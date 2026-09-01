import Foundation

/// The globally addressable identity of Work.
///
/// A bare work id is only meaningful inside one Work Host. Keeping the host beside it makes
/// attachment, logging, and a future remote client unambiguous without making a local path or
/// process id part of the identity.
public struct WorkRef: Codable, Hashable, Sendable {
    public let workHostID: String
    public let workID: String

    public init(workHostID: String, workID: String) {
        self.workHostID = workHostID
        self.workID = workID
    }
}

/// Identities allocated before a run starts.
///
/// Session and Work are intentionally separate even during the initial in-process one-to-one
/// implementation. A resumed session reuses its session/work identities and gets a new run id;
/// callers can do that by passing the existing ids to `allocate`.
public struct SessionWorkIdentity: Codable, Hashable, Sendable {
    public let sessionID: String
    public let work: WorkRef
    public let runID: String

    public var workHostID: String { work.workHostID }
    public var workID: String { work.workID }

    public init(sessionID: String, work: WorkRef, runID: String) {
        self.sessionID = sessionID
        self.work = work
        self.runID = runID
    }

    /// Allocate every identity before a driver, provider, or runtime host is started.
    ///
    /// Explicit ids are useful when resuming. The allocator does not derive one identity from
    /// another: session and Work must remain independently addressable as the process split grows.
    public static func allocate(
        workHostID: String,
        sessionID: String? = nil,
        workID: String? = nil,
        runID: String? = nil,
        makeID: @Sendable (String) -> String = { prefix in
            "\(prefix)-\(UUID().uuidString.lowercased())"
        }
    ) -> SessionWorkIdentity {
        SessionWorkIdentity(
            sessionID: sessionID ?? makeID("session"),
            work: WorkRef(workHostID: workHostID, workID: workID ?? makeID("work")),
            runID: runID ?? makeID("run"))
    }
}

/// The cancellation scopes the current core can honestly promise.
///
/// This is deliberately not inferred from the presence of a process or Python runtime. A
/// caller must declare a scope as supported, and the controller rejects an undeclared scope.
public enum SessionCancellationScope: String, Codable, CaseIterable, Hashable, Sendable {
    /// Ask the Aviary agent loop to stop at its next safe boundary. This does not interrupt a
    /// provider stream or an already-running Python action; the driver acknowledges it only
    /// after the agent is quiescent.
    case agentLoop
    /// Reserved for an engine that can actually interrupt the provider's model stream.
    case modelStream
    /// Reserved for an engine that can actually target the currently executing action.
    case currentAction
}

/// The commands that all session producers (composer, scheduler, notifications, and future
/// service clients) must pass through before touching a driver.
public enum SessionCommand: Codable, Hashable, Sendable {
    case start(prompt: String)
    case send(prompt: String)
    case steer(text: String)
    case queueFollowUp(text: String)
    case cancel(scope: SessionCancellationScope)
    case endRun

    private enum CodingKeys: String, CodingKey { case kind, value }

    private enum Kind: String, Codable {
        case start, send, steer, queueFollowUp, cancel, endRun
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .start(let prompt):
            try container.encode(Kind.start, forKey: .kind)
            try container.encode(prompt, forKey: .value)
        case .send(let prompt):
            try container.encode(Kind.send, forKey: .kind)
            try container.encode(prompt, forKey: .value)
        case .steer(let text):
            try container.encode(Kind.steer, forKey: .kind)
            try container.encode(text, forKey: .value)
        case .queueFollowUp(let text):
            try container.encode(Kind.queueFollowUp, forKey: .kind)
            try container.encode(text, forKey: .value)
        case .cancel(let scope):
            try container.encode(Kind.cancel, forKey: .kind)
            try container.encode(scope, forKey: .value)
        case .endRun:
            try container.encode(Kind.endRun, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .start:
            self = .start(prompt: try container.decode(String.self, forKey: .value))
        case .send:
            self = .send(prompt: try container.decode(String.self, forKey: .value))
        case .steer:
            self = .steer(text: try container.decode(String.self, forKey: .value))
        case .queueFollowUp:
            self = .queueFollowUp(text: try container.decode(String.self, forKey: .value))
        case .cancel:
            self = .cancel(
                scope: try container.decode(SessionCancellationScope.self, forKey: .value))
        case .endRun:
            self = .endRun
        }
    }

    var label: String {
        switch self {
        case .start: return "start"
        case .send: return "send"
        case .steer: return "steer"
        case .queueFollowUp: return "queue_follow_up"
        case .cancel: return "cancel"
        case .endRun: return "end_run"
        }
    }

    var textValue: String? {
        switch self {
        case .start: return nil
        case .send(let prompt): return prompt
        case .steer(let text), .queueFollowUp(let text): return text
        case .cancel, .endRun: return nil
        }
    }
}

/// Lifecycle the controller can establish from explicit driver acknowledgements.
public enum SessionCommandState: String, Codable, Hashable, Sendable {
    /// Identities exist, but no start command has been admitted.
    case prepared
    /// A start command was admitted and setup/provider/runtime work is in progress.
    case preparing
    /// A model turn or action is in progress.
    case running
    /// A command was admitted and its legacy intent record is being durably committed.
    case committing
    /// The run is alive and can accept a new prompt.
    case idle
    /// A declared cancellation request was admitted and awaits acknowledgement.
    case canceling
    case failed
    /// End was admitted and awaits the driver's teardown acknowledgement.
    case ending
    case ended
}

public struct SessionCommandCapabilities: Codable, Hashable, Sendable {
    public var supportsSteering: Bool
    public var supportsQueuedFollowUps: Bool
    public var cancellationScopes: Set<SessionCancellationScope>

    public init(
        supportsSteering: Bool = false,
        supportsQueuedFollowUps: Bool = false,
        cancellationScopes: Set<SessionCancellationScope> = []
    ) {
        self.supportsSteering = supportsSteering
        self.supportsQueuedFollowUps = supportsQueuedFollowUps
        self.cancellationScopes = cancellationScopes
    }

    public func supports(_ scope: SessionCancellationScope) -> Bool {
        cancellationScopes.contains(scope)
    }
}

/// A command accepted into the serialized session order.
public struct AdmittedSessionCommand: Codable, Hashable, Sendable {
    public let identity: SessionWorkIdentity
    public let commandID: String
    public let sequence: Int
    public let actorID: String
    public let command: SessionCommand
    public let previousState: SessionCommandState
    public let state: SessionCommandState

    public init(
        identity: SessionWorkIdentity, commandID: String, sequence: Int, actorID: String,
        command: SessionCommand, previousState: SessionCommandState, state: SessionCommandState,
        causalCursor: JournalCursor? = nil
    ) {
        self.identity = identity
        self.commandID = commandID
        self.sequence = sequence
        self.actorID = actorID
        self.command = command
        self.previousState = previousState
        self.state = state
        self.causalCursor = causalCursor
    }

    /// The Work cursor the caller observed before asking this controller to admit the command.
    /// It is optional for legacy/in-process callers, but when supplied it must survive unchanged
    /// into the native CommandRef rather than being replaced by whatever happens to be latest.
    public let causalCursor: JournalCursor?
}

/// The complete, already-admitted command record handed to a command journal.
///
/// This is deliberately a value rather than a native timeline event. The controller owns
/// admission order and identity; the journal owns how that record is made durable. A future
/// `RunJournalBundle` adapter can use the existing identity and causal information supplied by
/// its caller, but this seam never invents a Session, Work, attachment, client, or cursor.
public struct SessionCommandIntent: Codable, Hashable, Sendable {
    public let identity: SessionWorkIdentity
    public let commandID: String
    public let sequence: Int
    public let actorID: String
    public let command: SessionCommand
    public let previousState: SessionCommandState
    public let state: SessionCommandState
    public let causalCursor: JournalCursor?
    public let timestamp: Date

    public init(admitted: AdmittedSessionCommand, timestamp: Date = Date()) {
        self.identity = admitted.identity
        self.commandID = admitted.commandID
        self.sequence = admitted.sequence
        self.actorID = admitted.actorID
        self.command = admitted.command
        self.previousState = admitted.previousState
        self.state = admitted.state
        self.causalCursor = admitted.causalCursor
        self.timestamp = timestamp
    }
}

/// Errors at the command-journal crossing retain whether Work accepted the command. In
/// particular, a native-first journal can have a durable command.accepted receipt even though
/// its compatibility projection could not be appended. That is not a normal rejection and must
/// not be retried as if no canonical input existed.
public enum SessionCommandJournalError: Error, LocalizedError, Equatable, Sendable {
    case acceptedButUndelivered(commandID: String, reason: String)
    case causalConflict(
        commandID: String, expected: JournalCursor?, received: JournalCursor?)

    public var errorDescription: String? {
        switch self {
        case .acceptedButUndelivered(_, let reason):
            return "Command was accepted by the native journal but not delivered: \(reason)"
        case .causalConflict(let commandID, let expected, let received):
            return "Command \(commandID) has a stale or conflicting causal cursor "
                + "(expected \(String(describing: expected)), received \(String(describing: received))."
        }
    }
}

/// The narrow durability seam between command admission and execution.
///
/// Implementations must not perform the command. They only make the supplied immutable intent
/// durable and throw when that crossing is unavailable. The legacy `SessionWriter` conforms below;
/// a native `RunJournalBundle` coordinator can be supplied later without changing the controller
/// or making the legacy transcript pretend to be a native timeline.
public protocol SessionCommandJournal: Sendable {
    func commitIntent(_ intent: SessionCommandIntent) async throws

    /// Record the runtime crossing for an intent that was already durably admitted.
    ///
    /// Legacy Session JSONL has no separate delivery record, so its default implementation is a
    /// no-op. A native journal adapter can use this crossing to call `markCommandDelivered` only
    /// after the engine has accepted the command.
    func markDelivered(_ intent: SessionCommandIntent, at timestamp: Date) async throws

    /// Give a native journal a chance to terminalize an accepted command whose compatibility
    /// projection failed. Timeline v2 does not yet expose this operation in every adapter, so the
    /// default is intentionally a no-op; callers still receive an explicit not-delivered receipt
    /// and the controller fails closed. Native bundle adapters should override this once the
    /// command terminal-outcome event is available.
    func markUndelivered(
        _ intent: SessionCommandIntent, reason: String, at timestamp: Date
    ) async throws
}

public extension SessionCommandJournal {
    func markDelivered(_ intent: SessionCommandIntent, at timestamp: Date) async throws {
        // The legacy bridge records command intent only. Keeping delivery optional preserves its
        // existing bytes while allowing a native adapter to retain a second durable receipt.
    }

    func markUndelivered(
        _ intent: SessionCommandIntent, reason: String, at timestamp: Date
    ) async throws {
        // See the protocol documentation. This compatibility default preserves the canonical
        // accepted receipt while making the missing terminal event an explicit migration gap.
    }
}

/// The existing single-file transcript remains the default journal for live sessions.
extension SessionWriter: SessionCommandJournal {
    public func commitIntent(_ intent: SessionCommandIntent) async throws {
        _ = try await appendCommandIntent(
            commandID: intent.commandID, command: intent.command,
            identity: intent.identity, actorID: intent.actorID,
            controllerSequence: intent.sequence, previousState: intent.previousState,
            state: intent.state, timestamp: intent.timestamp)
    }
}

public enum SessionCommandRejection: Error, Codable, Hashable, Sendable, Equatable {
    case emptyInput
    case invalidState(command: String, state: SessionCommandState)
    case unsupportedCommand(command: String)
    case unsupportedCancellation(scope: SessionCancellationScope)
    case invalidActor
    case journalUnavailable
    /// Native Work refused the supplied caller cursor. No command acceptance was written.
    case causalConflict(expected: JournalCursor?, received: JournalCursor?)

    fileprivate var label: String {
        switch self {
        case .emptyInput: return "empty_input"
        case .invalidState: return "invalid_state"
        case .unsupportedCommand: return "unsupported_command"
        case .unsupportedCancellation: return "unsupported_cancellation"
        case .invalidActor: return "invalid_actor"
        case .journalUnavailable: return "journal_unavailable"
        case .causalConflict: return "causal_conflict"
        }
    }
}

public enum SessionCommandAdmission: Codable, Hashable, Sendable {
    case accepted(AdmittedSessionCommand)
    case rejected(commandID: String, reason: SessionCommandRejection)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// What happened after immutable command admission.
///
/// Admission answers whether the serialized Work controller accepted the command. Delivery is
/// a separate crossing: an accepted command can be queued, fail before crossing, or have an
/// indeterminate external effect. Keeping both prevents one command id from acquiring two
/// contradictory admission receipts.
public enum SessionCommandDelivery: Codable, Hashable, Sendable {
    case notAttempted
    case queued
    case delivered(referenceID: String?)
    case notDelivered(reason: String)
    case indeterminate(reason: String)

    public var isDelivered: Bool {
        if case .delivered = self { return true }
        return false
    }

    public var isQueued: Bool {
        if case .queued = self { return true }
        return false
    }

    /// The GUI may clear an input only after Work owns it, not merely after admission.
    public var wasHandedOff: Bool { isDelivered || isQueued }

    public var detail: String? {
        switch self {
        case .notDelivered(let reason), .indeterminate(let reason): return reason
        case .notAttempted, .queued, .delivered: return nil
        }
    }
}

public struct SessionCommandReceipt: Codable, Hashable, Sendable {
    public let admission: SessionCommandAdmission
    public let delivery: SessionCommandDelivery

    public init(
        admission: SessionCommandAdmission,
        delivery: SessionCommandDelivery = .notAttempted
    ) {
        self.admission = admission
        self.delivery = delivery
    }

    public var wasAdmitted: Bool { admission.isAccepted }
    public var isDelivered: Bool { delivery.isDelivered }
    public var isQueued: Bool { delivery.isQueued }
    public var wasHandedOff: Bool { delivery.wasHandedOff }

    /// Native Work accepted this command, but the compatibility projection or another required
    /// post-acceptance write failed before the runtime crossing. This is deliberately distinct
    /// from `admission` rejection so retry code cannot submit the canonical input twice.
    public var isAcceptedButUndelivered: Bool {
        guard admission.isAccepted else { return false }
        switch delivery {
        case .notDelivered, .indeterminate: return true
        case .notAttempted, .queued, .delivered: return false
        }
    }
}

/// The single serialized admission point for a session's commands.
///
/// This actor does not execute a command. The caller admits it, persists/dispatches the returned
/// record, and then calls an acknowledgement method when the driver has actually crossed the
/// corresponding boundary. Keeping admission separate from execution prevents the controller
/// from claiming that a provider or arbitrary Python action was canceled merely because a GUI
/// button was pressed.
public actor SessionCommandController {
    public let identity: SessionWorkIdentity
    /// Immutable and Sendable so attachment adapters can render capabilities without an actor
    /// hop; it is also what injected drivers must mirror rather than re-declaring locally.
    public nonisolated let capabilities: SessionCommandCapabilities

    private var currentState: SessionCommandState = .prepared
    private var nextSequence = 1
    private var admissionsByID: [String: SessionCommandAdmission] = [:]
    private var stateHistory: [SessionCommandState] = [.prepared]
    private var activeCommandID: String?
    private var nextDispatchSequence = 1
    private var dispatchOwners: Set<String> = []
    private var completedDispatches: Set<String> = []
    private var skippedDispatchSequences: Set<Int> = []
    private struct DispatchWaiter {
        let command: AdmittedSessionCommand
        let continuation: CheckedContinuation<AdmittedSessionCommand?, Never>
    }
    private var dispatchWaiters: [Int: DispatchWaiter] = [:]
    private var commandJournal: (any SessionCommandJournal)?
    private var pendingCommitIDs: Set<String> = []
    private var committedIntentIDs: Set<String> = []
    private var commitWaiters: [String: [CheckedContinuation<SessionCommandReceipt, Never>]] = [:]
    private var receiptsByID: [String: SessionCommandReceipt] = [:]
    private var undeliveredReasons: [String: String] = [:]
    private var pendingDeliveryIDs: Set<String> = []
    private enum DeliveryOutcome: Equatable {
        case delivered
        case notDelivered
        case indeterminate
    }
    private struct DeliveryWaiter {
        let expected: DeliveryOutcome
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var deliveryOutcomeByID: [String: DeliveryOutcome] = [:]
    private var deliveryWaiters: [String: [DeliveryWaiter]] = [:]
    private var journalUnavailableReason: String?
    private var degradedEndDispatchIDs: Set<String> = []

    public init(
        identity: SessionWorkIdentity,
        capabilities: SessionCommandCapabilities = .init(),
        writer: SessionWriter? = nil,
        journal: (any SessionCommandJournal)? = nil
    ) {
        self.identity = identity
        self.capabilities = capabilities
        // `writer` is the source-compatible legacy bridge. An explicitly supplied journal wins
        // so a caller can migrate one controller at a time without changing GUI construction.
        self.commandJournal = journal ?? writer
    }

    public var state: SessionCommandState { currentState }
    public var admittedCount: Int { nextSequence - 1 }
    public var states: [SessionCommandState] { stateHistory }
    public var isJournalUnavailable: Bool { journalUnavailableReason != nil }
    public var journalFailure: String? { journalUnavailableReason }

    /// Return the durable crossing status for an admitted command. Legacy callers can continue
    /// using `admitAndCommit`; migrated callers should inspect this receipt before retrying.
    public func receipt(for commandID: String) -> SessionCommandReceipt? {
        if let receipt = receiptsByID[commandID] { return receipt }
        guard let admission = admissionsByID[commandID] else { return nil }
        return SessionCommandReceipt(admission: admission)
    }

    /// Stable namespace for a CLI Start command. A run is a fresh execution attempt even when
    /// it cold-resumes the same Session/Work, so deriving this id from runID prevents the old
    /// cli-start id from colliding with the native command ledger on resume.
    public static func cliStartCommandID(for identity: SessionWorkIdentity) -> String {
        "cli-start-\(identity.runID)"
    }

    /// Replace the launch-boundary journal before the first command is admitted.
    ///
    /// The GUI has to create its legacy presentation writer synchronously so it can publish a
    /// `LiveRun`, while opening the native Session/Work pair is asynchronous. This deliberately
    /// narrow seam lets the driver install the native-authority bridge after opening that pair,
    /// but before Start can enter the command order. Once admission has begun the journal is an
    /// immutable part of the controller's history and replacement is refused.
    public func installJournalBeforeAdmission(
        _ journal: any SessionCommandJournal
    ) -> Bool {
        guard currentState == .prepared,
              nextSequence == 1,
              admissionsByID.isEmpty,
              pendingCommitIDs.isEmpty,
              committedIntentIDs.isEmpty,
              dispatchOwners.isEmpty,
              completedDispatches.isEmpty,
              dispatchWaiters.isEmpty,
              journalUnavailableReason == nil
        else { return false }
        commandJournal = journal
        return true
    }

    /// Admit one command in actor order. An explicit command id is useful for a retried remote
    /// request; when absent, the controller allocates it before dispatch.
    public func admit(
        _ command: SessionCommand,
        actorID: String,
        commandID: String? = nil,
        causalCursor: JournalCursor? = nil
    ) -> SessionCommandAdmission {
        let id = commandID ?? Self.newCommandID()
        if let prior = admissionsByID[id] { return prior }
        if journalUnavailableReason != nil, !isEnd(command) {
            return reject(id: id, reason: .journalUnavailable)
        }
        guard !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reject(id: id, reason: .invalidActor)
        }
        if let text = command.textValue,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return reject(id: id, reason: .emptyInput)
        }
        if case .cancel(let scope) = command, !capabilities.supports(scope) {
            return reject(id: id, reason: .unsupportedCancellation(scope: scope))
        }
        if case .steer = command, !capabilities.supportsSteering {
            return reject(id: id, reason: .unsupportedCommand(command: command.label))
        }
        if case .queueFollowUp = command, !capabilities.supportsQueuedFollowUps {
            return reject(id: id, reason: .unsupportedCommand(command: command.label))
        }
        // A journal commit can be suspended indefinitely (for example, a dead remote writer).
        // End is a local teardown intent, so it must still be admitted immediately and must not
        // join that writer's queue. Its degraded permit is deliberately not a durable intent.
        let degradedEnd = isEnd(command)
            && !pendingCommitIDs.isEmpty
        guard let nextState = degradedEnd ? .ending : nextState(for: command) else {
            return reject(
                id: id, reason: .invalidState(command: command.label, state: currentState))
        }

        let admitted = AdmittedSessionCommand(
            identity: identity, commandID: id, sequence: nextSequence, actorID: actorID,
            command: command, previousState: currentState, state: nextState,
            causalCursor: causalCursor)
        nextSequence += 1
        currentState = nextState
        stateHistory.append(nextState)
        if case .start = command {
            activeCommandID = id
        } else if case .send = command {
            activeCommandID = id
        } else if case .cancel = command {
            activeCommandID = id
        } else if case .endRun = command {
            activeCommandID = id
        }
        let result = SessionCommandAdmission.accepted(admitted)
        admissionsByID[id] = result
        if degradedEnd {
            committedIntentIDs.insert(id)
            degradedEndDispatchIDs.insert(id)
            refuseStaleDispatchWaiters()
        }
        // Legacy callers without a journal are already at the only available persistence
        // boundary; the journal-backed path uses `admitAndCommit` and leaves this uncommitted.
        if commandJournal == nil {
            committedIntentIDs.insert(id)
            receiptsByID[id] = SessionCommandReceipt(admission: result, delivery: .queued)
        }
        return result
    }

    /// Admit and durably record a command intent before exposing its dispatch permit. A writer
    /// failure is terminal for the journal: the accepted admission is replaced by a typed
    /// rejection, later non-End commands fail fast, and any queued dispatch waiters are resumed
    /// as undeliverable. End alone can still obtain a degraded teardown permit.
    public func admitAndCommit(
        _ command: SessionCommand,
        actorID: String,
        commandID: String? = nil,
        timestamp: Date = Date(),
        causalCursor: JournalCursor? = nil
    ) async -> SessionCommandAdmission {
        await admitAndCommitReceipt(
            command, actorID: actorID, commandID: commandID,
            timestamp: timestamp, causalCursor: causalCursor).admission
    }

    /// Admit and return both canonical admission and the post-admission delivery status. The
    /// original `admitAndCommit` API remains as a compatibility projection of this result.
    public func admitAndCommitReceipt(
        _ command: SessionCommand,
        actorID: String,
        commandID: String? = nil,
        timestamp: Date = Date(),
        causalCursor: JournalCursor? = nil
    ) async -> SessionCommandReceipt {
        if let commandID, pendingCommitIDs.contains(commandID) {
            return await withCheckedContinuation { continuation in
                commitWaiters[commandID, default: []].append(continuation)
            }
        }
        if let commandID, committedIntentIDs.contains(commandID),
           let existing = admissionsByID[commandID] {
            return receiptsByID[commandID] ?? SessionCommandReceipt(
                admission: existing, delivery: .queued)
        }
        let admission = admit(
            command, actorID: actorID, commandID: commandID, causalCursor: causalCursor)
        guard case .accepted(let admitted) = admission else {
            return SessionCommandReceipt(admission: admission)
        }
        guard let commandJournal else {
            committedIntentIDs.insert(admitted.commandID)
            let receipt = SessionCommandReceipt(admission: admission, delivery: .queued)
            receiptsByID[admitted.commandID] = receipt
            return receipt
        }
        if degradedEndDispatchIDs.contains(admitted.commandID) {
            // The End admission above is intentionally independent of the held writer call.
            let receipt = SessionCommandReceipt(admission: admission)
            receiptsByID[admitted.commandID] = receipt
            return receipt
        }
        if journalUnavailableReason != nil {
            // The command was admitted only because it is End; it is intentionally not written
            // through the wedged journal, and its teardown path is allowed to bypass old owners.
            guard isEnd(command) else {
                return SessionCommandReceipt(
                    admission: reject(id: admitted.commandID, reason: .journalUnavailable))
            }
            committedIntentIDs.insert(admitted.commandID)
            degradedEndDispatchIDs.insert(admitted.commandID)
            let receipt = SessionCommandReceipt(admission: admission)
            receiptsByID[admitted.commandID] = receipt
            return receipt
        }

        pendingCommitIDs.insert(admitted.commandID)
        transition(to: .committing)
        do {
            try await commandJournal.commitIntent(
                SessionCommandIntent(admitted: admitted, timestamp: timestamp))
            pendingCommitIDs.remove(admitted.commandID)
            committedIntentIDs.insert(admitted.commandID)
            let receipt = SessionCommandReceipt(admission: admission, delivery: .queued)
            receiptsByID[admitted.commandID] = receipt
            // End may have taken the degraded teardown path while this write was suspended.
            // The old commit is still recorded as committed, but it cannot resurrect a run or
            // steal ownership from End after teardown has started (or completed).
            if currentState == .committing {
                transition(to: admitted.state)
            }
            resumeCommitWaiters(for: admitted.commandID, with: receipt)
            return receipt
        } catch {
            pendingCommitIDs.remove(admitted.commandID)

            if let journalError = error as? SessionCommandJournalError,
               case .acceptedButUndelivered(let commandID, let reason) = journalError,
               commandID == admitted.commandID {
                // The native acceptance is canonical. Keep the admission accepted, make retries
                // idempotent by marking its command id committed, and refuse every later effect.
                committedIntentIDs.insert(admitted.commandID)
                if isEnd(admitted.command) {
                    // End must retain a local teardown permit. Native Work has accepted it and
                    // can still record actual delivery; only the legacy presentation failed.
                    // Do not terminalize it as not-delivered before cleanup crosses that boundary.
                    degradedEndDispatchIDs.insert(admitted.commandID)
                    latchJournalFailure(error)
                    transition(to: .ending)
                    let receipt = SessionCommandReceipt(
                        admission: admission, delivery: .queued)
                    receiptsByID[admitted.commandID] = receipt
                    resumeCommitWaiters(for: admitted.commandID, with: receipt)
                    return receipt
                }
                let intent = SessionCommandIntent(admitted: admitted, timestamp: timestamp)
                let receipt: SessionCommandReceipt
                do {
                    // Do not expose a not-delivered result until its native terminal receipt is
                    // durable. If this write is unavailable, the accepted command remains
                    // indeterminate and must not be cached as safely absent.
                    try await commandJournal.markUndelivered(
                        intent, reason: reason, at: timestamp)
                    undeliveredReasons[admitted.commandID] = reason
                    deliveryOutcomeByID[admitted.commandID] = .notDelivered
                    receipt = SessionCommandReceipt(
                        admission: admission, delivery: .notDelivered(reason: reason))
                } catch {
                    deliveryOutcomeByID[admitted.commandID] = .indeterminate
                    latchJournalFailure(error)
                    receipt = SessionCommandReceipt(
                        admission: admission,
                        delivery: .indeterminate(reason: error.localizedDescription))
                }
                latchJournalFailure(error)
                if currentState != .ending, currentState != .ended {
                    activeCommandID = nil
                    transition(to: .failed)
                }
                receiptsByID[admitted.commandID] = receipt
                resumeCommitWaiters(for: admitted.commandID, with: receipt)
                return receipt
            }

            if let journalError = error as? SessionCommandJournalError,
               case .causalConflict(_, let expected, let received) = journalError {
                let result = SessionCommandAdmission.rejected(
                    commandID: admitted.commandID,
                    reason: .causalConflict(expected: expected, received: received))
                admissionsByID[admitted.commandID] = result
                // No native acceptance exists. Restore the lifecycle owner when no later command
                // superseded it; the consumed local sequence is retained for audit monotonicity.
                if activeCommandID == admitted.commandID {
                    activeCommandID = nil
                }
                // Steer and queued follow-up commands do not own activeCommandID. If their
                // causal check loses a race while their intent is committing, restore the
                // lifecycle that existed before admission. A lifecycle acknowledgement, End,
                // or another later state may already have superseded `.committing`; in those
                // cases leave the newer state untouched.
                if currentState == .committing {
                    transition(to: admitted.previousState)
                }
                // The controller allocated a local sequence before the native cursor check. It
                // is still consumed for audit monotonicity, but no dispatch owner will ever
                // acknowledge it; advance the dispatch cursor so a later command cannot wait
                // forever behind this explicit refusal.
                skipDispatchSequence(admitted.sequence)
                let receipt = SessionCommandReceipt(admission: result)
                receiptsByID[admitted.commandID] = receipt
                resumeCommitWaiters(for: admitted.commandID, with: receipt)
                return receipt
            }

            latchJournalFailure(error)
            if isEnd(admitted.command) {
                // End's admission is immutable even when its own durable intent is ambiguous.
                // Teardown must remain possible, and the local degraded permit is preferable to
                // claiming that an accepted End became a rejected command.
                committedIntentIDs.insert(admitted.commandID)
                degradedEndDispatchIDs.insert(admitted.commandID)
                refuseStaleDispatchWaiters()
                if currentState == .committing {
                    transition(to: .ending)
                }
                let receipt = SessionCommandReceipt(admission: admission)
                receiptsByID[admitted.commandID] = receipt
                resumeCommitWaiters(for: admitted.commandID, with: receipt)
                return receipt
            }
            admissionsByID[admitted.commandID] = .rejected(
                commandID: admitted.commandID, reason: .journalUnavailable)
            // The lifecycle may have been acknowledged while this intent was in flight, so do
            // not use `.committing` as the condition for failure. Journal failure is terminal
            // for non-End work in every non-teardown lifecycle state.
            if currentState != .ending, currentState != .ended {
                activeCommandID = nil
                transition(to: .failed)
            }
            let result = admissionsByID[admitted.commandID]!
            let receipt = SessionCommandReceipt(admission: result)
            receiptsByID[admitted.commandID] = receipt
            resumeCommitWaiters(for: admitted.commandID, with: receipt)
            return receipt
        }
    }

    /// Wait until this admitted command owns the Work's dispatch turn. Admission and execution
    /// are separate boundaries: concurrent GUI/peer/scheduler tasks may resume in any order, so
    /// drivers must cross this gate before touching the engine.
    public func awaitDispatch(commandID: String) async -> AdmittedSessionCommand? {
        guard case .accepted(let admitted)? = admissionsByID[commandID] else { return nil }
        guard !pendingCommitIDs.contains(commandID) else { return nil }
        guard committedIntentIDs.contains(commandID) else { return nil }
        guard journalUnavailableReason == nil || isEnd(admitted.command) else { return nil }
        guard undeliveredReasons[commandID] == nil else { return nil }
        // End permits are owner-specific. A newer degraded End may have already completed
        // teardown while an older writer call is still returning; that older End must never be
        // handed out after `.ended`, even though its admission remains immutable.
        if isEnd(admitted.command) {
            guard currentState == .ending, activeCommandID == commandID else { return nil }
        }
        // A command admitted before End may still be sitting behind the normal dispatch cursor.
        // Once teardown starts, handing it out would let stale work run after the user ended the
        // Work. A command that already crossed this method remains the driver's responsibility.
        guard (currentState != .ending && currentState != .ended) || isEnd(admitted.command)
        else { return nil }
        // Dispatch is a single-consumer receipt. A retry or duplicate waiter must never be
        // allowed to execute the same command, and must not replace the original continuation.
        guard !dispatchOwners.contains(commandID), !completedDispatches.contains(commandID)
        else { return nil }
        if isEnd(admitted.command), degradedEndDispatchIDs.contains(commandID) {
            dispatchOwners.insert(commandID)
            return admitted
        }
        if admitted.sequence < nextDispatchSequence { return nil }
        dispatchOwners.insert(commandID)
        if admitted.sequence > nextDispatchSequence {
            return await withCheckedContinuation { continuation in
                dispatchWaiters[admitted.sequence] = DispatchWaiter(
                    command: admitted, continuation: continuation)
            }
        }
        return admitted
    }

    /// Release the next accepted command only after this command has actually been handed to
    /// the engine (or its terminal refusal/teardown has been observed).
    public func acknowledgeDispatched(commandID: String) -> Bool {
        guard case .accepted(let admitted)? = admissionsByID[commandID],
              dispatchOwners.contains(commandID),
              degradedEndDispatchIDs.contains(commandID) || admitted.sequence == nextDispatchSequence
        else { return false }
        dispatchOwners.remove(commandID)
        completedDispatches.insert(commandID)
        if degradedEndDispatchIDs.remove(commandID) != nil { return true }
        nextDispatchSequence += 1
        while skippedDispatchSequences.remove(nextDispatchSequence) != nil {
            nextDispatchSequence += 1
        }
        if let waiter = dispatchWaiters.removeValue(forKey: nextDispatchSequence) {
            dispatchOwners.insert(waiter.command.commandID)
            waiter.continuation.resume(returning: waiter.command)
        }
        return true
    }

    /// Record that a previously admitted command crossed the runtime delivery boundary.
    ///
    /// Delivery can happen after `acknowledgeDispatched` — notably for Start, whose dispatch
    /// permit covers setup while the actual input is handed to the agent later. The operation is
    /// idempotent by command id and coalesces concurrent retries, so a native journal never gets
    /// two delivery receipts for one admitted command.
    public func recordDelivered(
        commandID: String, timestamp: Date = Date()
    ) async -> Bool {
        guard case .accepted(let admitted)? = admissionsByID[commandID],
              committedIntentIDs.contains(commandID)
        else { return false }
        if let outcome = deliveryOutcomeByID[commandID] {
            return outcome == .delivered
        }
        if pendingDeliveryIDs.contains(commandID) {
            return await withCheckedContinuation { continuation in
                deliveryWaiters[commandID, default: []].append(
                    DeliveryWaiter(expected: .delivered, continuation: continuation))
            }
        }

        pendingDeliveryIDs.insert(commandID)
        do {
            if let commandJournal {
                try await commandJournal.markDelivered(
                    SessionCommandIntent(admitted: admitted, timestamp: timestamp), at: timestamp)
            }
            pendingDeliveryIDs.remove(commandID)
            deliveryOutcomeByID[commandID] = .delivered
            if let receipt = receiptsByID[commandID] {
                receiptsByID[commandID] = SessionCommandReceipt(
                    admission: receipt.admission, delivery: .delivered(referenceID: nil))
            }
            resumeDeliveryWaiters(for: commandID, with: .delivered)
            return true
        } catch {
            pendingDeliveryIDs.remove(commandID)
            deliveryOutcomeByID[commandID] = .indeterminate
            latchJournalFailure(error)
            // The runtime crossing has already happened; later commands must fail closed, but
            // the local lifecycle should not strand the caller in a state that prevents teardown.
            if currentState != .ending, currentState != .ended {
                activeCommandID = nil
                transition(to: .failed)
            }
            if let receipt = receiptsByID[commandID] {
                receiptsByID[commandID] = SessionCommandReceipt(
                    admission: receipt.admission,
                    delivery: .indeterminate(reason: error.localizedDescription))
            }
            resumeDeliveryWaiters(for: commandID, with: .indeterminate)
            return false
        }
    }

    /// Record a known terminal refusal after canonical admission but before runtime delivery.
    /// This keeps `accepted` immutable while ensuring the Work ledger has no orphaned queued
    /// command that a later GUI could mistake for work still awaiting delivery.
    public func recordNotDelivered(
        commandID: String, reason: String, timestamp: Date = Date()
    ) async -> Bool {
        guard case .accepted(let admitted)? = admissionsByID[commandID],
              committedIntentIDs.contains(commandID)
        else { return false }
        let boundedReason = String(reason.prefix(4_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !boundedReason.isEmpty else { return false }
        if let outcome = deliveryOutcomeByID[commandID] {
            return outcome == .notDelivered
        }
        if pendingDeliveryIDs.contains(commandID) {
            return await withCheckedContinuation { continuation in
                deliveryWaiters[commandID, default: []].append(
                    DeliveryWaiter(expected: .notDelivered, continuation: continuation))
            }
        }

        pendingDeliveryIDs.insert(commandID)
        do {
            if let commandJournal {
                try await commandJournal.markUndelivered(
                    SessionCommandIntent(admitted: admitted, timestamp: timestamp),
                    reason: boundedReason, at: timestamp)
            }
            pendingDeliveryIDs.remove(commandID)
            deliveryOutcomeByID[commandID] = .notDelivered
            undeliveredReasons[commandID] = boundedReason
            let admission = admissionsByID[commandID]!
            receiptsByID[commandID] = SessionCommandReceipt(
                admission: admission, delivery: .notDelivered(reason: boundedReason))
            resumeDeliveryWaiters(for: commandID, with: .notDelivered)
            return true
        } catch {
            pendingDeliveryIDs.remove(commandID)
            deliveryOutcomeByID[commandID] = .indeterminate
            latchJournalFailure(error)
            if currentState != .ending, currentState != .ended {
                activeCommandID = nil
                transition(to: .failed)
            }
            if let admission = admissionsByID[commandID] {
                receiptsByID[commandID] = SessionCommandReceipt(
                    admission: admission,
                    delivery: .indeterminate(reason: error.localizedDescription))
            }
            resumeDeliveryWaiters(for: commandID, with: .indeterminate)
            return false
        }
    }

    /// A journal-aware dispatch acknowledgement for native or other split-timeline callers.
    ///
    /// This is intentionally additive: existing GUI/legacy callers can continue using
    /// `acknowledgeDispatched`, whose behavior and synchronous shape are unchanged. Callers that
    /// supplied a journal with a separate delivery record may use this method when dispatch and
    /// delivery happen at one boundary. For a split boundary, call `acknowledgeDispatched` first
    /// and `recordDelivered` when the engine accepts the command. The durable delivery write
    /// happens before the local dispatch cursor advances. If that write is ambiguous, the journal
    /// is latched unavailable and the command's dispatch owner is released because the external
    /// boundary has already been crossed.
    public func acknowledgeDelivered(
        commandID: String, timestamp: Date = Date()
    ) async -> Bool {
        guard case .accepted(let admitted)? = admissionsByID[commandID],
              dispatchOwners.contains(commandID)
        else { return false }
        guard await recordDelivered(commandID: admitted.commandID, timestamp: timestamp) else {
            // `recordDelivered` latches any journal failure. Delivery is the boundary after which
            // the driver cannot safely be retried, so release this local owner even on ambiguity.
            _ = acknowledgeDispatched(commandID: commandID)
            return false
        }
        return acknowledgeDispatched(commandID: commandID)
    }

    /// Acknowledge that setup for the admitted start command completed and the turn can run.
    public func acknowledgePreparation(commandID: String) -> Bool {
        guard (currentState == .preparing || currentState == .committing),
              activeCommandID == commandID
        else { return false }
        transition(to: .running)
        return true
    }

    /// A driver acknowledgement that the admitted start or send crossed its turn boundary.
    public func acknowledgeTurnFinished(commandID: String) -> Bool {
        guard (currentState == .running || currentState == .committing),
              activeCommandID == commandID
        else { return false }
        activeCommandID = nil
        transition(to: .idle)
        return true
    }

    /// A driver acknowledgement for a declared cancellation scope. `terminal` is supplied by
    /// the driver because the controller cannot infer whether the underlying action ended.
    public func acknowledgeCancellation(commandID: String, terminal: Bool = false) -> Bool {
        guard (currentState == .canceling || currentState == .committing),
              activeCommandID == commandID
        else { return false }
        activeCommandID = nil
        transition(to: terminal ? .ended : .idle)
        return true
    }

    /// Record a failure for the exact command that currently owns the lifecycle. A late result
    /// from an older turn cannot overwrite a newer send or an ending teardown.
    public func markFailed(commandID: String) -> Bool {
        guard currentState != .ended, currentState != .ending,
              activeCommandID == commandID
        else { return false }
        activeCommandID = nil
        transition(to: .failed)
        return true
    }

    /// Explicit host/global failure path for setup failures that have no active command owner.
    /// It intentionally cannot overwrite ending/ended state.
    public func markFailed() -> Bool {
        guard currentState != .ended, currentState != .ending else { return false }
        activeCommandID = nil
        transition(to: .failed)
        return true
    }

    /// A driver acknowledgement that an admitted end command completed teardown.
    public func acknowledgeEnd(commandID: String) -> Bool {
        guard (currentState == .ending || currentState == .committing),
              activeCommandID == commandID
        else { return false }
        activeCommandID = nil
        transition(to: .ended)
        return true
    }

    private func nextState(for command: SessionCommand) -> SessionCommandState? {
        switch command {
        case .start:
            return currentState == .prepared ? .preparing : nil
        case .send:
            return currentState == .idle ? .running : nil
        case .steer:
            guard currentState == .running else { return nil }
            return currentState
        case .queueFollowUp:
            // With no active turn there is nothing to queue behind; callers should send.
            // Accepting this while idle would strand a message in Agent.pendingFollowUps.
            guard currentState == .running else { return nil }
            return currentState
        case .cancel:
            return currentState == .running ? .canceling : nil
        case .endRun:
            return currentState == .ended || currentState == .ending ? nil : .ending
        }
    }

    private func transition(to state: SessionCommandState) {
        currentState = state
        stateHistory.append(state)
    }

    private func isEnd(_ command: SessionCommand) -> Bool {
        if case .endRun = command { return true }
        return false
    }

    private func latchJournalFailure(_ error: Error) {
        if journalUnavailableReason == nil {
            journalUnavailableReason = error.localizedDescription
        }
        for waiter in dispatchWaiters.values {
            waiter.continuation.resume(returning: nil)
        }
        dispatchWaiters.removeAll()
    }

    private func refuseStaleDispatchWaiters() {
        for waiter in dispatchWaiters.values {
            waiter.continuation.resume(returning: nil)
        }
        dispatchWaiters.removeAll()
    }

    private func skipDispatchSequence(_ sequence: Int) {
        guard sequence >= nextDispatchSequence else { return }
        skippedDispatchSequences.insert(sequence)
        while skippedDispatchSequences.remove(nextDispatchSequence) != nil {
            nextDispatchSequence += 1
            if let waiter = dispatchWaiters.removeValue(forKey: nextDispatchSequence) {
                dispatchOwners.insert(waiter.command.commandID)
                waiter.continuation.resume(returning: waiter.command)
            }
        }
    }

    private func resumeCommitWaiters(
        for commandID: String, with result: SessionCommandReceipt
    ) {
        for waiter in commitWaiters.removeValue(forKey: commandID) ?? [] {
            waiter.resume(returning: result)
        }
    }

    private func resumeDeliveryWaiters(
        for commandID: String, with outcome: DeliveryOutcome
    ) {
        for waiter in deliveryWaiters.removeValue(forKey: commandID) ?? [] {
            waiter.continuation.resume(returning: waiter.expected == outcome)
        }
    }

    private func reject(
        id: String, reason: SessionCommandRejection
    ) -> SessionCommandAdmission {
        let result = SessionCommandAdmission.rejected(commandID: id, reason: reason)
        admissionsByID[id] = result
        return result
    }

    private static func newCommandID() -> String {
        "command-\(UUID().uuidString.lowercased())"
    }
}
