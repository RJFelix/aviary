import SwiftUI
import AviaryCore

/// Replaceable GUI attachment. The detached Muse worker owns execution and journal writes.
@Observable @MainActor
final class MuseCodeDriver {
    struct PendingApproval: Equatable {
        let requirement: MuseMSPApprovalRequirement
        let choices: [String]
        let labels: [String: String]
        let detail: String?
        var approvalID: String { requirement.approvalID }
    }
    var items: [TranscriptItem] = []
    var isStreaming = false
    var hasExited = false
    var usage = Usage()
    var sessionID: String?
    var sessionFile: URL?
    var errorBanner: String?
    var commandNotice: RunCommandNotice?
    var initialPromptDelivered = false
    var museSessionID: String?
    var pendingApproval: PendingApproval?
    var warnings: [String] = []
    var connected = false
    var hasUnconfirmedInput = false
    var savedDraft: String?
    var draftSaveError: String?
    var resolvedInput: (submitted: String, remaining: String)?
    let identity: SessionWorkIdentity
    let commandCapabilities = SessionCommandCapabilities(cancellationScopes: [.agentLoop])
    private let home: AgentHome
    private let cwd: String
    private let model: String
    private let effort: String?
    private var writer: SessionWriter?
    private var client: MuseWorkerClient?
    private var state: SessionCommandState = .prepared
    private var launchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var disconnected = false
    private var approvalAttempt: (requirement: MuseMSPApprovalRequirement, choice: String, commandID: String)?
    private var submittingApproval = false
    private var startedAt = Date()
    private var lastRevision: UInt64?
    private var sending = false
    private var closing = false
    private var transcriptStamp: String?
    private var parsedItems: [TranscriptItem] = []

    init(home: AgentHome, cwd: String, model: String, effort: String? = nil,
         identity: SessionWorkIdentity, writer: SessionWriter) {
        self.home = home; self.cwd = cwd; self.model = model; self.effort = effort
        self.identity = identity; self.writer = writer
        sessionID = writer.sessionID; sessionFile = writer.fileURL
    }

    init(attaching client: MuseWorkerClient) {
        self.home = client.home; self.cwd = client.manifest.cwd
        self.model = client.manifest.model; self.effort = client.manifest.effort
        self.identity = client.manifest.identity; self.client = client
        self.sessionID = identity.sessionID
        self.sessionFile = home.sessionFile(id: identity.sessionID)
        do { savedDraft = try client.store.readDraft(sessionID: identity.sessionID) }
        catch { draftSaveError = "The saved Muse draft could not be read." }
    }

    func commandState() async -> SessionCommandState { state }

    func start(prompt: String) {
        guard launchTask == nil, pollTask == nil else { return }
        isStreaming = client == nil
        launchTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let writer {
                    let inputID = prompt.isEmpty ? nil : try await writer.appendUser(prompt)
                    try await writer.closeChecked()
                    self.writer = nil
                    let manifest = MuseWorkerManifest(identity: identity, cwd: cwd, model: model,
                        effort: effort, title: String(prompt.prefix(120)), initialPrompt: prompt,
                        initialInputID: inputID)
                    let client = try MuseWorkerClient.reserve(home: home, manifest: manifest)
                    self.client = client
                    if let savedDraft { try client.store.writeDraft(sessionID: identity.sessionID, text: savedDraft) }
                    try client.launch()
                }
                await refresh()
                if !disconnected { beginPolling() }
            } catch {
                if let writer { try? await writer.closeChecked(); self.writer = nil }
                errorBanner = "Could not connect Muse: \(error.localizedDescription)"
                isStreaming = false; hasExited = true; state = .failed
                await reloadTranscript(snapshot: nil)
            }
        }
    }

    private func beginPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.disconnected else { break }
                await self.refresh()
                if self.hasExited { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func refresh() async {
        guard let client else { return }
        do {
            try reconcileInput(client)
            let snapshot = try client.snapshot()
            let owned = client.isOwned
            guard let snapshot else {
                if !owned && Date().timeIntervalSince(startedAt) > 15 { throw MuseWorkerClient.Error.unavailable }
                await reloadTranscript(snapshot: nil)
                return
            }
            guard owned || snapshot.isTerminal else { throw MuseWorkerClient.Error.unavailable }
            guard snapshot.isTerminal || Date().timeIntervalSince(snapshot.observedAt) < 10 else {
                throw MuseWorkerClient.Error.unresponsive
            }
            connected = owned; hasExited = snapshot.isTerminal; state = snapshot.commandState
            isStreaming = [.starting, .working, .canceling, .ending].contains(snapshot.state)
            initialPromptDelivered = snapshot.initialPromptDelivered; museSessionID = snapshot.museSessionID
            errorBanner = snapshot.error
            if let notice = snapshot.notice { commandNotice = .warning(notice) }
            if let approval = snapshot.approval {
                pendingApproval = .init(requirement: approval.requirement, choices: approval.choices,
                    labels: approval.labels, detail: approval.detail)
            } else { pendingApproval = nil }
            usage = snapshot.usage
            let unsettled = try client.store.pendingCommands(sessionID: identity.sessionID,
                expectedInstanceID: client.manifest.instanceID)
            let pendingSend = try unsettled.contains {
                try MuseWorkerCodec.unpack(MuseWorkerRequest.self, $0.request).operation == .send
            }
            hasUnconfirmedInput = hasUnconfirmedInput || pendingSend
            if lastRevision != snapshot.revision {
                lastRevision = snapshot.revision
                await reloadTranscript(snapshot: snapshot)
            }
        } catch {
            connected = false; isStreaming = false; state = .failed
            // Ownership, not a stale PID or heartbeat, decides whether execution is gone.
            hasExited = !client.isOwned
            errorBanner = error.localizedDescription; pendingApproval = nil
            await reloadTranscript(snapshot: nil)
        }
    }

    private func reloadTranscript(snapshot: MuseWorkerSnapshot?) async {
        guard let sessionFile else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: sessionFile.path)
        let stamp = "\(attributes?[.size] ?? 0):\(attributes?[.modificationDate] ?? "")"
        if stamp != transcriptStamp {
            let parsed = await Task.detached(priority: .userInitiated) { SessionParser.parse(fileURL: sessionFile) }.value
            guard !disconnected, let parsed else { return }
            parsedItems = parsed.items
            transcriptStamp = stamp
            if snapshot == nil { usage = parsed.usage }
        }
        var next = parsedItems
        if let snapshot, !snapshot.streamText.isEmpty || !snapshot.streamThinking.isEmpty,
           let current = try? client?.snapshot(), current.streamID == snapshot.streamID {
            var live = TranscriptItem(id: "muse-stream-\(snapshot.streamID)", kind: .assistant, timestamp: snapshot.observedAt)
            if !snapshot.streamThinking.isEmpty { live.blocks.append(.thinking(snapshot.streamThinking)) }
            if !snapshot.streamText.isEmpty { live.blocks.append(.text(snapshot.streamText)) }
            if snapshot.streamTruncated { live.blocks.append(.text("\n[Live preview limited; full output appears when recorded.]")) }
            next.append(live)
        }
        items = next
    }

    func send(_ prompt: String, sourceID: String? = nil) async -> LiveRunCommandResult {
        await refresh()
        guard !closing, !sending, !hasUnconfirmedInput else {
            return .unconfirmed("The previous message is still awaiting confirmation. Check delivery before sending another.")
        }
        sending = true
        defer { sending = false }
        return await issue(.init(.send, text: prompt))
    }

    func cancel(scope: SessionCancellationScope, sourceID: String? = nil) async -> LiveRunCommandResult {
        guard scope == .agentLoop else {
            return .rejected("Muse supports cancellation of the current agent turn only.")
        }
        return await issue(.init(.cancel))
    }

    private func issue(_ request: MuseWorkerRequest) async -> LiveRunCommandResult {
        let id = MuseMSPSession.newCommandID()
        guard let client, connected, !disconnected else {
            return .rejected("The Muse worker is not connected. No command was submitted.")
        }
        do {
            if request.operation == .send, let text = request.text {
                try client.store.writeHandoff(sessionID: identity.sessionID, commandID: id,
                    instanceID: client.manifest.instanceID, text: text)
                savedDraft = text
                hasUnconfirmedInput = true
            }
            let reply = try await client.request(request, commandID: id)
            await refresh()
            if let receipt = reply.receipt { return .session(receipt) }
            commandNotice = .warning(reply.error ?? "The worker did not confirm this command.")
        } catch { commandNotice = .warning(error.localizedDescription) }
        if request.operation == .send { hasUnconfirmedInput = true }
        return .unconfirmed("The command outcome is not confirmed. Check delivery; the saved attempt will not be resubmitted.")
    }

    private func reconcileInput(_ client: MuseWorkerClient) throws {
        let draft = try client.store.readDraftRecord(sessionID: identity.sessionID)
        guard let handoff = draft?.handoff else { hasUnconfirmedInput = false; return }
        hasUnconfirmedInput = true
        guard handoff.instanceID == client.manifest.instanceID,
              let command = try? client.store.command(sessionID: identity.sessionID,
                expectedInstanceID: handoff.instanceID, commandID: handoff.commandID),
              let raw = command.receipt else { return }
        let reply = try MuseWorkerCodec.unpack(MuseWorkerReply.self, raw)
        guard let receipt = reply.receipt else { return }
        let accepted = receipt.wasHandedOff
        if case .indeterminate = receipt.delivery { return }
        guard accepted || !receipt.wasAdmitted || {
            if case .notDelivered = receipt.delivery { return true }; return false
        }() else { return }
        let resolved = try client.store.resolveHandoff(sessionID: identity.sessionID,
            expectedCommandID: handoff.commandID, accepted: accepted)
        savedDraft = resolved?.text ?? ""
        resolvedInput = (handoff.text, savedDraft ?? "")
        hasUnconfirmedInput = false
    }

    @discardableResult
    func decideApproval(approvalID: String, requirement: MuseMSPApprovalRequirement,
                        choiceID: String, feedback: String? = nil) async -> Bool {
        guard let client, !submittingApproval, let pendingApproval,
              pendingApproval.approvalID == approvalID, pendingApproval.requirement == requirement,
              pendingApproval.choices.contains(choiceID) else { return false }
        do {
            for command in try client.store.pendingCommands(sessionID: identity.sessionID,
                expectedInstanceID: client.manifest.instanceID) {
                let request = try MuseWorkerCodec.unpack(MuseWorkerRequest.self, command.request)
                if request.operation == .approve, request.requirement == requirement,
                   let priorChoice = request.choiceID {
                    approvalAttempt = (requirement, priorChoice, command.commandID)
                    break
                }
            }
        } catch { commandNotice = .warning("The saved approval attempt could not be checked."); return false }
        if let attempt = approvalAttempt, attempt.requirement == requirement, attempt.choice != choiceID {
            commandNotice = .warning("The previous decision may already have reached Muse. Check its outcome first.")
            return false
        }
        let id = approvalAttempt?.requirement == requirement ? approvalAttempt!.commandID : MuseMSPSession.newCommandID()
        approvalAttempt = (requirement, choiceID, id); submittingApproval = true
        defer { submittingApproval = false }
        do {
            let reply = try await client.request(.init(.approve, requirement: requirement, choiceID: choiceID), commandID: id)
            await refresh()
            if reply.approvalAccepted == true { return true }
            commandNotice = .warning(reply.error ?? "Muse did not confirm that decision.")
        } catch { commandNotice = .warning(error.localizedDescription) }
        return false
    }

    /// Explicit End only. Application quit calls disconnect(), never this method.
    func stop() async {
        await launchTask?.value
        guard !hasExited else { return }
        for _ in 0..<150 where !connected && !hasExited {
            await refresh()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = await issue(.init(.end))
        for _ in 0..<50 {
            await refresh()
            if hasExited { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func disconnect() async {
        await launchTask?.value
        disconnected = true; pollTask?.cancel(); pollTask = nil; connected = false
    }

    @discardableResult func saveDraft(_ text: String) -> Bool {
        savedDraft = text
        guard let client else { return false }
        do {
            try client.store.writeDraft(sessionID: identity.sessionID, text: text)
            draftSaveError = nil
            return true
        } catch { draftSaveError = "The Muse draft could not be saved. Copy it before closing Aviary."; return false }
    }

    func flushDraft(_ text: String) async -> Bool {
        await launchTask?.value
        while sending { try? await Task.sleep(nanoseconds: 50_000_000) }
        if let client { try? reconcileInput(client) }
        let durableText = resolvedInput?.submitted == text ? (resolvedInput?.remaining ?? text) : text
        return saveDraft(durableText)
    }

    func freezeComposer() { closing = true }
    func resumeComposer() { closing = false }
    func waitForCommands() async {
        while sending || submittingApproval { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    /// User acknowledgment only; never retries or claims the old input did not execute.
    func acknowledgeUnknownInput() {
        guard !sending, hasExited, let client, !client.isOwned else { return }
        do {
            if let handoff = try client.store.readDraftRecord(sessionID: identity.sessionID)?.handoff {
                _ = try client.store.resolveHandoff(sessionID: identity.sessionID,
                    expectedCommandID: handoff.commandID, accepted: false)
            }
            hasUnconfirmedInput = false
        } catch { draftSaveError = "The saved attempt could not be acknowledged. Your draft is unchanged." }
    }
}
