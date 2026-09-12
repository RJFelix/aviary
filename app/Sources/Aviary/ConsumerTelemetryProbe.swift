import AviaryCore
import Foundation

/// A headless, local-only probe for the GUI consumer read boundaries.  The fixture is seeded
/// into the protocol's in-memory service, so it exercises the real controller and bridge without
/// a model call, a user home, or a command mutation.
enum ConsumerTelemetryProbe {
    private enum Failure: Error, CustomStringConvertible {
        case assertion(String)

        var description: String {
            switch self {
            case .assertion(let reason): return reason
            }
        }
    }

    @MainActor
    static func run(root: URL) async throws {
        let fixtureRoot = root.appending(
            path: "consumer-telemetry-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: fixtureRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let fixture = try await makeFixture(root: fixtureRoot)
        let bounded = await fixture.bridge.loadRepositoryReview(
            expectedDescriptor: fixture.artifact,
            maxTotalBytes: max(1, fixture.body.count - 1))
        guard case .failure(.bounded) = bounded else {
            throw Failure.assertion("bounded repository review result was not preserved")
        }

        let loaded = await fixture.bridge.loadRepositoryReview(
            expectedDescriptor: fixture.artifact)
        guard case .success(let review) = loaded,
              review.status == .clean else {
            throw Failure.assertion("canonical repository review did not load")
        }

        let connectedHistory = await fixture.controller.conversationHistory()
        guard connectedHistory.hasEarlier else {
            throw Failure.assertion("fixture did not expose an authenticated earlier-history page")
        }
        await fixture.service.setReachable(false)
        let stale = await fixture.bridge.loadRepositoryReview(
            expectedDescriptor: fixture.artifact)
        guard case .failure(.stale) = stale else {
            throw Failure.assertion("disconnected artifact read was not classified stale")
        }

        let beforeHistory = fixture.bridge.visibleMessages
        let beforeProjection = await fixture.controller.projection()
        do {
            _ = try await fixture.bridge.loadEarlierHistory()
            throw Failure.assertion("unreachable earlier-history read unexpectedly succeeded")
        } catch let error as WorkServiceAttachedWorkControllerError {
            _ = error
        }
        guard fixture.bridge.historyError != nil,
              fixture.bridge.visibleMessages.map(\.eventID) == beforeHistory.map(\.eventID),
              fixture.bridge.visibleMessages.map(\.text) == beforeHistory.map(\.text) else {
            throw Failure.assertion("history failure replaced the authenticated window")
        }

        _ = await fixture.bridge.jumpHistoryToLatest()
        _ = await fixture.bridge.refresh()
        let afterProjection = await fixture.controller.projection()
        guard beforeProjection.workCursor == afterProjection.workCursor,
              beforeProjection.sessionCursor == afterProjection.sessionCursor,
              beforeProjection.attachment == afterProjection.attachment,
              beforeProjection.pendingCommand == afterProjection.pendingCommand else {
            throw Failure.assertion("consumer reads changed canonical or pending state")
        }
        print("consumer telemetry: bounded/success/stale repository reads, preserved history failure, and no read-state mutation PASS")
    }

    private struct Fixture {
        let service: InMemoryWorkService
        let controller: WorkServiceAttachedWorkController
        let bridge: ServiceBackedRunBridge
        let artifact: WorkServiceArtifactDescriptor
        let body: Data
    }

    @MainActor private static func makeFixture(root: URL) async throws -> Fixture {
        let host = WorkHostRef("consumer-telemetry-host")
        let client = ClientRef("consumer-telemetry-client")
        let work = WorkRef(workHostID: host.workHostID, workID: "consumer-telemetry-work")
        let workJournal = JournalRef.work(work, journalID: "consumer-telemetry-work-journal")
        let session = SessionRef("consumer-telemetry-session")
        let sessionJournal = JournalRef.session(
            session, journalID: "consumer-telemetry-session-journal",
            authority: TimelineAuthorityRef(host.workHostID))
        let sessionAttachment = SessionAttachmentRef("consumer-telemetry-session-attachment")
        let run = RunRef("consumer-telemetry-run")
        let turn = TurnRef("consumer-telemetry-turn")
        let action = ActionRef("consumer-telemetry-action")
        let grants = Set(WorkServiceCapability.allCases)
        let instance = WorkHostInstanceRef(
            host: host, instanceID: "consumer-telemetry-instance",
            startIdentity: "consumer-telemetry-start")

        func encode<T: Encodable>(_ value: T) -> JSONValue {
            JSONValue.parse(try! JSONEncoder().encode(value))!
        }

        func event(
            journal: JournalRef, eventID: String, sequence: Int, previous: String?,
            type: String, session: SessionRef? = nil, work: WorkRef? = nil,
            workHost: WorkHostRef? = nil, client: ClientRef? = nil,
            sessionAttachment: SessionAttachmentRef? = nil, run: RunRef? = nil,
            turn: TurnRef? = nil, action: ActionRef? = nil,
            causedBy: EventRef? = nil, conversationParent: EventRef? = nil,
            payload: JSONValue = .object([:])) -> TimelineEvent {
            TimelineEvent(
                eventID: eventID, journal: journal, sequence: sequence,
                previousEventID: previous, causedByEventID: causedBy,
                conversationParent: conversationParent, session: session, work: work,
                workHost: workHost, client: client, sessionAttachment: sessionAttachment,
                run: run, turn: turn, action: action,
                actor: TimelineActor(actorID: "consumer-telemetry-seed", kind: "probe"),
                hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                type: type, payload: payload)
        }

        let w1 = event(
            journal: workJournal, eventID: "consumer-work-1", sequence: 1, previous: nil,
            type: TimelineEventType.workCreated, work: work, workHost: host)
        let w2 = event(
            journal: workJournal, eventID: "consumer-work-2", sequence: 2,
            previous: w1.eventID, type: TimelineEventType.sessionAttached,
            session: session, work: work, workHost: host, client: client,
            sessionAttachment: sessionAttachment,
            causedBy: EventRef(journal: sessionJournal, eventID: "consumer-session-2"),
            payload: .object(["capabilities": .array(
                grants.sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) })]))
        let w3 = event(
            journal: workJournal, eventID: "consumer-work-3", sequence: 3,
            previous: w2.eventID, type: TimelineEventType.runStarted,
            session: session, work: work, workHost: host, client: client,
            sessionAttachment: sessionAttachment, run: run,
            payload: .object(["model_id": .string("consumer-telemetry-model")]))

        var sessionEvents: [TimelineEvent] = [
            event(
                journal: sessionJournal, eventID: "consumer-session-1", sequence: 1,
                previous: nil, type: TimelineEventType.sessionCreated, session: session),
            event(
                journal: sessionJournal, eventID: "consumer-session-2", sequence: 2,
                previous: "consumer-session-1", type: TimelineEventType.sessionAttached,
                session: session, work: work, workHost: host, client: client,
                sessionAttachment: sessionAttachment,
                causedBy: EventRef(journal: sessionJournal, eventID: "consumer-session-1"),
                payload: .object(["capabilities": .array(
                    grants.sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) })])),
            event(
                journal: sessionJournal, eventID: "consumer-session-3", sequence: 3,
                previous: "consumer-session-2",
                type: TimelineEventType.sessionAttachmentCursorAdvanced,
                session: session, work: work, workHost: host, client: client,
                sessionAttachment: sessionAttachment,
                causedBy: EventRef(journal: workJournal, eventID: w2.eventID),
                payload: .object([
                    "cursor": encode(JournalCursor(
                        journal: workJournal, eventID: w2.eventID, sequence: w2.sequence)),
                    "capabilities": .array(grants.sorted { $0.rawValue < $1.rawValue }
                        .map { .string($0.rawValue) }),
                ])),
        ]
        var previousMessage: EventRef?
        for index in 0..<769 {
            let sequence = index + 4
            let id = "consumer-session-\(sequence)"
            let isAssistant = index == 768
            let message = event(
                journal: sessionJournal, eventID: id, sequence: sequence,
                previous: sessionEvents.last?.eventID, type: isAssistant
                    ? TimelineEventType.messageCommitted : TimelineEventType.inputAccepted,
                session: session, work: work, workHost: host, client: client,
                sessionAttachment: sessionAttachment,
                run: isAssistant ? run : nil,
                turn: isAssistant ? turn : nil,
                action: isAssistant ? action : nil,
                conversationParent: previousMessage,
                payload: isAssistant
                    ? .object(["role": .string("assistant"), "text": .string("clean")])
                    : .object(["text": .string("question-\(index)")]))
            sessionEvents.append(message)
            previousMessage = EventRef(journal: sessionJournal, eventID: id)
        }

        let review = await ObservedRepositoryReviewer(commandRunner: { arguments, cwd, _ in
            if arguments == ["rev-parse", "--show-toplevel"] {
                return ObservedRepositoryGitCommandResult(stdout: "\(cwd.path)\n")
            }
            if arguments.first == "rev-parse" {
                return ObservedRepositoryGitCommandResult(stdout: String(repeating: "a", count: 40))
            }
            if arguments.first == "symbolic-ref" {
                return ObservedRepositoryGitCommandResult(stdout: "main\n")
            }
            return ObservedRepositoryGitCommandResult()
        }).observe(cwd: root, runID: run.runID, turnID: turn.turnID,
                   observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let body = try review.encoded()
        let digest = "sha256:" + AviarySHA256.hash(data: body).map {
            String(format: "%02x", $0)
        }.joined()
        let source = EventRef(journal: workJournal, eventID: "consumer-review-source")
        let reference = TimelineBodyReference(
            authority: workJournal, referenceID: digest,
            mediaType: ObservedRepositoryReviewFormat.mediaType,
            byteCount: body.count, digest: digest)
        let artifact = try WorkServiceArtifactDescriptor(
            artifactID: "consumer-review-artifact", work: work, label: "review",
            mediaType: ObservedRepositoryReviewFormat.mediaType,
            byteCount: body.count, digest: digest, available: true,
            bodyReference: reference, sourceEvent: source, session: session,
            sessionAttachment: sessionAttachment, run: run, turn: turn, action: action,
            causedByEventID: source)
        let workCursor = JournalCursor(
            journal: workJournal, eventID: w3.eventID, sequence: w3.sequence)
        let sessionCursor = JournalCursor(
            journal: sessionJournal, eventID: sessionEvents.last!.eventID,
            sequence: sessionEvents.last!.sequence)
        let service = InMemoryWorkService(
            host: host, instanceID: instance.instanceID, startIdentity: instance.startIdentity,
            authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: grants]))
        try await service.register(.init(
            work: work, journal: workJournal, execution: .running, currentRun: run,
            cursor: workCursor, session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment, sessionCursor: sessionCursor,
            events: [w1, w2, w3], sessionEvents: sessionEvents,
            configuration: .init(), artifacts: [artifact], bodies: [reference: body]))
        let attached = try await service.attach(.init(
            work: work, journal: workJournal, client: client, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            commandID: "consumer-telemetry-attach",
            causalControlCursor: JournalCursor(journal: .workHost(host), sequence: 0),
            requestedCapabilities: grants))
        guard let attachment = attached.attachment,
              let key = ServiceAttachmentKey(work: work, attachment: attachment) else {
            throw Failure.assertion("in-memory fixture could not attach its canonical Session")
        }
        let intentStore = try WorkServiceAttachedWorkIntentStore(home: AgentHome(root: root), key: key)
        let controller = try WorkServiceAttachedWorkController(
            service: service,
            seed: .existing(work: attached.work, attachment: attachment),
            intentStore: intentStore, pageLimit: 128)
        var projection = try await controller.refresh()
        for _ in 0..<8 where !projection.isCanonical {
            projection = try await controller.refresh()
        }
        guard projection.isCanonical else {
            throw Failure.assertion("in-memory fixture did not reach a canonical projection")
        }
        return Fixture(
            service: service, controller: controller,
            bridge: ServiceBackedRunBridge(
                controller: controller, projection: projection,
                history: await controller.conversationHistory(), serviceAttachmentKey: key,
                workspaceLabel: "consumer-telemetry", modelLabel: nil, thinkingLevel: nil),
            artifact: artifact, body: body)
    }
}
