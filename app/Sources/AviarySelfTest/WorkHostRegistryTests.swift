import Foundation

@testable import AviaryCore

private struct RegistryImmediateProvider: ChatProvider {
    let id = "registry-immediate"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("registry"))
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private final class RegistryWeakWorkBox: @unchecked Sendable {
    weak var value: HostedInHouseWork?

    init(_ value: HostedInHouseWork) {
        self.value = value
    }
}

private func registryOpenWork(
    home: AgentHome,
    hostID: String,
    workID: String,
    runtimeHost: RuntimeHost
) async throws -> HostedInHouseWork {
    let identity = SessionWorkIdentity(
        sessionID: "registry-session-\(workID)",
        work: WorkRef(workHostID: hostID, workID: workID),
        runID: "registry-run-\(workID)")
    let persistedHost = try home.requirePersistedWorkHost()
    let binding = WorkBinding(
        session: SessionRef(identity.sessionID),
        work: identity.work,
        workHost: persistedHost,
        sessionAttachment: SessionAttachmentRef("registry-attachment-\(workID)"))
    _ = try await RunJournalBundle.createIdleWork(
        home: home, binding: binding, actorID: "registry-control-\(workID)")
    let configuration = HostedInHouseWorkConfiguration(
        home: home,
        cwd: "/private/raw/path/must-not-cross-registry-boundary",
        model: fakeModel(),
        provider: RegistryImmediateProvider(),
        runtimeHost: runtimeHost,
        workRunBinding: WorkRunBinding(workBinding: binding, run: RunRef(identity.runID)),
        serviceActorID: "registry-service",
        actorKind: "registry-test-work",
        systemPrompt: "Registry test agent.",
        maxIterations: 1)
    return try await HostedInHouseWork.open(configuration: configuration)
}

private func registryEndWork(
    _ work: HostedInHouseWork,
    commandID: String
) async throws -> HostedInHouseWorkSnapshot {
    let before = await work.snapshot()
    let command = HostedInHouseWorkCommand(
        work: before.identity.work,
        session: SessionRef(before.identity.sessionID),
        sessionAttachment: before.sessionAttachment,
        client: ClientRef("registry-end-client"),
        commandID: commandID,
        causalCursor: try XCTUnwrap(before.latestWorkCursor),
        command: .endRun)
    let receipt = try await work.submit(command)
    XCTAssertTrue(receipt.wasAdmitted)
    XCTAssertTrue(receipt.receipt.isDelivered)
    let ended = await registryWaitForLifecycle(work, .ended)
    XCTAssertEqual(ended.lifecycle, .ended)
    XCTAssertEqual(ended.journalHealth, .closed)
    return ended
}

private func registryWaitForLifecycle(
    _ work: HostedInHouseWork,
    _ expected: HostedInHouseWorkLifecycle,
    attempts: Int = 200
) async -> HostedInHouseWorkSnapshot {
    var snapshot = await work.snapshot()
    for _ in 0..<attempts {
        if snapshot.lifecycle == expected { return snapshot }
        try? await Task.sleep(nanoseconds: 5_000_000)
        snapshot = await work.snapshot()
    }
    return snapshot
}

private func registryCommitProof(
    _ work: HostedInHouseWork,
    operation: WorkServiceTerminalOperation = .complete,
    commandID: String,
    detail: String? = "registry terminal test"
) async throws -> WorkServiceTerminalCommitProof {
    let snapshot = await work.snapshot()
    let causal = try XCTUnwrap(snapshot.latestWorkCursor)
    let session = SessionRef(snapshot.identity.sessionID)
    let client = ClientRef("registry-terminal-client")
    let sessionJournal = JournalRef.session(
        session, authority: TimelineAuthorityRef(snapshot.identity.work.workHostID))
    let command = CommandRef(
        commandID: commandID,
        client: client,
        sessionAttachment: snapshot.sessionAttachment,
        causalCursor: causal)
    let request = WorkServiceTerminalCommitRequest(
        operation: operation,
        work: snapshot.identity.work,
        journal: JournalRef.work(snapshot.identity.work),
        client: client,
        session: session,
        sessionJournal: sessionJournal,
        sessionAttachment: snapshot.sessionAttachment,
        causalWorkCursor: causal,
        detail: detail,
        command: command)
    return try await work.commit(request)
}

private func assertRegistryReleaseWithTerminalDetail(
    operation: WorkServiceTerminalOperation, detail: String?, index: Int
) async throws {
    guard let runtimeHost = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let work = try await registryOpenWork(
        home: home, hostID: hostID,
        workID: "detail-\(operation.rawValue)-\(index)", runtimeHost: runtimeHost)
    let registry = WorkHostRegistry(host: WorkHostRef(hostID))
    _ = try await registry.register(work)
    _ = try await registryEndWork(
        work, commandID: "detail-\(operation.rawValue)-end-\(index)")
    let proof = try await registryCommitProof(
        work,
        operation: operation,
        commandID: "detail-\(operation.rawValue)-terminal-\(index)",
        detail: detail)
    let receipt = try await registry.release(work.identity.work, terminalProof: proof)
    XCTAssertTrue(receipt.released)
    XCTAssertEqual(receipt.terminalOperation, operation)
    guard case .historical(let history) = await registry.lookup(work.identity.work) else {
        XCTFail("terminal Work with \(operation.rawValue) detail was not retained")
        return
    }
    XCTAssertEqual(history.disposition, .historical)
}

private func registryProofShape(
    _ snapshot: HostedInHouseWorkSnapshot,
    operation: WorkServiceTerminalOperation = .complete,
    commandID: String = "registry-shaped-proof",
    pairingVerified: Bool = true
) throws -> WorkServiceTerminalCommitProof {
    let causal = try XCTUnwrap(snapshot.latestWorkCursor)
    let journal = JournalRef.work(snapshot.identity.work)
    let resultEventID = "registry-shaped-terminal-\(commandID)"
    let resulting = JournalCursor(
        journal: journal, eventID: resultEventID, sequence: causal.sequence + 1)
    let session = SessionRef(snapshot.identity.sessionID)
    let client = ClientRef("registry-terminal-client")
    let sessionJournal = JournalRef.session(
        session, authority: TimelineAuthorityRef(snapshot.identity.work.workHostID))
    let command = CommandRef(
        commandID: commandID,
        client: client,
        sessionAttachment: snapshot.sessionAttachment,
        causalCursor: causal)
    let eventKind = operation == .complete
        ? TimelineEventType.workCompleted : TimelineEventType.workDestroyed
    return WorkServiceTerminalCommitProof(
        operation: operation,
        work: snapshot.identity.work,
        journal: journal,
        command: command,
        causalWorkCursor: causal,
        resultingWorkCursor: resulting,
        terminalEvent: TimelineEvent(
            eventID: resultEventID,
            journal: journal,
            sequence: resulting.sequence,
            command: command,
            causedByEventID: causal.eventID.map {
                EventRef(journal: journal, eventID: $0)
            },
            session: session,
            work: snapshot.identity.work,
            workHost: WorkHostRef(snapshot.identity.work.workHostID),
            client: client,
            sessionAttachment: snapshot.sessionAttachment,
            actor: TimelineActor(actorID: "registry-terminal"),
            hostRecordedAt: Date(),
            type: eventKind,
            declaredDomains: [.work],
            provenance: .native),
        session: session,
        sessionJournal: sessionJournal,
        sessionAttachment: snapshot.sessionAttachment,
        pairedSessionCursor: pairingVerified
            ? JournalCursor(
                journal: sessionJournal, eventID: "registry-shaped-session", sequence: 1)
            : nil,
        sessionPairingVerified: pairingVerified,
        outstandingHandleIDs: [],
        commitID: "registry-shaped-commit-\(commandID)")
}

private func registryCanonicalFact(
    work: WorkRef,
    disposition: WorkHostRegistryCanonicalDisposition,
    hostInstance: WorkHostInstanceRef? = nil,
    metadata: WorkHostLaunchMetadata? = nil,
    sourceID: String = "registry-history"
) -> WorkHostRegistryCanonicalFact {
    WorkHostRegistryCanonicalFact(
        work: work,
        disposition: disposition,
        sourceID: sourceID,
        hostInstance: hostInstance,
        launchMetadata: metadata,
        recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

private func registryAssertError(
    _ expected: WorkHostRegistryError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("expected \(expected), but operation succeeded")
    } catch let error as WorkHostRegistryError {
        XCTAssertEqual(error, expected)
    } catch {
        XCTFail("expected \(expected), got unexpected error \(error)")
    }
}

private func registryWaitForDeallocation(
    _ box: RegistryWeakWorkBox,
    attempts: Int = 200
) async -> Bool {
    for _ in 0..<attempts {
        if box.value == nil { return true }
        await Task.yield()
    }
    return box.value == nil
}

func test_workHostRegistryOwnsFullWorkRefsAndStableInstanceIdentity() async throws {
    guard let firstHost = try makeHost(.reference),
          let secondHost = try makeHost(.reference) else { return }
    let firstHome = scratchHome()
    let hostID = try firstHome.requirePersistedWorkHostID()
    let first = try await registryOpenWork(
        home: firstHome, hostID: hostID, workID: "z-work", runtimeHost: firstHost)
    let second = try await registryOpenWork(
        home: firstHome, hostID: hostID, workID: "a-work", runtimeHost: secondHost)
    let registryHost = WorkHostRef(hostID)
    let registry = WorkHostRegistry(
        host: registryHost, instanceID: "instance-stable", startIdentity: "start-stable")

    let metadata = WorkHostLaunchMetadata(
        providerID: "registry-provider",
        modelID: "registry-model",
        workspaceID: try WorkHostWorkspaceID(
            "workspace-00000000-0000-0000-0000-000000000001"),
        runtimeHostKind: "reference",
        actorKind: "registry-test-work")
    _ = try await registry.register(first, launchMetadata: metadata)
    _ = try await registry.register(second)

    XCTAssertEqual(await registry.hostInstance, WorkHostInstanceRef(
        host: registryHost, instanceID: "instance-stable", startIdentity: "start-stable"))
    XCTAssertEqual(await registry.liveCount, 2)
    XCTAssertEqual(await registry.canonicalCount, 0)
    let lookup = await registry.lookup(first.identity.work)
    guard case .live(let firstEntry) = lookup else {
        XCTFail("expected a live registration")
        return
    }
    XCTAssertEqual(firstEntry.launchMetadata.workspaceID, metadata.workspaceID)
    XCTAssertNil(firstEntry.launchMetadata.providerID.flatMap { $0.contains("/private") ? $0 : nil })
    XCTAssertFalse(
        String(describing: firstEntry.launchMetadata)
            .contains("/private/raw/path/must-not-cross-registry-boundary"))

    let page = try await registry.list(limit: 2)
    XCTAssertEqual(page.entries.map(\.work.workID), ["a-work", "z-work"])
    XCTAssertNil(page.nextPageToken)

    let endedFirst = try await registryEndWork(first, commandID: "registry-end-z")
    let firstProof = try await registryCommitProof(
        first, operation: .complete, commandID: "registry-complete-z")
    let firstReceipt = try await registry.release(
        first.identity.work, terminalProof: firstProof)
    XCTAssertEqual(firstReceipt.terminalOperation, .complete)
    XCTAssertTrue(firstReceipt.released)
    XCTAssertEqual(endedFirst.lifecycle, firstReceipt.terminalLifecycle)
    XCTAssertEqual(await registry.liveCount, 1)
    XCTAssertEqual(await registry.canonicalCount, 1)
    guard case .historical(let firstHistory) = await registry.lookup(first.identity.work) else {
        XCTFail("released Work was not retained as canonical history")
        return
    }
    XCTAssertEqual(firstHistory.work, first.identity.work)
    XCTAssertEqual(firstHistory.hostInstance, firstReceipt.hostInstance)
    XCTAssertEqual(firstHistory.disposition, .historical)
    XCTAssertTrue(firstHistory.sourceID.hasPrefix("terminal-event:"))
    XCTAssertFalse((await registry.lookup(first.identity.work))?.isLiveRegistration ?? true)

    _ = try await registryEndWork(second, commandID: "registry-end-a")
    let secondProof = try await registryCommitProof(
        second, operation: .destroy, commandID: "registry-destroy-a")
    let secondReceipt = try await registry.release(
        second.identity.work, terminalProof: secondProof)
    XCTAssertEqual(secondReceipt.terminalOperation, .destroy)
    XCTAssertEqual(await registry.liveCount, 0)
    XCTAssertEqual(await registry.canonicalCount, 2)
    let releasedPage = try await registry.list(limit: 2)
    XCTAssertEqual(releasedPage.entries.map(\.kind), [.historical, .historical])
}

func test_workHostRegistryRejectsDuplicateAndDivergentIdentity() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let work = try await registryOpenWork(
        home: home, hostID: hostID, workID: "identity-work", runtimeHost: host)
    let registry = WorkHostRegistry(host: WorkHostRef(hostID))
    let workRef = work.identity.work
    let divergent = WorkRef(workHostID: hostID, workID: "other-work")

    await registryAssertError(.divergentRegistration(expected: workRef, actual: divergent)) {
        _ = try await registry.register(work, key: divergent)
    }
    XCTAssertEqual(await registry.count, 0)

    _ = try await registry.register(work)
    await registryAssertError(.duplicateRegistration(workRef)) {
        _ = try await registry.register(work)
    }
    let registryInstance = await registry.hostInstance
    let fact = registryCanonicalFact(
        work: workRef, disposition: .historical, hostInstance: registryInstance)
    await registryAssertError(.registrationConflict(workRef)) {
        try await registry.registerCanonical(fact)
    }
    XCTAssertEqual(await registry.liveCount, 1)

    _ = try await registryEndWork(work, commandID: "registry-identity-end")
    let proof = try await registryCommitProof(
        work, commandID: "registry-identity-complete")
    _ = try await registry.release(workRef, terminalProof: proof)
}

func test_workHostRegistrySeparatesCanonicalFactsFromLiveLiveness() async throws {
    let host = WorkHostRef("canonical-registry-host")
    let registry = WorkHostRegistry(
        host: host, instanceID: "current-instance", startIdentity: "current-start")
    let oldInstance = WorkHostInstanceRef(
        host: host, instanceID: "old-instance", startIdentity: "old-start")
    let facts = [
        registryCanonicalFact(
            work: WorkRef(workHostID: host.workHostID, workID: "historical"),
            disposition: .historical, hostInstance: oldInstance),
        registryCanonicalFact(
            work: WorkRef(workHostID: host.workHostID, workID: "recovering"),
            disposition: .recovering, hostInstance: oldInstance),
        registryCanonicalFact(
            work: WorkRef(workHostID: host.workHostID, workID: "unavailable"),
            disposition: .unavailable, hostInstance: oldInstance),
    ]
    for fact in facts {
        try await registry.registerCanonical(fact)
    }
    XCTAssertEqual(await registry.liveCount, 0)
    XCTAssertEqual(await registry.canonicalCount, 3)

    for fact in facts {
        guard let result = await registry.lookup(fact.work) else {
            XCTFail("missing canonical fact")
            continue
        }
        XCTAssertFalse(result.isLiveRegistration)
        XCTAssertEqual(result.kind.rawValue, fact.disposition.rawValue)
    }
    let validShape = try registryProofShape(
        HostedInHouseWorkSnapshot(
            identity: SessionWorkIdentity(
                sessionID: "canonical-session", work: facts[0].work, runID: "canonical-run"),
            sessionAttachment: SessionAttachmentRef("canonical-attachment"),
            lifecycle: .ended,
            runtimeState: .stopped,
            journalHealth: .closed,
            runtimeIdentity: nil,
            adoptionDescriptor: nil,
            adoptionEvidence: nil,
            agentAvailable: false,
            ephemeralObserverCount: 0,
            runtimeTransportConnected: false,
            ownedRuntimeProcessKnownAlive: false,
            runtimeCapabilitiesSummary: nil,
            latestSessionCursor: nil,
            latestWorkCursor: JournalCursor(
                journal: JournalRef.work(facts[0].work), eventID: "causal", sequence: 1),
            recoveryCoverage: RecoveryCoverage(),
            lastFailure: nil))
    await registryAssertError(.notLive(facts[0].work)) {
        _ = try await registry.release(facts[0].work, terminalProof: validShape)
    }
    await registryAssertError(.duplicateRegistration(facts[0].work)) {
        try await registry.registerCanonical(facts[0])
    }
    let divergent = registryCanonicalFact(
        work: facts[0].work, disposition: .recovering, hostInstance: oldInstance)
    await registryAssertError(.divergentCanonicalFact(facts[0].work)) {
        try await registry.registerCanonical(divergent)
    }
}

func test_workHostRegistryIgnoresClientDisconnects() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let work = try await registryOpenWork(
        home: home, hostID: hostID, workID: "observer-work", runtimeHost: host)
    let registry = WorkHostRegistry(host: WorkHostRef(hostID))
    _ = try await registry.register(work)

    let first = await work.subscribe(client: ClientRef("registry-gui-one"))
    let second = await work.subscribe(client: ClientRef("registry-gui-two"))
    XCTAssertTrue(first.accepted)
    XCTAssertTrue(second.accepted)
    XCTAssertEqual(await work.observerCount, 2)
    await work.unsubscribe(first.id)
    XCTAssertEqual(await work.observerCount, 1)
    XCTAssertEqual(await registry.liveCount, 1)
    guard case .live(let live) = await registry.lookup(work.identity.work) else {
        XCTFail("client disconnect removed live Work")
        return
    }
    XCTAssertEqual(ObjectIdentifier(live.hostedWork), ObjectIdentifier(work))
    await work.unsubscribe(second.id)
    XCTAssertEqual(await work.observerCount, 0)
    XCTAssertEqual(await registry.liveCount, 1)

    _ = try await registryEndWork(work, commandID: "registry-observer-end")
    let proof = try await registryCommitProof(
        work, commandID: "registry-observer-complete")
    _ = try await registry.release(work.identity.work, terminalProof: proof)
}

func test_workHostRegistryRequiresCanonicalProofAndSerializesReleaseRace() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let work = try await registryOpenWork(
        home: home, hostID: hostID, workID: "race-work", runtimeHost: host)
    let registry = WorkHostRegistry(host: WorkHostRef(hostID))
    _ = try await registry.register(work)

    let prepared = await work.snapshot()
    let shapedBeforeEnd = try registryProofShape(prepared)
    await registryAssertError(
        .notTerminalized(work.identity.work, lifecycle: .prepared)
    ) {
        _ = try await registry.release(
            work.identity.work, terminalProof: shapedBeforeEnd)
    }

    let startSnapshot = await work.snapshot()
    let startCommand = HostedInHouseWorkCommand(
        work: startSnapshot.identity.work,
        session: SessionRef(startSnapshot.identity.sessionID),
        sessionAttachment: startSnapshot.sessionAttachment,
        client: ClientRef("registry-start-client"),
        commandID: "registry-race-start",
        causalCursor: try XCTUnwrap(startSnapshot.latestWorkCursor),
        command: .start(prompt: "seed replacement context"))
    let started = try await work.submit(startCommand)
    XCTAssertTrue(started.wasAdmitted)
    let idle = await registryWaitForLifecycle(work, .idle, attempts: 2_000)
    XCTAssertEqual(idle.lifecycle, .idle)

    let ended = try await registryEndWork(work, commandID: "registry-race-end")
    let shapedWithoutPair = try registryProofShape(ended, pairingVerified: false)
    await registryAssertError(.invalidTerminalProof(work.identity.work)) {
        _ = try await registry.release(
            work.identity.work, terminalProof: shapedWithoutPair)
    }
    XCTAssertEqual(await registry.liveCount, 1)

    // An ended Run leaves its Work reusable. Rotate the actor against a different canonical
    // Session/attachment, changing both ownership and Run generation while keeping the logical
    // Work slot live.
    let oldActorID = ObjectIdentifier(work)
    let replacementHost = try XCTUnwrap(makeHost(.reference))
    let replacementBinding = WorkBinding(
        session: SessionRef("registry-race-replacement-session"),
        work: ended.identity.work,
        workHost: try home.requirePersistedWorkHost(),
        sessionAttachment: SessionAttachmentRef("registry-race-replacement-attachment"))
    let replacementCausalCursor = try XCTUnwrap(ended.latestWorkCursor)
    let replacementSessionJournal = JournalRef.session(
        replacementBinding.session,
        authority: TimelineAuthorityRef(replacementBinding.workHost.workHostID))
    let replacementClient = ClientRef("registry-replacement-client")
    let replacementCommand = CommandRef(
        commandID: "registry-race-publish-replacement-session",
        client: replacementClient,
        sessionAttachment: replacementBinding.sessionAttachment,
        causalCursor: replacementCausalCursor)
    let replacementPublication = try await RunJournalBundle.publishSessionAttachment(
        home: home,
        request: RunJournalBundleSessionPublicationRequest(
            work: replacementBinding.work,
            workHost: replacementBinding.workHost,
            workJournal: replacementCausalCursor.journal,
            session: replacementBinding.session,
            sessionJournal: replacementSessionJournal,
            sessionAttachment: replacementBinding.sessionAttachment,
            client: replacementClient,
            command: replacementCommand,
            capabilities: ["observe", "control", "start", "end"],
            causalWorkCursor: replacementCausalCursor),
        actorID: "registry-replacement-session-publisher")
    XCTAssertEqual(replacementPublication.session, replacementBinding.session)
    XCTAssertEqual(
        replacementPublication.sessionAttachment,
        replacementBinding.sessionAttachment)
    let replacementConfiguration = HostedInHouseWorkConfiguration(
        home: home,
        cwd: "/tmp",
        model: fakeModel(),
        provider: RegistryImmediateProvider(),
        runtimeHost: replacementHost,
        workRunBinding: WorkRunBinding(
            workBinding: replacementBinding, run: RunRef("registry-race-replacement-run")),
        serviceActorID: "registry-replacement-service",
        actorKind: "registry-test-replacement",
        systemPrompt: "Registry replacement agent.",
        maxIterations: 1,
        projectionMode: .fresh,
        modelContextMode: .launchFresh)
    let replacementEntry = try await registry.replace(
        work.identity.work, configuration: replacementConfiguration)
    let activeWork = replacementEntry.hostedWork
    XCTAssertNotEqual(ObjectIdentifier(activeWork), oldActorID)
    XCTAssertEqual(activeWork.identity.work, work.identity.work)
    XCTAssertEqual(activeWork.identity.sessionID, replacementBinding.session.sessionID)
    XCTAssertEqual(activeWork.sessionAttachment, replacementBinding.sessionAttachment)
    XCTAssertEqual(activeWork.identity.runID, "registry-race-replacement-run")
    XCTAssertEqual(await registry.liveCount, 1)

    _ = try await registryEndWork(activeWork, commandID: "registry-race-replacement-end")
    let proof = try await registryCommitProof(
        activeWork, commandID: "registry-race-replacement-complete")
    let forged = WorkServiceTerminalCommitProof(
        operation: proof.operation,
        work: proof.work,
        journal: proof.journal,
        command: proof.command,
        causalWorkCursor: proof.causalWorkCursor,
        resultingWorkCursor: proof.resultingWorkCursor,
        terminalEvent: proof.terminalEvent,
        session: proof.session,
        sessionJournal: proof.sessionJournal,
        sessionAttachment: proof.sessionAttachment,
        pairedSessionCursor: proof.pairedSessionCursor,
        sessionPairingVerified: proof.sessionPairingVerified,
        outstandingHandleIDs: proof.outstandingHandleIDs,
        commitID: proof.commitID + "-forged")
    await registryAssertError(.invalidTerminalProof(work.identity.work)) {
        _ = try await registry.release(
            work.identity.work, terminalProof: forged)
    }
    XCTAssertEqual(await registry.liveCount, 1)

    let outcomes = await withTaskGroup(
        of: Result<WorkHostRegistryReleaseReceipt, WorkHostRegistryError>.self,
        returning: [Result<WorkHostRegistryReleaseReceipt, WorkHostRegistryError>].self
    ) { group in
        for _ in 0..<16 {
            group.addTask {
                do {
                    return .success(try await registry.release(
                        activeWork.identity.work, terminalProof: proof))
                } catch let error as WorkHostRegistryError {
                    return .failure(error)
                } catch {
                    return .failure(.invalidTerminalProof(activeWork.identity.work))
                }
            }
        }
        var results: [Result<WorkHostRegistryReleaseReceipt, WorkHostRegistryError>] = []
        for await result in group { results.append(result) }
        return results
    }
    XCTAssertEqual(outcomes.filter {
        if case .success = $0 { return true }
        return false
    }.count, 1)
    XCTAssertEqual(outcomes.filter {
        guard case .failure(let error) = $0 else { return false }
        switch error {
        case .notLive(let failedWork), .workNotFound(let failedWork):
            return failedWork == activeWork.identity.work
        default:
            return false
        }
    }.count, 15)
    XCTAssertEqual(await registry.liveCount, 0)
    XCTAssertEqual(await registry.canonicalCount, 1)
    guard case .historical = await registry.lookup(activeWork.identity.work) else {
        XCTFail("released Work was not discoverable in canonical history")
        return
    }

    let terminalDetails: [String?] = [
        nil,
        "",
        " \t",
        String(repeating: "é", count: 2_000), // exactly 4,000 UTF-8 bytes
    ]
    for operation in [WorkServiceTerminalOperation.complete, .destroy] {
        for (index, detail) in terminalDetails.enumerated() {
            try await assertRegistryReleaseWithTerminalDetail(
                operation: operation, detail: detail, index: index)
        }
    }
}

func test_workHostRegistryBoundsMetadataIdentityCapacityAndPaging() async throws {
    let bounds = WorkHostRegistryBounds(
        maxEntries: 3,
        maxLiveEntries: 1,
        maxCanonicalEntries: 2,
        maxPageSize: 1,
        maxIdentityBytes: 64,
        maxMetadataBytes: 4)
    XCTAssertEqual(
        WorkHostRegistryBounds(maxEntries: Int.max, maxPageSize: Int.max).maxEntries, 4_096)
    let host = WorkHostRef("bounded-registry-host")
    let registry = WorkHostRegistry(host: host, bounds: bounds)
    let metadata = WorkHostLaunchMetadata(
        providerID: "ééé",
        modelID: "model-long",
        workspaceID: try WorkHostWorkspaceID(
            "workspace-00000000-0000-0000-0000-000000000002"),
        runtimeHostKind: "reference",
        actorKind: "registry")
    let first = WorkRef(workHostID: host.workHostID, workID: "first")
    let second = WorkRef(workHostID: host.workHostID, workID: "second")
    try await registry.registerCanonical(registryCanonicalFact(
        work: first, disposition: .historical, metadata: metadata))
    try await registry.registerCanonical(registryCanonicalFact(
        work: second, disposition: .recovering, metadata: metadata))

    guard case .historical(let firstFact) = await registry.lookup(first) else {
        XCTFail("missing bounded canonical fact")
        return
    }
    XCTAssertEqual(firstFact.launchMetadata?.providerID, "éé")
    XCTAssertEqual(firstFact.launchMetadata?.modelID, "mode")
    XCTAssertTrue(firstFact.launchMetadata?.metadataWasTruncated == true)
    XCTAssertFalse(firstFact.launchMetadata?.providerID?.contains("/private") ?? false)

    await registryAssertError(.canonicalCapacityExceeded) {
        try await registry.registerCanonical(registryCanonicalFact(
            work: WorkRef(workHostID: host.workHostID, workID: "third"),
            disposition: .unavailable))
    }
    let page = try await registry.list(limit: 1)
    XCTAssertEqual(page.entries.count, 1)
    XCTAssertNotNil(page.nextPageToken)
    let finalPage = try await registry.list(limit: 1, pageToken: page.nextPageToken)
    XCTAssertEqual(finalPage.entries.count, 1)
    XCTAssertNil(finalPage.nextPageToken)
    await registryAssertError(.invalidPageSize(requested: 2, maximum: 1)) {
        _ = try await registry.list(limit: 2)
    }
    await registryAssertError(.invalidPageToken) {
        _ = try await registry.list(limit: 1, pageToken: "not-a-registry-token")
    }
    let totalCapacityRegistry = WorkHostRegistry(
        host: host,
        bounds: WorkHostRegistryBounds(
            maxEntries: 1, maxLiveEntries: 1, maxCanonicalEntries: 2,
            maxPageSize: 1, maxIdentityBytes: 64, maxMetadataBytes: 4))
    try await totalCapacityRegistry.registerCanonical(registryCanonicalFact(
        work: WorkRef(workHostID: host.workHostID, workID: "total-first"),
        disposition: .historical))
    await registryAssertError(.capacityExceeded) {
        try await totalCapacityRegistry.registerCanonical(registryCanonicalFact(
            work: WorkRef(workHostID: host.workHostID, workID: "total-second"),
            disposition: .historical))
    }

    guard let runtimeHost = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let liveRegistry = WorkHostRegistry(host: WorkHostRef(hostID), bounds: bounds)
    let liveWork = try await registryOpenWork(
        home: home, hostID: hostID, workID: "live-bound", runtimeHost: runtimeHost)
    let liveMetadata = try await liveRegistry.register(
        liveWork, launchMetadata: metadata)
    XCTAssertEqual(liveMetadata.launchMetadata.providerID, "éé")
    XCTAssertEqual(liveMetadata.launchMetadata.modelID, "mode")
    XCTAssertTrue(liveMetadata.launchMetadata.metadataWasTruncated)

    // Fill the canonical category after the live slot has already been admitted. Releasing the
    // ended live Work is a one-for-one conversion and must still succeed at this bound.
    try await liveRegistry.registerCanonical(registryCanonicalFact(
        work: WorkRef(workHostID: hostID, workID: "canonical-fill-one"),
        disposition: .historical))
    try await liveRegistry.registerCanonical(registryCanonicalFact(
        work: WorkRef(workHostID: hostID, workID: "canonical-fill-two"),
        disposition: .recovering))
    XCTAssertEqual(await liveRegistry.canonicalCount, 2)

    let secondLive = try await registryOpenWork(
        home: home, hostID: hostID, workID: "second-live-bound",
        runtimeHost: try XCTUnwrap(makeHost(.reference)))
    await registryAssertError(.liveCapacityExceeded) {
        _ = try await liveRegistry.register(secondLive)
    }
    _ = try await registryEndWork(secondLive, commandID: "registry-second-live-bound-end")
    _ = try await registryCommitProof(
        secondLive, commandID: "registry-second-live-bound-complete")
    _ = try await registryEndWork(liveWork, commandID: "registry-live-bound-end")
    let liveProof = try await registryCommitProof(
        liveWork, commandID: "registry-live-bound-complete")
    _ = try await liveRegistry.release(liveWork.identity.work, terminalProof: liveProof)
    XCTAssertEqual(await liveRegistry.canonicalCount, 3)
    let overlongID = String(repeating: "é", count: 33)
    let overlongWork = try await registryOpenWork(
        home: home, hostID: hostID, workID: overlongID,
        runtimeHost: try XCTUnwrap(makeHost(.reference)))
    await registryAssertError(.invalidIdentity("Work identity")) {
        _ = try await liveRegistry.register(overlongWork)
    }
    _ = try await registryEndWork(overlongWork, commandID: "registry-overlong-end")
    _ = try await registryCommitProof(
        overlongWork, commandID: "registry-overlong-complete")
}

func test_workHostRegistrySerializesConcurrentDuplicateRegistration() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let work = try await registryOpenWork(
        home: home, hostID: hostID, workID: "concurrent-work", runtimeHost: host)
    let registry = WorkHostRegistry(host: WorkHostRef(hostID))
    let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for _ in 0..<32 {
            group.addTask {
                do {
                    _ = try await registry.register(work)
                    return true
                } catch {
                    return false
                }
            }
        }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results
    }
    XCTAssertEqual(outcomes.filter { $0 }.count, 1)
    XCTAssertEqual(await registry.liveCount, 1)

    _ = try await registryEndWork(work, commandID: "registry-concurrent-end")
    let proof = try await registryCommitProof(
        work, commandID: "registry-concurrent-complete")
    _ = try await registry.release(work.identity.work, terminalProof: proof)
}

func test_workHostRegistryStrongOwnershipEndsAtExplicitRelease() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    var work: HostedInHouseWork? = try await registryOpenWork(
        home: home, hostID: hostID, workID: "owned-work", runtimeHost: host)
    let box = RegistryWeakWorkBox(work!)
    let registry = WorkHostRegistry(host: WorkHostRef(hostID))
    var entry: WorkHostRegistryLiveEntry? = try await registry.register(work!)
    let workRef = work!.identity.work
    XCTAssertEqual(ObjectIdentifier(entry!.hostedWork), ObjectIdentifier(work!))
    XCTAssertNotNil(box.value)

    var lookup: WorkHostRegistryLookup? = await registry.lookup(workRef)
    var retained: HostedInHouseWork?
    if case .live(let live) = lookup {
        retained = live.hostedWork
    } else {
        XCTFail("registry did not retain live actor")
        return
    }
    lookup = nil
    entry = nil
    work = nil
    XCTAssertNotNil(box.value)
    guard retained != nil else {
        XCTFail("failed to retain actor for terminalization")
        return
    }
    _ = try await registryEndWork(retained!, commandID: "registry-owned-end")
    let proof = try await registryCommitProof(
        retained!, operation: .destroy, commandID: "registry-owned-destroy")
    _ = try await registry.release(workRef, terminalProof: proof)
    guard case .historical = await registry.lookup(workRef) else {
        XCTFail("released Work was not retained as canonical history")
        return
    }
    withExtendedLifetime(retained!) {}
    XCTAssertNotNil(box.value)
    retained = nil
    XCTAssertTrue(await registryWaitForDeallocation(box))
}
