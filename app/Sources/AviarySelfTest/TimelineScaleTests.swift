import Foundation
@testable import AviaryCore

private let scaleWork = WorkRef(workHostID: "scale-host", workID: "scale-work")
private let scaleJournal = JournalRef.work(scaleWork, journalID: "scale-journal")

private func scaleEvent(
    id: String,
    sequence: Int,
    previous: String?,
    type: String = TimelineEventType.hostOrderObserved,
    work: WorkRef? = nil
) -> TimelineEvent {
    TimelineEvent(
        eventID: id, journal: scaleJournal, sequence: sequence,
        previousEventID: previous, work: work,
        actor: TimelineActor(actorID: "scale", kind: "benchmark"),
        hostRecordedAt: Date(timeIntervalSince1970: Double(sequence)),
        type: type, declaredDomains: [.work], payload: .object([:]))
}

private func makeScaleData(eventCount: Int) throws -> Data {
    var data = Data()
    data.reserveCapacity(eventCount * 500)
    let encoder = JSONEncoder()
    var previous: String?
    for sequence in 1...eventCount {
        let id = "scale-\(sequence)"
        let event = scaleEvent(
            id: id, sequence: sequence, previous: previous,
            type: sequence == 1 ? TimelineEventType.workCreated : TimelineEventType.hostOrderObserved,
            work: sequence == 1 ? scaleWork : nil)
        data.append(try encoder.encode(event))
        data.append(0x0A)
        previous = id
    }
    return data
}

private func scaleLines(_ data: Data) -> [Data] {
    data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
}

private func joinScaleLines(_ lines: [Data]) -> Data {
    var data = Data()
    for line in lines {
        data.append(line)
        data.append(0x0A)
    }
    return data
}

private enum ScaleMutation: CaseIterable {
    case unknown
    case duplicate
    case reordered
    case malformed
    case truncated
}

private func mutateScale(_ data: Data, as mutation: ScaleMutation) -> Data {
    var lines = scaleLines(data)
    switch mutation {
    case .unknown:
        let text = String(decoding: lines[4], as: UTF8.self)
            .replacingOccurrences(of: "\"host.order_observed\"", with: "\"future.scale_event\"")
        lines[4] = Data(text.utf8)
        return joinScaleLines(lines)
    case .duplicate:
        lines.insert(lines[3], at: 4)
        return joinScaleLines(lines)
    case .reordered:
        lines.swapAt(3, 4)
        return joinScaleLines(lines)
    case .malformed:
        lines.insert(Data("{not-json}\n".utf8), at: 4)
        return joinScaleLines(lines)
    case .truncated:
        return Data(data.dropLast())
    }
}

private func scaleChunkSchedule(seed: Int) -> [Int] {
    (0..<17).map { ((seed * 37 + $0 * 19) % 41) + 1 }
}

/// Fresh local baseline budget for this verification slice (2026-08-31, Apple Swift 6):
/// 100k records, <=128 MiB encoded input, <=30 seconds read+reduce. The encoded byte count is
/// a deterministic retained-input proxy for working-set pressure; it is not a peak-RSS claim.
func test_timelineV2HundredThousandBaseline() throws {
    let eventCount = 100_000
    let generationStart = DispatchTime.now().uptimeNanoseconds
    let data = try makeScaleData(eventCount: eventCount)
    let generationSeconds = Double(DispatchTime.now().uptimeNanoseconds - generationStart) / 1e9

    let readStart = DispatchTime.now().uptimeNanoseconds
    let result = TimelineJournalReader.read(
        data, journal: scaleJournal,
        actor: TimelineActor(actorID: "scale-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    let snapshot = WorkReducer.reduce(result.records.map(\.event))
    let readReduceSeconds = Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1e9

    XCTAssertEqual(result.records.count, eventCount)
    XCTAssertEqual(snapshot.lastSequence, eventCount)
    XCTAssertEqual(snapshot.lastEventID, "scale-\(eventCount)")
    XCTAssertNil(result.quarantinedSuffix)
    XCTAssertNil(result.truncatedTail)
    XCTAssertTrue(data.count <= 128 * 1024 * 1024,
                  "encoded input exceeded the versioned working-set proxy budget")
    XCTAssertTrue(data.count >= 12 * 1024 * 1024,
                  "encoded input did not exercise the intended large-journal path")
    XCTAssertTrue(readReduceSeconds <= 30,
                  "read+reduce exceeded the versioned local baseline budget")
    print(String(format:
        "timeline-v2-baseline version=1 events=%d bytes=%d generation=%.3fs read_reduce=%.3fs",
        eventCount, data.count, generationSeconds, readReduceSeconds))
}

func test_timelineV2IncrementalAdversarialEquivalence() throws {
    let base = try makeScaleData(eventCount: 12)
    for mutation in ScaleMutation.allCases {
        let data = mutateScale(base, as: mutation)
        let whole = TimelineJournalReader.read(
            data, journal: scaleJournal,
            actor: TimelineActor(actorID: "scale-reader", kind: "self-test"),
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        for seed in 1...8 {
            let incremental = ReaderCensus.readIncrementally(
                data, journal: scaleJournal, chunkSizes: scaleChunkSchedule(seed: seed))
            XCTAssertEqual(
                incremental.records.map { $0.event.eventID },
                whole.records.map { $0.event.eventID },
                "mutation \(mutation) seed \(seed) committed IDs diverged")
            XCTAssertEqual(
                incremental.records.map { $0.event.sequence },
                whole.records.map { $0.event.sequence },
                "mutation \(mutation) seed \(seed) committed sequences diverged")
            XCTAssertEqual(incremental.truncatedTail?.rawBytes.count, whole.truncatedTail?.rawBytes.count,
                           "mutation \(mutation) seed \(seed) truncated tail diverged")
            XCTAssertEqual(incremental.quarantinedSuffix?.rawBytes.count,
                           whole.quarantinedSuffix?.rawBytes.count,
                           "mutation \(mutation) seed \(seed) quarantined suffix diverged")
            XCTAssertEqual(
                WorkReducer.reduce(incremental.records.map { $0.event }),
                WorkReducer.reduce(whole.records.map { $0.event }),
                "mutation \(mutation) seed \(seed) reducer snapshots diverged")
        }

        // Keep each mutation non-vacuous: equivalence alone can pass if both readers silently
        // discard the same damaged suffix.
        switch mutation {
        case .unknown:
            let snapshot = WorkReducer.reduce(whole.records.map(\.event))
            XCTAssertEqual(snapshot.unknownEvents.count, 1)
            XCTAssertEqual(snapshot.unknownEvents[0].event.eventID, "scale-5")
            XCTAssertTrue(snapshot.unknownDomains.contains(.work))
            let census = ReaderCensus.report(
                sessionData: Data(),
                sessionJournal: JournalRef.session(
                    SessionRef("scale-session"), journalID: "scale-session",
                    authority: TimelineAuthorityRef("scale-authority")),
                workData: data, workJournal: scaleJournal)
            XCTAssertTrue(census.unknownEventRefs.contains(
                EventRef(journal: scaleJournal, eventID: "scale-5")))
        case .duplicate, .reordered:
            XCTAssertNotNil(whole.quarantinedSuffix)
            let decoded = scaleLines(data).compactMap {
                try? JSONDecoder().decode(TimelineEvent.self, from: $0)
            }
            let snapshot = WorkReducer.reduce(decoded)
            XCTAssertFalse(snapshot.structuralIntegrityValid,
                           "mutation \(mutation) must reach the reducer as structural corruption")
        case .malformed:
            XCTAssertEqual(whole.records.count, 4)
            XCTAssertTrue(whole.quarantinedSuffix?.rawBytes.starts(with: Data("{not-json}".utf8)) == true)
        case .truncated:
            XCTAssertEqual(whole.records.count, 11)
            XCTAssertNotNil(whole.truncatedTail)
            XCTAssertFalse(whole.records.contains { $0.event.eventID == "scale-12" })
        }
    }
}
