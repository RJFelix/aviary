import Foundation

/// The bounded execution input for one agent child.
///
/// The Work Host owns admission, lifetime and durable Handle records. This value only carries
/// the already-resolved execution inputs needed to run one child. In particular, `provider` is
/// not a provider factory and `makeRuntimeHost` must return a fresh host for this child.
public struct AgentChildExecutionConfiguration: Sendable {
    public let origin: WorkRunBinding
    public let childID: String
    public let deadline: Date?
    public let home: AgentHome
    public let cwd: String
    public let model: ModelSpec
    public let provider: any ChatProvider
    public let systemPrompt: String
    public let systemPromptAssembly: SystemPromptAssembly?
    public let reasoningEffort: String?
    public let maxIterations: Int?
    public let memory: MemoryStore?
    public let recordPayloads: Bool
    public let makeRuntimeHost: @Sendable () -> RuntimeHost

    public init(
        origin: WorkRunBinding,
        childID: String,
        deadline: Date? = nil,
        home: AgentHome,
        cwd: String,
        model: ModelSpec,
        provider: any ChatProvider,
        systemPrompt: String,
        systemPromptAssembly: SystemPromptAssembly? = nil,
        reasoningEffort: String? = nil,
        maxIterations: Int? = nil,
        memory: MemoryStore? = nil,
        recordPayloads: Bool = false,
        makeRuntimeHost: @escaping @Sendable () -> RuntimeHost
    ) {
        self.origin = origin
        self.childID = childID
        self.deadline = deadline
        self.home = home
        self.cwd = cwd
        self.model = model
        self.provider = provider
        self.systemPrompt = systemPrompt
        self.systemPromptAssembly = systemPromptAssembly
        self.reasoningEffort = reasoningEffort
        self.maxIterations = maxIterations
        self.memory = memory
        self.recordPayloads = recordPayloads
        self.makeRuntimeHost = makeRuntimeHost
    }
}

public enum AgentChildExecutionState: String, Sendable, Equatable {
    case succeeded
    case failed
    case canceled
    case expired
}

/// Coverage of resources owned by this executor: its Python session/process, admitted
/// callbacks, and transcript writer. This does not contain or undo external effects, nor prove
/// that arbitrary processes launched directly by trusted Python have stopped.
public struct AgentChildExecutionCleanup: Sendable, Equatable {
    public let runtimeSessionDestroyed: Bool
    public let runtimeStopped: Bool
    public let transcriptClosed: Bool

    public init(
        runtimeSessionDestroyed: Bool,
        runtimeStopped: Bool,
        transcriptClosed: Bool
    ) {
        self.runtimeSessionDestroyed = runtimeSessionDestroyed
        self.runtimeStopped = runtimeStopped
        self.transcriptClosed = transcriptClosed
    }

    public var isComplete: Bool {
        runtimeSessionDestroyed && runtimeStopped && transcriptClosed
    }
}

public struct AgentChildExecutionResult: Sendable, Equatable {
    public let childID: String
    public let state: AgentChildExecutionState
    public let answer: String?
    public let detail: String?
    public let transcriptURL: URL?
    public let runtimeIdentity: RuntimeHost.HostIdentity?
    public let cleanup: AgentChildExecutionCleanup

    public init(
        childID: String,
        state: AgentChildExecutionState,
        answer: String? = nil,
        detail: String? = nil,
        transcriptURL: URL? = nil,
        runtimeIdentity: RuntimeHost.HostIdentity? = nil,
        cleanup: AgentChildExecutionCleanup
    ) {
        self.childID = childID
        self.state = state
        self.answer = answer
        self.detail = detail
        self.transcriptURL = transcriptURL
        self.runtimeIdentity = runtimeIdentity
        self.cleanup = cleanup
    }
}

public enum AgentChildCancellationOutcome: Sendable, Equatable {
    case accepted
    case alreadyTerminal(AgentChildExecutionState)
}

/// A single host-owned child execution.
///
/// This actor deliberately has no parent `AgentRunner`, parent `RuntimeHost`, or lifecycle
/// journal reference. The Work coordinator owns the durable Handle and calls `execute()` once;
/// the returned result and cleanup receipt are evidence for that coordinator to record. The
/// resource keeps its execution task alive across caller cancellation and only explicit
/// `cancel()` changes its cancellation boundary.
public actor AgentChildExecutionResource {
    private static let maxPromptBytes = 64 * 1024
    private struct NestedChildRefusal: Agent.SpawnDelegate {
        func startBackground(
            prompt: String, name: String?, model: String?, depth: Int
        ) async -> Agent.SpawnStartResult {
            .refused(
                name: name ?? "child",
                reason: "Nested agent children are not supported in this pilot.")
        }

        func children() async -> [Agent.ChildStatus] { [] }
    }

    private let configuration: AgentChildExecutionConfiguration
    private let prompt: String
    private var executionTask: Task<AgentChildExecutionResult, Never>?
    private var terminalResult: AgentChildExecutionResult?
    private var cleanupReceipt: AgentChildExecutionCleanup?
    private var cleanupDetail: String?
    private var cancellationRequested = false
    private var cleanupRequested = false

    private var runtimeHost: RuntimeHost?
    private var runtimeSession: String?
    private var runtimeSessionCreated = false
    private var runnerPrepared = false
    private var writer: SessionWriter?
    private var runner: AgentRunner?
    private var agent: Agent?

    public init(
        configuration: AgentChildExecutionConfiguration,
        prompt: String
    ) {
        self.configuration = configuration
        self.prompt = prompt
    }

    /// Start at most one owned execution. Calling this again returns the same terminal result.
    /// Cancellation of the caller does not cancel the owned task.
    public func execute() async -> AgentChildExecutionResult {
        if let terminalResult { return terminalResult }
        if cleanupRequested {
            let result = AgentChildExecutionResult(
                childID: configuration.childID,
                state: .canceled,
                detail: "The child was cleaned up before execution started.",
                cleanup: cleanupReceipt ?? emptyCleanup)
            terminalResult = result
            return result
        }
        if let executionTask { return await executionTask.value }

        let task = Task { [weak self] in
            guard let self else {
                return AgentChildExecutionResult(
                    childID: "unknown", state: .failed,
                    detail: "The child execution resource was released.",
                    runtimeIdentity: nil,
                    cleanup: AgentChildExecutionCleanup(
                        runtimeSessionDestroyed: false, runtimeStopped: false,
                        transcriptClosed: false))
            }
            return await self.perform()
        }
        executionTask = task
        return await task.value
    }

    /// Record cancellation intent before awaiting any actor or process boundary, then ask the
    /// real Agent to cancel and drain its active send. A queued/preparation child observes the
    /// intent at its next setup boundary and cannot resurrect itself afterward.
    public func cancel() async -> AgentChildCancellationOutcome {
        if let terminalResult { return .alreadyTerminal(terminalResult.state) }
        cancellationRequested = true
        executionTask?.cancel()
        if let agent {
            await agent.cancel()
            await agent.waitUntilQuiescent()
        }
        return .accepted
    }

    /// Read-only coordination evidence for callers that must prove cancellation intent was
    /// recorded before releasing a gated provider or making another request.
    public var cancellationIntentRecorded: Bool { cancellationRequested }

    /// Idempotent cleanup. If execution exists, this waits for its owned task; otherwise it
    /// closes nothing and returns a truthful empty receipt.
    public func cleanup() async -> AgentChildExecutionCleanup {
        if let cleanupReceipt { return cleanupReceipt }
        if let executionTask {
            _ = await executionTask.value
            return cleanupReceipt ?? emptyCleanup
        }
        cleanupRequested = true
        cancellationRequested = true
        return await finishCleanup()
    }

    private var emptyCleanup: AgentChildExecutionCleanup {
        AgentChildExecutionCleanup(
            runtimeSessionDestroyed: !runtimeSessionCreated,
            runtimeStopped: runtimeHost == nil,
            transcriptClosed: writer == nil)
    }

    private func perform() async -> AgentChildExecutionResult {
        var state: AgentChildExecutionState = .failed
        var answer: String?
        var detail: String?
        var transcriptURL: URL?
        var runtimeIdentity: RuntimeHost.HostIdentity?

        do {
            try validateConfiguration()
            try checkCancellationOrDeadline()

            let childHome = try makeChildHome()
            let identity = SessionWorkIdentity.allocate(
                workHostID: configuration.origin.workBinding.workHost.workHostID,
                sessionID: "\(configuration.childID)-session",
                workID: "\(configuration.childID)-work",
                runID: "\(configuration.childID)-run")
            let childWriter = try SessionWriter(
                home: childHome, cwd: configuration.cwd,
                model: configuration.model, identity: identity)
            writer = childWriter
            transcriptURL = childWriter.fileURL
            try checkCancellationOrDeadline()

            let childHost = configuration.makeRuntimeHost()
            guard await childHost.claimChildExecutionOwnership() else {
                throw AgentChildExecutionError.ownershipUnavailable
            }
            runtimeHost = childHost
            let capabilities = try await childHost.start()
            runtimeIdentity = capabilities.identity
            try checkCancellationOrDeadline()

            let childRunner = AgentRunner(
                provider: configuration.provider,
                host: childHost,
                settings: .init(
                    home: childHome,
                    cwd: configuration.cwd,
                    model: configuration.model,
                    systemPrompt: AgentRunner.childPrompt(
                        base: configuration.systemPrompt, depth: 1, maxDepth: 1),
                    // childPrompt adds a generated suffix, so the captured parent assembly no
                    // longer describes these bytes. Preserve honest provenance until a generated
                    // child assembly seam exists rather than passing mismatched metadata.
                    systemPromptAssembly: nil,
                    maxDepth: 1,
                    maxIterations: configuration.maxIterations,
                    childMaxIterations: 0,
                    memory: configuration.memory,
                    recordPayloads: configuration.recordPayloads,
                    childDelegate: NestedChildRefusal(),
                    identity: identity,
                    reasoningEffort: configuration.reasoningEffort,
                    writer: childWriter,
                    nativeJournal: nil))
            runner = childRunner
            runtimeSession = identity.workID
            runtimeSessionCreated = true
            let prepared = try await childRunner.prepare()
            runnerPrepared = true
            agent = prepared.agent
            try checkCancellationOrDeadline()

            if cancellationRequested {
                await prepared.agent.cancel()
                await prepared.agent.waitUntilQuiescent()
                state = .canceled
                detail = "The child was canceled before its prompt was delivered."
            } else {
                let outcome = await prepared.agent.send(prompt)
                answer = await prepared.agent.lastAssistantText
                if cancellationRequested || outcome == .cancelled {
                    state = .canceled
                    detail = "The child was canceled at an agent-loop boundary."
                } else {
                    switch outcome {
                    case .completed:
                        state = answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            ? .succeeded : .failed
                        if state == .failed { detail = "The child produced no answer." }
                    case .failed(let message):
                        state = .failed
                        detail = message
                    case .cancelled:
                        state = .canceled
                        detail = "The child was canceled at an agent-loop boundary."
                    }
                }
            }
        } catch is AgentChildExecutionCancellation {
            state = .canceled
            detail = "The child was canceled before execution completed."
        } catch AgentChildExecutionError.deadlineExpired {
            state = cancellationRequested ? .canceled : .expired
            detail = cancellationRequested
                ? "The child was canceled before execution completed."
                : "The child execution deadline expired before execution."
        } catch {
            state = cancellationRequested ? .canceled : .failed
            detail = cancellationRequested
                ? "The child was canceled before execution completed."
                : String(error.localizedDescription.prefix(500))
        }

        let cleanup = await finishCleanup()
        if cancellationRequested, state == .succeeded {
            state = .canceled
            detail = "The child was canceled during cleanup."
        }
        if !cleanup.isComplete, state == .succeeded {
            state = .failed
            detail = cleanupDetail ?? "Child cleanup did not complete."
        }
        let result = AgentChildExecutionResult(
            childID: configuration.childID,
            state: state,
            answer: answer,
            detail: detail,
            transcriptURL: transcriptURL,
            runtimeIdentity: runtimeIdentity,
            cleanup: cleanup)
        terminalResult = result
        return result
    }

    private func validateConfiguration() throws {
        let id = configuration.childID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id == configuration.childID,
              !id.isEmpty, id.utf8.count <= 256,
              !id.contains("/"), !id.contains("\\"), id != ".", id != ".."
        else { throw AgentChildExecutionError.invalidConfiguration("childID is invalid") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentChildExecutionError.invalidConfiguration("child prompt is empty")
        }
        guard prompt.utf8.count <= Self.maxPromptBytes else {
            throw AgentChildExecutionError.invalidConfiguration("child prompt is too large")
        }
        if let maxIterations = configuration.maxIterations {
            guard (1...1_000).contains(maxIterations) else {
                throw AgentChildExecutionError.invalidConfiguration(
                    "maxIterations must be between 1 and 1000")
            }
        }
        if let deadline = configuration.deadline {
            guard deadline.timeIntervalSince1970.isFinite else {
                throw AgentChildExecutionError.invalidConfiguration("child deadline is not finite")
            }
        }
    }

    private func checkCancellationOrDeadline() throws {
        if cancellationRequested { throw AgentChildExecutionCancellation() }
        if let deadline = configuration.deadline, Date() >= deadline {
            throw AgentChildExecutionError.deadlineExpired
        }
    }

    private func makeChildHome() throws -> AgentHome {
        let directory = configuration.home.artifactsDir
            .appending(path: "child-executions", directoryHint: .isDirectory)
            .appending(path: configuration.childID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AgentHome(root: directory)
    }

    private func finishCleanup() async -> AgentChildExecutionCleanup {
        if let cleanupReceipt { return cleanupReceipt }
        var runtimeSessionDestroyed = !runtimeSessionCreated
        var runtimeStopped = runtimeHost == nil
        var transcriptClosed = writer == nil
        var failures: [String] = []

        if let agent {
            await agent.cancel()
            await agent.waitUntilQuiescent()
        }
        if let runner { await runner.stopMCPServers() }
        if let runtimeHost, let runtimeSession, runtimeSessionCreated, runnerPrepared {
            do {
                try await runtimeHost.destroySession(runtimeSession)
                runtimeSessionDestroyed = true
            } catch {
                failures.append("runtime session cleanup failed: \(error.localizedDescription)")
            }
        }
        if let writer {
            do {
                try await writer.closeChecked()
                transcriptClosed = true
            } catch {
                failures.append("transcript cleanup failed: \(error.localizedDescription)")
            }
        }
        if let runtimeHost {
            let stopReceipt = await runtimeHost.stopWithReceipt()
            runtimeStopped = stopReceipt.ownedProcessExitVerified
                && stopReceipt.callbacksQuiescent
            if runtimeStopped { runtimeSessionDestroyed = true }
            if !runtimeStopped {
                failures.append("runtime host shutdown was not fully verified")
            }
        }
        cleanupDetail = failures.isEmpty ? nil : String(failures.joined(separator: " ").prefix(500))
        let receipt = AgentChildExecutionCleanup(
            runtimeSessionDestroyed: runtimeSessionDestroyed,
            runtimeStopped: runtimeStopped,
            transcriptClosed: transcriptClosed)
        cleanupReceipt = receipt
        if receipt.isComplete {
            // The terminal result retains only bounded evidence (answer, URL, identity). Do not
            // keep the full Agent/runner/transcript/runtime graph alive after verified cleanup.
            agent = nil
            runner = nil
            writer = nil
            runtimeHost = nil
            runtimeSession = nil
        }
        return receipt
    }
}

private struct AgentChildExecutionCancellation: Error {}

private enum AgentChildExecutionError: LocalizedError {
    case invalidConfiguration(String)
    case deadlineExpired
    case ownershipUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): return detail
        case .deadlineExpired: return "The child execution deadline expired before execution."
        case .ownershipUnavailable:
            return "The runtime host was not a fresh, exclusively leased child host."
        }
    }
}
