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
        command: SessionCommand, previousState: SessionCommandState, state: SessionCommandState
    ) {
        self.identity = identity
        self.commandID = commandID
        self.sequence = sequence
        self.actorID = actorID
        self.command = command
        self.previousState = previousState
        self.state = state
    }
}

public enum SessionCommandRejection: Error, Codable, Hashable, Sendable, Equatable {
    case emptyInput
    case invalidState(command: String, state: SessionCommandState)
    case unsupportedCommand(command: String)
    case unsupportedCancellation(scope: SessionCancellationScope)
    case invalidActor
    case journalUnavailable

    fileprivate var label: String {
        switch self {
        case .emptyInput: return "empty_input"
        case .invalidState: return "invalid_state"
        case .unsupportedCommand: return "unsupported_command"
        case .unsupportedCancellation: return "unsupported_cancellation"
        case .invalidActor: return "invalid_actor"
        case .journalUnavailable: return "journal_unavailable"
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
    private struct DispatchWaiter {
        let command: AdmittedSessionCommand
        let continuation: CheckedContinuation<AdmittedSessionCommand?, Never>
    }
    private var dispatchWaiters: [Int: DispatchWaiter] = [:]
    private let writer: SessionWriter?
    private var pendingCommitIDs: Set<String> = []
    private var committedIntentIDs: Set<String> = []
    private var commitWaiters: [String: [CheckedContinuation<SessionCommandAdmission, Never>]] = [:]
    private var journalUnavailableReason: String?
    private var degradedEndDispatchIDs: Set<String> = []

    public init(
        identity: SessionWorkIdentity,
        capabilities: SessionCommandCapabilities = .init(),
        writer: SessionWriter? = nil
    ) {
        self.identity = identity
        self.capabilities = capabilities
        self.writer = writer
    }

    public var state: SessionCommandState { currentState }
    public var admittedCount: Int { nextSequence - 1 }
    public var states: [SessionCommandState] { stateHistory }
    public var isJournalUnavailable: Bool { journalUnavailableReason != nil }
    public var journalFailure: String? { journalUnavailableReason }

    /// Admit one command in actor order. An explicit command id is useful for a retried remote
    /// request; when absent, the controller allocates it before dispatch.
    public func admit(
        _ command: SessionCommand,
        actorID: String,
        commandID: String? = nil
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
            command: command, previousState: currentState, state: nextState)
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
        // Legacy callers without a writer are already at the only available persistence
        // boundary; the writer-backed path uses `admitAndCommit` and leaves this uncommitted.
        if writer == nil { committedIntentIDs.insert(id) }
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
        timestamp: Date = Date()
    ) async -> SessionCommandAdmission {
        if let commandID, pendingCommitIDs.contains(commandID) {
            return await withCheckedContinuation { continuation in
                commitWaiters[commandID, default: []].append(continuation)
            }
        }
        if let commandID, committedIntentIDs.contains(commandID),
           let existing = admissionsByID[commandID] {
            return existing
        }
        let admission = admit(command, actorID: actorID, commandID: commandID)
        guard case .accepted(let admitted) = admission else { return admission }
        guard let writer else {
            committedIntentIDs.insert(admitted.commandID)
            return admission
        }
        if degradedEndDispatchIDs.contains(admitted.commandID) {
            // The End admission above is intentionally independent of the held writer call.
            return admission
        }
        if journalUnavailableReason != nil {
            // The command was admitted only because it is End; it is intentionally not written
            // through the wedged journal, and its teardown path is allowed to bypass old owners.
            guard isEnd(command) else { return reject(id: admitted.commandID, reason: .journalUnavailable) }
            committedIntentIDs.insert(admitted.commandID)
            degradedEndDispatchIDs.insert(admitted.commandID)
            return admission
        }

        pendingCommitIDs.insert(admitted.commandID)
        transition(to: .committing)
        do {
            _ = try await writer.appendCommandIntent(
                commandID: admitted.commandID, command: admitted.command,
                identity: admitted.identity, actorID: admitted.actorID,
                controllerSequence: admitted.sequence, previousState: admitted.previousState,
                state: admitted.state,
                timestamp: timestamp)
            pendingCommitIDs.remove(admitted.commandID)
            committedIntentIDs.insert(admitted.commandID)
            // End may have taken the degraded teardown path while this write was suspended.
            // The old commit is still recorded as committed, but it cannot resurrect a run or
            // steal ownership from End after teardown has started (or completed).
            if currentState == .committing {
                transition(to: admitted.state)
            }
            resumeCommitWaiters(for: admitted.commandID, with: admission)
            return admission
        } catch {
            pendingCommitIDs.remove(admitted.commandID)
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
                resumeCommitWaiters(for: admitted.commandID, with: admission)
                return admission
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
            resumeCommitWaiters(for: admitted.commandID, with: result)
            return result
        }
    }

    /// Wait until this admitted command owns the Work's dispatch turn. Admission and execution
    /// are separate boundaries: concurrent GUI/peer/scheduler tasks may resume in any order, so
    /// drivers must cross this gate before touching the engine.
    public func awaitDispatch(commandID: String) async -> AdmittedSessionCommand? {
        guard case .accepted(let admitted)? = admissionsByID[commandID] else { return nil }
        guard !pendingCommitIDs.contains(commandID) else { return nil }
        guard committedIntentIDs.contains(commandID) else { return nil }
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
        if let waiter = dispatchWaiters.removeValue(forKey: nextDispatchSequence) {
            dispatchOwners.insert(waiter.command.commandID)
            waiter.continuation.resume(returning: waiter.command)
        }
        return true
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

    private func resumeCommitWaiters(
        for commandID: String, with result: SessionCommandAdmission
    ) {
        for waiter in commitWaiters.removeValue(forKey: commandID) ?? [] {
            waiter.resume(returning: result)
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
