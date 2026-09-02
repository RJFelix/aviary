import Foundation
import CryptoKit

/// A bounded, read-only index of the native Timeline v2 journals in one AgentHome.
///
/// The catalog is intentionally a projection, not a second persistence layer. It discovers
/// locators, decodes the journal's own declared identity, and then lets the canonical reducers
/// decide which facts are usable. In particular, directory names never establish Work authority
/// and a Work tip is never substituted for a missing Session attachment cursor.
/// AgentHome roots must be canonical paths: a symlinked root can be discovered but cannot satisfy
/// exact locator round-trip, so its rows remain visibly unavailable rather than being trusted.
public enum LocalTimelineCatalog {
    public struct Limits: Codable, Hashable, Sendable {
        public let maxSessionJournals: Int
        public let maxWorkJournals: Int
        public let maxJournalBytes: Int
        public let maxDiagnostics: Int
        public let maxCorruptionReasonsPerRow: Int

        public init(maxSessionJournals: Int = 512, maxWorkJournals: Int = 2_048,
                    maxJournalBytes: Int = 64 * 1024 * 1024, maxDiagnostics: Int = 128,
                    maxCorruptionReasonsPerRow: Int = 16) {
            self.maxSessionJournals = max(1, maxSessionJournals)
            self.maxWorkJournals = max(1, maxWorkJournals)
            self.maxJournalBytes = max(1, maxJournalBytes)
            self.maxDiagnostics = max(1, maxDiagnostics)
            self.maxCorruptionReasonsPerRow = max(1, maxCorruptionReasonsPerRow)
        }
    }

    public struct Diagnostic: Codable, Hashable, Sendable, Identifiable {
        public static let maxMessageCharacters = 1_024
        public let id: String
        public let kind: String
        public let message: String

        public init(kind: String, message: String) {
            self.kind = kind
            self.message = String(message.prefix(Self.maxMessageCharacters))
            let digest = SHA256.hash(data: Data("\(kind)\0\(self.message)".utf8))
            self.id = "diagnostic-" + digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    public struct ActionFact: Codable, Hashable, Sendable, Identifiable {
        public let actionID: String
        public let state: ActionExecutionState
        public let failureKind: ActionFailureKind?
        public let retrySafety: ActionRetrySafety?

        public var id: String { actionID }

        fileprivate init(_ value: WorkActionSnapshot) {
            actionID = value.action.actionID
            state = value.state
            failureKind = value.failureKind
            retrySafety = value.retrySafety
        }
    }

    public struct HandleFact: Codable, Hashable, Sendable, Identifiable {
        public let handleID: String
        public let state: String

        public var id: String { handleID }

        fileprivate init(_ value: WorkHandleSnapshot) {
            handleID = value.handle.handleID
            state = value.state
        }
    }

    public struct CommandFact: Codable, Hashable, Sendable, Identifiable {
        public let commandID: String
        public let state: CommandDeliveryState

        public var id: String { commandID }

        fileprivate init(_ value: WorkCommandSnapshot) {
            commandID = value.command.commandID
            state = value.state
        }
    }

    /// One discovered Work locator. A row remains present when its file is corrupt or cannot
    /// establish identity, but operational facts are nil in that case. Unknown-event references
    /// and affected domains remain as explicit evidence even when projection is unavailable.
    public struct WorkRow: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        /// Stable discovered locator, retained only to disambiguate duplicate qualified Work
        /// identities in presentation. It is not an authority or a source of Work facts.
        public let locatorID: String?
        public let work: WorkRef?
        public let journal: JournalRef?
        public let workHost: WorkHostRef?
        /// Last committed prefix retained as evidence even when a tail makes the journal
        /// non-projectable. `cursor` below is the stricter canonical tip.
        public let committedPrefixCursor: JournalCursor?
        public let cursor: JournalCursor?
        public let isAvailable: Bool
        public let lifecycle: WorkLifecycle?
        public let execution: WorkExecution?
        public let modelID: String?
        public let activeRun: RunRef?
        public let activeTurn: TurnRef?
        public let actions: [ActionFact]
        public let handles: [HandleFact]
        public let commands: [CommandFact]
        /// Child lifecycle facts from the exact Work journal, when one was supplied. This is
        /// deliberately separate from the legacy AgentTree; an unavailable or unaligned read
        /// yields an unavailable projection and never lends child state to the UI.
        public let canonicalFlock: CanonicalFlockProjection?
        public let unknownEventRefs: [EventRef]
        public let unknownDomains: [TimelineDomain]
        public let tailBytes: Int
        public let corruptionReasons: [String]

        fileprivate init(locatorID: String, work declaredWork: WorkRef?, journal: JournalRef?,
                         snapshot: WorkSnapshot?,
                         read: TimelineJournalReadResult?, available: Bool, reasons: [String],
                         limit: Int, presentationID: String? = nil) {
            id = presentationID ?? declaredWork.map { LocalTimelineCatalog.qualifiedWork($0) } ?? locatorID
            self.locatorID = locatorID
            work = declaredWork
            self.journal = journal
            workHost = declaredWork.map { WorkHostRef($0.workHostID) }
            if let journal, let last = read?.records.last {
                committedPrefixCursor = JournalCursor(
                    journal: journal, eventID: last.event.eventID,
                    sequence: last.event.sequence)
            } else {
                committedPrefixCursor = nil
            }
            let exact = available && snapshot != nil
            cursor = exact ? committedPrefixCursor : nil
            isAvailable = exact
            unknownEventRefs = snapshot?.unknownEvents.map {
                EventRef(journal: $0.event.journal, eventID: $0.event.eventID)
            }.sorted { $0.eventID < $1.eventID } ?? []
            unknownDomains = snapshot.map {
                Array($0.unknownDomains).sorted { $0.rawValue < $1.rawValue }
            } ?? []
            if let snapshot, let read, !read.records.isEmpty {
                canonicalFlock = AgentTreeReader.canonicalProjection(work: snapshot, read: read)
            } else {
                canonicalFlock = nil
            }
            if exact, let snapshot {
                let workFactsKnown = !snapshot.unknownDomains.contains(.work)
                let actionFactsKnown = workFactsKnown
                    && !snapshot.unknownDomains.contains(.externalEffects)
                let runtimeFactsKnown = workFactsKnown
                    && !snapshot.unknownDomains.contains(.runtime)
                lifecycle = workFactsKnown ? snapshot.lifecycle : nil
                execution = workFactsKnown ? snapshot.execution : nil
                modelID = workFactsKnown ? snapshot.modelID : nil
                activeRun = workFactsKnown ? snapshot.activeRun : nil
                activeTurn = workFactsKnown ? snapshot.activeTurn : nil
                actions = actionFactsKnown
                    ? snapshot.actions.values.sorted {
                        $0.action.actionID < $1.action.actionID
                    }.map(ActionFact.init)
                    : []
                handles = runtimeFactsKnown
                    ? snapshot.handles.values.sorted {
                        $0.handle.handleID < $1.handle.handleID
                    }.map(HandleFact.init)
                    : []
                commands = workFactsKnown
                    ? snapshot.commands.values.sorted {
                        $0.command.commandID < $1.command.commandID
                    }.map(CommandFact.init)
                    : []
            } else {
                lifecycle = nil
                execution = nil
                modelID = nil
                activeRun = nil
                activeTurn = nil
                actions = []
                handles = []
                commands = []
            }
            tailBytes = (read?.truncatedTail?.rawBytes.count ?? 0)
                + (read?.quarantinedSuffix?.rawBytes.count ?? 0)
            corruptionReasons = reasons.prefix(limit).map { String($0.prefix(512)) }
        }
    }

    /// One Session locator and its canonical adapter result. Invalid Session files stay visible
    /// as rows with a nil summary, allowing callers to distinguish absence from corruption.
    public struct SessionRow: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let journal: JournalRef?
        public let summary: CanonicalSessionCatalogSummary?
        public let isAvailable: Bool
        public let unknownEventRefs: [EventRef]
        public let unknownDomains: [TimelineDomain]
        public let tailBytes: Int
        public let corruptionReasons: [String]

        fileprivate init(locatorID: String, journal: JournalRef?,
                         summary: CanonicalSessionCatalogSummary?, read: TimelineJournalReadResult?,
                         unknownEventRefs: [EventRef] = [],
                         unknownDomains: [TimelineDomain] = [],
                         reasons: [String], limit: Int) {
            id = locatorID
            self.journal = journal
            self.summary = summary
            isAvailable = summary != nil && reasons.isEmpty
            self.unknownEventRefs = unknownEventRefs
            self.unknownDomains = unknownDomains
            tailBytes = (read?.truncatedTail?.rawBytes.count ?? 0)
                + (read?.quarantinedSuffix?.rawBytes.count ?? 0)
            corruptionReasons = reasons.prefix(limit).map { String($0.prefix(512)) }
        }
    }

    public struct Snapshot: Codable, Hashable, Sendable {
        public let sessions: [SessionRow]
        public let sessionSummaries: [CanonicalSessionCatalogSummary]
        public let works: [WorkRow]
        public let diagnostics: [Diagnostic]

        fileprivate init(sessions: [SessionRow], works: [WorkRow], diagnostics: [Diagnostic]) {
            self.sessions = sessions
            sessionSummaries = sessions.compactMap(\SessionRow.summary)
                .sorted { $0.id < $1.id }
            self.works = works
            self.diagnostics = diagnostics
        }
    }

    /// Scan the canonical local Timeline v2 tree. Results are deterministic and bounded by
    /// `limits`; filesystem timestamps are never used for ordering or identity.
    public static func scan(home: AgentHome = .default,
                            limits: Limits = Limits()) -> Snapshot {
        var diagnostics = DiagnosticSink(limit: limits.maxDiagnostics)
        let candidates = discover(home: home, limits: limits, diagnostics: &diagnostics)
        let sessionCandidates = candidates.filter { $0.kind == .session }
        let workCandidates = candidates.filter { $0.kind == .work }

        var workRecords: [WorkRecord] = []
        for candidate in workCandidates {
            workRecords.append(readWork(candidate, home: home, limits: limits,
                                        diagnostics: &diagnostics))
        }
        let workCounts = Dictionary(grouping: workRecords.compactMap { record in
            record.row.work.map { ($0, record) }
        }, by: { $0.0 }).mapValues(\.count)
        let conflictedWorks = Set(workCounts.compactMap { $0.value > 1 ? $0.key : nil })
        for work in conflictedWorks.sorted(by: { qualifiedWork($0) < qualifiedWork($1) }) {
            diagnostics.append(
                kind: "duplicate_work",
                message: "duplicate qualified Work \(qualifiedWork(work)); no journal can project facts")
        }
        workRecords = workRecords.map { record in
            guard let work = record.row.work, conflictedWorks.contains(work) else { return record }
            let reasons = record.row.corruptionReasons
                + ["duplicate qualified Work identity is non-projectable"]
            return WorkRecord(
                locatorID: record.locatorID,
                row: WorkRow(
                    locatorID: record.locatorID, work: work, journal: record.row.journal,
                    snapshot: record.snapshot, read: record.read, available: false,
                    reasons: reasons, limit: limits.maxCorruptionReasonsPerRow,
                    presentationID: "\(qualifiedWork(work))#\(record.locatorID)"),
                snapshot: record.snapshot, read: record.read)
        }
        workRecords.sort {
            if $0.row.id != $1.row.id { return $0.row.id < $1.row.id }
            return $0.locatorID < $1.locatorID
        }

        var workReads: [JournalRef: TimelineJournalReadResult] = [:]
        var workSnapshots: [WorkSnapshot] = []
        for record in workRecords {
            guard let work = record.row.work, let journal = record.row.journal else { continue }
            guard !conflictedWorks.contains(work) else { continue }
            if let snapshot = record.snapshot {
                workSnapshots.append(snapshot)
                if let read = record.read { workReads[journal] = read }
            }
        }

        var sessionRecords: [SessionRecord] = []
        for candidate in sessionCandidates {
            sessionRecords.append(readSession(candidate, home: home, limits: limits,
                                              works: workSnapshots, workReads: workReads,
                                              diagnostics: &diagnostics))
        }
        let sessionCounts = Dictionary(grouping: sessionRecords.compactMap { record in
            record.row.journal.map { ($0.stableKey, record) }
        }, by: { $0.0 }).mapValues(\.count)
        let conflictedSessions = Set(sessionCounts.compactMap { $0.value > 1 ? $0.key : nil })
        for id in conflictedSessions.sorted() {
            diagnostics.append(
                kind: "duplicate_session",
                message: "duplicate qualified Session \(id); no journal can project facts")
        }
        sessionRecords = sessionRecords.map { record in
            guard let journal = record.row.journal,
                  conflictedSessions.contains(journal.stableKey)
            else { return record }
            return SessionRecord(
                locatorID: record.locatorID,
                row: SessionRow(
                    locatorID: record.locatorID, journal: journal, summary: nil,
                    read: record.read,
                    unknownEventRefs: record.row.unknownEventRefs,
                    unknownDomains: record.row.unknownDomains,
                    reasons: record.row.corruptionReasons
                        + ["duplicate qualified Session identity is non-projectable"],
                    limit: limits.maxCorruptionReasonsPerRow),
                read: record.read)
        }
        sessionRecords.sort {
            if $0.row.id != $1.row.id { return $0.row.id < $1.row.id }
            return $0.locatorID < $1.locatorID
        }
        let sessionRows = sessionRecords.map(\.row)

        return Snapshot(sessions: sessionRows, works: workRecords.map(\WorkRecord.row),
                        diagnostics: diagnostics.values)
    }

    /// Alias for callers that use read terminology for a read-only catalog operation.
    public static func read(home: AgentHome = .default, limits: Limits = Limits()) -> Snapshot {
        scan(home: home, limits: limits)
    }

    /// Re-read native Session/Work truth immediately before a legacy Continue or Trash action.
    ///
    /// Cached catalog state is suitable for rendering, not admission: another GUI or Work Host
    /// may have appended since the last refresh. The canonical native locator existing without
    /// exactly one projectable declared Session is itself uncertainty, including an undecodable
    /// first event whose directory name is not allowed to manufacture authority.
    public static func blocksLegacyAction(
        home: AgentHome = .default,
        sessionID: String,
        limits: Limits = Limits()
    ) -> Bool {
        let url = home.timelineV2SessionJournalURL(sessionID: sessionID)
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return true }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               [CocoaError.fileNoSuchFile.rawValue,
                CocoaError.fileReadNoSuchFile.rawValue].contains(nsError.code)
            {
                return false
            }
            // Permission, malformed-parent, and other I/O failures are uncertainty, not absence.
            return true
        }
        let snapshot = scan(home: home, limits: limits)
        let matches = snapshot.sessions.filter { row in
            guard let journal = row.journal, case .session(let session) = journal.owner else {
                return false
            }
            return session.sessionID == sessionID
        }
        guard matches.count == 1, let row = matches.first,
              row.isAvailable, let summary = row.summary
        else { return true }
        return summary.hasOngoingOrUncertainAttachedWork
    }

    private enum Kind { case session, work }
    private struct Candidate {
        let kind: Kind
        let url: URL
        let locatorID: String
    }
    private struct WorkRecord {
        let locatorID: String
        let row: WorkRow
        let snapshot: WorkSnapshot?
        let read: TimelineJournalReadResult?
    }
    private struct SessionRecord {
        let locatorID: String
        let row: SessionRow
        let read: TimelineJournalReadResult?
    }
    private struct DiagnosticSink {
        let limit: Int
        var values: [Diagnostic] = []

        init(limit: Int) { self.limit = limit }

        mutating func append(kind: String, message: String) {
            guard values.count < limit else { return }
            let diagnostic = Diagnostic(kind: kind, message: message)
            guard !values.contains(where: { $0.id == diagnostic.id }) else { return }
            values.append(diagnostic)
        }
    }

    private static func discover(home: AgentHome, limits: Limits,
                                 diagnostics: inout DiagnosticSink) -> [Candidate] {
        var result: [Candidate] = []
        let fm = FileManager.default
        let root = home.timelineV2Root
        guard let rootResolved = safeResolved(root) else {
            diagnostics.append(kind: "unsafe_root", message: "Timeline root is not safely contained")
            return []
        }

        func add(_ kind: Kind, _ url: URL, _ ordinal: inout Int, _ maximum: Int) {
            guard ordinal < maximum else {
                diagnostics.append(kind: "catalog_bound", message: "journal discovery limit reached")
                return
            }
            guard isSafeFile(url, under: rootResolved) else {
                diagnostics.append(kind: "unsafe_locator", message: "journal locator rejected")
                return
            }
            let relative = url.standardizedFileURL.path.replacingOccurrences(
                of: root.standardizedFileURL.path + "/", with: "")
            result.append(Candidate(kind: kind, url: url,
                                    locatorID: "locator-" + digest(relative)))
            ordinal += 1
        }

        var sessions = 0
        for directory in children(
            of: home.timelineV2SessionsDir, label: "Session journal directory",
            maximum: limits.maxSessionJournals, diagnostics: &diagnostics)
        {
            let journal = directory.appending(path: "journal.jsonl", directoryHint: .notDirectory)
            if fm.fileExists(atPath: journal.path) {
                add(.session, journal, &sessions, limits.maxSessionJournals)
            }
        }
        var works = 0
        for host in children(
            of: home.timelineV2WorkHostsDir, label: "Work Host directory",
            maximum: limits.maxWorkJournals, diagnostics: &diagnostics)
        {
            guard works < limits.maxWorkJournals else { break }
            let worksDir = host.appending(path: "works", directoryHint: .isDirectory)
            for work in children(
                of: worksDir, label: "Work journal directory",
                maximum: limits.maxWorkJournals - works, diagnostics: &diagnostics)
            {
                let journal = work.appending(path: "journal.jsonl", directoryHint: .notDirectory)
                if fm.fileExists(atPath: journal.path) {
                    add(.work, journal, &works, limits.maxWorkJournals)
                }
            }
        }
        return result.sorted { $0.locatorID < $1.locatorID }
    }

    private static func readWork(_ candidate: Candidate, home: AgentHome, limits: Limits,
                                 diagnostics: inout DiagnosticSink) -> WorkRecord {
        let failureID = candidate.locatorID
        guard let data = boundedData(candidate.url, maxBytes: limits.maxJournalBytes) else {
            let reason = "journal is unreadable or exceeds the catalog byte bound"
            diagnostics.append(kind: "unavailable_work", message: "\(failureID): \(reason)")
            return WorkRecord(
                locatorID: failureID,
                row: WorkRow(locatorID: failureID, work: nil, journal: nil, snapshot: nil,
                             read: nil, available: false, reasons: [reason],
                             limit: limits.maxCorruptionReasonsPerRow),
                snapshot: nil, read: nil)
        }
        guard let declared = firstJournalRef(in: data) else {
            let reason = "first complete event does not declare a decodable JournalRef"
            diagnostics.append(kind: "unavailable_work", message: "\(failureID): \(reason)")
            return WorkRecord(
                locatorID: failureID,
                row: WorkRow(locatorID: failureID, work: nil, journal: nil, snapshot: nil,
                             read: nil, available: false, reasons: [reason],
                             limit: limits.maxCorruptionReasonsPerRow),
                snapshot: nil, read: nil)
        }
        guard case .work(let work) = declared.owner,
              declared.authority.authorityID == work.workHostID,
              safeEqual(candidate.url, home.timelineV2WorkJournalURL(work))
        else {
            let reason = "declared Work owner, authority, or locator does not round-trip"
            diagnostics.append(kind: "unavailable_work", message: "\(failureID): \(reason)")
            return WorkRecord(
                locatorID: failureID,
                row: WorkRow(locatorID: failureID, work: nil, journal: nil, snapshot: nil,
                             read: nil, available: false, reasons: [reason],
                             limit: limits.maxCorruptionReasonsPerRow),
                snapshot: nil, read: nil)
        }
        let read = TimelineJournalReader.read(data, journal: declared,
            actor: TimelineActor(actorID: "local-catalog", kind: "reader"),
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        let snapshot = WorkReducer.reduce(read.records.map(\TimelineJournalRecord.event))
        var reasons = integrityReasons(read: read, snapshot: snapshot)
        if snapshot.work != work || snapshot.journal != declared
            || snapshot.workHost != WorkHostRef(work.workHostID)
        {
            reasons.append("Work reducer identity does not match the declared journal")
        }
        reasons = unique(reasons)
        let available = reasons.isEmpty
        let row = WorkRow(locatorID: candidate.locatorID, work: work, journal: declared,
                          snapshot: snapshot,
                          read: read, available: available, reasons: reasons,
                          limit: limits.maxCorruptionReasonsPerRow)
        if !available { diagnostics.append(kind: "unavailable_work", message: "\(row.id): \(reasons.joined(separator: "; "))") }
        return WorkRecord(locatorID: candidate.locatorID, row: row,
                          snapshot: snapshot, read: read)
    }

    private static func readSession(_ candidate: Candidate, home: AgentHome, limits: Limits,
                                    works: [WorkSnapshot], workReads: [JournalRef: TimelineJournalReadResult],
                                    diagnostics: inout DiagnosticSink) -> SessionRecord {
        let failureID = candidate.locatorID
        guard let data = boundedData(candidate.url, maxBytes: limits.maxJournalBytes),
              let declared = firstJournalRef(in: data),
              case .session(let session) = declared.owner,
              safeEqual(candidate.url, home.timelineV2SessionJournalURL(sessionID: session.sessionID))
        else {
            let reason = "declared Session owner or locator does not round-trip"
            diagnostics.append(kind: "unavailable_session", message: "\(failureID): \(reason)")
            return SessionRecord(
                locatorID: failureID,
                row: SessionRow(locatorID: failureID, journal: nil, summary: nil,
                                read: nil, reasons: [reason],
                                limit: limits.maxCorruptionReasonsPerRow),
                read: nil)
        }
        let read = TimelineJournalReader.read(data, journal: declared,
            actor: TimelineActor(actorID: "local-catalog", kind: "reader"),
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        let snapshot = SessionReducer.reduce(read.records.map(\TimelineJournalRecord.event))
        var cursors: [String: JournalCursor] = [:]
        for attachment in snapshot.attachments.values {
            if let cursor = attachment.cursor { cursors[attachment.attachment.attachmentID] = cursor }
        }
        let summary = SessionCatalogCanonicalAdapter.summarize(
            session: snapshot, works: works, cursors: cursors, sessionRead: read,
            workReads: workReads)
        let reasons = integrityReasons(read: read, snapshot: snapshot)
        var allReasons = reasons
        if summary == nil { allReasons.append("Session reducer did not establish canonical identity") }
        if !allReasons.isEmpty {
            diagnostics.append(kind: "unavailable_session", message: "\(failureID): \(allReasons.joined(separator: "; "))")
        }
        let availableSummary = allReasons.isEmpty ? summary : nil
        let unknownEventRefs = snapshot.unknownEvents.map {
            EventRef(journal: $0.event.journal, eventID: $0.event.eventID)
        }.sorted {
            if $0.journal.stableKey != $1.journal.stableKey {
                return $0.journal.stableKey < $1.journal.stableKey
            }
            return $0.eventID < $1.eventID
        }
        let unknownDomains = Array(snapshot.unknownDomains)
            .sorted { $0.rawValue < $1.rawValue }
        return SessionRecord(
            locatorID: candidate.locatorID,
            row: SessionRow(locatorID: declared.stableKey, journal: declared,
                            summary: availableSummary, read: read,
                            unknownEventRefs: unknownEventRefs,
                            unknownDomains: unknownDomains,
                            reasons: allReasons,
                            limit: limits.maxCorruptionReasonsPerRow),
            read: read)
    }

    private static func firstJournalRef(in data: Data) -> JournalRef? {
        let bytes = Array(data)
        let end = bytes.firstIndex(of: 0x0A) ?? bytes.endIndex
        guard end > 0 else { return nil }
        // A syntactically complete first JSON object without LF is still uncommitted. Decode its
        // declared identity only so the row can retain exact locator/tail evidence; the journal
        // reader below commits no records and the row remains unavailable.
        guard let value = JSONValue.parse(Data(bytes[0..<end])) else { return nil }
        guard let object = value.objectValue, object["journal"] != nil else { return nil }
        guard let event = try? JSONDecoder().decode(TimelineEvent.self,
                                                      from: Data(bytes[0..<end])) else { return nil }
        return event.journal
    }

    private static func integrityReasons(read: TimelineJournalReadResult,
                                         snapshot: WorkSnapshot) -> [String] {
        var reasons: [String] = []
        if read.records.isEmpty { reasons.append("journal has no committed records") }
        if read.truncatedTail != nil { reasons.append("journal has an uncommitted truncated tail") }
        if read.quarantinedSuffix != nil { reasons.append("journal has a quarantined suffix") }
        if !snapshot.structuralIntegrityValid { reasons.append(contentsOf: snapshot.corruptionReasons) }
        if !snapshot.semanticProjectionValid { reasons.append("semantic projection is invalid") }
        return unique(reasons)
    }

    private static func integrityReasons(read: TimelineJournalReadResult,
                                         snapshot: SessionSnapshot) -> [String] {
        var reasons: [String] = []
        if read.records.isEmpty { reasons.append("journal has no committed records") }
        if read.truncatedTail != nil { reasons.append("journal has an uncommitted truncated tail") }
        if read.quarantinedSuffix != nil { reasons.append("journal has a quarantined suffix") }
        if !snapshot.structuralIntegrityValid { reasons.append(contentsOf: snapshot.corruptionReasons) }
        if !snapshot.semanticProjectionValid { reasons.append("semantic projection is invalid") }
        return unique(reasons)
    }

    private static func children(
        of url: URL, label: String, maximum: Int,
        diagnostics: inout DiagnosticSink
    ) -> [URL] {
        let fm = FileManager.default
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                diagnostics.append(kind: "unavailable_directory", message: "\(label) is not a directory")
                return []
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               [CocoaError.fileNoSuchFile.rawValue,
                CocoaError.fileReadNoSuchFile.rawValue].contains(nsError.code)
            {
                return []
            }
            diagnostics.append(kind: "unavailable_directory", message: "\(label) could not be read")
            return []
        }
        var readFailed = false
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                readFailed = true
                return false
            })
        else {
            // The filesystem error often embeds an absolute path. The public diagnostic names
            // only the catalog plane so local usernames/layout never become protocol metadata.
            diagnostics.append(
                kind: "unavailable_directory", message: "\(label) could not be read")
            return []
        }
        var values: [URL] = []
        values.reserveCapacity(maximum)
        var overflowed = false
        for case let child as URL in enumerator {
            if values.count < maximum {
                values.append(child)
                values.sort { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                overflowed = true
                if let last = values.last,
                   child.lastPathComponent < last.lastPathComponent
                {
                    values[values.count - 1] = child
                    values.sort { $0.lastPathComponent < $1.lastPathComponent }
                }
            }
        }
        if readFailed {
            diagnostics.append(
                kind: "unavailable_directory", message: "\(label) could not be read completely")
        }
        if overflowed {
            diagnostics.append(
                kind: "catalog_bound", message: "\(label) discovery limit reached")
        }
        return values
    }

    private static func boundedData(_ url: URL, maxBytes: Int) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= maxBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= maxBytes
        else { return nil }
        return data
    }

    private static func safeResolved(_ url: URL) -> URL? {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isSafeFile(_ url: URL, under root: URL) -> Bool {
        guard let resolved = safeResolved(url),
              resolved.path == url.standardizedFileURL.path,
              resolved.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
        else { return false }
        return true
    }

    private static func safeEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
            && safeResolved(lhs)?.path == safeResolved(rhs)?.path
    }

    private static func qualifiedWork(_ work: WorkRef) -> String {
        "work:\(work.workHostID.utf8.count):\(work.workHostID)"
            + ":\(work.workID.utf8.count):\(work.workID)"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
