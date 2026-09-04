import Foundation
@testable import AviaryCore

private let canonicalSession = SessionRef("catalog-session")
private let canonicalSessionJournal = JournalRef.session(
    canonicalSession, journalID: "catalog-session-journal",
    authority: TimelineAuthorityRef("catalog-service"))
private let canonicalWork = WorkRef(workHostID: "catalog-host", workID: "catalog-work")
private let canonicalWorkJournal = JournalRef.work(canonicalWork, journalID: "catalog-work-journal")

private func catalogSessionRead(
    journal: JournalRef, eventID: String, sequence: Int, previousEventID: String? = nil,
    preceding: [(String, Int)] = [],
    quarantinedSuffix: TimelineJournalTail? = nil, truncatedTail: TimelineJournalTail? = nil
) -> TimelineJournalReadResult {
    let sessionOwner: SessionRef?
    if case .session(let session) = journal.owner {
        sessionOwner = session
    } else {
        sessionOwner = nil
    }
    let points = preceding + [(eventID, sequence)]
    let records = points.enumerated().map { index, point in
        let previous = index == 0 ? nil
            : (index == points.count - 1 ? previousEventID ?? points[index - 1].0 : points[index - 1].0)
        let event = TimelineEvent(
            eventID: point.0, journal: journal, sequence: point.1,
            previousEventID: previous,
            session: sessionOwner,
            actor: TimelineActor(actorID: "catalog-test", kind: "test"),
            hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(point.1)),
            type: "session.message")
        return TimelineJournalRecord(
            event: event, rawLineBytes: Data("{}\n".utf8),
            byteStart: index * 3, byteEnd: (index + 1) * 3)
    }
    return TimelineJournalReadResult(
        records: records, quarantinedSuffix: quarantinedSuffix, truncatedTail: truncatedTail)
}

private func catalogWorkRead(
    journal: JournalRef, points: [(String, Int)], duplicateLast: Bool = false,
    foreignJournal: JournalRef? = nil, brokenChain: Bool = false,
    quarantinedSuffix: TimelineJournalTail? = nil,
    truncatedTail: TimelineJournalTail? = nil
) -> TimelineJournalReadResult {
    let workOwner: WorkRef?
    let host: WorkHostRef?
    if case .work(let work) = journal.owner {
        workOwner = work
        host = WorkHostRef(work.workHostID)
    } else {
        workOwner = nil
        host = nil
    }
    var records = points.enumerated().map { index, point in
        let previous = index == 0 ? nil
            : (brokenChain && index == 1 ? "not-the-previous-event" : points[index - 1].0)
        let event = TimelineEvent(
            eventID: point.0,
            journal: foreignJournal ?? journal,
            sequence: point.1,
            previousEventID: previous,
            work: workOwner,
            workHost: host,
            actor: TimelineActor(actorID: "catalog-test", kind: "test"),
            hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(point.1)),
            type: "work.created")
        return TimelineJournalRecord(
            event: event, rawLineBytes: Data("{}\n".utf8),
            byteStart: index * 3, byteEnd: (index + 1) * 3)
    }
    if duplicateLast, let last = records.last {
        records.append(last)
    }
    return TimelineJournalReadResult(
        records: records, quarantinedSuffix: quarantinedSuffix, truncatedTail: truncatedTail)
}

func test_canonicalSessionCatalogPreservesAttachedWorkIdentityAndTruth() throws {
    var session = SessionSnapshot()
    session.session = canonicalSession
    session.journal = canonicalSessionJournal
    session.lifecycle = .active
    session.attention = .review
    session.messages = [SessionMessageSnapshot(eventID: "m1", role: "user", text: "Inspect this")]
    let attachment = SessionAttachmentRef("attachment-1")
    session.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: attachment, work: canonicalWork,
        cursor: JournalCursor(journal: canonicalWorkJournal, eventID: "w3", sequence: 3),
        capabilities: ["observe"])

    var work = WorkSnapshot()
    work.journal = canonicalWorkJournal
    work.work = canonicalWork
    work.workHost = WorkHostRef(canonicalWork.workHostID)
    work.lifecycle = .active
    work.execution = .running
    work.lastEventID = "w3"
    work.lastSequence = 3
    work.eventSequences = ["w1": 1, "w2": 2, "w3": 3]
    work.activeActionIDs = ["action-1"]
    work.modelID = "work-model"
    work.childStates["child-work"] = "running"
    work.actions["action-1"] = WorkActionSnapshot(
        action: ActionRef("action-1"), state: .running, kind: .runtime)

    var unrelated = WorkSnapshot()
    unrelated.journal = JournalRef.work(
        WorkRef(workHostID: "other-host", workID: "other-work"), journalID: "other-journal")
    unrelated.work = WorkRef(workHostID: "other-host", workID: "other-work")
    unrelated.modelID = "unrelated-model"
    unrelated.childStates["unrelated-child"] = "completed"
    session.modelID = "session-model"
    let summary = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work, unrelated], cursors: [
            attachment.attachmentID: JournalCursor(
                journal: canonicalWorkJournal, eventID: "w3", sequence: 3)
        ], workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal, points: [("w1", 1), ("w2", 2), ("w3", 3)])]))
    XCTAssertEqual(summary.id, canonicalSessionJournal.stableKey)
    XCTAssertEqual(summary.journal, canonicalSessionJournal)
    XCTAssertTrue(summary.assemblyReady)
    XCTAssertEqual(summary.attention, .review)
    XCTAssertEqual(summary.effectiveAttention, .review)
    XCTAssertEqual(summary.work.count, 1)
    XCTAssertEqual(summary.work[0].work, canonicalWork)
    XCTAssertEqual(summary.work[0].workHost, WorkHostRef("catalog-host"))
    XCTAssertEqual(summary.work[0].journal, canonicalWorkJournal)
    XCTAssertEqual(summary.work[0].outstandingActionIDs, ["action-1"])
    XCTAssertEqual(summary.work[0].journalIntegrityValid, true)
    XCTAssertEqual(summary.work[0].tailBytes, 0)
    XCTAssertEqual(summary.sessionIntegrityValid, nil)
    XCTAssertEqual(summary.sessionTailBytes, nil)
    XCTAssertEqual(summary.modelIDs, ["session-model", "work-model"])
    XCTAssertEqual(summary.childStates, ["child-work": "running"])
}

func test_canonicalSessionCatalogDoesNotProjectDetachedActiveWork() throws {
    var session = SessionSnapshot()
    session.session = canonicalSession
    session.journal = canonicalSessionJournal
    let attachment = SessionAttachmentRef("detached-attachment")
    let cursor = JournalCursor(journal: canonicalWorkJournal, eventID: "w1", sequence: 1)
    session.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: attachment, work: canonicalWork, cursor: cursor, isAttached: false)

    var work = WorkSnapshot()
    work.journal = canonicalWorkJournal
    work.work = canonicalWork
    work.workHost = WorkHostRef(canonicalWork.workHostID)
    work.lifecycle = .active
    work.execution = .running
    work.modelID = "detached-model"
    work.lastEventID = "w1"
    work.lastSequence = 1
    work.eventSequences = ["w1": 1]
    work.activeActionIDs = ["detached-action"]
    work.childStates = ["detached-child": "running"]

    let summary = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [attachment.attachmentID: cursor]))
    let row = try XCTUnwrap(summary.work.first)
    XCTAssertFalse(row.canProjectExecution)
    XCTAssertFalse(row.isAttached)
    XCTAssertEqual(row.lifecycle, .unknown)
    XCTAssertEqual(row.execution, .unknown)
    XCTAssertNil(row.modelID)
    XCTAssertEqual(row.outstandingActionIDs, [])
    XCTAssertEqual(summary.modelIDs, [])
    XCTAssertEqual(summary.childStates, [:])
    XCTAssertTrue(summary.assemblyReady)
    XCTAssertEqual(summary.effectiveAttention, summary.attention)
}

func test_canonicalSessionCatalogDoesNotProjectCorruptActiveWork() throws {
    var session = SessionSnapshot()
    session.session = canonicalSession
    session.journal = canonicalSessionJournal
    let attachment = SessionAttachmentRef("corrupt-attachment")
    let cursor = JournalCursor(journal: canonicalWorkJournal, eventID: "w1", sequence: 1)
    session.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: attachment, work: canonicalWork, cursor: cursor)

    var work = WorkSnapshot()
    work.journal = canonicalWorkJournal
    work.work = canonicalWork
    work.workHost = WorkHostRef(canonicalWork.workHostID)
    work.lifecycle = .active
    work.execution = .running
    work.modelID = "corrupt-model"
    work.lastEventID = "w1"
    work.lastSequence = 1
    work.eventSequences = ["w1": 1]
    work.activeActionIDs = ["corrupt-action"]
    work.childStates = ["corrupt-child": "running"]
    work.structuralIntegrityValid = false
    work.semanticProjectionValid = false

    let summary = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal, points: [("w1", 1)])]))
    let row = try XCTUnwrap(summary.work.first)
    XCTAssertFalse(row.canProjectExecution)
    XCTAssertTrue(row.isAttached)
    XCTAssertTrue(row.isAvailable)
    XCTAssertEqual(row.cursorAlignment, .exact)
    XCTAssertEqual(row.lifecycle, .unknown)
    XCTAssertEqual(row.execution, .unknown)
    XCTAssertNil(row.modelID)
    XCTAssertEqual(row.outstandingActionIDs, [])
    XCTAssertEqual(row.workReadAlignment, .exact)
    XCTAssertEqual(row.workReadCursor?.eventID, "w1")
    XCTAssertEqual(row.journalIntegrityValid, false)
    XCTAssertEqual(summary.modelIDs, [])
    XCTAssertEqual(summary.childStates, [:])
    XCTAssertFalse(summary.assemblyReady)
    XCTAssertNil(summary.effectiveAttention)
}

func test_canonicalSessionCatalogDoesNotHideDelayedRemoteWork() throws {
    var session = SessionSnapshot()
    session.session = canonicalSession
    session.journal = canonicalSessionJournal
    session.attention = .input
    let attachment = SessionAttachmentRef("delayed-attachment")
    session.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: attachment, work: canonicalWork, capabilities: ["observe"])

    let summary = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [], cursors: [:]))
    XCTAssertFalse(summary.assemblyReady)
    XCTAssertEqual(summary.attention, .input)
    XCTAssertNil(summary.effectiveAttention)
    XCTAssertEqual(summary.work.count, 1)
    XCTAssertFalse(summary.work[0].isAvailable)
    XCTAssertEqual(summary.work[0].workHost, WorkHostRef("catalog-host"))
    XCTAssertEqual(summary.work[0].journal, nil)
    XCTAssertEqual(summary.work[0].outstandingActionIDs, [])
}

func test_canonicalSessionCatalogSeparatesCursorAlignmentAndHidesUnalignedWork() throws {
    var session = SessionSnapshot()
    session.session = canonicalSession
    session.journal = canonicalSessionJournal
    let attachment = SessionAttachmentRef("alignment-attachment")
    session.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: attachment, work: canonicalWork)
    var work = WorkSnapshot()
    work.journal = canonicalWorkJournal
    work.work = canonicalWork
    work.workHost = WorkHostRef(canonicalWork.workHostID)
    work.lifecycle = .active
    work.execution = .running
    work.modelID = "ahead-model"
    work.lastEventID = "w3"
    work.lastSequence = 3
    work.eventSequences["w2"] = 2
    work.eventSequences["w3"] = 3
    work.activeActionIDs = ["ahead-action"]

    let observedAhead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [
            attachment.attachmentID: JournalCursor(
                journal: canonicalWorkJournal, eventID: "w2", sequence: 2)
        ]))
    XCTAssertEqual(observedAhead.work[0].cursorAlignment, .observedAhead)
    XCTAssertEqual(observedAhead.work[0].requestedCursor?.sequence, 2)
    XCTAssertEqual(observedAhead.work[0].observedCursor?.sequence, 3)
    XCTAssertEqual(observedAhead.work[0].lifecycle, .unknown)
    XCTAssertEqual(observedAhead.work[0].execution, .unknown)
    XCTAssertEqual(observedAhead.work[0].outstandingActionIDs, [])
    XCTAssertEqual(observedAhead.modelIDs, [])
    XCTAssertNil(observedAhead.effectiveAttention)

    let requestedAhead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [
            attachment.attachmentID: JournalCursor(
                journal: canonicalWorkJournal, eventID: "w4", sequence: 4)
        ], workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal,
            points: [("w1", 1), ("w2", 2), ("w3", 3), ("w4", 4)])]))
    XCTAssertEqual(requestedAhead.work[0].cursorAlignment, .requestedAhead)
    XCTAssertEqual(requestedAhead.work[0].lifecycle, .unknown)
    XCTAssertEqual(requestedAhead.work[0].outstandingActionIDs, [])
    XCTAssertTrue(requestedAhead.work[0].isAvailable)
    XCTAssertFalse(requestedAhead.assemblyReady)

    let sameIDObserved = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [
            attachment.attachmentID: JournalCursor(
                journal: canonicalWorkJournal, eventID: "w3", sequence: 2)
        ]))
    XCTAssertEqual(sameIDObserved.work[0].cursorAlignment, .divergent)
    XCTAssertEqual(sameIDObserved.work[0].lifecycle, .unknown)

    let sameIDRequested = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [
            attachment.attachmentID: JournalCursor(
                journal: canonicalWorkJournal, eventID: "w3", sequence: 4)
        ]))
    XCTAssertEqual(sameIDRequested.work[0].cursorAlignment, .divergent)
    XCTAssertEqual(sameIDRequested.work[0].outstandingActionIDs, [])

    // A sequence number alone does not prove that the requested cursor is an ancestor. The
    // catalog must not expose a false observed-ahead relationship for a divergent branch.
    var unverifiedWork = work
    unverifiedWork.eventSequences = ["w3": 3]
    let unverified = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [unverifiedWork], cursors: [
            attachment.attachmentID: JournalCursor(
                journal: canonicalWorkJournal, eventID: "w2", sequence: 2)
        ]))
    XCTAssertEqual(unverified.work[0].cursorAlignment, .divergent)
    XCTAssertEqual(unverified.work[0].lifecycle, .unknown)
    XCTAssertEqual(unverified.work[0].outstandingActionIDs, [])
    XCTAssertNil(unverified.effectiveAttention)

    let noRead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [:]))
    XCTAssertEqual(noRead.work[0].cursorAlignment, .requestedUnavailable)
    XCTAssertEqual(noRead.work[0].lifecycle, .unknown)

    let foreignCursor = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [
            attachment.attachmentID: JournalCursor(
                journal: JournalRef.work(
                    WorkRef(workHostID: "foreign-host", workID: "foreign-work")),
                eventID: "w3", sequence: 3)
        ]))
    XCTAssertEqual(foreignCursor.work[0].cursorAlignment, .divergent)
    XCTAssertEqual(foreignCursor.work[0].lifecycle, .unknown)
}

func test_canonicalSessionCatalogRequiresAllAttachedWorkIdentitiesToAgree() throws {
    var session = SessionSnapshot()
    session.session = canonicalSession
    session.journal = canonicalSessionJournal
    let attachment = SessionAttachmentRef("identity-attachment")
    let cursor = JournalCursor(journal: canonicalWorkJournal, eventID: "w1", sequence: 1)
    session.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: attachment, work: canonicalWork, cursor: cursor)

    var valid = WorkSnapshot()
    valid.journal = canonicalWorkJournal
    valid.work = canonicalWork
    valid.workHost = WorkHostRef(canonicalWork.workHostID)
    valid.lastEventID = "w1"
    valid.lastSequence = 1
    valid.eventSequences = ["w1": 1]
    valid.lifecycle = .active

    var mismatchedWork = valid
    mismatchedWork.work = WorkRef(workHostID: "foreign-host", workID: "foreign-work")
    var mismatchedJournalOwner = valid
    mismatchedJournalOwner.journal = JournalRef.session(
        canonicalSession, journalID: "wrong-kind", authority: TimelineAuthorityRef("session-authority"))
    var mismatchedHost = valid
    mismatchedHost.workHost = WorkHostRef("foreign-host")

    for mismatched in [mismatchedWork, mismatchedJournalOwner, mismatchedHost] {
        let summary = try XCTUnwrap(SessionCatalog.summarizeCanonical(
            session: session, works: [mismatched], cursors: [attachment.attachmentID: cursor]))
        let row = try XCTUnwrap(summary.work.first)
        XCTAssertFalse(row.isAvailable)
        XCTAssertNil(row.journal)
        XCTAssertEqual(row.cursorAlignment, .unavailable)
        XCTAssertEqual(row.lifecycle, .unknown)
        XCTAssertFalse(summary.assemblyReady)
        XCTAssertTrue(row.corruptionReasons.contains {
            $0.contains("identity does not match")
        })
    }
}

func test_canonicalSessionCatalogSuppressesUnknownSessionAndAttachmentDomains() throws {
    let attachment = SessionAttachmentRef("unknown-domain-attachment")
    let cursor = JournalCursor(
        journal: canonicalWorkJournal, eventID: "w1", sequence: 1)
    var session = SessionSnapshot()
    session.session = canonicalSession
    session.journal = canonicalSessionJournal
    session.lifecycle = .completed
    session.attention = .review
    session.modelID = "session-before-unknown"
    session.messages = [SessionMessageSnapshot(
        eventID: "message-before-unknown", role: "user", text: "stale title")]
    session.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: attachment, work: canonicalWork, cursor: cursor)
    var work = WorkSnapshot()
    work.journal = canonicalWorkJournal
    work.work = canonicalWork
    work.workHost = WorkHostRef(canonicalWork.workHostID)
    work.lifecycle = .active
    work.execution = .running
    work.modelID = "work-before-unknown"
    work.lastEventID = "w1"
    work.lastSequence = 1
    work.eventSequences = ["w1": 1]
    let read = catalogWorkRead(journal: canonicalWorkJournal, points: [("w1", 1)])

    var unknownSession = session
    unknownSession.unknownDomains = [.session]
    let sessionUnknown = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: unknownSession, works: [work],
        cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: read]))
    XCTAssertEqual(sessionUnknown.title, "")
    XCTAssertEqual(sessionUnknown.lifecycle, .unknown)
    XCTAssertEqual(sessionUnknown.attention, .none)
    XCTAssertNil(sessionUnknown.effectiveAttention)
    XCTAssertTrue(sessionUnknown.visibleMessages.isEmpty)
    XCTAssertNil(sessionUnknown.sessionModelID)
    XCTAssertTrue(sessionUnknown.modelIDs.isEmpty)
    XCTAssertFalse(sessionUnknown.work[0].attachmentProjectionKnown)
    XCTAssertFalse(sessionUnknown.work[0].canProjectExecution)
    XCTAssertFalse(sessionUnknown.assemblyReady)
    XCTAssertTrue(sessionUnknown.hasOngoingOrUncertainAttachedWork)

    var unknownAttachment = session
    unknownAttachment.unknownDomains = [.work]
    let attachmentUnknown = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: unknownAttachment, works: [work],
        cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: read]))
    XCTAssertEqual(attachmentUnknown.title, "stale title")
    XCTAssertEqual(attachmentUnknown.lifecycle, .completed)
    XCTAssertEqual(attachmentUnknown.sessionModelID, "session-before-unknown")
    XCTAssertFalse(attachmentUnknown.work[0].attachmentProjectionKnown)
    XCTAssertFalse(attachmentUnknown.work[0].canProjectExecution)
    XCTAssertEqual(attachmentUnknown.work[0].lifecycle, .unknown)
    XCTAssertFalse(attachmentUnknown.assemblyReady)
    XCTAssertTrue(attachmentUnknown.hasOngoingOrUncertainAttachedWork)
}

func test_canonicalSessionCatalogOnlyReportsExactCanonicalWorkReads() throws {
    var session = SessionSnapshot()
    session.session = canonicalSession
    session.journal = canonicalSessionJournal
    let attachment = SessionAttachmentRef("read-attachment")
    let cursor = JournalCursor(journal: canonicalWorkJournal, eventID: "w3", sequence: 3)
    session.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: attachment, work: canonicalWork, cursor: cursor)
    var work = WorkSnapshot()
    work.journal = canonicalWorkJournal
    work.work = canonicalWork
    work.workHost = WorkHostRef(canonicalWork.workHostID)
    work.lastEventID = "w3"
    work.lastSequence = 3
    work.eventSequences = ["w1": 1, "w2": 2, "w3": 3]
    work.lifecycle = .active

    let exact = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal, points: [("w1", 1), ("w2", 2), ("w3", 3)])]))
    XCTAssertEqual(exact.work[0].cursorAlignment, .exact)
    XCTAssertEqual(exact.work[0].workReadAlignment, .exact)
    XCTAssertEqual(exact.work[0].workReadCursor?.sequence, 3)
    XCTAssertEqual(exact.work[0].journalIntegrityValid, true)
    XCTAssertEqual(exact.work[0].tailBytes, 0)

    let noRead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [attachment.attachmentID: cursor]))
    XCTAssertEqual(noRead.work[0].workReadAlignment, .notSupplied)
    XCTAssertNil(noRead.work[0].workReadCursor)
    XCTAssertNil(noRead.work[0].journalIntegrityValid)
    XCTAssertNil(noRead.work[0].tailBytes)
    XCTAssertFalse(noRead.work[0].canProjectExecution)
    XCTAssertEqual(noRead.work[0].lifecycle, .unknown)
    XCTAssertFalse(noRead.assemblyReady)

    let staleRead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal, points: [("w1", 1), ("w2", 2)])]))
    XCTAssertEqual(staleRead.work[0].cursorAlignment, .exact)
    XCTAssertEqual(staleRead.work[0].workReadAlignment, .stale)
    XCTAssertEqual(staleRead.work[0].workReadCursor?.sequence, 2)
    XCTAssertEqual(staleRead.work[0].journalIntegrityValid, false)
    XCTAssertEqual(staleRead.work[0].tailBytes, 0)
    XCTAssertFalse(staleRead.work[0].canProjectExecution)
    XCTAssertEqual(staleRead.work[0].lifecycle, .unknown)
    XCTAssertFalse(staleRead.assemblyReady)

    let aheadRead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal, points: [("w1", 1), ("w2", 2), ("w3", 3), ("w4", 4)])]))
    XCTAssertEqual(aheadRead.work[0].workReadAlignment, .ahead)
    XCTAssertEqual(aheadRead.work[0].workReadCursor?.sequence, 4)
    XCTAssertEqual(aheadRead.work[0].journalIntegrityValid, false)
    XCTAssertFalse(aheadRead.work[0].canProjectExecution)
    XCTAssertEqual(aheadRead.work[0].lifecycle, .unknown)
    XCTAssertFalse(aheadRead.assemblyReady)

    var missingEvidenceWork = work
    missingEvidenceWork.eventSequences = ["w1": 1, "w3": 3]
    let unprovenStaleRead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [missingEvidenceWork], cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal, points: [("w1", 1), ("w2", 2)])]))
    XCTAssertEqual(unprovenStaleRead.work[0].workReadAlignment, .divergent)
    XCTAssertEqual(unprovenStaleRead.work[0].journalIntegrityValid, false)

    let unprovenAheadRead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal,
            points: [("w1", 1), ("w2", 2), ("other-tip", 3), ("other-ahead", 4)])]))
    XCTAssertEqual(unprovenAheadRead.work[0].workReadAlignment, .divergent)
    XCTAssertEqual(unprovenAheadRead.work[0].journalIntegrityValid, false)

    let foreignRead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal, points: [("w1", 1), ("w2", 2), ("w3", 3)],
            foreignJournal: JournalRef.work(
                WorkRef(workHostID: "foreign-host", workID: "foreign-work"))) ]))
    XCTAssertEqual(foreignRead.work[0].cursorAlignment, .exact)
    XCTAssertEqual(foreignRead.work[0].workReadAlignment, .foreign)
    XCTAssertEqual(foreignRead.work[0].journalIntegrityValid, false)
    XCTAssertEqual(foreignRead.work[0].tailBytes, 0)
    XCTAssertFalse(foreignRead.work[0].canProjectExecution)
    XCTAssertEqual(foreignRead.work[0].lifecycle, .unknown)
    XCTAssertFalse(foreignRead.assemblyReady)

    let duplicateRead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal, points: [("w1", 1), ("w2", 2), ("w3", 3)],
            duplicateLast: true)]))
    XCTAssertEqual(duplicateRead.work[0].cursorAlignment, .exact)
    XCTAssertEqual(duplicateRead.work[0].workReadAlignment, .invalid)
    XCTAssertEqual(duplicateRead.work[0].journalIntegrityValid, false)
    XCTAssertEqual(duplicateRead.work[0].tailBytes, 0)
    XCTAssertTrue(duplicateRead.work[0].corruptionReasons.contains {
        $0.contains("duplicate event IDs")
    })

    let brokenRead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal, points: [("w1", 1), ("w2", 2), ("w3", 3)],
            brokenChain: true)]))
    XCTAssertEqual(brokenRead.work[0].workReadAlignment, .invalid)
    XCTAssertEqual(brokenRead.work[0].journalIntegrityValid, false)

    let tailedRead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [work], cursors: [attachment.attachmentID: cursor],
        workReads: [canonicalWorkJournal: catalogWorkRead(
            journal: canonicalWorkJournal, points: [("w1", 1), ("w2", 2), ("w3", 3)],
            truncatedTail: TimelineJournalTail(rawBytes: Data("partial".utf8), byteStart: 9,
                                               byteEnd: 16))]))
    XCTAssertEqual(tailedRead.work[0].workReadAlignment, .exact)
    XCTAssertEqual(tailedRead.work[0].journalIntegrityValid, false)
    XCTAssertEqual(tailedRead.work[0].tailBytes, 7)
    XCTAssertFalse(tailedRead.work[0].canProjectExecution)
    XCTAssertEqual(tailedRead.work[0].lifecycle, .unknown)
    XCTAssertFalse(tailedRead.assemblyReady)
}

func test_canonicalSessionCatalogRetainsReducerDuplicateTruthWithoutTrapping() throws {
    let firstWork = TimelineEvent(
        eventID: "duplicate-work", journal: canonicalWorkJournal, sequence: 1,
        work: canonicalWork, workHost: WorkHostRef(canonicalWork.workHostID),
        actor: TimelineActor(actorID: "catalog-test"), hostRecordedAt: Date(timeIntervalSince1970: 1),
        type: TimelineEventType.workCreated)
    let duplicateWork = TimelineEvent(
        eventID: "duplicate-work", journal: canonicalWorkJournal, sequence: 2,
        previousEventID: "duplicate-work", work: canonicalWork,
        workHost: WorkHostRef(canonicalWork.workHostID), actor: TimelineActor(actorID: "catalog-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 2), type: TimelineEventType.workCreated)
    let reducedWork = WorkReducer.reduce([firstWork, duplicateWork])

    var session = SessionSnapshot()
    session.session = canonicalSession
    session.journal = canonicalSessionJournal
    let attachment = SessionAttachmentRef("duplicate-work-attachment")
    session.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: attachment, work: canonicalWork,
        cursor: JournalCursor(journal: canonicalWorkJournal, eventID: "duplicate-work", sequence: 1))
    let workSummary = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [reducedWork]))
    XCTAssertFalse(workSummary.work[0].structuralIntegrityValid)
    XCTAssertTrue(workSummary.work[0].corruptionReasons.contains {
        $0.contains("duplicate event duplicate-work")
    })

    let firstSession = TimelineEvent(
        eventID: "duplicate-session", journal: canonicalSessionJournal, sequence: 1,
        session: canonicalSession, actor: TimelineActor(actorID: "catalog-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1), type: TimelineEventType.sessionCreated)
    let duplicateSession = TimelineEvent(
        eventID: "duplicate-session", journal: canonicalSessionJournal, sequence: 2,
        previousEventID: "duplicate-session", session: canonicalSession,
        actor: TimelineActor(actorID: "catalog-test"), hostRecordedAt: Date(timeIntervalSince1970: 2),
        type: TimelineEventType.sessionCreated)
    let reducedSession = SessionReducer.reduce([firstSession, duplicateSession])
    let sessionSummary = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: reducedSession, works: []))
    XCTAssertFalse(sessionSummary.sessionStructuralIntegrityValid)
    XCTAssertTrue(sessionSummary.corruptionReasons.contains {
        $0.contains("duplicate event duplicate-session")
    })

    let duplicateRead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [], sessionRead: catalogSessionRead(
            journal: canonicalSessionJournal, eventID: "s3", sequence: 3,
            preceding: [("s2", 2), ("s3", 3)])))
    XCTAssertEqual(duplicateRead.sessionCursorAlignment, .divergent)
    XCTAssertEqual(duplicateRead.sessionIntegrityValid, false)
    XCTAssertTrue(duplicateRead.corruptionReasons.contains {
        $0.contains("duplicate event IDs")
    })
}

func test_canonicalSessionCatalogCorrelatesSessionSnapshotAndReadCursors() throws {
    var session = SessionSnapshot()
    session.session = canonicalSession
    session.journal = canonicalSessionJournal
    session.lastEventID = "s3"
    session.lastSequence = 3
    session.seenEventIDs = ["s2", "s3"]

    let stale = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [], sessionRead: catalogSessionRead(
            journal: canonicalSessionJournal, eventID: "s2", sequence: 2)))
    XCTAssertEqual(stale.sessionCursorAlignment, .requestedAhead)
    XCTAssertEqual(stale.sessionSnapshotCursor?.sequence, 3)
    XCTAssertEqual(stale.sessionReadCursor?.sequence, 2)
    XCTAssertEqual(stale.sessionCursor, stale.sessionReadCursor)
    XCTAssertEqual(stale.sessionIntegrityValid, false)
    XCTAssertEqual(stale.sessionTailBytes, 0)

    let ahead = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [], sessionRead: catalogSessionRead(
            journal: canonicalSessionJournal, eventID: "s4", sequence: 4,
            preceding: [("s3", 3)])))
    XCTAssertEqual(ahead.sessionCursorAlignment, .observedAhead)
    XCTAssertEqual(ahead.sessionSnapshotCursor?.sequence, 3)
    XCTAssertEqual(ahead.sessionReadCursor?.sequence, 4)
    XCTAssertEqual(ahead.sessionIntegrityValid, false)
    XCTAssertEqual(ahead.sessionTailBytes, 0)

    var unverifiedSession = session
    unverifiedSession.seenEventIDs = []
    let unverified = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: unverifiedSession, works: [], sessionRead: catalogSessionRead(
            journal: canonicalSessionJournal, eventID: "s2", sequence: 2)))
    XCTAssertEqual(unverified.sessionCursorAlignment, .divergent)
    XCTAssertEqual(unverified.sessionIntegrityValid, false)
    XCTAssertEqual(unverified.sessionTailBytes, 0)

    var invalidSnapshot = session
    invalidSnapshot.structuralIntegrityValid = false
    let invalidExact = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: invalidSnapshot, works: [], sessionRead: catalogSessionRead(
            journal: canonicalSessionJournal, eventID: "s3", sequence: 3)))
    XCTAssertEqual(invalidExact.sessionCursorAlignment, .exact)
    XCTAssertEqual(invalidExact.sessionIntegrityValid, false)
    XCTAssertEqual(invalidExact.sessionTailBytes, 0)

    let tailed = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [], sessionRead: catalogSessionRead(
            journal: canonicalSessionJournal, eventID: "s3", sequence: 3,
            truncatedTail: TimelineJournalTail(rawBytes: Data("partial".utf8), byteStart: 9,
                                                byteEnd: 16))))
    XCTAssertEqual(tailed.sessionCursorAlignment, .exact)
    XCTAssertEqual(tailed.sessionIntegrityValid, false)
    XCTAssertEqual(tailed.sessionTailBytes, 7)

    let foreignJournal = JournalRef.session(
        canonicalSession, journalID: "foreign-session-journal",
        authority: TimelineAuthorityRef("foreign-authority"))
    let foreign = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [], sessionRead: catalogSessionRead(
            journal: foreignJournal, eventID: "foreign-1", sequence: 1)))
    XCTAssertEqual(foreign.sessionCursorAlignment, .divergent)
    XCTAssertEqual(foreign.sessionReadCursor?.journal, foreignJournal)
    XCTAssertNotEqual(foreign.sessionReadCursor?.journal, canonicalSessionJournal)
    XCTAssertEqual(foreign.sessionIntegrityValid, false)
    XCTAssertEqual(foreign.sessionTailBytes, 0)
}

func test_canonicalSessionCatalogQualifiesSessionIDsAndRejectsOwnerMismatch() throws {
    let authorityA = JournalRef.session(
        canonicalSession, journalID: "session-journal", authority: TimelineAuthorityRef("authority-a"))
    let authorityB = JournalRef.session(
        canonicalSession, journalID: "session-journal", authority: TimelineAuthorityRef("authority-b"))
    var first = SessionSnapshot()
    first.session = canonicalSession
    first.journal = authorityA
    var second = SessionSnapshot()
    second.session = canonicalSession
    second.journal = authorityB
    let firstSummary = try XCTUnwrap(SessionCatalog.summarizeCanonical(session: first, works: []))
    let secondSummary = try XCTUnwrap(SessionCatalog.summarizeCanonical(session: second, works: []))
    XCTAssertNotEqual(firstSummary.id, secondSummary.id)
    XCTAssertEqual(firstSummary.id, authorityA.stableKey)

    var mismatched = SessionSnapshot()
    mismatched.session = canonicalSession
    mismatched.journal = JournalRef.session(
        SessionRef("different-session"), journalID: "session-journal",
        authority: TimelineAuthorityRef("authority-a"))
    XCTAssertNil(SessionCatalog.summarizeCanonical(session: mismatched, works: []))
}

func test_readerCensusRegistersCanonicalSessionCatalogProjection() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/ReaderCensus")
    let sessionData = try Data(contentsOf: root.appending(path: "session.jsonl"))
    let workData = try Data(contentsOf: root.appending(path: "work.jsonl"))
    let report = ReaderCensus.report(
        sessionData: sessionData, sessionJournal: JournalRef.session(
            SessionRef("census-session"), journalID: "session-journal",
            authority: TimelineAuthorityRef("session-authority")),
        workData: workData, workJournal: JournalRef.work(
            WorkRef(workHostID: "census-host", workID: "census-work"), journalID: "work-journal"))
    let projection = try XCTUnwrap(report.canonicalSessionCatalog)
    XCTAssertTrue(report.registeredConsumers.contains("production local Timeline catalog"))
    XCTAssertFalse(report.intentionallyUnwiredConsumers.contains {
        $0.contains("legacy SessionCatalog scanner")
    })
    let censusJournal = JournalRef.session(
        SessionRef("census-session"), journalID: "session-journal",
        authority: TimelineAuthorityRef("session-authority"))
    XCTAssertEqual(projection.id, censusJournal.stableKey)
    XCTAssertTrue(projection.assemblyReady)
    XCTAssertEqual(projection.work.count, 2)
    XCTAssertEqual(projection.work.map(\.workHost), [WorkHostRef("census-host"), WorkHostRef("census-host")])
}
