import Foundation
import OpenTelemetrySdk
@testable import AviaryCore

private enum AttachedControllerTestError: Error {
    case unsupported
    case transport
}

private actor AttachedControllerHistoryGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private enum AttachedControllerServiceMode: Sendable {
    case normal
    case repeatedPage
    case foreignPage
    case truncatedPage
    case transport
    case remoteStale
    case remoteReadStale
    case foreignSnapshot
    case forgedAcceptedReceipt
    case forgedHistoryPage
    case missingAttachment
    case omittedAttachment
    case artifactZeroProgress
    case artifactMalformed
    case artifactDigestMismatch
    case artifactIdentityMismatch
    case artifactUnavailable
    case artifactOmitted
    case artifactChunkTooLarge
    case artifactProducerRelationshipOmitted
    case artifactProducerRelationshipDetached
}

private func semanticTipDescends(
    from ancestor: EventRef?, to descendant: EventRef?,
    messages: [SessionMessageSnapshot]
) -> Bool {
    guard ancestor != descendant else { return true }
    guard let descendant else { return false }
    guard let ancestor else { return true }
    let messagesByID = Dictionary(
        uniqueKeysWithValues: messages.compactMap { message -> (String, SessionMessageSnapshot)? in
            guard let source = message.sourceEvent else { return nil }
            return (source.eventID, message)
        })
    var current: EventRef? = descendant
    var visited: Set<String> = []
    while let tip = current {
        guard tip.journal == ancestor.journal,
              visited.insert(tip.eventID).inserted,
              let message = messagesByID[tip.eventID],
              let parent = message.conversationParent else {
            return false
        }
        if parent == ancestor { return true }
        current = parent
    }
    return false
}

private final class AttachedControllerCheckpointBox: @unchecked Sendable {
    var record: WorkServiceAttachedWorkCheckpointStore.Record?
    var saveCount = 0
    var failSaves = false
}

private struct AttachedControllerCheckpointStore: WorkServiceAttachedWorkCheckpointStoring {
    let box: AttachedControllerCheckpointBox

    func load() throws -> WorkServiceAttachedWorkCheckpointStore.Record? {
        box.record
    }

    func save(_ record: WorkServiceAttachedWorkCheckpointStore.Record) throws {
        if box.failSaves { throw AttachedControllerTestError.transport }
        box.saveCount += 1
        box.record = record
    }
}

private struct AttachedControllerFixture: Sendable {
    let host: WorkHostRef
    let instance: WorkHostInstanceRef
    let work: WorkRef
    let workJournal: JournalRef
    let session: SessionRef
    let sessionJournal: JournalRef
    let sessionAttachment: SessionAttachmentRef
    let client: ClientRef
    let clientAttachment: ClientAttachmentRef
    let authorization: WorkServiceAuthorizationOutcome
    let workEvents: [TimelineEvent]
    let sessionEvents: [TimelineEvent]
    let descriptor: WorkServiceWorkDescriptor
    let response: WorkServiceCreateWorkResponse

    init(
        workID: String = "controller-work",
        clientID: String = "controller-client",
        disposition: WorkServiceRecordedDisposition = .reusable,
        artifacts: [WorkServiceArtifactDescriptor] = []
    ) throws {
        host = WorkHostRef("controller-host")
        instance = WorkHostInstanceRef(
            host: host, instanceID: "controller-instance", startIdentity: "controller-start")
        work = WorkRef(workHostID: host.workHostID, workID: workID)
        workJournal = JournalRef.work(work, journalID: "controller-work-journal")
        session = SessionRef("controller-session-\(workID)")
        sessionJournal = JournalRef.session(
            session, journalID: "controller-session-journal-\(workID)",
            authority: TimelineAuthorityRef(host.workHostID))
        sessionAttachment = SessionAttachmentRef("controller-session-attachment-\(workID)")
        client = ClientRef(clientID)
        clientAttachment = ClientAttachmentRef("controller-client-attachment-\(clientID)-\(workID)")
        authorization = WorkServiceAuthorizationOutcome(
            requested: Set(WorkServiceCapability.allCases),
            granted: Set(WorkServiceCapability.allCases), denied: [])
        let attachment = WorkServiceClientAttachment(
            attachment: clientAttachment, client: client, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            authorization: authorization)
        // The fixture advertises both independent client attachments.  This keeps the second
        // controller's exact existing seed on the canonical list instead of exercising a
        // vanished-row fallback while testing observer independence.
        let secondClient = ClientRef("controller-client-b")
        let secondAttachment = WorkServiceClientAttachment(
            attachment: ClientAttachmentRef(
                "controller-client-attachment-" + secondClient.clientID + "-" + workID),
            client: secondClient, session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment, authorization: authorization)

        func event(
            journal: JournalRef, eventID: String, sequence: Int, previous: String?,
            type: String, session: SessionRef? = nil, work: WorkRef? = nil,
            workHost: WorkHostRef? = nil, client: ClientRef? = nil,
            sessionAttachment: SessionAttachmentRef? = nil,
            payload: JSONValue = .object([:])
        ) -> TimelineEvent {
            TimelineEvent(
                eventID: eventID, journal: journal, sequence: sequence,
                previousEventID: previous, session: session, work: work,
                workHost: workHost, client: client, sessionAttachment: sessionAttachment,
                actor: TimelineActor(actorID: "controller-fixture", kind: "test"),
                hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                type: type, payload: payload)
        }

        let w1 = event(
            journal: workJournal, eventID: "work-1", sequence: 1, previous: nil,
            type: TimelineEventType.workCreated, session: session, work: work,
            workHost: host, client: client, sessionAttachment: sessionAttachment)
        let w2 = event(
            journal: workJournal, eventID: "work-2", sequence: 2, previous: w1.eventID,
            type: TimelineEventType.sessionAttached, session: session, work: work,
            workHost: host, client: client, sessionAttachment: sessionAttachment)
        var constructedWorkEvents = [w1, w2]
        if disposition != .reusable {
            constructedWorkEvents.append(event(
                journal: workJournal, eventID: "work-3", sequence: 3, previous: w2.eventID,
                type: disposition == .completed
                    ? TimelineEventType.workCompleted : TimelineEventType.workDestroyed,
                work: work, workHost: host))
        }
        workEvents = constructedWorkEvents

        let s1 = event(
            journal: sessionJournal, eventID: "session-1", sequence: 1, previous: nil,
            type: TimelineEventType.sessionCreated, session: session,
            work: work, workHost: host, client: client, sessionAttachment: sessionAttachment)
        let s2 = event(
            journal: sessionJournal, eventID: "session-2", sequence: 2, previous: s1.eventID,
            type: TimelineEventType.sessionAttached, session: session, work: work,
            workHost: host, client: client, sessionAttachment: sessionAttachment,
            payload: .object(["capabilities": .array([.string("observe"), .string("control")])]))
        let s3 = event(
            journal: sessionJournal, eventID: "session-3", sequence: 3, previous: s2.eventID,
            type: TimelineEventType.inputAccepted, session: session, work: work,
            workHost: host, client: client, sessionAttachment: sessionAttachment,
            payload: .object(["text": .string("hello from the GUI")]))
        let s4 = event(
            journal: sessionJournal, eventID: "session-4", sequence: 4, previous: s3.eventID,
            type: TimelineEventType.messageCommitted, session: session, work: work,
            workHost: host, client: client, sessionAttachment: sessionAttachment,
            payload: .object(["role": .string("assistant"), "text": .string("hello back")]))
        sessionEvents = [s1, s2, s3, s4]

        let workCursor = JournalCursor(
            journal: workJournal, eventID: workEvents.last!.eventID,
            sequence: workEvents.last!.sequence)
        let sessionCursor = JournalCursor(
            journal: sessionJournal, eventID: sessionEvents.last!.eventID,
            sequence: sessionEvents.last!.sequence)
        let observation = try WorkServiceHostObservation(
            instance: instance, reachability: .observedReachable, currentRun: nil,
            currentRunSession: nil, currentRunSessionAttachment: nil,
            servedCursor: workCursor, sourceCompleteness: .complete)
        let relationship = WorkServiceSessionAttachmentDescriptor(
            session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment, publication: .mirrored,
            causalSessionCursor: JournalCursor(
                journal: sessionJournal, eventID: s1.eventID, sequence: s1.sequence),
            sessionCursor: JournalCursor(
                journal: sessionJournal, eventID: s2.eventID, sequence: s2.sequence),
            causalWorkCursor: JournalCursor(
                journal: workJournal, eventID: w1.eventID, sequence: w1.sequence),
            resultingWorkCursor: JournalCursor(
                journal: workJournal, eventID: w2.eventID, sequence: w2.sequence),
            capabilities: [.observe, .control])
        var relationships = [relationship]
        for artifact in artifacts
        where artifact.session != session || artifact.sessionAttachment != sessionAttachment {
            let producerJournal = JournalRef.session(
                artifact.session,
                journalID: "controller-producer-session-journal-\(artifact.session.sessionID)",
                authority: TimelineAuthorityRef(host.workHostID))
            relationships.append(WorkServiceSessionAttachmentDescriptor(
                session: artifact.session, sessionJournal: producerJournal,
                sessionAttachment: artifact.sessionAttachment, publication: .mirrored,
                causalSessionCursor: JournalCursor(journal: producerJournal, sequence: 0),
                sessionCursor: JournalCursor(journal: producerJournal, sequence: 0),
                causalWorkCursor: JournalCursor(journal: workJournal, sequence: 0),
                resultingWorkCursor: JournalCursor(journal: workJournal, sequence: 0),
                capabilities: [.observe]))
        }
        descriptor = try WorkServiceWorkDescriptor(
            work: work, journal: workJournal, recordedDisposition: disposition,
            execution: .idle, currentRun: nil, currentRunSession: nil,
            currentRunSessionAttachment: nil, hostObservation: observation,
            attachments: [attachment, secondAttachment], sessionAttachments: relationships,
            artifacts: artifacts)
        let controlJournal = JournalRef.workHost(host)
        let controlCursor = JournalCursor(
            journal: controlJournal, eventID: "control-1", sequence: 1)
        let receipt = WorkServiceControlReceipt(
            operation: .createWork, work: work, commandID: "create-controller",
            state: .accepted, host: instance, causalControlCursor: JournalCursor(
                journal: controlJournal, sequence: 0), resultingControlCursor: controlCursor,
            authorization: authorization, outcome: .created)
        response = WorkServiceCreateWorkResponse(
            work: descriptor, authorization: authorization, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            attachment: attachment, workCursor: workCursor, sessionCursor: sessionCursor,
            controlCursor: controlCursor, receipt: receipt)
    }

    func attachment(for client: ClientRef) -> WorkServiceClientAttachment {
        WorkServiceClientAttachment(
            attachment: ClientAttachmentRef("controller-client-attachment-\(client.clientID)-\(work.workID)"),
            client: client, session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment, authorization: authorization)
    }
}

private func attachedControllerPrefixDigest(
    _ events: [TimelineEvent], cursor: JournalCursor
) -> String {
    var data = Data()
    data.append(Data((cursor.journal.stableKey + "\u{0}" + String(cursor.sequence)
        + "\u{0}" + (cursor.eventID ?? "") + "\u{0}").utf8))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for event in events where event.sequence <= cursor.sequence {
        if let encoded = try? encoder.encode(event) {
            data.append(encoded)
            data.append(0)
        }
    }
    return "sha256:" + AviarySHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}

private actor AttachedControllerTestService: WorkServiceClient {
    var hostCapabilities = Set(WorkServiceCapability.allCases)
    func setHostCapabilities(_ capabilities: Set<WorkServiceCapability>) {
        hostCapabilities = capabilities
    }
    var commandGate: AttachedControllerHistoryGate?
    func setCommandGate(_ gate: AttachedControllerHistoryGate?) { commandGate = gate }
    var commandReceiptGate: AttachedControllerHistoryGate?
    func setCommandReceiptGate(_ gate: AttachedControllerHistoryGate?) { commandReceiptGate = gate }
    let fixture: AttachedControllerFixture
    var mode: AttachedControllerServiceMode = .normal
    var artifactDescriptors: [WorkServiceArtifactDescriptor]
    var artifactBodies: [TimelineBodyReference: Data] = [:]
    var artifactBodyGate: AttachedControllerHistoryGate?
    var attachmentAuthorization: WorkServiceAuthorizationOutcome
    var artifactBodyRequests: [WorkServiceBodyRequest] = []
    var commandRequests: [WorkServiceCommandRequest] = []
    var directShellRequests: [WorkServiceDirectShellRequest] = []
    var commandFailuresRemaining = 0
    var loseAcceptedResponsesRemaining = 0
    var acceptedCommands: [String: WorkServiceCommandReceipt] = [:]
    var commandEffects = 0
    var workEvents: [TimelineEvent]
    var sessionEvents: [TimelineEvent]
    var controlCursorStorage: JournalCursor
    var hostInstanceStorage: WorkHostInstanceRef
    var descriptorExecutionOverride: WorkServiceExecutionState?
    var readAcknowledgements: [WorkServiceReadTarget: JournalCursor] = [:]
    var readAcknowledgementResponses: [String: WorkServiceAcknowledgeReadResponse] = [:]
    var readAcknowledgementRequests: [WorkServiceAcknowledgeReadRequest] = []
    var readAcknowledgementEffects = 0
    var loseReadAcknowledgementResponsesRemaining = 0
    var loseReadAcknowledgementBeforeAdmissionRemaining = 0
    var loseReadAcknowledgementBeforeAdmissionTarget: WorkServiceReadTarget?
    var advanceControlAfterWorkAcknowledgement = false
    var forgeReadAcknowledgementResponse = false
    var corruptPrefixDigests = false
    var snapshotAfterSequences: [Int] = []
    var pageAfterSequences: [Int] = []
    var historyRequests: [WorkServiceHistoryRequest] = []
    var historyGate: AttachedControllerHistoryGate?

    init(fixture: AttachedControllerFixture) {
        self.fixture = fixture
        self.artifactDescriptors = fixture.descriptor.artifacts
        self.attachmentAuthorization = fixture.authorization
        self.workEvents = fixture.workEvents
        self.sessionEvents = fixture.sessionEvents
        self.controlCursorStorage = fixture.response.controlCursor
        self.hostInstanceStorage = fixture.instance
    }

    func setMode(_ mode: AttachedControllerServiceMode) { self.mode = mode }
    func setForgedReadAcknowledgementResponse() { forgeReadAcknowledgementResponse = true }
    func setArtifactDescriptors(_ descriptors: [WorkServiceArtifactDescriptor]) {
        artifactDescriptors = descriptors
    }
    func setArtifactBody(_ body: Data, for reference: TimelineBodyReference) {
        artifactBodies[reference] = body
    }
    func setArtifactBodyGate(_ gate: AttachedControllerHistoryGate?) { artifactBodyGate = gate }
    func setAttachmentAuthorization(_ authorization: WorkServiceAuthorizationOutcome) {
        attachmentAuthorization = authorization
    }
    func artifactBodyRequestCount() -> Int { artifactBodyRequests.count }
    func failNextCommand() { commandFailuresRemaining += 1 }
    func loseNextAcceptedResponse() { loseAcceptedResponsesRemaining += 1 }
    func commandCount() -> Int { commandRequests.count }
    func directShellCount() -> Int { directShellRequests.count }
    func commandEffectCount() -> Int { commandEffects }
    func lastCommand() -> WorkServiceCommandRequest? { commandRequests.last }
    func readAckRequests() -> [WorkServiceAcknowledgeReadRequest] {
        readAcknowledgementRequests
    }
    func readAckEffectCount() -> Int { readAcknowledgementEffects }
    func setLoseReadAcknowledgementResponses(
        _ count: Int, beforeAdmission: Bool = false, target: WorkServiceReadTarget? = nil
    ) {
        if beforeAdmission {
            loseReadAcknowledgementBeforeAdmissionRemaining = count
            loseReadAcknowledgementBeforeAdmissionTarget = target
        } else {
            loseReadAcknowledgementResponsesRemaining = count
        }
    }
    func loseNextReadAcknowledgementBeforeAdmission(
        for target: WorkServiceReadTarget
    ) {
        loseReadAcknowledgementBeforeAdmissionTarget = target
    }
    func setAdvanceControlAfterWorkAcknowledgement(_ enabled: Bool) {
        advanceControlAfterWorkAcknowledgement = enabled
    }
    func setCorruptPrefixDigests(_ enabled: Bool) { corruptPrefixDigests = enabled }
    func setHostInstance(_ instance: WorkHostInstanceRef) { hostInstanceStorage = instance }
    func setDescriptorExecutionOverride(_ execution: WorkServiceExecutionState?) {
        descriptorExecutionOverride = execution
    }
    func controlCursor() -> JournalCursor { controlCursorStorage }
    func snapshotRequestCursors() -> [Int] { snapshotAfterSequences }
    func pageRequestCursors() -> [Int] { pageAfterSequences }
    func historyRequestCount() -> Int { historyRequests.count }
    func historyRequestBranchTips() -> [EventRef?] { historyRequests.map(\.branchTip) }
    func setHistoryGate(_ gate: AttachedControllerHistoryGate?) { historyGate = gate }

    func handshake(_ request: WorkServiceHandshakeRequest) async throws -> WorkServiceHandshakeResponse {
        try responseHandshake()
    }

    func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage {
        WorkServiceWorkPage(works: [fixture.descriptor], nextPageToken: nil)
    }

    func describeWork(_ request: WorkServiceDescribeRequest) async throws -> WorkServiceWorkDescriptor {
        fixture.descriptor
    }

    func createWork(_ request: WorkServiceCreateWorkRequest) async throws -> WorkServiceCreateWorkResponse {
        fixture.response
    }

    func createSession(_ request: WorkServiceCreateSessionRequest) async throws
        -> WorkServiceCreateSessionResponse {
        throw AttachedControllerTestError.unsupported
    }

    func completeWork(_ request: WorkServiceCompleteWorkRequest) async throws -> WorkServiceCommandReceipt {
        throw AttachedControllerTestError.unsupported
    }

    func attach(_ request: WorkServiceAttachRequest) async throws -> WorkServiceAttachResponse {
        throw AttachedControllerTestError.unsupported
    }

    func detach(_ request: WorkServiceDetachRequest) async throws -> WorkServiceDetachResponse {
        throw AttachedControllerTestError.unsupported
    }

    func updateCapabilities(
        _ request: WorkServiceUpdateCapabilitiesRequest
    ) async throws -> WorkServiceUpdateCapabilitiesResponse {
        throw AttachedControllerTestError.unsupported
    }

    func acknowledgeRead(
        _ request: WorkServiceAcknowledgeReadRequest
    ) async throws -> WorkServiceAcknowledgeReadResponse {
        readAcknowledgementRequests.append(request)
        if let prior = readAcknowledgementResponses[request.commandID] {
            return WorkServiceAcknowledgeReadResponse(
                work: prior.work, target: prior.target, cursor: prior.cursor,
                commandID: prior.commandID, state: .duplicate, host: prior.host,
                causalControlCursor: prior.causalControlCursor,
                resultingControlCursor: prior.resultingControlCursor,
                authorization: fixture.authorization,
                receipt: WorkServiceControlReceipt(
                    operation: .acknowledgeRead, work: prior.work,
                    commandID: prior.commandID, state: .duplicate, host: prior.host,
                    causalControlCursor: prior.causalControlCursor,
                    resultingControlCursor: prior.resultingControlCursor,
                    authorization: fixture.authorization, outcome: .readAcknowledged),
                diagnostic: "idempotent duplicate")
        }
        guard request.causalControlCursor == controlCursorStorage else {
            return WorkServiceAcknowledgeReadResponse(
                work: request.work, target: request.target, cursor: request.cursor,
                commandID: request.commandID, state: .rejected, host: hostInstanceStorage,
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursorStorage,
                authorization: fixture.authorization,
                rejection: .staleCursor, diagnostic: "stale control cursor")
        }
        let targetedBeforeAdmission = loseReadAcknowledgementBeforeAdmissionTarget == nil
            || loseReadAcknowledgementBeforeAdmissionTarget == request.target
        if loseReadAcknowledgementBeforeAdmissionRemaining > 0 && targetedBeforeAdmission {
            loseReadAcknowledgementBeforeAdmissionRemaining -= 1
            if loseReadAcknowledgementBeforeAdmissionRemaining == 0 {
                loseReadAcknowledgementBeforeAdmissionTarget = nil
            }
            throw AttachedControllerTestError.transport
        }
        if loseReadAcknowledgementBeforeAdmissionRemaining == 0
            && loseReadAcknowledgementBeforeAdmissionTarget == request.target {
            loseReadAcknowledgementBeforeAdmissionTarget = nil
            throw AttachedControllerTestError.transport
        }
        let resulting = appendControlCursor()
        readAcknowledgements[request.target] = request.cursor
        readAcknowledgementEffects += 1
        let response = WorkServiceAcknowledgeReadResponse(
            work: request.work, target: request.target, cursor: request.cursor,
            commandID: request.commandID, state: .accepted, host: hostInstanceStorage,
            causalControlCursor: request.causalControlCursor,
            resultingControlCursor: resulting, authorization: fixture.authorization,
            receipt: WorkServiceControlReceipt(
                operation: .acknowledgeRead, work: request.work,
                commandID: request.commandID, state: .accepted, host: hostInstanceStorage,
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: resulting, authorization: fixture.authorization,
                outcome: .readAcknowledged))
        readAcknowledgementResponses[request.commandID] = response
        if request.target.session == nil && advanceControlAfterWorkAcknowledgement {
            _ = appendControlCursor()
        }
        if loseReadAcknowledgementResponsesRemaining > 0 {
            loseReadAcknowledgementResponsesRemaining -= 1
            throw AttachedControllerTestError.transport
        }
        if forgeReadAcknowledgementResponse {
            return WorkServiceAcknowledgeReadResponse(
                work: response.work, target: response.target, cursor: response.cursor,
                commandID: "foreign-command", state: response.state, host: response.host,
                causalControlCursor: response.causalControlCursor,
                resultingControlCursor: response.resultingControlCursor,
                authorization: fixture.authorization, receipt: response.receipt)
        }
        return response
    }

    func snapshot(_ request: WorkServiceSnapshotRequest) async throws -> WorkServiceSnapshot {
        if mode == .transport { throw AttachedControllerTestError.transport }
        snapshotAfterSequences.append(request.afterCursor?.sequence ?? 0)
        if mode == .remoteReadStale, (request.afterCursor?.sequence ?? 0) > 0 {
            throw WorkServiceTransportError.remote(code: .staleCursor, detail: nil)
        }
        let events = events(for: request.target)
        var selected = Array(events.filter { $0.sequence > (request.afterCursor?.sequence ?? 0) }
            .prefix(request.limit))
        if mode == .foreignSnapshot, let first = selected.first {
            let foreignWork = WorkRef(workHostID: fixture.host.workHostID, workID: "foreign")
            let foreignJournal = JournalRef.work(foreignWork, journalID: "foreign-journal")
            selected[0] = TimelineEvent(
                eventID: first.eventID, journal: foreignJournal, sequence: first.sequence,
                previousEventID: first.previousEventID, session: first.session, work: first.work,
                workHost: first.workHost, client: first.client,
                sessionAttachment: first.sessionAttachment, actor: first.actor,
                hostRecordedAt: first.hostRecordedAt, type: first.type, payload: first.payload)
        }
        let served = selected.last.map {
            JournalCursor(journal: request.target.journal, eventID: $0.eventID, sequence: $0.sequence)
        } ?? request.afterCursor ?? JournalCursor(journal: request.target.journal, sequence: 0)
        var omissions: [WorkServiceOmission] = []
        if events.contains(where: { $0.sequence > served.sequence }) {
            omissions.append(WorkServiceOmission(category: "events", count: 1))
        }
        return WorkServiceSnapshot(
            work: try currentDescriptor(), events: selected, target: request.target,
            servedCursor: served,
            basePrefixDigest: prefixDigest(events, cursor: request.afterCursor
                ?? JournalCursor(journal: request.target.journal, sequence: 0)),
            prefixDigest: prefixDigest(events, cursor: served),
            omissions: omissions)
    }

    func eventsAfterCursor(_ request: WorkServiceEventsRequest) async throws -> WorkServiceEventPage {
        if mode == .transport { throw AttachedControllerTestError.transport }
        pageAfterSequences.append(request.afterCursor.sequence)
        let all = events(for: request.target)
        var selected = Array(all.filter { $0.sequence > request.afterCursor.sequence }
            .prefix(request.limit))
        if mode == .repeatedPage {
            selected = Array(all.prefix(request.limit))
        } else if mode == .foreignPage, let first = selected.first {
            let foreignWork = WorkRef(workHostID: fixture.host.workHostID, workID: "foreign")
            let foreignJournal = JournalRef.work(foreignWork, journalID: "foreign-journal")
            selected[0] = TimelineEvent(
                eventID: first.eventID, journal: foreignJournal, sequence: first.sequence,
                previousEventID: first.previousEventID, session: first.session, work: first.work,
                workHost: first.workHost, client: first.client,
                sessionAttachment: first.sessionAttachment, actor: first.actor,
                hostRecordedAt: first.hostRecordedAt, type: first.type, payload: first.payload)
        }
        let served = selected.last.map {
            JournalCursor(journal: request.target.journal, eventID: $0.eventID, sequence: $0.sequence)
        } ?? request.afterCursor
        let hasMore = all.contains { $0.sequence > served.sequence }
        let omissions: [WorkServiceOmission]
        if hasMore || mode == .truncatedPage {
            omissions = [WorkServiceOmission(category: "events", count: 1)]
        } else {
            omissions = []
        }
        return WorkServiceEventPage(
            events: selected, target: request.target, servedCursor: served,
            nextCursor: mode == .truncatedPage ? nil : (hasMore ? served : nil),
            basePrefixDigest: prefixDigest(all, cursor: request.afterCursor),
            prefixDigest: prefixDigest(all, cursor: served),
            omissions: omissions)
    }

    func historyBeforeCursor(_ request: WorkServiceHistoryRequest) async throws
        -> WorkServiceHistoryPage {
        if mode == .transport { throw AttachedControllerTestError.transport }
        historyRequests.append(request)
        if let historyGate { await historyGate.enter() }
        guard request.target == .session(
            session: fixture.session, journal: fixture.sessionJournal)
        else { throw AttachedControllerTestError.transport }
        var reducer = SessionReducer()
        for event in sessionEvents { reducer.apply(event) }
        let visibleIDs = Set(reducer.snapshot.messages.compactMap(\.sourceEvent?.eventID))
        let visible = sessionEvents.filter { visibleIDs.contains($0.eventID) }
        let tip = sessionEvents.last.map {
            JournalCursor(
                journal: fixture.sessionJournal, eventID: $0.eventID,
                sequence: $0.sequence)
        } ?? JournalCursor(journal: fixture.sessionJournal, sequence: 0)
        let frozen = request.frozenTipCursor ?? tip
        let frozenDigest = prefixDigest(sessionEvents, cursor: frozen)
        guard request.frozenTipDigest == nil || request.frozenTipDigest == frozenDigest,
              semanticTipDescends(
                  from: request.branchTip, to: reducer.snapshot.semanticTip,
                  messages: reducer.snapshot.messages)
        else { throw AttachedControllerTestError.transport }
        let cutoff = request.beforeCursor?.sequence ?? frozen.sequence + 1
        let candidates = visible.filter {
            $0.sequence <= frozen.sequence && $0.sequence < cutoff
        }
        var selected: [TimelineEvent] = []
        var bytes = 0
        for event in candidates.reversed() {
            guard selected.count < request.limit else { break }
            let size = try WorkServiceEventPageSizing.encodedByteCount(of: event)
            guard size <= request.maxBytes - bytes else { break }
            selected.append(event)
            bytes += size
        }
        selected.reverse()
        let canonicalLower = selected.first.map {
            JournalCursor(
                journal: fixture.sessionJournal, eventID: $0.eventID,
                sequence: $0.sequence)
        }
        let canonicalUpper = selected.last.map {
            JournalCursor(
                journal: fixture.sessionJournal, eventID: $0.eventID,
                sequence: $0.sequence)
        }
        let pageDigest = try WorkServiceHistoryPageEvidence.digest(
            events: selected, target: request.target, cursor: canonicalUpper ?? frozen)
        if mode == .forgedHistoryPage, let first = selected.first {
            selected[0] = TimelineEvent(
                eventID: first.eventID, journal: fixture.workJournal,
                sequence: first.sequence, previousEventID: first.previousEventID,
                session: first.session, work: first.work, workHost: first.workHost,
                client: first.client, sessionAttachment: first.sessionAttachment,
                actor: first.actor, hostRecordedAt: first.hostRecordedAt,
                type: first.type, payload: first.payload)
        }
        let hasOlder = candidates.count > selected.count
        return WorkServiceHistoryPage(
            authority: try WorkServiceHistoryAuthority(
                work: fixture.work, journal: fixture.workJournal,
                hostInstance: fixture.instance, sourceCompleteness: .complete),
            events: selected, target: request.target,
            lowerBoundaryCursor: canonicalLower, upperBoundaryCursor: canonicalUpper,
            nextBeforeCursor: hasOlder ? canonicalLower : nil, hasOlder: hasOlder,
            frozenTipCursor: frozen, frozenTipDigest: frozenDigest,
            prefixDigest: pageDigest,
            branchTip: request.branchTip,
            omissions: hasOlder
                ? [WorkServiceOmission(
                    category: "history", count: candidates.count - selected.count)]
                : [])
    }

    func fetchArtifact(_ request: WorkServiceArtifactRequest) async throws -> WorkServiceArtifactDescriptor {
        guard request.work == fixture.work,
              request.journal == fixture.workJournal,
              request.client == fixture.client else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard let artifact = artifactDescriptors.first(where: {
            $0.artifactID == request.artifactID
        }) else {
            throw WorkServiceProtocolError.artifactNotFound
        }
        if mode == .artifactIdentityMismatch {
            return try WorkServiceArtifactDescriptor(
                artifactID: artifact.artifactID, work: WorkRef(
                    workHostID: fixture.host.workHostID, workID: "foreign-work"),
                label: artifact.label, mediaType: artifact.mediaType,
                byteCount: artifact.byteCount, digest: artifact.digest,
                available: artifact.available, bodyReference: artifact.bodyReference,
                sourceEvent: EventRef(
                    journal: .work(
                        WorkRef(workHostID: fixture.host.workHostID, workID: "foreign-work"),
                        journalID: "foreign-artifact-journal"),
                    eventID: "foreign-artifact-event"),
                session: artifact.session, sessionAttachment: artifact.sessionAttachment,
                run: artifact.run)
        }
        return artifact
    }

    func fetchBody(_ request: WorkServiceBodyRequest) async throws -> WorkServiceBodyResponse {
        artifactBodyRequests.append(request)
        if let artifactBodyGate { await artifactBodyGate.enter() }
        guard let body = artifactBodies[request.reference] else {
            return WorkServiceBodyResponse(
                reference: request.reference, status: .unavailable, offset: request.offset)
        }
        if mode == .artifactUnavailable {
            return WorkServiceBodyResponse(
                reference: request.reference, status: .unavailable, offset: request.offset)
        }
        if mode == .artifactZeroProgress {
            return WorkServiceBodyResponse(
                reference: request.reference, status: .retained, offset: request.offset,
                data: Data(), nextOffset: request.offset)
        }
        let end = min(body.count, request.offset + request.limit)
        let malformedEnd = min(body.count, request.offset + request.limit + 1)
        let chunkEnd = mode == .artifactChunkTooLarge ? malformedEnd : end
        let chunk = body.subdata(in: request.offset..<chunkEnd)
        let next = end < body.count ? end : nil
        if mode == .artifactMalformed {
            return WorkServiceBodyResponse(
                reference: request.reference, status: .retained, offset: request.offset,
                data: chunk, nextOffset: next.map { $0 + 1 } ?? (end + 1))
        }
        if mode == .artifactDigestMismatch {
            let mismatched = TimelineBodyReference(
                authority: request.reference.authority, referenceID: request.reference.referenceID,
                mediaType: request.reference.mediaType, byteCount: request.reference.byteCount,
                digest: "sha256:" + String(repeating: "0", count: 64))
            return WorkServiceBodyResponse(
                reference: mismatched, status: .retained, offset: request.offset,
                data: chunk, nextOffset: next)
        }
        return WorkServiceBodyResponse(
            reference: request.reference, status: .retained, offset: request.offset,
            data: chunk, nextOffset: next)
    }

    func cancelAgentHandle(_ request: WorkServiceAgentHandleCancelRequest) async throws
        -> WorkServiceAgentHandleCancelResponse {
        throw WorkServiceProtocolError.invalidRequest("child cancellation is not modeled by this fixture")
    }

    func directShell(_ request: WorkServiceDirectShellRequest) async throws
        -> WorkServiceDirectShellResponse {
        directShellRequests.append(request)
        throw AttachedControllerTestError.unsupported
    }

    func command(_ request: WorkServiceCommandRequest) async throws -> WorkServiceCommandReceipt {
        commandRequests.append(request)
        if let commandGate { await commandGate.enter() }
        if mode == .remoteStale {
            throw WorkServiceTransportError.remote(code: .staleCursor, detail: nil)
        }
        if let prior = acceptedCommands[request.command.commandID] {
            return WorkServiceCommandReceipt(
                work: prior.work, commandID: prior.commandID, state: .duplicate,
                host: prior.host, hostSequence: prior.hostSequence,
                causalWorkCursor: prior.causalWorkCursor,
                resultingWorkCursor: prior.resultingWorkCursor,
                authorization: prior.authorization, outcome: prior.outcome)
        }
        if commandFailuresRemaining > 0 {
            commandFailuresRemaining -= 1
            throw AttachedControllerTestError.transport
        }
        let current = workEvents.last.map {
            JournalCursor(journal: fixture.workJournal, eventID: $0.eventID, sequence: $0.sequence)
        } ?? JournalCursor(journal: fixture.workJournal, sequence: 0)
        let authorization = fixture.authorization
        if request.causalWorkCursor != current {
            return WorkServiceCommandReceipt(
                work: fixture.work, commandID: request.command.commandID, state: .rejected,
                host: hostInstanceStorage, causalWorkCursor: request.causalWorkCursor,
                resultingWorkCursor: current, authorization: authorization,
                rejection: .staleCursor, diagnostic: "stale")
        }
        let resulting = JournalCursor(
            journal: fixture.workJournal, eventID: "command-\(commandRequests.count)",
            sequence: current.sequence + 1)
        let acceptedEvent: TimelineEvent
        if mode == .forgedAcceptedReceipt {
            acceptedEvent = TimelineEvent(
                eventID: resulting.eventID!, journal: fixture.workJournal,
                sequence: resulting.sequence, previousEventID: current.eventID,
                work: fixture.work, workHost: fixture.host,
                actor: TimelineActor(actorID: "controller-fixture", kind: "test"),
                hostRecordedAt: Date(), type: TimelineEventType.hostOrderObserved)
        } else {
            let canonicalCommand = WorkServiceCommandLedgerIdentity.command(
                from: request.command, client: request.command.client!)
            acceptedEvent = TimelineEvent(
                eventID: resulting.eventID!, journal: fixture.workJournal,
                sequence: resulting.sequence, hostSequence: commandRequests.count,
                idempotencyKey: canonicalCommand.commandID, command: canonicalCommand,
                previousEventID: current.eventID,
                causedByEventID: request.causalWorkCursor.eventID.map {
                    EventRef(journal: fixture.workJournal, eventID: $0)
                },
                session: fixture.session, work: fixture.work, workHost: fixture.host,
                client: request.command.client,
                sessionAttachment: request.command.sessionAttachment,
                actor: TimelineActor(actorID: "controller-fixture", kind: "test"),
                hostRecordedAt: Date(), type: TimelineEventType.commandAccepted)
        }
        workEvents.append(acceptedEvent)
        let receipt = WorkServiceCommandReceipt(
            work: fixture.work, commandID: request.command.commandID, state: .accepted,
                host: hostInstanceStorage, hostSequence: commandRequests.count,
            causalWorkCursor: request.causalWorkCursor, resultingWorkCursor: resulting,
            authorization: authorization, outcome: request.kind == .start ? .started : .inputAccepted)
        acceptedCommands[request.command.commandID] = receipt
        commandEffects += 1
        if let commandReceiptGate { await commandReceiptGate.enter() }
        if loseAcceptedResponsesRemaining > 0 {
            loseAcceptedResponsesRemaining -= 1
            throw AttachedControllerTestError.transport
        }
        return receipt
    }

    func advanceWorkCursor() {
        let prior = workEvents.last!
        workEvents.append(TimelineEvent(
            eventID: "work-\(workEvents.count + 1)", journal: fixture.workJournal,
            sequence: prior.sequence + 1, previousEventID: prior.eventID,
            work: fixture.work, workHost: fixture.host, actor: prior.actor,
            hostRecordedAt: Date(), type: TimelineEventType.hostOrderObserved))
    }

    func advanceSessionCursor() {
        let prior = sessionEvents.last!
        sessionEvents.append(TimelineEvent(
            eventID: "session-\(sessionEvents.count + 1)", journal: fixture.sessionJournal,
            sequence: prior.sequence + 1, previousEventID: prior.eventID,
            session: fixture.session, work: fixture.work, workHost: fixture.host,
            sessionAttachment: fixture.sessionAttachment, actor: prior.actor,
            hostRecordedAt: Date(), type: TimelineEventType.messageCommitted,
            payload: .object(["role": .string("assistant"), "text": .string("late message")]))
        )
    }

    func replaceWorkEvents(_ events: [TimelineEvent]) {
        workEvents = events
    }

    func replaceSessionEvents(_ events: [TimelineEvent]) {
        sessionEvents = events
    }

    private func events(for target: WorkServiceReadTarget) -> [TimelineEvent] {
        switch target {
        case .work: return workEvents
        case .session: return sessionEvents
        }
    }

    private func prefixDigest(_ events: [TimelineEvent], cursor: JournalCursor) -> String {
        if corruptPrefixDigests {
            return "sha256:" + String(repeating: "f", count: 64)
        }
        return attachedControllerPrefixDigest(events, cursor: cursor)
    }

    private func currentDescriptor() throws -> WorkServiceWorkDescriptor {
        let cursor = workEvents.last.map {
            JournalCursor(journal: fixture.workJournal, eventID: $0.eventID, sequence: $0.sequence)
        } ?? JournalCursor(journal: fixture.workJournal, sequence: 0)
        let reduced = WorkReducer.reduce(workEvents)
        let execution: WorkServiceExecutionState
        switch reduced.execution {
        case .idle: execution = .idle
        case .running: execution = .running
        case .held: execution = .held
        case .canceling: execution = .canceling
        case .unknown, .preparing, .failed: execution = .unknown
        }
        let observation = try fixture.descriptor.hostObservation.map {
            try WorkServiceHostObservation(
                instance: hostInstanceStorage, reachability: $0.reachability,
                currentRun: reduced.activeRun,
                currentRunSession: reduced.activeRunSession,
                currentRunSessionAttachment: reduced.activeRunSessionAttachment,
                servedCursor: cursor,
                sourceCompleteness: $0.sourceCompleteness)
        }
        let listedAttachments: [WorkServiceClientAttachment]
        var listedOmissions: [WorkServiceOmission]
        switch mode {
        case .missingAttachment:
            listedAttachments = []
            listedOmissions = []
        case .omittedAttachment:
            listedAttachments = []
            listedOmissions = [WorkServiceOmission(
                category: "attachments", count: fixture.descriptor.attachments.count)]
        default:
            listedAttachments = fixture.descriptor.attachments.map { attachment in
                guard attachment.attachment == fixture.clientAttachment else { return attachment }
                return WorkServiceClientAttachment(
                    attachment: attachment.attachment, client: attachment.client,
                    session: attachment.session, sessionJournal: attachment.sessionJournal,
                    sessionAttachment: attachment.sessionAttachment,
                    authorization: attachment.attachment == fixture.clientAttachment
                        ? attachmentAuthorization : attachment.authorization,
                    readAcknowledgements: readAcknowledgements.map {
                        WorkServiceReadAcknowledgement(target: $0.key, cursor: $0.value)
                    })
            }
            listedOmissions = fixture.descriptor.omissions
        }
        if mode == .artifactOmitted {
            listedOmissions.append(WorkServiceOmission(category: "artifacts", count: 1))
        }
        return try WorkServiceWorkDescriptor(
            work: fixture.descriptor.work, journal: fixture.descriptor.journal,
            recordedDisposition: fixture.descriptor.recordedDisposition,
            execution: descriptorExecutionOverride ?? execution, currentRun: reduced.activeRun,
            currentRunSession: reduced.activeRunSession,
            currentRunSessionAttachment: reduced.activeRunSessionAttachment,
            configuration: fixture.descriptor.configuration, hostObservation: observation,
            attachments: listedAttachments,
            sessionAttachments: {
                switch mode {
                case .artifactProducerRelationshipOmitted:
                    return fixture.descriptor.sessionAttachments.filter { relationship in
                        !artifactDescriptors.contains {
                            $0.session == relationship.session
                                && $0.sessionAttachment == relationship.sessionAttachment
                        }
                    }
                case .artifactProducerRelationshipDetached:
                    return fixture.descriptor.sessionAttachments.map { relationship in
                        let isProducer = artifactDescriptors.contains {
                            $0.session == relationship.session
                                && $0.sessionAttachment == relationship.sessionAttachment
                        }
                        return WorkServiceSessionAttachmentDescriptor(
                            session: relationship.session, sessionJournal: relationship.sessionJournal,
                            sessionAttachment: relationship.sessionAttachment,
                            publication: relationship.publication,
                            causalSessionCursor: relationship.causalSessionCursor,
                            sessionCursor: relationship.sessionCursor,
                            causalWorkCursor: relationship.causalWorkCursor,
                            resultingWorkCursor: relationship.resultingWorkCursor,
                            capabilities: relationship.capabilities,
                            isAttached: isProducer ? false : relationship.isAttached)
                    }
                default:
                    return fixture.descriptor.sessionAttachments
                }
            }(),
            artifacts: artifactDescriptors,
            omissions: listedOmissions)
    }

    private func responseHandshake() throws -> WorkServiceHandshakeResponse {
        let controlJournal = JournalRef.workHost(fixture.host)
        return WorkServiceHandshakeResponse(
            accepted: true, negotiatedVersion: WorkServiceProtocol.currentVersion,
            supportedRange: WorkServiceProtocol.minimumSupportedVersion ... WorkServiceProtocol.maximumSupportedVersion,
            host: fixture.host, hostInstance: hostInstanceStorage, controlJournal: controlJournal,
            controlCursor: controlCursorStorage,
            capabilities: hostCapabilities)
    }

    private func appendControlCursor() -> JournalCursor {
        let nextSequence = controlCursorStorage.sequence + 1
        controlCursorStorage = JournalCursor(
            journal: controlCursorStorage.journal,
            eventID: "control-\(nextSequence)", sequence: nextSequence)
        return controlCursorStorage
    }
}

private func makeAttachedController(
    fixture: AttachedControllerFixture,
    service: any WorkServiceClient,
    seed: WorkServiceAttachedWorkSeed? = nil,
    intentStore: WorkServiceAttachedWorkIntentStore? = nil,
    checkpointStore: (any WorkServiceAttachedWorkCheckpointStoring)? = nil,
    connect: WorkServiceAttachedWorkController.Connect? = nil,
    pageLimit: Int = 2,
    pageBytes: Int = WorkServiceBounds.maxEventPageBytes
) throws -> WorkServiceAttachedWorkController {
    let store = try intentStore ?? WorkServiceAttachedWorkIntentStore(
        url: FileManager.default.temporaryDirectory
            .appending(path: "aviary-controller-intent-\(UUID().uuidString).json"))
    return try WorkServiceAttachedWorkController(
        service: service, seed: seed ?? .created(fixture.response), intentStore: store,
        pageLimit: pageLimit, pageBytes: pageBytes,
        connect: connect, checkpointStore: checkpointStore)
}

private func attachedArtifactDigest(_ data: Data) -> String {
    "sha256:" + AviarySHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}

private func attachedArtifact(
    fixture: AttachedControllerFixture, id: String, mediaType: String, body: Data
) -> (WorkServiceArtifactDescriptor, TimelineBodyReference) {
    let digest = attachedArtifactDigest(body)
    let reference = TimelineBodyReference(
        authority: fixture.workJournal, referenceID: digest, mediaType: mediaType,
        byteCount: body.count, digest: digest)
    return (try! WorkServiceArtifactDescriptor(
        artifactID: id, work: fixture.work, label: id, mediaType: mediaType,
        byteCount: body.count, digest: digest, available: true,
        bodyReference: reference,
        sourceEvent: EventRef(journal: fixture.workJournal, eventID: "\(id)-event"),
        session: fixture.session, sessionAttachment: fixture.sessionAttachment,
        run: RunRef("controller-artifact-run")), reference)
}

private func attachedReviewArtifact(
    fixture: AttachedControllerFixture, id: String, turnID: String, body: Data
) -> (WorkServiceArtifactDescriptor, TimelineBodyReference) {
    let digest = attachedArtifactDigest(body)
    let reference = TimelineBodyReference(
        authority: fixture.workJournal, referenceID: digest,
        mediaType: ObservedRepositoryReviewFormat.mediaType,
        byteCount: body.count, digest: digest)
    let source = EventRef(journal: fixture.workJournal, eventID: "\(id)-event")
    return (try! WorkServiceArtifactDescriptor(
        artifactID: id, work: fixture.work, label: id,
        mediaType: ObservedRepositoryReviewFormat.mediaType,
        byteCount: body.count, digest: digest, available: true,
        bodyReference: reference, sourceEvent: source,
        session: fixture.session, sessionAttachment: fixture.sessionAttachment,
        run: RunRef("controller-review-run-\(turnID)"), turn: TurnRef(turnID),
        action: ActionRef("\(id)-action"), causedByEventID: source), reference)
}

private func configureAttachedArtifact(
    fixture: AttachedControllerFixture, service: AttachedControllerTestService,
    artifact: WorkServiceArtifactDescriptor, reference: TimelineBodyReference, body: Data
) async {
    await service.setArtifactDescriptors([artifact])
    await service.setArtifactBody(body, for: reference)
}

func testWorkServiceAttachedControllerFetchesLatestAuthorizedArtifactInChunks() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let body = Data(repeating: 0x61, count: WorkServiceBounds.maxBodyChunkBytes + 17)
    let (older, olderReference) = attachedArtifact(
        fixture: fixture, id: "older", mediaType: "text/plain", body: Data("old".utf8))
    let (latest, latestReference) = attachedArtifact(
        fixture: fixture, id: "latest", mediaType: "text/plain", body: body)
    await service.setArtifactDescriptors([older, latest])
    await service.setArtifactBody(Data("old".utf8), for: olderReference)
    await service.setArtifactBody(body, for: latestReference)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    _ = try await controller.refresh()

    let fetched = try await controller.fetchArtifactBody(mediaType: "text/plain")
    XCTAssertEqual(fetched.artifactID, "latest")
    XCTAssertEqual(fetched.reference, latestReference)
    XCTAssertEqual(fetched.data, body)
    XCTAssertEqual(await service.artifactBodyRequestCount(), 2)
}

func testWorkServiceAttachedControllerFetchesExactOlderReviewAndLatestReview() async throws {
    let fixture = try AttachedControllerFixture()
    let olderBody = Data("older review".utf8)
    let latestBody = Data("latest review".utf8)
    let (older, olderReference) = attachedReviewArtifact(
        fixture: fixture, id: "review-older", turnID: "turn-older", body: olderBody)
    let (latest, latestReference) = attachedReviewArtifact(
        fixture: fixture, id: "review-latest", turnID: "turn-latest", body: latestBody)
    let service = AttachedControllerTestService(fixture: fixture)
    await service.setArtifactDescriptors([older, latest])
    await service.setArtifactBody(olderBody, for: olderReference)
    await service.setArtifactBody(latestBody, for: latestReference)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    _ = try await controller.refresh()

    let fetchedOlder = try await controller.fetchArtifactBody(descriptor: older)
    XCTAssertEqual(fetchedOlder.artifactID, older.artifactID)
    XCTAssertEqual(fetchedOlder.data, olderBody)
    let fetchedLatest = try await controller.fetchArtifactBody(
        mediaType: ObservedRepositoryReviewFormat.mediaType)
    XCTAssertEqual(fetchedLatest.artifactID, latest.artifactID)
    XCTAssertEqual(fetchedLatest.data, latestBody)
    let history = await controller.repositoryReviewHistory(maxRows: 8)
    XCTAssertTrue(history.isAvailable)
    XCTAssertEqual(history.rows.map { $0.descriptor.artifactID }, [older.artifactID, latest.artifactID])

    let wrongAttachment = try WorkServiceArtifactDescriptor(
        artifactID: older.artifactID, work: older.work, label: older.label,
        mediaType: older.mediaType, byteCount: older.byteCount, digest: older.digest,
        available: older.available, bodyReference: older.bodyReference,
        sourceEvent: older.sourceEvent, session: older.session,
        sessionAttachment: SessionAttachmentRef("other-attachment"), run: older.run,
        turn: older.turn, action: older.action, causedByEventID: older.causedByEventID)
    do {
        _ = try await controller.fetchArtifactBody(descriptor: wrongAttachment)
        XCTFail("a descriptor for another Session attachment must be rejected")
    } catch WorkServiceAttachedArtifactLoadError.malformed {
        XCTAssertTrue(true)
    }
    let missing = try WorkServiceArtifactDescriptor(
        artifactID: "review-missing", work: latest.work, label: latest.label,
        mediaType: latest.mediaType, byteCount: latest.byteCount, digest: latest.digest,
        available: latest.available, bodyReference: latest.bodyReference,
        sourceEvent: latest.sourceEvent, session: latest.session,
        sessionAttachment: latest.sessionAttachment, run: latest.run, turn: latest.turn,
        action: latest.action, causedByEventID: latest.causedByEventID)
    do {
        _ = try await controller.fetchArtifactBody(descriptor: missing)
        XCTFail("a descriptor absent from the authenticated index must not be fetched")
    } catch WorkServiceAttachedArtifactLoadError.notFound {
        XCTAssertTrue(true)
    }
    do {
        _ = try await controller.fetchArtifactBody(
            descriptor: older, maxTotalBytes: olderBody.count - 1)
        XCTFail("an exact descriptor exceeding the body bound must be rejected")
    } catch WorkServiceAttachedArtifactLoadError.tooLarge {
        XCTAssertTrue(true)
    }

    let changed = try WorkServiceArtifactDescriptor(
        artifactID: older.artifactID, work: older.work, label: "replacement",
        mediaType: older.mediaType, byteCount: older.byteCount, digest: older.digest,
        available: older.available, bodyReference: older.bodyReference,
        sourceEvent: older.sourceEvent, session: older.session,
        sessionAttachment: older.sessionAttachment, run: older.run, turn: older.turn,
        action: older.action, causedByEventID: older.causedByEventID)
    await service.setArtifactDescriptors([changed, latest])
    _ = try await controller.refresh()
    do {
        _ = try await controller.fetchArtifactBody(descriptor: older)
        XCTFail("a replaced descriptor must not fetch under the older identity")
    } catch WorkServiceAttachedArtifactLoadError.malformed {
        XCTAssertTrue(true)
    }
    let denied = WorkServiceAuthorizationOutcome(
        requested: Set(WorkServiceCapability.allCases),
        granted: Set(WorkServiceCapability.allCases).subtracting([.inspectArtifacts]),
        denied: [.inspectArtifacts])
    await service.setAttachmentAuthorization(denied)
    _ = try await controller.refresh()
    do {
        _ = try await controller.fetchArtifactBody(descriptor: changed)
        XCTFail("an exact review fetch without inspect capability must be denied")
    } catch WorkServiceAttachedArtifactLoadError.capabilityDenied(.inspectArtifacts) {
        XCTAssertTrue(true)
    }
}

func testWorkServiceRepositoryReviewHistoryJoinsOnlyExactTurnRunAttachmentAndSessionJournal() throws {
    let fixture = try AttachedControllerFixture()
    let foreignFixture = try AttachedControllerFixture(workID: "foreign-work")
    let (older, _) = attachedReviewArtifact(
        fixture: fixture, id: "review-older", turnID: "turn-older", body: Data("old".utf8))
    let (latest, _) = attachedReviewArtifact(
        fixture: fixture, id: "review-latest", turnID: "turn-latest", body: Data("new".utf8))
    let (foreign, _) = attachedReviewArtifact(
        fixture: foreignFixture, id: "review-foreign", turnID: "turn-foreign", body: Data("foreign".utf8))
    let otherAttachment = try WorkServiceArtifactDescriptor(
        artifactID: "review-other-attachment", work: latest.work, label: "other attachment",
        mediaType: latest.mediaType, byteCount: latest.byteCount, digest: latest.digest,
        available: latest.available, bodyReference: latest.bodyReference,
        sourceEvent: latest.sourceEvent, session: latest.session,
        sessionAttachment: SessionAttachmentRef("other-attachment"), run: latest.run,
        turn: latest.turn, action: latest.action, causedByEventID: latest.causedByEventID)
    let olderSource = EventRef(journal: fixture.sessionJournal, eventID: "message-older")
    let latestSource = EventRef(journal: fixture.sessionJournal, eventID: "message-latest")
    let exactOlder = SessionMessageSnapshot(
        eventID: "message-older", role: "assistant", text: "old",
        sourceEvent: olderSource, run: older.run, turn: older.turn,
        sessionAttachment: older.sessionAttachment)
    let exactLatest = SessionMessageSnapshot(
        eventID: "message-latest", role: "assistant", text: "new",
        sourceEvent: latestSource, run: latest.run, turn: latest.turn,
        sessionAttachment: latest.sessionAttachment)
    let sameTurnDifferentRun = SessionMessageSnapshot(
        eventID: "message-foreign-run", role: "assistant", text: "wrong run",
        sourceEvent: EventRef(journal: fixture.sessionJournal, eventID: "message-foreign-run"),
        run: RunRef("foreign-run"), turn: latest.turn,
        sessionAttachment: latest.sessionAttachment)
    let mismatchedSourceCursor = SessionMessageSnapshot(
        eventID: "message-mismatched-cursor", role: "assistant", text: "wrong cursor",
        sourceEvent: latestSource,
        sourceCursor: JournalCursor(
            journal: fixture.sessionJournal, eventID: "different-source", sequence: 3),
        run: latest.run, turn: latest.turn, sessionAttachment: latest.sessionAttachment)
    let foreignSession = SessionMessageSnapshot(
        eventID: "message-foreign-session", role: "assistant", text: "wrong session",
        sourceEvent: EventRef(
            journal: JournalRef.session(
                SessionRef("foreign-session"), journalID: "foreign-session-journal",
                authority: TimelineAuthorityRef(fixture.host.workHostID)),
            eventID: "message-foreign-session"),
        run: latest.run, turn: latest.turn, sessionAttachment: latest.sessionAttachment)
    let key = try XCTUnwrap(WorkSessionKey(
        work: fixture.work, session: fixture.session,
        sessionJournal: fixture.sessionJournal, sessionAttachment: fixture.sessionAttachment))
    let history = WorkServiceRepositoryReviewHistory(
        workSession: key, descriptors: [foreign, otherAttachment, older, latest],
        messages: [
            exactOlder, exactLatest, sameTurnDifferentRun, mismatchedSourceCursor, foreignSession,
        ],
        artifactIndexComplete: true, maxRows: 8)
    XCTAssertTrue(history.isAvailable)
    XCTAssertEqual(history.rows.map { $0.descriptor.artifactID }, [older.artifactID, latest.artifactID])
    XCTAssertEqual(history.rows[0].transcriptSourceEvents, [olderSource])
    XCTAssertEqual(history.rows[1].transcriptSourceEvents, [latestSource])

    let changedOlder = try WorkServiceArtifactDescriptor(
        artifactID: older.artifactID, work: older.work, label: "changed older",
        mediaType: older.mediaType, byteCount: older.byteCount, digest: older.digest,
        available: older.available, bodyReference: older.bodyReference,
        sourceEvent: older.sourceEvent, session: older.session,
        sessionAttachment: older.sessionAttachment, run: older.run, turn: older.turn,
        action: older.action, causedByEventID: older.causedByEventID)
    let conflicting = WorkServiceRepositoryReviewHistory(
        workSession: key, descriptors: [older, changedOlder, latest], messages: [],
        artifactIndexComplete: true, maxRows: 8)
    XCTAssertFalse(conflicting.isAvailable)
    XCTAssertTrue(conflicting.rows.isEmpty)

    let capped = WorkServiceRepositoryReviewHistory(
        workSession: key, descriptors: [older, latest], messages: [],
        artifactIndexComplete: true, maxRows: 1)
    XCTAssertTrue(capped.isAvailable)
    XCTAssertEqual(capped.rows.count, 1)
    XCTAssertEqual(capped.omittedRowCount, 1)
    let unavailable = WorkServiceRepositoryReviewHistory(
        workSession: key, descriptors: [older, latest], messages: [],
        artifactIndexComplete: false, maxRows: 8)
    XCTAssertFalse(unavailable.isAvailable)
    XCTAssertTrue(unavailable.rows.isEmpty)
}

func testWorkServiceAttachedControllerRejectsArtifactProgressAndMetadataFailures() async throws {
    let fixture = try AttachedControllerFixture()
    let body = Data("artifact body".utf8)
    let (artifact, reference) = attachedArtifact(
        fixture: fixture, id: "artifact", mediaType: "application/json", body: body)
    for (modeIndex, mode) in [AttachedControllerServiceMode.artifactZeroProgress,
                 .artifactMalformed, .artifactDigestMismatch, .artifactIdentityMismatch].enumerated() {
        let service = AttachedControllerTestService(fixture: fixture)
        await configureAttachedArtifact(
            fixture: fixture, service: service, artifact: artifact,
            reference: reference, body: body)
        let controller = try makeAttachedController(fixture: fixture, service: service)
        _ = try await controller.refresh()
        await service.setMode(mode)
        do {
            _ = try await controller.fetchArtifactBody(mediaType: "application/json")
            XCTFail("malformed artifact response must fail closed (mode \(modeIndex))")
        } catch WorkServiceAttachedArtifactLoadError.malformed {
            XCTAssertTrue(true)
        }
    }

    let mediaService = AttachedControllerTestService(fixture: fixture)
    await configureAttachedArtifact(
        fixture: fixture, service: mediaService, artifact: artifact,
        reference: reference, body: body)
    let mediaController = try makeAttachedController(fixture: fixture, service: mediaService)
    _ = try await mediaController.refresh()
    do {
        _ = try await mediaController.fetchArtifactBody(mediaType: "application/\njson")
        XCTFail("control bytes in media types must be rejected")
    } catch WorkServiceAttachedArtifactLoadError.invalidOptions {
        XCTAssertTrue(true)
    }

    let largeBody = Data(repeating: 0x62, count: WorkServiceBounds.maxBodyChunkBytes + 1)
    let (largeArtifact, largeReference) = attachedArtifact(
        fixture: fixture, id: "large", mediaType: "application/octet-stream", body: largeBody)
    let chunkService = AttachedControllerTestService(fixture: fixture)
    await configureAttachedArtifact(
        fixture: fixture, service: chunkService, artifact: largeArtifact,
        reference: largeReference, body: largeBody)
    let chunkController = try makeAttachedController(fixture: fixture, service: chunkService)
    _ = try await chunkController.refresh()
    await chunkService.setMode(.artifactChunkTooLarge)
    do {
        _ = try await chunkController.fetchArtifactBody(mediaType: "application/octet-stream")
        XCTFail("a chunk larger than the requested limit must be malformed")
    } catch WorkServiceAttachedArtifactLoadError.malformed {
        XCTAssertTrue(true)
    }
}

func testWorkServiceAttachedControllerDistinguishesArtifactOmittedUnavailableAndTooLarge() async throws {
    let fixture = try AttachedControllerFixture()
    let body = Data("artifact body".utf8)
    let (artifact, reference) = attachedArtifact(
        fixture: fixture, id: "artifact", mediaType: "application/octet-stream", body: body)

    let omittedService = AttachedControllerTestService(fixture: fixture)
    await configureAttachedArtifact(
        fixture: fixture, service: omittedService, artifact: artifact,
        reference: reference, body: body)
    let omittedController = try makeAttachedController(
        fixture: fixture, service: omittedService)
    _ = try await omittedController.refresh()
    await omittedService.setMode(.artifactOmitted)
    _ = try await omittedController.refresh()
    XCTAssertEqual((await omittedController.projection()).descriptor.artifacts.last, artifact)
    do {
        _ = try await omittedController.fetchArtifactBody(mediaType: "application/octet-stream")
        XCTFail("a retained match in an omitted index cannot prove the latest artifact")
    } catch WorkServiceAttachedArtifactLoadError.omitted {
        XCTAssertTrue(true)
    }
    do {
        _ = try await omittedController.fetchArtifactBody(descriptor: artifact)
        XCTFail("an exact descriptor in an omitted index must remain unavailable")
    } catch WorkServiceAttachedArtifactLoadError.omitted {
        XCTAssertTrue(true)
    }
    await omittedService.setArtifactDescriptors([])
    _ = try await omittedController.refresh()
    do {
        _ = try await omittedController.fetchArtifactBody(mediaType: "application/octet-stream")
        XCTFail("an omitted artifact index must not be treated as not found")
    } catch WorkServiceAttachedArtifactLoadError.omitted {
        XCTAssertTrue(true)
    }

    let unavailableService = AttachedControllerTestService(fixture: fixture)
    await configureAttachedArtifact(
        fixture: fixture, service: unavailableService, artifact: artifact,
        reference: reference, body: body)
    let unavailableController = try makeAttachedController(
        fixture: fixture, service: unavailableService)
    _ = try await unavailableController.refresh()
    await unavailableService.setMode(.artifactUnavailable)
    do {
        _ = try await unavailableController.fetchArtifactBody(mediaType: "application/octet-stream")
        XCTFail("an unavailable body must be explicit")
    } catch WorkServiceAttachedArtifactLoadError.omitted {
        XCTAssertTrue(true)
    }

    let tooLargeController = try makeAttachedController(
        fixture: fixture, service: unavailableService)
    _ = try await tooLargeController.refresh()
    do {
        _ = try await tooLargeController.fetchArtifactBody(
            mediaType: "application/octet-stream", maxTotalBytes: body.count - 1)
        XCTFail("the descriptor byte count exceeds the caller bound")
    } catch WorkServiceAttachedArtifactLoadError.tooLarge {
        XCTAssertTrue(true)
    }

    let missingService = AttachedControllerTestService(fixture: fixture)
    let missingController = try makeAttachedController(
        fixture: fixture, service: missingService)
    _ = try await missingController.refresh()
    do {
        _ = try await missingController.fetchArtifactBody(mediaType: "application/octet-stream")
        XCTFail("a complete index with no matching artifact is not found")
    } catch WorkServiceAttachedArtifactLoadError.notFound {
        XCTAssertTrue(true)
    }
}

func testWorkServiceAttachedControllerFailsArtifactReadOnAttachmentOrCapabilityDrift() async throws {
    let fixture = try AttachedControllerFixture()
    let body = Data("artifact body".utf8)
    let (artifact, reference) = attachedArtifact(
        fixture: fixture, id: "artifact", mediaType: "text/plain", body: body)

    let detachService = AttachedControllerTestService(fixture: fixture)
    await configureAttachedArtifact(
        fixture: fixture, service: detachService, artifact: artifact,
        reference: reference, body: body)
    let detachController = try makeAttachedController(fixture: fixture, service: detachService)
    _ = try await detachController.refresh()
    let detachGate = AttachedControllerHistoryGate()
    await detachService.setArtifactBodyGate(detachGate)
    let detachTask = Task {
        try await detachController.fetchArtifactBody(mediaType: "text/plain")
    }
    await detachGate.waitUntilEntered()
    await detachService.setMode(.missingAttachment)
    _ = try await detachController.refresh()
    await detachGate.release()
    do {
        _ = try await detachTask.value
        XCTFail("detachment during body fetch must fail closed")
    } catch WorkServiceAttachedArtifactLoadError.incomplete {
        XCTAssertTrue(true)
    }

    let capabilityService = AttachedControllerTestService(fixture: fixture)
    await configureAttachedArtifact(
        fixture: fixture, service: capabilityService, artifact: artifact,
        reference: reference, body: body)
    let capabilityController = try makeAttachedController(
        fixture: fixture, service: capabilityService)
    _ = try await capabilityController.refresh()
    let capabilityGate = AttachedControllerHistoryGate()
    await capabilityService.setArtifactBodyGate(capabilityGate)
    let capabilityTask = Task {
        try await capabilityController.fetchArtifactBody(mediaType: "text/plain")
    }
    await capabilityGate.waitUntilEntered()
    let denied = WorkServiceAuthorizationOutcome(
        requested: Set(WorkServiceCapability.allCases), granted: [.observe], denied: [.inspectArtifacts])
    await capabilityService.setAttachmentAuthorization(denied)
    _ = try await capabilityController.refresh()
    await capabilityGate.release()
    do {
        _ = try await capabilityTask.value
        XCTFail("capability mutation during body fetch must fail closed")
    } catch WorkServiceAttachedArtifactLoadError.capabilityDenied(.inspectArtifacts) {
        XCTAssertTrue(true)
    }
}

func testWorkServiceAttachedControllerReadsArtifactFromTerminalWork() async throws {
    let fixture = try AttachedControllerFixture(disposition: .completed)
    let body = Data("terminal artifact".utf8)
    let (artifact, reference) = attachedArtifact(
        fixture: fixture, id: "terminal-artifact", mediaType: "text/plain", body: body)
    let service = AttachedControllerTestService(fixture: fixture)
    await configureAttachedArtifact(
        fixture: fixture, service: service, artifact: artifact,
        reference: reference, body: body)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    let projection = try await controller.refresh()
    XCTAssertEqual(projection.descriptor.recordedDisposition, .completed)
    XCTAssertEqual(try await controller.fetchArtifactBody(mediaType: "text/plain").data, body)
}

func testWorkServiceAttachedControllerAllowsSessionBToInspectSessionAReviewAfterProducerDetach() async throws {
    let base = try AttachedControllerFixture(workID: "cross-session-artifact")
    let producer = SessionRef("producer-session-a")
    let producerAttachment = SessionAttachmentRef("producer-attachment-a")
    let review = await ObservedRepositoryReviewer(commandRunner: { _, _, _ in
        ObservedRepositoryGitCommandResult(exitCode: 128)
    }).observe(
        cwd: FileManager.default.temporaryDirectory,
        runID: "producer-run-a", turnID: "producer-turn-a",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let body = try review.encoded()
    let digest = attachedArtifactDigest(body)
    let reference = TimelineBodyReference(
        authority: base.workJournal, referenceID: digest,
        mediaType: ObservedRepositoryReviewFormat.mediaType,
        byteCount: body.count, digest: digest)
    let artifact = try WorkServiceArtifactDescriptor(
        artifactID: "producer-a-review", work: base.work, label: "producer review",
        mediaType: ObservedRepositoryReviewFormat.mediaType,
        byteCount: body.count, digest: digest, available: true,
        bodyReference: reference,
        sourceEvent: EventRef(journal: base.workJournal, eventID: "producer-a-artifact"),
        session: producer, sessionAttachment: producerAttachment,
        run: RunRef("producer-run-a"), turn: TurnRef("producer-turn-a"),
        action: ActionRef("producer-action-a"),
        causedByEventID: EventRef(journal: base.workJournal, eventID: "producer-a-action-start"))

    for mode in [
        AttachedControllerServiceMode.artifactProducerRelationshipOmitted,
        .artifactProducerRelationshipDetached,
    ] {
        let fixture = try AttachedControllerFixture(
            workID: "cross-session-artifact", artifacts: [artifact])
        let service = AttachedControllerTestService(fixture: fixture)
        await configureAttachedArtifact(
            fixture: fixture, service: service, artifact: artifact,
            reference: reference, body: body)
        await service.setMode(mode)
        let controller = try makeAttachedController(fixture: fixture, service: service)
        _ = try await controller.refresh()
        let fetched = try await controller.fetchArtifactBody(
            mediaType: ObservedRepositoryReviewFormat.mediaType)
        XCTAssertEqual(fetched.artifactID, artifact.artifactID)
        XCTAssertEqual(fetched.data, body)
    }
}

func testWorkServiceConversationIdentityChangeSeparatesPrependAndTail() {
    XCTAssertEqual(
        WorkServiceConversationIdentityChange.classify(old: [], new: ["a"]),
        .appended(count: 1))
    XCTAssertEqual(
        WorkServiceConversationIdentityChange.classify(old: ["b", "c"], new: ["a", "b", "c"]),
        .prepended(count: 1, anchorID: "b"))
    XCTAssertEqual(
        WorkServiceConversationIdentityChange.classify(
            old: ["b", "c"], new: ["a", "b", "c", "d"]),
        .prependedAndAppended(prepended: 1, appended: 1, anchorID: "b"))
    XCTAssertEqual(
        WorkServiceConversationIdentityChange.classify(old: ["a"], new: ["a", "b", "c"]),
        .appended(count: 2))
    XCTAssertEqual(
        WorkServiceConversationIdentityChange.classify(
            old: ["c", "d", "e", "f"], new: ["a", "b", "c", "d"]),
        .prepended(count: 2, anchorID: "c"))
    XCTAssertEqual(
        WorkServiceConversationIdentityChange.classify(
            old: ["a", "b", "c", "d"], new: ["c", "d", "e", "f"]),
        .appended(count: 2))
    XCTAssertEqual(
        WorkServiceConversationIdentityChange.classify(
            old: ["shared", "old"], new: ["shared", "new"]),
        .replaced)
    XCTAssertEqual(
        WorkServiceConversationIdentityChange.classify(old: ["a", "b"], new: ["b", "a"]),
        .replaced)
    XCTAssertEqual(
        WorkServiceConversationIdentityChange.classify(old: ["a", "b"], new: ["a", "b"]),
        .unchanged)
}

func testWorkServiceAttachedControllerCreatesRefreshesAndProjectsVisibleConversation() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    let projection = try await controller.refresh()

    XCTAssertTrue(projection.isCanonical)
    XCTAssertEqual(projection.workSnapshot.work, fixture.work)
    XCTAssertEqual(projection.sessionSnapshot.session, fixture.session)
    XCTAssertEqual(projection.visibleMessages.map(\.role), ["user", "assistant"])
    XCTAssertEqual(projection.visibleMessages.map(\.text), ["hello from the GUI", "hello back"])
    let user = try XCTUnwrap(projection.visibleMessages.first)
    XCTAssertEqual(user.sourceEvent,
                   EventRef(journal: fixture.sessionJournal, eventID: "session-3"))
    XCTAssertEqual(user.hostRecordedAt, Date(timeIntervalSince1970: 3))
    XCTAssertEqual(user.actor?.actorID, "controller-fixture")
    let assistant = try XCTUnwrap(projection.visibleMessages.last)
    XCTAssertEqual(assistant.sourceEvent,
                   EventRef(journal: fixture.sessionJournal, eventID: "session-4"))
    XCTAssertEqual(assistant.hostRecordedAt, Date(timeIntervalSince1970: 4))
    XCTAssertEqual(assistant.actor?.actorID, "controller-fixture")
    XCTAssertEqual(projection.workCursor.sequence, 2)
    XCTAssertEqual(projection.sessionCursor.sequence, 4)
    XCTAssertNotEqual(projection.workCursor, projection.sessionCursor)
    XCTAssertEqual(projection.attachment.sessionAttachment, fixture.sessionAttachment)
    XCTAssertTrue(projection.capabilities.contains(.send))
}

func testWorkServiceAttachedControllerConsumesReferenceServiceCreateResponse() async throws {
    let host = WorkHostRef("controller-reference-host")
    let client = ClientRef("controller-reference-client")
    let granted = Set(WorkServiceCapability.allCases)
    let service = InMemoryWorkService(
        host: host,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: granted]))
    let controlJournal = JournalRef.workHost(host)
    let response = try await service.createWork(WorkServiceCreateWorkRequest(
        client: client, commandID: "reference-create",
        causalControlCursor: JournalCursor(journal: controlJournal, sequence: 0),
        requestedCapabilities: granted))
    let controller = try WorkServiceAttachedWorkController(
        service: service, seed: .created(response),
        intentStore: WorkServiceAttachedWorkIntentStore(
            url: FileManager.default.temporaryDirectory
                .appending(path: "aviary-controller-intent-\(UUID().uuidString).json")),
        pageLimit: 2)

    let projection = try await controller.refresh()
    XCTAssertTrue(projection.isCanonical)
    XCTAssertEqual(projection.workSnapshot.lifecycle, .active)
    XCTAssertEqual(projection.sessionSnapshot.lifecycle, .active)
    XCTAssertEqual(
        projection.sessionSnapshot.attachments[response.sessionAttachment.attachmentID]?.work,
        response.work.work)
    XCTAssertEqual(projection.workCursor, response.workCursor)
    XCTAssertEqual(projection.sessionCursor, response.sessionCursor)
    let inventory = try XCTUnwrap(projection.usageInventory)
    XCTAssertEqual(inventory.work, response.work.work)
    XCTAssertEqual(inventory.combinedAvailability, .complete)
    XCTAssertEqual(inventory.direct?.startedCrossings, 0)
    XCTAssertEqual(inventory.childrenTotal?.startedCrossings, 0)
    XCTAssertEqual(inventory.combined?.startedCrossings, 0)
}

func testWorkServiceAttachedControllerAcceptsExactStandaloneEventByteBoundary() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let allEvents = fixture.workEvents + fixture.sessionEvents
    let largestEventBytes = try allEvents.map {
        try WorkServiceEventPageSizing.encodedByteCount(of: $0)
    }.max()
    let pageBytes = try XCTUnwrap(largestEventBytes)
    let largestEvent = try XCTUnwrap(allEvents.first { event in
        guard let count = try? WorkServiceEventPageSizing.encodedByteCount(of: event) else {
            return false
        }
        return count == pageBytes
    })
    XCTAssertTrue(try JSONEncoder().encode([largestEvent]).count > pageBytes)

    let controller = try makeAttachedController(
        fixture: fixture, service: service, pageLimit: 1, pageBytes: pageBytes)
    let projection = try await controller.refresh()

    XCTAssertTrue(projection.isCanonical)
    XCTAssertEqual(projection.workCursor.sequence, fixture.workEvents.count)
    XCTAssertEqual(projection.sessionCursor.sequence, fixture.sessionEvents.count)
}

func testWorkServiceAttachedControllerExistingDescriptorRequiresExactBoundSession() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let invalid = WorkServiceClientAttachment(
        attachment: fixture.clientAttachment, client: fixture.client, session: nil,
        sessionJournal: nil, sessionAttachment: nil, authorization: fixture.authorization)
    do {
        _ = try makeAttachedController(
            fixture: fixture, service: service,
            seed: .existing(work: fixture.descriptor, attachment: invalid))
        XCTFail("an existing descriptor cannot guess a Session")
    } catch WorkServiceAttachedWorkControllerError.invalidSeed {
        XCTAssertTrue(true)
    }
}

func testWorkServiceAttachedControllerLeavesPriorProjectionOnMalformedPage() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    let initial = try await controller.refresh()
    await service.setMode(.foreignPage)
    await service.advanceSessionCursor()
    await service.advanceSessionCursor()
    await service.advanceSessionCursor()
    do {
        _ = try await controller.refresh()
        XCTFail("foreign event page must be rejected")
    } catch WorkServiceAttachedWorkControllerError.malformedResponse {
        let after = await controller.projection()
        XCTAssertEqual(after.workCursor, initial.workCursor)
        XCTAssertEqual(after.sessionCursor, initial.sessionCursor)
        XCTAssertEqual(after.visibleMessages, initial.visibleMessages)
        XCTAssertEqual(after.workSourceCompleteness, .incomplete)
        XCTAssertFalse(after.isCanonical)
        XCTAssertTrue(after.readDiagnostics.contains {
            $0.contains("malformed")
        })
    }
}

func testWorkServiceAttachedControllerRejectsRepeatedAndTruncatedPages() async throws {
    let fixture = try AttachedControllerFixture()
    let repeatedService = AttachedControllerTestService(fixture: fixture)
    let repeatedController = try makeAttachedController(
        fixture: fixture, service: repeatedService, pageLimit: 1)
    await repeatedService.setMode(.repeatedPage)
    do {
        _ = try await repeatedController.refresh()
        XCTFail("repeated page must not make progress")
    } catch WorkServiceAttachedWorkControllerError.malformedResponse {
        XCTAssertEqual((await repeatedController.projection()).workCursor.sequence, 0)
    }

    let truncatedService = AttachedControllerTestService(fixture: fixture)
    let truncatedController = try makeAttachedController(
        fixture: fixture, service: truncatedService, pageLimit: 1)
    await truncatedService.setMode(.truncatedPage)
    do {
        _ = try await truncatedController.refresh()
        XCTFail("an omission without a continuation cursor must fail closed")
    } catch WorkServiceAttachedWorkControllerError.sourceIncomplete {
        XCTAssertEqual((await truncatedController.projection()).sessionCursor.sequence, 0)
    }
}

func testWorkServiceAttachedControllerUsesLatestCursorAndRetainsStaleCommandWithoutReplay() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    _ = try await controller.refresh()
    await service.advanceWorkCursor()

    let receipt = try await controller.start("stale prompt", commandID: "stale-start")
    XCTAssertEqual(receipt.state, .rejected)
    XCTAssertEqual(receipt.rejection, .staleCursor)
    let pending = await controller.pendingCommand()
    XCTAssertEqual(pending?.state, .stale)
    XCTAssertEqual(pending?.commandID, "stale-start")
    XCTAssertEqual(pending?.causalWorkCursor.sequence, 2)
    XCTAssertEqual(await service.commandCount(), 1)

    // Refresh is read-only reconciliation: it catches up the canonical cursor but does not
    // redispatch the stale request.
    await service.setMode(.normal)
    _ = try await controller.refresh()
    XCTAssertEqual(await service.commandCount(), 1)
    XCTAssertEqual((await controller.pendingCommand())?.causalWorkCursor.sequence, 2)
    try await controller.abandonStaleCommand()
    let replacement = try await controller.start(
        "stale prompt", commandID: "stale-start-replacement")
    XCTAssertEqual(replacement.state, .accepted)
    XCTAssertEqual(await service.commandCount(), 2)
    XCTAssertEqual((await service.lastCommand())?.value, "stale prompt")
    let awaitingRefresh = await controller.projection()
    XCTAssertFalse(awaitingRefresh.isCanonical)
    XCTAssertTrue(awaitingRefresh.requiresRefresh)
    XCTAssertEqual(awaitingRefresh.pendingCommand?.state, .awaitingCanonicalEvidence)
    XCTAssertFalse(awaitingRefresh.needsRecovery)
    do {
        _ = try await controller.start("too early", commandID: "before-refresh")
        XCTFail("a forward receipt must fence the known-old cursor")
    } catch WorkServiceAttachedWorkControllerError.pendingCommandExists {
        XCTAssertEqual(await service.commandCount(), 2)
    }
    XCTAssertTrue((try await controller.refresh()).isCanonical)
    XCTAssertNil(await controller.pendingCommand())
}

func testWorkServiceAttachedControllerRetainsIndeterminateCommandUntilExplicitRetry() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    _ = try await controller.refresh()
    await service.failNextCommand()
    do {
        _ = try await controller.start("durable prompt", commandID: "indeterminate-start")
        XCTFail("transport failure should be surfaced")
    } catch WorkServiceAttachedWorkControllerError.transportFailure {
        let pending = await controller.pendingCommand()
        XCTAssertEqual(pending?.state, .indeterminate)
        XCTAssertEqual(pending?.commandID, "indeterminate-start")
        XCTAssertEqual(await service.commandCount(), 1)
    }
    _ = try await controller.retryPendingCommand()
    XCTAssertEqual((await controller.pendingCommand())?.state, .awaitingCanonicalEvidence)
    XCTAssertEqual(await service.commandCount(), 2)
    XCTAssertEqual((await service.lastCommand())?.value, "durable prompt")
    let awaitingRefresh = await controller.projection()
    XCTAssertFalse(awaitingRefresh.isCanonical)
    XCTAssertTrue(awaitingRefresh.requiresRefresh)
    XCTAssertFalse(awaitingRefresh.needsRecovery)
    XCTAssertTrue((try await controller.refresh()).isCanonical)
    XCTAssertNil(await controller.pendingCommand())
}

func testWorkServiceAttachedControllerDistinguishesInFlightFromLostResponse() async throws {
    for fails in [false, true] {
        let fixture = try AttachedControllerFixture()
        let service = AttachedControllerTestService(fixture: fixture)
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "aviary-inflight-intent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = try WorkServiceAttachedWorkIntentStore(url: storeURL)
        let controller = try makeAttachedController(fixture: fixture, service: service, intentStore: store)
        _ = try await controller.refresh()
        let gate = AttachedControllerHistoryGate()
        await service.setCommandGate(gate)
        if fails { await service.failNextCommand() }
        let task = Task { try await controller.start("saved input", commandID: "gated-input") }
        await gate.waitUntilEntered()
        let waiting = try await controller.refresh()
        XCTAssertTrue(waiting.commandInFlight, "read-only polling must retain the original call's lifetime")
        XCTAssertEqual(waiting.pendingCommand?.state, .indeterminate,
                       "the crash-safe durable intent must not claim acceptance")
        XCTAssertTrue(waiting.isCanonical, "a pending call is not itself source corruption")
        let reopened = try makeAttachedController(fixture: fixture, service: service, intentStore: store)
        let restored = await reopened.projection()
        XCTAssertFalse(restored.commandInFlight, "disk restoration must not invent a live transport call")
        XCTAssertEqual(restored.pendingCommand?.state, .indeterminate)
        do {
            _ = try await controller.retryPendingCommand()
            XCTFail("a second transport attempt must not race the original in-flight call")
        } catch WorkServiceAttachedWorkControllerError.pendingCommandExists { }
        XCTAssertEqual(await service.commandCount(), 1)
        await gate.release()
        do {
            let receipt = try await task.value
            XCTAssertFalse(fails)
            XCTAssertEqual(receipt.state, .accepted)
        } catch WorkServiceAttachedWorkControllerError.transportFailure {
            XCTAssertTrue(fails)
        }
        let settled = await controller.projection()
        XCTAssertFalse(settled.commandInFlight, "both success and transport failure end the local request lifetime")
        XCTAssertEqual(settled.pendingCommand?.state, fails ? .indeterminate : .awaitingCanonicalEvidence)
        _ = try await controller.refresh()
        XCTAssertEqual(await service.commandCount(), 1, "refresh never replays the request")
        XCTAssertEqual((await controller.pendingCommand())?.state, fails ? .indeterminate : nil)
    }
}

func testWorkServiceAttachedControllerAcceptanceReadCannotOrphanInFlightIntent() async throws {
    for losesResponse in [false, true] {
        let fixture = try AttachedControllerFixture()
        let service = AttachedControllerTestService(fixture: fixture)
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "aviary-receipt-race-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = try WorkServiceAttachedWorkIntentStore(url: storeURL)
        let controller = try makeAttachedController(fixture: fixture, service: service, intentStore: store)
        _ = try await controller.refresh()
        let gate = AttachedControllerHistoryGate()
        await service.setCommandReceiptGate(gate)
        if losesResponse { await service.loseNextAcceptedResponse() }
        let task = Task { try await controller.start("first input", commandID: "acceptance-before-response") }
        await gate.waitUntilEntered()
        let observed = try await controller.refresh()
        XCTAssertTrue(observed.commandInFlight)
        XCTAssertEqual(observed.workSnapshot.commands.count, 1, "the acceptance is already visible")
        XCTAssertNotNil(observed.pendingCommand, "the original response still owns its intent transition")
        await gate.release()
        do {
            let receipt = try await task.value
            XCTAssertFalse(losesResponse)
            XCTAssertEqual(receipt.state, .accepted)
        } catch WorkServiceAttachedWorkControllerError.transportFailure {
            XCTAssertTrue(losesResponse)
        }
        let reconciled = try await controller.refresh()
        XCTAssertFalse(reconciled.commandInFlight)
        XCTAssertNil(reconciled.pendingCommand)
        XCTAssertEqual(await service.commandCount(), 1, "canonical catch-up must not replay the request")
        await service.setCommandReceiptGate(nil)
        let second = try await controller.start("second input", commandID: "after-reconciliation")
        XCTAssertEqual(second.state, .accepted, "no orphaned on-disk intent may block the next input")
        _ = try await controller.refresh()
        XCTAssertNil(await controller.pendingCommand())
        XCTAssertEqual(await service.commandEffectCount(), 2)
    }
}

func testWorkServiceAttachedControllerRetriesExactIndeterminateStartThroughRecoveryDescriptor()
    async throws {
    let fixture = try AttachedControllerFixture(workID: "exact-start-recovery")
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    _ = try await controller.refresh()
    await service.failNextCommand()
    do {
        _ = try await controller.start("retained prompt", commandID: "retained-start")
        XCTFail("transport failure should retain the exact Start")
    } catch WorkServiceAttachedWorkControllerError.transportFailure {
        XCTAssertEqual((await controller.pendingCommand())?.state, .indeterminate)
    }
    await service.setDescriptorExecutionOverride(.recoveryRequired)
    let recovered = try await controller.refresh()
    XCTAssertTrue(recovered.isCanonical)
    XCTAssertTrue(recovered.needsRecovery)
    let recoveryControls = ServiceBackedGUIControlPolicy(projection: recovered)
    XCTAssertTrue(recoveryControls.canRetryPendingCommand(kind: .start))
    XCTAssertFalse(recoveryControls.canSubmitText)
    XCTAssertFalse(recoveryControls.canRetryPendingCommand(kind: .send))
    XCTAssertEqual(await service.commandCount(), 1)

    let receipt = try await controller.retryPendingCommand()
    XCTAssertEqual(receipt.state, .accepted)
    XCTAssertEqual(await service.commandCount(), 2)
    XCTAssertEqual((await service.lastCommand())?.kind, .start)
    XCTAssertEqual((await service.lastCommand())?.command.commandID, "retained-start")
    XCTAssertEqual((await service.lastCommand())?.value, "retained prompt")

    let changedFixture = try AttachedControllerFixture(workID: "changed-start-recovery")
    let changedService = AttachedControllerTestService(fixture: changedFixture)
    let changedController = try makeAttachedController(
        fixture: changedFixture, service: changedService)
    _ = try await changedController.refresh()
    await changedService.failNextCommand()
    do {
        _ = try await changedController.start("retained prompt", commandID: "retained-start")
        XCTFail("transport failure should retain the exact Start")
    } catch WorkServiceAttachedWorkControllerError.transportFailure {
        XCTAssertTrue(true)
    }
    await changedService.advanceWorkCursor()
    await changedService.setDescriptorExecutionOverride(.recoveryRequired)
    let changedProjection = try await changedController.refresh()
    XCTAssertFalse(ServiceBackedGUIControlPolicy(projection: changedProjection)
        .canRetryPendingCommand(kind: .start))
    do {
        _ = try await changedController.retryPendingCommand()
        XCTFail("a retained Start at an older causal cursor must remain fenced")
    } catch WorkServiceAttachedWorkControllerError.recoveryRequired {
        XCTAssertEqual(await changedService.commandCount(), 1)
    }
}

func testWorkServiceAttachedControllerPersistsRemoteStaleForRecreationAndReissue() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-controller-remote-stale-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkServiceAttachedWorkIntentStore(
        url: root.appending(path: "pending.json", directoryHint: .notDirectory))
    var first: WorkServiceAttachedWorkController? = try makeAttachedController(
        fixture: fixture, service: service, intentStore: store)
    _ = try await first?.refresh()
    await service.setMode(.remoteStale)
    do {
        _ = try await first?.start("remote stale prompt", commandID: "remote-stale")
        XCTFail("transport stale response must be classified as stale")
    } catch WorkServiceAttachedWorkControllerError.staleCursor {
        XCTAssertEqual((await first?.pendingCommand())?.state, .stale)
    }
    first = nil

    let replacement = try makeAttachedController(
        fixture: fixture, service: service, intentStore: store)
    XCTAssertEqual((await replacement.pendingCommand())?.state, .stale)
    _ = try await replacement.refresh()
    try await replacement.abandonStaleCommand()
    await service.setMode(.normal)
    let receipt = try await replacement.start(
        "remote stale prompt", commandID: "remote-stale-reissued")
    XCTAssertEqual(receipt.state, .accepted)
    XCTAssertEqual((await service.lastCommand())?.command.commandID, "remote-stale-reissued")
}

func testWorkServiceAttachedControllerRestoresExactIndeterminateIntentAfterRecreation() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-controller-restart-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkServiceAttachedWorkIntentStore(
        url: root.appending(path: "pending.json", directoryHint: .notDirectory))
    var first: WorkServiceAttachedWorkController? = try makeAttachedController(
        fixture: fixture, service: service, intentStore: store)
    _ = try await first?.refresh()
    await service.loseNextAcceptedResponse()
    do {
        _ = try await first?.start("survives GUI death", commandID: "durable-start")
        XCTFail("lost accepted response must remain indeterminate")
    } catch WorkServiceAttachedWorkControllerError.transportFailure {
        XCTAssertEqual((await first?.pendingCommand())?.state, .indeterminate)
    }
    XCTAssertEqual(await service.commandEffectCount(), 1)
    first = nil

    let replacement = try makeAttachedController(
        fixture: fixture, service: service, intentStore: store)
    XCTAssertEqual((await replacement.pendingCommand())?.commandID, "durable-start")
    XCTAssertEqual((await replacement.pendingCommand())?.valueDigest,
                   "sha256:" + AviarySHA256.hash(data: Data("survives GUI death".utf8))
                    .map { String(format: "%02x", $0) }.joined())
    _ = try await replacement.refresh() // exact canonical evidence; never redispatches
    XCTAssertEqual(await service.commandCount(), 1)
    XCTAssertNil(await replacement.pendingCommand())
    XCTAssertEqual(await service.commandEffectCount(), 1)
}

func testWorkServiceAttachedControllerClearsSharedIntentIdempotentlyAcrossGUIs() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-controller-shared-intent-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkServiceAttachedWorkIntentStore(
        url: root.appending(path: "pending.json", directoryHint: .notDirectory))
    var origin: WorkServiceAttachedWorkController? = try makeAttachedController(
        fixture: fixture, service: service, intentStore: store)
    _ = try await origin?.refresh()
    await service.loseNextAcceptedResponse()
    do {
        _ = try await origin?.start("shared exact intent", commandID: "shared-start")
        XCTFail("the first response is deliberately lost")
    } catch WorkServiceAttachedWorkControllerError.transportFailure {}
    origin = nil

    let observerA = try makeAttachedController(
        fixture: fixture, service: service, intentStore: store)
    let observerB = try makeAttachedController(
        fixture: fixture, service: service, intentStore: store)
    XCTAssertEqual((await observerA.pendingCommand())?.commandID, "shared-start")
    XCTAssertEqual((await observerB.pendingCommand())?.commandID, "shared-start")
    XCTAssertTrue((try await observerA.refresh()).isCanonical)
    XCTAssertTrue((try await observerB.refresh()).isCanonical)
    XCTAssertNil(await observerA.pendingCommand())
    XCTAssertNil(await observerB.pendingCommand())
    XCTAssertEqual(await service.commandEffectCount(), 1)
    let final = try makeAttachedController(
        fixture: fixture, service: service, intentStore: store)
    XCTAssertNil(await final.pendingCommand())
}

func testWorkServiceAttachedControllerKeepsAcceptedIntentUntilExactCanonicalEvidence() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    _ = try await controller.refresh()
    await service.setMode(.forgedAcceptedReceipt)

    let receipt = try await controller.start("must be canonical", commandID: "forged-accept")
    XCTAssertEqual(receipt.state, .accepted)
    let awaiting = try XCTUnwrap(await controller.pendingCommand())
    XCTAssertEqual(awaiting.state, .awaitingCanonicalEvidence)
    XCTAssertEqual(awaiting.expectedResultingWorkCursor, receipt.resultingWorkCursor)
    XCTAssertEqual(awaiting.expectedHostSequence, receipt.hostSequence)
    do {
        _ = try await controller.retryPendingCommand()
        XCTFail("an accepted command awaiting evidence must never be redispatched")
    } catch WorkServiceAttachedWorkControllerError.sourceIncomplete {
        XCTAssertTrue(true)
    }
    do {
        _ = try await controller.refresh()
        XCTFail("an unrelated event at the receipt cursor is not command evidence")
    } catch WorkServiceAttachedWorkControllerError.sourceIncomplete {
        XCTAssertEqual((await controller.pendingCommand())?.state, .awaitingCanonicalEvidence)
        XCTAssertEqual(await service.commandEffectCount(), 1)
    }
}

func testWorkServiceAttachedControllerCompletedWorkRemainsInspectableButRejectsMutation() async throws {
    let fixture = try AttachedControllerFixture(disposition: .completed)
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    let projection = try await controller.refresh()
    XCTAssertTrue(projection.isCanonical)
    XCTAssertEqual(projection.descriptor.recordedDisposition, .completed)
    do {
        _ = try await controller.start("terminal prompt", commandID: "terminal-start")
        XCTFail("completed Work must reject local mutation admission")
    } catch WorkServiceAttachedWorkControllerError.terminalWork {
        XCTAssertEqual(await service.commandCount(), 0)
    }
}

func testWorkServiceAttachedControllerMissingAttachmentDisablesMutation() async throws {
    let seedFixture = try AttachedControllerFixture(workID: "missing-seed-validation")
    let absentSeed = try WorkServiceWorkDescriptor(
        work: seedFixture.descriptor.work, journal: seedFixture.descriptor.journal,
        recordedDisposition: seedFixture.descriptor.recordedDisposition,
        execution: seedFixture.descriptor.execution, currentRun: nil,
        currentRunSession: nil, currentRunSessionAttachment: nil,
        configuration: seedFixture.descriptor.configuration,
        hostObservation: seedFixture.descriptor.hostObservation, attachments: [],
        sessionAttachments: seedFixture.descriptor.sessionAttachments,
        artifacts: seedFixture.descriptor.artifacts, omissions: [])
    do {
        _ = try makeAttachedController(
            fixture: seedFixture, service: AttachedControllerTestService(fixture: seedFixture),
            seed: .existing(work: absentSeed, attachment: seedFixture.response.attachment))
        XCTFail("a complete seed with no attachment omission must name one current row")
    } catch WorkServiceAttachedWorkControllerError.invalidSeed {}

    let omittedSeed = try WorkServiceWorkDescriptor(
        work: absentSeed.work, journal: absentSeed.journal,
        recordedDisposition: absentSeed.recordedDisposition, execution: absentSeed.execution,
        currentRun: nil, currentRunSession: nil, currentRunSessionAttachment: nil,
        configuration: absentSeed.configuration, hostObservation: absentSeed.hostObservation,
        attachments: [], sessionAttachments: absentSeed.sessionAttachments,
        artifacts: absentSeed.artifacts,
        omissions: [WorkServiceOmission(category: "attachments", count: 1)])
    let omittedController = try makeAttachedController(
        fixture: seedFixture, service: AttachedControllerTestService(fixture: seedFixture),
        seed: .existing(work: omittedSeed, attachment: seedFixture.response.attachment))
    XCTAssertTrue((await omittedController.projection()).capabilities.isEmpty)

    for mode in [AttachedControllerServiceMode.missingAttachment,
                 AttachedControllerServiceMode.omittedAttachment] {
        let fixture = try AttachedControllerFixture(workID: "missing-\(String(describing: mode))")
        let service = AttachedControllerTestService(fixture: fixture)
        let intentURL = FileManager.default.temporaryDirectory.appending(
            path: "aviary-missing-attachment-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: intentURL) }
        let intentStore = try WorkServiceAttachedWorkIntentStore(url: intentURL)
        let controller = try makeAttachedController(
            fixture: fixture, service: service, intentStore: intentStore)
        let initial = try await controller.refresh()
        await service.setMode(mode)
        let missing = try await controller.refresh()

        XCTAssertFalse(missing.isCanonical)
        XCTAssertTrue(missing.capabilities.isEmpty)
        XCTAssertEqual(missing.visibleMessages, initial.visibleMessages)
        let commandCount = await service.commandCount()
        do {
            _ = try await controller.send("must not dispatch")
            XCTFail("Send must fail closed when the exact client attachment disappears")
        } catch WorkServiceAttachedWorkControllerError.sourceIncomplete {}
        do {
            _ = try await controller.steer("must not dispatch")
            XCTFail("Steer must fail closed when the exact client attachment disappears")
        } catch WorkServiceAttachedWorkControllerError.sourceIncomplete {}
        do {
            _ = try await controller.queue("must not dispatch")
            XCTFail("Queue must fail closed when the exact client attachment disappears")
        } catch WorkServiceAttachedWorkControllerError.sourceIncomplete {}
        do {
            _ = try await controller.cancel(scope: .agentLoop)
            XCTFail("Cancel must fail closed when the exact client attachment disappears")
        } catch WorkServiceAttachedWorkControllerError.sourceIncomplete {}
        do {
            _ = try await controller.end()
            XCTFail("End must fail closed when the exact client attachment disappears")
        } catch WorkServiceAttachedWorkControllerError.sourceIncomplete {}
        XCTAssertEqual(await service.commandCount(), commandCount)
        XCTAssertNil(try intentStore.load())
    }
}

func testWorkServiceAttachedControllersObserveIndependentlyAndDisconnectingOneDoesNotEndWork() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let clientB = ClientRef("controller-client-b")
    let attachmentB = fixture.attachment(for: clientB)
    let controllerA = try makeAttachedController(fixture: fixture, service: service)
    let controllerB = try makeAttachedController(
        fixture: fixture, service: service,
        seed: .existing(work: fixture.descriptor, attachment: attachmentB))
    let first = try await controllerA.refresh()
    let second = try await controllerB.refresh()
    XCTAssertEqual(first.visibleMessages, second.visibleMessages)
    XCTAssertEqual(first.workCursor, second.workCursor)
    // A controller has no End-on-deinit/disconnect operation. The second controller remains a
    // valid observer after the first object goes out of scope.
    _ = controllerA
    let stillVisible = await controllerB.projection()
    XCTAssertTrue(stillVisible.isCanonical)
    XCTAssertEqual(stillVisible.descriptor.recordedDisposition, .reusable)
}

func testWorkServiceAttachedControllerBoundsCanonicalActivitiesAndMessagesExplicitly() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    var workEvents = fixture.workEvents
    let actionRun = RunRef("controller-activity-run")
    let actionTurn = TurnRef("controller-activity-turn")
    let actionActor = TimelineActor(actorID: "controller-activity", kind: "test")

    func workEvent(
        _ eventID: String, _ sequence: Int, _ previous: String?, _ type: String,
        run: RunRef? = nil, turn: TurnRef? = nil, action: ActionRef? = nil,
        payload: JSONValue = .object([:])
    ) -> TimelineEvent {
        TimelineEvent(
            eventID: eventID, journal: fixture.workJournal, sequence: sequence,
            hostSequence: sequence, previousEventID: previous,
            session: fixture.session, work: fixture.work, workHost: fixture.host,
            sessionAttachment: fixture.sessionAttachment,
            run: run, turn: turn, action: action,
            actor: actionActor, hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            type: type, declaredDomains: [.work, .externalEffects], payload: payload)
    }

    let runStarted = workEvent(
        "activity-run", 3, workEvents.last?.eventID, TimelineEventType.runStarted,
        run: actionRun, payload: .object(["model_id": .string("controller-activity-model")]))
    workEvents.append(runStarted)
    let turnStarted = workEvent(
        "activity-turn", 4, runStarted.eventID, TimelineEventType.turnStarted,
        run: actionRun, turn: actionTurn)
    workEvents.append(turnStarted)
    let activeAction = ActionRef("active-before-terminal-history")
    let activeIntent = workEvent(
        "activity-active-intent", 5, turnStarted.eventID, TimelineEventType.actionIntent,
        run: actionRun, turn: actionTurn, action: activeAction,
        payload: .object([
            "state": .string("proposed"), "kind": .string(ActionKind.python.rawValue),
            "intent": .string("remain visible while later actions finish")
        ]))
    workEvents.append(activeIntent)
    workEvents.append(workEvent(
        "activity-active-started", 6, activeIntent.eventID, TimelineEventType.actionStarted,
        run: actionRun, turn: actionTurn, action: activeAction,
        payload: .object([
            "state": .string("running"), "kind": .string(ActionKind.python.rawValue)
        ])))
    for index in 0..<260 {
        // The final event intentionally has the lexically earliest ID. The GUI projection must
        // follow canonical intent sequence, not sort by action identity.
        let actionID: String
        if index == 0 {
            actionID = "z-action-first"
        } else if index == 259 {
            actionID = "a-action-000"
        } else {
            actionID = String(format: "a-action-%03d", index)
        }
        let action = ActionRef(actionID)
        let intentSequence = workEvents.count + 1
        var metadata: [String: JSONValue] = ["index": .number(Double(index))]
        if index == 259 {
            metadata["unicode"] = .string(
                String(repeating: "🙂", count: WorkActionSnapshot.maxTextBytes))
        }
        let intent = workEvent(
            "activity-intent-\(index)", intentSequence,
            workEvents.last?.eventID, TimelineEventType.actionIntent,
            run: actionRun, turn: actionTurn, action: action,
            payload: .object([
                "state": .string("proposed"), "kind": .string(ActionKind.mcp.rawValue),
                "intent": .string("activity intent \(index)"),
                "target": .string("controller"), "scope": .string("turn"),
                "metadata": .object(metadata)
            ]))
        workEvents.append(intent)
        let started = workEvent(
            "activity-started-\(index)", workEvents.count + 1,
            workEvents.last?.eventID, TimelineEventType.actionStarted,
            run: actionRun, turn: actionTurn, action: action,
            payload: .object([
                "state": .string("running"), "kind": .string(ActionKind.mcp.rawValue)
            ]))
        workEvents.append(started)
        let outcome = workEvent(
            "activity-outcome-\(index)", workEvents.count + 1,
            workEvents.last?.eventID, TimelineEventType.actionOutcome,
            run: actionRun, turn: actionTurn, action: action,
            payload: .object([
                "state": .string("succeeded"), "kind": .string(ActionKind.mcp.rawValue),
                "retry_safety": .string(ActionRetrySafety.idempotent.rawValue)
            ]))
        workEvents.append(outcome)
    }

    var sessionEvents = Array(fixture.sessionEvents.prefix(2))
    let messageActor = TimelineActor(actorID: "controller-messages", kind: "test")
    for index in 0..<513 {
        let sequence = sessionEvents.count + 1
        sessionEvents.append(TimelineEvent(
            eventID: "bounded-message-\(index)", journal: fixture.sessionJournal, sequence: sequence,
            hostSequence: sequence, previousEventID: sessionEvents.last?.eventID,
            session: fixture.session, work: fixture.work, workHost: fixture.host,
            sessionAttachment: fixture.sessionAttachment, actor: messageActor,
            hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            type: TimelineEventType.messageCommitted, declaredDomains: [.session],
            payload: .object([
                "role": .string("assistant"), "text": .string("message-\(index)")
            ])))
    }
    await service.replaceWorkEvents(workEvents)
    await service.replaceSessionEvents(sessionEvents)

    let controller = try makeAttachedController(
        fixture: fixture, service: service, pageLimit: 64)
    let projection = try await controller.refresh()

    // The source is complete and the reducer is healthy, but the GUI-facing view is deliberately
    // bounded. Unsettled records outrank resolved history, then terminal records are newest-first;
    // every omitted category is explicit and no action text is rewritten to fit the display budget.
    XCTAssertFalse(projection.projectionComplete)
    XCTAssertTrue(projection.isCanonical)
    XCTAssertFalse(projection.needsRecovery)
    XCTAssertEqual(projection.activities.count, 256)
    XCTAssertEqual(projection.activities.first?.action.actionID, "active-before-terminal-history")
    XCTAssertEqual(projection.activities.last?.action.actionID, "a-action-005")
    XCTAssertEqual(projection.activities.first?.intentEvent?.sequence, 5)
    XCTAssertTrue(projection.activities.contains {
        $0.action.actionID == "a-action-000" && $0.metadataWasTruncated
    })
    XCTAssertEqual(projection.visibleMessages.count, 512)
    XCTAssertEqual(projection.visibleMessages.first?.text, "message-1")
    XCTAssertEqual(projection.visibleMessages.last?.text, "message-512")
    XCTAssertEqual(projection.projectionOmissions.map(\.category),
                   ["activities", "activity_metadata", "messages"])
    XCTAssertEqual(projection.projectionOmissions[0].count, 5)
    XCTAssertEqual(projection.projectionOmissions[1].count, 1)
    XCTAssertEqual(projection.projectionOmissions[2].count, 1)
    XCTAssertTrue(projection.projectionOmissions[2].diagnostic?.contains("UTF-8 bytes") == true)
}

func testWorkServiceAttachedControllerPagesHistoryWithoutMovingCanonicalCursors() async throws {
    let fixture = try AttachedControllerFixture(workID: "history-window")
    let service = AttachedControllerTestService(fixture: fixture)
    var sessionEvents = Array(fixture.sessionEvents.prefix(2))
    let actor = TimelineActor(actorID: "controller-history", kind: "test")
    for index in 0..<820 {
        let sequence = sessionEvents.count + 1
        sessionEvents.append(TimelineEvent(
            eventID: "history-message-\(index)", journal: fixture.sessionJournal,
            sequence: sequence, hostSequence: sequence,
            previousEventID: sessionEvents.last?.eventID,
            session: fixture.session, work: fixture.work, workHost: fixture.host,
            client: fixture.client, sessionAttachment: fixture.sessionAttachment,
            actor: actor, hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            type: TimelineEventType.messageCommitted, declaredDomains: [.session],
            payload: .object([
                "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                "text": .string("history-\(index)")
            ])))
    }
    await service.replaceSessionEvents(sessionEvents)
    let controller = try makeAttachedController(
        fixture: fixture, service: service, pageLimit: 128)
    let canonicalBefore = try await controller.refresh()
    let clientB = ClientRef("controller-client-b")
    let controllerB = try makeAttachedController(
        fixture: fixture, service: service,
        seed: .existing(work: fixture.descriptor, attachment: fixture.attachment(for: clientB)),
        pageLimit: 128)
    _ = try await controllerB.refresh()
    let independentInitial = await controllerB.conversationHistory()
    let acknowledgementsBefore = await service.readAckRequests()
    let commandsBefore = await service.commandCount()
    let initial = await controller.conversationHistory()

    XCTAssertEqual(initial.messages.count, 768)
    XCTAssertEqual(initial.messages.first?.text, "history-52")
    XCTAssertEqual(initial.messages.last?.text, "history-819")
    XCTAssertTrue(initial.hasEarlier)
    XCTAssertFalse(initial.hasNewer)
    XCTAssertEqual(initial.status, .ready)

    // SwiftUI can trigger the top sentinel more than once while a request is suspended. The
    // controller admits one network page only; a concurrent duplicate sees the stable loading
    // projection and cannot move a cursor, acknowledgement, or Work command.
    let gate = AttachedControllerHistoryGate()
    await service.setHistoryGate(gate)
    let firstLoad = Task { try await controller.loadEarlierConversationHistory() }
    await gate.waitUntilEntered()
    let duplicateLoad = try await controller.loadEarlierConversationHistory()
    XCTAssertEqual(duplicateLoad.status, .loading)
    XCTAssertEqual(duplicateLoad.messages, initial.messages)
    XCTAssertEqual(await service.historyRequestCount(), 1)

    // Tail growth can race with the suspended reverse read. Refresh must advance only the
    // canonical reducer/read state, retain the frozen historical rows, and mark newer content;
    // the eventual page then merges against that retained window without creating a gap.
    var prior = sessionEvents.last!
    sessionEvents.append(TimelineEvent(
        eventID: "history-message-820", journal: fixture.sessionJournal,
        sequence: prior.sequence + 1, previousEventID: prior.eventID,
        session: fixture.session, work: fixture.work, workHost: fixture.host,
        client: fixture.client, sessionAttachment: fixture.sessionAttachment,
        actor: actor, hostRecordedAt: Date(timeIntervalSince1970: 9_997),
        type: TimelineEventType.messageCommitted, declaredDomains: [.session],
        payload: .object(["role": .string("assistant"), "text": .string("history-820")])))
    await service.replaceSessionEvents(sessionEvents)
    let canonicalDuringLoad = try await controller.refresh()
    let historyDuringLoad = await controller.conversationHistory()
    XCTAssertEqual(historyDuringLoad.status, .ready)
    XCTAssertTrue(historyDuringLoad.hasNewer)
    XCTAssertEqual(historyDuringLoad.messages, initial.messages)
    let acknowledgementsAfterConcurrentRefresh = await service.readAckRequests()
    await gate.release()
    let older = try await firstLoad.value
    await service.setHistoryGate(nil)
    let canonicalAfter = await controller.projection()
    XCTAssertEqual(older.messages.count, 768)
    XCTAssertEqual(older.messages.first?.text, "history-0")
    XCTAssertEqual(older.messages.last?.text, "history-767")
    XCTAssertFalse(older.hasEarlier)
    XCTAssertTrue(older.hasNewer)
    XCTAssertEqual(older.status, .ready)
    XCTAssertEqual(canonicalAfter.workCursor, canonicalBefore.workCursor)
    XCTAssertEqual(canonicalAfter.sessionCursor, canonicalDuringLoad.sessionCursor)
    XCTAssertEqual(canonicalAfter.visibleMessages, canonicalDuringLoad.visibleMessages)
    XCTAssertTrue(acknowledgementsAfterConcurrentRefresh.count > acknowledgementsBefore.count)
    XCTAssertEqual(await service.readAckRequests(), acknowledgementsAfterConcurrentRefresh)
    XCTAssertEqual(await service.historyRequestCount(), 1)
    XCTAssertEqual(await service.commandCount(), commandsBefore)
    XCTAssertEqual(await controllerB.conversationHistory(), independentInitial)

    let latest = await controller.jumpConversationHistoryToLatest()
    XCTAssertEqual(latest.messages.first?.text, "history-53")
    XCTAssertEqual(latest.messages.last?.text, "history-820")
    XCTAssertTrue(latest.hasEarlier)
    XCTAssertFalse(latest.hasNewer)

    // A user-selected jump supersedes an older read even if that suspended RPC later returns a
    // malformed response. The late failure must not repaint the newest window as unavailable.
    let supersededGate = AttachedControllerHistoryGate()
    await service.setHistoryGate(supersededGate)
    let supersededLoad = Task { try await controller.loadEarlierConversationHistory() }
    await supersededGate.waitUntilEntered()
    await service.setMode(.forgedHistoryPage)
    let supersedingLatest = await controller.jumpConversationHistoryToLatest()
    await supersededGate.release()
    let lateResult = try await supersededLoad.value
    await service.setHistoryGate(nil)
    XCTAssertEqual(lateResult, supersedingLatest)
    XCTAssertEqual(await controller.conversationHistory(), supersedingLatest)
    XCTAssertEqual(supersedingLatest.status, .ready)

    var rejected = false
    do {
        _ = try await controller.loadEarlierConversationHistory()
    } catch WorkServiceAttachedWorkControllerError.malformedResponse {
        rejected = true
    }
    XCTAssertTrue(rejected)
    let preserved = await controller.conversationHistory()
    XCTAssertEqual(preserved.messages, latest.messages)
    XCTAssertEqual(preserved.status, .unavailable)
    XCTAssertTrue(preserved.hasEarlier)
    XCTAssertFalse(preserved.hasNewer)

    // Retry is explicit and can recover the same frozen branch. A later canonical branch
    // selection makes the historical window stale without replacing any authenticated rows.
    await service.setMode(.normal)
    _ = try await controller.loadEarlierConversationHistory()
    prior = sessionEvents.last!
    sessionEvents.append(TimelineEvent(
        eventID: "history-message-821", journal: fixture.sessionJournal,
        sequence: prior.sequence + 1, previousEventID: prior.eventID,
        session: fixture.session, work: fixture.work, workHost: fixture.host,
        client: fixture.client, sessionAttachment: fixture.sessionAttachment,
        actor: actor, hostRecordedAt: Date(timeIntervalSince1970: 9_998),
        type: TimelineEventType.messageCommitted, declaredDomains: [.session],
        payload: .object(["role": .string("assistant"), "text": .string("history-821")])))
    await service.replaceSessionEvents(sessionEvents)
    _ = try await controller.refresh()
    let appended = await controller.conversationHistory()
    XCTAssertEqual(appended.status, .ready)
    XCTAssertTrue(appended.hasNewer)
    XCTAssertEqual(appended.messages.first?.text, "history-0")
    XCTAssertEqual(appended.messages.last?.text, "history-767")

    prior = sessionEvents.last!
    sessionEvents.append(TimelineEvent(
        eventID: "history-select-root", journal: fixture.sessionJournal,
        sequence: prior.sequence + 1, previousEventID: prior.eventID,
        conversationParent: EventRef(
            journal: fixture.sessionJournal, eventID: "history-message-0"),
        session: fixture.session, work: fixture.work, workHost: fixture.host,
        client: fixture.client, sessionAttachment: fixture.sessionAttachment,
        actor: actor, hostRecordedAt: Date(timeIntervalSince1970: 9_999),
        type: TimelineEventType.sessionTipSelected, declaredDomains: [.session]))
    await service.replaceSessionEvents(sessionEvents)
    _ = try await controller.refresh()
    let stale = await controller.conversationHistory()
    XCTAssertEqual(stale.status, .staleBranch)
    XCTAssertTrue(stale.hasNewer)
    XCTAssertFalse(stale.hasEarlier)
    XCTAssertEqual(stale.messages.first?.text, "history-0")
    XCTAssertEqual(stale.messages.last?.text, "history-767")

    let selectedLatest = await controller.jumpConversationHistoryToLatest()
    XCTAssertEqual(selectedLatest.status, .ready)
    XCTAssertEqual(selectedLatest.messages.map(\.text), ["history-0"])
    XCTAssertFalse(selectedLatest.hasEarlier)
    XCTAssertFalse(selectedLatest.hasNewer)
}

func testWorkServiceAttachedControllerKeepsFrozenAncestorBranchTipAcrossDescendantRefresh()
    async throws {
    let fixture = try AttachedControllerFixture(workID: "history-descendant-branch")
    let service = AttachedControllerTestService(fixture: fixture)
    let actor = TimelineActor(actorID: "controller-history-descendant", kind: "test")
    var sessionEvents = Array(fixture.sessionEvents.prefix(2))
    for index in 0..<1_000 {
        let previousMessageID = index == 0
            ? nil : "descendant-history-\(index - 1)"
        let sequence = sessionEvents.count + 1
        sessionEvents.append(TimelineEvent(
            eventID: "descendant-history-\(index)", journal: fixture.sessionJournal,
            sequence: sequence, hostSequence: sequence,
            previousEventID: sessionEvents.last?.eventID,
            conversationParent: previousMessageID.map {
                EventRef(journal: fixture.sessionJournal, eventID: $0)
            }, session: fixture.session, work: fixture.work, workHost: fixture.host,
            client: fixture.client, sessionAttachment: fixture.sessionAttachment,
            actor: actor, hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            type: index.isMultiple(of: 2)
                ? TimelineEventType.inputAccepted : TimelineEventType.messageCommitted,
            declaredDomains: [.session],
            payload: .object([
                "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                "text": .string("descendant-\(index)")
            ])))
    }
    let originalTipID = "descendant-history-999"
    let originalTipSequence = sessionEvents.count + 1
    sessionEvents.append(TimelineEvent(
        eventID: "descendant-tip-initial", journal: fixture.sessionJournal,
        sequence: originalTipSequence, hostSequence: originalTipSequence,
        previousEventID: sessionEvents.last?.eventID,
        conversationParent: EventRef(
            journal: fixture.sessionJournal, eventID: originalTipID),
        session: fixture.session, work: fixture.work, workHost: fixture.host,
        client: fixture.client, sessionAttachment: fixture.sessionAttachment,
        actor: actor, hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(originalTipSequence)),
        type: TimelineEventType.sessionTipSelected, declaredDomains: [.session]))
    let originalBranchTip = EventRef(
        journal: fixture.sessionJournal, eventID: originalTipID)
    await service.replaceSessionEvents(sessionEvents)
    let controller = try makeAttachedController(
        fixture: fixture, service: service, pageLimit: 128)

    let initial: WorkServiceAttachedWorkProjection
    do {
        initial = try await controller.refresh()
    } catch {
        XCTFail("initial refresh failed: \(error)")
        throw error
    }
    let initialHistory = await controller.conversationHistory()
    XCTAssertTrue(initial.isCanonical)
    XCTAssertEqual(initialHistory.branchTip, originalBranchTip)
    XCTAssertTrue(initialHistory.hasEarlier)

    let firstOlder: WorkServiceConversationHistoryWindow
    do {
        firstOlder = try await controller.loadEarlierConversationHistory()
    } catch {
        XCTFail("first older page failed: \(error)")
        throw error
    }
    XCTAssertTrue(firstOlder.hasEarlier)
    XCTAssertEqual(firstOlder.branchTip, originalBranchTip)

    let prior = sessionEvents.last!
    let descendantID = "descendant-history-1000"
    let descendantSequence = prior.sequence + 1
    sessionEvents.append(TimelineEvent(
        eventID: descendantID, journal: fixture.sessionJournal,
        sequence: descendantSequence, hostSequence: descendantSequence,
        previousEventID: prior.eventID,
        conversationParent: EventRef(
            journal: fixture.sessionJournal, eventID: originalTipID),
        session: fixture.session, work: fixture.work, workHost: fixture.host,
        client: fixture.client, sessionAttachment: fixture.sessionAttachment,
        actor: actor, hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(descendantSequence)),
        type: TimelineEventType.messageCommitted, declaredDomains: [.session],
        payload: .object([
            "role": .string("assistant"), "text": .string("descendant-1000")
        ])))
    let tipSequence = descendantSequence + 1
    sessionEvents.append(TimelineEvent(
        eventID: "descendant-tip-selected", journal: fixture.sessionJournal,
        sequence: tipSequence, hostSequence: tipSequence,
        previousEventID: descendantID,
        conversationParent: EventRef(
            journal: fixture.sessionJournal, eventID: descendantID),
        session: fixture.session, work: fixture.work, workHost: fixture.host,
        client: fixture.client, sessionAttachment: fixture.sessionAttachment,
        actor: actor, hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(tipSequence)),
        type: TimelineEventType.sessionTipSelected, declaredDomains: [.session]))
    await service.replaceSessionEvents(sessionEvents)

    let refreshed: WorkServiceAttachedWorkProjection
    do {
        refreshed = try await controller.refresh()
    } catch {
        XCTFail("descendant refresh failed: \(error)")
        throw error
    }
    let browsing = await controller.conversationHistory()
    XCTAssertTrue(refreshed.isCanonical)
    XCTAssertTrue(browsing.hasNewer)
    XCTAssertEqual(browsing.status, .ready)
    XCTAssertEqual(browsing.branchTip, originalBranchTip)

    let secondOlder: WorkServiceConversationHistoryWindow
    do {
        secondOlder = try await controller.loadEarlierConversationHistory()
    } catch {
        XCTFail("second older page failed: \(error)")
        throw error
    }
    XCTAssertEqual(secondOlder.status, .ready)
    XCTAssertTrue(secondOlder.hasNewer)
    XCTAssertEqual(secondOlder.branchTip, originalBranchTip)
    XCTAssertTrue(secondOlder.messages.count > 0)
    XCTAssertTrue(
        (secondOlder.messages.first?.sourceCursor?.sequence ?? Int.max)
            < (firstOlder.messages.first?.sourceCursor?.sequence ?? Int.max))
    let requestBranchTips = await service.historyRequestBranchTips()
    XCTAssertEqual(requestBranchTips.count, 2)
    XCTAssertTrue(requestBranchTips.allSatisfy { $0 == originalBranchTip })
}

func testWorkServiceAttachedControllerReadAcknowledgementTelemetry() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    await service.setLoseReadAcknowledgementResponses(2)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    let (_, spans) = try await AviaryTelemetry.withRecording {
        _ = try await controller.refresh()
        _ = try await controller.refresh()
        _ = try await controller.refresh()
    }
    let attempts = spans.filter { $0.name == "aviary.gui.read_acknowledgement" }
    let requests = await service.readAckRequests()
    XCTAssertEqual(attempts.count, requests.count)
    XCTAssertEqual(attempts.count, 3, "descriptor reconciliation and unchanged polling emit no new attempts")
    XCTAssertEqual(attempts.map { $0.attributes["aviary.outcome"] },
        [.string("indeterminate"), .string("rejected"), .string("indeterminate")])
    XCTAssertEqual(Set(attempts.map { $0.traceId.hexString }).count, 3)
    for (span, request) in zip(attempts, requests) {
        XCTAssertEqual(span.attributes["aviary.command.id"], .string(AviaryTelemetry.identity(request.commandID)))
        XCTAssertEqual(span.attributes["aviary.read.journal.id"],
            .string(AviaryTelemetry.journalIdentity(request.cursor.journal)))
        XCTAssertEqual(span.attributes["aviary.read.sequence"], .int(request.cursor.sequence))
        XCTAssertFalse(String(describing: span).contains(fixture.session.sessionID))
    }
    XCTAssertEqual(await service.readAckEffectCount(), 2)
    XCTAssertEqual((await controller.projection()).attachment.readAcknowledgements.count, 2)
}

func testWorkServiceAttachedControllerReadAcknowledgementTelemetryCheckpointGate() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let box = AttachedControllerCheckpointBox()
    box.failSaves = true
    let controller = try makeAttachedController(fixture: fixture, service: service,
        checkpointStore: AttachedControllerCheckpointStore(box: box))
    let (_, withheld) = try await AviaryTelemetry.withRecording { _ = try await controller.refresh() }
    XCTAssertTrue(withheld.filter { $0.name == "aviary.gui.read_acknowledgement" }.isEmpty)
    XCTAssertTrue((await service.readAckRequests()).isEmpty)
    box.failSaves = false
    let (_, recovered) = try await AviaryTelemetry.withRecording { _ = try await controller.refresh() }
    let attempts = recovered.filter { $0.name == "aviary.gui.read_acknowledgement" }
    XCTAssertEqual(attempts.count, 2)
    XCTAssertTrue(attempts.allSatisfy { $0.attributes["aviary.outcome"] == .string("accepted") })
    XCTAssertTrue(attempts.allSatisfy { $0.events.count == 1 })
}

func testWorkServiceAttachedControllerReadAcknowledgementTelemetryForgedReceipt() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    await service.setForgedReadAcknowledgementResponse()
    let controller = try makeAttachedController(fixture: fixture, service: service)
    let (_, spans) = try await AviaryTelemetry.withRecording { _ = try await controller.refresh() }
    let attempts = spans.filter { $0.name == "aviary.gui.read_acknowledgement" }
    XCTAssertEqual(attempts.count, (await service.readAckRequests()).count)
    XCTAssertTrue(attempts.contains { $0.attributes["aviary.outcome"] == .string("indeterminate") })
    XCTAssertFalse(attempts.contains { $0.attributes["aviary.outcome"] == .string("accepted") })
    XCTAssertTrue(attempts.filter { $0.attributes["aviary.outcome"] == .string("indeterminate") }
        .allSatisfy { $0.events.isEmpty }, "an uncorrelated response is not a diagnostic receipt")
}

func testWorkServiceAttachedControllerAcknowledgesWorkAndSessionWithExactControlChain() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(fixture: fixture, service: service)

    let projection = try await controller.refresh()
    let requests = await service.readAckRequests()
    XCTAssertTrue(projection.isCanonical)
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.map(\.target), [
        .work(journal: fixture.workJournal),
        .session(session: fixture.session, journal: fixture.sessionJournal),
    ])
    XCTAssertEqual(requests[0].causalControlCursor.sequence, 1)
    XCTAssertEqual(requests[1].causalControlCursor.sequence, 2)
    XCTAssertEqual(await service.readAckEffectCount(), 2)
    XCTAssertEqual(projection.attachment.readAcknowledgements.count, 2)
    XCTAssertEqual(await service.controlCursor().sequence, 3)
}

func testWorkServiceAttachedControllerReconcilesLostWorkAndSessionAcknowledgements() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    await service.setLoseReadAcknowledgementResponses(2)
    let controller = try makeAttachedController(fixture: fixture, service: service)

    _ = try await controller.refresh()
    XCTAssertEqual(await service.readAckEffectCount(), 2)
    // The lost Work response leaves the local control cursor one step behind. The Session
    // attempt is rejected as stale and safely rebased once in the same refresh.
    XCTAssertEqual((await service.readAckRequests()).count, 3)
    XCTAssertTrue((await controller.projection()).attachment.readAcknowledgements.isEmpty)

    let reconciled = try await controller.refresh()
    XCTAssertTrue(reconciled.isCanonical)
    XCTAssertEqual((await service.readAckRequests()).count, 3)
    XCTAssertEqual(reconciled.attachment.readAcknowledgements.count, 2)
}

func testWorkServiceAttachedControllerExactlyReplaysAnUnadmittedAcknowledgement() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let sessionTarget = WorkServiceReadTarget.session(
        session: fixture.session, journal: fixture.sessionJournal)
    await service.loseNextReadAcknowledgementBeforeAdmission(for: sessionTarget)
    let controller = try makeAttachedController(fixture: fixture, service: service)

    _ = try await controller.refresh()
    let first = await service.readAckRequests()
    XCTAssertEqual(first.count, 2)
    XCTAssertEqual(await service.readAckEffectCount(), 1)

    let reconciled = try await controller.refresh()
    let requests = await service.readAckRequests()
    XCTAssertTrue(reconciled.isCanonical)
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(requests[1], requests[2], "replay must retain the exact request and command ID")
    XCTAssertEqual(await service.readAckEffectCount(), 2)
    XCTAssertEqual(reconciled.attachment.readAcknowledgements.count, 2)
}

func testWorkServiceAttachedControllerEventuallyReplaysAfterThreeLostResponses() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let sessionTarget = WorkServiceReadTarget.session(
        session: fixture.session, journal: fixture.sessionJournal)
    await service.setLoseReadAcknowledgementResponses(
        3, beforeAdmission: true, target: sessionTarget)
    let controller = try makeAttachedController(fixture: fixture, service: service)

    _ = try await controller.refresh()
    _ = try await controller.refresh()
    _ = try await controller.refresh()
    let third = await service.readAckRequests()
    XCTAssertEqual(third.count, 4)
    XCTAssertEqual(third[1], third[2])
    XCTAssertEqual(third[2], third[3])
    let final = try await controller.refresh()
    let requests = await service.readAckRequests()
    XCTAssertTrue(final.isCanonical)
    XCTAssertEqual(requests.count, 5)
    XCTAssertEqual(requests[3], requests[4])
    XCTAssertEqual(await service.readAckEffectCount(), 2)
    XCTAssertEqual(final.attachment.readAcknowledgements.count, 2)
}

func testWorkServiceAttachedControllerRetriesSessionAcknowledgementAfterConcurrentControlAdvance() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    await service.setAdvanceControlAfterWorkAcknowledgement(true)
    let controller = try makeAttachedController(fixture: fixture, service: service)

    let projection = try await controller.refresh()
    let requests = await service.readAckRequests()
    XCTAssertTrue(projection.isCanonical)
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(requests[1].target, .session(
        session: fixture.session, journal: fixture.sessionJournal))
    XCTAssertEqual(requests[1].causalControlCursor.sequence, 2)
    XCTAssertEqual(requests[2].causalControlCursor.sequence, 3)
    XCTAssertNotEqual(requests[1].commandID, requests[2].commandID)
    XCTAssertEqual(await service.readAckEffectCount(), 2)
}

func testWorkServiceAttachedControllerRestoresCheckpointOnlyAsNoncanonicalUntilHostValidation() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let box = AttachedControllerCheckpointBox()
    let checkpointStore = AttachedControllerCheckpointStore(box: box)
    let intentStore = try WorkServiceAttachedWorkIntentStore(
        url: FileManager.default.temporaryDirectory.appending(
            path: "aviary-controller-checkpoint-identity-\(UUID().uuidString).json"))
    defer { try? FileManager.default.removeItem(at: intentStore.url) }

    let first = try makeAttachedController(
        fixture: fixture, service: service, intentStore: intentStore,
        checkpointStore: checkpointStore)
    XCTAssertTrue(try await first.refresh().isCanonical)
    XCTAssertNotNil(box.record)

    let replacement = try makeAttachedController(
        fixture: fixture, service: service, intentStore: intentStore,
        checkpointStore: checkpointStore)
    let cached = await replacement.projection()
    XCTAssertFalse(cached.isCanonical)
    XCTAssertEqual(cached.workSourceCompleteness, .unknown)
    XCTAssertEqual(cached.sessionSourceCompleteness, .unknown)
    XCTAssertEqual(cached.workSnapshot.lastSequence, 0)
    XCTAssertEqual(cached.sessionSnapshot.lastSequence, 0)
    XCTAssertTrue(try await replacement.refresh().isCanonical)
}

func testWorkServiceAttachedControllerRejectsMismatchedCheckpointPrefixBeforeReplay() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let box = AttachedControllerCheckpointBox()
    let checkpointStore = AttachedControllerCheckpointStore(box: box)
    let intentStore = try WorkServiceAttachedWorkIntentStore(
        url: FileManager.default.temporaryDirectory.appending(
            path: "aviary-controller-checkpoint-prefix-\(UUID().uuidString).json"))
    defer { try? FileManager.default.removeItem(at: intentStore.url) }

    let first = try makeAttachedController(
        fixture: fixture, service: service, intentStore: intentStore,
        checkpointStore: checkpointStore)
    XCTAssertTrue(try await first.refresh().isCanonical)
    let firstRecord = try XCTUnwrap(box.record)
    XCTAssertEqual(firstRecord.committedWorkCursor.sequence, fixture.workEvents.count)

    // This is a validly encoded/checksummed checkpoint whose service-issued proof no longer
    // matches the host prefix. It must not leak the cached transcript before the failed refresh,
    // and the next healthy refresh must replay from the baseline.
    await service.setCorruptPrefixDigests(true)
    let replacement = try makeAttachedController(
        fixture: fixture, service: service, intentStore: intentStore,
        checkpointStore: checkpointStore)
    let cached = await replacement.projection()
    XCTAssertFalse(cached.isCanonical)
    XCTAssertEqual(cached.workSnapshot.lastSequence, 0)
    do {
        _ = try await replacement.refresh()
        XCTFail("a mismatched service prefix must reject the restored checkpoint")
    } catch WorkServiceAttachedWorkControllerError.sourceIncomplete {
        XCTAssertTrue(true)
    }
    XCTAssertEqual((await replacement.projection()).workSnapshot.lastSequence, 0)
    await service.setCorruptPrefixDigests(false)
    XCTAssertTrue(try await replacement.refresh().isCanonical)
    XCTAssertEqual((await replacement.projection()).workSnapshot.lastSequence,
                   fixture.workEvents.count)
}

func testWorkServiceAttachedControllerReauthenticatesInvalidatedIncrementalReadWithoutReplayingCommand()
    async throws {
    let fixture = try AttachedControllerFixture(workID: "incremental-reauthentication")
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    let initial = try await controller.refresh()
    XCTAssertTrue(initial.isCanonical)

    // The command crossed exactly once, but its response was lost. Its canonical acceptance is
    // deliberately left in the newer Work prefix while the controller retains the exact intent.
    await service.loseNextAcceptedResponse()
    do {
        _ = try await controller.start(
            "retained during source reauthentication", commandID: "reauthenticated-command")
        XCTFail("the accepted response must be lost")
    } catch WorkServiceAttachedWorkControllerError.transportFailure {
        XCTAssertEqual((await controller.pendingCommand())?.commandID, "reauthenticated-command")
    }
    XCTAssertEqual(await service.commandCount(), 1)

    // Model an invalidated since-cursor proof such as a typed remote stale read during a source
    // handoff. The published pair stays intact and the command remains retained.
    await service.setMode(.remoteReadStale)
    do {
        _ = try await controller.refresh()
        XCTFail("the incremental read must fail on its stale source cursor")
    } catch WorkServiceAttachedWorkControllerError.staleCursor {
        XCTAssertEqual((await controller.projection()).workCursor, initial.workCursor)
        XCTAssertEqual((await controller.projection()).sessionCursor, initial.sessionCursor)
        XCTAssertEqual((await controller.pendingCommand())?.commandID, "reauthenticated-command")
    }

    await service.setMode(.normal)
    let recovered = try await controller.refresh()
    XCTAssertTrue(recovered.isCanonical)
    XCTAssertEqual(recovered.workCursor.sequence, fixture.workEvents.count + 1)
    XCTAssertNil(await controller.pendingCommand())
    XCTAssertEqual(await service.commandCount(), 1, "source recovery must never replay the command")
    XCTAssertTrue(
        (await service.snapshotRequestCursors()).filter { $0 == 0 }.count >= 4,
        "the private recovery must reauthenticate both journals from zero")
}

func testWorkServiceAttachedControllerReadTraceClassifierOmitsErrorDetails() {
    let sensitive = "private prompt /Users/example/.secret token=credential"
    let samples: [(Error, String)] = [
        (WorkServiceTransportError.remote(code: .internalError, detail: sensitive),
         "transport.remote.internal_error"),
        (WorkServiceTransportError.writeFailed(sensitive), "transport.write_failed"),
        (WorkServiceProtocolError.invalidRequest(sensitive), "protocol.invalid_request"),
        (AttachedControllerTestError.transport, "unknown"),
    ]
    for (error, expected) in samples {
        let classified = WorkServiceAttachedWorkController.traceErrorCode(error)
        XCTAssertEqual(classified, expected)
        XCTAssertFalse(classified.contains(sensitive))
    }
}

func testWorkServiceAttachedControllerAttemptsOnlyOneBaselineReplayForStableCorruption()
    async throws {
    let fixture = try AttachedControllerFixture(workID: "baseline-replay-exhaustion")
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    let initial = try await controller.refresh()
    XCTAssertTrue(initial.isCanonical)
    await service.advanceWorkCursor()
    await service.advanceSessionCursor()

    await service.setMode(.remoteReadStale)
    do {
        _ = try await controller.refresh()
        XCTFail("the incremental proof must be invalidated")
    } catch WorkServiceAttachedWorkControllerError.staleCursor { }

    await service.setMode(.foreignSnapshot)
    do {
        _ = try await controller.refresh()
        XCTFail("the baseline replay must reject a malformed stable source")
    } catch WorkServiceAttachedWorkControllerError.malformedResponse { }
    let zeroReadsAfterReplay = (await service.snapshotRequestCursors()).filter { $0 == 0 }.count
    XCTAssertTrue(zeroReadsAfterReplay >= 4)

    do {
        _ = try await controller.refresh()
        XCTFail("the malformed incremental source must remain unavailable")
    } catch WorkServiceAttachedWorkControllerError.malformedResponse { }
    XCTAssertEqual(
        (await service.snapshotRequestCursors()).filter { $0 == 0 }.count,
        zeroReadsAfterReplay,
        "a failed baseline replay must not restart full history on every poll")
    let preserved = await controller.projection()
    XCTAssertEqual(preserved.workCursor, initial.workCursor)
    XCTAssertEqual(preserved.sessionCursor, initial.sessionCursor)
}

func testWorkServiceAttachedControllerRejectsRegressedOrRewrittenBaselinePrefix()
    async throws {
    for rewrite in [false, true] {
        let fixture = try AttachedControllerFixture(
            workID: rewrite ? "rewritten-baseline" : "regressed-baseline")
        let service = AttachedControllerTestService(fixture: fixture)
        if !rewrite {
            await service.advanceWorkCursor()
            await service.advanceSessionCursor()
        }
        let controller = try makeAttachedController(fixture: fixture, service: service)
        let initial = try await controller.refresh()
        XCTAssertTrue(initial.isCanonical)

        await service.setMode(.remoteReadStale)
        do {
            _ = try await controller.refresh()
            XCTFail("the incremental source must first invalidate its retained proof")
        } catch WorkServiceAttachedWorkControllerError.staleCursor { }

        if rewrite {
            var rewritten = fixture.sessionEvents
            let prior = rewritten.removeLast()
            rewritten.append(TimelineEvent(
                eventID: prior.eventID, journal: prior.journal, sequence: prior.sequence,
                hostSequence: prior.hostSequence, idempotencyKey: prior.idempotencyKey,
                command: prior.command, previousEventID: prior.previousEventID,
                causedByEventID: prior.causedByEventID, parentActivityID: prior.parentActivityID,
                conversationParent: prior.conversationParent, session: prior.session,
                work: prior.work, workHost: prior.workHost, client: prior.client,
                sessionAttachment: prior.sessionAttachment,
                clientAttachment: prior.clientAttachment, run: prior.run, turn: prior.turn,
                action: prior.action, handle: prior.handle, actor: prior.actor,
                hostRecordedAt: prior.hostRecordedAt, clientTimestamp: prior.clientTimestamp,
                schemaVersion: prior.schemaVersion, payloadVersion: prior.payloadVersion,
                type: prior.type, declaredDomains: prior.declaredDomains,
                provenance: prior.provenance, links: prior.links,
                omittedEvidenceLinkCount: prior.omittedEvidenceLinkCount,
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string("same identity, rewritten canonical payload"),
                ])))
            await service.replaceSessionEvents(rewritten)
        } else {
            await service.replaceWorkEvents(fixture.workEvents)
            await service.replaceSessionEvents(fixture.sessionEvents)
        }
        await service.setMode(.normal)
        do {
            _ = try await controller.refresh()
            XCTFail("baseline replay must not replace the published prefix")
        } catch WorkServiceAttachedWorkControllerError.sourceIncomplete { }
        let preserved = await controller.projection()
        XCTAssertEqual(preserved.workCursor, initial.workCursor)
        XCTAssertEqual(preserved.sessionCursor, initial.sessionCursor)
        XCTAssertEqual(preserved.workSnapshot, initial.workSnapshot)
        XCTAssertEqual(preserved.sessionSnapshot, initial.sessionSnapshot)
    }
}

func testWorkServiceAttachedControllerPreservesCheckpointAcrossHostRestart() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let box = AttachedControllerCheckpointBox()
    let checkpointStore = AttachedControllerCheckpointStore(box: box)
    let intentStore = try WorkServiceAttachedWorkIntentStore(
        url: FileManager.default.temporaryDirectory.appending(
            path: "aviary-controller-host-restart-\(UUID().uuidString).json"))
    defer { try? FileManager.default.removeItem(at: intentStore.url) }
    let connect: WorkServiceAttachedWorkController.Connect = {
        try await service.handshake(WorkServiceHandshakeRequest(client: fixture.client))
    }

    let first = try makeAttachedController(
        fixture: fixture, service: service, intentStore: intentStore,
        checkpointStore: checkpointStore, connect: connect)
    XCTAssertTrue(try await first.refresh().isCanonical)
    let priorSnapshotCursors = await service.snapshotRequestCursors()
    XCTAssertTrue(priorSnapshotCursors.contains { $0 == 0 })

    let restartedInstance = WorkHostInstanceRef(
        host: fixture.host, instanceID: "controller-instance-restarted",
        startIdentity: "controller-start-restarted")
    await service.setHostInstance(restartedInstance)
    let replacement = try makeAttachedController(
        fixture: fixture, service: service, intentStore: intentStore,
        checkpointStore: checkpointStore, connect: connect)
    let cached = await replacement.projection()
    XCTAssertEqual(cached.workSnapshot.lastSequence, 0)
    XCTAssertFalse(cached.isCanonical)
    let restored = try await replacement.refresh()
    XCTAssertTrue(restored.isCanonical)
    XCTAssertEqual(restored.workSnapshot.lastSequence, fixture.workEvents.count)
    XCTAssertEqual(restored.sessionSnapshot.lastSequence, fixture.sessionEvents.count)
    let resumedCursors = await service.snapshotRequestCursors().dropFirst(priorSnapshotCursors.count)
    XCTAssertTrue(resumedCursors.contains { $0 == fixture.workEvents.count })
    XCTAssertTrue(resumedCursors.contains { $0 == fixture.sessionEvents.count })
}

func testWorkServiceAttachedCheckpointStoreDetectsTornAndAlteredRecords() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-checkpoint-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkServiceAttachedWorkCheckpointStore(
        url: root.appending(path: "checkpoint.json", directoryHint: .notDirectory))
    let fixture = try AttachedControllerFixture()
    let box = AttachedControllerCheckpointBox()
    let controllerStore = AttachedControllerCheckpointStore(box: box)
    let intentStore = try WorkServiceAttachedWorkIntentStore(
        url: root.appending(path: "intent.json", directoryHint: .notDirectory))
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(
        fixture: fixture, service: service, intentStore: intentStore,
        checkpointStore: controllerStore)
    _ = try await controller.refresh()
    guard let record = box.record else {
        throw UnwrapFailure(description: "controller did not persist a checkpoint")
    }
    try store.save(record)
    let firstBytes = try Data(contentsOf: store.url)
    try store.save(record)
    XCTAssertEqual(firstBytes, try Data(contentsOf: store.url))

    var altered = firstBytes
    altered[altered.index(before: altered.endIndex)] = altered.last == 0x7d ? 0x7c : 0x7d
    try altered.write(to: store.url, options: .atomic)
    do {
        _ = try store.load()
        XCTFail("altered checkpoint must fail its deterministic checksum")
    } catch WorkServiceAttachedWorkControllerError.sourceIncomplete {
        XCTAssertTrue(true)
    }

    try Data(firstBytes.prefix(max(1, firstBytes.count / 2))).write(to: store.url, options: .atomic)
    do {
        _ = try store.load()
        XCTFail("torn checkpoint must fail closed")
    } catch WorkServiceAttachedWorkControllerError.sourceIncomplete {
        XCTAssertTrue(true)
    }
}

func testWorkServiceAttachedControllerRejectsV5SnapshotAndRebuildsNativeEndKind() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let prior = fixture.workEvents.last!
    let command = CommandRef(
        commandID: "controller-native-end", client: fixture.client,
        sessionAttachment: fixture.sessionAttachment,
        causalCursor: JournalCursor(
            journal: fixture.workJournal, eventID: prior.eventID,
            sequence: prior.sequence))
    let accepted = TimelineEvent(
        eventID: "controller-native-end-accepted", journal: fixture.workJournal,
        sequence: prior.sequence + 1, hostSequence: 1,
        idempotencyKey: command.commandID, command: command,
        previousEventID: prior.eventID,
        causedByEventID: EventRef(journal: fixture.workJournal, eventID: prior.eventID),
        session: fixture.session, work: fixture.work, workHost: fixture.host,
        client: fixture.client, sessionAttachment: fixture.sessionAttachment,
        actor: prior.actor, hostRecordedAt: Date(timeIntervalSince1970: 3),
        type: TimelineEventType.commandAccepted,
        payload: .object([
            "command_kind": .string("end_run"),
            "delivery_mode": .string(RunInputDeliveryMode.queued.rawValue),
            "carries_session_input": .bool(false),
        ]))
    await service.replaceWorkEvents(fixture.workEvents + [accepted])

    let box = AttachedControllerCheckpointBox()
    let checkpointStore = AttachedControllerCheckpointStore(box: box)
    let first = try makeAttachedController(
        fixture: fixture, service: service, checkpointStore: checkpointStore)
    let current = try await first.refresh()
    XCTAssertEqual(
        current.workSnapshot.commands[command.commandID]?.commandKind, .endRun)
    let currentRecord = try XCTUnwrap(box.record)
    var oldObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(currentRecord))
            as? [String: Any])
    oldObject["schemaVersion"] = 5
    box.record = try JSONDecoder().decode(
        WorkServiceAttachedWorkCheckpointStore.Record.self,
        from: JSONSerialization.data(withJSONObject: oldObject, options: [.sortedKeys]))

    let requestsBeforeRestart = await service.snapshotRequestCursors().count
    let replacement = try makeAttachedController(
        fixture: fixture, service: service, checkpointStore: checkpointStore)
    let unrestored = await replacement.projection()
    XCTAssertEqual(unrestored.workSnapshot.lastSequence, 0)
    let rebuilt = try await replacement.refresh()
    XCTAssertEqual(
        rebuilt.workSnapshot.commands[command.commandID]?.commandKind, .endRun)
    let allRequests = await service.snapshotRequestCursors()
    let restartRequests = allRequests.dropFirst(requestsBeforeRestart)
    XCTAssertTrue(restartRequests.contains(0))
    XCTAssertEqual(box.record?.schemaVersion,
                   WorkServiceAttachedWorkCheckpointStore.Record.currentSchemaVersion)
}

func testWorkServiceAttachedControllerSkipsCheckpointWriteForNoOpRefresh() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let box = AttachedControllerCheckpointBox()
    let controller = try makeAttachedController(
        fixture: fixture, service: service,
        checkpointStore: AttachedControllerCheckpointStore(box: box))

    _ = try await controller.refresh()
    let writes = box.saveCount
    _ = try await controller.refresh()
    XCTAssertEqual(box.saveCount, writes)
}

func testWorkServiceAttachedControllerCheckpointWriteFailureDoesNotHideCanonicalRead() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let box = AttachedControllerCheckpointBox()
    box.failSaves = true
    let controller = try makeAttachedController(
        fixture: fixture, service: service,
        checkpointStore: AttachedControllerCheckpointStore(box: box))

    let projection = try await controller.refresh()
    XCTAssertTrue(projection.workSnapshot.structuralIntegrityValid)
    XCTAssertTrue(projection.sessionSnapshot.structuralIntegrityValid)
    XCTAssertTrue(projection.readDiagnostics.contains {
        $0.contains("checkpoint")
    })
    XCTAssertEqual(await service.readAckEffectCount(), 0)

    // A local cache outage is not source failure. Once the same store becomes writable, a later
    // refresh retries the byte-identical checkpoint and can admit the already validated reads.
    box.failSaves = false
    let recovered = try await controller.refresh()
    XCTAssertTrue(recovered.isCanonical)
    XCTAssertEqual(await service.readAckEffectCount(), 2)
}

func testWorkServiceAttachedControllerBoundsOversizedCheckpointAndReplaysOnRestart() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    var sessionEvents = fixture.sessionEvents
    let oversizedText = String(repeating: "m", count: 100_000)
    for index in 0..<300 {
        let prior = sessionEvents.last!
        sessionEvents.append(TimelineEvent(
            eventID: "oversized-session-\(index)", journal: fixture.sessionJournal,
            sequence: prior.sequence + 1, previousEventID: prior.eventID,
            session: fixture.session, work: fixture.work, workHost: fixture.host,
            sessionAttachment: fixture.sessionAttachment,
            actor: TimelineActor(actorID: "oversized", kind: "test"),
            hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(index + 20)),
            type: TimelineEventType.messageCommitted,
            payload: .object(["role": .string("assistant"), "text": .string(oversizedText)])))
    }
    await service.replaceSessionEvents(sessionEvents)
    let box = AttachedControllerCheckpointBox()
    let checkpointStore = AttachedControllerCheckpointStore(box: box)
    let intentStore = try WorkServiceAttachedWorkIntentStore(
        url: FileManager.default.temporaryDirectory.appending(
            path: "aviary-controller-oversized-checkpoint-\(UUID().uuidString).json"))
    defer { try? FileManager.default.removeItem(at: intentStore.url) }

    let first = try makeAttachedController(
        fixture: fixture, service: service, intentStore: intentStore,
        checkpointStore: checkpointStore, pageLimit: 2)
    let initial = try await first.refresh()
    XCTAssertTrue(initial.isCanonical)
    let compact = try XCTUnwrap(box.record)
    XCTAssertNil(compact.committedWorkSnapshot)
    XCTAssertNil(compact.committedSessionSnapshot)
    XCTAssertNotNil(compact.committedSessionPrefixDigest)
    XCTAssertEqual(await service.readAckEffectCount(), 2)

    let replacement = try makeAttachedController(
        fixture: fixture, service: service, intentStore: intentStore,
        checkpointStore: checkpointStore, pageLimit: 2)
    let cached = await replacement.projection()
    XCTAssertEqual(cached.workSnapshot.lastSequence, 0)
    XCTAssertEqual(cached.sessionSnapshot.lastSequence, 0)
    XCTAssertFalse(cached.isCanonical)
    let restarted = try await replacement.refresh()
    XCTAssertTrue(restarted.isCanonical)
    XCTAssertEqual(restarted.sessionSnapshot.lastSequence, sessionEvents.count)
    XCTAssertTrue(await service.snapshotRequestCursors().contains { $0 == 0 })
    XCTAssertEqual(await service.readAckEffectCount(), 2)
}

func testWorkServiceAttachedControllerResumesMoreThan256PagesFromCheckpointCursor() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    var workEvents = fixture.workEvents
    var sessionEvents = fixture.sessionEvents
    for index in 0..<520 {
        let workPrevious = workEvents.last!.eventID
        workEvents.append(TimelineEvent(
            eventID: "catch-up-work-\(index)", journal: fixture.workJournal,
            sequence: workEvents.count + 1, previousEventID: workPrevious,
            work: fixture.work, workHost: fixture.host,
            actor: TimelineActor(actorID: "catch-up", kind: "test"),
            hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(index + 10)),
            type: TimelineEventType.hostOrderObserved))
        let sessionPrevious = sessionEvents.last!.eventID
        sessionEvents.append(TimelineEvent(
            eventID: "catch-up-session-\(index)", journal: fixture.sessionJournal,
            sequence: sessionEvents.count + 1, previousEventID: sessionPrevious,
            session: fixture.session, work: fixture.work, workHost: fixture.host,
            sessionAttachment: fixture.sessionAttachment,
            actor: TimelineActor(actorID: "catch-up", kind: "test"),
            hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(index + 10)),
            type: TimelineEventType.messageCommitted,
            payload: .object([
                "role": .string("assistant"), "text": .string("catch-up-\(index)")
            ])))
    }
    await service.replaceWorkEvents(workEvents)
    await service.replaceSessionEvents(sessionEvents)
    let controller = try makeAttachedController(
        fixture: fixture, service: service, pageLimit: 1)

    let first = try await controller.refresh()
    XCTAssertFalse(first.isCanonical)
    XCTAssertEqual(first.workCursor.sequence, 0)
    XCTAssertEqual(first.sessionCursor.sequence, 0)
    XCTAssertTrue((first.workOmissions.first(where: {
        $0.category == "controller_page_budget"
    })?.count ?? 0) > 0)
    let firstWorkPages = await service.pageRequestCursors().filter { $0 > 0 }
    XCTAssertFalse(firstWorkPages.isEmpty)

    let second = try await controller.refresh()
    XCTAssertFalse(second.isCanonical)
    // The paired public projection remains at its last committed boundary while both hidden
    // continuations advance; exposing either cursor here would publish half a catch-up state.
    XCTAssertEqual(second.workCursor.sequence, 0)
    XCTAssertEqual(second.sessionCursor.sequence, 0)
    XCTAssertTrue(await service.snapshotRequestCursors().contains {
        $0 > 0
    })
    XCTAssertTrue(await service.pageRequestCursors().contains { $0 > 0 })

    let final = try await controller.refresh()
    XCTAssertTrue(final.isCanonical)
    XCTAssertEqual(final.workCursor.sequence, workEvents.count)
    XCTAssertEqual(final.sessionCursor.sequence, sessionEvents.count)
    XCTAssertTrue(await service.pageRequestCursors().contains {
        $0 >= 257
    })

    // The same hidden continuation machinery must carry a recovery replay across its page
    // budget. Its intermediate prefixes never replace the already-published complete pair.
    await service.setMode(.remoteReadStale)
    do {
        _ = try await controller.refresh()
        XCTFail("the incremental proof must be invalidated before replay")
    } catch WorkServiceAttachedWorkControllerError.staleCursor { }
    await service.setMode(.normal)
    var replayed = await controller.projection()
    for _ in 0..<4 where !replayed.isCanonical {
        replayed = try await controller.refresh()
        if !replayed.isCanonical {
            XCTAssertEqual(replayed.workCursor, final.workCursor)
            XCTAssertEqual(replayed.sessionCursor, final.sessionCursor)
        }
    }
    XCTAssertTrue(replayed.isCanonical)
    XCTAssertEqual(replayed.workSnapshot, final.workSnapshot)
    XCTAssertEqual(replayed.sessionSnapshot, final.sessionSnapshot)
}

func testWorkServiceAttachedControllerRequiresCapturedRunForDirectShell() async throws {
    let fixture = try AttachedControllerFixture(workID: "direct-shell-run-fence")
    let service = AttachedControllerTestService(fixture: fixture)
    let run = RunRef("direct-shell-current-run")
    let prior = try XCTUnwrap(fixture.workEvents.last)
    let started = TimelineEvent(
        eventID: "direct-shell-run-started", journal: fixture.workJournal,
        sequence: prior.sequence + 1, previousEventID: prior.eventID,
        session: fixture.session, work: fixture.work, workHost: fixture.host,
        client: fixture.client, sessionAttachment: fixture.sessionAttachment, run: run,
        actor: TimelineActor(actorID: "direct-shell-run-fence", kind: "test"),
        hostRecordedAt: Date(), type: TimelineEventType.runStarted,
        declaredDomains: [.work], payload: .object([:]))
    await service.replaceWorkEvents(fixture.workEvents + [started])
    let controller = try makeAttachedController(fixture: fixture, service: service)
    let projection = try await controller.refresh()
    XCTAssertEqual(projection.descriptor.currentRun, run)

    do {
        _ = try await controller.directShell(
            operation: .run, language: .sh, source: Data("printf fenced".utf8),
            expectedRun: RunRef("stale-confirmed-run"))
        XCTFail("a command confirmed for a replaced Run must not reach the service")
    } catch WorkServiceProtocolError.invalidRequest { /* expected */ }
    do {
        _ = try await controller.directShell(
            operation: .run, language: .sh, source: Data("printf fenced".utf8))
        XCTFail("Run admission must require the caller's captured Run")
    } catch WorkServiceProtocolError.invalidRequest { /* expected */ }
    XCTAssertEqual(await service.directShellCount(), 0)

    do {
        _ = try await controller.directShell(
            operation: .run, language: .sh, source: Data("printf exact".utf8),
            expectedRun: run)
        XCTFail("the fixture service deliberately does not execute direct commands")
    } catch AttachedControllerTestError.unsupported { /* expected */ }
    XCTAssertEqual(await service.directShellCount(), 1)
}

func testWorkServiceAttachedControllerEndChecksHostFeatureNotClientGrant() async throws {
    let fixture = try AttachedControllerFixture()
    let service = AttachedControllerTestService(fixture: fixture)
    let controller = try makeAttachedController(fixture: fixture, service: service)
    _ = try await controller.refresh()
    XCTAssertTrue(try await controller.hostSupportsDirectShellForEnd())

    let granted = fixture.authorization.granted.subtracting([.directShell])
    await service.setAttachmentAuthorization(WorkServiceAuthorizationOutcome(
        requested: fixture.authorization.requested, granted: granted, denied: [.directShell]))
    _ = try await controller.refresh()
    XCTAssertTrue(try await controller.hostSupportsDirectShellForEnd(),
                  "A revoked client grant is not proof of an empty shared tray")

    await service.setHostCapabilities(Set(WorkServiceCapability.allCases).subtracting([.directShell]))
    XCTAssertFalse(try await controller.hostSupportsDirectShellForEnd())
    await service.setHostInstance(WorkHostInstanceRef(
        host: fixture.host, instanceID: "changed-for-end", startIdentity: "changed-for-end"))
    do {
        _ = try await controller.hostSupportsDirectShellForEnd()
        XCTFail("A replacement host must not prove feature absence for the old Run")
    } catch {
        XCTAssertTrue(error is WorkServiceProtocolError)
    }
}

let casesWorkServiceAttachedWorkController: [Case] = [
    ("phase3 Work controller End checks host feature not client grant", {
        try await testWorkServiceAttachedControllerEndChecksHostFeatureNotClientGrant()
    }),
    ("direct shell controller fences execution to the captured Run", {
        try await testWorkServiceAttachedControllerRequiresCapturedRunForDirectShell()
    }),
    ("phase3 Work controller acceptance read cannot orphan an in-flight intent", {
        try await testWorkServiceAttachedControllerAcceptanceReadCannotOrphanInFlightIntent()
    }),
    ("phase3 Work controller distinguishes in-flight from lost response", {
        try await testWorkServiceAttachedControllerDistinguishesInFlightFromLostResponse()
    }),
    ("phase4b Work controller fetches latest authorized artifact in chunks", {
        try await testWorkServiceAttachedControllerFetchesLatestAuthorizedArtifactInChunks()
    }),
    ("phase4b Work controller fetches exact older review and latest review", {
        try await testWorkServiceAttachedControllerFetchesExactOlderReviewAndLatestReview()
    }),
    ("phase4b Work controller projects exact repository review history", {
        try testWorkServiceRepositoryReviewHistoryJoinsOnlyExactTurnRunAttachmentAndSessionJournal()
    }),
    ("phase4b Work controller rejects artifact progress and metadata failures", {
        try await testWorkServiceAttachedControllerRejectsArtifactProgressAndMetadataFailures()
    }),
    ("phase4b Work controller distinguishes artifact omission, unavailable, and size", {
        try await testWorkServiceAttachedControllerDistinguishesArtifactOmittedUnavailableAndTooLarge()
    }),
    ("phase4b Work controller fences attachment and capability drift during artifact reads", {
        try await testWorkServiceAttachedControllerFailsArtifactReadOnAttachmentOrCapabilityDrift()
    }),
    ("phase4b Work controller allows Session B to inspect Session A review after producer detach", {
        try await testWorkServiceAttachedControllerAllowsSessionBToInspectSessionAReviewAfterProducerDetach()
    }),
    ("phase4b Work controller reads artifacts from terminal Work", {
        try await testWorkServiceAttachedControllerReadsArtifactFromTerminalWork()
    }),
    ("phase3 Work controller distinguishes history prepend from tail output", {
        testWorkServiceConversationIdentityChangeSeparatesPrependAndTail()
    }),
    ("phase3 Work controller creates and projects visible conversation", {
        try await testWorkServiceAttachedControllerCreatesRefreshesAndProjectsVisibleConversation()
    }),
    ("phase3 Work controller consumes a host-minted create response", {
        try await testWorkServiceAttachedControllerConsumesReferenceServiceCreateResponse()
    }),
    ("phase3 Work controller accepts exact standalone event byte boundary", {
        try await testWorkServiceAttachedControllerAcceptsExactStandaloneEventByteBoundary()
    }),
    ("phase3 Work controller requires an exact existing Session attachment", {
        try await testWorkServiceAttachedControllerExistingDescriptorRequiresExactBoundSession()
    }),
    ("phase3 Work controller preserves prior projection on malformed pages", {
        try await testWorkServiceAttachedControllerLeavesPriorProjectionOnMalformedPage()
    }),
    ("phase3 Work controller rejects repeated and truncated pages", {
        try await testWorkServiceAttachedControllerRejectsRepeatedAndTruncatedPages()
    }),
    ("phase3 Work controller retains stale command without replay", {
        try await testWorkServiceAttachedControllerUsesLatestCursorAndRetainsStaleCommandWithoutReplay()
    }),
    ("phase3 Work controller retains indeterminate command for explicit retry", {
        try await testWorkServiceAttachedControllerRetainsIndeterminateCommandUntilExplicitRetry()
    }),
    ("phase3 Work controller retries only exact indeterminate Start through recovery", {
        try await testWorkServiceAttachedControllerRetriesExactIndeterminateStartThroughRecoveryDescriptor()
    }),
    ("phase3 Work controller persists remote stale for recreation and reissue", {
        try await testWorkServiceAttachedControllerPersistsRemoteStaleForRecreationAndReissue()
    }),
    ("phase3 Work controller restores exact indeterminate intent after recreation", {
        try await testWorkServiceAttachedControllerRestoresExactIndeterminateIntentAfterRecreation()
    }),
    ("phase3 Work controller clears a shared durable intent idempotently", {
        try await testWorkServiceAttachedControllerClearsSharedIntentIdempotentlyAcrossGUIs()
    }),
    ("phase3 Work controller requires exact canonical command evidence", {
        try await testWorkServiceAttachedControllerKeepsAcceptedIntentUntilExactCanonicalEvidence()
    }),
    ("phase3 Work controller inspects terminal Work but rejects mutation", {
        try await testWorkServiceAttachedControllerCompletedWorkRemainsInspectableButRejectsMutation()
    }),
    ("phase3 Work controller disables mutation when attachment disappears", {
        try await testWorkServiceAttachedControllerMissingAttachmentDisablesMutation()
    }),
    ("phase3 Work controllers observe independently", {
        try await testWorkServiceAttachedControllersObserveIndependentlyAndDisconnectingOneDoesNotEndWork()
    }),
    ("phase3 Work controller bounds activities and messages explicitly", {
        try await testWorkServiceAttachedControllerBoundsCanonicalActivitiesAndMessagesExplicitly()
    }),
    ("phase3 Work controller pages history without moving canonical cursors", {
        try await testWorkServiceAttachedControllerPagesHistoryWithoutMovingCanonicalCursors()
    }),
    ("phase3 Work controller keeps frozen ancestor branch across descendant refresh", {
        try await testWorkServiceAttachedControllerKeepsFrozenAncestorBranchTipAcrossDescendantRefresh()
    }),
    ("phase3 Work controller acknowledges Work and Session with exact control chaining", {
        try await testWorkServiceAttachedControllerAcknowledgesWorkAndSessionWithExactControlChain()
    }),
    ("telemetry Work controller read acknowledgements preserve uncertainty without polling spans", {
        try await testWorkServiceAttachedControllerReadAcknowledgementTelemetry()
    }),
    ("telemetry Work controller read acknowledgements require durable local checkpoints", {
        try await testWorkServiceAttachedControllerReadAcknowledgementTelemetryCheckpointGate()
    }),
    ("telemetry Work controller read acknowledgements reject forged receipt evidence", {
        try await testWorkServiceAttachedControllerReadAcknowledgementTelemetryForgedReceipt()
    }),
    ("phase3 Work controller reconciles lost Work and Session acknowledgements", {
        try await testWorkServiceAttachedControllerReconcilesLostWorkAndSessionAcknowledgements()
    }),
    ("phase3 Work controller exactly replays an unadmitted acknowledgement", {
        try await testWorkServiceAttachedControllerExactlyReplaysAnUnadmittedAcknowledgement()
    }),
    ("phase3 Work controller eventually replays after three lost acknowledgements", {
        try await testWorkServiceAttachedControllerEventuallyReplaysAfterThreeLostResponses()
    }),
    ("phase3 Work controller retries after concurrent control advance", {
        try await testWorkServiceAttachedControllerRetriesSessionAcknowledgementAfterConcurrentControlAdvance()
    }),
    ("phase3 Work controller gates restored checkpoints until host validation", {
        try await testWorkServiceAttachedControllerRestoresCheckpointOnlyAsNoncanonicalUntilHostValidation()
    }),
    ("phase3 Work controller rejects a mismatched checkpoint prefix", {
        try await testWorkServiceAttachedControllerRejectsMismatchedCheckpointPrefixBeforeReplay()
    }),
    ("phase3 Work controller reauthenticates an invalidated incremental source", {
        try await testWorkServiceAttachedControllerReauthenticatesInvalidatedIncrementalReadWithoutReplayingCommand()
    }),
    ("phase3 Work controller read tracing omits error details", {
        testWorkServiceAttachedControllerReadTraceClassifierOmitsErrorDetails()
    }),
    ("phase3 Work controller bounds baseline replay for stable corruption", {
        try await testWorkServiceAttachedControllerAttemptsOnlyOneBaselineReplayForStableCorruption()
    }),
    ("phase3 Work controller rejects regressed or rewritten baseline prefix", {
        try await testWorkServiceAttachedControllerRejectsRegressedOrRewrittenBaselinePrefix()
    }),
    ("phase3 Work controller preserves exact checkpoint across host restart", {
        try await testWorkServiceAttachedControllerPreservesCheckpointAcrossHostRestart()
    }),
    ("phase3 Work controller detects torn and altered checkpoints", {
        try await testWorkServiceAttachedCheckpointStoreDetectsTornAndAlteredRecords()
    }),
    ("phase3 Work controller rejects v5 checkpoint and rebuilds native End kind", {
        try await testWorkServiceAttachedControllerRejectsV5SnapshotAndRebuildsNativeEndKind()
    }),
    ("phase3 Work controller skips no-op checkpoint writes", {
        try await testWorkServiceAttachedControllerSkipsCheckpointWriteForNoOpRefresh()
    }),
    ("phase3 Work controller treats checkpoint write failure as diagnostic", {
        try await testWorkServiceAttachedControllerCheckpointWriteFailureDoesNotHideCanonicalRead()
    }),
    ("phase3 Work controller bounds oversized checkpoints and replays on restart", {
        try await testWorkServiceAttachedControllerBoundsOversizedCheckpointAndReplaysOnRestart()
    }),
    ("phase3 Work controller resumes more than 256 pages", {
        try await testWorkServiceAttachedControllerResumesMoreThan256PagesFromCheckpointCursor()
    }),
]
