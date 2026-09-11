import Foundation

/// Host-private opt-in. No persisted or remote configuration can enable this pilot yet.
internal struct WorkAgentChildPilot: Sendable {
    let coordinator: WorkAgentChildCoordinator
    let deadline: Date?
    let makeRuntimeHost: @Sendable () -> RuntimeHost

    init(
        coordinator: WorkAgentChildCoordinator, deadline: Date? = nil,
        makeRuntimeHost: @escaping @Sendable () -> RuntimeHost
    ) {
        self.coordinator = coordinator
        self.deadline = deadline
        self.makeRuntimeHost = makeRuntimeHost
    }

    func makeDelegate(configuration: HostedInHouseWorkConfiguration) -> Agent.SpawnDelegate {
        WorkAgentChildSpawnDelegate(pilot: self, configuration: configuration)
    }
}

/// The callbacks are scoped to one authenticated Hosted Work binding. They are not a remote
/// authorization layer and never enumerate children belonging to other attached Sessions.
internal protocol WorkAgentSpawnDelegate: Agent.SpawnDelegate {
    func startWorkChild(
        callbackID: String, prompt: String, name: String?, model: String?, depth: Int
    ) async -> Agent.SpawnStartResult
    func handleStatus(id: String) async -> JSONValue
    func handleResult(id: String, offset: Int) async -> JSONValue
    func handleAwaitInterest(id: String, observerID: String, awaited: Bool) async -> JSONValue
}

internal actor WorkAgentChildSpawnDelegate: WorkAgentSpawnDelegate {
    private struct Request: Hashable, Sendable {
        let prompt: String
        let name: String?
        let model: String?
        let depth: Int
    }
    private struct Attempt {
        let request: Request
        let task: Task<Agent.SpawnStartResult, Never>
    }

    private let pilot: WorkAgentChildPilot
    private let configuration: HostedInHouseWorkConfiguration
    private var attempts: [String: Attempt] = [:]
    private var originated: [String] = []
    private let observerScope = UUID().uuidString.lowercased()
    private static let resultChunkBytes = 256 * 1_024

    init(pilot: WorkAgentChildPilot, configuration: HostedInHouseWorkConfiguration) {
        self.pilot = pilot
        self.configuration = configuration
    }

    func startBackground(
        prompt: String, name: String?, model: String?, depth: Int
    ) async -> Agent.SpawnStartResult {
        await startWorkChild(
            callbackID: UUID().uuidString, prompt: prompt, name: name, model: model, depth: depth)
    }

    /// At-least-once callbacks in this live Run share one admission task. An uncertain admission
    /// is retained as the same Handle, not retried. This is not cross-host execution recovery.
    func startWorkChild(
        callbackID: String, prompt: String, name: String?, model: String?, depth: Int
    ) async -> Agent.SpawnStartResult {
        let label = name ?? "child"
        guard !callbackID.isEmpty, callbackID.utf8.count <= 512,
              !prompt.isEmpty, prompt.utf8.count <= WorkAgentChildCoordinator.maximumPromptBytes,
              !label.isEmpty, label.utf8.count <= WorkAgentHandleSnapshot.maximumLabelBytes,
              depth == 1,
              model == nil || model == configuration.model.id
                || model == configuration.model.qualifiedID else {
            return .refused(name: label, reason: "Invalid Work child request or unsupported model/depth.")
        }
        let request = Request(prompt: prompt, name: name, model: model, depth: depth)
        if let prior = attempts[callbackID] {
            guard prior.request == request else {
                return .refused(name: label, reason: "The callback identity already names another request.")
            }
            return await prior.task.value
        }
        guard attempts.count < WorkAgentHandleSnapshot.maximumRetainedPerWork else {
            return .refused(name: label, reason: "This Run has reached its retained child-attempt limit.")
        }
        let pilot = self.pilot
        let configuration = self.configuration
        let task = Task<Agent.SpawnStartResult, Never> {
            do {
                let admission = try await pilot.coordinator.admit(
                    origin: configuration.workRunBinding, prompt: prompt, label: label,
                    deadline: pilot.deadline,
                    makeExecution: { handle, deadline in
                        AgentChildExecutionResource(
                            configuration: AgentChildExecutionConfiguration(
                                origin: configuration.workRunBinding, childID: handle.handleID,
                                deadline: deadline, home: configuration.home, cwd: configuration.cwd,
                                model: configuration.model, provider: configuration.provider,
                                systemPrompt: configuration.systemPrompt,
                                systemPromptAssembly: configuration.systemPromptAssembly,
                                reasoningEffort: configuration.reasoningEffort,
                                maxIterations: nil,
                                memory: configuration.memory, recordPayloads: configuration.recordPayloads,
                                makeRuntimeHost: pilot.makeRuntimeHost), prompt: prompt)
                    })
                return .workOwned(
                    handleID: admission.handle.handleID, name: label,
                    deadline: admission.deadline, admissionUncertain: false)
            } catch WorkAgentChildCoordinator.Failure.admissionUncertain(let handle) {
                return .workOwned(
                    handleID: handle.handleID, name: label,
                    deadline: pilot.deadline, admissionUncertain: true)
            } catch {
                return .refused(name: label, reason: "Work child admission was refused; no request was replayed.")
            }
        }
        attempts[callbackID] = Attempt(request: request, task: task)
        let result = await task.value
        if case .workOwned(let id, _, _, _) = result, !originated.contains(id) {
            originated.append(id)
        }
        return result
    }

    func children() async -> [Agent.ChildStatus] {
        var rows: [Agent.ChildStatus] = []
        for id in originated {
            let payload = await handleStatus(id: id)
            rows.append(Agent.ChildStatus(
                id: id, name: payload["name"]?.stringValue ?? "child",
                state: payload["state"]?.stringValue ?? "unavailable", answer: nil))
        }
        return rows
    }

    func handleStatus(id: String) async -> JSONValue {
        guard validID(id) else { return failure("Invalid Handle identity.") }
        do {
            let row = try await pilot.coordinator.inspect(
                work: configuration.workRunBinding.workBinding.work, handle: HandleRef(id))
            var payload: [String: JSONValue] = [
                "id": .string(id), "name": .string(row.label), "ownership": .string("work"),
                "state": .string(row.state.rawValue),
                "deadline": row.deadline.map { .number($0.timeIntervalSince1970) } ?? .null,
                "result_recorded": .bool(row.resultBody != nil),
                "source_event_id": .string(row.latestLifecycleEvent.eventID),
            ]
            if let outcome = row.terminalOutcome { payload["outcome"] = .string(outcome.rawValue) }
            if let cleanup = row.cleanup { payload["cleanup"] = .string(cleanup.state.rawValue) }
            return .object(payload)
        } catch { return failure("The Handle is unknown or canonical Work state is unavailable. No work was restarted.") }
    }

    /// Full body verification is bounded by 8 MiB per read; transport output is chunked. This
    /// does not claim a seekable body-store implementation or constant total lookup cost.
    func handleResult(id: String, offset: Int) async -> JSONValue {
        guard validID(id), offset >= 0, offset <= WorkAgentHandleSnapshot.maximumBodyBytes else {
            return failure("Invalid Handle body range.")
        }
        do {
            let read = try await pilot.coordinator.read(
                work: configuration.workRunBinding.workBinding.work, handle: HandleRef(id))
            guard read.record.state == .terminal else {
                return failure("The Handle has no readable terminal body; inspect its recorded state.")
            }
            guard case .available(let bytes) = read.result, offset <= bytes.count,
                  let body = read.record.resultBody, let digest = body.digest else {
                return failure("The recorded result body is absent or unavailable.")
            }
            let end = min(bytes.count, offset + Self.resultChunkBytes)
            return .object([
                "id": .string(id), "offset": .number(Double(offset)),
                "next_offset": .number(Double(end)), "byte_count": .number(Double(bytes.count)),
                "body_digest": .string(digest),
                "data_base64": .string(bytes.subdata(in: offset..<end).base64EncodedString()),
                "eof": .bool(end == bytes.count),
            ])
        } catch { return failure("The canonical result is unavailable; no work was restarted.") }
    }

    func handleAwaitInterest(id: String, observerID: String, awaited: Bool) async -> JSONValue {
        guard validID(id), !observerID.isEmpty, observerID.utf8.count <= 128 else {
            return failure("Invalid Handle or observer identity.")
        }
        do {
            let result = try await pilot.coordinator.awaitInterest(
                work: configuration.workRunBinding.workBinding.work, handle: HandleRef(id),
                observerID: observerScope + ":" + observerID, awaited: awaited)
            return .object(["accepted": .bool(result == .accepted)])
        } catch { return failure("Await interest could not be registered; the Handle was not restarted.") }
    }

    private func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func failure(_ detail: String) -> JSONValue { .object(["error": .string(detail)]) }
}
