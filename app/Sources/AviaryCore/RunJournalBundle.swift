import Foundation

/// The delivery crossing recorded by ``RunJournalBundle.commitInput``.
public enum RunInputDeliveryMode: String, Codable, Hashable, Sendable {
    /// Work owns the input, but the runtime has not crossed the delivery boundary yet.
    case queued
    /// Work owns the input and the runtime accepted delivery.
    case delivered
}

/// The terminal state of one Run. A Run can end without completing successfully; keeping this
/// value typed prevents the coordinator from silently projecting every termination as completed.
public enum RunTerminalOutcome: String, Codable, Hashable, Sendable {
    case completed
    case failed
    case canceled
    case held
    case indeterminate
}

/// The outcome of one native turn, projected onto Session attention at the turn boundary.
public enum RunTurnOutcome: String, Codable, Hashable, Sendable {
    case completed
    case failed
    case canceled

    public var sessionAttention: SessionAttention {
        switch self {
        case .completed: return .review
        case .failed: return .error
        case .canceled: return .none
        }
    }
}

/// The bounded vocabulary used by the first native effect boundary. Keeping this typed makes
/// action accounting useful without making the bundle know how any one provider executes.
public enum ActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case provider
    case compactionProvider = "compaction_provider"
    case providerSetup = "provider_setup"
    case python
    case mcp
    case runtime
    case hook
    case peerDelivery = "peer_delivery"
    case selfDelivery = "self_delivery"
    case webSearch = "web_search"
    case webExtract = "web_extract"
    case child
    case memory
    case artifact
    case imageRead = "image_read"
    case nestedProcessCallback = "nested_process_callback"
}

/// The lifecycle states recorded for a child admitted by a native run. A running record is
/// written before the child task is created; exactly one terminal state follows after it settles.
public enum ChildLifecycleState: String, Codable, CaseIterable, Hashable, Sendable {
    case running
    case done
    case failed
    case canceled
}

/// A capability to cross the external-effect boundary. It is intentionally only constructible
/// by ``RunJournalBundle.beginAction`` and is returned after both intent and start are durable.
public struct EffectPermit: Codable, Hashable, Sendable {
    public let action: ActionRef
    public let kind: ActionKind
    public let intent: String
    public let intentCommit: TimelineJournalCommit
    public let startedCommit: TimelineJournalCommit
    public let providerAdmission: ProviderAdmission?

    fileprivate init(action: ActionRef, kind: ActionKind, intent: String,
                     intentCommit: TimelineJournalCommit,
                     startedCommit: TimelineJournalCommit,
                     providerAdmission: ProviderAdmission? = nil) {
        self.action = action
        self.kind = kind
        self.intent = intent
        self.intentCommit = intentCommit
        self.startedCommit = startedCommit
        self.providerAdmission = providerAdmission
    }
}

/// The known durable prefix of both journals. This is deliberately not an atomic snapshot:
/// one journal can be ahead when the paired operation fails.
public struct RunJournalBundlePrefix: Codable, Hashable, Sendable {
    public let sessionCursor: JournalCursor?
    public let workCursor: JournalCursor?
    public let sessionEventCount: Int
    public let workEventCount: Int
    public let hostOrder: Int
    public let failedJournal: JournalRef?
    public let failureReason: String?

    public init(sessionCursor: JournalCursor?, workCursor: JournalCursor?,
                sessionEventCount: Int, workEventCount: Int, hostOrder: Int,
                failedJournal: JournalRef? = nil, failureReason: String? = nil) {
        self.sessionCursor = sessionCursor
        self.workCursor = workCursor
        self.sessionEventCount = sessionEventCount
        self.workEventCount = workEventCount
        self.hostOrder = hostOrder
        self.failedJournal = failedJournal
        self.failureReason = failureReason
    }
}

public enum RunJournalBundleHealth: Hashable, Sendable {
    case healthy
    case failed(reason: String)
    case closed
}

public struct RunJournalBundleStatus: Hashable, Sendable {
    public let health: RunJournalBundleHealth
    public let durablePrefix: RunJournalBundlePrefix

    public init(health: RunJournalBundleHealth, durablePrefix: RunJournalBundlePrefix) {
        self.health = health
        self.durablePrefix = durablePrefix
    }
}

/// One actor-serialized canonical read of the paired native journals. The Work projection is
/// always present; the Session projection is the exact Session/attachment owned by the bundle.
/// Callers may use the Work half as authoritative evidence when the Work's creation Session is a
/// different, cold Session.
public struct RunJournalBundleCanonicalObservation: Hashable, Sendable {
    public let binding: WorkBinding
    public let work: TimelineJournalCanonicalRead
    public let session: TimelineJournalCanonicalRead

    public init(
        binding: WorkBinding,
        work: TimelineJournalCanonicalRead,
        session: TimelineJournalCanonicalRead
    ) throws {
        guard work.journal == binding.workJournal,
              session.journal == binding.sessionJournal,
              case .work(let workHead) = work.projection,
              case .session(let sessionHead) = session.projection,
              workHead.work == binding.work,
              workHead.workHost == binding.workHost,
              sessionHead.session == binding.session else {
            throw RunJournalBundleError.invalidConfiguration(
                "canonical observation does not match its Work binding")
        }
        self.binding = binding
        self.work = work
        self.session = session
    }

    /// The Work half is intentionally available without exposing the cold creation Session.
    /// This is the only form suitable for an alternate active Session binding.
    public var workOnly: TimelineJournalCanonicalRead { work }
}

/// Canonical evidence for one exactly-once terminal Work transaction.
public struct RunJournalBundleTerminalCommit: Hashable, Sendable {
    public let workEvent: TimelineEvent
    public let workCommit: TimelineJournalCommit
    public let pairedSessionEvent: TimelineEvent?
    public let pairedSessionCommit: TimelineJournalCommit?
    public let outstandingHandleIDs: [HandleRef]

    public var sessionPairingVerified: Bool { pairedSessionCommit != nil }

    public init(workEvent: TimelineEvent, workCommit: TimelineJournalCommit,
                pairedSessionEvent: TimelineEvent?,
                pairedSessionCommit: TimelineJournalCommit?,
                outstandingHandleIDs: [HandleRef]) {
        self.workEvent = workEvent
        self.workCommit = workCommit
        self.pairedSessionEvent = pairedSessionEvent
        self.pairedSessionCommit = pairedSessionCommit
        self.outstandingHandleIDs = outstandingHandleIDs
    }
}

/// Durable identities that exist before any execution Run is admitted. Work creation is a
/// control-plane operation; it must not manufacture a Run identity or start provider/runtime
/// effects merely so the Session and Work become addressable.
public struct WorkBinding: Codable, Hashable, Sendable {
    public let session: SessionRef
    public let work: WorkRef
    public let workHost: WorkHostRef
    public let sessionAttachment: SessionAttachmentRef

    public init(session: SessionRef, work: WorkRef, workHost: WorkHostRef,
                sessionAttachment: SessionAttachmentRef) {
        self.session = session
        self.work = work
        self.workHost = workHost
        self.sessionAttachment = sessionAttachment
    }

    public var sessionJournal: JournalRef {
        .session(
            session, journalID: "session",
            authority: TimelineAuthorityRef(workHost.workHostID))
    }

    public var workJournal: JournalRef { .work(work, journalID: "work") }
}

/// One execution generation admitted against an existing durable Work binding.
public struct WorkRunBinding: Codable, Hashable, Sendable {
    public let workBinding: WorkBinding
    public let run: RunRef

    public init(workBinding: WorkBinding, run: RunRef) {
        self.workBinding = workBinding
        self.run = run
    }
}

/// A receipt for one durably published artifact.  The envelope fields are repeated here so a
/// producer can retain the exact Run/Turn/action/provenance association without rereading the
/// Work journal merely to interpret a successful append.
public struct RunJournalArtifactReceipt: Codable, Hashable, Sendable {
    public let descriptor: WorkServiceArtifactDescriptor
    public let commit: TimelineJournalCommit
    public let run: RunRef
    public let turn: TurnRef?
    public let action: ActionRef?
    public let provenance: EventRef?
    public let links: [TimelineLink]

    public init(
        descriptor: WorkServiceArtifactDescriptor, commit: TimelineJournalCommit,
        run: RunRef, turn: TurnRef?, action: ActionRef?, provenance: EventRef?,
        links: [TimelineLink]
    ) {
        self.descriptor = descriptor
        self.commit = commit
        self.run = run
        self.turn = turn
        self.action = action
        self.provenance = provenance
        self.links = links
    }
}

/// Exact genesis receipts for an idle Work. Both writers are closed before this value is
/// returned, so a service can durably register the pair without retaining execution ownership.
public struct IdleWorkCreation: Codable, Hashable, Sendable {
    public let binding: WorkBinding
    public let sessionCursor: JournalCursor
    public let workCursor: JournalCursor
    public let commits: [TimelineJournalCommit]

    public init(binding: WorkBinding, sessionCursor: JournalCursor,
                workCursor: JournalCursor, commits: [TimelineJournalCommit]) {
        self.binding = binding
        self.sessionCursor = sessionCursor
        self.workCursor = workCursor
        self.commits = commits
    }
}

/// The source-journal half of an existing-Work Session creation.  The control journal owns the
/// reservation and result record; this value contains only the evidence which was actually
/// committed in the Session/Work journals.  A caller may safely discard it after recording the
/// result because every field is reconstructable from those journals.
public struct RunJournalBundleSessionPublication: Codable, Hashable, Sendable {
    public let session: SessionRef
    public let sessionJournal: JournalRef
    public let sessionAttachment: SessionAttachmentRef
    public let publication: String
    public let capabilities: [String]
    public let causalSessionCursor: JournalCursor
    public let sessionCursor: JournalCursor
    public let causalWorkCursor: JournalCursor
    public let resultingWorkCursor: JournalCursor
    public let sessionCreated: TimelineJournalCommit
    public let sessionAttached: TimelineJournalCommit
    public let workMirror: TimelineJournalCommit?
    public let cursorAdvanced: TimelineJournalCommit

    public init(
        session: SessionRef, sessionJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef, publication: String,
        capabilities: [String], causalSessionCursor: JournalCursor,
        sessionCursor: JournalCursor, causalWorkCursor: JournalCursor,
        resultingWorkCursor: JournalCursor, sessionCreated: TimelineJournalCommit,
        sessionAttached: TimelineJournalCommit, workMirror: TimelineJournalCommit?,
        cursorAdvanced: TimelineJournalCommit
    ) {
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.publication = publication
        self.capabilities = capabilities.sorted()
        self.causalSessionCursor = causalSessionCursor
        self.sessionCursor = sessionCursor
        self.causalWorkCursor = causalWorkCursor
        self.resultingWorkCursor = resultingWorkCursor
        self.sessionCreated = sessionCreated
        self.sessionAttached = sessionAttached
        self.workMirror = workMirror
        self.cursorAdvanced = cursorAdvanced
    }
}

/// Bounded, host-minted input for ``publishSessionAttachment``.  In particular, no event id or
/// cursor is accepted from the caller; those remain writer-owned facts.
public struct RunJournalBundleSessionPublicationRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let workHost: WorkHostRef
    public let workJournal: JournalRef
    public let session: SessionRef
    public let sessionJournal: JournalRef
    public let sessionAttachment: SessionAttachmentRef
    public let client: ClientRef
    public let command: CommandRef
    public let capabilities: [String]
    public let causalWorkCursor: JournalCursor
    /// Required only for a terminal reference. The event must be the exact final Work event at
    /// ``causalWorkCursor``; the Work writer is still locked and checked, but never appended.
    public let terminalEvent: EventRef?

    public init(
        work: WorkRef, workHost: WorkHostRef, workJournal: JournalRef,
        session: SessionRef, sessionJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef, client: ClientRef,
        command: CommandRef, capabilities: [String], causalWorkCursor: JournalCursor,
        terminalEvent: EventRef? = nil
    ) {
        self.work = work
        self.workHost = workHost
        self.workJournal = workJournal
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.client = client
        self.command = command
        self.capabilities = capabilities.sorted()
        self.causalWorkCursor = causalWorkCursor
        self.terminalEvent = terminalEvent
    }
}

public enum RunJournalBundleError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case missingCounterpart(path: String)
    case duplicateActiveWriter(path: String)
    case invalidJournal(journal: JournalRef, reason: String)
    case invalidGenesis(journal: JournalRef, reason: String)
    case unfinishedActions([String])
    case unfinishedHandles([String])
    case unfinishedCommands([String])
    case alreadyFinished(String)
    case workTerminal(WorkLifecycle)
    case invalidOperation(String)
    /// The bundle's semantic gate observed a cleanly closed bundle before an agent Handle
    /// append touched the Work writer. Only this result is safe for the Work-owned route to
    /// retry through its post-Run writer.
    case closedBeforeAgentAppend
    case writer(TimelineJournalWriter.WriterError)
    case initializationFailed(RunJournalBundlePrefix, reason: String)
    case closeFailed(RunJournalBundlePrefix, reason: String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): return "Invalid Run journal bundle configuration: \(reason)"
        case .missingCounterpart(let path): return "Run journal bundle counterpart is missing: \(path)"
        case .duplicateActiveWriter(let path): return "Run journal bundle already has an active writer: \(path)"
        case .invalidJournal(let journal, let reason): return "Invalid native journal \(journal.journalID): \(reason)"
        case .invalidGenesis(let journal, let reason): return "Invalid journal genesis \(journal.journalID): \(reason)"
        case .unfinishedActions(let ids): return "Cannot resume Run with unfinished actions: \(ids.joined(separator: ", "))"
        case .unfinishedHandles(let ids): return "Cannot terminalize Work with unfinished Handles: \(ids.joined(separator: ", "))"
        case .unfinishedCommands(let ids):
            return "Cannot finish Run with accepted, undelivered commands: \(ids.joined(separator: ", "))"
        case .alreadyFinished(let reason): return "Run journal bundle is already finished: \(reason)"
        case .workTerminal(let lifecycle):
            return "Work is terminal and cannot be mutated: \(lifecycle.rawValue)"
        case .invalidOperation(let reason): return "Invalid Run journal operation: \(reason)"
        case .closedBeforeAgentAppend:
            return "Run journal bundle closed before the agent Handle append began."
        case .writer(let error): return error.localizedDescription
        case .initializationFailed(_, let reason): return "Run journal bundle initialization failed: \(reason)"
        case .closeFailed(_, let reason): return "Run journal bundle close was partial: \(reason)"
        case .unavailable(let reason): return "Run journal bundle unavailable: \(reason)"
        }
    }
}

/// The first semantic coordinator for native Timeline v2.
///
/// A bundle owns exactly one Session writer and one Work writer. It serializes semantic calls in
/// this process, but does not pretend that two files form a transaction. Every method keeps the
/// latest known cursor for each file so partial prefixes remain inspectable after a failure.
public actor RunJournalBundle {
    private static let maximumArtifactBodyBytes = 8 * 1024 * 1024

    private static func validArtifactText(
        _ value: String, maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value > 0x1F
                    && !(0x7F...0x9F).contains(scalar.value)
                    && scalar.value != 0x2028
                    && scalar.value != 0x2029
            }
    }

    private static func artifactIdentity(from event: TimelineEvent) -> String? {
        guard event.type == TimelineEventType.artifact,
              let object = event.payload.objectValue,
              let artifactID = object["artifact_id"]?.stringValue,
              validArtifactText(
                  artifactID, maximumBytes: WorkServiceBounds.maxIdentityCharacters)
        else { return nil }
        return artifactID
    }

    public nonisolated let session: SessionRef
    public nonisolated let work: WorkRef
    public nonisolated let workHost: WorkHostRef
    public nonisolated let sessionJournal: JournalRef
    public nonisolated let workJournal: JournalRef
    public nonisolated let sessionAttachment: SessionAttachmentRef
    public nonisolated let run: RunRef

    private let actor: TimelineActor
    private let sessionWriter: TimelineJournalWriter
    private let workWriter: TimelineJournalWriter
    private let contextBodyStore: ContextBodyStore
    private var sessionCursor: JournalCursor?
    private var workCursor: JournalCursor?
    private var sessionEventCount: Int
    private var workEventCount: Int
    private var hostOrder: Int
    private var activeActionIDs: Set<String>
    /// Action identities are single-use, including after a terminal outcome.
    private var seenActionIDs: Set<String>
    /// Producer artifact identities are single-use across a Work journal, including after a cold
    /// reopen.  The set is reconstructed from the already-read canonical Work prefix.
    private var seenArtifactIDs: Set<String>
    private var commands: [String: WorkCommandSnapshot]
    private var commandAcceptedRefs: [String: EventRef]
    private var permits: [String: EffectPermit]
    private var activeTurn: TurnRef?
    private var activeRun: RunRef?
    /// The exact Work prefix that preceded this bundle's `run.started` marker. A service can
    /// admit a Run after observing the idle Work cursor, so the first Start command may retain
    /// this historical cursor even though the marker is now the current Work tip.
    private var runStartPredecessorCursor: JournalCursor?
    /// Work remains reusable after every `run.finished`; this only changes after the explicit
    /// Work terminal transition has been durably paired with the Session cursor.
    private var workLifecycle: WorkLifecycle
    private var lastMessage: EventRef?
    /// Authored Session attention avoids duplicate evidence edges when a turn and its enclosing
    /// Run settle to the same visible state.
    private var authoredAttention: SessionAttention
    /// The journal, not the request builder, owns cumulative carriage accounting. Values are
    /// scoped by Run so a cold reducer and a reopened writer make the same claim.
    private var contextDeliveredBytesByRun: [String: Int]
    private var healthState: RunJournalBundleHealth = .healthy
    private var failedJournal: JournalRef?
    private var isClosed = false
    private var semanticGateHeld = false
    private var semanticGateWaiters: [CheckedContinuation<Void, Never>] = []

    private init(
        session: SessionRef, work: WorkRef, workHost: WorkHostRef,
        sessionJournal: JournalRef, workJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef, run: RunRef,
        actor: TimelineActor,
        contextBodyStore: ContextBodyStore,
        sessionWriter: TimelineJournalWriter, workWriter: TimelineJournalWriter,
        sessionCursor: JournalCursor?, workCursor: JournalCursor?,
        sessionEventCount: Int, workEventCount: Int, hostOrder: Int,
        activeActionIDs: Set<String> = [], seenActionIDs: Set<String> = [],
        seenArtifactIDs: Set<String> = [],
        commands: [String: WorkCommandSnapshot] = [:],
        commandAcceptedRefs: [String: EventRef] = [:], permits: [String: EffectPermit] = [:],
        activeTurn: TurnRef? = nil, activeRun: RunRef? = nil,
        runStartPredecessorCursor: JournalCursor? = nil,
        workLifecycle: WorkLifecycle = .active,
        lastMessage: EventRef? = nil,
        authoredAttention: SessionAttention = .none,
        contextDeliveredBytesByRun: [String: Int] = [:]
    ) {
        self.session = session
        self.work = work
        self.workHost = workHost
        self.sessionJournal = sessionJournal
        self.workJournal = workJournal
        self.sessionAttachment = sessionAttachment
        self.run = run
        self.actor = actor
        self.contextBodyStore = contextBodyStore
        self.sessionWriter = sessionWriter
        self.workWriter = workWriter
        self.sessionCursor = sessionCursor
        self.workCursor = workCursor
        self.sessionEventCount = sessionEventCount
        self.workEventCount = workEventCount
        self.hostOrder = hostOrder
        self.activeActionIDs = activeActionIDs
        self.seenActionIDs = seenActionIDs
        self.seenArtifactIDs = seenArtifactIDs
        self.commands = commands
        self.commandAcceptedRefs = commandAcceptedRefs
        self.permits = permits
        self.activeTurn = activeTurn
        self.activeRun = activeRun
        self.runStartPredecessorCursor = runStartPredecessorCursor
        self.workLifecycle = workLifecycle
        self.lastMessage = lastMessage
        self.authoredAttention = authoredAttention
        self.contextDeliveredBytesByRun = contextDeliveredBytesByRun
    }

    /// Create and close the canonical Session/Work genesis pair without starting a Run. This is
    /// the storage half of a service Create transaction: the Work Host control journal reserves
    /// identities before this call and registers these exact cursors after it returns.
    public static func createIdleWork(
        home: AgentHome,
        binding: WorkBinding,
        actorID: String,
        actorKind: String = "work-host-control",
        failurePlan: (session: TimelineJournalWriter.FailurePlan,
                      work: TimelineJournalWriter.FailurePlan) = (.none, .none),
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> IdleWorkCreation {
        let persistedHost = try home.requirePersistedWorkHost()
        guard binding.workHost == persistedHost,
              binding.work.workHostID == persistedHost.workHostID else {
            throw RunJournalBundleError.invalidConfiguration(
                "the idle Work binding does not belong to this AgentHome's persisted authority")
        }
        guard !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidConfiguration(
                "the idle Work creator identity is empty")
        }
        let configuration = try makeJournalConfiguration(
            session: binding.session,
            work: binding.work,
            workHost: binding.workHost,
            sessionAuthority: TimelineAuthorityRef(binding.workHost.workHostID),
            sessionAttachment: binding.sessionAttachment)
        let actor = TimelineActor(actorID: actorID, kind: actorKind)
        let sessionURL = home.timelineV2SessionJournalURL(binding.session)
        let workURL = home.timelineV2WorkJournalURL(binding.work)

        // `freshAt` intentionally refuses to overwrite an existing path. A process can still
        // die after either writer opens or after any of the four genesis appends, so an
        // unregistered reservation must be continued under both exact journal locks rather than
        // being left permanently wedged. The continuation accepts only the deterministic global
        // prefix emitted below; foreign/extended/corrupt evidence remains fail-closed.
        if FileManager.default.fileExists(atPath: sessionURL.path)
                || FileManager.default.fileExists(atPath: workURL.path) {
            return try await continueIdleWork(
                home: home, binding: binding, actor: actor,
                configuration: configuration, sessionURL: sessionURL, workURL: workURL,
                failurePlan: failurePlan, eventIDProvider: eventIDProvider, now: now)
        }

        let sessionWriter: TimelineJournalWriter
        do {
            sessionWriter = try TimelineJournalWriter(
                freshAt: sessionURL,
                journal: configuration.sessionJournal,
                actor: actor,
                home: home,
                failurePlan: failurePlan.session,
                eventIDProvider: eventIDProvider,
                now: now)
        } catch let error as TimelineJournalWriter.WriterError {
            throw mapWriterOpenError(error)
        }
        let workWriter: TimelineJournalWriter
        do {
            workWriter = try TimelineJournalWriter(
                freshAt: workURL,
                journal: configuration.workJournal,
                actor: actor,
                home: home,
                failurePlan: failurePlan.work,
                eventIDProvider: eventIDProvider,
                now: now)
        } catch {
            try? await sessionWriter.closeChecked()
            let reason = error.localizedDescription
            throw RunJournalBundleError.initializationFailed(
                RunJournalBundlePrefix(
                    sessionCursor: nil,
                    workCursor: nil,
                    sessionEventCount: 0,
                    workEventCount: 0,
                    hostOrder: 0,
                    failedJournal: configuration.workJournal,
                    failureReason: reason),
                reason: reason)
        }

        var sessionCursor: JournalCursor?
        var workCursor: JournalCursor?
        var sessionEventCount = 0
        var workEventCount = 0
        var hostOrder = 0
        var commits: [TimelineJournalCommit] = []
        var failedJournal: JournalRef?

        func prefix(reason: String? = nil) -> RunJournalBundlePrefix {
            RunJournalBundlePrefix(
                sessionCursor: sessionCursor,
                workCursor: workCursor,
                sessionEventCount: sessionEventCount,
                workEventCount: workEventCount,
                hostOrder: hostOrder,
                failedJournal: failedJournal,
                failureReason: reason)
        }

        do {
            hostOrder += 1
            failedJournal = configuration.sessionJournal
            let sessionCreated = try await sessionWriter.append(TimelineEventDraft(
                hostSequence: hostOrder,
                session: binding.session,
                type: TimelineEventType.sessionCreated,
                declaredDomains: [.session]))
            sessionCursor = sessionCreated.cursor
            sessionEventCount += 1
            commits.append(sessionCreated)

            hostOrder += 1
            failedJournal = configuration.workJournal
            let workCreated = try await workWriter.append(TimelineEventDraft(
                hostSequence: hostOrder,
                work: binding.work,
                workHost: binding.workHost,
                type: TimelineEventType.workCreated,
                declaredDomains: [.work]))
            workCursor = workCreated.cursor
            workEventCount += 1
            commits.append(workCreated)

            hostOrder += 1
            failedJournal = configuration.sessionJournal
            let sessionAttached = try await sessionWriter.append(TimelineEventDraft(
                hostSequence: hostOrder,
                session: binding.session,
                work: binding.work,
                sessionAttachment: binding.sessionAttachment,
                type: TimelineEventType.sessionAttached,
                declaredDomains: [.session, .work],
                payload: .object(["capabilities": .array([])])))
            sessionCursor = sessionAttached.cursor
            sessionEventCount += 1
            commits.append(sessionAttached)

            hostOrder += 1
            failedJournal = configuration.workJournal
            let workAttached = try await workWriter.append(TimelineEventDraft(
                hostSequence: hostOrder,
                causedByEventID: sessionAttached.eventRef,
                session: binding.session,
                work: binding.work,
                workHost: binding.workHost,
                sessionAttachment: binding.sessionAttachment,
                type: TimelineEventType.sessionAttached,
                declaredDomains: [.work, .session],
                payload: .object(["capabilities": .array([])])))
            workCursor = workAttached.cursor
            workEventCount += 1
            commits.append(workAttached)
            failedJournal = nil
        } catch {
            let reason = error.localizedDescription
            try? await sessionWriter.closeChecked()
            try? await workWriter.closeChecked()
            throw RunJournalBundleError.initializationFailed(prefix(reason: reason), reason: reason)
        }

        var closeFailure: Error?
        do { try await sessionWriter.closeChecked() } catch {
            closeFailure = error
            failedJournal = configuration.sessionJournal
        }
        do { try await workWriter.closeChecked() } catch {
            if closeFailure == nil {
                closeFailure = error
                failedJournal = configuration.workJournal
            }
        }
        if let closeFailure {
            let reason = closeFailure.localizedDescription
            throw RunJournalBundleError.closeFailed(prefix(reason: reason), reason: reason)
        }
        guard let sessionCursor, let workCursor else {
            throw RunJournalBundleError.initializationFailed(
                prefix(reason: "idle Work genesis did not produce both cursors"),
                reason: "idle Work genesis did not produce both cursors")
        }
        return IdleWorkCreation(
            binding: binding,
            sessionCursor: sessionCursor,
            workCursor: workCursor,
            commits: commits)
    }

    /// Publish one new Session relationship against an already-created Work.  The two native
    /// writers are held for the whole operation, so a live Run owner cannot race the Work mirror
    /// and a retry can distinguish a complete prefix from a foreign one.  This is deliberately a
    /// recoverable saga rather than an invented cross-file transaction: Session events are written
    /// first, the Work mirror second (unless the Work is terminal), and the final Session cursor
    /// event records the exact Work evidence.  Every prefix is validated before it is continued.
    /// Journal bytes and event records are streamed in bounded chunks, but the current exact
    /// duplicate-identity index and in-memory Work reducer remain proportional to journal history.
    /// This is intentionally described as streaming-but-history-indexed until a durable identity
    /// index and persistent reducer checkpoint can be used here.
    public static func publishSessionAttachment(
        home: AgentHome,
        request: RunJournalBundleSessionPublicationRequest,
        actorID: String,
        actorKind: String = "work-host-control",
        failurePlan: (session: TimelineJournalWriter.FailurePlan,
                      work: TimelineJournalWriter.FailurePlan) = (.none, .none),
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> RunJournalBundleSessionPublication {
        let persistedHost = try home.requirePersistedWorkHost()
        guard request.workHost == persistedHost,
              request.work.workHostID == persistedHost.workHostID,
              request.workJournal == .work(request.work, journalID: "work"),
              request.sessionJournal == .session(
                  request.session, journalID: "session",
                  authority: TimelineAuthorityRef(persistedHost.workHostID)),
              !request.session.sessionID.isEmpty,
              !request.sessionAttachment.attachmentID.isEmpty,
              !request.client.clientID.isEmpty,
              !request.command.commandID.isEmpty,
              request.command.client == request.client,
              request.command.sessionAttachment == request.sessionAttachment,
              request.command.causalCursor == request.causalWorkCursor,
              request.causalWorkCursor.journal == request.workJournal,
              request.causalWorkCursor.sequence >= 0,
              request.causalWorkCursor.sequence < Int.max,
              request.capabilities.count <= 64,
              Set(request.capabilities).count == request.capabilities.count,
              request.capabilities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw RunJournalBundleError.invalidConfiguration(
                "Session publication request contains a foreign or incomplete identity")
        }
        let actor = TimelineActor(actorID: actorID, kind: actorKind)
        guard !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidConfiguration("publication actor identity is empty")
        }
        let sessionURL = home.timelineV2SessionJournalURL(request.session)
        let workURL = home.timelineV2WorkJournalURL(request.work)
        guard FileManager.default.fileExists(atPath: workURL.path) else {
            throw RunJournalBundleError.missingCounterpart(path: workURL.path)
        }

        struct StreamSummary {
            var count = 0
            var last: TimelineEvent?
            var maximumHostSequence = 0
        }

        /// Consume a journal with bounded framing storage. The writer was opened first under the
        /// canonical owner lock, so duplicate IDs, event envelopes, and any recoverable tail have
        /// already been validated by its streaming-but-history-indexed reopen path. This pass
        /// retains only the reducer's state plus the small publication prefix; it never constructs
        /// a Data copy of the file.
        func streamEvents(
            _ url: URL,
            journal: JournalRef,
            onEvent: (TimelineEvent) throws -> Void
        ) throws -> StreamSummary {
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                throw TimelineJournalWriter.WriterError.unavailable(error.localizedDescription)
            }
            defer { try? handle.close() }
            var openedStatus = stat()
            var openedPathStatus = stat()
            let openedPathResult = url.path.withCString { lstat($0, &openedPathStatus) }
            guard fstat(handle.fileDescriptor, &openedStatus) == 0,
                  openedPathResult == 0,
                  openedStatus.st_dev == openedPathStatus.st_dev,
                  openedStatus.st_ino == openedPathStatus.st_ino else {
                throw TimelineJournalWriter.WriterError.dataPathReplaced(path: url.path)
            }
            var parser = TimelineJournalReaderState(
                journal: journal, actor: actor, hostRecordedAt: Date(timeIntervalSince1970: 0))
            var summary = StreamSummary()
            let chunkBytes = 64 * 1_024
            let maximumLineBytes = TimelineJournalWriter.maximumRecordBytes
            var lineLength = 0

            func consume(_ result: TimelineJournalReadResult) throws {
                guard result.quarantinedSuffix == nil else {
                    throw TimelineJournalWriter.WriterError.invalidJournal(
                        reason: "publication journal contains a corrupt interior suffix")
                }
                for record in result.records {
                    // The incremental reader validates journal, sequence, and previous-event
                    // links. Keep the final identity and host ordering without retaining history.
                    try onEvent(record.event)
                    summary.count += 1
                    summary.last = record.event
                    summary.maximumHostSequence = max(
                        summary.maximumHostSequence, record.event.hostSequence ?? 0)
                }
            }

            while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
                for byte in chunk {
                    lineLength += 1
                    guard lineLength <= maximumLineBytes else {
                        throw TimelineJournalWriter.WriterError.invalidJournal(
                            reason: "publication journal line exceeds bounded read limit")
                    }
                    if byte == 0x0A { lineLength = 0 }
                }
                try consume(parser.append(chunk))
            }
            let final = parser.append(Data(), final: true)
            try consume(final)
            guard final.truncatedTail == nil else {
                throw TimelineJournalWriter.WriterError.invalidJournal(
                    reason: "publication journal contains an unterminated tail")
            }
            var finalStatus = stat()
            var finalPathStatus = stat()
            let finalPathResult = url.path.withCString { lstat($0, &finalPathStatus) }
            guard fstat(handle.fileDescriptor, &finalStatus) == 0,
                  finalPathResult == 0,
                  finalStatus.st_dev == finalPathStatus.st_dev,
                  finalStatus.st_ino == finalPathStatus.st_ino else {
                throw TimelineJournalWriter.WriterError.dataPathReplaced(path: url.path)
            }
            return summary
        }

        func caps(_ event: TimelineEvent) -> [String]? {
            guard let values = event.payload["capabilities"]?.arrayValue else { return nil }
            let result = values.compactMap(\ .stringValue)
            return result.count == values.count ? result.sorted() : nil
        }

        func cursor(for event: TimelineEvent, journal: JournalRef) -> JournalCursor {
            JournalCursor(journal: journal, eventID: event.eventID, sequence: event.sequence)
        }

        func commit(_ event: TimelineEvent, journal: JournalRef) -> TimelineJournalCommit {
            TimelineJournalCommit(eventRef: EventRef(journal: journal, eventID: event.eventID),
                                  cursor: cursor(for: event, journal: journal))
        }

        let sessionExists = FileManager.default.fileExists(atPath: sessionURL.path)
        let sessionWriter: TimelineJournalWriter
        do {
            if sessionExists {
                sessionWriter = try TimelineJournalWriter(
                    reopeningStreaming: sessionURL, journal: request.sessionJournal, actor: actor,
                    home: home, allowTruncatedTail: true, failurePlan: failurePlan.session,
                    eventIDProvider: eventIDProvider, now: now)
            } else {
                sessionWriter = try TimelineJournalWriter(
                    freshAt: sessionURL, journal: request.sessionJournal, actor: actor, home: home,
                    failurePlan: failurePlan.session,
                    eventIDProvider: eventIDProvider, now: now)
            }
        } catch let error as TimelineJournalWriter.WriterError {
            throw mapWriterOpenError(error)
        }

        let workWriter: TimelineJournalWriter
        do {
            workWriter = try TimelineJournalWriter(
                reopeningStreaming: workURL, journal: request.workJournal, actor: actor,
                home: home, allowTruncatedTail: true, failurePlan: failurePlan.work,
                eventIDProvider: eventIDProvider, now: now)
        } catch let error as TimelineJournalWriter.WriterError {
            try? await sessionWriter.closeChecked()
            throw mapWriterOpenError(error)
        } catch {
            try? await sessionWriter.closeChecked()
            throw RunJournalBundleError.writer(
                .unavailable(error.localizedDescription))
        }

        func closeWriters() async {
            try? await sessionWriter.closeChecked()
            try? await workWriter.closeChecked()
        }

        do {
            var sessionEvents = [TimelineEvent]()
            let sessionSummary = try streamEvents(sessionURL, journal: request.sessionJournal) { event in
                if sessionEvents.count < 4 { sessionEvents.append(event) }
            }
            guard sessionSummary.count <= 3 else {
                throw RunJournalBundleError.invalidGenesis(
                    journal: request.sessionJournal,
                    reason: "publication source prefix is empty or has extra Session events")
            }
            var workReducer = WorkReducer()
            var workEventsCount = 0
            var workLast: TimelineEvent?
            var terminalEvent: TimelineEvent?
            var existingMirror: TimelineEvent?
            let existingSessionAttach = sessionEvents.dropFirst().first
            let validCommand: (TimelineEvent) -> Bool = { event in
                event.idempotencyKey == request.command.commandID && event.command == request.command
            }
            let validSessionIdentity: (TimelineEvent) -> Bool = { event in
                event.session == request.session && event.work == request.work
                    && event.workHost == request.workHost
                    && event.sessionAttachment == request.sessionAttachment
                    && event.client == request.client
            }
            let workSummary = try streamEvents(workURL, journal: request.workJournal) { event in
                guard event.provenance == .native else {
                    throw RunJournalBundleError.invalidGenesis(
                        journal: request.workJournal, reason: "publication source contains a legacy event")
                }
                workReducer.apply(event)
                workEventsCount += 1
                workLast = event
                if let requestedTerminal = request.terminalEvent,
                   event.eventID == requestedTerminal.eventID,
                   event.journal == requestedTerminal.journal {
                    terminalEvent = event
                }
                if event.type == TimelineEventType.sessionAttached,
                   event.session == request.session, event.work == request.work,
                   event.workHost == request.workHost,
                   event.sessionAttachment == request.sessionAttachment,
                   event.client == request.client,
                   event.causedByEventID == existingSessionAttach.map({ attached in
                       EventRef(journal: request.sessionJournal, eventID: attached.eventID)
                   }), caps(event) == request.capabilities.sorted(), validCommand(event) {
                    existingMirror = event
                }
            }
            guard workEventsCount > 0, workSummary.last != nil else {
                throw RunJournalBundleError.invalidGenesis(
                    journal: request.sessionJournal, reason: "publication source prefix is empty or has extra Session events")
            }
            let workState = workReducer.snapshot
            guard workState.structuralIntegrityValid, workState.semanticProjectionValid,
                  workState.quarantinedEvents.isEmpty,
                  workState.work == request.work, workState.journal == request.workJournal,
                  workState.workHost == request.workHost,
                  let workLast else {
                throw RunJournalBundleError.invalidJournal(
                    journal: request.workJournal, reason: "Work source is not a canonical projection")
            }
            let actualWorkCursor = cursor(for: workLast, journal: request.workJournal)
            let terminal = request.terminalEvent != nil
            let terminalRef = terminalEvent.map { event in
                EventRef(journal: request.workJournal, eventID: event.eventID)
            }
            if terminal {
                guard workState.lifecycle != .active, workState.activeRun == nil,
                      request.terminalEvent == terminalRef,
                      actualWorkCursor == request.causalWorkCursor else {
                    throw RunJournalBundleError.workTerminal(workState.lifecycle)
                }
            } else {
                guard workState.lifecycle == .active, workState.activeRun == nil,
                      workState.activeTurn == nil,
                      actualWorkCursor == request.causalWorkCursor
                          || actualWorkCursor.sequence == request.causalWorkCursor.sequence + 1 else {
                    throw RunJournalBundleError.invalidOperation(
                        "reusable Work cursor changed during Session publication")
                }
            }

            if let created = sessionEvents.first {
                guard created.sequence == 1, created.type == TimelineEventType.sessionCreated,
                      created.session == request.session, created.work == nil,
                      created.workHost == nil, created.client == nil,
                      created.sessionAttachment == nil, created.causedByEventID == nil,
                      created.payload == .object([:]), validCommand(created) else {
                    throw RunJournalBundleError.invalidGenesis(
                        journal: request.sessionJournal,
                        reason: "Session creation event does not match reservation")
                }
            }
            if let attached = sessionEvents.dropFirst().first {
                guard attached.sequence == 2, attached.type == TimelineEventType.sessionAttached,
                      validSessionIdentity(attached), attached.causedByEventID == EventRef(
                          journal: request.sessionJournal, eventID: sessionEvents[0].eventID),
                      caps(attached) == request.capabilities.sorted(), validCommand(attached) else {
                    throw RunJournalBundleError.invalidGenesis(
                        journal: request.sessionJournal,
                        reason: "Session attachment event does not match reservation")
                }
            }
            if let advanced = sessionEvents.dropFirst(2).first {
                let expectedCause = terminalEvent.map {
                    EventRef(journal: request.workJournal, eventID: $0.eventID)
                } ?? EventRef(journal: request.workJournal, eventID: workLast.eventID)
                let advancedCursor: JournalCursor? = advanced.payload["cursor"].flatMap {
                    decodeTimelineValue($0)
                }
                guard sessionEvents.count == 3,
                      advanced.sequence == 3,
                      advanced.type == TimelineEventType.sessionAttachmentCursorAdvanced,
                      validSessionIdentity(advanced), advanced.causedByEventID == expectedCause,
                      caps(advanced) == request.capabilities.sorted(), validCommand(advanced),
                      advancedCursor == actualWorkCursor else {
                    throw RunJournalBundleError.invalidGenesis(
                        journal: request.sessionJournal,
                        reason: "Session cursor evidence does not match Work source")
                }
            }

            let existingSessionAdvanced = sessionEvents.dropFirst(2).first
            if !terminal, let mirror = existingMirror {
                guard actualWorkCursor == cursor(for: mirror, journal: request.workJournal) else {
                    throw RunJournalBundleError.invalidOperation(
                        "Work contains evidence after the Session publication mirror")
                }
            } else if !terminal {
                guard actualWorkCursor == request.causalWorkCursor else {
                    throw RunJournalBundleError.invalidOperation(
                        "Work cursor advanced before this Session publication mirror")
                }
            }
            if terminal { guard existingMirror == nil else {
                throw RunJournalBundleError.invalidOperation("terminal publication has a Work mirror")
            }}
            if !terminal, existingSessionAdvanced != nil, existingMirror == nil {
                throw RunJournalBundleError.invalidGenesis(
                    journal: request.sessionJournal,
                    reason: "Session cursor evidence exists without its Work publication mirror")
            }
            guard sessionEvents.count >= (existingSessionAdvanced == nil ? 0 : 3) else {
                throw RunJournalBundleError.invalidGenesis(
                    journal: request.sessionJournal, reason: "Session prefix is not contiguous")
            }

            var hostOrder = max(sessionSummary.maximumHostSequence, workSummary.maximumHostSequence)
            func nextHostSequence() -> Int { hostOrder += 1; return hostOrder }
            var sessionCreated = sessionEvents.first.map { commit($0, journal: request.sessionJournal) }
            var sessionAttached = existingSessionAttach.map { commit($0, journal: request.sessionJournal) }
            var workMirror = existingMirror.map { commit($0, journal: request.workJournal) }
            var cursorAdvanced = existingSessionAdvanced.map {
                commit($0, journal: request.sessionJournal)
            }

            if sessionCreated == nil {
                sessionCreated = try await sessionWriter.append(TimelineEventDraft(
                    hostSequence: nextHostSequence(), idempotencyKey: request.command.commandID,
                    command: request.command, session: request.session,
                    type: TimelineEventType.sessionCreated, declaredDomains: [.session]))
            }
            if sessionAttached == nil {
                guard let created = sessionCreated else {
                    throw RunJournalBundleError.invalidOperation(
                        "Session attachment has no creation predecessor")
                }
                sessionAttached = try await sessionWriter.append(TimelineEventDraft(
                    hostSequence: nextHostSequence(), idempotencyKey: request.command.commandID,
                    command: request.command, causedByEventID: created.eventRef,
                    session: request.session, work: request.work, workHost: request.workHost,
                    client: request.client, sessionAttachment: request.sessionAttachment,
                    type: TimelineEventType.sessionAttached,
                    declaredDomains: [.session, .work],
                    payload: .object(["capabilities": .array(
                        request.capabilities.sorted().map { .string($0) })])))
            }
            let resultingWorkCursor: JournalCursor
            if terminal {
                resultingWorkCursor = request.causalWorkCursor
            } else if let mirror = workMirror {
                resultingWorkCursor = mirror.cursor
            } else {
                guard let attached = sessionAttached else {
                    throw RunJournalBundleError.invalidOperation(
                        "Work mirror has no Session attachment predecessor")
                }
                workMirror = try await workWriter.append(TimelineEventDraft(
                    hostSequence: nextHostSequence(), idempotencyKey: request.command.commandID,
                    command: request.command, causedByEventID: attached.eventRef,
                    session: request.session, work: request.work, workHost: request.workHost,
                    client: request.client, sessionAttachment: request.sessionAttachment,
                    type: TimelineEventType.sessionAttached,
                    declaredDomains: [.work, .session],
                    payload: .object(["capabilities": .array(
                        request.capabilities.sorted().map { .string($0) })])))
                resultingWorkCursor = workMirror!.cursor
            }
            if cursorAdvanced == nil {
                guard sessionAttached != nil else {
                    throw RunJournalBundleError.invalidOperation(
                        "Session cursor has no attachment predecessor")
                }
                let cause = terminal
                    ? terminalEvent.map { EventRef(journal: request.workJournal, eventID: $0.eventID) }
                    : workMirror?.eventRef
                guard let cause else {
                    throw RunJournalBundleError.invalidOperation(
                        "Session cursor has no Work evidence predecessor")
                }
                cursorAdvanced = try await sessionWriter.append(TimelineEventDraft(
                    hostSequence: nextHostSequence(), idempotencyKey: request.command.commandID,
                    command: request.command, causedByEventID: cause,
                    session: request.session, work: request.work, workHost: request.workHost,
                    client: request.client, sessionAttachment: request.sessionAttachment,
                    type: TimelineEventType.sessionAttachmentCursorAdvanced,
                    declaredDomains: [.session, .work], payload: .object([
                        "capabilities": .array(request.capabilities.sorted().map { .string($0) }),
                        "cursor": encodeTimelineValue(resultingWorkCursor)
                    ])))
            } else {
                guard cursorAdvanced!.cursor == JournalCursor(
                    journal: request.sessionJournal,
                    eventID: cursorAdvanced!.eventRef.eventID,
                    sequence: cursorAdvanced!.cursor.sequence) else {
                    throw RunJournalBundleError.invalidOperation(
                        "Session cursor evidence has a foreign journal")
                }
            }
            guard let created = sessionCreated, let attached = sessionAttached,
                  let advanced = cursorAdvanced else {
                throw RunJournalBundleError.invalidOperation(
                    "Session publication did not produce all evidence")
            }
            try await sessionWriter.closeChecked()
            try await workWriter.closeChecked()
            return RunJournalBundleSessionPublication(
                session: request.session, sessionJournal: request.sessionJournal,
                sessionAttachment: request.sessionAttachment,
                publication: terminal ? "terminal_reference" : "mirrored",
                capabilities: request.capabilities,
                causalSessionCursor: JournalCursor(journal: request.sessionJournal, sequence: 0),
                sessionCursor: advanced.cursor, causalWorkCursor: request.causalWorkCursor,
                resultingWorkCursor: resultingWorkCursor, sessionCreated: created,
                sessionAttached: attached, workMirror: workMirror,
                cursorAdvanced: advanced)
        } catch {
            await closeWriters()
            throw error
        }
    }

    private static func continueIdleWork(
        home: AgentHome,
        binding: WorkBinding,
        actor: TimelineActor,
        configuration: Configuration,
        sessionURL: URL,
        workURL: URL,
        failurePlan: (session: TimelineJournalWriter.FailurePlan,
                      work: TimelineJournalWriter.FailurePlan),
        eventIDProvider: @escaping @Sendable () -> String,
        now: @escaping @Sendable () -> Date
    ) async throws -> IdleWorkCreation {
        let sessionExists = FileManager.default.fileExists(atPath: sessionURL.path)
        let workExists = FileManager.default.fileExists(atPath: workURL.path)
        guard sessionExists || workExists else {
            throw RunJournalBundleError.invalidOperation(
                "idle Work continuation requires a durable journal prefix")
        }
        // The writer opens Session before Work and performs the first Session append before the
        // first Work append. A Work-only file is therefore impossible for this reservation. A
        // Session-only empty file is the one valid one-sided open window; an eventful Session
        // without its Work counterpart is foreign/deleted state and fails closed below.
        guard sessionExists else {
            throw RunJournalBundleError.invalidGenesis(
                journal: configuration.workJournal,
                reason: "idle genesis has a Work journal without its Session counterpart")
        }

        @Sendable func exactEnvelope(
            _ event: TimelineEvent, sequence: Int, hostSequence: Int,
            domains: Set<TimelineDomain>
        ) -> Bool {
            event.sequence == sequence
                && event.hostSequence == hostSequence
                && event.actor == actor
                && event.schemaVersion == TimelineEvent.currentSchemaVersion
                && event.payloadVersion == 1
                && event.idempotencyKey == nil
                && event.command == nil
                && event.parentActivityID == nil
                && event.conversationParent == nil
                && event.client == nil
                && event.clientAttachment == nil
                && event.turn == nil
                && event.action == nil
                && event.handle == nil
                && event.clientTimestamp == nil
                && event.links.isEmpty
                && event.declaredDomains == domains
        }

        // This validator runs inside TimelineJournalWriter's recovery callback, before any
        // unterminated suffix is truncated. It admits only an exact prefix emitted by this
        // reservation; the cross-journal causal/order checks remain below after both writers
        // have been opened.
        @Sendable func validateProducerPrefix(_ data: Data, journal: JournalRef) throws -> Int {
            let read = TimelineJournalReader.read(
                data, journal: journal, actor: actor,
                hostRecordedAt: Date(timeIntervalSince1970: 0))
            guard read.quarantinedSuffix == nil else {
                throw TimelineJournalWriter.WriterError.invalidJournal(
                    reason: "idle genesis contains a corrupt interior suffix")
            }
            let events = read.records.map(\.event)
            guard events.count <= 2 else {
                throw TimelineJournalWriter.WriterError.invalidJournal(
                    reason: "idle genesis prefix contains extra events")
            }
            for (index, event) in events.enumerated() {
                let expectedPrevious = index == 0 ? nil : events[index - 1].eventID
                guard event.previousEventID == expectedPrevious else {
                    throw TimelineJournalWriter.WriterError.invalidJournal(
                        reason: "idle genesis producer chain is not exact")
                }
                if journal == configuration.sessionJournal {
                    if index == 0 {
                        guard exactEnvelope(event, sequence: 1, hostSequence: 1,
                                            domains: [.session]),
                              event.type == TimelineEventType.sessionCreated,
                              event.session == binding.session,
                              event.work == nil,
                              event.workHost == nil,
                              event.run == nil,
                              event.causedByEventID == nil,
                              event.payload == .object([:]) else {
                            throw TimelineJournalWriter.WriterError.invalidJournal(
                                reason: "Session creation prefix does not match reservation")
                        }
                    } else {
                        guard exactEnvelope(event, sequence: 2, hostSequence: 3,
                                            domains: [.session, .work]),
                              event.type == TimelineEventType.sessionAttached,
                              event.session == binding.session,
                              event.work == binding.work,
                              event.workHost == nil,
                              event.sessionAttachment == binding.sessionAttachment,
                              event.run == nil,
                              event.causedByEventID == nil,
                              event.payload == .object(["capabilities": .array([])]) else {
                            throw TimelineJournalWriter.WriterError.invalidJournal(
                                reason: "Session attachment prefix does not match reservation")
                        }
                    }
                } else if journal == configuration.workJournal {
                    if index == 0 {
                        guard exactEnvelope(event, sequence: 1, hostSequence: 2,
                                            domains: [.work]),
                              event.type == TimelineEventType.workCreated,
                              event.work == binding.work,
                              event.workHost == binding.workHost,
                              event.session == nil,
                              event.sessionAttachment == nil,
                              event.run == nil,
                              event.causedByEventID == nil,
                              event.payload == .object([:]) else {
                            throw TimelineJournalWriter.WriterError.invalidJournal(
                                reason: "Work creation prefix does not match reservation")
                        }
                    } else {
                        // The cross-journal predecessor is checked after both files are read;
                        // this local validator still enforces all producer-owned fields.
                        guard exactEnvelope(event, sequence: 2, hostSequence: 4,
                                            domains: [.work, .session]),
                              event.type == TimelineEventType.sessionAttached,
                              event.session == binding.session,
                              event.work == binding.work,
                              event.workHost == binding.workHost,
                              event.sessionAttachment == binding.sessionAttachment,
                              event.run == nil,
                              event.payload == .object(["capabilities": .array([])]) else {
                            throw TimelineJournalWriter.WriterError.invalidJournal(
                                reason: "Work attachment prefix does not match reservation")
                        }
                    }
                } else {
                    throw TimelineJournalWriter.WriterError.invalidJournal(
                        reason: "idle genesis journal is not one of the reservation journals")
                }
            }
            return read.truncatedTail?.byteStart ?? data.count
        }

        // Do not create the missing Work file until the existing one-sided prefix has been
        // proved to be the exact empty Session-open window. In particular, Session event 1 plus
        // no Work file is an impossible crash state for createIdleWork; creating Work first and
        // discovering that fact later would turn a rejected reservation into an accepted retry.
        if !workExists {
            let handle = try FileHandle(forReadingFrom: sessionURL)
            defer { try? handle.close() }
            let maximumGenesisBytes = 256 * 1024
            let data = try handle.read(upToCount: maximumGenesisBytes + 1) ?? Data()
            guard data.count <= maximumGenesisBytes else {
                throw RunJournalBundleError.invalidJournal(
                    journal: configuration.sessionJournal,
                    reason: "idle genesis journal exceeds bounded prefix size")
            }
            let committedByteCount = try validateProducerPrefix(
                data, journal: configuration.sessionJournal)
            guard committedByteCount == data.count, data.isEmpty else {
                throw RunJournalBundleError.invalidGenesis(
                    journal: configuration.sessionJournal,
                    reason: "eventful Session journal has no Work counterpart")
            }
        }

        let sessionWriter: TimelineJournalWriter
        do {
            if sessionExists {
                sessionWriter = try TimelineJournalWriter(
                    reopening: sessionURL, journal: configuration.sessionJournal,
                    actor: actor, home: home,
                    recoveryCommittedByteCount: { data in
                        try validateProducerPrefix(data, journal: configuration.sessionJournal)
                    },
                    failurePlan: failurePlan.session,
                    eventIDProvider: eventIDProvider, now: now)
            } else {
                sessionWriter = try TimelineJournalWriter(
                    freshAt: sessionURL, journal: configuration.sessionJournal,
                    actor: actor, home: home, failurePlan: failurePlan.session,
                    eventIDProvider: eventIDProvider, now: now)
            }
        } catch let error as TimelineJournalWriter.WriterError {
            throw mapWriterOpenError(error)
        }

        let workWriter: TimelineJournalWriter
        do {
            if workExists {
                workWriter = try TimelineJournalWriter(
                    reopening: workURL, journal: configuration.workJournal,
                    actor: actor, home: home,
                    recoveryCommittedByteCount: { data in
                        try validateProducerPrefix(data, journal: configuration.workJournal)
                    },
                    failurePlan: failurePlan.work,
                    eventIDProvider: eventIDProvider, now: now)
            } else {
                workWriter = try TimelineJournalWriter(
                    freshAt: workURL, journal: configuration.workJournal,
                    actor: actor, home: home, failurePlan: failurePlan.work,
                    eventIDProvider: eventIDProvider, now: now)
            }
        } catch let error as TimelineJournalWriter.WriterError {
            try? await sessionWriter.closeChecked()
            throw mapWriterOpenError(error)
        }

        let readPrefix: (URL, JournalRef) throws -> [TimelineEvent] = { url, journal in
            // Genesis has at most two tiny events per file. Read one bounded sentinel byte over
            // the allowed envelope so a corrupt/hostile path cannot make recovery allocate an
            // unbounded Data buffer before the producer-prefix validator runs.
            let maximumGenesisBytes = 256 * 1024
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumGenesisBytes + 1) ?? Data()
            guard data.count <= maximumGenesisBytes else {
                throw RunJournalBundleError.invalidJournal(
                    journal: journal, reason: "idle genesis journal exceeds bounded prefix size")
            }
            let committedByteCount = try validateProducerPrefix(data, journal: journal)
            guard committedByteCount == data.count else {
                throw RunJournalBundleError.invalidJournal(
                    journal: journal, reason: "idle genesis prefix remains truncated")
            }
            let read = TimelineJournalReader.read(
                data, journal: journal, actor: actor,
                hostRecordedAt: Date(timeIntervalSince1970: 0))
            return read.records.map(\.event)
        }

        var continuationFailedJournal: JournalRef?
        do {
            let sessionEvents = try readPrefix(sessionURL, configuration.sessionJournal)
            let workEvents = try readPrefix(workURL, configuration.workJournal)
            guard sessionEvents.count <= 2, workEvents.count <= 2 else {
                throw RunJournalBundleError.invalidGenesis(
                    journal: configuration.workJournal,
                    reason: "idle genesis prefix contains extra events")
            }
            guard sessionEvents.allSatisfy({ $0.provenance == .native }),
                  workEvents.allSatisfy({ $0.provenance == .native }) else {
                throw RunJournalBundleError.invalidGenesis(
                    journal: configuration.workJournal,
                    reason: "idle genesis prefix contains a legacy event")
            }
            if let created = sessionEvents.first {
                guard exactEnvelope(created, sequence: 1, hostSequence: 1,
                                    domains: [.session]),
                      created.type == TimelineEventType.sessionCreated,
                      created.session == binding.session,
                      created.work == nil,
                      created.workHost == nil,
                      created.run == nil,
                      created.causedByEventID == nil,
                      created.payload == .object([:]),
                      created.previousEventID == nil else {
                    throw RunJournalBundleError.invalidGenesis(
                        journal: configuration.sessionJournal,
                        reason: "Session prefix does not begin with this reservation's creation")
                }
            }
            if let attached = sessionEvents.dropFirst().first {
                guard sessionEvents.count == 2,
                      exactEnvelope(attached, sequence: 2, hostSequence: 3,
                                    domains: [.session, .work]),
                      attached.type == TimelineEventType.sessionAttached,
                      attached.session == binding.session,
                      attached.work == binding.work,
                      attached.workHost == nil,
                      attached.sessionAttachment == binding.sessionAttachment,
                      attached.run == nil,
                      attached.causedByEventID == nil,
                      attached.payload == .object(["capabilities": .array([])]) else {
                    throw RunJournalBundleError.invalidGenesis(
                        journal: configuration.sessionJournal,
                        reason: "Session attachment prefix does not match reservation")
                }
            }
            if let created = workEvents.first {
                guard exactEnvelope(created, sequence: 1, hostSequence: 2,
                                    domains: [.work]),
                      created.type == TimelineEventType.workCreated,
                      created.work == binding.work,
                      created.workHost == binding.workHost,
                      created.session == nil,
                      created.sessionAttachment == nil,
                      created.run == nil,
                      created.causedByEventID == nil,
                      created.payload == .object([:]),
                      created.previousEventID == nil else {
                    throw RunJournalBundleError.invalidGenesis(
                        journal: configuration.workJournal,
                        reason: "Work prefix does not begin with this reservation's creation")
                }
            }
            if let attached = workEvents.dropFirst().first {
                guard workEvents.count == 2,
                      exactEnvelope(attached, sequence: 2, hostSequence: 4,
                                    domains: [.work, .session]),
                      attached.type == TimelineEventType.sessionAttached,
                      attached.session == binding.session,
                      attached.work == binding.work,
                      attached.workHost == binding.workHost,
                      attached.sessionAttachment == binding.sessionAttachment,
                      attached.run == nil,
                      let sessionAttach = sessionEvents.dropFirst().first,
                      attached.causedByEventID == EventRef(
                          journal: configuration.sessionJournal,
                          eventID: sessionAttach.eventID),
                      attached.payload == .object(["capabilities": .array([])]) else {
                    throw RunJournalBundleError.invalidGenesis(
                        journal: configuration.workJournal,
                        reason: "Work attachment prefix does not match Session attachment")
                }
            }
            // Only the global append prefixes emitted by createIdleWork are admitted. This
            // rejects an impossible work-only prefix and any pair whose order skipped a suffix.
            guard sessionEvents.count >= workEvents.count,
                  sessionEvents.count <= workEvents.count + 1,
                  !(workEvents.count == 0 && sessionEvents.count == 2) else {
                throw RunJournalBundleError.invalidGenesis(
                    journal: configuration.workJournal,
                    reason: "journal files are not one exact idle genesis prefix")
            }
            guard workExists || sessionEvents.isEmpty else {
                throw RunJournalBundleError.invalidGenesis(
                    journal: configuration.sessionJournal,
                    reason: "eventful Session journal has no Work counterpart")
            }

            var sessionCursor = sessionEvents.last.map {
                JournalCursor(journal: configuration.sessionJournal,
                              eventID: $0.eventID, sequence: $0.sequence)
            }
            var workCursor = workEvents.last.map {
                JournalCursor(journal: configuration.workJournal,
                              eventID: $0.eventID, sequence: $0.sequence)
            }
            var hostOrder = max(
                sessionEvents.compactMap(\.hostSequence).max() ?? 0,
                workEvents.compactMap(\.hostSequence).max() ?? 0)
            var sessionEventCount = sessionEvents.count
            var workEventCount = workEvents.count
            var commits: [TimelineJournalCommit] = []
            if sessionEvents.isEmpty {
                hostOrder += 1
                continuationFailedJournal = configuration.sessionJournal
                let created = try await sessionWriter.append(TimelineEventDraft(
                    hostSequence: hostOrder, session: binding.session,
                    type: TimelineEventType.sessionCreated,
                    declaredDomains: [.session]))
                sessionCursor = created.cursor
                sessionEventCount += 1
                commits.append(created)
            }
            if workEvents.isEmpty {
                hostOrder += 1
                continuationFailedJournal = configuration.workJournal
                let created = try await workWriter.append(TimelineEventDraft(
                    hostSequence: hostOrder, work: binding.work,
                    workHost: binding.workHost, type: TimelineEventType.workCreated,
                    declaredDomains: [.work]))
                workCursor = created.cursor
                workEventCount += 1
                commits.append(created)
            }
            var sessionAttachEventID = sessionEvents.dropFirst().first?.eventID
            if sessionAttachEventID == nil {
                hostOrder += 1
                continuationFailedJournal = configuration.sessionJournal
                let attached = try await sessionWriter.append(TimelineEventDraft(
                    hostSequence: hostOrder, session: binding.session, work: binding.work,
                    sessionAttachment: binding.sessionAttachment,
                    type: TimelineEventType.sessionAttached,
                    declaredDomains: [.session, .work],
                    payload: .object(["capabilities": .array([])])))
                sessionCursor = attached.cursor
                sessionEventCount += 1
                sessionAttachEventID = attached.eventRef.eventID
                commits.append(attached)
            }
            if workEvents.count < 2 {
                guard let sessionAttachEventID else {
                    throw RunJournalBundleError.invalidGenesis(
                        journal: configuration.sessionJournal,
                        reason: "Work attachment has no Session attachment predecessor")
                }
                hostOrder += 1
                continuationFailedJournal = configuration.workJournal
                let attached = try await workWriter.append(TimelineEventDraft(
                    hostSequence: hostOrder,
                    causedByEventID: EventRef(
                        journal: configuration.sessionJournal,
                        eventID: sessionAttachEventID),
                    session: binding.session, work: binding.work,
                    workHost: binding.workHost,
                    sessionAttachment: binding.sessionAttachment,
                    type: TimelineEventType.sessionAttached,
                    declaredDomains: [.work, .session],
                    payload: .object(["capabilities": .array([])])))
                workCursor = attached.cursor
                workEventCount += 1
                commits.append(attached)
            }

            do {
                continuationFailedJournal = configuration.sessionJournal
                try await sessionWriter.closeChecked()
                continuationFailedJournal = configuration.workJournal
                try await workWriter.closeChecked()
                continuationFailedJournal = nil
            } catch {
                throw RunJournalBundleError.closeFailed(
                    RunJournalBundlePrefix(
                        sessionCursor: sessionCursor, workCursor: workCursor,
                        sessionEventCount: sessionEventCount, workEventCount: workEventCount,
                        hostOrder: hostOrder, failedJournal: continuationFailedJournal,
                        failureReason: error.localizedDescription),
                    reason: error.localizedDescription)
            }
            guard let sessionCursor, let workCursor else {
                throw RunJournalBundleError.initializationFailed(
                    RunJournalBundlePrefix(
                        sessionCursor: sessionCursor, workCursor: workCursor,
                        sessionEventCount: 0, workEventCount: 0, hostOrder: hostOrder,
                        failedJournal: configuration.workJournal,
                        failureReason: "idle genesis continuation has no cursors"),
                    reason: "idle genesis continuation has no cursors")
            }
            let finalSessionEvents = try readPrefix(sessionURL, configuration.sessionJournal)
            let finalWorkEvents = try readPrefix(workURL, configuration.workJournal)
            var commitsWithHostSequence: [(Int, TimelineJournalCommit)] = []
            commitsWithHostSequence.reserveCapacity(
                finalSessionEvents.count + finalWorkEvents.count)
            for event in finalSessionEvents {
                guard let hostSequence = event.hostSequence else {
                    throw RunJournalBundleError.invalidGenesis(
                        journal: configuration.sessionJournal,
                        reason: "idle genesis event has no host sequence")
                }
                commitsWithHostSequence.append((hostSequence, TimelineJournalCommit(
                    eventRef: EventRef(journal: configuration.sessionJournal,
                                       eventID: event.eventID),
                    cursor: JournalCursor(journal: configuration.sessionJournal,
                                          eventID: event.eventID, sequence: event.sequence))))
            }
            for event in finalWorkEvents {
                guard let hostSequence = event.hostSequence else {
                    throw RunJournalBundleError.invalidGenesis(
                        journal: configuration.workJournal,
                        reason: "idle genesis event has no host sequence")
                }
                commitsWithHostSequence.append((hostSequence, TimelineJournalCommit(
                    eventRef: EventRef(journal: configuration.workJournal,
                                       eventID: event.eventID),
                    cursor: JournalCursor(journal: configuration.workJournal,
                                          eventID: event.eventID, sequence: event.sequence))))
            }
            commitsWithHostSequence.sort { $0.0 < $1.0 }
            guard commitsWithHostSequence.map(\.0) == Array(1...4) else {
                throw RunJournalBundleError.invalidGenesis(
                    journal: configuration.workJournal,
                    reason: "idle genesis host sequence is not exactly 1 through 4")
            }
            let allCommits = commitsWithHostSequence.map(\.1)
            return IdleWorkCreation(
                binding: binding, sessionCursor: sessionCursor, workCursor: workCursor,
                commits: allCommits)
        } catch {
            try? await sessionWriter.closeChecked()
            try? await workWriter.closeChecked()
            if let bundleError = error as? RunJournalBundleError {
                throw bundleError
            }
            let sessionEvents = try? readPrefix(sessionURL, configuration.sessionJournal)
            let workEvents = try? readPrefix(workURL, configuration.workJournal)
            let sessionCursor = sessionEvents?.last.map {
                JournalCursor(journal: configuration.sessionJournal,
                              eventID: $0.eventID, sequence: $0.sequence)
            }
            let workCursor = workEvents?.last.map {
                JournalCursor(journal: configuration.workJournal,
                              eventID: $0.eventID, sequence: $0.sequence)
            }
            let sessionCount = sessionEvents?.count ?? 0
            let workCount = workEvents?.count ?? 0
            let hostOrder = max(
                sessionEvents?.compactMap(\.hostSequence).max() ?? 0,
                workEvents?.compactMap(\.hostSequence).max() ?? 0)
            throw RunJournalBundleError.initializationFailed(
                RunJournalBundlePrefix(
                    sessionCursor: sessionCursor, workCursor: workCursor,
                    sessionEventCount: sessionCount, workEventCount: workCount,
                    hostOrder: hostOrder, failedJournal: continuationFailedJournal,
                    failureReason: error.localizedDescription),
                reason: error.localizedDescription)
        }
    }

    /// Open the one native journal pair owned by an existing launch identity.
    ///
    /// Fresh and resumed execution deliberately share this entry point. If neither journal
    /// exists, it creates the Session/Work attachment before any runtime effect. If both exist,
    /// it discovers the already-durable attachment and cold-reopens it with the new Run identity.
    /// One-sided pairs are refused rather than repaired or silently replaced.
    ///
    /// The local Work Host is the initial Session authority as well as the Work authority. That
    /// is an explicit bootstrap policy, not an identity collapse: the journals retain distinct
    /// owners and a future Session service can supply a different authority without changing the
    /// execution-facing API.
    public static func openForExecution(
        home: AgentHome,
        identity: SessionWorkIdentity,
        actorID: String,
        actorKind: String = "work-host",
        modelID: String? = nil,
        makeAttachmentID: @escaping @Sendable () -> String = {
            "attachment-\(UUID().uuidString.lowercased())"
        },
        failurePlan: (session: TimelineJournalWriter.FailurePlan,
                      work: TimelineJournalWriter.FailurePlan) = (.none, .none),
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> RunJournalBundle {
        let persistedHost = try home.requirePersistedWorkHost()
        guard identity.workHostID == persistedHost.workHostID else {
            throw RunJournalBundleError.invalidConfiguration(
                "the launch Work Host does not match this AgentHome's persisted authority")
        }
        guard !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidConfiguration("the launch actor identity is empty")
        }

        let session = SessionRef(identity.sessionID)
        let work = identity.work
        let run = RunRef(identity.runID)
        let authority = TimelineAuthorityRef(persistedHost.workHostID)
        let actor = TimelineActor(actorID: actorID, kind: actorKind)
        let sessionURL = home.timelineV2SessionJournalURL(session)
        let workURL = home.timelineV2WorkJournalURL(work)
        let sessionExists = FileManager.default.fileExists(atPath: sessionURL.path)
        let workExists = FileManager.default.fileExists(atPath: workURL.path)

        guard sessionExists == workExists else {
            throw RunJournalBundleError.missingCounterpart(
                path: (!sessionExists ? sessionURL : workURL).path)
        }
        if !sessionExists {
            let attachment = SessionAttachmentRef(makeAttachmentID())
            return try await createFresh(
                home: home, session: session, work: work, workHost: persistedHost,
                sessionAuthority: authority, sessionAttachment: attachment, run: run,
                actor: actor, modelID: modelID, failurePlan: failurePlan,
                eventIDProvider: eventIDProvider, now: now)
        }

        let configuration = try makeConfiguration(
            session: session, work: work, workHost: persistedHost,
            sessionAuthority: authority, sessionAttachment: SessionAttachmentRef("discovery"),
            run: run)
        let sessionEvents = try readNativeJournal(
            at: sessionURL, journal: configuration.sessionJournal, actor: actor)
        let workEvents = try readNativeJournal(
            at: workURL, journal: configuration.workJournal, actor: actor)
        let sessionAttachments = Set(sessionEvents.compactMap { event -> SessionAttachmentRef? in
            guard event.type == TimelineEventType.sessionAttached,
                  event.session == session, event.work == work else { return nil }
            return event.sessionAttachment
        })
        let workAttachments = Set(workEvents.compactMap { event -> SessionAttachmentRef? in
            guard event.type == TimelineEventType.sessionAttached,
                  event.session == session, event.work == work else { return nil }
            return event.sessionAttachment
        })
        guard sessionAttachments.count == 1,
              sessionAttachments == workAttachments,
              let attachment = sessionAttachments.first else {
            throw RunJournalBundleError.invalidGenesis(
                journal: configuration.sessionJournal,
                reason: "the existing Session/Work pair does not identify one mirrored attachment")
        }
        return try await reopen(
            home: home, session: session, work: work, workHost: persistedHost,
            sessionAuthority: authority, sessionAttachment: attachment, run: run,
            actor: actor, modelID: modelID, failurePlan: failurePlan,
            eventIDProvider: eventIDProvider, now: now)
    }

    /// Start one new execution generation against a separately created idle Work binding.
    /// Unlike the combined launch helper above, this API cannot create Work as a side effect.
    public static func openForExecution(
        home: AgentHome,
        binding: WorkRunBinding,
        actorID: String,
        actorKind: String = "work-host",
        modelID: String? = nil,
        failurePlan: (session: TimelineJournalWriter.FailurePlan,
                      work: TimelineJournalWriter.FailurePlan) = (.none, .none),
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> RunJournalBundle {
        let persistedHost = try home.requirePersistedWorkHost()
        let workBinding = binding.workBinding
        guard workBinding.workHost == persistedHost,
              workBinding.work.workHostID == persistedHost.workHostID else {
            throw RunJournalBundleError.invalidConfiguration(
                "the execution Work binding does not belong to this AgentHome's persisted authority")
        }
        guard !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidConfiguration(
                "the execution actor identity is empty")
        }
        let configuration = try makeConfiguration(
            session: workBinding.session, work: workBinding.work,
            workHost: workBinding.workHost,
            sessionAuthority: TimelineAuthorityRef(workBinding.workHost.workHostID),
            sessionAttachment: workBinding.sessionAttachment, run: binding.run)
        let actor = TimelineActor(actorID: actorID, kind: actorKind)
        let workEvents = try readNativeJournal(
            at: home.timelineV2WorkJournalURL(workBinding.work),
            journal: configuration.workJournal, actor: actor)
        let workState = WorkReducer.reduce(workEvents)
        // If the host died after the marker but before the first Start command, the marker is a
        // recoverable reservation only while it is the exact Work tail and no runtime effect has
        // been recorded. Reopen that exact Run without manufacturing a second run.started event.
        let recoverStartedRun = workState.activeRun == binding.run
            && workState.activeTurn == nil
            && workState.activeActionIDs.isEmpty
            && workEvents.count >= 2
            && workEvents.last?.type == TimelineEventType.runStarted
            && workEvents.last?.run == binding.run
        return try await reopen(
            home: home,
            session: workBinding.session,
            work: workBinding.work,
            workHost: workBinding.workHost,
            sessionAuthority: TimelineAuthorityRef(workBinding.workHost.workHostID),
            sessionAttachment: workBinding.sessionAttachment,
            run: binding.run,
            actor: actor,
            modelID: modelID,
            failurePlan: failurePlan,
            eventIDProvider: eventIDProvider,
            now: now,
            recoverStartedRun: recoverStartedRun)
    }

    /// Open and lock both journals before writing the first semantic event.
    public static func createFresh(
        home: AgentHome,
        session: SessionRef,
        work: WorkRef,
        workHost: WorkHostRef,
        sessionAuthority: TimelineAuthorityRef,
        sessionAttachment: SessionAttachmentRef,
        run: RunRef,
        actor: TimelineActor,
        modelID: String? = nil,
        failurePlan: (session: TimelineJournalWriter.FailurePlan,
                      work: TimelineJournalWriter.FailurePlan) = (.none, .none),
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> RunJournalBundle {
        let configuration = try makeConfiguration(
            session: session, work: work, workHost: workHost,
            sessionAuthority: sessionAuthority, sessionAttachment: sessionAttachment, run: run)
        let sessionURL = home.timelineV2SessionJournalURL(session)
        let workURL = home.timelineV2WorkJournalURL(work)

        let sessionWriter: TimelineJournalWriter
        do {
            sessionWriter = try TimelineJournalWriter(
                freshAt: sessionURL, journal: configuration.sessionJournal, actor: actor,
                home: home, failurePlan: failurePlan.session,
                eventIDProvider: eventIDProvider, now: now)
        } catch let error as TimelineJournalWriter.WriterError {
            throw mapWriterOpenError(error)
        }
        let workWriter: TimelineJournalWriter
        do {
            workWriter = try TimelineJournalWriter(
                freshAt: workURL, journal: configuration.workJournal, actor: actor,
                home: home, failurePlan: failurePlan.work,
                eventIDProvider: eventIDProvider, now: now)
        } catch let error as TimelineJournalWriter.WriterError {
            try? await sessionWriter.closeChecked()
            throw RunJournalBundleError.initializationFailed(
                RunJournalBundlePrefix(sessionCursor: nil, workCursor: nil,
                                       sessionEventCount: 0, workEventCount: 0, hostOrder: 0,
                                       failedJournal: configuration.workJournal,
                                       failureReason: error.localizedDescription),
                reason: error.localizedDescription)
        }

        let bundle = RunJournalBundle(
            session: session, work: work, workHost: workHost,
            sessionJournal: configuration.sessionJournal, workJournal: configuration.workJournal,
            sessionAttachment: sessionAttachment, run: run,
            actor: actor,
            contextBodyStore: ContextBodyStore(home: home),
            sessionWriter: sessionWriter, workWriter: workWriter,
            sessionCursor: nil, workCursor: nil, sessionEventCount: 0, workEventCount: 0,
            hostOrder: 0, activeRun: run, authoredAttention: .none)
        do {
            try await bundle.appendFreshGenesis(modelID: modelID)
            return bundle
        } catch {
            let prefix = await bundle.status.durablePrefix
            try? await bundle.closeChecked()
            if let bundleError = error as? RunJournalBundleError,
               case .initializationFailed = bundleError {
                throw bundleError
            }
            throw RunJournalBundleError.initializationFailed(prefix, reason: error.localizedDescription)
        }
    }

    /// Reopen both native journals, reject an incomplete pair or unfinished action, then append
    /// a new run marker at each writer's next sequence. Existing bytes are never repaired.
    public static func reopen(
        home: AgentHome,
        session: SessionRef,
        work: WorkRef,
        workHost: WorkHostRef,
        sessionAuthority: TimelineAuthorityRef,
        sessionAttachment: SessionAttachmentRef,
        run: RunRef,
        actor: TimelineActor,
        modelID: String? = nil,
        failurePlan: (session: TimelineJournalWriter.FailurePlan,
                      work: TimelineJournalWriter.FailurePlan) = (.none, .none),
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() },
        recoverStartedRun: Bool = false
    ) async throws -> RunJournalBundle {
        try await openExisting(
            home: home, session: session, work: work, workHost: workHost,
            sessionAuthority: sessionAuthority, sessionAttachment: sessionAttachment, run: run,
            actor: actor, modelID: modelID, startsRun: true,
            recoverStartedRun: recoverStartedRun,
            failurePlan: failurePlan, eventIDProvider: eventIDProvider, now: now)
    }

    /// Open one idle Session/Work pair solely to commit an explicit Work terminal
    /// transition. Unlike ``reopen``, this does not append `run.started`: completion and
    /// destruction happen after the execution Run has ended, and must not manufacture another
    /// Run merely to obtain the two canonical writer locks.
    /// Exact lost-response reconciliation uses ``readTerminalCommit`` and never acquires a writer.
    public static func openForTerminalMutation(
        home: AgentHome,
        identity: SessionWorkIdentity,
        sessionAttachment: SessionAttachmentRef,
        actorID: String,
        actorKind: String = "work-host-terminal",
        failurePlan: (session: TimelineJournalWriter.FailurePlan,
                      work: TimelineJournalWriter.FailurePlan) = (.none, .none),
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> RunJournalBundle {
        let persistedHost = try home.requirePersistedWorkHost()
        guard identity.workHostID == persistedHost.workHostID else {
            throw RunJournalBundleError.invalidConfiguration(
                "the terminal Work Host does not match this AgentHome's persisted authority")
        }
        guard !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidConfiguration("the terminal actor identity is empty")
        }
        return try await openExisting(
            home: home,
            session: SessionRef(identity.sessionID),
            work: identity.work,
            workHost: persistedHost,
            sessionAuthority: TimelineAuthorityRef(persistedHost.workHostID),
            sessionAttachment: sessionAttachment,
            run: RunRef(identity.runID),
            actor: TimelineActor(actorID: actorID, kind: actorKind),
            modelID: nil,
            startsRun: false,
            failurePlan: failurePlan,
            eventIDProvider: eventIDProvider,
            now: now)
    }

    /// Terminal mutation variant for callers that already carry the split Work/Run binding.
    public static func openForTerminalMutation(
        home: AgentHome,
        binding: WorkRunBinding,
        actorID: String,
        actorKind: String = "work-host-terminal",
        failurePlan: (session: TimelineJournalWriter.FailurePlan,
                      work: TimelineJournalWriter.FailurePlan) = (.none, .none),
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> RunJournalBundle {
        let workBinding = binding.workBinding
        let persistedHost = try home.requirePersistedWorkHost()
        guard workBinding.workHost == persistedHost,
              workBinding.work.workHostID == persistedHost.workHostID else {
            throw RunJournalBundleError.invalidConfiguration(
                "the terminal Work binding does not belong to this AgentHome's persisted authority")
        }
        guard !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidConfiguration("the terminal actor identity is empty")
        }
        return try await openExisting(
            home: home,
            session: workBinding.session,
            work: workBinding.work,
            workHost: workBinding.workHost,
            sessionAuthority: TimelineAuthorityRef(workBinding.workHost.workHostID),
            sessionAttachment: workBinding.sessionAttachment,
            run: binding.run,
            actor: TimelineActor(actorID: actorID, kind: actorKind),
            modelID: nil,
            startsRun: false,
            failurePlan: failurePlan,
            eventIDProvider: eventIDProvider,
            now: now)
    }

    private static func openExisting(
        home: AgentHome,
        session: SessionRef,
        work: WorkRef,
        workHost: WorkHostRef,
        sessionAuthority: TimelineAuthorityRef,
        sessionAttachment: SessionAttachmentRef,
        run: RunRef,
        actor: TimelineActor,
        modelID: String?,
        startsRun: Bool,
        recoverStartedRun: Bool = false,
        failurePlan: (session: TimelineJournalWriter.FailurePlan,
                      work: TimelineJournalWriter.FailurePlan),
        eventIDProvider: @escaping @Sendable () -> String,
        now: @escaping @Sendable () -> Date
    ) async throws -> RunJournalBundle {
        let configuration = try makeConfiguration(
            session: session, work: work, workHost: workHost,
            sessionAuthority: sessionAuthority, sessionAttachment: sessionAttachment, run: run)
        let sessionURL = home.timelineV2SessionJournalURL(session)
        let workURL = home.timelineV2WorkJournalURL(work)
        let sessionExists = FileManager.default.fileExists(atPath: sessionURL.path)
        let workExists = FileManager.default.fileExists(atPath: workURL.path)
        guard sessionExists && workExists else {
            throw RunJournalBundleError.missingCounterpart(
                path: (!sessionExists ? sessionURL : workURL).path)
        }

        let sessionWriter: TimelineJournalWriter
        do {
            sessionWriter = try TimelineJournalWriter(
                reopening: sessionURL, journal: configuration.sessionJournal, actor: actor,
                home: home, failurePlan: failurePlan.session,
                eventIDProvider: eventIDProvider, now: now)
        } catch let error as TimelineJournalWriter.WriterError {
            throw mapWriterOpenError(error)
        }
        let workWriter: TimelineJournalWriter
        do {
            workWriter = try TimelineJournalWriter(
                reopening: workURL, journal: configuration.workJournal, actor: actor,
                home: home, failurePlan: failurePlan.work,
                eventIDProvider: eventIDProvider, now: now)
        } catch let error as TimelineJournalWriter.WriterError {
            try? await sessionWriter.closeChecked()
            throw mapWriterOpenError(error)
        }

        do {
            let sessionEvents = try readNativeJournal(
                at: sessionURL, journal: configuration.sessionJournal, actor: actor)
            let workEvents = try readNativeJournal(
                at: workURL, journal: configuration.workJournal, actor: actor)
            let sessionState = SessionReducer.reduce(sessionEvents)
            let workState = WorkReducer.reduce(workEvents)
            try validateGenesis(
                sessionEvents, journal: configuration.sessionJournal,
                expectedType: TimelineEventType.sessionCreated)
            try validateGenesis(
                workEvents, journal: configuration.workJournal,
                expectedType: TimelineEventType.workCreated)
            guard sessionState.structuralIntegrityValid && sessionState.semanticProjectionValid else {
                throw RunJournalBundleError.invalidJournal(
                    journal: configuration.sessionJournal,
                    reason: sessionState.corruptionReasons.joined(separator: "; "))
            }
            guard workState.structuralIntegrityValid && workState.semanticProjectionValid else {
                throw RunJournalBundleError.invalidJournal(
                    journal: configuration.workJournal,
                    reason: workState.corruptionReasons.joined(separator: "; "))
            }
            let unfinished = workState.actions.values
                .filter { !$0.state.isTerminal }
                .map { $0.action.actionID }
                .sorted()
            guard unfinished.isEmpty else {
                throw RunJournalBundleError.unfinishedActions(unfinished)
            }
            if recoverStartedRun {
                guard startsRun,
                      workState.activeRun == run,
                      workState.activeTurn == nil,
                      workState.activeActionIDs.isEmpty,
                      workEvents.count >= 2,
                      workEvents.last?.type == TimelineEventType.runStarted,
                      workEvents.last?.run == run else {
                    throw RunJournalBundleError.invalidOperation(
                        "only an untouched trailing run.started marker can be recovered")
                }
            } else {
                guard workState.activeRun == nil, workState.activeTurn == nil else {
                    throw RunJournalBundleError.invalidOperation(
                        "the previous Run is still active; finish it before cold resume")
                }
            }
            guard workState.lifecycle == .active else {
                throw RunJournalBundleError.workTerminal(workState.lifecycle)
            }
            if startsRun && !recoverStartedRun {
                guard !workEvents.contains(where: { $0.run?.runID == run.runID }) else {
                    throw RunJournalBundleError.invalidOperation(
                        "the replacement Run identity already appears in the Work journal")
                }
            } else if !recoverStartedRun {
                let startedRuns = workEvents.compactMap { event -> RunRef? in
                    guard event.type == TimelineEventType.runStarted else { return nil }
                    return event.run
                }
                guard startedRuns.last == run else {
                    throw RunJournalBundleError.invalidOperation(
                        "terminal mutation requires the latest canonical Run generation")
                }
                guard workEvents.contains(where: {
                    $0.type == TimelineEventType.runFinished && $0.run == run
                }) else {
                    throw RunJournalBundleError.invalidOperation(
                        "terminal mutation requires a canonically finished Run")
                }
            }
            try validatePairedAttachment(
                sessionEvents: sessionEvents, workEvents: workEvents,
                session: session, work: work, attachment: sessionAttachment,
                sessionJournal: configuration.sessionJournal)

            let sessionCursor = cursor(for: sessionEvents.last, journal: configuration.sessionJournal)
            let workCursor = cursor(for: workEvents.last, journal: configuration.workJournal)
            let runStartPredecessorCursor: JournalCursor? = {
                // Both a fresh service Start and an exact restart retry cross the same marker
                // boundary. Preserve the cursor observed immediately before that marker so the
                // first Start command can bridge its caller's pre-open cursor. A terminal reopen
                // never admits a Run and therefore has no such bridge.
                guard (startsRun || recoverStartedRun) else { return nil }
                let predecessor = recoverStartedRun
                    ? workEvents.dropLast().last : workEvents.last
                guard let predecessor else {
                    return nil
                }
                return cursor(for: predecessor, journal: configuration.workJournal)
            }()
            let hostOrder = max(
                sessionEvents.compactMap(\.hostSequence).max() ?? 0,
                workEvents.compactMap(\.hostSequence).max() ?? 0)
            let bundle = RunJournalBundle(
                session: session, work: work, workHost: workHost,
                sessionJournal: configuration.sessionJournal, workJournal: configuration.workJournal,
                sessionAttachment: sessionAttachment, run: run,
                actor: actor,
                contextBodyStore: ContextBodyStore(home: home),
                sessionWriter: sessionWriter, workWriter: workWriter,
                sessionCursor: sessionCursor, workCursor: workCursor,
                sessionEventCount: sessionEvents.count, workEventCount: workEvents.count,
                hostOrder: hostOrder,
                seenActionIDs: Set(workState.actions.keys),
                seenArtifactIDs: Set(workEvents.compactMap(Self.artifactIdentity(from:))),
                commands: workState.commands,
                commandAcceptedRefs: workEvents.reduce(into: [String: EventRef]()) { refs, event in
                    guard event.type == TimelineEventType.commandAccepted,
                          let command = event.command,
                          refs[command.commandID] == nil else { return }
                    refs[command.commandID] = EventRef(
                        journal: configuration.workJournal, eventID: event.eventID)
                },
                activeTurn: workState.activeTurn,
                activeRun: (startsRun || recoverStartedRun) ? run : nil,
                runStartPredecessorCursor: runStartPredecessorCursor,
                workLifecycle: workState.lifecycle,
                lastMessage: sessionState.semanticTip ?? sessionState.messageHistory.last.map {
                    EventRef(journal: configuration.sessionJournal, eventID: $0.eventID)
                },
                authoredAttention: sessionState.attention,
                contextDeliveredBytesByRun:
                    sessionState.contextCumulativeDeliveredBytesByRun ?? [:])
            if startsRun && !recoverStartedRun {
                do {
                    try await bundle.appendRunStarted(modelID: modelID ?? workState.modelID)
                    return bundle
                } catch {
                    let prefix = await bundle.status.durablePrefix
                    try? await bundle.closeChecked()
                    throw RunJournalBundleError.initializationFailed(
                        prefix, reason: error.localizedDescription)
                }
            }
            return bundle
        } catch {
            try? await sessionWriter.closeChecked()
            try? await workWriter.closeChecked()
            throw error
        }
    }

    public var status: RunJournalBundleStatus {
        RunJournalBundleStatus(
            health: healthState,
            durablePrefix: RunJournalBundlePrefix(
                sessionCursor: sessionCursor, workCursor: workCursor,
                sessionEventCount: sessionEventCount, workEventCount: workEventCount,
                hostOrder: hostOrder, failedJournal: failedJournal,
                failureReason: {
                    if case .failed(let reason) = healthState { return reason }
                    return nil
                }()))
    }

    /// Read both native journals through their already-held writer locks. The bundle actor
    /// serializes this pair with every append/finish operation, while each writer fences its own
    /// descriptor and path and builds a bounded reducer head from the same byte stream.
    public func canonicalObservation(
        limits: BoundedTimelineReducerProjectionLimits = .default,
        maximumResidentRecords: Int = 1_000_000
    ) async throws -> RunJournalBundleCanonicalObservation {
        try await withSemanticGate {
            let work = try await workWriter.readCanonicalProjection(
                expectedWork: self.work, expectedWorkHost: self.workHost, limits: limits,
                maximumResidentRecords: maximumResidentRecords)
            let session = try await sessionWriter.readCanonicalProjection(
                expectedSession: self.session, limits: limits,
                maximumResidentRecords: maximumResidentRecords)
            return try RunJournalBundleCanonicalObservation(
                binding: WorkBinding(
                    session: self.session, work: self.work, workHost: self.workHost,
                    sessionAttachment: self.sessionAttachment),
                work: work, session: session)
        }
    }

    public var latestSessionCursor: JournalCursor? { sessionCursor }
    public var latestWorkCursor: JournalCursor? { workCursor }

    /// Whether this bundle still contains only the exact newly-started Run marker and therefore
    /// may be closed without terminalizing the reservation. This is intentionally narrow: once a
    /// command, turn, action, or recovery event is durable, callers must not erase that evidence.
    public var isUntouchedStartedRun: Bool {
        guard activeRun == run, let predecessor = runStartPredecessorCursor,
              activeTurn == nil, activeActionIDs.isEmpty else { return false }
        // `commands` is Work-wide history, so it is expected to contain commands from an
        // earlier finished Run during End -> Start recovery.  Prove the stronger property from
        // the locked canonical tail instead: the exact marker follows the saved predecessor and
        // no command/turn/action/effect/recovery event exists after it.
        guard let events = try? Self.readNativeJournal(
            at: workWriter.fileURL, journal: workJournal, actor: actor),
              let marker = events.last,
              marker.type == TimelineEventType.runStarted,
              marker.run == run,
              let prior = events.dropLast().last,
              JournalCursor(
                  journal: workJournal, eventID: prior.eventID,
                  sequence: prior.sequence) == predecessor,
              JournalCursor(
                  journal: workJournal, eventID: marker.eventID,
                  sequence: marker.sequence) == workCursor else {
            return false
        }
        return true
    }
    public var latestHostOrder: Int { hostOrder }
    /// The durable Work lifecycle as understood by this open bundle. `run.finished` deliberately
    /// leaves this `active`; only `completeWork` or `destroyWork` changes it.
    public var lifecycle: WorkLifecycle { workLifecycle }
    public var activeRunContextDeliveredBytes: Int {
        guard let activeRun else { return 0 }
        return contextDeliveredBytesByRun[activeRun.runID] ?? 0
    }
    public func contextDeliveredBytes(for run: RunRef) -> Int {
        contextDeliveredBytesByRun[run.runID] ?? 0
    }

    /// Return the command state that is currently durable in Work.
    ///
    /// This is intentionally a read-only actor seam. A paired Session operation can fail after
    /// ``acceptCommandLocked`` has appended `command.accepted`; callers must inspect that native
    /// fact before deciding whether a command was rejected or merely not delivered to a
    /// compatibility projection.
    public func commandState(for commandID: String) -> CommandDeliveryState? {
        commands[commandID]?.state
    }

    /// Diagnostic seam for proving the bundle's partial-prefix behavior. Production callers use
    /// the semantic methods only; this does not expose a raw event or bypass either writer.
    public func injectWriterFailure(
        _ point: TimelineJournalWriter.FailurePoint, in journal: TimelineJournalKind
    ) async {
        switch journal {
        case .session: await sessionWriter.injectFailure(point)
        case .work: await workWriter.injectFailure(point)
        case .workHost:
            // The paired bundle owns only the Session and Work journals. Work Host control
            // state has its own writer and failure-injection surface.
            preconditionFailure(
                "RunJournalBundle does not own a Work Host control journal; inject failure through WorkHostControlJournal")
        }
    }

    /// Record Work ownership and the Session-visible input. A delivered input receives both the
    /// accepted and delivered Work receipts; queued input stops at accepted.
    public func commitInput(
        text: String,
        deliveryMode: RunInputDeliveryMode,
        command: CommandRef,
        metadata: [String: JSONValue] = [:]
    ) async throws -> [TimelineJournalCommit] {
        try await withSemanticGate {
            try await self.commitInputLocked(
                text: text, deliveryMode: deliveryMode, command: command, metadata: metadata)
        }
    }

    /// Record the first Start whose caller observed the idle Work prefix immediately before
    /// this bundle appended `run.started`.
    ///
    /// Opening a Run advances the Work journal before the client can submit its Start command.
    /// This deliberately narrow seam preserves that client's exact causal cursor while still
    /// appending the acceptance receipt after `run.started`. It returns nil for every cursor that
    /// is not the exact canonical immediate predecessor, allowing the caller to use the normal
    /// stale-cursor rejection path. No other command, turn, or action may have appeared after the
    /// marker because the canonical Work tail must still be `run.started` for this Run.
    public func commitInitialStartIfEligible(
        prompt: String,
        deliveryMode: RunInputDeliveryMode,
        command: CommandRef,
        metadata: [String: JSONValue] = [:]
    ) async throws -> [TimelineJournalCommit]? {
        try await withSemanticGate {
            guard let causal = command.causalCursor,
                  let predecessor = self.runStartPredecessorCursor,
                  self.activeRun == self.run,
                  self.activeTurn == nil,
                  self.activeActionIDs.isEmpty,
                  causal == predecessor,
                  let current = self.workCursor,
                  current != predecessor else {
                return nil
            }

            // Re-read the canonical prefix at the semantic boundary. In addition to proving the
            // saved predecessor was not fabricated, this closes the gap where another writer
            // appended an intervening command/turn/action after `run.started`.
            let workEvents = try Self.readNativeJournal(
                at: self.workWriter.fileURL, journal: self.workJournal, actor: self.actor)
            let (nextSequence, sequenceOverflow) = predecessor.sequence.addingReportingOverflow(1)
            guard let runStarted = workEvents.last,
                  runStarted.type == TimelineEventType.runStarted,
                  runStarted.run == self.run,
                  let predecessorEvent = workEvents.dropLast().last,
                  JournalCursor(
                      journal: self.workJournal,
                      eventID: predecessorEvent.eventID,
                      sequence: predecessorEvent.sequence) == predecessor,
                  JournalCursor(
                      journal: self.workJournal,
                      eventID: runStarted.eventID,
                      sequence: runStarted.sequence) == current,
                  !sequenceOverflow,
                  runStarted.previousEventID == predecessor.eventID,
                  runStarted.sequence == nextSequence else {
                return nil
            }

            if prompt.isEmpty {
                return try await self.commitCommandLocked(
                    label: "start", deliveryMode: deliveryMode, command: command,
                    metadata: metadata, initialStartPredecessor: predecessor)
            }
            return try await self.commitInputLocked(
                text: prompt, deliveryMode: deliveryMode, command: command,
                metadata: metadata, initialStartPredecessor: predecessor)
        }
    }

    private func commitInputLocked(
        text: String,
        deliveryMode: RunInputDeliveryMode,
        command: CommandRef,
        metadata: [String: JSONValue],
        initialStartPredecessor: JournalCursor? = nil
    ) async throws -> [TimelineJournalCommit] {
        let accepted = try await acceptCommandLocked(
            command, deliveryMode: deliveryMode, payload: metadata,
            carriesSessionInput: true,
            initialStartPredecessor: initialStartPredecessor)
        let normalized = accepted.command
        var commits = accepted.commits
        let receipt = commits.last!
        var inputPayload: [String: JSONValue] = [
            "text": .string(text), "role": .string("user"),
            "delivery_mode": .string(deliveryMode.rawValue)
        ]
        if let commandKind = metadata["command_kind"] {
            inputPayload["command_kind"] = commandKind
        }
        let input = try await appendSession(TimelineEventDraft(
            hostSequence: nextHostOrder(), command: normalized,
            causedByEventID: receipt.eventRef,
            conversationParent: lastMessage,
            session: session, work: work, client: command.client,
            sessionAttachment: sessionAttachment, run: activeRun, turn: activeTurn,
            type: TimelineEventType.inputAccepted,
            declaredDomains: [.session, .work], payload: .object(inputPayload)))
        commits.append(input)
        lastMessage = input.eventRef
        let tip = try await appendSession(TimelineEventDraft(
            hostSequence: nextHostOrder(), causedByEventID: input.eventRef,
            conversationParent: input.eventRef,
            session: session, run: activeRun,
            type: TimelineEventType.sessionTipSelected, declaredDomains: [.session],
            payload: .object(["target": .string(input.eventRef.eventID)])))
        commits.append(tip)
        // A newly accepted input is now being worked. Clearing any prior review/error state is
        // a canonical Session fact, not a UI inference from an in-process LiveRun.
        if let attention = try await appendAttentionLocked(.none, causedBy: tip.eventRef) {
            commits.append(attention)
        }
        return commits
    }

    /// Record the Session attention that a producer has actually established. This is kept on
    /// the Session journal so every client can observe the same transition; callers must only
    /// use values supported by their real boundary (for example, the native runner does not
    /// claim confirmation without an explicit confirmation protocol).
    @discardableResult
    public func setAttention(_ attention: SessionAttention) async throws -> TimelineJournalCommit? {
        try await withSemanticGate {
            try await self.appendAttentionLocked(attention, causedBy: self.lastMessage)
        }
    }

    private func appendAttentionLocked(
        _ attention: SessionAttention, causedBy: EventRef?
    ) async throws -> TimelineJournalCommit? {
        try ensureUsable()
        guard authoredAttention != attention else { return nil }
        let commit = try await appendSession(TimelineEventDraft(
            hostSequence: nextHostOrder(), causedByEventID: causedBy,
            session: session, run: activeRun,
            type: TimelineEventType.sessionAttention, declaredDomains: [.session],
            payload: .object(["attention": .string(attention.rawValue)])))
        authoredAttention = attention
        return commit
    }

    /// Record a non-conversational command such as cancellation or End. Unlike `commitInput`,
    /// this changes only the Work command ledger; it cannot manufacture a user message in the
    /// Session conversation. Delivery remains a separate receipt for queued commands.
    public func commitCommand(
        label: String,
        deliveryMode: RunInputDeliveryMode,
        command: CommandRef,
        metadata: [String: JSONValue] = [:]
    ) async throws -> [TimelineJournalCommit] {
        try await withSemanticGate {
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RunJournalBundleError.invalidOperation("command label is empty")
            }
            var payload = metadata
            payload["command_kind"] = .string(label)
            return try await self.commitCommandLocked(
                label: label, deliveryMode: deliveryMode, command: command,
                metadata: payload)
        }
    }

    private func commitCommandLocked(
        label: String,
        deliveryMode: RunInputDeliveryMode,
        command: CommandRef,
        metadata: [String: JSONValue],
        initialStartPredecessor: JournalCursor? = nil
    ) async throws -> [TimelineJournalCommit] {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidOperation("command label is empty")
        }
        var payload = metadata
        payload["command_kind"] = .string(label)
        return try await acceptCommandLocked(
            command, deliveryMode: deliveryMode, payload: payload,
            carriesSessionInput: false,
            initialStartPredecessor: initialStartPredecessor).commits
    }

    /// Durably refuse a command whose caller observed a real but stale Work cursor. Rejection
    /// is a host-ordered Work fact, not an in-memory controller branch, so another GUI can see
    /// both the conflict and the exact state the caller acted on.
    @discardableResult
    public func rejectCommand(
        command: CommandRef, reason: String,
        metadata: [String: JSONValue] = [:]
    ) async throws -> TimelineJournalCommit {
        try await withSemanticGate {
            try self.ensureUsable()
            try self.ensureRunActive()
            guard !command.commandID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RunJournalBundleError.invalidOperation("command identity is empty")
            }
            guard self.commands[command.commandID] == nil else {
                throw RunJournalBundleError.invalidOperation(
                    "command identity has already been used")
            }
            guard command.sessionAttachment == nil
                    || command.sessionAttachment == self.sessionAttachment else {
                throw RunJournalBundleError.invalidOperation(
                    "command belongs to another Session attachment")
            }
            guard let causal = command.causalCursor,
                  causal.journal == self.workJournal,
                  let causalEventID = causal.eventID else {
                throw RunJournalBundleError.invalidOperation(
                    "rejected command must carry a Work cursor with durable event identity")
            }
            let workEvents = try Self.readNativeJournal(
                at: self.workWriter.fileURL, journal: self.workJournal, actor: self.actor)
            guard workEvents.contains(where: {
                $0.sequence == causal.sequence && $0.eventID == causalEventID
            }) else {
                throw RunJournalBundleError.invalidOperation(
                    "rejected command cursor is not part of the canonical Work chain")
            }
            let boundedReason = String(reason.prefix(4_000))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !boundedReason.isEmpty else {
                throw RunJournalBundleError.invalidOperation(
                    "command rejection requires a reason")
            }
            let normalized = CommandRef(
                commandID: command.commandID, client: command.client,
                sessionAttachment: self.sessionAttachment, causalCursor: causal)
            let hostOrder = self.nextHostOrder()
            var payload = metadata
            payload["reason"] = .string(boundedReason)
            if let expected = self.workCursor {
                payload["expected_cursor"] = encodeTimelineValue(expected)
            }
            payload["received_cursor"] = encodeTimelineValue(causal)
            let commit = try await self.appendWork(TimelineEventDraft(
                hostSequence: hostOrder,
                idempotencyKey: "\(command.commandID):rejected",
                command: normalized,
                causedByEventID: EventRef(journal: self.workJournal, eventID: causalEventID),
                work: self.work, workHost: self.workHost,
                client: command.client, sessionAttachment: self.sessionAttachment,
                run: self.run,
                type: TimelineEventType.commandRejected,
                declaredDomains: [.work], payload: .object(payload)))
            self.commands[normalized.commandID] = WorkCommandSnapshot(
                command: normalized, state: .rejected, actor: self.actor,
                hostSequence: hostOrder,
                idempotencyKey: "\(command.commandID):rejected",
                acceptanceEventRef: commit.eventRef,
                commandKind: payload["command_kind"]?.stringValue.flatMap { CanonicalCommandKind(rawValue: $0) },
                deliveryMode: payload["delivery_mode"]?.stringValue.flatMap { RunInputDeliveryMode(rawValue: $0) },
                acceptanceRun: self.activeRun, carriesSessionInput: false)
            return commit
        }
    }

    private func acceptCommandLocked(
        _ command: CommandRef,
        deliveryMode: RunInputDeliveryMode,
        payload extraPayload: [String: JSONValue],
        carriesSessionInput: Bool,
        initialStartPredecessor: JournalCursor? = nil
    ) async throws -> (command: CommandRef, commits: [TimelineJournalCommit]) {
        try ensureUsable()
        try ensureRunActive()
        guard !command.commandID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidOperation("command identity is empty")
        }
        guard commands[command.commandID] == nil else {
            throw RunJournalBundleError.invalidOperation("command identity has already been used")
        }
        guard command.sessionAttachment == nil || command.sessionAttachment == sessionAttachment else {
            throw RunJournalBundleError.invalidOperation("command belongs to another Session attachment")
        }
        let causal: JournalCursor
        if let initialStartPredecessor {
            guard command.causalCursor == initialStartPredecessor,
                  self.activeRun == self.run,
                  let current = self.workCursor,
                  current != initialStartPredecessor else {
                throw RunJournalBundleError.invalidOperation(
                    "initial Start command does not carry its canonical pre-run Work cursor")
            }
            causal = initialStartPredecessor
        } else {
            guard let current = command.causalCursor,
                  current.journal == workJournal,
                  current.sequence == workCursor?.sequence,
                  current.eventID == workCursor?.eventID else {
                throw RunJournalBundleError.invalidOperation(
                    "command must carry the current pre-receipt Work cursor")
            }
            causal = current
        }
        let normalized = CommandRef(
            commandID: command.commandID, client: command.client,
            sessionAttachment: sessionAttachment, causalCursor: causal)
        let acceptedHostOrder = nextHostOrder()
        var payload = extraPayload
        payload["delivery_mode"] = .string(deliveryMode.rawValue)
        payload["carries_session_input"] = .bool(carriesSessionInput)
        let accepted = try await appendWork(TimelineEventDraft(
            hostSequence: acceptedHostOrder, idempotencyKey: "\(command.commandID):accepted",
            command: normalized,
            causedByEventID: causal.eventID.map { EventRef(journal: workJournal, eventID: $0) },
            session: nil, work: work, workHost: workHost,
            client: command.client, sessionAttachment: sessionAttachment, run: self.activeRun,
            type: TimelineEventType.commandAccepted,
            declaredDomains: [.work], payload: .object(payload)))
        commands[normalized.commandID] = WorkCommandSnapshot(
            command: normalized, state: .accepted, actor: actor,
            hostSequence: acceptedHostOrder,
            idempotencyKey: "\(command.commandID):accepted",
            acceptanceEventRef: accepted.eventRef,
            commandKind: payload["command_kind"]?.stringValue.flatMap { CanonicalCommandKind(rawValue: $0) },
            deliveryMode: deliveryMode,
            acceptanceRun: self.activeRun, carriesSessionInput: carriesSessionInput)
        commandAcceptedRefs[normalized.commandID] = accepted.eventRef
        var commits = [accepted]
        if deliveryMode == .delivered {
            commits.append(try await markCommandDeliveredLocked(commandID: normalized.commandID))
        }
        return (normalized, commits)
    }

    /// Cross the runtime delivery boundary for an input previously committed as queued. The
    /// accepted CommandRef is looked up from the bundle and reused byte-for-byte; the caller's
    /// copy is only an identity handle and cannot rewrite its pre-acceptance causal cursor.
    @discardableResult
    public func markInputDelivered(command: CommandRef) async throws -> TimelineJournalCommit {
        try await withSemanticGate {
            try await self.markCommandDeliveredLocked(commandID: command.commandID)
        }
    }

    /// ID-oriented form for runtimes that retain only the durable command identity after queueing.
    @discardableResult
    public func markCommandDelivered(commandID: String) async throws -> TimelineJournalCommit {
        try await withSemanticGate {
            try await self.markCommandDeliveredLocked(commandID: commandID)
        }
    }

    private func markCommandDeliveredLocked(commandID: String) async throws -> TimelineJournalCommit {
        try ensureUsable()
        try ensureRunActive()
        guard !commandID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidOperation("command identity is empty")
        }
        guard let existing = commands[commandID] else {
            throw RunJournalBundleError.invalidOperation("command was not accepted")
        }
        guard existing.state == .accepted else {
            throw RunJournalBundleError.invalidOperation(
                "command is already \(existing.state.rawValue)")
        }
        guard let acceptance = commandAcceptedRefs[commandID] else {
            throw RunJournalBundleError.invalidOperation("accepted command receipt is unavailable")
        }
        let deliveryHostOrder = nextHostOrder()
        let receipt = try await appendWork(TimelineEventDraft(
            hostSequence: deliveryHostOrder, idempotencyKey: "\(commandID):delivered",
            command: existing.command, causedByEventID: acceptance,
            work: work, workHost: workHost,
            client: existing.command.client, sessionAttachment: sessionAttachment,
            run: self.activeRun,
            type: TimelineEventType.commandDelivered,
            declaredDomains: [.work], payload: .object([
                "delivery_mode": .string(RunInputDeliveryMode.delivered.rawValue)
            ])))
        commands[commandID] = WorkCommandSnapshot(
            command: existing.command, state: .delivered,
            acceptanceActor: existing.acceptanceActor,
            acceptanceHostSequence: existing.acceptanceHostSequence,
            acceptanceIdempotencyKey: existing.acceptanceIdempotencyKey,
            acceptanceEventRef: existing.acceptanceEventRef,
            deliveryEventRef: receipt.eventRef,
            deliveryActor: actor, deliveryHostSequence: deliveryHostOrder,
            deliveryIdempotencyKey: "\(commandID):delivered",
            commandKind: existing.commandKind, deliveryMode: existing.deliveryMode,
            acceptanceRun: existing.acceptanceRun,
            carriesSessionInput: existing.carriesSessionInput)
        return receipt
    }

    /// Terminalize a command that Work accepted but the runtime definitely did not receive.
    /// This is not an admission rejection: the original `command.accepted` remains the durable
    /// fact, followed by a separate delivery outcome that makes retries and recovery unambiguous.
    @discardableResult
    public func markCommandNotDelivered(
        commandID: String, reason: String
    ) async throws -> TimelineJournalCommit {
        try await withSemanticGate(respectCancellation: false) {
            try await self.markCommandDeliveryOutcomeLocked(
                commandID: commandID, state: .notDelivered, reason: reason)
        }
    }

    /// Record that the runtime crossing may have happened but no reliable delivery receipt is
    /// available. Retrying this command can duplicate effects and must require explicit review.
    @discardableResult
    public func markCommandDeliveryIndeterminate(
        commandID: String, reason: String
    ) async throws -> TimelineJournalCommit {
        try await withSemanticGate(respectCancellation: false) {
            try await self.markCommandDeliveryOutcomeLocked(
                commandID: commandID, state: .indeterminate, reason: reason)
        }
    }

    private func markCommandDeliveryOutcomeLocked(
        commandID: String, state: CommandDeliveryState, reason: String
    ) async throws -> TimelineJournalCommit {
        try ensureUsable()
        try ensureRunActive()
        guard state == .notDelivered || state == .indeterminate else {
            throw RunJournalBundleError.invalidOperation(
                "command terminalization requires a delivery-outcome state")
        }
        let boundedReason = String(reason.prefix(4_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !boundedReason.isEmpty else {
            throw RunJournalBundleError.invalidOperation(
                "command delivery outcome requires a reason")
        }
        guard let existing = commands[commandID] else {
            throw RunJournalBundleError.invalidOperation("command was not accepted")
        }
        guard existing.state == .accepted else {
            throw RunJournalBundleError.invalidOperation(
                "command is already \(existing.state.rawValue)")
        }
        guard let acceptedRef = commandAcceptedRefs[commandID] else {
            throw RunJournalBundleError.invalidOperation(
                "command acceptance provenance is unavailable")
        }
        let hostOrder = nextHostOrder()
        let type = state == .notDelivered
            ? TimelineEventType.commandNotDelivered
            : TimelineEventType.commandDeliveryIndeterminate
        let commit = try await appendWork(TimelineEventDraft(
            hostSequence: hostOrder,
            idempotencyKey: "\(commandID):\(state.rawValue)",
            command: existing.command, causedByEventID: acceptedRef,
            work: work, workHost: workHost, client: existing.command.client,
            sessionAttachment: existing.command.sessionAttachment,
            run: activeRun,
            type: type, declaredDomains: [.work], payload: .object([
                "delivery_state": .string(state.rawValue),
                "reason": .string(boundedReason),
            ])))
        commands[commandID] = WorkCommandSnapshot(
            command: existing.command, state: state,
            acceptanceActor: existing.acceptanceActor,
            acceptanceHostSequence: existing.acceptanceHostSequence,
            acceptanceIdempotencyKey: existing.acceptanceIdempotencyKey,
            acceptanceEventRef: existing.acceptanceEventRef,
            deliveryEventRef: commit.eventRef,
            deliveryActor: actor, deliveryHostSequence: hostOrder,
            deliveryIdempotencyKey: "\(commandID):\(state.rawValue)",
            commandKind: existing.commandKind, deliveryMode: existing.deliveryMode,
            acceptanceRun: existing.acceptanceRun,
            carriesSessionInput: existing.carriesSessionInput)
        return commit
    }

    public func startTurn(_ turn: TurnRef) async throws -> TimelineJournalCommit {
        try await withSemanticGate { try await self.startTurnLocked(turn) }
    }

    private func startTurnLocked(_ turn: TurnRef) async throws -> TimelineJournalCommit {
        try ensureUsable()
        try ensureRunActive()
        guard !turn.turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidOperation("turn identity is empty")
        }
        guard activeTurn == nil else {
            throw RunJournalBundleError.invalidOperation("another turn is already active")
        }
        let commit = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), work: work, workHost: workHost,
            run: activeRun, turn: turn, type: TimelineEventType.turnStarted,
            declaredDomains: [.work]))
        activeTurn = turn
        return commit
    }

    public func finishTurn(
        _ turn: TurnRef, outcome: RunTurnOutcome = .completed
    ) async throws -> [TimelineJournalCommit] {
        try await withSemanticGate(respectCancellation: false) {
            try await self.finishTurnLocked(turn, outcome: outcome)
        }
    }

    private func finishTurnLocked(
        _ turn: TurnRef, outcome: RunTurnOutcome
    ) async throws -> [TimelineJournalCommit] {
        try ensureUsable()
        guard !turn.turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidOperation("turn identity is empty")
        }
        guard activeTurn == turn else {
            throw RunJournalBundleError.invalidOperation("turn is not active")
        }
        let commit = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), work: work, workHost: workHost,
            run: activeRun, turn: turn, type: TimelineEventType.turnFinished,
            declaredDomains: [.work], payload: .object([
                "outcome": .string(outcome.rawValue),
            ])))
        guard let cursor = workCursor else {
            throw RunJournalBundleError.invalidOperation(
                "turn.finished did not produce a Work cursor")
        }
        // A turn outcome establishes the Session attention boundary. Persist attention and then
        // advance the attachment to this exact Work prefix. Failure at either Session append
        // keeps effective attention unknown; no reader may project ready-for-review from the
        // in-memory turn state alone.
        var commits = [commit]
        if let attention = try await appendAttentionLocked(
            outcome.sessionAttention, causedBy: commit.eventRef) {
            commits.append(attention)
        }
        let advanced = try await appendAttachmentCursorLocked(
            cursor, causedBy: commit.eventRef)
        activeTurn = nil
        commits.append(advanced)
        return commits
    }

    public func changeModel(_ modelID: String) async throws -> TimelineJournalCommit {
        try await withSemanticGate { try await self.changeModelLocked(modelID) }
    }

    private func changeModelLocked(_ modelID: String) async throws -> TimelineJournalCommit {
        try ensureUsable()
        try ensureRunActive()
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidOperation("model identity is empty")
        }
        return try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), work: work, workHost: workHost,
            run: activeRun, type: TimelineEventType.modelChanged,
            declaredDomains: [.work, .context], payload: .object([
                "model_id": .string(modelID)
            ])))
    }

    /// Persist the complete six-plane recovery claim before the resumed run can dispatch work.
    /// The evidence cursor remains the exact source prefix; this event belongs to the replacement
    /// Run and must not rewrite that historical boundary.
    public func recordRecoveryCoverage(
        _ coverage: RecoveryCoverage
    ) async throws -> TimelineJournalCommit {
        try await withSemanticGate {
            try self.ensureUsable()
            try self.ensureRunActive()
            guard RecoveryPlane.allCases.allSatisfy({ coverage.planes[$0] != nil }) else {
                throw RunJournalBundleError.invalidOperation(
                    "recovery coverage must report every state plane")
            }
            var payload: [String: JSONValue] = [
                "operation": .string(coverage.operation.rawValue),
                "work_journal": encodeTimelineValue(self.workJournal),
                "planes": .object(Dictionary(uniqueKeysWithValues:
                    RecoveryPlane.allCases.map { plane in
                        (plane.rawValue, .string(coverage.planes[plane]!.rawValue))
                    })),
                "caveats": .array(coverage.caveats.map(JSONValue.string)),
            ]
            if let evidence = coverage.evidence {
                payload["evidence"] = encodeTimelineValue(evidence)
            }
            if let cursor = coverage.evidenceCursor {
                payload["evidence_cursor"] = encodeTimelineValue(cursor)
            }
            return try await self.appendSession(TimelineEventDraft(
                hostSequence: self.nextHostOrder(), session: self.session,
                work: self.work, workHost: self.workHost,
                sessionAttachment: self.sessionAttachment, run: self.activeRun,
                type: TimelineEventType.recoveryCoverage,
                declaredDomains: [.session, .work, .context, .runtime, .externalEffects],
                payload: .object(payload)))
        }
    }

    public func beginAction(
        action: ActionRef = ActionRef(UUID().uuidString.lowercased()),
        kind: ActionKind,
        intent: String,
        target: String? = nil,
        scope: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) async throws -> EffectPermit {
        try await withSemanticGate {
            guard kind != .provider, kind != .compactionProvider else {
                throw RunJournalBundleError.invalidOperation(
                    "provider requests require a context crossing and pinned accounting admission")
            }
            return try await self.beginActionLocked(action: action, kind: kind, intent: intent,
                                              target: target, scope: scope, metadata: metadata)
        }
    }

    /// Append a context crossing and the provider action it authorizes as one semantic unit.
    /// The Session event is written first, then the Work action carries both a causal reference
    /// and an evidence edge back to it. A caller must retain the returned permit until the
    /// provider request has settled.
    public func prepareModelCrossing(
        manifest: ContextManifest,
        admission: ProviderAdmission,
        action: ActionRef = ActionRef(UUID().uuidString.lowercased()),
        kind: ActionKind,
        intent: String = "Request the next model response",
        target: String
    ) async throws -> EffectPermit {
        try await withSemanticGate {
            try self.ensureUsable()
            try self.ensureRunActive()
            guard kind == .provider || kind == .compactionProvider else {
                throw RunJournalBundleError.invalidOperation(
                    "a model crossing requires a provider action kind")
            }
            try admission.validate(kind: kind)
            try admission.validate(contextModelID: manifest.modelID, targetModel: target)
            let contextCommit = try await self.appendContextManifestLocked(manifest)
            return try await self.beginActionLocked(
                action: action, kind: kind, intent: intent, target: target, scope: "run",
                metadata: ["request_id": .string(manifest.requestID)],
                providerAdmission: admission,
                causedBy: contextCommit.eventRef,
                links: [TimelineLink(kind: .derivedFrom, target: contextCommit.eventRef)])
        }
    }

    private func beginActionLocked(
        action: ActionRef,
        kind: ActionKind,
        intent: String,
        target: String?,
        scope: String?,
        metadata: [String: JSONValue],
        providerAdmission: ProviderAdmission? = nil,
        causedBy: EventRef? = nil,
        links: [TimelineLink] = []
    ) async throws -> EffectPermit {
        try ensureUsable()
        guard activeRun != nil else {
            throw RunJournalBundleError.invalidOperation("cannot begin an action without an active Run")
        }
        guard !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidOperation("action intent is empty")
        }
        guard !action.actionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidOperation("action identity is empty")
        }
        guard !seenActionIDs.contains(action.actionID) else {
            throw RunJournalBundleError.invalidOperation("action identity has already been used")
        }
        var payload: [String: JSONValue] = [
            "state": .string(ActionExecutionState.proposed.rawValue),
            "kind": .string(kind.rawValue), "intent": .string(intent)
        ]
        if let target { payload["target"] = .string(target) }
        if let scope { payload["scope"] = .string(scope) }
        if !metadata.isEmpty { payload["metadata"] = .object(metadata) }
        if let providerAdmission { payload["provider_admission"] = providerAdmission.timelineValue }
        let intentCommit = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), causedByEventID: causedBy,
            work: work, workHost: workHost,
            run: activeRun, turn: activeTurn, action: action, type: TimelineEventType.actionIntent,
            declaredDomains: [.work, .externalEffects], links: links, payload: .object(payload)))
        let startedCommit = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), causedByEventID: intentCommit.eventRef,
            parentActivityID: intentCommit.eventRef,
            work: work, workHost: workHost,
            run: activeRun, turn: activeTurn, action: action,
            type: TimelineEventType.actionStarted,
            declaredDomains: [.work, .externalEffects], payload: .object([
                "state": .string(ActionExecutionState.running.rawValue),
                "kind": .string(kind.rawValue)
            ])))
        let permit = EffectPermit(action: action, kind: kind, intent: intent,
                                  intentCommit: intentCommit, startedCommit: startedCommit,
                                  providerAdmission: providerAdmission)
        seenActionIDs.insert(action.actionID)
        activeActionIDs.insert(action.actionID)
        permits[action.actionID] = permit
        return permit
    }

    public func finishAction(
        _ permit: EffectPermit,
        state: ActionExecutionState,
        retrySafety: ActionRetrySafety,
        failureKind: ActionFailureKind? = nil,
        providerSettlement: ProviderSettlement? = nil
    ) async throws -> TimelineJournalCommit {
        try await withSemanticGate(respectCancellation: false) {
            try await self.finishActionLocked(permit, state: state,
                                               retrySafety: retrySafety, failureKind: failureKind,
                                               providerSettlement: providerSettlement)
        }
    }

    private func finishActionLocked(
        _ permit: EffectPermit,
        state: ActionExecutionState,
        retrySafety: ActionRetrySafety,
        failureKind: ActionFailureKind?,
        providerSettlement: ProviderSettlement?
    ) async throws -> TimelineJournalCommit {
        try ensureUsable()
        guard state.isTerminal else {
            throw RunJournalBundleError.invalidOperation("action outcome must be terminal")
        }
        guard activeActionIDs.contains(permit.action.actionID),
              permits[permit.action.actionID] == permit else {
            throw RunJournalBundleError.invalidOperation("effect permit is not active")
        }
        if [.failed, .canceled, .indeterminateEffect].contains(state), failureKind == nil {
            throw RunJournalBundleError.invalidOperation(
                "failed, canceled, or indeterminate action outcomes require a failure kind")
        }
        if let admission = permit.providerAdmission {
            guard let providerSettlement else {
                throw RunJournalBundleError.invalidOperation("provider outcome requires usage settlement")
            }
            try providerSettlement.validate(admission: admission, kind: permit.kind, state: state)
        } else if providerSettlement != nil || permit.kind == .provider || permit.kind == .compactionProvider {
            throw RunJournalBundleError.invalidOperation("provider settlement has no matching admission")
        }
        var outcomePayload: [String: JSONValue] = [
            "state": .string(state.rawValue),
            "retry_safety": .string(retrySafety.rawValue),
            "kind": .string(permit.kind.rawValue)
        ]
        if let failureKind { outcomePayload["failure_kind"] = .string(failureKind.rawValue) }
        if let providerSettlement { outcomePayload["provider_settlement"] = providerSettlement.timelineValue }
        let commit = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), causedByEventID: permit.startedCommit.eventRef,
            parentActivityID: permit.startedCommit.eventRef,
            work: work, workHost: workHost,
            run: activeRun, turn: activeTurn, action: permit.action,
            type: TimelineEventType.actionOutcome,
            declaredDomains: [.work, .externalEffects], payload: .object(outcomePayload)))
        activeActionIDs.remove(permit.action.actionID)
        permits.removeValue(forKey: permit.action.actionID)
        return commit
    }

    /// Record one child lifecycle transition on the parent's Work journal.
    ///
    /// The bundle supplies the parent Session, Work, Work Host, and active Run identities. This
    /// keeps child provenance attached to the run that admitted it rather than asking a caller to
    /// repeat identities that could drift. Appending is intentionally fail-closed: ``appendWork``
    /// latches the bundle when the filesystem boundary is ambiguous, so a caller cannot present
    /// a child as successfully finished after a terminal record was not durable.
    @discardableResult
    public func recordChildLifecycle(
        childID: String, name: String, state: ChildLifecycleState
    ) async throws -> TimelineJournalCommit {
        try await withSemanticGate(respectCancellation: false) {
            try self.ensureUsable()
            guard let activeRun = self.activeRun else {
                throw RunJournalBundleError.alreadyFinished("no active Run")
            }
            guard !childID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RunJournalBundleError.invalidOperation("child identity is empty")
            }
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RunJournalBundleError.invalidOperation("child name is empty")
            }
            return try await self.appendWork(TimelineEventDraft(
                hostSequence: self.nextHostOrder(),
                session: self.session, work: self.work, workHost: self.workHost,
                run: activeRun, type: TimelineEventType.childLifecycle,
                declaredDomains: [.work, .externalEffects], payload: .object([
                    "child_id": .string(childID),
                    "name": .string(name),
                    "state": .string(state.rawValue),
                    "parent_session_id": .string(self.session.sessionID),
                    "parent_run_id": .string(activeRun.runID),
                ])))
        }
    }

    /// Retain one artifact body before publishing its bounded Work-journal descriptor.  The
    /// body store is content addressed and authoritative to this Work journal; the event itself
    /// carries only identity, measured metadata, and the device-independent body reference.
    /// Passing no body records an explicitly unavailable artifact.  A receipt repeats the exact
    /// envelope association so callers do not infer Run/Turn ownership from a later projection.
    public func recordArtifact(
        artifactID: String,
        label: String,
        mediaType: String? = nil,
        body: Data? = nil,
        action: ActionRef? = nil,
        provenance: EventRef? = nil,
        links: [TimelineLink] = []
    ) async throws -> RunJournalArtifactReceipt {
        try await withSemanticGate {
            try self.ensureUsable()
            try self.ensureRunActive()
            guard Self.validArtifactText(
                      artifactID, maximumBytes: WorkServiceBounds.maxIdentityCharacters) else {
                throw RunJournalBundleError.invalidOperation(
                    "artifact identity must be nonblank and bounded")
            }
            guard Self.validArtifactText(
                      label, maximumBytes: WorkServiceBounds.maxDiagnosticCharacters) else {
                throw RunJournalBundleError.invalidOperation(
                    "artifact label must be nonblank and bounded")
            }
            guard !self.seenArtifactIDs.contains(artifactID) else {
                throw RunJournalBundleError.invalidOperation(
                    "artifact identity has already been recorded")
            }
            if let mediaType {
                guard Self.validArtifactText(
                          mediaType, maximumBytes: WorkServiceBounds.maxDiagnosticCharacters) else {
                    throw RunJournalBundleError.invalidOperation(
                        "artifact media type must be nonblank and bounded")
                }
            }
            if let body, body.count > Self.maximumArtifactBodyBytes {
                throw RunJournalBundleError.invalidOperation(
                    "artifact body exceeds the bounded size")
            }
            guard links.count <= TimelineEvent.maxEvidenceLinks else {
                throw RunJournalBundleError.invalidOperation(
                    "artifact evidence links exceed the bounded limit")
            }
            if let action {
                guard !action.actionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      action.actionID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
                      self.activeActionIDs.contains(action.actionID),
                      let permit = self.permits[action.actionID],
                      let provenance,
                      provenance == permit.startedCommit.eventRef else {
                    throw RunJournalBundleError.invalidOperation(
                        "artifact action must cite its exact active start event")
                }
            } else if let provenance {
                guard !provenance.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      provenance.eventID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
                      provenance.journal == self.workJournal
                        || provenance.journal == self.sessionJournal else {
                    throw RunJournalBundleError.invalidOperation(
                        "artifact provenance is not a bundle journal event")
                }
            }
            if mediaType == ObservedRepositoryReviewFormat.mediaType {
                guard self.activeTurn != nil, action != nil, provenance != nil else {
                    throw RunJournalBundleError.invalidOperation(
                        "repository-review artifacts require an active Turn, Action, and cause")
                }
            }

            // This is deliberately the first side effect.  If the journal append later fails,
            // the durable body remains an honest orphan rather than an event advertising bytes
            // which were never retained.
            let bodyReference: TimelineBodyReference?
            if let body {
                bodyReference = try self.contextBodyStore.retain(
                    body, authority: self.workJournal,
                    mediaType: mediaType ?? "application/octet-stream")
            } else {
                bodyReference = nil
            }
            if mediaType == ObservedRepositoryReviewFormat.mediaType {
                guard let body, let turn = self.activeTurn,
                      let review = try? ObservedRepositoryReview.decode(body),
                      review.matchesCanonicalSource(run: self.run, turn: turn) else {
                    // The body was intentionally retained before this validation.  A failed
                    // producer attempt may leave an orphan, but it must never publish a Work
                    // descriptor whose review bytes belong to another Run/Turn.
                    throw RunJournalBundleError.invalidOperation(
                        "repository-review body provenance does not match the active Run and Turn")
                }
            }
            let descriptorMediaType = bodyReference?.mediaType ?? mediaType
            let descriptorByteCount = bodyReference?.byteCount
            let descriptorDigest = bodyReference?.digest
            var payload: [String: JSONValue] = [
                "artifact_id": .string(artifactID),
                "label": .string(label),
                "available": .bool(bodyReference != nil),
            ]
            if let mediaType = descriptorMediaType {
                payload["media_type"] = .string(mediaType)
            }
            if let byteCount = descriptorByteCount {
                payload["byte_count"] = .number(Double(byteCount))
            }
            if let digest = descriptorDigest {
                payload["digest"] = .string(digest)
            }
            if let bodyReference {
                payload["body_reference"] = encodeTimelineValue(bodyReference)
            }
            let commit: TimelineJournalCommit
            do {
                commit = try await self.appendWork(TimelineEventDraft(
                    hostSequence: self.nextHostOrder(),
                    causedByEventID: provenance,
                    session: self.session, work: self.work, workHost: self.workHost,
                    sessionAttachment: self.sessionAttachment, run: self.activeRun,
                    turn: self.activeTurn, action: action,
                    type: TimelineEventType.artifact,
                    declaredDomains: [.work], links: links,
                    payload: .object(payload)))
            } catch {
                // A Work-writer failure is an uncertain publication boundary. Validation and
                // body-retention failures happen before this block and remain ordinary failures.
                AviaryTelemetry.outcome("indeterminate")
                throw error
            }
            if mediaType == ObservedRepositoryReviewFormat.mediaType,
               let run = self.activeRun {
                var attributes = AviaryTelemetry.canonicalReferenceAttributes(commit)
                attributes.merge([
                    "aviary.artifact.id": .string(AviaryTelemetry.identity(artifactID)),
                    "aviary.work.id": .string(AviaryTelemetry.workIdentity(self.work)),
                    "aviary.run.id": .string(AviaryTelemetry.identity(run.runID)),
                ], uniquingKeysWith: { _, replacement in replacement })
                if let turn = self.activeTurn {
                    attributes["aviary.turn.id"] = .string(
                        AviaryTelemetry.identity(turn.turnID))
                }
                if let action {
                    attributes["aviary.action.id"] = .string(
                        AviaryTelemetry.identity(action.actionID))
                }
                if let descriptorByteCount {
                    attributes["aviary.artifact.bytes"] = .int(descriptorByteCount)
                }
                // Publication telemetry is a receipt for the canonical Work append, not for
                // body retention. An orphaned body has no event and cannot produce this receipt.
                AviaryTelemetry.event(
                    "aviary.repository.artifact.published", attributes: attributes)
            }
            self.seenArtifactIDs.insert(artifactID)
            // The source event does not exist until appendWork commits it. Build the descriptor
            // from that exact commit and the same envelope values/payload metadata, so a receipt
            // cannot accidentally describe a pre-commit or inferred event.
            let descriptor = try WorkServiceArtifactDescriptor(
                artifactID: artifactID,
                work: self.work,
                label: label,
                mediaType: descriptorMediaType,
                byteCount: descriptorByteCount,
                digest: descriptorDigest,
                available: bodyReference != nil,
                bodyReference: bodyReference,
                metadataWasTruncated: false,
                sourceEvent: commit.eventRef,
                session: self.session,
                sessionAttachment: self.sessionAttachment,
                run: self.run,
                turn: self.activeTurn,
                action: action,
                causedByEventID: provenance)
            return RunJournalArtifactReceipt(
                descriptor: descriptor, commit: commit, run: self.run,
                turn: self.activeTurn, action: action, provenance: provenance,
                links: links)
        }
    }

    /// Commit a legacy text-only assistant message first, then explicitly select it as the
    /// Session tip. New provider paths should use the structured overload so a tool call or
    /// image cannot disappear at the cold-resume boundary.
    public func commitAssistantMessage(_ text: String) async throws -> [TimelineJournalCommit] {
        try await commitAssistantMessage(ChatMessage(role: .assistant, content: [.text(text)]))
    }

    /// Commit the exact provider-visible assistant content. The retained body is published before
    /// the Session event, so a durable `message.committed` never claims reconstructable structured
    /// content whose bytes are unavailable.
    public func commitAssistantMessage(
        _ message: ChatMessage
    ) async throws -> [TimelineJournalCommit] {
        try await withSemanticGate { try await self.commitAssistantMessageLocked(message) }
    }

    private func commitAssistantMessageLocked(
        _ message: ChatMessage
    ) async throws -> [TimelineJournalCommit] {
        try ensureUsable()
        try ensureRunActive()
        guard message.role == .assistant else {
            throw RunJournalBundleError.invalidOperation(
                "committed assistant content must have the assistant role")
        }
        let body = try ContextManifest.bodyData(for: message)
        let bodyReference = try contextBodyStore.retain(
            body, authority: sessionJournal,
            mediaType: "application/vnd.aviary.chat-message+json")
        let text = message.content.compactMap { content -> String? in
            guard case .text(let value) = content else { return nil }
            return value
        }.joined()
        let contentKinds = message.content.map { content -> JSONValue in
            switch content {
            case .text: return .string("text")
            case .thinking: return .string("thinking")
            case .toolCall: return .string("tool_call")
            case .toolResult: return .string("tool_result")
            case .image: return .string("image")
            }
        }
        let message = try await appendSession(TimelineEventDraft(
            hostSequence: nextHostOrder(), conversationParent: lastMessage,
            session: session, sessionAttachment: sessionAttachment,
            run: activeRun, turn: activeTurn,
            type: TimelineEventType.messageCommitted, declaredDomains: [.session],
            payload: .object([
                "role": .string("assistant"), "text": .string(text),
                "content_kinds": .array(contentKinds),
                "message_body_ref": encodeTimelineValue(bodyReference),
            ])))
        lastMessage = message.eventRef
        let tip = try await appendSession(TimelineEventDraft(
            hostSequence: nextHostOrder(), causedByEventID: message.eventRef,
            conversationParent: message.eventRef,
            session: session, run: activeRun,
            type: TimelineEventType.sessionTipSelected,
            declaredDomains: [.session], payload: .object([
                "target": .string(message.eventRef.eventID)
            ])))
        return [message, tip]
    }

    /// Record the summary that actually replaced prior model context. This is deliberately a
    /// Session/context event, not a conversation message, so it cannot move the visible chat tip.
    public func commitCompaction(
        summary: String, tokensBefore: Int, droppedMessages: Int
    ) async throws -> TimelineJournalCommit {
        try await withSemanticGate {
            try self.ensureUsable()
            try self.ensureRunActive()
            guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RunJournalBundleError.invalidOperation("compaction summary is empty")
            }
            guard tokensBefore >= 0, droppedMessages >= 0 else {
                throw RunJournalBundleError.invalidOperation(
                    "compaction measurements cannot be negative")
            }
            return try await self.appendSession(TimelineEventDraft(
                hostSequence: self.nextHostOrder(), session: self.session, run: self.activeRun,
                type: TimelineEventType.compaction,
                declaredDomains: [.session, .context], payload: .object([
                    "summary": .string(summary),
                    "tokens_before": .number(Double(tokensBefore)),
                    "dropped_messages": .number(Double(droppedMessages)),
                    "summary_bytes": .number(Double(summary.utf8.count)),
                ])))
        }
    }

    /// Record the exact bounded metadata for the next model request before crossing the
    /// provider boundary. Bodies remain in their owning timeline/artifact store; this event
    /// carries only stable identities, provenance, hashes, measured sizes, and omissions.
    @discardableResult
    public func commitContextManifest(
        _ manifest: ContextManifest
    ) async throws -> TimelineJournalCommit {
        try await withSemanticGate {
            try self.ensureUsable()
            try self.ensureRunActive()
            return try await self.appendContextManifestLocked(manifest)
        }
    }

    private func appendContextSourcesObservedLocked(
        _ manifest: ContextManifest
    ) async throws -> TimelineJournalCommit {
        try await appendContextSourcesObservedLocked(
            assemblyID: manifest.systemPromptAssemblyID ?? "",
            sources: manifest.systemPromptSources ?? [])
    }

    private func appendContextSourcesObservedLocked(
        assemblyID: String,
        sources: [ContextManifestSource]
    ) async throws -> TimelineJournalCommit {
        guard let activeRun else {
            throw RunJournalBundleError.invalidOperation(
                "cannot observe prompt sources without an active Run")
        }
        // Provenance is the EventRef of this observation, which does not exist until append
        // returns. Never carry a caller's prior observation reference into this event.
        let observedSources = sources.map { $0.withProvenance(nil) }
        let probe = ContextManifest(
            manifestID: "source-observation", requestID: "source-observation",
            modelID: "source-observation", components: [ContextComponent(
                componentID: "source-observation", inclusionID: "source-observation",
                sourceID: "source-observation", mode: .instruction, measuredBytes: 0,
                includedBytes: 0, deliveredBytes: 0, fullByteCount: 0,
                digest: "sha256:" + String(repeating: "0", count: 64))],
            systemPromptAssemblyID: assemblyID, systemPromptSources: observedSources)
        do {
            try probe.validatePromptSources(authority: sessionJournal)
        } catch {
            throw RunJournalBundleError.invalidOperation(
                "prompt source observation is invalid: \(error.localizedDescription)")
        }
        return try await appendSession(TimelineEventDraft(
            hostSequence: nextHostOrder(), session: session,
            work: work, workHost: workHost, run: activeRun,
            type: TimelineEventType.contextSourcesObserved,
            declaredDomains: [.session, .context], payload: .object([
                "assembly_id": .string(assemblyID),
                "source_count": .number(Double(sources.count)),
                "sources": .array(observedSources.map(encodeTimelineValue)),
            ])))
    }

    private func appendContextManifestLocked(
        _ manifest: ContextManifest
    ) async throws -> TimelineJournalCommit {
        guard let activeRun else {
            throw RunJournalBundleError.invalidOperation(
                "cannot assemble model context without an active Run")
        }
        do {
            try manifest.validate(
                authority: sessionJournal,
                previousCumulativeDeliveredBytes:
                    contextDeliveredBytesByRun[activeRun.runID],
                requireRetainedBodies: true)
            // Reference metadata is only a claim. Resolve every body from the store owned by
            // this bundle and verify its digest and length before the Session may say the
            // crossing is reconstructable or a Work permit can escape.
            for component in manifest.components {
                _ = try contextBodyStore.read(component.bodyReference!)
            }
            for source in manifest.systemPromptSources ?? [] {
                if let reference = source.fullBodyReference { _ = try contextBodyStore.read(reference) }
                if let reference = source.deliveredBodyReference { _ = try contextBodyStore.read(reference) }
                if let reference = source.renderedBodyReference { _ = try contextBodyStore.read(reference) }
            }
            try validatePromptAssemblyBodies(manifest)
        } catch {
            throw RunJournalBundleError.invalidOperation(
                "context manifest or retained body is invalid: \(error.localizedDescription)")
        }
        let sourceObservation = manifest.systemPromptSources == nil
            ? nil
            : try await appendContextSourcesObservedLocked(manifest)
        let durableManifest: ContextManifest
        if let sources = manifest.systemPromptSources, let sourceObservation {
            let observedSources = sources.map { $0.withProvenance(sourceObservation.eventRef) }
            durableManifest = ContextManifest(
                schemaVersion: manifest.schemaVersion, manifestID: manifest.manifestID,
                requestID: manifest.requestID, modelID: manifest.modelID,
                measuredBy: manifest.measuredBy, components: manifest.components,
                omissions: manifest.omissions,
                cumulativeDeliveredBytes: manifest.cumulativeDeliveredBytes,
                systemPromptAssemblyID: manifest.systemPromptAssemblyID,
                systemPromptSources: observedSources)
        } else {
            durableManifest = manifest
        }
        var payload: [String: JSONValue] = [
            "manifest_id": .string(durableManifest.manifestID),
            "request_id": .string(durableManifest.requestID),
            "model_id": .string(durableManifest.modelID),
            "schema_version": .number(Double(durableManifest.schemaVersion)),
            "measured_by": .string(durableManifest.measuredBy),
            "measured_bytes": .number(Double(durableManifest.measuredBytes)),
            "delivered_bytes": .number(Double(durableManifest.deliveredBytes)),
            "cumulative_delivered_bytes": .number(Double(durableManifest.cumulativeDeliveredBytes)),
            "components": .array(durableManifest.components.map(encodeTimelineValue)),
            "omissions": .array(durableManifest.omissions.map(encodeTimelineValue)),
        ]
        if let assemblyID = durableManifest.systemPromptAssemblyID {
            payload["system_prompt_assembly_id"] = .string(assemblyID)
        }
        if let sources = durableManifest.systemPromptSources {
            payload["system_prompt_sources"] = .array(sources.map(encodeTimelineValue))
        }
        let commit = try await appendSession(TimelineEventDraft(
            hostSequence: nextHostOrder(), causedByEventID: sourceObservation?.eventRef,
            session: session,
            work: work, workHost: workHost, run: activeRun,
            type: TimelineEventType.contextAssembled,
            declaredDomains: [.session, .context], payload: .object(payload)))
        contextDeliveredBytesByRun[activeRun.runID] = manifest.cumulativeDeliveredBytes
        return commit
    }

    /// Re-bind a source-aware manifest to the exact retained system ChatMessage. The metadata
    /// validator proves identities, sizes, and references; this body-store boundary proves the
    /// byte relationships that a pure reducer cannot inspect.
    private func validatePromptAssemblyBodies(_ manifest: ContextManifest) throws {
        guard let sources = manifest.systemPromptSources,
              let assemblyID = manifest.systemPromptAssemblyID else { return }
        let pinned = manifest.components.filter { $0.mode == .pinned }
        guard sources.count > 0, pinned.count == 1,
              let systemReference = pinned[0].bodyReference,
              systemReference.mediaType == "application/vnd.aviary.chat-message+json" else {
            throw RunJournalBundleError.invalidOperation(
                "source-aware context requires one retained system ChatMessage")
        }
        let systemData = try contextBodyStore.read(systemReference)
        guard let systemObject = JSONValue.parse(systemData)?.objectValue,
              systemObject["role"]?.stringValue == ChatRole.system.rawValue,
              let content = systemObject["content"]?.arrayValue,
              content.count == 1,
              content[0]["type"]?.stringValue == "text",
              let systemText = content[0]["text"]?.stringValue else {
            throw RunJournalBundleError.invalidOperation(
                "source-aware context system body is not one text ChatMessage")
        }

        var assembled = Data()
        for source in sources {
            let full = try source.fullBodyReference.map(contextBodyStore.read)
            let delivered = try source.deliveredBodyReference.map(contextBodyStore.read)
            let rendered = try source.renderedBodyReference.map(contextBodyStore.read)
            switch source.status {
            case .present:
                guard let full, let delivered, let rendered, full == delivered else {
                    throw RunJournalBundleError.invalidOperation(
                        "present prompt source bytes do not match: \(source.sourceID)")
                }
                try validateDeliveredPromptSlice(source, delivered: delivered, rendered: rendered)
                assembled.append(rendered)
            case .truncated:
                guard let full, let delivered, let rendered,
                      delivered.count < full.count, full.starts(with: delivered) else {
                    throw RunJournalBundleError.invalidOperation(
                        "truncated prompt source is not a retained prefix: \(source.sourceID)")
                }
                try validateDeliveredPromptSlice(source, delivered: delivered, rendered: rendered)
                assembled.append(rendered)
            case .missing, .unreadable, .disabled:
                guard full == nil, delivered == nil, rendered == nil else {
                    throw RunJournalBundleError.invalidOperation(
                        "non-delivered prompt source retained unexpected bytes: \(source.sourceID)")
                }
            }
        }
        guard Self.promptDigest(assembled) == assemblyID,
              assembled == Data(systemText.utf8) else {
            throw RunJournalBundleError.invalidOperation(
                "prompt source assembly does not equal the retained system message")
        }
    }

    private func validateDeliveredPromptSlice(
        _ source: ContextManifestSource, delivered: Data, rendered: Data
    ) throws {
        let end = source.deliveredByteOffsetInRendered.addingReportingOverflow(delivered.count)
        guard !end.overflow, end.partialValue <= rendered.count,
              rendered.subdata(
                in: source.deliveredByteOffsetInRendered..<end.partialValue) == delivered else {
            throw RunJournalBundleError.invalidOperation(
                "prompt source framing does not contain its declared delivered bytes: \(source.sourceID)")
        }
    }

    private static func promptDigest(_ data: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// End the current run only after all actions and turns are terminal. Cursor advancement is a
    /// Session event that points at the just-committed Work run.finished record.
    public func finishRun(
        outcome: RunTerminalOutcome = .completed, detail: String? = nil
    ) async throws -> [TimelineJournalCommit] {
        try await withSemanticGate(respectCancellation: false) {
            try await self.finishRunLocked(outcome: outcome, detail: detail)
        }
    }

    private func finishRunLocked(
        outcome: RunTerminalOutcome, detail: String?
    ) async throws -> [TimelineJournalCommit] {
        try ensureUsable()
        guard activeRun != nil else { throw RunJournalBundleError.alreadyFinished("no active Run") }
        guard activeActionIDs.isEmpty else {
            throw RunJournalBundleError.unfinishedActions(activeActionIDs.sorted())
        }
        let acceptedCommands = commands.values
            .filter { $0.state == .accepted }
            .map { $0.command.commandID }
            .sorted()
        guard acceptedCommands.isEmpty else {
            throw RunJournalBundleError.unfinishedCommands(acceptedCommands)
        }
        guard activeTurn == nil else {
            throw RunJournalBundleError.invalidOperation("finish the active turn before finishing the Run")
        }
        let activeHandles = try canonicalActiveHandleIDs()
        guard activeHandles.isEmpty else {
            throw RunJournalBundleError.unfinishedHandles(activeHandles)
        }
        var outcomePayload: [String: JSONValue] = ["state": .string(outcome.rawValue)]
        if let detail, !detail.isEmpty { outcomePayload["detail"] = .string(detail) }
        let finished = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), session: session, work: work, workHost: workHost,
            sessionAttachment: sessionAttachment, run: activeRun,
            type: TimelineEventType.runFinished,
            declaredDomains: [.work], payload: .object(outcomePayload)))
        guard let cursor = workCursor else {
            throw RunJournalBundleError.invalidOperation("run.finished did not produce a Work cursor")
        }
        var commits: [TimelineJournalCommit] = [finished]
        let finalAttention: SessionAttention?
        switch outcome {
        case .failed, .indeterminate: finalAttention = .error
        case .held: finalAttention = .review
        case .canceled: finalAttention = SessionAttention.none
        case .completed: finalAttention = .review
        }
        // The attention transition must precede the attachment cursor advance. If the paired
        // Session append fails after Work has terminalized, the stale attachment keeps the
        // completed Work non-projectable instead of exposing a false ready-for-review fact.
        if let finalAttention {
            if let attentionCommit = try await appendAttentionLocked(
                finalAttention, causedBy: finished.eventRef) {
                commits.append(attentionCommit)
            }
        }
        let advanced = try await appendAttachmentCursorLocked(
            cursor, causedBy: finished.eventRef)
        activeRun = nil
        commits.append(advanced)
        return commits
    }

    /// Record a runtime Handle admission on the active Run. Handles are intentionally opaque to
    /// this coordinator; their canonical state is reread from the Work journal when the Run or
    /// Work is terminalized.
    @discardableResult
    public func startHandle(
        _ handle: HandleRef, state: String = "running"
    ) async throws -> TimelineJournalCommit {
        try await withSemanticGate {
            try self.ensureUsable()
            guard let activeRun = self.activeRun else {
                throw RunJournalBundleError.alreadyFinished("no active Run")
            }
            guard !handle.handleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RunJournalBundleError.invalidOperation("Handle identity is empty")
            }
            guard !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RunJournalBundleError.invalidOperation("Handle state is empty")
            }
            let workState = try self.canonicalWorkState()
            guard workState.handles[handle.handleID] == nil else {
                throw RunJournalBundleError.invalidOperation("Handle identity has already been used")
            }
            return try await self.appendWork(TimelineEventDraft(
                hostSequence: self.nextHostOrder(), work: self.work, workHost: self.workHost,
                run: activeRun, handle: handle, type: TimelineEventType.handleStarted,
                declaredDomains: [.work, .runtime], payload: .object([
                    "state": .string(state)
                ])))
        }
    }

    /// Record a terminal state for a previously admitted runtime Handle.
    @discardableResult
    public func finishHandle(
        _ handle: HandleRef, state: String = "completed"
    ) async throws -> TimelineJournalCommit {
        try await withSemanticGate {
            try self.ensureUsable()
            guard let activeRun = self.activeRun else {
                throw RunJournalBundleError.alreadyFinished("no active Run")
            }
            guard !handle.handleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RunJournalBundleError.invalidOperation("Handle identity is empty")
            }
            let terminalStates: Set<String> = ["succeeded", "failed", "canceled", "completed"]
            guard terminalStates.contains(state) else {
                throw RunJournalBundleError.invalidOperation(
                    "Handle outcome must use a terminal state")
            }
            let workState = try self.canonicalWorkState()
            guard let existing = workState.handles[handle.handleID],
                  !terminalStates.contains(existing.state) else {
                throw RunJournalBundleError.invalidOperation(
                    "Handle outcome requires an outstanding Handle")
            }
            return try await self.appendWork(TimelineEventDraft(
                hostSequence: self.nextHostOrder(), work: self.work, workHost: self.workHost,
                run: activeRun, handle: handle, type: TimelineEventType.handleOutcome,
                declaredDomains: [.work, .runtime], payload: .object([
                    "state": .string(state)
                ])))
        }
    }

    /// Explicitly terminalize the Work after its current Run has ended. A finished Run is not a
    /// finished Work: callers may reopen this same Work and start another Run until this method
    /// records `work.completed`.
    ///
    /// The Work record is appended first, then the mirrored Session attachment cursor is advanced
    /// to that exact Work prefix. If the paired Session append is ambiguous, the bundle is made
    /// terminal and unavailable rather than allowing a second completion or exposing a false
    /// successful pairing.
    @discardableResult
    public func completeWork(
        detail: String? = nil, command: CommandRef
    ) async throws -> [TimelineJournalCommit] {
        try await withSemanticGate(respectCancellation: false) {
            if let existing = try self.terminalCommit(for: command, detail: detail) {
                guard existing.workEvent.type == TimelineEventType.workCompleted,
                      let paired = existing.pairedSessionCommit else {
                    throw RunJournalBundleError.unavailable(
                        "the terminal Work event is not durably paired with Session")
                }
                return [existing.workCommit, paired]
            }
            return try await self.completeWorkLocked(detail: detail, command: command)
        }
    }

    private func completeWorkLocked(
        detail: String?, command: CommandRef
    ) async throws -> [TimelineJournalCommit] {
        try ensureUsable()
        try validateTerminalDetail(detail)
        try ensureWorkQuiescent()
        let normalized = try normalizedTerminalCommand(command)
        let event = try await appendWorkTerminalEvent(
            type: TimelineEventType.workCompleted, detail: detail, tombstone: false,
            command: normalized)
        guard let cursor = workCursor else {
            workLifecycle = .completed
            markTerminalPairingFailure("work.completed did not produce a Work cursor")
            throw RunJournalBundleError.invalidOperation(
                "work.completed did not produce a Work cursor")
        }
        do {
            let advanced = try await appendAttachmentCursorLocked(
                cursor, causedBy: event.eventRef, command: normalized,
                terminalType: TimelineEventType.workCompleted, terminalDetail: detail)
            workLifecycle = .completed
            return [event, advanced]
        } catch {
            // The Work terminal event is already durable. Preserve that fact locally and make
            // every further mutation fail closed if the Session half could not be paired.
            workLifecycle = .completed
            markTerminalPairingFailure(error.localizedDescription)
            throw error
        }
    }

    /// Destructively tombstone this Work. Destruction is intentionally separate from completion
    /// and requires an explicit service-level statement that host resources have been quiesced;
    /// the bundle itself only verifies the durable Run/action/Handle/command state.
    @discardableResult
    public func destroyWork(
        resourcesQuiesced: Bool, reason: String? = nil, command: CommandRef
    ) async throws -> [TimelineJournalCommit] {
        try await withSemanticGate(respectCancellation: false) {
            if let existing = try self.terminalCommit(for: command, detail: reason) {
                guard existing.workEvent.type == TimelineEventType.workDestroyed,
                      let paired = existing.pairedSessionCommit else {
                    throw RunJournalBundleError.unavailable(
                        "the terminal Work event is not durably paired with Session")
                }
                return [existing.workCommit, paired]
            }
            return try await self.destroyWorkLocked(
                resourcesQuiesced: resourcesQuiesced, reason: reason, command: command)
        }
    }

    private func destroyWorkLocked(
        resourcesQuiesced: Bool, reason: String?, command: CommandRef
    ) async throws -> [TimelineJournalCommit] {
        try ensureUsable()
        try validateTerminalDetail(reason)
        guard resourcesQuiesced else {
            throw RunJournalBundleError.invalidOperation(
                "destroying Work requires the service to confirm host resources are quiesced")
        }
        try ensureWorkQuiescent()
        let normalized = try normalizedTerminalCommand(command)
        let event = try await appendWorkTerminalEvent(
            type: TimelineEventType.workDestroyed, detail: reason, tombstone: true,
            command: normalized)
        guard let cursor = workCursor else {
            workLifecycle = .destroyed
            markTerminalPairingFailure("work.destroyed did not produce a Work cursor")
            throw RunJournalBundleError.invalidOperation(
                "work.destroyed did not produce a Work cursor")
        }
        do {
            let advanced = try await appendAttachmentCursorLocked(
                cursor, causedBy: event.eventRef, command: normalized,
                terminalType: TimelineEventType.workDestroyed, terminalDetail: reason)
            workLifecycle = .destroyed
            return [event, advanced]
        } catch {
            workLifecycle = .destroyed
            markTerminalPairingFailure(error.localizedDescription)
            throw error
        }
    }

    private func appendWorkTerminalEvent(
        type: String, detail: String?, tombstone: Bool, command: CommandRef
    ) async throws -> TimelineJournalCommit {
        guard type == TimelineEventType.workCompleted || type == TimelineEventType.workDestroyed else {
            throw RunJournalBundleError.invalidOperation("invalid Work terminal event")
        }
        let canonical = try await workWriter.readCanonicalProjection(
            expectedWork: work, expectedWorkHost: workHost, maximumResidentRecords: 0)
        guard case .work(let head) = canonical.projection,
              head.structuralIntegrityValid, head.semanticProjectionValid,
              head.causalOrderValid, head.coverage.isControlling,
              head.coverage.isIndexComplete(.agentHandles) else {
            throw RunJournalBundleError.invalidOperation(
                "Work terminalization requires a valid canonical projection")
        }
        guard head.liveAgentHandleCount == 0 else {
            throw RunJournalBundleError.invalidOperation(
                "Work cannot be terminalized while agent children remain outstanding")
        }
        if type == TimelineEventType.workDestroyed, head.unreapedAgentHandleCount != 0 {
            throw RunJournalBundleError.invalidOperation(
                "Work destruction requires agent child resources and retained results to be reaped")
        }
        var payload: [String: JSONValue] = [:]
        // Preserve the optionality exactly. Empty/whitespace detail is still a caller-supplied
        // value and participates in the terminal idempotency key; omitting it here would make a
        // cold proof reconstruction turn nonnil detail into nil and reject an otherwise exact
        // retry. Nil remains absent from the payload.
        if let detail {
            payload["detail"] = .string(detail)
        }
        if tombstone { payload["tombstone"] = .bool(true) }
        return try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(),
            idempotencyKey: terminalIdempotencyKey(
                type: type, command: command, detail: detail),
            command: command,
            causedByEventID: command.causalCursor?.eventID.map {
                EventRef(journal: workJournal, eventID: $0)
            },
            session: session, work: work, workHost: workHost,
            client: command.client, sessionAttachment: sessionAttachment,
            type: type, declaredDomains: [.work], payload: .object(payload)))
    }

    private func markTerminalPairingFailure(_ reason: String) {
        if case .failed = healthState { return }
        healthState = .failed(reason: "terminal Work event was not paired with Session: \(reason)")
        failedJournal = sessionJournal
    }

    private func ensureWorkQuiescent() throws {
        guard activeRun == nil else {
            throw RunJournalBundleError.invalidOperation(
                "Work cannot be terminalized while a Run is active")
        }
        guard activeTurn == nil else {
            throw RunJournalBundleError.invalidOperation(
                "Work cannot be terminalized while a turn is active")
        }
        guard activeActionIDs.isEmpty else {
            throw RunJournalBundleError.unfinishedActions(activeActionIDs.sorted())
        }
        // Handles are produced by the runtime boundary rather than by this coordinator. Read
        // the just-synchronized Work prefix so completion cannot silently ignore a live Handle
        // written by another component in the same Work Host.
        let activeHandles = try canonicalActiveHandleIDs()
        guard activeHandles.isEmpty else {
            throw RunJournalBundleError.unfinishedHandles(activeHandles)
        }
        let acceptedCommands = commands.values
            .filter { $0.state == .accepted }
            .map { $0.command.commandID }
            .sorted()
        guard acceptedCommands.isEmpty else {
            throw RunJournalBundleError.unfinishedCommands(acceptedCommands)
        }
    }

    private func canonicalActiveHandleIDs() throws -> [String] {
        let workState = try canonicalWorkState()
        let terminalHandleStates: Set<String> = ["succeeded", "failed", "canceled", "completed"]
        return workState.handles.values
            .filter { !terminalHandleStates.contains($0.state) }
            .map { $0.handle.handleID }
            .sorted()
    }

    private func canonicalWorkState() throws -> WorkSnapshot {
        let workEvents = try Self.readNativeJournal(
            at: workWriter.fileURL, journal: workJournal, actor: actor)
        let workState = WorkReducer.reduce(workEvents)
        guard workState.structuralIntegrityValid && workState.semanticProjectionValid else {
            throw RunJournalBundleError.invalidOperation(
                "Work cannot be terminalized while its canonical projection is invalid")
        }
        return workState
    }

    /// Read exact terminal evidence from the canonical journals. This remains available after a
    /// writer error or close so a caller can reconcile a response lost after durable commit.
    public func terminalCommit(
        for command: CommandRef, detail: String?
    ) throws -> RunJournalBundleTerminalCommit? {
        let workEvents = try Self.readNativeJournal(
            at: workWriter.fileURL, journal: workJournal, actor: actor)
        let sessionEvents = try Self.readNativeJournal(
            at: sessionWriter.fileURL, journal: sessionJournal, actor: actor)
        return try Self.terminalCommit(
            workEvents: workEvents,
            sessionEvents: sessionEvents,
            session: session,
            work: work,
            workHost: workHost,
            workJournal: workJournal,
            sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment,
            command: command,
            detail: detail)
    }

    /// Resolve one exact terminal transaction without acquiring either writer lock. This is the
    /// recovery path for a response lost after durable commit: opening a writer merely to read
    /// proof would make reconciliation fail whenever another legitimate owner already exists.
    public static func readTerminalCommit(
        home: AgentHome,
        identity: SessionWorkIdentity,
        sessionAttachment: SessionAttachmentRef,
        command: CommandRef,
        detail: String?,
        actorID: String = "work-host-terminal-reader"
    ) throws -> RunJournalBundleTerminalCommit? {
        let persistedHost = try home.requirePersistedWorkHost()
        guard identity.workHostID == persistedHost.workHostID else {
            throw RunJournalBundleError.invalidConfiguration(
                "the terminal proof Work Host does not match this AgentHome's persisted authority")
        }
        guard !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunJournalBundleError.invalidConfiguration(
                "the terminal proof reader identity is empty")
        }
        let session = SessionRef(identity.sessionID)
        let authority = TimelineAuthorityRef(persistedHost.workHostID)
        let configuration = try makeConfiguration(
            session: session,
            work: identity.work,
            workHost: persistedHost,
            sessionAuthority: authority,
            sessionAttachment: sessionAttachment,
            run: RunRef(identity.runID))
        let actor = TimelineActor(actorID: actorID, kind: "work-host-terminal-reader")
        let sessionEvents = try readNativeJournal(
            at: home.timelineV2SessionJournalURL(session),
            journal: configuration.sessionJournal,
            actor: actor)
        let workEvents = try readNativeJournal(
            at: home.timelineV2WorkJournalURL(identity.work),
            journal: configuration.workJournal,
            actor: actor)
        try validateGenesis(
            sessionEvents,
            journal: configuration.sessionJournal,
            expectedType: TimelineEventType.sessionCreated)
        try validateGenesis(
            workEvents,
            journal: configuration.workJournal,
            expectedType: TimelineEventType.workCreated)
        let sessionState = SessionReducer.reduce(sessionEvents)
        let workState = WorkReducer.reduce(workEvents)
        guard sessionState.structuralIntegrityValid && sessionState.semanticProjectionValid else {
            throw RunJournalBundleError.invalidJournal(
                journal: configuration.sessionJournal,
                reason: sessionState.corruptionReasons.joined(separator: "; "))
        }
        guard workState.structuralIntegrityValid && workState.semanticProjectionValid else {
            throw RunJournalBundleError.invalidJournal(
                journal: configuration.workJournal,
                reason: workState.corruptionReasons.joined(separator: "; "))
        }
        try validatePairedAttachment(
            sessionEvents: sessionEvents,
            workEvents: workEvents,
            session: session,
            work: identity.work,
            attachment: sessionAttachment,
            sessionJournal: configuration.sessionJournal)
        return try terminalCommit(
            workEvents: workEvents,
            sessionEvents: sessionEvents,
            session: session,
            work: identity.work,
            workHost: persistedHost,
            workJournal: configuration.workJournal,
            sessionJournal: configuration.sessionJournal,
            sessionAttachment: sessionAttachment,
            command: command,
            detail: detail)
    }

    private static func terminalCommit(
        workEvents: [TimelineEvent],
        sessionEvents: [TimelineEvent],
        session: SessionRef,
        work: WorkRef,
        workHost: WorkHostRef,
        workJournal: JournalRef,
        sessionJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef,
        command: CommandRef,
        detail: String?
    ) throws -> RunJournalBundleTerminalCommit? {
        let terminalEvents = workEvents.filter {
            ($0.type == TimelineEventType.workCompleted
                || $0.type == TimelineEventType.workDestroyed)
                && $0.command == command
        }
        guard terminalEvents.count <= 1 else {
            throw RunJournalBundleError.invalidJournal(
                journal: workJournal,
                reason: "one terminal command produced multiple Work events")
        }
        guard let workEvent = terminalEvents.first else { return nil }
        let workCommit = TimelineJournalCommit(
            eventRef: EventRef(journal: workJournal, eventID: workEvent.eventID),
            cursor: JournalCursor(
                journal: workJournal, eventID: workEvent.eventID,
                sequence: workEvent.sequence))
        guard workEvent.session == session,
              workEvent.work == work,
              workEvent.workHost == workHost,
              workEvent.client == command.client,
              workEvent.sessionAttachment == sessionAttachment,
              workEvent.idempotencyKey == terminalIdempotencyKey(
                  type: workEvent.type, command: command, detail: detail),
              workEvent.causedByEventID == command.causalCursor?.eventID.map({
                  EventRef(journal: workJournal, eventID: $0)
              }) else {
            throw RunJournalBundleError.invalidJournal(
                journal: workJournal,
                reason: "terminal Work event does not match its exact command envelope")
        }

        let paired = sessionEvents.filter {
            $0.type == TimelineEventType.sessionAttachmentCursorAdvanced
                && $0.command == command
                && $0.session == session
                && $0.client == command.client
                && $0.sessionAttachment == sessionAttachment
                && $0.causedByEventID == workCommit.eventRef
                && $0.idempotencyKey == terminalIdempotencyKey(
                    type: workEvent.type, command: command, detail: detail) + ":session"
                && $0.payload["cursor"] == encodeTimelineValue(workCommit.cursor)
        }
        guard paired.count <= 1 else {
            throw RunJournalBundleError.invalidJournal(
                journal: sessionJournal,
                reason: "one terminal Work event produced multiple Session cursor pairs")
        }
        let pairedEvent = paired.first
        let pairedCommit = pairedEvent.map {
            TimelineJournalCommit(
                eventRef: EventRef(journal: sessionJournal, eventID: $0.eventID),
                cursor: JournalCursor(
                    journal: sessionJournal, eventID: $0.eventID, sequence: $0.sequence))
        }
        let reduced = WorkReducer.reduce(workEvents)
        guard reduced.structuralIntegrityValid && reduced.semanticProjectionValid else {
            throw RunJournalBundleError.invalidJournal(
                journal: workJournal,
                reason: reduced.corruptionReasons.joined(separator: "; "))
        }
        let terminalHandleStates: Set<String> = ["succeeded", "failed", "canceled", "completed"]
        let handles = (reduced.handles.values
            .filter { !terminalHandleStates.contains($0.state) }
            .map(\.handle)
            + reduced.agentHandles.values.filter { $0.blocksWorkCompletion }.map(\.handle))
            .sorted { $0.handleID < $1.handleID }
        return RunJournalBundleTerminalCommit(
            workEvent: workEvent, workCommit: workCommit,
            pairedSessionEvent: pairedEvent, pairedSessionCommit: pairedCommit,
            outstandingHandleIDs: handles)
    }

    private func normalizedTerminalCommand(_ command: CommandRef) throws -> CommandRef {
        guard !command.commandID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let client = command.client,
              command.sessionAttachment == sessionAttachment,
              let causal = command.causalCursor,
              causal == workCursor else {
            throw RunJournalBundleError.invalidOperation(
                "terminal command must carry its client, Session attachment, and exact Work cursor")
        }
        guard commands[command.commandID] == nil else {
            throw RunJournalBundleError.invalidOperation(
                "terminal command identity has already been used")
        }
        return CommandRef(
            commandID: command.commandID, client: client,
            sessionAttachment: sessionAttachment, causalCursor: causal)
    }

    private func validateTerminalDetail(_ detail: String?) throws {
        guard detail?.utf8.count ?? 0 <= 4_000 else {
            throw RunJournalBundleError.invalidOperation(
                "Work terminal detail exceeds the 4,000-byte limit")
        }
    }

    private func appendAttachmentCursorLocked(
        _ cursor: JournalCursor, causedBy cause: EventRef,
        command: CommandRef? = nil, terminalType: String? = nil,
        terminalDetail: String? = nil
    ) async throws -> TimelineJournalCommit {
        try ensureUsable()
        return try await appendSession(TimelineEventDraft(
            hostSequence: nextHostOrder(),
            idempotencyKey: terminalPairIdempotencyKey(
                type: terminalType, command: command, detail: terminalDetail),
            command: command, causedByEventID: cause,
            session: session, client: command?.client,
            sessionAttachment: sessionAttachment,
            type: TimelineEventType.sessionAttachmentCursorAdvanced,
            declaredDomains: [.session, .work], payload: .object([
                "cursor": encodeTimelineValue(cursor)
            ])))
    }

    /// Close both files and report which durable prefix survived a partial close.
    /// Separate from health: a prior ambiguous write remains failed even after both writer
    /// close paths release their handles, allowing a later canonical read without replay.
    public var writersClosed: Bool { isClosed }

    public func closeChecked() async throws {
        try await withSemanticGate(respectCancellation: false) {
            try await self.closeCheckedLocked()
        }
    }

    private func closeCheckedLocked() async throws {
        guard !isClosed else { return }
        var firstFailure: Error?
        do { try await sessionWriter.closeChecked() } catch {
            firstFailure = error
            failedJournal = sessionJournal
        }
        do { try await workWriter.closeChecked() } catch {
            if firstFailure == nil { firstFailure = error; failedJournal = workJournal }
        }
        isClosed = true
        if let firstFailure {
            let reason = firstFailure.localizedDescription
            healthState = .failed(reason: reason)
            throw RunJournalBundleError.closeFailed(status.durablePrefix, reason: reason)
        }
        healthState = .closed
    }

    // MARK: - Private coordination

    /// Bounded-output Handle lookup through this bundle's existing owner lease. The current
    /// implementation replays the full Work journal; it is not a bounded-cost read. Reads and lifecycle
    /// mutations share the semantic gate, including the transition to a closed bundle.
    public func agentHandleHead() async throws -> BoundedWorkReducerHead {
        try await withSemanticGate(respectCancellation: false) {
            guard !self.isClosed, self.healthState == .healthy else {
                throw RunJournalBundleError.unavailable("Work writer is unavailable")
            }
            let read = try await self.workWriter.readCanonicalProjection(
                expectedWork: self.work, expectedWorkHost: self.workHost,
                maximumResidentRecords: 0)
            guard case .work(let head) = read.projection, head.coverage.isControlling,
                  head.coverage.isIndexComplete(.agentHandles) else {
                throw RunJournalBundleError.unavailable("Agent Handle projection is incomplete")
            }
            return head
        }
    }

    /// Route ownership includes the canonical file location, not only copied logical IDs.
    internal func ownsAgentHandleJournal(at url: URL) -> Bool {
        workWriter.fileURL.standardizedFileURL == url.standardizedFileURL
    }

    /// Borrow the Run's existing Work writer for one host-owned child transition. The event
    /// repeats its immutable origin; it need not belong to the current Run, and finishing this
    /// Run does not forbid a child outcome while this bundle still owns the writer. After close,
    /// the Work-level coordinator must explicitly acquire a new writer; this method never does.
    @discardableResult
    public func appendAgentHandle(_ draft: TimelineEventDraft) async throws -> TimelineJournalCommit {
        try await withSemanticGate(respectCancellation: false) {
            if self.isClosed {
                switch self.healthState {
                case .closed:
                    throw RunJournalBundleError.closedBeforeAgentAppend
                case .failed(let reason):
                    // A close failure may retain an earlier ambiguous durable prefix. It is not
                    // a clean pre-write handoff merely because both close paths were attempted.
                    throw RunJournalBundleError.unavailable(reason)
                case .healthy:
                    throw RunJournalBundleError.unavailable("bundle is closed")
                }
            }
            if self.workLifecycle == .completed && draft.type == TimelineEventType.agentHandleReaped {
                guard self.healthState == .healthy else {
                    throw RunJournalBundleError.unavailable("Work writer is unavailable")
                }
            } else {
                try self.ensureUsable()
            }
            let commit: TimelineJournalCommit
            do {
                commit = try await self.workWriter.appendAgentHandle(draft)
            } catch let error as TimelineJournalWriter.WriterError {
                if case .failed = await self.workWriter.health {
                    self.latch(error, journal: self.workJournal)
                }
                throw RunJournalBundleError.writer(error)
            }
            self.workCursor = commit.cursor
            self.workEventCount += 1
            if let order = draft.hostSequence { self.hostOrder = max(self.hostOrder, order) }
            return commit
        }
    }

    /// Actor isolation alone is not sufficient here: every writer append awaits, and Swift
    /// actors may re-enter between those awaits. This FIFO gate keeps one semantic operation's
    /// multi-event protocol contiguous while still allowing status/cursor reads to proceed.
    private func withSemanticGate<T>(
        respectCancellation: Bool = true,
        _ operation: () async throws -> T
    ) async throws -> T {
        await acquireSemanticGate()
        do {
            if respectCancellation { try Task.checkCancellation() }
            let result = try await operation()
            releaseSemanticGate()
            return result
        } catch {
            releaseSemanticGate()
            throw error
        }
    }

    private func acquireSemanticGate() async {
        if !semanticGateHeld {
            semanticGateHeld = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            semanticGateWaiters.append(continuation)
        }
    }

    private func releaseSemanticGate() {
        if semanticGateWaiters.isEmpty {
            semanticGateHeld = false
        } else {
            semanticGateWaiters.removeFirst().resume()
        }
    }

    private func appendSession(_ draft: TimelineEventDraft) async throws -> TimelineJournalCommit {
        do {
            let commit = try await sessionWriter.append(draft)
            sessionCursor = commit.cursor
            sessionEventCount += 1
            if let hostSequence = draft.hostSequence { hostOrder = max(hostOrder, hostSequence) }
            return commit
        } catch let error as TimelineJournalWriter.WriterError {
            latch(error, journal: sessionJournal)
            throw RunJournalBundleError.writer(error)
        } catch {
            let wrapped = TimelineJournalWriter.WriterError.unavailable(error.localizedDescription)
            latch(wrapped, journal: sessionJournal)
            throw RunJournalBundleError.writer(wrapped)
        }
    }

    private func appendWork(_ draft: TimelineEventDraft) async throws -> TimelineJournalCommit {
        do {
            let commit = try await workWriter.append(draft)
            workCursor = commit.cursor
            workEventCount += 1
            if let hostSequence = draft.hostSequence { hostOrder = max(hostOrder, hostSequence) }
            return commit
        } catch let error as TimelineJournalWriter.WriterError {
            latch(error, journal: workJournal)
            throw RunJournalBundleError.writer(error)
        } catch {
            let wrapped = TimelineJournalWriter.WriterError.unavailable(error.localizedDescription)
            latch(wrapped, journal: workJournal)
            throw RunJournalBundleError.writer(wrapped)
        }
    }

    private func appendFreshGenesis(modelID: String?) async throws {
        _ = try await appendSession(TimelineEventDraft(
            hostSequence: nextHostOrder(), session: session,
            type: TimelineEventType.sessionCreated, declaredDomains: [.session]))
        _ = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), work: work, workHost: workHost,
            type: TimelineEventType.workCreated, declaredDomains: [.work]))
        let sessionAttach = try await appendSession(TimelineEventDraft(
            hostSequence: nextHostOrder(), session: session, work: work,
            sessionAttachment: sessionAttachment, type: TimelineEventType.sessionAttached,
            declaredDomains: [.session, .work], payload: .object(["capabilities": .array([])])))
        _ = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), causedByEventID: sessionAttach.eventRef,
            session: session, work: work, workHost: workHost,
            sessionAttachment: sessionAttachment,
            type: TimelineEventType.sessionAttached, declaredDomains: [.work, .session],
            payload: .object(["capabilities": .array([])])))
        try await appendRunStarted(modelID: modelID)
    }

    private func appendRunStarted(modelID: String?) async throws {
        var payload: [String: JSONValue] = [:]
        if let modelID { payload["model_id"] = .string(modelID) }
        let predecessor = workCursor
        _ = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), session: session, work: work, workHost: workHost,
            sessionAttachment: sessionAttachment, run: run,
            type: TimelineEventType.runStarted, declaredDomains: [.work, .session],
            payload: .object(payload)))
        runStartPredecessorCursor = predecessor
        activeRun = run
    }

    private func ensureUsable() throws {
        guard !isClosed else { throw RunJournalBundleError.unavailable("bundle is closed") }
        if case .failed(let reason) = healthState {
            throw RunJournalBundleError.unavailable(reason)
        }
        guard healthState == .healthy else {
            throw RunJournalBundleError.unavailable("bundle is unavailable")
        }
        guard workLifecycle == .active else {
            throw RunJournalBundleError.workTerminal(workLifecycle)
        }
    }

    private func ensureRunActive() throws {
        guard activeRun != nil else {
            throw RunJournalBundleError.alreadyFinished("no active Run")
        }
    }

    private func nextHostOrder() -> Int {
        // A candidate is not part of the durable prefix until the writer returns after its
        // synchronize. This is important when a before-write/sync failure latches the bundle.
        hostOrder + 1
    }

    private func latch(_ error: TimelineJournalWriter.WriterError, journal: JournalRef) {
        healthState = .failed(reason: error.localizedDescription)
        failedJournal = journal
    }

    private struct Configuration {
        let sessionJournal: JournalRef
        let workJournal: JournalRef
    }

    private static func makeConfiguration(
        session: SessionRef, work: WorkRef, workHost: WorkHostRef,
        sessionAuthority: TimelineAuthorityRef, sessionAttachment: SessionAttachmentRef,
        run: RunRef
    ) throws -> Configuration {
        guard !run.runID.isEmpty else {
            throw RunJournalBundleError.invalidConfiguration("all identities are required")
        }
        return try makeJournalConfiguration(
            session: session,
            work: work,
            workHost: workHost,
            sessionAuthority: sessionAuthority,
            sessionAttachment: sessionAttachment)
    }

    private static func makeJournalConfiguration(
        session: SessionRef,
        work: WorkRef,
        workHost: WorkHostRef,
        sessionAuthority: TimelineAuthorityRef,
        sessionAttachment: SessionAttachmentRef
    ) throws -> Configuration {
        guard !session.sessionID.isEmpty,
              !work.workID.isEmpty,
              !workHost.workHostID.isEmpty,
              work.workHostID == workHost.workHostID,
              !sessionAuthority.authorityID.isEmpty,
              !sessionAttachment.attachmentID.isEmpty else {
            throw RunJournalBundleError.invalidConfiguration("all identities are required")
        }
        let sessionJournal = JournalRef.session(
            session, journalID: "session", authority: sessionAuthority)
        let workJournal = JournalRef.work(work, journalID: "work")
        return Configuration(sessionJournal: sessionJournal, workJournal: workJournal)
    }

    private static func mapWriterOpenError(
        _ error: TimelineJournalWriter.WriterError
    ) -> RunJournalBundleError {
        if case .competingWriter(let path) = error {
            return .duplicateActiveWriter(path: path)
        }
        return .writer(error)
    }

    private static func readNativeJournal(
        at url: URL, journal: JournalRef, actor: TimelineActor
    ) throws -> [TimelineEvent] {
        do {
            return try TimelineJournalWriter.readNativeEventsStreaming(
                at: url, journal: journal, actor: actor)
        } catch {
            throw RunJournalBundleError.invalidJournal(
                journal: journal, reason: error.localizedDescription)
        }
    }

    private static func validateGenesis(
        _ events: [TimelineEvent], journal: JournalRef, expectedType: String
    ) throws {
        guard let first = events.first, first.sequence == 1, first.type == expectedType else {
            throw RunJournalBundleError.invalidGenesis(
                journal: journal, reason: "first event must be \(expectedType) at sequence 1")
        }
        guard events.dropFirst().allSatisfy({ $0.type != expectedType }) else {
            throw RunJournalBundleError.invalidGenesis(
                journal: journal, reason: "genesis event appears more than once")
        }
    }

    private static func validatePairedAttachment(
        sessionEvents: [TimelineEvent], workEvents: [TimelineEvent],
        session: SessionRef, work: WorkRef, attachment: SessionAttachmentRef,
        sessionJournal: JournalRef
    ) throws {
        let sessionMatches = sessionEvents.filter {
            $0.type == TimelineEventType.sessionAttached
                && $0.session == session && $0.work == work
                && $0.sessionAttachment == attachment
        }
        let workMatches = workEvents.filter {
            $0.type == TimelineEventType.sessionAttached
                && $0.session == session && $0.work == work
                && $0.sessionAttachment == attachment
        }
        guard !sessionMatches.isEmpty, !workMatches.isEmpty else {
            throw RunJournalBundleError.invalidGenesis(
                journal: sessionJournal,
                reason: "the Session/Work attachment mirror is incomplete")
        }
    }

    private static func cursor(
        for event: TimelineEvent?, journal: JournalRef
    ) -> JournalCursor? {
        guard let event else { return nil }
        return JournalCursor(journal: journal, eventID: event.eventID, sequence: event.sequence)
    }
}

private func encodeTimelineValue<T: Encodable>(_ value: T) -> JSONValue {
    guard let data = try? JSONEncoder().encode(value), let decoded = JSONValue.parse(data) else {
        return .null
    }
    return decoded
}

private func terminalIdempotencyKey(
    type: String, command: CommandRef, detail: String?
) -> String {
    func component(_ value: String) -> String { "\(value.utf8.count):\(value)" }
    let client = command.client?.clientID ?? ""
    let attachment = command.sessionAttachment?.attachmentID ?? ""
    let cursor = command.causalCursor
    let detailComponent = detail.map { "some:\(component($0))" } ?? "none"
    return "work-terminal:v1/type:\(component(type))"
        + "/command:\(component(command.commandID))"
        + "/client:\(component(client))"
        + "/attachment:\(component(attachment))"
        + "/journal:\(component(cursor?.journal.stableKey ?? ""))"
        + "/sequence:\(cursor?.sequence ?? -1)"
        + "/event:\(component(cursor?.eventID ?? ""))"
        + "/detail:\(detailComponent)"
}

private func terminalPairIdempotencyKey(
    type: String?, command: CommandRef?, detail: String?
) -> String? {
    guard let type, let command else { return nil }
    return terminalIdempotencyKey(type: type, command: command, detail: detail) + ":session"
}
