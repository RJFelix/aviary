import Foundation

@testable import AviaryCore

let casesHostedWorkAgentChildPilot: [Case] = [
    ("phase5 Hosted pilot: opt-in configuration", {
        try await testHostedWorkAgentChildPilotDefaultsToNilAndRoundTrips()
    }),
    ("phase5 Hosted pilot: canonical writer route", {
        try await testInHouseWorkFactoryPilotRegistersRunRoute()
    }),
]

private struct HostedPilotImmediateProvider: ChatProvider {
    let id = "hosted-pilot-test"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private func hostedPilotRuntimeRoot() -> URL? {
    guard let root = EngineLocator.repoRoot(),
          FileManager.default.fileExists(
              atPath: root.appending(path: "runtime-hosts/python3/host.py").path)
    else { return nil }
    return root
}

private func hostedPilotBinding(
    home: AgentHome, suffix: String
) async throws -> WorkRunBinding {
    let host = try home.requirePersistedWorkHost()
    let binding = WorkBinding(
        session: SessionRef("hosted-pilot-session-\(suffix)"),
        work: WorkRef(workHostID: host.workHostID, workID: "hosted-pilot-work-\(suffix)"),
        workHost: host,
        sessionAttachment: SessionAttachmentRef("hosted-pilot-attachment-\(suffix)"))
    _ = try await RunJournalBundle.createIdleWork(
        home: home, binding: binding, actorID: "hosted-pilot-test")
    return WorkRunBinding(workBinding: binding, run: RunRef("hosted-pilot-run-\(suffix)"))
}

private func hostedPilotConfiguration(
    home: AgentHome, binding: WorkRunBinding, runtimeHost: RuntimeHost
) -> InHouseWorkFactory.Configuration {
    InHouseWorkFactory.Configuration(
        home: home,
        cwd: "/tmp",
        model: fakeModel(),
        provider: HostedPilotImmediateProvider(),
        runtimeHost: runtimeHost,
        workRunBinding: binding,
        serviceActorID: "hosted-pilot-work-host",
        systemPrompt: "You are a pilot test agent.",
        maxIterations: 2)
}

/// The private pilot is strictly opt-in. Existing public configuration construction must not
/// acquire a coordinator or alter the normal Hosted launch path; conversion preserves an
/// explicitly assigned pilot for the host-owned factory seam.
func testHostedWorkAgentChildPilotDefaultsToNilAndRoundTrips() async throws {
    guard let root = hostedPilotRuntimeRoot(),
          let runtimeHost = RuntimeHost.bundledPython(
              repoRoot: root, parentLifetimeLease: true)
    else { return }

    let home = scratchHome()
    let binding = try await hostedPilotBinding(home: home, suffix: "roundtrip")
    var configuration = hostedPilotConfiguration(
        home: home, binding: binding, runtimeHost: runtimeHost)
    XCTAssertNil(configuration.agentChildPilot)

    let coordinator = try WorkAgentChildCoordinator()
    let pilot = WorkAgentChildPilot(
        coordinator: coordinator,
        deadline: Date().addingTimeInterval(60),
        makeRuntimeHost: { RuntimeHost.bundledPython(
            repoRoot: root, parentLifetimeLease: true)! })
    configuration.agentChildPilot = pilot

    var hosted = HostedInHouseWorkConfiguration(
        home: configuration.home,
        cwd: configuration.cwd,
        model: configuration.model,
        provider: configuration.provider,
        runtimeHost: configuration.runtimeHost,
        workRunBinding: configuration.workRunBinding,
        serviceActorID: configuration.serviceActorID,
        actorKind: configuration.actorKind,
        systemPrompt: configuration.systemPrompt,
        maxIterations: configuration.maxIterations)
    hosted.agentChildPilot = pilot
    let roundTrip = InHouseWorkFactory.Configuration(hostedConfiguration: hosted)
    XCTAssertNotNil(roundTrip.agentChildPilot)
}

/// Factory admission must publish the Run bundle through the pilot's one Work route before it
/// returns the Hosted actor. A second open is therefore rejected as an already-owned live route,
/// rather than being allowed to create a competing writer behind the coordinator.
func testInHouseWorkFactoryPilotRegistersRunRoute() async throws {
    guard let root = hostedPilotRuntimeRoot(),
          let runtimeHost = RuntimeHost.bundledPython(
              repoRoot: root, parentLifetimeLease: true)
    else { return }

    let home = scratchHome()
    let binding = try await hostedPilotBinding(home: home, suffix: "route")
    var configuration = hostedPilotConfiguration(
        home: home, binding: binding, runtimeHost: runtimeHost)
    let coordinator = try WorkAgentChildCoordinator()
    configuration.agentChildPilot = WorkAgentChildPilot(
        coordinator: coordinator,
        deadline: Date().addingTimeInterval(60),
        makeRuntimeHost: { RuntimeHost.bundledPython(
            repoRoot: root, parentLifetimeLease: true)! })

    let work = try await InHouseWorkFactory.open(configuration: configuration)
    do {
        _ = try await coordinator.withRunOpen(work: binding.workBinding.work) {
            let bundle = try await RunJournalBundle.openForExecution(
                home: home,
                identity: SessionWorkIdentity(
                    sessionID: binding.workBinding.session.sessionID,
                    work: binding.workBinding.work,
                    runID: binding.run.runID),
                actorID: "unexpected-second-open",
                makeAttachmentID: { binding.workBinding.sessionAttachment.attachmentID })
            return (bundle, bundle)
        }
        XCTAssertTrue(false, "the pilot route must reject a competing live Run writer")
    } catch WorkAgentHandleJournal.Failure.writerStillOpen {
        // The factory registered the route and published its opened bundle before returning.
    }

    let snapshot = await work.snapshot()
    _ = try await work.submit(HostedInHouseWorkCommand(
        work: snapshot.identity.work,
        session: SessionRef(snapshot.identity.sessionID),
        sessionAttachment: snapshot.sessionAttachment,
        client: ClientRef("hosted-pilot-test"),
        commandID: "hosted-pilot-end",
        causalCursor: snapshot.latestWorkCursor!,
        command: .endRun))
}
