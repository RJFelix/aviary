import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The small set of durable states a GUI-launched chat can occupy before it is represented by
/// canonical Work/Session state.  This is intentionally not a general workflow enum: unknown
/// states must never be guessed at a recovery boundary.
public enum PendingChatPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case saved
    case preparing
    case blocked
    case awaitingAcceptance
}

/// A failure classification safe to retain and show after a crash.  Raw provider errors,
/// credentials, response bodies, and paths supplied by a remote peer do not belong here.
public enum PendingChatFailureKind: String, Codable, CaseIterable, Hashable, Sendable {
    case hostUnavailable
    case workspaceUnavailable
    case providerUnavailable
    case authorizationRequired
    /// Create was rejected by a stale control cursor before Work admission. The saved prompt
    /// remains valid and can be retried with a fresh attempt identity.
    case staleCreate
    case invalidRequest
    case unknown
}

/// One GUI chat intent retained before any Work Host, workspace, model, or provider preflight.
/// The prompt is the user's exact UTF-8 input; it is never truncated to fit a downstream model
/// or service limit. `generation` is the local compare-and-swap token for this row.
public struct PendingChat: Codable, Hashable, Sendable, Identifiable {
    public static let schemaVersion = 1
    public static let maximumPromptBytes = 64 * 1_024
    public static let maximumGeneration = 1_000_000_000
    public static let maximumPathBytes = 4 * 1_024
    public static let maximumMetadataBytes = 512

    public let schemaVersion: Int
    public let generation: Int
    public let id: UUID
    public let createdAt: Date
    public let prompt: String
    /// The selected working-directory path. It is retained as user-owned local intent, not
    /// resolved or validated by this store.
    public let cwd: String
    public let providerID: String?
    public let modelID: String?
    public let thinkingLevel: String?
    public let title: String?
    public let noContextFiles: Bool
    public let recordPayloads: Bool
    public let phase: PendingChatPhase
    public let failureKind: PendingChatFailureKind?
    public let attemptCommandID: UUID
    public let startCommandID: String
    /// Exact host-minted identity once Create has been accepted. The key carries client,
    /// client-attachment, Work, Session, Session journal, and Session attachment together.
    public let createdAssociation: ServiceAttachmentKey?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        prompt: String,
        cwd: String,
        providerID: String? = nil,
        modelID: String? = nil,
        thinkingLevel: String? = nil,
        title: String? = nil,
        noContextFiles: Bool = false,
        recordPayloads: Bool = false,
        phase: PendingChatPhase = .saved,
        failureKind: PendingChatFailureKind? = nil,
        attemptCommandID: UUID = UUID(),
        startCommandID: String? = nil,
        createdAssociation: ServiceAttachmentKey? = nil
    ) throws {
        try Self.validate(
            id: id, createdAt: createdAt, prompt: prompt, cwd: cwd,
            providerID: providerID, modelID: modelID, thinkingLevel: thinkingLevel, title: title,
            attemptCommandID: attemptCommandID, startCommandID: startCommandID ?? "start-\(id.uuidString.lowercased())",
            createdAssociation: createdAssociation, generation: 1)
        self.schemaVersion = Self.schemaVersion
        self.generation = 1
        self.id = id
        self.createdAt = createdAt
        self.prompt = prompt
        self.cwd = cwd
        self.providerID = providerID
        self.modelID = modelID
        self.thinkingLevel = thinkingLevel
        self.title = title
        self.noContextFiles = noContextFiles
        self.recordPayloads = recordPayloads
        self.phase = phase
        self.failureKind = failureKind
        self.attemptCommandID = attemptCommandID
        self.startCommandID = startCommandID ?? "start-\(id.uuidString.lowercased())"
        self.createdAssociation = createdAssociation
    }

    /// Return a changed value suitable for `PendingChatStore.update`. The store, not this value
    /// type, assigns the next generation, so a stale snapshot cannot manufacture a newer token.
    public func changing(
        phase: PendingChatPhase? = nil,
        failureKind: PendingChatFailureKind? = nil,
        attemptCommandID: UUID? = nil,
        createdAssociation: ServiceAttachmentKey? = nil,
        title: String? = nil
    ) throws -> PendingChat {
        try Self.make(
            generation: generation, id: id, createdAt: createdAt, prompt: prompt, cwd: cwd,
            providerID: providerID, modelID: modelID, thinkingLevel: thinkingLevel,
            title: title ?? self.title, noContextFiles: noContextFiles,
            recordPayloads: recordPayloads, phase: phase ?? self.phase,
            failureKind: failureKind ?? self.failureKind,
            attemptCommandID: attemptCommandID ?? self.attemptCommandID,
            startCommandID: startCommandID,
            createdAssociation: createdAssociation ?? self.createdAssociation)
    }

    /// Build an edited, unsent snapshot while retaining the exact chat identity and start
    /// command. Editing is only meaningful before Create is accepted; the store enforces the
    /// same rule again under its lock when this value is saved.
    public func edited(
        prompt: String,
        cwd: String,
        providerID: String?,
        modelID: String?,
        thinkingLevel: String? = nil,
        title: String? = nil,
        noContextFiles: Bool = false,
        recordPayloads: Bool = false
    ) throws -> PendingChat {
        guard phase == .saved || phase == .blocked, createdAssociation == nil else {
            throw PendingChatError.conflict
        }
        return try PendingChat(
            id: id, createdAt: createdAt, prompt: prompt, cwd: cwd,
            providerID: providerID, modelID: modelID, thinkingLevel: thinkingLevel,
            title: title, noContextFiles: noContextFiles, recordPayloads: recordPayloads,
            phase: .saved, failureKind: nil, attemptCommandID: attemptCommandID,
            startCommandID: startCommandID)
    }

    /// Whether this exact saved launch has crossed the canonical input-delivery boundary.
    /// Association or command acceptance alone is not delivery, and another user message in the
    /// same Session must never retire this pending intent.
    public func hasCanonicalDelivery(
        in projection: WorkServiceAttachedWorkProjection
    ) -> Bool {
        guard let association = createdAssociation,
              projection.isCanonical,
              ServiceAttachmentKey(
                work: projection.descriptor.work,
                attachment: projection.attachment) == association else { return false }

        let commandID = WorkServiceCommandLedgerIdentity.commandID(
            client: association.client, commandID: startCommandID)
        guard let command = projection.workSnapshot.commands[commandID],
              command.command.commandID == commandID,
              command.command.client == association.client,
              command.command.sessionAttachment == association.workSession.sessionAttachment,
              command.commandKind == .start,
              command.state == .delivered else { return false }

        let delivery = CanonicalInputDeliveryProjection(
            workSnapshot: projection.workSnapshot,
            sessionSnapshot: projection.sessionSnapshot,
            workSourceCompleteness: projection.workSourceCompleteness,
            sessionSourceCompleteness: projection.sessionSourceCompleteness,
            workOmissions: projection.workOmissions,
            sessionOmissions: projection.sessionOmissions)
        let rows = delivery.rows.filter { $0.commandID == commandID }
        guard delivery.isCanonical, delivery.omissions.isEmpty, rows.count == 1,
              let row = rows.first,
              row.state == .delivered,
              row.issue == nil,
              row.commandKind == .start,
              row.client == association.client,
              row.sessionAttachment == association.workSession.sessionAttachment,
              row.acceptanceEvent == command.acceptanceEventRef,
              row.deliveryEvent == command.deliveryEventRef,
              let messageEvent = row.messageEvent else { return false }

        let sessionMessages = projection.sessionSnapshot.messageHistory.isEmpty
            ? projection.sessionSnapshot.messages : projection.sessionSnapshot.messageHistory
        let messages = sessionMessages.filter { $0.sourceEvent == messageEvent }
        guard messages.count == 1, let message = messages.first else { return false }
        return message.role == "user"
            && message.text == prompt
            && message.client == association.client
            && message.sessionAttachment == association.workSession.sessionAttachment
            && message.causedBy == row.acceptanceEvent
    }

    private static func make(
        generation: Int, id: UUID, createdAt: Date, prompt: String, cwd: String,
        providerID: String?, modelID: String?, thinkingLevel: String?, title: String?,
        noContextFiles: Bool, recordPayloads: Bool, phase: PendingChatPhase,
        failureKind: PendingChatFailureKind?, attemptCommandID: UUID, startCommandID: String,
        createdAssociation: ServiceAttachmentKey?
    ) throws -> PendingChat {
        try validate(
            id: id, createdAt: createdAt, prompt: prompt, cwd: cwd,
            providerID: providerID, modelID: modelID, thinkingLevel: thinkingLevel, title: title,
            attemptCommandID: attemptCommandID, startCommandID: startCommandID,
            createdAssociation: createdAssociation, generation: generation)
        let value = PendingChat(
            schemaVersion: Self.schemaVersion, generation: generation, id: id,
            createdAt: createdAt, prompt: prompt, cwd: cwd, providerID: providerID,
            modelID: modelID, thinkingLevel: thinkingLevel, title: title,
            noContextFiles: noContextFiles, recordPayloads: recordPayloads, phase: phase,
            failureKind: failureKind, attemptCommandID: attemptCommandID,
            startCommandID: startCommandID, createdAssociation: createdAssociation)
        return value
    }

    private init(
        schemaVersion: Int, generation: Int, id: UUID, createdAt: Date, prompt: String,
        cwd: String, providerID: String?, modelID: String?, thinkingLevel: String?, title: String?,
        noContextFiles: Bool, recordPayloads: Bool, phase: PendingChatPhase,
        failureKind: PendingChatFailureKind?, attemptCommandID: UUID, startCommandID: String,
        createdAssociation: ServiceAttachmentKey?
    ) {
        self.schemaVersion = schemaVersion; self.generation = generation; self.id = id
        self.createdAt = createdAt; self.prompt = prompt; self.cwd = cwd
        self.providerID = providerID; self.modelID = modelID; self.thinkingLevel = thinkingLevel
        self.title = title; self.noContextFiles = noContextFiles; self.recordPayloads = recordPayloads
        self.phase = phase; self.failureKind = failureKind
        self.attemptCommandID = attemptCommandID; self.startCommandID = startCommandID
        self.createdAssociation = createdAssociation
    }

    private static func validate(
        id: UUID, createdAt: Date, prompt: String, cwd: String,
        providerID: String?, modelID: String?, thinkingLevel: String?, title: String?,
        attemptCommandID: UUID, startCommandID: String, createdAssociation: ServiceAttachmentKey?,
        generation: Int
    ) throws {
        guard generation > 0, generation <= maximumGeneration,
              createdAt.timeIntervalSince1970.isFinite,
              prompt.utf8.count <= maximumPromptBytes,
              !prompt.unicodeScalars.contains(where: { $0.value == 0 }),
              !cwd.isEmpty, cwd.utf8.count <= maximumPathBytes,
              !cwd.unicodeScalars.contains(where: { $0.value == 0 }),
              validMetadata(providerID), validMetadata(modelID), validMetadata(thinkingLevel),
              validMetadata(title), !startCommandID.isEmpty,
              startCommandID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              !startCommandID.unicodeScalars.contains(where: { $0.value == 0 }),
              createdAssociation?.isValid ?? true else { throw PendingChatError.invalid }
        _ = id; _ = attemptCommandID
    }

    private static func validMetadata(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= maximumMetadataBytes
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generation, id, createdAt, prompt, cwd, providerID, modelID
        case thinkingLevel, title, noContextFiles, recordPayloads, phase, failureKind
        case attemptCommandID, startCommandID, createdAssociation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c,
                debugDescription: "unsupported pending chat schema")
        }
        let generation = try c.decode(Int.self, forKey: .generation)
        let id = try c.decode(UUID.self, forKey: .id)
        let createdAt = try c.decode(Date.self, forKey: .createdAt)
        let prompt = try c.decode(String.self, forKey: .prompt)
        let cwd = try c.decode(String.self, forKey: .cwd)
        let providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        let modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        let thinkingLevel = try c.decodeIfPresent(String.self, forKey: .thinkingLevel)
        let title = try c.decodeIfPresent(String.self, forKey: .title)
        let noContextFiles = try c.decode(Bool.self, forKey: .noContextFiles)
        let recordPayloads = try c.decode(Bool.self, forKey: .recordPayloads)
        let phase = try c.decode(PendingChatPhase.self, forKey: .phase)
        let failureKind = try c.decodeIfPresent(PendingChatFailureKind.self, forKey: .failureKind)
        let attempt = try c.decode(UUID.self, forKey: .attemptCommandID)
        let start = try c.decode(String.self, forKey: .startCommandID)
        let association = try c.decodeIfPresent(ServiceAttachmentKey.self, forKey: .createdAssociation)
        try Self.validate(id: id, createdAt: createdAt, prompt: prompt, cwd: cwd,
            providerID: providerID, modelID: modelID, thinkingLevel: thinkingLevel, title: title,
            attemptCommandID: attempt, startCommandID: start, createdAssociation: association,
            generation: generation)
        self.init(schemaVersion: Self.schemaVersion, generation: generation, id: id,
            createdAt: createdAt, prompt: prompt, cwd: cwd, providerID: providerID,
            modelID: modelID, thinkingLevel: thinkingLevel, title: title,
            noContextFiles: noContextFiles, recordPayloads: recordPayloads, phase: phase,
            failureKind: failureKind, attemptCommandID: attempt, startCommandID: start,
            createdAssociation: association)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(generation, forKey: .generation)
        try c.encode(id, forKey: .id); try c.encode(createdAt, forKey: .createdAt)
        try c.encode(prompt, forKey: .prompt); try c.encode(cwd, forKey: .cwd)
        try c.encode(providerID, forKey: .providerID); try c.encode(modelID, forKey: .modelID)
        try c.encode(thinkingLevel, forKey: .thinkingLevel); try c.encode(title, forKey: .title)
        try c.encode(noContextFiles, forKey: .noContextFiles); try c.encode(recordPayloads, forKey: .recordPayloads)
        try c.encode(phase, forKey: .phase); try c.encode(failureKind, forKey: .failureKind)
        try c.encode(attemptCommandID, forKey: .attemptCommandID); try c.encode(startCommandID, forKey: .startCommandID)
        try c.encode(createdAssociation, forKey: .createdAssociation)
    }
}

public struct PendingChatUnavailable: Hashable, Sendable {
    public let fileName: String
    public let kind: PendingChatDiagnosticKind
    public init(fileName: String, kind: PendingChatDiagnosticKind) {
        self.fileName = fileName; self.kind = kind
    }
}

public enum PendingChatDiagnosticKind: String, CaseIterable, Hashable, Sendable {
    case malformed
    case unreadable
    case unsafeEntry
    case capacityExceeded
}

public struct PendingChatInventory: Hashable, Sendable {
    public let rows: [PendingChat]
    public let unavailable: [PendingChatUnavailable]
    public init(rows: [PendingChat], unavailable: [PendingChatUnavailable]) {
        self.rows = rows; self.unavailable = unavailable
    }
}

public enum PendingChatError: Error, Equatable, Sendable {
    case invalid
    case tooLarge
    case capacity
    case conflict
    case corrupt
    case ioFailure
}

/// Durable, bounded local storage for chats that have not yet crossed the canonical Create
/// boundary. It performs no network work and never retries a host operation.
public struct PendingChatStore: Sendable {
    public static let maximumRows = 128
    public static let maximumRecordBytes = 128 * 1_024
    public let directory: URL
    private let homeRoot: URL

    public init(home: AgentHome) throws {
        guard home.root.isFileURL, !home.root.path.isEmpty,
              home.root.path.unicodeScalars.allSatisfy({ $0.value != 0 }) else {
            throw PendingChatError.invalid
        }
        self.homeRoot = home.root
        self.directory = home.root.appending(path: "pending-chats", directoryHint: .isDirectory)
        try prepareDirectory()
    }

    public func create(
        prompt: String, cwd: String, providerID: String? = nil, modelID: String? = nil,
        thinkingLevel: String? = nil, title: String? = nil, noContextFiles: Bool = false,
        recordPayloads: Bool = false
    ) throws -> PendingChat {
        let chat = try PendingChat(prompt: prompt, cwd: cwd, providerID: providerID,
            modelID: modelID, thinkingLevel: thinkingLevel, title: title,
            noContextFiles: noContextFiles, recordPayloads: recordPayloads)
        try insert(chat)
        return chat
    }

    public func load() throws -> PendingChatInventory {
        try prepareDirectory()
        return try withLock { try inventoryLocked() }
    }

    public func insert(_ chat: PendingChat) throws {
        try prepareDirectory()
        try withLock {
            let target = url(for: chat.id)
            guard !exists(target) else { throw PendingChatError.conflict }
            let files = try rowURLsLocked()
            guard files.count < Self.maximumRows else { throw PendingChatError.capacity }
            try write(chat, to: target)
        }
    }

    @discardableResult
    public func update(_ chat: PendingChat, expectedGeneration: Int) throws -> PendingChat {
        try prepareDirectory()
        return try withLock {
            let target = url(for: chat.id)
            let existing = try read(target)
            guard existing.generation == expectedGeneration else { throw PendingChatError.conflict }
            let immutableAfterAdmission = existing.phase == .awaitingAcceptance
                || existing.createdAssociation != nil
            if immutableAfterAdmission {
                guard existing.prompt == chat.prompt, existing.cwd == chat.cwd,
                      existing.providerID == chat.providerID, existing.modelID == chat.modelID,
                      existing.thinkingLevel == chat.thinkingLevel,
                      existing.noContextFiles == chat.noContextFiles,
                      existing.recordPayloads == chat.recordPayloads,
                      existing.attemptCommandID == chat.attemptCommandID,
                      existing.startCommandID == chat.startCommandID,
                      (existing.createdAssociation == chat.createdAssociation
                          || (existing.createdAssociation == nil
                              && chat.createdAssociation != nil)) else {
                    throw PendingChatError.conflict
                }
            }
            let next = try PendingChat.makeForStore(from: chat, generation: PendingChat.nextGeneration(existing.generation))
            try write(next, to: target)
            return next
        }
    }

    public func delete(id: UUID, expectedGeneration: Int) throws {
        try prepareDirectory()
        try withLock {
            let target = url(for: id)
            let existing = try read(target)
            guard existing.generation == expectedGeneration else { throw PendingChatError.conflict }
            guard unlink(target.path) == 0 else { throw PendingChatError.ioFailure }
            try synchronizeDirectory()
        }
    }

    private func inventoryLocked() throws -> PendingChatInventory {
        let urls = try rowURLsLocked()
        var rows: [PendingChat] = []; var unavailable: [PendingChatUnavailable] = []
        for url in urls {
            if let resources = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
               resources.isDirectory == true || resources.isSymbolicLink == true {
                unavailable.append(.init(fileName: url.lastPathComponent, kind: .unsafeEntry))
                continue
            }
            do {
                let row = try read(url)
                guard url.lastPathComponent == fileName(for: row.id) else {
                    unavailable.append(.init(fileName: url.lastPathComponent, kind: .malformed)); continue
                }
                rows.append(row)
            } catch PendingChatError.corrupt {
                unavailable.append(.init(fileName: url.lastPathComponent, kind: .malformed))
            } catch {
                unavailable.append(.init(fileName: url.lastPathComponent, kind: .unreadable))
            }
        }
        return PendingChatInventory(rows: rows.sorted { $0.createdAt < $1.createdAt }, unavailable: unavailable)
    }

    private func rowURLsLocked() throws -> [URL] {
        guard let values = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { throw PendingChatError.ioFailure }
        var rows: [URL] = []; var count = 0
        for value in values {
            count += 1
            guard count <= Self.maximumRows + 32 else { throw PendingChatError.capacity }
            let r = try? value.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if r?.isDirectory == true || r?.isSymbolicLink == true {
                // Keep unsafe entries visible in inventory rather than treating them as rows.
                rows.append(value); continue
            }
            if value.pathExtension == "json" { rows.append(value) }
        }
        guard rows.count <= Self.maximumRows else { throw PendingChatError.capacity }
        return rows.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func read(_ target: URL) throws -> PendingChat {
        let fd = target.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw PendingChatError.corrupt }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == geteuid(), (st.st_mode & mode_t(0o777)) == mode_t(0o600),
              st.st_size >= 0, st.st_size <= off_t(Self.maximumRecordBytes) else {
            throw PendingChatError.corrupt
        }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = AviaryPOSIX.read(fd, &buffer, buffer.count)
            if n > 0 {
                guard data.count <= Self.maximumRecordBytes - n else { throw PendingChatError.corrupt }
                data.append(buffer, count: n)
            }
            else if n == 0 { break }
            else if errno != EINTR { throw PendingChatError.corrupt }
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .deferredToDate
            return try decoder.decode(PendingChat.self, from: data)
        }
        catch { throw PendingChatError.corrupt }
    }

    private func write(_ chat: PendingChat, to target: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        let data: Data
        do { data = try encoder.encode(chat) } catch { throw PendingChatError.invalid }
        guard data.count <= Self.maximumRecordBytes else { throw PendingChatError.tooLarge }
        let temporary = directory.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        defer { _ = unlink(temporary.path) }
        let fd = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard fd >= 0 else { throw PendingChatError.ioFailure }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let n = AviaryPOSIX.write(fd, base.advanced(by: offset), bytes.count - offset)
                    if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue }
                    else { throw PendingChatError.ioFailure }
                }
            }
            guard fsync(fd) == 0 else { throw PendingChatError.ioFailure }
        } catch { close(fd); throw error }
        guard close(fd) == 0 else { throw PendingChatError.ioFailure }
        var existing = stat()
        if lstat(target.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG,
                  existing.st_uid == geteuid(),
                  (existing.st_mode & mode_t(0o777)) == mode_t(0o600) else {
                throw PendingChatError.corrupt
            }
        } else if errno != ENOENT {
            throw PendingChatError.ioFailure
        }
        guard rename(temporary.path, target.path) == 0 else { throw PendingChatError.ioFailure }
        try synchronizeDirectory()
    }

    private func exists(_ url: URL) -> Bool { var st = stat(); return lstat(url.path, &st) == 0 }
    private func fileName(for id: UUID) -> String { "\(id.uuidString.lowercased()).json" }
    private func url(for id: UUID) -> URL { directory.appending(path: fileName(for: id), directoryHint: .notDirectory) }

    private func prepareDirectory() throws {
        for (index, candidate) in [homeRoot, directory].enumerated() {
            var st = stat()
            if lstat(candidate.path, &st) == 0 {
                let mode = st.st_mode & mode_t(0o777)
                guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == geteuid(),
                      (index == 0 ? (mode & mode_t(0o022)) == 0 : mode == mode_t(0o700)) else { throw PendingChatError.corrupt }
            } else {
                guard errno == ENOENT else { throw PendingChatError.ioFailure }
                do { try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: index == 1, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]) } catch { }
                guard lstat(candidate.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
                      st.st_uid == geteuid(), (st.st_mode & mode_t(0o777)) == mode_t(0o700) else { throw PendingChatError.corrupt }
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let lock = directory.appending(path: ".pending-chats.lock")
        let fd = lock.path.withCString { AviaryPOSIX.openExclusiveLock($0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: mode_t(0o600)) }
        guard fd >= 0 else { throw PendingChatError.ioFailure }
        defer { _ = AviaryPOSIX.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == geteuid(), (st.st_mode & mode_t(0o777)) == mode_t(0o600) else { throw PendingChatError.corrupt }
        return try body()
    }

    private func synchronizeDirectory() throws {
        let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw PendingChatError.ioFailure }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw PendingChatError.ioFailure }
    }
}

private extension PendingChat {
    static func makeForStore(from chat: PendingChat, generation: Int) throws -> PendingChat {
        guard generation <= maximumGeneration else { throw PendingChatError.conflict }
        return try make(generation: generation, id: chat.id, createdAt: chat.createdAt,
            prompt: chat.prompt, cwd: chat.cwd, providerID: chat.providerID, modelID: chat.modelID,
            thinkingLevel: chat.thinkingLevel, title: chat.title, noContextFiles: chat.noContextFiles,
            recordPayloads: chat.recordPayloads, phase: chat.phase,
            failureKind: (chat.phase == .saved || chat.phase == .preparing) ? nil : chat.failureKind,
            attemptCommandID: chat.attemptCommandID, startCommandID: chat.startCommandID,
            createdAssociation: chat.createdAssociation)
    }

    static func nextGeneration(_ generation: Int) throws -> Int {
        guard generation < maximumGeneration else { throw PendingChatError.conflict }
        return generation + 1
    }
}
