import Foundation

/// Provenance for one lexical Session search document.
public enum CanonicalSessionSearchSource: String, Codable, Hashable, Sendable {
    case canonical
    case companion
    case legacyCompatibility = "legacy_compatibility"
}

/// The palette's liveness projection keeps conversation lifecycle separate from running Work.
public enum CanonicalSessionLivenessProjection {
    public static func project(
        inProcess: Bool,
        source: CanonicalSessionSearchSource,
        summary: CanonicalSessionCatalogSummary?
    ) -> Bool? {
        if inProcess { return true }
        guard source != .legacyCompatibility else { return false }
        guard let summary,
              summary.sessionCursorAlignment == .exact,
              summary.sessionIntegrityValid == true,
              summary.sessionStructuralIntegrityValid,
              summary.sessionSemanticProjectionValid,
              !summary.unknownDomains.contains(.session),
              !summary.unknownDomains.contains(.work)
        else { return nil }
        let attached = summary.work.filter(\.isAttached)
        guard !attached.contains(where: { !$0.canProjectExecution }) else { return nil }
        return attached.contains {
            [.preparing, .running, .canceling].contains($0.execution)
        }
    }
}

/// One bounded lexical search document for one displayed Session row.
///
/// Native fields are populated only from an exact, integrity-valid Session read. A companion
/// never refills unknown native facts from its legacy transcript. This is intentionally a small
/// display projection, not a semantic index. Documents are ephemeral and are never persisted.
public struct CanonicalSessionSearchDocument: Hashable, Sendable, Identifiable {
    public let id: String
    /// The display/compatibility id used to select or open the row.
    public let actionTargetID: String
    public let source: CanonicalSessionSearchSource
    /// The injective JournalRef identity. It is exposed as a field, never searched as a blob.
    public private(set) var canonicalIdentity: String?
    public private(set) var authorityID: String?
    public private(set) var sessionID: String?
    public private(set) var journalID: String?
    public private(set) var localCompatibilityID: String?
    /// Journal-qualified provenance for the visible canonical messages retained in the document.
    public private(set) var sourceEventRefs: [EventRef]
    public private(set) var title: String?
    public private(set) var visibleConversation: String?
    public private(set) var lifecycle: SessionLifecycle?
    public private(set) var attention: SessionAttention?
    public private(set) var modelID: String?
    /// Lowercased matching text, bounded separately from the visible conversation.
    public private(set) var searchableText: String
    public private(set) var omittedConversationMessageCount: Int
    public private(set) var omittedConversationCharacterCount: Int
    public private(set) var omittedSearchCharacterCount: Int

    public static let maximumConversationMessages = 64
    public static let maximumConversationCharacters = 16_384
    public static let maximumSearchCharacters = 24_576
    public static let maximumQueryCharacters = 512
    public static let maximumTitleCharacters = 512
    public static let maximumModelCharacters = 512

    public var displayTitle: String { title ?? "Session details unknown" }

    public var displaySourceLabel: String {
        switch source {
        case .canonical: return "canonical"
        case .companion: return "native companion"
        case .legacyCompatibility: return "legacy compatibility"
        }
    }

    public var displaySubtitle: String {
        let state = lifecycle?.rawValue ?? "state unknown"
        let model = modelID ?? "model unknown"
        return "\(displaySourceLabel) · \(state) · \(model)"
    }

    public func matches(_ query: String) -> Bool {
        let normalized = String(query.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maximumQueryCharacters)).lowercased()
        guard !normalized.isEmpty else { return true }
        let identityComponents = [authorityID, sessionID, journalID, localCompatibilityID]
            .compactMap { $0?.lowercased() }
        if identityComponents.contains(where: {
            $0 == normalized || $0.hasPrefix(normalized)
        }) {
            return true
        }
        return searchableText.contains(normalized)
    }

    fileprivate init(entry: SessionCatalogProjection) {
        self.id = entry.id
        self.actionTargetID = entry.id
        self.canonicalIdentity = nil
        self.authorityID = nil
        self.sessionID = nil
        self.journalID = nil
        self.localCompatibilityID = nil
        self.sourceEventRefs = []
        self.title = nil
        self.visibleConversation = nil
        self.lifecycle = nil
        self.attention = nil
        self.modelID = nil
        self.searchableText = ""
        self.omittedConversationMessageCount = 0
        self.omittedConversationCharacterCount = 0
        self.omittedSearchCharacterCount = 0
        switch entry {
        case .legacy(let legacy):
            self.source = .legacyCompatibility
            self.canonicalIdentity = nil
            self.authorityID = nil
            self.sessionID = nil
            self.journalID = nil
            self.localCompatibilityID = legacy.summary.id
            let firstPromptProjection = PromptText.boundedUserFacing(
                legacy.summary.firstPrompt,
                maximumCharacters: Self.maximumConversationCharacters,
                fallbackToFirstInjectedBody: false)
            let firstPrompt = firstPromptProjection.text
            let lastAssistant = legacy.summary.lastAssistantText
            let legacyTitle = PromptText.boundedUserFacing(
                legacy.summary.title, maximumCharacters: Self.maximumTitleCharacters,
                fallbackToFirstInjectedBody: false)
            self.title = legacyTitle.text.isEmpty ? "Untitled session" : legacyTitle.text
            self.lifecycle = legacy.summary.sessionState.flatMap(SessionLifecycle.init(rawValue:))
            self.attention = nil
            let model = Self.boundedField(
                legacy.summary.model, maximumCharacters: Self.maximumModelCharacters)
            self.modelID = model.text
            let conversation = Self.boundedConversation([(firstPrompt, nil), (lastAssistant, nil)])
            self.visibleConversation = conversation.text
            self.omittedConversationMessageCount = conversation.omittedMessages
            self.omittedConversationCharacterCount = conversation.omittedCharacters
                + firstPromptProjection.omittedCharacterCount
            let search = Self.boundedSearch(components: [
                self.title, conversation.text, self.modelID,
            ])
            self.searchableText = search.text
            self.omittedSearchCharacterCount = search.omittedCharacters
                + self.omittedConversationCharacterCount
                + legacyTitle.omittedCharacterCount + model.omittedCharacters
        case .canonical(let canonical):
            self.source = .canonical
            self.assignNative(canonical)
        case .companion(let companion):
            self.source = .companion
            self.localCompatibilityID = companion.legacyID
            self.assignNative(companion.canonical)
        }
    }

    private mutating func assignNative(_ summary: CanonicalSessionCatalogSummary) {
        let proven = Self.nativeFactsProven(summary)
        // Owner and authority identity were established before a canonical summary could exist.
        // Keep those audit fields even when message/lifecycle facts fail closed.
        self.canonicalIdentity = summary.journal.stableKey
        self.authorityID = summary.journal.authority.authorityID
        self.sessionID = summary.session.sessionID
        self.journalID = summary.journal.journalID
        let title = Self.boundedField(
            summary.title, maximumCharacters: Self.maximumTitleCharacters)
        self.title = proven ? (title.text?.isEmpty == false ? title.text : "Untitled session") : nil
        self.lifecycle = proven ? summary.lifecycle : nil
        self.attention = proven ? summary.effectiveAttention : nil
        let model = Self.boundedField(
            summary.sessionModelID, maximumCharacters: Self.maximumModelCharacters)
        self.modelID = proven ? model.text : nil

        // Canonical visible conversation is explicitly user/assistant-only. Tool, context,
        // memory, artifact and raw/path material is never admitted to this lexical surface.
        let conversation = proven
            ? Self.boundedVisibleConversation(
                summary.visibleMessages, journal: summary.journal)
            : (text: nil, omittedMessages: 0, omittedCharacters: 0, eventRefs: [])
        self.visibleConversation = conversation.text
        self.omittedConversationMessageCount = conversation.omittedMessages
        self.omittedConversationCharacterCount = conversation.omittedCharacters
        self.sourceEventRefs = conversation.eventRefs
        let search = Self.boundedSearch(components: proven ? [
            self.title, conversation.text,
            summary.lifecycle.rawValue, summary.effectiveAttention?.rawValue,
            self.modelID,
        ] : [])
        self.searchableText = search.text
        self.omittedSearchCharacterCount = search.omittedCharacters
            + conversation.omittedCharacters
            + (proven ? title.omittedCharacters + model.omittedCharacters : 0)
    }

    private static func nativeFactsProven(_ summary: CanonicalSessionCatalogSummary) -> Bool {
        summary.sessionCursorAlignment == .exact
            && summary.sessionIntegrityValid == true
            && summary.sessionStructuralIntegrityValid
            && summary.sessionSemanticProjectionValid
            && !summary.unknownDomains.contains(.session)
    }

    private static func boundedConversation(_ values: [(String, EventRef?)]) -> (
        text: String?, omittedMessages: Int, omittedCharacters: Int, eventRefs: [EventRef]
    ) {
        var remaining = maximumConversationCharacters
        var text = ""
        var retainedMessages = 0
        var omittedMessages = 0
        var omittedCharacters = 0
        var eventRefs: [EventRef] = []
        for value in values where !value.0.isEmpty {
            guard retainedMessages < maximumConversationMessages else {
                omittedMessages += 1
                omittedCharacters += value.0.count
                continue
            }
            retainedMessages += 1
            if !text.isEmpty, remaining > 0 {
                text.append("\n")
                remaining -= 1
            }
            let characterCount = value.0.count
            let take = min(characterCount, remaining)
            if take > 0 { text.append(contentsOf: value.0.prefix(take)) }
            remaining -= take
            omittedCharacters += characterCount - take
            if take > 0, let ref = value.1 { eventRefs.append(ref) }
        }
        return (text.isEmpty ? nil : text, omittedMessages, omittedCharacters, eventRefs)
    }

    private static func boundedVisibleConversation(
        _ messages: [SessionMessageSnapshot], journal: JournalRef
    ) -> (text: String?, omittedMessages: Int, omittedCharacters: Int, eventRefs: [EventRef]) {
        var remaining = maximumConversationCharacters
        var text = ""
        var retainedMessages = 0
        var omittedMessages = 0
        var omittedCharacters = 0
        var eventRefs: [EventRef] = []
        eventRefs.reserveCapacity(min(messages.count, maximumConversationMessages))
        for message in messages
        where (message.role == "user" || message.role == "assistant") && !message.text.isEmpty {
            guard retainedMessages < maximumConversationMessages else {
                omittedMessages += 1
                omittedCharacters += message.text.count
                continue
            }
            retainedMessages += 1
            if !text.isEmpty, remaining > 0 {
                text.append("\n")
                remaining -= 1
            }
            let characterCount = message.text.count
            let take = min(characterCount, remaining)
            if take > 0 {
                text.append(contentsOf: message.text.prefix(take))
                eventRefs.append(EventRef(journal: journal, eventID: message.eventID))
            }
            remaining -= take
            omittedCharacters += characterCount - take
        }
        return (text.isEmpty ? nil : text, omittedMessages, omittedCharacters, eventRefs)
    }

    private static func boundedSearch(components: [String?]) -> (text: String, omittedCharacters: Int) {
        var text = ""
        var remaining = maximumSearchCharacters
        var omittedCharacters = 0
        for component in components.compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if !text.isEmpty, remaining > 0 {
                text.append(" ")
                remaining -= 1
            }
            let characterCount = component.count
            let take = min(characterCount, remaining)
            if take > 0 { text.append(contentsOf: component.prefix(take)) }
            remaining -= take
            omittedCharacters += characterCount - take
        }
        return (text.lowercased(), omittedCharacters)
    }

    private static func boundedField(
        _ value: String?, maximumCharacters: Int
    ) -> (text: String?, omittedCharacters: Int) {
        guard let value else { return (nil, 0) }
        let maximum = max(0, maximumCharacters)
        let count = value.count
        return (String(value.prefix(maximum)), max(0, count - maximum))
    }
}

/// Explicitly bounded compatibility search for legacy AgentTree rows. Native companions are
/// excluded by the caller; this adapter prevents injected context or artifact-sized prompts from
/// becoming invisible command-palette matches.
public struct LegacyAgentSearchDocument: Hashable, Sendable {
    public static let maximumNameCharacters = 256
    public static let maximumPromptCharacters = 4_096
    public static let maximumMetadataCharacters = 256

    public let displayName: String
    public let displaySubtitle: String
    public let userFacingPrompt: String
    private let searchableText: String

    public init(node: AgentNode) {
        let name = PromptText.boundedUserFacing(
            node.name, maximumCharacters: Self.maximumNameCharacters,
            fallbackToFirstInjectedBody: false).text
        displayName = name.isEmpty ? "Unnamed agent" : name
        let provider = node.provider.map { String($0.prefix(Self.maximumMetadataCharacters / 3)) }
        let model = node.model.map { String($0.prefix(Self.maximumMetadataCharacters / 3)) }
        let modelLabel: String
        switch (provider, model) {
        case (let provider?, let model?): modelLabel = "\(provider)/\(model)"
        case (nil, let model?): modelLabel = model
        case (let provider?, nil): modelLabel = provider
        default: modelLabel = "—"
        }
        let status = String(node.status.prefix(Self.maximumMetadataCharacters / 3))
        displaySubtitle = String("\(modelLabel) · \(status)"
            .prefix(Self.maximumMetadataCharacters))
        userFacingPrompt = PromptText.boundedUserFacing(
            node.prompt, maximumCharacters: Self.maximumPromptCharacters,
            fallbackToFirstInjectedBody: false).text
        searchableText = "\(displayName) \(userFacingPrompt)".lowercased()
    }

    public func matches(_ query: String) -> Bool {
        let normalized = String(query.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(CanonicalSessionSearchDocument.maximumQueryCharacters)).lowercased()
        return !normalized.isEmpty && searchableText.contains(normalized)
    }
}

/// A bounded deterministic index over conflict-free display-row projections. Duplicate display
/// IDs are withheld rather than selecting an arbitrary search target. The index is an ephemeral
/// refresh cache and has no persistence contract.
public struct CanonicalSessionSearchIndex: Hashable, Sendable {
    public static let maximumResultCount = 128
    public let documents: [CanonicalSessionSearchDocument]
    public let duplicateDocumentIDs: [String]
    public let duplicateCanonicalIdentities: [String]
    private let documentIndexes: [String: Int]

    public init(entries: [SessionCatalogProjection]) {
        let grouped = Dictionary(grouping: entries, by: \.id)
        let duplicates = grouped.compactMap { $0.value.count > 1 ? $0.key : nil }
        self.duplicateDocumentIDs = duplicates.sorted()
        let nativeIdentityCounts = Dictionary(grouping: entries.compactMap { entry -> String? in
            switch entry {
            case .canonical(let summary): return summary.journal.stableKey
            case .companion(let companion): return companion.canonical.journal.stableKey
            case .legacy: return nil
            }
        }, by: { $0 }).mapValues(\.count)
        let duplicateNativeIdentities = Set(nativeIdentityCounts.compactMap {
            $0.value > 1 ? $0.key : nil
        })
        self.duplicateCanonicalIdentities = duplicateNativeIdentities.sorted()
        let candidates = grouped.compactMap { _, values -> CanonicalSessionSearchDocument? in
            guard values.count == 1 else { return nil }
            let document = CanonicalSessionSearchDocument(entry: values[0])
            guard document.canonicalIdentity.map({ !duplicateNativeIdentities.contains($0) })
                ?? true
            else { return nil }
            return document
        }.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.source.rawValue < rhs.source.rawValue
        }
        self.documents = candidates
        self.documentIndexes = Dictionary(
            uniqueKeysWithValues: candidates.enumerated().map { ($0.element.actionTargetID, $0.offset) })
    }

    public func document(actionTargetID: String) -> CanonicalSessionSearchDocument? {
        guard let index = documentIndexes[actionTargetID] else { return nil }
        return documents[index]
    }

    public func matching(_ query: String, maxResults: Int = maximumResultCount)
        -> [CanonicalSessionSearchDocument]
    {
        let bounded = min(max(0, maxResults), Self.maximumResultCount)
        return Array(documents.lazy.filter { $0.matches(query) }.prefix(bounded))
    }
}
