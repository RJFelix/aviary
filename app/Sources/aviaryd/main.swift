import AviaryCore
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The local Work Host process.  It owns the service and transport for one process generation;
/// GUI/client disconnects are ordinary socket events and never reach the shutdown path.
@main
struct AviaryDaemonMain {
    private static let blockingProviderID = "aviaryd-test-provider"
    private static let blockingModelID = "aviaryd-test-model"
    private static let blockingSystemPrompt =
        "You are a deterministic Aviary daemon process test agent."

    /// A deterministic provider used only when the executable is explicitly launched with
    /// `--test-blocking`. It exercises the same Hosted/RuntimeHost/manifest path as production,
    /// while giving the subprocess test a real external release switch.
    private struct BlockingProvider: ChatProvider {
        let releaseFile: URL

        var id: String { AviaryDaemonMain.blockingProviderID }

        func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
            AsyncThrowingStream { continuation in
                let releaseFile = self.releaseFile
                Task {
                    do {
                        while !FileManager.default.fileExists(atPath: releaseFile.path) {
                            try Task.checkCancellation()
                            try await Task.sleep(nanoseconds: 20_000_000)
                        }
                        continuation.yield(.textDelta("daemon process survived client exit"))
                        continuation.yield(.done(stopReason: "test_release"))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Local sockets are a same-user boundary at this stage. The endpoint is private
    /// (0700 directory/0600 socket); this authorizer grants the protocol capabilities to that
    /// already-authenticated local principal. A future remote transport supplies a
    /// principal-backed authorizer instead.
    private struct LocalSocketAuthorizer: WorkServiceAuthorizer {
        func authorization(
            for client: ClientRef,
            requested: Set<WorkServiceCapability>
        ) -> WorkServiceAuthorizationOutcome {
            WorkServiceAuthorizationOutcome(
                requested: requested, granted: requested, denied: [])
        }
    }

    /// Installs the supervisor signal source before any asynchronous startup work. A signal
    /// delivered while the login shell or durable journals are opening is buffered, rather than
    /// being lost to the default signal disposition or an as-yet-unregistered waiter.
    private final class TerminationSignal: @unchecked Sendable {
        let stream: AsyncStream<Void>
        private let source: DispatchSourceSignal
        private var continuation: AsyncStream<Void>.Continuation?

        init() {
            signal(SIGTERM, SIG_IGN)
            var captured: AsyncStream<Void>.Continuation?
            stream = AsyncStream { captured = $0 }
            continuation = captured
            source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            source.setEventHandler { [weak self] in
                self?.continuation?.yield()
            }
            source.resume()
        }

        func cancel() {
            source.cancel()
            continuation?.finish()
            continuation = nil
        }
    }

    private enum StartupRaceOutcome: Sendable {
        case ready(WorkHostDaemonDescriptor)
        case failed(WorkHostDaemonCoordinatorError)
        case signal
        case parentLeaseEnded
    }

    private enum SupervisorRequest: Sendable {
        case signal
        case parentLeaseEnded
    }

    /// Resolves the startup/signal race without making signal handling wait for a potentially
    /// wedged resolver. The startup task is intentionally unstructured: after SIGTERM wins, the
    /// coordinator's state fence prevents a late startup continuation from publishing a listener.
    private final class StartupRace: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: StartupRaceOutcome?
        private var continuation: CheckedContinuation<StartupRaceOutcome, Never>?

        func resolve(_ outcome: StartupRaceOutcome) {
            lock.lock()
            guard self.outcome == nil else {
                lock.unlock()
                return
            }
            self.outcome = outcome
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: outcome)
        }

        func wait() async -> StartupRaceOutcome {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }

    /// A single signal consumer is kept alive across startup and steady state. This avoids the
    /// ready-vs-signal handoff losing an event when a temporary startup waiter is canceled.
    private actor SignalQueue {
        private var pending: [SupervisorRequest] = []
        private var waiter: CheckedContinuation<SupervisorRequest, Never>?

        func signal(_ request: SupervisorRequest) {
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: request)
            } else {
                pending.append(request)
            }
        }

        func wait() async -> SupervisorRequest {
            await withCheckedContinuation { continuation in
                if !pending.isEmpty {
                    continuation.resume(returning: pending.removeFirst())
                } else {
                    waiter = continuation
                }
            }
        }
    }

    private final class CompletionLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var continuation: CheckedContinuation<Void, Never>?

        func complete() {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }

        func wait(timeout: TimeInterval) async {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !completed else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + max(0, min(timeout, 30))) { [weak self] in
                    self?.complete()
                }
            }
        }
    }

    private struct Options {
        let home: AgentHome
        let socketRoot: URL?
        let instanceID: String?
        let startIdentity: String?
        let testBlocking: Bool
        let testParentLease: Bool
        let runtimeRepo: URL?
        let releaseFile: URL?
        let workspace: URL?

        static func parse(_ arguments: [String]) throws -> Options {
            var home: AgentHome?
            var socketRoot: URL?
            var instanceID: String?
            var startIdentity: String?
            var testBlocking = false
            var testParentLease = false
            var runtimeRepo: URL?
            var releaseFile: URL?
            var workspace: URL?
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--agent-home":
                    index += 1
                    guard index < arguments.count else { throw DaemonError.invalidArguments }
                    home = AgentHome(root: URL(fileURLWithPath: arguments[index], isDirectory: true))
                case "--socket-root":
                    index += 1
                    guard index < arguments.count else { throw DaemonError.invalidArguments }
                    socketRoot = URL(fileURLWithPath: arguments[index], isDirectory: true)
                case "--instance-id":
                    index += 1
                    guard index < arguments.count else { throw DaemonError.invalidArguments }
                    instanceID = arguments[index]
                case "--start-identity":
                    index += 1
                    guard index < arguments.count else { throw DaemonError.invalidArguments }
                    startIdentity = arguments[index]
                case "--test-blocking":
                    testBlocking = true
                case "--test-parent-lease":
                    testParentLease = true
                case "--runtime-repo":
                    index += 1
                    guard index < arguments.count else { throw DaemonError.invalidArguments }
                    runtimeRepo = URL(fileURLWithPath: arguments[index], isDirectory: true)
                case "--release-file":
                    index += 1
                    guard index < arguments.count else { throw DaemonError.invalidArguments }
                    releaseFile = URL(fileURLWithPath: arguments[index], isDirectory: false)
                case "--workspace":
                    index += 1
                    guard index < arguments.count else { throw DaemonError.invalidArguments }
                    workspace = URL(fileURLWithPath: arguments[index], isDirectory: true)
                case "--help", "-h":
                    print("usage: aviaryd [--agent-home PATH] [--socket-root PATH] "
                        + "[--test-blocking --runtime-repo PATH --release-file PATH "
                        + "--workspace PATH --test-parent-lease]")
                    exit(0)
                default:
                    throw DaemonError.invalidArguments
                }
                index += 1
            }
            guard !testParentLease || testBlocking else { throw DaemonError.invalidArguments }
            return Options(
                home: home ?? .default,
                socketRoot: socketRoot,
                instanceID: instanceID,
                startIdentity: startIdentity,
                testBlocking: testBlocking,
                testParentLease: testParentLease,
                runtimeRepo: runtimeRepo,
                releaseFile: releaseFile,
                workspace: workspace)
        }
    }

    private enum DaemonError: Error, LocalizedError {
        case invalidArguments

        var errorDescription: String? {
            switch self {
            case .invalidArguments:
                return "Invalid arguments. Use --help for usage."
            }
        }
    }

    static func main() async {
        AviaryTelemetry.configure(serviceName: "aviaryd", environment: ProcessInfo.processInfo.environment)
        var coordinator: WorkHostDaemonCoordinator?
        do {
            let options = try Options.parse(CommandLine.arguments)
            let termination = TerminationSignal()
            defer { termination.cancel() }
            let resolver = try serviceResolver(for: options)
            let createdCoordinator = try WorkHostDaemonCoordinator(
                home: options.home,
                socketRoot: options.socketRoot,
                instanceID: options.instanceID,
                startIdentity: options.startIdentity,
                resolver: resolver)
            coordinator = createdCoordinator
            let race = StartupRace()
            let signals = SignalQueue()
            let startupCompletion = CompletionLatch()
            let startupTask = Task {
                defer { startupCompletion.complete() }
                do {
                    race.resolve(.ready(try await createdCoordinator.start()))
                } catch let error as WorkHostDaemonCoordinatorError {
                    race.resolve(.failed(error))
                } catch {
                    race.resolve(.failed(.startupFailed(Self.bounded(error.localizedDescription))))
                }
            }
            let signalTask = Task {
                for await _ in termination.stream {
                    race.resolve(.signal)
                    await signals.signal(.signal)
                }
            }
            defer { signalTask.cancel() }
            // Abruptly killing the self-test process bypasses its Swift `defer` cleanup. In the
            // explicit subprocess-test mode, stdin is therefore a parent-lifetime lease: kernel
            // EOF is an unambiguous signal that the test owner vanished. It force-stops only the
            // process-owned transport and never terminalizes durable Work.
            let parentLeaseTask: Task<Void, Never>? = options.testParentLease ? Task.detached {
                while !Task.isCancelled {
                    let data = FileHandle.standardInput.availableData
                    if data.isEmpty {
                        race.resolve(.parentLeaseEnded)
                        await signals.signal(.parentLeaseEnded)
                        return
                    }
                }
            } : nil
            defer { parentLeaseTask?.cancel() }
            let startupOutcome = await race.wait()
            let descriptor: WorkHostDaemonDescriptor
            switch startupOutcome {
            case .ready(let value):
                descriptor = value
            case .failed(let error):
                startupTask.cancel()
                throw error
            case .signal:
                startupTask.cancel()
                await createdCoordinator.forceStop()
                // Give cooperative startup work a bounded opportunity to unwind before the fatal
                // path exits. The coordinator fence already guarantees that a late continuation
                // cannot publish a listener; this wait avoids relying on process exit for cleanup
                // in the normal cancellation case.
                await startupCompletion.wait(timeout: 2)
                // SIGTERM during startup is an ordinary supervisor stop, not a daemon startup
                // error. Cleanup has completed above, so return successfully without printing a
                // misleading failure or exiting with status 1.
                await AviaryTelemetry.shutdown(maximumDuration: 2)
                return
            case .parentLeaseEnded:
                startupTask.cancel()
                await createdCoordinator.forceStop()
                await startupCompletion.wait(timeout: 2)
                await AviaryTelemetry.shutdown(maximumDuration: 2)
                return
            }
            let ready = "aviaryd ready host=\(descriptor.hostInstance.host.workHostID)"
                + " instance=\(descriptor.hostInstance.instanceID)"
                + " endpoint=\(descriptor.endpoint.path)\n"
            FileHandle.standardOutput.write(Data(ready.utf8))

            // A signal is an explicit process-supervisor request.  A refused ordinary shutdown
            // leaves the daemon serving and waits for the next request; it never End-mutates Work.
            while true {
                let request = await signals.wait()
                if case .parentLeaseEnded = request {
                    await createdCoordinator.forceStop()
                    break
                }
                do {
                    try await createdCoordinator.shutdown()
                    break
                } catch let error as WorkHostDaemonCoordinatorError {
                    let line = "aviaryd shutdown refused: \(Self.bounded(error.localizedDescription))\n"
                    FileHandle.standardError.write(Data(line.utf8))
                    // A bounded drain timeout is also refusal-based: an in-flight request may
                    // still be mutating durable Work, so keep serving and let the supervisor
                    // retry rather than exiting with an unknown mutation outcome.
                    if case .shutdownRefused = error { continue }
                    if case .shutdownTimedOut = error { continue }
                    throw error
                }
            }
            await AviaryTelemetry.shutdown(maximumDuration: 2)
        } catch {
            if let coordinator {
                // Unexpected startup/shutdown failure must not strand an endpoint.json or socket
                // path. forceStop is deliberately non-terminalizing: durable Work remains for
                // recovery, while this process-owned transport is cleaned up before exit.
                await coordinator.forceStop()
            }
            let line = "aviaryd: \(Self.bounded(error.localizedDescription))\n"
            FileHandle.standardError.write(Data(line.utf8))
            await AviaryTelemetry.shutdown(maximumDuration: 2)
            exit(1)
        }
    }

    private static func bounded(_ value: String, maximumBytes: Int = 500) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        return String(decoding: value.utf8.prefix(maximumBytes), as: UTF8.self)
    }

    private static func serviceResolver(for options: Options) throws -> WorkHostDaemonServiceResolver {
        let authorizer = LocalSocketAuthorizer()
        guard options.testBlocking else {
            // `--runtime-repo` exists only for the deterministic test fixture below. A normal
            // daemon must derive its Python host from the binary's own origin: bundled helpers
            // use their app Resources payload and SwiftPM products use their enclosing checkout.
            // In particular, do not fall back to a conventional developer checkout when a
            // shipped bundle is missing or damaged.
            guard options.runtimeRepo == nil,
                  let executableURL = Bundle.main.executableURL
                    ?? (CommandLine.arguments.first.map {
                        URL(fileURLWithPath: $0, isDirectory: false)
                    }),
                  let runtimeRoot = EngineLocator.runtimeRoot(forExecutable: executableURL) else {
                throw DaemonError.invalidArguments
            }
            let explicitWorkspace = options.workspace
            // Construct the immutable launch resolver only after the coordinator has loaded the
            // login-shell environment. A bundled GUI process commonly starts with a sparse PATH
            // and no provider variables; capturing before that boundary would make the daemon's
            // reported environment provenance disagree with the credentials it can actually use.
            return WorkHostDaemonServiceResolver { home, host, instance, environment in
                let workspaceRegistry = try WorkHostWorkspaceRegistry(home: home)
                // Only the explicit --workspace option is allowed to mutate the host registry.
                // Without it, the daemon must not silently register or promote its process cwd.
                if let explicitWorkspace {
                    _ = try workspaceRegistry.registerLocalDirectory(
                        explicitWorkspace, label: "Default workspace", isDefault: true)
                }
                let launchResolver = LocalWorkHostLaunchResolver(configuration: .init(
                    home: home,
                    workspaceRegistry: workspaceRegistry,
                    runtimeRepositoryRoot: runtimeRoot,
                    environment: environment))
                let durable = WorkHostDaemonServiceResolver.durable(
                    authorizer: authorizer,
                    draftResolver: launchResolver.draftResolver,
                    hostedResolver: launchResolver.hostedConfigurationResolver,
                    agentChildRuntimeHostResolver:
                        launchResolver.agentChildRuntimeHostResolver,
                    promptAssemblyResolver: launchResolver.promptAssemblyResolver,
                    reconstructabilityProbe: launchResolver.reconstructabilityProbe,
                    workspaceCatalogProvider: { try workspaceRegistry.catalog() })
                return try await durable.open(
                    home: home, host: host, instance: instance, environment: environment)
            }
        }

        guard let runtimeRepo = options.runtimeRepo,
              let releaseFile = options.releaseFile,
              let workspace = options.workspace,
              !releaseFile.path.isEmpty,
              !releaseFile.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DaemonError.invalidArguments
        }
        var repoIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: runtimeRepo.path, isDirectory: &repoIsDirectory), repoIsDirectory.boolValue else {
            throw DaemonError.invalidArguments
        }
        let resolvedWorkspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        var workspaceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: resolvedWorkspace.path, isDirectory: &workspaceIsDirectory),
              workspaceIsDirectory.boolValue else {
            throw DaemonError.invalidArguments
        }
        let resolvedRepo = runtimeRepo.standardizedFileURL.resolvingSymlinksInPath()
        guard let runtimeHost = RuntimeHost.bundledPython(repoRoot: resolvedRepo) else {
            throw DaemonError.invalidArguments
        }
        let workspaceRegistry = try WorkHostWorkspaceRegistry(home: options.home)
        let workspaceDescriptor = try workspaceRegistry.registerLocalDirectory(
            resolvedWorkspace, label: "Default workspace", isDefault: true)
        let provider = BlockingProvider(releaseFile: releaseFile)
        let model = ModelSpec(rpc: .object([
            "id": .string(blockingModelID),
            "provider": .string(blockingProviderID),
            "name": .string("Aviary daemon process test"),
        ]))
        let blockingAssembly = try SystemPromptAssembly(
            text: blockingSystemPrompt,
            sources: [try PromptSource(
                sourceID: "aviaryd-test-prompt-v1",
                kind: .generated,
                label: "daemon test prompt",
                fullBody: blockingSystemPrompt,
                deliveredBody: blockingSystemPrompt,
                renderedBody: blockingSystemPrompt)])
            let draftResolver: DurableJournalBackedWorkLaunchManifestStore.DraftResolver = { request in
            guard request.configuration.providerID == blockingProviderID,
                  request.configuration.modelID == blockingModelID,
                  request.configuration.workspaceID == workspaceDescriptor.workspaceID else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            return WorkLaunchManifestDraft(
                workspace: WorkLaunchWorkspace(
                    locator: resolvedWorkspace.path, policy: .workspace),
                runtime: WorkLaunchRuntime(
                    providerID: blockingProviderID,
                    modelID: blockingModelID,
                    runtimeVariant: "python3"),
                configuration: request.configuration,
                requestedCapabilities: request.requestedCapabilities,
                budgetPolicy: WorkLaunchBudgetPolicy(
                    maximumTurns: 2, maximumDepth: 1, childMaximumTurns: 1),
                provenance: WorkLaunchManifestProvenance(source: "aviaryd.test-blocking"))
        }
        let promptAssemblyResolver:
            DurableJournalBackedWorkLaunchManifestStore.PromptAssemblyResolver = {
                draft, startBody, intent in
            let bodyDigest = "sha256:" + AviarySHA256.hash(data: startBody)
                .map { String(format: "%02x", $0) }.joined()
            guard draft.runtime.providerID == blockingProviderID,
                  draft.runtime.modelID == blockingModelID,
                  startBody.count <= WorkServiceBounds.maxCommandValueCharacters,
                  String(data: startBody, encoding: .utf8) != nil,
                  intent.bodyDigest == bodyDigest else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            return blockingAssembly
        }
        let hostedResolver: DurableJournalBackedWorkLaunchManifestStore.HostedConfigurationResolver = {
            manifest, binding, policy in
            guard manifest.runtime.providerID == blockingProviderID,
                  manifest.runtime.modelID == blockingModelID,
                  manifest.workspace.locator == resolvedWorkspace.path,
                  manifest.workspace.policy == .workspace,
                  manifest.workspaceID == workspaceDescriptor.workspaceID else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            let assembly = try WorkLaunchManifestStore(home: options.home)
                .resolvePromptAssembly(for: manifest)
            guard assembly.flattenedDigest == blockingAssembly.flattenedDigest,
                  assembly.flattenedText == blockingAssembly.flattenedText else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            return HostedInHouseWorkConfiguration(
                home: options.home,
                cwd: resolvedWorkspace.path,
                model: model,
                provider: provider,
                runtimeHost: runtimeHost,
                workRunBinding: binding,
                serviceActorID: "aviaryd",
                systemPrompt: assembly.flattenedText,
                systemPromptAssembly: assembly,
                maxDepth: 1,
                maxIterations: 2,
                childMaxIterations: 1,
                projectionMode: policy.projection,
                modelContextMode: policy.modelContext)
        }
        return .durable(
            authorizer: authorizer,
            draftResolver: draftResolver,
            hostedResolver: hostedResolver,
            promptAssemblyResolver: promptAssemblyResolver,
            reconstructabilityProbe: { _ in true },
            workspaceCatalogProvider: { try workspaceRegistry.catalog() })
    }
}
