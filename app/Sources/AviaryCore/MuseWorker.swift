import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

#if os(macOS)
/// The hosted-engine lane deliberately does not pretend to be an in-house Python Work.
/// One detached aviaryd process owns one Muse session; all GUIs are replaceable observers.
public struct MuseWorkerManifest: Codable, Sendable {
    public var schemaVersion = 1
    public var identity: SessionWorkIdentity
    public var instanceID: String
    public var cwd: String
    public var model: String
    public var effort: String?
    public var title: String
    public var initialPrompt: String
    public var initialInputID: String?
    public var museSessionID: String?
    public var startCommandID: String
    public var resuming: Bool
    public var createdAt: Date

    public init(identity: SessionWorkIdentity, cwd: String, model: String, effort: String?,
                title: String, initialPrompt: String, initialInputID: String?) {
        self.identity = identity
        self.instanceID = UUID().uuidString
        self.cwd = cwd
        self.model = model
        self.effort = effort
        self.title = title
        self.initialPrompt = initialPrompt
        self.initialInputID = initialInputID
        self.startCommandID = MuseMSPSession.newCommandID()
        self.resuming = false
        self.createdAt = Date()
    }
}

public struct MuseWorkerApproval: Codable, Sendable, Equatable {
    public var requirement: MuseMSPApprovalRequirement
    public var choices: [String]
    public var labels: [String: String]
    public var detail: String?
}

public struct MuseWorkerSnapshot: Codable, Sendable {
    public enum State: String, Codable, Sendable { case starting, idle, working, canceling, ending, ended, failed }
    public var instanceID: String
    public var sessionID: String
    public var state: State = .starting
    public var commandState: SessionCommandState = .prepared
    public var observedAt = Date()
    public var revision: UInt64 = 0
    public var museSessionID: String?
    public var initialPromptDelivered = false
    public var usage = Usage()
    public var approval: MuseWorkerApproval?
    public var activeCommandID: String?
    public var activeTurnID: String?
    public var streamID = UUID().uuidString
    public var streamText = ""
    public var streamThinking = ""
    public var streamTruncated = false
    public var error: String?
    public var notice: String?
    public var isTerminal: Bool { state == .ended || state == .failed }

    public init(instanceID: String, sessionID: String) {
        self.instanceID = instanceID
        self.sessionID = sessionID
    }
}

public struct MuseWorkerRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case start, send, cancel, approve, end }
    public var operation: Operation
    public var text: String?
    public var requirement: MuseMSPApprovalRequirement?
    public var choiceID: String?
    public init(_ operation: Operation, text: String? = nil,
                requirement: MuseMSPApprovalRequirement? = nil, choiceID: String? = nil) {
        self.operation = operation
        self.text = text
        self.requirement = requirement
        self.choiceID = choiceID
    }
}

public struct MuseWorkerReply: Codable, Sendable {
    public var receipt: SessionCommandReceipt?
    public var approvalAccepted: Bool?
    public var error: String?
    public init(receipt: SessionCommandReceipt? = nil, approvalAccepted: Bool? = nil, error: String? = nil) {
        self.receipt = receipt
        self.approvalAccepted = approvalAccepted
        self.error = error
    }
}

/// A JSON string inside the extensible store envelope preserves exact integer Usage fields.
public enum MuseWorkerCodec {
    public static func pack<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return .string(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
    public static func unpack<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        guard let string = value.stringValue else { throw MuseWorkerStore.Error.corruptStore }
        return try JSONDecoder().decode(type, from: Data(string.utf8))
    }
}

/// The only owner of a hosted Muse transcript, controller, and native child. No GUI connection
/// participates in its lifetime. The owner lock stays held until child stop and writer close.
public actor MuseWorker {
    private let home: AgentHome
    private let store: MuseWorkerStore
    private var manifest: MuseWorkerManifest
    private var snapshot: MuseWorkerSnapshot
    private var run: MuseCodeRun?
    private var controller: SessionCommandController?
    private var eventTask: Task<Void, Never>?
    private var continuation: AsyncStream<MuseCodeRun.Event>.Continuation?
    private var activeCommand: String?
    private var cancelCommand: String?
    private var preparation: Task<Void, Never>?
    private var ending = false
    private var overflowed = false
    private var lastSnapshotPublishAt: Date?

    private init(home: AgentHome, manifest: MuseWorkerManifest) {
        self.home = home
        self.store = MuseWorkerStore(homeRoot: home.root)
        self.manifest = manifest
        self.snapshot = MuseWorkerSnapshot(instanceID: manifest.instanceID, sessionID: manifest.identity.sessionID)
    }

    public static func runIfRequested(arguments: [String]) async -> Int32? {
        guard let index = arguments.firstIndex(of: "--muse-worker") else { return nil }
        guard index + 3 < arguments.count else { return 2 }
        let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let sessionID = arguments[index + 2]
        let home = AgentHome(root: root)
        let store = MuseWorkerStore(homeRoot: root)
        do {
            let record = try store.loadManifest(sessionID: sessionID)
            let manifest = try MuseWorkerCodec.unpack(MuseWorkerManifest.self, record.manifest)
            guard manifest.schemaVersion == 1, manifest.identity.sessionID == sessionID,
                  manifest.instanceID == record.instanceID,
                  manifest.instanceID == arguments[index + 3] else { return 2 }
            let lease = try store.acquireOwner(sessionID: sessionID, instanceID: record.instanceID)
            // Keep the descriptor alive across every suspension, including End's child join.
            defer { withExtendedLifetime(lease) {} }
            let worker = MuseWorker(home: home, manifest: manifest)
            #if canImport(Darwin)
            let priorSIGTERMHandler = signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
            termination.setEventHandler { Task<Void, Never> { await worker.requestStop() } }
            termination.resume()
            defer {
                termination.cancel()
                _ = signal(SIGTERM, priorSIGTERMHandler)
            }
            #endif
            await worker.serve()
            return 0
        } catch { return 1 }
    }

    private func serve() async {
        do {
            // A dispatched marker from a dead owner can never become a fresh dispatch.
            let start = try store.command(sessionID: manifest.identity.sessionID,
                expectedInstanceID: manifest.instanceID, commandID: manifest.startCommandID)
            guard start.stage == .pending else {
                throw MuseWorkerStore.Error.invalidCommandTransition
            }
            try validateTranscriptIdentity()
            if manifest.resuming,
               let priorSummary = SessionCatalog.summarize(fileURL: home.sessionFile(id: manifest.identity.sessionID)) {
                // Until Muse reports its cumulative total for the resumed native session,
                // keep the last confirmed transcript usage visible to observers.
                snapshot.usage = priorSummary.usage
            }
            try publish()
            let writer: SessionWriter
            if manifest.resuming {
                writer = try SessionWriter(home: home, resuming: manifest.identity.sessionID,
                    cwd: manifest.cwd, model: MuseCode.modelSpec(for: manifest.model), identity: manifest.identity)
            } else {
                // The GUI created and closed the initial projection before publishing the
                // manifest; exclusive ownership proves this producer-to-worker handoff.
                writer = try SessionWriter(home: home,
                    reopeningWithoutRunBoundary: manifest.identity.sessionID, identity: manifest.identity)
            }
            let controller = SessionCommandController(identity: manifest.identity,
                capabilities: .init(cancellationScopes: [.agentLoop]), writer: writer)
            self.controller = controller
            let run = MuseCodeRun(settings: .init(home: home, cwd: manifest.cwd,
                model: manifest.model, effort: manifest.effort, identity: manifest.identity,
                resumingMuseSessionID: manifest.resuming ? manifest.museSessionID : nil,
                sessionReady: { [weak self] id in
                    guard let self else { throw MuseMSPError.invalidResponse }
                    try await self.retainNativeSession(id)
                }), writer: writer)
            self.run = run
            let (events, continuation) = AsyncStream<MuseCodeRun.Event>.makeStream(bufferingPolicy: .bufferingOldest(512))
            self.continuation = continuation
            await run.observe { [weak self] event in
                if case .dropped = continuation.yield(event) {
                    Task<Void, Never> {
                        guard let self else { return }
                        await self.eventOverflow()
                    }
                }
            }
            eventTask = Task<Void, Never> { [weak self] in
                guard let self else { return }
                for await event in events { await self.ingest(event) }
            }
            preparation = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.process(start)
            }
            while !ending && !snapshot.isTerminal {
                for command in try store.pendingCommands(sessionID: manifest.identity.sessionID,
                    expectedInstanceID: manifest.instanceID) where command.commandID != manifest.startCommandID {
                    await process(command)
                    if ending { break }
                }
                try publish(force: false)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            if !ending {
                snapshot.error = "The Muse worker could not safely continue: \(error.localizedDescription)"
                setState(.failed)
            }
        }
        ending = true
        if !snapshot.isTerminal { setState(.ending) }
        await run?.stop()
        await preparation?.value
        continuation?.finish()
        await eventTask?.value
        snapshot.approval = nil
        snapshot.streamText = ""
        snapshot.streamThinking = ""
        activeCommand = nil
        cancelCommand = nil
        snapshot.activeCommandID = nil
        snapshot.activeTurnID = nil
        if snapshot.state != .failed {
            setState(.ended)
            snapshot.commandState = .ended
        }
        try? publish()
    }

    private func requestStop() async {
        guard !ending else { return }
        ending = true
        if !snapshot.isTerminal { setState(.ending) }
        try? publish()
        await run?.stop()
    }

    private func retainNativeSession(_ id: String) throws {
        guard !ending, !id.isEmpty, id.utf8.count <= 1024 else { throw MuseMSPError.invalidResponse }
        if let prior = manifest.museSessionID, prior != id { throw MuseMSPError.invalidResponse }
        manifest.museSessionID = id
        try store.updateManifest(sessionID: manifest.identity.sessionID,
            expectedInstanceID: manifest.instanceID, manifest: MuseWorkerCodec.pack(manifest))
        snapshot.museSessionID = id
        try publish()
    }

    /// SessionWriter opens its file for append, so check the identity-bearing path before
    /// either writer initializer can mutate it. Initial handoff requires the exact run;
    /// a deliberate resume keeps the session/work identity and allocates a new run.
    private func validateTranscriptIdentity() throws {
        let url = home.sessionFile(id: manifest.identity.sessionID)
        var metadata = stat()
        let result = url.path.withCString { lstat($0, &metadata) }
        guard result == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              let recovered = SessionWriter.recoverIdentity(
                home: home, sessionID: manifest.identity.sessionID),
              recovered.sessionID == manifest.identity.sessionID,
              recovered.workHostID == manifest.identity.workHostID,
              recovered.workID == manifest.identity.workID else {
            throw MuseWorkerStore.Error.corruptStore
        }
        guard !manifest.resuming else { return }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
              let header = JSONValue.parse(Data(line)),
              header["type"]?.stringValue == "session",
              header["id"]?.stringValue == manifest.identity.sessionID,
              header["runId"]?.stringValue == manifest.identity.runID else {
            throw MuseWorkerStore.Error.corruptStore
        }
    }

    private func publish(force: Bool = true) throws {
        let now = Date()
        if !force, let lastSnapshotPublishAt {
            let heartbeat: TimeInterval = [.starting, .working, .canceling, .ending].contains(snapshot.state)
                ? 0.25 : 1.0
            guard now.timeIntervalSince(lastSnapshotPublishAt) >= heartbeat else { return }
        }
        snapshot.observedAt = now
        snapshot.revision &+= 1
        try store.writeSnapshot(sessionID: manifest.identity.sessionID,
            expectedInstanceID: manifest.instanceID, snapshot: MuseWorkerCodec.pack(snapshot))
        lastSnapshotPublishAt = now
    }

    /// Ending is a one-way transition. A late start/event result may update receipts, but
    /// cannot make an ended worker appear idle or working again.
    private func setState(_ state: MuseWorkerSnapshot.State) {
        guard !snapshot.isTerminal else { return }
        if ending && state != .ended { return }
        snapshot.state = state
    }

    private func process(_ stored: MuseWorkerStore.Command) async {
        guard !ending, let controller, let run else { return }
        var didMarkDispatched = false
        do {
            let request = try MuseWorkerCodec.unpack(MuseWorkerRequest.self, stored.request)
            guard request.text.map({ $0.utf8.count <= 512 * 1024 }) ?? true else {
                throw MuseWorkerStore.Error.payloadTooLarge
            }
            // This write precedes admission's journal append and every native RPC effect.
            _ = try store.markDispatched(sessionID: manifest.identity.sessionID,
                expectedInstanceID: manifest.instanceID, commandID: stored.commandID)
            didMarkDispatched = true
            if request.operation == .approve {
                guard let requirement = request.requirement, let choice = request.choiceID,
                      snapshot.approval?.requirement == requirement,
                      snapshot.approval?.choices.contains(choice) == true else { throw MuseMSPError.invalidResponse }
                _ = try await run.decideApproval(approvalID: requirement.approvalID,
                    requirement: requirement, choiceID: choice, commandID: stored.commandID)
                try settle(stored.commandID, MuseWorkerReply(approvalAccepted: true))
                return
            }
            let command: SessionCommand
            switch request.operation {
            case .start:
                guard stored.commandID == manifest.startCommandID else { throw MuseMSPError.invalidResponse }
                command = .start(prompt: manifest.resuming ? "" : manifest.initialPrompt)
            case .send: command = .send(prompt: request.text ?? "")
            case .cancel: command = .cancel(scope: .agentLoop)
            case .end: command = .endRun
            case .approve: return
            }
            let admission = await controller.admitAndCommit(command, actorID: "muse-worker", commandID: stored.commandID)
            guard case .accepted = admission else {
                try settle(stored.commandID, MuseWorkerReply(receipt: .init(admission: admission)))
                return
            }
            guard await controller.awaitDispatch(commandID: stored.commandID) != nil else { throw MuseMSPError.invalidResponse }
            _ = await controller.acknowledgeDispatched(commandID: stored.commandID)
            var delivery: SessionCommandDelivery
            switch request.operation {
            case .start:
                activeCommand = stored.commandID
                snapshot.activeCommandID = stored.commandID
                try await run.start(prompt: manifest.resuming ? "" : manifest.initialPrompt,
                    firstCommandID: stored.commandID, precommittedInputID: manifest.resuming ? nil : manifest.initialInputID)
                _ = await controller.acknowledgePreparation(commandID: stored.commandID)
                if !ending && !snapshot.isTerminal && (manifest.resuming || manifest.initialPrompt.isEmpty) {
                    _ = await controller.acknowledgeTurnFinished(commandID: stored.commandID)
                    snapshot.initialPromptDelivered = manifest.resuming
                    setState(.idle)
                    activeCommand = nil
                    snapshot.activeCommandID = nil
                }
                delivery = .delivered(referenceID: await run.museSessionID)
            case .send:
                guard !ending && !snapshot.isTerminal else { throw MuseMSPError.canceledLocally }
                activeCommand = stored.commandID
                snapshot.activeCommandID = stored.commandID
                setState(.working)
                snapshot.error = nil
                resetStream()
                delivery = await run.send(request.text ?? "", commandID: stored.commandID)
                switch delivery {
                case .notDelivered(let detail):
                    _ = await controller.acknowledgeTurnFinished(commandID: stored.commandID)
                    activeCommand = nil
                    snapshot.activeCommandID = nil
                    if !ending { setState(.idle) }
                    snapshot.notice = "Muse did not accept this message: \(String(detail.prefix(1800)))"
                case .indeterminate(let detail):
                    _ = await controller.markFailed(commandID: stored.commandID)
                    activeCommand = nil
                    snapshot.activeCommandID = nil
                    snapshot.error = "Muse may have accepted this message, but its acknowledgement was lost. The worker stopped without retrying it: \(String(detail.prefix(1600)))"
                    setState(.failed)
                    ending = true
                    await run.stop()
                case .notAttempted:
                    _ = await controller.acknowledgeTurnFinished(commandID: stored.commandID)
                    activeCommand = nil
                    snapshot.activeCommandID = nil
                    if !ending { setState(.idle) }
                    snapshot.notice = "Muse did not attempt this message. You can send it again."
                case .queued, .delivered:
                    break
                }
            case .cancel:
                cancelCommand = stored.commandID
                setState(.canceling)
                delivery = await run.cancel(commandID: stored.commandID)
                if case .notAttempted = delivery {
                    // A turn can finish between admission and the worker's Cancel RPC. Let its
                    // terminal event reconcile first; otherwise retry only this non-sent effect.
                    for _ in 0..<10 where cancelCommand == stored.commandID && !ending {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        delivery = await run.cancel(commandID: stored.commandID)
                        if case .notAttempted = delivery { continue }
                        break
                    }
                }
                if cancelCommand == stored.commandID {
                    switch delivery {
                    case .notAttempted, .notDelivered:
                        cancelCommand = nil
                        _ = await controller.markFailed(commandID: stored.commandID)
                        activeCommand = nil
                        snapshot.activeCommandID = nil
                        snapshot.error = "Muse could not confirm cancellation. The worker stopped rather than leaving a stale cancel state."
                        setState(.failed)
                        ending = true
                        await run.stop()
                    case .indeterminate(let detail):
                        snapshot.notice = "Cancellation delivery is uncertain; waiting for Muse's turn status. \(String(detail.prefix(1200)))"
                    case .queued, .delivered:
                        break
                    }
                }
            case .end:
                ending = true
                setState(.ending)
                try publish()
                await run.stop()
                _ = await controller.acknowledgeEnd(commandID: stored.commandID)
                snapshot.commandState = await controller.state
                setState(.ended)
                delivery = .delivered(referenceID: nil)
            case .approve: return
            }
            if delivery.isDelivered, request.operation == .start || request.operation == .send {
                _ = await controller.recordDelivered(commandID: stored.commandID)
            }
            snapshot.commandState = await controller.state
            try settle(stored.commandID, MuseWorkerReply(receipt: .init(admission: admission, delivery: delivery)))
            try publish()
        } catch {
            // No automatic redispatch after this point, even if the receipt could not be stored.
            if !didMarkDispatched {
                if !ending {
                    snapshot.commandState = .failed
                    snapshot.error = "Muse could not persist command dispatch; the worker stopped without attempting it."
                    setState(.failed)
                    ending = true
                }
            } else {
                try? settle(stored.commandID, MuseWorkerReply(error: "Muse command outcome is not confirmed: \(error.localizedDescription)"))
                if stored.commandID == manifest.startCommandID {
                    if !ending {
                        snapshot.commandState = .failed
                        snapshot.error = "Muse startup was not confirmed: \(error.localizedDescription)"
                        setState(.failed)
                    }
                } else {
                    snapshot.notice = "Command delivery needs checking; this attempt will not be sent again automatically."
                }
            }
            try? publish()
        }
    }

    private func settle(_ id: String, _ reply: MuseWorkerReply) throws {
        _ = try store.settleCommand(sessionID: manifest.identity.sessionID,
            expectedInstanceID: manifest.instanceID, commandID: id, receipt: MuseWorkerCodec.pack(reply))
    }

    private func resetStream() {
        snapshot.streamID = UUID().uuidString
        snapshot.streamText = ""
        snapshot.streamThinking = ""
        snapshot.streamTruncated = false
    }

    private func appendBounded(_ text: String, thinking: Bool) {
        let limit = 64 * 1024
        let prior = thinking ? snapshot.streamThinking : snapshot.streamText
        let joined = prior + text
        let bounded = String(joined.prefix(limit))
        if thinking { snapshot.streamThinking = bounded } else { snapshot.streamText = bounded }
        snapshot.streamTruncated = snapshot.streamTruncated || joined.count > limit
    }

    private func ingest(_ event: MuseCodeRun.Event) async {
        guard let controller, !ending, !snapshot.isTerminal else { return }
        switch event {
        case .started: break
        case .museSession(let id): snapshot.museSessionID = id
        case .inputCommitted:
            snapshot.initialPromptDelivered = true
            snapshot.state = .working
            if let activeCommand { _ = await controller.recordDelivered(commandID: activeCommand) }
        case .textDelta(let text): appendBounded(text, thinking: false)
        case .thinkingDelta(let text): appendBounded(text, thinking: true)
        case .messageCommitted: resetStream()
        case .toolStarted, .toolFinished: break
        case .usage(let usage): snapshot.usage = usage
        case .approvalPending(let requirement, let choices, let labels, let detail):
            snapshot.approval = .init(requirement: requirement, choices: choices, labels: labels, detail: detail)
        case .approvalResolved(let requirement, _, _):
            if snapshot.approval?.requirement == requirement { snapshot.approval = nil }
        case .turnFinished(_, let terminal):
            if let cancelCommand {
                if terminal == "failed" {
                    _ = await controller.markFailed(commandID: cancelCommand)
                    snapshot.error = "Muse turn failed before cancellation was confirmed."
                    setState(.failed)
                } else {
                    _ = await controller.acknowledgeCancellation(commandID: cancelCommand)
                }
                self.cancelCommand = nil
            } else if let activeCommand {
                if terminal == "completed" || terminal == "cancelled" {
                    _ = await controller.acknowledgePreparation(commandID: activeCommand)
                    _ = await controller.acknowledgeTurnFinished(commandID: activeCommand)
                } else {
                    _ = await controller.markFailed(commandID: activeCommand)
                    snapshot.error = "Muse ended the turn without confirming success."
                    setState(.failed)
                }
            }
            activeCommand = nil
            snapshot.activeCommandID = nil
            snapshot.activeTurnID = nil
            snapshot.approval = nil
            if !snapshot.isTerminal { setState(.idle) }
            if terminal == "cancelled" { snapshot.notice = "Muse confirmed the turn was cancelled." }
            resetStream()
        case .warning(let text): snapshot.notice = String(text.prefix(2000))
        case .failed(let text):
            snapshot.error = String(text.prefix(2000))
            // A provider error can end a turn without ending the host. The host terminal will
            // restore idle; a lost connection follows with .finished and remains failed.
        case .finished:
            if !ending {
                setState(.failed)
                snapshot.error = snapshot.error ?? "Muse stopped. Its saved conversation can be resumed."
            }
        }
        snapshot.commandState = await controller.state
        try? publish()
    }

    private func eventOverflow() async {
        guard !overflowed else { return }
        overflowed = true
        snapshot.error = "Muse events exceeded the bounded worker queue. Execution was stopped; inspect the saved transcript before resuming."
        snapshot.state = .failed
        await run?.stop()
    }
}
#endif
