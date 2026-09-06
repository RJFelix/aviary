import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct ServiceBackedDraftCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue) }
}

/// The current editor contents and the optional durable handoff marker for one exact attachment.
public struct ServiceBackedDraftSnapshot: Codable, Hashable, Sendable {
    public static let schemaVersion = 2
    public static let maximumGeneration = 1_000_000_000

    public let schemaVersion: Int
    /// Monotonically increasing per-record version used as the local file CAS token.
    public let generation: Int
    public let text: String
    public let handoff: ServiceBackedDraftHandoff?

    public init(text: String, handoff: ServiceBackedDraftHandoff? = nil) throws {
        try self.init(text: text, handoff: handoff, generation: 1)
    }

    init(
        text: String, handoff: ServiceBackedDraftHandoff?, generation: Int
    ) throws {
        guard text.utf8.count <= WorkServiceBounds.maxCommandValueCharacters else {
            throw ServiceBackedDraftError.tooLarge
        }
        guard generation > 0, generation <= Self.maximumGeneration else {
            throw ServiceBackedDraftError.invalid
        }
        self.schemaVersion = Self.schemaVersion
        self.generation = generation
        self.text = text
        self.handoff = handoff
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: ServiceBackedDraftCodingKey.self)
        let expected = Set(["schemaVersion", "generation", "text", "handoff"])
        guard Set(dynamic.allKeys.map(\.stringValue)) == expected else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "invalid draft snapshot fields"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container,
                debugDescription: "unsupported draft snapshot schema")
        }
        let generation = try container.decode(Int.self, forKey: .generation)
        guard generation > 0, generation <= Self.maximumGeneration else {
            throw DecodingError.dataCorruptedError(
                forKey: .generation, in: container, debugDescription: "invalid draft generation")
        }
        let text = try container.decode(String.self, forKey: .text)
        guard text.utf8.count <= WorkServiceBounds.maxCommandValueCharacters else {
            throw DecodingError.dataCorruptedError(
                forKey: .text, in: container, debugDescription: "draft text exceeds bound")
        }
        self.schemaVersion = Self.schemaVersion
        self.generation = generation
        self.text = text
        self.handoff = try container.decodeIfPresent(
            ServiceBackedDraftHandoff.self, forKey: .handoff)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generation, forKey: .generation)
        try container.encode(text, forKey: .text)
        // Encode the optional key explicitly as null when there is no handoff so the strict
        // decoder sees one stable record shape rather than a synthesized omitted field.
        try container.encode(handoff, forKey: .handoff)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generation, text, handoff
    }
}

/// A crash-recovery marker for a command submitted from one attachment's draft.
///
/// It deliberately stores only the submitted UTF-8 digest, never a second copy of the submitted
/// text. The snapshot's current text may be edited while the marker is pending, so resolution can
/// clear only the text that is still byte-identical to the submitted command.
public struct ServiceBackedDraftHandoff: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let commandID: String
    public let kind: WorkServiceCommandKind
    public let submittedTextDigest: String

    public init(text: String, kind: WorkServiceCommandKind, commandID: String) throws {
        guard text.utf8.count <= WorkServiceBounds.maxCommandValueCharacters else {
            throw ServiceBackedDraftError.tooLarge
        }
        try self.init(
            commandID: commandID, kind: kind, submittedTextDigest: Self.digest(of: text))
    }

    public init(
        commandID: String, kind: WorkServiceCommandKind, submittedTextDigest: String
    ) throws {
        guard Self.validCommandID(commandID), Self.validDigest(submittedTextDigest) else {
            throw ServiceBackedDraftError.invalid
        }
        self.schemaVersion = Self.schemaVersion
        self.commandID = commandID
        self.kind = kind
        self.submittedTextDigest = submittedTextDigest
    }

    /// Stable digest representation used by the handoff protocol.
    public static func digest(of text: String) -> String {
        let digest = AviarySHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "sha256:" + digest
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: ServiceBackedDraftCodingKey.self)
        let expected = Set(["schemaVersion", "commandID", "kind", "submittedTextDigest"])
        guard Set(dynamic.allKeys.map(\.stringValue)) == expected else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "invalid draft handoff fields"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container,
                debugDescription: "unsupported draft handoff schema")
        }
        let commandID = try container.decode(String.self, forKey: .commandID)
        let kind = try container.decode(WorkServiceCommandKind.self, forKey: .kind)
        let digest = try container.decode(String.self, forKey: .submittedTextDigest)
        guard Self.validCommandID(commandID), Self.validDigest(digest) else {
            throw DecodingError.dataCorruptedError(
                forKey: .submittedTextDigest, in: container,
                debugDescription: "invalid draft handoff bounds")
        }
        self.schemaVersion = Self.schemaVersion
        self.commandID = commandID
        self.kind = kind
        self.submittedTextDigest = digest
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, commandID, kind, submittedTextDigest
    }

    private static func validCommandID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= WorkServiceBounds.maxIdentityCharacters
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func validDigest(_ value: String) -> Bool {
        let prefix = "sha256:"
        guard value.hasPrefix(prefix), value.utf8.count == prefix.utf8.count + 64 else {
            return false
        }
        return value.dropFirst(prefix.count).unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x61 && scalar.value <= 0x66)
        }
    }
}

/// Canonical disposition of a persisted command handoff after a GUI restart.
///
/// Absence is intentionally unresolved: a bounded projection cannot prove that a command was
/// never admitted.  This classifier is pure and requires the exact attachment-qualified
/// projection before it considers either the Work command ledger or a controller pending record.
public enum ServiceBackedDraftHandoffDisposition: Equatable, Sendable {
    case accepted
    case rejected
    case unresolved

    /// Classify only evidence belonging to this exact client/Work/Session attachment.
    public static func classify(
        _ handoff: ServiceBackedDraftHandoff,
        key: ServiceAttachmentKey,
        projection: WorkServiceAttachedWorkProjection
    ) -> Self {
        let workJournal = JournalRef.work(key.workSession.work)
        let attachment = projection.attachment
        guard key.isValid,
              projection.isCanonical,
              projection.descriptor.work == key.workSession.work,
              projection.descriptor.journal == workJournal,
              projection.workCursor.journal == workJournal,
              projection.sessionCursor.journal == key.workSession.sessionJournal,
              attachment.client == key.client,
              attachment.attachment == key.clientAttachment,
              attachment.session == key.workSession.session,
              attachment.sessionJournal == key.workSession.sessionJournal,
              attachment.sessionAttachment == key.workSession.sessionAttachment,
              projection.descriptor.sessionAttachments.contains(where: {
                  $0.session == key.workSession.session
                      && $0.sessionJournal == key.workSession.sessionJournal
                      && $0.sessionAttachment == key.workSession.sessionAttachment
                      && $0.isAttached
              }) else {
            return .unresolved
        }

        let canonicalCommandID = WorkServiceCommandLedgerIdentity.commandID(
            client: key.client, commandID: handoff.commandID)
        if let command = projection.workSnapshot.commands[canonicalCommandID] {
            guard command.command.commandID == canonicalCommandID,
                  command.command.client == key.client,
                  command.command.sessionAttachment == key.workSession.sessionAttachment,
                  let causalCursor = command.command.causalCursor,
                  causalCursor.journal == workJournal,
                  causalCursor.sequence >= 0,
                  causalCursor.sequence <= projection.workCursor.sequence else {
                return .unresolved
            }
            switch command.state {
            case .accepted, .delivered:
                return .accepted
            case .rejected, .notDelivered:
                return .rejected
            case .indeterminate:
                return .unresolved
            }
        }

        if let pending = projection.pendingCommand {
            guard pending.commandID == handoff.commandID,
                  pending.client == key.client,
                  pending.attachment == key.clientAttachment,
                  pending.sessionAttachment == key.workSession.sessionAttachment,
                  pending.causalWorkCursor.journal == workJournal,
                  pending.causalWorkCursor.sequence >= 0,
                  pending.causalWorkCursor.sequence <= projection.workCursor.sequence,
                  pending.kind == handoff.kind,
                  pending.valueDigest == handoff.submittedTextDigest else {
                return .unresolved
            }
            switch pending.state {
            case .stale:
                return .rejected
            case .indeterminate, .awaitingCanonicalEvidence:
                return .unresolved
            }
        }
        return .unresolved
    }
}

/// Durable GUI draft text for exactly one service attachment.
///
/// This is deliberately a synchronous, `Sendable` file primitive rather than an in-memory UI
/// object. Every operation takes the per-directory advisory lock, so callers may use it from a
/// detached task or another process without holding an actor or view alive. The Work Host's
/// canonical journal remains authoritative; this store only preserves text that has not yet
/// been submitted.
public struct ServiceBackedDraftStore: Sendable {
    public static let schemaVersion = 3
    public static let maximumRecordBytes = 64 * 1_024
    public static let maximumRecords = 32
    /// Bound directory enumeration as well as retained records. Junk entries cannot force an
    /// unbounded array or scan before a caller reaches the record cap.
    public static let maximumDirectoryEntries = maximumRecords * 8

    /// The directory contains only Aviary-owned, mode-0600 JSON records and a mode-0600 lock.
    public let directory: URL
    /// The record URL is useful to diagnostics/tests for checking permissions. Its final
    /// component is a digest of the complete attachment-qualified key, never an identity.
    public let url: URL

    private let expectedKey: ServiceAttachmentKey
    private let homeRoot: URL

    public init(home: AgentHome, key: ServiceAttachmentKey) throws {
        guard key.isValid else { throw ServiceBackedDraftError.invalid }
        let keyData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            keyData = try encoder.encode(key)
        } catch {
            throw ServiceBackedDraftError.invalid
        }
        let digest = AviarySHA256.hash(data: Data("service-draft-v1\0".utf8) + keyData)
            .map { String(format: "%02x", $0) }.joined()
        self.expectedKey = key
        self.homeRoot = home.root
        self.directory = home.root
            .appending(path: "work-service-clients", directoryHint: .isDirectory)
            .appending(path: "drafts", directoryHint: .isDirectory)
        self.url = directory.appending(
            path: "draft-v1." + digest + ".json", directoryHint: .notDirectory)
        try prepareDirectory()
    }

    /// Return the exact editor text and any pending command handoff, or `nil` when no record is
    /// retained.
    public func load() throws -> ServiceBackedDraftSnapshot? {
        try prepareDirectory()
        return try withLock {
            return try readLocked()?.snapshot
        }
    }

    /// Replace the current editor text idempotently while preserving an existing handoff marker.
    /// Empty text removes the record only when no command handoff is pending.
    @discardableResult
    public func replace(
        _ text: String, expectedGeneration: Int?
    ) throws -> ServiceBackedDraftSnapshot? {
        guard text.utf8.count <= WorkServiceBounds.maxCommandValueCharacters else {
            throw ServiceBackedDraftError.tooLarge
        }
        try prepareDirectory()
        return try withLock {
            let records = try recordURLsLocked()
            let existing: Record?
            var repairingCorrupt = false
            do {
                existing = try readLocked()
            } catch ServiceBackedDraftError.corrupt {
                // Draft text is disposable Aviary-owned state. An explicit edit may repair a
                // malformed exact record, but only after proving it is our regular mode-0600
                // file. Symlinks, insecure modes, and oversized files remain fail-closed.
                guard try repairableTargetLocked() else { throw ServiceBackedDraftError.corrupt }
                existing = nil
                repairingCorrupt = true
            }
            if repairingCorrupt {
                guard expectedGeneration == nil else { throw ServiceBackedDraftError.conflict }
            } else if let existing {
                guard expectedGeneration == existing.snapshot.generation else {
                    throw ServiceBackedDraftError.conflict
                }
            } else if expectedGeneration != nil {
                // A nil token is reserved for create or explicit repair of an unusable regular
                // 0600 row. It cannot satisfy a stale token after an external deletion.
                guard try repairableTargetLocked() else { throw ServiceBackedDraftError.conflict }
            }
            if text.isEmpty {
                if let existing, existing.snapshot.handoff != nil {
                    if existing.snapshot.text.isEmpty { return existing.snapshot }
                    let snapshot = try ServiceBackedDraftSnapshot(
                        text: text, handoff: existing.snapshot.handoff,
                        generation: try nextGeneration(existing.snapshot.generation))
                    if snapshot == existing.snapshot { return existing.snapshot }
                    try atomicallyWrite(try encoded(Record(key: expectedKey, snapshot: snapshot)))
                    return snapshot
                }
                let targetExists: Bool
                if existing != nil {
                    targetExists = true
                } else {
                    targetExists = try repairableTargetLocked()
                }
                guard targetExists else { return nil }
                guard unlink(url.path) == 0 else {
                    if errno == ENOENT { return nil }
                    throw ServiceBackedDraftError.corrupt
                }
                try synchronizeDirectory()
                return nil
            }

            if let existing {
                guard existing.key == expectedKey else { throw ServiceBackedDraftError.conflict }
                if existing.snapshot.text == text { return existing.snapshot }
                let snapshot = try ServiceBackedDraftSnapshot(
                    text: text, handoff: existing.snapshot.handoff,
                    generation: try nextGeneration(existing.snapshot.generation))
                if existing.snapshot == snapshot { return existing.snapshot }
                try atomicallyWrite(try encoded(Record(key: expectedKey, snapshot: snapshot)))
                return snapshot
            } else if !records.contains(where: { $0.path == url.path }),
                      records.count >= Self.maximumRecords {
                throw ServiceBackedDraftError.capacity
            }
            let snapshot = try ServiceBackedDraftSnapshot(
                text: text, handoff: nil, generation: 1)
            let data = try encoded(Record(key: expectedKey, snapshot: snapshot))
            guard data.count <= Self.maximumRecordBytes else {
                throw ServiceBackedDraftError.tooLarge
            }
            try atomicallyWrite(data)
            return try ServiceBackedDraftSnapshot(
                text: text, handoff: nil, generation: 1)
        }
    }

    /// Atomically mark text as submitted before crossing into the Work service. Repeating the
    /// exact marker is idempotent and preserves edits made after the first submission; any
    /// conflicting marker is rejected until the existing handoff is resolved.
    @discardableResult
    public func beginHandoff(
        text: String, kind: WorkServiceCommandKind, commandID: String,
        expectedGeneration: Int?
    ) throws -> ServiceBackedDraftSnapshot {
        let handoff = try ServiceBackedDraftHandoff(text: text, kind: kind, commandID: commandID)
        try prepareDirectory()
        return try withLock {
            let records = try recordURLsLocked()
            let existing: Record?
            let targetPresent: Bool
            do {
                existing = try readLocked()
                targetPresent = existing != nil
            } catch ServiceBackedDraftError.corrupt {
                throw ServiceBackedDraftError.corrupt
            }
            if let existing {
                guard existing.key == expectedKey else { throw ServiceBackedDraftError.conflict }
                guard expectedGeneration == existing.snapshot.generation else {
                    throw ServiceBackedDraftError.conflict
                }
                if let current = existing.snapshot.handoff {
                    guard current == handoff else { throw ServiceBackedDraftError.conflict }
                    return existing.snapshot
                }
            } else {
                guard expectedGeneration == nil, !targetPresent else {
                    throw ServiceBackedDraftError.conflict
                }
                if records.count >= Self.maximumRecords {
                    throw ServiceBackedDraftError.capacity
                }
            }
            let snapshot = try ServiceBackedDraftSnapshot(
                text: text, handoff: handoff,
                generation: try nextGeneration(existing?.snapshot.generation ?? 0))
            try atomicallyWrite(try encoded(Record(key: expectedKey, snapshot: snapshot)))
            return snapshot
        }
    }

    /// Resolve a submitted command exactly once. Accepted delivery clears the current editor
    /// text only when its digest still matches the submitted bytes; an edited-next draft is
    /// preserved. Rejected delivery always preserves current text. The marker is removed either
    /// way, and an empty marker-free record is removed durably.
    @discardableResult
    public func resolveHandoff(
        commandID: String, accepted: Bool, currentText: String,
        expectedGeneration: Int
    ) throws -> ServiceBackedDraftSnapshot? {
        guard !commandID.isEmpty,
              commandID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              !commandID.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ServiceBackedDraftError.invalid
        }
        guard currentText.utf8.count <= WorkServiceBounds.maxCommandValueCharacters else {
            throw ServiceBackedDraftError.tooLarge
        }
        try prepareDirectory()
        return try withLock {
            // A caller reaches this method only with a durable marker it previously loaded.
            // Missing or already-resolved state is not proof that the command was handled; fail
            // closed instead of treating an unexplained unlink as successful resolution.
            guard let existing = try readLocked() else { throw ServiceBackedDraftError.corrupt }
            guard existing.snapshot.generation == expectedGeneration else {
                throw ServiceBackedDraftError.conflict
            }
            guard let handoff = existing.snapshot.handoff else {
                throw ServiceBackedDraftError.conflict
            }
            guard handoff.commandID == commandID else {
                throw ServiceBackedDraftError.conflict
            }
            // The generation is the CAS witness for the GUI's current editor snapshot. A second
            // process that edited the row after this GUI read it necessarily changed the locked
            // generation and is rejected above. When the generation still matches, currentText
            // is the GUI's legitimate newer edit and is folded into this same locked transaction.
            let shouldClearText = accepted
                && ServiceBackedDraftHandoff.digest(of: currentText)
                    == handoff.submittedTextDigest
            let resultingText = shouldClearText ? "" : currentText
            if resultingText.isEmpty {
                guard unlink(url.path) == 0 else {
                    if errno == ENOENT { return nil }
                    throw ServiceBackedDraftError.corrupt
                }
                try synchronizeDirectory()
                return nil
            }
            let snapshot = try ServiceBackedDraftSnapshot(
                text: resultingText, handoff: nil,
                generation: try nextGeneration(existing.snapshot.generation))
            try atomicallyWrite(try encoded(Record(key: expectedKey, snapshot: snapshot)))
            return snapshot
        }
    }

    /// Explicit spelling for clients that model draft deletion separately from replacement.
    @discardableResult
    public func clear(expectedGeneration: Int?) throws -> ServiceBackedDraftSnapshot? {
        try replace("", expectedGeneration: expectedGeneration)
    }

    private struct Record: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let key: ServiceAttachmentKey
        let snapshot: ServiceBackedDraftSnapshot

        enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion, key, snapshot
        }

        init(key: ServiceAttachmentKey, snapshot: ServiceBackedDraftSnapshot) {
            self.schemaVersion = ServiceBackedDraftStore.schemaVersion
            self.key = key
            self.snapshot = snapshot
        }

        init(from decoder: Decoder) throws {
            let dynamic = try decoder.container(keyedBy: ServiceBackedDraftCodingKey.self)
            let expected = Set(CodingKeys.allCases.map(\.rawValue))
            guard Set(dynamic.allKeys.map(\.stringValue)) == expected else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid draft record fields"))
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(Int.self, forKey: .schemaVersion)
                    == ServiceBackedDraftStore.schemaVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion, in: container,
                    debugDescription: "unsupported draft record schema")
            }
            self.schemaVersion = ServiceBackedDraftStore.schemaVersion
            self.key = try container.decode(ServiceAttachmentKey.self, forKey: .key)
            self.snapshot = try container.decode(ServiceBackedDraftSnapshot.self, forKey: .snapshot)
        }
    }

    private func encoded(_ record: Record) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return try encoder.encode(record) }
        catch { throw ServiceBackedDraftError.corrupt }
    }

    private func nextGeneration(_ generation: Int) throws -> Int {
        guard generation >= 0, generation < ServiceBackedDraftSnapshot.maximumGeneration else {
            throw ServiceBackedDraftError.corrupt
        }
        return generation + 1
    }

    private func readLocked() throws -> Record? {
        let fd = url.path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ServiceBackedDraftError.corrupt
        }
        defer { _ = AviaryPOSIX.close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              (information.st_mode & mode_t(0o777)) == mode_t(0o600),
              information.st_size >= 0,
              information.st_size <= off_t(Self.maximumRecordBytes) else {
            throw ServiceBackedDraftError.corrupt
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = AviaryPOSIX.read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count <= Self.maximumRecordBytes - count else {
                    throw ServiceBackedDraftError.corrupt
                }
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw ServiceBackedDraftError.corrupt
            }
        }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: data) }
        catch { throw ServiceBackedDraftError.corrupt }
        guard record.key.isValid,
              record.snapshot.text.utf8.count <= WorkServiceBounds.maxCommandValueCharacters,
              url.lastPathComponent == Self.url(for: record.key, directory: directory)
                    .lastPathComponent else {
            throw ServiceBackedDraftError.corrupt
        }
        guard record.key == expectedKey else { throw ServiceBackedDraftError.conflict }
        return record
    }

    /// Count candidate records without decoding siblings. Reads and repairs are row-local to the
    /// exact attachment key; only the bounded cardinality check looks beyond that row.
    private func recordURLsLocked() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            throw ServiceBackedDraftError.corrupt
        }
        var records: [URL] = []
        var visited = 0
        while let value = enumerator.nextObject() as? URL {
            visited += 1
            guard visited <= Self.maximumDirectoryEntries else {
                throw ServiceBackedDraftError.capacity
            }
            let resources: URLResourceValues
            do { resources = try value.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
            catch { throw ServiceBackedDraftError.corrupt }
            guard resources.isDirectory != true else { throw ServiceBackedDraftError.corrupt }
            if value.pathExtension == "json" { records.append(value) }
        }
        guard records.count <= Self.maximumRecords else { throw ServiceBackedDraftError.capacity }
        return records
    }

    private func repairableTargetLocked() throws -> Bool {
        let fd = url.path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            if errno == ENOENT { return false }
            throw ServiceBackedDraftError.corrupt
        }
        defer { _ = AviaryPOSIX.close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              (information.st_mode & mode_t(0o777)) == mode_t(0o600),
              information.st_size >= 0,
              information.st_size <= off_t(Self.maximumRecordBytes) else {
            return false
        }
        return true
    }

    private func prepareDirectory() throws {
        let clients = homeRoot.appending(
            path: "work-service-clients", directoryHint: .isDirectory)
        let candidates = [homeRoot, clients, directory]
        for (index, candidate) in candidates.enumerated() {
            var information = stat()
            if lstat(candidate.path, &information) == 0 {
                let mode = information.st_mode & mode_t(0o777)
                let acceptableMode = index == 0
                    ? (mode & mode_t(0o022)) == 0
                    : mode == mode_t(0o700)
                guard (information.st_mode & S_IFMT) == S_IFDIR,
                      information.st_uid == geteuid(),
                      acceptableMode else {
                    throw ServiceBackedDraftError.corrupt
                }
            } else {
                guard errno == ENOENT else { throw ServiceBackedDraftError.corrupt }
                do {
                    try FileManager.default.createDirectory(
                        at: candidate, withIntermediateDirectories: index == 0,
                        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
                } catch {
                    // Another GUI/process may have won the create-if-absent race. The
                    // postcondition below is authoritative; unrelated failures still fail
                    // closed when the directory cannot be revalidated.
                }
                guard lstat(candidate.path, &information) == 0,
                      (information.st_mode & S_IFMT) == S_IFDIR,
                      information.st_uid == geteuid(),
                      (information.st_mode & mode_t(0o777)) == mode_t(0o700) else {
                    throw ServiceBackedDraftError.corrupt
                }
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = directory.appending(
            path: ".drafts.lock", directoryHint: .notDirectory)
        let fd = lockURL.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: mode_t(0o600))
        }
        guard fd >= 0 else { throw ServiceBackedDraftError.corrupt }
        defer { _ = AviaryPOSIX.close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              (information.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw ServiceBackedDraftError.corrupt
        }
        return try body()
    }

    private func atomicallyWrite(_ data: Data) throws {
        let temporary = directory.appending(
            path: ".draft-v1.tmp-" + UUID().uuidString,
            directoryHint: .notDirectory)
        defer { _ = unlink(temporary.path) }
        let fd = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw ServiceBackedDraftError.corrupt }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = AviaryPOSIX.write(fd, base.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && errno == EINTR { continue }
                    else { throw ServiceBackedDraftError.corrupt }
                }
            }
            guard fsync(fd) == 0 else { throw ServiceBackedDraftError.corrupt }
        } catch {
            _ = AviaryPOSIX.close(fd)
            throw error
        }
        guard AviaryPOSIX.close(fd) == 0 else { throw ServiceBackedDraftError.corrupt }
        var information = stat()
        if lstat(url.path, &information) == 0 {
            guard (information.st_mode & S_IFMT) == S_IFREG,
                  information.st_uid == geteuid(),
                  (information.st_mode & mode_t(0o777)) == mode_t(0o600) else {
                throw ServiceBackedDraftError.corrupt
            }
        } else if errno != ENOENT { throw ServiceBackedDraftError.corrupt }
        guard rename(temporary.path, url.path) == 0 else {
            throw ServiceBackedDraftError.corrupt
        }
        try synchronizeDirectory()
    }

    private func synchronizeDirectory() throws {
        let fd = directory.path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw ServiceBackedDraftError.corrupt }
        defer { _ = AviaryPOSIX.close(fd) }
        guard fsync(fd) == 0 else { throw ServiceBackedDraftError.corrupt }
    }

    private static func url(for key: ServiceAttachmentKey, directory: URL) -> URL {
        let keyData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            keyData = (try? encoder.encode(key)) ?? Data()
        }
        let digest = AviarySHA256.hash(data: Data("service-draft-v1\0".utf8) + keyData)
            .map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "draft-v1." + digest + ".json", directoryHint: .notDirectory)
    }
}

public enum ServiceBackedDraftError: Error, Equatable, Sendable {
    case invalid
    case conflict
    case corrupt
    case tooLarge
    case capacity
}
