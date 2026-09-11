import Foundation

/// An exact, copy-on-write Work reducer backed by ``PersistentProjectionRadixMap``.
///
/// Only the scalar continuation and the exact slots needed by one incoming event are prefetched.
/// The shared transition function runs against an event-local overlay; changed typed records are
/// then written to a new map root.  No root is published by this type, so a failed operation leaves
/// the caller's prior root authoritative. Child and recovery evidence is stored as bounded,
/// metadata-only typed records. The original
/// event payload is never copied into this map; child state is classified and recovery caveats are
/// represented by count/digest metadata.
public struct PersistentWorkExactState: Sendable {
    public static let schemaVersion = 6
    public static let maximumIdentityBytes = 1_024
    /// One mutation may need to authenticate every active attachment in the affected Session.
    /// WorkService bounds those relationships to 64, leaving room for the event's other typed
    /// dependencies while keeping disk work finite and explicit.
    public static let maximumOperationSlots = 96

    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case missingScalar
        case invalidRecord
        case duplicateEvent(String)
        case unsupportedEvent(String)
        case tooManyPrefetchedSlots
        case map(PersistentProjectionRadixMap.MapError)

        public var errorDescription: String? {
            switch self {
            case .missingScalar: return "Persistent Work exact state has no scalar continuation."
            case .invalidRecord: return "Persistent Work exact state contains an invalid typed record."
            case .duplicateEvent(let id): return "Persistent Work event was already observed: \(id)."
            case .unsupportedEvent(let type): return "Persistent Work event family is not exact in v6: \(type)."
            case .tooManyPrefetchedSlots: return "Persistent Work exact-state prefetch exceeds its bound."
            case .map(let error): return error.localizedDescription
            }
        }
    }

    public struct ApplyResult: Hashable, Sendable {
        public let previousRoot: PersistentProjectionRadixMap.Root?
        public let root: PersistentProjectionRadixMap.Root
        /// Event-local diagnostic projection. Unprefetched membership is intentionally absent;
        /// this is never a complete WorkSnapshot or an exact checkpoint.
        public let eventLocalSnapshot: WorkSnapshot
        public let changedSlots: [String]
        public let lastMutationMetrics: PersistentProjectionRadixMap.Metrics

        fileprivate init(previousRoot: PersistentProjectionRadixMap.Root?, root: PersistentProjectionRadixMap.Root,
                         eventLocalSnapshot: WorkSnapshot, changedSlots: [String],
                         lastMutationMetrics: PersistentProjectionRadixMap.Metrics) {
            self.previousRoot = previousRoot
            self.root = root
            self.eventLocalSnapshot = eventLocalSnapshot
            self.changedSlots = changedSlots
            self.lastMutationMetrics = lastMutationMetrics
        }
    }

    private static let scalarKey = "work-exact-v6/scalar"
    private let map: PersistentProjectionRadixMap
    private var root: PersistentProjectionRadixMap.Root?
    private var lastSnapshot: WorkSnapshot

    public var currentRoot: PersistentProjectionRadixMap.Root? { root }
    /// The latest event-local view. On a cold open this contains only scalar facts; callers that
    /// need exact membership should apply the next event (which performs the bounded prefetch).
    public var eventLocalSnapshot: WorkSnapshot { lastSnapshot }

    public init(map: PersistentProjectionRadixMap, root: PersistentProjectionRadixMap.Root? = nil) throws {
        guard case .work = map.journal.owner else { throw Error.invalidRecord }
        self.map = map
        self.root = root
        if let root {
            guard let scalar: ScalarRecord = try Self.read(map: map, root: root, key: Self.scalarKey)
            else { throw Error.missingScalar }
            try scalar.validate(scope: map.journal)
            self.lastSnapshot = Self.scalarSnapshot(scalar)
        }
        else { self.lastSnapshot = WorkSnapshot() }
    }

    /// Applies one canonical event. All disk reads happen before the transition and all writes
    /// target immutable map objects. The old `currentRoot` is changed only after every write and
    /// validation succeeds.
    public mutating func apply(_ event: TimelineEvent) throws -> ApplyResult {
        try Self.validateIncomingIdentities(event)
        let previousRoot = root
        let scalar = try loadScalar()
        let refs = try Prefetch(map: map, root: root, event: event, scalar: scalar)
        guard refs.seen == nil else { throw Error.duplicateEvent(event.eventID) }

        var overlay = EventLocalOverlay(
            scalar: scalar, scope: map.journal.stableKey, seen: refs.seenRecords, runs: refs.runs,
            actions: refs.actions, handles: refs.handles, agentHandles: refs.agentHandles,
            attachments: refs.attachments,
            attachmentCounts: refs.attachmentCounts, commands: refs.commands,
            children: refs.children, recoveries: refs.recoveries,
            unknowns: refs.unknowns, quarantines: refs.quarantines)
        let before = overlay.snapshot
        WorkReducerTransition.apply(event, to: &overlay)
        guard !overlay.invalidMutation else { throw Error.invalidRecord }
        try overlay.scalarRecord.validate(scope: map.journal)
        let after = overlay.snapshot
        let changedKeys = Self.changedKeys(event: event, before: before, after: after, overlay: overlay)
        guard changedKeys.count <= Self.maximumOperationSlots else { throw Error.tooManyPrefetchedSlots }

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
            try map.validate(root: finalRoot)
            root = finalRoot
            lastSnapshot = after
            return ApplyResult(previousRoot: previousRoot, root: finalRoot,
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
        guard let value: ScalarRecord = try Self.read(map: map, root: root, key: Self.scalarKey)
        else { throw Error.missingScalar }
        try value.validate(scope: map.journal)
        return value
    }

    private func write(scalar: ScalarRecord) throws -> PersistentProjectionRadixMap.TransactionResult {
        let encoded = try Self.encode(scalar)
        return try map.setting(root: root, key: Self.scalarKey, value: encoded)
    }

    private static func changedKeys(event: TimelineEvent, before: WorkSnapshot, after: WorkSnapshot,
                                    overlay: EventLocalOverlay) -> [String] {
        var keys = [scalarKey]
        if after.seenEventIDs.count > before.seenEventIDs.count {
            keys.append(slotKey(kind: "seen", identity: event.eventID))
        }
        if let run = event.run, before.observedRunIDs != after.observedRunIDs, overlay.runs[run.runID] != nil { keys.append(slotKey(kind: "run", identity: run.runID)) }
        if let action = event.action, before.actions[action.actionID] != after.actions[action.actionID] { keys.append(slotKey(kind: "action", identity: action.actionID)) }
        if let handle = event.handle, before.handles[handle.handleID] != after.handles[handle.handleID] { keys.append(slotKey(kind: "handle", identity: handle.handleID)) }
        if let handle = event.handle,
           before.agentHandles[handle.handleID] != after.agentHandles[handle.handleID] {
            keys.append(slotKey(kind: "agent-handle", identity: handle.handleID))
        }
        if let attachment = event.sessionAttachment, overlay.attachments[attachment.attachmentID] != nil {
            if before.sessionAttachments[attachment.attachmentID] != after.sessionAttachments[attachment.attachmentID] {
                keys.append(slotKey(kind: "attachment", identity: attachment.attachmentID))
            }
            // The exact per-Session count can change while the boolean membership projection
            // remains true (for example, the second attachment to one Session). A detach derives
            // its Session from the stored attachment rather than the optional event envelope, so
            // persist every old/new/envelope Session count that the bounded prefetch loaded.
            let affectedSessionIDs = Set([
                before.sessionAttachments[attachment.attachmentID]?.session.sessionID,
                after.sessionAttachments[attachment.attachmentID]?.session.sessionID,
                event.session?.sessionID,
            ].compactMap { $0 })
            for sessionID in affectedSessionIDs.sorted()
            where overlay.attachmentCounts[sessionID] != nil {
                keys.append(slotKey(kind: "attachment-count", identity: sessionID))
            }
        }
        if let command = event.command, before.commands[command.commandID] != after.commands[command.commandID] { keys.append(slotKey(kind: "command", identity: command.commandID)) }
        if event.type == TimelineEventType.childLifecycle,
           let childID = event.payload["child_id"]?.stringValue {
            keys.append(slotKey(kind: "child", identity: childID))
        }
        if event.type == TimelineEventType.recoveryCoverage {
            keys.append(slotKey(kind: "recovery", identity: event.eventID))
        }
        if after.unknownEvents.count > before.unknownEvents.count { keys.append(slotKey(kind: "unknown", identity: event.eventID)) }
        if after.quarantinedEvents.count > before.quarantinedEvents.count { keys.append(slotKey(kind: "quarantine", identity: event.eventID)) }
        return Array(Set(keys)).sorted()
    }

    private static func slotKey(kind: String, identity: String) -> String {
        let material = "work-exact-slot-v1\0\(kind.count):\(kind)\0\(identity.utf8.count):\(identity)"
        return "work-exact-v6/\(kind)/" + AviarySHA256.hash(data: Data(material.utf8)).description
    }

    private static func validateIncomingIdentities(_ event: TimelineEvent) throws {
        let values = [event.eventID, event.previousEventID,
                      event.command?.causalCursor?.eventID,
                      event.command?.client?.clientID,
                      event.command?.sessionAttachment?.attachmentID,
                      event.journal.journalID, event.journal.stableKey,
                      event.work?.workID, event.work?.workHostID, event.workHost?.workHostID,
                      event.session?.sessionID, event.sessionAttachment?.attachmentID,
                      event.run?.runID, event.turn?.turnID, event.action?.actionID,
                      event.handle?.handleID, event.command?.commandID].compactMap { $0 }
        guard values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximumIdentityBytes }) else {
            throw Error.invalidRecord
        }
    }

    private static func validStoredAgentHandle(_ handle: WorkAgentHandleSnapshot) -> Bool {
        guard handle.deadline.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
            return false
        }
        if let cancellation = handle.cancellationEvidence, cancellation.cause != .client,
           (cancellation.command != nil || cancellation.event.client != nil) {
            return false
        }
        if let cancellation = handle.cancellationEvidence, cancellation.cause == .deadline,
           !validDeadlineEvidence(handle.deadline, recordedAt: cancellation.event.hostRecordedAt) {
            return false
        }
        if let terminal = handle.terminalEvidence, terminal.outcome == .expired,
           !validDeadlineEvidence(handle.deadline, recordedAt: terminal.event.hostRecordedAt) {
            return false
        }
        if let cancellation = handle.cancellationEvidence,
           let terminal = handle.terminalEvidence,
           !cancellationAllowsTerminalOutcome(
               cancellation.cause, outcome: terminal.outcome) {
            return false
        }
        return true
    }

    private static func cancellationAllowsTerminalOutcome(
        _ cause: WorkAgentHandleCancellationCause?,
        outcome: WorkAgentHandleTerminalOutcome
    ) -> Bool {
        switch cause {
        case .deadline:
            return [.expired, .indeterminate].contains(outcome)
        case .client, .workDestruction, .hostShutdown:
            return [.canceled, .indeterminate].contains(outcome)
        case nil:
            return true
        }
    }

    private static func validDeadlineEvidence(_ deadline: Date?, recordedAt: Date) -> Bool {
        guard let deadline, deadline.timeIntervalSince1970.isFinite,
              recordedAt.timeIntervalSince1970.isFinite else { return false }
        return recordedAt >= deadline
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func digestJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return "sha256:" + AviarySHA256.hash(data: data).description
    }

    private static func digestTextArray(_ values: [String]) -> String {
        digestJSON(.array(values.map { .string($0) }))
    }

    private static func scalarSnapshot(_ scalar: ScalarRecord) -> WorkSnapshot {
        var value = WorkSnapshot()
        value.journal = scalar.journal; value.work = scalar.work; value.workHost = scalar.workHost
        value.lifecycle = scalar.lifecycle; value.execution = scalar.execution; value.activeRun = scalar.activeRun
        value.activeRunSession = scalar.activeRunSession
        value.activeRunSessionAttachment = scalar.activeRunSessionAttachment
        value.modelID = scalar.modelID; value.activeTurn = scalar.activeTurn
        value.lastHostSequence = scalar.lastHostSequence; value.unknownDomains = scalar.unknownDomains
        value.lastEventID = scalar.lastEventID; value.lastSequence = scalar.lastSequence
        value.causalOrderValid = scalar.causalOrderValid; value.structuralIntegrityValid = scalar.structuralIntegrityValid
        value.semanticProjectionValid = scalar.semanticProjectionValid
        return value
    }

    private static func read<T: Decodable>(map: PersistentProjectionRadixMap,
                                           root: PersistentProjectionRadixMap.Root?, key: String) throws -> T? {
        let result: PersistentProjectionRadixMap.LookupResult
        do { result = try map.lookup(root: root, key: key) }
        catch let error as PersistentProjectionRadixMap.MapError { throw Error.map(error) }
        guard let bytes = result.value else { return nil }
        do { return try JSONDecoder().decode(T.self, from: bytes) }
        catch { throw Error.invalidRecord }
    }

    // MARK: Typed records

    private struct ScalarRecord: Codable, Hashable, Sendable {
        let schemaVersion: Int; let kind: String; let journal: JournalRef?
        let work: WorkRef?; let workHost: WorkHostRef?; let lifecycle: WorkLifecycle; let execution: WorkExecution
        let activeRun: RunRef?; let activeRunSession: SessionRef?
        let activeRunSessionAttachment: SessionAttachmentRef?
        let modelID: String?; let activeTurn: TurnRef?; let lastHostSequence: Int?
        let unknownDomains: Set<TimelineDomain>; let lastEventID: String?; let lastSequence: Int
        let causalOrderValid: Bool; let structuralIntegrityValid: Bool; let semanticProjectionValid: Bool
        let seenEventCount: Int; let activeActionCount: Int; let outstandingHandleCount: Int
        let liveAgentHandleCount: Int; let unreapedAgentHandleCount: Int
        let retainedAgentHandleCount: Int
        let lastUnknownEventID: String?; let lastQuarantineEventID: String?

        static func empty(journal: JournalRef) -> ScalarRecord {
            var snapshot = WorkSnapshot()
            snapshot.journal = journal
            if case .work(let work) = journal.owner {
                snapshot.work = work
                snapshot.workHost = WorkHostRef(work.workHostID)
            }
            return ScalarRecord(
                BoundedWorkScalarContinuation(snapshot: snapshot),
                seenEventCount: 0,
                activeActionCount: 0,
                outstandingHandleCount: 0,
                liveAgentHandleCount: 0,
                unreapedAgentHandleCount: 0,
                retainedAgentHandleCount: 0)
        }

        init(_ scalar: BoundedWorkScalarContinuation, seenEventCount: Int,
             activeActionCount: Int, outstandingHandleCount: Int,
             liveAgentHandleCount: Int, unreapedAgentHandleCount: Int,
             retainedAgentHandleCount: Int,
             lastUnknownEventID: String? = nil, lastQuarantineEventID: String? = nil) {
            schemaVersion = PersistentWorkExactState.schemaVersion; kind = "scalar"; journal = scalar.journal; work = scalar.work
            workHost = scalar.workHost; lifecycle = scalar.lifecycle; execution = scalar.execution
            activeRun = scalar.activeRun; activeRunSession = scalar.activeRunSession
            activeRunSessionAttachment = scalar.activeRunSessionAttachment
            modelID = scalar.modelID; activeTurn = scalar.activeTurn
            lastHostSequence = scalar.lastHostSequence; unknownDomains = scalar.unknownDomains
            lastEventID = scalar.lastEventID; lastSequence = scalar.lastSequence
            causalOrderValid = scalar.causalOrderValid; structuralIntegrityValid = scalar.structuralIntegrityValid
            semanticProjectionValid = scalar.semanticProjectionValid; self.seenEventCount = seenEventCount
            self.activeActionCount = activeActionCount; self.outstandingHandleCount = outstandingHandleCount
            self.liveAgentHandleCount = liveAgentHandleCount
            self.unreapedAgentHandleCount = unreapedAgentHandleCount
            self.retainedAgentHandleCount = retainedAgentHandleCount
            self.lastUnknownEventID = lastUnknownEventID; self.lastQuarantineEventID = lastQuarantineEventID
        }

        func validate(scope: JournalRef) throws {
            guard schemaVersion == PersistentWorkExactState.schemaVersion,
                  kind == "scalar",
                  journal == scope,
                  lastSequence >= 0, lastSequence < Int.max,
                  seenEventCount == lastSequence,
                  activeActionCount >= 0, activeActionCount <= seenEventCount,
                  outstandingHandleCount >= 0, outstandingHandleCount <= seenEventCount,
                  liveAgentHandleCount >= 0,
                  liveAgentHandleCount <= unreapedAgentHandleCount,
                  unreapedAgentHandleCount <= retainedAgentHandleCount,
                  retainedAgentHandleCount <= WorkAgentHandleSnapshot.maximumRetainedPerWork,
                  retainedAgentHandleCount <= seenEventCount,
                  lastHostSequence.map({ $0 >= 0 && $0 < Int.max }) ?? true,
                  (activeRunSession == nil) == (activeRunSessionAttachment == nil),
                  (activeRun == nil) == (activeRunSession == nil),
                  [lastEventID, lastUnknownEventID, lastQuarantineEventID].compactMap({ $0 })
                      .allSatisfy({ !$0.isEmpty && $0.utf8.count <= PersistentWorkExactState.maximumIdentityBytes })
            else { throw Error.invalidRecord }
            guard case .work(let owner) = scope.owner,
                  work == owner,
                  workHost == WorkHostRef(owner.workHostID),
                  lastSequence == 0 ? lastEventID == nil : lastEventID != nil,
                  [work?.workID, work?.workHostID, workHost?.workHostID,
                   activeRun?.runID, activeRunSession?.sessionID,
                   activeRunSessionAttachment?.attachmentID, modelID, activeTurn?.turnID]
                    .compactMap({ $0 })
                    .allSatisfy({ !$0.isEmpty && $0.utf8.count <= PersistentWorkExactState.maximumIdentityBytes })
            else { throw Error.invalidRecord }
        }
    }

    private struct SeenRecord: Codable, Hashable, Sendable { let kind: String; let scope: String; let eventID: String; let sequence: Int }
    private struct RunRecord: Codable, Hashable, Sendable { let kind: String; let scope: String; let run: RunRef }
    private struct ActionRecord: Codable, Hashable, Sendable { let kind: String; let scope: String; let action: WorkActionSnapshot; let isActive: Bool }
    private struct HandleRecord: Codable, Hashable, Sendable { let kind: String; let scope: String; let handle: WorkHandleSnapshot }
    private struct AgentHandleRecord: Codable, Hashable, Sendable {
        let kind: String
        let scope: String
        let handle: WorkAgentHandleSnapshot
    }
    private struct AttachmentRecord: Codable, Hashable, Sendable { let kind: String; let scope: String; let work: WorkRef; let attachment: WorkSessionAttachmentSnapshot }
    private struct CountRecord: Codable, Hashable, Sendable {
        let kind: String
        let scope: String
        let session: SessionRef
        let count: Int
        /// Sorted exact membership, not merely a plausible aggregate. Prefetch authenticates
        /// every member against its typed attachment record before the transition can use it.
        let activeAttachmentIDs: [String]
    }
    private struct CommandRecord: Codable, Hashable, Sendable { let kind: String; let scope: String; let command: WorkCommandSnapshot }
    private struct ChildRecord: Codable, Hashable, Sendable {
        let kind: String
        let scope: String
        let childID: String
        let state: String
        let stateDigest: String
    }
    /// Recovery records deliberately retain only the typed coverage envelope and a digest/count
    /// for caveats.  Caveat text may contain private model/runtime material and is not durable.
    private struct RecoveryRecord: Codable, Hashable, Sendable {
        let kind: String
        let scope: String
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
    }
    private struct UnknownRecord: Codable, Hashable, Sendable { let kind: String; let scope: String; let eventID: String; let journal: JournalRef; let sequence: Int; let type: String; let offset: Int; let domains: Set<TimelineDomain>; let payloadDigest: String }
    private struct QuarantineRecord: Codable, Hashable, Sendable { let kind: String; let scope: String; let eventID: String; let journal: JournalRef; let sequence: Int; let type: String; let classification: String; let structural: Bool; let payloadDigest: String }

    // MARK: bounded prefetch and event-local conformance

    private struct Prefetch {
        let seen: SeenRecord?
        let seenRecords: [String: SeenRecord]; let runs: [String: RunRecord]; let actions: [String: ActionRecord]
        let handles: [String: HandleRecord]; let agentHandles: [String: AgentHandleRecord]
        let attachments: [String: AttachmentRecord]; let attachmentCounts: [String: CountRecord]
        let commands: [String: CommandRecord]; let children: [String: ChildRecord]
        let recoveries: [String: RecoveryRecord]
        let unknowns: [UnknownRecord]; let quarantines: [QuarantineRecord]

        init(map: PersistentProjectionRadixMap, root: PersistentProjectionRadixMap.Root?, event: TimelineEvent, scalar: ScalarRecord) throws {
            guard case .work(let expectedWork) = map.journal.owner else { throw Error.invalidRecord }
            var seenRecords: [String: SeenRecord] = [:]; var runs: [String: RunRecord] = [:]; var actions: [String: ActionRecord] = [:]
            var handles: [String: HandleRecord] = [:]; var agentHandles: [String: AgentHandleRecord] = [:]
            var attachments: [String: AttachmentRecord] = [:]; var counts: [String: CountRecord] = [:]; var commands: [String: CommandRecord] = [:]
            var children: [String: ChildRecord] = [:]; var recoveries: [String: RecoveryRecord] = [:]
            var slotCount = 0
            func load<T: Decodable>(_ key: String) throws -> T? { slotCount += 1; guard slotCount <= maximumOperationSlots else { throw Error.tooManyPrefetchedSlots }; return try PersistentWorkExactState.read(map: map, root: root, key: key) }
            let seen: SeenRecord? = try load(slotKey(kind: "seen", identity: event.eventID))
            if let seen { guard seen.kind == "seen", seen.scope == map.journal.stableKey, seen.eventID == event.eventID, seen.sequence > 0 else { throw Error.invalidRecord }; seenRecords[seen.eventID] = seen }
            if let prior = event.previousEventID, let record: SeenRecord = try load(slotKey(kind: "seen", identity: prior)) { guard record.kind == "seen", record.scope == map.journal.stableKey, record.eventID == prior, record.sequence > 0 else { throw Error.invalidRecord }; seenRecords[record.eventID] = record }
            if let cursor = event.command?.causalCursor, let prior = cursor.eventID, let record: SeenRecord = try load(slotKey(kind: "seen", identity: prior)) { guard record.kind == "seen", record.scope == map.journal.stableKey, record.eventID == prior, record.sequence == cursor.sequence else { throw Error.invalidRecord }; seenRecords[record.eventID] = record }
            if let run = event.run, let record: RunRecord = try load(slotKey(kind: "run", identity: run.runID)) { guard record.kind == "run", record.scope == map.journal.stableKey, record.run.runID == run.runID else { throw Error.invalidRecord }; runs[run.runID] = record }
            if let action = event.action, let record: ActionRecord = try load(slotKey(kind: "action", identity: action.actionID)) { guard record.kind == "action", record.scope == map.journal.stableKey, record.action.action.actionID == action.actionID else { throw Error.invalidRecord }; actions[action.actionID] = record }
            if let handle = event.handle, let record: HandleRecord = try load(slotKey(kind: "handle", identity: handle.handleID)) { guard record.kind == "handle", record.scope == map.journal.stableKey, record.handle.handle.handleID == handle.handleID else { throw Error.invalidRecord }; handles[handle.handleID] = record }
            if let handle = event.handle,
               let record: AgentHandleRecord = try load(slotKey(
                   kind: "agent-handle", identity: handle.handleID)) {
                guard record.kind == "agent-handle", record.scope == map.journal.stableKey,
                      record.handle.handle.handleID == handle.handleID,
                      PersistentWorkExactState.validStoredAgentHandle(record.handle) else {
                    throw Error.invalidRecord
                }
                agentHandles[handle.handleID] = record
                let proofs = [
                    record.handle.cancellationEvidence?.event,
                    record.handle.terminalEvidence?.event,
                ].compactMap { $0 }
                var proofEventIDs = Set<String>()
                for proof in proofs {
                    proofEventIDs.insert(proof.event.eventID)
                    if let previous = proof.previousEventID { proofEventIDs.insert(previous) }
                    if let cause = proof.causedByEventID { proofEventIDs.insert(cause.eventID) }
                }
                if let cleanup = record.handle.terminalEvidence?.cleanup.evidence {
                    proofEventIDs.insert(cleanup.eventID)
                }
                for eventID in proofEventIDs.sorted() where seenRecords[eventID] == nil {
                    guard let proofRecord: SeenRecord = try load(slotKey(
                        kind: "seen", identity: eventID)),
                          proofRecord.kind == "seen",
                          proofRecord.scope == map.journal.stableKey,
                          proofRecord.eventID == eventID,
                          proofRecord.sequence > 0 else { throw Error.invalidRecord }
                    seenRecords[eventID] = proofRecord
                }
            }
            if let evidence = (event.type == TimelineEventType.agentHandleTerminal
                ? (decodeTimelineValue(event.payload) as WorkAgentHandleTerminalPayload?)?.cleanup.evidence
                : nil),
               let record: SeenRecord = try load(slotKey(kind: "seen", identity: evidence.eventID)) {
                guard record.kind == "seen", record.scope == map.journal.stableKey,
                      record.eventID == evidence.eventID, record.sequence > 0 else {
                    throw Error.invalidRecord
                }
                seenRecords[record.eventID] = record
            }
            // Match the canonical transition's dependency footprint. A detach derives its
            // Session exclusively from the stored attachment; an arbitrary envelope Session is
            // not evidence and must not expand the bounded authentication set. An attach needs
            // the target count, and an existing same-ID attachment also needs its stored count
            // for the stage operation. A conflicting reattach is quarantined before staging, so
            // authenticating only the stored side preserves that canonical outcome even when two
            // Sessions are each at their 64-attachment bound.
            let isAttachmentMutation = event.type == TimelineEventType.sessionAttached
                || event.type == TimelineEventType.sessionDetached
                || event.type == TimelineEventType.sessionAttachmentCapabilityChanged
            let needsStoredAttachment = isAttachmentMutation
                || event.type == TimelineEventType.runStarted
                || event.type == TimelineEventType.recoveryCoverage
                || event.type == TimelineEventType.agentHandleQueued
            var affectedSessions = Set<SessionRef>()
            var storedAttachment: AttachmentRecord?
            if needsStoredAttachment, let attachment = event.sessionAttachment,
               let record: AttachmentRecord = try load(slotKey(
                   kind: "attachment", identity: attachment.attachmentID)) {
                guard record.kind == "attachment", record.scope == map.journal.stableKey,
                      record.work == expectedWork,
                      record.attachment.attachment.attachmentID == attachment.attachmentID else {
                    throw Error.invalidRecord
                }
                attachments[attachment.attachmentID] = record
                storedAttachment = record
            }
            if event.type == TimelineEventType.agentHandleCancelRequested,
               let caller = event.command?.sessionAttachment,
               attachments[caller.attachmentID] == nil,
               let record: AttachmentRecord = try load(slotKey(
                   kind: "attachment", identity: caller.attachmentID)) {
                guard record.kind == "attachment", record.scope == map.journal.stableKey,
                      record.work == expectedWork,
                      record.attachment.attachment == caller else { throw Error.invalidRecord }
                attachments[caller.attachmentID] = record
                affectedSessions.insert(record.attachment.session)
            }
            switch event.type {
            case TimelineEventType.sessionDetached,
                 TimelineEventType.sessionAttachmentCapabilityChanged:
                if let session = storedAttachment?.attachment.session {
                    affectedSessions.insert(session)
                }
            case TimelineEventType.sessionAttached:
                if let storedAttachment {
                    affectedSessions.insert(storedAttachment.attachment.session)
                    if storedAttachment.attachment.session == event.session,
                       let session = event.session {
                        affectedSessions.insert(session)
                    }
                } else if let session = event.session {
                    affectedSessions.insert(session)
                }
            case TimelineEventType.recoveryCoverage:
                if let session = storedAttachment?.attachment.session {
                    affectedSessions.insert(session)
                }
            case TimelineEventType.runStarted:
                // run.started authenticates its exact Session/attachment pair through the
                // stored attachment. Prefetch that Session's bounded membership before the
                // shared transition checks the attachment is currently attached.
                if let session = storedAttachment?.attachment.session {
                    affectedSessions.insert(session)
                }
            case TimelineEventType.agentHandleQueued:
                if let session = storedAttachment?.attachment.session {
                    affectedSessions.insert(session)
                }
            default:
                break
            }
            for session in affectedSessions.sorted(by: { $0.sessionID < $1.sessionID }) {
                if let record: CountRecord = try load(slotKey(
                    kind: "attachment-count", identity: session.sessionID)) {
                    guard record.kind == "attachment-count",
                          record.scope == map.journal.stableKey,
                          record.session == session, record.count >= 0,
                          record.count <= scalar.seenEventCount,
                          record.count == record.activeAttachmentIDs.count,
                          record.activeAttachmentIDs.count
                            <= WorkServiceBounds.maxSessionAttachmentsPerWork,
                          record.activeAttachmentIDs == record.activeAttachmentIDs.sorted(),
                          Set(record.activeAttachmentIDs).count
                            == record.activeAttachmentIDs.count,
                          record.activeAttachmentIDs.allSatisfy({
                              !$0.isEmpty && $0.utf8.count
                                <= PersistentWorkExactState.maximumIdentityBytes
                          }) else {
                        throw Error.invalidRecord
                    }
                    counts[session.sessionID] = record
                    for attachmentID in record.activeAttachmentIDs {
                        let member: AttachmentRecord
                        if let loaded = attachments[attachmentID] {
                            member = loaded
                        } else {
                            guard let loaded: AttachmentRecord = try load(slotKey(
                                kind: "attachment", identity: attachmentID)) else {
                                throw Error.invalidRecord
                            }
                            member = loaded
                            attachments[attachmentID] = loaded
                        }
                        guard member.kind == "attachment",
                              member.scope == map.journal.stableKey,
                              member.work == expectedWork,
                              member.attachment.attachment.attachmentID == attachmentID,
                              member.attachment.session == session,
                              member.attachment.isAttached else {
                            throw Error.invalidRecord
                        }
                    }
                }
            }
            for record in attachments.values {
                let members = counts[record.attachment.session.sessionID]?.activeAttachmentIDs ?? []
                guard members.contains(record.attachment.attachment.attachmentID)
                    == record.attachment.isAttached else {
                    throw Error.invalidRecord
                }
            }
            if let command = event.command, let record: CommandRecord = try load(slotKey(kind: "command", identity: command.commandID)) { guard record.kind == "command", record.scope == map.journal.stableKey, record.command.command.commandID == command.commandID else { throw Error.invalidRecord }; commands[command.commandID] = record }
            if let childID = event.payload["child_id"]?.stringValue,
               let record: ChildRecord = try load(slotKey(kind: "child", identity: childID)) {
                guard record.kind == "child", record.scope == map.journal.stableKey,
                      record.childID == childID, !record.state.isEmpty,
                      record.stateDigest.hasPrefix("sha256:") else { throw Error.invalidRecord }
                children[childID] = record
            }
            if event.type == TimelineEventType.recoveryCoverage,
               let record: RecoveryRecord = try load(slotKey(kind: "recovery", identity: event.eventID)) {
                guard record.kind == "recovery", record.scope == map.journal.stableKey,
                      record.sourceEvent.eventID == event.eventID,
                      record.sourceEvent.journal == map.journal,
                      record.caveatCount >= 0,
                      record.caveatCount <= 256 else { throw Error.invalidRecord }
                recoveries[event.eventID] = record
            }
            var unknowns: [UnknownRecord] = []
            if let id = scalar.lastUnknownEventID, let record: UnknownRecord = try load(slotKey(kind: "unknown", identity: id)) { guard record.kind == "unknown", record.scope == map.journal.stableKey, record.journal == map.journal, record.eventID == id else { throw Error.invalidRecord }; unknowns.append(record) }
            var quarantines: [QuarantineRecord] = []
            if let id = scalar.lastQuarantineEventID, let record: QuarantineRecord = try load(slotKey(kind: "quarantine", identity: id)) { guard record.kind == "quarantine", record.scope == map.journal.stableKey, record.journal == map.journal, record.eventID == id else { throw Error.invalidRecord }; quarantines.append(record) }
            self.seen = seen; self.seenRecords = seenRecords; self.runs = runs; self.actions = actions
            self.handles = handles; self.agentHandles = agentHandles
            self.attachments = attachments; self.attachmentCounts = counts
            self.commands = commands; self.children = children; self.recoveries = recoveries
            self.unknowns = unknowns; self.quarantines = quarantines
        }
    }

    private struct EventLocalOverlay: WorkTransitionState {
        var scalarState: BoundedWorkScalarContinuation; let scope: String; var seen: [String: SeenRecord]; var runs: [String: RunRecord]; var actions: [String: ActionRecord]; var handles: [String: HandleRecord]; var agentHandles: [String: AgentHandleRecord]; var attachments: [String: AttachmentRecord]; var attachmentCounts: [String: CountRecord]; var commands: [String: CommandRecord]; var children: [String: ChildRecord]; var recoveries: [String: RecoveryRecord]; var unknownRecords: [UnknownRecord]; var quarantineRecords: [QuarantineRecord]; var seenCount: Int; var activeActions: Int; var outstandingHandles: Int; var liveAgentHandles: Int; var unreapedAgentHandles: Int; var retainedAgentHandles: Int; var invalidMutation = false
        let work: WorkRef
        init(scalar: ScalarRecord, scope: String, seen: [String: SeenRecord], runs: [String: RunRecord], actions: [String: ActionRecord], handles: [String: HandleRecord], agentHandles: [String: AgentHandleRecord], attachments: [String: AttachmentRecord], attachmentCounts: [String: CountRecord], commands: [String: CommandRecord], children: [String: ChildRecord], recoveries: [String: RecoveryRecord], unknowns: [UnknownRecord], quarantines: [QuarantineRecord]) {
            var continuation = BoundedWorkScalarContinuation(snapshot: WorkSnapshot())
            continuation.journal = scalar.journal; continuation.work = scalar.work; continuation.workHost = scalar.workHost
            continuation.lifecycle = scalar.lifecycle; continuation.execution = scalar.execution
            continuation.activeRun = scalar.activeRun; continuation.modelID = scalar.modelID; continuation.activeTurn = scalar.activeTurn
            continuation.activeRunSession = scalar.activeRunSession
            continuation.activeRunSessionAttachment = scalar.activeRunSessionAttachment
            continuation.lastHostSequence = scalar.lastHostSequence; continuation.unknownDomains = scalar.unknownDomains
            continuation.lastEventID = scalar.lastEventID; continuation.lastSequence = scalar.lastSequence
            continuation.causalOrderValid = scalar.causalOrderValid; continuation.structuralIntegrityValid = scalar.structuralIntegrityValid
            continuation.semanticProjectionValid = scalar.semanticProjectionValid
            scalarState = continuation
            self.scope = scope
            self.work = scalar.work!
            self.seen = seen; self.runs = runs; self.actions = actions; self.handles = handles
            self.agentHandles = agentHandles; self.attachments = attachments
            self.attachmentCounts = attachmentCounts; self.commands = commands
            self.children = children; self.recoveries = recoveries; unknownRecords = unknowns
            quarantineRecords = quarantines; seenCount = scalar.seenEventCount
            activeActions = scalar.activeActionCount; outstandingHandles = scalar.outstandingHandleCount
            liveAgentHandles = scalar.liveAgentHandleCount
            unreapedAgentHandles = scalar.unreapedAgentHandleCount
            retainedAgentHandles = scalar.retainedAgentHandleCount
        }
        var scalar: BoundedWorkScalarContinuation { scalarState }
        var seenEventCount: Int { seenCount }
        func hasSeenEvent(_ id: String) -> Bool { seen[id] != nil }
        func eventSequence(for id: String) -> Int? { seen[id]?.sequence }
        func hasObservedRun(_ id: String) -> Bool { runs[id] != nil }
        func action(for id: String) -> WorkActionSnapshot? { actions[id]?.action }
        func isActionActive(_ id: String) -> Bool { actions[id]?.isActive == true }
        func handle(for id: String) -> WorkHandleSnapshot? { handles[id]?.handle }
        func agentHandle(for id: String) -> WorkAgentHandleSnapshot? { agentHandles[id]?.handle }
        func sessionAttachment(for id: String) -> WorkSessionAttachmentSnapshot? { attachments[id]?.attachment }
        func activeSessionAttachmentCount(for session: SessionRef) -> Int { attachmentCounts[session.sessionID]?.count ?? 0 }
        func command(for id: String) -> WorkCommandSnapshot? { commands[id]?.command }
        var activeActionCount: Int { activeActions }; var outstandingHandleCount: Int { outstandingHandles }
        var liveAgentHandleCount: Int { liveAgentHandles }
        var unreapedAgentHandleCount: Int { unreapedAgentHandles }
        var retainedAgentHandleCount: Int { retainedAgentHandles }
        mutating func stageScalar(_ value: BoundedWorkScalarContinuation) { scalarState = value }
        mutating func stageSeenEvent(_ event: TimelineEvent) {
            let (nextSeenCount, overflow) = seenCount.addingReportingOverflow(1)
            guard !overflow, nextSeenCount < Int.max, event.sequence < Int.max else {
                invalidMutation = true
                return
            }
            seen[event.eventID] = SeenRecord(
                kind: "seen", scope: scope, eventID: event.eventID, sequence: event.sequence)
            seenCount = nextSeenCount
            var value = scalarState
            value.lastEventID = event.eventID
            value.lastSequence = max(value.lastSequence, event.sequence)
            if let host = event.hostSequence { value.lastHostSequence = host }
            scalarState = value
        }
        mutating func stageObservedRun(_ run: RunRef) { runs[run.runID] = RunRecord(kind: "run", scope: scope, run: run) }
        mutating func stageSessionAttachment(_ value: WorkSessionAttachmentSnapshot) {
            let old = attachments[value.attachment.attachmentID]?.attachment
            attachments[value.attachment.attachmentID] = AttachmentRecord(
                kind: "attachment", scope: scope, work: work, attachment: value)
            rebuildCount(for: old?.session ?? value.session)
            if let old, old.session != value.session { rebuildCount(for: value.session) }
        }
        mutating func stageSessionAttachmentDetached(_ id: String) { guard let old = attachments[id]?.attachment else { return }; var value = old; value.isAttached = false; stageSessionAttachment(value) }
        mutating func stageSessionAttachmentCapabilities(_ id: String, capabilities: Set<String>) { guard let old = attachments[id]?.attachment else { return }; var value = old; value.capabilities = capabilities; attachments[id] = AttachmentRecord(kind: "attachment", scope: scope, work: work, attachment: value) }
        mutating func stageAction(_ value: WorkActionSnapshot, active: Bool?) {
            let id = value.action.actionID
            let was = actions[id]?.isActive ?? false
            let next = active ?? was
            if next && !was {
                let (count, overflow) = activeActions.addingReportingOverflow(1)
                guard !overflow, count < Int.max else { invalidMutation = true; return }
                activeActions = count
            }
            if !next && was {
                guard activeActions > 0 else { invalidMutation = true; return }
                activeActions -= 1
            }
            actions[id] = ActionRecord(
                kind: "action", scope: scope, action: value, isActive: next)
        }
        mutating func stageHandle(_ value: WorkHandleSnapshot) {
            let id = value.handle.handleID
            let old = handles[id]?.handle
            let terminal = ["succeeded", "failed", "canceled", "completed"].contains(value.state)
            let oldTerminal = old.map {
                ["succeeded", "failed", "canceled", "completed"].contains($0.state)
            } ?? true
            if !oldTerminal && terminal {
                guard outstandingHandles > 0 else { invalidMutation = true; return }
                outstandingHandles -= 1
            }
            if oldTerminal && !terminal {
                let (count, overflow) = outstandingHandles.addingReportingOverflow(1)
                guard !overflow, count < Int.max else { invalidMutation = true; return }
                outstandingHandles = count
            }
            handles[id] = HandleRecord(kind: "handle", scope: scope, handle: value)
        }
        mutating func stageAgentHandle(_ value: WorkAgentHandleSnapshot) {
            let id = value.handle.handleID
            let old = agentHandles[id]?.handle
            if old == nil {
                guard retainedAgentHandles < WorkAgentHandleSnapshot.maximumRetainedPerWork else {
                    invalidMutation = true; return
                }
                retainedAgentHandles += 1
            }
            if old?.blocksWorkCompletion != true && value.blocksWorkCompletion {
                liveAgentHandles += 1
            }
            if old?.blocksWorkCompletion == true && !value.blocksWorkCompletion {
                guard liveAgentHandles > 0 else { invalidMutation = true; return }
                liveAgentHandles -= 1
            }
            if old != nil && old?.state != .reaped && value.state == .reaped {
                guard unreapedAgentHandles > 0 else { invalidMutation = true; return }
                unreapedAgentHandles -= 1
            } else if old == nil && value.state != .reaped {
                unreapedAgentHandles += 1
            }
            agentHandles[id] = AgentHandleRecord(
                kind: "agent-handle", scope: scope, handle: value)
        }
        mutating func stageCommand(_ value: WorkCommandSnapshot) { commands[value.command.commandID] = CommandRecord(kind: "command", scope: scope, command: value) }
        mutating func stageRecovery(_ coverage: RecoveryCoverage, recorded: RecordedRecoveryCoverage) {
            let caveats = coverage.caveats
            recoveries[recorded.sourceEvent.eventID] = RecoveryRecord(
                kind: "recovery", scope: scope, operation: coverage.operation,
                planes: coverage.planes, evidence: coverage.evidence,
                evidenceCursor: coverage.evidenceCursor, caveatCount: caveats.count,
                caveatDigest: PersistentWorkExactState.digestTextArray(caveats),
                sourceEvent: recorded.sourceEvent, session: recorded.session,
                work: recorded.work, workJournal: recorded.workJournal,
                workHost: recorded.workHost, sessionAttachment: recorded.sessionAttachment,
                run: recorded.run)
        }
        mutating func stageChildState(_ state: String, for childID: String) {
            let classification: String
            switch state {
            case "running": classification = "running"
            case "done": classification = "done"
            case "failed": classification = "failed"
            case "canceled": classification = "canceled"
            default: classification = "unknown"
            }
            children[childID] = ChildRecord(
                kind: "child", scope: scope, childID: childID, state: classification,
                stateDigest: PersistentWorkExactState.digestJSON(.string(state)))
        }
        mutating func stageUnknown(_ value: UnknownTimelineEvent) { unknownRecords.append(UnknownRecord(kind: "unknown", scope: scope, eventID: value.event.eventID, journal: value.event.journal, sequence: value.event.sequence, type: value.event.type, offset: value.journalOffset, domains: value.affectedDomains, payloadDigest: PersistentWorkExactState.digestJSON(value.rawPayload))); var scalar = scalarState; scalar.unknownDomains.formUnion(value.affectedDomains); scalarState = scalar }
        mutating func stageQuarantineOnly(_ event: TimelineEvent) { quarantineRecords.append(QuarantineRecord(kind: "quarantine", scope: scope, eventID: event.eventID, journal: event.journal, sequence: event.sequence, type: event.type, classification: "structural", structural: true, payloadDigest: PersistentWorkExactState.digestJSON(event.payload))) }
        mutating func stageQuarantine(_ event: TimelineEvent, reason: String, structural: Bool) { var scalar = scalarState; if structural { scalar.causalOrderValid = false; scalar.structuralIntegrityValid = false } else { scalar.semanticProjectionValid = false }; scalarState = scalar; quarantineRecords.append(QuarantineRecord(kind: "quarantine", scope: scope, eventID: event.eventID, journal: event.journal, sequence: event.sequence, type: event.type, classification: structural ? "structural" : "semantic", structural: structural, payloadDigest: PersistentWorkExactState.digestJSON(event.payload))) }
        mutating func rebuildCount(for session: SessionRef) {
            let activeIDs = attachments.values
                .filter { $0.attachment.session == session && $0.attachment.isAttached }
                .map { $0.attachment.attachment.attachmentID }
                .sorted()
            guard activeIDs.count <= WorkServiceBounds.maxSessionAttachmentsPerWork,
                  activeIDs.count <= seenCount else {
                invalidMutation = true
                return
            }
            attachmentCounts[session.sessionID] = CountRecord(
                kind: "attachment-count", scope: scope, session: session,
                count: activeIDs.count, activeAttachmentIDs: activeIDs)
        }
        var scalarRecord: ScalarRecord { ScalarRecord(scalarState, seenEventCount: seenCount, activeActionCount: activeActions, outstandingHandleCount: outstandingHandles, liveAgentHandleCount: liveAgentHandles, unreapedAgentHandleCount: unreapedAgentHandles, retainedAgentHandleCount: retainedAgentHandles, lastUnknownEventID: unknownRecords.last?.eventID, lastQuarantineEventID: quarantineRecords.last?.eventID) }
        var snapshot: WorkSnapshot {
            var value = WorkSnapshot()
            value.journal = scalar.journal; value.work = scalar.work; value.workHost = scalar.workHost
            value.lifecycle = scalar.lifecycle; value.execution = scalar.execution; value.activeRun = scalar.activeRun
            value.activeRunSession = scalar.activeRunSession
            value.activeRunSessionAttachment = scalar.activeRunSessionAttachment
            value.modelID = scalar.modelID; value.activeTurn = scalar.activeTurn
            value.lastHostSequence = scalar.lastHostSequence; value.unknownDomains = scalar.unknownDomains
            value.lastEventID = scalar.lastEventID; value.lastSequence = scalar.lastSequence
            value.causalOrderValid = scalar.causalOrderValid
            value.structuralIntegrityValid = scalar.structuralIntegrityValid
            value.semanticProjectionValid = scalar.semanticProjectionValid
            value.seenEventIDs = Set(seen.keys)
            value.eventSequences = seen.reduce(into: [:]) { $0[$1.key] = $1.value.sequence }
            value.observedRunIDs = Set(runs.keys)
            value.actions = actions.reduce(into: [:]) { $0[$1.key] = $1.value.action }
            value.handles = handles.reduce(into: [:]) { $0[$1.key] = $1.value.handle }
            value.agentHandles = agentHandles.reduce(into: [:]) { $0[$1.key] = $1.value.handle }
            value.sessionAttachments = attachments.reduce(into: [:]) { $0[$1.key] = $1.value.attachment }
            value.commands = commands.reduce(into: [:]) { $0[$1.key] = $1.value.command }
            value.childStates = children.reduce(into: [:]) { $0[$1.key] = $1.value.state }
            value.activeActionIDs = Set(actions.values.filter(\.isActive).map { $0.action.action.actionID })
            value.recovery = recoveries.values.sorted { $0.sourceEvent.eventID < $1.sourceEvent.eventID }
                .map(Self.recoveryCoverage)
            value.recordedRecovery = recoveries.values.sorted { $0.sourceEvent.eventID < $1.sourceEvent.eventID }
                .map(Self.recordedRecovery)
            value.unknownEvents = unknownRecords.map { UnknownTimelineEvent(
                event: TimelineEvent(eventID: $0.eventID, journal: $0.journal, sequence: $0.sequence,
                    actor: TimelineActor(actorID: "persisted", kind: "metadata"),
                    hostRecordedAt: Date(timeIntervalSince1970: 0), type: $0.type,
                    declaredDomains: $0.domains,
                    payload: .object(["payload_digest": .string($0.payloadDigest)])),
                journalOffset: $0.offset,
                rawPayload: .object(["payload_digest": .string($0.payloadDigest)]),
                affectedDomains: $0.domains) }
            value.corruptionReasons = quarantineRecords.map { $0.classification }
            value.quarantinedEvents = quarantineRecords.map { TimelineEvent(
                eventID: $0.eventID, journal: $0.journal, sequence: $0.sequence,
                actor: TimelineActor(actorID: "persisted", kind: "metadata"),
                hostRecordedAt: Date(timeIntervalSince1970: 0), type: $0.type,
                payload: .object(["classification": .string($0.classification),
                                  "payload_digest": .string($0.payloadDigest)])) }
            value.attachedSessionIDs = Set(attachmentCounts.values.filter { $0.count > 0 }
                .map { $0.session.sessionID })
            return value
        }
        private static func recoveryCoverage(_ record: RecoveryRecord) -> RecoveryCoverage {
            RecoveryCoverage(operation: record.operation, planes: record.planes,
                              evidence: record.evidence, evidenceCursor: record.evidenceCursor)
        }
        private static func recordedRecovery(_ record: RecoveryRecord) -> RecordedRecoveryCoverage {
            RecordedRecoveryCoverage(coverage: recoveryCoverage(record), sourceEvent: record.sourceEvent,
                session: record.session, work: record.work, workJournal: record.workJournal,
                workHost: record.workHost, sessionAttachment: record.sessionAttachment, run: record.run)
        }
        func encodedValue(for key: String) throws -> Data? {
            if key == PersistentWorkExactState.scalarKey { return try PersistentWorkExactState.encode(scalarRecord) }
            let parts = key.split(separator: "/")
            guard parts.count == 3 else { return nil }
            let kind = String(parts[1])
            func id<T>(_ values: [String: T]) -> String? {
                values.keys.first { PersistentWorkExactState.slotKey(kind: kind, identity: $0) == key }
            }
            if kind == "seen", let key = id(seen), let record = seen[key] { return try PersistentWorkExactState.encode(record) }
            if kind == "run", let key = id(runs), let record = runs[key] { return try PersistentWorkExactState.encode(record) }
            if kind == "action", let key = id(actions), let record = actions[key] { return try PersistentWorkExactState.encode(record) }
            if kind == "handle", let key = id(handles), let record = handles[key] { return try PersistentWorkExactState.encode(record) }
            if kind == "agent-handle", let key = id(agentHandles), let record = agentHandles[key] { return try PersistentWorkExactState.encode(record) }
            if kind == "attachment", let key = id(attachments), let record = attachments[key] { return try PersistentWorkExactState.encode(record) }
            if kind == "attachment-count", let key = id(attachmentCounts), let record = attachmentCounts[key] { return try PersistentWorkExactState.encode(record) }
            if kind == "command", let key = id(commands), let record = commands[key] { return try PersistentWorkExactState.encode(record) }
            if kind == "child", let key = id(children), let record = children[key] { return try PersistentWorkExactState.encode(record) }
            if kind == "recovery", let key = id(recoveries), let record = recoveries[key] { return try PersistentWorkExactState.encode(record) }
            if kind == "unknown", let record = unknownRecords.first(where: { PersistentWorkExactState.slotKey(kind: kind, identity: $0.eventID) == key }) { return try PersistentWorkExactState.encode(record) }
            if kind == "quarantine", let record = quarantineRecords.first(where: { PersistentWorkExactState.slotKey(kind: kind, identity: $0.eventID) == key }) { return try PersistentWorkExactState.encode(record) }
            return nil
        }
    }
}
