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
    /// Start command can append its prompt. Nil for fresh runs and legacy-only resumes.
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
    /// Fresh runs create the pair. Native resumes reopen the pair. A legacy-only resume returns
    /// nil instead of creating a misleading Timeline v2 tail halfway through the conversation;
    /// one-sided native state still throws through `RunJournalBundle.openForExecution`.
    public static func openForLaunch(
        home: AgentHome,
        identity: SessionWorkIdentity,
        legacyProjection: SessionWriter,
        actorID: String,
        actorKind: String = "client",
        modelID: String? = nil,
        resumingLegacySession: Bool
    ) async throws -> NativeSessionCommandJournal? {
        let sessionExists = FileManager.default.fileExists(
            atPath: home.timelineV2SessionJournalURL(sessionID: identity.sessionID).path)
        let workExists = FileManager.default.fileExists(
            atPath: home.timelineV2WorkJournalURL(identity.work).path)
        if resumingLegacySession, !sessionExists, !workExists { return nil }

        let bundle = try await RunJournalBundle.openForExecution(
            home: home, identity: identity, actorID: actorID, actorKind: actorKind,
            modelID: modelID)
        do {
            let resumeSeed = try resumingLegacySession
                ? captureResumeSeed(home: home, identity: identity, bundle: bundle)
                : nil
            if let resumeSeed {
                _ = try await bundle.recordRecoveryCoverage(resumeSeed.coverage)
            }
            return try NativeSessionCommandJournal(
                identity: identity, nativeJournal: bundle,
                legacyProjection: legacyProjection, resumeSeed: resumeSeed)
        } catch {
            _ = try? await bundle.finishRun(
                outcome: .failed,
                detail: "native cold-resume validation or command journal installation failed")
            try? await bundle.closeChecked()
            throw error
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
        let client = ClientRef(intent.actorID)
        // Preserve a caller's observed Work cursor exactly. RunJournalBundle may fill a missing
        // cursor for legacy callers, but it must never overwrite a supplied one.
        let command = CommandRef(
            commandID: intent.commandID, client: client, causalCursor: intent.causalCursor)
        var metadata: [String: JSONValue] = [
            "command_kind": .string(intent.command.label),
            "controller_sequence": .number(Double(intent.sequence)),
            "actor_id": .string(intent.actorID),
            "controller_state": .string(intent.state.rawValue),
            // Keep cursor provenance observable even when the compatibility API omits a cursor
            // and the bundle supplies its legacy "latest" fallback.
            "caller_causal_cursor_supplied": .bool(intent.causalCursor != nil),
        ]
        do {
            // Refuse a stale caller cursor before entering the bundle. This gives the controller a
            // typed conflict result instead of treating a lost race as an unavailable journal.
            if let received = intent.causalCursor {
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
        _ = try await nativeJournal.markCommandDelivered(commandID: intent.commandID)
        try await legacyProjection.markDelivered(intent, at: timestamp)
    }

    public func markUndelivered(
        _ intent: SessionCommandIntent, reason: String, at timestamp: Date
    ) async throws {
        try validate(intent)
        _ = try await nativeJournal.markCommandNotDelivered(
            commandID: intent.commandID, reason: reason)
    }

    private func validate(_ intent: SessionCommandIntent) throws {
        guard intent.identity == identity else {
            throw RunJournalBundleError.invalidOperation(
                "the command intent belongs to another Session, Work, or Run")
        }
    }
}
