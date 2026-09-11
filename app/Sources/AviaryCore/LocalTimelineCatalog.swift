import Foundation

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
        public let maxWorkHostControlJournals: Int
        public let maxClientAttachmentsPerControl: Int
        public let maxReadAcknowledgementsPerControl: Int

        public init(maxSessionJournals: Int = 512, maxWorkJournals: Int = 2_048,
                    maxJournalBytes: Int = 64 * 1024 * 1024, maxDiagnostics: Int = 128,
                    maxCorruptionReasonsPerRow: Int = 16,
                    maxWorkHostControlJournals: Int = 512,
                    maxClientAttachmentsPerControl: Int = 256,
                    maxReadAcknowledgementsPerControl: Int = 256) {
            self.maxSessionJournals = max(1, maxSessionJournals)
            self.maxWorkJournals = max(1, maxWorkJournals)
            self.maxJournalBytes = max(1, maxJournalBytes)
            self.maxDiagnostics = max(1, maxDiagnostics)
            self.maxCorruptionReasonsPerRow = max(1, maxCorruptionReasonsPerRow)
            self.maxWorkHostControlJournals = max(1, maxWorkHostControlJournals)
            self.maxClientAttachmentsPerControl = max(1, maxClientAttachmentsPerControl)
            self.maxReadAcknowledgementsPerControl = max(1, maxReadAcknowledgementsPerControl)
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
            let digest = AviarySHA256.hash(data: Data("\(kind)\0\(self.message)".utf8))
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

    /// A privacy-safe projection of one Work-owned agent child. Request/result bodies, labels,
    /// deadlines, and cancellation envelopes remain canonical Work facts and are not catalog
    /// metadata.
    public struct AgentHandleFact: Codable, Hashable, Sendable, Identifiable {
        internal static let maximumIdentityBytes = PersistentWorkExactState.maximumIdentityBytes
        public let handleID: String
        public let origin: WorkAgentHandleOrigin
        public let state: WorkAgentHandleState
        public let terminalOutcome: WorkAgentHandleTerminalOutcome?
        public let cleanupState: WorkAgentHandleCleanupState?
        public let latestLifecycleEvent: EventRef
        private let projectionValidity: Bool

        public var id: String { handleID }

        public var blocksWorkCompletion: Bool {
            !projectionValidity || state.isLive || cleanupState == .indeterminate
        }

        internal var isProjectionValid: Bool { projectionValidity }

        internal init(_ value: WorkAgentHandleSnapshot) {
            handleID = value.handle.handleID
            origin = value.origin
            state = value.state
            terminalOutcome = value.terminalOutcome
            cleanupState = value.cleanup?.state
            latestLifecycleEvent = value.latestLifecycleEvent
            projectionValidity = Self.isStructurallyValid(
                handleID: handleID, origin: origin, state: state,
                terminalOutcome: terminalOutcome, cleanupState: cleanupState,
                latestLifecycleEvent: latestLifecycleEvent)
        }

        private enum CodingKeys: String, CodingKey {
            case handleID, origin, state, terminalOutcome, cleanupState, latestLifecycleEvent
        }

        public init(from decoder: Decoder) throws {
            do {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let decodedHandleID = try container.decode(String.self, forKey: .handleID)
                let decodedOrigin = try container.decode(WorkAgentHandleOrigin.self, forKey: .origin)
                let decodedState = try container.decode(WorkAgentHandleState.self, forKey: .state)
                let decodedOutcome = try container.decodeIfPresent(
                    WorkAgentHandleTerminalOutcome.self, forKey: .terminalOutcome)
                let decodedCleanup = try container.decodeIfPresent(
                    WorkAgentHandleCleanupState.self, forKey: .cleanupState)
                let decodedEvent = try container.decode(EventRef.self, forKey: .latestLifecycleEvent)
                guard Self.isStructurallyValid(
                    handleID: decodedHandleID, origin: decodedOrigin, state: decodedState,
                    terminalOutcome: decodedOutcome, cleanupState: decodedCleanup,
                    latestLifecycleEvent: decodedEvent) else {
                    throw Self.invalidProjectionError(codingPath: container.codingPath)
                }
                handleID = decodedHandleID
                origin = decodedOrigin
                state = decodedState
                terminalOutcome = decodedOutcome
                cleanupState = decodedCleanup
                latestLifecycleEvent = decodedEvent
                projectionValidity = true
            } catch {
                throw Self.invalidProjectionError(codingPath: decoder.codingPath)
            }
        }

        public func encode(to encoder: Encoder) throws {
            guard projectionValidity else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "invalid agent Handle catalog fact"))
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(handleID, forKey: .handleID)
            try container.encode(origin, forKey: .origin)
            try container.encode(state, forKey: .state)
            try container.encodeIfPresent(terminalOutcome, forKey: .terminalOutcome)
            try container.encodeIfPresent(cleanupState, forKey: .cleanupState)
            try container.encode(latestLifecycleEvent, forKey: .latestLifecycleEvent)
        }

        private static func isStructurallyValid(
            handleID: String, origin: WorkAgentHandleOrigin, state: WorkAgentHandleState,
            terminalOutcome: WorkAgentHandleTerminalOutcome?,
            cleanupState: WorkAgentHandleCleanupState?, latestLifecycleEvent: EventRef
        ) -> Bool {
            guard !handleID.isEmpty,
                  !origin.work.workHostID.isEmpty, !origin.work.workID.isEmpty,
                  origin.workHost == WorkHostRef(origin.work.workHostID),
                  !origin.session.sessionID.isEmpty,
                  !origin.sessionAttachment.attachmentID.isEmpty,
                  !origin.run.runID.isEmpty,
                  !latestLifecycleEvent.eventID.isEmpty,
                  case .work(let owner) = latestLifecycleEvent.journal.owner,
                  owner == origin.work,
                  latestLifecycleEvent.journal.authority.authorityID == origin.work.workHostID
            else { return false }
            let identityValues = [
                handleID, origin.work.workHostID, origin.work.workID,
                origin.workHost.workHostID, origin.session.sessionID,
                origin.sessionAttachment.attachmentID, origin.run.runID,
                latestLifecycleEvent.journal.journalID,
                latestLifecycleEvent.journal.authority.authorityID,
                latestLifecycleEvent.eventID,
            ]
            guard identityValues.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= maximumIdentityBytes
            }) else { return false }
            switch state {
            case .queued, .running, .cancelRequested:
                return terminalOutcome == nil && cleanupState == nil
            case .terminal:
                guard let terminalOutcome, let cleanupState else { return false }
                if terminalOutcome == .indeterminate {
                    return cleanupState == .indeterminate
                }
                switch cleanupState {
                case .notStarted:
                    return [.failed, .canceled, .expired].contains(terminalOutcome)
                case .quiesced:
                    return [.succeeded, .failed, .canceled, .expired].contains(terminalOutcome)
                case .indeterminate:
                    return false
                }
            case .reaped:
                guard let terminalOutcome, let cleanupState else { return false }
                switch cleanupState {
                case .notStarted:
                    return [.failed, .canceled, .expired].contains(terminalOutcome)
                case .quiesced:
                    return [.succeeded, .failed, .canceled, .expired].contains(terminalOutcome)
                case .indeterminate:
                    return false
                }
            }
        }

        private static func invalidProjectionError(codingPath: [CodingKey]) -> DecodingError {
            .dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "invalid agent Handle catalog fact"))
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.handleID == rhs.handleID && lhs.origin == rhs.origin
                && lhs.state == rhs.state && lhs.terminalOutcome == rhs.terminalOutcome
                && lhs.cleanupState == rhs.cleanupState
                && lhs.latestLifecycleEvent == rhs.latestLifecycleEvent
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(handleID)
            hasher.combine(origin)
            hasher.combine(state)
            hasher.combine(terminalOutcome)
            hasher.combine(cleanupState)
            hasher.combine(latestLifecycleEvent)
        }

        /// Stable, privacy-preserving order for bounded agent-child presentation. Completion
        /// blockers always survive a low presentation bound before terminal/quiescent facts.
        internal static func less(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.blocksWorkCompletion != rhs.blocksWorkCompletion {
                return lhs.blocksWorkCompletion
            }
            return lhs.handleID < rhs.handleID
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
        public let agentHandles: [AgentHandleFact]
        public let commands: [CommandFact]
        /// Child lifecycle facts from the exact Work journal, when one was supplied. This is
        /// deliberately separate from the legacy AgentTree; an unavailable or unaligned read
        /// yields an unavailable projection and never lends child state to the UI.
        public let canonicalFlock: CanonicalFlockProjection?
        /// Exact many-to-many attachment facts from the Work journal. These are facts about
        /// who is attached, not ownership claims about any one GUI.
        public let sessionAttachments: [WorkSessionAttachmentSnapshot]
        /// Durable client attachment facts joined from the Work Host control journal. Work and
        /// Session journals intentionally never populate this field.
        public let clientAttachments: [WorkHostClientAttachmentSnapshot]
        public let omittedSessionAttachmentCount: Int
        public let omittedClientAttachmentCount: Int
        /// Work-recorded recovery claims retain their source event and full identity envelope;
        /// Session-recorded claims are joined separately through canonical Session summaries.
        public let recoveryCoverage: [RecordedRecoveryCoverage]
        public let omittedRecoveryCoverageCount: Int
        public let runHistory: [RunRef]
        public let omittedRunCount: Int
        /// Complete membership proof retained inside AviaryCore for exact recovery-envelope
        /// joins. Public consumers receive only the bounded `runHistory` projection above.
        internal let observedRunIDs: Set<String>
        public let unknownEventRefs: [EventRef]
        public let unknownDomains: [TimelineDomain]
        public let tailBytes: Int
        public let corruptionReasons: [String]

        internal init(locatorID: String, work declaredWork: WorkRef?, journal: JournalRef?,
                         snapshot: WorkSnapshot?,
                         read: TimelineJournalReadResult?, available: Bool, reasons: [String],
                         limit: Int, presentationID: String? = nil,
                         controlClientAttachments: [WorkHostClientAttachmentSnapshot] = [],
                         omittedControlClientAttachmentCount: Int = 0,
                         attachmentLimit: Int = 256) {
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
            let attachmentLimit = max(1, attachmentLimit)
            if exact, let snapshot,
               !snapshot.unknownDomains.contains(.work),
               !snapshot.unknownDomains.contains(.session) {
                let orderedSessions = snapshot.sessionAttachments.values.sorted {
                    $0.attachment.attachmentID < $1.attachment.attachmentID
                }
                sessionAttachments = Array(orderedSessions.prefix(attachmentLimit))
                omittedSessionAttachmentCount = max(0, orderedSessions.count - attachmentLimit)
            } else {
                sessionAttachments = []
                omittedSessionAttachmentCount = 0
            }
            if exact, let snapshot, !snapshot.unknownDomains.contains(.work) {
                let runLimit = 256
                let orderedRuns = snapshot.observedRunIDs.sorted().map(RunRef.init)
                runHistory = Array(orderedRuns.prefix(runLimit))
                omittedRunCount = max(0, orderedRuns.count - runLimit)
                observedRunIDs = snapshot.observedRunIDs
            } else {
                runHistory = []
                omittedRunCount = 0
                observedRunIDs = []
            }
            if exact, !controlClientAttachments.isEmpty,
               let snapshot, !snapshot.unknownDomains.contains(.work) {
                let orderedClients = controlClientAttachments.sorted {
                    $0.attachment.attachmentID < $1.attachment.attachmentID
                }
                clientAttachments = Array(orderedClients.prefix(attachmentLimit))
                omittedClientAttachmentCount = max(0, orderedClients.count - attachmentLimit)
                    + max(0, omittedControlClientAttachmentCount)
            } else {
                clientAttachments = []
                omittedClientAttachmentCount = 0
            }
            // Recovery claims are themselves typed Work facts. Preserve bounded, envelope-
            // qualified claims when another domain is unknown; that uncertainty remains visible
            // on the Work recovery row rather than erasing the claim and its source evidence.
            if exact, let snapshot, !snapshot.unknownDomains.contains(.work) {
                let orderedRecovery = snapshot.recordedRecovery.sorted {
                    Self.recoveryKey($0) < Self.recoveryKey($1)
                }
                let recoveryLimit = 64
                recoveryCoverage = Array(orderedRecovery.prefix(recoveryLimit))
                omittedRecoveryCoverageCount = max(0, orderedRecovery.count - recoveryLimit)
            } else {
                recoveryCoverage = []
                omittedRecoveryCoverageCount = 0
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
                let agentHandleFactsKnown = workFactsKnown && runtimeFactsKnown
                    && !snapshot.unknownDomains.contains(.externalEffects)
                agentHandles = agentHandleFactsKnown
                    ? Array(snapshot.agentHandles.values
                        .map(AgentHandleFact.init)
                        .sorted(by: LocalTimelineCatalog.agentHandleLess)
                        .prefix(WorkAgentHandleSnapshot.maximumRetainedPerWork))
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
                agentHandles = []
                commands = []
            }
            tailBytes = (read?.truncatedTail?.rawBytes.count ?? 0)
                + (read?.quarantinedSuffix?.rawBytes.count ?? 0)
            corruptionReasons = reasons.prefix(limit).map { String($0.prefix(512)) }
        }

        private static func recoveryKey(_ value: RecordedRecoveryCoverage) -> String {
            value.sourceEvent.journal.stableKey + "|" + value.sourceEvent.eventID
        }

        fileprivate func withControlClientAttachments(
            _ values: [WorkHostClientAttachmentSnapshot],
            snapshot: WorkSnapshot?,
            read: TimelineJournalReadResult?,
            reasonLimit: Int,
            omittedControlClientAttachmentCount: Int = 0,
            attachmentLimit: Int
        ) -> WorkRow {
            WorkRow(
                locatorID: locatorID ?? id, work: work, journal: journal, snapshot: snapshot,
                read: read, available: isAvailable, reasons: corruptionReasons,
                limit: reasonLimit, presentationID: id,
                controlClientAttachments: values,
                omittedControlClientAttachmentCount: omittedControlClientAttachmentCount,
                attachmentLimit: attachmentLimit)
        }
    }

    /// Stable, privacy-preserving order for bounded agent-child presentation. Completion
    /// blockers always survive a low presentation bound before terminal/quiescent facts.
    internal static func agentHandleLess(
        _ lhs: AgentHandleFact, _ rhs: AgentHandleFact
    ) -> Bool {
        AgentHandleFact.less(lhs, rhs)
    }

    /// One discovered Work Host control journal. Control rows remain visible when the journal
    /// is unreadable or semantically incomplete, but their client/read facts are unavailable in
    /// that case. A control row is never inferred from Work or Session records.
    public struct WorkHostControlRow: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let locatorID: String
        public let workHost: WorkHostRef?
        public let journal: JournalRef?
        public let cursor: JournalCursor?
        public let isAvailable: Bool
        public let clientAttachments: [WorkHostClientAttachmentSnapshot]
        public let omittedClientAttachmentCount: Int
        public let readAcknowledgements: [WorkHostReadAcknowledgementSnapshot]
        public let omittedReadAcknowledgementCount: Int
        public let unknownEventRefs: [EventRef]
        public let unknownDomains: [TimelineDomain]
        /// Bytes after the last independently synchronized Work Host control seal. They are
        /// visible recovery evidence but never projected as attachment or read-ack facts.
        public let unsealedSuffixBytes: Int
        public let tailBytes: Int
        public let corruptionReasons: [String]

        internal init(
            locatorID: String,
            workHost: WorkHostRef?,
            journal: JournalRef?,
            snapshot: WorkHostControlSnapshot?,
            read: TimelineJournalReadResult?,
            available: Bool,
            reasons: [String],
            limits: Limits,
            presentationID: String? = nil,
            unsealedSuffixBytes: Int = 0
        ) {
            self.locatorID = locatorID
            self.workHost = workHost
            self.journal = journal
            id = presentationID ?? journal?.stableKey ?? locatorID
            let exact = available && snapshot != nil
            if exact, let journal, let last = read?.records.last {
                cursor = JournalCursor(
                    journal: journal, eventID: last.event.eventID, sequence: last.event.sequence)
            } else {
                cursor = nil
            }
            let attachmentValues = snapshot?.clientAttachments.values.sorted {
                if $0.attachment.attachmentID != $1.attachment.attachmentID {
                    return $0.attachment.attachmentID < $1.attachment.attachmentID
                }
                return $0.client.clientID < $1.client.clientID
            } ?? []
            let readValues = snapshot?.readAcknowledgements.values.sorted {
                if $0.client.clientID != $1.client.clientID {
                    return $0.client.clientID < $1.client.clientID
                }
                if $0.attachment.attachmentID != $1.attachment.attachmentID {
                    return $0.attachment.attachmentID < $1.attachment.attachmentID
                }
                return $0.targetJournal.stableKey < $1.targetJournal.stableKey
            } ?? []
            var boundedAttachments: [WorkHostClientAttachmentSnapshot]
            var omittedAttachments: Int
            var boundedAcknowledgements: [WorkHostReadAcknowledgementSnapshot]
            var omittedAcknowledgements: Int
            if exact {
                boundedAttachments = Array(attachmentValues.prefix(limits.maxClientAttachmentsPerControl))
                omittedAttachments = max(
                    0, attachmentValues.count - boundedAttachments.count)
                boundedAcknowledgements = Array(
                    readValues.prefix(limits.maxReadAcknowledgementsPerControl))
                omittedAcknowledgements = max(
                    0, readValues.count - boundedAcknowledgements.count)
            } else {
                boundedAttachments = []
                omittedAttachments = 0
                boundedAcknowledgements = []
                omittedAcknowledgements = 0
            }
            unknownEventRefs = snapshot?.unknownEvents.map {
                EventRef(journal: $0.event.journal, eventID: $0.event.eventID)
            }.sorted { lhs, rhs in
                if lhs.journal.stableKey != rhs.journal.stableKey {
                    return lhs.journal.stableKey < rhs.journal.stableKey
                }
                return lhs.eventID < rhs.eventID
            } ?? []
            unknownDomains = Array(Set(snapshot?.unknownEvents.flatMap {
                Array($0.affectedDomains)
            } ?? [])).sorted { $0.rawValue < $1.rawValue }
            self.unsealedSuffixBytes = max(0, unsealedSuffixBytes)
            tailBytes = self.unsealedSuffixBytes
                + (read?.truncatedTail?.rawBytes.count ?? 0)
                + (read?.quarantinedSuffix?.rawBytes.count ?? 0)
            var allReasons = reasons
            if !(snapshot?.unknownEvents.isEmpty ?? true) {
                allReasons.append("control journal contains unknown events")
            }
            var rowAvailable = exact && allReasons.isEmpty
            if !allReasons.isEmpty || !exact {
                // Unknown control events may supersede an attachment or acknowledgement. The
                // row remains visible as evidence but its bounded facts cannot be used.
                rowAvailable = false
                boundedAttachments = []
                omittedAttachments = 0
                boundedAcknowledgements = []
                omittedAcknowledgements = 0
            }
            isAvailable = rowAvailable
            clientAttachments = boundedAttachments
            omittedClientAttachmentCount = omittedAttachments
            readAcknowledgements = boundedAcknowledgements
            omittedReadAcknowledgementCount = omittedAcknowledgements
            corruptionReasons = Array(allReasons.prefix(limits.maxCorruptionReasonsPerRow))
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
        public let workHostControls: [WorkHostControlRow]
        public let diagnostics: [Diagnostic]
        public let diagnosticsTruncated: Bool

        fileprivate init(sessions: [SessionRow], works: [WorkRow],
                         workHostControls: [WorkHostControlRow], diagnostics: [Diagnostic],
                         diagnosticsTruncated: Bool) {
            self.sessions = sessions
            sessionSummaries = sessions.compactMap(\SessionRow.summary)
                .sorted { $0.id < $1.id }
            self.works = works
            self.workHostControls = workHostControls
            self.diagnostics = diagnostics
            self.diagnosticsTruncated = diagnosticsTruncated
        }

        /// Notification delivery may baseline when discovery is complete. Row-local failures are
        /// omitted from canonical facts and retain their prior checkpoint; they must not block
        /// unrelated exact Sessions. Only discovery uncertainty makes the source incomplete.
        public var canonicalNotificationSourceComplete: Bool {
            guard !diagnosticsTruncated else { return false }
            let globalKinds: Set<String> = ["unsafe_root", "catalog_bound", "unavailable_directory"]
            return !diagnostics.contains { globalKinds.contains($0.kind) }
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
        let controlCandidates = candidates.filter { $0.kind == .control }

        var controlRecords: [ControlRecord] = []
        for candidate in controlCandidates {
            controlRecords.append(readControl(candidate, home: home, limits: limits,
                                               diagnostics: &diagnostics))
        }
        let controlCounts = Dictionary(grouping: controlRecords.compactMap { record in
            record.row.workHost.map { ($0, record) }
        }, by: { $0.0 }).mapValues(\.count)
        let conflictedControlHosts = Set(
            controlCounts.compactMap { $0.value > 1 ? $0.key : nil })
        for host in conflictedControlHosts.sorted(by: { $0.workHostID < $1.workHostID }) {
            diagnostics.append(
                kind: "duplicate_work_host_control",
                message: "duplicate Work Host control journal (\(host.workHostID)); no client facts can project")
        }

        var workRecords: [WorkRecord] = []
        for candidate in workCandidates {
            workRecords.append(readWork(candidate, home: home, limits: limits,
                                        diagnostics: &diagnostics))
        }
        // Enrich Work rows only after their journal has established the authority-qualified
        // WorkRef. Directory names are not identities, and a control row is usable only when it
        // is the unique available journal for that Work Host.
        workRecords = workRecords.map { record in
            guard let work = record.row.work,
                  let control = controlRecords.first(where: {
                      $0.row.workHost == WorkHostRef(work.workHostID)
                  }), controlRecords.filter({ $0.row.workHost == control.row.workHost }).count == 1,
                  control.row.isAvailable,
                  let journal = record.row.journal else { return record }
            let attachments = control.row.clientAttachments.filter {
                $0.work == work && $0.workJournal == journal
            }
            guard !attachments.isEmpty else { return record }
            let allMatchingAttachments = control.snapshot?.clientAttachments.values.filter {
                $0.work == work && $0.workJournal == journal
            }.count ?? attachments.count
            let enriched = record.row.withControlClientAttachments(
                attachments, snapshot: record.snapshot, read: record.read,
                reasonLimit: limits.maxCorruptionReasonsPerRow,
                omittedControlClientAttachmentCount: max(
                    0, allMatchingAttachments - attachments.count),
                attachmentLimit: limits.maxClientAttachmentsPerControl)
            return WorkRecord(locatorID: record.locatorID, row: enriched,
                              snapshot: record.snapshot, read: record.read)
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
                        workHostControls: controlRecords.map(\.row),
                        diagnostics: diagnostics.values, diagnosticsTruncated: diagnostics.didOmit)
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

    private enum Kind { case session, work, control }
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
    private struct ControlRecord {
        let locatorID: String
        let row: WorkHostControlRow
        let snapshot: WorkHostControlSnapshot?
        let read: TimelineJournalReadResult?
    }
    private struct DiagnosticSink {
        let limit: Int
        var values: [Diagnostic] = []
        var didOmit = false

        init(limit: Int) { self.limit = limit }

        mutating func append(kind: String, message: String) {
            guard values.count < limit else {
                didOmit = true
                return
            }
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
        var controls = 0
        for host in children(
            of: home.timelineV2WorkHostsDir, label: "Work Host directory",
            maximum: max(limits.maxWorkJournals, limits.maxWorkHostControlJournals),
            diagnostics: &diagnostics)
        {
            if works < limits.maxWorkJournals {
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
            let control = host.appending(path: "control", directoryHint: .isDirectory)
                .appending(path: "journal.jsonl", directoryHint: .notDirectory)
            if fm.fileExists(atPath: control.path) {
                add(.control, control, &controls, limits.maxWorkHostControlJournals)
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

    private static func readControl(
        _ candidate: Candidate,
        home: AgentHome,
        limits: Limits,
        diagnostics: inout DiagnosticSink
    ) -> ControlRecord {
        let failureID = candidate.locatorID
        guard let data = boundedData(candidate.url, maxBytes: limits.maxJournalBytes) else {
            let reason = "control journal is unreadable or exceeds the catalog byte bound"
            diagnostics.append(kind: "unavailable_work_host_control",
                               message: "\(failureID): \(reason)")
            return ControlRecord(
                locatorID: failureID,
                row: WorkHostControlRow(locatorID: failureID, workHost: nil, journal: nil,
                                        snapshot: nil, read: nil, available: false,
                                        reasons: [reason], limits: limits),
                snapshot: nil, read: nil)
        }
        guard let declared = firstJournalRef(in: data),
              case .workHost(let workHost) = declared.owner,
              declared.authority.authorityID == workHost.workHostID,
              safeEqual(candidate.url, home.timelineV2WorkHostControlJournalURL(workHost))
        else {
            let reason = "declared Work Host control owner, authority, or locator does not round-trip"
            diagnostics.append(kind: "unavailable_work_host_control",
                               message: "\(failureID): \(reason)")
            return ControlRecord(
                locatorID: failureID,
                row: WorkHostControlRow(locatorID: failureID, workHost: nil, journal: nil,
                                        snapshot: nil, read: nil, available: false,
                                        reasons: [reason], limits: limits),
                snapshot: nil, read: nil)
        }
        let committedData: Data
        do {
            committedData = try WorkHostControlJournal.committedPrefixData(
                for: candidate.url, journal: declared, data: data)
        } catch {
            let reason = "Work Host control durability seal is missing or does not match the journal"
            diagnostics.append(kind: "unavailable_work_host_control",
                               message: "\(failureID): \(reason)")
            return ControlRecord(
                locatorID: failureID,
                row: WorkHostControlRow(
                    locatorID: failureID, workHost: workHost, journal: declared,
                    snapshot: nil, read: nil, available: false,
                    reasons: [reason], limits: limits),
                snapshot: nil, read: nil)
        }
        let unsealedSuffixBytes = max(0, data.count - committedData.count)
        if unsealedSuffixBytes > 0 {
            diagnostics.append(
                kind: "unsealed_work_host_control_suffix",
                message: "\(failureID): \(unsealedSuffixBytes) uncommitted suffix bytes were withheld")
        }
        let read = TimelineJournalReader.read(
            committedData, journal: declared,
            actor: TimelineActor(actorID: "local-catalog", kind: "reader"),
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        let snapshot = WorkHostControlReducer.reduce(
            read.records.map(\.event),
            initial: WorkHostControlSnapshot(journal: declared))
        var reasons = integrityReasons(read: read, snapshot: snapshot)
        if snapshot.journal != declared || snapshot.workHost != workHost {
            reasons.append("Work Host control reducer identity does not match the declared journal")
        }
        let row = WorkHostControlRow(
            locatorID: candidate.locatorID, workHost: workHost, journal: declared,
            snapshot: snapshot, read: read, available: reasons.isEmpty,
            reasons: unique(reasons), limits: limits,
            unsealedSuffixBytes: unsealedSuffixBytes)
        if !row.isAvailable {
            diagnostics.append(
                kind: "unavailable_work_host_control",
                message: "\(row.id): \(row.corruptionReasons.joined(separator: "; "))")
        }
        return ControlRecord(locatorID: candidate.locatorID, row: row,
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

    private static func integrityReasons(
        read: TimelineJournalReadResult,
        snapshot: WorkHostControlSnapshot
    ) -> [String] {
        var reasons: [String] = []
        if read.records.isEmpty { reasons.append("journal has no committed records") }
        if read.truncatedTail != nil { reasons.append("journal has an uncommitted truncated tail") }
        if read.quarantinedSuffix != nil { reasons.append("journal has a quarantined suffix") }
        if !snapshot.causalOrderValid { reasons.append("control journal causal order is invalid") }
        if !snapshot.structuralIntegrityValid { reasons.append(contentsOf: snapshot.corruptionReasons) }
        if !snapshot.semanticProjectionValid { reasons.append("control semantic projection is invalid") }
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
        AviarySHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
