import Foundation

// MARK: - Work transition state seam

/// The scalar portion of an incremental Work reduction.
///
/// This is intentionally a fixed-shape value rather than a generic projection framework.  The
/// identity sets/maps and their membership checks stay behind ``WorkTransitionStateAccess``;
/// this value only carries the small set of scalar facts that a future exact continuation needs
/// to resume.  Values are not shortened or otherwise normalized here: the in-memory adapter must
/// remain byte-for-byte equivalent to the public WorkReducer snapshot contract.
internal struct BoundedWorkScalarContinuation: Equatable, Sendable {
    var journal: JournalRef?
    var work: WorkRef?
    var workHost: WorkHostRef?
    var lifecycle: WorkLifecycle
    var execution: WorkExecution
    var activeRun: RunRef?
    var activeRunSession: SessionRef?
    var activeRunSessionAttachment: SessionAttachmentRef?
    var modelID: String?
    var activeTurn: TurnRef?
    var providerUsage: ProviderUsageAggregate
    var lastHostSequence: Int?
    var unknownDomains: Set<TimelineDomain>
    var lastEventID: String?
    var lastSequence: Int
    var causalOrderValid: Bool
    var structuralIntegrityValid: Bool
    var semanticProjectionValid: Bool

    init(snapshot: WorkSnapshot) {
        journal = snapshot.journal
        work = snapshot.work
        workHost = snapshot.workHost
        lifecycle = snapshot.lifecycle
        execution = snapshot.execution
        activeRun = snapshot.activeRun
        activeRunSession = snapshot.activeRunSession
        activeRunSessionAttachment = snapshot.activeRunSessionAttachment
        modelID = snapshot.modelID
        activeTurn = snapshot.activeTurn
        providerUsage = snapshot.providerUsage
        lastHostSequence = snapshot.lastHostSequence
        unknownDomains = snapshot.unknownDomains
        lastEventID = snapshot.lastEventID
        lastSequence = snapshot.lastSequence
        causalOrderValid = snapshot.causalOrderValid
        structuralIntegrityValid = snapshot.structuralIntegrityValid
        semanticProjectionValid = snapshot.semanticProjectionValid
    }

    func apply(to snapshot: inout WorkSnapshot) {
        snapshot.journal = journal
        snapshot.work = work
        snapshot.workHost = workHost
        snapshot.lifecycle = lifecycle
        snapshot.execution = execution
        snapshot.activeRun = activeRun
        snapshot.activeRunSession = activeRunSession
        snapshot.activeRunSessionAttachment = activeRunSessionAttachment
        snapshot.modelID = modelID
        snapshot.activeTurn = activeTurn
        snapshot.providerUsage = providerUsage
        snapshot.lastHostSequence = lastHostSequence
        snapshot.unknownDomains = unknownDomains
        snapshot.lastEventID = lastEventID
        snapshot.lastSequence = lastSequence
        snapshot.causalOrderValid = causalOrderValid
        snapshot.structuralIntegrityValid = structuralIntegrityValid
        snapshot.semanticProjectionValid = semanticProjectionValid
    }
}

/// Read-only, typed access to the identity/membership facts needed by one Work event.
///
/// This is a nonthrowing, event-local overlay contract—not a disk adapter. A persistent reducer
/// must first perform bounded throwing prefetch into an overlay, apply the transition there, then
/// durably commit or discard the complete mutation batch. The scalar continuation is deliberately
/// separate so a bounded HEAD can never be mistaken for an exact membership checkpoint.
internal protocol WorkTransitionStateAccess {
    var scalar: BoundedWorkScalarContinuation { get }
    var seenEventCount: Int { get }

    func hasSeenEvent(_ eventID: String) -> Bool
    func eventSequence(for eventID: String) -> Int?
    func hasObservedRun(_ runID: String) -> Bool
    func action(for actionID: String) -> WorkActionSnapshot?
    func isActionActive(_ actionID: String) -> Bool
    func handle(for handleID: String) -> WorkHandleSnapshot?
    func agentHandle(for handleID: String) -> WorkAgentHandleSnapshot?
    func sessionAttachment(for attachmentID: String) -> WorkSessionAttachmentSnapshot?
    func activeSessionAttachmentCount(for session: SessionRef) -> Int
    func command(for commandID: String) -> WorkCommandSnapshot?

    /// Checked cardinalities.  Adapters must never decrement either value below zero.
    var activeActionCount: Int { get }
    /// Legacy runtime Handles are Run-owned and continue to gate `run.finished`.
    var outstandingHandleCount: Int { get }
    /// Work-owned agent Handles have independent live, unreaped, and lifetime cardinalities.
    var liveAgentHandleCount: Int { get }
    var unreapedAgentHandleCount: Int { get }
    var retainedAgentHandleCount: Int { get }
}

/// Typed, event-local staged writes used by the shared Work transition function.
///
/// Each operation has one semantic purpose.  In particular, map membership and its derived
/// cardinality are updated together in the overlay. A persistent integration must publish the
/// entire resulting mutation batch atomically with its exact checkpoint; these methods perform no
/// fallible I/O and may never swallow a storage error.
internal protocol WorkTransitionStagedMutation {
    mutating func stageScalar(_ continuation: BoundedWorkScalarContinuation)
    mutating func stageSeenEvent(_ event: TimelineEvent)
    mutating func stageObservedRun(_ run: RunRef)
    mutating func stageSessionAttachment(_ attachment: WorkSessionAttachmentSnapshot)
    mutating func stageSessionAttachmentDetached(_ attachmentID: String)
    mutating func stageSessionAttachmentCapabilities(_ attachmentID: String, capabilities: Set<String>)
    /// `active == nil` preserves existing membership exactly. This matters when reducing from a
    /// caller-supplied inconsistent snapshot: extraction must not silently normalize old state.
    mutating func stageAction(_ action: WorkActionSnapshot, active: Bool?)
    mutating func stageHandle(_ handle: WorkHandleSnapshot)
    mutating func stageAgentHandle(_ handle: WorkAgentHandleSnapshot)
    mutating func stageCommand(_ command: WorkCommandSnapshot)
    mutating func stageRecovery(_ coverage: RecoveryCoverage, recorded: RecordedRecoveryCoverage)
    mutating func stageChildState(_ state: String, for childID: String)
    mutating func stageUnknown(_ unknown: UnknownTimelineEvent)
    mutating func stageQuarantineOnly(_ event: TimelineEvent)
    mutating func stageQuarantine(_ event: TimelineEvent, reason: String, structural: Bool)
}

internal protocol WorkTransitionState: WorkTransitionStateAccess, WorkTransitionStagedMutation {}

/// The in-memory conformance adapter used by ``WorkReducer`` and by differential tests.
///
/// This adapter intentionally keeps the complete ``WorkSnapshot`` collections.  It is a
/// conformance adapter, not the future disk-backed map.  Its counters are maintained alongside
/// each staged membership mutation and use checked guards on every decrement.
internal struct InMemoryWorkTransitionState: WorkTransitionState, Sendable {
    private var storedSnapshot: WorkSnapshot
    private var scalarContinuation: BoundedWorkScalarContinuation
    private var activeAttachmentCounts: [String: Int]
    private var activeActionCounter: Int
    private var outstandingHandleCounter: Int
    private var liveAgentHandleCounter: Int
    private var unreapedAgentHandleCounter: Int
    private var retainedAgentHandleCounter: Int

    init(snapshot: WorkSnapshot = WorkSnapshot()) {
        storedSnapshot = snapshot
        scalarContinuation = BoundedWorkScalarContinuation(snapshot: snapshot)

        var attachmentCounts: [String: Int] = [:]
        for attachment in snapshot.sessionAttachments.values where attachment.isAttached {
            attachmentCounts[attachment.session.sessionID, default: 0] += 1
        }
        activeAttachmentCounts = attachmentCounts
        activeActionCounter = snapshot.activeActionIDs.count
        outstandingHandleCounter = snapshot.handles.values.reduce(into: 0) { count, handle in
            if !Self.isTerminalHandleState(handle.state) { count += 1 }
        }
        liveAgentHandleCounter = snapshot.agentHandles.values.reduce(into: 0) { count, handle in
            if handle.blocksWorkCompletion { count += 1 }
        }
        unreapedAgentHandleCounter = snapshot.agentHandles.values.reduce(into: 0) { count, handle in
            if handle.state != .reaped { count += 1 }
        }
        retainedAgentHandleCounter = snapshot.agentHandles.count
    }

    var snapshot: WorkSnapshot {
        var result = storedSnapshot
        scalarContinuation.apply(to: &result)
        return result
    }

    var scalar: BoundedWorkScalarContinuation { scalarContinuation }
    var seenEventCount: Int { storedSnapshot.seenEventIDs.count }

    func hasSeenEvent(_ eventID: String) -> Bool {
        storedSnapshot.seenEventIDs.contains(eventID)
    }

    func eventSequence(for eventID: String) -> Int? {
        storedSnapshot.eventSequences[eventID]
    }

    func hasObservedRun(_ runID: String) -> Bool {
        storedSnapshot.observedRunIDs.contains(runID)
    }

    func action(for actionID: String) -> WorkActionSnapshot? {
        storedSnapshot.actions[actionID]
    }

    func isActionActive(_ actionID: String) -> Bool {
        storedSnapshot.activeActionIDs.contains(actionID)
    }

    func handle(for handleID: String) -> WorkHandleSnapshot? {
        storedSnapshot.handles[handleID]
    }

    func agentHandle(for handleID: String) -> WorkAgentHandleSnapshot? {
        storedSnapshot.agentHandles[handleID]
    }

    func sessionAttachment(for attachmentID: String) -> WorkSessionAttachmentSnapshot? {
        storedSnapshot.sessionAttachments[attachmentID]
    }

    func activeSessionAttachmentCount(for session: SessionRef) -> Int {
        activeAttachmentCounts[session.sessionID, default: 0]
    }

    func command(for commandID: String) -> WorkCommandSnapshot? {
        storedSnapshot.commands[commandID]
    }

    var activeActionCount: Int { activeActionCounter }
    var outstandingHandleCount: Int { outstandingHandleCounter }
    var liveAgentHandleCount: Int { liveAgentHandleCounter }
    var unreapedAgentHandleCount: Int { unreapedAgentHandleCounter }
    var retainedAgentHandleCount: Int { retainedAgentHandleCounter }

    mutating func stageScalar(_ continuation: BoundedWorkScalarContinuation) {
        scalarContinuation = continuation
    }

    mutating func stageSeenEvent(_ event: TimelineEvent) {
        storedSnapshot.seenEventIDs.insert(event.eventID)
        storedSnapshot.eventSequences[event.eventID] = event.sequence
        var continuation = scalarContinuation
        continuation.lastEventID = event.eventID
        continuation.lastSequence = max(continuation.lastSequence, event.sequence)
        if let hostSequence = event.hostSequence { continuation.lastHostSequence = hostSequence }
        stageScalar(continuation)
    }

    mutating func stageObservedRun(_ run: RunRef) {
        storedSnapshot.observedRunIDs.insert(run.runID)
    }

    mutating func stageSessionAttachment(_ attachment: WorkSessionAttachmentSnapshot) {
        let old = storedSnapshot.sessionAttachments[attachment.attachment.attachmentID]
        switch (old?.isAttached == true, attachment.isAttached) {
        case (false, true):
            activeAttachmentCounts[attachment.session.sessionID, default: 0] += 1
        case (true, false):
            // The shared transition rejects a changed Session identity before reaching this
            // seam.  Use the old value for the decrement anyway so a direct adapter mutation
            // cannot debit the replacement Session's counter.
            decrementAttachmentCount(for: old!.session)
        default:
            break
        }
        if attachment.isAttached {
            storedSnapshot.attachedSessionIDs.insert(attachment.session.sessionID)
        } else if activeAttachmentCounts[attachment.session.sessionID, default: 0] == 0 {
            storedSnapshot.attachedSessionIDs.remove(attachment.session.sessionID)
        }
        if let old, old.session != attachment.session,
           activeAttachmentCounts[old.session.sessionID, default: 0] == 0 {
            storedSnapshot.attachedSessionIDs.remove(old.session.sessionID)
        }
        storedSnapshot.sessionAttachments[attachment.attachment.attachmentID] = attachment
    }

    mutating func stageSessionAttachmentDetached(_ attachmentID: String) {
        guard var state = storedSnapshot.sessionAttachments[attachmentID] else { return }
        let wasAttached = state.isAttached
        state.isAttached = false
        storedSnapshot.sessionAttachments[attachmentID] = state
        if wasAttached {
            decrementAttachmentCount(for: state.session)
        }
        if activeAttachmentCounts[state.session.sessionID, default: 0] == 0 {
            storedSnapshot.attachedSessionIDs.remove(state.session.sessionID)
        }
    }

    mutating func stageSessionAttachmentCapabilities(_ attachmentID: String, capabilities: Set<String>) {
        guard var state = storedSnapshot.sessionAttachments[attachmentID] else { return }
        state.capabilities = capabilities
        storedSnapshot.sessionAttachments[attachmentID] = state
    }

    mutating func stageAction(_ action: WorkActionSnapshot, active: Bool?) {
        let actionID = action.action.actionID
        let wasActive = storedSnapshot.activeActionIDs.contains(actionID)
        if let active {
            if active && !wasActive {
                storedSnapshot.activeActionIDs.insert(actionID)
                activeActionCounter += 1
            } else if !active && wasActive {
                storedSnapshot.activeActionIDs.remove(actionID)
                decrementActiveActionCount()
            }
        }
        storedSnapshot.actions[actionID] = action
    }

    mutating func stageHandle(_ handle: WorkHandleSnapshot) {
        let handleID = handle.handle.handleID
        let old = storedSnapshot.handles[handleID]
        let wasOutstanding = old.map { !Self.isTerminalHandleState($0.state) } ?? false
        let isOutstanding = !Self.isTerminalHandleState(handle.state)
        if !wasOutstanding && isOutstanding {
            outstandingHandleCounter += 1
        } else if wasOutstanding && !isOutstanding {
            decrementOutstandingHandleCount()
        }
        storedSnapshot.handles[handleID] = handle
    }

    mutating func stageAgentHandle(_ handle: WorkAgentHandleSnapshot) {
        let handleID = handle.handle.handleID
        let old = storedSnapshot.agentHandles[handleID]
        if old == nil {
            retainedAgentHandleCounter += 1
        }
        let wasLive = old?.blocksWorkCompletion ?? false
        if !wasLive && handle.blocksWorkCompletion { liveAgentHandleCounter += 1 }
        if wasLive && !handle.blocksWorkCompletion { decrementLiveAgentHandleCount() }
        let wasUnreaped = old.map { $0.state != .reaped } ?? false
        let isUnreaped = handle.state != .reaped
        if !wasUnreaped && isUnreaped { unreapedAgentHandleCounter += 1 }
        if wasUnreaped && !isUnreaped { decrementUnreapedAgentHandleCount() }
        storedSnapshot.agentHandles[handleID] = handle
    }

    mutating func stageCommand(_ command: WorkCommandSnapshot) {
        storedSnapshot.commands[command.command.commandID] = command
    }

    mutating func stageRecovery(_ coverage: RecoveryCoverage, recorded: RecordedRecoveryCoverage) {
        storedSnapshot.recovery.append(coverage)
        storedSnapshot.recordedRecovery.append(recorded)
    }

    mutating func stageChildState(_ state: String, for childID: String) {
        storedSnapshot.childStates[childID] = state
    }

    mutating func stageUnknown(_ unknown: UnknownTimelineEvent) {
        storedSnapshot.unknownEvents.append(unknown)
        var continuation = scalarContinuation
        continuation.unknownDomains.formUnion(unknown.affectedDomains)
        stageScalar(continuation)
    }

    mutating func stageQuarantineOnly(_ event: TimelineEvent) {
        storedSnapshot.quarantinedEvents.append(event)
    }

    mutating func stageQuarantine(_ event: TimelineEvent, reason: String, structural: Bool) {
        var continuation = scalarContinuation
        if structural {
            continuation.causalOrderValid = false
            continuation.structuralIntegrityValid = false
        } else {
            continuation.semanticProjectionValid = false
        }
        stageScalar(continuation)
        storedSnapshot.corruptionReasons.append(reason)
        storedSnapshot.quarantinedEvents.append(event)
    }

    private mutating func decrementAttachmentCount(for session: SessionRef) {
        guard let count = activeAttachmentCounts[session.sessionID], count > 0 else {
            activeAttachmentCounts[session.sessionID] = 0
            return
        }
        let next = count - 1
        if next == 0 {
            activeAttachmentCounts.removeValue(forKey: session.sessionID)
        } else {
            activeAttachmentCounts[session.sessionID] = next
        }
    }

    private mutating func decrementActiveActionCount() {
        guard activeActionCounter > 0 else {
            activeActionCounter = 0
            return
        }
        activeActionCounter -= 1
    }

    private mutating func decrementOutstandingHandleCount() {
        guard outstandingHandleCounter > 0 else {
            outstandingHandleCounter = 0
            return
        }
        outstandingHandleCounter -= 1
    }

    private mutating func decrementLiveAgentHandleCount() {
        guard liveAgentHandleCounter > 0 else {
            liveAgentHandleCounter = 0
            return
        }
        liveAgentHandleCounter -= 1
    }

    private mutating func decrementUnreapedAgentHandleCount() {
        guard unreapedAgentHandleCounter > 0 else {
            unreapedAgentHandleCounter = 0
            return
        }
        unreapedAgentHandleCounter -= 1
    }

    private static func isTerminalHandleState(_ state: String) -> Bool {
        ["succeeded", "failed", "canceled", "completed"].contains(state)
    }
}

// MARK: - Shared Work semantics

/// The one event/legality implementation for Work journals.
///
/// Keep this function generic over the narrow state seam above.  Adapters own storage and
/// checked membership bookkeeping; this layer owns ordering, identity, legality, and evidence.
internal enum WorkReducerTransition {
    static func apply<State: WorkTransitionState>(_ event: TimelineEvent, to state: inout State) {
        guard accept(event, state: &state) else { return }
        guard event.isKnownType,
              event.schemaVersion <= TimelineEvent.currentSchemaVersion,
              event.payloadVersion <= 1
        else {
            recordUnknown(event, state: &state)
            return
        }

        // Child lifecycle records are the source of truth for Flock's child rows.  They must
        // carry the parent's Work identity explicitly; otherwise a reader can accept the
        // event into the parent's reducer while a canonical projection silently drops it.  If
        // the producer includes the optional parent Session/Run fields, they must agree with
        // the typed envelope too.  Do this before the general identity fields below are copied
        // so a foreign record cannot overwrite the reducer's established Work identity while
        // being quarantined.
        if event.type == TimelineEventType.childLifecycle {
            guard let expectedWork = state.scalar.work,
                  let eventWork = event.work,
                  eventWork == expectedWork else {
                quarantine(event, state: &state,
                           reason: "child lifecycle Work ownership is missing or mismatched")
                return
            }
            if let parentSessionID = event.payload["parent_session_id"]?.stringValue {
                guard let eventSession = event.session,
                      eventSession.sessionID == parentSessionID else {
                    quarantine(event, state: &state,
                               reason: "child lifecycle parent Session does not match envelope")
                    return
                }
            }
            if let parentRunID = event.payload["parent_run_id"]?.stringValue {
                guard let eventRun = event.run,
                      eventRun.runID == parentRunID else {
                    quarantine(event, state: &state,
                               reason: "child lifecycle parent Run does not match envelope")
                    return
                }
            }
        }

        if let work = event.work { updateScalar(&state) { $0.work = work } }
        if let host = event.workHost { updateScalar(&state) { $0.workHost = host } }
        if isExecutionMutation(event.type, state: state) {
            quarantine(event, state: &state, reason: "execution mutation on terminal Work")
            return
        }

        switch event.type {
        case TimelineEventType.workCreated:
            guard !isTerminalLifecycle(state) else {
                quarantine(event, state: &state, reason: "terminal Work cannot be reactivated")
                return
            }
            updateScalar(&state) { $0.lifecycle = .active }
        case TimelineEventType.workCompleted:
            guard !isTerminalLifecycle(state), !hasOutstandingWorkForCompletion(state) else {
                quarantine(event, state: &state,
                           reason: "Work completed while actions or Handles remain outstanding")
                return
            }
            let activeActionCount = state.activeActionCount
            updateScalar(&state) {
                $0.lifecycle = .completed
                $0.execution = activeActionCount == 0 ? .idle : .running
                $0.activeRun = nil
                $0.activeRunSession = nil
                $0.activeRunSessionAttachment = nil
                $0.activeTurn = nil
            }
        case TimelineEventType.workFailed:
            guard !isTerminalLifecycle(state) else {
                quarantine(event, state: &state, reason: "terminal Work cannot change lifecycle")
                return
            }
            guard !hasOutstandingWork(state) else {
                quarantine(event, state: &state,
                           reason: "Work failed while actions or Handles remain outstanding")
                return
            }
            // Failure describes the current execution attempt; Work itself remains attachable.
            updateScalar(&state) {
                if $0.lifecycle == .unknown { $0.lifecycle = .active }
                $0.execution = .failed
            }
        case TimelineEventType.workDestroyed:
            guard !isTerminalLifecycle(state), !hasOutstandingWorkForDestruction(state) else {
                quarantine(event, state: &state,
                           reason: "Work destroyed while actions, live Handles, or unreaped agent Handles remain")
                return
            }
            let activeActionCount = state.activeActionCount
            updateScalar(&state) {
                $0.lifecycle = .destroyed
                $0.execution = activeActionCount == 0 ? .idle : .running
                $0.activeRun = nil
                $0.activeRunSession = nil
                $0.activeRunSessionAttachment = nil
                $0.activeTurn = nil
            }
        case TimelineEventType.sessionAttached:
            guard let session = event.session, !session.sessionID.isEmpty,
                  let attachment = event.sessionAttachment, !attachment.attachmentID.isEmpty else {
                quarantine(event, state: &state, reason: "Work session attachment is malformed")
                return
            }
            if state.sessionAttachment(for: attachment.attachmentID) != nil {
                quarantine(event, state: &state,
                           reason: "Work session attachment identity was reused")
                return
            }
            state.stageSessionAttachment(WorkSessionAttachmentSnapshot(
                attachment: attachment, session: session,
                capabilities: Set(event.payload["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [])))
        case TimelineEventType.sessionDetached:
            guard let attachment = event.sessionAttachment,
                  state.sessionAttachment(for: attachment.attachmentID)?.isAttached == true else {
                quarantine(event, state: &state,
                           reason: "Work session detach references an unknown or detached attachment")
                return
            }
            state.stageSessionAttachmentDetached(attachment.attachmentID)
            // ``stageSessionAttachmentDetached`` updates the count and attached-session set.
            // The read above intentionally keeps the identity check in this shared layer.
        case TimelineEventType.sessionAttachmentCapabilityChanged:
            guard let attachment = event.sessionAttachment,
                  state.sessionAttachment(for: attachment.attachmentID) != nil,
                  let capabilities = event.payload["capabilities"]?.arrayValue?.compactMap(\.stringValue)
            else {
                quarantine(event, state: &state,
                           reason: "Work attachment capability change is malformed")
                return
            }
            state.stageSessionAttachmentCapabilities(attachment.attachmentID, capabilities: Set(capabilities))
        case TimelineEventType.runStarted:
            guard !isTerminalLifecycle(state), state.scalar.activeRun == nil,
                  let run = event.run, !run.runID.isEmpty,
                  !state.hasObservedRun(run.runID),
                  let session = event.session, !session.sessionID.isEmpty,
                  let sessionAttachment = event.sessionAttachment,
                  !sessionAttachment.attachmentID.isEmpty,
                  let attached = state.sessionAttachment(
                      for: sessionAttachment.attachmentID),
                  attached.session == session, attached.isAttached else {
                quarantine(event, state: &state,
                           reason: "run cannot start without a fresh identity, an exact attached Session/attachment pair, while another Run is active, or on terminal Work")
                return
            }
            state.stageObservedRun(run)
            updateScalar(&state) {
                $0.activeRun = run
                $0.activeRunSession = session
                $0.activeRunSessionAttachment = sessionAttachment
                $0.modelID = event.payload["model_id"]?.stringValue
                    ?? event.payload["model"]?.stringValue
                $0.execution = .running
                if $0.lifecycle == .unknown { $0.lifecycle = .active }
            }
        case TimelineEventType.runFinished:
            // The active Run is the thing this event is finishing. Requiring
            // `activeRun == nil` here made every run.finished event self-contradictory;
            // only actions, a turn, or live Handles must be quiescent first.
            guard let run = event.run, run == state.scalar.activeRun,
                  let session = event.session,
                  session == state.scalar.activeRunSession,
                  let sessionAttachment = event.sessionAttachment,
                  sessionAttachment == state.scalar.activeRunSessionAttachment,
                  !hasOutstandingRunWork(state) else {
                quarantine(event, state: &state,
                           reason: "run finish does not match the active Run owner or Work remains outstanding")
                return
            }
            updateScalar(&state) {
                $0.activeRun = nil
                $0.activeRunSession = nil
                $0.activeRunSessionAttachment = nil
                $0.execution = executionAfterRun(event.payload)
            }
        case TimelineEventType.modelChanged:
            guard let model = event.payload["model_id"]?.stringValue
                    ?? event.payload["model"]?.stringValue,
                  !model.isEmpty else {
                quarantine(event, state: &state, reason: "model change is missing model identity")
                return
            }
            updateScalar(&state) { $0.modelID = model }
        case TimelineEventType.turnStarted:
            guard let run = event.run, run == state.scalar.activeRun,
                  let turn = event.turn,
                  !turn.turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  state.scalar.activeTurn == nil else {
                quarantine(event, state: &state,
                           reason: "turn start requires the active Run, a non-empty identity, and no active turn")
                return
            }
            updateScalar(&state) {
                $0.activeTurn = turn
                $0.execution = .running
            }
        case TimelineEventType.turnFinished:
            guard let run = event.run, run == state.scalar.activeRun,
                  let turn = event.turn,
                  !turn.turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  turn == state.scalar.activeTurn,
                  let outcome = event.payload["outcome"]?.stringValue,
                  RunTurnOutcome(rawValue: outcome) != nil else {
                quarantine(event, state: &state,
                           reason: "turn finish must match the active Run and active turn with a valid outcome")
                return
            }
            let activeActionCount = state.activeActionCount
            updateScalar(&state) {
                $0.activeTurn = nil
                if activeActionCount == 0 { $0.execution = .idle }
            }
        case TimelineEventType.actionStarted:
            guard let action = event.action, !action.actionID.isEmpty,
                  let existing = state.action(for: action.actionID),
                  existing.state == .proposed,
                  existing.hasValidProviderEvidence,
                  validActionEventPayload(event, state: state),
                  event.payload["kind"] == nil || actionKind(in: event) == existing.kind,
                  event.payload["provider_admission"] == nil,
                  event.payload["provider_settlement"] == nil,
                  let actionState = event.payload["state"]?.stringValue.flatMap({ ActionExecutionState(rawValue: $0) }),
                  actionState == .queued || actionState == .running else {
                quarantine(event, state: &state, reason: "action start requires a prior action intent")
                return
            }
            var providerUsage = state.scalar.providerUsage
            if isProviderAction(existing.kind) {
                do { try providerUsage.recordStarted() }
                catch {
                    quarantine(event, state: &state,
                               reason: "provider action start exceeds the bounded usage aggregate")
                    return
                }
            }
            state.stageAction(existing.withStarted(event, state: actionState), active: true)
            updateScalar(&state) {
                $0.execution = .running
                $0.providerUsage = providerUsage
            }
        case TimelineEventType.actionIntent:
            guard let action = event.action, !action.actionID.isEmpty,
                  state.action(for: action.actionID) == nil,
                  validActionEventPayload(event, state: state),
                  actionKind(in: event) != nil,
                  event.payload["provider_settlement"] == nil,
                  let intent = event.payload["intent"]?.stringValue,
                  !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  event.payload["state"]?.stringValue.flatMap({ ActionExecutionState(rawValue: $0) }) == .proposed else {
                quarantine(event, state: &state, reason: "action intent is malformed or duplicated")
                return
            }
            guard let projected = WorkActionSnapshot(intent: event) else {
                quarantine(event, state: &state,
                           reason: "action intent is missing a known kind or identity")
                return
            }
            guard projected.hasValidProviderEvidence else {
                quarantine(event, state: &state,
                           reason: "action intent has invalid provider admission evidence")
                return
            }
            state.stageAction(projected, active: nil)
        case TimelineEventType.actionOutcome:
            applyActionOutcome(event, state: &state)
        case TimelineEventType.handleStarted:
            guard let run = event.run, run == state.scalar.activeRun,
                  let handle = event.handle,
                  !handle.handleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  state.handle(for: handle.handleID) == nil,
                  state.agentHandle(for: handle.handleID) == nil else {
                quarantine(event, state: &state,
                           reason: "Handle start requires the active Run, a fresh non-empty identity, and no existing Handle")
                return
            }
            guard let handleState = event.payload["state"]?.stringValue,
                  !handleState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                quarantine(event, state: &state, reason: "Handle start is missing state")
                return
            }
            state.stageHandle(WorkHandleSnapshot(handle: handle, state: handleState))
        case TimelineEventType.handleOutcome:
            guard let run = event.run, run == state.scalar.activeRun,
                  let handle = event.handle,
                  !handle.handleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let existing = state.handle(for: handle.handleID),
                  !isTerminalHandleState(existing.state) else {
                quarantine(event, state: &state,
                           reason: "Handle outcome requires the active Run and an outstanding Handle")
                return
            }
            guard let handleState = event.payload["state"]?.stringValue,
                  !handleState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                quarantine(event, state: &state, reason: "Handle outcome is missing state")
                return
            }
            state.stageHandle(WorkHandleSnapshot(handle: handle, state: handleState))
        case TimelineEventType.agentHandleQueued:
            applyAgentHandleQueued(event, state: &state)
        case TimelineEventType.agentHandleStarted:
            applyAgentHandleStarted(event, state: &state)
        case TimelineEventType.agentHandleProviderStarted, TimelineEventType.agentHandleProviderSettled:
            applyAgentHandleProviderEvent(event, state: &state)
        case TimelineEventType.agentHandleCancelRequested:
            applyAgentHandleCancellation(event, state: &state)
        case TimelineEventType.agentHandleTerminal:
            applyAgentHandleTerminal(event, state: &state)
        case TimelineEventType.agentHandleReaped:
            applyAgentHandleReaped(event, state: &state)
        case TimelineEventType.recoveryCoverage:
            guard let coverage = decodeRecoveryCoverage(event.payload),
                  let session = event.session, !session.sessionID.isEmpty,
                  let attachment = event.sessionAttachment, !attachment.attachmentID.isEmpty,
                  let sessionState = state.sessionAttachment(for: attachment.attachmentID),
                  sessionState.session == session, sessionState.isAttached,
                  let work = event.work, work == state.scalar.work,
                  let workJournal: JournalRef = event.payload["work_journal"].flatMap({ decodeTimelineValue($0) }),
                  workJournal.owner == .work(work),
                  workJournal.authority.authorityID == work.workHostID,
                  workJournal == state.scalar.journal,
                  let workHost = event.workHost, workHost.workHostID == work.workHostID,
                  let run = event.run, run == state.scalar.activeRun else {
                quarantine(event, state: &state,
                           reason: "Work recovery coverage has an invalid identity envelope")
                return
            }
            state.stageRecovery(coverage, recorded: RecordedRecoveryCoverage(
                coverage: coverage,
                sourceEvent: EventRef(journal: event.journal, eventID: event.eventID),
                session: session, work: work, workJournal: workJournal, workHost: workHost,
                sessionAttachment: attachment, run: run))
        case TimelineEventType.childLifecycle:
            guard let childID = event.payload["child_id"]?.stringValue,
                  let childState = event.payload["state"]?.stringValue,
                  !childID.isEmpty, !childState.isEmpty else {
                quarantine(event, state: &state,
                           reason: "child lifecycle is missing child identity or state")
                return
            }
            state.stageChildState(childState, for: childID)
        case TimelineEventType.artifact:
            // Artifact payloads are retained and indexed by their dedicated bounded service
            // projection. They do not mutate Work scalar state, but their producer envelope and
            // descriptor must still be exact before the known event is admitted to the prefix.
            guard validArtifactEvent(event, state: state) else {
                quarantine(event, state: &state,
                           reason: "artifact has an invalid active execution envelope or descriptor")
                return
            }
        case TimelineEventType.commandAccepted, TimelineEventType.commandRejected,
             TimelineEventType.commandDelivered, TimelineEventType.commandNotDelivered,
             TimelineEventType.commandDeliveryIndeterminate:
            applyCommandReceipt(event, state: &state)
        case TimelineEventType.hostOrderObserved:
            break
        default:
            recordUnknown(event, state: &state)
        }
    }

    private static func accept<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) -> Bool {
        guard state.scalar.structuralIntegrityValid else {
            state.stageQuarantineOnly(event)
            return false
        }
        guard !state.hasSeenEvent(event.eventID) else {
            quarantine(event, state: &state, reason: "duplicate event \(event.eventID)", structural: true)
            return false
        }
        guard acceptsJournal(event.journal, state: state) else {
            quarantine(event, state: &state,
                       reason: "event belongs to another journal", structural: true)
            return false
        }
        if state.scalar.journal == nil {
            updateScalar(&state) { $0.journal = event.journal }
        }
        if state.scalar.work == nil, case .work(let work) = event.journal.owner {
            updateScalar(&state) {
                $0.work = work
                $0.workHost = WorkHostRef(work.workHostID)
            }
        }
        if let work = event.work, work != state.scalar.work {
            quarantine(event, state: &state,
                       reason: "event Work identity does not match journal", structural: true)
            return false
        }
        if let host = event.workHost, host.workHostID != state.scalar.work?.workHostID {
            quarantine(event, state: &state,
                       reason: "event Work Host identity does not match journal", structural: true)
            return false
        }
        if let previous = state.scalar.lastEventID, event.previousEventID != previous {
            quarantine(event, state: &state, reason: "previous event mismatch", structural: true)
            return false
        } else if state.scalar.lastEventID == nil, event.previousEventID != nil {
            quarantine(event, state: &state,
                       reason: "non-empty previous event at journal start", structural: true)
            return false
        }
        if event.sequence != state.scalar.lastSequence + 1 {
            quarantine(event, state: &state,
                       reason: "sequence gap or non-increasing sequence", structural: true)
            return false
        }
        if let hostSequence = event.hostSequence,
           let previousHostSequence = state.scalar.lastHostSequence,
           hostSequence <= previousHostSequence {
            quarantine(event, state: &state,
                       reason: "non-increasing host order", structural: true)
            return false
        }
        state.stageSeenEvent(event)
        return true
    }

    private static func acceptsJournal<State: WorkTransitionState>(
        _ journal: JournalRef, state: State
    ) -> Bool {
        guard case .work = journal.owner else { return false }
        return state.scalar.journal == nil || state.scalar.journal == journal
    }

    private static func recordUnknown<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) {
        let domains = event.declaredDomains.isEmpty
            ? Set(TimelineDomain.allCases)
            : event.declaredDomains
        state.stageUnknown(UnknownTimelineEvent(
            event: event, journalOffset: state.seenEventCount - 1,
            affectedDomains: domains))
    }

    private static func quarantine<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State, reason: String, structural: Bool = false
    ) {
        state.stageQuarantine(event, reason: reason, structural: structural)
    }

    private static func applyAgentHandleQueued<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) {
        guard !isTerminalLifecycle(state),
              let handle = event.handle,
              validIdentity(handle.handleID),
              state.handle(for: handle.handleID) == nil,
              state.agentHandle(for: handle.handleID) == nil,
              state.retainedAgentHandleCount < WorkAgentHandleSnapshot.maximumRetainedPerWork,
              validAgentHandleDomains(event),
              let payload: WorkAgentHandleQueuedPayload = decodeExactTimelineValue(event.payload),
              validAgentHandleOrigin(payload.origin, event: event, state: state),
              validAgentHandleLabel(payload.label),
              payload.deadline.map({
                  $0.timeIntervalSince1970.isFinite && $0 > event.hostRecordedAt
              }) ?? true,
              validAgentHandleBody(payload.requestBody, journal: event.journal),
              event.command == nil, event.client == nil,
              event.causedByEventID == nil else {
            quarantine(event, state: &state,
                       reason: "agent Handle queue admission is malformed, over limit, or not owned by the active Run")
            return
        }
        let source = EventRef(journal: event.journal, eventID: event.eventID)
        state.stageAgentHandle(WorkAgentHandleSnapshot(
            handle: handle, origin: payload.origin, label: payload.label,
            deadline: payload.deadline, requestBody: payload.requestBody,
            queuedEvent: source, executionLimits: payload.executionLimits))
    }

    private static func applyAgentHandleStarted<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) {
        guard let existing = validAgentHandleTransition(event, state: state),
              existing.state == .queued,
              existing.deadline.map({
                  $0.timeIntervalSince1970.isFinite && event.hostRecordedAt < $0
              }) ?? true,
              event.payload == .object([:]),
              event.command == nil, event.client == nil else {
            quarantine(event, state: &state,
                       reason: "agent Handle start requires the exact queued origin and causal event")
            return
        }
        var updated = existing
        updated.state = .running
        let source = EventRef(journal: event.journal, eventID: event.eventID)
        updated.startedEvent = source
        updated.executionStartedAt = event.hostRecordedAt
        updated.latestLifecycleEvent = source
        state.stageAgentHandle(updated)
    }

    private static func applyAgentHandleProviderEvent<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) {
        guard let handle = event.handle,
              let existing = state.agentHandle(for: handle.handleID),
              validStoredAgentHandleEvidence(existing, state: state),
              let execution = existing.startedEvent,
              validAgentHandleDomains(event), event.command == nil, event.client == nil,
              event.action == nil, event.turn == nil,
              event.work == existing.origin.work, event.workHost == existing.origin.workHost,
              event.session == existing.origin.session,
              event.sessionAttachment == existing.origin.sessionAttachment,
              event.run == existing.origin.run,
              existing.state == .running || existing.state == .cancelRequested else {
            quarantine(event, state: &state,
                       reason: "Child provider crossing has no exact live execution owner")
            return
        }
        var updated = existing
        do {
            if event.type == TimelineEventType.agentHandleProviderStarted {
                guard existing.state == .running,
                      existing.deadline.map({ event.hostRecordedAt < $0 }) ?? true else {
                    throw WorkAgentProviderAccounting.Failure.invalidTransition
                }
                guard case .object(let payload) = event.payload,
                      let admissionValue = payload["admission"],
                      let admission = try? ProviderAdmission(timelineValue: admissionValue),
                      try existing.executionLimits.admissionDecision(
                          for: existing.providerAccounting.usage,
                          providerAdmission: admission) == .allow else {
                    throw WorkAgentProviderAccounting.Failure.invalidTransition
                }
                try updated.providerAccounting.applyStart(event, execution: execution)
            } else {
                try updated.providerAccounting.applySettlement(event)
            }
            state.stageAgentHandle(updated)
        } catch {
            quarantine(event, state: &state,
                       reason: "Child provider accounting transition is conflicting or malformed")
        }
    }

    private static func applyAgentHandleCancellation<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) {
        guard let existing = validAgentHandleTransition(event, state: state),
              existing.state == .queued || existing.state == .running,
              let payload: WorkAgentHandleCancelRequestedPayload = decodeExactTimelineValue(
                event.payload),
              validAgentHandleCancellationEnvelope(
                  event, cause: payload.cause, prior: existing, state: state) else {
            quarantine(event, state: &state,
                       reason: "agent Handle cancellation is malformed, stale, or already terminal")
            return
        }
        var updated = existing
        updated.state = .cancelRequested
        updated.cancellationEvidence = WorkAgentHandleCancellationEvidence(
            cause: payload.cause, event: WorkAgentHandleEventEvidence(event),
            command: event.command)
        updated.latestLifecycleEvent = updated.cancellationEvidence!.event.event
        state.stageAgentHandle(updated)
    }

    private static func applyAgentHandleTerminal<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) {
        guard let existing = validAgentHandleTransition(event, state: state),
              existing.state.isLive,
              event.command == nil, event.client == nil,
              let payload: WorkAgentHandleTerminalPayload = decodeExactTimelineValue(
                event.payload),
              existing.providerAccounting.pending == nil || payload.outcome != .succeeded,
              validAgentHandleTerminal(
                payload, prior: existing, event: event, state: state) else {
            quarantine(event, state: &state,
                       reason: "agent Handle terminal outcome is malformed, conflicting, or lacks exact cleanup evidence")
            return
        }
        var updated = existing
        updated.state = .terminal
        updated.terminalEvidence = WorkAgentHandleTerminalEvidence(
            outcome: payload.outcome, resultBody: payload.resultBody,
            cleanup: payload.cleanup, event: WorkAgentHandleEventEvidence(event),
            limitRefusal: payload.limitRefusal,
            executionSettledAt: payload.executionSettledAt)
        updated.latestLifecycleEvent = updated.terminalEvidence!.event.event
        state.stageAgentHandle(updated)
    }

    private static func applyAgentHandleReaped<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) {
        guard let existing = validAgentHandleTransition(event, state: state),
              existing.state == .terminal,
              existing.cleanup?.state != .indeterminate,
              event.command == nil, event.client == nil,
              let payload: WorkAgentHandleReapedPayload = decodeExactTimelineValue(
                event.payload) else {
            quarantine(event, state: &state,
                       reason: "agent Handle reap requires one exact terminal outcome")
            return
        }
        let source = EventRef(journal: event.journal, eventID: event.eventID)
        var updated = existing
        updated.state = .reaped
        updated.reapReason = payload.reason
        updated.latestLifecycleEvent = source
        updated.reapedEvent = source
        state.stageAgentHandle(updated)
    }

    private static func applyActionOutcome<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) {
        guard let action = event.action, !action.actionID.isEmpty,
              let existing = state.action(for: action.actionID),
              existing.hasValidProviderEvidence,
              validActionEventPayload(event, state: state),
              event.payload["kind"] == nil || actionKind(in: event) == existing.kind,
              event.payload["provider_admission"] == nil,
              let actionState = event.payload["state"]?.stringValue.flatMap({ ActionExecutionState(rawValue: $0) }),
              legalActionTransition(from: existing.state, to: actionState) else {
            quarantine(event, state: &state,
                       reason: "action outcome has no intent or illegal state transition")
            return
        }
        // Provider accounting begins at the dedicated action.started transition. Allowing the
        // generic outcome family to activate a proposed provider action would bypass that single
        // start count and make its later terminal settlement impossible to account exactly.
        if isProviderAction(existing.kind), existing.state == .proposed {
            quarantine(event, state: &state,
                       reason: "provider action activation requires action.started")
            return
        }
        let failureKind = event.payload["failure_kind"]?.stringValue
            .flatMap(ActionFailureKind.init(rawValue:))
        let retrySafety = event.payload["retry_safety"]?.stringValue
            .flatMap(ActionRetrySafety.init(rawValue:))
        if event.payload["failure_kind"] != nil && failureKind == nil {
            quarantine(event, state: &state, reason: "action outcome has unknown failure kind")
            return
        }
        if event.payload["retry_safety"] != nil && retrySafety == nil {
            quarantine(event, state: &state, reason: "action outcome has unknown retry safety")
            return
        }
        guard !actionState.isTerminal || retrySafety != nil else {
            quarantine(event, state: &state,
                       reason: "terminal action outcome must declare retry safety")
            return
        }
        if [.failed, .canceled, .indeterminateEffect].contains(actionState), failureKind == nil {
            quarantine(event, state: &state,
                       reason: "failed, canceled, or indeterminate action must declare failure kind")
            return
        }
        let providerSettlement: ProviderSettlement?
        if let value = event.payload["provider_settlement"] {
            guard let decoded = try? ProviderSettlement(timelineValue: value) else {
                quarantine(event, state: &state,
                           reason: "provider action outcome has malformed settlement evidence")
                return
            }
            providerSettlement = decoded
        } else {
            providerSettlement = nil
        }
        if isProviderAction(existing.kind), actionState.isTerminal {
            guard let admission = existing.providerAdmission, let providerSettlement,
                  (try? providerSettlement.validate(
                    admission: admission, kind: existing.kind, state: actionState)) != nil else {
                quarantine(event, state: &state,
                           reason: "provider action outcome has no matching terminal settlement")
                return
            }
        } else if isProviderAction(existing.kind) {
            guard providerSettlement == nil else {
                quarantine(event, state: &state,
                           reason: "nonterminal provider action cannot carry provider settlement")
                return
            }
        } else if providerSettlement != nil {
            quarantine(event, state: &state,
                       reason: "non-provider action outcome cannot carry provider settlement")
            return
        }
        var providerUsage = state.scalar.providerUsage
        if let providerSettlement {
            do { try providerUsage.recordSettlement(providerSettlement) }
            catch {
                quarantine(event, state: &state,
                           reason: "provider action settlement violates the Work usage aggregate")
                return
            }
        }
        state.stageAction(existing.withOutcome(
            event, state: actionState, failureKind: failureKind, retrySafety: retrySafety,
            providerSettlement: providerSettlement),
            active: !actionState.isTerminal)
        updateScalar(&state) { $0.providerUsage = providerUsage }
        if actionState.isTerminal {
            if state.activeActionCount == 0, state.scalar.activeTurn == nil {
                updateScalar(&state) {
                    // A user-run shell command may return nonzero or hit its chosen timeout
                    // without failing the waiting agent. Preserve the action outcome while
                    // leaving the same Run available for a follow-up. Unknown effects still
                    // require recovery rather than pretending execution is settled.
                    let failedAgent = actionState == .indeterminateEffect
                        || (actionState == .failed && existing.kind != .directShell)
                    $0.execution = failedAgent ? .failed : .idle
                }
            }
        } else {
            updateScalar(&state) { $0.execution = actionState == .cancelRequested ? .canceling : .running }
        }
    }

    private static func applyCommandReceipt<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) {
        guard let command = event.command, let commandState = commandState(for: event.type),
              !command.commandID.isEmpty,
              command.client.map({ !$0.clientID.isEmpty }) ?? true,
              command.sessionAttachment.map({ !$0.attachmentID.isEmpty }) ?? true,
              let hostSequence = event.hostSequence,
              command.client == event.client,
              command.sessionAttachment == event.sessionAttachment,
              command.causalCursor != nil,
              validCausalCursor(command.causalCursor, receiptSequence: event.sequence, state: state) else {
            quarantine(event, state: &state, reason: "command delivery event is missing command identity")
            return
        }
        if commandState == .accepted || commandState == .rejected {
            // Admission receipts describe the exact Work state observed by the caller.
            // A cursor without an event identity is deliberately represented by no cause;
            // once it has an identity, the event reference must retain its journal too.
            guard event.causedByEventID == causalEventRef(for: command) else {
                quarantine(event, state: &state,
                           reason: "command admission cause does not match its cursor")
                return
            }
        }
        if let existing = state.command(for: command.commandID) {
            guard existing.command == command else {
                quarantine(event, state: &state,
                           reason: "command id conflicts across clients or attachments")
                return
            }
            if commandState == .delivered || commandState == .notDelivered || commandState == .indeterminate {
                // Delivery is only meaningful as a receipt for this command's durable
                // acceptance event. The event ref is retained in the snapshot so this
                // remains enforceable when reduction resumes from an earlier prefix.
                guard existing.state == .accepted,
                      event.causedByEventID == existing.acceptanceEventRef else {
                    quarantine(event, state: &state,
                               reason: "command delivery cause does not match acceptance")
                    return
                }
            }
            if existing.state == commandState {
                let sameProvenance: Bool
                switch commandState {
                case .accepted, .rejected:
                    sameProvenance = existing.acceptanceActor == event.actor
                        && existing.acceptanceIdempotencyKey == event.idempotencyKey
                case .delivered, .notDelivered, .indeterminate:
                    sameProvenance = existing.deliveryActor == event.actor
                        && existing.deliveryIdempotencyKey == event.idempotencyKey
                }
                guard sameProvenance else {
                    quarantine(event, state: &state,
                               reason: "duplicate command receipt provenance conflicts")
                    return
                }
                // Idempotent duplicate: retain the first receipt and its provenance.
                return
            }
            guard existing.state == .accepted,
                  commandState == .delivered || commandState == .notDelivered || commandState == .indeterminate else {
                quarantine(event, state: &state, reason: "illegal command receipt transition")
                return
            }
            state.stageCommand(WorkCommandSnapshot(
                command: existing.command, state: commandState,
                acceptanceActor: existing.acceptanceActor,
                acceptanceHostSequence: existing.acceptanceHostSequence,
                acceptanceIdempotencyKey: existing.acceptanceIdempotencyKey,
                acceptanceEventRef: existing.acceptanceEventRef,
                deliveryEventRef: EventRef(journal: event.journal, eventID: event.eventID),
                deliveryActor: event.actor, deliveryHostSequence: hostSequence,
                deliveryIdempotencyKey: event.idempotencyKey,
                commandKind: existing.commandKind, deliveryMode: existing.deliveryMode,
                acceptanceRun: existing.acceptanceRun,
                carriesSessionInput: existing.carriesSessionInput))
            return
        } else if commandState == .delivered || commandState == .notDelivered || commandState == .indeterminate {
            quarantine(event, state: &state,
                       reason: "command delivery outcome appeared before acceptance")
            return
        }
        state.stageCommand(WorkCommandSnapshot(
            command: command, state: commandState, actor: event.actor,
            hostSequence: hostSequence, idempotencyKey: event.idempotencyKey,
            acceptanceEventRef: EventRef(journal: event.journal, eventID: event.eventID),
            commandKind: event.payload["command_kind"]?.stringValue.flatMap { CanonicalCommandKind(rawValue: $0) },
            deliveryMode: event.payload["delivery_mode"]?.stringValue.flatMap { RunInputDeliveryMode(rawValue: $0) },
            acceptanceRun: event.run,
            carriesSessionInput: event.payload["carries_session_input"]?.boolValue))
    }

    private static func legalActionTransition(
        from: ActionExecutionState, to: ActionExecutionState
    ) -> Bool {
        switch (from, to) {
        case (.proposed, .queued), (.proposed, .running),
             (.queued, .running), (.queued, .cancelRequested),
             (.running, .cancelRequested),
             (.queued, .succeeded), (.queued, .failed), (.queued, .canceled), (.queued, .indeterminateEffect),
             (.running, .succeeded), (.running, .failed), (.running, .canceled), (.running, .indeterminateEffect),
             (.cancelRequested, .canceled), (.cancelRequested, .indeterminateEffect):
            return true
        default:
            return false
        }
    }

    private static let maximumArtifactBodyBytes = 8 * 1024 * 1024
    private static let artifactPayloadKeys: Set<String> = [
        "artifact_id", "label", "media_type", "byte_count", "digest", "available",
        "body_reference",
    ]

    private static func validArtifactText(_ value: String, maximumBytes: Int) -> Bool {
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

    private static func validArtifactBodyReference(
        _ reference: TimelineBodyReference, journal: JournalRef
    ) -> Bool {
        guard reference.authority == journal,
              validArtifactText(
                  reference.referenceID, maximumBytes: WorkServiceBounds.maxIdentityCharacters),
              let byteCount = reference.byteCount,
              (0...maximumArtifactBodyBytes).contains(byteCount),
              let digest = reference.digest,
              ContextBodyStore.isValidDigest(digest),
              reference.referenceID == digest else {
            return false
        }
        return reference.mediaType.map {
            validArtifactText($0, maximumBytes: WorkServiceBounds.maxDiagnosticCharacters)
        } ?? true
    }

    private static func validArtifactEvent<State: WorkTransitionState>(
        _ event: TimelineEvent, state: State
    ) -> Bool {
        guard let expectedWork = state.scalar.work,
              let expectedHost = state.scalar.workHost,
              let eventWork = event.work,
              eventWork == expectedWork,
              let eventHost = event.workHost,
              eventHost == expectedHost,
              eventHost.workHostID == eventWork.workHostID,
              let activeRun = state.scalar.activeRun,
              event.run == activeRun,
              let activeSession = state.scalar.activeRunSession,
              let activeAttachment = state.scalar.activeRunSessionAttachment,
              event.session == activeSession,
              event.sessionAttachment == activeAttachment,
              let attached = state.sessionAttachment(for: activeAttachment.attachmentID),
              attached.session == activeSession,
              attached.isAttached,
              event.turn == state.scalar.activeTurn else {
            return false
        }

        if let action = event.action {
            guard validArtifactText(
                      action.actionID, maximumBytes: WorkServiceBounds.maxIdentityCharacters),
                  let actionSnapshot = state.action(for: action.actionID),
                  state.isActionActive(action.actionID),
                  let startedEvent = actionSnapshot.startedEvent?.sourceEvent,
                  event.causedByEventID == startedEvent else {
                return false
            }
        }
        guard validArtifactPayload(event.payload, journal: event.journal) else {
            return false
        }

        if event.payload["media_type"]?.stringValue == ObservedRepositoryReviewFormat.mediaType {
            guard let turn = event.turn,
                  turn == state.scalar.activeTurn,
                  let action = event.action,
                  let actionSnapshot = state.action(for: action.actionID),
                  state.isActionActive(action.actionID),
                  let startedEvent = actionSnapshot.startedEvent?.sourceEvent,
                  event.causedByEventID == startedEvent else {
                return false
            }
        }
        return true
    }

    private static func validArtifactPayload(
        _ payload: JSONValue, journal: JournalRef
    ) -> Bool {
        guard let object = payload.objectValue,
              object.keys.allSatisfy({ artifactPayloadKeys.contains($0) }),
              let artifactID = object["artifact_id"]?.stringValue,
              validArtifactText(
                  artifactID, maximumBytes: WorkServiceBounds.maxIdentityCharacters),
              let label = object["label"]?.stringValue,
              validArtifactText(label, maximumBytes: WorkServiceBounds.maxDiagnosticCharacters),
              let available = object["available"]?.boolValue else {
            return false
        }

        let mediaType: String?
        if let value = object["media_type"] {
            guard let decoded = value.stringValue,
                  validArtifactText(
                      decoded, maximumBytes: WorkServiceBounds.maxDiagnosticCharacters) else {
                return false
            }
            mediaType = decoded
        } else {
            mediaType = nil
        }

        let byteCount: Int?
        if let value = object["byte_count"] {
            guard let decoded = value.intValue,
                  (0...maximumArtifactBodyBytes).contains(decoded) else {
                return false
            }
            byteCount = decoded
        } else {
            byteCount = nil
        }

        let digest: String?
        if let value = object["digest"] {
            guard let decoded = value.stringValue,
                  ContextBodyStore.isValidDigest(decoded) else {
                return false
            }
            digest = decoded
        } else {
            digest = nil
        }

        let bodyReference: TimelineBodyReference?
        if let value = object["body_reference"] {
            guard let data = try? JSONEncoder().encode(value),
                  let decoded = try? JSONDecoder().decode(
                      TimelineBodyReference.self, from: data),
                  validArtifactBodyReference(decoded, journal: journal) else {
                return false
            }
            bodyReference = decoded
        } else {
            bodyReference = nil
        }

        guard available == (bodyReference != nil) else { return false }
        if let bodyReference {
            return bodyReference.mediaType == mediaType
                && bodyReference.byteCount == byteCount
                && bodyReference.digest == digest
                && byteCount != nil
                && digest != nil
        }
        return byteCount == nil && digest == nil
    }

    /// Action lifecycle records use a typed vocabulary where present. Omitting optional intent
    /// fields is valid on a start/outcome, but a present malformed value must quarantine the
    /// record rather than silently dropping producer facts. The envelope's Run/Turn identities
    /// are also checked against the currently active execution when supplied.
    private static func validActionEventPayload<State: WorkTransitionState>(
        _ event: TimelineEvent, state: State
    ) -> Bool {
        if event.payload["kind"] != nil && actionKind(in: event) == nil { return false }
        for key in ["intent", "target", "scope"] where event.payload[key] != nil {
            guard event.payload[key]?.stringValue != nil else { return false }
        }
        if event.payload["metadata"] != nil && event.payload["metadata"]?.objectValue == nil {
            return false
        }
        if let run = event.run, run != state.scalar.activeRun { return false }
        if let turn = event.turn {
            guard event.run == state.scalar.activeRun, turn == state.scalar.activeTurn else { return false }
        }
        return true
    }

    private static func actionKind(in event: TimelineEvent) -> ActionKind? {
        event.payload["kind"]?.stringValue.flatMap(ActionKind.init(rawValue:))
    }

    private static func isProviderAction(_ kind: ActionKind) -> Bool {
        kind == .provider || kind == .compactionProvider
    }

    private static func executionAfterRun(_ payload: JSONValue) -> WorkExecution {
        switch payload["state"]?.stringValue {
        case "failed": return .failed
        case "preparing": return .preparing
        case "canceling", "cancel_requested": return .canceling
        case "held": return .held
        default: return .idle
        }
    }

    private static func hasOutstandingWork<State: WorkTransitionState>(_ state: State) -> Bool {
        state.scalar.activeRun != nil || state.scalar.activeTurn != nil
            || state.activeActionCount > 0 || state.outstandingHandleCount > 0
    }

    private static func hasOutstandingWorkForCompletion<State: WorkTransitionState>(
        _ state: State
    ) -> Bool {
        hasOutstandingWork(state) || state.liveAgentHandleCount > 0
    }

    private static func hasOutstandingWorkForDestruction<State: WorkTransitionState>(
        _ state: State
    ) -> Bool {
        hasOutstandingWorkForCompletion(state) || state.unreapedAgentHandleCount > 0
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= PersistentWorkExactState.maximumIdentityBytes
    }

    private static func validAgentHandleLabel(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= WorkAgentHandleSnapshot.maximumLabelBytes
            && value.unicodeScalars.allSatisfy { $0.value > 0x1F && !(0x7F...0x9F).contains($0.value) }
    }

    private static func validAgentHandleBody(
        _ reference: TimelineBodyReference, journal: JournalRef
    ) -> Bool {
        reference.authority == journal
            && validIdentity(reference.referenceID)
            && reference.referenceID == reference.digest
            && reference.digest.map(ContextBodyStore.isValidDigest) == true
            && reference.byteCount.map { (0...WorkAgentHandleSnapshot.maximumBodyBytes).contains($0) } == true
            && reference.mediaType.map { !$0.isEmpty && $0.utf8.count <= 512 } ?? true
    }

    private static func validAgentHandleOrigin<State: WorkTransitionState>(
        _ origin: WorkAgentHandleOrigin, event: TimelineEvent, state: State
    ) -> Bool {
        guard case .work(let owner) = event.journal.owner,
              let work = state.scalar.work, let host = state.scalar.workHost,
              origin.work == work, owner == work, event.work == work,
              origin.workHost == host, event.workHost == host,
              host.workHostID == work.workHostID,
              origin.session == state.scalar.activeRunSession, event.session == origin.session,
              origin.sessionAttachment == state.scalar.activeRunSessionAttachment,
              event.sessionAttachment == origin.sessionAttachment,
              origin.run == state.scalar.activeRun, event.run == origin.run,
              state.sessionAttachment(for: origin.sessionAttachment.attachmentID)?.session == origin.session,
              state.sessionAttachment(for: origin.sessionAttachment.attachmentID)?.isAttached == true else {
            return false
        }
        return [work.workHostID, work.workID, host.workHostID, origin.session.sessionID,
                origin.sessionAttachment.attachmentID, origin.run.runID].allSatisfy(validIdentity)
    }

    private static func validAgentHandleTransition<State: WorkTransitionState>(
        _ event: TimelineEvent, state: State
    ) -> WorkAgentHandleSnapshot? {
        guard let handle = event.handle, let existing = state.agentHandle(for: handle.handleID),
              validStoredAgentHandleEvidence(existing, state: state),
              validAgentHandleDomains(event),
              event.work == existing.origin.work,
              event.workHost == existing.origin.workHost,
              event.session == existing.origin.session,
              event.sessionAttachment == existing.origin.sessionAttachment,
              event.run == existing.origin.run,
              event.causedByEventID == existing.latestLifecycleEvent else { return nil }
        return existing
    }

    private static func validStoredAgentHandleEvidence<State: WorkTransitionState>(
        _ handle: WorkAgentHandleSnapshot, state: State
    ) -> Bool {
        guard let journal = state.scalar.journal else { return false }
        guard (try? handle.providerAccounting.validate(
            origin: handle.origin, handle: handle.handle, execution: handle.startedEvent,
            journal: journal, lastSequence: state.scalar.lastSequence)) != nil else { return false }
        guard (try? handle.providerAccounting.validateLifecycleOrder(
            executionSequence: handle.startedEvent.flatMap {
                state.eventSequence(for: $0.eventID)
            },
            cancellationSequence: handle.cancellationEvidence?.event.sequence,
            terminalSequence: handle.terminalEvidence?.event.sequence)) != nil else { return false }
        guard (try? handle.executionLimits.validate()) != nil,
              (handle.startedEvent == nil) == (handle.executionStartedAt == nil),
              handle.executionStartedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              handle.deadline.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
            return false
        }
        func validEvent(_ proof: WorkAgentHandleEventEvidence) -> Bool {
            guard proof.event.journal == journal,
                  validIdentity(proof.event.eventID), proof.sequence > 0,
                  proof.sequence <= state.scalar.lastSequence,
                  state.eventSequence(for: proof.event.eventID) == proof.sequence,
                  proof.hostSequence.map({ $0 >= 0 }) ?? true,
                  validIdentity(proof.actor.actorID),
                  !proof.actor.kind.isEmpty,
                  proof.actor.kind.utf8.count <= PersistentWorkExactState.maximumIdentityBytes,
                  proof.work == handle.origin.work,
                  proof.workHost == handle.origin.workHost,
                  proof.session == handle.origin.session,
                  proof.sessionAttachment == handle.origin.sessionAttachment,
                  proof.run == handle.origin.run,
                  proof.handle == handle.handle,
                  proof.hostRecordedAt.timeIntervalSince1970.isFinite,
                  proof.provenance == .native else { return false }
            if proof.sequence == 1 {
                guard proof.previousEventID == nil else { return false }
            } else {
                guard let previous = proof.previousEventID, validIdentity(previous),
                      state.eventSequence(for: previous) == proof.sequence - 1 else { return false }
            }
            if let cause = proof.causedByEventID {
                guard cause.journal == journal, validIdentity(cause.eventID),
                      state.eventSequence(for: cause.eventID).map({ $0 < proof.sequence }) == true
                else { return false }
            }
            return true
        }
        guard handle.providerAccounting.evidence.allSatisfy(validEvent) else { return false }
        if let cancellation = handle.cancellationEvidence {
            guard validEvent(cancellation.event),
                  cancellation.event.causedByEventID
                    == (handle.startedEvent ?? handle.queuedEvent) else { return false }
            if cancellation.cause == .client {
                guard let command = cancellation.command,
                      validIdentity(command.commandID),
                      let client = command.client, validIdentity(client.clientID),
                      cancellation.event.client == client,
                      let attachment = command.sessionAttachment,
                      validIdentity(attachment.attachmentID),
                      let cursor = command.causalCursor,
                      cursor.journal == journal,
                      cursor.eventID == cancellation.event.previousEventID,
                      cursor.sequence == cancellation.event.sequence - 1 else { return false }
            } else if cancellation.cause == .deadline {
                guard cancellation.command == nil, cancellation.event.client == nil,
                      let deadline = handle.deadline,
                      cancellation.event.hostRecordedAt >= deadline else { return false }
            } else if cancellation.command != nil || cancellation.event.client != nil {
                return false
            }
        }
        if let terminal = handle.terminalEvidence {
            guard validEvent(terminal.event),
                  terminal.event.causedByEventID
                    == (handle.cancellationEvent ?? handle.startedEvent ?? handle.queuedEvent),
                  terminal.outcome != .succeeded || terminal.resultBody != nil,
                  terminal.resultBody.map({ validAgentHandleBody($0, journal: journal) }) ?? true
            else { return false }
            guard terminal.event.client == nil else { return false }
            if terminal.outcome == .expired {
                guard let deadline = handle.deadline,
                      terminal.event.hostRecordedAt >= deadline else { return false }
            }
            if let cleanupEvidence = terminal.cleanup.evidence {
                guard cleanupEvidence.journal == journal,
                      state.eventSequence(for: cleanupEvidence.eventID).map({
                          $0 < terminal.event.sequence
                      }) == true else { return false }
            }
            if handle.startedEvent == nil {
                guard terminal.cleanup.state == .notStarted,
                      [.failed, .canceled, .expired].contains(terminal.outcome) else { return false }
            } else if terminal.outcome == .indeterminate {
                guard terminal.cleanup.state == .indeterminate else { return false }
            } else if terminal.cleanup.state != .quiesced { return false }
            if terminal.outcome == .limited {
                guard terminal.cleanup.state == .quiesced,
                      handle.providerAccounting.pending == nil,
                      let refusal = terminal.limitRefusal,
                      let startedAt = handle.executionStartedAt,
                      let settledAt = terminal.executionSettledAt,
                      settledAt.timeIntervalSince1970.isFinite,
                      settledAt >= startedAt,
                      settledAt <= terminal.event.hostRecordedAt,
                      (try? refusal.validate(
                          limits: handle.executionLimits,
                          usage: handle.providerAccounting.usage)) != nil,
                      handle.deadline.map({ settledAt < $0 }) ?? true
                else { return false }
            } else if terminal.limitRefusal != nil || terminal.executionSettledAt != nil {
                return false
            }
            if handle.cancellationEvidence != nil,
               !cancellationAllowsTerminalOutcome(
                   handle.cancellationCause, outcome: terminal.outcome) { return false }
        }
        switch handle.state {
        case .queued:
            return handle.cancellationEvidence == nil && handle.terminalEvidence == nil
                && handle.startedEvent == nil
                && handle.latestLifecycleEvent == handle.queuedEvent
        case .running:
            return handle.cancellationEvidence == nil && handle.terminalEvidence == nil
                && handle.startedEvent != nil
                && handle.latestLifecycleEvent == handle.startedEvent
        case .cancelRequested:
            return handle.cancellationEvidence != nil && handle.terminalEvidence == nil
                && handle.latestLifecycleEvent == handle.cancellationEvent
        case .terminal:
            return handle.terminalEvidence != nil
                && handle.latestLifecycleEvent == handle.terminalEvent
        case .reaped:
            return handle.terminalEvidence != nil && handle.reapedEvent != nil
                && handle.reapReason != nil
                && handle.latestLifecycleEvent == handle.reapedEvent
                && handle.cleanup?.state != .indeterminate
        }
    }

    private static func validAgentHandleDomains(_ event: TimelineEvent) -> Bool {
        event.declaredDomains == [.work, .runtime, .externalEffects]
            && event.provenance == .native
            && (event.hostSequence.map({ $0 >= 0 }) ?? true)
            && event.hostRecordedAt.timeIntervalSince1970.isFinite
            && validIdentity(event.actor.actorID)
            && validIdentity(event.actor.kind)
    }

    private static func validAgentHandleCancellationEnvelope<State: WorkTransitionState>(
        _ event: TimelineEvent, cause: WorkAgentHandleCancellationCause,
        prior: WorkAgentHandleSnapshot, state: State
    ) -> Bool {
        if cause != .client {
            guard event.command == nil, event.client == nil else { return false }
            if cause == .deadline {
                guard let deadline = prior.deadline,
                      deadline.timeIntervalSince1970.isFinite,
                      event.hostRecordedAt.timeIntervalSince1970.isFinite,
                      event.hostRecordedAt >= deadline else { return false }
            }
            return true
        }
        guard let command = event.command, validIdentity(command.commandID),
              let client = command.client, event.client == client, validIdentity(client.clientID),
              let callerAttachment = command.sessionAttachment,
              state.sessionAttachment(for: callerAttachment.attachmentID)?.isAttached == true,
              let cursor = command.causalCursor,
              cursor.journal == event.journal,
              cursor.eventID == event.previousEventID,
              cursor.sequence == event.sequence - 1 else { return false }
        return true
    }

    private static func validAgentHandleTerminal<State: WorkTransitionState>(
        _ payload: WorkAgentHandleTerminalPayload, prior: WorkAgentHandleSnapshot,
        event: TimelineEvent, state: State
    ) -> Bool {
        if let body = payload.resultBody, !validAgentHandleBody(body, journal: event.journal) {
            return false
        }
        if payload.outcome == .succeeded && payload.resultBody == nil { return false }
        if payload.outcome == .expired {
            guard let deadline = prior.deadline,
                  deadline.timeIntervalSince1970.isFinite,
                  event.hostRecordedAt.timeIntervalSince1970.isFinite,
                  event.hostRecordedAt >= deadline else {
                return false
            }
        }
        if payload.outcome == .limited {
            guard prior.providerAccounting.pending == nil,
                  payload.cleanup.state == .quiesced,
                  let refusal = payload.limitRefusal,
                  let startedAt = prior.executionStartedAt,
                  let settledAt = payload.executionSettledAt,
                  settledAt.timeIntervalSince1970.isFinite,
                  settledAt >= startedAt,
                  settledAt <= event.hostRecordedAt,
                  (try? refusal.validate(
                      limits: prior.executionLimits,
                      usage: prior.providerAccounting.usage)) != nil else {
                return false
            }
            guard prior.deadline.map({ settledAt < $0 }) ?? true else {
                return false
            }
        } else if payload.limitRefusal != nil || payload.executionSettledAt != nil {
            return false
        }
        if let evidence = payload.cleanup.evidence {
            guard evidence.journal == event.journal,
                  let sequence = state.eventSequence(for: evidence.eventID),
                  sequence < event.sequence else { return false }
        }
        if prior.startedEvent == nil {
            guard payload.cleanup.state == .notStarted,
                  [.failed, .canceled, .expired].contains(payload.outcome) else { return false }
        } else if payload.outcome == .indeterminate {
            guard payload.cleanup.state == .indeterminate else { return false }
        } else {
            guard payload.cleanup.state == .quiesced else { return false }
        }
        if prior.state == .cancelRequested,
           !cancellationAllowsTerminalOutcome(
               prior.cancellationCause, outcome: payload.outcome) { return false }
        return true
    }

    private static func cancellationAllowsTerminalOutcome(
        _ cause: WorkAgentHandleCancellationCause?,
        outcome: WorkAgentHandleTerminalOutcome
    ) -> Bool {
        switch cause {
        case .deadline:
            return [.expired, .indeterminate].contains(outcome)
        case .client, .workDestruction, .hostShutdown:
            return [.canceled, .indeterminate].contains(outcome)
        case nil:
            return true
        }
    }

    private static func hasOutstandingRunWork<State: WorkTransitionState>(_ state: State) -> Bool {
        state.scalar.activeTurn != nil || state.activeActionCount > 0
            || state.outstandingHandleCount > 0
    }

    private static func isTerminalHandleState(_ state: String) -> Bool {
        ["succeeded", "failed", "canceled", "completed"].contains(state)
    }

    private static func isTerminalLifecycle<State: WorkTransitionState>(_ state: State) -> Bool {
        state.scalar.lifecycle == .completed || state.scalar.lifecycle == .destroyed
    }

    private static func isExecutionMutation<State: WorkTransitionState>(
        _ type: String, state: State
    ) -> Bool {
        [TimelineEventType.runStarted, TimelineEventType.runFinished,
         TimelineEventType.turnStarted, TimelineEventType.turnFinished,
         TimelineEventType.actionIntent, TimelineEventType.actionStarted,
         TimelineEventType.actionOutcome, TimelineEventType.handleStarted,
         TimelineEventType.handleOutcome].contains(type) && isTerminalLifecycle(state)
    }

    private static func commandState(for type: String) -> CommandDeliveryState? {
        switch type {
        case TimelineEventType.commandAccepted: return .accepted
        case TimelineEventType.commandRejected: return .rejected
        case TimelineEventType.commandDelivered: return .delivered
        case TimelineEventType.commandNotDelivered: return .notDelivered
        case TimelineEventType.commandDeliveryIndeterminate: return .indeterminate
        default: return nil
        }
    }

    private static func causalEventRef(for command: CommandRef) -> EventRef? {
        guard let cursor = command.causalCursor, let eventID = cursor.eventID else { return nil }
        return EventRef(journal: cursor.journal, eventID: eventID)
    }

    private static func validCausalCursor<State: WorkTransitionState>(
        _ cursor: JournalCursor?, receiptSequence: Int, state: State
    ) -> Bool {
        guard let cursor else { return true }
        // A command describes the state observed before its receipt. It cannot point at another
        // Work journal or at this/future receipt in the same journal.
        guard cursor.journal == state.scalar.journal, cursor.sequence < receiptSequence else { return false }
        guard let eventID = cursor.eventID else { return true }
        return state.eventSequence(for: eventID) == cursor.sequence
    }

    private static func updateScalar<State: WorkTransitionState>(
        _ state: inout State, _ body: (inout BoundedWorkScalarContinuation) -> Void
    ) {
        var continuation = state.scalar
        body(&continuation)
        state.stageScalar(continuation)
    }
}

// MARK: - Shared decoding helpers

// These helpers are shared by WorkReducerTransition and SessionReducer.  They intentionally keep
// the forgiving JSONValue decoding boundary used by the pre-extraction reducers.
func decodeRecoveryCoverage(_ payload: JSONValue) -> RecoveryCoverage? {
    guard let object = payload.objectValue else { return nil }
    var planes: [RecoveryPlane: RecoveryCoverageStatus] = [:]
    if let encoded = object["planes"]?.objectValue {
        for (key, value) in encoded {
            guard let plane = RecoveryPlane(rawValue: key),
                  let status = value.stringValue.flatMap(RecoveryCoverageStatus.init(rawValue:))
            else { continue }
            planes[plane] = status
        }
    }
    let caveats = object["caveats"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let operation = object["operation"]?.stringValue.flatMap(RecoveryOperation.init(rawValue:)) ?? .unknown
    let evidence: EventRef? = object["evidence"].flatMap { decodeTimelineValue($0) }
    let cursor: JournalCursor? = object["evidence_cursor"].flatMap { decodeTimelineValue($0) }
    return RecoveryCoverage(operation: operation, planes: planes, evidence: evidence,
                            evidenceCursor: cursor, caveats: caveats)
}

func decodeTimelineValue<T: Decodable>(_ value: JSONValue) -> T? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

/// Strict typed payload decoding for security-sensitive canonical families. Unlike the general
/// compatibility decoder, this rejects ignored/unknown fields (including nested raw text) by
/// requiring the decoded value's canonical JSON shape to equal the source shape exactly.
func decodeExactTimelineValue<T: Codable>(_ value: JSONValue) -> T? {
    guard let decoded: T = decodeTimelineValue(value),
          let encoded = try? JSONEncoder().encode(decoded),
          JSONValue.parse(encoded) == value else { return nil }
    return decoded
}
