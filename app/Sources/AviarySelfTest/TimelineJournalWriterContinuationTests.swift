import Foundation
@testable import AviaryCore

private func continuationHome(_ suffix: String) -> AgentHome {
    AgentHome(root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "aviary-writer-\(suffix)-\(UUID().uuidString)"))
}

private func continuationDraft(
    _ type: String, work: WorkRef
) -> TimelineEventDraft {
    TimelineEventDraft(
        work: work,
        workHost: WorkHostRef(work.workHostID),
        type: type,
        declaredDomains: [.work])
}

func testTimelineJournalWriterContinuationSeedsOnceAndAdvancesAfterCommit() async throws {
    let home = continuationHome("seed")
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: home.workHostID, workID: "writer-continuation-seed")
    let url = home.timelineV2WorkJournalURL(work)
    let journal = JournalRef.work(work, journalID: "work")
    let writer = try TimelineJournalWriter.createFresh(
        at: url, journal: journal, actor: TimelineActor(actorID: "continuation", kind: "test"),
        home: home)

    _ = try await writer.append(continuationDraft(TimelineEventType.workCreated, work: work))
    XCTAssertEqual(await writer.canonicalContinuationSeedCount, 1)
    XCTAssertEqual(await writer.canonicalContinuationApplyCount, 1)

    _ = try await writer.append(continuationDraft(TimelineEventType.workFailed, work: work))
    XCTAssertEqual(await writer.canonicalContinuationSeedCount, 1,
                   "a second append must use the writer-owned continuation")
    XCTAssertEqual(await writer.canonicalContinuationApplyCount, 2)

    _ = try await writer.readCanonicalProjection(
        expectedWork: work, expectedWorkHost: WorkHostRef(work.workHostID),
        maximumResidentRecords: 0)
    XCTAssertEqual(await writer.canonicalContinuationSeedCount, 1,
                   "a read over the unchanged source must not reseed the continuation")
    XCTAssertEqual(await writer.canonicalContinuationApplyCount, 2)
    try await writer.closeChecked()
}

func testTimelineJournalWriterContinuationInvalidatesAfterUncertainWrite() async throws {
    let home = continuationHome("uncertain")
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: home.workHostID, workID: "writer-continuation-uncertain")
    let url = home.timelineV2WorkJournalURL(work)
    let journal = JournalRef.work(work, journalID: "work")
    let writer = try TimelineJournalWriter.createFresh(
        at: url, journal: journal, actor: TimelineActor(actorID: "continuation", kind: "test"),
        home: home)
    _ = try await writer.append(continuationDraft(TimelineEventType.workCreated, work: work))
    await writer.injectFailure(.afterWriteBeforeSync)

    do {
        _ = try await writer.append(continuationDraft(TimelineEventType.workFailed, work: work))
        XCTFail("an uncertain write must fail closed")
    } catch {
        XCTAssertTrue(true)
    }
    XCTAssertTrue(await writer.canonicalContinuationInvalidationCount > 0)
    let health = await writer.health
    if case .failed = health {
        XCTAssertTrue(true)
    } else {
        XCTFail("an uncertain append must leave the writer failed")
    }
    do {
        try await writer.closeChecked()
    } catch {
        XCTAssertTrue(true)
    }
}

func testTimelineJournalWriterContinuationRejectsExternalAppendWithoutWriterWrite() async throws {
    let home = continuationHome("external-append")
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: home.workHostID, workID: "writer-continuation-external-append")
    let url = home.timelineV2WorkJournalURL(work)
    let journal = JournalRef.work(work, journalID: "work")
    let writer = try TimelineJournalWriter.createFresh(
        at: url, journal: journal, actor: TimelineActor(actorID: "continuation", kind: "test"),
        home: home)
    _ = try await writer.append(continuationDraft(TimelineEventType.workCreated, work: work))

    let foreign = try FileHandle(forWritingTo: url)
    try foreign.seekToEnd()
    try foreign.write(contentsOf: Data("foreign\n".utf8))
    try foreign.close()
    let externallyChangedPrefix = try Data(contentsOf: url)

    do {
        _ = try await writer.append(continuationDraft(TimelineEventType.workFailed, work: work))
        XCTFail("an external append must fail closed before the writer appends")
    } catch {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(try Data(contentsOf: url), externallyChangedPrefix,
                   "the failed writer call must not add bytes after an external append")
    if case .failed = await writer.health {
        XCTAssertTrue(true)
    } else {
        XCTFail("external source mutation must fail the writer")
    }
    try? await writer.closeChecked()
}

func testTimelineJournalWriterContinuationRejectsReplacementWithoutReseeding() async throws {
    let home = continuationHome("replacement")
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: home.workHostID, workID: "writer-continuation-replacement")
    let url = home.timelineV2WorkJournalURL(work)
    let journal = JournalRef.work(work, journalID: "work")
    let writer = try TimelineJournalWriter.createFresh(
        at: url, journal: journal, actor: TimelineActor(actorID: "continuation", kind: "test"),
        home: home)
    _ = try await writer.append(continuationDraft(TimelineEventType.workCreated, work: work))
    let durablePrefix = try Data(contentsOf: url)
    let moved = url.deletingLastPathComponent().appendingPathComponent("moved-prefix")
    try FileManager.default.moveItem(at: url, to: moved)
    try durablePrefix.write(to: url, options: [.withoutOverwriting])
    let replacementPrefix = try Data(contentsOf: url)

    do {
        _ = try await writer.append(continuationDraft(TimelineEventType.workFailed, work: work))
        XCTFail("a replaced source must fail closed before reseeding or appending")
    } catch {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(try Data(contentsOf: url), replacementPrefix,
                   "replacement bytes must remain untouched after source rejection")
    XCTAssertEqual(await writer.canonicalContinuationSeedCount, 1,
                   "source replacement must not reseed from a different path")
    if case .failed = await writer.health {
        XCTAssertTrue(true)
    } else {
        XCTFail("source replacement must fail the writer")
    }
    try? await writer.closeChecked()
}

let casesTimelineJournalWriterContinuation: [(String, () async throws -> Void)] = [
    ("phase5 writer continuation: one canonical seed and incremental commits", {
        try await testTimelineJournalWriterContinuationSeedsOnceAndAdvancesAfterCommit()
    }),
    ("phase5 writer continuation: uncertain write invalidates cached state", {
        try await testTimelineJournalWriterContinuationInvalidatesAfterUncertainWrite()
    }),
    ("phase5 writer continuation: external append is rejected before writer write", {
        try await testTimelineJournalWriterContinuationRejectsExternalAppendWithoutWriterWrite()
    }),
    ("phase5 writer continuation: replacement is rejected without reseeding", {
        try await testTimelineJournalWriterContinuationRejectsReplacementWithoutReseeding()
    }),
]
