import Foundation

/// Pure decisions at the boundary between the Work-service projection and GUI presentation.
///
/// AppModel owns transport and persistence, but it should not decide whether a recovered
/// mutation is safe to replay or whether a background observation is allowed to move focus.
/// Keeping those decisions here makes the passive/explicit distinction executable without
/// importing SwiftUI or depending on a live Work Host.
public enum ServiceBackedGUIOrchestration {
    /// The exact prompt/command pair that may cross the Work-service Start boundary.
    public struct StartCommand: Hashable, Sendable {
        public let prompt: String
        public let commandID: String?

        public init(prompt: String, commandID: String?) {
            self.prompt = prompt
            self.commandID = commandID
        }
    }

    /// Resolve a Start without ever borrowing the body from one intent and the identity from
    /// another. While a bootstrap Start is retained, it is the only Start that may cross: a
    /// fresh composer command cannot safely prove the earlier Start stayed outside Work.
    public static func startCommand(
        prompt: String,
        commandID: String?,
        retained: ServiceBackedStartIntent?
    ) -> StartCommand? {
        guard let retained else {
            return StartCommand(prompt: prompt, commandID: commandID)
        }
        guard prompt == retained.prompt,
              commandID == nil || commandID == retained.commandID else { return nil }
        return StartCommand(prompt: prompt, commandID: retained.commandID)
    }

    /// Main-actor command admission reduced to a value type so retry/recovery/quit interleavings
    /// can be tested without importing the SwiftUI executable. All operations that can resolve a
    /// durable handoff participate in the same counter as new composer submissions.
    public struct CommandBarrier: Hashable, Sendable {
        public private(set) var admissionFrozen = false
        public private(set) var operationsInFlight = 0

        public init() {}

        public mutating func begin(
            hasUnresolvedDraft: Bool,
            allowingUnresolvedDraft: Bool = false
        ) -> Bool {
            guard !admissionFrozen,
                  operationsInFlight == 0,
                  allowingUnresolvedDraft || !hasUnresolvedDraft else { return false }
            operationsInFlight += 1
            return true
        }

        /// Returns true when every admitted operation has settled.
        @discardableResult
        public mutating func finish() -> Bool {
            guard operationsInFlight > 0 else { return false }
            operationsInFlight -= 1
            return operationsInFlight == 0
        }

        public mutating func freeze() {
            admissionFrozen = true
        }

        public mutating func resume() {
            admissionFrozen = false
        }

        public func canResolveUnresolvedDraft(
            hasUnresolvedDraft: Bool,
            isEnding: Bool
        ) -> Bool {
            hasUnresolvedDraft && !isEnding && operationsInFlight == 0
        }
    }

    public enum ReconciliationMode: Hashable, Sendable {
        case passivePolling
        case explicitCreate
    }

    /// The only recovery fact that can be adopted by the GUI. The key includes the minted client
    /// attachment as well as the Work/Session relationship, so a recovery cannot accidentally
    /// collapse two Sessions that happen to live on one Work.
    public struct RecoveredCreateSession: Hashable, Sendable {
        public let request: WorkServiceCreateSessionRequest
        public let attachmentKey: ServiceAttachmentKey

        public init?(
            request: WorkServiceCreateSessionRequest,
            attachmentKey: ServiceAttachmentKey
        ) {
            guard attachmentKey.client == request.client,
                  attachmentKey.workSession.work == request.work,
                  attachmentKey.workSession.sessionJournal.owner
                      == .session(attachmentKey.workSession.session),
                  attachmentKey.workSession.sessionJournal.authority.authorityID
                      == request.work.workHostID,
                  attachmentKey.clientAttachment != request.attachment else { return nil }
            self.request = request
            self.attachmentKey = attachmentKey
        }
    }

    public enum CreateSessionOutcome: Hashable, Sendable {
        /// The response was validated against the exact retained request and yielded one exact
        /// minted client attachment. A merely well-shaped response is not enough to construct
        /// this case; callers must pass the failable ``RecoveredCreateSession`` initializer.
        case recovered(RecoveredCreateSession)
        /// The host proved that this request was not admitted. It is safe to clear the marker.
        case rejected
        /// Transport or incomplete evidence leaves admission unknown. The marker must remain.
        case blocked
    }

    public struct CreateSessionObservation: Hashable, Sendable {
        public let request: WorkServiceCreateSessionRequest
        public let outcome: CreateSessionOutcome

        public init(
            request: WorkServiceCreateSessionRequest,
            outcome: CreateSessionOutcome
        ) {
            self.request = request
            self.outcome = outcome
        }
    }

    public struct CreateSessionDecision: Hashable, Sendable {
        /// Requests whose durable marker can be removed after this pass.
        public let cleared: [WorkServiceCreateSessionRequest]
        /// Requests that must stay on disk, including requests with no observation and blocked
        /// observations. This is deliberately a value rather than a count so callers cannot
        /// accidentally replace a blocked record with a newly-generated command.
        public let retained: [WorkServiceCreateSessionRequest]
        /// Only exact, request-qualified recoveries are adopted.
        public let recoveries: [RecoveredCreateSession]
        /// An explicit Create gesture may mint a new Session only when every prior marker has
        /// been definitively cleared and no exact recovery already served the gesture.
        public let shouldIssueCreateSession: Bool
        /// Passive polling may adopt an exact recovered row, but it never changes presentation
        /// focus. Explicit Create is allowed to show the recovered Session to the user.
        public let shouldFocusRecovery: Bool

        public init(
            cleared: [WorkServiceCreateSessionRequest],
            retained: [WorkServiceCreateSessionRequest],
            recoveries: [RecoveredCreateSession],
            shouldIssueCreateSession: Bool,
            shouldFocusRecovery: Bool
        ) {
            self.cleared = cleared
            self.retained = retained
            self.recoveries = recoveries
            self.shouldIssueCreateSession = shouldIssueCreateSession
            self.shouldFocusRecovery = shouldFocusRecovery
        }
    }

    /// Reconcile observations without collapsing records by command id. Matching uses the full
    /// request value, and an observation carrying a recovery for a different request remains
    /// retained rather than becoming an adoption of the wrong Session.
    public static func reconcileCreateSession(
        pending: [WorkServiceCreateSessionRequest],
        observations: [CreateSessionObservation],
        mode: ReconciliationMode
    ) -> CreateSessionDecision {
        var cleared: [WorkServiceCreateSessionRequest] = []
        var retained: [WorkServiceCreateSessionRequest] = []
        var recoveries: [RecoveredCreateSession] = []

        for request in pending {
            let matches = observations.filter { $0.request == request }
            guard matches.count == 1, let observation = matches.first else {
                retained.append(request)
                continue
            }
            switch observation.outcome {
            case .rejected:
                cleared.append(request)
            case .blocked:
                retained.append(request)
            case .recovered(let recovery):
                guard recovery.request == request else {
                    retained.append(request)
                    continue
                }
                cleared.append(request)
                recoveries.append(recovery)
            }
        }

        let canIssue = mode == .explicitCreate
            && recoveries.isEmpty
            && retained.isEmpty
        return CreateSessionDecision(
            cleared: cleared,
            retained: retained,
            recoveries: recoveries,
            shouldIssueCreateSession: canIssue,
            shouldFocusRecovery: mode == .explicitCreate && !recoveries.isEmpty)
    }

    /// Presentation state intentionally contains only stable GUI facts. A passive poll returns
    /// these values unchanged while still handing exact recoveries to the caller for adoption.
    public struct PresentationState: Hashable, Sendable {
        public let selectedSessionID: String?
        public let focusedAttachment: ServiceAttachmentKey?

        public init(selectedSessionID: String?, focusedAttachment: ServiceAttachmentKey?) {
            self.selectedSessionID = selectedSessionID
            self.focusedAttachment = focusedAttachment
        }
    }

    public struct PassivePollingDecision: Hashable, Sendable {
        public let presentation: PresentationState
        public let adopted: [ServiceAttachmentKey]

        public init(presentation: PresentationState, adopted: [ServiceAttachmentKey]) {
            self.presentation = presentation
            self.adopted = adopted
        }
    }

    /// A poll can reconcile and adopt rows, but it cannot select a different row or reattach a
    /// detached row into the foreground. Duplicate keys are coalesced in encounter order.
    public static func passivePolling(
        current: PresentationState,
        recoveries: [RecoveredCreateSession]
    ) -> PassivePollingDecision {
        var seen: Set<ServiceAttachmentKey> = []
        let adopted = recoveries.compactMap { recovery -> ServiceAttachmentKey? in
            seen.insert(recovery.attachmentKey).inserted ? recovery.attachmentKey : nil
        }
        return PassivePollingDecision(presentation: current, adopted: adopted)
    }

    /// Resolve the target behind an explicit Inspect/Attach gesture. The target is qualified by
    /// Work, Session journal, Session attachment, and client. Any duplicate semantic target or
    /// duplicate client attachment is rejected rather than resolved by descriptor ordering.
    public struct InspectDecision: Hashable, Sendable {
        public let target: AttachTargetKey
        public let existingAttachment: WorkServiceClientAttachment?
        public let existingAttachmentKey: ServiceAttachmentKey?
        /// Inspect is an explicit user gesture, so the selected/reattached exact key may become
        /// the foreground row. Passive catalog polling never uses this decision.
        public let shouldFocus: Bool

        public init(
            target: AttachTargetKey,
            existingAttachment: WorkServiceClientAttachment?,
            existingAttachmentKey: ServiceAttachmentKey?,
            shouldFocus: Bool = true
        ) {
            self.target = target
            self.existingAttachment = existingAttachment
            self.existingAttachmentKey = existingAttachmentKey
            self.shouldFocus = shouldFocus
        }
    }

    public static func inspect(
        descriptor: WorkServiceWorkDescriptor,
        client: ClientRef,
        targetSessionAttachment: SessionAttachmentRef
    ) -> InspectDecision? {
        guard let workSession = descriptor.exactAttachmentQualifiedSessionTarget(
            targetSessionAttachment),
            let target = AttachTargetKey(client: client, workSession: workSession) else {
            return nil
        }

        let matches = descriptor.attachments.filter {
            $0.client == client
                && $0.session == workSession.session
                && $0.sessionJournal == workSession.sessionJournal
                && $0.sessionAttachment == workSession.sessionAttachment
        }
        guard matches.count <= 1 else { return nil }
        guard let existing = matches.first else {
            return InspectDecision(
                target: target, existingAttachment: nil, existingAttachmentKey: nil)
        }
        guard let key = ServiceAttachmentKey(work: descriptor.work, attachment: existing),
              key.client == client,
              key.workSession == workSession else { return nil }
        return InspectDecision(
            target: target, existingAttachment: existing, existingAttachmentKey: key)
    }
}
