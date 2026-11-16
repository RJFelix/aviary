import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Native Swift transport for the Muse Session Protocol (MSP). The caller owns the
/// `muse serve` child and passes its stdin/stdout handles; stderr is never protocol data.
///
/// Wire source: https://meta-models.github.io/muse-code-sdk/next/guides/msp-wire/
/// Reference generated from commit 6a4ea794fed2ad356ff7f601df742d4779470e5e.
/// MSP is pre-1.0. The fingerprint is a warning, not an authority or hard gate.
public enum MuseMSP {
    /// 1.3.0-R3401.1 stable bundle, exported with `muse schema generate-json-schema`.
    public static let stableFingerprint =
        "sha256:7469c9e352e67def4a59df7e439984d7194fa351e1c8b7abb34060fd977ced81"
    /// Developer Preview's experimental bundle; the installed binary exports it
    /// with `muse schema generate-json-schema --experimental`. `initialize` still
    /// reports the stable-surface fingerprint, even when experimentalApi is true.
    public static let experimentalFingerprint =
        "sha256:2db88d9ee93131257757ab3cf74026eab9079813a4cb82c45cc231901a170fc6"
    public static let defaultFrameLimit = 10 * 1024 * 1024
}

public enum MuseMSPError: LocalizedError, Sendable, Equatable {
    case invalidFrame
    case frameTooLarge
    case invalidResponse
    case invalidHandshake
    case notInitialized
    case alreadyInitialized
    case connectionClosed
    case eventOverflow
    case canceledLocally
    case writeTimedOut
    case requestTimedOut
    case transport(String)
    /// A host error is kept intact. Branch on `data.kind`, never message text.
    case remote(MuseMSPRemoteError)

    public var errorDescription: String? {
        switch self {
        case .invalidFrame: return "Muse sent a malformed protocol frame."
        case .frameTooLarge: return "Muse sent a protocol frame larger than Aviary can accept."
        case .invalidResponse: return "Muse returned an incomplete or unexpected response."
        case .invalidHandshake: return "Muse could not establish a compatible connection."
        case .notInitialized: return "The Muse connection is not ready."
        case .alreadyInitialized: return "The Muse connection was already initialized."
        case .connectionClosed: return "Muse closed its connection."
        case .eventOverflow: return "Muse produced updates faster than Aviary could consume them."
        case .canceledLocally: return "The Muse request was cancelled locally."
        case .writeTimedOut: return "Muse did not accept the request bytes in time."
        case .requestTimedOut: return "Muse did not acknowledge the request in time."
        case .transport: return "The local Muse connection failed."
        case .remote(let error): return "Muse rejected the request (code \(error.code))."
        }
    }
}

public struct MuseMSPRemoteError: Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public var kind: String? { data?["kind"]?.stringValue }
    public var retryable: Bool? { data?["retryable"]?.boolValue }
    /// The release schema can advertise methods which a particular binary defers
    /// behind its parity gate. Keep this machine-readable; never branch on the
    /// host's human message (which is intentionally not stable).
    public var isMethodNotFound: Bool { code == -32601 || kind == "methodNotFound" }
}

public enum MuseMSPRequestID: Sendable, Hashable {
    case string(String)
    case integer(Int)

    fileprivate var json: JSONValue {
        switch self {
        case .string(let value): .string(value)
        case .integer(let value): .number(Double(value))
        }
    }

    fileprivate init?(_ value: JSONValue) {
        switch value {
        case .string(let string): self = .string(string)
        case .number(let number):
            guard number.isFinite, number.rounded() == number,
                  let integer = value.intValue else { return nil }
            self = .integer(integer)
        default: return nil
        }
    }
}

public enum MuseMSPFrame: Sendable, Equatable {
    case request(id: MuseMSPRequestID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?, emittedAtMs: Int?)
    case success(id: MuseMSPRequestID, result: JSONValue)
    case failure(id: MuseMSPRequestID?, error: MuseMSPRemoteError)
}

/// Incremental LF-only framing. U+2028/U+2029 remain ordinary UTF-8 JSON bytes.
public struct MuseMSPLineFramer: Sendable {
    public let limit: Int
    private var line = Data()

    public init(limit: Int = MuseMSP.defaultFrameLimit) {
        self.limit = max(1, min(limit, MuseMSP.defaultFrameLimit))
    }

    public mutating func append(_ chunk: Data) throws -> [Data] {
        var completed: [Data] = []
        for byte in chunk {
            if byte == 0x0A {
                if line.last == 0x0D { line.removeLast() }
                guard line.count <= limit else { throw MuseMSPError.frameTooLarge }
                if !line.isEmpty { completed.append(line) }
                line.removeAll(keepingCapacity: true)
            } else {
                guard line.count < limit + 1 else { throw MuseMSPError.frameTooLarge }
                line.append(byte)
            }
        }
        if line.count > limit + (line.last == 0x0D ? 1 : 0) {
            throw MuseMSPError.frameTooLarge
        }
        return completed
    }

    public var hasPartialFrame: Bool { !line.isEmpty }
}

public enum MuseMSPCodec {
    public static func decode(_ line: Data) throws -> MuseMSPFrame {
        guard let value = JSONValue.parse(line), case .object = value,
              value["jsonrpc"]?.stringValue == "2.0" else {
            throw MuseMSPError.invalidFrame
        }
        let idValue = value["id"]
        let id = idValue.flatMap(MuseMSPRequestID.init)
        if let method = value["method"]?.stringValue {
            guard !method.isEmpty, value["result"] == nil, value["error"] == nil else {
                throw MuseMSPError.invalidFrame
            }
            if let idValue {
                guard !idValue.isNull, let id else { throw MuseMSPError.invalidFrame }
                return .request(id: id, method: method, params: value["params"])
            }
            return .notification(method: method, params: value["params"],
                                 emittedAtMs: value["emittedAtMs"]?.intValue)
        }
        guard idValue != nil, value["params"] == nil else { throw MuseMSPError.invalidFrame }
        if let result = value["result"] {
            guard let id, value["error"] == nil, case .object = result else {
                throw MuseMSPError.invalidFrame
            }
            return .success(id: id, result: result)
        }
        guard let error = value["error"], case .object = error,
              let code = error["code"]?.intValue,
              let message = error["message"]?.stringValue else {
            throw MuseMSPError.invalidFrame
        }
        guard id != nil || idValue?.isNull == true else { throw MuseMSPError.invalidFrame }
        return .failure(id: id, error: MuseMSPRemoteError(
            code: code, message: message, data: error["data"]))
    }

    public static func encode(_ frame: MuseMSPFrame,
                              limit: Int = MuseMSP.defaultFrameLimit) throws -> Data {
        var body: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        switch frame {
        case .request(let id, let method, let params):
            body["id"] = id.json
            body["method"] = .string(method)
            if let params { body["params"] = params }
        case .notification(let method, let params, let emittedAtMs):
            body["method"] = .string(method)
            if let params { body["params"] = params }
            if let emittedAtMs { body["emittedAtMs"] = .number(Double(emittedAtMs)) }
        case .success(let id, let result):
            guard case .object = result else { throw MuseMSPError.invalidFrame }
            body["id"] = id.json
            body["result"] = result
        case .failure(let id, let error):
            body["id"] = id?.json ?? .null
            var errorBody: [String: JSONValue] = [
                "code": .number(Double(error.code)), "message": .string(error.message),
            ]
            if let data = error.data { errorBody["data"] = data }
            body["error"] = .object(errorBody)
        }
        let bytes = try JSONEncoder().encode(JSONValue.object(body))
        guard bytes.count <= max(1, min(limit, MuseMSP.defaultFrameLimit)) else {
            throw MuseMSPError.frameTooLarge
        }
        var framed = bytes
        framed.append(0x0A)
        return framed
    }
}

private final class MuseMSPWriteCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return continuation != nil
    }
}

public struct MuseMSPHandshake: Sendable, Equatable {
    public let raw: JSONValue
    public let schemaVersion: Int
    public let fingerprint: String
    public let serverName: String
    public let serverVersion: String
    public let grantedCapabilities: [String]
    public let experimentalAPI: Bool
    public let sessionDurability: String
    /// Host identity metadata is additive in MSP v1; retain it when present but
    /// do not make older hosts fail handshake parsing.
    public let museHome: String?
    public let platformFamily: String?
    public let platformOS: String?
    public let userAgent: String?

    public var fingerprintDiffersFromDocumentation: Bool {
        fingerprint != MuseMSP.stableFingerprint
    }

    public init(_ raw: JSONValue) throws {
        guard let schemaVersion = raw.path("schema.version")?.intValue,
              let fingerprint = raw.path("schema.fingerprint")?.stringValue,
              let serverName = raw.path("serverInfo.name")?.stringValue,
              let serverVersion = raw.path("serverInfo.version")?.stringValue,
              let capabilities = raw["grantedCapabilities"]?.arrayValue,
              let experimentalAPI = raw["experimentalApi"]?.boolValue else {
            throw MuseMSPError.invalidHandshake
        }
        self.raw = raw
        self.schemaVersion = schemaVersion
        self.fingerprint = fingerprint
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.grantedCapabilities = capabilities.compactMap(\.stringValue)
        self.experimentalAPI = experimentalAPI
        self.sessionDurability = raw["sessionDurability"]?.stringValue ?? "durable"
        self.museHome = raw["museHome"]?.stringValue
        self.platformFamily = raw["platformFamily"]?.stringValue
        self.platformOS = raw["platformOs"]?.stringValue
        self.userAgent = raw["userAgent"]?.stringValue
    }
}

public struct MuseMSPModelCatalog: Sendable, Equatable {
    public struct Model: Sendable, Equatable {
        public let id: String
        public let label: String
        public let providerID: String
        public let isDefault: Bool
        public let isActive: Bool
        public let raw: JSONValue
    }

    public let providerID: String
    public let source: String
    public let profileID: String?
    public let models: [Model]

    public init(_ raw: JSONValue) throws {
        guard let providerID = raw["providerId"]?.stringValue,
              let source = raw["source"]?.stringValue,
              let rows = raw["models"]?.arrayValue else { throw MuseMSPError.invalidResponse }
        self.providerID = providerID
        self.source = source
        self.profileID = raw["profileId"]?.stringValue
        self.models = try rows.map { row in
            guard let id = row["modelId"]?.stringValue,
                  let label = row["displayLabel"]?.stringValue,
                  let providerID = row["providerId"]?.stringValue,
                  let isDefault = row["isDefault"]?.boolValue,
                  let isActive = row["isActive"]?.boolValue else {
                throw MuseMSPError.invalidResponse
            }
            return Model(id: id, label: label, providerID: providerID,
                         isDefault: isDefault, isActive: isActive, raw: row)
        }
    }
}

public struct MuseMSPAccountState: Sendable, Equatable {
    public let state: String
    public let credentialRequired: Bool
    public let label: String?

    public init(_ raw: JSONValue) throws {
        guard let state = raw["state"]?.stringValue,
              let credentialRequired = raw["credentialRequired"]?.boolValue else {
            throw MuseMSPError.invalidResponse
        }
        self.state = state
        self.credentialRequired = credentialRequired
        self.label = raw["label"]?.stringValue
    }
}

/// A command response is only an intake acknowledgement. It does not report execution,
/// cancellation, or a turn's terminal outcome; those are observed in the session view.
public struct MuseMSPCommandAck: Sendable, Equatable {
    public let commandID: String
    public let status: String

    public init(_ raw: JSONValue) throws {
        guard let commandID = raw["commandId"]?.stringValue,
              let status = raw["status"]?.stringValue,
              status == "accepted" || status == "noop" else {
            throw MuseMSPError.invalidResponse
        }
        self.commandID = commandID
        self.status = status
    }
}

public enum MuseMSPIncoming: Sendable, Equatable {
    case notification(method: String, params: JSONValue?, emittedAtMs: Int?)
    case request(id: MuseMSPRequestID, method: String, params: JSONValue?)
}

/// One connection to an already-spawned `muse serve`. No automatic command retry: after
/// a lost acknowledgement, a caller must reconcile using the same durable `commandId`.
public actor MuseMSPConnection {
    private enum Phase: Equatable { case new, initializing, activating, ready, closed }
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let limit: Int
    private let writeQueue = DispatchQueue(label: "aviary.muse.msp.write")
    private let onWriteTimeout: (@Sendable () -> Void)?
    private var phase: Phase = .new
    private var framer: MuseMSPLineFramer
    private var nextRequest = 0
    private var pending: [MuseMSPRequestID: CheckedContinuation<JSONValue, Error>] = [:]
    private var canceledIDs: Set<MuseMSPRequestID> = []
    private var readerStarted = false
    private var failure: MuseMSPError?
    private let incomingContinuation: AsyncStream<MuseMSPIncoming>.Continuation
    public nonisolated let incoming: AsyncStream<MuseMSPIncoming>

    public init(stdin: FileHandle, stdout: FileHandle,
                frameLimit: Int = MuseMSP.defaultFrameLimit,
                onWriteTimeout: (@Sendable () -> Void)? = nil) {
        self.stdin = stdin
        self.stdout = stdout
        self.limit = max(1, min(frameLimit, MuseMSP.defaultFrameLimit))
        self.onWriteTimeout = onWriteTimeout
        self.framer = MuseMSPLineFramer(limit: frameLimit)
        let pair = AsyncStream<MuseMSPIncoming>.makeStream(
            bufferingPolicy: .bufferingOldest(256))
        self.incoming = pair.stream
        self.incomingContinuation = pair.continuation
    }

    public var terminalError: MuseMSPError? { failure }

    public func initialize(clientName: String, version: String,
                           experimentalAPI: Bool = false,
                           requestedCapabilities: [String] = [],
                           userInputDialogs: Bool = false) async throws -> MuseMSPHandshake {
        guard phase == .new else { throw MuseMSPError.alreadyInitialized }
        phase = .initializing
        startReader()
        var capabilities: [String: JSONValue] = [
            "experimentalApi": .bool(experimentalAPI),
            "userInputDialogs": .bool(userInputDialogs),
        ]
        if !requestedCapabilities.isEmpty {
            capabilities["requestedCapabilities"] = .array(requestedCapabilities.map(JSONValue.string))
        }
        let params: JSONValue = .object([
            "clientInfo": .object(["name": .string(clientName), "version": .string(version)]),
            "capabilities": .object(capabilities),
        ])
        do {
            let result = try await sendRequest("initialize", params: params, beforeReady: true)
            let handshake = try MuseMSPHandshake(result)
            phase = .activating
            try await write(.notification(method: "initialized", params: nil, emittedAtMs: nil))
            guard phase == .activating else { throw failure ?? .connectionClosed }
            phase = .ready
            return handshake
        } catch {
            fail(error as? MuseMSPError ?? .transport(String(describing: error)))
            throw error
        }
    }

    public func request(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        guard phase == .ready else { throw failure ?? .notInitialized }
        return try await sendRequest(method, params: params, beforeReady: false)
    }

    public func modelList(sessionID: String? = nil) async throws -> MuseMSPModelCatalog {
        let params: JSONValue = sessionID.map { .object(["sessionId": .string($0)]) } ?? .object([:])
        return try MuseMSPModelCatalog(try await request("model/list", params: params))
    }

    /// `account/read` is experimental. Opt in during `initialize` before calling it.
    public func accountRead() async throws -> MuseMSPAccountState {
        try MuseMSPAccountState(try await request("account/read"))
    }

    public func respond(to id: MuseMSPRequestID, result: JSONValue) async throws {
        guard phase == .ready else { throw failure ?? .notInitialized }
        try await write(.success(id: id, result: result))
    }

    public func respond(to id: MuseMSPRequestID, error: MuseMSPRemoteError) async throws {
        guard phase == .ready else { throw failure ?? .notInitialized }
        try await write(.failure(id: id, error: error))
    }

    public func close() { fail(.connectionClosed) }

    private func startReader() {
        guard !readerStarted else { return }
        readerStarted = true
        let output = stdout
        // FileHandle.read(upToCount:) may wait for its entire requested count on a
        // pipe. MSP frames are usually far smaller; POSIX read returns available
        // bytes immediately after the first byte arrives. Keep the blocking read
        // off the actor's executor and cap each read to one bounded chunk.
        Task.detached { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    read(output.fileDescriptor, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    let bytes = Data(buffer.prefix(count))
                    await self?.receive(bytes)
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                if count == 0 {
                    await self?.endOfOutput()
                } else {
                    let code = errno
                    await self?.fail(.transport("Muse stdout read failed (errno \(code))"))
                }
                return
            }
        }
    }

    private func sendRequest(_ method: String, params: JSONValue?,
                             beforeReady: Bool) async throws -> JSONValue {
        guard beforeReady ? phase == .initializing : phase == .ready else {
            throw failure ?? .notInitialized
        }
        guard pending.count < 256 else { throw MuseMSPError.eventOverflow }
        nextRequest += 1
        let id = MuseMSPRequestID.string("aviary-\(nextRequest)")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: MuseMSPError.canceledLocally)
                    return
                }
                pending[id] = continuation
                Task.detached { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    await self?.timeoutWait(id)
                }
                Task {
                    guard pending[id] != nil, phase != .closed else { return }
                    do {
                        try await write(.request(id: id, method: method, params: params))
                    } catch {
                        pending.removeValue(forKey: id)?.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWait(id) }
        }
    }

    private func cancelWait(_ id: MuseMSPRequestID) {
        endWait(id, error: .canceledLocally)
    }

    private func timeoutWait(_ id: MuseMSPRequestID) {
        endWait(id, error: .requestTimedOut)
    }

    private func endWait(_ id: MuseMSPRequestID, error: MuseMSPError) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if canceledIDs.count >= 1024 {
            fail(.eventOverflow)
        } else {
            canceledIDs.insert(id)
        }
        continuation.resume(throwing: error)
    }

    private func write(_ frame: MuseMSPFrame) async throws {
        guard phase != .closed else { throw failure ?? .connectionClosed }
        let bytes = try MuseMSPCodec.encode(frame, limit: limit)
        let input = stdin
        let writeQueue = writeQueue
        let onWriteTimeout = onWriteTimeout
        do {
            try await withCheckedThrowingContinuation { continuation in
                let completion = MuseMSPWriteCompletion(continuation)
                writeQueue.async {
                    do {
                        try input.write(contentsOf: bytes)
                        completion.finish(.success(()))
                    } catch {
                        completion.finish(.failure(error))
                    }
                }
                Task.detached {
                    try? await Task.sleep(for: .seconds(10))
                    if completion.finish(.failure(MuseMSPError.writeTimedOut)) {
                        onWriteTimeout?()
                    }
                }
            }
        }
        catch {
            let transport = error as? MuseMSPError ?? .transport(String(describing: error))
            fail(transport)
            throw transport
        }
    }

    private func receive(_ bytes: Data) {
        guard phase != .closed else { return }
        do {
            for line in try framer.append(bytes) {
                let frame = try MuseMSPCodec.decode(line)
                switch frame {
                case .success(let id, let result):
                    if let continuation = pending.removeValue(forKey: id) {
                        continuation.resume(returning: result)
                    } else if canceledIDs.remove(id) == nil {
                        throw MuseMSPError.invalidResponse
                    }
                case .failure(let id, let error):
                    // A null-id parse/invalid-request reply cannot be correlated, but its
                    // host-owned code/data is still more useful than a fabricated failure.
                    guard let id else { throw MuseMSPError.remote(error) }
                    if let continuation = pending.removeValue(forKey: id) {
                        continuation.resume(throwing: MuseMSPError.remote(error))
                    } else if canceledIDs.remove(id) == nil {
                        throw MuseMSPError.invalidResponse
                    }
                case .notification(let method, let params, let emittedAtMs):
                    guard phase == .ready || phase == .activating else {
                        throw MuseMSPError.invalidFrame
                    }
                    try enqueue(.notification(method: method, params: params,
                                              emittedAtMs: emittedAtMs))
                case .request(let id, let method, let params):
                    guard phase == .ready || phase == .activating else {
                        throw MuseMSPError.invalidFrame
                    }
                    try enqueue(.request(id: id, method: method, params: params))
                }
            }
        } catch {
            fail(error as? MuseMSPError ?? .transport(String(describing: error)))
        }
    }

    private func enqueue(_ event: MuseMSPIncoming) throws {
        switch incomingContinuation.yield(event) {
        case .enqueued: break
        case .dropped, .terminated: throw MuseMSPError.eventOverflow
        @unknown default: throw MuseMSPError.eventOverflow
        }
    }

    private func endOfOutput() {
        fail(framer.hasPartialFrame ? .invalidFrame : .connectionClosed)
    }

    private func fail(_ error: MuseMSPError) {
        guard phase != .closed else { return }
        phase = .closed
        failure = error
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        incomingContinuation.finish()
    }
}
