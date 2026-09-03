import CryptoKit
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

    fileprivate init(action: ActionRef, kind: ActionKind, intent: String,
                     intentCommit: TimelineJournalCommit,
                     startedCommit: TimelineJournalCommit) {
        self.action = action
        self.kind = kind
        self.intent = intent
        self.intentCommit = intentCommit
        self.startedCommit = startedCommit
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
    private var commands: [String: WorkCommandSnapshot]
    private var commandAcceptedRefs: [String: EventRef]
    private var permits: [String: EffectPermit]
    private var activeTurn: TurnRef?
    private var activeRun: RunRef?
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
        commands: [String: WorkCommandSnapshot] = [:],
        commandAcceptedRefs: [String: EventRef] = [:], permits: [String: EffectPermit] = [:],
        activeTurn: TurnRef? = nil, activeRun: RunRef? = nil,
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
        self.commands = commands
        self.commandAcceptedRefs = commandAcceptedRefs
        self.permits = permits
        self.activeTurn = activeTurn
        self.activeRun = activeRun
        self.workLifecycle = workLifecycle
        self.lastMessage = lastMessage
        self.authoredAttention = authoredAttention
        self.contextDeliveredBytesByRun = contextDeliveredBytesByRun
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
        now: @escaping @Sendable () -> Date = { Date() }
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
            guard workState.activeRun == nil, workState.activeTurn == nil else {
                throw RunJournalBundleError.invalidOperation(
                    "the previous Run is still active; finish it before cold resume")
            }
            guard workState.lifecycle == .active else {
                throw RunJournalBundleError.workTerminal(workState.lifecycle)
            }
            guard !workEvents.contains(where: { $0.run?.runID == run.runID }) else {
                throw RunJournalBundleError.invalidOperation(
                    "the replacement Run identity already appears in the Work journal")
            }
            try validatePairedAttachment(
                sessionEvents: sessionEvents, workEvents: workEvents,
                session: session, work: work, attachment: sessionAttachment,
                sessionJournal: configuration.sessionJournal)

            let sessionCursor = cursor(for: sessionEvents.last, journal: configuration.sessionJournal)
            let workCursor = cursor(for: workEvents.last, journal: configuration.workJournal)
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
                seenActionIDs: Set(workState.actions.keys), commands: workState.commands,
                commandAcceptedRefs: workEvents.reduce(into: [String: EventRef]()) { refs, event in
                    guard event.type == TimelineEventType.commandAccepted,
                          let command = event.command,
                          refs[command.commandID] == nil else { return }
                    refs[command.commandID] = EventRef(
                        journal: configuration.workJournal, eventID: event.eventID)
                },
                activeTurn: workState.activeTurn, activeRun: run,
                workLifecycle: workState.lifecycle,
                lastMessage: sessionState.semanticTip ?? sessionState.messageHistory.last.map {
                    EventRef(journal: configuration.sessionJournal, eventID: $0.eventID)
                },
                authoredAttention: sessionState.attention,
                contextDeliveredBytesByRun:
                    sessionState.contextCumulativeDeliveredBytesByRun ?? [:])
            do {
                try await bundle.appendRunStarted(modelID: modelID ?? workState.modelID)
                return bundle
            } catch {
                let prefix = await bundle.status.durablePrefix
                try? await bundle.closeChecked()
                throw RunJournalBundleError.initializationFailed(prefix, reason: error.localizedDescription)
            }
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

    public var latestSessionCursor: JournalCursor? { sessionCursor }
    public var latestWorkCursor: JournalCursor? { workCursor }
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

    private func commitInputLocked(
        text: String,
        deliveryMode: RunInputDeliveryMode,
        command: CommandRef,
        metadata: [String: JSONValue]
    ) async throws -> [TimelineJournalCommit] {
        let accepted = try await acceptCommandLocked(
            command, deliveryMode: deliveryMode, payload: metadata)
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
            sessionAttachment: sessionAttachment,
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
            return try await self.acceptCommandLocked(
                command, deliveryMode: deliveryMode, payload: payload).commits
        }
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
                run: self.activeRun,
                type: TimelineEventType.commandRejected,
                declaredDomains: [.work], payload: .object(payload)))
            self.commands[normalized.commandID] = WorkCommandSnapshot(
                command: normalized, state: .rejected, actor: self.actor,
                hostSequence: hostOrder,
                idempotencyKey: "\(command.commandID):rejected",
                acceptanceEventRef: commit.eventRef)
            return commit
        }
    }

    private func acceptCommandLocked(
        _ command: CommandRef,
        deliveryMode: RunInputDeliveryMode,
        payload extraPayload: [String: JSONValue]
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
        guard let causal = command.causalCursor ?? workCursor,
              causal.journal == workJournal,
              causal.sequence == workCursor?.sequence,
              causal.eventID == workCursor?.eventID
        else {
            throw RunJournalBundleError.invalidOperation(
                "command must carry the current pre-receipt Work cursor")
        }
        let normalized = CommandRef(
            commandID: command.commandID, client: command.client,
            sessionAttachment: sessionAttachment, causalCursor: causal)
        let acceptedHostOrder = nextHostOrder()
        var payload = extraPayload
        payload["delivery_mode"] = .string(deliveryMode.rawValue)
        let accepted = try await appendWork(TimelineEventDraft(
            hostSequence: acceptedHostOrder, idempotencyKey: "\(command.commandID):accepted",
            command: normalized,
            causedByEventID: causal.eventID.map { EventRef(journal: workJournal, eventID: $0) },
            session: nil, work: work, workHost: workHost,
            client: command.client, sessionAttachment: sessionAttachment,
            type: TimelineEventType.commandAccepted,
            declaredDomains: [.work], payload: .object(payload)))
        commands[normalized.commandID] = WorkCommandSnapshot(
            command: normalized, state: .accepted, actor: actor,
            hostSequence: acceptedHostOrder,
            idempotencyKey: "\(command.commandID):accepted",
            acceptanceEventRef: accepted.eventRef)
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
            deliveryIdempotencyKey: "\(commandID):delivered")
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
            deliveryIdempotencyKey: "\(commandID):\(state.rawValue)")
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
            declaredDomains: [.work]))
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
            try await self.beginActionLocked(action: action, kind: kind, intent: intent,
                                              target: target, scope: scope, metadata: metadata)
        }
    }

    /// Append a context crossing and the provider action it authorizes as one semantic unit.
    /// The Session event is written first, then the Work action carries both a causal reference
    /// and an evidence edge back to it. A caller must retain the returned permit until the
    /// provider request has settled.
    public func prepareModelCrossing(
        manifest: ContextManifest,
        action: ActionRef = ActionRef(UUID().uuidString.lowercased()),
        kind: ActionKind,
        intent: String = "Request the next model response",
        target: String? = nil
    ) async throws -> EffectPermit {
        try await withSemanticGate {
            try self.ensureUsable()
            try self.ensureRunActive()
            guard kind == .provider || kind == .compactionProvider else {
                throw RunJournalBundleError.invalidOperation(
                    "a model crossing requires a provider action kind")
            }
            let contextCommit = try await self.appendContextManifestLocked(manifest)
            return try await self.beginActionLocked(
                action: action, kind: kind, intent: intent, target: target, scope: "run",
                metadata: ["request_id": .string(manifest.requestID)],
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
        let intentCommit = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), causedByEventID: causedBy,
            work: work, workHost: workHost,
            run: activeRun, action: action, type: TimelineEventType.actionIntent,
            declaredDomains: [.work, .externalEffects], links: links, payload: .object(payload)))
        let startedCommit = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), causedByEventID: intentCommit.eventRef,
            parentActivityID: intentCommit.eventRef,
            work: work, workHost: workHost,
            run: activeRun, action: action,
            type: TimelineEventType.actionStarted,
            declaredDomains: [.work, .externalEffects], payload: .object([
                "state": .string(ActionExecutionState.running.rawValue),
                "kind": .string(kind.rawValue)
            ])))
        let permit = EffectPermit(action: action, kind: kind, intent: intent,
                                  intentCommit: intentCommit, startedCommit: startedCommit)
        seenActionIDs.insert(action.actionID)
        activeActionIDs.insert(action.actionID)
        permits[action.actionID] = permit
        return permit
    }

    public func finishAction(
        _ permit: EffectPermit,
        state: ActionExecutionState,
        retrySafety: ActionRetrySafety,
        failureKind: ActionFailureKind? = nil
    ) async throws -> TimelineJournalCommit {
        try await withSemanticGate(respectCancellation: false) {
            try await self.finishActionLocked(permit, state: state,
                                               retrySafety: retrySafety, failureKind: failureKind)
        }
    }

    private func finishActionLocked(
        _ permit: EffectPermit,
        state: ActionExecutionState,
        retrySafety: ActionRetrySafety,
        failureKind: ActionFailureKind?
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
        var outcomePayload: [String: JSONValue] = [
            "state": .string(state.rawValue),
            "retry_safety": .string(retrySafety.rawValue),
            "kind": .string(permit.kind.rawValue)
        ]
        if let failureKind { outcomePayload["failure_kind"] = .string(failureKind.rawValue) }
        let commit = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), causedByEventID: permit.startedCommit.eventRef,
            parentActivityID: permit.startedCommit.eventRef,
            work: work, workHost: workHost,
            run: activeRun, action: permit.action,
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
            session: session, run: activeRun,
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
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
            hostSequence: nextHostOrder(), work: work, workHost: workHost,
            run: activeRun, type: TimelineEventType.runFinished,
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
        var payload: [String: JSONValue] = [:]
        if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

        let sessionEvents = try Self.readNativeJournal(
            at: sessionWriter.fileURL, journal: sessionJournal, actor: actor)
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
        let handles = reduced.handles.values
            .filter { !terminalHandleStates.contains($0.state) }
            .map(\.handle)
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
        guard detail?.count ?? 0 <= 4_000 else {
            throw RunJournalBundleError.invalidOperation(
                "Work terminal detail exceeds the 4,000-character limit")
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
        _ = try await appendWork(TimelineEventDraft(
            hostSequence: nextHostOrder(), work: work, workHost: workHost,
            run: run, type: TimelineEventType.runStarted, declaredDomains: [.work],
            payload: .object(payload)))
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
        guard !session.sessionID.isEmpty, !work.workID.isEmpty,
              !workHost.workHostID.isEmpty, work.workHostID == workHost.workHostID,
              !sessionAttachment.attachmentID.isEmpty, !run.runID.isEmpty else {
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
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw RunJournalBundleError.invalidJournal(journal: journal, reason: error.localizedDescription) }
        let read = TimelineJournalReader.read(
            data, journal: journal, actor: actor, hostRecordedAt: Date(timeIntervalSince1970: 0))
        guard read.quarantinedSuffix == nil, read.truncatedTail == nil, !read.records.isEmpty else {
            throw RunJournalBundleError.invalidJournal(
                journal: journal, reason: "journal is empty, corrupt, or has an incomplete tail")
        }
        guard read.records.allSatisfy({ $0.event.provenance == .native }) else {
            throw RunJournalBundleError.invalidJournal(journal: journal, reason: "legacy event in native bundle")
        }
        return read.records.map(\.event)
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
