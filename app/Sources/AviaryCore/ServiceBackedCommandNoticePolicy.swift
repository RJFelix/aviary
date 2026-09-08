import Foundation

/// The exact Work command represented by a GUI acknowledgement banner.
///
/// A receipt is only host admission. Keeping this identity on the notice lets a later
/// canonical projection retire the banner without allowing an unrelated command, client, or
/// attachment to do so.
public struct ServiceBackedCommandNotice: Equatable, Hashable, Sendable {
    public let work: WorkRef
    public let commandID: String
    public let kind: WorkServiceCommandKind
    public let client: ClientRef
    public let attachment: ClientAttachmentRef
    public let sessionAttachment: SessionAttachmentRef?

    public init(
        work: WorkRef,
        commandID: String,
        kind: WorkServiceCommandKind,
        client: ClientRef,
        attachment: ClientAttachmentRef,
        sessionAttachment: SessionAttachmentRef?
    ) {
        self.work = work
        self.commandID = commandID
        self.kind = kind
        self.client = client
        self.attachment = attachment
        self.sessionAttachment = sessionAttachment
    }
}

/// Pure lifecycle policy for a service-backed success notice.
///
/// ``clear`` means the canonical Work journal has caught up with the exact accepted command;
/// it does not mean that a provider has delivered a response. In particular, a canonical
/// ``accepted`` command remains distinct from ``delivered``. An incomplete read, a foreign
/// command, or a missing exact canonical record retains the acknowledgement.
/// Transport connectivity is intentionally not another gate: a complete canonical snapshot is
/// valid evidence even while the host is offline. The attached controller marks a failed read's
/// retained snapshot incomplete, which is covered by ``isCanonical`` and prevents stale clearing.
public enum ServiceBackedCommandNoticeDisposition: Equatable, Sendable {
    case retain
    case clear
}

public enum ServiceBackedCommandNoticePolicy {
    public static func disposition(
        for notice: ServiceBackedCommandNotice,
        projection: WorkServiceAttachedWorkProjection
    ) -> ServiceBackedCommandNoticeDisposition {
        guard projection.isCanonical,
              projection.descriptor.work == notice.work,
              projection.attachment.client == notice.client,
              projection.attachment.attachment == notice.attachment,
              projection.pendingCommand == nil,
              let receipt = projection.lastReceipt,
              (receipt.state == .accepted || receipt.state == .duplicate),
              receipt.work == notice.work,
              receipt.commandID == notice.commandID,
              outcomeMatches(receipt, kind: notice.kind),
              let resultingCursor = receipt.resultingWorkCursor,
              reaches(projection.workCursor, resulting: resultingCursor),
              let eventID = resultingCursor.eventID
        else {
            return .retain
        }

        let canonicalID = WorkServiceCommandLedgerIdentity.commandID(
            client: notice.client, commandID: notice.commandID)
        guard let command = projection.workSnapshot.commands[canonicalID],
              command.command.commandID == canonicalID,
              command.command.client == notice.client,
              command.command.sessionAttachment == notice.sessionAttachment,
              command.commandKind == canonicalKind(for: notice.kind),
              command.state != .rejected,
              command.state != .indeterminate,
              command.acceptanceEventRef == EventRef(
                  journal: resultingCursor.journal, eventID: eventID)
        else {
            return .retain
        }
        return .clear
    }

    public static func shouldClear(
        _ notice: ServiceBackedCommandNotice,
        from projection: WorkServiceAttachedWorkProjection
    ) -> Bool {
        disposition(for: notice, projection: projection) == .clear
    }

    private static func reaches(_ candidate: JournalCursor, resulting required: JournalCursor) -> Bool {
        guard candidate.journal == required.journal,
              candidate.sequence >= required.sequence else { return false }
        return candidate.sequence > required.sequence || candidate.eventID == required.eventID
    }

    private static func outcomeMatches(
        _ receipt: WorkServiceCommandReceipt,
        kind: WorkServiceCommandKind
    ) -> Bool {
        switch kind {
        case .start:
            return receipt.outcome == .started || receipt.outcome == .startRecoveryRequired
        case .send: return receipt.outcome == .inputAccepted
        case .steer: return receipt.outcome == .steeringAccepted
        case .queue: return receipt.outcome == .queued
        case .hold: return receipt.outcome == .holdRequested
        case .cancel: return receipt.outcome == .cancellationRequested
        case .end: return receipt.outcome == .endRequested
        case .destroy: return receipt.outcome == .destroyed
        case .complete: return receipt.outcome == .completed
        }
    }

    private static func canonicalKind(for kind: WorkServiceCommandKind) -> CanonicalCommandKind {
        switch kind {
        case .start: return .start
        case .send: return .send
        case .steer: return .steer
        case .queue: return .queue
        case .hold: return .hold
        case .cancel: return .cancel
        case .end: return .end
        case .destroy: return .destroy
        case .complete: return .complete
        }
    }
}
