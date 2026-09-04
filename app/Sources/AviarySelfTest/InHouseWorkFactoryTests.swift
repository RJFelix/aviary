import Foundation

@testable import AviaryCore

private struct FactoryLaunchManifest: InHouseWorkLaunchManifest, Sendable {
    let workRunBinding: WorkRunBinding
}

private final class FactoryRecordingProvider: ChatProvider, @unchecked Sendable {
    let id = "factory-recording"
    private let lock = NSLock()
    private var recordedRequests: [ChatRequest] = []

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("factory response"))
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }

    var requests: [ChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}

private actor FactoryStreamGate {
    private var continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation?
    private var installWaiters: [CheckedContinuation<Void, Never>] = []

    func install(_ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
        self.continuation = continuation
        let waiters = installWaiters
        installWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilInstalled() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waiter in
            installWaiters.append(waiter)
        }
    }

    func release() {
        continuation?.yield(.done(stopReason: "stop"))
        continuation?.finish()
        continuation = nil
    }
}

private struct FactoryBlockingProvider: ChatProvider {
    let id = "factory-blocking"
    let gate: FactoryStreamGate

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await gate.install(continuation) }
        }
    }
}

private func factoryWorkRunBinding(
    home: AgentHome,
    identity: SessionWorkIdentity
) async throws -> WorkRunBinding {
    let host = try home.requirePersistedWorkHost()
    let binding = WorkBinding(
        session: SessionRef(identity.sessionID),
        work: identity.work,
        workHost: host,
        sessionAttachment: SessionAttachmentRef("factory-attachment-\(identity.work.workID)"))
    _ = try await RunJournalBundle.createIdleWork(
        home: home, binding: binding, actorID: "factory-control-\(identity.work.workID)")
    return WorkRunBinding(workBinding: binding, run: RunRef(identity.runID))
}

private func factoryConfiguration(
    home: AgentHome,
    identity: SessionWorkIdentity,
    host: RuntimeHost,
    provider: any ChatProvider,
    assembly: SystemPromptAssembly? = nil,
    binding suppliedBinding: WorkRunBinding? = nil,
    projectionMode: WorkLaunchProjectionMode = .fresh,
    modelContextMode: WorkLaunchContextMode = .launchFresh
) async throws -> InHouseWorkFactory.Configuration {
    let binding: WorkRunBinding
    if let suppliedBinding {
        binding = suppliedBinding
    } else {
        binding = try await factoryWorkRunBinding(home: home, identity: identity)
    }
    return InHouseWorkFactory.Configuration(
        home: home,
        cwd: "/tmp",
        model: fakeModel(),
        provider: provider,
        runtimeHost: host,
        workRunBinding: binding,
        serviceActorID: "factory-work-host",
        systemPrompt: assembly?.flattenedText ?? "You are a factory test agent.",
        systemPromptAssembly: assembly,
        maxIterations: 2,
        projectionMode: projectionMode,
        modelContextMode: modelContextMode)
}

private func factoryCommand(
    _ snapshot: HostedInHouseWorkSnapshot,
    commandID: String,
    command: SessionCommand,
    client: String = "factory-test"
) -> HostedInHouseWorkCommand {
    HostedInHouseWorkCommand(
        work: snapshot.identity.work,
        session: SessionRef(snapshot.identity.sessionID),
        sessionAttachment: snapshot.sessionAttachment,
        client: ClientRef(client),
        commandID: commandID,
        causalCursor: snapshot.latestWorkCursor!,
        command: command)
}

private func factoryWaitForLifecycle(
    _ work: HostedInHouseWork,
    _ expected: HostedInHouseWorkLifecycle,
    attempts: Int = 300
) async -> HostedInHouseWorkSnapshot {
    var snapshot = await work.snapshot()
    for _ in 0..<attempts {
        if snapshot.lifecycle == expected { return snapshot }
        try? await Task.sleep(nanoseconds: 5_000_000)
        snapshot = await work.snapshot()
    }
    return snapshot
}

private func factoryProjectionLines(_ home: AgentHome, sessionID: String) throws -> [JSONValue] {
    let data = try Data(contentsOf: home.sessionFile(id: sessionID))
    return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        .compactMap { JSONValue.parse(Data($0)) }
}

private func factoryNativeWorkLines(_ home: AgentHome, work: WorkRef) throws -> [JSONValue] {
    let data = try Data(contentsOf: home.timelineV2WorkJournalURL(work))
    return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        .compactMap { JSONValue.parse(Data($0)) }
}

/// The Work Host resolver receives a pre-created binding and must thread that exact identity
/// through the factory, journals, runner, and provider request. Prompt source metadata is also
/// retained at the provider crossing rather than flattened away.
func test_inHouseWorkFactoryThreadsManifestIdentityAndPromptMetadata() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "factory-identity-session",
        work: WorkRef(workHostID: hostID, workID: "factory-identity-work"),
        runID: "factory-identity-run")
    let assembly = try SystemPromptAssembly.build(
        cwd: "/tmp", skills: "factory skill block", memory: "factory memory block",
        includeContextFiles: false)
    let provider = FactoryRecordingProvider()
    let configuration = try await factoryConfiguration(
        home: home, identity: identity, host: host, provider: provider, assembly: assembly)
    let manifest = FactoryLaunchManifest(workRunBinding: configuration.workRunBinding)

    let work = try await InHouseWorkFactory.open(launchManifest: manifest) { resolved in
        XCTAssertEqual(resolved.workRunBinding, manifest.workRunBinding)
        return configuration
    }
    let prepared = await work.snapshot()
    XCTAssertEqual(prepared.identity, identity)
    XCTAssertEqual(prepared.sessionAttachment, manifest.workRunBinding.workBinding.sessionAttachment)
    XCTAssertEqual(prepared.lifecycle, .prepared)
    XCTAssertEqual(prepared.runtimeState, .notStarted)
    XCTAssertEqual(prepared.journalHealth, .healthy)

    let start = try await work.submit(factoryCommand(
        prepared, commandID: "factory-start", command: .start(prompt: "run factory")))
    XCTAssertTrue(start.wasAdmitted)
    let settled = await factoryWaitForLifecycle(work, .idle)
    XCTAssertEqual(settled.identity, identity)
    XCTAssertEqual(settled.sessionAttachment, manifest.workRunBinding.workBinding.sessionAttachment)
    XCTAssertTrue(settled.agentAvailable)
    XCTAssertEqual(settled.runtimeState, .connected)
    let request = try XCTUnwrap(provider.requests.first)
    XCTAssertEqual(request.messages.first, ChatMessage.system(assembly.flattenedText))
    XCTAssertEqual(assembly.sources.first?.kind, .workingDirectory)
    XCTAssertTrue(assembly.sources.contains { $0.kind == .skill })
    XCTAssertTrue(assembly.sources.contains { $0.kind == .memory })
    let sessionText = String(
        decoding: try Data(contentsOf: home.timelineV2SessionJournalURL(SessionRef(identity.sessionID))),
        as: UTF8.self)
    XCTAssertTrue(sessionText.contains(TimelineEventType.contextSourcesObserved))
    XCTAssertTrue(sessionText.contains(assembly.digest))

    let end = try await work.submit(factoryCommand(
        settled, commandID: "factory-end", command: .endRun))
    XCTAssertTrue(end.receipt.isDelivered)
    let ended = await work.snapshot()
    XCTAssertEqual(ended.lifecycle, .ended)
    XCTAssertEqual(ended.runtimeState, .stopped)
    XCTAssertEqual(ended.journalHealth, .closed)
    XCTAssertFalse(ended.agentAvailable)
}

/// The injected window stands in for a process dying after the disposable writer exists but
/// before canonical admission. The final AgentHome projection stays absent, so the same verified
/// WorkRunBinding can be retried without manufacturing another Work, Session, or Run.
func test_inHouseWorkFactoryFreshProjectionStagingIsRetryable() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "factory-staging-session",
        work: WorkRef(workHostID: hostID, workID: "factory-staging-work"),
        runID: "factory-staging-run")
    let provider = FactoryRecordingProvider()
    var configuration = try await factoryConfiguration(
        home: home, identity: identity, host: host, provider: provider)
    let projectionURL = home.sessionFile(id: identity.sessionID)
    configuration.failureStage =
        .afterFreshProjectionBeforeCanonicalAdmission

    do {
        _ = try await InHouseWorkFactory.open(configuration: configuration)
        XCTFail("the injected staging failure must reject before canonical admission")
    } catch let error as HostedInHouseWorkError {
        guard case .invalidConfiguration(let detail) = error else {
            XCTFail("unexpected staging failure: \(error)")
            return
        }
        XCTAssertTrue(detail.contains("staging"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: projectionURL.path))

    // A header-only projection is the exact disposable shape this factory can safely reclaim
    // from a prior interrupted admission. A real transcript is still rejected by validation.
    let staleProjection = try SessionWriter(
        home: home, cwd: configuration.cwd, model: nil, identity: identity)
    try await staleProjection.closeChecked()
    XCTAssertTrue(FileManager.default.fileExists(atPath: projectionURL.path))

    configuration.failureStage = nil
    let work = try await InHouseWorkFactory.open(configuration: configuration)
    let prepared = await work.snapshot()
    XCTAssertEqual(prepared.identity, identity)
    XCTAssertEqual(prepared.lifecycle, .prepared)
    XCTAssertEqual(prepared.journalHealth, .healthy)
    let end = try await work.submit(factoryCommand(
        prepared, commandID: "factory-staging-end", command: .endRun))
    XCTAssertTrue(end.receipt.isDelivered)
    XCTAssertEqual((await work.snapshot()).lifecycle, .ended)
}

/// Canonical admission and flat publication are separate crash windows. Both retries must reuse
/// the one untouched native marker and the one complete flat boundary; publication never gets to
/// delete a complete file and rewrite it in place.
func test_inHouseWorkFactoryPublicationWindowsAreRetryable() async throws {
    guard let host = try makeHost(.reference) else { return }
    for (offset, stage) in [
        InHouseWorkFactory.Configuration.FailureStage
            .afterCanonicalAdmissionBeforeFreshProjectionPublication,
        .afterFreshProjectionPublicationBeforeBridgeInstallation,
    ].enumerated() {
        let home = scratchHome()
        let hostID = try home.requirePersistedWorkHostID()
        let identity = SessionWorkIdentity(
            sessionID: "factory-publication-session-\(offset)",
            work: WorkRef(workHostID: hostID, workID: "factory-publication-work-\(offset)"),
            runID: "factory-publication-run-\(offset)")
        var configuration = try await factoryConfiguration(
            home: home, identity: identity, host: host, provider: FactoryRecordingProvider())
        configuration.failureStage = stage

        do {
            _ = try await InHouseWorkFactory.open(configuration: configuration)
            XCTFail("injected publication failure must reject")
        } catch let error as HostedInHouseWorkError {
            guard case .invalidConfiguration = error else {
                XCTFail("unexpected publication error: \(error)")
                continue
            }
        }

        configuration.failureStage = nil
        let retry = try await InHouseWorkFactory.open(configuration: configuration)
        let prepared = await retry.snapshot()
        XCTAssertEqual(prepared.identity, identity)
        let ended = try await retry.submit(factoryCommand(
            prepared, commandID: "factory-publication-end-\(offset)", command: .endRun))
        XCTAssertTrue(ended.receipt.isDelivered)

        let projection = try factoryProjectionLines(home, sessionID: identity.sessionID)
        XCTAssertEqual(
            projection.filter { $0["type"]?.stringValue == "model_change" }.count, 1,
            "retry must not append a second initial model boundary")
        let work = try factoryNativeWorkLines(home, work: identity.work)
        XCTAssertEqual(
            work.filter { $0["type"]?.stringValue == TimelineEventType.runStarted }.count, 1,
            "retry must not append a second canonical run marker")
    }
}

/// Replacement Runs retain the stable Session/Work/WorkHost header while their exact run tail is
/// detected independently. This exercises the historical-prefix path for both Run2 and Run3.
func test_inHouseWorkFactoryReplacementRunsReuseHistoricalProjection() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    // Exact cold resume is source-aware: seed the predecessor with the same producer-side
    // assembly metadata that every production launch now carries. A flattened prompt without
    // source identities is intentionally not a resumable compatibility path.
    let assembly = try SystemPromptAssembly.build(
        cwd: "/tmp", skills: "", memory: "", includeContextFiles: false)
    let hostID = try home.requirePersistedWorkHostID()
    let work = WorkRef(workHostID: hostID, workID: "factory-replacement-work")
    let sessionID = "factory-replacement-session"
    let binding1 = try await factoryWorkRunBinding(
        home: home,
        identity: SessionWorkIdentity(sessionID: sessionID, work: work, runID: "factory-run-1"))

    let firstIdentity = SessionWorkIdentity(
        sessionID: sessionID, work: work, runID: "factory-run-1")
    let firstConfiguration = try await factoryConfiguration(
        home: home, identity: firstIdentity, host: host, provider: FactoryRecordingProvider(),
        assembly: assembly, binding: binding1)
    let first = try await InHouseWorkFactory.open(configuration: firstConfiguration)
    let firstPrepared = await first.snapshot()
    _ = try await first.submit(factoryCommand(
        firstPrepared, commandID: "factory-replacement-start-1",
        command: .start(prompt: "seed replacement context")))
    let firstIdle = await factoryWaitForLifecycle(first, .idle)
    let firstEnd = try await first.submit(factoryCommand(
        firstIdle, commandID: "factory-replacement-end-1", command: .endRun))
    XCTAssertTrue(firstEnd.receipt.isDelivered)

    let binding2 = WorkRunBinding(workBinding: binding1.workBinding, run: RunRef("factory-run-2"))
    let secondIdentity = SessionWorkIdentity(
        sessionID: sessionID, work: work, runID: "factory-run-2")
    let secondConfiguration = try await factoryConfiguration(
        home: home, identity: secondIdentity, host: host, provider: FactoryRecordingProvider(),
        assembly: assembly, binding: binding2, projectionMode: .reopenHistorical,
        modelContextMode: .exactColdResume)
    let second = try await InHouseWorkFactory.open(configuration: secondConfiguration)
    let secondPrepared = await second.snapshot()
    XCTAssertEqual(secondPrepared.identity, secondIdentity)
    let secondEnd = try await second.submit(factoryCommand(
        secondPrepared, commandID: "factory-replacement-end-2", command: .endRun))
    XCTAssertTrue(secondEnd.receipt.isDelivered)

    let binding3 = WorkRunBinding(workBinding: binding1.workBinding, run: RunRef("factory-run-3"))
    let thirdIdentity = SessionWorkIdentity(
        sessionID: sessionID, work: work, runID: "factory-run-3")
    let thirdConfiguration = try await factoryConfiguration(
        home: home, identity: thirdIdentity, host: host, provider: FactoryRecordingProvider(),
        assembly: assembly, binding: binding3, projectionMode: .reopenHistorical,
        modelContextMode: .exactColdResume)
    let third = try await InHouseWorkFactory.open(configuration: thirdConfiguration)
    let thirdPrepared = await third.snapshot()
    XCTAssertEqual(thirdPrepared.identity, thirdIdentity)
    let thirdEnd = try await third.submit(factoryCommand(
        thirdPrepared, commandID: "factory-replacement-end-3", command: .endRun))
    XCTAssertTrue(thirdEnd.receipt.isDelivered)

    let projection = try factoryProjectionLines(home, sessionID: sessionID)
    let starts = projection.compactMap { line -> String? in
        guard line["type"]?.stringValue == "run_start" else { return nil }
        return line["runId"]?.stringValue
    }
    XCTAssertEqual(starts, ["factory-run-2", "factory-run-3"])
    XCTAssertEqual(
        projection.filter { $0["type"]?.stringValue == "model_change" }.count, 3,
        "each of the three Runs gets exactly one model boundary")
}

/// SessionWriter's boundary dictionaries are not ordered JSON.  An interrupted append can leave
/// a prefix beginning with any field, and the next replacement must quarantine that fragment
/// (with one newline) before appending exactly one valid boundary.  Exercise both boundary kinds
/// through the production factory path, after canonical Run admission has taken its locks.
func test_inHouseWorkFactoryRepairsUnterminatedBoundaryPrefixes() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let work = WorkRef(workHostID: hostID, workID: "factory-partial-work")
    let sessionID = "factory-partial-session"
    let identity1 = SessionWorkIdentity(sessionID: sessionID, work: work, runID: "factory-partial-1")
    let binding1 = try await factoryWorkRunBinding(home: home, identity: identity1)
    let first = try await InHouseWorkFactory.open(configuration: try await factoryConfiguration(
        home: home, identity: identity1, host: host, provider: FactoryRecordingProvider(),
        binding: binding1))
    let firstPrepared = await first.snapshot()
    _ = try await first.submit(factoryCommand(
        firstPrepared, commandID: "factory-partial-start-1", command: .start(prompt: "seed")))
    let firstIdle = await factoryWaitForLifecycle(first, .idle)
    _ = try await first.submit(factoryCommand(
        firstIdle, commandID: "factory-partial-end-1", command: .endRun))

    let projectionURL = home.sessionFile(id: sessionID)
    let handle = try FileHandle(forWritingTo: projectionURL)
    try handle.seekToEnd()
    // Deliberately begin with runId rather than type; this is one valid Dictionary encoding order.
    try handle.write(contentsOf: Data(
        "{\"runId\":\"interrupted-run\",\"workHostId\":\"\(hostID)\",".utf8))
    try handle.close()

    let identity2 = SessionWorkIdentity(sessionID: sessionID, work: work, runID: "factory-partial-2")
    let binding2 = WorkRunBinding(workBinding: binding1.workBinding, run: RunRef(identity2.runID))
    let second = try await InHouseWorkFactory.open(configuration: try await factoryConfiguration(
        home: home, identity: identity2, host: host, provider: FactoryRecordingProvider(),
        binding: binding2, projectionMode: .reopenHistorical,
        modelContextMode: .launchFresh))
    _ = try await second.submit(factoryCommand(
        await second.snapshot(), commandID: "factory-partial-end-2", command: .endRun))

    let afterRunStart = try factoryProjectionLines(home, sessionID: sessionID)
    XCTAssertEqual(
        afterRunStart.filter { $0["runId"]?.stringValue == identity2.runID }.count, 1)

    let secondHandle = try FileHandle(forWritingTo: projectionURL)
    try secondHandle.seekToEnd()
    // A model_change prefix may begin with modelId. It must be treated the same way.
    try secondHandle.write(contentsOf: Data("{\"modelId\":\"interrupted-model\",".utf8))
    try secondHandle.close()

    let identity3 = SessionWorkIdentity(sessionID: sessionID, work: work, runID: "factory-partial-3")
    let binding3 = WorkRunBinding(workBinding: binding1.workBinding, run: RunRef(identity3.runID))
    let third = try await InHouseWorkFactory.open(configuration: try await factoryConfiguration(
        home: home, identity: identity3, host: host, provider: FactoryRecordingProvider(),
        binding: binding3, projectionMode: .reopenHistorical,
        modelContextMode: .launchFresh))
    _ = try await third.submit(factoryCommand(
        await third.snapshot(), commandID: "factory-partial-end-3", command: .endRun))

    let finalProjection = try factoryProjectionLines(home, sessionID: sessionID)
    XCTAssertEqual(
        finalProjection.filter { $0["runId"]?.stringValue == identity3.runID }.count, 1)
    XCTAssertEqual(
        finalProjection.filter { $0["type"]?.stringValue == "model_change" }.count, 3,
        "the interrupted model boundary is quarantined, then exactly one valid replacement boundary is appended")
}

/// A file with a foreign stable header, no header, or a malformed tail is not evidence that this
/// factory may append. Identity validation happens before canonical Run admission.
func test_inHouseWorkFactoryRejectsForeignHeaderlessAndMalformedProjection() async throws {
    guard let host = try makeHost(.reference) else { return }
    for disposition in ["foreign", "headerless", "malformed"] {
        let home = scratchHome()
        let hostID = try home.requirePersistedWorkHostID()
        let identity = SessionWorkIdentity(
            sessionID: "factory-invalid-projection-\(disposition)",
            work: WorkRef(workHostID: hostID, workID: "factory-invalid-work-\(disposition)"),
            runID: "factory-invalid-run-\(disposition)")
        let configuration = try await factoryConfiguration(
            home: home, identity: identity, host: host, provider: FactoryRecordingProvider())
        let projectionURL = home.sessionFile(id: identity.sessionID)
        try FileManager.default.createDirectory(
            at: projectionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if disposition == "foreign" {
            let foreign = SessionWorkIdentity(
                sessionID: identity.sessionID,
                work: WorkRef(workHostID: hostID, workID: "foreign-work"),
                runID: "foreign-run")
            let writer = try SessionWriter(
                home: home, cwd: configuration.cwd, model: configuration.model, identity: foreign)
            try await writer.closeChecked()
        } else if disposition == "headerless" {
            try Data("not-json\n".utf8).write(to: projectionURL)
        } else {
            let writer = try SessionWriter(
                home: home, cwd: configuration.cwd, model: configuration.model, identity: identity)
            try await writer.closeChecked()
            let handle = try FileHandle(forWritingTo: projectionURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{malformed\n".utf8))
            try handle.close()
        }

        do {
            _ = try await InHouseWorkFactory.open(configuration: configuration)
            XCTFail("\(disposition) projection must fail closed")
        } catch let error as HostedInHouseWorkError {
            guard case .invalidConfiguration = error else {
                XCTFail("unexpected \(disposition) error: \(error)")
                continue
            }
        }
        let work = try factoryNativeWorkLines(home, work: identity.work)
        XCTAssertFalse(work.contains { $0["type"]?.stringValue == TimelineEventType.runStarted })
    }
}

/// Reopening an existing projection is also identity-fenced.  A stable Aviary header that names
/// another Work must not be treated as merely historical, because SessionWriter's filename-based
/// resume would otherwise append the requested Run to a foreign transcript.
func test_inHouseWorkFactoryRejectsForeignHistoricalProjection() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let target = SessionWorkIdentity(
        sessionID: "factory-foreign-historical-session",
        work: WorkRef(workHostID: hostID, workID: "factory-foreign-target-work"),
        runID: "factory-foreign-target-run")
    let configuration = try await factoryConfiguration(
        home: home, identity: target, host: host, provider: FactoryRecordingProvider(),
        projectionMode: .reopenHistorical, modelContextMode: .launchFresh)
    let foreign = SessionWorkIdentity(
        sessionID: target.sessionID,
        work: WorkRef(workHostID: hostID, workID: "factory-foreign-source-work"),
        runID: "factory-foreign-source-run")
    let writer = try SessionWriter(
        home: home, cwd: configuration.cwd, model: configuration.model, identity: foreign)
    try await writer.closeChecked()

    do {
        _ = try await InHouseWorkFactory.open(configuration: configuration)
        XCTFail("a historical projection for another Work must fail closed")
    } catch let error as HostedInHouseWorkError {
        guard case .invalidConfiguration = error else {
            XCTFail("unexpected foreign historical projection error: \(error)")
            return
        }
    }
    let binding = configuration.workRunBinding
    let work = try factoryNativeWorkLines(home, work: binding.workBinding.work)
    XCTAssertFalse(work.contains { $0["type"]?.stringValue == TimelineEventType.runStarted })
}

/// Cancellation is an explicit Agent-loop request. The test provider stays suspended until
/// released, proving End waits for quiescence and then tears down the owned runtime and writers.
func test_inHouseWorkFactoryCancellationAndTeardown() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "factory-cancel-session",
        work: WorkRef(workHostID: hostID, workID: "factory-cancel-work"),
        runID: "factory-cancel-run")
    let gate = FactoryStreamGate()
    let configuration = try await factoryConfiguration(
        home: home, identity: identity, host: host, provider: FactoryBlockingProvider(gate: gate))
    let work = try await InHouseWorkFactory.open(configuration: configuration)
    let prepared = await work.snapshot()
    _ = try await work.submit(factoryCommand(
        prepared, commandID: "factory-cancel-start", command: .start(prompt: "block")))
    await gate.waitUntilInstalled()
    let running = await factoryWaitForLifecycle(work, .running)
    XCTAssertEqual(running.lifecycle, .running)
    XCTAssertEqual(running.runtimeState, .connected)

    let cancel = try await work.submit(factoryCommand(
        running, commandID: "factory-cancel", command: .cancel(scope: .agentLoop)))
    XCTAssertTrue(cancel.receipt.isDelivered)
    XCTAssertEqual(cancel.lifecycle, .canceling)
    await gate.release()
    let idle = await factoryWaitForLifecycle(work, .idle)
    XCTAssertEqual(idle.lifecycle, .idle)
    XCTAssertTrue(idle.agentAvailable)

    let end = try await work.submit(factoryCommand(
        idle, commandID: "factory-cancel-end", command: .endRun))
    XCTAssertTrue(end.receipt.isDelivered)
    let ended = await work.snapshot()
    XCTAssertEqual(ended.lifecycle, .ended)
    XCTAssertEqual(ended.runtimeState, .stopped)
    XCTAssertEqual(ended.journalHealth, .closed)
    XCTAssertFalse(ended.agentAvailable)
}

/// Hosted execution is owned by the Work actor, not by an ephemeral observer. Removing its only
/// subscription leaves the runtime and Agent usable until an explicit End command.
func test_inHouseWorkFactoryObserverLossDoesNotEndExecution() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "factory-observer-session",
        work: WorkRef(workHostID: hostID, workID: "factory-observer-work"),
        runID: "factory-observer-run")
    let configuration = try await factoryConfiguration(
        home: home, identity: identity, host: host, provider: FactoryRecordingProvider())
    let work = try await InHouseWorkFactory.open(configuration: configuration)
    let subscription = await work.subscribe(client: ClientRef("factory-observer"))
    XCTAssertTrue(subscription.accepted)
    await work.unsubscribe(subscription.id)
    let observerCount = await work.observerCount
    XCTAssertEqual(observerCount, 0)

    let prepared = await work.snapshot()
    _ = try await work.submit(factoryCommand(
        prepared, commandID: "factory-observer-start", command: .start(prompt: "")))
    let idle = await factoryWaitForLifecycle(work, .idle)
    XCTAssertEqual(idle.lifecycle, .idle)
    XCTAssertEqual(idle.runtimeState, .connected)
    XCTAssertEqual(idle.ephemeralObserverCount, 0)
    XCTAssertTrue(idle.agentAvailable)

    let end = try await work.submit(factoryCommand(
        idle, commandID: "factory-observer-end", command: .endRun))
    XCTAssertTrue(end.receipt.isDelivered)
    let ended = await work.snapshot()
    XCTAssertEqual(ended.lifecycle, .ended)
    XCTAssertEqual(ended.runtimeState, .stopped)
}

let casesInHouseWorkFactory: [Case] = [
    ("inHouseWorkFactoryThreadsManifestIdentityAndPromptMetadata", {
        try await test_inHouseWorkFactoryThreadsManifestIdentityAndPromptMetadata()
    }),
    ("inHouseWorkFactoryFreshProjectionStagingIsRetryable", {
        try await test_inHouseWorkFactoryFreshProjectionStagingIsRetryable()
    }),
    ("inHouseWorkFactoryPublicationWindowsAreRetryable", {
        try await test_inHouseWorkFactoryPublicationWindowsAreRetryable()
    }),
    ("inHouseWorkFactoryReplacementRunsReuseHistoricalProjection", {
        try await test_inHouseWorkFactoryReplacementRunsReuseHistoricalProjection()
    }),
    ("inHouseWorkFactoryRepairsUnterminatedBoundaryPrefixes", {
        try await test_inHouseWorkFactoryRepairsUnterminatedBoundaryPrefixes()
    }),
    ("inHouseWorkFactoryRejectsForeignHeaderlessAndMalformedProjection", {
        try await test_inHouseWorkFactoryRejectsForeignHeaderlessAndMalformedProjection()
    }),
    ("inHouseWorkFactoryRejectsForeignHistoricalProjection", {
        try await test_inHouseWorkFactoryRejectsForeignHistoricalProjection()
    }),
    ("inHouseWorkFactoryCancellationAndTeardown", {
        try await test_inHouseWorkFactoryCancellationAndTeardown()
    }),
    ("inHouseWorkFactoryObserverLossDoesNotEndExecution", {
        try await test_inHouseWorkFactoryObserverLossDoesNotEndExecution()
    }),
]
