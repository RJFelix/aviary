import Foundation

/// The result of reconstructing a native conversation from the durable journals.
///
/// This is intentionally separate from ``SessionResume``.  The latter is the compatibility
/// adapter for Prime-Agent's transcript format; this type only accepts the native, canonical
/// journal protocol and therefore can be honest about which state planes were actually rebuilt.
public struct NativeColdResumeResult: Sendable {
    /// Pinned instructions retained from the effective request. Integration must either reuse
    /// these or prove that its rebuilt instructions are identical before claiming parity.
    public let pinnedMessages: [ChatMessage]
    public let messages: [ChatMessage]
    /// The exact tool schemas retained with the effective request.
    public let tools: [ChatTool]
    public let modelID: String
    public let contextManifest: ContextManifest
    public let contextBoundary: EventRef
    public let sessionCursor: JournalCursor
    public let workCursor: JournalCursor
    /// The six state planes are always present.  In particular, a reconstructed conversation
    /// is not evidence that the Python namespace or an external effect survived.
    public let coverage: RecoveryCoverage
    public let caveats: [String]

    public init(
        pinnedMessages: [ChatMessage], messages: [ChatMessage], tools: [ChatTool],
        modelID: String, contextManifest: ContextManifest,
        contextBoundary: EventRef, sessionCursor: JournalCursor, workCursor: JournalCursor,
        coverage: RecoveryCoverage, caveats: [String] = []
    ) {
        self.pinnedMessages = pinnedMessages
        self.messages = messages
        self.tools = tools
        self.modelID = modelID
        self.contextManifest = contextManifest
        self.contextBoundary = contextBoundary
        self.sessionCursor = sessionCursor
        self.workCursor = workCursor
        self.coverage = coverage
        self.caveats = caveats
    }
}

public enum NativeColdResumeError: LocalizedError, Equatable, Sendable {
    case emptyJournal(JournalRef)
    case untailedJournal(JournalRef)
    case foreignJournal(JournalRef)
    case legacyRecord(JournalRef)
    case structurallyInvalid(JournalRef, String)
    case semanticallyInvalid(JournalRef, String)
    case noCompleteContextManifest
    case contextBoundaryMalformed
    case retainedBodyUnavailable(String)
    case retainedBodyNotMessage(String)
    case malformedMessageBody(String)
    case unreconstructableConversationTail(String)
    case workStateUnavailable(String)
    case compactionAfterContextBoundary

    public var errorDescription: String? {
        switch self {
        case .emptyJournal(let journal): return "Native journal is empty: " + journal.journalID + "."
        case .untailedJournal(let journal): return "Native journal has an uncommitted tail: " + journal.journalID + "."
        case .foreignJournal(let journal): return "Native read contains a foreign journal: " + journal.journalID + "."
        case .legacyRecord(let journal): return "Native resume cannot consume a legacy record: " + journal.journalID + "."
        case .structurallyInvalid(_, let reason): return "Native journal structure is invalid: " + reason + "."
        case .semanticallyInvalid(_, let reason): return "Native journal projection is invalid: " + reason + "."
        case .noCompleteContextManifest: return "No complete native context manifest is available for cold resume."
        case .contextBoundaryMalformed: return "The native context boundary is malformed."
        case .retainedBodyUnavailable(let id): return "A retained context body is unavailable: " + id + "."
        case .retainedBodyNotMessage(let id): return "A retained context body is not a canonical chat message: " + id + "."
        case .malformedMessageBody(let id): return "A retained context message is malformed: " + id + "."
        case .unreconstructableConversationTail(let id):
            return "A committed post-context conversation message cannot be reconstructed: " + id + "."
        case .workStateUnavailable(let reason): return "Native Work state cannot be resumed safely: " + reason + "."
        case .compactionAfterContextBoundary:
            return "The effective context changed after the recorded context boundary."
        }
    }
}

/// Native cold-resume reducer.  It reads already-parsed canonical journal results, so callers
/// can use it with a local file, a remote page, or a service cache.  The supplied read must be
/// exact: a stale, foreign, malformed, or tailed prefix is never treated as a successful resume.
public enum NativeColdResume {
    public static func resume(
        sessionRead: TimelineJournalReadResult,
        expectedSessionCursor: JournalCursor,
        workRead: TimelineJournalReadResult,
        expectedWorkCursor: JournalCursor,
        bodyStore: ContextBodyStore
    ) throws -> NativeColdResumeResult {
        let sessionJournal = try validateRead(sessionRead, expectedCursor: expectedSessionCursor)
        let sessionEvents = sessionRead.records.map(\.event)
        let sessionSnapshot = SessionReducer.reduce(sessionEvents)
        try validateSnapshot(sessionSnapshot, journal: sessionJournal)

        guard let manifest = sessionSnapshot.contextManifest else {
            throw NativeColdResumeError.noCompleteContextManifest
        }
        guard let boundaryEvent = sessionEvents.last(where: {
            $0.type == TimelineEventType.contextAssembled
                && $0.payload["manifest_id"]?.stringValue == manifest.manifestID
        }), let boundaryRun = boundaryEvent.run,
        let boundarySession = boundaryEvent.session,
        let boundaryWork = boundaryEvent.work,
        let boundaryWorkHost = boundaryEvent.workHost,
        let boundaryHostSequence = boundaryEvent.hostSequence,
        case .session(let sessionOwner) = sessionJournal.owner,
        sessionOwner == boundarySession,
        boundaryWork.workHostID == boundaryWorkHost.workHostID else {
            throw NativeColdResumeError.contextBoundaryMalformed
        }
        let boundary = EventRef(journal: sessionJournal, eventID: boundaryEvent.eventID)

        let reconstructed = try decodeManifest(manifest, bodyStore: bodyStore)
        let activeMessageIDs = Set(sessionSnapshot.messages.map(\.eventID))
        let activeSuffixEvents = sessionEvents.filter {
            $0.sequence > boundaryEvent.sequence && activeMessageIDs.contains($0.eventID)
                && ($0.type == TimelineEventType.inputAccepted
                    || $0.type == TimelineEventType.messageCommitted)
        }
        let suffixMessages = try decodeCommittedSuffix(
            sessionEvents.filter { $0.sequence > boundaryEvent.sequence },
            activeMessageIDs: activeMessageIDs, bodyStore: bodyStore)

        let caveats = [
            "the Python namespace, live Futures/Handles, and external effects are not reconstructed"
        ]
        let workJournal = try validateRead(workRead, expectedCursor: expectedWorkCursor)
            let workEvents = workRead.records.map(\.event)
            let workSnapshot = WorkReducer.reduce(workEvents)
            try validateSnapshot(workSnapshot, journal: workJournal)
            guard case .work(let workOwner) = workJournal.owner,
                  workOwner == boundaryWork,
                  workJournal.authority.authorityID == boundaryWork.workHostID else {
                throw NativeColdResumeError.workStateUnavailable("Work journal identity does not match the context boundary")
            }
            let sessionAttachments = sessionSnapshot.attachments.values.filter {
                $0.isAttached && $0.work == boundaryWork
            }
            guard sessionAttachments.count == 1,
                  let sessionAttachment = sessionAttachments.first,
                  sessionAttachment.cursor == expectedWorkCursor,
                  let workAttachment = workSnapshot.sessionAttachments[
                    sessionAttachment.attachment.attachmentID],
                  workAttachment.isAttached,
                  workAttachment.session == boundarySession else {
                throw NativeColdResumeError.workStateUnavailable(
                    "the Session/Work attachment does not prove the exact Work tip")
            }
            if workSnapshot.activeRun != nil || workSnapshot.activeTurn != nil
                || !workSnapshot.activeActionIDs.isEmpty {
                throw NativeColdResumeError.workStateUnavailable(
                    "the journal ends with an active Run, turn, or action")
            }
            if workSnapshot.commands.values.contains(where: { $0.state == .accepted }) {
                throw NativeColdResumeError.workStateUnavailable(
                    "an accepted command has no durable delivery outcome")
            }
            let runActionEvents = workEvents.filter {
                $0.run == boundaryRun && isActionEvent($0)
            }
            guard runActionEvents.allSatisfy({ $0.hostSequence != nil }) else {
                throw NativeColdResumeError.workStateUnavailable(
                    "the context Run contains action activity without host-order provenance")
            }
            let postBoundaryActivity = runActionEvents.filter {
                ($0.hostSequence ?? Int.min) > boundaryHostSequence
            }
            let boundaryIntents = postBoundaryActivity.filter {
                $0.type == TimelineEventType.actionIntent && $0.causedByEventID == boundary
            }
            guard boundaryIntents.count == 1,
                  let boundaryAction = boundaryIntents[0].action,
                  boundaryIntents[0].payload["metadata"]?.objectValue?["request_id"]?.stringValue
                    == manifest.requestID,
                  let crossingKind = boundaryIntents[0].payload["kind"]?.stringValue
                    .flatMap(ActionKind.init(rawValue:)) else {
                throw NativeColdResumeError.workStateUnavailable(
                    "the context boundary has no unique causally linked provider action")
            }
            guard crossingKind == .provider else {
                throw NativeColdResumeError.workStateUnavailable(
                    "the latest context manifest belongs to a compaction request, not the next conversation request")
            }
            let unexplainedActivity = postBoundaryActivity.filter {
                $0.action != boundaryAction
            }
            if !unexplainedActivity.isEmpty {
                throw NativeColdResumeError.workStateUnavailable(
                    "post-context action activity has no later effective context manifest")
            }
            let crossingEvents = postBoundaryActivity.filter { $0.action == boundaryAction }
            guard crossingEvents.count == 3,
                  let intent = crossingEvents.first(where: {
                    $0.type == TimelineEventType.actionIntent
                  }),
                  let started = crossingEvents.first(where: {
                    $0.type == TimelineEventType.actionStarted
                  }),
                  let outcome = crossingEvents.first(where: {
                    $0.type == TimelineEventType.actionOutcome
                  }),
                  started.causedByEventID == EventRef(
                    journal: workJournal, eventID: intent.eventID),
                  outcome.causedByEventID == EventRef(
                    journal: workJournal, eventID: started.eventID) else {
                throw NativeColdResumeError.workStateUnavailable(
                    "the context provider action chain is incomplete or has invalid causality")
            }
            guard let crossing = workSnapshot.actions[boundaryAction.actionID],
                  crossing.state.isTerminal else {
                throw NativeColdResumeError.workStateUnavailable(
                    "the context provider action has no terminal outcome")
            }
            if crossing.state == .succeeded,
               !activeSuffixEvents.contains(where: {
                   $0.type == TimelineEventType.messageCommitted
               }) {
                throw NativeColdResumeError.workStateUnavailable(
                    "the successful context provider action has no reconstructable assistant response")
            }

        guard !sessionEvents.contains(where: {
            $0.sequence > boundaryEvent.sequence && $0.type == TimelineEventType.compaction
        }) else {
            throw NativeColdResumeError.compactionAfterContextBoundary
        }

        let messages = reconstructed.history + suffixMessages
        try validateConversation(messages)
        return NativeColdResumeResult(
            pinnedMessages: reconstructed.pinned, messages: messages,
            tools: reconstructed.tools,
            modelID: manifest.modelID,
            contextManifest: manifest,
            contextBoundary: boundary,
            sessionCursor: expectedSessionCursor,
            workCursor: expectedWorkCursor,
            coverage: RecoveryCoverage(
                operation: .coldResume,
                planes: [
                    .timeline: .reconstructed,
                    .effectiveContext: .reconstructed,
                    .runtimeNamespace: .lost,
                    .backgroundWork: .lost,
                    .memoriesArtifactsRepository: .unknown,
                    .externalEffects: .unknown,
                ], evidence: boundary,
                evidenceCursor: expectedSessionCursor,
                caveats: caveats),
            caveats: caveats)
    }

    private static func validateRead(
        _ read: TimelineJournalReadResult, expectedCursor: JournalCursor
    ) throws -> JournalRef {
        guard let first = read.records.first else {
            throw NativeColdResumeError.emptyJournal(
                JournalRef.session(SessionRef("unknown"), authority: TimelineAuthorityRef("unknown")))
        }
        let journal = first.event.journal
        guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
            throw NativeColdResumeError.untailedJournal(journal)
        }
        guard read.records.allSatisfy({ $0.event.journal == journal }) else {
            throw NativeColdResumeError.foreignJournal(journal)
        }
        guard read.records.allSatisfy({ $0.event.provenance == .native }) else {
            throw NativeColdResumeError.legacyRecord(journal)
        }
        var previous: String?
        for (index, record) in read.records.enumerated() {
            guard record.event.sequence == index + 1,
                  record.event.previousEventID == previous else {
                throw NativeColdResumeError.structurallyInvalid(
                    journal, "the read is not an exact contiguous append chain")
            }
            previous = record.event.eventID
        }
        guard let tip = read.records.last?.event,
              expectedCursor.journal == journal,
              expectedCursor.sequence == tip.sequence,
              expectedCursor.eventID == tip.eventID else {
            throw NativeColdResumeError.structurallyInvalid(
                journal, "the read tip does not match the expected durable cursor")
        }
        return journal
    }

    private static func validateSnapshot<T>(_ snapshot: T, journal: JournalRef) throws {
        let structural: Bool
        let semantic: Bool
        let reasons: [String]
        switch snapshot {
        case let value as SessionSnapshot:
            structural = value.structuralIntegrityValid; semantic = value.semanticProjectionValid
            reasons = value.corruptionReasons
        case let value as WorkSnapshot:
            structural = value.structuralIntegrityValid; semantic = value.semanticProjectionValid
            reasons = value.corruptionReasons
        default:
            return
        }
        guard structural else {
            throw NativeColdResumeError.structurallyInvalid(journal, reasons.joined(separator: "; "))
        }
        guard semantic else {
            throw NativeColdResumeError.semanticallyInvalid(journal, reasons.joined(separator: "; "))
        }
    }

    private static func decodeManifest(
        _ manifest: ContextManifest, bodyStore: ContextBodyStore
    ) throws -> (pinned: [ChatMessage], history: [ChatMessage], tools: [ChatTool]) {
        var pinned: [ChatMessage] = []
        var history: [ChatMessage] = []
        var tools: [ChatTool] = []
        var sawToolManifest = false
        for component in manifest.components {
            guard let reference = component.bodyReference else {
                throw NativeColdResumeError.retainedBodyUnavailable(component.inclusionID)
            }
            let data: Data
            do { data = try bodyStore.read(reference) }
            catch { throw NativeColdResumeError.retainedBodyUnavailable(component.inclusionID) }
            switch reference.mediaType {
            case "application/vnd.aviary.chat-message+json":
                let message = try decodeMessage(data, identity: component.inclusionID)
                let filtered = message.content.filter {
                    if case .thinking = $0 { return false }
                    return true
                }
                let replayable = ChatMessage(role: message.role, content: filtered)
                if message.role == .system {
                    guard component.mode == .pinned else {
                        throw NativeColdResumeError.malformedMessageBody(component.inclusionID)
                    }
                    if !filtered.isEmpty { pinned.append(replayable) }
                } else {
                    guard component.mode == .history else {
                        throw NativeColdResumeError.malformedMessageBody(component.inclusionID)
                    }
                    if !filtered.isEmpty { history.append(replayable) }
                }
            case "application/vnd.aviary.tool-schema-manifest+json":
                guard component.mode == .instruction, !sawToolManifest else {
                    throw NativeColdResumeError.retainedBodyNotMessage(component.inclusionID)
                }
                tools = try decodeTools(data, identity: component.inclusionID)
                sawToolManifest = true
            default:
                throw NativeColdResumeError.retainedBodyNotMessage(component.inclusionID)
            }
        }
        return (pinned, history, tools)
    }

    private static func decodeTools(_ data: Data, identity: String) throws -> [ChatTool] {
        guard let values = JSONValue.parse(data)?.arrayValue else {
            throw NativeColdResumeError.retainedBodyNotMessage(identity)
        }
        return try values.map { value in
            guard let object = value.objectValue,
                  let name = object["name"]?.stringValue,
                  let description = object["description"]?.stringValue,
                  let parameters = object["parameters"],
                  !name.isEmpty else {
                throw NativeColdResumeError.retainedBodyNotMessage(identity)
            }
            return ChatTool(name: name, description: description, parameters: parameters)
        }
    }

    private static func decodeCommittedSuffix(
        _ events: [TimelineEvent], activeMessageIDs: Set<String>, bodyStore: ContextBodyStore
    ) throws -> [ChatMessage] {
        var result: [ChatMessage] = []
        for event in events where
            event.type == TimelineEventType.inputAccepted || event.type == TimelineEventType.messageCommitted {
            // A message on a discarded branch is not part of the effective conversation and
            // must not force us to reconstruct bytes that the user cannot see.
            guard activeMessageIDs.contains(event.eventID) else { continue }
            let message: ChatMessage
            if let value = event.payload["message_body_ref"] ?? event.payload["body_ref"] {
                guard let reference: TimelineBodyReference = decodeNativeTimelineValue(value),
                      reference.authority == event.journal else {
                    throw NativeColdResumeError.unreconstructableConversationTail(event.eventID)
                }
                let data: Data
                do { data = try bodyStore.read(reference) }
                catch { throw NativeColdResumeError.retainedBodyUnavailable(event.eventID) }
                message = try decodeMessage(data, identity: event.eventID)
            } else {
                // Native v2 initially recorded text-only committed messages.  That shape is
                // still exact for user input. An assistant text event cannot prove that the
                // provider response contained no tool calls, so it must carry the retained
                // structured body before cold resume may accept it.
                guard event.type == TimelineEventType.inputAccepted else {
                    throw NativeColdResumeError.unreconstructableConversationTail(event.eventID)
                }
                guard let text = event.payload["text"]?.stringValue,
                      let roleRaw = event.payload["role"]?.stringValue,
                      let role = ChatRole(rawValue: roleRaw),
                      role == .user || role == .assistant,
                      event.payload["tool_calls"] == nil,
                      event.payload["images"] == nil else {
                    throw NativeColdResumeError.unreconstructableConversationTail(event.eventID)
                }
                message = ChatMessage(role: role, content: [.text(text)])
            }
            if message.role == .system { continue }
            let expectedRole = event.type == TimelineEventType.inputAccepted ? ChatRole.user : nil
            if let expectedRole, message.role != expectedRole {
                throw NativeColdResumeError.malformedMessageBody(event.eventID)
            }
            let filtered = message.content.filter { if case .thinking = $0 { return false }; return true }
            if !filtered.isEmpty { result.append(ChatMessage(role: message.role, content: filtered)) }
        }
        return result
    }

    private static func isActionEvent(_ event: TimelineEvent) -> Bool {
        event.type == TimelineEventType.actionIntent
            || event.type == TimelineEventType.actionStarted
            || event.type == TimelineEventType.actionOutcome
    }

    /// The provider must never receive an orphaned result or an unanswered call manufactured by
    /// a suffix that was never itself sent. A manifest body was already provider-accepted; only
    /// the post-boundary additions need this final whole-conversation check.
    private static func validateConversation(_ messages: [ChatMessage]) throws {
        var pending: [String: String] = [:]
        for message in messages {
            for content in message.content {
                switch content {
                case .toolCall(let id, let name, _):
                    guard pending[id] == nil else {
                        throw NativeColdResumeError.unreconstructableConversationTail(id)
                    }
                    pending[id] = name
                case .toolResult(let id, let name, _, _):
                    guard pending[id] == name else {
                        throw NativeColdResumeError.unreconstructableConversationTail(id)
                    }
                    pending.removeValue(forKey: id)
                case .text, .thinking, .image:
                    break
                }
            }
        }
        if let first = pending.keys.sorted().first {
            throw NativeColdResumeError.unreconstructableConversationTail(first)
        }
    }

    private static func decodeMessage(_ data: Data, identity: String) throws -> ChatMessage {
        guard let value = JSONValue.parse(data), let object = value.objectValue,
              let roleRaw = object["role"]?.stringValue,
              let role = ChatRole(rawValue: roleRaw),
              let contentValues = object["content"]?.arrayValue else {
            throw NativeColdResumeError.malformedMessageBody(identity)
        }
        var content: [ChatContent] = []
        for item in contentValues {
            guard let object = item.objectValue, let type = object["type"]?.stringValue else {
                throw NativeColdResumeError.malformedMessageBody(identity)
            }
            switch type {
            case "text":
                guard let text = object["text"]?.stringValue else { throw NativeColdResumeError.malformedMessageBody(identity) }
                content.append(.text(text))
            case "thinking":
                guard let text = object["text"]?.stringValue else { throw NativeColdResumeError.malformedMessageBody(identity) }
                content.append(.thinking(text))
            case "tool_call":
                guard let id = object["id"]?.stringValue, let name = object["name"]?.stringValue,
                      let arguments = object["arguments"] else { throw NativeColdResumeError.malformedMessageBody(identity) }
                content.append(.toolCall(id: id, name: name, arguments: arguments))
            case "tool_result":
                guard let id = object["id"]?.stringValue, let name = object["name"]?.stringValue,
                      let text = object["text"]?.stringValue, let isError = object["is_error"]?.boolValue else {
                    throw NativeColdResumeError.malformedMessageBody(identity)
                }
                content.append(.toolResult(id: id, name: name, text: text, isError: isError))
            case "image":
                guard let mimeType = object["mime_type"]?.stringValue,
                      let base64 = object["base64"]?.stringValue else { throw NativeColdResumeError.malformedMessageBody(identity) }
                content.append(.image(mimeType: mimeType, base64: base64))
            default:
                throw NativeColdResumeError.malformedMessageBody(identity)
            }
        }
        return ChatMessage(role: role, content: content)
    }

    private static func decodeNativeTimelineValue<T: Decodable>(_ value: JSONValue) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
