import Foundation

/// An exact, copy-on-write Session reducer continuation backed by the persistent radix map.
///
/// The map stores the continuation facts and the bounded typed slots needed by the next Session
/// event. Message and compaction bodies are intentionally not durable: their digest, size, and
/// presentation bit are enough to authenticate branch selection while the canonical journal (and
/// the bounded projection head) remains the source for presentation text. A state instance may
/// retain bodies in memory for differential tests and for the current event only; reopening it
/// never recovers those bodies from the map.
public struct PersistentSessionExactState: Sendable {
    public static let schemaVersion = 1
    public static let maximumIdentityBytes = 1_024
    /// One event's typed dependency footprint is finite. Message ancestry validity is carried by
    /// each authenticated record, so semantic-tip legality does not turn this into a history walk.
    public static let maximumOperationSlots = 128

    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case missingScalar
        case invalidRecord
        case duplicateEvent(String)
        case tooManyPrefetchedSlots
        case map(PersistentProjectionRadixMap.MapError)

        public var errorDescription: String? {
            switch self {
            case .missingScalar: return "Persistent Session exact state has no scalar continuation."
            case .invalidRecord: return "Persistent Session exact state contains an invalid typed record."
            case .duplicateEvent(let id): return "Persistent Session event was already observed: \(id)."
            case .tooManyPrefetchedSlots:
                return "Persistent Session exact-state prefetch exceeds its bound."
            case .map(let error): return error.localizedDescription
            }
        }
    }

    public struct ApplyResult: Hashable, Sendable {
        public let previousRoot: PersistentProjectionRadixMap.Root?
        public let root: PersistentProjectionRadixMap.Root
        /// This is an event-local view. On a cold reopen, message bodies are redacted and only
        /// the ancestry needed by the incoming event is materialized.
        public let eventLocalSnapshot: SessionSnapshot
        public let changedSlots: [String]
        public let lastMutationMetrics: PersistentProjectionRadixMap.Metrics

        fileprivate init(
            previousRoot: PersistentProjectionRadixMap.Root?,
            root: PersistentProjectionRadixMap.Root,
            eventLocalSnapshot: SessionSnapshot,
            changedSlots: [String],
            lastMutationMetrics: PersistentProjectionRadixMap.Metrics
        ) {
            self.previousRoot = previousRoot
            self.root = root
            self.eventLocalSnapshot = eventLocalSnapshot
            self.changedSlots = changedSlots
            self.lastMutationMetrics = lastMutationMetrics
        }
    }

    private static let scalarKey = "session-exact-v1/scalar"
    private let map: PersistentProjectionRadixMap
    private var root: PersistentProjectionRadixMap.Root?
    private var lastSnapshot: SessionSnapshot
    /// These are deliberately non-persistent. They make same-process differential checks useful
    /// without turning typed map values into a second transcript store.
    private var ephemeralMessageBodies: [String: String]
    private var ephemeralCompactionSummaries: [String: String]

    public var currentRoot: PersistentProjectionRadixMap.Root? { root }
    public var eventLocalSnapshot: SessionSnapshot { lastSnapshot }

    public init(
        map: PersistentProjectionRadixMap,
        root: PersistentProjectionRadixMap.Root? = nil
    ) throws {
        guard case .session = map.journal.owner else { throw Error.invalidRecord }
        self.map = map
        self.root = root
        self.ephemeralMessageBodies = [:]
        self.ephemeralCompactionSummaries = [:]
        if let root {
            guard let scalar: ScalarRecord = try Self.read(
                map: map, root: root, key: Self.scalarKey) else {
                throw Error.missingScalar
            }
            try scalar.validate(scope: map.journal)
            var snapshot = Self.scalarSnapshot(scalar)
            if let id = scalar.lastUnknownEventID {
                guard let record: UnknownRecord = try Self.read(
                    map: map, root: root, key: Self.slotKey(kind: "unknown", identity: id)) else {
                    throw Error.invalidRecord
                }
                try Self.validateUnknownRecord(
                    record, scope: map.journal, maxSequence: scalar.lastSequence, expectedID: id)
            }
            if let id = scalar.lastQuarantineEventID {
                guard let record: QuarantineRecord = try Self.read(
                    map: map, root: root, key: Self.slotKey(kind: "quarantine", identity: id)) else {
                    throw Error.invalidRecord
                }
                try Self.validateQuarantineRecord(
                    record, scope: map.journal, expectedID: id)
            }
            if let context: ContextRecord = try Self.read(
                map: map, root: root, key: Self.contextKey) {
                guard context.kind == "context", context.scope == map.journal.stableKey else {
                    throw Error.invalidRecord
                }
                try context.validate(scope: map.journal)
                context.continuation.apply(to: &snapshot)
            }
            if let compaction: CompactionRecord = try Self.read(
                map: map, root: root, key: Self.compactionKey) {
                guard compaction.kind == "compaction",
                      compaction.scope == map.journal.stableKey,
                      compaction.summaryByteCount >= 0,
                      Self.isCanonicalDigest(compaction.summaryDigest),
                      !compaction.boundaryEventID.isEmpty else {
                    throw Error.invalidRecord
                }
                // The durable slot carries only a digest. Do not put that digest into the
                // public String summary field on reopen: callers could mistake it for the raw
                // compaction prose. The current compaction event may expose its in-memory body
                // through the event-local overlay, but a reopen is intentionally metadata-only.
                snapshot.compactionBoundaryEventID = compaction.boundaryEventID
            }
            self.lastSnapshot = snapshot
        } else {
            self.lastSnapshot = SessionSnapshot()
        }
    }

    /// Applies one canonical event. Reads are completed before the nonthrowing transition enters
    /// its event-local overlay. The caller's root is changed only after every typed write and the
    /// affected typed paths have validated successfully. Publication performs a full reachable-
    /// object audit while the projection-store commit is still unpublished.
    public mutating func apply(_ event: TimelineEvent) throws -> ApplyResult {
        try Self.validateIncomingIdentities(event)
        let previousRoot = root
        let scalar = try loadScalar()
        let prefetched = try Prefetch(
            map: map, root: root, event: event, scalar: scalar)
        guard prefetched.seen == nil else { throw Error.duplicateEvent(event.eventID) }

        var overlay = EventLocalOverlay(
            scalar: scalar,
            scope: map.journal.stableKey,
            seenRecords: prefetched.seenRecords,
            attachments: prefetched.attachments,
            messages: prefetched.messages,
            contexts: prefetched.contexts,
            cumulative: prefetched.cumulative,
            compaction: prefetched.compaction,
            recoveries: prefetched.recoveries,
            children: prefetched.children,
            unknowns: prefetched.unknowns,
            quarantines: prefetched.quarantines,
            messageBodies: ephemeralMessageBodies,
            compactionSummaries: ephemeralCompactionSummaries)
        overlay.currentEventRunID = event.run?.runID
        // A reopened source observation retains only its fingerprint. If the next assembled
        // crossing carries the same canonical source list, make that list available to the shared
        // transition in memory; it is re-sanitized when the resulting context slot is encoded.
        if event.type == TimelineEventType.contextAssembled,
           let contextRecord = overlay.contexts,
           let components = decodeContextComponents(event.payload),
           let manifest = decodeContextManifest(event.payload, components: components),
           let sources = manifest.systemPromptSources,
           contextRecord.promptSourcesFingerprint == Self.digestPromptSources(sources) {
            overlay.ephemeralContext = contextRecord.continuation(withPromptSources: sources)
        }
        let before = overlay.snapshot
        SessionReducerTransition.apply(event, to: &overlay)
        guard !overlay.invalidMutation else { throw Error.invalidRecord }
        try overlay.scalarRecord.validate(scope: map.journal)
        let after = overlay.snapshot
        let changedKeys = Self.changedKeys(
            event: event, before: before, after: after, overlay: overlay)
        guard changedKeys.count <= Self.maximumOperationSlots else {
            throw Error.tooManyPrefetchedSlots
        }

        // The shared transition is deliberately non-throwing and therefore cannot validate the
        // encoded representation it just staged. Authenticate every changed typed value before
        // touching the candidate root; a malformed value must leave the prior root publishable
        // and must not defer failure until a later bounded prefetch or reopen.
        try overlay.validateChangedRecords(changedKeys, scope: map.journal)

        var nextRoot = root
        var finalMetrics: PersistentProjectionRadixMap.Metrics?
        do {
            let scalarWrite = try write(scalar: overlay.scalarRecord)
            nextRoot = scalarWrite.newRoot
            finalMetrics = scalarWrite.metrics
            for key in changedKeys {
                if key == Self.scalarKey { continue }
                guard let value = try overlay.encodedValue(for: key) else { continue }
                let result = try map.setting(root: nextRoot, key: key, value: value)
                nextRoot = result.newRoot
                finalMetrics = result.metrics
            }
            guard let finalRoot = nextRoot else { throw Error.invalidRecord }
            // `setting` has already authenticated every rewritten radix path. The publication
            // boundary performs the full reachable-object audit; doing that walk here would make
            // a long Session pay for historical objects on every event.
            root = finalRoot
            // Keep only the dependency footprint that was just authenticated. This preserves
            // same-process differential usefulness without allowing raw bodies to grow with the
            // lifetime of a Session exact-state object.
            let messageIDs = Set(overlay.messages.keys)
            ephemeralMessageBodies = overlay.messageBodies.filter { messageIDs.contains($0.key) }
            if let compaction = overlay.compactionRecord,
               let summary = overlay.compactionSummaries[compaction.boundaryEventID] {
                ephemeralCompactionSummaries = [compaction.boundaryEventID: summary]
            } else {
                ephemeralCompactionSummaries = [:]
            }
            lastSnapshot = after
            return ApplyResult(
                previousRoot: previousRoot, root: finalRoot,
                eventLocalSnapshot: after, changedSlots: changedKeys,
                lastMutationMetrics: finalMetrics ?? scalarWrite.metrics)
        } catch let error as Error {
            throw error
        } catch let error as PersistentProjectionRadixMap.MapError {
            throw Error.map(error)
        } catch {
            throw Error.invalidRecord
        }
    }

    private func loadScalar() throws -> ScalarRecord {
        if root == nil { return ScalarRecord.empty(journal: map.journal) }
        guard let scalar: ScalarRecord = try Self.read(
            map: map, root: root, key: Self.scalarKey) else {
            throw Error.missingScalar
        }
        try scalar.validate(scope: map.journal)
        return scalar
    }

    private func write(
        scalar: ScalarRecord
    ) throws -> PersistentProjectionRadixMap.TransactionResult {
        try map.setting(root: root, key: Self.scalarKey, value: Self.encode(scalar))
    }

    private static func changedKeys(
        event: TimelineEvent,
        before: SessionSnapshot,
        after: SessionSnapshot,
        overlay: EventLocalOverlay
    ) -> [String] {
        var keys = [scalarKey]
        if after.seenEventIDs.count > before.seenEventIDs.count {
            keys.append(slotKey(kind: "seen", identity: event.eventID))
        }
        if let attachment = event.sessionAttachment,
           overlay.attachments[attachment.attachmentID] != nil,
           before.attachments[attachment.attachmentID]
               != after.attachments[attachment.attachmentID] {
            keys.append(slotKey(kind: "attachment", identity: attachment.attachmentID))
        }
        if (event.type == TimelineEventType.inputAccepted
            || event.type == TimelineEventType.messageCommitted),
           overlay.messages[event.eventID] != nil {
            keys.append(slotKey(kind: "message", identity: event.eventID))
        }
        if overlay.didStageContext {
            keys.append(contextKey)
        }
        for runID in overlay.changedCumulativeRunIDs {
            if overlay.cumulative[runID] != nil {
                keys.append(slotKey(kind: "cumulative", identity: runID))
            }
        }
        if overlay.didStageCompaction { keys.append(compactionKey) }
        if overlay.didStageRecovery {
            keys.append(slotKey(kind: "recovery", identity: event.eventID))
        }
        if let childID = overlay.changedChildID {
            keys.append(slotKey(kind: "child", identity: childID))
        }
        if after.unknownEvents.count > before.unknownEvents.count,
           let id = overlay.unknownRecords.last?.eventID {
            keys.append(slotKey(kind: "unknown", identity: id))
        }
        if after.quarantinedEvents.count > before.quarantinedEvents.count,
           let id = overlay.quarantineRecords.last?.eventID {
            keys.append(slotKey(kind: "quarantine", identity: id))
        }
        return Array(Set(keys)).sorted()
    }

    private static let contextKey = "session-exact-v1/context"
    private static let compactionKey = "session-exact-v1/compaction"

    private static func slotKey(kind: String, identity: String) -> String {
        let material = "session-exact-slot-v1\0\(kind.count):\(kind)\0\(identity.utf8.count):\(identity)"
        return "session-exact-v1/\(kind)/"
            + hexDigest(Data(material.utf8))
    }

    private static func validateIncomingIdentities(_ event: TimelineEvent) throws {
        let values = [
            event.eventID, event.previousEventID, event.journal.journalID,
            event.journal.stableKey, event.session?.sessionID,
            event.work?.workID, event.work?.workHostID, event.workHost?.workHostID,
            event.sessionAttachment?.attachmentID, event.run?.runID,
            event.turn?.turnID, event.causedByEventID?.eventID,
            event.conversationParent?.eventID, event.parentActivityID?.eventID,
            event.command?.commandID, event.command?.client?.clientID,
            event.command?.sessionAttachment?.attachmentID,
            event.command?.causalCursor?.eventID, event.type,
        ].compactMap { $0 }
        guard values.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= maximumIdentityBytes
        }) else { throw Error.invalidRecord }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func read<T: Decodable>(
        map: PersistentProjectionRadixMap,
        root: PersistentProjectionRadixMap.Root?,
        key: String
    ) throws -> T? {
        let result: PersistentProjectionRadixMap.LookupResult
        do { result = try map.lookup(root: root, key: key) }
        catch let error as PersistentProjectionRadixMap.MapError { throw Error.map(error) }
        guard let bytes = result.value else { return nil }
        do { return try JSONDecoder().decode(T.self, from: bytes) }
        catch { throw Error.invalidRecord }
    }

    private static func digestJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return "sha256:" + hexDigest(data)
    }

    private static func digestText(_ value: String) -> String {
        "sha256:" + hexDigest(Data(value.utf8))
    }

    private static func digestPromptSources(_ sources: [ContextManifestSource]) -> String {
        digestPromptSourceRecords(sources.map(PromptSourceRecord.init))
    }

    private static func digestPromptSourceRecords(_ sources: [PromptSourceRecord]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // The persisted fingerprint covers the complete privacy-preserving records, including
        // the original-label digest rather than the redacted marker. Provenance is normalized
        // because the source-observation event stores nil while the immediately following
        // crossing stores that observation's exact EventRef.
        let canonical = sources.map { source in
            PromptSourceRecord(
                kind: source.kind, sourceID: source.sourceID,
                inclusionID: source.inclusionID, sourceKind: source.sourceKind,
                status: source.status, label: source.label,
                labelByteCount: source.labelByteCount, labelDigest: source.labelDigest,
                fullByteCount: source.fullByteCount, fullDigest: source.fullDigest,
                deliveredByteCount: source.deliveredByteCount,
                deliveredDigest: source.deliveredDigest,
                deliveredByteOffsetInRendered: source.deliveredByteOffsetInRendered,
                renderedByteCount: source.renderedByteCount,
                renderedDigest: source.renderedDigest,
                fullBodyReference: source.fullBodyReference,
                deliveredBodyReference: source.deliveredBodyReference,
                renderedBodyReference: source.renderedBodyReference,
                provenance: nil)
        }
        let data = (try? encoder.encode(canonical)) ?? Data()
        return "sha256:" + hexDigest(data)
    }

    private static func hexDigest(_ data: Data) -> String {
        AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        guard value.utf8.count == 71, value.hasPrefix("sha256:") else { return false }
        return value.utf8.dropFirst(7).allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func childClassification(_ state: String) -> String {
        switch state {
        case "running": return "running"
        case "done": return "done"
        case "succeeded", "completed": return "done"
        case "failed": return "failed"
        case "canceled", "cancelled": return "canceled"
        default: return "unknown"
        }
    }

    private static func isCanonicalChildClassification(_ value: String) -> Bool {
        ["running", "done", "failed", "canceled", "unknown"].contains(value)
    }

    private static func validBodyReference(
        _ reference: TimelineBodyReference?, scope: JournalRef, digest: String?, byteCount: Int?
    ) -> Bool {
        guard let reference else { return true }
        guard let digest, let byteCount, byteCount >= 0,
              reference.authority == scope,
              reference.referenceID == digest,
              reference.digest == digest,
              reference.byteCount == byteCount,
              isCanonicalDigest(digest) else { return false }
        return true
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumIdentityBytes
    }

    private static func validateUnknownRecord(
        _ record: UnknownRecord,
        scope: JournalRef,
        maxSequence: Int,
        expectedID: String? = nil
    ) throws {
        guard record.kind == "unknown", record.type == "unknown",
              record.scope == scope.stableKey, record.journal == scope,
              expectedID.map({ record.eventID == $0 }) ?? true,
              validIdentity(record.eventID), record.sequence > 0,
              record.sequence <= maxSequence,
              record.typeDigest.utf8.count <= maximumIdentityBytes,
              isCanonicalDigest(record.typeDigest), record.offset >= 0,
              isCanonicalDigest(record.payloadDigest) else {
            throw Error.invalidRecord
        }
    }

    private static func validateQuarantineRecord(
        _ record: QuarantineRecord,
        scope: JournalRef,
        expectedID: String? = nil
    ) throws {
        guard record.kind == "quarantine", record.type == "quarantine",
              record.scope == scope.stableKey,
              expectedID.map({ record.eventID == $0 }) ?? true,
              validIdentity(record.eventID), validIdentity(record.journal.stableKey),
              record.sequence < Int.max,
              record.typeDigest.utf8.count <= maximumIdentityBytes,
              isCanonicalDigest(record.typeDigest),
              ["structural", "semantic"].contains(record.classification),
              record.structural == (record.classification == "structural"),
              isCanonicalDigest(record.payloadDigest) else {
            throw Error.invalidRecord
        }
    }

    private static func validateSeenRecord(
        _ record: SeenRecord, scope: JournalRef, maxSequence: Int
    ) throws {
        guard record.kind == "seen", record.scope == scope.stableKey,
              validIdentity(record.eventID), record.sequence > 0,
              record.sequence <= maxSequence else { throw Error.invalidRecord }
    }

    private static func validateAttachmentRecord(
        _ record: AttachmentRecord, scope: JournalRef
    ) throws {
        let attachment = record.attachment
        guard record.kind == "attachment", record.scope == scope.stableKey,
              validIdentity(attachment.attachment.attachmentID),
              validIdentity(attachment.work.workID), validIdentity(attachment.work.workHostID),
              attachment.capabilities.count <= 256,
              attachment.capabilities.allSatisfy(validIdentity) else {
            throw Error.invalidRecord
        }
        if let cursor = attachment.cursor {
            guard cursor.sequence >= 0, cursor.sequence < Int.max,
                  cursor.journal.owner == .work(attachment.work),
                  cursor.eventID.map(validIdentity) ?? true else {
                throw Error.invalidRecord
            }
        }
    }

    private static func validateCumulativeRecord(
        _ record: CumulativeRecord, scope: JournalRef
    ) throws {
        guard record.kind == "cumulative", record.scope == scope.stableKey,
              validIdentity(record.runID), record.bytes >= 0 else { throw Error.invalidRecord }
    }

    private static func validateCompactionRecord(
        _ record: CompactionRecord, scope: JournalRef
    ) throws {
        guard record.kind == "compaction", record.scope == scope.stableKey,
              isCanonicalDigest(record.summaryDigest), record.summaryByteCount >= 0,
              validIdentity(record.boundaryEventID) else { throw Error.invalidRecord }
    }

    private static func validateRecoveryRecord(
        _ record: RecoveryRecord, scope: JournalRef
    ) throws {
        guard record.kind == "recovery", record.scope == scope.stableKey,
              record.sourceEvent.journal == scope, validIdentity(record.sourceEvent.eventID),
              record.caveatCount >= 0, record.caveatCount <= 256,
              record.caveatDigest.map(isCanonicalDigest) ?? true else {
            throw Error.invalidRecord
        }
    }

    private static func validateChildRecord(
        _ record: ChildRecord, scope: JournalRef
    ) throws {
        guard record.kind == "child", record.scope == scope.stableKey,
              validIdentity(record.childID), isCanonicalChildClassification(record.state),
              isCanonicalDigest(record.stateDigest) else { throw Error.invalidRecord }
    }

    private static func scalarSnapshot(_ scalar: ScalarRecord) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.journal = scalar.journal
        snapshot.session = scalar.session
        snapshot.lifecycle = scalar.lifecycle
        snapshot.execution = scalar.execution
        snapshot.attention = scalar.attention
        snapshot.attentionEvent = scalar.attentionEvent
        snapshot.activeRun = scalar.activeRun
        snapshot.modelID = scalar.modelID
        snapshot.activeTurn = scalar.activeTurn
        snapshot.semanticTip = scalar.semanticTip
        snapshot.unknownDomains = scalar.unknownDomains
        snapshot.lastEventID = scalar.lastEventID
        snapshot.lastSequence = scalar.lastSequence
        snapshot.causalOrderValid = scalar.causalOrderValid
        snapshot.structuralIntegrityValid = scalar.structuralIntegrityValid
        snapshot.semanticProjectionValid = scalar.semanticProjectionValid
        return snapshot
    }

    // MARK: Typed records

    private struct ScalarRecord: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let kind: String
        let journal: JournalRef?
        let session: SessionRef?
        let lifecycle: SessionLifecycle
        let execution: WorkExecution
        let attention: SessionAttention
        let attentionEvent: EventRef?
        let activeRun: RunRef?
        let modelID: String?
        let activeTurn: TurnRef?
        let semanticTip: EventRef?
        let unknownDomains: Set<TimelineDomain>
        let lastEventID: String?
        let lastSequence: Int
        let causalOrderValid: Bool
        let structuralIntegrityValid: Bool
        let semanticProjectionValid: Bool
        let seenEventCount: Int
        let messageHistoryCount: Int
        let recoveryCount: Int
        let childCount: Int
        let unknownCount: Int
        let quarantineCount: Int
        let lastUnknownEventID: String?
        let lastQuarantineEventID: String?

        static func empty(journal: JournalRef) -> ScalarRecord {
            var snapshot = SessionSnapshot()
            snapshot.journal = journal
            if case .session(let session) = journal.owner { snapshot.session = session }
            return ScalarRecord(
                BoundedSessionScalarContinuation(snapshot: snapshot), seenEventCount: 0,
                messageHistoryCount: 0, recoveryCount: 0, childCount: 0, unknownCount: 0,
                quarantineCount: 0)
        }

        init(
            _ scalar: BoundedSessionScalarContinuation,
            seenEventCount: Int,
            messageHistoryCount: Int,
            recoveryCount: Int,
            childCount: Int,
            unknownCount: Int,
            quarantineCount: Int,
            lastUnknownEventID: String? = nil,
            lastQuarantineEventID: String? = nil
        ) {
            schemaVersion = PersistentSessionExactState.schemaVersion
            kind = "scalar"
            journal = scalar.journal
            session = scalar.session
            lifecycle = scalar.lifecycle
            execution = scalar.execution
            attention = scalar.attention
            attentionEvent = scalar.attentionEvent
            activeRun = scalar.activeRun
            modelID = scalar.modelID
            activeTurn = scalar.activeTurn
            semanticTip = scalar.semanticTip
            unknownDomains = scalar.unknownDomains
            lastEventID = scalar.lastEventID
            lastSequence = scalar.lastSequence
            causalOrderValid = scalar.causalOrderValid
            structuralIntegrityValid = scalar.structuralIntegrityValid
            semanticProjectionValid = scalar.semanticProjectionValid
            self.seenEventCount = seenEventCount
            self.messageHistoryCount = messageHistoryCount
            self.recoveryCount = recoveryCount
            self.childCount = childCount
            self.unknownCount = unknownCount
            self.quarantineCount = quarantineCount
            self.lastUnknownEventID = lastUnknownEventID
            self.lastQuarantineEventID = lastQuarantineEventID
        }

        func validate(scope: JournalRef) throws {
            guard schemaVersion == PersistentSessionExactState.schemaVersion,
                  kind == "scalar", journal == scope,
                  lastSequence >= 0, lastSequence < Int.max,
                  seenEventCount == lastSequence,
                  messageHistoryCount >= 0, messageHistoryCount <= seenEventCount,
                  recoveryCount >= 0, recoveryCount <= seenEventCount,
                  childCount >= 0, childCount <= seenEventCount,
                  unknownCount >= 0, unknownCount <= seenEventCount,
                  quarantineCount >= 0,
                  (unknownCount == 0) == (lastUnknownEventID == nil),
                  (quarantineCount == 0) == (lastQuarantineEventID == nil),
                  lastEventID.map(Self.validIdentity) ?? true,
                  lastUnknownEventID.map(Self.validIdentity) ?? true,
                  lastQuarantineEventID.map(Self.validIdentity) ?? true else {
                throw Error.invalidRecord
            }
            guard case .session(let owner) = scope.owner,
                  session == owner,
                  lastSequence == 0 ? lastEventID == nil : lastEventID != nil,
                  [owner.sessionID, modelID, activeRun?.runID, activeTurn?.turnID]
                    .compactMap({ $0 }).allSatisfy(Self.validIdentity) else {
                throw Error.invalidRecord
            }
        }

        private static func validIdentity(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= PersistentSessionExactState.maximumIdentityBytes
        }
    }

    private struct SeenRecord: Codable, Hashable, Sendable {
        let kind: String; let scope: String; let eventID: String; let sequence: Int
    }

    private struct AttachmentRecord: Codable, Hashable, Sendable {
        let kind: String; let scope: String; let attachment: SessionAttachmentSnapshot
    }

    /// No message body is present in this record. `textDigest` is over the exact UTF-8 body and
    /// `presentationVisible` preserves the one body-dependent branch fact the reducer needs.
    private struct MessageRecord: Codable, Hashable, Sendable {
        let kind: String
        let scope: String
        let eventID: String
        let sequence: Int
        let role: String
        let textDigest: String
        let textByteCount: Int
        let presentationVisible: Bool
        let conversationValid: Bool
        let conversationParent: EventRef?
        let sourceEvent: EventRef
        let hostRecordedAt: Date?
        let clientTimestamp: Date?
        let run: RunRef?
        let turn: TurnRef?
        let actor: TimelineActor?
        let client: ClientRef?
        let sessionAttachment: SessionAttachmentRef?
        let causedBy: EventRef?
        let parentActivity: EventRef?
        let provenance: TimelineEventProvenance?
        let links: [TimelineLink]

        init(
            message: SessionMessageSnapshot, sequence: Int, scope: String,
            conversationValid: Bool
        ) {
            kind = "message"
            self.scope = scope
            eventID = message.eventID
            self.sequence = sequence
            role = message.role
            textDigest = PersistentSessionExactState.digestText(message.text)
            textByteCount = message.text.utf8.count
            presentationVisible = message.role != ChatRole.assistant.rawValue || !message.text.isEmpty
            self.conversationValid = conversationValid
            conversationParent = message.conversationParent
            sourceEvent = message.sourceEvent ?? EventRef(
                journal: JournalRef.session(SessionRef("invalid"), authority: TimelineAuthorityRef("invalid")),
                eventID: message.eventID)
            hostRecordedAt = message.hostRecordedAt
            clientTimestamp = message.clientTimestamp
            run = message.run
            turn = message.turn
            actor = message.actor
            client = message.client
            sessionAttachment = message.sessionAttachment
            causedBy = message.causedBy
            parentActivity = message.parentActivity
            provenance = message.provenance
            links = message.links
        }

        func validate(scope expectedScope: JournalRef) throws {
            guard kind == "message", scope == expectedScope.stableKey,
                  !eventID.isEmpty, eventID.utf8.count <= PersistentSessionExactState.maximumIdentityBytes,
                  sequence > 0, sequence < Int.max, role.utf8.count <= 256,
                  textByteCount >= 0,
                  PersistentSessionExactState.isCanonicalDigest(textDigest),
                  sourceEvent.journal == expectedScope, sourceEvent.eventID == eventID,
                  links.count <= TimelineEvent.maxEvidenceLinks else {
                throw Error.invalidRecord
            }
            guard client.map({ !$0.clientID.isEmpty
                    && $0.clientID.utf8.count <= PersistentSessionExactState.maximumIdentityBytes }) ?? true,
                  sessionAttachment.map({ !$0.attachmentID.isEmpty
                    && $0.attachmentID.utf8.count <= PersistentSessionExactState.maximumIdentityBytes }) ?? true
            else { throw Error.invalidRecord }
            if let parent = conversationParent, parent.journal != expectedScope {
                // Cross-journal ancestry is retained as an invalid message, not an authorization
                // edge. The transition will refuse it as a semantic tip.
                return
            }
        }

        func snapshot(body: String?) -> SessionMessageSnapshot {
            let text = body ?? (presentationVisible ? "[redacted]" : "")
            return SessionMessageSnapshot(
                eventID: eventID, role: role, text: text,
                conversationParent: conversationParent, sourceEvent: sourceEvent,
                sourceCursor: JournalCursor(
                    journal: sourceEvent.journal, eventID: eventID, sequence: sequence),
                hostRecordedAt: hostRecordedAt, clientTimestamp: clientTimestamp,
                run: run, turn: turn, actor: actor, client: client,
                sessionAttachment: sessionAttachment, causedBy: causedBy,
                parentActivity: parentActivity, provenance: provenance, links: links)
        }
    }

    /// Metadata-only prompt-source evidence. Producer labels are hashed and replaced by a fixed
    /// marker; the full source list remains available only in the current event-local overlay.
    private struct PromptSourceRecord: Codable, Hashable, Sendable {
        let kind: String
        let sourceID: String
        let inclusionID: String
        let sourceKind: PromptSourceKind
        let status: PromptSourceStatus
        let label: String
        let labelByteCount: Int
        let labelDigest: String
        let fullByteCount: Int?
        let fullDigest: String?
        let deliveredByteCount: Int
        let deliveredDigest: String
        let deliveredByteOffsetInRendered: Int
        let renderedByteCount: Int
        let renderedDigest: String
        let fullBodyReference: TimelineBodyReference?
        let deliveredBodyReference: TimelineBodyReference?
        let renderedBodyReference: TimelineBodyReference?
        let provenance: EventRef?

        fileprivate init(
            kind: String, sourceID: String, inclusionID: String,
            sourceKind: PromptSourceKind, status: PromptSourceStatus,
            label: String, labelByteCount: Int, labelDigest: String,
            fullByteCount: Int?, fullDigest: String?, deliveredByteCount: Int,
            deliveredDigest: String, deliveredByteOffsetInRendered: Int,
            renderedByteCount: Int, renderedDigest: String,
            fullBodyReference: TimelineBodyReference?,
            deliveredBodyReference: TimelineBodyReference?,
            renderedBodyReference: TimelineBodyReference?, provenance: EventRef?
        ) {
            self.kind = kind; self.sourceID = sourceID; self.inclusionID = inclusionID
            self.sourceKind = sourceKind; self.status = status; self.label = label
            self.labelByteCount = labelByteCount; self.labelDigest = labelDigest
            self.fullByteCount = fullByteCount; self.fullDigest = fullDigest
            self.deliveredByteCount = deliveredByteCount; self.deliveredDigest = deliveredDigest
            self.deliveredByteOffsetInRendered = deliveredByteOffsetInRendered
            self.renderedByteCount = renderedByteCount; self.renderedDigest = renderedDigest
            self.fullBodyReference = fullBodyReference
            self.deliveredBodyReference = deliveredBodyReference
            self.renderedBodyReference = renderedBodyReference; self.provenance = provenance
        }

        init(source: ContextManifestSource) {
            kind = "prompt-source"
            sourceID = source.sourceID; inclusionID = source.inclusionID
            sourceKind = source.kind; status = source.status
            label = "redacted"
            labelByteCount = source.label.utf8.count
            labelDigest = PersistentSessionExactState.digestText(source.label)
            fullByteCount = source.fullByteCount; fullDigest = source.fullDigest
            deliveredByteCount = source.deliveredByteCount
            deliveredDigest = source.deliveredDigest
            deliveredByteOffsetInRendered = source.deliveredByteOffsetInRendered
            renderedByteCount = source.renderedByteCount; renderedDigest = source.renderedDigest
            fullBodyReference = source.fullBodyReference
            deliveredBodyReference = source.deliveredBodyReference
            renderedBodyReference = source.renderedBodyReference
            provenance = source.provenance
        }

        func validate(scope: JournalRef) throws {
            guard kind == "prompt-source",
                  !sourceID.isEmpty, sourceID.utf8.count <= PersistentSessionExactState.maximumIdentityBytes,
                  !inclusionID.isEmpty, inclusionID.utf8.count <= PersistentSessionExactState.maximumIdentityBytes,
                  label == "redacted", labelByteCount >= 0, labelByteCount <= 1_024,
                  PersistentSessionExactState.isCanonicalDigest(labelDigest),
                  deliveredByteCount >= 0, deliveredByteOffsetInRendered >= 0,
                  renderedByteCount >= 0,
                  PersistentSessionExactState.isCanonicalDigest(deliveredDigest),
                  PersistentSessionExactState.isCanonicalDigest(renderedDigest),
                  fullByteCount.map({ $0 >= 0 }) ?? true,
                  fullDigest.map(PersistentSessionExactState.isCanonicalDigest) ?? true else {
                throw Error.invalidRecord
            }
            guard PersistentSessionExactState.validBodyReference(
                fullBodyReference, scope: scope, digest: fullDigest, byteCount: fullByteCount),
                  PersistentSessionExactState.validBodyReference(
                      deliveredBodyReference, scope: scope, digest: deliveredDigest,
                      byteCount: deliveredByteCount),
                  PersistentSessionExactState.validBodyReference(
                      renderedBodyReference, scope: scope, digest: renderedDigest,
                      byteCount: renderedByteCount),
                  provenance.map({ $0.journal == scope }) ?? true else {
                throw Error.invalidRecord
            }
        }
    }

    private struct ManifestRecord: Codable, Hashable, Sendable {
        let kind: String
        let manifestID: String
        let requestID: String
        let modelID: String
        let measuredBy: String
        let measuredBytes: Int
        let deliveredBytes: Int
        let cumulativeDeliveredBytes: Int
        let componentCount: Int
        let promptSourceFingerprint: String?

        init(manifest: ContextManifest, promptSourceFingerprint: String?) {
            kind = "manifest"
            manifestID = manifest.manifestID; requestID = manifest.requestID
            modelID = manifest.modelID; measuredBy = manifest.measuredBy
            measuredBytes = manifest.measuredBytes; deliveredBytes = manifest.deliveredBytes
            cumulativeDeliveredBytes = manifest.cumulativeDeliveredBytes
            componentCount = manifest.components.count
            self.promptSourceFingerprint = promptSourceFingerprint
        }

        func validate() throws {
            guard kind == "manifest",
                  [manifestID, requestID, modelID, measuredBy].allSatisfy({
                      !$0.isEmpty && $0.utf8.count <= PersistentSessionExactState.maximumIdentityBytes
                  }), measuredBytes >= 0, deliveredBytes >= 0,
                  cumulativeDeliveredBytes >= 0, componentCount >= 0,
                  measuredBy == ContextManifest.measurementBasis,
                  promptSourceFingerprint.map(PersistentSessionExactState.isCanonicalDigest) ?? true
            else { throw Error.invalidRecord }
        }
    }

    private struct ContextRecord: Codable, Hashable, Sendable {
        let kind: String
        let scope: String
        let components: [ContextComponent]
        let manifest: ManifestRecord?
        let lastRunID: String?
        let promptAssemblyID: String?
        let promptSources: [PromptSourceRecord]?
        let promptSourcesFingerprint: String?
        let sourcesObservationEventID: String?
        let sourcesObservationSession: SessionRef?
        let sourcesObservationWork: WorkRef?
        let sourcesObservationWorkHost: WorkHostRef?
        let sourcesObservationRun: RunRef?
        let boundaryEventID: String?

        init(context: SessionContextContinuation, scope: String, lastRunID: String?) {
            kind = "context"; self.scope = scope
            components = context.components
            promptSources = context.promptSources?.map(PromptSourceRecord.init)
            promptSourcesFingerprint = context.promptSources.map {
                PersistentSessionExactState.digestPromptSources($0)
            }
            manifest = context.manifest.map {
                ManifestRecord(
                    manifest: $0, promptSourceFingerprint: $0.systemPromptSources.map {
                        PersistentSessionExactState.digestPromptSources($0)
                    })
            }
            self.lastRunID = lastRunID
            promptAssemblyID = context.promptAssemblyID
            sourcesObservationEventID = context.sourcesObservationEventID
            sourcesObservationSession = context.sourcesObservationSession
            sourcesObservationWork = context.sourcesObservationWork
            sourcesObservationWorkHost = context.sourcesObservationWorkHost
            sourcesObservationRun = context.sourcesObservationRun
            boundaryEventID = context.boundaryEventID
        }

        /// Rehydrate only the metadata required for an event-local transition. Prompt source
        /// labels and full manifest fields remain unavailable until the current event supplies
        /// them and its fingerprint matches this record.
        var continuation: SessionContextContinuation {
            var value = SessionContextContinuation(snapshot: SessionSnapshot())
            value.components = components
            value.promptAssemblyID = promptAssemblyID
            value.sourcesObservationEventID = sourcesObservationEventID
            value.sourcesObservationSession = sourcesObservationSession
            value.sourcesObservationWork = sourcesObservationWork
            value.sourcesObservationWorkHost = sourcesObservationWorkHost
            value.sourcesObservationRun = sourcesObservationRun
            value.boundaryEventID = boundaryEventID
            return value
        }

        func continuation(withPromptSources sources: [ContextManifestSource])
            -> SessionContextContinuation {
            var value = continuation
            value.promptSources = sources
            return value
        }

        func validate(scope expectedScope: JournalRef) throws {
            guard kind == "context", scope == expectedScope.stableKey,
                  components.count <= BoundedTimelineReducerProjectionLimits.default.maximumContextComponents,
                  (promptSources?.count ?? 0)
                    <= BoundedTimelineReducerProjectionLimits.default.maximumPromptSources,
                  promptSourcesFingerprint.map(PersistentSessionExactState.isCanonicalDigest) ?? true,
                  (promptSources == nil) == (promptSourcesFingerprint == nil),
                  lastRunID.map(PersistentSessionExactState.validIdentity) ?? true
            else { throw Error.invalidRecord }
            for component in components {
                guard !component.componentID.isEmpty,
                      component.componentID.utf8.count <= PersistentSessionExactState.maximumIdentityBytes,
                      !component.inclusionID.isEmpty,
                      component.inclusionID.utf8.count <= PersistentSessionExactState.maximumIdentityBytes,
                      [component.measuredBytes, component.includedBytes, component.deliveredBytes,
                       component.fullByteCount].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
                    throw Error.invalidRecord
                }
            }
            for component in components {
                guard component.digest.map(PersistentSessionExactState.isCanonicalDigest) ?? true,
                      PersistentSessionExactState.validBodyReference(
                          component.bodyReference, scope: expectedScope,
                          digest: component.digest, byteCount: component.fullByteCount),
                      component.source.provenance.map({ $0.journal == expectedScope }) ?? true,
                      component.tokenCount.map({ $0 >= 0 }) ?? true,
                      component.tokenizer.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else {
                    throw Error.invalidRecord
                }
            }
            try promptSources?.forEach { try $0.validate(scope: expectedScope) }
            if let promptSources {
                guard promptSourcesFingerprint
                        == PersistentSessionExactState.digestPromptSourceRecords(promptSources),
                      let promptAssemblyID,
                      PersistentSessionExactState.isCanonicalDigest(promptAssemblyID),
                      let sourcesObservationEventID,
                      let sourcesObservationSession,
                      let sourcesObservationWork,
                      let sourcesObservationWorkHost,
                      let sourcesObservationRun,
                      case .session(let owner) = expectedScope.owner,
                      sourcesObservationSession == owner,
                      PersistentSessionExactState.validIdentity(sourcesObservationEventID),
                      PersistentSessionExactState.validIdentity(
                          sourcesObservationWork.workID),
                      PersistentSessionExactState.validIdentity(
                          sourcesObservationWork.workHostID),
                      PersistentSessionExactState.validIdentity(
                          sourcesObservationWorkHost.workHostID),
                      sourcesObservationWork.workHostID == sourcesObservationWorkHost.workHostID,
                      PersistentSessionExactState.validIdentity(sourcesObservationRun.runID) else {
                    throw Error.invalidRecord
                }
                let observation = EventRef(
                    journal: expectedScope, eventID: sourcesObservationEventID)
                let provenances = promptSources.map(\.provenance)
                guard provenances.allSatisfy({ $0 == nil })
                        || provenances.allSatisfy({ $0 == observation }) else {
                    throw Error.invalidRecord
                }
            } else {
                guard promptSourcesFingerprint == nil, promptAssemblyID == nil,
                      sourcesObservationEventID == nil, sourcesObservationSession == nil,
                      sourcesObservationWork == nil, sourcesObservationWorkHost == nil,
                      sourcesObservationRun == nil else {
                    throw Error.invalidRecord
                }
            }
            try manifest?.validate()
            if let manifest {
                var measured = 0
                var delivered = 0
                for component in components {
                    if let value = component.measuredBytes {
                        let sum = measured.addingReportingOverflow(value)
                        guard !sum.overflow else { throw Error.invalidRecord }
                        measured = sum.partialValue
                    }
                    if let value = component.deliveredBytes {
                        let sum = delivered.addingReportingOverflow(value)
                        guard !sum.overflow else { throw Error.invalidRecord }
                        delivered = sum.partialValue
                    }
                }
                guard manifest.componentCount == components.count,
                      manifest.measuredBytes == measured,
                      manifest.deliveredBytes == delivered,
                      manifest.cumulativeDeliveredBytes >= delivered else {
                    throw Error.invalidRecord
                }
            }
            if let manifestFingerprint = manifest?.promptSourceFingerprint,
               let sourcesFingerprint = promptSourcesFingerprint,
               manifestFingerprint != sourcesFingerprint {
                throw Error.invalidRecord
            }
        }
    }

    private struct CumulativeRecord: Codable, Hashable, Sendable {
        let kind: String; let scope: String; let runID: String; let bytes: Int
    }

    private struct CompactionRecord: Codable, Hashable, Sendable {
        let kind: String; let scope: String; let summaryDigest: String
        let summaryByteCount: Int; let boundaryEventID: String
    }

    private struct RecoveryRecord: Codable, Hashable, Sendable {
        let kind: String; let scope: String
        let operation: RecoveryOperation
        let planes: [RecoveryPlane: RecoveryCoverageStatus]
        let evidence: EventRef?
        let evidenceCursor: JournalCursor?
        let caveatCount: Int
        let caveatDigest: String?
        let sourceEvent: EventRef
        let session: SessionRef
        let work: WorkRef
        let workJournal: JournalRef
        let workHost: WorkHostRef
        let sessionAttachment: SessionAttachmentRef
        let run: RunRef

        init(coverage: RecoveryCoverage, recorded: RecordedRecoveryCoverage, scope: String) {
            kind = "recovery"; self.scope = scope
            operation = coverage.operation; planes = coverage.planes
            evidence = coverage.evidence; evidenceCursor = coverage.evidenceCursor
            caveatCount = coverage.caveats.count
            caveatDigest = coverage.caveats.isEmpty
                ? nil : PersistentSessionExactState.digestJSON(
                    .array(coverage.caveats.map { .string($0) }))
            sourceEvent = recorded.sourceEvent; session = recorded.session; work = recorded.work
            workJournal = recorded.workJournal; workHost = recorded.workHost
            sessionAttachment = recorded.sessionAttachment; run = recorded.run
        }

        func coverage() -> RecoveryCoverage {
            RecoveryCoverage(
                operation: operation, planes: planes, evidence: evidence,
                evidenceCursor: evidenceCursor,
                // Durable recovery records retain only caveat count/fingerprint. Preserve the
                // count in the event-local view with a fixed redaction marker so an empty array
                // cannot be mistaken for proof that no caveats existed.
                caveats: Array(repeating: "[redacted]", count: caveatCount))
        }

        func recorded() -> RecordedRecoveryCoverage {
            RecordedRecoveryCoverage(
                coverage: coverage(), sourceEvent: sourceEvent, session: session, work: work,
                workJournal: workJournal, workHost: workHost,
                sessionAttachment: sessionAttachment, run: run)
        }
    }

    private struct ChildRecord: Codable, Hashable, Sendable {
        let kind: String; let scope: String; let childID: String
        let state: String; let stateDigest: String
    }

    private struct UnknownRecord: Codable, Hashable, Sendable {
        let kind: String; let scope: String; let eventID: String; let journal: JournalRef
        let sequence: Int; let type: String; let typeDigest: String; let offset: Int
        let domains: Set<TimelineDomain>; let payloadDigest: String
    }

    private struct QuarantineRecord: Codable, Hashable, Sendable {
        let kind: String; let scope: String; let eventID: String; let journal: JournalRef
        let sequence: Int; let type: String; let typeDigest: String; let classification: String
        let structural: Bool; let payloadDigest: String
    }

    // MARK: Bounded prefetch

    private struct Prefetch {
        let seen: SeenRecord?
        let seenRecords: [String: SeenRecord]
        let attachments: [String: AttachmentRecord]
        let messages: [String: MessageRecord]
        let contexts: ContextRecord?
        let cumulative: [String: CumulativeRecord]
        let compaction: CompactionRecord?
        let recoveries: [String: RecoveryRecord]
        let children: [String: ChildRecord]
        let unknowns: [UnknownRecord]
        let quarantines: [QuarantineRecord]

        init(
            map: PersistentProjectionRadixMap,
            root: PersistentProjectionRadixMap.Root?,
            event: TimelineEvent,
            scalar: ScalarRecord
        ) throws {
            guard case .session(let expectedSession) = map.journal.owner else {
                throw Error.invalidRecord
            }
            var slots = 0
            func load<T: Decodable>(_ key: String) throws -> T? {
                slots += 1
                guard slots <= PersistentSessionExactState.maximumOperationSlots else {
                    throw Error.tooManyPrefetchedSlots
                }
                return try PersistentSessionExactState.read(map: map, root: root, key: key)
            }

            // The shared transition deliberately short-circuits all future events after a
            // structural failure. Do not prefetch a missing physical predecessor (or reject a
            // duplicate before the transition can quarantine it); only retain the latest typed
            // quarantine record needed to append the next evidence row.
            if !scalar.structuralIntegrityValid {
                var quarantines: [QuarantineRecord] = []
                if let id = scalar.lastQuarantineEventID {
                    guard let record: QuarantineRecord = try load(
                        PersistentSessionExactState.slotKey(kind: "quarantine", identity: id)) else {
                        throw Error.invalidRecord
                    }
                    try PersistentSessionExactState.validateQuarantineRecord(
                        record, scope: map.journal, expectedID: id)
                    quarantines.append(record)
                }
                self.seen = nil; self.seenRecords = [:]
                self.attachments = [:]; self.messages = [:]; self.contexts = nil
                self.cumulative = [:]; self.compaction = nil; self.recoveries = [:]
                self.children = [:]; self.unknowns = []; self.quarantines = quarantines
                return
            }

            let seen: SeenRecord? = try load(PersistentSessionExactState.slotKey(
                kind: "seen", identity: event.eventID))
            var seenRecords: [String: SeenRecord] = [:]
            if let seen {
                guard seen.kind == "seen", seen.scope == map.journal.stableKey,
                      seen.eventID == event.eventID, seen.sequence > 0,
                      seen.sequence <= scalar.lastSequence else {
                    throw Error.invalidRecord
                }
                seenRecords[seen.eventID] = seen
            }
            if let previous = event.previousEventID {
                guard let record: SeenRecord = try load(PersistentSessionExactState.slotKey(
                    kind: "seen", identity: previous)) else { throw Error.invalidRecord }
                guard record.kind == "seen", record.scope == map.journal.stableKey,
                      record.eventID == previous, record.sequence > 0,
                      record.sequence <= scalar.lastSequence else {
                    throw Error.invalidRecord
                }
                seenRecords[previous] = record
            }

            var attachments: [String: AttachmentRecord] = [:]
            if let attachment = event.sessionAttachment,
               let record: AttachmentRecord = try load(PersistentSessionExactState.slotKey(
                   kind: "attachment", identity: attachment.attachmentID)) {
                guard record.kind == "attachment", record.scope == map.journal.stableKey,
                      record.attachment.attachment == attachment,
                      !record.attachment.work.workID.isEmpty,
                      record.attachment.work.workID.utf8.count
                        <= PersistentSessionExactState.maximumIdentityBytes,
                      !record.attachment.work.workHostID.isEmpty,
                      record.attachment.work.workHostID.utf8.count
                        <= PersistentSessionExactState.maximumIdentityBytes else {
                    throw Error.invalidRecord
                }
                attachments[attachment.attachmentID] = record
            }

            var messages: [String: MessageRecord] = [:]
            func loadMessage(_ id: String) throws {
                guard messages[id] == nil else { return }
                guard let record: MessageRecord = try load(
                    PersistentSessionExactState.slotKey(kind: "message", identity: id)) else {
                    return
                }
                try record.validate(scope: map.journal)
                guard record.eventID == id else { throw Error.invalidRecord }
                messages[id] = record
            }

            let eventParent = event.conversationParent
                ?? event.payload["conversation_parent"].flatMap { decodeTimelineValue($0) }
            switch event.type {
            case TimelineEventType.inputAccepted, TimelineEventType.messageCommitted:
                // Appending a message needs only its immediate parent. The ancestry-valid bit on
                // that parent is itself authenticated in the typed record, so a linear chat does
                // not repeatedly rescan its entire history.
                if let parent = eventParent?.eventID,
                   let record: MessageRecord = try load(PersistentSessionExactState.slotKey(
                       kind: "message", identity: parent)) {
                    try record.validate(scope: map.journal)
                    guard record.eventID == parent else { throw Error.invalidRecord }
                    messages[parent] = record
                }
            case TimelineEventType.sessionTipSelected:
                // Tip legality depends only on the selected node's authenticated, persisted
                // conversation-valid bit. Visible branch materialization is deliberately a
                // bounded event-local view and may be partial; the canonical bounded head is
                // rebuilt separately by LocalTimelineProjectionReader.
                if let id = event.conversationParent?.eventID {
                    guard let record: SeenRecord = try load(PersistentSessionExactState.slotKey(
                        kind: "seen", identity: id)) else { throw Error.invalidRecord }
                    guard record.kind == "seen", record.scope == map.journal.stableKey,
                          record.eventID == id, record.sequence > 0,
                          record.sequence <= scalar.lastSequence else {
                        throw Error.invalidRecord
                    }
                    seenRecords[id] = record
                    try loadMessage(id)
                }
                if let id = scalar.semanticTip?.eventID {
                    try loadMessage(id)
                }
            default:
                break
            }

            var contexts: ContextRecord?
            if event.type == TimelineEventType.contextSourcesObserved
                || event.type == TimelineEventType.contextAssembled,
               let record: ContextRecord = try load(PersistentSessionExactState.contextKey) {
                guard record.kind == "context", record.scope == map.journal.stableKey else {
                    throw Error.invalidRecord
                }
                try record.validate(scope: map.journal)
                contexts = record
            }

            var cumulative: [String: CumulativeRecord] = [:]
            if event.type == TimelineEventType.contextAssembled, let run = event.run {
                let priorCumulative: CumulativeRecord?
                if let context = contexts, context.manifest != nil,
                   context.lastRunID == run.runID {
                    guard let record: CumulativeRecord = try load(
                        PersistentSessionExactState.slotKey(kind: "cumulative", identity: run.runID))
                    else { throw Error.invalidRecord }
                    priorCumulative = record
                } else {
                    priorCumulative = try load(PersistentSessionExactState.slotKey(
                        kind: "cumulative", identity: run.runID))
                }
                if let record = priorCumulative {
                    guard record.kind == "cumulative", record.scope == map.journal.stableKey,
                          record.runID == run.runID, record.bytes >= 0 else {
                        throw Error.invalidRecord
                    }
                    cumulative[run.runID] = record
                }
            }

            var compaction: CompactionRecord?
            if event.type == TimelineEventType.compaction,
               let record: CompactionRecord = try load(PersistentSessionExactState.compactionKey) {
                guard record.kind == "compaction", record.scope == map.journal.stableKey,
                      record.summaryByteCount >= 0,
                      PersistentSessionExactState.isCanonicalDigest(record.summaryDigest) else {
                    throw Error.invalidRecord
                }
                compaction = record
            }

            var recoveries: [String: RecoveryRecord] = [:]
            if event.type == TimelineEventType.recoveryCoverage,
               let record: RecoveryRecord = try load(PersistentSessionExactState.slotKey(
                   kind: "recovery", identity: event.eventID)) {
                guard record.kind == "recovery", record.scope == map.journal.stableKey,
                      record.sourceEvent == EventRef(journal: event.journal, eventID: event.eventID),
                      record.caveatCount >= 0, record.caveatCount <= 256 else {
                    throw Error.invalidRecord
                }
                recoveries[event.eventID] = record
            }

            var children: [String: ChildRecord] = [:]
            if let childID = event.payload["child_id"]?.stringValue,
               let record: ChildRecord = try load(PersistentSessionExactState.slotKey(
                   kind: "child", identity: childID)) {
                guard record.kind == "child", record.scope == map.journal.stableKey,
                      record.childID == childID,
                      PersistentSessionExactState.isCanonicalChildClassification(record.state),
                      PersistentSessionExactState.isCanonicalDigest(record.stateDigest) else {
                    throw Error.invalidRecord
                }
                children[childID] = record
            }

            var unknowns: [UnknownRecord] = []
            if let id = scalar.lastUnknownEventID {
                guard let record: UnknownRecord = try load(PersistentSessionExactState.slotKey(
                    kind: "unknown", identity: id)) else { throw Error.invalidRecord }
                try PersistentSessionExactState.validateUnknownRecord(
                    record, scope: map.journal, maxSequence: scalar.lastSequence, expectedID: id)
                unknowns.append(record)
            }
            var quarantines: [QuarantineRecord] = []
            if let id = scalar.lastQuarantineEventID {
                guard let record: QuarantineRecord = try load(PersistentSessionExactState.slotKey(
                    kind: "quarantine", identity: id)) else { throw Error.invalidRecord }
                try PersistentSessionExactState.validateQuarantineRecord(
                    record, scope: map.journal, expectedID: id)
                quarantines.append(record)
            }

            self.seen = seen; self.seenRecords = seenRecords
            self.attachments = attachments; self.messages = messages
            self.contexts = contexts; self.cumulative = cumulative
            self.compaction = compaction; self.recoveries = recoveries
            self.children = children; self.unknowns = unknowns; self.quarantines = quarantines
            _ = expectedSession
        }
    }

    // MARK: Event-local SessionTransitionState adapter

    private struct EventLocalOverlay: SessionTransitionState {
        var scalarState: BoundedSessionScalarContinuation
        let scope: String
        var seenRecords: [String: SeenRecord]
        var attachments: [String: AttachmentRecord]
        var messages: [String: MessageRecord]
        var contexts: ContextRecord?
        var ephemeralContext: SessionContextContinuation?
        var cumulative: [String: CumulativeRecord]
        var compactionRecord: CompactionRecord?
        var recoveries: [String: RecoveryRecord]
        var children: [String: ChildRecord]
        var unknownRecords: [UnknownRecord]
        var quarantineRecords: [QuarantineRecord]
        var messageBodies: [String: String]
        var compactionSummaries: [String: String]
        var seenCount: Int
        var messageCount: Int
        var recoveryCount: Int
        var childCount: Int
        var unknownCount: Int
        var quarantineCount: Int
        var visible: [SessionMessageSnapshot] = []
        var invalidMutation = false
        var didStageContext = false
        var changedCumulativeRunIDs: Set<String> = []
        var didStageCompaction = false
        var didStageRecovery = false
        var changedChildID: String?
        var currentEventRunID: String?

        func validateChangedRecords(_ keys: [String], scope: JournalRef) throws {
            for key in keys where key != PersistentSessionExactState.scalarKey {
                if key == PersistentSessionExactState.contextKey {
                    guard let contexts else { throw Error.invalidRecord }
                    try contexts.validate(scope: scope)
                    continue
                }
                if key == PersistentSessionExactState.compactionKey {
                    guard let compactionRecord else { throw Error.invalidRecord }
                    try PersistentSessionExactState.validateCompactionRecord(
                        compactionRecord, scope: scope)
                    continue
                }
                let parts = key.split(separator: "/")
                guard parts.count == 3 else { throw Error.invalidRecord }
                let kind = String(parts[1])
                switch kind {
                case "seen":
                    guard let id = seenRecords.keys.first(where: {
                        PersistentSessionExactState.slotKey(kind: kind, identity: $0) == key
                    }), let record = seenRecords[id] else { throw Error.invalidRecord }
                    try PersistentSessionExactState.validateSeenRecord(
                        record, scope: scope, maxSequence: scalarState.lastSequence)
                case "attachment":
                    guard let id = attachments.keys.first(where: {
                        PersistentSessionExactState.slotKey(kind: kind, identity: $0) == key
                    }), let record = attachments[id] else { throw Error.invalidRecord }
                    try PersistentSessionExactState.validateAttachmentRecord(record, scope: scope)
                case "message":
                    guard let id = messages.keys.first(where: {
                        PersistentSessionExactState.slotKey(kind: kind, identity: $0) == key
                    }), let record = messages[id] else { throw Error.invalidRecord }
                    guard record.eventID == id else { throw Error.invalidRecord }
                    try record.validate(scope: scope)
                case "cumulative":
                    guard let id = cumulative.keys.first(where: {
                        PersistentSessionExactState.slotKey(kind: kind, identity: $0) == key
                    }), let record = cumulative[id] else { throw Error.invalidRecord }
                    try PersistentSessionExactState.validateCumulativeRecord(record, scope: scope)
                case "recovery":
                    guard let id = recoveries.keys.first(where: {
                        PersistentSessionExactState.slotKey(kind: kind, identity: $0) == key
                    }), let record = recoveries[id] else { throw Error.invalidRecord }
                    try PersistentSessionExactState.validateRecoveryRecord(record, scope: scope)
                case "child":
                    guard let id = children.keys.first(where: {
                        PersistentSessionExactState.slotKey(kind: kind, identity: $0) == key
                    }), let record = children[id] else { throw Error.invalidRecord }
                    try PersistentSessionExactState.validateChildRecord(record, scope: scope)
                case "unknown":
                    guard let record = unknownRecords.first(where: {
                        PersistentSessionExactState.slotKey(kind: kind, identity: $0.eventID) == key
                    }) else { throw Error.invalidRecord }
                    try PersistentSessionExactState.validateUnknownRecord(
                        record, scope: scope, maxSequence: scalarState.lastSequence)
                case "quarantine":
                    guard let record = quarantineRecords.first(where: {
                        PersistentSessionExactState.slotKey(kind: kind, identity: $0.eventID) == key
                    }) else { throw Error.invalidRecord }
                    // Structural evidence may be foreign to the Session journal and may have
                    // been rejected before stageSeenEvent, so it intentionally has no semantic
                    // sequence bound.
                    try PersistentSessionExactState.validateQuarantineRecord(
                        record, scope: scope)
                default:
                    throw Error.invalidRecord
                }
            }
        }

        init(
            scalar: ScalarRecord,
            scope: String,
            seenRecords: [String: SeenRecord],
            attachments: [String: AttachmentRecord],
            messages: [String: MessageRecord],
            contexts: ContextRecord?,
            cumulative: [String: CumulativeRecord],
            compaction: CompactionRecord?,
            recoveries: [String: RecoveryRecord],
            children: [String: ChildRecord],
            unknowns: [UnknownRecord],
            quarantines: [QuarantineRecord],
            messageBodies: [String: String],
            compactionSummaries: [String: String]
        ) {
            var scalarContinuation = BoundedSessionScalarContinuation(snapshot: SessionSnapshot())
            scalarContinuation.journal = scalar.journal; scalarContinuation.session = scalar.session
            scalarContinuation.lifecycle = scalar.lifecycle; scalarContinuation.execution = scalar.execution
            scalarContinuation.attention = scalar.attention; scalarContinuation.attentionEvent = scalar.attentionEvent
            scalarContinuation.activeRun = scalar.activeRun; scalarContinuation.modelID = scalar.modelID
            scalarContinuation.activeTurn = scalar.activeTurn; scalarContinuation.semanticTip = scalar.semanticTip
            scalarContinuation.unknownDomains = scalar.unknownDomains; scalarContinuation.lastEventID = scalar.lastEventID
            scalarContinuation.lastSequence = scalar.lastSequence
            scalarContinuation.causalOrderValid = scalar.causalOrderValid
            scalarContinuation.structuralIntegrityValid = scalar.structuralIntegrityValid
            scalarContinuation.semanticProjectionValid = scalar.semanticProjectionValid
            self.scalarState = scalarContinuation; self.scope = scope
            self.seenRecords = seenRecords; self.attachments = attachments; self.messages = messages
            self.contexts = contexts; self.cumulative = cumulative; self.compactionRecord = compaction
            self.ephemeralContext = nil
            self.recoveries = recoveries; self.children = children
            self.unknownRecords = unknowns; self.quarantineRecords = quarantines
            self.messageBodies = messageBodies; self.compactionSummaries = compactionSummaries
            self.currentEventRunID = nil
            self.seenCount = scalar.seenEventCount; self.messageCount = scalar.messageHistoryCount
            self.recoveryCount = scalar.recoveryCount; self.childCount = scalar.childCount
            self.unknownCount = scalar.unknownCount; self.quarantineCount = scalar.quarantineCount
            self.visible = Self.visibleFromRecords(
                messages: messages, bodies: messageBodies, tip: scalar.semanticTip,
                scope: scalar.journal)
        }

        var scalar: BoundedSessionScalarContinuation { scalarState }
        var context: SessionContextContinuation {
            ephemeralContext ?? contexts?.continuation ?? SessionContextContinuation(snapshot: SessionSnapshot())
        }
        var compactionContinuation: SessionCompactionContinuation {
            var value = SessionCompactionContinuation(snapshot: SessionSnapshot())
            value.summary = compactionRecord.flatMap {
                compactionSummaries[$0.boundaryEventID]
            }
            value.boundaryEventID = compactionRecord?.boundaryEventID
            return value
        }
        var compaction: SessionCompactionContinuation { compactionContinuation }
        var seenEventCount: Int { seenCount }
        var messageHistoryCount: Int { messageCount }

        func hasSeenEvent(_ eventID: String) -> Bool { seenRecords[eventID] != nil }

        func attachment(for attachmentID: String) -> SessionAttachmentSnapshot? {
            attachments[attachmentID]?.attachment
        }

        func message(for eventID: String) -> SessionMessageSnapshot? {
            guard let value = messages[eventID] else { return nil }
            return value.snapshot(body: messageBodies[eventID])
        }

        func messageIsValid(_ eventID: String) -> Bool {
            guard let record = messages[eventID],
                  record.sourceEvent.journal.stableKey == scope else { return false }
            return record.conversationValid
        }

        func contextCumulativeDeliveredBytes(for runID: String) -> Int? {
            cumulative[runID]?.bytes
        }

        func recovery(at index: Int) -> RecoveryCoverage? {
            guard index >= 0,
                  let value = recoveries.values.sorted(by: { $0.sourceEvent.eventID < $1.sourceEvent.eventID })
                    .dropFirst(index).first else { return nil }
            return value.coverage()
        }

        func childState(for childID: String) -> String? { children[childID]?.state }

        func selectedBranchExtension(
            from previousTip: EventRef, to newTip: EventRef?
        ) -> [SessionMessageSnapshot]? {
            guard let newTip else { return nil }
            if previousTip == newTip { return [] }
            var current: EventRef? = newTip
            var visited: Set<String> = []
            var result: [SessionMessageSnapshot] = []
            while let ref = current, ref != previousTip {
                guard ref.journal.stableKey == scope,
                      visited.insert(ref.eventID).inserted,
                      let message = self.message(for: ref.eventID),
                      self.messageIsValid(ref.eventID) else { return nil }
                result.append(message)
                current = message.conversationParent
            }
            guard current == previousTip else { return nil }
            return result.reversed()
        }

        func visibleMessages(for tip: EventRef?) -> [SessionMessageSnapshot] {
            guard let tip else {
                return messages.values.sorted(by: Self.messageLess).compactMap { value in
                    guard value.presentationVisible else { return nil }
                    return value.snapshot(body: messageBodies[value.eventID])
                }
            }
            var current: EventRef? = tip
            var visited: Set<String> = []
            var result: [SessionMessageSnapshot] = []
            while let ref = current, visited.insert(ref.eventID).inserted,
                  let value = messages[ref.eventID] {
                if value.presentationVisible {
                    result.append(value.snapshot(body: messageBodies[value.eventID]))
                }
                current = value.conversationParent
            }
            return result.reversed()
        }

        mutating func stageScalar(_ continuation: BoundedSessionScalarContinuation) {
            scalarState = continuation
        }

        mutating func stageSeenEvent(_ event: TimelineEvent) {
            let (next, overflow) = seenCount.addingReportingOverflow(1)
            guard !overflow, next < Int.max, event.sequence > 0, event.sequence < Int.max else {
                invalidMutation = true; return
            }
            seenRecords[event.eventID] = SeenRecord(
                kind: "seen", scope: scope, eventID: event.eventID, sequence: event.sequence)
            seenCount = next
            var value = scalarState
            value.lastEventID = event.eventID; value.lastSequence = max(value.lastSequence, event.sequence)
            scalarState = value
        }

        mutating func stageAttachment(_ attachment: SessionAttachmentSnapshot) {
            attachments[attachment.attachment.attachmentID] = AttachmentRecord(
                kind: "attachment", scope: scope, attachment: attachment)
        }

        mutating func stageMessage(_ message: SessionMessageSnapshot) {
            guard let source = message.sourceEvent,
                  source.journal.stableKey == scope,
                  message.eventID.utf8.count <= PersistentSessionExactState.maximumIdentityBytes else {
                invalidMutation = true; return
            }
            let conversationValid: Bool
            if let parent = message.conversationParent {
                conversationValid = parent.journal.stableKey == scope
                    && messages[parent.eventID]?.conversationValid == true
            } else {
                conversationValid = true
            }
            let record = MessageRecord(
                message: message, sequence: scalarState.lastSequence, scope: scope,
                conversationValid: conversationValid)
            messages[message.eventID] = record
            messageBodies[message.eventID] = message.text
            messageCount += 1
            if scalarState.semanticTip == nil && record.presentationVisible {
                visible.append(message)
            }
            // A malformed parent remains an inspectable message but cannot become a semantic tip;
            // its validity is persisted on this record for bounded future appends.
        }

        mutating func stageContext(_ context: SessionContextContinuation) {
            contexts = ContextRecord(
                context: context, scope: scope, lastRunID: currentEventRunID)
            ephemeralContext = context
            didStageContext = true
        }

        mutating func stageContextCumulativeDeliveredBytes(_ bytes: Int, for runID: String) {
            guard bytes >= 0, runID.utf8.count <= PersistentSessionExactState.maximumIdentityBytes else {
                invalidMutation = true; return
            }
            cumulative[runID] = CumulativeRecord(
                kind: "cumulative", scope: scope, runID: runID, bytes: bytes)
            changedCumulativeRunIDs.insert(runID)
        }

        mutating func stageCompaction(_ compaction: SessionCompactionContinuation) {
            guard let summary = compaction.summary, let boundary = compaction.boundaryEventID else {
                invalidMutation = true; return
            }
            self.compactionRecord = CompactionRecord(
                kind: "compaction", scope: scope,
                summaryDigest: PersistentSessionExactState.digestText(summary),
                summaryByteCount: summary.utf8.count, boundaryEventID: boundary)
            compactionSummaries[boundary] = summary
            didStageCompaction = true
        }

        mutating func stageVisibleMessages(_ messages: [SessionMessageSnapshot]) {
            visible = messages
        }

        mutating func appendVisibleMessages(_ messages: [SessionMessageSnapshot]) {
            visible.append(contentsOf: messages)
        }

        mutating func recordVisibleProjectionFastPath() {}
        mutating func recordVisibleProjectionRebuild(scannedMessageCount: Int) {}

        mutating func stageRecovery(_ coverage: RecoveryCoverage, recorded: RecordedRecoveryCoverage) {
            recoveries[recorded.sourceEvent.eventID] = RecoveryRecord(
                coverage: coverage, recorded: recorded, scope: scope)
            recoveryCount += 1; didStageRecovery = true
        }

        mutating func stageChildState(_ state: String, for childID: String) {
            guard !childID.isEmpty,
                  childID.utf8.count <= PersistentSessionExactState.maximumIdentityBytes,
                  !state.isEmpty,
                  state.utf8.count <= PersistentSessionExactState.maximumIdentityBytes else {
                invalidMutation = true; return
            }
            // SessionReducerTransition only needs the current lifecycle value for future
            // admission. Keep a closed classification in the durable record and authenticate the
            // producer's exact value separately; arbitrary producer prose never survives reopen.
            let classification = state
            let wasPresent = children[childID] != nil
            children[childID] = ChildRecord(
                kind: "child", scope: scope, childID: childID,
                state: PersistentSessionExactState.childClassification(classification),
                stateDigest: PersistentSessionExactState.digestText(state))
            if !wasPresent { childCount += 1 }
            changedChildID = childID
        }

        mutating func stageUnknown(_ unknown: UnknownTimelineEvent) {
            unknownRecords.append(UnknownRecord(
                kind: "unknown", scope: scope, eventID: unknown.event.eventID,
                journal: unknown.event.journal, sequence: unknown.event.sequence,
                type: "unknown", typeDigest: PersistentSessionExactState.digestText(unknown.event.type),
                offset: unknown.journalOffset,
                domains: unknown.affectedDomains,
                payloadDigest: PersistentSessionExactState.digestJSON(unknown.rawPayload)))
            unknownCount += 1
            var value = scalarState; value.unknownDomains.formUnion(unknown.affectedDomains)
            scalarState = value
        }

        mutating func stageQuarantineOnly(_ event: TimelineEvent) {
            let (next, overflow) = quarantineCount.addingReportingOverflow(1)
            guard !overflow, next < Int.max else {
                invalidMutation = true
                return
            }
            quarantineRecords.append(Self.quarantineRecord(event, scope: scope, structural: true))
            quarantineCount = next
        }

        mutating func stageQuarantine(_ event: TimelineEvent, reason: String, structural: Bool) {
            var value = scalarState
            if structural {
                value.causalOrderValid = false; value.structuralIntegrityValid = false
            } else {
                value.semanticProjectionValid = false
            }
            scalarState = value
            let (next, overflow) = quarantineCount.addingReportingOverflow(1)
            guard !overflow, next < Int.max else {
                invalidMutation = true
                return
            }
            quarantineRecords.append(Self.quarantineRecord(event, scope: scope, structural: structural))
            quarantineCount = next
            _ = reason
        }

        var scalarRecord: ScalarRecord {
            ScalarRecord(
                scalarState, seenEventCount: seenCount, messageHistoryCount: messageCount,
                recoveryCount: recoveryCount, childCount: childCount,
                unknownCount: unknownCount, quarantineCount: quarantineCount,
                lastUnknownEventID: unknownRecords.last?.eventID,
                lastQuarantineEventID: quarantineRecords.last?.eventID)
        }

        var snapshot: SessionSnapshot {
            var value = SessionSnapshot()
            value.journal = scalar.journal; value.session = scalar.session
            value.lifecycle = scalar.lifecycle; value.execution = scalar.execution
            value.attention = scalar.attention; value.attentionEvent = scalar.attentionEvent
            value.activeRun = scalar.activeRun; value.modelID = scalar.modelID
            value.activeTurn = scalar.activeTurn; value.semanticTip = scalar.semanticTip
            value.unknownDomains = scalar.unknownDomains; value.lastEventID = scalar.lastEventID
            value.lastSequence = scalar.lastSequence
            value.causalOrderValid = scalar.causalOrderValid
            value.structuralIntegrityValid = scalar.structuralIntegrityValid
            value.semanticProjectionValid = scalar.semanticProjectionValid
            value.seenEventIDs = Set(seenRecords.keys)
            value.attachments = attachments.reduce(into: [:]) { $0[$1.key] = $1.value.attachment }
            value.messageHistory = messages.values.sorted(by: Self.messageLess).map {
                $0.snapshot(body: messageBodies[$0.eventID])
            }
            value.messages = visible
            context.apply(to: &value)
            value.contextCumulativeDeliveredBytesByRun = cumulative.mapValues(\.bytes)
            if let compactionRecord {
                // The exact map stores only the summary fingerprint. A digest is not a
                // semantically valid substitute for compaction prose in this event-local view;
                // expose the body only while it is present in the bounded in-memory dependency
                // footprint and otherwise leave the field absent.
                value.compactionSummary = compactionSummaries[compactionRecord.boundaryEventID]
                value.compactionBoundaryEventID = compactionRecord.boundaryEventID
            }
            value.childStates = children.mapValues(\.state)
            let sortedRecovery = recoveries.values.sorted { $0.sourceEvent.eventID < $1.sourceEvent.eventID }
            value.recovery = sortedRecovery.map { $0.coverage() }
            value.recordedRecovery = sortedRecovery.map { $0.recorded() }
            value.unknownEvents = unknownRecords.map { record in
                UnknownTimelineEvent(
                    event: TimelineEvent(
                        eventID: record.eventID, journal: record.journal, sequence: record.sequence,
                        actor: TimelineActor(actorID: "persisted", kind: "metadata"),
                        hostRecordedAt: Date(timeIntervalSince1970: 0), type: record.type,
                        declaredDomains: record.domains,
                        payload: .object(["payload_digest": .string(record.payloadDigest)])),
                    journalOffset: record.offset,
                    rawPayload: .object(["payload_digest": .string(record.payloadDigest)]),
                    affectedDomains: record.domains)
            }
            value.corruptionReasons = quarantineRecords.map(\.classification)
            value.quarantinedEvents = quarantineRecords.map { record in
                TimelineEvent(
                    eventID: record.eventID, journal: record.journal, sequence: record.sequence,
                    actor: TimelineActor(actorID: "persisted", kind: "metadata"),
                    hostRecordedAt: Date(timeIntervalSince1970: 0), type: record.type,
                    payload: .object([
                        "classification": .string(record.classification),
                        "payload_digest": .string(record.payloadDigest),
                    ]))
            }
            return value
        }

        func encodedValue(for key: String) throws -> Data? {
            if key == PersistentSessionExactState.scalarKey {
                return try PersistentSessionExactState.encode(scalarRecord)
            }
            if key == PersistentSessionExactState.contextKey {
                guard let contexts else { return nil }
                return try PersistentSessionExactState.encode(contexts)
            }
            if key == PersistentSessionExactState.compactionKey {
                guard let compactionRecord else { return nil }
                return try PersistentSessionExactState.encode(compactionRecord)
            }
            let parts = key.split(separator: "/")
            guard parts.count == 3 else { return nil }
            let kind = String(parts[1])
            func id<T>(_ values: [String: T]) -> String? {
                values.keys.first { PersistentSessionExactState.slotKey(kind: kind, identity: $0) == key }
            }
            if kind == "seen", let id = id(seenRecords), let value = seenRecords[id] {
                return try PersistentSessionExactState.encode(value)
            }
            if kind == "attachment", let id = id(attachments), let value = attachments[id] {
                return try PersistentSessionExactState.encode(value)
            }
            if kind == "message", let id = id(messages), let value = messages[id] {
                return try PersistentSessionExactState.encode(value)
            }
            if kind == "cumulative", let id = id(cumulative), let value = cumulative[id] {
                return try PersistentSessionExactState.encode(value)
            }
            if kind == "recovery", let id = id(recoveries), let value = recoveries[id] {
                return try PersistentSessionExactState.encode(value)
            }
            if kind == "child", let id = id(children), let value = children[id] {
                return try PersistentSessionExactState.encode(value)
            }
            if kind == "unknown", let value = unknownRecords.first(
                where: { PersistentSessionExactState.slotKey(kind: kind, identity: $0.eventID) == key }) {
                return try PersistentSessionExactState.encode(value)
            }
            if kind == "quarantine", let value = quarantineRecords.first(
                where: { PersistentSessionExactState.slotKey(kind: kind, identity: $0.eventID) == key }) {
                return try PersistentSessionExactState.encode(value)
            }
            return nil
        }

        private static func visibleFromRecords(
            messages: [String: MessageRecord],
            bodies: [String: String],
            tip: EventRef?,
            scope: JournalRef?
        ) -> [SessionMessageSnapshot] {
            guard let tip else { return [] }
            var current: EventRef? = tip
            var visited: Set<String> = []
            var result: [SessionMessageSnapshot] = []
            while let ref = current, visited.insert(ref.eventID).inserted,
                  ref.journal == scope,
                  let value = messages[ref.eventID] {
                if value.presentationVisible { result.append(value.snapshot(body: bodies[value.eventID])) }
                current = value.conversationParent
            }
            return result.reversed()
        }

        private static func messageLess(_ lhs: MessageRecord, _ rhs: MessageRecord) -> Bool {
            lhs.sequence == rhs.sequence ? lhs.eventID < rhs.eventID : lhs.sequence < rhs.sequence
        }

        private static func quarantineRecord(
            _ event: TimelineEvent, scope: String, structural: Bool
        ) -> QuarantineRecord {
            QuarantineRecord(
                kind: "quarantine", scope: scope, eventID: event.eventID,
                journal: event.journal, sequence: event.sequence, type: "quarantine",
                typeDigest: PersistentSessionExactState.digestText(event.type),
                classification: structural ? "structural" : "semantic",
                structural: structural,
                payloadDigest: PersistentSessionExactState.digestJSON(event.payload))
        }
    }
}
