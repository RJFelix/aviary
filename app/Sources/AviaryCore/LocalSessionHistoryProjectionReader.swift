import Foundation

/// Owner-locked reader for the metadata index and canonical message bodies of one Session.
///
/// Every returned message is reread from its JSONL byte range and checked against immutable index
/// metadata. The private derived index supplies selected-branch membership and completeness under
/// Aviary's cooperating-writer trust model; canonical rows supply the returned body bytes and
/// exact row evidence. `read()` deliberately owns one Timeline owner lock for the complete
/// operation; it never calls `LocalTimelineProjectionReader.read()`, whose shorter lease would
/// create a gap between index selection and canonical range reads.
public struct LocalSessionHistoryProjectionReader: Sendable {
    public struct Limits: Hashable, Sendable {
        public static let standard = Limits()
        public let maximumChunkBytes: Int
        public let maximumLineBytes: Int
        public let maximumPhysicalEvents: Int
        public let maximumPageRecords: Int
        public let maximumPageBytes: Int
        public let maximumPrefixProofBytes: Int

        public init(
            maximumChunkBytes: Int = 64 * 1_024,
            maximumLineBytes: Int = 1 * 1_024 * 1_024,
            maximumPhysicalEvents: Int = 4_000_000,
            maximumPageRecords: Int = 128,
            maximumPageBytes: Int = 256 * 1_024,
            maximumPrefixProofBytes: Int = 64 * 1_024 * 1_024
        ) {
            self.maximumChunkBytes = max(1, min(maximumChunkBytes, 4 * 1_024 * 1_024))
            self.maximumLineBytes = max(1, min(maximumLineBytes, 64 * 1_024 * 1_024))
            self.maximumPhysicalEvents = max(1, min(maximumPhysicalEvents, 8_000_000))
            self.maximumPageRecords = max(1, min(maximumPageRecords, 4_096))
            self.maximumPageBytes = max(1, min(maximumPageBytes, 64 * 1_024 * 1_024))
            self.maximumPrefixProofBytes = max(
                1, min(maximumPrefixProofBytes, 256 * 1_024 * 1_024))
        }
    }

    public enum ReaderError: Error, LocalizedError, Equatable, Sendable {
        case unsupportedJournal
        case sourceChanged
        case sourceIncomplete
        case malformedLine
        case lineTooLarge
        case tooManyEvents
        case invalidRange
        case canonicalMismatch
        case pageTooLarge
        case pageCannotProgress(requiredBytes: Int, maximumBytes: Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedJournal: return "Session history requires a Session journal."
            case .sourceChanged: return "The Session journal changed during history reading."
            case .sourceIncomplete: return "Session history projection is incomplete."
            case .malformedLine: return "The Session journal contains a malformed line."
            case .lineTooLarge: return "A Session journal line exceeds the history reader bound."
            case .tooManyEvents: return "The Session journal exceeds the history reader bound."
            case .invalidRange: return "A persisted Session message range is invalid."
            case .canonicalMismatch: return "A persisted Session message does not match its journal bytes."
            case .pageTooLarge: return "The requested Session history page exceeds the bound."
            case .pageCannotProgress:
                return "The next Session history event exceeds the requested byte bound."
            }
        }
    }

    public struct Metrics: Codable, Hashable, Sendable {
        public let historyIndexBuilds: Int
        public let historyCacheHits: Int
        public let historyProjectionRebuilds: Int
        public let decodedPhysicalEvents: Int
        public let sourceBytesScanned: Int
        /// Largest raw journal chunk/line buffer held by the I/O path. This intentionally does
        /// not claim total process heap, which also includes bounded metadata dictionaries for
        /// selected messages and reducer identity.
        public let peakBufferBytes: Int
        public let metadataLookups: Int
        public let parentLinks: Int
        public let historyCanonicalRangeReads: Int
        public let historyCanonicalRangeBytes: Int
        public let historyMapObjects: Int
        public let historyMapBytes: Int

        fileprivate init(
            historyIndexBuilds: Int = 0,
            historyCacheHits: Int = 0,
            historyProjectionRebuilds: Int = 0,
            decodedPhysicalEvents: Int = 0,
            sourceBytesScanned: Int = 0,
            peakBufferBytes: Int = 0,
            metadataLookups: Int = 0,
            parentLinks: Int = 0,
            historyCanonicalRangeReads: Int = 0,
            historyCanonicalRangeBytes: Int = 0,
            historyMapObjects: Int = 0,
            historyMapBytes: Int = 0
        ) {
            self.historyIndexBuilds = max(0, historyIndexBuilds)
            self.historyCacheHits = max(0, historyCacheHits)
            self.historyProjectionRebuilds = max(0, historyProjectionRebuilds)
            self.decodedPhysicalEvents = max(0, decodedPhysicalEvents)
            self.sourceBytesScanned = max(0, sourceBytesScanned)
            self.peakBufferBytes = max(0, peakBufferBytes)
            self.metadataLookups = max(0, metadataLookups)
            self.parentLinks = max(0, parentLinks)
            self.historyCanonicalRangeReads = max(0, historyCanonicalRangeReads)
            self.historyCanonicalRangeBytes = max(0, historyCanonicalRangeBytes)
            self.historyMapObjects = max(0, historyMapObjects)
            self.historyMapBytes = max(0, historyMapBytes)
        }
    }

    public struct Result: Sendable {
        public let events: [TimelineEvent]
        public let source: PersistentSessionHistoryIndex.SourceProof
        public let semanticTip: EventRef?
        public let sessionAttachments: [PersistentSessionHistoryIndex.HistoryAttachmentRecord]
        /// Canonical relationship events reread and verified from their Session journal ranges
        /// under the same owner lock as the selected message page.
        public let relationshipEvents: [TimelineEvent]
        public let nextBeforeCursor: JournalCursor?
        public let hasOlder: Bool
        public let metrics: Metrics
        public let didBuildIndex: Bool
    }

    /// Current Session/Work relationship authority without selecting or materializing a message.
    /// This is intentionally separate from `read`: an authorization recheck must not depend on
    /// the caller's page byte budget or on the size of an unrelated newly appended message.
    public struct RelationshipAuthorityResult: Sendable {
        public let source: PersistentSessionHistoryIndex.SourceProof
        public let sessionAttachments: [PersistentSessionHistoryIndex.HistoryAttachmentRecord]
        public let relationshipEvents: [TimelineEvent]
        public let metrics: Metrics
        public let didBuildIndex: Bool
    }

    private struct ScanResult {
        let source: PersistentSessionHistoryIndex.SourceProof
        let semanticTip: EventRef?
        let eventCount: Int
        let bytes: Int
        let peakBuffer: Int
    }

    private let fileURL: URL
    private let home: AgentHome
    private let journal: JournalRef
    private let session: SessionRef
    private let index: PersistentSessionHistoryIndex
    private let lease: LocalTimelineProjectionSourceLease
    private let limits: Limits

    public init(
        home: AgentHome,
        session: SessionRef,
        journal: JournalRef,
        indexDirectory: URL,
        sourceLimits: LocalTimelineProjectionSourceLease.Limits = .default,
        indexLimits: PersistentSessionHistoryIndex.Limits = .default,
        limits: Limits = .standard
    ) throws {
        guard journal.owner == .session(session) else { throw ReaderError.unsupportedJournal }
        self.home = home
        self.session = session
        self.journal = journal
        self.fileURL = home.timelineV2SessionJournalURL(session).standardizedFileURL
        self.index = try PersistentSessionHistoryIndex(directory: indexDirectory, limits: indexLimits)
        self.lease = LocalTimelineProjectionSourceLease(
            fileURL: self.fileURL, journal: journal, limits: sourceLimits)
        self.limits = limits
    }

    /// Build or load the selected-branch index, then reread only the requested canonical lines.
    public func read(
        before: JournalCursor? = nil,
        frozenTip: JournalCursor? = nil,
        frozenTipDigest: String? = nil,
        branchTip: EventRef? = nil,
        limit: Int = 128,
        maxBytes: Int = 256 * 1_024
    ) throws -> Result {
        guard limit > 0, limit <= limits.maximumPageRecords,
              maxBytes > 0, maxBytes <= limits.maximumPageBytes,
              (frozenTip == nil) == (frozenTipDigest == nil) else {
            throw ReaderError.pageTooLarge
        }
        return try TimelineJournalWriter.withAdvisoryOwnerLock(
            home: home, journal: journal, dataURL: fileURL
        ) {
            try readLocked(
                before: before, frozenTip: frozenTip,
                frozenTipDigest: frozenTipDigest, branchTip: branchTip,
                limit: limit, maxBytes: maxBytes)
        }
    }

    public func readCurrentRelationshipAuthority() throws -> RelationshipAuthorityResult {
        try TimelineJournalWriter.withAdvisoryOwnerLock(
            home: home, journal: journal, dataURL: fileURL
        ) {
            try readCurrentRelationshipAuthorityLocked()
        }
    }

    private func readCurrentRelationshipAuthorityLocked(
        cacheRepairAttempted: Bool = false
    ) throws -> RelationshipAuthorityResult {
        let observed = try lease.observe()
        var manifest: PersistentSessionHistoryIndex.Manifest
        var didBuild = false
        var metrics = Metrics()

        do {
            let existing = try index.loadManifest()
            guard existing.source.session == session,
                  existing.source.journal == journal,
                  existing.source.sourceID
                    == LocalTimelineProjectionSourceLease.sourceID(for: journal),
                  existing.source.sourceGeneration == observed.source.sourceGeneration,
                  existing.source.prefixByteCount <= observed.source.sourceByteCount else {
                throw ReaderError.sourceChanged
            }
            if existing.source.prefixByteCount == observed.source.sourceByteCount {
                guard existing.source.sourceFingerprint == observed.source.fingerprint else {
                    throw ReaderError.sourceChanged
                }
                manifest = existing
                metrics = Metrics(historyCacheHits: 1)
            } else {
                let scan = try coldBuild(observed: observed)
                manifest = try index.loadManifest(proving: scan.source)
                didBuild = true
                metrics = Metrics(
                    historyIndexBuilds: 1, historyProjectionRebuilds: 1,
                    decodedPhysicalEvents: scan.eventCount,
                    sourceBytesScanned: scan.bytes, peakBufferBytes: scan.peakBuffer)
            }
        } catch let error as PersistentSessionHistoryIndex.IndexError {
            if error == .missingObject {
                let scan = try coldBuild(observed: observed)
                manifest = try index.loadManifest(proving: scan.source)
                didBuild = true
                metrics = Metrics(
                    historyIndexBuilds: 1, decodedPhysicalEvents: scan.eventCount,
                    sourceBytesScanned: scan.bytes, peakBufferBytes: scan.peakBuffer)
            } else if !cacheRepairAttempted, isRepairableCacheError(error) {
                try index.quarantineCache()
                return try readCurrentRelationshipAuthorityLocked(
                    cacheRepairAttempted: true)
            } else {
                throw mapIndexError(error)
            }
        }

        let relationship = try readCanonicalRelationships(
            manifest.relationshipEvents, source: manifest.source)
        let final = try lease.observe()
        guard final.source.sourceGeneration == observed.source.sourceGeneration,
              final.source.sourceByteCount == observed.source.sourceByteCount,
              final.source.fingerprint == observed.source.fingerprint else {
            throw ReaderError.sourceChanged
        }
        metrics = mergeMetrics(metrics, Metrics(
            peakBufferBytes: relationship.peakBuffer,
            historyCanonicalRangeReads: relationship.reads,
            historyCanonicalRangeBytes: relationship.bytes))
        return RelationshipAuthorityResult(
            source: manifest.source, sessionAttachments: manifest.sessionAttachments,
            relationshipEvents: relationship.events, metrics: metrics,
            didBuildIndex: didBuild)
    }

    private func readLocked(
        before: JournalCursor?,
        frozenTip: JournalCursor?,
        frozenTipDigest: String?,
        branchTip: EventRef?,
        limit: Int,
        maxBytes: Int,
        cacheRepairAttempted: Bool = false
    ) throws -> Result {
        let observed = try lease.observe()
        var built = false
        var buildMetrics = Metrics()
        var source: PersistentSessionHistoryIndex.SourceProof
        var semanticTip: EventRef?
        var currentRelationshipAuthority: CurrentRelationshipAuthority?

        let existingManifest: PersistentSessionHistoryIndex.Manifest?
        do {
            if let frozenTip, let frozenTipDigest {
                existingManifest = try index.loadManifest(
                    journal: journal, frozenCursor: frozenTip,
                    frozenWirePrefixDigest: frozenTipDigest)
            } else {
                existingManifest = try index.loadManifest()
            }
        } catch let error as PersistentSessionHistoryIndex.IndexError {
            // A missing moving HEAD is the normal first-read state. Other decode/checksum/object
            // failures describe disposable cache damage. Quarantine only that cache state and
            // rebuild from the canonical source while this read still holds the owner lock.
            if error == .missingObject && frozenTip == nil {
                existingManifest = nil
            } else if frozenTip != nil {
                // A frozen boundary is caller-supplied proof, not an authority to mutate the
                // shared cache. A missing/random boundary must fail closed without deleting the
                // valid moving HEAD or other GUI's frozen publications.
                throw mapIndexError(error)
            } else if !cacheRepairAttempted, isRepairableCacheError(error) {
                try index.quarantineCache()
                return try readLocked(
                    before: before, frozenTip: frozenTip,
                    frozenTipDigest: frozenTipDigest, branchTip: branchTip,
                    limit: limit, maxBytes: maxBytes, cacheRepairAttempted: true)
            } else {
                throw mapIndexError(error)
            }
        }
        if let manifest = existingManifest {
            guard manifest.source.session == session,
                  manifest.source.journal == journal,
                  manifest.source.sourceID == LocalTimelineProjectionSourceLease.sourceID(for: journal),
                  manifest.source.sourceGeneration == observed.source.sourceGeneration,
                  manifest.source.prefixByteCount <= observed.source.sourceByteCount else {
                // A successfully decoded publication that names a different source is not
                // disposable corruption. It may be a replacement/forgery, so never rebuild from
                // the new bytes merely because this is the latest (unfrozen) request.
                throw ReaderError.sourceChanged
            }
            if let frozenTip, let frozenTipDigest {
                guard manifest.source.physicalCursor == frozenTip,
                      manifest.source.wirePrefixDigest == frozenTipDigest,
                      manifest.semanticTip == branchTip else {
                    throw ReaderError.sourceIncomplete
                }
                let currentValidation = try validateCurrentHistorySemantics(
                    frozenManifest: manifest, observed: observed)
                let proof = try proveFrozenPrefix(
                    manifest: manifest, observed: observed)
                buildMetrics = mergeMetrics(currentValidation.metrics, Metrics(
                    historyCacheHits: 1, sourceBytesScanned: proof.bytes,
                    peakBufferBytes: proof.peakBuffer))
                currentRelationshipAuthority = currentValidation
                source = manifest.source
                semanticTip = manifest.semanticTip
            } else if manifest.source.prefixByteCount == observed.source.sourceByteCount {
                guard manifest.source.sourceFingerprint == observed.source.fingerprint else {
                    throw ReaderError.sourceChanged
                }
                source = manifest.source
                semanticTip = manifest.semanticTip
                buildMetrics = Metrics(historyCacheHits: 1)
            } else {
                // The latest source grew under the cooperating append-only owner lock. Rebuild
                // the moving HEAD from byte zero; old immutable boundary publications remain
                // addressable for GUIs already pinned to an earlier prefix.
                let scan = try coldBuild(observed: observed)
                source = scan.source
                semanticTip = scan.semanticTip
                built = true
                buildMetrics = Metrics(
                    historyIndexBuilds: 1, historyProjectionRebuilds: 1,
                    decodedPhysicalEvents: scan.eventCount, sourceBytesScanned: scan.bytes,
                    peakBufferBytes: scan.peakBuffer)
            }
        } else {
            let scan = try coldBuild(
                observed: observed, through: frozenTip,
                expectedWirePrefixDigest: frozenTipDigest,
                expectedSemanticTip: branchTip,
                requireSemanticTipMatch: frozenTip != nil)
            source = scan.source
            built = true
            semanticTip = scan.semanticTip
            buildMetrics = Metrics(
                historyIndexBuilds: 1,
                decodedPhysicalEvents: scan.eventCount, sourceBytesScanned: scan.bytes,
                peakBufferBytes: scan.peakBuffer)
            if frozenTip != nil {
                // Rebuilding a missing immutable boundary proves only the caller's frozen
                // content prefix. Relationship authority is deliberately current, so a cache
                // loss must still validate the suffix that followed that prefix before any old
                // message bytes are served.
                let frozenManifest = try index.loadManifest(provingFrozen: source)
                let currentValidation = try validateCurrentHistorySemantics(
                    frozenManifest: frozenManifest, observed: observed)
                currentRelationshipAuthority = currentValidation
                buildMetrics = mergeMetrics(buildMetrics, currentValidation.metrics)
            }
        }

        let page: PersistentSessionHistoryIndex.Page
        do {
            page = try index.loadPage(
                proving: source, semanticTip: semanticTip, before: before, limit: limit)
        } catch let error as PersistentSessionHistoryIndex.IndexError {
            if frozenTip == nil, !cacheRepairAttempted, isRepairableCacheError(error) {
                try index.quarantineCache()
                return try readLocked(
                    before: before, frozenTip: frozenTip,
                    frozenTipDigest: frozenTipDigest, branchTip: branchTip,
                    limit: limit, maxBytes: maxBytes, cacheRepairAttempted: true)
            }
            throw mapIndexError(error)
        }
        let boundedPage = try byteBoundedPage(page, maximumBytes: maxBytes)
        let rangeResult = try readCanonicalPage(boundedPage.records, source: source)
        let relationshipAuthority = currentRelationshipAuthority
            ?? CurrentRelationshipAuthority(
                source: source, records: page.relationshipEvents, metrics: Metrics())
        let relationshipResult = try readCanonicalRelationships(
            relationshipAuthority.records, source: relationshipAuthority.source)
        let final = try lease.observe()
        guard final.source.sourceGeneration == observed.source.sourceGeneration,
              final.source.sourceByteCount == observed.source.sourceByteCount,
              final.source.fingerprint == observed.source.fingerprint else {
            throw ReaderError.sourceChanged
        }

        let query = page.metrics
        let metrics = Metrics(
            historyIndexBuilds: buildMetrics.historyIndexBuilds,
            historyCacheHits: buildMetrics.historyCacheHits,
            historyProjectionRebuilds: buildMetrics.historyProjectionRebuilds,
            decodedPhysicalEvents: buildMetrics.decodedPhysicalEvents,
            sourceBytesScanned: buildMetrics.sourceBytesScanned,
            peakBufferBytes: max(
                buildMetrics.peakBufferBytes,
                max(rangeResult.peakBuffer, relationshipResult.peakBuffer)),
            metadataLookups: query.branchEntriesExamined,
            // Packed selected-branch pages use authenticated boundary lookup rather than
            // walking conversation-parent edges. Keep that cost distinct and truthful.
            parentLinks: 0,
            historyCanonicalRangeReads: rangeResult.reads + relationshipResult.reads,
            historyCanonicalRangeBytes: rangeResult.bytes + relationshipResult.bytes,
            historyMapObjects: query.objectsRead,
            historyMapBytes: query.bytesRead)
        return Result(
            events: rangeResult.events, source: source, semanticTip: page.semanticTip,
            sessionAttachments: page.sessionAttachments,
            relationshipEvents: relationshipResult.events,
            nextBeforeCursor: boundedPage.nextBeforeCursor,
            hasOlder: boundedPage.hasOlder,
            metrics: metrics, didBuildIndex: built)
    }

    /// Frozen pages retain their original content boundary, but Work relationship authority is
    /// current. If the Session grew after that boundary, authenticate a latest complete history
    /// publication (or rebuild it under this same owner lock) before serving the older page. This
    /// prevents an unknown Work-domain suffix from leaving stale attachment truth usable merely
    /// because a GUI already holds an earlier frozen cursor.
    private struct CurrentRelationshipAuthority {
        let source: PersistentSessionHistoryIndex.SourceProof
        let records: [PersistentSessionHistoryIndex.HistoryRelationshipEventRecord]
        let metrics: Metrics
    }

    private func validateCurrentHistorySemantics(
        frozenManifest: PersistentSessionHistoryIndex.Manifest,
        observed: LocalTimelineProjectionSourceLease.Observation
    ) throws -> CurrentRelationshipAuthority {
        guard frozenManifest.source.prefixByteCount < observed.source.sourceByteCount else {
            return CurrentRelationshipAuthority(
                source: frozenManifest.source,
                records: frozenManifest.relationshipEvents, metrics: Metrics())
        }
        if let latest = try? index.loadManifest(),
           latest.source.session == session,
           latest.source.journal == journal,
           latest.source.sourceGeneration == observed.source.sourceGeneration,
           latest.source.prefixByteCount == observed.source.sourceByteCount,
           latest.source.sourceFingerprint == observed.source.fingerprint {
            return CurrentRelationshipAuthority(
                source: latest.source, records: latest.relationshipEvents,
                metrics: Metrics())
        }
        let scan = try coldBuild(observed: observed)
        let latest = try index.loadManifest(proving: scan.source)
        return CurrentRelationshipAuthority(
            source: latest.source, records: latest.relationshipEvents,
            metrics: Metrics(
                historyIndexBuilds: 1, historyProjectionRebuilds: 1,
                decodedPhysicalEvents: scan.eventCount,
                sourceBytesScanned: scan.bytes, peakBufferBytes: scan.peakBuffer))
    }

    private func mergeMetrics(_ lhs: Metrics, _ rhs: Metrics) -> Metrics {
        func add(_ first: Int, _ second: Int) -> Int {
            first > Int.max - second ? Int.max : first + second
        }
        return Metrics(
            historyIndexBuilds: add(lhs.historyIndexBuilds, rhs.historyIndexBuilds),
            historyCacheHits: add(lhs.historyCacheHits, rhs.historyCacheHits),
            historyProjectionRebuilds: add(
                lhs.historyProjectionRebuilds, rhs.historyProjectionRebuilds),
            decodedPhysicalEvents: add(lhs.decodedPhysicalEvents, rhs.decodedPhysicalEvents),
            sourceBytesScanned: add(lhs.sourceBytesScanned, rhs.sourceBytesScanned),
            peakBufferBytes: max(lhs.peakBufferBytes, rhs.peakBufferBytes),
            metadataLookups: add(lhs.metadataLookups, rhs.metadataLookups),
            parentLinks: add(lhs.parentLinks, rhs.parentLinks),
            historyCanonicalRangeReads: add(
                lhs.historyCanonicalRangeReads, rhs.historyCanonicalRangeReads),
            historyCanonicalRangeBytes: add(
                lhs.historyCanonicalRangeBytes, rhs.historyCanonicalRangeBytes),
            historyMapObjects: add(lhs.historyMapObjects, rhs.historyMapObjects),
            historyMapBytes: add(lhs.historyMapBytes, rhs.historyMapBytes))
    }

    private func coldBuild(
        observed: LocalTimelineProjectionSourceLease.Observation,
        through frozenTip: JournalCursor? = nil,
        expectedWirePrefixDigest: String? = nil,
        expectedSemanticTip: EventRef? = nil,
        requireSemanticTipMatch: Bool = false
    ) throws -> ScanResult {
        if let frozenTip {
            guard frozenTip.journal == journal, frozenTip.sequence > 0,
                  frozenTip.sequence <= limits.maximumPhysicalEvents,
                  frozenTip.eventID != nil else { throw ReaderError.sourceIncomplete }
        }
        let rawSeed = DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal)
        var builder = try index.makeBuilder(
            session: session, journal: journal,
            sourceGeneration: observed.source.sourceGeneration)
        var rawPrefix = rawSeed
        var wirePrefix = PersistentSessionHistoryIndex.wirePrefixSeed(for: journal)
        let stream = try streamFromZero(through: frozenTip) { event, row in
            try builder.append(event: event, row: row)
            let lineDigest = try DisposableTimelineProjectionStore.canonicalEventLineDigest(event)
            rawPrefix = DisposableTimelineProjectionStore.advancePrefixDigest(
                rawPrefix, lineDigest: lineDigest)
            wirePrefix = PersistentSessionHistoryIndex.advanceWirePrefix(
                wirePrefix, lineDigest: lineDigest)
        }
        guard frozenTip != nil || stream.bytes == observed.source.sourceByteCount else {
            throw ReaderError.sourceChanged
        }
        if let frozenTip {
            guard stream.eventCount == frozenTip.sequence,
                  stream.lastEventID == frozenTip.eventID else {
                throw ReaderError.sourceIncomplete
            }
        }
        if let expectedWirePrefixDigest, expectedWirePrefixDigest != wirePrefix {
            throw ReaderError.sourceIncomplete
        }
        let physicalCursor = JournalCursor(
            journal: journal, eventID: stream.lastEventID, sequence: stream.eventCount)
        let source = PersistentSessionHistoryIndex.SourceProof(
            session: session, journal: journal,
            sourceID: LocalTimelineProjectionSourceLease.sourceID(for: journal),
            sourceGeneration: observed.source.sourceGeneration,
            sourceFingerprint: observed.source.fingerprint,
            physicalCursor: physicalCursor, prefixByteCount: stream.bytes,
            prefixDigest: rawPrefix, wirePrefixDigest: wirePrefix)
        // Perform the final source fence before publishing HEAD. The owner lock keeps a
        // cooperating writer out, so a failed fence cannot leave a newly published index for a
        // source that was changing during the scan.
        let prePublish = try lease.observe()
        guard prePublish.source.sourceGeneration == observed.source.sourceGeneration,
              prePublish.source.sourceByteCount == observed.source.sourceByteCount,
              prePublish.source.fingerprint == observed.source.fingerprint else {
            throw ReaderError.sourceChanged
        }
        let manifest = try builder.finalize(source: source)
        if requireSemanticTipMatch, manifest.semanticTip != expectedSemanticTip {
            throw ReaderError.sourceIncomplete
        }
        let after = try lease.observe()
        guard after.source.sourceGeneration == observed.source.sourceGeneration,
              after.source.sourceByteCount == observed.source.sourceByteCount,
              after.source.fingerprint == observed.source.fingerprint else {
            throw ReaderError.sourceChanged
        }
        return ScanResult(
            source: source, semanticTip: manifest.semanticTip,
            eventCount: stream.eventCount,
            bytes: stream.bytes, peakBuffer: stream.peakBuffer)
    }

    private struct StreamResult {
        let eventCount: Int
        let lastEventID: String?
        let bytes: Int
        let peakBuffer: Int
    }

    private func streamFromZero(
        through frozenTip: JournalCursor? = nil,
        consume: (TimelineEvent, DisposableTimelineProjectionStore.BucketRow) throws -> Void
    ) throws -> StreamResult {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch { throw ReaderError.sourceChanged }
        defer { try? handle.close() }
        var buffer = Data()
        var pendingStart = 0
        var offset = 0
        var sequence = 1
        var previous: String?
        var prefix = DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal)
        var count = 0
        var peak = 0
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: limits.maximumChunkBytes) ?? Data() }
            catch { throw ReaderError.sourceChanged }
            if chunk.isEmpty { break }
            buffer.append(chunk)
            peak = max(peak, buffer.count - pendingStart)
            guard buffer.count - pendingStart <= limits.maximumLineBytes + limits.maximumChunkBytes
            else { throw ReaderError.lineTooLarge }
            while let newline = buffer[pendingStart...].firstIndex(of: 0x0A) {
                let end = newline + 1
                let raw = Data(buffer[pendingStart..<end])
                pendingStart = end
                guard raw.count > 1, raw.last == 0x0A, raw.count <= limits.maximumLineBytes
                else { throw ReaderError.malformedLine }
                let content = raw.dropLast()
                let event: TimelineEvent
                do { event = try JSONDecoder().decode(TimelineEvent.self, from: content) }
                catch { throw ReaderError.malformedLine }
                guard event.schemaVersion == TimelineEvent.currentSchemaVersion,
                      event.payloadVersion <= 1, event.provenance == .native,
                      event.journal == journal, event.sequence == sequence,
                      event.previousEventID == previous,
                      event.evidenceLinkBoundsAreValid else { throw ReaderError.malformedLine }
                let lineDigest: String
                do { lineDigest = try DisposableTimelineProjectionStore.canonicalEventLineDigest(event) }
                catch { throw ReaderError.malformedLine }
                let after = DisposableTimelineProjectionStore.advancePrefixDigest(
                    prefix, lineDigest: lineDigest)
                let row = DisposableTimelineProjectionStore.BucketRow(
                    sequence: sequence, eventID: event.eventID,
                    previousEventID: previous, byteStart: offset, byteEnd: offset + raw.count,
                    prefixDigestBefore: prefix, prefixDigestAfter: after, lineDigest: lineDigest)
                try consume(event, row)
                prefix = after
                previous = event.eventID
                offset += raw.count
                sequence += 1
                count += 1
                guard count <= limits.maximumPhysicalEvents else { throw ReaderError.tooManyEvents }
                if let frozenTip, sequence - 1 == frozenTip.sequence {
                    guard previous == frozenTip.eventID else {
                        throw ReaderError.sourceIncomplete
                    }
                    return StreamResult(
                        eventCount: count, lastEventID: previous,
                        bytes: offset, peakBuffer: peak)
                }
            }
            if pendingStart > 0, pendingStart >= limits.maximumChunkBytes {
                buffer.removeSubrange(0..<pendingStart)
                pendingStart = 0
            }
        }
        guard pendingStart == buffer.count else { throw ReaderError.malformedLine }
        return StreamResult(eventCount: count, lastEventID: previous, bytes: offset, peakBuffer: peak)
    }

    private struct RangeResult {
        let events: [TimelineEvent]
        let reads: Int
        let bytes: Int
        let peakBuffer: Int
    }

    private struct RelationshipRangeResult {
        let events: [TimelineEvent]
        let reads: Int
        let bytes: Int
        let peakBuffer: Int
    }

    private struct BoundedPage {
        let records: [PersistentSessionHistoryIndex.MessageRecord]
        let nextBeforeCursor: JournalCursor?
        let hasOlder: Bool
    }

    /// Apply the Work-service byte contract before opening any canonical message ranges. The
    /// stored range includes one journal newline; standalone event-envelope bytes do not.
    private func byteBoundedPage(
        _ page: PersistentSessionHistoryIndex.Page,
        maximumBytes: Int
    ) throws -> BoundedPage {
        var newestFirst: [PersistentSessionHistoryIndex.MessageRecord] = []
        newestFirst.reserveCapacity(page.records.count)
        var bytes = 0
        for record in page.records.reversed() {
            let length = record.byteEnd - record.byteStart
            guard length > 1, length <= limits.maximumLineBytes else {
                throw ReaderError.invalidRange
            }
            let encodedBytes = length - 1
            guard encodedBytes <= maximumBytes else {
                if newestFirst.isEmpty {
                    throw ReaderError.pageCannotProgress(
                        requiredBytes: encodedBytes, maximumBytes: maximumBytes)
                }
                break
            }
            guard encodedBytes <= maximumBytes - bytes else { break }
            newestFirst.append(record)
            bytes += encodedBytes
        }
        newestFirst.reverse()
        let records = newestFirst
        let truncatedByBytes = records.count < page.records.count
        let hasOlder = page.hasOlder || truncatedByBytes
        return BoundedPage(
            records: records,
            nextBeforeCursor: hasOlder ? records.first?.sourceCursor : nil,
            hasOlder: hasOlder)
    }

    private struct PrefixProofMetrics {
        let bytes: Int
        let peakBuffer: Int
    }

    /// Authenticate an older manifest against the current append-only source by replaying at
    /// most one sparse-anchor interval. This is an owner-lock contract, not a sandbox proof: a
    /// non-cooperating writer that rewrites an unsampled earlier interval is outside the model.
    private func proveFrozenPrefix(
        manifest: PersistentSessionHistoryIndex.Manifest,
        observed: LocalTimelineProjectionSourceLease.Observation
    ) throws -> PrefixProofMetrics {
        let source = manifest.source
        guard source.session == session, source.journal == journal,
              source.sourceGeneration == observed.source.sourceGeneration,
              source.prefixByteCount <= observed.source.sourceByteCount else {
            throw ReaderError.sourceChanged
        }
        if source.prefixByteCount == observed.source.sourceByteCount {
            guard source.sourceFingerprint == observed.source.fingerprint else {
                throw ReaderError.sourceChanged
            }
            return PrefixProofMetrics(bytes: 0, peakBuffer: 0)
        }
        guard source.physicalCursor.sequence > 0,
              let anchor = lastAnchor(
                atOrBefore: source.physicalCursor.sequence, in: manifest.anchors),
              (anchor.cursor.sequence - 1)
                .isMultiple(of: PersistentSessionHistoryIndex.anchorStride),
              anchor.cursor.journal == journal,
              anchor.cursor.eventID != nil,
              anchor.byteStart >= 0, anchor.byteEnd > anchor.byteStart,
              anchor.byteEnd <= source.prefixByteCount else {
            throw ReaderError.sourceIncomplete
        }
        let length = source.prefixByteCount - anchor.byteStart
        guard length > 0, length <= limits.maximumPrefixProofBytes else {
            throw ReaderError.sourceIncomplete
        }
        let raw: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(anchor.byteStart))
            raw = try handle.read(upToCount: length) ?? Data()
        } catch {
            throw ReaderError.sourceChanged
        }
        guard raw.count == length, raw.last == 0x0A else {
            throw ReaderError.sourceChanged
        }
        var offset = 0
        var absoluteOffset = anchor.byteStart
        var sequence = anchor.cursor.sequence
        var previous = anchor.previousEventID
        var rawPrefix = anchor.prefixDigestBefore
        var wirePrefix = anchor.wirePrefixDigestBefore
        var eventCount = 0
        while offset < raw.count {
            guard let newline = raw[offset...].firstIndex(of: 0x0A) else {
                throw ReaderError.canonicalMismatch
            }
            let end = newline + 1
            let line = Data(raw[offset..<end])
            guard line.count > 1, line.count <= limits.maximumLineBytes else {
                throw ReaderError.lineTooLarge
            }
            let event: TimelineEvent
            do { event = try JSONDecoder().decode(TimelineEvent.self, from: line.dropLast()) }
            catch { throw ReaderError.canonicalMismatch }
            guard event.schemaVersion == TimelineEvent.currentSchemaVersion,
                  event.payloadVersion <= 1, event.provenance == .native,
                  event.journal == journal, event.session == nil || event.session == session,
                  event.sequence == sequence, event.previousEventID == previous,
                  event.evidenceLinkBoundsAreValid else {
                throw ReaderError.canonicalMismatch
            }
            let lineDigest: String
            do { lineDigest = try DisposableTimelineProjectionStore.canonicalEventLineDigest(event) }
            catch { throw ReaderError.canonicalMismatch }
            let nextRawPrefix = DisposableTimelineProjectionStore.advancePrefixDigest(
                rawPrefix, lineDigest: lineDigest)
            let nextWirePrefix = PersistentSessionHistoryIndex.advanceWirePrefix(
                wirePrefix, lineDigest: lineDigest)
            if eventCount == 0 {
                guard event.eventID == anchor.cursor.eventID,
                      absoluteOffset == anchor.byteStart,
                      absoluteOffset + line.count == anchor.byteEnd,
                      lineDigest == anchor.lineDigest,
                      nextRawPrefix == anchor.prefixDigestAfter,
                      nextWirePrefix == anchor.wirePrefixDigestAfter else {
                    throw ReaderError.canonicalMismatch
                }
            }
            absoluteOffset += line.count
            offset = end
            previous = event.eventID
            rawPrefix = nextRawPrefix
            wirePrefix = nextWirePrefix
            sequence += 1
            eventCount += 1
            guard eventCount <= PersistentSessionHistoryIndex.anchorStride else {
                throw ReaderError.sourceIncomplete
            }
        }
        guard absoluteOffset == source.prefixByteCount,
              sequence - 1 == source.physicalCursor.sequence,
              previous == source.physicalCursor.eventID,
              rawPrefix == source.prefixDigest,
              wirePrefix == source.wirePrefixDigest else {
            throw ReaderError.sourceIncomplete
        }
        return PrefixProofMetrics(bytes: raw.count, peakBuffer: raw.count)
    }

    private func lastAnchor(
        atOrBefore sequence: Int,
        in anchors: [PersistentSessionHistoryIndex.PhysicalAnchor]
    ) -> PersistentSessionHistoryIndex.PhysicalAnchor? {
        var low = 0
        var high = anchors.count
        while low < high {
            let mid = low + (high - low) / 2
            if anchors[mid].cursor.sequence <= sequence { low = mid + 1 }
            else { high = mid }
        }
        return low == 0 ? nil : anchors[low - 1]
    }

    private func readCanonicalPage(
        _ records: [PersistentSessionHistoryIndex.MessageRecord],
        source: PersistentSessionHistoryIndex.SourceProof
    ) throws -> RangeResult {
        var events: [TimelineEvent] = []
        events.reserveCapacity(records.count)
        var bytes = 0
        var peakBuffer = 0
        for record in records {
            guard record.sourceGeneration == source.sourceGeneration,
                  record.sourceCursor.journal == journal,
                  record.sourceCursor.sequence > 0,
                  record.byteStart >= 0, record.byteEnd > record.byteStart,
                  record.byteEnd - record.byteStart <= limits.maximumLineBytes,
                  record.byteEnd <= source.prefixByteCount else { throw ReaderError.invalidRange }
            let length = record.byteEnd - record.byteStart
            let raw: Data
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(record.byteStart))
                raw = try handle.read(upToCount: length) ?? Data()
            } catch { throw ReaderError.sourceChanged }
            guard raw.count == length, raw.last == 0x0A else { throw ReaderError.canonicalMismatch }
            let event: TimelineEvent
            do { event = try JSONDecoder().decode(TimelineEvent.self, from: raw.dropLast()) }
            catch { throw ReaderError.canonicalMismatch }
            try verify(event: event, record: record, raw: raw)
            events.append(event)
            bytes += raw.count
            peakBuffer = max(peakBuffer, raw.count)
        }
        return RangeResult(
            events: events, reads: records.count, bytes: bytes,
            peakBuffer: peakBuffer)
    }

    private func readCanonicalRelationships(
        _ records: [PersistentSessionHistoryIndex.HistoryRelationshipEventRecord],
        source: PersistentSessionHistoryIndex.SourceProof
    ) throws -> RelationshipRangeResult {
        var events: [TimelineEvent] = []
        events.reserveCapacity(records.count)
        var bytes = 0
        var peakBuffer = 0
        for record in records {
            guard record.sourceGeneration == source.sourceGeneration,
                  record.event.journal == journal,
                  record.cursor.journal == journal,
                  record.cursor.eventID == record.event.eventID,
                  record.cursor.sequence > 0,
                  record.byteStart >= 0, record.byteEnd > record.byteStart,
                  record.byteEnd - record.byteStart <= limits.maximumLineBytes,
                  record.byteEnd <= source.prefixByteCount else {
                throw ReaderError.invalidRange
            }
            let length = record.byteEnd - record.byteStart
            let raw: Data
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(record.byteStart))
                raw = try handle.read(upToCount: length) ?? Data()
            } catch {
                throw ReaderError.sourceChanged
            }
            guard raw.count == length, raw.last == 0x0A else {
                throw ReaderError.canonicalMismatch
            }
            let event: TimelineEvent
            do {
                event = try JSONDecoder().decode(TimelineEvent.self, from: raw.dropLast())
            } catch {
                throw ReaderError.canonicalMismatch
            }
            let lineDigest = try? DisposableTimelineProjectionStore.canonicalEventLineDigest(event)
            guard event.schemaVersion == TimelineEvent.currentSchemaVersion,
                  event.payloadVersion <= 1, event.provenance == .native,
                  event.evidenceLinkBoundsAreValid,
                  event.eventID == record.event.eventID,
                  event.journal == journal, event.session == session,
                  event.sequence == record.cursor.sequence,
                  event.previousEventID == record.previousEventID,
                  event.type == record.type,
                  lineDigest == record.lineDigest,
                  DisposableTimelineProjectionStore.advancePrefixDigest(
                    record.prefixDigestBefore, lineDigest: record.lineDigest)
                    == record.prefixDigestAfter else {
                throw ReaderError.canonicalMismatch
            }
            events.append(event)
            bytes += raw.count
            peakBuffer = max(peakBuffer, raw.count)
        }
        return RelationshipRangeResult(
            events: events, reads: records.count, bytes: bytes,
            peakBuffer: peakBuffer)
    }

    private func verify(
        event: TimelineEvent,
        record: PersistentSessionHistoryIndex.MessageRecord,
        raw: Data
    ) throws {
        guard event.eventID == record.eventID, event.journal == journal,
              event.session == nil || event.session == session,
              event.sequence == record.sourceCursor.sequence,
              event.previousEventID == record.previousEventID,
              event.conversationParent == record.conversationParent,
              let message = SessionMessageSnapshot.canonicalMessage(from: event),
              message.role == record.role,
              message.text.utf8.count == record.textByteCount,
              wireDigest(Data(message.text.utf8)) == record.textDigest,
              message.sourceEvent?.journal == journal,
              message.sourceEvent?.eventID == event.eventID,
              message.sourceCursor == record.sourceCursor,
              message.conversationParent == record.conversationParent,
              (try? DisposableTimelineProjectionStore.canonicalEventLineDigest(event)) == record.lineDigest,
              record.byteEnd - record.byteStart == raw.count else { throw ReaderError.canonicalMismatch }
        let after = DisposableTimelineProjectionStore.advancePrefixDigest(
            record.prefixDigestBefore, lineDigest: record.lineDigest)
        guard after == record.prefixDigestAfter else { throw ReaderError.canonicalMismatch }
    }

    private func wireDigest(_ data: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func mapIndexError(_ error: PersistentSessionHistoryIndex.IndexError) -> ReaderError {
        switch error {
        case .sourceMismatch, .invalidSource, .checksumMismatch, .missingObject,
                .schemaMismatch, .invalidRecord, .invalidBranch, .boundaryNotOnBranch:
            return .sourceIncomplete
        case .invalidCursor, .oversize: return .pageTooLarge
        default: return .sourceIncomplete
        }
    }

    private func isRepairableCacheError(
        _ error: PersistentSessionHistoryIndex.IndexError
    ) -> Bool {
        switch error {
        case .missingObject, .checksumMismatch, .schemaMismatch, .invalidRecord,
                .invalidBranch, .symlinkOrNonRegularFile, .insecurePermissions,
                .ioFailure:
            return true
        case .unavailable, .invalidIdentity, .invalidSource, .sourceMismatch,
                .duplicateIdentity, .chainMismatch, .missingSelectedTip,
                .boundaryNotOnBranch, .invalidCursor, .oversize:
            // These are request/source/semantic failures, not proof that the moving cache can be
            // safely discarded. In particular, never repair a forged or foreign frozen boundary.
            return false
        }
    }
}
