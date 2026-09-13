import SwiftUI
import Foundation
import AviaryCore

/// Deterministic, in-memory scenes used by the screenshot harness.
///
/// These scenes are deliberately not a persistence fixture and never touch `~/.aviary`. They
/// exercise the same dense surfaces a person uses while following durable Work: a canonical
/// Session, two GUI attachments, one active action, and a draft whose service crossing needs
/// explicit reconciliation after a GUI handoff.
enum VisualFixtureRoute: String {
    case cockpit = "cockpit-fixture"
    case serviceChat = "service-chat-fixture"
    case serviceChatNarrow = "service-chat-narrow-fixture"
    case productionDelivery = "production-delivery-fixture"
    case productionDeliveryNarrow = "production-delivery-narrow-fixture"
    case productionInspectorNarrow = "production-inspector-narrow-fixture"
    case conversationHistory = "conversation-history-fixture"
    case conversationHistoryNarrow = "conversation-history-narrow-fixture"
    case repositoryReview = "repository-review-fixture"
    case repositoryReviewNarrow = "repository-review-narrow-fixture"
    case repositoryReviewStale = "repository-review-stale-fixture"
    case repositoryReviewFeedbackNearFull = "repository-review-feedback-near-full-fixture"
    case repositoryReviewFeedbackFull = "repository-review-feedback-full-fixture"
    case projectReconfirmation = "project-reconfirmation-fixture"
    case activityOverview = "activity-overview-fixture"
    case activityOverviewNarrow = "activity-overview-narrow-fixture"
    case activityOverviewStale = "activity-overview-stale-fixture"
    case diagnostics = "diagnostics-fixture"
    case usageAccounting = "usage-accounting-fixture"
    case usageInventory = "usage-inventory-fixture"
    case usageInventoryNarrow = "usage-inventory-narrow-fixture"
    case chatWelcome = "chat-welcome-fixture"
    case chatRecovery = "chat-recovery-fixture"
    case chatUncertain = "chat-uncertain-fixture"
    case chatCreated = "chat-created-fixture"
    case requestLocations = "request-locations-fixture"
    case activityStrip = "activity-strip-fixture"

    var isNarrow: Bool {
        self == .serviceChatNarrow || self == .productionDeliveryNarrow
            || self == .productionInspectorNarrow
            || self == .conversationHistoryNarrow
            || self == .repositoryReviewNarrow
            || self == .activityOverviewNarrow
            || self == .usageInventoryNarrow
    }
}

struct VisualFixtureView: View {
    let route: VisualFixtureRoute

    var body: some View {
        switch route {
        case .cockpit:
            FixtureCockpitView()
        case .serviceChat, .serviceChatNarrow:
            FixtureServiceConversationView(narrow: route.isNarrow)
        case .productionDelivery, .productionDeliveryNarrow:
            ProductionRunPaneFixture(narrow: route.isNarrow)
        case .productionInspectorNarrow:
            ProductionInspectorFixture()
        case .conversationHistory, .conversationHistoryNarrow:
            ConversationHistoryFixture(narrow: route.isNarrow)
        case .repositoryReview, .repositoryReviewNarrow:
            RepositoryReviewFixtureView(narrow: route.isNarrow)
        case .repositoryReviewStale:
            RepositoryReviewStaleFixtureView()
        case .repositoryReviewFeedbackNearFull:
            RepositoryReviewFeedbackFixtureView(draftCount: 3_995)
        case .repositoryReviewFeedbackFull:
            RepositoryReviewFeedbackFixtureView(draftCount: 4_000)
        case .projectReconfirmation:
            ProjectReconfirmationSheet(initialDirectory: "", prepare: { _ in
                throw WorkHostWorkspaceRegistryError.workspaceNotFound
            }, confirm: { _ in .confirmedNeedsRefresh })
                .background(Color(nsColor: .windowBackgroundColor))
        case .activityOverview, .activityOverviewNarrow, .activityOverviewStale:
            ActivityOverviewFixture(isCurrent: route != .activityOverviewStale)
        case .diagnostics:
            DiagnosticsFixture()
        case .usageAccounting:
            UsageAccountingFixture()
        case .usageInventory, .usageInventoryNarrow:
            UsageInventoryFixtureView(narrow: route == .usageInventoryNarrow)
        case .chatWelcome, .chatRecovery, .chatUncertain, .chatCreated:
            ChatVisualLearningFixture(route: route)
        case .requestLocations:
            VStack(alignment: .leading, spacing: 28) {
                Text("Saved request states · design fixture").font(.headline)
                ForEach(PendingChatPhase.allCases, id: \.self) { phase in
                    SavedRequestProgress(state: .init(
                        phase: phase, isPreparing: false, conversationCreated: false))
                }
                SavedRequestProgress(state: .init(
                    phase: .preparing, isPreparing: true, conversationCreated: false))
                SavedRequestProgress(state: .init(
                    phase: .saved, isPreparing: true, conversationCreated: false))
                SavedRequestProgress(state: .init(
                    phase: .awaitingAcceptance, isPreparing: false, conversationCreated: true))
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        case .activityStrip:
            VStack(alignment: .leading, spacing: 20) {
                Text("Activity strip · production component fixture").font(.headline).padding(.horizontal, 16)
                WorkActivityStrip(action: WorkActionPresentation(FixtureData.activeAction),
                    concurrentActions: [WorkActionPresentation(FixtureData.activeAction)], onInspect: { _ in })
                WorkActivityStrip(action: WorkActionPresentation(FixtureData.activeAction),
                    concurrentActions: FixtureData.actions.map(WorkActionPresentation.init), onInspect: { _ in })
                WorkActivityStrip(action: WorkActionPresentation(FixtureData.activeAction),
                    concurrentActions: [WorkActionPresentation(FixtureData.activeAction)],
                    sourceIsCurrent: false, onInspect: { _ in })
            }.padding(.vertical, 20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

/// Real chat views with only disposable, local presentation data. No bootstrap or delivery.
@MainActor
private struct ChatVisualLearningFixture: View {
    let route: VisualFixtureRoute
    @State private var model: AppModel

    init(route: VisualFixtureRoute) {
        self.route = route
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aviary-chat-design-" + UUID().uuidString)
        let suite = "aviary.chat-design." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(home: AgentHome(root: root), presentationDefaults: defaults,
                             modelPreferencesStore: ModelPreferencesStore(directory: root))
        defer { try? FileManager.default.removeItem(at: root) }
        model.modelCatalog.enabled = [ModelSpec(rpc: .object([
            "id": .string("design-model"), "name": .string("Coding agent"),
            "provider": .string("Fixture provider"), "contextWindow": .number(128_000)]))]
        model.localWorkServiceError = route == .chatWelcome ? nil : "The agent service is unavailable."
        model.newChatRequested = route == .chatWelcome
        if route != .chatWelcome {
            let chat = try! PendingChat(
                id: UUID(uuidString: "27C7620E-5160-4946-8A34-E8AD10A64D17")!,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                prompt: "Help me understand how this project fits together, then suggest the smallest useful improvement.",
                cwd: "/Projects/Aviary", providerID: "Fixture provider", modelID: "design-model",
                phase: route == .chatUncertain || route == .chatCreated ? .awaitingAcceptance : .blocked,
                failureKind: .hostUnavailable,
                createdAssociation: route == .chatCreated ? ServiceAttachmentKey(
                    client: ClientRef("fixture-client"),
                    clientAttachment: ClientAttachmentRef("fixture-client-attachment"),
                    work: FixtureData.work, session: FixtureData.session,
                    sessionJournal: FixtureData.sessionJournal,
                    sessionAttachment: FixtureData.attachment) : nil)
            model.pendingChats = [chat]
            model.selectedPendingChatID = chat.id
        }
        _model = State(initialValue: model)
    }

    var body: some View {
        CockpitView().environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Presentation-only Work usage scenes. These are deliberately not built through Core's
/// authenticated inventory initializer; they make the complete and incomplete child-fact
/// states easy to inspect without touching a Work Host or a user's stored transcripts.
struct ServiceWorkUsageInventoryFixture {
    let direct: CanonicalWorkUsage?
    let directAvailability: CanonicalWorkUsageInventory.DirectAvailability
    let childrenTotal: CanonicalWorkUsage?
    let childCount: Int
    let omittedChildCount: Int
    let invalidChildCount: Int
    let combined: CanonicalWorkUsage?
    let combinedAvailability: CanonicalWorkUsageInventory.CombinedAvailability

    static let wide = ServiceWorkUsageInventoryFixture(
        direct: usage(
            started: 11, settled: 10,
            unresolved: .init(total: 1, breakdown: 1, cost: 1),
            input: 36_000, output: 12_000, cacheRead: 4_000, total: 52_000, cost: 0.87),
        directAvailability: .complete,
        childrenTotal: usage(
            started: 4, settled: 3,
            unresolved: .init(total: 1, breakdown: 1, cost: 1),
            input: 14_000, output: 5_000, cacheRead: 1_000, total: 20_000, cost: 0.31),
        childCount: 2,
        omittedChildCount: 0,
        invalidChildCount: 0,
        combined: usage(
            started: 15, settled: 13,
            unresolved: .init(total: 2, breakdown: 2, cost: 2),
            input: 50_000, output: 17_000, cacheRead: 5_000, total: 72_000, cost: 1.18),
        combinedAvailability: .complete)

    static let narrow = ServiceWorkUsageInventoryFixture(
        direct: usage(
            started: 5, settled: 4,
            unresolved: .init(total: 1, breakdown: 1, cost: 1),
            input: 8_000, output: 2_000, cacheRead: 1_000, total: 11_000, cost: 0.19),
        directAvailability: .complete,
        childrenTotal: nil,
        childCount: 1,
        omittedChildCount: 2,
        invalidChildCount: 0,
        combined: nil,
        combinedAvailability: .childFactsOmitted)

    private static func usage(
        started: Int,
        settled: Int,
        unresolved: ProviderUsageAggregate.UnresolvedCounts,
        input: Int,
        output: Int,
        cacheRead: Int,
        total: Int,
        cost: Double
    ) -> CanonicalWorkUsage {
        CanonicalWorkUsage(aggregate: ProviderUsageAggregate(
            started: started,
            settled: settled,
            unresolved: unresolved,
            knownFloors: .init(
                inputTokens: input, outputTokens: output,
                cacheReadTokens: cacheRead, totalTokens: total, cost: cost)))
    }
}

private struct UsageInventoryFixtureView: View {
    let narrow: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(narrow ? "Work-wide usage · incomplete child facts" : "Work-wide usage · complete inventory")
                    .font(.system(size: 13, weight: .semibold))
                Text(narrow
                    ? "Fixture: the Main agent subtotal stays visible while missing Background agent facts withhold a combined total."
                    : "Fixture: a canonical Work total is split into Main agent and Background agents subtotals before the combined view.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ServiceWorkUsageInventoryCard(
                    fixture: narrow
                        ? ServiceWorkUsageInventoryFixture.narrow
                        : ServiceWorkUsageInventoryFixture.wide)
            }
            .padding(16)
        }
        .frame(minWidth: narrow ? 0 : 560, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Production analytics over disposable fixture records: complete, partial, unclassified,
/// and absent reports. No user transcript, provider, or Work service is opened.
private struct UsageAccountingFixture: View {
    @State private var model: AppModel = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aviary-usage-fixture-" + UUID().uuidString)
        let suite = "aviary.usage-fixture." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("The isolated usage fixture preferences could not be constructed")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(home: AgentHome(root: root), presentationDefaults: defaults,
            modelPreferencesStore: ModelPreferencesStore(directory: root))
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let priced = ModelSpec(rpc: .object([
                "id": .string("Fixture model"), "provider": .string("Fixture provider"),
                "cost": .object(["input": .number(2), "output": .number(4),
                    "cacheRead": .number(0.2), "cacheWrite": .number(3)])]))
            let complete = Usage(finality: .finalReport, accounted: ProviderUsage.account(report: .init(
                inputTokens: 2_000, outputTokens: 300, cacheReadTokens: 1_000,
                cacheWriteTokens: 0, inputAccounting: .cacheInclusive), model: priced))
            let partial = Usage(finality: .finalReport, accounted: ProviderUsage.account(report: .init(
                inputTokens: 3_000, outputTokens: 500,
                inputAccounting: .cacheInclusive), model: priced))
            let imported = Usage(json: .object(["input": .number(2_000_000),
                "output": .number(500_000), "totalTokens": .number(2_500_000),
                "cost": .object(["total": .number(12.35)])]))
            let missing = Usage(finality: .finalReport, accounted: ProviderUsage.account(report: nil, model: priced))
            let stamp = ISO8601DateFormatter().string(from: Date())
            for (index, usage) in [complete, partial, imported, missing].enumerated() {
                let names = ["Complete report", "Partial report", "Recorded import", "Missing report"]
                let usageValue = JSONValue.parse(try JSONEncoder().encode(usage)) ?? .null
                let lines: [JSONValue] = [
                    .object(["type": .string("session"), "id": .string("usage-\(index)"),
                        "cwd": .string("/fixture/accounting"), "timestamp": .string(stamp)]),
                    .object(["type": .string("session_info"), "name": .string(names[index])]),
                    .object(["type": .string("message"), "timestamp": .string(stamp),
                        "message": .object(["role": .string("assistant"),
                            "model": .string(names[index]), "provider": .string("Fixture provider"),
                            "usage": usageValue, "content": .array([])])]),
                ]
                var bytes = Data()
                for line in lines { bytes.append(try JSONEncoder().encode(line)); bytes.append(10) }
                let path = root.appendingPathComponent("usage-\(index).jsonl")
                try bytes.write(to: path)
                if var summary = SessionCatalog.summarize(fileURL: path) {
                    summary.updatedAt = Date()
                    model.sessions.append(summary)
                }
            }
            model.analytics = UsageAnalytics.build(from: model.sessions)
        } catch {
            preconditionFailure("The isolated usage fixture could not be constructed")
        }
        return model
    }()

    var body: some View {
        UsageView().environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Production diagnostics without bootstrapping, connecting to, or changing a user's service.
private struct DiagnosticsFixture: View {
    @State private var model: AppModel = {
        let model = AppModel()
        model.home = AgentHome(root: URL(fileURLWithPath: "/tmp/aviary-diagnostics-fixture"))
        return model
    }()

    var body: some View {
        HealthView().environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ActivityOverviewFixture: View {
    let isCurrent: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agent activity").font(.headline).padding(16)
            Divider()
            ScrollView {
                ChatActivityContent(
                    activity: ChatActivityPresentation(
                        actions: WorkActionPresentation.project(FixtureData.activityOverviewActions),
                        sourceIsComplete: isCurrent),
                    children: ChatChildActivityPresentation(
                        workingState: FixtureData.inspectorProjections.working,
                        sourceIsCurrent: isCurrent),
                    agentHandles: ChatAgentHandleActivityPresentation(
                        workingState: FixtureData.inspectorProjections.working,
                        sourceIsCurrent: isCurrent))
                    .padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The production repository review sheet content, with an in-memory bounded artifact so the
/// wide and narrow fixture routes are deterministic and do not need a Work Host.
private struct RepositoryReviewFixtureView: View {
    let narrow: Bool

    var body: some View {
        RepositoryReviewView(
            fixtureReview: FixtureData.repositoryReview,
            fixtureDescriptor: FixtureData.repositoryReviewDescriptor)
            .frame(minWidth: narrow ? 0 : 560, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The production failure/retry copy for a descriptor that changed while its body was open.
private struct RepositoryReviewStaleFixtureView: View {
    var body: some View {
        RepositoryReviewView(fixtureError: .unavailable, allowsRetry: true)
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Near-full and full composer bounds exercise the exact remaining-capacity copy without
/// sending anything or depending on a service attachment.
private struct RepositoryReviewFeedbackFixtureView: View {
    let draftCount: Int

    var body: some View {
        RepositoryReviewView(
            fixtureReview: FixtureData.repositoryReview,
            fixtureDraft: String(repeating: "d", count: draftCount))
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The production transcript surface in an explicitly partial history state: earlier rows are
/// available above, newer canonical rows exist beyond this GUI's bounded window, and neither
/// condition is confused with command delivery or Work lifecycle.
private struct ConversationHistoryFixture: View {
    let narrow: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(Design.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversation history")
                        .font(.system(size: 13, weight: .semibold))
                    Text("This GUI is browsing a bounded canonical window")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Design.gutter)
            Divider()
            TranscriptView(
                items: FixtureData.historyTranscript,
                hideThinking: false,
                isStreaming: false,
                autoScroll: false,
                hasEarlierHistory: true,
                hasNewerHistory: true,
                onLoadEarlierHistory: {},
                onJumpToLatestHistory: {})
        }
        .frame(minWidth: narrow ? 0 : 560, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Paged canonical conversation history fixture")
    }
}

/// The same inspector presented by Cockpit's Context and Working State button, rendered at the
/// narrow-sheet width so its disclosure rows and six-plane recovery matrix stay reviewable.
@MainActor
private struct ProductionInspectorFixture: View {
    @State private var selectedItem: TranscriptItem?
    private let model: AppModel
    private let run: LiveRun

    init() {
        let model = AppModel()
        let run = LiveRun.productionRunPaneVisualFixture(
            items: FixtureData.productionTranscriptNarrow,
            pendingInputs: [FixtureData.waitingInput],
            deliveryAttention: [FixtureData.uncertainInput],
            actions: FixtureData.actions.map(WorkActionPresentation.init),
            recordedModelContext: FixtureData.inspectorProjections.context,
            canonicalWorkingState: FixtureData.inspectorProjections.working,
            draft: "Check the current runtime namespace, then queue a separate summary for review.")
        model.runs = [run]
        model.focusedRunID = run.id
        self.model = model
        self.run = run
    }

    var body: some View {
        RunInspector(run: run, selectedItem: $selectedItem)
            .environment(model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Cockpit run context and working state sheet")
    }
}

private enum FixtureData {
    static let host = WorkHostRef("host-linux-01")
    static let work = WorkRef(workHostID: host.workHostID, workID: "work-research-042")
    static let session = SessionRef("session-aviary-042")
    static let workJournal = JournalRef.work(work)
    static let sessionJournal = JournalRef.session(
        session, authority: TimelineAuthorityRef(host.workHostID))
    static let attachment = SessionAttachmentRef("session-attachment-042")
    static let run = RunRef("run-20260906-01")
    static let turn = TurnRef("turn-07")
    static let actor = TimelineActor(actorID: "work-host-linux-01", kind: "work-host")
    static let baseTime = Date(timeIntervalSince1970: 1_757_136_000)

    static let historyTranscript: [TranscriptItem] = (0..<18).map { index in
        var item = TranscriptItem(
            id: "fixture-history-\(index)",
            kind: index.isMultiple(of: 2) ? .user : .assistant,
            timestamp: baseTime.addingTimeInterval(TimeInterval(index * 24)))
        item.text = index.isMultiple(of: 2)
            ? "Review checkpoint \(index / 2 + 1) and preserve my place while earlier history loads."
            : "Checkpoint \(index / 2 + 1) is recorded. The next page can prepend without moving this row."
        item.blocks = [.text(item.text)]
        item.model = "claude-sonnet-4-5"
        return item
    }

    static func observation(_ id: String, sequence: Int, offset: TimeInterval) -> WorkActionObservation {
        WorkActionObservation(
            sourceEvent: EventRef(journal: workJournal, eventID: id),
            sequence: sequence,
            hostSequence: sequence,
            run: run,
            turn: turn,
            actor: actor,
            hostRecordedAt: baseTime.addingTimeInterval(offset),
            clientTimestamp: baseTime.addingTimeInterval(offset + 0.3),
            provenance: .native)
    }

    static let activeAction = WorkActionSnapshot(
        action: ActionRef("action-python-inspect-001"),
        state: .running,
        kind: .python,
        intent: "Inspect the repository and verify the remote Work Host state",
        target: "workspace /aviary · branch core-experience",
        scope: "turn",
        metadata: ["phase": .string("read-only verification")],
        intentEvent: observation("event-action-intent-001", sequence: 18, offset: 42),
        startedEvent: observation("event-action-started-001", sequence: 19, offset: 43))

    static let completedAction = WorkActionSnapshot(
        action: ActionRef("action-search-000"),
        state: .succeeded,
        retrySafety: .idempotent,
        kind: .webSearch,
        intent: "Find the latest transport notes",
        target: "Aviary transport notes",
        scope: "turn",
        intentEvent: observation("event-action-intent-000", sequence: 11, offset: 8),
        startedEvent: observation("event-action-started-000", sequence: 12, offset: 9),
        outcomeEvent: observation("event-action-outcome-000", sequence: 13, offset: 14))

    static let actions = [activeAction, completedAction]
    static let activityOverviewActions = actions + [
        WorkActionSnapshot(
            action: ActionRef("activity-failed-search"), state: .failed,
            failureKind: .timeout, retrySafety: .unknown, kind: .webSearch,
            intent: "Look up the provider's retry behavior",
            startedEvent: observation("activity-failed-start", sequence: 14, offset: 15),
            outcomeEvent: observation("activity-failed-end", sequence: 15, offset: 20)),
        WorkActionSnapshot(
            action: ActionRef("activity-queued-check"), state: .queued, kind: .runtime,
            intent: "Check the integration tests after the current step",
            intentEvent: observation("activity-queued-intent", sequence: 21, offset: 45)),
    ]

    static let inspectorProjections: (
        context: RecordedModelContextProjection,
        working: CanonicalWorkingStateProjection
    ) = {
        let systemBody = TimelineBodyReference(
            authority: sessionJournal, referenceID: "fixture-system-body",
            mediaType: "application/vnd.aviary.chat-message+json", byteCount: 9_840,
            digest: "sha256:fixture-system")
        let historyBody = TimelineBodyReference(
            authority: sessionJournal, referenceID: "fixture-history-body",
            mediaType: "application/vnd.aviary.chat-message+json", byteCount: 18_210,
            digest: "sha256:fixture-history")
        let components = [
            ContextComponent(
                componentID: "fixture-system", inclusionID: "fixture-system-include",
                sourceID: "system-prompt", mode: .pinned,
                measuredBytes: 9_840, includedBytes: 9_840, deliveredBytes: 9_840,
                fullByteCount: 9_840, bodyReference: systemBody, digest: "sha256:fixture-system"),
            ContextComponent(
                componentID: "fixture-history", inclusionID: "fixture-history-include",
                sourceID: "conversation-history", mode: .history,
                deliveryMode: .truncated, measuredBytes: 25_400, includedBytes: 18_210,
                deliveredBytes: 18_210, fullByteCount: 25_400,
                bodyReference: historyBody, digest: "sha256:fixture-history"),
            ContextComponent(
                componentID: "fixture-tools", inclusionID: "fixture-tools-include",
                sourceID: "tool-schema", mode: .instruction,
                measuredBytes: 3_190, includedBytes: 3_190, deliveredBytes: 3_190,
                fullByteCount: 3_190, digest: "sha256:fixture-tools"),
            ContextComponent(
                componentID: "fixture-compaction", inclusionID: "fixture-compaction-include",
                sourceID: "compaction-summary",
                sourceProvenance: EventRef(
                    journal: sessionJournal, eventID: "fixture-compaction-event"),
                mode: .compactionSummary, deliveryMode: .summary,
                measuredBytes: 2_140, includedBytes: 2_140, deliveredBytes: 2_140,
                fullByteCount: 2_140,
                digest: "sha256:" + String(repeating: "a", count: 64)),
        ]
        let promptSources = [
            ContextManifestSource(
                sourceID: "base-instructions-v1", inclusionID: "source-base",
                kind: .baseInstruction, status: .present, label: "unsafe fixture label",
                fullByteCount: 4_120, fullDigest: "sha256:fixture-base",
                deliveredByteCount: 4_120, deliveredDigest: "sha256:fixture-base",
                renderedByteCount: 4_120, renderedDigest: "sha256:fixture-base"),
            ContextManifestSource(
                sourceID: "/private/fixture/AGENTS.md", inclusionID: "source-context",
                kind: .contextFile, status: .truncated, label: "private fixture path",
                fullByteCount: 10_400, fullDigest: "sha256:fixture-context-full",
                deliveredByteCount: 4_096, deliveredDigest: "sha256:fixture-context-delivered",
                renderedByteCount: 4_180, renderedDigest: "sha256:fixture-context-rendered"),
            ContextManifestSource(
                sourceID: "skill:repo-inspection", inclusionID: "source-skill",
                kind: .skill, status: .present, label: "private skill description",
                fullByteCount: 1_624, fullDigest: "sha256:fixture-skill",
                deliveredByteCount: 1_624, deliveredDigest: "sha256:fixture-skill",
                renderedByteCount: 1_680, renderedDigest: "sha256:fixture-skill-rendered"),
        ]
        let manifest = ContextManifest(
            manifestID: "fixture-context-manifest", requestID: "fixture-request",
            modelID: "claude-sonnet-4-5", components: components,
            omissions: [ContextManifestOmission(
                omissionID: "fixture-history-bound", sourceID: "conversation-history",
                reason: "bounded history", measuredBytes: 7_190)],
            cumulativeDeliveredBytes: 112_480,
            systemPromptAssemblyID: "fixture-prompt-assembly",
            systemPromptSources: promptSources)

        let workCursor = JournalCursor(
            journal: workJournal, eventID: "fixture-work-tip", sequence: 25)
        let sessionCursor = JournalCursor(
            journal: sessionJournal, eventID: "fixture-session-tip", sequence: 14)
        var workSnapshot = WorkSnapshot()
        workSnapshot.journal = workJournal
        workSnapshot.work = work
        workSnapshot.workHost = host
        workSnapshot.lifecycle = .active
        workSnapshot.execution = .running
        workSnapshot.lastSequence = workCursor.sequence
        workSnapshot.lastEventID = workCursor.eventID
        workSnapshot.attachedSessionIDs = [session.sessionID]
        workSnapshot.sessionAttachments[attachment.attachmentID] = WorkSessionAttachmentSnapshot(
            attachment: attachment, session: session,
            capabilities: ["observe", "control"])
        workSnapshot.activeRun = run
        workSnapshot.observedRunIDs = [run.runID]
        workSnapshot.activeRunSession = session
        workSnapshot.activeRunSessionAttachment = attachment
        workSnapshot.modelID = "claude-sonnet-4-5"
        workSnapshot.activeTurn = turn
        workSnapshot.activeActionIDs = [activeAction.action.actionID]
        workSnapshot.actions = Dictionary(uniqueKeysWithValues: actions.map { ($0.action.actionID, $0) })
        workSnapshot.handles = [
            "fixture-handle": WorkHandleSnapshot(handle: HandleRef("fixture-handle"), state: "running")
        ]
        workSnapshot.childStates = ["fixture-child": "done", "fixture-child-running": "running",
                                    "fixture-child-failed": "failed"]
        // Design-only records exercise the same prepared activity presentation as the live UI.
        // Canonical lifecycle/cleanup validity is covered by the separate native journal fixtures.
        for (index, state) in [WorkAgentHandleState.running, .terminal, .reaped].enumerated() {
            let handle = HandleRef("fixture-background-agent-\(index)")
            let queued = EventRef(journal: workJournal, eventID: "fixture-agent-queued-\(index)")
            var value = WorkAgentHandleSnapshot(
                handle: handle,
                origin: WorkAgentHandleOrigin(
                    work: work, workHost: host, session: session,
                    sessionAttachment: attachment, run: run),
                label: "not displayed", deadline: Date(timeIntervalSince1970: 100),
                requestBody: TimelineBodyReference(
                    authority: workJournal, referenceID: "fixture-agent-request-\(index)"),
                queuedEvent: queued)
            value.state = state
            if state != .running {
                let event = WorkAgentHandleEventEvidence(
                    event: EventRef(journal: workJournal, eventID: "fixture-agent-terminal-\(index)"),
                    sequence: 24, previousEventID: "fixture-agent-started-\(index)",
                    causedByEventID: queued, hostSequence: nil,
                    work: work, workHost: host, session: session,
                    sessionAttachment: attachment, run: run, handle: handle, client: nil,
                    actor: TimelineActor(actorID: "visual-fixture"),
                    hostRecordedAt: Date(timeIntervalSince1970: 90), provenance: .native)
                value.terminalEvidence = WorkAgentHandleTerminalEvidence(
                    outcome: state == .terminal ? .indeterminate : .succeeded,
                    resultBody: nil,
                    cleanup: WorkAgentHandleCleanupProof(
                        state: state == .terminal ? .indeterminate : .quiesced), event: event)
                value.latestLifecycleEvent = event.event
            }
            workSnapshot.agentHandles[handle.handleID] = value
        }
        let recoveryCoverage = RecoveryCoverage(
            operation: .reattachLiveHost,
            planes: [
                .timeline: .preserved, .effectiveContext: .preserved,
                .runtimeNamespace: .unknown, .backgroundWork: .referenced,
                .memoriesArtifactsRepository: .referenced, .externalEffects: .unknown,
            ])
        workSnapshot.recovery = [recoveryCoverage]
        workSnapshot.recordedRecovery = [RecordedRecoveryCoverage(
            coverage: recoveryCoverage,
            sourceEvent: EventRef(journal: workJournal, eventID: "fixture-recovery-event"),
            session: session, work: work, workJournal: workJournal, workHost: host,
            sessionAttachment: attachment, run: run)]

        var sessionSnapshot = SessionSnapshot()
        sessionSnapshot.journal = sessionJournal
        sessionSnapshot.session = session
        sessionSnapshot.lifecycle = .active
        sessionSnapshot.lastSequence = sessionCursor.sequence
        sessionSnapshot.lastEventID = sessionCursor.eventID
        sessionSnapshot.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
            attachment: attachment, work: work, cursor: workCursor,
            capabilities: ["observe", "control"])
        sessionSnapshot.activeRun = run
        sessionSnapshot.activeTurn = turn
        sessionSnapshot.modelID = "claude-sonnet-4-5"
        sessionSnapshot.contextManifest = manifest
        sessionSnapshot.contextComponents = components
        sessionSnapshot.contextBoundaryEventID = "fixture-context-boundary"

        let authorization = WorkServiceAuthorizationOutcome(
            requested: [.observe, .control], granted: [.observe, .control], denied: [])
        let clientAttachment = WorkServiceClientAttachment(
            attachment: ClientAttachmentRef("fixture-client-attachment"),
            client: ClientRef("fixture-client"), session: session,
            sessionJournal: sessionJournal, sessionAttachment: attachment,
            authorization: authorization)
        let relationship = WorkServiceSessionAttachmentDescriptor(
            session: session, sessionJournal: sessionJournal, sessionAttachment: attachment,
            publication: .mirrored,
            causalSessionCursor: JournalCursor(journal: sessionJournal, sequence: 1),
            sessionCursor: sessionCursor,
            causalWorkCursor: JournalCursor(journal: workJournal, sequence: 1),
            resultingWorkCursor: JournalCursor(journal: workJournal, sequence: 2),
            capabilities: [.observe, .control])
        let descriptor = try! WorkServiceWorkDescriptor(
            work: work, journal: workJournal, recordedDisposition: .reusable,
            execution: .running, currentRun: run, currentRunSession: session,
            currentRunSessionAttachment: attachment,
            configuration: WorkServiceWorkConfiguration(
                providerID: "anthropic", modelID: "claude-sonnet-4-5",
                workspaceID: try! WorkHostWorkspaceID(
                    "workspace-12345678-1234-1234-1234-123456789abc")),
            hostObservation: nil, attachments: [clientAttachment],
            sessionAttachments: [relationship],
            artifacts: [try! WorkServiceArtifactDescriptor(
                artifactID: "fixture-report", work: work, label: "Checkpoint report",
                mediaType: "text/markdown",
                sourceEvent: EventRef(journal: workJournal, eventID: "fixture-report-event"),
                session: session, sessionAttachment: attachment, run: run)],
            omissions: [WorkServiceOmission(category: "artifact_metadata", count: 1)])
        return (
            RecordedModelContextProjection(sessionSnapshot),
            CanonicalWorkingStateProjection(
                descriptor: descriptor, attachment: clientAttachment,
                workSnapshot: workSnapshot, sessionSnapshot: sessionSnapshot,
                workCursor: workCursor, sessionCursor: sessionCursor,
                workSourceCompleteness: .complete, sessionSourceCompleteness: .complete))
    }()

    static let repositoryReview: ObservedRepositoryReview = {
        // Keep this fixture's omission contract in lockstep with the producer. The first
        // exclusion is deliberately explicit: structured names are relative, while tracked
        // diff text remains unfiltered file content.
        let expectedExclusions = [
            "structured file metadata uses repository-relative paths; tracked diff text is unfiltered file content",
            "untracked and ignored file bodies are never read",
            "binary and submodule diff bodies are never retained",
            "this artifact is observation only; it cannot stage, revert, commit, checkpoint, or restore",
        ]
        let json = """
        {
          "attribution": "not_attributed",
          "coverage": {
            "binaryBodiesExcluded": true,
            "bounded": false,
            "ignoredNamesOnly": true,
            "stagedDiffObserved": true,
            "statusObserved": true,
            "submoduleBodiesExcluded": true,
            "untrackedNamesOnly": true,
            "unstagedDiffObserved": true
          },
          "diffs": [
            {
              "byteCount": 114,
              "kind": "staged",
              "retainedSectionCount": 1,
              "text": "diff --git a/01-README.md b/01-README.md\\n--- a/01-README.md\\n+++ b/01-README.md\\n@@ -1 +1,2 @@\\n Keep review feedback attached to its source.\\n+Draft first; send only when ready.\\n",
              "truncated": false
            },
            {
              "byteCount": 71,
              "kind": "unstaged",
              "retainedSectionCount": 1,
              "text": "diff --git a/01-README.md b/01-README.md\\n--- a/01-README.md\\n+++ b/01-README.md\\n@@ -4 +4 @@\\n-Feedback applies to the latest review.\\n+Feedback applies to the exact selected review.\\n",
              "truncated": false
            }
          ],
          "exclusions": [
            "structured file metadata uses repository-relative paths; tracked diff text is unfiltered file content",
            "untracked and ignored file bodies are never read",
            "binary and submodule diff bodies are never retained",
            "this artifact is observation only; it cannot stage, revert, commit, checkpoint, or restore"
          ],
          "files": [
            {
              "indexStatus": "M",
              "isBinary": false,
              "isIgnored": false,
              "isSubmodule": false,
              "isUntracked": false,
              "kind": "tracked",
              "path": "01-README.md",
              "workTreeStatus": "M"
            },
            {
              "indexStatus": ".",
              "isBinary": false,
              "isIgnored": false,
              "isSubmodule": false,
              "isUntracked": true,
              "kind": "untracked",
              "path": "02-review-notes.swift",
              "workTreeStatus": "."
            },
            {
              "indexStatus": ".",
              "isBinary": true,
              "isIgnored": false,
              "isSubmodule": false,
              "isUntracked": false,
              "kind": "tracked",
              "path": "03-icon.bin",
              "workTreeStatus": "M"
            }
          ],
          "fenceAfter": {
            "head": {
              "detached": false,
              "oid": "0123456789abcdef0123456789abcdef01234567",
              "ref": "feature/review-ui"
            },
            "contentDigest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "statusDigest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "statusEntryCount": 3,
            "statusTruncated": false
          },
          "fenceBefore": {
            "head": {
              "detached": false,
              "oid": "0123456789abcdef0123456789abcdef01234567",
              "ref": "feature/review-ui"
            },
            "contentDigest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "statusDigest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "statusEntryCount": 3,
            "statusTruncated": false
          },
          "head": {
            "detached": false,
            "oid": "0123456789abcdef0123456789abcdef01234567",
            "ref": "feature/review-ui"
          },
          "mediaType": "application/vnd.aviary.repository-review+json",
          "observedAt": "2026-09-06T18:00:00Z",
          "omissions": [
            {
              "detail": "untracked file name and status retained; body was not read",
              "kind": "untracked_body",
              "path": "02-review-notes.swift"
            },
            {
              "detail": "binary diff body was excluded; only the file status is retained",
              "kind": "binary",
              "path": "03-icon.bin"
            }
          ],
          "repositoryIdentityDigest": "sha256:\(String(repeating: "a", count: 64))",
          "runID": "run-review-fixture",
          "schema": "aviary.repository-review",
          "scope": "current_working_tree",
          "status": "changes",
          "turnID": "turn-review-fixture",
          "version": 2
        }
        """
        var object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        object["diffs"] = (object["diffs"] as! [[String: Any]]).map { diff in
            var diff = diff
            diff["byteCount"] = (diff["text"] as! String).utf8.count
            return diff
        }
        let review = try! ObservedRepositoryReview.decode(
            JSONSerialization.data(withJSONObject: object))
        precondition(
            review.exclusions == expectedExclusions,
            "repository review fixture exclusions drifted from the production observation contract")
        return review
    }()

    static let repositoryReviewDescriptor: WorkServiceArtifactDescriptor = {
        let review = repositoryReview
        let bytes = try! review.encoded()
        let digest = "sha256:" + AviarySHA256.hash(data: bytes).description
        let source = EventRef(journal: workJournal, eventID: "review-artifact-event")
        return try! WorkServiceArtifactDescriptor(
            artifactID: "review-fixture-artifact", work: work, label: "review.json",
            mediaType: ObservedRepositoryReviewFormat.mediaType,
            byteCount: bytes.count, digest: digest, available: true,
            bodyReference: TimelineBodyReference(
                authority: workJournal, referenceID: digest,
                mediaType: ObservedRepositoryReviewFormat.mediaType,
                byteCount: bytes.count, digest: digest),
            sourceEvent: source, session: session, sessionAttachment: attachment,
            run: RunRef(review.runID), turn: TurnRef(review.turnID),
            action: ActionRef("review-fixture-action"), causedByEventID: source)
    }()

    static func deliveryRow(
        id: String, sequence: Int, state: CanonicalInputDeliveryState,
        issue: CanonicalInputDeliveryIssue? = nil, hasMessage: Bool = true,
        kind: CanonicalCommandKind = .steer,
        mode: RunInputDeliveryMode = .queued
    ) -> CanonicalInputDeliveryRow {
        CanonicalInputDeliveryRow(
            id: id,
            commandID: "command-\(id)",
            messageEvent: hasMessage
                ? EventRef(journal: sessionJournal, eventID: "message-\(id)") : nil,
            acceptanceEvent: EventRef(journal: workJournal, eventID: "accepted-\(id)"),
            deliveryEvent: state == .acceptedWaitingDelivery
                ? nil : EventRef(journal: workJournal, eventID: "outcome-\(id)"),
            hostSequence: sequence,
            client: ClientRef("client-macbook-gui"),
            sessionAttachment: attachment,
            run: RunRef("run-20260906-01"),
            commandKind: kind,
            deliveryMode: mode,
            state: state,
            issue: issue)
    }

    static let deliveredInput = deliveryRow(
        id: "delivered", sequence: 7, state: .delivered,
        kind: .send, mode: .delivered)
    static let waitingInput = deliveryRow(
        id: "waiting", sequence: 24, state: .acceptedWaitingDelivery)
    static let uncertainInput = deliveryRow(
        id: "uncertain", sequence: 25, state: .indeterminateUnknownEffect,
        issue: .missingSessionMessage, hasMessage: false,
        kind: .queue, mode: .queued)

    static var transcript: [TranscriptItem] {
        var prompt = TranscriptItem(
            id: "fixture-message-user-001", kind: .user, timestamp: baseTime.addingTimeInterval(3))
        prompt.blocks = [.text(
            "Compare the local and remote Work Host projections, then explain what the GUI can safely control.")]
        prompt.model = "claude-sonnet-4-5"

        var assistant = TranscriptItem(
            id: "fixture-message-assistant-001", kind: .assistant,
            timestamp: baseTime.addingTimeInterval(6))
        assistant.blocks = [.text(
            "I found the remote Work on `linux-01`. Its canonical Session is attached to two GUI clients, and the active Python action is still running. I can show the evidence and keep this conversation available if the current window closes.")]
        assistant.model = "claude-sonnet-4-5"
        assistant.provider = "Anthropic"
        var usage = Usage()
        usage.input = 3_842
        usage.output = 286
        usage.cacheRead = 2_910
        usage.totalTokens = 7_038
        assistant.usage = usage

        var tool = TranscriptItem(
            id: "fixture-tool-python-001", kind: .tool, timestamp: baseTime.addingTimeInterval(10))
        tool.toolCall = ToolCall(
            id: "tool-call-001", name: "python",
            arguments: .object(["code": .string(
                "from pathlib import Path\nprint(Path.cwd())\nprint('remote host: linux-01')")]))
        tool.toolResultText = "PosixPath('/workspace/aviary')\nremote host: linux-01"
        tool.toolDuration = 1.8

        var followup = TranscriptItem(
            id: "fixture-message-assistant-002", kind: .assistant,
            timestamp: baseTime.addingTimeInterval(17))
        followup.blocks = [.thinking("The host has durable ownership; the GUI only has an attachment.") , .text(
            "The next step is explicit: review the action evidence before deciding whether to steer or wait. The current action has a canonical start but no end yet, so its duration remains unknown.")]
        followup.model = "claude-sonnet-4-5"
        followup.provider = "Anthropic"

        return [prompt, assistant, tool, followup]
    }

    static var productionTranscript: [TranscriptItem] {
        var rows = transcript
        rows[0].inputDelivery = deliveredInput

        var pending = TranscriptItem(
            id: "fixture-message-user-waiting", kind: .user,
            timestamp: baseTime.addingTimeInterval(26))
        pending.blocks = [.text(
            "Before the next model call, verify the remote checkpoint and report any missing delivery evidence.")]
        pending.inputDelivery = waitingInput
        rows.append(pending)
        return rows
    }

    static var productionTranscriptNarrow: [TranscriptItem] {
        var delivered = transcript[0]
        delivered.blocks = [.text(
            "Compare the local and remote Work state, then explain what this GUI can safely control.")]
        delivered.inputDelivery = deliveredInput

        var response = transcript[1]
        response.blocks = [.text(
            "The Work stays on `linux-01` if this window closes. I am checking its canonical action and delivery evidence now.")]

        var pending = TranscriptItem(
            id: "fixture-message-user-waiting", kind: .user,
            timestamp: baseTime.addingTimeInterval(26))
        pending.blocks = [.text(
            "Before the next model call, verify the remote checkpoint.")]
        pending.inputDelivery = waitingInput
        return [delivered, response, pending]
    }
}

/// A deterministic state injection around the actual production chat hierarchy. Unlike the
/// design fixtures below, this route certifies layout and rendering through RunPane itself; it
/// still does not claim that a Work Host or durable store produced the fixture data.
@MainActor
private struct ProductionRunPaneFixture: View {
    let narrow: Bool
    private let model: AppModel
    private let run: LiveRun

    init(narrow: Bool) {
        self.narrow = narrow
        let model = AppModel()
        let run = LiveRun.productionRunPaneVisualFixture(
            items: narrow
                ? FixtureData.productionTranscriptNarrow : FixtureData.productionTranscript,
            pendingInputs: [FixtureData.waitingInput],
            deliveryAttention: [FixtureData.uncertainInput],
            actions: FixtureData.actions.map(WorkActionPresentation.init),
            recordedModelContext: FixtureData.inspectorProjections.context,
            canonicalWorkingState: FixtureData.inspectorProjections.working,
            draft: "Check the current runtime namespace, then queue a separate summary for review.")
        model.runs = [run]
        model.focusedRunID = run.id
        model.showInspector = !narrow
        model.hideThinking = false
        self.model = model
        self.run = run
    }

    var body: some View {
        RunPane(run: run, showsInspector: !narrow)
            .environment(model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct FixtureCockpitView: View {
    @State private var selected = "remote"

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 720 {
                FixtureServiceConversationView(narrow: true)
            } else {
                HStack(spacing: 0) {
                    FixtureRail(selected: $selected)
                        .frame(width: min(365, geometry.size.width * 0.31))
                    Divider()
                    FixtureCockpitDetail()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct FixtureRail: View {
    @Binding var selected: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("SESSION WORKSPACE")
                        .font(Design.sectionTitle).tracking(0.7).foregroundStyle(.secondary)
                    Spacer()
                    Text("3").font(Design.numeric(10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.bottom, 4)

                Text("NEEDS YOU").font(Design.sectionTitle).foregroundStyle(Design.warning)
                    .padding(.top, 4)
                FixtureRailCard(
                    id: "remote", title: "Remote state review", state: "needs input",
                    detail: "linux-01 · 2 clients", symbol: "exclamationmark.circle.fill",
                    tint: Design.warning, selected: selected == "remote") { selected = "remote" }

                Text("WORKING").font(Design.sectionTitle).foregroundStyle(.secondary)
                    .padding(.top, 5)
                FixtureRailCard(
                    id: "local", title: "Refactor workspace", state: "working",
                    detail: "macbook · attached here", symbol: "bolt.fill",
                    tint: Design.accent, selected: selected == "local") { selected = "local" }

                Text("READY FOR REVIEW").font(Design.sectionTitle).foregroundStyle(.secondary)
                    .padding(.top, 5)
                FixtureRailCard(
                    id: "finished", title: "Transport smoke test", state: "ready for review",
                    detail: "linux-02 · 1 Work", symbol: "checkmark.circle.fill",
                    tint: Design.success, selected: selected == "finished") { selected = "finished" }

                Button("+  New session") {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 8)
            }
            .padding(14)
        }
        .background(.background.secondary)
    }
}

private struct FixtureRailCard: View {
    let id: String
    let title: String
    let state: String
    let detail: String
    let symbol: String
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    Text(state).foregroundStyle(tint)
                    Spacer()
                    Text("Work")
                }
                .font(Design.numeric(9.5))
                Text(detail).font(Design.mono(9)).foregroundStyle(.secondary)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Design.accentSoft : Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(
                selected ? AnyShapeStyle(Design.accent.opacity(0.65))
                    : AnyShapeStyle(Color.secondary.opacity(0.55))))
        }
        .buttonStyle(.plain)
    }
}

private struct FixtureCockpitDetail: View {
    var body: some View {
        VStack(spacing: 0) {
            FixtureConversationHeader(compact: false)
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Design.accent)
                Text("Canonical Session · Work remains on linux-01 if this GUI closes")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Chip(text: "2 attachments", tint: Design.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            Divider()
            TranscriptView(items: FixtureData.transcript, isStreaming: true, autoScroll: false)
            Divider()
            WorkActivityStrip(
                action: WorkActionPresentation(FixtureData.activeAction),
                concurrentActions: FixtureData.actions.map(WorkActionPresentation.init),
                onInspect: { _ in })
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            FixtureHandoffComposer()
        }
    }
}

private struct FixtureServiceConversationView: View {
    let narrow: Bool

    var body: some View {
        VStack(spacing: 0) {
            FixtureConversationHeader(compact: narrow)
            Divider()
            if narrow {
                FixtureAttachmentBanner()
            }
            TranscriptView(items: FixtureData.transcript, isStreaming: true, autoScroll: false)
            Divider()
            if !narrow {
                HStack(alignment: .top, spacing: 12) {
                    WorkActivityStrip(
                        action: WorkActionPresentation(FixtureData.activeAction),
                        concurrentActions: FixtureData.actions.map(WorkActionPresentation.init),
                        onInspect: { _ in })
                    .frame(maxWidth: .infinity)
                    FixtureActionEvidenceCard()
                        .frame(width: 280)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                Divider()
            } else {
                FixtureCompactActivity()
                Divider()
            }
            FixtureHandoffComposer(compact: narrow)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct FixtureCompactActivity: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(Design.accent)
                Text("CURRENT ACTIVITY").font(Design.sectionTitle).foregroundStyle(.secondary)
                Chip(text: "running", tint: Design.accent)
                Spacer()
                Text("canonical").font(Design.mono(9)).foregroundStyle(Design.success)
            }
            WorkActionLensRow(action: WorkActionPresentation(FixtureData.activeAction))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Design.accent.opacity(0.065))
    }
}

private struct FixtureConversationHeader: View {
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(Design.accent).frame(width: 8, height: 8)
                Text("Remote state review").font(.system(size: compact ? 14 : 15, weight: .semibold))
                    .lineLimit(1)
                Chip(text: "working", tint: Design.accent)
                Spacer()
                if !compact {
                    Button("Detach") {}.buttonStyle(.bordered).controlSize(.small)
                    Button("End") {}.buttonStyle(.bordered).controlSize(.small).tint(Design.danger)
                } else {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 7) {
                Text("linux-01").font(Design.mono(9.5)).foregroundStyle(Design.accent)
                Text("·").foregroundStyle(.tertiary)
                Text("claude-sonnet-4-5").font(.system(size: 9.5)).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("time unknown").font(Design.numeric(9.5)).foregroundStyle(.secondary)
                Spacer()
                Text("work-...-042").font(Design.mono(9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

private struct FixtureAttachmentBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Design.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Attached to durable Work").font(.system(size: 10.5, weight: .semibold))
                Text("Host linux-01 · 2 GUI attachments · canonical cursor 24")
                    .font(Design.mono(9)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Design.accent.opacity(0.07))
    }
}

private struct FixtureActionEvidenceCard: View {
    var body: some View {
        Card("Action evidence", symbol: "bolt.horizontal.circle") {
            WorkActionLensRow(action: WorkActionPresentation(FixtureData.activeAction))
            Divider().opacity(0.5)
            HStack {
                Text("1 resolved action").font(.system(size: 9.5)).foregroundStyle(.secondary)
                Spacer()
                Text("canonical").font(Design.mono(9)).foregroundStyle(Design.success)
            }
        }
    }
}

private struct FixtureHandoffComposer: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.warning)
                Text("Draft handoff needs review")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Design.warning)
                Spacer()
                Text("generation 17").font(Design.mono(9)).foregroundStyle(.tertiary)
            }
            Text("The last GUI closed while a command was crossing. Work may have accepted it; Aviary will not replay automatically.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                Button("Check Work again") {}
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Return to composer") {}
                    .buttonStyle(.bordered).controlSize(.small).tint(Design.warning)
                Spacer()
                if !compact { Text("draft preserved locally").font(Design.mono(9)).foregroundStyle(.tertiary) }
            }
            Text("Inspect the canonical receipt before sending again")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            TextEditor(text: .constant("Continue by checking the remote Work Host output and summarize any unresolved effects."))
                .font(.system(size: 11))
                .frame(minHeight: compact ? 62 : 72, maxHeight: compact ? 82 : 100)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.65)))
        }
        .padding(.horizontal, compact ? 11 : 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
