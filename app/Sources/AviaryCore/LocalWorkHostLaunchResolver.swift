import Foundation

/// Host-local launch material for the durable Work service.
///
/// A daemon owns one of these values for its process generation.  The value is deliberately an
/// immutable snapshot: model routing, auth presence, environment and user preferences are
/// captured at construction and are never reread halfway through a Create or recovery probe.
/// Credentials are used only while materializing an in-memory provider.  Neither this type nor a
/// ``WorkLaunchManifestDraft`` contains a credential or a provider key expression.
public struct LocalWorkHostLaunchResolver: Sendable {
    public struct Configuration: Sendable {
        public let home: AgentHome
        /// The host-local registry is the only authority that turns an opaque client workspace
        /// identity into a filesystem URL. The registry itself never crosses the WorkService
        /// boundary.
        public let workspaceRegistry: WorkHostWorkspaceRegistry
        public let runtimeRepositoryRoot: URL
        public let allowedRuntimeVariants: Set<String>
        public let defaultRuntimeVariant: String
        public let runtimeExecutable: String
        public let models: ModelsConfig
        public let auth: AuthInfo
        public let environment: [String: String]
        public let preferences: ModelPreferences
        public let serviceActorID: String
        public let actorKind: String

        /// Capture all mutable host inputs once.  Passing explicit snapshots is useful to a
        /// daemon bootstrapper and makes tests independent of the machine running them.
        public init(
            home: AgentHome,
            workspaceRegistry: WorkHostWorkspaceRegistry,
            runtimeRepositoryRoot: URL,
            allowedRuntimeVariants: Set<String> = ["python3", "python3-shared"],
            defaultRuntimeVariant: String = "python3",
            runtimeExecutable: String = "/usr/bin/env",
            models: ModelsConfig? = nil,
            auth: AuthInfo? = nil,
            environment: [String: String]? = nil,
            preferences: ModelPreferences? = nil,
            serviceActorID: String = "aviaryd",
            actorKind: String = "work-host"
        ) {
            let capturedAuth = auth ?? AuthInfo.load(home: home)
            self.home = home
            self.workspaceRegistry = workspaceRegistry
            self.runtimeRepositoryRoot = runtimeRepositoryRoot
            self.allowedRuntimeVariants = allowedRuntimeVariants
            self.defaultRuntimeVariant = defaultRuntimeVariant
            self.runtimeExecutable = runtimeExecutable
            self.models = models ?? ModelsConfig.load(home: home, auth: capturedAuth)
            self.auth = capturedAuth
            self.environment = environment ?? ProcessEnvironment.shared.snapshot
            self.preferences = preferences ?? ModelPreferencesStore().load()
            self.serviceActorID = serviceActorID
            self.actorKind = actorKind
        }
    }

    /// Errors intentionally carry no untrusted paths, key expressions or body text.  A daemon
    /// may put the localized description in a bounded receipt without accidentally echoing a
    /// secret-looking request value.
    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case invalidConfiguration
        case workspaceNotApproved
        case workspaceUnavailable
        case workspaceSymlink
        case invalidWorkspaceSelection
        case runtimeVariantNotAllowed
        case runtimeUnavailable
        case invalidRuntimeExecutable
        case modelUnavailable
        case modelDrift
        case providerUnavailable
        case bodyUnavailable
        case bodyMismatch
        case authorityMismatch
        case manifestMismatch
        case unsupportedManifestOptions

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return "The local Work Host launch configuration is invalid."
            case .workspaceNotApproved:
                return "The requested workspace is outside the Work Host's approved roots."
            case .workspaceUnavailable:
                return "The approved workspace is unavailable."
            case .workspaceSymlink:
                return "Symlinked workspaces are not accepted by the local Work Host."
            case .invalidWorkspaceSelection:
                return "The requested opaque workspace selection is invalid."
            case .runtimeVariantNotAllowed:
                return "The requested runtime variant is not allowlisted."
            case .runtimeUnavailable:
                return "The allowlisted runtime script is unavailable."
            case .invalidRuntimeExecutable:
                return "The Work Host runtime executable is invalid."
            case .modelUnavailable:
                return "The requested in-house model is unavailable."
            case .modelDrift:
                return "The captured model route no longer matches the launch record."
            case .providerUnavailable:
                return "The captured provider route could not be materialized."
            case .bodyUnavailable:
                return "A retained launch body is unavailable."
            case .bodyMismatch:
                return "A retained launch body failed its identity check."
            case .authorityMismatch:
                return "A retained launch body belongs to a different Work Host."
            case .manifestMismatch:
                return "The launch manifest does not name this Work Host execution."
            case .unsupportedManifestOptions:
                return "The launch manifest contains options this Work Host cannot reconstruct."
            }
        }
    }

    public let configuration: Configuration

    private static let provenancePrefix = "local-work-host-launch-v1:"
    private static let maximumPathBytes = 4 * 1024
    private static let maximumRuntimeVariantBytes = 128
    private static let maximumBodyBytes = 64 * 1024 * 1024

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Convert the bounded service Create request into identity-independent, Run-free launch
    /// material. Create has no prompt bytes: the exact Start body is unavailable until Start and
    /// prompt assembly therefore belongs after the durable Start reservation.
    public func draft(
        for request: WorkServiceCreateWorkRequest
    ) throws -> WorkLaunchManifestDraft {
        guard request.commandID.utf8.count <= WorkServiceBounds.maxCommandValueCharacters,
              request.client.clientID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              !request.configuration.wasTruncated,
              request.configuration.includeContextFiles,
              request.configuration.contextPolicy == nil,
              request.configuration.resumePolicy == nil else {
            throw Error.invalidConfiguration
        }

        let selection = try resolveSelection(for: request.configuration)
        guard let workspaceID = request.configuration.workspaceID else {
            throw Error.invalidWorkspaceSelection
        }
        let workspace = try resolveWorkspace(workspaceID)
        let runtime = try validateRuntime(
            variant: configuration.defaultRuntimeVariant,
            repository: configuration.runtimeRepositoryRoot)

        let requestedThinking = request.configuration.thinkingLevel
        // HostedInHouseWork's current attestation treats `enabled` as a capability bit and the
        // level as the selected effort.  Keep the latter without claiming a separately enabled
        // reasoning subsystem that the host configuration cannot attest yet.
        let reasoning = WorkLaunchReasoningPolicy(enabled: false, level: requestedThinking)
        return WorkLaunchManifestDraft(
            workspace: WorkLaunchWorkspace(locator: workspace.path, policy: .workspace),
            runtime: WorkLaunchRuntime(
                providerID: selection.providerID,
                modelID: selection.modelID,
                runtimeVariant: runtime),
            configuration: request.configuration,
            requestedCapabilities: request.requestedCapabilities,
            contextPolicy: WorkLaunchContextPolicy(
                includeContextFiles: request.configuration.includeContextFiles),
            recordingPolicy: WorkLaunchRecordingPolicy(
                recordPayloads: request.configuration.recordPayloads),
            reasoningPolicy: reasoning,
            provenance: WorkLaunchManifestProvenance(
                source: Self.provenancePrefix + selection.configurationDigest))
    }

    /// Closure-shaped adapter for ``DurableJournalBackedWorkLaunchManifestStore``.
    public var draftResolver:
        @Sendable (WorkServiceCreateWorkRequest) async throws -> WorkLaunchManifestDraft {
        { [self] request in try self.draft(for: request) }
    }

    /// Assemble the prompt exactly once for the winning Start reservation. The caller must pass
    /// the retained Start bytes; this method verifies their digest before reading any current
    /// context, skill, or memory inputs. Recovery callers must use
    /// ``WorkLaunchManifestStore.resolvePromptAssembly(for:)`` instead.
    public func assemblePrompt(
        for draft: WorkLaunchManifestDraft,
        startBody: Data,
        startIntent: WorkLaunchStartIntent
    ) throws -> SystemPromptAssembly {
        guard startBody.count <= Self.maximumBodyBytes else { throw Error.bodyUnavailable }
        let bodyDigest = "sha256:" + AviarySHA256.hash(data: startBody)
            .map { String(format: "%02x", $0) }.joined()
        guard bodyDigest == startIntent.bodyDigest,
              let prompt = String(data: startBody, encoding: .utf8) else {
            throw Error.bodyMismatch
        }

        let cwd = draft.workspace.locator
        let settings = HarnessSettings.load(home: configuration.home)
        let library = Library.discover(
            home: configuration.home, settings: settings,
            projectRoot: URL(fileURLWithPath: cwd), enginePackageRoot: nil)
        let skillGate = SkillGate()
        let skillSelection = skillGate.select(
            skills: library.skills, prompt: prompt, cwd: cwd)
        let memoryStore = MemoryStore(
            repoRoot: configuration.runtimeRepositoryRoot,
            home: configuration.home, cwd: cwd)
        let memoryGate = MemoryGate()
        let memorySelection = memoryGate.select(
            memoryStore.load(sessionID: nil), prompt: prompt)
        do {
            return try SystemPromptAssembly.build(
                cwd: cwd,
                skills: skillGate.render(skillSelection),
                memory: memoryGate.render(memorySelection),
                includeContextFiles: draft.contextPolicy.includeContextFiles)
        } catch {
            throw Error.bodyUnavailable
        }
    }

    /// Closure-shaped adapter for a service that has already won a Start reservation. Keeping
    /// this seam separate from ``hostedConfigurationResolver`` prevents a recovery probe from
    /// accidentally rebuilding ambient prompt state.
    public typealias PromptAssemblyResolver = @Sendable (
        WorkLaunchManifestDraft, Data, WorkLaunchStartIntent
    ) async throws -> SystemPromptAssembly

    public var promptAssemblyResolver: PromptAssemblyResolver {
        { [self] draft, startBody, startIntent in
            try self.assemblePrompt(
                for: draft, startBody: startBody, startIntent: startIntent)
        }
    }

    /// Materialize an exact Run-bound manifest.  This is the only effectful resolver operation:
    /// it may construct a provider in memory, but it never persists a credential and never uses
    /// the current process environment or executes a key command.
    public func hostedConfiguration(
        for manifest: WorkLaunchManifest,
        binding: WorkRunBinding,
        policy: WorkLaunchExecutionPolicy
    ) async throws -> HostedInHouseWorkConfiguration? {
        try validateManifestIdentity(manifest, binding: binding)
        guard manifest.hooks.isEmpty,
              manifest.goal == WorkLaunchGoalConfiguration(),
              manifest.peerScheduler == WorkLaunchPeerSchedulerConfiguration(),
              manifest.contextPolicy == WorkLaunchContextPolicy(),
              manifest.recordingPolicy.wireLogLocator == nil,
              manifest.resumePolicy == policy.resumePolicy,
              manifest.reasoningPolicy.tokenBudget == nil,
              manifest.budgetPolicy.maximumTokens == nil,
              manifest.budgetPolicy.maximumWallClockSeconds == nil else {
            throw Error.unsupportedManifestOptions
        }

        guard let workspaceID = manifest.workspaceID else {
            throw Error.manifestMismatch
        }
        // This is the final host-side identity check before materializing provider/runtime state.
        // RuntimeHost currently accepts a path as its cwd, so Process.run cannot atomically pin
        // that directory against a replacement between this check and the child spawn. The
        // remaining window is reported by the runtime/launch failure path rather than treated as
        // a security boundary; all durable admission and recovery checks still revalidate here.
        let workspace = try resolveWorkspace(workspaceID)
        guard workspace.path == manifest.workspace.locator else {
            throw Error.manifestMismatch
        }
        let expected = try resolveSelection(
            providerID: manifest.runtime.providerID, modelID: manifest.runtime.modelID)
        guard manifest.provenance.source == Self.provenancePrefix + expected.configurationDigest else {
            throw Error.modelDrift
        }
        _ = try validateRuntime(
            variant: manifest.runtime.runtimeVariant,
            repository: configuration.runtimeRepositoryRoot)

        let launchStore = WorkLaunchManifestStore(home: configuration.home)
        guard manifest.promptAssembly != nil else { throw Error.manifestMismatch }
        let assembly: SystemPromptAssembly
        do {
            assembly = try launchStore.resolvePromptAssembly(for: manifest)
        } catch let error as WorkLaunchManifestStoreError {
            switch error {
            case .wrongAuthority: throw Error.authorityMismatch
            case .bodyUnavailable, .invalidReference: throw Error.bodyUnavailable
            default: throw Error.manifestMismatch
            }
        } catch {
            throw Error.bodyUnavailable
        }
        // A Run-bound Start must always retain its exact input, even when it is empty.  Reading
        // it here verifies that the provider cannot be opened against digest-only evidence.
        _ = try readBody(manifest.initialInputBodyReference, required: true)

        let (providerSpec, model) = try providerAndModel(
            providerID: expected.providerID, modelID: expected.modelID)
        let providerResult = await ChatProviderRouting.makeProvider(
            spec: providerSpec,
            model: model,
            home: configuration.home,
            sessionID: manifest.identity.session.sessionID,
            resolveSecret: { [environment = configuration.environment] expression in
                Self.resolveCapturedSecret(expression, environment: environment)
            })
        let provider: any ChatProvider
        switch providerResult {
        case .success(let resolved): provider = resolved
        case .failure: throw Error.providerUnavailable
        }
        guard let runtimeHost = RuntimeHost.bundledPython(
            repoRoot: configuration.runtimeRepositoryRoot,
            python: configuration.runtimeExecutable,
            variant: manifest.runtime.runtimeVariant) else {
            throw Error.runtimeUnavailable
        }

        return HostedInHouseWorkConfiguration(
            home: configuration.home,
            cwd: workspace.path,
            model: model,
            provider: provider,
            runtimeHost: runtimeHost,
            workRunBinding: binding,
            serviceActorID: configuration.serviceActorID,
            actorKind: configuration.actorKind,
            systemPrompt: assembly.flattenedText,
            systemPromptAssembly: assembly,
            reasoningEffort: manifest.reasoningPolicy.level,
            maxDepth: manifest.budgetPolicy.maximumDepth ?? 3,
            maxIterations: manifest.budgetPolicy.maximumTurns ?? 40,
            childMaxIterations: manifest.budgetPolicy.childMaximumTurns ?? 20,
            recordPayloads: manifest.recordingPolicy.recordPayloads,
            projectionMode: policy.projection,
            modelContextMode: policy.modelContext)
    }

    /// Closure-shaped adapter for the durable service.  The service supplies the exact manifest
    /// selected by the Run-bound pointer; this closure never rebuilds one from a WorkRef.
    public var hostedConfigurationResolver:
        DurableJournalBackedWorkLaunchManifestStore.HostedConfigurationResolver {
        { [self] manifest, binding, policy in
            try await self.hostedConfiguration(for: manifest, binding: binding, policy: policy)
        }
    }

    /// A local, non-effectful recovery probe for Run-free launch material. It checks only the
    /// allowlisted runtime script, approved workspace, current captured route attestation, and
    /// bounded policy/configuration. Prompt bytes do not exist at Create/template time and are
    /// therefore intentionally not read here. It does not call
    /// ``ChatProviderRouting.makeProvider``, invoke a shell, open a socket, start Python, or
    /// perform a network request.
    public func canReconstruct(
        _ template: WorkLaunchWorkTemplateRecord
    ) -> Bool {
        guard let persistedHost = configuration.home.persistedWorkHostID,
              template.binding.workHost == WorkHostRef(persistedHost) else { return false }
        guard let workspaceID = template.template.draft.configuration.workspaceID,
              let workspace = try? resolveWorkspace(workspaceID),
              workspace.path == template.template.draft.workspace.locator,
              workspace.path.utf8.count <= Self.maximumPathBytes else { return false }
        guard let selection = try? resolveSelection(
            providerID: template.template.draft.runtime.providerID,
            modelID: template.template.draft.runtime.modelID),
            template.template.draft.provenance.source
                == Self.provenancePrefix + selection.configurationDigest else {
            return false
        }
        guard (try? validateRuntime(
            variant: template.template.draft.runtime.runtimeVariant,
            repository: configuration.runtimeRepositoryRoot)) != nil else { return false }
        guard template.template.draft.contextPolicy.maximumContextBytes == nil,
              template.template.draft.contextPolicy.includeContextFiles,
              template.template.draft.recordingPolicy.wireLogLocator == nil,
              template.template.draft.resumePolicy == WorkLaunchResumePolicy(),
              template.template.draft.reasoningPolicy.tokenBudget == nil,
              template.template.draft.budgetPolicy.maximumTokens == nil,
              template.template.draft.budgetPolicy.maximumWallClockSeconds == nil,
              template.template.draft.goal == WorkLaunchGoalConfiguration(),
              template.template.draft.hooks.isEmpty,
              template.template.draft.peerScheduler == WorkLaunchPeerSchedulerConfiguration()
        else { return false }
        return true
    }

    public var reconstructabilityProbe:
        @Sendable (WorkLaunchWorkTemplateRecord) async throws -> Bool {
        { [self] template in self.canReconstruct(template) }
    }

    // MARK: Selection and local policy

    private func resolveSelection(
        for request: WorkServiceWorkConfiguration
    ) throws -> InHouseModelSelection {
        switch (request.providerID, request.modelID) {
        case (let provider?, let model?):
            return try resolveSelection(providerID: provider, modelID: model)
        case (nil, let model?):
            return try resolveSelection(reference: model)
        case (nil, nil):
            return try resolveSelection(reference: nil)
        case (_, nil):
            throw Error.modelUnavailable
        }
    }

    private func resolveSelection(reference: String?) throws -> InHouseModelSelection {
        let result = InHouseModelResolver.resolve(
            reference,
            inputs: InHouseModelResolver.Inputs(
                config: configuration.models,
                auth: configuration.auth,
                environment: configuration.environment,
                preferences: configuration.preferences))
        guard case .success(let selection) = result else { throw Error.modelUnavailable }
        return selection
    }

    private func resolveSelection(
        providerID: String, modelID: String
    ) throws -> InHouseModelSelection {
        let result = InHouseModelResolver.resolve(
            "\(providerID)/\(modelID)",
            inputs: InHouseModelResolver.Inputs(
                config: configuration.models,
                auth: configuration.auth,
                environment: configuration.environment,
                preferences: configuration.preferences))
        guard case .success(let selection) = result else { throw Error.modelUnavailable }
        return selection
    }

    private func providerAndModel(
        providerID: String, modelID: String
    ) throws -> (ProviderSpec, ModelSpec) {
        var providers = configuration.models.providers
        let codex = BuiltInProviders.openAICodex(auth: configuration.auth)
        if !providers.contains(where: { $0.id == codex.id }) { providers.append(codex) }
        guard let provider = providers.first(where: { $0.id == providerID }),
              let model = provider.models.first(where: { $0.id == modelID }) else {
            throw Error.modelUnavailable
        }
        return (provider, model)
    }

    private func resolveWorkspace(_ workspaceID: WorkHostWorkspaceID) throws -> URL {
        do {
            return try configuration.workspaceRegistry.resolve(workspaceID)
        } catch let error as WorkHostWorkspaceRegistryError {
            switch error {
            case .invalidWorkspaceID: throw Error.invalidWorkspaceSelection
            case .workspaceNotFound, .workspaceNotDirectory, .workspaceInaccessible,
                 .workspaceIdentityMismatch:
                throw Error.workspaceUnavailable
            case .workspaceSymlink: throw Error.workspaceSymlink
            default: throw Error.workspaceUnavailable
            }
        } catch {
            throw Error.workspaceUnavailable
        }
    }

    private func secureDirectory(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard standardized.path == resolved.path else { throw Error.workspaceSymlink }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Error.workspaceUnavailable
        }
        return standardized
    }

    private func validateRuntime(variant: String, repository: URL) throws -> String {
        guard variant.utf8.count <= Self.maximumRuntimeVariantBytes,
              configuration.allowedRuntimeVariants.contains(variant),
              variant == variant.trimmingCharacters(in: .whitespacesAndNewlines),
              !variant.isEmpty,
              !variant.contains("/"), !variant.contains("\\") else {
            throw Error.runtimeVariantNotAllowed
        }
        guard configuration.runtimeExecutable == "/usr/bin/env" else {
            throw Error.invalidRuntimeExecutable
        }
        let root = try secureDirectory(repository)
        let script = root.appending(path: "runtime-hosts/\(variant)/host.py")
        let standardized = script.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard standardized.path == resolved.path else { throw Error.runtimeUnavailable }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: standardized.path, isDirectory: &isDirectory), !isDirectory.boolValue,
            FileManager.default.isReadableFile(atPath: standardized.path) else {
            throw Error.runtimeUnavailable
        }
        return variant
    }

    private func workHostAuthorityOwner() throws -> WorkHostRef {
        try configuration.home.requirePersistedWorkHost()
    }

    private func workHostAuthority() throws -> JournalRef {
        .workHost(try workHostAuthorityOwner())
    }

    private func validateManifestIdentity(
        _ manifest: WorkLaunchManifest, binding: WorkRunBinding
    ) throws {
        let expected = WorkLaunchManifestIdentity(
            work: binding.workBinding.work,
            session: binding.workBinding.session,
            sessionAttachment: binding.workBinding.sessionAttachment,
            run: binding.run)
        guard manifest.identity == expected,
              binding.workBinding.workHost == (try? workHostAuthorityOwner()),
              manifest.identity.work.workHostID == binding.workBinding.workHost.workHostID else {
            throw Error.manifestMismatch
        }
    }

    private func readBody(
        _ reference: TimelineBodyReference?, required: Bool
    ) throws -> Data {
        guard let reference else {
            if required { throw Error.bodyUnavailable }
            return Data()
        }
        guard reference.authority == (try? workHostAuthority()),
              let digest = reference.digest,
              reference.referenceID == digest,
              ContextBodyStore.isValidDigest(digest),
              let byteCount = reference.byteCount,
              byteCount >= 0, byteCount <= Self.maximumBodyBytes else {
            throw Error.authorityMismatch
        }
        guard let body = try? ContextBodyStore(home: configuration.home).read(reference),
              body.count == byteCount else { throw Error.bodyUnavailable }
        let actual = "sha256:" + AviarySHA256.hash(data: body)
            .map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { throw Error.bodyMismatch }
        return body
    }

    private static func resolveCapturedSecret(
        _ expression: String?, environment: [String: String]
    ) -> String? {
        guard let expression, !expression.isEmpty else { return nil }
        switch ApiKeyForm.classify(expression) {
        case .environmentVariable(let name):
            let value = environment[name]
            return value?.isEmpty == false ? value : nil
        case .literal:
            return expression
        case .command:
            // Command-form credentials are intentionally not eligible for this host-local
            // resolver.  InHouseModelResolver rejects them before this closure is called.
            return nil
        }
    }

}
