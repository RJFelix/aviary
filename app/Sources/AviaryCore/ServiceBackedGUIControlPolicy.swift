import Foundation

/// Pure, executable policy for the controls shown by a GUI attached to one Session on one Work.
///
/// The GUI is a projection, not an authority. This value therefore accepts only canonical facts
/// already established by the Work service and never guesses an owner from attachment order or
/// treats transport connectivity as permission. Keeping the decision in AviaryCore lets every
/// client render the same controls and makes the composer contract testable without SwiftUI.
public struct ServiceBackedGUIControlPolicy: Hashable, Sendable {
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
        requiresRefresh: Bool
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
            requiresRefresh: projection.requiresRefresh)
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
        isCanonical && !needsRecovery && !requiresRefresh
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
