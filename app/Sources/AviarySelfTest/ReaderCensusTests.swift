import Foundation
@testable import AviaryCore

private enum ReaderCensusFixtureFiles {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ReaderCensus")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: root.appending(path: name))
    }

    static func manifest() throws -> ReaderCensusManifest {
        try JSONDecoder().decode(ReaderCensusManifest.self, from: data("manifest.json"))
    }
}

private let censusSessionJournal = JournalRef.session(
    SessionRef("census-session"), journalID: "session-journal",
    authority: TimelineAuthorityRef("session-authority"))
private let censusWorkJournal = JournalRef.work(
    WorkRef(workHostID: "census-host", workID: "census-work"), journalID: "work-journal")
private let censusControlJournal = JournalRef.workHost(
    WorkHostRef("census-host"), journalID: "control-journal")

private func prefixLines(_ data: Data, count: Int) -> Data {
    var result = Data()
    for line in data.split(separator: 0x0A).prefix(count) {
        result.append(contentsOf: line)
        result.append(0x0A)
    }
    return result
}

func test_readerCensusRecordedAgentsSurviveParentEnd() throws {
    let sessionData = prefixLines(try ReaderCensusFixtureFiles.data("session.jsonl"), count: 3)
    let workData = try ReaderCensusFixtureFiles.data("variants/work-agent-handle-lifecycle.jsonl")
    let sessionRead = ReaderCensus.read(sessionData, journal: censusSessionJournal)
    for count in 5...12 {
        let prefix = prefixLines(workData, count: count)
        let workRead = ReaderCensus.read(prefix, journal: censusWorkJournal)
        let report = ReaderCensus.report(
            sessionRead: sessionRead, workRead: workRead,
            sessionJournal: censusSessionJournal, workJournal: censusWorkJournal)
        XCTAssertTrue(report.workIntegrityValid)
        XCTAssertEqual(report.agentHandles.count, count < 7 ? 1 : 2)
        XCTAssertTrue(report.outstandingHandleIDs.isEmpty,
                      "Work-owned agents must not be conflated with Run-owned Handles")
        XCTAssertTrue(report.childStates.isEmpty,
                      "agent_handle events must not be inferred from child.lifecycle strings")
        let incremental = ReaderCensus.report(
            sessionRead: ReaderCensus.readIncrementally(
                sessionData, journal: censusSessionJournal, chunkSizes: [1, 7, 31]),
            workRead: ReaderCensus.readIncrementally(
                prefix, journal: censusWorkJournal, chunkSizes: [2, 19, 3]),
            sessionJournal: censusSessionJournal, workJournal: censusWorkJournal)
        XCTAssertEqual(incremental, report)
        let restored = try JSONDecoder().decode(
            ReaderCensusReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(restored, report)
        let recovery = try XCTUnwrap(report.canonicalWorkRecovery.rows.first)
        XCTAssertEqual(recovery.agentHandles, report.agentHandles)
        XCTAssertEqual(recovery.completionBlockingAgentHandleIDs,
                       report.completionBlockingAgentHandleIDs)
        if count >= 9 { XCTAssertNil(recovery.activeRun) }
        let catalog = try XCTUnwrap(report.canonicalSessionCatalog)
        XCTAssertFalse(catalog.work.isEmpty)
        for work in catalog.work {
            XCTAssertEqual(work.agentHandles, report.agentHandles)
            XCTAssertEqual(work.completionBlockingAgentHandleIDs,
                           report.completionBlockingAgentHandleIDs)
        }
        if count == 9 {
            XCTAssertEqual(report.agentHandles.map(\.state), [.running, .running])
            XCTAssertEqual(report.completionBlockingAgentHandleIDs, ["agent-a", "agent-b"])
        }
        if count == 12 {
            XCTAssertEqual(report.agentHandles.map(\.handleID), ["agent-b", "agent-a"])
            XCTAssertEqual(report.agentHandles.map(\.state), [.terminal, .reaped])
            XCTAssertEqual(report.agentHandles.first?.cleanupState, .indeterminate)
            XCTAssertEqual(report.completionBlockingAgentHandleIDs, ["agent-b"])
        }
        let metadata = String(decoding: try JSONEncoder().encode(report.agentHandles), as: UTF8.self)
        XCTAssertFalse(metadata.contains("private-agent-label-secret"))
        XCTAssertFalse(metadata.contains("request_body"))
        XCTAssertFalse(metadata.contains("result_body"))
        XCTAssertFalse(metadata.contains("deadline"))
    }
    // An unknown runtime event is preserved as an unknown, never interpreted as zero agents.
    let lastLine = try XCTUnwrap(workData.split(separator: 0x0A).last)
    var unknown = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(lastLine)) as? [String: Any])
    unknown["event_id"] = "unknown-agent-runtime"
    unknown["sequence"] = 13
    unknown["previous_event_id"] = "b-terminal"
    unknown["type"] = "runtime.future-agent-state"
    unknown["declared_domains"] = ["runtime"]
    unknown["payload"] = [:] as [String: String]
    var unknownData = workData
    unknownData.append(try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys]))
    unknownData.append(0x0A)
    let unknownReport = ReaderCensus.report(
        sessionData: sessionData, sessionJournal: censusSessionJournal,
        workData: unknownData, workJournal: censusWorkJournal)
    XCTAssertTrue(unknownReport.workIntegrityValid)
    XCTAssertTrue(unknownReport.unknownDomains.contains(.runtime))
    XCTAssertTrue(unknownReport.agentHandles.isEmpty)
    XCTAssertTrue(unknownReport.completionBlockingAgentHandleIDs.isEmpty)
    XCTAssertTrue(unknownReport.canonicalWorkRecovery.rows.first?.agentHandles.isEmpty == true)

    var tailed = workData
    tailed.append(Data("{\"event_id\":\"unfinished".utf8))
    let tailedReport = ReaderCensus.report(
        sessionData: sessionData, sessionJournal: censusSessionJournal,
        workData: tailed, workJournal: censusWorkJournal)
    XCTAssertFalse(tailedReport.workIntegrityValid)
    XCTAssertTrue(tailedReport.agentHandles.isEmpty)
}

func test_readerCensusCompletedWorkWithUnknownAgentsBlocksDestructiveActions() throws {
    let sessionRead = ReaderCensus.read(
        prefixLines(try ReaderCensusFixtureFiles.data("session.jsonl"), count: 3),
        journal: censusSessionJournal)
    let fixtureRead = ReaderCensus.read(
        try ReaderCensusFixtureFiles.data("variants/work-agent-handle-lifecycle.jsonl"),
        journal: censusWorkJournal)
    var events = Array(fixtureRead.records.prefix(6).map(\.event))
    let terminal = try XCTUnwrap(fixtureRead.records.first { $0.event.eventID == "a-terminal" })
    func append(_ id: String, type: String, domains: Set<TimelineDomain>,
                handle: HandleRef? = nil, payload: JSONValue = .object([:])) {
        events.append(TimelineEvent(
            eventID: id, journal: censusWorkJournal, sequence: events.count + 1,
            previousEventID: events.last?.eventID,
            causedByEventID: handle.map { _ in EventRef(journal: censusWorkJournal, eventID: "a-started") },
            session: SessionRef("census-session"),
            work: WorkRef(workHostID: "census-host", workID: "census-work"),
            workHost: WorkHostRef("census-host"), sessionAttachment: SessionAttachmentRef("sa-main"),
            run: RunRef("run-1"), handle: handle,
            actor: TimelineActor(actorID: "census-completion"),
            hostRecordedAt: Date(timeIntervalSince1970: 30), type: type,
            declaredDomains: domains, payload: payload))
    }
    append("ended", type: TimelineEventType.runFinished, domains: [.work, .runtime])
    append("settled", type: TimelineEventType.agentHandleTerminal,
           domains: [.work, .runtime, .externalEffects], handle: HandleRef("agent-a"),
           payload: terminal.event.payload)
    append("completed", type: TimelineEventType.workCompleted, domains: [.work])
    func report() throws -> ReaderCensusReport {
        var data = Data()
        for event in events {
            data.append(try JSONEncoder().encode(event))
            data.append(0x0A)
        }
        return ReaderCensus.report(
            sessionRead: sessionRead, workRead: ReaderCensus.read(data, journal: censusWorkJournal),
            sessionJournal: censusSessionJournal, workJournal: censusWorkJournal)
    }
    let complete = try report()
    XCTAssertTrue(complete.workIntegrityValid)
    let summary = try XCTUnwrap(complete.canonicalSessionCatalog)
    XCTAssertFalse(summary.hasOngoingOrUncertainAttachedWork)
    XCTAssertTrue(summary.work.allSatisfy(\.agentHandleFactsAvailable))
    for domain in [TimelineDomain.session, .runtime, .externalEffects] {
        append("unknown-\(domain.rawValue)", type: "future.agent-state", domains: [domain])
        let unknown = try report()
        XCTAssertTrue(unknown.workIntegrityValid)
        let unknownSummary = try XCTUnwrap(unknown.canonicalSessionCatalog)
        XCTAssertTrue(unknownSummary.hasOngoingOrUncertainAttachedWork,
                      "the Continue/Trash admission predicate must not infer safe absence")
        XCTAssertTrue(unknownSummary.work.allSatisfy { !$0.agentHandleFactsAvailable })
        XCTAssertTrue(unknownSummary.work.allSatisfy { $0.agentHandles.isEmpty })
        events.removeLast()
    }
}

func test_readerCensusFixtureProjectsCorePlanes() throws {
    let manifest = try ReaderCensusFixtureFiles.manifest()
    let controlData = try ReaderCensusFixtureFiles.data(manifest.controlJournal)
    try WorkHostControlJournal.validateDurabilitySeal(
        for: ReaderCensusFixtureFiles.root.appending(path: manifest.controlJournal),
        journal: censusControlJournal, data: controlData)
    let report = ReaderCensus.report(
        sessionData: try ReaderCensusFixtureFiles.data(manifest.sessionJournal),
        sessionJournal: censusSessionJournal,
        workData: try ReaderCensusFixtureFiles.data(manifest.workJournal),
        workJournal: censusWorkJournal,
        controlData: controlData,
        controlJournal: censusControlJournal,
        manifest: manifest)

    XCTAssertEqual(report.projectionRulesVersion, 2)
    XCTAssertTrue(report.agentHandles.isEmpty)
    XCTAssertTrue(report.completionBlockingAgentHandleIDs.isEmpty)
    XCTAssertEqual(report.sessionCommittedEventIDs.count, 18)
    XCTAssertEqual(report.workCommittedEventIDs.count, 19)
    XCTAssertTrue(report.sessionIntegrityValid)
    XCTAssertTrue(report.workIntegrityValid)
    XCTAssertTrue(report.sessionStructuralIntegrityValid)
    XCTAssertTrue(report.workStructuralIntegrityValid)
    XCTAssertTrue(report.sessionSemanticProjectionValid)
    XCTAssertTrue(report.workSemanticProjectionValid)
    let flock = try XCTUnwrap(report.canonicalFlock)
    XCTAssertTrue(flock.isAvailable)
    XCTAssertTrue(flock.integrityValid)
    XCTAssertEqual(flock.work, WorkRef(workHostID: "census-host", workID: "census-work"))
    XCTAssertEqual(flock.workHost, WorkHostRef("census-host"))
    XCTAssertEqual(flock.cursor?.eventID, "w21")
    XCTAssertEqual(flock.nodes.map(\.childID), ["child-1"])
    if let flockNode = flock.nodes.first {
        XCTAssertEqual(flockNode.state, "completed")
        XCTAssertNil(flockNode.name, "fixture omits a display name; Flock must not invent one")
        XCTAssertEqual(flockNode.source.eventID, "w19")
    } else {
        XCTFail("fixture Work row should retain its child lifecycle evidence")
    }
    let flockCatalog = try XCTUnwrap(report.canonicalFlockCatalog.first)
    XCTAssertFalse(flockCatalog.childLifecycleAvailable,
                   "Reader Census must exercise the production Flock projection boundary")
    XCTAssertTrue(flockCatalog.children.isEmpty)
    XCTAssertTrue(flockCatalog.unknownDomains.contains(.work)
                  || flockCatalog.unknownDomains.contains(.externalEffects)
                  || flockCatalog.unknownDomains.contains(.runtime))
    XCTAssertEqual(report.registeredConsumers, [
        "production local Timeline catalog", "canonical SessionCatalog projection",
        "canonical Flock adapter", "canonical Flock catalog projection", "canonical attention adapter",
        "canonical Session search", "canonical notification projection",
        "canonical Work recovery projection",
    ])
    let search = report.canonicalSessionSearch
    let searchDocument = try XCTUnwrap(search.documents.first)
    XCTAssertTrue(searchDocument.matches("selected branch is preserved"))
    XCTAssertFalse(searchDocument.matches("abandoned branch"))
    XCTAssertFalse(searchDocument.matches("earlier inspection was compacted"))
    XCTAssertEqual(searchDocument.sourceEventRefs.map(\.eventID), ["s6", "s7", "s10", "s11"])
    XCTAssertTrue(report.assemblerReady)
    XCTAssertEqual(report.visibleMessageIDs, ["s6", "s7", "s10", "s11"])
    XCTAssertEqual(report.activeTip?.eventID, "s11")
    XCTAssertEqual(report.contextInclusionIDs, ["include-pinned", "include-artifact"])
    XCTAssertEqual(report.omittedContextIDs, ["omit-history"])
    XCTAssertEqual(report.contextComponents.count, 3)
    XCTAssertEqual(report.compactionSummary,
                   "Earlier inspection was compacted; preserve the selected branch.")
    XCTAssertEqual(report.contextComponents[1].deliveryMode, .manifest)
    XCTAssertEqual(report.contextComponents[1].bodyReference?.referenceID, "artifact-large")
    XCTAssertEqual(report.contextComponents[1].fullByteCount, 109)
    XCTAssertEqual(
        report.contextComponents[1].digest,
        "sha256:d20df9c3095aae2a5f655826b2e5cf5ccc95a4e44dc42d5f355c97eda0770da1")
    XCTAssertEqual(
        report.contextComponents[1].bodyReference?.digest,
        report.contextComponents[1].digest)
    XCTAssertEqual(report.contextComponents[1].bodyReference?.byteCount, 109)
    XCTAssertEqual(
        Set(report.contextComponents.compactMap { $0.bodyReference?.referenceID }),
        Set(["artifact-large", "tool-result"]))
    XCTAssertEqual(report.contextComponents[2].fullByteCount, 63)
    XCTAssertEqual(
        report.contextComponents[2].digest,
        "sha256:f7423ed89ecf634efc2cbe26e719d08e53fd49888c41af2547b378740a5d7fe8")
    XCTAssertEqual(report.authoredAttention, .review)
    XCTAssertEqual(report.attention, .error)
    XCTAssertTrue(report.canonicalNotifications.candidates.isEmpty,
                  "Reader Census must withhold notifications when the exact Work state is unknown")
    let serializedReport = try JSONEncoder().encode(report)
    let restoredReport = try JSONDecoder().decode(
        ReaderCensusReport.self, from: serializedReport)
    XCTAssertEqual(restoredReport.canonicalNotifications, report.canonicalNotifications,
                   "the notification consumer receipt must survive Reader Census serialization")
    XCTAssertEqual(restoredReport.canonicalWorkRecovery, report.canonicalWorkRecovery,
                   "the Work recovery consumer receipt must survive Reader Census serialization")
    let recoveryProjection = try XCTUnwrap(report.canonicalWorkRecovery.rows.first)
    XCTAssertEqual(recoveryProjection.work,
                   WorkRef(workHostID: "census-host", workID: "census-work"))
    XCTAssertEqual(recoveryProjection.journal, censusWorkJournal)
    XCTAssertEqual(recoveryProjection.disposition, .uncertain,
                   "the fixture has complete durable Work facts but an unknown external-effects domain")
    XCTAssertEqual(recoveryProjection.activeRun, RunRef("run-1"))
    XCTAssertEqual(recoveryProjection.activeTurn, TurnRef("turn-1"))
    XCTAssertEqual(recoveryProjection.cursor?.eventID, "w21")
    XCTAssertEqual(recoveryProjection.committedPrefixCursor?.eventID, "w21")
    XCTAssertEqual(recoveryProjection.sessionAttachments.map(\.attachment.attachmentID).sorted(),
                   ["sa-main", "sa-remote"])
    XCTAssertEqual(recoveryProjection.clientAttachments.map(\.attachment.attachmentID).sorted(),
                   ["ca-local", "ca-remote"])
    let localRecoveryClient = try XCTUnwrap(recoveryProjection.clientAttachments.first {
        $0.client == ClientRef("client-local")
    })
    XCTAssertEqual(localRecoveryClient.readAcknowledgements.count, 1)
    XCTAssertEqual(localRecoveryClient.readAcknowledgements.first?.targetJournal,
                   censusWorkJournal)
    XCTAssertEqual(localRecoveryClient.readAcknowledgements.first?.cursor.eventID, "w21")
    let remoteRecoveryClient = try XCTUnwrap(recoveryProjection.clientAttachments.first {
        $0.client == ClientRef("client-remote")
    })
    XCTAssertEqual(remoteRecoveryClient.readAcknowledgements.count, 1)
    XCTAssertEqual(remoteRecoveryClient.readAcknowledgements.first?.targetJournal,
                   censusSessionJournal)
    XCTAssertEqual(remoteRecoveryClient.readAcknowledgements.first?.cursor.eventID, "s19")
    XCTAssertEqual(recoveryProjection.recoveryCoverage.count, 1)
    if let recovery = recoveryProjection.recoveryCoverage.first {
        XCTAssertEqual(recovery.coverage.operation, .coldResume)
    } else {
        XCTFail("the bounded Work recovery row should retain its recorded coverage")
    }
    XCTAssertEqual(recoveryProjection.unknownEventRefs.map(\.eventID), ["w21"])
    XCTAssertEqual(recoveryProjection.unknownDomains, [.externalEffects])
    XCTAssertEqual(recoveryProjection.omittedAttachmentCount, 0)
    XCTAssertEqual(recoveryProjection.omittedRecoveryCoverageCount, 0)
    XCTAssertTrue(report.canonicalWorkRecovery.sourceComplete,
                  "unknown row domains are evidence, not global discovery incompleteness")
    XCTAssertEqual(report.canonicalWorkRecovery.omittedRowCount, 0)
    XCTAssertEqual(report.canonicalWorkRecovery.omittedAttachmentCount, 0)
    XCTAssertEqual(report.canonicalWorkRecovery.omittedObservationCount, 0)
    var notificationDelivery = CanonicalNotificationDelivery()
    XCTAssertTrue(notificationDelivery.plan(report.canonicalNotifications).candidates.isEmpty,
                  "Reader Census must exercise the production delivery gate, not only register its name")
    let attentionRow = try XCTUnwrap(report.canonicalAttentionInbox.rows.first)
    XCTAssertEqual(attentionRow.authoredAttention, .review)
    XCTAssertNil(attentionRow.effectiveAttention,
                 "unknown runtime state must keep the notification boundary non-actionable")
    XCTAssertEqual(attentionRow.attentionRequirement, .unknown)
    XCTAssertTrue(attentionRow.sessionUnknownDomains.contains(.runtime))
    XCTAssertEqual(report.outstandingActionIDs, ["action-incomplete"])
    XCTAssertEqual(report.indeterminateActionIDs, ["action-indeterminate"])
    XCTAssertEqual(report.outstandingHandleIDs, ["handle-background"])
    XCTAssertTrue(report.outstandingCommandIDs.isEmpty)
    XCTAssertEqual(report.childStates, ["child-1": "completed"])
    XCTAssertEqual(report.modelIDs, ["model-v1", "model-v2"])
    XCTAssertEqual(report.runIDs, ["run-1"])
    XCTAssertEqual(report.recovery.count, 1)
    XCTAssertEqual(report.recovery[0].journal, censusWorkJournal)
    XCTAssertEqual(report.recovery[0].coverage.planes[.runtimeNamespace], .lost)
    XCTAssertEqual(report.attachments.count, 4)
    XCTAssertEqual(
        report.attachments.filter { $0.journal == censusSessionJournal }.count, 2)
    XCTAssertEqual(
        report.attachments.filter { $0.journal == censusControlJournal }.count, 2)
    XCTAssertTrue(report.unknownEventRefs.contains { $0.eventID == "w21" })
    XCTAssertEqual(report.unknownEventRefs.count, 2)
    XCTAssertEqual(
        Set(report.unknownEventRefs.map { $0.journal }),
        Set([censusSessionJournal, censusWorkJournal]))
    XCTAssertTrue(report.unknownDomains.contains(.runtime))
    XCTAssertEqual(report.unknownReferenceIDs, ["missing-activity"])
    XCTAssertEqual(report.unknownReferences.count, 1)
    XCTAssertEqual(report.unknownReferences[0].eventID, "missing-activity")
    XCTAssertEqual(report.intentionallyUnwiredConsumers, [
        "service recovery",
    ])

    let workEvents = ReaderCensus.read(
        try ReaderCensusFixtureFiles.data("work.jsonl"), journal: censusWorkJournal)
        .records.map(\.event)
    XCTAssertEqual(workEvents.first { $0.eventID == "w14" }?.payload["command_kind"]?.stringValue, "queue")
    XCTAssertEqual(workEvents.first { $0.eventID == "w14" }?.payload["delivery_mode"]?.stringValue, "queued")
    XCTAssertEqual(workEvents.first { $0.eventID == "w15" }?.payload["command_kind"]?.stringValue, "steer")
    XCTAssertEqual(workEvents.first { $0.eventID == "w15" }?.payload["late"]?.boolValue, true)
    XCTAssertEqual(workEvents.first { $0.eventID == "w11" }?.payload["kind"]?.stringValue, "mcp")
    XCTAssertEqual(workEvents.first { $0.eventID == "w11" }?.payload["tool_name"]?.stringValue, "shell")

    // Every retained body named by the manifest is addressable by a context body reference, and
    // the locator's measured bytes/digest agree with the actual retained bytes.
    let manifestBodyReferences = Set(report.contextComponents.compactMap { $0.bodyReference?.referenceID })
    XCTAssertTrue(manifestBodyReferences.isSuperset(of: ["artifact-large", "tool-result"]))
    let manifestBodyByReference = [
        "artifact-large": "bodies/large-artifact.json",
        "tool-result": "bodies/tool-result.txt",
    ]
    XCTAssertEqual(Set(manifest.retainedBodies), Set(manifestBodyByReference.values))
    for (referenceID, path) in manifestBodyByReference {
        let body = try ReaderCensusFixtureFiles.data(path)
        let component = try XCTUnwrap(report.contextComponents.first {
            $0.bodyReference?.referenceID == referenceID
        })
        XCTAssertEqual(component.bodyReference?.byteCount, body.count)
        XCTAssertEqual(component.fullByteCount, body.count)
        let digest = AviarySHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(component.bodyReference?.digest, "sha256:\(digest)")
    }

    // Bare IDs are only a compatibility view: the same event ID can legitimately occur in
    // separate journals and must remain distinguishable in the canonical report.
    let duplicateSessionData = Data(String(
        decoding: try ReaderCensusFixtureFiles.data("session.jsonl"), as: UTF8.self)
        .replacingOccurrences(of: "\"event_id\":\"s20\"", with: "\"event_id\":\"w21\"")
        .utf8)
    let duplicateReport = ReaderCensus.report(
        sessionData: duplicateSessionData, sessionJournal: censusSessionJournal,
        workData: try ReaderCensusFixtureFiles.data("work.jsonl"), workJournal: censusWorkJournal)
    XCTAssertEqual(duplicateReport.unknownEventRefs.map(\.eventID), ["w21", "w21"])
    XCTAssertEqual(Set(duplicateReport.unknownEventRefs.map(\.eventID)), ["w21"])
    XCTAssertEqual(
        Set(duplicateReport.unknownEventRefs.map { $0.journal }),
        Set([censusSessionJournal, censusWorkJournal]))
}

func test_readerCensusProjectsPositiveReadyNotificationAndDeliveryTransition() throws {
    let session = SessionRef("census-notification-ready")
    let sessionJournal = JournalRef.session(
        session, journalID: "notification-session-journal",
        authority: TimelineAuthorityRef("notification-session-service"))
    let workJournal = JournalRef.work(
        WorkRef(workHostID: "notification-work-host", workID: "unused-work"))
    let actor = TimelineActor(actorID: "reader-census-notification", kind: "self-test")
    let created = TimelineEvent(
        eventID: "ready-s1", journal: sessionJournal, sequence: 1,
        session: session, actor: actor,
        hostRecordedAt: Date(timeIntervalSince1970: 1),
        type: TimelineEventType.sessionCreated)
    let attention = TimelineEvent(
        eventID: "ready-s2", journal: sessionJournal, sequence: 2,
        previousEventID: "ready-s1", session: session, actor: actor,
        hostRecordedAt: Date(timeIntervalSince1970: 2),
        type: TimelineEventType.sessionAttention,
        payload: .object(["attention": .string(SessionAttention.review.rawValue)]))
    var sessionData = Data()
    for event in [created, attention] {
        sessionData.append(try JSONEncoder().encode(event))
        sessionData.append(0x0A)
    }

    let report = ReaderCensus.report(
        sessionData: sessionData, sessionJournal: sessionJournal,
        workData: Data(), workJournal: workJournal)
    let candidate = try XCTUnwrap(report.canonicalNotifications.candidates.first)
    XCTAssertEqual(candidate.kind, .readyForReview)
    XCTAssertEqual(candidate.actionIdentity.session, session)
    XCTAssertEqual(candidate.sourceCursor.eventID, "ready-s2")
    XCTAssertEqual(candidate.sourceEvent?.eventID, "ready-s2")

    var delivery = CanonicalNotificationDelivery()
    XCTAssertTrue(delivery.plan(
        CanonicalNotificationProjection(summaries: [])).candidates.isEmpty)
    let transition = delivery.plan(report.canonicalNotifications)
    XCTAssertEqual(transition.candidates, [candidate],
                   "Reader Census must exercise a positive production delivery transition")
}

func test_readerCensusFlockRejectsUnalignedOrForeignWork() throws {
    let workData = try ReaderCensusFixtureFiles.data("work.jsonl")
    let fullRead = ReaderCensus.read(workData, journal: censusWorkJournal)
    let snapshot = WorkReducer.reduce(fullRead.records.map(\.event))

    let staleRead = ReaderCensus.read(
        prefixLines(workData, count: 18), journal: censusWorkJournal)
    let stale = AgentTreeReader.canonicalProjection(work: snapshot, read: staleRead)
    XCTAssertFalse(stale.isAvailable)
    XCTAssertFalse(stale.integrityValid)
    XCTAssertTrue(stale.nodes.isEmpty)
    XCTAssertNil(stale.cursor)

    let foreignJournal = JournalRef.work(
        WorkRef(workHostID: "other-host", workID: "other-work"), journalID: "other-journal")
    let foreignRead = ReaderCensus.read(workData, journal: foreignJournal)
    let foreign = AgentTreeReader.canonicalProjection(work: snapshot, read: foreignRead)
    XCTAssertFalse(foreign.isAvailable)
    XCTAssertTrue(foreign.nodes.isEmpty)

    var mismatched = snapshot
    mismatched.workHost = WorkHostRef("other-host")
    let mismatchedProjection = AgentTreeReader.canonicalProjection(
        work: mismatched, read: fullRead)
    XCTAssertFalse(mismatchedProjection.isAvailable)
    XCTAssertTrue(mismatchedProjection.nodes.isEmpty)
}

func test_readerCensusRejectsMalformedChildOwnershipInsteadOfOmittingIt() throws {
    let original = try ReaderCensusFixtureFiles.data("work.jsonl")
    let childPrefix = "\"work\":{\"workHostID\":\"census-host\",\"workID\":\"census-work\"},\"payload\":{\"child_id\":\"child-1\""

    func assertUnavailable(_ data: Data, structural: Bool = false) throws {
        let read = ReaderCensus.read(data, journal: censusWorkJournal)
        let snapshot = WorkReducer.reduce(read.records.map(\.event))
        if structural {
            XCTAssertFalse(snapshot.structuralIntegrityValid)
        } else {
            XCTAssertFalse(snapshot.semanticProjectionValid)
        }
        XCTAssertTrue(snapshot.childStates["child-1"] == nil)
        let projection = AgentTreeReader.canonicalProjection(work: snapshot, read: read)
        XCTAssertFalse(projection.isAvailable)
        XCTAssertTrue(projection.nodes.isEmpty)
    }

    let missingWork = Data(String(decoding: original, as: UTF8.self)
        .replacingOccurrences(of: childPrefix,
                              with: "\"payload\":{\"child_id\":\"child-1\"")
        .utf8)
    try assertUnavailable(missingWork)

    let foreignWork = Data(String(decoding: original, as: UTF8.self)
        .replacingOccurrences(
            of: childPrefix,
            with: "\"work\":{\"workHostID\":\"other-host\",\"workID\":\"other-work\"},\"payload\":{\"child_id\":\"child-1\"")
        .utf8)
    try assertUnavailable(foreignWork, structural: true)

    let parentSessionMismatch = Data(String(decoding: original, as: UTF8.self)
        .replacingOccurrences(
            of: childPrefix,
            with: "\"work\":{\"workHostID\":\"census-host\",\"workID\":\"census-work\"},\"session\":{\"sessionID\":\"census-session\"},\"payload\":{\"child_id\":\"child-1\",\"parent_session_id\":\"other-session\""
        )
        .utf8)
    try assertUnavailable(parentSessionMismatch)

    let parentRunMismatch = Data(String(decoding: original, as: UTF8.self)
        .replacingOccurrences(
            of: childPrefix,
            with: "\"work\":{\"workHostID\":\"census-host\",\"workID\":\"census-work\"},\"run\":{\"runID\":\"run-1\"},\"payload\":{\"child_id\":\"child-1\",\"parent_run_id\":\"other-run\""
        )
        .utf8)
    try assertUnavailable(parentRunMismatch)
}

func test_readerCensusIndeterminateActionOverridesAuthoredAttention() throws {
    let original = try ReaderCensusFixtureFiles.data("session.jsonl")
    let altered = Data(String(decoding: original, as: UTF8.self)
        .replacingOccurrences(of: "\"attention\":\"review\"", with: "\"attention\":\"none\"")
        .utf8)
    let report = ReaderCensus.report(
        sessionData: altered, sessionJournal: censusSessionJournal,
        workData: try ReaderCensusFixtureFiles.data("work.jsonl"), workJournal: censusWorkJournal)
    XCTAssertEqual(report.authoredAttention, .none)
    XCTAssertEqual(report.attention, .error)
    XCTAssertEqual(report.indeterminateActionIDs, ["action-indeterminate"])
}

func test_readerCensusRejectsContradictoryRetainedBodyMetadata() throws {
    let original = try ReaderCensusFixtureFiles.data("session.jsonl")
    let altered = Data(String(decoding: original, as: UTF8.self)
        .replacingOccurrences(
            of: "\"byte_count\":109,\"digest\":\"sha256:d20df9c3095aae2a5f655826b2e5cf5ccc95a4e44dc42d5f355c97eda0770da1\"",
            with: "\"byte_count\":109,\"digest\":\"sha256:contradictory\"")
        .utf8)
    let report = ReaderCensus.report(
        sessionData: altered, sessionJournal: censusSessionJournal,
        workData: try ReaderCensusFixtureFiles.data("work.jsonl"), workJournal: censusWorkJournal)
    XCTAssertFalse(report.sessionSemanticProjectionValid)
    XCTAssertFalse(report.sessionIntegrityValid)
    XCTAssertTrue(report.workSemanticProjectionValid)
}

func test_readerCensusIncrementalChunksMatchWholeRead() throws {
    let sessionData = try ReaderCensusFixtureFiles.data("session.jsonl")
    let workData = try ReaderCensusFixtureFiles.data("work.jsonl")
    let wholeSession = ReaderCensus.read(sessionData, journal: censusSessionJournal)
    let wholeWork = ReaderCensus.read(workData, journal: censusWorkJournal)
    let chunkSizes = [1, 2, 7, 3, 19, 5, 11]
    let incrementalSession = ReaderCensus.readIncrementally(
        sessionData, journal: censusSessionJournal, chunkSizes: chunkSizes)
    let incrementalWork = ReaderCensus.readIncrementally(
        workData, journal: censusWorkJournal, chunkSizes: chunkSizes)

    XCTAssertEqual(
        incrementalSession.records.map { $0.event.eventID },
        wholeSession.records.map { $0.event.eventID })
    XCTAssertEqual(
        incrementalWork.records.map { $0.event.eventID },
        wholeWork.records.map { $0.event.eventID })
    XCTAssertNil(incrementalSession.quarantinedSuffix)
    XCTAssertNil(incrementalSession.truncatedTail)
    XCTAssertNil(incrementalWork.quarantinedSuffix)
    XCTAssertNil(incrementalWork.truncatedTail)

    let wholeReport = ReaderCensus.report(
        sessionRead: wholeSession, workRead: wholeWork,
        sessionJournal: censusSessionJournal, workJournal: censusWorkJournal)
    let incrementalReport = ReaderCensus.report(
        sessionRead: incrementalSession, workRead: incrementalWork,
        sessionJournal: censusSessionJournal, workJournal: censusWorkJournal)
    XCTAssertEqual(incrementalReport, wholeReport)

    // A fixed seed gives reproducible coverage while exercising boundaries that tend to split
    // inside JSON strings, escaped values, and nested references.
    for seed in 1...8 {
        let schedule = (0..<9).map { ((seed * 31 + $0 * 17) % 23) + 1 }
        let session = ReaderCensus.readIncrementally(
            sessionData, journal: censusSessionJournal, chunkSizes: schedule)
        let work = ReaderCensus.readIncrementally(
            workData, journal: censusWorkJournal, chunkSizes: schedule)
        XCTAssertEqual(session.records.map { $0.event.eventID }, wholeSession.records.map { $0.event.eventID })
        XCTAssertEqual(work.records.map { $0.event.eventID }, wholeWork.records.map { $0.event.eventID })
        XCTAssertEqual(session.truncatedTail?.rawBytes.count, wholeSession.truncatedTail?.rawBytes.count)
        XCTAssertEqual(work.truncatedTail?.rawBytes.count, wholeWork.truncatedTail?.rawBytes.count)
    }

    // Prefixes model a remote reader that has only fetched part of either journal. Both reader
    // modes must agree on committed bytes, reduced snapshots, and the assembled report.
    for step in 1...11 {
        let sessionPrefix = Data(sessionData.prefix(max(1, sessionData.count * step / 12)))
        let workPrefix = Data(workData.prefix(max(1, workData.count * step / 12)))
        let wholeSessionPrefix = ReaderCensus.read(sessionPrefix, journal: censusSessionJournal)
        let incrementalSessionPrefix = ReaderCensus.readIncrementally(
            sessionPrefix, journal: censusSessionJournal, chunkSizes: [2, 5, 13])
        let wholePrefix = ReaderCensus.read(workPrefix, journal: censusWorkJournal)
        let incrementalPrefix = ReaderCensus.readIncrementally(
            workPrefix, journal: censusWorkJournal, chunkSizes: [2, 5, 13])
        XCTAssertEqual(
            incrementalSessionPrefix.records.map { $0.event.eventID },
            wholeSessionPrefix.records.map { $0.event.eventID })
        XCTAssertEqual(
            SessionReducer.reduce(incrementalSessionPrefix.records.map { $0.event }),
            SessionReducer.reduce(wholeSessionPrefix.records.map { $0.event }))
        XCTAssertEqual(
            incrementalPrefix.records.map { $0.event.eventID },
            wholePrefix.records.map { $0.event.eventID })
        XCTAssertEqual(
            WorkReducer.reduce(incrementalPrefix.records.map { $0.event }),
            WorkReducer.reduce(wholePrefix.records.map { $0.event }))
        XCTAssertEqual(incrementalPrefix.truncatedTail?.rawBytes.count, wholePrefix.truncatedTail?.rawBytes.count)
        XCTAssertEqual(incrementalPrefix.quarantinedSuffix?.rawBytes.count, wholePrefix.quarantinedSuffix?.rawBytes.count)
        XCTAssertEqual(
            ReaderCensus.report(
                sessionRead: incrementalSessionPrefix, workRead: incrementalPrefix,
                sessionJournal: censusSessionJournal, workJournal: censusWorkJournal),
            ReaderCensus.report(
                sessionRead: wholeSessionPrefix, workRead: wholePrefix,
                sessionJournal: censusSessionJournal, workJournal: censusWorkJournal))
    }

    // Session has already recorded a cursor for Work w21 while the remote Work page ends at w20.
    // The assembler must not silently substitute the older Work cursor and claim attachment.
    let delayedSession = ReaderCensus.read(
        prefixLines(sessionData, count: 18), journal: censusSessionJournal)
    let delayedWork = ReaderCensus.read(
        prefixLines(workData, count: 18), journal: censusWorkJournal)
    let delayedReport = ReaderCensus.report(
        sessionRead: delayedSession, workRead: delayedWork,
        sessionJournal: censusSessionJournal, workJournal: censusWorkJournal)
    XCTAssertFalse(delayedReport.assemblerReady)

    // A Session prefix with no active Work attachment is a complete assembly in its own right;
    // the absence of a Work page must not make every early/session-only projection look broken.
    let unattachedSession = ReaderCensus.read(
        prefixLines(sessionData, count: 1), journal: censusSessionJournal)
    let unavailableWork = ReaderCensus.read(
        Data(), journal: censusWorkJournal)
    let unattachedReport = ReaderCensus.report(
        sessionRead: unattachedSession, workRead: unavailableWork,
        sessionJournal: censusSessionJournal, workJournal: censusWorkJournal)
    XCTAssertTrue(unattachedReport.assemblerReady)
    XCTAssertTrue(unattachedReport.canonicalWorkRecovery.rows.isEmpty,
                  "an absent Work page must not manufacture an identity-less recovery row")
    XCTAssertFalse(unattachedReport.canonicalWorkRecovery.sourceComplete)
}

func test_readerCensusMalformedAndTruncatedTailsStayVisible() throws {
    let malformed = try ReaderCensus.read(
        ReaderCensusFixtureFiles.data("variants/work-malformed.jsonl"), journal: censusWorkJournal)
    XCTAssertEqual(malformed.records.map { $0.event.eventID }, ["w1"])
    XCTAssertNotNil(malformed.quarantinedSuffix)
    XCTAssertNil(malformed.truncatedTail)

    // This fixture deliberately has no final newline: the last record is a transport-truncated
    // tail under the real byte reader contract and must not be treated as committed.
    let truncatedBytes = try ReaderCensusFixtureFiles.data("variants/work-truncated.jsonl")
    XCTAssertTrue(truncatedBytes.last != 0x0A, "truncated fixture must be unterminated")
    let truncated = ReaderCensus.read(truncatedBytes, journal: censusWorkJournal)
    XCTAssertEqual(truncated.records.map { $0.event.eventID }, ["w1"])
    XCTAssertNotNil(truncated.truncatedTail)
    XCTAssertNil(truncated.quarantinedSuffix)
}

func test_readerCensusLegacyJournalKeepsSyntheticIdentity() throws {
    let journal = JournalRef.session(
        SessionRef("legacy-census"), journalID: "legacy-journal",
        authority: TimelineAuthorityRef("legacy-authority"))
    let result = ReaderCensus.read(
        try ReaderCensusFixtureFiles.data("legacy.jsonl"), journal: journal)
    XCTAssertEqual(result.records.count, 2)
    XCTAssertTrue(result.records.allSatisfy { $0.event.provenance == .legacyAdapted })
    XCTAssertTrue(result.records[0].event.eventID.hasPrefix("legacy:"))
    XCTAssertEqual(result.records[0].legacyRawID, "legacy-census")
    XCTAssertNil(result.truncatedTail)
    XCTAssertNil(result.quarantinedSuffix)
}

func test_readerCensusManifestAndRetainedBodiesRoundTrip() throws {
    let manifest = try ReaderCensusFixtureFiles.manifest()
    let roundTrip = try JSONDecoder().decode(
        ReaderCensusManifest.self, from: JSONEncoder().encode(manifest))
    XCTAssertEqual(roundTrip, manifest)
    for path in manifest.retainedBodies {
        let body = try ReaderCensusFixtureFiles.data(path)
        XCTAssertFalse(body.isEmpty)
        let expected: (Int, String)
        if path.hasSuffix("large-artifact.json") {
            expected = (109, "d20df9c3095aae2a5f655826b2e5cf5ccc95a4e44dc42d5f355c97eda0770da1")
        } else {
            expected = (63, "f7423ed89ecf634efc2cbe26e719d08e53fd49888c41af2547b378740a5d7fe8")
        }
        XCTAssertEqual(body.count, expected.0)
        XCTAssertEqual(
            AviarySHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(), expected.1)
    }
}
