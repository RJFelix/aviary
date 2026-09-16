import Foundation

/// The fixed, user-facing availability statements for an action.  These are statements about
/// this projection's evidence, not promises that a provider or Python runtime was contained.
public struct WorkActionAvailability: Codable, Hashable, Sendable {
    public let exactInput: String
    public let output: String
    public let effects: String
    public let confirmation: String
    public let checkpoint: String

    public init(exactInput: String, output: String, effects: String,
                confirmation: String, checkpoint: String) {
        self.exactInput = exactInput
        self.output = output
        self.effects = effects
        self.confirmation = confirmation
        self.checkpoint = checkpoint
    }
}

/// A bounded, privacy-safe GUI projection of one canonical Work action.
///
/// This type is intentionally a projection rather than a second reducer.  Lifecycle evidence is
/// copied from validated observations, and no arbitrary producer metadata is carried through:
/// only its count and truncation bit are exposed.  The `intent` and `target` fields are separate
/// because an action can have an understandable intent without having a target (or vice versa).
public struct WorkActionPresentation: Codable, Hashable, Sendable, Identifiable {
    public static let maxIdentifierCharacters = 256
    public static let maxCausalLinks = TimelineEvent.maxEvidenceLinks

    public let id: String
    public var actionID: String { id }
    public let identifierWasTruncated: Bool
    public let kind: ActionKind
    public let kindTitle: String
    public let state: ActionExecutionState
    public let stateTitle: String
    public let intent: String?
    public let affectedTarget: String?
    public let scope: String?
    public let metadataEntryCount: Int
    public let metadataWasTruncated: Bool

    /// These are canonical host timestamps from the action's lifecycle observations. Client time
    /// is never used here. An end before a start is retained as evidence but produces no duration.
    public let hostStartTime: Date?
    public let hostEndTime: Date?
    public let durationSeconds: TimeInterval?
    public let timeAvailability: String

    public let failureKind: ActionFailureKind?
    public let retrySafety: ActionRetrySafety?
    /// Always populated for terminal states, including cancellation and indeterminate effects.
    public let failureGuidance: String?
    public let retryGuidance: String?

    /// WorkActionObservation is already the canonical, journal-qualified lifecycle reference.
    /// Its primary cause and parent remain distinct from the bounded typed link collection; the
    /// presentation never invents `derived_from` links from those different relationships.
    public let intentEvidence: WorkActionObservation?
    public let startedEvidence: WorkActionObservation?
    public let outcomeEvidence: WorkActionObservation?
    public let causalLinks: [TimelineLink]
    /// Link records omitted either at a lifecycle-observation boundary or while combining the
    /// retained observations. Source-level omitted links have unknown identity, so this is a
    /// record count rather than a claim that every omitted link was distinct.
    public let omittedCausalLinkCount: Int
    /// A saturated source count is rendered as a lower bound; the projection never turns a
    /// defensive arithmetic cap into a false exactness claim.
    public let omittedCausalLinkCountIsLowerBound: Bool

    /// Fixed strings make the boundary legible without copying arbitrary producer metadata.
    public let availability: WorkActionAvailability
    public let boundaryDisclosure: String

    public init(_ snapshot: WorkActionSnapshot) {
        let boundedID = Self.boundIdentifier(snapshot.action.actionID)
        self.id = boundedID.value
        self.identifierWasTruncated = boundedID.wasTruncated
        self.kind = snapshot.kind
        self.kindTitle = Self.kindTitle(snapshot.kind)
        self.state = snapshot.state
        self.stateTitle = Self.stateTitle(snapshot.state)
        self.intent = snapshot.intent
        self.affectedTarget = snapshot.target
        self.scope = snapshot.scope
        self.metadataEntryCount = snapshot.metadata.count
        self.metadataWasTruncated = snapshot.metadataWasTruncated

        self.hostStartTime = snapshot.startedEvent?.hostRecordedAt
        self.hostEndTime = snapshot.outcomeEvent?.hostRecordedAt
        if let start = hostStartTime, let end = hostEndTime, end >= start {
            self.durationSeconds = end.timeIntervalSince(start)
            self.timeAvailability = "canonical host start and end recorded"
        } else if hostStartTime != nil, hostEndTime != nil {
            self.durationSeconds = nil
            self.timeAvailability = "canonical host times conflict; duration withheld"
        } else if hostStartTime != nil {
            self.durationSeconds = nil
            self.timeAvailability = "canonical host start recorded; action has no canonical end"
        } else if hostEndTime != nil {
            self.durationSeconds = nil
            self.timeAvailability = "canonical host end recorded; action start is unavailable"
        } else {
            self.durationSeconds = nil
            self.timeAvailability = "canonical host timing unavailable"
        }

        self.failureKind = snapshot.failureKind
        self.retrySafety = snapshot.retrySafety
        if snapshot.state.isTerminal {
            self.failureGuidance = Self.failureGuidance(for: snapshot.state, kind: snapshot.failureKind)
            self.retryGuidance = Self.retryGuidance(for: snapshot.retrySafety)
        } else {
            self.failureGuidance = nil
            self.retryGuidance = nil
        }

        self.intentEvidence = snapshot.intentEvent
        self.startedEvidence = snapshot.startedEvent
        self.outcomeEvidence = snapshot.outcomeEvent
        let causalLinkProjection = Self.causalLinks(from: snapshot)
        self.causalLinks = causalLinkProjection.links
        self.omittedCausalLinkCount = causalLinkProjection.omittedCount
        self.omittedCausalLinkCountIsLowerBound = causalLinkProjection.isLowerBound
        self.availability = Self.availability(for: snapshot)
        self.boundaryDisclosure = Self.boundaryDisclosure(for: snapshot.kind)
    }

    /// Return the GUI order: all unsettled actions first, then newest terminal actions.  This
    /// prevents an old resolved history from pushing an active action below the 256-row cap.
    public static func project(_ actions: [WorkActionSnapshot]) -> [WorkActionPresentation] {
        Array(projectWithOmissions(actions).presentations)
    }

    /// Return the canonical bounded snapshot order for consumers that still need reducer
    /// snapshots (for example a controller bridge). The ordering is shared with `project(_:)`.
    public static func retainedSnapshots(
        _ actions: [WorkActionSnapshot], limit: Int = 256
    ) -> [WorkActionSnapshot] {
        let safeLimit = max(0, min(limit, 256))
        return Array(orderedActions(actions).prefix(safeLimit).map(\.action))
    }

    public struct Projection: Codable, Hashable, Sendable {
        public let presentations: [WorkActionPresentation]
        public let omittedUnsettledCount: Int
        public let omittedTerminalCount: Int
        public let totalCount: Int

        public var omittedCount: Int { omittedUnsettledCount + omittedTerminalCount }
        public var wasTruncated: Bool { omittedCount > 0 }
    }

    public static func projectWithOmissions(
        _ actions: [WorkActionSnapshot], limit: Int = 256
    ) -> Projection {
        let safeLimit = max(0, min(limit, 256))
        let ordered = orderedActions(actions)
        let retained = Array(ordered.prefix(safeLimit))
        let unsettled = ordered.filter { !$0.action.state.isTerminal }
        let terminal = ordered.filter { $0.action.state.isTerminal }
        let retainedUnsettled = min(unsettled.count, retained.count)
        let omittedUnsettled = unsettled.count - retainedUnsettled
        let omittedTerminal = terminal.count - max(0, retained.count - retainedUnsettled)
        return Projection(
            presentations: retained.map { WorkActionPresentation($0.action) },
            omittedUnsettledCount: omittedUnsettled,
            omittedTerminalCount: omittedTerminal,
            totalCount: actions.count)
    }

    private static func orderedActions(_ actions: [WorkActionSnapshot])
        -> [(index: Int, action: WorkActionSnapshot, sequence: Int)] {
        let indexed = actions.enumerated().map { index, action in
            (index: index, action: action, sequence: sequence(of: action))
        }
        let unsettled = indexed.filter { !$0.action.state.isTerminal }.sorted(by: displayOrder)
        let terminal = indexed.filter { $0.action.state.isTerminal }.sorted {
            if $0.sequence != $1.sequence { return $0.sequence > $1.sequence }
            if $0.action.action.actionID != $1.action.action.actionID {
                return $0.action.action.actionID < $1.action.action.actionID
            }
            return $0.index < $1.index
        }
        return unsettled + terminal
    }

    private static func sequence(of action: WorkActionSnapshot) -> Int {
        if action.state.isTerminal {
            return action.outcomeEvent?.sequence ?? action.startedEvent?.sequence
                ?? action.intentEvent?.sequence ?? Int.max
        }
        switch action.state {
        case .running, .cancelRequested:
            return action.startedEvent?.sequence ?? action.intentEvent?.sequence
                ?? action.outcomeEvent?.sequence ?? Int.max
        case .queued, .proposed, .unknown:
            return action.intentEvent?.sequence ?? action.startedEvent?.sequence
                ?? action.outcomeEvent?.sequence ?? Int.max
        case .succeeded, .failed, .canceled, .indeterminateEffect:
            return action.outcomeEvent?.sequence ?? action.startedEvent?.sequence
                ?? action.intentEvent?.sequence ?? Int.max
        }
    }

    private static func displayOrder(
        _ lhs: (index: Int, action: WorkActionSnapshot, sequence: Int),
        _ rhs: (index: Int, action: WorkActionSnapshot, sequence: Int)
    ) -> Bool {
        let lhsPriority = unsettledPriority(lhs.action.state)
        let rhsPriority = unsettledPriority(rhs.action.state)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.action.action.actionID != rhs.action.action.actionID {
            return lhs.action.action.actionID < rhs.action.action.actionID
        }
        return lhs.index < rhs.index
    }

    private static func unsettledPriority(_ state: ActionExecutionState) -> Int {
        switch state {
        case .running, .cancelRequested: return 0
        case .queued: return 1
        case .proposed: return 2
        case .unknown: return 3
        case .succeeded, .failed, .canceled, .indeterminateEffect: return 4
        }
    }

    private static func boundIdentifier(_ value: String) -> (value: String, wasTruncated: Bool) {
        guard value.utf8.count > maxIdentifierCharacters else { return (value, false) }
        let digest = AviarySHA256.hash(data: Data(value.utf8)).description
        let suffix = "-" + String(digest.prefix(48))
        let prefixLimit = maxIdentifierCharacters - suffix.utf8.count
        var result = ""
        var bytes = 0
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= prefixLimit else { break }
            result.append(character)
            bytes += count
        }
        return (result + suffix, true)
    }

    private static func stateTitle(_ state: ActionExecutionState) -> String {
        switch state {
        case .cancelRequested: return "Cancel requested"
        case .indeterminateEffect: return "Effect indeterminate"
        default: return state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func kindTitle(_ kind: ActionKind) -> String {
        switch kind {
        case .provider: return "Model response"
        case .compactionProvider: return "Conversation summary"
        case .providerSetup: return "Connecting to model"
        case .python: return "Python execution"
        case .mcp: return "MCP operation"
        case .runtime: return "Runtime operation"
        case .hook: return "Hook"
        case .peerDelivery: return "Peer delivery"
        case .selfDelivery: return "Self delivery"
        case .webSearch: return "Web search"
        case .webExtract: return "Web extraction"
        case .child: return "Child Work"
        case .memory: return "Memory operation"
        case .artifact: return "Artifact operation"
        case .imageRead: return "Image read"
        case .nestedProcessCallback: return "Nested process callback"
        }
    }

    private static func failureGuidance(
        for state: ActionExecutionState, kind: ActionFailureKind?
    ) -> String {
        switch state {
        case .succeeded: return "The action completed; inspect its recorded outcome before repeating it."
        case .failed:
            let label = kind?.rawValue.replacingOccurrences(of: "_", with: " ") ?? "unspecified"
            return "The action failed (\(label)); inspect the recorded outcome before retrying."
        case .canceled: return "The action was canceled; confirm no partial effect before trying again."
        case .indeterminateEffect:
            return "The effect is indeterminate; reconcile the external target before any retry."
        default: return "The action is not terminal."
        }
    }

    private static func retryGuidance(for safety: ActionRetrySafety?) -> String {
        switch safety {
        case .safe: return "Retry is explicitly safe."
        case .idempotent: return "Retry is idempotent; use a fresh command identity and re-check the outcome."
        case .unsafe: return "Do not retry automatically; the action is marked unsafe to repeat."
        case .unknown, .none: return "Retry safety is unknown; do not retry automatically."
        }
    }

    private static func causalLinks(from snapshot: WorkActionSnapshot)
        -> (links: [TimelineLink], omittedCount: Int, isLowerBound: Bool) {
        var unique: [TimelineLink] = []
        var sourceOmitted = 0
        var isLowerBound = false
        for observation in [snapshot.intentEvent, snapshot.startedEvent, snapshot.outcomeEvent]
            .compactMap({ $0 }) {
            let omitted = max(0, observation.omittedEvidenceLinkCount ?? 0)
            if omitted == TimelineEvent.maxOmittedEvidenceLinkCount {
                isLowerBound = true
            }
            sourceOmitted += min(Int.max - sourceOmitted, omitted)
            for link in observation.links where !unique.contains(link) {
                unique.append(link)
            }
        }
        let retained = Array(unique.prefix(maxCausalLinks))
        let mergeOmitted = unique.count - retained.count
        return (
            retained,
            sourceOmitted + min(Int.max - sourceOmitted, mergeOmitted),
            isLowerBound)
    }

    private static func availability(for snapshot: WorkActionSnapshot) -> WorkActionAvailability {
        let input: String
        if snapshot.intent == nil {
            input = "exact input not recorded"
        } else if snapshot.metadataWasTruncated {
            input = "exact input unavailable; bounded intent recorded and metadata is truncated"
        } else {
            input = "exact input unavailable; bounded intent recorded"
        }
        let output = snapshot.outcomeEvent == nil
            ? "canonical output not observed"
            : "canonical outcome observed; output body is not in this projection"
        let effects = snapshot.outcomeEvent == nil
            ? "effects not yet determined"
            : "effect status recorded; external effect contents are not proven"
        let confirmation = snapshot.kind == .python || snapshot.kind == .mcp
            ? "confirmation is not recorded by this action projection"
            : "confirmation is not recorded"
        let checkpoint = "recovery checkpoint coverage is not recorded by this action projection"
        return WorkActionAvailability(exactInput: input, output: output, effects: effects,
                                      confirmation: confirmation, checkpoint: checkpoint)
    }

    private static func boundaryDisclosure(for kind: ActionKind) -> String {
        switch kind {
        case .python:
            return "Python may perform file, process, socket, and network effects; Aviary does not observe or contain those effects here."
        case .mcp:
            return "The MCP boundary is recorded, but server-side effects are not contained by this projection."
        case .provider, .compactionProvider:
            return "Provider input/output status is recorded at Aviary's boundary; provider-side effects are not independently proven."
        case .providerSetup:
            return "Provider configuration and credential resolution are recorded; this is not a model request."
        case .runtime, .nestedProcessCallback:
            return "Runtime activity is recorded at the host boundary; process internals are not contained by this projection."
        case .hook:
            return "Hooks may block or rewrite a call, but this projection is not a general security boundary."
        case .peerDelivery, .selfDelivery:
            return "Delivery status is recorded; recipient-side processing is not independently observed here."
        case .webSearch, .webExtract:
            return "Network retrieval is recorded; remote content and side effects are not contained here."
        case .child:
            return "Child Work lifecycle is recorded; child runtime effects require its own canonical action evidence."
        case .memory:
            return "Memory selection is recorded; source contents are intentionally omitted from this projection."
        case .artifact:
            return "Artifact identity/status is recorded; artifact contents require explicit inspection."
        case .imageRead:
            return "Image-read status is recorded; image contents are not copied into this projection."
        }
    }
}
