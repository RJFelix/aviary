import Foundation
@testable import AviaryCore

private let attentionSession = SessionRef("attention-session")
private let attentionSessionJournal = JournalRef.session(
    attentionSession, journalID: "attention-session-journal",
    authority: TimelineAuthorityRef("session-authority"))
private let attentionWork = WorkRef(workHostID: "attention-host", workID: "attention-work")
private let attentionWorkJournal = JournalRef.work(attentionWork, journalID: "attention-work-journal")

private func attentionRead(
    journal: JournalRef, eventID: String, sequence: Int,
    previousEventID: String? = nil,
    foreignJournal: JournalRef? = nil,
    tail: TimelineJournalTail? = nil
) -> TimelineJournalReadResult {
    let actualJournal = foreignJournal ?? journal
    let session: SessionRef?
    let work: WorkRef?
    let host: WorkHostRef?
    switch actualJournal.owner {
    case .session(let value):
        session = value
        work = nil
        host = nil
    case .work(let value):
        session = nil
        work = value
        host = WorkHostRef(value.workHostID)
    }
    let event = TimelineEvent(
        eventID: eventID, journal: actualJournal, sequence: sequence,
        previousEventID: previousEventID, session: session, work: work, workHost: host,
        actor: TimelineActor(actorID: "attention-test", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: session == nil ? TimelineEventType.workCreated : TimelineEventType.sessionCreated)
    let record = TimelineJournalRecord(
        event: event, rawLineBytes: Data("{}\n".utf8), byteStart: 0, byteEnd: 3)
    return TimelineJournalReadResult(records: [record], truncatedTail: tail)
}

private func attentionReadChain(
    journal: JournalRef, points: [(String, Int)],
    tail: TimelineJournalTail? = nil
) -> TimelineJournalReadResult {
    let records = points.enumerated().map { index, point in
        let session: SessionRef?
        let work: WorkRef?
        let host: WorkHostRef?
        switch journal.owner {
        case .session(let value):
            session = value
            work = nil
            host = nil
        case .work(let value):
            session = nil
            work = value
            host = WorkHostRef(value.workHostID)
        }
        let event = TimelineEvent(
            eventID: point.0, journal: journal, sequence: point.1,
            previousEventID: index == 0 ? nil : points[index - 1].0,
            session: session, work: work, workHost: host,
            actor: TimelineActor(actorID: "attention-test", kind: "test"),
            hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(point.1)),
            type: session == nil ? TimelineEventType.workCreated : TimelineEventType.sessionCreated)
        return TimelineJournalRecord(
            event: event, rawLineBytes: Data("{}\n".utf8), byteStart: index * 3,
            byteEnd: (index + 1) * 3)
    }
    return TimelineJournalReadResult(records: records, truncatedTail: tail)
}

private func attentionSummary(
    attention: SessionAttention = .review,
    sessionUnknownDomains: Set<TimelineDomain> = [],
    workUnknownDomains: Set<TimelineDomain> = [],
    sessionCorruptionReasons: [String] = [],
    workCorruptionReasons: [String] = [],
    sessionUnknownEventCount: Int = 0,
    workUnknownEventCount: Int = 0,
    requestedCursor: JournalCursor? = nil,
    attachmentIDs: [String] = ["attention-attachment"],
    workSnapshot: Bool = true,
    workRead: TimelineJournalReadResult? = nil,
    sessionRead: TimelineJournalReadResult? = attentionRead(
        journal: attentionSessionJournal, eventID: "s1", sequence: 1)
) throws -> CanonicalSessionCatalogSummary {
    var session = SessionSnapshot()
    session.session = attentionSession
    session.journal = attentionSessionJournal
    session.lifecycle = .active
    session.attention = attention
    session.lastEventID = "s1"
    session.lastSequence = 1
    session.seenEventIDs = ["s1"]
    session.unknownDomains = sessionUnknownDomains
    session.corruptionReasons = sessionCorruptionReasons
    session.unknownEvents = (0..<sessionUnknownEventCount).map { index in
        let event = TimelineEvent(
            eventID: "session-unknown-\(index)", journal: attentionSessionJournal,
            sequence: index + 2, session: attentionSession,
            actor: TimelineActor(actorID: "attention-test", kind: "test"),
            hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(index + 2)),
            type: "session.unknown")
        return UnknownTimelineEvent(event: event, journalOffset: index)
    }

    let requested = requestedCursor ?? JournalCursor(
        journal: attentionWorkJournal, eventID: "w1", sequence: 1)
    for attachmentID in attachmentIDs {
        let attachment = SessionAttachmentRef(attachmentID)
        session.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
            attachment: attachment, work: attentionWork, cursor: requested)
    }

    var works: [WorkSnapshot] = []
    if workSnapshot {
        var work = WorkSnapshot()
        work.journal = attentionWorkJournal
        work.work = attentionWork
        work.workHost = WorkHostRef(attentionWork.workHostID)
        work.lifecycle = .active
        work.execution = .running
        work.lastEventID = "w1"
        work.lastSequence = 1
        work.eventSequences = ["w1": 1]
        work.unknownDomains = workUnknownDomains
        work.corruptionReasons = workCorruptionReasons
        work.unknownEvents = (0..<workUnknownEventCount).map { index in
            let event = TimelineEvent(
                eventID: "work-unknown-\(index)", journal: attentionWorkJournal,
                sequence: index + 2, work: attentionWork,
                workHost: WorkHostRef(attentionWork.workHostID),
                actor: TimelineActor(actorID: "attention-test", kind: "test"),
                hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(index + 2)),
                type: "work.unknown")
            return UnknownTimelineEvent(event: event, journalOffset: index)
        }
        works = [work]
    }
    return try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: works,
        cursors: Dictionary(uniqueKeysWithValues: attachmentIDs.map { ($0, requested) }),
        sessionRead: sessionRead,
        workReads: workRead.map { [attentionWorkJournal: $0] } ?? [:]))
}

func test_canonicalAttentionInboxUsesQualifiedSessionIdentity() throws {
    let summary = try attentionSummary(
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let projection = CanonicalAttentionInboxProjection(summary: summary)
    let row = try XCTUnwrap(projection.rows.first)

    XCTAssertEqual(projection.rows.count, 1)
    XCTAssertEqual(row.attachments.count, 1)
    XCTAssertEqual(row.authoredAttention, .review)
    XCTAssertEqual(row.effectiveAttention, .review)
    XCTAssertEqual(row.attentionRequirement, .required)
    XCTAssertEqual(row.sessionSourceCursor?.journal, attentionSessionJournal)
    XCTAssertEqual(row.attachments[0].sourceCursor?.journal, attentionWorkJournal)
    XCTAssertEqual(row.attachments[0].workHost, WorkHostRef("attention-host"))
    XCTAssertTrue(row.qualifiedSessionID.contains("session-authority"))
    XCTAssertTrue(row.attachments[0].qualifiedWorkID.contains("attention-host"))
    XCTAssertTrue(row.id.contains("session-authority"))
    XCTAssertTrue(row.attachments[0].id.contains("attention-attachment"))
    XCTAssertEqual(row.sessionUnknownDomains, [])
    XCTAssertEqual(row.attachments[0].unknownDomains, [])
}

func test_canonicalAttentionInboxReportsNoAttentionSeparatelyFromUnknown() throws {
    let summary = try attentionSummary(
        attention: .none,
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let row = try XCTUnwrap(CanonicalAttentionInboxProjection(summary: summary).rows.first)

    XCTAssertEqual(row.authoredAttention, SessionAttention.none)
    XCTAssertEqual(row.effectiveAttention, SessionAttention.none)
    XCTAssertEqual(row.attentionRequirement, .none)
}

func test_canonicalAttentionInboxFailsClosedForMissingAndUnalignedWork() throws {
    let missing = try attentionSummary(workSnapshot: false)
    let missingRow = try XCTUnwrap(
        CanonicalAttentionInboxProjection(summary: missing).rows.first)
    XCTAssertNil(missingRow.effectiveAttention)
    XCTAssertEqual(missingRow.attentionRequirement, .unknown)
    XCTAssertEqual(missingRow.attachments.count, 1)
    XCTAssertEqual(missingRow.attachments[0].cursorAlignment, .unavailable)
    XCTAssertNil(missingRow.attachments[0].integrityValid)

    let staleCursor = JournalCursor(journal: attentionWorkJournal, eventID: "w0", sequence: 0)
    let stale = try attentionSummary(
        requestedCursor: staleCursor,
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let staleRow = try XCTUnwrap(
        CanonicalAttentionInboxProjection(summary: stale).rows.first)
    XCTAssertNil(staleRow.effectiveAttention)
    XCTAssertEqual(staleRow.attentionRequirement, .unknown)
    XCTAssertNotEqual(staleRow.attachments[0].cursorAlignment, .exact)
    XCTAssertEqual(staleRow.attachments[0].readAlignment, .exact)
}

func test_canonicalAttentionInboxFailsClosedForUnknownDomainsAndTails() throws {
    let unknown = try attentionSummary(
        sessionUnknownDomains: [.session], workUnknownDomains: [.runtime, .externalEffects],
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let unknownRow = try XCTUnwrap(
        CanonicalAttentionInboxProjection(summary: unknown).rows.first)
    XCTAssertNil(unknownRow.authoredAttention)
    XCTAssertNil(unknownRow.effectiveAttention)
    XCTAssertEqual(unknownRow.attentionRequirement, .unknown)
    XCTAssertEqual(unknownRow.sessionUnknownDomains, [.session])
    XCTAssertEqual(unknownRow.attachments[0].unknownDomains, [.externalEffects, .runtime])

    let tailed = try attentionSummary(
        workRead: attentionRead(
            journal: attentionWorkJournal, eventID: "w1", sequence: 1,
            tail: TimelineJournalTail(rawBytes: Data("partial".utf8), byteStart: 3, byteEnd: 10)))
    let tailedRow = try XCTUnwrap(
        CanonicalAttentionInboxProjection(summary: tailed).rows.first)
    XCTAssertNil(tailedRow.effectiveAttention)
    XCTAssertEqual(tailedRow.attentionRequirement, .unknown)
    XCTAssertEqual(tailedRow.attachments[0].readAlignment, .exact)
    XCTAssertEqual(tailedRow.attachments[0].integrityValid, false)
    XCTAssertEqual(tailedRow.attachments[0].tailBytes, 7)
    XCTAssertTrue(tailedRow.attachments[0].corruptionReasons.contains(
        "journal has an uncommitted truncated tail"))
}

func test_canonicalAttentionInboxRejectsForeignAheadAndDivergentWork() throws {
    let foreignWork = WorkRef(workHostID: "foreign-host", workID: "foreign-work")
    let foreignJournal = JournalRef.work(foreignWork, journalID: "foreign-journal")
    let foreign = try attentionSummary(workRead: attentionRead(
        journal: attentionWorkJournal, eventID: "w1", sequence: 1,
        foreignJournal: foreignJournal))
    let foreignRow = try XCTUnwrap(
        CanonicalAttentionInboxProjection(summary: foreign).rows.first)
    XCTAssertNil(foreignRow.effectiveAttention)
    XCTAssertEqual(foreignRow.attentionRequirement, .unknown)
    XCTAssertEqual(foreignRow.attachments[0].readAlignment, .foreign)

    let aheadCursor = JournalCursor(journal: attentionWorkJournal, eventID: "w2", sequence: 2)
    let ahead = try attentionSummary(
        requestedCursor: aheadCursor,
        workRead: attentionReadChain(
            journal: attentionWorkJournal, points: [("w1", 1), ("w2", 2)]))
    let aheadRow = try XCTUnwrap(
        CanonicalAttentionInboxProjection(summary: ahead).rows.first)
    XCTAssertNil(aheadRow.effectiveAttention)
    XCTAssertEqual(aheadRow.attentionRequirement, .unknown)
    XCTAssertEqual(aheadRow.attachments[0].cursorAlignment, .requestedAhead)
    XCTAssertEqual(aheadRow.attachments[0].readAlignment, .ahead)

    let divergentCursor = JournalCursor(
        journal: attentionWorkJournal, eventID: "other-branch", sequence: 1)
    let divergent = try attentionSummary(
        requestedCursor: divergentCursor,
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let divergentRow = try XCTUnwrap(
        CanonicalAttentionInboxProjection(summary: divergent).rows.first)
    XCTAssertNil(divergentRow.effectiveAttention)
    XCTAssertEqual(divergentRow.attentionRequirement, .unknown)
    XCTAssertEqual(divergentRow.attachments[0].cursorAlignment, .divergent)
    XCTAssertEqual(divergentRow.attachments[0].readAlignment, .exact)
}

func test_canonicalAttentionInboxQualifiesRowsByAttachmentIdentity() throws {
    let summary = try attentionSummary(
        attachmentIDs: ["attachment-a", "attachment-b"],
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let rows = CanonicalAttentionInboxProjection(summary: summary, maxRows: 8).rows

    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].attachments.count, 2)
    XCTAssertNotEqual(rows[0].attachments[0].id, rows[0].attachments[1].id)
    XCTAssertEqual(rows[0].attentionRequirement, .required)

    let bounded = CanonicalAttentionInboxProjection(
        summary: summary, maxRows: 8, maxAttachments: 1)
    XCTAssertEqual(bounded.rows.count, 1)
    XCTAssertEqual(bounded.rows[0].attachments.count, 1)
    XCTAssertEqual(bounded.rows[0].omittedAttachmentCount, 1)
}

private func attentionSessionOnlySummary(authorityID: String) throws -> CanonicalSessionCatalogSummary {
    let journal = JournalRef.session(
        attentionSession, journalID: "session-journal", authority: TimelineAuthorityRef(authorityID))
    var session = SessionSnapshot()
    session.session = attentionSession
    session.journal = journal
    session.lifecycle = .active
    session.attention = .input
    session.lastEventID = "s1"
    session.lastSequence = 1
    session.seenEventIDs = ["s1"]
    let readEvent = TimelineEvent(
        eventID: "s1", journal: journal, sequence: 1, session: attentionSession,
        actor: TimelineActor(actorID: "attention-test", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1), type: TimelineEventType.sessionCreated)
    let read = TimelineJournalReadResult(records: [TimelineJournalRecord(
        event: readEvent, rawLineBytes: Data("{}\n".utf8), byteStart: 0, byteEnd: 3)])
    return try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session, works: [], sessionRead: read))
}

func test_canonicalAttentionInboxBoundsAcrossSessionsAndKeepsAuthoritiesDistinct() throws {
    let first = try attentionSessionOnlySummary(authorityID: "authority-a")
    let second = try attentionSessionOnlySummary(authorityID: "authority-b")
    let all = CanonicalAttentionInboxProjection(summaries: [second, first], maxRows: 8)
    XCTAssertEqual(all.rows.count, 2)
    XCTAssertNotEqual(all.rows[0].qualifiedSessionID, all.rows[1].qualifiedSessionID)
    XCTAssertNotEqual(all.rows[0].id, all.rows[1].id)

    let bounded = CanonicalAttentionInboxProjection(summaries: [second, first], maxRows: 1)
    XCTAssertEqual(bounded.rows.count, 1)
    XCTAssertEqual(bounded.omittedRowCount, 1)
    XCTAssertTrue(bounded.isTruncated)
}

func test_canonicalAttentionInboxIsBoundedDeterministicAndAuthorityQualified() throws {
    let secondWork = WorkRef(workHostID: "other-host", workID: attentionWork.workID)
    let secondJournal = JournalRef.work(secondWork, journalID: "other-work-journal")
    var session = SessionSnapshot()
    session.session = attentionSession
    session.journal = attentionSessionJournal
    session.lifecycle = .active
    session.attention = .input
    session.lastEventID = "s1"
    session.lastSequence = 1
    session.seenEventIDs = ["s1"]
    let firstAttachment = SessionAttachmentRef("a1")
    let secondAttachment = SessionAttachmentRef("a2")
    session.attachments[firstAttachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: firstAttachment, work: attentionWork,
        cursor: JournalCursor(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    session.attachments[secondAttachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: secondAttachment, work: secondWork,
        cursor: JournalCursor(journal: secondJournal, eventID: "w1", sequence: 1))

    func workSnapshot(_ work: WorkRef, journal: JournalRef) -> WorkSnapshot {
        var snapshot = WorkSnapshot()
        snapshot.journal = journal
        snapshot.work = work
        snapshot.workHost = WorkHostRef(work.workHostID)
        snapshot.lifecycle = .active
        snapshot.execution = .running
        snapshot.lastEventID = "w1"
        snapshot.lastSequence = 1
        snapshot.eventSequences = ["w1": 1]
        return snapshot
    }
    let summary = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: session,
        works: [workSnapshot(secondWork, journal: secondJournal), workSnapshot(attentionWork, journal: attentionWorkJournal)],
        cursors: [
            firstAttachment.attachmentID: JournalCursor(journal: attentionWorkJournal, eventID: "w1", sequence: 1),
            secondAttachment.attachmentID: JournalCursor(journal: secondJournal, eventID: "w1", sequence: 1)
        ],
        sessionRead: attentionRead(journal: attentionSessionJournal, eventID: "s1", sequence: 1),
        workReads: [
            attentionWorkJournal: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1),
            secondJournal: attentionRead(journal: secondJournal, eventID: "w1", sequence: 1)
        ]))

    let bounded = CanonicalAttentionInboxProjection(summary: summary, maxRows: 1)
    let all = CanonicalAttentionInboxProjection(summary: summary, maxRows: 8)
    XCTAssertEqual(bounded.rows.count, 1)
    XCTAssertEqual(bounded.omittedRowCount, 0)
    XCTAssertFalse(bounded.isTruncated)
    XCTAssertEqual(bounded.rows[0].attachments.count, 2)
    let repeated = CanonicalAttentionInboxProjection(summary: summary, maxRows: 8)
    XCTAssertEqual(all.rows.map(\.id), repeated.rows.map(\.id))
    XCTAssertEqual(all.rows.count, 1)
    XCTAssertNotEqual(all.rows[0].attachments[0].qualifiedWorkID,
                      all.rows[0].attachments[1].qualifiedWorkID)
    XCTAssertTrue(all.rows[0].id.contains("session-authority"))
}

func test_canonicalAttentionInboxBoundsEvidenceAndReasons() throws {
    let summary = try attentionSummary(
        sessionCorruptionReasons: (0..<40).map { "session-reason-\($0)" },
        workCorruptionReasons: (0..<40).map { "work-reason-\($0)-\(String(repeating: "x", count: 600))" },
        sessionUnknownEventCount: 140,
        workUnknownEventCount: 140,
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let row = try XCTUnwrap(CanonicalAttentionInboxProjection(summary: summary).rows.first)
    let evidence = try XCTUnwrap(row.attachments.first)

    XCTAssertEqual(row.sessionUnknownEventRefs.count, CanonicalAttentionInboxProjection.maximumUnknownEventRefs)
    XCTAssertEqual(row.omittedSessionUnknownEventRefCount, 12)
    XCTAssertEqual(row.corruptionReasons.count, CanonicalAttentionInboxProjection.maximumCorruptionReasons)
    XCTAssertEqual(row.omittedCorruptionReasonCount, 8)
    XCTAssertTrue(row.corruptionReasons.allSatisfy { $0.count <= CanonicalAttentionInboxProjection.maximumReasonCharacters })
    XCTAssertEqual(evidence.unknownEventRefs.count, CanonicalAttentionInboxProjection.maximumUnknownEventRefs)
    XCTAssertEqual(evidence.omittedUnknownEventRefCount, 12)
    XCTAssertEqual(evidence.corruptionReasons.count, CanonicalAttentionInboxProjection.maximumCorruptionReasons)
    XCTAssertEqual(evidence.omittedCorruptionReasonCount, 8)
    XCTAssertEqual(evidence.truncatedCorruptionReasonCount, 40)
    XCTAssertTrue(evidence.corruptionReasons.allSatisfy {
        $0.count <= CanonicalAttentionInboxProjection.maximumReasonCharacters
    })
}

func test_canonicalAttentionInboxCoalescesDuplicateJournalSummariesAsConflict() throws {
    let review = try attentionSummary(
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let input = try attentionSummary(
        attention: .input,
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let projection = CanonicalAttentionInboxProjection(summaries: [input, review])
    let row = try XCTUnwrap(projection.rows.first)

    XCTAssertEqual(projection.rows.count, 1)
    XCTAssertEqual(row.duplicateSummaryCount, 2)
    XCTAssertEqual(row.attentionRequirement, .unknown)
    XCTAssertNil(row.authoredAttention)
    XCTAssertNil(row.effectiveAttention)
    XCTAssertTrue(row.attachments.isEmpty)
    XCTAssertEqual(row.omittedAttachmentCount, 0)
    XCTAssertEqual(row.sessionSourceCursor, nil)
    XCTAssertEqual(row.sessionCursorAlignment, .divergent)
    XCTAssertNil(row.sessionIntegrityValid)
    XCTAssertFalse(row.sessionStructuralIntegrityValid)
    XCTAssertFalse(row.sessionSemanticProjectionValid)
    XCTAssertEqual(row.sessionUnknownEventRefs, [])
    XCTAssertEqual(row.omittedSessionUnknownEventRefCount, 0)
    XCTAssertEqual(row.omittedCorruptionReasonCount, 0)
    XCTAssertTrue(row.corruptionReasons.contains {
        $0.contains("duplicate canonical Session summaries")
    })
}
