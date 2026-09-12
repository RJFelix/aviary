import Foundation
import OpenTelemetrySdk
@testable import AviaryCore

/// Repository-review telemetry deliberately has its own cases so the bounded review span and
/// its canonical publication receipt can be checked without relying on Agent's provider fixture.
/// The root self-test runner owns registration of this array.
let casesAviaryTelemetryRepositoryReview: [Case] = [
    ("telemetry repository review records bounded facts and no repository content", {
        try await testAviaryTelemetryRepositoryReviewSpan()
    }),
    ("telemetry repository review publishes only after a Work append", {
        try await testAviaryTelemetryRepositoryReviewPublication()
    }),
]

private func telemetryRepositoryReviewModel() -> ModelSpec {
    ModelSpec(rpc: .object([
        "id": .string("repository-review-model"),
        "provider": .string("repository-review-provider"),
    ]))
}

private func telemetryRepositoryReviewAttributeString(
    _ span: SpanData, key: String
) -> String? {
    guard case .string(let value)? = span.attributes[key] else { return nil }
    return value
}

private func telemetryRepositoryReviewEventAttributeString(
    _ event: SpanData.Event, key: String
) -> String? {
    guard case .string(let value)? = event.attributes[key] else { return nil }
    return value
}

private func testAviaryTelemetryRepositoryReviewSpan() async throws {
    let reviewer = ObservedRepositoryReviewer { _, _, _ in
        // An arbitrary discovery error must not be mislabeled as an empty/non-repository result.
        ObservedRepositoryGitCommandResult(
            stdout: "", stderr: "private path and diff must not be retained", exitCode: 128)
    }
    let (_, spans) = await AviaryTelemetry.withRecording {
        await reviewer.observe(
            cwd: URL(fileURLWithPath: "/private/repository-review-secret"),
            runID: "review-run",
            turnID: "review-turn")
    }

    let span = try XCTUnwrap(spans.first { $0.name == "aviary.repository.review" })
    XCTAssertEqual(
        telemetryRepositoryReviewAttributeString(span, key: "aviary.run.id"),
        AviaryTelemetry.identity("review-run"))
    XCTAssertEqual(
        telemetryRepositoryReviewAttributeString(span, key: "aviary.turn.id"),
        AviaryTelemetry.identity("review-turn"))
    let completion = try XCTUnwrap(span.events.first {
        $0.name == "aviary.repository.review.completed"
    })
    XCTAssertEqual(
        telemetryRepositoryReviewEventAttributeString(
            completion, key: "aviary.repository.review.status"),
        ObservedRepositoryReviewStatus.failed.rawValue)
    XCTAssertEqual(span.attributes["aviary.outcome"], .string("failed"))
    XCTAssertFalse(String(describing: spans).contains("repository-review-secret"))
    XCTAssertFalse(String(describing: spans).contains("private path and diff"))

    let root = URL(fileURLWithPath: "/tmp/rev-otel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let (review, unavailableSpans) = await AviaryTelemetry.withRecording {
        await ObservedRepositoryReviewer().observe(cwd: root, runID: "empty-run", turnID: "empty-turn")
    }
    XCTAssertEqual(review.status, .notRepository)
    let unavailable = try XCTUnwrap(unavailableSpans.first { $0.name == "aviary.repository.review" })
    XCTAssertEqual(unavailable.attributes["aviary.outcome"], .string("unavailable"))
    XCTAssertFalse(String(describing: unavailableSpans).contains(root.path))
}

private struct TelemetryRepositoryReviewFixture {
    let home: AgentHome
    let identity: SessionWorkIdentity
    let bundle: RunJournalBundle
    let turn: TurnRef
    let permit: EffectPermit
    let review: ObservedRepositoryReview
}

private func makeTelemetryRepositoryReviewFixture() async throws
    -> TelemetryRepositoryReviewFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-repository-review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "repository-review-session",
        work: WorkRef(workHostID: hostID, workID: "repository-review-work"),
        runID: "repository-review-run")
    let model = telemetryRepositoryReviewModel()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "repository-review-test",
        modelID: model.qualifiedID,
        makeAttachmentID: { "repository-review-attachment" })
    let turn = TurnRef("repository-review-turn")
    _ = try await bundle.startTurn(turn)
    let permit = try await bundle.beginAction(
        action: ActionRef("repository-review-action"), kind: .artifact,
        intent: "Observe current repository state", target: "working-tree", scope: "run")
    let review = await ObservedRepositoryReviewer { _, _, _ in
        ObservedRepositoryGitCommandResult(exitCode: 128)
    }.observe(cwd: URL(fileURLWithPath: "/tmp"), runID: identity.runID, turnID: turn.turnID)
    return TelemetryRepositoryReviewFixture(
        home: home, identity: identity, bundle: bundle, turn: turn,
        permit: permit, review: review)
}

private func settleTelemetryRepositoryReviewFixture(
    _ fixture: TelemetryRepositoryReviewFixture
) async {
    _ = try? await fixture.bundle.finishAction(
        fixture.permit, state: .succeeded, retrySafety: .idempotent)
    _ = try? await fixture.bundle.finishTurn(fixture.turn)
    _ = try? await fixture.bundle.finishRun()
    try? await fixture.bundle.closeChecked()
    try? FileManager.default.removeItem(at: fixture.home.root)
}

private func testAviaryTelemetryRepositoryReviewPublication() async throws {
    let fixture = try await makeTelemetryRepositoryReviewFixture()
    let (receipt, spans) = try await AviaryTelemetry.withRecording {
        let value = try await AviaryTelemetry.withSpan(
            "aviary.repository.review.publish") {
                try await fixture.bundle.recordArtifact(
                    artifactID: "repository-review-artifact",
                    label: "Observed repository review",
                    mediaType: ObservedRepositoryReview.mediaType,
                    body: try fixture.review.encoded(),
                    action: fixture.permit.action,
                    provenance: fixture.permit.startedCommit.eventRef)
            }
        await settleTelemetryRepositoryReviewFixture(fixture)
        return value
    }
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }

    let span = try XCTUnwrap(spans.first { $0.name == "aviary.repository.review.publish" })
    let publication = try XCTUnwrap(span.events.first {
        $0.name == "aviary.repository.artifact.published"
    })
    let canonical = AviaryTelemetry.canonicalReferenceAttributes(receipt.commit)
    XCTAssertEqual(canonical.count, 3)
    XCTAssertEqual(
        publication.attributes["aviary.event.id"],
        .string(AviaryTelemetry.identity(receipt.commit.eventRef.eventID)))
    XCTAssertEqual(
        publication.attributes["aviary.event.journal.id"],
        .string(AviaryTelemetry.journalIdentity(receipt.commit.eventRef.journal)))
    XCTAssertEqual(
        publication.attributes["aviary.event.sequence"],
        .int(receipt.commit.cursor.sequence))
    XCTAssertEqual(
        publication.attributes["aviary.artifact.id"],
        .string(AviaryTelemetry.identity(receipt.descriptor.artifactID)))
    XCTAssertEqual(
        publication.attributes["aviary.work.id"],
        .string(AviaryTelemetry.workIdentity(receipt.descriptor.work)))
    XCTAssertEqual(
        publication.attributes["aviary.run.id"],
        .string(AviaryTelemetry.identity(receipt.run.runID)))
    XCTAssertEqual(
        publication.attributes["aviary.turn.id"],
        .string(AviaryTelemetry.identity(receipt.turn!.turnID)))
    XCTAssertEqual(
        publication.attributes["aviary.action.id"],
        .string(AviaryTelemetry.identity(receipt.action!.actionID)))
    XCTAssertEqual(publication.attributes["aviary.artifact.bytes"], .int(receipt.descriptor.byteCount!))
    XCTAssertFalse(String(describing: spans).contains("repository-review-artifact"))

    let genericFixture = try await makeTelemetryRepositoryReviewFixture()
    defer { try? FileManager.default.removeItem(at: genericFixture.home.root) }
    let (_, genericSpans) = try await AviaryTelemetry.withRecording {
        let value = try await AviaryTelemetry.withSpan("aviary.repository.review.publish") {
            try await genericFixture.bundle.recordArtifact(
                artifactID: "generic-artifact",
                label: "Generic retained body",
                mediaType: "text/plain",
                body: Data("body only".utf8))
        }
        await settleTelemetryRepositoryReviewFixture(genericFixture)
        return value
    }
    XCTAssertFalse(genericSpans.contains { span in
        span.events.contains { $0.name == "aviary.repository.artifact.published" }
    })

    for failurePoint in [
        TimelineJournalWriter.FailurePoint.beforeWrite,
        TimelineJournalWriter.FailurePoint.afterWriteBeforeSync,
    ] {
        let failedFixture = try await makeTelemetryRepositoryReviewFixture()
        defer { try? FileManager.default.removeItem(at: failedFixture.home.root) }
        await failedFixture.bundle.injectWriterFailure(failurePoint, in: .work)
        let (_, failedSpans) = await AviaryTelemetry.withRecording {
            do {
                try await AviaryTelemetry.withSpan("aviary.repository.review.publish") {
                    _ = try await failedFixture.bundle.recordArtifact(
                        artifactID: "repository-review-failed-artifact",
                        label: "Observed repository review",
                        mediaType: ObservedRepositoryReview.mediaType,
                        body: try failedFixture.review.encoded(),
                        action: failedFixture.permit.action,
                        provenance: failedFixture.permit.startedCommit.eventRef)
                }
                XCTFail("a failed Work append must not publish a telemetry receipt")
            } catch {
                // The append failure is the proof boundary; there must be no fabricated commit event.
            }
            try? await failedFixture.bundle.closeChecked()
        }
        let failedSpan = try XCTUnwrap(failedSpans.first {
            $0.name == "aviary.repository.review.publish"
        })
        XCTAssertEqual(failedSpan.attributes["aviary.outcome"], .string("indeterminate"))
        XCTAssertFalse(failedSpan.events.contains {
            $0.name == "aviary.repository.artifact.published"
        })
    }
}
