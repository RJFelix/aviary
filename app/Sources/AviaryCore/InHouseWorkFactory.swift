import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The host-private launch record that has already passed Work creation and attachment
/// validation. A concrete Work Host may conform its reconstructable launch manifest to this
/// protocol without making that manifest a Core transport type.
public protocol InHouseWorkLaunchManifest: Sendable {
    var workRunBinding: WorkRunBinding { get }
}

/// Composes one in-house execution owned by a Work Host.
///
/// The Work Host creates the Work/Session/attachment first and passes the resulting
/// ``WorkRunBinding`` here. This factory never allocates or discovers identities. It opens the
/// one execution-generation journal exactly once, then gives that already-open authority to the
/// Hosted actor, which owns the Agent, AgentRunner, and RuntimeHost for the lifetime of the Run.
/// Provider credentials and runtime configuration are deliberately resolved by the caller and
/// are carried only in memory; this value is not a transport DTO.
/// Peer and self callbacks are explicit dependencies. Scheduling is intentionally not constructed
/// here: a Work Host/service owns that policy and submits commands through Hosted Work when it is
/// needed, so losing a scheduler or observer cannot tear down this execution.
public enum InHouseWorkFactory {
    public struct Configuration: Sendable {
        /// Internal failure injection used to exercise the crash window around fresh projection
        /// staging. Production callers cannot select a failure stage through the public init.
        enum FailureStage: String, Sendable, Hashable {
            case afterFreshProjectionBeforeCanonicalAdmission
            case afterCanonicalAdmissionBeforeFreshProjectionPublication
            case afterFreshProjectionPublicationBeforeBridgeInstallation
        }

        public let home: AgentHome
        public let cwd: String
        public let model: ModelSpec
        public let provider: any ChatProvider
        public let runtimeHost: RuntimeHost
        public let workRunBinding: WorkRunBinding
        public let serviceActorID: String
        public let actorKind: String
        public let systemPrompt: String
        public let systemPromptAssembly: SystemPromptAssembly?
        public let reasoningEffort: String?
        public let maxDepth: Int
        public let maxIterations: Int
        public let childMaxIterations: Int?
        public let memory: MemoryStore?
        public let recordPayloads: Bool
        public let goal: Goal?
        public let hookPaths: [String]
        public let projectionMode: WorkLaunchProjectionMode
        public let modelContextMode: WorkLaunchContextMode
        public let peerDelegate: Agent.PeerDelegate?
        public let selfDelegate: Agent.SelfDelegate?
        /// Host-private pilot opt-in; the public initializer leaves this unset.
        internal var agentChildPilot: WorkAgentChildPilot?
        public let startAdmissionGate: (@Sendable () async -> Void)?
        public let adoptionEvidenceSink:
            (@Sendable (HostedInHouseWorkAdoptionEvidence) async throws -> Void)?

        /// Test-only; the public configuration initializer leaves this unset.
        var failureStage: FailureStage?

        public init(
            home: AgentHome,
            cwd: String,
            model: ModelSpec,
            provider: any ChatProvider,
            runtimeHost: RuntimeHost,
            workRunBinding: WorkRunBinding,
            serviceActorID: String,
            actorKind: String = "work-host",
            systemPrompt: String,
            systemPromptAssembly: SystemPromptAssembly? = nil,
            reasoningEffort: String? = nil,
            maxDepth: Int = 3,
            maxIterations: Int = 40,
            childMaxIterations: Int? = nil,
            memory: MemoryStore? = nil,
            recordPayloads: Bool = false,
            goal: Goal? = nil,
            hookPaths: [String] = [],
            projectionMode: WorkLaunchProjectionMode = .fresh,
            modelContextMode: WorkLaunchContextMode = .launchFresh,
            peerDelegate: Agent.PeerDelegate? = nil,
            selfDelegate: Agent.SelfDelegate? = nil,
            startAdmissionGate: (@Sendable () async -> Void)? = nil,
            adoptionEvidenceSink:
                (@Sendable (HostedInHouseWorkAdoptionEvidence) async throws -> Void)? = nil
        ) {
            self.home = home
            self.cwd = cwd
            self.model = model
            self.provider = provider
            self.runtimeHost = runtimeHost
            self.workRunBinding = workRunBinding
            self.serviceActorID = serviceActorID
            self.actorKind = actorKind
            self.systemPrompt = systemPrompt
            self.systemPromptAssembly = systemPromptAssembly
            self.reasoningEffort = reasoningEffort
            self.maxDepth = maxDepth
            self.maxIterations = maxIterations
            self.childMaxIterations = childMaxIterations
            self.memory = memory
            self.recordPayloads = recordPayloads
            self.goal = goal
            self.hookPaths = hookPaths
            self.projectionMode = projectionMode
            self.modelContextMode = modelContextMode
            self.peerDelegate = peerDelegate
            self.selfDelegate = selfDelegate
            self.agentChildPilot = nil
            self.startAdmissionGate = startAdmissionGate
            self.adoptionEvidenceSink = adoptionEvidenceSink
            self.failureStage = nil
        }

        fileprivate var hostedConfiguration: HostedInHouseWorkConfiguration {
            var configuration = HostedInHouseWorkConfiguration(
                home: home,
                cwd: cwd,
                model: model,
                provider: provider,
                runtimeHost: runtimeHost,
                workRunBinding: workRunBinding,
                serviceActorID: serviceActorID,
                actorKind: actorKind,
                systemPrompt: systemPrompt,
                systemPromptAssembly: systemPromptAssembly,
                reasoningEffort: reasoningEffort,
                maxDepth: maxDepth,
                maxIterations: maxIterations,
                childMaxIterations: childMaxIterations,
                memory: memory,
                recordPayloads: recordPayloads,
                goal: goal,
                hookPaths: hookPaths,
                projectionMode: projectionMode,
                modelContextMode: modelContextMode,
                peerDelegate: peerDelegate,
                selfDelegate: selfDelegate,
                startAdmissionGate: startAdmissionGate,
                adoptionEvidenceSink: adoptionEvidenceSink)
            configuration.agentChildPilot = agentChildPilot
            return configuration
        }
    }

    /// Open one already-resolved Hosted actor. External Work Hosts enter through the manifest
    /// overload below so a durable launch record, rather than a service descriptor alone, names
    /// the exact Work/Session/Run generation.
    static func open(configuration: Configuration) async throws -> HostedInHouseWork {
        let hostedConfiguration = configuration.hostedConfiguration
        try validate(hostedConfiguration)

        if let pilot = hostedConfiguration.agentChildPilot {
            try await pilot.coordinator.register(
                work: hostedConfiguration.workRunBinding.workBinding.work,
                home: hostedConfiguration.home,
                actor: TimelineActor(
                    actorID: hostedConfiguration.serviceActorID,
                    kind: hostedConfiguration.actorKind))
        }

        let identity = identity(for: hostedConfiguration.workRunBinding)
        let projectionURL = hostedConfiguration.home.sessionFile(id: identity.sessionID)
        if hostedConfiguration.projectionMode == .reopenHistorical {
            guard FileManager.default.fileExists(atPath: projectionURL.path) else {
                throw HostedInHouseWorkError.invalidConfiguration(
                    "historical projection reopen requires an existing Session projection")
            }
            let existingBoundary = try Self.existingRunBoundary(
                at: projectionURL, identity: identity, model: hostedConfiguration.model)
            switch existingBoundary {
            case .historical, .partial, .runStartOnly, .complete:
                break
            case .foreign, .headerOnly, .none:
                throw HostedInHouseWorkError.invalidConfiguration(
                    "existing Session projection is not a reopenable historical projection")
            }

            // Acquire the canonical Run marker before touching the final flat projection. The
            // placeholder is disposable and exists only to satisfy the bridge identity check;
            // this ordering prevents two replacement attempts from racing on SessionWriter's
            // unlocked append path.
            let placeholder = try makeFreshProjectionStage(
                configuration: hostedConfiguration, identity: identity)
            let canonicalBridge: NativeSessionCommandJournal
            do {
                if let pilot = hostedConfiguration.agentChildPilot {
                    canonicalBridge = try await pilot.coordinator.withRunOpen(
                        work: hostedConfiguration.workRunBinding.workBinding.work) {
                            let bridge = try await NativeSessionCommandJournal.openForRun(
                                home: hostedConfiguration.home,
                                binding: hostedConfiguration.workRunBinding,
                                legacyProjection: placeholder.writer,
                                actorID: hostedConfiguration.serviceActorID,
                                actorKind: hostedConfiguration.actorKind,
                                modelID: hostedConfiguration.model.qualifiedID,
                                modelContextMode: hostedConfiguration.modelContextMode)
                            return (bridge.nativeJournal, bridge)
                        }
                } else {
                    canonicalBridge = try await NativeSessionCommandJournal.openForRun(
                        home: hostedConfiguration.home,
                        binding: hostedConfiguration.workRunBinding,
                        legacyProjection: placeholder.writer,
                        actorID: hostedConfiguration.serviceActorID,
                        actorKind: hostedConfiguration.actorKind,
                        modelID: hostedConfiguration.model.qualifiedID,
                        modelContextMode: hostedConfiguration.modelContextMode)
                }
            } catch {
                try? await placeholder.writer.closeChecked()
                removeStage(placeholder)
                throw error
            }

            do {
                // The canonical writer locks are now held by NativeSessionCommandJournal. Only
                // after that point may the historical compatibility projection be repaired and
                // extended with the new Run boundary.
                let projection: SessionWriter
                switch existingBoundary {
                case .complete:
                    projection = try SessionWriter(
                        home: hostedConfiguration.home,
                        reopeningWithoutRunBoundary: identity.sessionID,
                        identity: identity)
                case .runStartOnly:
                    projection = try SessionWriter(
                        home: hostedConfiguration.home,
                        reopeningWithoutRunBoundary: identity.sessionID,
                        identity: identity)
                    try await projection.appendModelChange(hostedConfiguration.model)
                case .historical, .partial:
                    projection = try SessionWriter(
                        home: hostedConfiguration.home,
                        resuming: identity.sessionID,
                        cwd: hostedConfiguration.cwd,
                        model: hostedConfiguration.model,
                        identity: identity)
                case .foreign, .headerOnly, .none:
                    throw HostedInHouseWorkError.invalidConfiguration(
                        "existing Session projection is not a reopenable historical projection")
                }
                try await placeholder.writer.closeChecked()
                removeStage(placeholder)
                let bridge = try NativeSessionCommandJournal(
                    identity: identity,
                    nativeJournal: canonicalBridge.nativeJournal,
                    legacyProjection: projection,
                    resumeSeed: canonicalBridge.resumeSeed)
                let controller = SessionCommandController(
                    identity: identity,
                    capabilities: Agent.inHouseCommandCapabilities,
                    journal: bridge)
                return HostedInHouseWork(
                    configuration: hostedConfiguration, bridge: bridge, controller: controller)
            } catch {
                try? await placeholder.writer.closeChecked()
                removeStage(placeholder)
                await failOpenedExecution(
                    canonicalBridge,
                    detail: "historical Session projection could not be reopened: "
                        + bounded(error.localizedDescription))
                throw HostedInHouseWorkError.invalidConfiguration(
                    "could not reopen historical Session projection: "
                        + bounded(error.localizedDescription))
            }
        }

        if hostedConfiguration.modelContextMode == .exactColdResume {
            throw HostedInHouseWorkError.invalidConfiguration(
                "exact cold resume requires a historical Session projection reopen")
        }

        // A genuinely fresh first Run has no flat projection yet and must fall through to the
        // disposable staging path below.  Only an existing projection enters this exact-retry
        // branch; treating `.none` as an error here would make the publication path unreachable.
        if hostedConfiguration.projectionMode == .fresh,
           FileManager.default.fileExists(atPath: projectionURL.path) {
            let writer: SessionWriter
            do {
                switch try Self.existingRunBoundary(
                    at: projectionURL, identity: identity, model: hostedConfiguration.model) {
                case .complete:
                    // A prior process may have written the flat run boundary before dying at
                    // the native marker/command boundary. SessionWriter(resuming:) appends a
                    // second boundary, so use the idempotent reopen only after this exact tail
                    // shape has been proven. Native RunJournalBundle still rechecks the paired
                    // canonical marker under both writer locks.
                    writer = try SessionWriter(
                        home: hostedConfiguration.home,
                        reopeningWithoutRunBoundary: identity.sessionID,
                        identity: identity)
                case .runStartOnly:
                    writer = try SessionWriter(
                        home: hostedConfiguration.home,
                        reopeningWithoutRunBoundary: identity.sessionID,
                        identity: identity)
                    try await writer.appendModelChange(hostedConfiguration.model)
                case .headerOnly:
                    writer = try SessionWriter(
                        home: hostedConfiguration.home,
                        reopeningWithoutRunBoundary: identity.sessionID,
                        identity: identity)
                case .historical:
                    writer = try SessionWriter(
                        home: hostedConfiguration.home,
                        resuming: identity.sessionID,
                        cwd: hostedConfiguration.cwd,
                        model: hostedConfiguration.model,
                        identity: identity)
                case .partial:
                    throw HostedInHouseWorkError.invalidConfiguration(
                        "a fresh Session projection has an interrupted replacement boundary")
                case .foreign, .none:
                    throw HostedInHouseWorkError.invalidConfiguration(
                        "existing Session projection is malformed or unavailable")
                }
            } catch {
                throw HostedInHouseWorkError.invalidConfiguration(
                    "could not open Session projection: \(bounded(error.localizedDescription))")
            }
            do {
                // This is the sole execution-generation opener. `createIdleWork` has already
                // closed its genesis writers; openForRun reopens that exact pair and appends this
                // Run marker.
                let bridge: NativeSessionCommandJournal
                if let pilot = hostedConfiguration.agentChildPilot {
                    bridge = try await pilot.coordinator.withRunOpen(
                        work: hostedConfiguration.workRunBinding.workBinding.work) {
                            let bridge = try await NativeSessionCommandJournal.openForRun(
                                home: hostedConfiguration.home,
                                binding: hostedConfiguration.workRunBinding,
                                legacyProjection: writer,
                                actorID: hostedConfiguration.serviceActorID,
                                actorKind: hostedConfiguration.actorKind,
                                modelID: hostedConfiguration.model.qualifiedID,
                                modelContextMode: hostedConfiguration.modelContextMode)
                            return (bridge.nativeJournal, bridge)
                        }
                } else {
                    bridge = try await NativeSessionCommandJournal.openForRun(
                        home: hostedConfiguration.home,
                        binding: hostedConfiguration.workRunBinding,
                        legacyProjection: writer,
                        actorID: hostedConfiguration.serviceActorID,
                        actorKind: hostedConfiguration.actorKind,
                        modelID: hostedConfiguration.model.qualifiedID,
                        modelContextMode: hostedConfiguration.modelContextMode)
                }
                let controller = SessionCommandController(
                    identity: identity,
                    capabilities: Agent.inHouseCommandCapabilities,
                    journal: bridge)
                return HostedInHouseWork(
                    configuration: hostedConfiguration,
                    bridge: bridge,
                    controller: controller)
            } catch {
                await writer.close()
                throw error
            }
        }

        // The fresh legacy projection is staged under the final sessions directory. A process
        // death before canonical admission therefore cannot leave a final flat Session that
        // blocks a retry. The canonical Run is admitted while this staging writer is alive; only
        // after that succeeds do we publish the real projection and give it to Hosted Work.
        let stage = try makeFreshProjectionStage(configuration: hostedConfiguration, identity: identity)
        if configuration.failureStage == .afterFreshProjectionBeforeCanonicalAdmission {
            try? await stage.writer.closeChecked()
            removeStage(stage)
            throw HostedInHouseWorkError.invalidConfiguration(
                "injected failure after fresh Session projection staging")
        }

        do {
            let stagedBridge: NativeSessionCommandJournal
            if let pilot = hostedConfiguration.agentChildPilot {
                stagedBridge = try await pilot.coordinator.withRunOpen(
                    work: hostedConfiguration.workRunBinding.workBinding.work) {
                        let bridge = try await NativeSessionCommandJournal.openForRun(
                            home: hostedConfiguration.home,
                            binding: hostedConfiguration.workRunBinding,
                            legacyProjection: stage.writer,
                            actorID: hostedConfiguration.serviceActorID,
                            actorKind: hostedConfiguration.actorKind,
                            modelID: hostedConfiguration.model.qualifiedID,
                            modelContextMode: hostedConfiguration.modelContextMode)
                        return (bridge.nativeJournal, bridge)
                    }
            } else {
                stagedBridge = try await NativeSessionCommandJournal.openForRun(
                    home: hostedConfiguration.home,
                    binding: hostedConfiguration.workRunBinding,
                    legacyProjection: stage.writer,
                    actorID: hostedConfiguration.serviceActorID,
                    actorKind: hostedConfiguration.actorKind,
                    modelID: hostedConfiguration.model.qualifiedID,
                    modelContextMode: hostedConfiguration.modelContextMode)
            }
            do {
                try await stage.writer.closeChecked()
            } catch {
                await failOpenedExecution(
                    stagedBridge,
                    detail: "staged Session projection could not be synchronized")
                throw error
            }

            let projection: SessionWriter
            do {
                // A first-Run retry may already have published the exact flat projection before
                // dying at the canonical marker/command boundary. Reopen that proven boundary
                // without appending a second session header/run_start/model_change. An existing
                // but non-Aviary or mismatched projection is not repairable evidence: fail closed
                // rather than appending this Run to foreign transcript bytes.
                let projectionURL = hostedConfiguration.home.sessionFile(id: identity.sessionID)
                if FileManager.default.fileExists(atPath: projectionURL.path) {
                    switch try Self.existingRunBoundary(
                        at: projectionURL, identity: identity, model: hostedConfiguration.model) {
                    case .complete:
                        projection = try SessionWriter(
                            home: hostedConfiguration.home,
                            reopeningWithoutRunBoundary: identity.sessionID,
                            identity: identity)
                    case .runStartOnly:
                        projection = try SessionWriter(
                            home: hostedConfiguration.home,
                            reopeningWithoutRunBoundary: identity.sessionID,
                            identity: identity)
                        try await projection.appendModelChange(hostedConfiguration.model)
                    case .headerOnly:
                        projection = try SessionWriter(
                            home: hostedConfiguration.home,
                            reopeningWithoutRunBoundary: identity.sessionID,
                            identity: identity)
                    case .foreign, .historical, .partial:
                        throw HostedInHouseWorkError.invalidConfiguration(
                            "existing Session projection is not this exact Run boundary")
                    case .none:
                        throw HostedInHouseWorkError.invalidConfiguration(
                            "existing Session projection is malformed or unavailable")
                    }
                } else {
                    if configuration.failureStage ==
                            .afterCanonicalAdmissionBeforeFreshProjectionPublication {
                        await failOpenedExecution(
                            stagedBridge,
                            detail: "injected failure after canonical Run admission")
                        throw HostedInHouseWorkError.invalidConfiguration(
                            "injected failure after canonical admission")
                    }
                    try publishFreshProjection(stage, to: projectionURL)
                    projection = try SessionWriter(
                        home: hostedConfiguration.home,
                        reopeningWithoutRunBoundary: identity.sessionID,
                        identity: identity)
                }
            } catch {
                await failOpenedExecution(
                    stagedBridge,
                    detail: "fresh Session projection could not be published: "
                        + bounded(error.localizedDescription))
                throw HostedInHouseWorkError.invalidConfiguration(
                    "could not publish Session projection: \(bounded(error.localizedDescription))")
            }
            if configuration.failureStage ==
                    .afterFreshProjectionPublicationBeforeBridgeInstallation {
                await failOpenedExecution(
                    stagedBridge,
                    detail: "injected failure after Session projection publication")
                await projection.close()
                removeStage(stage)
                throw HostedInHouseWorkError.invalidConfiguration(
                    "injected failure after Session projection publication")
            }
            do {
                // Rebind the already-admitted native authority to the published projection. No
                // second RunJournalBundle or Run marker is opened here.
                let bridge = try NativeSessionCommandJournal(
                    identity: identity,
                    nativeJournal: stagedBridge.nativeJournal,
                    legacyProjection: projection,
                    resumeSeed: stagedBridge.resumeSeed)
                let controller = SessionCommandController(
                    identity: identity,
                    capabilities: Agent.inHouseCommandCapabilities,
                    journal: bridge)
                return HostedInHouseWork(
                    configuration: hostedConfiguration,
                    bridge: bridge,
                    controller: controller)
            } catch {
                await projection.close()
                await failOpenedExecution(
                    stagedBridge,
                    detail: "fresh Hosted bridge could not be installed")
                throw error
            }
        } catch {
            try? await stage.writer.closeChecked()
            removeStage(stage)
            throw error
        }
    }

    /// Resolve a host-private launch manifest into the in-memory execution configuration, then
    /// open exactly the binding named by that manifest. The resolver is deliberately injected:
    /// Core must not know where provider credentials, model routing, hooks, memory, or runtime
    /// adoption inputs are stored. Returning a different Work/Session/Run is rejected before any
    /// writer is opened, so a manifest cannot accidentally create a second execution generation.
    public static func open<Manifest: InHouseWorkLaunchManifest>(
        launchManifest: Manifest,
        resolve: @Sendable (Manifest) async throws -> Configuration
    ) async throws -> HostedInHouseWork {
        let configuration = try await resolve(launchManifest)
        guard configuration.workRunBinding == launchManifest.workRunBinding else {
            throw HostedInHouseWorkError.invalidConfiguration(
                "launch manifest resolver returned a different Work/Session/Run binding")
        }
        return try await open(configuration: configuration)
    }

    private static func identity(for binding: WorkRunBinding) -> SessionWorkIdentity {
        SessionWorkIdentity(
            sessionID: binding.workBinding.session.sessionID,
            work: binding.workBinding.work,
            runID: binding.run.runID)
    }

    private struct FreshProjectionStage {
        let root: URL
        let writer: SessionWriter
    }

    private static func makeFreshProjectionStage(
        configuration: HostedInHouseWorkConfiguration,
        identity: SessionWorkIdentity
    ) throws -> FreshProjectionStage {
        // Keep the staging directory below the final `sessions` directory. This guarantees the
        // eventual no-replace link is on the same filesystem as the published projection while
        // keeping the final pathname absent until canonical `run.started` admission succeeds.
        try FileManager.default.createDirectory(
            at: configuration.home.sessionsDir, withIntermediateDirectories: true)
        let root = configuration.home.sessionsDir.appending(
            path: ".aviary-inhouse-projection-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory)
        do {
            let writer = try SessionWriter(
                home: AgentHome(root: root),
                cwd: configuration.cwd,
                model: configuration.model,
                identity: identity)
            return FreshProjectionStage(root: root, writer: writer)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw HostedInHouseWorkError.invalidConfiguration(
                "could not stage Session projection: \(bounded(error.localizedDescription))")
        }
    }

    private static func removeStage(_ stage: FreshProjectionStage) {
        try? FileManager.default.removeItem(at: stage.root)
    }

    /// Publish a complete staged transcript without replacing a concurrently-created final
    /// projection. The writer synchronizes every JSONL record and is closed before this method is
    /// called; the directory syncs make both the new name and the cleanup durable. A hard link is
    /// used instead of `moveItem`/rename so an existing final file can never be clobbered.
    private static func publishFreshProjection(
        _ stage: FreshProjectionStage, to destination: URL
    ) throws {
        let source = stage.writer.fileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw HostedInHouseWorkError.invalidConfiguration(
                "staged Session projection disappeared before publication")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

#if canImport(Darwin)
        let linkResult = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                link(sourcePath, destinationPath)
            }
        }
        guard linkResult == 0 else {
            let code = errno
            if code == EEXIST {
                throw HostedInHouseWorkError.invalidConfiguration(
                    "another process published the Session projection first")
            }
            throw HostedInHouseWorkError.invalidConfiguration(
                "could not publish Session projection: \(String(cString: strerror(code)))")
        }
        do {
            try synchronizeDirectory(destination.deletingLastPathComponent())
            try FileManager.default.removeItem(at: source)
            try synchronizeDirectory(source.deletingLastPathComponent())
        } catch {
            // The destination link is deliberately left in place. It is a complete transcript
            // and is safer to recover on the next attempt than to remove after an indeterminate
            // directory sync.
            throw HostedInHouseWorkError.invalidConfiguration(
                "Session projection publication was not fully synchronized: "
                    + bounded(error.localizedDescription))
        }
#else
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw HostedInHouseWorkError.invalidConfiguration(
                "could not publish Session projection: \(bounded(error.localizedDescription))")
        }
#endif
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
#if canImport(Darwin)
        let descriptor = directory.path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_DIRECTORY)
        }
        guard descriptor >= 0 else {
            throw HostedInHouseWorkError.invalidConfiguration(
                "could not open Session projection directory for synchronization")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw HostedInHouseWorkError.invalidConfiguration(
                "could not synchronize Session projection directory")
        }
#else
        _ = directory
#endif
    }

    private enum ExistingRunBoundary {
        case none
        case headerOnly
        case runStartOnly
        case complete
        case historical
        case foreign
        case partial(runMatches: Bool)
    }

    /// Prove that the flat projection already ends with this exact Run's Aviary-owned boundary.
    /// The native Work journal remains authoritative; this helper only prevents duplicate
    /// `run_start`/`model_change` lines during a retry in the pre-acceptance crash window.
    private static func existingRunBoundary(
        at url: URL,
        identity: SessionWorkIdentity,
        model: ModelSpec
    ) throws -> ExistingRunBoundary {
        let maximumProjectionBytes = 64 * 1024 * 1024
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .none }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumProjectionBytes + 1),
              data.count <= maximumProjectionBytes,
              !data.isEmpty else { return .none }
        let terminated = data.last == UInt8(ascii: "\n")
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // SessionWriter deliberately keeps an interrupted JSONL fragment visible and terminates
        // it with a newline on the next open. Recognize only Aviary-owned run boundary fragments
        // here; arbitrary unterminated data remains foreign/malformed and fails closed.
        let hasPartialTail: Bool
        let completeLines: [Data.SubSequence]
        if terminated {
            hasPartialTail = false
            completeLines = Array(lines)
        } else {
            guard lines.count >= 2, let tail = lines.last else { return .none }
            let prefixEnd = lines.index(before: lines.endIndex)
            completeLines = Array(lines[..<prefixEnd])
            guard Self.isAviaryBoundaryPrefix(Data(tail)) else { return .none }
            hasPartialTail = true
        }
        // SessionWriter's quarantine is deliberately append-only: the malformed fragment is
        // kept as an unreadable, now newline-terminated line. Ignore only those proven Aviary
        // boundary prefixes while validating the remaining complete projection. Foreign or
        // arbitrary malformed lines still fail closed below.
        var validLines: [Data] = []
        validLines.reserveCapacity(completeLines.count)
        for line in completeLines {
            let bytes = Data(line)
            guard let value = JSONValue.parse(bytes) else {
                guard Self.isAviaryBoundaryPrefix(bytes) else { return .none }
                continue
            }
            guard value["type"]?.stringValue?.isEmpty == false else { return .none }
            validLines.append(bytes)
        }
        guard let firstLine = validLines.first,
              let header = JSONValue.parse(firstLine),
              header["type"]?.stringValue == "session",
              header["version"]?.intValue == 1,
              header["writer"]?.stringValue == "aviary",
              header["id"]?.stringValue?.isEmpty == false,
              header["workHostId"]?.stringValue?.isEmpty == false,
              header["workId"]?.stringValue?.isEmpty == false else { return .none }

        // The stable projection identity is the Session/Work/WorkHost tuple in the historical
        // header. The header's old run id and model are intentionally not compared with the
        // requested replacement Run: a Run2/Run3 retry must be able to reopen Run1's projection.
        guard header["id"]?.stringValue == identity.sessionID,
              header["workHostId"]?.stringValue == identity.workHostID,
              header["workId"]?.stringValue == identity.workID else { return .foreign }

        var parsedLines: [JSONValue] = []
        parsedLines.reserveCapacity(validLines.count)
        for (index, line) in validLines.enumerated() {
            guard let value = JSONValue.parse(line),
                  value["type"]?.stringValue?.isEmpty == false else { return .none }
            if index > 0 {
                guard value["id"]?.stringValue?.isEmpty == false,
                  value["timestamp"]?.stringValue?.isEmpty == false else { return .none }
            }
            parsedLines.append(value)
        }
        guard parsedLines.count == validLines.count else { return .none }
        if hasPartialTail {
            return .partial(runMatches: header["runId"]?.stringValue == identity.runID)
        }
        if parsedLines.count == 1 {
            return header["runId"]?.stringValue == identity.runID ? .headerOnly : .historical
        }

        guard let last = parsedLines.last else { return .none }
        if parsedLines.count == 2,
           last["type"]?.stringValue == "model_change",
           (last["parentId"]?.stringValue == nil
                || last["parentId"]?.stringValue == header["id"]?.stringValue),
           last["provider"]?.stringValue?.isEmpty == false,
           last["modelId"]?.stringValue?.isEmpty == false,
           last["id"]?.stringValue?.isEmpty == false,
           last["timestamp"]?.stringValue?.isEmpty == false {
            // A two-line header/model prefix is the complete initial boundary only for the same
            // Run. A replacement Run must retain this historical prefix and append its own
            // boundary through SessionWriter(resuming:).
            guard header["runId"]?.stringValue == identity.runID else { return .historical }
            guard last["provider"]?.stringValue == model.providerID,
                  last["modelId"]?.stringValue == model.id else { return .none }
            return .headerOnly
        }
        let runStart: JSONValue
        if last["type"]?.stringValue == "run_start" {
            runStart = last
        } else if last["type"]?.stringValue == "model_change" {
            guard last["type"]?.stringValue == "model_change",
                  validLines.count >= 2,
                  let candidate = validLines.dropLast().last,
                  let parsed = JSONValue.parse(candidate) else { return .none }
            runStart = parsed
            guard last["parentId"]?.stringValue == runStart["id"]?.stringValue,
                  last["provider"]?.stringValue == model.providerID,
                  last["modelId"]?.stringValue == model.id,
                  last["id"]?.stringValue?.isEmpty == false,
                  last["timestamp"]?.stringValue?.isEmpty == false else { return .none }
            guard runStart["type"]?.stringValue == "run_start",
                  runStart["runId"]?.stringValue == identity.runID,
                  runStart["workHostId"]?.stringValue == identity.workHostID,
                  runStart["workId"]?.stringValue == identity.workID else {
                return .historical
            }
            return .complete
        } else {
            // A valid historical message/tool/outcome after an older Run is not a current
            // boundary. It remains safe input for a replacement SessionWriter.
            return .historical
        }
        guard runStart["runId"]?.stringValue?.isEmpty == false,
              runStart["workHostId"]?.stringValue?.isEmpty == false,
              runStart["workId"]?.stringValue?.isEmpty == false,
              runStart["id"]?.stringValue?.isEmpty == false,
              runStart["timestamp"]?.stringValue?.isEmpty == false else { return .none }
        guard runStart["workHostId"]?.stringValue == identity.workHostID,
              runStart["workId"]?.stringValue == identity.workID else {
            return .historical
        }
        return runStart["runId"]?.stringValue == identity.runID
            ? .runStartOnly : .historical
    }

    /// SessionWriter encodes a boundary from a Dictionary, so JSON key order is intentionally
    /// not part of the on-disk contract. A partial write may therefore begin with `provider`,
    /// `id`, or any other boundary field rather than the `type` field. Validate the partial as a
    /// prefix of a flat Aviary boundary object instead of relying on one encoder ordering. This
    /// remains fail-closed for foreign data: every complete key must be one of the fields that
    /// SessionWriter can emit, values must be JSON strings (or an unfinished string), and at
    /// least one boundary key must have been observed.
    private static func isAviaryBoundaryPrefix(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard bytes.first == UInt8(ascii: "{") else { return false }
        guard String(data: data, encoding: .utf8) != nil else { return false }
        let allowedKeys: Set<String> = [
            "runId", "workHostId", "workId", "provider", "modelId", "id", "timestamp",
            "parentId", "type",
        ]
        var keys = Set<String>()
        var index = 1

        func skipWhitespace() {
            while index < bytes.count,
                  bytes[index] == UInt8(ascii: " ")
                    || bytes[index] == UInt8(ascii: "\t")
                    || bytes[index] == UInt8(ascii: "\r") {
                index += 1
            }
        }

        while true {
            skipWhitespace()
            guard index < bytes.count else { break }
            guard bytes[index] == UInt8(ascii: "\"") else { return false }
            index += 1
            let keyStart = index
            var keyEnd: Int?
            while index < bytes.count {
                if bytes[index] == UInt8(ascii: "\\") {
                    // Generated keys contain no escapes. Treat an escaped key as foreign rather
                    // than trying to decode an ambiguous partial token.
                    return false
                }
                if bytes[index] == UInt8(ascii: "\"") {
                    keyEnd = index
                    index += 1
                    break
                }
                index += 1
            }
            guard let keyEnd else {
                // A crash in the middle of the key cannot prove which boundary was being written.
                break
            }
            let key = String(decoding: bytes[keyStart..<keyEnd], as: UTF8.self)
            guard allowedKeys.contains(key) else { return false }
            keys.insert(key)
            skipWhitespace()
            guard index < bytes.count else { break }
            guard bytes[index] == UInt8(ascii: ":") else { return false }
            index += 1
            skipWhitespace()
            guard index < bytes.count else { break }
            // Every SessionWriter boundary field is a string. A partial string is still a valid
            // append prefix; any other value shape is foreign/malformed state.
            guard bytes[index] == UInt8(ascii: "\"") else { return false }
            index += 1
            var closedValue = false
            while index < bytes.count {
                if bytes[index] == UInt8(ascii: "\\") {
                    guard index + 1 < bytes.count else { break }
                    index += 2
                    continue
                }
                if bytes[index] == UInt8(ascii: "\"") {
                    index += 1
                    closedValue = true
                    break
                }
                index += 1
            }
            guard closedValue else { break }
            skipWhitespace()
            guard index < bytes.count else { break }
            guard bytes[index] == UInt8(ascii: ",") else {
                // A complete `}` without the writer's final newline is not an interrupted write.
                return false
            }
            index += 1
        }

        return !keys.isEmpty
    }

    private static func failOpenedExecution(
        _ bridge: NativeSessionCommandJournal,
        detail: String
    ) async {
        // A projection/runtime setup failure before the first command must leave the exact
        // trailing Run marker available for a same-command retry.  The native bundle proves
        // this under its writer locks; once any canonical activity exists, preserve the old
        // fail-closed terminalization behavior.
        if !(await bridge.nativeJournal.isUntouchedStartedRun) {
            _ = try? await bridge.nativeJournal.finishRun(
                outcome: .failed, detail: bounded(detail))
        }
        try? await bridge.nativeJournal.closeChecked()
    }

    private static func validate(_ configuration: HostedInHouseWorkConfiguration) throws {
        let binding = configuration.workRunBinding
        let identity = identity(for: binding)
        let identifiers = [
            identity.sessionID,
            identity.work.workHostID,
            identity.work.workID,
            identity.runID,
            configuration.serviceActorID,
        ]
        guard identifiers.allSatisfy({
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && $0.utf8.count <= 256
        }) else {
            throw HostedInHouseWorkError.invalidConfiguration(
                "Work, Session, Run, and service actor identities must be nonempty and at most "
                    + "256 UTF-8 bytes")
        }

        let persistedHost = try configuration.home.requirePersistedWorkHost()
        guard binding.workBinding.workHost == persistedHost,
              binding.workBinding.work.workHostID == persistedHost.workHostID else {
            throw HostedInHouseWorkError.invalidConfiguration(
                "execution Work binding does not belong to this AgentHome's persisted authority")
        }
        guard binding.workBinding.sessionJournal.authority ==
                TimelineAuthorityRef(persistedHost.workHostID) else {
            throw HostedInHouseWorkError.invalidConfiguration(
                "execution Session authority must be the persisted Work Host authority")
        }

        let sessionURL = configuration.home.timelineV2SessionJournalURL(
            SessionRef(identity.sessionID))
        let workURL = configuration.home.timelineV2WorkJournalURL(identity.work)
        guard FileManager.default.fileExists(atPath: sessionURL.path),
              FileManager.default.fileExists(atPath: workURL.path) else {
            throw HostedInHouseWorkError.invalidConfiguration(
                "Hosted Work requires a separately created canonical idle Session/Work pair")
        }

        let projectionURL = configuration.home.sessionFile(id: identity.sessionID)
        let projectionExists = FileManager.default.fileExists(atPath: projectionURL.path)
        if configuration.projectionMode == .reopenHistorical {
            guard projectionExists else {
                throw HostedInHouseWorkError.invalidConfiguration(
                    "historical projection reopen requires an existing Session projection")
            }
            let boundary = try Self.existingRunBoundary(
                at: projectionURL, identity: identity, model: configuration.model)
            switch boundary {
            // A replacement opener can crash after the flat `run_start` or complete
            // `run_start`+`model_change` boundary but before bridge installation. Those exact
            // current-Run shapes are idempotent retry inputs, just like an older historical
            // prefix or an Aviary-owned interrupted tail.
            case .foreign:
                throw HostedInHouseWorkError.invalidConfiguration(
                    "existing Session projection belongs to a different Work identity")
            case .historical, .partial, .runStartOnly, .complete:
                break
            case .headerOnly, .none:
                throw HostedInHouseWorkError.invalidConfiguration(
                    "existing Session projection is not a reopenable historical projection")
            }
        } else {
            guard configuration.modelContextMode == .launchFresh else {
                throw HostedInHouseWorkError.invalidConfiguration(
                    "exact cold resume requires a historical Session projection reopen")
            }
            if projectionExists {
                // A first-Run retry may own a complete/run_start-only flat boundary already
                // published before its canonical command. That boundary is reopened later
                // without appending. A header-only disposable prefix may be removed; everything
                // else (including foreign or mismatched transcript bytes) fails closed.
                switch try Self.existingRunBoundary(
                    at: projectionURL, identity: identity, model: configuration.model) {
                case .complete, .runStartOnly, .headerOnly:
                    break
                case .foreign, .historical, .partial:
                    throw HostedInHouseWorkError.invalidConfiguration(
                        "a fresh Hosted run cannot replace an existing Session projection")
                case .none:
                    throw HostedInHouseWorkError.invalidConfiguration(
                        "a fresh Hosted run cannot use a malformed Session projection")
                }
            }
        }

        if let assembly = configuration.systemPromptAssembly,
           Data(configuration.systemPrompt.utf8) != Data(assembly.flattenedText.utf8) {
            throw HostedInHouseWorkError.invalidConfiguration(
                "systemPrompt and systemPromptAssembly contain different bytes")
        }

        if let deadline = configuration.agentChildPilot?.deadline {
            guard deadline.timeIntervalSince1970.isFinite,
                  deadline > Date() else {
                throw HostedInHouseWorkError.invalidConfiguration(
                    "agent child pilot deadline must be finite and in the future")
            }
        }
    }

    private static func bounded(_ value: String, limit: Int = 500) -> String {
        String(value.prefix(limit))
    }

}

extension InHouseWorkFactory.Configuration {
    init(hostedConfiguration configuration: HostedInHouseWorkConfiguration) {
        self.init(
            home: configuration.home,
            cwd: configuration.cwd,
            model: configuration.model,
            provider: configuration.provider,
            runtimeHost: configuration.runtimeHost,
            workRunBinding: configuration.workRunBinding,
            serviceActorID: configuration.serviceActorID,
            actorKind: configuration.actorKind,
            systemPrompt: configuration.systemPrompt,
            systemPromptAssembly: configuration.systemPromptAssembly,
            reasoningEffort: configuration.reasoningEffort,
            maxDepth: configuration.maxDepth,
            maxIterations: configuration.maxIterations,
            childMaxIterations: configuration.childMaxIterations,
            memory: configuration.memory,
            recordPayloads: configuration.recordPayloads,
            goal: configuration.goal,
            hookPaths: configuration.hookPaths,
            projectionMode: configuration.projectionMode,
            modelContextMode: configuration.modelContextMode,
            peerDelegate: configuration.peerDelegate,
            selfDelegate: configuration.selfDelegate,
            startAdmissionGate: configuration.startAdmissionGate,
            adoptionEvidenceSink: configuration.adoptionEvidenceSink)
        self.agentChildPilot = configuration.agentChildPilot
    }
}
