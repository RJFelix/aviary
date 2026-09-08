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
        case .followUp: "Send after this response"
        }
    }
    public var buttonLabel: String {
        switch self {
        case .guideCurrentWork: "Send guidance"
        case .followUp: "Queue message"
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
