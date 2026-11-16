import Foundation

/// A native, process-owned Muse Code session.
///
/// Muse owns its own loop, tools, approvals, and provider session. Aviary owns the durable
/// transcript and observes the MSP view. Command acknowledgements are intake evidence only;
/// `turn/completed` is the only event that completes a turn.
public actor MuseCodeRun {
    public struct Settings: Sendable {
        public var home: AgentHome
        public var cwd: String
        public var model: String
        public var effort: String?
        public var identity: SessionWorkIdentity?
        public var resumingMuseSessionID: String?
        /// Must commit the native identity before the first model/tool crossing.
        public var sessionReady: (@Sendable (String) async throws -> Void)?

        public init(
            home: AgentHome, cwd: String, model: String, effort: String? = nil,
            identity: SessionWorkIdentity? = nil,
            resumingMuseSessionID: String? = nil,
            sessionReady: (@Sendable (String) async throws -> Void)? = nil
        ) {
            self.home = home
            self.cwd = cwd
            self.model = model
            self.effort = effort
            self.identity = identity
            self.resumingMuseSessionID = resumingMuseSessionID
            self.sessionReady = sessionReady
        }
    }

    public enum Event: Sendable {
        case started(aviarySession: String)
        case museSession(String)
        case inputCommitted(id: String)
        case textDelta(String)
        case thinkingDelta(String)
        case messageCommitted(id: String)
        case toolStarted(name: String)
        case toolFinished(name: String, isError: Bool)
        case turnFinished(turnID: String, terminal: String)
        case usage(Usage)
        case approvalPending(
            requirement: MuseMSPApprovalRequirement, choices: [String],
            labels: [String: String], detail: String?
        )
        /// A host event resolved an approval. A command ACK alone never emits this event.
        case approvalResolved(requirement: MuseMSPApprovalRequirement, choiceID: String, terminal: Bool)
        case warning(String)
        case failed(String)
        case finished
    }

    public enum RunError: LocalizedError, Sendable, Equatable {
        case noBinary
        case launchFailed(String)
        case deliveryFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noBinary:
                return "No `muse` executable was found. Install Muse Code and sign in once."
            case .launchFailed(let detail): return "Could not start Muse Code: \(detail)"
            case .deliveryFailed(let detail): return "Could not deliver input to Muse Code: \(detail)"
            }
        }
    }

    private struct MessageBuffer {
        var id: String
        var text = ""
        var thinking = ""
        var toolCalls: [(id: String, name: String, arguments: JSONValue)] = []
        var stopReason: String?

        var hasContent: Bool { !text.isEmpty || !thinking.isEmpty || !toolCalls.isEmpty }
    }

    private struct PendingApproval {
        let requirement: MuseMSPApprovalRequirement
        let choices: [String]
        let labels: [String: String]
        let detail: String?
    }

    private let settings: Settings
    private let writer: SessionWriter
    private var observer: (@Sendable (Event) -> Void)?
    private var owner: MuseMSPProcess?
    private var incomingTask: Task<Void, Never>?
    private var sessionIDValue: String?
    private var activeTurnID: String?
    private var activeCommandID: String?
    private var pendingTurn = false
    private var messageBuffers: [String: MessageBuffer] = [:]
    private var pendingToolNames: [String: String] = [:]
    private var completedItems = Set<String>()
    private var itemKinds: [String: String] = [:]
    private var earlyTerminals: [String: (terminal: String, error: JSONValue?, params: JSONValue)] = [:]
    private var approvals: [String: PendingApproval] = [:]
    private var recordedOutcome: TranscriptOutcome.State?
    private var stopping = false
    public private(set) var isFinished = false
    public private(set) var totalUsage = Usage()

    public nonisolated var sessionID: String { writer.sessionID }
    public nonisolated var fileURL: URL { writer.fileURL }
    public nonisolated var sessionWriter: SessionWriter { writer }
    public var museSessionID: String? { sessionIDValue }

    public init(settings: Settings, writer: SessionWriter) {
        self.settings = settings
        self.writer = writer
    }

    public func observe(_ observer: (@Sendable (Event) -> Void)?) {
        self.observer = observer
    }

    public func start(prompt: String, firstCommandID: String? = nil,
                      precommittedInputID: String? = nil) async throws {
        guard !isFinished, !stopping, owner == nil else {
            throw RunError.launchFailed("the Muse run has already started")
        }
        var inputID = precommittedInputID
        if !prompt.isEmpty, inputID == nil {
            guard await writerIsHealthy() else {
                let error = RunError.launchFailed("the session journal is unavailable")
                emit(.failed(error.localizedDescription))
                throw error
            }
            do {
                inputID = try await writer.appendUser(prompt)
            } catch {
                let detail = "the journal rejected the user message: \(error.localizedDescription)"
                await failBeforeStart(detail)
                throw RunError.deliveryFailed(detail)
            }
        } else if !(await writerIsHealthy()) {
            let error = RunError.launchFailed("the session journal is unavailable")
            emit(.failed(error.localizedDescription))
            throw error
        }
        guard !stopping, !isFinished, let executable = await MuseCode.locate() else {
            let error = RunError.noBinary
            await failBeforeStart(error.localizedDescription)
            throw error
        }

        let process: MuseMSPProcess
        do {
            process = try await MuseMSPProcess.launch(
                executable: executable, cwd: settings.cwd,
                environment: MuseCode.scrubbedEnvironment(), experimentalAPI: true,
                userInputDialogs: false)
            guard !stopping, !isFinished else {
                await process.stop()
                throw RunError.launchFailed("the Muse run was stopped during startup")
            }
            owner = process
            let session = try await startSession(connection: process.connection)
            guard !stopping, !isFinished else {
                await process.stop()
                throw RunError.launchFailed("the Muse run was stopped during startup")
            }
            sessionIDValue = session.sessionID
            try await settings.sessionReady?(session.sessionID)
            if let effort = settings.effort {
                let effortCommand = MuseMSPSession.newCommandID()
                let ack = try MuseMSPCommandAck(await process.connection.request("session/setReasoningEffort", params: .object([
                    "sessionId": .string(session.sessionID),
                    "commandId": .string(effortCommand),
                    "reasoningEffort": .string(effort),
                ])))
                guard ack.commandID == effortCommand else { throw MuseMSPError.invalidResponse }
            }
            guard !stopping, !isFinished else {
                await process.stop()
                throw RunError.launchFailed("the Muse run was stopped during startup")
            }
            emit(.started(aviarySession: writer.sessionID))
            emit(.museSession(session.sessionID))
            let stream = process.connection.incoming
            incomingTask = Task { [weak self] in
                for await incoming in stream {
                    guard let self else { return }
                    await self.ingest(incoming)
                }
                await self?.connectionEnded()
            }
        } catch {
            await stopOwner()
            let detail = error.localizedDescription
            await failBeforeStart(detail)
            throw RunError.launchFailed(detail)
        }

        if !prompt.isEmpty, !stopping, !isFinished {
            let delivery = await dispatchPrecommitted(
                prompt, inputID: inputID!, commandID: firstCommandID)
            guard delivery.isDelivered else {
                let detail = delivery.detail ?? "input delivery was not confirmed"
                throw RunError.deliveryFailed(detail)
            }
        }
    }

    /// Append exactly once, then attempt exactly one MSP `turn/start`. A lost acknowledgement
    /// is indeterminate and is never retried, because the host may have accepted the command.
    public func send(_ text: String, commandID suppliedCommandID: String? = nil) async -> SessionCommandDelivery {
        guard !text.isEmpty else { return .notDelivered(reason: "the input is empty") }
        guard owner != nil, sessionIDValue != nil, !isFinished, !stopping, !pendingTurn,
              await writerIsHealthy() else {
            return .notDelivered(reason: "the Muse run is not accepting input")
        }
        let inputID: String
        do {
            inputID = try await writer.appendUser(text)
            recordedOutcome = nil
        } catch {
            let detail = "the journal rejected the user message: \(error.localizedDescription)"
            await recordFailure(detail)
            return .notDelivered(reason: detail)
        }
        return await dispatchPrecommitted(text, inputID: inputID, commandID: suppliedCommandID)
    }

    private func dispatchPrecommitted(
        _ text: String, inputID: String, commandID suppliedCommandID: String?
    ) async -> SessionCommandDelivery {
        guard let owner, let sessionID = sessionIDValue, !isFinished else {
            return .notDelivered(reason: "the Muse run is not accepting input")
        }
        let commandID = suppliedCommandID ?? MuseMSPSession.newCommandID()
        completedItems.removeAll()
        itemKinds.removeAll()
        earlyTerminals.removeAll()
        activeCommandID = commandID
        pendingTurn = true
        let ack: MuseMSPTurnStartAck
        do {
            ack = try await owner.connection.turnStart(
                sessionID: sessionID, commandID: commandID, text: text)
        } catch let error as MuseMSPError {
            let detail = "Muse input acknowledgement was not confirmed: \(describe(error))"
            if case .remote = error {
                activeCommandID = nil
                activeTurnID = nil
                pendingTurn = false
                await recordFailure(detail)
                return .notDelivered(reason: detail)
            }
            emit(.warning(detail))
            return .indeterminate(reason: detail)
        } catch {
            let detail = "Muse input acknowledgement was not confirmed: \(error.localizedDescription)"
            emit(.warning(detail))
            return .indeterminate(reason: detail)
        }

        activeCommandID = commandID
        guard !stopping, !isFinished else {
            return .indeterminate(reason: "Muse stopped while input acknowledgement was arriving")
        }
        activeTurnID = ack.turnID
        emit(.inputCommitted(id: inputID))
        if let early = earlyTerminals.removeValue(forKey: ack.turnID) {
            await finishTurn(terminal: early.terminal, error: early.error, params: early.params)
        }
        return .delivered(referenceID: ack.turnID)
    }

    private func startSession(connection: MuseMSPConnection) async throws -> MuseMSPSessionStart {
        if let nativeID = settings.resumingMuseSessionID {
            let resumed = try await connection.sessionResume(
                nativeID, commandID: MuseMSPSession.newCommandID(), excludeItems: true,
                expectedWorkspaceRoot: settings.cwd)
            guard resumed.pendingRequests.isEmpty,
                  resumed.session["status"]?.stringValue == "idle",
                  resumed.session["activeTurnId"]?.isNull == true else {
                throw RunError.launchFailed("Muse has unresolved requests from the previous run; automatic continuation was withheld")
            }
            return try MuseMSPSessionStart(.object([
                "session": resumed.session, "viewCursor": .string(resumed.viewCursor),
            ]))
        }
        var params: [String: JSONValue] = [
            "commandId": .string(MuseMSPSession.newCommandID()),
            "workspaceRoot": .string(settings.cwd),
        ]
        if !settings.model.isEmpty { params["modelId"] = .string(settings.model) }
        return try MuseMSPSessionStart(
            try await connection.request("session/start", params: .object(params)))
    }

    /// Ask Muse to cancel the active turn. The ACK does not finish the turn; only a matching
    /// `turn/completed` view event can produce `turnFinished` or a cancellation outcome.
    public func cancel(commandID suppliedCommandID: String? = nil) async -> SessionCommandDelivery {
        guard let owner, let sessionID = sessionIDValue, let turnID = activeTurnID,
              pendingTurn, !isFinished else { return .notAttempted }
        do {
            let ack = try await owner.connection.turnCancel(
                sessionID: sessionID, commandID: suppliedCommandID ?? MuseMSPSession.newCommandID(), turnID: turnID)
            return .delivered(referenceID: ack.turnID)
        } catch let error as MuseMSPError {
            emit(.warning("Muse cancellation acknowledgement was not confirmed: \(describe(error))"))
            if case .remote = error { return .notDelivered(reason: describe(error)) }
            return .indeterminate(reason: describe(error))
        } catch {
            emit(.warning("Muse cancellation acknowledgement was not confirmed: \(error.localizedDescription)"))
            return .indeterminate(reason: error.localizedDescription)
        }
    }

    /// Resolve one server-issued approval stage. Resolution remains pending until a matching
    /// host view event arrives; an ACK is not execution evidence.
    @discardableResult
    public func decideApproval(
        approvalID: String, requirement: MuseMSPApprovalRequirement,
        choiceID: String, feedback: String? = nil, commandID suppliedCommandID: String? = nil
    ) async throws -> MuseMSPApprovalDecisionAck {
        guard let owner, let sessionID = sessionIDValue, !isFinished,
              let pending = approvals[approvalID], pending.requirement == requirement else {
            throw MuseMSPError.invalidResponse
        }
        guard pending.choices.contains(choiceID) else { throw MuseMSPError.invalidResponse }
        return try await owner.connection.approvalDecide(
            sessionID: sessionID, approvalID: approvalID, requirement: requirement,
            choiceID: choiceID, commandID: suppliedCommandID ?? MuseMSPSession.newCommandID(), feedback: feedback)
    }

    /// Stop the host process and close the transcript. This does not invent a turn terminal.
    public func stop() async {
        guard !stopping else { return }
        stopping = true
        incomingTask?.cancel()
        incomingTask = nil
        if pendingTurn {
            await recordFailure("Muse run stopped before the active turn terminal.")
        }
        await stopOwner()
        isFinished = true
        do { try await writer.closeChecked() } catch {
            emit(.failed("The Muse session journal close was not confirmed: \(error.localizedDescription)"))
        }
        emit(.finished)
    }

    private func ingest(_ incoming: MuseMSPIncoming) async {
        switch incoming {
        case .request(let id, let method, let params):
            await ingestRequest(id: id, method: method, params: params)
        case .notification(let method, let params, _):
            if let event = try? MuseMSPViewEvent(incoming) {
                guard event.sessionID == sessionIDValue else { return }
                await ingestViewEvent(event)
            } else if method.lowercased().contains("approval"), let params,
                      params["sessionId"]?.stringValue == sessionIDValue {
                await ingestApprovalEvent(params)
            }
        }
    }

    private func ingestRequest(id: MuseMSPRequestID, method: String, params: JSONValue?) async {
        guard let params, params["sessionId"]?.stringValue == sessionIDValue,
              method.lowercased().contains("approval"),
              let pending = parseApproval(params) else {
            if let owner {
                try? await owner.connection.respond(to: id, error: MuseMSPRemoteError(
                    code: -32601, message: "Client interaction unsupported", data: nil))
            }
            await recordFailure("Muse requested an unsupported or malformed client interaction.")
            return
        }
        approvals[pending.requirement.approvalID] = pending
        emit(.approvalPending(
            requirement: pending.requirement, choices: pending.choices,
            labels: pending.labels, detail: pending.detail))
        // Deliberately leave the request unanswered. Native approval choices use the explicit
        // approval/decide command lane; no default or inferred choice is safe to send here.
        _ = id
    }

    /// Transport has already fenced the Session. Kept internal for deterministic wire fixtures.
    func ingestViewEvent(_ event: MuseMSPViewEvent) async {
        guard !stopping, !isFinished else { return }
        if event.method == "session/tokenUsage", let cumulative = event.params["cumulative"] {
            var fields = cumulative.objectValue ?? [:]
            fields["outputTokens"] = cumulative["outputTokens"]
            if let report = Self.projectUsage(.object(fields)), report != totalUsage {
                guard report.totalTokens >= totalUsage.totalTokens,
                      report.output >= totalUsage.output else {
                    emit(.warning("Muse reported a regressing cumulative usage total; the last confirmed total is retained."))
                    return
                }
                do {
                    try await writer.appendUsageSnapshot(report, source: "muse-code")
                    totalUsage = report
                    emit(.usage(report))
                } catch {
                    await recordFailure("Could not save Muse usage accounting.")
                    await stop()
                }
            }
        }
        if event.method == "item/started", let item = event.params["item"],
           let id = item["itemId"]?.stringValue, let kind = item["kind"]?.stringValue {
            itemKinds[id] = kind
            if kind == "toolCall" { await commitToolItem(item) }
        }
        if let delta = event.textDelta {
            if completedItems.contains(delta.itemID) { return }
            var buffer = messageBuffers[delta.itemID] ?? MessageBuffer(id: delta.itemID)
            switch delta.field.lowercased() {
            case "thinking", "reasoning":
                buffer.thinking += delta.delta
                emit(.thinkingDelta(delta.delta))
            case let field where field.hasPrefix("summary."):
                buffer.thinking += delta.delta
                emit(.thinkingDelta(delta.delta))
            case "text", "content", "message":
                if itemKinds[delta.itemID] == "reasoning" {
                    buffer.thinking += delta.delta
                    emit(.thinkingDelta(delta.delta))
                } else {
                    buffer.text += delta.delta
                    emit(.textDelta(delta.delta))
                }
            case "output":
                return // Tool output belongs to its result row, never an assistant message.
            default:
                emit(.warning("Muse emitted an unmodelled item delta field: \(delta.field)"))
            }
            messageBuffers[delta.itemID] = buffer
        }
        if let item = event.completedItem {
            await ingestCompletedItem(item)
        }
        if let terminal = event.turnTerminal {
            if terminal.turnID == activeTurnID {
                await finishTurn(terminal: terminal.terminal, error: terminal.error,
                                 params: event.params)
            } else if pendingTurn && activeTurnID == nil && earlyTerminals.count < 16 {
                earlyTerminals[terminal.turnID] = (
                    terminal: terminal.terminal, error: terminal.error, params: event.params)
            }
        }
        if event.method.lowercased().contains("approval") {
            await ingestApprovalEvent(event.params, terminal: event.method == "approval/resolved")
        }
    }

    private func ingestCompletedItem(_ item: JSONValue) async {
        guard let id = item["itemId"]?.stringValue, completedItems.insert(id).inserted else { return }
        let kind = (item["kind"]?.stringValue ?? item["type"]?.stringValue ?? "")
            .lowercased()
        if kind == "usermessage" { return }
        if kind.contains("approval"), let pending = parseApproval(item) {
            approvals[pending.requirement.approvalID] = pending
            emit(.approvalPending(
                requirement: pending.requirement, choices: pending.choices,
                labels: pending.labels, detail: pending.detail))
            return
        }
        if kind == "toolcall" || kind.contains("tool") || item["tool"] != nil
            || item["toolName"] != nil || item["toolCallId"] != nil {
            await commitToolItem(item)
            return
        }
        guard kind == "agentmessage" || kind == "reasoning" else {
            let summary = item["fallbackText"]?.stringValue ?? ""
            do {
                try await writer.appendNote(
                    "Muse \(kind) · \(item["status"]?.stringValue ?? "unknown"): \(summary)",
                    customType: kind == "reminderchild" ? "aviary.muse.housekeeping.v1" : "aviary.note")
            } catch {
                await recordFailure("Could not record Muse activity.")
                await stop()
            }
            return
        }
        var buffer = messageBuffers[id] ?? MessageBuffer(id: id)
        if kind == "reasoning" {
            let summary = item["summary"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n")
            buffer.text = ""
            buffer.thinking = summary?.isEmpty == false ? summary! : item["text"]?.stringValue ?? buffer.thinking
        } else {
            buffer.text = item["text"]?.stringValue ?? buffer.text
        }
        buffer.stopReason = item["stopReason"]?.stringValue
        messageBuffers[id] = buffer
        await commitMessage(id: id)
    }

    private func commitToolItem(_ item: JSONValue) async {
        let callID = item["toolCallId"]?.stringValue ?? item["callId"]?.stringValue
            ?? item["itemId"]?.stringValue ?? UUID().uuidString
        let name = item["tool"]?.stringValue ?? item["toolName"]?.stringValue
            ?? item["name"]?.stringValue ?? "muse tool"
        let status = item["status"]?.stringValue?.lowercased()
        let isResult = item["visibleOutput"] != nil || item["result"] != nil || item["output"] != nil
            || item["isError"] != nil || item["error"] != nil
            || ["completed", "failed", "rejected", "cancelled"].contains(status)
        if isResult {
            if pendingToolNames[callID] == nil {
                var callBuffer = MessageBuffer(id: callID)
                let rawArgs = item["args"]?.stringValue
                let arguments = rawArgs.flatMap { JSONValue.parse(line: $0) }
                    ?? rawArgs.map(JSONValue.string)
                    ?? item["arguments"] ?? item["input"] ?? .object([:])
                callBuffer.toolCalls.append((id: callID, name: name, arguments: arguments))
                messageBuffers[callID] = callBuffer
                pendingToolNames[callID] = name
                emit(.toolStarted(name: name))
                await commitMessage(id: callID)
                guard !stopping, !isFinished else { return }
            }
            let text = item["visibleOutput"]?.stringValue ?? item["result"]?.stringValue
                ?? item["output"]?.stringValue
                ?? item["failureReason"]?.stringValue
                ?? (item["outputRef"] != nil ? "[Output retained by Muse; not fetched in this view.]" : "[No output reported by Muse.]")
            let isError = item["isError"]?.boolValue
                ?? (item["error"] != nil || ["failed", "rejected", "cancelled"].contains(status))
            do { try await writer.appendToolResult(id: callID, name: name, text: text, isError: isError) }
            catch {
                await recordFailure("Could not record Muse tool result: \(error.localizedDescription)")
                await stop()
                return
            }
            pendingToolNames.removeValue(forKey: callID)
            emit(.toolFinished(name: name, isError: isError))
            return
        }
        guard pendingToolNames[callID] == nil else { return }
        let rawArgs = item["args"]?.stringValue
        let arguments = rawArgs.flatMap { JSONValue.parse(line: $0) }
            ?? rawArgs.map(JSONValue.string)
            ?? item["arguments"] ?? item["input"] ?? .object([:])
        var buffer = messageBuffers[callID] ?? MessageBuffer(id: callID)
        buffer.toolCalls.append((id: callID, name: name, arguments: arguments))
        messageBuffers[callID] = buffer
        pendingToolNames[callID] = name
        emit(.toolStarted(name: name))
        await commitMessage(id: callID)
    }

    private func commitMessage(id: String) async {
        guard let buffer = messageBuffers[id], buffer.hasContent else { return }
        do {
            let messageID = try await writer.appendAssistant(
                text: buffer.text, thinking: buffer.thinking, toolCalls: buffer.toolCalls,
                usage: nil, stopReason: buffer.stopReason)
            emit(.messageCommitted(id: messageID))
            messageBuffers.removeValue(forKey: id)
        } catch {
            await recordFailure("Could not record Muse message: \(error.localizedDescription)")
            await stop()
        }
    }

    private func finishTurn(terminal: String, error: JSONValue?, params: JSONValue) async {
        guard pendingTurn else { return }
        for id in messageBuffers.keys.sorted() { await commitMessage(id: id) }
        guard !stopping, !isFinished else { return }
        let normalized = terminal.lowercased()
        if normalized.contains("cancel") {
            await recordOutcome(.cancelled, detail: "Muse turn cancelled")
        } else if normalized == "failed" {
            let detail = error?.stringValue ?? "Muse turn failed."
            await recordFailure(detail)
        } else if normalized != "completed" {
            await recordFailure("Muse ended the turn with an unrecognized outcome; success is unconfirmed.")
        }
        let completedTurnID = activeTurnID ?? ""
        pendingTurn = false
        activeTurnID = nil
        activeCommandID = nil
        emit(.turnFinished(turnID: completedTurnID, terminal: terminal))
    }

    private func ingestApprovalEvent(_ params: JSONValue, terminal: Bool = false) async {
        guard let approvalID = params["approvalId"]?.stringValue else { return }
        if let pending = parseApproval(params) {
            approvals[approvalID] = pending
            emit(.approvalPending(
                requirement: pending.requirement, choices: pending.choices,
                labels: pending.labels, detail: pending.detail))
        }
        guard let choiceID = params["choiceId"]?.stringValue
            ?? params["selectedChoiceId"]?.stringValue
            ?? params["decision"]?.stringValue else { return }
        let pending = approvals.removeValue(forKey: approvalID)
        guard let pending else { return }
        emit(.approvalResolved(
            requirement: pending.requirement, choiceID: choiceID,
            terminal: terminal || params["terminal"]?.boolValue == true))
    }

    private func parseApproval(_ raw: JSONValue) -> PendingApproval? {
        guard let approvalID = raw["approvalId"]?.stringValue else { return nil }
        let requirement = raw["currentRequirementId"] ?? raw["requirementId"] ?? raw
        guard let sourceIndex = requirement["sourceIndex"]?.intValue,
              sourceIndex >= 0,
              requirement["approvalId"]?.stringValue == approvalID else { return nil }
        let choiceRows = raw["availableChoices"]?.arrayValue
            ?? raw["choices"]?.arrayValue ?? raw["options"]?.arrayValue ?? []
        let choices = choiceRows.compactMap {
            $0["choiceId"]?.stringValue ?? $0["id"]?.stringValue ?? $0.stringValue
        }
        guard !choices.isEmpty, Set(choices).count == choices.count else { return nil }
        var labels: [String: String] = [:]
        for row in choiceRows {
            guard let id = row["choiceId"]?.stringValue ?? row["id"]?.stringValue,
                  let label = row["label"]?.stringValue ?? row["displayLabel"]?.stringValue
                    ?? row["title"]?.stringValue else { continue }
            labels[id] = String(label.prefix(400))
        }
        let detail: String? = {
            func bounded(_ text: String) -> String {
                text.count <= 4000 ? text : String(text.prefix(4000)) + "\n[Details truncated; deny if the visible action is insufficient to decide.]"
            }
            if let description = raw["description"]?.stringValue { return bounded(description) }
            if let subject = raw["subject"]?.compactJSON { return bounded(subject) }
            let tool = raw["toolName"]?.stringValue
            let args = raw["rawArgs"]?.stringValue
            guard tool != nil || args != nil else { return nil }
            return bounded(([tool, args].compactMap { $0 }).joined(separator: "\n"))
        }()
        return PendingApproval(
            requirement: MuseMSPApprovalRequirement(approvalID: approvalID, sourceIndex: sourceIndex),
            choices: choices, labels: labels, detail: detail)
    }

    /// MSP cumulative prompt totals are counted once. Its raw provider input/cache counters
    /// do not declare cache inclusivity, so do not manufacture an ordinary-input breakdown.
    static func projectUsage(_ raw: JSONValue) -> Usage? {
        func count(_ key: String) -> Int? {
            guard let value = raw[key]?.intValue, value >= 0 else { return nil }
            return value
        }
        let output = count("outputTokens")
        let prompt = count("promptTokens")
        let reportedTotal = count("totalTokens")
        guard output != nil || prompt != nil || reportedTotal != nil else { return nil }
        var report = Usage()
        report.output = output ?? 0
        if let reasoning = count("reasoningTokens"), reasoning <= report.output {
            report.reasoning = reasoning
        }
        if let reportedTotal, reportedTotal >= report.output {
            report.totalTokens = reportedTotal
            report.completeness.tokenTotal = .complete
        } else if let prompt, let output, prompt <= Int.max - output {
            report.totalTokens = prompt + output
            report.completeness.tokenTotal = .complete
        } else {
            report.totalTokens = report.output
            report.completeness.tokenTotal = output == nil ? .unavailable : .lowerBound
        }
        report.completeness.breakdown = output == nil ? .unavailable : .lowerBound
        report.completeness.cost = .unavailable
        report.completeness.inputAccounting = .unknown
        return report
    }

    private func connectionEnded() async {
        incomingTask = nil
        guard !stopping, !isFinished else { return }
        if pendingTurn { await recordFailure("Muse connection ended before the active turn terminal.") }
        isFinished = true
        do { try await writer.closeChecked() } catch { }
        emit(.finished)
    }

    private func writerIsHealthy() async -> Bool {
        if case .healthy = await writer.writerHealth { return true }
        return false
    }

    private func failBeforeStart(_ detail: String) async {
        await recordFailure(detail)
        isFinished = true
        do { try await writer.closeChecked() } catch { }
        emit(.finished)
    }

    private func recordFailure(_ detail: String) async {
        let bounded = String(detail.prefix(4000))
        guard recordedOutcome == nil else {
            emit(.failed(bounded))
            return
        }
        recordedOutcome = .failed
        do { try await writer.appendOutcome(state: .failed, detail: bounded) }
        catch { }
        emit(.failed(bounded))
    }

    private func recordOutcome(_ state: TranscriptOutcome.State, detail: String) async {
        guard recordedOutcome == nil else { return }
        recordedOutcome = state
        _ = try? await writer.appendOutcome(state: state, detail: String(detail.prefix(4000)))
    }

    private func stopOwner() async {
        guard let owner else { return }
        await owner.stop()
        self.owner = nil
    }

    private func emit(_ event: Event) { observer?(event) }

    private func describe(_ error: MuseMSPError) -> String {
        switch error {
        case .remote(let remote): return remote.kind ?? remote.message
        default: return String(describing: error)
        }
    }
}
