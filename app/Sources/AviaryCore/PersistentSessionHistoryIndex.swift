import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A disposable, metadata-only projection of one selected Session conversation branch.
///
/// Canonical message text remains exclusively in the Session JSONL journal. A cold builder
/// validates the complete physical append chain and records exact line ranges/digests, but retains
/// no `TimelineEvent` or message-body array. Finalization follows the selected semantic tip and
/// writes packed immutable branch chunks before atomically replacing `HEAD`. A page lookup reads
/// only the bounded chunk range that contains the requested branch boundary.
///
/// This primitive does not acquire the Timeline owner lock and does not read canonical line
/// bodies. Its caller must hold one owner-lock/source lease across build or load, canonical range
/// reads, and the final source fence. Canonical rows remain the authority for returned body bytes;
/// selected-branch completeness relies on this private derived index and the cooperating-writer
/// lock contract. A same-user process that coherently recomputes cache metadata is outside that
/// trust model, and this cache is not a sandbox or containment boundary.
public struct PersistentSessionHistoryIndex: Sendable {
    public static let schemaVersion = 4
    public static let chunkSchemaVersion = 1
    public static let anchorStride = 256

    public struct Limits: Hashable, Sendable {
        public static let `default` = Limits()

        public let maximumIdentityBytes: Int
        public let maximumPhysicalEvents: Int
        public let maximumMessages: Int
        public let maximumAuxiliaryRecords: Int
        public let maximumChunkMessages: Int
        public let maximumChunkBytes: Int
        public let maximumManifestBytes: Int
        public let maximumHeadBytes: Int
        public let maximumObjectBytes: Int

        public init(
            maximumIdentityBytes: Int = 1_024,
            maximumPhysicalEvents: Int = 4_000_000,
            maximumMessages: Int = 524_288,
            maximumAuxiliaryRecords: Int = 16_384,
            maximumChunkMessages: Int = 128,
            maximumChunkBytes: Int = 512 * 1_024,
            maximumManifestBytes: Int = 4 * 1_024 * 1_024,
            maximumHeadBytes: Int = 64 * 1_024,
            maximumObjectBytes: Int = 8 * 1_024 * 1_024
        ) {
            self.maximumIdentityBytes = Self.clamp(maximumIdentityBytes, 4 * 1_024)
            self.maximumPhysicalEvents = Self.clamp(maximumPhysicalEvents, 8_000_000)
            self.maximumMessages = Self.clamp(maximumMessages, 4_000_000)
            self.maximumAuxiliaryRecords = Self.clamp(
                maximumAuxiliaryRecords, 131_072)
            self.maximumChunkMessages = Self.clamp(maximumChunkMessages, 4_096)
            self.maximumChunkBytes = Self.clamp(maximumChunkBytes, 8 * 1_024 * 1_024)
            self.maximumManifestBytes = Self.clamp(maximumManifestBytes, 16 * 1_024 * 1_024)
            self.maximumHeadBytes = Self.clamp(maximumHeadBytes, 1 * 1_024 * 1_024)
            self.maximumObjectBytes = Self.clamp(maximumObjectBytes, 64 * 1_024 * 1_024)
        }

        private static func clamp(_ value: Int, _ upper: Int) -> Int {
            max(1, min(value, upper))
        }
    }

    public enum IndexError: Swift.Error, LocalizedError, Equatable, Sendable {
        case unavailable
        case invalidIdentity
        case invalidSource
        case sourceMismatch
        case invalidRecord
        case duplicateIdentity
        case chainMismatch
        case missingSelectedTip
        case invalidBranch
        case boundaryNotOnBranch
        case invalidCursor
        case missingObject
        case checksumMismatch
        case schemaMismatch
        case oversize
        case symlinkOrNonRegularFile
        case insecurePermissions
        case ioFailure

        public var errorDescription: String? {
            switch self {
            case .unavailable: return "Persistent Session history is unavailable."
            case .invalidIdentity: return "Persistent Session history identity is invalid."
            case .invalidSource: return "Persistent Session history source proof is invalid."
            case .sourceMismatch: return "Persistent Session history source proof does not match."
            case .invalidRecord: return "Persistent Session history contains an invalid record."
            case .duplicateIdentity: return "Persistent Session history contains a duplicate event identity."
            case .chainMismatch: return "Persistent Session history append chain does not match."
            case .missingSelectedTip: return "Persistent Session history cannot resolve its selected tip."
            case .invalidBranch: return "Persistent Session history selected branch is invalid."
            case .boundaryNotOnBranch: return "The requested history boundary is not on the selected branch."
            case .invalidCursor: return "Persistent Session history cursor is invalid."
            case .missingObject: return "A persistent Session history object is missing."
            case .checksumMismatch: return "A persistent Session history checksum does not match."
            case .schemaMismatch: return "Persistent Session history schema is unsupported."
            case .oversize: return "Persistent Session history exceeds a configured bound."
            case .symlinkOrNonRegularFile: return "Persistent Session history storage is not a private regular path."
            case .insecurePermissions: return "Persistent Session history storage permissions are not private."
            case .ioFailure: return "Persistent Session history storage I/O failed."
            }
        }
    }

    public typealias Error = IndexError

    /// Exact identity of the canonical physical prefix represented by one manifest.
    public struct SourceProof: Codable, Hashable, Sendable {
        public let session: SessionRef
        public let journal: JournalRef
        public let sourceID: String
        public let sourceGeneration: String
        /// Exact source observation at publication. It is carried inside the same
        /// content-addressed manifest as the branch metadata; there is no second fence file that
        /// can be published in a different crash window.
        public let sourceFingerprint: String
        public let physicalCursor: JournalCursor
        public let prefixByteCount: Int
        /// Raw 64-hex projection-store prefix chain.
        public let prefixDigest: String
        /// `sha256:<64>` Work-service physical-prefix token.
        public let wirePrefixDigest: String

        public init(
            session: SessionRef,
            journal: JournalRef,
            sourceID: String,
            sourceGeneration: String,
            sourceFingerprint: String,
            physicalCursor: JournalCursor,
            prefixByteCount: Int,
            prefixDigest: String,
            wirePrefixDigest: String
        ) {
            self.session = session
            self.journal = journal
            self.sourceID = sourceID
            self.sourceGeneration = sourceGeneration
            self.sourceFingerprint = sourceFingerprint
            self.physicalCursor = physicalCursor
            self.prefixByteCount = prefixByteCount
            self.prefixDigest = prefixDigest
            self.wirePrefixDigest = wirePrefixDigest
        }
    }

    /// Metadata sufficient to locate and independently verify one canonical message line.
    /// Message text is represented only by a digest and byte count.
    public struct MessageRecord: Codable, Hashable, Sendable {
        public let eventID: String
        /// Physical append-chain predecessor.  The selected semantic branch can skip physical
        /// events, so history range verification must retain this independently of the
        /// conversation parent.
        public let previousEventID: String?
        public let sourceCursor: JournalCursor
        public let conversationParent: EventRef?
        public let role: String
        public let textDigest: String
        public let textByteCount: Int
        public let byteStart: Int
        public let byteEnd: Int
        public let lineDigest: String
        public let prefixDigestBefore: String
        public let prefixDigestAfter: String
        public let sourceGeneration: String
    }

    /// Sparse physical evidence used by a later range reader to prove an older frozen cursor.
    public struct PhysicalAnchor: Codable, Hashable, Sendable {
        public let cursor: JournalCursor
        public let previousEventID: String?
        public let byteStart: Int
        public let byteEnd: Int
        public let lineDigest: String
        public let prefixDigestBefore: String
        public let prefixDigestAfter: String
        public let wirePrefixDigestBefore: String
        public let wirePrefixDigestAfter: String
    }

    public struct ChunkReference: Codable, Hashable, Sendable {
        public let objectID: String
        public let byteCount: Int
        public let messageCount: Int
        public let firstCursor: JournalCursor
        public let lastCursor: JournalCursor
    }

    /// Metadata-only relationship evidence from the canonical Session reducer. Capability
    /// strings are intentionally omitted: history authorization is checked against the current
    /// Work Host control attachment, and arbitrary timeline payload text must not enter this
    /// disposable index.
    public struct HistoryAttachmentRecord: Codable, Hashable, Sendable {
        public let attachment: SessionAttachmentRef
        public let work: WorkRef
        public let cursor: JournalCursor?
        public let isAttached: Bool

        fileprivate init(_ snapshot: SessionAttachmentSnapshot) {
            attachment = snapshot.attachment
            work = snapshot.work
            cursor = snapshot.cursor
            isAttached = snapshot.isAttached
        }
    }

    /// Body-free address evidence for the bounded Session relationship events that cross
    /// journals. Client, capability, command, payload, and producer-envelope values are omitted;
    /// the owner-locked reader must recover those facts from the exact canonical row.
    public struct HistoryRelationshipEventRecord: Codable, Hashable, Sendable {
        public let event: EventRef
        public let cursor: JournalCursor
        public let previousEventID: String?
        public let type: String
        public let session: SessionRef
        /// Exact canonical row evidence. The manifest remains an address book; readers must
        /// reread this range from the Session journal before using any projected field as
        /// relationship authority.
        public let byteStart: Int
        public let byteEnd: Int
        public let lineDigest: String
        public let prefixDigestBefore: String
        public let prefixDigestAfter: String
        public let sourceGeneration: String
    }

    public struct Manifest: Codable, Hashable, Sendable {
        public let schemaVersion: Int
        public let source: SourceProof
        public let semanticTip: EventRef?
        public let physicalEventCount: Int
        public let indexedMessageCount: Int
        public let selectedMessageCount: Int
        public let sessionAttachments: [HistoryAttachmentRecord]
        public let relationshipEvents: [HistoryRelationshipEventRecord]
        public let chunks: [ChunkReference]
        public let anchors: [PhysicalAnchor]
        public let manifestDigest: String

        fileprivate init(
            source: SourceProof,
            semanticTip: EventRef?,
            physicalEventCount: Int,
            indexedMessageCount: Int,
            selectedMessageCount: Int,
            sessionAttachments: [HistoryAttachmentRecord],
            relationshipEvents: [HistoryRelationshipEventRecord],
            chunks: [ChunkReference],
            anchors: [PhysicalAnchor],
            manifestDigest: String
        ) {
            self.schemaVersion = PersistentSessionHistoryIndex.schemaVersion
            self.source = source
            self.semanticTip = semanticTip
            self.physicalEventCount = physicalEventCount
            self.indexedMessageCount = indexedMessageCount
            self.selectedMessageCount = selectedMessageCount
            self.sessionAttachments = sessionAttachments
            self.relationshipEvents = relationshipEvents
            self.chunks = chunks
            self.anchors = anchors
            self.manifestDigest = manifestDigest
        }
    }

    public struct QueryMetrics: Codable, Hashable, Sendable {
        public let objectsRead: Int
        public let bytesRead: Int
        public let chunksRead: Int
        public let branchEntriesExamined: Int
        /// Binary-search steps used to resolve the frozen boundary within the chunk table.
        public let boundaryEntriesExamined: Int
        /// Binary-search steps used to resolve the exact boundary record within its chunk.
        public let boundaryRecordsExamined: Int
        /// Bytes read from the selected HEAD or immutable boundary pointer and manifest.
        public let headBytesRead: Int
        public let manifestBytesRead: Int

        fileprivate init(objectsRead: Int = 0, bytesRead: Int = 0,
                         chunksRead: Int = 0, branchEntriesExamined: Int = 0,
                         boundaryEntriesExamined: Int = 0,
                         boundaryRecordsExamined: Int = 0,
                         headBytesRead: Int = 0,
                         manifestBytesRead: Int = 0) {
            self.objectsRead = objectsRead
            self.bytesRead = bytesRead
            self.chunksRead = chunksRead
            self.branchEntriesExamined = branchEntriesExamined
            self.boundaryEntriesExamined = boundaryEntriesExamined
            self.boundaryRecordsExamined = boundaryRecordsExamined
            self.headBytesRead = headBytesRead
            self.manifestBytesRead = manifestBytesRead
        }
    }

    public struct Page: Hashable, Sendable {
        public let records: [MessageRecord]
        public let source: SourceProof
        public let semanticTip: EventRef?
        public let sessionAttachments: [HistoryAttachmentRecord]
        public let relationshipEvents: [HistoryRelationshipEventRecord]
        public let nextBeforeCursor: JournalCursor?
        public let hasOlder: Bool
        public let metrics: QueryMetrics
    }

    private struct MessageBuildRecord: Sendable {
        let record: MessageRecord
        let presentationVisible: Bool
        let conversationValid: Bool
    }

    /// Body-free adapter over the canonical Session transition rules. It retains only bounded
    /// identities and redacted message markers, so semantic validation does not recreate the
    /// full Session reducer's lifetime message-body arrays.
    private struct HistorySemanticState: SessionTransitionState, Sendable {
        private var scalarState = BoundedSessionScalarContinuation(snapshot: SessionSnapshot())
        private var contextState = SessionContextContinuation(snapshot: SessionSnapshot())
        private var compactionState = SessionCompactionContinuation(snapshot: SessionSnapshot())
        private var seen = Set<String>()
        private var attachments: [String: SessionAttachmentSnapshot] = [:]
        private var messages: [String: SessionMessageSnapshot] = [:]
        private var messageValidity: [String: Bool] = [:]
        private var messageOrder: [String] = []
        private var cumulativeContextBytes: [String: Int] = [:]
        private let maximumMessageRecords: Int
        private let maximumAuxiliaryRecords: Int
        private(set) var exceededBounds = false

        init(maximumMessageRecords: Int, maximumAuxiliaryRecords: Int) {
            self.maximumMessageRecords = max(1, maximumMessageRecords)
            self.maximumAuxiliaryRecords = max(1, maximumAuxiliaryRecords)
        }

        var scalar: BoundedSessionScalarContinuation { scalarState }
        var context: SessionContextContinuation { contextState }
        var compaction: SessionCompactionContinuation { compactionState }
        var seenEventCount: Int { seen.count }
        var messageHistoryCount: Int { messageOrder.count }

        var isHistoryComplete: Bool {
            !exceededBounds && scalarState.structuralIntegrityValid
                && scalarState.semanticProjectionValid
                // Conversation content may remain intelligible when a future runtime-only event
                // appears, but this index also carries the Session-to-Work publication rows used
                // by WorkService history authorization. Any unknown Session or Work semantic can
                // therefore change the selected branch or relationship and must fail closed.
                && scalarState.unknownDomains.isDisjoint(with: [.session, .work])
        }

        var currentAttachments: [HistoryAttachmentRecord] {
            attachments.values.map(HistoryAttachmentRecord.init).sorted {
                $0.attachment.attachmentID < $1.attachment.attachmentID
            }
        }

        func hasSeenEvent(_ eventID: String) -> Bool { seen.contains(eventID) }

        func attachment(for attachmentID: String) -> SessionAttachmentSnapshot? {
            attachments[attachmentID]
        }

        func message(for eventID: String) -> SessionMessageSnapshot? { messages[eventID] }
        func messageIsValid(_ eventID: String) -> Bool { messageValidity[eventID] == true }

        func contextCumulativeDeliveredBytes(for runID: String) -> Int? {
            cumulativeContextBytes[runID]
        }

        func recovery(at index: Int) -> RecoveryCoverage? { nil }
        func childState(for childID: String) -> String? { nil }

        func selectedBranchExtension(
            from previousTip: EventRef, to newTip: EventRef?
        ) -> [SessionMessageSnapshot]? {
            guard let newTip else { return nil }
            if previousTip == newTip { return [] }
            var current: EventRef? = newTip
            var visited = Set<String>()
            var result: [SessionMessageSnapshot] = []
            while let ref = current, ref != previousTip {
                guard ref.journal == scalarState.journal,
                      visited.insert(ref.eventID).inserted,
                      messageValidity[ref.eventID] == true,
                      let message = messages[ref.eventID] else { return nil }
                result.append(message)
                current = message.conversationParent
            }
            guard current == previousTip else { return nil }
            return result.reversed()
        }

        func visibleMessages(for tip: EventRef?) -> [SessionMessageSnapshot] {
            guard let tip else {
                return messageOrder.compactMap { messages[$0] }.filter(\.isPresentationVisible)
            }
            var current: EventRef? = tip
            var visited = Set<String>()
            var result: [SessionMessageSnapshot] = []
            while let ref = current, visited.insert(ref.eventID).inserted {
                guard let message = messages[ref.eventID] else { break }
                if message.isPresentationVisible { result.append(message) }
                current = message.conversationParent
            }
            return result.reversed()
        }

        mutating func stageScalar(_ continuation: BoundedSessionScalarContinuation) {
            scalarState = continuation
        }

        mutating func stageSeenEvent(_ event: TimelineEvent) {
            seen.insert(event.eventID)
            // Match InMemorySessionTransitionState exactly: physical-chain acceptance advances
            // the scalar continuation before the event-specific transition is evaluated.
            scalarState.lastEventID = event.eventID
            scalarState.lastSequence = max(scalarState.lastSequence, event.sequence)
        }

        mutating func stageAttachment(_ attachment: SessionAttachmentSnapshot) {
            let key = attachment.attachment.attachmentID
            if attachments[key] == nil,
               attachments.count >= maximumAuxiliaryRecords {
                exceededBounds = true
                return
            }
            attachments[key] = attachment
        }

        mutating func stageMessage(_ message: SessionMessageSnapshot) {
            if messages[message.eventID] == nil,
               messages.count >= maximumMessageRecords {
                exceededBounds = true
                return
            }
            let redacted = SessionMessageSnapshot(
                eventID: message.eventID, role: message.role,
                text: message.isPresentationVisible ? "x" : "",
                conversationParent: message.conversationParent,
                sourceEvent: message.sourceEvent, sourceCursor: message.sourceCursor)
            messages[message.eventID] = redacted
            messageOrder.append(message.eventID)
            if let parent = message.conversationParent {
                messageValidity[message.eventID] = parent.journal == scalarState.journal
                    && messages[parent.eventID] != nil
                    && messageValidity[parent.eventID] == true
            } else {
                messageValidity[message.eventID] = true
            }
        }

        mutating func stageContext(_ context: SessionContextContinuation) {
            contextState = context
        }

        mutating func stageContextCumulativeDeliveredBytes(_ bytes: Int, for runID: String) {
            if cumulativeContextBytes[runID] == nil,
               cumulativeContextBytes.count >= maximumAuxiliaryRecords {
                exceededBounds = true
                return
            }
            cumulativeContextBytes[runID] = bytes
        }

        mutating func stageCompaction(_ compaction: SessionCompactionContinuation) {
            var snapshot = SessionSnapshot()
            snapshot.compactionSummary = compaction.summary == nil ? nil : "recorded"
            snapshot.compactionBoundaryEventID = compaction.boundaryEventID
            compactionState = SessionCompactionContinuation(snapshot: snapshot)
        }

        mutating func stageVisibleMessages(_ messages: [SessionMessageSnapshot]) {}
        mutating func appendVisibleMessages(_ messages: [SessionMessageSnapshot]) {}
        mutating func recordVisibleProjectionFastPath() {}
        mutating func recordVisibleProjectionRebuild(scannedMessageCount: Int) {}
        mutating func stageRecovery(
            _ coverage: RecoveryCoverage, recorded: RecordedRecoveryCoverage
        ) {}
        mutating func stageChildState(_ state: String, for childID: String) {}

        mutating func stageUnknown(_ unknown: UnknownTimelineEvent) {
            scalarState.unknownDomains.formUnion(unknown.affectedDomains)
        }

        mutating func stageQuarantineOnly(_ event: TimelineEvent) {}

        mutating func stageQuarantine(
            _ event: TimelineEvent, reason: String, structural: Bool
        ) {
            if structural {
                scalarState.causalOrderValid = false
                scalarState.structuralIntegrityValid = false
            } else {
                scalarState.semanticProjectionValid = false
            }
        }
    }

    private struct ChunkObject: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let journal: JournalRef
        let sourceGeneration: String
        let ordinal: Int
        let records: [MessageRecord]
    }

    private struct ManifestBody: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let source: SourceProof
        let semanticTip: EventRef?
        let physicalEventCount: Int
        let indexedMessageCount: Int
        let selectedMessageCount: Int
        let sessionAttachments: [HistoryAttachmentRecord]
        let relationshipEvents: [HistoryRelationshipEventRecord]
        let chunks: [ChunkReference]
        let anchors: [PhysicalAnchor]
    }

    private struct Head: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let manifestObjectID: String
        let manifestByteCount: Int
        let manifestDigest: String
    }

    /// An immutable pointer for one exact physical frozen boundary.  The filename is also a
    /// digest of the key; the duplicated key here makes a copied or swapped pointer fail closed.
    private struct BoundaryHead: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let boundaryKey: String
        let manifestObjectID: String
        let manifestByteCount: Int
        let manifestDigest: String
    }

    /// Streaming cold builder. It retains bounded scalar/index metadata, never message text or
    /// `TimelineEvent` values. Duplicate identity and append-chain truth stay in the shared
    /// Session transition state rather than a second lifetime-sized builder set.
    public struct Builder: Sendable {
        private let index: PersistentSessionHistoryIndex
        private let session: SessionRef
        private let journal: JournalRef
        private let sourceGeneration: String
        private var previousEventID: String?
        private var nextSequence = 1
        private var nextByteStart = 0
        private var prefixDigest: String
        private var wirePrefixDigest: String
        private var physicalEventCount = 0
        private var messages: [String: MessageBuildRecord] = [:]
        private var anchors: [PhysicalAnchor] = []
        private var relationshipEvents: [HistoryRelationshipEventRecord] = []
        private var currentAttachmentEvents: [String: HistoryRelationshipEventRecord] = [:]
        private var semanticTip: EventRef?
        private var semantics: HistorySemanticState

        fileprivate init(
            index: PersistentSessionHistoryIndex,
            session: SessionRef,
            journal: JournalRef,
            sourceGeneration: String
        ) throws {
            guard journal.owner == .session(session),
                  PersistentSessionHistoryIndex.validIdentity(session.sessionID,
                      maximum: index.limits.maximumIdentityBytes),
                  PersistentSessionHistoryIndex.validIdentity(journal.journalID,
                      maximum: index.limits.maximumIdentityBytes),
                  PersistentSessionHistoryIndex.validRawDigest(sourceGeneration) else {
                throw Error.invalidIdentity
            }
            self.index = index
            self.session = session
            self.journal = journal
            self.sourceGeneration = sourceGeneration
            self.prefixDigest = DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal)
            self.wirePrefixDigest = PersistentSessionHistoryIndex.wirePrefixSeed(for: journal)
            self.semantics = HistorySemanticState(
                maximumMessageRecords: index.limits.maximumMessages,
                maximumAuxiliaryRecords: index.limits.maximumAuxiliaryRecords)
        }

        public mutating func append(
            event: TimelineEvent,
            row: DisposableTimelineProjectionStore.BucketRow
        ) throws {
            guard physicalEventCount < index.limits.maximumPhysicalEvents,
                  event.schemaVersion == TimelineEvent.currentSchemaVersion,
                  event.payloadVersion <= 1,
                  event.provenance == .native,
                  event.journal == journal,
                  event.session == nil || event.session == session,
                  event.sequence == nextSequence,
                  event.previousEventID == previousEventID,
                  event.evidenceLinkBoundsAreValid,
                  row.sequence == event.sequence,
                  row.eventID == event.eventID,
                  row.previousEventID == event.previousEventID,
                  row.byteStart == nextByteStart,
                  row.byteEnd > row.byteStart,
                  row.prefixDigestBefore == prefixDigest,
                  Self.validRow(row),
                  PersistentSessionHistoryIndex.validIdentity(
                    event.eventID, maximum: index.limits.maximumIdentityBytes) else {
                throw Error.chainMismatch
            }
            let expectedLine = try DisposableTimelineProjectionStore.canonicalEventLineDigest(event)
            let expectedPrefix = DisposableTimelineProjectionStore.advancePrefixDigest(
                prefixDigest, lineDigest: expectedLine)
            guard row.lineDigest == expectedLine,
                  row.prefixDigestAfter == expectedPrefix else {
                throw Error.checksumMismatch
            }
            SessionReducerTransition.apply(event, to: &semantics)
            guard semantics.isHistoryComplete else { throw Error.invalidRecord }
            if Self.isCreationRelationshipEvent(event)
                    || Self.isAttachmentStateEvent(event) {
                guard let relationship = Self.relationshipRecord(
                    event, row: row, sourceGeneration: sourceGeneration,
                    maximumIdentityBytes: index.limits.maximumIdentityBytes)
                else { throw Error.oversize }
                if Self.isCreationRelationshipEvent(event) {
                    guard relationshipEvents.count < index.limits.maximumAuxiliaryRecords else {
                        throw Error.oversize
                    }
                    relationshipEvents.append(relationship)
                }
                if Self.isAttachmentStateEvent(event),
                   let attachmentID = event.sessionAttachment?.attachmentID {
                    guard currentAttachmentEvents[attachmentID] != nil
                            || currentAttachmentEvents.count
                                < index.limits.maximumAuxiliaryRecords else {
                        throw Error.oversize
                    }
                    currentAttachmentEvents[attachmentID] = relationship
                }
            }
            let wireBefore = wirePrefixDigest
            let wireAfter = PersistentSessionHistoryIndex.advanceWirePrefix(
                wireBefore, lineDigest: expectedLine)
            if (event.sequence - 1).isMultiple(of: PersistentSessionHistoryIndex.anchorStride) {
                anchors.append(PhysicalAnchor(
                    cursor: JournalCursor(
                        journal: journal, eventID: event.eventID, sequence: event.sequence),
                    previousEventID: event.previousEventID,
                    byteStart: row.byteStart, byteEnd: row.byteEnd,
                    lineDigest: row.lineDigest,
                    prefixDigestBefore: row.prefixDigestBefore,
                    prefixDigestAfter: row.prefixDigestAfter,
                    wirePrefixDigestBefore: wireBefore,
                    wirePrefixDigestAfter: wireAfter))
            }

            if let message = SessionMessageSnapshot.canonicalMessage(from: event) {
                guard messages.count < index.limits.maximumMessages,
                      message.sourceCursor?.journal == journal,
                      message.sourceCursor?.eventID == event.eventID,
                      message.sourceCursor?.sequence == event.sequence,
                      message.sourceEvent?.journal == journal,
                      message.sourceEvent?.eventID == event.eventID,
                      message.conversationParent?.journal == nil
                        || message.conversationParent?.journal == journal,
                      PersistentSessionHistoryIndex.validIdentity(
                        message.role, maximum: index.limits.maximumIdentityBytes) else {
                    throw Error.invalidRecord
                }
                let conversationValid: Bool
                if let parent = message.conversationParent {
                    conversationValid = messages[parent.eventID]?.conversationValid == true
                } else {
                    conversationValid = true
                }
                let record = MessageRecord(
                    eventID: event.eventID,
                    previousEventID: event.previousEventID,
                    sourceCursor: JournalCursor(
                        journal: journal, eventID: event.eventID, sequence: event.sequence),
                    conversationParent: message.conversationParent,
                    role: message.role,
                    textDigest: PersistentSessionHistoryIndex.wireDigest(Data(message.text.utf8)),
                    textByteCount: message.text.utf8.count,
                    byteStart: row.byteStart, byteEnd: row.byteEnd,
                    lineDigest: row.lineDigest,
                    prefixDigestBefore: row.prefixDigestBefore,
                    prefixDigestAfter: row.prefixDigestAfter,
                    sourceGeneration: sourceGeneration)
                messages[event.eventID] = MessageBuildRecord(
                    record: record,
                    presentationVisible: message.isPresentationVisible,
                    conversationValid: conversationValid)
            }

            if event.type == TimelineEventType.sessionTipSelected {
                guard let tip = event.conversationParent,
                      tip.journal == journal,
                      messages[tip.eventID]?.conversationValid == true else {
                    throw Error.invalidBranch
                }
                semanticTip = tip
            }

            physicalEventCount += 1
            nextSequence += 1
            nextByteStart = row.byteEnd
            previousEventID = event.eventID
            prefixDigest = expectedPrefix
            wirePrefixDigest = wireAfter
        }

        public mutating func finalize(source: SourceProof) throws -> Manifest {
            guard source.session == session,
                  source.journal == journal,
                  source.sourceGeneration == sourceGeneration,
                  source.physicalCursor.journal == journal,
                  source.physicalCursor.sequence == physicalEventCount,
                  source.physicalCursor.eventID == previousEventID,
                  source.prefixByteCount == nextByteStart,
                  source.prefixDigest == prefixDigest,
                  source.wirePrefixDigest == wirePrefixDigest,
                  PersistentSessionHistoryIndex.validateSource(source,
                    maximumIdentityBytes: index.limits.maximumIdentityBytes) else {
                throw Error.sourceMismatch
            }
            let selected = try selectedBranch()
            var relationshipByEventID: [String: HistoryRelationshipEventRecord] = [:]
            for relationship in relationshipEvents {
                guard relationshipByEventID[relationship.event.eventID] == nil else {
                    throw Error.duplicateIdentity
                }
                relationshipByEventID[relationship.event.eventID] = relationship
            }
            for relationship in currentAttachmentEvents.values {
                relationshipByEventID[relationship.event.eventID] = relationship
            }
            let currentRelationshipEvents = relationshipByEventID.values.sorted {
                $0.cursor.sequence < $1.cursor.sequence
            }
            guard currentRelationshipEvents.count <= index.limits.maximumAuxiliaryRecords else {
                throw Error.oversize
            }
            return try index.publish(
                source: source, semanticTip: semanticTip,
                physicalEventCount: physicalEventCount,
                indexedMessageCount: messages.count,
                selected: selected, sessionAttachments: semantics.currentAttachments,
                relationshipEvents: currentRelationshipEvents,
                anchors: anchors)
        }

        /// History authority needs only the immutable Session-publication prefix. Later
        /// attachment cursor advances are normal turn/run bookkeeping, can be numerous, and do
        /// not establish a different Session-to-Work relationship. Retaining them here would
        /// both exhaust the bounded auxiliary index and incorrectly require creation-only
        /// capability evidence on ordinary cursor updates.
        private static func isCreationRelationshipEvent(_ event: TimelineEvent) -> Bool {
            switch event.type {
            case TimelineEventType.sessionCreated:
                return event.sequence == 1
            case TimelineEventType.sessionAttached:
                return event.sequence == 2
            case TimelineEventType.sessionAttachmentCursorAdvanced:
                // Only CreateSession's immutable publication record belongs here. The primary
                // Session can also emit an ordinary cursor advance at sequence three after its
                // first run; that runtime event has no publication command/capability envelope.
                return event.sequence == 3
                    && event.command != nil && event.idempotencyKey != nil
                    && event.client != nil && event.workHost != nil
                    && event.payload["capabilities"]?.arrayValue != nil
            default:
                return false
            }
        }

        /// The latest attach/detach transition for each bounded Session attachment is retained
        /// alongside the immutable publication prefix. JBS rereads these exact canonical rows
        /// before using the Session-to-Work relationship as current history authority.
        private static func isAttachmentStateEvent(_ event: TimelineEvent) -> Bool {
            (event.type == TimelineEventType.sessionAttached
                || event.type == TimelineEventType.sessionDetached)
                && event.sessionAttachment != nil
        }

        private static func relationshipRecord(
            _ event: TimelineEvent,
            row: DisposableTimelineProjectionStore.BucketRow,
            sourceGeneration: String,
            maximumIdentityBytes: Int
        ) -> HistoryRelationshipEventRecord? {
            guard let session = event.session else { return nil }
            guard PersistentSessionHistoryIndex.validIdentity(
                session.sessionID, maximum: maximumIdentityBytes) else { return nil }
            return HistoryRelationshipEventRecord(
                event: EventRef(journal: event.journal, eventID: event.eventID),
                cursor: JournalCursor(
                    journal: event.journal, eventID: event.eventID,
                    sequence: event.sequence),
                previousEventID: event.previousEventID,
                type: event.type, session: session,
                byteStart: row.byteStart, byteEnd: row.byteEnd,
                lineDigest: row.lineDigest,
                prefixDigestBefore: row.prefixDigestBefore,
                prefixDigestAfter: row.prefixDigestAfter,
                sourceGeneration: sourceGeneration)
        }

        private func selectedBranch() throws -> [MessageRecord] {
            guard let semanticTip else {
                return messages.values
                    .filter(\.presentationVisible)
                    .map(\.record)
                    .sorted { $0.sourceCursor.sequence < $1.sourceCursor.sequence }
            }
            var current: EventRef? = semanticTip
            var visited = Set<String>()
            var reversed: [MessageRecord] = []
            while let ref = current {
                guard ref.journal == journal,
                      visited.insert(ref.eventID).inserted,
                      let value = messages[ref.eventID],
                      value.conversationValid else {
                    throw Error.invalidBranch
                }
                if value.presentationVisible { reversed.append(value.record) }
                current = value.record.conversationParent
                guard visited.count <= messages.count else { throw Error.invalidBranch }
            }
            return reversed.reversed()
        }

        private static func validRow(
            _ row: DisposableTimelineProjectionStore.BucketRow
        ) -> Bool {
            row.sequence > 0 && row.sequence < Int.max
                && row.byteStart >= 0 && row.byteEnd > row.byteStart
                && PersistentSessionHistoryIndex.validRawDigest(row.lineDigest)
                && PersistentSessionHistoryIndex.validRawDigest(row.prefixDigestBefore)
                && PersistentSessionHistoryIndex.validRawDigest(row.prefixDigestAfter)
        }
    }

    public let directory: URL
    public let limits: Limits
    private let objectsDirectory: URL
    private let headURL: URL
    private let boundariesDirectory: URL
    private let beforeHeadPublication: @Sendable () throws -> Void

    public init(
        directory: URL,
        limits: Limits = .default,
        beforeHeadPublication: @escaping @Sendable () throws -> Void = {}
    ) throws {
        self.directory = directory.standardizedFileURL
        self.limits = limits
        self.objectsDirectory = self.directory.appending(
            path: "objects", directoryHint: .isDirectory)
        self.headURL = self.directory.appending(path: "HEAD", directoryHint: .notDirectory)
        self.boundariesDirectory = self.directory.appending(
            path: "boundaries", directoryHint: .isDirectory)
        self.beforeHeadPublication = beforeHeadPublication
        try Self.preparePrivateDirectory(self.directory)
        try Self.preparePrivateDirectory(self.objectsDirectory)
        try Self.preparePrivateDirectory(self.boundariesDirectory)
    }

    public func makeBuilder(
        session: SessionRef,
        journal: JournalRef,
        sourceGeneration: String
    ) throws -> Builder {
        try Builder(index: self, session: session, journal: journal,
                    sourceGeneration: sourceGeneration)
    }

    public func loadManifest(proving source: SourceProof) throws -> Manifest {
        let manifest = try loadManifest()
        guard manifest.source == source else { throw Error.sourceMismatch }
        return manifest
    }

    /// Load the immutable publication for an older frozen physical boundary.  `HEAD` is
    /// intentionally not consulted: it always denotes the newest publication and may have moved
    /// since a caller received its first page.
    public func loadManifest(
        provingFrozen source: SourceProof
    ) throws -> Manifest {
        try loadFrozenManifestWithMetrics(proving: source).manifest
    }

    /// Resolve a frozen publication from the evidence carried by the Work-service request.
    /// The caller does not need to know this host's source-generation or byte-range metadata;
    /// those remain inside the authenticated manifest and are returned only after the immutable
    /// boundary pointer proves the exact journal/cursor/wire-digest tuple.
    public func loadManifest(
        journal: JournalRef,
        frozenCursor: JournalCursor,
        frozenWirePrefixDigest: String
    ) throws -> Manifest {
        try loadFrozenManifestWithMetrics(
            journal: journal, cursor: frozenCursor,
            wirePrefixDigest: frozenWirePrefixDigest).manifest
    }

    public func loadManifest() throws -> Manifest {
        try loadLatestManifestWithMetrics().manifest
    }

    /// Quarantine the disposable publication pointers after an integrity failure.
    ///
    /// Immutable objects are disposable cache state too: a corrupt object must be removed before
    /// rebuilding, or a content-addressed write can collide with the damaged bytes. This operation
    /// is intentionally narrow and never removes the index root or recursively deletes an
    /// unexpected child directory.
    public func quarantineCache() throws {
        try removeCacheEntry(headURL)
        try removeCacheDirectoryContents(boundariesDirectory)
        try removeCacheDirectoryContents(objectsDirectory)
    }

    private func removeCacheDirectoryContents(_ url: URL) throws {
        guard directoryIsPrivateDirectory(url) else {
            throw Error.symlinkOrNonRegularFile
        }
        let entries: [URL]
        do {
            // Include hidden temporary files: an interrupted publication must not survive a
            // quarantine and collide with the next bounded rebuild.
            entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [])
        } catch {
            throw Error.ioFailure
        }
        for entry in entries {
            var status = stat()
            guard entry.path.withCString({ lstat($0, &status) }) == 0 else {
                throw Error.ioFailure
            }
            guard (status.st_mode & S_IFMT) == S_IFREG
                    || (status.st_mode & S_IFMT) == S_IFLNK else {
                throw Error.symlinkOrNonRegularFile
            }
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                throw Error.ioFailure
            }
        }
    }

    private struct LoadedManifest {
        let manifest: Manifest
        let metrics: MutableQueryMetrics
    }

    private func loadLatestManifestWithMetrics() throws -> LoadedManifest {
        let headData = try readPrivateFile(headURL, maximumBytes: limits.maximumHeadBytes)
        let head = try decode(Head.self, from: headData)
        guard head.schemaVersion == Self.schemaVersion,
              Self.validRawDigest(head.manifestObjectID),
              head.manifestObjectID == head.manifestDigest,
              head.manifestByteCount > 0,
              head.manifestByteCount <= limits.maximumManifestBytes else {
            throw Error.schemaMismatch
        }
        let manifest = try loadManifestObject(
            manifestObjectID: head.manifestObjectID,
            manifestByteCount: head.manifestByteCount,
            manifestDigest: head.manifestDigest)
        return LoadedManifest(
            manifest: manifest,
            metrics: MutableQueryMetrics(
                objectsRead: 2,
                bytesRead: headData.count + head.manifestByteCount,
                headBytesRead: headData.count,
                manifestBytesRead: head.manifestByteCount))
    }

    private func loadManifestObject(
        manifestObjectID: String,
        manifestByteCount: Int,
        manifestDigest: String
    ) throws -> Manifest {
        let data = try readObject(
            manifestObjectID, expectedBytes: manifestByteCount,
            maximumBytes: limits.maximumManifestBytes)
        guard Self.rawDigest(data) == manifestDigest else { throw Error.checksumMismatch }
        let body = try decode(ManifestBody.self, from: data)
        try validateManifestBody(body)
        return Manifest(
            source: body.source, semanticTip: body.semanticTip,
            physicalEventCount: body.physicalEventCount,
            indexedMessageCount: body.indexedMessageCount,
            selectedMessageCount: body.selectedMessageCount,
            sessionAttachments: body.sessionAttachments,
            relationshipEvents: body.relationshipEvents,
            chunks: body.chunks, anchors: body.anchors,
            manifestDigest: manifestDigest)
    }

    /// Return at most `limit` selected-branch records before the exclusive boundary. The manifest
    /// chunk table is itself the immutable selected-branch vector, so a fabricated or off-branch
    /// cursor is rejected by exact lookup rather than accepted because it is physically present.
    public func loadPage(
        proving source: SourceProof,
        semanticTip: EventRef?,
        before: JournalCursor? = nil,
        limit: Int
    ) throws -> Page {
        guard limit > 0, limit <= limits.maximumChunkMessages else { throw Error.oversize }
        // The first page follows the moving latest HEAD.  Every continuation is anchored to the
        // exact source proof returned with the earlier page, so later publications cannot retarget
        // it to a different branch or physical prefix.
        let loaded: LoadedManifest
        if before == nil {
            let latest = try loadLatestManifestWithMetrics()
            loaded = latest.manifest.source == source
                ? latest : try loadFrozenManifestWithMetrics(proving: source)
        } else {
            loaded = try loadFrozenManifestWithMetrics(proving: source)
        }
        let manifest = loaded.manifest
        let initialMetrics = loaded.metrics
        guard manifest.source == source else { throw Error.sourceMismatch }
        guard manifest.semanticTip == semanticTip else { throw Error.sourceMismatch }
        guard !manifest.chunks.isEmpty else {
            guard before == nil, manifest.selectedMessageCount == 0 else {
                throw Error.boundaryNotOnBranch
            }
            return Page(
                records: [], source: source, semanticTip: semanticTip,
                sessionAttachments: manifest.sessionAttachments,
                relationshipEvents: manifest.relationshipEvents,
                nextBeforeCursor: nil, hasOlder: false,
                metrics: initialMetrics.freeze())
        }

        var metrics = initialMetrics
        var chunkIndex: Int
        var exclusiveIndex: Int
        var boundaryChunk: ChunkObject?
        if let before {
            guard before.journal == source.journal,
                  before.sequence > 0,
                  before.sequence <= source.physicalCursor.sequence,
                  before.eventID != nil else { throw Error.invalidCursor }
            chunkIndex = try findChunk(
                containing: before, in: manifest.chunks, metrics: &metrics)
            let chunk = try loadChunk(
                manifest.chunks[chunkIndex], ordinal: chunkIndex,
                source: source, metrics: &metrics)
            guard let index = findRecord(containing: before, in: chunk, metrics: &metrics) else {
                throw Error.boundaryNotOnBranch
            }
            exclusiveIndex = index
            boundaryChunk = chunk
        } else {
            chunkIndex = manifest.chunks.count - 1
            exclusiveIndex = manifest.chunks[chunkIndex].messageCount
        }

        var newestFirst: [MessageRecord] = []
        let wanted = limit + 1
        var firstChunk = true
        while newestFirst.count < wanted, chunkIndex >= 0 {
            let reference = manifest.chunks[chunkIndex]
            let chunk: ChunkObject
            if firstChunk, let boundaryChunk {
                chunk = boundaryChunk
            } else {
                chunk = try loadChunk(
                    reference, ordinal: chunkIndex,
                    source: source, metrics: &metrics)
            }
            let upper = firstChunk ? exclusiveIndex : chunk.records.count
            if upper > 0 {
                for record in chunk.records[..<upper].reversed() {
                    metrics.branchEntriesExamined += 1
                    newestFirst.append(record)
                    if newestFirst.count == wanted { break }
                }
            }
            firstChunk = false
            chunkIndex -= 1
            exclusiveIndex = chunkIndex >= 0 ? manifest.chunks[chunkIndex].messageCount : 0
        }
        let hasOlder = newestFirst.count > limit
        if hasOlder { newestFirst.removeLast() }
        let records = newestFirst.reversed()
        let materialized = Array(records)
        return Page(
            records: materialized, source: source, semanticTip: semanticTip,
            sessionAttachments: manifest.sessionAttachments,
            relationshipEvents: manifest.relationshipEvents,
            nextBeforeCursor: hasOlder ? materialized.first?.sourceCursor : nil,
            hasOlder: hasOlder,
            metrics: QueryMetrics(
                objectsRead: metrics.objectsRead,
                bytesRead: metrics.bytesRead,
                chunksRead: metrics.chunksRead,
                branchEntriesExamined: metrics.branchEntriesExamined,
                boundaryEntriesExamined: metrics.boundaryEntriesExamined,
                boundaryRecordsExamined: metrics.boundaryRecordsExamined,
                headBytesRead: metrics.headBytesRead,
                manifestBytesRead: metrics.manifestBytesRead))
    }

    private func loadFrozenManifestWithMetrics(
        proving source: SourceProof
    ) throws -> LoadedManifest {
        let loaded = try loadFrozenManifestWithMetrics(
            journal: source.journal, cursor: source.physicalCursor,
            wirePrefixDigest: source.wirePrefixDigest)
        guard loaded.manifest.source == source else { throw Error.sourceMismatch }
        return loaded
    }

    private func loadFrozenManifestWithMetrics(
        journal: JournalRef,
        cursor: JournalCursor,
        wirePrefixDigest: String
    ) throws -> LoadedManifest {
        let key = try Self.boundaryKey(
            journal: journal, cursor: cursor,
            wirePrefixDigest: wirePrefixDigest)
        let pointerURL = boundariesDirectory.appending(
            path: key, directoryHint: .notDirectory)
        let pointerData = try readPrivateFile(pointerURL, maximumBytes: limits.maximumHeadBytes)
        let pointer = try decode(BoundaryHead.self, from: pointerData)
        guard pointer.schemaVersion == Self.schemaVersion,
              pointer.boundaryKey == key,
              pointer.manifestByteCount > 0,
              pointer.manifestByteCount <= limits.maximumManifestBytes,
              Self.validRawDigest(pointer.manifestObjectID),
              pointer.manifestObjectID == pointer.manifestDigest else {
            throw Error.schemaMismatch
        }
        let manifest = try loadManifestObject(
            manifestObjectID: pointer.manifestObjectID,
            manifestByteCount: pointer.manifestByteCount,
            manifestDigest: pointer.manifestDigest)
        guard manifest.source.journal == journal,
              manifest.source.physicalCursor == cursor,
              manifest.source.wirePrefixDigest == wirePrefixDigest else {
            throw Error.sourceMismatch
        }
        return LoadedManifest(
            manifest: manifest,
            metrics: MutableQueryMetrics(
                objectsRead: 2,
                bytesRead: pointerData.count + pointer.manifestByteCount,
                headBytesRead: pointerData.count,
                manifestBytesRead: pointer.manifestByteCount))
    }

    public func anchor(
        atOrBefore sequence: Int,
        proving source: SourceProof
    ) throws -> PhysicalAnchor? {
        let manifest = try loadManifest(provingFrozen: source)
        guard sequence > 0, sequence <= source.physicalCursor.sequence else {
            throw Error.invalidCursor
        }
        var low = 0
        var high = manifest.anchors.count
        while low < high {
            let mid = low + (high - low) / 2
            if manifest.anchors[mid].cursor.sequence <= sequence {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low == 0 ? nil : manifest.anchors[low - 1]
    }

    private func publish(
        source: SourceProof,
        semanticTip: EventRef?,
        physicalEventCount: Int,
        indexedMessageCount: Int,
        selected: [MessageRecord],
        sessionAttachments: [HistoryAttachmentRecord],
        relationshipEvents: [HistoryRelationshipEventRecord],
        anchors: [PhysicalAnchor]
    ) throws -> Manifest {
        var references: [ChunkReference] = []
        var offset = 0
        var ordinal = 0
        while offset < selected.count {
            var end = min(selected.count, offset + limits.maximumChunkMessages)
            var bytes: Data?
            while end > offset {
                let object = ChunkObject(
                    schemaVersion: Self.chunkSchemaVersion,
                    journal: source.journal,
                    sourceGeneration: source.sourceGeneration,
                    ordinal: ordinal,
                    records: Array(selected[offset..<end]))
                let candidate = try encode(object)
                if candidate.count <= limits.maximumChunkBytes,
                   candidate.count <= limits.maximumObjectBytes {
                    bytes = candidate
                    break
                }
                end -= 1
            }
            guard end > offset, let data = bytes,
                  let first = selected[offset..<end].first,
                  let last = selected[offset..<end].last else { throw Error.oversize }
            let objectID = try writeObject(data)
            references.append(ChunkReference(
                objectID: objectID, byteCount: data.count,
                messageCount: end - offset,
                firstCursor: first.sourceCursor,
                lastCursor: last.sourceCursor))
            offset = end
            ordinal += 1
        }
        let body = ManifestBody(
            schemaVersion: Self.schemaVersion,
            source: source, semanticTip: semanticTip,
            physicalEventCount: physicalEventCount,
            indexedMessageCount: indexedMessageCount,
            selectedMessageCount: selected.count,
            sessionAttachments: sessionAttachments,
            relationshipEvents: relationshipEvents,
            chunks: references, anchors: anchors)
        try validateManifestBody(body)
        let bodyData = try encode(body)
        guard bodyData.count <= limits.maximumManifestBytes else { throw Error.oversize }
        let manifestObjectID = try writeObject(bodyData)
        let head = Head(
            schemaVersion: Self.schemaVersion,
            manifestObjectID: manifestObjectID,
            manifestByteCount: bodyData.count,
            manifestDigest: manifestObjectID)
        // Boundary publication precedes the moving HEAD.  A crash can leave an unreachable
        // immutable candidate, but HEAD still points at the prior complete publication; callers
        // therefore either see the old index or rebuild, never a partially published boundary.
        try writeBoundary(
            source: source, manifestObjectID: manifestObjectID,
            manifestByteCount: bodyData.count, manifestDigest: manifestObjectID)
        try beforeHeadPublication()
        try writeHead(head)
        return Manifest(
            source: source, semanticTip: semanticTip,
            physicalEventCount: physicalEventCount,
            indexedMessageCount: indexedMessageCount,
            selectedMessageCount: selected.count,
            sessionAttachments: sessionAttachments,
            relationshipEvents: relationshipEvents,
            chunks: references, anchors: anchors,
            manifestDigest: manifestObjectID)
    }

    private func validateManifestBody(_ body: ManifestBody) throws {
        guard body.schemaVersion == Self.schemaVersion,
              Self.validateSource(body.source, maximumIdentityBytes: limits.maximumIdentityBytes),
              body.physicalEventCount == body.source.physicalCursor.sequence,
              body.indexedMessageCount >= body.selectedMessageCount,
              body.indexedMessageCount <= limits.maximumMessages,
              body.selectedMessageCount >= 0,
              body.selectedMessageCount <= limits.maximumMessages,
              body.sessionAttachments.count <= limits.maximumAuxiliaryRecords,
              body.relationshipEvents.count <= limits.maximumAuxiliaryRecords,
              body.chunks.count <= body.selectedMessageCount,
              body.anchors.count <= (body.physicalEventCount / Self.anchorStride) + 1,
              body.semanticTip?.journal == nil || body.semanticTip?.journal == body.source.journal else {
            throw Error.invalidSource
        }
        var attachmentIDs = Set<String>()
        var previousAttachmentID: String?
        for attachment in body.sessionAttachments {
            let attachmentID = attachment.attachment.attachmentID
            guard Self.validIdentity(
                    attachmentID, maximum: limits.maximumIdentityBytes),
                  Self.validIdentity(
                    attachment.work.workHostID, maximum: limits.maximumIdentityBytes),
                  Self.validIdentity(
                    attachment.work.workID, maximum: limits.maximumIdentityBytes),
                  attachmentIDs.insert(attachmentID).inserted,
                  previousAttachmentID.map({ $0 < attachmentID }) ?? true,
                  attachment.cursor.map({ cursor in
                    cursor.journal.owner == .work(attachment.work)
                        && cursor.journal.kind == .work
                        && cursor.journal.authority.authorityID
                            == attachment.work.workHostID
                        && Self.validIdentity(
                            cursor.journal.journalID,
                            maximum: limits.maximumIdentityBytes)
                        && (cursor.eventID.map({
                            Self.validIdentity(
                                $0, maximum: limits.maximumIdentityBytes)
                        }) ?? (cursor.sequence == 0))
                        && cursor.sequence >= 0
                        && cursor.sequence < Int.max
                        && (cursor.sequence == 0) == (cursor.eventID == nil)
                  }) ?? true else {
                throw Error.invalidSource
            }
            previousAttachmentID = attachmentID
        }
        var relationshipIDs = Set<String>()
        var previousRelationshipSequence = 0
        for relationship in body.relationshipEvents {
            let eventID = relationship.event.eventID
            guard relationship.event.journal == body.source.journal,
                  relationship.cursor.journal == body.source.journal,
                  relationship.cursor.eventID == eventID,
                  relationship.cursor.sequence > previousRelationshipSequence,
                  relationship.cursor.sequence <= body.source.physicalCursor.sequence,
                  relationship.session == body.source.session,
                  relationshipIDs.insert(eventID).inserted,
                  Self.validIdentity(eventID, maximum: limits.maximumIdentityBytes),
                  [TimelineEventType.sessionCreated,
                   TimelineEventType.sessionAttached,
                   TimelineEventType.sessionDetached,
                   TimelineEventType.sessionAttachmentCursorAdvanced]
                    .contains(relationship.type),
                  relationship.previousEventID.map({
                      Self.validIdentity($0, maximum: limits.maximumIdentityBytes)
                  }) ?? true,
                  relationship.byteStart >= 0,
                  relationship.byteEnd > relationship.byteStart,
                  relationship.byteEnd <= body.source.prefixByteCount,
                  relationship.byteEnd - relationship.byteStart
                    <= limits.maximumObjectBytes,
                  Self.validRawDigest(relationship.lineDigest),
                  Self.validRawDigest(relationship.prefixDigestBefore),
                  Self.validRawDigest(relationship.prefixDigestAfter),
                  relationship.sourceGeneration == body.source.sourceGeneration,
                  Self.validRelationshipShape(relationship) else {
                throw Error.invalidSource
            }
            previousRelationshipSequence = relationship.cursor.sequence
        }
        var count = 0
        var previous: JournalCursor?
        for reference in body.chunks {
            guard Self.validRawDigest(reference.objectID),
                  reference.byteCount > 0,
                  reference.byteCount <= limits.maximumChunkBytes,
                  reference.messageCount > 0,
                  reference.messageCount <= limits.maximumChunkMessages,
                  reference.firstCursor.journal == body.source.journal,
                  reference.lastCursor.journal == body.source.journal,
                  reference.firstCursor.sequence <= reference.lastCursor.sequence,
                  previous.map({ $0.sequence < reference.firstCursor.sequence }) ?? true else {
                throw Error.invalidBranch
            }
            count += reference.messageCount
            previous = reference.lastCursor
        }
        guard count == body.selectedMessageCount else { throw Error.invalidBranch }
        if body.selectedMessageCount == 0 {
            guard body.chunks.isEmpty else { throw Error.invalidBranch }
        } else {
            guard body.chunks.last != nil else { throw Error.invalidBranch }
        }
        var previousAnchorSequence = 0
        var previousAnchorByteEnd = 0
        for anchor in body.anchors {
            guard anchor.cursor.journal == body.source.journal,
                  anchor.cursor.eventID != nil,
                  (anchor.cursor.sequence - 1).isMultiple(of: Self.anchorStride),
                  (previousAnchorSequence == 0
                    ? anchor.cursor.sequence == 1
                    : anchor.cursor.sequence == previousAnchorSequence + Self.anchorStride),
                  anchor.cursor.sequence > previousAnchorSequence,
                  anchor.cursor.sequence <= body.source.physicalCursor.sequence,
                  anchor.byteStart >= 0, anchor.byteEnd > anchor.byteStart,
                  anchor.byteStart >= previousAnchorByteEnd,
                  anchor.byteEnd <= body.source.prefixByteCount,
                  anchor.previousEventID.map({
                    Self.validIdentity($0, maximum: limits.maximumIdentityBytes)
                  }) ?? true,
                  Self.validRawDigest(anchor.lineDigest),
                  Self.validRawDigest(anchor.prefixDigestBefore),
                  Self.validRawDigest(anchor.prefixDigestAfter),
                  Self.validWireDigest(anchor.wirePrefixDigestBefore),
                  Self.validWireDigest(anchor.wirePrefixDigestAfter),
                  DisposableTimelineProjectionStore.advancePrefixDigest(
                    anchor.prefixDigestBefore, lineDigest: anchor.lineDigest)
                    == anchor.prefixDigestAfter,
                  Self.advanceWirePrefix(
                    anchor.wirePrefixDigestBefore, lineDigest: anchor.lineDigest)
                    == anchor.wirePrefixDigestAfter else {
                throw Error.invalidSource
            }
            previousAnchorSequence = anchor.cursor.sequence
            previousAnchorByteEnd = anchor.byteEnd
        }
        if body.physicalEventCount == 0 {
            guard body.anchors.isEmpty else { throw Error.invalidSource }
        } else {
            guard body.anchors.first?.cursor.sequence == 1 else {
                throw Error.invalidSource
            }
        }
    }

    private func writeBoundary(
        source: SourceProof,
        manifestObjectID: String,
        manifestByteCount: Int,
        manifestDigest: String
    ) throws {
        let key = try Self.boundaryKey(
            journal: source.journal, cursor: source.physicalCursor,
            wirePrefixDigest: source.wirePrefixDigest)
        let boundary = BoundaryHead(
            schemaVersion: Self.schemaVersion, boundaryKey: key,
            manifestObjectID: manifestObjectID,
            manifestByteCount: manifestByteCount, manifestDigest: manifestDigest)
        let data = try encode(boundary)
        guard data.count <= limits.maximumHeadBytes else { throw Error.oversize }
        let url = boundariesDirectory.appending(path: key, directoryHint: .notDirectory)

        // Never use replaceItem here: a boundary is immutable once published.  In particular,
        // a same-key/different-branch publication must not silently retarget old continuations.
        var existingStatus = stat()
        if url.path.withCString({ lstat($0, &existingStatus) }) == 0 {
            let existing = try readPrivateFile(url, maximumBytes: limits.maximumHeadBytes)
            guard existing == data else { throw Error.sourceMismatch }
            return
        }
        let temporary = boundariesDirectory.appending(
            path: ".boundary-\(UUID().uuidString.lowercased())", directoryHint: .notDirectory)
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try Self.setPrivateFilePermissions(temporary)
            do {
                try FileManager.default.moveItem(at: temporary, to: url)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                try? FileManager.default.removeItem(at: temporary)
                let existing = try readPrivateFile(url, maximumBytes: limits.maximumHeadBytes)
                guard existing == data else { throw Error.sourceMismatch }
            }
        } catch let error as Error {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw Error.ioFailure
        }
    }

    private func findChunk(
        containing cursor: JournalCursor,
        in references: [ChunkReference],
        metrics: inout MutableQueryMetrics
    ) throws -> Int {
        var low = 0
        var high = references.count
        while low < high {
            let mid = low + (high - low) / 2
            metrics.boundaryEntriesExamined += 1
            if references[mid].lastCursor.sequence < cursor.sequence {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < references.count,
              references[low].firstCursor.sequence <= cursor.sequence else {
            throw Error.boundaryNotOnBranch
        }
        return low
    }

    private func findRecord(
        containing cursor: JournalCursor,
        in chunk: ChunkObject,
        metrics: inout MutableQueryMetrics
    ) -> Int? {
        var low = 0
        var high = chunk.records.count
        while low < high {
            let mid = low + (high - low) / 2
            metrics.boundaryRecordsExamined += 1
            if chunk.records[mid].sourceCursor.sequence < cursor.sequence {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < chunk.records.count,
              chunk.records[low].sourceCursor == cursor else { return nil }
        return low
    }

    private struct MutableQueryMetrics {
        var objectsRead: Int
        var bytesRead: Int
        var chunksRead: Int
        var branchEntriesExamined: Int
        var boundaryEntriesExamined: Int
        var boundaryRecordsExamined: Int
        var headBytesRead: Int
        var manifestBytesRead: Int

        init(objectsRead: Int = 0, bytesRead: Int = 0, chunksRead: Int = 0,
             branchEntriesExamined: Int = 0, boundaryEntriesExamined: Int = 0,
             boundaryRecordsExamined: Int = 0, headBytesRead: Int = 0,
             manifestBytesRead: Int = 0) {
            self.objectsRead = objectsRead
            self.bytesRead = bytesRead
            self.chunksRead = chunksRead
            self.branchEntriesExamined = branchEntriesExamined
            self.boundaryEntriesExamined = boundaryEntriesExamined
            self.boundaryRecordsExamined = boundaryRecordsExamined
            self.headBytesRead = headBytesRead
            self.manifestBytesRead = manifestBytesRead
        }

        func freeze() -> QueryMetrics {
            QueryMetrics(
                objectsRead: objectsRead, bytesRead: bytesRead,
                chunksRead: chunksRead, branchEntriesExamined: branchEntriesExamined,
                boundaryEntriesExamined: boundaryEntriesExamined,
                boundaryRecordsExamined: boundaryRecordsExamined,
                headBytesRead: headBytesRead, manifestBytesRead: manifestBytesRead)
        }
    }

    private func loadChunk(
        _ reference: ChunkReference,
        ordinal: Int,
        source: SourceProof,
        metrics: inout MutableQueryMetrics
    ) throws -> ChunkObject {
        let data = try readObject(
            reference.objectID, expectedBytes: reference.byteCount,
            maximumBytes: limits.maximumChunkBytes)
        metrics.objectsRead += 1
        metrics.bytesRead += data.count
        metrics.chunksRead += 1
        let chunk = try decode(ChunkObject.self, from: data)
        guard chunk.schemaVersion == Self.chunkSchemaVersion,
              chunk.journal == source.journal,
              chunk.sourceGeneration == source.sourceGeneration,
              chunk.ordinal == ordinal,
              chunk.records.count == reference.messageCount,
              chunk.records.first?.sourceCursor == reference.firstCursor,
              chunk.records.last?.sourceCursor == reference.lastCursor else {
            throw Error.invalidBranch
        }
        var previous: JournalCursor?
        for record in chunk.records {
            guard record.sourceCursor.journal == source.journal,
                  record.sourceCursor.eventID == record.eventID,
                  record.sourceCursor.sequence > 0,
                  record.sourceCursor.sequence <= source.physicalCursor.sequence,
                  previous.map({ $0.sequence < record.sourceCursor.sequence }) ?? true,
                  record.conversationParent?.journal == nil
                    || record.conversationParent?.journal == source.journal,
                  Self.validIdentity(record.eventID, maximum: limits.maximumIdentityBytes),
                  Self.validIdentity(record.role, maximum: limits.maximumIdentityBytes),
                  Self.validWireDigest(record.textDigest), record.textByteCount >= 0,
                  record.byteStart >= 0, record.byteEnd > record.byteStart,
                  Self.validRawDigest(record.lineDigest),
                  Self.validRawDigest(record.prefixDigestBefore),
                  Self.validRawDigest(record.prefixDigestAfter),
                  record.sourceGeneration == source.sourceGeneration else {
                throw Error.invalidRecord
            }
            previous = record.sourceCursor
        }
        return chunk
    }

    private func writeObject(_ data: Data) throws -> String {
        guard data.count <= limits.maximumObjectBytes else { throw Error.oversize }
        let objectID = Self.rawDigest(data)
        let url = objectsDirectory.appending(path: objectID, directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try readPrivateFile(url, maximumBytes: limits.maximumObjectBytes)
            guard existing == data else { throw Error.checksumMismatch }
            return objectID
        }
        let temporary = objectsDirectory.appending(
            path: ".tmp-\(UUID().uuidString.lowercased())", directoryHint: .notDirectory)
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try Self.setPrivateFilePermissions(temporary)
            do {
                try FileManager.default.moveItem(at: temporary, to: url)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                try? FileManager.default.removeItem(at: temporary)
                let existing = try readPrivateFile(url, maximumBytes: limits.maximumObjectBytes)
                guard existing == data else { throw Error.checksumMismatch }
            }
        } catch let error as Error {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw Error.ioFailure
        }
        return objectID
    }

    private func writeHead(_ head: Head) throws {
        let data = try encode(head)
        guard data.count <= limits.maximumHeadBytes else { throw Error.oversize }
        let temporary = directory.appending(
            path: ".HEAD-\(UUID().uuidString.lowercased())", directoryHint: .notDirectory)
        do {
            var destinationStatus = stat()
            if headURL.path.withCString({ lstat($0, &destinationStatus) }) == 0 {
                guard (destinationStatus.st_mode & S_IFMT) == S_IFREG,
                      destinationStatus.st_uid == geteuid(),
                      (destinationStatus.st_mode & mode_t(0o777)) == mode_t(0o600) else {
                    throw Error.symlinkOrNonRegularFile
                }
            } else if errno != ENOENT {
                throw Error.ioFailure
            }
            let descriptor = temporary.path.withCString {
                open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            }
            guard descriptor >= 0 else { throw Error.ioFailure }
            do {
                try data.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    var offset = 0
                    while offset < raw.count {
                        let count = write(descriptor, base.advanced(by: offset), raw.count - offset)
                        if count > 0 { offset += count }
                        else if count < 0, errno == EINTR { continue }
                        else { throw Error.ioFailure }
                    }
                }
                guard fsync(descriptor) == 0 else { throw Error.ioFailure }
            } catch {
                _ = AviaryPOSIX.close(descriptor)
                throw error
            }
            guard AviaryPOSIX.close(descriptor) == 0 else { throw Error.ioFailure }
            guard rename(temporary.path, headURL.path) == 0 else { throw Error.ioFailure }
            try Self.synchronizeDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let error = error as? Error { throw error }
            throw Error.ioFailure
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw Error.ioFailure }
        defer { _ = AviaryPOSIX.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Error.ioFailure }
    }

    private func readObject(
        _ objectID: String,
        expectedBytes: Int,
        maximumBytes: Int
    ) throws -> Data {
        guard Self.validRawDigest(objectID), expectedBytes > 0,
              expectedBytes <= maximumBytes else { throw Error.invalidRecord }
        let data = try readPrivateFile(
            objectsDirectory.appending(path: objectID, directoryHint: .notDirectory),
            maximumBytes: maximumBytes)
        guard data.count == expectedBytes,
              Self.rawDigest(data) == objectID else { throw Error.checksumMismatch }
        return data
    }

    private static func boundaryKey(
        journal: JournalRef,
        cursor: JournalCursor,
        wirePrefixDigest: String
    ) throws -> String {
        guard cursor.journal == journal,
              cursor.sequence >= 0, cursor.sequence < Int.max,
              (cursor.sequence == 0 ? cursor.eventID == nil : cursor.eventID != nil),
              validWireDigest(wirePrefixDigest) else {
            throw Error.invalidSource
        }
        var material = Data("session-history-boundary-v1\u{0}".utf8)
        material.append(Data(journal.stableKey.utf8))
        material.append(0)
        material.append(Data(String(cursor.sequence).utf8))
        material.append(0)
        material.append(Data((cursor.eventID ?? "").utf8))
        material.append(0)
        material.append(Data(wirePrefixDigest.utf8))
        return rawDigest(material)
    }

    private func readPrivateFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let path = url.standardizedFileURL.path
        let descriptor = path.withCString { AviaryPOSIX.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw Error.symlinkOrNonRegularFile }
            throw Error.missingObject
        }
        defer { _ = AviaryPOSIX.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= off_t(maximumBytes),
              (status.st_mode & 0o077) == 0 else {
            if (status.st_mode & 0o077) != 0 { throw Error.insecurePermissions }
            throw Error.oversize
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            let expected = Int(status.st_size)
            let data = try handle.read(upToCount: expected + 1) ?? Data()
            guard data.count == expected else { throw Error.ioFailure }
            return data
        } catch let error as Error {
            throw error
        } catch {
            throw Error.ioFailure
        }
    }

    private func removeCacheEntry(_ url: URL) throws {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        guard result == 0 || errno == ENOENT else { throw Error.ioFailure }
        guard result == 0 else { return }
        guard (status.st_mode & S_IFMT) == S_IFREG
                || (status.st_mode & S_IFMT) == S_IFLNK else {
            throw Error.symlinkOrNonRegularFile
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw Error.ioFailure
        }
    }

    private func directoryIsPrivateDirectory(_ url: URL) -> Bool {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & 0o077) == 0 else {
            return false
        }
        return true
    }

    private static func preparePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var status = stat()
        if url.path.withCString({ lstat($0, &status) }) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                throw Error.symlinkOrNonRegularFile
            }
            guard (status.st_mode & 0o077) == 0 else { throw Error.insecurePermissions }
            return
        }
        do {
            try fm.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw Error.ioFailure
        }
    }

    private static func setPrivateFilePermissions(_ url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path)
        } catch {
            throw Error.ioFailure
        }
    }

    private static func validateSource(
        _ source: SourceProof,
        maximumIdentityBytes: Int
    ) -> Bool {
        source.journal.owner == .session(source.session)
            && source.physicalCursor.journal == source.journal
            && source.physicalCursor.sequence >= 0
            && source.physicalCursor.sequence < Int.max
            && (source.physicalCursor.sequence == 0
                ? source.physicalCursor.eventID == nil : source.physicalCursor.eventID != nil)
            && source.prefixByteCount >= 0
            && validIdentity(source.session.sessionID, maximum: maximumIdentityBytes)
            && validIdentity(source.journal.journalID, maximum: maximumIdentityBytes)
            && validIdentity(source.sourceID, maximum: maximumIdentityBytes)
            && validRawDigest(source.sourceGeneration)
            && validRawDigest(source.sourceFingerprint)
            && validRawDigest(source.prefixDigest)
            && validWireDigest(source.wirePrefixDigest)
    }

    private static func validIdentity(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }

    private static func validRawDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x66)
        }
    }

    private static func validWireDigest(_ value: String) -> Bool {
        value.hasPrefix("sha256:") && validRawDigest(String(value.dropFirst(7)))
    }

    private static func validRelationshipShape(
        _ value: HistoryRelationshipEventRecord
    ) -> Bool {
        switch value.type {
        case TimelineEventType.sessionCreated:
            return value.cursor.sequence == 1
        case TimelineEventType.sessionAttached:
            return value.cursor.sequence >= 2
        case TimelineEventType.sessionDetached:
            return value.cursor.sequence >= 3
        case TimelineEventType.sessionAttachmentCursorAdvanced:
            return value.cursor.sequence == 3
        default:
            return false
        }
    }

    private static func rawDigest(_ data: Data) -> String {
        AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func wireDigest(_ data: Data) -> String {
        "sha256:" + rawDigest(data)
    }

    public static func wirePrefixSeed(for journal: JournalRef) -> String {
        wireDigest(Data("aviary-prefix-v1\u{0}seed\u{0}\(journal.stableKey)".utf8))
    }

    public static func advanceWirePrefix(_ prefix: String, lineDigest: String) -> String {
        var material = Data("aviary-prefix-v1\u{0}".utf8)
        material.append(Data(prefix.utf8))
        material.append(0)
        material.append(Data(lineDigest.utf8))
        return wireDigest(material)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(value) }
        catch { throw Error.invalidRecord }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw Error.invalidRecord }
    }
}
