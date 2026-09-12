import Foundation

/// The explicit native-authority/legacy-projection bridge used during Timeline v2 migration.
///
/// The native Session/Work pair is written first and is authoritative for command acceptance and
/// delivery. `SessionWriter` is written second solely because the current GUI/parser still reads
/// that format. If either write is unavailable the controller fails closed before dispatch; this
/// bridge never presents the two files as a transaction.
public actor NativeSessionCommandJournal: SessionCommandJournal {
    public nonisolated let identity: SessionWorkIdentity
    public nonisolated let nativeJournal: RunJournalBundle
    public nonisolated let legacyProjection: SessionWriter
    /// Immutable native history captured after the journal pair is locked and before the new
    /// Start command can append its prompt. Nil for launch-fresh runs; exact cold resume always
    /// carries a reconstructed seed.
    public nonisolated let resumeSeed: NativeColdResumeResult?

    public init(
        identity: SessionWorkIdentity,
        nativeJournal: RunJournalBundle,
        legacyProjection: SessionWriter,
        resumeSeed: NativeColdResumeResult? = nil
    ) throws {
        guard nativeJournal.session == SessionRef(identity.sessionID),
              nativeJournal.work == identity.work,
              nativeJournal.run == RunRef(identity.runID),
              legacyProjection.identity == identity else {
            throw RunJournalBundleError.invalidConfiguration(
                "the command bridge identities do not describe one Session, Work, and Run")
        }
        self.identity = identity
        self.nativeJournal = nativeJournal
        self.legacyProjection = legacyProjection
        self.resumeSeed = resumeSeed
    }

    /// Open the canonical launch journal when this execution has a complete native history.
    ///
    /// Fresh runs create the pair. Exact cold resumes must reopen a complete native pair; a
    /// missing or one-sided pair fails through `RunJournalBundle.openForExecution` rather than
    /// falling back to the legacy SessionWriter transcript.
    public static func openForLaunch(
        home: AgentHome,
        identity: SessionWorkIdentity,
        legacyProjection: SessionWriter,
        actorID: String,
        actorKind: String = "client",
        modelID: String? = nil,
        modelContextMode: WorkLaunchContextMode
    ) async throws -> NativeSessionCommandJournal {
        if modelContextMode == .exactColdResume {
            let sessionExists = FileManager.default.fileExists(
                atPath: home.timelineV2SessionJournalURL(sessionID: identity.sessionID).path)
            let workExists = FileManager.default.fileExists(
                atPath: home.timelineV2WorkJournalURL(identity.work).path)
            guard sessionExists && workExists else {
                if sessionExists != workExists {
                    throw RunJournalBundleError.missingCounterpart(
                        path: (!sessionExists
                            ? home.timelineV2SessionJournalURL(sessionID: identity.sessionID)
                            : home.timelineV2WorkJournalURL(identity.work)).path)
                }
                // Exact cold resume is a native reconstruction contract. With no canonical pair
                // there is no prior context to reconstruct, and opening a new Run would make a
                // failed legacy fallback look like a valid cold launch.
                throw NativeColdResumeError.noCompleteContextManifest
            }
        }
        let bundle = try await RunJournalBundle.openForExecution(
            home: home, identity: identity, actorID: actorID, actorKind: actorKind,
            modelID: modelID)
        do {
            let resumeSeed: NativeColdResumeResult?
            if modelContextMode == .exactColdResume {
                resumeSeed = try captureResumeSeed(
                    home: home, identity: identity, bundle: bundle)
            } else {
                resumeSeed = nil
            }
            if let resumeSeed {
                _ = try await bundle.recordRecoveryCoverage(resumeSeed.coverage)
            }
            return try NativeSessionCommandJournal(
                identity: identity, nativeJournal: bundle,
                legacyProjection: legacyProjection, resumeSeed: resumeSeed)
        } catch {
            // A replacement Run can fail during pre-command reconstruction (for example when a
            // retained context body is unavailable) after its exact marker has been appended.
            // Keep that untouched reservation recoverable; terminalizing it here would leave the
            // durable Start pointer naming a finished Run that a retry can never reopen. Once any
            // command/turn/effect evidence exists, preserve the existing failed-run behavior.
            if !(await bundle.isUntouchedStartedRun) {
                _ = try? await bundle.finishRun(
                    outcome: .failed,
                    detail: "native cold-resume validation or command journal installation failed")
            }
            try? await bundle.closeChecked()
            throw error
        }
    }

    /// Open an execution generation against a service-created idle Work binding. Unlike the
    /// identity-based launch path, this method never creates the Session/Work journals or mints
    /// their attachment; those facts must already be durable before a Hosted actor is returned.
    public static func openForRun(
        home: AgentHome,
        binding: WorkRunBinding,
        legacyProjection: SessionWriter,
        actorID: String,
        actorKind: String = "work-host",
        modelID: String? = nil,
        modelContextMode: WorkLaunchContextMode
    ) async throws -> NativeSessionCommandJournal {
        let identity = SessionWorkIdentity(
            sessionID: binding.workBinding.session.sessionID,
            work: binding.workBinding.work,
            runID: binding.run.runID)
        guard legacyProjection.identity == identity else {
            throw RunJournalBundleError.invalidConfiguration(
                "the legacy Session projection does not match the Work Run binding")
        }
        let bundle = try await RunJournalBundle.openForExecution(
            home: home, binding: binding, actorID: actorID, actorKind: actorKind,
            modelID: modelID)
        do {
            let resumeSeed = try modelContextMode == .exactColdResume
                ? captureResumeSeed(home: home, identity: identity, bundle: bundle)
                : nil
            if let resumeSeed {
                _ = try await bundle.recordRecoveryCoverage(resumeSeed.coverage)
            }
            return try NativeSessionCommandJournal(
                identity: identity, nativeJournal: bundle,
                legacyProjection: legacyProjection, resumeSeed: resumeSeed)
        } catch {
            // Keep an exact, untouched `run.started` reservation recoverable.  In particular,
            // cold-resume validation can fail after the paired marker was committed but before
            // any command crossed the runtime boundary; appending `run.finished` here would
            // poison the durable Start pointer and make an exact retry impossible.  Once the
            // marker has any later canonical activity, terminalize it as before.
            if !(await bundle.isUntouchedStartedRun) {
                _ = try? await bundle.finishRun(
                    outcome: .failed,
                    detail: "native cold-resume validation or command journal installation failed")
            }
            try? await bundle.closeChecked()
            throw error
        }
    }

    /// Inspect the completed predecessor without opening writers or appending a replacement Run.
    /// `nil` means there is no recorded context crossing (the normal Start(empty) case); every
    /// other failure is meaningful corruption or incompleteness and must fail closed before a
    /// replacement manifest is published.
    public static func preflightPriorContext(
        home: AgentHome,
        binding: WorkBinding
    ) throws -> NativeColdResumeResult? {
        let sessionURL = home.timelineV2SessionJournalURL(binding.session)
        let workURL = home.timelineV2WorkJournalURL(binding.work)
        guard FileManager.default.fileExists(atPath: sessionURL.path),
              FileManager.default.fileExists(atPath: workURL.path) else {
            throw NativeColdResumeError.emptyJournal(binding.sessionJournal)
        }
        let actor = TimelineActor(actorID: "native-resume-preflight", kind: "work-host")
        let sessionData: Data
        let workData: Data
        do {
            sessionData = try Data(contentsOf: sessionURL)
            workData = try Data(contentsOf: workURL)
        } catch {
            throw NativeColdResumeError.workStateUnavailable(
                "native predecessor journal could not be read")
        }
        let sessionRead = TimelineJournalReader.read(
            sessionData, journal: binding.sessionJournal, actor: actor,
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        let workRead = TimelineJournalReader.read(
            workData, journal: binding.workJournal, actor: actor,
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        guard let sessionTip = sessionRead.records.last?.event,
              let workTip = workRead.records.last?.event else {
            throw NativeColdResumeError.emptyJournal(binding.sessionJournal)
        }
        do {
            return try NativeColdResume.resume(
                sessionRead: sessionRead,
                expectedSessionCursor: JournalCursor(
                    journal: binding.sessionJournal, eventID: sessionTip.eventID,
                    sequence: sessionTip.sequence),
                workRead: workRead,
                expectedWorkCursor: JournalCursor(
                    journal: binding.workJournal, eventID: workTip.eventID,
                    sequence: workTip.sequence),
                bodyStore: ContextBodyStore(home: home))
        } catch NativeColdResumeError.noCompleteContextManifest {
            return nil
        }
    }

    /// `openForExecution` has locked both files and appended exactly one `run.started` record for
    /// the replacement Run. Remove that marker from the replay view: it is the new attempt, not
    /// prior history. The Session side has not changed, and its attachment cursor must identify
    /// the exact prior Work tip accepted by `NativeColdResume`.
    private static func captureResumeSeed(
        home: AgentHome, identity: SessionWorkIdentity, bundle: RunJournalBundle
    ) throws -> NativeColdResumeResult {
        let actor = TimelineActor(actorID: "native-resume-reader", kind: "work-host")
        let sessionRead = TimelineJournalReader.read(
            try Data(contentsOf: home.timelineV2SessionJournalURL(sessionID: identity.sessionID)),
            journal: bundle.sessionJournal, actor: actor,
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        let completeWorkRead = TimelineJournalReader.read(
            try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
            journal: bundle.workJournal, actor: actor,
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        guard completeWorkRead.quarantinedSuffix == nil,
              completeWorkRead.truncatedTail == nil,
              let replacementStart = completeWorkRead.records.last,
              replacementStart.event.type == TimelineEventType.runStarted,
              replacementStart.event.run == RunRef(identity.runID) else {
            throw RunJournalBundleError.invalidJournal(
                journal: bundle.workJournal,
                reason: "the locked Work journal does not end at the replacement Run marker")
        }
        let priorWorkRecords = Array(completeWorkRead.records.dropLast())
        guard let priorWorkTip = priorWorkRecords.last?.event,
              let sessionTip = sessionRead.records.last?.event else {
            throw RunJournalBundleError.invalidJournal(
                journal: bundle.workJournal,
                reason: "the prior Session/Work replay prefix is empty")
        }
        let priorWorkRead = TimelineJournalReadResult(records: priorWorkRecords)
        return try NativeColdResume.resume(
            sessionRead: sessionRead,
            expectedSessionCursor: JournalCursor(
                journal: bundle.sessionJournal, eventID: sessionTip.eventID,
                sequence: sessionTip.sequence),
            workRead: priorWorkRead,
            expectedWorkCursor: JournalCursor(
                journal: bundle.workJournal, eventID: priorWorkTip.eventID,
                sequence: priorWorkTip.sequence),
            bodyStore: ContextBodyStore(home: home))
    }

    public func commitIntent(_ intent: SessionCommandIntent) async throws {
        try validate(intent)
        guard let causalCursor = intent.causalCursor else {
            throw SessionCommandJournalError.causalConflict(
                commandID: intent.commandID,
                expected: await nativeJournal.latestWorkCursor,
                received: nil)
        }
        let client = ClientRef(intent.actorID)
        // Native command admission always carries the exact caller-observed Work cursor. The
        // flat SessionWriter compatibility path remains separate and may use its own defaults.
        let command = CommandRef(
            commandID: intent.commandID, client: client, causalCursor: causalCursor)
        var metadata: [String: JSONValue] = [
            "command_kind": .string(intent.command.label),
            "controller_sequence": .number(Double(intent.sequence)),
            "actor_id": .string(intent.actorID),
            "controller_state": .string(intent.state.rawValue),
            "caller_causal_cursor_supplied": .bool(true),
        ]
        do {
            var committedInitialStart = false
            if case .start(let prompt) = intent.command {
                // A service observes the idle Work cursor before this bridge opens the Run, so
                // `run.started` may already be one event newer by the time Start is committed.
                // Let the bundle validate and preserve that exact predecessor only for this first
                // Start; all other commands continue through the current-cursor check below.
                if try await nativeJournal.commitInitialStartIfEligible(
                    prompt: prompt, deliveryMode: .queued, command: command,
                    metadata: metadata) != nil {
                    committedInitialStart = true
                }
            }
            // Refuse a stale caller cursor before entering the bundle. This gives the controller a
            // typed conflict result instead of treating a lost race as an unavailable journal.
            if !committedInitialStart {
                let received = causalCursor
                let expected = await nativeJournal.latestWorkCursor
                guard received == expected else {
                    if received.journal == nativeJournal.workJournal {
                        do {
                            _ = try await nativeJournal.rejectCommand(
                                command: command,
                                reason: "the caller Work cursor is stale",
                                metadata: [
                                    "command_kind": .string(intent.command.label),
                                    "actor_id": .string(intent.actorID),
                                ])
                        } catch let bundleError as RunJournalBundleError {
                            // A fabricated/noncanonical cursor cannot safely be linked into the
                            // Work journal. It remains a typed client conflict, while actual
                            // writer failures still propagate and latch the controller.
                            if case .invalidOperation(let reason) = bundleError,
                               reason.contains("cursor is not part") {
                                throw SessionCommandJournalError.causalConflict(
                                    commandID: intent.commandID,
                                    expected: expected, received: received)
                            }
                            throw bundleError
                        }
                    }
                    throw SessionCommandJournalError.causalConflict(
                        commandID: intent.commandID, expected: expected, received: received)
                }
            }
            if !committedInitialStart {
                switch intent.command {
                case .start(let prompt):
                    if prompt.isEmpty {
                        _ = try await nativeJournal.commitCommand(
                            label: intent.command.label, deliveryMode: .queued,
                            command: command, metadata: metadata)
                    } else {
                        _ = try await nativeJournal.commitInput(
                            text: prompt, deliveryMode: .queued, command: command,
                            metadata: metadata)
                    }
                case .send(let prompt):
                    _ = try await nativeJournal.commitInput(
                        text: prompt, deliveryMode: .queued, command: command,
                        metadata: metadata)
                case .steer(let text), .queueFollowUp(let text):
                    _ = try await nativeJournal.commitInput(
                        text: text, deliveryMode: .queued, command: command,
                        metadata: metadata)
                case .cancel(let scope):
                    metadata["cancellation_scope"] = .string(scope.rawValue)
                    _ = try await nativeJournal.commitCommand(
                        label: intent.command.label, deliveryMode: .queued,
                        command: command, metadata: metadata)
                case .endRun:
                    _ = try await nativeJournal.commitCommand(
                        label: intent.command.label, deliveryMode: .queued,
                        command: command, metadata: metadata)
                }
            }
            try await commitLegacyProjection(intent)
        } catch let error as SessionCommandJournalError {
            throw error
        } catch let error as RunJournalBundleError {
            // `commitInput` writes Work acceptance before its canonical Session input/tip. A
            // Session failure therefore does not by itself mean admission failed: inspect the
            // actual Work ledger while the bundle still retains that partial prefix.
            if let state = await nativeJournal.commandState(for: intent.commandID),
               state != .rejected {
                throw SessionCommandJournalError.acceptedButUndelivered(
                    commandID: intent.commandID, reason: error.localizedDescription)
            }
            // The bundle currently validates cursor ancestry but has no public rejection append
            // operation. Keep that refusal typed and non-retryable; callers can refresh their
            // cursor and submit a new command id. Other bundle failures remain infrastructure
            // failures and latch the controller.
            if case .invalidOperation(let reason) = error,
               reason.contains("current pre-receipt Work cursor") {
                let expected = await nativeJournal.latestWorkCursor
                throw SessionCommandJournalError.causalConflict(
                    commandID: intent.commandID, expected: expected,
                    received: intent.causalCursor)
            }
            throw error
        }

    }

    private func commitLegacyProjection(_ intent: SessionCommandIntent) async throws {
        // Native acceptance is already durable. If this projection append fails, the command
        // remains visibly accepted-but-undelivered in Work and the controller refuses dispatch.
        do {
            try await legacyProjection.commitIntent(intent)
        } catch {
            throw SessionCommandJournalError.acceptedButUndelivered(
                commandID: intent.commandID, reason: error.localizedDescription)
        }
    }

    public func markDelivered(_ intent: SessionCommandIntent, at timestamp: Date) async throws {
        try validate(intent)
        _ = try await AviaryTelemetry.withSpan(
            "aviary.command.canonical_delivery",
            attributes: [
                "aviary.command.ledger.id": .string(AviaryTelemetry.identity(intent.commandID)),
                "aviary.client.id": .string(AviaryTelemetry.identity(intent.actorID)),
                "aviary.session.id": .string(AviaryTelemetry.identity(identity.sessionID)),
                "aviary.work.id": .string(AviaryTelemetry.workIdentity(identity.work)),
                "aviary.run.id": .string(AviaryTelemetry.identity(identity.runID)),
            ]) {
                do {
                    let commit = try await nativeJournal.markCommandDelivered(
                        commandID: intent.commandID)
                    AviaryTelemetry.event("aviary.command.canonical_delivery", attributes: [
                        "aviary.command.ledger.id": .string(
                            AviaryTelemetry.identity(intent.commandID)),
                        "aviary.delivery.state": .string("delivered"),
                    ].merging(AviaryTelemetry.canonicalReferenceAttributes(commit)) { _, exact in exact })
                    AviaryTelemetry.outcome("succeeded")
                    return commit
                } catch {
                    AviaryTelemetry.event(
                        "aviary.agent.exception",
                        attributes: ["error.type": .string("canonical_delivery")])
                    Self.recordCanonicalDeliveryFailure(error)
                    throw error
                }
            }
        try await legacyProjection.markDelivered(intent, at: timestamp)
    }

    public func markUndelivered(
        _ intent: SessionCommandIntent, reason: String, at timestamp: Date
    ) async throws {
        try validate(intent)
        try await AviaryTelemetry.withSpan("aviary.command.canonical_nondelivery", attributes: [
            "aviary.command.ledger.id": .string(AviaryTelemetry.identity(intent.commandID)),
            "aviary.client.id": .string(AviaryTelemetry.identity(intent.actorID)),
            "aviary.session.id": .string(AviaryTelemetry.identity(identity.sessionID)),
            "aviary.work.id": .string(AviaryTelemetry.workIdentity(identity.work)),
            "aviary.run.id": .string(AviaryTelemetry.identity(identity.runID)),
        ]) {
            do {
                let commit = try await nativeJournal.markCommandNotDelivered(
                    commandID: intent.commandID, reason: reason)
                AviaryTelemetry.event("aviary.command.canonical_nondelivery", attributes: [
                    "aviary.command.ledger.id": .string(AviaryTelemetry.identity(intent.commandID)),
                    "aviary.delivery.state": .string("not_delivered"),
                ].merging(AviaryTelemetry.canonicalReferenceAttributes(commit)) { _, exact in exact })
                AviaryTelemetry.outcome("succeeded")
            } catch {
                AviaryTelemetry.event("aviary.agent.exception", attributes: [
                    "error.type": .string("canonical_delivery"),
                ])
                Self.recordCanonicalDeliveryFailure(error)
                throw error
            }
        }
    }

    private static func recordCanonicalDeliveryFailure(_ error: Error) {
        if let error = error as? RunJournalBundleError {
            switch error {
            case .invalidOperation, .alreadyFinished, .workTerminal:
                AviaryTelemetry.outcome("rejected")
                return
            default: break
            }
        }
        // An append can fail after writing. No commit event is emitted without confirmation,
        // and failure alone must not imply that the delivery record does not exist.
        AviaryTelemetry.outcome("indeterminate")
    }

    private func validate(_ intent: SessionCommandIntent) throws {
        guard intent.identity == identity else {
            throw RunJournalBundleError.invalidOperation(
                "the command intent belongs to another Session, Work, or Run")
        }
    }
}
