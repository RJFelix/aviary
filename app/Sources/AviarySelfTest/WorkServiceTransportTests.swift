import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AviaryCore

private let transportHost = WorkHostRef("transport-host")
private let transportWork = WorkRef(workHostID: transportHost.workHostID, workID: "work-1")
private let transportJournal = JournalRef.work(transportWork, journalID: "work-journal")
private let transportClientA = ClientRef("transport-a")
private let transportClientB = ClientRef("transport-b")

private func transportReadCursor(
    _ attachment: WorkServiceClientAttachment,
    journal: JournalRef
) -> JournalCursor? {
    attachment.readAcknowledgements.first { $0.target.journal == journal }?.cursor
}

private struct RejectingTransportPrincipalBinding: WorkServiceTransportPrincipalBinding {
    func accepts(claimedClient: ClientRef) -> Bool { false }
}

private func transportBody() -> (reference: TimelineBodyReference, data: Data) {
    let data = Data("transport-artifact-body".utf8)
    let digest = "sha256:" + AviarySHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
    return (
        TimelineBodyReference(
            authority: transportJournal, referenceID: "artifact-body",
            mediaType: "text/plain", byteCount: data.count, digest: digest), data)
}

private let transportCapabilities: Set<WorkServiceCapability> = [
    .observe, .control, .start, .send, .steer, .queue, .hold, .cancel, .end,
    .inspectArtifacts, .createSession,
]

private func transportAuthorizer() -> WorkServiceCapabilityPolicy {
    WorkServiceCapabilityPolicy(grantsByClient: [
        transportClientA: transportCapabilities,
        transportClientB: [.observe, .control, .start],
    ])
}

private func transportSocketPath() -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aw-\(UUID().uuidString.lowercased())", isDirectory: true)
    try! FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    return root.appendingPathComponent("service.sock").path
}

private func transportEnvelopePayload<T: Encodable>(_ value: T) throws -> JSONValue {
    JSONValue.parse(try JSONEncoder().encode(value)) ?? .null
}

private func transportFixture(
    path: String,
    principalBinding: (any WorkServiceTransportPrincipalBinding)? = nil
) async throws -> (
    service: InMemoryWorkService,
    server: WorkServiceUnixSocketServer,
    clientA: WorkServiceUnixSocketClient,
    cursor: JournalCursor,
    controlCursor: JournalCursor
) {
    let service = InMemoryWorkService(
        host: transportHost, instanceID: "transport-instance", startIdentity: "transport-start",
        authorizer: transportAuthorizer())
    let cursor = JournalCursor(journal: transportJournal, sequence: 0)
    let controlCursor = JournalCursor(
        journal: JournalRef.workHost(transportHost), sequence: 0)
    let body = transportBody()
    try await service.register(.init(
        work: transportWork, journal: transportJournal, cursor: cursor,
        configuration: .init(modelID: "transport-model"),
        artifacts: [WorkServiceArtifactDescriptor(
            artifactID: "artifact-1", work: transportWork, label: "transport artifact",
            mediaType: "text/plain", byteCount: body.data.count,
            digest: body.reference.digest, bodyReference: body.reference)],
        bodies: [body.reference: body.data]))
    let server = WorkServiceUnixSocketServer(
        endpoint: WorkServiceTransportEndpoint(path: path), service: service,
        principalBinding: principalBinding)
    try await server.start()
    let clientA = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: transportClientA)
    return (service, server, clientA, cursor, controlCursor)
}

private func stopTransport(
    _ server: WorkServiceUnixSocketServer,
    _ clients: [WorkServiceUnixSocketClient]
) async {
    for client in clients { await client.close() }
    let root = URL(fileURLWithPath: (await server.endpoint).path)
        .deletingLastPathComponent()
    await server.stop()
    try? FileManager.default.removeItem(at: root)
}

func test_workServiceTransportHandshakeAndReadProjection() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    do {
        let handshake = try await fixture.clientA.connect(build: "transport-test")
        XCTAssertTrue(handshake.accepted)
        XCTAssertEqual(handshake.negotiatedVersion, WorkServiceProtocol.currentVersion)
        XCTAssertEqual(handshake.host, transportHost)
        XCTAssertEqual(handshake.hostInstance.instanceID, "transport-instance")
        XCTAssertTrue(handshake.capabilities.contains(.observe))
        XCTAssertFalse(handshake.capabilities.contains(.complete))

        let page = try await fixture.clientA.listWorks(.init(
            client: transportClientA, pageSize: WorkServiceBounds.maxPageSize))
        XCTAssertEqual(page.works.count, 1)
        XCTAssertEqual(page.works.first?.work, transportWork)
        XCTAssertEqual(page.works.first?.journal, transportJournal)
        XCTAssertEqual(page.works.first?.configuration.modelID, "transport-model")
        let described = try await fixture.clientA.describeWork(.init(
            work: transportWork, journal: transportJournal, client: transportClientA))
        XCTAssertEqual(described, page.works.first)
        let created = try await fixture.clientA.createWork(.init(
            client: transportClientA, commandID: "transport-create",
            causalControlCursor: handshake.controlCursor,
            configuration: .init(modelID: "created-model"),
            requestedCapabilities: [.observe, .control, .createSession, .send]))
        XCTAssertEqual(created.work.configuration.modelID, "created-model")
        XCTAssertTrue(created.attachment.readAcknowledgements.isEmpty)
        do {
            _ = try await fixture.clientA.createWork(.init(
                client: transportClientA, commandID: "transport-create",
                causalControlCursor: handshake.controlCursor,
                configuration: .init(
                    modelID: "changed-model"),
                requestedCapabilities: [.observe, .control, .createSession, .send]))
            XCTFail("transport redaction must preserve exact host-side retry comparison")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .invalidRequest)
        }
        let createSessionRequest = WorkServiceCreateSessionRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, client: transportClientA,
            commandID: "transport-create-session",
            causalControlCursor: created.controlCursor,
            causalWorkCursor: created.workCursor,
            requestedCapabilities: [.observe, .send])
        let createdSession = try await fixture.clientA.createSession(createSessionRequest)
        XCTAssertEqual(createdSession.state, .accepted)
        XCTAssertEqual(createdSession.relationship?.publication, .mirrored)
        XCTAssertEqual(createdSession.sessionCursor?.sequence, 3)
        XCTAssertTrue(createdSession.work.sessionAttachments.contains {
            $0.sessionAttachment == createdSession.sessionAttachment
        })
        let baseAttachment = try XCTUnwrap(createdSession.attachment)
        let baseRelationship = try XCTUnwrap(createdSession.relationship)
        let baseSessionCursor = try XCTUnwrap(createdSession.sessionCursor)
        let requestEnvelope = WorkServiceTransportRequestEnvelope(
            id: "transport-create-session-correlation", operation: .createSession,
            client: transportClientA,
            payload: try transportEnvelopePayload(createSessionRequest))
        func replacingRelationship(
            publication: WorkServiceSessionAttachmentPublication? = nil,
            causalSessionCursor: JournalCursor? = nil,
            sessionCursor: JournalCursor? = nil,
            causalWorkCursor: JournalCursor? = nil,
            resultingWorkCursor: JournalCursor? = nil,
            capabilities: Set<WorkServiceCapability>? = nil,
            isAttached: Bool? = nil
        ) -> WorkServiceSessionAttachmentDescriptor {
            WorkServiceSessionAttachmentDescriptor(
                session: baseRelationship.session,
                sessionJournal: baseRelationship.sessionJournal,
                sessionAttachment: baseRelationship.sessionAttachment,
                publication: publication ?? baseRelationship.publication,
                causalSessionCursor: causalSessionCursor ?? baseRelationship.causalSessionCursor,
                sessionCursor: sessionCursor ?? baseRelationship.sessionCursor,
                causalWorkCursor: causalWorkCursor ?? baseRelationship.causalWorkCursor,
                resultingWorkCursor: resultingWorkCursor ?? baseRelationship.resultingWorkCursor,
                capabilities: capabilities ?? baseRelationship.capabilities,
                isAttached: isAttached ?? baseRelationship.isAttached)
        }
        func replacingWork(
            attachments: [WorkServiceClientAttachment]? = nil,
            relationship: WorkServiceSessionAttachmentDescriptor? = nil
        ) throws -> WorkServiceWorkDescriptor {
            try WorkServiceWorkDescriptor(
                work: createdSession.work.work, journal: createdSession.work.journal,
                recordedDisposition: createdSession.work.recordedDisposition,
                execution: createdSession.work.execution,
                currentRun: createdSession.work.currentRun,
                currentRunSession: createdSession.work.currentRunSession,
                currentRunSessionAttachment: createdSession.work.currentRunSessionAttachment,
                configuration: createdSession.work.configuration,
                hostObservation: createdSession.work.hostObservation,
                attachments: attachments ?? createdSession.work.attachments,
                sessionAttachments: [relationship ?? baseRelationship],
                artifacts: createdSession.work.artifacts,
                omissions: createdSession.work.omissions)
        }
        func replacingResponse(
            work: WorkServiceWorkDescriptor,
            attachment: WorkServiceClientAttachment,
            relationship: WorkServiceSessionAttachmentDescriptor,
            sessionCursor: JournalCursor,
            controlCursor: JournalCursor? = nil
        ) throws -> WorkServiceCreateSessionResponse {
            let resultingControlCursor = controlCursor ?? createdSession.controlCursor
            let receipt = WorkServiceControlReceipt(
                operation: createdSession.receipt.operation,
                work: createdSession.receipt.work,
                commandID: createdSession.receipt.commandID,
                state: createdSession.receipt.state,
                host: createdSession.receipt.host,
                causalControlCursor: createdSession.receipt.causalControlCursor,
                resultingControlCursor: resultingControlCursor,
                authorization: createdSession.receipt.authorization,
                outcome: createdSession.receipt.outcome,
                rejection: createdSession.receipt.rejection,
                diagnostic: createdSession.receipt.diagnostic)
            return WorkServiceCreateSessionResponse(
                work: work, session: createdSession.session,
                sessionJournal: createdSession.sessionJournal,
                sessionAttachment: createdSession.sessionAttachment,
                attachment: attachment, relationship: relationship,
                workCursor: createdSession.workCursor, sessionCursor: sessionCursor,
                controlCursor: resultingControlCursor,
                authorization: createdSession.authorization,
                commandID: createdSession.commandID, state: createdSession.state,
                host: createdSession.host,
                causalControlCursor: createdSession.causalControlCursor,
                causalWorkCursor: createdSession.causalWorkCursor,
                receipt: receipt)
        }
        let reducedAuthorization = WorkServiceAuthorizationOutcome(
            requested: createdSession.authorization.requested,
            granted: [.observe], denied: [.send])
        let forgedAttachment = WorkServiceClientAttachment(
            attachment: baseAttachment.attachment, client: baseAttachment.client,
            session: baseAttachment.session, sessionJournal: baseAttachment.sessionJournal,
            sessionAttachment: baseAttachment.sessionAttachment,
            authorization: reducedAuthorization,
            readAcknowledgements: baseAttachment.readAcknowledgements)
        let nonbaseline = JournalCursor(
            journal: baseRelationship.sessionJournal,
            eventID: "nonbaseline", sequence: 1)
        let shortenedSessionCursor = JournalCursor(
            journal: baseRelationship.sessionJournal,
            eventID: "short-session", sequence: 2)
        let reusedAttachment = WorkServiceClientAttachment(
            attachment: createSessionRequest.attachment,
            client: baseAttachment.client,
            session: baseAttachment.session,
            sessionJournal: baseAttachment.sessionJournal,
            sessionAttachment: baseAttachment.sessionAttachment,
            authorization: baseAttachment.authorization,
            readAcknowledgements: baseAttachment.readAcknowledgements)
        let reusedAttachmentDescriptor = try replacingWork(attachments:
            createdSession.work.attachments.filter {
                $0.attachment != baseAttachment.attachment
                    && $0.attachment != createSessionRequest.attachment
            } + [reusedAttachment])
        let skippedControlCursor = JournalCursor(
            journal: createdSession.controlCursor.journal,
            eventID: "skipped-control-event",
            sequence: createSessionRequest.causalControlCursor.sequence + 3)
        let overflowWorkCursor = JournalCursor(
            journal: baseRelationship.causalWorkCursor.journal,
            eventID: "overflow-causal-work", sequence: Int.max)
        let mutants: [(String, WorkServiceCreateSessionResponse)] = [
            ("descriptor omits minted client attachment", try replacingResponse(
                work: try replacingWork(attachments: []), attachment: baseAttachment,
                relationship: baseRelationship, sessionCursor: baseSessionCursor)),
            ("client attachment authorization differs", try replacingResponse(
                // A changed current grant is valid only when the descriptor carries the same
                // current attachment. Keep the descriptor's immutable publication attachment
                // here so this mutant remains a forged, uncorrelated response.
                work: try replacingWork(attachments: [baseAttachment]),
                attachment: forgedAttachment, relationship: baseRelationship,
                sessionCursor: baseSessionCursor)),
            ("relationship capabilities differ", try {
                let relationship = replacingRelationship(capabilities: [.observe])
                return try replacingResponse(
                    work: try replacingWork(relationship: relationship), attachment: baseAttachment,
                    relationship: relationship, sessionCursor: baseSessionCursor)
            }()),
            ("relationship is detached", try {
                let relationship = replacingRelationship(isAttached: false)
                return try replacingResponse(
                    work: try replacingWork(relationship: relationship), attachment: baseAttachment,
                    relationship: relationship, sessionCursor: baseSessionCursor)
            }()),
            ("publication contradicts reusable Work", try {
                let relationship = replacingRelationship(publication: .terminalReference)
                return try replacingResponse(
                    work: try replacingWork(relationship: relationship), attachment: baseAttachment,
                    relationship: relationship, sessionCursor: baseSessionCursor)
            }()),
            ("Session creation does not begin at baseline", try {
                let relationship = replacingRelationship(causalSessionCursor: nonbaseline)
                return try replacingResponse(
                    work: try replacingWork(relationship: relationship), attachment: baseAttachment,
                    relationship: relationship, sessionCursor: baseSessionCursor)
            }()),
            ("Session creation omits one of three events", try {
                let relationship = replacingRelationship(sessionCursor: shortenedSessionCursor)
                return try replacingResponse(
                    work: try replacingWork(relationship: relationship), attachment: baseAttachment,
                    relationship: relationship, sessionCursor: shortenedSessionCursor)
            }()),
            ("minted attachment reuses the authorizing attachment identity", try replacingResponse(
                work: reusedAttachmentDescriptor, attachment: reusedAttachment,
                relationship: baseRelationship, sessionCursor: baseSessionCursor)),
            ("descriptor repeats one client attachment identity", try replacingResponse(
                work: try replacingWork(attachments: [baseAttachment, baseAttachment]),
                attachment: baseAttachment, relationship: baseRelationship,
                sessionCursor: baseSessionCursor)),
            ("control result skips an unobserved journal event", try replacingResponse(
                work: try replacingWork(), attachment: baseAttachment,
                relationship: baseRelationship, sessionCursor: baseSessionCursor,
                controlCursor: skippedControlCursor)),
            ("mirrored causal Work cursor overflows", try {
                let relationship = replacingRelationship(causalWorkCursor: overflowWorkCursor)
                return try replacingResponse(
                    work: try replacingWork(relationship: relationship), attachment: baseAttachment,
                    relationship: relationship, sessionCursor: baseSessionCursor)
            }()),
        ]
        for (label, mutant) in mutants {
            let envelope = WorkServiceTransportResponseEnvelope(
                id: requestEnvelope.id, ok: true,
                data: try transportEnvelopePayload(mutant), hostInstance: createdSession.host)
            do {
                try WorkServiceTransportCodec.validateResponseSemantics(
                    envelope, operation: requestEnvelope.operation)
                try WorkServiceTransportCodec.validateResponseCorrelation(
                    envelope, request: requestEnvelope,
                    expectedHostInstance: createdSession.host)
                XCTFail("transport accepted forged createSession response: \(label)")
            } catch WorkServiceTransportError.invalidResponse {
                XCTAssertTrue(true)
            }
        }
        // A structured stale rejection must survive the wire as a typed response. In particular,
        // its authorization tuple describes the current request rather than the earlier accepted
        // command, so correlation must not poison the client connection as `invalidResponse`.
        let staleSession = try await fixture.clientA.createSession(.init(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, client: transportClientA,
            commandID: "transport-create-session-stale",
            causalControlCursor: created.controlCursor,
            causalWorkCursor: created.workCursor,
            requestedCapabilities: [.observe]))
        XCTAssertEqual(staleSession.state, .rejected)
        XCTAssertEqual(staleSession.rejection, .staleCursor)
        XCTAssertEqual(staleSession.authorization.requested, [.observe])
        let conflictingSession = try await fixture.clientA.createSession(.init(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, client: transportClientA,
            commandID: "transport-create-session",
            causalControlCursor: created.controlCursor,
            causalWorkCursor: created.workCursor,
            requestedCapabilities: [.observe]))
        XCTAssertEqual(conflictingSession.state, .rejected)
        XCTAssertEqual(conflictingSession.rejection, .conflictingCommand)
        XCTAssertEqual(conflictingSession.authorization.requested, [.observe])
        let stillConnected = try await fixture.clientA.listWorks(.init(
            client: transportClientA, pageSize: WorkServiceBounds.maxPageSize))
        XCTAssertFalse(stillConnected.works.isEmpty)
        await stopTransport(fixture.server, [fixture.clientA])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA])
        throw error
    }
}

func test_workServiceTransportCreateSessionReplayKeepsMutableAttachmentCurrent()
    async throws {
    let path = transportSocketPath()
    let socketRoot = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)
    let homeRoot = FileManager.default.temporaryDirectory
        .appending(path: "aviary-transport-jbs-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: socketRoot)
        try? FileManager.default.removeItem(at: homeRoot)
    }
    let home = AgentHome(root: homeRoot)
    let host = try home.requirePersistedWorkHost()
    let store = DurableJournalBackedWorkLaunchManifestStore(
        store: WorkLaunchManifestStore(home: home), bodyAuthority: .workHost(host),
        draftResolver: { request in
            WorkLaunchManifestDraft(
                workspace: WorkLaunchWorkspace(
                    locator: "/tmp/transport-jbs", policy: .temporary),
                runtime: WorkLaunchRuntime(
                    providerID: "transport-jbs-provider",
                    modelID: request.configuration.modelID ?? "transport-jbs-model",
                    runtimeVariant: "transport-test"),
                configuration: request.configuration,
                requestedCapabilities: request.requestedCapabilities,
                provenance: WorkLaunchManifestProvenance(source: "transport-jbs-test"))
        },
        reconstructabilityProbe: { _ in true })
    let authorizer = WorkServiceCapabilityPolicy(
        grantsByClient: [transportClientA: transportCapabilities])
    let service = try JournalBackedWorkService(
        home: home, instanceID: "transport-jbs-a", startIdentity: "transport-jbs-start-a",
        authorizer: authorizer, manifestStore: store)
    let server = WorkServiceUnixSocketServer(
        endpoint: WorkServiceTransportEndpoint(path: path), service: service)
    let client = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: transportClientA)
    do {
        try await server.start()
        let handshake = try await client.connect()
        let createRequest = WorkServiceCreateWorkRequest(
            client: transportClientA, commandID: "transport-jbs-create",
            causalControlCursor: handshake.controlCursor,
            configuration: WorkServiceWorkConfiguration(modelID: "transport-jbs-model"),
            requestedCapabilities: [.observe, .control, .createSession, .send])
        let created = try await client.createWork(createRequest)
        let sessionRequest = WorkServiceCreateSessionRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, client: transportClientA,
            commandID: "transport-jbs-session", causalControlCursor: created.controlCursor,
            causalWorkCursor: created.workCursor,
            requestedCapabilities: [.observe, .control, .send])
        let first = try await client.createSession(sessionRequest)
        let firstAttachment = try XCTUnwrap(first.attachment)
        let firstAuthorization = first.authorization
        let firstRelationship = try XCTUnwrap(first.relationship)
        let updated = try await client.updateCapabilities(.init(
            work: created.work.work, journal: created.work.journal,
            attachment: firstAttachment.attachment, client: transportClientA,
            requestedCapabilities: [.observe, .control], commandID: "transport-jbs-update",
            causalControlCursor: first.controlCursor))
        XCTAssertEqual(updated.state, .accepted)
        XCTAssertEqual(
            Set(try XCTUnwrap(updated.attachment).authorization.granted), [.observe, .control])

        // Transport must accept mutable current capabilities while preserving the immutable
        // CreateSession authorization and relationship in the duplicate response.
        let duplicate = try await client.createSession(sessionRequest)
        XCTAssertEqual(duplicate.state, .duplicate)
        XCTAssertEqual(duplicate.authorization, firstAuthorization)
        XCTAssertEqual(duplicate.relationship, firstRelationship)
        XCTAssertEqual(
            Set(try XCTUnwrap(duplicate.attachment).authorization.granted),
            [.observe, .control])
        XCTAssertTrue(duplicate.work.attachments.contains {
            $0.attachment == firstAttachment.attachment
                && $0.authorization.granted == [.observe, .control]
        })

        // A later Session publication advances the Work journal. An exact CreateSession retry
        // must still replay the immutable first relationship while projecting the current
        // attachment row and the newer host observation over the Unix socket.
        let advanced = try await client.createSession(.init(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, client: transportClientA,
            commandID: "transport-jbs-session-advanced",
            causalControlCursor: updated.resultingControlCursor,
            causalWorkCursor: first.workCursor,
            requestedCapabilities: [.observe]))
        XCTAssertEqual(advanced.state, .accepted)
        XCTAssertEqual(advanced.relationship?.publication, .mirrored)
        XCTAssertTrue(advanced.workCursor.sequence > first.workCursor.sequence)

        let advancedDuplicate = try await client.createSession(sessionRequest)
        XCTAssertEqual(advancedDuplicate.state, .duplicate)
        XCTAssertEqual(advancedDuplicate.relationship, firstRelationship)
        XCTAssertEqual(advancedDuplicate.attachment?.attachment, first.attachment?.attachment)
        XCTAssertEqual(
            Set(try XCTUnwrap(advancedDuplicate.attachment).authorization.granted),
            [.observe, .control])
        XCTAssertEqual(advancedDuplicate.workCursor, first.workCursor)
        XCTAssertTrue(advancedDuplicate.work.attachments.contains {
            $0.attachment == firstAttachment.attachment
                && $0.authorization.granted == [.observe, .control]
        })

        // A missing attachment in a duplicate response is forged while the current descriptor
        // still carries the exact row; the transport correlation boundary must reject it.
        let forgedOmission = WorkServiceCreateSessionResponse(
            work: duplicate.work, session: duplicate.session,
            sessionJournal: duplicate.sessionJournal,
            sessionAttachment: duplicate.sessionAttachment, attachment: nil,
            relationship: duplicate.relationship, workCursor: duplicate.workCursor,
            sessionCursor: duplicate.sessionCursor, controlCursor: duplicate.controlCursor,
            authorization: duplicate.authorization, commandID: duplicate.commandID,
            state: .duplicate, host: duplicate.host,
            causalControlCursor: duplicate.causalControlCursor,
            causalWorkCursor: duplicate.causalWorkCursor, receipt: duplicate.receipt)
        let requestEnvelope = WorkServiceTransportRequestEnvelope(
            id: "transport-jbs-session", operation: .createSession,
            client: transportClientA, payload: try transportEnvelopePayload(sessionRequest))
        let omissionEnvelope = WorkServiceTransportResponseEnvelope(
            id: requestEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedOmission), hostInstance: duplicate.host)
        do {
            try WorkServiceTransportCodec.validateResponseSemantics(
                omissionEnvelope, operation: .createSession)
            try WorkServiceTransportCodec.validateResponseCorrelation(
                omissionEnvelope, request: requestEnvelope, expectedHostInstance: duplicate.host)
            XCTFail("transport accepted a duplicate response omitting a current attachment")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        // A same-ID row with different identity fields is not historical evidence. It must not
        // be accepted merely because the returned attachment has the immutable publication grant.
        let currentAttachment = try XCTUnwrap(duplicate.attachment)
        let forgedRow = WorkServiceClientAttachment(
            attachment: currentAttachment.attachment, client: ClientRef("forged-client"),
            session: currentAttachment.session, sessionJournal: currentAttachment.sessionJournal,
            sessionAttachment: currentAttachment.sessionAttachment,
            authorization: currentAttachment.authorization,
            readAcknowledgements: currentAttachment.readAcknowledgements)
        let forgedDescriptor = try WorkServiceWorkDescriptor(
            work: duplicate.work.work, journal: duplicate.work.journal,
            recordedDisposition: duplicate.work.recordedDisposition,
            execution: duplicate.work.execution, currentRun: duplicate.work.currentRun,
            currentRunSession: duplicate.work.currentRunSession,
            currentRunSessionAttachment: duplicate.work.currentRunSessionAttachment,
            configuration: duplicate.work.configuration,
            hostObservation: duplicate.work.hostObservation, attachments: [forgedRow],
            sessionAttachments: duplicate.work.sessionAttachments,
            artifacts: duplicate.work.artifacts, omissions: duplicate.work.omissions)
        let forgedSameID = WorkServiceCreateSessionResponse(
            work: forgedDescriptor, session: duplicate.session,
            sessionJournal: duplicate.sessionJournal,
            sessionAttachment: duplicate.sessionAttachment,
            attachment: duplicate.attachment, relationship: duplicate.relationship,
            workCursor: duplicate.workCursor, sessionCursor: duplicate.sessionCursor,
            controlCursor: duplicate.controlCursor, authorization: duplicate.authorization,
            commandID: duplicate.commandID, state: .duplicate, host: duplicate.host,
            causalControlCursor: duplicate.causalControlCursor,
            causalWorkCursor: duplicate.causalWorkCursor, receipt: duplicate.receipt)
        let forgedSameIDEnvelope = WorkServiceTransportResponseEnvelope(
            id: requestEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedSameID), hostInstance: duplicate.host)
        do {
            try WorkServiceTransportCodec.validateResponseSemantics(
                forgedSameIDEnvelope, operation: .createSession)
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedSameIDEnvelope, request: requestEnvelope,
                expectedHostInstance: duplicate.host)
            XCTFail("transport accepted a mismatched same-ID attachment row")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        let detached = try await client.detach(.init(
            work: created.work.work, journal: created.work.journal,
            attachment: firstAttachment.attachment, client: transportClientA,
            commandID: "transport-jbs-detach", causalControlCursor: advanced.resultingControlCursor))
        XCTAssertEqual(detached.state, .accepted)
        let historical = try await client.createSession(sessionRequest)
        XCTAssertEqual(historical.state, .duplicate)
        XCTAssertEqual(historical.attachment, first.attachment)
        XCTAssertEqual(historical.authorization, firstAuthorization)
        XCTAssertFalse(historical.work.attachments.contains {
            $0.attachment == firstAttachment.attachment
        })

        // Complete the Work through its canonical journal proof, then replay the same command
        // over a live Unix socket. The immutable mirrored relationship and historical minted
        // attachment remain replayable, while the terminal Work projection stays attachment-free.
        let firstSession = try XCTUnwrap(first.session)
        let firstSessionAttachment = try XCTUnwrap(first.sessionAttachment)
        let workBinding = WorkBinding(
            session: firstSession, work: created.work.work,
            workHost: WorkHostRef(created.work.work.workHostID),
            sessionAttachment: firstSessionAttachment)
        let runBinding = WorkRunBinding(
            workBinding: workBinding, run: RunRef("transport-jbs-terminal-run"))
        let execution = try await RunJournalBundle.openForExecution(
            home: home, binding: runBinding, actorID: "transport-jbs-terminal-execution")
        _ = try await execution.finishRun(outcome: .completed)
        let finishedCursor = try XCTUnwrap(await execution.latestWorkCursor)
        try await execution.closeChecked()
        let terminal = try await RunJournalBundle.openForTerminalMutation(
            home: home, binding: runBinding, actorID: "transport-jbs-terminal-committer")
        let terminalCommand = CommandRef(
            commandID: "transport-jbs-terminal-complete", client: transportClientA,
            sessionAttachment: firstSessionAttachment, causalCursor: finishedCursor)
        let terminalCommits = try await terminal.completeWork(
            detail: "transport terminal replay", command: terminalCommand)
        try await terminal.closeChecked()
        XCTAssertTrue(terminalCommits.count > 0)
        XCTAssertEqual(terminalCommits[0].cursor.sequence, finishedCursor.sequence + 1)

        let terminalDuplicate = try await client.createSession(sessionRequest)
        XCTAssertEqual(terminalDuplicate.state, .duplicate)
        XCTAssertEqual(terminalDuplicate.work.recordedDisposition, .completed)
        XCTAssertEqual(terminalDuplicate.relationship, firstRelationship)
        XCTAssertEqual(terminalDuplicate.attachment, first.attachment)
        XCTAssertEqual(terminalDuplicate.authorization, firstAuthorization)
        XCTAssertEqual(terminalDuplicate.workCursor, first.workCursor)
        XCTAssertFalse(terminalDuplicate.work.attachments.contains {
            $0.attachment == firstAttachment.attachment
        })

        await client.close()
        await server.stop()
        await service.controlJournal.close()

        let restarted = try JournalBackedWorkService(
            home: home, instanceID: "transport-jbs-b", startIdentity: "transport-jbs-start-b",
            authorizer: authorizer, manifestStore: store)
        let restartCreateRequest = WorkServiceCreateWorkRequest(
            client: transportClientA, commandID: createRequest.commandID,
            causalControlCursor: createRequest.causalControlCursor,
            configuration: createRequest.configuration,
            requestedCapabilities: createRequest.requestedCapabilities)
        // Rehydrate the durable Work template before reconnecting the transport. CreateWork's
        // direct retry is the host restart seam; the response under test is the exact
        // CreateSession replay carried over the new socket.
        _ = try await restarted.createWork(restartCreateRequest)
        let restartedPath = transportSocketPath()
        let restartedRoot = URL(fileURLWithPath: restartedPath).deletingLastPathComponent()
        let restartedServer = WorkServiceUnixSocketServer(
            endpoint: WorkServiceTransportEndpoint(path: restartedPath), service: restarted)
        let restartedClient = WorkServiceUnixSocketClient(
            endpoint: WorkServiceTransportEndpoint(path: restartedPath), client: transportClientA)
        defer {
            Task {
                await restartedClient.close()
                await restartedServer.stop()
                await restarted.controlJournal.close()
                try? FileManager.default.removeItem(at: restartedRoot)
            }
        }
        try await restartedServer.start()
        _ = try await restartedClient.connect()
        let reopened = try await restartedClient.createSession(sessionRequest)
        XCTAssertEqual(reopened.state, .duplicate)
        XCTAssertEqual(reopened.attachment, first.attachment)
        XCTAssertEqual(reopened.authorization, firstAuthorization)
        XCTAssertFalse(reopened.work.attachments.contains {
            $0.attachment == firstAttachment.attachment
        })
        await restartedClient.close()
        await restartedServer.stop()
        await restarted.controlJournal.close()
        try? FileManager.default.removeItem(at: restartedRoot)
    } catch {
        await client.close()
        await server.stop()
        await service.controlJournal.close()
        throw error
    }
}

func test_workServiceTransportInMemoryCreateWorkReplayKeepsMutableAttachmentCurrent()
    async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    do {
        let handshake = try await fixture.clientA.connect()
        let request = WorkServiceCreateWorkRequest(
            client: transportClientA, commandID: "in-memory-replay-create",
            causalControlCursor: handshake.controlCursor,
            requestedCapabilities: [.observe, .control, .createSession])
        let created = try await fixture.clientA.createWork(request)
        let originalAttachment = created.attachment
        let updated = try await fixture.clientA.updateCapabilities(.init(
            work: created.work.work, journal: created.work.journal,
            attachment: originalAttachment.attachment, client: transportClientA,
            requestedCapabilities: [.observe], commandID: "in-memory-replay-update",
            causalControlCursor: created.controlCursor))
        let attachedDuplicate = try await fixture.clientA.createWork(request)
        XCTAssertEqual(attachedDuplicate.receipt.state, .duplicate)
        XCTAssertEqual(attachedDuplicate.authorization, created.authorization)
        XCTAssertEqual(attachedDuplicate.attachment.authorization.granted, [.observe])
        XCTAssertTrue(attachedDuplicate.work.attachments.contains {
            $0.attachment == originalAttachment.attachment
                && $0.authorization.granted == [.observe]
        })

        let detached = try await fixture.clientA.detach(.init(
            work: created.work.work, journal: created.work.journal,
            attachment: originalAttachment.attachment, client: transportClientA,
            commandID: "in-memory-replay-detach",
            causalControlCursor: updated.resultingControlCursor))
        XCTAssertEqual(detached.state, .accepted)
        let detachedDuplicate = try await fixture.clientA.createWork(request)
        XCTAssertEqual(detachedDuplicate.receipt.state, .duplicate)
        XCTAssertEqual(detachedDuplicate.attachment, originalAttachment)
        XCTAssertFalse(detachedDuplicate.work.attachments.contains {
            $0.attachment == originalAttachment.attachment
        })
        await stopTransport(fixture.server, [fixture.clientA])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA])
        throw error
    }
}

func test_workServiceTransportRawCorrelationAllowsCanonicalShorthandAndUnobservedWork()
    async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    do {
        let handshake = try await fixture.clientA.connect()
        let created = try await fixture.clientA.createWork(.init(
            client: transportClientA, commandID: "raw-correlation-create",
            causalControlCursor: handshake.controlCursor,
            requestedCapabilities: [.observe, .control, .createSession]))
        let createRequest = WorkServiceCreateSessionRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, client: transportClientA,
            commandID: "raw-correlation-session",
            causalControlCursor: created.controlCursor,
            causalWorkCursor: created.workCursor, requestedCapabilities: [.observe])
        let createdSession = try await fixture.clientA.createSession(createRequest)
        let expectedHost = createdSession.host
        let canonicalAttachment = try XCTUnwrap(createdSession.attachment)
        let createEnvelope = WorkServiceTransportRequestEnvelope(
            id: "raw-correlation-session", operation: .createSession,
            client: transportClientA, payload: try transportEnvelopePayload(createRequest))

        // A durable idle/historical projection need not carry an actor observation. Its journal,
        // relationship, and returned Work cursor still provide the canonical correlation.
        let unobservedWork = try WorkServiceWorkDescriptor(
            work: createdSession.work.work, journal: createdSession.work.journal,
            recordedDisposition: createdSession.work.recordedDisposition,
            execution: createdSession.work.execution, currentRun: createdSession.work.currentRun,
            currentRunSession: createdSession.work.currentRunSession,
            currentRunSessionAttachment: createdSession.work.currentRunSessionAttachment,
            configuration: createdSession.work.configuration, hostObservation: nil,
            attachments: createdSession.work.attachments,
            sessionAttachments: createdSession.work.sessionAttachments,
            artifacts: createdSession.work.artifacts, omissions: createdSession.work.omissions)
        let unobservedSession = WorkServiceCreateSessionResponse(
            work: unobservedWork, session: createdSession.session,
            sessionJournal: createdSession.sessionJournal,
            sessionAttachment: createdSession.sessionAttachment,
            attachment: createdSession.attachment, relationship: createdSession.relationship,
            workCursor: createdSession.workCursor, sessionCursor: createdSession.sessionCursor,
            controlCursor: createdSession.controlCursor,
            authorization: createdSession.authorization, commandID: createdSession.commandID,
            state: createdSession.state, host: createdSession.host,
            causalControlCursor: createdSession.causalControlCursor,
            causalWorkCursor: createdSession.causalWorkCursor, receipt: createdSession.receipt)
        let unobservedEnvelope = WorkServiceTransportResponseEnvelope(
            id: createEnvelope.id, ok: true,
            data: try transportEnvelopePayload(unobservedSession), hostInstance: expectedHost)
        try WorkServiceTransportCodec.validateResponseSemantics(
            unobservedEnvelope, operation: .createSession)
        try WorkServiceTransportCodec.validateResponseCorrelation(
            unobservedEnvelope, request: createEnvelope, expectedHostInstance: expectedHost)

        // A duplicate can be reconciled from its historical receipt after a later detach has
        // removed the old client attachment from the current descriptor. The exact duplicate
        // cursors and returned identities still make this a canonical replay.
        let historicalDuplicateWork = try WorkServiceWorkDescriptor(
            work: createdSession.work.work, journal: createdSession.work.journal,
            recordedDisposition: createdSession.work.recordedDisposition,
            execution: createdSession.work.execution, currentRun: createdSession.work.currentRun,
            currentRunSession: createdSession.work.currentRunSession,
            currentRunSessionAttachment: createdSession.work.currentRunSessionAttachment,
            configuration: createdSession.work.configuration, hostObservation: nil,
            attachments: createdSession.work.attachments.filter {
                $0.attachment != canonicalAttachment.attachment
            }, sessionAttachments: createdSession.work.sessionAttachments,
            artifacts: createdSession.work.artifacts, omissions: createdSession.work.omissions)
        let historicalDuplicateReceipt = WorkServiceControlReceipt(
            operation: .createSession, work: createRequest.work,
            commandID: createRequest.commandID, state: .duplicate, host: expectedHost,
            causalControlCursor: createRequest.causalControlCursor,
            resultingControlCursor: createdSession.controlCursor,
            authorization: createdSession.authorization, outcome: .sessionCreated)
        let historicalDuplicate = WorkServiceCreateSessionResponse(
            work: historicalDuplicateWork, session: createdSession.session,
            sessionJournal: createdSession.sessionJournal,
            sessionAttachment: createdSession.sessionAttachment,
            attachment: canonicalAttachment, relationship: createdSession.relationship,
            workCursor: createdSession.workCursor, sessionCursor: createdSession.sessionCursor,
            controlCursor: createdSession.controlCursor,
            authorization: createdSession.authorization, commandID: createRequest.commandID,
            state: .duplicate, host: expectedHost,
            causalControlCursor: createRequest.causalControlCursor,
            causalWorkCursor: createRequest.causalWorkCursor,
            receipt: historicalDuplicateReceipt)
        let historicalDuplicateEnvelope = WorkServiceTransportResponseEnvelope(
            id: createEnvelope.id, ok: true,
            data: try transportEnvelopePayload(historicalDuplicate), hostInstance: expectedHost)
        try WorkServiceTransportCodec.validateResponseSemantics(
            historicalDuplicateEnvelope, operation: .createSession)
        try WorkServiceTransportCodec.validateResponseCorrelation(
            historicalDuplicateEnvelope, request: createEnvelope,
            expectedHostInstance: expectedHost)

        // Observation, when present, remains a cursor fence rather than becoming optional data.
        let staleObservation = try WorkServiceHostObservation(
            instance: expectedHost, reachability: .observedReachable,
            currentRun: createdSession.work.currentRun,
            currentRunSession: createdSession.work.currentRunSession,
            currentRunSessionAttachment: createdSession.work.currentRunSessionAttachment,
            servedCursor: JournalCursor(journal: createdSession.work.journal, sequence: 0),
            sourceCompleteness: .complete)
        let staleWork = try WorkServiceWorkDescriptor(
            work: createdSession.work.work, journal: createdSession.work.journal,
            recordedDisposition: createdSession.work.recordedDisposition,
            execution: createdSession.work.execution, currentRun: createdSession.work.currentRun,
            currentRunSession: createdSession.work.currentRunSession,
            currentRunSessionAttachment: createdSession.work.currentRunSessionAttachment,
            configuration: createdSession.work.configuration, hostObservation: staleObservation,
            attachments: createdSession.work.attachments,
            sessionAttachments: createdSession.work.sessionAttachments,
            artifacts: createdSession.work.artifacts, omissions: createdSession.work.omissions)
        let staleSession = WorkServiceCreateSessionResponse(
            work: staleWork, session: createdSession.session,
            sessionJournal: createdSession.sessionJournal,
            sessionAttachment: createdSession.sessionAttachment,
            attachment: createdSession.attachment, relationship: createdSession.relationship,
            workCursor: createdSession.workCursor, sessionCursor: createdSession.sessionCursor,
            controlCursor: createdSession.controlCursor,
            authorization: createdSession.authorization, commandID: createdSession.commandID,
            state: createdSession.state, host: createdSession.host,
            causalControlCursor: createdSession.causalControlCursor,
            causalWorkCursor: createdSession.causalWorkCursor, receipt: createdSession.receipt)
        let staleEnvelope = WorkServiceTransportResponseEnvelope(
            id: createEnvelope.id, ok: true,
            data: try transportEnvelopePayload(staleSession), hostInstance: expectedHost)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                staleEnvelope, request: createEnvelope, expectedHostInstance: expectedHost)
            XCTFail("transport accepted a stale served cursor in a present observation")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        let attachCausal = createdSession.controlCursor
        let attachResulting = JournalCursor(
            journal: attachCausal.journal, eventID: "raw-correlation-attach",
            sequence: attachCausal.sequence + 1)
        let attachAuthorization = WorkServiceAuthorizationOutcome(
            requested: [.observe], granted: [.observe], denied: [])
        let attachWork = try WorkServiceWorkDescriptor(
            work: createdSession.work.work, journal: createdSession.work.journal,
            recordedDisposition: createdSession.work.recordedDisposition,
            execution: createdSession.work.execution, currentRun: createdSession.work.currentRun,
            currentRunSession: createdSession.work.currentRunSession,
            currentRunSessionAttachment: createdSession.work.currentRunSessionAttachment,
            configuration: createdSession.work.configuration,
            hostObservation: createdSession.work.hostObservation,
            attachments: createdSession.work.attachments,
            sessionAttachments: createdSession.work.sessionAttachments,
            artifacts: createdSession.work.artifacts, omissions: createdSession.work.omissions)
        let attachRequest = WorkServiceAttachRequest(
            work: createdSession.work.work, journal: createdSession.work.journal,
            client: transportClientA, commandID: "raw-correlation-attach",
            causalControlCursor: attachCausal, requestedCapabilities: [.observe])
        let attachReceipt = WorkServiceControlReceipt(
            operation: .attach, work: attachRequest.work, commandID: attachRequest.commandID,
            state: .accepted, host: expectedHost,
            causalControlCursor: attachCausal, resultingControlCursor: attachResulting,
            authorization: attachAuthorization, outcome: .attached)
        let attachResponse = WorkServiceAttachResponse(
            work: attachWork, attachment: canonicalAttachment,
            authorization: attachAuthorization, commandID: attachRequest.commandID,
            state: .accepted, host: expectedHost,
            causalControlCursor: attachCausal, resultingControlCursor: attachResulting,
            receipt: attachReceipt)
        let attachEnvelope = WorkServiceTransportRequestEnvelope(
            id: attachRequest.commandID, operation: .attach, client: transportClientA,
            payload: try transportEnvelopePayload(attachRequest))
        let attachWire = WorkServiceTransportResponseEnvelope(
            id: attachEnvelope.id, ok: true,
            data: try transportEnvelopePayload(attachResponse), hostInstance: expectedHost)
        try WorkServiceTransportCodec.validateResponseSemantics(attachWire, operation: .attach)
        try WorkServiceTransportCodec.validateResponseCorrelation(
            attachWire, request: attachEnvelope, expectedHostInstance: expectedHost)

        // An exact duplicate still carries the complete canonical tuple and must remain valid.
        let duplicateCausal = attachRequest.causalControlCursor
        let duplicateReceipt = WorkServiceControlReceipt(
            operation: .attach, work: attachRequest.work, commandID: attachRequest.commandID,
            state: .duplicate, host: expectedHost,
            causalControlCursor: duplicateCausal, resultingControlCursor: attachResulting,
            authorization: attachAuthorization, outcome: .attached)
        let duplicateResponse = WorkServiceAttachResponse(
            work: attachWork, attachment: canonicalAttachment,
            authorization: attachAuthorization, commandID: attachRequest.commandID,
            state: .duplicate, host: expectedHost,
            causalControlCursor: duplicateCausal, resultingControlCursor: attachResulting,
            receipt: duplicateReceipt)
        let duplicateWire = WorkServiceTransportResponseEnvelope(
            id: attachEnvelope.id, ok: true,
            data: try transportEnvelopePayload(duplicateResponse), hostInstance: expectedHost)
        try WorkServiceTransportCodec.validateResponseSemantics(duplicateWire, operation: .attach)
        try WorkServiceTransportCodec.validateResponseCorrelation(
            duplicateWire, request: attachEnvelope, expectedHostInstance: expectedHost)

        // The exact duplicate remains valid after a later detach removes the historical
        // attachment from the current descriptor. Accepted responses must still project it.
        let detachedDuplicateWork = try WorkServiceWorkDescriptor(
            work: attachWork.work, journal: attachWork.journal,
            recordedDisposition: attachWork.recordedDisposition,
            execution: attachWork.execution, currentRun: attachWork.currentRun,
            currentRunSession: attachWork.currentRunSession,
            currentRunSessionAttachment: attachWork.currentRunSessionAttachment,
            configuration: attachWork.configuration,
            hostObservation: attachWork.hostObservation,
            attachments: attachWork.attachments.filter {
                $0.attachment != canonicalAttachment.attachment
            }, sessionAttachments: attachWork.sessionAttachments,
            artifacts: attachWork.artifacts, omissions: attachWork.omissions)
        let detachedDuplicateResponse = WorkServiceAttachResponse(
            work: detachedDuplicateWork, attachment: canonicalAttachment,
            authorization: attachAuthorization, commandID: attachRequest.commandID,
            state: .duplicate, host: expectedHost,
            causalControlCursor: duplicateCausal, resultingControlCursor: attachResulting,
            receipt: duplicateReceipt)
        let detachedDuplicateWire = WorkServiceTransportResponseEnvelope(
            id: attachEnvelope.id, ok: true,
            data: try transportEnvelopePayload(detachedDuplicateResponse),
            hostInstance: expectedHost)
        try WorkServiceTransportCodec.validateResponseSemantics(
            detachedDuplicateWire, operation: .attach)
        try WorkServiceTransportCodec.validateResponseCorrelation(
            detachedDuplicateWire, request: attachEnvelope,
            expectedHostInstance: expectedHost)

        let detachedAcceptedResponse = WorkServiceAttachResponse(
            work: detachedDuplicateWork, attachment: canonicalAttachment,
            authorization: attachAuthorization, commandID: attachRequest.commandID,
            state: .accepted, host: expectedHost,
            causalControlCursor: attachCausal, resultingControlCursor: attachResulting,
            receipt: attachReceipt)
        let detachedAcceptedWire = WorkServiceTransportResponseEnvelope(
            id: attachEnvelope.id, ok: true,
            data: try transportEnvelopePayload(detachedAcceptedResponse),
            hostInstance: expectedHost)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                detachedAcceptedWire, request: attachEnvelope,
                expectedHostInstance: expectedHost)
            XCTFail("transport accepted a new attachment absent from the current descriptor")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        // Omitting only part of the tuple is not the documented shorthand.
        let incompleteAttachment = WorkServiceClientAttachment(
            attachment: canonicalAttachment.attachment, client: canonicalAttachment.client,
            session: canonicalAttachment.session, sessionJournal: nil,
            sessionAttachment: canonicalAttachment.sessionAttachment,
            authorization: canonicalAttachment.authorization)
        let incompleteResponse = WorkServiceAttachResponse(
            work: attachWork, attachment: incompleteAttachment,
            authorization: attachAuthorization, commandID: attachRequest.commandID,
            state: .accepted, host: expectedHost,
            causalControlCursor: attachCausal, resultingControlCursor: attachResulting,
            receipt: attachReceipt)
        let incompleteWire = WorkServiceTransportResponseEnvelope(
            id: attachEnvelope.id, ok: true,
            data: try transportEnvelopePayload(incompleteResponse), hostInstance: expectedHost)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                incompleteWire, request: attachEnvelope, expectedHostInstance: expectedHost)
            XCTFail("transport accepted an incomplete returned Session tuple")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }
        await stopTransport(fixture.server, [fixture.clientA])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA])
        throw error
    }
}

func test_workServiceTransportTerminalCreateSessionRequiresObserveBeforeMutation() async throws {
    let path = transportSocketPath()
    let work = WorkRef(
        workHostID: transportHost.workHostID, workID: "transport-terminal-session")
    let journal = JournalRef.work(work)
    let createdEvent = TimelineEvent(
        eventID: "transport-terminal-created", journal: journal, sequence: 1,
        work: work, workHost: transportHost,
        actor: TimelineActor(actorID: "transport-terminal", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1),
        type: TimelineEventType.workCreated)
    let completedEvent = TimelineEvent(
        eventID: "transport-terminal-completed", journal: journal, sequence: 2,
        previousEventID: createdEvent.eventID,
        work: work, workHost: transportHost,
        actor: TimelineActor(actorID: "transport-terminal", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 2),
        type: TimelineEventType.workCompleted)
    let service = InMemoryWorkService(
        host: transportHost,
        instanceID: "transport-terminal-instance",
        startIdentity: "transport-terminal-start",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [
            transportClientA: [.createSession],
        ]))
    try await service.register(.init(
        work: work, journal: journal, disposition: .completed,
        execution: .idle,
        cursor: JournalCursor(
            journal: journal, eventID: completedEvent.eventID, sequence: 2),
        events: [createdEvent, completedEvent]))
    let server = WorkServiceUnixSocketServer(
        endpoint: WorkServiceTransportEndpoint(path: path), service: service)
    try await server.start()
    let client = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: transportClientA)
    do {
        let handshake = try await client.connect(build: "terminal-session-capability-test")
        let attached = try await client.attach(.init(
            work: work, journal: journal, client: transportClientA,
            commandID: "terminal-attach",
            causalControlCursor: handshake.controlCursor,
            requestedCapabilities: [.createSession]))
        let attachment = try XCTUnwrap(attached.attachment)
        for (index, capabilities) in [
            Set<WorkServiceCapability>(),
            Set<WorkServiceCapability>([.observe]),
        ].enumerated() {
            let response = try await client.createSession(.init(
                work: work, journal: journal, attachment: attachment.attachment,
                client: transportClientA,
                commandID: "terminal-session-denied-\(index)",
                causalControlCursor: attached.resultingControlCursor,
                causalWorkCursor: JournalCursor(
                    journal: journal, eventID: completedEvent.eventID, sequence: 2),
                requestedCapabilities: capabilities))
            XCTAssertEqual(response.state, .rejected)
            XCTAssertEqual(response.rejection, .authorizationDenied)
            XCTAssertNil(response.session)
            XCTAssertNil(response.attachment)
            XCTAssertEqual(response.controlCursor, attached.resultingControlCursor)
        }
        let refreshed = try await client.handshake(WorkServiceHandshakeRequest(
            client: transportClientA, build: "terminal-session-capability-test"))
        XCTAssertEqual(refreshed.controlCursor, attached.resultingControlCursor)
        await stopTransport(server, [client])
    } catch {
        await stopTransport(server, [client])
        throw error
    }
}

func test_workServiceTransportRefreshesHandshakeCursorOnTheSameSocket() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    let wrongHostClient = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: transportClientB,
        expectedHost: WorkHostRef("different-host"))
    do {
        let initial = try await fixture.clientA.connect()
        XCTAssertEqual(initial.controlCursor.sequence, 0)
        let attached = try await fixture.clientA.attach(.init(
            work: transportWork, journal: transportJournal, client: transportClientA,
            commandID: "transport-handshake-attach", causalControlCursor: initial.controlCursor,
            requestedCapabilities: [.observe, .control]))
        XCTAssertEqual(attached.state, .accepted)
        let refreshed = try await fixture.clientA.handshake(.init(client: transportClientA))
        XCTAssertEqual(refreshed.controlCursor, attached.resultingControlCursor)
        XCTAssertEqual((await fixture.clientA.negotiatedHandshake)?.controlCursor,
                       attached.resultingControlCursor)

        do {
            _ = try await fixture.clientA.handshake(.init(client: transportClientB))
            XCTFail("a connected socket must reject a different client identity")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .identityMismatch)
        }
        do {
            _ = try await wrongHostClient.connect()
            XCTFail("a client with a different expected host must reject the handshake")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .identityMismatch)
        }
        await stopTransport(fixture.server, [fixture.clientA, wrongHostClient])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA, wrongHostClient])
        throw error
    }
}

func test_workServiceTransportSupportsIndependentClientsAndOrderedMutations() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    let clientB = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: transportClientB)
    do {
        _ = try await fixture.clientA.connect()
        _ = try await clientB.connect()
        async let pageA = fixture.clientA.listWorks(.init(client: transportClientA, pageSize: 1))
        async let pageB = clientB.listWorks(.init(client: transportClientB, pageSize: 1))
        XCTAssertEqual(try await pageA.works.map(\.work), [transportWork])
        XCTAssertEqual(try await pageB.works.map(\.work), [transportWork])

        let attachedA = try await fixture.clientA.attach(.init(
            work: transportWork, journal: transportJournal, client: transportClientA,
            commandID: "attach-a", causalControlCursor: fixture.controlCursor,
            requestedCapabilities: [.observe, .control, .start, .inspectArtifacts, .createSession]))
        let attachmentA = try XCTUnwrap(attachedA.attachment)
        let attachedControlCursor = attachedA.resultingControlCursor
        XCTAssertEqual(attachedA.state, .accepted)

        // The second GUI observes the exact cursor produced by the first attachment.  Its
        // attachment is independent, but Work host ordering remains canonical and is never
        // derived from which socket connected first.
        let attachedB = try await clientB.attach(.init(
            work: transportWork, journal: transportJournal, client: transportClientB,
            commandID: "attach-b", causalControlCursor: attachedControlCursor,
            requestedCapabilities: [.observe, .control, .start]))
        let attachmentB = try XCTUnwrap(attachedB.attachment)
        XCTAssertNotEqual(attachmentA.attachment, attachmentB.attachment)
        XCTAssertTrue(attachmentA.readAcknowledgements.isEmpty)
        XCTAssertTrue(attachmentB.readAcknowledgements.isEmpty)
        let cursorB = try XCTUnwrap(
            attachedB.work.hostObservation?.servedCursor)

        let updated = try await clientB.updateCapabilities(.init(
            work: transportWork, journal: transportJournal,
            attachment: attachmentB.attachment, client: transportClientB,
            requestedCapabilities: [.observe, .control, .start], commandID: "capabilities-b",
            causalControlCursor: attachedB.resultingControlCursor))
        XCTAssertEqual(updated.state, .accepted)
        XCTAssertEqual(updated.receipt.operation, .updateCapabilities)
        XCTAssertEqual(updated.receipt.causalControlCursor, attachedB.resultingControlCursor)
        let workTarget = WorkServiceReadTarget.work(journal: transportJournal)
        let workSnapshot = try await clientB.snapshot(.init(
            work: transportWork, journal: transportJournal,
            attachment: attachmentB.attachment, client: transportClientB,
            target: workTarget, afterCursor: nil, limit: 8))
        XCTAssertEqual(workSnapshot.target, workTarget)
        XCTAssertTrue(workSnapshot.events.isEmpty)
        let acknowledged = try await clientB.acknowledgeRead(.init(
            work: transportWork, journal: transportJournal,
            attachment: attachmentB.attachment, client: transportClientB,
            target: workTarget,
            cursor: JournalCursor(journal: transportJournal, sequence: 0),
            commandID: "ack-session-b", causalControlCursor: updated.resultingControlCursor))
        XCTAssertEqual(acknowledged.state, .accepted)
        XCTAssertEqual(acknowledged.receipt.operation, .acknowledgeRead)
        let describedAfterAcknowledgement = try await clientB.describeWork(.init(
            work: transportWork, journal: transportJournal, client: transportClientB))
        let projectedAttachment = try XCTUnwrap(
            describedAfterAcknowledgement.attachments.first {
                $0.attachment == attachmentB.attachment
            })
        XCTAssertEqual(projectedAttachment.readAcknowledgements.count, 1)
        XCTAssertEqual(
            transportReadCursor(projectedAttachment, journal: transportJournal),
            JournalCursor(journal: transportJournal, sequence: 0))

        // Attachment identities are visible projection data, not bearer credentials. A second
        // authenticated GUI cannot borrow A's stronger attachment on any read surface.
        do {
            _ = try await clientB.snapshot(.init(
                work: transportWork, journal: transportJournal,
                attachment: attachmentA.attachment, client: transportClientB,
                target: .work(journal: transportJournal),
                afterCursor: cursorB, limit: 1))
            XCTFail("transport accepted another client's attachment")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .attachmentNotFound)
        }
        do {
            _ = try await clientB.fetchArtifact(.init(
                work: transportWork, journal: transportJournal,
                attachment: attachmentA.attachment, client: transportClientB,
                artifactID: "artifact-1"))
            XCTFail("transport inherited another client's artifact capability")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .attachmentNotFound)
        }

        // A Run must carry an exact Session/SessionAttachment owner. Establish a canonical
        // relationship before exercising the active-Run observation path; the earlier unqualified
        // attachment remains useful for the artifact/read assertions above.
        let createdSession = try await fixture.clientA.createSession(.init(
            work: transportWork, journal: transportJournal,
            attachment: attachmentA.attachment, client: transportClientA,
            commandID: "create-session-a", causalControlCursor: acknowledged.resultingControlCursor,
            causalWorkCursor: cursorB,
            requestedCapabilities: [.observe, .control, .start]))
        let sessionClientAttachmentA = try XCTUnwrap(createdSession.attachment)
        let attachedSessionB = try await clientB.attach(.init(
            work: transportWork, journal: transportJournal, client: transportClientB,
            session: createdSession.session, sessionJournal: createdSession.sessionJournal,
            sessionAttachment: createdSession.sessionAttachment,
            commandID: "attach-session-b", causalControlCursor: createdSession.controlCursor,
            requestedCapabilities: [.observe, .control, .start]))
        let activeAttachmentB = try XCTUnwrap(attachedSessionB.attachment)
        let sessionWorkCursor = createdSession.workCursor
        let started = try await fixture.clientA.command(.init(
            work: transportWork, journal: transportJournal,
            attachment: sessionClientAttachmentA.attachment, commandID: "start-a",
            client: transportClientA, sessionAttachment: sessionClientAttachmentA.sessionAttachment,
            causalWorkCursor: sessionWorkCursor, kind: .start))
        XCTAssertEqual(started.state, .accepted)
        XCTAssertEqual(started.outcome, .started)
        XCTAssertEqual(started.causalWorkCursor, sessionWorkCursor)
        // Start records the Run boundary before its command admission receipt.
        XCTAssertEqual(started.resultingWorkCursor?.sequence, sessionWorkCursor.sequence + 2)

        // A second client can observe the same Work after the first client's mutation; no
        // connection-level host sequence or global client lock is needed for this join.
        let observed = try await clientB.snapshot(.init(
            work: transportWork, journal: transportJournal,
            attachment: activeAttachmentB.attachment, client: transportClientB,
            target: .work(journal: transportJournal),
            afterCursor: sessionWorkCursor, limit: 8))
        let canonicalStartID = WorkServiceCommandLedgerIdentity.commandID(
            client: transportClientA, commandID: "start-a")
        XCTAssertTrue(observed.events.contains { $0.command?.commandID == canonicalStartID })
        XCTAssertEqual(observed.work.currentRun, RunRef("run-1"))
        let firstObservedEvent = try XCTUnwrap(observed.events.first)
        let exactEventBytes = try WorkServiceEventPageSizing.encodedByteCount(
            of: firstObservedEvent)
        let exactBoundary = try await clientB.eventsAfterCursor(.init(
            work: transportWork, journal: transportJournal,
            attachment: activeAttachmentB.attachment, client: transportClientB,
            target: .work(journal: transportJournal),
            afterCursor: sessionWorkCursor, limit: 1, maxBytes: exactEventBytes))
        XCTAssertEqual(exactBoundary.events, [firstObservedEvent])
        do {
            _ = try await clientB.eventsAfterCursor(.init(
                work: transportWork, journal: transportJournal,
                attachment: activeAttachmentB.attachment, client: transportClientB,
                target: .work(journal: transportJournal),
                afterCursor: sessionWorkCursor, limit: 8, maxBytes: 1))
            XCTFail("transport must surface an event page that cannot make progress")
        } catch WorkServiceTransportError.remote(let code, let diagnostic) {
            XCTAssertEqual(code, .eventPageCannotProgress)
            XCTAssertTrue(diagnostic?.contains("requires") == true)
        }
        let artifact = try await fixture.clientA.fetchArtifact(.init(
            work: transportWork, journal: transportJournal,
            attachment: attachmentA.attachment, client: transportClientA,
            artifactID: "artifact-1"))
        XCTAssertEqual(artifact.bodyReference, transportBody().reference)
        let body = try await fixture.clientA.fetchBody(.init(
            work: transportWork, journal: transportJournal,
            attachment: attachmentA.attachment, client: transportClientA,
            reference: transportBody().reference,
            offset: 0, limit: WorkServiceBounds.maxBodyChunkBytes))
        XCTAssertEqual(body.status, .retained)
        XCTAssertEqual(body.data, transportBody().data)
        let events = try await clientB.eventsAfterCursor(.init(
            work: transportWork, journal: transportJournal,
            attachment: activeAttachmentB.attachment, client: transportClientB,
            target: .work(journal: transportJournal),
            afterCursor: sessionWorkCursor, limit: 8))
        XCTAssertTrue(events.events.contains { $0.command?.commandID == canonicalStartID })
        let detached = try await clientB.detach(.init(
            work: transportWork, journal: transportJournal,
            attachment: activeAttachmentB.attachment, client: transportClientB,
            commandID: "detach-b", causalControlCursor: attachedSessionB.resultingControlCursor))
        XCTAssertEqual(detached.state, .accepted)
        await stopTransport(fixture.server, [fixture.clientA, clientB])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA, clientB])
        throw error
    }
}

func test_workServiceTransportPreservesTypedErrorsAndIdentityFence() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    let clientB = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: ClientRef("read-only"))
    do {
        _ = try await fixture.clientA.connect()
        do {
            _ = try await fixture.clientA.listWorks(.init(client: transportClientB, pageSize: 1))
            XCTFail("transport accepted a payload client different from its handshake")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .identityMismatch)
        }

        _ = try await clientB.connect()
        do {
            _ = try await clientB.listWorks(.init(client: ClientRef("read-only"), pageSize: 1))
            XCTFail("transport let an unauthorized principal list Work")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .capabilityDenied)
        }
        await stopTransport(fixture.server, [fixture.clientA, clientB])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA, clientB])
        throw error
    }
}

func test_workServiceTransportOrdersRequestsWithinOneConnection() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    do {
        let raw = try RawWorkServiceTransportClient(path: path)
        let handshake = WorkServiceHandshakeRequest(client: transportClientA)
        try raw.send(.init(
            id: "ordered-handshake", operation: .handshake, client: transportClientA,
            payload: try transportEnvelopePayload(handshake)))
        let handshakeResponse = try raw.receive()
        XCTAssertTrue(handshakeResponse.ok)
        let handshakeData = try XCTUnwrap(handshakeResponse.data)
        let handshakeValue = try JSONDecoder().decode(
            WorkServiceHandshakeResponse.self, from: JSONEncoder().encode(handshakeData))
        let create = WorkServiceCreateWorkRequest(
            client: transportClientA, commandID: "ordered-create",
            causalControlCursor: handshakeValue.controlCursor)
        try raw.send(.init(
            id: "ordered-create-request", operation: .createWork, client: transportClientA,
            payload: try transportEnvelopePayload(create)))
        let createResponse = try raw.receive()
        XCTAssertEqual(createResponse.id, "ordered-create-request")
        XCTAssertTrue(createResponse.ok)
        let createdData = try XCTUnwrap(createResponse.data)
        let created = try JSONDecoder().decode(
            WorkServiceCreateWorkResponse.self, from: JSONEncoder().encode(createdData))
        XCTAssertEqual(created.receipt.outcome, .created)
        let attach = WorkServiceAttachRequest(
            work: created.work.work, journal: created.work.journal, client: transportClientA,
            session: created.session, sessionJournal: created.sessionJournal,
            sessionAttachment: created.sessionAttachment, commandID: "ordered-attach",
            causalControlCursor: created.controlCursor,
            requestedCapabilities: [.observe])
        // A fresh host-minted identity and its control cursor are learned from the create
        // response before the first independent client attachment is issued.
        try raw.send(.init(
            id: "ordered-attach-request", operation: .attach, client: transportClientA,
            payload: try transportEnvelopePayload(attach)))
        let attachResponse = try raw.receive()
        XCTAssertEqual(attachResponse.id, "ordered-attach-request")
        XCTAssertTrue(attachResponse.ok)
        let attachedData = try XCTUnwrap(attachResponse.data)
        let attached = try JSONDecoder().decode(
            WorkServiceAttachResponse.self, from: JSONEncoder().encode(attachedData))
        XCTAssertEqual(attached.state, .accepted)
        raw.close()
        await stopTransport(fixture.server, [])
    } catch {
        await stopTransport(fixture.server, [])
        throw error
    }
}

func test_workServiceTransportDisconnectLeavesServiceForAnotherGUI() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    let clientB = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: transportClientB)
    do {
        _ = try await fixture.clientA.connect()
        XCTAssertEqual((try await fixture.clientA.listWorks(.init(
            client: transportClientA, pageSize: 1))).works.count, 1)
        await fixture.clientA.close()

        let deadline = Date().addingTimeInterval(2)
        while await fixture.server.connectedClientCount != 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(await fixture.server.connectedClientCount, 0)

        _ = try await clientB.connect()
        let page = try await clientB.listWorks(.init(client: transportClientB, pageSize: 1))
        XCTAssertEqual(page.works.map(\.work), [transportWork])
        XCTAssertEqual(page.works.first?.hostObservation?.reachability, .observedReachable)
        await stopTransport(fixture.server, [fixture.clientA, clientB])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA, clientB])
        throw error
    }
}

func test_workServiceTransportCodecBoundsAndRoundTripsEnvelopes() throws {
    let request = WorkServiceTransportRequestEnvelope(
        id: "request-1", operation: .listWorks, client: transportClientA,
        payload: try transportEnvelopePayload(
            WorkServiceListRequest(client: transportClientA, pageSize: 3)))
    let frame = try WorkServiceTransportCodec.encodeFrame(request)
    XCTAssertEqual(frame.last, UInt8(ascii: "\n"))
    let decoded = try WorkServiceTransportCodec.decodeRequest(
        frame.dropLast())
    XCTAssertEqual(decoded, request)
    do {
        _ = try WorkServiceTransportCodec.decodeRequest(Data("{}".utf8))
        XCTFail("codec accepted a request without an id or operation")
    } catch WorkServiceTransportError.invalidFrame {
        XCTAssertTrue(true)
    }

    let huge = WorkServiceTransportRequestEnvelope(
        id: "huge", operation: .listWorks, client: transportClientA,
        payload: .string(String(repeating: "x", count: WorkServiceTransportCodec.maxFrameBytes)))
    do {
        _ = try WorkServiceTransportCodec.encodeFrame(huge)
        XCTFail("codec accepted an oversized request frame")
    } catch WorkServiceTransportError.frameTooLarge(let bytes, let limit) {
        XCTAssertTrue(bytes > limit)
        XCTAssertEqual(limit, WorkServiceTransportCodec.maxFrameBytes)
    }

    let response = WorkServiceTransportResponseEnvelope(
        id: "request-1", ok: false,
        error: .init(code: .capabilityDenied, detail: "bounded diagnostic"))
    let responseFrame = try WorkServiceTransportCodec.encodeFrame(response)
    XCTAssertEqual(try WorkServiceTransportCodec.decodeResponse(responseFrame.dropLast()), response)
}

func test_workServiceTransportRejectsRawWorkspacePathAlongsideOpaqueID() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    do {
        let raw = try RawWorkServiceTransportClient(path: path)
        let handshake = WorkServiceHandshakeRequest(client: transportClientA)
        try raw.send(WorkServiceTransportRequestEnvelope(
            id: "path-handshake", operation: .handshake, client: transportClientA,
            payload: try transportEnvelopePayload(handshake)))
        let accepted = try raw.receive()
        XCTAssertTrue(accepted.ok)
        let handshakeData = try JSONEncoder().encode(try XCTUnwrap(accepted.data))
        let handshakeResponse = try JSONDecoder().decode(
            WorkServiceHandshakeResponse.self, from: handshakeData)
        let request = WorkServiceCreateWorkRequest(
            client: transportClientA, commandID: "raw-path-create",
            causalControlCursor: handshakeResponse.controlCursor,
            configuration: .init(workspaceID: try WorkHostWorkspaceID(
                "workspace-00000000-0000-0000-0000-000000000021")))
        guard case .object(var requestObject) = try transportEnvelopePayload(request),
              case .object(var configuration) = requestObject["configuration"] else {
            XCTFail("create request did not encode as an object")
            raw.close()
            await stopTransport(fixture.server, [])
            return
        }
        configuration["path"] = .string("/private/host-secret/workspace")
        requestObject["configuration"] = .object(configuration)
        try raw.send(WorkServiceTransportRequestEnvelope(
            id: "raw-path-request", operation: .createWork, client: transportClientA,
            payload: .object(requestObject)))
        let rejected = try raw.receive()
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.error?.code, .invalidFrame)
        raw.close()
        await stopTransport(fixture.server, [])
    } catch {
        await stopTransport(fixture.server, [])
        throw error
    }
}

func test_workServiceTransportRejectsPathShapedWorkspaceLabels() throws {
    let labels = ["/private/host-secret/workspace", "file:///tmp/workspace", "~/workspace", "../workspace"]
    for label in labels {
        let wire = Data("""
        {"workspaceID":"workspace-00000000-0000-0000-0000-000000000021","label":"\(label)","isDefault":false,"availability":"available","capabilities":[]}
        """.utf8)
        do {
            _ = try JSONDecoder().decode(WorkHostWorkspaceDescriptor.self, from: wire)
            XCTFail("transport accepted a path-shaped workspace label: \(label)")
        } catch let error as WorkHostWorkspaceRegistryError {
            XCTAssertEqual(error, .invalidLabel)
        } catch {
            XCTFail("unexpected workspace label error: \(error)")
        }
    }
}

private final class RawWorkServiceTransportClient: @unchecked Sendable {
    private let descriptor: Int32

    init(path: String) throws {
        let descriptor = AviaryPOSIX.streamSocket()
        guard descriptor >= 0 else { throw UnwrapFailure(description: "raw socket failed") }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            var pathBytes = Data(path.utf8)
            guard pathBytes.count <= 103 else {
                throw UnwrapFailure(description: "raw socket path too long")
            }
            pathBytes.append(0)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw UnwrapFailure(description: "raw connect failed") }
        } catch {
            _ = AviaryPOSIX.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    func send(_ envelope: WorkServiceTransportRequestEnvelope) throws {
        let frame = try WorkServiceTransportCodec.encodeFrame(envelope)
        try write(frame)
    }

    func write(_ bytes: Data) throws {
        try bytes.withUnsafeBytes { rawBytes in
            guard let base = rawBytes.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < rawBytes.count {
                let written = AviaryPOSIX.write(
                    descriptor, base.advanced(by: offset), rawBytes.count - offset)
                guard written > 0 else { throw UnwrapFailure(description: "raw write failed") }
                offset += written
            }
        }
    }

    func receive() throws -> WorkServiceTransportResponseEnvelope {
        var line = Data()
        while true {
            var byte: UInt8 = 0
            let count = withUnsafeMutableBytes(of: &byte) { rawBytes in
                AviaryPOSIX.read(descriptor, rawBytes.baseAddress, rawBytes.count)
            }
            guard count == 1 else { throw UnwrapFailure(description: "raw socket closed") }
            if byte == UInt8(ascii: "\n") { break }
            line.append(byte)
            guard line.count <= WorkServiceTransportCodec.maxFrameBytes else {
                throw UnwrapFailure(description: "raw response exceeded bound")
            }
        }
        return try WorkServiceTransportCodec.decodeResponse(line)
    }

    func close() { _ = AviaryPOSIX.close(descriptor) }
}

private final class DelayedWorkService: WorkServiceClient, @unchecked Sendable {
    let base: InMemoryWorkService
    let delayNanoseconds: UInt64
    private let delayState = DispatchQueue(label: "aviary.transport.delayed-service.state")
    private var hasDelayedOneRequest = false

    init(base: InMemoryWorkService, delayNanoseconds: UInt64) {
        self.base = base
        self.delayNanoseconds = delayNanoseconds
    }

    func handshake(_ request: WorkServiceHandshakeRequest) async throws
        -> WorkServiceHandshakeResponse {
        try await base.handshake(request)
    }

    func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage {
        let shouldDelay = delayState.sync {
            let shouldDelay = !hasDelayedOneRequest
            hasDelayedOneRequest = true
            return shouldDelay
        }
        if shouldDelay {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try await base.listWorks(request)
    }

    func describeWork(_ request: WorkServiceDescribeRequest) async throws
        -> WorkServiceWorkDescriptor {
        try await base.describeWork(request)
    }

    func createWork(_ request: WorkServiceCreateWorkRequest) async throws
        -> WorkServiceCreateWorkResponse {
        try await base.createWork(request)
    }

    func createSession(_ request: WorkServiceCreateSessionRequest) async throws
        -> WorkServiceCreateSessionResponse {
        try await base.createSession(request)
    }

    func completeWork(_ request: WorkServiceCompleteWorkRequest) async throws
        -> WorkServiceCommandReceipt {
        try await base.completeWork(request)
    }

    func attach(_ request: WorkServiceAttachRequest) async throws -> WorkServiceAttachResponse {
        try await base.attach(request)
    }

    func detach(_ request: WorkServiceDetachRequest) async throws -> WorkServiceDetachResponse {
        try await base.detach(request)
    }

    func updateCapabilities(_ request: WorkServiceUpdateCapabilitiesRequest) async throws
        -> WorkServiceUpdateCapabilitiesResponse {
        try await base.updateCapabilities(request)
    }

    func acknowledgeRead(_ request: WorkServiceAcknowledgeReadRequest) async throws
        -> WorkServiceAcknowledgeReadResponse {
        try await base.acknowledgeRead(request)
    }

    func snapshot(_ request: WorkServiceSnapshotRequest) async throws -> WorkServiceSnapshot {
        try await base.snapshot(request)
    }

    func eventsAfterCursor(_ request: WorkServiceEventsRequest) async throws
        -> WorkServiceEventPage {
        try await base.eventsAfterCursor(request)
    }

    func fetchArtifact(_ request: WorkServiceArtifactRequest) async throws
        -> WorkServiceArtifactDescriptor {
        try await base.fetchArtifact(request)
    }

    func fetchBody(_ request: WorkServiceBodyRequest) async throws -> WorkServiceBodyResponse {
        try await base.fetchBody(request)
    }

    func command(_ request: WorkServiceCommandRequest) async throws
        -> WorkServiceCommandReceipt {
        try await base.command(request)
    }
}

private func transportDelayedFixture(
    path: String, delayNanoseconds: UInt64
) async throws -> (
    service: InMemoryWorkService,
    server: WorkServiceUnixSocketServer,
    client: WorkServiceUnixSocketClient
) {
    let service = InMemoryWorkService(
        host: transportHost, instanceID: "transport-delayed-instance",
        startIdentity: "transport-delayed-start", authorizer: transportAuthorizer())
    let cursor = JournalCursor(journal: transportJournal, sequence: 0)
    try await service.register(.init(
        work: transportWork, journal: transportJournal, cursor: cursor,
        artifacts: [], bodies: [:]))
    let delayed = DelayedWorkService(base: service, delayNanoseconds: delayNanoseconds)
    let server = WorkServiceUnixSocketServer(
        endpoint: WorkServiceTransportEndpoint(path: path), service: delayed)
    try await server.start()
    let client = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: transportClientA,
        requestTimeout: 0.1)
    return (service, server, client)
}

func test_workServiceTransportFrameBeforeEOFIsAdmittedAndApplied() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    do {
        let raw = try RawWorkServiceTransportClient(path: path)
        let handshake = WorkServiceHandshakeRequest(client: transportClientA)
        try raw.send(.init(
            id: "eof-handshake", operation: .handshake, client: transportClientA,
            payload: try transportEnvelopePayload(handshake)))
        let handshakeResponse = try raw.receive()
        XCTAssertTrue(handshakeResponse.ok)
        let handshakeData = try XCTUnwrap(handshakeResponse.data)
        let handshakeValue = try JSONDecoder().decode(
            WorkServiceHandshakeResponse.self, from: JSONEncoder().encode(handshakeData))

        let work = WorkRef(workHostID: transportHost.workHostID, workID: "work-2")
        let create = WorkServiceCreateWorkRequest(
            client: transportClientA, commandID: "eof-create",
            causalControlCursor: handshakeValue.controlCursor)
        try raw.send(.init(
            id: "eof-create-request", operation: .createWork, client: transportClientA,
            payload: try transportEnvelopePayload(create)))
        // Closing immediately after the frame exercises the FIFO pump's frame-before-EOF rule.
        raw.close()

        let deadline = Date().addingTimeInterval(2)
        var applied = false
        while Date() < deadline {
            let page = try await fixture.service.listWorks(.init(
                client: transportClientA, pageSize: WorkServiceBounds.maxPageSize))
            if page.works.contains(where: { $0.work == work }) {
                applied = true
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(applied)
        await stopTransport(fixture.server, [])
    } catch {
        await stopTransport(fixture.server, [])
        throw error
    }
}

func test_workServiceTransportTimeoutLateResponseIsTombstoned() async throws {
    let path = transportSocketPath()
    let fixture = try await transportDelayedFixture(path: path, delayNanoseconds: 400_000_000)
    do {
        _ = try await fixture.client.connect()
        do {
            _ = try await fixture.client.listWorks(.init(
                client: transportClientA, pageSize: 1))
            XCTFail("delayed request unexpectedly completed before timeout")
        } catch WorkServiceTransportError.timedOut(let operation) {
            XCTAssertEqual(operation, .listWorks)
        }

        // The delayed response arrives after the local timeout. It must be consumed by the
        // tombstone rather than treated as an unsolicited response that kills the connection.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let page = try await fixture.client.listWorks(.init(
            client: transportClientA, pageSize: 1))
        XCTAssertEqual(page.works.count, 1)
        XCTAssertTrue(await fixture.client.isConnected)
        await stopTransport(fixture.server, [fixture.client])
    } catch {
        await stopTransport(fixture.server, [fixture.client])
        throw error
    }
}

func test_workServiceTransportRejectsUnexpectedHandshakeHost() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    let client = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: transportClientA,
        expectedHost: WorkHostRef("unexpected-host"))
    do {
        do {
            _ = try await client.connect()
            XCTFail("client accepted a handshake from an unexpected Work Host")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .identityMismatch)
        }
        XCTAssertFalse(await client.isConnected)
        await stopTransport(fixture.server, [fixture.clientA, client])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA, client])
        throw error
    }
}

func test_workServiceTransportPrincipalBindingRejectsSelfClaimedClient() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(
        path: path, principalBinding: RejectingTransportPrincipalBinding())
    do {
        do {
            _ = try await fixture.clientA.connect()
            XCTFail("transport accepted a client rejected by its principal binding")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .handshakeRejected)
        }
        XCTAssertFalse(await fixture.clientA.isConnected)
        await stopTransport(fixture.server, [fixture.clientA])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA])
        throw error
    }
}

func test_workServiceTransportStopAwaitsOneSharedBoundedDrain() async throws {
    let path = transportSocketPath()
    let fixture = try await transportDelayedFixture(
        path: path, delayNanoseconds: 400_000_000)
    do {
        _ = try await fixture.client.connect()
        let request: Task<WorkServiceWorkPage, Error> = Task {
            try await fixture.client.listWorks(.init(client: transportClientA, pageSize: 1))
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let started = Date()
        await fixture.server.stop(drainTimeout: 0.05)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(elapsed < 0.5)
        XCTAssertEqual(await fixture.server.connectedClientCount, 0)
        _ = try? await request.value
        await fixture.client.close()
    } catch {
        await stopTransport(fixture.server, [fixture.client])
        throw error
    }
}

func test_workServiceTransportCancellationLateResponseIsTombstoned() async throws {
    let path = transportSocketPath()
    let fixture = try await transportDelayedFixture(
        path: path, delayNanoseconds: 400_000_000)
    do {
        _ = try await fixture.client.connect()
        let request: Task<WorkServiceWorkPage, Error> = Task {
            try await fixture.client.listWorks(.init(client: transportClientA, pageSize: 1))
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("canceled transport request unexpectedly completed")
        } catch WorkServiceTransportError.canceled {
            XCTAssertTrue(true)
        }
        // The first service response is still in flight. Its eventual frame must be consumed by
        // the cancellation tombstone, leaving the same connection usable for a later request.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let page = try await fixture.client.listWorks(.init(
            client: transportClientA, pageSize: 1))
        XCTAssertEqual(page.works.count, 1)
        XCTAssertTrue(await fixture.client.isConnected)
        await stopTransport(fixture.server, [fixture.client])
    } catch {
        await stopTransport(fixture.server, [fixture.client])
        throw error
    }
}

func test_workServiceTransportStopPreservesReplacementEndpoint() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    do {
        await fixture.clientA.close()
        try FileManager.default.removeItem(atPath: path)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: path, contents: Data("replacement".utf8), attributes: nil))
        await fixture.server.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try FileManager.default.removeItem(atPath: path)
    } catch {
        await stopTransport(fixture.server, [fixture.clientA])
        try? FileManager.default.removeItem(atPath: path)
        throw error
    }
}

func test_workServiceTransportInputPumpBoundsFloodBeforeTaskAdmission() async throws {
    let path = transportSocketPath()
    let service = InMemoryWorkService(
        host: transportHost, instanceID: "transport-flood-instance",
        startIdentity: "transport-flood-start", authorizer: transportAuthorizer())
    try await service.register(.init(
        work: transportWork, journal: transportJournal,
        cursor: JournalCursor(journal: transportJournal, sequence: 0)))
    let server = WorkServiceUnixSocketServer(
        endpoint: WorkServiceTransportEndpoint(path: path), service: service,
        maxFrameBytes: 2_048, maxPendingRequests: 1, maxInputBytes: 2_048)
    try await server.start()
    do {
        let raw = try RawWorkServiceTransportClient(path: path)
        let handshake = WorkServiceHandshakeRequest(client: transportClientA)
        try raw.send(.init(
            id: "flood-handshake", operation: .handshake, client: transportClientA,
            payload: try transportEnvelopePayload(handshake)))
        XCTAssertTrue(try raw.receive().ok)
        let request = WorkServiceTransportRequestEnvelope(
            id: "flood-0", operation: .listWorks, client: transportClientA,
            payload: try transportEnvelopePayload(
                WorkServiceListRequest(client: transportClientA, pageSize: 1)))
        let one = try WorkServiceTransportCodec.encodeFrame(request, maxBytes: 2_048)
        var burst = Data()
        for index in 0..<32 {
            let id = "flood-\(index)"
            let frame = try WorkServiceTransportCodec.encodeFrame(
                WorkServiceTransportRequestEnvelope(
                    id: id, operation: .listWorks, client: transportClientA,
                    payload: request.payload), maxBytes: 2_048)
            burst.append(frame)
        }
        XCTAssertFalse(one.isEmpty)
        try raw.write(burst)
        raw.close()
        let deadline = Date().addingTimeInterval(2)
        while await server.connectedClientCount != 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(await server.connectedClientCount, 0)
        await server.stop()
    } catch {
        await server.stop()
        throw error
    }
}

func test_workServiceTransportResponseSemanticBounds() throws {
    let semanticWork = WorkRef(workHostID: transportHost.workHostID, workID: "semantic-work")
    let journal = JSONValue.parse(
        try JSONEncoder().encode(JournalRef.work(semanticWork, journalID: "semantic-journal")))
        ?? .null
    let descriptor = JSONValue.object([
        "work": .object([
            "workHostID": .string(transportHost.workHostID),
            "workID": .string("semantic-work"),
        ]),
        "journal": journal,
        "attachments": .array([]),
        "artifacts": .array([]),
        "omissions": .array([]),
    ])
    let oversizedPage = WorkServiceTransportResponseEnvelope(
        id: "semantic-page", ok: true,
        data: .object(["works": .array(Array(repeating: descriptor,
                                             count: WorkServiceBounds.maxPageSize + 1))]))
    do {
        try WorkServiceTransportCodec.validateResponseSemantics(
            oversizedPage, operation: .listWorks)
        XCTFail("transport accepted a response page over the semantic bound")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }

    let oversizedBody = WorkServiceTransportResponseEnvelope(
        id: "semantic-body", ok: true,
        data: .object([
            "offset": .number(0),
            "status": .string("retained"),
            "data": .string(Data(repeating: 0x42,
                                  count: WorkServiceBounds.maxBodyChunkBytes + 1)
                .base64EncodedString()),
        ]))
    do {
        try WorkServiceTransportCodec.validateResponseSemantics(
            oversizedBody, operation: .fetchBody)
        XCTFail("transport accepted a body response over the chunk bound")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }

    let invalidOffsets = WorkServiceTransportResponseEnvelope(
        id: "semantic-offset", ok: true,
        data: .object([
            "reference": JSONValue.parse(
                try JSONEncoder().encode(transportBody().reference)) ?? .null,
            "status": .string("retained"),
            "offset": .number(10),
            "data": .string(Data([0x01, 0x02, 0x03]).base64EncodedString()),
            "nextOffset": .number(12),
        ]))
    do {
        try WorkServiceTransportCodec.validateResponseSemantics(
            invalidOffsets, operation: .fetchBody)
        XCTFail("transport accepted inconsistent body offsets")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }
}

func test_workServiceTransportRejectsFalsePageProgressAndBodyEOFClaims() async throws {
    let instance = WorkHostInstanceRef(
        host: transportHost, instanceID: "transport-instance", startIdentity: "transport-start")
    let target = WorkServiceReadTarget.work(journal: transportJournal)
    let request = WorkServiceEventsRequest(
        work: transportWork, journal: transportJournal,
        attachment: ClientAttachmentRef("transport-attachment"), client: transportClientA,
        target: target, afterCursor: JournalCursor(journal: transportJournal, sequence: 0),
        limit: 2)
    let envelope = WorkServiceTransportRequestEnvelope(
        id: "correlation-page", operation: .eventsAfterCursor, client: transportClientA,
        payload: try transportEnvelopePayload(request))
    func event(_ id: String, _ sequence: Int, _ previous: String?) -> TimelineEvent {
        TimelineEvent(
            eventID: id, journal: transportJournal, sequence: sequence,
            previousEventID: previous, work: transportWork, workHost: transportHost,
            actor: TimelineActor(actorID: "host", kind: "test"),
            hostRecordedAt: Date(timeIntervalSince1970: 0), type: "test")
    }
    let first = event("page-1", 1, nil)
    let second = event("page-2", 2, first.eventID)
    let good = WorkServiceEventPage(
        events: [first, second], target: target,
        servedCursor: JournalCursor(journal: transportJournal, eventID: second.eventID, sequence: 2),
        nextCursor: nil)
    let goodEnvelope = WorkServiceTransportResponseEnvelope(
        id: envelope.id, ok: true, data: try JSONValue.parse(JSONEncoder().encode(good)),
        hostInstance: instance)
    try WorkServiceTransportCodec.validateResponseCorrelation(
        goodEnvelope, request: envelope, expectedHostInstance: instance)
    guard case .object(let validPageObject) = try transportEnvelopePayload(good),
          case .array(let validEvents) = validPageObject["events"],
          case .object(let validFirstEvent) = validEvents.first else {
        XCTFail("event page must encode native Timeline events")
        return
    }
    for invalidCount in [-1, 0, TimelineEvent.maxOmittedEvidenceLinkCount + 1] {
        var forgedEvent = validFirstEvent
        forgedEvent["omitted_evidence_link_count"] = .number(Double(invalidCount))
        var forgedPage = validPageObject
        forgedPage["events"] = .array([.object(forgedEvent), validEvents[1]])
        let forgedEnvelope = WorkServiceTransportResponseEnvelope(
            id: envelope.id, ok: true, data: .object(forgedPage), hostInstance: instance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedEnvelope, request: envelope, expectedHostInstance: instance)
            XCTFail("transport accepted invalid omitted evidence-link metadata")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }
    }
    let missingEnvelopeInstance = WorkServiceTransportResponseEnvelope(
        id: envelope.id, ok: true, data: try JSONValue.parse(JSONEncoder().encode(good)))
    do {
        try WorkServiceTransportCodec.validateResponseCorrelation(
            missingEnvelopeInstance, request: envelope, expectedHostInstance: instance)
        XCTFail("an empty-page response without the negotiated instance was accepted")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }
    let correlatedFailure = WorkServiceTransportResponseEnvelope(
        id: envelope.id, ok: false,
        error: .init(code: .staleCursor, detail: "stale"), hostInstance: instance)
    try WorkServiceTransportCodec.validateResponseCorrelation(
        correlatedFailure, request: envelope, expectedHostInstance: instance)
    let uncorrelatedFailure = WorkServiceTransportResponseEnvelope(
        id: envelope.id, ok: false,
        error: .init(code: .staleCursor, detail: "stale"))
    do {
        try WorkServiceTransportCodec.validateResponseCorrelation(
            uncorrelatedFailure, request: envelope, expectedHostInstance: instance)
        XCTFail("an uncorrelated stale-cursor error was accepted as host proof")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }
    let foreignFailure = WorkServiceTransportResponseEnvelope(
        id: envelope.id, ok: false,
        error: .init(code: .staleCursor, detail: "stale"),
        hostInstance: WorkHostInstanceRef(
            host: transportHost, instanceID: "foreign-instance",
            startIdentity: "foreign-start"))
    do {
        try WorkServiceTransportCodec.validateResponseCorrelation(
            foreignFailure, request: envelope, expectedHostInstance: instance)
        XCTFail("a stale-cursor error from another host instance was accepted")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }

    let skipped = event("page-3", 3, first.eventID)
    let badPage = WorkServiceEventPage(
        events: [skipped], target: target,
        servedCursor: JournalCursor(journal: transportJournal, eventID: skipped.eventID, sequence: 3),
        nextCursor: nil)
    let badEnvelope = WorkServiceTransportResponseEnvelope(
        id: envelope.id, ok: true, data: try JSONValue.parse(JSONEncoder().encode(badPage)),
        hostInstance: instance)
    do {
        try WorkServiceTransportCodec.validateResponseCorrelation(
            badEnvelope, request: envelope, expectedHostInstance: instance)
        XCTFail("transport accepted a skipped event page")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }

    let otherWork = WorkRef(workHostID: transportHost.workHostID, workID: "other-work")
    let wrongOwner = TimelineEvent(
        eventID: "wrong-owner", journal: transportJournal, sequence: 1,
        work: otherWork, workHost: transportHost,
        actor: TimelineActor(actorID: "host", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0), type: "test")
    let wrongOwnerPage = WorkServiceEventPage(
        events: [wrongOwner], target: target,
        servedCursor: JournalCursor(journal: transportJournal, eventID: wrongOwner.eventID, sequence: 1),
        nextCursor: nil)
    let wrongOwnerEnvelope = WorkServiceTransportResponseEnvelope(
        id: envelope.id, ok: true,
        data: try JSONValue.parse(JSONEncoder().encode(wrongOwnerPage)), hostInstance: instance)
    do {
        try WorkServiceTransportCodec.validateResponseCorrelation(
            wrongOwnerEnvelope, request: envelope, expectedHostInstance: instance)
        XCTFail("transport accepted a Work event from another Work owner")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }

    let session = SessionRef("foreign-session")
    let sessionJournal = JournalRef.session(
        session, authority: TimelineAuthorityRef(transportHost.workHostID))
    let sessionTarget = WorkServiceReadTarget.session(session: session, journal: sessionJournal)
    let genesis = TimelineEvent(
        eventID: "session-genesis", journal: sessionJournal, sequence: 1,
        session: session, actor: TimelineActor(actorID: "session-host", kind: "session"),
        hostRecordedAt: Date(timeIntervalSince1970: 0), type: TimelineEventType.sessionCreated)
    let sessionRequest = WorkServiceEventsRequest(
        work: transportWork, journal: transportJournal,
        attachment: ClientAttachmentRef("transport-attachment"), client: transportClientA,
        target: sessionTarget,
        afterCursor: JournalCursor(journal: sessionJournal, sequence: 0), limit: 1)
    let sessionEnvelope = WorkServiceTransportRequestEnvelope(
        id: "session-genesis-page", operation: .eventsAfterCursor, client: transportClientA,
        payload: try transportEnvelopePayload(sessionRequest))
    let sessionPage = WorkServiceEventPage(
        events: [genesis], target: sessionTarget,
        servedCursor: JournalCursor(journal: sessionJournal, eventID: genesis.eventID, sequence: 1),
        nextCursor: nil)
    let sessionResponse = WorkServiceTransportResponseEnvelope(
        id: sessionEnvelope.id, ok: true,
        data: try JSONValue.parse(JSONEncoder().encode(sessionPage)), hostInstance: instance)
    try WorkServiceTransportCodec.validateResponseCorrelation(
        sessionResponse, request: sessionEnvelope, expectedHostInstance: instance)

    // A real native Session genesis deliberately has no Work/Work Host fields. Validate the
    // JSONL-produced event rather than only a hand-built DTO so JournalBacked composition cannot
    // accidentally acquire the InMemory host stamps.
    let nativeRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("aviary-transport-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: nativeRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: nativeRoot) }
    let nativeHome = AgentHome(root: nativeRoot)
    let nativeHost = try nativeHome.requirePersistedWorkHost()
    let nativeSession = SessionRef("native-session-genesis")
    let nativeWork = WorkRef(workHostID: nativeHost.workHostID, workID: "native-work")
    let nativeBinding = WorkBinding(
        session: nativeSession, work: nativeWork, workHost: nativeHost,
        sessionAttachment: SessionAttachmentRef("native-attachment"))
    let nativeCreation = try await RunJournalBundle.createIdleWork(
        home: nativeHome, binding: nativeBinding, actorID: "native-test-actor",
        now: { Date(timeIntervalSince1970: 0) })
    let nativeRead = TimelineJournalReader.read(
        try Data(contentsOf: nativeHome.timelineV2SessionJournalURL(nativeSession)),
        journal: nativeBinding.sessionJournal,
        actor: TimelineActor(actorID: "native-test-actor", kind: "work-host-control"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    let nativeGenesis = try XCTUnwrap(nativeRead.records.first?.event)
    XCTAssertEqual(nativeGenesis.type, TimelineEventType.sessionCreated)
    XCTAssertEqual(nativeGenesis.session, nativeSession)
    XCTAssertNil(nativeGenesis.work)
    XCTAssertNil(nativeGenesis.workHost)
    XCTAssertNil(nativeRead.truncatedTail)
    XCTAssertNil(nativeRead.quarantinedSuffix)
    let nativeInstance = WorkHostInstanceRef(
        host: nativeHost, instanceID: "native-instance", startIdentity: "native-start")
    let nativeTarget = WorkServiceReadTarget.session(
        session: nativeSession, journal: nativeBinding.sessionJournal)
    let nativeRequest = WorkServiceEventsRequest(
        work: nativeWork, journal: nativeBinding.workJournal,
        attachment: ClientAttachmentRef("native-client-attachment"), client: transportClientA,
        target: nativeTarget,
        afterCursor: JournalCursor(journal: nativeBinding.sessionJournal, sequence: 0), limit: 1)
    let nativeEnvelope = WorkServiceTransportRequestEnvelope(
        id: "native-session-genesis-page", operation: .eventsAfterCursor,
        client: transportClientA, payload: try transportEnvelopePayload(nativeRequest))
    let nativePage = WorkServiceEventPage(
        events: [nativeGenesis], target: nativeTarget,
        servedCursor: JournalCursor(
            journal: nativeBinding.sessionJournal, eventID: nativeGenesis.eventID, sequence: 1),
        nextCursor: nil)
    let nativeResponse = WorkServiceTransportResponseEnvelope(
        id: nativeEnvelope.id, ok: true,
        data: try JSONValue.parse(JSONEncoder().encode(nativePage)), hostInstance: nativeInstance)
    try WorkServiceTransportCodec.validateResponseCorrelation(
        nativeResponse, request: nativeEnvelope, expectedHostInstance: nativeInstance)
    XCTAssertEqual(nativeCreation.commits.first?.cursor, nativePage.servedCursor)

    let body = transportBody()
    let bodyRequest = WorkServiceBodyRequest(
        work: transportWork, journal: transportJournal,
        attachment: ClientAttachmentRef("transport-attachment"), client: transportClientA,
        reference: body.reference, offset: 0, limit: 2)
    let bodyEnvelope = WorkServiceTransportRequestEnvelope(
        id: "correlation-body", operation: .fetchBody, client: transportClientA,
        payload: try transportEnvelopePayload(bodyRequest))
    let missingDeclaredLength = TimelineBodyReference(
        authority: body.reference.authority, referenceID: body.reference.referenceID,
        mediaType: body.reference.mediaType, byteCount: nil, digest: body.reference.digest)
    let missingLengthRequest = WorkServiceBodyRequest(
        work: transportWork, journal: transportJournal,
        attachment: ClientAttachmentRef("transport-attachment"), client: transportClientA,
        reference: missingDeclaredLength, offset: 0, limit: 2)
    let missingLengthEnvelope = WorkServiceTransportRequestEnvelope(
        id: "correlation-body-missing-length", operation: .fetchBody,
        client: transportClientA, payload: try transportEnvelopePayload(missingLengthRequest))
    let missingLengthResponse = WorkServiceBodyResponse(
        reference: missingDeclaredLength, status: .retained, offset: 0,
        data: Data("ab".utf8), nextOffset: nil)
    let missingLengthResponseEnvelope = WorkServiceTransportResponseEnvelope(
        id: missingLengthEnvelope.id, ok: true,
        data: try JSONValue.parse(JSONEncoder().encode(missingLengthResponse)),
        hostInstance: instance)
    do {
        try WorkServiceTransportCodec.validateResponseCorrelation(
            missingLengthResponseEnvelope, request: missingLengthEnvelope,
            expectedHostInstance: instance)
        XCTFail("transport accepted a retained body without declared byteCount")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }
    let missingLengthProgressResponse = WorkServiceBodyResponse(
        reference: missingDeclaredLength, status: .retained, offset: 0,
        data: Data("ab".utf8), nextOffset: 2)
    let missingLengthProgressEnvelope = WorkServiceTransportResponseEnvelope(
        id: missingLengthEnvelope.id, ok: true,
        data: try JSONValue.parse(JSONEncoder().encode(missingLengthProgressResponse)),
        hostInstance: instance)
    do {
        try WorkServiceTransportCodec.validateResponseCorrelation(
            missingLengthProgressEnvelope, request: missingLengthEnvelope,
            expectedHostInstance: instance)
        XCTFail("transport accepted a progressing retained body without byteCount")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }
    let premature = WorkServiceBodyResponse(
        reference: body.reference, status: .retained, offset: 0,
        data: Data("ab".utf8), nextOffset: nil)
    let prematureEnvelope = WorkServiceTransportResponseEnvelope(
        id: bodyEnvelope.id, ok: true,
        data: try JSONValue.parse(JSONEncoder().encode(premature)), hostInstance: instance)
    do {
        try WorkServiceTransportCodec.validateResponseCorrelation(
            prematureEnvelope, request: bodyEnvelope, expectedHostInstance: instance)
        XCTFail("transport accepted a retained body before declared EOF")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }
    let overLimit = WorkServiceBodyResponse(
        reference: body.reference, status: .retained, offset: 0,
        data: Data("abc".utf8), nextOffset: 3)
    let overLimitEnvelope = WorkServiceTransportResponseEnvelope(
        id: bodyEnvelope.id, ok: true,
        data: try JSONValue.parse(JSONEncoder().encode(overLimit)), hostInstance: instance)
    do {
        try WorkServiceTransportCodec.validateResponseCorrelation(
            overLimitEnvelope, request: bodyEnvelope, expectedHostInstance: instance)
        XCTFail("transport accepted body bytes beyond the request limit")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }
}

func test_workServiceTransportBindsMutationReceiptShapesAndIdentities() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    let expectedInstance = WorkHostInstanceRef(
        host: transportHost, instanceID: "transport-instance", startIdentity: "transport-start")
    do {
        let handshake = try await fixture.clientA.connect()
        let createRequest = WorkServiceCreateWorkRequest(
            client: transportClientA, commandID: "adversarial-create",
            causalControlCursor: handshake.controlCursor)
        let created = try await fixture.clientA.createWork(createRequest)
        let createEnvelope = WorkServiceTransportRequestEnvelope(
            id: "adversarial-create", operation: .createWork, client: transportClientA,
            payload: try transportEnvelopePayload(createRequest))

        let forgedCreateAuthorization = WorkServiceAuthorizationOutcome(
            requested: [.observe], granted: [.observe], denied: [])
        let forgedCreate = WorkServiceCreateWorkResponse(
            work: created.work, authorization: forgedCreateAuthorization,
            session: created.session, sessionJournal: created.sessionJournal,
            sessionAttachment: created.sessionAttachment, attachment: created.attachment,
            workCursor: created.workCursor, sessionCursor: created.sessionCursor,
            controlCursor: created.controlCursor, receipt: created.receipt)
        let forgedCreateEnvelope = WorkServiceTransportResponseEnvelope(
            id: createEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedCreate), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedCreateEnvelope, request: createEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted create authorization different from its receipt")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        // Every authorization copy can agree with each other and still lie about what was
        // requested. The transport must validate the capability partition against the request,
        // not only compare response fields with one another.
        let forgedCreateAttachment = WorkServiceClientAttachment(
            attachment: created.attachment.attachment, client: created.attachment.client,
            session: created.attachment.session, sessionJournal: created.attachment.sessionJournal,
            sessionAttachment: created.attachment.sessionAttachment,
            authorization: forgedCreateAuthorization)
        let forgedCreateWork = try WorkServiceWorkDescriptor(
            work: created.work.work, journal: created.work.journal,
            recordedDisposition: created.work.recordedDisposition,
            execution: created.work.execution, currentRun: created.work.currentRun,
            currentRunSession: created.work.currentRunSession,
            currentRunSessionAttachment: created.work.currentRunSessionAttachment,
            configuration: created.work.configuration,
            hostObservation: created.work.hostObservation,
            attachments: [forgedCreateAttachment], artifacts: created.work.artifacts,
            omissions: created.work.omissions)
        let forgedCreateAllCopiesReceipt = WorkServiceControlReceipt(
            operation: .createWork, work: forgedCreateWork.work,
            commandID: createRequest.commandID, state: .accepted,
            host: created.receipt.host, causalControlCursor: createRequest.causalControlCursor,
            resultingControlCursor: created.controlCursor,
            authorization: forgedCreateAuthorization, outcome: .created)
        let forgedCreateAllCopies = WorkServiceCreateWorkResponse(
            work: forgedCreateWork, authorization: forgedCreateAuthorization,
            session: created.session, sessionJournal: created.sessionJournal,
            sessionAttachment: created.sessionAttachment, attachment: forgedCreateAttachment,
            workCursor: created.workCursor, sessionCursor: created.sessionCursor,
            controlCursor: created.controlCursor, receipt: forgedCreateAllCopiesReceipt)
        let forgedCreateAllCopiesEnvelope = WorkServiceTransportResponseEnvelope(
            id: createEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedCreateAllCopies), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedCreateAllCopiesEnvelope, request: createEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted create authorization whose copies lied about requested capabilities")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        let forgedCreateReceipt = WorkServiceControlReceipt(
            operation: .createWork, work: created.work.work, commandID: createRequest.commandID,
            state: .accepted, host: created.receipt.host,
            causalControlCursor: createRequest.causalControlCursor,
            resultingControlCursor: created.controlCursor,
            authorization: created.receipt.authorization)
        let forgedCreateOutcome = WorkServiceCreateWorkResponse(
            work: created.work, authorization: created.authorization,
            session: created.session, sessionJournal: created.sessionJournal,
            sessionAttachment: created.sessionAttachment, attachment: created.attachment,
            workCursor: created.workCursor, sessionCursor: created.sessionCursor,
            controlCursor: created.controlCursor, receipt: forgedCreateReceipt)
        let forgedCreateOutcomeEnvelope = WorkServiceTransportResponseEnvelope(
            id: createEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedCreateOutcome), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedCreateOutcomeEnvelope, request: createEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted a create receipt without its required outcome")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        let attachRequest = WorkServiceAttachRequest(
            work: created.work.work, journal: created.work.journal, client: transportClientA,
            session: created.session, sessionJournal: created.sessionJournal,
            sessionAttachment: created.sessionAttachment, commandID: "adversarial-attach",
            causalControlCursor: created.controlCursor, requestedCapabilities: [.observe, .control])
        let attached = try await fixture.clientA.attach(attachRequest)
        let attachEnvelope = WorkServiceTransportRequestEnvelope(
            id: "adversarial-attach", operation: .attach, client: transportClientA,
            payload: try transportEnvelopePayload(attachRequest))
        let attachedClientAttachment = try XCTUnwrap(attached.attachment)

        let forgedAttachAuthorization = WorkServiceAuthorizationOutcome(
            requested: [.observe], granted: [.observe], denied: [])
        let forgedAttachAttachment = WorkServiceClientAttachment(
            attachment: attachedClientAttachment.attachment, client: attachedClientAttachment.client,
            session: attachedClientAttachment.session,
            sessionJournal: attachedClientAttachment.sessionJournal,
            sessionAttachment: attachedClientAttachment.sessionAttachment,
            authorization: forgedAttachAuthorization)
        let forgedAttachWork = try WorkServiceWorkDescriptor(
            work: attached.work.work, journal: attached.work.journal,
            recordedDisposition: attached.work.recordedDisposition,
            execution: attached.work.execution, currentRun: attached.work.currentRun,
            currentRunSession: attached.work.currentRunSession,
            currentRunSessionAttachment: attached.work.currentRunSessionAttachment,
            configuration: attached.work.configuration,
            hostObservation: attached.work.hostObservation,
            attachments: attached.work.attachments.map {
                $0.attachment == attachedClientAttachment.attachment
                    ? forgedAttachAttachment : $0
            }, artifacts: attached.work.artifacts, omissions: attached.work.omissions)
        let forgedAttachAllCopiesReceipt = WorkServiceControlReceipt(
            operation: .attach, work: attached.work.work, commandID: attached.commandID,
            state: .accepted, host: attached.host,
            causalControlCursor: attached.causalControlCursor,
            resultingControlCursor: attached.resultingControlCursor,
            authorization: forgedAttachAuthorization, outcome: .attached)
        let forgedAttachAllCopies = WorkServiceAttachResponse(
            work: forgedAttachWork, attachment: forgedAttachAttachment,
            authorization: forgedAttachAuthorization, commandID: attached.commandID,
            state: .accepted, host: attached.host,
            causalControlCursor: attached.causalControlCursor,
            resultingControlCursor: attached.resultingControlCursor,
            receipt: forgedAttachAllCopiesReceipt)
        let forgedAttachAllCopiesEnvelope = WorkServiceTransportResponseEnvelope(
            id: attachEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedAttachAllCopies), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedAttachAllCopiesEnvelope, request: attachEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted attach authorization whose copies lied about requested capabilities")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        let foreignControlJournal = JournalRef.workHost(WorkHostRef("foreign-control-host"))
        let swappedResultingCursor = JournalCursor(
            journal: foreignControlJournal, eventID: "foreign-control-event", sequence: 1)
        let swappedCursorReceipt = WorkServiceControlReceipt(
            operation: .attach, work: attached.work.work, commandID: attached.commandID,
            state: .accepted, host: attached.host,
            causalControlCursor: attached.causalControlCursor,
            resultingControlCursor: swappedResultingCursor,
            authorization: attached.authorization, outcome: .attached)
        let swappedCursorResponse = WorkServiceAttachResponse(
            work: attached.work, attachment: attached.attachment,
            authorization: attached.authorization, commandID: attached.commandID,
            state: .accepted, host: attached.host,
            causalControlCursor: attached.causalControlCursor,
            resultingControlCursor: swappedResultingCursor,
            receipt: swappedCursorReceipt)
        let swappedCursorEnvelope = WorkServiceTransportResponseEnvelope(
            id: attachEnvelope.id, ok: true,
            data: try transportEnvelopePayload(swappedCursorResponse), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                swappedCursorEnvelope, request: attachEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted a resulting cursor from a foreign control journal")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        let backwardCursor = attachRequest.causalControlCursor
        let backwardCursorReceipt = WorkServiceControlReceipt(
            operation: .attach, work: attached.work.work, commandID: attached.commandID,
            state: .accepted, host: attached.host,
            causalControlCursor: attached.causalControlCursor,
            resultingControlCursor: backwardCursor,
            authorization: attached.authorization, outcome: .attached)
        let backwardCursorResponse = WorkServiceAttachResponse(
            work: attached.work, attachment: attached.attachment,
            authorization: attached.authorization, commandID: attached.commandID,
            state: .accepted, host: attached.host,
            causalControlCursor: attached.causalControlCursor,
            resultingControlCursor: backwardCursor,
            receipt: backwardCursorReceipt)
        let backwardCursorEnvelope = WorkServiceTransportResponseEnvelope(
            id: attachEnvelope.id, ok: true,
            data: try transportEnvelopePayload(backwardCursorResponse), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                backwardCursorEnvelope, request: attachEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted an accepted attach without forward cursor progress")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        let swappedSession = SessionRef("swapped-session")
        let swappedSessionJournal = JournalRef.session(
            swappedSession, authority: TimelineAuthorityRef(transportHost.workHostID))
        let swappedAttachment = WorkServiceClientAttachment(
            attachment: attachedClientAttachment.attachment, client: transportClientA,
            session: swappedSession, sessionJournal: swappedSessionJournal,
            sessionAttachment: SessionAttachmentRef("swapped-session-attachment"),
            authorization: attachedClientAttachment.authorization)
        let forgedAttach = WorkServiceAttachResponse(
            work: attached.work, attachment: swappedAttachment,
            authorization: attached.authorization, commandID: attached.commandID,
            state: attached.state, host: attached.host,
            causalControlCursor: attached.causalControlCursor,
            resultingControlCursor: attached.resultingControlCursor,
            receipt: attached.receipt)
        let forgedAttachEnvelope = WorkServiceTransportResponseEnvelope(
            id: attachEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedAttach), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedAttachEnvelope, request: attachEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted an attachment with a swapped Session tuple")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        let missingAttachOutcomeReceipt = WorkServiceControlReceipt(
            operation: .attach, work: attached.work.work, commandID: attached.commandID,
            state: .accepted, host: attached.host,
            causalControlCursor: attached.causalControlCursor,
            resultingControlCursor: attached.resultingControlCursor,
            authorization: attached.authorization)
        let forgedAttachOutcome = WorkServiceAttachResponse(
            work: attached.work, attachment: attached.attachment,
            authorization: attached.authorization, commandID: attached.commandID,
            state: .accepted, host: attached.host,
            causalControlCursor: attached.causalControlCursor,
            resultingControlCursor: attached.resultingControlCursor,
            receipt: missingAttachOutcomeReceipt)
        let forgedAttachOutcomeEnvelope = WorkServiceTransportResponseEnvelope(
            id: attachEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedAttachOutcome), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedAttachOutcomeEnvelope, request: attachEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted an attach receipt without its required outcome")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        let inconsistentReceipt = WorkServiceControlReceipt(
            operation: .attach, work: attached.work.work, commandID: attached.commandID,
            state: .rejected, host: attached.host,
            causalControlCursor: attached.causalControlCursor,
            resultingControlCursor: attached.resultingControlCursor,
            authorization: attached.authorization, rejection: .invalidState)
        let forgedAttachState = WorkServiceAttachResponse(
            work: attached.work, attachment: attached.attachment,
            authorization: attached.authorization, commandID: attached.commandID,
            state: .accepted, host: attached.host,
            causalControlCursor: attached.causalControlCursor,
            resultingControlCursor: attached.resultingControlCursor,
            receipt: inconsistentReceipt)
        let forgedAttachStateEnvelope = WorkServiceTransportResponseEnvelope(
            id: attachEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedAttachState), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedAttachStateEnvelope, request: attachEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted inconsistent attachment state and receipt")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        let updateRequest = WorkServiceUpdateCapabilitiesRequest(
            work: attached.work.work, journal: attached.work.journal,
            attachment: attachedClientAttachment.attachment, client: transportClientA,
            requestedCapabilities: [.observe], commandID: "adversarial-capabilities",
            causalControlCursor: attached.resultingControlCursor)
        let forgedUpdateAuthorization = WorkServiceAuthorizationOutcome(
            requested: [], granted: [], denied: [])
        let forgedUpdateAttachment = WorkServiceClientAttachment(
            attachment: attachedClientAttachment.attachment, client: transportClientA,
            session: attachedClientAttachment.session,
            sessionJournal: attachedClientAttachment.sessionJournal,
            sessionAttachment: attachedClientAttachment.sessionAttachment,
            authorization: forgedUpdateAuthorization)
        let forgedUpdateReceipt = WorkServiceControlReceipt(
            operation: .updateCapabilities, work: updateRequest.work,
            commandID: updateRequest.commandID, state: .accepted, host: attached.host,
            causalControlCursor: updateRequest.causalControlCursor,
            resultingControlCursor: attached.resultingControlCursor,
            authorization: forgedUpdateAuthorization, outcome: .capabilitiesUpdated)
        let forgedUpdate = WorkServiceUpdateCapabilitiesResponse(
            work: updateRequest.work, attachment: forgedUpdateAttachment,
            authorization: forgedUpdateAuthorization, commandID: updateRequest.commandID,
            state: .accepted, host: attached.host,
            causalControlCursor: updateRequest.causalControlCursor,
            resultingControlCursor: attached.resultingControlCursor,
            receipt: forgedUpdateReceipt)
        let updateEnvelope = WorkServiceTransportRequestEnvelope(
            id: "adversarial-capabilities", operation: .updateCapabilities,
            client: transportClientA, payload: try transportEnvelopePayload(updateRequest))
        let forgedUpdateEnvelope = WorkServiceTransportResponseEnvelope(
            id: updateEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedUpdate), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedUpdateEnvelope, request: updateEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted update authorization whose copies lied about requested capabilities")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }

        let commandRequest = WorkServiceCommandRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: attachedClientAttachment.attachment, commandID: "adversarial-start",
            client: transportClientA,
            sessionAttachment: attachedClientAttachment.sessionAttachment,
            causalWorkCursor: created.workCursor, kind: .start)
        let commandReceipt = try await fixture.clientA.command(commandRequest)
        let commandEnvelope = WorkServiceTransportRequestEnvelope(
            id: "adversarial-start", operation: .command, client: transportClientA,
            payload: try transportEnvelopePayload(commandRequest))
        let forgedCommand = WorkServiceCommandReceipt(
            work: commandReceipt.work, commandID: commandReceipt.commandID,
            state: commandReceipt.state, host: commandReceipt.host,
            hostSequence: commandReceipt.hostSequence,
            causalWorkCursor: commandReceipt.causalWorkCursor,
            resultingWorkCursor: commandReceipt.resultingWorkCursor,
            authorization: commandReceipt.authorization, outcome: .completed)
        let forgedCommandEnvelope = WorkServiceTransportResponseEnvelope(
            id: commandEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedCommand), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedCommandEnvelope, request: commandEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted a command outcome for another command kind")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }
        let forgedCommandCursor = WorkServiceCommandReceipt(
            work: commandReceipt.work, commandID: commandReceipt.commandID,
            state: commandReceipt.state, host: commandReceipt.host,
            hostSequence: commandReceipt.hostSequence,
            causalWorkCursor: JournalCursor(journal: created.work.journal, sequence: 0),
            resultingWorkCursor: commandReceipt.resultingWorkCursor,
            authorization: commandReceipt.authorization, outcome: commandReceipt.outcome)
        let forgedCommandCursorEnvelope = WorkServiceTransportResponseEnvelope(
            id: commandEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedCommandCursor), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedCommandCursorEnvelope, request: commandEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted a command receipt with a swapped causal cursor")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }
        let forgedCommandID = WorkServiceCommandReceipt(
            work: commandReceipt.work, commandID: "swapped-command",
            state: commandReceipt.state, host: commandReceipt.host,
            hostSequence: commandReceipt.hostSequence,
            causalWorkCursor: commandReceipt.causalWorkCursor,
            resultingWorkCursor: commandReceipt.resultingWorkCursor,
            authorization: commandReceipt.authorization, outcome: commandReceipt.outcome)
        let forgedCommandIDEnvelope = WorkServiceTransportResponseEnvelope(
            id: commandEnvelope.id, ok: true,
            data: try transportEnvelopePayload(forgedCommandID), hostInstance: expectedInstance)
        do {
            try WorkServiceTransportCodec.validateResponseCorrelation(
                forgedCommandIDEnvelope, request: commandEnvelope,
                expectedHostInstance: expectedInstance)
            XCTFail("transport accepted a receipt for a swapped command")
        } catch WorkServiceTransportError.invalidResponse {
            XCTAssertTrue(true)
        }
        await stopTransport(fixture.server, [fixture.clientA])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA])
        throw error
    }
}

func test_workServiceTransportRejectsDuplicateAndOversizedFramesExplicitly() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    do {
        let raw = try RawWorkServiceTransportClient(path: path)
        let handshake = WorkServiceHandshakeRequest(client: transportClientA)
        let envelope = WorkServiceTransportRequestEnvelope(
            id: "same-id", operation: .handshake, client: transportClientA,
            payload: try transportEnvelopePayload(handshake))
        try raw.send(envelope)
        let accepted = try raw.receive()
        XCTAssertTrue(accepted.ok)
        try raw.send(envelope)
        let duplicate = try raw.receive()
        XCTAssertFalse(duplicate.ok)
        XCTAssertEqual(duplicate.id, "same-id")
        XCTAssertEqual(duplicate.error?.code, .duplicateRequestID)
        try raw.write(Data("{\"id\":\"future\",\"operation\":\"future_operation\"}\n".utf8))
        let unsupported = try raw.receive()
        XCTAssertFalse(unsupported.ok)
        XCTAssertEqual(unsupported.id, "future")
        XCTAssertEqual(unsupported.error?.code, .unsupportedOperation)
        raw.close()

        let oversized = try RawWorkServiceTransportClient(path: path)
        var bytes = Data(repeating: UInt8(ascii: "x"),
                         count: WorkServiceTransportCodec.maxFrameBytes)
        bytes.append(UInt8(ascii: "\n"))
        try oversized.write(bytes)
        let tooLarge = try oversized.receive()
        XCTAssertFalse(tooLarge.ok)
        XCTAssertEqual(tooLarge.error?.code, .frameTooLarge)
        oversized.close()
        await stopTransport(fixture.server, [])
    } catch {
        await stopTransport(fixture.server, [])
        throw error
    }
}

func test_workServiceTransportRejectsAttachmentOverflowBeforeSessionPublication() async throws {
    let path = transportSocketPath()
    let fixture = try await transportFixture(path: path)
    do {
        let handshake = try await fixture.clientA.connect(build: "attachment-bound-test")
        var controlCursor = handshake.controlCursor
        var authorizingAttachment: WorkServiceClientAttachment?
        for index in 0..<WorkServiceBounds.maxAttachmentsPerWork {
            let response = try await fixture.clientA.attach(.init(
                work: transportWork, journal: transportJournal,
                client: transportClientA, commandID: "bounded-client-attachment-\(index)",
                causalControlCursor: controlCursor,
                requestedCapabilities: [.observe, .createSession]))
            XCTAssertEqual(response.state, .accepted)
            controlCursor = response.resultingControlCursor
            if authorizingAttachment == nil { authorizingAttachment = response.attachment }
        }
        let before = try await fixture.clientA.describeWork(.init(
            work: transportWork, journal: transportJournal, client: transportClientA))
        XCTAssertEqual(before.attachments.count, WorkServiceBounds.maxAttachmentsPerWork)
        XCTAssertNil(before.omissions.first(where: { $0.category == "attachments" }))
        let workCursor = try XCTUnwrap(before.hostObservation?.servedCursor)

        let session = try await fixture.clientA.createSession(.init(
            work: transportWork, journal: transportJournal,
            attachment: try XCTUnwrap(authorizingAttachment).attachment,
            client: transportClientA, commandID: "bounded-session-no-publication",
            causalControlCursor: controlCursor, causalWorkCursor: workCursor,
            requestedCapabilities: [.observe]))
        XCTAssertEqual(session.state, .rejected)
        XCTAssertEqual(session.rejection, .invalidState)
        XCTAssertNil(session.session)
        XCTAssertNil(session.sessionJournal)
        XCTAssertNil(session.sessionAttachment)
        XCTAssertNil(session.attachment)
        XCTAssertNil(session.relationship)
        XCTAssertEqual(session.controlCursor, controlCursor)
        XCTAssertEqual(session.workCursor, workCursor)

        let overflow = try await fixture.clientA.attach(.init(
            work: transportWork, journal: transportJournal,
            client: transportClientA, commandID: "bounded-client-attachment-overflow",
            causalControlCursor: controlCursor, requestedCapabilities: [.observe]))
        XCTAssertEqual(overflow.state, .rejected)
        XCTAssertEqual(overflow.rejection, .invalidState)
        XCTAssertNil(overflow.attachment)
        XCTAssertEqual(overflow.resultingControlCursor, controlCursor)
        let after = try await fixture.clientA.describeWork(.init(
            work: transportWork, journal: transportJournal, client: transportClientA))
        XCTAssertEqual(after.attachments, before.attachments)
        XCTAssertEqual(after.hostObservation?.servedCursor, workCursor)
        await stopTransport(fixture.server, [fixture.clientA])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA])
        throw error
    }
}

private func test_workServiceDescriptorOwnerValidationDoesNotTrap() throws {
    let host = WorkHostRef("descriptor-validation-host")
    let work = WorkRef(workHostID: host.workHostID, workID: "descriptor-validation-work")
    let journal = JournalRef.work(work)
    let run = RunRef("descriptor-validation-run")
    let session = SessionRef("descriptor-validation-session")
    let attachment = SessionAttachmentRef("descriptor-validation-attachment")
    let sessionJournal = JournalRef.session(
        session, authority: TimelineAuthorityRef(host.workHostID))
    let workCursor = JournalCursor(journal: journal, sequence: 0)
    let sessionCursor = JournalCursor(journal: sessionJournal, sequence: 0)
    let relationship = WorkServiceSessionAttachmentDescriptor(
        session: session, sessionJournal: sessionJournal, sessionAttachment: attachment,
        publication: .mirrored, causalSessionCursor: sessionCursor,
        sessionCursor: JournalCursor(journal: sessionJournal, eventID: "session-attachment", sequence: 1),
        causalWorkCursor: workCursor,
        resultingWorkCursor: JournalCursor(journal: journal, eventID: "work-mirror", sequence: 1),
        capabilities: [.observe])

    do {
        _ = try WorkServiceHostObservation(
            instance: WorkHostInstanceRef(host: host, instanceID: "instance", startIdentity: "start"),
            reachability: .observedReachable, currentRun: run,
            currentRunSession: nil, currentRunSessionAttachment: nil,
            servedCursor: nil, sourceCompleteness: .complete)
        XCTFail("a partial host owner tuple must be rejected")
    } catch let error as WorkServiceProtocolError {
        XCTAssertEqual(error, .invalidRequest(
            "an observed Run must have exactly one Session/attachment owner envelope"))
    }

    let observation = try WorkServiceHostObservation(
        instance: WorkHostInstanceRef(host: host, instanceID: "instance", startIdentity: "start"),
        reachability: .observedReachable, currentRun: nil,
        currentRunSession: nil, currentRunSessionAttachment: nil,
        servedCursor: nil, sourceCompleteness: .complete)
    do {
        _ = try WorkServiceWorkDescriptor(
            work: work, journal: journal, recordedDisposition: .reusable, execution: .idle,
            currentRun: run, currentRunSession: session,
            currentRunSessionAttachment: attachment, hostObservation: observation,
            sessionAttachments: [relationship])
        XCTFail("a complete mismatched host owner must be rejected")
    } catch let error as WorkServiceProtocolError {
        XCTAssertEqual(error, .invalidRequest(
            "complete host observation must name the descriptor's exact Run owner"))
    }

    let valid = try WorkServiceWorkDescriptor(
        work: work, journal: journal, recordedDisposition: .reusable, execution: .running,
        currentRun: run, currentRunSession: session,
        currentRunSessionAttachment: attachment, hostObservation: nil,
        sessionAttachments: [relationship])
    guard case .object(var forgedObject) = try transportEnvelopePayload(valid) else {
        XCTFail("descriptor must encode as an object")
        return
    }
    forgedObject["sessionAttachments"] = .array([])
    let forgedOwnerEnvelope = WorkServiceTransportResponseEnvelope(
        id: "forged-owner-descriptor", ok: true, data: .object(forgedObject))
    do {
        try WorkServiceTransportCodec.validateResponseSemantics(
            forgedOwnerEnvelope, operation: .describeWork)
        XCTFail("transport accepted an active owner with no attached Session relationship")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }
    guard case .object(var detachedRelationship) = try transportEnvelopePayload(relationship) else {
        XCTFail("relationship must encode as an object")
        return
    }
    detachedRelationship["isAttached"] = .bool(false)
    forgedObject["sessionAttachments"] = .array([.object(detachedRelationship)])
    let detachedOwnerEnvelope = WorkServiceTransportResponseEnvelope(
        id: "detached-owner-descriptor", ok: true, data: .object(forgedObject))
    do {
        try WorkServiceTransportCodec.validateResponseSemantics(
            detachedOwnerEnvelope, operation: .describeWork)
        XCTFail("transport accepted an active owner with a detached Session relationship")
    } catch WorkServiceTransportError.invalidResponse {
        XCTAssertTrue(true)
    }
}

let casesWorkServiceTransport: [Case] = [
    ("phase3 Work service transport: owner validation fails closed without trapping", {
        try test_workServiceDescriptorOwnerValidationDoesNotTrap()
    }),
    ("phase3 Work service transport: CreateSession replay preserves mutable attachment state", {
        try await test_workServiceTransportCreateSessionReplayKeepsMutableAttachmentCurrent()
    }),
    ("phase3 Work service transport: InMemory CreateWork replay preserves mutable attachment state", {
        try await test_workServiceTransportInMemoryCreateWorkReplayKeepsMutableAttachmentCurrent()
    }),
    ("phase3 Work service transport: handshake and read projection", {
        try await test_workServiceTransportHandshakeAndReadProjection()
    }),
    ("phase3 Work service transport: raw correlation accepts canonical shorthand", {
        try await test_workServiceTransportRawCorrelationAllowsCanonicalShorthandAndUnobservedWork()
    }),
    ("phase3 Work service transport: terminal Session requires observe before mutation", {
        try await test_workServiceTransportTerminalCreateSessionRequiresObserveBeforeMutation()
    }),
    ("phase3 Work service transport: same-socket handshake refreshes control cursor", {
        try await test_workServiceTransportRefreshesHandshakeCursorOnTheSameSocket()
    }),
    ("phase3 Work service transport: independent clients and ordered mutations", {
        try await test_workServiceTransportSupportsIndependentClientsAndOrderedMutations()
    }),
    ("phase3 Work service transport: typed errors and identity fence", {
        try await test_workServiceTransportPreservesTypedErrorsAndIdentityFence()
    }),
    ("phase3 Work service transport: requests are ordered per connection", {
        try await test_workServiceTransportOrdersRequestsWithinOneConnection()
    }),
    ("phase3 Work service transport: disconnect leaves service available", {
        try await test_workServiceTransportDisconnectLeavesServiceForAnotherGUI()
    }),
    ("phase3 Work service transport: codec bounds and envelope round trips", {
        try test_workServiceTransportCodecBoundsAndRoundTripsEnvelopes()
    }),
    ("phase3 Work service transport: raw workspace paths are rejected", {
        try await test_workServiceTransportRejectsRawWorkspacePathAlongsideOpaqueID()
    }),
    ("phase3 Work service transport: path-shaped workspace labels are rejected", {
        try test_workServiceTransportRejectsPathShapedWorkspaceLabels()
    }),
    ("phase3 Work service transport: duplicate and oversized frames are explicit", {
        try await test_workServiceTransportRejectsDuplicateAndOversizedFramesExplicitly()
    }),
    ("phase3 Work service transport: attachment overflow rejects before Session publication", {
        try await test_workServiceTransportRejectsAttachmentOverflowBeforeSessionPublication()
    }),
    ("phase3 Work service transport: frame before EOF is admitted", {
        try await test_workServiceTransportFrameBeforeEOFIsAdmittedAndApplied()
    }),
    ("phase3 Work service transport: timeout late responses are tombstoned", {
        try await test_workServiceTransportTimeoutLateResponseIsTombstoned()
    }),
    ("phase3 Work service transport: unexpected handshake host is rejected", {
        try await test_workServiceTransportRejectsUnexpectedHandshakeHost()
    }),
    ("phase3 Work service transport: principal binding rejects self-claimed clients", {
        try await test_workServiceTransportPrincipalBindingRejectsSelfClaimedClient()
    }),
    ("phase3 Work service transport: stop awaits one bounded drain", {
        try await test_workServiceTransportStopAwaitsOneSharedBoundedDrain()
    }),
    ("phase3 Work service transport: cancellation late responses are tombstoned", {
        try await test_workServiceTransportCancellationLateResponseIsTombstoned()
    }),
    ("phase3 Work service transport: replacement endpoint is preserved", {
        try await test_workServiceTransportStopPreservesReplacementEndpoint()
    }),
    ("phase3 Work service transport: input pump bounds flood admission", {
        try await test_workServiceTransportInputPumpBoundsFloodBeforeTaskAdmission()
    }),
    ("phase3 Work service transport: response semantic bounds", {
        try test_workServiceTransportResponseSemanticBounds()
    }),
    ("phase3 Work service transport: response progress and body EOF are exact", {
        try await test_workServiceTransportRejectsFalsePageProgressAndBodyEOFClaims()
    }),
    ("phase3 Work service transport: mutation receipts bind state and identities", {
        try await test_workServiceTransportBindsMutationReceiptShapesAndIdentities()
    }),
]
