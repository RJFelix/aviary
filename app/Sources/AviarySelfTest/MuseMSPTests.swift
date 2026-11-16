import Foundation
@testable import AviaryCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func museReadChunk(_ handle: FileHandle) throws -> Data? {
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = buffer.withUnsafeMutableBytes { raw in
            read(handle.fileDescriptor, raw.baseAddress, raw.count)
        }
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 { return nil }
        if errno == EINTR { continue }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func museFrame(_ line: String) throws -> MuseMSPFrame {
    try MuseMSPCodec.decode(Data(line.utf8))
}

func test_museMSPFramingKeepsUnicodeSeparatorsAndBoundsPartialLines() throws {
    var framer = MuseMSPLineFramer(limit: 128)
    let first = Data("{\"jsonrpc\":\"2.0\",\"method\":\"note\",\"params\":{\"text\":\"a\u{2028}b\"}}\r\n".utf8)
    let chunks = [first.prefix(11), first.dropFirst(11).prefix(15), first.dropFirst(26)]
    XCTAssertTrue(try framer.append(Data(chunks[0])).isEmpty)
    XCTAssertTrue(try framer.append(Data(chunks[1])).isEmpty)
    let decoded = try XCTUnwrap(try framer.append(Data(chunks[2])).first)
    XCTAssertEqual(try MuseMSPCodec.decode(decoded), .notification(
        method: "note", params: .object(["text": .string("a\u{2028}b")]), emittedAtMs: nil))
    XCTAssertTrue(try framer.append(Data("\n\r\n".utf8)).isEmpty)

    var tiny = MuseMSPLineFramer(limit: 4)
    do {
        _ = try tiny.append(Data("12345\n".utf8))
        XCTFail("oversize complete frame accepted")
    } catch MuseMSPError.frameTooLarge { }
    var unfinished = MuseMSPLineFramer(limit: 4)
    do {
        _ = try unfinished.append(Data("12345".utf8))
        XCTFail("oversize partial frame accepted")
    } catch MuseMSPError.frameTooLarge { }
}

func test_museMSPEnvelopeShapesAndCorrelations() throws {
    // The denial is excerpted from the published usershell-without-grant corpus scenario.
    let errorLine = """
    {"error":{"code":-32010,"data":{"capability":"userShell","kind":"capabilityRequired","retryable":false},"message":"session/userShell requires the userShell capability"},"id":"a1","jsonrpc":"2.0"}
    """
    guard case .failure(.string("a1"), let remote) = try museFrame(errorLine) else {
        return XCTFail("wrong error envelope")
    }
    XCTAssertEqual(remote.code, -32010)
    XCTAssertEqual(remote.kind, "capabilityRequired")
    XCTAssertEqual(remote.retryable, false)
    XCTAssertEqual(remote.data?["capability"]?.stringValue, "userShell")
    let deferred = MuseMSPRemoteError(code: -32601, message: "method not found",
                                      data: .object(["kind": .string("methodNotFound")]))
    XCTAssertTrue(deferred.isMethodNotFound)

    XCTAssertEqual(try museFrame("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"),
                   .success(id: .integer(1), result: .object([:])))
    XCTAssertEqual(try museFrame("{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{}}"),
                   .success(id: .string("1"), result: .object([:])))
    XCTAssertEqual(try museFrame("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}"),
                   .notification(method: "initialized", params: nil, emittedAtMs: nil))
    do {
        _ = try museFrame("{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"result\":{},\"error\":{}}")
        XCTFail("result plus error accepted")
    } catch MuseMSPError.invalidFrame { }
    do {
        _ = try museFrame("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"x\"}")
        XCTFail("null request id accepted")
    } catch MuseMSPError.invalidFrame { }
}

func test_museMSPEncodesOneLineAndOmitsAbsentParams() throws {
    let encoded = try MuseMSPCodec.encode(.request(id: .string("a1"),
                                                   method: "account/read", params: nil))
    XCTAssertEqual(encoded.last, 0x0A)
    XCTAssertEqual(encoded.filter { $0 == 0x0A }.count, 1)
    let value = try XCTUnwrap(JSONValue.parse(Data(encoded.dropLast())))
    XCTAssertNil(value["params"])
    XCTAssertEqual(value["id"]?.stringValue, "a1")
    XCTAssertEqual(value["jsonrpc"]?.stringValue, "2.0")
}

func test_museMSPHandshakeCatalogAccountAndAckAreDistinct() throws {
    let raw = JSONValue.object([
        "schema": .object(["version": 1, "fingerprint": .string(MuseMSP.stableFingerprint)]),
        "serverInfo": .object(["name": "muse", "version": "1.0"]),
        "grantedCapabilities": .array([.string("userShell")]),
        "experimentalApi": true,
    ])
    let handshake = try MuseMSPHandshake(raw)
    XCTAssertFalse(handshake.fingerprintDiffersFromDocumentation)
    XCTAssertEqual(handshake.sessionDurability, "durable")

    let catalog = try MuseMSPModelCatalog(.object([
        "providerId": "meta", "source": "providerCatalog", "profileId": .null,
        "models": .array([.object([
            "modelId": "muse-spark-1.2", "displayLabel": "Muse Spark",
            "providerId": "meta", "isDefault": true, "isActive": false,
        ])]),
    ]))
    XCTAssertEqual(catalog.models.first?.id, "muse-spark-1.2")
    XCTAssertEqual(catalog.source, "providerCatalog")
    let account = try MuseMSPAccountState(.object([
        "state": "loggedOut", "credentialRequired": true,
    ]))
    XCTAssertTrue(account.credentialRequired)
    XCTAssertNil(account.label)
    let ack = try MuseMSPCommandAck(.object([
        "commandId": "0198f0aa-1111-7000-8000-0000000000aa", "status": "accepted",
    ]))
    XCTAssertEqual(ack.status, "accepted")
    // No terminal outcome can be inferred from this acknowledgement.
}

func test_museMSPConnectionHandshakesAndPreservesHostError() async throws {
    let toHost = Pipe()
    let fromHost = Pipe()
    let connection = MuseMSPConnection(stdin: toHost.fileHandleForWriting,
                                       stdout: fromHost.fileHandleForReading)
    let watchdog = Task.detached {
        try? await Task.sleep(for: .seconds(8))
        guard !Task.isCancelled else { return }
        try? toHost.fileHandleForWriting.close()
        try? fromHost.fileHandleForWriting.close()
    }
    defer { watchdog.cancel() }
    let host = Task.detached {
        var framer = MuseMSPLineFramer()
        while let chunk = try museReadChunk(toHost.fileHandleForReading) {
            for line in try framer.append(chunk) {
                let value = try XCTUnwrap(JSONValue.parse(line))
                let method = value["method"]?.stringValue
                if method == "initialize" {
                    let id = try XCTUnwrap(value["id"]?.stringValue)
                    let result: JSONValue = .object([
                        "schema": .object(["version": 1, "fingerprint": .string(MuseMSP.stableFingerprint)]),
                        "serverInfo": .object(["name": "muse", "version": "1.0"]),
                        "grantedCapabilities": .array([]), "experimentalApi": false,
                    ])
                    try fromHost.fileHandleForWriting.write(contentsOf:
                        MuseMSPCodec.encode(.success(id: .string(id), result: result)))
                } else if method == "model/list" {
                    let id = try XCTUnwrap(value["id"]?.stringValue)
                    let error = MuseMSPRemoteError(code: -32001, message: "busy",
                        data: .object(["kind": "overloaded", "retryable": true]))
                    try fromHost.fileHandleForWriting.write(contentsOf:
                        MuseMSPCodec.encode(.failure(id: .string(id), error: error)))
                    return
                }
            }
        }
    }
    let handshake = try await connection.initialize(clientName: "aviary", version: "0.1")
    XCTAssertEqual(handshake.serverName, "muse")
    do {
        _ = try await connection.modelList()
        XCTFail("host error was lost")
    } catch MuseMSPError.remote(let error) {
        XCTAssertEqual(error.kind, "overloaded")
        XCTAssertEqual(error.retryable, true)
    }
    await connection.close()
    try? toHost.fileHandleForWriting.close()
    try? fromHost.fileHandleForWriting.close()
    _ = try await host.value
}

func test_museMSPPendingHandshakeFailsOnConnectionLoss() async throws {
    let toHost = Pipe()
    let fromHost = Pipe()
    let connection = MuseMSPConnection(stdin: toHost.fileHandleForWriting,
                                       stdout: fromHost.fileHandleForReading)
    let watchdog = Task.detached {
        try? await Task.sleep(for: .seconds(8))
        guard !Task.isCancelled else { return }
        try? toHost.fileHandleForWriting.close()
        try? fromHost.fileHandleForWriting.close()
    }
    defer { watchdog.cancel() }
    let initializing = Task {
        try await connection.initialize(clientName: "aviary", version: "0.1")
    }
    let outbound = try await Task.detached {
        try museReadChunk(toHost.fileHandleForReading)
    }.value
    XCTAssertNotNil((outbound ?? Data()).range(of: Data("initialize".utf8)))
    try fromHost.fileHandleForWriting.close()
    do {
        _ = try await initializing.value
        XCTFail("EOF left initialize waiting")
    } catch MuseMSPError.connectionClosed { }
    XCTAssertEqual(await connection.terminalError, .connectionClosed)
    try? toHost.fileHandleForWriting.close()
}

func test_museMSPInstalledBinarySmokeWhenRequested() async throws {
    guard let executable = ProcessInfo.processInfo.environment["AVIARY_MUSE_EXECUTABLE"],
          !executable.isEmpty else { return }
    let owner = try await MuseMSPProcess.launch(
        executable: executable, cwd: FileManager.default.currentDirectoryPath,
        experimentalAPI: true)
    do {
        let handshake = await owner.handshake
        XCTAssertEqual(handshake.schemaVersion, 1)
        XCTAssertFalse(handshake.fingerprintDiffersFromDocumentation)
        let catalog = try await owner.connection.modelList()
        XCTAssertFalse(catalog.providerID.isEmpty)
        // Account is the host's projected lane only; never load or print auth files.
        let account = try await owner.connection.accountRead()
        XCTAssertFalse(account.state.isEmpty)
        await owner.stop()
        XCTAssertFalse(await owner.isRunning)
    } catch {
        await owner.stop()
        throw error
    }
}

func test_museMSPSessionSchemaShapesKeepAckSeparateFromViewTerminal() throws {
    let commandID = MuseMSPSession.newCommandID()
    XCTAssertEqual(commandID.count, 36)
    XCTAssertEqual(commandID[commandID.index(commandID.startIndex, offsetBy: 14)], "7")
    XCTAssertEqual(commandID[commandID.index(commandID.startIndex, offsetBy: 19)], "8")

    let start = try MuseMSPSessionStart(.object([
        "session": .object(["sessionId": .string("s1"), "status": .string("idle")]),
        "viewCursor": .string("c1"),
    ]))
    XCTAssertEqual(start.sessionID, "s1")
    XCTAssertEqual(start.viewCursor, "c1")

    let ack = try MuseMSPTurnStartAck(.object([
        "commandId": .string(commandID), "status": .string("accepted"),
        "disposition": .string("started"), "startedNewTurn": true,
        "turnId": .string("t1"),
    ]))
    XCTAssertEqual(ack.turnID, "t1")
    XCTAssertEqual(ack.status, "accepted")

    let delta = try MuseMSPViewEvent(.object([
        "method": .string("item/delta"), "params": .object([
            "sessionId": .string("s1"), "viewCursor": .string("c2"),
            "itemId": .string("i1"), "delta": .string("hello"),
        ]),
    ]))
    XCTAssertEqual(delta.textDelta?.field, "text")
    XCTAssertEqual(delta.textDelta?.delta, "hello")
    XCTAssertEqual(delta.itemID, "i1")
    XCTAssertNil(delta.turnTerminal)

    let reasoning = try MuseMSPViewEvent(.object([
        "method": .string("item/delta"), "params": .object([
            "sessionId": .string("s1"), "viewCursor": .string("c2b"),
            "itemId": .string("r1"), "field": .string("summary.0"),
            "delta": .string("internal"),
        ]),
    ]))
    XCTAssertEqual(reasoning.reasoningDelta?.delta, "internal")

    let tool = try MuseMSPViewEvent(.object([
        "method": .string("item/completed"), "params": .object([
            "sessionId": .string("s1"), "viewCursor": .string("c2c"),
            "item": .object(["itemId": .string("tool-1"), "kind": .string("toolCall"),
                              "status": .string("completed"), "tool": .string("python")]),
        ]),
    ]))
    XCTAssertEqual(tool.itemKind, "toolCall")
    XCTAssertEqual(tool.item?["tool"]?.stringValue, "python")

    let approval = try MuseMSPViewEvent(.object([
        "method": .string("approval/requested"), "params": .object([
            "sessionId": .string("s1"), "viewCursor": .string("c2d"),
            "approvalId": .string("a1"),
            "currentRequirementId": .object(["approvalId": .string("a1"), "sourceIndex": .number(3)]),
        ]),
    ]))
    XCTAssertEqual(approval.currentApprovalRequirement?.sourceIndex, 3)

    let usage = try MuseMSPViewEvent(.object([
        "method": .string("turn/completed"), "params": .object([
            "sessionId": .string("s1"), "viewCursor": .string("c2e"),
            "turnId": .string("t1"), "terminal": .string("completed"),
            "usage": .object(["inputTokens": .number(4), "outputTokens": .number(2)]),
        ]),
    ]))
    XCTAssertEqual(usage.usage?["usage"]?["outputTokens"]?.intValue, 2)

    let completed = try MuseMSPViewEvent(.object([
        "method": .string("turn/completed"), "params": .object([
            "sessionId": .string("s1"), "viewCursor": .string("c3"),
            "turnId": .string("t1"), "terminal": .string("completed"),
            "sourceRange": .object([:]),
        ]),
    ]))
    XCTAssertEqual(completed.turnTerminal?.turnID, ack.turnID)
    XCTAssertEqual(completed.turnTerminal?.terminal, "completed")

    let page = try MuseMSPViewPage(.object([
        "events": .array([.object([
            "method": .string("turn/completed"), "params": completed.params,
        ])]), "nextCursor": .null,
    ]))
    XCTAssertEqual(page.events.count, 1)
    XCTAssertNil(page.nextCursor)
    let requirement = try MuseMSPApprovalRequirement(.object([
        "approvalId": .string("a1"), "sourceIndex": 2,
    ]))
    XCTAssertEqual(requirement.raw["sourceIndex"]?.intValue, 2)
}

func test_museMSPSessionResumeRetainsHistoryModeAndChecksIdentity() throws {
    let response = JSONValue.object([
        "session": .object([
            "sessionId": .string("s-resume"),
            "workspaceRoot": .string("/tmp/muse-workspace"),
            "status": .string("idle"),
        ]),
        "history": .object([
            "mode": .string("inline"),
            "items": .array([.object(["itemId": .string("i1"), "kind": .string("agentMessage")])]),
            "snapshot": .null,
        ]),
        "pendingRequests": .array([]),
        "viewCursor": .string("cursor-9"),
    ])
    let resumed = try MuseMSPSessionResume(
        response, expectedSessionID: "s-resume", expectedWorkspaceRoot: "/tmp/muse-workspace")
    XCTAssertEqual(resumed.sessionID, "s-resume")
    XCTAssertEqual(resumed.viewCursor, "cursor-9")
    XCTAssertEqual(resumed.historyMode, "inline")
    XCTAssertEqual(resumed.inlineItems?.count, 1)
    XCTAssertTrue(resumed.pendingRequests.isEmpty)

    // Metadata-only/none history is a valid resume response, but it is not a claim
    // that execution or a model context was restored.
    let metadataOnly = JSONValue.object([
        "session": .object(["sessionId": .string("s-resume")]),
        "history": .object(["mode": .string("none"), "items": .null]),
        "pendingRequests": .array([]), "viewCursor": .string("cursor-10"),
    ])
    let resumedWithoutInlineItems = try MuseMSPSessionResume(
        metadataOnly, expectedSessionID: "s-resume")
    XCTAssertEqual(resumedWithoutInlineItems.historyMode, "none")
    XCTAssertNil(resumedWithoutInlineItems.inlineItems)

    do {
        _ = try MuseMSPSessionResume(response, expectedSessionID: "another-session")
        XCTFail("host response for a different session was accepted")
    } catch MuseMSPError.invalidResponse { }
    do {
        _ = try MuseMSPSessionResume(
            response, expectedSessionID: "s-resume", expectedWorkspaceRoot: "/tmp/other-workspace")
        XCTFail("host response for a different workspace was accepted")
    } catch MuseMSPError.invalidResponse { }
}

/// Explicitly opt in with AVIARY_MUSE_LIVE_TEST=1 and AVIARY_MUSE_EXECUTABLE.
/// This makes one authenticated provider turn; it is not part of the default suite.
/// The host cannot run workspace shell or write files. The installed 1.3 host's
/// ephemeral `--no-session-log` profile currently admits turns but never advances
/// them, so this proof intentionally uses the durable profile until that host bug
/// is fixed upstream.
func test_museMSPAuthenticatedRestrictedTinyTurnWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["AVIARY_MUSE_LIVE_TEST"] == "1" else { return }
    let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["AVIARY_MUSE_EXECUTABLE"])
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("aviary-muse-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
    let owner: MuseMSPProcess
    do {
        owner = try await MuseMSPProcess.launch(
            executable: executable, cwd: workspace.path,
            disableShell: true, disableWrite: true)
    } catch {
        try? FileManager.default.removeItem(at: workspace)
        throw error
    }
    do {
        let session = try await owner.connection.sessionStart(
            commandID: MuseMSPSession.newCommandID(), workspaceRoot: workspace.path)
        let sessionID = session.sessionID
        let connection = await owner.connection
        let terminal = Task { () -> (turnID: String, outcome: String, sawText: Bool)? in
            var sawText = false
            for await incoming in connection.incoming {
                guard let event = try? MuseMSPViewEvent(incoming),
                      event.sessionID == sessionID else { continue }
                if let delta = event.textDelta, delta.field == "text", !delta.delta.isEmpty {
                    sawText = true
                }
                if let item = event.completedItem,
                   item["kind"]?.stringValue == "agentMessage",
                   item["text"]?.stringValue?.isEmpty == false {
                    sawText = true
                }
                if let ending = event.turnTerminal {
                    return (ending.turnID, ending.terminal, sawText)
                }
            }
            return nil
        }
        let timeout = Task.detached {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await owner.stop()
        }
        let commandID = MuseMSPSession.newCommandID()
        let ack: MuseMSPTurnStartAck
        do {
            ack = try await owner.connection.turnStart(
                sessionID: sessionID, commandID: commandID,
                text: "Reply with exactly OK. Do not call tools.")
        } catch {
            timeout.cancel()
            terminal.cancel()
            throw error
        }
        XCTAssertEqual(ack.commandID, commandID)
        XCTAssertEqual(ack.status, "accepted")
        // The ack is not a terminal: wait for the durable view event, bounded by
        // the watchdog stopping the child and finishing the incoming stream.
        let result = await terminal.value
        timeout.cancel()
        XCTAssertEqual(result?.turnID, ack.turnID)
        XCTAssertEqual(result?.outcome, "completed")
        XCTAssertTrue(result?.sawText == true)
        await owner.stop()
        try FileManager.default.removeItem(at: workspace)
    } catch {
        await owner.stop()
        try? FileManager.default.removeItem(at: workspace)
        throw error
    }
}
