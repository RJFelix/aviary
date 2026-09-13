import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import AviaryCore

private enum WorkAgentChildDaemonJourneyFailure: Error {
    case missingProduct
    case missingFixture
    case daemonDidNotStart
    case stage(String)
    case terminalMismatch(
        fixtureRoot: String, state: String, outcome: String, pending: Bool,
        started: Int, settled: Int, tokenFloor: Int, unresolved: Int,
        semanticValid: Bool, eventCount: Int, omissionCount: Int)
    case terminalTimeout(
        fixtureRoot: String, daemonRunning: Bool, snapshotReadFailures: Int,
        state: String, outcome: String, pending: Bool, started: Int, settled: Int,
        tokenFloor: Int, unresolved: Int, semanticValid: Bool,
        eventCount: Int, omissionCount: Int)
}

private struct WorkAgentChildDaemonJourneyFixture {
    let root: URL
    let home: AgentHome
    let workspace: URL
    let socketRoot: URL
    let readyFile: URL
    let releaseFile: URL
    let daemonLog: URL

    init() throws {
        let nonce = UUID().uuidString.lowercased().prefix(12)
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "avcj-\(nonce)", directoryHint: .isDirectory)
        home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
        workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        socketRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "avcs-\(nonce)", directoryHint: .isDirectory)
        readyFile = root.appending(path: "provider-ready.json", directoryHint: .notDirectory)
        releaseFile = root.appending(path: "release-child", directoryHint: .notDirectory)
        daemonLog = root.appending(path: "daemon.log", directoryHint: .notDirectory)
        for directory in [root, home.root, workspace, socketRoot] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: directory != root,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        }
    }
}

@discardableResult
private func workAgentChildJourneyTerminate(
    _ process: Process, gracefulTimeout: TimeInterval = 3
) -> Bool {
    guard process.isRunning else {
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
    process.terminate()
    let deadline = Date().addingTimeInterval(max(0, gracefulTimeout))
    while process.isRunning && Date() < deadline { usleep(20_000) }
    guard process.isRunning else {
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
    _ = kill(process.processIdentifier, SIGKILL)
    let killDeadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < killDeadline { usleep(20_000) }
    return false
}

private func workAgentChildJourneyRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func workAgentChildJourneyWait<Value>(
    stage: String,
    timeout: TimeInterval,
    overallDeadline: Date,
    poll: () async throws -> Value?
) async throws -> Value {
    let deadline = min(Date().addingTimeInterval(timeout), overallDeadline)
    while Date() < deadline {
        if let value = try await poll() { return value }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    throw WorkAgentChildDaemonJourneyFailure.stage(stage)
}

private func workAgentChildJourneySnapshot(
    client: WorkServiceUnixSocketClient,
    create: WorkServiceCreateWorkResponse,
    attachment: WorkServiceClientAttachment,
    clientRef: ClientRef
) async throws -> WorkServiceSnapshot {
    try await client.snapshot(WorkServiceSnapshotRequest(
        work: create.work.work,
        journal: create.work.journal,
        attachment: attachment.attachment,
        client: clientRef,
        target: .work(journal: create.work.journal),
        limit: WorkServiceBounds.maxEventsPerPage,
        maxBytes: WorkServiceBounds.maxEventPageBytes))
}

func testNormalAviarydWorkOwnedChildSurvivesParentEndAndRefusesShutdown() async throws {
    let testExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
    let daemonExecutable = testExecutable.deletingLastPathComponent().appending(path: "aviaryd")
    guard FileManager.default.isExecutableFile(atPath: daemonExecutable.path) else {
        throw WorkAgentChildDaemonJourneyFailure.missingProduct
    }
    let repositoryRoot = workAgentChildJourneyRepositoryRoot()
    let providerScript = repositoryRoot.appending(path: "app/Fixtures/agent-child-openai.py")
    guard FileManager.default.isReadableFile(atPath: providerScript.path) else {
        throw WorkAgentChildDaemonJourneyFailure.missingFixture
    }
    let fixture = try WorkAgentChildDaemonJourneyFixture()
    let overallDeadline = Date().addingTimeInterval(90)
    var journeyCompleted = false
    defer {
        if journeyCompleted {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: fixture.socketRoot)
        } else {
            print("retained generated child journey fixture: \(fixture.root.path)")
            print("retained generated child journey socket root: \(fixture.socketRoot.path)")
        }
    }

    let provider = Process()
    provider.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    provider.arguments = [
        "python3", providerScript.path, fixture.readyFile.path, fixture.releaseFile.path,
    ]
    provider.standardInput = FileHandle.nullDevice
    provider.standardOutput = FileHandle.nullDevice
    provider.standardError = FileHandle.nullDevice
    try provider.run()
    defer { _ = workAgentChildJourneyTerminate(provider, gracefulTimeout: 1) }

    let port: Int = try await workAgentChildJourneyWait(
        stage: "provider readiness", timeout: 8, overallDeadline: overallDeadline
    ) { () async throws -> Int? in
        guard provider.isRunning,
              let data = try? Data(contentsOf: fixture.readyFile),
              data.count <= 4_096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = (object["port"] as? NSNumber)?.intValue,
              (1...65_535).contains(port) else { return nil }
        return port
    }

    let models: [String: Any] = [
        "providers": [
            "child-daemon-local": [
                "name": "Bounded child daemon loopback",
                "baseUrl": "http://127.0.0.1:\(port)/v1",
                "api": "openai-completions",
                "apiKey": "child-daemon-key",
                "models": [[
                    "id": "child-daemon-model",
                    "contextWindow": 100_000,
                    "maxTokens": 2_048,
                    "cost": ["input": 0.000001, "output": 0.000002],
                ]],
            ],
        ],
    ]
    let modelsData = try JSONSerialization.data(withJSONObject: models, options: [.sortedKeys])
    try modelsData.write(to: fixture.home.modelsFile, options: [.atomic])
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: fixture.home.modelsFile.path)
    let host = try fixture.home.requirePersistedWorkHost()

    let daemon = Process()
    daemon.executableURL = daemonExecutable
    daemon.arguments = [
        "--agent-home", fixture.home.root.path,
        "--socket-root", fixture.socketRoot.path,
        "--instance-id", "normal-child-instance",
        "--start-identity", "normal-child-start",
        "--workspace", fixture.workspace.path,
    ]
    daemon.standardInput = FileHandle.nullDevice
    daemon.standardOutput = FileHandle.nullDevice
    XCTAssertTrue(FileManager.default.createFile(atPath: fixture.daemonLog.path, contents: Data()))
    let daemonLogHandle = try FileHandle(forWritingTo: fixture.daemonLog)
    daemon.standardError = daemonLogHandle
    var daemonEnvironment = ProcessInfo.processInfo.environment
    daemonEnvironment["HOME"] = fixture.home.root.path
    daemonEnvironment["ZDOTDIR"] = fixture.root.path
    daemon.environment = daemonEnvironment
    try daemon.run()
    defer {
        _ = workAgentChildJourneyTerminate(daemon)
        try? daemonLogHandle.close()
    }

    let layout = WorkHostDaemonEndpointLayout(
        home: fixture.home, workHost: host, socketRoot: fixture.socketRoot)
    let published: WorkHostDaemonDescriptor = try await workAgentChildJourneyWait(
        stage: "normal daemon readiness", timeout: 15, overallDeadline: overallDeadline
    ) { () async throws -> WorkHostDaemonDescriptor? in
        guard daemon.isRunning else {
            throw WorkAgentChildDaemonJourneyFailure.daemonDidNotStart
        }
        return try WorkHostDaemonEndpointPublisher.discover(layout: layout)
    }

    let clientARef = ClientRef("normal-child-client-a")
    let clientA = WorkServiceUnixSocketClient(
        endpoint: published.endpoint, client: clientARef, expectedHost: host)
    let handshakeA = try await clientA.connect(build: "normal-child-journey")
    let workspaceID = try XCTUnwrap(handshakeA.workspaceCatalog.defaultWorkspace?.workspaceID)
    let capabilities = Set(WorkServiceCapability.allCases)
    let create = try await clientA.createWork(WorkServiceCreateWorkRequest(
        client: clientARef,
        commandID: "normal-child-create",
        causalControlCursor: handshakeA.controlCursor,
        configuration: WorkServiceWorkConfiguration(
            providerID: "child-daemon-local",
            modelID: "child-daemon-model",
            workspaceID: workspaceID),
        requestedCapabilities: capabilities))
    let start = try await clientA.command(WorkServiceCommandRequest(
        work: create.work.work,
        journal: create.work.journal,
        attachment: create.attachment.attachment,
        commandID: "normal-child-start",
        client: clientARef,
        sessionAttachment: create.sessionAttachment,
        causalWorkCursor: create.workCursor,
        kind: .start,
        value: "launch one normal daemon child"))
    XCTAssertEqual(start.state, .accepted)

    let runningA: (WorkServiceSnapshot, WorkAgentHandleSnapshot) =
        try await workAgentChildJourneyWait(
            stage: "Work-owned child running", timeout: 30,
            overallDeadline: overallDeadline
        ) { () async throws -> (WorkServiceSnapshot, WorkAgentHandleSnapshot)? in
            let snapshot = try await workAgentChildJourneySnapshot(
                client: clientA, create: create, attachment: create.attachment,
                clientRef: clientARef)
            guard snapshot.omissions.isEmpty else { return nil }
            let work = WorkReducer.reduce(snapshot.events)
            guard work.semanticProjectionValid,
                  work.activeTurn == nil,
                  work.activeActionIDs.isEmpty,
                  work.agentHandles.count == 1,
                  let handle = work.agentHandles.values.first,
                  handle.state == .running,
                  handle.providerAccounting.pending != nil,
                  handle.providerAccounting.usage.started == 1,
                  handle.providerAccounting.usage.settled == 0 else { return nil }
            return (snapshot, handle)
        }
    let handleRef = runningA.1.handle
    let parentRun = try XCTUnwrap(WorkReducer.reduce(runningA.0.events).activeRun)
    XCTAssertNil(runningA.1.deadline)

    // EOF is not a lifecycle command. Client B uses a separately authorized attachment and
    // remains able to observe and end the parent while the child owns its independent runtime.
    await clientA.close()
    XCTAssertTrue(daemon.isRunning)
    let clientBRef = ClientRef("normal-child-client-b")
    let clientB = WorkServiceUnixSocketClient(
        endpoint: published.endpoint, client: clientBRef, expectedHost: host)
    let handshakeB = try await clientB.connect(build: "normal-child-journey")
    let attach = try await clientB.attach(WorkServiceAttachRequest(
        work: create.work.work,
        journal: create.work.journal,
        client: clientBRef,
        session: create.session,
        sessionJournal: create.sessionJournal,
        sessionAttachment: create.sessionAttachment,
        commandID: "normal-child-attach-b",
        causalControlCursor: handshakeB.controlCursor,
        requestedCapabilities: capabilities))
    let attachmentB = try XCTUnwrap(attach.attachment)
    XCTAssertEqual(attach.state, .accepted)
    let observedByB = try await workAgentChildJourneySnapshot(
        client: clientB, create: create, attachment: attachmentB, clientRef: clientBRef)
    let observedWork = WorkReducer.reduce(observedByB.events)
    XCTAssertEqual(observedWork.agentHandles[handleRef.handleID]?.state, .running)
    XCTAssertEqual(
        observedWork.agentHandles[handleRef.handleID]?.providerAccounting.usage.started, 1)

    let endCursor = try XCTUnwrap(observedByB.servedCursor)
    let end = try await clientB.command(WorkServiceCommandRequest(
        work: create.work.work,
        journal: create.work.journal,
        attachment: attachmentB.attachment,
        commandID: "normal-child-end-parent",
        client: clientBRef,
        sessionAttachment: attachmentB.sessionAttachment,
        causalWorkCursor: endCursor,
        kind: .end))
    XCTAssertEqual(end.state, .accepted)
    _ = try await workAgentChildJourneyWait(
        stage: "parent ended without child cancellation", timeout: 15,
        overallDeadline: overallDeadline
    ) { () async throws -> WorkServiceSnapshot? in
        let snapshot = try await workAgentChildJourneySnapshot(
            client: clientB, create: create, attachment: attachmentB, clientRef: clientBRef)
        let work = WorkReducer.reduce(snapshot.events)
        guard snapshot.work.currentRun == nil,
              work.agentHandles[handleRef.handleID]?.state == .running else { return nil }
        return snapshot
    }

    // An ordinary supervisor stop must be refused while this process still owns the child.
    daemon.terminate()
    _ = try await workAgentChildJourneyWait(
        stage: "shutdown refusal receipt", timeout: 5,
        overallDeadline: overallDeadline
    ) { () async throws -> Bool? in
        guard daemon.isRunning else {
            throw WorkAgentChildDaemonJourneyFailure.stage(
                "daemon exited while its Work-owned child was running")
        }
        guard let data = try? Data(contentsOf: fixture.daemonLog),
              data.count <= 16 * 1_024,
              String(data: data, encoding: .utf8)?.contains("aviaryd shutdown refused:") == true
        else { return nil }
        return true
    }
    let serviceAfterRefusal: WorkServiceSnapshot = try await workAgentChildJourneyWait(
        stage: "shutdown refusal", timeout: 5, overallDeadline: overallDeadline
    ) { () async throws -> WorkServiceSnapshot? in
        guard daemon.isRunning else {
            throw WorkAgentChildDaemonJourneyFailure.stage(
                "daemon exited while its Work-owned child was running")
        }
        return try? await workAgentChildJourneySnapshot(
            client: clientB, create: create, attachment: attachmentB, clientRef: clientBRef)
    }
    XCTAssertEqual(
        WorkReducer.reduce(serviceAfterRefusal.events)
            .agentHandles[handleRef.handleID]?.state,
        .running)

    XCTAssertTrue(FileManager.default.createFile(
        atPath: fixture.releaseFile.path, contents: Data()))
    let terminalDeadline = min(Date().addingTimeInterval(30), overallDeadline)
    var terminal: WorkSnapshot?
    var terminalSnapshotReadFailures = 0
    var lastTerminalWork: WorkSnapshot?
    var lastTerminalEventCount = 0
    var lastTerminalOmissionCount = 0
    while terminal == nil && Date() < terminalDeadline {
        guard daemon.isRunning else {
            throw WorkAgentChildDaemonJourneyFailure.stage(
                "daemon exited before child terminal accounting")
        }
        let snapshot: WorkServiceSnapshot
        do {
            snapshot = try await workAgentChildJourneySnapshot(
                client: clientB, create: create, attachment: attachmentB, clientRef: clientBRef)
        } catch {
            terminalSnapshotReadFailures += 1
            try await Task.sleep(nanoseconds: 25_000_000)
            continue
        }
        lastTerminalEventCount = snapshot.events.count
        lastTerminalOmissionCount = snapshot.omissions.count
        let work = WorkReducer.reduce(snapshot.events)
        lastTerminalWork = work
        if snapshot.omissions.isEmpty,
           let handle = work.agentHandles[handleRef.handleID],
           handle.state == .terminal {
            guard handle.terminalOutcome == .succeeded,
                  !handle.blocksWorkCompletion,
                  handle.providerAccounting.pending == nil,
                  handle.providerAccounting.usage.started == 1,
                  handle.providerAccounting.usage.settled == 1,
                  handle.providerAccounting.usage.knownTokenFloor == 38 else {
                throw WorkAgentChildDaemonJourneyFailure.terminalMismatch(
                    fixtureRoot: fixture.root.path, state: handle.state.rawValue,
                    outcome: handle.terminalOutcome?.rawValue ?? "none",
                    pending: handle.providerAccounting.pending != nil,
                    started: handle.providerAccounting.usage.started,
                    settled: handle.providerAccounting.usage.settled,
                    tokenFloor: handle.providerAccounting.usage.knownTokenFloor,
                    unresolved: handle.providerAccounting.usage.unresolvedTotal,
                    semanticValid: work.semanticProjectionValid,
                    eventCount: snapshot.events.count,
                    omissionCount: snapshot.omissions.count)
            }
            terminal = work
            break
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    guard let terminal else {
        let handle = lastTerminalWork?.agentHandles[handleRef.handleID]
        throw WorkAgentChildDaemonJourneyFailure.terminalTimeout(
            fixtureRoot: fixture.root.path, daemonRunning: daemon.isRunning,
            snapshotReadFailures: terminalSnapshotReadFailures,
            state: handle?.state.rawValue ?? "missing",
            outcome: handle?.terminalOutcome?.rawValue ?? "none",
            pending: handle?.providerAccounting.pending != nil,
            started: handle?.providerAccounting.usage.started ?? -1,
            settled: handle?.providerAccounting.usage.settled ?? -1,
            tokenFloor: handle?.providerAccounting.usage.knownTokenFloor ?? -1,
            unresolved: handle?.providerAccounting.usage.unresolvedTotal ?? -1,
            semanticValid: lastTerminalWork?.semanticProjectionValid ?? false,
            eventCount: lastTerminalEventCount,
            omissionCount: lastTerminalOmissionCount)
    }
    let terminalHandle = try XCTUnwrap(terminal.agentHandles[handleRef.handleID])
    XCTAssertEqual(terminalHandle.origin.run, parentRun)
    XCTAssertEqual(terminalHandle.providerAccounting.usage.unresolvedTotal, 0)
    XCTAssertEqual(terminal.activeRun, nil)

    let terminalEvents = try await workAgentChildJourneySnapshot(
        client: clientB, create: create, attachment: attachmentB, clientRef: clientBRef).events
    XCTAssertEqual(terminalEvents.filter {
        $0.type == TimelineEventType.agentHandleProviderStarted && $0.handle == handleRef
    }.count, 1)
    XCTAssertEqual(terminalEvents.filter {
        $0.type == TimelineEventType.agentHandleProviderSettled && $0.handle == handleRef
    }.count, 1)
    XCTAssertEqual(terminalEvents.filter {
        $0.type == TimelineEventType.agentHandleTerminal && $0.handle == handleRef
    }.count, 1)
    XCTAssertEqual(terminalEvents.filter {
        $0.type == TimelineEventType.agentHandleCancelRequested && $0.handle == handleRef
    }.count, 0)

    let statsURL = URL(string: "http://127.0.0.1:\(port)/stats")!
    var statsRequest = URLRequest(url: statsURL)
    statsRequest.timeoutInterval = 3
    let (statsData, statsResponse) = try await URLSession.shared.data(for: statsRequest)
    XCTAssertEqual((statsResponse as? HTTPURLResponse)?.statusCode, 200)
    let stats = try JSONSerialization.jsonObject(with: statsData) as? [String: Any]
    let calls = stats?["calls"] as? [[String: Any]] ?? []
    XCTAssertEqual(calls.count, 3)
    XCTAssertEqual(Set(calls.compactMap { $0["kind"] as? String }),
                   Set(["parent_spawn", "parent_finish", "child"]))
    XCTAssertTrue(calls.allSatisfy { ($0["authorized"] as? Bool) == true })

    await clientB.close()
    let graceful = workAgentChildJourneyTerminate(daemon, gracefulTimeout: 10)
    XCTAssertTrue(graceful, "normal daemon must stop after parent End and child settlement")
    XCTAssertFalse(daemon.isRunning)
    let removed: Bool = try await workAgentChildJourneyWait(
        stage: "endpoint cleanup", timeout: 3, overallDeadline: overallDeadline
    ) { () async throws -> Bool? in
        try WorkHostDaemonEndpointPublisher.discover(layout: layout) == nil ? true : nil
    }
    XCTAssertTrue(removed)
    journeyCompleted = true
}

let casesWorkAgentChildDaemonJourney: [Case] = [
    ("phase5 production child: normal daemon survives End and refuses stop", {
        try await testNormalAviarydWorkOwnedChildSurvivesParentEndAndRefusesShutdown()
    }),
]
