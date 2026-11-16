import Foundation

/// Session/turn subset of the installed Muse 1.3.0-R3401.1 stable MSP schema.
/// Source: https://meta-models.github.io/muse-code-sdk/next/guides/msp-wire/
/// `session/start` is durable creation, while `turn/start` and `turn/cancel` replies
/// are intake acknowledgements. Only view events report execution and terminals.
public enum MuseMSPSession {
    /// A UUIDv7-shaped command id with a millisecond timestamp and random tail.
    /// Retain the returned id across any retry; never generate a replacement after
    /// an uncertain acknowledgement.
    public static func newCommandID() -> String {
        let millis = UInt64(Date().timeIntervalSince1970 * 1_000)
        let random = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let timestamp = String(format: "%012llx", millis)
        return "\(timestamp.prefix(8))-\(timestamp.suffix(4))-7\(random.prefix(3))-8\(random.dropFirst(3).prefix(3))-\(random.dropFirst(6).prefix(12))"
    }
}

public struct MuseMSPSessionStart: Sendable, Equatable {
    public let sessionID: String
    public let viewCursor: String
    public let session: JSONValue

    public init(_ raw: JSONValue) throws {
        guard let session = raw["session"], case .object = session,
              let sessionID = session["sessionId"]?.stringValue, !sessionID.isEmpty,
              let viewCursor = raw["viewCursor"]?.stringValue else {
            throw MuseMSPError.invalidResponse
        }
        self.sessionID = sessionID
        self.viewCursor = viewCursor
        self.session = session
    }
}

public struct MuseMSPSessionRead: Sendable, Equatable {
    public let session: JSONValue
    public let history: JSONValue
    public let pendingRequests: [JSONValue]
    public let viewCursor: String

    public init(_ raw: JSONValue) throws {
        guard let session = raw["session"], case .object = session,
              let history = raw["history"], case .object = history,
              let pendingRequests = raw["pendingRequests"]?.arrayValue,
              let viewCursor = raw["viewCursor"]?.stringValue else {
            throw MuseMSPError.invalidResponse
        }
        self.session = session
        self.history = history
        self.pendingRequests = pendingRequests
        self.viewCursor = viewCursor
    }
}

/// Durable session reattachment response. History describes what the host served to
/// reconstruct a view; absent/elided history does not say whether a turn is executing.
public struct MuseMSPSessionResume: Sendable, Equatable {
    public let sessionID: String
    public let viewCursor: String
    public let session: JSONValue
    public let history: JSONValue
    public let pendingRequests: [JSONValue]

    public var historyMode: String? { history["mode"]?.stringValue }
    /// Present only when the host served inline history. Other history modes require
    /// their own snapshot/page interpretation and are deliberately not flattened here.
    public var inlineItems: [JSONValue]? { history["items"]?.arrayValue }

    public init(_ raw: JSONValue, expectedSessionID: String,
                expectedWorkspaceRoot: String? = nil) throws {
        guard !expectedSessionID.isEmpty,
              let session = raw["session"], case .object = session,
              let sessionID = session["sessionId"]?.stringValue,
              sessionID == expectedSessionID,
              let history = raw["history"], case .object = history,
              history["mode"]?.stringValue != nil,
              let items = history["items"], items.isNull || items.arrayValue != nil,
              let pendingRequests = raw["pendingRequests"]?.arrayValue,
              let viewCursor = raw["viewCursor"]?.stringValue,
              !viewCursor.isEmpty else {
            throw MuseMSPError.invalidResponse
        }
        if let expectedWorkspaceRoot {
            guard let workspaceRoot = session["workspaceRoot"]?.stringValue,
                  workspaceRoot == expectedWorkspaceRoot else {
                throw MuseMSPError.invalidResponse
            }
        }
        self.sessionID = sessionID
        self.viewCursor = viewCursor
        self.session = session
        self.history = history
        self.pendingRequests = pendingRequests
    }
}

public struct MuseMSPTurnStartAck: Sendable, Equatable {
    public let commandID: String
    public let status: String
    public let disposition: String
    public let startedNewTurn: Bool
    public let turnID: String

    public init(_ raw: JSONValue) throws {
        guard let commandID = raw["commandId"]?.stringValue,
              let status = raw["status"]?.stringValue,
              !status.isEmpty,
              let disposition = raw["disposition"]?.stringValue,
              !disposition.isEmpty,
              let startedNewTurn = raw["startedNewTurn"]?.boolValue,
              let turnID = raw["turnId"]?.stringValue,
              !turnID.isEmpty else { throw MuseMSPError.invalidResponse }
        self.commandID = commandID
        self.status = status
        self.disposition = disposition
        self.startedNewTurn = startedNewTurn
        self.turnID = turnID
    }
}

public struct MuseMSPTurnCancelAck: Sendable, Equatable {
    public let commandID: String
    public let status: String
    public let turnID: String

    public init(_ raw: JSONValue) throws {
        guard let commandID = raw["commandId"]?.stringValue,
              let status = raw["status"]?.stringValue,
              !status.isEmpty,
              let turnID = raw["turnId"]?.stringValue else {
            throw MuseMSPError.invalidResponse
        }
        self.commandID = commandID
        self.status = status
        self.turnID = turnID
    }
}

public struct MuseMSPApprovalDecisionAck: Sendable, Equatable {
    public let commandID: String
    public let approvalID: String
    public let status: String
    /// Stage resolution, not necessarily the approval's durable view terminal.
    public let terminal: Bool

    public init(_ raw: JSONValue) throws {
        guard let commandID = raw["commandId"]?.stringValue,
              let approvalID = raw["approvalId"]?.stringValue,
              let status = raw["status"]?.stringValue,
              !status.isEmpty,
              let terminal = raw["terminal"]?.boolValue else {
            throw MuseMSPError.invalidResponse
        }
        self.commandID = commandID
        self.approvalID = approvalID
        self.status = status
        self.terminal = terminal
    }
}

/// Exact current approval stage token supplied by the host. A stale source index
/// is rejected rather than being applied to a later stage.
public struct MuseMSPApprovalRequirement: Codable, Sendable, Equatable {
    public let approvalID: String
    public let sourceIndex: Int

    public init(approvalID: String, sourceIndex: Int) {
        self.approvalID = approvalID
        self.sourceIndex = sourceIndex
    }

    public init(_ raw: JSONValue) throws {
        guard let approvalID = raw["approvalId"]?.stringValue,
              let sourceIndex = raw["sourceIndex"]?.intValue else {
            throw MuseMSPError.invalidResponse
        }
        self.init(approvalID: approvalID, sourceIndex: sourceIndex)
    }

    public var raw: JSONValue {
        .object(["approvalId": .string(approvalID),
                 "sourceIndex": .number(Double(sourceIndex))])
    }
}

public struct MuseMSPViewPage: Sendable, Equatable {
    public let events: [MuseMSPViewEvent]
    public let nextCursor: String?

    public init(_ raw: JSONValue) throws {
        guard let rows = raw["events"]?.arrayValue,
              let next = raw["nextCursor"],
              next.isNull || next.stringValue != nil else {
            throw MuseMSPError.invalidResponse
        }
        self.events = try rows.map(MuseMSPViewEvent.init)
        self.nextCursor = next.stringValue
    }
}

/// Carries the exact host params, plus fields essential for safe routing. Unknown
/// view methods remain visible rather than being silently discarded.
public struct MuseMSPViewEvent: Sendable, Equatable {
    public let method: String
    public let sessionID: String
    public let viewCursor: String
    public let params: JSONValue

    public init(_ raw: JSONValue) throws {
        guard let method = raw["method"]?.stringValue,
              let params = raw["params"], case .object = params,
              let sessionID = params["sessionId"]?.stringValue,
              let viewCursor = params["viewCursor"]?.stringValue else {
            throw MuseMSPError.invalidResponse
        }
        self.method = method
        self.sessionID = sessionID
        self.viewCursor = viewCursor
        self.params = params
    }

    public init?(_ incoming: MuseMSPIncoming) throws {
        guard case .notification(let method, let params, _) = incoming,
              let params else { return nil }
        try self.init(.object(["method": .string(method), "params": params]))
    }

    public var textDelta: (itemID: String, field: String, delta: String)? {
        guard method == "item/delta", let itemID = params["itemId"]?.stringValue,
              let delta = params["delta"]?.stringValue else { return nil }
        return (itemID, params["field"]?.stringValue ?? "text", delta)
    }

    /// Text deltas whose field is a reasoning summary (for example `summary.0`).
    /// Reasoning is never assumed to be model-visible; callers decide whether to
    /// show or persist it based on the field name and the item's kind.
    public var reasoningDelta: (itemID: String, field: String, delta: String)? {
        guard let delta = textDelta, delta.field.hasPrefix("summary.") else { return nil }
        return delta
    }

    /// The full item carried by an item lifecycle notification. Item kinds are an
    /// open set, so this deliberately returns the lossless object rather than a
    /// closed Swift enum.
    public var item: JSONValue? {
        guard method == "item/started" || method == "item/updated" || method == "item/completed" else {
            return nil
        }
        return params["item"]
    }

    public var itemID: String? { item?["itemId"]?.stringValue ?? params["itemId"]?.stringValue }
    public var itemKind: String? { item?["kind"]?.stringValue }
    public var itemStatus: String? { item?["status"]?.stringValue }

    public var turnStarted: (commandID: String, turnID: String)? {
        guard method == "turn/started",
              let commandID = params["commandId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue else { return nil }
        return (commandID, turnID)
    }

    /// Approval requests are surfaced as raw, lossless params. In particular,
    /// `currentRequirementId` is not interchangeable with an older source index.
    public var approvalRequest: JSONValue? {
        method == "approval/requested" ? params : nil
    }

    public var currentApprovalRequirement: MuseMSPApprovalRequirement? {
        guard method == "approval/requested", let raw = params["currentRequirementId"] else {
            return nil
        }
        return try? MuseMSPApprovalRequirement(raw)
    }

    /// Usage is attached to turn completion or session token-usage notifications.
    /// Return the complete params so newer usage fields remain available.
    public var usage: JSONValue? {
        guard method == "turn/completed" || method == "session/tokenUsage" || method == "usage/changed" else {
            return nil
        }
        return params
    }

    public var completedItem: JSONValue? {
        method == "item/completed" ? params["item"] : nil
    }

    public var turnTerminal: (turnID: String, terminal: String, error: JSONValue?)? {
        guard method == "turn/completed", let turnID = params["turnId"]?.stringValue,
              let terminal = params["terminal"]?.stringValue else { return nil }
        return (turnID, terminal, params["error"])
    }
}

public extension MuseMSPConnection {
    /// Starts and auto-subscribes this connection. The caller owns `commandID`.
    func sessionStart(commandID: String, workspaceRoot: String,
                      modelID: String? = nil, providerID: String? = nil) async throws
        -> MuseMSPSessionStart {
        guard !commandID.isEmpty, workspaceRoot.hasPrefix("/") else {
            throw MuseMSPError.invalidResponse
        }
        var params: [String: JSONValue] = [
            "commandId": .string(commandID), "workspaceRoot": .string(workspaceRoot),
        ]
        if let modelID { params["modelId"] = .string(modelID) }
        if let providerID { params["providerId"] = .string(providerID) }
        return try MuseMSPSessionStart(try await request("session/start", params: .object(params)))
    }

    /// A point-in-time read. It neither loads nor subscribes to the session.
    func sessionRead(_ sessionID: String, excludeItems: Bool = true) async throws
        -> MuseMSPSessionRead {
        try MuseMSPSessionRead(try await request("session/read", params: .object([
            "sessionId": .string(sessionID), "excludeItems": .bool(excludeItems),
        ])))
    }

    /// Loads and attaches this connection to a durable session. The response's
    /// history mode is authoritative; none/elided history is not execution evidence.
    func sessionResume(_ sessionID: String, commandID: String,
                       cursor: String? = nil, history: String? = nil,
                       excludeItems: Bool = false,
                       expectedWorkspaceRoot: String? = nil) async throws
        -> MuseMSPSessionResume {
        guard !sessionID.isEmpty, !commandID.isEmpty,
              cursor.map({ !$0.isEmpty }) ?? true,
              history.map({ ["auto", "inline", "snapshot", "anchored"].contains($0) }) ?? true else {
            throw MuseMSPError.invalidResponse
        }
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionID), "commandId": .string(commandID),
            "excludeItems": .bool(excludeItems),
        ]
        if let cursor { params["cursor"] = .string(cursor) }
        if let history { params["history"] = .string(history) }
        let raw = try await request("session/resume", params: .object(params))
        return try MuseMSPSessionResume(raw, expectedSessionID: sessionID,
                                        expectedWorkspaceRoot: expectedWorkspaceRoot)
    }

    /// `after` must be an observed cursor; omitted means live events from now.
    func viewSubscribe(_ sessionID: String, after: String? = nil) async throws -> String {
        var params: [String: JSONValue] = ["sessionId": .string(sessionID)]
        if let after { params["after"] = .string(after) }
        let raw = try await request("view/subscribe", params: .object(params))
        guard let cursor = raw["viewCursor"]?.stringValue else {
            throw MuseMSPError.invalidResponse
        }
        return cursor
    }

    func viewPage(_ sessionID: String, after cursor: String? = nil,
                  limit: Int = 100) async throws -> MuseMSPViewPage {
        guard (1...1_000).contains(limit) else { throw MuseMSPError.invalidResponse }
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionID), "limit": .number(Double(limit)),
            "direction": .string("forward"),
        ]
        if let cursor { params["cursor"] = .string(cursor) }
        return try MuseMSPViewPage(try await request("view/page", params: .object(params)))
    }

    /// Only an intake ack. Observe `turn/completed` for the terminal outcome.
    func turnStart(sessionID: String, commandID: String, text: String,
                   ifBusy: String = "queue") async throws -> MuseMSPTurnStartAck {
        guard !text.isEmpty, ["queue", "steer", "replace"].contains(ifBusy) else {
            throw MuseMSPError.invalidResponse
        }
        let raw = try await request("turn/start", params: .object([
            "sessionId": .string(sessionID), "commandId": .string(commandID),
            "input": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "ifBusy": .string(ifBusy),
        ]))
        let ack = try MuseMSPTurnStartAck(raw)
        guard ack.commandID == commandID else { throw MuseMSPError.invalidResponse }
        return ack
    }

    /// Plain cancellation on the normal command lane, not a priority interrupt.
    func turnCancel(sessionID: String, commandID: String,
                    turnID: String? = nil) async throws -> MuseMSPTurnCancelAck {
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionID), "commandId": .string(commandID),
        ]
        if let turnID { params["turnId"] = .string(turnID) }
        let ack = try MuseMSPTurnCancelAck(try await request("turn/cancel", params: .object(params)))
        guard ack.commandID == commandID else { throw MuseMSPError.invalidResponse }
        return ack
    }

    /// Caller must present a current server-issued choice and requirement id.
    /// Never infer an approval choice or auto-approve from its display text.
    func approvalDecide(sessionID: String, approvalID: String,
                        requirement: MuseMSPApprovalRequirement,
                        choiceID: String, commandID: String,
                        feedback: String? = nil) async throws -> MuseMSPApprovalDecisionAck {
        guard requirement.approvalID == approvalID else { throw MuseMSPError.invalidResponse }
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionID), "approvalId": .string(approvalID),
            "requirementId": requirement.raw, "choiceId": .string(choiceID),
            "commandId": .string(commandID),
        ]
        if let feedback { params["feedback"] = .string(feedback) }
        let ack = try MuseMSPApprovalDecisionAck(
            try await request("approval/decide", params: .object(params)))
        guard ack.commandID == commandID, ack.approvalID == approvalID else {
            throw MuseMSPError.invalidResponse
        }
        return ack
    }
}
