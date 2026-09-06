import SwiftUI
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

    var isNarrow: Bool {
        self == .serviceChatNarrow || self == .productionDeliveryNarrow
            || self == .productionInspectorNarrow
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
        }
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
        workSnapshot.childStates = ["fixture-child": "done"]
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
            artifacts: [WorkServiceArtifactDescriptor(
                artifactID: "fixture-report", work: work, label: "Checkpoint report",
                mediaType: "text/markdown", byteCount: 2_840,
                digest: "sha256:fixture-report", available: true)],
            omissions: [WorkServiceOmission(category: "artifact_metadata", count: 1)])
        return (
            RecordedModelContextProjection(sessionSnapshot),
            CanonicalWorkingStateProjection(
                descriptor: descriptor, attachment: clientAttachment,
                workSnapshot: workSnapshot, sessionSnapshot: sessionSnapshot,
                workCursor: workCursor, sessionCursor: sessionCursor,
                workSourceCompleteness: .complete, sessionSourceCompleteness: .complete))
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
