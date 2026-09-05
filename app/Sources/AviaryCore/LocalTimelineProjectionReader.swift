import Foundation

/// A bounded reader for one canonical, local Timeline JSONL journal.
///
/// This type is a composition layer: LocalTimelineProjectionSourceLease proves the local source
/// descriptor and DisposableTimelineProjectionStore owns the disposable index. It is not a
/// sandbox, a security boundary, or a second authority. The complete operation holds the same
/// advisory owner lock as cooperating canonical writers, then fences each source observation and
/// fails closed if the source is not stable for the operation.
///
/// The reader never uses Data(contentsOf:). Cold and growth rebuilds use bounded FileHandle
/// chunks, retain only the current line plus bounded index/page data, and publish one store
/// generation after the source and typed reducer replay have both succeeded. Work growth performs
/// one bounded zero-based index pass plus a separately metered exact-state suffix pass from a
/// persisted proof; Session growth retains its two truthful zero-based passes.
public struct LocalTimelineProjectionReader: Sendable {
    public enum JournalKind: String, Codable, Hashable, Sendable {
        case work
        case session
    }

    public struct Limits: Codable, Hashable, Sendable {
        public static let standard = Limits()

        public let maximumChunkBytes: Int
        public let maximumLineBytes: Int
        public let maximumSeenEventIDs: Int
        public let maximumIndexedRows: Int
        public let maximumRecentPageEvents: Int
        public let maximumRecentEventBytes: Int
        /// Until exact disk-backed continuation state is integrated, a rebuild uses the ordinary
        /// in-memory reducer. This explicit source bound keeps that bootstrap path finite rather
        /// than pretending count limits alone are a practical memory budget.
        public let maximumBootstrapSourceBytes: Int

        public init(
            maximumChunkBytes: Int = 64 * 1_024,
            maximumLineBytes: Int = 1 * 1_024 * 1_024,
            maximumSeenEventIDs: Int = 1_000_000,
            maximumIndexedRows: Int = 65_535,
            maximumRecentPageEvents: Int = 2_048,
            maximumRecentEventBytes: Int = 4 * 1_024 * 1_024,
            maximumBootstrapSourceBytes: Int = 64 * 1_024 * 1_024
        ) {
            self.maximumChunkBytes = Self.clamp(maximumChunkBytes, upper: 4 * 1_024 * 1_024)
            self.maximumLineBytes = Self.clamp(maximumLineBytes, upper: 64 * 1_024 * 1_024)
            self.maximumSeenEventIDs = Self.clamp(maximumSeenEventIDs, upper: 4_000_000)
            self.maximumIndexedRows = Self.clamp(maximumIndexedRows, upper: 1_000_000)
            self.maximumRecentPageEvents = Self.clamp(maximumRecentPageEvents, upper: 16_384)
            self.maximumRecentEventBytes = Self.clamp(
                maximumRecentEventBytes, upper: 64 * 1_024 * 1_024)
            self.maximumBootstrapSourceBytes = Self.clamp(
                maximumBootstrapSourceBytes, upper: 1 * 1_024 * 1_024 * 1_024)
        }

        private static func clamp(_ value: Int, upper: Int) -> Int {
            max(1, min(value, upper))
        }
    }

    public enum ReaderError: Swift.Error, LocalizedError, Equatable, Sendable {
        case unsupportedJournal
        case sourceChanged
        case sourceTooLarge
        case malformedLine
        case truncatedTail
        case lineTooLarge
        case duplicateIdentity
        case tooManyEvents
        case tooManyIndexedRows
        case tooManyBuckets
        case invalidCachedProjection
        case cacheUnavailable
        case projectionFailed
        /// The bounded Work query projection may understand an event family that the v1
        /// persistent exact-state overlay deliberately does not.  In that case no combined
        /// HEAD/root publication is safe; callers must use an explicitly supported rebuild path.
        case exactStateUnavailable
        case storeRejected

        public var errorDescription: String? {
            switch self {
            case .unsupportedJournal:
                return "Only Work and Session journals can be locally projected."
            case .sourceChanged:
                return "The canonical Timeline source changed during projection."
            case .sourceTooLarge:
                return "The canonical Timeline source exceeds the bounded reader limit."
            case .malformedLine:
                return "The canonical Timeline contains a malformed event line."
            case .truncatedTail:
                return "The canonical Timeline ends with an unterminated event line."
            case .lineTooLarge:
                return "A canonical Timeline event line exceeds the bounded reader limit."
            case .duplicateIdentity:
                return "The canonical Timeline contains a duplicate event identity."
            case .tooManyEvents:
                return "The canonical Timeline exceeds the bounded duplicate-detection limit."
            case .tooManyIndexedRows:
                return "The projection exceeds its bounded index capacity."
            case .tooManyBuckets:
                return "The projection exceeds the store's bounded bucket-per-commit limit."
            case .invalidCachedProjection:
                return "The cached projection cannot be used as a typed projection."
            case .cacheUnavailable:
                return "The disposable projection cache is unavailable."
            case .projectionFailed:
                return "The canonical Timeline could not produce a typed projection."
            case .exactStateUnavailable:
                return "The Work exact-state overlay cannot represent this canonical event yet."
            case .storeRejected:
                return "The disposable projection store rejected the projection."
            }
        }
    }

    /// Index and reducer-replay costs are intentionally separate. Work growth reports the bounded
    /// suffix read used by its persisted exact reducer state; the bounded index still rebuilds
    /// from zero. Session growth remains zero-based and reports no suffix-only work.
    public struct Metrics: Codable, Hashable, Sendable {
        public let cacheHit: Bool
        public let rebuiltIndex: Bool
        public let reducerReplayedFromZero: Bool
        public let readCalls: Int
        public let bytesRead: Int
        public let suffixBytesRead: Int
        public let reducerReplayBytesRead: Int
        public let peakBufferedBytes: Int
        /// Bytes inspected while framing newline-delimited events during the index pass. Each
        /// source byte is examined at most once, so this remains linear even for a long line that
        /// spans many chunks.
        public let newlineBytesExamined: Int
        public let peakRecentEventBytes: Int
        public let decodedEventCount: Int
        public let indexedRowCount: Int
        public let sealedBucketCount: Int
        public let recentPageCount: Int
        /// Exact Work cache validation authenticates the root and scalar continuation only.
        /// Full typed-value availability is audited during publication or an explicit repair
        /// operation, while a bounded lookup authenticates any records needed for growth.
        public let exactStateValidationNodesVisited: Int
        public let exactStateValidationObjectsRead: Int
        public let exactStateValidationBytesRead: Int

        public init(
            cacheHit: Bool = false,
            rebuiltIndex: Bool = false,
            reducerReplayedFromZero: Bool = false,
            readCalls: Int = 0,
            bytesRead: Int = 0,
            suffixBytesRead: Int = 0,
            reducerReplayBytesRead: Int = 0,
            peakBufferedBytes: Int = 0,
            newlineBytesExamined: Int = 0,
            peakRecentEventBytes: Int = 0,
            decodedEventCount: Int = 0,
            indexedRowCount: Int = 0,
            sealedBucketCount: Int = 0,
            recentPageCount: Int = 0,
            exactStateValidationNodesVisited: Int = 0,
            exactStateValidationObjectsRead: Int = 0,
            exactStateValidationBytesRead: Int = 0
        ) {
            self.cacheHit = cacheHit
            self.rebuiltIndex = rebuiltIndex
            self.reducerReplayedFromZero = reducerReplayedFromZero
            self.readCalls = max(0, readCalls)
            self.bytesRead = max(0, bytesRead)
            self.suffixBytesRead = max(0, suffixBytesRead)
            self.reducerReplayBytesRead = max(0, reducerReplayBytesRead)
            self.peakBufferedBytes = max(0, peakBufferedBytes)
            self.newlineBytesExamined = max(0, newlineBytesExamined)
            self.peakRecentEventBytes = max(0, peakRecentEventBytes)
            self.decodedEventCount = max(0, decodedEventCount)
            self.indexedRowCount = max(0, indexedRowCount)
            self.sealedBucketCount = max(0, sealedBucketCount)
            self.recentPageCount = max(0, recentPageCount)
            self.exactStateValidationNodesVisited = max(0, exactStateValidationNodesVisited)
            self.exactStateValidationObjectsRead = max(0, exactStateValidationObjectsRead)
            self.exactStateValidationBytesRead = max(0, exactStateValidationBytesRead)
        }
    }

    public enum ReducerHead: Hashable, Sendable {
        case work(BoundedWorkReducerHead)
        case session(BoundedSessionReducerHead)

        public var work: BoundedWorkReducerHead? {
            guard case .work(let value) = self else { return nil }
            return value
        }

        public var session: BoundedSessionReducerHead? {
            guard case .session(let value) = self else { return nil }
            return value
        }
    }

    public struct Result: Hashable, Sendable {
        public let snapshot: DisposableTimelineProjectionStore.Snapshot
        public let source: DisposableTimelineProjectionStore.SourceFingerprint
        public let reducerHead: ReducerHead
        public let metrics: Metrics
        public let didRebuild: Bool
        public let appendedEventCount: Int

        public init(
            snapshot: DisposableTimelineProjectionStore.Snapshot,
            source: DisposableTimelineProjectionStore.SourceFingerprint,
            reducerHead: ReducerHead,
            metrics: Metrics,
            didRebuild: Bool,
            appendedEventCount: Int
        ) {
            self.snapshot = snapshot
            self.source = source
            self.reducerHead = reducerHead
            self.metrics = metrics
            self.didRebuild = didRebuild
            self.appendedEventCount = max(0, appendedEventCount)
        }
    }

    public let fileURL: URL
    public let home: AgentHome
    public let lease: LocalTimelineProjectionSourceLease
    public let store: DisposableTimelineProjectionStore
    public let journal: JournalRef
    public let kind: JournalKind
    public let limits: Limits
    public let reducerLimits: BoundedTimelineReducerProjectionLimits

    public init(
        store: DisposableTimelineProjectionStore,
        home: AgentHome,
        sourceLimits: LocalTimelineProjectionSourceLease.Limits = .default,
        limits: Limits = .standard,
        reducerLimits: BoundedTimelineReducerProjectionLimits = .default
    ) throws {
        guard store.journal.owner.isProjectionOwner else { throw ReaderError.unsupportedJournal }
        self.home = home
        self.store = store
        self.journal = store.journal
        self.limits = limits
        self.reducerLimits = reducerLimits
        switch store.journal.owner {
        case .work:
            self.kind = .work
        case .session:
            self.kind = .session
        case .workHost:
            throw ReaderError.unsupportedJournal
        }
        switch store.journal.owner {
        case .work(let work):
            self.fileURL = home.timelineV2WorkJournalURL(work).standardizedFileURL
        case .session(let session):
            self.fileURL = home.timelineV2SessionJournalURL(session).standardizedFileURL
        case .workHost:
            throw ReaderError.unsupportedJournal
        }
        self.lease = LocalTimelineProjectionSourceLease(
            fileURL: self.fileURL, journal: store.journal, limits: sourceLimits)
    }

    /// Read the current source. A missing HEAD performs a cold rebuild. A validated HEAD with
    /// an append-only suffix performs a bounded, zero-based index rebuild followed by an exact
    /// streaming reducer replay. A no-op cache hit performs only HEAD/terminal validation.
    ///
    /// The zero-based index rebuild is intentional: the bounded reducer head remains only a query
    /// projection. Work may additionally continue its semantic reducer from a persisted exact
    /// checkpoint whose source boundary was proven above; Session has no such continuation path.
    public func read() throws -> Result {
        try TimelineJournalWriter.withAdvisoryOwnerLock(
            home: home, journal: journal, dataURL: fileURL
        ) {
            try readLocked()
        }
    }

    private func readLocked() throws -> Result {
        var validationMetrics = LocalTimelineProjectionSourceLease.Metrics()
        var validatedSource: DisposableTimelineProjectionStore.SourceFingerprint?
        var cached: DisposableTimelineProjectionStore.ValidatedSnapshot?
        do {
            cached = try store.load { challenge in
                let observation = try lease.validateWithMetrics(
                    challenge, growthPolicy: .cooperatingAppendOnlyOwnerLock)
                validationMetrics = observation.metrics
                validatedSource = observation.source
                return observation.source
            }
        } catch let error as DisposableTimelineProjectionStore.StoreError {
            switch error {
            case .rebuildRequired(.missingHead):
                break
            default:
                throw mapStoreError(error)
            }
        } catch let error as ReaderError {
            throw error
        } catch {
            throw ReaderError.sourceChanged
        }

        guard let cached, let observed = validatedSource ?? Optional(cached.observedSource) else {
            return try coldRebuild(validationMetrics: validationMetrics)
        }
        guard cached.snapshot.journal == journal,
              cached.snapshot.source.journal == journal,
              observed.sourceID == cached.snapshot.source.sourceID,
              observed.sourceGeneration == cached.snapshot.source.sourceGeneration,
              observed.prefixByteCount == cached.snapshot.source.prefixByteCount,
              observed.prefixDigest == cached.snapshot.source.prefixDigest else {
            throw ReaderError.invalidCachedProjection
        }
        let expectedSeed = DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal)
        guard cached.snapshot.prefixSeed.sequence == 0,
              cached.snapshot.prefixSeed.byteCount == 0,
              cached.snapshot.prefixSeed.previousEventID == nil,
              cached.snapshot.prefixSeed.digest == expectedSeed else {
            // This reader has no exact semantic checkpoint for an omitted prefix. A syntactically
            // valid nonzero seed can only be consumed by a future reader that proves that full
            // continuation state; it must never become a cache hit here.
            throw ReaderError.invalidCachedProjection
        }

        if observed.sourceByteCount == cached.snapshot.source.sourceByteCount {
            // A cooperating append-only owner may change metadata while preserving bytes, but a
            // same-size fingerprint change is never a no-op. We cannot prove a middle rewrite
            // from bounded boundary samples, so reject rather than serve a stale cached head.
            guard observed.fingerprint == cached.snapshot.source.fingerprint else {
                throw ReaderError.sourceChanged
            }
            var exactValidation: PersistentProjectionRadixMap.Metrics?
            if kind == .work {
                if cached.snapshot.cursor.sequence > 0 {
                    // A bounded reducer head is not sufficient evidence for Work. Validate the
                    // content-addressed exact root even on a no-op cache hit; otherwise a corrupt
                    // map could look healthy until the next append.
                    let loaded = try loadWorkExactState(
                        from: cached.snapshot, source: cached.snapshot.source)
                    exactValidation = loaded.validationMetrics
                } else {
                    // No canonical event means there is no semantic reducer state to persist.
                    // This is the sole rootless Work exception; it must not be generalized to a
                    // nonempty cache whose membership could have been omitted.
                    guard cached.snapshot.exactStateCheckpoint == nil else {
                        throw ReaderError.invalidCachedProjection
                    }
                }
            }
            let head = try decodeReducerHead(from: cached.snapshot)
            let metrics = Metrics(
                cacheHit: true, rebuiltIndex: false, reducerReplayedFromZero: false,
                readCalls: validationMetrics.readCalls, bytesRead: validationMetrics.bytesRead,
                suffixBytesRead: 0, reducerReplayBytesRead: 0,
                peakBufferedBytes: validationMetrics.peakReadBytes,
                newlineBytesExamined: 0,
                peakRecentEventBytes: 0,
                decodedEventCount: 0, indexedRowCount: 0,
                sealedBucketCount: cached.snapshot.sealedBucketCount,
                recentPageCount: cached.snapshot.recentPages.count,
                exactStateValidationNodesVisited: exactValidation?.nodesVisited ?? 0,
                exactStateValidationObjectsRead: exactValidation?.objectsRead ?? 0,
                exactStateValidationBytesRead: exactValidation?.bytesRead ?? 0)
            return Result(
                snapshot: cached.snapshot, source: cached.snapshot.source,
                reducerHead: head, metrics: metrics, didRebuild: false,
                appendedEventCount: 0)
        }
        guard observed.sourceByteCount > cached.snapshot.source.sourceByteCount else {
            throw ReaderError.sourceChanged
        }
        return try rebuildAfterGrowth(
            cached: cached.snapshot, observed: observed, validationMetrics: validationMetrics)
    }

    // MARK: Cold and growth operations

    private func coldRebuild(
        validationMetrics: LocalTimelineProjectionSourceLease.Metrics
    ) throws -> Result {
        let before = try observeSource()
        guard before.source.sourceByteCount >= 0 else { throw ReaderError.sourceChanged }
        guard before.source.sourceByteCount <= limits.maximumBootstrapSourceBytes else {
            throw ReaderError.sourceTooLarge
        }
        let seed = DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal)
        let prefixSeed = DisposableTimelineProjectionStore.PrefixSeed(
            byteCount: 0, digest: seed, sequence: 0, previousEventID: nil)
        var index = IndexAccumulator(
            limits: limits, storeLimits: store.limits)
        var workAccumulator = BoundedWorkReducerAccumulator(limits: reducerLimits)
        var workMap: PersistentProjectionRadixMap?
        var workExactState: PersistentWorkExactState?
        if kind == .work {
            let prepared = try makeWorkExactState(
                source: before.source,
                namespaceID: defaultWorkExactNamespaceID(source: before.source))
            workMap = prepared.map
            workExactState = prepared.state
        }
        let firstPass = try stream(
            startByte: 0, targetByteCount: before.source.sourceByteCount,
            startSequence: 1, startPreviousEventID: nil, startPrefixDigest: seed,
            metrics: .init()
        ) { event, row in
            try index.consume(event: event, row: row)
            if kind == .work {
                workAccumulator.append(event)
                guard var exact = workExactState else {
                    throw ReaderError.exactStateUnavailable
                }
                do {
                    _ = try exact.apply(event)
                } catch {
                    throw mapExactStateError(error)
                }
                workExactState = exact
            }
        }
        let afterIndex = try fencedSource(after: before)
        index.metrics = StreamMetrics(validationMetrics)
        index.metrics.merge(firstPass.metrics)
        guard afterIndex.source.sourceByteCount == before.source.sourceByteCount,
              firstPass.nextByteOffset == before.source.sourceByteCount else {
            throw ReaderError.sourceChanged
        }
        let finalSource = makeSource(
            observation: afterIndex.source,
            prefixByteCount: firstPass.nextByteOffset,
            prefixDigest: firstPass.nextPrefixDigest)
        let cursor = JournalCursor(
            journal: journal, eventID: firstPass.lastEventID, sequence: firstPass.lastSequence)
        let projectionSource = BoundedReducerProjectionSource(
            source: finalSource, cursor: cursor)
        let head: ReplayResult
        var exactCheckpoint: DisposableTimelineProjectionStore.ExactStateCheckpoint?
        switch kind {
        case .work:
            do {
                let bounded = try workAccumulator.finalize(source: projectionSource)
                head = ReplayResult(
                    head: .work(bounded), opaque: try bounded.opaqueReducerHead(),
                    // The index pass is also the Work bounded-reducer pass.  Report the bytes
                    // once; the persistent overlay has no separate source replay.
                    replayBytes: firstPass.bytesRead)
            } catch {
                throw ReaderError.projectionFailed
            }
            if firstPass.eventCount > 0 {
                guard let state = workExactState, let map = workMap else {
                    throw ReaderError.exactStateUnavailable
                }
                exactCheckpoint = try makeWorkExactCheckpoint(
                    state: state, map: map, source: finalSource, cursor: cursor)
            }
        case .session:
            head = try replayReducer(
                targetByteCount: before.source.sourceByteCount,
                source: projectionSource, initialPrefixSeed: prefixSeed)
            exactCheckpoint = nil
        }
        let afterReplay = try fencedSource(after: afterIndex)
        guard afterReplay.source.sourceByteCount == before.source.sourceByteCount else {
            throw ReaderError.sourceChanged
        }
        let commit = try index.makeCommit(
            source: finalSource, cursor: cursor, prefixSeed: prefixSeed,
            reducerHead: head.opaque, expectedGeneration: nil,
            recentPages: index.recentPages,
            exactStateCheckpoint: exactCheckpoint)
        let snapshot = try commitStore(commit, exactStateMap: workMap)
        let metrics = index.metrics(
            cacheHit: false, rebuiltIndex: true, reducerReplayedFromZero: true,
            replayBytes: head.replayBytes)
        return Result(
            snapshot: snapshot, source: snapshot.source, reducerHead: head.head,
            metrics: metrics, didRebuild: true, appendedEventCount: firstPass.eventCount)
    }

    /// Rebuild the complete bounded index and typed query head when the source grew.
    ///
    /// The bounded index intentionally reads from byte zero. The source lease's cooperating-owner
    /// lock mode proves the append-only producer contract while this operation runs under the
    /// canonical Timeline lock. For Work, the exact reducer overlay separately starts at a stored
    /// boundary only after its source identity and cursor proof succeeds; Session remains full
    /// replay. The commit only supplies the changed current/new buckets so immutable sealed cache
    /// history remains reusable.
    private func rebuildAfterGrowth(
        cached: DisposableTimelineProjectionStore.Snapshot,
        observed: DisposableTimelineProjectionStore.SourceFingerprint,
        validationMetrics: LocalTimelineProjectionSourceLease.Metrics
    ) throws -> Result {
        let before = try observeSource()
        guard sameObservation(before.source, observed),
              before.source.sourceByteCount == observed.sourceByteCount,
              cached.cursor.eventID == cached.nextPreviousEventID else {
            throw ReaderError.sourceChanged
        }
        guard before.source.sourceByteCount <= limits.maximumBootstrapSourceBytes else {
            throw ReaderError.sourceTooLarge
        }
        let prefixSeed = cached.prefixSeed
        guard prefixSeed.sequence == 0, prefixSeed.byteCount == 0,
              prefixSeed.previousEventID == nil,
              prefixSeed.digest == DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal)
        else {
            // A nonzero cached seed is not an exact checkpoint and this reader has no bounded
            // proof for rebuilding from it. Leave the old cache untouched.
            throw ReaderError.invalidCachedProjection
        }
        // The bounded Work head is rebuilt from byte zero, but Work's exact reducer continuation
        // can advance from the proven cached boundary. Session intentionally remains full replay.
        var workAccumulator = BoundedWorkReducerAccumulator(limits: reducerLimits)
        var workMap: PersistentProjectionRadixMap?
        var workExactState: PersistentWorkExactState?
        var exactValidation: PersistentProjectionRadixMap.Metrics?
        let suffixStartByte: Int
        let suffixStartSequence: Int
        let suffixPreviousEventID: String?
        let suffixPrefixDigest: String
        if kind == .work {
            if cached.exactStateCheckpoint != nil {
                let loaded = try loadWorkExactState(from: cached, source: cached.source)
                workMap = loaded.map
                workExactState = loaded.state
                exactValidation = loaded.validationMetrics
                guard cached.source.prefixByteCount == cached.source.sourceByteCount,
                      cached.cursor.sequence > 0,
                      cached.cursor.sequence < Int.max,
                      cached.cursor.eventID != nil else {
                    throw ReaderError.invalidCachedProjection
                }
                suffixStartByte = cached.source.prefixByteCount
                suffixStartSequence = cached.cursor.sequence + 1
                suffixPreviousEventID = cached.cursor.eventID
                suffixPrefixDigest = cached.source.prefixDigest
            } else {
                // Only an empty Work cache may be upgraded without a persisted exact root. A
                // nonempty rootless cache would require guessing at omitted reducer membership.
                guard cached.cursor.sequence == 0,
                      cached.cursor.eventID == nil,
                      cached.source.prefixByteCount == 0 else {
                    throw ReaderError.invalidCachedProjection
                }
                let prepared = try makeWorkExactState(
                    source: before.source, namespaceID: cached.namespaceID)
                workMap = prepared.map
                workExactState = prepared.state
                suffixStartByte = 0
                suffixStartSequence = 1
                suffixPreviousEventID = nil
                suffixPrefixDigest = DisposableTimelineProjectionStore.canonicalPrefixSeed(
                    for: journal)
            }
        } else {
            workMap = nil
            workExactState = nil
            suffixStartByte = 0
            suffixStartSequence = 1
            suffixPreviousEventID = nil
            suffixPrefixDigest = DisposableTimelineProjectionStore.canonicalPrefixSeed(
                for: journal)
        }
        var index = IndexAccumulator(
            limits: limits, storeLimits: store.limits)
        var cachedBoundaryMatched = cached.cursor.sequence == 0
        let full = try stream(
            startByte: 0, targetByteCount: before.source.sourceByteCount,
            startSequence: 1, startPreviousEventID: nil,
            startPrefixDigest: prefixSeed.digest, metrics: .init()
        ) { event, row in
            if row.sequence == cached.cursor.sequence {
                guard row.eventID == cached.cursor.eventID,
                      row.byteEnd == cached.source.prefixByteCount,
                      row.prefixDigestAfter == cached.source.prefixDigest else {
                    throw ReaderError.sourceChanged
                }
                cachedBoundaryMatched = true
            }
            try index.consume(event: event, row: row)
            if kind == .work {
                workAccumulator.append(event)
            }
        }
        let afterIndex = try fencedSource(after: before)
        guard cachedBoundaryMatched,
              full.nextByteOffset == observed.sourceByteCount,
              afterIndex.source.sourceByteCount == observed.sourceByteCount else {
            throw ReaderError.sourceChanged
        }
        let finalSource = makeSource(
            observation: afterIndex.source,
            prefixByteCount: full.nextByteOffset,
            prefixDigest: full.nextPrefixDigest)
        let cursor = JournalCursor(
            journal: journal, eventID: full.lastEventID, sequence: full.lastSequence)
        let projectionSource = BoundedReducerProjectionSource(
            source: finalSource, cursor: cursor)
        var suffix: StreamResult?
        if kind == .work {
            guard suffixStartByte <= observed.sourceByteCount,
                  suffixStartSequence > 0, suffixStartSequence < Int.max,
                  var exact = workExactState else {
                throw ReaderError.invalidCachedProjection
            }
            let continuation = try stream(
                startByte: suffixStartByte,
                targetByteCount: observed.sourceByteCount,
                startSequence: suffixStartSequence,
                startPreviousEventID: suffixPreviousEventID,
                startPrefixDigest: suffixPrefixDigest
            ) { event, _ in
                do {
                    _ = try exact.apply(event)
                } catch {
                    throw mapExactStateError(error)
                }
            }
            guard continuation.nextByteOffset == observed.sourceByteCount,
                  continuation.nextPrefixDigest == full.nextPrefixDigest,
                  continuation.lastEventID == full.lastEventID,
                  continuation.lastSequence == full.lastSequence else {
                throw ReaderError.sourceChanged
            }
            suffix = continuation
            workExactState = exact
        }
        let head: ReplayResult
        var exactCheckpoint: DisposableTimelineProjectionStore.ExactStateCheckpoint?
        switch kind {
        case .work:
            do {
                let bounded = try workAccumulator.finalize(source: projectionSource)
                head = ReplayResult(
                    head: .work(bounded), opaque: try bounded.opaqueReducerHead(),
                    replayBytes: full.bytesRead)
            } catch {
                throw ReaderError.projectionFailed
            }
            guard let state = workExactState, let map = workMap else {
                throw ReaderError.exactStateUnavailable
            }
            if full.eventCount > 0 {
                exactCheckpoint = try makeWorkExactCheckpoint(
                    state: state, map: map, source: finalSource, cursor: cursor)
            }
        case .session:
            head = try replayReducer(
                targetByteCount: observed.sourceByteCount,
                source: projectionSource, initialPrefixSeed: prefixSeed)
            exactCheckpoint = nil
        }
        let afterReplay = try fencedSource(after: afterIndex)
        guard afterReplay.source.sourceByteCount == observed.sourceByteCount else {
            throw ReaderError.sourceChanged
        }
        let oldCurrent: DisposableTimelineProjectionStore.Bucket?
        if cached.currentBucket != nil {
            oldCurrent = try store.loadBucket(
                containingSequence: cached.cursor.sequence, proving: cached.source)
        } else {
            oldCurrent = nil
        }
        let commit = try index.makeCommit(
            source: finalSource, cursor: cursor, prefixSeed: prefixSeed,
            reducerHead: head.opaque, expectedGeneration: cached.generation,
            oldCurrent: oldCurrent, oldAnchors: cached.anchors,
            oldAcknowledgements: cached.pendingAcknowledgements,
            oldSealedThroughSequence: cached.sealedThroughSequence,
            recentPages: index.recentPages,
            exactStateCheckpoint: exactCheckpoint)
        let snapshot = try commitStore(commit, exactStateMap: workMap)
        index.metrics = StreamMetrics(validationMetrics)
        index.metrics.merge(full.metrics)
        if let suffix {
            index.metrics.merge(suffix.metrics)
        }
        let metrics = index.metrics(
            cacheHit: false, rebuiltIndex: true, reducerReplayedFromZero: true,
            replayBytes: head.replayBytes,
            suffixBytes: suffix?.bytesRead ?? 0,
            exactValidation: exactValidation)
        return Result(
            snapshot: snapshot, source: snapshot.source, reducerHead: head.head,
            metrics: metrics, didRebuild: true,
            appendedEventCount: suffix?.eventCount
                ?? max(0, full.eventCount - cached.cursor.sequence))
    }

    private func replayReducer(
        targetByteCount: Int,
        source: BoundedReducerProjectionSource,
        initialPrefixSeed: DisposableTimelineProjectionStore.PrefixSeed
    ) throws -> ReplayResult {
        guard initialPrefixSeed.sequence == 0,
              initialPrefixSeed.byteCount == 0,
              initialPrefixSeed.previousEventID == nil,
              initialPrefixSeed.digest
                == DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal) else {
            throw ReaderError.invalidCachedProjection
        }
        var work = BoundedWorkReducerAccumulator(limits: reducerLimits)
        var session = BoundedSessionReducerAccumulator(limits: reducerLimits)
        let replay = try stream(
            startByte: initialPrefixSeed.byteCount, targetByteCount: targetByteCount,
            startSequence: initialPrefixSeed.sequence + 1,
            startPreviousEventID: initialPrefixSeed.previousEventID,
            startPrefixDigest: initialPrefixSeed.digest
        ) { event, _ in
            switch kind {
            case .work:
                work.append(event)
            case .session:
                session.append(event)
            }
        }
        guard replay.nextByteOffset == targetByteCount else { throw ReaderError.sourceChanged }
        do {
            switch kind {
            case .work:
                let head = try work.finalize(source: source)
                return ReplayResult(
                    head: .work(head), opaque: try head.opaqueReducerHead(),
                    replayBytes: replay.bytesRead)
            case .session:
                let head = try session.finalize(source: source)
                return ReplayResult(
                    head: .session(head), opaque: try head.opaqueReducerHead(),
                    replayBytes: replay.bytesRead)
            }
        } catch {
            throw ReaderError.projectionFailed
        }
    }

    private struct ReplayResult {
        let head: ReducerHead
        let opaque: DisposableTimelineProjectionStore.OpaqueReducerHead
        let replayBytes: Int
    }

    private static let exactWorkMapKind = "work-exact-v1"

    /// The map is deliberately private to this projection store.  Its namespace is stable for a
    /// journal so a cold retry after a failed publication can reuse immutable orphan objects, while
    /// the source-generation scope still prevents a replaced journal file from borrowing them.
    private func makeWorkExactMap(
        source: DisposableTimelineProjectionStore.SourceFingerprint,
        namespaceID: String
    ) throws -> PersistentProjectionRadixMap {
        do {
            return try PersistentProjectionRadixMap(
                directory: store.directory.appending(
                    path: "work-exact-state", directoryHint: .isDirectory),
                namespaceID: namespaceID,
                journal: journal,
                sourceGeneration: source.sourceGeneration,
                mapKind: Self.exactWorkMapKind)
        } catch {
            throw ReaderError.exactStateUnavailable
        }
    }

    private func defaultWorkExactNamespaceID(
        source: DisposableTimelineProjectionStore.SourceFingerprint
    ) -> String {
        "work-exact-v1." + AviarySHA256.hash(data: Data(
            "aviary-work-exact-namespace-v1\u{0}\(journal.stableKey)\u{0}"
                .appending(source.sourceGeneration)
                .appending("\u{0}\(source.sourceByteCount)\u{0}")
                .appending(source.fingerprint)
                .utf8)).description
    }

    private func makeWorkExactState(
        source: DisposableTimelineProjectionStore.SourceFingerprint,
        namespaceID: String
    ) throws -> (map: PersistentProjectionRadixMap, state: PersistentWorkExactState) {
        let map = try makeWorkExactMap(source: source, namespaceID: namespaceID)
        do {
            return (map, try PersistentWorkExactState(map: map))
        } catch {
            throw ReaderError.exactStateUnavailable
        }
    }

    /// Loads the bounded exact-state proof needed for a Work cache hit or suffix continuation.
    /// The store proves the checkpoint envelope and source boundary; this layer authenticates the
    /// root node and scalar continuation. Historical typed values are deliberately not walked on
    /// every read. A future repair/audit operation may use `validateReachable`; normal growth
    /// validates only the typed records required by each incoming event.
    private func loadWorkExactState(
        from snapshot: DisposableTimelineProjectionStore.Snapshot,
        source: DisposableTimelineProjectionStore.SourceFingerprint
    ) throws -> (
        map: PersistentProjectionRadixMap,
        state: PersistentWorkExactState,
        validationMetrics: PersistentProjectionRadixMap.Metrics
    ) {
        guard let checkpoint = try store.loadExactStateCheckpoint(proving: snapshot.source),
              checkpoint.namespaceID == snapshot.namespaceID,
              checkpoint.journal == journal,
              checkpoint.sourceGeneration == source.sourceGeneration,
              checkpoint.cursor == snapshot.cursor,
              checkpoint.prefixByteCount == source.prefixByteCount,
              checkpoint.prefixDigest == source.prefixDigest,
              checkpoint.roots.count == 1,
              let descriptor = checkpoint.roots.first,
              descriptor.mapKind == Self.exactWorkMapKind,
              descriptor.namespaceID == snapshot.namespaceID,
              descriptor.journal == journal,
              descriptor.sourceGeneration == source.sourceGeneration else {
            throw ReaderError.invalidCachedProjection
        }
        let map = try makeWorkExactMap(
            source: source, namespaceID: snapshot.namespaceID)
        do {
            let validationMetrics = try map.validate(root: descriptor.root)
            let state = try PersistentWorkExactState(map: map, root: descriptor.root)
            let scalar = state.eventLocalSnapshot
            guard scalar.journal == journal,
                  scalar.lastSequence == snapshot.cursor.sequence,
                  scalar.lastEventID == snapshot.cursor.eventID else {
                throw ReaderError.invalidCachedProjection
            }
            return (map, state, validationMetrics)
        } catch let error as ReaderError {
            throw error
        } catch {
            throw ReaderError.invalidCachedProjection
        }
    }

    private func makeWorkExactCheckpoint(
        state: PersistentWorkExactState,
        map: PersistentProjectionRadixMap,
        source: DisposableTimelineProjectionStore.SourceFingerprint,
        cursor: JournalCursor
    ) throws -> DisposableTimelineProjectionStore.ExactStateCheckpoint {
        guard let root = state.currentRoot else {
            // A zero-event Work journal cannot currently materialize the scalar map root.  Do not
            // invent a synthetic canonical event; the caller must use an explicit empty-state
            // seed API before publishing an exact checkpoint for that case.
            throw ReaderError.exactStateUnavailable
        }
        guard root.journal == journal,
              root.namespaceID == map.namespaceID,
              root.sourceGeneration == source.sourceGeneration,
              root.mapKind == Self.exactWorkMapKind else {
            throw ReaderError.exactStateUnavailable
        }
        return DisposableTimelineProjectionStore.ExactStateCheckpoint(
            namespaceID: map.namespaceID,
            journal: journal,
            sourceGeneration: source.sourceGeneration,
            cursor: cursor,
            prefixByteCount: source.prefixByteCount,
            prefixDigest: source.prefixDigest,
            roots: [DisposableTimelineProjectionStore.ExactStateRootDescriptor(root: root)])
    }

    private func mapExactStateError(_ error: Error) -> ReaderError {
        if let error = error as? PersistentWorkExactState.Error,
           case .unsupportedEvent = error {
            return .exactStateUnavailable
        }
        return .projectionFailed
    }

    // MARK: Source streaming

    private struct StreamMetrics: Sendable {
        var readCalls: Int = 0
        var bytesRead: Int = 0
        var peakBufferedBytes: Int = 0
        var newlineBytesExamined: Int = 0
        var eventCount: Int = 0

        init() {}

        init(_ sourceMetrics: LocalTimelineProjectionSourceLease.Metrics) {
            readCalls = sourceMetrics.readCalls
            bytesRead = sourceMetrics.bytesRead
            peakBufferedBytes = sourceMetrics.peakReadBytes
        }

        mutating func read(_ count: Int, buffered: Int) {
            readCalls = readCalls >= Int.max ? Int.max : readCalls + 1
            bytesRead = count > Int.max - bytesRead ? Int.max : bytesRead + count
            peakBufferedBytes = max(peakBufferedBytes, buffered)
        }

        mutating func examinedForNewline(_ count: Int) {
            newlineBytesExamined = count > Int.max - newlineBytesExamined
                ? Int.max : newlineBytesExamined + count
        }

        mutating func merge(_ other: StreamMetrics) {
            readCalls = readCalls > Int.max - other.readCalls
                ? Int.max : readCalls + other.readCalls
            bytesRead = bytesRead > Int.max - other.bytesRead
                ? Int.max : bytesRead + other.bytesRead
            peakBufferedBytes = max(peakBufferedBytes, other.peakBufferedBytes)
            newlineBytesExamined = newlineBytesExamined > Int.max - other.newlineBytesExamined
                ? Int.max : newlineBytesExamined + other.newlineBytesExamined
            eventCount = eventCount > Int.max - other.eventCount
                ? Int.max : eventCount + other.eventCount
        }
    }

    private struct StreamResult {
        let nextByteOffset: Int
        let nextPrefixDigest: String
        let lastEventID: String?
        let lastSequence: Int
        let eventCount: Int
        let bytesRead: Int
        let metrics: StreamMetrics
    }

    private func stream(
        startByte: Int,
        targetByteCount: Int,
        startSequence: Int,
        startPreviousEventID: String?,
        startPrefixDigest: String,
        metrics sourceMetrics: StreamMetrics = .init(),
        consume: (TimelineEvent, DisposableTimelineProjectionStore.BucketRow) throws -> Void
    ) throws -> StreamResult {
        guard startByte >= 0, targetByteCount >= startByte,
              startSequence > 0, startSequence < Int.max else {
            throw ReaderError.sourceChanged
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
            try handle.seek(toOffset: UInt64(startByte))
        } catch {
            throw ReaderError.sourceChanged
        }
        defer { try? handle.close() }

        var metrics = sourceMetrics
        var pending = [UInt8]()
        pending.reserveCapacity(min(limits.maximumLineBytes, limits.maximumChunkBytes))
        var pendingStart = 0
        var nextNewlineSearchIndex = 0
        var offset = startByte
        var nextSequence = startSequence
        var previousEventID = startPreviousEventID
        var prefixDigest = startPrefixDigest
        var lastEventID = startPreviousEventID
        var lastSequence = startSequence - 1
        var eventCount = 0
        var seenEventIDs = Set<String>()
        var remaining = targetByteCount - startByte

        while remaining > 0 {
            let request = min(remaining, limits.maximumChunkBytes)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: request) ?? Data()
            } catch {
                throw ReaderError.sourceChanged
            }
            guard !chunk.isEmpty, chunk.count <= request else { throw ReaderError.sourceChanged }
            remaining -= chunk.count
            pending.append(contentsOf: chunk)
            let activePendingCount = pending.count - pendingStart
            metrics.read(chunk.count, buffered: activePendingCount)
            guard activePendingCount <= limits.maximumLineBytes + limits.maximumChunkBytes else {
                throw ReaderError.lineTooLarge
            }

            while nextNewlineSearchIndex < pending.count {
                let searchStart = nextNewlineSearchIndex
                guard let newline = pending[searchStart...].firstIndex(of: 0x0A) else {
                    metrics.examinedForNewline(pending.count - searchStart)
                    nextNewlineSearchIndex = pending.count
                    break
                }
                metrics.examinedForNewline(newline - searchStart + 1)
                let lineLength = newline - pendingStart + 1
                guard lineLength <= limits.maximumLineBytes else {
                    throw ReaderError.lineTooLarge
                }
                let raw = Data(pending[pendingStart..<(pendingStart + lineLength)])
                pendingStart += lineLength
                nextNewlineSearchIndex = pendingStart
                guard raw.last == UInt8(ascii: "\n"), raw.count > 1 else {
                    throw ReaderError.malformedLine
                }
                let content = Data(raw.dropLast())
                let event: TimelineEvent
                do {
                    event = try JSONDecoder().decode(TimelineEvent.self, from: content)
                } catch {
                    throw ReaderError.malformedLine
                }
                guard event.provenance == .native,
                      event.schemaVersion == TimelineEvent.currentSchemaVersion,
                      event.payloadVersion <= 1,
                      event.journal == journal,
                      event.sequence == nextSequence,
                      event.previousEventID == previousEventID,
                      event.sequence < Int.max,
                      !event.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      event.eventID.utf8.count <= reducerLimits.maximumIdentifierBytes,
                      !event.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      event.links.count <= TimelineEvent.maxEvidenceLinks else {
                    throw ReaderError.malformedLine
                }
                guard seenEventIDs.count < limits.maximumSeenEventIDs else {
                    throw ReaderError.tooManyEvents
                }
                guard seenEventIDs.insert(event.eventID).inserted else {
                    throw ReaderError.duplicateIdentity
                }
                let lineDigest: String
                do {
                    lineDigest = try DisposableTimelineProjectionStore.canonicalEventLineDigest(event)
                } catch {
                    throw ReaderError.malformedLine
                }
                let lineStart = offset
                let lineEnd = offset + lineLength
                guard lineEnd <= targetByteCount else { throw ReaderError.sourceChanged }
                let prefixBefore = prefixDigest
                prefixDigest = DisposableTimelineProjectionStore.advancePrefixDigest(
                    prefixDigest, lineDigest: lineDigest)
                let row = DisposableTimelineProjectionStore.BucketRow(
                    sequence: event.sequence, eventID: event.eventID,
                    previousEventID: event.previousEventID,
                    byteStart: lineStart, byteEnd: lineEnd,
                    prefixDigestBefore: prefixBefore, prefixDigestAfter: prefixDigest,
                    lineDigest: lineDigest)
                try consume(event, row)
                offset = lineEnd
                nextSequence += 1
                previousEventID = event.eventID
                lastEventID = event.eventID
                lastSequence = event.sequence
                eventCount += 1
                metrics.eventCount += 1
                guard eventCount <= limits.maximumSeenEventIDs else {
                    throw ReaderError.tooManyEvents
                }
            }
            metrics.peakBufferedBytes = max(metrics.peakBufferedBytes, pending.count - pendingStart)
            if pendingStart > 0,
               pendingStart >= limits.maximumChunkBytes,
                pendingStart * 2 >= pending.count {
                let removed = pendingStart
                pending.removeSubrange(0..<pendingStart)
                pendingStart = 0
                nextNewlineSearchIndex = max(0, nextNewlineSearchIndex - removed)
            }
        }
        guard pendingStart == pending.count else { throw ReaderError.truncatedTail }
        return StreamResult(
            nextByteOffset: offset, nextPrefixDigest: prefixDigest,
            lastEventID: lastEventID, lastSequence: lastSequence,
            eventCount: eventCount, bytesRead: metrics.bytesRead, metrics: metrics)
    }

    // MARK: Index assembly

    private struct IndexAccumulator {
        private struct RecentEntry {
            let event: TimelineEvent
            let byteCount: Int
        }

        let readerLimits: Limits
        let storeLimits: DisposableTimelineProjectionStore.Limits
        var rows: [DisposableTimelineProjectionStore.BucketRow] = []
        private var recent: [RecentEntry] = []
        var recentStart = 0
        var recentByteCount = 0
        var peakRecentByteCount = 0
        var metrics = StreamMetrics(.init())

        init(
            limits: Limits,
            storeLimits: DisposableTimelineProjectionStore.Limits
        ) {
            self.readerLimits = limits
            self.storeLimits = storeLimits
        }

        /// One store commit can retain at most its configured sealed buckets plus one partial
        /// bucket. This is a bootstrap bound, not a promise of lifetime-sized journal support;
        /// a future reader can publish/index progressively once the store exposes that protocol.
        private var maximumIndexedRows: Int {
            let commitRows = storeLimits.maximumBucketsPerCommit
                * DisposableTimelineProjectionStore.bucketWidth
                + (DisposableTimelineProjectionStore.bucketWidth - 1)
            return min(readerLimits.maximumIndexedRows, commitRows)
        }

        mutating func consume(
            event: TimelineEvent,
            row: DisposableTimelineProjectionStore.BucketRow
        ) throws {
            guard rows.count < maximumIndexedRows else {
                throw ReaderError.tooManyIndexedRows
            }
            rows.append(row)
            let maximumRecent = min(
                readerLimits.maximumRecentPageEvents,
                storeLimits.maximumRecentPages * storeLimits.maximumRecentPageEvents)
            let eventBytes = row.byteEnd - row.byteStart
            if eventBytes <= readerLimits.maximumRecentEventBytes {
                while recentStart < recent.count,
                      (recent.count - recentStart >= maximumRecent
                        || recentByteCount > readerLimits.maximumRecentEventBytes - eventBytes) {
                    recentByteCount -= recent[recentStart].byteCount
                    recentStart += 1
                }
                recent.append(RecentEntry(event: event, byteCount: eventBytes))
                recentByteCount += eventBytes
                peakRecentByteCount = max(peakRecentByteCount, recentByteCount)
            }
            // Release evicted rich events once tombstones occupy at least half the backing
            // buffer. This keeps retained backing storage within a small constant factor of the
            // active byte/count budgets while preserving amortized linear compaction work.
            if recentStart > 0, recentStart * 2 >= recent.count {
                recent.removeSubrange(0..<recentStart)
                recentStart = 0
            }
        }

        var recentPages: [DisposableTimelineProjectionStore.RecentEventPage] {
            makePages(recent[recentStart...].map(\.event))
        }

        func recentPagesAppending(
            _ oldPages: [DisposableTimelineProjectionStore.RecentEventPage]
        ) -> [DisposableTimelineProjectionStore.RecentEventPage] {
            let oldEvents = oldPages.flatMap(\.events)
            let currentRecent = recent[recentStart...].map(\.event)
            let combined = Array((oldEvents + currentRecent).suffix(
                min(readerLimits.maximumRecentPageEvents,
                    storeLimits.maximumRecentPages * storeLimits.maximumRecentPageEvents)))
            return makePages(combined)
        }

        func makePages(
            _ source: [TimelineEvent]
        ) -> [DisposableTimelineProjectionStore.RecentEventPage] {
            guard !source.isEmpty else { return [] }
            let width = min(
                DisposableTimelineProjectionStore.bucketWidth,
                storeLimits.maximumRecentPageEvents)
            var result: [DisposableTimelineProjectionStore.RecentEventPage] = []
            var index = 0
            while index < source.count {
                let end = min(source.count, index + width)
                let pageEvents = Array(source[index..<end])
                let start = pageEvents.first!.sequence
                let finish = pageEvents.last!.sequence
                let page = DisposableTimelineProjectionStore.RecentEventPage(
                    pageID: "recent-\(start)-\(finish)", events: pageEvents)
                if let encoded = try? DisposableTimelineProjectionStore.canonicalJSON(page),
                   encoded.count <= storeLimits.maximumRecentPageBytes,
                   encoded.count <= storeLimits.maximumObjectBytes {
                    result.append(page)
                }
                index = end
            }
            return Array(result.suffix(storeLimits.maximumRecentPages))
        }

        func makeCommit(
            source: DisposableTimelineProjectionStore.SourceFingerprint,
            cursor: JournalCursor,
            prefixSeed: DisposableTimelineProjectionStore.PrefixSeed,
            reducerHead: DisposableTimelineProjectionStore.OpaqueReducerHead,
            expectedGeneration: Int?,
            oldCurrent: DisposableTimelineProjectionStore.Bucket? = nil,
            oldAnchors: [DisposableTimelineProjectionStore.AnchorRecord] = [],
            oldAcknowledgements: [DisposableTimelineProjectionStore.PendingAcknowledgement] = [],
            oldSealedThroughSequence: Int? = nil,
            recentPages: [DisposableTimelineProjectionStore.RecentEventPage],
            exactStateCheckpoint: DisposableTimelineProjectionStore.ExactStateCheckpoint? = nil
        ) throws -> DisposableTimelineProjectionStore.Commit {
            let planned = try planBuckets(
                oldCurrent: oldCurrent, oldSealedThroughSequence: oldSealedThroughSequence)
            guard planned.sealed.count <= storeLimits.maximumBucketsPerCommit else {
                throw ReaderError.tooManyBuckets
            }
            guard cursor.sequence < Int.max else { throw ReaderError.sourceChanged }
            let next = cursor.sequence + 1
            return DisposableTimelineProjectionStore.Commit(
                source: source, cursor: cursor, prefixSeed: prefixSeed,
                nextSequence: next, nextPreviousEventID: cursor.eventID,
                sealedBuckets: planned.sealed, currentBucket: planned.current,
                anchors: oldAnchors, recentPages: recentPages,
                reducerHead: reducerHead,
                exactStateCheckpoint: exactStateCheckpoint,
                pendingAcknowledgements: oldAcknowledgements,
                expectedGeneration: expectedGeneration)
        }

        private func planBuckets(
            oldCurrent: DisposableTimelineProjectionStore.Bucket?,
            oldSealedThroughSequence: Int?
        ) throws -> (
            sealed: [DisposableTimelineProjectionStore.Bucket],
            current: DisposableTimelineProjectionStore.Bucket?
        ) {
            var all = oldCurrent?.rows ?? []
            let minimumNewSequence = oldCurrent?.rows.last?.sequence
                ?? oldSealedThroughSequence
                ?? 0
            all.append(contentsOf: rows.filter { $0.sequence > minimumNewSequence })
            guard all.count <= maximumIndexedRows else {
                throw ReaderError.tooManyIndexedRows
            }
            guard !all.isEmpty else { return ([], nil) }
            var sealed: [DisposableTimelineProjectionStore.Bucket] = []
            var index = 0
            while all.count - index >= DisposableTimelineProjectionStore.bucketWidth {
                let group = Array(all[index..<(index + DisposableTimelineProjectionStore.bucketWidth)])
                guard let first = group.first else { throw ReaderError.sourceChanged }
                sealed.append(.init(bucketStart: first.sequence, rows: group))
                index += DisposableTimelineProjectionStore.bucketWidth
            }
            let remaining = Array(all[index...])
            let current: DisposableTimelineProjectionStore.Bucket?
            if remaining.isEmpty {
                current = nil
            } else {
                guard let first = remaining.first else { throw ReaderError.sourceChanged }
                current = .init(bucketStart: first.sequence, rows: remaining)
            }
            return (sealed, current)
        }

        func metrics(
            cacheHit: Bool,
            rebuiltIndex: Bool,
            reducerReplayedFromZero: Bool,
            replayBytes: Int,
            suffixBytes: Int = 0,
            exactValidation: PersistentProjectionRadixMap.Metrics? = nil
        ) -> Metrics {
            Metrics(
                cacheHit: cacheHit, rebuiltIndex: rebuiltIndex,
                reducerReplayedFromZero: reducerReplayedFromZero,
                readCalls: metrics.readCalls, bytesRead: metrics.bytesRead,
                suffixBytesRead: suffixBytes,
                reducerReplayBytesRead: replayBytes,
                peakBufferedBytes: metrics.peakBufferedBytes,
                newlineBytesExamined: metrics.newlineBytesExamined,
                peakRecentEventBytes: peakRecentByteCount,
                decodedEventCount: metrics.eventCount,
                indexedRowCount: rows.count,
                sealedBucketCount: max(
                    0, rows.count / DisposableTimelineProjectionStore.bucketWidth),
                recentPageCount: recentPages.count,
                exactStateValidationNodesVisited: exactValidation?.nodesVisited ?? 0,
                exactStateValidationObjectsRead: exactValidation?.objectsRead ?? 0,
                exactStateValidationBytesRead: exactValidation?.bytesRead ?? 0)
        }
    }

    private func loadRecentPages(
        from snapshot: DisposableTimelineProjectionStore.Snapshot
    ) throws -> [DisposableTimelineProjectionStore.RecentEventPage] {
        guard !snapshot.recentPages.isEmpty else { return [] }
        var pages: [DisposableTimelineProjectionStore.RecentEventPage] = []
        for descriptor in snapshot.recentPages {
            do {
                pages.append(try store.loadRecentPage(
                    id: descriptor.pageID, proving: snapshot.source))
            } catch {
                throw ReaderError.invalidCachedProjection
            }
        }
        return pages
    }

    // MARK: Store/source helpers

    private func decodeReducerHead(
        from snapshot: DisposableTimelineProjectionStore.Snapshot
    ) throws -> ReducerHead {
        guard let descriptor = snapshot.reducerHead else {
            throw ReaderError.invalidCachedProjection
        }
        let bytes: Data
        do {
            bytes = try store.loadReducerHead(proving: snapshot.source)
        } catch {
            throw ReaderError.invalidCachedProjection
        }
        do {
            let opaque = DisposableTimelineProjectionStore.OpaqueReducerHead(
                mediaType: descriptor.mediaType, schemaVersion: descriptor.schemaVersion, bytes: bytes)
            let expectedSource = BoundedReducerProjectionSource(
                source: snapshot.source, cursor: snapshot.cursor)
            switch kind {
            case .work:
                let head = try BoundedWorkReducerHead.decodeOpaqueReducerHead(
                    opaque, limits: reducerLimits)
                guard head.source == expectedSource else {
                    throw ReaderError.invalidCachedProjection
                }
                return .work(head)
            case .session:
                let head = try BoundedSessionReducerHead.decodeOpaqueReducerHead(
                    opaque, limits: reducerLimits)
                guard head.source == expectedSource else {
                    throw ReaderError.invalidCachedProjection
                }
                return .session(head)
            }
        } catch {
            throw ReaderError.invalidCachedProjection
        }
    }

    private func commitStore(
        _ commit: DisposableTimelineProjectionStore.Commit,
        exactStateMap: PersistentProjectionRadixMap?
    ) throws -> DisposableTimelineProjectionStore.Snapshot {
        do {
            let validator: DisposableTimelineProjectionStore.ExactStateCheckpointValidator?
            if commit.exactStateCheckpoint != nil {
                guard let exactStateMap else {
                    throw ReaderError.exactStateUnavailable
                }
                validator = { checkpoint, prior in
                    guard checkpoint.journal == self.journal,
                          checkpoint.roots.count == 1,
                          let descriptor = checkpoint.roots.first,
                          descriptor.mapKind == Self.exactWorkMapKind,
                          descriptor.namespaceID == checkpoint.namespaceID,
                          descriptor.sourceGeneration == checkpoint.sourceGeneration else {
                        throw ReaderError.exactStateUnavailable
                    }
                    if let prior {
                        guard prior.journal == checkpoint.journal,
                              prior.namespaceID == checkpoint.namespaceID,
                              prior.sourceGeneration == checkpoint.sourceGeneration,
                              checkpoint.cursor.sequence >= prior.cursor.sequence else {
                            throw ReaderError.invalidCachedProjection
                        }
                    }
                    try exactStateMap.validateReachable(root: descriptor.root)
                    let state = try PersistentWorkExactState(
                        map: exactStateMap, root: descriptor.root)
                    guard state.currentRoot == descriptor.root,
                          state.eventLocalSnapshot.journal == checkpoint.journal,
                          state.eventLocalSnapshot.lastSequence == checkpoint.cursor.sequence,
                          state.eventLocalSnapshot.lastEventID == checkpoint.cursor.eventID else {
                        throw ReaderError.exactStateUnavailable
                    }
                }
            } else {
                validator = nil
            }
            return try store.commit(
                commit, validatingExactStateCheckpoint: validator)
        } catch let error as DisposableTimelineProjectionStore.StoreError {
            switch error {
            case .invalidCommit(.oversize), .invalidCommit(.invalidBucket):
                throw ReaderError.tooManyBuckets
            default:
                throw ReaderError.storeRejected
            }
        } catch let error as ReaderError {
            throw error
        } catch {
            throw ReaderError.storeRejected
        }
    }

    private func observeSource() throws -> LocalTimelineProjectionSourceLease.Observation {
        do {
            return try lease.observe()
        } catch let error as LocalTimelineProjectionSourceLease.Error {
            switch error {
            case .sourceTooLarge:
                throw ReaderError.sourceTooLarge
            default:
                throw ReaderError.sourceChanged
            }
        } catch {
            throw ReaderError.sourceChanged
        }
    }

    private func fencedSource(
        after prior: LocalTimelineProjectionSourceLease.Observation
    ) throws -> LocalTimelineProjectionSourceLease.Observation {
        let next = try observeSource()
        guard sameObservation(prior.source, next.source) else {
            throw ReaderError.sourceChanged
        }
        return next
    }

    private func makeSource(
        observation: DisposableTimelineProjectionStore.SourceFingerprint,
        prefixByteCount: Int,
        prefixDigest: String
    ) -> DisposableTimelineProjectionStore.SourceFingerprint {
        DisposableTimelineProjectionStore.SourceFingerprint(
            journal: observation.journal, sourceID: observation.sourceID,
            sourceGeneration: observation.sourceGeneration,
            fingerprint: observation.fingerprint,
            sourceByteCount: observation.sourceByteCount,
            prefixByteCount: prefixByteCount, prefixDigest: prefixDigest)
    }

    private func sameObservation(
        _ lhs: DisposableTimelineProjectionStore.SourceFingerprint,
        _ rhs: DisposableTimelineProjectionStore.SourceFingerprint
    ) -> Bool {
        lhs.journal == rhs.journal
            && lhs.sourceID == rhs.sourceID
            && lhs.sourceGeneration == rhs.sourceGeneration
            && lhs.fingerprint == rhs.fingerprint
            && lhs.sourceByteCount == rhs.sourceByteCount
    }

    private func mapStoreError(
        _ error: DisposableTimelineProjectionStore.StoreError
    ) -> ReaderError {
        switch error {
        case .rebuildRequired(.wrongSource), .rebuildRequired(.prefixMismatch),
             .rebuildRequired(.sourceRegression), .cacheUnavailable(.wrongSource),
             .cacheUnavailable(.prefixMismatch):
            return .sourceChanged
        case .rebuildRequired(.missingHead):
            return .cacheUnavailable
        default:
            return .cacheUnavailable
        }
    }
}

private extension TimelineJournalOwner {
    var isProjectionOwner: Bool {
        switch self {
        case .work, .session:
            return true
        case .workHost:
            return false
        }
    }
}
