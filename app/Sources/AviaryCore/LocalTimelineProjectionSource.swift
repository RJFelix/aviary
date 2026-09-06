import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A bounded, read-only lease over one local canonical Timeline JSONL file.
///
/// The lease is an observation aid for ``DisposableTimelineProjectionStore``; it is not a
/// filesystem sandbox and it does not make an uncooperating writer safe.  The intended producer
/// is a cooperating append-only Timeline writer.  We open one descriptor with `O_NOFOLLOW`, fence
/// that descriptor against the path with `fstat`/`lstat`, perform only bounded `pread` calls, and
/// fence the descriptor and path again before returning.  A replacement, truncate, mode/owner
/// change, non-regular file, or a changed first boundary is rejected rather than being presented
/// as a valid source observation.
public struct LocalTimelineProjectionSourceLease: Sendable {
    /// Whether validation may accept bytes appended after the stored observation.
    ///
    /// The append-only case is a producer contract, not a filesystem or security proof. Callers
    /// must hold the canonical Timeline owner lock for the entire validation and suffix-read
    /// operation, and every cooperating writer must use that same lock. Without that authority,
    /// a bounded reader cannot distinguish a pure append from a rewrite of an unsampled middle
    /// range followed by an append.
    public enum GrowthPolicy: String, Codable, Hashable, Sendable {
        case requireUnchangedSource = "require_unchanged_source"
        case cooperatingAppendOnlyOwnerLock = "cooperating_append_only_owner_lock"
    }

    public struct Limits: Codable, Hashable, Sendable {
        public static let `default` = Limits()

        public let maximumSourceBytes: Int
        public let maximumBoundaryBytes: Int
        public let maximumTerminalBytes: Int

        public init(
            maximumSourceBytes: Int = Int.max / 4,
            maximumBoundaryBytes: Int = 4 * 1_024,
            maximumTerminalBytes: Int = 4 * 1_024 * 1_024
        ) {
            self.maximumSourceBytes = Self.clamp(maximumSourceBytes, upper: Int.max / 4)
            self.maximumBoundaryBytes = Self.clamp(maximumBoundaryBytes, upper: 1 * 1_024 * 1_024)
            self.maximumTerminalBytes = Self.clamp(
                maximumTerminalBytes, upper: min(64 * 1_024 * 1_024, Int.max / 4))
        }

        private static func clamp(_ value: Int, upper: Int) -> Int {
            max(1, min(value, upper))
        }
    }

    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case missing
        case inaccessible
        case symlinkOrNonRegularFile
        case insecurePermissions
        case sourceChanged
        case sourceTooLarge
        case invalidChallenge
        case invalidTerminal
        case invalidDigest
        case invalidOffsets
        case ioFailure

        public var errorDescription: String? {
            switch self {
            case .missing:
                return "The local Timeline source is missing."
            case .inaccessible:
                return "The local Timeline source is inaccessible."
            case .symlinkOrNonRegularFile:
                return "The local Timeline source is not a regular file."
            case .insecurePermissions:
                return "The local Timeline source permissions are not private."
            case .sourceChanged:
                return "The local Timeline source changed during observation."
            case .sourceTooLarge:
                return "The local Timeline source exceeds the bounded observation limit."
            case .invalidChallenge:
                return "The projection source challenge is not valid for this journal."
            case .invalidTerminal:
                return "The projection terminal event is not the challenged canonical record."
            case .invalidDigest:
                return "The projection source digest is invalid."
            case .invalidOffsets:
                return "The projection source byte range is invalid."
            case .ioFailure:
                return "The local Timeline source could not be read."
            }
        }
    }

    /// Counters are deliberately about work done, not a promise that a full journal was read.
    /// `bytesRead` is bounded by the boundary samples plus one terminal row.
    public struct Metrics: Codable, Hashable, Sendable {
        public let readCalls: Int
        public let bytesRead: Int
        public let peakReadBytes: Int
        public let boundaryBytes: Int
        public let terminalBytes: Int

        public init(
            readCalls: Int = 0,
            bytesRead: Int = 0,
            peakReadBytes: Int = 0,
            boundaryBytes: Int = 0,
            terminalBytes: Int = 0
        ) {
            self.readCalls = max(0, readCalls)
            self.bytesRead = max(0, bytesRead)
            self.peakReadBytes = max(0, peakReadBytes)
            self.boundaryBytes = max(0, boundaryBytes)
            self.terminalBytes = max(0, terminalBytes)
        }
    }

    public struct Observation: Hashable, Sendable {
        public let source: DisposableTimelineProjectionStore.SourceFingerprint
        public let metrics: Metrics

        public init(
            source: DisposableTimelineProjectionStore.SourceFingerprint,
            metrics: Metrics
        ) {
            self.source = source
            self.metrics = metrics
        }

        public var fingerprint: DisposableTimelineProjectionStore.SourceFingerprint { source }

        public var sourceFingerprint: DisposableTimelineProjectionStore.SourceFingerprint { source }
    }

    public let journal: JournalRef
    public let limits: Limits
    private let fileURL: URL

    public init(
        fileURL: URL,
        journal: JournalRef,
        limits: Limits = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.journal = journal
        self.limits = limits
    }

    public init(
        url: URL,
        journal: JournalRef,
        limits: Limits = .default
    ) {
        self.init(fileURL: url, journal: journal, limits: limits)
    }

    public init(
        _ fileURL: URL,
        journal: JournalRef,
        limits: Limits = .default
    ) {
        self.init(fileURL: fileURL, journal: journal, limits: limits)
    }

    /// Observe the file with bounded boundary reads.  The returned fingerprint intentionally
    /// proves only an empty prefix; use ``validate(_:)`` with the store's challenge before using
    /// it to load a non-empty projection.
    public func observe() throws -> Observation {
        let descriptor = try openSource()
        defer { _ = AviaryPOSIX.close(descriptor) }

        var metrics = MetricsAccumulator()
        let before = try fencedMetadata(descriptor)
        try validateReadableSize(before.size)
        let initialBoundary = try boundaryFacts(
            descriptor, size: before.size, metrics: &metrics)

        var after = try fencedMetadata(descriptor)
        guard after.size >= before.size else { throw Error.sourceChanged }
        try validateReadableSize(after.size)
        var finalBoundary = initialBoundary
        if after.size != before.size {
            finalBoundary = try boundaryFacts(
                descriptor, size: after.size, metrics: &metrics)
        }
        let final = try fencedMetadata(descriptor)
        guard final.sameIdentityAndSecurity(as: before),
              final.sameIdentityAndSecurity(as: after),
              final.size == after.size,
              finalBoundary.first == initialBoundary.first else {
            throw Error.sourceChanged
        }
        after = final

        return Observation(
            source: makeSourceFingerprint(
                metadata: after, boundary: finalBoundary,
                prefixByteCount: 0,
                prefixDigest: DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal)),
            metrics: metrics.value)
    }

    public func fingerprint() throws -> DisposableTimelineProjectionStore.SourceFingerprint {
        try observe().source
    }

    /// Prove the exact terminal row requested by a projection store.  This is suitable for:
    ///
    ///     try store.load { try lease.validate($0) }
    ///
    /// Only the terminal row's byte range is read. The default requires the exact stored source
    /// observation; accepting a newer append-only suffix requires the explicit owner-lock policy.
    public func validate(
        _ challenge: DisposableTimelineProjectionStore.SourceValidationChallenge
    ) throws -> DisposableTimelineProjectionStore.SourceFingerprint {
        try validateWithMetrics(challenge, growthPolicy: .requireUnchangedSource).source
    }

    public func validate(
        challenge: DisposableTimelineProjectionStore.SourceValidationChallenge
    ) throws -> DisposableTimelineProjectionStore.SourceFingerprint {
        try validate(challenge)
    }

    public func validateWithMetrics(
        _ challenge: DisposableTimelineProjectionStore.SourceValidationChallenge,
        growthPolicy: GrowthPolicy = .requireUnchangedSource
    ) throws -> Observation {
        guard challenge.storedSource.journal == journal,
              challenge.cursor.journal == journal,
              challenge.prefixSeed.sequence >= 0,
              challenge.prefixSeed.sequence < Int.max,
              challenge.prefixSeed.byteCount >= 0,
              validDigest(challenge.prefixSeed.digest),
              challenge.prefixSeed.byteCount <= limits.maximumSourceBytes,
              challenge.cursor.sequence >= 0,
              challenge.cursor.sequence < Int.max,
              challenge.storedSource.sourceByteCount >= 0,
              challenge.storedSource.prefixByteCount >= 0,
              validDigest(challenge.storedSource.sourceGeneration),
              validDigest(challenge.storedSource.fingerprint),
              validDigest(challenge.storedSource.prefixDigest) else {
            throw Error.invalidChallenge
        }

        let descriptor = try openSource()
        defer { _ = AviaryPOSIX.close(descriptor) }
        var metrics = MetricsAccumulator()
        let before = try fencedMetadata(descriptor)
        try validateReadableSize(before.size)
        guard before.size >= challenge.storedSource.sourceByteCount else {
            throw Error.sourceChanged
        }

        let expectedSourceID = Self.sourceID(for: journal)
        let expectedGeneration = Self.sourceGeneration(for: journal, metadata: before)
        guard challenge.storedSource.sourceID == expectedSourceID,
              challenge.storedSource.sourceGeneration == expectedGeneration else {
            throw Error.invalidChallenge
        }
        // This lease proves bytes from the canonical beginning of a local journal. It does not
        // accept a caller's digest as proof of an omitted prefix, even when a later terminal row
        // is individually valid. A future exact continuation protocol may add a distinct lease
        // type for nonzero seeds; silently treating one as equivalent would promote unproven state.
        guard challenge.prefixSeed.sequence == 0,
              challenge.prefixSeed.byteCount == 0,
              challenge.prefixSeed.previousEventID == nil,
              challenge.prefixSeed.digest
                == DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal) else {
            throw Error.invalidChallenge
        }

        let initialBoundary = try boundaryFacts(
            descriptor, size: before.size, metrics: &metrics)
        let prefixEvidence: PrefixEvidence
        if let terminal = challenge.terminalRow {
            prefixEvidence = try proveTerminal(
                terminal, challenge: challenge, descriptor: descriptor,
                sourceSize: before.size, metrics: &metrics)
        } else {
            // With no terminal row, only the explicit empty canonical prefix can be current.
            guard challenge.cursor.sequence == 0,
                  challenge.cursor.eventID == nil,
                  challenge.prefixSeed.sequence == 0,
                  challenge.prefixSeed.byteCount == 0,
                  challenge.prefixSeed.previousEventID == nil,
                  challenge.prefixSeed.digest
                    == DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal),
                  challenge.storedSource.prefixByteCount == 0,
                  challenge.storedSource.prefixDigest
                    == DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal) else {
                throw Error.invalidChallenge
            }
            prefixEvidence = PrefixEvidence(
                byteCount: challenge.prefixSeed.byteCount,
                digest: challenge.prefixSeed.digest)
        }

        let observedAfterRead = try fencedMetadata(descriptor)
        guard observedAfterRead.size >= before.size else { throw Error.sourceChanged }
        try validateReadableSize(observedAfterRead.size)
        var finalBoundary = initialBoundary
        if observedAfterRead.size != before.size {
            finalBoundary = try boundaryFacts(
                descriptor, size: observedAfterRead.size, metrics: &metrics)
        }
        let after = try fencedMetadata(descriptor)
        try validateReadableSize(after.size)
        guard after.sameIdentityAndSecurity(as: before),
              after.sameIdentityAndSecurity(as: observedAfterRead),
              after.size == observedAfterRead.size,
              finalBoundary.first == initialBoundary.first else {
            throw Error.sourceChanged
        }

        let observation = Observation(
            source: makeSourceFingerprint(
                metadata: after, boundary: finalBoundary,
                prefixByteCount: prefixEvidence.byteCount,
                prefixDigest: prefixEvidence.digest),
            metrics: metrics.value)
        if growthPolicy == .requireUnchangedSource {
            guard observation.source.sourceByteCount == challenge.storedSource.sourceByteCount,
                  observation.source.fingerprint == challenge.storedSource.fingerprint else {
                throw Error.sourceChanged
            }
        }
        return observation
    }

    /// A spelling that emphasizes that the challenge is a proof rather than a cache load.
    public func prove(
        _ challenge: DisposableTimelineProjectionStore.SourceValidationChallenge
    ) throws -> DisposableTimelineProjectionStore.SourceFingerprint {
        try validate(challenge)
    }

    // MARK: Descriptor and source identity

    private func openSource() throws -> Int32 {
        let descriptor = fileURL.path.withCString {
            // O_NONBLOCK prevents a FIFO/device at the final path from blocking before fstat can
            // reject it. It has no effect on ordinary regular files.
            AviaryPOSIX.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: throw Error.missing
            case ELOOP: throw Error.symlinkOrNonRegularFile
            case EACCES, EPERM: throw Error.inaccessible
            default: throw Error.ioFailure
            }
        }
        return descriptor
    }

    private struct FileMetadata: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
        let fileType: UInt32
        let owner: UInt64
        let mode: UInt32
        let size: Int
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        func sameIdentityAndSecurity(as other: FileMetadata) -> Bool {
            device == other.device && inode == other.inode && fileType == other.fileType
                && owner == other.owner && mode == other.mode
        }
    }

    private func fencedMetadata(_ descriptor: Int32) throws -> FileMetadata {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else { throw Error.ioFailure }
        var pathStatus = stat()
        let pathResult = fileURL.path.withCString { localLStat($0, &pathStatus) }
        guard pathResult == 0 else {
            switch errno {
            case ENOENT: throw Error.missing
            case ELOOP: throw Error.symlinkOrNonRegularFile
            case EACCES, EPERM: throw Error.inaccessible
            default: throw Error.ioFailure
            }
        }

        let descriptorMetadata = try metadata(from: descriptorStatus)
        let pathMetadata = try metadata(from: pathStatus)
        guard descriptorMetadata.sameIdentityAndSecurity(as: pathMetadata) else {
            throw Error.sourceChanged
        }
        return descriptorMetadata
    }

    private func metadata(from status: stat) throws -> FileMetadata {
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= off_t(Int.max) else {
            throw Error.symlinkOrNonRegularFile
        }
        let mode = UInt32(status.st_mode)
        guard UInt64(status.st_uid) == UInt64(geteuid()),
              (mode & 0o077) == 0,
              (mode & UInt32(S_IRUSR)) != 0 else {
            throw Error.insecurePermissions
        }

        #if canImport(Darwin)
        let modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        let modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        let changeSeconds = Int64(status.st_ctimespec.tv_sec)
        let changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        #elseif canImport(Glibc)
        let modificationSeconds = Int64(status.st_mtim.tv_sec)
        let modificationNanoseconds = Int64(status.st_mtim.tv_nsec)
        let changeSeconds = Int64(status.st_ctim.tv_sec)
        let changeNanoseconds = Int64(status.st_ctim.tv_nsec)
        #else
        let modificationSeconds: Int64 = 0
        let modificationNanoseconds: Int64 = 0
        let changeSeconds: Int64 = 0
        let changeNanoseconds: Int64 = 0
        #endif

        return FileMetadata(
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino),
            fileType: UInt32(status.st_mode & S_IFMT), owner: UInt64(status.st_uid), mode: mode,
            size: Int(status.st_size), modificationSeconds: modificationSeconds,
            modificationNanoseconds: modificationNanoseconds, changeSeconds: changeSeconds,
            changeNanoseconds: changeNanoseconds)
    }

    private func validateReadableSize(_ size: Int) throws {
        guard size >= 0 else { throw Error.sourceChanged }
        guard size <= limits.maximumSourceBytes else { throw Error.sourceTooLarge }
    }

    public static func sourceID(for journal: JournalRef) -> String {
        "aviary-local-source-v1." + digest(Data(
            "aviary-local-source-id-v1\u{0}\(journal.stableKey)".utf8))
    }

    private static func sourceGeneration(
        for journal: JournalRef, metadata: FileMetadata
    ) -> String {
        let material = [
            "aviary-local-source-generation-v1", journal.stableKey,
            String(metadata.device), String(metadata.inode), String(metadata.fileType),
        ].map(component).joined(separator: "\u{0}")
        return digest(Data(material.utf8))
    }

    private func makeSourceFingerprint(
        metadata: FileMetadata,
        boundary: BoundaryFacts,
        prefixByteCount: Int,
        prefixDigest: String
    ) -> DisposableTimelineProjectionStore.SourceFingerprint {
        let generation = Self.sourceGeneration(for: journal, metadata: metadata)
        let material = [
            "aviary-local-source-fingerprint-v1", journal.stableKey, generation,
            String(metadata.size), String(metadata.owner), String(metadata.mode),
            String(metadata.modificationSeconds), String(metadata.modificationNanoseconds),
            String(metadata.changeSeconds), String(metadata.changeNanoseconds),
            boundary.firstDigest, boundary.lastDigest,
        ].map(Self.component).joined(separator: "\u{0}")
        return DisposableTimelineProjectionStore.SourceFingerprint(
            journal: journal,
            sourceID: Self.sourceID(for: journal),
            sourceGeneration: generation,
            fingerprint: Self.digest(Data(material.utf8)),
            sourceByteCount: metadata.size,
            prefixByteCount: prefixByteCount,
            prefixDigest: prefixDigest)
    }

    private struct BoundaryFacts: Hashable, Sendable {
        let first: Data
        let last: Data
        let firstDigest: String
        let lastDigest: String
    }

    private func boundaryFacts(
        _ descriptor: Int32, size: Int, metrics: inout MetricsAccumulator
    ) throws -> BoundaryFacts {
        guard size >= 0 else { throw Error.sourceChanged }
        let firstCount = min(size, limits.maximumBoundaryBytes)
        let first = try preadExact(
            descriptor, offset: 0, count: firstCount, metrics: &metrics, boundary: true)
        let last: Data
        if size <= limits.maximumBoundaryBytes {
            last = first
        } else {
            last = try preadExact(
                descriptor, offset: size - limits.maximumBoundaryBytes,
                count: limits.maximumBoundaryBytes, metrics: &metrics, boundary: true)
        }
        return BoundaryFacts(
            first: first, last: last, firstDigest: Self.digest(first), lastDigest: Self.digest(last))
    }

    private struct PrefixEvidence: Hashable, Sendable {
        let byteCount: Int
        let digest: String
    }

    private func proveTerminal(
        _ row: DisposableTimelineProjectionStore.BucketRow,
        challenge: DisposableTimelineProjectionStore.SourceValidationChallenge,
        descriptor: Int32,
        sourceSize: Int,
        metrics: inout MetricsAccumulator
    ) throws -> PrefixEvidence {
        guard row.sequence > challenge.prefixSeed.sequence,
              row.sequence == challenge.cursor.sequence,
              row.eventID == challenge.cursor.eventID,
              row.byteStart >= 0,
              row.byteEnd > row.byteStart,
              row.byteEnd <= sourceSize,
              row.byteEnd <= limits.maximumSourceBytes,
              row.byteEnd - row.byteStart <= limits.maximumTerminalBytes,
              challenge.storedSource.prefixByteCount == row.byteEnd,
              challenge.storedSource.prefixDigest == row.prefixDigestAfter,
              validDigest(row.prefixDigestBefore),
              validDigest(row.prefixDigestAfter),
              validDigest(row.lineDigest) else {
            throw Error.invalidOffsets
        }
        if row.sequence == challenge.prefixSeed.sequence + 1 {
            guard row.byteStart == challenge.prefixSeed.byteCount,
                  row.previousEventID == challenge.prefixSeed.previousEventID,
                  row.prefixDigestBefore == challenge.prefixSeed.digest else {
                throw Error.invalidChallenge
            }
        } else {
            guard row.byteStart >= challenge.prefixSeed.byteCount else {
                throw Error.invalidOffsets
            }
        }

        let bytes = try preadExact(
            descriptor, offset: row.byteStart, count: row.byteEnd - row.byteStart,
            metrics: &metrics, boundary: false)
        guard bytes.last == UInt8(ascii: "\n"), bytes.count > 1 else {
            throw Error.invalidTerminal
        }
        let content = Data(bytes.dropLast())
        guard let event = try? JSONDecoder().decode(TimelineEvent.self, from: content),
              event.provenance == .native,
              event.schemaVersion == TimelineEvent.currentSchemaVersion,
              event.journal == journal,
              event.sequence == row.sequence,
              event.eventID == row.eventID,
              event.previousEventID == row.previousEventID,
              !event.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              event.evidenceLinkBoundsAreValid else {
            throw Error.invalidTerminal
        }
        guard let lineDigest = try? DisposableTimelineProjectionStore.canonicalEventLineDigest(event),
              lineDigest == row.lineDigest else {
            throw Error.invalidTerminal
        }
        let prefixAfter = DisposableTimelineProjectionStore.advancePrefixDigest(
            row.prefixDigestBefore, lineDigest: lineDigest)
        guard prefixAfter == row.prefixDigestAfter else { throw Error.invalidTerminal }
        return PrefixEvidence(byteCount: row.byteEnd, digest: prefixAfter)
    }

    // MARK: Bounded POSIX reads

    private struct MetricsAccumulator {
        var calls = 0
        var bytes = 0
        var peak = 0
        var boundary = 0
        var terminal = 0

        mutating func add(_ count: Int, boundary isBoundary: Bool) {
            guard count > 0 else { return }
            calls = calls > Int.max - 1 ? Int.max : calls + 1
            bytes = count > Int.max - bytes ? Int.max : bytes + count
            peak = max(peak, count)
            if isBoundary {
                boundary = count > Int.max - boundary ? Int.max : boundary + count
            } else {
                terminal = count > Int.max - terminal ? Int.max : terminal + count
            }
        }

        var value: Metrics {
            Metrics(
                readCalls: calls, bytesRead: bytes, peakReadBytes: peak,
                boundaryBytes: boundary, terminalBytes: terminal)
        }
    }

    private func preadExact(
        _ descriptor: Int32,
        offset: Int,
        count: Int,
        metrics: inout MetricsAccumulator,
        boundary: Bool
    ) throws -> Data {
        guard offset >= 0, count >= 0, offset <= Int.max - count else {
            throw Error.invalidOffsets
        }
        if count == 0 { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        var consumed = 0
        while consumed < count {
            let amount = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return localPRead(
                    descriptor, base.advanced(by: consumed), count - consumed,
                    off_t(offset + consumed))
            }
            if amount > 0 {
                consumed += amount
                metrics.add(amount, boundary: boundary)
                continue
            }
            if amount == 0 { throw Error.sourceChanged }
            if errno == EINTR { continue }
            throw Error.ioFailure
        }
        return Data(bytes)
    }

    private static func component(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    private static func digest(_ data: Data) -> String {
        AviarySHA256.hash(data: data).description
    }

    private func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 65 && $0.value <= 70)
                    || ($0.value >= 97 && $0.value <= 102)
            }
    }
}

/// Short spelling for integrations that treat the lease as a source rather than a descriptor.
public typealias LocalTimelineProjectionSource = LocalTimelineProjectionSourceLease

private func localLStat(
    _ path: UnsafePointer<CChar>, _ result: UnsafeMutablePointer<stat>
) -> Int32 {
    #if canImport(Darwin)
    return Darwin.lstat(path, result)
    #elseif canImport(Glibc)
    return Glibc.lstat(path, result)
    #else
    return -1
    #endif
}

private func localPRead(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ count: Int,
    _ offset: off_t
) -> Int {
    #if canImport(Darwin)
    return Darwin.pread(descriptor, buffer, count, offset)
    #elseif canImport(Glibc)
    return Glibc.pread(descriptor, buffer, count, offset)
    #else
    return -1
    #endif
}
