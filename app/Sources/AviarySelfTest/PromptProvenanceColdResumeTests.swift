import Foundation
@testable import AviaryCore

private struct PromptColdResumeFixture {
    let home: AgentHome
    let project: URL
    let identity: SessionWorkIdentity
    let sessionJournal: JournalRef
    let workJournal: JournalRef
    let sessionRead: TimelineJournalReadResult
    let workRead: TimelineJournalReadResult
    let sessionCursor: JournalCursor
    let workCursor: JournalCursor
    let manifest: ContextManifest
    let assembly: SystemPromptAssembly
}

private func promptColdSourceManifest(
    assembly: SystemPromptAssembly,
    request: ChatRequest,
    store: ContextBodyStore,
    journal: JournalRef,
    manifestID: String,
    includeSources: Bool
) throws -> ContextManifest {
    let measured = try ContextManifest.build(
        request: request, manifestID: manifestID, requestID: manifestID)
    var componentReferences: [String: TimelineBodyReference] = [:]
    for (index, message) in request.messages.enumerated() {
        let component = measured.components[index]
        componentReferences[component.sourceID] = try store.retain(
            ContextManifest.bodyData(for: message), authority: journal,
            mediaType: "application/vnd.aviary.chat-message+json")
    }
    let retained = try ContextManifest.build(
        request: request, manifestID: manifestID, requestID: manifestID,
        bodyReferences: componentReferences)
    guard includeSources else { return retained }

    let sources = try assembly.sources.enumerated().map { index, source in
        let bodyMediaType = "application/vnd.aviary.prompt-source+utf8"
        let fullReference: TimelineBodyReference?
        let deliveredReference: TimelineBodyReference?
        let renderedReference: TimelineBodyReference?
        switch source.status {
        case .present, .truncated:
            fullReference = try source.fullBody.map {
                try store.retain(Data($0.utf8), authority: journal, mediaType: bodyMediaType)
            }
            deliveredReference = try store.retain(
                Data(source.deliveredBody.utf8), authority: journal, mediaType: bodyMediaType)
            renderedReference = try store.retain(
                Data(source.renderedBody.utf8), authority: journal, mediaType: bodyMediaType)
        case .missing, .unreadable, .disabled:
            fullReference = nil
            deliveredReference = nil
            renderedReference = nil
        }
        return ContextManifestSource(
            source: source, inclusionID: "\(manifestID):source:\(index)",
            fullBodyReference: fullReference, deliveredBodyReference: deliveredReference,
            renderedBodyReference: renderedReference)
    }
    return ContextManifest(
        schemaVersion: retained.schemaVersion, manifestID: retained.manifestID,
        requestID: retained.requestID, modelID: retained.modelID,
        measuredBy: retained.measuredBy, components: retained.components,
        omissions: retained.omissions,
        cumulativeDeliveredBytes: retained.cumulativeDeliveredBytes,
        systemPromptAssemblyID: assembly.digest, systemPromptSources: sources)
}

private func promptColdRead(
    home: AgentHome, journal: JournalRef, url: URL
) throws -> TimelineJournalReadResult {
    TimelineJournalReader.read(
        try Data(contentsOf: url), journal: journal,
        actor: TimelineActor(actorID: "prompt-cold-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
}

private func makePromptColdResumeFixture(
    includeSources: Bool = true
) async throws -> PromptColdResumeFixture {
    let home = scratchHome()
    let project = home.root.appending(path: "prompt-project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    // Include both a truncated source and a missing source so status and body-bearing/non-body
    // source reconstruction are covered by the same exact pinned ChatMessage.
    try String(repeating: "A", count: 12_001).write(
        to: project.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)

    let assembly = try SystemPromptAssembly.build(
        cwd: project.path, memory: "retained memory", includeContextFiles: true)
    let request = ChatRequest(
        model: "model", messages: [
            .system(assembly.flattenedText), .user("before prompt provenance boundary"),
        ])
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("prompt-cold-session")
    let work = WorkRef(workHostID: hostID, workID: "prompt-cold-work")
    let identity = SessionWorkIdentity(
        sessionID: session.sessionID, work: work, runID: "prompt-cold-run")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("prompt-cold-authority"),
        sessionAttachment: SessionAttachmentRef("prompt-cold-attachment"),
        run: RunRef(identity.runID),
        actor: TimelineActor(actorID: "prompt-cold-producer", kind: "self-test"),
        modelID: request.model)
    let manifest = try promptColdSourceManifest(
        assembly: assembly, request: request, store: ContextBodyStore(home: home),
        journal: bundle.sessionJournal, manifestID: "prompt-cold-manifest",
        includeSources: includeSources)
    let permit = try await bundle.prepareModelCrossing(
        manifest: manifest, admission: fixtureProviderAdmission(), action: ActionRef("prompt-cold-provider-action"), kind: .provider)
    _ = try await bundle.finishAction(permit, state: .succeeded, retrySafety: .unsafe,
        providerSettlement: fixtureProviderSettlement(permit))
    _ = try await bundle.commitAssistantMessage(.init(
        role: .assistant, content: [.text("after prompt provenance boundary")]))
    _ = try await bundle.finishRun()
    let sessionCursor = try XCTUnwrap(await bundle.latestSessionCursor)
    let workCursor = try XCTUnwrap(await bundle.latestWorkCursor)
    let sessionJournal = bundle.sessionJournal
    let workJournal = bundle.workJournal
    try await bundle.closeChecked()
    let sessionRead = try promptColdRead(
        home: home, journal: sessionJournal,
        url: home.timelineV2SessionJournalURL(session))
    let workRead = try promptColdRead(
        home: home, journal: workJournal, url: home.timelineV2WorkJournalURL(work))
    return PromptColdResumeFixture(
        home: home, project: project, identity: identity,
        sessionJournal: sessionJournal, workJournal: workJournal,
        sessionRead: sessionRead, workRead: workRead,
        sessionCursor: sessionCursor, workCursor: workCursor,
        manifest: manifest, assembly: assembly)
}

private func resumePromptCold(
    _ fixture: PromptColdResumeFixture,
    sessionRead: TimelineJournalReadResult? = nil
) throws -> NativeColdResumeResult {
    try NativeColdResume.resume(
        sessionRead: sessionRead ?? fixture.sessionRead,
        expectedSessionCursor: fixture.sessionCursor,
        workRead: fixture.workRead, expectedWorkCursor: fixture.workCursor,
        bodyStore: ContextBodyStore(home: fixture.home))
}

private func clonePromptColdEvent(
    _ event: TimelineEvent,
    run: RunRef? = nil,
    causedBy: EventRef? = nil,
    payload: JSONValue? = nil
) -> TimelineEvent {
    TimelineEvent(
        eventID: event.eventID, journal: event.journal, sequence: event.sequence,
        hostSequence: event.hostSequence, idempotencyKey: event.idempotencyKey,
        command: event.command, previousEventID: event.previousEventID,
        causedByEventID: causedBy ?? event.causedByEventID,
        parentActivityID: event.parentActivityID,
        conversationParent: event.conversationParent, session: event.session,
        work: event.work, workHost: event.workHost, client: event.client,
        sessionAttachment: event.sessionAttachment, clientAttachment: event.clientAttachment,
        run: run ?? event.run, turn: event.turn, action: event.action, handle: event.handle,
        actor: event.actor, hostRecordedAt: event.hostRecordedAt,
        clientTimestamp: event.clientTimestamp, schemaVersion: event.schemaVersion,
        payloadVersion: event.payloadVersion, type: event.type,
        declaredDomains: event.declaredDomains, provenance: event.provenance,
        links: event.links, payload: payload ?? event.payload)
}

private func promptColdJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    try XCTUnwrap(JSONValue.parse(JSONEncoder().encode(value)))
}

func test_promptProvenanceColdResumeUsesRetainedBodiesAfterSourceFilesChange() async throws {
    let fixture = try await makePromptColdResumeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    // These files are intentionally changed after the durable crossing. A cold replay must not
    // consult them, even though SystemPromptAssembly.build would now produce different bytes.
    try "changed after run".write(
        to: fixture.project.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    try "created after run".write(
        to: fixture.project.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)

    let result = try resumePromptCold(fixture)
    let replayed = result.systemPromptAssembly
    XCTAssertEqual(replayed.flattenedText, fixture.assembly.flattenedText)
    XCTAssertEqual(replayed.flattenedByteCount, fixture.assembly.flattenedByteCount)
    XCTAssertEqual(replayed.flattenedDigest, fixture.assembly.flattenedDigest)
    XCTAssertEqual(replayed.sources.map(\.sourceID), fixture.assembly.sources.map(\.sourceID))
    XCTAssertEqual(replayed.sources.map(\.status), fixture.assembly.sources.map(\.status))
    XCTAssertEqual(
        replayed.sources.map(\.fullByteCount), fixture.assembly.sources.map(\.fullByteCount))
    XCTAssertEqual(
        replayed.sources.map(\.deliveredByteCount), fixture.assembly.sources.map(\.deliveredByteCount))
    XCTAssertEqual(
        replayed.sources.map(\.renderedByteCount), fixture.assembly.sources.map(\.renderedByteCount))
    XCTAssertEqual(
        replayed.sources.map(\.renderedDigest), fixture.assembly.sources.map(\.renderedDigest))

    let events = fixture.sessionRead.records.map(\.event)
    let observation = try XCTUnwrap(events.last { $0.type == TimelineEventType.contextSourcesObserved })
    let retainedSources = try XCTUnwrap(result.contextManifest.systemPromptSources)
    XCTAssertTrue(retainedSources.allSatisfy {
        $0.provenance == EventRef(journal: fixture.sessionJournal, eventID: observation.eventID)
    })
}

func test_promptProvenanceColdResumeRefusesMissingOrCorruptSourceBody() async throws {
    let missing = try await makePromptColdResumeFixture()
    defer { try? FileManager.default.removeItem(at: missing.home.root) }
    let missingSource = try XCTUnwrap(
        missing.manifest.systemPromptSources?.first(where: { $0.fullBodyReference != nil }))
    let missingReference = try XCTUnwrap(missingSource.fullBodyReference)
    let missingPath = missing.home.root.appending(path: "context-bodies/sha256")
        .appending(path: String(missingReference.referenceID.dropFirst("sha256:".count)))
    try FileManager.default.removeItem(at: missingPath)
    do {
        _ = try resumePromptCold(missing)
        XCTFail("a missing retained prompt source body must refuse cold resume")
    } catch let error as NativeColdResumeError {
        guard case .retainedBodyUnavailable(let sourceID) = error else {
            return XCTFail("expected source body refusal, got \(error)")
        }
        XCTAssertEqual(sourceID, missingSource.sourceID)
    }

    let corrupt = try await makePromptColdResumeFixture()
    defer { try? FileManager.default.removeItem(at: corrupt.home.root) }
    let corruptSource = try XCTUnwrap(
        corrupt.manifest.systemPromptSources?.first(where: { $0.renderedBodyReference != nil }))
    let corruptReference = try XCTUnwrap(corruptSource.renderedBodyReference)
    let corruptPath = corrupt.home.root.appending(path: "context-bodies/sha256")
        .appending(path: String(corruptReference.referenceID.dropFirst("sha256:".count)))
    try Data("corrupted source bytes".utf8).write(to: corruptPath)
    do {
        _ = try resumePromptCold(corrupt)
        XCTFail("a corrupt retained prompt source body must refuse cold resume")
    } catch let error as NativeColdResumeError {
        guard case .retainedBodyUnavailable(let sourceID) = error else {
            return XCTFail("expected corrupt source body refusal, got \(error)")
        }
        XCTAssertEqual(sourceID, corruptSource.sourceID)
    }
}

func test_promptProvenanceColdResumeRechecksTruncatedFullBodyPrefix() async throws {
    let fixture = try await makePromptColdResumeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let sourceIndex = try XCTUnwrap(
        fixture.manifest.systemPromptSources?.firstIndex { $0.status == .truncated })
    let original = try XCTUnwrap(fixture.manifest.systemPromptSources?[sourceIndex])
    let fullByteCount = try XCTUnwrap(original.fullByteCount)
    let wrongFull = Data(String(repeating: "Z", count: fullByteCount).utf8)
    let wrongFullReference = try ContextBodyStore(home: fixture.home).retain(
        wrongFull, authority: fixture.sessionJournal,
        mediaType: "application/vnd.aviary.prompt-source+utf8")
    func replacement(provenance: EventRef?) -> ContextManifestSource {
        ContextManifestSource(
            sourceID: original.sourceID, inclusionID: original.inclusionID,
            kind: original.kind, status: original.status, label: original.label,
            fullByteCount: wrongFull.count, fullDigest: wrongFullReference.digest,
            deliveredByteCount: original.deliveredByteCount,
            deliveredDigest: original.deliveredDigest,
            deliveredByteOffsetInRendered: original.deliveredByteOffsetInRendered,
            renderedByteCount: original.renderedByteCount,
            renderedDigest: original.renderedDigest,
            fullBodyReference: wrongFullReference,
            deliveredBodyReference: original.deliveredBodyReference,
            renderedBodyReference: original.renderedBodyReference,
            provenance: provenance)
    }

    var records = fixture.sessionRead.records
    let observationIndex = try XCTUnwrap(records.lastIndex {
        $0.event.type == TimelineEventType.contextSourcesObserved
    })
    let crossingIndex = try XCTUnwrap(records.lastIndex {
        $0.event.type == TimelineEventType.contextAssembled
    })
    let observation = records[observationIndex].event
    let observationRef = EventRef(
        journal: fixture.sessionJournal, eventID: observation.eventID)

    var observationPayload = try XCTUnwrap(observation.payload.objectValue)
    var observedSources = try XCTUnwrap(observationPayload["sources"]?.arrayValue)
    observedSources[sourceIndex] = try promptColdJSON(replacement(provenance: nil))
    observationPayload["sources"] = .array(observedSources)
    let observationRecord = records[observationIndex]
    records[observationIndex] = TimelineJournalRecord(
        event: clonePromptColdEvent(
            observationRecord.event, payload: .object(observationPayload)),
        rawLineBytes: observationRecord.rawLineBytes,
        byteStart: observationRecord.byteStart, byteEnd: observationRecord.byteEnd,
        legacyRawID: observationRecord.legacyRawID)

    let crossingRecord = records[crossingIndex]
    var crossingPayload = try XCTUnwrap(crossingRecord.event.payload.objectValue)
    var crossingSources = try XCTUnwrap(
        crossingPayload["system_prompt_sources"]?.arrayValue)
    crossingSources[sourceIndex] = try promptColdJSON(
        replacement(provenance: observationRef))
    crossingPayload["system_prompt_sources"] = .array(crossingSources)
    records[crossingIndex] = TimelineJournalRecord(
        event: clonePromptColdEvent(
            crossingRecord.event, payload: .object(crossingPayload)),
        rawLineBytes: crossingRecord.rawLineBytes, byteStart: crossingRecord.byteStart,
        byteEnd: crossingRecord.byteEnd, legacyRawID: crossingRecord.legacyRawID)

    let forgedRead = TimelineJournalReadResult(records: records)
    XCTAssertTrue(SessionReducer.reduce(records.map(\.event)).semanticProjectionValid)
    do {
        _ = try resumePromptCold(fixture, sessionRead: forgedRead)
        XCTFail("cold resume must re-check that delivered truncation is a prefix of full bytes")
    } catch let error as NativeColdResumeError {
        XCTAssertEqual(error, .contextBoundaryMalformed)
    }
}

func test_promptProvenanceColdResumeRefusesForgedMissingAndMismatchedObservation() async throws {
    let forged = try await makePromptColdResumeFixture()
    defer { try? FileManager.default.removeItem(at: forged.home.root) }
    let forgedEvents = forged.sessionRead.records.map(\.event)
    let crossingIndex = try XCTUnwrap(
        forgedEvents.lastIndex { $0.type == TimelineEventType.contextAssembled })
    let crossingRecord = forged.sessionRead.records[crossingIndex]
    var changed = forged.sessionRead.records
    changed[crossingIndex] = TimelineJournalRecord(
        event: clonePromptColdEvent(
            crossingRecord.event,
            causedBy: EventRef(journal: forged.sessionJournal, eventID: "forged-observation")),
        rawLineBytes: crossingRecord.rawLineBytes, byteStart: crossingRecord.byteStart,
        byteEnd: crossingRecord.byteEnd, legacyRawID: crossingRecord.legacyRawID)
    do {
        _ = try resumePromptCold(
            forged, sessionRead: TimelineJournalReadResult(records: changed))
        XCTFail("a context crossing caused by a forged observation must refuse")
    } catch is NativeColdResumeError { }

    let missing = try await makePromptColdResumeFixture()
    defer { try? FileManager.default.removeItem(at: missing.home.root) }
    let observationIndex = try XCTUnwrap(
        missing.sessionRead.records.lastIndex {
            $0.event.type == TimelineEventType.contextSourcesObserved
        })
    var missingRecords = missing.sessionRead.records
    missingRecords.remove(at: observationIndex)
    do {
        _ = try resumePromptCold(
            missing, sessionRead: TimelineJournalReadResult(records: missingRecords))
        XCTFail("a context crossing without its immediately preceding observation must refuse")
    } catch is NativeColdResumeError { }

    let mismatched = try await makePromptColdResumeFixture()
    defer { try? FileManager.default.removeItem(at: mismatched.home.root) }
    let mismatchEvents = mismatched.sessionRead.records.map(\.event)
    let mismatchIndex = try XCTUnwrap(
        mismatchEvents.lastIndex { $0.type == TimelineEventType.contextSourcesObserved })
    let observation = mismatchEvents[mismatchIndex]
    var payload = try XCTUnwrap(observation.payload.objectValue)
    payload["assembly_id"] = .string("sha256:" + String(repeating: "f", count: 64))
    var mismatchRecords = mismatched.sessionRead.records
    let original = mismatchRecords[mismatchIndex]
    mismatchRecords[mismatchIndex] = TimelineJournalRecord(
        event: clonePromptColdEvent(original.event, payload: .object(payload)),
        rawLineBytes: original.rawLineBytes, byteStart: original.byteStart,
        byteEnd: original.byteEnd, legacyRawID: original.legacyRawID)
    do {
        _ = try resumePromptCold(
            mismatched, sessionRead: TimelineJournalReadResult(records: mismatchRecords))
        XCTFail("a mismatched source observation must refuse")
    } catch is NativeColdResumeError { }

    let wrongIdentity = try await makePromptColdResumeFixture()
    defer { try? FileManager.default.removeItem(at: wrongIdentity.home.root) }
    var identityRecords = wrongIdentity.sessionRead.records
    let identityIndex = try XCTUnwrap(
        identityRecords.lastIndex { $0.event.type == TimelineEventType.contextSourcesObserved })
    let identityOriginal = identityRecords[identityIndex]
    identityRecords[identityIndex] = TimelineJournalRecord(
        event: clonePromptColdEvent(identityOriginal.event, run: RunRef("wrong-run")),
        rawLineBytes: identityOriginal.rawLineBytes, byteStart: identityOriginal.byteStart,
        byteEnd: identityOriginal.byteEnd, legacyRawID: identityOriginal.legacyRawID)
    do {
        _ = try resumePromptCold(
            wrongIdentity, sessionRead: TimelineJournalReadResult(records: identityRecords))
        XCTFail("an observation from another run must refuse")
    } catch is NativeColdResumeError { }
}

func test_promptProvenanceColdResumeRefusesLegacySourceLessManifest() async throws {
    let fixture = try await makePromptColdResumeFixture(includeSources: false)
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    try? FileManager.default.removeItem(at: fixture.project.appending(path: "AGENTS.md"))
    try "new file".write(
        to: fixture.project.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
    do {
        _ = try resumePromptCold(fixture)
        XCTFail("source-less native cold resume must refuse before runtime effect")
    } catch NativeColdResumeError.noCompleteContextManifest {
        XCTAssertTrue(true)
    }
}
