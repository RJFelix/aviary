import Foundation

#if os(macOS)
/// Same-user local client. Disconnect has no worker/process side effect. Persistent command
/// IDs are reconciled by reading the original receipt, never by generating a replacement.
public struct MuseWorkerClient: Sendable {
    public enum Error: Swift.Error, LocalizedError, Sendable {
        case invalidManifest, unavailable, unresponsive, cannotResume, deliveryUnknown(String)
        public var errorDescription: String? {
            switch self {
            case .invalidManifest: return "The saved Muse session identity is invalid."
            case .unavailable: return "The Muse worker is not running. Resume the saved chat to continue."
            case .unresponsive: return "The Muse worker is not responding. No duplicate agent or command was started."
            case .cannotResume: return "This chat has no saved native Muse session to resume. Its transcript is still available."
            case .deliveryUnknown: return "Muse command delivery is unconfirmed. The saved attempt will not be sent again automatically."
            }
        }
    }

    public let home: AgentHome
    public let manifest: MuseWorkerManifest
    public var store: MuseWorkerStore { MuseWorkerStore(homeRoot: home.root) }

    public init(home: AgentHome, manifest: MuseWorkerManifest) throws {
        guard manifest.schemaVersion == 1, !manifest.identity.sessionID.isEmpty,
              UUID(uuidString: manifest.instanceID) != nil,
              manifest.cwd.hasPrefix("/"), !manifest.model.isEmpty else { throw Error.invalidManifest }
        self.home = home
        self.manifest = manifest
    }

    public static func load(home: AgentHome, sessionID: String) throws -> MuseWorkerClient {
        let record = try MuseWorkerStore(homeRoot: home.root).loadManifest(sessionID: sessionID)
        let manifest = try MuseWorkerCodec.unpack(MuseWorkerManifest.self, record.manifest)
        guard manifest.identity.sessionID == sessionID, manifest.instanceID == record.instanceID else {
            throw Error.invalidManifest
        }
        return try MuseWorkerClient(home: home, manifest: manifest)
    }

    public static func reserve(home: AgentHome, manifest: MuseWorkerManifest) throws -> MuseWorkerClient {
        let client = try MuseWorkerClient(home: home, manifest: manifest)
        try client.store.createSession(sessionID: manifest.identity.sessionID,
            manifest: MuseWorkerCodec.pack(manifest), instanceID: manifest.instanceID)
        _ = try client.store.submitCommand(sessionID: manifest.identity.sessionID,
            expectedInstanceID: manifest.instanceID, commandID: manifest.startCommandID,
            request: MuseWorkerCodec.pack(MuseWorkerRequest(.start)))
        return client
    }

    /// Cold continuation is explicit and creates a new worker generation. A live owner always
    /// wins: even a stale heartbeat never authorizes a second writer or process.
    public func reserveResume() throws -> MuseWorkerClient {
        let current = try Self.load(home: home, sessionID: manifest.identity.sessionID)
        guard current.manifest.instanceID == manifest.instanceID else { throw MuseWorkerStore.Error.instanceMismatch }
        guard try store.readDraftRecord(sessionID: manifest.identity.sessionID)?.handoff == nil else {
            throw Error.deliveryUnknown("saved-input")
        }
        guard let nativeID = current.manifest.museSessionID, !nativeID.isEmpty else { throw Error.cannotResume }
        var next = current.manifest
        next.instanceID = UUID().uuidString
        next.identity = .allocate(workHostID: next.identity.workHostID,
            sessionID: next.identity.sessionID, workID: next.identity.workID)
        next.initialPrompt = ""
        next.initialInputID = nil
        next.startCommandID = MuseMSPSession.newCommandID()
        next.resuming = true
        next.createdAt = Date()
        try store.reserveResume(sessionID: next.identity.sessionID,
            expectedInstanceID: manifest.instanceID, newInstanceID: next.instanceID,
            manifest: MuseWorkerCodec.pack(next), startCommandID: next.startCommandID,
            startRequest: MuseWorkerCodec.pack(MuseWorkerRequest(.start)))
        let client = try Self(home: home, manifest: next)
        _ = try store.submitCommand(sessionID: next.identity.sessionID,
            expectedInstanceID: next.instanceID, commandID: next.startCommandID,
            request: MuseWorkerCodec.pack(MuseWorkerRequest(.start)))
        return client
    }

    public func launch(sourceExecutableURL: URL? = nil) throws {
        let executable = try LocalAviaryDaemonLauncher(agentHome: home,
            sourceExecutableURL: sourceExecutableURL).resolveExecutable()
        let process = Process()
        process.executableURL = executable.url
        process.arguments = ["--muse-worker", home.root.path, manifest.identity.sessionID, manifest.instanceID]
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.environment = MuseCode.scrubbedEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Intentionally no retained Process/termination handler: quitting a GUI is detach.
    }

    public var isOwned: Bool {
        (try? MuseWorkerStore.isOwned(homeRoot: home.root, sessionID: manifest.identity.sessionID)) == true
    }

    public func snapshot() throws -> MuseWorkerSnapshot? {
        guard let raw = try store.loadSnapshot(sessionID: manifest.identity.sessionID,
            expectedInstanceID: manifest.instanceID) else { return nil }
        let value = try MuseWorkerCodec.unpack(MuseWorkerSnapshot.self, raw)
        guard value.instanceID == manifest.instanceID, value.sessionID == manifest.identity.sessionID else {
            throw Error.invalidManifest
        }
        return value
    }

    public func request(_ request: MuseWorkerRequest, commandID: String,
                        timeout: TimeInterval = 30) async throws -> MuseWorkerReply {
        if let prior = try? store.command(sessionID: manifest.identity.sessionID,
            expectedInstanceID: manifest.instanceID, commandID: commandID),
           let receipt = prior.receipt {
            guard prior.request == (try MuseWorkerCodec.pack(request)) else {
                throw MuseWorkerStore.Error.commandContentMismatch
            }
            return try MuseWorkerCodec.unpack(MuseWorkerReply.self, receipt)
        }
        guard isOwned else { throw Error.unavailable }
        guard let observed = try snapshot(), !observed.isTerminal,
              Date().timeIntervalSince(observed.observedAt) < 10 else { throw Error.unresponsive }
        _ = try store.submitCommand(sessionID: manifest.identity.sessionID,
            expectedInstanceID: manifest.instanceID, commandID: commandID,
            request: MuseWorkerCodec.pack(request))
        let deadline = Date().addingTimeInterval(min(60, max(0.1, timeout)))
        repeat {
            let record = try store.command(sessionID: manifest.identity.sessionID,
                expectedInstanceID: manifest.instanceID, commandID: commandID)
            if let receipt = record.receipt { return try MuseWorkerCodec.unpack(MuseWorkerReply.self, receipt) }
            guard isOwned else { throw Error.deliveryUnknown(commandID) }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        throw Error.deliveryUnknown(commandID)
    }
}
#endif
