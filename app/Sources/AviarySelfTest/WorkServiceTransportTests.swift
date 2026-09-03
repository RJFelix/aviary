import Darwin
import CryptoKit
import Foundation
@testable import AviaryCore

private let transportHost = WorkHostRef("transport-host")
private let transportWork = WorkRef(workHostID: transportHost.workHostID, workID: "work-1")
private let transportJournal = JournalRef.work(transportWork, journalID: "work-journal")
private let transportClientA = ClientRef("transport-a")
private let transportClientB = ClientRef("transport-b")

private struct RejectingTransportPrincipalBinding: WorkServiceTransportPrincipalBinding {
    func accepts(claimedClient: ClientRef) -> Bool { false }
}

private func transportBody() -> (reference: TimelineBodyReference, data: Data) {
    let data = Data("transport-artifact-body".utf8)
    let digest = "sha256:" + SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
    return (
        TimelineBodyReference(
            authority: transportJournal, referenceID: "artifact-body",
            mediaType: "text/plain", byteCount: data.count, digest: digest), data)
}

private let transportCapabilities: Set<WorkServiceCapability> = [
    .observe, .control, .start, .send, .steer, .queue, .hold, .cancel, .end,
    .inspectArtifacts,
]

private func transportAuthorizer() -> WorkServiceCapabilityPolicy {
    WorkServiceCapabilityPolicy(grantsByClient: [
        transportClientA: transportCapabilities,
        transportClientB: [.observe, .control, .start],
    ])
}

private func transportSocketPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("aw-\(UUID().uuidString.prefix(8)).sock")
        .path
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
    cursor: JournalCursor
) {
    let service = InMemoryWorkService(
        host: transportHost, instanceID: "transport-instance", startIdentity: "transport-start",
        authorizer: transportAuthorizer())
    let cursor = JournalCursor(journal: transportJournal, sequence: 0)
    let body = transportBody()
    try await service.register(.init(
        work: transportWork, journal: transportJournal, cursor: cursor,
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
    return (service, server, clientA, cursor)
}

private func stopTransport(
    _ server: WorkServiceUnixSocketServer,
    _ clients: [WorkServiceUnixSocketClient]
) async {
    for client in clients { await client.close() }
    await server.stop()
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
        let described = try await fixture.clientA.describeWork(.init(
            work: transportWork, journal: transportJournal, client: transportClientA))
        XCTAssertEqual(described, page.works.first)
        await stopTransport(fixture.server, [fixture.clientA])
    } catch {
        await stopTransport(fixture.server, [fixture.clientA])
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
            commandID: "attach-a", causalCursor: fixture.cursor,
            requestedCapabilities: [.observe, .control, .start, .inspectArtifacts]))
        let attachmentA = try XCTUnwrap(attachedA.attachment)
        let attachedCursor = try XCTUnwrap(attachedA.resultingCursor)
        XCTAssertEqual(attachedA.state, .accepted)

        // The second GUI observes the exact cursor produced by the first attachment.  Its
        // attachment is independent, but Work host ordering remains canonical and is never
        // derived from which socket connected first.
        let attachedB = try await clientB.attach(.init(
            work: transportWork, journal: transportJournal, client: transportClientB,
            commandID: "attach-b", causalCursor: attachedCursor,
            requestedCapabilities: [.observe, .control, .start]))
        let attachmentB = try XCTUnwrap(attachedB.attachment)
        XCTAssertNotEqual(attachmentA.attachment, attachmentB.attachment)
        let cursorB = try XCTUnwrap(attachedB.resultingCursor)

        // Attachment identities are visible projection data, not bearer credentials. A second
        // authenticated GUI cannot borrow A's stronger attachment on any read surface.
        do {
            _ = try await clientB.snapshot(.init(
                work: transportWork, journal: transportJournal,
                attachment: attachmentA.attachment, client: transportClientB,
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

        let started = try await fixture.clientA.command(.init(
            work: transportWork, journal: transportJournal,
            attachment: attachmentA.attachment, commandID: "start-a",
            client: transportClientA, causalCursor: cursorB, kind: .start))
        XCTAssertEqual(started.state, .accepted)
        XCTAssertEqual(started.outcome, .started)
        XCTAssertEqual(started.causalCursor, cursorB)
        XCTAssertEqual(started.resultingCursor?.sequence, cursorB.sequence + 1)

        // A second client can observe the same Work after the first client's mutation; no
        // connection-level host sequence or global client lock is needed for this join.
        let observed = try await clientB.snapshot(.init(
            work: transportWork, journal: transportJournal,
            attachment: attachmentB.attachment, client: transportClientB,
            afterCursor: cursorB, limit: 8))
        XCTAssertTrue(observed.events.contains { $0.commandID == "start-a" })
        XCTAssertEqual(observed.work.currentRun, RunRef("run-1"))
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
            attachment: attachmentB.attachment, client: transportClientB,
            afterCursor: cursorB, limit: 8))
        XCTAssertTrue(events.events.contains { $0.commandID == "start-a" })
        let detached = try await clientB.detach(.init(
            work: transportWork, journal: transportJournal,
            attachment: attachmentB.attachment, client: transportClientB,
            commandID: "detach-b", causalCursor: try XCTUnwrap(started.resultingCursor)))
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
        XCTAssertTrue(try raw.receive().ok)

        let work = WorkRef(workHostID: transportHost.workHostID, workID: "ordered-work")
        let journal = JournalRef.work(work, journalID: "ordered-journal")
        let empty = JournalCursor(journal: journal, sequence: 0)
        let create = WorkServiceCreateWorkRequest(
            work: work, journal: journal, client: transportClientA,
            commandID: "ordered-create", causalCursor: empty)
        let attach = WorkServiceAttachRequest(
            work: work, journal: journal, client: transportClientA,
            commandID: "ordered-attach",
            causalCursor: JournalCursor(
                journal: journal, eventID: "service-event-1", sequence: 1),
            requestedCapabilities: [.observe])
        // These arrive before either response is read.  The second request is only valid if the
        // first request's durable create has been dispatched first on this connection.
        try raw.send(.init(
            id: "ordered-create-request", operation: .createWork, client: transportClientA,
            payload: try transportEnvelopePayload(create)))
        try raw.send(.init(
            id: "ordered-attach-request", operation: .attach, client: transportClientA,
            payload: try transportEnvelopePayload(attach)))
        let createResponse = try raw.receive()
        let attachResponse = try raw.receive()
        XCTAssertEqual(createResponse.id, "ordered-create-request")
        XCTAssertTrue(createResponse.ok)
        XCTAssertEqual(attachResponse.id, "ordered-attach-request")
        XCTAssertTrue(attachResponse.ok)
        let createdData = try XCTUnwrap(createResponse.data)
        let created = try JSONDecoder().decode(
            WorkServiceCreateWorkResponse.self, from: JSONEncoder().encode(createdData))
        XCTAssertEqual(created.receipt.outcome, .created)
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

private final class RawWorkServiceTransportClient: @unchecked Sendable {
    private let descriptor: Int32

    init(path: String) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
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
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw UnwrapFailure(description: "raw connect failed") }
        } catch {
            Darwin.close(descriptor)
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
                let written = Darwin.write(
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
            let count = Darwin.read(descriptor, &byte, 1)
            guard count == 1 else { throw UnwrapFailure(description: "raw socket closed") }
            if byte == UInt8(ascii: "\n") { break }
            line.append(byte)
            guard line.count <= WorkServiceTransportCodec.maxFrameBytes else {
                throw UnwrapFailure(description: "raw response exceeded bound")
            }
        }
        return try WorkServiceTransportCodec.decodeResponse(line)
    }

    func close() { Darwin.close(descriptor) }
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
        XCTAssertTrue(try raw.receive().ok)

        let work = WorkRef(workHostID: transportHost.workHostID, workID: "eof-work")
        let journal = JournalRef.work(work, journalID: "eof-journal")
        let create = WorkServiceCreateWorkRequest(
            work: work, journal: journal, client: transportClientA,
            commandID: "eof-create", causalCursor: JournalCursor(journal: journal, sequence: 0))
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

let casesWorkServiceTransport: [Case] = [
    ("phase3 Work service transport: handshake and read projection", {
        try await test_workServiceTransportHandshakeAndReadProjection()
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
    ("phase3 Work service transport: duplicate and oversized frames are explicit", {
        try await test_workServiceTransportRejectsDuplicateAndOversizedFramesExplicitly()
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
]
