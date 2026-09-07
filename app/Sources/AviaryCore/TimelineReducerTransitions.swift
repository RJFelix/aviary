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
    func handle(for handleID: String) -> WorkHandleSnapshot?
    func sessionAttachment(for attachmentID: String) -> WorkSessionAttachmentSnapshot?
    func activeSessionAttachmentCount(for session: SessionRef) -> Int
    func command(for commandID: String) -> WorkCommandSnapshot?

    /// Checked cardinalities.  Adapters must never decrement either value below zero.
    var activeActionCount: Int { get }
    var outstandingHandleCount: Int { get }
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

    func handle(for handleID: String) -> WorkHandleSnapshot? {
        storedSnapshot.handles[handleID]
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
            guard !isTerminalLifecycle(state), !hasOutstandingWork(state) else {
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
            guard !isTerminalLifecycle(state), !hasOutstandingWork(state) else {
                quarantine(event, state: &state,
                           reason: "Work destroyed while actions or Handles remain outstanding")
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
                  turn == state.scalar.activeTurn else {
                quarantine(event, state: &state,
                           reason: "turn finish must match the active Run and active turn")
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
                  validActionEventPayload(event, state: state),
                  event.payload["kind"] == nil || actionKind(in: event) == existing.kind,
                  let actionState = event.payload["state"]?.stringValue.flatMap({ ActionExecutionState(rawValue: $0) }),
                  actionState == .queued || actionState == .running else {
                quarantine(event, state: &state, reason: "action start requires a prior action intent")
                return
            }
            state.stageAction(existing.withStarted(event, state: actionState), active: true)
            updateScalar(&state) { $0.execution = .running }
        case TimelineEventType.actionIntent:
            guard let action = event.action, !action.actionID.isEmpty,
                  state.action(for: action.actionID) == nil,
                  validActionEventPayload(event, state: state),
                  actionKind(in: event) != nil,
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
            state.stageAction(projected, active: nil)
        case TimelineEventType.actionOutcome:
            applyActionOutcome(event, state: &state)
        case TimelineEventType.handleStarted:
            guard let run = event.run, run == state.scalar.activeRun,
                  let handle = event.handle,
                  !handle.handleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  state.handle(for: handle.handleID) == nil else {
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
            // projection. They do not mutate Work scalar state, but they are a known native
            // event and must not poison the Work domain as an unknown extension.
            break
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

    private static func applyActionOutcome<State: WorkTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) {
        guard let action = event.action, !action.actionID.isEmpty,
              let existing = state.action(for: action.actionID),
              validActionEventPayload(event, state: state),
              event.payload["kind"] == nil || actionKind(in: event) == existing.kind,
              let actionState = event.payload["state"]?.stringValue.flatMap({ ActionExecutionState(rawValue: $0) }),
              legalActionTransition(from: existing.state, to: actionState) else {
            quarantine(event, state: &state,
                       reason: "action outcome has no intent or illegal state transition")
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
        state.stageAction(existing.withOutcome(
            event, state: actionState, failureKind: failureKind, retrySafety: retrySafety),
            active: !actionState.isTerminal)
        if actionState.isTerminal {
            if state.activeActionCount == 0, state.scalar.activeTurn == nil {
                updateScalar(&state) {
                    $0.execution = actionState == .failed || actionState == .indeterminateEffect
                        ? .failed : .idle
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
