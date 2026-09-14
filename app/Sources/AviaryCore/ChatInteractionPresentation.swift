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

    /// Guidance is a one-message override. A failed send or a newer choice keeps the editor
    /// unchanged; an accepted override returns the next message to ordinary follow-up delivery.
    public static func afterSubmission(
        submitted: Self, current: Self, handedOff: Bool
    ) -> Self {
        handedOff && submitted == .guideCurrentWork && current == submitted ? .followUp : current
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
        hasUnresolvedDraftHandoff: Bool,
        persistenceNotice: String?,
        commandInFlight: Bool,
        commandState: SessionCommandState,
        hasExited: Bool,
        isEnding: Bool = false,
        acceptsInput: Bool,
        isStreaming: Bool,
        availableDeliveries: [ChatBusyDelivery],
        effectiveDelivery: ChatBusyDelivery?,
        draftIsEmpty: Bool
    ) -> Self {
        // These two states mean an exact command may already have crossed the service boundary.
        // They take precedence over every lifecycle or capability hint so the UI never invites a
        // second copy while canonical evidence is unresolved.
        if hasUnresolvedDraftHandoff {
            return blocked(
                "Delivery needs checking. This draft will not be sent again automatically.",
                symbol: "exclamationmark.triangle.fill")
        }
        if commandInFlight {
            return blocked(
                "Waiting for the agent service to confirm receipt. Aviary will not send another copy.",
                symbol: "hourglass")
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
