import Foundation

/// In-memory scheduling policy owned by one Work Host coordinator. This is not a durable
/// Handle registry: the coordinator records admission before committing a reservation, and
/// retains canonical terminal results after releasing their queue slots.
public struct WorkAgentChildAdmissionQueue: Sendable {
    public struct Limits: Hashable, Sendable {
        public let executing: Int
        public let queued: Int
        public let queuedPerWork: Int

        public init(executing: Int = 2, queued: Int = 32, queuedPerWork: Int = 8) throws {
            guard (1...2).contains(executing), (1...32).contains(queued),
                  (1...8).contains(queuedPerWork), queuedPerWork <= queued else {
                throw Failure.invalidLimits
            }
            self.executing = executing
            self.queued = queued
            self.queuedPerWork = queuedPerWork
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidLimits, invalidIdentity, invalidDeadline, capacity, duplicate
        case staleReservation, invalidTransition
    }

    public struct Reservation: Hashable, Sendable {
        public let work: WorkRef
        public let handle: HandleRef
        fileprivate let token: UUID
    }

    /// Execute only after the queued event is durable; expiry/cancellation settlement must
    /// durably record a terminal outcome without starting a provider or Python process.
    public enum Decision: Equatable, Sendable {
        case execute(Reservation)
        case expireBeforeExecution(Reservation)
    }

    public struct Counts: Equatable, Sendable {
        public let admitting: Int
        public let queued: Int
        public let executing: Int
        public let settlingWithoutExecution: Int
    }

    private enum State: Sendable { case admitting, queued, executing, settling }
    private struct Entry: Sendable {
        let reservation: Reservation
        let deadline: Date?
        var state: State
        var awaited: Bool
    }

    public let limits: Limits
    private var entries: [Entry] = []
    private var workOrder: [WorkRef] = []
    /// One promotion is allowed ahead of the oldest non-awaited child. A normal FIFO
    /// selection or selection of that non-awaited child restores the promotion allowance.
    private var promotionUsed: Set<WorkRef> = []

    public init(limits: Limits) { self.limits = limits }

    public var counts: Counts {
        Counts(admitting: entries.filter { $0.state == .admitting }.count,
               queued: entries.filter { $0.state == .queued }.count,
               executing: entries.filter { $0.state == .executing }.count,
               settlingWithoutExecution: entries.filter { $0.state == .settling }.count)
    }

    /// Counts the reservation before a durable admission await can reenter the coordinator.
    /// A caller must either commit it after persistence or abandon it after a proven failure.
    /// An uncertain append must keep its reservation until canonical reconciliation.
    public mutating func reserve(
        work: WorkRef, handle: HandleRef, deadline: Date? = nil, now: Date = Date()
    ) throws -> Reservation {
        guard Self.validID(work.workHostID), Self.validID(work.workID),
              Self.validID(handle.handleID) else { throw Failure.invalidIdentity }
        if let deadline {
            guard deadline.timeIntervalSince1970.isFinite,
                  now.timeIntervalSince1970.isFinite, deadline > now else {
                throw Failure.invalidDeadline
            }
        }
        guard !entries.contains(where: {
            $0.reservation.work == work && $0.reservation.handle == handle
        }) else { throw Failure.duplicate }
        let waiting = entries.filter { $0.state != .executing }
        guard waiting.count < limits.queued,
              waiting.filter({ $0.reservation.work == work }).count < limits.queuedPerWork else {
            throw Failure.capacity
        }
        let reservation = Reservation(work: work, handle: handle, token: UUID())
        entries.append(Entry(reservation: reservation, deadline: deadline,
                             state: .admitting, awaited: false))
        if !workOrder.contains(work) { workOrder.append(work) }
        return reservation
    }

    public mutating func commit(_ reservation: Reservation) throws {
        let index = try index(for: reservation)
        guard entries[index].state == .admitting else { throw Failure.invalidTransition }
        entries[index].state = .queued
    }

    public mutating func abandonUncommitted(_ reservation: Reservation) throws {
        let index = try index(for: reservation)
        guard entries[index].state == .admitting else { throw Failure.invalidTransition }
        remove(at: index)
    }

    public mutating func setAwaitInterest(_ reservation: Reservation, awaited: Bool) throws {
        let index = try index(for: reservation)
        guard entries[index].state == .queued || entries[index].state == .admitting else {
            throw Failure.invalidTransition
        }
        entries[index].awaited = awaited
    }

    /// Expiry does not consume execution capacity, but holds its admission slot until the
    /// coordinator proves terminal persistence. Running expiry is owned by the coordinator:
    /// it requests resource cancellation and keeps the execution slot until quiescent.
    public mutating func next(now: Date) throws -> Decision? {
        guard now.timeIntervalSince1970.isFinite else { throw Failure.invalidDeadline }
        if let expired = entries.firstIndex(where: {
            $0.state == .queued && $0.deadline.map { $0 <= now } == true
        }) {
            entries[expired].state = .settling
            return .expireBeforeExecution(entries[expired].reservation)
        }
        guard counts.executing < limits.executing else { return nil }
        for work in workOrder {
            guard !entries.contains(where: {
                $0.reservation.work == work && $0.state == .executing
            }) else { continue }
            let candidates = entries.indices.filter {
                entries[$0].reservation.work == work && entries[$0].state == .queued
            }
            guard let oldest = candidates.first else { continue }
            let nonAwaited = candidates.first { !entries[$0].awaited }
            let awaited = candidates.first { entries[$0].awaited }
            let chosen: Int
            if promotionUsed.contains(work), let nonAwaited {
                chosen = nonAwaited
                promotionUsed.remove(work)
            } else if let awaited, awaited != oldest, let nonAwaited, nonAwaited < awaited {
                chosen = awaited
                promotionUsed.insert(work)
            } else {
                chosen = oldest
                promotionUsed.remove(work)
            }
            entries[chosen].state = .executing
            workOrder.removeAll { $0 == work }
            workOrder.append(work)
            return .execute(entries[chosen].reservation)
        }
        return nil
    }

    /// Called only after durable cancellation admission. It prevents provider dispatch but
    /// does not release capacity before the canceled terminal record has been committed.
    public mutating func cancelQueued(_ reservation: Reservation) throws {
        let index = try index(for: reservation)
        guard entries[index].state == .queued else { throw Failure.invalidTransition }
        entries[index].state = .settling
    }

    /// Release only after actual execution cleanup and terminal recording, or after a queued
    /// expiry/cancellation terminal record. A cancellation request alone is not completion.
    public mutating func finish(_ reservation: Reservation) throws {
        let index = try index(for: reservation)
        guard entries[index].state == .executing || entries[index].state == .settling else {
            throw Failure.invalidTransition
        }
        remove(at: index)
    }

    private func index(for reservation: Reservation) throws -> Int {
        guard let index = entries.firstIndex(where: { $0.reservation == reservation }) else {
            throw Failure.staleReservation
        }
        return index
    }

    private mutating func remove(at index: Int) {
        let work = entries.remove(at: index).reservation.work
        if !entries.contains(where: { $0.reservation.work == work }) {
            workOrder.removeAll { $0 == work }
            promotionUsed.remove(work)
        }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
