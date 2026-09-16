import Foundation

@testable import AviaryCore

private struct WorkLaunchManifestFixture {
    let root: URL
    let home: AgentHome
    let host: WorkHostRef
    let work: WorkRef
    let session: SessionRef
    let attachment: SessionAttachmentRef
    let run: RunRef
    let workJournal: JournalRef
    let sessionJournal: JournalRef
    let controlJournal: JournalRef
    let controlCursor: JournalCursor
    let identity: WorkLaunchManifestIdentity
    let startIntent: WorkLaunchStartIntent
    let body: Data
    let bodyReference: TimelineBodyReference
    let systemBody: Data
    let promptAssembly: WorkLaunchPromptAssembly
    let manifest: WorkLaunchManifest
    let store: WorkLaunchManifestStore

    init(name: String = UUID().uuidString.lowercased()) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "aviary-work-launch-\(name)", directoryHint: .isDirectory)
        home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
        host = try home.requirePersistedWorkHost()
        work = WorkRef(workHostID: host.workHostID, workID: "work-\(name)")
        session = SessionRef("session-\(name)")
        attachment = SessionAttachmentRef("attachment-\(name)")
        run = RunRef("run-\(name)")
        workJournal = .work(work)
        sessionJournal = .session(
            session, authority: TimelineAuthorityRef(host.workHostID))
        controlJournal = .workHost(host)
        controlCursor = JournalCursor(journal: controlJournal, eventID: nil, sequence: 0)
        store = WorkLaunchManifestStore(home: home)
        identity = WorkLaunchManifestIdentity(
            work: work, session: session, sessionAttachment: attachment, run: run)
        body = Data("the private prompt body \(name)".utf8)
        let bodyReference = try ContextBodyStore(home: home).retain(
            body, authority: sessionJournal, mediaType: "text/plain")
        guard let bodyDigest = bodyReference.digest else {
            throw WorkLaunchManifestStoreError.invalidReference
        }
        systemBody = Data("the flattened system prompt \(name)".utf8)
        let systemText = String(decoding: systemBody, as: UTF8.self)
        let promptSource = try PromptSource(
            sourceID: "fixture:system", kind: .generated, label: "Fixture system",
            fullBody: systemText, deliveredBody: systemText, renderedBody: systemText)
        let assembly = try SystemPromptAssembly(text: systemText, sources: [promptSource])
        promptAssembly = try store.retainPromptAssembly(
            assembly, authority: .workHost(host),
            provenance: WorkLaunchManifestProvenance(source: "fixture.prompt"))
        manifest = WorkLaunchManifest(
            identity: identity,
            startIntent: WorkLaunchStartIntent(
                client: ClientRef("self-test-client"), commandID: "start-\(name)",
                causalWorkCursor: JournalCursor(journal: workJournal, sequence: 0),
                bodyDigest: bodyDigest),
            workspace: WorkLaunchWorkspace(
                locator: root.appending(path: "workspace", directoryHint: .isDirectory).path,
                policy: .workspace,
                provenance: EventRef(journal: workJournal, eventID: "workspace-observed")),
            runtime: WorkLaunchRuntime(
                providerID: "provider.test", modelID: "model.test", runtimeVariant: "native",
                provenance: EventRef(journal: workJournal, eventID: "runtime-selected")),
            initialInputBodyReference: bodyReference,
            promptAssembly: promptAssembly,
            systemPromptBodyReference: promptAssembly.flattenedBodyReference,
            contextPolicy: WorkLaunchContextPolicy(
                includeContextFiles: true, contextManifestID: "context-manifest"),
            recordingPolicy: WorkLaunchRecordingPolicy(
                recordPayloads: true,
                wireLogDirectory: root.path,
                wireLogLocator: root.appending(path: "run-\(run.runID).jsonl").path),
            resumePolicy: WorkLaunchResumePolicy(mode: .coldResume, sourceSession: session,
                                                 sourceRun: run),
            reasoningPolicy: WorkLaunchReasoningPolicy(
                enabled: true, level: "medium", tokenBudget: 512),
            budgetPolicy: WorkLaunchBudgetPolicy(
                maximumTurns: 8, maximumTokens: 8_192, maximumWallClockSeconds: 120),
            goal: WorkLaunchGoalConfiguration(
                goalID: "goal-\(name)", summary: "bounded test goal", mode: "execute"),
            hooks: [WorkLaunchHookConfiguration(hookID: "hook.test", phase: "before_run")],
            peerScheduler: WorkLaunchPeerSchedulerConfiguration(
                enabled: true, maximumPeers: 2, queuePolicy: "serial"),
            provenance: WorkLaunchManifestProvenance(
                source: "self-test", sourceEvent: EventRef(journal: workJournal, eventID: "manifest"),
                sourceCursor: JournalCursor(
                    journal: workJournal, eventID: "manifest", sequence: 3)))
        startIntent = manifest.startIntent
        self.bodyReference = bodyReference
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    var binding: WorkRunBinding {
        WorkRunBinding(
            workBinding: WorkBinding(
                session: session, work: work, workHost: host, sessionAttachment: attachment),
            run: run)
    }
}

private func expectWorkLaunchError(
    _ body: () throws -> Void,
    matches: (WorkLaunchManifestStoreError) -> Bool
) throws {
    do {
        try body()
        XCTFail("expected WorkLaunchManifestStoreError")
    } catch let error as WorkLaunchManifestStoreError {
        XCTAssertTrue(matches(error), "unexpected Work launch error: \(error)")
    }
}

private func expectRuntimeAdoptionError(
    _ body: () throws -> Void,
    matches: (RuntimeAdoptionRecordStoreError) -> Bool
) throws {
    do {
        try body()
        XCTFail("expected RuntimeAdoptionRecordStoreError")
    } catch let error as RuntimeAdoptionRecordStoreError {
        XCTAssertTrue(matches(error), "unexpected Runtime adoption error: \(error)")
    }
}

private func startWithRetainedAssembly(
    fixture: WorkLaunchManifestFixture,
    template: WorkLaunchWorkTemplateRecord,
    run: RunRef,
    intent: WorkLaunchStartIntent,
    expectedPrevious: WorkLaunchManifestGeneration? = nil
) throws -> WorkLaunchManifestRecord {
    let admission = try fixture.store.reserveStart(
        template, binding: fixture.binding.workBinding, run: run, startIntent: intent,
        expectedPrevious: expectedPrevious,
        initialInputBodyReference: fixture.bodyReference)
    let reservation: WorkLaunchStartReservation
    switch admission {
    case .existing(let record): return record
    case .winner(let value), .reserved(let value): reservation = value
    }
    let prepared = try fixture.store.prepareStart(
        reservation, promptAssembly: fixture.promptAssembly)
    return try fixture.store.start(
        template, binding: fixture.binding.workBinding,
        run: prepared.run, startIntent: prepared.intent,
        expectedPrevious: prepared.expectedPrevious,
        initialInputBodyReference: prepared.initialInputBodyReference,
        promptAssembly: try XCTUnwrap(prepared.promptAssembly))
}

private func retainStaleStartReservation(
    _ reservation: WorkLaunchStartReservation,
    store: WorkLaunchManifestStore
) throws {
    // Start reservations are now the single Work-scoped admission fence. The selected
    // Session/attachment remains payload, but all contenders must address one durable slot.
    let digest = workAddressDigest(reservation.binding.work)
    let url = store.startReservationDirectory.appending(
        path: digest + ".json",
        directoryHint: .notDirectory)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(reservation).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func workAddressDigest(_ work: WorkRef) -> String {
    let material = [
        "work", work.workHostID, work.workID,
    ].map { "\($0.utf8.count):\($0)" }.joined(separator: "\u{0}")
    return "sha256:" + AviarySHA256.hash(data: Data(material.utf8))
        .map { String(format: "%02x", $0) }.joined()
}

private func retainStalePendingPointer(
    binding: WorkBinding,
    identity: WorkLaunchManifestIdentity,
    digest: String,
    store: WorkLaunchManifestStore
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bindingObject = try JSONSerialization.jsonObject(
        with: encoder.encode(binding))
    let identityObject = try JSONSerialization.jsonObject(
        with: encoder.encode(identity))
    let object: [String: Any] = [
        "schemaVersion": 1,
        "binding": bindingObject,
        "identity": identityObject,
        "digest": digest,
        "expectedPrevious": NSNull(),
    ]
    let data = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    let url = store.pendingPointerDirectory.appending(
        path: workAddressDigest(binding.work) + ".json", directoryHint: .notDirectory)
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func test_workLaunchManifestRoundTripsWithExactBodyDigestAndNoPromptBody() throws {
    let fixture = try WorkLaunchManifestFixture()
    defer { fixture.remove() }

    let record = try fixture.store.save(fixture.manifest)
    let loaded = try XCTUnwrap(try fixture.store.read(fixture.identity))
    XCTAssertEqual(loaded, record)
    XCTAssertEqual(loaded.manifestByteCount, try fixture.manifest.canonicalBytes().count)
    XCTAssertEqual(loaded.manifestDigest, try fixture.manifest.contentDigest())
    XCTAssertEqual(try fixture.store.resolveInitialInputBody(for: loaded.manifest), fixture.body)
    XCTAssertEqual(try fixture.store.resolveSystemPromptBody(for: loaded.manifest), fixture.systemBody)

    let metadata = try fixture.manifest.canonicalBytes()
    XCTAssertFalse(metadata.range(of: fixture.body) != nil,
                   "raw prompt bytes must stay in ContextBodyStore")
    XCTAssertFalse(metadata.range(of: fixture.systemBody) != nil,
                   "raw system prompt bytes must stay in ContextBodyStore")
    XCTAssertTrue(metadata.count > 0)
    XCTAssertEqual(loaded.manifest.workRunBinding, fixture.binding)
}

func test_workLaunchManifestTwoStageBindingUsesReservedIdentity() throws {
    let fixture = try WorkLaunchManifestFixture()
    defer { fixture.remove() }

    let draft = WorkLaunchManifestDraft(
        workspace: fixture.manifest.workspace,
        runtime: fixture.manifest.runtime,
        configuration: WorkServiceWorkConfiguration(
            includeContextFiles: fixture.manifest.contextPolicy.includeContextFiles,
            recordPayloads: fixture.manifest.recordingPolicy.recordPayloads),
        requestedCapabilities: [],
        contextPolicy: fixture.manifest.contextPolicy,
        recordingPolicy: WorkLaunchRecordingPolicy(
            recordPayloads: true, wireLogDirectory: fixture.root.path),
        resumePolicy: fixture.manifest.resumePolicy,
        reasoningPolicy: fixture.manifest.reasoningPolicy,
        budgetPolicy: fixture.manifest.budgetPolicy,
        goal: fixture.manifest.goal,
        hooks: fixture.manifest.hooks,
        peerScheduler: fixture.manifest.peerScheduler,
        provenance: fixture.manifest.provenance)
    let key = WorkLaunchCreateKey(
        client: fixture.startIntent.client,
        requestDigest: try WorkLaunchCreateKey.requestDigest(
            configuration: draft.configuration,
            requestedCapabilities: draft.requestedCapabilities),
        commandID: fixture.startIntent.commandID,
        causalControlCursor: fixture.controlCursor)
    let retained = try fixture.store.retain(draft, for: key)
    XCTAssertEqual(retained.digest, try draft.contentDigest())
    let reloadedDraft = try XCTUnwrap(try fixture.store.loadRetainedDraft(for: key))
    XCTAssertEqual(reloadedDraft, retained)
    let template = try fixture.store.publishTemplate(
        retained, binding: fixture.binding.workBinding)
    let record = try startWithRetainedAssembly(
        fixture: fixture, template: template, run: fixture.run, intent: fixture.startIntent)
    XCTAssertEqual(record.manifest.identity, fixture.identity)
    XCTAssertEqual(record.manifest.workRunBinding, fixture.binding)
    XCTAssertEqual(try fixture.store.read(fixture.identity), record)

    // The current/pending admission fence is Work-scoped even though each Run payload retains
    // its selected Session binding. A second attached Session can propose the next Run only
    // after observing the predecessor selection, and a competing first reservation cannot create
    // a second manifest under a separate Session-qualified path.
    let alternateSession = SessionRef("alternate-\(fixture.session.sessionID)")
    let alternateAttachment = SessionAttachmentRef("alternate-\(fixture.attachment.attachmentID)")
    XCTAssertNotEqual(alternateSession, fixture.session)
    XCTAssertNotEqual(alternateAttachment, fixture.attachment)
    let alternateBinding = WorkBinding(
        session: alternateSession, work: fixture.work, workHost: fixture.host,
        sessionAttachment: alternateAttachment)
    let alternateJournal = JournalRef.session(
        alternateSession, authority: TimelineAuthorityRef(fixture.host.workHostID))
    let alternateBodyReference = try ContextBodyStore(home: fixture.home).retain(
        fixture.body, authority: alternateJournal, mediaType: "text/plain")
    let alternateIntent = WorkLaunchStartIntent(
        client: ClientRef("alternate-client"), commandID: "alternate-start",
        causalWorkCursor: fixture.startIntent.causalWorkCursor,
        bodyDigest: fixture.startIntent.bodyDigest)
    let predecessorSelection = try XCTUnwrap(
        try fixture.store.readCurrentSelection(for: fixture.binding.workBinding))
    let alternateAdmission = try fixture.store.reserveStart(
        template, binding: alternateBinding, run: RunRef("alternate-run"),
        startIntent: alternateIntent,
        expectedPrevious: predecessorSelection.selectionGeneration,
        initialInputBodyReference: alternateBodyReference)
    guard case .winner = alternateAdmission else {
        XCTFail("alternate Session must win only the next Work-level reservation")
        return
    }
    try expectWorkLaunchError({
        _ = try fixture.store.reserveStart(
            template, binding: fixture.binding.workBinding, run: RunRef("loser-run"),
            startIntent: WorkLaunchStartIntent(
                client: ClientRef("loser-client"), commandID: "loser-start",
                causalWorkCursor: fixture.startIntent.causalWorkCursor,
                bodyDigest: fixture.startIntent.bodyDigest),
            expectedPrevious: predecessorSelection.selectionGeneration,
            initialInputBodyReference: fixture.bodyReference)
    }) {
        if case .requestConflict = $0 { return true }
        return false
    }
    XCTAssertTrue(try fixture.store.hasPendingStart(for: fixture.binding.workBinding))
}

func test_workLaunchManifestRetentionTemplateAndStartAreIdempotentAndCAS() throws {
    let fixture = try WorkLaunchManifestFixture()
    defer { fixture.remove() }
    let draft = WorkLaunchManifestDraft(
        workspace: fixture.manifest.workspace,
        runtime: fixture.manifest.runtime,
        configuration: WorkServiceWorkConfiguration(
            includeContextFiles: fixture.manifest.contextPolicy.includeContextFiles,
            recordPayloads: fixture.manifest.recordingPolicy.recordPayloads),
        requestedCapabilities: [],
        contextPolicy: fixture.manifest.contextPolicy,
        recordingPolicy: WorkLaunchRecordingPolicy(
            recordPayloads: true, wireLogDirectory: fixture.root.path),
        resumePolicy: fixture.manifest.resumePolicy,
        reasoningPolicy: fixture.manifest.reasoningPolicy,
        budgetPolicy: fixture.manifest.budgetPolicy,
        goal: fixture.manifest.goal,
        hooks: fixture.manifest.hooks,
        peerScheduler: fixture.manifest.peerScheduler,
        provenance: fixture.manifest.provenance)
    let key = WorkLaunchCreateKey(
        client: fixture.startIntent.client,
        requestDigest: try WorkLaunchCreateKey.requestDigest(
            configuration: draft.configuration,
            requestedCapabilities: draft.requestedCapabilities),
        commandID: fixture.startIntent.commandID,
        causalControlCursor: fixture.controlCursor)
    let retained = try fixture.store.retain(draft, for: key)
    let laterDraft = WorkLaunchManifestDraft(
        workspace: draft.workspace,
        runtime: draft.runtime,
        configuration: draft.configuration,
        requestedCapabilities: draft.requestedCapabilities,
        contextPolicy: draft.contextPolicy,
        recordingPolicy: draft.recordingPolicy,
        resumePolicy: draft.resumePolicy,
        reasoningPolicy: draft.reasoningPolicy,
        budgetPolicy: draft.budgetPolicy,
        goal: draft.goal,
        hooks: draft.hooks,
        peerScheduler: draft.peerScheduler,
        provenance: WorkLaunchManifestProvenance(
            source: draft.provenance.source, sourceEvent: draft.provenance.sourceEvent,
            sourceCursor: draft.provenance.sourceCursor,
            recordedAt: Date(timeIntervalSince1970: 99)))
    let retry = try fixture.store.retain(laterDraft, for: key)
    XCTAssertEqual(retry.digest, retained.digest)
    XCTAssertEqual(retry.draft.draft, retained.draft.draft)
    let template = try fixture.store.publishTemplate(
        retained, binding: fixture.binding.workBinding)
    XCTAssertEqual(try fixture.store.readTemplate(for: fixture.work), template)
    // The store lock serializes a concurrent first Start: one caller publishes the Run pointer,
    // while all retrying callers observe and return the same durable record.
    let concurrentLock = NSLock()
    var concurrentSuccesses: [WorkLaunchManifestRecord] = []
    var concurrentFailures: [Error] = []
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        do {
            let result = try startWithRetainedAssembly(
                fixture: fixture, template: template, run: fixture.run, intent: fixture.startIntent)
            concurrentLock.lock()
            concurrentSuccesses.append(result)
            concurrentLock.unlock()
        } catch {
            concurrentLock.lock()
            concurrentFailures.append(error)
            concurrentLock.unlock()
        }
    }
    XCTAssertEqual(concurrentSuccesses.count, 8)
    XCTAssertEqual(concurrentFailures.count, 0)
    let first = try XCTUnwrap(concurrentSuccesses.first)
    XCTAssertTrue(concurrentSuccesses.dropFirst().allSatisfy { $0 == first })

    // Simulate a final-publish crash after the best-effort reservation unlink. Repair must
    // remove the orphaned Run 1 reservation before the next distinct Run can advance the CAS.
    let staleReservation = WorkLaunchStartReservation(
        binding: fixture.binding.workBinding, run: fixture.run,
        intent: fixture.startIntent, templateGeneration: template.generation,
        initialInputBodyReference: fixture.bodyReference,
        promptAssembly: fixture.promptAssembly)
    try retainStaleStartReservation(staleReservation, store: fixture.store)
    try FileManager.default.removeItem(
        at: fixture.store.bindingPointerURL(for: fixture.binding.workBinding))
    let repaired = try fixture.store.repairCurrentSelection(first)
    XCTAssertEqual(repaired, first)
    XCTAssertNil(try fixture.store.readStartReservation(for: fixture.binding.workBinding))
    try retainStalePendingPointer(
        binding: fixture.binding.workBinding, identity: fixture.identity,
        digest: first.manifestDigest, store: fixture.store)
    XCTAssertFalse(try fixture.store.hasPendingStart(for: fixture.binding.workBinding))

    let retryStart = try startWithRetainedAssembly(
        fixture: fixture, template: template, run: fixture.run, intent: fixture.startIntent)
    XCTAssertEqual(retryStart, first)
    let conflictingIntent = WorkLaunchStartIntent(
        client: fixture.startIntent.client, commandID: "conflicting-start",
        causalWorkCursor: fixture.startIntent.causalWorkCursor,
        bodyDigest: fixture.startIntent.bodyDigest)
    try expectWorkLaunchError({
        _ = try startWithRetainedAssembly(
            fixture: fixture, template: template, run: fixture.run, intent: conflictingIntent)
    }) {
        if case .requestConflict = $0 { return true }
        return false
    }
    let nextRun = RunRef("run-next")
    let nextIntent = WorkLaunchStartIntent(
        client: fixture.startIntent.client, commandID: "start-next",
        causalWorkCursor: fixture.startIntent.causalWorkCursor,
        bodyDigest: fixture.startIntent.bodyDigest)
    try expectWorkLaunchError({
        _ = try startWithRetainedAssembly(
            fixture: fixture, template: template, run: nextRun, intent: nextIntent)
    }) {
        if case .generationMismatch = $0 { return true }
        return false
    }
    let second = try startWithRetainedAssembly(
        fixture: fixture, template: template, run: nextRun, intent: nextIntent,
        expectedPrevious: try XCTUnwrap(
            try fixture.store.readCurrentSelection(for: fixture.binding.workBinding))
            .selectionGeneration)
    let thirdRun = RunRef("run-third")
    let thirdIntent = WorkLaunchStartIntent(
        client: fixture.startIntent.client, commandID: "start-third",
        causalWorkCursor: fixture.startIntent.causalWorkCursor,
        bodyDigest: fixture.startIntent.bodyDigest)
    let secondSelection = try XCTUnwrap(
        try fixture.store.readCurrentSelection(for: fixture.binding.workBinding))
    // A historical Run can retain an orphaned reservation if its cleanup failed after a later
    // replacement advanced current-by-binding. The final identity/Start indexes still prove it
    // was fully published, so the next distinct Run may discard only that stale marker.
    try retainStaleStartReservation(staleReservation, store: fixture.store)
    let third = try startWithRetainedAssembly(
        fixture: fixture, template: template, run: thirdRun, intent: thirdIntent,
        expectedPrevious: secondSelection.selectionGeneration)
    let current = try XCTUnwrap(
        try fixture.store.readCurrent(for: fixture.binding.workBinding))
    XCTAssertEqual(current, third)
    XCTAssertEqual(
        try fixture.store.readStart(for: fixture.binding.workBinding, intent: fixture.startIntent),
        first)
    XCTAssertEqual(
        try startWithRetainedAssembly(
            fixture: fixture, template: template, run: fixture.run,
            intent: fixture.startIntent),
        first)
    XCTAssertEqual(
        try fixture.store.readStart(for: fixture.binding.workBinding, intent: nextIntent),
        second)
    XCTAssertEqual(
        try fixture.store.readStart(for: fixture.binding.workBinding, intent: thirdIntent),
        third)
}

func test_workLaunchManifestTamperAndOversizeFailBeforeTrustingRecord() throws {
    let fixture = try WorkLaunchManifestFixture()
    defer { fixture.remove() }

    let record = try fixture.store.save(fixture.manifest)
    let payloadURL = fixture.store.manifestURL(forDigest: record.manifestDigest)
    var tampered = try Data(contentsOf: payloadURL)
    tampered.append(UInt8(ascii: "x"))
    try tampered.write(to: payloadURL)
    try expectWorkLaunchError({ _ = try fixture.store.read(fixture.identity) }) {
        if case .tamperedRecord = $0 { return true }
        if case .digestMismatch = $0 { return true }
        if case .malformedRecord = $0 { return true }
        return false
    }

    try tampered.write(to: payloadURL)
    let oversized = Data(repeating: UInt8(ascii: "x"), count: fixture.store.limits.maximumRecordBytes + 1)
    try oversized.write(to: payloadURL)
    try expectWorkLaunchError({ _ = try fixture.store.read(fixture.identity) }) {
        if case .recordTooLarge = $0 { return true }
        return false
    }
}

func test_workLaunchManifestRejectsWrongAuthorityAndSymlink() throws {
    let fixture = try WorkLaunchManifestFixture()
    defer { fixture.remove() }

    let foreign = WorkLaunchManifest(
        identity: WorkLaunchManifestIdentity(
            work: WorkRef(workHostID: "host-foreign", workID: fixture.work.workID),
            session: fixture.session, sessionAttachment: fixture.attachment, run: fixture.run),
        startIntent: WorkLaunchStartIntent(
            client: fixture.startIntent.client, commandID: fixture.startIntent.commandID,
            causalWorkCursor: JournalCursor(
                journal: .work(WorkRef(workHostID: "host-foreign", workID: fixture.work.workID)),
                sequence: fixture.startIntent.causalWorkCursor.sequence),
            bodyDigest: fixture.startIntent.bodyDigest),
        workspace: fixture.manifest.workspace, runtime: fixture.manifest.runtime,
        initialInputBodyReference: fixture.manifest.initialInputBodyReference,
        provenance: fixture.manifest.provenance)
    try expectWorkLaunchError({ _ = try fixture.store.save(foreign) }) {
        if case .wrongAuthority = $0 { return true }
        if case .identityMismatch = $0 { return true }
        return false
    }

    let record = try fixture.store.save(fixture.manifest)
    let payloadURL = fixture.store.manifestURL(forDigest: record.manifestDigest)
    let target = fixture.root.appending(path: "payload-target.json")
    try FileManager.default.removeItem(at: payloadURL)
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: payloadURL, withDestinationURL: target)
    try expectWorkLaunchError({ _ = try fixture.store.read(fixture.identity) }) {
        if case .symlinkOrNonRegularFile = $0 { return true }
        return false
    }
}

func test_workLaunchManifestGenerationFenceRefusesStaleReplacementAndRemoval() throws {
    let fixture = try WorkLaunchManifestFixture()
    defer { fixture.remove() }

    let first = try fixture.store.save(fixture.manifest)
    let changed = WorkLaunchManifest(
        identity: fixture.manifest.identity,
        startIntent: WorkLaunchStartIntent(
            client: fixture.startIntent.client, commandID: "changed-start",
            causalWorkCursor: fixture.startIntent.causalWorkCursor,
            bodyDigest: fixture.startIntent.bodyDigest),
        workspace: fixture.manifest.workspace, runtime: fixture.manifest.runtime,
        initialInputBodyReference: fixture.manifest.initialInputBodyReference,
        promptAssembly: fixture.manifest.promptAssembly,
        systemPromptBodyReference: fixture.manifest.systemPromptBodyReference,
        contextPolicy: fixture.manifest.contextPolicy,
        recordingPolicy: fixture.manifest.recordingPolicy,
        resumePolicy: fixture.manifest.resumePolicy,
        reasoningPolicy: fixture.manifest.reasoningPolicy,
        budgetPolicy: fixture.manifest.budgetPolicy,
        goal: fixture.manifest.goal,
        hooks: fixture.manifest.hooks,
        peerScheduler: fixture.manifest.peerScheduler,
        provenance: fixture.manifest.provenance)
    let second = try fixture.store.save(changed)
    XCTAssertEqual(second.generation.generation, first.generation.generation + 1)
    try expectWorkLaunchError({
        _ = try fixture.store.replace(fixture.manifest, expected: first.generation)
    }) {
        if case .generationMismatch = $0 { return true }
        return false
    }
    try expectWorkLaunchError({ try fixture.store.remove(fixture.identity, expected: first.generation) }) {
        if case .generationMismatch = $0 { return true }
        return false
    }
    try fixture.store.remove(fixture.identity, expected: second.generation)
    XCTAssertNil(try fixture.store.read(fixture.identity))
}

func test_workLaunchPromptAssemblyRetainsSourcesAndReplaysExactBytes() throws {
    let fixture = try WorkLaunchManifestFixture()
    defer { fixture.remove() }

    let marker = "## source-looking-marker \(fixture.root.path)"
    let source = try PromptSource(
        sourceID: "generated:marker",
        kind: .generated,
        label: "Generated context",
        identity: "/private/ambient/producer-secret",
        fullBody: marker,
        deliveredBody: marker,
        renderedBody: "\n\n<generated>\n\(marker)\n</generated>",
        deliveredByteOffsetInRendered: Data("\n\n<generated>\n".utf8).count)
    let assembly = try SystemPromptAssembly(
        text: source.renderedBody,
        sources: [source])
    let retained: WorkLaunchPromptAssembly
    do {
        retained = try fixture.store.retainPromptAssembly(
            assembly,
            authority: .workHost(fixture.host),
            provenance: WorkLaunchManifestProvenance(source: "start.prompt.v1"))
    } catch {
        XCTFail("retain prompt assembly failed: \(error)")
        throw error
    }

    let metadata = try JSONEncoder().encode(retained)
    XCTAssertFalse(metadata.range(of: Data(marker.utf8)) != nil)
    XCTAssertFalse(metadata.range(of: Data("/private/ambient/producer-secret".utf8)) != nil)
    XCTAssertFalse(metadata.range(of: Data(fixture.root.path.utf8)) != nil)

    let manifest = WorkLaunchManifest(
        identity: fixture.identity,
        startIntent: fixture.startIntent,
        workspace: fixture.manifest.workspace,
        runtime: fixture.manifest.runtime,
        initialInputBodyReference: fixture.bodyReference,
        promptAssembly: retained,
        systemPromptBodyReference: retained.flattenedBodyReference,
        contextPolicy: fixture.manifest.contextPolicy,
        recordingPolicy: fixture.manifest.recordingPolicy,
        resumePolicy: fixture.manifest.resumePolicy,
        reasoningPolicy: fixture.manifest.reasoningPolicy,
        budgetPolicy: fixture.manifest.budgetPolicy,
        goal: fixture.manifest.goal,
        hooks: fixture.manifest.hooks,
        peerScheduler: fixture.manifest.peerScheduler,
        provenance: fixture.manifest.provenance)
    do {
        _ = try fixture.store.save(manifest)
    } catch {
        XCTFail("save prompt manifest failed: \(error)")
        throw error
    }
    let replayed: SystemPromptAssembly
    do {
        replayed = try fixture.store.resolvePromptAssembly(for: manifest)
    } catch {
        XCTFail("resolve prompt assembly failed: \(error)")
        throw error
    }
    XCTAssertEqual(replayed.flattenedText, assembly.flattenedText)
    XCTAssertEqual(replayed.sources.map(\.sourceID), ["generated:marker"])
    XCTAssertEqual(replayed.sources.map(\.kind), assembly.sources.map(\.kind))
    XCTAssertEqual(replayed.sources.map(\.status), assembly.sources.map(\.status))
    XCTAssertEqual(replayed.sources[0].deliveredDigest, source.deliveredDigest)
    XCTAssertEqual(replayed.sources[0].renderedDigest, source.renderedDigest)
}

func test_workLaunchPreparedStartReservationUsesRecordBound() throws {
    let fixture = try WorkLaunchManifestFixture()
    defer { fixture.remove() }

    let workspace = fixture.root.appending(
        path: "prepared-start-workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try Data(String(repeating: "context line\n", count: 900).utf8).write(
        to: workspace.appending(path: "AGENTS.md"))
    let assembly = try SystemPromptAssembly.build(
        cwd: workspace.path,
        skills: "# Skills\n" + String(repeating: "skill material\n", count: 80),
        memory: "# Memory\n" + String(repeating: "memory material\n", count: 80),
        includeContextFiles: true)
    XCTAssertTrue(assembly.sources.contains { $0.kind == .contextFile && $0.status == .present })
    XCTAssertTrue(assembly.sources.contains { $0.kind == .skill })
    XCTAssertTrue(assembly.sources.contains { $0.kind == .memory })
    let retainedAssembly = try fixture.store.retainPromptAssembly(
        assembly, authority: .workHost(fixture.host),
        provenance: WorkLaunchManifestProvenance(source: "start.prompt.v1"))

    let launchWorkspace = WorkLaunchWorkspace(locator: workspace.path, policy: .workspace)
    let draft = WorkLaunchManifestDraft(
        workspace: launchWorkspace,
        runtime: fixture.manifest.runtime,
        configuration: WorkServiceWorkConfiguration(includeContextFiles: true),
        requestedCapabilities: [],
        contextPolicy: WorkLaunchContextPolicy(includeContextFiles: true))
    let createKey = WorkLaunchCreateKey(
        client: fixture.startIntent.client,
        requestDigest: try WorkLaunchCreateKey.requestDigest(
            configuration: draft.configuration,
            requestedCapabilities: draft.requestedCapabilities),
        commandID: "create-large-prepared-start",
        causalControlCursor: fixture.controlCursor)
    let retainedDraft = try fixture.store.retain(draft, for: createKey)
    let template = try fixture.store.publishTemplate(
        retainedDraft, binding: fixture.binding.workBinding)
    let admission = try fixture.store.reserveStart(
        template, binding: fixture.binding.workBinding, run: fixture.run,
        startIntent: fixture.startIntent,
        initialInputBodyReference: fixture.bodyReference)
    guard case .winner(let reservation) = admission else {
        XCTFail("first Start must win the reservation")
        return
    }
    let prepared = try fixture.store.prepareStart(
        reservation, promptAssembly: retainedAssembly)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let preparedBytes = try encoder.encode(prepared).count
    XCTAssertTrue(preparedBytes > fixture.store.limits.maximumMetadataBytes)
    XCTAssertTrue(preparedBytes <= fixture.store.limits.maximumRecordBytes)

    let reopened = WorkLaunchManifestStore(home: fixture.home)
    XCTAssertEqual(
        try reopened.readStartReservation(for: fixture.binding.workBinding), prepared)
    let retried = try reopened.reserveStart(
        template, binding: fixture.binding.workBinding, run: fixture.run,
        startIntent: fixture.startIntent,
        initialInputBodyReference: fixture.bodyReference)
    guard case .reserved(let exact) = retried else {
        XCTFail("an exact retry must reuse the prepared reservation")
        return
    }
    XCTAssertEqual(exact, prepared)

    let smallRecordStore = WorkLaunchManifestStore(
        home: fixture.home,
        limits: WorkLaunchManifestLimits(maximumRecordBytes: preparedBytes - 1))
    try expectWorkLaunchError({
        _ = try smallRecordStore.readStartReservation(for: fixture.binding.workBinding)
    }) {
        if case .recordTooLarge = $0 { return true }
        return false
    }
}

func test_workLaunchCreateRetentionRequiresExactControlCursorAndRequestDigest() throws {
    let fixture = try WorkLaunchManifestFixture()
    defer { fixture.remove() }
    let draft = WorkLaunchManifestDraft(
        workspace: fixture.manifest.workspace,
        runtime: fixture.manifest.runtime,
        configuration: WorkServiceWorkConfiguration(),
        requestedCapabilities: [])
    let digest = try WorkLaunchCreateKey.requestDigest(
        configuration: draft.configuration, requestedCapabilities: draft.requestedCapabilities)
    // A Create key carries the exact control cursor observed by the host. It is not required
    // to be genesis: another client may have advanced the shared control journal between two
    // Create attempts.
    let advancedCursor = JournalCursor(
        journal: fixture.controlJournal, eventID: "control-event-23", sequence: 23)
    let valid = WorkLaunchCreateKey(
        client: ClientRef("create-client"), requestDigest: digest,
        commandID: "create-command", causalControlCursor: advancedCursor)
    let first = try fixture.store.retain(draft, for: valid)
    let secondKey = WorkLaunchCreateKey(
        client: valid.client, requestDigest: digest,
        commandID: "create-command-2", causalControlCursor: advancedCursor)
    let second = try fixture.store.retain(draft, for: secondKey)
    XCTAssertEqual(try fixture.store.loadRetainedDraft(
        client: valid.client, commandID: valid.commandID,
        causalControlCursor: valid.causalControlCursor, draftDigest: try draft.contentDigest())?.key,
        valid)
    XCTAssertEqual(try fixture.store.loadRetainedDraft(
        client: secondKey.client, commandID: secondKey.commandID,
        causalControlCursor: secondKey.causalControlCursor,
        draftDigest: try draft.contentDigest())?.key, secondKey)

    let reopened = WorkLaunchManifestStore(home: fixture.home)
    XCTAssertEqual(try reopened.loadRetainedDraft(for: valid), first)
    XCTAssertEqual(try reopened.loadRetainedDraft(for: secondKey), second)
    XCTAssertEqual(try reopened.retain(draft, for: valid), first,
                   "an exact duplicate reopens the original retained bytes")

    let changedDraft = WorkLaunchManifestDraft(
        workspace: draft.workspace, runtime: draft.runtime,
        configuration: WorkServiceWorkConfiguration(recordPayloads: true),
        requestedCapabilities: [],
        recordingPolicy: WorkLaunchRecordingPolicy(recordPayloads: true))
    let changedDigest = try WorkLaunchCreateKey.requestDigest(
        configuration: changedDraft.configuration,
        requestedCapabilities: changedDraft.requestedCapabilities)
    let conflictingKey = WorkLaunchCreateKey(
        client: valid.client, requestDigest: changedDigest,
        commandID: valid.commandID, causalControlCursor: advancedCursor)
    try expectWorkLaunchError({
        _ = try reopened.retain(changedDraft, for: conflictingKey)
    }) {
        if case .requestConflict = $0 { return true }
        return false
    }

    let wrongDigest = WorkLaunchCreateKey(
        client: valid.client, requestDigest: "sha256:" + String(repeating: "0", count: 64),
        commandID: valid.commandID, causalControlCursor: advancedCursor)
    try expectWorkLaunchError({ _ = try fixture.store.retain(draft, for: wrongDigest) }) {
        if case .requestConflict = $0 { return true }
        return false
    }

    let zeroWithEvent = WorkLaunchCreateKey(
        client: valid.client, requestDigest: digest, commandID: "zero-with-event",
        causalControlCursor: JournalCursor(
            journal: fixture.controlJournal, eventID: "not-genesis", sequence: 0))
    try expectWorkLaunchError({ _ = try fixture.store.retain(draft, for: zeroWithEvent) }) {
        if case .invalidManifest = $0 { return true }
        return false
    }
    let positiveWithoutEvent = WorkLaunchCreateKey(
        client: valid.client, requestDigest: digest, commandID: "positive-without-event",
        causalControlCursor: JournalCursor(
            journal: fixture.controlJournal, eventID: nil, sequence: 1))
    try expectWorkLaunchError({ _ = try fixture.store.retain(draft, for: positiveWithoutEvent) }) {
        if case .invalidManifest = $0 { return true }
        return false
    }
    for cursor in [
        JournalCursor(journal: fixture.controlJournal, eventID: " \n", sequence: 1),
        JournalCursor(journal: fixture.controlJournal, eventID: "overflow", sequence: Int.max),
        JournalCursor(journal: fixture.controlJournal, eventID: nil, sequence: -1),
    ] {
        let malformed = WorkLaunchCreateKey(
            client: valid.client, requestDigest: digest, commandID: "malformed-cursor",
            causalControlCursor: cursor)
        try expectWorkLaunchError({ _ = try fixture.store.retain(draft, for: malformed) }) {
            if case .invalidManifest = $0 { return true }
            return false
        }
    }
    let wrongJournal = WorkLaunchCreateKey(
        client: valid.client, requestDigest: digest, commandID: "other-command",
        causalControlCursor: JournalCursor(
            journal: fixture.workJournal, eventID: "foreign-control-event", sequence: 23))
    try expectWorkLaunchError({ _ = try fixture.store.retain(draft, for: wrongJournal) }) {
        if case .identityMismatch = $0 { return true }
        return false
    }
}

private func runtimeAdoptionFixture(
    _ fixture: WorkLaunchManifestFixture
) -> RuntimeAdoptionRecord {
    let descriptor = RuntimeHost.AdoptionDescriptor(
        endpoint: RuntimeHost.SocketEndpoint(path: "/tmp/aviary-runtime-test.sock"),
        identity: RuntimeHost.HostIdentity(
            hostID: fixture.host.workHostID, instanceID: "runtime-instance"))
    let event = EventRef(journal: fixture.workJournal, eventID: "runtime-adoption")
    return RuntimeAdoptionRecord(
        descriptor: descriptor, work: fixture.work, session: fixture.session, run: fixture.run,
        sourceEvent: event,
        sourceCursor: JournalCursor(journal: fixture.workJournal, eventID: event.eventID, sequence: 4))
}

func test_runtimeAdoptionRecordNormalizesLivenessAndGenerationFence() throws {
    let fixture = try WorkLaunchManifestFixture()
    defer { fixture.remove() }
    let store = RuntimeAdoptionRecordStore(home: fixture.home)
    let original = runtimeAdoptionFixture(fixture)
    let first = try store.save(original)
    let second = try store.save(original)
    let payloadURL = store.recordURL(forDigest: first.generation.digest)
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: payloadURL)) as? [String: Any])
    var nested = try XCTUnwrap(object["record"] as? [String: Any])
    nested["isLivenessProof"] = true
    object["record"] = nested
    try JSONSerialization.data(withJSONObject: object).write(to: payloadURL)

    let normalized = try XCTUnwrap(
        try store.read(work: fixture.work, session: fixture.session, run: fixture.run))
    XCTAssertFalse(normalized.record.isLivenessProof)
    XCTAssertEqual(normalized.record, original)

    try expectRuntimeAdoptionError({
        _ = try store.replace(original, expected: first.generation)
    }) {
        if case .generationMismatch = $0 { return true }
        return false
    }
    try expectRuntimeAdoptionError({
        try store.remove(work: fixture.work, session: fixture.session, run: fixture.run,
                         expected: first.generation)
    }) {
        if case .generationMismatch = $0 { return true }
        return false
    }
    try store.remove(work: fixture.work, session: fixture.session, run: fixture.run,
                     expected: second.generation)
    XCTAssertNil(try store.read(work: fixture.work, session: fixture.session, run: fixture.run))
}

func test_runtimeAdoptionRecordRejectsWrongAuthorityAndOversizedRecord() throws {
    let fixture = try WorkLaunchManifestFixture()
    defer { fixture.remove() }
    let store = RuntimeAdoptionRecordStore(home: fixture.home)
    let valid = runtimeAdoptionFixture(fixture)
    let foreign = RuntimeAdoptionRecord(
        descriptor: valid.descriptor,
        work: WorkRef(workHostID: "host-foreign", workID: fixture.work.workID),
        session: valid.session, run: valid.run,
        sourceEvent: valid.sourceEvent, sourceCursor: valid.sourceCursor)
    try expectRuntimeAdoptionError({ _ = try store.save(foreign) }) {
        if case .wrongAuthority = $0 { return true }
        return false
    }

    let small = RuntimeAdoptionRecordStore(home: fixture.home, maximumRecordBytes: 64)
    try expectRuntimeAdoptionError({ _ = try small.save(valid) }) {
        if case .recordTooLarge = $0 { return true }
        if case .ioFailure = $0 { return true }
        return false
    }
}

let casesWorkLaunchManifest: [Case] = [
    ("phase3 launch manifest: exact body digest and no raw prompt", {
        try test_workLaunchManifestRoundTripsWithExactBodyDigestAndNoPromptBody()
    }),
    ("phase3 launch manifest: two-stage reserved identity binding", {
        try test_workLaunchManifestTwoStageBindingUsesReservedIdentity()
    }),
    ("phase3 launch manifest: request retention and Start CAS", {
        try test_workLaunchManifestRetentionTemplateAndStartAreIdempotentAndCAS()
    }),
    ("phase3 launch manifest: tamper and oversize fail closed", {
        try test_workLaunchManifestTamperAndOversizeFailBeforeTrustingRecord()
    }),
    ("phase3 launch manifest: wrong authority and symlink fail closed", {
        try test_workLaunchManifestRejectsWrongAuthorityAndSymlink()
    }),
    ("phase3 launch manifest: stale replacement and removal are fenced", {
        try test_workLaunchManifestGenerationFenceRefusesStaleReplacementAndRemoval()
    }),
    ("phase3 launch prompt: source bodies are durable and byte-exact", {
        try test_workLaunchPromptAssemblyRetainsSourcesAndReplaysExactBytes()
    }),
    ("phase3 launch prompt: prepared Start reservation uses record bound", {
        try test_workLaunchPreparedStartReservationUsesRecordBound()
    }),
    ("phase3 launch create: control cursor and request digest are exact", {
        try test_workLaunchCreateRetentionRequiresExactControlCursorAndRequestDigest()
    }),
    ("phase3 runtime adoption: liveness is normalized and generations fenced", {
        try test_runtimeAdoptionRecordNormalizesLivenessAndGenerationFence()
    }),
    ("phase3 runtime adoption: authority and size are bounded", {
        try test_runtimeAdoptionRecordRejectsWrongAuthorityAndOversizedRecord()
    }),
]
