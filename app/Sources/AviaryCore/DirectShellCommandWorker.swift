import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc

// Glibc exports this extension (since 2.29), but Swift's Glibc module does not declare it.
// Binding the existing symbol preserves posix_spawn's atomic working-directory setup and its
// launch-error semantics instead of routing the admitted source through a second wrapper shell.
@_silgen_name("posix_spawn_file_actions_addchdir_np")
private func aviary_posixSpawnFileActionsAddChdir(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t>,
    _ path: UnsafePointer<CChar>
) -> Int32
#endif

/// The only shells a direct command may select.  The executable is deliberately fixed;
/// callers cannot turn this value into an arbitrary executable path.
public enum DirectShellLanguage: String, Codable, Equatable, Hashable, Sendable {
    case sh
    case bash
    case zsh

    public init?(wireValue: String) {
        switch wireValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sh", "shell": self = .sh
        case "bash": self = .bash
        case "zsh": self = .zsh
        default: return nil
        }
    }

    fileprivate var executable: String {
        switch self {
        case .sh: return "/bin/sh"
        case .bash: return "/bin/bash"
        case .zsh: return "/bin/zsh"
        }
    }
}

/// Host-owned input to a direct shell worker.  This is intentionally independent of the
/// Work-service DTOs: admission and journal identity are owned by the service, while this
/// value describes only the OS process to run after a durable start permit.
public struct DirectShellCommandRequest: Codable, Equatable, Sendable {
    public static let maximumSourceBytes = 16 * 1024
    public static let maximumIdentityBytes = 256
    public static let maximumEnvironmentEntries = 1_024
    public static let maximumEnvironmentBytes = 512 * 1_024

    public let commandID: String
    public let actionID: String
    public let language: DirectShellLanguage
    public let source: Data
    public let workingDirectory: URL
    public let environment: [String: String]
    public let timeout: TimeInterval?

    public init(
        commandID: String,
        actionID: String,
        language: DirectShellLanguage,
        source: Data,
        workingDirectory: URL,
        environment: [String: String] = ProcessEnvironment.shared.snapshot,
        timeout: TimeInterval? = nil
    ) {
        self.commandID = commandID
        self.actionID = actionID
        self.language = language
        self.source = source
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case invalidIdentity
        case invalidSource
        case invalidWorkingDirectory
        case invalidEnvironment
        case invalidTimeout

        public var description: String {
            switch self {
            case .invalidIdentity: return "command identity is invalid"
            case .invalidSource: return "command source is invalid"
            case .invalidWorkingDirectory: return "working directory is invalid"
            case .invalidEnvironment: return "command environment is invalid"
            case .invalidTimeout: return "timeout must be finite and positive"
            }
        }
    }

    /// Validate the exact process input. Invalid environment entries are rejected rather than
    /// silently removed: the executed environment must be the environment the host admitted.
    public func validate() throws {
        guard Self.validIdentity(commandID), Self.validIdentity(actionID) else {
            throw ValidationError.invalidIdentity
        }
        guard !source.isEmpty, source.count <= Self.maximumSourceBytes,
              !source.contains(0), String(data: source, encoding: .utf8) != nil else {
            throw ValidationError.invalidSource
        }
        let path = workingDirectory.path
        guard workingDirectory.isFileURL, path.hasPrefix("/"), !path.contains("\0"),
              !path.isEmpty, path.utf8.count <= 4_096 else {
            throw ValidationError.invalidWorkingDirectory
        }
        guard environment.count <= Self.maximumEnvironmentEntries else {
            throw ValidationError.invalidEnvironment
        }
        var environmentBytes = 0
        for (key, value) in environment {
            guard !key.isEmpty, !key.contains("="), !key.contains("\0"),
                  !value.contains("\0") else {
                throw ValidationError.invalidEnvironment
            }
            let (entryBytes, entryOverflow) = key.utf8.count.addingReportingOverflow(value.utf8.count)
            let (encodedBytes, encodedOverflow) = entryBytes.addingReportingOverflow(2)
            let (nextBytes, aggregateOverflow) = environmentBytes.addingReportingOverflow(encodedBytes)
            guard !entryOverflow, !encodedOverflow, !aggregateOverflow,
                  nextBytes <= Self.maximumEnvironmentBytes else {
                throw ValidationError.invalidEnvironment
            }
            environmentBytes = nextBytes
        }
        if let timeout, (!timeout.isFinite || timeout <= 0) {
            throw ValidationError.invalidTimeout
        }
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumIdentityBytes
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    public init(
        commandID: String,
        actionID: String,
        language: DirectShellLanguage,
        source: String,
        workingDirectory: URL,
        environment: [String: String] = ProcessEnvironment.shared.snapshot,
        timeout: TimeInterval? = nil
    ) {
        self.init(
            commandID: commandID, actionID: actionID, language: language,
            source: Data(source.utf8), workingDirectory: workingDirectory,
            environment: environment, timeout: timeout)
    }
}

public struct DirectShellOutputCapture: Codable, Equatable, Sendable {
    public let head: Data
    public let tail: Data
    public let totalByteCount: Int64
    public let omittedByteCount: Int64
    public let isTruncated: Bool
    /// False means a pipe read failed or the bounded post-exit drain was abandoned. Retained
    /// bytes and counts remain truthful for bytes actually observed, but are not the whole stream.
    public let isComplete: Bool

    public var retainedByteCount: Int { head.count + tail.count }

    fileprivate init(head: Data, tail: Data, totalByteCount: Int64, isComplete: Bool = true) {
        self.head = head
        self.tail = tail
        self.totalByteCount = totalByteCount
        self.omittedByteCount = max(0, totalByteCount - Int64(head.count + tail.count))
        self.isTruncated = self.omittedByteCount > 0
        self.isComplete = isComplete
    }
}

public enum DirectShellCommandTerminalStatus: Codable, Equatable, Sendable {
    case exited(exitCode: Int32)
    case nonzero(exitCode: Int32)
    case signaled(signal: Int32)
    case canceled
    case timedOut
    case invalidRequest(message: String)
    case launchFailed(message: String)
    case workerFailed(message: String)
}

public struct DirectShellCommandResult: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let commandID: String
    public let actionID: String
    public let language: DirectShellLanguage
    public let source: Data
    public let status: DirectShellCommandTerminalStatus
    public let stdout: DirectShellOutputCapture
    public let stderr: DirectShellOutputCapture
    public let startedAt: Date
    public let endedAt: Date

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var outputComplete: Bool { stdout.isComplete && stderr.isComplete }

    public enum ValidationError: Error, Equatable {
        case invalidSchema
        case invalidIdentity
        case invalidSource
        case invalidDates
        case invalidCapture
    }

    /// Validate a decoded result before treating its bounded bytes as an artifact.
    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else { throw ValidationError.invalidSchema }
        guard !commandID.isEmpty, commandID.utf8.count <= 256,
              !actionID.isEmpty, actionID.utf8.count <= 256 else {
            throw ValidationError.invalidIdentity
        }
        guard !source.isEmpty, source.count <= DirectShellCommandRequest.maximumSourceBytes,
              !source.contains(0), String(data: source, encoding: .utf8) != nil else {
            throw ValidationError.invalidSource
        }
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
              endedAt.timeIntervalSinceReferenceDate.isFinite,
              endedAt >= startedAt else {
            throw ValidationError.invalidDates
        }
        try Self.validateCapture(stdout)
        try Self.validateCapture(stderr)
        switch status {
        case .exited(let code):
            guard code == 0 else { throw ValidationError.invalidCapture }
        case .nonzero(let code):
            guard code != 0 else { throw ValidationError.invalidCapture }
        case .signaled(let signal):
            guard signal > 0 else { throw ValidationError.invalidCapture }
        case .invalidRequest(let message), .launchFailed(let message), .workerFailed(let message):
            guard !message.isEmpty, message.utf8.count <= 256,
                  message.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0) || $0 == "\t"
                  }) else {
                throw ValidationError.invalidCapture
            }
        case .canceled, .timedOut:
            break
        }
    }

    private static func validateCapture(_ capture: DirectShellOutputCapture) throws {
        let retained = capture.head.count + capture.tail.count
        guard retained <= DirectShellOutputCollector.maximumRetainedBytes,
              capture.totalByteCount >= Int64(retained),
              capture.omittedByteCount == capture.totalByteCount - Int64(retained),
              capture.isTruncated == (capture.omittedByteCount > 0) else {
            throw ValidationError.invalidCapture
        }
    }

    fileprivate init(
        request: DirectShellCommandRequest,
        status: DirectShellCommandTerminalStatus,
        stdout: DirectShellOutputCapture,
        stderr: DirectShellOutputCapture,
        startedAt: Date,
        endedAt: Date
    ) {
        self.schemaVersion = Self.schemaVersion
        self.commandID = request.commandID
        self.actionID = request.actionID
        self.language = request.language
        self.source = request.source
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

private actor DirectShellProcessGate {
    static let shared = DirectShellProcessGate()
    private static let maximumConcurrentProcesses = 4
    private var active = 0

    func tryAcquire() -> Bool {
        guard active < Self.maximumConcurrentProcesses else { return false }
        active += 1
        return true
    }

    func release() { active = max(0, active - 1) }
}

private final class DirectShellProcessControl: @unchecked Sendable {
    enum StopReason: Equatable {
        case canceled
        case timedOut
    }

    private let lock = NSLock()
    private var processGroupID: pid_t?
    private var reason: StopReason?
    private var finished = false

    func withLaunchLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func requestedReasonLocked() -> StopReason? {
        reason
    }

    func attachLocked(processGroupID: pid_t) {
        self.processGroupID = processGroupID
        let pendingReason = reason
        let shouldSignal = !finished && pendingReason != nil
        if shouldSignal { sendTERMLocked() }
    }

    func request(_ newReason: StopReason) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if reason == nil { reason = newReason }
        let shouldSignal = processGroupID != nil
        if shouldSignal { sendTERMLocked() }
        lock.unlock()
    }

    func finish() -> StopReason? {
        lock.lock(); defer { lock.unlock() }
        finished = true
        return reason
    }

    func requestedReason() -> StopReason? {
        lock.lock(); defer { lock.unlock() }
        return reason
    }

    var hasLaunchedProcess: Bool {
        lock.lock(); defer { lock.unlock() }
        return processGroupID != nil
    }

    private func sendTERMLocked() {
        let group = processGroupID
        guard let group, group > 0 else { return }
        _ = kill(-group, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sendKILL()
        }
    }

    private func sendKILL() {
        lock.lock(); defer { lock.unlock() }
        guard !finished, reason != nil, let group = processGroupID, group > 0 else { return }
        _ = kill(-group, SIGKILL)
    }
}

private final class DirectShellOutputCollector: @unchecked Sendable {
    static let maximumRetainedBytes = 64 * 1024
    static let headBytes = maximumRetainedBytes / 2

    private let lock = NSLock()
    private var completeData = Data()
    private var head = Data()
    private var tail = Data()
    private var overflowed = false
    private var total: Int64 = 0

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        total += Int64(data.count)
        if !overflowed {
            if completeData.count + data.count <= Self.maximumRetainedBytes {
                completeData.append(data)
                return
            }
            let combined = completeData + data
            head = Data(combined.prefix(Self.headBytes))
            tail = Data(combined.suffix(Self.headBytes))
            completeData.removeAll(keepingCapacity: false)
            overflowed = true
            return
        }

        if head.count < Self.headBytes {
            head.append(data.prefix(Self.headBytes - head.count))
        }
        tail.append(data)
        if tail.count > Self.headBytes {
            tail = Data(tail.suffix(Self.headBytes))
        }
    }

    func capture(isComplete: Bool = true) -> DirectShellOutputCapture {
        lock.lock(); defer { lock.unlock() }
        if overflowed {
            return DirectShellOutputCapture(
                head: head, tail: tail, totalByteCount: total, isComplete: isComplete)
        }
        return DirectShellOutputCapture(
            head: completeData, tail: Data(), totalByteCount: total, isComplete: isComplete)
    }
}

/// A nonblocking pipe reader. A descendant that inherits a write end must never be able to
/// keep the worker's settlement path blocked forever, so the reader is explicitly abandonable.
private final class DirectShellPipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var abandoned = false
    private var readSucceeded = true

    func markDone(success: Bool) {
        lock.lock(); done = true; readSucceeded = readSucceeded && success; lock.unlock()
    }

    func abandon() {
        lock.lock(); abandoned = true; readSucceeded = false; lock.unlock()
    }

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    var isAbandoned: Bool {
        lock.lock(); defer { lock.unlock() }
        return abandoned
    }

    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return done && readSucceeded && !abandoned
    }
}

/// A bounded, host-owned process-group worker for one direct shell command.
///
/// Process creation and waiting happen on a detached task and pipe readers live on utility
/// queues.  The actor itself never blocks a cooperative executor thread.  There is no implicit
/// timeout: a deadline is enforced only when the caller supplies one.
public actor DirectShellCommandWorker {
    public let request: DirectShellCommandRequest

    private let control = DirectShellProcessControl()
    private let preSpawnHook: (@Sendable () async -> Void)?
    private var runTask: Task<DirectShellCommandResult, Never>?

    public init(request: DirectShellCommandRequest) {
        self.init(request: request, preSpawnHook: nil)
    }

    /// Internal test seam only. Production callers use the public initializer, which leaves the
    /// hook nil; the hook lets self-tests place a cancellation deterministically between process
    /// admission and the short launch critical section without sleeping against real timing.
    init(request: DirectShellCommandRequest, preSpawnHook: (@Sendable () async -> Void)?) {
        self.request = request
        self.preSpawnHook = preSpawnHook
    }

    public func start() async {
        guard runTask == nil else { return }
        let request = self.request
        let control = self.control
        let preSpawnHook = self.preSpawnHook
        runTask = Task.detached(priority: .userInitiated) {
            await Self.execute(request: request, control: control, preSpawnHook: preSpawnHook)
        }
    }

    public func wait() async -> DirectShellCommandResult {
        await start()
        guard let runTask else {
            return Self.immediateFailure(request: request, message: "worker could not start")
        }
        // Canceling a GUI waiter must not cancel the host-owned process.  Only the explicit
        // stop command owns process termination; callers that need a bounded wait can stop it
        // separately and then await the durable result.
        return await runTask.value
    }

    public func stop() async {
        control.request(.canceled)
    }

    /// Internal launch observation distinguishes never-spawned cancellation from a child
    /// killed before it could produce output; neither stdout nor a marker file proves this.
    var hasLaunchedProcess: Bool { control.hasLaunchedProcess }

    private static func immediateFailure(
        request: DirectShellCommandRequest, message: String
    ) -> DirectShellCommandResult {
        let now = Date()
        return DirectShellCommandResult(
            request: request, status: .launchFailed(message: message),
            stdout: DirectShellOutputCapture(head: Data(), tail: Data(), totalByteCount: 0),
            stderr: DirectShellOutputCapture(head: Data(), tail: Data(), totalByteCount: 0),
            startedAt: now, endedAt: now)
    }

    private static func execute(
        request: DirectShellCommandRequest,
        control: DirectShellProcessControl,
        preSpawnHook: (@Sendable () async -> Void)?
    ) async -> DirectShellCommandResult {
        let startedAt = Date()
        do {
            try request.validate()
        } catch let error as DirectShellCommandRequest.ValidationError {
            return DirectShellCommandResult(
                request: request, status: .invalidRequest(message: error.description),
                stdout: DirectShellOutputCapture(head: Data(), tail: Data(), totalByteCount: 0),
                stderr: DirectShellOutputCapture(head: Data(), tail: Data(), totalByteCount: 0),
                startedAt: startedAt, endedAt: Date())
        } catch {
            return DirectShellCommandResult(
                request: request, status: .invalidRequest(message: "command request is invalid"),
                stdout: DirectShellOutputCapture(head: Data(), tail: Data(), totalByteCount: 0),
                stderr: DirectShellOutputCapture(head: Data(), tail: Data(), totalByteCount: 0),
                startedAt: startedAt, endedAt: Date())
        }

        let emptyCapture = DirectShellOutputCapture(head: Data(), tail: Data(), totalByteCount: 0)
        if let reason = control.requestedReason() {
            let status: DirectShellCommandTerminalStatus =
                reason == .canceled ? .canceled : .timedOut
            return DirectShellCommandResult(
                request: request, status: status,
                stdout: emptyCapture, stderr: emptyCapture,
                startedAt: startedAt, endedAt: Date())
        }
        let processGate = DirectShellProcessGate.shared
        guard await processGate.tryAcquire() else {
            return immediateFailure(request: request, message: "direct shell concurrency limit reached")
        }

        if let preSpawnHook { await preSpawnHook() }

        let stdoutCollector = DirectShellOutputCollector()
        let stderrCollector = DirectShellOutputCollector()
        // Stop and launch are serialized by the same short lock. If Stop won before this
        // section, no shell is spawned; if launch won, Stop observes the attached group and
        // signals it. The lock is never held across an async suspension.
        let launch: Result<SpawnedProcess, SpawnFailure>?
        launch = control.withLaunchLock {
            guard control.requestedReasonLocked() == nil else { return nil }
            let result = spawn(request: request)
            if case .success(let process) = result {
                control.attachLocked(processGroupID: process.pid)
            }
            return result
        }
        guard let launch else {
            await processGate.release()
            let status: DirectShellCommandTerminalStatus =
                control.requestedReason() == .timedOut ? .timedOut : .canceled
            return DirectShellCommandResult(
                request: request, status: status,
                stdout: emptyCapture, stderr: emptyCapture,
                startedAt: startedAt, endedAt: Date())
        }
        guard case .success(let process) = launch else {
            let message: String
            if case .failure(let error) = launch { message = error.message }
            else { message = "unknown launch failure" }
            _ = control.finish()
            await processGate.release()
            return DirectShellCommandResult(
                request: request, status: .launchFailed(message: message),
                stdout: stdoutCollector.capture(), stderr: stderrCollector.capture(),
                startedAt: startedAt, endedAt: Date())
        }

        let stdoutDrain = DirectShellPipeDrain()
        let stderrDrain = DirectShellPipeDrain()
        drain(process.stdout, into: stdoutCollector, state: stdoutDrain)
        drain(process.stderr, into: stderrCollector, state: stderrDrain)

        var timer: DispatchWorkItem?
        if let timeout = request.timeout {
            let item = DispatchWorkItem { control.request(.timedOut) }
            timer = item
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout, execute: item)
        }

        let observation = await observeExit(process.pid)
        timer?.cancel()
        var waitFailure: String?
        var waitStatus: Int32 = 0
        let pipesComplete: Bool
        let stopReason: DirectShellProcessControl.StopReason?
        if let error = observation.error {
            // Without a successful waitid ownership proof, the PID may already have been
            // recycled. Fence our control object before abandoning readers, and never signal or
            // reap a potentially unrelated process.
            waitFailure = error
            stopReason = control.finish()
            pipesComplete = await abandonPipes([stdoutDrain, stderrDrain])
        } else {
            // Keep the child as a zombie while the pipe grace period targets its original process
            // group. Only after signaling/abandonment is fenced do we reap it, so a recycled PID
            // cannot receive a delayed cleanup signal.
            pipesComplete = await waitForPipes(
                [stdoutDrain, stderrDrain], processGroupID: process.pid)
            stopReason = control.finish()
            let reap = await reapExit(process.pid)
            waitStatus = reap.status
            if let error = reap.error {
                waitFailure = error
            }
        }
        let status: DirectShellCommandTerminalStatus
        if let waitFailure {
            status = .workerFailed(message: waitFailure)
        } else if stopReason == .canceled {
            status = .canceled
        } else if stopReason == .timedOut {
            status = .timedOut
        } else if (waitStatus & 0x7f) == 0 {
            let code = (waitStatus >> 8) & 0xff
            status = code == 0 ? .exited(exitCode: code) : .nonzero(exitCode: code)
        } else if (waitStatus & 0x7f) != 0x7f {
            status = .signaled(signal: waitStatus & 0x7f)
        } else {
            status = .launchFailed(message: "process did not produce a terminal wait status")
        }

        let result = DirectShellCommandResult(
            request: request, status: status,
            stdout: stdoutCollector.capture(isComplete: pipesComplete),
            stderr: stderrCollector.capture(isComplete: pipesComplete),
            startedAt: startedAt, endedAt: Date())
        await processGate.release()
        return result
    }

    private struct SpawnedProcess {
        let pid: pid_t
        let stdout: Int32
        let stderr: Int32
    }

    private struct SpawnFailure: Error {
        let message: String
    }

    private static func spawn(
        request: DirectShellCommandRequest
    ) -> Result<SpawnedProcess, SpawnFailure> {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            if stdoutPipe[0] != 0 { close(stdoutPipe[0]); close(stdoutPipe[1]) }
            return .failure(SpawnFailure(message: String(cString: strerror(errno))))
        }
        for descriptor in stdoutPipe + stderrPipe {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
                return .failure(SpawnFailure(message: "could not configure output pipe inheritance"))
            }
        }

        #if canImport(Darwin)
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            return .failure(SpawnFailure(message: "could not initialize spawn attributes"))
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let setup: [Int32] = [
            posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]),
            posix_spawn_file_actions_addclose(&actions, stderrPipe[0]),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]),
            posix_spawn_file_actions_addclose(&actions, stderrPipe[1])
        ]
        guard setup.allSatisfy({ $0 == 0 }) else {
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            return .failure(SpawnFailure(message: "could not configure output pipes"))
        }

        let nullFD = open("/dev/null", O_RDONLY)
        guard nullFD >= 0,
              posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, nullFD) == 0 else {
            if nullFD >= 0 { close(nullFD) }
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            return .failure(SpawnFailure(message: "could not configure null stdin"))
        }
        #if canImport(Darwin)
        let workingDirectoryResult = posix_spawn_file_actions_addchdir_np(
            &actions, request.workingDirectory.path)
        #else
        let workingDirectoryResult = request.workingDirectory.path.withCString {
            aviary_posixSpawnFileActionsAddChdir(&actions, $0)
        }
        #endif
        guard workingDirectoryResult == 0 else {
            close(nullFD)
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            return .failure(SpawnFailure(message: "could not configure working directory"))
        }

        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            close(nullFD)
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            return .failure(SpawnFailure(message: "could not configure process group"))
        }

        var source = Array(request.source)
        source.append(0)
        let environmentStrings = request.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let environmentPointers = environmentStrings.map { strdup($0) }
        defer { environmentPointers.forEach { if let pointer = $0 { free(pointer) } } }
        var environment = environmentPointers + [nil]
        var pid: pid_t = 0
        let executable = request.language.executable
        let spawnError: Int32 = source.withUnsafeMutableBufferPointer { sourceBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                executable.withCString { executablePointer in
                    var argv: [UnsafeMutablePointer<CChar>?] = [
                        UnsafeMutablePointer(mutating: executablePointer),
                        strdup("-c"),
                        UnsafeMutableRawPointer(sourceBuffer.baseAddress!).assumingMemoryBound(to: CChar.self),
                        nil
                    ]
                    defer { if let arg = argv[1] { free(arg) } }
                    return posix_spawn(
                        &pid, executablePointer, &actions, &attributes,
                        &argv, environmentBuffer.baseAddress)
                }
            }
        }

        guard spawnError == 0 else {
            close(nullFD)
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            return .failure(SpawnFailure(message: String(cString: strerror(spawnError))))
        }
        close(nullFD)
        close(stdoutPipe[1]); close(stderrPipe[1])
        return .success(SpawnedProcess(pid: pid, stdout: stdoutPipe[0], stderr: stderrPipe[0]))
    }

    private static func drain(
        _ descriptor: Int32,
        into collector: DirectShellOutputCollector,
        state: DirectShellPipeDrain
    ) {
        DispatchQueue.global(qos: .utility).async {
            let flags = fcntl(descriptor, F_GETFL)
            var succeeded = true
            if flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0 {
                succeeded = false
                close(descriptor)
                state.markDone(success: false)
                return
            }
            defer { close(descriptor); state.markDone(success: succeeded) }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                if state.isAbandoned { return }
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let pollResult = poll(&pollDescriptor, 1, 50)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    succeeded = false
                    return
                }
                if pollResult == 0 { continue }
                while !state.isAbandoned {
                    let count = buffer.withUnsafeMutableBytes {
                        read(descriptor, $0.baseAddress, $0.count)
                    }
                    if count == 0 { return }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        succeeded = false
                        return
                    }
                    collector.append(Data(buffer[0..<Int(count)]))
                }
            }
        }
    }

    private struct ProcessWaitObservation: Sendable {
        let error: String?
    }

    private struct ProcessReap: Sendable {
        let status: Int32
        let error: String?
    }

    /// waitid/waitpid are intentionally kept off Swift's cooperative executor. A pair of
    /// long-lived commands must not consume the small Linux executor pool while their roots or
    /// zombie cleanup are waiting on the OS.
    private static func observeExit(_ processID: pid_t) async -> ProcessWaitObservation {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<ProcessWaitObservation, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var info = siginfo_t()
                while true {
                    let result = waitid(P_PID, id_t(processID), &info, WEXITED | WNOWAIT)
                    if result == 0 {
                        continuation.resume(returning: ProcessWaitObservation(error: nil))
                        return
                    }
                    if errno == EINTR { continue }
                    let code = errno
                    continuation.resume(returning: ProcessWaitObservation(
                        error: "waitid failed: \(String(cString: strerror(code)))"))
                    return
                }
            }
        }
    }

    private static func reapExit(_ processID: pid_t) async -> ProcessReap {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<ProcessReap, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while true {
                    let result = waitpid(processID, &status, 0)
                    if result == processID {
                        continuation.resume(returning: ProcessReap(status: status, error: nil))
                        return
                    }
                    if result < 0 && errno == EINTR { continue }
                    let code = errno
                    continuation.resume(returning: ProcessReap(
                        status: status,
                        error: "waitpid failed: \(String(cString: strerror(code)))"))
                    return
                }
            }
        }
    }

    private static func abandonPipes(_ drains: [DirectShellPipeDrain]) async -> Bool {
        func complete() -> Bool { drains.allSatisfy(\.isDone) }
        func successful() -> Bool { drains.allSatisfy(\.isComplete) }
        let deadline = ContinuousClock.now + .milliseconds(250)
        while !complete() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !complete() { drains.forEach { $0.abandon() } }
        return complete() && successful()
    }

    private static func waitForPipes(
        _ drains: [DirectShellPipeDrain], processGroupID: pid_t
    ) async -> Bool {
        func complete() -> Bool { drains.allSatisfy(\.isDone) }
        func completeAndSuccessful() -> Bool { drains.allSatisfy(\.isComplete) }
        let initialDeadline = ContinuousClock.now + .seconds(2)
        while !complete() && ContinuousClock.now < initialDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard !complete() else { return completeAndSuccessful() }
        _ = kill(-processGroupID, SIGTERM)
        let termDeadline = ContinuousClock.now + .seconds(2)
        while !complete() && ContinuousClock.now < termDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard !complete() else { return completeAndSuccessful() }
        _ = kill(-processGroupID, SIGKILL)
        let killDeadline = ContinuousClock.now + .milliseconds(250)
        while !complete() && ContinuousClock.now < killDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !complete() { drains.forEach { $0.abandon() } }
        return complete() && completeAndSuccessful()
    }
}
