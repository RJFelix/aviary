import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The bounded, disposable index that lets a Work Host or client catch up a canonical journal
/// without retaining a lifetime-sized snapshot.  This is deliberately an index, not an authority:
/// every value carries the journal/source evidence that produced it and callers must still treat a
/// failed load as "rebuild from canonical JSONL", never as a canonical Work result.
///
/// The store has three small pieces of state:
///
/// * `HEAD` is a checksummed, atomically replaced description of the current prefix and its
///   bounded projections;
/// * immutable content-addressed objects hold buckets, recent pages, opaque reducer heads, and
///   exact-state checkpoint manifests;
/// * deterministic reference files map a fixed-width sealed bucket number to one object.  A
///   reference is one bounded direct lookup, so reading bucket N never enumerates the history.
///
/// The current partial bucket is referenced directly by `HEAD` and can be replaced with a new
/// generation.  Once a bucket is sealed its reference and object are never replaced.  Replaced
/// bounded payloads are reclaimed after `HEAD` publication, while crash or unlink-failure orphans
/// remain harmless. Total namespace size is not a hard bound: quota-triggered rebuild and semantic
/// garbage collection are deliberately a separate policy.
public struct DisposableTimelineProjectionStore: Sendable {
    // Adding exact-state root references changes the on-disk HEAD shape.  There is intentionally
    // no compatibility decoder for the pre-root schema; an old HEAD must be rebuilt.
    public static let schemaVersion = 3
    public static let bucketWidth = 256

    // MARK: Public bounds and records

    /// All store limits live in this value so a Work Host and a GUI can make the same admission
    /// decision.  Initializers clamp values to a finite, positive range; no caller can turn a
    /// supposedly bounded projection into an unbounded file or array.
    public struct Limits: Codable, Hashable, Sendable {
        public static let `default` = Limits()

        public let maximumHeadBytes: Int
        public let maximumObjectBytes: Int
        public let maximumSourceBytes: Int
        public let maximumIdentityBytes: Int
        public let maximumAnchorRecords: Int
        public let maximumRecentPages: Int
        public let maximumRecentPageEvents: Int
        public let maximumRecentPageBytes: Int
        public let maximumReducerHeadBytes: Int
        public let maximumBucketsPerCommit: Int
        public let maximumClearPayloads: Int
        public let maximumPendingAcknowledgements: Int
        public let maximumExactStateRoots: Int
        public let maximumExactStateRootEntries: Int
        public let maximumExactStateCheckpointBytes: Int

        public init(
            maximumHeadBytes: Int = 128 * 1_024,
            maximumObjectBytes: Int = 4 * 1_024 * 1_024,
            maximumSourceBytes: Int = Int.max / 4,
            maximumIdentityBytes: Int = 512,
            maximumAnchorRecords: Int = 512,
            maximumRecentPages: Int = 8,
            maximumRecentPageEvents: Int = 256,
            maximumRecentPageBytes: Int = 512 * 1_024,
            maximumReducerHeadBytes: Int = 256 * 1_024,
            maximumBucketsPerCommit: Int = 64,
            maximumClearPayloads: Int = 32,
            maximumPendingAcknowledgements: Int = 32,
            maximumExactStateRoots: Int = 8,
            maximumExactStateRootEntries: Int = 1_000_000,
            maximumExactStateCheckpointBytes: Int = 128 * 1_024
        ) {
            self.maximumHeadBytes = Self.clamp(maximumHeadBytes, upper: 4 * 1_024 * 1_024)
            self.maximumObjectBytes = Self.clamp(maximumObjectBytes, upper: 64 * 1_024 * 1_024)
            self.maximumSourceBytes = Self.clamp(maximumSourceBytes, upper: Int.max / 4)
            self.maximumIdentityBytes = Self.clamp(maximumIdentityBytes, upper: 4 * 1_024)
            self.maximumAnchorRecords = Self.clamp(maximumAnchorRecords, upper: 4_096)
            self.maximumRecentPages = Self.clamp(maximumRecentPages, upper: 64)
            self.maximumRecentPageEvents = Self.clamp(maximumRecentPageEvents, upper: 4_096)
            self.maximumRecentPageBytes = Self.clamp(maximumRecentPageBytes, upper: 4 * 1_024 * 1_024)
            self.maximumReducerHeadBytes = Self.clamp(maximumReducerHeadBytes, upper: 4 * 1_024 * 1_024)
            self.maximumBucketsPerCommit = Self.clamp(maximumBucketsPerCommit, upper: 256)
            self.maximumClearPayloads = Self.clamp(maximumClearPayloads, upper: 256)
            self.maximumPendingAcknowledgements = Self.clamp(
                maximumPendingAcknowledgements, upper: 256)
            self.maximumExactStateRoots = Self.clamp(maximumExactStateRoots, upper: 64)
            self.maximumExactStateRootEntries = Self.clamp(
                maximumExactStateRootEntries, upper: Int.max / 4)
            self.maximumExactStateCheckpointBytes = Self.clamp(
                maximumExactStateCheckpointBytes, upper: 4 * 1_024 * 1_024)
        }

        private static func clamp(_ value: Int, upper: Int) -> Int {
            max(1, min(value, upper))
        }
    }

    public enum AccessOperation: String, Codable, Hashable, Sendable {
        case prepareDirectory
        case acquireLock
        case readHead
        case readBucketReference
        case readPayload
        case readRecentPage
        case readReducerHead
        case readExactStateCheckpoint
        case writePayload
        case writeReference
        case publishHead
        case clearHead
    }

    /// These reasons deliberately contain no URL/path.  A cache diagnostic must not reveal a
    /// workspace layout, and a reason is enough for the caller to choose rebuild or retry.
    public enum FailureReason: String, Codable, Hashable, Sendable {
        case missingHead
        case missingPayload
        case missingReference
        case malformedHead
        case malformedPayload
        case malformedReference
        case schemaMismatch
        case checksumMismatch
        case wrongJournal
        case wrongSource
        case sourceRegression
        case cursorRegression
        case prefixMismatch
        case chainMismatch
        case duplicateIdentity
        case invalidIdentity
        case invalidDigest
        case invalidOffsets
        case invalidBucket
        case invalidPage
        case invalidReducerHead
        case invalidExactStateRoot
        case invalidExactStateCheckpoint
        case staleGeneration
        case oversize
        case symlinkOrNonRegularFile
        case insecurePermissions
        case accessDenied
        case ioFailure
        case notIndexed
        case invalidClear
        case reentrantAccess
        case publicationIndeterminate
    }

    public enum StoreError: Swift.Error, LocalizedError, Equatable, Sendable {
        case cacheUnavailable(FailureReason)
        case rebuildRequired(FailureReason)
        case invalidCommit(FailureReason)
        case staleGeneration(expected: Int, actual: Int)
        case notFound

        public var errorDescription: String? {
            switch self {
            case .cacheUnavailable(let reason):
                return "Disposable projection cache is unavailable (\(reason.rawValue))."
            case .rebuildRequired(let reason):
                return "Disposable projection cache requires rebuild (\(reason.rawValue))."
            case .invalidCommit(let reason):
                return "Disposable projection commit was rejected (\(reason.rawValue))."
            case .staleGeneration(let expected, let actual):
                return "Disposable projection generation is stale (expected \(expected), got \(actual))."
            case .notFound:
                return "Disposable projection item was not found."
            }
        }
    }

    public typealias Error = StoreError

    /// Identity and byte evidence for the canonical source at the committed cursor.  The stable
    /// `sourceID` is intentionally opaque; a raw filesystem path is not a valid public identity.
    public struct SourceFingerprint: Codable, Hashable, Sendable {
        public let journal: JournalRef
        public let sourceID: String
        /// Stable physical/remote generation identity. For a local journal this is derived from
        /// the validated device/inode/type tuple; an append may change `fingerprint`, but it must
        /// never change this value without invalidating the projection.
        public let sourceGeneration: String
        /// Digest of the current bounded source observation (size/times/boundary evidence).
        public let fingerprint: String
        public let sourceByteCount: Int
        public let prefixByteCount: Int
        public let prefixDigest: String

        public init(
            journal: JournalRef,
            sourceID: String,
            sourceGeneration: String,
            fingerprint: String,
            sourceByteCount: Int,
            prefixByteCount: Int,
            prefixDigest: String
        ) {
            self.journal = journal
            self.sourceID = sourceID
            self.sourceGeneration = sourceGeneration
            self.fingerprint = fingerprint
            self.sourceByteCount = sourceByteCount
            self.prefixByteCount = prefixByteCount
            self.prefixDigest = prefixDigest
        }

        /// A spelling useful at call sites that call the value a source fingerprint rather than
        /// the shorter `fingerprint` field.
        public init(
            journal: JournalRef,
            sourceID: String,
            sourceGeneration: String,
            sourceFingerprint: String,
            sourceByteCount: Int,
            prefixByteCount: Int,
            prefixDigest: String
        ) {
            self.init(
                journal: journal, sourceID: sourceID, sourceGeneration: sourceGeneration,
                fingerprint: sourceFingerprint,
                sourceByteCount: sourceByteCount, prefixByteCount: prefixByteCount,
                prefixDigest: prefixDigest)
        }

        public var sourceFingerprint: String { fingerprint }
    }

    /// The immutable prefix before the first bucket represented by this cache.  `sequence` is
    /// normally zero, but a cache may be seeded at a sequence boundary divisible by 256.
    public struct PrefixSeed: Codable, Hashable, Sendable {
        public let byteCount: Int
        public let digest: String
        public let sequence: Int
        public let previousEventID: String?

        public init(
            byteCount: Int,
            digest: String,
            sequence: Int = 0,
            previousEventID: String? = nil
        ) {
            self.byteCount = byteCount
            self.digest = digest
            self.sequence = sequence
            self.previousEventID = previousEventID
        }
    }

    /// One bounded anchor retained in `HEAD`.  It is enough to diagnose/seek a prefix without
    /// retaining event bodies or every historical row in the head file.
    public struct AnchorRecord: Codable, Hashable, Sendable {
        public let sequence: Int
        public let eventID: String
        public let previousEventID: String?
        public let byteStart: Int
        public let byteEnd: Int
        public let prefixDigestBefore: String
        public let prefixDigestAfter: String
        public let lineDigest: String

        public init(
            sequence: Int,
            eventID: String,
            previousEventID: String?,
            byteStart: Int,
            byteEnd: Int,
            prefixDigestBefore: String,
            prefixDigestAfter: String,
            lineDigest: String
        ) {
            self.sequence = sequence
            self.eventID = eventID
            self.previousEventID = previousEventID
            self.byteStart = byteStart
            self.byteEnd = byteEnd
            self.prefixDigestBefore = prefixDigestBefore
            self.prefixDigestAfter = prefixDigestAfter
            self.lineDigest = lineDigest
        }
    }

    /// A row is metadata only.  Canonical event bytes remain in JSONL; this object proves the
    /// sequence/offset/prefix relationship needed to address a bounded suffix.
    public struct BucketRow: Codable, Hashable, Sendable {
        public let sequence: Int
        public let eventID: String
        public let previousEventID: String?
        public let byteStart: Int
        public let byteEnd: Int
        public let prefixDigestBefore: String
        public let prefixDigestAfter: String
        public let lineDigest: String

        public init(
            sequence: Int,
            eventID: String,
            previousEventID: String?,
            byteStart: Int,
            byteEnd: Int,
            prefixDigestBefore: String,
            prefixDigestAfter: String,
            lineDigest: String
        ) {
            self.sequence = sequence
            self.eventID = eventID
            self.previousEventID = previousEventID
            self.byteStart = byteStart
            self.byteEnd = byteEnd
            self.prefixDigestBefore = prefixDigestBefore
            self.prefixDigestAfter = prefixDigestAfter
            self.lineDigest = lineDigest
        }
    }

    public typealias EventRow = BucketRow

    public struct Bucket: Codable, Hashable, Sendable {
        public let bucketStart: Int
        public let rows: [BucketRow]

        public init(bucketStart: Int, rows: [BucketRow]) {
            self.bucketStart = bucketStart
            self.rows = rows
        }

        public var bucketEnd: Int? {
            guard let last = rows.last else { return nil }
            return last.sequence
        }
    }

    public typealias SequenceBucket = Bucket

    /// An optional recent page.  Pages are separate immutable objects rather than being copied
    /// into `HEAD`, which keeps the head checksum small even when a page contains rich envelopes.
    public struct RecentEventPage: Codable, Hashable, Sendable {
        public let pageID: String
        public let events: [TimelineEvent]

        public init(pageID: String, events: [TimelineEvent]) {
            self.pageID = pageID
            self.events = events
        }

        public var sequenceStart: Int? { events.first?.sequence }
        public var sequenceEnd: Int? { events.last?.sequence }
    }

    public struct OpaqueReducerHead: Codable, Hashable, Sendable {
        public let mediaType: String
        public let schemaVersion: Int
        public let bytes: Data

        public init(mediaType: String = "application/octet-stream", schemaVersion: Int = 1,
                    bytes: Data) {
            self.mediaType = mediaType
            self.schemaVersion = schemaVersion
            self.bytes = bytes
        }
    }

    public struct BucketDescriptor: Codable, Hashable, Sendable {
        public let bucketStart: Int
        public let rowCount: Int
        public let lastSequence: Int
        public let objectID: String
        public let byteCount: Int
        public let generation: Int

        public init(bucketStart: Int, rowCount: Int, lastSequence: Int, objectID: String,
                    byteCount: Int, generation: Int) {
            self.bucketStart = bucketStart
            self.rowCount = rowCount
            self.lastSequence = lastSequence
            self.objectID = objectID
            self.byteCount = byteCount
            self.generation = generation
        }
    }

    public struct RecentEventPageDescriptor: Codable, Hashable, Sendable {
        public let pageID: String
        public let sequenceStart: Int
        public let sequenceEnd: Int
        public let eventCount: Int
        public let objectID: String
        public let byteCount: Int
        public let digest: String

        public init(pageID: String, sequenceStart: Int, sequenceEnd: Int, eventCount: Int,
                    objectID: String, byteCount: Int, digest: String) {
            self.pageID = pageID
            self.sequenceStart = sequenceStart
            self.sequenceEnd = sequenceEnd
            self.eventCount = eventCount
            self.objectID = objectID
            self.byteCount = byteCount
            self.digest = digest
        }
    }

    public struct OpaquePayloadDescriptor: Codable, Hashable, Sendable {
        public let objectID: String
        public let mediaType: String
        public let schemaVersion: Int
        public let byteCount: Int
        public let digest: String

        public init(objectID: String, mediaType: String, schemaVersion: Int, byteCount: Int,
                    digest: String) {
            self.objectID = objectID
            self.mediaType = mediaType
            self.schemaVersion = schemaVersion
            self.byteCount = byteCount
            self.digest = digest
        }
    }

    public typealias ReducerHeadDescriptor = OpaquePayloadDescriptor

    /// A bounded, metadata-only reference to one exact reducer-state map root.
    ///
    /// The map owns the content-addressed objects and remains the authority for validating the
    /// root against those objects.  This descriptor deliberately carries only the scoped root
    /// envelope, so a projection HEAD never embeds a raw key, value, or filesystem path.  An
    /// integration that is about to publish a root must call the corresponding map's `validate`
    /// while holding its own integration lock; storing or loading this descriptor does not claim
    /// whole-tree semantic validation.
    public struct ExactStateRootDescriptor: Codable, Hashable, Sendable {
        public let root: PersistentProjectionRadixMap.Root
        public init(root: PersistentProjectionRadixMap.Root) {
            self.root = root
        }

        public var schemaVersion: Int { root.schemaVersion }
        public var namespaceID: String { root.namespaceID }
        public var journal: JournalRef { root.journal }
        public var sourceGeneration: String { root.sourceGeneration }
        public var mapKind: String { root.mapKind }
        public var objectID: String { root.objectID }
        public var entryCount: Int { root.entryCount }

        // Encode the same flat root envelope as PersistentProjectionRadixMap.Root. Keeping the
        // descriptor's JSON flat makes the checkpoint auditable and avoids introducing a second
        // nested schema without making the map root itself visible to callers.
        public func encode(to encoder: Encoder) throws {
            try root.encode(to: encoder)
        }

        public init(from decoder: Decoder) throws {
            self.root = try PersistentProjectionRadixMap.Root(from: decoder)
        }
    }

    /// The content-addressed exact-state checkpoint written beside the bounded projection. The
    /// manifest, rather than an individual map root, binds a bounded ordered root set to one
    /// exact journal prefix. A semantic no-op may reuse map nodes while still producing a new
    /// checkpoint at the new cursor.
    public struct ExactStateCheckpoint: Encodable, Hashable, Sendable {
        public static let schemaVersion = 1

        public let schemaVersion: Int
        public let namespaceID: String
        public let journal: JournalRef
        public let sourceGeneration: String
        public let cursor: JournalCursor
        public let prefixByteCount: Int
        public let prefixDigest: String
        public let roots: [ExactStateRootDescriptor]

        init(
            namespaceID: String,
            journal: JournalRef,
            sourceGeneration: String,
            cursor: JournalCursor,
            prefixByteCount: Int,
            prefixDigest: String,
            roots: [ExactStateRootDescriptor]
        ) {
            self.schemaVersion = Self.schemaVersion
            self.namespaceID = namespaceID
            self.journal = journal
            self.sourceGeneration = sourceGeneration
            self.cursor = cursor
            self.prefixByteCount = prefixByteCount
            self.prefixDigest = prefixDigest
            self.roots = DisposableTimelineProjectionStore.sortedExactStateRoots(roots)
        }

        fileprivate init(persisted: PersistedExactStateCheckpoint) {
            self.schemaVersion = persisted.schemaVersion
            self.namespaceID = persisted.namespaceID
            self.journal = persisted.journal
            self.sourceGeneration = persisted.sourceGeneration
            self.cursor = persisted.cursor
            self.prefixByteCount = persisted.prefixByteCount
            self.prefixDigest = persisted.prefixDigest
            self.roots = persisted.roots
        }
    }

    /// The bounded HEAD reference to an exact-state checkpoint object. The root set itself stays
    /// in that immutable object so HEAD remains small and cannot be mistaken for the checkpoint's
    /// semantic contents.
    public struct ExactStateCheckpointDescriptor: Codable, Hashable, Sendable {
        public let objectID: String
        public let schemaVersion: Int
        public let byteCount: Int
        public let digest: String

        public init(objectID: String, schemaVersion: Int, byteCount: Int, digest: String) {
            self.objectID = objectID
            self.schemaVersion = schemaVersion
            self.byteCount = byteCount
            self.digest = digest
        }
    }

    /// The integration seam for proving an exact-state checkpoint. The store invokes this bounded
    /// callback while holding its exclusive lock, before writing any payload or replacing `HEAD`.
    /// The integration receives the complete current manifest and the prior manifest so it can
    /// authenticate transitions (including semantic no-ops) rather than merely checking one map
    /// root's object path. Validators must not call back into this store; same-thread re-entry is
    /// rejected with `reentrantAccess`. Integrations that validate a radix map must use one global
    /// lock order—projection store before map—and must never acquire the store while holding a map
    /// lock.
    public typealias ExactStateCheckpointValidator = @Sendable (
        ExactStateCheckpoint, ExactStateCheckpoint?
    ) throws -> Void

    /// Short spelling for callers that already speak in terms of root references.
    public typealias ExactRootDescriptor = ExactStateRootDescriptor
    public typealias ExactStateRoot = ExactStateRootDescriptor

    /// A HEAD whose stored prefix was checked against a fresh canonical source observation in the
    /// same locked operation. The observation is returned because a growing source can validly be
    /// newer than the stored projection and must be reused for subsequent direct lookups.
    public struct ValidatedSnapshot: Hashable, Sendable {
        public let snapshot: Snapshot
        public let observedSource: SourceFingerprint

        public init(snapshot: Snapshot, observedSource: SourceFingerprint) {
            self.snapshot = snapshot
            self.observedSource = observedSource
        }
    }

    /// The exact bounded cache evidence a canonical source reader must prove before a HEAD can be
    /// used. `terminalRow` is nil only when the projection is exactly at its explicit prefix seed.
    public struct SourceValidationChallenge: Hashable, Sendable {
        public let storedSource: SourceFingerprint
        public let cursor: JournalCursor
        public let prefixSeed: PrefixSeed
        public let terminalRow: BucketRow?

        public init(
            storedSource: SourceFingerprint,
            cursor: JournalCursor,
            prefixSeed: PrefixSeed,
            terminalRow: BucketRow?
        ) {
            self.storedSource = storedSource
            self.cursor = cursor
            self.prefixSeed = prefixSeed
            self.terminalRow = terminalRow
        }
    }

    /// Acknowledgement intent is a client-side obligation, not evidence that the canonical
    /// Work-Host control journal accepted an acknowledgement.  It remains bounded and is cleared
    /// only by the next projection commit that carries the updated control cursor.
    public struct PendingAcknowledgement: Codable, Hashable, Sendable {
        public let request: WorkServiceAcknowledgeReadRequest
        public let stale: Bool

        public init(
            request: WorkServiceAcknowledgeReadRequest,
            stale: Bool = false
        ) {
            self.request = request
            self.stale = stale
        }
    }

    /// The complete bounded `HEAD` projection.  It does not include sealed bucket rows or page
    /// bodies; those are fetched by direct object/reference lookup.
    public struct Snapshot: Codable, Hashable, Sendable {
        public let schemaVersion: Int
        public let namespaceID: String
        public let journal: JournalRef
        public let source: SourceFingerprint
        public let cursor: JournalCursor
        public let prefixSeed: PrefixSeed
        public let nextSequence: Int
        public let nextPreviousEventID: String?
        public let sealedThroughSequence: Int
        public let sealedBucketCount: Int
        public let currentBucket: BucketDescriptor?
        public let anchors: [AnchorRecord]
        public let recentPages: [RecentEventPageDescriptor]
        /// True when the retained pages are only a bounded suffix rather than every canonical
        /// event after `prefixSeed`. Page bodies are optional cache material; this bit prevents
        /// an empty or shortened page list from masquerading as a complete recent transcript.
        public let recentEventsOmitted: Bool
        public let reducerHead: OpaquePayloadDescriptor?
        public let exactStateCheckpoint: ExactStateCheckpointDescriptor?
        public let pendingAcknowledgements: [PendingAcknowledgement]
        public let generation: Int

        public init(
            namespaceID: String,
            journal: JournalRef,
            source: SourceFingerprint,
            cursor: JournalCursor,
            prefixSeed: PrefixSeed,
            nextSequence: Int,
            nextPreviousEventID: String?,
            sealedThroughSequence: Int,
            sealedBucketCount: Int,
            currentBucket: BucketDescriptor?,
            anchors: [AnchorRecord],
            recentPages: [RecentEventPageDescriptor],
            recentEventsOmitted: Bool,
            reducerHead: OpaquePayloadDescriptor?,
            exactStateCheckpoint: ExactStateCheckpointDescriptor? = nil,
            pendingAcknowledgements: [PendingAcknowledgement] = [],
            generation: Int
        ) {
            self.schemaVersion = DisposableTimelineProjectionStore.schemaVersion
            self.namespaceID = namespaceID
            self.journal = journal
            self.source = source
            self.cursor = cursor
            self.prefixSeed = prefixSeed
            self.nextSequence = nextSequence
            self.nextPreviousEventID = nextPreviousEventID
            self.sealedThroughSequence = sealedThroughSequence
            self.sealedBucketCount = sealedBucketCount
            self.currentBucket = currentBucket
            self.anchors = Array(anchors)
            self.recentPages = Array(recentPages)
            self.recentEventsOmitted = recentEventsOmitted
            self.reducerHead = reducerHead
            self.exactStateCheckpoint = exactStateCheckpoint
            self.pendingAcknowledgements = Array(pendingAcknowledgements)
            self.generation = generation
        }
    }

    /// A commit is a replacement of the bounded projection, not an append to the cache.  The
    /// canonical source append chain remains the caller's responsibility; `expectedGeneration`
    /// prevents two readers from publishing competing cache heads.
    public struct Commit: Encodable, Hashable, Sendable {
        public let source: SourceFingerprint
        public let cursor: JournalCursor
        public let prefixSeed: PrefixSeed
        public let nextSequence: Int
        public let nextPreviousEventID: String?
        public let sealedBuckets: [Bucket]
        public let currentBucket: Bucket?
        public let anchors: [AnchorRecord]
        public let recentPages: [RecentEventPage]
        public let reducerHead: OpaqueReducerHead?
        public let exactStateCheckpoint: ExactStateCheckpoint?
        public let pendingAcknowledgements: [PendingAcknowledgement]
        public let expectedGeneration: Int?

        public init(
            source: SourceFingerprint,
            cursor: JournalCursor,
            prefixSeed: PrefixSeed,
            nextSequence: Int,
            nextPreviousEventID: String?,
            sealedBuckets: [Bucket] = [],
            currentBucket: Bucket? = nil,
            anchors: [AnchorRecord] = [],
            recentPages: [RecentEventPage] = [],
            reducerHead: OpaqueReducerHead? = nil,
            exactStateCheckpoint: ExactStateCheckpoint? = nil,
            pendingAcknowledgements: [PendingAcknowledgement] = [],
            expectedGeneration: Int? = nil
        ) {
            self.source = source
            self.cursor = cursor
            self.prefixSeed = prefixSeed
            self.nextSequence = nextSequence
            self.nextPreviousEventID = nextPreviousEventID
            self.sealedBuckets = sealedBuckets
            self.currentBucket = currentBucket
            self.anchors = anchors
            self.recentPages = recentPages
            self.reducerHead = reducerHead
            self.exactStateCheckpoint = exactStateCheckpoint
            self.pendingAcknowledgements = pendingAcknowledgements
            self.expectedGeneration = expectedGeneration
        }
    }

    public typealias ProjectionCommit = Commit

    public struct ClearResult: Codable, Hashable, Sendable {
        public let hadHead: Bool
        public let removedPayloads: Int
        public let retainedImmutablePayloads: Bool
        public let rebuildRequired: Bool

        public init(hadHead: Bool, removedPayloads: Int, retainedImmutablePayloads: Bool,
                    rebuildRequired: Bool) {
            self.hadHead = hadHead
            self.removedPayloads = removedPayloads
            self.retainedImmutablePayloads = retainedImmutablePayloads
            self.rebuildRequired = rebuildRequired
        }
    }

    // MARK: Store lifecycle

    public let directory: URL
    public let journal: JournalRef
    public let limits: Limits
    private let observer: (@Sendable (AccessOperation) -> Void)?

    public init(
        directory: URL,
        journal: JournalRef,
        limits: Limits = .default,
        observer: (@Sendable (AccessOperation) -> Void)? = nil
    ) throws {
        // Lexically normalize aliases such as `/a/./b` and `/a/c/../b` before deriving the
        // reentrancy key. Symlinks are still rejected by `prepareDirectory`; this does not resolve
        // or authorize an alternate filesystem target.
        self.directory = directory.standardizedFileURL
        self.journal = journal
        self.limits = limits
        self.observer = observer
        try prepareDirectory()
    }

    /// Read `HEAD` and its single terminal bucket proof. Sealed history and stored seek anchors
    /// are intentionally lazy; a direct historical lookup validates only the object it touches.
    public func load(proving observedSource: SourceFingerprint) throws -> Snapshot {
        try prepareDirectory()
        return try withLock {
            try readHeadLocked(proving: observedSource)
        }
    }

    /// Load a HEAD and prove its exact-state checkpoint while the store lock is held. The callback
    /// receives the complete manifest; this store still does not own or semantically inspect the
    /// map object graph itself.
    public func load(
        proving observedSource: SourceFingerprint,
        validatingExactStateCheckpoint validator: ExactStateCheckpointValidator
    ) throws -> Snapshot {
        try prepareDirectory()
        return try withLock {
            let snapshot = try readHeadLocked(proving: observedSource)
            guard let checkpoint = try readExactStateCheckpointDescriptorLocked(snapshot) else {
                return snapshot
            }
            do { try validator(checkpoint, nil) }
            catch StoreError.cacheUnavailable(.reentrantAccess) {
                throw StoreError.cacheUnavailable(.reentrantAccess)
            } catch {
                throw StoreError.cacheUnavailable(.invalidExactStateCheckpoint)
            }
            return snapshot
        }
    }

    /// Bootstrap a production source lease without exposing an unvalidated cache header. The
    /// validator receives the checksummed-but-untrusted stored source boundary plus its exact
    /// indexed terminal row, proves that boundary against the canonical journal, and returns its
    /// fresh observation. It is synchronous by design: callers must not await or acquire a
    /// canonical writer while holding this store's lock.
    public func load(
        validatingSource validator: (SourceValidationChallenge) throws -> SourceFingerprint
    ) throws -> ValidatedSnapshot {
        try prepareDirectory()
        return try withLock {
            guard let snapshot = try readHeadIfPresentLocked() else {
                throw StoreError.rebuildRequired(.missingHead)
            }
            let terminal = try validateProjectedTerminalLocked(snapshot)
            // A source-valid HEAD is still unusable when its exact-state manifest is missing or
            // malformed. Resolve the content-addressed checkpoint before exposing a
            // `ValidatedSnapshot`; semantic map validation remains the integration's concern.
            _ = try readExactStateCheckpointDescriptorLocked(snapshot)
            let observed = try validator(SourceValidationChallenge(
                storedSource: snapshot.source, cursor: snapshot.cursor,
                prefixSeed: snapshot.prefixSeed, terminalRow: terminal))
            try validateObservedSource(observed, against: snapshot.source)
            return ValidatedSnapshot(snapshot: snapshot, observedSource: observed)
        }
    }

    /// Publish a new generation. Payloads and sealed references are durable before `HEAD` is
    /// renamed, so a crash leaves only harmless orphaned content and the previous valid head.
    /// A failure to sync the directory after the rename is `publicationIndeterminate`; callers
    /// must reload HEAD instead of blindly replaying the old expected generation.
    @discardableResult
    public func commit(_ commit: Commit) throws -> Snapshot {
        try self.commit(commit, validatingExactStateCheckpoint: nil as ExactStateCheckpointValidator?)
    }

    /// Publish a generation after proving its complete exact-state checkpoint under the store
    /// lock. A rootless commit keeps the original bounded-store API. Checkpoint-bearing commits
    /// must provide the integration callback because this store cannot locate or semantically
    /// validate a map's content-addressed objects on its own.
    @discardableResult
    public func commit(
        _ commit: Commit,
        validatingExactStateCheckpoint validator: ExactStateCheckpointValidator?
    ) throws -> Snapshot {
        try prepareDirectory()
        return try withLock {
            let old = try readHeadIfPresentLocked()
            if let old { try validateProjectedTerminalLocked(old) }
            let nextGeneration: Int
            let namespaceID: String
            if let old {
                guard let expected = commit.expectedGeneration else {
                    throw StoreError.invalidCommit(.staleGeneration)
                }
                guard expected == old.generation else {
                    throw StoreError.staleGeneration(expected: expected, actual: old.generation)
                }
                guard old.generation < Int.max else {
                    throw StoreError.invalidCommit(.staleGeneration)
                }
                nextGeneration = old.generation + 1
                namespaceID = old.namespaceID
            } else {
                guard commit.expectedGeneration == nil || commit.expectedGeneration == 0 else {
                    throw StoreError.staleGeneration(expected: commit.expectedGeneration ?? 0, actual: 0)
                }
                nextGeneration = 1
                // Adopt a checkpoint's namespace for the first combined publication so bucket
                // references and exact state share one projection namespace. A root-free first
                // commit keeps the historical random namespace behavior.
                namespaceID = commit.exactStateCheckpoint?.namespaceID
                    ?? "p-" + UUID().uuidString.lowercased()
            }

            let priorCheckpoint: ExactStateCheckpoint?
            if let old {
                priorCheckpoint = try readExactStateCheckpointDescriptorLocked(old)
            } else {
                priorCheckpoint = nil
            }
            try validateCommit(
                commit, old: old, namespaceID: namespaceID, priorCheckpoint: priorCheckpoint)
            try validateExactStateRootPublicationLocked(
                commit.exactStateCheckpoint, prior: priorCheckpoint, validator: validator)
            if commit.exactStateCheckpoint != nil {
                try reserveExactNamespaceLocked(
                    namespaceID: namespaceID, initialCommit: commit, existingHead: old)
            }

            let oldSealedThrough = old?.sealedThroughSequence ?? commit.prefixSeed.sequence
            var sealedThrough = oldSealedThrough
            if let last = commit.sealedBuckets.last {
                sealedThrough = last.bucketStart + Self.bucketWidth - 1
            }

            // Immutable bucket objects and deterministic references are written before the head.
            for bucket in commit.sealedBuckets {
                let descriptor = try writeBucketObjectLocked(
                    bucket, namespaceID: namespaceID, source: commit.source,
                    generation: nextGeneration, sealed: true)
                try writeBucketReferenceLocked(
                    bucketStart: bucket.bucketStart, namespaceID: namespaceID,
                    objectID: descriptor.objectID, generation: nextGeneration)
            }

            let currentDescriptor: BucketDescriptor?
            if let current = commit.currentBucket {
                currentDescriptor = try writeBucketObjectLocked(
                    current, namespaceID: namespaceID, source: commit.source,
                    generation: nextGeneration, sealed: false)
            } else {
                currentDescriptor = nil
            }

            let pageDescriptors = try commit.recentPages.map {
                try writeRecentPageLocked($0, namespaceID: namespaceID, source: commit.source)
            }
            let recentPagesCoverRetainedPrefix: Bool
            if commit.cursor.sequence == commit.prefixSeed.sequence {
                recentPagesCoverRetainedPrefix = commit.recentPages.isEmpty
            } else {
                recentPagesCoverRetainedPrefix =
                    commit.recentPages.first?.sequenceStart == commit.prefixSeed.sequence + 1
                    && commit.recentPages.last?.sequenceEnd == commit.cursor.sequence
            }
            let reducerDescriptor: OpaquePayloadDescriptor?
            if let reducerHead = commit.reducerHead {
                reducerDescriptor = try writeReducerHeadLocked(
                    reducerHead, namespaceID: namespaceID, source: commit.source)
            } else {
                reducerDescriptor = nil
            }

            let exactCheckpointDescriptor = try commit.exactStateCheckpoint.map {
                try writeExactStateCheckpointLocked($0, namespaceID: namespaceID, source: commit.source)
            }

            let snapshot = Snapshot(
                namespaceID: namespaceID, journal: journal, source: commit.source,
                cursor: commit.cursor, prefixSeed: commit.prefixSeed,
                nextSequence: commit.nextSequence,
                nextPreviousEventID: commit.nextPreviousEventID,
                sealedThroughSequence: sealedThrough,
                sealedBucketCount: (sealedThrough - commit.prefixSeed.sequence)
                    / Self.bucketWidth,
                currentBucket: currentDescriptor,
                anchors: commit.anchors,
                recentPages: pageDescriptors,
                recentEventsOmitted: !recentPagesCoverRetainedPrefix,
                reducerHead: reducerDescriptor,
                exactStateCheckpoint: exactCheckpointDescriptor,
                pendingAcknowledgements: commit.pendingAcknowledgements,
                generation: nextGeneration)
            try writeHeadLocked(snapshot)
            reclaimReplacedPayloadsLocked(old: old, new: snapshot)
            return snapshot
        }
    }

    /// Directly load the fixed-width bucket containing `sequence`.  This opens `HEAD`, one
    /// deterministic reference (for a sealed bucket), and one content object at most.
    public func loadBucket(
        containingSequence sequence: Int,
        proving observedSource: SourceFingerprint
    ) throws -> Bucket {
        guard sequence >= 0 else { throw StoreError.notFound }
        try prepareDirectory()
        return try withLock {
            let snapshot = try readHeadLocked(proving: observedSource)
            guard sequence > snapshot.prefixSeed.sequence,
                  sequence <= snapshot.cursor.sequence else {
                throw StoreError.notFound
            }
            let start = Self.bucketStart(for: sequence)
            let objectID: String
            let expectedGeneration: Int?
            let expectedByteCount: Int?
            if start <= snapshot.sealedThroughSequence {
                objectID = try readBucketReferenceLocked(
                    bucketStart: start, namespaceID: snapshot.namespaceID)
                expectedGeneration = nil
                expectedByteCount = nil
            } else if let current = snapshot.currentBucket, current.bucketStart == start {
                objectID = current.objectID
                expectedGeneration = current.generation
                expectedByteCount = current.byteCount
            } else {
                throw StoreError.cacheUnavailable(.notIndexed)
            }
            let bucket = try readBucketObjectLocked(
                objectID: objectID, namespaceID: snapshot.namespaceID,
                sourceID: snapshot.source.sourceID,
                expectedByteCount: expectedByteCount,
                expectedGeneration: expectedGeneration)
            guard bucket.bucketStart == start,
                  bucket.rows.contains(where: { $0.sequence == sequence }) else {
                throw StoreError.cacheUnavailable(.invalidBucket)
            }
            return bucket
        }
    }

    public func loadBucket(
        startingAt bucketStart: Int,
        proving observedSource: SourceFingerprint
    ) throws -> Bucket {
        guard bucketStart > 0, bucketStart == Self.bucketStart(for: bucketStart) else {
            throw StoreError.notFound
        }
        return try loadBucket(containingSequence: bucketStart, proving: observedSource)
    }

    /// Fetch one recent page by its stable page identity.  Bodies stay outside `HEAD` and are
    /// returned only on explicit request.
    public func loadRecentPage(
        id pageID: String,
        proving observedSource: SourceFingerprint
    ) throws -> RecentEventPage {
        try prepareDirectory()
        return try withLock {
            let snapshot = try readHeadLocked(proving: observedSource)
            guard let descriptor = snapshot.recentPages.first(where: { $0.pageID == pageID }) else {
                throw StoreError.notFound
            }
            return try readRecentPageLocked(
                descriptor, namespaceID: snapshot.namespaceID,
                sourceID: snapshot.source.sourceID)
        }
    }

    public func loadReducerHead(proving observedSource: SourceFingerprint) throws -> Data {
        try prepareDirectory()
        return try withLock {
            let snapshot = try readHeadLocked(proving: observedSource)
            guard let descriptor = snapshot.reducerHead else { throw StoreError.notFound }
            return try readReducerHeadLocked(
                descriptor, namespaceID: snapshot.namespaceID,
                sourceID: snapshot.source.sourceID)
        }
    }

    /// Load the bounded exact-state root references from `HEAD`.  This returns metadata only; an
    /// integration that needs to use a root must validate its map objects under the integration
    /// lock before performing a lookup or reducer operation.
    public func loadExactStateRoots(
        proving observedSource: SourceFingerprint
    ) throws -> [ExactStateRootDescriptor] {
        try loadExactStateCheckpoint(proving: observedSource)?.roots ?? []
    }

    /// Load and validate the immutable exact-state checkpoint manifest referenced by `HEAD`.
    /// The manifest object proves the source boundary and root set; semantic map object validation
    /// remains the responsibility of the integration callback.
    public func loadExactStateCheckpoint(
        proving observedSource: SourceFingerprint
    ) throws -> ExactStateCheckpoint? {
        try prepareDirectory()
        return try withLock {
            let snapshot = try readHeadLocked(proving: observedSource)
            return try readExactStateCheckpointDescriptorLocked(snapshot)
        }
    }

    /// Resolve and prove one seek anchor lazily. Ordinary HEAD and payload reads never walk the
    /// historical anchor set; a caller pays for exactly the bucket containing the anchor it uses.
    public func loadAnchor(
        at sequence: Int,
        proving observedSource: SourceFingerprint
    ) throws -> AnchorRecord {
        guard sequence > 0 else { throw StoreError.notFound }
        try prepareDirectory()
        return try withLock {
            let snapshot = try readHeadLocked(proving: observedSource)
            guard let anchor = snapshot.anchors.first(where: { $0.sequence == sequence }) else {
                throw StoreError.notFound
            }
            let bucket = try readIndexedBucketLocked(
                startingAt: Self.bucketStart(for: sequence), snapshot: snapshot)
            guard let row = bucket.rows.first(where: { $0.sequence == sequence }),
                  anchorMatchesRow(anchor, row) else {
                throw StoreError.cacheUnavailable(.invalidBucket)
            }
            return anchor
        }
    }

    /// Remove `HEAD` and the bounded set of currently referenced replaceable payloads.  Sealed
    /// references/objects are intentionally retained as orphaned immutable data; deleting them
    /// would require an unbounded directory walk and would make recovery from an interrupted
    /// clear less safe. Exact-state namespaces are durably retired before HEAD is removed; a
    /// later rebuild must use a fresh namespace and therefore can never trust retained references.
    public func clear() throws -> ClearResult {
        try prepareDirectory()
        return try withLock {
            // A corrupt HEAD cannot safely reveal which exact namespace must be retired. Fail
            // closed instead of deleting evidence and permitting a caller-supplied namespace to
            // alias retained sealed references.
            let old = try readHeadIfPresentLocked()
            let retiredExactNamespace = try retireActiveExactNamespaceLocked(
                expectedNamespaceID: old?.namespaceID,
                required: old?.exactStateCheckpoint != nil)
            // Invalidate first. Cleanup is bounded and best-effort; a failure after this point may
            // leak an orphan, but it can never leave a published head referring to a removed
            // object.
            guard try removeHeadLocked() else {
                throw StoreError.cacheUnavailable(.invalidClear)
            }
            notify(.clearHead)
            try synchronizeDirectoryLocked()
            if retiredExactNamespace {
                try removeActiveExactNamespacePointerLocked()
            }
            var removed = 0
            if let old {
                if let current = old.currentBucket {
                    if (try? removePayloadIfPresentLocked(current.objectID)) == true { removed += 1 }
                }
                for page in old.recentPages.prefix(limits.maximumClearPayloads) {
                    if (try? removePayloadIfPresentLocked(page.objectID)) == true { removed += 1 }
                }
                if let reducer = old.reducerHead,
                   (try? removePayloadIfPresentLocked(reducer.objectID)) == true {
                    removed += 1
                }
                if let checkpoint = old.exactStateCheckpoint,
                   (try? removePayloadIfPresentLocked(checkpoint.objectID)) == true {
                    removed += 1
                }
            }
            return ClearResult(
                hadHead: old != nil, removedPayloads: removed,
                retainedImmutablePayloads: true, rebuildRequired: true)
        }
    }

    public static func bucketStart(for sequence: Int) -> Int {
        guard sequence > 0 else { return 1 }
        let zeroBased = sequence - 1
        return (zeroBased / bucketWidth) * bucketWidth + 1
    }

    /// Stable JSON encoding is useful for tests and for callers that need to fingerprint a
    /// projection input without depending on dictionary iteration order.
    public static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// The same hash-chain domain used by JournalBackedWorkService. Keeping this algorithm public
    /// prevents a projection producer from inventing a second, incompatible notion of prefix.
    public static func canonicalPrefixSeed(for journal: JournalRef) -> String {
        hexDigest(Data("aviary-prefix-v1\u{0}seed\u{0}\(journal.stableKey)".utf8))
    }

    public static func canonicalEventLineDigest(_ event: TimelineEvent) throws -> String {
        hexDigest(try canonicalJSON(event) + Data([UInt8(ascii: "\n")]))
    }

    public static func advancePrefixDigest(_ prefix: String, lineDigest: String) -> String {
        var material = Data("aviary-prefix-v1\u{0}".utf8)
        material.append(Data(prefix.utf8))
        material.append(0)
        material.append(Data(lineDigest.utf8))
        return hexDigest(material)
    }

    // MARK: Validation

    private func validateCommit(
        _ commit: Commit, old: Snapshot?, namespaceID: String,
        priorCheckpoint: ExactStateCheckpoint?
    ) throws {
        guard commit.source.journal == journal,
              commit.cursor.journal == journal else {
            throw StoreError.invalidCommit(.wrongJournal)
        }
        try validateSource(commit.source)
        try validateCursor(commit.cursor)
        try validatePrefixSeed(commit.prefixSeed, source: commit.source)
        if let checkpoint = commit.exactStateCheckpoint {
            try validateExactStateCheckpoint(
                checkpoint, namespaceID: namespaceID, source: commit.source,
                cursor: commit.cursor, prior: priorCheckpoint)
        } else if priorCheckpoint != nil {
            // A root-bearing HEAD cannot be replaced by a rootless commit. Such a commit would
            // silently erase the exact-state publication while still advancing the bounded head.
            throw StoreError.invalidCommit(.invalidExactStateCheckpoint)
        }
        guard commit.nextSequence > 0,
              commit.cursor.sequence < Int.max,
              commit.nextSequence == commit.cursor.sequence + 1,
              commit.nextPreviousEventID == commit.cursor.eventID,
              commit.nextSequence < Int.max else {
            throw StoreError.invalidCommit(.cursorRegression)
        }
        guard commit.anchors.count <= limits.maximumAnchorRecords else {
            throw StoreError.invalidCommit(.oversize)
        }
        try validatePendingAcknowledgements(
            commit.pendingAcknowledgements, workCursor: commit.cursor)
        guard commit.sealedBuckets.count <= limits.maximumBucketsPerCommit else {
            throw StoreError.invalidCommit(.oversize)
        }
        if let reducer = commit.reducerHead {
            guard reducer.bytes.count <= limits.maximumReducerHeadBytes,
                  reducer.schemaVersion > 0,
                  validMediaType(reducer.mediaType) else {
                throw StoreError.invalidCommit(.oversize)
            }
        }

        if let old {
            guard old.journal == journal,
                  old.source.journal == journal,
                  old.source.sourceID == commit.source.sourceID,
                  old.source.sourceGeneration == commit.source.sourceGeneration else {
                throw StoreError.invalidCommit(.wrongSource)
            }
            guard commit.source.sourceByteCount >= old.source.sourceByteCount,
                  commit.source.prefixByteCount >= old.source.prefixByteCount,
                  commit.cursor.sequence >= old.cursor.sequence else {
                throw StoreError.invalidCommit(.sourceRegression)
            }
            if commit.cursor.sequence == old.cursor.sequence {
                guard commit.cursor.eventID == old.cursor.eventID,
                      commit.source.prefixDigest == old.source.prefixDigest,
                      commit.source.prefixByteCount == old.source.prefixByteCount else {
                    throw StoreError.invalidCommit(.prefixMismatch)
                }
            }
            guard commit.prefixSeed == old.prefixSeed else {
                throw StoreError.invalidCommit(.prefixMismatch)
            }
            guard commit.sealedBuckets.allSatisfy({ $0.bucketStart > old.sealedThroughSequence
                || ($0.bucketStart == old.currentBucket?.bucketStart) }) else {
                throw StoreError.invalidCommit(.cursorRegression)
            }
            if let oldCurrent = old.currentBucket {
                let sealsOldCurrent = commit.sealedBuckets.first?.bucketStart == oldCurrent.bucketStart
                let updatesOldCurrent = commit.currentBucket?.bucketStart == oldCurrent.bucketStart
                guard sealsOldCurrent || updatesOldCurrent else {
                    // A partial bucket is the only replaceable historical object.  A commit may
                    // extend it or seal that exact bucket, but may not skip over it and publish a
                    // later bucket as if the missing prefix had been proven.
                    throw StoreError.invalidCommit(.cursorRegression)
                }
            }
            if let oldCurrent = old.currentBucket,
               let current = commit.currentBucket,
               current.bucketStart == oldCurrent.bucketStart,
               current.rows.count < oldCurrent.rowCount {
                throw StoreError.invalidCommit(.cursorRegression)
            }
        } else {
            guard commit.prefixSeed.sequence % Self.bucketWidth == 0 else {
                throw StoreError.invalidCommit(.prefixMismatch)
            }
        }

        var expectedStart: Int
        if let oldCurrent = old?.currentBucket,
           let first = commit.sealedBuckets.first,
           first.bucketStart == oldCurrent.bucketStart {
            expectedStart = oldCurrent.bucketStart
            guard first.rows.count == Self.bucketWidth else {
                throw StoreError.invalidCommit(.invalidBucket)
            }
            let oldBucket = try readBucketObjectLocked(
                objectID: oldCurrent.objectID,
                namespaceID: old!.namespaceID,
                sourceID: old!.source.sourceID,
                expectedGeneration: oldCurrent.generation)
            guard first.rows.starts(with: oldBucket.rows) else {
                throw StoreError.invalidCommit(.chainMismatch)
            }
        } else {
            expectedStart = (old?.sealedThroughSequence ?? commit.prefixSeed.sequence) + 1
            if expectedStart <= commit.prefixSeed.sequence {
                expectedStart = commit.prefixSeed.sequence + 1
            }
        }
        for bucket in commit.sealedBuckets {
            guard bucket.bucketStart == expectedStart,
                  bucket.rows.count == Self.bucketWidth else {
                throw StoreError.invalidCommit(.invalidBucket)
            }
            try validateBucket(bucket, sealed: true, source: commit.source)
            guard expectedStart <= Int.max - Self.bucketWidth else {
                throw StoreError.invalidCommit(.invalidBucket)
            }
            expectedStart += Self.bucketWidth
        }

        let suppliedBuckets = commit.sealedBuckets + (commit.currentBucket.map { [$0] } ?? [])
        if suppliedBuckets.count > 1 {
            for index in 1..<suppliedBuckets.count {
                guard let previous = suppliedBuckets[index - 1].rows.last,
                      let next = suppliedBuckets[index].rows.first,
                      next.sequence == previous.sequence + 1,
                      next.previousEventID == previous.eventID,
                      next.byteStart == previous.byteEnd,
                      next.prefixDigestBefore == previous.prefixDigestAfter else {
                    throw StoreError.invalidCommit(.chainMismatch)
                }
            }
        }

        // The first newly stored row must join the already proven prefix exactly.  This catches a
        // cross-bucket gap even when the caller supplies a syntactically valid bucket number.
        let firstNewBucket: Bucket?
        if let first = commit.sealedBuckets.first {
            firstNewBucket = first
        } else {
            firstNewBucket = commit.currentBucket
        }
        if let first = firstNewBucket, let row = first.rows.first {
            let expectedPrevious: String?
            let expectedByteStart: Int
            let expectedPrefix: String
            if let oldCurrent = old?.currentBucket,
               first.bucketStart == oldCurrent.bucketStart {
                let oldBucket = try readBucketObjectLocked(
                    objectID: oldCurrent.objectID,
                    namespaceID: old!.namespaceID,
                    sourceID: old!.source.sourceID,
                    expectedGeneration: oldCurrent.generation)
                guard let oldFirst = oldBucket.rows.first else {
                    throw StoreError.invalidCommit(.chainMismatch)
                }
                // This branch is checked by the prefix-of-old-bucket tests below; use the
                // old bucket's first boundary to make the cross-bucket check explicit.
                expectedPrevious = oldFirst.previousEventID
                expectedByteStart = oldFirst.byteStart
                expectedPrefix = oldFirst.prefixDigestBefore
            } else if let old {
                if old.sealedThroughSequence > old.prefixSeed.sequence {
                    let prior = try readBucketObjectLocked(
                        objectID: try readBucketReferenceLocked(
                            bucketStart: Self.bucketStart(for: old.sealedThroughSequence),
                            namespaceID: old.namespaceID),
                        namespaceID: old.namespaceID,
                        sourceID: old.source.sourceID)
                    guard let priorRow = prior.rows.last else {
                        throw StoreError.invalidCommit(.chainMismatch)
                    }
                    expectedPrevious = priorRow.eventID
                    expectedByteStart = priorRow.byteEnd
                    expectedPrefix = priorRow.prefixDigestAfter
                } else {
                    expectedPrevious = old.prefixSeed.previousEventID
                    expectedByteStart = old.prefixSeed.byteCount
                    expectedPrefix = old.prefixSeed.digest
                }
            } else {
                expectedPrevious = commit.prefixSeed.previousEventID
                expectedByteStart = commit.prefixSeed.byteCount
                expectedPrefix = commit.prefixSeed.digest
            }
            guard row.previousEventID == expectedPrevious,
                  row.byteStart == expectedByteStart,
                  row.prefixDigestBefore == expectedPrefix else {
                throw StoreError.invalidCommit(.chainMismatch)
            }
        } else if commit.cursor.sequence == commit.prefixSeed.sequence {
            guard commit.source.prefixByteCount == commit.prefixSeed.byteCount,
                  commit.source.prefixDigest == commit.prefixSeed.digest else {
                throw StoreError.invalidCommit(.prefixMismatch)
            }
        }

        if let current = commit.currentBucket {
            guard !current.rows.isEmpty, current.rows.count < Self.bucketWidth,
                  current.bucketStart == expectedStart,
                  current.bucketStart == Self.bucketStart(for: commit.cursor.sequence),
                  current.rows.last?.sequence == commit.cursor.sequence else {
                throw StoreError.invalidCommit(.invalidBucket)
            }
            try validateBucket(current, sealed: false, source: commit.source)
            if let oldCurrent = old?.currentBucket,
               oldCurrent.bucketStart == current.bucketStart {
                let oldBucket = try readBucketObjectLocked(
                    objectID: oldCurrent.objectID,
                    namespaceID: old!.namespaceID,
                    sourceID: old!.source.sourceID,
                    expectedGeneration: oldCurrent.generation)
                guard current.rows.starts(with: oldBucket.rows) else {
                    throw StoreError.invalidCommit(.chainMismatch)
                }
            }
        } else {
            let expectedLast = commit.sealedBuckets.last.map {
                $0.bucketStart + Self.bucketWidth - 1
            } ?? old?.sealedThroughSequence ?? commit.prefixSeed.sequence
            guard commit.cursor.sequence == expectedLast else {
                throw StoreError.invalidCommit(.invalidBucket)
            }
        }
        try validateAnchors(
            commit.anchors, prefixSeed: commit.prefixSeed,
            cursor: commit.cursor, source: commit.source)
        try validateAnchorsAgainstIndexLocked(
            commit.anchors, suppliedBuckets: suppliedBuckets, old: old)

        let terminalRow = commit.currentBucket?.rows.last ?? commit.sealedBuckets.last?.rows.last
        if let terminalRow {
            guard terminalRow.sequence == commit.cursor.sequence,
                  terminalRow.eventID == commit.cursor.eventID,
                  terminalRow.byteEnd == commit.source.prefixByteCount,
                  terminalRow.prefixDigestAfter == commit.source.prefixDigest else {
                throw StoreError.invalidCommit(.prefixMismatch)
            }
        } else if let old {
            guard commit.cursor == old.cursor,
                  commit.source.prefixByteCount == old.source.prefixByteCount,
                  commit.source.prefixDigest == old.source.prefixDigest else {
                throw StoreError.invalidCommit(.prefixMismatch)
            }
        } else {
            guard commit.cursor.sequence == commit.prefixSeed.sequence,
                  commit.source.prefixByteCount == commit.prefixSeed.byteCount,
                  commit.source.prefixDigest == commit.prefixSeed.digest else {
                throw StoreError.invalidCommit(.prefixMismatch)
            }
        }
        try validatePages(
            commit.recentPages, cursor: commit.cursor,
            suppliedBuckets: suppliedBuckets, old: old)
    }

    private func validateSource(_ source: SourceFingerprint) throws {
        guard source.journal == journal,
              validIdentity(source.sourceID),
              validDigest(source.sourceGeneration),
              validDigest(source.fingerprint),
              validDigest(source.prefixDigest),
              source.sourceByteCount >= 0,
              source.prefixByteCount >= 0,
              source.prefixByteCount <= source.sourceByteCount,
              source.sourceByteCount <= limits.maximumSourceBytes else {
            throw StoreError.invalidCommit(.wrongSource)
        }
    }

    /// Validate only the bounded root envelope.  The store cannot prove a map's object graph
    /// without owning its directory, and deliberately does not pretend that an object ID proves
    /// semantic state.  The map/integration layer must perform `PersistentProjectionRadixMap
    /// .validate(root:)` under its own lock before handing the descriptor to this commit.
    private func validateExactStateRoots(
        _ roots: [ExactStateRootDescriptor], namespaceID: String,
        source: SourceFingerprint,
        prior: [ExactStateRootDescriptor]? = nil
    ) throws {
        guard roots.count <= limits.maximumExactStateRoots else {
            throw StoreError.invalidCommit(.oversize)
        }
        guard validIdentity(namespaceID) else {
            throw StoreError.invalidCommit(.invalidExactStateRoot)
        }
        guard roots == Self.sortedExactStateRoots(roots) else {
            throw StoreError.invalidCommit(.invalidExactStateRoot)
        }
        var mapKinds = Set<String>()
        for descriptor in roots {
            guard descriptor.schemaVersion == PersistentProjectionRadixMap.schemaVersion else {
                throw StoreError.invalidCommit(.schemaMismatch)
            }
            guard validIdentity(descriptor.namespaceID), descriptor.namespaceID == namespaceID else {
                throw StoreError.invalidCommit(.invalidExactStateRoot)
            }
            guard descriptor.journal == journal, descriptor.journal == source.journal else {
                throw StoreError.invalidCommit(.wrongJournal)
            }
            guard validExactDigest(descriptor.sourceGeneration),
                  descriptor.sourceGeneration == source.sourceGeneration else {
                throw StoreError.invalidCommit(.wrongSource)
            }
            guard validIdentity(descriptor.mapKind), mapKinds.insert(descriptor.mapKind).inserted else {
                throw StoreError.invalidCommit(.invalidIdentity)
            }
            guard validExactDigest(descriptor.objectID) else {
                throw StoreError.invalidCommit(.invalidDigest)
            }
            guard descriptor.entryCount > 0,
                  descriptor.entryCount <= limits.maximumExactStateRootEntries else {
                throw StoreError.invalidCommit(.invalidExactStateRoot)
            }
        }
        if let prior, !prior.isEmpty {
            // Once exact maps participate in a publication, their semantic slots are stable for
            // the lifetime of that projection namespace.  A changed map kind would otherwise
            // make an old root look like the replacement for a different reducer map.
            // Additions/removals are represented by a future explicit migration, not by silently
            // relabeling a root in the same bounded store.
            //
            let priorKinds = prior.map(\.mapKind)
            let currentKinds = roots.map(\.mapKind)
            guard !roots.isEmpty, priorKinds == currentKinds else {
                throw StoreError.invalidCommit(.invalidExactStateRoot)
            }
        }
    }

    private func validateExactStateCheckpoint(
        _ checkpoint: ExactStateCheckpoint,
        namespaceID: String,
        source: SourceFingerprint,
        cursor: JournalCursor,
        prior: ExactStateCheckpoint? = nil
    ) throws {
        guard checkpoint.schemaVersion == ExactStateCheckpoint.schemaVersion else {
            throw StoreError.invalidCommit(.schemaMismatch)
        }
        guard validIdentity(checkpoint.namespaceID), checkpoint.namespaceID == namespaceID else {
            throw StoreError.invalidCommit(.invalidExactStateRoot)
        }
        guard checkpoint.journal == journal, checkpoint.journal == source.journal,
              checkpoint.cursor.journal == journal else {
            throw StoreError.invalidCommit(.wrongJournal)
        }
        guard checkpoint.sourceGeneration == source.sourceGeneration,
              validExactDigest(checkpoint.sourceGeneration) else {
            throw StoreError.invalidCommit(.wrongSource)
        }
        guard checkpoint.cursor == cursor else {
            throw StoreError.invalidCommit(.cursorRegression)
        }
        guard
              checkpoint.prefixByteCount == source.prefixByteCount,
              checkpoint.prefixByteCount >= 0,
              checkpoint.prefixByteCount <= source.sourceByteCount,
              checkpoint.prefixDigest == source.prefixDigest,
              validExactDigest(checkpoint.prefixDigest) else {
            throw StoreError.invalidCommit(.prefixMismatch)
        }
        guard !checkpoint.roots.isEmpty else {
            throw StoreError.invalidCommit(.invalidExactStateCheckpoint)
        }
        try validateExactStateRoots(
            checkpoint.roots, namespaceID: namespaceID, source: source,
            prior: prior?.roots)
    }

    private func validateExactStateCheckpointDescriptor(
        _ descriptor: ExactStateCheckpointDescriptor
    ) throws {
        guard descriptor.schemaVersion == ExactStateCheckpoint.schemaVersion,
              validExactDigest(descriptor.objectID),
              descriptor.digest == descriptor.objectID,
              descriptor.byteCount > 0,
              descriptor.byteCount <= limits.maximumExactStateCheckpointBytes,
              descriptor.byteCount <= limits.maximumObjectBytes else {
            throw StoreError.cacheUnavailable(.invalidExactStateCheckpoint)
        }
    }

    private func validateExactStateRootPublicationLocked(
        _ checkpoint: ExactStateCheckpoint?,
        prior: ExactStateCheckpoint?,
        validator: ExactStateCheckpointValidator?
    ) throws {
        guard let checkpoint else { return }
        guard let validator else {
            throw StoreError.invalidCommit(.invalidExactStateCheckpoint)
        }
        do {
            try validator(checkpoint, prior)
        } catch StoreError.cacheUnavailable(.reentrantAccess) {
            throw StoreError.cacheUnavailable(.reentrantAccess)
        } catch {
            // Do not leak map paths or map-specific diagnostics through the projection-store
            // contract. The failed proof is deliberately a bounded, typed rejection before any
            // payload or HEAD publication.
            throw StoreError.invalidCommit(.invalidExactStateCheckpoint)
        }
    }

    private func validateCursor(_ cursor: JournalCursor) throws {
        guard cursor.journal == journal,
              cursor.sequence >= 0,
              cursor.sequence < Int.max,
              (cursor.sequence == 0 ? cursor.eventID == nil : cursor.eventID.map(validIdentity) == true)
        else { throw StoreError.invalidCommit(.cursorRegression) }
    }

    private func validatePrefixSeed(_ seed: PrefixSeed, source: SourceFingerprint) throws {
        guard seed.byteCount >= 0,
              seed.byteCount <= source.prefixByteCount,
              seed.sequence >= 0,
              seed.sequence % Self.bucketWidth == 0,
              seed.sequence < Int.max,
              validDigest(seed.digest),
              (seed.sequence == 0 ? seed.previousEventID == nil
                : seed.previousEventID.map(validIdentity) == true) else {
            throw StoreError.invalidCommit(.prefixMismatch)
        }
        if seed.sequence == 0,
           seed.digest != Self.canonicalPrefixSeed(for: journal) {
            throw StoreError.invalidCommit(.prefixMismatch)
        }
    }

    private func validateAnchors(
        _ anchors: [AnchorRecord], prefixSeed: PrefixSeed,
        cursor: JournalCursor, source: SourceFingerprint
    ) throws {
        var previousSequence = prefixSeed.sequence
        var previousEventID = prefixSeed.previousEventID
        var previousByteEnd = prefixSeed.byteCount
        var previousPrefixDigest = prefixSeed.digest
        var seen = Set<String>()
        for anchor in anchors {
            guard anchor.sequence > prefixSeed.sequence,
                  anchor.sequence <= cursor.sequence,
                  anchor.sequence > previousSequence,
                  validIdentity(anchor.eventID),
                  anchor.previousEventID.map(validIdentity) ?? true,
                  validOffsets(anchor.byteStart, anchor.byteEnd),
                  validDigest(anchor.prefixDigestBefore),
                  validDigest(anchor.prefixDigestAfter),
                  validDigest(anchor.lineDigest),
                  anchor.prefixDigestAfter == Self.advancePrefixDigest(
                    anchor.prefixDigestBefore, lineDigest: anchor.lineDigest),
                  anchor.byteStart >= previousByteEnd,
                  anchor.byteEnd <= source.prefixByteCount,
                  seen.insert(anchor.eventID).inserted else {
                throw StoreError.invalidCommit(.invalidBucket)
            }
            if anchor.sequence == previousSequence + 1 {
                guard anchor.previousEventID == previousEventID,
                      anchor.byteStart == previousByteEnd,
                      anchor.prefixDigestBefore == previousPrefixDigest else {
                    throw StoreError.invalidCommit(.chainMismatch)
                }
            }
            previousSequence = anchor.sequence
            previousEventID = anchor.eventID
            previousByteEnd = anchor.byteEnd
            previousPrefixDigest = anchor.prefixDigestAfter
        }
        if let terminal = anchors.last, terminal.sequence == cursor.sequence {
            guard terminal.eventID == cursor.eventID,
                  terminal.byteEnd == source.prefixByteCount,
                  terminal.prefixDigestAfter == source.prefixDigest else {
                throw StoreError.invalidCommit(.prefixMismatch)
            }
        }
    }

    private func validateAnchorsAgainstIndexLocked(
        _ anchors: [AnchorRecord], suppliedBuckets: [Bucket], old: Snapshot?
    ) throws {
        guard !anchors.isEmpty else { return }
        var suppliedRows: [Int: BucketRow] = [:]
        for bucket in suppliedBuckets {
            for row in bucket.rows { suppliedRows[row.sequence] = row }
        }
        // Anchors already admitted into the checksummed prior HEAD were proven against the exact
        // indexed row when first committed. Retaining them in a metadata-only generation must not
        // turn a bounded commit into a historical bucket walk under the exclusive lock.
        let previouslyProven = Set(old?.anchors ?? [])
        var loadedBuckets: [Int: Bucket] = [:]
        for anchor in anchors {
            if previouslyProven.contains(anchor) { continue }
            let row: BucketRow?
            if let supplied = suppliedRows[anchor.sequence] {
                row = supplied
            } else if let old, anchor.sequence <= old.cursor.sequence {
                let start = Self.bucketStart(for: anchor.sequence)
                let bucket: Bucket
                if let loaded = loadedBuckets[start] {
                    bucket = loaded
                } else {
                    bucket = try readIndexedBucketLocked(startingAt: start, snapshot: old)
                    loadedBuckets[start] = bucket
                }
                row = bucket.rows.first(where: { $0.sequence == anchor.sequence })
            } else {
                row = nil
            }
            guard let row, anchorMatchesRow(anchor, row) else {
                throw StoreError.invalidCommit(.invalidBucket)
            }
        }
    }

    private func readIndexedBucketLocked(
        startingAt start: Int, snapshot: Snapshot
    ) throws -> Bucket {
        if let current = snapshot.currentBucket, current.bucketStart == start {
            return try readBucketObjectLocked(
                objectID: current.objectID, namespaceID: snapshot.namespaceID,
                sourceID: snapshot.source.sourceID,
                expectedByteCount: current.byteCount,
                expectedGeneration: current.generation)
        }
        guard start <= snapshot.sealedThroughSequence else {
            throw StoreError.cacheUnavailable(.notIndexed)
        }
        let objectID = try readBucketReferenceLocked(
            bucketStart: start, namespaceID: snapshot.namespaceID)
        return try readBucketObjectLocked(
            objectID: objectID, namespaceID: snapshot.namespaceID,
            sourceID: snapshot.source.sourceID)
    }

    private func anchorMatchesRow(_ anchor: AnchorRecord, _ row: BucketRow) -> Bool {
        anchor.sequence == row.sequence
            && anchor.eventID == row.eventID
            && anchor.previousEventID == row.previousEventID
            && anchor.byteStart == row.byteStart
            && anchor.byteEnd == row.byteEnd
            && anchor.prefixDigestBefore == row.prefixDigestBefore
            && anchor.prefixDigestAfter == row.prefixDigestAfter
            && anchor.lineDigest == row.lineDigest
    }

    private func validatePendingAcknowledgements(
        _ acknowledgements: [PendingAcknowledgement], workCursor: JournalCursor
    ) throws {
        guard acknowledgements.count <= limits.maximumPendingAcknowledgements else {
            throw StoreError.invalidCommit(.oversize)
        }
        var seen = Set<String>()
        for acknowledgement in acknowledgements {
            let request = acknowledgement.request
            let identity = "\(request.client.clientID.utf8.count):\(request.client.clientID)"
                + "/\(request.commandID.utf8.count):\(request.commandID)"
            guard validIdentity(request.client.clientID),
                  validIdentity(request.commandID),
                  validIdentity(request.attachment.attachmentID),
                  request.target.journal == journal,
                  request.cursor.journal == journal,
                  request.cursor.sequence >= 0,
                  request.cursor.sequence <= workCursor.sequence,
                  request.cursor.sequence < Int.max,
                  (request.cursor.sequence == 0
                    ? request.cursor.eventID == nil
                    : request.cursor.eventID.map(validIdentity) == true),
                  request.causalControlCursor.sequence >= 0,
                  request.causalControlCursor.sequence < Int.max,
                  (request.causalControlCursor.sequence == 0
                    ? request.causalControlCursor.eventID == nil
                    : request.causalControlCursor.eventID.map(validIdentity) == true),
                  isWorkJournal(request.journal, for: request.work),
                  acknowledgementTargetMatchesRequest(request),
                  isControlJournal(request.causalControlCursor.journal, for: request.work),
                  seen.insert(identity).inserted else {
                throw StoreError.invalidCommit(.invalidIdentity)
            }
        }
    }

    private func acknowledgementTargetMatchesRequest(
        _ request: WorkServiceAcknowledgeReadRequest
    ) -> Bool {
        switch request.target {
        case .work(let targetJournal):
            return targetJournal == request.journal
                && isWorkJournal(targetJournal, for: request.work)
        case .session(let session, let targetJournal):
            guard targetJournal.authority.authorityID == request.work.workHostID else {
                return false
            }
            if case .session(let owner) = targetJournal.owner {
                return owner == session
            }
            return false
        }
    }

    private func isWorkJournal(_ candidate: JournalRef, for work: WorkRef) -> Bool {
        guard candidate.authority.authorityID == work.workHostID else { return false }
        if case .work(let owner) = candidate.owner { return owner == work }
        return false
    }

    private func isControlJournal(_ candidate: JournalRef, for work: WorkRef) -> Bool {
        guard candidate.authority.authorityID == work.workHostID else { return false }
        if case .workHost(let owner) = candidate.owner {
            return owner == WorkHostRef(work.workHostID)
        }
        return false
    }

    private func validatePages(
        _ pages: [RecentEventPage],
        cursor: JournalCursor,
        suppliedBuckets: [Bucket],
        old: Snapshot?
    ) throws {
        guard pages.count <= limits.maximumRecentPages else {
            throw StoreError.invalidCommit(.oversize)
        }
        var previousPageEndSequence: Int?
        var previousPageEndEventID: String?
        var pageIDs = Set<String>()
        var suppliedRows: [Int: BucketRow] = [:]
        for bucket in suppliedBuckets {
            for row in bucket.rows { suppliedRows[row.sequence] = row }
        }
        var loadedBuckets: [Int: Bucket] = [:]
        for page in pages {
            guard validIdentity(page.pageID), pageIDs.insert(page.pageID).inserted,
                  !page.events.isEmpty,
                  page.events.count <= Self.bucketWidth,
                  page.events.first?.sequence ?? 0 > (old?.prefixSeed.sequence ?? 0),
                  page.events.last?.sequence ?? 0 <= cursor.sequence else {
                throw StoreError.invalidCommit(.invalidPage)
            }
            if let previousPageEndSequence {
                guard previousPageEndSequence < Int.max,
                      page.events.first!.sequence == previousPageEndSequence + 1,
                      page.events.first!.previousEventID == previousPageEndEventID else {
                    throw StoreError.invalidCommit(.chainMismatch)
                }
            }
            guard page.events.count <= limits.maximumRecentPageEvents else {
                throw StoreError.invalidCommit(.oversize)
            }
            var expected = page.events.first!.sequence
            var previous = previousPageEndEventID
            for event in page.events {
                let row: BucketRow?
                if let supplied = suppliedRows[event.sequence] {
                    row = supplied
                } else if let old, event.sequence <= old.cursor.sequence {
                    let bucketStart = Self.bucketStart(for: event.sequence)
                    let bucket: Bucket
                    if let cached = loadedBuckets[bucketStart] {
                        bucket = cached
                    } else if let current = old.currentBucket,
                              current.bucketStart == bucketStart {
                        bucket = try readBucketObjectLocked(
                            objectID: current.objectID, namespaceID: old.namespaceID,
                            sourceID: old.source.sourceID,
                            expectedByteCount: current.byteCount,
                            expectedGeneration: current.generation)
                        loadedBuckets[bucketStart] = bucket
                    } else {
                        let objectID = try readBucketReferenceLocked(
                            bucketStart: bucketStart, namespaceID: old.namespaceID)
                        bucket = try readBucketObjectLocked(
                            objectID: objectID, namespaceID: old.namespaceID,
                            sourceID: old.source.sourceID)
                        loadedBuckets[bucketStart] = bucket
                    }
                    row = bucket.rows.first(where: { $0.sequence == event.sequence })
                } else {
                    row = nil
                }
                guard event.journal == journal,
                      event.sequence == expected,
                      validIdentity(event.eventID),
                      previous == nil || event.previousEventID == previous,
                      let row,
                      row.eventID == event.eventID,
                      row.previousEventID == event.previousEventID,
                      row.lineDigest == (try Self.canonicalEventLineDigest(event)) else {
                    throw StoreError.invalidCommit(.chainMismatch)
                }
                previous = event.eventID
                guard expected < Int.max else {
                    throw StoreError.invalidCommit(.chainMismatch)
                }
                expected += 1
            }
            previousPageEndSequence = page.events.last!.sequence
            previousPageEndEventID = page.events.last!.eventID
            let encoded = try Self.canonicalJSON(page)
            guard encoded.count <= limits.maximumRecentPageBytes,
                  encoded.count <= limits.maximumObjectBytes else {
                throw StoreError.invalidCommit(.oversize)
            }
        }
    }

    private func validateBucket(_ bucket: Bucket, sealed: Bool, source: SourceFingerprint) throws {
        guard bucket.bucketStart > 0,
              bucket.bucketStart == Self.bucketStart(for: bucket.bucketStart),
              bucket.bucketStart <= Int.max - Self.bucketWidth + 1,
              !bucket.rows.isEmpty,
              bucket.rows.count <= Self.bucketWidth,
              sealed ? bucket.rows.count == Self.bucketWidth : bucket.rows.count < Self.bucketWidth
        else { throw StoreError.invalidCommit(.invalidBucket) }
        var expected = bucket.bucketStart
        var previousEventID: String?
        var previousEnd: Int?
        var previousPrefixDigest: String?
        var seen = Set<String>()
        for row in bucket.rows {
            guard row.sequence == expected,
                  validIdentity(row.eventID),
                  row.previousEventID.map(validIdentity) ?? true,
                  validOffsets(row.byteStart, row.byteEnd),
                  previousEnd == nil || row.byteStart == previousEnd,
                  previousPrefixDigest == nil || row.prefixDigestBefore == previousPrefixDigest,
                  validDigest(row.prefixDigestBefore),
                  validDigest(row.prefixDigestAfter),
                  validDigest(row.lineDigest),
                  row.prefixDigestAfter == Self.advancePrefixDigest(
                    row.prefixDigestBefore, lineDigest: row.lineDigest),
                  seen.insert(row.eventID).inserted else {
                throw StoreError.invalidCommit(.invalidBucket)
            }
            if let previousEventID {
                guard row.previousEventID == previousEventID else {
                    throw StoreError.invalidCommit(.chainMismatch)
                }
            }
            previousEventID = row.eventID
            previousEnd = row.byteEnd
            previousPrefixDigest = row.prefixDigestAfter
            guard expected < Int.max else {
                throw StoreError.invalidCommit(.invalidBucket)
            }
            expected += 1
        }
        guard let last = bucket.rows.last,
              last.sequence < Int.max,
              last.byteEnd <= source.sourceByteCount else {
            throw StoreError.invalidCommit(.invalidOffsets)
        }
    }

    // MARK: Encoded objects

    private struct HeadEnvelope: Codable {
        let schemaVersion: Int
        let bodyDigest: String
        let body: Snapshot
    }

    private struct BucketObjectBody: Codable {
        let schemaVersion: Int
        let namespaceID: String
        let journal: JournalRef
        let sourceID: String
        let generation: Int
        let bucket: Bucket
    }

    private struct BucketEnvelope: Codable {
        let schemaVersion: Int
        let objectID: String
        let bodyDigest: String
        let body: BucketObjectBody
    }

    private struct ReferenceBody: Codable {
        let schemaVersion: Int
        let namespaceID: String
        let journal: JournalRef
        let bucketStart: Int
        let objectID: String
    }

    private struct ReferenceEnvelope: Codable {
        let schemaVersion: Int
        let bodyDigest: String
        let body: ReferenceBody
    }

    private struct PageObjectBody: Codable {
        let schemaVersion: Int
        let namespaceID: String
        let journal: JournalRef
        let sourceID: String
        let page: RecentEventPage
    }

    private struct PageEnvelope: Codable {
        let schemaVersion: Int
        let objectID: String
        let bodyDigest: String
        let body: PageObjectBody
    }

    private struct ReducerObjectBody: Codable {
        let schemaVersion: Int
        let namespaceID: String
        let journal: JournalRef
        let sourceID: String
        let mediaType: String
        let reducerSchemaVersion: Int
        let bytes: Data
    }

    private struct ReducerEnvelope: Codable {
        let schemaVersion: Int
        let objectID: String
        let bodyDigest: String
        let body: ReducerObjectBody
    }

    fileprivate struct PersistedExactStateCheckpoint: Codable {
        let schemaVersion: Int
        let namespaceID: String
        let journal: JournalRef
        let sourceGeneration: String
        let cursor: JournalCursor
        let prefixByteCount: Int
        let prefixDigest: String
        let roots: [ExactStateRootDescriptor]

        init(_ checkpoint: ExactStateCheckpoint) {
            schemaVersion = checkpoint.schemaVersion
            namespaceID = checkpoint.namespaceID
            journal = checkpoint.journal
            sourceGeneration = checkpoint.sourceGeneration
            cursor = checkpoint.cursor
            prefixByteCount = checkpoint.prefixByteCount
            prefixDigest = checkpoint.prefixDigest
            roots = checkpoint.roots
        }
    }

    private struct ExactStateCheckpointEnvelope: Codable {
        let schemaVersion: Int
        let objectID: String
        let bodyDigest: String
        let body: PersistedExactStateCheckpoint
    }

    /// Permanent, direct-addressed evidence that an exact-map namespace was used by this store.
    /// A failed first publication may retry only the identical normalized commit. `clear()`
    /// retires the namespace before removing HEAD, so retained sealed references can never be
    /// mistaken for a new projection generation.
    private struct ExactNamespaceMarker: Codable, Equatable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let namespaceID: String
        let journal: JournalRef
        let initialCommitDigest: String
        let retired: Bool

        init(
            namespaceID: String, journal: JournalRef,
            initialCommitDigest: String, retired: Bool
        ) {
            self.schemaVersion = Self.schemaVersion
            self.namespaceID = namespaceID
            self.journal = journal
            self.initialCommitDigest = initialCommitDigest
            self.retired = retired
        }
    }

    /// One fixed, bounded pointer lets `clear()` retire a reservation even when an attempted first
    /// exact publication never produced HEAD. Permanent per-namespace markers still prevent an
    /// older namespace from becoming reusable after this pointer advances.
    private struct ExactNamespacePointer: Codable, Equatable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let namespaceID: String
        let journal: JournalRef
        let initialCommitDigest: String

        init(marker: ExactNamespaceMarker) {
            self.schemaVersion = Self.schemaVersion
            self.namespaceID = marker.namespaceID
            self.journal = marker.journal
            self.initialCommitDigest = marker.initialCommitDigest
        }
    }

    private func writeHeadLocked(_ snapshot: Snapshot) throws {
        let bodyData = try Self.canonicalJSON(snapshot)
        let bodyDigest = digest(bodyData)
        let envelope = HeadEnvelope(
            schemaVersion: Self.schemaVersion, bodyDigest: bodyDigest, body: snapshot)
        let data = try Self.canonicalJSON(envelope)
        guard data.count <= limits.maximumHeadBytes else {
            throw StoreError.invalidCommit(.oversize)
        }
        try writeAtomicallyLocked(data, to: headURL, operation: .publishHead)
    }

    private func readHeadLocked(proving observedSource: SourceFingerprint) throws -> Snapshot {
        guard let snapshot = try readHeadIfPresentLocked() else {
            throw StoreError.rebuildRequired(.missingHead)
        }
        try validateSnapshot(snapshot)
        try validateObservedSource(observedSource, against: snapshot.source)
        try validateProjectedTerminalLocked(snapshot)
        _ = try readExactStateCheckpointDescriptorLocked(snapshot)
        return snapshot
    }

    /// Validate one bounded terminal bucket so a checksummed `HEAD` cannot claim a cursor or
    /// prefix that is not represented by the directly addressable index. Older sealed history is
    /// verified lazily when its bucket is requested.
    @discardableResult
    private func validateProjectedTerminalLocked(_ snapshot: Snapshot) throws -> BucketRow? {
        if let current = snapshot.currentBucket {
            let bucket = try readBucketObjectLocked(
                objectID: current.objectID, namespaceID: snapshot.namespaceID,
                sourceID: snapshot.source.sourceID,
                expectedByteCount: current.byteCount,
                expectedGeneration: current.generation)
            guard bucket.rows.count == current.rowCount,
                  bucket.rows.last?.sequence == current.lastSequence,
                  bucket.rows.last?.sequence == snapshot.cursor.sequence,
                  bucket.rows.last?.eventID == snapshot.cursor.eventID,
                  bucket.rows.last?.byteEnd == snapshot.source.prefixByteCount,
                  bucket.rows.last?.prefixDigestAfter == snapshot.source.prefixDigest else {
                throw StoreError.cacheUnavailable(.invalidBucket)
            }
            return bucket.rows.last
        } else if snapshot.cursor.sequence > snapshot.prefixSeed.sequence {
            let bucketStart = Self.bucketStart(for: snapshot.cursor.sequence)
            let objectID = try readBucketReferenceLocked(
                bucketStart: bucketStart, namespaceID: snapshot.namespaceID)
            let bucket = try readBucketObjectLocked(
                objectID: objectID, namespaceID: snapshot.namespaceID,
                sourceID: snapshot.source.sourceID)
            guard bucket.bucketStart == bucketStart,
                  bucket.rows.count == Self.bucketWidth,
                  bucket.rows.last?.sequence == snapshot.cursor.sequence,
                  bucket.rows.last?.eventID == snapshot.cursor.eventID,
                  bucket.rows.last?.byteEnd == snapshot.source.prefixByteCount,
                  bucket.rows.last?.prefixDigestAfter == snapshot.source.prefixDigest else {
                throw StoreError.cacheUnavailable(.invalidBucket)
            }
            return bucket.rows.last
        } else {
            guard snapshot.source.prefixByteCount == snapshot.prefixSeed.byteCount,
                  snapshot.source.prefixDigest == snapshot.prefixSeed.digest else {
                throw StoreError.cacheUnavailable(.prefixMismatch)
            }
            return nil
        }
    }

    private func readHeadIfPresentLocked() throws -> Snapshot? {
        notify(.readHead)
        guard let data = try readPrivateFileLocked(
            headURL, maximumBytes: limits.maximumHeadBytes, missingIsNil: true) else {
            return nil
        }
        do {
            let envelope = try JSONDecoder().decode(HeadEnvelope.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion,
                  envelope.body.schemaVersion == Self.schemaVersion,
                  validDigest(envelope.bodyDigest),
                  digest(try Self.canonicalJSON(envelope.body)) == envelope.bodyDigest else {
                throw StoreError.cacheUnavailable(.checksumMismatch)
            }
            try validateSnapshot(envelope.body)
            return envelope.body
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.cacheUnavailable(.malformedHead)
        }
    }

    private func validateSnapshot(_ snapshot: Snapshot) throws {
        guard snapshot.schemaVersion == Self.schemaVersion,
              validIdentity(snapshot.namespaceID),
              snapshot.journal == journal,
              snapshot.source.journal == journal,
              snapshot.cursor.journal == journal,
              snapshot.generation > 0,
              snapshot.generation < Int.max,
              snapshot.nextSequence > 0,
              snapshot.cursor.sequence < Int.max,
              snapshot.nextSequence == snapshot.cursor.sequence + 1,
              snapshot.nextPreviousEventID == snapshot.cursor.eventID,
              snapshot.sealedThroughSequence >= snapshot.prefixSeed.sequence,
              snapshot.sealedThroughSequence % Self.bucketWidth == 0,
              snapshot.sealedBucketCount == (snapshot.sealedThroughSequence
                - snapshot.prefixSeed.sequence) / Self.bucketWidth,
              snapshot.anchors.count <= limits.maximumAnchorRecords,
              snapshot.recentPages.count <= limits.maximumRecentPages,
              snapshot.pendingAcknowledgements.count <= limits.maximumPendingAcknowledgements else {
            throw StoreError.cacheUnavailable(.malformedHead)
        }
        try validateSource(snapshot.source)
        try validateCursor(snapshot.cursor)
        try validatePrefixSeed(snapshot.prefixSeed, source: snapshot.source)
        try validateAnchors(
            snapshot.anchors, prefixSeed: snapshot.prefixSeed,
            cursor: snapshot.cursor, source: snapshot.source)
        try validatePendingAcknowledgements(
            snapshot.pendingAcknowledgements, workCursor: snapshot.cursor)
        if let checkpoint = snapshot.exactStateCheckpoint {
            try validateExactStateCheckpointDescriptor(checkpoint)
        }
        if let current = snapshot.currentBucket {
            guard current.bucketStart == Self.bucketStart(for: snapshot.cursor.sequence),
                  current.rowCount > 0, current.rowCount < Self.bucketWidth,
                  current.lastSequence == snapshot.cursor.sequence,
                  validDigest(current.objectID), current.byteCount > 0,
                  current.byteCount <= limits.maximumObjectBytes,
                  current.generation == snapshot.generation else {
                throw StoreError.cacheUnavailable(.malformedHead)
            }
        } else {
            guard snapshot.cursor.sequence == snapshot.sealedThroughSequence else {
                throw StoreError.cacheUnavailable(.malformedHead)
            }
        }
        var pageIDs = Set<String>()
        var previousPageEnd: Int?
        for page in snapshot.recentPages {
            guard validIdentity(page.pageID), pageIDs.insert(page.pageID).inserted,
                  page.sequenceStart > 0, page.sequenceEnd >= page.sequenceStart,
                  page.sequenceEnd <= snapshot.cursor.sequence,
                  page.eventCount > 0, page.eventCount <= limits.maximumRecentPageEvents,
                  validDigest(page.objectID), validDigest(page.digest),
                  page.byteCount > 0, page.byteCount <= limits.maximumRecentPageBytes else {
                throw StoreError.cacheUnavailable(.malformedHead)
            }
            if let previousPageEnd {
                guard previousPageEnd < Int.max,
                      page.sequenceStart == previousPageEnd + 1 else {
                    throw StoreError.cacheUnavailable(.malformedHead)
                }
            }
            previousPageEnd = page.sequenceEnd
        }
        let recentPagesCoverRetainedPrefix: Bool
        if snapshot.cursor.sequence == snapshot.prefixSeed.sequence {
            recentPagesCoverRetainedPrefix = snapshot.recentPages.isEmpty
        } else {
            recentPagesCoverRetainedPrefix =
                snapshot.recentPages.first?.sequenceStart == snapshot.prefixSeed.sequence + 1
                && snapshot.recentPages.last?.sequenceEnd == snapshot.cursor.sequence
        }
        guard snapshot.recentEventsOmitted == !recentPagesCoverRetainedPrefix else {
            throw StoreError.cacheUnavailable(.malformedHead)
        }
        if let reducer = snapshot.reducerHead {
            guard validMediaType(reducer.mediaType), reducer.schemaVersion > 0,
                  validDigest(reducer.objectID), validDigest(reducer.digest),
                  reducer.byteCount >= 0,
                  reducer.byteCount <= limits.maximumReducerHeadBytes else {
                throw StoreError.cacheUnavailable(.invalidReducerHead)
            }
        }
    }

    private func validateObservedSource(
        _ observed: SourceFingerprint,
        against stored: SourceFingerprint
    ) throws {
        guard observed.journal == journal,
              validIdentity(observed.sourceID),
              validDigest(observed.sourceGeneration),
              validDigest(observed.fingerprint),
              validDigest(observed.prefixDigest),
              observed.sourceByteCount >= 0,
              observed.sourceByteCount <= limits.maximumSourceBytes,
              observed.prefixByteCount >= 0,
              observed.prefixByteCount <= observed.sourceByteCount,
              observed.sourceID == stored.sourceID,
              observed.sourceGeneration == stored.sourceGeneration else {
            throw StoreError.rebuildRequired(.wrongSource)
        }
        guard observed.sourceByteCount >= stored.prefixByteCount,
              observed.prefixByteCount == stored.prefixByteCount,
              observed.prefixDigest == stored.prefixDigest else {
            throw StoreError.rebuildRequired(.prefixMismatch)
        }
        if observed.sourceByteCount == stored.sourceByteCount,
           observed.fingerprint != stored.fingerprint {
            throw StoreError.rebuildRequired(.wrongSource)
        }
    }

    private func writeBucketObjectLocked(
        _ bucket: Bucket, namespaceID: String, source: SourceFingerprint,
        generation: Int, sealed: Bool
    ) throws -> BucketDescriptor {
        let body = BucketObjectBody(
            schemaVersion: Self.schemaVersion, namespaceID: namespaceID,
            journal: journal, sourceID: source.sourceID,
            generation: sealed ? 0 : generation, bucket: bucket)
        let bodyData = try Self.canonicalJSON(body)
        let objectID = digest(bodyData)
        let envelope = BucketEnvelope(
            schemaVersion: Self.schemaVersion, objectID: objectID,
            bodyDigest: objectID, body: body)
        let data = try Self.canonicalJSON(envelope)
        guard data.count <= limits.maximumObjectBytes else {
            throw StoreError.invalidCommit(.oversize)
        }
        try writeContentAddressedLocked(data, objectID: objectID, suffix: "bucket")
        guard let last = bucket.rows.last else {
            throw StoreError.invalidCommit(.invalidBucket)
        }
        return BucketDescriptor(
            bucketStart: bucket.bucketStart, rowCount: bucket.rows.count,
            lastSequence: last.sequence, objectID: objectID, byteCount: data.count,
            generation: sealed ? 0 : generation)
    }

    private func readBucketObjectLocked(
        objectID: String, namespaceID: String, sourceID: String,
        expectedByteCount: Int? = nil, expectedGeneration: Int? = nil
    ) throws -> Bucket {
        notify(.readPayload)
        let data = try readObjectLocked(objectID: objectID, suffix: "bucket")
        if let expectedByteCount, data.count != expectedByteCount {
            throw StoreError.cacheUnavailable(.checksumMismatch)
        }
        do {
            let envelope = try JSONDecoder().decode(BucketEnvelope.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion,
                  envelope.objectID == objectID,
                  envelope.bodyDigest == objectID,
                  digest(try Self.canonicalJSON(envelope.body)) == objectID,
                  envelope.body.schemaVersion == Self.schemaVersion,
                  envelope.body.namespaceID == namespaceID,
                  envelope.body.journal == journal,
                  envelope.body.sourceID == sourceID,
                  expectedGeneration == nil
                    ? envelope.body.generation == 0
                    : envelope.body.generation == expectedGeneration else {
                throw StoreError.cacheUnavailable(.checksumMismatch)
            }
            try validateBucket(
                envelope.body.bucket,
                sealed: envelope.body.bucket.rows.count == Self.bucketWidth,
                source: SourceFingerprint(
                    journal: journal, sourceID: sourceID,
                    sourceGeneration: String(repeating: "0", count: 64),
                    fingerprint: String(repeating: "0", count: 64),
                    sourceByteCount: limits.maximumSourceBytes,
                    prefixByteCount: 0,
                    prefixDigest: String(repeating: "0", count: 64)))
            return envelope.body.bucket
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.cacheUnavailable(.malformedPayload)
        }
    }

    private func writeBucketReferenceLocked(
        bucketStart: Int, namespaceID: String, objectID: String, generation: Int
    ) throws {
        guard validDigest(objectID), bucketStart > 0,
              bucketStart == Self.bucketStart(for: bucketStart) else {
            throw StoreError.invalidCommit(.invalidBucket)
        }
        let body = ReferenceBody(
            schemaVersion: Self.schemaVersion, namespaceID: namespaceID,
            journal: journal, bucketStart: bucketStart, objectID: objectID)
        let bodyData = try Self.canonicalJSON(body)
        let envelope = ReferenceEnvelope(
            schemaVersion: Self.schemaVersion, bodyDigest: digest(bodyData), body: body)
        let data = try Self.canonicalJSON(envelope)
        guard data.count <= limits.maximumObjectBytes else {
            throw StoreError.invalidCommit(.oversize)
        }
        let url = referenceURL(namespaceID: namespaceID, bucketStart: bucketStart)
        notify(.writeReference)
        do {
            try writeNewLocked(data, to: url, operation: .writeReference)
        } catch StoreError.cacheUnavailable(.ioFailure) {
            // A retry after a crash may have already published the exact immutable reference.
            let existing = try readPrivateFileLocked(
                url, maximumBytes: limits.maximumObjectBytes, missingIsNil: false)
            guard let existing,
                  existing == data else { throw StoreError.cacheUnavailable(.checksumMismatch) }
        }
        _ = generation
    }

    private func readBucketReferenceLocked(bucketStart: Int, namespaceID: String) throws -> String {
        notify(.readBucketReference)
        let url = referenceURL(namespaceID: namespaceID, bucketStart: bucketStart)
        guard let data = try readPrivateFileLocked(
            url, maximumBytes: limits.maximumObjectBytes, missingIsNil: true) else {
            throw StoreError.cacheUnavailable(.missingReference)
        }
        do {
            let envelope = try JSONDecoder().decode(ReferenceEnvelope.self, from: data)
            let bodyData = try Self.canonicalJSON(envelope.body)
            guard envelope.schemaVersion == Self.schemaVersion,
                  envelope.body.schemaVersion == Self.schemaVersion,
                  envelope.body.namespaceID == namespaceID,
                  envelope.body.journal == journal,
                  envelope.body.bucketStart == bucketStart,
                  validDigest(envelope.body.objectID),
                  digest(bodyData) == envelope.bodyDigest else {
                throw StoreError.cacheUnavailable(.checksumMismatch)
            }
            return envelope.body.objectID
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.cacheUnavailable(.malformedReference)
        }
    }

    private func writeRecentPageLocked(
        _ page: RecentEventPage, namespaceID: String, source: SourceFingerprint
    ) throws -> RecentEventPageDescriptor {
        let body = PageObjectBody(
            schemaVersion: Self.schemaVersion, namespaceID: namespaceID,
            journal: journal, sourceID: source.sourceID, page: page)
        let bodyData = try Self.canonicalJSON(body)
        let objectID = digest(bodyData)
        let envelope = PageEnvelope(
            schemaVersion: Self.schemaVersion, objectID: objectID,
            bodyDigest: objectID, body: body)
        let data = try Self.canonicalJSON(envelope)
        guard data.count <= limits.maximumRecentPageBytes,
              data.count <= limits.maximumObjectBytes else {
            throw StoreError.invalidCommit(.oversize)
        }
        try writeContentAddressedLocked(data, objectID: objectID, suffix: "page")
        guard let first = page.events.first, let last = page.events.last else {
            throw StoreError.invalidCommit(.invalidPage)
        }
        return RecentEventPageDescriptor(
            pageID: page.pageID, sequenceStart: first.sequence, sequenceEnd: last.sequence,
            eventCount: page.events.count, objectID: objectID, byteCount: data.count,
            digest: objectID)
    }

    private func readRecentPageLocked(
        _ descriptor: RecentEventPageDescriptor, namespaceID: String, sourceID: String
    ) throws -> RecentEventPage {
        notify(.readRecentPage)
        let data = try readObjectLocked(objectID: descriptor.objectID, suffix: "page")
        do {
            let envelope = try JSONDecoder().decode(PageEnvelope.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion,
                  envelope.objectID == descriptor.objectID,
                  envelope.bodyDigest == descriptor.digest,
                  digest(try Self.canonicalJSON(envelope.body)) == descriptor.digest,
                  data.count == descriptor.byteCount,
                  envelope.body.namespaceID == namespaceID,
                  envelope.body.journal == journal,
                  envelope.body.sourceID == sourceID,
                  envelope.body.page.pageID == descriptor.pageID,
                  envelope.body.page.events.count == descriptor.eventCount,
                  envelope.body.page.events.first?.sequence == descriptor.sequenceStart,
                  envelope.body.page.events.last?.sequence == descriptor.sequenceEnd else {
                throw StoreError.cacheUnavailable(.checksumMismatch)
            }
            return envelope.body.page
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.cacheUnavailable(.malformedPayload)
        }
    }

    private func writeReducerHeadLocked(
        _ reducer: OpaqueReducerHead, namespaceID: String, source: SourceFingerprint
    ) throws -> OpaquePayloadDescriptor {
        guard reducer.bytes.count <= limits.maximumReducerHeadBytes,
              validMediaType(reducer.mediaType), reducer.schemaVersion > 0 else {
            throw StoreError.invalidCommit(.invalidReducerHead)
        }
        let body = ReducerObjectBody(
            schemaVersion: Self.schemaVersion, namespaceID: namespaceID,
            journal: journal, sourceID: source.sourceID, mediaType: reducer.mediaType,
            reducerSchemaVersion: reducer.schemaVersion, bytes: reducer.bytes)
        let bodyData = try Self.canonicalJSON(body)
        let objectID = digest(bodyData)
        let envelope = ReducerEnvelope(
            schemaVersion: Self.schemaVersion, objectID: objectID,
            bodyDigest: objectID, body: body)
        let data = try Self.canonicalJSON(envelope)
        guard data.count <= limits.maximumReducerHeadBytes,
              data.count <= limits.maximumObjectBytes else {
            throw StoreError.invalidCommit(.oversize)
        }
        try writeContentAddressedLocked(data, objectID: objectID, suffix: "reducer")
        return OpaquePayloadDescriptor(
            objectID: objectID, mediaType: reducer.mediaType,
            schemaVersion: reducer.schemaVersion, byteCount: reducer.bytes.count,
            digest: objectID)
    }

    private func readReducerHeadLocked(
        _ descriptor: OpaquePayloadDescriptor, namespaceID: String, sourceID: String
    ) throws -> Data {
        notify(.readReducerHead)
        let data = try readObjectLocked(objectID: descriptor.objectID, suffix: "reducer")
        do {
            let envelope = try JSONDecoder().decode(ReducerEnvelope.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion,
                  envelope.objectID == descriptor.objectID,
                  envelope.bodyDigest == descriptor.digest,
                  digest(try Self.canonicalJSON(envelope.body)) == descriptor.digest,
                  envelope.body.namespaceID == namespaceID,
                  envelope.body.journal == journal,
                  envelope.body.sourceID == sourceID,
                  envelope.body.mediaType == descriptor.mediaType,
                  envelope.body.reducerSchemaVersion == descriptor.schemaVersion,
                  envelope.body.bytes.count == descriptor.byteCount,
                  data.count <= limits.maximumReducerHeadBytes else {
                throw StoreError.cacheUnavailable(.checksumMismatch)
            }
            return envelope.body.bytes
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.cacheUnavailable(.malformedPayload)
        }
    }

    private func writeExactStateCheckpointLocked(
        _ checkpoint: ExactStateCheckpoint,
        namespaceID: String,
        source: SourceFingerprint
    ) throws -> ExactStateCheckpointDescriptor {
        try validateExactStateCheckpoint(
            checkpoint, namespaceID: namespaceID, source: source, cursor: checkpoint.cursor)
        let persisted = PersistedExactStateCheckpoint(checkpoint)
        let bodyData = try Self.canonicalJSON(persisted)
        let objectID = digest(bodyData)
        let envelope = ExactStateCheckpointEnvelope(
            schemaVersion: Self.schemaVersion, objectID: objectID,
            bodyDigest: objectID, body: persisted)
        let data = try Self.canonicalJSON(envelope)
        guard data.count <= limits.maximumExactStateCheckpointBytes,
              data.count <= limits.maximumObjectBytes else {
            throw StoreError.invalidCommit(.oversize)
        }
        try writeContentAddressedLocked(
            data, objectID: objectID, suffix: "exact-checkpoint")
        return ExactStateCheckpointDescriptor(
            objectID: objectID, schemaVersion: checkpoint.schemaVersion,
            byteCount: data.count, digest: objectID)
    }

    private func readExactStateCheckpointDescriptorLocked(
        _ snapshot: Snapshot
    ) throws -> ExactStateCheckpoint? {
        guard let descriptor = snapshot.exactStateCheckpoint else { return nil }
        try validateExactStateCheckpointDescriptor(descriptor)
        notify(.readExactStateCheckpoint)
        let data = try readObjectLocked(
            objectID: descriptor.objectID, suffix: "exact-checkpoint")
        do {
            let envelope = try JSONDecoder().decode(
                ExactStateCheckpointEnvelope.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion,
                  envelope.objectID == descriptor.objectID,
                  envelope.bodyDigest == descriptor.digest,
                  digest(try Self.canonicalJSON(envelope.body)) == descriptor.digest,
                  data.count == descriptor.byteCount else {
                throw StoreError.cacheUnavailable(.checksumMismatch)
            }
            let checkpoint = ExactStateCheckpoint(persisted: envelope.body)
            try validateExactStateCheckpoint(
                checkpoint, namespaceID: snapshot.namespaceID,
                source: snapshot.source, cursor: snapshot.cursor)
            return checkpoint
        } catch let error as StoreError {
            switch error {
            case .invalidCommit(let reason):
                throw StoreError.cacheUnavailable(reason)
            default:
                throw error
            }
        } catch {
            throw StoreError.cacheUnavailable(.malformedPayload)
        }
    }

    private func reserveExactNamespaceLocked(
        namespaceID: String, initialCommit: Commit, existingHead: Snapshot?
    ) throws {
        let normalized = Commit(
            source: initialCommit.source,
            cursor: initialCommit.cursor,
            prefixSeed: initialCommit.prefixSeed,
            nextSequence: initialCommit.nextSequence,
            nextPreviousEventID: initialCommit.nextPreviousEventID,
            sealedBuckets: initialCommit.sealedBuckets,
            currentBucket: initialCommit.currentBucket,
            anchors: initialCommit.anchors,
            recentPages: initialCommit.recentPages,
            reducerHead: initialCommit.reducerHead,
            exactStateCheckpoint: initialCommit.exactStateCheckpoint,
            pendingAcknowledgements: initialCommit.pendingAcknowledgements,
            expectedGeneration: nil)
        let initialDigest = digest(try Self.canonicalJSON(normalized))
        let markerURL = exactNamespaceMarkerURL(namespaceID: namespaceID)
        let expected = ExactNamespaceMarker(
            namespaceID: namespaceID, journal: journal,
            initialCommitDigest: initialDigest, retired: false)

        if let data = try readPrivateFileLocked(
            markerURL, maximumBytes: limits.maximumHeadBytes, missingIsNil: true)
        {
            let marker: ExactNamespaceMarker
            do { marker = try JSONDecoder().decode(ExactNamespaceMarker.self, from: data) }
            catch { throw StoreError.cacheUnavailable(.malformedReference) }
            guard marker.schemaVersion == ExactNamespaceMarker.schemaVersion,
                  marker.namespaceID == namespaceID,
                  marker.journal == journal,
                  validDigest(marker.initialCommitDigest) else {
                throw StoreError.cacheUnavailable(.malformedReference)
            }
            guard !marker.retired else {
                throw StoreError.invalidCommit(.invalidExactStateCheckpoint)
            }
            // With no published HEAD, only an exact retry of the first attempted publication may
            // reuse this namespace. A different prefix might encounter immutable references left
            // by the failed attempt.
            if existingHead == nil, marker.initialCommitDigest != initialDigest {
                throw StoreError.invalidCommit(.invalidExactStateCheckpoint)
            }
            guard existingHead == nil || existingHead?.namespaceID == namespaceID else {
                throw StoreError.invalidCommit(.invalidExactStateCheckpoint)
            }
            try activateExactNamespaceLocked(marker: marker)
            return
        }

        // A store that already advertises an exact checkpoint must also have its namespace
        // marker. Missing marker evidence is corruption, not an invitation to recreate it.
        if existingHead?.exactStateCheckpoint != nil {
            throw StoreError.cacheUnavailable(.missingReference)
        }
        // A failed first publication may have durably reserved a different disposable namespace
        // without ever publishing HEAD. A later rebuild for a changed canonical source must not
        // remain wedged behind that abandoned reservation. Retire it before admitting the new
        // namespace; same-namespace retries took the marker-present path above and still require
        // an exact initial-commit digest match.
        if existingHead == nil,
           try retireActiveExactNamespaceLocked(expectedNamespaceID: nil, required: false) {
            try removeActiveExactNamespacePointerLocked()
        }
        let data = try Self.canonicalJSON(expected)
        guard data.count <= limits.maximumHeadBytes else {
            throw StoreError.invalidCommit(.oversize)
        }
        try writeNewLocked(data, to: markerURL, operation: .writeReference)
        try activateExactNamespaceLocked(marker: expected)
    }

    private func activateExactNamespaceLocked(marker: ExactNamespaceMarker) throws {
        let pointer = ExactNamespacePointer(marker: marker)
        let pointerURL = activeExactNamespacePointerURL
        if let data = try readPrivateFileLocked(
            pointerURL, maximumBytes: limits.maximumHeadBytes, missingIsNil: true)
        {
            let stored: ExactNamespacePointer
            do { stored = try JSONDecoder().decode(ExactNamespacePointer.self, from: data) }
            catch { throw StoreError.cacheUnavailable(.malformedReference) }
            guard stored.schemaVersion == ExactNamespacePointer.schemaVersion,
                  stored.journal == journal,
                  validIdentity(stored.namespaceID),
                  validDigest(stored.initialCommitDigest) else {
                throw StoreError.cacheUnavailable(.malformedReference)
            }
            guard stored == pointer else {
                throw StoreError.invalidCommit(.invalidExactStateCheckpoint)
            }
            return
        }
        let data = try Self.canonicalJSON(pointer)
        guard data.count <= limits.maximumHeadBytes else {
            throw StoreError.invalidCommit(.oversize)
        }
        try writeNewLocked(data, to: pointerURL, operation: .writeReference)
    }

    @discardableResult
    private func retireActiveExactNamespaceLocked(
        expectedNamespaceID: String?, required: Bool
    ) throws -> Bool {
        guard let data = try readPrivateFileLocked(
            activeExactNamespacePointerURL,
            maximumBytes: limits.maximumHeadBytes,
            missingIsNil: true)
        else {
            if required { throw StoreError.cacheUnavailable(.missingReference) }
            return false
        }
        let pointer: ExactNamespacePointer
        do { pointer = try JSONDecoder().decode(ExactNamespacePointer.self, from: data) }
        catch { throw StoreError.cacheUnavailable(.malformedReference) }
        guard pointer.schemaVersion == ExactNamespacePointer.schemaVersion,
              pointer.journal == journal,
              validIdentity(pointer.namespaceID),
              validDigest(pointer.initialCommitDigest),
              expectedNamespaceID == nil || expectedNamespaceID == pointer.namespaceID else {
            throw StoreError.cacheUnavailable(.malformedReference)
        }
        try retireExactNamespaceLocked(
            namespaceID: pointer.namespaceID,
            expectedInitialCommitDigest: pointer.initialCommitDigest)
        return true
    }

    private func retireExactNamespaceLocked(
        namespaceID: String, expectedInitialCommitDigest: String
    ) throws {
        let markerURL = exactNamespaceMarkerURL(namespaceID: namespaceID)
        guard let data = try readPrivateFileLocked(
            markerURL, maximumBytes: limits.maximumHeadBytes, missingIsNil: true)
        else { throw StoreError.cacheUnavailable(.missingReference) }
        let marker: ExactNamespaceMarker
        do { marker = try JSONDecoder().decode(ExactNamespaceMarker.self, from: data) }
        catch { throw StoreError.cacheUnavailable(.malformedReference) }
        guard marker.schemaVersion == ExactNamespaceMarker.schemaVersion,
              marker.namespaceID == namespaceID,
              marker.journal == journal,
              marker.initialCommitDigest == expectedInitialCommitDigest,
              validDigest(marker.initialCommitDigest) else {
            throw StoreError.cacheUnavailable(.malformedReference)
        }
        guard !marker.retired else { return }
        let retired = ExactNamespaceMarker(
            namespaceID: marker.namespaceID, journal: marker.journal,
            initialCommitDigest: marker.initialCommitDigest, retired: true)
        try writeAtomicallyLocked(
            try Self.canonicalJSON(retired), to: markerURL, operation: .writeReference)
    }

    private func removeActiveExactNamespacePointerLocked() throws {
        let url = activeExactNamespacePointerURL
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw StoreError.cacheUnavailable(.accessDenied)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw StoreError.cacheUnavailable(.symlinkOrNonRegularFile)
        }
        guard unlink(url.path) == 0 else {
            throw StoreError.cacheUnavailable(.ioFailure)
        }
        try synchronizeDirectoryLocked(at: referencesURL)
    }

    // MARK: Filesystem discipline

    private var headURL: URL { directory.appending(path: "HEAD", directoryHint: .notDirectory) }
    private var objectsURL: URL { directory.appending(path: "objects", directoryHint: .isDirectory) }
    private var referencesURL: URL { directory.appending(path: "refs", directoryHint: .isDirectory) }
    private var lockURL: URL { directory.appending(path: ".store.lock", directoryHint: .notDirectory) }
    private func lockReentrancyKey() throws -> String {
        var info = stat()
        guard stat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            throw StoreError.cacheUnavailable(.accessDenied)
        }
        // Device/inode identity collapses lexical and symlinked-ancestor aliases to the same
        // cooperating store without treating the path spelling as authority.
        return "aviary.projection-store.lock.\(UInt64(info.st_dev)).\(UInt64(info.st_ino))"
    }

    private func prepareDirectory() throws {
        notify(.prepareDirectory)
        try ensurePrivateDirectory(directory)
        try ensurePrivateDirectory(objectsURL)
        try ensurePrivateDirectory(referencesURL)
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid(),
                  (info.st_mode & mode_t(0o777)) == mode_t(0o700) else {
                throw StoreError.cacheUnavailable(
                    (info.st_mode & S_IFMT) == S_IFLNK ? .symlinkOrNonRegularFile : .insecurePermissions)
            }
            return
        }
        guard errno == ENOENT else { throw StoreError.cacheUnavailable(.accessDenied) }
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw StoreError.cacheUnavailable(.ioFailure)
        }
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            throw StoreError.cacheUnavailable(.symlinkOrNonRegularFile)
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let reentrancyKey = try lockReentrancyKey()
        let threadState = Thread.current.threadDictionary
        guard threadState[reentrancyKey] == nil else {
            throw StoreError.cacheUnavailable(.reentrantAccess)
        }
        threadState[reentrancyKey] = true
        defer { threadState.removeObject(forKey: reentrancyKey) }
        let fd = lockURL.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode: mode_t(0o600))
        }
        guard fd >= 0 else { throw StoreError.cacheUnavailable(.accessDenied) }
        notify(.acquireLock)
        defer { _ = AviaryPOSIX.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw StoreError.cacheUnavailable(.insecurePermissions)
        }
        return try body()
    }

    private func readPrivateFileLocked(
        _ url: URL, maximumBytes: Int, missingIsNil: Bool
    ) throws -> Data? {
        let fd = url.path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            if missingIsNil, errno == ENOENT { return nil }
            if errno == ELOOP { throw StoreError.cacheUnavailable(.symlinkOrNonRegularFile) }
            if errno == ENOENT { throw StoreError.rebuildRequired(.missingPayload) }
            throw StoreError.cacheUnavailable(.accessDenied)
        }
        defer { _ = AviaryPOSIX.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o777)) == mode_t(0o600),
              info.st_size >= 0,
              info.st_size <= off_t(maximumBytes) else {
            throw StoreError.cacheUnavailable(
                (info.st_mode & S_IFMT) == S_IFREG ? .insecurePermissions : .symlinkOrNonRegularFile)
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(16 * 1_024, maximumBytes))
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                AviaryPOSIX.read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                guard data.count <= maximumBytes - count else {
                    throw StoreError.cacheUnavailable(.oversize)
                }
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw StoreError.cacheUnavailable(.ioFailure)
            }
        }
        return data
    }

    private func writeContentAddressedLocked(_ data: Data, objectID: String, suffix: String) throws {
        guard validDigest(objectID), data.count <= limits.maximumObjectBytes else {
            throw StoreError.invalidCommit(.oversize)
        }
        let url = objectURL(objectID: objectID, suffix: suffix)
        notify(.writePayload)
        do {
            try writeNewLocked(data, to: url, operation: .writePayload)
        } catch StoreError.cacheUnavailable(.ioFailure) {
            // Content addressing makes an exact retry safe.  A different body under the same
            // digest is corruption, not a reason to replace an immutable object.
            guard let existing = try readPrivateFileLocked(
                url, maximumBytes: limits.maximumObjectBytes, missingIsNil: false),
                  existing == data else {
                throw StoreError.cacheUnavailable(.checksumMismatch)
            }
        }
    }

    private func writeNewLocked(_ data: Data, to url: URL, operation: AccessOperation) throws {
        let fd = url.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else {
            if errno == EEXIST {
                throw StoreError.cacheUnavailable(.ioFailure)
            }
            throw StoreError.cacheUnavailable(.ioFailure)
        }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let count = write(fd, base.advanced(by: offset), raw.count - offset)
                    if count > 0 {
                        offset += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        throw StoreError.cacheUnavailable(.ioFailure)
                    }
                }
            }
            guard fsync(fd) == 0 else {
                throw StoreError.cacheUnavailable(.ioFailure)
            }
        } catch {
            _ = AviaryPOSIX.close(fd)
            _ = unlink(url.path)
            throw error
        }
        guard AviaryPOSIX.close(fd) == 0 else {
            throw StoreError.cacheUnavailable(.ioFailure)
        }
        _ = operation
        try synchronizeDirectoryLocked(at: url.deletingLastPathComponent())
    }

    private func writeAtomicallyLocked(
        _ data: Data, to destination: URL, operation: AccessOperation
    ) throws {
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(),
                  (info.st_mode & mode_t(0o777)) == mode_t(0o600) else {
                throw StoreError.cacheUnavailable(.symlinkOrNonRegularFile)
            }
        } else if errno != ENOENT {
            throw StoreError.cacheUnavailable(.accessDenied)
        }
        let temporary = directory.appending(
            path: ".HEAD.\(UUID().uuidString.lowercased()).tmp", directoryHint: .notDirectory)
        let fd = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw StoreError.cacheUnavailable(.ioFailure) }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let count = write(fd, base.advanced(by: offset), raw.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && errno == EINTR { continue }
                    else { throw StoreError.cacheUnavailable(.ioFailure) }
                }
            }
            guard fsync(fd) == 0 else { throw StoreError.cacheUnavailable(.ioFailure) }
        } catch {
            _ = AviaryPOSIX.close(fd)
            _ = unlink(temporary.path)
            throw error
        }
        guard AviaryPOSIX.close(fd) == 0 else {
            _ = unlink(temporary.path)
            throw StoreError.cacheUnavailable(.ioFailure)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            _ = unlink(temporary.path)
            throw StoreError.cacheUnavailable(.ioFailure)
        }
        notify(operation)
        do {
            try synchronizeDirectoryLocked(at: destination.deletingLastPathComponent())
        } catch {
            if operation == .publishHead {
                throw StoreError.cacheUnavailable(.publicationIndeterminate)
            }
            throw error
        }
    }

    private func removeHeadLocked() throws -> Bool {
        var info = stat()
        guard lstat(headURL.path, &info) == 0 else {
            if errno == ENOENT { return true }
            throw StoreError.cacheUnavailable(.accessDenied)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw StoreError.cacheUnavailable(.symlinkOrNonRegularFile)
        }
        return unlink(headURL.path) == 0
    }

    private func removePayloadIfPresentLocked(_ objectID: String) throws -> Bool {
        guard validDigest(objectID) else { throw StoreError.cacheUnavailable(.invalidDigest) }
        // The suffix is not persisted in the descriptor.  Current/recent/reducer objects are
        // removed through the three known bounded suffixes; at most one exists for an object ID.
        for suffix in ["bucket", "page", "reducer", "exact-checkpoint"] {
            let url = objectURL(objectID: objectID, suffix: suffix)
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { continue }
                throw StoreError.cacheUnavailable(.accessDenied)
            }
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(),
                  (info.st_mode & mode_t(0o777)) == mode_t(0o600) else {
                throw StoreError.cacheUnavailable(.symlinkOrNonRegularFile)
            }
            guard unlink(url.path) == 0 else { throw StoreError.cacheUnavailable(.ioFailure) }
            return true
        }
        return false
    }

    /// Reclaim only the bounded replaceable payload set from the immediately previous head.
    /// Sealed buckets remain immutable history. Failure is deliberately non-fatal after HEAD has
    /// committed: at worst one generation leaks, while reporting commit failure here would make a
    /// successfully published transaction look indeterminate to its caller.
    private func reclaimReplacedPayloadsLocked(old: Snapshot?, new: Snapshot) {
        guard let old else { return }
        struct PayloadKey: Hashable {
            let objectID: String
            let suffix: String
        }
        var retained = Set<PayloadKey>()
        if let current = new.currentBucket {
            retained.insert(PayloadKey(objectID: current.objectID, suffix: "bucket"))
        }
        for page in new.recentPages {
            retained.insert(PayloadKey(objectID: page.objectID, suffix: "page"))
        }
        if let reducer = new.reducerHead {
            retained.insert(PayloadKey(objectID: reducer.objectID, suffix: "reducer"))
        }
        if let checkpoint = new.exactStateCheckpoint {
            retained.insert(PayloadKey(objectID: checkpoint.objectID, suffix: "exact-checkpoint"))
        }
        var obsolete: [PayloadKey] = []
        if let current = old.currentBucket {
            obsolete.append(PayloadKey(objectID: current.objectID, suffix: "bucket"))
        }
        obsolete.append(contentsOf: old.recentPages.map {
            PayloadKey(objectID: $0.objectID, suffix: "page")
        })
        if let reducer = old.reducerHead {
            obsolete.append(PayloadKey(objectID: reducer.objectID, suffix: "reducer"))
        }
        if let checkpoint = old.exactStateCheckpoint {
            obsolete.append(PayloadKey(objectID: checkpoint.objectID, suffix: "exact-checkpoint"))
        }
        var removedAny = false
        for key in obsolete where !retained.contains(key) {
            if (try? removePayloadIfPresentLocked(key.objectID, suffix: key.suffix)) == true {
                removedAny = true
            }
        }
        if removedAny { try? synchronizeDirectoryLocked(at: objectsURL) }
    }

    private func removePayloadIfPresentLocked(_ objectID: String, suffix: String) throws -> Bool {
        guard validDigest(objectID),
              ["bucket", "page", "reducer", "exact-checkpoint"].contains(suffix) else {
            throw StoreError.cacheUnavailable(.invalidDigest)
        }
        let url = objectURL(objectID: objectID, suffix: suffix)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw StoreError.cacheUnavailable(.accessDenied)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw StoreError.cacheUnavailable(.symlinkOrNonRegularFile)
        }
        guard unlink(url.path) == 0 else { throw StoreError.cacheUnavailable(.ioFailure) }
        return true
    }

    private func synchronizeDirectoryLocked(at directoryURL: URL? = nil) throws {
        let directoryURL = directoryURL ?? directory
        let fd = directoryURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw StoreError.cacheUnavailable(.ioFailure) }
        defer { _ = AviaryPOSIX.close(fd) }
        guard fsync(fd) == 0 else { throw StoreError.cacheUnavailable(.ioFailure) }
    }

    private func objectURL(objectID: String, suffix: String) -> URL {
        objectsURL.appending(path: "\(objectID).\(suffix)", directoryHint: .notDirectory)
    }

    private func referenceURL(namespaceID: String, bucketStart: Int) -> URL {
        referencesURL.appending(
            path: "\(namespaceID)-\(bucketStart).ref",
            directoryHint: .notDirectory)
    }

    private func exactNamespaceMarkerURL(namespaceID: String) -> URL {
        let markerID = digest(Data("exact-namespace-v1\u{0}\(namespaceID)".utf8))
        return referencesURL.appending(
            path: "\(markerID).exact-namespace", directoryHint: .notDirectory)
    }

    private var activeExactNamespacePointerURL: URL {
        referencesURL.appending(
            path: "ACTIVE-EXACT-NAMESPACE", directoryHint: .notDirectory)
    }

    private func readObjectLocked(objectID: String, suffix: String) throws -> Data {
        guard validDigest(objectID) else { throw StoreError.cacheUnavailable(.invalidDigest) }
        guard let data = try readPrivateFileLocked(
            objectURL(objectID: objectID, suffix: suffix),
            maximumBytes: limits.maximumObjectBytes, missingIsNil: true) else {
            throw StoreError.cacheUnavailable(.missingPayload)
        }
        return data
    }

    // MARK: Small helpers

    private func notify(_ operation: AccessOperation) {
        observer?(operation)
    }

    private func digest(_ data: Data) -> String {
        Self.hexDigest(data)
    }

    private static func hexDigest(_ data: Data) -> String {
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

    private func validExactDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 97 && $0.value <= 102)
            }
    }

    private func validIdentity(_ value: String) -> Bool {
        value.utf8.count > 0
            && value.utf8.count <= limits.maximumIdentityBytes
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
            && !value.contains("/")
            && !value.contains("\\")
    }

    private func validMediaType(_ value: String) -> Bool {
        guard value.utf8.count > 0,
              value.utf8.count <= limits.maximumIdentityBytes else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57)
                    || (byte >= 65 && byte <= 90)
                    || (byte >= 97 && byte <= 122)
                    || byte == 33 || byte == 35 || byte == 36 || byte == 38
                    || byte == 43 || byte == 45 || byte == 46 || byte == 94
                    || byte == 95
            }
        }
    }

    private func validOffsets(_ start: Int, _ end: Int) -> Bool {
        start >= 0 && end > start && end <= limits.maximumSourceBytes
    }

    private static func sortedExactStateRoots(
        _ roots: [ExactStateRootDescriptor]
    ) -> [ExactStateRootDescriptor] {
        roots.sorted {
            if $0.namespaceID != $1.namespaceID {
                return $0.namespaceID < $1.namespaceID
            }
            if $0.mapKind != $1.mapKind {
                return $0.mapKind < $1.mapKind
            }
            if $0.objectID != $1.objectID {
                return $0.objectID < $1.objectID
            }
            return $0.entryCount < $1.entryCount
        }
    }
}
