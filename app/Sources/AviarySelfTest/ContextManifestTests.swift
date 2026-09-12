import Foundation
@testable import AviaryCore

private let contextManifestWork = WorkRef(
    workHostID: "context-work-host", workID: "context-work")
private let contextManifestWorkHost = WorkHostRef(contextManifestWork.workHostID)

private func contextManifestRequest() -> ChatRequest {
    ChatRequest(
        model: "model",
        messages: [
            .system("stable instructions"),
            .init(role: .user, content: [.text("private request body")]),
            .init(role: .assistant, content: [
                .text("answer"), .thinking("private reasoning that is not replayable")
            ]),
        ],
        tools: [ChatTool(
            name: "lookup", description: "private tool description",
            parameters: .object(["secret": .string("private schema value")]))])
}

private func retainedContextManifest(
    request: ChatRequest,
    store: ContextBodyStore,
    journal: JournalRef,
    manifestID: String = "context-run:model:0",
    requestID: String = "request-0",
    priorDeliveredBytes: Int = 0
) throws -> ContextManifest {
    let base = try ContextManifest.build(
        request: request, manifestID: manifestID, requestID: requestID,
        priorDeliveredBytes: priorDeliveredBytes)
    var references: [String: TimelineBodyReference] = [:]
    for (index, message) in request.messages.enumerated() {
        let component = base.components[index]
        references[component.sourceID] = try store.retain(
            try ContextManifest.bodyData(for: message), authority: journal,
            mediaType: "application/vnd.aviary.chat-message+json")
    }
    if !request.tools.isEmpty, let component = base.components.last {
        references[component.sourceID] = try store.retain(
            try ContextManifest.toolsData(for: request.tools), authority: journal,
            mediaType: "application/vnd.aviary.tool-schema-manifest+json")
    }
    return try ContextManifest.build(
        request: request, manifestID: manifestID, requestID: requestID,
        bodyReferences: references, priorDeliveredBytes: priorDeliveredBytes)
}

private func contextManifestJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(value)))
}

private func contextManifestPayload(
    _ manifest: ContextManifest, overrides: [String: JSONValue] = [:]
) throws -> JSONValue {
    var payload: [String: JSONValue] = [
        "manifest_id": .string(manifest.manifestID),
        "request_id": .string(manifest.requestID),
        "model_id": .string(manifest.modelID),
        "schema_version": .number(Double(manifest.schemaVersion)),
        "measured_by": .string(manifest.measuredBy),
        "measured_bytes": .number(Double(manifest.measuredBytes)),
        "delivered_bytes": .number(Double(manifest.deliveredBytes)),
        "cumulative_delivered_bytes": .number(Double(manifest.cumulativeDeliveredBytes)),
        "components": .array(try manifest.components.map(contextManifestJSON)),
        "omissions": .array(try manifest.omissions.map(contextManifestJSON)),
    ]
    for (key, value) in overrides { payload[key] = value }
    return .object(payload)
}

private func contextSessionEvent(
    _ type: String, id: String, sequence: Int, journal: JournalRef,
    previous: String? = nil, work: WorkRef? = nil, workHost: WorkHostRef? = nil,
    run: RunRef? = nil, payload: JSONValue = .object([:])
) -> TimelineEvent {
    let session: SessionRef?
    if case .session(let owner) = journal.owner { session = owner } else { session = nil }
    return TimelineEvent(
        eventID: id, journal: journal, sequence: sequence,
        previousEventID: previous, session: session,
        work: work, workHost: workHost, run: run,
        actor: TimelineActor(actorID: "context-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: Double(sequence)),
        type: type, declaredDomains: [.session, .context], payload: payload)
}

func test_contextManifestIsStableMeasuredAndSecretSafe() throws {
    let request = contextManifestRequest()
    let sourceJournal = JournalRef.session(
        SessionRef("context-session"), authority: TimelineAuthorityRef("context-service"))
    let source = ContextSourceRef(
        sourceID: "session.message.user-1",
        provenance: EventRef(journal: sourceJournal, eventID: "user-1"))

    let first = try ContextManifest.build(
        request: request, manifestID: "run-1:model:0", requestID: "request-0",
        sourceRefs: [1: source])
    let user = try XCTUnwrap(first.components.first { $0.sourceID == source.sourceID })
    let body = TimelineBodyReference(
        authority: sourceJournal, referenceID: "body-user-1",
        mediaType: "text/plain", byteCount: user.fullByteCount, digest: user.digest)
    let second = try ContextManifest.build(
        request: request, manifestID: "run-1:model:0", requestID: "request-0",
        sourceRefs: [1: source], bodyReferences: [source.sourceID: body],
        priorDeliveredBytes: 123)

    XCTAssertEqual(first.components.map(\.componentID), second.components.map(\.componentID))
    XCTAssertEqual(second.cumulativeDeliveredBytes, 123 + second.deliveredBytes)
    XCTAssertEqual(second.components.first { $0.sourceID == source.sourceID }?.bodyReference, body)
    XCTAssertEqual(
        second.components.first { $0.sourceID == source.sourceID }?.source.provenance,
        source.provenance)
    XCTAssertTrue(second.measuredBytes > 0)
    XCTAssertTrue(second.deliveredBytes > 0)
    XCTAssertEqual(second.measuredBy, ContextManifest.measurementBasis)
    XCTAssertTrue(second.omissions.contains { $0.reason == "provider_does_not_accept_replayed_reasoning" })
    XCTAssertEqual(second.components[2].deliveryMode, .truncated)

    let encoded = try JSONEncoder().encode(second)
    let encodedText = String(decoding: encoded, as: UTF8.self)
    XCTAssertFalse(encodedText.contains("private request body"))
    XCTAssertFalse(encodedText.contains("private reasoning that is not replayable"))
    XCTAssertFalse(encodedText.contains("private schema value"))

    let delimiterText = ChatMessage(
        role: .user,
        content: [.text("a\ntool_result:id:name:false:x")])
    let structuredBlocks = ChatMessage(
        role: .user,
        content: [
            .text("a"), .toolResult(id: "id", name: "name", text: "x", isError: false),
        ])
    XCTAssertNotEqual(
        try ContextManifest.bodyData(for: delimiterText),
        try ContextManifest.bodyData(for: structuredBlocks),
        "typed canonical encoding must not alias content that resembles its field labels")

    var firstOrder: [String: JSONValue] = [:]
    firstOrder["alpha"] = 1
    firstOrder["beta"] = 2
    var secondOrder: [String: JSONValue] = [:]
    secondOrder["beta"] = 2
    secondOrder["alpha"] = 1
    XCTAssertEqual(
        try ContextManifest.toolsData(for: [ChatTool(
            name: "ordered", description: "stable", parameters: .object(firstOrder))]),
        try ContextManifest.toolsData(for: [ChatTool(
            name: "ordered", description: "stable", parameters: .object(secondOrder))]),
        "object insertion order must not change a durable component identity")

    var rejectedNonFiniteNumbers = 0
    for invalidNumber in [Double.nan, Double.infinity, -Double.infinity] {
        do {
            _ = try ContextManifest.build(
                request: ChatRequest(
                    model: "provider/model", messages: [.system("instructions")],
                    tools: [ChatTool(
                        name: "invalid", description: "must fail before a permit",
                        parameters: .object(["value": .number(invalidNumber)]))]),
                manifestID: "invalid-number", requestID: "invalid-number")
            XCTFail("non-finite request data must fail before a manifest or permit exists")
        } catch {
            rejectedNonFiniteNumbers += 1
        }
    }
    XCTAssertEqual(rejectedNonFiniteNumbers, 3)
}

func test_contextManifestRejectsContradictoryBodyMetadata() throws {
    let request = contextManifestRequest()
    let journal = JournalRef.session(
        SessionRef("context-session"), authority: TimelineAuthorityRef("context-service"))
    let source = ContextSourceRef(sourceID: "session.message.user-1")
    let first = try ContextManifest.build(
        request: request, manifestID: "run-1:model:0", requestID: "request-0",
        sourceRefs: [1: source])
    let user = try XCTUnwrap(first.components.first { $0.sourceID == source.sourceID })
    let contradictory = TimelineBodyReference(
        authority: journal, referenceID: "body-user-1", mediaType: "text/plain",
        byteCount: (user.fullByteCount ?? 0) + 1, digest: "sha256:not-the-body")
    let second = try ContextManifest.build(
        request: request, manifestID: "run-1:model:0", requestID: "request-0",
        sourceRefs: [1: source], bodyReferences: [source.sourceID: contradictory])
    XCTAssertNil(second.components.first { $0.sourceID == source.sourceID }?.bodyReference)
    XCTAssertTrue(second.omissions.contains { $0.reason == "retained_body_metadata_mismatch" })
}

func test_contextCrossingRejectsMissingRetainedBodyAndFalseCumulativeClaims() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-context-boundary-\(UUID().uuidString)", directoryHint: .isDirectory)
    let foreignRoot = FileManager.default.temporaryDirectory.appending(
        path: "aviary-context-foreign-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: foreignRoot)
    }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("context-boundary-session")
    let work = WorkRef(workHostID: hostID, workID: "context-boundary-work")
    let run = RunRef("context-boundary-run")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("context-service"),
        sessionAttachment: SessionAttachmentRef("context-attachment"), run: run,
        actor: TimelineActor(actorID: "context-test", kind: "self-test"),
        modelID: "provider/model")

    let absent = try retainedContextManifest(
        request: contextManifestRequest(), store: ContextBodyStore(home: AgentHome(root: foreignRoot)),
        journal: bundle.sessionJournal)
    do {
        _ = try await bundle.prepareModelCrossing(
            manifest: absent, admission: fixtureProviderAdmission(), kind: .provider,
            target: "provider/model")
        XCTFail("metadata-only retained body claims must not authorize a provider request")
    } catch { }
    XCTAssertEqual(await bundle.activeRunContextDeliveredBytes, 0)

    let store = ContextBodyStore(home: home)
    let falseFirst = try retainedContextManifest(
        request: contextManifestRequest(), store: store, journal: bundle.sessionJournal,
        manifestID: "false-first", requestID: "false-first", priorDeliveredBytes: 1)
    do {
        _ = try await bundle.prepareModelCrossing(
            manifest: falseFirst, admission: fixtureProviderAdmission(), kind: .provider,
            target: "provider/model")
        XCTFail("the first cumulative total must equal this crossing")
    } catch { }

    let first = try retainedContextManifest(
        request: contextManifestRequest(), store: store, journal: bundle.sessionJournal,
        manifestID: "first", requestID: "first")
    let firstPermit = try await bundle.prepareModelCrossing(
        manifest: first, admission: fixtureProviderAdmission(), kind: .provider,
        target: "provider/model")
    _ = try await bundle.finishAction(firstPermit, state: .succeeded, retrySafety: .unsafe,
        providerSettlement: fixtureProviderSettlement(firstPermit))
    XCTAssertEqual(await bundle.activeRunContextDeliveredBytes, first.deliveredBytes)

    let jumped = try retainedContextManifest(
        request: contextManifestRequest(), store: store, journal: bundle.sessionJournal,
        manifestID: "jumped", requestID: "jumped",
        priorDeliveredBytes: first.cumulativeDeliveredBytes + 1)
    do {
        _ = try await bundle.prepareModelCrossing(
            manifest: jumped, admission: fixtureProviderAdmission(), kind: .provider,
            target: "provider/model")
        XCTFail("a later cumulative total must advance by exactly this crossing")
    } catch { }
    XCTAssertEqual(await bundle.activeRunContextDeliveredBytes, first.cumulativeDeliveredBytes)

    let events = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2SessionJournalURL(session)),
        journal: bundle.sessionJournal,
        actor: TimelineActor(actorID: "context-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1)).records.map(\.event)
    XCTAssertEqual(events.filter { $0.type == TimelineEventType.contextAssembled }.count, 1)
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
}

func test_contextManifestColdReplayUsesCanonicalValidationAndRunScopedTotals() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-context-replay-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SessionRef("context-replay-session")
    let journal = JournalRef.session(
        session, journalID: "context-replay-journal",
        authority: TimelineAuthorityRef("context-service"))
    let run = RunRef("context-replay-run")
    let first = try retainedContextManifest(
        request: contextManifestRequest(), store: ContextBodyStore(home: AgentHome(root: root)),
        journal: journal, manifestID: "replay-first", requestID: "replay-first")
    let genesis = contextSessionEvent(
        TimelineEventType.sessionCreated, id: "s1", sequence: 1, journal: journal)

    func reduced(
        _ payload: JSONValue,
        work eventWork: WorkRef? = contextManifestWork,
        workHost eventWorkHost: WorkHostRef? = contextManifestWorkHost,
        run eventRun: RunRef? = run
    ) -> SessionSnapshot {
        SessionReducer.reduce([
            genesis,
            contextSessionEvent(
                TimelineEventType.contextAssembled, id: "s2", sequence: 2,
                journal: journal, previous: "s1", work: eventWork,
                workHost: eventWorkHost, run: eventRun, payload: payload),
        ])
    }

    let valid = reduced(try contextManifestPayload(first))
    XCTAssertTrue(valid.semanticProjectionValid)
    XCTAssertEqual(valid.contextManifest, first)
    XCTAssertEqual(valid.contextCumulativeDeliveredBytesByRun?[run.runID], first.deliveredBytes)

    var invalidPayloads: [JSONValue] = [
        try contextManifestPayload(first, overrides: ["schema_version": 99]),
        try contextManifestPayload(first, overrides: ["measured_by": "provider_http_bytes"]),
        try contextManifestPayload(first, overrides: [
            "cumulative_delivered_bytes": .number(Double(first.cumulativeDeliveredBytes + 1)),
        ]),
    ]
    let firstComponent = try XCTUnwrap(first.components.first)
    invalidPayloads.append(try contextManifestPayload(first, overrides: [
        "components": .array([
            try contextManifestJSON(firstComponent), try contextManifestJSON(firstComponent),
        ]),
        "measured_bytes": .number(Double((firstComponent.measuredBytes ?? 0) * 2)),
        "delivered_bytes": .number(Double((firstComponent.deliveredBytes ?? 0) * 2)),
        "cumulative_delivered_bytes": .number(Double((firstComponent.deliveredBytes ?? 0) * 2)),
    ]))
    let foreignJournal = JournalRef.session(
        session, journalID: "foreign-context-journal",
        authority: TimelineAuthorityRef("foreign-service"))
    let foreign = try retainedContextManifest(
        request: contextManifestRequest(), store: ContextBodyStore(home: AgentHome(root: root)),
        journal: foreignJournal, manifestID: "foreign", requestID: "foreign")
    invalidPayloads.append(try contextManifestPayload(foreign))

    for payload in invalidPayloads {
        let snapshot = reduced(payload)
        XCTAssertFalse(snapshot.semanticProjectionValid)
        XCTAssertNil(snapshot.contextManifest)
        XCTAssertEqual(snapshot.quarantinedEvents.count, 1)
    }

    let hugeCount = 5_000_000_000_000_000_000
    let hugeDigest = "sha256:" + String(repeating: "0", count: 64)
    func hugeComponent(_ suffix: String) -> ContextComponent {
        ContextComponent(
            componentID: "huge-\(suffix)", inclusionID: "huge-inclusion-\(suffix)",
            sourceID: "huge-source-\(suffix)", mode: .history,
            measuredBytes: hugeCount, includedBytes: hugeCount,
            deliveredBytes: hugeCount, fullByteCount: hugeCount,
            bodyReference: TimelineBodyReference(
                authority: journal, referenceID: hugeDigest,
                byteCount: hugeCount, digest: hugeDigest),
            digest: hugeDigest)
    }
    let overflow = ContextManifest(
        manifestID: "overflow", requestID: "overflow", modelID: "provider/model",
        components: [hugeComponent("one"), hugeComponent("two")])
    XCTAssertEqual(overflow.measuredBytes, -1)
    XCTAssertEqual(overflow.deliveredBytes, -1)
    XCTAssertFalse(reduced(try contextManifestPayload(overflow)).semanticProjectionValid)

    XCTAssertFalse(reduced(try contextManifestPayload(first), run: nil).semanticProjectionValid)
    XCTAssertFalse(reduced(
        try contextManifestPayload(first), work: nil, workHost: nil
    ).semanticProjectionValid)
    XCTAssertFalse(reduced(
        try contextManifestPayload(first),
        workHost: WorkHostRef("mismatched-work-host")
    ).semanticProjectionValid)
    XCTAssertFalse(reduced(
        try contextManifestPayload(first),
        work: WorkRef(workHostID: "", workID: ""), workHost: WorkHostRef("")
    ).semanticProjectionValid)
    XCTAssertFalse(reduced(
        try contextManifestPayload(first), run: RunRef("")
    ).semanticProjectionValid)

    let second = try retainedContextManifest(
        request: contextManifestRequest(), store: ContextBodyStore(home: AgentHome(root: root)),
        journal: journal, manifestID: "replay-second", requestID: "replay-second",
        priorDeliveredBytes: first.cumulativeDeliveredBytes)
    let persisted = try JSONDecoder().decode(
        SessionSnapshot.self, from: JSONEncoder().encode(valid))
    var resumed = SessionReducer(snapshot: persisted)
    resumed.apply(contextSessionEvent(
        TimelineEventType.contextAssembled, id: "s3", sequence: 3,
        journal: journal, previous: "s2", work: contextManifestWork,
        workHost: contextManifestWorkHost, run: run,
        payload: try contextManifestPayload(second)))
    XCTAssertTrue(resumed.snapshot.semanticProjectionValid)
    XCTAssertEqual(
        resumed.snapshot.contextCumulativeDeliveredBytesByRun?[run.runID],
        second.cumulativeDeliveredBytes)

    var jumpedPayload = try XCTUnwrap(contextManifestPayload(second).objectValue)
    jumpedPayload["cumulative_delivered_bytes"] = .number(Double(second.cumulativeDeliveredBytes + 1))
    var jumped = SessionReducer(snapshot: valid)
    jumped.apply(contextSessionEvent(
        TimelineEventType.contextAssembled, id: "s3", sequence: 3,
        journal: journal, previous: "s2", work: contextManifestWork,
        workHost: contextManifestWorkHost, run: run, payload: .object(jumpedPayload)))
    XCTAssertFalse(jumped.snapshot.semanticProjectionValid)
    XCTAssertEqual(jumped.snapshot.contextManifest, first)
}

func test_runJournalBundleRestoresPerRunContextTotalsOnColdReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-context-reopen-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("context-reopen-session")
    let work = WorkRef(workHostID: hostID, workID: "context-reopen-work")
    let oldRun = RunRef("context-reopen-old-run")
    let attachment = SessionAttachmentRef("context-reopen-attachment")
    let actor = TimelineActor(actorID: "context-test", kind: "self-test")
    let firstBundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("context-service"),
        sessionAttachment: attachment, run: oldRun, actor: actor, modelID: "provider/model")
    let manifest = try retainedContextManifest(
        request: contextManifestRequest(), store: ContextBodyStore(home: home),
        journal: firstBundle.sessionJournal)
    let permit = try await firstBundle.prepareModelCrossing(
        manifest: manifest, admission: fixtureProviderAdmission(), kind: .provider,
        target: "provider/model")
    _ = try await firstBundle.finishAction(permit, state: .succeeded, retrySafety: .unsafe,
        providerSettlement: fixtureProviderSettlement(permit))
    _ = try await firstBundle.finishRun()
    try await firstBundle.closeChecked()

    let newRun = RunRef("context-reopen-new-run")
    let reopened = try await RunJournalBundle.reopen(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("context-service"),
        sessionAttachment: attachment, run: newRun, actor: actor, modelID: "provider/model")
    XCTAssertEqual(await reopened.contextDeliveredBytes(for: oldRun), manifest.cumulativeDeliveredBytes)
    XCTAssertEqual(await reopened.activeRunContextDeliveredBytes, 0)
    _ = try await reopened.finishRun()
    try await reopened.closeChecked()
}

func test_runJournalBundlePersistsContextManifestWithoutBodyText() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-context-manifest-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("context-session")
    let work = WorkRef(workHostID: hostID, workID: "context-work")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("context-service"),
        sessionAttachment: SessionAttachmentRef("context-attachment"), run: RunRef("context-run"),
        actor: TimelineActor(actorID: "context-test", kind: "self-test"), modelID: "provider/model",
        eventIDProvider: { UUID().uuidString }, now: { Date(timeIntervalSince1970: 1) })
    let store = ContextBodyStore(home: home)
    let manifest = try retainedContextManifest(
        request: contextManifestRequest(), store: store, journal: bundle.sessionJournal)
    let permit = try await bundle.prepareModelCrossing(
        manifest: manifest, admission: fixtureProviderAdmission(), kind: .provider,
        intent: "Request the next agent response", target: "provider/model")
    let data = try Data(contentsOf: home.timelineV2SessionJournalURL(session))
    let read = TimelineJournalReader.read(
        data, journal: bundle.sessionJournal,
        actor: TimelineActor(actorID: "context-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    let event = try XCTUnwrap(read.records.last?.event)
    XCTAssertEqual(event.type, TimelineEventType.contextAssembled)
    XCTAssertFalse(String(decoding: event.payload.compactJSON.utf8, as: UTF8.self)
        .contains("private request body"))
    let snapshot = SessionReducer.reduce(read.records.map(\.event))
    XCTAssertEqual(snapshot.contextComponents, manifest.components)
    XCTAssertEqual(snapshot.contextBoundaryEventID, event.eventID)
    for component in manifest.components {
        let reference = try XCTUnwrap(component.bodyReference)
        let retained = try store.read(reference)
        XCTAssertEqual(retained.count, component.fullByteCount)
    }
    let workData = try Data(contentsOf: home.timelineV2WorkJournalURL(work))
    let workRead = TimelineJournalReader.read(
        workData, journal: bundle.workJournal,
        actor: TimelineActor(actorID: "context-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    let intent = try XCTUnwrap(workRead.records.map(\.event).last {
        $0.type == TimelineEventType.actionIntent
    })
    XCTAssertEqual(intent.causedByEventID, EventRef(journal: bundle.sessionJournal, eventID: event.eventID))
    XCTAssertTrue(intent.links.contains {
        $0.kind == .derivedFrom && $0.target == .event(intent.causedByEventID!)
    })
    XCTAssertEqual(permit.intentCommit.eventRef, EventRef(journal: bundle.workJournal, eventID: intent.eventID))
    _ = try await bundle.finishAction(permit, state: .succeeded, retrySafety: .unsafe,
        providerSettlement: fixtureProviderSettlement(permit))
    let compactionManifest = try retainedContextManifest(
        request: contextManifestRequest(), store: store, journal: bundle.sessionJournal,
        manifestID: "context-run:compaction:1", requestID: "request-1",
        priorDeliveredBytes: manifest.cumulativeDeliveredBytes)
    let compactionPermit = try await bundle.prepareModelCrossing(
        manifest: compactionManifest, admission: fixtureProviderAdmission(kind: .compactionProvider), kind: .compactionProvider,
        intent: "Compact the conversation with the provider", target: "provider/model")
    XCTAssertEqual(compactionPermit.kind, .compactionProvider)
    XCTAssertEqual(
        compactionManifest.cumulativeDeliveredBytes,
        manifest.cumulativeDeliveredBytes + compactionManifest.deliveredBytes)
    _ = try await bundle.finishAction(
        compactionPermit, state: .succeeded, retrySafety: .unsafe,
        providerSettlement: fixtureProviderSettlement(compactionPermit))
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    let finalReport = ReaderCensus.report(
        sessionData: try Data(contentsOf: home.timelineV2SessionJournalURL(session)),
        sessionJournal: bundle.sessionJournal,
        workData: try Data(contentsOf: home.timelineV2WorkJournalURL(work)),
        workJournal: bundle.workJournal)
    XCTAssertEqual(finalReport.contextManifest?.manifestID, compactionManifest.manifestID)
    XCTAssertEqual(
        finalReport.contextManifest?.cumulativeDeliveredBytes,
        compactionManifest.cumulativeDeliveredBytes)
    XCTAssertEqual(finalReport.contextComponents.map(\.tokenCount),
                   compactionManifest.components.map(\.tokenCount))
}

func test_contextWorkIntentFailureCannotIssueProviderPermit() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-context-work-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("context-work-failure-session")
    let work = WorkRef(workHostID: hostID, workID: "context-work-failure")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("context-service"),
        sessionAttachment: SessionAttachmentRef("context-attachment"),
        run: RunRef("context-work-failure-run"),
        actor: TimelineActor(actorID: "context-test", kind: "self-test"),
        modelID: "provider/model")
    let manifest = try retainedContextManifest(
        request: contextManifestRequest(), store: ContextBodyStore(home: home),
        journal: bundle.sessionJournal)
    await bundle.injectWriterFailure(.beforeWrite, in: .work)
    do {
        _ = try await bundle.prepareModelCrossing(
            manifest: manifest, admission: fixtureProviderAdmission(), kind: .provider,
            intent: "Request the next agent response", target: "provider/model")
        XCTFail("a failed Work action append must not return an effect permit")
    } catch { }

    let sessionData = try Data(contentsOf: home.timelineV2SessionJournalURL(session))
    let sessionRead = TimelineJournalReader.read(
        sessionData, journal: bundle.sessionJournal,
        actor: TimelineActor(actorID: "context-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    XCTAssertEqual(
        sessionRead.records.map(\.event).filter {
            $0.type == TimelineEventType.contextAssembled
        }.count,
        1,
        "a synchronized Session manifest remains inspectable after the later Work failure")
    let workData = try Data(contentsOf: home.timelineV2WorkJournalURL(work))
    let workRead = TimelineJournalReader.read(
        workData, journal: bundle.workJournal,
        actor: TimelineActor(actorID: "context-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    XCTAssertFalse(workRead.records.map(\.event).contains {
        $0.type == TimelineEventType.actionIntent
    })
    if case .failed = await bundle.status.health { } else {
        XCTFail("an ambiguous Work append must latch the bundle")
    }
    try? await bundle.closeChecked()
}

private actor ContextManifestSpyCounter {
    var calls = 0
    func increment() { calls += 1 }
}

private actor ContextCrossingObservation {
    var calls = 0
    var sawDurableContextBeforeCall = false
    var sawCausalProviderActionBeforeCall = false

    func record(context: Bool, action: Bool) {
        calls += 1
        sawDurableContextBeforeCall = context
        sawCausalProviderActionBeforeCall = action
    }
}

private struct ContextCrossingInspectingProvider: ChatProvider {
    let observation: ContextCrossingObservation
    let sessionURL: URL
    let workURL: URL
    let sessionJournal: JournalRef
    let workJournal: JournalRef
    var id: String { "context-inspecting" }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let sessionEvents = (try? Data(contentsOf: sessionURL)).map {
            TimelineJournalReader.read(
                $0, journal: sessionJournal,
                actor: TimelineActor(actorID: "provider-spy", kind: "self-test"),
                hostRecordedAt: Date(timeIntervalSince1970: 1)).records.map(\.event)
        } ?? []
        let workEvents = (try? Data(contentsOf: workURL)).map {
            TimelineJournalReader.read(
                $0, journal: workJournal,
                actor: TimelineActor(actorID: "provider-spy", kind: "self-test"),
                hostRecordedAt: Date(timeIntervalSince1970: 1)).records.map(\.event)
        } ?? []
        let context = sessionEvents.last { $0.type == TimelineEventType.contextAssembled }
        let intent = workEvents.last { $0.type == TimelineEventType.actionIntent }
        let started = workEvents.last { $0.type == TimelineEventType.actionStarted }
        let contextWasDurable = context != nil
        let contextLinked = context.map {
            intent?.causedByEventID == EventRef(journal: sessionJournal, eventID: $0.eventID)
        } ?? false
        let startLinked = intent.map {
            started?.causedByEventID == EventRef(journal: workJournal, eventID: $0.eventID)
        } ?? false
        let actionWasCausal = contextLinked && startLinked

        return AsyncThrowingStream { continuation in
            Task {
                await observation.record(context: contextWasDurable, action: actionWasCausal)
                continuation.yield(.textDelta("done"))
                continuation.yield(.done(stopReason: "stop"))
                continuation.finish()
            }
        }
    }
}

private struct ContextManifestSpyProvider: ChatProvider {
    let counter: ContextManifestSpyCounter
    var id: String { "context-spy" }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await counter.increment()
                continuation.yield(.textDelta("provider must not be called"))
                continuation.yield(.done(stopReason: "stop"))
                continuation.finish()
            }
        }
    }
}

func test_contextManifestAndCausalActionAreDurableBeforeProviderCall() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-context-crossing-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("context-crossing-session")
    let work = WorkRef(workHostID: hostID, workID: "context-crossing-work")
    let identity = SessionWorkIdentity(
        sessionID: session.sessionID, work: work, runID: "context-crossing-run")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("context-service"),
        sessionAttachment: SessionAttachmentRef("context-attachment"), run: RunRef(identity.runID),
        actor: TimelineActor(actorID: "context-test", kind: "self-test"), modelID: "provider/model",
        eventIDProvider: { UUID().uuidString }, now: { Date(timeIntervalSince1970: 1) })
    let writer = try SessionWriter(
        home: home, cwd: root.path, model: ModelSpec(rpc: .object([
            "id": .string("model"), "provider": .string("provider")
        ])), identity: identity)
    let observation = ContextCrossingObservation()
    let provider = ContextCrossingInspectingProvider(
        observation: observation,
        sessionURL: home.timelineV2SessionJournalURL(session),
        workURL: home.timelineV2WorkJournalURL(work),
        sessionJournal: bundle.sessionJournal, workJournal: bundle.workJournal)
    let agent = Agent(
        provider: provider,
        host: RuntimeHost(executable: "/usr/bin/true", arguments: []), writer: writer,
        hostSession: "context-crossing-runtime",
        config: .init(
            model: ModelSpec(rpc: .object([
                "id": .string("model"), "provider": .string("provider")
            ])), cwd: root.path, systemPrompt: "instructions", maxIterations: 1),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    XCTAssertEqual(await agent.send("private request body"), .completed)
    XCTAssertEqual(await observation.calls, 1)
    XCTAssertTrue(await observation.sawDurableContextBeforeCall)
    XCTAssertTrue(await observation.sawCausalProviderActionBeforeCall)
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()
}

func test_contextManifestFailurePreventsProviderCall() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-context-manifest-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("context-failure-session")
    let work = WorkRef(workHostID: hostID, workID: "context-failure-work")
    let identity = SessionWorkIdentity(
        sessionID: session.sessionID, work: work, runID: "context-failure-run")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("context-service"),
        sessionAttachment: SessionAttachmentRef("context-attachment"), run: RunRef(identity.runID),
        actor: TimelineActor(actorID: "context-test", kind: "self-test"), modelID: "provider/model",
        eventIDProvider: { UUID().uuidString }, now: { Date(timeIntervalSince1970: 1) })
    let writer = try SessionWriter(
        home: home, cwd: root.path, model: ModelSpec(rpc: .object([
            "id": .string("model"), "provider": .string("provider")
        ])), identity: identity)
    await bundle.injectWriterFailure(
        TimelineJournalWriter.FailurePoint.beforeWrite, in: TimelineJournalKind.session)
    let counter = ContextManifestSpyCounter()
    let agent = Agent(
        provider: ContextManifestSpyProvider(counter: counter),
        host: RuntimeHost(executable: "/usr/bin/true", arguments: []), writer: writer,
        hostSession: "context-failure-runtime",
        config: .init(
            model: ModelSpec(rpc: .object([
                "id": .string("model"), "provider": .string("provider")
            ])), cwd: root.path, systemPrompt: "instructions", maxIterations: 1),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    let outcome = await agent.send("private request body")
    if case .failed = outcome { } else { XCTFail("context failure must fail the send") }
    XCTAssertEqual(await counter.calls, 0)
    try? await writer.closeChecked()
    try? await bundle.closeChecked()
}
