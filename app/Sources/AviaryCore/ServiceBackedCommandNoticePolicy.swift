import Foundation

/// The exact Work command represented by a GUI acknowledgement banner.
///
/// A receipt is only host admission. Keeping this identity on the notice lets a later
/// canonical projection retire the banner without allowing an unrelated command, client, or
/// attachment to do so.
public struct ServiceBackedCommandNotice: Equatable, Hashable, Sendable {
    public enum Evidence: Equatable, Hashable, Sendable {
        /// The caller received an accepted receipt. Preserve the receipt/cursor correlation that
        /// prevents a later unrelated command from retiring its acknowledgement.
        case acceptedReceipt(resultingWorkCursor: JournalCursor)
        /// The response was lost or malformed. A complete canonical projection of this exact
        /// client-qualified command is sufficient to settle uncertainty without replaying it.
        case canonicalCommand
    }

    public let work: WorkRef
    public let commandID: String
    public let kind: WorkServiceCommandKind
    public let client: ClientRef
    public let attachment: ClientAttachmentRef
    public let sessionAttachment: SessionAttachmentRef?
    public let evidence: Evidence

    public init(
        work: WorkRef,
        commandID: String,
        kind: WorkServiceCommandKind,
        client: ClientRef,
        attachment: ClientAttachmentRef,
        sessionAttachment: SessionAttachmentRef?,
        evidence: Evidence
    ) {
        self.work = work
        self.commandID = commandID
        self.kind = kind
        self.client = client
        self.attachment = attachment
        self.sessionAttachment = sessionAttachment
        self.evidence = evidence
    }
}

/// Pure lifecycle policy for a service-backed acknowledgement or uncertainty notice.
///
/// ``clear`` means the canonical Work journal has caught up with the exact accepted command;
/// it does not mean that a provider has delivered a response. Receipt-backed notices retain the
/// receipt/cursor correlation, while a notice created after lost confirmation can be settled by
/// the exact canonical command alone. An incomplete read, a foreign command, or a missing exact
/// canonical record retains the notice.
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
        guard projection.pendingCommand == nil,
              let command = exactCanonicalCommandEvidence(for: notice, in: projection)
        else { return .retain }

        if case .canonicalCommand = notice.evidence {
            return .clear
        }

        guard case .acceptedReceipt(let resultingCursor) = notice.evidence,
              reaches(projection.workCursor, resulting: resultingCursor),
              let eventID = resultingCursor.eventID,
              command.acceptanceEventRef == EventRef(
                  journal: resultingCursor.journal, eventID: eventID),
              projection.workSnapshot.eventSequences[eventID] == resultingCursor.sequence
        else { return .retain }
        return .clear
    }

    /// Whether this complete projection contains a host-recorded acceptance/delivery of the
    /// exact client-qualified command. Unlike notice retirement, this crossing predicate does
    /// not require the controller's single pending slot to be empty: a later pending command
    /// cannot erase evidence that this earlier command reached Work.
    public static func hasExactCanonicalCommandEvidence(
        for notice: ServiceBackedCommandNotice,
        in projection: WorkServiceAttachedWorkProjection
    ) -> Bool {
        exactCanonicalCommandEvidence(for: notice, in: projection) != nil
    }

    /// Internal typed evidence for Core policies that must correlate command-specific producer
    /// facts beyond the public yes/no crossing predicate.
    static func exactCanonicalCommandEvidence(
        for notice: ServiceBackedCommandNotice,
        in projection: WorkServiceAttachedWorkProjection
    ) -> WorkCommandSnapshot? {
        guard projection.isCanonical,
              projection.descriptor.work == notice.work,
              projection.attachment.client == notice.client,
              projection.attachment.attachment == notice.attachment,
              projection.workSnapshot.journal == projection.descriptor.journal,
              projection.workCursor.journal == projection.descriptor.journal
        else { return nil }
        let canonicalID = WorkServiceCommandLedgerIdentity.commandID(
            client: notice.client, commandID: notice.commandID)
        guard let command = projection.workSnapshot.commands[canonicalID],
              command.command.commandID == canonicalID,
              command.command.client == notice.client,
              command.command.sessionAttachment == notice.sessionAttachment,
              let commandKind = command.commandKind,
              canonicalKinds(for: notice.kind).contains(commandKind),
              command.state == .accepted || command.state == .delivered,
              let acceptance = command.acceptanceEventRef,
              acceptance.journal == projection.descriptor.journal,
              !acceptance.eventID.isEmpty,
              // Host execution order and journal position are independent domains. Locate the
              // acceptance in the reduced journal before comparing it with the Work cursor.
              let acceptanceSequence = projection.workSnapshot.eventSequences[acceptance.eventID],
              acceptanceSequence > 0,
              command.acceptanceHostSequence > 0,
              acceptanceSequence <= projection.workCursor.sequence,
              acceptanceSequence < projection.workCursor.sequence
                  || projection.workCursor.eventID == acceptance.eventID
        else { return nil }
        return command
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

    /// Native Session journals and the Work-service API use different labels for two equivalent
    /// operations. Accept only those explicit aliases; every other service command remains an
    /// exact one-to-one vocabulary match.
    private static func canonicalKinds(
        for kind: WorkServiceCommandKind
    ) -> Set<CanonicalCommandKind> {
        switch kind {
        case .start: return [.start]
        case .send: return [.send]
        case .steer: return [.steer]
        case .queue: return [.queue, .queueFollowUp]
        case .hold: return [.hold]
        case .cancel: return [.cancel]
        case .end: return [.end, .endRun]
        case .destroy: return [.destroy]
        case .complete: return [.complete]
        }
    }
}
