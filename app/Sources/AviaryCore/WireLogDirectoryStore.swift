import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum WireLogDirectoryStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidDirectory
    case directoryUnavailable
    case knownDirectoryLimitReached(Int)
    case configurationIO(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The saved wire-log directory settings are invalid."
        case .invalidDirectory:
            return "Choose an absolute file-system directory."
        case .directoryUnavailable:
            return "The selected wire-log directory is unavailable or not writable."
        case .knownDirectoryLimitReached(let limit):
            return "Aviary can remember at most \(limit) wire-log directories."
        case .configurationIO(let operation):
            return "Wire-log directory settings could not be \(operation)."
        }
    }
}

/// Local GUI configuration for provider-request logs. This is deliberately outside the
/// Work-service contract: the path belongs to the machine that records and inspects the logs.
public struct WireLogDirectoryStore: Sendable {
    public struct Selection: Sendable, Equatable {
        /// Directory to use for the next locally hosted Create.
        public let directory: URL
        /// Selected and previously selected directories, newest first. The default remains in
        /// this list so logs from before a custom location can still be discovered.
        public let knownDirectories: [URL]
    }

    public static let maximumKnownDirectories = 12
    public static let maximumPathBytes = 4_096
    public static let maximumConfigurationBytes = 64 * 1_024
    public static let configurationFilename = "wire-log-directory.json"

    private struct Record: Codable {
        var schemaVersion: Int
        var directoryPath: String
        var knownDirectoryPaths: [String]
        var updatedAt: Date
    }

    private let home: AgentHome

    /// The config is private to the local AgentHome and does not alter `settings.json`.
    public var configurationURL: URL {
        home.root.appending(path: Self.configurationFilename, directoryHint: .notDirectory)
    }

    public init(home: AgentHome) {
        self.home = home
    }

    /// Read the current selection. A missing record means the existing WireLog default; a
    /// present but malformed record is an error and is never replaced with that default.
    public func load() throws -> Selection {
        var information = stat()
        let status = configurationURL.path.withCString { lstat($0, &information) }
        if status != 0, errno == ENOENT {
            let fallback = try Self.validatedDirectoryURL(WireLog.directory)
            return Selection(directory: fallback, knownDirectories: [fallback])
        }
        guard status == 0 else {
            throw WireLogDirectoryStoreError.configurationIO("read")
        }
        guard (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size >= 0,
              information.st_size <= off_t(Self.maximumConfigurationBytes) else {
            throw WireLogDirectoryStoreError.invalidConfiguration
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: configurationURL)
            defer { try? handle.close() }
            var bounded = Data()
            while bounded.count <= Self.maximumConfigurationBytes {
                let remaining = Self.maximumConfigurationBytes + 1 - bounded.count
                guard remaining > 0,
                      let chunk = try handle.read(upToCount: min(16 * 1_024, remaining)),
                      !chunk.isEmpty else {
                    break
                }
                bounded.append(chunk)
            }
            guard bounded.count <= Self.maximumConfigurationBytes else {
                throw WireLogDirectoryStoreError.invalidConfiguration
            }
            data = bounded
        } catch let error as WireLogDirectoryStoreError {
            throw error
        } catch {
            throw WireLogDirectoryStoreError.configurationIO("read")
        }

        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: data)
        } catch {
            throw WireLogDirectoryStoreError.invalidConfiguration
        }
        guard record.schemaVersion == 1,
              !record.knownDirectoryPaths.isEmpty,
              record.knownDirectoryPaths.count <= Self.maximumKnownDirectories else {
            throw WireLogDirectoryStoreError.invalidConfiguration
        }

        let known: [URL]
        do {
            known = try record.knownDirectoryPaths.map(Self.validatedPersistedDirectoryPath)
        } catch {
            throw WireLogDirectoryStoreError.invalidConfiguration
        }
        let uniquePaths = Set(known.map(\.path))
        guard uniquePaths.count == known.count else {
            throw WireLogDirectoryStoreError.invalidConfiguration
        }
        let selected: URL
        do {
            selected = try Self.validatedPersistedDirectoryPath(record.directoryPath)
        } catch {
            throw WireLogDirectoryStoreError.invalidConfiguration
        }
        guard known.contains(selected) else {
            throw WireLogDirectoryStoreError.invalidConfiguration
        }
        return Selection(directory: selected, knownDirectories: known)
    }

    /// Validate the current path immediately before Create. This re-reads the file so a live
    /// GUI observes a setting changed by another app process, and fails rather than silently
    /// recording in a different directory if the selected target is no longer writable.
    public func resolveForCreate() throws -> Selection {
        let selection = try load()
        try Self.requireExistingWritableDirectory(selection.directory)
        return selection
    }

    /// Explicitly restore the default directory after malformed local configuration. Any
    /// existing regular config is copied byte-for-byte before replacement; recorded log files
    /// are never moved or deleted. A symlink or other non-regular config is not repaired.
    @discardableResult
    public func resetToDefault() throws -> Selection {
        try withConfigurationLock {
            let fallback = try Self.validatedDirectoryURL(WireLog.directory)
            try Self.requireExistingWritableDirectory(fallback)
            var information = stat()
            let status = configurationURL.path.withCString { lstat($0, &information) }
            let hadRegularConfiguration: Bool
            var known: [URL] = [fallback]

            if status == 0 {
                guard (information.st_mode & S_IFMT) == S_IFREG else {
                    throw WireLogDirectoryStoreError.invalidConfiguration
                }
                hadRegularConfiguration = true
                do {
                    let previous = try load()
                    known = previous.knownDirectories
                } catch WireLogDirectoryStoreError.invalidConfiguration {
                    // The explicit reset is the only operation allowed to replace a malformed
                    // regular config. The exact original bytes are retained in the backup.
                    known = [fallback]
                } catch {
                    throw error
                }
            } else if errno == ENOENT {
                hadRegularConfiguration = false
            } else {
                throw WireLogDirectoryStoreError.configurationIO("read")
            }

            if !known.contains(fallback) {
                guard known.count < Self.maximumKnownDirectories else {
                    throw WireLogDirectoryStoreError.knownDirectoryLimitReached(
                        Self.maximumKnownDirectories)
                }
                known.append(fallback)
            }
            known.removeAll { $0 == fallback }
            known.insert(fallback, at: 0)

            let selection = Selection(directory: fallback, knownDirectories: known)
            if hadRegularConfiguration { try backupExistingConfiguration() }
            try write(selection, backupExisting: false)
            return selection
        }
    }

    /// Select a local destination. A new folder may be created, matching the folder picker's
    /// create-directory behavior; re-selecting a known path does not evict or reorder the other
    /// known locations out of the bounded discovery history.
    @discardableResult
    public func select(directory: URL) throws -> Selection {
        let chosen = try Self.validatedDirectoryURL(directory)
        return try withConfigurationLock {
            // Re-read after acquiring the cross-process lock: two open GUIs must merge against
            // the winner's history rather than overwrite one another's newly selected paths.
            let existing = try load()
            let alreadyKnown = existing.knownDirectories.contains(chosen)
            guard alreadyKnown || existing.knownDirectories.count < Self.maximumKnownDirectories else {
                throw WireLogDirectoryStoreError.knownDirectoryLimitReached(
                    Self.maximumKnownDirectories)
            }

            try Self.createAndVerifyWritableDirectory(chosen)
            var known = existing.knownDirectories
            if !alreadyKnown { known.append(chosen) }
            // Keep the current selection first without dropping any retained location.
            known.removeAll { $0 == chosen }
            known.insert(chosen, at: 0)

            let selection = Selection(directory: chosen, knownDirectories: known)
            try write(selection)
            return selection
        }
    }

    private func write(_ selection: Selection, backupExisting: Bool = true) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: home.root, withIntermediateDirectories: true)
        } catch {
            throw WireLogDirectoryStoreError.configurationIO("saved")
        }

        let record = Record(
            schemaVersion: 1,
            directoryPath: selection.directory.path,
            knownDirectoryPaths: selection.knownDirectories.map(\.path),
            updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw WireLogDirectoryStoreError.configurationIO("encoded")
        }
        guard data.count <= Self.maximumConfigurationBytes else {
            throw WireLogDirectoryStoreError.invalidConfiguration
        }

        if backupExisting { try backupExistingConfigurationIfPresent() }

        do {
            try data.write(to: configurationURL, options: [.atomic])
        } catch {
            throw WireLogDirectoryStoreError.configurationIO("saved")
        }
    }

    private func backupExistingConfigurationIfPresent() throws {
        var information = stat()
        let status = configurationURL.path.withCString { lstat($0, &information) }
        if status != 0 {
            if errno == ENOENT { return }
            throw WireLogDirectoryStoreError.configurationIO("read")
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            throw WireLogDirectoryStoreError.invalidConfiguration
        }
        try backupExistingConfiguration()
    }

    private func backupExistingConfiguration() throws {
        let stamp = "\(Int64(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased())"
        let backup = configurationURL.deletingLastPathComponent().appending(
            path: "\(Self.configurationFilename).aviary-bak-\(stamp)",
            directoryHint: .notDirectory)
        do {
            try FileManager.default.copyItem(at: configurationURL, to: backup)
        } catch {
            throw WireLogDirectoryStoreError.configurationIO("backed up")
        }
    }

    private var lockURL: URL {
        home.root.appending(path: ".wire-log-directory.lock", directoryHint: .notDirectory)
    }

    private func withConfigurationLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        } catch {
            throw WireLogDirectoryStoreError.configurationIO("locked")
        }
        let descriptor = lockURL.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw WireLogDirectoryStoreError.configurationIO("locked")
        }
        defer { _ = AviaryPOSIX.close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              (information.st_mode & mode_t(0o077)) == 0 else {
            throw WireLogDirectoryStoreError.configurationIO("locked")
        }
        return try body()
    }

    private static func validatedDirectoryURL(_ directory: URL) throws -> URL {
        guard directory.isFileURL else { throw WireLogDirectoryStoreError.invalidDirectory }
        let originalPath = directory.path
        guard originalPath.hasPrefix("/") else {
            throw WireLogDirectoryStoreError.invalidDirectory
        }
        let path = directory.standardizedFileURL.path
        guard path.hasPrefix("/"), path.utf8.count <= maximumPathBytes,
              !path.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw WireLogDirectoryStoreError.invalidDirectory
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func validatedPersistedDirectoryPath(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), path.utf8.count <= maximumPathBytes,
              !path.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw WireLogDirectoryStoreError.invalidDirectory
        }
        let url = try validatedDirectoryURL(URL(fileURLWithPath: path, isDirectory: true))
        guard url.path == path else { throw WireLogDirectoryStoreError.invalidDirectory }
        return url
    }

    private static func createAndVerifyWritableDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw WireLogDirectoryStoreError.directoryUnavailable
        }
        try requireExistingWritableDirectory(directory)
    }

    private static func requireExistingWritableDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WireLogDirectoryStoreError.directoryUnavailable
        }

        let probe = directory.appending(
            path: ".aviary-wire-log-write-check-\(UUID().uuidString.lowercased())",
            directoryHint: .notDirectory)
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else {
            throw WireLogDirectoryStoreError.directoryUnavailable
        }
        do {
            try FileManager.default.removeItem(at: probe)
        } catch {
            throw WireLogDirectoryStoreError.directoryUnavailable
        }
    }
}
