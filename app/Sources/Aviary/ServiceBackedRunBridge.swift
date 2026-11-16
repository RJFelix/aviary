import AviaryCore
import Foundation

/// A command result that keeps the native Work-service receipt separate from the older
/// in-process SessionCommandReceipt.  In particular, the service case does not invent a local
/// command body, sequence, actor, or causal event merely to satisfy a legacy view API.
enum LiveRunCommandResult: Sendable {
    case session(SessionCommandReceipt)
    case service(WorkServiceCommandReceipt)
    case rejected(String)
    case unconfirmed(String)

    var wasHandedOff: Bool {
        switch self {
        case .session(let receipt): return receipt.wasHandedOff
        case .service(let receipt):
            return receipt.state == .accepted || receipt.state == .duplicate
        case .rejected, .unconfirmed: return false
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
        case .rejected, .unconfirmed: return false
        }
    }

    var detail: String? {
        switch self {
        case .session(let receipt): return receipt.delivery.detail
        case .service(let receipt): return receipt.diagnostic
        case .rejected(let message), .unconfirmed(let message): return message
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

enum ServiceBackedRunBridgeFailureCertainty: Equatable, Sendable {
    case rejected
    case uncertain
}

/// Presentation-safe outcomes for the on-demand repository review read. The GUI deliberately
/// does not expose transport diagnostics, host paths, or storage details from the Work service.
enum RepositoryReviewLoadError: Error, Equatable, Sendable {
    case stale
    case unavailable
    case bounded
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
    private(set) var inputDeliveryProjection: CanonicalInputDeliveryProjection
    private(set) var history: WorkServiceConversationHistoryWindow
    private(set) var historyError: String?
    private(set) var lastError: String?
    private(set) var directShellEntries: [WorkServiceDirectShellEntry] = []
    private(set) var directShellError: String?
    private var directShellReadCursor: JournalCursor?
    private var startPresentationGrace: ServiceBackedStartPresentationGrace?
    private var startPresentationExpiryTask: Task<Void, Never>?
    private var startPresentationGeneration = 0
    var onPresentationChange: (@MainActor () -> Void)?

    var supportsDirectShell: Bool {
        projection.capabilities.contains(.directShell)
            && projection.descriptor.currentRunSession?.sessionID == sessionID
    }

    var canRunDirectShell: Bool {
        controlPolicy.canRunDirectShell
    }

    @discardableResult
    func directShell(operation: WorkServiceDirectShellOperation,
                     language: DirectShellLanguage? = nil, source: Data? = nil,
                     durationLimitSeconds: TimeInterval? = nil, action: ActionRef? = nil,
                     expectedRun: RunRef? = nil) async throws
        -> WorkServiceDirectShellResponse {
        try await performDirectShell(
            operation: operation, language: language, source: source,
            durationLimitSeconds: durationLimitSeconds, action: action,
            expectedRun: expectedRun, presentsFailure: true)
    }

    /// Authoritative pre-End reconciliation uses passive failure presentation: an unavailable
    /// empty-tray read aborts End truthfully without inventing a persistent composer error.
    /// Known outstanding-command uncertainty remains visible through the shared policy.
    @discardableResult
    func inspectDirectShellForReconciliation() async throws
        -> WorkServiceDirectShellResponse {
        try await performDirectShell(operation: .inspect, presentsFailure: false)
    }

    private func performDirectShell(
        operation: WorkServiceDirectShellOperation,
        language: DirectShellLanguage? = nil,
        source: Data? = nil,
        durationLimitSeconds: TimeInterval? = nil,
        action: ActionRef? = nil,
        expectedRun: RunRef? = nil,
        presentsFailure: Bool
    ) async throws -> WorkServiceDirectShellResponse {
        do {
            let response = try await controller.directShell(operation: operation,
                language: language, source: source,
                durationLimitSeconds: durationLimitSeconds, action: action,
                expectedRun: expectedRun)
            guard response.disposition == .accepted || response.disposition == .duplicate else {
                throw WorkServiceProtocolError.invalidRequest(response.diagnostic ?? "Command state is unavailable")
            }
            if action == nil { directShellEntries = response.entries }
            else {
                for entry in response.entries {
                    if let index = directShellEntries.firstIndex(where: { $0.action == entry.action }) {
                        directShellEntries[index] = entry
                    } else { directShellEntries.append(entry) }
                }
            }
            directShellError = nil
            if action == nil { directShellReadCursor = response.resultingWorkCursor }
            return response
        } catch {
            let hasOutstandingCommand = directShellEntries.contains {
                !$0.state.isTerminal || $0.pendingContext
            }
            // A background tray read is observational convenience, not a failed user command.
            // With no known outstanding command it must not manufacture composer-blocking
            // uncertainty during Start. If an earlier explicit operation was uncertain, retain
            // that warning until a successful authoritative read reconciles it.
            let passiveDisposition = ServiceBackedGUIControlPolicy
                .passiveInspectionFailureDisposition(
                    hasExistingUncertainty: directShellError != nil,
                    hasOutstandingCommand: hasOutstandingCommand)
            if presentsFailure || passiveDisposition == .surfaceUncertainty {
                directShellError = operation == .inspect
                    ? "Command status is unavailable. Your saved output has not been cleared."
                    : "Confirmation is unavailable. Check command status before running it again."
            }
            throw error
        }
    }

    init(
        controller: WorkServiceAttachedWorkController,
        projection: WorkServiceAttachedWorkProjection,
        history: WorkServiceConversationHistoryWindow,
        serviceAttachmentKey: ServiceAttachmentKey,
        workspaceLabel: String,
        modelLabel: String?,
        thinkingLevel: String?
    ) {
        self.controller = controller
        self.projection = projection
        self.history = history
        self.work = projection.descriptor.work
        self.serviceAttachmentKey = serviceAttachmentKey
        self.sessionID = projection.attachment.session?.sessionID ?? ""
        self.workspaceID = projection.descriptor.configuration.workspaceID
        self.workspaceLabel = workspaceLabel
        self.modelLabel = modelLabel
        self.thinkingLevel = thinkingLevel
        self.inputDeliveryProjection = Self.makeInputDeliveryProjection(from: projection)
    }

    var isConnected: Bool {
        switch projection.connectivity {
        case .connected: return true
        default: return false
        }
    }

    var activities: [WorkActionSnapshot] { projection.activities }
    /// Durable provider accounting for this Work's lifetime. This is intentionally separate
    /// from the legacy per-transcript ``Usage`` value: several Sessions may observe one Work,
    /// and this total must never be added once per attachment. The controller exposes the
    /// inventory only after authenticating the complete Work/Session projection, including
    /// child facts; the GUI must not rebuild or sum provider usage itself.
    var canonicalWorkUsageInventory: CanonicalWorkUsageInventory? {
        projection.usageInventory
    }

    /// The last provider-bound context accepted by the canonical Session reducer. This is a
    /// historical crossing, not a prediction of the next request.
    var recordedModelContext: RecordedModelContextProjection {
        RecordedModelContextProjection(
            projection.sessionSnapshot,
            sourceCompleteness: projection.sessionSourceCompleteness)
    }
    /// Durable Work/Session state at the controller's exact cursors. Runtime namespace state is
    /// explicitly not exposed until the Work service grows a capability-controlled inspect RPC.
    var canonicalWorkingState: CanonicalWorkingStateProjection {
        CanonicalWorkingStateProjection(projection: projection)
    }
    /// Privacy-safe semantic action rows prepared in Core so every GUI uses the same titles,
    /// timing, retry guidance, provenance, and observation-boundary disclosures.
    var actionPresentations: [WorkActionPresentation] {
        WorkActionPresentation.project(projection.activities)
    }
    var activitySourceIsCurrent: Bool {
        lastError == nil && ChatActivityPresentation.sourceIsCurrent(projection)
    }
    var visibleMessages: [SessionMessageSnapshot] { history.messages }
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

    /// Inputs the Work Host owns but has not yet proven delivered to the runtime. These are
    /// distinct from both unsent GUI drafts and the controller's single in-flight mutation.
    var pendingInputs: [CanonicalInputDeliveryRow] {
        inputDeliveryProjection.unresolvedAcceptedCommands
    }

    /// A canonical command result, deliberately weaker than a provider/turn outcome claim.
    var controlResult: ServiceBackedControlResult? {
        ServiceBackedControlResultPolicy.latestResult(in: projection)
    }

    var repositoryReviewHistory: WorkServiceRepositoryReviewHistory {
        WorkServiceRepositoryReviewHistory(
            workSession: serviceAttachmentKey.workSession,
            descriptors: projection.descriptor.artifacts,
            messages: visibleMessages,
            artifactIndexComplete: projection.isCanonical
                && projection.capabilities.contains(.inspectArtifacts)
                && !projection.descriptor.omissions.contains {
                ["artifacts", "artifact_index", "artifact_identity_scope"].contains($0.category)
            })
    }

    /// Publication order is recorded order, not a fabricated observation time.
    var latestRepositoryReviewDescriptor: WorkServiceArtifactDescriptor? {
        let history = repositoryReviewHistory
        return history.sourceComplete ? history.rows.last?.descriptor : nil
    }

    /// Resolve and parse the selected review only after a person explicitly asks to load it.
    /// ``WorkServiceAttachedWorkController`` revalidates the descriptor, body reference, fence,
    /// byte count, and digest during the read. A changed identity is never returned as stale
    /// content.
    func loadRepositoryReview(
        expectedDescriptor: WorkServiceArtifactDescriptor,
        maxTotalBytes: Int = ObservedRepositoryReviewLimits.default.totalArtifactBytes
    ) async -> Result<ObservedRepositoryReview, RepositoryReviewLoadError> {
        var attributes = consumerReadAttributes
        attributes["aviary.read.target"] = .string("work")
        attributes["aviary.artifact.id"] = .string(
            AviaryTelemetry.identity(expectedDescriptor.artifactID))
        let result = await AviaryTelemetry.withSpan(
            "aviary.gui.repository_review.load", attributes: attributes
        ) {
            let result = await loadRepositoryReviewUntraced(
                expectedDescriptor: expectedDescriptor, maxTotalBytes: maxTotalBytes)
            switch result {
            case .success:
                AviaryTelemetry.outcome("succeeded")
            case .failure(.bounded):
                AviaryTelemetry.outcome("unavailable")
            case .failure(.stale), .failure(.unavailable):
                AviaryTelemetry.outcome("unavailable")
            }
            return result
        }
        return result
    }

    private func loadRepositoryReviewUntraced(
        expectedDescriptor: WorkServiceArtifactDescriptor,
        maxTotalBytes: Int
    ) async -> Result<ObservedRepositoryReview, RepositoryReviewLoadError> {
        let selected = expectedDescriptor
        guard repositoryReviewHistory.sourceComplete,
              repositoryReviewHistory.rows.contains(where: { $0.descriptor == selected }) else {
            return .failure(.unavailable)
        }
        do {
            let fetched = try await controller.fetchArtifactBody(
                descriptor: selected,
                maxTotalBytes: maxTotalBytes)
            guard fetched.descriptor == selected,
                  repositoryReviewHistory.sourceComplete,
                  repositoryReviewHistory.rows.contains(where: { $0.descriptor == selected }) else {
                return .failure(.unavailable)
            }
            guard fetched.data.count <= maxTotalBytes else {
                return .failure(.bounded)
            }
            do {
                let review = try ObservedRepositoryReview.decode(fetched.data)
                guard review.matchesCanonicalSource(of: selected) else {
                    return .failure(.unavailable)
                }
                return .success(review)
            } catch {
                // Invalid review bytes are not actionable GUI evidence. Keep the distinction
                // intentionally coarse and never surface the decoder's remote payload detail.
                return .failure(.unavailable)
            }
        } catch let error as WorkServiceAttachedArtifactLoadError {
            switch error {
            case .tooLarge:
                return .failure(.bounded)
            case .incomplete:
                // If the selected descriptor is still present, the canonical projection was
                // changing or incomplete during the read; do not present the partial result.
                return .failure(repositoryReviewHistory.rows.contains(where: {
                    $0.descriptor == selected
                }) ? .stale : .unavailable)
            case .omitted, .notFound, .malformed, .capabilityDenied, .invalidOptions:
                return .failure(.unavailable)
            }
        } catch {
            return .failure(.unavailable)
        }
    }

    /// Unknown-effect delivery outcomes remain visible even when the paired Session append was
    /// interrupted and there is therefore no transcript row to carry their warning.
    var inputDeliveryAttention: [CanonicalInputDeliveryRow] {
        inputDeliveryProjection.rows.filter(\.requiresHumanReview)
    }

    private var controlPolicy: ServiceBackedGUIControlPolicy {
        ServiceBackedGUIControlPolicy(projection: projection)
    }

    /// A retained Start may be retried while the Work has no Run owner.  Every other retained
    /// command must still belong to this exact active Session relationship; keep the repair UI
    /// disabled when a refresh observes an ownership transfer.
    var canRetryPendingCommand: Bool {
        guard !projection.commandInFlight,
              let pending = projection.pendingCommand else { return false }
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
        if presentsAcceptedStartGrace { return .preparing }
        if projection.needsRecovery { return .failed }
        if let pending = projection.pendingCommand, pending.kind == .start {
            if projection.commandInFlight { return .preparing }
            if pending.state == .awaitingCanonicalEvidence { return .committing }
        }
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
        if let pending = projection.pendingCommand, !projection.commandInFlight {
            switch pending.state {
            case .stale:
                return "A \(pending.kind.rawValue) command is stale. Refresh canonical Work before deciding whether to abandon it and issue a new command."
            case .indeterminate:
                return "A \(pending.kind.rawValue) command has an indeterminate outcome. Refresh canonical Work and reconcile it explicitly; Aviary will not replay it automatically."
            case .awaitingCanonicalEvidence:
                break
            }
        }
        // `requiresRefresh` is explicitly ordinary accepted-receipt catch-up. It withholds
        // mutation through ServiceBackedGUIControlPolicy, but is not an error or uncertainty.
        if projection.needsRecovery && !presentsAcceptedStartGrace {
            return "This Work is visible but not safely actionable until its Work and Session state can be recovered."
        }
        return nil
    }

    /// Canonical Session messages are the only transcript source for this adapter.  Host time
    /// is preferred and missing host time remains an explicit distant-past sentinel rather than
    /// using the GUI's clock to invent ordering or completion time.
    var transcriptItems: [TranscriptItem] {
        var deliveryByMessage: [EventRef: CanonicalInputDeliveryRow] = [:]
        for row in inputDeliveryProjection.rows {
            guard let event = row.messageEvent, deliveryByMessage[event] == nil else { continue }
            deliveryByMessage[event] = row
        }
        return visibleMessages.map { message in
            let role = message.role.lowercased()
            let kind: TranscriptItem.Kind = switch role {
            case "user": .user
            case "assistant", "model": .assistant
            // A canonical message snapshot has text and provenance, not a paired ToolCall/result.
            // Mapping it to `.tool` would hide the text and falsely label the row as running.
            case "tool", "action": .custom
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
            if let source = message.sourceEvent {
                item.inputDelivery = deliveryByMessage[source]
            }
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
            history = await controller.conversationHistory()
            if history.status == .ready || history.status == .staleBranch {
                // A successful refresh either recovered the page or proved that the Session
                // selected another branch. In the latter case Return to latest is the truthful
                // action; retaining a dead Retry banner would only issue a request the controller
                // must reject.
                historyError = nil
            }
            inputDeliveryProjection = Self.makeInputDeliveryProjection(from: next)
            lastError = ServiceBackedGUIControlPolicy.blockingReadDiagnostic(in: next)
            reconcileStartPresentationGrace(with: next)
            // On first attachment, pending command output may be older than the bounded action
            // window. Query the authoritative tray once, then only when Work advances. Never
            // infer absence from the currently visible activity rows.
            if supportsDirectShell, controlPolicy.allowsPassiveDirectShellInspection,
               directShellReadCursor != next.workCursor {
                _ = try? await performDirectShell(
                    operation: .inspect, presentsFailure: false)
            }
            return next
        } catch {
            let observed = await controller.projection()
            projection = observed
            history = await controller.conversationHistory()
            inputDeliveryProjection = Self.makeInputDeliveryProjection(from: observed)
            lastError = Self.message(for: error, projection: observed)
            reconcileStartPresentationGrace(with: observed)
            return observed
        }
    }

    /// Prepend one authenticated, bounded page without changing the controller's canonical
    /// reducer, read acknowledgement, or command cursors.
    @discardableResult
    func loadEarlierHistory() async throws -> WorkServiceConversationHistoryWindow {
        try await AviaryTelemetry.withSpan(
            "aviary.gui.history.load_earlier", attributes: consumerReadAttributes
        ) {
            do {
                history = try await controller.loadEarlierConversationHistory()
                historyError = nil
                AviaryTelemetry.outcome("succeeded")
                return history
            } catch {
                history = await controller.conversationHistory()
                historyError = Self.historyMessage(for: error)
                AviaryTelemetry.outcome(Self.historyTelemetryOutcome(for: error))
                throw error
            }
        }
    }

    /// Release this GUI's historical window and return to its newest authenticated projection.
    /// This is presentation state only and does not write to Work or Session.
    @discardableResult
    func jumpHistoryToLatest() async -> WorkServiceConversationHistoryWindow {
        history = await controller.jumpConversationHistoryToLatest()
        historyError = nil
        return history
    }

    func start(_ prompt: String, commandID: String? = nil) async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        let effectiveCommandID = commandID ?? UUID().uuidString.lowercased()
        return try await issue(kind: .start, commandID: effectiveCommandID) {
            try await self.controller.start(prompt, commandID: effectiveCommandID)
        }
    }

    func send(_ prompt: String, commandID: String? = nil) async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        let effectiveCommandID = commandID ?? UUID().uuidString.lowercased()
        return try await issue(kind: .send, commandID: effectiveCommandID) {
            try await self.controller.send(prompt, commandID: effectiveCommandID)
        }
    }

    func steer(_ text: String, commandID: String? = nil) async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        let effectiveCommandID = commandID ?? UUID().uuidString.lowercased()
        return try await issue(kind: .steer, commandID: effectiveCommandID) {
            try await self.controller.steer(text, commandID: effectiveCommandID)
        }
    }

    func queue(_ text: String, commandID: String? = nil) async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        let effectiveCommandID = commandID ?? UUID().uuidString.lowercased()
        return try await issue(kind: .queue, commandID: effectiveCommandID) {
            try await self.controller.queue(text, commandID: effectiveCommandID)
        }
    }

    func cancel(scope: SessionCancellationScope) async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        let commandID = UUID().uuidString.lowercased()
        return try await issue(kind: .cancel, commandID: commandID) {
            try await self.controller.cancel(scope: scope, commandID: commandID)
        }
    }

    /// The only service-backed lifecycle termination operation.  Generic GUI disconnect and
    /// process termination never call this method.
    func end(commandID: String) async throws -> WorkServiceCommandReceipt {
        try requireExactRunOwner()
        return try await issue(kind: .end, commandID: commandID) {
            try await self.controller.end(commandID: commandID)
        }
    }

    /// A failed response is not itself a rejection. Only a structured rejection, a proven stale
    /// cursor, or a controller gate that runs before request retention proves that this exact
    /// command did not cross. A retained command may have taken effect and is never retried here.
    func failureCertainty(
        for error: Error, commandID: String, kind: WorkServiceCommandKind
    ) async -> ServiceBackedRunBridgeFailureCertainty {
        if error is ServiceBackedRunBridgeError { return .rejected }
        let key = serviceAttachmentKey
        let notice = ServiceBackedCommandNotice(
            work: work, commandID: commandID, kind: kind,
            client: key.client, attachment: key.clientAttachment,
            sessionAttachment: key.workSession.sessionAttachment,
            evidence: .canonicalCommand)
        if ServiceBackedCommandNoticePolicy.hasExactCanonicalCommandEvidence(
            for: notice, in: projection) {
            return .uncertain
        }
        if hasMatchingAcceptedReceipt(commandID: commandID, kind: kind) {
            return .uncertain
        }
        if let pending = await controller.pendingCommand() {
            if pending.commandID == commandID {
                return pending.state == .stale ? .rejected : .uncertain
            }
        }
        guard let controllerError = error as? WorkServiceAttachedWorkControllerError else {
            return .uncertain
        }
        switch controllerError {
        case .staleCursor, .pendingCommandExists, .noPendingCommand,
             .commandNotAdmissible, .capabilityDenied, .terminalWork,
             .recoveryRequired, .invalidSeed, .invalidOptions:
            return .rejected
        case .sourceIncomplete, .notConnected, .malformedResponse,
             .transportFailure, .hostMismatch:
            return .uncertain
        }
    }

    private func hasMatchingAcceptedReceipt(
        commandID: String, kind: WorkServiceCommandKind
    ) -> Bool {
        guard let receipt = projection.lastReceipt,
              receipt.work == work,
              receipt.commandID == commandID,
              receipt.state == .accepted || receipt.state == .duplicate
        else { return false }
        switch kind {
        case .start:
            return receipt.outcome == .started || receipt.outcome == .startRecoveryRequired
        case .send: return receipt.outcome == .inputAccepted
        case .steer: return receipt.outcome == .steeringAccepted
        case .queue: return receipt.outcome == .queued
        case .hold: return receipt.outcome == .holdRequested
        case .cancel: return receipt.outcome == .cancellationRequested
        case .end: return receipt.outcome == .endRequested
        case .destroy: return receipt.outcome == .destroyed
        case .complete: return receipt.outcome == .completed
        }
    }

    private func requireExactRunOwner() throws {
        guard hasExactRunOwner else {
            throw WorkServiceAttachedWorkControllerError.recoveryRequired
        }
    }

    private static func makeInputDeliveryProjection(
        from projection: WorkServiceAttachedWorkProjection
    ) -> CanonicalInputDeliveryProjection {
        CanonicalInputDeliveryProjection(
            workSnapshot: projection.workSnapshot,
            sessionSnapshot: projection.sessionSnapshot,
            workSourceCompleteness: projection.workSourceCompleteness,
            sessionSourceCompleteness: projection.sessionSourceCompleteness,
            workOmissions: projection.workOmissions,
            sessionOmissions: projection.sessionOmissions)
    }

    private var consumerReadAttributes: [String: AviaryTraceValue] {
        var attributes: [String: AviaryTraceValue] = [
            "aviary.work.id": .string(AviaryTelemetry.workIdentity(work)),
            "aviary.read.target": .string("session"),
        ]
        if !sessionID.isEmpty {
            attributes["aviary.session.id"] = .string(AviaryTelemetry.identity(sessionID))
        }
        return attributes
    }

    private static func historyTelemetryOutcome(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let error = error as? WorkServiceAttachedWorkControllerError else {
            return "failed"
        }
        switch error {
        case .invalidOptions:
            return "unavailable"
        case .invalidSeed, .hostMismatch, .notConnected, .malformedResponse, .sourceIncomplete,
             .pendingCommandExists, .noPendingCommand, .commandNotAdmissible,
             .capabilityDenied, .terminalWork, .recoveryRequired, .staleCursor,
             .transportFailure:
            return "unavailable"
        }
    }

    /// Retry the controller's one explicitly retained command, preserving its original command
    /// id, value, and causal cursor. This is a user repair action, never an automatic polling
    /// behavior.
    func retryPendingCommand() async throws -> WorkServiceCommandReceipt {
        // Do not prefetch the pending row: a concurrent refresh may replace it between the read
        // and the retry. The controller owns the single atomic retained request; its returned
        // receipt is the first safe place to expose the exact command identity.
        return try await issue {
            try await self.controller.retryPendingCommand()
        }
    }

    /// Abandon only a stale command after the user has seen the current canonical projection.
    /// Indeterminate commands are deliberately rejected by the controller.
    func abandonStaleCommand() async throws {
        try await controller.abandonStaleCommand()
        _ = await refresh()
    }

    private func issue(
        kind: WorkServiceCommandKind? = nil,
        commandID: String? = nil,
        _ operation: @escaping () async throws -> WorkServiceCommandReceipt
    ) async throws -> WorkServiceCommandReceipt {
        var attributes: [String: AviaryTraceValue] = [
            "aviary.work.id": .string(AviaryTelemetry.workIdentity(work)),
        ]
        if let commandID {
            attributes["aviary.command.id"] = .string(AviaryTelemetry.identity(commandID))
        }
        if let kind {
            attributes["aviary.command.kind"] = .string(kind.rawValue)
        }
        return try await AviaryTelemetry.withSpan("aviary.ui.command", attributes: attributes) {
            do {
                return try await self.issueUntraced(operation, kind: kind)
            } catch {
                let certainty: ServiceBackedRunBridgeFailureCertainty
                if let kind, let commandID {
                    certainty = await self.failureCertainty(
                        for: error, commandID: commandID, kind: kind)
                } else {
                    certainty = .uncertain
                }
                AviaryTelemetry.outcome(certainty == .rejected ? "rejected" : "indeterminate")
                throw error
            }
        }
    }

    private func issueUntraced(
        _ operation: @escaping () async throws -> WorkServiceCommandReceipt,
        kind: WorkServiceCommandKind?
    ) async throws -> WorkServiceCommandReceipt {
        if kind == .start { clearStartPresentationGrace() }
        do {
            let receipt = try await operation()
            AviaryTelemetry.outcome(receipt.state.rawValue)
            var receiptAttributes: [String: AviaryTraceValue] = [
                "aviary.receipt.state": .string(receipt.state.rawValue),
                "aviary.command.id": .string(
                    AviaryTelemetry.identity(receipt.commandID)),
            ]
            if let kind {
                receiptAttributes["aviary.command.kind"] = .string(kind.rawValue)
            }
            AviaryTelemetry.event("aviary.command.receipt", attributes: receiptAttributes)
            guard receipt.state == .accepted || receipt.state == .duplicate else {
                AviaryTelemetry.outcome("rejected")
                let detail = receipt.diagnostic
                    ?? receipt.rejection?.rawValue
                    ?? "The Work Host rejected the command."
                _ = await refresh()
                lastError = "The Work Host rejected the command: \(detail)"
                throw ServiceBackedRunBridgeError.rejected(detail)
            }
            if kind == .start {
                installStartPresentationGrace(ServiceBackedStartPresentationGrace(
                    receipt: receipt, attachment: projection.attachment, now: Date()))
            }
            _ = await refresh()
            return receipt
        } catch {
            _ = await refresh()
            throw error
        }
    }

    private var presentsAcceptedStartGrace: Bool {
        startPresentationGrace?.presentsPreparing(
            projection: projection, now: Date()) == true
    }

    private func reconcileStartPresentationGrace(
        with projection: WorkServiceAttachedWorkProjection
    ) {
        guard var grace = startPresentationGrace else { return }
        switch grace.reconcile(projection: projection, now: Date()) {
        case .awaitingCanonicalEvidence, .presentPreparing:
            startPresentationGrace = grace
        case .clear:
            clearStartPresentationGrace()
        }
    }

    private func installStartPresentationGrace(
        _ grace: ServiceBackedStartPresentationGrace?
    ) {
        clearStartPresentationGrace()
        guard let grace else { return }
        startPresentationGrace = grace
        startPresentationGeneration += 1
        let generation = startPresentationGeneration
        let nanoseconds = UInt64(
            ServiceBackedStartPresentationGrace.maximumDuration * 1_000_000_000)
        startPresentationExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self, self.startPresentationGeneration == generation else { return }
            self.startPresentationExpiryTask = nil
            self.startPresentationGrace = nil
            self.onPresentationChange?()
        }
    }

    private func clearStartPresentationGrace() {
        startPresentationGeneration += 1
        startPresentationExpiryTask?.cancel()
        startPresentationExpiryTask = nil
        startPresentationGrace = nil
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

    private static func historyMessage(for error: Error) -> String {
        if let error = error as? WorkServiceAttachedWorkControllerError {
            switch error {
            case .sourceIncomplete, .recoveryRequired, .malformedResponse:
                return "Earlier history could not be verified against the canonical Session."
            case .capabilityDenied:
                return "This attachment is not authorized to read earlier history."
            case .hostMismatch:
                return "The Work Host identity changed while earlier history was loading."
            case .terminalWork:
                return "Earlier history is unavailable from this completed Work projection."
            default:
                break
            }
        }
        return "Earlier history is temporarily unavailable. Your current transcript is unchanged."
    }
}
