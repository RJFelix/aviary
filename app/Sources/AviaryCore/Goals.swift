import Foundation

/// A budget and a finishing condition for a run.
///
/// The harness has goals; the useful part is not the word but the two numbers. An agent asked
/// to do something open-ended will otherwise run until an iteration ceiling it cannot see,
/// which produces the worst kind of stop: silent, arbitrary, and indistinguishable from
/// success. A goal makes the limit something the agent knows about and can plan against.
public struct Goal: Sendable, Hashable {
    public var text: String
    /// Total tokens this goal may spend. Nil means no token budget.
    public var tokenBudget: Int?
    /// Wall-clock ceiling. Nil means no time budget.
    public var timeBudget: TimeInterval?
    public var startedAt: Date

    public init(
        text: String, tokenBudget: Int? = nil, timeBudget: TimeInterval? = nil,
        startedAt: Date = Date()
    ) {
        self.text = text
        self.tokenBudget = tokenBudget
        self.timeBudget = timeBudget
        self.startedAt = startedAt
    }

    public enum Status: Sendable, Equatable {
        case running
        case tokensExhausted(spent: Int, budget: Int)
        case timeExhausted(elapsed: TimeInterval, budget: TimeInterval)

        public var isFinished: Bool { self != .running }
    }

    public func status(spent: Int, now: Date = Date()) -> Status {
        if let budget = tokenBudget, spent >= budget {
            return .tokensExhausted(spent: spent, budget: budget)
        }
        if let budget = timeBudget, now.timeIntervalSince(startedAt) >= budget {
            return .timeExhausted(elapsed: now.timeIntervalSince(startedAt), budget: budget)
        }
        return .running
    }

    /// What the agent is told about its own budget.
    ///
    /// Stated rather than hidden, because a budget the agent cannot see is one it cannot plan
    /// against — it will spend the whole allowance on exploration and be cut off mid-thought.
    public func briefing(spent: Int, now: Date = Date()) -> String {
        var lines = ["## Goal", "", text]
        var limits: [String] = []
        if let budget = tokenBudget {
            let remaining = max(0, budget - spent)
            limits.append("\(Fmt.tokens(remaining)) of \(Fmt.tokens(budget)) tokens left")
        }
        if let budget = timeBudget {
            let remaining = max(0, budget - now.timeIntervalSince(startedAt))
            limits.append("\(Int(remaining / 60)) of \(Int(budget / 60)) minutes left")
        }
        if !limits.isEmpty {
            lines.append("")
            lines.append("Budget: " + limits.joined(separator: ", ")
                + ". Spend it on the goal, not on exploring around it. If you will not finish "
                + "within it, say what you did and what remains rather than being cut off.")
        }
        return lines.joined(separator: "\n")
    }

    public func exhaustionNote(_ status: Status) -> String? {
        switch status {
        case .running:
            return nil
        case .tokensExhausted(let spent, let budget):
            return "Goal stopped: spent \(Fmt.tokens(spent)) of a \(Fmt.tokens(budget)) token "
                + "budget. Raise the budget or narrow the goal."
        case .timeExhausted(let elapsed, let budget):
            return "Goal stopped after \(Int(elapsed / 60)) minutes against a "
                + "\(Int(budget / 60)) minute budget."
        }
    }
}
