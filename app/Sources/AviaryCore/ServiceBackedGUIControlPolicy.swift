import Foundation

/// Pure, executable policy for the controls shown by a GUI attached to one Session on one Work.
///
/// The GUI is a projection, not an authority. This value therefore accepts only canonical facts
/// already established by the Work service and never guesses an owner from attachment order or
/// treats transport connectivity as permission. Keeping the decision in AviaryCore lets every
/// client render the same controls and makes the composer contract testable without SwiftUI.
public struct ServiceBackedGUIControlPolicy: Hashable, Sendable {
    public enum PassiveInspectionFailureDisposition: Hashable, Sendable {
        case preservePresentation
        case surfaceUncertainty
    }

    /// Read diagnostics are retained history, not the outcome of the latest refresh. A
    /// verified fresh projection retires their blocking presentation, without deleting them.
    public static func blockingReadDiagnostic(in projection: WorkServiceAttachedWorkProjection) -> String? {
        projection.isCanonical ? nil : projection.readDiagnostics.last
    }

    public let execution: WorkServiceExecutionState
    public let currentRun: RunRef?
    public let currentRunSession: SessionRef?
    public let currentRunSessionAttachment: SessionAttachmentRef?
    public let attachedSession: SessionRef?
    public let attachedSessionAttachment: SessionAttachmentRef?
    public let capabilities: Set<WorkServiceCapability>
    public let isCanonical: Bool
    public let needsRecovery: Bool
    public let requiresRefresh: Bool
    public let commandInFlight: Bool
    private var exactUnadmittedStartRecovery = false

    public init(
        execution: WorkServiceExecutionState,
        currentRun: RunRef?,
        currentRunSession: SessionRef?,
        currentRunSessionAttachment: SessionAttachmentRef?,
        attachedSession: SessionRef?,
        attachedSessionAttachment: SessionAttachmentRef?,
        capabilities: Set<WorkServiceCapability>,
        isCanonical: Bool,
        needsRecovery: Bool,
        requiresRefresh: Bool,
        commandInFlight: Bool = false
    ) {
        self.execution = execution
        self.currentRun = currentRun
        self.currentRunSession = currentRunSession
        self.currentRunSessionAttachment = currentRunSessionAttachment
        self.attachedSession = attachedSession
        self.attachedSessionAttachment = attachedSessionAttachment
        self.capabilities = capabilities
        self.isCanonical = isCanonical
        self.needsRecovery = needsRecovery
        self.requiresRefresh = requiresRefresh
        self.commandInFlight = commandInFlight
    }

    public init(projection: WorkServiceAttachedWorkProjection) {
        self.init(
            execution: projection.descriptor.execution,
            currentRun: projection.descriptor.currentRun,
            currentRunSession: projection.descriptor.currentRunSession,
            currentRunSessionAttachment: projection.descriptor.currentRunSessionAttachment,
            attachedSession: projection.attachment.session,
            attachedSessionAttachment: projection.attachment.sessionAttachment,
            capabilities: projection.capabilities,
            isCanonical: projection.isCanonical,
            needsRecovery: projection.needsRecovery,
            requiresRefresh: projection.requiresRefresh,
            commandInFlight: projection.commandInFlight)
        if let pending = projection.pendingCommand {
            // A host may retain a Start reservation before it has a Run. Only the explicit
            // retry of that exact, current request can ask the host to finish admission.
            exactUnadmittedStartRecovery = !projection.commandInFlight && projection.isCanonical
                && !projection.requiresRefresh
                && execution == .recoveryRequired
                && currentRun == nil && currentRunSession == nil && currentRunSessionAttachment == nil
                && projection.workSnapshot.activeRun == nil
                && projection.workSnapshot.activeRunSession == nil
                && projection.workSnapshot.activeRunSessionAttachment == nil
                && projection.workSnapshot.execution == .idle
                && pending.kind == .start && pending.state == .indeterminate
                && pending.causalWorkCursor == projection.workCursor
                && pending.client == projection.attachment.client
                && pending.attachment == projection.attachment.attachment
                && pending.sessionAttachment == projection.attachment.sessionAttachment
                && hasExactRunOwner && capabilities.contains(.control) && capabilities.contains(.start)
        }
    }

    /// An idle Work has no owner tuple. An active Work is controllable only by the exact Session
    /// relationship named by `run.started`; another GUI attached to that same Session qualifies,
    /// while a client attached to a different Session remains observe-only for this Run.
    public var hasExactRunOwner: Bool {
        guard let currentRun else {
            return currentRunSession == nil && currentRunSessionAttachment == nil
        }
        guard Self.validIdentity(currentRun.runID),
              let currentRunSession,
              Self.validIdentity(currentRunSession.sessionID),
              let currentRunSessionAttachment,
              Self.validIdentity(currentRunSessionAttachment.attachmentID),
              let attachedSession,
              Self.validIdentity(attachedSession.sessionID),
              let attachedSessionAttachment,
              Self.validIdentity(attachedSessionAttachment.attachmentID) else { return false }
        return currentRunSession == attachedSession
            && currentRunSessionAttachment == attachedSessionAttachment
    }

    private var canMutate: Bool {
        isCanonical && !needsRecovery && !requiresRefresh && !commandInFlight
            && hasExactRunOwner && capabilities.contains(.control)
    }

    /// True when the next composer submission must mint a Run rather than append to one.
    public var requiresStartForNextInput: Bool {
        canMutate && currentRun == nil && execution == .idle
            && capabilities.contains(.start)
    }

    public var canSubmitText: Bool {
        guard canMutate else { return false }
        switch execution {
        case .idle where currentRun == nil:
            return capabilities.contains(.start)
        case .idle:
            return capabilities.contains(.send)
        case .running:
            return capabilities.contains(.steer) || capabilities.contains(.queue)
        case .held, .canceling, .ending, .recoveryRequired, .unknown:
            return false
        }
    }

    /// Background direct-command observation is useful only at a settled, current boundary.
    /// Explicit Inspect remains available to surface errors; this gate prevents ordinary model
    /// execution or recovery from turning an opportunistic tray refresh into UI uncertainty.
    public var allowsPassiveDirectShellInspection: Bool {
        isCanonical && !needsRecovery && !requiresRefresh && execution == .idle
    }

    /// Direct shell execution is a mutation on the exact active Run. It is available only at
    /// the same canonical idle boundary used by other control decisions; capability visibility
    /// alone must never make a recovery, catch-up, or foreign-Session projection actionable.
    public var canRunDirectShell: Bool {
        canMutate && currentRun != nil && execution == .idle
            && capabilities.contains(.directShell)
    }

    /// A passive read never replaces an earlier explicit uncertainty. With no known outstanding
    /// command it also stays silent; only a previously observed live/pending command makes a new
    /// background inspection failure user-relevant.
    public static func passiveInspectionFailureDisposition(
        hasExistingUncertainty: Bool,
        hasOutstandingCommand: Bool
    ) -> PassiveInspectionFailureDisposition {
        !hasExistingUncertainty && hasOutstandingCommand
            ? .surfaceUncertainty : .preservePresentation
    }

    public var canEnd: Bool {
        guard canMutate, currentRun != nil, capabilities.contains(.end) else { return false }
        switch execution {
        case .idle, .running, .held, .canceling: return true
        case .ending, .recoveryRequired, .unknown: return false
        }
    }

    public var commandCapabilities: SessionCommandCapabilities {
        guard canMutate else { return SessionCommandCapabilities() }
        var cancellationScopes: Set<SessionCancellationScope> = []
        if capabilities.contains(.cancel) { cancellationScopes.insert(.agentLoop) }
        return SessionCommandCapabilities(
            supportsSteering: capabilities.contains(.steer),
            supportsQueuedFollowUps: capabilities.contains(.queue),
            cancellationScopes: cancellationScopes)
    }

    public func canRetryPendingCommand(kind: WorkServiceCommandKind) -> Bool {
        if kind == .start && exactUnadmittedStartRecovery { return true }
        guard canMutate, capabilities.contains(Self.capability(for: kind)) else { return false }
        switch kind {
        case .start: return currentRun == nil
        default: return currentRun != nil
        }
    }

    private static func capability(for kind: WorkServiceCommandKind) -> WorkServiceCapability {
        switch kind {
        case .start: return .start
        case .send: return .send
        case .steer: return .steer
        case .queue: return .queue
        case .cancel: return .cancel
        case .end: return .end
        case .hold: return .hold
        case .destroy: return .destroy
        case .complete: return .complete
        }
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= WorkServiceBounds.maxIdentityCharacters
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

/// Process-local presentation grace for the short interval between an accepted Start receipt
/// and the live actor becoming observable through the attached Work projection.
///
/// This value never grants mutation authority. It can only replace a transient
/// `recoveryRequired` presentation with `preparing`, and only after the canonical journal has
/// authenticated the exact accepted Start. The first qualifying projection binds one Run; a
/// later Run, Session, attachment, host instance, terminal lifecycle, or healthy execution state
/// clears the grace instead of retargeting it.
public struct ServiceBackedStartPresentationGrace: Hashable, Sendable {
    public enum Disposition: Hashable, Sendable {
        case awaitingCanonicalEvidence
        case presentPreparing
        case clear
    }

    public static let maximumDuration: TimeInterval = 10

    private let work: WorkRef
    private let commandID: String
    private let client: ClientRef
    private let attachment: ClientAttachmentRef
    private let session: SessionRef
    private let sessionAttachment: SessionAttachmentRef
    private let host: WorkHostInstanceRef
    private let hostSequence: Int
    private let resultingWorkCursor: JournalCursor
    private let expiresAt: Date
    private var run: RunRef?

    public init?(
        receipt: WorkServiceCommandReceipt,
        attachment: WorkServiceClientAttachment,
        now: Date,
        duration: TimeInterval = ServiceBackedStartPresentationGrace.maximumDuration
    ) {
        guard receipt.state == .accepted,
              receipt.outcome == .started,
              receipt.hostProvenance == .current,
              let hostSequence = receipt.hostSequence, hostSequence > 0,
              let resultingWorkCursor = receipt.resultingWorkCursor,
              let session = attachment.session,
              let sessionAttachment = attachment.sessionAttachment,
              receipt.authorization.granted.contains(.control),
              receipt.authorization.granted.contains(.start),
              duration.isFinite, duration > 0 else { return nil }
        self.work = receipt.work
        self.commandID = receipt.commandID
        self.client = attachment.client
        self.attachment = attachment.attachment
        self.session = session
        self.sessionAttachment = sessionAttachment
        self.host = receipt.host
        self.hostSequence = hostSequence
        self.resultingWorkCursor = resultingWorkCursor
        self.expiresAt = now.addingTimeInterval(min(duration, Self.maximumDuration))
        self.run = nil
    }

    /// Reconcile against a newly read projection. Callers retain the value only for `awaiting`
    /// or `presentPreparing`; `clear` is terminal for this process-local grace.
    public mutating func reconcile(
        projection: WorkServiceAttachedWorkProjection,
        now: Date
    ) -> Disposition {
        guard now < expiresAt,
              projection.descriptor.work == work,
              projection.descriptor.journal == resultingWorkCursor.journal,
              projection.attachment.client == client,
              projection.attachment.attachment == attachment,
              projection.attachment.session == session,
              projection.attachment.sessionAttachment == sessionAttachment,
              projection.descriptor.recordedDisposition == .reusable,
              projection.workSnapshot.lifecycle == .active,
              projection.sessionSnapshot.lifecycle == .active else { return .clear }

        guard Self.reaches(projection.workCursor, resulting: resultingWorkCursor) else {
            // An older retained projection is ordinary post-receipt catch-up. Once the cursor has
            // reached the receipt, every mismatch below is current evidence and clears at once.
            return projection.workCursor.journal == resultingWorkCursor.journal
                && projection.workCursor.sequence < resultingWorkCursor.sequence
                ? .awaitingCanonicalEvidence : .clear
        }

        let notice = ServiceBackedCommandNotice(
            work: work, commandID: commandID, kind: .start, client: client,
            attachment: attachment, sessionAttachment: sessionAttachment,
            evidence: .acceptedReceipt(resultingWorkCursor: resultingWorkCursor))
        guard projection.isCanonical,
              projection.pendingCommand == nil,
              let command = ServiceBackedCommandNoticePolicy.exactCanonicalCommandEvidence(
                  for: notice, in: projection),
              projection.descriptor.execution == .recoveryRequired,
              projection.workSnapshot.execution == .preparing
                  || projection.workSnapshot.execution == .running,
              let currentRun = projection.descriptor.currentRun,
              command.acceptanceRun == currentRun,
              command.acceptanceHostSequence == hostSequence,
              projection.descriptor.currentRunSession == session,
              projection.descriptor.currentRunSessionAttachment == sessionAttachment,
              projection.workSnapshot.activeRun == currentRun,
              projection.workSnapshot.activeRunSession == session,
              projection.workSnapshot.activeRunSessionAttachment == sessionAttachment,
              let observation = projection.descriptor.hostObservation,
              observation.instance == host,
              observation.sourceCompleteness == .complete,
              observation.servedCursor.map({
                  Self.reaches($0, resulting: resultingWorkCursor)
              }) == true,
              observation.currentRun == currentRun,
              observation.currentRunSession == session,
              observation.currentRunSessionAttachment == sessionAttachment else { return .clear }

        if let run {
            guard run == currentRun else { return .clear }
        } else {
            run = currentRun
        }
        return .presentPreparing
    }

    /// A side-effect-free presentation check for render paths. An unbound receipt candidate is
    /// never enough; `reconcile` must first have authenticated and captured the exact Run.
    public func presentsPreparing(
        projection: WorkServiceAttachedWorkProjection,
        now: Date
    ) -> Bool {
        guard run != nil else { return false }
        var copy = self
        return copy.reconcile(projection: projection, now: now) == .presentPreparing
            && copy.run == run
    }

    private static func reaches(
        _ candidate: JournalCursor, resulting required: JournalCursor
    ) -> Bool {
        guard candidate.journal == required.journal,
              candidate.sequence >= required.sequence else { return false }
        return candidate.sequence > required.sequence || candidate.eventID == required.eventID
    }
}
