import Foundation
@testable import AviaryCore

private func promptSourceManifestFixture(
    assembly: SystemPromptAssembly,
    request: ChatRequest,
    store: ContextBodyStore,
    journal: JournalRef,
    manifestID: String = "prompt-source-manifest"
) throws -> ContextManifest {
    let measured = try ContextManifest.build(
        request: request, manifestID: manifestID, requestID: manifestID)
    var componentReferences: [String: TimelineBodyReference] = [:]
    for (index, message) in request.messages.enumerated() {
        let component = measured.components[index]
        componentReferences[component.sourceID] = try store.retain(
            try ContextManifest.bodyData(for: message), authority: journal,
            mediaType: "application/vnd.aviary.chat-message+json")
    }
    if !request.tools.isEmpty, let tools = measured.components.last {
        componentReferences[tools.sourceID] = try store.retain(
            try ContextManifest.toolsData(for: request.tools), authority: journal,
            mediaType: "application/vnd.aviary.tool-schema-manifest+json")
    }
    let retained = try ContextManifest.build(
        request: request, manifestID: manifestID, requestID: manifestID,
        bodyReferences: componentReferences)

    let sources = try assembly.sources.enumerated().map { index, source in
        let fullReference = try source.fullBody.map {
            try store.retain(
                Data($0.utf8), authority: journal,
                mediaType: "application/vnd.aviary.prompt-source+utf8")
        }
        let deliveredReference: TimelineBodyReference?
        let renderedReference: TimelineBodyReference?
        switch source.status {
        case .present, .truncated:
            deliveredReference = try store.retain(
                Data(source.deliveredBody.utf8), authority: journal,
                mediaType: "application/vnd.aviary.prompt-source+utf8")
            renderedReference = try store.retain(
                Data(source.renderedBody.utf8), authority: journal,
                mediaType: "application/vnd.aviary.prompt-source+utf8")
        case .missing, .unreadable, .disabled:
            deliveredReference = nil
            renderedReference = nil
        }
        return ContextManifestSource(
            source: source, inclusionID: "\(manifestID):source:\(index)",
            fullBodyReference: fullReference,
            deliveredBodyReference: deliveredReference,
            renderedBodyReference: renderedReference)
    }
    return ContextManifest(
        schemaVersion: retained.schemaVersion, manifestID: retained.manifestID,
        requestID: retained.requestID, modelID: retained.modelID,
        measuredBy: retained.measuredBy, components: retained.components,
        omissions: retained.omissions,
        cumulativeDeliveredBytes: retained.cumulativeDeliveredBytes,
        systemPromptAssemblyID: assembly.digest,
        systemPromptSources: sources)
}

private func promptSourceClone(
    _ event: TimelineEvent,
    causedBy: EventRef? = nil,
    payload: JSONValue? = nil,
    session: SessionRef? = nil,
    work: WorkRef? = nil,
    workHost: WorkHostRef? = nil,
    run: RunRef? = nil,
    clearSession: Bool = false,
    clearWork: Bool = false,
    clearWorkHost: Bool = false,
    clearRun: Bool = false
) -> TimelineEvent {
    TimelineEvent(
        eventID: event.eventID, journal: event.journal, sequence: event.sequence,
        hostSequence: event.hostSequence, idempotencyKey: event.idempotencyKey,
        command: event.command, previousEventID: event.previousEventID,
        causedByEventID: causedBy ?? event.causedByEventID,
        parentActivityID: event.parentActivityID,
        conversationParent: event.conversationParent,
        session: clearSession ? nil : (session ?? event.session),
        work: clearWork ? nil : (work ?? event.work),
        workHost: clearWorkHost ? nil : (workHost ?? event.workHost), client: event.client,
        sessionAttachment: event.sessionAttachment,
        clientAttachment: event.clientAttachment,
        run: clearRun ? nil : (run ?? event.run), turn: event.turn,
        action: event.action, handle: event.handle, actor: event.actor,
        hostRecordedAt: event.hostRecordedAt, clientTimestamp: event.clientTimestamp,
        schemaVersion: event.schemaVersion, payloadVersion: event.payloadVersion,
        type: event.type, declaredDomains: event.declaredDomains,
        provenance: event.provenance, links: event.links, payload: payload ?? event.payload)
}

private func promptSourceEvents(
    home: AgentHome, session: SessionRef, journal: JournalRef
) throws -> [TimelineEvent] {
    TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2SessionJournalURL(session)),
        journal: journal,
        actor: TimelineActor(actorID: "prompt-source-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1)).records.map(\.event)
}

private func promptSourceManifest(
    _ manifest: ContextManifest,
    replacing source: ContextManifestSource,
    at index: Int
) -> ContextManifest {
    var sources = manifest.systemPromptSources ?? []
    sources[index] = source
    return ContextManifest(
        schemaVersion: manifest.schemaVersion, manifestID: manifest.manifestID,
        requestID: manifest.requestID, modelID: manifest.modelID,
        measuredBy: manifest.measuredBy, components: manifest.components,
        omissions: manifest.omissions,
        cumulativeDeliveredBytes: manifest.cumulativeDeliveredBytes,
        systemPromptAssemblyID: manifest.systemPromptAssemblyID,
        systemPromptSources: sources)
}

func test_promptSourceManifestCrossingIsCausalBoundedAndSecretSafe() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-prompt-source-manifest-\(UUID().uuidString)",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("prompt-source-session")
    let work = WorkRef(workHostID: hostID, workID: "prompt-source-work")
    let run = RunRef("prompt-source-run")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("prompt-source-service"),
        sessionAttachment: SessionAttachmentRef("prompt-source-attachment"), run: run,
        actor: TimelineActor(actorID: "prompt-source-test", kind: "self-test"),
        modelID: "provider/model")
    let secret = "credential-like-body-must-not-enter-journal"
    let assembly = try SystemPromptAssembly.build(
        cwd: root.path, memory: secret, includeContextFiles: false)
    let request = ChatRequest(
        model: "model", messages: [.system(assembly.flattenedText), .user("hello")])
    let store = ContextBodyStore(home: home)
    let manifest = try promptSourceManifestFixture(
        assembly: assembly, request: request, store: store, journal: bundle.sessionJournal)
    let componentDeliveredBytes = manifest.deliveredBytes

    let permit = try await bundle.prepareModelCrossing(manifest: manifest, admission: fixtureProviderAdmission(), kind: .provider)
    let data = try Data(contentsOf: home.timelineV2SessionJournalURL(session))
    let read = TimelineJournalReader.read(
        data, journal: bundle.sessionJournal,
        actor: TimelineActor(actorID: "prompt-source-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    let events = read.records.map(\.event)
    let observation = try XCTUnwrap(events.last {
        $0.type == TimelineEventType.contextSourcesObserved
    })
    let crossing = try XCTUnwrap(events.last {
        $0.type == TimelineEventType.contextAssembled
    })
    XCTAssertEqual(crossing.previousEventID, observation.eventID)
    XCTAssertEqual(
        crossing.causedByEventID,
        EventRef(journal: bundle.sessionJournal, eventID: observation.eventID))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(root.path))

    let snapshot = SessionReducer.reduce(events)
    XCTAssertTrue(snapshot.semanticProjectionValid)
    let durable = try XCTUnwrap(snapshot.contextManifest)
    XCTAssertEqual(durable.deliveredBytes, componentDeliveredBytes)
    XCTAssertEqual(durable.cumulativeDeliveredBytes, componentDeliveredBytes)
    XCTAssertEqual(durable.systemPromptSources?.count, assembly.sources.count)
    XCTAssertTrue(durable.systemPromptSources?.allSatisfy {
        $0.provenance == EventRef(
            journal: bundle.sessionJournal, eventID: observation.eventID)
    } == true)
    XCTAssertEqual(
        durable.systemPromptSources?.map(\.renderedByteCount).reduce(0, +),
        assembly.flattenedByteCount)

    _ = try await bundle.finishAction(permit, state: .succeeded, retrySafety: .unsafe,
        providerSettlement: fixtureProviderSettlement(permit))
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
}

func test_promptSourceManifestReducerRejectsForgedOrMismatchedObservation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-prompt-source-forgery-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("prompt-source-forgery-session")
    let work = WorkRef(workHostID: hostID, workID: "prompt-source-forgery-work")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("prompt-source-service"),
        sessionAttachment: SessionAttachmentRef("prompt-source-attachment"),
        run: RunRef("prompt-source-forgery-run"),
        actor: TimelineActor(actorID: "prompt-source-test", kind: "self-test"),
        modelID: "provider/model")
    let assembly = try SystemPromptAssembly.build(cwd: root.path, includeContextFiles: false)
    let request = ChatRequest(model: "model", messages: [.system(assembly.flattenedText)])
    let manifest = try promptSourceManifestFixture(
        assembly: assembly, request: request, store: ContextBodyStore(home: home),
        journal: bundle.sessionJournal)
    let permit = try await bundle.prepareModelCrossing(manifest: manifest, admission: fixtureProviderAdmission(), kind: .provider)
    let read = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2SessionJournalURL(session)),
        journal: bundle.sessionJournal,
        actor: TimelineActor(actorID: "prompt-source-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    let events = read.records.map(\.event)
    let crossingIndex = try XCTUnwrap(events.lastIndex {
        $0.type == TimelineEventType.contextAssembled
    })
    let crossing = events[crossingIndex]

    var forged = events
    forged[crossingIndex] = promptSourceClone(
        crossing,
        causedBy: EventRef(journal: bundle.sessionJournal, eventID: "not-the-observation"))
    let forgedSnapshot = SessionReducer.reduce(forged)
    XCTAssertFalse(forgedSnapshot.semanticProjectionValid)
    XCTAssertNil(forgedSnapshot.contextManifest)

    let observationIndex = try XCTUnwrap(events.lastIndex {
        $0.type == TimelineEventType.contextSourcesObserved
    })
    var mismatchedPayload = try XCTUnwrap(events[observationIndex].payload.objectValue)
    mismatchedPayload["assembly_id"] = .string("system-prompt-assembly:wrong")
    var mismatched = events
    mismatched[observationIndex] = promptSourceClone(
        events[observationIndex], payload: .object(mismatchedPayload))
    let mismatchedSnapshot = SessionReducer.reduce(mismatched)
    XCTAssertFalse(mismatchedSnapshot.semanticProjectionValid)
    XCTAssertNil(mismatchedSnapshot.contextManifest)

    let identityCases: [(String, TimelineEvent)] = [
        ("missing session", promptSourceClone(events[observationIndex], clearSession: true)),
        ("missing work", promptSourceClone(events[observationIndex], clearWork: true)),
        ("missing work host", promptSourceClone(events[observationIndex], clearWorkHost: true)),
        ("missing run", promptSourceClone(events[observationIndex], clearRun: true)),
        ("foreign run", promptSourceClone(
            events[observationIndex], run: RunRef("prompt-source-foreign-run"))),
        ("foreign work", promptSourceClone(
            events[observationIndex],
            work: WorkRef(workHostID: events[observationIndex].work!.workHostID,
                          workID: "prompt-source-foreign-work"))),
        ("foreign work host", promptSourceClone(
            events[observationIndex],
            work: WorkRef(workHostID: "prompt-source-foreign-host", workID: "prompt-source-work"),
            workHost: WorkHostRef("prompt-source-foreign-host"))),
    ]
    for (label, forgedObservation) in identityCases {
        var forgedIdentity = events
        forgedIdentity[observationIndex] = forgedObservation
        let snapshot = SessionReducer.reduce(forgedIdentity)
        XCTAssertFalse(snapshot.semanticProjectionValid, label)
        XCTAssertNil(snapshot.contextManifest, label)
        XCTAssertTrue(
            snapshot.quarantinedEvents.contains {
                $0.eventID == forgedObservation.eventID || $0.eventID == crossing.eventID
            }, label)
    }

    _ = try await bundle.finishAction(permit, state: .succeeded, retrySafety: .unsafe,
        providerSettlement: fixtureProviderSettlement(permit))
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
}

func test_promptSourceManifestRejectsSwappedAssemblyAndEmptySourcesBeforeAppend() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-prompt-source-swap-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("prompt-source-swap-session")
    let work = WorkRef(workHostID: hostID, workID: "prompt-source-swap-work")
    let run = RunRef("prompt-source-swap-run")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("prompt-source-service"),
        sessionAttachment: SessionAttachmentRef("prompt-source-attachment"), run: run,
        actor: TimelineActor(actorID: "prompt-source-test", kind: "self-test"),
        modelID: "provider/model")
    let store = ContextBodyStore(home: home)
    let assemblyA = try SystemPromptAssembly.build(
        cwd: root.path, memory: "assembly A", includeContextFiles: false)
    let assemblyB = try SystemPromptAssembly.build(
        cwd: root.path, memory: "assembly B", includeContextFiles: false)
    let requestA = ChatRequest(
        model: "model", messages: [.system(assemblyA.flattenedText), .user("A")])
    let requestB = ChatRequest(
        model: "model", messages: [.system(assemblyB.flattenedText), .user("B")])
    let manifestA = try promptSourceManifestFixture(
        assembly: assemblyA, request: requestA, store: store, journal: bundle.sessionJournal,
        manifestID: "assembly-a")
    let manifestB = try promptSourceManifestFixture(
        assembly: assemblyB, request: requestB, store: store, journal: bundle.sessionJournal,
        manifestID: "assembly-b")
    let swapped = ContextManifest(
        schemaVersion: manifestA.schemaVersion, manifestID: manifestA.manifestID,
        requestID: manifestA.requestID, modelID: manifestA.modelID,
        measuredBy: manifestA.measuredBy, components: manifestA.components,
        omissions: manifestA.omissions,
        cumulativeDeliveredBytes: manifestA.cumulativeDeliveredBytes,
        systemPromptAssemblyID: manifestB.systemPromptAssemblyID,
        systemPromptSources: manifestB.systemPromptSources)
    let before = try promptSourceEvents(
        home: home, session: session, journal: bundle.sessionJournal)
    do {
        _ = try await bundle.prepareModelCrossing(manifest: swapped, admission: fixtureProviderAdmission(), kind: .provider)
        XCTFail("an assembly from request B must not authorize request A")
    } catch { }
    let afterSwap = try promptSourceEvents(
        home: home, session: session, journal: bundle.sessionJournal)
    XCTAssertEqual(afterSwap.count, before.count)
    XCTAssertFalse(afterSwap.contains { $0.type == TimelineEventType.contextSourcesObserved })
    XCTAssertFalse(afterSwap.contains { $0.type == TimelineEventType.contextAssembled })

    let emptySources = ContextManifest(
        schemaVersion: manifestA.schemaVersion, manifestID: manifestA.manifestID,
        requestID: manifestA.requestID, modelID: manifestA.modelID,
        measuredBy: manifestA.measuredBy, components: manifestA.components,
        omissions: manifestA.omissions,
        cumulativeDeliveredBytes: manifestA.cumulativeDeliveredBytes,
        systemPromptAssemblyID: assemblyA.digest, systemPromptSources: [])
    do {
        _ = try await bundle.prepareModelCrossing(manifest: emptySources, admission: fixtureProviderAdmission(), kind: .provider)
        XCTFail("a source-aware manifest must not have an empty source list")
    } catch { }
    let afterEmpty = try promptSourceEvents(
        home: home, session: session, journal: bundle.sessionJournal)
    XCTAssertEqual(afterEmpty.count, before.count)
    XCTAssertFalse(afterEmpty.contains { $0.type == TimelineEventType.contextSourcesObserved })
    XCTAssertFalse(afterEmpty.contains { $0.type == TimelineEventType.contextAssembled })
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
}

func test_promptSourceManifestRejectsContradictorySourceMetadataAndMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-prompt-source-metadata-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("prompt-source-metadata-session")
    let work = WorkRef(workHostID: hostID, workID: "prompt-source-metadata-work")
    let run = RunRef("prompt-source-metadata-run")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("prompt-source-service"),
        sessionAttachment: SessionAttachmentRef("prompt-source-attachment"), run: run,
        actor: TimelineActor(actorID: "prompt-source-test", kind: "self-test"),
        modelID: "provider/model")
    let assembly = try SystemPromptAssembly.build(
        cwd: root.path, memory: "metadata fixture", includeContextFiles: false)
    let request = ChatRequest(model: "model", messages: [.system(assembly.flattenedText)])
    let store = ContextBodyStore(home: home)
    let manifest = try promptSourceManifestFixture(
        assembly: assembly, request: request, store: store, journal: bundle.sessionJournal)
    let source = try XCTUnwrap(manifest.systemPromptSources?.first { $0.status == .present })

    let differentDigest = String(repeating: "0", count: 64)
    let digestMismatch = ContextManifestSource(
        sourceID: source.sourceID, inclusionID: source.inclusionID, kind: source.kind,
        status: .present, label: source.label, fullByteCount: source.fullByteCount,
        fullDigest: "sha256:\(differentDigest)", deliveredByteCount: source.deliveredByteCount,
        deliveredDigest: source.deliveredDigest,
        deliveredByteOffsetInRendered: source.deliveredByteOffsetInRendered,
        renderedByteCount: source.renderedByteCount, renderedDigest: source.renderedDigest,
        fullBodyReference: source.fullBodyReference,
        deliveredBodyReference: source.deliveredBodyReference,
        renderedBodyReference: source.renderedBodyReference)
    let badDigestManifest = promptSourceManifest(manifest, replacing: digestMismatch,
                                                  at: manifest.systemPromptSources!.firstIndex {
                                                      $0.inclusionID == source.inclusionID
                                                  }!)
    do {
        _ = try await bundle.prepareModelCrossing(manifest: badDigestManifest, admission: fixtureProviderAdmission(), kind: .provider)
        XCTFail("present source full and delivered digests must agree")
    } catch { }

    let foreignJournal = JournalRef.session(
        SessionRef("foreign-prompt-source"), authority: TimelineAuthorityRef("foreign"))
    let differentReference = TimelineBodyReference(
        authority: foreignJournal, referenceID: source.fullDigest!,
        mediaType: "application/vnd.aviary.prompt-source+utf8",
        byteCount: source.fullByteCount, digest: source.fullDigest)
    let referenceMismatch = ContextManifestSource(
        sourceID: source.sourceID, inclusionID: source.inclusionID, kind: source.kind,
        status: .present, label: source.label, fullByteCount: source.fullByteCount,
        fullDigest: source.fullDigest, deliveredByteCount: source.deliveredByteCount,
        deliveredDigest: source.deliveredDigest,
        deliveredByteOffsetInRendered: source.deliveredByteOffsetInRendered,
        renderedByteCount: source.renderedByteCount, renderedDigest: source.renderedDigest,
        fullBodyReference: differentReference,
        deliveredBodyReference: source.deliveredBodyReference,
        renderedBodyReference: source.renderedBodyReference)
    let badReferenceManifest = promptSourceManifest(manifest, replacing: referenceMismatch,
                                                      at: manifest.systemPromptSources!.firstIndex {
                                                          $0.inclusionID == source.inclusionID
                                                      }!)
    do {
        _ = try await bundle.prepareModelCrossing(manifest: badReferenceManifest, admission: fixtureProviderAdmission(), kind: .provider)
        XCTFail("present source full and delivered references must agree and be local")
    } catch { }

    let secretMediaReference = TimelineBodyReference(
        authority: source.fullBodyReference!.authority, referenceID: source.fullBodyReference!.referenceID,
        mediaType: "application/vnd.aviary.prompt-source+utf8;path=\(root.path);token=secret",
        byteCount: source.fullBodyReference!.byteCount, digest: source.fullBodyReference!.digest)
    let secretMediaSource = ContextManifestSource(
        sourceID: source.sourceID, inclusionID: source.inclusionID, kind: source.kind,
        status: source.status, label: source.label, fullByteCount: source.fullByteCount,
        fullDigest: source.fullDigest, deliveredByteCount: source.deliveredByteCount,
        deliveredDigest: source.deliveredDigest,
        deliveredByteOffsetInRendered: source.deliveredByteOffsetInRendered,
        renderedByteCount: source.renderedByteCount, renderedDigest: source.renderedDigest,
        fullBodyReference: secretMediaReference,
        deliveredBodyReference: source.deliveredBodyReference,
        renderedBodyReference: source.renderedBodyReference)
    let badMediaManifest = promptSourceManifest(manifest, replacing: secretMediaSource,
                                                 at: manifest.systemPromptSources!.firstIndex {
                                                     $0.inclusionID == source.inclusionID
                                                 }!)
    do {
        _ = try await bundle.prepareModelCrossing(manifest: badMediaManifest, admission: fixtureProviderAdmission(), kind: .provider)
        XCTFail("prompt source body media types must be exact and secret-free")
    } catch { }
    XCTAssertFalse(try promptSourceEvents(home: home, session: session, journal: bundle.sessionJournal)
        .contains { $0.type == TimelineEventType.contextSourcesObserved })
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
}

func test_promptSourceManifestRejectsTruncatedBodyThatIsNotAFullPrefix() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-prompt-source-truncation-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let contextFile = root.appendingPathComponent("AGENTS.md")
    try String(repeating: "A", count: 13_001).write(
        to: contextFile, atomically: true, encoding: .utf8)
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("prompt-source-truncation-session")
    let work = WorkRef(workHostID: hostID, workID: "prompt-source-truncation-work")
    let run = RunRef("prompt-source-truncation-run")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("prompt-source-service"),
        sessionAttachment: SessionAttachmentRef("prompt-source-attachment"), run: run,
        actor: TimelineActor(actorID: "prompt-source-test", kind: "self-test"),
        modelID: "provider/model")
    let assembly = try SystemPromptAssembly.build(cwd: root.path, includeContextFiles: true)
    let request = ChatRequest(model: "model", messages: [.system(assembly.flattenedText)])
    let store = ContextBodyStore(home: home)
    let manifest = try promptSourceManifestFixture(
        assembly: assembly, request: request, store: store, journal: bundle.sessionJournal)
    let sourceIndex = try XCTUnwrap(manifest.systemPromptSources?.firstIndex { $0.status == .truncated })
    let source = try XCTUnwrap(manifest.systemPromptSources?[sourceIndex])
    let wrongDelivered = Data(repeating: 0x5A, count: source.deliveredByteCount)
    let renderedBody = try XCTUnwrap(assembly.sources.first { $0.sourceID == source.sourceID })
        .renderedBody
    var wrongRendered = Data(renderedBody.utf8)
    let renderedEnd = source.deliveredByteOffsetInRendered + source.deliveredByteCount
    wrongRendered.replaceSubrange(
        source.deliveredByteOffsetInRendered..<renderedEnd, with: wrongDelivered)
    let wrongDeliveredReference = try store.retain(
        wrongDelivered, authority: bundle.sessionJournal,
        mediaType: "application/vnd.aviary.prompt-source+utf8")
    let wrongRenderedReference = try store.retain(
        wrongRendered, authority: bundle.sessionJournal,
        mediaType: "application/vnd.aviary.prompt-source+utf8")
    let malformed = ContextManifestSource(
        sourceID: source.sourceID, inclusionID: source.inclusionID, kind: source.kind,
        status: .truncated, label: source.label, fullByteCount: source.fullByteCount,
        fullDigest: source.fullDigest, deliveredByteCount: wrongDelivered.count,
        deliveredDigest: wrongDeliveredReference.digest!,
        deliveredByteOffsetInRendered: source.deliveredByteOffsetInRendered,
        renderedByteCount: wrongRendered.count, renderedDigest: wrongRenderedReference.digest!,
        fullBodyReference: source.fullBodyReference,
        deliveredBodyReference: wrongDeliveredReference,
        renderedBodyReference: wrongRenderedReference)
    let malformedManifest = promptSourceManifest(manifest, replacing: malformed, at: sourceIndex)
    do {
        _ = try await bundle.prepareModelCrossing(manifest: malformedManifest, admission: fixtureProviderAdmission(), kind: .provider)
        XCTFail("a truncated delivered body must be a prefix of its full retained body")
    } catch { }
    let events = try promptSourceEvents(home: home, session: session, journal: bundle.sessionJournal)
    XCTAssertFalse(events.contains { $0.type == TimelineEventType.contextSourcesObserved })
    XCTAssertFalse(events.contains { $0.type == TimelineEventType.contextAssembled })
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
}
