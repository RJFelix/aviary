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
    let expectedSummary = String(repeating: "summary ", count: 900)
        + "credentials-token /private/secret/path"
    let compactionDigest = promptProjectionDigest("d")
    let compactionBody = TimelineBodyReference(
        authority: promptProjectionSessionJournal, referenceID: compactionDigest,
        mediaType: "application/json", byteCount: Data(expectedSummary.utf8).count,
        digest: compactionDigest)
    let compactionComponent = ContextComponent(
        componentID: "compaction-component", inclusionID: "compaction:0",
        sourceID: "compaction-summary",
        sourceProvenance: EventRef(
            journal: promptProjectionSessionJournal, eventID: "compact-for-request"),
        mode: .compactionSummary, deliveryMode: .summary,
        measuredBytes: Data(expectedSummary.utf8).count,
        includedBytes: Data(expectedSummary.utf8).count,
        deliveredBytes: Data(expectedSummary.utf8).count,
        fullByteCount: Data(expectedSummary.utf8).count,
        bodyReference: compactionBody, digest: compactionDigest)
    let manifest = ContextManifest(
        manifestID: "manifest-1", requestID: "request-1", modelID: "provider/model",
        components: [ContextComponent(
            componentID: "component-stable", inclusionID: "component:0", sourceID: "message:0",
            mode: .history, deliveryMode: .truncated, measuredBytes: 20, includedBytes: 12,
            deliveredBytes: 12, fullByteCount: 20, bodyReference: body, digest: digest),
            compactionComponent],
        omissions: [ContextManifestOmission(
            omissionID: "omission-1", sourceID: "message:1", reason: "not selected",
            measuredBytes: 4)], systemPromptAssemblyID: "assembly-1",
        systemPromptSources: [source])
    let report = promptProjectionReport(
        manifest: manifest, components: [component], unknownEventRefs: [
            EventRef(journal: promptProjectionSessionJournal, eventID: "unknown-1")
        ], unknownReferenceIDs: ["missing-1"])

    let projection = report.recordedModelContext
    XCTAssertEqual(projection.availability, .observed)
    XCTAssertTrue(projection.manifestID?.hasPrefix("context-manifest-sha256:") == true)
    XCTAssertTrue(projection.requestID?.hasPrefix("context-request-sha256:") == true)
    XCTAssertEqual(projection.modelID, "provider/model")
    XCTAssertTrue(projection.assemblyID?.hasPrefix("prompt-assembly-sha256:") == true)
    XCTAssertTrue(projection.contextBoundaryEventID?.hasPrefix("context-boundary-sha256:") == true)
    XCTAssertTrue(projection.compactionBoundaryEventID?.hasPrefix("compaction-boundary-sha256:") == true)
    XCTAssertEqual(projection.sources?.count, 1)
    let projectedSource = try XCTUnwrap(projection.sources?.first)
    XCTAssertTrue(projectedSource.id.hasPrefix("prompt-source-sha256:"))
    XCTAssertTrue(projectedSource.inclusionID.hasPrefix("prompt-inclusion-sha256:"))
    XCTAssertFalse(projectedSource.id.contains("source-stable"))
    XCTAssertFalse(projectedSource.inclusionID.contains("prompt:0"))
    XCTAssertEqual(projectedSource.label, "Base instructions")
    XCTAssertEqual(projectedSource.fullByteCount, 20)
    XCTAssertEqual(projectedSource.deliveredByteCount, 12)
    XCTAssertEqual(projectedSource.renderedByteCount, 14)
    XCTAssertEqual(projectedSource.status, .truncated)
    XCTAssertNotNil(projectedSource.deliveredBodyReference)
    XCTAssertEqual(projectedSource.provenance?.eventID, "observe-1")
    XCTAssertTrue(projection.components.first?.id.hasPrefix("context-component-sha256:") == true)
    XCTAssertEqual(projection.components.first?.deliveryMode, .truncated)
    XCTAssertNotNil(projection.components.first?.bodyReference)
    XCTAssertEqual(projection.omissionCount, 1)
    XCTAssertEqual(projection.unknowns.referenceCount, 1)
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

func test_readerCensusContextWithoutProviderManifestIsUnavailable() throws {
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

    XCTAssertEqual(projection.availability, .unavailable)
    XCTAssertNil(projection.manifestID)
    XCTAssertNil(projection.modelID)
    // Without a provider-bound manifest there is no source-complete recorded model context.
    XCTAssertNil(projection.assemblyID)
    XCTAssertNil(projection.sources)
    XCTAssertEqual(projection.componentCount, 0)
    XCTAssertEqual(projection.components.count, 0)
    XCTAssertEqual(projection.omittedComponentCount, 0)
    XCTAssertEqual(projection.unknowns.referenceCount, 40)
    XCTAssertTrue(projection.hasOmissions)

    let empty = promptProjectionReport()
    XCTAssertEqual(empty.recordedModelContext.availability, .unavailable)
    XCTAssertNil(empty.recordedModelContext.sources)
    XCTAssertNil(empty.recordedModelContext.modelID)
}

func test_readerCensusDoesNotSpliceIndependentCompactionIntoRecordedCrossing() throws {
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
    XCTAssertEqual(report.recordedModelContext.availability, .invalid)
    XCTAssertNil(report.recordedModelContext.compactionBoundaryEventID)
    XCTAssertNil(report.recordedModelContext.compactionSummaryByteCount)
}
