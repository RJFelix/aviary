import Foundation
@testable import AviaryCore

private let promptProjectionSessionJournal = JournalRef.session(
    SessionRef("prompt-projection-session"), journalID: "prompt-projection-session-journal",
    authority: TimelineAuthorityRef("prompt-projection-authority"))
private let promptProjectionWorkJournal = JournalRef.work(
    WorkRef(workHostID: "prompt-projection-host", workID: "prompt-projection-work"),
    journalID: "prompt-projection-work-journal")

private func promptProjectionDigest(_ character: Character) -> String {
    "sha256:" + String(repeating: String(character), count: 64)
}

private func promptProjectionReport(
    manifest: ContextManifest? = nil,
    components: [ReaderCensusContextComponent] = [],
    unknownEventRefs: [EventRef] = [], unknownReferenceIDs: [String] = []
) -> ReaderCensusReport {
    ReaderCensusReport(
        sessionCursor: nil, workCursor: nil,
        sessionCommittedEventIDs: [], workCommittedEventIDs: [],
        sessionIntegrityValid: true, workIntegrityValid: true,
        sessionStructuralIntegrityValid: true, workStructuralIntegrityValid: true,
        sessionSemanticProjectionValid: true, workSemanticProjectionValid: true,
        sessionTailBytes: 0, workTailBytes: 0,
        visibleMessageIDs: [], contextInclusionIDs: components.map(\.inclusionID),
        omittedContextIDs: [], contextComponents: components,
        contextManifest: manifest,
        contextBoundaryEventID: "context-boundary-1", compactionBoundaryEventID: "compact-1",
        compactionSummary: String(repeating: "summary ", count: 900)
            + "credentials-token /private/secret/path",
        recovery: [], authoredAttention: .none, attention: .none,
        outstandingActionIDs: [], indeterminateActionIDs: [], outstandingHandleIDs: [],
        outstandingCommandIDs: [], childStates: [:], modelIDs: [], runIDs: [], activeTip: nil,
        attachments: [], unknownEventRefs: unknownEventRefs, unknownDomains: [.context],
        unknownReferenceIDs: unknownReferenceIDs, unknownReferences: [], assemblerReady: false,
        intentionallyUnwiredConsumers: [])
}

func test_readerCensusNextModelContextIsMetadataOnlyAndBounded() throws {
    let digest = promptProjectionDigest("a")
    let renderedDigest = promptProjectionDigest("b")
    let deliveredDigest = promptProjectionDigest("c")
    let body = TimelineBodyReference(
        authority: promptProjectionSessionJournal, referenceID: digest,
        mediaType: "text/plain", byteCount: 12, digest: digest)
    let source = ContextManifestSource(
        sourceID: "source-stable", inclusionID: "prompt:0", kind: .baseInstruction,
        status: .truncated, label: "/private/secret/AGENTS.md", fullByteCount: 20,
        fullDigest: digest, deliveredByteCount: 12, deliveredDigest: deliveredDigest,
        renderedByteCount: 14, renderedDigest: renderedDigest,
        fullBodyReference: body, deliveredBodyReference: body,
        renderedBodyReference: body,
        provenance: EventRef(journal: promptProjectionSessionJournal, eventID: "observe-1"))
    let component = ReaderCensusContextComponent(
        component: ContextComponent(
            componentID: "component-stable", inclusionID: "component:0", sourceID: "message:0",
            mode: .history, deliveryMode: .truncated, measuredBytes: 20, includedBytes: 12,
            deliveredBytes: 12, fullByteCount: 20, bodyReference: body, digest: digest))
    let manifest = ContextManifest(
        manifestID: "manifest-1", requestID: "request-1", modelID: "provider/model",
        components: [ContextComponent(
            componentID: "component-stable", inclusionID: "component:0", sourceID: "message:0",
            mode: .history, deliveryMode: .truncated, measuredBytes: 20, includedBytes: 12,
            deliveredBytes: 12, fullByteCount: 20, bodyReference: body, digest: digest)],
        omissions: [ContextManifestOmission(
            omissionID: "omission-1", sourceID: "message:1", reason: "not selected",
            measuredBytes: 4)], systemPromptAssemblyID: "assembly-1",
        systemPromptSources: [source])
    let report = promptProjectionReport(
        manifest: manifest, components: [component], unknownEventRefs: [
            EventRef(journal: promptProjectionSessionJournal, eventID: "unknown-1")
        ], unknownReferenceIDs: ["missing-1"])

    let projection = report.recordedModelContext
    XCTAssertEqual(projection.state, .observed)
    XCTAssertEqual(projection.manifestID, "manifest-1")
    XCTAssertEqual(projection.requestID, "request-1")
    XCTAssertEqual(projection.modelID, "provider/model")
    XCTAssertEqual(projection.assemblyID, "assembly-1")
    XCTAssertEqual(projection.contextBoundaryEventID, "context-boundary-1")
    XCTAssertEqual(projection.compactionBoundaryEventID, "compact-1")
    XCTAssertEqual(projection.promptSources?.count, 1)
    let projectedSource = try XCTUnwrap(projection.promptSources?.first)
    XCTAssertTrue(projectedSource.sourceID.hasPrefix("source-sha256:"))
    XCTAssertTrue(projectedSource.inclusionID.hasPrefix("inclusion-sha256:"))
    XCTAssertFalse(projectedSource.sourceID.contains("source-stable"))
    XCTAssertFalse(projectedSource.inclusionID.contains("prompt:0"))
    XCTAssertEqual(projectedSource.label, "Base instructions")
    XCTAssertEqual(projectedSource.fullByteCount, 20)
    XCTAssertEqual(projectedSource.deliveredByteCount, 12)
    XCTAssertEqual(projectedSource.renderedByteCount, 14)
    XCTAssertEqual(projectedSource.status, .truncated)
    XCTAssertTrue(projectedSource.bodyAddressAvailable)
    XCTAssertEqual(projectedSource.provenance?.eventID, "observe-1")
    XCTAssertEqual(projection.components.first?.componentID, "component-stable")
    XCTAssertEqual(projection.components.first?.deliveryStatus, .truncated)
    XCTAssertTrue(projection.components.first?.bodyAddressAvailable == true)
    XCTAssertEqual(projection.omissionCount, 1)
    XCTAssertEqual(projection.unknowns.referenceIDs, ["missing-1"])
    let expectedSummary = String(repeating: "summary ", count: 900)
        + "credentials-token /private/secret/path"
    XCTAssertEqual(
        projection.compactionSummaryByteCount, Data(expectedSummary.utf8).count)
    XCTAssertTrue(projection.compactionSummaryDigest?.hasPrefix("sha256:") == true)
    XCTAssertTrue(projection.compactionSummaryInspectionRequired)

    let encoded = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
    XCTAssertFalse(encoded.contains("private/secret"))
    XCTAssertFalse(encoded.contains("credentials-token"))
    XCTAssertFalse(encoded.contains("summary summary"))
    XCTAssertFalse(encoded.contains("source-stable"))
    XCTAssertFalse(encoded.contains("prompt:0"))
    XCTAssertFalse(encoded.contains("raw body"))
    XCTAssertFalse(encoded.contains("credentials"))
}

func test_readerCensusNextModelContextPreservesCanonicalOrderAndLegacyUnknowns() throws {
    let components = (0..<70).map { index in
        ReaderCensusContextComponent(component: ContextComponent(
            componentID: "component-\(index)", inclusionID: "include-\(index)",
            sourceID: "source-\(index)", mode: .history, measuredBytes: 1,
            includedBytes: 1, deliveredBytes: 1, fullByteCount: 1))
    }
    let report = promptProjectionReport(
        components: components,
        unknownReferenceIDs: (0..<40).map { "missing-\($0)" })
    let projection = report.contextProjection

    XCTAssertEqual(projection.state, .legacy)
    XCTAssertNil(projection.manifestID)
    XCTAssertNil(projection.modelID)
    // Without a provider-bound manifest there is no source-complete next-model context.
    XCTAssertNil(projection.assemblyID)
    XCTAssertNil(projection.promptSources)
    XCTAssertEqual(projection.componentCount, 70)
    XCTAssertEqual(projection.components.count, ReaderCensusContextProjection.maxComponents)
    XCTAssertEqual(projection.omittedComponentCount, 6)
    XCTAssertEqual(projection.components[2].inclusionID, "include-2")
    XCTAssertEqual(projection.unknowns.referenceIDs.count, ReaderCensusContextProjection.maxUnknowns)
    XCTAssertEqual(projection.unknowns.referenceIDOmittedCount, 8)
    XCTAssertTrue(projection.hasOmittedRecords)

    let empty = promptProjectionReport()
    XCTAssertEqual(empty.recordedModelContext.state, .unknown)
    XCTAssertNil(empty.recordedModelContext.promptSources)
    XCTAssertNil(empty.recordedModelContext.modelID)
}

func test_readerCensusCompactionBoundaryComesFromLastAcceptedEvent() throws {
    let session = SessionRef("prompt-projection-session")
    let actor = TimelineActor(actorID: "prompt-projection-test", kind: "self-test")
    let created = TimelineEvent(
        eventID: "created", journal: promptProjectionSessionJournal, sequence: 1,
        session: session, actor: actor, hostRecordedAt: Date(timeIntervalSince1970: 1),
        type: TimelineEventType.sessionCreated)
    let accepted = TimelineEvent(
        eventID: "accepted-compaction", journal: promptProjectionSessionJournal, sequence: 2,
        previousEventID: created.eventID, session: session, actor: actor,
        hostRecordedAt: Date(timeIntervalSince1970: 2), type: TimelineEventType.compaction,
        payload: .object(["summary": "accepted summary"]))
    let quarantined = TimelineEvent(
        eventID: "quarantined-compaction", journal: promptProjectionSessionJournal, sequence: 3,
        previousEventID: accepted.eventID, session: session, actor: actor,
        hostRecordedAt: Date(timeIntervalSince1970: 3), type: TimelineEventType.compaction,
        payload: .object(["summary": ""]))
    let sessionRead = TimelineJournalReadResult(records: [created, accepted, quarantined]
        .enumerated().map { index, event in
            TimelineJournalRecord(
                event: event, rawLineBytes: Data(), byteStart: index, byteEnd: index + 1)
        })
    let report = ReaderCensus.report(
        sessionRead: sessionRead, workRead: TimelineJournalReadResult(records: []),
        sessionJournal: promptProjectionSessionJournal,
        workJournal: promptProjectionWorkJournal)

    XCTAssertFalse(report.sessionSemanticProjectionValid)
    XCTAssertEqual(report.compactionSummary, "accepted summary")
    XCTAssertEqual(report.compactionBoundaryEventID, accepted.eventID)
    XCTAssertEqual(report.recordedModelContext.compactionBoundaryEventID, accepted.eventID)
    XCTAssertNotEqual(
        report.recordedModelContext.compactionBoundaryEventID, quarantined.eventID)
}
