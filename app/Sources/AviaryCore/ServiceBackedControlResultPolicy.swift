import Foundation

/// A durable control result that a GUI can present without inferring a turn or provider outcome.
public enum ServiceBackedControlResult: Hashable, Sendable {
    /// The exact latest command for the attached Session owner is a canonically delivered Cancel.
    case stopRequestDelivered
}

/// Pure projection policy for durable control-result copy.
///
/// This intentionally does not interpret `turn.finished`: ``WorkSnapshot`` currently retains
/// only the resulting idle state, not that event's outcome. A delivered Cancel therefore proves
/// that the stop request reached Work, but not that an in-flight provider or action was
/// interrupted. Any later command for the same Session attachment suppresses the result.
public enum ServiceBackedControlResultPolicy {
    public static func latestResult(
        in projection: WorkServiceAttachedWorkProjection
    ) -> ServiceBackedControlResult? {
        let descriptor = projection.descriptor
        let work = projection.workSnapshot
        let session = projection.sessionSnapshot
        let attachment = projection.attachment
        guard projection.isCanonical, !projection.needsRecovery,
              !projection.requiresRefresh, !projection.commandInFlight,
              projection.pendingCommand == nil,
              projection.workSourceCompleteness == .complete,
              projection.sessionSourceCompleteness == .complete,
              projection.workOmissions.isEmpty, projection.sessionOmissions.isEmpty,
              descriptor.omissions.isEmpty,
              descriptor.recordedDisposition == .reusable,
              descriptor.execution == .idle,
              let currentRun = descriptor.currentRun,
              let ownerSession = descriptor.currentRunSession,
              let ownerSessionAttachment = descriptor.currentRunSessionAttachment,
              attachment.session == ownerSession,
              attachment.sessionAttachment == ownerSessionAttachment,
              attachment.sessionJournal == session.journal,
              session.session == ownerSession,
              work.journal == descriptor.journal,
              work.work == descriptor.work,
              work.lifecycle == .active, work.execution == .idle,
              work.activeRun == currentRun,
              work.activeRunSession == ownerSession,
              work.activeRunSessionAttachment == ownerSessionAttachment,
              work.activeTurn == nil, work.activeActionIDs.isEmpty,
              projection.workCursor.journal == descriptor.journal,
              ServiceBackedGUIControlPolicy(projection: projection).canSubmitText
        else { return nil }

        // A ClientAttachmentRef is not copied into command events. Require this projection to be
        // the only descriptor attachment for its client and Session relationship before using
        // the client-qualified command ledger as evidence for this GUI attachment.
        let exactClientRelationships = descriptor.attachments.filter {
            $0.client == attachment.client
                && $0.session == ownerSession
                && $0.sessionJournal == attachment.sessionJournal
                && $0.sessionAttachment == ownerSessionAttachment
        }
        guard exactClientRelationships.count == 1,
              exactClientRelationships[0].attachment == attachment.attachment else { return nil }

        var latestSequence: Int?
        var latestCommand: WorkCommandSnapshot?
        var latestSequenceIsAmbiguous = false
        for (ledgerID, command) in work.commands
        where command.command.sessionAttachment == ownerSessionAttachment {
            guard ledgerID == command.command.commandID,
                  command.command.client != nil,
                  let acceptance = command.acceptanceEventRef,
                  acceptance.journal == descriptor.journal,
                  let sequence = work.eventSequences[acceptance.eventID],
                  sequence > 0, sequence <= projection.workCursor.sequence,
                  sequence < projection.workCursor.sequence
                    || projection.workCursor.eventID == acceptance.eventID
            else { return nil }
            if let currentLatest = latestSequence, sequence == currentLatest {
                latestSequenceIsAmbiguous = true
            } else if latestSequence.map({ sequence > $0 }) ?? true {
                latestSequence = sequence
                latestCommand = command
                latestSequenceIsAmbiguous = false
            }
        }
        guard let latestSequence, let command = latestCommand,
              !latestSequenceIsAmbiguous else { return nil }
        guard command.commandKind == .cancel,
              command.acceptanceRun == currentRun,
              command.state == .delivered,
              let delivery = command.deliveryEventRef,
              delivery.journal == descriptor.journal,
              let deliverySequence = work.eventSequences[delivery.eventID],
              deliverySequence > latestSequence,
              deliverySequence <= projection.workCursor.sequence,
              deliverySequence < projection.workCursor.sequence
                || projection.workCursor.eventID == delivery.eventID
        else { return nil }
        return .stopRequestDelivered
    }
}
