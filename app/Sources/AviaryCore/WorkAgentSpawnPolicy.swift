import Foundation

/// The caller-selected bounds for one Work-owned child.
///
/// This is a cooperative execution policy, not a billing or security boundary. A timeout is
/// translated to an absolute host deadline once, at admission, and the provider accounting
/// limits are retained with the child Handle. Omitted or explicit null fields mean unlimited.
internal struct WorkAgentSpawnPolicy: Hashable, Sendable {
    static let unlimited = WorkAgentSpawnPolicy(timeout: nil, executionLimits: .unlimited)

    let timeout: TimeInterval?
    let executionLimits: WorkAgentExecutionLimits

    init(
        timeout: TimeInterval? = nil,
        executionLimits: WorkAgentExecutionLimits = .unlimited
    ) {
        self.timeout = timeout
        self.executionLimits = executionLimits
    }

    /// Decode the callback fields that Python may provide for a child spawn. The callback
    /// boundary accepts only the three policy fields; prompt/name/model are decoded by Agent.
    init(callbackPayload: JSONValue) throws {
        guard let object = callbackPayload.objectValue else {
            throw WorkAgentSpawnPolicyError.invalidField
        }
        // Agent supplies the complete spawn object here. These three ordinary spawn fields are
        // validated by Agent; this decoder only owns the policy extension fields.
        let allowed: Set<String> = [
            "prompt", "name", "model", "timeout", "token_limit", "cost_limit_usd",
        ]
        guard object.keys.allSatisfy({ allowed.contains($0) }) else {
            throw WorkAgentSpawnPolicyError.unknownField
        }

        let timeout: TimeInterval?
        switch object["timeout"] {
        case nil, .some(.null):
            timeout = nil
        case .some(.number(let value)):
            guard value.isFinite, value > 0 else {
                throw WorkAgentSpawnPolicyError.invalidTimeout
            }
            timeout = value
        default:
            throw WorkAgentSpawnPolicyError.invalidTimeout
        }

        let maximumTokens: Int?
        switch object["token_limit"] {
        case nil, .some(.null):
            maximumTokens = nil
        case .some(.string(let value)):
            guard value.utf8.count <= WorkAgentExecutionLimits.maximumDecimalBytes,
                  !value.isEmpty,
                  let parsed = Int(value),
                  String(parsed) == value,
                  parsed > 0 else {
                throw WorkAgentSpawnPolicyError.invalidTokenLimit
            }
            maximumTokens = parsed
        default:
            throw WorkAgentSpawnPolicyError.invalidTokenLimit
        }

        let maximumCost: Double?
        switch object["cost_limit_usd"] {
        case nil, .some(.null):
            maximumCost = nil
        case .some(.number(let value)):
            guard value.isFinite, value > 0 else {
                throw WorkAgentSpawnPolicyError.invalidCostLimit
            }
            maximumCost = value
        default:
            throw WorkAgentSpawnPolicyError.invalidCostLimit
        }

        do {
            let executionLimits = try WorkAgentExecutionLimits(
                maximumTokens: maximumTokens,
                maximumEstimatedCostUSD: maximumCost)
            self.init(timeout: timeout, executionLimits: executionLimits)
        } catch WorkAgentExecutionLimitsError.invalidMaximumTokens {
            throw WorkAgentSpawnPolicyError.invalidTokenLimit
        } catch {
            throw WorkAgentSpawnPolicyError.invalidCostLimit
        }
    }

    /// Canonical callback/status projection. Token limits stay strings so Python cannot lose
    /// Int precision; cost and timeout remain JSON numbers by callback contract.
    var callbackPayload: JSONValue {
        var object: [String: JSONValue] = [:]
        if let timeout { object["timeout"] = .number(timeout) }
        if let maximumTokens = executionLimits.maximumTokens {
            object["token_limit"] = .string(String(maximumTokens))
        }
        if let maximumCost = executionLimits.maximumEstimatedCostUSD {
            object["cost_limit_usd"] = .number(maximumCost)
        }
        return .object(object)
    }

    /// Resolve the one absolute deadline used by a coordinator admission. The host deadline is
    /// intentionally computed once for an accepted callback attempt, including the uncertain
    /// admission path; retries of the callback return that same attempt's result.
    func absoluteDeadline(now: Date, pilotDeadline: Date?) throws -> Date? {
        guard now.timeIntervalSince1970.isFinite else {
            throw WorkAgentSpawnPolicyError.invalidDeadline
        }
        var candidates: [Date] = []
        if let timeout {
            guard timeout.isFinite, timeout > 0 else {
                throw WorkAgentSpawnPolicyError.invalidTimeout
            }
            let deadline = now.addingTimeInterval(timeout)
            guard deadline.timeIntervalSince1970.isFinite, deadline > now else {
                throw WorkAgentSpawnPolicyError.invalidDeadline
            }
            candidates.append(deadline)
        }
        if let pilotDeadline {
            guard pilotDeadline.timeIntervalSince1970.isFinite, pilotDeadline > now else {
                throw WorkAgentSpawnPolicyError.invalidDeadline
            }
            candidates.append(pilotDeadline)
        }
        guard let first = candidates.first else { return nil }
        return candidates.dropFirst().reduce(first, min)
    }
}

internal enum WorkAgentSpawnPolicyError: Error, LocalizedError, Equatable, Sendable {
    case invalidField
    case unknownField
    case invalidTimeout
    case invalidTokenLimit
    case invalidCostLimit
    case invalidDeadline

    var errorDescription: String? {
        switch self {
        case .invalidField:
            return "The child spawn policy must be an object."
        case .unknownField:
            return "The child spawn policy contains an unknown field."
        case .invalidTimeout:
            return "The child timeout must be a finite positive number."
        case .invalidTokenLimit:
            return "The child token limit must be a positive decimal string."
        case .invalidCostLimit:
            return "The child estimated-cost limit must be a finite positive number."
        case .invalidDeadline:
            return "The child deadline could not be represented as a future host deadline."
        }
    }
}
