import Foundation

/// The exact identity of the input that was saved for a startup attempt.
///
/// A prompt alone is not an identity.  The association and the client-qualified command are
/// retained so presentation can only collapse the request that produced the visible Work/Session
/// input.  An unassociated PendingChat or an invalid start intent deliberately has no identity.
public struct StartupInputIdentity: Hashable, Sendable {
    public let association: ServiceAttachmentKey
    public let commandID: String
    public let prompt: String

    public init?(
        association: ServiceAttachmentKey,
        commandID: String,
        prompt: String
    ) {
        guard association.isValid,
              !commandID.isEmpty,
              commandID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              !commandID.unicodeScalars.contains(where: { $0.value == 0 }),
              prompt.utf8.count <= WorkServiceBounds.maxCommandValueCharacters else { return nil }
        self.association = association
        self.commandID = commandID
        self.prompt = prompt
    }

    public init?(pendingChat: PendingChat) {
        guard let association = pendingChat.createdAssociation else { return nil }
        self.init(
            association: association, commandID: pendingChat.startCommandID,
            prompt: pendingChat.prompt)
    }

    public init?(startIntent: ServiceBackedStartIntent) {
        guard let association = ServiceAttachmentKey(
            client: startIntent.client,
            clientAttachment: startIntent.clientAttachment,
            work: startIntent.work,
            session: startIntent.session,
            sessionJournal: startIntent.sessionJournal,
            sessionAttachment: startIntent.sessionAttachment) else { return nil }
        self.init(
            association: association, commandID: startIntent.commandID,
            prompt: startIntent.prompt)
    }

    /// The command identity used by the canonical Work command ledger.
    public var canonicalCommandID: String {
        WorkServiceCommandLedgerIdentity.commandID(
            client: association.client, commandID: commandID)
    }
}

/// Presentation-only startup deduplication.  It intentionally accepts the current visible
/// message list rather than a Session snapshot: a delivered input outside that bounded window is
/// not visible evidence and cannot suppress the saved startup echo.
public enum StartupChatPresentationPolicy {
    /// Colliding local requests must remain individually reachable even if one is delivered.
    /// Retiring only that member would make an unrelated survivor look safe to collapse.
    public static func hasAssociationCollision(_ chat: PendingChat, in savedRequests: [PendingChat]) -> Bool {
        guard let key = chat.createdAssociation else { return false }
        return savedRequests.filter { $0.createdAssociation == key }.count > 1
    }

    /// Return the startup prompt for rendering, or nil only when the exact startup input is
    /// already in the supplied currently visible message list.  A missing/uncanonical projection
    /// keeps the saved prompt as the recovery fallback; it is never guessed away.
    public static func savedPrompt(
        pendingChat: PendingChat?,
        startIntent: ServiceBackedStartIntent?,
        projection: WorkServiceAttachedWorkProjection?,
        visibleMessages: [SessionMessageSnapshot]
    ) -> String? {
        let prompt = pendingChat?.prompt ?? startIntent?.prompt
        guard let prompt, !prompt.isEmpty else { return nil }
        let startup: StartupInputIdentity?
        if let pendingChat {
            // An unresolved PendingChat owns this prompt; do not let a different fallback intent
            // qualify it for suppression merely because their text happens to be equal.
            startup = StartupInputIdentity(pendingChat: pendingChat)
        } else {
            startup = startIntent.flatMap(StartupInputIdentity.init(startIntent:))
        }
        guard let startup, let projection else { return prompt }
        guard projection.isCanonical else { return prompt }
        guard let projectionKey = ServiceAttachmentKey(
            work: projection.descriptor.work, attachment: projection.attachment),
              projectionKey == startup.association else { return prompt }
        let delivery = CanonicalInputDeliveryProjection(
            workSnapshot: projection.workSnapshot,
            sessionSnapshot: projection.sessionSnapshot,
            workSourceCompleteness: projection.workSourceCompleteness,
            sessionSourceCompleteness: projection.sessionSourceCompleteness,
            workOmissions: projection.workOmissions,
            sessionOmissions: projection.sessionOmissions)
        return shouldSuppressSavedStartupEcho(
            startup: startup, deliveryProjection: delivery,
            visibleMessages: visibleMessages) ? nil : prompt
    }

    /// The inverse of the collapse decision, for callers that need a simple row filter.  This
    /// remains presentation-only and deliberately does not delete or mutate the PendingChat.
    public static func showsPendingRow(
        _ chat: PendingChat,
        visibleAttachmentKeys: [ServiceAttachmentKey],
        hasRecoveryDetail: Bool
    ) -> Bool {
        guard !hasRecoveryDetail,
              chat.phase == .preparing || chat.phase == .awaitingAcceptance,
              let association = chat.createdAssociation,
              visibleAttachmentKeys.filter({ $0 == association }).count == 1 else {
            return true
        }
        return false
    }

    /// Suppress the saved startup echo only when the exact canonical start input is in the
    /// currently rendered message list.  Text equality is only one final check; all durable
    /// command, attachment, run, event, and causal identities must agree first.
    public static func shouldSuppressSavedStartupEcho(
        startup: StartupInputIdentity,
        deliveryProjection: CanonicalInputDeliveryProjection,
        visibleMessages: [SessionMessageSnapshot]
    ) -> Bool {
        shouldSuppressSavedStartupEcho(
            startup: startup, deliveryRows: deliveryProjection.rows,
            deliveryProjectionIsCanonical: deliveryProjection.isCanonical,
            deliveryOmissions: deliveryProjection.omissions,
            visibleMessages: visibleMessages)
    }

    /// Lower-level bounded form for callers that already hold the retained delivery rows.  It
    /// is also useful for small presentation tests without constructing a Work/Session store.
    public static func shouldSuppressSavedStartupEcho(
        startup: StartupInputIdentity,
        deliveryRows: [CanonicalInputDeliveryRow],
        deliveryProjectionIsCanonical: Bool,
        deliveryOmissions: [WorkServiceOmission] = [],
        visibleMessages: [SessionMessageSnapshot]
    ) -> Bool {
        guard deliveryProjectionIsCanonical, deliveryOmissions.isEmpty else { return false }

        let candidates = deliveryRows.filter { row in
            row.commandID == startup.canonicalCommandID
                && row.state != .provenanceUnavailable
                && row.issue == nil
                && row.commandKind == .start
                && row.client == startup.association.client
                && row.sessionAttachment == startup.association.workSession.sessionAttachment
        }
        guard candidates.count == 1, let row = candidates.first,
              let messageEvent = row.messageEvent,
              let acceptanceEvent = row.acceptanceEvent,
              let run = row.run else { return false }

        let messages = visibleMessages.filter { message in
            message.role == "user"
                && message.text == startup.prompt
                && message.eventID == messageEvent.eventID
                && message.sourceEvent == messageEvent
                && message.sourceEvent?.journal == startup.association.workSession.sessionJournal
                && message.client == startup.association.client
                && message.sessionAttachment == startup.association.workSession.sessionAttachment
                && message.causedBy == acceptanceEvent
                && message.run == run
        }
        guard messages.count == 1, let message = messages.first else { return false }

        // Keep these explicit even though the delivery projection normally establishes them;
        // this makes a forged/mixed row fail closed if a caller assembles the projection itself.
        return row.acceptanceEvent?.journal == .work(startup.association.workSession.work)
            && (row.deliveryEvent == nil
                || row.deliveryEvent?.journal == .work(startup.association.workSession.work))
            && message.sourceEvent == row.messageEvent
    }
}
