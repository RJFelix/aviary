import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AviaryCore

private let persistentSessionID = SessionRef("persistent-session-exact")
private let persistentSessionJournal = JournalRef.session(
    persistentSessionID, journalID: "persistent-session-exact-journal",
    authority: TimelineAuthorityRef("persistent-session-exact-authority"))
private let persistentSessionWork = WorkRef(
    workHostID: "persistent-session-exact-host", workID: "persistent-session-exact-work")

private func persistentSessionDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "aviary-persistent-session-\(UUID().uuidString.lowercased())",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    guard chmod(directory.path, mode_t(0o700)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }
    return directory
}

private func persistentSessionMap(at directory: URL) throws -> PersistentProjectionRadixMap {
    try PersistentProjectionRadixMap(
        directory: directory.appending(path: "map", directoryHint: .isDirectory),
        namespaceID: "persistent-session-exact-namespace", journal: persistentSessionJournal,
        sourceGeneration: String(repeating: "b", count: 64), mapKind: "session-exact-v1")
}

private func persistentSessionValueFiles(
    in directory: URL, containingRecordKind expectedKind: String
) throws -> [URL] {
    let values = directory.appending(path: "map/values", directoryHint: .isDirectory)
    return try FileManager.default.contentsOfDirectory(atPath: values.path).compactMap { name in
        let url = values.appending(path: name)
        guard let envelope = JSONValue.parse(try Data(contentsOf: url)),
              let encoded = envelope["body"]?["bytes"]?.stringValue,
              let bytes = Data(base64Encoded: encoded),
              JSONValue.parse(bytes)?["kind"]?.stringValue == expectedKind else { return nil }
        return url
    }
}

private func persistentSessionJSON<T: Encodable>(_ value: T) -> JSONValue {
    JSONValue.parse(try! JSONEncoder().encode(value))!
}

private func persistentSessionContextPayload(_ manifest: ContextManifest) -> JSONValue {
    var payload: [String: JSONValue] = [
        "manifest_id": .string(manifest.manifestID),
        "request_id": .string(manifest.requestID),
        "model_id": .string(manifest.modelID),
        "schema_version": .number(Double(manifest.schemaVersion)),
        "measured_by": .string(manifest.measuredBy),
        "measured_bytes": .number(Double(manifest.measuredBytes)),
        "delivered_bytes": .number(Double(manifest.deliveredBytes)),
        "cumulative_delivered_bytes": .number(Double(manifest.cumulativeDeliveredBytes)),
        "components": .array(manifest.components.map(persistentSessionJSON)),
        "omissions": .array(manifest.omissions.map(persistentSessionJSON)),
    ]
    if let assemblyID = manifest.systemPromptAssemblyID {
        payload["system_prompt_assembly_id"] = .string(assemblyID)
    }
    if let sources = manifest.systemPromptSources {
        payload["system_prompt_sources"] = .array(sources.map(persistentSessionJSON))
    }
    return .object(payload)
}

private func persistentSessionEvent(
    _ type: String, _ id: String, _ sequence: Int, previous: String? = nil,
    causedBy: EventRef? = nil,
    command: CommandRef? = nil,
    work: WorkRef? = nil, workHost: WorkHostRef? = nil,
    client: ClientRef? = nil, attachment: SessionAttachmentRef? = nil, run: RunRef? = nil,
    turn: TurnRef? = nil, conversationParent: EventRef? = nil,
    declaredDomains: Set<TimelineDomain> = [], payload: JSONValue = .object([:]),
    session: SessionRef? = persistentSessionID
) -> TimelineEvent {
    TimelineEvent(
        eventID: id, journal: persistentSessionJournal, sequence: sequence,
        command: command, previousEventID: previous, causedByEventID: causedBy,
        parentActivityID: nil, conversationParent: conversationParent,
        session: session, work: work, workHost: workHost,
        client: client, sessionAttachment: attachment, run: run, turn: turn,
        actor: TimelineActor(actorID: "persistent-session-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: Double(sequence)),
        type: type, declaredDomains: declaredDomains, payload: payload)
}

private func testPersistentSessionExactStateRetainsInputDeliveryJoinAcrossReopen() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var state = try PersistentSessionExactState(map: map)
    let created = persistentSessionEvent(
        TimelineEventType.sessionCreated, "delivery-reopen-1", 1)
    let attachment = SessionAttachmentRef("delivery-reopen-attachment")
    let attached = persistentSessionEvent(
        TimelineEventType.sessionAttached, "delivery-reopen-2", 2,
        previous: created.eventID, work: persistentSessionWork,
        workHost: WorkHostRef(persistentSessionWork.workHostID),
        attachment: attachment,
        payload: .object(["capabilities": .array([.string("send")])]))
    let client = ClientRef("delivery-reopen-client")
    let workJournal = JournalRef.work(persistentSessionWork)
    let acceptance = EventRef(journal: workJournal, eventID: "work-acceptance-7")
    let run = RunRef("delivery-reopen-run")
    let input = persistentSessionEvent(
        TimelineEventType.inputAccepted, "delivery-reopen-3", 3,
        previous: attached.eventID, causedBy: acceptance,
        command: CommandRef(
            commandID: "delivery-reopen-command", client: client,
            sessionAttachment: attachment),
        work: persistentSessionWork,
        workHost: WorkHostRef(persistentSessionWork.workHostID),
        client: client, attachment: attachment, run: run,
        payload: .object(["text": .string("private delivery input")]))
    for event in [created, attached, input] { _ = try state.apply(event) }

    var reopened = try PersistentSessionExactState(
        map: map, root: try XCTUnwrap(state.currentRoot))
    let continued = try reopened.apply(persistentSessionEvent(
        TimelineEventType.messageCommitted, "delivery-reopen-4", 4,
        previous: input.eventID,
        conversationParent: EventRef(
            journal: persistentSessionJournal, eventID: input.eventID),
        payload: .object(["role": .string("assistant"), "text": .string("safe")])))
    let message = try XCTUnwrap(continued.eventLocalSnapshot.messageHistory.first)
    XCTAssertEqual(message.client, client)
    XCTAssertEqual(message.sessionAttachment, attachment)
    XCTAssertEqual(message.run, run)
    XCTAssertEqual(message.causedBy, acceptance)
    XCTAssertEqual(message.text, "[redacted]")
}

private func persistentSessionComponent() -> ContextComponent {
    ContextComponent(
        componentID: "persistent-session-component",
        inclusionID: "persistent-session-inclusion", sourceID: "persistent-session-source",
        mode: .history, deliveryMode: .full, measuredBytes: 5, includedBytes: 5,
        deliveredBytes: 5, fullByteCount: 5,
        digest: "sha256:" + String(repeating: "a", count: 64))
}

private func persistentSessionRepresentativeEvents() -> [TimelineEvent] {
    let created = persistentSessionEvent(TimelineEventType.sessionCreated, "session-exact-1", 1)
    let attachment = SessionAttachmentRef("session-exact-attachment")
    let attached = persistentSessionEvent(
        TimelineEventType.sessionAttached, "session-exact-2", 2, previous: created.eventID,
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        attachment: attachment, payload: .object([
            "capabilities": .array([.string("observe"), .string("send")])]))
    let input = persistentSessionEvent(
        TimelineEventType.inputAccepted, "session-exact-3", 3, previous: attached.eventID,
        payload: .object(["text": .string("private user message")]))
    let reply = persistentSessionEvent(
        TimelineEventType.messageCommitted, "session-exact-4", 4, previous: input.eventID,
        conversationParent: EventRef(journal: persistentSessionJournal, eventID: input.eventID),
        payload: .object(["role": .string("assistant"), "text": .string("private assistant reply")]))
    let model = persistentSessionEvent(
        TimelineEventType.modelChanged, "session-exact-5", 5, previous: reply.eventID,
        payload: .object(["model_id": .string("session-exact-model")]))
    let context = persistentSessionEvent(
        TimelineEventType.contextAssembled, "session-exact-6", 6, previous: model.eventID,
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        run: RunRef("session-exact-run"), payload: .object([
            "components": .array([persistentSessionJSON(persistentSessionComponent())])]))
    let tip = persistentSessionEvent(
        TimelineEventType.sessionTipSelected, "session-exact-7", 7, previous: context.eventID,
        conversationParent: EventRef(journal: persistentSessionJournal, eventID: reply.eventID))
    let child = persistentSessionEvent(
        TimelineEventType.childLifecycle, "session-exact-8", 8, previous: tip.eventID,
        payload: .object(["child_id": .string("child-exact"), "state": .string("running")]))
    let compaction = persistentSessionEvent(
        TimelineEventType.compaction, "session-exact-9", 9, previous: child.eventID,
        payload: .object(["summary": .string("private compaction summary")]))
    let unknown = persistentSessionEvent(
        "future.session.exact", "session-exact-10", 10, previous: compaction.eventID,
        declaredDomains: [.context, .runtime],
        payload: .object(["secret": .string("private unknown payload")]))
    let attention = persistentSessionEvent(
        TimelineEventType.sessionAttention, "session-exact-11", 11, previous: unknown.eventID,
        payload: .object(["attention": .string("review")]))
    return [created, attached, input, reply, model, context, tip, child, compaction, unknown, attention]
}

private func persistentSessionExpectError<T: Error>(
    _ body: () throws -> Void, _ check: (T) -> Bool, line: Int = #line
) {
    do { try body(); XCTFail("expected error", line: line) }
    catch let error as T { XCTAssertTrue(check(error), "unexpected error: \(error)", line: line) }
    catch { XCTFail("unexpected error: \(error)", line: line) }
}

private func testPersistentSessionExactStateRepresentativeParity() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var state = try PersistentSessionExactState(map: map)
    var canonical = InMemorySessionTransitionState()
    for event in persistentSessionRepresentativeEvents() {
        let result = try state.apply(event)
        SessionReducerTransition.apply(event, to: &canonical)
        XCTAssertEqual(result.eventLocalSnapshot.lastEventID, canonical.snapshot.lastEventID)
        XCTAssertEqual(result.eventLocalSnapshot.lastSequence, canonical.snapshot.lastSequence)
        XCTAssertEqual(result.eventLocalSnapshot.lifecycle, canonical.snapshot.lifecycle)
        XCTAssertEqual(result.eventLocalSnapshot.modelID, canonical.snapshot.modelID)
        XCTAssertEqual(result.eventLocalSnapshot.attention, canonical.snapshot.attention)
        XCTAssertEqual(result.eventLocalSnapshot.semanticTip, canonical.snapshot.semanticTip)
        XCTAssertEqual(result.eventLocalSnapshot.unknownDomains, canonical.snapshot.unknownDomains)
        XCTAssertEqual(result.eventLocalSnapshot.structuralIntegrityValid,
                       canonical.snapshot.structuralIntegrityValid)
        XCTAssertEqual(result.eventLocalSnapshot.semanticProjectionValid,
                       canonical.snapshot.semanticProjectionValid)
        if let attachment = event.sessionAttachment {
            XCTAssertEqual(
                result.eventLocalSnapshot.attachments[attachment.attachmentID],
                canonical.snapshot.attachments[attachment.attachmentID])
        }
        if event.type == TimelineEventType.messageCommitted {
            XCTAssertEqual(result.eventLocalSnapshot.messageHistory.map(\.text), [
                "private user message", "private assistant reply"])
        }
        if event.type == TimelineEventType.childLifecycle {
            XCTAssertEqual(result.eventLocalSnapshot.childStates["child-exact"], "running")
        }
        XCTAssertFalse(result.changedSlots.isEmpty)
    }
    XCTAssertEqual(state.eventLocalSnapshot.attention, .review)
    XCTAssertEqual(state.eventLocalSnapshot.unknownEvents.count, 1)
    let childRecords = try persistentSessionValueFiles(
        in: directory, containingRecordKind: "child")
    XCTAssertFalse(childRecords.isEmpty)
    let compactionRecords = try persistentSessionValueFiles(
        in: directory, containingRecordKind: "compaction")
    XCTAssertFalse(compactionRecords.isEmpty)
}

private func testPersistentSessionExactStateReopenContinuesAndRejectsDuplicate() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var first = try PersistentSessionExactState(map: map)
    let created = persistentSessionEvent(TimelineEventType.sessionCreated, "reopen-1", 1)
    let root = try first.apply(created).root
    var reopened = try PersistentSessionExactState(map: map, root: root)
    XCTAssertEqual(reopened.eventLocalSnapshot.lastSequence, 1)
    let priorRoot = reopened.currentRoot
    persistentSessionExpectError({ _ = try reopened.apply(created) }, {
        (error: PersistentSessionExactState.Error) in
        if case .duplicateEvent("reopen-1") = error { return true }
        return false
    })
    XCTAssertEqual(reopened.currentRoot, priorRoot)
    let continued = try reopened.apply(persistentSessionEvent(
        TimelineEventType.modelChanged, "reopen-2", 2, previous: created.eventID,
        payload: .object(["model_id": .string("reopened-model")])))
    XCTAssertEqual(continued.eventLocalSnapshot.modelID, "reopened-model")
    XCTAssertEqual(continued.eventLocalSnapshot.lastSequence, 2)
}

private func testPersistentSessionExactStateContextAccountingAndAttachments() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var state = try PersistentSessionExactState(map: map)
    let created = persistentSessionEvent(TimelineEventType.sessionCreated, "context-1", 1)
    let attachment = SessionAttachmentRef("context-attachment")
    let attached = persistentSessionEvent(
        TimelineEventType.sessionAttached, "context-2", 2, previous: created.eventID,
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        attachment: attachment)
    let digest = "sha256:" + String(repeating: "c", count: 64)
    let bodyReference = TimelineBodyReference(
        authority: persistentSessionJournal, referenceID: digest,
        byteCount: 4, digest: digest)
    let retained = ContextComponent(
        componentID: "context-retained-component", inclusionID: "context-retained-inclusion",
        sourceID: "context-retained-source", mode: .history, measuredBytes: 4,
        includedBytes: 4, deliveredBytes: 4, fullByteCount: 4,
        bodyReference: bodyReference, digest: digest)
    let manifest = ContextManifest(
        manifestID: "context-manifest-1", requestID: "context-request-1", modelID: "context-model",
        components: [retained], cumulativeDeliveredBytes: 4)
    let manifestJSON = persistentSessionContextPayload(manifest)
    let firstContext = persistentSessionEvent(
        TimelineEventType.contextAssembled, "context-3", 3, previous: attached.eventID,
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        run: RunRef("context-run"), payload: manifestJSON)
    let secondManifest = ContextManifest(
        manifestID: "context-manifest-2", requestID: "context-request-2", modelID: "context-model",
        components: [retained], cumulativeDeliveredBytes: 8)
    let secondContext = persistentSessionEvent(
        TimelineEventType.contextAssembled, "context-4", 4, previous: firstContext.eventID,
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        run: RunRef("context-run"), payload: persistentSessionContextPayload(secondManifest))
    _ = try state.apply(created)
    let attachmentResult = try state.apply(attached)
    XCTAssertEqual(attachmentResult.eventLocalSnapshot.attachments[attachment.attachmentID]?.isAttached, true)
    let contextResult = try state.apply(firstContext)
    XCTAssertEqual(contextResult.eventLocalSnapshot.contextManifest?.cumulativeDeliveredBytes, 4)
    XCTAssertEqual(contextResult.eventLocalSnapshot.contextCumulativeDeliveredBytesByRun?["context-run"], 4)
    let next = try state.apply(secondContext)
    XCTAssertEqual(next.eventLocalSnapshot.contextManifest?.cumulativeDeliveredBytes, 8)
    XCTAssertEqual(next.eventLocalSnapshot.contextCumulativeDeliveredBytesByRun?["context-run"], 8)

    var reopened = try PersistentSessionExactState(
        map: map, root: next.root)
    let regressingManifest = ContextManifest(
        manifestID: "context-manifest-regression", requestID: "context-request-regression",
        modelID: "context-model", components: [retained], cumulativeDeliveredBytes: 7)
    let regressing = try reopened.apply(persistentSessionEvent(
        TimelineEventType.contextAssembled, "context-5", 5, previous: secondContext.eventID,
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        run: RunRef("context-run"), payload: persistentSessionContextPayload(regressingManifest)))
    XCTAssertFalse(regressing.eventLocalSnapshot.semanticProjectionValid)
    XCTAssertEqual(
        regressing.eventLocalSnapshot.contextCumulativeDeliveredBytesByRun?["context-run"], 8)
}

private func testPersistentSessionExactStateContextSourcesSurviveReopenWithoutLabels() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var state = try PersistentSessionExactState(map: map)
    let created = persistentSessionEvent(TimelineEventType.sessionCreated, "source-1", 1)
    let attachment = SessionAttachmentRef("source-attachment")
    let attached = persistentSessionEvent(
        TimelineEventType.sessionAttached, "source-2", 2, previous: created.eventID,
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        attachment: attachment)
    let bodyDigest = "sha256:" + String(repeating: "e", count: 64)
    let componentReference = TimelineBodyReference(
        authority: persistentSessionJournal, referenceID: bodyDigest,
        byteCount: 4, digest: bodyDigest)
    let component = ContextComponent(
        componentID: "source-component", inclusionID: "source-inclusion",
        sourceID: "source-body", mode: .history, measuredBytes: 4, includedBytes: 4,
        deliveredBytes: 4, fullByteCount: 4, bodyReference: componentReference,
        digest: bodyDigest)
    let promptReference = TimelineBodyReference(
        authority: persistentSessionJournal, referenceID: bodyDigest,
        mediaType: "application/vnd.aviary.prompt-source+utf8", byteCount: 4,
        digest: bodyDigest)
    let secretLabel = "private/source/path/token"
    let source = ContextManifestSource(
        sourceID: "source-prompt", inclusionID: "source-prompt-inclusion", kind: .generated,
        status: .present, label: secretLabel, fullByteCount: 4, fullDigest: bodyDigest,
        deliveredByteCount: 4, deliveredDigest: bodyDigest,
        renderedByteCount: 4, renderedDigest: bodyDigest,
        fullBodyReference: promptReference, deliveredBodyReference: promptReference,
        renderedBodyReference: promptReference)
    let assemblyID = "sha256:" + String(repeating: "f", count: 64)
    let observed = persistentSessionEvent(
        TimelineEventType.contextSourcesObserved, "source-3", 3, previous: attached.eventID,
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        run: RunRef("source-run"), payload: .object([
            "assembly_id": .string(assemblyID),
            "source_count": .number(1),
            "sources": .array([persistentSessionJSON(source)])
        ]))
    let assembled = ContextManifest(
        manifestID: "source-manifest", requestID: "source-request", modelID: "source-model",
        components: [component], cumulativeDeliveredBytes: 4,
        systemPromptAssemblyID: assemblyID, systemPromptSources: [source.withProvenance(
            EventRef(journal: persistentSessionJournal, eventID: observed.eventID))])
    let crossing = persistentSessionEvent(
        TimelineEventType.contextAssembled, "source-4", 4, previous: observed.eventID,
        causedBy: EventRef(journal: persistentSessionJournal, eventID: observed.eventID),
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        run: RunRef("source-run"), payload: persistentSessionContextPayload(assembled))
    _ = try state.apply(created)
    _ = try state.apply(attached)
    let observedResult = try state.apply(observed)
    var reopened = try PersistentSessionExactState(map: map, root: observedResult.root)
    let result = try reopened.apply(crossing)
    XCTAssertEqual(result.eventLocalSnapshot.contextManifest?.manifestID, "source-manifest")
    XCTAssertEqual(result.eventLocalSnapshot.contextManifest?.systemPromptSources?.first?.label,
                   secretLabel)
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    while let file = enumerator.nextObject() as? URL {
        guard (try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            continue
        }
        XCTAssertFalse(try Data(contentsOf: file).range(of: Data(secretLabel.utf8)) != nil)
    }

    let contextKey = "session-exact-v1/context"
    let storedContext = try XCTUnwrap(
        try map.lookup(root: result.root, key: contextKey).value)
    func forgedRoot(field: String, value: Any) throws -> PersistentProjectionRadixMap.Root {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: storedContext) as? [String: Any])
        object[field] = value
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let changed = try map.setting(root: result.root, key: contextKey, value: bytes)
        return try XCTUnwrap(changed.newRoot)
    }
    for root in try [
        forgedRoot(
            field: "promptSourcesFingerprint",
            value: "sha256:" + String(repeating: "0", count: 64)),
        forgedRoot(field: "sourcesObservationEventID", value: "foreign-observation"),
    ] {
        persistentSessionExpectError({
            _ = try PersistentSessionExactState(map: map, root: root)
        }, { (error: PersistentSessionExactState.Error) in
            if case .invalidRecord = error { return true }
            return false
        })
    }
}

private func testPersistentSessionExactStatePrivacyAndCanonicalDigests() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var state = try PersistentSessionExactState(map: map)
    let secret = "SESSION-EXACT-PRIVATE-SECRET-PATH-TOKEN-LABEL"
    _ = try state.apply(persistentSessionEvent(
        TimelineEventType.inputAccepted, "privacy-1", 1,
        payload: .object(["text": .string(secret)])))
    _ = try state.apply(persistentSessionEvent(
        TimelineEventType.compaction, "privacy-2", 2, previous: "privacy-1",
        payload: .object(["summary": .string(secret)])))
    _ = try state.apply(persistentSessionEvent(
        "future.private.session", "privacy-3", 3, previous: "privacy-2",
        declaredDomains: [.runtime], payload: .object(["secret": .string(secret)])))
    _ = try state.apply(persistentSessionEvent(
        TimelineEventType.childLifecycle, "privacy-4", 4, previous: "privacy-3",
        payload: .object(["child_id": .string("privacy-child"), "state": .string(secret)])))
    let emptyDigest = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let source = ContextManifestSource(
        sourceID: "privacy-source", inclusionID: "privacy-inclusion", kind: .contextFile,
        status: .missing, label: secret, deliveredByteCount: 0, deliveredDigest: emptyDigest,
        renderedByteCount: 0, renderedDigest: emptyDigest)
    let assemblyID = "sha256:" + String(repeating: "d", count: 64)
    let observed = persistentSessionEvent(
        TimelineEventType.contextSourcesObserved, "privacy-5", 5, previous: "privacy-4",
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        run: RunRef("privacy-run"), payload: .object([
            "assembly_id": .string(assemblyID),
            "source_count": .number(1),
            "sources": .array([persistentSessionJSON(source)])
        ]))
    _ = try state.apply(observed)
    let context = ContextManifest(
        manifestID: "privacy-manifest", requestID: "privacy-request", modelID: "privacy-model",
        components: [persistentSessionComponent()], cumulativeDeliveredBytes: 5,
        systemPromptAssemblyID: assemblyID, systemPromptSources: [source.withProvenance(
            EventRef(journal: persistentSessionJournal, eventID: observed.eventID))])
    _ = try state.apply(persistentSessionEvent(
        TimelineEventType.contextAssembled, "privacy-6", 6, previous: observed.eventID,
        causedBy: EventRef(journal: persistentSessionJournal, eventID: observed.eventID),
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        run: RunRef("privacy-run"), payload: persistentSessionJSON(context)))
    let root = try XCTUnwrap(state.currentRoot)
    let scalar = try XCTUnwrap(try map.lookup(root: root, key: "session-exact-v1/scalar").value)
    let scalarText = String(decoding: scalar, as: UTF8.self)
    XCTAssertFalse(scalarText.contains(secret))
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    while let file = enumerator.nextObject() as? URL {
        guard (try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        XCTAssertFalse(try Data(contentsOf: file).range(of: Data(secret.utf8)) != nil)
    }
    let reopened = try PersistentSessionExactState(map: map, root: root)
    var continued = reopened
    let redactedParent = try continued.apply(persistentSessionEvent(
        TimelineEventType.messageCommitted, "privacy-7", 7, previous: "privacy-6",
        conversationParent: EventRef(journal: persistentSessionJournal, eventID: "privacy-1"),
        payload: .object(["role": .string("assistant"), "text": .string("safe")])))
    XCTAssertEqual(redactedParent.eventLocalSnapshot.messageHistory.first?.text, "[redacted]")
    // A reopened exact state exposes the boundary but not a digest disguised as raw prose.
    XCTAssertNil(reopened.eventLocalSnapshot.compactionSummary)
    XCTAssertEqual(reopened.eventLocalSnapshot.compactionBoundaryEventID, "privacy-2")
    let childRecords = try persistentSessionValueFiles(
        in: directory, containingRecordKind: "child")
    XCTAssertFalse(childRecords.isEmpty)
    XCTAssertTrue(childRecords.contains { file in
        guard let envelope = JSONValue.parse((try? Data(contentsOf: file)) ?? Data()),
              let encoded = envelope["body"]?["bytes"]?.stringValue,
              let bytes = Data(base64Encoded: encoded),
              let body = JSONValue.parse(bytes) else { return false }
        return body["state"]?.stringValue == "unknown"
    })
}

private func testPersistentSessionExactStateBoundsConversationPrefetch() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var state = try PersistentSessionExactState(map: map)
    var previous: String?
    for sequence in 1...140 {
        let id = "bound-\(sequence)"
        let parent = previous.map { EventRef(journal: persistentSessionJournal, eventID: $0) }
        let type = sequence == 1 ? TimelineEventType.inputAccepted : TimelineEventType.messageCommitted
        let payload: JSONValue = sequence == 1
            ? .object(["text": .string("bound-root")])
            : .object(["role": .string("assistant"), "text": .string("bound-\(sequence)")])
        let event = persistentSessionEvent(
            type, id, sequence, previous: previous, conversationParent: parent, payload: payload)
        _ = try state.apply(event)
        previous = id
    }
    let selection = persistentSessionEvent(
        TimelineEventType.sessionTipSelected, "bound-select", 141, previous: previous,
        conversationParent: EventRef(journal: persistentSessionJournal, eventID: "bound-140"))
    let result = try state.apply(selection)
    XCTAssertEqual(result.eventLocalSnapshot.semanticTip?.eventID, "bound-140")
    XCTAssertEqual(result.eventLocalSnapshot.lastSequence, 141)
}

private func testPersistentSessionExactStateDeepTipAfterReopen() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var state = try PersistentSessionExactState(map: map)
    var previous: String?
    for sequence in 1...260 {
        let id = "deep-\(sequence)"
        let parent = previous.map { EventRef(journal: persistentSessionJournal, eventID: $0) }
        let type = sequence == 1 ? TimelineEventType.inputAccepted : TimelineEventType.messageCommitted
        let payload: JSONValue = sequence == 1
            ? .object(["text": .string("deep-root")])
            : .object(["role": .string("assistant"), "text": .string("deep-\(sequence)")])
        _ = try state.apply(persistentSessionEvent(
            type, id, sequence, previous: previous, conversationParent: parent, payload: payload))
        previous = id
    }
    let root = try XCTUnwrap(state.currentRoot)
    var reopened = try PersistentSessionExactState(map: map, root: root)
    let tip = try reopened.apply(persistentSessionEvent(
        TimelineEventType.sessionTipSelected, "deep-select", 261, previous: previous,
        conversationParent: EventRef(journal: persistentSessionJournal, eventID: "deep-260")))
    XCTAssertEqual(tip.eventLocalSnapshot.semanticTip?.eventID, "deep-260")
    XCTAssertEqual(tip.eventLocalSnapshot.lastSequence, 261)
    var reopenedAgain = try PersistentSessionExactState(map: map, root: tip.root)
    let olderTip = try reopenedAgain.apply(persistentSessionEvent(
        TimelineEventType.sessionTipSelected, "deep-select-older", 262, previous: "deep-select",
        conversationParent: EventRef(journal: persistentSessionJournal, eventID: "deep-259")))
    XCTAssertEqual(olderTip.eventLocalSnapshot.semanticTip?.eventID, "deep-259")
    XCTAssertEqual(olderTip.eventLocalSnapshot.lastSequence, 262)
}

private func testPersistentSessionExactStateLinearGrowthStaysBoundedAfterReopen() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var state = try PersistentSessionExactState(map: map)
    var previous: String?
    var maximumMutationNodesVisited = 0
    for sequence in 1...280 {
        let id = "linear-\(sequence)"
        let parent = previous.map { EventRef(journal: persistentSessionJournal, eventID: $0) }
        let type = sequence == 1 ? TimelineEventType.inputAccepted : TimelineEventType.messageCommitted
        let payload: JSONValue = sequence == 1
            ? .object(["text": .string("linear-root")])
            : .object(["role": .string("assistant"), "text": .string("linear-\(sequence)")])
        let result = try state.apply(persistentSessionEvent(
            type, id, sequence, previous: previous, conversationParent: parent, payload: payload))
        maximumMutationNodesVisited = max(
            maximumMutationNodesVisited, result.lastMutationMetrics.nodesVisited)
        previous = id
    }
    XCTAssertEqual(state.eventLocalSnapshot.lastSequence, 280)
    XCTAssertTrue(maximumMutationNodesVisited < PersistentSessionExactState.maximumOperationSlots)
    var reopened = try PersistentSessionExactState(map: map, root: try XCTUnwrap(state.currentRoot))
    let continued = try reopened.apply(persistentSessionEvent(
        TimelineEventType.messageCommitted, "linear-281", 281, previous: previous,
        conversationParent: EventRef(journal: persistentSessionJournal, eventID: "linear-280"),
        payload: .object(["role": .string("assistant"), "text": .string("linear-tail")])))
    XCTAssertEqual(continued.eventLocalSnapshot.lastSequence, 281)
    XCTAssertEqual(reopened.eventLocalSnapshot.lastSequence, 281)
    XCTAssertTrue(continued.lastMutationMetrics.nodesVisited < PersistentSessionExactState.maximumOperationSlots)
}

private func testPersistentSessionExactStateFailsClosedOnCorruptTypedRecord() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var state = try PersistentSessionExactState(map: map)
    let created = persistentSessionEvent(TimelineEventType.sessionCreated, "corrupt-1", 1)
    _ = try state.apply(created)
    let attachment = SessionAttachmentRef("corrupt-attachment")
    _ = try state.apply(persistentSessionEvent(
        TimelineEventType.sessionAttached, "corrupt-2", 2, previous: created.eventID,
        work: persistentSessionWork, workHost: WorkHostRef(persistentSessionWork.workHostID),
        attachment: attachment))
    guard let file = try persistentSessionValueFiles(
        in: directory, containingRecordKind: "attachment").first else {
        XCTFail("attachment record not found")
        return
    }
    try Data("{\"kind\":\"forged\"}".utf8).write(to: file)
    let priorRoot = state.currentRoot
    persistentSessionExpectError({
        _ = try state.apply(persistentSessionEvent(
            TimelineEventType.sessionDetached, "corrupt-3", 3, previous: "corrupt-2",
            attachment: attachment))
    }, { (error: PersistentSessionExactState.Error) in
        if case .map(.invalidObject) = error { return true }
        if case .invalidRecord = error { return true }
        return false
    })
    XCTAssertEqual(state.currentRoot, priorRoot)
}

private func testPersistentSessionExactStateValidatesTypedRecordsBeforePublish() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var state = try PersistentSessionExactState(map: map)
    let created = persistentSessionEvent(TimelineEventType.sessionCreated, "typed-1", 1)
    _ = try state.apply(created)
    let priorRoot = state.currentRoot
    let oversizedRole = String(repeating: "r", count: 257)
    persistentSessionExpectError({
        _ = try state.apply(persistentSessionEvent(
            TimelineEventType.messageCommitted, "typed-2", 2, previous: created.eventID,
            conversationParent: EventRef(journal: persistentSessionJournal, eventID: created.eventID),
            payload: .object([
                "role": .string(oversizedRole), "text": .string("body")
            ])))
    }, { (error: PersistentSessionExactState.Error) in
        if case .invalidRecord = error { return true }
        return false
    })
    // A bad staged message must not publish its seen marker or scalar advance either.
    XCTAssertEqual(state.currentRoot, priorRoot)
    XCTAssertEqual(state.eventLocalSnapshot.lastSequence, 1)
    let valid = try state.apply(persistentSessionEvent(
        TimelineEventType.messageCommitted, "typed-2", 2, previous: created.eventID,
        conversationParent: EventRef(journal: persistentSessionJournal, eventID: created.eventID),
        payload: .object(["role": .string("assistant"), "text": .string("body")])))
    XCTAssertEqual(valid.eventLocalSnapshot.lastSequence, 2)
}

private func testPersistentSessionExactStateStructuralQuarantineReopensAndContinues() throws {
    let directory = try persistentSessionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentSessionMap(at: directory)
    var state = try PersistentSessionExactState(map: map)
    var canonical = InMemorySessionTransitionState()
    let created = persistentSessionEvent(TimelineEventType.sessionCreated, "structural-1", 1)
    _ = try state.apply(created)
    SessionReducerTransition.apply(created, to: &canonical)
    let wrongOwner = persistentSessionEvent(
        TimelineEventType.modelChanged, "structural-2", 2, previous: created.eventID,
        payload: .object(["model_id": .string("ignored")]), session: SessionRef("foreign"))
    let quarantined: PersistentSessionExactState.ApplyResult
    do {
        quarantined = try state.apply(wrongOwner)
    } catch {
        XCTFail("wrong-owner apply: \(error)")
        return
    }
    SessionReducerTransition.apply(wrongOwner, to: &canonical)
    XCTAssertEqual(quarantined.eventLocalSnapshot.lastSequence, canonical.snapshot.lastSequence)
    XCTAssertEqual(quarantined.eventLocalSnapshot.quarantinedEvents.count,
                   canonical.snapshot.quarantinedEvents.count)
    XCTAssertFalse(quarantined.eventLocalSnapshot.structuralIntegrityValid)
    let root = quarantined.root
    var reopened: PersistentSessionExactState
    do {
        reopened = try PersistentSessionExactState(map: map, root: root)
    } catch {
        XCTFail("structural reopen: \(error)")
        return
    }
    XCTAssertEqual(reopened.eventLocalSnapshot.lastSequence, 1)
    XCTAssertFalse(reopened.eventLocalSnapshot.structuralIntegrityValid)
    let afterReopen: PersistentSessionExactState.ApplyResult
    do {
        afterReopen = try reopened.apply(persistentSessionEvent(
            TimelineEventType.modelChanged, "structural-3", 3, previous: wrongOwner.eventID,
            payload: .object(["model_id": .string("still-quarantined")])))
    } catch {
        XCTFail("post-reopen structural continuation: \(error)")
        return
    }
    XCTAssertEqual(afterReopen.eventLocalSnapshot.lastSequence, canonical.snapshot.lastSequence)
    XCTAssertEqual(afterReopen.eventLocalSnapshot.quarantinedEvents.count, 2)
    XCTAssertFalse(afterReopen.eventLocalSnapshot.structuralIntegrityValid)
}

let casesPersistentSessionExactState: [Case] = [
    ("phase3 persistent Session exact state matches reducer across typed transitions", {
        try testPersistentSessionExactStateRepresentativeParity()
    }),
    ("phase3 persistent Session exact state reopens and rejects duplicates", {
        try testPersistentSessionExactStateReopenContinuesAndRejectsDuplicate()
    }),
    ("phase3 persistent Session exact state preserves context accounting and attachments", {
        try testPersistentSessionExactStateContextAccountingAndAttachments()
    }),
    ("phase3 persistent Session exact state rehydrates source fingerprints without labels", {
        try testPersistentSessionExactStateContextSourcesSurviveReopenWithoutLabels()
    }),
    ("phase3 persistent Session exact state keeps message and evidence bodies private", {
        try testPersistentSessionExactStatePrivacyAndCanonicalDigests()
    }),
    ("phase3 persistent Session exact state bounds conversation prefetch", {
        try testPersistentSessionExactStateBoundsConversationPrefetch()
    }),
    ("phase3 persistent Session exact state selects a deep tip after reopen", {
        try testPersistentSessionExactStateDeepTipAfterReopen()
    }),
    ("phase3 persistent Session exact state grows linear history after reopen", {
        try testPersistentSessionExactStateLinearGrowthStaysBoundedAfterReopen()
    }),
    ("phase3 persistent Session exact state fails closed on corrupt typed records", {
        try testPersistentSessionExactStateFailsClosedOnCorruptTypedRecord()
    }),
    ("phase3 persistent Session exact state validates staged records before publish", {
        try testPersistentSessionExactStateValidatesTypedRecordsBeforePublish()
    }),
    ("phase3 persistent Session exact state preserves structural quarantine across reopen", {
        try testPersistentSessionExactStateStructuralQuarantineReopensAndContinues()
    }),
    ("phase3 persistent Session exact state retains input delivery join across reopen", {
        try testPersistentSessionExactStateRetainsInputDeliveryJoinAcrossReopen()
    }),
]
