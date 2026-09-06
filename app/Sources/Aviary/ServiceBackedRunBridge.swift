import AviaryCore
import Foundation

/// A command result that keeps the native Work-service receipt separate from the older
/// in-process SessionCommandReceipt.  In particular, the service case does not invent a local
/// command body, sequence, actor, or causal event merely to satisfy a legacy view API.
enum LiveRunCommandResult: Sendable {
    case session(SessionCommandReceipt)
    case service(WorkServiceCommandReceipt)
    case rejected(String)

    var wasHandedOff: Bool {
        switch self {
        case .session(let receipt): return receipt.wasHandedOff
        case .service(let receipt):
            return receipt.state == .accepted || receipt.state == .duplicate
        case .rejected: return false
        }
    }

    /// A Work-service acceptance is durable command ownership, but not proof that the provider
    /// has completed the action.  Treat it as queued for UI copy until canonical execution facts
    /// arrive through the projection.
    var isQueued: Bool {
        switch self {
        case .session(let receipt): return receipt.isQueued
        case .service(let receipt):
            return receipt.state == .accepted || receipt.state == .duplicate
        case .rejected: return false
        }
    }

    var detail: String? {
        switch self {
        case .session(let receipt): return receipt.delivery.detail
        case .service(let receipt): return receipt.diagnostic
        case .rejected(let message): return message
        }
    }
}

enum ServiceBackedRunBridgeError: Error, LocalizedError, Sendable {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let detail):
            return detail.isEmpty ? "The Work Host rejected the command." : detail
        }
    }
}

/// The GUI projection of one attached Work-service controller.
///
/// This is deliberately an adapter rather than another Work implementation.  The controller
/// owns the durable command identity, cursor checks, and pending-intent record; this value only
/// turns its immutable projection into the values the existing LiveRun view understands.  It
/// contains no SessionWriter, RuntimeHost, Process, or host-local workspace path, so dropping
/// this object cannot end or otherwise release Work.
@MainActor
final class ServiceBackedRunBridge {
    let controller: WorkServiceAttachedWorkController
    let work: WorkRef
    let serviceAttachmentKey: ServiceAttachmentKey
    let sessionID: String
    let workspaceID: WorkHostWorkspaceID?
    let workspaceLabel: String
    let modelLabel: String?
    let thinkingLevel: String?

    private(set) var projection: WorkServiceAttachedWorkProjection
    private(set) var lastError: String?

    init(
        controller: WorkServiceAttachedWorkController,
        projection: WorkServiceAttachedWorkProjection,
        serviceAttachmentKey: ServiceAttachmentKey,
        workspaceLabel: String,
        modelLabel: String?,
        thinkingLevel: String?
    ) {
        self.controller = controller
        self.projection = projection
        self.work = projection.descriptor.work
        self.serviceAttachmentKey = serviceAttachmentKey
        self.sessionID = projection.attachment.session?.sessionID ?? ""
        self.workspaceID = projection.descriptor.configuration.workspaceID
        self.workspaceLabel = workspaceLabel
        self.modelLabel = modelLabel
        self.thinkingLevel = thinkingLevel
    }

    var isConnected: Bool {
        switch projection.connectivity {
        case .connected: return true
        default: return false
        }
    }

    var activities: [WorkActionSnapshot] { projection.activities }
    var visibleMessages: [SessionMessageSnapshot] { projection.visibleMessages }
    /// Delivery evidence comes from the canonical Session reducer, not from a Start receipt.
    /// Read the full message history so a bounded visible-message projection cannot make an
    /// already-delivered Workshop request look undelivered after a long conversation.
    var hasCanonicalInputDelivery: Bool {
        projection.sessionSnapshot.messageHistory.contains { $0.role == "user" }
    }

    /// A first Start obligation is resolved by the exact canonical command, not by a current
    /// Run or a user message that another GUI/command may have produced. This covers a GUI dying
    /// after Start acceptance but before its local intent file was removed without consuming an
    /// unrelated bootstrap seed.
    func hasCanonicalStartEvidence(for intent: ServiceBackedStartIntent) -> Bool {
        intent.hasCanonicalEvidence(in: projection)
    }

    /// Auto-retry is safe only while the attachment minted with Create is still the attachment
    /// receiving the exact Start command. A detach/re-attach creates a new identity; keep the
    /// seed for explicit review rather than replaying it against a different Session.
    func hasMatchingStartAttachment(for intent: ServiceBackedStartIntent) -> Bool {
        intent.hasMatchingAttachment(in: projection)
    }
    var pendingCommand: WorkServiceAttachedWorkPendingCommand? {
        projection.pendingCommand
    }

    private var controlPolicy: ServiceBackedGUIControlPolicy {
        ServiceBackedGUIControlPolicy(projection: projection)
    }

    /// A retained Start may be retried while the Work has no Run owner.  Every other retained
    /// command must still belong to this exact active Session relationship; keep the repair UI
    /// disabled when a refresh observes an ownership transfer.
    var canRetryPendingCommand: Bool {
        guard let pending = projection.pendingCommand else { return false }
        return controlPolicy.canRetryPendingCommand(kind: pending.kind)
    }

    /// An active Work run is owned by exactly one Session relationship.  A descriptor that
    /// omits or mismatches that owner is safe to inspect, but must never receive text controls.
    var hasExactRunOwner: Bool {
        controlPolicy.hasExactRunOwner
    }

    /// An idle Session without a Run is a conversation ready for its first `Start`, not a
    /// settled Run ready for `Send`. The distinction comes entirely from the canonical Work
    /// projection; local message count and GUI construction time are not lifecycle evidence.
    var requiresStartForNextInput: Bool {
        controlPolicy.requiresStartForNextInput
    }

    var canSubmitText: Bool {
        controlPolicy.canSubmitText
    }

    var canEnd: Bool {
        controlPolicy.canEnd
    }

    /// Capabilities are observations from the attached Work, never assumptions made by the
    /// GUI.  The protocol currently exposes cancellation as one bounded agent-loop scope;
    /// model-stream/current-action interruption remains unavailable unless a future capability
    /// says so explicitly.
    var commandCapabilities: SessionCommandCapabilities {
        controlPolicy.commandCapabilities
    }

    /// Work execution has a richer state machine than the legacy LiveRun view.  A held or
    /// recovery-required Work must not be mapped to `.idle`, because that would offer a send
    /// control for a state the controller will correctly refuse.  `.failed` is the existing
    /// UI's non-actionable state, while `executionLabel` preserves the truthful detail.
    var commandState: SessionCommandState {
        if isTerminal { return .ended }
        if projection.needsRecovery || projection.requiresRefresh { return .failed }
        switch projection.descriptor.execution {
        case .idle: return .idle
        case .running: return .running
        case .canceling: return .canceling
        case .ending: return .ending
        case .held, .recoveryRequired, .unknown: return .failed
        }
    }

    var executionLabel: String {
        switch projection.descriptor.execution {
        case .idle: return "idle"
        case .running: return "running"
        case .held: return "held"
        case .canceling: return "canceling"
        case .ending: return "ending"
        case .recoveryRequired: return "recovery required"
        case .unknown: return "unknown"
        }
    }

    var isStreaming: Bool {
        switch projection.descriptor.execution {
        case .running, .canceling, .ending: return true
        case .idle, .held, .recoveryRequired, .unknown: return false
        }
    }

    var isTerminal: Bool {
        projection.descriptor.recordedDisposition != .reusable
            || projection.workSnapshot.lifecycle == .completed
            || projection.workSnapshot.lifecycle == .destroyed
            || projection.sessionSnapshot.lifecycle == .completed
            || projection.sessionSnapshot.lifecycle == .archived
    }

    var isEnding: Bool { projection.descriptor.execution == .ending }

    var errorBanner: String? {
        if let lastError { return lastError }
        if let pending = projection.pendingCommand {
            switch pending.state {
            case .stale:
                return "A \(pending.kind.rawValue) command is stale. Refresh canonical Work before deciding whether to abandon it and issue a new command."
            case .indeterminate:
                return "A \(pending.kind.rawValue) command has an indeterminate outcome. Refresh canonical Work and reconcile it explicitly; Aviary will not replay it automatically."
            case .awaitingCanonicalEvidence:
                return "The Work Host accepted a \(pending.kind.rawValue) command. Aviary is waiting for its exact canonical journal event and will not replay it."
            }
        }
        if projection.requiresRefresh {
            return "The Work Host acknowledged a command; the canonical journal is still catching up."
        }
        if projection.needsRecovery {
            return "This Work is visible but not safely actionable until its Work and Session state can be recovered."
        }
        return nil
    }

    /// Canonical Session messages are the only transcript source for this adapter.  Host time
    /// is preferred and missing host time remains an explicit distant-past sentinel rather than
    /// using the GUI's clock to invent ordering or completion time.
    var transcriptItems: [TranscriptItem] {
        visibleMessages.map { message in
            let role = message.role.lowercased()
            let kind: TranscriptItem.Kind = switch role {
            case "user": .user
            case "assistant", "model": .assistant
            case "tool", "action": .tool
            case "system": .stateChange
            default: .custom
            }
            var item = TranscriptItem(
                id: "canonical:\(sessionID):\(message.eventID)",
                kind: kind,
                timestamp: message.hostRecordedAt ?? .distantPast)
            item.text = message.text
            if !message.text.isEmpty { item.blocks = [.text(message.text)] }
            item.model = projection.workSnapshot.modelID ?? modelLabel
            item.customType = message.role
            return item
        }
    }

    /// Refresh failures preserve the last canonical pair and make the source problem visible.
    /// No failed read is translated into an empty transcript or a terminal Work state.
    @discardableResult
    func refresh() async -> WorkServiceAttachedWorkProjection {
        do {
            let next = try await controller.refresh()
            projection = next
            lastError = next.readDiagnostics.last
            return next
        } catch {
            let observed = await controller.projection()
            projection = observed
            lastError = Self.message(for: error, projection: observed)
            return observed
        }
    }

    func start(_ prompt: String, commandID: String? = nil) async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        if let commandID {
            return try await issue { try await self.controller.start(prompt, commandID: commandID) }
        }
        return try await issue { try await self.controller.start(prompt) }
    }

    func send(_ prompt: String) async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        return try await issue { try await self.controller.send(prompt) }
    }

    func steer(_ text: String) async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        return try await issue { try await self.controller.steer(text) }
    }

    func queue(_ text: String) async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        return try await issue { try await self.controller.queue(text) }
    }

    func cancel(scope: SessionCancellationScope) async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        return try await issue { try await self.controller.cancel(scope: scope) }
    }

    /// The only service-backed lifecycle termination operation.  Generic GUI disconnect and
    /// process termination never call this method.
    func end() async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        return try await issue { try await self.controller.end() }
    }

    private func requireExactRunOwner() throws {
        guard hasExactRunOwner else {
            throw WorkServiceAttachedWorkControllerError.recoveryRequired
        }
    }

    /// Retry the controller's one explicitly retained command, preserving its original command
    /// id, value, and causal cursor. This is a user repair action, never an automatic polling
    /// behavior.
    func retryPendingCommand() async throws -> WorkServiceCommandReceipt {
        try await issue { try await self.controller.retryPendingCommand() }
    }

    /// Abandon only a stale command after the user has seen the current canonical projection.
    /// Indeterminate commands are deliberately rejected by the controller.
    func abandonStaleCommand() async throws {
        try await controller.abandonStaleCommand()
        _ = await refresh()
    }

    private func issue(
        _ operation: @escaping () async throws -> WorkServiceCommandReceipt
    ) async throws -> WorkServiceCommandReceipt {
        do {
            let receipt = try await operation()
            guard receipt.state == .accepted || receipt.state == .duplicate else {
                let detail = receipt.diagnostic
                    ?? receipt.rejection?.rawValue
                    ?? "The Work Host rejected the command."
                _ = await refresh()
                lastError = "The Work Host rejected the command: \(detail)"
                throw ServiceBackedRunBridgeError.rejected(detail)
            }
            _ = await refresh()
            return receipt
        } catch {
            _ = await refresh()
            throw error
        }
    }

    private static func message(
        for error: Error, projection: WorkServiceAttachedWorkProjection
    ) -> String {
        if let error = error as? WorkServiceAttachedWorkControllerError {
            switch error {
            case .staleCursor:
                return "The Work Host rejected a stale command cursor. Refresh canonical Work before retrying."
            case .pendingCommandExists:
                return "A prior command is still awaiting explicit reconciliation."
            case .recoveryRequired, .sourceIncomplete, .malformedResponse:
                return "The Work Host returned incomplete or unrecoverable canonical state."
            case .terminalWork:
                return "This Work is terminal and remains available for inspection only."
            case .capabilityDenied:
                return "The attached client is not authorized for that Work operation."
            case .hostMismatch:
                return "The Work Host identity changed; this attachment is no longer safe to use."
            default:
                break
            }
        }
        if case .disconnected = projection.connectivity {
            return "The Work Host connection is disconnected; Work remains durable and can be reattached."
        }
        return "The Work Host could not provide a complete canonical projection."
    }
}
