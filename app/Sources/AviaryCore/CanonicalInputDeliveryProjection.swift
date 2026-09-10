import Foundation

/// The state a Session input can honestly have after it is joined to the Work command ledger.
/// In particular, an accepted command is not delivered merely because a client received a
/// service receipt; delivery requires the exact canonical Work delivery event in the snapshot.
public enum CanonicalInputDeliveryState: String, Codable, Hashable, Sendable {
    case acceptedWaitingDelivery = "accepted_waiting_delivery"
    case delivered
    case notDelivered = "not_delivered"
    case indeterminateUnknownEffect = "indeterminate_unknown_effect"
    case provenanceUnavailable = "provenance_unavailable"
}

public enum CanonicalInputDeliveryIssue: String, Codable, Hashable, Sendable {
    case missingCause = "missing_cause"
    case foreignCause = "foreign_cause"
    case missingAcceptance = "missing_acceptance"
    case duplicateAcceptance = "duplicate_acceptance"
    case journalMismatch = "journal_mismatch"
    case clientMismatch = "client_mismatch"
    case sessionAttachmentMismatch = "session_attachment_mismatch"
    case runMismatch = "run_mismatch"
    case commandKindUnavailable = "command_kind_unavailable"
    case deliveryModeUnavailable = "delivery_mode_unavailable"
    case deliveryEvidenceUnavailable = "delivery_evidence_unavailable"
    case missingSessionMessage = "missing_session_message"
    case inputFactUnavailable = "input_fact_unavailable"
    case sourceUnavailable = "source_unavailable"
}

/// One bounded GUI-facing join row. This row never carries input text: the Session snapshot is
/// the owner of that content, while this projection only supplies identity and delivery truth.
public struct CanonicalInputDeliveryRow: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let commandID: String?
    public let messageEvent: EventRef?
    public let acceptanceEvent: EventRef?
    public let deliveryEvent: EventRef?
    public let hostSequence: Int?
    public let client: ClientRef?
    public let sessionAttachment: SessionAttachmentRef?
    public let run: RunRef?
    public let commandKind: CanonicalCommandKind?
    public let deliveryMode: RunInputDeliveryMode?
    public let state: CanonicalInputDeliveryState
    public let issue: CanonicalInputDeliveryIssue?

    public init(
        id: String, commandID: String?, messageEvent: EventRef?, acceptanceEvent: EventRef?,
        deliveryEvent: EventRef?, hostSequence: Int?, client: ClientRef?,
        sessionAttachment: SessionAttachmentRef?, run: RunRef?,
        commandKind: CanonicalCommandKind?, deliveryMode: RunInputDeliveryMode?,
        state: CanonicalInputDeliveryState, issue: CanonicalInputDeliveryIssue?
    ) {
        self.id = id
        self.commandID = commandID
        self.messageEvent = messageEvent
        self.acceptanceEvent = acceptanceEvent
        self.deliveryEvent = deliveryEvent
        self.hostSequence = hostSequence
        self.client = client
        self.sessionAttachment = sessionAttachment
        self.run = run
        self.commandKind = commandKind
        self.deliveryMode = deliveryMode
        self.state = state
        self.issue = issue
    }

    /// Outcomes whose retry safety requires explicit human review. Accepted-waiting commands are
    /// unresolved too, but have their own pending section and must not be duplicated here.
    public var requiresHumanReview: Bool {
        switch state {
        case .indeterminateUnknownEffect, .provenanceUnavailable: return true
        case .notDelivered: return messageEvent == nil
        case .acceptedWaitingDelivery, .delivered: return false
        }
    }

    public var requiresPriorityRetention: Bool {
        state == .acceptedWaitingDelivery || requiresHumanReview
    }
}

/// A pure, snapshot-only input-delivery join. Callers provide source completeness explicitly;
/// this keeps a bounded page from being mistaken for the whole Work/Session history.
public struct CanonicalInputDeliveryProjection: Codable, Hashable, Sendable {
    public static let maximumUnresolvedCommands = 128
    public static let maximumRows = 512
    public static let maximumOmissionCount = WorkServiceBounds.maxOmissionCount

    public let rows: [CanonicalInputDeliveryRow]
    public let omittedRowCount: Int
    /// Accepted commands with no canonical delivery outcome, ordered by host sequence.
    public let unresolvedAcceptedCommands: [CanonicalInputDeliveryRow]
    public let omittedUnresolvedAcceptedCommandCount: Int
    /// Number of omitted accepted, indeterminate, or otherwise unproven rows that deserve user
    /// attention. This is separate from ordinary resolved-history row omission.
    public let omittedAttentionCount: Int
    public let workSourceCompleteness: WorkServiceSourceCompleteness
    public let sessionSourceCompleteness: WorkServiceSourceCompleteness
    public let omissions: [WorkServiceOmission]
    /// False whenever either source is incomplete/unknown, an omission occurred, or a row's
    /// identity could not be proven. Rows remain available as evidence in that case.
    public let isCanonical: Bool

    public init(
        workSnapshot: WorkSnapshot,
        sessionSnapshot: SessionSnapshot,
        workSourceCompleteness: WorkServiceSourceCompleteness = .complete,
        sessionSourceCompleteness: WorkServiceSourceCompleteness = .complete,
        workOmissions: [WorkServiceOmission] = [],
        sessionOmissions: [WorkServiceOmission] = [],
        maximumUnresolvedCommands: Int = CanonicalInputDeliveryProjection.maximumUnresolvedCommands,
        maximumRows: Int = CanonicalInputDeliveryProjection.maximumRows
    ) {
        self.workSourceCompleteness = workSourceCompleteness
        self.sessionSourceCompleteness = sessionSourceCompleteness

        let messages = (sessionSnapshot.messageHistory.isEmpty
            ? sessionSnapshot.messages : sessionSnapshot.messageHistory)
            .filter { $0.role == "user" }
        var acceptanceCounts: [EventRef: Int] = [:]
        var commandsByAcceptance: [EventRef: [WorkCommandSnapshot]] = [:]
        var commandIDCounts: [String: Int] = [:]
        for command in workSnapshot.commands.values {
            if let ref = command.acceptanceEventRef {
                acceptanceCounts[ref, default: 0] += 1
                commandsByAcceptance[ref, default: []].append(command)
            }
            commandIDCounts[command.command.commandID, default: 0] += 1
        }

        var builtRows: [CanonicalInputDeliveryRow] = []
        let rowBound = min(max(0, maximumRows), Self.maximumRows)
        var omittedRows = 0
        var omittedUnresolved = 0
        var omittedAttention = 0
        var unattributedInputs = 0
        var joinedAcceptanceRefs = Set<EventRef>()
        for message in messages {
            let row = Self.join(
                message: message, work: workSnapshot, session: sessionSnapshot,
                acceptanceCounts: acceptanceCounts, commandIDCounts: commandIDCounts,
                commandsByAcceptance: commandsByAcceptance)
            Self.retain(row, in: &builtRows, bound: rowBound,
                        omittedRows: &omittedRows, omittedUnresolved: &omittedUnresolved,
                        omittedAttention: &omittedAttention)
            if let acceptance = row.acceptanceEvent { joinedAcceptanceRefs.insert(acceptance) }
        }
        // The Work acceptance is durable before the Session input event is appended. A crash or
        // bounded Session page can therefore leave a real accepted command with no message row.
        // Keep that metadata-only command in the pending tray when its exact attachment/run are
        // still provable; omitting it would make a retry look safe when it is not.
        if let session = sessionSnapshot.session, let workJournal = workSnapshot.journal {
            for command in workSnapshot.commands.values where command.state != .rejected {
                if let acceptance = command.acceptanceEventRef,
                   joinedAcceptanceRefs.contains(acceptance) { continue }
                // A true producer fact (or an input-capable kind whose fact is unavailable) must
                // not vanish merely because its attachment relationship is corrupt/missing. A
                // relationship mapped to another Session is correctly outside this projection;
                // a relationship no Session can claim is a bounded global attention omission.
                let couldCarryInput = command.carriesSessionInput == true
                    || (command.carriesSessionInput == nil
                        && Self.isInputKind(command.commandKind))
                if couldCarryInput {
                    guard let attachment = command.command.sessionAttachment,
                          let relationship = workSnapshot.sessionAttachments[
                            attachment.attachmentID] else {
                        unattributedInputs = Self.saturatedAdd(unattributedInputs, 1)
                        omittedAttention = Self.saturatedAdd(omittedAttention, 1)
                        continue
                    }
                    if relationship.session != session { continue }
                }
                guard let row = Self.orphanRow(
                    command: command, work: workSnapshot,
                    sessionRef: session, workJournal: workJournal,
                    acceptanceCounts: acceptanceCounts,
                    commandIDCounts: commandIDCounts) else { continue }
                Self.retain(row, in: &builtRows, bound: rowBound,
                            omittedRows: &omittedRows,
                            omittedUnresolved: &omittedUnresolved,
                            omittedAttention: &omittedAttention)
            }
        }
        if workSourceCompleteness != .complete {
            builtRows = builtRows.map { row in
                guard row.state == .acceptedWaitingDelivery else { return row }
                return Self.unavailable(row, issue: .sourceUnavailable)
            }
        } else if sessionSourceCompleteness != .complete {
            // A complete Work prefix can establish an accepted command, but an incomplete
            // Session prefix cannot establish that its user message is absent.
            builtRows = builtRows.map { row in
                guard row.state == .acceptedWaitingDelivery, row.messageEvent == nil else { return row }
                return Self.unavailable(row, issue: .sourceUnavailable)
            }
        }
        self.rows = builtRows.sorted { Self.order($0, then: $1) }
        self.omittedRowCount = omittedRows

        let unresolved = self.rows.filter { $0.state == .acceptedWaitingDelivery }
        let bound = min(max(0, maximumUnresolvedCommands), Self.maximumUnresolvedCommands)
        self.unresolvedAcceptedCommands = Array(unresolved.prefix(bound))
        self.omittedUnresolvedAcceptedCommandCount = Self.saturatedAdd(
            omittedUnresolved, max(0, unresolved.count - bound))
        self.omittedAttentionCount = omittedAttention

        var localOmissions: [WorkServiceOmission] = []
        if omittedRows > 0 {
            localOmissions.append(WorkServiceOmission(
                category: "canonical_input_delivery.rows", count: omittedRows))
        }
        if omittedAttention > 0 {
            localOmissions.append(WorkServiceOmission(
                category: "canonical_input_delivery.attention", count: omittedAttention))
        }
        if unattributedInputs > 0 {
            localOmissions.append(WorkServiceOmission(
                category: "canonical_input_delivery.unattributed_inputs",
                count: unattributedInputs))
        }
        if self.omittedUnresolvedAcceptedCommandCount > 0 {
            localOmissions.append(WorkServiceOmission(
                category: "canonical_input_delivery.unresolved_commands",
                count: self.omittedUnresolvedAcceptedCommandCount))
        }
        if workSourceCompleteness != .complete {
            localOmissions.append(WorkServiceOmission(
                category: "canonical_input_delivery.work_source",
                count: 1, diagnostic: workSourceCompleteness.rawValue))
        }
        if sessionSourceCompleteness != .complete {
            localOmissions.append(WorkServiceOmission(
                category: "canonical_input_delivery.session_source",
                count: 1, diagnostic: sessionSourceCompleteness.rawValue))
        }
        // Preserve this projection's own disclosure categories before bounded upstream
        // diagnostics. Otherwise 64 unrelated remote categories could crowd out the only
        // explicit indication that an input requiring attention was itself omitted.
        self.omissions = Self.boundedOmissions(
            workOmissions + sessionOmissions + localOmissions,
            reservedCategories: Set(localOmissions.map(\.category)))
        let rowsProven = builtRows.allSatisfy { $0.state != .provenanceUnavailable }
        self.isCanonical = rowsProven
            && workSourceCompleteness == .complete
            && sessionSourceCompleteness == .complete
            && self.omittedUnresolvedAcceptedCommandCount == 0
            && omittedRows == 0
            && omittedAttention == 0
            && workOmissions.isEmpty && sessionOmissions.isEmpty
            && workSnapshot.structuralIntegrityValid && workSnapshot.semanticProjectionValid
            && sessionSnapshot.structuralIntegrityValid && sessionSnapshot.semanticProjectionValid
    }

    public var sourceCompleteness: WorkServiceSourceCompleteness {
        if workSourceCompleteness == .unknown || sessionSourceCompleteness == .unknown { return .unknown }
        if workSourceCompleteness == .incomplete || sessionSourceCompleteness == .incomplete { return .incomplete }
        return .complete
    }

    private static func join(
        message: SessionMessageSnapshot, work: WorkSnapshot, session: SessionSnapshot,
        acceptanceCounts: [EventRef: Int], commandIDCounts: [String: Int],
        commandsByAcceptance: [EventRef: [WorkCommandSnapshot]]
    ) -> CanonicalInputDeliveryRow {
        let messageEvent = message.sourceEvent
        let baseID = messageEvent.map { "message/\($0.journal.stableKey)/\($0.eventID)" }
            ?? "message/\(message.eventID)"
        func unavailable(_ issue: CanonicalInputDeliveryIssue, command: WorkCommandSnapshot? = nil)
            -> CanonicalInputDeliveryRow {
            CanonicalInputDeliveryRow(
                id: baseID, commandID: command?.command.commandID,
                messageEvent: messageEvent, acceptanceEvent: command?.acceptanceEventRef,
                deliveryEvent: command?.deliveryEventRef,
                hostSequence: command?.acceptanceHostSequence,
                client: message.client, sessionAttachment: message.sessionAttachment,
                run: message.run, commandKind: command?.commandKind,
                deliveryMode: command?.deliveryMode, state: .provenanceUnavailable, issue: issue)
        }

        guard let causedBy = message.causedBy else { return unavailable(.missingCause) }
        guard let workJournal = work.journal else { return unavailable(.sourceUnavailable) }
        guard causedBy.journal == workJournal else { return unavailable(.foreignCause) }
        guard let commands = commandsByAcceptance[causedBy], let command = commands.first else {
            return unavailable(.missingAcceptance)
        }
        guard acceptanceCounts[causedBy] == 1 else {
            return unavailable(.duplicateAcceptance, command: command)
        }
        guard commandIDCounts[command.command.commandID] == 1 else {
            return unavailable(.duplicateAcceptance, command: command)
        }
        guard let sessionJournal = session.journal,
              let messageEvent,
              messageEvent.journal == sessionJournal,
              causedBy.journal == workJournal,
              command.acceptanceEventRef == causedBy else {
            return unavailable(.journalMismatch, command: command)
        }
        guard command.command.client != nil, command.command.client == message.client else {
            return unavailable(.clientMismatch, command: command)
        }
        guard command.command.sessionAttachment != nil,
              command.command.sessionAttachment == message.sessionAttachment else {
            return unavailable(.sessionAttachmentMismatch, command: command)
        }
        guard let attachment = command.command.sessionAttachment,
              let session = session.session,
              let attachmentFact = work.sessionAttachments[attachment.attachmentID],
              attachmentFact.session == session else {
            return unavailable(.sessionAttachmentMismatch, command: command)
        }
        guard command.acceptanceRun == message.run else {
            return unavailable(.runMismatch, command: command)
        }
        guard command.commandKind != nil else { return unavailable(.commandKindUnavailable, command: command) }
        guard command.deliveryMode != nil else { return unavailable(.deliveryModeUnavailable, command: command) }
        guard command.carriesSessionInput == true,
              Self.isInputKind(command.commandKind) else {
            return unavailable(.inputFactUnavailable, command: command)
        }

        let state: CanonicalInputDeliveryState
        switch command.state {
        case .accepted:
            guard command.deliveryEventRef == nil,
                  command.deliveryActor == nil,
                  command.deliveryHostSequence == nil else {
                return unavailable(.deliveryEvidenceUnavailable, command: command)
            }
            state = .acceptedWaitingDelivery
        case .delivered:
            guard let delivery = command.deliveryEventRef,
                  delivery.journal == workJournal,
                  delivery != command.acceptanceEventRef,
                  command.deliveryActor != nil,
                  command.deliveryHostSequence != nil else {
                return unavailable(.deliveryEvidenceUnavailable, command: command)
            }
            state = .delivered
        case .notDelivered:
            guard let delivery = command.deliveryEventRef,
                  delivery.journal == workJournal,
                  delivery != command.acceptanceEventRef,
                  command.deliveryActor != nil,
                  command.deliveryHostSequence != nil else {
                return unavailable(.deliveryEvidenceUnavailable, command: command)
            }
            state = .notDelivered
        case .indeterminate:
            guard let delivery = command.deliveryEventRef,
                  delivery.journal == workJournal,
                  delivery != command.acceptanceEventRef,
                  command.deliveryActor != nil,
                  command.deliveryHostSequence != nil else {
                return unavailable(.deliveryEvidenceUnavailable, command: command)
            }
            state = .indeterminateUnknownEffect
        case .rejected: return unavailable(.missingAcceptance, command: command)
        }
        return CanonicalInputDeliveryRow(
            id: baseID, commandID: command.command.commandID, messageEvent: messageEvent,
            acceptanceEvent: command.acceptanceEventRef, deliveryEvent: command.deliveryEventRef,
            hostSequence: command.acceptanceHostSequence, client: message.client,
            sessionAttachment: message.sessionAttachment, run: message.run,
            commandKind: command.commandKind, deliveryMode: command.deliveryMode,
            state: state, issue: nil)
    }

    private static func order(_ lhs: CanonicalInputDeliveryRow, then rhs: CanonicalInputDeliveryRow) -> Bool {
        let left = lhs.hostSequence ?? Int.max
        let right = rhs.hostSequence ?? Int.max
        if left != right { return left < right }
        return lhs.id < rhs.id
    }

    private static func unavailable(
        _ row: CanonicalInputDeliveryRow, issue: CanonicalInputDeliveryIssue
    ) -> CanonicalInputDeliveryRow {
        CanonicalInputDeliveryRow(
            id: row.id, commandID: row.commandID, messageEvent: row.messageEvent,
            acceptanceEvent: row.acceptanceEvent, deliveryEvent: row.deliveryEvent,
            hostSequence: row.hostSequence, client: row.client,
            sessionAttachment: row.sessionAttachment, run: row.run,
            commandKind: row.commandKind, deliveryMode: row.deliveryMode,
            state: .provenanceUnavailable, issue: issue)
    }

    private static func orphanRow(
        command: WorkCommandSnapshot, work: WorkSnapshot,
        sessionRef: SessionRef, workJournal: JournalRef,
        acceptanceCounts: [EventRef: Int], commandIDCounts: [String: Int]
    ) -> CanonicalInputDeliveryRow? {
        // Attribute an orphan command to this Session only when Work still proves the exact
        // attachment relationship. Once attributed, preserve malformed/missing delivery facts as
        // an unavailable row instead of silently dropping an already host-owned command.
        guard let attachment = command.command.sessionAttachment,
              let attachmentFact = work.sessionAttachments[attachment.attachmentID],
              attachmentFact.session == sessionRef else { return nil }
        let acceptance = command.acceptanceEventRef
        let base = CanonicalInputDeliveryRow(
            id: acceptance.map { "command/\($0.journal.stableKey)/\($0.eventID)" }
                ?? "command/\(command.command.commandID)",
            commandID: command.command.commandID, messageEvent: nil,
            acceptanceEvent: acceptance, deliveryEvent: command.deliveryEventRef,
            hostSequence: command.acceptanceHostSequence, client: command.command.client,
            sessionAttachment: attachment, run: command.acceptanceRun,
            commandKind: command.commandKind, deliveryMode: command.deliveryMode,
            state: .provenanceUnavailable, issue: .missingSessionMessage)
        if command.carriesSessionInput == nil && command.commandKind == nil {
            return unavailable(base, issue: .commandKindUnavailable)
        }
        switch command.carriesSessionInput {
        case false: return nil
        case nil where command.commandKind != nil && !Self.isInputKind(command.commandKind): return nil
        default: break
        }
        guard command.carriesSessionInput == true else {
            return unavailable(base, issue: .inputFactUnavailable)
        }
        guard let acceptance else { return unavailable(base, issue: .missingAcceptance) }
        guard acceptance.journal == workJournal else {
            return unavailable(base, issue: .journalMismatch)
        }
        guard acceptanceCounts[acceptance] == 1,
              commandIDCounts[command.command.commandID] == 1 else {
            return unavailable(base, issue: .duplicateAcceptance)
        }
        guard command.command.client != nil else {
            return unavailable(base, issue: .clientMismatch)
        }
        guard command.acceptanceRun != nil else {
            return unavailable(base, issue: .runMismatch)
        }
        guard command.commandKind != nil else {
            return unavailable(base, issue: .commandKindUnavailable)
        }
        guard command.deliveryMode != nil else {
            return unavailable(base, issue: .deliveryModeUnavailable)
        }
        guard Self.isInputKind(command.commandKind) else {
            return unavailable(base, issue: .inputFactUnavailable)
        }
        let state: CanonicalInputDeliveryState
        switch command.state {
        case .accepted:
            guard command.deliveryEventRef == nil,
                  command.deliveryActor == nil,
                  command.deliveryHostSequence == nil else {
                return unavailable(base, issue: .deliveryEvidenceUnavailable)
            }
            state = .acceptedWaitingDelivery
        case .delivered:
            guard let delivery = command.deliveryEventRef,
                  delivery.journal == workJournal, delivery != acceptance,
                  command.deliveryActor != nil, command.deliveryHostSequence != nil else {
                return unavailable(base, issue: .deliveryEvidenceUnavailable)
            }
            state = .delivered
        case .notDelivered:
            guard let delivery = command.deliveryEventRef,
                  delivery.journal == workJournal, delivery != acceptance,
                  command.deliveryActor != nil, command.deliveryHostSequence != nil else {
                return unavailable(base, issue: .deliveryEvidenceUnavailable)
            }
            state = .notDelivered
        case .indeterminate:
            guard let delivery = command.deliveryEventRef,
                  delivery.journal == workJournal, delivery != acceptance,
                  command.deliveryActor != nil, command.deliveryHostSequence != nil else {
                return unavailable(base, issue: .deliveryEvidenceUnavailable)
            }
            state = .indeterminateUnknownEffect
        case .rejected: return nil
        }
        return CanonicalInputDeliveryRow(
            id: base.id,
            commandID: command.command.commandID, messageEvent: nil,
            acceptanceEvent: acceptance, deliveryEvent: command.deliveryEventRef,
            hostSequence: command.acceptanceHostSequence, client: command.command.client,
            sessionAttachment: attachment, run: command.acceptanceRun,
            commandKind: command.commandKind, deliveryMode: command.deliveryMode,
            state: state, issue: .missingSessionMessage)
    }

    private static func isInputKind(_ kind: CanonicalCommandKind?) -> Bool {
        guard let kind else { return false }
        switch kind {
        case .start, .send, .steer, .queue, .queueFollowUp: return true
        case .hold, .cancel, .end, .endRun, .destroy, .complete: return false
        }
    }

    private static func retentionPriority(_ row: CanonicalInputDeliveryRow) -> Int {
        switch row.state {
        case .acceptedWaitingDelivery: return 0
        case .indeterminateUnknownEffect: return 1
        case .provenanceUnavailable: return 2
        case .notDelivered where row.messageEvent == nil: return 2
        case .delivered, .notDelivered: return 3
        }
    }

    private static func retentionOrder(
        _ lhs: CanonicalInputDeliveryRow, then rhs: CanonicalInputDeliveryRow
    ) -> Bool {
        let leftPriority = retentionPriority(lhs)
        let rightPriority = retentionPriority(rhs)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        let leftSequence = lhs.hostSequence ?? Int.min
        let rightSequence = rhs.hostSequence ?? Int.min
        if leftPriority >= 3 && leftSequence != rightSequence { return leftSequence > rightSequence }
        return order(lhs, then: rhs)
    }

    private static func retain(
        _ row: CanonicalInputDeliveryRow,
        in rows: inout [CanonicalInputDeliveryRow], bound: Int,
        omittedRows: inout Int, omittedUnresolved: inout Int,
        omittedAttention: inout Int
    ) {
        guard bound > 0 else {
            omittedRows += 1
            if row.state == .acceptedWaitingDelivery { omittedUnresolved += 1 }
            if row.requiresPriorityRetention { omittedAttention += 1 }
            return
        }
        rows.append(row)
        rows.sort { retentionOrder($0, then: $1) }
        if rows.count > bound, let dropped = rows.popLast() {
            omittedRows += 1
            if dropped.state == .acceptedWaitingDelivery { omittedUnresolved += 1 }
            if dropped.requiresPriorityRetention { omittedAttention += 1 }
        }
    }

    private static func boundedOmissions(
        _ values: [WorkServiceOmission], reservedCategories: Set<String>
    ) -> [WorkServiceOmission] {
        var byCategory: [String: WorkServiceOmission] = [:]
        for value in values {
            if let existing = byCategory[value.category] {
                byCategory[value.category] = WorkServiceOmission(
                    category: value.category,
                    count: saturatedAdd(existing.count, value.count),
                    diagnostic: existing.diagnostic ?? value.diagnostic)
            } else { byCategory[value.category] = value }
        }
        let prioritized = byCategory.values.sorted { lhs, rhs in
            let lhsReserved = reservedCategories.contains(lhs.category)
            let rhsReserved = reservedCategories.contains(rhs.category)
            if lhsReserved != rhsReserved { return lhsReserved }
            return lhs.category < rhs.category
        }
        return prioritized.prefix(64).sorted { $0.category < $1.category }
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let left = max(0, lhs)
        let right = max(0, rhs)
        if left >= maximumOmissionCount || right >= maximumOmissionCount { return maximumOmissionCount }
        return min(maximumOmissionCount, left + right)
    }
}
