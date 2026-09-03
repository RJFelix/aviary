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
    indeterminateActionID: String? = nil,
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
        if let indeterminateActionID {
            work.actions[indeterminateActionID] = WorkActionSnapshot(
                action: ActionRef(indeterminateActionID), state: .indeterminateEffect,
                failureKind: .indeterminateEffect, retrySafety: .unknown)
        }
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

private func attentionSessionOnlySummary(
    authorityID: String, attention: SessionAttention = .input,
    attentionEventID: String? = nil
) throws -> CanonicalSessionCatalogSummary {
    let journal = JournalRef.session(
        attentionSession, journalID: "session-journal", authority: TimelineAuthorityRef(authorityID))
    var session = SessionSnapshot()
    session.session = attentionSession
    session.journal = journal
    session.lifecycle = .active
    session.attention = attention
    let sourceID = attentionEventID ?? "s1"
    session.lastEventID = sourceID
    session.lastSequence = 1
    session.seenEventIDs = [sourceID]
    session.attentionEvent = EventRef(journal: journal, eventID: sourceID)
    let readEvent = TimelineEvent(
        eventID: sourceID, journal: journal, sequence: 1, session: attentionSession,
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

func test_canonicalNotificationsClassifyAndRetainActionIdentity() throws {
    let needsYou = try attentionSessionOnlySummary(authorityID: "notification-needs")
    let needsProjection = CanonicalNotificationProjection(summaries: [needsYou])
    let needs = try XCTUnwrap(needsProjection.candidates.first)
    XCTAssertEqual(needs.kind, .needsYou)
    XCTAssertEqual(needs.actionIdentity.session, attentionSession)
    XCTAssertEqual(needs.sourceCursor.eventID, "s1")
    let userInfo = try XCTUnwrap(needs.routeUserInfo)
    XCTAssertEqual(userInfo.count, 1, "the OS payload has one canonical route value")
    let decodedRoute = try XCTUnwrap(CanonicalNotificationRoute.decode(userInfo: userInfo))
    XCTAssertEqual(decodedRoute, needs.route)

    var reviewSession = SessionSnapshot()
    let reviewJournal = JournalRef.session(
        attentionSession, journalID: "review-journal", authority: TimelineAuthorityRef("review"))
    reviewSession.session = attentionSession
    reviewSession.journal = reviewJournal
    reviewSession.lifecycle = .completed
    reviewSession.attention = .review
    reviewSession.lastEventID = "review-tip"
    reviewSession.lastSequence = 1
    reviewSession.seenEventIDs = ["review-tip"]
    let reviewEvent = TimelineEvent(
        eventID: "review-tip", journal: reviewJournal, sequence: 1,
        session: attentionSession, actor: TimelineActor(actorID: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1), type: TimelineEventType.sessionCreated)
    let review = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: reviewSession, works: [], sessionRead: TimelineJournalReadResult(records: [
            TimelineJournalRecord(event: reviewEvent, rawLineBytes: Data("{}\n".utf8), byteStart: 0, byteEnd: 3)
        ])))
    let reviewCandidate = try XCTUnwrap(
        CanonicalNotificationProjection(summaries: [review]).candidates.first)
    XCTAssertEqual(reviewCandidate.kind, .readyForReview)
}

func test_canonicalNotificationDeliveryBaselinesDeduplicatesAndWithholdsIncompleteScans() throws {
    let summary = try attentionSessionOnlySummary(
        authorityID: "notification-delivery", attention: .review)
    let projection = CanonicalNotificationProjection(summaries: [summary])
    var delivery = CanonicalNotificationDelivery()
    XCTAssertTrue(delivery.plan(projection).candidates.isEmpty)
    XCTAssertTrue(delivery.plan(projection).candidates.isEmpty)

    let none = try attentionSessionOnlySummary(
        authorityID: "notification-delivery", attention: .none)
    XCTAssertTrue(delivery.plan(CanonicalNotificationProjection(summaries: [none])).candidates.isEmpty)
    let returned = delivery.plan(projection).candidates
    XCTAssertEqual(returned.count, 1)
    XCTAssertEqual(returned[0].kind, .readyForReview)

    let truncated = CanonicalNotificationProjection(summaries: [summary], maxCandidates: 0)
    XCTAssertFalse(truncated.isComplete)
    XCTAssertTrue(delivery.plan(truncated).candidates.isEmpty)
}

func test_canonicalNotificationsRetainUnknownsConflictsAndTransitionProvenance() throws {
    let baseline = try attentionSessionOnlySummary(
        authorityID: "notification-fingerprint", attention: .review, attentionEventID: "review-1")
    var delivery = CanonicalNotificationDelivery()
    XCTAssertTrue(delivery.plan(CanonicalNotificationProjection(summaries: [baseline])).candidates.isEmpty)
    let repeated = try attentionSessionOnlySummary(
        authorityID: "notification-fingerprint", attention: .review, attentionEventID: "review-2")
    let repeatedPlan = delivery.plan(CanonicalNotificationProjection(summaries: [repeated]))
    XCTAssertEqual(repeatedPlan.candidates.count, 1,
                   "a second review event is a new source transition")
    XCTAssertNotEqual(repeatedPlan.candidates[0].id, CanonicalNotificationProjection(
        summaries: [baseline]).candidates[0].id)
    delivery.commit(repeatedPlan.candidates[0])

    let exact = try attentionSessionOnlySummary(authorityID: "unrelated-exact", attention: .review)
    let conflictProjection = CanonicalNotificationProjection(summaries: [baseline, baseline, exact])
    XCTAssertEqual(conflictProjection.conflictingSessionCount, 1)
    XCTAssertEqual(conflictProjection.candidates.count, 1,
                   "one conflicted Session must not suppress an unrelated exact Session")

    let healthyNone = try attentionSessionOnlySummary(
        authorityID: "interleaved-healthy", attention: .none, attentionEventID: "healthy-none")
    let healthyReview = try attentionSessionOnlySummary(
        authorityID: "interleaved-healthy", attention: .review, attentionEventID: "healthy-review")
    let conflict = try attentionSessionOnlySummary(
        authorityID: "interleaved-conflict", attention: .review, attentionEventID: "conflict-review")
    var interleavedDelivery = CanonicalNotificationDelivery()
    _ = interleavedDelivery.plan(CanonicalNotificationProjection(
        summaries: [healthyNone, conflict, conflict]))
    let interleavedPlan = interleavedDelivery.plan(CanonicalNotificationProjection(
        summaries: [healthyReview, conflict, conflict]))
    XCTAssertEqual(interleavedPlan.candidates.count, 1,
                   "an exact Session may transition while another row is conflicted")
    interleavedDelivery.commit(try XCTUnwrap(interleavedPlan.candidates.first))
    XCTAssertTrue(interleavedDelivery.plan(CanonicalNotificationProjection(
        summaries: [healthyReview, conflict, conflict])).candidates.isEmpty,
        "the interleaved healthy transition must not repeat on the next poll")

    let complete = try attentionSummary(attention: .review, workSnapshot: false)
    let unknownProjection = CanonicalNotificationProjection(summaries: [complete])
    XCTAssertTrue(unknownProjection.candidates.isEmpty)
    XCTAssertTrue(unknownProjection.observedStates.isEmpty,
                  "unknown Work must not be collapsed into a baseline `.none`")

    var incompleteDelivery = CanonicalNotificationDelivery()
    let incomplete = CanonicalNotificationProjection(
        summaries: [baseline], sourceComplete: false)
    XCTAssertFalse(incomplete.isComplete)
    XCTAssertTrue(incompleteDelivery.plan(incomplete).candidates.isEmpty)
    XCTAssertTrue(incompleteDelivery.plan(CanonicalNotificationProjection(
        summaries: [baseline])).candidates.isEmpty,
        "a source-completeness failure must not consume or replace the baseline")
}

func test_canonicalNotificationDeliveryCommitsOnlyAfterAcknowledgementAndPersists() throws {
    let none = try attentionSessionOnlySummary(authorityID: "notification-ack", attention: .none)
    let review = try attentionSessionOnlySummary(
        authorityID: "notification-ack", attention: .review, attentionEventID: "ack-review")
    var delivery = CanonicalNotificationDelivery()
    _ = delivery.plan(CanonicalNotificationProjection(summaries: [none]))
    let plan = delivery.plan(CanonicalNotificationProjection(summaries: [review]))
    let candidate = try XCTUnwrap(plan.candidates.first)
    XCTAssertEqual(delivery.plan(CanonicalNotificationProjection(summaries: [review])).candidates.count, 0,
                   "an in-flight candidate is reserved until its platform request resolves")
    delivery.rollback(candidate)
    let retryPlan = delivery.plan(CanonicalNotificationProjection(summaries: [review]))
    XCTAssertEqual(retryPlan.candidates.count, 1)
    let retry = try XCTUnwrap(retryPlan.candidates.first)
    delivery.commit(retry)
    let checkpoint = try XCTUnwrap(delivery.checkpointData)
    var restored = CanonicalNotificationDelivery(checkpoint: checkpoint)
    XCTAssertTrue(restored.plan(CanonicalNotificationProjection(summaries: [review])).candidates.isEmpty,
                  "an acknowledged transition remains deduplicated across relaunch")
}

func test_canonicalNotificationDeliveryEmitsForSessionCreatedAfterInitialBaseline() throws {
    var delivery = CanonicalNotificationDelivery()
    XCTAssertTrue(delivery.plan(
        CanonicalNotificationProjection(summaries: [])).candidates.isEmpty)

    let firstReview = try attentionSessionOnlySummary(
        authorityID: "notification-new-session", attention: .review,
        attentionEventID: "new-session-review")
    let plan = delivery.plan(CanonicalNotificationProjection(summaries: [firstReview]))
    XCTAssertEqual(plan.candidates.count, 1)
    XCTAssertEqual(plan.candidates.first?.kind, .readyForReview)
    delivery.commit(try XCTUnwrap(plan.candidates.first))
    XCTAssertTrue(delivery.plan(
        CanonicalNotificationProjection(summaries: [firstReview])).candidates.isEmpty)
}

func test_canonicalNotificationIdentityIsInjectiveAndRequestIDsBounded() throws {
    let cursor = JournalCursor(journal: attentionSessionJournal, eventID: "cursor", sequence: 1)
    let first = CanonicalNotificationCandidate(
        kind: .failedRecovery, title: "generic", body: "generic",
        actionIdentity: CanonicalNotificationActionIdentity(
            session: SessionRef("a|b"), sessionJournal: attentionSessionJournal,
            work: attentionWork, workJournal: attentionWorkJournal,
            sessionAttachment: SessionAttachmentRef("attachment/a"), action: ActionRef("x|y")),
        sourceCursor: cursor)
    let second = CanonicalNotificationCandidate(
        kind: .failedRecovery, title: "generic", body: "generic",
        actionIdentity: CanonicalNotificationActionIdentity(
            session: SessionRef("a"), sessionJournal: attentionSessionJournal,
            work: attentionWork, workJournal: attentionWorkJournal,
            sessionAttachment: SessionAttachmentRef("attachment/a"), action: ActionRef("x|y")),
        sourceCursor: cursor)
    XCTAssertNotEqual(first.actionIdentity.stableKey, second.actionIdentity.stableKey)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertTrue(first.id.utf8.count <= 128,
                  "OS request IDs must not contain unbounded user-controlled identity bytes")
}

func test_canonicalNotificationRouteRejectsOversizedOrForeignPayloads() throws {
    let hugeSession = SessionRef(String(repeating: "s", count: 20_000))
    let journal = try JournalRef(
        journalID: "huge-session-journal", authority: TimelineAuthorityRef("route"),
        owner: .session(hugeSession))
    let route = CanonicalNotificationRoute(
        kind: .needsYou, session: hugeSession, sessionJournal: journal,
        sourceSessionCursor: JournalCursor(journal: journal, eventID: "event", sequence: 1))
    XCTAssertNil(route.encodedValue)
    XCTAssertNil(CanonicalNotificationRoute.decode(userInfo: [
        CanonicalNotificationRoute.userInfoKey: String(repeating: "A", count: 20_000)
    ]))

    let other = try attentionSessionOnlySummary(authorityID: "route-foreign")
    let candidate = try XCTUnwrap(CanonicalNotificationProjection(summaries: [other]).candidates.first)
    let foreignRoute = CanonicalNotificationRoute(
        kind: candidate.kind, session: candidate.actionIdentity.session,
        sessionJournal: candidate.actionIdentity.sessionJournal,
        sourceSessionCursor: JournalCursor(
            journal: attentionSessionJournal, eventID: "foreign", sequence: 1))
    XCTAssertFalse(foreignRoute.isValid)

    let invalidCursor = CanonicalNotificationRoute(
        kind: .needsYou, session: attentionSession, sessionJournal: attentionSessionJournal,
        sourceSessionCursor: JournalCursor(
            journal: attentionSessionJournal, eventID: "", sequence: 0))
    XCTAssertFalse(invalidCursor.isValid, "routes need positive, named Session evidence")
    let incoherentKind = CanonicalNotificationRoute(
        kind: .failedRecovery, session: attentionSession, sessionJournal: attentionSessionJournal,
        sourceSessionCursor: JournalCursor(
            journal: attentionSessionJournal, eventID: "event", sequence: 1))
    XCTAssertFalse(incoherentKind.isValid,
                   "failed recovery routes must retain Work, action, and outcome identity")
    let wrongRecoveryOutcome = CanonicalNotificationRoute(
        kind: .failedRecovery, session: attentionSession,
        sessionJournal: attentionSessionJournal, work: attentionWork,
        workJournal: attentionWorkJournal,
        sessionAttachment: SessionAttachmentRef("attachment"), action: ActionRef("action"),
        outcome: .failed, sourceSessionCursor: JournalCursor(
            journal: attentionSessionJournal, eventID: "event", sequence: 1))
    XCTAssertFalse(wrongRecoveryOutcome.isValid,
                   "failed-recovery routes must name an indeterminate external effect")
    let incompleteRecoveryEvidence = CanonicalNotificationRoute(
        kind: .failedRecovery, session: attentionSession,
        sessionJournal: attentionSessionJournal, work: attentionWork,
        workJournal: attentionWorkJournal,
        sessionAttachment: SessionAttachmentRef("attachment"), action: ActionRef("action"),
        outcome: .indeterminateEffect, sourceSessionCursor: JournalCursor(
            journal: attentionSessionJournal, eventID: "event", sequence: 1))
    XCTAssertFalse(incompleteRecoveryEvidence.isValid,
                   "failed-recovery routes require the exact Work evidence cursor")
    let workBackedReview = CanonicalNotificationRoute(
        kind: .readyForReview, session: attentionSession,
        sessionJournal: attentionSessionJournal, work: attentionWork,
        workJournal: attentionWorkJournal, sourceSessionCursor: JournalCursor(
            journal: attentionSessionJournal, eventID: "event", sequence: 1),
        workCursor: JournalCursor(
            journal: attentionWorkJournal, eventID: "work-event", sequence: 1))
    XCTAssertFalse(workBackedReview.isValid,
                   "non-recovery routes cannot carry unused Work evidence")
    let incoherentFields = CanonicalNotificationRoute(
        kind: .readyForReview, session: attentionSession, sessionJournal: attentionSessionJournal,
        action: ActionRef("unexpected-action"), sourceSessionCursor: JournalCursor(
            journal: attentionSessionJournal, eventID: "event", sequence: 1))
    XCTAssertFalse(incoherentFields.isValid,
                   "review routes cannot carry failed-action fields")
}

func test_canonicalNotificationProjectionReconcilesIdenticalRoutesOnly() throws {
    let summary = try attentionSummary(
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let projection = CanonicalNotificationProjection(summaries: [summary])
    let candidate = try XCTUnwrap(projection.candidates.first)
    XCTAssertTrue(candidate.route.isValid,
                  "a cursor-backed route does not require a separate attention EventRef")
    XCTAssertEqual(projection.candidate(matching: candidate.route)?.id, candidate.id)

    let stale = CanonicalNotificationRoute(
        kind: candidate.kind, session: candidate.actionIdentity.session,
        sessionJournal: candidate.actionIdentity.sessionJournal,
        work: candidate.actionIdentity.work, workJournal: candidate.actionIdentity.workJournal,
        sessionAttachment: candidate.actionIdentity.sessionAttachment,
        action: candidate.actionIdentity.action, outcome: candidate.actionIdentity.outcome,
        sourceSessionCursor: JournalCursor(
            journal: candidate.sourceCursor.journal,
            eventID: "later-session-event", sequence: candidate.sourceCursor.sequence + 1),
        sourceSessionEvent: candidate.sourceEvent,
        workCursor: candidate.workCursor)
    XCTAssertTrue(stale.isValid)
    XCTAssertNil(projection.candidate(matching: stale))
}

func test_canonicalNotificationProjectionQualifiesSameWorkActionByAttachment() throws {
    let first = try attentionSummary(
        attention: .error, attachmentIDs: ["z-attachment", "a-attachment"],
        indeterminateActionID: "shared-action",
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let second = try attentionSummary(
        attention: .error, attachmentIDs: ["a-attachment", "z-attachment"],
        indeterminateActionID: "shared-action",
        workRead: attentionRead(journal: attentionWorkJournal, eventID: "w1", sequence: 1))
    let firstCandidate = try XCTUnwrap(
        CanonicalNotificationProjection(summaries: [first]).candidates.first)
    let secondCandidate = try XCTUnwrap(
        CanonicalNotificationProjection(summaries: [second]).candidates.first)
    XCTAssertEqual(firstCandidate.kind, .failedRecovery)
    XCTAssertEqual(firstCandidate.actionIdentity.sessionAttachment,
                   SessionAttachmentRef("a-attachment"))
    XCTAssertEqual(secondCandidate.actionIdentity.sessionAttachment,
                   SessionAttachmentRef("a-attachment"))
    XCTAssertEqual(firstCandidate.route, secondCandidate.route)
}

func test_canonicalNotificationCheckpointIsBoundedAndCurrentKeysSurvivePruning() throws {
    var delivery = CanonicalNotificationDelivery()
    let summaries = try (0..<1025).map {
        try attentionSessionOnlySummary(
            authorityID: "checkpoint-\($0)", attention: .none, attentionEventID: "none-\($0)")
    }
    for chunkStart in stride(from: 0, to: summaries.count, by: 512) {
        let chunk = Array(summaries[chunkStart..<min(chunkStart + 512, summaries.count)])
        _ = delivery.plan(CanonicalNotificationProjection(summaries: chunk))
    }
    let data = try XCTUnwrap(delivery.checkpointData)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let states = try XCTUnwrap(object["stateBySession"] as? [String: Any])
    XCTAssertTrue(
        states.count <= CanonicalNotificationDelivery.maximumCheckpointSessions,
        "checkpoint state must stay bounded")

    let newest = try attentionSessionOnlySummary(
        authorityID: "checkpoint-newest", attention: .review, attentionEventID: "newest")
    let projection = CanonicalNotificationProjection(summaries: [newest])
    _ = delivery.plan(projection)
    let retry = delivery.plan(projection)
    XCTAssertTrue(retry.candidates.isEmpty, "the current projection remains deduplicated after pruning")
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
