import Foundation
@testable import AviaryCore

private struct NativeResumeFixture {
    let home: AgentHome
    let identity: SessionWorkIdentity
    let sessionJournal: JournalRef
    let workJournal: JournalRef
    let sessionRead: TimelineJournalReadResult
    let workRead: TimelineJournalReadResult
    let sessionCursor: JournalCursor
    let workCursor: JournalCursor
    let manifest: ContextManifest
    let request: ChatRequest
}

private func nativeResumeManifest(
    request: ChatRequest, bundle: RunJournalBundle, store: ContextBodyStore
) throws -> ContextManifest {
    let base = try ContextManifest.build(
        request: request, manifestID: "native-cold-manifest",
        requestID: "native-cold-request")
    var refs: [String: TimelineBodyReference] = [:]
    for (index, message) in request.messages.enumerated() {
        refs[base.components[index].sourceID] = try store.retain(
            ContextManifest.bodyData(for: message), authority: bundle.sessionJournal,
            mediaType: "application/vnd.aviary.chat-message+json")
    }
    if !request.tools.isEmpty, let toolComponent = base.components.last {
        refs[toolComponent.sourceID] = try store.retain(
            ContextManifest.toolsData(for: request.tools), authority: bundle.sessionJournal,
            mediaType: "application/vnd.aviary.tool-schema-manifest+json")
    }
    let retained = try ContextManifest.build(
        request: request, manifestID: base.manifestID, requestID: base.requestID,
        bodyReferences: refs)
    guard request.messages.count == 2,
          case .text(let systemText) = request.messages[0].content[0] else {
        throw NativeColdResumeError.contextBoundaryMalformed
    }
    let promptSource = try PromptSource(
        sourceID: "native-resume-system", kind: .generated, label: "Native test system",
        fullBody: systemText, deliveredBody: systemText, renderedBody: systemText)
    let promptBody = try store.retain(
        Data(systemText.utf8), authority: bundle.sessionJournal,
        mediaType: "application/vnd.aviary.prompt-source+utf8")
    let promptAssembly = try SystemPromptAssembly(text: systemText, sources: [promptSource])
    let promptManifestSource = ContextManifestSource(
        source: promptSource, inclusionID: "native-resume-system",
        fullBodyReference: promptBody, deliveredBodyReference: promptBody,
        renderedBodyReference: promptBody)
    return ContextManifest(
        schemaVersion: retained.schemaVersion, manifestID: retained.manifestID,
        requestID: retained.requestID, modelID: retained.modelID,
        measuredBy: retained.measuredBy, components: retained.components,
        omissions: retained.omissions, cumulativeDeliveredBytes: retained.cumulativeDeliveredBytes,
        systemPromptAssemblyID: promptAssembly.digest,
        systemPromptSources: [promptManifestSource])
}

private func nativeResumeRead(
    home: AgentHome, journal: JournalRef, url: URL
) throws -> TimelineJournalReadResult {
    TimelineJournalReader.read(
        try Data(contentsOf: url), journal: journal,
        actor: TimelineActor(actorID: "native-resume-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
}

private func makeNativeResumeFixture(
    crossingKind: ActionKind = .provider,
    assistantContent: [ChatContent]? = [.text("after the boundary")],
    suffixInput: String? = nil,
    addUnrepresentedAction: Bool = false,
    tools requestedTools: [ChatTool]? = nil
) async throws -> NativeResumeFixture {
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "native-cold-session",
        work: WorkRef(workHostID: hostID, workID: "native-cold-work"),
        runID: "native-cold-run")
    // Keep a deliberately conflicting compatibility transcript. Production replay must use the
    // native seed and never consult this presentation projection when the native pair exists.
    let legacy = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: identity)
    _ = try await legacy.appendUser("legacy poison must not be replayed")
    _ = try await legacy.appendAssistant(
        text: "legacy-only answer", thinking: "", toolCalls: [],
        usage: nil, stopReason: "stop")
    try await legacy.closeChecked()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "native-resume-producer",
        makeAttachmentID: { "native-cold-attachment" })
    let store = ContextBodyStore(home: home)
    let tools = requestedTools ?? [ChatTool(
        name: "python", description: "Execute Python.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["code": .object(["type": .string("string")])]),
            "required": .array([.string("code")]),
        ]))]
    let request = ChatRequest(model: "provider/native", messages: [
        .system("instructions"), .user("before the boundary"),
    ], tools: tools)
    let manifest = try nativeResumeManifest(request: request, bundle: bundle, store: store)
    let crossing = try await bundle.prepareModelCrossing(
        manifest: manifest, action: ActionRef("context-provider-action"),
        kind: crossingKind)
    _ = try await bundle.finishAction(
        crossing, state: .succeeded, retrySafety: .unsafe)
    if crossingKind == .compactionProvider {
        _ = try await bundle.commitCompaction(
            summary: "compacted", tokensBefore: 100, droppedMessages: 2)
    } else if let assistantContent {
        _ = try await bundle.commitAssistantMessage(
            ChatMessage(role: .assistant, content: assistantContent))
    }
    if let suffixInput {
        let commandID = "suffix-input-command"
        _ = try await bundle.commitInput(
            text: suffixInput, deliveryMode: .queued,
            command: CommandRef(
                commandID: commandID, client: ClientRef("test-client"),
                causalCursor: await bundle.latestWorkCursor))
        _ = try await bundle.markCommandDelivered(commandID: commandID)
    }
    if addUnrepresentedAction {
        let action = try await bundle.beginAction(
            action: ActionRef("unrepresented-python-action"), kind: .python,
            intent: "Execute a tool result absent from a later context")
        _ = try await bundle.finishAction(
            action, state: .succeeded, retrySafety: .unsafe)
    }
    _ = try await bundle.finishRun()
    let sessionCursor = try XCTUnwrap(await bundle.latestSessionCursor)
    let workCursor = try XCTUnwrap(await bundle.latestWorkCursor)
    let sessionJournal = bundle.sessionJournal
    let workJournal = bundle.workJournal
    try await bundle.closeChecked()
    let sessionRead = try nativeResumeRead(
        home: home, journal: sessionJournal,
        url: home.timelineV2SessionJournalURL(sessionID: identity.sessionID))
    let workRead = try nativeResumeRead(
        home: home, journal: workJournal,
        url: home.timelineV2WorkJournalURL(identity.work))
    return NativeResumeFixture(
        home: home, identity: identity, sessionJournal: sessionJournal,
        workJournal: workJournal, sessionRead: sessionRead, workRead: workRead,
        sessionCursor: sessionCursor, workCursor: workCursor,
        manifest: manifest, request: request)
}

private func resumeNativeFixture(
    _ fixture: NativeResumeFixture,
    sessionRead: TimelineJournalReadResult? = nil,
    sessionCursor: JournalCursor? = nil,
    workRead: TimelineJournalReadResult? = nil,
    workCursor: JournalCursor? = nil
) throws -> NativeColdResumeResult {
    try NativeColdResume.resume(
        sessionRead: sessionRead ?? fixture.sessionRead,
        expectedSessionCursor: sessionCursor ?? fixture.sessionCursor,
        workRead: workRead ?? fixture.workRead,
        expectedWorkCursor: workCursor ?? fixture.workCursor,
        bodyStore: ContextBodyStore(home: fixture.home))
}

private func assertNativeResumeThrows(
    _ operation: () throws -> NativeColdResumeResult,
    check: ((NativeColdResumeError) -> Void)? = nil
) {
    do {
        _ = try operation()
        XCTFail("expected native cold resume to refuse")
    } catch let error as NativeColdResumeError {
        check?(error)
    } catch {
        XCTFail("unexpected native cold resume error: \(error)")
    }
}

func test_nativeColdResumeReconstructsProducerContextAndReportsCoverage() async throws {
    let fixture = try await makeNativeResumeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let result = try resumeNativeFixture(fixture)
    XCTAssertEqual(result.pinnedMessages.map(\.plainText), ["instructions"])
    XCTAssertEqual(
        result.messages.map(\.plainText),
        ["before the boundary", "after the boundary"])
    XCTAssertEqual(result.tools, fixture.request.tools)
    XCTAssertEqual(result.modelID, "provider/native")
    XCTAssertEqual(result.sessionCursor, fixture.sessionCursor)
    XCTAssertEqual(result.workCursor, fixture.workCursor)
    XCTAssertEqual(result.coverage.operation, .coldResume)
    XCTAssertEqual(result.coverage.planes[.timeline], .reconstructed)
    XCTAssertEqual(result.coverage.planes[.effectiveContext], .reconstructed)
    XCTAssertEqual(result.coverage.planes[.runtimeNamespace], .lost)
    XCTAssertEqual(result.coverage.planes[.backgroundWork], .lost)
    XCTAssertEqual(result.coverage.planes[.memoriesArtifactsRepository], .unknown)
    XCTAssertEqual(result.coverage.planes[.externalEffects], .unknown)
}

func test_nativeColdResumeAcceptsExactUserSuffixAfterBoundary() async throws {
    let fixture = try await makeNativeResumeFixture(suffixInput: "queued after response")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let result = try resumeNativeFixture(fixture)
    XCTAssertEqual(
        result.messages.map(\.plainText),
        ["before the boundary", "after the boundary", "queued after response"])
}

func test_nativeColdResumeRefusesMissingOrCorruptMessageAndToolBodies() async throws {
    let missingTool = try await makeNativeResumeFixture()
    defer { try? FileManager.default.removeItem(at: missingTool.home.root) }
    let toolRef = try XCTUnwrap(missingTool.manifest.components.last?.bodyReference)
    let toolPath = missingTool.home.root.appending(path: "context-bodies/sha256")
        .appending(path: String(toolRef.referenceID.dropFirst("sha256:".count)))
    try FileManager.default.removeItem(at: toolPath)
    assertNativeResumeThrows({ try resumeNativeFixture(missingTool) }) { error in
        XCTAssertEqual(
            error, .retainedBodyUnavailable(
                missingTool.manifest.components.last!.inclusionID))
    }

    let corruptMessage = try await makeNativeResumeFixture()
    defer { try? FileManager.default.removeItem(at: corruptMessage.home.root) }
    let messageRef = try XCTUnwrap(corruptMessage.manifest.components[0].bodyReference)
    let messagePath = corruptMessage.home.root.appending(path: "context-bodies/sha256")
        .appending(path: String(messageRef.referenceID.dropFirst("sha256:".count)))
    try Data("corrupt".utf8).write(to: messagePath)
    assertNativeResumeThrows({ try resumeNativeFixture(corruptMessage) })

    let unknownMedia = try await makeNativeResumeFixture()
    defer { try? FileManager.default.removeItem(at: unknownMedia.home.root) }
    var unknownRecords = unknownMedia.sessionRead.records
    let contextIndex = try XCTUnwrap(unknownRecords.lastIndex(where: {
        $0.event.type == TimelineEventType.contextAssembled
    }))
    let contextRecord = unknownRecords[contextIndex]
    var contextPayload = try XCTUnwrap(contextRecord.event.payload.objectValue)
    var components = try XCTUnwrap(contextPayload["components"]?.arrayValue)
    var firstComponent = try XCTUnwrap(components[0].objectValue)
    var bodyReference = try XCTUnwrap(firstComponent["body_ref"]?.objectValue)
    bodyReference["media_type"] = .string("application/vnd.aviary.unknown+json")
    firstComponent["body_ref"] = .object(bodyReference)
    components[0] = .object(firstComponent)
    contextPayload["components"] = .array(components)
    unknownRecords[contextIndex] = TimelineJournalRecord(
        event: cloneNativeResumeEvent(
            contextRecord.event, payload: .object(contextPayload)),
        rawLineBytes: contextRecord.rawLineBytes,
        byteStart: contextRecord.byteStart, byteEnd: contextRecord.byteEnd)
    assertNativeResumeThrows({ try resumeNativeFixture(
        unknownMedia,
        sessionRead: TimelineJournalReadResult(records: unknownRecords)) }) { error in
        XCTAssertEqual(
            error, .retainedBodyNotMessage(
                unknownMedia.manifest.components[0].inclusionID))
    }
}

func test_nativeColdResumeRefusesStaleCursorAndTailedRead() async throws {
    let fixture = try await makeNativeResumeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let stale = JournalCursor(
        journal: fixture.sessionJournal,
        eventID: fixture.sessionRead.records.dropLast().last?.event.eventID,
        sequence: fixture.sessionCursor.sequence - 1)
    assertNativeResumeThrows({ try resumeNativeFixture(fixture, sessionCursor: stale) })

    let tailed = TimelineJournalReadResult(
        records: fixture.sessionRead.records,
        truncatedTail: TimelineJournalTail(
            rawBytes: Data("partial".utf8), byteStart: 0, byteEnd: 7))
    assertNativeResumeThrows({ try resumeNativeFixture(fixture, sessionRead: tailed) })

    var misalignedRecords = fixture.sessionRead.records
    let cursorIndex = try XCTUnwrap(misalignedRecords.lastIndex(where: {
        $0.event.type == TimelineEventType.sessionAttachmentCursorAdvanced
    }))
    let cursorRecord = misalignedRecords[cursorIndex]
    let earlierWork = try XCTUnwrap(fixture.workRead.records.dropLast().last?.event)
    let earlierCursor = JournalCursor(
        journal: fixture.workJournal, eventID: earlierWork.eventID,
        sequence: earlierWork.sequence)
    let encodedCursor = try XCTUnwrap(
        JSONValue.parse(try JSONEncoder().encode(earlierCursor)))
    misalignedRecords[cursorIndex] = TimelineJournalRecord(
        event: cloneNativeResumeEvent(
            cursorRecord.event, payload: .object(["cursor": encodedCursor])),
        rawLineBytes: cursorRecord.rawLineBytes,
        byteStart: cursorRecord.byteStart, byteEnd: cursorRecord.byteEnd)
    assertNativeResumeThrows({ try resumeNativeFixture(
        fixture,
        sessionRead: TimelineJournalReadResult(records: misalignedRecords)) }) { error in
        guard case .workStateUnavailable(let reason) = error else {
            return XCTFail("expected attachment cursor refusal, got \(error)")
        }
        XCTAssertTrue(reason.contains("exact Work tip"))
    }
}

func test_nativeColdResumeRefusesTextOnlyOrDanglingStructuredAssistant() async throws {
    let textOnly = try await makeNativeResumeFixture()
    defer { try? FileManager.default.removeItem(at: textOnly.home.root) }
    let messageIndex = try XCTUnwrap(textOnly.sessionRead.records.lastIndex(where: {
        $0.event.type == TimelineEventType.messageCommitted
    }))
    var records = textOnly.sessionRead.records
    let original = records[messageIndex]
    let payload: JSONValue = .object([
        "role": .string("assistant"), "text": .string("flattened")
    ])
    records[messageIndex] = TimelineJournalRecord(
        event: cloneNativeResumeEvent(original.event, payload: payload),
        rawLineBytes: original.rawLineBytes,
        byteStart: original.byteStart, byteEnd: original.byteEnd)
    assertNativeResumeThrows({ try resumeNativeFixture(
        textOnly, sessionRead: TimelineJournalReadResult(records: records)) }) { error in
        XCTAssertEqual(error, .unreconstructableConversationTail(original.event.eventID))
    }

    let dangling = try await makeNativeResumeFixture(
        assistantContent: [
            .text("I will call a tool"),
            .toolCall(id: "dangling", name: "python", arguments: .object([:])),
        ])
    defer { try? FileManager.default.removeItem(at: dangling.home.root) }
    assertNativeResumeThrows({ try resumeNativeFixture(dangling) }) { error in
        XCTAssertEqual(error, .unreconstructableConversationTail("dangling"))
    }
}

func test_nativeColdResumeRefusesPostBoundaryActionAndCompactionCrossing() async throws {
    let actionGap = try await makeNativeResumeFixture(addUnrepresentedAction: true)
    defer { try? FileManager.default.removeItem(at: actionGap.home.root) }
    assertNativeResumeThrows({ try resumeNativeFixture(actionGap) }) { error in
        guard case .workStateUnavailable(let reason) = error else {
            return XCTFail("expected Work action gap refusal, got \(error)")
        }
        XCTAssertTrue(reason.contains("post-context action"))
    }

    let compaction = try await makeNativeResumeFixture(
        crossingKind: .compactionProvider, assistantContent: nil)
    defer { try? FileManager.default.removeItem(at: compaction.home.root) }
    assertNativeResumeThrows({ try resumeNativeFixture(compaction) }) { error in
        guard case .workStateUnavailable(let reason) = error else {
            return XCTFail("expected compaction crossing refusal, got \(error)")
        }
        XCTAssertTrue(reason.contains("compaction request"))
    }
}

private actor NativeResumeRequestRecorder {
    private(set) var requests: [ChatRequest] = []
    func append(_ request: ChatRequest) { requests.append(request) }
}

private struct NativeResumeRecordingProvider: ChatProvider {
    let recorder: NativeResumeRequestRecorder
    var id: String { "native-resume-recording" }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.append(request)
                continuation.yield(.textDelta("resumed answer"))
                continuation.yield(.done(stopReason: "stop"))
                continuation.finish()
            }
        }
    }
}

func test_nativeLaunchCapturesPreStartSeedAndRunnerNeverFallsBackToLegacy() async throws {
    let cwd = "/tmp"
    let model = fakeModel()
    let expectedTools = Agent.tools(
        cwd: cwd, canSpawn: true, spawnBudget: 3, hasMemory: false,
        supportsImages: model.supportsImages, peerCount: 0,
        hasWeb: WebSearch.configuredKey() != nil)
    let fixture = try await makeNativeResumeFixture(tools: expectedTools)
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    guard let host = try makeHost(.reference) else {
        print("      skipped: no reference runtime host")
        return
    }
    _ = try await host.start()
    defer { Task { await host.stop() } }

    let resumedIdentity = SessionWorkIdentity(
        sessionID: fixture.identity.sessionID, work: fixture.identity.work,
        runID: "native-cold-run-2")
    let legacy = try SessionWriter(
        home: fixture.home, resuming: fixture.identity.sessionID, cwd: cwd,
        model: model, identity: resumedIdentity)
    let bridge = try XCTUnwrap(try await NativeSessionCommandJournal.openForLaunch(
        home: fixture.home, identity: resumedIdentity, legacyProjection: legacy,
        actorID: "native-resume-launch", modelID: model.qualifiedID,
        modelContextMode: .exactColdResume))
    let seed = try XCTUnwrap(bridge.resumeSeed)
    XCTAssertEqual(
        seed.messages.map(\.plainText),
        ["before the boundary", "after the boundary"])
    let recoveryRead = try nativeResumeRead(
        home: fixture.home, journal: bridge.nativeJournal.sessionJournal,
        url: fixture.home.timelineV2SessionJournalURL(sessionID: fixture.identity.sessionID))
    XCTAssertEqual(
        SessionReducer.reduce(recoveryRead.records.map(\.event)).recovery.last,
        seed.coverage)

    // This is the adversarial ordering from the GUI: Start is durable before runner.prepare.
    // The immutable seed must not absorb this new prompt and Agent.send must add it once.
    let prompt = "new prompt exactly once"
    let commandID = "native-resume-start-command"
    _ = try await bridge.nativeJournal.commitInput(
        text: prompt, deliveryMode: .queued,
        command: CommandRef(
            commandID: commandID, client: ClientRef("resume-client"),
            causalCursor: await bridge.nativeJournal.latestWorkCursor))

    let recorder = NativeResumeRequestRecorder()
    let seedAssembly = seed.systemPromptAssembly
    let runner = AgentRunner(
        provider: NativeResumeRecordingProvider(recorder: recorder), host: host,
        settings: .init(
            home: fixture.home, cwd: cwd, model: model,
            systemPrompt: seedAssembly.flattenedText,
            systemPromptAssembly: seedAssembly,
            resume: fixture.identity.sessionID, identity: resumedIdentity,
            writer: legacy, nativeJournal: bridge.nativeJournal,
            nativeResumeSeed: seed))
    let (_, agent) = try await runner.prepare()
    let outcome = await agent.send(prompt)
    XCTAssertEqual(outcome, .completed)
    _ = try await bridge.nativeJournal.markCommandDelivered(commandID: commandID)

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(request.messages.first?.plainText, "instructions")
    let texts = request.messages.map(\.plainText)
    XCTAssertEqual(texts.filter { $0 == prompt }.count, 1)
    XCTAssertTrue(texts.contains("before the boundary"))
    XCTAssertTrue(texts.contains("after the boundary"))
    XCTAssertFalse(texts.contains("legacy poison must not be replayed"))
    XCTAssertEqual(request.tools, expectedTools)

    _ = try await bridge.nativeJournal.finishRun()
    try await bridge.nativeJournal.closeChecked()
    try await legacy.closeChecked()
}

private func assertNativeRunnerRefusesAssembly(
    configuredAssembly: SystemPromptAssembly,
    configuredPrompt: String
) async throws {
    let fixture = try await makeNativeResumeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    guard let host = try makeHost(.reference) else {
        print("      skipped: no reference runtime host")
        return
    }
    _ = try await host.start()

    let resumedIdentity = SessionWorkIdentity(
        sessionID: fixture.identity.sessionID, work: fixture.identity.work,
        runID: "native-assembly-mismatch-run")
    let legacy = try SessionWriter(
        home: fixture.home, resuming: fixture.identity.sessionID, cwd: "/tmp",
        model: fakeModel(), identity: resumedIdentity)
    let bridge = try await NativeSessionCommandJournal.openForLaunch(
        home: fixture.home, identity: resumedIdentity, legacyProjection: legacy,
        actorID: "native-assembly-mismatch", modelID: fakeModel().qualifiedID,
        modelContextMode: .exactColdResume)
    let seed = try XCTUnwrap(bridge.resumeSeed)
    let recorder = NativeResumeRequestRecorder()
    let runner = AgentRunner(
        provider: NativeResumeRecordingProvider(recorder: recorder), host: host,
        settings: .init(
            home: fixture.home, cwd: "/tmp", model: fakeModel(),
            systemPrompt: configuredPrompt, systemPromptAssembly: configuredAssembly,
            resume: fixture.identity.sessionID, identity: resumedIdentity,
            writer: legacy, nativeJournal: bridge.nativeJournal,
            nativeResumeSeed: seed))

    do {
        _ = try await runner.prepare()
        XCTFail("native cold resume must reject mismatched prompt assembly before runtime effect")
    } catch RunJournalBundleError.invalidConfiguration {
        XCTAssertTrue(true)
    }
    XCTAssertTrue(await recorder.requests.isEmpty)
    let workRead = try nativeResumeRead(
        home: fixture.home, journal: fixture.workJournal,
        url: fixture.home.timelineV2WorkJournalURL(fixture.identity.work))
    let replacementEvents = workRead.records.map(\.event).filter {
        $0.run == RunRef(resumedIdentity.runID)
    }
    XCTAssertEqual(replacementEvents.map(\.type), [TimelineEventType.runStarted])
    _ = try? await bridge.nativeJournal.finishRun(
        outcome: .failed, detail: "assembly mismatch test cleanup")
    try? await bridge.nativeJournal.closeChecked()
    try? await legacy.closeChecked()
    await host.stop()
}

func test_nativeColdResumeRefusesSameTextDifferentSourceAssembly() async throws {
    let base = try SystemPromptAssembly(
        text: "instructions",
        sources: [try PromptSource(
            sourceID: "native-resume-system", kind: .generated,
            label: "Native test system", fullBody: "instructions",
            deliveredBody: "instructions", renderedBody: "instructions")])
    let differentSources = try SystemPromptAssembly(
        text: base.flattenedText,
        sources: [try PromptSource(
            sourceID: "different-native-source", kind: .generated,
            label: "different source", fullBody: base.flattenedText,
            deliveredBody: base.flattenedText, renderedBody: base.flattenedText)])
    try await assertNativeRunnerRefusesAssembly(
        configuredAssembly: differentSources, configuredPrompt: base.flattenedText)
}

func test_nativeColdResumeRefusesDifferentPromptBytes() async throws {
    let differentPrompt = "a different pinned system prompt"
    let differentAssembly = try SystemPromptAssembly(
        text: differentPrompt,
        sources: [try PromptSource(
            sourceID: "different-native-prompt", kind: .generated,
            label: "different prompt", fullBody: differentPrompt,
            deliveredBody: differentPrompt, renderedBody: differentPrompt)])
    try await assertNativeRunnerRefusesAssembly(
        configuredAssembly: differentAssembly, configuredPrompt: differentPrompt)
}

func test_nativeColdResumeRefusesSourceLessEmptyAssembly() async throws {
    let emptyAssembly = try SystemPromptAssembly(text: "", sources: [])
    try await assertNativeRunnerRefusesAssembly(
        configuredAssembly: emptyAssembly, configuredPrompt: "")
}

func test_nativeLaunchRefusesUnavailableSeedBeforeCommandOrRuntimeEffect() async throws {
    let fixture = try await makeNativeResumeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let body = try XCTUnwrap(fixture.manifest.components.last?.bodyReference)
    let path = fixture.home.root.appending(path: "context-bodies/sha256")
        .appending(path: String(body.referenceID.dropFirst("sha256:".count)))
    try FileManager.default.removeItem(at: path)

    let resumedIdentity = SessionWorkIdentity(
        sessionID: fixture.identity.sessionID, work: fixture.identity.work,
        runID: "native-corrupt-resume-run")
    let legacy = try SessionWriter(
        home: fixture.home, resuming: fixture.identity.sessionID, cwd: "/tmp",
        model: fakeModel(), identity: resumedIdentity)
    do {
        _ = try await NativeSessionCommandJournal.openForLaunch(
            home: fixture.home, identity: resumedIdentity, legacyProjection: legacy,
            actorID: "native-corrupt-resume", modelID: fakeModel().qualifiedID,
            modelContextMode: .exactColdResume)
        XCTFail("corrupt retained context must refuse native launch")
    } catch let error as NativeColdResumeError {
        guard case .retainedBodyUnavailable = error else {
            return XCTFail("expected retained body refusal, got \(error)")
        }
    }
    try await legacy.closeChecked()

    let workRead = try nativeResumeRead(
        home: fixture.home, journal: fixture.workJournal,
        url: fixture.home.timelineV2WorkJournalURL(fixture.identity.work))
    let failedRunEvents = workRead.records.map(\.event).filter {
        $0.run == RunRef(resumedIdentity.runID)
    }
    XCTAssertEqual(
        failedRunEvents.map(\.type),
        [TimelineEventType.runStarted],
        "pre-effect cold-resume refusal leaves the exact Start reservation retryable")
    XCTAssertFalse(failedRunEvents.contains(where: { $0.command != nil || $0.action != nil }))
}

private func cloneNativeResumeEvent(
    _ event: TimelineEvent, payload: JSONValue
) -> TimelineEvent {
    TimelineEvent(
        eventID: event.eventID, journal: event.journal, sequence: event.sequence,
        hostSequence: event.hostSequence, idempotencyKey: event.idempotencyKey,
        command: event.command, previousEventID: event.previousEventID,
        causedByEventID: event.causedByEventID,
        parentActivityID: event.parentActivityID,
        conversationParent: event.conversationParent,
        session: event.session, work: event.work, workHost: event.workHost,
        client: event.client, sessionAttachment: event.sessionAttachment,
        clientAttachment: event.clientAttachment, run: event.run, turn: event.turn,
        action: event.action, handle: event.handle, actor: event.actor,
        hostRecordedAt: event.hostRecordedAt, clientTimestamp: event.clientTimestamp,
        schemaVersion: event.schemaVersion, payloadVersion: event.payloadVersion,
        type: event.type, declaredDomains: event.declaredDomains,
        provenance: event.provenance, links: event.links, payload: payload)
}
