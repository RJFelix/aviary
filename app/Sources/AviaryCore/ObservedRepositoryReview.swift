import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func observedRepositorySafeText(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
        let value = scalar.value
        return value >= 0x20 && value != 0x7F
            && !(0x80...0x9F).contains(value)
            && value != 0x2028 && value != 0x2029
    }
}

private func observedRepositoryValidRelativePath(
    _ path: String, maxBytes: Int
) -> Bool {
    !path.isEmpty
        && path.utf8.count <= maxBytes
        && observedRepositorySafeText(path)
        && !path.hasPrefix("/")
        && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        && !path.split(separator: "/", omittingEmptySubsequences: false).contains(".")
}

private enum ObservedRepositoryDiscoveryEvidence {
    case none
    case repositoryMetadata
    case ambiguous
}

private enum ObservedRepositoryPathProbe {
    case missing
    case present(mode: mode_t)
    case inaccessible
}

/// A failed Git discovery is only a truthful ``notRepository`` result when the local path also
/// provides no evidence of a repository. Git emits the same C-locale message for an empty or
/// corrupt `.git`, so stderr alone cannot distinguish an ordinary directory from damaged
/// metadata. Probe with `lstat` so permission errors, symlink loops, and other ambiguous paths
/// remain failures rather than being downgraded to absence.
private func observedRepositoryDiscoveryEvidence(at cwd: URL) -> ObservedRepositoryDiscoveryEvidence {
    let base = cwd.standardizedFileURL
    guard observedRepositoryDirectoryIsAccessible(base) else { return .ambiguous }

    var current = base
    while true {
        // `lstat` on macOS reports `/var` and `/tmp` as symlinks to `/private/...`; use `stat`
        // for the ancestor itself so those normal aliases remain traversable. Metadata probes
        // below still use `lstat`, preserving the distinction between missing and ambiguous
        // `.git`/bare markers.
        guard observedRepositoryDirectoryIsAccessible(current) else { return .ambiguous }

        switch observedRepositoryPathProbe(current.appendingPathComponent(".git")) {
        case .present, .inaccessible:
            return .repositoryMetadata
        case .missing:
            break
        }

        // A bare repository has no `.git` directory. Any canonical marker is evidence worth
        // preserving as a failure: a partially damaged bare layout must not be downgraded to an
        // ordinary directory merely because one of its markers is missing.
        let bareMarkers = ["HEAD", "objects", "refs", "config"]
        for marker in bareMarkers {
            switch observedRepositoryPathProbe(current.appendingPathComponent(marker)) {
            case .present:
                return .repositoryMetadata
            case .missing:
                break
            case .inaccessible:
                return .ambiguous
            }
        }

        // Foundation can represent the parent of `/` as `/..` and keep growing that path.
        // Stop at the root explicitly; absence must not eventually become ENAMETOOLONG.
        if current.path == "/" { return .none }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        if parent.path == current.path { return .none }
        current = parent
    }
}

private func observedRepositoryModeIsDirectory(_ mode: mode_t) -> Bool {
    mode & S_IFMT == S_IFDIR
}

private func observedRepositoryDirectoryIsAccessible(_ url: URL) -> Bool {
    var information = stat()
    let result = url.path.withCString { stat($0, &information) }
    return result == 0 && observedRepositoryModeIsDirectory(information.st_mode)
}

private func observedRepositoryPathProbe(_ url: URL) -> ObservedRepositoryPathProbe {
    var information = stat()
    let result = url.path.withCString { lstat($0, &information) }
    guard result == 0 else {
        return errno == ENOENT ? .missing : .inaccessible
    }
    return .present(mode: information.st_mode)
}

/// These omissions mean the observer could not interpret all of the Git evidence it received.
/// They are different from deliberate content exclusions such as untracked or binary bodies: a
/// stable pair of equally malformed streams still cannot prove that the working tree was clean.
private let observedRepositoryIncompleteEvidenceKinds: Set<String> = [
    "invalid_status", "out_of_bound", "invalid_diff", "bounded",
    "projection_limit", "artifact_limit",
]

/// The media type emitted by ``ObservedRepositoryReview``.
public enum ObservedRepositoryReviewFormat {
    public static let mediaType = "application/vnd.aviary.repository-review+json"
    public static let schema = "aviary.repository-review"
    public static let version = 2
}

public enum ObservedRepositoryReviewStatus: String, Codable, Sendable {
    case clean
    case changes
    case unstableConflict = "unstable_conflict"
    case notRepository = "not_repository"
    case timedOut = "timed_out"
    case cancelled
    case failed
    case bounded
}

public struct ObservedRepositoryReviewLimits: Codable, Equatable, Sendable {
    public let commandStdoutBytes: Int
    public let commandStderrBytes: Int
    public let diffBytes: Int
    public let pathBytes: Int
    public let stringBytes: Int
    public let fileCount: Int
    public let omissionCount: Int
    public let totalArtifactBytes: Int
    public let timeout: TimeInterval

    public static let `default` = ObservedRepositoryReviewLimits(
        commandStdoutBytes: 512 * 1024,
        commandStderrBytes: 32 * 1024,
        diffBytes: 256 * 1024,
        pathBytes: 4 * 1024,
        stringBytes: 16 * 1024,
        fileCount: 2_000,
        omissionCount: 2_000,
        totalArtifactBytes: 768 * 1024,
        timeout: 8)

    /// The envelope itself is larger than a few hundred bytes. Clamp an invalidly tiny caller
    /// budget to a useful minimum so the bounded fallback can still be a valid Codable record.
    public static let minimumTotalArtifactBytes = 1_024
    public static let maximumTotalArtifactBytes = 8 * 1024 * 1024
    public static let maximumTimeout: TimeInterval = 60
    /// Fixed wire maxima. A producer may choose tighter operational limits, but a consumer must
    /// validate against the format ceiling rather than assuming the producer used `.default`.
    public static let wireMaximum = ObservedRepositoryReviewLimits(
        commandStdoutBytes: maximumTotalArtifactBytes,
        commandStderrBytes: 1024 * 1024,
        diffBytes: 4 * 1024 * 1024,
        pathBytes: 64 * 1024,
        stringBytes: 64 * 1024,
        fileCount: 10_000,
        omissionCount: 10_000,
        totalArtifactBytes: maximumTotalArtifactBytes,
        timeout: maximumTimeout)

    private static func bounded(_ value: Int, minimum: Int = 1, maximum: Int) -> Int {
        min(maximum, max(minimum, value))
    }

    public init(
        commandStdoutBytes: Int = 512 * 1024,
        commandStderrBytes: Int = 32 * 1024,
        diffBytes: Int = 256 * 1024,
        pathBytes: Int = 4 * 1024,
        stringBytes: Int = 16 * 1024,
        fileCount: Int = 2_000,
        omissionCount: Int = 2_000,
        totalArtifactBytes: Int = 768 * 1024,
        timeout: TimeInterval = 8)
    {
        self.commandStdoutBytes = Self.bounded(
            commandStdoutBytes, maximum: Self.maximumTotalArtifactBytes)
        self.commandStderrBytes = Self.bounded(
            commandStderrBytes, maximum: 1024 * 1024)
        self.diffBytes = Self.bounded(diffBytes, maximum: 4 * 1024 * 1024)
        self.pathBytes = Self.bounded(pathBytes, maximum: 64 * 1024)
        self.stringBytes = Self.bounded(stringBytes, maximum: 64 * 1024)
        self.fileCount = Self.bounded(fileCount, maximum: 10_000)
        self.omissionCount = Self.bounded(omissionCount, maximum: 10_000)
        self.totalArtifactBytes = Self.bounded(
            totalArtifactBytes, minimum: Self.minimumTotalArtifactBytes,
            maximum: Self.maximumTotalArtifactBytes)
        self.timeout = timeout.isFinite
            ? min(Self.maximumTimeout, max(0.01, timeout))
            : 8
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            commandStdoutBytes: try values.decode(Int.self, forKey: .commandStdoutBytes),
            commandStderrBytes: try values.decode(Int.self, forKey: .commandStderrBytes),
            diffBytes: try values.decode(Int.self, forKey: .diffBytes),
            pathBytes: try values.decode(Int.self, forKey: .pathBytes),
            stringBytes: try values.decode(Int.self, forKey: .stringBytes),
            fileCount: try values.decode(Int.self, forKey: .fileCount),
            omissionCount: try values.decode(Int.self, forKey: .omissionCount),
            totalArtifactBytes: try values.decode(Int.self, forKey: .totalArtifactBytes),
            timeout: try values.decode(TimeInterval.self, forKey: .timeout))
    }
}

/// A result from a single literal-argument Git invocation. The runner deliberately carries
/// bytes rather than strings: invalid UTF-8 is an omission, never a replacement-character
/// path that could accidentally be presented as a trustworthy review.
public struct ObservedRepositoryGitCommandResult: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public let timedOut: Bool
    public let cancelled: Bool
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool

    public init(
        stdout: Data = Data(),
        stderr: Data = Data(),
        exitCode: Int32 = 0,
        timedOut: Bool = false,
        cancelled: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false)
    {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    public init(
        stdout: String,
        stderr: String = "",
        exitCode: Int32 = 0,
        timedOut: Bool = false,
        cancelled: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false)
    {
        self.init(
            stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), exitCode: exitCode,
            timedOut: timedOut, cancelled: cancelled,
            stdoutTruncated: stdoutTruncated, stderrTruncated: stderrTruncated)
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled }
}

public struct ObservedRepositoryHead: Codable, Equatable, Sendable {
    public let oid: String?
    public let ref: String?
    public let detached: Bool

    public init(oid: String?, ref: String?, detached: Bool) {
        self.oid = oid
        self.ref = ref
        self.detached = detached
    }
}

public struct ObservedRepositoryFence: Codable, Equatable, Sendable {
    public let head: ObservedRepositoryHead?
    /// A digest of the bounded, NUL-delimited status stream. The stream itself is not retained
    /// in the artifact, both to keep it small and to avoid duplicating path material.
    public let statusDigest: String?
    /// Digest of the staged and unstaged diff observations made at this side of the fence.
    /// This lets a decoded conflict prove content drift even when HEAD and porcelain status
    /// happen to remain unchanged.
    public let contentDigest: String?
    public let statusEntryCount: Int
    public let statusTruncated: Bool

    public init(
        head: ObservedRepositoryHead?, statusDigest: String?, contentDigest: String?,
        statusEntryCount: Int, statusTruncated: Bool)
    {
        self.head = head
        self.statusDigest = statusDigest
        self.contentDigest = contentDigest
        self.statusEntryCount = statusEntryCount
        self.statusTruncated = statusTruncated
    }
}

public struct ObservedRepositoryFile: Codable, Equatable, Sendable {
    public let path: String
    public let kind: String
    public let indexStatus: String
    public let workTreeStatus: String
    public let originalPath: String?
    public let isUntracked: Bool
    public let isIgnored: Bool
    public let isBinary: Bool
    public let isSubmodule: Bool

    public init(
        path: String,
        kind: String,
        indexStatus: String,
        workTreeStatus: String,
        originalPath: String? = nil,
        isUntracked: Bool = false,
        isIgnored: Bool = false,
        isBinary: Bool = false,
        isSubmodule: Bool = false)
    {
        self.path = path
        self.kind = kind
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.originalPath = originalPath
        self.isUntracked = isUntracked
        self.isIgnored = isIgnored
        self.isBinary = isBinary
        self.isSubmodule = isSubmodule
    }
}

public struct ObservedRepositoryDiff: Codable, Equatable, Sendable {
    public let kind: String
    public let text: String?
    public let byteCount: Int
    public let truncated: Bool
    public let retainedSectionCount: Int

    public init(
        kind: String,
        text: String?,
        byteCount: Int,
        truncated: Bool,
        retainedSectionCount: Int)
    {
        self.kind = kind
        self.text = text
        self.byteCount = byteCount
        self.truncated = truncated
        self.retainedSectionCount = retainedSectionCount
    }
}

public struct ObservedRepositoryOmission: Codable, Equatable, Sendable {
    public let kind: String
    public let path: String?
    public let detail: String

    public init(kind: String, path: String? = nil, detail: String) {
        self.kind = kind
        self.path = path
        self.detail = detail
    }
}

public struct ObservedRepositoryCoverage: Codable, Equatable, Sendable {
    public let statusObserved: Bool
    public let stagedDiffObserved: Bool
    public let unstagedDiffObserved: Bool
    public let untrackedNamesOnly: Bool
    public let ignoredNamesOnly: Bool
    public let binaryBodiesExcluded: Bool
    public let submoduleBodiesExcluded: Bool
    public let bounded: Bool

    public init(
        statusObserved: Bool,
        stagedDiffObserved: Bool,
        unstagedDiffObserved: Bool,
        untrackedNamesOnly: Bool,
        ignoredNamesOnly: Bool,
        binaryBodiesExcluded: Bool,
        submoduleBodiesExcluded: Bool,
        bounded: Bool)
    {
        self.statusObserved = statusObserved
        self.stagedDiffObserved = stagedDiffObserved
        self.unstagedDiffObserved = unstagedDiffObserved
        self.untrackedNamesOnly = untrackedNamesOnly
        self.ignoredNamesOnly = ignoredNamesOnly
        self.binaryBodiesExcluded = binaryBodiesExcluded
        self.submoduleBodiesExcluded = submoduleBodiesExcluded
        self.bounded = bounded
    }
}

/// A read-only, point-in-time view of the current Git worktree. This is deliberately not an
/// attribution, checkpoint, sandbox, or restore record. A review is only stable when the
/// before/after fence agrees; unstable reviews never contain a presentable diff.
public struct ObservedRepositoryReview: Codable, Equatable, Sendable {
    public let mediaType: String
    public let schema: String
    public let version: Int
    public let observedAt: Date
    public let runID: String
    public let turnID: String
    public let repositoryIdentityDigest: String?
    public let scope: String
    public let attribution: String
    public let status: ObservedRepositoryReviewStatus
    public let head: ObservedRepositoryHead?
    public let fenceBefore: ObservedRepositoryFence?
    public let fenceAfter: ObservedRepositoryFence?
    public let files: [ObservedRepositoryFile]
    public let diffs: [ObservedRepositoryDiff]
    public let omissions: [ObservedRepositoryOmission]
    public let coverage: ObservedRepositoryCoverage
    public let exclusions: [String]

    public static let mediaType = ObservedRepositoryReviewFormat.mediaType
    public static let schema = ObservedRepositoryReviewFormat.schema
    public static let schemaVersion = ObservedRepositoryReviewFormat.version

    public static func observe(
        cwd: URL,
        runID: String,
        turnID: String,
        observedAt: Date = Date(),
        limits: ObservedRepositoryReviewLimits = .default) async -> Self
    {
        await ObservedRepositoryReviewer().observe(
            cwd: cwd, runID: runID, turnID: turnID,
            observedAt: observedAt, limits: limits)
    }

    fileprivate init(
        observedAt: Date,
        runID: String,
        turnID: String,
        repositoryIdentityDigest: String?,
        status: ObservedRepositoryReviewStatus,
        head: ObservedRepositoryHead?,
        fenceBefore: ObservedRepositoryFence?,
        fenceAfter: ObservedRepositoryFence?,
        files: [ObservedRepositoryFile],
        diffs: [ObservedRepositoryDiff],
        omissions: [ObservedRepositoryOmission],
        coverage: ObservedRepositoryCoverage,
        exclusions: [String])
    {
        self.mediaType = Self.mediaType
        self.schema = Self.schema
        self.version = Self.schemaVersion
        self.observedAt = observedAt
        self.runID = runID
        self.turnID = turnID
        self.repositoryIdentityDigest = repositoryIdentityDigest
        self.scope = "current_working_tree"
        self.attribution = "not_attributed"
        self.status = status
        self.head = head
        self.fenceBefore = fenceBefore
        self.fenceAfter = fenceAfter
        self.files = files
        self.diffs = diffs
        self.omissions = omissions
        self.coverage = coverage
        self.exclusions = exclusions
    }

    /// Canonical JSON for transport/storage. Sorted keys and a fixed date strategy make bytes
    /// repeatable when the supplied timestamp is the same.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ObservedRepositoryReview {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: data)
        guard value.mediaType == mediaType,
              value.schema == schema,
              value.version == schemaVersion,
              value.scope == "current_working_tree",
              value.attribution == "not_attributed"
        else { throw ValidationError.invalidEnvelope }
        try value.validate(limits: .wireMaximum)
        return value
    }

    /// Prove that decoded review bytes belong to the exact canonical Run/Turn that published
    /// their artifact.  The media type and schema are not identity: a body captured during an
    /// earlier attempt must never be presented under a later descriptor.
    public func matchesCanonicalSource(run: RunRef, turn: TurnRef) -> Bool {
        runID == run.runID && turnID == turn.turnID
    }

    /// The descriptor overload keeps the artifact identity proof at the Core boundary so an
    /// adapter cannot accidentally compare review bytes with a GUI Session instead of the
    /// producer's Run/Turn envelope.
    public func matchesCanonicalSource(of artifact: WorkServiceArtifactDescriptor) -> Bool {
        guard artifact.mediaType == Self.mediaType, let turn = artifact.turn else { return false }
        return matchesCanonicalSource(run: artifact.run, turn: turn)
    }

    public enum ValidationError: Error, Equatable {
        case invalidEnvelope
        case emptyIdentity
        case absolutePath
        case parentPath
        case oversizedPath
        case duplicateFile
        case tooManyFiles
        case tooManyOmissions
        case tooManyExclusions
        case invalidDigest
        case oversizedText
        case invalidStatus
        case invalidHead
        case invalidFence
        case invalidCoverage
        case invalidKind
        case controlCharacter
        case unsorted
    }

    public func validate(limits: ObservedRepositoryReviewLimits = .default) throws {
        guard mediaType == Self.mediaType, schema == Self.schema,
              version == Self.schemaVersion,
              scope == "current_working_tree", attribution == "not_attributed",
              observedRepositorySafeText(runID), observedRepositorySafeText(turnID),
              observedRepositorySafeText(scope), observedRepositorySafeText(attribution)
        else { throw ValidationError.invalidEnvelope }
        guard !runID.isEmpty, !turnID.isEmpty,
              runID.utf8.count <= limits.stringBytes,
              turnID.utf8.count <= limits.stringBytes
        else { throw ValidationError.emptyIdentity }
        guard files.count <= limits.fileCount else { throw ValidationError.tooManyFiles }
        guard omissions.count <= limits.omissionCount else { throw ValidationError.tooManyOmissions }
        guard exclusions.count <= limits.omissionCount else { throw ValidationError.tooManyExclusions }

        func validOID(_ value: String?) -> Bool {
            guard let value else { return true }
            return value.count >= 7 && value.count <= 128
                && value.allSatisfy {
                    $0.isASCII && ($0.isNumber || ("a"..."f").contains($0) || ("A"..."F").contains($0))
                }
        }
        func validDigest(_ value: String?) -> Bool {
            guard let value else { return true }
            guard value.count == 71, value.hasPrefix("sha256:") else { return false }
            return value.dropFirst(7).allSatisfy {
                $0.isASCII && ($0.isNumber || ("a"..."f").contains($0))
            }
        }
        func validateHead(_ value: ObservedRepositoryHead?) throws {
            guard let value else { return }
            guard validOID(value.oid), value.detached == (value.ref == nil) else {
                throw ValidationError.invalidHead
            }
            if value.oid == nil, value.ref == nil { throw ValidationError.invalidHead }
            if let ref = value.ref {
                guard !ref.isEmpty, ref.utf8.count <= limits.stringBytes,
                      observedRepositorySafeText(ref), !ref.hasPrefix("/"),
                      !ref.split(separator: "/").contains("..")
                else { throw ValidationError.invalidHead }
            }
        }
        func validateFence(_ value: ObservedRepositoryFence?) throws {
            guard let value else { return }
            guard value.head != nil, value.statusEntryCount >= 0,
                  value.statusDigest != nil, validDigest(value.statusDigest),
                  value.contentDigest != nil, validDigest(value.contentDigest)
            else { throw ValidationError.invalidFence }
            try validateHead(value.head)
        }
        try validateHead(head)
        try validateFence(fenceBefore)
        try validateFence(fenceAfter)
        guard validDigest(repositoryIdentityDigest) else { throw ValidationError.invalidDigest }
        switch status {
        case .clean, .changes, .bounded:
            // These statuses claim one stable point-in-time observation. A differing status
            // digest/count/truncation flag is a conflict even when HEAD itself did not move.
            guard fenceBefore == fenceAfter, fenceBefore?.head == head else {
                throw ValidationError.invalidFence
            }
        case .unstableConflict:
            guard fenceBefore?.head == head else { throw ValidationError.invalidFence }
        case .notRepository, .timedOut, .cancelled, .failed:
            break
        }
        guard coverage.untrackedNamesOnly, coverage.ignoredNamesOnly,
              coverage.binaryBodiesExcluded, coverage.submoduleBodiesExcluded,
              coverage.statusObserved == (fenceBefore != nil && fenceAfter != nil),
              !((fenceBefore?.statusTruncated == true
                  || fenceAfter?.statusTruncated == true) && !coverage.bounded)
        else { throw ValidationError.invalidCoverage }
        guard !omissions.contains(where: {
            observedRepositoryIncompleteEvidenceKinds.contains($0.kind)
        }) || coverage.bounded else {
            throw ValidationError.invalidCoverage
        }

        var seen = Set<String>()
        var previousPath: String?
        for file in files {
            guard observedRepositoryValidRelativePath(file.path, maxBytes: limits.pathBytes)
            else {
                if file.path.hasPrefix("/") { throw ValidationError.absolutePath }
                if file.path.split(separator: "/").contains("..") { throw ValidationError.parentPath }
                if !observedRepositorySafeText(file.path) { throw ValidationError.controlCharacter }
                throw ValidationError.oversizedPath
            }
            guard seen.insert(file.path).inserted else { throw ValidationError.duplicateFile }
            if let previousPath, previousPath > file.path { throw ValidationError.unsorted }
            previousPath = file.path
            guard ["tracked", "untracked", "ignored"].contains(file.kind),
                  file.indexStatus.count == 1, file.workTreeStatus.count == 1,
                  observedRepositorySafeText(file.kind),
                  observedRepositorySafeText(file.indexStatus),
                  observedRepositorySafeText(file.workTreeStatus),
                  file.indexStatus.allSatisfy({ ".MADRCUT?!".contains($0) }),
                  file.workTreeStatus.allSatisfy({ ".MADRCUT?!".contains($0) })
            else { throw ValidationError.invalidKind }
            guard file.isUntracked == (file.kind == "untracked"),
                  file.isIgnored == (file.kind == "ignored"),
                  !(file.isUntracked && file.isIgnored) else {
                throw ValidationError.invalidKind
            }
            if let originalPath = file.originalPath {
                guard observedRepositoryValidRelativePath(originalPath, maxBytes: limits.pathBytes)
                else { throw ValidationError.oversizedPath }
            }
        }
        let diffKinds = diffs.map(\.kind)
        guard diffKinds.allSatisfy({ $0 == "staged" || $0 == "unstaged" }),
              Set(diffKinds).count == diffKinds.count,
              diffKinds == diffKinds.sorted(by: { $0 == "staged" && $1 == "unstaged" })
        else { throw ValidationError.invalidKind }
        for diff in diffs {
            guard diff.byteCount >= 0, diff.byteCount <= limits.diffBytes,
                  diff.retainedSectionCount >= 0,
                  !diff.truncated,
                  let text = diff.text, !text.isEmpty,
                  text.utf8.count == diff.byteCount,
                  text.utf8.count <= limits.diffBytes
            else { throw ValidationError.oversizedText }
        }
        for omission in omissions {
            guard omission.kind.utf8.count <= limits.stringBytes,
                  omission.detail.utf8.count <= limits.stringBytes,
                  observedRepositorySafeText(omission.kind),
                  observedRepositorySafeText(omission.detail)
            else { throw ValidationError.oversizedText }
            if let path = omission.path {
                guard observedRepositoryValidRelativePath(path, maxBytes: limits.pathBytes)
                else { throw ValidationError.oversizedPath }
            }
        }
        for exclusion in exclusions {
            guard exclusion.utf8.count <= limits.stringBytes,
                  observedRepositorySafeText(exclusion)
            else { throw ValidationError.oversizedText }
        }
        switch status {
        case .notRepository:
            guard head == nil, fenceBefore == nil, fenceAfter == nil,
                  repositoryIdentityDigest == nil, files.isEmpty, diffs.isEmpty else {
                throw ValidationError.invalidStatus
            }
        case .timedOut:
            guard head == nil, fenceBefore == nil, fenceAfter == nil,
                  repositoryIdentityDigest == nil,
                  files.isEmpty, diffs.isEmpty, coverage.bounded,
                  omissions.contains(where: { $0.kind == "timeout" }) else {
                throw ValidationError.invalidStatus
            }
        case .cancelled:
            guard head == nil, fenceBefore == nil, fenceAfter == nil,
                  repositoryIdentityDigest == nil,
                  files.isEmpty, diffs.isEmpty, coverage.bounded,
                  omissions.contains(where: { $0.kind == "cancelled" }) else {
                throw ValidationError.invalidStatus
            }
        case .failed:
            guard head == nil, fenceBefore == nil, fenceAfter == nil,
                  repositoryIdentityDigest == nil,
                  files.isEmpty, diffs.isEmpty else { throw ValidationError.invalidStatus }
        case .unstableConflict:
            guard head != nil, repositoryIdentityDigest != nil,
                  fenceBefore != nil, fenceAfter != nil, fenceBefore != fenceAfter,
                  diffs.isEmpty,
                  omissions.contains(where: { $0.kind == "conflict" }) else {
                throw ValidationError.invalidStatus
            }
        case .clean:
            guard head != nil, fenceBefore != nil, fenceAfter != nil,
                  repositoryIdentityDigest != nil,
                  diffs.isEmpty, files.allSatisfy(\.isIgnored), !coverage.bounded else {
                throw ValidationError.invalidStatus
            }
        case .changes:
            guard head != nil, fenceBefore != nil, fenceAfter != nil,
                  repositoryIdentityDigest != nil, !coverage.bounded,
                  !diffs.isEmpty || files.contains(where: { !$0.isIgnored }) else {
                throw ValidationError.invalidStatus
            }
        case .bounded:
            guard head != nil, fenceBefore != nil, fenceAfter != nil,
                  repositoryIdentityDigest != nil, coverage.bounded, diffs.isEmpty else {
                throw ValidationError.invalidStatus
            }
        }
    }
}

/// Injectable observer for tests and Work Host integration. The closure receives only literal
/// Git arguments and a private cwd; it is never a shell command string.
public struct ObservedRepositoryReviewer: Sendable {
    public typealias CommandRunner = @Sendable
        (_ arguments: [String], _ cwd: URL, _ timeout: TimeInterval)
        async -> ObservedRepositoryGitCommandResult

    private let commandRunner: CommandRunner

    public init(commandRunner: CommandRunner? = nil) {
        self.commandRunner = commandRunner ?? Self.liveCommandRunner
    }

    public func observe(
        cwd: URL,
        runID: String,
        turnID: String,
        observedAt: Date = Date(),
        limits: ObservedRepositoryReviewLimits = .default) async -> ObservedRepositoryReview
    {
        // Keep this span around the actual bounded Git observation.  Only bounded facts leave
        // the process: the Run/Turn are correlation hashes, while status and measurements are
        // emitted as a fixed completion event after the observer has settled.  In particular,
        // no cwd, path, diff, or retained body is ever an attribute or event value.
        return await AviaryTelemetry.withSpan(
            "aviary.repository.review",
            attributes: [
                "aviary.run.id": .string(AviaryTelemetry.identity(runID)),
                "aviary.turn.id": .string(AviaryTelemetry.identity(turnID)),
            ]) {
                let observer = ObservationState(
                    cwd: cwd.standardizedFileURL,
                    runID: runID,
                    turnID: turnID,
                    observedAt: observedAt,
                    limits: limits,
                    commandRunner: commandRunner)
                let review = await observer.run()
                var attributes: [String: AviaryTraceValue] = [
                    "aviary.repository.review.status": .string(review.status.rawValue),
                    "aviary.repository.review.files": .int(review.files.count),
                    "aviary.repository.review.diffs": .int(review.diffs.count),
                    "aviary.repository.review.omissions": .int(review.omissions.count),
                    "aviary.repository.review.diff_bytes": .int(
                        review.diffs.reduce(0) { partial, diff in
                            let (value, overflow) = partial.addingReportingOverflow(
                                max(0, diff.byteCount))
                            return overflow ? Int.max : value
                        }),
                    "aviary.repository.review.bounded": .bool(review.coverage.bounded),
                ]
                if AviaryTelemetry.context != nil,
                   let artifactBytes = try? review.encoded().count {
                    attributes["aviary.repository.review.artifact_bytes"] = .int(artifactBytes)
                }
                AviaryTelemetry.event("aviary.repository.review.completed", attributes: attributes)
                switch review.status {
                case .clean, .changes, .bounded:
                    AviaryTelemetry.outcome("completed")
                case .notRepository:
                    AviaryTelemetry.outcome("unavailable")
                case .unstableConflict:
                    AviaryTelemetry.outcome("indeterminate")
                case .timedOut, .failed:
                    AviaryTelemetry.outcome("failed")
                case .cancelled:
                    AviaryTelemetry.outcome("cancelled")
                }
                return review
            }
    }

    public static let liveCommandRunner: CommandRunner = { arguments, cwd, timeout in
        await ObservedRepositoryBoundedGitRunner.run(arguments: arguments, cwd: cwd, timeout: timeout)
    }
}

/// ``Shell.run`` is intentionally general-purpose and returns complete streams. A repository
/// review cannot use that helper: a hostile or simply enormous diff would be buffered before the
/// review's limits were applied. This private runner caps each pipe while it is being drained.
private enum ObservedRepositoryBoundedGitRunner {
    private static let stdoutLimit = 512 * 1024
    private static let stderrLimit = 32 * 1024

    static func run(
        arguments: [String], cwd: URL, timeout: TimeInterval
    ) async -> ObservedRepositoryGitCommandResult {
        let control = ObservedRepositoryProcessControl()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard !Task.isCancelled else {
                        continuation.resume(returning: ObservedRepositoryGitCommandResult(cancelled: true))
                        return
                    }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.arguments = [
                        "-c", "core.fsmonitor=false",
                        "-c", "core.untrackedCache=false",
                    ] + arguments
                    process.currentDirectoryURL = cwd
                    var environment = ProcessEnvironment.shared.snapshot
                    // Git may otherwise refresh optional index metadata during a read-only
                    // command. This reduces incidental writes without pretending configured Git
                    // hooks/helpers or the unrestricted process are a containment boundary.
                    environment["GIT_OPTIONAL_LOCKS"] = "0"
                    // Repository discovery must describe this cwd, not a repository redirected
                    // by inherited Git variables. A fixed locale also makes the one discovery
                    // diagnostic we classify below stable across login-shell environments.
                    for key in [
                        "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
                        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                        "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES",
                        "GIT_DISCOVERY_ACROSS_FILESYSTEM",
                    ] {
                        environment.removeValue(forKey: key)
                    }
                    environment["LC_ALL"] = "C"
                    environment["LANG"] = "C"
                    environment["LANGUAGE"] = "C"
                    process.environment = environment
                    process.standardInput = FileHandle.nullDevice
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    let stdout = ObservedRepositoryBoundedDataSink(limit: stdoutLimit)
                    let stderr = ObservedRepositoryBoundedDataSink(limit: stderrLimit)
                    let readers = DispatchGroup()
                    for (pipe, sink) in [(stdoutPipe, stdout), (stderrPipe, stderr)] {
                        readers.enter()
                        DispatchQueue.global(qos: .utility).async {
                            while true {
                                guard let chunk = try? pipe.fileHandleForReading.read(upToCount: 16 * 1024),
                                      !chunk.isEmpty else { break }
                                sink.append(chunk)
                            }
                            readers.leave()
                        }
                    }
                    do {
                        try process.run()
                    } catch {
                        try? stdoutPipe.fileHandleForReading.close()
                        try? stderrPipe.fileHandleForReading.close()
                        _ = readers.wait(timeout: .now() + 1)
                        continuation.resume(returning: ObservedRepositoryGitCommandResult(exitCode: -1))
                        return
                    }
                    control.attach(process)
                    let deadline = DispatchWorkItem {
                        if control.requestTimeout() {
                            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                                control.forceKillIfRunning()
                            }
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    process.waitUntilExit()
                    if readers.wait(timeout: .now() + 0.5) == .timedOut {
                        // A misconfigured descendant may inherit Git's pipes. Bound completion
                        // anyway and close our read ends; this is cleanup, not a process-tree
                        // containment claim.
                        try? stdoutPipe.fileHandleForReading.close()
                        try? stderrPipe.fileHandleForReading.close()
                    }
                    deadline.cancel()
                    let state = control.finish()
                    let captured = stdout.value()
                    let errors = stderr.value()
                    continuation.resume(returning: ObservedRepositoryGitCommandResult(
                        stdout: captured.data, stderr: errors.data,
                        exitCode: process.terminationStatus,
                        timedOut: state.timedOut, cancelled: state.cancelled,
                        stdoutTruncated: captured.truncated, stderrTruncated: errors.truncated))
                }
            }
        }, onCancel: {
            if control.requestCancellation() {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    control.forceKillIfRunning()
                }
            }
        })
    }
}

private final class ObservedRepositoryBoundedDataSink: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var didTruncate = false

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else {
            didTruncate = true
            return
        }
        let remaining = limit - data.count
        if chunk.count > remaining {
            data.append(chunk.prefix(remaining))
            didTruncate = true
        } else {
            data.append(chunk)
        }
    }

    func value() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, didTruncate)
    }
}

private final class ObservedRepositoryProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var didTimeout = false
    private var didCancel = false
    private var finished = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = didCancel || didTimeout
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }

    func requestTimeout() -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        didTimeout = true
        let process = self.process
        lock.unlock()
        process?.terminate()
        return true
    }

    func requestCancellation() -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        didCancel = true
        let process = self.process
        lock.unlock()
        process?.terminate()
        return true
    }

    func forceKillIfRunning() {
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    func finish() -> (timedOut: Bool, cancelled: Bool) {
        lock.lock()
        finished = true
        let result = (didTimeout, didCancel)
        lock.unlock()
        return result
    }
}

private struct ObservationState: Sendable {
    let cwd: URL
    let runID: String
    let turnID: String
    let observedAt: Date
    let limits: ObservedRepositoryReviewLimits
    let commandRunner: ObservedRepositoryReviewer.CommandRunner
    let deadlineNanos: UInt64

    init(
        cwd: URL,
        runID: String,
        turnID: String,
        observedAt: Date,
        limits: ObservedRepositoryReviewLimits,
        commandRunner: @escaping ObservedRepositoryReviewer.CommandRunner)
    {
        self.cwd = cwd
        self.runID = runID
        self.turnID = turnID
        self.observedAt = observedAt
        self.limits = limits
        self.commandRunner = commandRunner
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = UInt64(limits.timeout * 1_000_000_000)
        let (deadline, overflow) = now.addingReportingOverflow(delta)
        self.deadlineNanos = overflow ? UInt64.max : deadline
    }

    struct Command {
        let result: ObservedRepositoryGitCommandResult
        let stdout: Data
        let stderr: Data
        let outputTruncated: Bool
    }

    struct Status {
        let entries: [RawStatus]
        let omissions: [ObservedRepositoryOmission]
        let boundedData: Data
        let truncated: Bool
        let digest: String
    }

    struct Fence {
        let head: ObservedRepositoryHead
        let status: Status
        let contentDigest: String?

        init(head: ObservedRepositoryHead, status: Status, contentDigest: String? = nil) {
            self.head = head
            self.status = status
            self.contentDigest = contentDigest
        }

        func recordingContent(_ digest: String) -> Fence {
            Fence(head: head, status: status, contentDigest: digest)
        }

        var publicValue: ObservedRepositoryFence {
            ObservedRepositoryFence(
                head: head, statusDigest: status.digest, contentDigest: contentDigest,
                statusEntryCount: status.entries.count, statusTruncated: status.truncated)
        }
    }

    struct RawStatus {
        let path: String
        let originalPath: String?
        let indexStatus: String
        let workTreeStatus: String
        let kind: String
        let isUntracked: Bool
        let isIgnored: Bool
        let isSubmodule: Bool
    }

    enum Stop: Error { case timedOut, cancelled, failed }

    func run() async -> ObservedRepositoryReview {
        var omissions: [ObservedRepositoryOmission] = []
        let exclusions = [
            "structured file metadata uses repository-relative paths; tracked diff text is unfiltered file content",
            "untracked and ignored file bodies are never read",
            "binary and submodule diff bodies are never retained",
            "this artifact is observation only; it cannot stage, revert, commit, checkpoint, or restore",
        ]

        do {
            try checkCancellation()
            guard let root = try await repositoryRoot() else {
                return make(
                    status: .notRepository, root: nil, head: nil, before: nil, after: nil,
                    files: [], diffs: [], omissions: [
                        ObservedRepositoryOmission(kind: "not_repository", detail: "cwd is not inside a Git worktree")
                    ], exclusions: exclusions, statusObserved: false, staged: false, unstaged: false,
                    bounded: false)
            }
            let identityDigest = digest(for: root.path)
            let beforeStatus = try await fence(root: root)
            let staged = try await diff(kind: "staged", arguments: [
                "-c", "core.quotePath=false", "diff", "--cached", "--no-ext-diff",
                "--no-color", "--no-renames", "--no-textconv", "--",
            ], root: root, omissions: &omissions)
            let unstaged = try await diff(kind: "unstaged", arguments: [
                "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color",
                "--no-renames", "--no-textconv", "--",
            ], root: root, omissions: &omissions)
            // A second diff capture is part of the content fence. HEAD and porcelain status can
            // remain unchanged while a tracked file is edited in place during this read.
            let stagedAfter = try await diff(kind: "staged", arguments: [
                "-c", "core.quotePath=false", "diff", "--cached", "--no-ext-diff",
                "--no-color", "--no-renames", "--no-textconv", "--",
            ], root: root, omissions: &omissions)
            let unstagedAfter = try await diff(kind: "unstaged", arguments: [
                "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color",
                "--no-renames", "--no-textconv", "--",
            ], root: root, omissions: &omissions)
            let afterStatus = try await fence(root: root)
            let before = beforeStatus.recordingContent(
                diffEvidenceDigest(staged: staged, unstaged: unstaged))
            let after = afterStatus.recordingContent(
                diffEvidenceDigest(staged: stagedAfter, unstaged: unstagedAfter))

            let statusAgrees = before.head == after.head
                && before.status.digest == after.status.digest
                && before.status.entries.count == after.status.entries.count
                && before.status.truncated == after.status.truncated
            let diffContentAgrees = equivalent(staged, stagedAfter)
                && equivalent(unstaged, unstagedAfter)
            let paths = statusFiles(before.status.entries, binaryPaths: staged.binaryPaths.union(unstaged.binaryPaths))
            omissions.append(contentsOf: before.status.omissions)
            for entry in before.status.entries where entry.isUntracked {
                omissions.append(ObservedRepositoryOmission(
                    kind: "untracked_body", path: entry.path,
                    detail: "untracked file name and status retained; body was not read"))
            }
            for entry in before.status.entries where entry.isIgnored {
                omissions.append(ObservedRepositoryOmission(
                    kind: "ignored", path: entry.path,
                    detail: "ignored file name and status retained; body was not read"))
            }
            for entry in before.status.entries where entry.isSubmodule {
                omissions.append(ObservedRepositoryOmission(
                    kind: "submodule", path: entry.path,
                    detail: "submodule contents are outside this worktree review"))
            }
            omissions.append(contentsOf: staged.omissions)
            omissions.append(contentsOf: unstaged.omissions)
            if !statusAgrees || !diffContentAgrees {
                omissions.append(ObservedRepositoryOmission(
                    kind: "conflict", detail: "HEAD, status, or diff content changed while the bounded review was running"))
                let evidenceWasIncomplete = omissions.contains {
                    observedRepositoryIncompleteEvidenceKinds.contains($0.kind)
                }
                return make(
                    status: .unstableConflict, root: root, identityDigest: identityDigest,
                    head: before.head, before: before, after: after, files: paths,
                    diffs: [], omissions: omissions, exclusions: exclusions,
                    statusObserved: true, staged: false, unstaged: false,
                    bounded: before.status.truncated || after.status.truncated
                        || staged.truncated || unstaged.truncated
                        || stagedAfter.truncated || unstagedAfter.truncated
                        || evidenceWasIncomplete,
                    fileEntriesTruncated: before.status.entries.count > limits.fileCount)
            }

            let evidenceWasIncomplete = omissions.contains {
                observedRepositoryIncompleteEvidenceKinds.contains($0.kind)
            }
            let bounded = before.status.truncated || after.status.truncated
                || staged.truncated || unstaged.truncated
                || stagedAfter.truncated || unstagedAfter.truncated
                || evidenceWasIncomplete
            if bounded {
                omissions.append(ObservedRepositoryOmission(
                    kind: "bounded", detail: "one or more Git streams reached the configured limit"))
            }
            let hasChanges = before.status.entries.contains { !$0.isIgnored }
            let status: ObservedRepositoryReviewStatus = !hasChanges
                ? .clean : (bounded ? .bounded : .changes)
            // A matching bounded prefix is not proof that its omitted suffix was stable or text.
            // Retain status/name metadata, but do not present a partial diff as review evidence.
            let diffs = bounded ? [] : [staged.value, unstaged.value].compactMap { $0 }
            return make(
                status: status, root: root, identityDigest: identityDigest, head: before.head,
                before: before, after: after, files: paths, diffs: diffs,
                omissions: omissions, exclusions: exclusions, statusObserved: true,
                staged: staged.value != nil, unstaged: unstaged.value != nil, bounded: bounded,
                fileEntriesTruncated: before.status.entries.count > limits.fileCount)
        } catch Stop.timedOut {
            omissions.append(ObservedRepositoryOmission(kind: "timeout", detail: "a Git observation exceeded its deadline"))
            return make(status: .timedOut, root: nil, head: nil, before: nil, after: nil,
                        files: [], diffs: [], omissions: omissions, exclusions: exclusions,
                        statusObserved: false, staged: false, unstaged: false, bounded: true)
        } catch Stop.cancelled {
            omissions.append(ObservedRepositoryOmission(kind: "cancelled", detail: "the observation task was cancelled"))
            return make(status: .cancelled, root: nil, head: nil, before: nil, after: nil,
                        files: [], diffs: [], omissions: omissions, exclusions: exclusions,
                        statusObserved: false, staged: false, unstaged: false, bounded: true)
        } catch {
            omissions.append(ObservedRepositoryOmission(kind: "failed", detail: boundedString(error.localizedDescription)))
            return make(status: .failed, root: nil, head: nil, before: nil, after: nil,
                        files: [], diffs: [], omissions: omissions, exclusions: exclusions,
                        statusObserved: false, staged: false, unstaged: false, bounded: false)
        }
    }

    private func repositoryRoot() async throws -> URL? {
        let result = try await command([
            "rev-parse", "--show-toplevel",
        ], cwd: cwd)
        guard result.result.succeeded else {
            if result.result.timedOut { throw Stop.timedOut }
            if result.result.cancelled { throw Stop.cancelled }
            // With the live runner's C locale and repository-redirect variables removed, this
            // is the only discovery failure we can classify. The filesystem check is essential:
            // Git emits the same message for an empty/corrupt `.git` as for a plain directory.
            guard result.result.exitCode == 128,
                  !result.outputTruncated,
                  let stderr = String(data: result.stderr, encoding: .utf8),
                  stderr.contains("not a git repository") else {
                throw Stop.failed
            }
            switch observedRepositoryDiscoveryEvidence(at: cwd) {
            case .none:
                return nil
            case .repositoryMetadata, .ambiguous:
                throw Stop.failed
            }
        }
        guard let path = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty, !path.contains("\0")
        else { throw Stop.failed }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private func fence(root: URL) async throws -> Fence {
        let headResult = try await command(["rev-parse", "--verify", "HEAD"], cwd: root)
        if headResult.result.timedOut { throw Stop.timedOut }
        if headResult.result.cancelled { throw Stop.cancelled }
        let oid: String?
        if headResult.result.succeeded {
            oid = try parseOID(headResult.stdout)
        } else {
            // An initialized repository with no commit has a symbolic HEAD but no OID. That is
            // a valid observation, distinct from a detached or failed repository.
            oid = nil
        }
        let refResult = try await command(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: root)
        if refResult.result.timedOut { throw Stop.timedOut }
        if refResult.result.cancelled { throw Stop.cancelled }
        let ref = refResult.result.succeeded
            ? parseRef(refResult.stdout)
            : nil
        guard headResult.result.succeeded || ref != nil else { throw Stop.failed }
        let statusResult = try await command([
            "status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=matching", "--",
        ], cwd: root)
        guard statusResult.result.succeeded else {
            if statusResult.result.timedOut { throw Stop.timedOut }
            if statusResult.result.cancelled { throw Stop.cancelled }
            throw Stop.failed
        }
        let bounded = cap(statusResult.stdout, to: limits.commandStdoutBytes)
        let parsed = parseStatus(bounded.data)
        return Fence(
            head: ObservedRepositoryHead(oid: oid, ref: ref, detached: ref == nil),
            status: Status(
                entries: parsed.entries, omissions: parsed.omissions,
                boundedData: bounded.data, truncated:
                    statusResult.outputTruncated || bounded.truncated,
                digest: digest(data: bounded.data)))
    }

    private struct DiffCapture {
        let value: ObservedRepositoryDiff?
        let truncated: Bool
        let binaryPaths: Set<String>
        let omissions: [ObservedRepositoryOmission]
        let evidenceDigest: String
    }

    private func diff(
        kind: String,
        arguments: [String],
        root: URL,
        omissions: inout [ObservedRepositoryOmission]) async throws -> DiffCapture
    {
        let result = try await command(arguments, cwd: root)
        if result.result.timedOut { throw Stop.timedOut }
        if result.result.cancelled { throw Stop.cancelled }
        guard result.result.succeeded else { throw Stop.failed }
        let capped = cap(result.stdout, to: min(limits.commandStdoutBytes, limits.diffBytes))
        var evidence = Data(kind.utf8)
        evidence.append(0)
        evidence.append(capped.data)
        evidence.append((capped.truncated || result.outputTruncated) ? 1 : 0)
        let evidenceDigest = digest(data: evidence)
        guard let raw = String(data: capped.data, encoding: .utf8) else {
            return DiffCapture(
                value: nil, truncated: capped.truncated || result.outputTruncated,
                binaryPaths: [], omissions: [ObservedRepositoryOmission(
                    kind: "invalid_diff", detail: "Git emitted non-UTF-8 diff bytes")],
                evidenceDigest: evidenceDigest)
        }
        let sections = raw.isEmpty ? [] : raw.components(separatedBy: "diff --git ")
        var retained: [String] = []
        var binaryPaths = Set<String>()
        var localOmissions: [ObservedRepositoryOmission] = []
        for (index, section) in sections.enumerated() {
            guard index > 0 else { continue }
            let complete = "diff --git " + section
            let path = parseDiffPath(section).flatMap { validPath($0) }
            let isBinary = complete.contains("\nBinary files ")
                || complete.contains("\nGIT binary patch")
                || complete.contains("\r\nBinary files ")
            let isSubmodule = complete.contains("Subproject commit ")
            if isBinary {
                if let path { binaryPaths.insert(path) }
                localOmissions.append(ObservedRepositoryOmission(
                    kind: "binary", path: path,
                    detail: "binary diff body was excluded; only the file status is retained"))
                continue
            }
            if isSubmodule {
                localOmissions.append(ObservedRepositoryOmission(
                    kind: "submodule", path: path,
                    detail: "submodule diff body was excluded; only the file status is retained"))
                continue
            }
            retained.append(complete)
        }
        let text = retained.isEmpty ? nil : retained.joined(separator: "")
        let value: ObservedRepositoryDiff? = raw.isEmpty || text == nil
            ? nil
            : ObservedRepositoryDiff(
                kind: kind, text: text, byteCount: text?.utf8.count ?? 0,
                truncated: capped.truncated || result.outputTruncated,
                retainedSectionCount: retained.count)
        return DiffCapture(
            value: value, truncated: capped.truncated || result.outputTruncated,
            binaryPaths: binaryPaths, omissions: localOmissions,
            evidenceDigest: evidenceDigest)
    }

    private func statusFiles(_ entries: [RawStatus], binaryPaths: Set<String>) -> [ObservedRepositoryFile] {
        var files: [ObservedRepositoryFile] = []
        for entry in entries.prefix(limits.fileCount) {
            let binary = binaryPaths.contains(entry.path)
            files.append(ObservedRepositoryFile(
                path: entry.path, kind: entry.kind,
                indexStatus: entry.indexStatus, workTreeStatus: entry.workTreeStatus,
                originalPath: entry.originalPath, isUntracked: entry.isUntracked,
                isIgnored: entry.isIgnored, isBinary: binary, isSubmodule: entry.isSubmodule))
        }
        return files.sorted { $0.path < $1.path }
    }

    private func equivalent(_ lhs: DiffCapture, _ rhs: DiffCapture) -> Bool {
        lhs.evidenceDigest == rhs.evidenceDigest
    }

    private func diffEvidenceDigest(
        staged: DiffCapture, unstaged: DiffCapture
    ) -> String {
        digest(data: Data((staged.evidenceDigest + "\n" + unstaged.evidenceDigest).utf8))
    }

    private func make(
        status: ObservedRepositoryReviewStatus,
        root: URL?,
        identityDigest: String? = nil,
        head: ObservedRepositoryHead?,
        before: Fence?,
        after: Fence?,
        files: [ObservedRepositoryFile],
        diffs: [ObservedRepositoryDiff],
        omissions: [ObservedRepositoryOmission],
        exclusions: [String],
        statusObserved: Bool,
        staged: Bool,
        unstaged: Bool,
        bounded: Bool,
        fileEntriesTruncated: Bool = false) -> ObservedRepositoryReview
    {
        let needsLimitMarker = fileEntriesTruncated
            || omissions.count > limits.omissionCount
        let effectiveBounded = bounded || needsLimitMarker
        let effectiveStatus: ObservedRepositoryReviewStatus =
            effectiveBounded && (status == .clean || status == .changes)
            ? .bounded : status
        var safeOmissions = Array(omissions.prefix(limits.omissionCount))
        if needsLimitMarker {
            let detail: String
            switch (fileEntriesTruncated, omissions.count > limits.omissionCount) {
            case (true, true):
                detail = "file entries and additional omission records were capped"
            case (true, false):
                detail = "file entries were capped at the configured limit"
            case (false, true):
                detail = "additional omission records were capped at the configured limit"
            case (false, false):
                detail = "review metadata reached a configured limit"
            }
            if safeOmissions.count == limits.omissionCount {
                safeOmissions.removeLast()
            }
            safeOmissions.append(ObservedRepositoryOmission(
                kind: "projection_limit", detail: detail))
        }
        let cappedOmissions = safeOmissions
            .map { omission in
                ObservedRepositoryOmission(
                    kind: boundedString(omission.kind), path: omission.path.flatMap(validPath),
                    detail: boundedString(omission.detail))
            }
        let coverage = ObservedRepositoryCoverage(
            statusObserved: statusObserved, stagedDiffObserved: staged,
            unstagedDiffObserved: unstaged, untrackedNamesOnly: true,
            ignoredNamesOnly: true, binaryBodiesExcluded: true,
            submoduleBodiesExcluded: true, bounded: effectiveBounded)
        let result = ObservedRepositoryReview(
            observedAt: observedAt, runID: boundedIdentity(runID), turnID: boundedIdentity(turnID),
            repositoryIdentityDigest: identityDigest, status: effectiveStatus, head: head,
            fenceBefore: before?.publicValue, fenceAfter: after?.publicValue,
            files: files.sorted { $0.path < $1.path },
            diffs: effectiveStatus == .bounded ? [] : diffs,
            omissions: Array(cappedOmissions), coverage: coverage,
            exclusions: exclusions.map(boundedString))
        // The artifact itself is Codable and validated by callers. If a pathological caller
        // chooses tiny limits, omit optional diff text rather than returning an oversized body.
        if let bytes = try? result.encoded(), bytes.count > limits.totalArtifactBytes {
            var fallbackFiles = files.sorted { $0.path < $1.path }
            var fallbackOmissions = Array(cappedOmissions.prefix(max(0, limits.omissionCount - 1))) + [ObservedRepositoryOmission(
                kind: "artifact_limit", detail: "diff sections and file entries were omitted to bound the artifact")]
            var fallbackExclusions = exclusions.map(boundedString)
            var fallbackIdentity = identityDigest
            var fallbackHead = head
            var fallbackBefore = before
            var fallbackAfter = after
            var fallbackStatus: ObservedRepositoryReviewStatus = .bounded
            var fallbackStatusObserved = statusObserved
            func fallback() -> ObservedRepositoryReview {
                ObservedRepositoryReview(
                    observedAt: observedAt, runID: boundedIdentity(runID), turnID: boundedIdentity(turnID),
                    repositoryIdentityDigest: fallbackIdentity, status: fallbackStatus, head: fallbackHead,
                    fenceBefore: fallbackBefore?.publicValue, fenceAfter: fallbackAfter?.publicValue,
                    files: fallbackFiles, diffs: [], omissions: fallbackOmissions,
                    coverage: ObservedRepositoryCoverage(
                    statusObserved: fallbackStatusObserved,
                    stagedDiffObserved: fallbackStatusObserved && staged,
                    unstagedDiffObserved: fallbackStatusObserved && unstaged,
                    untrackedNamesOnly: true,
                    ignoredNamesOnly: true, binaryBodiesExcluded: true,
                    submoduleBodiesExcluded: true, bounded: true),
                    exclusions: fallbackExclusions)
            }
            var boundedResult = fallback()
            while let encoded = try? boundedResult.encoded(),
                  encoded.count > limits.totalArtifactBytes
            {
                if !fallbackFiles.isEmpty {
                    fallbackFiles.removeLast()
                } else if fallbackOmissions.count > 1 {
                    fallbackOmissions.removeFirst()
                } else if !fallbackExclusions.isEmpty {
                    fallbackExclusions.removeLast()
                } else if fallbackBefore != nil || fallbackAfter != nil || fallbackHead != nil {
                    fallbackBefore = nil
                    fallbackAfter = nil
                    fallbackHead = nil
                    fallbackIdentity = nil
                    // Once the stable point-in-time fence itself no longer fits, this is not a
                    // review with reduced detail. It is an explicitly failed observation whose
                    // only retained fact is that artifact publication reached its hard bound.
                    fallbackStatus = .failed
                    fallbackStatusObserved = false
                } else {
                    break
                }
                boundedResult = fallback()
            }
            return boundedResult
        }
        return result
    }

    private func command(_ arguments: [String], cwd: URL) async throws -> Command {
        try checkCancellation()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineNanos else { throw Stop.timedOut }
        let remaining = TimeInterval(deadlineNanos - now) / 1_000_000_000
        let result = await commandRunner(arguments, cwd, remaining)
        if result.timedOut { throw Stop.timedOut }
        if result.cancelled { throw Stop.cancelled }
        let stdout = cap(result.stdout, to: limits.commandStdoutBytes)
        let stderr = cap(result.stderr, to: limits.commandStderrBytes)
        return Command(
            result: result, stdout: stdout.data, stderr: stderr.data,
            outputTruncated: stdout.truncated || stderr.truncated
                || result.stdoutTruncated || result.stderrTruncated)
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw Stop.cancelled }
        if DispatchTime.now().uptimeNanoseconds >= deadlineNanos { throw Stop.timedOut }
    }

    private func cap(_ data: Data, to limit: Int) -> (data: Data, truncated: Bool) {
        guard data.count > limit else { return (data, false) }
        return (Data(data.prefix(limit)), true)
    }

    private func parseOID(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            value.range(of: "^[0-9a-fA-F]{7,128}$", options: .regularExpression) != nil
        else { throw Stop.failed }
        return value.lowercased()
    }

    private func parseRef(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
            value.utf8.count <= limits.stringBytes,
            !value.hasPrefix("/"), !value.split(separator: "/").contains("..")
        else { return nil }
        return value
    }

    private func parseStatus(_ data: Data) -> (
        entries: [RawStatus], count: Int, omissions: [ObservedRepositoryOmission])
    {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var entries: [RawStatus] = []
        var omissions: [ObservedRepositoryOmission] = []
        var index = 0
        while index < records.count {
            let bytes = Data(records[index])
            guard let line = String(data: bytes, encoding: .utf8), !line.isEmpty else {
                omissions.append(ObservedRepositoryOmission(
                    kind: "invalid_status", detail: "Git emitted a non-UTF-8 status record"))
                index += 1
                continue
            }
            let first = line.first!
            if first == "?" || first == "!" {
                let path = String(line.dropFirst(2))
                if let valid = validPath(path) {
                    entries.append(RawStatus(
                        path: valid, originalPath: nil, indexStatus: ".", workTreeStatus: ".",
                        kind: first == "?" ? "untracked" : "ignored",
                        isUntracked: first == "?", isIgnored: first == "!", isSubmodule: false))
                } else {
                    omissions.append(ObservedRepositoryOmission(
                        kind: path.hasPrefix("/") || path.split(separator: "/").contains("..")
                            || !observedRepositorySafeText(path)
                            ? "out_of_bound" : "invalid_status",
                        detail: "a status path was rejected as out of scope"))
                }
                index += 1
                continue
            }
            if first == "1" || first == "2" || first == "u" {
                let requiredParts = first == "1" ? 9 : (first == "2" ? 10 : 11)
                let maxSplits = requiredParts - 1
                let parts = line.split(separator: " ", maxSplits: maxSplits,
                                       omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= requiredParts,
                      parts[1].count == 2,
                      let path = validPath(parts.last ?? "")
                else {
                    omissions.append(ObservedRepositoryOmission(
                        kind: "invalid_status", detail: "a Git porcelain-v2 record was rejected"))
                    index += 1
                    continue
                }
                let xy = Array(parts[1])
                let sub = parts[2]
                let kind = xy[0] == "?" || xy[1] == "?" ? "untracked" : "tracked"
                var original: String?
                if first == "2" && index + 1 < records.count,
                   let candidate = String(data: Data(records[index + 1]), encoding: .utf8),
                   let validOriginal = validPath(candidate)
                {
                    original = validOriginal
                    index += 1
                }
                entries.append(RawStatus(
                    path: path, originalPath: original, indexStatus: String(xy[0]),
                    workTreeStatus: String(xy[1]), kind: kind,
                    isUntracked: false, isIgnored: false, isSubmodule: sub.first == "S"))
                index += 1
                continue
            }
            // Accept porcelain-v1 records as a defensive fallback for older Git versions.
            if line.count >= 3 {
                let chars = Array(line)
                let path = String(line.dropFirst(3))
                if chars[0] == "?" || chars[0] == "!" {
                    if let valid = validPath(path) {
                        entries.append(RawStatus(
                            path: valid, originalPath: nil, indexStatus: ".", workTreeStatus: ".",
                            kind: chars[0] == "?" ? "untracked" : "ignored",
                            isUntracked: chars[0] == "?", isIgnored: chars[0] == "!", isSubmodule: false))
                    }
                } else if let valid = validPath(path) {
                    entries.append(RawStatus(
                        path: valid, originalPath: nil, indexStatus: String(chars[0]),
                        workTreeStatus: String(chars[1]), kind: "tracked",
                        isUntracked: false, isIgnored: false, isSubmodule: false))
                }
            } else {
                omissions.append(ObservedRepositoryOmission(
                    kind: "invalid_status", detail: "a Git status record was rejected"))
            }
            index += 1
        }
        return (entries, records.count, omissions)
    }

    private func parseDiffPath(_ section: String) -> String? {
        let lines = section.split(whereSeparator: { $0.isNewline }).map(String.init)
        for line in lines {
            if line.hasPrefix("--- a/") {
                return String(line.dropFirst("--- a/".count))
            }
            if line.hasPrefix("+++ b/") {
                return String(line.dropFirst("+++ b/".count))
            }
            if line.hasPrefix("Binary files a/"),
               let separator = line.range(of: " and b/", options: .backwards),
               line.hasSuffix(" differ")
            {
                let start = line.index(
                    line.startIndex, offsetBy: "Binary files a/".count)
                return String(line[start..<separator.lowerBound])
            }
        }
        // The header is ambiguous when a path contains spaces. Use it only for the simple case;
        // structured status metadata still carries the exact NUL-delimited path when this is nil.
        guard let header = lines.first,
              !header.hasPrefix("\""),
              let separator = header.range(of: " b/", options: .backwards)
        else { return nil }
        let candidate = header[..<separator.lowerBound]
        return candidate.hasPrefix("a/") ? String(candidate.dropFirst(2)) : nil
    }

    private func validPath(_ path: String) -> String? {
        guard observedRepositoryValidRelativePath(path, maxBytes: limits.pathBytes)
        else { return nil }
        return path
    }

    private func boundedString(_ value: String) -> String {
        guard value.utf8.count > limits.stringBytes else { return value }
        return String(decoding: Data(value.utf8.prefix(limits.stringBytes)), as: UTF8.self)
    }

    private func boundedIdentity(_ value: String) -> String {
        let limit = min(limits.stringBytes, max(1, limits.totalArtifactBytes / 8))
        guard value.utf8.count > limit else { return value }
        return String(decoding: Data(value.utf8.prefix(limit)), as: UTF8.self)
    }

    private func digest(for path: String) -> String {
        digest(data: Data("aviary.repository.identity.v1\0\(path)".utf8))
    }

    private func digest(data: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: data).description
    }
}
