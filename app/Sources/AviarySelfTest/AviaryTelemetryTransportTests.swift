import Foundation
import OpenTelemetrySdk
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AviaryCore

private func telemetryTransportFrame(
    traceparent: String?
) throws -> Data {
    let envelope = WorkServiceTransportRequestEnvelope(
        id: "telemetry-transport-request", operation: .listWorks,
        client: ClientRef("telemetry-client"), traceparent: traceparent,
        payload: .object([:]))
    let frame = try WorkServiceTransportCodec.encodeFrame(envelope)
    return Data(frame.dropLast())
}

private func telemetryTransportPayload<T: Encodable>(_ value: T) throws -> JSONValue {
    JSONValue.parse(try JSONEncoder().encode(value)) ?? .null
}

func testAviaryTelemetryTransportEnvelopeCarriesTraceparent() throws {
    let traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    let decoded = try WorkServiceTransportCodec.decodeRequest(
        telemetryTransportFrame(traceparent: traceparent))
    XCTAssertEqual(decoded.traceparent, traceparent)
}

func testAviaryTelemetryTransportIgnoresMalformedTraceparent() throws {
    let malformed = "not-a-w3c-traceparent"
    let decoded = try WorkServiceTransportCodec.decodeRequest(
        telemetryTransportFrame(traceparent: malformed))
    XCTAssertEqual(decoded.id, "telemetry-transport-request")
    XCTAssertEqual(decoded.operation, .listWorks)
    XCTAssertEqual(decoded.traceparent, malformed,
                   "wire metadata is preserved; the server decides whether it is usable")
}

private let telemetryTransportHost = WorkHostRef("telemetry-transport-host")
private let telemetryTransportClient = ClientRef("telemetry-transport-client")

private func telemetryTransportSocketPath() -> String {
    let root = URL(fileURLWithPath: "/tmp")
        .appendingPathComponent("aviary-telemetry-transport-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    return root.appendingPathComponent("service.sock").path
}

private struct TelemetryRawTransportError: Error {}

private final class TelemetryRawTransportClient: @unchecked Sendable {
    private let descriptor: Int32

    init(path: String) throws {
        let descriptor = AviaryPOSIX.streamSocket()
        guard descriptor >= 0 else { throw TelemetryRawTransportError() }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            var pathBytes = Data(path.utf8)
            guard !pathBytes.isEmpty, pathBytes.count <= 103 else {
                throw TelemetryRawTransportError()
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
            guard result == 0 else { throw TelemetryRawTransportError() }
        } catch {
            _ = AviaryPOSIX.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    func send(_ envelope: WorkServiceTransportRequestEnvelope) throws {
        let frame = try WorkServiceTransportCodec.encodeFrame(envelope)
        try frame.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = AviaryPOSIX.write(
                    descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw TelemetryRawTransportError() }
                offset += count
            }
        }
    }

    func receive() throws -> WorkServiceTransportResponseEnvelope {
        var line = Data()
        while true {
            var byte: UInt8 = 0
            let count = withUnsafeMutableBytes(of: &byte) { bytes in
                AviaryPOSIX.read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count == 1 else { throw TelemetryRawTransportError() }
            if byte == UInt8(ascii: "\n") { break }
            line.append(byte)
            guard line.count <= WorkServiceTransportCodec.maxFrameBytes else {
                throw TelemetryRawTransportError()
            }
        }
        return try WorkServiceTransportCodec.decodeResponse(line)
    }

    func close() { _ = AviaryPOSIX.close(descriptor) }
}

private func telemetryAttributeString(
    _ span: SpanData, key: String
) -> String? {
    guard case .string(let value)? = span.attributes[key] else { return nil }
    return value
}

func testAviaryTelemetryTransportPropagatesClientToServerSpan() async throws {
    let path = telemetryTransportSocketPath()
    let service = InMemoryWorkService(
        host: telemetryTransportHost, instanceID: "telemetry-transport-instance",
        startIdentity: "telemetry-transport-start",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [
            telemetryTransportClient: [.observe],
        ]))
    let server = WorkServiceUnixSocketServer(
        endpoint: WorkServiceTransportEndpoint(path: path), service: service)
    try await server.start()
    let client = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: telemetryTransportClient)
    do {
        let (_, spans) = try await AviaryTelemetry.withRecording {
            _ = try await client.connect(build: "telemetry-transport-test")
            return try await AviaryTelemetry.withSpan(
                "aviary.gui.poll", attributes: ["rpc.system": .string("aviary.work")]
            ) {
                try await client.listWorks(
                    WorkServiceListRequest(client: telemetryTransportClient, pageSize: 1))
            }
        }
        let clients = spans.filter { $0.kind == .client }
        let servers = spans.filter { $0.kind == .server }
        let clientList = try XCTUnwrap(clients.first {
            telemetryAttributeString($0, key: "rpc.method") == "list_works"
        })
        let serverList = try XCTUnwrap(servers.first {
            telemetryAttributeString($0, key: "rpc.method") == "list_works"
                && $0.parentSpanId != nil
        })
        XCTAssertEqual(clientList.traceId.hexString, serverList.traceId.hexString)
        XCTAssertEqual(serverList.parentSpanId?.hexString, clientList.spanId.hexString)
        XCTAssertEqual(
            telemetryAttributeString(clientList, key: "rpc.system"), "aviary.work")
        XCTAssertEqual(
            telemetryAttributeString(clientList, key: "rpc.method"), "list_works")
        XCTAssertEqual(
            telemetryAttributeString(clientList, key: "aviary.request.id"),
            telemetryAttributeString(serverList, key: "aviary.request.id"))
        XCTAssertNil(telemetryAttributeString(clientList, key: "request.id"))
        XCTAssertEqual(telemetryAttributeString(clientList, key: "aviary.outcome"), "completed")
        XCTAssertEqual(telemetryAttributeString(serverList, key: "aviary.outcome"), "completed")
    } catch {
        await client.close()
        await server.stop()
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent())
        throw error
    }
    await client.close()
    await server.stop()
    try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: path).deletingLastPathComponent())
}

func testAviaryTelemetryTransportSuppressesUnparentedReadSpans() async throws {
    let path = telemetryTransportSocketPath()
    let service = InMemoryWorkService(
        host: telemetryTransportHost, instanceID: "telemetry-unparented-instance",
        startIdentity: "telemetry-unparented-start",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [
            telemetryTransportClient: [.observe],
        ]))
    let server = WorkServiceUnixSocketServer(
        endpoint: WorkServiceTransportEndpoint(path: path), service: service)
    try await server.start()
    let client = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: telemetryTransportClient)
    do {
        let (_, spans) = try await AviaryTelemetry.withRecording {
            _ = try await client.connect(build: "telemetry-unparented-test")
            return try await client.listWorks(
                WorkServiceListRequest(client: telemetryTransportClient, pageSize: 1))
        }
        XCTAssertTrue(spans.contains {
            $0.kind == .client && telemetryAttributeString($0, key: "rpc.method") == "handshake"
        })
        XCTAssertTrue(spans.contains {
            $0.kind == .server && telemetryAttributeString($0, key: "rpc.method") == "handshake"
        })
        XCTAssertFalse(spans.contains {
            telemetryAttributeString($0, key: "rpc.method") == "list_works"
        }, "unparented GUI polling reads remain out of the trace stream")
    } catch {
        await client.close()
        await server.stop()
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent())
        throw error
    }
    await client.close()
    await server.stop()
    try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: path).deletingLastPathComponent())
}

func testAviaryTelemetryTransportIgnoresMalformedServerParent() async throws {
    let path = telemetryTransportSocketPath()
    let service = InMemoryWorkService(
        host: telemetryTransportHost, instanceID: "telemetry-malformed-instance",
        startIdentity: "telemetry-malformed-start",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [
            telemetryTransportClient: [.observe],
        ]))
    let server = WorkServiceUnixSocketServer(
        endpoint: WorkServiceTransportEndpoint(path: path), service: service)
    try await server.start()
    do {
        let (_, spans) = try await AviaryTelemetry.withRecording {
            let raw = try TelemetryRawTransportClient(path: path)
            defer { raw.close() }
            let handshake = WorkServiceHandshakeRequest(client: telemetryTransportClient)
            try raw.send(WorkServiceTransportRequestEnvelope(
                id: "malformed-handshake", operation: .handshake,
                client: telemetryTransportClient,
                traceparent: "not-a-traceparent",
                payload: try telemetryTransportPayload(handshake)))
            XCTAssertTrue(try raw.receive().ok)
            let request = WorkServiceListRequest(client: telemetryTransportClient, pageSize: 1)
            try raw.send(WorkServiceTransportRequestEnvelope(
                id: "malformed-list", operation: .listWorks,
                client: telemetryTransportClient,
                traceparent: "not-a-traceparent",
                payload: try telemetryTransportPayload(request)))
            let response = try raw.receive()
            XCTAssertTrue(response.ok)
            return response
        }
        let malformedHandshake = try XCTUnwrap(spans.first {
            $0.kind == .server
                && telemetryAttributeString($0, key: "rpc.method") == "handshake"
                && $0.parentSpanId == nil
        })
        XCTAssertEqual(
            telemetryAttributeString(malformedHandshake, key: "aviary.outcome"), "completed")
        XCTAssertFalse(spans.contains {
            $0.kind == .server
                && telemetryAttributeString($0, key: "rpc.method") == "list_works"
        }, "malformed read parent is ignored and the routine read remains untraced")
    } catch {
        await server.stop()
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent())
        throw error
    }
    await server.stop()
    try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: path).deletingLastPathComponent())
}

func testAviaryTelemetryTransportFallsBackBeforeWriteAtExactFrameBoundary() async throws {
    let path = telemetryTransportSocketPath()
    let boundaryClient = ClientRef(
        String(repeating: "b", count: WorkServiceBounds.maxIdentityCharacters))
    let service = InMemoryWorkService(
        host: telemetryTransportHost, instanceID: "telemetry-boundary-instance",
        startIdentity: "telemetry-boundary-start",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [
            boundaryClient: [.observe],
        ]))
    let request = WorkServiceListRequest(
        client: boundaryClient, pageSize: WorkServiceBounds.maxPageSize,
        pageToken: String(repeating: "0", count: 512))
    let payload = try telemetryTransportPayload(request)
    // connect() consumes ws-1 for its handshake, so listWorks() deterministically uses ws-2.
    let untracedEnvelope = WorkServiceTransportRequestEnvelope(
        id: "ws-2", operation: .listWorks, client: boundaryClient,
        payload: payload)
    let tracedEnvelope = WorkServiceTransportRequestEnvelope(
        id: "ws-2", operation: .listWorks, client: boundaryClient,
        traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        payload: payload)
    let untracedFrame = try WorkServiceTransportCodec.encodeFrame(untracedEnvelope)
    let tracedFrame = try WorkServiceTransportCodec.encodeFrame(tracedEnvelope)
    XCTAssertEqual(
        try WorkServiceTransportCodec.encodeFrame(untracedEnvelope, maxBytes: untracedFrame.count).count,
        untracedFrame.count)
    XCTAssertTrue(tracedFrame.count > untracedFrame.count)
    do {
        _ = try WorkServiceTransportCodec.encodeFrame(
            tracedEnvelope, maxBytes: untracedFrame.count)
        XCTFail("traceparent unexpectedly fit the exact untraced frame boundary")
    } catch {
        if case WorkServiceTransportError.frameTooLarge = error {
            XCTAssertTrue(true)
        } else {
            XCTFail("unexpected exact-boundary error: \(error)")
        }
    }

    let server = WorkServiceUnixSocketServer(
        endpoint: WorkServiceTransportEndpoint(path: path), service: service)
    try await server.start()
    let client = WorkServiceUnixSocketClient(
        endpoint: WorkServiceTransportEndpoint(path: path), client: boundaryClient,
        maxFrameBytes: untracedFrame.count)
    do {
        let (page, spans) = try await AviaryTelemetry.withRecording {
            _ = try await client.connect(build: "telemetry-boundary-test")
            // The exact-boundary call can succeed only if the oversized traced envelope is
            // discarded before write and the same request ID is written once without metadata.
            return try await AviaryTelemetry.withSpan("aviary.gui.poll") {
                try await client.listWorks(request)
            }
        }
        XCTAssertTrue(page.works.isEmpty)
        XCTAssertTrue(spans.contains {
            $0.kind == .client
                && telemetryAttributeString($0, key: "rpc.method") == "list_works"
                && telemetryAttributeString($0, key: "aviary.outcome") == "completed"
        })
        XCTAssertFalse(spans.contains {
            $0.kind == .server
                && telemetryAttributeString($0, key: "rpc.method") == "list_works"
        }, "fallback omits metadata and remains an unparented routine read")
    } catch {
        await client.close()
        await server.stop()
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent())
        throw error
    }
    await client.close()
    await server.stop()
    try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: path).deletingLastPathComponent())
}

let casesAviaryTelemetryTransport: [Case] = [
    ("phase5 telemetry transport: quiet read acknowledgements still have uncertain mutation outcomes", {
        XCTAssertEqual(workServiceClientTraceOutcome(for: WorkServiceTransportError.disconnected,
            operation: .acknowledgeRead, didStartWrite: true), "indeterminate")
        XCTAssertEqual(workServiceClientTraceOutcome(for: WorkServiceTransportError.disconnected,
            operation: .snapshot, didStartWrite: true), "unavailable")
        XCTAssertEqual(workServiceClientTraceOutcome(for: WorkServiceTransportError.disconnected,
            operation: .command, didStartWrite: false), "unavailable")
        XCTAssertEqual(workServiceClientTraceOutcome(for: WorkServiceTransportError.invalidFrame,
            operation: .command, didStartWrite: true), "indeterminate")
    }),
    ("phase5 telemetry transport: traceparent envelope round trip", {
        try testAviaryTelemetryTransportEnvelopeCarriesTraceparent()
    }),
    ("phase5 telemetry transport: malformed traceparent is not a request failure", {
        try testAviaryTelemetryTransportIgnoresMalformedTraceparent()
    }),
    ("phase5 telemetry transport: client and server spans share trace context", {
        try await testAviaryTelemetryTransportPropagatesClientToServerSpan()
    }),
    ("phase5 telemetry transport: malformed server parent is ignored", {
        try await testAviaryTelemetryTransportIgnoresMalformedServerParent()
    }),
    ("phase5 telemetry transport: unparented reads are suppressed", {
        try await testAviaryTelemetryTransportSuppressesUnparentedReadSpans()
    }),
    ("phase5 telemetry transport: trace metadata falls back before exact frame-boundary write", {
        try await testAviaryTelemetryTransportFallsBackBeforeWriteAtExactFrameBoundary()
    }),
]
