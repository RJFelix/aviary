import Foundation

/// Plain-language presentation, not command admission. The caller must still enforce the
/// canonical control policy at submission; changing a label never grants a capability.
public enum ChatBusyDelivery: String, CaseIterable, Identifiable, Sendable {
    case guideCurrentWork
    case followUp

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .guideCurrentWork: "Guide current work"
        case .followUp: "Follow-up message"
        }
    }
    public var buttonLabel: String {
        switch self {
        case .guideCurrentWork: "Send guidance"
        case .followUp: "Queue message"
        }
    }
    /// The short labels used by the busy composer action strip. The longer labels above remain
    /// useful in status copy and accessibility descriptions.
    public var compactLabel: String {
        switch self {
        case .guideCurrentWork: "Steer"
        case .followUp: "Queue"
        }
    }
    public var symbol: String {
        switch self {
        case .guideCurrentWork: "arrow.turn.down.right"
        case .followUp: "text.append"
        }
    }
    public var explanation: String {
        switch self {
        case .guideCurrentWork:
            "Adds guidance before the agent's next model request. It does not interrupt an action already in progress."
        case .followUp:
            "Keeps this as a separate message for the agent to answer after its current work."
        }
    }
    public var placeholder: String {
        switch self {
        case .guideCurrentWork: "Add a correction or steer the current work…"
        case .followUp: "Write your next request…"
        }
    }

    public static func available(supportsGuidance: Bool, supportsFollowUp: Bool) -> [Self] {
        // The ordinary chat action is a separate follow-up. Guidance is an explicit choice.
        (supportsFollowUp ? [.followUp] : []) + (supportsGuidance ? [.guideCurrentWork] : [])
    }

}

/// The user's preferred busy-composer action. This is presentation preference only: the
/// capability-derived delivery list and the submission gate still decide whether an action can
/// be admitted. It is intentionally a small raw-value type so the GUI can persist it in
/// UserDefaults without coupling Core to a settings file format.
public enum ChatBusyDeliveryPreference: String, CaseIterable, Identifiable, Sendable {
    case followUp
    case guideCurrentWork

    public static let storageKey = "aviary.chat.busyDeliveryPreference"
    public static let `default`: Self = .followUp

    public var id: String { rawValue }
    public var delivery: ChatBusyDelivery {
        switch self {
        case .followUp: .followUp
        case .guideCurrentWork: .guideCurrentWork
        }
    }
    public var label: String {
        switch self {
        case .followUp: "Queue follow-up"
        case .guideCurrentWork: "Steer current work"
        }
    }
    public var explanation: String {
        switch self {
        case .followUp: "Return and the primary busy action queue a separate message for after the current work."
        case .guideCurrentWork: "Return and the primary busy action steer before the next model request."
        }
    }

    public static func load(rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .default
    }

    /// Resolve a preference against the exact capability-derived choices. A persisted choice
    /// cannot manufacture a route that the current Work did not advertise.
    public func resolved(in choices: [ChatBusyDelivery]) -> ChatBusyDelivery? {
        if choices.contains(delivery) { return delivery }
        return choices.first
    }
}

/// Presentation-only bridge for the short interval after a Work Host accepted a message and
/// before its canonical projection catches up. It deliberately accepts the exact notice and
/// projection objects so a stale, disconnected, uncertain, or failed state cannot be relabeled
/// as healthy progress.
public enum ChatAcceptedMessageRefreshPolicy {
    public static func shouldShow(
        notice: ServiceBackedCommandNotice?,
        noticeWasSuccessful: Bool,
        projection: WorkServiceAttachedWorkProjection?,
        hasErrorBanner: Bool
    ) -> Bool {
        guard !hasErrorBanner, noticeWasSuccessful,
              let notice,
              case .acceptedReceipt(let acceptedCursor) = notice.evidence,
              [.start, .send, .steer, .queue].contains(notice.kind),
              let projection,
              notice.work == projection.descriptor.work,
              notice.client == projection.attachment.client,
              notice.attachment == projection.attachment.attachment,
              notice.sessionAttachment == projection.attachment.sessionAttachment,
              acceptedCursor.journal == projection.descriptor.journal,
              let receipt = projection.lastReceipt,
              receipt.commandID == notice.commandID,
              receipt.work == notice.work,
              receipt.state == .accepted || receipt.state == .duplicate,
              receipt.resultingWorkCursor == acceptedCursor,
              projection.requiresRefresh,
              !projection.needsRecovery,
              case .connected = projection.connectivity
        else { return false }
        return true
    }
}

/// One mutually-exclusive composer submission state. A durable handoff marker exists before the
/// controller call begins, so the marker alone cannot mean that delivery was lost. Only a marker
/// left after both the GUI operation and the controller request lifetime end needs recovery.
public enum ChatComposerSubmissionState: Equatable, Sendable {
    case idle
    case active
    case needsRecovery

    public static func resolve(
        hasDraftHandoff: Bool,
        localOperationsInFlight: Int,
        serviceCommandInFlight: Bool
    ) -> Self {
        if localOperationsInFlight > 0 || serviceCommandInFlight { return .active }
        return hasDraftHandoff ? .needsRecovery : .idle
    }
}

/// Explanatory composer copy derived from the same exact facts that the caller uses for
/// admission. This value never grants admission or predicts that a command will be accepted.
public struct ChatComposerStatusPresentation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case information
        case blocked
    }

    public let kind: Kind
    public let text: String
    public let symbol: String

    public static func resolve(
        submissionState: ChatComposerSubmissionState,
        persistenceNotice: String?,
        commandState: SessionCommandState,
        hasExited: Bool,
        isEnding: Bool = false,
        acceptsInput: Bool,
        isStreaming: Bool,
        availableDeliveries: [ChatBusyDelivery],
        effectiveDelivery: ChatBusyDelivery?,
        draftIsEmpty: Bool,
        receiptPending: Bool = false
    ) -> Self {
        // Active is the original request lifetime, not an uncertain outcome. It takes precedence
        // over the durable marker written for that same request so ordinary sends never flash
        // recovery language while the service call is still underway.
        if submissionState == .active {
            return blocked(
                "Sending to the agent service…",
                symbol: "hourglass")
        }
        // A handoff becomes unresolved only after the original GUI and controller request
        // lifetimes have both ended without accepted or rejected evidence.
        if submissionState == .needsRecovery {
            return blocked(
                "Delivery needs checking. This draft will not be sent again automatically.",
                symbol: "exclamationmark.triangle.fill")
        }

        if hasExited || commandState == .ended {
            return blocked(
                "This agent session has ended. Your draft stays here.",
                symbol: "stop.circle")
        }
        if isEnding || commandState == .ending {
            return blocked("The agent session is ending. Your draft stays here.", symbol: "stop.circle")
        }
        switch commandState {
        case .prepared, .preparing, .committing:
            return blocked("The agent is starting. Your draft stays here.", symbol: "hourglass")
        case .canceling:
            return blocked(
                "The agent is stopping after its current step. A model response or action already in progress may finish first. Your draft stays here.",
                symbol: "stop.circle")
        case .failed:
            return blocked(
                "Sending is unavailable while this chat needs attention. Your draft stays here.",
                symbol: "exclamationmark.triangle.fill")
        case .running, .idle, .ending, .ended:
            break
        }

        // A service receipt can arrive just before the next canonical projection reports the
        // Work as busy. Keep the accepted handoff visible during that short interval instead of
        // translating the stale admission snapshot into a misleading disabled flash.
        if receiptPending {
            return information(
                "Agent service accepted your message; updating this chat…",
                symbol: "hourglass")
        }

        if !acceptsInput {
            if isStreaming && availableDeliveries.isEmpty {
                return blocked(
                    "No message route is available during the current recorded work. Your draft stays here.",
                    symbol: "tray")
            }
            return blocked(
                "Sending is unavailable in the current recorded state. Your draft stays here.",
                symbol: "exclamationmark.circle")
        }

        if isStreaming {
            guard let effectiveDelivery,
                  availableDeliveries.contains(effectiveDelivery) else {
                let text = availableDeliveries.isEmpty
                    ? "No message route is available during the current recorded work. Your draft stays here."
                    : "Choose where this message should go. Your draft stays here until you do."
                return blocked(text, symbol: "tray")
            }
        }

        if let notice = persistenceNotice?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notice.isEmpty {
            return information(notice, symbol: "externaldrive.badge.exclamationmark")
        }

        if draftIsEmpty {
            return information("Write a message before sending.", symbol: "pencil")
        }

        if isStreaming, let effectiveDelivery {
            return information(effectiveDelivery.explanation, symbol: effectiveDelivery.symbol)
        }

        return information("Send a message to the agent.", symbol: "arrow.up")
    }

    private static func information(_ text: String, symbol: String) -> Self {
        Self(kind: .information, text: text, symbol: symbol)
    }

    private static func blocked(_ text: String, symbol: String) -> Self {
        Self(kind: .blocked, text: text, symbol: symbol)
    }
}

/// Header status for the recorded chat projection. A current service read is not proof of
/// runtime liveness, but a disconnected or incomplete service read must not animate as live.
public struct ChatRunHeaderStatusPresentation: Equatable, Sendable {
    public let label: String
    public let symbol: String
    public let showsPulse: Bool
    public let isNeutral: Bool

    public static func resolve(
        commandState: SessionCommandState,
        isStreaming: Bool,
        hasExited: Bool,
        isServiceBacked: Bool,
        serviceSourceIsCurrent: Bool
    ) -> Self {
        let stateLabel = ChatInteractionPresentation.stateLabel(commandState)
        if isServiceBacked && !serviceSourceIsCurrent {
            return Self(
                label: "Last recorded: \(stateLabel)",
                symbol: "clock",
                showsPulse: false,
                isNeutral: true)
        }
        if isStreaming {
            return Self(
                label: stateLabel,
                symbol: "circle.fill",
                showsPulse: true,
                isNeutral: false)
        }
        return Self(
            label: stateLabel,
            symbol: hasExited ? "stop.circle.fill" : "circle.fill",
            showsPulse: false,
            isNeutral: false)
    }
}

public enum ChatInteractionPresentation {
    public static func stateLabel(_ state: SessionCommandState) -> String {
        switch state {
        case .prepared, .preparing, .committing: "Starting"
        case .running: "Working"
        case .idle: "Ready"
        case .canceling: "Stopping after current step"
        case .failed: "Needs attention"
        case .ending: "Ending agent session"
        // End is not proof that a task succeeded.
        case .ended: "Agent session ended"
        }
    }

    public static let stopExplanation =
        "Stops before the next step. A model response or action already in progress may finish first."
}

/// Orders existing facts for one chat status surface. This never dismisses a notice or
/// reconciles a command: every supplied source remains available in the detail projection.
public struct ChatStatusPresentation: Equatable, Sendable {
    public enum Source: String, Hashable, Sendable { case project, chatError, command, stopReceipt, projectionLimits, inputDeliveryLimits }
    public enum Tone: Equatable, Sendable { case uncertain, danger, warning, information, success }
    public struct Item: Equatable, Sendable {
        public let source: Source
        public let tone: Tone
        public let title: String
        public let message: String
        public init(source: Source, tone: Tone, title: String, message: String) {
            self.source = source; self.tone = tone; self.title = title; self.message = message
        }
        public var needsAttention: Bool { tone == .uncertain || tone == .danger || tone == .warning }
        public var symbol: String {
            switch tone {
            case .uncertain: "questionmark.circle.fill"
            case .danger: "exclamationmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .information: "info.circle"
            case .success: "checkmark.circle"
            }
        }
        fileprivate var rank: Int {
            // Bounded display coverage is supporting evidence, not a new outcome or a
            // delivery failure. Input-delivery limits retain their warning priority.
            if source == .projectionLimits { return 5 }
            switch tone {
            case .uncertain: return 0
            case .danger: return 1
            case .warning: return 2
            case .success: return 3
            case .information: return 4
            }
        }
    }
    public let items: [Item]
    public var primary: Item? { items.first }
    public var attentionCount: Int { items.filter(\.needsAttention).count }

    public init(items: [Item]) {
        // Stable source ordering for equal severity; never deduplicate by prose because two
        // different evidence sources can legitimately carry the same description.
        let sourceOrder: [Source] = [.project, .chatError, .command, .inputDeliveryLimits, .projectionLimits, .stopReceipt]
        self.items = items.enumerated().sorted { lhs, rhs in
            if lhs.element.rank != rhs.element.rank { return lhs.element.rank < rhs.element.rank }
            let left = sourceOrder.firstIndex(of: lhs.element.source) ?? sourceOrder.count
            let right = sourceOrder.firstIndex(of: rhs.element.source) ?? sourceOrder.count
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
}
