import Foundation

/// Work a session does on its own: a job at an interval, or a heartbeat that pokes it when idle.
///
/// Stored per session, in the session's own artifacts directory, so a schedule cannot outlive
/// the thing it schedules — the harness's cron jobs keyed on a stable *attachment* id instead,
/// which is why forking a session silently stole its parent's schedule.
///
/// Deliberately interval-based rather than cron-expression-based. Every real use in the corpus
/// was "every N minutes"; a cron parser is a weekend and a class of bugs bought for a case
/// nobody had.
public struct ScheduledJob: Sendable, Hashable, Identifiable {
    public var id: String
    /// What to send.
    public var prompt: String
    public var everySeconds: TimeInterval
    /// A heartbeat only fires when the session is idle; a job fires regardless.
    public var onlyWhenIdle: Bool
    public var enabled: Bool
    public var createdAt: Date
    public var lastRunAt: Date?
    public var runCount: Int

    public init(
        id: String = "job-" + UUID().uuidString.prefix(8).lowercased(),
        prompt: String, everySeconds: TimeInterval, onlyWhenIdle: Bool = false,
        enabled: Bool = true, createdAt: Date = Date(), lastRunAt: Date? = nil, runCount: Int = 0
    ) {
        self.id = id
        self.prompt = prompt
        self.everySeconds = everySeconds
        self.onlyWhenIdle = onlyWhenIdle
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.runCount = runCount
    }

    public func isDue(now: Date = Date()) -> Bool {
        guard enabled else { return false }
        let last = lastRunAt ?? createdAt
        return now.timeIntervalSince(last) >= everySeconds
    }

    public var summary: String {
        let cadence = everySeconds < 3600
            ? "every \(Int(everySeconds / 60))m"
            : "every \(Int(everySeconds / 3600))h"
        return "\(cadence)\(onlyWhenIdle ? ", when idle" : "") · ran \(runCount)×"
    }
}

/// Reads and writes a session's schedules.
///
/// Whole-file rewrites rather than an append log, unlike the memory and workshop stores. The
/// difference is that this has exactly one writer — the app — and its records are *mutable
/// state* (a last-run timestamp) rather than a history worth keeping. An append log for a
/// counter that changes every tick would grow without bound and answer no question.
public struct ScheduleStore: Sendable {
    public let home: AgentHome
    public let sessionID: String

    public init(home: AgentHome, sessionID: String) {
        self.home = home
        self.sessionID = sessionID
    }

    public var fileURL: URL {
        home.scheduledJobs(forSession: sessionID)
    }

    public func load() -> [ScheduledJob] {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let root = JSONValue.parse(data)
        else { return [] }
        return (root["jobs"]?.arrayValue ?? []).compactMap { entry in
            guard let id = entry["id"]?.stringValue,
                  let prompt = entry["prompt"]?.stringValue,
                  let interval = entry["everySeconds"]?.doubleValue
            else { return nil }
            return ScheduledJob(
                id: id, prompt: prompt, everySeconds: interval,
                onlyWhenIdle: entry["onlyWhenIdle"]?.boolValue ?? false,
                enabled: entry["enabled"]?.boolValue ?? true,
                createdAt: WorkshopLog.parseDate(entry["createdAt"]?.stringValue) ?? Date(),
                lastRunAt: WorkshopLog.parseDate(entry["lastRunAt"]?.stringValue),
                runCount: entry["runCount"]?.intValue ?? 0)
        }
    }

    public func save(_ jobs: [ScheduledJob]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = JSONValue.object(["jobs": .array(jobs.map { job in
            var obj: [String: JSONValue] = [
                "id": .string(job.id),
                "prompt": .string(job.prompt),
                "everySeconds": .number(job.everySeconds),
                "onlyWhenIdle": .bool(job.onlyWhenIdle),
                "enabled": .bool(job.enabled),
                "createdAt": .string(SessionWriter.stamp(job.createdAt)),
                "runCount": .number(Double(job.runCount)),
            ]
            if let last = job.lastRunAt { obj["lastRunAt"] = .string(SessionWriter.stamp(last)) }
            return .object(obj)
        })])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .prettyPrinted, .sortedKeys]
        // Atomic, because a tick that lands during a write must not truncate the file.
        try encoder.encode(payload).write(to: fileURL, options: .atomic)
    }

    @discardableResult
    public func add(_ job: ScheduledJob) throws -> [ScheduledJob] {
        var jobs = load()
        jobs.append(job)
        try save(jobs)
        return jobs
    }

    public func remove(id: String) throws {
        try save(load().filter { $0.id != id })
    }

    /// Record that a job fired. Separate from `save` so a caller cannot forget the counter and
    /// leave a job that fires forever because its last-run never advanced.
    public func markRun(id: String, at date: Date = Date()) throws {
        var jobs = load()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].lastRunAt = date
        jobs[index].runCount += 1
        try save(jobs)
    }
}
