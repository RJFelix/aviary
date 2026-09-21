import Foundation
@testable import AviaryCore

private func startupPolicyKey(_ suffix: String = "a") throws -> ServiceAttachmentKey {
    let work = WorkRef(workHostID: "startup-policy-host", workID: "startup-policy-work")
    let session = SessionRef("startup-policy-session-\(suffix)")
    let workSession = try XCTUnwrap(WorkSessionKey(
        work: work, session: session,
        sessionJournal: .session(session, journalID: "startup-policy-journal-\(suffix)",
                                  authority: TimelineAuthorityRef(work.workHostID)),
        sessionAttachment: SessionAttachmentRef("startup-policy-session-attachment-\(suffix)")))
    return try XCTUnwrap(ServiceAttachmentKey(
        client: ClientRef("startup-policy-client"),
        clientAttachment: ClientAttachmentRef("startup-policy-client-attachment-\(suffix)"),
        workSession: workSession))
}

private func startupPolicyRow(
    key: ServiceAttachmentKey,
    commandID: String,
    prompt: String,
    run: RunRef = RunRef("startup-policy-run"),
    messageEventID: String = "startup-policy-message",
    acceptanceEventID: String = "startup-policy-accepted",
    deliveryEventID: String = "startup-policy-delivered"
) -> (CanonicalInputDeliveryRow, SessionMessageSnapshot) {
    let workJournal = JournalRef.work(key.workSession.work)
    let sessionJournal = key.workSession.sessionJournal
    let acceptance = EventRef(journal: workJournal, eventID: acceptanceEventID)
    let delivery = EventRef(journal: workJournal, eventID: deliveryEventID)
    let messageEvent = EventRef(journal: sessionJournal, eventID: messageEventID)
    let row = CanonicalInputDeliveryRow(
        id: "startup-policy-row", commandID: commandID, messageEvent: messageEvent,
        acceptanceEvent: acceptance, deliveryEvent: delivery, hostSequence: 3,
        client: key.client, sessionAttachment: key.workSession.sessionAttachment, run: run,
        commandKind: .start, deliveryMode: .queued, state: .delivered, issue: nil)
    let message = SessionMessageSnapshot(
        eventID: messageEventID, role: "user", text: prompt, sourceEvent: messageEvent,
        run: run, client: key.client,
        sessionAttachment: key.workSession.sessionAttachment, causedBy: acceptance)
    return (row, message)
}

let casesStartupPresentationPolicy: [Case] = [
    ("startup presentation: sidebar collapse requires exact visible association", {
        let key = try startupPolicyKey()
        let chat = try PendingChat(
            prompt: "same", cwd: "/tmp", phase: .awaitingAcceptance,
            startCommandID: "startup", createdAssociation: key)
        XCTAssertFalse(StartupChatPresentationPolicy.showsPendingRow(
            chat, visibleAttachmentKeys: [key], hasRecoveryDetail: false))
        XCTAssertTrue(StartupChatPresentationPolicy.showsPendingRow(
            chat, visibleAttachmentKeys: [], hasRecoveryDetail: false))
        XCTAssertTrue(StartupChatPresentationPolicy.showsPendingRow(
            chat, visibleAttachmentKeys: [try startupPolicyKey("other")],
            hasRecoveryDetail: false))
        XCTAssertTrue(StartupChatPresentationPolicy.showsPendingRow(
            chat, visibleAttachmentKeys: [key, key], hasRecoveryDetail: false))
        let conflict = try PendingChat(
            prompt: "different unsent request", cwd: "/tmp", phase: .awaitingAcceptance,
            startCommandID: "other-startup", createdAssociation: key)
        XCTAssertFalse(StartupChatPresentationPolicy.hasAssociationCollision(chat, in: [chat]))
        XCTAssertTrue(StartupChatPresentationPolicy.hasAssociationCollision(chat, in: [chat, conflict]))
        XCTAssertTrue(StartupChatPresentationPolicy.hasAssociationCollision(conflict, in: [chat, conflict]))
        XCTAssertFalse(StartupChatPresentationPolicy.hasAssociationCollision(conflict, in: [conflict]))
        let sameClientAttachment = try XCTUnwrap(ServiceAttachmentKey(
            client: key.client, clientAttachment: key.clientAttachment,
            workSession: try XCTUnwrap(WorkSessionKey(
                work: key.workSession.work, session: SessionRef("other-session"),
                sessionJournal: .session(
                    SessionRef("other-session"), journalID: "other-journal",
                    authority: TimelineAuthorityRef(key.workSession.work.workHostID)),
                sessionAttachment: SessionAttachmentRef("other-attachment")))))
        XCTAssertTrue(StartupChatPresentationPolicy.showsPendingRow(
            chat, visibleAttachmentKeys: [sameClientAttachment], hasRecoveryDetail: false))
    }),
    ("startup presentation: recovery and saved states retain the durable row", {
        let key = try startupPolicyKey()
        let chat = try PendingChat(
            prompt: "same", cwd: "/tmp", phase: .awaitingAcceptance,
            startCommandID: "startup", createdAssociation: key)
        XCTAssertTrue(StartupChatPresentationPolicy.showsPendingRow(
            chat, visibleAttachmentKeys: [key], hasRecoveryDetail: true))
        let blocked = try chat.changing(phase: .blocked)
        XCTAssertTrue(StartupChatPresentationPolicy.showsPendingRow(
            blocked, visibleAttachmentKeys: [key], hasRecoveryDetail: false))
        let saved = try PendingChat(prompt: "same", cwd: "/tmp")
        XCTAssertTrue(StartupChatPresentationPolicy.showsPendingRow(
            saved, visibleAttachmentKeys: [key], hasRecoveryDetail: false))
        let staleFailure = try PendingChat(
            prompt: "same", cwd: "/tmp", phase: .preparing,
            failureKind: .providerUnavailable, createdAssociation: key)
        XCTAssertFalse(StartupChatPresentationPolicy.showsPendingRow(
            staleFailure, visibleAttachmentKeys: [key], hasRecoveryDetail: false))
    }),
    ("startup presentation: exact visible canonical start suppresses only its saved echo", {
        let key = try startupPolicyKey()
        let startup = try XCTUnwrap(StartupInputIdentity(
            association: key, commandID: "startup", prompt: "same"))
        let (row, message) = startupPolicyRow(
            key: key, commandID: startup.canonicalCommandID, prompt: startup.prompt)
        let suppress: ([SessionMessageSnapshot]) -> Bool = { messages in
            StartupChatPresentationPolicy.shouldSuppressSavedStartupEcho(
                startup: startup, deliveryRows: [row],
                deliveryProjectionIsCanonical: true, visibleMessages: messages)
        }
        XCTAssertTrue(suppress([message]))
        XCTAssertFalse(suppress([message, message]))
        let sameEventIDForeignSource = SessionMessageSnapshot(
            eventID: message.eventID, role: message.role, text: message.text,
            sourceEvent: EventRef(journal: key.workSession.sessionJournal, eventID: "foreign"),
            run: message.run, client: message.client,
            sessionAttachment: message.sessionAttachment, causedBy: message.causedBy)
        XCTAssertFalse(suppress([sameEventIDForeignSource]))

        let acceptedVisibleRow = CanonicalInputDeliveryRow(
            id: row.id, commandID: row.commandID, messageEvent: row.messageEvent,
            acceptanceEvent: row.acceptanceEvent, deliveryEvent: nil,
            hostSequence: row.hostSequence, client: row.client,
            sessionAttachment: row.sessionAttachment, run: row.run,
            commandKind: row.commandKind, deliveryMode: row.deliveryMode,
            state: .acceptedWaitingDelivery, issue: nil)
        XCTAssertTrue(StartupChatPresentationPolicy.shouldSuppressSavedStartupEcho(
            startup: startup, deliveryRows: [acceptedVisibleRow],
            deliveryProjectionIsCanonical: true, visibleMessages: [message]))

        let sameTextOtherRequest = SessionMessageSnapshot(
            eventID: "other", role: "user", text: "same",
            sourceEvent: EventRef(journal: key.workSession.sessionJournal, eventID: "other"),
            run: RunRef("other-run"), client: key.client,
            sessionAttachment: key.workSession.sessionAttachment,
            causedBy: row.acceptanceEvent)
        XCTAssertFalse(suppress([sameTextOtherRequest]))
        XCTAssertFalse(suppress([]))
    }),
    ("startup presentation: mismatched command client session and run fail closed", {
        let key = try startupPolicyKey()
        let startup = try XCTUnwrap(StartupInputIdentity(
            association: key, commandID: "startup", prompt: "same"))
        let (row, message) = startupPolicyRow(
            key: key, commandID: startup.canonicalCommandID, prompt: startup.prompt)
        let suppress: ([SessionMessageSnapshot]) -> Bool = { messages in
            StartupChatPresentationPolicy.shouldSuppressSavedStartupEcho(
                startup: startup, deliveryRows: [row],
                deliveryProjectionIsCanonical: true, visibleMessages: messages)
        }
        let mismatchedCommand = CanonicalInputDeliveryRow(
            id: row.id, commandID: "other-command", messageEvent: row.messageEvent,
            acceptanceEvent: row.acceptanceEvent, deliveryEvent: row.deliveryEvent,
            hostSequence: row.hostSequence, client: row.client,
            sessionAttachment: row.sessionAttachment, run: row.run,
            commandKind: row.commandKind, deliveryMode: row.deliveryMode,
            state: row.state, issue: row.issue)
        XCTAssertFalse(StartupChatPresentationPolicy.shouldSuppressSavedStartupEcho(
            startup: startup, deliveryRows: [mismatchedCommand],
            deliveryProjectionIsCanonical: true, visibleMessages: [message]))
        let wrongClientMessage = SessionMessageSnapshot(
            eventID: message.eventID, role: message.role, text: message.text,
            sourceEvent: message.sourceEvent, run: message.run,
            client: ClientRef("other-client"),
            sessionAttachment: message.sessionAttachment, causedBy: message.causedBy)
        XCTAssertFalse(suppress([wrongClientMessage]))
        let wrongRunMessage = SessionMessageSnapshot(
            eventID: message.eventID, role: message.role, text: message.text,
            sourceEvent: message.sourceEvent, run: RunRef("other-run"),
            client: message.client, sessionAttachment: message.sessionAttachment,
            causedBy: message.causedBy)
        XCTAssertFalse(suppress([wrongRunMessage]))
        let wrongSessionKey = try startupPolicyKey("other")
        let wrongSessionMessage = SessionMessageSnapshot(
            eventID: message.eventID, role: message.role, text: message.text,
            sourceEvent: EventRef(journal: wrongSessionKey.workSession.sessionJournal,
                                  eventID: message.eventID), run: message.run,
            client: message.client,
            sessionAttachment: wrongSessionKey.workSession.sessionAttachment,
            causedBy: message.causedBy)
        XCTAssertFalse(suppress([wrongSessionMessage]))
    }),
    ("startup presentation: incomplete evidence and retained cleanup marker keep echo recoverable", {
        let key = try startupPolicyKey()
        let startup = try XCTUnwrap(StartupInputIdentity(
            association: key, commandID: "startup", prompt: "same"))
        let (row, message) = startupPolicyRow(
            key: key, commandID: startup.canonicalCommandID, prompt: startup.prompt)
        let incomplete = false
        XCTAssertFalse(StartupChatPresentationPolicy.shouldSuppressSavedStartupEcho(
            startup: startup, deliveryRows: [row],
            deliveryProjectionIsCanonical: incomplete, visibleMessages: [message]))
        let chat = try PendingChat(
            prompt: startup.prompt, cwd: "/tmp", phase: .preparing,
            startCommandID: startup.commandID, createdAssociation: key)
        XCTAssertTrue(StartupChatPresentationPolicy.showsPendingRow(
            chat, visibleAttachmentKeys: [key], hasRecoveryDetail: true))
        XCTAssertEqual(StartupChatPresentationPolicy.savedPrompt(
            pendingChat: chat, startIntent: nil, projection: nil, visibleMessages: []),
            chat.prompt)
    }),
]
