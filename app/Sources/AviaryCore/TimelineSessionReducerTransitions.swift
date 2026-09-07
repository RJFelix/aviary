import Foundation

// MARK: - Session transition state seam

/// The fixed-shape scalar continuation of a Session reduction.
///
/// This is intentionally an in-memory, event-local overlay value. A future persistent adapter
/// must bounded-prefetch the exact slots for one event, apply the transition here, and publish
/// or discard the complete mutation batch under a root-atomic checkpoint. It must not perform
/// fallible storage from the nonthrowing transition function.
internal struct BoundedSessionScalarContinuation: Equatable, Sendable {
    var journal: JournalRef?
    var session: SessionRef?
    var lifecycle: SessionLifecycle
    var execution: WorkExecution
    var attention: SessionAttention
    var attentionEvent: EventRef?
    var activeRun: RunRef?
    var modelID: String?
    var activeTurn: TurnRef?

    var semanticTip: EventRef?

    var unknownDomains: Set<TimelineDomain>
    var lastEventID: String?
    var lastSequence: Int
    var causalOrderValid: Bool
    var structuralIntegrityValid: Bool
    var semanticProjectionValid: Bool

    init(snapshot: SessionSnapshot) {
        journal = snapshot.journal
        session = snapshot.session
        lifecycle = snapshot.lifecycle
        execution = snapshot.execution
        attention = snapshot.attention
        attentionEvent = snapshot.attentionEvent
        activeRun = snapshot.activeRun
        modelID = snapshot.modelID
        activeTurn = snapshot.activeTurn
        semanticTip = snapshot.semanticTip
        unknownDomains = snapshot.unknownDomains
        lastEventID = snapshot.lastEventID
        lastSequence = snapshot.lastSequence
        causalOrderValid = snapshot.causalOrderValid
        structuralIntegrityValid = snapshot.structuralIntegrityValid
        semanticProjectionValid = snapshot.semanticProjectionValid
    }

    func apply(to snapshot: inout SessionSnapshot) {
        snapshot.journal = journal
        snapshot.session = session
        snapshot.lifecycle = lifecycle
        snapshot.execution = execution
        snapshot.attention = attention
        snapshot.attentionEvent = attentionEvent
        snapshot.activeRun = activeRun
        snapshot.modelID = modelID
        snapshot.activeTurn = activeTurn
        snapshot.semanticTip = semanticTip
        snapshot.unknownDomains = unknownDomains
        snapshot.lastEventID = lastEventID
        snapshot.lastSequence = lastSequence
        snapshot.causalOrderValid = causalOrderValid
        snapshot.structuralIntegrityValid = structuralIntegrityValid
        snapshot.semanticProjectionValid = semanticProjectionValid
    }
}

/// The current context crossing and source-observation slots. These are separate from the small
/// scalar continuation because a persistent adapter can prefetch one bounded context record
/// without loading lifetime-sized per-Run measurements into its scalar record.
internal struct SessionContextContinuation: Equatable, Sendable {
    var components: [ContextComponent]
    var manifest: ContextManifest?
    var promptAssemblyID: String?
    var promptSources: [ContextManifestSource]?
    var sourcesObservationEventID: String?
    var sourcesObservationSession: SessionRef?
    var sourcesObservationWork: WorkRef?
    var sourcesObservationWorkHost: WorkHostRef?
    var sourcesObservationRun: RunRef?
    var boundaryEventID: String?

    init(snapshot: SessionSnapshot) {
        components = snapshot.contextComponents
        manifest = snapshot.contextManifest
        promptAssemblyID = snapshot.contextPromptAssemblyID
        promptSources = snapshot.contextPromptSources
        sourcesObservationEventID = snapshot.contextSourcesObservationEventID
        sourcesObservationSession = snapshot.contextSourcesObservationSession
        sourcesObservationWork = snapshot.contextSourcesObservationWork
        sourcesObservationWorkHost = snapshot.contextSourcesObservationWorkHost
        sourcesObservationRun = snapshot.contextSourcesObservationRun
        boundaryEventID = snapshot.contextBoundaryEventID
    }

    func apply(to snapshot: inout SessionSnapshot) {
        snapshot.contextComponents = components
        snapshot.contextManifest = manifest
        snapshot.contextPromptAssemblyID = promptAssemblyID
        snapshot.contextPromptSources = promptSources
        snapshot.contextSourcesObservationEventID = sourcesObservationEventID
        snapshot.contextSourcesObservationSession = sourcesObservationSession
        snapshot.contextSourcesObservationWork = sourcesObservationWork
        snapshot.contextSourcesObservationWorkHost = sourcesObservationWorkHost
        snapshot.contextSourcesObservationRun = sourcesObservationRun
        snapshot.contextBoundaryEventID = boundaryEventID
    }
}

internal struct SessionCompactionContinuation: Equatable, Sendable {
    var summary: String?
    var boundaryEventID: String?

    init(snapshot: SessionSnapshot) {
        summary = snapshot.compactionSummary
        boundaryEventID = snapshot.compactionBoundaryEventID
    }

    func apply(to snapshot: inout SessionSnapshot) {
        snapshot.compactionSummary = summary
        snapshot.compactionBoundaryEventID = boundaryEventID
    }
}

/// Exact, bounded reads required by one Session event transition.
///
/// This is not a storage protocol. Persistent implementations must do their throwing reads
/// before entering this nonthrowing event-local overlay and must commit a complete resulting
/// checkpoint or discard it. Message branch materialization is intentionally a query-shaped
/// operation here; persisting it incrementally requires a separate ordered branch index.
internal protocol SessionTransitionStateAccess {
    var scalar: BoundedSessionScalarContinuation { get }
    var context: SessionContextContinuation { get }
    var compaction: SessionCompactionContinuation { get }
    var seenEventCount: Int { get }

    func hasSeenEvent(_ eventID: String) -> Bool
    func attachment(for attachmentID: String) -> SessionAttachmentSnapshot?
    func message(for eventID: String) -> SessionMessageSnapshot?
    func messageIsValid(_ eventID: String) -> Bool
    func contextCumulativeDeliveredBytes(for runID: String) -> Int?
    func recovery(at index: Int) -> RecoveryCoverage?
    func childState(for childID: String) -> String?

    var messageHistoryCount: Int { get }
    func selectedBranchExtension(from previousTip: EventRef, to newTip: EventRef?)
        -> [SessionMessageSnapshot]?
    func visibleMessages(for tip: EventRef?) -> [SessionMessageSnapshot]
}

/// Nonthrowing staged mutations for one Session event. Implementations own indexes, exact
/// membership, and root publication; this seam never performs I/O or swallows an error.
internal protocol SessionTransitionStagedMutation {
    mutating func stageScalar(_ continuation: BoundedSessionScalarContinuation)
    mutating func stageSeenEvent(_ event: TimelineEvent)
    mutating func stageAttachment(_ attachment: SessionAttachmentSnapshot)
    mutating func stageMessage(_ message: SessionMessageSnapshot)
    mutating func stageContext(_ context: SessionContextContinuation)
    mutating func stageContextCumulativeDeliveredBytes(_ bytes: Int, for runID: String)
    mutating func stageCompaction(_ compaction: SessionCompactionContinuation)
    mutating func stageVisibleMessages(_ messages: [SessionMessageSnapshot])
    mutating func appendVisibleMessages(_ messages: [SessionMessageSnapshot])
    mutating func recordVisibleProjectionFastPath()
    mutating func recordVisibleProjectionRebuild(scannedMessageCount: Int)
    mutating func stageRecovery(_ coverage: RecoveryCoverage, recorded: RecordedRecoveryCoverage)
    mutating func stageChildState(_ state: String, for childID: String)
    mutating func stageUnknown(_ unknown: UnknownTimelineEvent)
    mutating func stageQuarantineOnly(_ event: TimelineEvent)
    mutating func stageQuarantine(_ event: TimelineEvent, reason: String, structural: Bool)
}

internal protocol SessionTransitionState: SessionTransitionStateAccess, SessionTransitionStagedMutation {}

/// The complete in-memory adapter used by ``SessionReducer`` and differential tests.
///
/// Its dictionaries are the exact event-local slots a persistent adapter will prefetch. The
/// full arrays are retained solely to preserve the public SessionSnapshot representation and
/// to make this adapter a faithful reference implementation.
internal struct InMemorySessionTransitionState: SessionTransitionState, Sendable {
    private var storedSnapshot: SessionSnapshot
    private var scalarContinuation: BoundedSessionScalarContinuation
    private var contextContinuation: SessionContextContinuation
    private var compactionContinuation: SessionCompactionContinuation
    private var contextCumulativeDeliveredBytesByRun: [String: Int]?
    private var messageByID: [String: SessionMessageSnapshot]
    private var conversationValidityByMessageID: [String: Bool]

    private(set) var visibleProjectionRebuildCount: Int = 0
    private(set) var visibleProjectionMessagesScanned: Int = 0
    private(set) var visibleProjectionFastPathCount: Int = 0

    init(snapshot: SessionSnapshot = SessionSnapshot()) {
        storedSnapshot = snapshot
        scalarContinuation = BoundedSessionScalarContinuation(snapshot: snapshot)
        contextContinuation = SessionContextContinuation(snapshot: snapshot)
        compactionContinuation = SessionCompactionContinuation(snapshot: snapshot)
        contextCumulativeDeliveredBytesByRun = snapshot.contextCumulativeDeliveredBytesByRun
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
        messageByID = indexedMessages
        conversationValidityByMessageID = indexedValidity
    }

    var snapshot: SessionSnapshot {
        var result = storedSnapshot
        scalarContinuation.apply(to: &result)
        contextContinuation.apply(to: &result)
        compactionContinuation.apply(to: &result)
        result.contextCumulativeDeliveredBytesByRun = contextCumulativeDeliveredBytesByRun
        return result
    }

    var scalar: BoundedSessionScalarContinuation { scalarContinuation }
    var context: SessionContextContinuation { contextContinuation }
    var compaction: SessionCompactionContinuation { compactionContinuation }
    var seenEventCount: Int { storedSnapshot.seenEventIDs.count }
    var messageHistoryCount: Int { storedSnapshot.messageHistory.count }

    func hasSeenEvent(_ eventID: String) -> Bool {
        storedSnapshot.seenEventIDs.contains(eventID)
    }

    func attachment(for attachmentID: String) -> SessionAttachmentSnapshot? {
        storedSnapshot.attachments[attachmentID]
    }

    func message(for eventID: String) -> SessionMessageSnapshot? {
        messageByID[eventID]
    }

    func messageIsValid(_ eventID: String) -> Bool {
        conversationValidityByMessageID[eventID] == true
    }

    func contextCumulativeDeliveredBytes(for runID: String) -> Int? {
        contextCumulativeDeliveredBytesByRun?[runID]
    }

    func recovery(at index: Int) -> RecoveryCoverage? {
        guard storedSnapshot.recovery.indices.contains(index) else { return nil }
        return storedSnapshot.recovery[index]
    }

    func childState(for childID: String) -> String? {
        storedSnapshot.childStates[childID]
    }

    func selectedBranchExtension(
        from previousTip: EventRef, to newTip: EventRef?
    ) -> [SessionMessageSnapshot]? {
        guard let newTip else { return nil }
        if previousTip == newTip { return [] }
        var current: EventRef? = newTip
        var visited: Set<String> = []
        var extensionMessages: [SessionMessageSnapshot] = []
        while let ref = current, ref != previousTip {
            guard ref.journal == scalarContinuation.journal,
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

    func visibleMessages(for tip: EventRef?) -> [SessionMessageSnapshot] {
        guard let tip else {
            return storedSnapshot.messageHistory.filter(sessionMessageIsPresentationVisible)
        }
        var current: EventRef? = tip
        var visible: [SessionMessageSnapshot] = []
        var visited: Set<String> = []
        while let ref = current, visited.insert(ref.eventID).inserted {
            guard let message = messageByID[ref.eventID] else { break }
            if sessionMessageIsPresentationVisible(message) { visible.append(message) }
            current = message.conversationParent
        }
        return visible.reversed()
    }

    mutating func stageScalar(_ continuation: BoundedSessionScalarContinuation) {
        scalarContinuation = continuation
    }

    mutating func stageSeenEvent(_ event: TimelineEvent) {
        storedSnapshot.seenEventIDs.insert(event.eventID)
        var continuation = scalarContinuation
        continuation.lastEventID = event.eventID
        continuation.lastSequence = max(continuation.lastSequence, event.sequence)
        stageScalar(continuation)
    }

    mutating func stageAttachment(_ attachment: SessionAttachmentSnapshot) {
        storedSnapshot.attachments[attachment.attachment.attachmentID] = attachment
    }

    mutating func stageMessage(_ message: SessionMessageSnapshot) {
        storedSnapshot.messageHistory.append(message)
        messageByID[message.eventID] = message
        if let parent = message.conversationParent {
            conversationValidityByMessageID[message.eventID] =
                parent.journal == scalarContinuation.journal
                && messageByID[parent.eventID] != nil
                && conversationValidityByMessageID[parent.eventID] == true
        } else {
            conversationValidityByMessageID[message.eventID] = true
        }
        if scalarContinuation.semanticTip == nil, sessionMessageIsPresentationVisible(message) {
            storedSnapshot.messages.append(message)
        }
    }

    mutating func stageContext(_ context: SessionContextContinuation) {
        contextContinuation = context
    }

    mutating func stageContextCumulativeDeliveredBytes(_ bytes: Int, for runID: String) {
        var totals = contextCumulativeDeliveredBytesByRun ?? [:]
        totals[runID] = bytes
        contextCumulativeDeliveredBytesByRun = totals
    }

    mutating func stageCompaction(_ compaction: SessionCompactionContinuation) {
        compactionContinuation = compaction
    }

    mutating func stageVisibleMessages(_ messages: [SessionMessageSnapshot]) {
        storedSnapshot.messages = messages
    }

    mutating func appendVisibleMessages(_ messages: [SessionMessageSnapshot]) {
        storedSnapshot.messages.append(contentsOf: messages)
    }

    mutating func recordVisibleProjectionFastPath() {
        visibleProjectionFastPathCount += 1
    }

    mutating func recordVisibleProjectionRebuild(scannedMessageCount: Int) {
        visibleProjectionRebuildCount += 1
        visibleProjectionMessagesScanned += scannedMessageCount
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
}

public extension SessionMessageSnapshot {
    /// Decode the canonical presentation value for a Session message event.
    ///
    /// History paging and the full Session reducer must share this exact conversion. A second
    /// ad-hoc decoder could otherwise assign a different role, parent, timestamp, or provenance
    /// to the same durable event and still render a superficially plausible conversation.
    static func canonicalMessage(from event: TimelineEvent) -> SessionMessageSnapshot? {
        let role: String
        switch event.type {
        case TimelineEventType.inputAccepted:
            role = ChatRole.user.rawValue
        case TimelineEventType.messageCommitted:
            role = event.payload["role"]?.stringValue ?? ChatRole.assistant.rawValue
        default:
            return nil
        }
        guard let text = event.payload["text"]?.stringValue else { return nil }
        let parent = event.conversationParent
            ?? event.payload["conversation_parent"].flatMap { decodeTimelineValue($0) }
        if event.payload["conversation_parent"] != nil && parent == nil { return nil }
        return SessionMessageSnapshot(
            eventID: event.eventID, role: role, text: text, conversationParent: parent,
            sourceEvent: EventRef(journal: event.journal, eventID: event.eventID),
            sourceCursor: JournalCursor(
                journal: event.journal, eventID: event.eventID, sequence: event.sequence),
            hostRecordedAt: event.hostRecordedAt, clientTimestamp: event.clientTimestamp,
            run: event.run, turn: event.turn, actor: event.actor,
            client: event.client, sessionAttachment: event.sessionAttachment,
            causedBy: event.causedByEventID, parentActivity: event.parentActivityID,
            provenance: event.provenance, links: event.links)
    }

    /// Empty assistant fragments are canonical ancestry nodes but not conversation rows.
    var isPresentationVisible: Bool {
        role != ChatRole.assistant.rawValue || !text.isEmpty
    }
}

private func sessionMessageIsPresentationVisible(_ message: SessionMessageSnapshot) -> Bool {
    message.isPresentationVisible
}

// MARK: - Shared Session semantics

/// The one event/legality implementation for Session journals.
internal enum SessionReducerTransition {
    static func apply<State: SessionTransitionState>(_ event: TimelineEvent, to state: inout State) {
        guard accept(event, state: &state) else { return }
        guard event.isKnownType,
              event.schemaVersion <= TimelineEvent.currentSchemaVersion,
              event.payloadVersion <= 1
        else {
            recordUnknown(event, state: &state)
            return
        }
        if let session = event.session { updateScalar(&state) { $0.session = session } }

        switch event.type {
        case TimelineEventType.sessionCreated:
            updateScalar(&state) { $0.lifecycle = .active }
        case TimelineEventType.sessionAttached:
            guard let work = event.work, !work.workHostID.isEmpty, !work.workID.isEmpty,
                  let attachment = event.sessionAttachment, !attachment.attachmentID.isEmpty else {
                quarantine(event, state: &state, reason: "session attachment missing Work or attachment identity")
                return
            }
            if state.attachment(for: attachment.attachmentID) != nil {
                quarantine(event, state: &state,
                           reason: "Session attachment identity was reused")
                return
            }
            state.stageAttachment(SessionAttachmentSnapshot(
                attachment: attachment, work: work,
                capabilities: Set(event.payload["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [])))
            updateScalar(&state) { $0.lifecycle = .active }
        case TimelineEventType.sessionDetached:
            guard let attachment = event.sessionAttachment,
                  var attachmentState = state.attachment(for: attachment.attachmentID),
                  attachmentState.isAttached else {
                quarantine(event, state: &state,
                           reason: "session detach references an unknown or detached attachment")
                return
            }
            attachmentState.isAttached = false
            state.stageAttachment(attachmentState)
        case TimelineEventType.sessionAttachmentCapabilityChanged:
            guard let attachment = event.sessionAttachment,
                  var attachmentState = state.attachment(for: attachment.attachmentID),
                  let capabilities = event.payload["capabilities"]?.arrayValue?.compactMap(\.stringValue)
            else {
                quarantine(event, state: &state, reason: "attachment capability change is malformed")
                return
            }
            attachmentState.capabilities = Set(capabilities)
            state.stageAttachment(attachmentState)
        case TimelineEventType.sessionAttachmentCursorAdvanced:
            guard let attachment = event.sessionAttachment,
                  var attachmentState = state.attachment(for: attachment.attachmentID),
                  let cursor: JournalCursor = event.payload["cursor"].flatMap({ decodeTimelineValue($0) }),
                  cursor.journal.owner == .work(attachmentState.work)
            else {
                quarantine(event, state: &state, reason: "attachment cursor is malformed or for another Work")
                return
            }
            attachmentState.cursor = cursor
            state.stageAttachment(attachmentState)
        case TimelineEventType.inputAccepted:
            appendMessage(event, role: "user", state: &state)
        case TimelineEventType.messageCommitted:
            appendMessage(event, role: event.payload["role"]?.stringValue ?? "assistant", state: &state)
        case TimelineEventType.recoveryCoverage:
            guard let coverage = decodeRecoveryCoverage(event.payload),
                  let session = event.session, session == state.scalar.session,
                  let attachment = event.sessionAttachment, !attachment.attachmentID.isEmpty,
                  let work = event.work,
                  let workJournal: JournalRef = event.payload["work_journal"].flatMap({ decodeTimelineValue($0) }),
                  workJournal.owner == .work(work),
                  workJournal.authority.authorityID == work.workHostID,
                  let attachmentState = state.attachment(for: attachment.attachmentID),
                  attachmentState.work == work, attachmentState.isAttached,
                  let workHost = event.workHost, workHost.workHostID == work.workHostID,
                  let run = event.run, !run.runID.isEmpty else {
                quarantine(event, state: &state,
                           reason: "Session recovery coverage has an invalid identity envelope")
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
        case TimelineEventType.contextSourcesObserved:
            guard let assemblyID = event.payload["assembly_id"]?.stringValue,
                  let sources = decodeContextSources(event.payload),
                  let observationSession = event.session,
                  let observationWork = event.work,
                  let observationWorkHost = event.workHost,
                  let observationRun = event.run,
                  observationSession == state.scalar.session,
                  observationWork.workHostID == observationWorkHost.workHostID,
                  !observationWork.workID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !observationWork.workHostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !observationRun.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !assemblyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                quarantine(event, state: &state, reason: "context source observation is malformed")
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
                quarantine(event, state: &state,
                           reason: "context source observation failed validation")
                return
            }
            updateContext(&state) {
                $0.promptAssemblyID = assemblyID
                $0.promptSources = sources
                $0.sourcesObservationEventID = event.eventID
                $0.sourcesObservationSession = observationSession
                $0.sourcesObservationWork = observationWork
                $0.sourcesObservationWorkHost = observationWorkHost
                $0.sourcesObservationRun = observationRun
            }
        case TimelineEventType.contextAssembled:
            guard let components = decodeContextComponents(event.payload) else {
                quarantine(event, state: &state, reason: "context component manifest is malformed")
                return
            }
            let contextManifest = decodeContextManifest(event.payload, components: components)
            if event.payload["manifest_id"] != nil && contextManifest == nil {
                quarantine(event, state: &state, reason: "context crossing metadata is malformed")
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
                    quarantine(event, state: &state,
                               reason: "context crossing is missing or mismatches Work, Work Host, or Run identity")
                    return
                }
                if let sources = contextManifest.systemPromptSources {
                    guard let assemblyID = contextManifest.systemPromptAssemblyID,
                          let observedAssemblyID = state.context.promptAssemblyID,
                          let observedSources = state.context.promptSources,
                          let observationEventID = state.context.sourcesObservationEventID,
                          let causedBy = event.causedByEventID,
                          assemblyID == observedAssemblyID,
                          causedBy.journal == event.journal,
                          causedBy.eventID == observationEventID,
                          event.previousEventID == observationEventID,
                          state.context.sourcesObservationSession == event.session,
                          state.context.sourcesObservationWork == event.work,
                          state.context.sourcesObservationWorkHost == event.workHost,
                          state.context.sourcesObservationRun == event.run,
                          sources.allSatisfy({ $0.provenance == causedBy }),
                          sources.map({ $0.withProvenance(nil) }) == observedSources.map({
                              $0.withProvenance(nil)
                          }) else {
                        quarantine(event, state: &state,
                                   reason: "context crossing does not match its immediately preceding source observation")
                        return
                    }
                }
                do {
                    try contextManifest.validate(
                        authority: event.journal,
                        previousCumulativeDeliveredBytes:
                            state.contextCumulativeDeliveredBytes(for: run.runID),
                        requireRetainedBodies: true)
                } catch {
                    quarantine(event, state: &state,
                               reason: "context crossing failed canonical validation: \(error.localizedDescription)")
                    return
                }
                state.stageContextCumulativeDeliveredBytes(
                    contextManifest.cumulativeDeliveredBytes, for: run.runID)
            }
            var context = state.context
            context.components = components
            context.manifest = contextManifest
            context.promptAssemblyID = contextManifest?.systemPromptAssemblyID
            context.promptSources = contextManifest?.systemPromptSources
            context.sourcesObservationEventID = contextManifest?.systemPromptSources == nil
                ? nil : event.causedByEventID?.eventID
            if contextManifest?.systemPromptSources == nil {
                context.sourcesObservationSession = nil
                context.sourcesObservationWork = nil
                context.sourcesObservationWorkHost = nil
                context.sourcesObservationRun = nil
            }
            context.boundaryEventID = event.eventID
            state.stageContext(context)
        case TimelineEventType.compaction:
            guard let summary = event.payload["summary"]?.stringValue, !summary.isEmpty else {
                quarantine(event, state: &state, reason: "context compaction is missing summary")
                return
            }
            var compaction = state.compaction
            compaction.summary = summary
            compaction.boundaryEventID = event.eventID
            state.stageCompaction(compaction)
        case TimelineEventType.modelChanged:
            guard let model = event.payload["model_id"]?.stringValue
                    ?? event.payload["model"]?.stringValue,
                  !model.isEmpty else {
                quarantine(event, state: &state, reason: "model change is missing model identity")
                return
            }
            updateScalar(&state) { $0.modelID = model }
        case TimelineEventType.sessionAttention:
            guard let raw = event.payload["attention"]?.stringValue,
                  let attention = SessionAttention(rawValue: raw) else {
                // A malformed attention event cannot mean `.none`; retain the previous known
                // state so notification delivery never invents a clearing edge.
                recordUnknown(event, state: &state)
                quarantine(event, state: &state,
                           reason: "session attention payload is missing or invalid")
                return
            }
            updateScalar(&state) {
                $0.attention = attention
                $0.attentionEvent = EventRef(journal: event.journal, eventID: event.eventID)
            }
        case TimelineEventType.sessionCompleted:
            updateScalar(&state) {
                $0.lifecycle = .completed
                $0.execution = .idle
            }
        case TimelineEventType.sessionArchived:
            updateScalar(&state) {
                $0.lifecycle = .archived
                $0.attention = .none
                $0.attentionEvent = EventRef(journal: event.journal, eventID: event.eventID)
            }
        case TimelineEventType.sessionTipSelected:
            guard let tip = event.conversationParent, validateConversationTip(tip, state: state) else {
                quarantine(event, state: &state, reason: "semantic tip is not a known acyclic Session node")
                return
            }
            let previousTip = state.scalar.semanticTip
            updateScalar(&state) { $0.semanticTip = tip }
            rebuildVisibleMessages(from: previousTip, state: &state)
        default:
            recordUnknown(event, state: &state)
        }
    }

    private static func accept<State: SessionTransitionState>(
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
            quarantine(event, state: &state, reason: "event belongs to another journal", structural: true)
            return false
        }
        if state.scalar.journal == nil { updateScalar(&state) { $0.journal = event.journal } }
        if state.scalar.session == nil, case .session(let session) = event.journal.owner {
            updateScalar(&state) { $0.session = session }
        }
        if let session = event.session, session != state.scalar.session {
            quarantine(event, state: &state,
                       reason: "event Session identity does not match journal", structural: true)
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
        state.stageSeenEvent(event)
        return true
    }

    private static func acceptsJournal<State: SessionTransitionState>(
        _ journal: JournalRef, state: State
    ) -> Bool {
        guard case .session = journal.owner else { return false }
        return state.scalar.journal == nil || state.scalar.journal == journal
    }

    private static func recordUnknown<State: SessionTransitionState>(
        _ event: TimelineEvent, state: inout State
    ) {
        let domains = event.declaredDomains.isEmpty
            ? Set(TimelineDomain.allCases) : event.declaredDomains
        state.stageUnknown(UnknownTimelineEvent(
            event: event, journalOffset: state.seenEventCount - 1,
            affectedDomains: domains))
    }

    private static func quarantine<State: SessionTransitionState>(
        _ event: TimelineEvent, state: inout State, reason: String, structural: Bool = false
    ) {
        state.stageQuarantine(event, reason: reason, structural: structural)
    }

    private static func appendMessage<State: SessionTransitionState>(
        _ event: TimelineEvent, role: String, state: inout State
    ) {
        guard event.payload["text"]?.stringValue != nil else {
            quarantine(event, state: &state, reason: "message is missing text")
            return
        }
        let parent = event.conversationParent
            ?? event.payload["conversation_parent"].flatMap { decodeTimelineValue($0) }
        if event.payload["conversation_parent"] != nil && parent == nil {
            quarantine(event, state: &state, reason: "message conversation parent is malformed")
            return
        }
        guard let message = SessionMessageSnapshot.canonicalMessage(from: event) else {
            quarantine(event, state: &state, reason: "message could not be projected")
            return
        }
        // `role` is retained in this private signature so the switch above remains an explicit
        // reducer contract. The shared decoder independently derives and must agree with it.
        guard message.role == role else {
            quarantine(event, state: &state, reason: "message role is inconsistent")
            return
        }
        state.stageMessage(message)
    }

    private static func rebuildVisibleMessages<State: SessionTransitionState>(
        from previousTip: EventRef?, state: inout State
    ) {
        if let previousTip,
           let extensionMessages = state.selectedBranchExtension(from: previousTip, to: state.scalar.semanticTip) {
            if !extensionMessages.isEmpty {
                state.appendVisibleMessages(extensionMessages.filter(sessionMessageIsPresentationVisible))
            }
            state.recordVisibleProjectionFastPath()
            return
        }
        state.recordVisibleProjectionRebuild(scannedMessageCount: state.messageHistoryCount)
        state.stageVisibleMessages(state.visibleMessages(for: state.scalar.semanticTip))
    }

    private static func validateConversationTip<State: SessionTransitionState>(
        _ tip: EventRef, state: State
    ) -> Bool {
        tip.journal == state.scalar.journal
            && state.hasSeenEvent(tip.eventID)
            && state.message(for: tip.eventID) != nil
            && state.messageIsValid(tip.eventID)
    }

    private static func updateScalar<State: SessionTransitionState>(
        _ state: inout State, _ body: (inout BoundedSessionScalarContinuation) -> Void
    ) {
        var continuation = state.scalar
        body(&continuation)
        state.stageScalar(continuation)
    }

    private static func updateContext<State: SessionTransitionState>(
        _ state: inout State, _ body: (inout SessionContextContinuation) -> Void
    ) {
        var continuation = state.context
        body(&continuation)
        state.stageContext(continuation)
    }
}
