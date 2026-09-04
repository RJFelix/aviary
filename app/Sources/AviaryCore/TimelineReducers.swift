import Foundation

/// Pure projection of a Work journal. Applying the same prefix live or from cold storage yields
/// the same snapshot; no runtime, filesystem, wall-clock, or GUI state is consulted.
public struct WorkReducer: Sendable {
    public private(set) var snapshot: WorkSnapshot

    public init(snapshot: WorkSnapshot = WorkSnapshot()) {
        self.snapshot = snapshot
    }

    public static func reduce<S: Sequence>(
        _ events: S, initial: WorkSnapshot = WorkSnapshot()
    ) -> WorkSnapshot where S.Element == TimelineEvent {
        var reducer = WorkReducer(snapshot: initial)
        for event in events { reducer.apply(event) }
        return reducer.snapshot
    }

    public mutating func apply(_ event: TimelineEvent) {
        guard accept(event) else { return }
        guard event.isKnownType,
              event.schemaVersion <= TimelineEvent.currentSchemaVersion,
              event.payloadVersion <= 1
        else {
            recordUnknown(event)
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
            guard let expectedWork = snapshot.work,
                  let eventWork = event.work,
                  eventWork == expectedWork else {
                quarantine(event, reason: "child lifecycle Work ownership is missing or mismatched")
                return
            }
            if let parentSessionID = event.payload["parent_session_id"]?.stringValue {
                guard let eventSession = event.session,
                      eventSession.sessionID == parentSessionID else {
                    quarantine(event, reason: "child lifecycle parent Session does not match envelope")
                    return
                }
            }
            if let parentRunID = event.payload["parent_run_id"]?.stringValue {
                guard let eventRun = event.run,
                      eventRun.runID == parentRunID else {
                    quarantine(event, reason: "child lifecycle parent Run does not match envelope")
                    return
                }
            }
        }
        if let work = event.work { snapshot.work = work }
        if let host = event.workHost { snapshot.workHost = host }
        if isExecutionMutation(event.type) && isTerminalLifecycle {
            quarantine(event, reason: "execution mutation on terminal Work")
            return
        }

        switch event.type {
        case TimelineEventType.workCreated:
            guard !isTerminalLifecycle else {
                quarantine(event, reason: "terminal Work cannot be reactivated")
                return
            }
            snapshot.lifecycle = .active
        case TimelineEventType.workCompleted:
            guard !isTerminalLifecycle, !hasOutstandingWork else {
                quarantine(event, reason: "Work completed while actions or Handles remain outstanding")
                return
            }
            snapshot.lifecycle = .completed
            snapshot.execution = snapshot.activeActionIDs.isEmpty ? .idle : .running
            snapshot.activeRun = nil
            snapshot.activeTurn = nil
        case TimelineEventType.workFailed:
            guard !isTerminalLifecycle else {
                quarantine(event, reason: "terminal Work cannot change lifecycle")
                return
            }
            guard !hasOutstandingWork else {
                quarantine(event, reason: "Work failed while actions or Handles remain outstanding")
                return
            }
            // Failure describes the current execution attempt; Work itself remains attachable.
            if snapshot.lifecycle == .unknown { snapshot.lifecycle = .active }
            snapshot.execution = .failed
        case TimelineEventType.workDestroyed:
            guard !isTerminalLifecycle, !hasOutstandingWork else {
                quarantine(event, reason: "Work destroyed while actions or Handles remain outstanding")
                return
            }
            snapshot.lifecycle = .destroyed
            snapshot.execution = snapshot.activeActionIDs.isEmpty ? .idle : .running
            snapshot.activeRun = nil
            snapshot.activeTurn = nil
        case TimelineEventType.sessionAttached:
            guard let session = event.session, !session.sessionID.isEmpty,
                  let attachment = event.sessionAttachment, !attachment.attachmentID.isEmpty else {
                quarantine(event, reason: "Work session attachment is malformed")
                return
            }
            if let existing = snapshot.sessionAttachments[attachment.attachmentID],
               existing.session != session {
                quarantine(event, reason: "Work session attachment identity was reused by another Session")
                return
            }
            snapshot.attachedSessionIDs.insert(session.sessionID)
            snapshot.sessionAttachments[attachment.attachmentID] = WorkSessionAttachmentSnapshot(
                attachment: attachment, session: session,
                capabilities: Set(event.payload["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        case TimelineEventType.sessionDetached:
            guard let attachment = event.sessionAttachment,
                  var state = snapshot.sessionAttachments[attachment.attachmentID] else {
                quarantine(event, reason: "Work session detach references unknown attachment")
                return
            }
            state.isAttached = false
            snapshot.sessionAttachments[attachment.attachmentID] = state
            if !snapshot.sessionAttachments.values.contains(where: {
                $0.isAttached && $0.session == state.session
            }) {
                snapshot.attachedSessionIDs.remove(state.session.sessionID)
            }
        case TimelineEventType.sessionAttachmentCapabilityChanged:
            guard let attachment = event.sessionAttachment,
                  var state = snapshot.sessionAttachments[attachment.attachmentID],
                  let capabilities = event.payload["capabilities"]?.arrayValue?.compactMap(\.stringValue)
            else {
                quarantine(event, reason: "Work attachment capability change is malformed")
                return
            }
            state.capabilities = Set(capabilities)
            snapshot.sessionAttachments[attachment.attachmentID] = state
        case TimelineEventType.runStarted:
            guard !isTerminalLifecycle, snapshot.activeRun == nil,
                  let run = event.run, !run.runID.isEmpty,
                  !snapshot.observedRunIDs.contains(run.runID) else {
                quarantine(
                    event,
                    reason: "run cannot start without a fresh identity, while another Run is active, or on terminal Work")
                return
            }
            snapshot.activeRun = run
            snapshot.observedRunIDs.insert(run.runID)
            snapshot.modelID = event.payload["model_id"]?.stringValue
                ?? event.payload["model"]?.stringValue
            snapshot.execution = .running
            if snapshot.lifecycle == .unknown { snapshot.lifecycle = .active }
        case TimelineEventType.runFinished:
            // The active Run is the thing this event is finishing. Requiring
            // `activeRun == nil` here made every run.finished event self-contradictory;
            // only actions, a turn, or live Handles must be quiescent first.
            guard let run = event.run, run == snapshot.activeRun, !hasOutstandingRunWork else {
                quarantine(
                    event,
                    reason: "run finish does not match the active Run or Work remains outstanding")
                return
            }
            snapshot.activeRun = nil
            snapshot.execution = executionAfterRun(event.payload)
        case TimelineEventType.modelChanged:
            guard let model = event.payload["model_id"]?.stringValue
                    ?? event.payload["model"]?.stringValue,
                  !model.isEmpty else {
                quarantine(event, reason: "model change is missing model identity")
                return
            }
            snapshot.modelID = model
        case TimelineEventType.turnStarted:
            guard let run = event.run, run == snapshot.activeRun,
                  let turn = event.turn,
                  !turn.turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  snapshot.activeTurn == nil else {
                quarantine(event, reason: "turn start requires the active Run, a non-empty identity, and no active turn")
                return
            }
            snapshot.activeTurn = turn
            snapshot.execution = .running
        case TimelineEventType.turnFinished:
            guard let run = event.run, run == snapshot.activeRun,
                  let turn = event.turn,
                  !turn.turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  turn == snapshot.activeTurn else {
                quarantine(event, reason: "turn finish must match the active Run and active turn")
                return
            }
            snapshot.activeTurn = nil
            if snapshot.activeActionIDs.isEmpty { snapshot.execution = .idle }
        case TimelineEventType.actionStarted:
            guard let action = event.action, !action.actionID.isEmpty,
                  let existing = snapshot.actions[action.actionID],
                  existing.state == .proposed,
                  validActionEventPayload(event),
                  event.payload["kind"] == nil || actionKind(in: event) == existing.kind,
                  let state = event.payload["state"]?.stringValue.flatMap(ActionExecutionState.init(rawValue:)),
                  state == .queued || state == .running
            else {
                quarantine(event, reason: "action start requires a prior action intent")
                return
            }
            snapshot.actions[action.actionID] = existing.withStarted(event, state: state)
            snapshot.activeActionIDs.insert(action.actionID)
            snapshot.execution = .running
        case TimelineEventType.actionIntent:
            guard let action = event.action, !action.actionID.isEmpty,
                  snapshot.actions[action.actionID] == nil,
                  validActionEventPayload(event),
                  actionKind(in: event) != nil,
                  let intent = event.payload["intent"]?.stringValue,
                  !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  event.payload["state"]?.stringValue.flatMap(ActionExecutionState.init(rawValue:)) == .proposed
            else {
                quarantine(event, reason: "action intent is malformed or duplicated")
                return
            }
            guard let projected = WorkActionSnapshot(intent: event) else {
                quarantine(event, reason: "action intent is missing a known kind or identity")
                return
            }
            snapshot.actions[action.actionID] = projected
        case TimelineEventType.actionOutcome:
            applyActionOutcome(event)
        case TimelineEventType.handleStarted:
            guard let run = event.run, run == snapshot.activeRun,
                  let handle = event.handle,
                  !handle.handleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  snapshot.handles[handle.handleID] == nil else {
                quarantine(event, reason: "Handle start requires the active Run, a fresh non-empty identity, and no existing Handle")
                return
            }
            guard let state = event.payload["state"]?.stringValue,
                  !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                quarantine(event, reason: "Handle start is missing state")
                return
            }
            snapshot.handles[handle.handleID] = WorkHandleSnapshot(handle: handle, state: state)
        case TimelineEventType.handleOutcome:
            guard let run = event.run, run == snapshot.activeRun,
                  let handle = event.handle,
                  !handle.handleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let existing = snapshot.handles[handle.handleID],
                  !isTerminalHandleState(existing.state) else {
                quarantine(event, reason: "Handle outcome requires the active Run and an outstanding Handle")
                return
            }
            guard let state = event.payload["state"]?.stringValue,
                  !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                quarantine(event, reason: "Handle outcome is missing state")
                return
            }
            snapshot.handles[handle.handleID] = WorkHandleSnapshot(handle: handle, state: state)
        case TimelineEventType.recoveryCoverage:
            guard let coverage = decodeRecoveryCoverage(event.payload),
                  let session = event.session, !session.sessionID.isEmpty,
                  let attachment = event.sessionAttachment, !attachment.attachmentID.isEmpty,
                  let sessionState = snapshot.sessionAttachments[attachment.attachmentID],
                  sessionState.session == session, sessionState.isAttached,
                  let work = event.work, work == snapshot.work,
                  let workJournal: JournalRef = event.payload["work_journal"].flatMap({ decodeTimelineValue($0) }),
                  workJournal.owner == .work(work),
                  workJournal.authority.authorityID == work.workHostID,
                  workJournal == snapshot.journal,
                  let workHost = event.workHost, workHost.workHostID == work.workHostID,
                  let run = event.run, run == snapshot.activeRun else {
                quarantine(event, reason: "Work recovery coverage has an invalid identity envelope")
                return
            }
            snapshot.recovery.append(coverage)
            snapshot.recordedRecovery.append(RecordedRecoveryCoverage(
                coverage: coverage,
                sourceEvent: EventRef(journal: event.journal, eventID: event.eventID),
                session: session, work: work, workJournal: workJournal, workHost: workHost,
                sessionAttachment: attachment, run: run))
        case TimelineEventType.childLifecycle:
            guard let childID = event.payload["child_id"]?.stringValue,
                  let state = event.payload["state"]?.stringValue,
                  !childID.isEmpty, !state.isEmpty else {
                quarantine(event, reason: "child lifecycle is missing child identity or state")
                return
            }
            snapshot.childStates[childID] = state
        case TimelineEventType.commandAccepted, TimelineEventType.commandRejected,
             TimelineEventType.commandDelivered, TimelineEventType.commandNotDelivered,
             TimelineEventType.commandDeliveryIndeterminate:
            guard let command = event.command, let state = commandState(for: event.type),
                  !command.commandID.isEmpty,
                  command.client.map({ !$0.clientID.isEmpty }) ?? true,
                  command.sessionAttachment.map({ !$0.attachmentID.isEmpty }) ?? true,
                  let hostSequence = event.hostSequence,
                  command.client == event.client,
                  command.sessionAttachment == event.sessionAttachment,
                  command.causalCursor != nil,
                  validCausalCursor(command.causalCursor, receiptSequence: event.sequence) else {
                quarantine(event, reason: "command delivery event is missing command identity")
                return
            }
            if state == .accepted || state == .rejected {
                // Admission receipts describe the exact Work state observed by the caller.
                // A cursor without an event identity is deliberately represented by no cause;
                // once it has an identity, the event reference must retain its journal too.
                guard event.causedByEventID == causalEventRef(for: command) else {
                    quarantine(event, reason: "command admission cause does not match its cursor")
                    return
                }
            }
            if let existing = snapshot.commands[command.commandID] {
                guard existing.command == command else {
                    quarantine(event, reason: "command id conflicts across clients or attachments")
                    return
                }
                if state == .delivered || state == .notDelivered || state == .indeterminate {
                    // Delivery is only meaningful as a receipt for this command's durable
                    // acceptance event. The event ref is retained in the snapshot so this
                    // remains enforceable when reduction resumes from an earlier prefix.
                    guard existing.state == .accepted,
                          event.causedByEventID == existing.acceptanceEventRef else {
                        quarantine(event, reason: "command delivery cause does not match acceptance")
                        return
                    }
                }
                if existing.state == state {
                    let sameProvenance: Bool
                    switch state {
                    case .accepted, .rejected:
                        sameProvenance = existing.acceptanceActor == event.actor
                            && existing.acceptanceIdempotencyKey == event.idempotencyKey
                    case .delivered, .notDelivered, .indeterminate:
                        sameProvenance = existing.deliveryActor == event.actor
                            && existing.deliveryIdempotencyKey == event.idempotencyKey
                    }
                    guard sameProvenance else {
                        quarantine(event, reason: "duplicate command receipt provenance conflicts")
                        return
                    }
                    // Idempotent duplicate: retain the first receipt and its provenance.
                    return
                }
                guard existing.state == .accepted,
                      state == .delivered || state == .notDelivered || state == .indeterminate
                else {
                    quarantine(event, reason: "illegal command receipt transition")
                    return
                }
                snapshot.commands[command.commandID] = WorkCommandSnapshot(
                    command: existing.command, state: state,
                    acceptanceActor: existing.acceptanceActor,
                    acceptanceHostSequence: existing.acceptanceHostSequence,
                    acceptanceIdempotencyKey: existing.acceptanceIdempotencyKey,
                    acceptanceEventRef: existing.acceptanceEventRef,
                    deliveryEventRef: EventRef(journal: event.journal, eventID: event.eventID),
                    deliveryActor: event.actor, deliveryHostSequence: hostSequence,
                    deliveryIdempotencyKey: event.idempotencyKey)
                return
            } else if state == .delivered || state == .notDelivered || state == .indeterminate {
                quarantine(event, reason: "command delivery outcome appeared before acceptance")
                return
            }
            snapshot.commands[command.commandID] = WorkCommandSnapshot(
                command: command, state: state, actor: event.actor,
                hostSequence: hostSequence, idempotencyKey: event.idempotencyKey,
                acceptanceEventRef: EventRef(journal: event.journal, eventID: event.eventID))
        case TimelineEventType.hostOrderObserved:
            break
        default:
            recordUnknown(event)
        }
    }

    private mutating func accept(_ event: TimelineEvent) -> Bool {
        guard snapshot.structuralIntegrityValid else {
            snapshot.quarantinedEvents.append(event)
            return false
        }
        guard !snapshot.seenEventIDs.contains(event.eventID) else {
            quarantine(event, reason: "duplicate event \(event.eventID)", structural: true)
            return false
        }
        guard acceptsJournal(event.journal) else {
            quarantine(event, reason: "event belongs to another journal", structural: true)
            return false
        }
        if snapshot.journal == nil { snapshot.journal = event.journal }
        if snapshot.work == nil, case .work(let work) = event.journal.owner {
            snapshot.work = work
            snapshot.workHost = WorkHostRef(work.workHostID)
        }
        if let work = event.work, work != snapshot.work {
            quarantine(event, reason: "event Work identity does not match journal", structural: true)
            return false
        }
        if let host = event.workHost, host.workHostID != snapshot.work?.workHostID {
            quarantine(event, reason: "event Work Host identity does not match journal", structural: true)
            return false
        }
        if let previous = snapshot.lastEventID, event.previousEventID != previous {
            quarantine(event, reason: "previous event mismatch", structural: true)
            return false
        } else if snapshot.lastEventID == nil, event.previousEventID != nil {
            quarantine(event, reason: "non-empty previous event at journal start", structural: true)
            return false
        }
        if event.sequence != snapshot.lastSequence + 1 {
            quarantine(event, reason: "sequence gap or non-increasing sequence", structural: true)
            return false
        }
        if let hostSequence = event.hostSequence,
           let previousHostSequence = snapshot.lastHostSequence,
           hostSequence <= previousHostSequence {
            quarantine(event, reason: "non-increasing host order", structural: true)
            return false
        }
        snapshot.seenEventIDs.insert(event.eventID)
        snapshot.eventSequences[event.eventID] = event.sequence
        snapshot.lastEventID = event.eventID
        snapshot.lastSequence = max(snapshot.lastSequence, event.sequence)
        if let hostSequence = event.hostSequence { snapshot.lastHostSequence = hostSequence }
        return true
    }

    private func acceptsJournal(_ journal: JournalRef) -> Bool {
        guard case .work = journal.owner else { return false }
        return snapshot.journal == nil || snapshot.journal == journal
    }

    private mutating func recordUnknown(_ event: TimelineEvent) {
        let domains = event.declaredDomains.isEmpty
            ? Set(TimelineDomain.allCases)
            : event.declaredDomains
        snapshot.unknownEvents.append(UnknownTimelineEvent(
            event: event, journalOffset: snapshot.seenEventIDs.count - 1,
            affectedDomains: domains))
        snapshot.unknownDomains.formUnion(domains)
    }

    private mutating func quarantine(_ event: TimelineEvent, reason: String, structural: Bool = false) {
        if structural {
            snapshot.causalOrderValid = false
            snapshot.structuralIntegrityValid = false
        } else {
            snapshot.semanticProjectionValid = false
        }
        snapshot.corruptionReasons.append(reason)
        snapshot.quarantinedEvents.append(event)
    }

    private mutating func applyActionOutcome(_ event: TimelineEvent) {
        guard let action = event.action, !action.actionID.isEmpty,
              let existing = snapshot.actions[action.actionID],
              validActionEventPayload(event),
              event.payload["kind"] == nil || actionKind(in: event) == existing.kind,
              let state = event.payload["state"]?.stringValue.flatMap(ActionExecutionState.init(rawValue:)),
              legalActionTransition(from: existing.state, to: state)
        else {
            quarantine(event, reason: "action outcome has no intent or illegal state transition")
            return
        }
        let failureKind = event.payload["failure_kind"]?.stringValue
            .flatMap(ActionFailureKind.init(rawValue:))
        let retrySafety = event.payload["retry_safety"]?.stringValue
            .flatMap(ActionRetrySafety.init(rawValue:))
        if event.payload["failure_kind"] != nil && failureKind == nil {
            quarantine(event, reason: "action outcome has unknown failure kind")
            return
        }
        if event.payload["retry_safety"] != nil && retrySafety == nil {
            quarantine(event, reason: "action outcome has unknown retry safety")
            return
        }
        guard !state.isTerminal || retrySafety != nil else {
            quarantine(event, reason: "terminal action outcome must declare retry safety")
            return
        }
        if [.failed, .canceled, .indeterminateEffect].contains(state), failureKind == nil {
            quarantine(event, reason: "failed, canceled, or indeterminate action must declare failure kind")
            return
        }
        snapshot.actions[action.actionID] = existing.withOutcome(
            event, state: state, failureKind: failureKind, retrySafety: retrySafety)
        if state.isTerminal {
            snapshot.activeActionIDs.remove(action.actionID)
            if snapshot.activeActionIDs.isEmpty, snapshot.activeTurn == nil {
                snapshot.execution = state == .failed || state == .indeterminateEffect
                    ? .failed : .idle
            }
        } else {
            snapshot.activeActionIDs.insert(action.actionID)
            snapshot.execution = state == .cancelRequested ? .canceling : .running
        }
    }

    private func legalActionTransition(from: ActionExecutionState, to: ActionExecutionState) -> Bool {
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
    private func validActionEventPayload(_ event: TimelineEvent) -> Bool {
        if event.payload["kind"] != nil && actionKind(in: event) == nil { return false }
        for key in ["intent", "target", "scope"] where event.payload[key] != nil {
            guard event.payload[key]?.stringValue != nil else { return false }
        }
        if event.payload["metadata"] != nil && event.payload["metadata"]?.objectValue == nil {
            return false
        }
        if let run = event.run, run != snapshot.activeRun { return false }
        if let turn = event.turn {
            guard event.run == snapshot.activeRun, turn == snapshot.activeTurn else { return false }
        }
        return true
    }

    private func actionKind(in event: TimelineEvent) -> ActionKind? {
        event.payload["kind"]?.stringValue.flatMap(ActionKind.init(rawValue:))
    }

    private func executionAfterRun(_ payload: JSONValue) -> WorkExecution {
        switch payload["state"]?.stringValue {
        case "failed": return .failed
        case "preparing": return .preparing
        case "canceling", "cancel_requested": return .canceling
        case "held": return .held
        default: return .idle
        }
    }

    private var hasOutstandingWork: Bool {
        if snapshot.activeRun != nil || snapshot.activeTurn != nil || !snapshot.activeActionIDs.isEmpty { return true }
        return snapshot.handles.values.contains { !isTerminalHandleState($0.state) }
    }

    private var hasOutstandingRunWork: Bool {
        if snapshot.activeTurn != nil || !snapshot.activeActionIDs.isEmpty { return true }
        return snapshot.handles.values.contains { !isTerminalHandleState($0.state) }
    }

    private func isTerminalHandleState(_ state: String) -> Bool {
        ["succeeded", "failed", "canceled", "completed"].contains(state)
    }

    private var isTerminalLifecycle: Bool {
        snapshot.lifecycle == .completed || snapshot.lifecycle == .destroyed
    }

    private func isExecutionMutation(_ type: String) -> Bool {
        [TimelineEventType.runStarted, TimelineEventType.runFinished,
         TimelineEventType.turnStarted, TimelineEventType.turnFinished,
         TimelineEventType.actionIntent, TimelineEventType.actionStarted,
         TimelineEventType.actionOutcome, TimelineEventType.handleStarted,
         TimelineEventType.handleOutcome].contains(type)
    }

    private func commandState(for type: String) -> CommandDeliveryState? {
        switch type {
        case TimelineEventType.commandAccepted: return .accepted
        case TimelineEventType.commandRejected: return .rejected
        case TimelineEventType.commandDelivered: return .delivered
        case TimelineEventType.commandNotDelivered: return .notDelivered
        case TimelineEventType.commandDeliveryIndeterminate: return .indeterminate
        default: return nil
        }
    }

    private func causalEventRef(for command: CommandRef) -> EventRef? {
        guard let cursor = command.causalCursor, let eventID = cursor.eventID else { return nil }
        return EventRef(journal: cursor.journal, eventID: eventID)
    }

    private func validCausalCursor(_ cursor: JournalCursor?, receiptSequence: Int) -> Bool {
        guard let cursor else { return true }
        // A command describes the state observed before its receipt. It cannot point at another
        // Work journal or at this/future receipt in the same journal.
        guard cursor.journal == snapshot.journal, cursor.sequence < receiptSequence else { return false }
        guard let eventID = cursor.eventID else { return true }
        return snapshot.eventSequences[eventID] == cursor.sequence
    }

}

/// Pure projection of a Session journal. Work identity and attachment state are kept separate
/// from the visible conversation so a session can continue, detach, or archive independently.
public struct SessionReducer: Sendable {
    public private(set) var snapshot: SessionSnapshot

    // This is deliberately reducer-local instrumentation rather than persisted projection
    // state.  It makes the cost of an explicit branch rebuild observable in scale tests without
    // changing the SessionSnapshot contract or its Codable/Hashable representation.
    internal private(set) var visibleProjectionRebuildCount: Int = 0
    internal private(set) var visibleProjectionMessagesScanned: Int = 0
    internal private(set) var visibleProjectionFastPathCount: Int = 0

    // Message identity and conversation validity are indexed as events arrive.  A tip-selection
    // event is common in the native producer path, so rebuilding a dictionary and walking the
    // entire ancestry for every tip would make an ordinary linear conversation quadratic.
    private var messageByID: [String: SessionMessageSnapshot]
    private var conversationValidityByMessageID: [String: Bool]

    public init(snapshot: SessionSnapshot = SessionSnapshot()) {
        self.snapshot = snapshot
        var indexedMessages: [String: SessionMessageSnapshot] = [:]
        var indexedValidity: [String: Bool] = [:]
        for message in snapshot.messageHistory {
            indexedMessages[message.eventID] = message
            let valid: Bool
            if let parent = message.conversationParent {
                valid = parent.journal == snapshot.journal
                    && indexedMessages[parent.eventID] != nil
                    && indexedValidity[parent.eventID] == true
            } else {
                valid = true
            }
            indexedValidity[message.eventID] = valid
        }
        self.messageByID = indexedMessages
        self.conversationValidityByMessageID = indexedValidity
    }

    public static func reduce<S: Sequence>(
        _ events: S, initial: SessionSnapshot = SessionSnapshot()
    ) -> SessionSnapshot where S.Element == TimelineEvent {
        var reducer = SessionReducer(snapshot: initial)
        for event in events { reducer.apply(event) }
        return reducer.snapshot
    }

    public mutating func apply(_ event: TimelineEvent) {
        guard accept(event) else { return }
        guard event.isKnownType,
              event.schemaVersion <= TimelineEvent.currentSchemaVersion,
              event.payloadVersion <= 1
        else {
            recordUnknown(event)
            return
        }
        if let session = event.session { snapshot.session = session }

        switch event.type {
        case TimelineEventType.sessionCreated:
            snapshot.lifecycle = .active
        case TimelineEventType.sessionAttached:
            guard let work = event.work, !work.workHostID.isEmpty, !work.workID.isEmpty,
                  let attachment = event.sessionAttachment, !attachment.attachmentID.isEmpty else {
                quarantine(event, reason: "session attachment missing Work or attachment identity")
                return
            }
            if let existing = snapshot.attachments[attachment.attachmentID],
               existing.work != work {
                quarantine(event, reason: "Session attachment identity was reused by another Work")
                return
            }
            snapshot.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
                attachment: attachment, work: work,
                capabilities: Set(event.payload["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? []))
            snapshot.lifecycle = .active
        case TimelineEventType.sessionDetached:
            guard let attachment = event.sessionAttachment,
                  var state = snapshot.attachments[attachment.attachmentID] else {
                quarantine(event, reason: "session detach references unknown attachment")
                return
            }
            state.isAttached = false
            snapshot.attachments[attachment.attachmentID] = state
        case TimelineEventType.sessionAttachmentCapabilityChanged:
            guard let attachment = event.sessionAttachment,
                  var state = snapshot.attachments[attachment.attachmentID],
                  let capabilities = event.payload["capabilities"]?.arrayValue?.compactMap(\.stringValue)
            else {
                quarantine(event, reason: "attachment capability change is malformed")
                return
            }
            state.capabilities = Set(capabilities)
            snapshot.attachments[attachment.attachmentID] = state
        case TimelineEventType.sessionAttachmentCursorAdvanced:
            guard let attachment = event.sessionAttachment,
                  var state = snapshot.attachments[attachment.attachmentID],
                  let cursor: JournalCursor = event.payload["cursor"].flatMap({ decodeTimelineValue($0) }),
                  cursor.journal.owner == .work(state.work)
            else {
                quarantine(event, reason: "attachment cursor is malformed or for another Work")
                return
            }
            state.cursor = cursor
            snapshot.attachments[attachment.attachmentID] = state
        case TimelineEventType.inputAccepted:
            appendMessage(event, role: "user")
        case TimelineEventType.messageCommitted:
            appendMessage(event, role: event.payload["role"]?.stringValue ?? "assistant")
        case TimelineEventType.recoveryCoverage:
            guard let coverage = decodeRecoveryCoverage(event.payload),
                  let session = event.session, session == snapshot.session,
                  let attachment = event.sessionAttachment, !attachment.attachmentID.isEmpty,
                  let work = event.work,
                  let workJournal: JournalRef = event.payload["work_journal"].flatMap({ decodeTimelineValue($0) }),
                  workJournal.owner == .work(work),
                  workJournal.authority.authorityID == work.workHostID,
                  let attachmentState = snapshot.attachments[attachment.attachmentID],
                  attachmentState.work == work, attachmentState.isAttached,
                  let workHost = event.workHost, workHost.workHostID == work.workHostID,
                  let run = event.run, !run.runID.isEmpty else {
                quarantine(event, reason: "Session recovery coverage has an invalid identity envelope")
                return
            }
            snapshot.recovery.append(coverage)
            snapshot.recordedRecovery.append(RecordedRecoveryCoverage(
                coverage: coverage,
                sourceEvent: EventRef(journal: event.journal, eventID: event.eventID),
                session: session, work: work, workJournal: workJournal, workHost: workHost,
                sessionAttachment: attachment, run: run))
        case TimelineEventType.childLifecycle:
            guard let childID = event.payload["child_id"]?.stringValue,
                  let state = event.payload["state"]?.stringValue,
                  !childID.isEmpty, !state.isEmpty else {
                quarantine(event, reason: "child lifecycle is missing child identity or state")
                return
            }
            snapshot.childStates[childID] = state
        case TimelineEventType.contextSourcesObserved:
            guard let assemblyID = event.payload["assembly_id"]?.stringValue,
                  let sources = decodeContextSources(event.payload),
                  let observationSession = event.session,
                  let observationWork = event.work,
                  let observationWorkHost = event.workHost,
                  let observationRun = event.run,
                  observationSession == snapshot.session,
                  observationWork.workHostID == observationWorkHost.workHostID,
                  !observationWork.workID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !observationWork.workHostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !observationRun.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !assemblyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                quarantine(event, reason: "context source observation is malformed")
                return
            }
            let probe = ContextManifest(
                manifestID: "source-observation", requestID: "source-observation",
                modelID: "source-observation", components: [ContextComponent(
                    componentID: "source-observation", inclusionID: "source-observation",
                    sourceID: "source-observation", mode: .instruction, measuredBytes: 0,
                    includedBytes: 0, deliveredBytes: 0, fullByteCount: 0,
                    digest: "sha256:" + String(repeating: "0", count: 64))],
                systemPromptAssemblyID: assemblyID, systemPromptSources: sources)
            do {
                try probe.validatePromptSources(authority: event.journal)
            } catch {
                quarantine(event, reason: "context source observation failed validation")
                return
            }
            snapshot.contextPromptAssemblyID = assemblyID
            snapshot.contextPromptSources = sources
            snapshot.contextSourcesObservationEventID = event.eventID
            snapshot.contextSourcesObservationSession = observationSession
            snapshot.contextSourcesObservationWork = observationWork
            snapshot.contextSourcesObservationWorkHost = observationWorkHost
            snapshot.contextSourcesObservationRun = observationRun
        case TimelineEventType.contextAssembled:
            guard let components = decodeContextComponents(event.payload) else {
                quarantine(event, reason: "context component manifest is malformed")
                return
            }
            let contextManifest = decodeContextManifest(event.payload, components: components)
            if event.payload["manifest_id"] != nil && contextManifest == nil {
                quarantine(event, reason: "context crossing metadata is malformed")
                return
            }
            if let contextManifest {
                guard let run = event.run,
                      let work = event.work,
                      let workHost = event.workHost,
                      work.workHostID == workHost.workHostID,
                      !run.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !work.workID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !work.workHostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !workHost.workHostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    quarantine(
                        event,
                        reason: "context crossing is missing or mismatches Work, Work Host, or Run identity")
                    return
                }
                if let sources = contextManifest.systemPromptSources {
                    guard let assemblyID = contextManifest.systemPromptAssemblyID,
                          let observedAssemblyID = snapshot.contextPromptAssemblyID,
                          let observedSources = snapshot.contextPromptSources,
                          let observationEventID = snapshot.contextSourcesObservationEventID,
                          let causedBy = event.causedByEventID,
                          assemblyID == observedAssemblyID,
                          causedBy.journal == event.journal,
                          causedBy.eventID == observationEventID,
                          event.previousEventID == observationEventID,
                          snapshot.contextSourcesObservationSession == event.session,
                          snapshot.contextSourcesObservationWork == event.work,
                          snapshot.contextSourcesObservationWorkHost == event.workHost,
                          snapshot.contextSourcesObservationRun == event.run,
                          sources.allSatisfy({ $0.provenance == causedBy }),
                          sources.map({ $0.withProvenance(nil) }) == observedSources.map({
                              $0.withProvenance(nil)
                          }) else {
                        quarantine(
                            event,
                            reason: "context crossing does not match its immediately preceding source observation")
                        return
                    }
                }
                do {
                    try contextManifest.validate(
                        authority: event.journal,
                        previousCumulativeDeliveredBytes:
                            snapshot.contextCumulativeDeliveredBytesByRun?[run.runID],
                        requireRetainedBodies: true)
                } catch {
                    quarantine(
                        event,
                        reason: "context crossing failed canonical validation: \(error.localizedDescription)")
                    return
                }
                var totals = snapshot.contextCumulativeDeliveredBytesByRun ?? [:]
                totals[run.runID] = contextManifest.cumulativeDeliveredBytes
                snapshot.contextCumulativeDeliveredBytesByRun = totals
            }
            snapshot.contextComponents = components
            snapshot.contextManifest = contextManifest
            snapshot.contextPromptAssemblyID = contextManifest?.systemPromptAssemblyID
            snapshot.contextPromptSources = contextManifest?.systemPromptSources
            snapshot.contextSourcesObservationEventID = contextManifest?.systemPromptSources == nil
                ? nil : event.causedByEventID?.eventID
            if contextManifest?.systemPromptSources == nil {
                snapshot.contextSourcesObservationSession = nil
                snapshot.contextSourcesObservationWork = nil
                snapshot.contextSourcesObservationWorkHost = nil
                snapshot.contextSourcesObservationRun = nil
            }
            snapshot.contextBoundaryEventID = event.eventID
        case TimelineEventType.compaction:
            guard let summary = event.payload["summary"]?.stringValue,
                  !summary.isEmpty else {
                quarantine(event, reason: "context compaction is missing summary")
                return
            }
            snapshot.compactionSummary = summary
            snapshot.compactionBoundaryEventID = event.eventID
        case TimelineEventType.modelChanged:
            guard let model = event.payload["model_id"]?.stringValue
                    ?? event.payload["model"]?.stringValue,
                  !model.isEmpty else {
                quarantine(event, reason: "model change is missing model identity")
                return
            }
            snapshot.modelID = model
        case TimelineEventType.sessionAttention:
            guard let raw = event.payload["attention"]?.stringValue,
                  let attention = SessionAttention(rawValue: raw) else {
                // A malformed attention event cannot mean `.none`: quarantine it and retain
                // the prior known state so notification delivery never invents a clearing edge.
                recordUnknown(event)
                quarantine(event, reason: "session attention payload is missing or invalid")
                return
            }
            snapshot.attention = attention
            snapshot.attentionEvent = EventRef(journal: event.journal, eventID: event.eventID)
        case TimelineEventType.sessionCompleted:
            snapshot.lifecycle = .completed
            snapshot.execution = .idle
        case TimelineEventType.sessionArchived:
            snapshot.lifecycle = .archived
            snapshot.attention = .none
            snapshot.attentionEvent = EventRef(journal: event.journal, eventID: event.eventID)
        case TimelineEventType.sessionTipSelected:
            guard let tip = event.conversationParent, validateConversationTip(tip) else {
                quarantine(event, reason: "semantic tip is not a known acyclic Session node")
                return
            }
            let previousTip = snapshot.semanticTip
            snapshot.semanticTip = tip
            rebuildVisibleMessages(from: previousTip)
        default:
            recordUnknown(event)
        }
    }

    private mutating func accept(_ event: TimelineEvent) -> Bool {
        guard snapshot.structuralIntegrityValid else {
            snapshot.quarantinedEvents.append(event)
            return false
        }
        guard !snapshot.seenEventIDs.contains(event.eventID) else {
            quarantine(event, reason: "duplicate event \(event.eventID)", structural: true)
            return false
        }
        guard acceptsJournal(event.journal) else {
            quarantine(event, reason: "event belongs to another journal", structural: true)
            return false
        }
        if snapshot.journal == nil { snapshot.journal = event.journal }
        if snapshot.session == nil, case .session(let session) = event.journal.owner {
            snapshot.session = session
        }
        if let session = event.session, session != snapshot.session {
            quarantine(event, reason: "event Session identity does not match journal", structural: true)
            return false
        }
        if let previous = snapshot.lastEventID, event.previousEventID != previous {
            quarantine(event, reason: "previous event mismatch", structural: true)
            return false
        } else if snapshot.lastEventID == nil, event.previousEventID != nil {
            quarantine(event, reason: "non-empty previous event at journal start", structural: true)
            return false
        }
        if event.sequence != snapshot.lastSequence + 1 {
            quarantine(event, reason: "sequence gap or non-increasing sequence", structural: true)
            return false
        }
        snapshot.seenEventIDs.insert(event.eventID)
        snapshot.lastEventID = event.eventID
        snapshot.lastSequence = max(snapshot.lastSequence, event.sequence)
        return true
    }

    private func acceptsJournal(_ journal: JournalRef) -> Bool {
        guard case .session = journal.owner else { return false }
        return snapshot.journal == nil || snapshot.journal == journal
    }

    private mutating func recordUnknown(_ event: TimelineEvent) {
        let domains = event.declaredDomains.isEmpty
            ? Set(TimelineDomain.allCases)
            : event.declaredDomains
        snapshot.unknownEvents.append(UnknownTimelineEvent(
            event: event, journalOffset: snapshot.seenEventIDs.count - 1,
            affectedDomains: domains))
        snapshot.unknownDomains.formUnion(domains)
    }

    private mutating func quarantine(_ event: TimelineEvent, reason: String, structural: Bool = false) {
        if structural {
            snapshot.causalOrderValid = false
            snapshot.structuralIntegrityValid = false
        } else {
            snapshot.semanticProjectionValid = false
        }
        snapshot.corruptionReasons.append(reason)
        snapshot.quarantinedEvents.append(event)
    }

    private mutating func appendMessage(_ event: TimelineEvent, role: String) {
        guard let text = event.payload["text"]?.stringValue else {
            quarantine(event, reason: "message is missing text")
            return
        }
        let parent = event.conversationParent
            ?? event.payload["conversation_parent"].flatMap { decodeTimelineValue($0) }
        if event.payload["conversation_parent"] != nil && parent == nil {
            quarantine(event, reason: "message conversation parent is malformed")
            return
        }
        let message = SessionMessageSnapshot(eventID: event.eventID, role: role, text: text,
                                             conversationParent: parent,
                                             sourceEvent: EventRef(journal: event.journal, eventID: event.eventID),
                                             hostRecordedAt: event.hostRecordedAt,
                                             clientTimestamp: event.clientTimestamp,
                                             run: event.run, turn: event.turn, actor: event.actor,
                                             causedBy: event.causedByEventID,
                                             parentActivity: event.parentActivityID,
                                             provenance: event.provenance, links: event.links)
        snapshot.messageHistory.append(message)
        messageByID[message.eventID] = message
        if let parent = message.conversationParent {
            conversationValidityByMessageID[message.eventID] =
                parent.journal == snapshot.journal
                && messageByID[parent.eventID] != nil
                && conversationValidityByMessageID[parent.eventID] == true
        } else {
            conversationValidityByMessageID[message.eventID] = true
        }
        // With no explicit semantic tip, journal order is the presentation order.  Appending
        // the new visible row is both exact and constant-time; filtering the complete history
        // here made a long ordinary conversation quadratic.  Once a tip is selected, the
        // selected branch is authoritative until another tip-selection event explicitly asks
        // us to validate and rebuild it, so later messages must not perturb that projection.
        if snapshot.semanticTip == nil, isPresentationVisible(message) {
            snapshot.messages.append(message)
        }
    }

    private mutating func rebuildVisibleMessages(from previousTip: EventRef?) {
        if let previousTip, let extensionMessages = selectedBranchExtension(
            from: previousTip, to: snapshot.semanticTip) {
            if !extensionMessages.isEmpty {
                snapshot.messages.append(contentsOf: extensionMessages.filter(isPresentationVisible))
            }
            visibleProjectionFastPathCount += 1
            return
        }
        visibleProjectionRebuildCount += 1
        visibleProjectionMessagesScanned += snapshot.messageHistory.count
        guard let tip = snapshot.semanticTip else {
            snapshot.messages = snapshot.messageHistory.filter(isPresentationVisible)
            return
        }
        var current: EventRef? = tip
        var visible: [SessionMessageSnapshot] = []
        var visited: Set<String> = []
        while let ref = current, visited.insert(ref.eventID).inserted {
            guard let message = messageByID[ref.eventID] else { break }
            if isPresentationVisible(message) { visible.append(message) }
            current = message.conversationParent
        }
        snapshot.messages = visible.reversed()
    }

    /// A tool-only assistant event is part of the model-visible conversation chain and must
    /// remain in `messageHistory`, but it has no human-visible text row. The legacy renderer
    /// already presents its tool call/result separately; filtering only the visible projection
    /// keeps native/legacy chat parity without discarding recovery provenance.
    private func isPresentationVisible(_ message: SessionMessageSnapshot) -> Bool {
        message.role != ChatRole.assistant.rawValue || !message.text.isEmpty
    }

    private func validateConversationTip(_ tip: EventRef) -> Bool {
        tip.journal == snapshot.journal
            && snapshot.seenEventIDs.contains(tip.eventID)
            && messageByID[tip.eventID] != nil
            && conversationValidityByMessageID[tip.eventID] == true
    }

    /// Returns the messages newly selected when `to` extends the previously selected tip.  The
    /// walk is proportional only to the extension, and a failed walk falls back to the full
    /// branch rebuild for arbitrary branch switches.
    private func selectedBranchExtension(
        from previousTip: EventRef, to newTip: EventRef?
    ) -> [SessionMessageSnapshot]? {
        guard let newTip else { return nil }
        if previousTip == newTip { return [] }
        var current: EventRef? = newTip
        var visited: Set<String> = []
        var extensionMessages: [SessionMessageSnapshot] = []
        while let ref = current, ref != previousTip {
            guard ref.journal == snapshot.journal,
                  visited.insert(ref.eventID).inserted,
                  conversationValidityByMessageID[ref.eventID] == true,
                  let message = messageByID[ref.eventID] else {
                return nil
            }
            extensionMessages.append(message)
            current = message.conversationParent
        }
        guard current == previousTip else { return nil }
        return extensionMessages.reversed()
    }

}

private func decodeRecoveryCoverage(_ payload: JSONValue) -> RecoveryCoverage? {
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

private func decodeTimelineValue<T: Decodable>(_ value: JSONValue) -> T? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

private func decodeContextComponents(_ payload: JSONValue) -> [ContextComponent]? {
    guard let values = payload["components"]?.arrayValue else { return nil }
    let decoded = values.compactMap { value -> ContextComponent? in
        guard let component: ContextComponent = decodeTimelineValue(value) else { return nil }
        if [.truncated, .summary, .manifest].contains(component.deliveryMode),
           (component.bodyReference == nil || component.digest == nil || component.fullByteCount == nil) {
            return nil
        }
        if let body = component.bodyReference,
           body.digest != component.digest || body.byteCount != component.fullByteCount {
            return nil
        }
        return component
    }
    return decoded.count == values.count ? decoded : nil
}

private func decodeContextManifest(
    _ payload: JSONValue, components: [ContextComponent]
) -> ContextManifest? {
    guard let manifestID = payload["manifest_id"]?.stringValue,
          let requestID = payload["request_id"]?.stringValue,
          let modelID = payload["model_id"]?.stringValue,
          let measuredBy = payload["measured_by"]?.stringValue,
          let schemaVersion = payload["schema_version"]?.intValue,
          let measuredBytes = payload["measured_bytes"]?.intValue,
          let deliveredBytes = payload["delivered_bytes"]?.intValue,
          let cumulativeDeliveredBytes = payload["cumulative_delivered_bytes"]?.intValue,
          let omissionValues = payload["omissions"]?.arrayValue else { return nil }
    let omissions: [ContextManifestOmission] = omissionValues.compactMap {
        decodeTimelineValue($0)
    }
    guard omissions.count == omissionValues.count else { return nil }
    let sourceValues = payload["system_prompt_sources"]?.arrayValue
    let promptSources: [ContextManifestSource]?
    if let sourceValues {
        let decoded: [ContextManifestSource] = sourceValues.compactMap {
            decodeTimelineValue($0)
        }
        guard decoded.count == sourceValues.count else { return nil }
        promptSources = decoded
    } else {
        promptSources = nil
    }
    let manifest = ContextManifest(
        schemaVersion: schemaVersion, manifestID: manifestID, requestID: requestID,
        modelID: modelID, measuredBy: measuredBy, components: components,
        omissions: omissions, cumulativeDeliveredBytes: cumulativeDeliveredBytes,
        systemPromptAssemblyID: payload["system_prompt_assembly_id"]?.stringValue,
        systemPromptSources: promptSources)
    guard manifest.measuredBytes == measuredBytes,
          manifest.deliveredBytes == deliveredBytes else { return nil }
    return manifest
}

private func decodeContextSources(_ payload: JSONValue) -> [ContextManifestSource]? {
    guard let values = payload["sources"]?.arrayValue,
          let expectedCount = payload["source_count"]?.intValue,
          expectedCount == values.count else { return nil }
    let decoded: [ContextManifestSource] = values.compactMap { decodeTimelineValue($0) }
    return decoded.count == values.count ? decoded : nil
}
