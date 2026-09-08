import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Host-private launch material

/// The durable Work service cannot reconstruct an execution from the control journal's digests
/// alone. A host-private manifest resolver therefore supplies the material which is deliberately
/// absent from transport and control records (for example a provider/runtime and the retained
/// prompt). `durableRecord` is the verified record returned by ``WorkLaunchManifestStore``;
/// closures are only the injected runtime/provider resolver and never an in-memory reconstruction
/// database.
public struct JournalBackedWorkLaunchManifest: Sendable {
    public let identity: WorkLaunchManifestIdentity?
    public let template: WorkLaunchWorkTemplateRecord?
    public let bodyDigest: String
    public let configurationDigest: String
    public let launchMetadata: WorkHostLaunchMetadata
    public let hostedConfiguration: (@Sendable (WorkRunBinding) -> HostedInHouseWorkConfiguration?)?
    public let hostedConfigurationAsync:
        (@Sendable (WorkRunBinding, WorkLaunchExecutionPolicy) async throws
            -> HostedInHouseWorkConfiguration?)?
    public let durableRecord: WorkLaunchManifestRecord?
    public let retainedRecord: WorkLaunchDraftRetentionRecord?
    /// Digest of the identity-independent durable draft. This is distinct from the final
    /// identity-bound manifest digest and is what a retry uses to reload the exact draft.
    public let retainedDraftDigest: String?
    /// The exact bounded caller configuration, when attested by the adapter. The durable store
    /// always populates this from the retained draft; lightweight injected seams may leave it nil.
    public let requestedConfiguration: WorkServiceWorkConfiguration?
    public let requestedCapabilities: Set<WorkServiceCapability>?

    public init(
        bodyDigest: String,
        configurationDigest: String,
        launchMetadata: WorkHostLaunchMetadata = .init(),
        hostedConfiguration: (@Sendable (WorkRunBinding) -> HostedInHouseWorkConfiguration?)? = nil,
        identity: WorkLaunchManifestIdentity? = nil,
        template: WorkLaunchWorkTemplateRecord? = nil,
        hostedConfigurationAsync:
            (@Sendable (WorkRunBinding, WorkLaunchExecutionPolicy) async throws
                -> HostedInHouseWorkConfiguration?)? = nil,
        durableRecord: WorkLaunchManifestRecord? = nil,
        retainedDraftDigest: String? = nil,
        retainedRecord: WorkLaunchDraftRetentionRecord? = nil,
        requestedConfiguration: WorkServiceWorkConfiguration? = nil,
        requestedCapabilities: Set<WorkServiceCapability>? = nil
    ) {
        self.identity = identity
        self.template = template
        self.bodyDigest = bodyDigest
        self.configurationDigest = configurationDigest
        self.launchMetadata = launchMetadata
        self.hostedConfiguration = hostedConfiguration
        self.hostedConfigurationAsync = hostedConfigurationAsync
        self.durableRecord = durableRecord
        self.retainedDraftDigest = retainedDraftDigest
        self.retainedRecord = retainedRecord
        self.requestedConfiguration = requestedConfiguration
        self.requestedCapabilities = requestedCapabilities
    }

    fileprivate func withTemplate(
        _ template: WorkLaunchWorkTemplateRecord
    ) -> JournalBackedWorkLaunchManifest {
        JournalBackedWorkLaunchManifest(
            bodyDigest: bodyDigest, configurationDigest: configurationDigest,
            launchMetadata: launchMetadata, hostedConfiguration: hostedConfiguration,
            identity: nil, template: template,
            hostedConfigurationAsync: hostedConfigurationAsync,
            durableRecord: nil, retainedDraftDigest: retainedDraftDigest,
            retainedRecord: retainedRecord,
            requestedConfiguration: requestedConfiguration
                ?? template.template.draft.configuration,
            requestedCapabilities: requestedCapabilities
                ?? template.template.draft.requestedCapabilities)
    }

    fileprivate func withDurableRecord(
        _ record: WorkLaunchManifestRecord
    ) -> JournalBackedWorkLaunchManifest {
        JournalBackedWorkLaunchManifest(
            bodyDigest: record.manifest.initialInputBodyDigest ?? record.manifestDigest,
            configurationDigest: record.manifestDigest,
            launchMetadata: WorkHostLaunchMetadata(
                providerID: record.manifest.runtime.providerID,
                modelID: record.manifest.runtime.modelID,
                workspaceID: template?.template.draft.configuration.workspaceID
                    ?? retainedRecord?.draft.draft.configuration.workspaceID,
                runtimeHostKind: record.manifest.runtime.runtimeVariant),
            hostedConfiguration: hostedConfiguration,
            identity: record.manifest.identity,
            template: template,
            hostedConfigurationAsync: hostedConfigurationAsync,
            durableRecord: record,
            retainedDraftDigest: retainedDraftDigest,
            retainedRecord: retainedRecord,
            requestedConfiguration: requestedConfiguration
                ?? template?.template.draft.configuration,
            requestedCapabilities: requestedCapabilities
                ?? template?.template.draft.requestedCapabilities)
    }
}

/// Host-private manifest seam.  `retain` is called before the control reservation, making the
/// manifest itself the first durable/recoverable admission fact.  `resolve` is called only during
/// a fresh recovery read; no previously returned manifest is cached as proof.
public protocol JournalBackedWorkServiceLaunchManifestStore: Sendable {
    func retain(
        _ request: WorkServiceCreateWorkRequest
    ) async throws -> JournalBackedWorkLaunchManifest

    /// Recover a control reservation whose response was lost before the Run-free template was
    /// published. Implementations must use only the reservation's durable retention proof; they
    /// must not invoke an ambient/default resolver for this path.
    func recoverReservation(
        _ reservation: WorkHostControlCreationReservation
    ) async throws -> JournalBackedWorkLaunchManifest?

    /// Publish the Run-free Work template after control reservation. This is the Create commit;
    /// no Run or execution actor exists yet.
    func bindTemplate(
        _ manifest: JournalBackedWorkLaunchManifest,
        binding: WorkBinding
    ) async throws -> JournalBackedWorkLaunchManifest

    /// Publish one exact Run-bound manifest for a client-qualified Start admission.
    func bindStart(
        _ manifest: JournalBackedWorkLaunchManifest,
        binding: WorkBinding,
        run: RunRef,
        intent: WorkLaunchStartIntent,
        body: Data,
        policy: WorkLaunchExecutionPolicy,
        /// Exact predecessor assembly selected by native cold-resume preflight. When present it
        /// is the only permitted assembly input; the ambient resolver is for launch-fresh only.
        selectedPromptAssembly: WorkLaunchPromptAssembly?
    ) async throws -> JournalBackedWorkLaunchManifest

    /// Durably choose the one Run which may assemble a Start prompt. Only the CAS winner may
    /// consult ambient files, skills, or memory; a reserved retry must use its retained assembly.
    func reserveStart(
        _ template: WorkLaunchWorkTemplateRecord,
        binding: WorkBinding,
        run: RunRef,
        intent: WorkLaunchStartIntent,
        expectedPrevious: WorkLaunchManifestGeneration?,
        initialInputBodyReference: TimelineBodyReference
    ) async throws -> WorkLaunchStartAdmission

    func prepareStart(
        _ reservation: WorkLaunchStartReservation,
        promptAssembly: WorkLaunchPromptAssembly
    ) async throws -> WorkLaunchStartReservation

    /// Read the exact binding-wide Start reservation without selecting a Run. A reservation
    /// which already contains an assembly is eligible for exact recovery; one without it is a
    /// crash-during-assembly fact and must remain recovery-required.
    func resolveStartReservation(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        intent: WorkLaunchStartIntent
    ) async throws -> WorkLaunchStartReservation?

    /// Load the exact durable assembly from a predecessor Run for native cold replay. A nil
    /// result is not permission to consult ambient prompt sources.
    func resolvePromptAssemblyRecord(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        run: RunRef
    ) async throws -> WorkLaunchPromptAssembly?

    func resolve(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef
    ) async throws -> JournalBackedWorkLaunchManifest?

    /// Resolve an exact prior Start admission. A nil result is never permission to mint another
    /// Run for a retry; the caller must report recovery-required instead.
    func resolveStart(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        intent: WorkLaunchStartIntent
    ) async throws -> JournalBackedWorkLaunchManifest?

    /// Read the exact Work-level Run selection without treating it as execution liveness. This
    /// lets recovery distinguish a Run-bound admission which died before `run.started` from the
    /// ordinary post-End selection of a completed historical Run.
    func currentSelection(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef
    ) async throws -> WorkLaunchManifestRecord?

    /// The pending pointer is a binding-wide admission fence. Its presence without a current
    /// selection is a crash window, not permission to treat an idle Work as reconstructable.
    func hasPendingStart(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef
    ) async throws -> Bool

    /// Whether an exact pending Run is still fenced by the selection observed when it was
    /// published. Historical pending records must be returned for duplicate projection but may
    /// never rewind a newer current-by-binding selection.
    func mayRepairPendingStart(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        intent: WorkLaunchStartIntent,
        currentSelection: WorkLaunchBindingSelection?
    ) async throws -> Bool

    /// Prove that the host can materialize an executable configuration from the durable Run-free
    /// template. A nonnil resolver closure alone is not reconstruction proof after restart.
    func canReconstruct(
        _ manifest: JournalBackedWorkLaunchManifest
    ) async throws -> Bool
}

public extension JournalBackedWorkServiceLaunchManifestStore {
    func recoverReservation(
        _ reservation: WorkHostControlCreationReservation
    ) async throws -> JournalBackedWorkLaunchManifest? {
        _ = reservation
        return nil
    }

    func mayRepairPendingStart(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        intent: WorkLaunchStartIntent,
        currentSelection: WorkLaunchBindingSelection?
    ) async throws -> Bool {
        // Test/injected stores which do not expose durable pending fences remain conservative:
        // their pending result is treated as repairable only when it is not already superseded.
        _ = (work, session, sessionAttachment, intent, currentSelection)
        return true
    }

    func resolveStartReservation(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        intent: WorkLaunchStartIntent
    ) async throws -> WorkLaunchStartReservation? {
        _ = (work, session, sessionAttachment, intent)
        return nil
    }

    func resolvePromptAssemblyRecord(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        run: RunRef
    ) async throws -> WorkLaunchPromptAssembly? {
        _ = (work, session, sessionAttachment, run)
        return nil
    }
}

/// Bridge the service seam to the durable ``WorkLaunchManifestStore``. The draft and runtime
/// resolvers are injected because Core must not know how a host obtains provider credentials,
/// model instances, or workspace access. The durable store owns retention, binding, generation,
/// and exact-identity verification. Recovery always uses the store's Work-template pointer; the
/// service never substitutes a closure or an in-memory index for that durable lookup.
public struct DurableJournalBackedWorkLaunchManifestStore:
    JournalBackedWorkServiceLaunchManifestStore, Sendable {
    public typealias DraftResolver =
        @Sendable (WorkServiceCreateWorkRequest) async throws -> WorkLaunchManifestDraft
    public typealias HostedConfigurationResolver =
        @Sendable (WorkLaunchManifest, WorkRunBinding, WorkLaunchExecutionPolicy) async throws
            -> HostedInHouseWorkConfiguration?
    public typealias PromptAssemblyResolver =
        @Sendable (WorkLaunchManifestDraft, Data, WorkLaunchStartIntent) async throws
            -> SystemPromptAssembly
    public typealias ReconstructabilityProbe =
        @Sendable (WorkLaunchWorkTemplateRecord) async throws -> Bool

    public let store: WorkLaunchManifestStore
    private let draftResolver: DraftResolver
    private let hostedResolver: HostedConfigurationResolver?
    private let promptAssemblyResolver: PromptAssemblyResolver?
    private let reconstructabilityProbe: ReconstructabilityProbe?
    private let bodyAuthority: JournalRef

    public init(
        store: WorkLaunchManifestStore,
        bodyAuthority: JournalRef,
        draftResolver: @escaping DraftResolver,
        hostedResolver: HostedConfigurationResolver? = nil,
        promptAssemblyResolver: PromptAssemblyResolver? = nil,
        reconstructabilityProbe: ReconstructabilityProbe? = nil
    ) {
        self.store = store
        self.bodyAuthority = bodyAuthority
        self.draftResolver = draftResolver
        self.hostedResolver = hostedResolver
        self.promptAssemblyResolver = promptAssemblyResolver
        self.reconstructabilityProbe = reconstructabilityProbe
    }

    public func retain(
        _ request: WorkServiceCreateWorkRequest
    ) async throws -> JournalBackedWorkLaunchManifest {
        // The Create key is caller-computable. Recovering it before invoking the resolver closes
        // the crash window after durable retention but before the control reservation: a changed
        // provider default must not select a second draft or rerun provider/workspace effects.
        let requestKey = WorkLaunchCreateKey(
            client: request.client,
            requestDigest: try WorkLaunchCreateKey.requestDigest(
                configuration: request.configuration,
                requestedCapabilities: request.requestedCapabilities),
            commandID: request.commandID,
            causalControlCursor: request.causalControlCursor)
        if let retained = try store.loadRetainedDraft(for: requestKey) {
            return retainedManifest(retained)
        }
        let draft = try await draftResolver(request)
        guard draft.configuration == request.configuration,
              draft.requestedCapabilities == request.requestedCapabilities else {
            throw WorkServiceProtocolError.invalidRequest(
                "resolved launch draft does not preserve the requested Create identity")
        }
        // Create retains only identity-independent launch configuration. Start owns its exact
        // input body and retains it under the chosen Run identity before manifest publication.
        // The request key is client/command/cursor-qualified and its digest is independent of the
        // resolved runtime and provenance timestamp. This makes duplicate Create calls return
        // the same retained draft after a process restart, even when ambient defaults changed.
        let retained = try store.retain(draft, for: requestKey)
        return retainedManifest(retained)
    }

    private func retainedManifest(
        _ retained: WorkLaunchDraftRetentionRecord
    ) -> JournalBackedWorkLaunchManifest {
        let draft = retained.draft.draft
        return JournalBackedWorkLaunchManifest(
            bodyDigest: retained.digest,
            configurationDigest: retained.digest,
            launchMetadata: WorkHostLaunchMetadata(
                providerID: draft.runtime.providerID,
                modelID: draft.runtime.modelID,
                workspaceID: draft.configuration.workspaceID,
                runtimeHostKind: draft.runtime.runtimeVariant),
            hostedConfigurationAsync: {
                guard let resolver = hostedResolver else { return nil }
                return { @Sendable [store, resolver] binding, policy in
                    let identity = WorkLaunchManifestIdentity(
                        work: binding.workBinding.work, session: binding.workBinding.session,
                        sessionAttachment: binding.workBinding.sessionAttachment, run: binding.run)
                    guard let record = try store.read(identity) else {
                        throw WorkServiceProtocolError.sourceIncomplete
                    }
                    return try await resolver(record.manifest, binding, policy)
                }
            }(), retainedDraftDigest: retained.digest,
            retainedRecord: retained,
            requestedConfiguration: draft.configuration,
            requestedCapabilities: draft.requestedCapabilities)
    }

    public func recoverReservation(
        _ reservation: WorkHostControlCreationReservation
    ) async throws -> JournalBackedWorkLaunchManifest? {
        let retained = try store.loadRetainedDraft(
            client: reservation.client,
            commandID: reservation.command.commandID,
            causalControlCursor: reservation.causalControlCursor,
            draftDigest: reservation.configurationDigest)
        guard let retained, retained.digest == reservation.configurationDigest else {
            return nil
        }
        let draft = retained.draft.draft
        return JournalBackedWorkLaunchManifest(
            bodyDigest: retained.digest,
            configurationDigest: retained.digest,
            launchMetadata: WorkHostLaunchMetadata(
                providerID: draft.runtime.providerID,
                modelID: draft.runtime.modelID,
                workspaceID: draft.configuration.workspaceID,
                runtimeHostKind: draft.runtime.runtimeVariant),
            hostedConfigurationAsync: {
                guard let resolver = hostedResolver else { return nil }
                return { @Sendable [store, resolver] binding, policy in
                    let identity = WorkLaunchManifestIdentity(
                        work: binding.workBinding.work, session: binding.workBinding.session,
                        sessionAttachment: binding.workBinding.sessionAttachment, run: binding.run)
                    guard let record = try store.read(identity) else {
                        throw WorkServiceProtocolError.sourceIncomplete
                    }
                    return try await resolver(record.manifest, binding, policy)
                }
            }(),
            retainedDraftDigest: retained.digest,
            retainedRecord: retained,
            requestedConfiguration: draft.configuration,
            requestedCapabilities: draft.requestedCapabilities)
    }

    public func bindTemplate(
        _ manifest: JournalBackedWorkLaunchManifest,
        binding: WorkBinding
    ) async throws -> JournalBackedWorkLaunchManifest {
        if let template = manifest.template {
            guard template.work == binding.work,
                  template.workHost == binding.workHost else {
                throw WorkServiceProtocolError.journalMismatch
            }
            return manifest.withTemplate(template)
        }
        guard let retained = manifest.retainedRecord else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let template = try store.publishTemplate(retained, binding: binding)
        return manifest.withTemplate(template)
    }

    public func reserveStart(
        _ template: WorkLaunchWorkTemplateRecord,
        binding: WorkBinding,
        run: RunRef,
        intent: WorkLaunchStartIntent,
        expectedPrevious: WorkLaunchManifestGeneration?,
        initialInputBodyReference: TimelineBodyReference
    ) async throws -> WorkLaunchStartAdmission {
        guard template.workHost.workHostID == (try? store.home.requirePersistedWorkHostID()) else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return try store.reserveStart(
            template, binding: binding, run: run, startIntent: intent,
            expectedPrevious: expectedPrevious,
            initialInputBodyReference: initialInputBodyReference)
    }

    public func prepareStart(
        _ reservation: WorkLaunchStartReservation,
        promptAssembly: WorkLaunchPromptAssembly
    ) async throws -> WorkLaunchStartReservation {
        try store.prepareStart(reservation, promptAssembly: promptAssembly)
    }

    public func resolveStartReservation(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        intent: WorkLaunchStartIntent
    ) async throws -> WorkLaunchStartReservation? {
        let binding = WorkBinding(
            session: session, work: work, workHost: WorkHostRef(work.workHostID),
            sessionAttachment: sessionAttachment)
        let reservation: WorkLaunchStartReservation?
        do {
            reservation = try store.readStartReservation(for: binding)
        } catch WorkLaunchManifestStoreError.requestConflict {
            // The single Work-level reservation belongs to another exact binding. It is a
            // durable fence, not recovery material that this caller may adopt.
            return nil
        } catch {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        guard let reservation else { return nil }
        return reservation.intent == intent ? reservation : nil
    }

    public func resolvePromptAssemblyRecord(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        run: RunRef
    ) async throws -> WorkLaunchPromptAssembly? {
        let identity = WorkLaunchManifestIdentity(
            work: work, session: session, sessionAttachment: sessionAttachment, run: run)
        return try store.read(identity)?.manifest.promptAssembly
    }

    public func bindStart(
        _ manifest: JournalBackedWorkLaunchManifest,
        binding: WorkBinding,
        run: RunRef,
        intent: WorkLaunchStartIntent,
        body: Data,
        policy: WorkLaunchExecutionPolicy,
        selectedPromptAssembly: WorkLaunchPromptAssembly? = nil
    ) async throws -> JournalBackedWorkLaunchManifest {
        guard let template = manifest.template,
              template.work == binding.work,
              template.workHost == binding.workHost else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        // Retain and verify the exact per-Run input before publication. Create's template may
        // contain a default, but a replacement Start is allowed to carry different bytes.
        let reference: TimelineBodyReference
        do {
            reference = try ContextBodyStore(home: store.home).retain(body, authority: bodyAuthority)
        } catch {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        guard reference.digest == intent.bodyDigest else {
            throw WorkServiceProtocolError.invalidRequest(
                "Start input does not match its durable Start identity")
        }
        // The binding pointer is the durable Work-level Start reservation. A first Start may
        // never replace an in-flight pointer: exact retries join the same record, while a
        // different client-qualified Start fails closed. Replacement is reserved exclusively
        // for End -> Start and remains a compare-and-swap under the store lock.
        let currentSelection = try store.readCurrentSelection(for: binding)
        // The current pointer is Work-scoped, so an alternate canonical Session sees the prior
        // owner's completed Run here as well.  Same-binding replacements reopen historical
        // state; a different attached binding must use a fresh projection and is allowed to
        // advance the Work pointer under the same CAS.  A fresh first Start has no current
        // selection and is unaffected by this distinction.
        let replacingEndedRun: Bool
        let canReplaceDifferentBinding = policy.modelContext == .launchFresh
            && (policy.projection == .fresh || policy.projection == .reopenHistorical)
        if let current = currentSelection {
            let currentBinding = current.record.manifest.workRunBinding.workBinding
            let sameBinding = currentBinding.session == binding.session
                && currentBinding.sessionAttachment == binding.sessionAttachment
            replacingEndedRun = sameBinding
                ? policy.projection == .reopenHistorical
                : canReplaceDifferentBinding
        } else {
            replacingEndedRun = policy.projection == .reopenHistorical
        }

        // A process can die after the exact Run pointer is published but before the Work-level
        // selection pointer. Recover that one pending intent before considering a fresh Run. The
        // caller's in-process gate and the durable Start intent are the two halves of this CAS;
        // no scan result is accepted for a different intent or silently made current.
        if let pending = try store.readPendingStart(for: binding, intent: intent) {
            let mayRepair = try store.mayRepairPendingStart(
                for: binding, intent: intent, currentSelection: currentSelection)
            if mayRepair {
                let repaired = try store.repairCurrentSelection(
                    pending, expectedPrevious: currentSelection?.selectionGeneration)
                guard repaired.manifest.identity.run == pending.manifest.identity.run,
                      repaired.manifest.startIntent == intent else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                return manifest.withDurableRecord(repaired)
            }
            // The pending record is an old, exact Start whose Work selection has since moved to
            // another Run. Return it only for duplicate projection; never regress the binding
            // pointer merely because a historical pending marker survived cleanup.
            return manifest.withDurableRecord(pending)
        }
        let current = currentSelection?.record
        if let current, !replacingEndedRun {
            let currentBinding = current.manifest.workRunBinding.workBinding
            let sameBinding = currentBinding.session == binding.session
                && currentBinding.sessionAttachment == binding.sessionAttachment
            // A Work-level current selection can belong to another canonical Session.  It is
            // not an idempotent hit for this caller, but a completed predecessor which this
            // exact fresh binding may replace under the expectedPrevious CAS.  All callers of
            // this adapter reach here only after the service has proven the Work is idle and
            // selected the corresponding launch policy.
            if !sameBinding {
                guard canReplaceDifferentBinding else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
            }
            if sameBinding {
                guard current.manifest.startIntent == intent else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                return manifest.withDurableRecord(current)
            }
        }
        let expectedPrevious = currentSelection?.selectionGeneration

        // The exact Start bytes are retained before the durable winner CAS and are the only body
        // input supplied to prompt assembly. A reservation without an assembly is a crash/recovery
        // fact, not permission to read ambient files again.
        let exactBody: Data
        do {
            exactBody = try ContextBodyStore(home: store.home).read(reference)
        } catch {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let admission = try store.reserveStart(
            template, binding: binding, run: run, startIntent: intent,
            expectedPrevious: expectedPrevious,
            initialInputBodyReference: reference)
        let prepared: WorkLaunchStartReservation
        switch admission {
        case .existing(let existing):
            return manifest.withDurableRecord(existing)
        case .reserved(let reservation):
            guard let assembly = reservation.promptAssembly else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            prepared = reservation
            _ = assembly
        case .winner(let reservation):
            let retainedAssembly: WorkLaunchPromptAssembly
            if let selectedPromptAssembly {
                // Exact cold resume selected this assembly from the predecessor's durable
                // crossing. It is already retained and must be carried byte-for-byte; stamping
                // a fresh provenance timestamp would make the new Run attest a different
                // assembly even when its provider bytes and source refs are identical.
                retainedAssembly = selectedPromptAssembly
            } else {
                guard let promptAssemblyResolver else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                let assembly: SystemPromptAssembly
                do {
                    assembly = try await promptAssemblyResolver(
                        template.template.draft, exactBody, intent)
                } catch {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                let promptProvenance = WorkLaunchManifestProvenance(source: "start.prompt.v1")
                do {
                    retainedAssembly = try store.retainPromptAssembly(
                        assembly, authority: .workHost(try store.home.requirePersistedWorkHost()),
                        provenance: promptProvenance)
                } catch {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
            }
            prepared = try store.prepareStart(
                reservation, promptAssembly: retainedAssembly)
        }
        guard let promptAssembly = prepared.promptAssembly else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let record = try store.start(
            template,
            binding: binding,
            run: prepared.run, startIntent: prepared.intent,
            expectedPrevious: prepared.expectedPrevious,
            initialInputBodyReference: prepared.initialInputBodyReference,
            promptAssembly: promptAssembly,
            resumePolicy: policy.resumePolicy)
        return manifest.withDurableRecord(record)
    }

    public func resolve(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef
    ) async throws -> JournalBackedWorkLaunchManifest? {
        guard let template = try store.readTemplate(for: work),
              template.work == work,
              template.workHost == WorkHostRef(work.workHostID) else { return nil }
        // The template's retention key is the durable Create proof.  Resolve must load and
        // verify that keyed retention after restart; a template payload alone is not enough to
        // reconstruct executable launch material.
        let draftDigest = try template.template.draft.contentDigest()
        guard let retained = try store.loadRetainedDraft(for: template.template.retentionKey),
              retained.digest == draftDigest else {
            return nil
        }
        return JournalBackedWorkLaunchManifest(
            bodyDigest: draftDigest,
            configurationDigest: draftDigest,
            launchMetadata: WorkHostLaunchMetadata(
                providerID: template.template.draft.runtime.providerID,
                modelID: template.template.draft.runtime.modelID,
                workspaceID: template.template.draft.configuration.workspaceID,
                runtimeHostKind: template.template.draft.runtime.runtimeVariant),
            template: template,
            hostedConfigurationAsync: {
                guard let resolver = hostedResolver else { return nil }
                return { @Sendable [resolver, store] binding, policy in
                    let identity = WorkLaunchManifestIdentity(
                        work: binding.workBinding.work, session: binding.workBinding.session,
                        sessionAttachment: binding.workBinding.sessionAttachment, run: binding.run)
                    guard let record = try store.read(identity) else {
                        throw WorkServiceProtocolError.sourceIncomplete
                    }
                    return try await resolver(record.manifest, binding, policy)
                }
            }(), retainedDraftDigest: draftDigest,
            retainedRecord: retained,
            requestedConfiguration: template.template.draft.configuration,
            requestedCapabilities: template.template.draft.requestedCapabilities)
    }

    public func resolveStart(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        intent: WorkLaunchStartIntent
    ) async throws -> JournalBackedWorkLaunchManifest? {
        guard let base = try await resolve(
            work: work, session: session, sessionAttachment: sessionAttachment) else {
            return nil
        }
        let binding = WorkBinding(
            session: session, work: work, workHost: WorkHostRef(work.workHostID),
            sessionAttachment: sessionAttachment)
        let current = try store.readCurrentSelection(for: binding)
        if let record = current?.record,
           record.manifest.startIntent == intent,
           record.manifest.identity.work == work,
           record.manifest.identity.session == session,
           record.manifest.identity.sessionAttachment == sessionAttachment {
            return base.withDurableRecord(record)
        }
        // Historical duplicates use the intent index, never the Work-level current pointer. This
        // preserves Run 1's canonical receipt after a later Run 2 replacement without moving
        // current-by-binding backwards.
        if let historical = try store.readStart(for: binding, intent: intent) {
            return base.withDurableRecord(historical)
        }
        // A crash can leave an exact Run-bound payload and identity pointer published while the
        // Work-level selection still names the prior Run. Return the exact pending record as a
        // recovery candidate, but do not repair here: this method is also used by a duplicate
        // Start receipt after later Runs exist. ``bindStart`` performs the strict repair only on
        // the no-command, admission path while its per-Work gate is held.
        let pending = try store.readPendingStart(for: binding, intent: intent)
        guard let pending else { return nil }
        guard pending.manifest.startIntent == intent,
              pending.manifest.identity.work == work,
              pending.manifest.identity.session == session,
              pending.manifest.identity.sessionAttachment == sessionAttachment else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return base.withDurableRecord(pending)
    }

    public func currentSelection(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef
    ) async throws -> WorkLaunchManifestRecord? {
        let binding = WorkBinding(
            session: session, work: work, workHost: WorkHostRef(work.workHostID),
            sessionAttachment: sessionAttachment)
        return try store.readCurrentSelection(for: binding)?.record
    }

    public func hasPendingStart(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef
    ) async throws -> Bool {
        let binding = WorkBinding(
            session: session, work: work, workHost: WorkHostRef(work.workHostID),
            sessionAttachment: sessionAttachment)
        return try store.hasPendingStart(for: binding)
    }

    public func mayRepairPendingStart(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        intent: WorkLaunchStartIntent,
        currentSelection: WorkLaunchBindingSelection?
    ) async throws -> Bool {
        let binding = WorkBinding(
            session: session, work: work, workHost: WorkHostRef(work.workHostID),
            sessionAttachment: sessionAttachment)
        return try store.mayRepairPendingStart(
            for: binding, intent: intent, currentSelection: currentSelection)
    }

    public func canReconstruct(
        _ manifest: JournalBackedWorkLaunchManifest
    ) async throws -> Bool {
        guard hostedResolver != nil, promptAssemblyResolver != nil,
              let template = manifest.template,
              let reconstructabilityProbe else { return false }
        // The probe is deliberately Run-free: invoking the normal resolver would require
        // selecting a Run and would turn a recovery read into an execution admission.
        return try await reconstructabilityProbe(template)
    }
}

public enum JournalBackedWorkRecoveryDisposition: String, Codable, Hashable, Sendable {
    case idleReconstructable = "idle_reconstructable"
    /// A durable active Run exists, but this service instance has no fresh liveness proof.  It is
    /// intentionally not projected as running.
    case liveUnproven = "live_unproven"
    case recoveryRequired = "recovery_required"
    case historical
    case corrupt
    case unavailable
}

public struct JournalBackedWorkRecoveryEntry: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef?
    public let disposition: JournalBackedWorkRecoveryDisposition
    public let workCursor: JournalCursor?
    public let sessionCursor: JournalCursor?
    public let sourcePresence: WorkHostControlCreationSourcePresence
    public let failure: WorkHostControlCreationSourceVerificationFailure?
    public let hostInstance: WorkHostInstanceRef?
    public let diagnostic: String?

    public init(
        work: WorkRef,
        journal: JournalRef?,
        disposition: JournalBackedWorkRecoveryDisposition,
        workCursor: JournalCursor? = nil,
        sessionCursor: JournalCursor? = nil,
        sourcePresence: WorkHostControlCreationSourcePresence = .notObserved,
        failure: WorkHostControlCreationSourceVerificationFailure? = nil,
        hostInstance: WorkHostInstanceRef? = nil,
        diagnostic: String? = nil
    ) {
        self.work = work
        self.journal = journal
        self.disposition = disposition
        self.workCursor = workCursor
        self.sessionCursor = sessionCursor
        self.sourcePresence = sourcePresence
        self.failure = failure
        self.hostInstance = hostInstance
        self.diagnostic = diagnostic.map { String($0.prefix(WorkServiceBounds.maxDiagnosticCharacters)) }
    }
}

/// A workspace catalog is host-local I/O, not Work-service state.  Keep the potentially blocking
/// provider outside the service actor and share one in-flight probe between callers.  A timeout
/// only releases the caller: an underlying synchronous filesystem/network call cannot be safely
/// cancelled, so its single task remains fenced until it returns.  That is intentional -- a hung
/// provider can make handshakes fail closed, but cannot grow one unbounded task per request.
private actor BoundedWorkspaceCatalogProbe {
    enum ReadResult: Sendable {
        case success(WorkHostWorkspaceCatalog)
        case unavailable
        case timedOut
        case cancelled
    }

    private enum ProbeResult: Sendable {
        case success(WorkHostWorkspaceCatalog)
        case unavailable
    }

    private struct ActiveProbe {
        let id: UUID
        let task: Task<ProbeResult, Never>
    }

    private struct Waiter {
        let probeID: UUID
        let continuation: CheckedContinuation<ReadResult, Never>
        let timeoutTask: Task<Void, Never>
    }

    private let provider: WorkHostWorkspaceCatalogProvider
    private let timeoutNanoseconds: UInt64
    private let maximumWaiters: Int
    private var activeProbe: ActiveProbe?
    private var waiters: [UUID: Waiter] = [:]

    init(
        provider: @escaping WorkHostWorkspaceCatalogProvider,
        timeoutNanoseconds: UInt64,
        maximumWaiters: Int = 16
    ) {
        self.provider = provider
        // Keep a caller-provided test timeout useful while preventing an accidental zero timeout
        // or an effectively unbounded service handshake in production.
        self.timeoutNanoseconds = min(max(timeoutNanoseconds, 1), 30_000_000_000)
        self.maximumWaiters = max(1, maximumWaiters)
    }

    func read() async -> ReadResult {
        if Task.isCancelled { return .cancelled }
        let waiterID = UUID()
        let probeID = beginProbeIfNeeded()
        guard waiters.count < maximumWaiters else { return .unavailable }

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                install(
                    waiterID: waiterID,
                    probeID: probeID,
                    continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        })
    }

    private func beginProbeIfNeeded() -> UUID {
        if let activeProbe { return activeProbe.id }
        let id = UUID()
        let provider = self.provider
        let task = Task.detached(priority: .utility) { () -> ProbeResult in
            do {
                return .success(try await provider())
            } catch {
                return .unavailable
            }
        }
        activeProbe = ActiveProbe(id: id, task: task)
        Task { [weak self] in
            let result = await task.value
            await self?.complete(probeID: id, result: result)
        }
        return id
    }

    private func install(
        waiterID: UUID,
        probeID: UUID,
        continuation: CheckedContinuation<ReadResult, Never>
    ) {
        guard activeProbe?.id == probeID else {
            continuation.resume(returning: .unavailable)
            return
        }
        if Task.isCancelled {
            continuation.resume(returning: .cancelled)
            return
        }
        let timeoutNanoseconds = self.timeoutNanoseconds
        let timeoutTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.timeout(waiterID: waiterID, probeID: probeID)
        }
        waiters[waiterID] = Waiter(
            probeID: probeID, continuation: continuation, timeoutTask: timeoutTask)
    }

    private func complete(probeID: UUID, result: ProbeResult) {
        guard activeProbe?.id == probeID else { return }
        activeProbe = nil
        let matching = waiters.filter { $0.value.probeID == probeID }
        for (waiterID, waiter) in matching {
            waiters.removeValue(forKey: waiterID)
            waiter.timeoutTask.cancel()
            switch result {
            case .success(let catalog): waiter.continuation.resume(returning: .success(catalog))
            case .unavailable: waiter.continuation.resume(returning: .unavailable)
            }
        }
    }

    private func timeout(waiterID: UUID, probeID: UUID) {
        guard let waiter = waiters[waiterID], waiter.probeID == probeID else { return }
        waiters.removeValue(forKey: waiterID)
        waiter.continuation.resume(returning: .timedOut)
    }

    private func cancel(waiterID: UUID) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: .cancelled)
    }
}

// MARK: - Journal-backed composition

/// Read-path counters exposed for diagnostics and production tests. `bytesScanned` counts bytes
/// handed to the incremental JSONL reader, not metadata probes or bytes served from the cache.
/// These counters are observations only; they never participate in canonical identity or
/// readiness decisions.
public struct JournalBackedWorkServiceReadMetrics: Codable, Hashable, Sendable {
    public let readCalls: Int
    public let cacheHits: Int
    public let rebuilds: Int
    public let incrementalReads: Int
    public let invalidations: Int
    public let bytesScanned: Int
    public let recordsApplied: Int

    public init(
        readCalls: Int = 0,
        cacheHits: Int = 0,
        rebuilds: Int = 0,
        incrementalReads: Int = 0,
        invalidations: Int = 0,
        bytesScanned: Int = 0,
        recordsApplied: Int = 0
    ) {
        self.readCalls = readCalls
        self.cacheHits = cacheHits
        self.rebuilds = rebuilds
        self.incrementalReads = incrementalReads
        self.invalidations = invalidations
        self.bytesScanned = bytesScanned
        self.recordsApplied = recordsApplied
    }
}

/// Successful conversation-history costs are deliberately separate from forward journal reads.
/// `calls` also counts attempts that fail, but the remaining counters are published only when a
/// reader returns its metrics. A bounded metadata lookup or selected canonical-line read must
/// never inflate `recordsApplied` and hide an accidental full Session reducer replay.
public struct JournalBackedWorkServiceHistoryMetrics: Codable, Hashable, Sendable {
    public let calls: Int
    public let indexBuilds: Int
    public let cacheHits: Int
    public let rebuilds: Int
    public let decodedPhysicalEvents: Int
    public let sourceBytesScanned: Int
    public let peakBufferBytes: Int
    public let metadataLookups: Int
    public let parentLinks: Int
    public let canonicalRangeReads: Int
    public let canonicalRangeBytes: Int
    public let mapObjectsRead: Int
    public let mapBytesRead: Int

    public init(
        calls: Int = 0, indexBuilds: Int = 0, cacheHits: Int = 0,
        rebuilds: Int = 0, decodedPhysicalEvents: Int = 0,
        sourceBytesScanned: Int = 0, peakBufferBytes: Int = 0,
        metadataLookups: Int = 0, parentLinks: Int = 0,
        canonicalRangeReads: Int = 0, canonicalRangeBytes: Int = 0,
        mapObjectsRead: Int = 0, mapBytesRead: Int = 0
    ) {
        self.calls = max(0, calls)
        self.indexBuilds = max(0, indexBuilds)
        self.cacheHits = max(0, cacheHits)
        self.rebuilds = max(0, rebuilds)
        self.decodedPhysicalEvents = max(0, decodedPhysicalEvents)
        self.sourceBytesScanned = max(0, sourceBytesScanned)
        self.peakBufferBytes = max(0, peakBufferBytes)
        self.metadataLookups = max(0, metadataLookups)
        self.parentLinks = max(0, parentLinks)
        self.canonicalRangeReads = max(0, canonicalRangeReads)
        self.canonicalRangeBytes = max(0, canonicalRangeBytes)
        self.mapObjectsRead = max(0, mapObjectsRead)
        self.mapBytesRead = max(0, mapBytesRead)
    }
}

/// Resolves the immutable canonical admission evidence used by public command receipts.
/// A Hosted actor saying it admitted work is not enough: the exact client-qualified command
/// envelope must be present in the reduced Work journal, with an addressable event and host
/// sequence. This intentionally has no fallback to the current Work tip.
enum JournalBackedWorkServiceCommandEvidence {
    struct Result: Equatable, Sendable {
        let cursor: JournalCursor
        let hostSequence: Int
    }

    static func resolve(
        snapshot: WorkSnapshot,
        journal: JournalRef,
        request: WorkServiceCommandRequest,
        client: ClientRef
    ) throws -> Result {
        let expected = WorkServiceCommandLedgerIdentity.command(
            from: request.command, client: client)
        guard snapshot.journal == journal,
              journal == request.journal,
              snapshot.structuralIntegrityValid,
              snapshot.semanticProjectionValid,
              snapshot.quarantinedEvents.isEmpty,
              let recorded = snapshot.commands[expected.commandID],
              recorded.command == expected,
              let acceptance = recorded.acceptanceEventRef,
              acceptance.journal == journal,
              let sequence = snapshot.eventSequences[acceptance.eventID],
              sequence > request.causalWorkCursor.sequence,
              recorded.acceptanceHostSequence > 0 else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return Result(
            cursor: JournalCursor(
                journal: journal, eventID: acceptance.eventID, sequence: sequence),
            hostSequence: recorded.acceptanceHostSequence)
    }
}

/// The bounded production composition of WorkServiceProtocol.
///
/// The control journal owns client relationships and control cursors.  RunJournalBundle owns
/// Session/Work source truth, while WorkHostRegistry owns the live HostedInHouseWork actor.  No
/// client reference is used as actor ownership, so detaching the final GUI leaves Work alive.
public actor JournalBackedWorkService: WorkServiceClient {
    public typealias LaunchManifestStore = JournalBackedWorkServiceLaunchManifestStore

    private static let maximumArtifactBodyBytes = 8 * 1024 * 1024

    public let home: AgentHome
    public let host: WorkHostRef
    public let hostInstance: WorkHostInstanceRef
    public let controlJournal: WorkHostControlJournal
    public let registry: WorkHostRegistry

    private let actor: TimelineActor
    private let authorizer: any WorkServiceAuthorizer
    private let manifestStore: (any JournalBackedWorkServiceLaunchManifestStore)?
    /// Read the host-owned workspace registry at each handshake. Keeping a provider rather than
    /// a catalog snapshot means a GUI that reconnects observes durable registry mutations made by
    /// another local admin process, while launch resolution still revalidates the selected ID.
    private let workspaceCatalogProbe: BoundedWorkspaceCatalogProbe
    private let bounds: WorkHostRegistryBounds
    /// Testable bound for raw live envelopes. Production keeps the one-million-record ceiling;
    /// crossing it changes storage strategy, never source availability.
    private let canonicalResidentRecordLimit: Int
    private var loaded = false
    private var manifests: [WorkRef: JournalBackedWorkLaunchManifest] = [:]

    // MARK: Incremental canonical source cache

    /// The cache is actor-owned and keyed by both the typed journal authority and the exact
    /// expected path. A path by itself is not an identity, and a JournalRef by itself cannot
    /// distinguish two host-private files accidentally supplied for one logical journal.
    private struct JournalCacheKey: Hashable, Sendable {
        let journal: JournalRef
        let path: String
    }

    private struct JournalFileIdentity: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
    }

    private struct JournalFileFingerprint: Equatable, Sendable {
        let identity: JournalFileIdentity
        let byteCount: Int
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let lastByte: UInt8?
        /// Hash of bounded prefix/suffix evidence. It is not a complete file digest; it prevents
        /// the common same-inode rewrite+append case from reusing a stale reducer prefix.
        let prefixEvidence: String
    }

    /// A sparse, byte-addressable checkpoint used when a journal is larger than the resident
    /// decoded-event cache.  It deliberately keeps only identity and offsets; the event envelope
    /// is reread from the already-authorized journal when a bounded page needs it.
    private struct JournalRecordIndex: Sendable {
        let eventID: String
        let sequence: Int
        let byteStart: Int
        let byteEnd: Int
        let previousEventID: String?
        /// Digest immediately before this record. Keeping both sides of each sparse anchor lets a
        /// page prove a checkpoint at an arbitrary cursor while rereading only the bounded anchor
        /// suffix, rather than retaining one digest per historical event.
        let prefixDigestBefore: String
        let prefixDigest: String
    }

    private struct JournalReadCacheEntry: Sendable {
        let fingerprint: JournalFileFingerprint
        let result: TimelineJournalReadResult
        /// Bounded canonical genesis prefix retained even when `result.records` is nonresident.
        let prefixRecords: [TimelineJournalRecord]
        let workSnapshot: WorkSnapshot?
        let sessionSnapshot: SessionSnapshot?
        let sequenceToIndex: [Int: Int]
        let sparseIndex: [JournalRecordIndex]
        let recordCount: Int
        let lastRecord: TimelineJournalRecord?
        let penultimateRecord: TimelineJournalRecord?
        let terminalLineDigest: String?
        let prefixSeed: String
        let prefixDigest: String
        let nextSequence: Int
        let previousEventID: String?
        let isFullyResident: Bool
        let latestRunStarted: RunRef?
        let latestRunFinished: RunRef?
        let latestRunFinishedEvent: TimelineEvent?
        let runStartedIDs: Set<String>
        let runFinishedIDs: Set<String>
        let runFinishedExists: Bool
        let artifactDescriptors: [WorkServiceArtifactDescriptor]
        let artifactDescriptorCount: Int
        let artifactDescriptorsComplete: Bool
        let artifactDescriptorIdentityConflict: Bool
        let bodyReferences: Set<TimelineBodyReference>
        let bodyReferenceCount: Int
        let bodyReferencesComplete: Bool
    }

    private enum JournalReadLimits {
        static let chunkBytes = 256 * 1024
        /// Cache admission is bounded independently of journal availability.  Sources larger than
        /// this retain reducer state plus a sparse offset index and continue to be readable via
        /// bounded page scans; the value is never used as a source-size validity limit.
        static let maximumResidentBytes = 256 * 1024 * 1024
        static let maximumResidentRecords = 1_000_000
        static let sparseStride = 256
        static let maximumSparseEntries = 4_000_000
        static let maximumCachedArtifacts = WorkServiceBounds.maxArtifactsPerWork
        static let maximumCachedBodyReferences = 65_536
    }

    private var journalCache: [JournalCacheKey: JournalReadCacheEntry] = [:]
    private var readMetrics = JournalBackedWorkServiceReadMetrics()
    private var historyMetrics = JournalBackedWorkServiceHistoryMetrics()
    /// Internal deterministic race seam. Production leaves this nil; self-tests use it to
    /// suspend after the first Session read and prove the second authority pass observes a
    /// concurrent relationship transition.
    private var historyAfterInitialReadHook: (@Sendable () async -> Void)?
    /// A durable reservation prevents two processes from minting Runs, while this in-process
    /// task map prevents an actor re-entrant duplicate from observing the winner's pre-assembly
    /// reservation and incorrectly reporting ``sourceIncomplete``.  The key is the complete
    /// client-qualified Start intent; conflicting intents never join this task.
    private struct StartAdmissionKey: Hashable, Sendable {
        let work: WorkRef
        let binding: WorkBinding
        let intent: WorkLaunchStartIntent
    }
    private struct StartActorAdmission: Sendable {
        let entry: WorkHostRegistryLiveEntry
        let ownsTask: Bool
    }
    private var startsInProgress: [StartAdmissionKey: Task<WorkHostRegistryLiveEntry, Error>] = [:]

    public init(
        home: AgentHome,
        workHost: WorkHostRef? = nil,
        instanceID: String = "instance-" + UUID().uuidString.lowercased(),
        startIdentity: String = "start-" + UUID().uuidString.lowercased(),
        actor: TimelineActor = TimelineActor(actorID: "work-service", kind: "work-service"),
        authorizer: any WorkServiceAuthorizer,
        manifestStore: (any JournalBackedWorkServiceLaunchManifestStore)? = nil,
        bounds: WorkHostRegistryBounds = .default,
        workspaceCatalogProvider: @escaping WorkHostWorkspaceCatalogProvider = { .empty },
        workspaceCatalogTimeoutNanoseconds: UInt64 = 500_000_000,
        canonicalResidentRecordLimit: Int = 1_000_000,
        creationIdentityMinter: @escaping @Sendable () -> WorkHostControlMintedIdentity = {
            WorkHostControlMintedIdentity(
                workID: "work-" + UUID().uuidString.lowercased(),
                sessionID: "session-" + UUID().uuidString.lowercased(),
                sessionAttachmentID: "session-attachment-" + UUID().uuidString.lowercased())
        }
    ) throws {
        let persistedHost = try home.requirePersistedWorkHost()
        if let workHost, workHost != persistedHost {
            throw WorkServiceProtocolError.hostUnavailable(workHost)
        }
        self.home = home
        self.host = persistedHost
        self.actor = actor
        self.authorizer = authorizer
        self.manifestStore = manifestStore
        self.workspaceCatalogProbe = BoundedWorkspaceCatalogProbe(
            provider: workspaceCatalogProvider,
            timeoutNanoseconds: workspaceCatalogTimeoutNanoseconds)
        self.bounds = bounds
        self.canonicalResidentRecordLimit = max(
            1, min(canonicalResidentRecordLimit, JournalReadLimits.maximumResidentRecords))
        let instance = WorkHostInstanceRef(
            host: persistedHost, instanceID: instanceID, startIdentity: startIdentity)
        self.hostInstance = instance
        self.registry = WorkHostRegistry(hostInstance: instance, bounds: bounds)
        let controlURL = home.timelineV2WorkHostControlJournalURL(persistedHost)
        if FileManager.default.fileExists(atPath: controlURL.path) {
            self.controlJournal = try WorkHostControlJournal.reopenExisting(
                home: home, workHost: persistedHost, actor: actor,
                creationIdentityMinter: creationIdentityMinter)
        } else {
            self.controlJournal = try WorkHostControlJournal.createFresh(
                home: home, workHost: persistedHost, actor: actor,
                creationIdentityMinter: creationIdentityMinter)
        }
    }

    /// Return source-reader instrumentation without exposing cache contents or filesystem paths.
    /// A caller may use the delta between two samples to verify that a steady-state poll consumed
    /// only an append suffix rather than rereading the complete journal.
    public func journalReadMetrics() -> JournalBackedWorkServiceReadMetrics {
        readMetrics
    }

    /// Return conversation-history instrumentation without combining it with the forward
    /// journal-reader counters. Successful full Session scans remain visible instead of
    /// disappearing inside a normal descriptor or polling read; a failed scan currently reports
    /// its attempted call but cannot publish partial byte/event counters.
    public func historyReadMetrics() -> JournalBackedWorkServiceHistoryMetrics {
        historyMetrics
    }

    func installHistoryAfterInitialReadHook(
        _ hook: (@Sendable () async -> Void)?
    ) {
        historyAfterInitialReadHook = hook
    }

    public func handshake(_ request: WorkServiceHandshakeRequest) async throws
        -> WorkServiceHandshakeResponse {
        try validateClient(request.client)
        let catalog: WorkHostWorkspaceCatalog
        switch await workspaceCatalogProbe.read() {
        case .success(let freshCatalog):
            catalog = freshCatalog
        case .unavailable, .timedOut, .cancelled:
            // This is deliberately performed before both accepted and rejected responses. A
            // malformed/inaccessible registry must never be hidden by a stale or empty snapshot.
            let cursor = try await currentControlCursor()
            return WorkServiceHandshakeResponse(
                accepted: false, negotiatedVersion: nil,
                supportedRange: WorkServiceProtocol.minimumSupportedVersion
                    ... WorkServiceProtocol.maximumSupportedVersion,
                host: host, hostInstance: hostInstance,
                controlJournal: cursor.journal, controlCursor: cursor,
                capabilities: [], workspaceCatalog: .empty,
                diagnostic: "workspace catalog unavailable")
        }
        guard request.protocolVersion >= WorkServiceProtocol.minimumSupportedVersion,
              request.protocolVersion <= WorkServiceProtocol.maximumSupportedVersion else {
            return WorkServiceHandshakeResponse(
                accepted: false, negotiatedVersion: nil,
                supportedRange: WorkServiceProtocol.minimumSupportedVersion ...
                    WorkServiceProtocol.maximumSupportedVersion,
                host: host, hostInstance: hostInstance,
                controlJournal: try await currentControlCursor().journal,
                controlCursor: try await currentControlCursor(),
                capabilities: [], workspaceCatalog: catalog,
                diagnostic: "unsupported Work service protocol version")
        }
        let cursor = try await currentControlCursor()
        return WorkServiceHandshakeResponse(
            accepted: true, negotiatedVersion: WorkServiceProtocol.currentVersion,
            supportedRange: WorkServiceProtocol.minimumSupportedVersion ...
                WorkServiceProtocol.maximumSupportedVersion,
            host: host, hostInstance: hostInstance,
            controlJournal: cursor.journal, controlCursor: cursor,
            capabilities: Set(WorkServiceCapability.allCases),
            workspaceCatalog: catalog)
    }

    public func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage {
        try await ensureLoaded()
        try validateClient(request.client)
        let listAuthorization = authorizer.authorization(
            for: request.client, requested: [.observe])
        guard listAuthorization.allows(.observe) else {
            throw WorkServiceProtocolError.capabilityDenied(.observe)
        }
        guard request.pageSize > 0, request.pageSize <= WorkServiceBounds.maxPageSize else {
            throw WorkServiceProtocolError.invalidRequest("page size is outside the protocol bound")
        }
        let all = try await allWorkRefs()
        let offset = try parsePageToken(request.pageToken, total: all.count)
        let selected = Array(all.dropFirst(offset).prefix(request.pageSize))
        var descriptors: [WorkServiceWorkDescriptor] = []
        var unavailableDescriptorCount = 0
        for work in selected {
            do {
                descriptors.append(try await descriptor(for: work, client: request.client))
            } catch {
                // One corrupt or unavailable Work must not make a bounded inventory page
                // unprogressable. The sorted source page is still consumed, while the typed
                // omission records that this row was deliberately not projected. Do not expose
                // arbitrary source errors in the transport diagnostic.
                unavailableDescriptorCount += 1
            }
        }
        let nextOffset = offset + selected.count
        let omissions: [WorkServiceOmission] = unavailableDescriptorCount == 0 ? [] : [
            WorkServiceOmission(
                category: "work_descriptors", count: unavailableDescriptorCount,
                diagnostic: "one or more Work descriptors were unavailable")
        ]
        return WorkServiceWorkPage(
            works: descriptors,
            nextPageToken: nextOffset < all.count ? String(nextOffset) : nil,
            omissions: omissions)
    }

    public func describeWork(_ request: WorkServiceDescribeRequest) async throws -> WorkServiceWorkDescriptor {
        try await ensureLoaded()
        try validateClient(request.client)
        _ = try await requireCanonical(work: request.work, journal: request.journal)
        guard try await clientHasObserve(work: request.work, client: request.client) else {
            throw WorkServiceProtocolError.capabilityDenied(.observe)
        }
        return try await descriptor(for: request.work, client: request.client)
    }

    public func createWork(_ request: WorkServiceCreateWorkRequest) async throws
        -> WorkServiceCreateWorkResponse {
        try await ensureLoaded()
        try validateClient(request.client)
        guard validConfigurationBounds(request.configuration) else {
            throw WorkServiceProtocolError.invalidRequest("configuration exceeds protocol bounds")
        }
        let auth = authorizer.authorization(
            for: request.client, requested: request.requestedCapabilities)
        guard auth.allows(.observe), auth.allows(.control) else {
            throw WorkServiceProtocolError.capabilityDenied(
                auth.denied.contains(.observe) ? .observe : .control)
        }
        guard let manifestStore else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        // Inspect the durable control key before asking a resolver for launch material. A lost
        // Create response must replay the already-bound template, even if defaults, provider
        // routing, or workspace preferences changed while the process was down.
        let controlBeforeRetain = try await controlSnapshot()
        let priorCreation = controlBeforeRetain.creation(
            client: request.client, commandID: request.commandID)
        let retainedManifest: JournalBackedWorkLaunchManifest?
        let reservation: WorkHostControlCreationReservation
        let priorManifest: JournalBackedWorkLaunchManifest?
        if let priorCreation {
            guard !priorCreation.isConflicted else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            reservation = priorCreation.reservation
            guard reservation.causalControlCursor == request.causalControlCursor else {
                throw WorkServiceProtocolError.invalidRequest(
                    "Create retry does not match its durable causal control cursor")
            }
            let priorBinding = WorkBinding(
                session: reservation.session,
                work: reservation.work,
                workHost: host,
                sessionAttachment: reservation.sessionAttachment)
            let resolved = try await manifestStore.resolve(
                work: reservation.work,
                session: reservation.session,
                sessionAttachment: reservation.sessionAttachment)
            if let resolved {
                if let requested = resolved.requestedConfiguration {
                    guard requested == request.configuration else {
                        throw WorkServiceProtocolError.invalidRequest(
                            "Create retry does not match its durable requested configuration")
                    }
                }
                if let capabilities = resolved.requestedCapabilities {
                    guard capabilities == request.requestedCapabilities else {
                        throw WorkServiceProtocolError.invalidRequest(
                            "Create retry does not match its durable capabilities")
                    }
                }
                guard let template = resolved.template,
                      template.work == priorBinding.work,
                      template.workHost == priorBinding.workHost,
                      resolved.identity == nil,
                      resolved.bodyDigest == reservation.bodyDigest,
                      resolved.configurationDigest == reservation.configurationDigest else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                retainedManifest = nil
                priorManifest = resolved
            } else {
                // A crash after reservation but before template publication can still recover the
                // exact retained draft by the full client/command/cursor/digest proof. It must
                // never rerun the resolver, since ambient defaults may have changed.
                guard priorCreation.registration == nil,
                      let recovered = try await manifestStore.recoverReservation(reservation),
                      recovered.template == nil,
                      recovered.retainedRecord != nil,
                      recovered.bodyDigest == reservation.bodyDigest,
                      recovered.configurationDigest == reservation.configurationDigest else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                if let requested = recovered.requestedConfiguration {
                    guard requested == request.configuration else {
                        throw WorkServiceProtocolError.invalidRequest(
                            "Create retry does not match its durable requested configuration")
                    }
                }
                if let capabilities = recovered.requestedCapabilities {
                    guard capabilities == request.requestedCapabilities else {
                        throw WorkServiceProtocolError.invalidRequest(
                            "Create retry does not match its durable capabilities")
                    }
                }
                retainedManifest = recovered
                priorManifest = nil
            }
        } else {
            // Manifest retention is intentionally before reservation: a control digest without
            // host-private launch material is not a reusable creation proof after restart.
            let retained = try await manifestStore.retain(request)
            try validateManifest(retained)
            let creationRequest = WorkHostControlCreationRequest(
                client: request.client, commandID: request.commandID,
                bodyDigest: retained.bodyDigest,
                configurationDigest: retained.configurationDigest,
                causalControlCursor: request.causalControlCursor)
            retainedManifest = retained
            reservation = try await controlJournal.reserveCreation(creationRequest)
            priorManifest = nil
        }
        let binding = WorkBinding(
            session: reservation.session,
            work: reservation.work,
            workHost: host,
            sessionAttachment: reservation.sessionAttachment)
        // A response retry after registration must resolve the exact identity-bound record. It
        // may not mint a new Run or republish a different manifest merely because the first
        // response was lost. A reservation with no registration is the only crash window where a
        // fresh same-command bind is allowed to repair the incomplete transaction.
        let controlBeforeBind = try await controlSnapshot()
        let priorRegistration = controlBeforeBind.creation(
            client: request.client, commandID: request.commandID)?.registration
        let manifest: JournalBackedWorkLaunchManifest
        if let priorManifest {
            manifest = priorManifest
        } else {
            guard priorRegistration == nil else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            guard let retainedManifest else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            // Create publishes only the Run-free template. A Run is an execution generation and
            // is minted by Start, never by a retry of this control operation.
            manifest = try await manifestStore.bindTemplate(
                retainedManifest, binding: binding)
        }
        try validateManifest(manifest)
        guard let template = manifest.template,
              template.work == binding.work,
              template.workHost == binding.workHost,
              manifest.identity == nil,
              manifest.bodyDigest == reservation.bodyDigest,
              manifest.configurationDigest == reservation.configurationDigest else {
            throw WorkServiceProtocolError.invalidRequest(
                "Create requires an exact Run-free launch template")
        }
        manifests[reservation.work] = manifest
        let registration = try await ensureRegistered(
            reservation: reservation, binding: binding)
        // Create admits an idle Work only. Opening HostedInHouseWork here would append a
        // `run.started` marker before the client has issued Start, making the response depend on
        // whether a provider resolver happened to be available and falsely projecting running.
        // The registry is populated by Start, after an execution generation is explicitly
        // admitted. This also leaves a lost Create response replayable from the idle pair.
        // A fresh verified projection is required immediately before returning a creation
        // response. This closes the journal-write/registration/response crash window.
        let projection = await controlJournal.verifiedCreationProjection(
            client: request.client, commandID: request.commandID)
        guard projection.verification.isVerified,
              projection.projection?.state == .registered,
              projection.projection?.responseIsReconstructable == true,
              let verifiedRegistration = projection.projection?.registration,
              verifiedRegistration == registration else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let attachmentPublication = try await attachForCreate(
            request: request, reservation: reservation,
            registration: verifiedRegistration, authorization: auth)
        let source = try await canonicalSource(
            work: reservation.work, journal: verifiedRegistration.workJournal,
            registration: verifiedRegistration)
        let descriptor = try await descriptor(for: reservation.work, client: request.client)
        let receiptState: WorkServiceCommandReceiptState = priorCreation == nil
            ? .accepted : .duplicate
        return WorkServiceCreateWorkResponse(
            work: descriptor, authorization: auth,
            session: reservation.session, sessionJournal: verifiedRegistration.sessionJournal,
            sessionAttachment: reservation.sessionAttachment,
            attachment: attachmentPublication.attachment,
            workCursor: source.workCursor, sessionCursor: source.sessionCursor,
            controlCursor: attachmentPublication.controlCursor,
            receipt: WorkServiceControlReceipt(
                operation: .createWork, work: reservation.work,
                commandID: request.commandID, state: receiptState,
                host: hostInstance, causalControlCursor: request.causalControlCursor,
                resultingControlCursor: attachmentPublication.controlCursor, authorization: auth,
                outcome: .created))
    }

    public func createSession(_ request: WorkServiceCreateSessionRequest) async throws
        -> WorkServiceCreateSessionResponse {
        try await ensureLoaded()
        try validateClient(request.client)
        let source = try await requireCanonical(work: request.work, journal: request.journal)
        let control = try await controlSnapshot()
        let existing = control.sessionCreation(
            work: request.work, client: request.client, commandID: request.commandID)
        if let existing {
            let same = existing.reservation.workJournal == request.journal
                && existing.reservation.authorizingAttachment == request.attachment
                && existing.reservation.causalControlCursor == request.causalControlCursor
                && existing.reservation.causalWorkCursor == request.causalWorkCursor
                && existing.reservation.requestedCapabilities
                    == request.requestedCapabilities.map { $0.rawValue }.sorted()
            guard same, !existing.isConflicted else {
                throw WorkServiceProtocolError.invalidRequest(
                    "create Session command conflicts with a prior request")
            }
        }
        if let existing, let prior = existing.result {
            // A completed exact retry is a reconstruction, not another publication attempt.
            // The Work may have advanced after the response was lost, so reopening the old
            // source saga would incorrectly require its historical cursor to still be the tail.
            // Re-read and authenticate the referenced Session/Work evidence, then replay the
            // exact recorded transition cursors without consulting mutable authorization state.
            let verifiedAttachments = try await completedSessionAttachments(
                for: request.work, source: source, control: control)
            guard let verified = verifiedAttachments.first(where: {
                $0.attachment == existing.reservation.clientAttachment
                    && $0.session == existing.reservation.session
                    && $0.sessionAttachment == existing.reservation.sessionAttachment
            }) else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            let effective = Set(
                prior.capabilities.compactMap(WorkServiceCapability.init(rawValue:)))
            let authorization = WorkServiceAuthorizationOutcome(
                requested: request.requestedCapabilities, granted: effective,
                denied: request.requestedCapabilities.subtracting(effective),
                diagnostic: effective == request.requestedCapabilities
                    ? nil : "capabilities were limited by the authorizing attachment or Work state")
            // The CreateSession relationship and response authorization are immutable
            // publication evidence, but the client attachment is mutable control state. An
            // exact retry after updateCapabilities must replay the original relationship while
            // returning the attachment's current grant; never let publication capabilities
            // resurrect a grant that the control journal has since reduced.
            let attachment: WorkServiceClientAttachment?
            if let current = control.clientAttachments[existing.reservation.clientAttachment.attachmentID] {
                guard current.attachment == verified.attachment,
                      current.client == verified.client,
                      current.work == verified.work,
                      current.workJournal == verified.workJournal,
                      current.session == verified.session,
                      current.sessionJournal == verified.sessionJournal,
                      current.sessionAttachment == verified.sessionAttachment,
                      current.attachedEvent == verified.attachedEvent else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                // A detached historical row remains valid publication evidence but cannot be
                // returned as a live authority. Preserve the minted attachment identity and
                // immutable publication grant; the descriptor deliberately omits this row, so a
                // client can correlate the duplicate without adopting it as current authority.
                attachment = current.isAttached
                    ? try clientAttachment(current, control: control)
                    : try clientAttachment(
                        verified, control: control, authorizationOverride: authorization)
            } else {
                // A compacted/omitted current row is likewise historical evidence only.
                attachment = try clientAttachment(
                    verified, control: control, authorizationOverride: authorization)
            }
            let relationship = WorkServiceSessionAttachmentDescriptor(
                session: existing.reservation.session,
                sessionJournal: existing.reservation.sessionJournal,
                sessionAttachment: existing.reservation.sessionAttachment,
                publication: prior.publication == "terminal_reference"
                    ? .terminalReference : .mirrored,
                causalSessionCursor: prior.causalSessionCursor,
                sessionCursor: prior.sessionCursor,
                causalWorkCursor: prior.causalWorkCursor,
                resultingWorkCursor: prior.resultingWorkCursor,
                capabilities: effective)
            let descriptor = try await descriptor(for: request.work, client: request.client)
            let receipt = controlReceipt(
                .createSession, work: request.work, commandID: request.commandID,
                state: .duplicate, causal: request.causalControlCursor,
                resulting: prior.resultingControlCursor,
                authorization: authorization, outcome: .sessionCreated)
            return WorkServiceCreateSessionResponse(
                work: descriptor, session: existing.reservation.session,
                sessionJournal: existing.reservation.sessionJournal,
                sessionAttachment: existing.reservation.sessionAttachment,
                attachment: attachment, relationship: relationship,
                workCursor: prior.resultingWorkCursor,
                sessionCursor: prior.sessionCursor,
                controlCursor: prior.resultingControlCursor,
                authorization: authorization, commandID: request.commandID,
                state: .duplicate, host: hostInstance,
                causalControlCursor: request.causalControlCursor,
                causalWorkCursor: request.causalWorkCursor, receipt: receipt,
                diagnostic: "idempotent duplicate")
        }
        let authorizing = control.clientAttachments[request.attachment.attachmentID]
        let operationAuthorization = authorizer.authorization(
            for: request.client, requested: [.createSession])
        let attachedClientCount = control.clientAttachments.values.filter {
            $0.work == request.work && $0.workJournal == request.journal && $0.isAttached
        }.count
        guard existing != nil || attachedClientCount < WorkServiceBounds.maxAttachmentsPerWork else {
            throw WorkServiceProtocolError.invalidRequest(
                "Work client attachment bound reached")
        }
        let terminal = source.workState.lifecycle != .active
        let semanticCapabilities: Set<WorkServiceCapability> = terminal
            ? [.observe] : Set(WorkServiceCapability.allCases).subtracting([.createSession])
        let authorization: WorkServiceAuthorizationOutcome
        let effective: Set<WorkServiceCapability>
        if let prior = existing?.result {
            // An exact retry replays the capabilities that were durably published. Current
            // attachment/auth state may have changed after the original response; rechecking it
            // here would turn a lost response into a false denial.
            effective = Set(prior.capabilities.compactMap(WorkServiceCapability.init(rawValue:)))
            authorization = WorkServiceAuthorizationOutcome(
                requested: request.requestedCapabilities, granted: effective,
                denied: request.requestedCapabilities.subtracting(effective),
                diagnostic: effective == request.requestedCapabilities
                    ? nil : "capabilities were limited by the authorizing attachment or Work state")
        } else {
            guard let authorizing,
                  authorizing.work == request.work,
                  authorizing.workJournal == request.journal,
                  authorizing.client == request.client,
                  authorizing.isAttached,
                  operationAuthorization.allows(.createSession),
                  authorizing.capabilities.contains(WorkServiceCapability.createSession.rawValue)
            else {
                throw control.clientAttachments[request.attachment.attachmentID] == nil
                    ? WorkServiceProtocolError.attachmentNotFound
                    : WorkServiceProtocolError.capabilityDenied(.createSession)
            }
            let principal = authorizer.authorization(
                for: request.client, requested: request.requestedCapabilities)
            let authorizingCapabilities = Set(
                authorizing.capabilities.compactMap(WorkServiceCapability.init(rawValue:)))
            effective = request.requestedCapabilities
                .intersection(principal.granted)
                .intersection(authorizingCapabilities)
                .intersection(semanticCapabilities)
            authorization = WorkServiceAuthorizationOutcome(
                requested: request.requestedCapabilities, granted: effective,
                denied: request.requestedCapabilities.subtracting(effective),
                diagnostic: effective == request.requestedCapabilities
                    ? nil : "capabilities were limited by the authorizing attachment or Work state")
        }
        let controlCursor = try await currentControlCursor()
        guard existing != nil || request.causalControlCursor == controlCursor else {
            throw WorkServiceProtocolError.staleCursor(
                expected: request.causalControlCursor, actual: controlCursor)
        }
        guard existing != nil || request.causalWorkCursor == source.workCursor else {
            throw WorkServiceProtocolError.staleCursor(
                expected: request.causalWorkCursor, actual: source.workCursor)
        }
        let terminalEvent: EventRef? = terminal
            ? source.workCache.lastRecord.map {
                EventRef(journal: source.workJournal, eventID: $0.event.eventID)
            } : nil
        if terminal {
            guard source.workState.activeRun == nil,
                  let last = source.workCache.lastRecord,
                  [TimelineEventType.workCompleted, TimelineEventType.workDestroyed,
                   TimelineEventType.workFailed].contains(last.event.type) else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            guard request.requestedCapabilities.contains(.observe),
                  effective == [.observe] else {
                throw WorkServiceProtocolError.capabilityDenied(.observe)
            }
        }
        var relationshipIDs = Set(source.workState.sessionAttachments.keys)
        relationshipIDs.formUnion(control.sessionCreations.values.compactMap { creation in
            guard creation.reservation.work == request.work, creation.result != nil else {
                return nil
            }
            return creation.reservation.sessionAttachment.attachmentID
        })
        guard existing != nil || relationshipIDs.count < WorkServiceBounds.maxSessionAttachmentsPerWork else {
            throw WorkServiceProtocolError.invalidRequest(
                "Work Session attachment bound reached")
        }

        // A durable reservation is the minting boundary. On an exact retry all identities below
        // come from that reservation; no random value is generated before the control journal
        // has admitted the operation.
        let reservation: WorkHostControlSessionCreationRequest
        if let existing {
            reservation = existing.reservation
        } else {
            let identities = try await mintSessionPublicationIdentities(work: request.work)
            let sessionJournal = JournalRef.session(
                identities.session, journalID: "session",
                authority: TimelineAuthorityRef(host.workHostID))
            let command = CommandRef(
                commandID: request.commandID, client: request.client,
                sessionAttachment: nil,
                causalCursor: request.causalControlCursor)
            reservation = WorkHostControlSessionCreationRequest(
                work: request.work, workJournal: request.journal,
                authorizingAttachment: request.attachment, client: request.client,
                command: command, causalControlCursor: request.causalControlCursor,
                causalWorkCursor: request.causalWorkCursor,
                requestedCapabilities: request.requestedCapabilities.map { $0.rawValue },
                session: identities.session, sessionJournal: sessionJournal,
                sessionAttachment: identities.sessionAttachment,
                clientAttachment: identities.clientAttachment)
        }
        let requestedPublicationCapabilities = existing?.result?.capabilities
            ?? effective.map { $0.rawValue }
        let publicationHome = home
        let publicationHost = host
        let publicationActorID = actor.actorID
        let publicationActorKind = actor.kind
        let result: WorkHostControlSessionCreationResult
        if let prior = existing?.result {
            // The source verifier is the authority for a completed result. It must still see the
            // exact three Session records and the required Work mirror/reference, but no source
            // append is attempted on retry (the Work may have advanced after publication).
            guard try await completedSessionAttachments(
                for: request.work, source: source, control: control).contains(where: {
                    $0.attachment == reservation.clientAttachment && $0.client == request.client
                }) else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            result = prior
        } else {
            let transaction = try await controlJournal.publishSessionCreation(reservation) {
                [publicationHome, publicationHost, publicationActorID, publicationActorKind,
                 requestedPublicationCapabilities, terminalEvent] reserved in
                try await RunJournalBundle.publishSessionAttachment(
                    home: publicationHome,
                    request: RunJournalBundleSessionPublicationRequest(
                        work: reserved.work, workHost: publicationHost,
                        workJournal: reserved.workJournal, session: reserved.session,
                        sessionJournal: reserved.sessionJournal,
                        sessionAttachment: reserved.sessionAttachment, client: reserved.client,
                        command: CommandRef(
                            commandID: reserved.command.commandID, client: reserved.client,
                            sessionAttachment: reserved.sessionAttachment,
                            causalCursor: reserved.causalWorkCursor),
                        capabilities: requestedPublicationCapabilities,
                        causalWorkCursor: reserved.causalWorkCursor,
                        terminalEvent: terminalEvent),
                    actorID: publicationActorID, actorKind: publicationActorKind)
            }
            result = transaction.result
        }
        // The owner returns the completion commit cursor captured while its mutation gate was
        // still held. A fresh read here could include an unrelated control mutation that raced
        // after completion and would make the accepted +2 span unverifiable.
        let resultControlCursor = result.resultingControlCursor
        let updatedControl = try await controlSnapshot()
        let attachment = try completedSessionClientAttachment(
            reservation: reservation, result: result, control: updatedControl)
        let relationship = WorkServiceSessionAttachmentDescriptor(
            session: reservation.session, sessionJournal: reservation.sessionJournal,
            sessionAttachment: reservation.sessionAttachment,
            publication: result.publication == "terminal_reference"
                ? .terminalReference : .mirrored,
            causalSessionCursor: result.causalSessionCursor,
            sessionCursor: result.sessionCursor,
            causalWorkCursor: result.causalWorkCursor,
            resultingWorkCursor: result.resultingWorkCursor,
            capabilities: Set(result.capabilities.compactMap {
                WorkServiceCapability(rawValue: $0)
            }))
        let descriptor = try await descriptor(for: request.work, client: request.client)
        let receipt = controlReceipt(
            .createSession, work: request.work, commandID: request.commandID,
            state: existing?.result == nil ? .accepted : .duplicate,
            causal: request.causalControlCursor, resulting: resultControlCursor,
            authorization: authorization, outcome: .sessionCreated)
        return WorkServiceCreateSessionResponse(
            work: descriptor, session: reservation.session,
            sessionJournal: reservation.sessionJournal,
            sessionAttachment: reservation.sessionAttachment, attachment: attachment,
            relationship: relationship, workCursor: result.resultingWorkCursor,
            sessionCursor: result.sessionCursor, controlCursor: resultControlCursor,
            authorization: authorization, commandID: request.commandID,
            state: existing?.result == nil ? .accepted : .duplicate,
            host: hostInstance, causalControlCursor: request.causalControlCursor,
            causalWorkCursor: request.causalWorkCursor, receipt: receipt,
            diagnostic: existing?.result == nil ? nil : "idempotent duplicate")
    }

    public func attach(_ request: WorkServiceAttachRequest) async throws -> WorkServiceAttachResponse {
        try await ensureLoaded()
        try validateClient(request.client)
        // Reconcile the durable command before reading source journals or checking the current
        // control cursor. A response can be lost after the control append, and a later mutation
        // (or an unavailable source) must not turn an exact retry into a stale/error result.
        if let prior = try await controlJournal.priorCommand(
            work: request.work, client: request.client, commandID: request.commandID) {
            guard prior.event.type == TimelineEventType.clientAttached,
                  prior.event.work == request.work,
                  prior.event.journal == controlJournal.journal,
                  prior.event.client == request.client,
                  prior.event.clientAttachment != nil,
                  prior.event.command?.commandID == request.commandID,
                  prior.event.command?.causalCursor == request.causalControlCursor,
                  let workJournal: JournalRef = decodeControlPayload(
                      prior.event.payload["work_journal"]),
                  workJournal == request.journal,
                  let capabilities: [String] = decodeControlPayload(
                      prior.event.payload["capabilities"]),
                  let requestedCapabilities: [String] = decodeControlPayload(
                      prior.event.payload["requested_capabilities"]),
                  let command = prior.event.command,
                  let attachmentRef = prior.event.clientAttachment else {
                throw WorkServiceProtocolError.invalidRequest(
                    "client-qualified attach command conflicts with a prior request")
            }
            let sessionJournal: JournalRef? = decodeControlPayload(
                prior.event.payload["session_journal"])
            let identity = WorkHostControlMutationIdentity(
                type: TimelineEventType.clientAttached, work: request.work,
                workJournal: workJournal, attachment: attachmentRef, client: request.client,
                session: prior.event.session, sessionJournal: sessionJournal,
                sessionAttachment: prior.event.sessionAttachment,
                capabilities: capabilities.sorted(),
                requestedCapabilities: requestedCapabilities.sorted(),
                targetJournal: nil, targetCursor: nil,
                causalControlCursor: request.causalControlCursor)
            guard let exact = try await controlJournal.priorMutation(identity, command: command),
                  exact.event.eventID == prior.event.eventID else {
                throw WorkServiceProtocolError.invalidRequest(
                    "client-qualified attach command conflicts with a prior request")
            }
            let suppliedSessionTuple = request.session != nil
                || request.sessionJournal != nil || request.sessionAttachment != nil
            if suppliedSessionTuple {
                guard request.session == prior.event.session,
                      request.sessionJournal == sessionJournal,
                      request.sessionAttachment == prior.event.sessionAttachment else {
                    throw WorkServiceProtocolError.invalidRequest(
                        "client-qualified attach command conflicts with a prior request")
                }
            }
            guard requestedCapabilities == request.requestedCapabilities
                .map(\.rawValue).sorted() else {
                throw WorkServiceProtocolError.invalidRequest(
                    "client-qualified attach command conflicts with a prior request")
            }
            let control = try await controlSnapshot()
            guard let record = control.clientAttachments.values.first(where: {
                $0.attachedEvent == EventRef(journal: prior.event.journal,
                                             eventID: prior.event.eventID)
                    && $0.workJournal == request.journal
            }) else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            let requested = Set(requestedCapabilities.compactMap(WorkServiceCapability.init(rawValue:)))
            let duplicateAuthorization = WorkServiceAuthorizationOutcome(
                requested: requested,
                granted: Set(record.capabilities.compactMap(WorkServiceCapability.init(rawValue:))),
                denied: requested.subtracting(
                    Set(record.capabilities.compactMap(WorkServiceCapability.init(rawValue:)))))
            let attachment = try clientAttachment(
                record, control: control, authorizationOverride: duplicateAuthorization)
            let descriptor = try await descriptor(for: request.work, client: request.client)
            let resulting = prior.commit.cursor
            return WorkServiceAttachResponse(
                work: descriptor, attachment: attachment,
                authorization: attachment.authorization, commandID: request.commandID,
                state: .duplicate, host: hostInstance,
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: resulting,
                receipt: controlReceipt(
                    .attach, work: request.work, commandID: request.commandID,
                    state: .duplicate, causal: request.causalControlCursor,
                    resulting: resulting, authorization: duplicateAuthorization,
                    outcome: .attached))
        }
        let source = try await requireCanonical(work: request.work, journal: request.journal)
        let auth = authorizer.authorization(
            for: request.client, requested: request.requestedCapabilities)
        guard auth.allows(.observe) else {
            throw WorkServiceProtocolError.capabilityDenied(.observe)
        }
        let cursor = try await currentControlCursor()
        guard request.causalControlCursor == cursor else {
            throw WorkServiceProtocolError.staleCursor(expected: request.causalControlCursor, actual: cursor)
        }
        let control = try await controlSnapshot()
        let attachedClientCount = control.clientAttachments.values.filter {
            $0.work == request.work && $0.workJournal == request.journal && $0.isAttached
        }.count
        guard attachedClientCount < WorkServiceBounds.maxAttachmentsPerWork else {
            throw WorkServiceProtocolError.invalidRequest(
                "Work client attachment bound reached")
        }
        let sessionTuple = try await normalizedSessionTuple(
            request.session, request.sessionJournal, request.sessionAttachment, source: source)
        let attachmentRef = try await mintClientAttachment()
        let command = CommandRef(
            commandID: request.commandID, client: request.client,
            // The normalized tuple is the authority for this attachment's Session identity.
            // Keep the command envelope tied to it rather than the source's shorthand field.
            sessionAttachment: sessionTuple.attachment, causalCursor: request.causalControlCursor)
        let attachmentCommit = try await controlJournal.attachClient(
            work: request.work, workJournal: request.journal, attachment: attachmentRef,
            client: request.client, capabilities: Set(auth.granted.map(\.rawValue)),
            requestedCapabilities: Set(request.requestedCapabilities.map(\.rawValue)),
            session: sessionTuple.session, sessionJournal: sessionTuple.journal,
            sessionAttachment: sessionTuple.attachment, command: command,
            causalControlCursor: request.causalControlCursor)
        let resulting = attachmentCommit.cursor
        let descriptor = try await descriptor(for: request.work, client: request.client)
        let updatedControl = try await controlSnapshot()
        guard let record = updatedControl.clientAttachments[attachmentRef.attachmentID] else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let attachment = try clientAttachment(record, control: updatedControl)
        return WorkServiceAttachResponse(
            work: descriptor, attachment: attachment, authorization: auth,
            commandID: request.commandID, state: .accepted, host: hostInstance,
            causalControlCursor: request.causalControlCursor, resultingControlCursor: resulting,
            receipt: controlReceipt(.attach, work: request.work, commandID: request.commandID,
                                    state: .accepted, causal: request.causalControlCursor,
                                    resulting: resulting, authorization: auth,
                                    outcome: .attached))
    }

    public func detach(_ request: WorkServiceDetachRequest) async throws -> WorkServiceDetachResponse {
        try await ensureLoaded()
        try validateClient(request.client)
        if let prior = try await controlJournal.priorCommand(
            work: request.work, client: request.client, commandID: request.commandID) {
            guard prior.event.type == TimelineEventType.clientDetached,
                  prior.event.work == request.work,
                  prior.event.journal == controlJournal.journal,
                  prior.event.client == request.client,
                  prior.event.clientAttachment == request.attachment,
                  prior.event.command?.commandID == request.commandID,
                  prior.event.command?.causalCursor == request.causalControlCursor,
                  let workJournal: JournalRef = decodeControlPayload(
                      prior.event.payload["work_journal"]),
                  workJournal == request.journal,
                  let command = prior.event.command else {
                throw WorkServiceProtocolError.invalidRequest(
                    "client-qualified detach command conflicts with a prior request")
            }
            let sessionJournal: JournalRef? = decodeControlPayload(
                prior.event.payload["session_journal"])
            let identity = WorkHostControlMutationIdentity(
                type: TimelineEventType.clientDetached, work: request.work,
                workJournal: workJournal, attachment: request.attachment,
                client: request.client, session: prior.event.session,
                sessionJournal: sessionJournal,
                sessionAttachment: prior.event.sessionAttachment,
                capabilities: nil, requestedCapabilities: nil,
                targetJournal: nil, targetCursor: nil,
                causalControlCursor: request.causalControlCursor)
            guard let exact = try await controlJournal.priorMutation(identity, command: command),
                  exact.event.eventID == prior.event.eventID else {
                throw WorkServiceProtocolError.invalidRequest(
                    "client-qualified detach command conflicts with a prior request")
            }
            let control = try await controlSnapshot()
            guard let current = control.clientAttachments[request.attachment.attachmentID],
                  current.client == request.client, current.work == request.work,
                  current.workJournal == request.journal else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            let resulting = prior.commit.cursor
            let authorization = authorization(current)
            let receipt = controlReceipt(
                .detach, work: request.work, commandID: request.commandID,
                state: .duplicate, causal: request.causalControlCursor,
                resulting: resulting, authorization: authorization, outcome: .detached)
            return WorkServiceDetachResponse(
                work: request.work, commandID: request.commandID, state: .duplicate,
                host: hostInstance, causalControlCursor: request.causalControlCursor,
                resultingControlCursor: resulting, receipt: receipt)
        }
        let source = try await requireCanonical(work: request.work, journal: request.journal)
        let control = try await controlSnapshot()
        guard let current = control.clientAttachments[request.attachment.attachmentID],
              current.client == request.client, current.work == request.work,
              current.workJournal == request.journal, current.isAttached else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        guard current.capabilities.contains(WorkServiceCapability.control.rawValue) else {
            throw WorkServiceProtocolError.capabilityDenied(.control)
        }
        let relationships = try await sessionRelationships(for: source, control: control)
        guard let currentSession = current.session,
              let currentSessionJournal = current.sessionJournal,
              let currentSessionAttachment = current.sessionAttachment,
              relationships.contains(where: {
                  $0.session == currentSession
                      && $0.sessionJournal == currentSessionJournal
                      && $0.sessionAttachment == currentSessionAttachment
                      && $0.isAttached
              }) else {
            throw WorkServiceProtocolError.journalMismatch
        }
        let cursor = try await currentControlCursor()
        guard request.causalControlCursor == cursor else {
            throw WorkServiceProtocolError.staleCursor(expected: request.causalControlCursor, actual: cursor)
        }
        let command = CommandRef(
            commandID: request.commandID, client: request.client,
            sessionAttachment: current.sessionAttachment,
            causalCursor: request.causalControlCursor)
        let detachCommit = try await controlJournal.explicitlyDetachClient(
            work: request.work, workJournal: request.journal, attachment: request.attachment,
            client: request.client, session: current.session, sessionJournal: current.sessionJournal,
            sessionAttachment: current.sessionAttachment, command: command,
            causalControlCursor: request.causalControlCursor)
        let resulting = detachCommit.cursor
        let receipt = controlReceipt(.detach, work: request.work, commandID: request.commandID,
                                    state: .accepted, causal: request.causalControlCursor,
                                    resulting: resulting, authorization: authorization(current),
                                    outcome: .detached)
        return WorkServiceDetachResponse(
            work: request.work, commandID: request.commandID, state: .accepted,
            host: hostInstance, causalControlCursor: request.causalControlCursor,
            resultingControlCursor: resulting, receipt: receipt)
    }

    public func updateCapabilities(_ request: WorkServiceUpdateCapabilitiesRequest) async throws
        -> WorkServiceUpdateCapabilitiesResponse {
        try await ensureLoaded()
        try validateClient(request.client)
        if let prior = try await controlJournal.priorCommand(
            work: request.work, client: request.client, commandID: request.commandID) {
            guard prior.event.type == TimelineEventType.clientCapabilityChanged,
                  prior.event.work == request.work,
                  prior.event.journal == controlJournal.journal,
                  prior.event.client == request.client,
                  prior.event.clientAttachment == request.attachment,
                  prior.event.command?.commandID == request.commandID,
                  prior.event.command?.causalCursor == request.causalControlCursor,
                  let workJournal: JournalRef = decodeControlPayload(
                      prior.event.payload["work_journal"]),
                  workJournal == request.journal,
                  let capabilities: [String] = decodeControlPayload(
                      prior.event.payload["capabilities"]),
                  let requestedCapabilities: [String] = decodeControlPayload(
                      prior.event.payload["requested_capabilities"]),
                  let command = prior.event.command else {
                throw WorkServiceProtocolError.invalidRequest(
                    "client-qualified capability command conflicts with a prior request")
            }
            let sessionJournal: JournalRef? = decodeControlPayload(
                prior.event.payload["session_journal"])
            let identity = WorkHostControlMutationIdentity(
                type: TimelineEventType.clientCapabilityChanged, work: request.work,
                workJournal: workJournal, attachment: request.attachment,
                client: request.client, session: prior.event.session,
                sessionJournal: sessionJournal,
                sessionAttachment: prior.event.sessionAttachment,
                capabilities: capabilities.sorted(),
                requestedCapabilities: requestedCapabilities.sorted(),
                targetJournal: nil, targetCursor: nil,
                causalControlCursor: request.causalControlCursor)
            guard let exact = try await controlJournal.priorMutation(identity, command: command),
                  exact.event.eventID == prior.event.eventID else {
                throw WorkServiceProtocolError.invalidRequest(
                    "client-qualified capability command conflicts with a prior request")
            }
            guard requestedCapabilities == request.requestedCapabilities
                .map(\.rawValue).sorted() else {
                throw WorkServiceProtocolError.invalidRequest(
                    "client-qualified capability command conflicts with a prior request")
            }
            let control = try await controlSnapshot()
            guard let current = control.clientAttachments[request.attachment.attachmentID],
                  current.client == request.client, current.work == request.work,
                  current.workJournal == request.journal else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            var durable = current
            durable.capabilities = Set(capabilities)
            let attachment = try clientAttachment(durable, control: control)
            let authorization = WorkServiceAuthorizationOutcome(
                requested: request.requestedCapabilities,
                granted: attachment.authorization.granted,
                denied: request.requestedCapabilities.subtracting(
                    attachment.authorization.granted))
            let resulting = prior.commit.cursor
            return WorkServiceUpdateCapabilitiesResponse(
                work: request.work, attachment: attachment, authorization: authorization,
                commandID: request.commandID, state: .duplicate, host: hostInstance,
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: resulting,
                receipt: controlReceipt(
                    .updateCapabilities, work: request.work, commandID: request.commandID,
                    state: .duplicate, causal: request.causalControlCursor,
                    resulting: resulting, authorization: authorization,
                    outcome: .capabilitiesUpdated))
        }
        _ = try await requireCanonical(work: request.work, journal: request.journal)
        let auth = authorizer.authorization(
            for: request.client, requested: request.requestedCapabilities)
        guard auth.allows(.observe) else { throw WorkServiceProtocolError.capabilityDenied(.observe) }
        let control = try await controlSnapshot()
        guard let current = control.clientAttachments[request.attachment.attachmentID],
              current.client == request.client, current.work == request.work,
              current.workJournal == request.journal, current.isAttached else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        guard current.capabilities.contains(WorkServiceCapability.control.rawValue) else {
            throw WorkServiceProtocolError.capabilityDenied(.control)
        }
        let cursor = try await currentControlCursor()
        guard request.causalControlCursor == cursor else {
            throw WorkServiceProtocolError.staleCursor(expected: request.causalControlCursor, actual: cursor)
        }
        let command = CommandRef(commandID: request.commandID, client: request.client,
                                 sessionAttachment: current.sessionAttachment,
                                 causalCursor: request.causalControlCursor)
        let capabilityCommit = try await controlJournal.updateClientCapabilities(
            work: request.work, workJournal: request.journal, attachment: request.attachment,
            client: request.client, capabilities: Set(auth.granted.map(\.rawValue)),
            requestedCapabilities: Set(request.requestedCapabilities.map(\.rawValue)),
            session: current.session, sessionJournal: current.sessionJournal,
            sessionAttachment: current.sessionAttachment, command: command,
            causalControlCursor: request.causalControlCursor)
        let resulting = capabilityCommit.cursor
        let snapshot = try await controlSnapshot()
        guard let updated = snapshot.clientAttachments[request.attachment.attachmentID] else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let attachment = try clientAttachment(updated, control: snapshot)
        return WorkServiceUpdateCapabilitiesResponse(
            work: request.work, attachment: attachment, authorization: auth,
            commandID: request.commandID, state: .accepted, host: hostInstance,
            causalControlCursor: request.causalControlCursor, resultingControlCursor: resulting,
            receipt: controlReceipt(.updateCapabilities, work: request.work,
                                    commandID: request.commandID, state: .accepted,
                                    causal: request.causalControlCursor, resulting: resulting,
                                    authorization: auth, outcome: .capabilitiesUpdated))
    }

    public func acknowledgeRead(_ request: WorkServiceAcknowledgeReadRequest) async throws
        -> WorkServiceAcknowledgeReadResponse {
        try await ensureLoaded()
        try validateClient(request.client)
        if let prior = try await controlJournal.priorCommand(
            work: request.work, client: request.client, commandID: request.commandID) {
            guard prior.event.type == TimelineEventType.clientReadAcknowledged,
                  prior.event.work == request.work,
                  prior.event.journal == controlJournal.journal,
                  prior.event.client == request.client,
                  prior.event.clientAttachment == request.attachment,
                  prior.event.command?.commandID == request.commandID,
                  prior.event.command?.causalCursor == request.causalControlCursor,
                  let workJournal: JournalRef = decodeControlPayload(
                      prior.event.payload["work_journal"]),
                  workJournal == request.journal,
                  let targetJournal: JournalRef = decodeControlPayload(
                      prior.event.payload["target_journal"]),
                  targetJournal == request.target.journal,
                  let targetCursor: JournalCursor = decodeControlPayload(
                      prior.event.payload["cursor"]),
                  targetCursor == request.cursor,
                  let command = prior.event.command else {
                throw WorkServiceProtocolError.invalidRequest(
                    "client-qualified read acknowledgement conflicts with a prior request")
            }
            let sessionJournal: JournalRef? = decodeControlPayload(
                prior.event.payload["session_journal"])
            let identity = WorkHostControlMutationIdentity(
                type: TimelineEventType.clientReadAcknowledged, work: request.work,
                workJournal: workJournal, attachment: request.attachment,
                client: request.client, session: prior.event.session,
                sessionJournal: sessionJournal,
                sessionAttachment: prior.event.sessionAttachment,
                capabilities: nil, requestedCapabilities: nil,
                targetJournal: targetJournal, targetCursor: targetCursor,
                causalControlCursor: request.causalControlCursor)
            guard let exact = try await controlJournal.priorMutation(identity, command: command),
                  exact.event.eventID == prior.event.eventID else {
                throw WorkServiceProtocolError.invalidRequest(
                    "client-qualified read acknowledgement conflicts with a prior request")
            }
            let control = try await controlSnapshot()
            guard let current = control.clientAttachments[request.attachment.attachmentID],
                  current.client == request.client, current.work == request.work,
                  current.workJournal == request.journal else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            let authorization = authorization(current)
            let resulting = prior.commit.cursor
            return WorkServiceAcknowledgeReadResponse(
                work: request.work, target: request.target, cursor: request.cursor,
                commandID: request.commandID, state: .duplicate, host: hostInstance,
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: resulting, authorization: authorization,
                receipt: controlReceipt(
                    .acknowledgeRead, work: request.work, commandID: request.commandID,
                    state: .duplicate, causal: request.causalControlCursor,
                    resulting: resulting, authorization: authorization,
                    outcome: .readAcknowledged))
        }
        let source = try await requireCanonical(work: request.work, journal: request.journal)
        guard request.cursor.journal == request.target.journal else {
            throw WorkServiceProtocolError.journalMismatch
        }
        let control = try await controlSnapshot()
        guard let current = control.clientAttachments[request.attachment.attachmentID],
              current.client == request.client, current.work == request.work,
              current.workJournal == request.journal, current.isAttached else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        guard current.capabilities.contains(WorkServiceCapability.observe.rawValue) else {
            throw WorkServiceProtocolError.capabilityDenied(.observe)
        }
        let serviceAttachment = try clientAttachment(current, control: control)
        try await validateReadableTarget(
            request.target, attachment: serviceAttachment, source: source)
        let targetRecords = try await records(for: request.target, source: source)
        let actualTargetCursor = cursor(
            targetRecords.result.records, journal: request.target.journal)
        guard request.cursor.sequence <= actualTargetCursor.sequence else {
            throw WorkServiceProtocolError.staleCursor(expected: request.cursor, actual: actualTargetCursor)
        }
        let cursor = try await currentControlCursor()
        guard request.causalControlCursor == cursor else {
            throw WorkServiceProtocolError.staleCursor(expected: request.causalControlCursor, actual: cursor)
        }
        let command = CommandRef(commandID: request.commandID, client: request.client,
                                 sessionAttachment: current.sessionAttachment,
                                 causalCursor: request.causalControlCursor)
        let acknowledgementCommit = try await controlJournal.acknowledgeRead(
            work: request.work, workJournal: request.journal, attachment: request.attachment,
            client: request.client, targetJournal: request.target.journal, cursor: request.cursor,
            session: current.session, sessionJournal: current.sessionJournal,
            sessionAttachment: current.sessionAttachment, command: command,
            causalControlCursor: request.causalControlCursor)
        let resulting = acknowledgementCommit.cursor
        return WorkServiceAcknowledgeReadResponse(
            work: request.work, target: request.target, cursor: request.cursor,
            commandID: request.commandID, state: .accepted, host: hostInstance,
            causalControlCursor: request.causalControlCursor, resultingControlCursor: resulting,
            authorization: authorization(current),
            receipt: controlReceipt(.acknowledgeRead, work: request.work,
                                    commandID: request.commandID, state: .accepted,
                                    causal: request.causalControlCursor, resulting: resulting,
                                    authorization: authorization(current), outcome: .readAcknowledged))
    }

    public func snapshot(_ request: WorkServiceSnapshotRequest) async throws -> WorkServiceSnapshot {
        try await ensureLoaded()
        try validateClient(request.client)
        let source = try await requireCanonical(work: request.work, journal: request.journal)
        let attachment = try await requireAttached(
            work: request.work, journal: request.journal, attachment: request.attachment,
            client: request.client, capability: .observe)
        try await validateReadableTarget(
            request.target, attachment: attachment, source: source)
        let records = try await records(for: request.target, source: source)
        let page = try await page(
            entry: records, journal: request.target.journal,
            expectedURL: expectedURL(for: request.target, source: source),
            after: request.afterCursor, target: request.target,
            limit: request.limit, maxBytes: request.maxBytes)
        return WorkServiceSnapshot(
            work: try await descriptor(for: request.work, client: request.client),
            events: page.events, target: request.target,
            servedCursor: page.servedCursor, basePrefixDigest: page.basePrefixDigest,
            prefixDigest: page.prefixDigest, omissions: page.omissions)
    }

    public func eventsAfterCursor(_ request: WorkServiceEventsRequest) async throws
        -> WorkServiceEventPage {
        try await ensureLoaded()
        try validateClient(request.client)
        let source = try await requireCanonical(work: request.work, journal: request.journal)
        let attachment = try await requireAttached(
            work: request.work, journal: request.journal, attachment: request.attachment,
            client: request.client, capability: .observe)
        try await validateReadableTarget(
            request.target, attachment: attachment, source: source)
        let records = try await records(for: request.target, source: source)
        let page = try await page(
            entry: records, journal: request.target.journal,
            expectedURL: expectedURL(for: request.target, source: source),
            after: request.afterCursor, target: request.target,
            limit: request.limit, maxBytes: request.maxBytes)
        return WorkServiceEventPage(
            events: page.events, target: request.target, servedCursor: page.servedCursor,
            nextCursor: page.nextCursor, basePrefixDigest: page.basePrefixDigest,
            prefixDigest: page.prefixDigest, omissions: page.omissions)
    }

    public func historyBeforeCursor(
        _ request: WorkServiceHistoryRequest
    ) async throws -> WorkServiceHistoryPage {
        try await ensureLoaded()
        try validateClient(request.client)
        let control = try await controlSnapshot()
        let attachment = try await requireAttached(
            work: request.work, journal: request.journal, attachment: request.attachment,
            client: request.client, capability: .observe)
        guard case .session(let session, let journal) = request.target else {
            throw WorkServiceProtocolError.invalidRequest(
                "history paging requires a Session target")
        }
        guard attachment.session == session,
              attachment.sessionJournal == journal,
              let sessionAttachment = attachment.sessionAttachment,
              journal.owner == .session(session), journal.kind == .session,
              journal.authority.authorityID == host.workHostID else {
            throw WorkServiceProtocolError.journalMismatch
        }
        let source = try await historyCanonicalWorkSource(
            work: request.work, journal: request.journal, control: control)
        let indexDirectory = sessionHistoryIndexDirectory(for: journal)
        let reader: LocalSessionHistoryProjectionReader
        do {
            reader = try LocalSessionHistoryProjectionReader(
                home: home, session: session, journal: journal,
                indexDirectory: indexDirectory)
        } catch {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let result: LocalSessionHistoryProjectionReader.Result
        incrementHistoryMetrics(calls: 1)
        do {
            result = try reader.read(
                before: request.beforeCursor,
                frozenTip: request.frozenTipCursor,
                frozenTipDigest: request.frozenTipDigest,
                branchTip: request.branchTip,
                limit: request.limit, maxBytes: request.maxBytes)
        } catch let error as LocalSessionHistoryProjectionReader.ReaderError {
            switch error {
            case .pageCannotProgress(let required, let maximum):
                throw WorkServiceProtocolError.eventPageCannotProgress(
                    requiredBytes: required, maximumBytes: maximum)
            case .pageTooLarge:
                throw WorkServiceProtocolError.invalidRequest(
                    "history page bounds are invalid")
            default:
                throw WorkServiceProtocolError.sourceIncomplete
            }
        } catch {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        incrementHistoryMetrics(result.metrics)
        if let historyAfterInitialReadHook {
            await historyAfterInitialReadHook()
        }
        let relationshipIsCanonical = try await historyRelationshipIsCanonical(
            work: request.work, session: session, journal: journal,
            sessionAttachment: sessionAttachment,
            relationshipEvents: result.relationshipEvents,
            source: source, control: control)
        guard relationshipIsCanonical else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        // Work and Session relationship facts live in independent append-only journals. Take a
        // second bounded pass after every source used by the first validation has returned. A
        // SessionAttachment identity is terminal once detached, so equal attached projections
        // on both passes are ABA-proof: there was an interval in which the requested Session,
        // the creation Session, and Work authority all overlapped. Content-only Session appends
        // remain valid and do not perturb this relationship projection.
        let latestSource = try await historyCanonicalWorkSource(
            work: request.work, journal: request.journal, control: control)
        let authorityAttachmentIDs = Set([
            sessionAttachment.attachmentID,
            source.registration.reservation.sessionAttachment.attachmentID,
        ])
        guard authorityAttachmentIDs.allSatisfy({ attachmentID in
            latestSource.workState.sessionAttachments[attachmentID]
                == source.workState.sessionAttachments[attachmentID]
        }) else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let latestRelationship: LocalSessionHistoryProjectionReader.RelationshipAuthorityResult
        do {
            latestRelationship = try reader.readCurrentRelationshipAuthority()
        } catch {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        incrementHistoryMetrics(latestRelationship.metrics)
        guard try await historyRelationshipIsCanonical(
                work: request.work, session: session, journal: journal,
                sessionAttachment: sessionAttachment,
                relationshipEvents: latestRelationship.relationshipEvents,
                source: latestSource, control: control) else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        // Every source/registry call above may suspend this actor. Re-read the bounded control
        // facts last and perform the final authorization check synchronously, so a detach,
        // capability revocation, registration conflict, or replacement Session publication
        // cannot race an already-started history read and receive bytes afterward.
        let finalControl = try await controlSnapshot()
        guard historyFinalControlIsAuthorized(
              finalControl, initialControl: control, request: request,
              session: session, journal: journal,
              sessionAttachment: sessionAttachment, registration: source.registration) else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        let frozen = result.source.physicalCursor
        let upper = result.events.last.map {
            JournalCursor(journal: journal, eventID: $0.eventID, sequence: $0.sequence)
        }
        let lower = result.events.first.map {
            JournalCursor(journal: journal, eventID: $0.eventID, sequence: $0.sequence)
        }
        let pageDigest = try WorkServiceHistoryPageEvidence.digest(
            events: result.events, target: request.target, cursor: upper ?? frozen)
        let omissions = result.hasOlder ? [WorkServiceOmission(
            category: "history", count: 1,
            diagnostic: "older selected-branch messages remain")] : []
        return WorkServiceHistoryPage(
            authority: try WorkServiceHistoryAuthority(
                work: request.work, journal: request.journal,
                hostInstance: hostInstance, sourceCompleteness: .complete),
            events: result.events, target: request.target,
            lowerBoundaryCursor: lower, upperBoundaryCursor: upper,
            nextBeforeCursor: result.nextBeforeCursor, hasOlder: result.hasOlder,
            frozenTipCursor: frozen, frozenTipDigest: result.source.wirePrefixDigest,
            prefixDigest: pageDigest, branchTip: result.semanticTip,
            omissions: omissions)
    }

    public func fetchArtifact(_ request: WorkServiceArtifactRequest) async throws
        -> WorkServiceArtifactDescriptor {
        try await ensureLoaded()
        try validateClient(request.client)
        guard validArtifactIdentity(request.artifactID) else {
            throw WorkServiceProtocolError.invalidRequest(
                "artifact identity must be nonblank and bounded")
        }
        let source = try await requireCanonical(work: request.work, journal: request.journal)
        try await requireAttached(
            work: request.work, journal: request.journal, attachment: request.attachment,
            client: request.client, capability: .inspectArtifacts)
        let sourceArtifacts = try uniqueArtifacts(in: source)
        let artifactIndexOmitted = !source.workCache.artifactDescriptorsComplete
            || source.workCache.artifactDescriptorCount != sourceArtifacts.count
        if artifactIndexOmitted {
            // Even a matching row in the newest bounded window is not an exact identity proof:
            // the same ID may have appeared before that row was retained.  Scan the canonical
            // stream for this requested ID and fail closed on a duplicate.
            guard let artifact = try streamFindArtifact(
                entry: source.workCache,
                journal: source.workJournal,
                expectedURL: home.timelineV2WorkJournalURL(request.work),
                work: request.work,
                artifactID: request.artifactID) else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            return artifact
        }
        guard let artifact = sourceArtifacts.first(where: {
            $0.artifactID == request.artifactID
        }) else {
            // A complete descriptor index proves that this identity is absent.
            throw WorkServiceProtocolError.artifactNotFound
        }
        return artifact
    }

    public func fetchBody(_ request: WorkServiceBodyRequest) async throws -> WorkServiceBodyResponse {
        try await ensureLoaded()
        try validateClient(request.client)
        let source = try await requireCanonical(work: request.work, journal: request.journal)
        let attachment = try await requireAttached(
            work: request.work, journal: request.journal, attachment: request.attachment,
            client: request.client, capability: .observe)
        guard request.offset >= 0, request.limit > 0 else {
            throw WorkServiceProtocolError.invalidRequest("body offset and limit must be positive")
        }
        guard request.reference.authority == request.journal
                || request.reference.authority == attachment.sessionJournal else {
            throw WorkServiceProtocolError.journalMismatch
        }
        switch try classifyBodyReference(source, request.reference) {
        case .artifact:
            guard attachment.authorization.allows(.inspectArtifacts) else {
                throw WorkServiceProtocolError.capabilityDenied(.inspectArtifacts)
            }
        case .context:
            break
        case .absent:
            return WorkServiceBodyResponse(reference: request.reference, status: .unavailable,
                                           offset: request.offset,
                                           diagnostic: "body reference is not present in canonical journals")
        case .unknown:
            // A Work-journal body is sensitive by default.  Do not turn a reference embedded in
            // an event shape outside the narrow producer vocabulary into either observe access
            // or an inspect-artifacts success.
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let store = ContextBodyStore(home: home)
        guard let body = try? store.read(request.reference) else {
            return WorkServiceBodyResponse(reference: request.reference, status: .unavailable,
                                           offset: request.offset, diagnostic: "body is not retained")
        }
        guard request.offset <= body.count else {
            throw WorkServiceProtocolError.invalidRequest("body offset is beyond retained body")
        }
        let length = min(request.limit, WorkServiceBounds.maxBodyChunkBytes)
        let end = request.offset + min(length, body.count - request.offset)
        return WorkServiceBodyResponse(
            reference: request.reference, status: .retained, offset: request.offset,
            data: body.subdata(in: request.offset..<end), nextOffset: end < body.count ? end : nil)
    }

    public func command(_ request: WorkServiceCommandRequest) async throws
        -> WorkServiceCommandReceipt {
        try await ensureLoaded()
        try validateClient(request.command.client)
        guard let client = request.command.client,
              request.command.causalCursor == request.causalWorkCursor else {
            throw WorkServiceProtocolError.invalidRequest("command causal cursor is inconsistent")
        }
        let attachment = try await requireAttached(
            work: request.work, journal: request.journal, attachment: request.attachment,
            client: client, capability: capability(for: request.kind))
        guard request.command.sessionAttachment == attachment.sessionAttachment else {
            throw WorkServiceProtocolError.invalidRequest("command Session attachment does not match client attachment")
        }
        // The first Start can have crossed the native run.started boundary while its Hosted
        // actor is still being admitted to the registry. In that narrow window there is no cold
        // source read available (the actor owns both journal locks), but an exact same-intent
        // caller can still join the in-process admission task. Match the complete client/body/
        // cursor identity and the authenticated Session binding before waiting; a different
        // binding or intent must continue through the normal fail-closed path below.
        var joinedInFlightStart = false
        if request.kind == .start,
           let session = attachment.session,
           let sessionAttachment = attachment.sessionAttachment,
           let client = request.command.client {
            let intent = WorkLaunchStartIntent(
                client: client, commandID: request.command.commandID,
                causalWorkCursor: request.causalWorkCursor,
                bodyDigest: digest(Data((request.value ?? "").utf8)))
            let binding = WorkBinding(
                session: session, work: request.work, workHost: host,
                sessionAttachment: sessionAttachment)
            if let task = startsInProgress.first(where: {
                $0.key.work == request.work
                    && $0.key.binding == binding
                    && $0.key.intent == intent
            })?.value {
                _ = try await task.value
                joinedInFlightStart = true
            }
        }
        // Authenticate the caller's exact control attachment before attempting a canonical
        // source read. During an active Run the owning actor keeps its journal locks held, so a
        // foreign Session must receive the stable owner rejection rather than an incidental
        // sourceIncomplete result from the cold registration Session. This is negative-only: a
        // matching owner still goes through the full canonical verifier below.
        if [.send, .steer, .queue, .cancel, .end].contains(request.kind) {
            try await rejectCrossSessionLiveOwner(
                work: request.work, attachment: attachment)
        }
        let source = try await requireCanonical(work: request.work, journal: request.journal)
        let callerBinding = try callerWorkBinding(attachment, source: source, work: request.work)
        let commandLedgerID = qualifiedCommandID(clientID: client.clientID,
                                                  commandID: request.command.commandID)
        let priorCommand = source.workState.commands[commandLedgerID]
        switch request.kind {
        case .start:
            // A Start is a Work-level admission, but its selected Session/attachment is the
            // caller's authenticated canonical attachment. A stale owner tuple is never
            // silently inherited from the creation reservation. An exact retry of an already
            // recorded Start is allowed through to the duplicate/recovery projection below,
            // including after a service restart; a new Start remains refused while any Run is
            // active even when it comes from that same Session.
            let sameActiveOwner = source.workState.activeRunSession == callerBinding.session
                && source.workState.activeRunSessionAttachment == callerBinding.sessionAttachment
            let exactRecordedStart = priorCommand != nil && sameActiveOwner
            if source.workState.activeRun != nil {
                // A same-Session caller may be observing the narrow opener window after the
                // native run.started marker but before command.accepted is durable. That is not
                // an ownership conflict; it is an unjoinable, incomplete admission and must
                // fail closed as source-incomplete. A different Session remains a stable public
                // invalidRequest and never reaches actor/ledger admission.
                guard sameActiveOwner else {
                    throw WorkServiceProtocolError.invalidRequest(
                        "Start is owned by another active Session attachment")
                }
                guard exactRecordedStart || joinedInFlightStart else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
            } else {
                guard source.workState.activeRunSession == nil,
                      source.workState.activeRunSessionAttachment == nil else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
            }
        case .send, .steer, .queue, .cancel, .end:
            // All mutable text/run controls are owner-qualified. This check precedes every
            // ledger/actor path, so a secondary Session can observe but cannot create a
            // transcript event or command-acceptance event.
            guard source.workState.activeRun != nil,
                  source.workState.activeRunSession == callerBinding.session,
                  source.workState.activeRunSessionAttachment == callerBinding.sessionAttachment else {
                throw WorkServiceProtocolError.invalidRequest(
                    "active Run belongs to a different Session attachment")
            }
        case .hold, .complete, .destroy:
            break
        }
        guard !request.valueWasTruncated,
              (request.value?.utf8.count ?? 0) <= WorkServiceBounds.maxCommandValueCharacters else {
            throw WorkServiceProtocolError.invalidRequest("command value exceeds protocol bounds")
        }
        if request.kind == .start {
            // Start's value is part of the client-qualified launch identity. Resolve the durable
            // Work template before any actor admission so a retry or a racing caller cannot bind
            // the same Run reservation to different prompt bytes.
            guard let store = manifestStore,
                  try await store.resolve(
                      work: request.work, session: callerBinding.session,
                      sessionAttachment: callerBinding.sessionAttachment) != nil else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            // The per-Run body is retained at Start admission. The Run-free template is only
            // configuration/reconstruction material and must not constrain a replacement's
            // exact input bytes.
        }
        let liveActor: WorkHostRegistryLiveEntry?
        if let lookup = await registry.lookup(request.work), case .live(let entry) = lookup {
            liveActor = entry
        } else {
            liveActor = nil
        }
        let exactLiveActor = if let liveActor {
            await exactLiveHostedActor(liveActor, source: source, binding: callerBinding)
        } else {
            false
        }
        // An explicit End leaves the terminal Hosted actor in the registry until the replacement
        // Start swaps it for the next Run. Its ended/closed snapshot is not a liveness proof, but
        // it is a valid reusable boundary when the canonical Work has no active Run. Other
        // disconnected, failed, or identity-mismatched actors remain recovery-required.
        let endedLiveActor: Bool
        if let liveActor {
            let snapshot = await liveActor.hostedWork.snapshot()
            endedLiveActor = snapshot.identity.work == source.registration.reservation.work
                && snapshot.lifecycle == .ended
                && snapshot.journalHealth == .closed
        } else {
            endedLiveActor = false
        }
        // These are observations of a durable execution/recovery boundary, not ordinary
        // command-state rejections. Do not let terminal commands or a send through an absent
        // actor turn them back into an idle/reusable Work. The one exception is the exact Start
        // admission retry which may repair a minted Run through the native marker bridge.
        let exactStartRecoveryRetry: Bool
        if request.kind == .start {
            exactStartRecoveryRetry = try await isExactStartRecoveryRetry(
                request, source: source, client: client, binding: callerBinding)
        } else {
            exactStartRecoveryRetry = false
        }
        // The first Start may be suspended while the prompt resolver reads bounded ambient
        // inputs. A same-intent request must join that exact in-process task before the durable
        // reservation is classified as an unfinished crash; a different intent remains fenced.
        let inFlightStartAdmission: Bool = if request.kind == .start {
            startsInProgress[startAdmissionKey(
                work: request.work, binding: callerBinding, client: client,
                commandID: request.command.commandID,
                causalWorkCursor: request.causalWorkCursor,
                prompt: request.value ?? "")] != nil
        } else {
            false
        }
        let unstartedStartReservation = try await hasUnstartedStartReservation(
            source, binding: callerBinding)
        let registryRequiresRecovery: Bool = if let lookup = await registry.lookup(request.work) {
            switch lookup {
            case .recovering, .unavailable: true
            case .live, .historical: false
            }
        } else {
            false
        }
        let executionRequiresRecovery = source.workState.execution == .failed
            || source.workState.execution == .unknown
            || (unstartedStartReservation && !inFlightStartAdmission)
            || (source.workState.activeRun != nil && !exactLiveActor)
            || (source.workState.activeRun == nil
                && source.workState.execution != .idle && !exactLiveActor)
            // A registry `.live` label is only an ownership lookup. If its Hosted snapshot is
            // disconnected, failed, stale, or otherwise mismatched, even an idle reducer state
            // must remain non-actionable until an exact recovery path proves a healthy actor.
            || (liveActor != nil && !exactLiveActor
                && !(request.kind == .start && source.workState.activeRun == nil
                    && endedLiveActor))
            || registryRequiresRecovery
        // A Start retry needs the durable, client-qualified admission record. The Work command
        // projection intentionally does not retain enough request body material to prove that a
        // caller with the same textual id supplied the same launch. If the exact Start record is
        // present, its acceptance is already canonical and a lost response can be replayed without
        // reopening an ended actor or minting a second Run.
        if request.kind == .start, priorCommand != nil {
            guard let priorCursor = priorCommand?.command.causalCursor,
                  request.causalWorkCursor == priorCursor else {
                throw WorkServiceProtocolError.staleCursor(
                    expected: priorCommand?.command.causalCursor ?? source.workCursor,
                    actual: request.causalWorkCursor)
            }
            guard let priorManifest = try await resolveStartManifest(
                work: request.work, source: source, client: client,
                commandID: request.command.commandID, prompt: request.value ?? "",
                binding: callerBinding),
                  let priorRecord = priorManifest.durableRecord,
                  startBodyMatches(
                    request.value ?? "", record: priorRecord) else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            // A Work may already have a newer Run actor after End -> Start. Only an actor whose
            // complete identity matches this historical Start is a liveness proof for its
            // duplicate receipt; a different current Run must remain explicitly unproven.
            let samePriorIdentity = liveActor.map {
                $0.hostedWork.identity.work == priorRecord.manifest.identity.work
                    && $0.hostedWork.identity.sessionID == priorRecord.manifest.identity.session.sessionID
                    && $0.hostedWork.identity.runID == priorRecord.manifest.identity.run.runID
                    && $0.hostedWork.sessionAttachment == priorRecord.manifest.identity.sessionAttachment
            } ?? false
            // Identity alone is not a liveness proof. The exact snapshot gate also checks the
            // runtime connection, journal health, lifecycle, and active Run tuple; a retained
            // actor with the right IDs but a failed/disconnected writer remains recovery-required.
            let hasLiveActorForPrior = samePriorIdentity && exactLiveActor
            let latest = try await canonicalSource(
                work: request.work, journal: request.journal,
                registration: source.registration)
            let priorState = priorCommand!.state
            let recoveryRequired = source.workState.activeRun == priorRecord.manifest.identity.run
                && !hasLiveActorForPrior
            let deliveryDiagnostic: String?
            let duplicateOutcome: WorkServiceCommandOutcome?
            let duplicateRejection: WorkServiceCommandRejection?
            let duplicateRecoveryState: CommandDeliveryState?
            switch priorState {
            case .accepted:
                duplicateOutcome = recoveryRequired ? .startRecoveryRequired : .started
                duplicateRejection = nil
                duplicateRecoveryState = recoveryRequired ? .accepted : nil
                deliveryDiagnostic = recoveryRequired
                    ? "Start was accepted before host loss; delivery is unproven and no redispatch was attempted"
                    : "Start was already durably admitted"
            case .delivered:
                duplicateOutcome = recoveryRequired ? .startRecoveryRequired : .started
                duplicateRejection = nil
                duplicateRecoveryState = recoveryRequired ? .delivered : nil
                deliveryDiagnostic = recoveryRequired
                    ? "Start was accepted and delivered before host loss; execution recovery is required and no redispatch was attempted"
                    : "Start was already durably admitted and delivered"
            case .rejected:
                duplicateOutcome = nil
                duplicateRejection = .invalidState
                duplicateRecoveryState = nil
                deliveryDiagnostic = "Start was durably rejected"
            case .notDelivered:
                duplicateOutcome = .startRecoveryRequired
                duplicateRejection = nil
                duplicateRecoveryState = .notDelivered
                deliveryDiagnostic = "Start was accepted but durably marked not delivered; recovery is required and no redispatch was attempted"
            case .indeterminate:
                duplicateOutcome = .startRecoveryRequired
                duplicateRejection = nil
                duplicateRecoveryState = .indeterminate
                deliveryDiagnostic = "Start delivery is indeterminate; recovery is required and no redispatch was attempted"
            }
            let exactEvidence = try JournalBackedWorkServiceCommandEvidence.resolve(
                snapshot: latest.workState, journal: latest.workJournal,
                request: request, client: client)
            let receiptState: WorkServiceCommandReceiptState = priorState == .rejected
                ? .rejected : .duplicate
            return WorkServiceCommandReceipt(
                work: request.work, commandID: request.command.commandID,
                state: receiptState, host: hostInstance,
                // Public rejection receipts do not claim an accepted execution ordering.
                // The rejection event remains addressable through `resultingWorkCursor`.
                hostSequence: receiptState == .rejected ? nil : exactEvidence.hostSequence,
                hostProvenance: hasLiveActorForPrior ? .current : .unknown,
                causalWorkCursor: priorCommand?.command.causalCursor ?? request.causalWorkCursor,
                resultingWorkCursor: exactEvidence.cursor,
                authorization: attachment.authorization, outcome: duplicateOutcome,
                rejection: duplicateRejection, recoveryState: duplicateRecoveryState,
                diagnostic: deliveryDiagnostic)
        }
        // A duplicate Start can return its already-canonical recovery receipt without acting on
        // the host. All new commands, including terminal commands, remain fail-closed while the
        // durable execution boundary is unproven; only an exact non-duplicate Start retry may
        // repair a pre-run marker through the native bridge below.
        guard !executionRequiresRecovery || exactStartRecoveryRetry || inFlightStartAdmission else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        // A retry may carry the original (now stale) cursor. Only the exact live actor can
        // compare the complete command value and reconcile the response; after restart, a Work
        // command projection deliberately lacks enough body material to invent that proof.
        if priorCommand != nil && liveActor == nil
                && request.kind != .complete && request.kind != .destroy {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let initialStartRecoveryCursor = request.kind == .start
            ? startPredecessorCursor(source) : nil
        guard request.causalWorkCursor == source.workCursor || priorCommand != nil
                || request.kind == .complete || request.kind == .destroy
                || request.causalWorkCursor == initialStartRecoveryCursor else {
            throw WorkServiceProtocolError.staleCursor(
                expected: request.causalWorkCursor, actual: source.workCursor)
        }
        switch request.kind {
        case .hold:
            throw WorkServiceProtocolError.invalidRequest("hold is not supported by HostedInHouseWork")
        case .complete, .destroy:
            return try await terminalCommand(request, source: source, attachment: attachment,
                                             client: client)
        case .start, .send, .steer, .queue, .cancel, .end:
            break
        }
        let live: WorkHostRegistryLiveEntry
        var ownsStartAdmission = false
        var startAdmissionKeyToRelease: StartAdmissionKey?
        defer {
            if ownsStartAdmission, let key = startAdmissionKeyToRelease {
                startsInProgress.removeValue(forKey: key)
            }
        }
        if request.kind == .start {
            let admission: StartActorAdmission
            do {
                admission = try await admitStartActor(
                    work: request.work, source: source, client: client,
                    commandID: request.command.commandID,
                    causalWorkCursor: request.causalWorkCursor,
                    prompt: request.value ?? "", binding: callerBinding)
            } catch WorkLaunchManifestStoreError.requestConflict,
                    WorkLaunchManifestStoreError.generationMismatch {
                // The durable Work-scoped Start CAS may be won by another Session after this
                // caller's idle observation. Surface the stable service rejection rather than
                // leaking a store implementation error or retrying with a second Run identity.
                throw WorkServiceProtocolError.sourceIncomplete
            }
            live = admission.entry
            ownsStartAdmission = admission.ownsTask
            if ownsStartAdmission {
                startAdmissionKeyToRelease = startAdmissionKey(
                    work: request.work, binding: callerBinding, client: client,
                    commandID: request.command.commandID,
                    causalWorkCursor: request.causalWorkCursor,
                    prompt: request.value ?? "")
            }
        } else if let lookup = await registry.lookup(request.work), case .live(let entry) = lookup {
            live = entry
        } else {
            throw WorkServiceProtocolError.hostUnavailable(host)
        }
        let sessionCommand: SessionCommand
        switch request.kind {
        case .start: sessionCommand = .start(prompt: request.value ?? "")
        case .send: sessionCommand = .send(prompt: request.value ?? "")
        case .steer: sessionCommand = .steer(text: request.value ?? "")
        case .queue: sessionCommand = .queueFollowUp(text: request.value ?? "")
        case .cancel:
            guard let value = request.value,
                  let scope = SessionCancellationScope(rawValue: value) else {
                throw WorkServiceProtocolError.invalidRequest("cancel requires a valid scope")
            }
            sessionCommand = .cancel(scope: scope)
        case .end: sessionCommand = .endRun
        case .hold, .destroy, .complete: fatalError("terminal/hold handled above")
        }
        let hosted = HostedInHouseWorkCommand(
            work: request.work, session: callerBinding.session,
            sessionAttachment: callerBinding.sessionAttachment, client: client,
            commandID: request.command.commandID,
            // The caller's cursor is the command's canonical causal identity. The execution
            // opener must provide a journal-level bridge for the preceding `run.started` marker;
            // substituting the post-open cursor here would produce a split-brain receipt and
            // canonical CommandRef. Until that bridge is available, the native journal fails
            // closed rather than silently rewriting this identity.
            causalCursor: request.causalWorkCursor,
            command: sessionCommand)
        do {
            let result = try await live.hostedWork.submit(hosted)
            // A same-intent caller which joined the in-process admission task is a duplicate
            // even though Hosted's idempotent command ledger returns the original accepted
            // receipt. Preserve one accepted opener and one duplicate reconciliation at the
            // public service boundary; later retries use the durable prior-command branch.
            let state: WorkServiceCommandReceiptState = if result.receipt.wasAdmitted {
                request.kind == .start && !ownsStartAdmission ? .duplicate : .accepted
            } else {
                .rejected
            }
            let rejectionProjection: (WorkServiceCommandRejection?, String?) =
                switch result.receipt.admission {
                case .accepted:
                    (nil, nil)
                case .rejected(_, reason: .causalConflict):
                    // Native admission rejected the caller's exact Work cursor before writing
                    // any command fact. Preserve that retry-safe result at the service boundary
                    // instead of collapsing it into an unrelated lifecycle refusal.
                    (.staleCursor, "Hosted Work rejected a stale causal Work cursor.")
                case .rejected(_, reason: .journalUnavailable):
                    (.sourceIncomplete, "Hosted Work could not durably admit the command.")
                case .rejected(_, reason: .emptyInput),
                        .rejected(_, reason: .invalidActor):
                    (.malformedRequest, "Hosted Work rejected malformed command input.")
                case .rejected(_, reason: .unsupportedCommand),
                        .rejected(_, reason: .unsupportedCancellation):
                    (.invalidState, "Hosted Work does not support the requested command here.")
                case .rejected(_, reason: .invalidState(_, let controllerState)):
                    (.invalidState,
                     "Hosted Work refused the command while \(controllerState.rawValue).")
                }
            let outcome = result.receipt.wasAdmitted ? commandOutcome(request.kind) : nil
            let latest = try await canonicalSource(
                work: request.work, journal: request.journal,
                registration: source.registration)
            let exactEvidence: JournalBackedWorkServiceCommandEvidence.Result?
            if result.receipt.wasAdmitted {
                exactEvidence = try JournalBackedWorkServiceCommandEvidence.resolve(
                    snapshot: latest.workState, journal: latest.workJournal,
                    request: request, client: client)
            } else {
                exactEvidence = nil
            }
            return WorkServiceCommandReceipt(
                work: request.work, commandID: request.command.commandID, state: state,
                host: hostInstance, hostSequence: exactEvidence?.hostSequence,
                causalWorkCursor: request.causalWorkCursor,
                // The public receipt identifies command acceptance, not whichever asynchronous
                // Agent delivery happened to append before this read. Joined Start callers and
                // later duplicate retries must therefore expose the same immutable cursor.
                resultingWorkCursor: exactEvidence?.cursor ?? latest.workCursor,
                authorization: attachment.authorization, outcome: outcome,
                rejection: rejectionProjection.0,
                diagnostic: result.receipt.delivery.detail ?? rejectionProjection.1)
        } catch let error as HostedInHouseWorkError {
            throw WorkServiceProtocolError.invalidRequest(error.localizedDescription)
        }
    }

    public func completeWork(_ request: WorkServiceCompleteWorkRequest) async throws
        -> WorkServiceCommandReceipt {
        let command = WorkServiceCommandRequest(
            work: request.work, journal: request.journal, attachment: request.attachment,
            commandID: request.command.commandID, client: request.command.client ?? ClientRef(""),
            sessionAttachment: request.command.sessionAttachment,
            causalWorkCursor: request.causalWorkCursor, kind: .complete)
        return try await self.command(command)
    }

    /// Re-read all control creations and source journals. This method intentionally returns
    /// recovery categories instead of upgrading a durable active Run to `running`.
    public func scanRecovery() async throws -> [JournalBackedWorkRecoveryEntry] {
        try await ensureLoaded()
        let control = try await controlSnapshot()
        var result: [JournalBackedWorkRecoveryEntry] = []
        for creation in control.creations.values.sorted(by: {
            $0.reservation.work.workID < $1.reservation.work.workID
        }) {
            let reservation = creation.reservation
            guard let registration = creation.registration, !creation.isConflicted else {
                let disposition: JournalBackedWorkRecoveryDisposition =
                    creation.registration == nil ? .unavailable : .corrupt
                result.append(JournalBackedWorkRecoveryEntry(
                    work: reservation.work, journal: creation.registration?.workJournal,
                    disposition: disposition, sourcePresence: .notObserved,
                    failure: creation.isConflicted ? .creationConflicted : .registrationMissing,
                    hostInstance: hostInstance,
                    diagnostic: "creation source verification did not produce a reconstructable pair"))
                continue
            }
            do {
                let source = try await historyCanonicalWorkSource(
                    work: reservation.work, journal: registration.workJournal,
                    control: control)
                let sessionReader = try LocalSessionHistoryProjectionReader(
                    home: home, session: reservation.session,
                    journal: registration.sessionJournal,
                    indexDirectory: sessionHistoryIndexDirectory(
                        for: registration.sessionJournal),
                    limits: .init(maximumPageBytes: 1 * 1_024 * 1_024))
                incrementHistoryMetrics(calls: 1)
                let sessionObservation = try sessionReader.read(
                    limit: 1, maxBytes: 1 * 1_024 * 1_024)
                incrementHistoryMetrics(sessionObservation.metrics)
                guard source.workState.sessionAttachments[
                    reservation.sessionAttachment.attachmentID].map({
                        $0.attachment == reservation.sessionAttachment
                            && $0.session == reservation.session && $0.isAttached
                    }) == true,
                    currentHistorySessionRelationshipIsAttached(
                        sessionObservation.relationshipEvents,
                        session: reservation.session, work: reservation.work,
                        attachment: reservation.sessionAttachment),
                    primaryHistoryRelationshipIsCanonical(
                    relationshipEvents: sessionObservation.relationshipEvents,
                    source: source) else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                // Recovery classification is a fresh observation. The in-memory manifest cache
                // is useful for routing only; it is never enough to call an idle Work
                // reconstructable after a store loss, deletion, or tamper event.
                let manifestResolves: Bool
                let hostedConfigurationResolves: Bool
                if let store = manifestStore {
                    let resolved = try? await store.resolve(
                        work: reservation.work, session: reservation.session,
                        sessionAttachment: reservation.sessionAttachment)
                    manifestResolves = resolved != nil
                    hostedConfigurationResolves = if let resolved {
                        (try? await store.canReconstruct(resolved)) == true
                    } else {
                        false
                    }
                } else {
                    manifestResolves = false
                    hostedConfigurationResolves = false
                }
                let lookup = await registry.lookup(reservation.work)
                let hasUnstartedStartReservation = try await self.hasUnstartedStartReservation(
                    source, binding: primaryWorkBinding(source))
                let disposition: JournalBackedWorkRecoveryDisposition
                let host: WorkHostInstanceRef?
                switch source.workState.lifecycle {
                case .completed, .destroyed:
                    disposition = .historical
                    host = nil
                case .active:
                    if source.workState.execution == .unknown
                            || !source.workState.unknownEvents.isEmpty
                            || !source.workState.unknownDomains.isEmpty {
                        disposition = .corrupt
                    } else if source.workState.execution == .failed {
                        disposition = .recoveryRequired
                    } else if source.workState.activeRun != nil {
                        // A durable run marker is evidence of unfinished recovery, never a
                        // runtime liveness claim. An actor retained by this process is still
                        // classified separately as live-unproven; after restart there is no such
                        // registration and the same canonical state is recovery-required.
                        disposition = lookup?.isLiveRegistration == true
                            ? .liveUnproven : .recoveryRequired
                    } else if hasUnstartedStartReservation {
                        // A Run-bound selection or pending mutex without a canonical marker is
                        // an unfinished Start admission. It must never be projected as idle or
                        // reconstructed by a different command.
                        disposition = .recoveryRequired
                    } else if manifestResolves && hostedConfigurationResolves
                                && lookup?.isLiveRegistration == true {
                        disposition = .idleReconstructable
                    } else {
                        disposition = manifestResolves && hostedConfigurationResolves
                            ? .idleReconstructable : .recoveryRequired
                    }
                    host = lookup.flatMap { if case .live(let entry) = $0 { return entry.hostInstance }; return nil }
                case .unknown:
                    disposition = .corrupt
                    host = nil
                }
                result.append(JournalBackedWorkRecoveryEntry(
                    work: reservation.work, journal: registration.workJournal,
                    disposition: disposition, workCursor: source.workCursor,
                    sessionCursor: sessionObservation.source.physicalCursor,
                    sourcePresence: .verified,
                    hostInstance: host, diagnostic: nil))
            } catch {
                result.append(JournalBackedWorkRecoveryEntry(
                    work: reservation.work, journal: registration.workJournal,
                    disposition: .corrupt, sourcePresence: .unverified,
                    hostInstance: hostInstance, diagnostic: "canonical source read failed"))
            }
        }
        return result
    }

    // MARK: Internals

    private struct CanonicalSource: Sendable {
        let registration: WorkHostControlWorkRegistration
        let workJournal: JournalRef
        let sessionJournal: JournalRef
        let workCache: JournalReadCacheEntry
        let sessionCache: JournalReadCacheEntry
        let workRead: TimelineJournalReadResult
        let sessionRead: TimelineJournalReadResult
        let workState: WorkSnapshot
        let sessionState: SessionSnapshot
        let workSequenceToIndex: [Int: Int]
        let sessionSequenceToIndex: [Int: Int]
        let workCursor: JournalCursor
        let sessionCursor: JournalCursor
        var session: SessionRef { registration.reservation.session }
        var sessionAttachment: SessionAttachmentRef { registration.reservation.sessionAttachment }
        var boundedWorkRecords: [TimelineJournalRecord] {
            workRead.records.isEmpty ? workCache.prefixRecords : workRead.records
        }
        var boundedSessionRecords: [TimelineJournalRecord] {
            sessionRead.records.isEmpty ? sessionCache.prefixRecords : sessionRead.records
        }
    }

    /// History needs current Work/relationship authority, but not the creation Session's full
    /// transcript. Keeping this projection separate prevents a reverse-page request for one
    /// attached Session from replaying another Session into an unbounded message array.
    private struct HistoryCanonicalWorkSource: Sendable {
        let registration: WorkHostControlWorkRegistration
        let workCache: JournalReadCacheEntry
        let workState: WorkSnapshot
        let workCursor: JournalCursor
    }

    private func historyCanonicalWorkSource(
        work: WorkRef,
        journal: JournalRef,
        control: WorkHostControlSnapshot
    ) async throws -> HistoryCanonicalWorkSource {
        let matchingCreations = control.creations.values.filter {
            $0.reservation.work == work && $0.registration?.workJournal == journal
        }
        guard control.structuralIntegrityValid, control.semanticProjectionValid,
              control.unknownEvents.isEmpty,
              control.workHost == host,
              matchingCreations.count == 1,
              let creation = matchingCreations.first, !creation.isConflicted,
              let registration = creation.registration,
              registration.reservation == creation.reservation,
              registration.reservation.work == work,
              registration.workJournal == journal,
              journal.owner == .work(work), journal.kind == .work,
              journal.authority.authorityID == host.workHostID,
              registration.sessionJournal.owner == .session(
                registration.reservation.session),
              registration.sessionJournal.kind == .session,
              registration.sessionJournal.authority.authorityID == host.workHostID else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let activeObservation = try await liveObservationIfActive(work: work, supplied: nil)
        let cache: JournalReadCacheEntry
        if let activeObservation {
            guard activeObservation.workOnly.journal == journal else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            cache = try journalCacheEntry(from: activeObservation.workOnly, work: work)
        } else {
            cache = try readJournal(
                journal, expectedURL: home.timelineV2WorkJournalURL(work))
        }
        guard cache.result.quarantinedSuffix == nil,
              cache.result.truncatedTail == nil,
              let state = cache.workSnapshot,
              state.structuralIntegrityValid, state.semanticProjectionValid,
              state.unknownDomains.isDisjoint(with: [.work, .session]),
              state.work == work, state.workHost == host, state.journal == journal,
              let last = cache.lastRecord?.event else {
            throw WorkServiceProtocolError.sourceIncomplete
        }

        // The control registration alone is never source proof. Authenticate the exact bounded
        // creation prefix against the current Work journal and require its original Session
        // relationship before allowing an unrelated history index to be opened.
        let prefix = cache.result.records.isEmpty
            ? cache.prefixRecords : cache.result.records
        guard registration.workGenesisCursor.journal == journal,
              registration.workGenesisCursor.sequence > 0,
              let registeredIndex = prefix.firstIndex(where: {
                $0.event.sequence == registration.workGenesisCursor.sequence
                    && $0.event.eventID == registration.workGenesisCursor.eventID
              }) else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        var genesisReducer = WorkReducer()
        for record in prefix[...registeredIndex] { genesisReducer.apply(record.event) }
        let genesis = genesisReducer.snapshot
        guard genesis.structuralIntegrityValid, genesis.semanticProjectionValid,
              genesis.work == work, genesis.workHost == host, genesis.journal == journal,
              genesis.sessionAttachments[
                registration.reservation.sessionAttachment.attachmentID].map({
                    $0.attachment == registration.reservation.sessionAttachment
                        && $0.session == registration.reservation.session
                        && $0.isAttached
                }) == true else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return HistoryCanonicalWorkSource(
            registration: registration, workCache: cache, workState: state,
            workCursor: JournalCursor(
                journal: journal, eventID: last.eventID, sequence: last.sequence))
    }

    private func historyRelationshipIsCanonical(
        work: WorkRef,
        session: SessionRef,
        journal: JournalRef,
        sessionAttachment: SessionAttachmentRef,
        relationshipEvents: [TimelineEvent],
        source: HistoryCanonicalWorkSource,
        control: WorkHostControlSnapshot
    ) async throws -> Bool {
        let reservation = source.registration.reservation
        guard currentHistorySessionRelationshipIsAttached(
            relationshipEvents, session: session, work: work,
            attachment: sessionAttachment) else {
            return false
        }
        if session == reservation.session,
           journal == source.registration.sessionJournal,
           sessionAttachment == reservation.sessionAttachment {
            return source.workState.sessionAttachments[
                sessionAttachment.attachmentID].map({
                    $0.attachment == sessionAttachment && $0.session == session
                        && $0.isAttached
                }) == true
                && primaryHistoryRelationshipIsCanonical(
                    relationshipEvents: relationshipEvents, source: source)
        }

        // An alternate Session cannot substitute for the registered creation pair. Authenticate
        // that fixed pair through its own metadata-only index before validating the requested
        // Session publication below.
        let primaryReader = try LocalSessionHistoryProjectionReader(
            home: home, session: reservation.session,
            journal: source.registration.sessionJournal,
            indexDirectory: sessionHistoryIndexDirectory(
                for: source.registration.sessionJournal))
        let primary = try primaryReader.readCurrentRelationshipAuthority()
        incrementHistoryMetrics(primary.metrics)
        guard currentHistorySessionRelationshipIsAttached(
                primary.relationshipEvents,
                session: reservation.session, work: reservation.work,
                attachment: reservation.sessionAttachment),
              primaryHistoryRelationshipIsCanonical(
                relationshipEvents: primary.relationshipEvents, source: source),
              source.workState.sessionAttachments[
                reservation.sessionAttachment.attachmentID].map({
                    $0.attachment == reservation.sessionAttachment
                        && $0.session == reservation.session && $0.isAttached
                }) == true else {
            return false
        }

        let candidates = control.sessionCreations.values.filter {
            !$0.isConflicted && $0.reservation.work == work
                && $0.reservation.session == session
                && $0.reservation.sessionJournal == journal
                && $0.reservation.sessionAttachment == sessionAttachment
        }
        guard candidates.count == 1, let creation = candidates.first,
              let publication = creation.result,
              publication.publication == "mirrored"
                || publication.publication == "terminal_reference",
              publication.causalWorkCursor == creation.reservation.causalWorkCursor,
              publication.causalSessionCursor.journal == journal,
              publication.causalSessionCursor.sequence == 0,
              publication.causalSessionCursor.eventID == nil,
              publication.sessionCursor.journal == journal,
              publication.sessionCreatedEvent.journal == journal,
              publication.sessionAttachedEvent.journal == journal,
              publication.cursorAdvancedEvent.journal == journal,
              let created = relationshipEvent(
                publication.sessionCreatedEvent, in: relationshipEvents),
              let attached = relationshipEvent(
                publication.sessionAttachedEvent, in: relationshipEvents),
              let advanced = relationshipEvent(
                publication.cursorAdvancedEvent, in: relationshipEvents),
              created.type == TimelineEventType.sessionCreated,
              created.sequence == 1, created.previousEventID == nil,
              created.session == session, created.work == nil,
              created.workHost == nil, created.client == nil,
              created.sessionAttachment == nil, created.causedByEventID == nil,
              attached.type == TimelineEventType.sessionAttached,
              attached.sequence == 2,
              attached.previousEventID == created.eventID,
              attached.session == session, attached.work == work,
              attached.workHost == host,
              attached.client == creation.reservation.client,
              attached.sessionAttachment == sessionAttachment,
              attached.causedByEventID == EventRef(
                journal: journal, eventID: created.eventID),
              historyCapabilities(in: attached) == publication.capabilities.sorted(),
              advanced.type == TimelineEventType.sessionAttachmentCursorAdvanced,
              advanced.sequence == 3,
              advanced.previousEventID == attached.eventID,
              advanced.session == session, advanced.work == work,
              advanced.workHost == host,
              advanced.client == creation.reservation.client,
              advanced.sessionAttachment == sessionAttachment,
              historyCapabilities(in: advanced) == publication.capabilities.sorted(),
              historyRecordedWorkCursor(in: advanced) == publication.resultingWorkCursor,
              publication.sessionCursor == JournalCursor(
                journal: journal, eventID: advanced.eventID,
                sequence: advanced.sequence) else {
            return false
        }
        let publicationCommand = CommandRef(
            commandID: creation.reservation.command.commandID,
            client: creation.reservation.client,
            sessionAttachment: sessionAttachment,
            causalCursor: publication.causalWorkCursor)
        guard historyProducerEnvelope(
                created, idempotencyKey: publicationCommand.commandID,
                command: publicationCommand, declaredDomains: [.session]),
              created.hostSequence.map({ $0 > 0 }) == true,
              created.payload == .object([:]),
              historyProducerEnvelope(
                attached, idempotencyKey: publicationCommand.commandID,
                command: publicationCommand, declaredDomains: [.session, .work]),
              attached.hostSequence == created.hostSequence.map({ $0 + 1 }),
              attached.actor == created.actor,
              attached.payload == historyCapabilitiesPayload(publication.capabilities),
              historyProducerEnvelope(
                advanced, idempotencyKey: publicationCommand.commandID,
                command: publicationCommand, declaredDomains: [.session, .work]),
              advanced.actor == created.actor,
              advanced.payload == historyCursorPayload(
                publication.resultingWorkCursor,
                capabilities: publication.capabilities) else {
            return false
        }

        if publication.publication == "mirrored" {
            guard source.workState.sessionAttachments[
                    sessionAttachment.attachmentID].map({
                        $0.attachment == sessionAttachment && $0.session == session
                            && $0.isAttached
                    }) == true,
                  let mirrorRef = publication.workMirrorEvent,
                  mirrorRef.journal == source.registration.workJournal,
                  publication.resultingWorkCursor.journal == mirrorRef.journal,
                  publication.resultingWorkCursor.eventID == mirrorRef.eventID,
                  let mirror = try await exactWorkEvent(
                    at: publication.resultingWorkCursor,
                    after: publication.causalWorkCursor, source: source),
                  mirror.eventID == mirrorRef.eventID,
                  mirror.type == TimelineEventType.sessionAttached,
                  mirror.session == session, mirror.work == work,
                  mirror.workHost == host,
                  mirror.client == creation.reservation.client,
                  mirror.sessionAttachment == sessionAttachment,
                  mirror.causedByEventID == EventRef(
                    journal: journal, eventID: attached.eventID),
                  historyCapabilities(in: mirror) == publication.capabilities.sorted(),
                  historyProducerEnvelope(
                    mirror, idempotencyKey: publicationCommand.commandID,
                    command: publicationCommand, declaredDomains: [.work, .session]),
                  mirror.actor == created.actor,
                  mirror.hostSequence == attached.hostSequence.map({ $0 + 1 }),
                  mirror.payload == historyCapabilitiesPayload(publication.capabilities),
                  advanced.hostSequence == mirror.hostSequence.map({ $0 + 1 }),
                  advanced.causedByEventID == mirrorRef else {
                return false
            }
        } else {
            guard publication.workMirrorEvent == nil,
                  publication.resultingWorkCursor == publication.causalWorkCursor,
                  source.workCursor == publication.causalWorkCursor,
                  let terminal = source.workCache.lastRecord?.event,
                  [TimelineEventType.workCompleted, TimelineEventType.workDestroyed,
                   TimelineEventType.workFailed].contains(terminal.type),
                  JournalCursor(
                    journal: source.registration.workJournal,
                    eventID: terminal.eventID, sequence: terminal.sequence)
                    == publication.causalWorkCursor,
                  advanced.causedByEventID == EventRef(
                    journal: source.registration.workJournal,
                    eventID: terminal.eventID),
                  advanced.hostSequence == attached.hostSequence.map({ $0 + 1 }) else {
                return false
            }
        }
        return true
    }

    /// Resolve the current known attach/detach state from canonical rows reread under the
    /// history reader's latest source lease. The immutable creation row proves provenance; this
    /// latest transition prevents a later Session detach from leaving that old proof usable.
    private func currentHistorySessionRelationshipIsAttached(
        _ events: [TimelineEvent],
        session: SessionRef,
        work: WorkRef,
        attachment: SessionAttachmentRef
    ) -> Bool {
        let latest = events.filter {
            $0.session == session && $0.sessionAttachment == attachment
                && ($0.type == TimelineEventType.sessionAttached
                    || $0.type == TimelineEventType.sessionDetached)
        }.max { $0.sequence < $1.sequence }
        guard let latest, latest.type == TimelineEventType.sessionAttached,
              latest.work == work else {
            return false
        }
        return true
    }

    private func historyFinalControlIsAuthorized(
        _ final: WorkHostControlSnapshot,
        initialControl: WorkHostControlSnapshot,
        request: WorkServiceHistoryRequest,
        session: SessionRef,
        journal: JournalRef,
        sessionAttachment: SessionAttachmentRef,
        registration: WorkHostControlWorkRegistration
    ) -> Bool {
        guard final.structuralIntegrityValid, final.semanticProjectionValid,
              final.unknownEvents.isEmpty,
              final.workHost == host,
              let clientAttachment = final.clientAttachments[
                request.attachment.attachmentID],
              clientAttachment.attachment == request.attachment,
              clientAttachment.work == request.work,
              clientAttachment.workJournal == request.journal,
              clientAttachment.client == request.client,
              clientAttachment.session == session,
              clientAttachment.sessionJournal == journal,
              clientAttachment.sessionAttachment == sessionAttachment,
              clientAttachment.isAttached,
              clientAttachment.capabilities.contains(
                WorkServiceCapability.observe.rawValue) else {
            return false
        }
        let finalCreations = final.creations.values.filter {
            $0.reservation.work == request.work
                && $0.registration?.workJournal == request.journal
                && !$0.isConflicted && $0.registration == registration
        }
        guard finalCreations.count == 1 else { return false }

        let reservation = registration.reservation
        if session == reservation.session,
           journal == registration.sessionJournal,
           sessionAttachment == reservation.sessionAttachment {
            return true
        }
        func selectedCreation(
            _ control: WorkHostControlSnapshot
        ) -> WorkHostControlSessionCreationSnapshot? {
            let values = control.sessionCreations.values.filter {
                !$0.isConflicted && $0.abort == nil
                    && $0.reservation.work == request.work
                    && $0.reservation.session == session
                    && $0.reservation.sessionJournal == journal
                    && $0.reservation.sessionAttachment == sessionAttachment
            }
            return values.count == 1 ? values[0] : nil
        }
        guard let initial = selectedCreation(initialControl),
              let current = selectedCreation(final), current == initial else {
            return false
        }
        return true
    }

    private func primaryHistoryRelationshipIsCanonical(
        relationshipEvents: [TimelineEvent],
        source: HistoryCanonicalWorkSource
    ) -> Bool {
        let registration = source.registration
        let reservation = registration.reservation
        guard registration.sessionGenesisCursor.journal == registration.sessionJournal,
              registration.sessionGenesisCursor.sequence == 2,
              let attachedID = registration.sessionGenesisCursor.eventID,
              let attached = relationshipEvent(
                EventRef(journal: registration.sessionJournal, eventID: attachedID),
                in: relationshipEvents),
              let created = relationshipEvents.first(where: {
                  $0.type == TimelineEventType.sessionCreated && $0.sequence == 1
              }),
              created.previousEventID == nil,
              created.session == reservation.session, created.work == nil,
              created.workHost == nil, created.client == nil,
              created.sessionAttachment == nil, created.causedByEventID == nil,
              JournalCursor(
                journal: attached.journal, eventID: attached.eventID,
                sequence: attached.sequence) == registration.sessionGenesisCursor,
              attached.type == TimelineEventType.sessionAttached,
              attached.previousEventID == created.eventID,
              attached.session == reservation.session,
              attached.work == reservation.work,
              attached.workHost == nil, attached.client == nil,
              attached.sessionAttachment == reservation.sessionAttachment,
              attached.causedByEventID == nil,
              historyCapabilities(in: attached) == [],
              registration.workGenesisCursor.journal == registration.workJournal,
              registration.workGenesisCursor.sequence == 2,
              source.workCache.prefixRecords.count >= 2 else {
            return false
        }
        let workCreated = source.workCache.prefixRecords[0].event
        let workAttached = source.workCache.prefixRecords[1].event
        let valid = historyProducerEnvelope(
                created, idempotencyKey: nil, command: nil,
                declaredDomains: [.session])
            && created.hostSequence == 1 && created.payload == .object([:])
            && historyProducerEnvelope(
                attached, idempotencyKey: nil, command: nil,
                declaredDomains: [.session, .work])
            && attached.actor == created.actor && attached.hostSequence == 3
            && attached.payload == historyCapabilitiesPayload([])
            && workCreated.type == TimelineEventType.workCreated
            && workCreated.sequence == 1 && workCreated.previousEventID == nil
            && workCreated.work == reservation.work && workCreated.workHost == host
            && workCreated.session == nil && workCreated.sessionAttachment == nil
            && workCreated.causedByEventID == nil && workCreated.client == nil
            && historyProducerEnvelope(
                workCreated, idempotencyKey: nil, command: nil,
                declaredDomains: [.work])
            && workCreated.actor == created.actor && workCreated.hostSequence == 2
            && workCreated.payload == .object([:])
            && workAttached.type == TimelineEventType.sessionAttached
            && workAttached.sequence == 2
            && workAttached.previousEventID == workCreated.eventID
            && workAttached.work == reservation.work
            && workAttached.workHost == host
            && workAttached.session == reservation.session
            && workAttached.client == nil
            && workAttached.sessionAttachment == reservation.sessionAttachment
            && workAttached.causedByEventID == EventRef(
                journal: attached.journal, eventID: attached.eventID)
            && historyCapabilities(in: workAttached) == []
            && historyProducerEnvelope(
                workAttached, idempotencyKey: nil, command: nil,
                declaredDomains: [.work, .session])
            && workAttached.actor == created.actor && workAttached.hostSequence == 4
            && workAttached.payload == historyCapabilitiesPayload([])
            && registration.workGenesisCursor == JournalCursor(
                journal: registration.workJournal,
                eventID: workAttached.eventID, sequence: workAttached.sequence)
        return valid
    }

    private func relationshipEvent(
        _ reference: EventRef,
        in events: [TimelineEvent]
    ) -> TimelineEvent? {
        let matching = events.filter {
            $0.journal == reference.journal && $0.eventID == reference.eventID
        }
        return matching.count == 1 ? matching[0] : nil
    }

    private func exactWorkEvent(
        at cursor: JournalCursor,
        after predecessor: JournalCursor,
        source: HistoryCanonicalWorkSource
    ) async throws -> TimelineEvent? {
        guard cursor.journal == source.registration.workJournal,
              predecessor.journal == cursor.journal,
              cursor.sequence == predecessor.sequence + 1 else { return nil }
        if source.workCache.isFullyResident,
           (predecessor.sequence == 0
                ? predecessor.eventID == nil
                : source.workCache.sequenceToIndex[predecessor.sequence].flatMap({ index in
                    index < source.workCache.result.records.count
                        ? source.workCache.result.records[index].event.eventID : nil
                }) == predecessor.eventID),
           let index = source.workCache.sequenceToIndex[cursor.sequence],
           index < source.workCache.result.records.count {
            let event = source.workCache.result.records[index].event
            return event.eventID == cursor.eventID
                    && event.sequence == cursor.sequence
                    && event.previousEventID == predecessor.eventID
                ? event : nil
        }
        let page: Page
        do {
            page = try await self.page(
                entry: source.workCache, journal: source.registration.workJournal,
                expectedURL: home.timelineV2WorkJournalURL(
                    source.registration.reservation.work),
                after: predecessor,
                target: .work(journal: source.registration.workJournal),
                limit: 1, maxBytes: WorkServiceBounds.maxEventPageBytes)
        } catch WorkServiceProtocolError.staleCursor {
            // This cursor comes from durable relationship evidence rather than the caller's
            // paging position. A fabricated predecessor means the relationship projection is
            // incomplete; it is not a useful stale-cursor repair instruction for the GUI.
            return nil
        }
        guard page.events.count == 1, let event = page.events.first,
              event.eventID == cursor.eventID, event.sequence == cursor.sequence,
              event.previousEventID == predecessor.eventID else {
            return nil
        }
        return event
    }

    private func historyCapabilities(in event: TimelineEvent) -> [String]? {
        guard let values = event.payload["capabilities"]?.arrayValue else { return nil }
        let result = values.compactMap(\.stringValue)
        return result.count == values.count ? result.sorted() : nil
    }

    private func historyRecordedWorkCursor(in event: TimelineEvent) -> JournalCursor? {
        event.payload["cursor"].flatMap { decodeTimelineValue($0) }
    }

    private func historyProducerEnvelope(
        _ event: TimelineEvent,
        idempotencyKey: String?,
        command: CommandRef?,
        declaredDomains: Set<TimelineDomain>
    ) -> Bool {
        event.schemaVersion == TimelineEvent.currentSchemaVersion
            && event.payloadVersion == 1
            && event.provenance == .native
            && event.idempotencyKey == idempotencyKey
            && event.command == command
            && event.parentActivityID == nil
            && event.conversationParent == nil
            && event.clientAttachment == nil
            && event.run == nil
            && event.turn == nil
            && event.action == nil
            && event.handle == nil
            && event.clientTimestamp == nil
            && event.omittedEvidenceLinkCount == nil
            && event.links.isEmpty
            && event.declaredDomains == declaredDomains
    }

    private func historyCapabilitiesPayload(_ capabilities: [String]) -> JSONValue {
        .object([
            "capabilities": .array(capabilities.sorted().map(JSONValue.string))
        ])
    }

    private func historyCursorPayload(
        _ cursor: JournalCursor, capabilities: [String]
    ) -> JSONValue {
        .object([
            "capabilities": .array(capabilities.sorted().map(JSONValue.string)),
            "cursor": historyEncodedValue(cursor),
        ])
    }

    private func historyEncodedValue<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = JSONValue.parse(data) else {
            return .null
        }
        return decoded
    }

    private func sessionHistoryIndexDirectory(for journal: JournalRef) -> URL {
        let material = "session-history-v4\0\(journal.stableKey)"
        let key = AviarySHA256.hash(data: Data(material.utf8)).description
        return home.timelineV2Dir
            .appending(path: "projections", directoryHint: .isDirectory)
            .appending(path: "session-history-v4", directoryHint: .isDirectory)
            .appending(path: key, directoryHint: .isDirectory)
    }

    /// Admit a Hosted actor only as part of an explicit Start. Create deliberately leaves the
    /// Work pair idle, so this is the sole service path that appends a `run.started` marker. An
    /// ended actor is replaced under the registry's same Work/Session/attachment fence; it is
    /// never submitted a command after its lifecycle has closed.
    private func admitStartActor(
        work: WorkRef,
        source: CanonicalSource,
        client: ClientRef,
        commandID: String,
        causalWorkCursor: JournalCursor,
        prompt: String,
        binding: WorkBinding
    ) async throws -> StartActorAdmission {
        let key = startAdmissionKey(
            work: work, binding: binding, client: client, commandID: commandID,
            causalWorkCursor: causalWorkCursor, prompt: prompt)
        let intent = key.intent
        if let existing = startsInProgress[key] {
            // Await the exact opener task. Once it returns the caller continues through the
            // Hosted command ledger, whose command-ID idempotency makes the duplicate receipt
            // converge without a second provider Run or prompt assembly.
            return StartActorAdmission(entry: try await existing.value, ownsTask: false)
        }
        let task = Task { [self] in
            try await performStartActor(
                work: work, source: source, client: client, commandID: commandID,
                prompt: prompt, intent: intent, selectedBinding: binding)
        }
        startsInProgress[key] = task
        do {
            let result = try await task.value
            return StartActorAdmission(entry: result, ownsTask: true)
        } catch {
            startsInProgress.removeValue(forKey: key)
            throw error
        }
    }

    private func performStartActor(
        work: WorkRef,
        source: CanonicalSource,
        client: ClientRef,
        commandID: String,
        prompt: String,
        intent: WorkLaunchStartIntent,
        selectedBinding: WorkBinding
    ) async throws -> WorkHostRegistryLiveEntry {
        guard source.workState.lifecycle == .active else {
            throw WorkServiceProtocolError.invalidRequest("Start requires an active Work")
        }

        var endedEntry: WorkHostRegistryLiveEntry?
        if let lookup = await registry.lookup(work) {
            switch lookup {
            case .live(let entry):
                let snapshot = await entry.hostedWork.snapshot()
                switch snapshot.lifecycle {
                case .ended where snapshot.journalHealth == .closed:
                    endedEntry = entry
                case .prepared, .preparing, .idle, .running, .canceling, .ending:
                    guard source.workState.activeRun == nil else {
                        throw WorkServiceProtocolError.sourceIncomplete
                    }
                    return entry
                case .ended, .failed:
                    throw WorkServiceProtocolError.hostUnavailable(host)
                }
            case .historical, .recovering, .unavailable:
                throw WorkServiceProtocolError.hostUnavailable(host)
            }
        }

        guard let store = manifestStore else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        // Always re-read the Work-level template. A cached closure or descriptor is not restart
        // proof and can otherwise let two concurrent Start calls race on stale launch material.
        let base: JournalBackedWorkLaunchManifest
        if let resolved = try await store.resolve(
            work: work, session: selectedBinding.session,
            sessionAttachment: selectedBinding.sessionAttachment) {
            manifests[work] = resolved
            base = resolved
        } else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        // The first Start caller observes the idle Work tip. During the narrow opener window the
        // canonical tip advances to run.started; the exact predecessor remains the causal
        // identity retained by the durable Start intent and by RunJournalBundle's bridge.
        let recoveryCursor = startPredecessorCursor(source)
        let intentCursor = recoveryCursor ?? source.workCursor

        guard intent.causalWorkCursor == intentCursor,
              intent.bodyDigest == digest(Data(prompt.utf8)) else {
            throw WorkServiceProtocolError.invalidRequest("Start intent changed during admission")
        }
        let hasFinishedRun = source.workCache.runFinishedExists
        let replacingEndedRun = endedEntry != nil || hasFinishedRun
        let workBinding = WorkBinding(
            session: selectedBinding.session, work: work, workHost: host,
            sessionAttachment: selectedBinding.sessionAttachment)
        let prior = try await store.resolveStart(
            work: work, session: selectedBinding.session,
            sessionAttachment: selectedBinding.sessionAttachment, intent: intent)
        var recoveringStartedRun = false
        if let priorRun = prior?.identity?.run, source.workState.activeRun == priorRun {
            guard recoveryCursor != nil else { throw WorkServiceProtocolError.sourceIncomplete }
            recoveringStartedRun = true
        }
        let predecessorRun = source.workCache.latestRunFinished
        let launchPolicy: WorkLaunchExecutionPolicy
        var selectedPromptAssembly: WorkLaunchPromptAssembly?
        if recoveringStartedRun, let prior,
           let priorPolicy = prior.durableRecord?.manifest.resumePolicy {
            // Exact admission retries reuse the policy already persisted for that Run. The
            // current Work marker is not a new historical replacement and must not reclassify a
            // fresh first Start as cold merely because its flat boundary exists.
            launchPolicy = WorkLaunchExecutionPolicy(
                projection: .fresh,
                modelContext: priorPolicy.mode == .coldResume
                    ? .exactColdResume : .launchFresh,
                sourceSession: priorPolicy.sourceSession,
                sourceRun: priorPolicy.sourceRun)
        } else if replacingEndedRun {
            guard let predecessorRun else { throw WorkServiceProtocolError.sourceIncomplete }
            // Cold replay is only valid when the latest finished Run was owned by this exact
            // selected Session/attachment. When ownership alternates across Sessions, the
            // selected Session has no exact predecessor crossing; reopening it with a fresh
            // context is the safe, reusable Work path.
            let predecessorBinding = latestFinishedRunBinding(source, run: predecessorRun)
            let priorContext: NativeColdResumeResult?
            if predecessorBinding == workBinding {
                do {
                    priorContext = try NativeSessionCommandJournal.preflightPriorContext(
                        home: home, binding: workBinding)
                } catch NativeColdResumeError.noCompleteContextManifest {
                    // This is the ordinary empty/no-crossing predecessor. Historical projection
                    // reopening remains required, but the provider receives a fresh context.
                    priorContext = nil
                } catch {
                    // A recorded crossing with incomplete/corrupt retained state is not
                    // equivalent to "no context". Refuse before publishing the replacement Run.
                    throw WorkServiceProtocolError.sourceIncomplete
                }
            } else {
                priorContext = nil
            }
            if let priorContext {
                // The native bridge will replay this exact predecessor assembly. A source-less
                // predecessor cannot claim exact cold parity, and current ambient inputs are not
                // a valid substitute for the recorded crossing.
                let materializedAssembly = priorContext.systemPromptAssembly
                guard let durableAssembly = try await store.resolvePromptAssemblyRecord(
                          work: work, session: workBinding.session,
                          sessionAttachment: workBinding.sessionAttachment, run: predecessorRun),
                      let recordedAssembly = try? durableAssembly.materialize(
                          using: ContextBodyStore(home: home)),
                      recordedAssembly == materializedAssembly else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                selectedPromptAssembly = durableAssembly
            }
            // A newly selected Session may have canonical native attachment history but no
            // prior flat projection yet. Reopen the selected Session's existing projection
            // only when it owns the immediately preceding Run; an alternating owner gets a
            // genuinely fresh projection while the Work-level Run remains a replacement.
            // A Session may alternate ownership after End. Its existing Aviary flat projection
            // is safe to reopen even when the new context is launch-fresh; an untouched Session
            // has no projection yet and must use the staged fresh path.
            let selectedProjectionURL = home.sessionFile(id: selectedBinding.session.sessionID)
            let projection: WorkLaunchProjectionMode = predecessorBinding == workBinding
                || FileManager.default.fileExists(atPath: selectedProjectionURL.path)
                ? .reopenHistorical : .fresh
            launchPolicy = WorkLaunchExecutionPolicy(
                projection: projection,
                modelContext: priorContext == nil ? .launchFresh : .exactColdResume,
                sourceSession: priorContext == nil ? nil : selectedBinding.session,
                sourceRun: priorContext == nil ? nil : predecessorRun)
        } else {
            launchPolicy = WorkLaunchExecutionPolicy(
                projection: .fresh, modelContext: .launchFresh)
        }
        let manifest: JournalBackedWorkLaunchManifest
        if let prior {
            // If the opener crashed before run.started, the exact durable pointer can safely be
            // continued with the same Run. Once run.started exists, however, a missing live actor
            // is recovery-required; this service must not claim liveness from a journal marker.
            guard let priorRun = prior.identity?.run else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            if source.workState.activeRun == priorRun {
                guard recoveryCursor != nil else { throw WorkServiceProtocolError.sourceIncomplete }
                recoveringStartedRun = true
            }
            guard source.workState.activeRun == nil || recoveringStartedRun else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            // Re-submit the exact durable Run through bindStart. For a pending pointer this
            // repairs the Work-level selection; for an already-current record it is an idempotent
            // read. It never mints a second Run for this Start identity.
            manifest = try await store.bindStart(
                prior,
                binding: workBinding,
                run: priorRun,
                intent: intent,
                body: Data(prompt.utf8),
                policy: launchPolicy,
                selectedPromptAssembly: nil)
        } else {
            // Every successful Start gets one fresh Run generation. A retry of an already
            // admitted Start returned above from its exact durable pointer; it never reaches
            // this minting path.
            // A durable active Run is an unresolved admission, not an indication that this
            // Work is available for another replacement. Only the exact Start intent branch
            // above may recover that trailing marker; a different command must not supersede it.
            guard source.workState.activeRun == nil else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            let run = RunRef("run-" + UUID().uuidString.lowercased())
            let binding = WorkRunBinding(
                workBinding: WorkBinding(
                    session: selectedBinding.session, work: work, workHost: host,
                    sessionAttachment: selectedBinding.sessionAttachment), run: run)
            // A replacement has a new Run identity but the exact same logical Work binding. The
            // manifest store publishes this generation and its Work-level current-start pointer
            // before any journal opener runs. Its compare-and-swap is the durable half of the
            // in-process `startsInProgress` gate.
            manifest = try await store.bindStart(
                base, binding: binding.workBinding, run: run, intent: intent,
                body: Data(prompt.utf8),
                policy: launchPolicy,
                selectedPromptAssembly: selectedPromptAssembly)
        }
        try validateManifest(manifest)
        manifests[work] = manifest
        guard let run = manifest.identity?.run else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let binding = WorkRunBinding(
            workBinding: WorkBinding(
                session: selectedBinding.session, work: work, workHost: host,
                sessionAttachment: selectedBinding.sessionAttachment), run: run)
        try validateStartManifest(
            manifest, intent: intent, body: Data(prompt.utf8), binding: binding)
        let configuration = try await hostedConfiguration(
            manifest, binding: binding, policy: launchPolicy)
        guard let configuration,
              attestHostedConfiguration(
                  configuration, manifest: manifest, binding: binding,
                  policy: launchPolicy) else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        if endedEntry != nil {
            // Registry replacement opens exactly one new actor under its same Work/Session/
            // attachment fence. Do not open a second actor here.
            return try await registry.replace(
                work, configuration: configuration,
                launchMetadata: manifest.launchMetadata)
        }
        // Reserve the registry slot before Hosted construction. Opening writes the durable
        // run.started marker and acquires native/flat writer locks; a post-open capacity failure
        // would otherwise strand an indexed, unaccepted Run and poison its exact retry. The
        // actor-isolated reservation counts against both caps and fences this Work until commit.
        let reservation = try await registry.reserveRegistration(
            for: work, launchMetadata: manifest.launchMetadata)
        do {
            let hosted = try await HostedInHouseWork.open(configuration: configuration)
            do {
                return try await registry.commitRegistration(reservation, hostedWork: hosted)
            } catch {
                // commit can fail only for an invalid token/identity or an unexpected future
                // registry mutation. Release the unadopted actor before dropping it; the exact
                // reservation is cancelled regardless of the failure path.
                await closeUnadoptedActor(hosted)
                await registry.cancelRegistration(reservation)
                throw error
            }
        } catch {
            await registry.cancelRegistration(reservation)
            throw error
        }
    }

    private func closeUnadoptedActor(_ hosted: HostedInHouseWork) async {
        let snapshot = await hosted.snapshot()
        guard snapshot.lifecycle != .ended,
              let causalCursor = snapshot.latestWorkCursor else { return }
        let cleanup = HostedInHouseWorkCommand(
            work: snapshot.identity.work,
            session: SessionRef(snapshot.identity.sessionID),
            sessionAttachment: snapshot.sessionAttachment,
            client: ClientRef("work-host-registry-cleanup"),
            commandID: "registry-cleanup-" + UUID().uuidString.lowercased(),
            causalCursor: causalCursor,
            command: .endRun)
        _ = try? await hosted.submit(cleanup)
    }

    private func hostedConfiguration(
        _ manifest: JournalBackedWorkLaunchManifest,
        binding: WorkRunBinding,
        policy: WorkLaunchExecutionPolicy
    ) async throws -> HostedInHouseWorkConfiguration? {
        if let resolver = manifest.hostedConfigurationAsync {
            return try await resolver(binding, policy)
        }
        return manifest.hostedConfiguration?(binding)
    }

    /// The provider resolver is an effectful boundary and may run after a daemon restart.  A
    /// nonnil result is not enough: every executable fact which survived in the host-private
    /// manifest must still match the materialized configuration before it can open writers or
    /// start a provider.  In particular, a changed workspace/model/system context is drift, not
    /// a best-effort reconstruction.
    private func attestHostedConfiguration(
        _ configuration: HostedInHouseWorkConfiguration,
        manifest: JournalBackedWorkLaunchManifest,
        binding: WorkRunBinding,
        policy: WorkLaunchExecutionPolicy
    ) -> Bool {
        guard configuration.home == home,
              configuration.workRunBinding == binding,
              configuration.projectionMode == policy.projection,
              configuration.modelContextMode == policy.modelContext,
              manifest.durableRecord?.manifest.resumePolicy == policy.resumePolicy,
              let draft = manifest.template?.template.draft else {
            return false
        }
        guard configuration.cwd == draft.workspace.locator,
              configuration.model.providerID == draft.runtime.providerID,
              configuration.model.id == draft.runtime.modelID,
              configuration.recordPayloads == draft.recordingPolicy.recordPayloads,
              configuration.reasoningEffort == draft.reasoningPolicy.level,
              // These fields have no corresponding executable knobs in Hosted yet.  Accept only
              // their explicit defaults until a typed field is added; silently dropping a
              // persisted budget/goal/hook/context policy would make restart reconstruction
              // claim a different run than the one the client created.
              draft.contextPolicy == WorkLaunchContextPolicy(),
              draft.recordingPolicy.wireLogLocator == nil,
              draft.reasoningPolicy.enabled == false,
              draft.reasoningPolicy.tokenBudget == nil,
              draft.budgetPolicy.maximumTokens == nil,
              draft.budgetPolicy.maximumWallClockSeconds == nil,
              draft.goal == WorkLaunchGoalConfiguration(),
              draft.hooks.isEmpty,
              draft.peerScheduler == WorkLaunchPeerSchedulerConfiguration(),
              configuration.maxIterations == (draft.budgetPolicy.maximumTurns ?? 40),
              configuration.maxDepth == (draft.budgetPolicy.maximumDepth ?? 3),
              configuration.childMaxIterations ==
                  (draft.budgetPolicy.childMaximumTurns ?? 20),
              configuration.hookPaths.isEmpty else {
            return false
        }
        guard let assembly = manifest.durableRecord?.manifest.promptAssembly,
              let configuredAssembly = configuration.systemPromptAssembly,
              let retainedAssembly = try? assembly.materialize(
                  using: ContextBodyStore(home: home)),
              configuredAssembly == retainedAssembly,
              configuredAssembly.flattenedDigest == assembly.flattenedDigest,
              digest(Data(configuration.systemPrompt.utf8)) == assembly.flattenedDigest else {
            // A final native launch without the retained assembly is source-less and must fail
            // closed. The Run-free template is intentionally not a fallback prompt source.
            return false
        }
        return true
    }

    private func resolveStartManifest(
        work: WorkRef,
        source: CanonicalSource,
        client: ClientRef,
        commandID: String,
        prompt: String,
        binding: WorkBinding
    ) async throws -> JournalBackedWorkLaunchManifest? {
        guard let store = manifestStore else { return nil }
        let key = qualifiedCommandID(clientID: client.clientID, commandID: commandID)
        guard let prior = source.workState.commands[key],
              prior.command.client == client,
              prior.command.commandID == key,
              let causalCursor = prior.command.causalCursor else {
            return nil
        }
        guard try await store.resolve(
            work: work, session: binding.session,
            sessionAttachment: binding.sessionAttachment)
                != nil else { return nil }
        let intent = WorkLaunchStartIntent(
            client: client, commandID: commandID, causalWorkCursor: causalCursor,
            bodyDigest: digest(Data(prompt.utf8)))
        if let current = try await store.resolveStart(
            work: work, session: binding.session,
            sessionAttachment: binding.sessionAttachment, intent: intent) {
            return current
        }
        return nil
    }

    /// A registry `.live` case is only an ownership record. It becomes a command/liveness proof
    /// after the actor snapshot still matches the canonical Work/Session/attachment/Run tuple
    /// and reports healthy connected writers. A stale or disconnected actor must not authorize a
    /// command merely because the registry retains a reference to it.
    private func exactLiveHostedActor(
        _ entry: WorkHostRegistryLiveEntry,
        source: CanonicalSource,
        binding: WorkBinding
    ) async -> Bool {
        let snapshot = await entry.hostedWork.snapshot()
        guard snapshot.identity.work == source.registration.reservation.work,
              snapshot.identity.sessionID == binding.session.sessionID,
              snapshot.sessionAttachment == binding.sessionAttachment,
              snapshot.runtimeState == .connected,
              snapshot.journalHealth == .healthy,
              snapshot.lifecycle != .failed else { return false }
        guard let activeRun = source.workState.activeRun else {
            // During the narrow Start opener window the actor is prepared before the marker is
            // visible to the Work reducer. It is safe to use only for Start; callers with a
            // durable idle source are handled by the command recovery guard above.
            return snapshot.lifecycle == .prepared || snapshot.lifecycle == .idle
        }
        return snapshot.identity.runID == activeRun.runID
    }

    /// Prove the only restart repair permitted for a Run-bound Start admission. The durable
    /// selection, caller identity, causal Work cursor, and retained prompt bytes must all match;
    /// a same-text command with a different cursor/identity remains a new unproven admission.
    private func isExactStartRecoveryRetry(
        _ request: WorkServiceCommandRequest,
        source: CanonicalSource,
        client: ClientRef,
        binding: WorkBinding
    ) async throws -> Bool {
        guard request.kind == .start, let store = manifestStore else { return false }
        let intent = WorkLaunchStartIntent(
            client: client, commandID: request.command.commandID,
            causalWorkCursor: request.causalWorkCursor,
            bodyDigest: digest(Data((request.value ?? "").utf8)))
        let selection = try await store.currentSelection(
            work: source.registration.reservation.work,
            session: binding.session,
            sessionAttachment: binding.sessionAttachment)
        if let record = selection {
            guard record.manifest.identity.work == request.work,
                  record.manifest.identity.session == binding.session,
                  record.manifest.identity.sessionAttachment == binding.sessionAttachment,
                  record.manifest.startIntent == intent,
                  startBodyMatches(request.value ?? "", record: record) else { return false }
            let run = record.manifest.identity.run

            if source.workState.activeRun == nil {
                // The pre-marker crash window: the selection is durable, but no canonical marker
                // has yet been appended. The opener may mint no new Run; it must continue this
                // one.
                return !source.workCache.runStartedIDs.contains(run.runID)
            }

            // If the marker is already canonical, only its untouched immediate predecessor
            // remains eligible for the bridge. Any later event makes recovery indeterminate and
            // therefore rejects even an otherwise matching retry.
            guard source.workState.activeRun == run,
                  let predecessor = startPredecessorCursor(source),
                  predecessor == request.causalWorkCursor else { return false }
            return true
        }

        // A crash after prompt assembly has been retained but before the final Run manifest was
        // published leaves only the binding reservation. It is safe to continue exactly that
        // reservation when its persisted assembly is present; a reservation without assembly
        // remains recovery-required and must never call the ambient resolver again.
        guard let reservation = try await store.resolveStartReservation(
            work: source.registration.reservation.work,
            session: binding.session,
            sessionAttachment: binding.sessionAttachment,
            intent: intent), reservation.promptAssembly != nil else {
            return false
        }
        return true
    }

    /// Return the Work cursor immediately before an untouched trailing `run.started` marker.
    /// This is the only cursor a one-call Start retry may use after the opener has crossed the
    /// marker boundary; any later canonical event makes the reservation recovery-required.
    private func startPredecessorCursor(_ source: CanonicalSource) -> JournalCursor? {
        guard source.workState.activeRun != nil,
              source.workCache.recordCount >= 2,
              let marker = source.workCache.lastRecord,
              marker.event.type == TimelineEventType.runStarted,
              marker.event.run == source.workState.activeRun,
              let predecessor = source.workCache.penultimateRecord else {
            return nil
        }
        return JournalCursor(
            journal: source.workJournal,
            eventID: predecessor.event.eventID,
            sequence: predecessor.event.sequence)
    }

    private func latestFinishedRunBinding(
        _ source: CanonicalSource, run: RunRef
    ) -> WorkBinding? {
        guard let event = source.workCache.latestRunFinishedEvent
            ?? source.workRead.records.reversed().first(where: {
                $0.event.type == TimelineEventType.runFinished && $0.event.run == run
            })?.event,
        event.type == TimelineEventType.runFinished,
        event.run == run,
        let session = event.session,
        let sessionAttachment = event.sessionAttachment,
        source.workState.sessionAttachments[sessionAttachment.attachmentID].map({
            $0.session == session && $0.attachment == sessionAttachment
        }) == true else {
            return nil
        }
        return WorkBinding(
            session: session, work: source.registration.reservation.work, workHost: host,
            sessionAttachment: sessionAttachment)
    }

    private func startAdmissionKey(
        work: WorkRef,
        binding: WorkBinding,
        client: ClientRef,
        commandID: String,
        causalWorkCursor: JournalCursor,
        prompt: String
    ) -> StartAdmissionKey {
        StartAdmissionKey(
            work: work,
            binding: binding,
            intent: WorkLaunchStartIntent(
                client: client, commandID: commandID,
                causalWorkCursor: causalWorkCursor,
                bodyDigest: digest(Data(prompt.utf8))))
    }

    /// A Run-bound manifest can be durable before the native opener appends `run.started`.
    /// That state is neither idle nor live: the selected Run is an unfinished admission and
    /// must be repaired only by the exact client-qualified Start retry. A completed prior Run
    /// remains the normal current selection after End, so its historical marker/terminal event
    /// explicitly excludes it from this classification.
    private func hasUnstartedStartReservation(
        _ source: CanonicalSource, binding: WorkBinding
    ) async throws -> Bool {
        guard let store = manifestStore else { return false }
        let selection = try await store.currentSelection(
            work: source.registration.reservation.work,
            session: binding.session,
            sessionAttachment: binding.sessionAttachment)
        if let selection {
            let run = selection.manifest.identity.run
            let hasStarted = source.workCache.runStartedIDs.contains(run.runID)
            let hasFinished = source.workCache.runFinishedIDs.contains(run.runID)
            if !hasStarted && !hasFinished { return true }
        }
        return try await store.hasPendingStart(
            work: source.registration.reservation.work,
            session: binding.session,
            sessionAttachment: binding.sessionAttachment)
    }

    private func hasUnstartedStartReservation(
        _ source: HistoryCanonicalWorkSource, binding: WorkBinding
    ) async throws -> Bool {
        guard let store = manifestStore else { return false }
        let selection = try await store.currentSelection(
            work: source.registration.reservation.work,
            session: binding.session,
            sessionAttachment: binding.sessionAttachment)
        if let selection {
            let run = selection.manifest.identity.run
            let hasStarted = source.workCache.runStartedIDs.contains(run.runID)
            let hasFinished = source.workCache.runFinishedIDs.contains(run.runID)
            if !hasStarted && !hasFinished { return true }
        }
        return try await store.hasPendingStart(
            work: source.registration.reservation.work,
            session: binding.session,
            sessionAttachment: binding.sessionAttachment)
    }

    private func ensureLoaded() async throws {
        guard !loaded else { return }
        let control = try await controlSnapshot()
        guard control.structuralIntegrityValid, control.semanticProjectionValid,
              control.quarantinedEvents.isEmpty, control.unknownEvents.isEmpty else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        for creation in control.creations.values {
            let reservation = creation.reservation
            guard let registration = creation.registration, !creation.isConflicted else {
                continue
            }
            var resolvedManifest: JournalBackedWorkLaunchManifest?
            if let store = manifestStore {
                let manifest = try? await store.resolve(
                    work: reservation.work, session: reservation.session,
                    sessionAttachment: reservation.sessionAttachment)
                if let manifest {
                    resolvedManifest = manifest
                    manifests[reservation.work] = manifest
                }
            }
            do {
                let source = try await historyCanonicalWorkSource(
                    work: reservation.work, journal: registration.workJournal,
                    control: control)
                let disposition: WorkHostRegistryCanonicalDisposition =
                    source.workState.lifecycle == .completed || source.workState.lifecycle == .destroyed
                        ? .historical : .recovering
                // An idle pair plus matching host-private launch material can be opened by a
                // later Create/Start path. Leave the logical slot unclaimed so a restart can
                // reconstruct the service-owned actor without trying to replace a canonical fact.
                let hasUntouchedStartReservation = source.workState.lifecycle == .active
                    && source.workState.activeRun != nil
                    && source.workState.activeTurn == nil
                    && source.workState.activeActionIDs.isEmpty
                    && source.workCache.recordCount >= 2
                    && source.workCache.lastRecord?.event.type == TimelineEventType.runStarted
                    && source.workCache.lastRecord?.event.run == source.workState.activeRun
                let hasHostedConfiguration: Bool
                if let store = manifestStore, let resolvedManifest {
                    hasHostedConfiguration = (try? await store.canReconstruct(resolvedManifest)) == true
                } else {
                    hasHostedConfiguration = false
                }
                let hasUnstartedStartReservation = try await self.hasUnstartedStartReservation(
                    source, binding: primaryWorkBinding(source))
                let canReconstructIdle = source.workState.lifecycle == .active
                    && source.workState.execution == .idle
                    && source.workState.activeRun == nil
                    && !hasUnstartedStartReservation
                    && resolvedManifest != nil && hasHostedConfiguration
                let canRecoverStartedReservation = hasUntouchedStartReservation
                    && resolvedManifest != nil && hasHostedConfiguration
                if await registry.lookup(reservation.work) == nil
                        && !canReconstructIdle && !canRecoverStartedReservation
                        // A Run-bound Start selection with no run.started marker is an
                        // unfinished admission, but it must remain addressable by the exact
                        // client-qualified retry. Registering `.recovering` here would make
                        // admitStartActor reject that retry before it can resolve the durable
                        // intent. scanRecovery/descriptor projection carries the recovery truth;
                        // the absent registry slot is an intentional admission seam.
                        && !hasUnstartedStartReservation {
                    try await registerCanonical(
                        work: reservation.work, registration: registration,
                        disposition: disposition, sourceID: "creation-" + reservation.command.commandID)
                }
            } catch {
                if await registry.lookup(reservation.work) == nil {
                    try? await registerCanonical(
                        work: reservation.work, registration: registration,
                        disposition: .unavailable, sourceID: "creation-" + reservation.command.commandID)
                }
            }
        }
        loaded = true
    }

    private func ensureRegistered(
        reservation: WorkHostControlCreationReservation,
        binding: WorkBinding
    ) async throws -> WorkHostControlWorkRegistration {
        let current = try await controlSnapshot()
        if let prior = current.creation(client: reservation.client,
                                        commandID: reservation.command.commandID)?.registration {
            return prior
        }
        // Creation owns the deterministic idle genesis pair. `createIdleWork` continues an
        // exact unregistered prefix (including a one-sided writer-open window) under both locks;
        // it rejects any registered/extended/foreign evidence instead of overwriting it.
        let idle = try await RunJournalBundle.createIdleWork(
            home: home, binding: binding, actorID: actor.actorID, actorKind: actor.kind)
        let source = (workCursor: idle.workCursor, sessionCursor: idle.sessionCursor)
        let registration = try await controlJournal.registerWork(
            WorkHostControlWorkRegistrationRequest(
                reservation: reservation, workJournal: binding.workJournal,
                sessionJournal: binding.sessionJournal, workGenesisCursor: source.workCursor,
                sessionGenesisCursor: source.sessionCursor,
                causalControlCursor: try await currentControlCursor()))
        return registration
    }

    private func readGenesisSource(binding: WorkBinding) async throws -> (workCursor: JournalCursor, sessionCursor: JournalCursor) {
        let work = try readJournal(binding.workJournal, expectedURL: home.timelineV2WorkJournalURL(binding.work))
        let session = try readJournal(binding.sessionJournal, expectedURL: home.timelineV2SessionJournalURL(binding.session))
        let workEvents = work.result.records.map(\.event)
        let sessionEvents = session.result.records.map(\.event)
        guard let workState = work.workSnapshot,
              let sessionState = session.sessionSnapshot else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let workAttachments = Set(workEvents.compactMap { event -> SessionAttachmentRef? in
            guard event.type == TimelineEventType.sessionAttached,
                  event.session == binding.session, event.work == binding.work else { return nil }
            return event.sessionAttachment
        })
        let sessionAttachments = Set(sessionEvents.compactMap { event -> SessionAttachmentRef? in
            guard event.type == TimelineEventType.sessionAttached,
                  event.session == binding.session, event.work == binding.work else { return nil }
            return event.sessionAttachment
        })
        // Registration may reconcile only the exact two-event idle pair created by
        // `createIdleWork`. A partially started or otherwise extended source is a recovery case,
        // never a fresh Create registration.
        guard work.result.records.count == 2, session.result.records.count == 2,
              workEvents.first?.type == TimelineEventType.workCreated,
              sessionEvents.first?.type == TimelineEventType.sessionCreated,
              workAttachments == Set([binding.sessionAttachment]),
              sessionAttachments == workAttachments,
              workState.structuralIntegrityValid, workState.semanticProjectionValid,
              workState.lifecycle == .active, workState.activeRun == nil,
              sessionState.structuralIntegrityValid, sessionState.semanticProjectionValid,
              let workLast = work.result.records.last?.event,
              let sessionLast = session.result.records.last?.event else { throw WorkServiceProtocolError.sourceIncomplete }
        return (
            JournalCursor(journal: binding.workJournal, eventID: workLast.eventID, sequence: workLast.sequence),
            JournalCursor(journal: binding.sessionJournal, eventID: sessionLast.eventID, sequence: sessionLast.sequence))
    }

    private struct CreateAttachmentPublication {
        let attachment: WorkServiceClientAttachment
        let controlCursor: JournalCursor
    }

    private func attachForCreate(
        request: WorkServiceCreateWorkRequest,
        reservation: WorkHostControlCreationReservation,
        registration: WorkHostControlWorkRegistration,
        authorization: WorkServiceAuthorizationOutcome
    ) async throws -> CreateAttachmentPublication {
        let control = try await controlSnapshot()
        let attachmentCommandID = createAttachmentCommandID(
            client: request.client, commandID: request.commandID)
        let prior = try await priorAttachment(
            control: control, work: reservation.work, journal: registration.workJournal,
            client: request.client, commandID: attachmentCommandID)
        if let prior {
            guard let publication = try await controlJournal.priorCommand(
                work: reservation.work, client: request.client,
                commandID: attachmentCommandID),
                  publication.event.type == TimelineEventType.clientAttached,
                  publication.event.work == reservation.work,
                  publication.event.journal == control.journal,
                  publication.event.client == request.client,
                  publication.event.command?.commandID == attachmentCommandID,
                  publication.commit.eventRef == prior.attachedEvent else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            return CreateAttachmentPublication(
                attachment: try clientAttachment(prior, control: control),
                controlCursor: publication.commit.cursor)
        }
        let attachment = try await mintClientAttachment()
        let cursor = try await currentControlCursor()
        let command = CommandRef(commandID: attachmentCommandID, client: request.client,
                                 sessionAttachment: reservation.sessionAttachment,
                                 causalCursor: cursor)
        let publication = try await controlJournal.attachClient(
            work: reservation.work, workJournal: registration.workJournal,
            attachment: attachment, client: request.client,
            capabilities: Set(authorization.granted.map(\.rawValue)),
            requestedCapabilities: Set(authorization.requested.map(\.rawValue)),
            session: reservation.session, sessionJournal: registration.sessionJournal,
            sessionAttachment: reservation.sessionAttachment, command: command,
            causalControlCursor: cursor)
        let updated = try await controlSnapshot()
        guard let record = updated.clientAttachments[attachment.attachmentID],
              record.attachedEvent == publication.eventRef else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return CreateAttachmentPublication(
            attachment: try clientAttachment(record, control: updated),
            controlCursor: publication.cursor)
    }

    private func registerCanonical(
        work: WorkRef,
        registration: WorkHostControlWorkRegistration,
        disposition: WorkHostRegistryCanonicalDisposition,
        sourceID: String
    ) async throws {
        try await registry.registerCanonical(WorkHostRegistryCanonicalFact(
            work: work, disposition: disposition, sourceID: sourceID,
            hostInstance: disposition == .recovering ? hostInstance : nil,
            launchMetadata: nil))
    }

    private func canonicalSource(
        work: WorkRef, journal: JournalRef,
        registration: WorkHostControlWorkRegistration,
        liveObservation: RunJournalBundleCanonicalObservation? = nil
    ) async throws -> CanonicalSource {
        guard journal == registration.workJournal,
              registration.reservation.work == work else { throw WorkServiceProtocolError.journalMismatch }
        let activeObservation = try await liveObservationIfActive(
            work: work, supplied: liveObservation)
        let workCache: JournalReadCacheEntry
        if let activeObservation {
            guard activeObservation.workOnly.journal == journal else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            workCache = try journalCacheEntry(from: activeObservation.workOnly, work: work)
        } else {
            workCache = try readJournal(journal, expectedURL: home.timelineV2WorkJournalURL(work))
        }
        let sessionCache: JournalReadCacheEntry
        if let activeObservation,
           activeObservation.session.journal == registration.sessionJournal,
           activeObservation.session.sessionSnapshot?.session == registration.reservation.session {
            // The selected actor owns both journals for this binding.  Use the same
            // actor-serialized read for the Session side too; an unlocked cold read here can
            // observe the Work's run.started before the Session writer has flushed its mirror.
            sessionCache = try journalCacheEntry(
                from: activeObservation.session, work: work)
        } else {
            // An alternate active Session owns the Work while the creation Session is cold.
            // It must never be substituted as the registered Session source.
            sessionCache = try readJournal(
                registration.sessionJournal,
                expectedURL: home.timelineV2SessionJournalURL(registration.reservation.session))
        }
        let workRead = workCache.result
        let sessionRead = sessionCache.result
        guard workRead.quarantinedSuffix == nil, workRead.truncatedTail == nil,
              sessionRead.quarantinedSuffix == nil, sessionRead.truncatedTail == nil else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        guard let workState = workCache.workSnapshot,
              let sessionState = sessionCache.sessionSnapshot else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        guard workState.structuralIntegrityValid, workState.semanticProjectionValid,
              sessionState.structuralIntegrityValid, sessionState.semanticProjectionValid,
              workState.work == work, workState.journal == journal,
              sessionState.session == registration.reservation.session,
              sessionState.journal == registration.sessionJournal else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        guard let workLast = workCache.lastRecord?.event,
              let sessionLast = sessionCache.lastRecord?.event else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return CanonicalSource(
            registration: registration, workJournal: journal,
            sessionJournal: registration.sessionJournal, workCache: workCache,
            sessionCache: sessionCache, workRead: workRead, sessionRead: sessionRead,
            workState: workState, sessionState: sessionState,
            workSequenceToIndex: workCache.sequenceToIndex,
            sessionSequenceToIndex: sessionCache.sequenceToIndex,
            workCursor: JournalCursor(journal: journal, eventID: workLast.eventID, sequence: workLast.sequence),
            sessionCursor: JournalCursor(journal: registration.sessionJournal,
                                         eventID: sessionLast.eventID, sequence: sessionLast.sequence))
    }

    /// Return a live Work observation only while its Hosted actor still owns open native writers.
    /// An ended actor has released those locks and is intentionally allowed to use the existing
    /// cold projection path. Any other live actor read failure is surfaced; it must never silently
    /// downgrade to an unlocked service read while a Run is active.
    private func liveObservationIfActive(
        work: WorkRef,
        supplied: RunJournalBundleCanonicalObservation?
    ) async throws -> RunJournalBundleCanonicalObservation? {
        if let supplied { return supplied }
        guard let lookup = await registry.lookup(work), case .live(let entry) = lookup else {
            return nil
        }
        let snapshot = await entry.hostedWork.snapshot()
        if snapshot.lifecycle == .ended && snapshot.journalHealth == .closed {
            return nil
        }
        return try await entry.hostedWork.canonicalObservation(
            maximumResidentRecords: canonicalResidentRecordLimit)
    }

    private func journalCacheEntry(
        from live: TimelineJournalCanonicalRead,
        work: WorkRef
    ) throws -> JournalReadCacheEntry {
        let records = live.records
        guard live.fileFingerprint.byteCount == live.source.sourceByteCount,
              live.pagePrefixSeed == prefixSeed(for: live.journal),
              live.sparseIndex.first?.sequence == 1,
              live.sparseIndex.last.map({ $0.sequence <= live.eventCount }) == true else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let result = TimelineJournalReadResult(records: records)
        let sequenceToIndex = Dictionary(uniqueKeysWithValues: records.enumerated().map {
            ($0.element.event.sequence, $0.offset)
        })
        let references = records.reduce(into: Set<TimelineBodyReference>()) { refs, record in
            refs.formUnion(collectBodyReferences(in: record.event.payload))
        }
        let artifactEventCount = records.reduce(into: 0) { count, record in
            if record.event.type == TimelineEventType.artifact { count += 1 }
        }
        var artifacts: [WorkServiceArtifactDescriptor] = []
        var retainedArtifactIDs: Set<String> = []
        var artifactIdentityConflict = false
        var decodedArtifactCount = 0
        for record in records {
            guard let artifact = artifactDescriptor(from: record.event, work: work) else { continue }
            decodedArtifactCount += 1
            if retainedArtifactIDs.contains(artifact.artifactID) {
                artifactIdentityConflict = true
            }
            if artifacts.count >= JournalReadLimits.maximumCachedArtifacts,
               let evicted = artifacts.first {
                artifacts.removeFirst()
                retainedArtifactIDs.remove(evicted.artifactID)
            }
            artifacts.append(artifact)
            retainedArtifactIDs.insert(artifact.artifactID)
        }
        let fingerprint = JournalFileFingerprint(
            identity: JournalFileIdentity(
                device: live.fileFingerprint.device, inode: live.fileFingerprint.inode,
                mode: live.fileFingerprint.mode),
            byteCount: live.fileFingerprint.byteCount,
            modificationSeconds: live.fileFingerprint.modificationSeconds,
            modificationNanoseconds: live.fileFingerprint.modificationNanoseconds,
            changeSeconds: live.fileFingerprint.changeSeconds,
            changeNanoseconds: live.fileFingerprint.changeNanoseconds,
            lastByte: live.fileFingerprint.lastByte,
            prefixEvidence: live.fileFingerprint.prefixEvidence)
        let last = TimelineJournalRecord(
            event: live.lastEvent.event, rawLineBytes: Data(),
            byteStart: live.lastEvent.byteStart, byteEnd: live.lastEvent.byteEnd)
        let penultimate = live.penultimateEvent.map {
            TimelineJournalRecord(event: $0.event, rawLineBytes: Data(),
                                  byteStart: $0.byteStart, byteEnd: $0.byteEnd)
        }
        // Live canonical observations use the projection store's raw 64-hex seed, while the
        // service's page protocol uses its namespaced `sha256:` digest chain. Normalize the
        // live seed before retaining the entry so the first page's base token and every
        // subsequent token have one wire representation. If the live observation is resident,
        // rebuild the bounded service chain over its retained records; a nonresident live read
        // takes the streaming path and will rebuild the chain while serving a page.
        let prefixSeed = live.pagePrefixSeed
        let prefixDigest = live.pagePrefixDigest
        let sparseIndex = live.sparseIndex.map {
            JournalRecordIndex(
                eventID: $0.eventID, sequence: $0.sequence,
                byteStart: $0.byteStart, byteEnd: $0.byteEnd,
                previousEventID: $0.previousEventID,
                prefixDigestBefore: $0.prefixDigestBefore,
                prefixDigest: $0.prefixDigest)
        }
        if live.isFullyResident {
            var recomputed = prefixSeed
            for record in records {
                recomputed = try advancePrefixDigest(recomputed, event: record.event)
            }
            guard records.count == live.eventCount, recomputed == prefixDigest else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
        } else {
            guard records.isEmpty else { throw WorkServiceProtocolError.sourceIncomplete }
        }
        let (nextSequence, overflow) = live.lastEvent.event.sequence.addingReportingOverflow(1)
        guard !overflow else { throw WorkServiceProtocolError.sourceIncomplete }
        return JournalReadCacheEntry(
            fingerprint: fingerprint, result: result, prefixRecords: live.prefixRecords,
            workSnapshot: live.workSnapshot, sessionSnapshot: live.sessionSnapshot,
            sequenceToIndex: sequenceToIndex, sparseIndex: sparseIndex,
            recordCount: live.eventCount,
            lastRecord: last, penultimateRecord: penultimate,
            terminalLineDigest: live.terminalLineDigest,
            prefixSeed: prefixSeed, prefixDigest: prefixDigest,
            nextSequence: nextSequence,
            previousEventID: live.lastEvent.event.eventID,
            isFullyResident: live.isFullyResident,
            latestRunStarted: live.latestRunStarted,
            latestRunFinished: live.latestRunFinished,
            latestRunFinishedEvent: live.latestRunFinishedEvent,
            runStartedIDs: live.runStartedIDs, runFinishedIDs: live.runFinishedIDs,
            runFinishedExists: !live.runFinishedIDs.isEmpty,
            artifactDescriptors: artifacts,
            artifactDescriptorCount: decodedArtifactCount,
            artifactDescriptorsComplete: live.isFullyResident
                && artifactEventCount == decodedArtifactCount,
            artifactDescriptorIdentityConflict: artifactIdentityConflict,
            bodyReferences: references,
            bodyReferenceCount: references.count,
            bodyReferencesComplete: live.isFullyResident)
    }

    private func requireCanonical(work: WorkRef, journal: JournalRef) async throws -> CanonicalSource {
        let control = try await controlSnapshot()
        guard let creation = control.creations.values.first(where: {
            $0.reservation.work == work && $0.registration?.workJournal == journal
        }), creation.registration != nil else {
            throw WorkServiceProtocolError.workNotFound(work)
        }
        let liveObservation = try await liveObservationIfActive(work: work, supplied: nil)
        let verified = await controlJournal.verifiedCreationProjection(
            client: creation.reservation.client, commandID: creation.reservation.command.commandID,
            canonicalWork: liveObservation?.workOnly, canonicalSession: liveObservation?.session)
        // A live actor may own the Work through an alternate canonical Session while the
        // Session recorded by creation is only available through the cold reader. The control
        // verifier must still prove both the live Work and the exact registered Session prefix;
        // a Work-only result is never sufficient for a canonical service operation.
        guard verified.verification.isVerified,
              let verifiedRegistration = verified.projection?.registration else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return try await canonicalSource(
            work: work, journal: journal, registration: verifiedRegistration,
            liveObservation: liveObservation)
    }

    private func controlSnapshot() async throws -> WorkHostControlSnapshot { try await controlJournal.snapshot() }

    private func currentControlCursor() async throws -> JournalCursor {
        let snapshot = try await controlSnapshot()
        guard let journal = snapshot.journal else { throw WorkServiceProtocolError.sourceIncomplete }
        return JournalCursor(journal: journal, eventID: snapshot.lastEventID, sequence: snapshot.lastSequence)
    }

    private func allWorkRefs() async throws -> [WorkRef] {
        let control = try await controlSnapshot()
        return control.creations.values.map(\.reservation.work).sorted {
            $0.workID < $1.workID
        }
    }

    private func descriptor(for work: WorkRef, client: ClientRef) async throws -> WorkServiceWorkDescriptor {
        let source: CanonicalSource
        do {
            source = try await requireCanonical(
                work: work, journal: JournalRef.work(work))
        } catch {
            throw error
        }
        let lookup = await registry.lookup(work)
        let recorded: WorkServiceRecordedDisposition
        switch source.workState.lifecycle {
        case .completed: recorded = .completed
        case .destroyed: recorded = .destroyed
        case .active: recorded = .reusable
        case .unknown: throw WorkServiceProtocolError.sourceIncomplete
        }
        // Unknown reducer facts are observable, but they are not a reason to guess a usable
        // execution state. The same is true of a durable active Run: a journal marker identifies
        // the Run, not a live actor capable of accepting commands.
        var execution: WorkServiceExecutionState
        if source.workState.execution == .unknown
                || !source.workState.unknownEvents.isEmpty
                || !source.workState.unknownDomains.isEmpty {
            execution = .unknown
        } else if source.workState.execution == .failed {
            execution = .recoveryRequired
        } else if source.workState.activeRun != nil {
            execution = .recoveryRequired
        } else {
            switch source.workState.execution {
            case .idle: execution = .idle
            case .running, .preparing, .canceling, .held:
                // A non-running durable projection with no active Run is still not actionable
                // unless a live actor below proves the exact binding. This covers reducer states
                // whose active Run evidence was lost or could not be projected.
                execution = .recoveryRequired
            case .failed: execution = .recoveryRequired
            case .unknown: execution = .unknown
            }
        }
        var observation: WorkServiceHostObservation?
        if let lookup {
            switch lookup {
            case .live(let entry):
                let hosted = await entry.hostedWork.snapshot()
                let exactBinding = hosted.identity.work == source.registration.reservation.work
                    && (source.workState.activeRun == nil
                        || (hosted.identity.sessionID
                                == source.workState.activeRunSession?.sessionID
                            && hosted.sessionAttachment
                                == source.workState.activeRunSessionAttachment))
                let exactRun = source.workState.activeRun.map {
                    hosted.identity.runID == $0.runID
                } ?? [.prepared, .idle, .ended].contains(hosted.lifecycle)
                let liveProof = exactBinding && exactRun
                    && hosted.runtimeState == .connected
                    && hosted.journalHealth == .healthy
                    && hosted.lifecycle != .failed
                let exactIdleActor = exactBinding && source.workState.activeRun == nil
                    && hosted.journalHealth == .healthy
                    && [.prepared, .idle].contains(hosted.lifecycle)
                let exactEndedActor = exactBinding && source.workState.activeRun == nil
                    && hosted.lifecycle == .ended && hosted.journalHealth == .closed
                if liveProof || exactIdleActor || exactEndedActor {
                    if exactEndedActor {
                        execution = .idle
                    } else {
                        switch hosted.lifecycle {
                    case .prepared, .idle: execution = .idle
                    case .preparing, .running: execution = .running
                    case .canceling: execution = .canceling
                    case .ending: execution = .ending
                    case .ended, .failed: execution = .recoveryRequired
                        }
                    }
                } else if source.workState.execution != .unknown {
                    execution = .recoveryRequired
                }
                observation = try WorkServiceHostObservation(
                    instance: entry.hostInstance,
                    reachability: hosted.runtimeState == .connected
                        && hosted.journalHealth == .healthy ? .observedReachable : .recovering,
                    currentRun: source.workState.activeRun,
                    currentRunSession: source.workState.activeRunSession,
                    currentRunSessionAttachment: source.workState.activeRunSessionAttachment,
                    servedCursor: source.workCursor,
                    sourceCompleteness: .complete)
            case .recovering(let fact):
                // A recovering entry is never a positive liveness observation. In particular, a
                // durable run.started record does not turn this descriptor into `running` or
                // leave an otherwise idle projection actionable.
                if execution != .unknown { execution = .recoveryRequired }
                observation = try WorkServiceHostObservation(
                    instance: fact.hostInstance ?? hostInstance, reachability: .recovering,
                    currentRun: source.workState.activeRun,
                    currentRunSession: source.workState.activeRunSession,
                    currentRunSessionAttachment: source.workState.activeRunSessionAttachment,
                    servedCursor: source.workCursor,
                    sourceCompleteness: .complete)
            case .historical:
                // Historical is a durable terminal/retired registry fact, not liveness. An idle
                // Work with no current Run remains idle; an active or failed projection remains
                // recovery-required and can never be acted on through this descriptor.
                if source.workState.activeRun != nil || execution == .recoveryRequired {
                    execution = .recoveryRequired
                }
                observation = nil
            case .unavailable:
                if execution != .unknown { execution = .recoveryRequired }
                observation = nil
            }
        }
        // A durable pre-marker Start selection has no activeRun in the Work reducer yet, but it
        // is still an unfinished admission. Only its exact Start retry may cross the opener.
        let hasUnstartedReservation = try await hasUnstartedStartReservation(
            source, binding: primaryWorkBinding(source))
        if execution == .idle && hasUnstartedReservation {
            execution = .recoveryRequired
        }
        let control = try await controlSnapshot()
        // Every completed Session creation is inserted into the canonical control attachment
        // table by the reducer. Source verification below authenticates those records; it must
        // not synthesize a second always-attached copy that could resurrect a later detach.
        _ = try await completedSessionAttachments(for: work, source: source, control: control)
        let allAttachments = Array(control.clientAttachments.values)
        let attachments = try allAttachments
            .filter {
                $0.work == work && $0.workJournal == source.workJournal && $0.isAttached
            }
            .reduce(into: [WorkHostClientAttachmentSnapshot]()) { result, value in
                guard !result.contains(where: { $0.attachment == value.attachment }) else { return }
                result.append(value)
            }
            .sorted { $0.attachment.attachmentID < $1.attachment.attachmentID }
            .prefix(WorkServiceBounds.maxAttachmentsPerWork)
            .map { try clientAttachment($0, control: control) }
        let omitted = allAttachments.filter {
            $0.work == work && $0.workJournal == source.workJournal && $0.isAttached
        }.count - attachments.count
        let sourceArtifacts = try uniqueArtifacts(in: source)
        var omissions: [WorkServiceOmission] = []
        if omitted > 0 {
            omissions.append(WorkServiceOmission(category: "attachments", count: omitted))
        }
        let artifactOmitted = max(
            0, source.workCache.artifactDescriptorCount
                - sourceArtifacts.count)
        if artifactOmitted > 0 {
            omissions.append(WorkServiceOmission(category: "artifacts", count: artifactOmitted))
            // The bounded display window proves only local identity uniqueness. Exact lookup
            // scans the full canonical source for the requested ID before returning a descriptor.
            omissions.append(WorkServiceOmission(
                category: "artifact_identity_scope", count: artifactOmitted))
        }
        if !source.workCache.artifactDescriptorsComplete {
            // A live nonresident observation proves the Work reducer/cursor but intentionally
            // does not retain the history needed to enumerate artifacts. Keep the exact state
            // usable while making this independent index explicitly unknown.
            omissions.append(WorkServiceOmission(category: "artifact_index", count: 1))
        }
        let truncatedArtifactMetadata = sourceArtifacts.filter(
            \.metadataWasTruncated).count
        if truncatedArtifactMetadata > 0 {
            omissions.append(WorkServiceOmission(
                category: "artifact_metadata", count: truncatedArtifactMetadata))
        }
        guard let config = manifests[work]?.requestedConfiguration
            ?? manifests[work]?.template?.template.draft.configuration else {
            // A durable template without its exact request configuration is not a truthful
            // descriptor after restart.  Do not substitute the resolved runtime route here.
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return try WorkServiceWorkDescriptor(
            work: work, journal: source.workJournal, recordedDisposition: recorded,
            execution: execution, currentRun: source.workState.activeRun,
            currentRunSession: source.workState.activeRunSession,
            currentRunSessionAttachment: source.workState.activeRunSessionAttachment,
            configuration: WorkServiceWorkConfiguration(
                providerID: config.providerID, modelID: config.modelID,
                thinkingLevel: config.thinkingLevel, contextPolicy: config.contextPolicy,
                workspaceID: config.workspaceID,
                includeContextFiles: config.includeContextFiles,
                recordPayloads: config.recordPayloads, resumePolicy: config.resumePolicy),
            hostObservation: observation,
            attachments: Array(attachments),
            sessionAttachments: try await sessionRelationships(
                for: source, control: control),
            artifacts: sourceArtifacts,
            omissions: omissions)
    }

    private func clientAttachment(
        _ value: WorkHostClientAttachmentSnapshot,
        control: WorkHostControlSnapshot,
        authorizationOverride: WorkServiceAuthorizationOutcome? = nil
    ) throws -> WorkServiceClientAttachment {
        let granted = Set(value.capabilities.compactMap(WorkServiceCapability.init(rawValue:)))
        let auth = WorkServiceAuthorizationOutcome(requested: granted, granted: granted, denied: [])
        let acknowledgements = control.readAcknowledgements.values.filter {
            $0.client == value.client && $0.attachment == value.attachment && $0.work == value.work
        }.sorted { $0.targetJournal.stableKey < $1.targetJournal.stableKey }
            .prefix(WorkServiceBounds.maxReadAcknowledgementsPerAttachment)
            .map { ack -> WorkServiceReadAcknowledgement in
                let target: WorkServiceReadTarget
                if case .session(let session) = ack.targetJournal.owner {
                    target = .session(session: session, journal: ack.targetJournal)
                } else {
                    target = .work(journal: ack.targetJournal)
                }
                return WorkServiceReadAcknowledgement(target: target, cursor: ack.cursor)
            }
        return WorkServiceClientAttachment(
            attachment: value.attachment, client: value.client, session: value.session,
            sessionJournal: value.sessionJournal, sessionAttachment: value.sessionAttachment,
            authorization: authorizationOverride ?? auth,
            readAcknowledgements: Array(acknowledgements))
    }

    private func completedSessionAttachments(
        for work: WorkRef, source: CanonicalSource,
        control: WorkHostControlSnapshot
    ) async throws -> [WorkHostClientAttachmentSnapshot] {
        var result: [WorkHostClientAttachmentSnapshot] = []
        func capabilities(_ event: TimelineEvent) -> [String]? {
            guard let values = event.payload["capabilities"]?.arrayValue else { return nil }
            let names = values.compactMap(\.stringValue)
            return names.count == values.count ? names.sorted() : nil
        }
        for creation in control.sessionCreations.values where creation.reservation.work == work {
            guard let publication = creation.result else { continue }
            guard publication.publication == "mirrored"
                    || publication.publication == "terminal_reference",
                  publication.sessionCreatedEvent.journal == creation.reservation.sessionJournal,
                  publication.sessionAttachedEvent.journal == creation.reservation.sessionJournal,
                  publication.cursorAdvancedEvent.journal == creation.reservation.sessionJournal,
                  publication.causalWorkCursor == creation.reservation.causalWorkCursor else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            // A control result is not source truth by itself. Re-read the newly-created Session
            // and verify every referenced event before projecting its client attachment.
            let session = try readJournal(
                publication.sessionCreatedEvent.journal,
                expectedURL: home.timelineV2SessionJournalURL(creation.reservation.session))
            let sessionRecords = session.result.records.isEmpty
                ? session.prefixRecords : session.result.records
            let advancedCause: EventRef?
            if publication.publication == "mirrored" {
                advancedCause = publication.workMirrorEvent
            } else {
                advancedCause = source.workCache.lastRecord
                    .map { EventRef(journal: source.workJournal, eventID: $0.event.eventID) }
            }
            guard session.result.quarantinedSuffix == nil,
                  session.result.truncatedTail == nil,
                  sessionRecords.count >= 3,
                  let created = sessionRecords.first(where: {
                      $0.event.eventID == publication.sessionCreatedEvent.eventID
                  }),
                  let attached = sessionRecords.first(where: {
                      $0.event.eventID == publication.sessionAttachedEvent.eventID
                  }),
                  let advanced = sessionRecords.first(where: {
                      $0.event.eventID == publication.cursorAdvancedEvent.eventID
                  }),
                  attached.event.type == TimelineEventType.sessionAttached,
                  advanced.event.type == TimelineEventType.sessionAttachmentCursorAdvanced,
                  created.event.type == TimelineEventType.sessionCreated,
                  created.event.session == creation.reservation.session,
                  attached.event.session == creation.reservation.session,
                  attached.event.work == work,
                  created.event.workHost == nil,
                  attached.event.workHost == host,
                  attached.event.client == creation.reservation.client,
                  attached.event.sessionAttachment == creation.reservation.sessionAttachment,
                  attached.event.causedByEventID == publication.sessionCreatedEvent,
                  created.event.journal == creation.reservation.sessionJournal,
                  attached.event.journal == creation.reservation.sessionJournal,
                  created.event.sequence == 1,
                  attached.event.sequence == 2,
                  advanced.event.session == creation.reservation.session,
                  advanced.event.work == work,
                  advanced.event.workHost == host,
                  advanced.event.client == creation.reservation.client,
                  advanced.event.sessionAttachment == creation.reservation.sessionAttachment,
                  advanced.event.causedByEventID == advancedCause,
                  advanced.event.journal == creation.reservation.sessionJournal,
                  advanced.event.sequence == 3,
                  capabilities(advanced.event) == publication.capabilities.sorted(),
                  capabilities(attached.event) == publication.capabilities.sorted(),
                  (advanced.event.payload["cursor"].flatMap {
                      decodeTimelineValue($0) as JournalCursor?
                  }) == publication.resultingWorkCursor,
                  publication.sessionCursor == JournalCursor(
                      journal: advanced.event.journal,
                      eventID: advanced.event.eventID,
                      sequence: advanced.event.sequence),
                  sessionRecords[2].event.eventID == publication.cursorAdvancedEvent.eventID else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            if publication.publication == "mirrored" {
                guard let mirror = publication.workMirrorEvent,
                      source.boundedWorkRecords.contains(where: {
                          $0.event.eventID == mirror.eventID
                              && $0.event.type == TimelineEventType.sessionAttached
                              && $0.event.session == creation.reservation.session
                              && $0.event.workHost == host
                              && $0.event.client == creation.reservation.client
                              && $0.event.sessionAttachment == creation.reservation.sessionAttachment
                              && $0.event.causedByEventID == publication.sessionAttachedEvent
                              && JournalCursor(
                                  journal: source.workJournal,
                                  eventID: $0.event.eventID,
                                  sequence: $0.event.sequence)
                                  == publication.resultingWorkCursor
                      }) else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
            } else {
                guard publication.workMirrorEvent == nil,
                      publication.resultingWorkCursor == publication.causalWorkCursor,
                      source.workCursor == publication.causalWorkCursor,
                      let terminalEvent = source.workCache.lastRecord,
                      [TimelineEventType.workCompleted, TimelineEventType.workDestroyed,
                       TimelineEventType.workFailed].contains(terminalEvent.event.type),
                      JournalCursor(
                          journal: source.workJournal,
                          eventID: terminalEvent.event.eventID,
                          sequence: terminalEvent.event.sequence)
                          == publication.causalWorkCursor,
                      let terminal = advanced.event.causedByEventID,
                      EventRef(
                          journal: source.workJournal,
                          eventID: terminalEvent.event.eventID) == terminal else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
            }
            // The control attachment row is mutable relationship state: an explicit capability
            // update changes its current grant, and a detach may remove it from a transport's
            // current view.  The completed Session publication itself is immutable source
            // evidence.  Reconstruct the relationship from that evidence and preserve only the
            // current attached/detached bit when the row is still present.  This keeps an exact
            // historical create-session retry truthful after updateCapabilities or detach.
            let recorded = control.clientAttachments[
                creation.reservation.clientAttachment.attachmentID]
            if let recorded {
                guard recorded.attachment == creation.reservation.clientAttachment,
                      recorded.client == creation.reservation.client,
                      recorded.work == work,
                      recorded.workJournal == source.workJournal,
                      recorded.session == creation.reservation.session,
                      recorded.sessionJournal == creation.reservation.sessionJournal,
                      recorded.sessionAttachment == creation.reservation.sessionAttachment,
                      recorded.attachedEvent == publication.resultEvent else {
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                result.append(WorkHostClientAttachmentSnapshot(
                    attachment: recorded.attachment, client: recorded.client,
                    work: recorded.work, workJournal: recorded.workJournal,
                    session: recorded.session, sessionJournal: recorded.sessionJournal,
                    sessionAttachment: recorded.sessionAttachment,
                    capabilities: Set(publication.capabilities), isAttached: recorded.isAttached,
                    attachedEvent: recorded.attachedEvent,
                    detachedEvent: recorded.detachedEvent))
            } else {
                // A compacted/terminal historical control projection may omit the now-detached
                // client row.  The immutable publication still proves the exact relationship;
                // represent it as detached so no historical replay silently grants authority.
                result.append(WorkHostClientAttachmentSnapshot(
                    attachment: creation.reservation.clientAttachment,
                    client: creation.reservation.client, work: work,
                    workJournal: source.workJournal, session: creation.reservation.session,
                    sessionJournal: creation.reservation.sessionJournal,
                    sessionAttachment: creation.reservation.sessionAttachment,
                    capabilities: Set(publication.capabilities), isAttached: false,
                    attachedEvent: publication.resultEvent))
            }
        }
        return result
    }

    private func sessionRelationships(
        for source: CanonicalSource, control: WorkHostControlSnapshot
    ) async throws -> [WorkServiceSessionAttachmentDescriptor] {
        var relationships: [WorkServiceSessionAttachmentDescriptor] = []
        let primaryAttached = source.boundedSessionRecords.first {
            let event = $0.event
            return event.type == TimelineEventType.sessionAttached
                && event.session == source.session && event.work == source.registration.reservation.work
                && event.sessionAttachment == source.sessionAttachment
        }
        let primaryMirror = primaryAttached.flatMap { attached in
            source.boundedWorkRecords.filter {
                let event = $0.event
                return event.type == TimelineEventType.sessionAttached
                    && event.session == source.session
                    && event.work == source.registration.reservation.work
                    && event.sessionAttachment == source.sessionAttachment
                    && event.causedByEventID == EventRef(
                        journal: source.sessionJournal, eventID: attached.event.eventID)
            }.first
        }
        if let attached = primaryAttached, let mirror = primaryMirror {
            let prior = source.boundedWorkRecords.last(where: {
                $0.event.sequence < mirror.event.sequence
            })
                .map { JournalCursor(journal: source.workJournal,
                                      eventID: $0.event.eventID, sequence: $0.event.sequence) }
                ?? JournalCursor(journal: source.workJournal, sequence: 0)
            relationships.append(WorkServiceSessionAttachmentDescriptor(
                session: source.session, sessionJournal: source.sessionJournal,
                sessionAttachment: source.sessionAttachment, publication: .mirrored,
                causalSessionCursor: JournalCursor(journal: source.sessionJournal, sequence: 0),
                sessionCursor: JournalCursor(journal: source.sessionJournal,
                                             eventID: source.sessionCursor.eventID,
                                             sequence: source.sessionCursor.sequence),
                causalWorkCursor: prior,
                resultingWorkCursor: JournalCursor(journal: source.workJournal,
                                                   eventID: mirror.event.eventID,
                                                   sequence: mirror.event.sequence),
                capabilities: Set((attached.event.payload["capabilities"]?.arrayValue ?? [])
                    .compactMap { $0.stringValue }
                    .compactMap { WorkServiceCapability(rawValue: $0) })))
        }
        let verifiedAttachments = try await completedSessionAttachments(
            for: source.registration.reservation.work, source: source, control: control)
        for creation in control.sessionCreations.values
            where creation.reservation.work == source.registration.reservation.work {
            guard let result = creation.result else { continue }
            guard verifiedAttachments.contains(where: {
                $0.attachment == creation.reservation.clientAttachment
            }) else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            relationships.append(WorkServiceSessionAttachmentDescriptor(
                session: creation.reservation.session,
                sessionJournal: creation.reservation.sessionJournal,
                sessionAttachment: creation.reservation.sessionAttachment,
                publication: result.publication == "terminal_reference"
                    ? .terminalReference : .mirrored,
                causalSessionCursor: result.causalSessionCursor,
                sessionCursor: result.sessionCursor,
                causalWorkCursor: result.causalWorkCursor,
                resultingWorkCursor: result.resultingWorkCursor,
                capabilities: Set(result.capabilities.compactMap {
                    WorkServiceCapability(rawValue: $0)
                })))
        }
        return relationships.sorted {
            $0.sessionAttachment.attachmentID < $1.sessionAttachment.attachmentID
        }
    }

    private func completedSessionClientAttachment(
        reservation: WorkHostControlSessionCreationRequest,
        result: WorkHostControlSessionCreationResult,
        control: WorkHostControlSnapshot
    ) throws -> WorkServiceClientAttachment {
        guard let value = control.clientAttachments[reservation.clientAttachment.attachmentID],
              value.attachment == reservation.clientAttachment,
              value.client == reservation.client,
              value.work == reservation.work,
              value.workJournal == reservation.workJournal,
              value.session == reservation.session,
              value.sessionJournal == reservation.sessionJournal,
              value.sessionAttachment == reservation.sessionAttachment,
              value.isAttached,
              value.attachedEvent == result.resultEvent else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return try clientAttachment(value, control: control)
    }

    private func decodeControlPayload<T: Decodable>(_ value: JSONValue?) -> T? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func priorAttachment(
        control: WorkHostControlSnapshot,
        work: WorkRef,
        journal: JournalRef,
        client: ClientRef,
        commandID: String
    ) async throws -> WorkHostClientAttachmentSnapshot? {
        let read = try await controlJournal.read()
        guard let attachedRef = read.records.map(\.event).first(where: { event in
            event.type == TimelineEventType.clientAttached && event.work == work
                && event.journal == control.journal && event.client == client
                && event.command?.commandID == commandID
        }).map({ EventRef(journal: $0.journal, eventID: $0.eventID) }) else {
            return nil
        }
        return control.clientAttachments.values.first {
            $0.attachedEvent == attachedRef && $0.workJournal == journal
        }
    }

    private func authorization(_ value: WorkHostClientAttachmentSnapshot) -> WorkServiceAuthorizationOutcome {
        let granted = Set(value.capabilities.compactMap(WorkServiceCapability.init(rawValue:)))
        return WorkServiceAuthorizationOutcome(requested: granted, granted: granted, denied: [])
    }

    private func clientHasObserve(work: WorkRef, client: ClientRef) async throws -> Bool {
        let control = try await controlSnapshot()
        return control.clientAttachments.values.contains {
            $0.work == work && $0.client == client && $0.isAttached
                && $0.capabilities.contains(WorkServiceCapability.observe.rawValue)
        }
    }

    @discardableResult
    private func requireAttached(
        work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
        client: ClientRef, capability: WorkServiceCapability
    ) async throws -> WorkServiceClientAttachment {
        let control = try await controlSnapshot()
        guard let value = control.clientAttachments[attachment.attachmentID],
              value.work == work, value.workJournal == journal,
              value.client == client, value.isAttached else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        let result = try clientAttachment(value, control: control)
        guard result.authorization.allows(capability) else {
            throw WorkServiceProtocolError.capabilityDenied(capability)
        }
        return result
    }

    /// Convert the authenticated client attachment into the exact canonical Work binding. The
    /// control registration's reservation is only the creation provenance; it is never a command
    /// identity or a substitute for the Session selected by this caller.
    private func callerWorkBinding(
        _ attachment: WorkServiceClientAttachment,
        source: CanonicalSource,
        work: WorkRef
    ) throws -> WorkBinding {
        guard let session = attachment.session,
              let sessionJournal = attachment.sessionJournal,
              let sessionAttachment = attachment.sessionAttachment,
              sessionJournal == WorkBinding(
                session: session, work: work, workHost: host,
                sessionAttachment: sessionAttachment).sessionJournal,
              let relationship = source.workState.sessionAttachments[
                sessionAttachment.attachmentID],
              relationship.attachment == sessionAttachment,
              relationship.session == session,
              relationship.isAttached else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        return WorkBinding(
            session: session, work: work, workHost: host,
            sessionAttachment: sessionAttachment)
    }

    /// Reject only a clearly foreign live actor before the canonical source read. The control
    /// attachment is authenticated by ``requireAttached``; the Hosted snapshot contributes the
    /// live actor's exact Session/attachment identity. This helper intentionally has no positive
    /// authorization result: callers whose identity matches, whose actor is absent, or whose
    /// actor has ended still require the normal canonical Work/Session verification.
    private func rejectCrossSessionLiveOwner(
        work: WorkRef,
        attachment: WorkServiceClientAttachment
    ) async throws {
        guard let session = attachment.session,
              let sessionJournal = attachment.sessionJournal,
              let sessionAttachment = attachment.sessionAttachment,
              sessionJournal.owner == .session(session),
              sessionJournal.kind == .session,
              sessionJournal.authority.authorityID == host.workHostID else {
            return
        }
        guard let lookup = await registry.lookup(work), case .live(let entry) = lookup else {
            return
        }
        let snapshot = await entry.hostedWork.snapshot()
        guard snapshot.lifecycle != .ended else { return }
        guard snapshot.identity.sessionID == session.sessionID,
              snapshot.sessionAttachment == sessionAttachment else {
            throw WorkServiceProtocolError.invalidRequest(
                "active Run belongs to a different Session attachment")
        }
    }

    private func primaryWorkBinding(_ source: CanonicalSource) -> WorkBinding {
        WorkBinding(
            session: source.session, work: source.registration.reservation.work, workHost: host,
            sessionAttachment: source.sessionAttachment)
    }

    private func primaryWorkBinding(_ source: HistoryCanonicalWorkSource) -> WorkBinding {
        WorkBinding(
            session: source.registration.reservation.session,
            work: source.registration.reservation.work, workHost: host,
            sessionAttachment: source.registration.reservation.sessionAttachment)
    }

    private func validateTarget(_ target: WorkServiceReadTarget, source: CanonicalSource) throws {
        switch target {
        case .work(let journal):
            guard journal == source.workJournal else { throw WorkServiceProtocolError.journalMismatch }
        case .session(let session, let journal):
            guard session == source.session, journal == source.sessionJournal else {
                throw WorkServiceProtocolError.journalMismatch
            }
        }
    }

    private func records(
        for target: WorkServiceReadTarget, source: CanonicalSource
    ) async throws -> JournalReadCacheEntry {
        switch target {
        case .work(let journal):
            guard journal == source.workJournal else {
                throw WorkServiceProtocolError.journalMismatch
            }
            return source.workCache
        case .session(let session, let journal):
            if session == source.session && journal == source.sessionJournal {
                return source.sessionCache
            }
            let control = try await controlSnapshot()
            guard try await sessionRelationships(for: source, control: control).contains(where: {
                $0.session == session && $0.sessionJournal == journal
            }) else { throw WorkServiceProtocolError.journalMismatch }
            return try readJournal(
                journal, expectedURL: home.timelineV2SessionJournalURL(session))
        }
    }

    private func validateReadableTarget(
        _ target: WorkServiceReadTarget,
        attachment: WorkServiceClientAttachment,
        source: CanonicalSource
    ) async throws {
        switch target {
        case .work(let journal):
            guard journal == source.workJournal else {
                throw WorkServiceProtocolError.journalMismatch
            }
        case .session(let session, let journal):
            guard attachment.session == session,
                  attachment.sessionJournal == journal,
                  attachment.sessionAttachment != nil else {
                throw WorkServiceProtocolError.journalMismatch
            }
            let control = try await controlSnapshot()
            guard try await sessionRelationships(for: source, control: control).contains(where: {
                $0.session == session && $0.sessionJournal == journal
                    && $0.sessionAttachment == attachment.sessionAttachment
            }) else { throw WorkServiceProtocolError.journalMismatch }
        }
    }

    private func expectedURL(
        for target: WorkServiceReadTarget, source: CanonicalSource
    ) -> URL {
        if target.session == nil {
            return home.timelineV2WorkJournalURL(source.registration.reservation.work)
        }
        if case .session(let session, _) = target {
            return home.timelineV2SessionJournalURL(session)
        }
        return home.timelineV2SessionJournalURL(source.registration.reservation.session)
    }

    private struct Page {
        let events: [TimelineEvent]
        let servedCursor: JournalCursor?
        let nextCursor: JournalCursor?
        let basePrefixDigest: String?
        let prefixDigest: String?
        let omissions: [WorkServiceOmission]
    }

    private func page(
        entry: JournalReadCacheEntry, journal: JournalRef, expectedURL: URL,
        after: JournalCursor?, target: WorkServiceReadTarget,
        limit: Int, maxBytes: Int
    ) async throws -> Page {
        guard limit > 0, limit <= WorkServiceBounds.maxEventsPerPage,
              maxBytes > 0, maxBytes <= WorkServiceBounds.maxEventPageBytes else {
            throw WorkServiceProtocolError.invalidRequest("event page bounds are invalid")
        }
        guard after?.journal == nil || after?.journal == journal else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard entry.isFullyResident else {
            return try streamPage(
                entry: entry, journal: journal, expectedURL: expectedURL,
                after: after, target: target, limit: limit, maxBytes: maxBytes)
        }
        return try residentPage(
            entry: entry, records: entry.result.records, sequenceToIndex: entry.sequenceToIndex,
            recordCount: entry.recordCount, after: after, target: target,
            limit: limit, maxBytes: maxBytes)
    }

    private func residentPage(
        entry: JournalReadCacheEntry, records: [TimelineJournalRecord],
        sequenceToIndex: [Int: Int], recordCount: Int,
        after: JournalCursor?, target: WorkServiceReadTarget,
        limit: Int, maxBytes: Int
    ) throws -> Page {
        let journal = target.journal
        let start: Int
        if let after {
            // Sequence zero with no event is the canonical empty-prefix cursor. It is useful for
            // a first page and is not itself a journal record; every other cursor must identify
            // an exact event, including its event ID, so a fabricated cursor cannot skip data.
            if after.sequence == 0 && after.eventID == nil {
                start = 0
            } else {
                guard let index = sequenceToIndex[after.sequence],
                      index < records.count,
                      records[index].event.sequence == after.sequence,
                      records[index].event.eventID == after.eventID else {
                    throw WorkServiceProtocolError.staleCursor(
                        expected: after, actual: cursor(records, journal: journal))
                }
                start = index + 1
            }
        } else { start = 0 }
        var selected: [TimelineEvent] = []
        var bytes = 0
        var stoppedForBytes = false
        for record in records.dropFirst(start).prefix(limit) {
            // The page protocol counts standalone event envelopes. Durable JSONL byte ranges also
            // include record delimiters and therefore cannot be used as the wire-facing bound.
            let size = try WorkServiceEventPageSizing.encodedByteCount(of: record.event)
            guard size <= maxBytes else {
                throw WorkServiceProtocolError.eventPageCannotProgress(requiredBytes: size, maximumBytes: maxBytes)
            }
            guard bytes + size <= maxBytes else {
                stoppedForBytes = true
                break
            }
            selected.append(record.event); bytes += size
        }
        let served = selected.last.map { JournalCursor(journal: journal, eventID: $0.eventID, sequence: $0.sequence) }
            ?? after
        let index = selected.last.flatMap { sequenceToIndex[$0.sequence] }
        let hasMore = index.map { $0 + 1 < recordCount } ?? false
        let next = hasMore ? served : nil
        let remaining = recordCount - (start + selected.count)
        var omissions: [WorkServiceOmission] = []
        if remaining > 0 {
            // These are deliberately source-level facts, not an estimate of what the client has
            // already read.  The continuation cursor is the last event actually delivered, so a
            // controller can prove that every omitted event will be requested on the next page.
            let category = stoppedForBytes ? "event_bytes" : "events"
            let diagnostic = stoppedForBytes
                ? "event page byte bound reached; continue from served cursor"
                : "event page count bound reached; continue from served cursor"
            omissions.append(WorkServiceOmission(
                category: category, count: remaining, diagnostic: diagnostic))
        }
        let basePrefixDigest = try prefixDigest(
            for: after, entry: entry, records: records, sequenceToIndex: sequenceToIndex,
            journal: journal)
        var servedPrefixDigest = basePrefixDigest
        for event in selected {
            servedPrefixDigest = try advancePrefixDigest(
                servedPrefixDigest ?? entry.prefixSeed, event: event)
        }
        return Page(
            events: selected, servedCursor: served, nextCursor: next,
            basePrefixDigest: basePrefixDigest, prefixDigest: servedPrefixDigest,
            omissions: omissions)
    }

    /// Read a bounded page from a nonresident source. The canonical full-file scan already
    /// validated the append chain and populated the reducer cache; this second pass only decodes
    /// the suffix needed by the requested page and re-fences the open file before publishing it.
    private func streamPage(
        entry: JournalReadCacheEntry, journal: JournalRef, expectedURL: URL,
        after: JournalCursor?, target: WorkServiceReadTarget,
        limit: Int, maxBytes: Int
    ) throws -> Page {
        let path = expectedURL.standardizedFileURL.path
        let descriptor = path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw WorkServiceProtocolError.sourceIncomplete }
        defer { _ = AviaryPOSIX.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let before = try journalFileFingerprint(descriptor: descriptor, path: expectedURL, handle: handle)
        guard before == entry.fingerprint else { throw WorkServiceProtocolError.sourceIncomplete }

        let afterSequence = after?.sequence ?? 0
        guard afterSequence >= 0, afterSequence <= entry.recordCount else {
            throw WorkServiceProtocolError.staleCursor(
                expected: after ?? JournalCursor(journal: journal, sequence: afterSequence),
                actual: JournalCursor(journal: journal, sequence: entry.recordCount))
        }
        if afterSequence == 0, after?.eventID != nil {
            throw WorkServiceProtocolError.staleCursor(
                expected: after ?? JournalCursor(journal: journal, sequence: 0),
                actual: JournalCursor(journal: journal, sequence: entry.recordCount))
        }
        let anchor: JournalRecordIndex?
        if afterSequence == 0 {
            anchor = nil
        } else {
            anchor = sparseAnchor(for: afterSequence, in: entry.sparseIndex)
            guard anchor != nil else { throw WorkServiceProtocolError.sourceIncomplete }
        }
        let startOffset = anchor?.byteStart ?? 0
        let initialSequence = anchor?.sequence ?? 1
        let initialPreviousEventID = anchor?.previousEventID
        var parser = TimelineJournalReaderState(
            journal: journal, actor: actor, hostRecordedAt: Date(),
            initialByteOffset: startOffset, initialSequence: initialSequence,
            initialPreviousEventID: initialPreviousEventID)
        var offset = startOffset
        var validatedAfter = afterSequence == 0
        var selected: [TimelineEvent] = []
        var bytes = 0
        var stoppedForBytes = false
        var prefix = anchor?.prefixDigestBefore ?? entry.prefixSeed
        var basePrefixDigest: String? = afterSequence == 0 ? entry.prefixSeed : nil
        var servedPrefixDigest: String?
        while offset < entry.fingerprint.byteCount {
            let requested = min(JournalReadLimits.chunkBytes, entry.fingerprint.byteCount - offset)
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: requested), chunk.count == requested else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            let final = offset + requested == entry.fingerprint.byteCount
            let parsed = parser.append(chunk, final: final)
            guard parsed.quarantinedSuffix == nil,
                  parsed.truncatedTail == nil || !final else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            for record in parsed.records {
                let digestBefore = prefix
                prefix = try advancePrefixDigest(digestBefore, event: record.event)
                if !validatedAfter {
                    if record.event.sequence == afterSequence {
                        guard let after, record.event.eventID == after.eventID else {
                            throw WorkServiceProtocolError.staleCursor(
                                expected: JournalCursor(
                                    journal: journal, eventID: after?.eventID,
                                    sequence: afterSequence),
                                actual: JournalCursor(
                                    journal: journal, eventID: record.event.eventID,
                                    sequence: record.event.sequence))
                        }
                        validatedAfter = true
                        basePrefixDigest = prefix
                    }
                    continue
                }
                guard selected.count < limit else { break }
                let size = try WorkServiceEventPageSizing.encodedByteCount(of: record.event)
                guard size <= maxBytes else {
                    throw WorkServiceProtocolError.eventPageCannotProgress(
                        requiredBytes: size, maximumBytes: maxBytes)
                }
                guard bytes + size <= maxBytes else {
                    stoppedForBytes = true
                    break
                }
                selected.append(record.event)
                bytes += size
                servedPrefixDigest = prefix
            }
            if (validatedAfter && (selected.count >= limit || stoppedForBytes)) { break }
            offset += requested
        }
        guard validatedAfter else {
            throw WorkServiceProtocolError.staleCursor(
                expected: after ?? JournalCursor(journal: journal, sequence: afterSequence),
                actual: JournalCursor(journal: journal, sequence: entry.recordCount))
        }
        let served = selected.last.map {
            JournalCursor(journal: journal, eventID: $0.eventID, sequence: $0.sequence)
        } ?? after
        if servedPrefixDigest == nil {
            servedPrefixDigest = basePrefixDigest
        }
        let deliveredThrough = selected.last?.sequence ?? afterSequence
        let remaining = max(0, entry.recordCount - deliveredThrough)
        let hasMore = remaining > 0
        var omissions: [WorkServiceOmission] = []
        if hasMore {
            omissions.append(WorkServiceOmission(
                category: stoppedForBytes ? "event_bytes" : "events",
                count: remaining,
                diagnostic: stoppedForBytes
                    ? "event page byte bound reached; continue from served cursor"
                    : "event page count bound reached; continue from served cursor"))
        }
        let afterFingerprint = try journalFileFingerprint(
            descriptor: descriptor, path: expectedURL, handle: handle)
        guard before == afterFingerprint else { throw WorkServiceProtocolError.sourceIncomplete }
        return Page(
            events: selected, servedCursor: served, nextCursor: hasMore ? served : nil,
            basePrefixDigest: basePrefixDigest, prefixDigest: servedPrefixDigest,
            omissions: omissions)
    }

    private func sparseAnchor(
        for sequence: Int, in entries: [JournalRecordIndex]
    ) -> JournalRecordIndex? {
        var low = 0
        var high = entries.count
        var result: JournalRecordIndex?
        while low < high {
            let middle = low + (high - low) / 2
            if entries[middle].sequence <= sequence {
                result = entries[middle]
                low = middle + 1
            } else {
                high = middle
            }
        }
        return result
    }

    /// Read one canonical source through an actor-owned incremental cache. The open descriptor is
    /// itself the identity fence: `O_NOFOLLOW` rejects a replaced final path, and fstat/lstat
    /// comparisons before and after the scan reject a rename or inode swap while bytes are read.
    /// A candidate cache is published only after the complete append chain reaches EOF without a
    /// malformed or unterminated suffix.
    private func readJournal(
        _ journal: JournalRef, expectedURL: URL, stabilizationAttempt: Int = 0
    ) throws -> JournalReadCacheEntry {
        let path = expectedURL.standardizedFileURL.path
        guard !path.utf8.contains(0) else { throw WorkServiceProtocolError.sourceIncomplete }
        let key = JournalCacheKey(journal: journal, path: path)
        let previous = journalCache[key]
        incrementReadMetrics(readCalls: 1)

        let descriptor = path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            incrementReadMetrics(invalidations: 1)
            throw WorkServiceProtocolError.sourceIncomplete
        }
        defer { _ = AviaryPOSIX.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)

        var observedBefore: JournalFileFingerprint?
        do {
            let before = try journalFileFingerprint(
                descriptor: descriptor, path: expectedURL, handle: handle)
            observedBefore = before
            if let previous, previous.fingerprint == before {
                // Even a cache hit gets a second identity check. It performs no history read, but
                // a concurrent path replacement must not turn the old entry into current truth.
                let after = try journalFileFingerprint(
                    descriptor: descriptor, path: expectedURL, handle: handle)
                guard before == after else {
                    journalCache.removeValue(forKey: key)
                    incrementReadMetrics(invalidations: 1)
                    throw WorkServiceProtocolError.sourceIncomplete
                }
                incrementReadMetrics(cacheHits: 1)
                return previous
            }

            // Remove the old entry before mutating any shared arrays/dictionaries. This avoids a
            // copy-on-write full-history clone on the append path and makes failure semantics
            // explicit: the old value can never be served after the source changed.
            journalCache.removeValue(forKey: key)
            let appendBase: JournalReadCacheEntry?
            if let previous,
               previous.fingerprint.identity == before.identity,
               before.byteCount > previous.fingerprint.byteCount,
               try prefixTailMatches(
                   previous, descriptor: descriptor, handle: handle) {
                appendBase = previous
            } else {
                appendBase = nil
            }
            let startByteCount = appendBase?.fingerprint.byteCount ?? 0
            let scan = try scanJournal(
                journal: journal, handle: handle, targetByteCount: before.byteCount,
                startByteCount: startByteCount, previous: appendBase)
            let after = try journalFileFingerprint(
                descriptor: descriptor, path: expectedURL, handle: handle)
            guard before == after else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            let entry = JournalReadCacheEntry(
                fingerprint: after, result: scan.result, prefixRecords: scan.prefixRecords,
                workSnapshot: scan.workSnapshot, sessionSnapshot: scan.sessionSnapshot,
                sequenceToIndex: scan.sequenceToIndex,
                sparseIndex: scan.sparseIndex, recordCount: scan.recordCount,
                lastRecord: scan.lastRecord, penultimateRecord: scan.penultimateRecord,
                terminalLineDigest: scan.terminalLineDigest,
                prefixSeed: scan.prefixSeed, prefixDigest: scan.prefixDigest,
                nextSequence: scan.nextSequence, previousEventID: scan.previousEventID,
                isFullyResident: scan.isFullyResident,
                latestRunStarted: scan.latestRunStarted,
                latestRunFinished: scan.latestRunFinished,
                latestRunFinishedEvent: scan.latestRunFinishedEvent,
                runStartedIDs: scan.runStartedIDs, runFinishedIDs: scan.runFinishedIDs,
                runFinishedExists: scan.runFinishedExists,
                artifactDescriptors: scan.artifactDescriptors,
                artifactDescriptorCount: scan.artifactDescriptorCount,
                artifactDescriptorsComplete: scan.artifactDescriptorsComplete,
                artifactDescriptorIdentityConflict: scan.artifactDescriptorIdentityConflict,
                bodyReferences: scan.bodyReferences,
                bodyReferenceCount: scan.bodyReferenceCount,
                bodyReferencesComplete: scan.bodyReferencesComplete)
            journalCache[key] = entry
            incrementReadMetrics(
                rebuilds: appendBase == nil ? 1 : 0,
                incrementalReads: appendBase == nil ? 0 : 1)
            return entry
        } catch {
            // A Hosted actor may append a complete line while this reader is scanning. The open
            // descriptor proves that the path identity is unchanged, and a strictly larger byte
            // count is the one safe transient case: retry the bounded read against the new tip.
            // Stable malformed content, truncation, and inode replacement remain fail-closed.
            if stabilizationAttempt < 3,
               let before = observedBefore,
               let after = try? journalFileFingerprint(
                   descriptor: descriptor, path: expectedURL, handle: handle),
               before.identity == after.identity,
               after.byteCount > before.byteCount {
                journalCache.removeValue(forKey: key)
                return try readJournal(
                    journal, expectedURL: expectedURL,
                    stabilizationAttempt: stabilizationAttempt + 1)
            }
            // No stale success is allowed after an invalidation, even when the prior cache was a
            // fully valid prefix. The caller receives sourceIncomplete and must retry after a new
            // stable append-chain read.
            journalCache.removeValue(forKey: key)
            incrementReadMetrics(invalidations: 1)
            throw WorkServiceProtocolError.sourceIncomplete
        }
    }

    private struct JournalScanResult {
        let result: TimelineJournalReadResult
        let prefixRecords: [TimelineJournalRecord]
        let workSnapshot: WorkSnapshot?
        let sessionSnapshot: SessionSnapshot?
        let sequenceToIndex: [Int: Int]
        let sparseIndex: [JournalRecordIndex]
        let recordCount: Int
        let lastRecord: TimelineJournalRecord?
        let penultimateRecord: TimelineJournalRecord?
        let terminalLineDigest: String?
        let prefixSeed: String
        let prefixDigest: String
        let nextSequence: Int
        let previousEventID: String?
        let isFullyResident: Bool
        let latestRunStarted: RunRef?
        let latestRunFinished: RunRef?
        let latestRunFinishedEvent: TimelineEvent?
        let runStartedIDs: Set<String>
        let runFinishedIDs: Set<String>
        let runFinishedExists: Bool
        let artifactDescriptors: [WorkServiceArtifactDescriptor]
        let artifactDescriptorCount: Int
        let artifactDescriptorsComplete: Bool
        let artifactDescriptorIdentityConflict: Bool
        let bodyReferences: Set<TimelineBodyReference>
        let bodyReferenceCount: Int
        let bodyReferencesComplete: Bool
    }

    private func scanJournal(
        journal: JournalRef,
        handle: FileHandle,
        targetByteCount: Int,
        startByteCount: Int,
        previous: JournalReadCacheEntry?
    ) throws -> JournalScanResult {
        guard targetByteCount >= 0,
              startByteCount >= 0, startByteCount <= targetByteCount else {
            throw WorkServiceProtocolError.sourceIncomplete
        }

        let priorEventID = previous?.previousEventID
        var parser = TimelineJournalReaderState(
            journal: journal, actor: actor, hostRecordedAt: Date(),
            initialByteOffset: startByteCount,
            initialSequence: previous?.nextSequence ?? 1,
            initialPreviousEventID: priorEventID)

        // A resident cache is a latency optimization, not a prerequisite for canonical
        // availability.  Once a source exceeds the resident budget we retain only a sparse byte
        // index and the bounded reducer projection.  Pages then reread just the requested range.
        var isFullyResident = targetByteCount <= JournalReadLimits.maximumResidentBytes
            && previous?.isFullyResident != false
        var records = isFullyResident ? (previous?.result.records ?? []) : []
        var prefixRecords = previous?.prefixRecords ?? []
        var sequenceToIndex = isFullyResident ? (previous?.sequenceToIndex ?? [:]) : [:]
        var sparseIndex = previous?.sparseIndex ?? []
        var recordCount = previous?.recordCount ?? 0
        var lastRecord = previous?.lastRecord
        var penultimateRecord = previous?.penultimateRecord
        var terminalLineDigest = previous?.terminalLineDigest
        let seedDigest = previous?.prefixSeed ?? prefixSeed(for: journal)
        var currentPrefixDigest = previous?.prefixDigest ?? seedDigest
        var workReducer: WorkReducer?
        var sessionReducer: SessionReducer?
        switch journal.owner {
        case .work:
            workReducer = WorkReducer(snapshot: previous?.workSnapshot ?? WorkSnapshot())
            sessionReducer = nil
        case .session:
            workReducer = nil
            sessionReducer = SessionReducer(snapshot: previous?.sessionSnapshot ?? SessionSnapshot())
        case .workHost:
            workReducer = nil
            sessionReducer = nil
        }
        var latestRunStarted = previous?.latestRunStarted
        var latestRunFinished = previous?.latestRunFinished
        var latestRunFinishedEvent = previous?.latestRunFinishedEvent
        var runStartedIDs = previous?.runStartedIDs ?? []
        var runFinishedIDs = previous?.runFinishedIDs ?? []
        var runFinishedExists = previous?.runFinishedExists ?? false
        var artifactDescriptors = previous?.artifactDescriptors ?? []
        var artifactDescriptorCount = previous?.artifactDescriptorCount ?? 0
        var artifactDescriptorsComplete = previous?.artifactDescriptorsComplete ?? true
        var artifactDescriptorIdentityConflict =
            previous?.artifactDescriptorIdentityConflict ?? false
        var retainedArtifactIDs = Set(artifactDescriptors.map(\.artifactID))
        var cachedBodyReferences = previous?.bodyReferences ?? []
        var bodyReferenceCount = previous?.bodyReferenceCount ?? 0
        var bodyReferencesComplete = previous?.bodyReferencesComplete ?? true
        var offset = startByteCount

        while offset < targetByteCount {
            let requested = min(JournalReadLimits.chunkBytes, targetByteCount - offset)
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: requested),
                  chunk.count == requested else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            incrementReadMetrics(bytesScanned: chunk.count)
            let parsed = parser.append(
                chunk, final: offset + requested == targetByteCount)
            guard parsed.quarantinedSuffix == nil,
                  parsed.truncatedTail == nil || offset + requested < targetByteCount else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            for record in parsed.records {
                recordCount += 1
                let compact = TimelineJournalRecord(
                    event: record.event, rawLineBytes: Data(), byteStart: record.byteStart,
                    byteEnd: record.byteEnd, legacyRawID: record.legacyRawID)
                if prefixRecords.count < JournalReadLimits.sparseStride {
                    prefixRecords.append(compact)
                }
                let priorRecord = lastRecord
                penultimateRecord = lastRecord
                lastRecord = compact
                terminalLineDigest = digest(record.rawLineBytes)
                let prefixDigestBefore = currentPrefixDigest
                currentPrefixDigest = try advancePrefixDigest(
                    prefixDigestBefore, event: record.event)
                if record.event.type == TimelineEventType.runStarted,
                   let run = record.event.run {
                    latestRunStarted = run
                    runStartedIDs.insert(run.runID)
                }
                if record.event.type == TimelineEventType.runFinished {
                    runFinishedExists = true
                    if let run = record.event.run {
                        latestRunFinished = run
                        latestRunFinishedEvent = record.event
                        runFinishedIDs.insert(run.runID)
                    }
                }
                let references = collectBodyReferences(in: record.event.payload)
                if !references.isEmpty {
                    bodyReferenceCount += references.count
                    if bodyReferencesComplete {
                        for reference in references {
                            if cachedBodyReferences.count < JournalReadLimits.maximumCachedBodyReferences {
                                cachedBodyReferences.insert(reference)
                            } else {
                                bodyReferencesComplete = false
                                break
                            }
                        }
                    }
                }
                if case .work(let artifactWork) = journal.owner,
                   record.event.type == TimelineEventType.artifact {
                    if let artifact = artifactDescriptor(
                        from: record.event, work: artifactWork) {
                        if retainedArtifactIDs.contains(artifact.artifactID) {
                            artifactDescriptorIdentityConflict = true
                        }
                        let (nextArtifactCount, artifactCountOverflow) =
                            artifactDescriptorCount.addingReportingOverflow(1)
                        guard !artifactCountOverflow else {
                            throw WorkServiceProtocolError.sourceIncomplete
                        }
                        artifactDescriptorCount = nextArtifactCount
                        if artifactDescriptors.count >= JournalReadLimits.maximumCachedArtifacts {
                            if let evicted = artifactDescriptors.first {
                                retainedArtifactIDs.remove(evicted.artifactID)
                            }
                            artifactDescriptors.removeFirst()
                        }
                        artifactDescriptors.append(artifact)
                        retainedArtifactIDs.insert(artifact.artifactID)
                    } else {
                        artifactDescriptorsComplete = false
                    }
                }

                // Keep a bounded sparse index even for nonresident sources. The first record and
                // every stride boundary are enough to locate any later page with a bounded suffix
                // scan, while avoiding one dictionary entry per historical event.
                if sparseIndex.count < JournalReadLimits.maximumSparseEntries,
                   recordCount == 1 || (recordCount - 1) % JournalReadLimits.sparseStride == 0 {
                    sparseIndex.append(JournalRecordIndex(
                        eventID: record.event.eventID, sequence: record.event.sequence,
                        byteStart: record.byteStart, byteEnd: record.byteEnd,
                        previousEventID: priorRecord?.event.eventID,
                        prefixDigestBefore: prefixDigestBefore,
                        prefixDigest: currentPrefixDigest))
                }

                if isFullyResident {
                    if recordCount <= JournalReadLimits.maximumResidentRecords {
                        sequenceToIndex[record.event.sequence] = records.count
                        records.append(compact)
                    } else {
                        // The source remains valid. Drop the resident envelopes and continue the
                        // same validated reduction with sparse offsets.
                        isFullyResident = false
                        records.removeAll(keepingCapacity: false)
                        sequenceToIndex.removeAll(keepingCapacity: false)
                    }
                }
                workReducer?.apply(record.event)
                sessionReducer?.apply(record.event)
                incrementReadMetrics(recordsApplied: 1)
            }
            offset += requested
        }

        let nextSequence: Int
        let previousEventID: String?
        if let last = lastRecord?.event {
            let (next, overflow) = last.sequence.addingReportingOverflow(1)
            guard !overflow else { throw WorkServiceProtocolError.sourceIncomplete }
            nextSequence = next
            previousEventID = last.eventID
        } else {
            nextSequence = 1
            previousEventID = nil
        }
        return JournalScanResult(
            result: TimelineJournalReadResult(records: isFullyResident ? records : []),
            prefixRecords: prefixRecords,
            workSnapshot: workReducer?.snapshot,
            sessionSnapshot: sessionReducer?.snapshot,
            sequenceToIndex: sequenceToIndex, sparseIndex: sparseIndex,
            recordCount: recordCount, lastRecord: lastRecord,
            penultimateRecord: penultimateRecord,
            terminalLineDigest: terminalLineDigest, prefixSeed: seedDigest,
            prefixDigest: currentPrefixDigest, nextSequence: nextSequence,
            previousEventID: previousEventID, isFullyResident: isFullyResident,
            latestRunStarted: latestRunStarted, latestRunFinished: latestRunFinished,
            latestRunFinishedEvent: latestRunFinishedEvent,
            runStartedIDs: runStartedIDs, runFinishedIDs: runFinishedIDs,
            runFinishedExists: runFinishedExists,
            artifactDescriptors: artifactDescriptors,
            artifactDescriptorCount: artifactDescriptorCount,
            artifactDescriptorsComplete: artifactDescriptorsComplete,
            artifactDescriptorIdentityConflict: artifactDescriptorIdentityConflict,
            bodyReferences: cachedBodyReferences,
            bodyReferenceCount: bodyReferenceCount,
            bodyReferencesComplete: bodyReferencesComplete)
    }

    private func incrementReadMetrics(
        readCalls: Int = 0,
        cacheHits: Int = 0,
        rebuilds: Int = 0,
        incrementalReads: Int = 0,
        invalidations: Int = 0,
        bytesScanned: Int = 0,
        recordsApplied: Int = 0
    ) {
        func add(_ value: Int, _ delta: Int) -> Int {
            guard delta > 0 else { return value }
            let (result, overflow) = value.addingReportingOverflow(delta)
            return overflow ? Int.max : result
        }
        readMetrics = JournalBackedWorkServiceReadMetrics(
            readCalls: add(readMetrics.readCalls, readCalls),
            cacheHits: add(readMetrics.cacheHits, cacheHits),
            rebuilds: add(readMetrics.rebuilds, rebuilds),
            incrementalReads: add(readMetrics.incrementalReads, incrementalReads),
            invalidations: add(readMetrics.invalidations, invalidations),
            bytesScanned: add(readMetrics.bytesScanned, bytesScanned),
            recordsApplied: add(readMetrics.recordsApplied, recordsApplied))
    }

    private func incrementHistoryMetrics(
        calls: Int = 0,
        indexBuilds: Int = 0,
        cacheHits: Int = 0,
        rebuilds: Int = 0,
        decodedPhysicalEvents: Int = 0,
        sourceBytesScanned: Int = 0,
        peakBufferBytes: Int = 0,
        metadataLookups: Int = 0,
        parentLinks: Int = 0,
        canonicalRangeReads: Int = 0,
        canonicalRangeBytes: Int = 0,
        mapObjectsRead: Int = 0,
        mapBytesRead: Int = 0
    ) {
        func add(_ value: Int, _ delta: Int) -> Int {
            guard delta > 0 else { return value }
            let (result, overflow) = value.addingReportingOverflow(delta)
            return overflow ? Int.max : result
        }
        historyMetrics = JournalBackedWorkServiceHistoryMetrics(
            calls: add(historyMetrics.calls, calls),
            indexBuilds: add(historyMetrics.indexBuilds, indexBuilds),
            cacheHits: add(historyMetrics.cacheHits, cacheHits),
            rebuilds: add(historyMetrics.rebuilds, rebuilds),
            decodedPhysicalEvents: add(
                historyMetrics.decodedPhysicalEvents, decodedPhysicalEvents),
            sourceBytesScanned: add(historyMetrics.sourceBytesScanned, sourceBytesScanned),
            peakBufferBytes: max(historyMetrics.peakBufferBytes, max(0, peakBufferBytes)),
            metadataLookups: add(historyMetrics.metadataLookups, metadataLookups),
            parentLinks: add(historyMetrics.parentLinks, parentLinks),
            canonicalRangeReads: add(
                historyMetrics.canonicalRangeReads, canonicalRangeReads),
            canonicalRangeBytes: add(
                historyMetrics.canonicalRangeBytes, canonicalRangeBytes),
            mapObjectsRead: add(historyMetrics.mapObjectsRead, mapObjectsRead),
            mapBytesRead: add(historyMetrics.mapBytesRead, mapBytesRead))
    }

    private func incrementHistoryMetrics(
        _ metrics: LocalSessionHistoryProjectionReader.Metrics
    ) {
        incrementHistoryMetrics(
            indexBuilds: metrics.historyIndexBuilds,
            cacheHits: metrics.historyCacheHits,
            rebuilds: metrics.historyProjectionRebuilds,
            decodedPhysicalEvents: metrics.decodedPhysicalEvents,
            sourceBytesScanned: metrics.sourceBytesScanned,
            peakBufferBytes: metrics.peakBufferBytes,
            metadataLookups: metrics.metadataLookups,
            parentLinks: metrics.parentLinks,
            canonicalRangeReads: metrics.historyCanonicalRangeReads,
            canonicalRangeBytes: metrics.historyCanonicalRangeBytes,
            mapObjectsRead: metrics.historyMapObjects,
            mapBytesRead: metrics.historyMapBytes)
    }

    /// The empty-prefix token is scoped to the logical journal, so a cursor from one journal can
    /// never be mistaken for an empty prefix in another journal.  Prefix tokens are a hash-chain
    /// over the decoded event's canonical JSON line, not a whole-history digest: each scan advances
    /// the token once and sparse anchors make later validation bounded.
    private func prefixSeed(for journal: JournalRef) -> String {
        digest(Data("aviary-prefix-v1\u{0}seed\u{0}\(journal.stableKey)".utf8))
    }

    private func advancePrefixDigest(_ prefix: String, event: TimelineEvent) throws -> String {
        let lineDigest = try DisposableTimelineProjectionStore.canonicalEventLineDigest(event)
        var material = Data("aviary-prefix-v1\u{0}".utf8)
        material.append(Data(prefix.utf8))
        material.append(0)
        material.append(Data(lineDigest.utf8))
        return digest(material)
    }

    private func prefixDigest(
        for cursorValue: JournalCursor?, entry: JournalReadCacheEntry,
        records: [TimelineJournalRecord], sequenceToIndex: [Int: Int], journal: JournalRef
    ) throws -> String? {
        guard let cursor = cursorValue else { return entry.prefixSeed }
        guard cursor.journal == journal, cursor.sequence >= 0,
              cursor.sequence <= entry.recordCount else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard cursor.sequence > 0 else {
            guard cursor.eventID == nil else {
                throw WorkServiceProtocolError.staleCursor(
                    expected: cursor,
                    actual: JournalCursor(journal: journal, sequence: entry.recordCount))
            }
            return entry.prefixSeed
        }
        guard let targetIndex = sequenceToIndex[cursor.sequence],
              targetIndex >= 0, targetIndex < records.count,
              records[targetIndex].event.sequence == cursor.sequence,
              records[targetIndex].event.eventID == cursor.eventID else {
            throw WorkServiceProtocolError.staleCursor(
                expected: cursor,
                actual: self.cursor(records, journal: journal))
        }
        guard let anchor = sparseAnchor(for: cursor.sequence, in: entry.sparseIndex),
              let anchorIndex = sequenceToIndex[anchor.sequence],
              anchorIndex >= 0, anchorIndex <= targetIndex,
              records[anchorIndex].event.sequence == anchor.sequence,
              records[anchorIndex].event.eventID == anchor.eventID else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        var result = try advancePrefixDigest(
            anchor.prefixDigestBefore, event: records[anchorIndex].event)
        guard result == anchor.prefixDigest else { throw WorkServiceProtocolError.sourceIncomplete }
        if anchorIndex < targetIndex {
            for index in (anchorIndex + 1)...targetIndex {
                result = try advancePrefixDigest(result, event: records[index].event)
            }
        }
        // This is an internal cache invariant. A mismatch means the cache's prefix proof no longer
        // describes the events being served, so fail closed rather than returning a token that a
        // controller could use to skip an unproven reducer state.
        return result
    }

    private func prefixTailMatches(
        _ previous: JournalReadCacheEntry,
        descriptor: Int32,
        handle: FileHandle
    ) throws -> Bool {
        let fingerprint = previous.fingerprint
        guard fingerprint.byteCount > 0 else { return true }
        guard let expected = fingerprint.lastByte else { return false }
        guard let actual = try byte(
            at: fingerprint.byteCount - 1, descriptor: descriptor, handle: handle) else {
            return false
        }
        guard actual == expected else { return false }
        guard let terminal = previous.lastRecord,
              let expectedTerminalDigest = previous.terminalLineDigest else {
            return false
        }
        let terminalLength = terminal.byteEnd - terminal.byteStart
        guard terminalLength > 0,
              let terminalData = try readRange(
                  at: terminal.byteStart, length: terminalLength, handle: handle),
              digest(terminalData) == expectedTerminalDigest else {
            return false
        }
        // A small prefix sample catches in-place rewrites which leave the former terminal line
        // unchanged.  Complete-prefix proof is supplied by the owner writer's append lock; this
        // evidence makes accidental same-inode replacement fail closed in ordinary cases without
        // re-reading the entire history on every append.
        return try prefixEvidence(for: handle, byteCount: fingerprint.byteCount)
            == fingerprint.prefixEvidence
    }

    private func readRange(at offset: Int, length: Int, handle: FileHandle) throws -> Data? {
        let (_, overflow) = offset.addingReportingOverflow(length)
        guard offset >= 0, length >= 0, !overflow else {
            return nil
        }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: length) ?? Data()
        try handle.seek(toOffset: 0)
        return data.count == length ? data : nil
    }

    private func byte(
        at offset: Int, descriptor: Int32, handle: FileHandle
    ) throws -> UInt8? {
        _ = descriptor
        guard offset >= 0 else { return nil }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: 1) ?? Data()
        try handle.seek(toOffset: 0)
        guard data.count == 1 else { return nil }
        return data[data.startIndex]
    }

    private func journalFileFingerprint(
        descriptor: Int32, path: URL, handle: FileHandle
    ) throws -> JournalFileFingerprint {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_size >= 0,
              descriptorStatus.st_size <= off_t(Int.max) else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        var pathStatus = stat()
        let pathResult = path.standardizedFileURL.path.withCString {
            lstat($0, &pathStatus)
        }
        guard pathResult == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let byteCount = Int(descriptorStatus.st_size)
        let lastByte = try byte(at: byteCount - 1, descriptor: descriptor, handle: handle)
        let evidence = try prefixEvidence(for: handle, byteCount: byteCount)
        let times = journalFileTimes(descriptorStatus)
        return JournalFileFingerprint(
            identity: JournalFileIdentity(
                device: UInt64(descriptorStatus.st_dev),
                inode: UInt64(descriptorStatus.st_ino),
                mode: UInt32(descriptorStatus.st_mode)),
            byteCount: byteCount,
            modificationSeconds: times.modificationSeconds,
            modificationNanoseconds: times.modificationNanoseconds,
            changeSeconds: times.changeSeconds,
            changeNanoseconds: times.changeNanoseconds,
            lastByte: lastByte, prefixEvidence: evidence)
    }

    private func journalFileTimes(_ status: stat) -> (
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        changeSeconds: Int64,
        changeNanoseconds: Int64
    ) {
        #if canImport(Darwin)
        return (
            Int64(status.st_mtimespec.tv_sec), Int64(status.st_mtimespec.tv_nsec),
            Int64(status.st_ctimespec.tv_sec), Int64(status.st_ctimespec.tv_nsec))
        #elseif canImport(Glibc)
        return (
            Int64(status.st_mtim.tv_sec), Int64(status.st_mtim.tv_nsec),
            Int64(status.st_ctim.tv_sec), Int64(status.st_ctim.tv_nsec))
        #else
        return (0, 0, 0, 0)
        #endif
    }

    private func prefixEvidence(for handle: FileHandle, byteCount: Int) throws -> String {
        guard byteCount >= 0 else { throw WorkServiceProtocolError.sourceIncomplete }
        let sample = min(4 * 1024, byteCount)
        guard let first = try readRange(at: 0, length: sample, handle: handle) else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        guard byteCount > sample else { return digest(first) }
        guard let last = try readRange(
            at: byteCount - sample, length: sample, handle: handle) else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        var evidence = Data()
        evidence.append(first)
        evidence.append(last)
        return digest(evidence)
    }

    private func artifacts(in source: CanonicalSource) -> [WorkServiceArtifactDescriptor] {
        source.workCache.artifactDescriptors
    }

    private func uniqueArtifacts(
        in source: CanonicalSource
    ) throws -> [WorkServiceArtifactDescriptor] {
        let values = artifacts(in: source)
        guard !source.workCache.artifactDescriptorIdentityConflict,
              Set(values.map(\.artifactID)).count == values.count else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return values
    }

    private func artifactDescriptor(
        from event: TimelineEvent, work: WorkRef
    ) -> WorkServiceArtifactDescriptor? {
        // Callers first authenticate the canonical Work reduction, which verifies the active
        // Run owner and exact action-start cause for artifact events. Do not maintain a second
        // action-history authority here: it diverges between resident and streamed reads.
        // This projection validates the bounded wire shape, never a filename or local path.
        guard event.type == TimelineEventType.artifact,
              event.journal.owner == .work(work),
              event.work == work,
              event.workHost == WorkHostRef(work.workHostID),
              let session = event.session,
              let sessionAttachment = event.sessionAttachment,
              let run = event.run,
              let object = event.payload.objectValue,
              let id = object["artifact_id"]?.stringValue,
              validArtifactIdentity(id),
              validArtifactIdentity(session.sessionID),
              validArtifactIdentity(sessionAttachment.attachmentID),
              validArtifactIdentity(run.runID),
              event.turn.map({ validArtifactIdentity($0.turnID) }) ?? true,
              event.action.map({ validArtifactIdentity($0.actionID) }) ?? true,
              event.causedByEventID.map({ validArtifactCause($0, event: event) }) ?? true,
              let label = object["label"]?.stringValue,
              validArtifactLabel(label) else { return nil }
        if event.action != nil {
            guard let cause = event.causedByEventID, cause.journal == event.journal else {
                return nil
            }
        }
        let mediaType: String?
        if let value = object["media_type"] {
            guard let decoded = value.stringValue, validArtifactMediaType(decoded) else {
                return nil
            }
            mediaType = decoded
        } else {
            mediaType = nil
        }
        let byteCount: Int?
        if let value = object["byte_count"] {
            guard let decoded = value.intValue,
                  (0...Self.maximumArtifactBodyBytes).contains(decoded) else { return nil }
            byteCount = decoded
        } else {
            byteCount = nil
        }
        let contentDigest: String?
        if let value = object["digest"] {
            guard let decoded = value.stringValue,
                  ContextBodyStore.isValidDigest(decoded) else { return nil }
            contentDigest = decoded
        } else {
            contentDigest = nil
        }
        guard let available = object["available"]?.boolValue else { return nil }
        let body: TimelineBodyReference?
        if let value = object["body_reference"] {
            guard let data = try? JSONEncoder().encode(value),
                  let decoded = try? JSONDecoder().decode(
                    TimelineBodyReference.self, from: data),
                  validArtifactBodyReference(decoded, journal: event.journal) else {
                return nil
            }
            body = decoded
        } else {
            body = nil
        }
        if available != (body != nil) {
            return nil
        }
        if let body {
            guard body.byteCount == byteCount,
                  body.digest == contentDigest,
                  body.mediaType == mediaType,
                  body.byteCount != nil,
                  body.digest != nil else { return nil }
        } else {
            guard byteCount == nil, contentDigest == nil else { return nil }
        }
        if mediaType == ObservedRepositoryReviewFormat.mediaType {
            guard event.turn != nil, event.action != nil,
                  let cause = event.causedByEventID,
                  cause.journal == event.journal else { return nil }
        }
        return try? WorkServiceArtifactDescriptor(
            artifactID: id, work: work, label: label,
            mediaType: mediaType, byteCount: byteCount, digest: contentDigest,
            available: body != nil,
            bodyReference: body,
            sourceEvent: EventRef(journal: event.journal, eventID: event.eventID),
            session: session, sessionAttachment: sessionAttachment, run: run,
            turn: event.turn, action: event.action,
            causedByEventID: event.causedByEventID)
    }

    private func validArtifactCause(_ cause: EventRef, event: TimelineEvent) -> Bool {
        guard validArtifactIdentity(cause.eventID) else { return false }
        guard cause.journal == event.journal else {
            guard cause.journal.kind == .session,
                  cause.journal.owner == .session(event.session ?? SessionRef("")),
                  cause.journal.authority.authorityID == event.work?.workHostID else {
                return false
            }
            return true
        }
        return true
    }

    private func validArtifactIdentity(_ value: String) -> Bool {
        validArtifactText(value, maximumBytes: WorkServiceBounds.maxIdentityCharacters)
    }

    private func validArtifactLabel(_ value: String) -> Bool {
        validArtifactText(value, maximumBytes: WorkServiceBounds.maxDiagnosticCharacters)
    }

    private func validArtifactMediaType(_ value: String) -> Bool {
        validArtifactText(value, maximumBytes: WorkServiceBounds.maxDiagnosticCharacters)
    }

    private func validArtifactText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value > 0x1F
                    && !(0x7F...0x9F).contains(scalar.value)
                    && scalar.value != 0x2028
                    && scalar.value != 0x2029
            }
    }

    private func validArtifactBodyReference(
        _ reference: TimelineBodyReference, journal: JournalRef
    ) -> Bool {
        reference.authority == journal
            && validArtifactIdentity(reference.referenceID)
            && (reference.mediaType.map(validArtifactMediaType) ?? true)
            && (reference.byteCount.map { (0...Self.maximumArtifactBodyBytes).contains($0) } ?? false)
            && (reference.digest.map(ContextBodyStore.isValidDigest) ?? false)
            && (reference.digest.map { reference.referenceID == $0 } ?? false)
    }

    private func collectBodyReferences(in value: JSONValue) -> Set<TimelineBodyReference> {
        var result: Set<TimelineBodyReference> = []
        func visit(_ value: JSONValue) {
            if let data = try? JSONEncoder().encode(value),
               let reference = try? JSONDecoder().decode(TimelineBodyReference.self, from: data) {
                result.insert(reference)
            }
            switch value {
            case .array(let values): values.forEach(visit)
            case .object(let values): values.values.forEach(visit)
            default: break
            }
        }
        visit(value)
        return result
    }

    /// Work journals have two body-bearing producer shapes.  Artifact bodies must come from a
    /// valid bounded artifact descriptor; observe-only command bodies must be direct references
    /// on a recognized input command that explicitly carries session input.  A reference in any
    /// other Work event is intentionally unknown, even when the retained body itself exists.
    private func workBodyReferenceKind(
        in event: TimelineEvent, work: WorkRef, reference: TimelineBodyReference
    ) -> CanonicalBodyReferenceKind? {
        guard collectBodyReferences(in: event.payload).contains(reference) else { return nil }
        if event.type == TimelineEventType.artifact {
            guard artifactDescriptor(
                from: event, work: work
            )?.bodyReference == reference else {
                return .unknown
            }
            return .artifact
        }
        guard event.type == TimelineEventType.commandAccepted,
              let object = event.payload.objectValue,
              let encoded = object["body_reference"],
              let data = try? JSONEncoder().encode(encoded),
              let direct = try? JSONDecoder().decode(
                  TimelineBodyReference.self, from: data),
              direct == reference,
              object["carries_session_input"]?.boolValue == true,
              let commandKind = object["command_kind"]?.stringValue.flatMap(
                  CanonicalCommandKind.init(rawValue:)),
              [.start, .send, .steer, .queue, .queueFollowUp].contains(commandKind)
        else {
            return .unknown
        }
        return .context
    }

    private enum CanonicalBodyReferenceKind {
        case artifact
        case context
        case absent
        case unknown
    }

    /// Classify a body reference from canonical event evidence, rather than from the bounded
    /// descriptor cache.  In particular, an artifact beyond the 128-row display window must
    /// still be recognized as an artifact before ``fetchBody`` authorizes its bytes.  Nonresident
    /// journals are scanned incrementally through the already fingerprinted descriptor; this
    /// never materializes the complete JSONL source in an auxiliary array.
    private func classifyBodyReference(
        _ source: CanonicalSource, _ reference: TimelineBodyReference
    ) throws -> CanonicalBodyReferenceKind {
        if reference.authority == source.workJournal {
            let cache = source.workCache
            if cache.isFullyResident {
                var sawArtifact = false
                var sawContext = false
                var sawUnknown = false
                for record in cache.result.records {
                    guard let kind = workBodyReferenceKind(
                        in: record.event, work: source.registration.reservation.work,
                        reference: reference) else { continue }
                    switch kind {
                    case .artifact:
                        // Content-addressed body bytes may be shared by multiple distinct
                        // artifact descriptors.  Each descriptor keeps its own provenance;
                        // only mixing artifact and context producers remains ambiguous.
                        sawArtifact = true
                    case .context: sawContext = true
                    case .unknown: sawUnknown = true
                    case .absent: break
                    }
                }
                if sawUnknown || (sawArtifact && sawContext) { return .unknown }
                if sawArtifact { return .artifact }
                return sawContext ? .context : .absent
            }
            // A bounded cache can prove absence only when it retained every body reference.
            // Otherwise reread the exact canonical stream and classify the event type there.
            if !cache.bodyReferences.contains(reference), cache.bodyReferencesComplete {
                return .absent
            }
            return try streamClassifyBodyReference(
                entry: cache,
                journal: source.workJournal,
                expectedURL: home.timelineV2WorkJournalURL(
                    source.registration.reservation.work),
                work: source.registration.reservation.work,
                reference: reference)
        }

        // Artifact records belong to the Work journal. Session-owned references therefore retain
        // the existing observe-only context/conversation policy while still requiring exact
        // canonical evidence before any retained bytes are served.
        guard try sourceContainsBodyReference(source, reference) else { return .absent }
        return .context
    }

    private func sourceContainsBodyReference(
        _ source: CanonicalSource, _ reference: TimelineBodyReference
    ) throws -> Bool {
        if source.workCache.bodyReferences.contains(reference)
            || source.sessionCache.bodyReferences.contains(reference) {
            return true
        }
        let candidates: [(JournalReadCacheEntry, JournalRef, URL)] = [
            (source.workCache, source.workJournal,
             home.timelineV2WorkJournalURL(source.registration.reservation.work)),
            (source.sessionCache, source.sessionJournal,
             home.timelineV2SessionJournalURL(source.registration.reservation.session))
        ]
        for (entry, journal, url) in candidates where !entry.bodyReferencesComplete {
            if try streamContainsBodyReference(
                entry: entry, journal: journal, expectedURL: url, reference: reference) {
                return true
            }
        }
        if case .session(let session) = reference.authority.owner,
           session != source.session {
            let entry = try readJournal(
                reference.authority,
                expectedURL: home.timelineV2SessionJournalURL(session))
            if entry.bodyReferences.contains(reference) { return true }
            if !entry.bodyReferencesComplete,
               try streamContainsBodyReference(
                   entry: entry, journal: reference.authority,
                   expectedURL: home.timelineV2SessionJournalURL(session), reference: reference) {
                return true
            }
        }
        return false
    }

    private struct SessionPublicationIdentities: Sendable {
        let session: SessionRef
        let sessionAttachment: SessionAttachmentRef
        let clientAttachment: ClientAttachmentRef
    }

    private func streamContainsBodyReference(
        entry: JournalReadCacheEntry, journal: JournalRef, expectedURL: URL,
        reference: TimelineBodyReference
    ) throws -> Bool {
        let path = expectedURL.standardizedFileURL.path
        let descriptor = path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw WorkServiceProtocolError.sourceIncomplete }
        defer { _ = AviaryPOSIX.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let before = try journalFileFingerprint(descriptor: descriptor, path: expectedURL, handle: handle)
        guard before == entry.fingerprint else { throw WorkServiceProtocolError.sourceIncomplete }
        var found = false
        var parser = TimelineJournalReaderState(
            journal: journal, actor: actor, hostRecordedAt: Date())
        var offset = 0
        while offset < before.byteCount {
            let requested = min(JournalReadLimits.chunkBytes, before.byteCount - offset)
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: requested), chunk.count == requested else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            let final = offset + requested == before.byteCount
            let parsed = parser.append(chunk, final: final)
            guard parsed.quarantinedSuffix == nil,
                  parsed.truncatedTail == nil || !final else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            if parsed.records.contains(where: {
                collectBodyReferences(in: $0.event.payload).contains(reference)
            }) {
                found = true
                break
            }
            offset += requested
        }
        let after = try journalFileFingerprint(descriptor: descriptor, path: expectedURL, handle: handle)
        guard before == after else { throw WorkServiceProtocolError.sourceIncomplete }
        return found
    }

    private func streamClassifyBodyReference(
        entry: JournalReadCacheEntry, journal: JournalRef, expectedURL: URL,
        work: WorkRef,
        reference: TimelineBodyReference
    ) throws -> CanonicalBodyReferenceKind {
        let path = expectedURL.standardizedFileURL.path
        let descriptor = path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw WorkServiceProtocolError.sourceIncomplete }
        defer { _ = AviaryPOSIX.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let before = try journalFileFingerprint(descriptor: descriptor, path: expectedURL, handle: handle)
        guard before == entry.fingerprint else { throw WorkServiceProtocolError.sourceIncomplete }
        var sawContext = false
        var sawArtifact = false
        var sawUnknown = false
        var offset = 0
        var parser = TimelineJournalReaderState(
            journal: journal, actor: actor, hostRecordedAt: Date())
        while offset < before.byteCount {
            let requested = min(JournalReadLimits.chunkBytes, before.byteCount - offset)
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: requested), chunk.count == requested else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            let final = offset + requested == before.byteCount
            let parsed = parser.append(chunk, final: final)
            guard parsed.quarantinedSuffix == nil,
                  parsed.truncatedTail == nil || !final else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            for record in parsed.records {
                guard let kind = workBodyReferenceKind(
                    in: record.event,
                    work: work,
                    reference: reference) else { continue }
                switch kind {
                case .artifact:
                    sawArtifact = true
                case .context: sawContext = true
                case .unknown: sawUnknown = true
                case .absent: break
                }
            }
            offset += requested
        }
        let after = try journalFileFingerprint(descriptor: descriptor, path: expectedURL, handle: handle)
        guard before == after else { throw WorkServiceProtocolError.sourceIncomplete }
        if sawUnknown || (sawArtifact && sawContext) { return .unknown }
        if sawArtifact { return .artifact }
        return sawContext ? .context : .absent
    }

    private func streamFindArtifact(
        entry: JournalReadCacheEntry, journal: JournalRef, expectedURL: URL,
        work: WorkRef, artifactID: String
    ) throws -> WorkServiceArtifactDescriptor? {
        let path = expectedURL.standardizedFileURL.path
        let descriptor = path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw WorkServiceProtocolError.sourceIncomplete }
        defer { _ = AviaryPOSIX.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let before = try journalFileFingerprint(descriptor: descriptor, path: expectedURL, handle: handle)
        guard before == entry.fingerprint else { throw WorkServiceProtocolError.sourceIncomplete }
        var candidate: WorkServiceArtifactDescriptor?
        var duplicate = false
        var malformedMatch = false
        var offset = 0
        var parser = TimelineJournalReaderState(
            journal: journal, actor: actor, hostRecordedAt: Date())
        while offset < before.byteCount {
            let requested = min(JournalReadLimits.chunkBytes, before.byteCount - offset)
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: requested), chunk.count == requested else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            let final = offset + requested == before.byteCount
            let parsed = parser.append(chunk, final: final)
            guard parsed.quarantinedSuffix == nil,
                  parsed.truncatedTail == nil || !final else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            for record in parsed.records {
                guard record.event.type == TimelineEventType.artifact else { continue }
                guard let object = record.event.payload.objectValue,
                      object["artifact_id"]?.stringValue == artifactID else { continue }
                guard let artifact = artifactDescriptor(
                    from: record.event, work: work
                ) else {
                    malformedMatch = true
                    continue
                }
                if candidate == nil {
                    candidate = artifact
                } else {
                    duplicate = true
                }
            }
            offset += requested
        }
        let after = try journalFileFingerprint(descriptor: descriptor, path: expectedURL, handle: handle)
        guard before == after else { throw WorkServiceProtocolError.sourceIncomplete }
        guard !duplicate, !malformedMatch else { throw WorkServiceProtocolError.sourceIncomplete }
        return candidate
    }

    private func terminalCommand(
        _ request: WorkServiceCommandRequest, source: CanonicalSource,
        attachment: WorkServiceClientAttachment, client: ClientRef
    ) async throws -> WorkServiceCommandReceipt {
        let operation: WorkServiceTerminalOperation = request.kind == .complete ? .complete : .destroy
        guard let sessionAttachment = attachment.sessionAttachment else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let command = WorkServiceCommandLedgerIdentity.command(
            from: CommandRef(
                commandID: request.command.commandID, client: client,
                sessionAttachment: sessionAttachment,
                causalCursor: request.causalWorkCursor),
            client: client)
        let identity = SessionWorkIdentity(
            sessionID: source.session.sessionID, work: request.work,
            runID: source.workCache.latestRunStarted?.runID ?? "unknown-run")
        let terminal = WorkServiceTerminalCommitRequest(
            operation: operation, work: request.work, journal: request.journal,
            client: client, session: source.session, sessionJournal: source.sessionJournal,
            sessionAttachment: sessionAttachment,
            causalWorkCursor: request.causalWorkCursor, detail: request.value,
            command: command)
        let proof: WorkServiceTerminalCommitProof?
        if let lookup = await registry.lookup(request.work), case .live(let entry) = lookup {
            proof = try await entry.hostedWork.commit(terminal)
            _ = try await registry.release(request.work, terminalProof: proof!)
        } else {
            proof = try RunJournalBundle.readTerminalCommit(
                home: home, identity: identity,
                sessionAttachment: sessionAttachment, command: command,
                detail: request.value).flatMap { try WorkServiceTerminalCommitProof.makeProof(record: $0, request: terminal) }
        }
        guard let proof else { throw WorkServiceProtocolError.invalidRequest("Work must End before terminalization") }
        return WorkServiceCommandReceipt(
            work: request.work, commandID: request.command.commandID, state: .accepted,
            host: hostInstance, hostSequence: proof.terminalEvent.hostSequence,
            causalWorkCursor: request.causalWorkCursor, resultingWorkCursor: proof.resultingWorkCursor,
            authorization: attachment.authorization,
            outcome: operation == .complete ? .completed : .destroyed, terminalProof: proof)
    }

    private func mintSessionPublicationIdentities(
        work: WorkRef
    ) async throws -> SessionPublicationIdentities {
        for _ in 0..<32 {
            let session = SessionRef("session-" + UUID().uuidString.lowercased())
            let sessionAttachment = SessionAttachmentRef(
                "session-attachment-" + UUID().uuidString.lowercased())
            let clientAttachment = ClientAttachmentRef(
                "client-attachment-" + UUID().uuidString.lowercased())
            let journal = JournalRef.session(
                session, journalID: "session", authority: TimelineAuthorityRef(host.workHostID))
            let control = try await controlSnapshot()
            let used = control.sessionCreations.values.contains {
                $0.reservation.work == work
                    && ($0.reservation.session == session
                        || $0.reservation.sessionAttachment == sessionAttachment
                        || $0.reservation.clientAttachment == clientAttachment)
            }
            guard !used, !FileManager.default.fileExists(
                atPath: home.timelineV2SessionJournalURL(session).path) else { continue }
            _ = journal
            return SessionPublicationIdentities(
                session: session, sessionAttachment: sessionAttachment,
                clientAttachment: clientAttachment)
        }
        throw WorkServiceProtocolError.sourceIncomplete
    }

    private func mintClientAttachment() async throws -> ClientAttachmentRef {
        for _ in 0..<32 {
            let value = ClientAttachmentRef("client-attachment-" + UUID().uuidString.lowercased())
            let control = try await controlSnapshot()
            if control.clientAttachments[value.attachmentID] == nil { return value }
        }
        throw WorkServiceProtocolError.sourceIncomplete
    }

    private func validateManifest(_ manifest: JournalBackedWorkLaunchManifest) throws {
        guard validDigest(manifest.bodyDigest), validDigest(manifest.configurationDigest) else {
            throw WorkServiceProtocolError.invalidRequest("launch manifest digests are invalid")
        }
    }

    /// A Start may execute only from the exact identity-bound durable record returned by the
    /// launch store. A template/digest or an in-memory closure is not enough: the retained body,
    /// client-qualified intent, Work/Session/attachment tuple, and selected Run must all be
    /// present and byte-verifiable before Hosted construction can append a marker.
    private func validateStartManifest(
        _ manifest: JournalBackedWorkLaunchManifest,
        intent: WorkLaunchStartIntent,
        body: Data,
        binding: WorkRunBinding
    ) throws {
        guard let record = manifest.durableRecord else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let durable = record.manifest
        guard durable.identity.work == binding.workBinding.work,
              durable.identity.session == binding.workBinding.session,
              durable.identity.sessionAttachment == binding.workBinding.sessionAttachment,
              durable.identity.run == binding.run,
              durable.startIntent == intent,
              durable.promptAssembly != nil,
              let reference = durable.initialInputBodyReference,
              reference.digest == intent.bodyDigest,
              (try? ContextBodyStore(home: home).read(reference)) == body else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        try validateManifest(manifest)
    }

    private func digest(_ data: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
    }

    private func startBodyMatches(
        _ prompt: String,
        record: WorkLaunchManifestRecord
    ) -> Bool {
        let bytes = Data(prompt.utf8)
        guard record.manifest.startIntent.bodyDigest == digest(bytes) else { return false }
        guard let reference = record.manifest.initialInputBodyReference else {
            // A Start record without its exact retained input body is not replayable.  Digest-only
            // protocol seams cannot prove the bytes after restart, so they fail closed.
            return false
        }
        return (try? ContextBodyStore(home: home).read(reference)) == bytes
    }

    private func validConfigurationBounds(_ configuration: WorkServiceWorkConfiguration) -> Bool {
        !configuration.wasTruncated
            && [configuration.providerID, configuration.modelID, configuration.thinkingLevel,
                configuration.contextPolicy,
                configuration.resumePolicy]
                .allSatisfy { ($0?.utf8.count ?? 0) <= WorkServiceBounds.maxCommandValueCharacters }
    }

    private func capability(for kind: WorkServiceCommandKind) -> WorkServiceCapability {
        switch kind {
        case .start: return .start
        case .send: return .send
        case .steer: return .steer
        case .queue: return .queue
        case .hold: return .hold
        case .cancel: return .cancel
        case .end: return .end
        case .destroy: return .destroy
        case .complete: return .complete
        }
    }

    private func qualifiedCommandID(clientID: String, commandID: String) -> String {
        WorkServiceCommandLedgerIdentity.commandID(
            client: ClientRef(clientID), commandID: commandID)
    }

    private func createAttachmentCommandID(client: ClientRef, commandID: String) -> String {
        let material = Data("create-attachment-v1\u{0}\(client.clientID)\u{0}\(commandID)".utf8)
        let digest = AviarySHA256.hash(data: material)
            .map { String(format: "%02x", $0) }.joined()
        return "create-attachment-v1.\(digest)"
    }

    private func validateClient(_ client: ClientRef?) throws {
        guard let client, !client.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              client.clientID.utf8.count <= WorkServiceBounds.maxIdentityCharacters else {
            throw WorkServiceProtocolError.invalidRequest("client identity is not bounded")
        }
    }

    private func validateSessionTuple(
        _ session: SessionRef?, _ sessionJournal: JournalRef?, _ attachment: SessionAttachmentRef?,
        expectedSession: SessionRef, expectedJournal: JournalRef,
        expectedAttachment: SessionAttachmentRef
    ) throws {
        guard session == expectedSession, sessionJournal == expectedJournal,
              attachment == expectedAttachment else { throw WorkServiceProtocolError.journalMismatch }
    }

    private func normalizedSessionTuple(
        _ session: SessionRef?, _ journal: JournalRef?, _ attachment: SessionAttachmentRef?,
        source: CanonicalSource
    ) async throws -> (session: SessionRef, journal: JournalRef, attachment: SessionAttachmentRef) {
        if session == nil && journal == nil && attachment == nil {
            return (source.session, source.sessionJournal, source.sessionAttachment)
        }
        if session == source.session && journal == source.sessionJournal
                && attachment == source.sessionAttachment {
            return (source.session, source.sessionJournal, source.sessionAttachment)
        }
        let control = try await controlSnapshot()
        let relationships = try await sessionRelationships(for: source, control: control)
        guard let relationship = relationships.first(where: {
            $0.session == session && $0.sessionJournal == journal
                && $0.sessionAttachment == attachment && $0.isAttached
        }) else { throw WorkServiceProtocolError.journalMismatch }
        return (relationship.session, relationship.sessionJournal, relationship.sessionAttachment)
    }

    private func parsePageToken(_ token: String?, total: Int) throws -> Int {
        guard let token else { return 0 }
        guard let value = Int(token), value >= 0, value <= total else {
            throw WorkServiceProtocolError.invalidRequest("invalid page token")
        }
        return value
    }

    private func cursor(_ records: [TimelineJournalRecord], journal: JournalRef) -> JournalCursor {
        records.last.map { JournalCursor(journal: journal, eventID: $0.event.eventID, sequence: $0.event.sequence) }
            ?? JournalCursor(journal: journal, sequence: 0)
    }

    private func controlReceipt(
        _ operation: WorkServiceControlOperation, work: WorkRef, commandID: String,
        state: WorkServiceCommandReceiptState, causal: JournalCursor,
        resulting: JournalCursor, authorization: WorkServiceAuthorizationOutcome,
        outcome: WorkServiceControlOutcome? = nil
    ) -> WorkServiceControlReceipt {
        WorkServiceControlReceipt(
            operation: operation, work: work, commandID: commandID, state: state,
            host: hostInstance, causalControlCursor: causal,
            resultingControlCursor: resulting, authorization: authorization, outcome: outcome)
    }

    private func commandOutcome(_ kind: WorkServiceCommandKind) -> WorkServiceCommandOutcome? {
        switch kind {
        case .start: return .started
        case .send: return .inputAccepted
        case .steer: return .steeringAccepted
        case .queue: return .queued
        case .cancel: return .cancellationRequested
        case .end: return .endRequested
        case .hold: return .holdRequested
        case .destroy: return .destroyed
        case .complete: return .completed
        }
    }

    private func validDigest(_ value: String) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0].lowercased() == "sha256"
            && parts[1].count == 64 && parts[1].allSatisfy { $0.isHexDigit }
    }

    private func containsBodyReference(_ value: JSONValue, _ reference: TimelineBodyReference) -> Bool {
        if let data = try? JSONEncoder().encode(value),
           let decoded = try? JSONDecoder().decode(TimelineBodyReference.self, from: data), decoded == reference {
            return true
        }
        switch value {
        case .array(let values): return values.contains { containsBodyReference($0, reference) }
        case .object(let values): return values.values.contains { containsBodyReference($0, reference) }
        default: return false
        }
    }
}
