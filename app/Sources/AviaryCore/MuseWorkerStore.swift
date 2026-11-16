import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Small, same-user durable handoff store for a detached native Muse worker.
/// This is local process coordination, not a security boundary against another process owned by
/// the same user. Payloads remain extensible JSON and are always read with explicit byte bounds.
public struct MuseWorkerStore: Sendable {
    public static let maximumManifestBytes = 1 * 1_024 * 1_024
    public static let maximumSnapshotBytes = 1 * 1_024 * 1_024
    public static let maximumDraftBytes = 1 * 1_024 * 1_024
    public static let maximumCommandBytes = 1 * 1_024 * 1_024
    /// Lifetime cap per session, including settled records and all worker generations.
    /// Full receipts remain available, so this is intentionally fail-closed rather than evicting.
    public static let maximumRetainedCommands = 1_024
    public static let maximumRegularCommands = maximumRetainedCommands - 1
    public static let maximumSessions = 4_096
    public static let directoryName = "muse-workers"
    public static let resumeReservationLifetime: TimeInterval = 120

    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case invalidSessionID
        case invalidInstanceID
        case invalidCommandID
        case sessionMissing
        case sessionExists
        case instanceMismatch
        case commandMissing
        case commandContentMismatch
        case invalidCommandTransition
        case commandCapacityReached(Int)
        case sessionCapacityReached(Int)
        case invalidStore
        case corruptStore
        case ioFailure
        case ownerAlreadyHeld
        case resumeAlreadyReserved
        case resumeReservationExpired
        case resumeReservationMismatch
        case payloadTooLarge

        public var errorDescription: String? {
            switch self {
            case .invalidSessionID: return "The Muse worker session identifier is invalid."
            case .invalidInstanceID: return "The Muse worker instance identifier is invalid."
            case .invalidCommandID: return "The Muse worker command identifier is invalid."
            case .sessionMissing: return "The Muse worker session is unavailable."
            case .sessionExists: return "The Muse worker session already has different state."
            case .instanceMismatch: return "The Muse worker instance has changed."
            case .commandMissing: return "The Muse worker command is unavailable."
            case .commandContentMismatch: return "The Muse worker command identifier was reused with different content."
            case .invalidCommandTransition: return "The Muse worker command cannot make that state transition."
            case .commandCapacityReached(let limit): return "The Muse worker has reached its retained command limit (\(limit))."
            case .sessionCapacityReached(let limit): return "The Muse worker store has reached its session limit (\(limit))."
            case .invalidStore: return "The Muse worker store is not a valid private directory."
            case .corruptStore: return "The Muse worker store contains invalid data."
            case .ioFailure: return "The Muse worker store could not complete the operation."
            case .ownerAlreadyHeld: return "Another Muse worker currently owns this session."
            case .resumeAlreadyReserved: return "A Muse worker launch is already reserved for this session."
            case .resumeReservationExpired: return "The Muse worker launch reservation expired. Reserve a new worker launch."
            case .resumeReservationMismatch: return "The Muse worker launch reservation does not match this instance."
            case .payloadTooLarge: return "The Muse worker payload exceeds its size limit."
            }
        }
    }

    public struct Session: Sendable, Equatable {
        public let sessionID: String
        public let instanceID: String
        public let manifest: JSONValue
        public let resumeReservationToken: String?
        public let resumeReservationExpiresAt: TimeInterval?
        public let resumeStartCommand: Command?

        public init(sessionID: String, instanceID: String, manifest: JSONValue,
                    resumeReservationToken: String? = nil, resumeReservationExpiresAt: TimeInterval? = nil,
                    resumeStartCommand: Command? = nil) {
            self.sessionID = sessionID
            self.instanceID = instanceID
            self.manifest = manifest
            self.resumeReservationToken = resumeReservationToken
            self.resumeReservationExpiresAt = resumeReservationExpiresAt
            self.resumeStartCommand = resumeStartCommand
        }
    }

    public struct Command: Sendable, Equatable {
        public enum Stage: String, Codable, Sendable { case pending, dispatched, settled }
        public let commandID: String
        public let instanceID: String
        public let sequence: Int
        public let request: JSONValue
        public let stage: Stage
        public let receipt: JSONValue?
    }

    public struct Draft: Sendable, Equatable {
        public struct Handoff: Sendable, Equatable {
            public let commandID: String
            public let instanceID: String
            public let text: String
        }
        public let text: String
        public let handoff: Handoff?
        public init(text: String, handoff: Handoff? = nil) {
            self.text = text
            self.handoff = handoff
        }
    }

    public let homeRoot: URL
    private var workersRoot: URL { homeRoot.appending(path: Self.directoryName, directoryHint: .isDirectory) }

    public init(homeRoot: URL) {
        self.homeRoot = homeRoot.standardizedFileURL
    }

    /// Creates a session idempotently only when the prior creation has identical identity and
    /// manifest. Reusing an id for another worker never replaces its state.
    @discardableResult
    public func createSession(sessionID: String, manifest: JSONValue, instanceID: String) throws -> Session {
        try Self.validateSessionID(sessionID)
        try Self.validateUUID(instanceID, invalid: .invalidInstanceID)
        try Self.validatePayload(manifest, maximum: Self.maximumManifestBytes)
        try ensureStoreDirectory()
        try withRootLock {
            let target = sessionURL(sessionID)
            if !(try pathExists(target)) {
                let names = try enumeratedNames(workersRoot, limit: Self.maximumSessions + 32)
                let existingSessionCount = names.filter { name in
                    guard (try? Self.validateSessionID(name)) != nil else { return false }
                    return (try? isRealDirectory(workersRoot.appending(path: name, directoryHint: .isDirectory))) == true
                }.count
                guard existingSessionCount < Self.maximumSessions else {
                    throw Error.sessionCapacityReached(Self.maximumSessions)
                }
                let createResult = target.path.withCString { mkdir($0, mode_t(0o700)) }
                if createResult != 0 && errno != EEXIST { throw Error.ioFailure }
            }
        }
        guard try isRealDirectory(sessionURL(sessionID)) else { throw Error.invalidStore }
        let sessionFD = sessionURL(sessionID).path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard sessionFD >= 0 else { throw Error.invalidStore }
        defer { close(sessionFD) }
        guard fchmod(sessionFD, mode_t(0o700)) == 0 else { throw Error.ioFailure }
        return try withSessionLock(sessionID) {
            let url = sessionURL(sessionID)
            if try pathExists(url.appending(path: "manifest.json")) {
                let existing = try readManifest(sessionID)
                guard existing.instanceID == instanceID, existing.manifest == manifest else {
                    throw Error.sessionExists
                }
                return existing
            }
            try writeJSON(.object(["instanceID": .string(instanceID), "manifest": manifest]),
                          to: url.appending(path: "manifest.json"), limit: Self.maximumManifestBytes)
            return Session(sessionID: sessionID, instanceID: instanceID, manifest: manifest)
        }
    }

    /// Bounded enumeration; non-session entries and malformed names are ignored.
    public func sessions() throws -> [String] {
        try ensureStoreDirectory()
        let names = try withRootLock { try enumeratedNames(workersRoot, limit: Self.maximumSessions + 32) }
        let sessionNames = names.filter { name in
            guard (try? Self.validateSessionID(name)) != nil else { return false }
            return (try? isRealDirectory(sessionURL(name))) == true
        }
        guard sessionNames.count <= Self.maximumSessions else { throw Error.sessionCapacityReached(Self.maximumSessions) }
        return sessionNames.sorted()
    }

    public func loadManifest(sessionID: String) throws -> Session {
        try Self.validateSessionID(sessionID)
        return try readManifest(sessionID)
    }

    /// One bounded local GUI draft per session. It is independent of the worker generation and
    /// survives worker restarts; this is not a multi-client draft history.
    public func readDraft(sessionID: String) throws -> String? {
        try readDraftRecord(sessionID: sessionID)?.text
    }

    public func readDraftRecord(sessionID: String) throws -> Draft? {
        try Self.validateSessionID(sessionID)
        return try withSessionLock(sessionID) {
            try readDraftRecordUnlocked(sessionID)
        }
    }

    public func writeDraft(sessionID: String, text: String) throws {
        try Self.validateSessionID(sessionID)
        try Self.validateDraft(text: text, handoff: nil)
        try withSessionLock(sessionID) {
            let existing = try readDraftRecordUnlocked(sessionID)
            try writeJSON(Self.encodeDraft(Draft(text: text, handoff: existing?.handoff)),
                          to: sessionURL(sessionID).appending(path: "draft.json"),
                          limit: Self.maximumDraftBytes)
        }
    }

    public func writeHandoff(sessionID: String, commandID: String, instanceID: String, text: String) throws {
        try Self.validateSessionID(sessionID)
        let canonicalID = try Self.canonicalCommandID(commandID)
        try Self.validateUUID(instanceID, invalid: .invalidInstanceID)
        let handoff = Draft.Handoff(commandID: canonicalID, instanceID: instanceID, text: text)
        try Self.validateDraft(text: text, handoff: handoff)
        try withSessionLock(sessionID) {
            if let existing = try readDraftRecordUnlocked(sessionID)?.handoff {
                guard existing == handoff else { throw Error.commandContentMismatch }
                return
            }
            try writeJSON(Self.encodeDraft(Draft(text: text, handoff: handoff)),
                to: sessionURL(sessionID).appending(path: "draft.json"), limit: Self.maximumDraftBytes)
        }
    }

    /// Resolve only the named handoff. On accepted delivery, clear the draft only if the user
    /// has not edited it since the send began. This makes receipt reconciliation one atomic edit.
    @discardableResult
    public func resolveHandoff(sessionID: String, expectedCommandID: String, accepted: Bool) throws -> Draft? {
        try Self.validateSessionID(sessionID)
        let id = try Self.canonicalCommandID(expectedCommandID)
        return try withSessionLock(sessionID) {
            guard let current = try readDraftRecordUnlocked(sessionID) else { return nil }
            guard let handoff = current.handoff, handoff.commandID == id else { return current }
            let nextText = accepted && current.text == handoff.text ? "" : current.text
            let resolved = Draft(text: nextText)
            try writeJSON(Self.encodeDraft(resolved), to: sessionURL(sessionID).appending(path: "draft.json"),
                          limit: Self.maximumDraftBytes)
            return resolved
        }
    }

    @discardableResult
    public func updateManifest(sessionID: String, expectedInstanceID: String, manifest: JSONValue) throws -> Session {
        try Self.validateSessionID(sessionID)
        try Self.validateUUID(expectedInstanceID, invalid: .invalidInstanceID)
        try Self.validatePayload(manifest, maximum: Self.maximumManifestBytes)
        return try withSessionLock(sessionID) {
            let current = try readManifest(sessionID)
            guard current.instanceID == expectedInstanceID else { throw Error.instanceMismatch }
            let updated = Session(sessionID: sessionID, instanceID: expectedInstanceID, manifest: manifest)
            try writeJSON(manifestEnvelope(instanceID: expectedInstanceID, manifest: manifest,
                reservationToken: current.resumeReservationToken,
                reservationExpiresAt: current.resumeReservationExpiresAt,
                resumeStartCommand: current.resumeStartCommand),
                          to: sessionURL(sessionID).appending(path: "manifest.json"), limit: Self.maximumManifestBytes)
            return updated
        }
    }

    /// Advance the durable worker generation only after acquiring the lifetime-owner lock.
    /// Old command records remain as receipt and dispatch evidence; command UUIDs remain unique
    /// across all generations of the session.
    @discardableResult
    public func reserveResume(sessionID: String, expectedInstanceID: String, newInstanceID: String,
                              manifest: JSONValue, startCommandID: String,
                              startRequest: JSONValue) throws -> Session {
        try Self.validateSessionID(sessionID)
        try Self.validateUUID(expectedInstanceID, invalid: .invalidInstanceID)
        try Self.validateUUID(newInstanceID, invalid: .invalidInstanceID)
        guard expectedInstanceID != newInstanceID else { throw Error.invalidInstanceID }
        try Self.validatePayload(manifest, maximum: Self.maximumManifestBytes)
        let startID = try Self.canonicalCommandID(startCommandID)
        try Self.validatePayload(startRequest, maximum: Self.maximumCommandBytes)
        let ownerFD = try acquireUnlockedOwnerFile(sessionID)
        defer { _ = flock(ownerFD, LOCK_UN); close(ownerFD) }
        return try withSessionLock(sessionID) {
            let current = try readManifest(sessionID)
            guard current.instanceID == expectedInstanceID else { throw Error.instanceMismatch }
            if let expiresAt = current.resumeReservationExpiresAt, expiresAt > Date().timeIntervalSince1970 {
                throw Error.resumeAlreadyReserved
            }
            var existingFiles = try commandFiles(sessionID)
            // Preserve a start command embedded by an expired reservation before replacing it.
            // This also prevents its ID from being reused after a delayed launch.
            if let priorStart = current.resumeStartCommand,
               !existingFiles.contains("command-\(priorStart.commandID).json") {
                guard existingFiles.count < Self.maximumRetainedCommands else {
                    throw Error.commandCapacityReached(Self.maximumRetainedCommands)
                }
                try writeJSON(encode(priorStart), to: commandURL(sessionID, priorStart.commandID),
                              limit: Self.maximumCommandBytes)
                existingFiles.append("command-\(priorStart.commandID).json")
            } else if let priorStart = current.resumeStartCommand {
                guard try readCommand(commandURL(sessionID, priorStart.commandID),
                    expectedID: priorStart.commandID) == priorStart else { throw Error.commandContentMismatch }
            }
            guard !existingFiles.contains("command-\(startID).json"),
                  current.resumeStartCommand?.commandID != startID else {
                throw Error.commandContentMismatch
            }
            let previousCommands = try existingFiles.map { name in
                try readCommand(sessionURL(sessionID).appending(path: name), expectedID: filenameCommandID(from: name))
            }
            guard Set(previousCommands.map(\.sequence)).count == previousCommands.count else {
                throw Error.corruptStore
            }
            guard previousCommands.count < Self.maximumRegularCommands else {
                throw Error.commandCapacityReached(Self.maximumRetainedCommands)
            }
            let startCommand = Command(commandID: startID, instanceID: newInstanceID,
                sequence: (previousCommands.map(\.sequence).max() ?? 0) + 1,
                request: startRequest, stage: .pending, receipt: nil)
            let reservationToken = UUID().uuidString.lowercased()
            let expiresAt = Date().timeIntervalSince1970 + Self.resumeReservationLifetime
            let reserved = Session(sessionID: sessionID, instanceID: newInstanceID, manifest: manifest,
                resumeReservationToken: reservationToken, resumeReservationExpiresAt: expiresAt,
                resumeStartCommand: startCommand)
            try writeJSON(manifestEnvelope(instanceID: newInstanceID, manifest: manifest,
                reservationToken: reservationToken, reservationExpiresAt: expiresAt,
                resumeStartCommand: startCommand),
                          to: sessionURL(sessionID).appending(path: "manifest.json"), limit: Self.maximumManifestBytes)
            return reserved
        }
    }

    public func loadSnapshot(sessionID: String, expectedInstanceID: String) throws -> JSONValue? {
        try Self.validateSessionID(sessionID)
        try Self.validateUUID(expectedInstanceID, invalid: .invalidInstanceID)
        return try withSessionLock(sessionID) {
            try requireInstance(sessionID, expected: expectedInstanceID)
            let url = sessionURL(sessionID).appending(path: "snapshot.json")
            guard try pathExists(url) else { return nil }
            let record = try readJSON(url, limit: Self.maximumSnapshotBytes)
            guard let recordInstanceID = record["instanceID"]?.stringValue,
                  UUID(uuidString: recordInstanceID) != nil,
                  let snapshot = record["snapshot"] else { throw Error.corruptStore }
            // A previous generation's snapshot is normal after resume reservation and before
            // the new worker's first snapshot. Treat it as absent instead of as corruption.
            guard recordInstanceID == expectedInstanceID else { return nil }
            return snapshot
        }
    }

    public func writeSnapshot(sessionID: String, expectedInstanceID: String, snapshot: JSONValue) throws {
        try Self.validateSessionID(sessionID)
        try Self.validateUUID(expectedInstanceID, invalid: .invalidInstanceID)
        try Self.validatePayload(snapshot, maximum: Self.maximumSnapshotBytes)
        try withSessionLock(sessionID) {
            try requireInstance(sessionID, expected: expectedInstanceID)
            try writeJSON(.object(["instanceID": .string(expectedInstanceID), "snapshot": snapshot]),
                          to: sessionURL(sessionID).appending(path: "snapshot.json"), limit: Self.maximumSnapshotBytes)
        }
    }

    /// Exact replay returns the existing command and never resets its delivery stage or receipt.
    @discardableResult
    public func submitCommand(sessionID: String, expectedInstanceID: String, commandID: String, request: JSONValue) throws -> Command {
        try Self.validateSessionID(sessionID)
        try Self.validateUUID(expectedInstanceID, invalid: .invalidInstanceID)
        let id = try Self.canonicalCommandID(commandID)
        try Self.validatePayload(request, maximum: Self.maximumCommandBytes)
        return try withSessionLock(sessionID) {
            try requireInstance(sessionID, expected: expectedInstanceID)
            let url = commandURL(sessionID, id)
            if try pathExists(url) {
                let existing = try readCommand(url, expectedID: id)
                guard existing.instanceID == expectedInstanceID else { throw Error.commandContentMismatch }
                guard existing.request == request else { throw Error.commandContentMismatch }
                return existing
            }
            let existingFiles = try commandFiles(sessionID)
            let currentManifest = try readManifest(sessionID)
            if let reservedStart = currentManifest.resumeStartCommand, reservedStart.commandID == id {
                guard reservedStart.instanceID == expectedInstanceID, reservedStart.request == request else {
                    throw Error.commandContentMismatch
                }
                return reservedStart
            }
            var previousCommands = try existingFiles.map { name in
                try readCommand(sessionURL(sessionID).appending(path: name), expectedID: filenameCommandID(from: name))
            }
            if let embedded = currentManifest.resumeStartCommand,
               !existingFiles.contains("command-\(embedded.commandID).json") {
                previousCommands.append(embedded)
            }
            guard Set(previousCommands.map(\.sequence)).count == previousCommands.count else { throw Error.corruptStore }
            if Self.isEndControlRequest(request) {
                guard previousCommands.count < Self.maximumRetainedCommands else {
                    throw Error.commandCapacityReached(Self.maximumRetainedCommands)
                }
            } else {
                guard previousCommands.count < Self.maximumRegularCommands else {
                    throw Error.commandCapacityReached(Self.maximumRetainedCommands)
                }
            }
            let sequence = (previousCommands.map(\.sequence).max() ?? 0) + 1
            let command = Command(commandID: id, instanceID: expectedInstanceID, sequence: sequence,
                                  request: request, stage: .pending, receipt: nil)
            try writeJSON(encode(command), to: url, limit: Self.maximumCommandBytes)
            return command
        }
    }

    public func command(sessionID: String, expectedInstanceID: String, commandID: String) throws -> Command {
        try Self.validateSessionID(sessionID)
        try Self.validateUUID(expectedInstanceID, invalid: .invalidInstanceID)
        let id = try Self.canonicalCommandID(commandID)
        return try withSessionLock(sessionID) {
            try requireInstance(sessionID, expected: expectedInstanceID)
            let result: Command
            if try pathExists(commandURL(sessionID, id)) {
                result = try readCommand(commandURL(sessionID, id), expectedID: id)
            } else if let embedded = try readManifest(sessionID).resumeStartCommand,
                      embedded.commandID == id {
                result = embedded
            } else {
                throw Error.commandMissing
            }
            guard result.instanceID == expectedInstanceID else { throw Error.commandMissing }
            return result
        }
    }

    public func pendingCommands(sessionID: String, expectedInstanceID: String) throws -> [Command] {
        try Self.validateSessionID(sessionID)
        try Self.validateUUID(expectedInstanceID, invalid: .invalidInstanceID)
        return try withSessionLock(sessionID) {
            try requireInstance(sessionID, expected: expectedInstanceID)
            var commands = try commandFiles(sessionID).map { name in
                try readCommand(sessionURL(sessionID).appending(path: name), expectedID: filenameCommandID(from: name))
            }
            if let embedded = try readManifest(sessionID).resumeStartCommand {
                if let persisted = commands.first(where: { $0.commandID == embedded.commandID }) {
                    guard persisted == embedded else { throw Error.commandContentMismatch }
                } else {
                    commands.append(embedded)
                }
            }
            guard Set(commands.map(\.sequence)).count == commands.count else { throw Error.corruptStore }
            return commands.filter { $0.instanceID == expectedInstanceID && $0.stage != .settled }
                .sorted { $0.sequence < $1.sequence }
        }
    }

    public func markDispatched(sessionID: String, expectedInstanceID: String, commandID: String) throws -> Command {
        try transition(sessionID: sessionID, expectedInstanceID: expectedInstanceID, commandID: commandID) { current in
            guard current.stage == .pending else { throw Error.invalidCommandTransition }
            return Command(commandID: current.commandID, instanceID: current.instanceID, sequence: current.sequence,
                           request: current.request, stage: .dispatched, receipt: nil)
        }
    }

    /// Settling is idempotent only for an identical prior receipt.
    public func settleCommand(sessionID: String, expectedInstanceID: String, commandID: String, receipt: JSONValue) throws -> Command {
        try Self.validatePayload(receipt, maximum: Self.maximumCommandBytes)
        return try transition(sessionID: sessionID, expectedInstanceID: expectedInstanceID, commandID: commandID) { current in
            if current.stage == .settled {
                guard current.receipt == receipt else { throw Error.commandContentMismatch }
                return current
            }
            guard current.stage == .dispatched else { throw Error.invalidCommandTransition }
            return Command(commandID: current.commandID, instanceID: current.instanceID, sequence: current.sequence,
                           request: current.request, stage: .settled, receipt: receipt)
        }
    }

    /// The returned lease owns an exclusive flock until released or deallocated. A lock probe is
    /// only an instantaneous ownership check, not proof of process health or PID identity.
    public func acquireOwner(sessionID: String, instanceID: String) throws -> MuseWorkerOwnerLease {
        try Self.validateSessionID(sessionID)
        try Self.validateUUID(instanceID, invalid: .invalidInstanceID)
        let fd = try acquireUnlockedOwnerFile(sessionID)
        do {
            try withSessionLock(sessionID) {
                let current = try readManifest(sessionID)
                guard current.instanceID == instanceID else { throw Error.instanceMismatch }
                if let token = current.resumeReservationToken {
                    guard let expiresAt = current.resumeReservationExpiresAt,
                          expiresAt > Date().timeIntervalSince1970 else {
                        throw Error.resumeReservationExpired
                    }
                    guard UUID(uuidString: token) != nil else { throw Error.corruptStore }
                    if let start = current.resumeStartCommand {
                        let startURL = commandURL(sessionID, start.commandID)
                        if try pathExists(startURL) {
                            guard try readCommand(startURL, expectedID: start.commandID) == start else {
                                throw Error.commandContentMismatch
                            }
                        } else {
                            try writeJSON(encode(start), to: startURL, limit: Self.maximumCommandBytes)
                        }
                    }
                    try writeJSON(manifestEnvelope(instanceID: instanceID, manifest: current.manifest),
                        to: sessionURL(sessionID).appending(path: "manifest.json"), limit: Self.maximumManifestBytes)
                }
            }
        }
        catch { _ = flock(fd, LOCK_UN); close(fd); throw error }
        return MuseWorkerOwnerLease(fileDescriptor: fd, sessionID: sessionID, instanceID: instanceID)
    }

    public static func isOwned(homeRoot: URL, sessionID: String) throws -> Bool {
        try validateSessionID(sessionID)
        let url = homeRoot.standardizedFileURL.appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: sessionID, directoryHint: .isDirectory).appending(path: "owner.lock")
        let fd = url.path.withCString { open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else {
            if errno == ENOENT { return false }
            throw Error.ioFailure
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Error.invalidStore }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { _ = flock(fd, LOCK_UN); return false }
        if errno == EWOULDBLOCK || errno == EAGAIN { return true }
        throw Error.ioFailure
    }

    // MARK: Internal operations

    private func transition(sessionID: String, expectedInstanceID: String, commandID: String,
                            _ body: (Command) throws -> Command) throws -> Command {
        try Self.validateSessionID(sessionID)
        try Self.validateUUID(expectedInstanceID, invalid: .invalidInstanceID)
        let id = try Self.canonicalCommandID(commandID)
        return try withSessionLock(sessionID) {
            try requireInstance(sessionID, expected: expectedInstanceID)
            let url = commandURL(sessionID, id)
            let currentManifest = try readManifest(sessionID)
            let commandFileExists = try pathExists(url)
            let wasEmbedded = !commandFileExists
            let current: Command
            if !wasEmbedded {
                current = try readCommand(url, expectedID: id)
            } else if let embedded = currentManifest.resumeStartCommand, embedded.commandID == id {
                current = embedded
            } else {
                throw Error.commandMissing
            }
            guard current.instanceID == expectedInstanceID else { throw Error.commandMissing }
            let updated = try body(current)
            if updated != current {
                try writeJSON(encode(updated), to: url, limit: Self.maximumCommandBytes)
                if wasEmbedded {
                    try writeJSON(manifestEnvelope(instanceID: expectedInstanceID, manifest: currentManifest.manifest,
                        reservationToken: currentManifest.resumeReservationToken,
                        reservationExpiresAt: currentManifest.resumeReservationExpiresAt),
                        to: sessionURL(sessionID).appending(path: "manifest.json"), limit: Self.maximumManifestBytes)
                }
            }
            return updated
        }
    }

    private func ensureStoreDirectory() throws {
        do { try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true) }
        catch { throw Error.ioFailure }
        let rootFD = homeRoot.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else { throw Error.invalidStore }
        defer { close(rootFD) }
        let result = workersRoot.path.withCString { mkdir($0, mode_t(0o700)) }
        if result != 0 && errno != EEXIST { throw Error.ioFailure }
        let fd = workersRoot.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw Error.invalidStore }
        defer { close(fd) }
        guard fchmod(fd, mode_t(0o700)) == 0 else { throw Error.ioFailure }
    }

    private func withRootLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = workersRoot.appending(path: "root.mutation.lock")
        let fd = lockURL.path.withCString {
            open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        }
        guard fd >= 0 else { throw Error.invalidStore }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              fchmod(fd, mode_t(0o600)) == 0 else { close(fd); throw Error.invalidStore }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Error.ioFailure }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private func createPrivateDirectory(_ url: URL) throws {
        guard url.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else { throw Error.ioFailure }
        let fd = url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw Error.invalidStore }
        defer { close(fd) }
        guard fchmod(fd, mode_t(0o700)) == 0 else { throw Error.ioFailure }
    }

    /// Opens and exclusively holds the owner file, returning its descriptor to the caller.
    private func acquireUnlockedOwnerFile(_ sessionID: String) throws -> Int32 {
        guard try isRealDirectory(sessionURL(sessionID)) else { throw Error.sessionMissing }
        let lockURL = sessionURL(sessionID).appending(path: "owner.lock")
        let fd = lockURL.path.withCString { open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600)) }
        guard fd >= 0 else { throw Error.ioFailure }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(fd); throw Error.invalidStore }
        guard fchmod(fd, mode_t(0o600)) == 0 else { close(fd); throw Error.ioFailure }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let e = errno
            close(fd)
            if e == EWOULDBLOCK || e == EAGAIN { throw Error.ownerAlreadyHeld }
            throw Error.ioFailure
        }
        return fd
    }

    private func withSessionLock<T>(_ sessionID: String, _ body: () throws -> T) throws -> T {
        try ensureStoreDirectory()
        let dir = sessionURL(sessionID)
        guard try isRealDirectory(dir) else { throw Error.sessionMissing }
        let lockURL = dir.appending(path: "mutation.lock")
        let fd = lockURL.path.withCString { open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600)) }
        guard fd >= 0 else { throw Error.invalidStore }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(fd); throw Error.invalidStore }
        defer { close(fd) }
        guard fchmod(fd, mode_t(0o600)) == 0, flock(fd, LOCK_EX) == 0 else { throw Error.ioFailure }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private func readManifest(_ sessionID: String) throws -> Session {
        let record = try readJSON(sessionURL(sessionID).appending(path: "manifest.json"), limit: Self.maximumManifestBytes)
        guard let instance = record["instanceID"]?.stringValue, UUID(uuidString: instance) != nil,
              let manifest = record["manifest"] else { throw Error.corruptStore }
        let reservation = record["resumeReservation"]
        let reservationToken: String?
        let reservationExpiresAt: TimeInterval?
        if let reservation {
            guard let token = reservation["token"]?.stringValue, UUID(uuidString: token) != nil,
                  case .number(let expiry)? = reservation["expiresAt"], expiry.isFinite else {
                throw Error.corruptStore
            }
            reservationToken = token
            reservationExpiresAt = expiry
        } else {
            reservationToken = nil
            reservationExpiresAt = nil
        }
        let resumeStartCommand: Command?
        if let value = record["resumeStartCommand"] {
            guard let commandID = value["commandID"]?.stringValue else { throw Error.corruptStore }
            resumeStartCommand = try decodeCommandRecord(value, expectedID: commandID)
        } else {
            resumeStartCommand = nil
        }
        if reservationToken != nil {
            guard let resumeStartCommand, resumeStartCommand.instanceID == instance,
                  resumeStartCommand.stage == .pending else { throw Error.corruptStore }
        }
        return Session(sessionID: sessionID, instanceID: instance, manifest: manifest,
            resumeReservationToken: reservationToken, resumeReservationExpiresAt: reservationExpiresAt,
            resumeStartCommand: resumeStartCommand)
    }

    private func manifestEnvelope(instanceID: String, manifest: JSONValue, reservationToken: String? = nil,
                                  reservationExpiresAt: TimeInterval? = nil,
                                  resumeStartCommand: Command? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["instanceID": .string(instanceID), "manifest": manifest]
        if let reservationToken, let reservationExpiresAt {
            value["resumeReservation"] = .object([
                "token": .string(reservationToken),
                "expiresAt": .number(reservationExpiresAt),
            ])
        }
        if let resumeStartCommand { value["resumeStartCommand"] = encode(resumeStartCommand) }
        return .object(value)
    }

    private func readDraftRecordUnlocked(_ sessionID: String) throws -> Draft? {
        let url = sessionURL(sessionID).appending(path: "draft.json")
        guard try pathExists(url) else { return nil }
        let record = try readJSON(url, limit: Self.maximumDraftBytes)
        guard let text = record["text"]?.stringValue else { throw Error.corruptStore }
        let handoff: Draft.Handoff?
        if let raw = record["handoff"] {
            guard let commandID = raw["commandID"]?.stringValue,
                  (try? Self.canonicalCommandID(commandID)) == commandID,
                  let instanceID = raw["instanceID"]?.stringValue, UUID(uuidString: instanceID) != nil,
                  let handoffText = raw["text"]?.stringValue else { throw Error.corruptStore }
            handoff = Draft.Handoff(commandID: commandID, instanceID: instanceID, text: handoffText)
        } else {
            handoff = nil
        }
        return Draft(text: text, handoff: handoff)
    }

    private static func encodeDraft(_ draft: Draft) -> JSONValue {
        var value: [String: JSONValue] = ["text": .string(draft.text)]
        if let handoff = draft.handoff {
            value["handoff"] = .object(["commandID": .string(handoff.commandID),
                "instanceID": .string(handoff.instanceID), "text": .string(handoff.text)])
        }
        return .object(value)
    }

    private static func validateDraft(text: String, handoff: Draft.Handoff?) throws {
        guard let data = try? JSONEncoder().encode(encodeDraft(Draft(text: text, handoff: handoff))),
              data.count <= maximumDraftBytes else { throw Error.payloadTooLarge }
    }

    private func requireInstance(_ sessionID: String, expected: String) throws {
        let current = try readManifest(sessionID)
        guard current.instanceID == expected else { throw Error.instanceMismatch }
    }

    private func commandFiles(_ sessionID: String) throws -> [String] {
        try cleanupTemporaryFiles(sessionID)
        let names = try enumeratedNames(sessionURL(sessionID), limit: Self.maximumRetainedCommands + 32)
        let files = names.filter { $0.hasPrefix("command-") && $0.hasSuffix(".json") }
        guard files.count <= Self.maximumRetainedCommands else { throw Error.corruptStore }
        return files
    }

    /// Remove only abandoned temp files created by `writeJSON`, while the caller holds the
    /// session mutation lock. Enumeration is capped so malformed directories remain bounded.
    private func cleanupTemporaryFiles(_ sessionID: String) throws {
        let directory = sessionURL(sessionID)
        let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw Error.ioFailure }
        guard let dir = fdopendir(fd) else { close(fd); throw Error.ioFailure }
        defer { closedir(dir) }
        var removed = false
        var visited = 0
        while let entry = readdir(dir) {
            let name = Self.directoryEntryName(entry)
            if name == "." || name == ".." { continue }
            visited += 1
            guard visited <= Self.maximumRetainedCommands * 64 else {
                throw Error.sessionCapacityReached(Self.maximumRetainedCommands * 64)
            }
            guard isStoreTemporaryFilename(name) else { continue }
            let url = directory.appending(path: name)
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) == 0 else {
                if errno == ENOENT { continue }
                throw Error.ioFailure
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
            guard url.path.withCString({ unlink($0) }) == 0 else { throw Error.ioFailure }
            removed = true
        }
        if removed {
            guard fsync(fd) == 0 else { throw Error.ioFailure }
        }
    }

    private func isStoreTemporaryFilename(_ name: String) -> Bool {
        guard name.hasPrefix(".tmp-") else { return false }
        return UUID(uuidString: String(name.dropFirst(".tmp-".count))) != nil
    }

    private func enumeratedNames(_ directory: URL, limit: Int) throws -> [String] {
        let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw Error.ioFailure }
        guard let dir = fdopendir(fd) else { close(fd); throw Error.ioFailure }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = Self.directoryEntryName(entry)
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= limit else {
                throw Error.sessionCapacityReached(limit)
            }
        }
        return names
    }

    private func readCommand(_ url: URL, expectedID: String) throws -> Command {
        let record = try readJSON(url, limit: Self.maximumCommandBytes)
        return try decodeCommandRecord(record, expectedID: expectedID)
    }

    private func decodeCommandRecord(_ record: JSONValue, expectedID: String) throws -> Command {
        guard (try? Self.canonicalCommandID(expectedID)) == expectedID,
              record["commandID"]?.stringValue == expectedID,
              let stageText = record["stage"]?.stringValue, let stage = Command.Stage(rawValue: stageText),
              let instanceID = record["instanceID"]?.stringValue, UUID(uuidString: instanceID) != nil,
              let sequence = record["sequence"]?.intValue, sequence > 0,
              let request = record["request"] else { throw Error.corruptStore }
        let receipt = record["receipt"]
        guard (stage == .settled) == (receipt != nil) else { throw Error.corruptStore }
        return Command(commandID: expectedID, instanceID: instanceID, sequence: sequence,
                       request: request, stage: stage, receipt: receipt)
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: entry.pointee.d_name) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private func encode(_ command: Command) -> JSONValue {
        var value: [String: JSONValue] = ["commandID": .string(command.commandID), "instanceID": .string(command.instanceID),
                                         "sequence": .number(Double(command.sequence)),
                                         "request": command.request,
                                         "stage": .string(command.stage.rawValue)]
        if let receipt = command.receipt { value["receipt"] = receipt }
        return .object(value)
    }

    private func commandURL(_ sessionID: String, _ commandID: String) -> URL {
        sessionURL(sessionID).appending(path: "command-\(commandID).json")
    }

    private func filenameCommandID(from filename: String) -> String {
        String(filename.dropFirst("command-".count).dropLast(".json".count))
    }
    private func sessionURL(_ sessionID: String) -> URL { workersRoot.appending(path: sessionID, directoryHint: .isDirectory) }

    private func pathExists(_ url: URL) throws -> Bool {
        var st = stat()
        if url.path.withCString({ lstat($0, &st) }) == 0 { return true }
        if errno == ENOENT { return false }
        throw Error.ioFailure
    }

    private func isRealDirectory(_ url: URL) throws -> Bool {
        let fd = url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0 {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return false }
            throw Error.ioFailure
        }
        close(fd)
        return true
    }

    private func readJSON(_ url: URL, limit: Int) throws -> JSONValue {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            if errno == ENOENT { throw Error.commandMissing }
            throw Error.ioFailure
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size >= 0, st.st_size <= off_t(limit) else { throw Error.corruptStore }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(16 * 1_024, limit + 1))
        while data.count <= limit {
            let n = read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if n == 0 { break }
            if n < 0 { if errno == EINTR { continue }; throw Error.ioFailure }
            data.append(contentsOf: buffer.prefix(n))
        }
        guard data.count <= limit, let value = JSONValue.parse(data) else { throw Error.corruptStore }
        return value
    }

    private func writeJSON(_ value: JSONValue, to destination: URL, limit: Int) throws {
        let data: Data
        do { data = try JSONEncoder().encode(value) } catch { throw Error.corruptStore }
        guard data.count <= limit else { throw Error.payloadTooLarge }
        let temp = destination.deletingLastPathComponent().appending(path: ".tmp-\(UUID().uuidString)")
        let fd = temp.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard fd >= 0 else { throw Error.ioFailure }
        var good = fchmod(fd, mode_t(0o600)) == 0
        data.withUnsafeBytes { bytes in
            var offset = 0
            while good && offset < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { good = false; break }
                offset += n
            }
        }
        if good { good = fsync(fd) == 0 }
        close(fd)
        guard good else { _ = temp.path.withCString { unlink($0) }; throw Error.ioFailure }
        let renameResult = temp.path.withCString { source in destination.path.withCString { target in rename(source, target) } }
        guard renameResult == 0 else { _ = temp.path.withCString { unlink($0) }; throw Error.ioFailure }
        let dirFD = destination.deletingLastPathComponent().path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard dirFD >= 0 else { throw Error.ioFailure }
        defer { close(dirFD) }
        guard fsync(dirFD) == 0 else { throw Error.ioFailure }
    }

    private static func validatePayload(_ payload: JSONValue, maximum: Int) throws {
        let data: Data
        do { data = try JSONEncoder().encode(payload) } catch { throw Error.corruptStore }
        guard data.count <= maximum else { throw Error.payloadTooLarge }
    }

    private static func isEndControlRequest(_ request: JSONValue) -> Bool {
        let value: JSONValue
        if case .string(let encoded) = request {
            guard let parsed = JSONValue.parse(Data(encoded.utf8)) else { return false }
            value = parsed
        } else {
            value = request
        }
        return value["operation"]?.stringValue == "end"
    }

    private static func validateSessionID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 }) else {
            throw Error.invalidSessionID
        }
    }

    private static func validateUUID(_ id: String, invalid: Error) throws {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id.lowercased() else { throw invalid }
    }

    private static func canonicalCommandID(_ id: String) throws -> String {
        guard let uuid = UUID(uuidString: id) else { throw Error.invalidCommandID }
        return uuid.uuidString.lowercased()
    }
}

public final class MuseWorkerOwnerLease: @unchecked Sendable {
    public let sessionID: String
    public let instanceID: String
    private let descriptorLock = NSLock()
    private var descriptor: Int32

    fileprivate init(fileDescriptor: Int32, sessionID: String, instanceID: String) {
        descriptor = fileDescriptor
        self.sessionID = sessionID
        self.instanceID = instanceID
    }

    public func release() {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
