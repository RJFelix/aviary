import Foundation
@testable import AviaryCore

private func settlementBundle(_ home: AgentHome) async throws -> RunJournalBundle {
    try await RunJournalBundle.createFresh(home: home,
        session: SessionRef("settlement-session"),
        work: WorkRef(workHostID: "settlement-host", workID: "settlement-work"),
        workHost: WorkHostRef("settlement-host"),
        sessionAuthority: TimelineAuthorityRef("settlement-host"),
        sessionAttachment: SessionAttachmentRef("settlement-attachment"), run: RunRef("settlement-run"),
        actor: TimelineActor(actorID: "settlement-host", kind: "self-test"), modelID: "provider/model")
}

private func settlementHome() throws -> AgentHome {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("psj-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AgentHome(root: root)
}

private func settlementSnapshot(_ home: AgentHome, _ bundle: RunJournalBundle) throws -> WorkSnapshot {
    let read = TimelineJournalReader.read(try Data(contentsOf: home.timelineV2WorkJournalURL(bundle.work)),
        journal: bundle.workJournal, actor: TimelineActor(actorID: "reader", kind: "self-test"),
        hostRecordedAt: Date())
    return WorkReducer.reduce(read.records.map(\.event))
}

let casesProviderSettlementJournal: [Case] = [
    ("provider settlement journal: failed usage commits once and permits End", {
        let home = try settlementHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let bundle = try await settlementBundle(home)
        let manifest = try await fixtureProviderManifest(home: home, bundle: bundle)
        let admission = fixtureProviderAdmission()

        // The admission is part of the crossing identity, not merely pricing metadata.  A
        // mismatched rate snapshot must be rejected before the Session context or Work action
        // can be appended, so a caller cannot leave an orphaned context boundary behind.
        let beforeMismatch = await bundle.latestWorkCursor
        let mismatchedAdmission = ProviderAdmission(
            purpose: .normal,
            rates: ProviderUsage.RateSnapshot(model: ModelSpec(rpc: .object([
                "id": .string("other-model"), "provider": .string("provider")
            ]))))
        do {
            _ = try await bundle.prepareModelCrossing(
                manifest: manifest, admission: mismatchedAdmission, kind: .provider,
                target: "provider/model")
            XCTFail("a rate snapshot for another model must not authorize this crossing")
        } catch let error as ProviderSettlementError {
            XCTAssertEqual(error, .modelIdentityMismatch)
        } catch {
            XCTFail("unexpected model identity error: \(error)")
        }
        XCTAssertEqual(await bundle.latestWorkCursor, beforeMismatch)
        let preflightSessionData = try Data(
            contentsOf: home.timelineV2SessionJournalURL(bundle.session))
        let preflightSessionRead = TimelineJournalReader.read(
            preflightSessionData, journal: bundle.sessionJournal,
            actor: TimelineActor(actorID: "settlement-test", kind: "self-test"),
            hostRecordedAt: Date(timeIntervalSince1970: 1))
        XCTAssertFalse(preflightSessionRead.records.contains {
            $0.event.type == TimelineEventType.contextAssembled
        })

        // Keep a unicode provider/model pair and a slash-containing model ID as positive
        // identity cases.  Qualified targets are checked by exact suffix, never by splitting
        // on a slash that may belong to the model ID.
        let unicodeAdmission = ProviderAdmission(
            purpose: .normal,
            rates: ProviderUsage.RateSnapshot(model: ModelSpec(rpc: .object([
                "id": .string("模型/variant"), "provider": .string("供应商")
            ]))))
        try unicodeAdmission.validate(
            contextModelID: "模型/variant", targetModel: "供应商/模型/variant")
        let longProvider = String(repeating: "p", count: 257)
        let longModel = String(repeating: "m", count: 257)
        let longAdmission = ProviderAdmission(
            purpose: .normal,
            rates: ProviderUsage.RateSnapshot(model: ModelSpec(rpc: .object([
                "id": .string(longModel), "provider": .string(longProvider)
            ]))))
        try longAdmission.validate(
            contextModelID: longModel, targetModel: "\(longProvider)/\(longModel)")

        let permit = try await bundle.prepareModelCrossing(manifest: manifest, admission: admission, kind: .provider)
        let before = await bundle.latestWorkCursor
        let settlement = ProviderSettlement(admission: admission,
            report: .init(inputTokens: 17, outputTokens: 3, inputAccounting: .cacheInclusive),
            finality: .unconfirmed)
        do {
            _ = try await bundle.finishAction(permit, state: .succeeded, retrySafety: .unsafe,
                providerSettlement: settlement)
            XCTFail("unconfirmed provider result cannot authorize success")
        } catch { }
        do {
            _ = try await bundle.finishAction(permit, state: .failed, retrySafety: .unknown, failureKind: .infrastructure)
            XCTFail("omitted usage settlement must not erase exposure")
        } catch { }
        XCTAssertEqual(await bundle.latestWorkCursor, before)
        let commit = try await bundle.finishAction(permit, state: .failed, retrySafety: .unknown,
            failureKind: .infrastructure, providerSettlement: settlement)
        var expected = ProviderUsageAggregate()
        try expected.recordStarted()
        try expected.recordSettlement(settlement)
        let snapshot = try settlementSnapshot(home, bundle)
        XCTAssertTrue(snapshot.semanticProjectionValid)
        XCTAssertEqual(snapshot.providerUsage, expected)
        XCTAssertEqual(snapshot.actions[permit.action.actionID]?.providerSettlement, settlement)
        XCTAssertEqual(commit.cursor.sequence, (before?.sequence ?? 0) + 1)
        do {
            _ = try await bundle.finishAction(permit, state: .failed, retrySafety: .unknown,
                failureKind: .infrastructure, providerSettlement: settlement)
            XCTFail("same permit must not settle twice")
        } catch { }
        XCTAssertEqual(await bundle.latestWorkCursor, commit.cursor)
        _ = try await bundle.finishRun(outcome: .failed)
        try await bundle.closeChecked()
        XCTAssertEqual(try settlementSnapshot(home, bundle).providerUsage, expected)
    }),
    ("provider settlement journal: uncertain append latches before another dispatch", {
        let home = try settlementHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let bundle = try await settlementBundle(home)
        let manifest = try await fixtureProviderManifest(home: home, bundle: bundle)
        let permit = try await bundle.prepareModelCrossing(manifest: manifest,
            admission: fixtureProviderAdmission(), kind: .provider)
        await bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)
        do {
            _ = try await bundle.finishAction(permit, state: .succeeded, retrySafety: .unsafe,
                providerSettlement: fixtureProviderSettlement(permit))
            XCTFail("after-write uncertainty must not claim settlement success")
        } catch { }
        let failed = await bundle.status
        if case .healthy = failed.health { XCTFail("ambiguous outcome must latch journal") }
        do {
            _ = try await bundle.prepareModelCrossing(manifest: manifest,
                admission: fixtureProviderAdmission(), kind: .provider)
            XCTFail("latched writer cannot dispatch another model")
        } catch { }
        try? await bundle.closeChecked()
    }),
]
