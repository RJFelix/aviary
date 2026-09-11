import AviaryCore
import Foundation

private let childQueueNow = Date(timeIntervalSince1970: 1_000)
private func childQueueWork(_ id: String) -> WorkRef {
    WorkRef(workHostID: "queue-host", workID: id)
}

private func childQueueAdd(
    _ queue: inout WorkAgentChildAdmissionQueue, _ work: String, _ handle: String,
    deadline: Date = childQueueNow.addingTimeInterval(60)
) throws -> WorkAgentChildAdmissionQueue.Reservation {
    let reservation = try queue.reserve(work: childQueueWork(work), handle: HandleRef(handle),
                                        deadline: deadline, now: childQueueNow)
    try queue.commit(reservation)
    return reservation
}

private func childQueueExpectFailure(
    _ expected: WorkAgentChildAdmissionQueue.Failure, _ action: () throws -> Void
) {
    do {
        try action()
        XCTAssertTrue(false, "queue mutation should refuse")
    } catch let failure as WorkAgentChildAdmissionQueue.Failure {
        XCTAssertEqual(failure, expected)
    } catch {
        XCTAssertTrue(false, "queue returned an unexpected error type")
    }
}

func testWorkAgentChildQueueReservationsAreBounded() throws {
    var queue = WorkAgentChildAdmissionQueue(limits: try .init(queued: 2, queuedPerWork: 1))
    let pending = try queue.reserve(work: childQueueWork("a"), handle: HandleRef("pending"),
                                    deadline: childQueueNow.addingTimeInterval(2), now: childQueueNow)
    XCTAssertNil(try queue.next(now: childQueueNow), "uncommitted admission cannot execute")
    childQueueExpectFailure(.capacity) { _ = try childQueueAdd(&queue, "a", "second") }
    _ = try childQueueAdd(&queue, "b", "b")
    childQueueExpectFailure(.capacity) { _ = try childQueueAdd(&queue, "c", "c") }
    XCTAssertEqual(queue.counts.admitting, 1)
    try queue.abandonUncommitted(pending)
    childQueueExpectFailure(.staleReservation) { try queue.commit(pending) }
    let new = try childQueueAdd(&queue, "a", "pending")
    childQueueExpectFailure(.staleReservation) { try queue.abandonUncommitted(pending) }
    childQueueExpectFailure(.invalidTransition) { try queue.abandonUncommitted(new) }
    childQueueExpectFailure(.duplicate) { _ = try childQueueAdd(&queue, "a", "pending") }
    XCTAssertEqual(queue.counts.queued, 2)
}

func testWorkAgentChildQueueRoundRobinAndAwaitFairness() throws {
    var queue = WorkAgentChildAdmissionQueue(limits: try .init(executing: 1))
    let a1 = try childQueueAdd(&queue, "a", "a1")
    let a2 = try childQueueAdd(&queue, "a", "a2")
    let a3 = try childQueueAdd(&queue, "a", "a3")
    let b1 = try childQueueAdd(&queue, "b", "b1")
    let b2 = try childQueueAdd(&queue, "b", "b2")
    try queue.setAwaitInterest(a2, awaited: true)
    try queue.setAwaitInterest(a3, awaited: true)
    XCTAssertEqual(try queue.next(now: childQueueNow), .execute(a2))
    XCTAssertNil(try queue.next(now: childQueueNow), "await interest cannot overbook capacity")
    try queue.finish(a2)
    XCTAssertEqual(try queue.next(now: childQueueNow), .execute(b1), "rotate across Works")
    try queue.finish(b1)
    XCTAssertEqual(try queue.next(now: childQueueNow), .execute(a1),
                   "second awaited child cannot starve the skipped oldest child")
    try queue.finish(a1)
    XCTAssertEqual(try queue.next(now: childQueueNow), .execute(b2))
    try queue.finish(b2)
    XCTAssertEqual(try queue.next(now: childQueueNow), .execute(a3))
    try queue.finish(a3)
    XCTAssertNil(try queue.next(now: childQueueNow))
    XCTAssertEqual(queue.counts.executing, 0)
}

func testWorkAgentChildQueueOneExecutingChildPerWork() throws {
    var queue = WorkAgentChildAdmissionQueue(limits: try .init())
    let a1 = try childQueueAdd(&queue, "a", "a1")
    let a2 = try childQueueAdd(&queue, "a", "a2")
    let b1 = try childQueueAdd(&queue, "b", "b1")
    XCTAssertEqual(try queue.next(now: childQueueNow), .execute(a1))
    XCTAssertEqual(try queue.next(now: childQueueNow), .execute(b1))
    try queue.finish(b1)
    XCTAssertNil(try queue.next(now: childQueueNow), "a second slot cannot run another A child")
    childQueueExpectFailure(.invalidTransition) { try queue.cancelQueued(a1) }
    XCTAssertEqual(queue.counts.executing, 1, "running cancellation does not free execution")
    try queue.finish(a1)
    XCTAssertEqual(try queue.next(now: childQueueNow), .execute(a2))
    try queue.finish(a2)
}

func testWorkAgentChildQueueExpiryAndCancellationHoldCapacity() throws {
    var queue = WorkAgentChildAdmissionQueue(limits: try .init(queued: 2, queuedPerWork: 2))
    let a = try childQueueAdd(&queue, "a", "expired",
                              deadline: childQueueNow.addingTimeInterval(1))
    let b = try childQueueAdd(&queue, "a", "canceled")
    let after = childQueueNow.addingTimeInterval(2)
    XCTAssertEqual(try queue.next(now: after), .expireBeforeExecution(a))
    try queue.cancelQueued(b)
    XCTAssertEqual(queue.counts.settlingWithoutExecution, 2)
    XCTAssertEqual(queue.counts.executing, 0)
    XCTAssertNil(try queue.next(now: after), "settling children cannot execute")
    childQueueExpectFailure(.capacity) { _ = try childQueueAdd(&queue, "b", "new") }
    try queue.finish(a)
    _ = try childQueueAdd(&queue, "b", "new")
    childQueueExpectFailure(.staleReservation) { try queue.finish(a) }
    try queue.finish(b)
    XCTAssertEqual(queue.counts.settlingWithoutExecution, 0)
    let pending = try queue.reserve(work: childQueueWork("c"), handle: HandleRef("slow-admit"),
                                    deadline: childQueueNow.addingTimeInterval(1), now: childQueueNow)
    try queue.commit(pending)
    XCTAssertEqual(try queue.next(now: after), .expireBeforeExecution(pending),
                   "time spent persisting admission consumes the same deadline")
}

func testWorkAgentChildQueueRejectsInvalidInputs() throws {
    childQueueExpectFailure(.invalidLimits) { _ = try WorkAgentChildAdmissionQueue.Limits(executing: 3) }
    childQueueExpectFailure(.invalidLimits) { _ = try WorkAgentChildAdmissionQueue.Limits(queued: 1) }
    var queue = WorkAgentChildAdmissionQueue(limits: try .init())
    childQueueExpectFailure(.invalidDeadline) {
        _ = try childQueueAdd(&queue, "a", "past", deadline: childQueueNow)
    }
    childQueueExpectFailure(.invalidDeadline) {
        _ = try childQueueAdd(&queue, "a", "infinite", deadline: Date(timeIntervalSince1970: .infinity))
    }
    childQueueExpectFailure(.invalidIdentity) { _ = try childQueueAdd(&queue, "a", "bad\nidentity") }
    childQueueExpectFailure(.invalidIdentity) { _ = try childQueueAdd(&queue, "", "empty-work") }
    XCTAssertEqual(queue.counts.queued, 0)
}

let casesWorkAgentChildAdmissionQueue: [Case] = [
    ("phase5 child queue: bounded durable reservations", testWorkAgentChildQueueReservationsAreBounded),
    ("phase5 child queue: round robin and bounded await promotion", testWorkAgentChildQueueRoundRobinAndAwaitFairness),
    ("phase5 child queue: one executing child per Work", testWorkAgentChildQueueOneExecutingChildPerWork),
    ("phase5 child queue: expiry and cancellation retain capacity", testWorkAgentChildQueueExpiryAndCancellationHoldCapacity),
    ("phase5 child queue: rejects invalid inputs", testWorkAgentChildQueueRejectsInvalidInputs),
]
