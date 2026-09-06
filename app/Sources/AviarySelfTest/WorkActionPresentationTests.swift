import Foundation
@testable import AviaryCore

private let actionPresentationHost = WorkHostRef("action-presentation-host")
private let actionPresentationWork = WorkRef(
    workHostID: actionPresentationHost.workHostID, workID: "action-presentation-work")
private let actionPresentationJournal = JournalRef.work(actionPresentationWork)
private let actionPresentationActor = TimelineActor(
    actorID: "action-presentation-actor", kind: "work-host")

private func actionPresentationObservation(
    _ id: String, sequence: Int, at time: TimeInterval,
    causedBy: EventRef? = nil, links: [TimelineLink] = []
) -> WorkActionObservation {
    WorkActionObservation(
        sourceEvent: EventRef(journal: actionPresentationJournal, eventID: id),
        sequence: sequence, hostSequence: sequence,
        run: RunRef("action-run"), turn: TurnRef("action-turn"),
        actor: actionPresentationActor,
        hostRecordedAt: Date(timeIntervalSince1970: time),
        clientTimestamp: Date(timeIntervalSince1970: 99_999),
        causedBy: causedBy,
        parentActivity: nil,
        provenance: .native, links: links)
}

private func actionPresentationSnapshot(
    id: String, kind: ActionKind, state: ActionExecutionState = .succeeded,
    sequence: Int = 1, start: TimeInterval? = 10, end: TimeInterval? = 12,
    metadata: [String: JSONValue] = [:], metadataWasTruncated: Bool = false,
    failureKind: ActionFailureKind? = nil,
    retrySafety: ActionRetrySafety? = .idempotent,
    intent: String? = "inspect the target", target: String? = "target-1"
) -> WorkActionSnapshot {
    let root = actionPresentationObservation("intent-\(id)", sequence: sequence, at: start ?? 1)
    let started = start.map {
        actionPresentationObservation("started-\(id)", sequence: sequence + 1, at: $0)
    }
    let outcome = end.map {
        actionPresentationObservation("outcome-\(id)", sequence: sequence + 2, at: $0)
    }
    return WorkActionSnapshot(
        action: ActionRef(id), state: state, failureKind: failureKind,
        retrySafety: retrySafety, kind: kind, intent: intent, target: target,
        scope: "turn", metadata: metadata, metadataWasTruncated: metadataWasTruncated,
        intentEvent: root, startedEvent: started, outcomeEvent: outcome)
}

func testWorkActionPresentationCoversEveryKindAndBoundaryDisclosure() throws {
    let actions = ActionKind.allCases.enumerated().map { index, kind in
        actionPresentationSnapshot(id: "kind-\(index)", kind: kind)
    }
    let presentations = WorkActionPresentation.project(actions)
    XCTAssertEqual(presentations.count, ActionKind.allCases.count)
    for kind in ActionKind.allCases {
        let presentation = try XCTUnwrap(presentations.first { $0.kind == kind })
        XCTAssertEqual(presentation.kind, kind)
        XCTAssertFalse(presentation.kindTitle.isEmpty)
        XCTAssertFalse(presentation.boundaryDisclosure.isEmpty)
        XCTAssertFalse(presentation.availability.exactInput.isEmpty)
        XCTAssertFalse(presentation.availability.output.isEmpty)
        XCTAssertFalse(presentation.availability.effects.isEmpty)
        XCTAssertFalse(presentation.availability.confirmation.isEmpty)
        XCTAssertFalse(presentation.availability.checkpoint.isEmpty)
        XCTAssertEqual(presentation.state, .succeeded)
        XCTAssertNotNil(presentation.failureGuidance)
        XCTAssertNotNil(presentation.retryGuidance)
    }
    let python = try XCTUnwrap(presentations.first { $0.kind == .python })
    XCTAssertTrue(python.boundaryDisclosure.localizedCaseInsensitiveContains("not observe"))
    XCTAssertTrue(python.boundaryDisclosure.localizedCaseInsensitiveContains("contain"))
}

func testWorkActionPresentationUsesCanonicalHostTimesAndWithholdsNegativeDuration() throws {
    let cause = EventRef(journal: actionPresentationJournal, eventID: "cause")
    let link = TimelineLink(kind: .supports, target: cause)
    let normal = actionPresentationSnapshot(
        id: "timed", kind: .runtime, sequence: 4, start: 20, end: 27)
    let normalPresentation = WorkActionPresentation(normal)
    XCTAssertEqual(normalPresentation.durationSeconds, 7)
    XCTAssertEqual(normalPresentation.hostStartTime, Date(timeIntervalSince1970: 20))
    XCTAssertEqual(normalPresentation.hostEndTime, Date(timeIntervalSince1970: 27))

    let invalid = actionPresentationSnapshot(
        id: "negative", kind: .runtime, sequence: 7, start: 30, end: 29)
    let invalidPresentation = WorkActionPresentation(invalid)
    XCTAssertNil(invalidPresentation.durationSeconds)
    XCTAssertTrue(invalidPresentation.timeAvailability.contains("withheld"))

    let linked = WorkActionSnapshot(
        action: ActionRef("linked"), state: .running, kind: .child,
        intent: "run child", target: "child-work", scope: "run",
        intentEvent: actionPresentationObservation(
            "linked-intent", sequence: 1, at: 1, causedBy: cause, links: [link]))
    let linkedPresentation = WorkActionPresentation(linked)
    XCTAssertEqual(linkedPresentation.intentEvidence?.sourceEvent.journal, actionPresentationJournal)
    XCTAssertEqual(linkedPresentation.intentEvidence?.actor, actionPresentationActor)
    XCTAssertEqual(linkedPresentation.intentEvidence?.run, RunRef("action-run"))
    XCTAssertEqual(linkedPresentation.intentEvidence?.turn, TurnRef("action-turn"))
    XCTAssertEqual(linkedPresentation.intentEvidence?.provenance, .native)
    XCTAssertEqual(linkedPresentation.intentEvidence?.causedBy, cause)
    XCTAssertEqual(linkedPresentation.causalLinks, [link])

    let intentLinks = (0..<40).map { offset in
        TimelineLink(kind: .supports, target: EventRef(
            journal: actionPresentationJournal, eventID: "intent-link-\(offset)"))
    }
    let startedLinks = (0..<20).map { offset in
        TimelineLink(kind: .produced, target: EventRef(
            journal: actionPresentationJournal, eventID: "started-link-\(offset)"))
    }
    let outcomeLinks = (0..<20).map { offset in
        TimelineLink(kind: .verifies, target: EventRef(
            journal: actionPresentationJournal, eventID: "outcome-link-\(offset)"))
    }
    let boundedLinks = WorkActionPresentation(WorkActionSnapshot(
        action: ActionRef("many-links"), state: .succeeded, kind: .runtime,
        intentEvent: actionPresentationObservation(
            "many-links-intent", sequence: 2, at: 2, links: intentLinks),
        startedEvent: actionPresentationObservation(
            "many-links-started", sequence: 3, at: 3, links: startedLinks),
        outcomeEvent: actionPresentationObservation(
            "many-links-outcome", sequence: 4, at: 4, links: outcomeLinks)))
    XCTAssertEqual(boundedLinks.causalLinks.count, WorkActionPresentation.maxCausalLinks)
    XCTAssertEqual(boundedLinks.intentEvidence?.omittedEvidenceLinkCount, 8)
    XCTAssertEqual(boundedLinks.omittedCausalLinkCount, 48)
    XCTAssertFalse(boundedLinks.omittedCausalLinkCountIsLowerBound)

    let saturatedObservation = WorkActionObservation(
        sourceEvent: EventRef(journal: actionPresentationJournal, eventID: "saturated-source"),
        sequence: 5, actor: actionPresentationActor,
        hostRecordedAt: Date(timeIntervalSince1970: 5),
        omittedEvidenceLinkCount: TimelineEvent.maxOmittedEvidenceLinkCount + 1)
    let saturatedPresentation = WorkActionPresentation(WorkActionSnapshot(
        action: ActionRef("saturated-links"), state: .running, kind: .runtime,
        intentEvent: saturatedObservation))
    XCTAssertEqual(
        saturatedPresentation.omittedCausalLinkCount,
        TimelineEvent.maxOmittedEvidenceLinkCount)
    XCTAssertTrue(saturatedPresentation.omittedCausalLinkCountIsLowerBound)

    let validObservation = WorkActionObservation(
        sourceEvent: EventRef(journal: actionPresentationJournal, eventID: "bounded-source"),
        sequence: 1, actor: actionPresentationActor,
        hostRecordedAt: Date(timeIntervalSince1970: 1),
        omittedEvidenceLinkCount: 8, links: [link])
    let validRoundTrip = try JSONDecoder().decode(
        WorkActionObservation.self, from: JSONEncoder().encode(validObservation))
    XCTAssertEqual(validRoundTrip.omittedEvidenceLinkCount, 8)
    guard case .object(let validObject) = JSONValue.parse(
        try JSONEncoder().encode(validObservation)) else {
        XCTFail("Work action observation must encode as an object")
        return
    }
    for invalidCount in [-1, 0, TimelineEvent.maxOmittedEvidenceLinkCount + 1] {
        var forged = validObject
        forged["omittedEvidenceLinkCount"] = .number(Double(invalidCount))
        do {
            _ = try JSONDecoder().decode(
                WorkActionObservation.self,
                from: JSONEncoder().encode(JSONValue.object(forged)))
            XCTFail("Work action observation accepted invalid omitted link count")
        } catch { }
    }
    var oversizedLinks = validObject
    oversizedLinks["links"] = .array((0...TimelineEvent.maxEvidenceLinks).map { index in
        JSONValue.parse(try! JSONEncoder().encode(TimelineLink(
            kind: .supports, target: EventRef(
                journal: actionPresentationJournal, eventID: "oversized-link-\(index)"))))!
    })
    do {
        _ = try JSONDecoder().decode(
            WorkActionObservation.self,
            from: JSONEncoder().encode(JSONValue.object(oversizedLinks)))
        XCTFail("Work action observation accepted an oversized link array")
    } catch { }
}

func testWorkActionPresentationFailureRetryAndPrivacyContracts() throws {
    let states: [(ActionExecutionState, ActionFailureKind, ActionRetrySafety)] = [
        (.failed, .task, .safe),
        (.canceled, .cancellation, .unsafe),
        (.indeterminateEffect, .indeterminateEffect, .unknown),
    ]
    for (_, values) in states.enumerated() {
        let presentation = WorkActionPresentation(actionPresentationSnapshot(
            id: "terminal-\(values.0.rawValue)", kind: .python, state: values.0,
            failureKind: values.1, retrySafety: values.2))
        XCTAssertNotNil(presentation.failureGuidance)
        XCTAssertNotNil(presentation.retryGuidance)
        XCTAssertTrue(presentation.failureGuidance?.isEmpty == false)
        XCTAssertTrue(presentation.retryGuidance?.isEmpty == false)
        XCTAssertEqual(presentation.failureKind, values.1)
        XCTAssertEqual(presentation.retrySafety, values.2)
    }
    let secret = "credential=do-not-copy"
    let snapshot = actionPresentationSnapshot(
        id: String(repeating: "x", count: 600), kind: .mcp,
        metadata: ["secret": .string(secret), "nested": .object(["token": .string(secret)])],
        metadataWasTruncated: true)
    let presentation = WorkActionPresentation(snapshot)
    XCTAssertTrue(presentation.identifierWasTruncated)
    XCTAssertTrue(presentation.id.utf8.count <= WorkActionPresentation.maxIdentifierCharacters)
    let distinct = WorkActionPresentation(actionPresentationSnapshot(
        id: String(repeating: "x", count: 599) + "y", kind: .mcp))
    XCTAssertTrue(distinct.id != presentation.id)
    XCTAssertEqual(presentation.metadataEntryCount, 2)
    XCTAssertTrue(presentation.metadataWasTruncated)
    let encoded = String(decoding: try JSONEncoder().encode(presentation), as: UTF8.self)
    XCTAssertFalse(encoded.contains(secret))
    XCTAssertFalse(encoded.contains("token"))
    XCTAssertTrue(presentation.availability.confirmation.contains("not recorded"))
    XCTAssertTrue(presentation.availability.checkpoint.contains("not recorded"))

    let noEvidence = WorkActionPresentation(actionPresentationSnapshot(
        id: "missing", kind: .artifact, state: .proposed, start: nil, end: nil,
        retrySafety: nil, intent: nil, target: nil))
    XCTAssertTrue(noEvidence.availability.exactInput.contains("not recorded"))
    XCTAssertTrue(noEvidence.availability.output.contains("not observed"))
    XCTAssertTrue(noEvidence.hostStartTime == nil)
    XCTAssertTrue(noEvidence.hostEndTime == nil)
    XCTAssertTrue(noEvidence.failureGuidance == nil)
}

func testWorkActionPresentationRetainsUnsettledBeforeNewestTerminalWithinBound() throws {
    var actions: [WorkActionSnapshot] = []
    for index in 0..<300 {
        actions.append(actionPresentationSnapshot(
            id: "terminal-\(String(format: "%03d", index))", kind: .runtime,
            state: .succeeded, sequence: index + 1,
            start: TimeInterval(index), end: TimeInterval(index + 1)))
    }
    actions.append(actionPresentationSnapshot(
        id: "active-early", kind: .python, state: .running, sequence: 2,
        start: 2, end: nil))
    let projection = WorkActionPresentation.projectWithOmissions(actions)
    XCTAssertEqual(projection.presentations.count, 256)
    XCTAssertTrue(projection.presentations.contains { $0.id == "active-early" })
    XCTAssertEqual(projection.presentations.first?.id, "active-early")
    XCTAssertEqual(projection.presentations.dropFirst().first?.id, "terminal-299")
    XCTAssertEqual(projection.omittedUnsettledCount, 0)
    XCTAssertEqual(projection.omittedTerminalCount, 45)
    XCTAssertTrue(projection.wasTruncated)
    XCTAssertEqual(projection.omittedCount, 45)

    let allActive = (0..<300).map { index in
        actionPresentationSnapshot(
            id: "active-\(index)", kind: .runtime, state: .running,
            sequence: index + 1, start: TimeInterval(index), end: nil)
    }
    let activeProjection = WorkActionPresentation.projectWithOmissions(allActive)
    XCTAssertEqual(activeProjection.presentations.count, 256)
    XCTAssertEqual(activeProjection.omittedUnsettledCount, 44)
    XCTAssertEqual(activeProjection.omittedTerminalCount, 0)

    let statePriority = WorkActionPresentation.project([
        actionPresentationSnapshot(
            id: "unknown-old", kind: .runtime, state: .unknown,
            sequence: 1, start: nil, end: nil),
        actionPresentationSnapshot(
            id: "proposed-old", kind: .runtime, state: .proposed,
            sequence: 2, start: nil, end: nil),
        actionPresentationSnapshot(
            id: "queued", kind: .runtime, state: .queued,
            sequence: 3, start: nil, end: nil),
        actionPresentationSnapshot(
            id: "running-new", kind: .runtime, state: .running,
            sequence: 100, start: 101, end: nil),
        actionPresentationSnapshot(
            id: "cancel-requested", kind: .runtime, state: .cancelRequested,
            sequence: 101, start: 102, end: nil),
    ])
    XCTAssertEqual(
        statePriority.map(\.id),
        ["running-new", "cancel-requested", "queued", "proposed-old", "unknown-old"])
}

let casesWorkActionPresentation: [Case] = [
    ("phase4 action presentation: every kind has fixed boundary language", {
        try testWorkActionPresentationCoversEveryKindAndBoundaryDisclosure()
    }),
    ("phase4 action presentation: host time and causal evidence are canonical", {
        try testWorkActionPresentationUsesCanonicalHostTimesAndWithholdsNegativeDuration()
    }),
    ("phase4 action presentation: terminal guidance and privacy stay explicit", {
        try testWorkActionPresentationFailureRetryAndPrivacyContracts()
    }),
    ("phase4 action presentation: unsettled actions outrank terminal history", {
        try testWorkActionPresentationRetainsUnsettledBeforeNewestTerminalWithinBound()
    }),
]
