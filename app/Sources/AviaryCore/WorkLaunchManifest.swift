import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Launch material

/// Bounds for the host-private launch record.  These are deliberately independent of the
/// WorkService response bounds: a launch record is local reconstruction material and may retain
/// a workspace path, but it must never become an unbounded local database or a service payload.
public struct WorkLaunchManifestLimits: Codable, Hashable, Sendable {
    public static let `default` = WorkLaunchManifestLimits()

    public let maximumManifestBytes: Int
    public let maximumRecordBytes: Int
    public let maximumIdentityBytes: Int
    public let maximumPathBytes: Int
    public let maximumMetadataBytes: Int
    public let maximumBodyBytes: Int
    public let maximumArrayEntries: Int

    public init(
        maximumManifestBytes: Int = 128 * 1024,
        maximumRecordBytes: Int = 132 * 1024,
        maximumIdentityBytes: Int = 512,
        maximumPathBytes: Int = 4 * 1024,
        maximumMetadataBytes: Int = 8 * 1024,
        maximumBodyBytes: Int = 64 * 1024 * 1024,
        maximumArrayEntries: Int = 128
    ) {
        self.maximumManifestBytes = max(1, min(maximumManifestBytes, 4 * 1024 * 1024))
        self.maximumRecordBytes = max(1, min(maximumRecordBytes, 4 * 1024 * 1024))
        self.maximumIdentityBytes = max(1, min(maximumIdentityBytes, 4 * 1024))
        self.maximumPathBytes = max(1, min(maximumPathBytes, 64 * 1024))
        self.maximumMetadataBytes = max(1, min(maximumMetadataBytes, 64 * 1024))
        self.maximumBodyBytes = max(1, min(maximumBodyBytes, 512 * 1024 * 1024))
        self.maximumArrayEntries = max(1, min(maximumArrayEntries, 4_096))
    }
}

public enum WorkLaunchManifestStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidManifest(String)
    case wrongAuthority(expected: String, actual: String)
    case identityMismatch
    case invalidReference
    case bodyUnavailable
    case requestConflict
    case manifestTooLarge
    case recordTooLarge
    case malformedRecord
    case tamperedRecord
    case digestMismatch
    case symlinkOrNonRegularFile
    case accessDenied
    case notFound
    case generationMismatch
    case invalidGeneration
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let detail): return "Invalid Work launch manifest: " + detail + "."
        case .wrongAuthority(let expected, let actual):
            return "Work launch manifest authority mismatch (expected " + expected
                + ", got " + actual + ")."
        case .identityMismatch: return "Work launch manifest identity does not match its address."
        case .invalidReference: return "Work launch manifest body reference is invalid."
        case .bodyUnavailable: return "Work launch manifest body is unavailable or corrupted."
        case .requestConflict: return "Work launch manifest create request already has different material."
        case .manifestTooLarge: return "Work launch manifest exceeds its size bound."
        case .recordTooLarge: return "Work launch manifest record exceeds its size bound."
        case .malformedRecord: return "Work launch manifest record is malformed."
        case .tamperedRecord: return "Work launch manifest record failed integrity verification."
        case .digestMismatch: return "Work launch manifest digest does not match its content."
        case .symlinkOrNonRegularFile:
            return "Work launch manifest storage is not a regular private file."
        case .accessDenied: return "Work launch manifest storage is not privately owned."
        case .notFound: return "Work launch manifest was not found."
        case .generationMismatch: return "Work launch manifest generation is stale."
        case .invalidGeneration: return "Work launch manifest generation is invalid."
        case .ioFailure(let operation): return "Work launch manifest " + operation + " failed."
        }
    }
}

/// The identity that is sufficient to select one executable Work attempt after a service restart.
/// Every component is kept separate because a Session is not a Work and a Run is not a Session.
public struct WorkLaunchManifestIdentity: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let session: SessionRef
    public let sessionAttachment: SessionAttachmentRef
    public let run: RunRef

    public init(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        run: RunRef
    ) {
        self.work = work
        self.session = session
        self.sessionAttachment = sessionAttachment
        self.run = run
    }

    public init(identity: SessionWorkIdentity, sessionAttachment: SessionAttachmentRef) {
        self.init(
            work: identity.work, session: SessionRef(identity.sessionID),
            sessionAttachment: sessionAttachment, run: RunRef(identity.runID))
    }

    fileprivate var addressMaterial: String {
        [work.workHostID, work.workID, session.sessionID, sessionAttachment.attachmentID, run.runID]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "\u{0}")
    }
}

public struct WorkLaunchWorkspace: Codable, Hashable, Sendable {
    /// This locator is intentionally host-private. It is never copied into a WorkService
    /// descriptor; a remote client receives only the policy and public Work identity.
    public let locator: String
    public let policy: WorkHostWorkingDirectoryPolicy
    public let provenance: EventRef?

    public init(
        locator: String,
        policy: WorkHostWorkingDirectoryPolicy,
        provenance: EventRef? = nil
    ) {
        self.locator = locator
        self.policy = policy
        self.provenance = provenance
    }
}

public struct WorkLaunchRuntime: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String
    public let runtimeVariant: String
    public let provenance: EventRef?

    public init(
        providerID: String,
        modelID: String,
        runtimeVariant: String,
        provenance: EventRef? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.runtimeVariant = runtimeVariant
        self.provenance = provenance
    }
}

public struct WorkLaunchContextPolicy: Codable, Hashable, Sendable {
    public let includeContextFiles: Bool
    public let contextManifestID: String?
    public let maximumContextBytes: Int?
    public let provenance: EventRef?

    public init(
        includeContextFiles: Bool = true,
        contextManifestID: String? = nil,
        maximumContextBytes: Int? = nil,
        provenance: EventRef? = nil
    ) {
        self.includeContextFiles = includeContextFiles
        self.contextManifestID = contextManifestID
        self.maximumContextBytes = maximumContextBytes
        self.provenance = provenance
    }
}

public struct WorkLaunchRecordingPolicy: Codable, Hashable, Sendable {
    public let recordPayloads: Bool
    /// A host-private path. It is omitted from service descriptors and can be nil when recording
    /// is disabled. The path is metadata, never a credential or payload body.
    public let wireLogLocator: String?
    public let provenance: EventRef?

    public init(
        recordPayloads: Bool = false,
        wireLogLocator: String? = nil,
        provenance: EventRef? = nil
    ) {
        self.recordPayloads = recordPayloads
        self.wireLogLocator = wireLogLocator
        self.provenance = provenance
    }
}

/// Which compatibility Session projection operation a Work launch performs. This is intentionally
/// independent from model-context reconstruction: a replacement can append a new flat boundary
/// while still launching a provider with no prior conversation.
public enum WorkLaunchProjectionMode: String, Codable, Hashable, Sendable {
    case fresh
    case reopenHistorical = "reopen_historical"
}

/// Whether the provider receives a newly-launched context or the exact native context rebuilt from
/// the prior completed Run. This is not a statement about whether the flat Session file exists.
public enum WorkLaunchContextMode: String, Codable, Hashable, Sendable {
    case launchFresh = "launch_fresh"
    case exactColdResume = "exact_cold_resume"
}

/// The two independent choices made at Start admission. The source fields are optional metadata
/// for an exact cold resume and are persisted in ``WorkLaunchResumePolicy``.
public struct WorkLaunchExecutionPolicy: Codable, Hashable, Sendable {
    public let projection: WorkLaunchProjectionMode
    public let modelContext: WorkLaunchContextMode
    public let sourceSession: SessionRef?
    public let sourceRun: RunRef?

    public init(
        projection: WorkLaunchProjectionMode,
        modelContext: WorkLaunchContextMode,
        sourceSession: SessionRef? = nil,
        sourceRun: RunRef? = nil
    ) {
        self.projection = projection
        self.modelContext = modelContext
        self.sourceSession = sourceSession
        self.sourceRun = sourceRun
    }

    public var resumePolicy: WorkLaunchResumePolicy {
        WorkLaunchResumePolicy(
            mode: modelContext == .exactColdResume ? .coldResume : .fresh,
            sourceSession: modelContext == .exactColdResume ? sourceSession : nil,
            sourceRun: modelContext == .exactColdResume ? sourceRun : nil)
    }
}

public enum WorkLaunchResumeMode: String, Codable, Hashable, Sendable {
    case fresh
    case coldResume = "cold_resume"
}

public struct WorkLaunchResumePolicy: Codable, Hashable, Sendable {
    public let mode: WorkLaunchResumeMode
    public let sourceSession: SessionRef?
    public let sourceRun: RunRef?
    public let provenance: EventRef?

    public init(
        mode: WorkLaunchResumeMode = .fresh,
        sourceSession: SessionRef? = nil,
        sourceRun: RunRef? = nil,
        provenance: EventRef? = nil
    ) {
        self.mode = mode
        self.sourceSession = sourceSession
        self.sourceRun = sourceRun
        self.provenance = provenance
    }
}

public struct WorkLaunchReasoningPolicy: Codable, Hashable, Sendable {
    public let enabled: Bool
    public let level: String?
    public let tokenBudget: Int?
    public let provenance: EventRef?

    public init(
        enabled: Bool = false,
        level: String? = nil,
        tokenBudget: Int? = nil,
        provenance: EventRef? = nil
    ) {
        self.enabled = enabled
        self.level = level
        self.tokenBudget = tokenBudget
        self.provenance = provenance
    }
}

public struct WorkLaunchBudgetPolicy: Codable, Hashable, Sendable {
    public let maximumTurns: Int?
    /// Hosted execution's bounded recursion policy. These remain optional so a producer can
    /// explicitly select the host defaults, but a resolver must attest any non-default value.
    public let maximumDepth: Int?
    public let childMaximumTurns: Int?
    public let maximumTokens: Int?
    public let maximumWallClockSeconds: Int?
    public let provenance: EventRef?

    public init(
        maximumTurns: Int? = nil,
        maximumDepth: Int? = nil,
        childMaximumTurns: Int? = nil,
        maximumTokens: Int? = nil,
        maximumWallClockSeconds: Int? = nil,
        provenance: EventRef? = nil
    ) {
        self.maximumTurns = maximumTurns
        self.maximumDepth = maximumDepth
        self.childMaximumTurns = childMaximumTurns
        self.maximumTokens = maximumTokens
        self.maximumWallClockSeconds = maximumWallClockSeconds
        self.provenance = provenance
    }
}

public struct WorkLaunchGoalConfiguration: Codable, Hashable, Sendable {
    public let goalID: String?
    public let summary: String?
    public let mode: String?
    public let provenance: EventRef?

    public init(
        goalID: String? = nil,
        summary: String? = nil,
        mode: String? = nil,
        provenance: EventRef? = nil
    ) {
        self.goalID = goalID
        self.summary = summary
        self.mode = mode
        self.provenance = provenance
    }
}

public struct WorkLaunchHookConfiguration: Codable, Hashable, Sendable {
    public let hookID: String
    public let phase: String
    public let enabled: Bool
    public let provenance: EventRef?

    public init(
        hookID: String,
        phase: String,
        enabled: Bool = true,
        provenance: EventRef? = nil
    ) {
        self.hookID = hookID
        self.phase = phase
        self.enabled = enabled
        self.provenance = provenance
    }
}

public struct WorkLaunchPeerSchedulerConfiguration: Codable, Hashable, Sendable {
    public let enabled: Bool
    public let maximumPeers: Int
    public let queuePolicy: String
    public let provenance: EventRef?

    public init(
        enabled: Bool = false,
        maximumPeers: Int = 0,
        queuePolicy: String = "serial",
        provenance: EventRef? = nil
    ) {
        self.enabled = enabled
        self.maximumPeers = maximumPeers
        self.queuePolicy = queuePolicy
        self.provenance = provenance
    }
}

public struct WorkLaunchManifestProvenance: Codable, Hashable, Sendable {
    public let source: String
    public let sourceEvent: EventRef?
    public let sourceCursor: JournalCursor?
    public let recordedAt: Date

    public init(
        source: String,
        sourceEvent: EventRef? = nil,
        sourceCursor: JournalCursor? = nil,
        recordedAt: Date = Date()
    ) {
        self.source = source
        self.sourceEvent = sourceEvent
        self.sourceCursor = sourceCursor
        self.recordedAt = recordedAt
    }
}

/// Durable, metadata-only provenance for the exact system prompt admitted by Start.
///
/// The flattened prompt and each producer source are retained in ``ContextBodyStore``.  This
/// value contains only content-addressed references and bounded metadata, so a manifest can be
/// inspected or copied without putting prompt text, file paths, or memory contents into its JSON.
public struct WorkLaunchPromptAssembly: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let flattenedBodyReference: TimelineBodyReference
    public let flattenedByteCount: Int
    public let flattenedDigest: String
    public let sources: [ContextManifestSource]
    public let provenance: WorkLaunchManifestProvenance

    public init(
        flattenedBodyReference: TimelineBodyReference,
        flattenedByteCount: Int,
        flattenedDigest: String,
        sources: [ContextManifestSource],
        provenance: WorkLaunchManifestProvenance
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.flattenedBodyReference = flattenedBodyReference
        self.flattenedByteCount = flattenedByteCount
        self.flattenedDigest = flattenedDigest
        self.sources = sources
        self.provenance = provenance
    }

    public var flattenedBodyRef: TimelineBodyReference { flattenedBodyReference }

    /// Rehydrate the exact producer decomposition from retained bytes. No ambient files,
    /// settings, skills, or memory stores are consulted by this operation.
    public func materialize(using bodyStore: ContextBodyStore) throws -> SystemPromptAssembly {
        guard schemaVersion == Self.currentSchemaVersion,
              flattenedByteCount >= 0,
              flattenedDigest == flattenedBodyReference.digest,
              flattenedBodyReference.referenceID == flattenedDigest,
              ContextBodyStore.isValidDigest(flattenedDigest),
              flattenedBodyReference.byteCount == flattenedByteCount else {
            throw WorkLaunchManifestStoreError.invalidReference
        }
        let flattenedData: Data
        do {
            flattenedData = try bodyStore.read(flattenedBodyReference)
        } catch {
            throw WorkLaunchManifestStoreError.bodyUnavailable
        }
        guard flattenedData.count == flattenedByteCount,
              Self.digest(flattenedData) == flattenedDigest,
              let flattenedText = String(data: flattenedData, encoding: .utf8) else {
            throw WorkLaunchManifestStoreError.bodyUnavailable
        }

        var offset = 0
        var materialized: [PromptSource] = []
        materialized.reserveCapacity(sources.count)
        for source in sources {
            let full = try Self.read(
                source.fullBodyReference, expectedDigest: source.fullDigest,
                expectedByteCount: source.fullByteCount, bodyStore: bodyStore,
                required: source.status == .present || source.status == .truncated)
            let delivered = try Self.read(
                source.deliveredBodyReference, expectedDigest: source.deliveredDigest,
                expectedByteCount: source.deliveredByteCount, bodyStore: bodyStore, required: true)
            let rendered = try Self.read(
                source.renderedBodyReference, expectedDigest: source.renderedDigest,
                expectedByteCount: source.renderedByteCount, bodyStore: bodyStore, required: true)
            guard let delivered, let rendered,
                  let deliveredText = String(data: delivered, encoding: .utf8),
                  let renderedText = String(data: rendered, encoding: .utf8) else {
                throw WorkLaunchManifestStoreError.bodyUnavailable
            }
            let fullText = full.flatMap { String(data: $0, encoding: .utf8) }
            guard full == nil || fullText != nil else {
                throw WorkLaunchManifestStoreError.bodyUnavailable
            }
            if source.status == .truncated {
                guard let fullText, fullText.hasPrefix(deliveredText) else {
                    throw WorkLaunchManifestStoreError.tamperedRecord
                }
            }
            let promptSource = try PromptSource(
                sourceID: source.sourceID, kind: source.kind, label: source.label,
                identity: nil, status: source.status, fullBody: fullText,
                deliveredBody: deliveredText, renderedBody: renderedText,
                deliveredByteOffsetInRendered: source.deliveredByteOffsetInRendered,
                renderedByteOffset: offset)
            materialized.append(promptSource)
            offset += promptSource.renderedByteCount
        }
        guard offset == flattenedByteCount else {
            throw WorkLaunchManifestStoreError.invalidManifest("prompt source byte accounting")
        }
        do {
            return try SystemPromptAssembly(text: flattenedText, sources: materialized)
        } catch {
            throw WorkLaunchManifestStoreError.tamperedRecord
        }
    }

    private static func read(
        _ reference: TimelineBodyReference?, expectedDigest: String?, expectedByteCount: Int?,
        bodyStore: ContextBodyStore, required: Bool
    ) throws -> Data? {
        guard let reference else {
            if required { throw WorkLaunchManifestStoreError.invalidReference }
            return nil
        }
        guard let digest = reference.digest,
              reference.referenceID == digest,
              digest == expectedDigest,
              ContextBodyStore.isValidDigest(digest),
              let byteCount = reference.byteCount,
              byteCount == expectedByteCount,
              byteCount >= 0 else {
            throw WorkLaunchManifestStoreError.invalidReference
        }
        do {
            let data = try bodyStore.read(reference)
            guard data.count == byteCount, Self.digest(data) == digest else {
                throw WorkLaunchManifestStoreError.bodyUnavailable
            }
            return data
        } catch let error as WorkLaunchManifestStoreError {
            throw error
        } catch {
            throw WorkLaunchManifestStoreError.bodyUnavailable
        }
    }

    private static func digest(_ data: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Pre-reservation launch material. A Work service may retain input/system bodies and this
/// configuration before its control journal mints Work/Session/attachment identities.  It is not
/// executable and has no identity; `bind(to:)` is the only path to the verified manifest used by
/// a host. This makes the durable order explicit: retain bytes -> reserve identities -> bind and
/// publish the final manifest.
public struct WorkLaunchManifestDraft: Codable, Hashable, Sendable {
    public let workspace: WorkLaunchWorkspace
    public let runtime: WorkLaunchRuntime
    /// The exact bounded request configuration which produced this draft.  Requested provider
    /// and model values intentionally remain optional here: the runtime below records the
    /// resolved route, while this field preserves what the caller actually asked for across a
    /// process restart.
    public let configuration: WorkServiceWorkConfiguration
    /// The bounded capability set requested by the Create caller. This is retained with the
    /// Run-free template so an exact Create retry can reject changed authority claims.
    public let requestedCapabilities: Set<WorkServiceCapability>
    public let contextPolicy: WorkLaunchContextPolicy
    public let recordingPolicy: WorkLaunchRecordingPolicy
    public let resumePolicy: WorkLaunchResumePolicy
    public let reasoningPolicy: WorkLaunchReasoningPolicy
    public let budgetPolicy: WorkLaunchBudgetPolicy
    public let goal: WorkLaunchGoalConfiguration
    public let hooks: [WorkLaunchHookConfiguration]
    public let peerScheduler: WorkLaunchPeerSchedulerConfiguration
    public let provenance: WorkLaunchManifestProvenance

    public init(
        workspace: WorkLaunchWorkspace,
        runtime: WorkLaunchRuntime,
        configuration: WorkServiceWorkConfiguration,
        requestedCapabilities: Set<WorkServiceCapability>,
        contextPolicy: WorkLaunchContextPolicy = WorkLaunchContextPolicy(),
        recordingPolicy: WorkLaunchRecordingPolicy = WorkLaunchRecordingPolicy(),
        resumePolicy: WorkLaunchResumePolicy = WorkLaunchResumePolicy(),
        reasoningPolicy: WorkLaunchReasoningPolicy = WorkLaunchReasoningPolicy(),
        budgetPolicy: WorkLaunchBudgetPolicy = WorkLaunchBudgetPolicy(),
        goal: WorkLaunchGoalConfiguration = WorkLaunchGoalConfiguration(),
        hooks: [WorkLaunchHookConfiguration] = [],
        peerScheduler: WorkLaunchPeerSchedulerConfiguration =
            WorkLaunchPeerSchedulerConfiguration(),
        provenance: WorkLaunchManifestProvenance =
            WorkLaunchManifestProvenance(source: "unknown")
    ) {
        self.workspace = workspace
        self.runtime = runtime
        self.configuration = configuration
        self.requestedCapabilities = requestedCapabilities
        self.contextPolicy = contextPolicy
        self.recordingPolicy = recordingPolicy
        self.resumePolicy = resumePolicy
        self.reasoningPolicy = reasoningPolicy
        self.budgetPolicy = budgetPolicy
        self.goal = goal
        self.hooks = hooks
        self.peerScheduler = peerScheduler
        self.provenance = provenance
    }

    public func canonicalBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Set's synthesized Codable order is not stable across a decode/re-encode or process
        // restart. Normalize this one set before content-addressing the draft.
        guard var object = try JSONSerialization.jsonObject(
            with: encoder.encode(self)) as? [String: Any] else {
            throw WorkLaunchManifestStoreError.invalidManifest("draft encoding")
        }
        object["requestedCapabilities"] = requestedCapabilities.map(\.rawValue).sorted()
        return try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public func contentDigest() throws -> String {
        "sha256:" + AviarySHA256.hash(data: try canonicalBytes())
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Digest of the request material with only the recording clock normalized. The exact
    /// content digest still includes `recordedAt`; this companion digest lets a retried Create
    /// use the same externally supplied key even when it reconstructed an otherwise identical
    /// draft in a new process.
    public func idempotencyDigest() throws -> String {
        let normalized = WorkLaunchManifestDraft(
            workspace: workspace, runtime: runtime,
            configuration: configuration,
            requestedCapabilities: requestedCapabilities,
            contextPolicy: contextPolicy, recordingPolicy: recordingPolicy,
            resumePolicy: resumePolicy, reasoningPolicy: reasoningPolicy,
            budgetPolicy: budgetPolicy, goal: goal, hooks: hooks,
            peerScheduler: peerScheduler,
            provenance: WorkLaunchManifestProvenance(
                source: provenance.source, sourceEvent: provenance.sourceEvent,
                sourceCursor: provenance.sourceCursor, recordedAt: Date(timeIntervalSince1970: 0)))
        return try normalized.contentDigest()
    }

    /// Return the same retained launch material with the Start-selected context policy. Create is
    /// Run-free, so a replacement's exact cold-resume decision is applied only when Start binds a
    /// final identity-bound manifest.
    public func withResumePolicy(_ policy: WorkLaunchResumePolicy) -> WorkLaunchManifestDraft {
        WorkLaunchManifestDraft(
            workspace: workspace, runtime: runtime,
            configuration: configuration,
            requestedCapabilities: requestedCapabilities,
            contextPolicy: contextPolicy, recordingPolicy: recordingPolicy,
            resumePolicy: policy, reasoningPolicy: reasoningPolicy,
            budgetPolicy: budgetPolicy, goal: goal, hooks: hooks,
            peerScheduler: peerScheduler, provenance: provenance)
    }

    internal func bind(
        to binding: WorkRunBinding, startIntent: WorkLaunchStartIntent,
        initialInputBodyReference: TimelineBodyReference? = nil,
        promptAssembly: WorkLaunchPromptAssembly? = nil
    ) throws -> WorkLaunchManifest {
        guard binding.workBinding.workHost == WorkHostRef(binding.workBinding.work.workHostID) else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        return WorkLaunchManifest(
            identity: WorkLaunchManifestIdentity(
                work: binding.workBinding.work, session: binding.workBinding.session,
                sessionAttachment: binding.workBinding.sessionAttachment, run: binding.run),
            startIntent: startIntent,
            workspaceID: configuration.workspaceID,
            workspace: workspace, runtime: runtime,
            initialInputBodyReference: initialInputBodyReference,
            promptAssembly: promptAssembly,
            // A Run-free draft never contributes a prompt body. The flattened reference is
            // introduced only by the retained Start-time assembly.
            systemPromptBodyReference: promptAssembly?.flattenedBodyReference,
            contextPolicy: contextPolicy, recordingPolicy: recordingPolicy,
            resumePolicy: resumePolicy, reasoningPolicy: reasoningPolicy,
            budgetPolicy: budgetPolicy, goal: goal, hooks: hooks,
            peerScheduler: peerScheduler, provenance: provenance)
    }

    fileprivate func validate(limits: WorkLaunchManifestLimits) throws {
        guard !workspace.locator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              workspace.locator.utf8.count <= limits.maximumPathBytes,
              !workspace.locator.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkLaunchManifestStoreError.invalidManifest("draft workspace locator")
        }
        let strings = [runtime.providerID, runtime.modelID, runtime.runtimeVariant,
                       peerScheduler.queuePolicy, provenance.source]
        guard strings.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.utf8.count <= limits.maximumMetadataBytes
                && !$0.unicodeScalars.contains(where: { $0.value == 0 })
        }) else { throw WorkLaunchManifestStoreError.invalidManifest("draft metadata") }
        try validateRequestedConfiguration()
        guard hooks.count <= limits.maximumArrayEntries else {
            throw WorkLaunchManifestStoreError.invalidManifest("too many draft hooks")
        }
        guard requestedCapabilities.isSubset(of: Set(WorkServiceCapability.allCases)) else {
            throw WorkLaunchManifestStoreError.invalidManifest("unknown requested capability")
        }
        for hook in hooks where hook.hookID.utf8.count > limits.maximumMetadataBytes
            || hook.phase.utf8.count > limits.maximumMetadataBytes {
            throw WorkLaunchManifestStoreError.invalidManifest("draft hook metadata")
        }
        let budgets = [
            contextPolicy.maximumContextBytes, reasoningPolicy.tokenBudget,
            budgetPolicy.maximumTurns, budgetPolicy.maximumTokens,
            budgetPolicy.maximumWallClockSeconds,
        ]
        guard budgets.compactMap({ $0 }).allSatisfy({ $0 >= 0 }),
              peerScheduler.maximumPeers >= 0 else {
            throw WorkLaunchManifestStoreError.invalidManifest("negative draft budget")
        }
        guard try canonicalBytes().count <= limits.maximumManifestBytes else {
            throw WorkLaunchManifestStoreError.manifestTooLarge
        }
    }

    /// Validate the request/configuration seam while retaining nil requested route fields as nil.
    /// A resolver may choose a default provider or model, but it may not silently execute a
    /// different explicitly requested value after a restart.
    private func validateRequestedConfiguration() throws {
        let values = [configuration.providerID, configuration.modelID,
                      configuration.thinkingLevel, configuration.contextPolicy,
                      configuration.resumePolicy]
        guard !configuration.wasTruncated,
              values.allSatisfy({ ($0?.utf8.count ?? 0) <= WorkServiceBounds.maxCommandValueCharacters })
        else { throw WorkLaunchManifestStoreError.invalidManifest("requested configuration") }
        if let provider = configuration.providerID, provider != runtime.providerID {
            throw WorkLaunchManifestStoreError.invalidManifest(
                "requested provider does not match resolved runtime")
        }
        if let model = configuration.modelID {
            let matchesResolvedModel = model == runtime.modelID
                || (configuration.providerID == nil
                    && model == "\(runtime.providerID)/\(runtime.modelID)")
            guard matchesResolvedModel else {
                throw WorkLaunchManifestStoreError.invalidManifest(
                    "requested model does not match resolved runtime")
            }
        }
        if let thinking = configuration.thinkingLevel, thinking != reasoningPolicy.level {
            throw WorkLaunchManifestStoreError.invalidManifest(
                "requested reasoning level does not match resolved policy")
        }
        if let context = configuration.contextPolicy,
           context != contextPolicy.contextManifestID {
            throw WorkLaunchManifestStoreError.invalidManifest(
                "requested context policy does not match resolved policy")
        }
        guard configuration.includeContextFiles == contextPolicy.includeContextFiles,
              configuration.recordPayloads == recordingPolicy.recordPayloads else {
            throw WorkLaunchManifestStoreError.invalidManifest(
                "requested context or recording policy does not match resolved policy")
        }
        if let resume = configuration.resumePolicy,
           resume != resumePolicy.mode.rawValue {
            throw WorkLaunchManifestStoreError.invalidManifest(
                "requested resume policy does not match resolved policy")
        }
    }
}

/// Host-private reconstruction material. The input and flattened system bodies are never fields
/// here: each is retained by `ContextBodyStore` and addressed only by its verified,
/// authority-qualified body reference. This type is therefore safe to keep out of service
/// descriptors and list pages.
public struct WorkLaunchManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let identity: WorkLaunchManifestIdentity
    public let startIntent: WorkLaunchStartIntent
    /// The opaque host workspace selection is retained alongside the host-private resolved path
    /// so a restart can revalidate the identity before using that path.
    public let workspaceID: WorkHostWorkspaceID?
    public let workspace: WorkLaunchWorkspace
    public let runtime: WorkLaunchRuntime
    public let initialInputBodyReference: TimelineBodyReference?
    /// The Start-time prompt admission. Native launch requires this record. It remains optional in
    /// the value shape only so malformed/source-less records can be rejected by validation without
    /// distorting the separate Run-free draft type.
    public let promptAssembly: WorkLaunchPromptAssembly?
    public let systemPromptBodyReference: TimelineBodyReference?
    public let contextPolicy: WorkLaunchContextPolicy
    public let recordingPolicy: WorkLaunchRecordingPolicy
    public let resumePolicy: WorkLaunchResumePolicy
    public let reasoningPolicy: WorkLaunchReasoningPolicy
    public let budgetPolicy: WorkLaunchBudgetPolicy
    public let goal: WorkLaunchGoalConfiguration
    public let hooks: [WorkLaunchHookConfiguration]
    public let peerScheduler: WorkLaunchPeerSchedulerConfiguration
    public let provenance: WorkLaunchManifestProvenance

    public init(
        identity: WorkLaunchManifestIdentity,
        startIntent: WorkLaunchStartIntent,
        workspaceID: WorkHostWorkspaceID? = nil,
        workspace: WorkLaunchWorkspace,
        runtime: WorkLaunchRuntime,
        initialInputBodyReference: TimelineBodyReference? = nil,
        promptAssembly: WorkLaunchPromptAssembly? = nil,
        systemPromptBodyReference: TimelineBodyReference? = nil,
        contextPolicy: WorkLaunchContextPolicy = WorkLaunchContextPolicy(),
        recordingPolicy: WorkLaunchRecordingPolicy = WorkLaunchRecordingPolicy(),
        resumePolicy: WorkLaunchResumePolicy = WorkLaunchResumePolicy(),
        reasoningPolicy: WorkLaunchReasoningPolicy = WorkLaunchReasoningPolicy(),
        budgetPolicy: WorkLaunchBudgetPolicy = WorkLaunchBudgetPolicy(),
        goal: WorkLaunchGoalConfiguration = WorkLaunchGoalConfiguration(),
        hooks: [WorkLaunchHookConfiguration] = [],
        peerScheduler: WorkLaunchPeerSchedulerConfiguration =
            WorkLaunchPeerSchedulerConfiguration(),
        provenance: WorkLaunchManifestProvenance =
            WorkLaunchManifestProvenance(source: "unknown")
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.identity = identity
        self.startIntent = startIntent
        self.workspaceID = workspaceID
        self.workspace = workspace
        self.runtime = runtime
        self.initialInputBodyReference = initialInputBodyReference
        self.promptAssembly = promptAssembly
        self.systemPromptBodyReference = systemPromptBodyReference
        self.contextPolicy = contextPolicy
        self.recordingPolicy = recordingPolicy
        self.resumePolicy = resumePolicy
        self.reasoningPolicy = reasoningPolicy
        self.budgetPolicy = budgetPolicy
        self.goal = goal
        self.hooks = hooks
        self.peerScheduler = peerScheduler
        self.provenance = provenance
    }

    /// The exact canonical metadata bytes used for the content address. No prompt bytes are
    /// included because both body fields are `TimelineBodyReference` values.
    public func canonicalBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func contentDigest() throws -> String {
        "sha256:" + AviarySHA256.hash(data: try canonicalBytes())
            .map { String(format: "%02x", $0) }.joined()
    }

    public var initialInputBodyDigest: String? { initialInputBodyReference?.digest }
    public var systemPromptBodyDigest: String? { systemPromptBodyReference?.digest }
    public var promptAssemblyBodyDigest: String? { promptAssembly?.flattenedDigest }

    public func withInitialInputBodyReference(_ reference: TimelineBodyReference?) -> WorkLaunchManifest {
        WorkLaunchManifest(
            identity: identity, startIntent: startIntent, workspaceID: workspaceID,
            workspace: workspace, runtime: runtime,
            initialInputBodyReference: reference,
            promptAssembly: promptAssembly,
            systemPromptBodyReference: systemPromptBodyReference, contextPolicy: contextPolicy,
            recordingPolicy: recordingPolicy, resumePolicy: resumePolicy,
            reasoningPolicy: reasoningPolicy, budgetPolicy: budgetPolicy, goal: goal,
            hooks: hooks, peerScheduler: peerScheduler, provenance: provenance)
    }

    public func withSystemPromptBodyReference(_ reference: TimelineBodyReference?) -> WorkLaunchManifest {
        WorkLaunchManifest(
            identity: identity, startIntent: startIntent, workspaceID: workspaceID,
            workspace: workspace, runtime: runtime,
            initialInputBodyReference: initialInputBodyReference,
            promptAssembly: promptAssembly,
            systemPromptBodyReference: reference, contextPolicy: contextPolicy,
            recordingPolicy: recordingPolicy, resumePolicy: resumePolicy,
            reasoningPolicy: reasoningPolicy, budgetPolicy: budgetPolicy, goal: goal,
            hooks: hooks, peerScheduler: peerScheduler, provenance: provenance)
    }

    public func withResumePolicy(_ policy: WorkLaunchResumePolicy) -> WorkLaunchManifest {
        WorkLaunchManifest(
            identity: identity, startIntent: startIntent, workspaceID: workspaceID,
            workspace: workspace, runtime: runtime,
            initialInputBodyReference: initialInputBodyReference,
            promptAssembly: promptAssembly,
            systemPromptBodyReference: systemPromptBodyReference, contextPolicy: contextPolicy,
            recordingPolicy: recordingPolicy, resumePolicy: policy,
            reasoningPolicy: reasoningPolicy, budgetPolicy: budgetPolicy, goal: goal,
            hooks: hooks, peerScheduler: peerScheduler, provenance: provenance)
    }

    public func withPromptAssembly(_ assembly: WorkLaunchPromptAssembly?) -> WorkLaunchManifest {
        WorkLaunchManifest(
            identity: identity, startIntent: startIntent, workspaceID: workspaceID,
            workspace: workspace, runtime: runtime,
            initialInputBodyReference: initialInputBodyReference,
            promptAssembly: assembly,
            systemPromptBodyReference: assembly?.flattenedBodyReference,
            contextPolicy: contextPolicy, recordingPolicy: recordingPolicy,
            resumePolicy: resumePolicy, reasoningPolicy: reasoningPolicy,
            budgetPolicy: budgetPolicy, goal: goal, hooks: hooks,
            peerScheduler: peerScheduler, provenance: provenance)
    }

    fileprivate func validate(
        limits: WorkLaunchManifestLimits,
        expectedAuthority: String? = nil
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkLaunchManifestStoreError.invalidManifest("unsupported schema")
        }
        try Self.validateIdentity(identity, limits: limits)
        try Self.validateStartIntent(
            startIntent, identity: identity, bodyReference: initialInputBodyReference, limits: limits)
        if let expectedAuthority, identity.work.workHostID != expectedAuthority {
            throw WorkLaunchManifestStoreError.wrongAuthority(
                expected: expectedAuthority, actual: identity.work.workHostID)
        }
        try Self.validatePath(workspace.locator, limits: limits, required: true)
        try Self.validateOptionalString(workspace.policy.rawValue, name: "workspace policy", limits: limits)
        try Self.validateString(runtime.providerID, name: "provider", limits: limits)
        try Self.validateString(runtime.modelID, name: "model", limits: limits)
        try Self.validateString(runtime.runtimeVariant, name: "runtime variant", limits: limits)
        try Self.validateOptionalString(contextPolicy.contextManifestID, name: "context manifest", limits: limits)
        try Self.validateNonNegative(contextPolicy.maximumContextBytes, name: "context budget")
        try Self.validatePath(recordingPolicy.wireLogLocator, limits: limits, required: false)
        try Self.validateOptionalString(reasoningPolicy.level, name: "reasoning level", limits: limits)
        try Self.validateNonNegative(reasoningPolicy.tokenBudget, name: "reasoning budget")
        try Self.validateNonNegative(budgetPolicy.maximumTurns, name: "turn budget")
        try Self.validateNonNegative(budgetPolicy.maximumDepth, name: "depth budget")
        try Self.validateNonNegative(
            budgetPolicy.childMaximumTurns, name: "child turn budget")
        try Self.validateNonNegative(budgetPolicy.maximumTokens, name: "token budget")
        try Self.validateNonNegative(
            budgetPolicy.maximumWallClockSeconds, name: "wall clock budget")
        try Self.validateOptionalString(goal.goalID, name: "goal id", limits: limits)
        try Self.validateOptionalString(goal.summary, name: "goal summary", limits: limits)
        try Self.validateOptionalString(goal.mode, name: "goal mode", limits: limits)
        guard hooks.count <= limits.maximumArrayEntries else {
            throw WorkLaunchManifestStoreError.invalidManifest("too many hooks")
        }
        for hook in hooks {
            try Self.validateString(hook.hookID, name: "hook id", limits: limits)
            try Self.validateString(hook.phase, name: "hook phase", limits: limits)
        }
        try Self.validateNonNegative(peerScheduler.maximumPeers, name: "peer limit")
        try Self.validateString(peerScheduler.queuePolicy, name: "peer queue policy", limits: limits)
        try Self.validateString(provenance.source, name: "provenance source", limits: limits)
        try Self.validateCursor(provenance.sourceEvent, cursor: provenance.sourceCursor)
        try Self.validateBodyReference(
            initialInputBodyReference, identity: identity, limits: limits)
        try Self.validateBodyReference(
            systemPromptBodyReference, identity: identity, limits: limits)
        guard let promptAssembly else {
            throw WorkLaunchManifestStoreError.invalidReference
        }
        try Self.validatePromptAssembly(
            promptAssembly, identity: identity, limits: limits)
        guard systemPromptBodyReference == promptAssembly.flattenedBodyReference else {
            throw WorkLaunchManifestStoreError.invalidReference
        }

        let bytes = try canonicalBytes()
        guard bytes.count <= limits.maximumManifestBytes else {
            throw WorkLaunchManifestStoreError.manifestTooLarge
        }
    }

    fileprivate static func validateIdentity(
        _ identity: WorkLaunchManifestIdentity, limits: WorkLaunchManifestLimits
    ) throws {
        let values = [
            identity.work.workHostID, identity.work.workID, identity.session.sessionID,
            identity.sessionAttachment.attachmentID, identity.run.runID,
        ]
        guard values.allSatisfy({ validIdentity($0, maximumBytes: limits.maximumIdentityBytes) }) else {
            throw WorkLaunchManifestStoreError.invalidManifest("identity is empty or oversized")
        }
    }

    fileprivate static func validateStartIntent(
        _ intent: WorkLaunchStartIntent, identity: WorkLaunchManifestIdentity,
        bodyReference: TimelineBodyReference?,
        limits: WorkLaunchManifestLimits
    ) throws {
        try validateString(intent.client.clientID, name: "start client", limits: limits)
        try validateString(intent.commandID, name: "start command", limits: limits)
        guard intent.causalWorkCursor.sequence >= 0,
              intent.causalWorkCursor.journal.owner == .work(identity.work),
              intent.causalWorkCursor.journal.authority.authorityID == identity.work.workHostID else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        guard ContextBodyStore.isValidDigest(intent.bodyDigest),
              intent.bodyDigest == bodyReference?.digest else {
            throw WorkLaunchManifestStoreError.invalidReference
        }
    }

    private static func validIdentity(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func validateString(
        _ value: String, name: String, limits: WorkLaunchManifestLimits
    ) throws {
        guard validIdentity(value, maximumBytes: limits.maximumMetadataBytes) else {
            throw WorkLaunchManifestStoreError.invalidManifest(name + " is empty or oversized")
        }
    }

    private static func validateOptionalString(
        _ value: String?, name: String, limits: WorkLaunchManifestLimits
    ) throws {
        if let value { try validateString(value, name: name, limits: limits) }
    }

    private static func validatePath(
        _ value: String?, limits: WorkLaunchManifestLimits, required: Bool
    ) throws {
        guard let value else {
            if required { throw WorkLaunchManifestStoreError.invalidManifest("workspace locator is missing") }
            return
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= limits.maximumPathBytes,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkLaunchManifestStoreError.invalidManifest("path is empty or oversized")
        }
    }

    private static func validateNonNegative(_ value: Int?, name: String) throws {
        if let value, value < 0 {
            throw WorkLaunchManifestStoreError.invalidManifest(name + " is negative")
        }
    }

    private static func validateCursor(_ event: EventRef?, cursor: JournalCursor?) throws {
        guard let event else {
            guard cursor == nil else {
                throw WorkLaunchManifestStoreError.invalidManifest("cursor has no source event")
            }
            return
        }
        if let cursor,
           (cursor.journal != event.journal || cursor.eventID != event.eventID || cursor.sequence < 0) {
            throw WorkLaunchManifestStoreError.invalidManifest("provenance cursor mismatch")
        }
    }

    fileprivate static func validateBodyReference(
        _ reference: TimelineBodyReference?, identity: WorkLaunchManifestIdentity,
        limits: WorkLaunchManifestLimits
    ) throws {
        guard let reference else { return }
        guard let digest = reference.digest,
              ContextBodyStore.isValidDigest(digest),
              reference.referenceID == digest,
              let byteCount = reference.byteCount,
              byteCount >= 0,
              byteCount <= limits.maximumBodyBytes,
              reference.referenceID.utf8.count <= limits.maximumIdentityBytes else {
            throw WorkLaunchManifestStoreError.invalidReference
        }
        let ownerMatches: Bool
        switch reference.authority.owner {
        case .work(let work): ownerMatches = work == identity.work
        case .session(let session): ownerMatches = session == identity.session
        case .workHost(let host): ownerMatches = host.workHostID == identity.work.workHostID
        }
        guard ownerMatches,
              reference.authority.authority.authorityID == identity.work.workHostID else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
    }

    fileprivate static func validateTemplateBodyReference(
        _ reference: TimelineBodyReference?, identity: WorkLaunchManifestIdentity,
        limits: WorkLaunchManifestLimits
    ) throws {
        try validateBodyReference(reference, identity: identity, limits: limits)
    }

    fileprivate static func validatePromptAssembly(
        _ assembly: WorkLaunchPromptAssembly,
        identity: WorkLaunchManifestIdentity,
        limits: WorkLaunchManifestLimits
    ) throws {
        guard assembly.schemaVersion == WorkLaunchPromptAssembly.currentSchemaVersion
        else { throw WorkLaunchManifestStoreError.invalidManifest("prompt schema") }
        guard assembly.sources.count <= limits.maximumArrayEntries
        else { throw WorkLaunchManifestStoreError.invalidManifest("prompt source count") }
        guard assembly.flattenedByteCount >= 0,
              assembly.flattenedByteCount <= limits.maximumBodyBytes
        else { throw WorkLaunchManifestStoreError.invalidReference }
        guard ContextBodyStore.isValidDigest(assembly.flattenedDigest),
              assembly.flattenedDigest == assembly.flattenedBodyReference.digest,
              assembly.flattenedBodyReference.referenceID == assembly.flattenedDigest,
              assembly.flattenedBodyReference.byteCount == assembly.flattenedByteCount
        else { throw WorkLaunchManifestStoreError.invalidReference }
        try validateBodyReference(
            assembly.flattenedBodyReference, identity: identity, limits: limits)

        var sourceIDs = Set<String>()
        var inclusionIDs = Set<String>()
        var renderedTotal = 0
        for (index, source) in assembly.sources.enumerated() {
            let expectedInclusionID = "prompt-source-v1-\(index)-"
                + String(WorkLaunchDurableIO.digest(Data(source.sourceID.utf8))
                    .dropFirst("sha256:".count))
            guard sourceIDs.insert(source.sourceID).inserted,
                  inclusionIDs.insert(source.inclusionID).inserted,
                  source.inclusionID == expectedInclusionID,
                  validIdentity(source.sourceID, maximumBytes: limits.maximumIdentityBytes),
                  validIdentity(source.inclusionID, maximumBytes: limits.maximumIdentityBytes),
                  validIdentity(source.label, maximumBytes: limits.maximumMetadataBytes),
                  !source.sourceID.contains("/"), !source.sourceID.contains("\\"),
                  source.label == "source-\(index)-\(source.kind.rawValue)",
                  source.provenance == nil || source.provenance == assembly.provenance.sourceEvent,
                  source.deliveredByteCount >= 0,
                  source.renderedByteCount >= 0,
                  source.deliveredByteOffsetInRendered >= 0,
                  source.deliveredByteOffsetInRendered <= source.renderedByteCount,
                  source.deliveredByteCount <= source.renderedByteCount,
                  source.deliveredByteCount <= limits.maximumBodyBytes,
                  source.renderedByteCount <= limits.maximumBodyBytes
            else { throw WorkLaunchManifestStoreError.invalidManifest("prompt source metadata") }
            if let fullByteCount = source.fullByteCount {
                guard fullByteCount >= 0, fullByteCount <= limits.maximumBodyBytes,
                      ContextBodyStore.isValidDigest(source.fullDigest ?? "") else {
                    throw WorkLaunchManifestStoreError.invalidReference
                }
                guard source.status == .present || source.status == .truncated else {
                    throw WorkLaunchManifestStoreError.invalidReference
                }
            } else {
                guard source.fullDigest == nil, source.fullBodyReference == nil else {
                    throw WorkLaunchManifestStoreError.invalidReference
                }
                guard source.status == .missing || source.status == .unreadable
                    || source.status == .disabled else {
                    throw WorkLaunchManifestStoreError.invalidReference
                }
            }
            guard ContextBodyStore.isValidDigest(source.deliveredDigest),
                  ContextBodyStore.isValidDigest(source.renderedDigest) else {
                throw WorkLaunchManifestStoreError.invalidReference
            }
            try validatePromptSourceReference(
                source.fullBodyReference, digest: source.fullDigest,
                byteCount: source.fullByteCount, identity: identity, limits: limits,
                required: source.status == .present || source.status == .truncated)
            try validatePromptSourceReference(
                source.deliveredBodyReference, digest: source.deliveredDigest,
                byteCount: source.deliveredByteCount, identity: identity, limits: limits,
                required: true)
            try validatePromptSourceReference(
                source.renderedBodyReference, digest: source.renderedDigest,
                byteCount: source.renderedByteCount, identity: identity, limits: limits,
                required: true)
            let addition = renderedTotal.addingReportingOverflow(source.renderedByteCount)
            guard !addition.overflow else { throw WorkLaunchManifestStoreError.invalidReference }
            renderedTotal = addition.partialValue
        }
        guard renderedTotal == assembly.flattenedByteCount else {
            throw WorkLaunchManifestStoreError.invalidReference
        }
    }

    private static func validatePromptSourceReference(
        _ reference: TimelineBodyReference?, digest: String?, byteCount: Int?,
        identity: WorkLaunchManifestIdentity, limits: WorkLaunchManifestLimits, required: Bool
    ) throws {
        guard let reference else {
            if required { throw WorkLaunchManifestStoreError.invalidReference }
            return
        }
        guard let digest, reference.digest == digest,
              reference.referenceID == digest,
              let byteCount, reference.byteCount == byteCount,
              byteCount >= 0, byteCount <= limits.maximumBodyBytes else {
            throw WorkLaunchManifestStoreError.invalidReference
        }
        try validateBodyReference(reference, identity: identity, limits: limits)
    }
}

extension WorkLaunchManifest: InHouseWorkLaunchManifest {
    /// The default Work/Session journal IDs and Host authority are part of `WorkRunBinding`'s
    /// canonical projection. No identity is inferred from a path or from a service descriptor.
    public var workRunBinding: WorkRunBinding {
        WorkRunBinding(
            workBinding: WorkBinding(
                session: identity.session, work: identity.work,
                workHost: WorkHostRef(identity.work.workHostID),
                sessionAttachment: identity.sessionAttachment),
            run: identity.run)
    }
}

public struct WorkLaunchManifestGeneration: Codable, Hashable, Sendable {
    public let generation: Int
    public let digest: String

    public init(generation: Int, digest: String) {
        self.generation = generation
        self.digest = digest
    }
}

public struct WorkLaunchManifestRecord: Codable, Hashable, Sendable {
    public let manifest: WorkLaunchManifest
    public let generation: WorkLaunchManifestGeneration
    /// Exact canonical metadata byte count, independently recomputed on every read.
    public let manifestByteCount: Int

    public init(
        manifest: WorkLaunchManifest,
        generation: WorkLaunchManifestGeneration,
        manifestByteCount: Int
    ) {
        self.manifest = manifest
        self.generation = generation
        self.manifestByteCount = manifestByteCount
    }

    public var manifestDigest: String { generation.digest }
    public var digest: String { generation.digest }
    public var byteCount: Int { manifestByteCount }
}

/// A Run-bound manifest together with the generation of the Work-level current-Run selection.
/// `record.generation` fences the manifest's identity pointer; `selectionGeneration` fences the
/// separate pointer addressed by the Run-free Work/Session/attachment tuple.
public struct WorkLaunchBindingSelection: Codable, Hashable, Sendable {
    public let record: WorkLaunchManifestRecord
    public let selectionGeneration: WorkLaunchManifestGeneration

    public init(
        record: WorkLaunchManifestRecord,
        selectionGeneration: WorkLaunchManifestGeneration
    ) {
        self.record = record
        self.selectionGeneration = selectionGeneration
    }
}


public struct WorkLaunchManifestDraftRecord: Codable, Hashable, Sendable {
    public let draft: WorkLaunchManifestDraft
    public let digest: String
    public let draftByteCount: Int

    public init(draft: WorkLaunchManifestDraft, digest: String, draftByteCount: Int) {
        self.draft = draft
        self.digest = digest
        self.draftByteCount = draftByteCount
    }

    public var byteCount: Int { draftByteCount }
}

/// The caller-owned idempotency namespace for a Create attempt. `commandID` and
/// `causalControlCursor` are the caller's exact control identity; `requestDigest` is the
/// canonical digest of the bounded requested configuration and capabilities. The resolved
/// provider/runtime draft is deliberately not part of this key, so a retry can recover the
/// first durable draft even when ambient routing defaults have changed.
public struct WorkLaunchCreateKey: Codable, Hashable, Sendable {
    public let client: ClientRef
    public let commandID: String
    public let causalControlCursor: JournalCursor
    public let requestDigest: String

    public init(
        client: ClientRef,
        requestDigest: String,
        commandID: String,
        causalControlCursor: JournalCursor
    ) {
        self.client = client
        self.commandID = commandID
        self.causalControlCursor = causalControlCursor
        self.requestDigest = requestDigest
    }

    /// Compute the caller-owned portion of the Create identity without invoking a provider or
    /// workspace resolver. Set order is normalized before hashing so the key is stable across
    /// process restarts.
    public static func requestDigest(
        configuration: WorkServiceWorkConfiguration,
        requestedCapabilities: Set<WorkServiceCapability>
    ) throws -> String {
        let material = WorkLaunchCreateRequestMaterial(
            schemaVersion: 1, configuration: configuration,
            requestedCapabilities: requestedCapabilities.map(\.rawValue).sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(material)
        return "sha256:" + AviarySHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
    }
}

private struct WorkLaunchCreateRequestMaterial: Codable {
    let schemaVersion: Int
    let configuration: WorkServiceWorkConfiguration
    let requestedCapabilities: [String]
}

/// A retained draft together with the external Create key that made its retention idempotent.
public struct WorkLaunchDraftRetentionRecord: Codable, Hashable, Sendable {
    public let key: WorkLaunchCreateKey
    public let draft: WorkLaunchManifestDraftRecord
    public let idempotencyDigest: String

    public init(
        key: WorkLaunchCreateKey,
        draft: WorkLaunchManifestDraftRecord,
        idempotencyDigest: String
    ) {
        self.key = key
        self.draft = draft
        self.idempotencyDigest = idempotencyDigest
    }

    public var digest: String { draft.digest }
    public var byteCount: Int { draft.draftByteCount }
}

/// Work-level launch material after the control reservation and before any Run exists. This is
/// what recovery looks up by Work; it deliberately carries no Run identity and cannot start an
/// execution on its own.
public struct WorkLaunchWorkTemplate: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let work: WorkRef
    public let workHost: WorkHostRef
    public let draft: WorkLaunchManifestDraft
    /// The keyed Create retention which produced this template.  A template without that
    /// durable request proof is not reconstructable and therefore cannot be published.
    public let retentionKey: WorkLaunchCreateKey

    public init(
        work: WorkRef,
        workHost: WorkHostRef,
        draft: WorkLaunchManifestDraft,
        retentionKey: WorkLaunchCreateKey
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.work = work
        self.workHost = workHost
        self.draft = draft
        self.retentionKey = retentionKey
    }

    public func canonicalBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var object = try JSONSerialization.jsonObject(
            with: encoder.encode(self)) as? [String: Any],
            var draftObject = object["draft"] as? [String: Any] else {
            throw WorkLaunchManifestStoreError.invalidManifest("template encoding")
        }
        // A template embeds the draft's capability Set. Synthesized Set encoding is not stable
        // across process launches or decode/re-encode, so normalize it at this enclosing content
        // address just as WorkLaunchManifestDraft.canonicalBytes() does for the draft itself.
        draftObject["requestedCapabilities"] = draft.requestedCapabilities.map(\.rawValue).sorted()
        object["draft"] = draftObject
        return try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public func contentDigest() throws -> String {
        "sha256:" + AviarySHA256.hash(data: try canonicalBytes())
            .map { String(format: "%02x", $0) }.joined()
    }
}

public struct WorkLaunchWorkTemplateGeneration: Codable, Hashable, Sendable {
    public let generation: Int
    public let digest: String

    public init(generation: Int, digest: String) {
        self.generation = generation
        self.digest = digest
    }
}

public struct WorkLaunchWorkTemplateRecord: Codable, Hashable, Sendable {
    public let template: WorkLaunchWorkTemplate
    public let generation: WorkLaunchWorkTemplateGeneration
    public let templateByteCount: Int

    public init(
        template: WorkLaunchWorkTemplate,
        generation: WorkLaunchWorkTemplateGeneration,
        templateByteCount: Int
    ) {
        self.template = template
        self.generation = generation
        self.templateByteCount = templateByteCount
    }

    public var digest: String { generation.digest }
    public var byteCount: Int { templateByteCount }
    public var work: WorkRef { template.work }
    public var workHost: WorkHostRef { template.workHost }
}

/// The exact client-qualified Start admission that creates one Run. Its cursor and body digest
/// are compared during binding so a retry cannot silently start a different command against the
/// same Work-level template.
public struct WorkLaunchStartIntent: Codable, Hashable, Sendable {
    public let client: ClientRef
    public let commandID: String
    public let causalWorkCursor: JournalCursor
    public let bodyDigest: String

    public init(
        client: ClientRef,
        commandID: String,
        causalWorkCursor: JournalCursor,
        bodyDigest: String
    ) {
        self.client = client
        self.commandID = commandID
        self.causalWorkCursor = causalWorkCursor
        self.bodyDigest = bodyDigest
    }
}

/// Durable admission state for the one Start which won the binding-wide compare-and-swap.
///
/// This is deliberately separate from the final Run manifest.  It is the crash fence between
/// retaining the exact Start bytes and publishing the identity-bound prompt assembly.  A
/// reservation without an assembly is recovery-required; it is never permission to invoke an
/// ambient prompt resolver a second time.
public struct WorkLaunchStartReservation: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let binding: WorkBinding
    public let run: RunRef
    public let intent: WorkLaunchStartIntent
    public let templateGeneration: WorkLaunchWorkTemplateGeneration
    public let initialInputBodyReference: TimelineBodyReference
    public let expectedPrevious: WorkLaunchManifestGeneration?
    public let promptAssembly: WorkLaunchPromptAssembly?

    public init(
        binding: WorkBinding,
        run: RunRef,
        intent: WorkLaunchStartIntent,
        templateGeneration: WorkLaunchWorkTemplateGeneration,
        initialInputBodyReference: TimelineBodyReference,
        expectedPrevious: WorkLaunchManifestGeneration? = nil,
        promptAssembly: WorkLaunchPromptAssembly? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.binding = binding
        self.run = run
        self.intent = intent
        self.templateGeneration = templateGeneration
        self.initialInputBodyReference = initialInputBodyReference
        self.expectedPrevious = expectedPrevious
        self.promptAssembly = promptAssembly
    }
}

/// Result of the durable Start winner CAS. Only ``winner`` may invoke the ambient prompt
/// assembly resolver. ``reserved`` is an exact retry/recovery observation and must reuse the
/// already-retained assembly, or fail closed when assembly is absent.
public enum WorkLaunchStartAdmission: Sendable {
    case winner(WorkLaunchStartReservation)
    case reserved(WorkLaunchStartReservation)
    case existing(WorkLaunchManifestRecord)
}

// MARK: - Runtime adoption material

public struct RuntimeAdoptionRecord: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let descriptor: RuntimeHost.AdoptionDescriptor
    public let work: WorkRef
    public let session: SessionRef
    public let run: RunRef
    public let sourceEvent: EventRef
    public let sourceCursor: JournalCursor
    public let observedAt: Date
    /// This value is always normalized to false. A decoder deliberately ignores an encoded true.
    public let isLivenessProof: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, descriptor, work, session, run, sourceEvent, sourceCursor, observedAt
        case isLivenessProof
    }

    public init(
        descriptor: RuntimeHost.AdoptionDescriptor,
        work: WorkRef,
        session: SessionRef,
        run: RunRef,
        sourceEvent: EventRef,
        sourceCursor: JournalCursor,
        observedAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.descriptor = descriptor
        self.work = work
        self.session = session
        self.run = run
        self.sourceEvent = sourceEvent
        self.sourceCursor = sourceCursor
        self.observedAt = observedAt
        self.isLivenessProof = false
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        descriptor = try values.decode(RuntimeHost.AdoptionDescriptor.self, forKey: .descriptor)
        work = try values.decode(WorkRef.self, forKey: .work)
        session = try values.decode(SessionRef.self, forKey: .session)
        run = try values.decode(RunRef.self, forKey: .run)
        sourceEvent = try values.decode(EventRef.self, forKey: .sourceEvent)
        sourceCursor = try values.decode(JournalCursor.self, forKey: .sourceCursor)
        observedAt = try values.decode(Date.self, forKey: .observedAt)
        _ = try values.decodeIfPresent(Bool.self, forKey: .isLivenessProof)
        isLivenessProof = false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(descriptor, forKey: .descriptor)
        try values.encode(work, forKey: .work)
        try values.encode(session, forKey: .session)
        try values.encode(run, forKey: .run)
        try values.encode(sourceEvent, forKey: .sourceEvent)
        try values.encode(sourceCursor, forKey: .sourceCursor)
        try values.encode(observedAt, forKey: .observedAt)
        try values.encode(false, forKey: .isLivenessProof)
    }
}

public struct RuntimeAdoptionRecordGeneration: Codable, Hashable, Sendable {
    public let generation: Int
    public let digest: String

    public init(generation: Int, digest: String) {
        self.generation = generation
        self.digest = digest
    }
}

public struct RuntimeAdoptionRecordResult: Codable, Hashable, Sendable {
    public let record: RuntimeAdoptionRecord
    public let generation: RuntimeAdoptionRecordGeneration
    public let recordByteCount: Int

    public init(
        record: RuntimeAdoptionRecord,
        generation: RuntimeAdoptionRecordGeneration,
        recordByteCount: Int
    ) {
        self.record = record
        self.generation = generation
        self.recordByteCount = recordByteCount
    }

    public var recordDigest: String { generation.digest }
    public var digest: String { generation.digest }
    public var byteCount: Int { recordByteCount }
}

public enum RuntimeAdoptionRecordStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidRecord(String)
    case wrongAuthority(expected: String, actual: String)
    case identityMismatch
    case recordTooLarge
    case malformedRecord
    case tamperedRecord
    case digestMismatch
    case symlinkOrNonRegularFile
    case accessDenied
    case notFound
    case generationMismatch
    case invalidGeneration
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRecord(let detail): return "Invalid Runtime adoption record: " + detail + "."
        case .wrongAuthority(let expected, let actual):
            return "Runtime adoption authority mismatch (expected " + expected
                + ", got " + actual + ")."
        case .identityMismatch: return "Runtime adoption identity does not match its address."
        case .recordTooLarge: return "Runtime adoption record exceeds its size bound."
        case .malformedRecord: return "Runtime adoption record is malformed."
        case .tamperedRecord: return "Runtime adoption record failed integrity verification."
        case .digestMismatch: return "Runtime adoption record digest does not match its content."
        case .symlinkOrNonRegularFile:
            return "Runtime adoption storage is not a regular private file."
        case .accessDenied: return "Runtime adoption storage is not privately owned."
        case .notFound: return "Runtime adoption record was not found."
        case .generationMismatch: return "Runtime adoption generation is stale."
        case .invalidGeneration: return "Runtime adoption generation is invalid."
        case .ioFailure(let operation): return "Runtime adoption " + operation + " failed."
        }
    }
}

// MARK: - Shared durable storage primitives

private enum WorkLaunchDurableIO {
    static func digest(_ data: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validDigest(_ digest: String) -> Bool {
        ContextBodyStore.isValidDigest(digest)
    }

    static func digestPathComponent(_ digest: String) -> String {
        guard validDigest(digest) else { return "__invalid-digest__" }
        return String(digest.dropFirst("sha256:".count))
    }

    static func preparePrivateDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw WorkLaunchManifestStoreError.ioFailure("directory creation")
        }
        var information = stat()
        guard lstat(directory.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == geteuid() else {
            throw WorkLaunchManifestStoreError.accessDenied
        }
        if information.st_mode & mode_t(0o077) != 0 {
            guard chmod(directory.path, mode_t(0o700)) == 0 else {
                throw WorkLaunchManifestStoreError.accessDenied
            }
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path != directory.path {
            try synchronizeDirectory(parent)
        }
    }

    static func openRegularNoFollow(_ url: URL) throws -> Int32? {
        let fd = url.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == EACCES || errno == ELOOP {
                throw WorkLaunchManifestStoreError.symlinkOrNonRegularFile
            }
            throw WorkLaunchManifestStoreError.ioFailure("read")
        }
        var information = stat()
        guard fstat(fd, &information) == 0 else {
            close(fd)
            throw WorkLaunchManifestStoreError.ioFailure("stat")
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw WorkLaunchManifestStoreError.symlinkOrNonRegularFile
        }
        guard information.st_uid == geteuid(), information.st_mode & mode_t(0o077) == 0 else {
            close(fd)
            throw WorkLaunchManifestStoreError.accessDenied
        }
        return fd
    }

    static func readBounded(_ url: URL, maximumBytes: Int) throws -> Data? {
        guard let fd = try openRegularNoFollow(url) else { return nil }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0 else {
            throw WorkLaunchManifestStoreError.ioFailure("stat")
        }
        guard information.st_size >= 0 else {
            throw WorkLaunchManifestStoreError.malformedRecord
        }
        guard information.st_size <= off_t(maximumBytes) else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        var result = Data()
        result.reserveCapacity(min(maximumBytes, Int(information.st_size)))
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard result.count <= maximumBytes - count else {
                    throw WorkLaunchManifestStoreError.recordTooLarge
                }
                result.append(buffer, count: count)
                continue
            }
            if count == 0 { return result }
            if errno == EINTR { continue }
            throw WorkLaunchManifestStoreError.ioFailure("read")
        }
    }

    static func writeNew(_ data: Data, to destination: URL, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else { throw WorkLaunchManifestStoreError.recordTooLarge }
        let temporary = destination.deletingLastPathComponent().appending(
            path: "." + destination.lastPathComponent + "-"
                + UUID().uuidString.lowercased() + ".tmp",
            directoryHint: .notDirectory)
        let fd = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw WorkLaunchManifestStoreError.ioFailure("temporary-file open") }
        var published = false
        defer {
            close(fd)
            if !published { _ = unlink(temporary.path) }
        }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0 else {
            throw WorkLaunchManifestStoreError.ioFailure("file synchronization")
        }
        guard temporary.path.withCString({ source in
            destination.path.withCString { target in rename(source, target) }
        }) == 0 else {
            throw WorkLaunchManifestStoreError.ioFailure("publication")
        }
        published = true
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    static func replace(_ data: Data, at destination: URL, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else { throw WorkLaunchManifestStoreError.recordTooLarge }
        let temporary = destination.deletingLastPathComponent().appending(
            path: "." + destination.lastPathComponent + "-"
                + UUID().uuidString.lowercased() + ".tmp",
            directoryHint: .notDirectory)
        let fd = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw WorkLaunchManifestStoreError.ioFailure("temporary-file open") }
        var published = false
        defer {
            close(fd)
            if !published { _ = unlink(temporary.path) }
        }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0 else {
            throw WorkLaunchManifestStoreError.ioFailure("file synchronization")
        }
        guard temporary.path.withCString({ source in
            destination.path.withCString { target in rename(source, target) }
        }) == 0 else {
            throw WorkLaunchManifestStoreError.ioFailure("publication")
        }
        published = true
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                throw WorkLaunchManifestStoreError.ioFailure("write")
            }
        }
    }

    static func synchronizeDirectory(_ directory: URL) throws {
        let fd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw WorkLaunchManifestStoreError.ioFailure("directory open") }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw WorkLaunchManifestStoreError.ioFailure("directory synchronization")
        }
    }

    static func verifyPrivateDirectory(_ directory: URL) throws {
        var information = stat()
        guard lstat(directory.path, &information) == 0 else {
            if errno == ENOENT { throw WorkLaunchManifestStoreError.notFound }
            throw WorkLaunchManifestStoreError.ioFailure("directory stat")
        }
        guard (information.st_mode & S_IFMT) == S_IFDIR else {
            throw WorkLaunchManifestStoreError.symlinkOrNonRegularFile
        }
        guard information.st_uid == geteuid(), information.st_mode & mode_t(0o077) == 0 else {
            throw WorkLaunchManifestStoreError.accessDenied
        }
    }

    static func withLock<T>(_ url: URL, body: () throws -> T) throws -> T {
        let fd = url.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: mode_t(0o600))
        }
        guard fd >= 0 else {
            if errno == ELOOP { throw WorkLaunchManifestStoreError.symlinkOrNonRegularFile }
            throw WorkLaunchManifestStoreError.ioFailure("lock")
        }
        var information = stat()
        guard fstat(fd, &information) == 0 else {
            close(fd)
            throw WorkLaunchManifestStoreError.ioFailure("lock stat")
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw WorkLaunchManifestStoreError.symlinkOrNonRegularFile
        }
        guard information.st_uid == geteuid(), information.st_mode & mode_t(0o077) == 0 else {
            close(fd)
            throw WorkLaunchManifestStoreError.accessDenied
        }
        let lock = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? lock.close() }
        return try body()
    }

    static func identityDigest(_ material: String) -> String {
        digest(Data(material.utf8))
    }
}

// MARK: - Work launch manifest store

/// Durable, content-addressed launch records and generation-fenced current pointers.
public struct WorkLaunchManifestStore: Sendable, Hashable {
    public let home: AgentHome
    public let limits: WorkLaunchManifestLimits
    public let root: URL
    public let payloadDirectory: URL
    public let pointerDirectory: URL
    public let draftPayloadDirectory: URL
    public let requestPointerDirectory: URL
    public let templatePayloadDirectory: URL
    public let templatePointerDirectory: URL
    public let bindingPointerDirectory: URL
    /// One bounded pending pointer per Work binding. It is written before Run identity and
    /// binding publication so a crash can be repaired without scanning historical payloads.
    public let pendingPointerDirectory: URL
    /// Intent-indexed Run records are retained for historical duplicate receipts. They are
    /// separate from the single pending pointer, so replaying Run 1 after Run 2 never rewinds
    /// the Work-level current selection.
    public let startPointerDirectory: URL
    /// One binding-wide Start admission fence. Unlike the final pending pointer, this record is
    /// written before prompt assembly and may carry the retained assembly through a crash window.
    public let startReservationDirectory: URL

    public init(home: AgentHome, limits: WorkLaunchManifestLimits = .default) {
        self.home = home
        self.limits = limits
        self.root = home.root.appending(path: "work-launch-manifests", directoryHint: .isDirectory)
        self.payloadDirectory = root.appending(path: "sha256", directoryHint: .isDirectory)
        self.pointerDirectory = root.appending(path: "current", directoryHint: .isDirectory)
        self.draftPayloadDirectory = root.appending(path: "drafts", directoryHint: .isDirectory)
            .appending(path: "sha256", directoryHint: .isDirectory)
        self.requestPointerDirectory = root.appending(path: "requests", directoryHint: .isDirectory)
        let templates = root.appending(path: "templates", directoryHint: .isDirectory)
        self.templatePayloadDirectory = templates.appending(path: "sha256", directoryHint: .isDirectory)
        self.templatePointerDirectory = templates.appending(path: "current", directoryHint: .isDirectory)
        self.bindingPointerDirectory = root.appending(
            path: "current-by-binding", directoryHint: .isDirectory)
        self.pendingPointerDirectory = root.appending(
            path: "pending-by-binding", directoryHint: .isDirectory)
        self.startPointerDirectory = root.appending(
            path: "starts-by-intent", directoryHint: .isDirectory)
        self.startReservationDirectory = root.appending(
            path: "start-reservations-by-binding", directoryHint: .isDirectory)
    }

    public func manifestURL(forDigest digest: String) -> URL {
        payloadDirectory.appending(path: WorkLaunchDurableIO.digestPathComponent(digest) + ".json",
                                    directoryHint: .notDirectory)
    }

    public func pointerURL(for identity: WorkLaunchManifestIdentity) -> URL {
        pointerDirectory.appending(
            path: WorkLaunchDurableIO.identityDigest(identity.addressMaterial) + ".json",
            directoryHint: .notDirectory)
    }

    public func draftURL(forDigest digest: String) -> URL {
        draftPayloadDirectory.appending(
            path: WorkLaunchDurableIO.digestPathComponent(digest) + ".json",
            directoryHint: .notDirectory)
    }

    public func requestPointerURL(for key: WorkLaunchCreateKey) -> URL {
        requestPointerDirectory.appending(
            path: WorkLaunchDurableIO.identityDigest(Self.addressMaterial(for: key)) + ".json",
            directoryHint: .notDirectory)
    }

    public func templateURL(forDigest digest: String) -> URL {
        templatePayloadDirectory.appending(
            path: WorkLaunchDurableIO.digestPathComponent(digest) + ".json",
            directoryHint: .notDirectory)
    }

    public func templatePointerURL(for work: WorkRef) -> URL {
        templatePointerDirectory.appending(
            path: WorkLaunchDurableIO.identityDigest(Self.addressMaterial(for: work)) + ".json",
            directoryHint: .notDirectory)
    }

    /// The current Run pointer is addressed by Work, not by its selected Session. Its payload
    /// carries the exact binding, so replacement Start admissions from another attached Session
    /// still contend on one durable Work slot/CAS.
    public func bindingPointerURL(for binding: WorkBinding) -> URL {
        bindingPointerDirectory.appending(
            path: WorkLaunchDurableIO.identityDigest(Self.addressMaterial(for: binding.work)) + ".json",
            directoryHint: .notDirectory)
    }

    private func pendingPointerURL(for binding: WorkBinding) -> URL {
        pendingPointerDirectory.appending(
            path: WorkLaunchDurableIO.identityDigest(Self.addressMaterial(for: binding.work)) + ".json",
            directoryHint: .notDirectory)
    }

    public func startPointerURL(
        for binding: WorkBinding, intent: WorkLaunchStartIntent
    ) -> URL {
        let material = [
            "start", binding.work.workHostID, binding.work.workID,
            binding.session.sessionID, binding.sessionAttachment.attachmentID,
            intent.client.clientID, intent.commandID,
            intent.causalWorkCursor.journal.stableKey,
            intent.causalWorkCursor.eventID ?? "", String(intent.causalWorkCursor.sequence),
            intent.bodyDigest,
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "\u{0}")
        return startPointerDirectory.appending(
            path: WorkLaunchDurableIO.identityDigest(material) + ".json",
            directoryHint: .notDirectory)
    }

    private func startReservationURL(for binding: WorkBinding) -> URL {
        startReservationDirectory.appending(
            path: WorkLaunchDurableIO.identityDigest(Self.addressMaterial(for: binding.work)) + ".json",
            directoryHint: .notDirectory)
    }

    /// Retain a draft under the caller's client-qualified Create/request key. A retry with the
    /// same key returns the first durable bytes, including its original provenance clock; a
    /// semantically different draft is rejected rather than replacing a reserved request.
    public func retain(
        _ draft: WorkLaunchManifestDraft, for key: WorkLaunchCreateKey
    ) throws -> WorkLaunchDraftRetentionRecord {
        try withPreparedStorage {
            try validateCreateKey(key)
            try validateCreateRequestDigest(key, draft: draft)
            let idempotencyDigest = try draft.idempotencyDigest()
            try draft.validate(limits: limits)
            let pointerURL = requestPointerURL(for: key)
            if let data = try WorkLaunchDurableIO.readBounded(
                pointerURL, maximumBytes: limits.maximumMetadataBytes) {
                let pointer = try decodeRequestPointer(data)
                guard pointer.key == key else { throw WorkLaunchManifestStoreError.identityMismatch }
                guard pointer.idempotencyDigest == idempotencyDigest else {
                    throw WorkLaunchManifestStoreError.requestConflict
                }
                let retained = try loadDraftLocked(digest: pointer.draftDigest)
                guard retained.draftByteCount == pointer.draftByteCount else {
                    throw WorkLaunchManifestStoreError.tamperedRecord
                }
                try validateCreateRequestDigest(pointer.key, draft: retained.draft)
                return WorkLaunchDraftRetentionRecord(
                    key: key, draft: retained, idempotencyDigest: idempotencyDigest)
            }
            // A changed request has a different key (configuration/capability digest, causal
            // cursor, or both), and therefore a different pointer filename. Reject it before
            // creating a second pointer when it reuses the same caller command.
            try rejectConflictingCreateIdentityLocked(key)
            let retained = try retainDraftLocked(draft)
            try validateCreateRequestDigest(key, draft: retained.draft)
            let pointer = RequestPointer(
                schemaVersion: 1, key: key, draftDigest: retained.digest,
                draftByteCount: retained.draftByteCount, idempotencyDigest: idempotencyDigest)
            try writeRequestPointer(pointer, at: pointerURL)
            return WorkLaunchDraftRetentionRecord(
                key: key, draft: retained, idempotencyDigest: idempotencyDigest)
        }
    }

    /// Retain the exact Start-time system prompt and its producer-side source bodies. The
    /// returned value is metadata only; all prompt bytes are content-addressed in the context
    /// body store and are synchronously durable before this method returns.
    public func retainPromptAssembly(
        _ assembly: SystemPromptAssembly,
        authority: JournalRef,
        provenance: WorkLaunchManifestProvenance
    ) throws -> WorkLaunchPromptAssembly {
        try withPreparedStorage {
            let expectedHost = try home.requirePersistedWorkHost()
            guard authority == .workHost(expectedHost) else {
                throw WorkLaunchManifestStoreError.wrongAuthority(
                    expected: expectedHost.workHostID, actual: authority.authority.authorityID)
            }
            guard assembly.sources.count <= limits.maximumArrayEntries,
                  assembly.flattenedByteCount <= limits.maximumBodyBytes else {
                throw WorkLaunchManifestStoreError.recordTooLarge
            }

            let bodies = ContextBodyStore(home: home)
            let flattened = try bodies.retain(
                Data(assembly.flattenedText.utf8), authority: authority,
                mediaType: "text/plain; charset=utf-8")
            guard flattened.digest == assembly.flattenedDigest,
                  flattened.byteCount == assembly.flattenedByteCount else {
                throw WorkLaunchManifestStoreError.digestMismatch
            }

            var sources: [ContextManifestSource] = []
            sources.reserveCapacity(assembly.sources.count)
            for (index, source) in assembly.sources.enumerated() {
                let sourcePrefix = "prompt-source-v1-\(index)"
                let fullReference: TimelineBodyReference?
                if let fullBody = source.fullBody {
                    let data = Data(fullBody.utf8)
                    guard data.count <= limits.maximumBodyBytes else {
                        throw WorkLaunchManifestStoreError.recordTooLarge
                    }
                    fullReference = try bodies.retain(
                        data, authority: authority,
                        mediaType: "application/vnd.aviary.prompt-source+utf8")
                } else {
                    fullReference = nil
                }
                let deliveredReference = try bodies.retain(
                    Data(source.deliveredBody.utf8), authority: authority,
                    mediaType: "application/vnd.aviary.prompt-source+utf8")
                let renderedReference = try bodies.retain(
                    Data(source.renderedBody.utf8), authority: authority,
                    mediaType: "application/vnd.aviary.prompt-source+utf8")
                // IDs remain stable for the source, while the inclusion address is a bounded
                // digest rather than a concatenation that could expose a path or exceed the
                // metadata bound. Labels are deliberately producer-neutral; arbitrary labels can
                // contain paths or prompt text and therefore never cross into the manifest.
                let inclusionDigest = WorkLaunchDurableIO.digest(Data(source.sourceID.utf8))
                let inclusionID = "\(sourcePrefix)-"
                    + String(inclusionDigest.dropFirst("sha256:".count))
                sources.append(ContextManifestSource(
                    sourceID: source.sourceID,
                    inclusionID: inclusionID,
                    kind: source.kind,
                    status: source.status,
                    label: "source-\(index)-\(source.kind.rawValue)",
                    fullByteCount: source.fullByteCount,
                    fullDigest: source.fullDigest,
                    deliveredByteCount: source.deliveredByteCount,
                    deliveredDigest: source.deliveredDigest,
                    deliveredByteOffsetInRendered: source.deliveredByteOffsetInRendered,
                    renderedByteCount: source.renderedByteCount,
                    renderedDigest: source.renderedDigest,
                    fullBodyReference: fullReference,
                    deliveredBodyReference: deliveredReference,
                    renderedBodyReference: renderedReference,
                    provenance: provenance.sourceEvent))
            }
            let retained = WorkLaunchPromptAssembly(
                flattenedBodyReference: flattened,
                flattenedByteCount: assembly.flattenedByteCount,
                flattenedDigest: assembly.flattenedDigest,
                sources: sources,
                provenance: provenance)
            // Validate the metadata and all retained references before exposing it to a caller.
            try validateRetainedPromptAssembly(retained, authority: authority)
            return retained
        }
    }

    /// Resolve the recorded Start-time prompt without consulting current files, skills, memory,
    /// settings, or model defaults. This is the only prompt source permitted on recovery paths.
    public func resolvePromptAssembly(
        for manifest: WorkLaunchManifest
    ) throws -> SystemPromptAssembly {
        try withPreparedStorage {
            let expectedAuthority = try home.requirePersistedWorkHostID()
            try manifest.validate(limits: limits, expectedAuthority: expectedAuthority)
            guard let assembly = manifest.promptAssembly else {
                throw WorkLaunchManifestStoreError.bodyUnavailable
            }
            try validateRetainedPromptAssembly(
                assembly, authority: .workHost(WorkHostRef(expectedAuthority)), identity: manifest.identity)
            return try assembly.materialize(using: ContextBodyStore(home: home))
        }
    }

    public func loadRetainedDraft(
        for key: WorkLaunchCreateKey
    ) throws -> WorkLaunchDraftRetentionRecord? {
        try withPreparedStorage {
            try validateCreateKey(key)
            guard let data = try WorkLaunchDurableIO.readBounded(
                requestPointerURL(for: key), maximumBytes: limits.maximumMetadataBytes) else {
                return nil
            }
            let pointer = try decodeRequestPointer(data)
            guard pointer.key == key else { throw WorkLaunchManifestStoreError.identityMismatch }
            let retained = try loadDraftLocked(digest: pointer.draftDigest)
            guard retained.draftByteCount == pointer.draftByteCount,
                  try retained.draft.idempotencyDigest() == pointer.idempotencyDigest else {
                throw WorkLaunchManifestStoreError.tamperedRecord
            }
            try validateCreateRequestDigest(pointer.key, draft: retained.draft)
            return WorkLaunchDraftRetentionRecord(
                key: key, draft: retained, idempotencyDigest: pointer.idempotencyDigest)
        }
    }

    /// Resolve a retained Create reservation using every durable identity component. A bare
    /// client/digest join is ambiguous once a client retries command IDs or a home contains
    /// multiple reservations, so callers must provide the exact command and persisted control
    /// cursor. Zero or multiple matches are not recoverable guesses.
    public func loadRetainedDraft(
        client: ClientRef,
        commandID: String,
        causalControlCursor: JournalCursor,
        draftDigest: String
    ) throws -> WorkLaunchDraftRetentionRecord? {
        try withPreparedStorage {
            let keyShape = WorkLaunchCreateKey(
                client: client, requestDigest: "sha256:" + String(repeating: "0", count: 64),
                commandID: commandID, causalControlCursor: causalControlCursor)
            try validateCreateKeyShape(keyShape)
            guard WorkLaunchDurableIO.validDigest(draftDigest) else {
                throw WorkLaunchManifestStoreError.invalidManifest("retained draft lookup")
            }
            guard FileManager.default.fileExists(atPath: requestPointerDirectory.path) else {
                return nil
            }
            let entries = try FileManager.default.contentsOfDirectory(
                at: requestPointerDirectory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            guard entries.count <= limits.maximumArrayEntries else {
                throw WorkLaunchManifestStoreError.recordTooLarge
            }
            var matches: [WorkLaunchDraftRetentionRecord] = []
            for entry in entries {
                let values = try entry.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else {
                    throw WorkLaunchManifestStoreError.symlinkOrNonRegularFile
                }
                guard let data = try WorkLaunchDurableIO.readBounded(
                    entry, maximumBytes: limits.maximumMetadataBytes) else {
                    throw WorkLaunchManifestStoreError.notFound
                }
                let pointer = try decodeRequestPointer(data)
                guard pointer.key.client == client,
                      pointer.key.commandID == commandID,
                      pointer.key.causalControlCursor == causalControlCursor,
                      pointer.draftDigest == draftDigest else { continue }
                let retained = try loadDraftLocked(digest: pointer.draftDigest)
                guard retained.draftByteCount == pointer.draftByteCount,
                      try retained.draft.idempotencyDigest() == pointer.idempotencyDigest else {
                    throw WorkLaunchManifestStoreError.tamperedRecord
                }
                try validateCreateRequestDigest(pointer.key, draft: retained.draft)
                matches.append(WorkLaunchDraftRetentionRecord(
                    key: pointer.key, draft: retained,
                    idempotencyDigest: pointer.idempotencyDigest))
            }
            guard matches.count <= 1 else {
                throw WorkLaunchManifestStoreError.requestConflict
            }
            return matches.first
        }
    }

    internal func load(draftDigest digest: String) throws -> WorkLaunchManifestDraftRecord {
        try withPreparedStorage {
            try loadDraftLocked(digest: digest)
        }
    }

    /// Publish the Work-level, Run-free template after the host reservation has minted its
    /// exact Work/Session/attachment tuple. This is the durable Create result used by recovery.
    public func publishTemplate(
        _ retained: WorkLaunchDraftRetentionRecord, binding: WorkBinding
    ) throws -> WorkLaunchWorkTemplateRecord {
        try withPreparedStorage {
            try validateBinding(binding)
            try validateCreateKey(retained.key)
            let retainedDigest = try retained.draft.draft.contentDigest()
            guard retained.draft.digest == retainedDigest else {
                throw WorkLaunchManifestStoreError.digestMismatch
            }
            guard let pointerData = try WorkLaunchDurableIO.readBounded(
                requestPointerURL(for: retained.key), maximumBytes: limits.maximumMetadataBytes) else {
                throw WorkLaunchManifestStoreError.notFound
            }
            let pointer = try decodeRequestPointer(pointerData)
            guard pointer.key == retained.key,
                  pointer.draftDigest == retained.digest,
                  pointer.draftByteCount == retained.byteCount,
                  pointer.idempotencyDigest == retained.idempotencyDigest else {
                throw WorkLaunchManifestStoreError.tamperedRecord
            }
            let durableDraft = try loadDraftLocked(digest: pointer.draftDigest)
            guard durableDraft == retained.draft else {
                throw WorkLaunchManifestStoreError.tamperedRecord
            }
            try validateCreateRequestDigest(pointer.key, draft: durableDraft.draft)
            let template = WorkLaunchWorkTemplate(
                work: binding.work, workHost: binding.workHost,
                draft: retained.draft.draft, retentionKey: retained.key)
            return try saveTemplateLocked(template)
        }
    }

    /// Reopen the Run-free launch template selected by a Work reservation. The session and
    /// attachment in the payload must match the reservation; callers cannot substitute a new
    /// Session by looking up only a bare Work id.
    public func readTemplate(for work: WorkRef) throws -> WorkLaunchWorkTemplateRecord? {
        try withPreparedStorage {
            let expectedAuthority = try home.requirePersistedWorkHostID()
            guard work.workHostID == expectedAuthority else {
                throw WorkLaunchManifestStoreError.wrongAuthority(
                    expected: expectedAuthority, actual: work.workHostID)
            }
            guard let pointer = try readTemplatePointer(for: work) else { return nil }
            guard let payload = try WorkLaunchDurableIO.readBounded(
                templateURL(forDigest: pointer.digest), maximumBytes: limits.maximumRecordBytes) else {
                throw WorkLaunchManifestStoreError.notFound
            }
            return try decodeTemplatePayload(payload, work: work, pointer: pointer)
        }
    }

    internal func template(for work: WorkRef) throws -> WorkLaunchWorkTemplateRecord? {
        try readTemplate(for: work)
    }

    internal func replaceTemplate(
        _ template: WorkLaunchWorkTemplate, expected: WorkLaunchWorkTemplateGeneration
    ) throws -> WorkLaunchWorkTemplateRecord {
        try withPreparedStorage {
            guard let current = try readTemplatePointer(for: template.work),
                  current == expected else {
                throw WorkLaunchManifestStoreError.generationMismatch
            }
            let next = try nextGeneration(after: expected.generation)
            return try publishTemplateLocked(template, generation: next)
        }
    }

    internal func bind(
        _ draft: WorkLaunchManifestDraftRecord, binding: WorkRunBinding,
        startIntent: WorkLaunchStartIntent
    ) throws -> WorkLaunchManifestRecord {
        try save(draft.draft, binding: binding, startIntent: startIntent)
    }

    /// Serialize Start against the Work-level template and publish exactly one Run-bound
    /// manifest. A retry of the same Run and Start returns the existing generation; a conflicting
    /// Start for that Run is rejected.
    internal func bind(
        _ template: WorkLaunchWorkTemplateRecord, binding: WorkBinding, run: RunRef,
        startIntent: WorkLaunchStartIntent,
        expectedPrevious: WorkLaunchManifestGeneration? = nil,
        initialInputBodyReference: TimelineBodyReference? = nil,
        promptAssembly: WorkLaunchPromptAssembly? = nil,
        resumePolicy: WorkLaunchResumePolicy? = nil
    ) throws -> WorkLaunchManifestRecord {
        try withPreparedStorage {
            let expectedAuthority = try home.requirePersistedWorkHostID()
            guard template.workHost.workHostID == expectedAuthority else {
                throw WorkLaunchManifestStoreError.wrongAuthority(
                    expected: expectedAuthority,
                    actual: template.workHost.workHostID)
            }
            guard let current = try readTemplatePointer(for: template.work),
                  current == template.generation else {
                throw WorkLaunchManifestStoreError.generationMismatch
            }
            let canonicalTemplate = try template.template.canonicalBytes()
            guard canonicalTemplate.count == template.templateByteCount,
                  WorkLaunchDurableIO.digest(canonicalTemplate) == template.digest else {
                throw WorkLaunchManifestStoreError.tamperedRecord
            }
            try validateTemplate(template.template)
            guard let promptAssembly else {
                throw WorkLaunchManifestStoreError.invalidReference
            }
            guard binding.work == template.work,
                  binding.workHost == template.workHost else {
                throw WorkLaunchManifestStoreError.identityMismatch
            }
            let runBinding = WorkRunBinding(workBinding: binding, run: run)
            if let existing = try readStartLocked(for: binding, intent: startIntent) {
                guard existing.manifest.identity.run == run,
                      existing.manifest.promptAssembly == promptAssembly,
                      existing.manifest.initialInputBodyReference == initialInputBodyReference else {
                    throw WorkLaunchManifestStoreError.requestConflict
                }
                return existing
            }
            let reservation = try readStartReservationLocked(for: binding)
            guard let reservation,
                  reservation.run == run,
                  reservation.intent == startIntent,
                  reservation.templateGeneration == template.generation,
                  reservation.initialInputBodyReference == initialInputBodyReference,
                  reservation.promptAssembly == promptAssembly else {
                throw WorkLaunchManifestStoreError.requestConflict
            }
            var manifest = try template.template.draft.bind(
                to: runBinding, startIntent: startIntent,
                initialInputBodyReference: initialInputBodyReference,
                promptAssembly: promptAssembly)
            if let resumePolicy {
                manifest = manifest.withResumePolicy(resumePolicy)
            }
            try manifest.validate(limits: limits, expectedAuthority: expectedAuthority)
            if manifest.initialInputBodyReference != nil {
                _ = try resolveInitialInputBody(for: manifest)
            }
            if manifest.systemPromptBodyReference != nil {
                _ = try resolveSystemPromptBody(for: manifest)
            }
            return try publishRunManifestLocked(manifest, expectedPrevious: expectedPrevious)
        }
    }

    internal func start(
        _ template: WorkLaunchWorkTemplateRecord, binding: WorkBinding, run: RunRef,
        startIntent: WorkLaunchStartIntent,
        expectedPrevious: WorkLaunchManifestGeneration? = nil,
        initialInputBodyReference: TimelineBodyReference? = nil,
        promptAssembly: WorkLaunchPromptAssembly? = nil,
        resumePolicy: WorkLaunchResumePolicy? = nil
    ) throws -> WorkLaunchManifestRecord {
        try bind(
            template, binding: binding, run: run, startIntent: startIntent, expectedPrevious: expectedPrevious,
            initialInputBodyReference: initialInputBodyReference,
            promptAssembly: promptAssembly,
            resumePolicy: resumePolicy)
    }

    internal func put(_ manifest: WorkLaunchManifest) throws -> WorkLaunchManifestRecord {
        try save(manifest)
    }

    /// Retain a prompt body in the existing content-addressed context store and publish the
    /// resulting reference in one manifest operation. The body is never serialized into the
    /// launch metadata.
    internal func save(
        _ manifest: WorkLaunchManifest, initialInputBody: Data, authority: JournalRef
    ) throws -> WorkLaunchManifestRecord {
        let reference: TimelineBodyReference
        do {
            reference = try ContextBodyStore(home: home).retain(initialInputBody, authority: authority)
        } catch {
            throw WorkLaunchManifestStoreError.bodyUnavailable
        }
        return try save(manifest.withInitialInputBodyReference(reference))
    }

    /// Publish a final, identity-bound manifest after a host service reservation. The draft may
    /// have been retained before reservation, but the persisted executable record always carries
    /// the exact host-minted Work/Session/attachment/Run tuple.
    internal func save(
        _ draft: WorkLaunchManifestDraft, binding: WorkRunBinding,
        startIntent: WorkLaunchStartIntent,
        promptAssembly: WorkLaunchPromptAssembly? = nil
    ) throws -> WorkLaunchManifestRecord {
        try save(draft.bind(
            to: binding, startIntent: startIntent, promptAssembly: promptAssembly))
    }

    /// Create a record, or replace the current record as one serialized generation. Callers that
    /// require a strict compare-and-swap should use `replace(_:expected:)` instead.
    internal func save(_ manifest: WorkLaunchManifest) throws -> WorkLaunchManifestRecord {
        try withPreparedStorage {
            let expectedAuthority = try home.requirePersistedWorkHostID()
            try manifest.validate(limits: limits, expectedAuthority: expectedAuthority)
            if manifest.initialInputBodyReference != nil {
                _ = try resolveInitialInputBody(for: manifest)
            }
            if manifest.systemPromptBodyReference != nil {
                _ = try resolveSystemPromptBody(for: manifest)
            }
            let existing = try readPointer(manifest.identity)
            let candidateDigest = try manifest.contentDigest()
            if let existing, existing.digest == candidateDigest {
                try ensureBindingPointer(for: manifest, digest: candidateDigest)
                guard let payload = try WorkLaunchDurableIO.readBounded(
                    manifestURL(forDigest: candidateDigest),
                    maximumBytes: limits.maximumRecordBytes) else {
                    throw WorkLaunchManifestStoreError.notFound
                }
                return try decodePayload(payload, identity: manifest.identity, pointer: existing)
            }
            let prior = existing?.generation ?? 0
            let generation = try nextGeneration(after: prior)
            return try publish(manifest, generation: generation)
        }
    }

    internal func replace(
        _ manifest: WorkLaunchManifest, expected: WorkLaunchManifestGeneration
    ) throws -> WorkLaunchManifestRecord {
        try withPreparedStorage {
            let expectedAuthority = try home.requirePersistedWorkHostID()
            try manifest.validate(limits: limits, expectedAuthority: expectedAuthority)
            guard let current = try readPointer(manifest.identity), current == expected else {
                throw WorkLaunchManifestStoreError.generationMismatch
            }
            let candidateDigest = try manifest.contentDigest()
            if current.digest == candidateDigest {
                try ensureBindingPointer(for: manifest, digest: candidateDigest)
                guard let payload = try WorkLaunchDurableIO.readBounded(
                    manifestURL(forDigest: candidateDigest),
                    maximumBytes: limits.maximumRecordBytes) else {
                    throw WorkLaunchManifestStoreError.notFound
                }
                return try decodePayload(payload, identity: manifest.identity, pointer: current)
            }
            if let currentBinding = try readBindingPointer(for: manifest.workRunBinding.workBinding) {
                guard currentBinding.run == manifest.identity.run else {
                    throw WorkLaunchManifestStoreError.generationMismatch
                }
            }
            let next = try nextGeneration(after: expected.generation)
            return try publish(manifest, generation: next)
        }
    }

    public func read(
        _ identity: WorkLaunchManifestIdentity
    ) throws -> WorkLaunchManifestRecord? {
        try withPreparedStorage {
            let expectedAuthority = try home.requirePersistedWorkHostID()
            guard identity.work.workHostID == expectedAuthority else {
                throw WorkLaunchManifestStoreError.wrongAuthority(
                    expected: expectedAuthority, actual: identity.work.workHostID)
            }
            guard let pointer = try readPointer(identity) else { return nil }
            guard let payload = try WorkLaunchDurableIO.readBounded(
                manifestURL(forDigest: pointer.digest), maximumBytes: limits.maximumRecordBytes)
            else { throw WorkLaunchManifestStoreError.notFound }
            return try decodePayload(payload, identity: identity, pointer: pointer)
        }
    }

    /// Read the current Run selected for a Run-free reservation tuple. The returned manifest
    /// still carries the exact Run, and both the binding pointer and Run pointer are verified.
    internal func readCurrent(for binding: WorkBinding) throws -> WorkLaunchManifestRecord? {
        try readCurrentSelection(for: binding)?.record
    }

    /// Read the current Run and the exact Work-level selection generation used by the binding
    /// pointer's compare-and-swap. The manifest record generation belongs to the Run identity
    /// pointer and is not a substitute for this selection generation.
    public func readCurrentSelection(for binding: WorkBinding) throws -> WorkLaunchBindingSelection? {
        try withPreparedStorage {
            try validateBinding(binding)
            guard let pointer = try readBindingPointer(for: binding) else { return nil }
            let identity = WorkLaunchManifestIdentity(
                work: pointer.binding.work, session: pointer.binding.session,
                sessionAttachment: pointer.binding.sessionAttachment, run: pointer.run)
            let runPointer = try readPointer(identity)
            let record: WorkLaunchManifestRecord
            if let runPointer {
                guard runPointer.digest == pointer.digest else {
                    throw WorkLaunchManifestStoreError.identityMismatch
                }
                guard let payload = try WorkLaunchDurableIO.readBounded(
                    manifestURL(forDigest: pointer.digest), maximumBytes: limits.maximumRecordBytes) else {
                    throw WorkLaunchManifestStoreError.notFound
                }
                record = try decodePayload(payload, identity: identity, pointer: runPointer)
            } else {
                // Publish writes the content-addressed payload before the identity pointer. A
                // crash in that narrow window leaves a complete exact manifest selected by the
                // binding pointer; repair the identity pointer before exposing the record.
                guard let payload = try WorkLaunchDurableIO.readBounded(
                    manifestURL(forDigest: pointer.digest), maximumBytes: limits.maximumRecordBytes) else {
                    throw WorkLaunchManifestStoreError.notFound
                }
                let repairedPointer = WorkLaunchManifestGeneration(
                    generation: pointer.generation, digest: pointer.digest)
                record = try decodePayload(payload, identity: identity, pointer: repairedPointer)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(Pointer(
                    schemaVersion: 1, identity: identity,
                    generation: pointer.generation, digest: pointer.digest))
                try WorkLaunchDurableIO.replace(
                    data, at: pointerURL(for: identity), maximumBytes: limits.maximumMetadataBytes)
            }
            // A crash after both current pointers were durable can leave the one-shot pending
            // marker behind. It is no longer an admission gate once it exactly names the current
            // selection; clear it before another replacement Start can mistake it for a conflict.
            if let pending = try readPendingPointer(for: binding),
               pending.identity == identity, pending.digest == pointer.digest {
                // The pending mutex may be the only durable copy of the historical intent index
                // after a crash between pending and StartPointer. Recreate that index before
                // clearing the mutex; otherwise a later Run would erase the old duplicate's
                // lookup path.
                try ensureStartPointer(
                    for: pointer.binding, intent: record.manifest.startIntent,
                    identity: identity, digest: pointer.digest)
                try? removePendingPointer(for: binding)
            }
            return WorkLaunchBindingSelection(
                record: record,
                selectionGeneration: WorkLaunchManifestGeneration(
                    generation: pointer.generation, digest: pointer.digest))
        }
    }

    /// Find one exact Run-bound Start payload which was durably written before its Work-level
    /// selection pointer. This bounded recovery read handles the crash window between the
    /// identity pointer and binding pointer writes without guessing a Run identity. Callers must
    /// repair the selection with an expected predecessor before treating the result as current.
    public func readPendingStart(
        for binding: WorkBinding,
        intent: WorkLaunchStartIntent
    ) throws -> WorkLaunchManifestRecord? {
        try withPreparedStorage { () throws -> WorkLaunchManifestRecord? in
            try validateBinding(binding)
            guard let data = try WorkLaunchDurableIO.readBounded(
                pendingPointerURL(for: binding), maximumBytes: limits.maximumMetadataBytes) else {
                return nil
            }
            let pending: PendingPointer
            do { pending = try JSONDecoder().decode(PendingPointer.self, from: data) }
            catch { throw WorkLaunchManifestStoreError.malformedRecord }
            guard pending.schemaVersion == 1,
                  pending.binding.work == binding.work,
                  pending.binding.workHost == binding.workHost,
                  pending.identity == WorkLaunchManifestIdentity(
                    work: pending.binding.work, session: pending.binding.session,
                    sessionAttachment: pending.binding.sessionAttachment, run: pending.identity.run),
                  WorkLaunchDurableIO.validDigest(pending.digest) else {
                throw WorkLaunchManifestStoreError.identityMismatch
            }
            guard pending.binding == binding else {
                throw WorkLaunchManifestStoreError.requestConflict
            }
            guard let payload = try WorkLaunchDurableIO.readBounded(
                manifestURL(forDigest: pending.digest), maximumBytes: limits.maximumRecordBytes) else {
                throw WorkLaunchManifestStoreError.notFound
            }
            let pointer = try readPointer(pending.identity)
            if let pointer, pointer.digest != pending.digest {
                throw WorkLaunchManifestStoreError.identityMismatch
            }
            let record = try decodePayload(
                payload, identity: pending.identity,
                pointer: WorkLaunchManifestGeneration(
                    generation: pointer?.generation ?? 1, digest: pending.digest))
            // The pending file is a one-shot mutex, but cleanup is deliberately best-effort.
            // If both current pointers already name this exact record, a stale pending marker
            // cannot be allowed to wedge a later replacement Start.  Keep returning the record
            // for its exact intent; for any other intent, clear/ignore only this verified stale
            // marker and let the caller inspect the current selection normally.
            if let current = try readBindingPointer(for: binding),
               current.run == pending.identity.run,
               current.digest == pending.digest {
                if record.manifest.startIntent == intent {
                    try? removePendingPointer(for: binding)
                    return record
                }
                try? removePendingPointer(for: binding)
                return nil
            }
            if let current = try readBindingPointer(for: binding) {
                // A different current selection can only be newer than this pending admission
                // when its observed predecessor no longer matches. The pending mutex is then a
                // stale cleanup marker, not a reason to wedge a later replacement Start. Keep
                // the exact-predecessor case gated below so an unfinished publication cannot be
                // silently superseded.
                let currentGeneration = WorkLaunchManifestGeneration(
                    generation: current.generation, digest: current.digest)
                if pending.expectedPrevious != currentGeneration {
                    try? removePendingPointer(for: binding)
                    return nil
                }
            }
            // The pending slot is a single durable admission gate. A different intent is not a
            // cache miss: allowing a caller to overwrite it would lose the first Start's exact
            // Run reservation after a crash.
            guard record.manifest.startIntent == intent else {
                throw WorkLaunchManifestStoreError.requestConflict
            }
            return record
        }
    }

    /// Read an exact client-qualified Start record for duplicate receipt projection. Unlike
    /// ``readPendingStart``, this index is historical and is never used to update the current
    /// Work selection. A caller must separately prove whether the command is still live or is a
    /// finished historical duplicate from canonical Work events.
    public func readStart(
        for binding: WorkBinding,
        intent: WorkLaunchStartIntent
    ) throws -> WorkLaunchManifestRecord? {
        try withPreparedStorage {
            try validateBinding(binding)
            guard let data = try WorkLaunchDurableIO.readBounded(
                startPointerURL(for: binding, intent: intent),
                maximumBytes: limits.maximumMetadataBytes) else { return nil }
            let pointer: StartPointer
            do { pointer = try JSONDecoder().decode(StartPointer.self, from: data) }
            catch { throw WorkLaunchManifestStoreError.malformedRecord }
            guard pointer.schemaVersion == 1,
                  pointer.binding == binding,
                  pointer.intent == intent,
                  pointer.identity.work == binding.work,
                  pointer.identity.session == binding.session,
                  pointer.identity.sessionAttachment == binding.sessionAttachment,
                  WorkLaunchDurableIO.validDigest(pointer.digest) else {
                throw WorkLaunchManifestStoreError.identityMismatch
            }
            guard let payload = try WorkLaunchDurableIO.readBounded(
                manifestURL(forDigest: pointer.digest),
                maximumBytes: limits.maximumRecordBytes) else {
                throw WorkLaunchManifestStoreError.notFound
            }
            if let identityPointer = try readPointer(pointer.identity),
               identityPointer.digest != pointer.digest {
                throw WorkLaunchManifestStoreError.identityMismatch
            }
            return try decodePayload(
                payload, identity: pointer.identity,
                pointer: WorkLaunchManifestGeneration(
                    generation: (try readPointer(pointer.identity))?.generation ?? 1,
                    digest: pointer.digest))
        }
    }

    /// Reserve exactly one Run for a client-qualified Start. The reservation is the durable CAS
    /// winner which precedes prompt assembly. A caller receiving ``winner`` is the only caller
    /// allowed to read ambient prompt inputs; all later callers receive ``reserved`` and must use
    /// its already-retained assembly or report recovery-required.
    public func reserveStart(
        _ template: WorkLaunchWorkTemplateRecord,
        binding: WorkBinding,
        run: RunRef,
        startIntent: WorkLaunchStartIntent,
        expectedPrevious: WorkLaunchManifestGeneration? = nil,
        initialInputBodyReference: TimelineBodyReference
    ) throws -> WorkLaunchStartAdmission {
        try withPreparedStorage {
            let expectedAuthority = try home.requirePersistedWorkHostID()
            try validateBinding(binding)
            guard template.work == binding.work,
                  template.workHost == binding.workHost,
                  binding.work.workHostID == expectedAuthority,
                  let currentTemplate = try readTemplatePointer(for: template.work),
                  currentTemplate == template.generation else {
                throw WorkLaunchManifestStoreError.generationMismatch
            }
            let canonicalTemplate = try template.template.canonicalBytes()
            guard canonicalTemplate.count == template.templateByteCount,
                  WorkLaunchDurableIO.digest(canonicalTemplate) == template.digest else {
                throw WorkLaunchManifestStoreError.tamperedRecord
            }
            try validateTemplate(template.template)
            let identity = WorkLaunchManifestIdentity(
                work: binding.work, session: binding.session,
                sessionAttachment: binding.sessionAttachment, run: run)
            try WorkLaunchManifest.validateIdentity(identity, limits: limits)
            try WorkLaunchManifest.validateStartIntent(
                startIntent, identity: identity,
                bodyReference: initialInputBodyReference, limits: limits)
            try WorkLaunchManifest.validateBodyReference(
                initialInputBodyReference, identity: identity, limits: limits)
            if let expectedPrevious {
                guard expectedPrevious.generation > 0,
                      WorkLaunchDurableIO.validDigest(expectedPrevious.digest) else {
                    throw WorkLaunchManifestStoreError.generationMismatch
                }
            }

            // An already-indexed exact Start is a completed publication. It wins over any stale
            // reservation marker and is returned without touching prompt assembly.
            if let existing = try readStartLocked(for: binding, intent: startIntent) {
                guard existing.manifest.identity.run == run else {
                    throw WorkLaunchManifestStoreError.requestConflict
                }
                return .existing(existing)
            }

            if let existing = try readStartReservationLocked(for: binding) {
                // The reservation occupies the Work-scoped admission slot, so its payload may
                // belong to another attached Session. Validate it against its own binding before
                // comparing provenance; projecting the caller's Session into that identity would
                // turn a legitimate cross-Session CAS conflict into an identity-mismatch path.
                try validateStartReservation(existing)
                guard existing.binding == binding else {
                    throw WorkLaunchManifestStoreError.requestConflict
                }
                try validateStartReservation(
                    existing, identity: WorkLaunchManifestIdentity(
                        work: binding.work, session: binding.session,
                        sessionAttachment: binding.sessionAttachment, run: existing.run))
                // Cleanup after final publication is deliberately best-effort, so a process
                // crash or an injected removal failure can leave the binding-wide reservation
                // beside its already-complete historical Run.  A fully validated final record
                // proves that reservation's winner and makes the marker safe to discard; an
                // unpaired reservation remains an active CAS fence and must still reject any
                // different intent.
                if let completed = try readStartLocked(
                    for: binding, intent: existing.intent),
                   completed.manifest.identity.run == existing.run,
                   completed.manifest.initialInputBodyReference
                        == existing.initialInputBodyReference,
                   completed.manifest.promptAssembly == existing.promptAssembly,
                   try isFullyPublishedStartLocked(
                       for: binding, identity: completed.manifest.identity,
                       digest: completed.manifestDigest) {
                    try removeStartReservation(for: binding)
                } else {
                    guard existing.intent == startIntent,
                          existing.templateGeneration == template.generation,
                          existing.initialInputBodyReference == initialInputBodyReference else {
                        throw WorkLaunchManifestStoreError.requestConflict
                    }
                    return .reserved(existing)
                }
            }

            let current = try readBindingPointer(for: binding).map {
                WorkLaunchManifestGeneration(generation: $0.generation, digest: $0.digest)
            }
            if let currentPointer = try readBindingPointer(for: binding),
               currentPointer.run == run {
                throw WorkLaunchManifestStoreError.requestConflict
            }
            guard current == expectedPrevious else {
                throw WorkLaunchManifestStoreError.generationMismatch
            }
            let reservation = WorkLaunchStartReservation(
                binding: binding, run: run, intent: startIntent,
                templateGeneration: template.generation,
                initialInputBodyReference: initialInputBodyReference,
                expectedPrevious: expectedPrevious)
            try validateStartReservation(reservation, identity: identity)
            try writeStartReservation(reservation)
            return .winner(reservation)
        }
    }

    /// Persist the exact producer-side assembly after its source bodies have been retained and
    /// before final Run publication. Repeating this operation with identical bytes is idempotent;
    /// replacing it with a different assembly is a conflict.
    public func prepareStart(
        _ reservation: WorkLaunchStartReservation,
        promptAssembly: WorkLaunchPromptAssembly
    ) throws -> WorkLaunchStartReservation {
        try withPreparedStorage {
            try validateStartReservation(reservation)
            let binding = reservation.binding
            guard let existing = try readStartReservationLocked(for: binding) else {
                // Another winner may have completed publication and removed the reservation
                // between this retry's CAS read and preparation. Reuse that exact final record;
                // never invoke a second assembly for the same Start.
                if let completed = try readStartLocked(for: binding, intent: reservation.intent),
                   completed.manifest.identity.run == reservation.run,
                   let completedAssembly = completed.manifest.promptAssembly,
                   completedAssembly == promptAssembly {
                    return WorkLaunchStartReservation(
                        binding: reservation.binding, run: reservation.run,
                        intent: reservation.intent,
                        templateGeneration: reservation.templateGeneration,
                        initialInputBodyReference: reservation.initialInputBodyReference,
                        expectedPrevious: reservation.expectedPrevious,
                        promptAssembly: completedAssembly)
                }
                throw WorkLaunchManifestStoreError.notFound
            }
            guard existing.binding == binding, existing.run == reservation.run,
                  existing.intent == reservation.intent,
                  existing.templateGeneration == reservation.templateGeneration,
                  existing.initialInputBodyReference == reservation.initialInputBodyReference,
                  existing.expectedPrevious == reservation.expectedPrevious else {
                throw WorkLaunchManifestStoreError.requestConflict
            }
            let identity = WorkLaunchManifestIdentity(
                work: binding.work, session: binding.session,
                sessionAttachment: binding.sessionAttachment, run: reservation.run)
            try validateRetainedPromptAssembly(
                promptAssembly, authority: .workHost(try home.requirePersistedWorkHost()),
                identity: identity)
            if let old = existing.promptAssembly {
                guard old == promptAssembly else {
                    throw WorkLaunchManifestStoreError.requestConflict
                }
                return existing
            }
            let prepared = WorkLaunchStartReservation(
                binding: existing.binding, run: existing.run, intent: existing.intent,
                templateGeneration: existing.templateGeneration,
                initialInputBodyReference: existing.initialInputBodyReference,
                expectedPrevious: existing.expectedPrevious,
                promptAssembly: promptAssembly)
            try validateStartReservation(prepared, identity: identity)
            try writeStartReservation(prepared)
            return prepared
        }
    }

    /// Read the binding-wide Start fence without selecting a Run or invoking any resolver.
    public func readStartReservation(for binding: WorkBinding) throws
        -> WorkLaunchStartReservation? {
        try withPreparedStorage {
            try validateBinding(binding)
            guard let reservation = try readStartReservationLocked(for: binding) else { return nil }
            // The reservation path is the exact selected Start binding, unlike the Work-level
            // current-selection pointer. A caller for another Session may observe that Work is
            // fenced through hasPendingStart, but must not receive or reuse the first caller's
            // reservation provenance.
            guard reservation.binding == binding else {
                throw WorkLaunchManifestStoreError.requestConflict
            }
            let identity = WorkLaunchManifestIdentity(
                work: binding.work, session: binding.session,
                sessionAttachment: binding.sessionAttachment, run: reservation.run)
            try validateStartReservation(reservation, identity: identity)
            return reservation
        }
    }

    /// Repair the exact Work-level current selection for a manifest found in a publish crash
    /// window. The optional predecessor is a strict CAS fence: replacing an existing Run is only
    /// valid when the caller proves which selection it observed before this repair.
    internal func repairCurrentSelection(
        _ record: WorkLaunchManifestRecord,
        expectedPrevious: WorkLaunchManifestGeneration? = nil
    ) throws -> WorkLaunchManifestRecord {
        try withPreparedStorage {
            let expectedAuthority = try home.requirePersistedWorkHostID()
            try record.manifest.validate(limits: limits, expectedAuthority: expectedAuthority)
            let manifestDigest = try record.manifest.contentDigest()
            guard manifestDigest == record.manifestDigest else {
                throw WorkLaunchManifestStoreError.digestMismatch
            }
            let payload = try encodeManifestPayload(record.manifest, digest: manifestDigest)
            let payloadURL = manifestURL(forDigest: manifestDigest)
            if let existing = try WorkLaunchDurableIO.readBounded(
                payloadURL, maximumBytes: limits.maximumRecordBytes) {
                guard existing == payload else { throw WorkLaunchManifestStoreError.tamperedRecord }
            } else {
                try WorkLaunchDurableIO.writeNew(
                    payload, to: payloadURL, maximumBytes: limits.maximumRecordBytes)
            }

            let identity = record.manifest.identity
            if let current = try readPointer(identity) {
                guard current.digest == manifestDigest else {
                    throw WorkLaunchManifestStoreError.identityMismatch
                }
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let pointerData = try encoder.encode(Pointer(
                    schemaVersion: 1, identity: identity,
                    generation: max(1, record.generation.generation), digest: manifestDigest))
                try WorkLaunchDurableIO.replace(
                    pointerData, at: pointerURL(for: identity),
                    maximumBytes: limits.maximumMetadataBytes)
            }

            let binding = record.manifest.workRunBinding.workBinding
            // Pending is the durable mutex. Ensure the historical intent index exists before
            // publishing/changing the current binding pointer, so every crash boundary leaves
            // an exact duplicate path and never requires scanning historical payloads.
            try ensureStartPointer(
                for: binding, intent: record.manifest.startIntent,
                identity: identity, digest: manifestDigest)
            if let current = try readBindingPointer(for: binding) {
                if current.run == identity.run && current.digest == manifestDigest {
                    guard let identityPointer = try readPointer(identity) else {
                        throw WorkLaunchManifestStoreError.notFound
                    }
                    try ensureStartPointer(
                        for: binding, intent: record.manifest.startIntent,
                        identity: identity, digest: manifestDigest)
                    let repaired = try decodePayload(
                        payload, identity: identity, pointer: identityPointer)
                    // A stale reservation can survive the original final publication.  Repair
                    // must close that admission fence before returning, or the next distinct
                    // Run will be wedged behind an already-published historical winner.
                    try? removeStartReservation(for: binding)
                    try? removePendingPointer(for: binding)
                    return repaired
                }
                let prior = WorkLaunchManifestGeneration(
                    generation: current.generation, digest: current.digest)
                guard expectedPrevious == prior else {
                    throw WorkLaunchManifestStoreError.generationMismatch
                }
                let generation = try nextGeneration(after: current.generation)
                try writeBindingPointer(BindingPointer(
                    schemaVersion: 1, binding: binding, run: identity.run,
                    generation: generation, digest: manifestDigest))
            } else {
                guard expectedPrevious == nil else {
                    throw WorkLaunchManifestStoreError.generationMismatch
                }
                try writeBindingPointer(BindingPointer(
                    schemaVersion: 1, binding: binding, run: identity.run,
                    generation: 1, digest: manifestDigest))
            }
            guard let identityPointer = try readPointer(identity) else {
                throw WorkLaunchManifestStoreError.notFound
            }
            let repaired = try decodePayload(payload, identity: identity, pointer: identityPointer)
            try? removeStartReservation(for: binding)
            try? removePendingPointer(for: binding)
            return repaired
        }
    }

    internal func current(
        for identity: WorkLaunchManifestIdentity
    ) throws -> WorkLaunchManifestRecord? {
        try read(identity)
    }

    internal func load(manifestDigest digest: String) throws -> WorkLaunchManifestRecord {
        try withPreparedStorage {
            guard WorkLaunchDurableIO.validDigest(digest) else {
                throw WorkLaunchManifestStoreError.digestMismatch
            }
            guard let payload = try WorkLaunchDurableIO.readBounded(
                manifestURL(forDigest: digest), maximumBytes: limits.maximumRecordBytes)
            else { throw WorkLaunchManifestStoreError.notFound }
            let decoded = try decodeEnvelope(payload)
            guard decoded.digest == digest else { throw WorkLaunchManifestStoreError.digestMismatch }
            return try decodePayload(payload, identity: decoded.manifest.identity,
                                     pointer: WorkLaunchManifestGeneration(
                                        generation: 0, digest: decoded.digest))
        }
    }

    public func resolveInitialInputBody(for manifest: WorkLaunchManifest) throws -> Data {
        try manifest.validate(
            limits: limits, expectedAuthority: try home.requirePersistedWorkHostID())
        guard let reference = manifest.initialInputBodyReference else {
            throw WorkLaunchManifestStoreError.bodyUnavailable
        }
        return try resolveBody(reference)
    }

    public func resolveSystemPromptBody(for manifest: WorkLaunchManifest) throws -> Data {
        try manifest.validate(
            limits: limits, expectedAuthority: try home.requirePersistedWorkHostID())
        guard let assembly = manifest.promptAssembly else {
            throw WorkLaunchManifestStoreError.bodyUnavailable
        }
        try validateRetainedPromptAssembly(
            assembly, authority: .workHost(try home.requirePersistedWorkHost()),
            identity: manifest.identity)
        return try ContextBodyStore(home: home).read(assembly.flattenedBodyReference)
    }

    private func resolveBody(_ reference: TimelineBodyReference) throws -> Data {
        guard let digest = reference.digest,
              reference.referenceID == digest,
              ContextBodyStore.isValidDigest(digest),
              let byteCount = reference.byteCount,
              byteCount >= 0,
              byteCount <= limits.maximumBodyBytes else {
            throw WorkLaunchManifestStoreError.invalidReference
        }
        let bodyRoot = ContextBodyStore(home: home).root
        let bodyDirectory = bodyRoot.appending(path: "sha256", directoryHint: .isDirectory)
        try WorkLaunchDurableIO.verifyPrivateDirectory(bodyRoot)
        try WorkLaunchDurableIO.verifyPrivateDirectory(bodyDirectory)
        let bodyURL = bodyDirectory.appending(
            path: String(digest.dropFirst("sha256:".count)), directoryHint: .notDirectory)
        let body: Data?
        do {
            body = try WorkLaunchDurableIO.readBounded(bodyURL, maximumBytes: limits.maximumBodyBytes)
        } catch let error as WorkLaunchManifestStoreError {
            switch error {
            case .symlinkOrNonRegularFile, .accessDenied:
                throw error
            default:
                throw WorkLaunchManifestStoreError.bodyUnavailable
            }
        } catch {
            throw WorkLaunchManifestStoreError.bodyUnavailable
        }
        guard let body, body.count == byteCount, WorkLaunchDurableIO.digest(body) == digest else {
            throw WorkLaunchManifestStoreError.bodyUnavailable
        }
        return body
    }

    internal func remove(
        _ identity: WorkLaunchManifestIdentity,
        expected: WorkLaunchManifestGeneration
    ) throws {
        try withPreparedStorage {
            let expectedAuthority = try home.requirePersistedWorkHostID()
            guard identity.work.workHostID == expectedAuthority else {
                throw WorkLaunchManifestStoreError.wrongAuthority(
                    expected: expectedAuthority, actual: identity.work.workHostID)
            }
            guard let current = try readPointer(identity), current == expected else {
                throw WorkLaunchManifestStoreError.generationMismatch
            }
            let pointer = pointerURL(for: identity)
            guard unlink(pointer.path) == 0 || errno == ENOENT else {
                throw WorkLaunchManifestStoreError.ioFailure("removal")
            }
            let bindingPointerURL = bindingPointerURL(for: WorkBinding(
                session: identity.session, work: identity.work,
                workHost: WorkHostRef(identity.work.workHostID),
                sessionAttachment: identity.sessionAttachment))
            if let current = try readBindingPointer(for: WorkBinding(
                session: identity.session, work: identity.work,
                workHost: WorkHostRef(identity.work.workHostID),
                sessionAttachment: identity.sessionAttachment)), current.run == identity.run,
               current.digest == expected.digest {
                guard unlink(bindingPointerURL.path) == 0 || errno == ENOENT else {
                    throw WorkLaunchManifestStoreError.ioFailure("binding pointer removal")
                }
            }
            try WorkLaunchDurableIO.synchronizeDirectory(pointerDirectory)
            try WorkLaunchDurableIO.synchronizeDirectory(bindingPointerDirectory)
        }
    }

    internal func remove(_ record: WorkLaunchManifestRecord) throws {
        try remove(record.manifest.identity, expected: record.generation)
    }

    private struct Pointer: Codable, Hashable {
        let schemaVersion: Int
        let identity: WorkLaunchManifestIdentity
        let generation: Int
        let digest: String
    }

    private struct Envelope: Codable, Hashable {
        let schemaVersion: Int
        let identity: WorkLaunchManifestIdentity
        let digest: String
        let manifestByteCount: Int
        let manifest: WorkLaunchManifest
    }

    private struct DraftEnvelope: Codable, Hashable {
        let schemaVersion: Int
        let digest: String
        let draftByteCount: Int
        let draft: WorkLaunchManifestDraft
    }

    private struct RequestPointer: Codable, Hashable {
        let schemaVersion: Int
        let key: WorkLaunchCreateKey
        let draftDigest: String
        let draftByteCount: Int
        let idempotencyDigest: String
    }

    private struct TemplatePointer: Codable, Hashable {
        let schemaVersion: Int
        let work: WorkRef
        let workHost: WorkHostRef
        let generation: Int
        let digest: String
    }

    private struct TemplateEnvelope: Codable, Hashable {
        let schemaVersion: Int
        let work: WorkRef
        let workHost: WorkHostRef
        let digest: String
        let templateByteCount: Int
        let template: WorkLaunchWorkTemplate
    }

    private struct BindingPointer: Codable, Hashable {
        let schemaVersion: Int
        let binding: WorkBinding
        let run: RunRef
        let generation: Int
        let digest: String
    }

    /// This pointer is an intent-keyed recovery fence, not another current selection. It remains
    /// until both current pointers are durable, and is removed as a best-effort cleanup after a
    /// successful publication. A stale pointer can therefore only name the exact payload it was
    /// created for; it is never inferred from the unbounded historical payload directory.
    private struct PendingPointer: Codable, Hashable {
        let schemaVersion: Int
        let binding: WorkBinding
        let identity: WorkLaunchManifestIdentity
        let digest: String
        let expectedPrevious: WorkLaunchManifestGeneration?
    }

    private struct StartPointer: Codable, Hashable {
        let schemaVersion: Int
        let binding: WorkBinding
        let intent: WorkLaunchStartIntent
        let identity: WorkLaunchManifestIdentity
        let digest: String
    }

    private static func addressMaterial(for key: WorkLaunchCreateKey) -> String {
        ["create", key.client.clientID, key.commandID,
         key.causalControlCursor.journal.stableKey,
         key.causalControlCursor.eventID ?? "",
         String(key.causalControlCursor.sequence),
         key.requestDigest]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "\u{0}")
    }

    private static func addressMaterial(for work: WorkRef) -> String {
        ["work", work.workHostID, work.workID]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "\u{0}")
    }

    private static func addressMaterial(for binding: WorkBinding) -> String {
        ["binding", binding.work.workHostID, binding.work.workID,
         binding.session.sessionID, binding.sessionAttachment.attachmentID]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "\u{0}")
    }

    private func validateRetainedPromptAssembly(
        _ assembly: WorkLaunchPromptAssembly,
        authority: JournalRef,
        identity: WorkLaunchManifestIdentity? = nil
    ) throws {
        let host = try home.requirePersistedWorkHost()
        guard authority == .workHost(host) else {
            throw WorkLaunchManifestStoreError.wrongAuthority(
                expected: host.workHostID, actual: authority.authority.authorityID)
        }
        let validationIdentity = identity ?? WorkLaunchManifestIdentity(
            work: WorkRef(workHostID: host.workHostID, workID: "prompt-validation"),
            session: SessionRef("prompt-validation"),
            sessionAttachment: SessionAttachmentRef("prompt-validation"),
            run: RunRef("prompt-validation"))
        try WorkLaunchManifest.validatePromptAssembly(
            assembly, identity: validationIdentity, limits: limits)
        guard assembly.provenance.source.utf8.count <= limits.maximumMetadataBytes,
              !assembly.provenance.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !assembly.provenance.source.unicodeScalars.contains(where: { $0.value == 0 }),
              !assembly.provenance.source.contains("/"),
              !assembly.provenance.source.contains("\\") else {
            throw WorkLaunchManifestStoreError.invalidManifest("prompt provenance")
        }
    }

    private func validateCreateKeyShape(_ key: WorkLaunchCreateKey) throws {
        guard !key.client.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              key.client.clientID.utf8.count <= limits.maximumIdentityBytes,
              !key.client.clientID.unicodeScalars.contains(where: { $0.value == 0 }),
              !key.commandID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              key.commandID.utf8.count <= limits.maximumIdentityBytes,
              !key.commandID.unicodeScalars.contains(where: { $0.value == 0 }),
              key.causalControlCursor.sequence >= 0,
              key.causalControlCursor.journal.stableKey.utf8.count <= limits.maximumIdentityBytes,
              !key.causalControlCursor.journal.stableKey.unicodeScalars.contains(where: { $0.value == 0 }),
              (key.causalControlCursor.eventID?.utf8.count ?? 0) <= limits.maximumIdentityBytes,
              !(key.causalControlCursor.eventID?.unicodeScalars.contains(where: { $0.value == 0 }) ?? false)
        else {
            throw WorkLaunchManifestStoreError.invalidManifest("create key")
        }
        let persistedHost = try home.requirePersistedWorkHost()
        let expected = JournalCursor(
            journal: .workHost(persistedHost), eventID: nil, sequence: 0)
        guard key.causalControlCursor == expected else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
    }

    private func validateCreateKey(_ key: WorkLaunchCreateKey) throws {
        try validateCreateKeyShape(key)
        guard WorkLaunchDurableIO.validDigest(key.requestDigest) else {
            throw WorkLaunchManifestStoreError.invalidManifest("create key")
        }
    }

    private func validateCreateRequestDigest(
        _ key: WorkLaunchCreateKey, draft: WorkLaunchManifestDraft
    ) throws {
        let expected = try WorkLaunchCreateKey.requestDigest(
            configuration: draft.configuration,
            requestedCapabilities: draft.requestedCapabilities)
        guard key.requestDigest == expected else {
            throw WorkLaunchManifestStoreError.requestConflict
        }
    }

    private func validateBinding(_ binding: WorkBinding) throws {
        let expectedAuthority = try home.requirePersistedWorkHostID()
        guard binding.work.workHostID == expectedAuthority else {
            throw WorkLaunchManifestStoreError.wrongAuthority(
                expected: expectedAuthority, actual: binding.work.workHostID)
        }
        let values = [binding.session.sessionID, binding.work.workID,
                      binding.work.workHostID, binding.workHost.workHostID,
                      binding.sessionAttachment.attachmentID]
        guard values.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.utf8.count <= limits.maximumIdentityBytes
                && !$0.unicodeScalars.contains(where: { $0.value == 0 })
        }), binding.workHost == WorkHostRef(binding.work.workHostID) else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
    }

    private func retainDraftLocked(_ draft: WorkLaunchManifestDraft) throws
        -> WorkLaunchManifestDraftRecord
    {
        try draft.validate(limits: limits)
        let bytes = try draft.canonicalBytes()
        let digest = WorkLaunchDurableIO.digest(bytes)
        let envelope = DraftEnvelope(
            schemaVersion: 1, digest: digest, draftByteCount: bytes.count, draft: draft)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(envelope)
        guard payload.count <= limits.maximumRecordBytes else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        let destination = draftURL(forDigest: digest)
        if let existing = try WorkLaunchDurableIO.readBounded(
            destination, maximumBytes: limits.maximumRecordBytes) {
            guard existing == payload else { throw WorkLaunchManifestStoreError.tamperedRecord }
        } else {
            try WorkLaunchDurableIO.writeNew(
                payload, to: destination, maximumBytes: limits.maximumRecordBytes)
        }
        return WorkLaunchManifestDraftRecord(
            draft: draft, digest: digest, draftByteCount: bytes.count)
    }

    private func loadDraftLocked(digest: String) throws -> WorkLaunchManifestDraftRecord {
        guard WorkLaunchDurableIO.validDigest(digest) else {
            throw WorkLaunchManifestStoreError.digestMismatch
        }
        guard let payload = try WorkLaunchDurableIO.readBounded(
            draftURL(forDigest: digest), maximumBytes: limits.maximumRecordBytes) else {
            throw WorkLaunchManifestStoreError.notFound
        }
        let envelope: DraftEnvelope
        do { envelope = try JSONDecoder().decode(DraftEnvelope.self, from: payload) }
        catch { throw WorkLaunchManifestStoreError.malformedRecord }
        guard envelope.schemaVersion == 1, envelope.digest == digest,
              envelope.draftByteCount >= 0,
              envelope.draftByteCount <= limits.maximumManifestBytes else {
            throw WorkLaunchManifestStoreError.tamperedRecord
        }
        try envelope.draft.validate(limits: limits)
        let bytes = try envelope.draft.canonicalBytes()
        guard bytes.count == envelope.draftByteCount,
              WorkLaunchDurableIO.digest(bytes) == envelope.digest else {
            throw WorkLaunchManifestStoreError.digestMismatch
        }
        return WorkLaunchManifestDraftRecord(
            draft: envelope.draft, digest: envelope.digest,
            draftByteCount: envelope.draftByteCount)
    }

    private func decodeRequestPointer(_ data: Data) throws -> RequestPointer {
        let pointer: RequestPointer
        do { pointer = try JSONDecoder().decode(RequestPointer.self, from: data) }
        catch { throw WorkLaunchManifestStoreError.malformedRecord }
        guard pointer.schemaVersion == 1,
              WorkLaunchDurableIO.validDigest(pointer.key.requestDigest),
              WorkLaunchDurableIO.validDigest(pointer.draftDigest),
              WorkLaunchDurableIO.validDigest(pointer.idempotencyDigest),
              pointer.draftByteCount >= 0,
              pointer.draftByteCount <= limits.maximumManifestBytes else {
            throw WorkLaunchManifestStoreError.tamperedRecord
        }
        try validateCreateKey(pointer.key)
        return pointer
    }

    private func rejectConflictingCreateIdentityLocked(
        _ key: WorkLaunchCreateKey
    ) throws {
        guard FileManager.default.fileExists(atPath: requestPointerDirectory.path) else {
            return
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: requestPointerDirectory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        guard entries.count <= limits.maximumArrayEntries else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw WorkLaunchManifestStoreError.symlinkOrNonRegularFile
            }
            guard let data = try WorkLaunchDurableIO.readBounded(
                entry, maximumBytes: limits.maximumMetadataBytes) else {
                throw WorkLaunchManifestStoreError.notFound
            }
            let pointer = try decodeRequestPointer(data)
            if pointer.key.client == key.client,
               pointer.key.commandID == key.commandID,
               pointer.key != key {
                throw WorkLaunchManifestStoreError.requestConflict
            }
        }
    }

    private func writeRequestPointer(_ pointer: RequestPointer, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(pointer)
        guard data.count <= limits.maximumMetadataBytes else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        try WorkLaunchDurableIO.replace(data, at: url, maximumBytes: limits.maximumMetadataBytes)
    }

    private func nextGeneration(after generation: Int) throws -> Int {
        let addition = generation.addingReportingOverflow(1)
        guard !addition.overflow, addition.partialValue > generation else {
            throw WorkLaunchManifestStoreError.invalidGeneration
        }
        return addition.partialValue
    }

    private func validateTemplate(_ template: WorkLaunchWorkTemplate) throws {
        guard template.schemaVersion == WorkLaunchWorkTemplate.currentSchemaVersion else {
            throw WorkLaunchManifestStoreError.invalidManifest("unsupported template schema")
        }
        try template.draft.validate(limits: limits)
        // A Work template has no Run or Start identity yet. In particular, its exact input and
        // prompt bodies do not exist until Start retains them under the winning Run reservation.
        let expectedAuthority = try home.requirePersistedWorkHostID()
        guard template.work.workHostID == expectedAuthority,
              template.workHost == WorkHostRef(expectedAuthority) else {
            throw WorkLaunchManifestStoreError.wrongAuthority(
                expected: expectedAuthority, actual: template.work.workHostID)
        }
        // A template is executable recovery material only when its draft is tied to the
        // client-qualified Create retention pointer.  This check is intentionally performed on
        // every read, not just on first publication, so a hand-written template payload cannot
        // masquerade as a durable Create result after restart.
        guard let requestData = try WorkLaunchDurableIO.readBounded(
            requestPointerURL(for: template.retentionKey),
            maximumBytes: limits.maximumMetadataBytes) else {
            throw WorkLaunchManifestStoreError.notFound
        }
        let requestPointer = try decodeRequestPointer(requestData)
        guard requestPointer.key == template.retentionKey else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        let retained = try loadDraftLocked(digest: requestPointer.draftDigest)
        guard retained.draft == template.draft,
              retained.digest == requestPointer.draftDigest,
              retained.draftByteCount == requestPointer.draftByteCount,
              try retained.draft.idempotencyDigest() == requestPointer.idempotencyDigest else {
            throw WorkLaunchManifestStoreError.tamperedRecord
        }
        try validateCreateRequestDigest(template.retentionKey, draft: template.draft)
    }

    private func saveTemplateLocked(
        _ template: WorkLaunchWorkTemplate
    ) throws -> WorkLaunchWorkTemplateRecord {
        try validateTemplate(template)
        let bytes = try template.canonicalBytes()
        guard bytes.count <= limits.maximumManifestBytes else {
            throw WorkLaunchManifestStoreError.manifestTooLarge
        }
        let digest = WorkLaunchDurableIO.digest(bytes)
        if let current = try readTemplatePointer(for: template.work) {
            guard let payload = try WorkLaunchDurableIO.readBounded(
                templateURL(forDigest: current.digest), maximumBytes: limits.maximumRecordBytes) else {
                throw WorkLaunchManifestStoreError.notFound
            }
            let existing = try decodeTemplatePayload(
                payload, work: template.work, pointer: current)
            if current.digest == digest {
                guard existing.template.work == template.work,
                      existing.template.workHost == template.workHost else {
                    throw WorkLaunchManifestStoreError.identityMismatch
                }
                return existing
            }
            // A second Create for this Work must use the durable replacement API with an
            // expected generation. Silent replacement here could move a Work to different
            // Session/attachment material after a lost response.
            guard existing.template.work == template.work,
                  existing.template.workHost == template.workHost else {
                throw WorkLaunchManifestStoreError.identityMismatch
            }
            throw WorkLaunchManifestStoreError.requestConflict
        }
        return try publishTemplateLocked(template, generation: 1)
    }

    private func publishTemplateLocked(
        _ template: WorkLaunchWorkTemplate, generation: Int
    ) throws -> WorkLaunchWorkTemplateRecord {
        try validateTemplate(template)
        let bytes = try template.canonicalBytes()
        guard bytes.count <= limits.maximumManifestBytes else {
            throw WorkLaunchManifestStoreError.manifestTooLarge
        }
        let digest = WorkLaunchDurableIO.digest(bytes)
        let envelope = TemplateEnvelope(
            schemaVersion: 2, work: template.work, workHost: template.workHost, digest: digest,
            templateByteCount: bytes.count, template: template)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(envelope)
        guard payload.count <= limits.maximumRecordBytes else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        let payloadURL = templateURL(forDigest: digest)
        if let existing = try WorkLaunchDurableIO.readBounded(
            payloadURL, maximumBytes: limits.maximumRecordBytes) {
            guard existing == payload else { throw WorkLaunchManifestStoreError.tamperedRecord }
        } else {
            try WorkLaunchDurableIO.writeNew(
                payload, to: payloadURL, maximumBytes: limits.maximumRecordBytes)
        }
        let pointer = TemplatePointer(
            schemaVersion: 2, work: template.work, workHost: template.workHost,
            generation: generation, digest: digest)
        try writeTemplatePointer(pointer)
        return WorkLaunchWorkTemplateRecord(
            template: template,
            generation: WorkLaunchWorkTemplateGeneration(generation: generation, digest: digest),
            templateByteCount: bytes.count)
    }

    private func writeTemplatePointer(_ pointer: TemplatePointer) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(pointer)
        guard data.count <= limits.maximumMetadataBytes else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        try WorkLaunchDurableIO.replace(
            data, at: templatePointerURL(for: pointer.work),
            maximumBytes: limits.maximumMetadataBytes)
    }

    private func readTemplatePointer(for work: WorkRef) throws -> WorkLaunchWorkTemplateGeneration? {
        guard let data = try WorkLaunchDurableIO.readBounded(
            templatePointerURL(for: work), maximumBytes: limits.maximumMetadataBytes) else {
            return nil
        }
        let pointer: TemplatePointer
        do { pointer = try JSONDecoder().decode(TemplatePointer.self, from: data) }
        catch { throw WorkLaunchManifestStoreError.malformedRecord }
        guard pointer.schemaVersion == 2, pointer.work == work,
              pointer.workHost == WorkHostRef(work.workHostID),
              pointer.generation > 0, WorkLaunchDurableIO.validDigest(pointer.digest) else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        return WorkLaunchWorkTemplateGeneration(
            generation: pointer.generation, digest: pointer.digest)
    }

    private func decodeTemplatePayload(
        _ payload: Data, work: WorkRef, pointer: WorkLaunchWorkTemplateGeneration
    ) throws -> WorkLaunchWorkTemplateRecord {
        let envelope: TemplateEnvelope
        do { envelope = try JSONDecoder().decode(TemplateEnvelope.self, from: payload) }
        catch { throw WorkLaunchManifestStoreError.malformedRecord }
        guard envelope.schemaVersion == 2,
              envelope.work == work,
              envelope.workHost == envelope.template.workHost,
              envelope.template.work == work,
              envelope.digest == pointer.digest,
              envelope.templateByteCount >= 0,
              envelope.templateByteCount <= limits.maximumManifestBytes,
              WorkLaunchDurableIO.validDigest(envelope.digest) else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        try validateTemplate(envelope.template)
        let bytes = try envelope.template.canonicalBytes()
        guard bytes.count == envelope.templateByteCount else {
            throw WorkLaunchManifestStoreError.tamperedRecord
        }
        guard WorkLaunchDurableIO.digest(bytes) == envelope.digest else {
            throw WorkLaunchManifestStoreError.digestMismatch
        }
        return WorkLaunchWorkTemplateRecord(
            template: envelope.template, generation: pointer,
            templateByteCount: envelope.templateByteCount)
    }

    private func writeBindingPointer(_ pointer: BindingPointer) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(pointer)
        guard data.count <= limits.maximumMetadataBytes else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        try WorkLaunchDurableIO.replace(
            data, at: bindingPointerURL(for: pointer.binding),
            maximumBytes: limits.maximumMetadataBytes)
    }

    private func writePendingPointer(_ pointer: PendingPointer) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(pointer)
        guard data.count <= limits.maximumMetadataBytes else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        try WorkLaunchDurableIO.replace(
            data, at: pendingPointerURL(for: pointer.binding),
            maximumBytes: limits.maximumMetadataBytes)
    }

    private func writeStartPointer(_ pointer: StartPointer) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(pointer)
        guard data.count <= limits.maximumMetadataBytes else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        try WorkLaunchDurableIO.replace(
            data, at: startPointerURL(for: pointer.binding, intent: pointer.intent),
            maximumBytes: limits.maximumMetadataBytes)
    }

    private func writeStartReservation(
        _ reservation: WorkLaunchStartReservation
    ) throws {
        try validateStartReservation(reservation)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(reservation)
        guard data.count <= limits.maximumMetadataBytes else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        try WorkLaunchDurableIO.replace(
            data, at: startReservationURL(for: reservation.binding),
            maximumBytes: limits.maximumMetadataBytes)
    }

    private func ensureStartPointer(
        for binding: WorkBinding,
        intent: WorkLaunchStartIntent,
        identity: WorkLaunchManifestIdentity,
        digest: String
    ) throws {
        if let existing = try readStartPointer(for: binding, intent: intent) {
            guard existing.identity == identity, existing.digest == digest else {
                throw WorkLaunchManifestStoreError.requestConflict
            }
            return
        }
        try writeStartPointer(StartPointer(
            schemaVersion: 1, binding: binding, intent: intent,
            identity: identity, digest: digest))
    }

    private func readPendingPointer(for binding: WorkBinding) throws -> PendingPointer? {
        guard let data = try WorkLaunchDurableIO.readBounded(
            pendingPointerURL(for: binding), maximumBytes: limits.maximumMetadataBytes) else {
            return nil
        }
        let pointer: PendingPointer
        do { pointer = try JSONDecoder().decode(PendingPointer.self, from: data) }
        catch { throw WorkLaunchManifestStoreError.malformedRecord }
        guard pointer.schemaVersion == 1,
              pointer.binding.work == binding.work,
              pointer.binding.workHost == binding.workHost,
              pointer.identity.work == pointer.binding.work,
              pointer.identity.session == pointer.binding.session,
              pointer.identity.sessionAttachment == pointer.binding.sessionAttachment,
              WorkLaunchDurableIO.validDigest(pointer.digest) else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        if let expectedPrevious = pointer.expectedPrevious {
            guard expectedPrevious.generation > 0,
                  WorkLaunchDurableIO.validDigest(expectedPrevious.digest) else {
                throw WorkLaunchManifestStoreError.identityMismatch
            }
        }
        return pointer
    }

    /// Inspect only the binding-wide pending fence. The caller intentionally does not get to
    /// turn this into a manifest or a Run: without the matching client-qualified intent, the
    /// pending record is an admission/recovery fact and must not be guessed at.
    internal func hasPendingStart(for binding: WorkBinding) throws -> Bool {
        try withPreparedStorage {
            try validateBinding(binding)
            // Both the final publish mutex and the pre-assembly reservation represent an
            // unfinished Start admission unless they are paired with a fully validated final
            // publication. Cleanup is best-effort, so recovery classification must not turn an
            // already-published historical Run back into an active wedge.
            var active = false
            if let pending = try readPendingPointer(for: binding) {
                if try isFullyPublishedStartLocked(
                    for: binding, identity: pending.identity, digest: pending.digest) {
                    try? removePendingPointer(for: binding)
                } else {
                    active = true
                }
            }
            if let reservation = try readStartReservationLocked(for: binding) {
                try validateStartReservation(reservation)
                if let completed = try readStartLocked(for: binding, intent: reservation.intent),
                   completed.manifest.identity.run == reservation.run,
                   completed.manifest.initialInputBodyReference
                        == reservation.initialInputBodyReference,
                   completed.manifest.promptAssembly == reservation.promptAssembly,
                   try isFullyPublishedStartLocked(
                       for: binding, identity: completed.manifest.identity,
                       digest: completed.manifestDigest) {
                    try? removeStartReservation(for: binding)
                } else {
                    active = true
                }
            }
            return active
        }
    }

    /// Return whether the single pending admission still targets the selection which existed
    /// before it was published. A newer current selection proves this is historical; callers may
    /// replay its receipt but must not move the Work-level pointer backwards.
    internal func mayRepairPendingStart(
        for binding: WorkBinding,
        intent: WorkLaunchStartIntent,
        currentSelection: WorkLaunchBindingSelection?
    ) throws -> Bool {
        try withPreparedStorage {
            try validateBinding(binding)
            guard let data = try WorkLaunchDurableIO.readBounded(
                pendingPointerURL(for: binding), maximumBytes: limits.maximumMetadataBytes) else {
                return false
            }
            let pending: PendingPointer
            do { pending = try JSONDecoder().decode(PendingPointer.self, from: data) }
            catch { throw WorkLaunchManifestStoreError.malformedRecord }
            guard pending.schemaVersion == 1, pending.binding == binding,
                  pending.identity.work == binding.work,
                  pending.identity.session == binding.session,
                  pending.identity.sessionAttachment == binding.sessionAttachment,
                  WorkLaunchDurableIO.validDigest(pending.digest) else {
                throw WorkLaunchManifestStoreError.identityMismatch
            }
            guard let payload = try WorkLaunchDurableIO.readBounded(
                manifestURL(forDigest: pending.digest), maximumBytes: limits.maximumRecordBytes)
            else { throw WorkLaunchManifestStoreError.notFound }
            let identityPointer = try readPointer(pending.identity)
            let record = try decodePayload(
                payload, identity: pending.identity,
                pointer: WorkLaunchManifestGeneration(
                    generation: identityPointer?.generation ?? 1, digest: pending.digest))
            guard record.manifest.startIntent == intent else {
                throw WorkLaunchManifestStoreError.requestConflict
            }
            guard let expectedPrevious = pending.expectedPrevious else {
                // A nil predecessor is the first Start. It is repairable only while no current
                // selection exists; a later Run must never be rewound to it.
                return currentSelection == nil
            }
            guard let currentSelection else { return false }
            return currentSelection.selectionGeneration == expectedPrevious
        }
    }

    private func readStartPointer(
        for binding: WorkBinding, intent: WorkLaunchStartIntent
    ) throws -> StartPointer? {
        guard let data = try WorkLaunchDurableIO.readBounded(
            startPointerURL(for: binding, intent: intent),
            maximumBytes: limits.maximumMetadataBytes) else {
            return nil
        }
        let pointer: StartPointer
        do { pointer = try JSONDecoder().decode(StartPointer.self, from: data) }
        catch { throw WorkLaunchManifestStoreError.malformedRecord }
        guard pointer.schemaVersion == 1,
              pointer.binding == binding,
              pointer.intent == intent,
              pointer.identity.work == binding.work,
              pointer.identity.session == binding.session,
              pointer.identity.sessionAttachment == binding.sessionAttachment,
              WorkLaunchDurableIO.validDigest(pointer.digest) else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        return pointer
    }

    private func readStartLocked(
        for binding: WorkBinding, intent: WorkLaunchStartIntent
    ) throws -> WorkLaunchManifestRecord? {
        guard let pointer = try readStartPointer(for: binding, intent: intent) else { return nil }
        guard let payload = try WorkLaunchDurableIO.readBounded(
            manifestURL(forDigest: pointer.digest), maximumBytes: limits.maximumRecordBytes) else {
            throw WorkLaunchManifestStoreError.notFound
        }
        if let identityPointer = try readPointer(pointer.identity),
           identityPointer.digest != pointer.digest {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        return try decodePayload(
            payload, identity: pointer.identity,
            pointer: WorkLaunchManifestGeneration(
                generation: (try readPointer(pointer.identity))?.generation ?? 1,
                digest: pointer.digest))
    }

    /// Prove that a one-shot marker is now paired with every final publication edge. This is
    /// intentionally stricter than merely finding a payload: the identity pointer (written last
    /// by publication), and exact client-qualified Start index must both exist before recovery
    /// may ignore cleanup. A non-current identity is a historical final Run and is equally safe
    /// to clean; the next current binding cannot have advanced before this edge was written.
    private func isFullyPublishedStartLocked(
        for binding: WorkBinding,
        identity: WorkLaunchManifestIdentity,
        digest: String
    ) throws -> Bool {
        guard identity.work == binding.work,
              identity.session == binding.session,
              identity.sessionAttachment == binding.sessionAttachment,
              WorkLaunchDurableIO.validDigest(digest),
              let identityPointer = try readPointer(identity),
              identityPointer.digest == digest,
              let payload = try WorkLaunchDurableIO.readBounded(
                  manifestURL(forDigest: digest), maximumBytes: limits.maximumRecordBytes) else {
            return false
        }
        let record = try decodePayload(payload, identity: identity, pointer: identityPointer)
        guard let startPointer = try readStartPointer(
            for: binding, intent: record.manifest.startIntent),
              startPointer.identity == identity,
              startPointer.digest == digest else {
            return false
        }
        return true
    }

    private func readStartReservationLocked(
        for binding: WorkBinding
    ) throws -> WorkLaunchStartReservation? {
        guard let data = try WorkLaunchDurableIO.readBounded(
            startReservationURL(for: binding), maximumBytes: limits.maximumMetadataBytes) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(WorkLaunchStartReservation.self, from: data)
        } catch {
            throw WorkLaunchManifestStoreError.malformedRecord
        }
    }

    private func validateStartReservation(
        _ reservation: WorkLaunchStartReservation,
        identity: WorkLaunchManifestIdentity? = nil
    ) throws {
        guard reservation.schemaVersion == WorkLaunchStartReservation.currentSchemaVersion,
              reservation.binding.workHost == WorkHostRef(reservation.binding.work.workHostID),
              reservation.templateGeneration.generation > 0,
              WorkLaunchDurableIO.validDigest(reservation.templateGeneration.digest),
              reservation.expectedPrevious == nil
                  || (reservation.expectedPrevious!.generation > 0
                      && WorkLaunchDurableIO.validDigest(reservation.expectedPrevious!.digest)) else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        let expectedIdentity = identity ?? WorkLaunchManifestIdentity(
            work: reservation.binding.work, session: reservation.binding.session,
            sessionAttachment: reservation.binding.sessionAttachment, run: reservation.run)
        try WorkLaunchManifest.validateIdentity(expectedIdentity, limits: limits)
        try WorkLaunchManifest.validateStartIntent(
            reservation.intent, identity: expectedIdentity,
            bodyReference: reservation.initialInputBodyReference, limits: limits)
        try WorkLaunchManifest.validateBodyReference(
            reservation.initialInputBodyReference, identity: expectedIdentity, limits: limits)
        if let promptAssembly = reservation.promptAssembly {
            try WorkLaunchManifest.validatePromptAssembly(
                promptAssembly, identity: expectedIdentity, limits: limits)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(reservation).count <= limits.maximumMetadataBytes else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
    }

    private func removePendingPointer(for binding: WorkBinding) throws {
        let url = pendingPointerURL(for: binding)
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw WorkLaunchManifestStoreError.ioFailure("pending pointer removal")
        }
        try WorkLaunchDurableIO.synchronizeDirectory(pendingPointerDirectory)
    }

    private func readBindingPointer(for binding: WorkBinding) throws -> BindingPointer? {
        guard let data = try WorkLaunchDurableIO.readBounded(
            bindingPointerURL(for: binding), maximumBytes: limits.maximumMetadataBytes) else {
            return nil
        }
        let pointer: BindingPointer
        do { pointer = try JSONDecoder().decode(BindingPointer.self, from: data) }
        catch { throw WorkLaunchManifestStoreError.malformedRecord }
        guard pointer.schemaVersion == 1,
              pointer.binding.work == binding.work,
              pointer.binding.workHost == binding.workHost,
              pointer.run.runID.utf8.count <= limits.maximumIdentityBytes,
              !pointer.run.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pointer.generation > 0,
              WorkLaunchDurableIO.validDigest(pointer.digest) else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        return pointer
    }

    private func publishRunManifestLocked(
        _ manifest: WorkLaunchManifest,
        expectedPrevious: WorkLaunchManifestGeneration?
    ) throws -> WorkLaunchManifestRecord {
        let expectedAuthority = try home.requirePersistedWorkHostID()
        try manifest.validate(limits: limits, expectedAuthority: expectedAuthority)
        let digest = try manifest.contentDigest()
        let binding = manifest.workRunBinding
        // A Start identity is idempotent across Run generations.  CAS on the current binding
        // alone is insufficient: a replacement with a reused client/command key could overwrite
        // the historical receipt index and make an old retry point at the newer Run.
        if let prior = try readStartPointer(
            for: binding.workBinding, intent: manifest.startIntent) {
            guard prior.identity == manifest.identity, prior.digest == digest else {
                throw WorkLaunchManifestStoreError.requestConflict
            }
        }
        let currentBinding = try readBindingPointer(for: binding.workBinding)
        if let current = try readPointer(manifest.identity) {
            if current.digest == digest {
                if let currentBinding {
                    guard currentBinding.run == manifest.identity.run,
                          currentBinding.digest == digest else {
                        throw WorkLaunchManifestStoreError.identityMismatch
                    }
                }
                try ensureBindingPointer(for: manifest, digest: digest)
                guard let payload = try WorkLaunchDurableIO.readBounded(
                    manifestURL(forDigest: digest), maximumBytes: limits.maximumRecordBytes) else {
                    throw WorkLaunchManifestStoreError.notFound
                }
                return try decodePayload(payload, identity: manifest.identity, pointer: current)
                }
                throw WorkLaunchManifestStoreError.requestConflict
            }
        if let currentBinding {
            let previous = WorkLaunchManifestGeneration(
                generation: currentBinding.generation, digest: currentBinding.digest)
            guard expectedPrevious == previous else {
                throw WorkLaunchManifestStoreError.generationMismatch
            }
        } else if expectedPrevious != nil {
            throw WorkLaunchManifestStoreError.generationMismatch
        }
        if manifest.initialInputBodyReference != nil {
            _ = try resolveInitialInputBody(for: manifest)
        }
        if manifest.systemPromptBodyReference != nil {
            _ = try resolveSystemPromptBody(for: manifest)
        }
        return try publish(
            manifest, generation: 1, expectedPrevious: expectedPrevious)
    }

    private func ensureBindingPointer(
        for manifest: WorkLaunchManifest, digest: String
    ) throws {
        let binding = manifest.workRunBinding.workBinding
        if let current = try readBindingPointer(for: binding) {
            guard current.run == manifest.identity.run, current.digest == digest else {
                throw WorkLaunchManifestStoreError.identityMismatch
            }
            return
        }
        let generation = try nextGeneration(after: 0)
        try writeBindingPointer(BindingPointer(
            schemaVersion: 1, binding: binding, run: manifest.identity.run,
            generation: generation, digest: digest))
    }

    private func encodeManifestPayload(
        _ manifest: WorkLaunchManifest, digest: String
    ) throws -> Data {
        let manifestBytes = try manifest.canonicalBytes()
        guard manifestBytes.count <= limits.maximumManifestBytes else {
            throw WorkLaunchManifestStoreError.manifestTooLarge
        }
        guard WorkLaunchDurableIO.digest(manifestBytes) == digest else {
            throw WorkLaunchManifestStoreError.digestMismatch
        }
        let envelope = Envelope(
            schemaVersion: 1, identity: manifest.identity, digest: digest,
            manifestByteCount: manifestBytes.count, manifest: manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(envelope)
        guard payload.count <= limits.maximumRecordBytes else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        return payload
    }

    private func publish(
        _ manifest: WorkLaunchManifest, generation: Int,
        expectedPrevious: WorkLaunchManifestGeneration? = nil
    ) throws -> WorkLaunchManifestRecord {
        let manifestBytes = try manifest.canonicalBytes()
        guard manifestBytes.count <= limits.maximumManifestBytes else {
            throw WorkLaunchManifestStoreError.manifestTooLarge
        }
        let digest = WorkLaunchDurableIO.digest(manifestBytes)
        let envelope = Envelope(
            schemaVersion: 1, identity: manifest.identity,
            digest: digest, manifestByteCount: manifestBytes.count, manifest: manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(envelope)
        guard payload.count <= limits.maximumRecordBytes else {
            throw WorkLaunchManifestStoreError.recordTooLarge
        }
        let payloadURL = manifestURL(forDigest: digest)
        if let existing = try WorkLaunchDurableIO.readBounded(
            payloadURL, maximumBytes: limits.maximumRecordBytes) {
            guard existing == payload else { throw WorkLaunchManifestStoreError.tamperedRecord }
        } else {
            try WorkLaunchDurableIO.writeNew(payload, to: payloadURL,
                                             maximumBytes: limits.maximumRecordBytes)
        }
        // Pending is the binding-wide admission mutex. It must precede the intent index: a
        // crash after the historical index but before pending would let another Start silently
        // supersede this unacknowledged reservation. Exact retry repairs the remaining files
        // from this pending record; historical records never move current-by-binding backwards.
        try writePendingPointer(PendingPointer(
            schemaVersion: 1, binding: manifest.workRunBinding.workBinding,
            identity: manifest.identity, digest: digest,
            expectedPrevious: expectedPrevious))
        try writeStartPointer(StartPointer(
            schemaVersion: 1,
            binding: manifest.workRunBinding.workBinding,
            intent: manifest.startIntent,
            identity: manifest.identity,
            digest: digest))
        let bindingGeneration = try nextGeneration(
            after: (try readBindingPointer(for: manifest.workRunBinding.workBinding))?.generation ?? 0)
        try writeBindingPointer(BindingPointer(
            schemaVersion: 1, binding: manifest.workRunBinding.workBinding,
            run: manifest.identity.run, generation: bindingGeneration, digest: digest))
        let pointer = Pointer(schemaVersion: 1, identity: manifest.identity,
                              generation: generation, digest: digest)
        let pointerData = try encoder.encode(pointer)
        try WorkLaunchDurableIO.replace(pointerData, at: pointerURL(for: manifest.identity),
                                        maximumBytes: limits.maximumMetadataBytes)
        // The final Run manifest and both selection indexes are now durable. The pre-assembly
        // reservation is no longer needed as a recovery fence; cleanup is best-effort because the
        // exact final record remains addressable by its intent and identity pointers.
        try? removeStartReservation(for: manifest.workRunBinding.workBinding)
        // Cleanup is not part of the publication proof. If it fails, the stale pending pointer is
        // harmless because current selection and identity are already an exact pair; a later
        // retry observes that pair and removes it through repair.
        try? removePendingPointer(for: manifest.workRunBinding.workBinding)
        return WorkLaunchManifestRecord(
            manifest: manifest,
            generation: WorkLaunchManifestGeneration(generation: generation, digest: digest),
            manifestByteCount: manifestBytes.count)
    }

    private func removeStartReservation(for binding: WorkBinding) throws {
        let url = startReservationURL(for: binding)
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw WorkLaunchManifestStoreError.ioFailure("Start reservation removal")
        }
        try WorkLaunchDurableIO.synchronizeDirectory(startReservationDirectory)
    }

    private func readPointer(
        _ identity: WorkLaunchManifestIdentity
    ) throws -> WorkLaunchManifestGeneration? {
        guard let data = try WorkLaunchDurableIO.readBounded(
            pointerURL(for: identity), maximumBytes: limits.maximumMetadataBytes) else { return nil }
        let pointer: Pointer
        do { pointer = try JSONDecoder().decode(Pointer.self, from: data) }
        catch { throw WorkLaunchManifestStoreError.malformedRecord }
        guard pointer.schemaVersion == 1, pointer.identity == identity,
              pointer.generation > 0, WorkLaunchDurableIO.validDigest(pointer.digest) else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        return WorkLaunchManifestGeneration(generation: pointer.generation, digest: pointer.digest)
    }

    private func decodeEnvelope(_ payload: Data) throws -> Envelope {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: payload) }
        catch { throw WorkLaunchManifestStoreError.malformedRecord }
        guard envelope.schemaVersion == 1,
              envelope.manifestByteCount >= 0,
              envelope.manifestByteCount <= limits.maximumManifestBytes,
              WorkLaunchDurableIO.validDigest(envelope.digest) else {
            throw WorkLaunchManifestStoreError.tamperedRecord
        }
        return envelope
    }

    private func decodePayload(
        _ payload: Data,
        identity: WorkLaunchManifestIdentity,
        pointer: WorkLaunchManifestGeneration
    ) throws -> WorkLaunchManifestRecord {
        let envelope = try decodeEnvelope(payload)
        guard envelope.identity == identity,
              envelope.digest == pointer.digest,
              envelope.manifest.identity == identity else {
            throw WorkLaunchManifestStoreError.identityMismatch
        }
        try envelope.manifest.validate(
            limits: limits, expectedAuthority: try home.requirePersistedWorkHostID())
        if envelope.manifest.initialInputBodyReference != nil {
            _ = try resolveInitialInputBody(for: envelope.manifest)
        }
        if envelope.manifest.systemPromptBodyReference != nil {
            _ = try resolveSystemPromptBody(for: envelope.manifest)
        }
        let bytes = try envelope.manifest.canonicalBytes()
        guard bytes.count == envelope.manifestByteCount else {
            throw WorkLaunchManifestStoreError.tamperedRecord
        }
        guard WorkLaunchDurableIO.digest(bytes) == envelope.digest else {
            throw WorkLaunchManifestStoreError.digestMismatch
        }
        return WorkLaunchManifestRecord(
            manifest: envelope.manifest, generation: pointer,
            manifestByteCount: envelope.manifestByteCount)
    }

    private func prepareContextBodyStorage() throws {
        let bodyRoot = ContextBodyStore(home: home).root
        let bodyDirectory = bodyRoot.appending(path: "sha256", directoryHint: .isDirectory)
        try WorkLaunchDurableIO.preparePrivateDirectory(bodyRoot)
        try WorkLaunchDurableIO.preparePrivateDirectory(bodyDirectory)
    }

    private func withPreparedStorage<T>(_ body: () throws -> T) throws -> T {
        try WorkLaunchDurableIO.preparePrivateDirectory(root)
        try WorkLaunchDurableIO.preparePrivateDirectory(payloadDirectory)
        try WorkLaunchDurableIO.preparePrivateDirectory(pointerDirectory)
        try WorkLaunchDurableIO.preparePrivateDirectory(draftPayloadDirectory)
        try WorkLaunchDurableIO.preparePrivateDirectory(requestPointerDirectory)
        try WorkLaunchDurableIO.preparePrivateDirectory(templatePayloadDirectory)
        try WorkLaunchDurableIO.preparePrivateDirectory(templatePointerDirectory)
        try WorkLaunchDurableIO.preparePrivateDirectory(bindingPointerDirectory)
        try WorkLaunchDurableIO.preparePrivateDirectory(pendingPointerDirectory)
        try WorkLaunchDurableIO.preparePrivateDirectory(startPointerDirectory)
        try WorkLaunchDurableIO.preparePrivateDirectory(startReservationDirectory)
        let lock = root.appending(path: ".lock", directoryHint: .notDirectory)
        return try WorkLaunchDurableIO.withLock(lock, body: body)
    }
}

// MARK: - Runtime adoption record store

/// A separate store for reconnect material. An adoption record is an observation and never a
/// liveness assertion; callers still need a fresh identity-checked RuntimeHost handshake.
public struct RuntimeAdoptionRecordStore: Sendable, Hashable {
    public let home: AgentHome
    public let maximumRecordBytes: Int
    public let root: URL
    public let payloadDirectory: URL
    public let pointerDirectory: URL

    public init(home: AgentHome, maximumRecordBytes: Int = 32 * 1024) {
        self.home = home
        self.maximumRecordBytes = max(1, min(maximumRecordBytes, 4 * 1024 * 1024))
        self.root = home.root.appending(path: "runtime-adoption-records", directoryHint: .isDirectory)
        self.payloadDirectory = root.appending(path: "sha256", directoryHint: .isDirectory)
        self.pointerDirectory = root.appending(path: "current", directoryHint: .isDirectory)
    }

    public func recordURL(forDigest digest: String) -> URL {
        payloadDirectory.appending(path: WorkLaunchDurableIO.digestPathComponent(digest) + ".json",
                                    directoryHint: .notDirectory)
    }

    public func pointerURL(for record: RuntimeAdoptionRecord) -> URL {
        pointerDirectory.appending(
            path: WorkLaunchDurableIO.identityDigest(Self.addressMaterial(for: record)) + ".json",
            directoryHint: .notDirectory)
    }

    public func pointerURL(
        work: WorkRef, session: SessionRef, run: RunRef
    ) -> URL {
        pointerDirectory.appending(
            path: WorkLaunchDurableIO.identityDigest(Self.addressMaterial(
                for: IdentityKey(work: work, session: session, run: run))) + ".json",
            directoryHint: .notDirectory)
    }

    public func put(_ record: RuntimeAdoptionRecord) throws -> RuntimeAdoptionRecordResult {
        try save(record)
    }

    public func save(_ record: RuntimeAdoptionRecord) throws -> RuntimeAdoptionRecordResult {
        try withPreparedStorage {
            try validate(record)
            let existing = try readPointer(for: record)
            let prior = existing?.generation ?? 0
            let addition = prior.addingReportingOverflow(1)
            guard !addition.overflow, addition.partialValue > 0 else {
                throw RuntimeAdoptionRecordStoreError.invalidGeneration
            }
            let generation = addition.partialValue
            return try publish(record, generation: generation)
        }
    }

    public func replace(
        _ record: RuntimeAdoptionRecord, expected: RuntimeAdoptionRecordGeneration
    ) throws -> RuntimeAdoptionRecordResult {
        try withPreparedStorage {
            try validate(record)
            guard let current = try readPointer(for: record), current == expected else {
                throw RuntimeAdoptionRecordStoreError.generationMismatch
            }
            let addition = expected.generation.addingReportingOverflow(1)
            guard !addition.overflow, addition.partialValue > expected.generation else {
                throw RuntimeAdoptionRecordStoreError.invalidGeneration
            }
            let next = addition.partialValue
            return try publish(record, generation: next)
        }
    }

    public func read(
        work: WorkRef, session: SessionRef, run: RunRef
    ) throws -> RuntimeAdoptionRecordResult? {
        try withPreparedStorage {
            let expectedAuthority = try home.requirePersistedWorkHostID()
            guard work.workHostID == expectedAuthority else {
                throw RuntimeAdoptionRecordStoreError.wrongAuthority(
                    expected: expectedAuthority, actual: work.workHostID)
            }
            let key = IdentityKey(work: work, session: session, run: run)
            guard let pointer = try readPointer(for: key) else { return nil }
            guard let payload = try WorkLaunchDurableIO.readBounded(
                recordURL(forDigest: pointer.digest), maximumBytes: maximumRecordBytes)
            else { throw RuntimeAdoptionRecordStoreError.notFound }
            return try decodePayload(payload, key: key, pointer: pointer)
        }
    }

    public func load(recordDigest digest: String) throws -> RuntimeAdoptionRecordResult {
        try withPreparedStorage {
            guard WorkLaunchDurableIO.validDigest(digest) else {
                throw RuntimeAdoptionRecordStoreError.digestMismatch
            }
            guard let payload = try WorkLaunchDurableIO.readBounded(
                recordURL(forDigest: digest), maximumBytes: maximumRecordBytes)
            else { throw RuntimeAdoptionRecordStoreError.notFound }
            let envelope = try decodeEnvelope(payload)
            guard envelope.digest == digest else {
                throw RuntimeAdoptionRecordStoreError.digestMismatch
            }
            let key = IdentityKey(work: envelope.record.work,
                                  session: envelope.record.session, run: envelope.record.run)
            return try decodePayload(
                payload, key: key,
                pointer: RuntimeAdoptionRecordGeneration(
                    generation: 0, digest: envelope.digest))
        }
    }

    public func remove(
        work: WorkRef, session: SessionRef, run: RunRef,
        expected: RuntimeAdoptionRecordGeneration
    ) throws {
        try withPreparedStorage {
            let expectedAuthority = try home.requirePersistedWorkHostID()
            guard work.workHostID == expectedAuthority else {
                throw RuntimeAdoptionRecordStoreError.wrongAuthority(
                    expected: expectedAuthority, actual: work.workHostID)
            }
            let key = IdentityKey(work: work, session: session, run: run)
            guard let current = try readPointer(for: key), current == expected else {
                throw RuntimeAdoptionRecordStoreError.generationMismatch
            }
            let pointer = pointerURL(work: work, session: session, run: run)
            guard unlink(pointer.path) == 0 || errno == ENOENT else {
                throw RuntimeAdoptionRecordStoreError.ioFailure("removal")
            }
            try WorkLaunchDurableIO.synchronizeDirectory(pointerDirectory)
        }
    }

    public func remove(_ result: RuntimeAdoptionRecordResult) throws {
        try remove(
            work: result.record.work, session: result.record.session, run: result.record.run,
            expected: result.generation)
    }

    private struct IdentityKey: Hashable {
        let work: WorkRef
        let session: SessionRef
        let run: RunRef
    }

    private struct Pointer: Codable, Hashable {
        let schemaVersion: Int
        let work: WorkRef
        let session: SessionRef
        let run: RunRef
        let generation: Int
        let digest: String
    }

    private struct Envelope: Codable, Hashable {
        let schemaVersion: Int
        let work: WorkRef
        let session: SessionRef
        let run: RunRef
        let digest: String
        let recordByteCount: Int
        let record: RuntimeAdoptionRecord
    }

    private static func addressMaterial(for record: RuntimeAdoptionRecord) -> String {
        addressMaterial(for: IdentityKey(work: record.work, session: record.session, run: record.run))
    }

    private static func addressMaterial(for key: IdentityKey) -> String {
        [key.work.workHostID, key.work.workID, key.session.sessionID, key.run.runID]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "\u{0}")
    }

    private func validate(_ record: RuntimeAdoptionRecord) throws {
        let expectedHost = try home.requirePersistedWorkHostID()
        guard record.schemaVersion == RuntimeAdoptionRecord.currentSchemaVersion else {
            throw RuntimeAdoptionRecordStoreError.invalidRecord("unsupported schema")
        }
        guard record.work.workHostID == expectedHost else {
            throw RuntimeAdoptionRecordStoreError.wrongAuthority(
                expected: expectedHost, actual: record.work.workHostID)
        }
        let values = [record.work.workHostID, record.work.workID,
                      record.session.sessionID, record.run.runID,
                      record.descriptor.identity.hostID, record.descriptor.identity.instanceID]
        guard values.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512
                && !$0.unicodeScalars.contains(where: { $0.value == 0 })
        }) else { throw RuntimeAdoptionRecordStoreError.invalidRecord("identity") }
        guard record.descriptor.identity.hostID == record.work.workHostID,
              record.descriptor.protocolVersion == RuntimeHost.protocolVersion else {
            throw RuntimeAdoptionRecordStoreError.identityMismatch
        }
        let endpoint = record.descriptor.endpoint.path
        guard endpoint.hasPrefix("/"), endpoint.utf8.count <= 103,
              !endpoint.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RuntimeAdoptionRecordStoreError.invalidRecord("endpoint")
        }
        guard record.sourceCursor.journal == record.sourceEvent.journal,
              record.sourceCursor.eventID == record.sourceEvent.eventID,
              record.sourceCursor.sequence >= 0 else {
            throw RuntimeAdoptionRecordStoreError.invalidRecord("source cursor")
        }
        let sourceMatches: Bool
        switch record.sourceEvent.journal.owner {
        case .work(let work): sourceMatches = work == record.work
        case .session(let session): sourceMatches = session == record.session
        case .workHost(let host): sourceMatches = host.workHostID == record.work.workHostID
        }
        guard sourceMatches else { throw RuntimeAdoptionRecordStoreError.identityMismatch }
    }

    private func publish(
        _ record: RuntimeAdoptionRecord, generation: Int
    ) throws -> RuntimeAdoptionRecordResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let recordBytes = try Self.canonicalBytes(for: record)
        guard recordBytes.count <= maximumRecordBytes else {
            throw RuntimeAdoptionRecordStoreError.recordTooLarge
        }
        let digest = WorkLaunchDurableIO.digest(recordBytes)
        let envelope = Envelope(
            schemaVersion: 1, work: record.work, session: record.session, run: record.run,
            digest: digest, recordByteCount: recordBytes.count, record: record)
        let payload = try encoder.encode(envelope)
        guard payload.count <= maximumRecordBytes else {
            throw RuntimeAdoptionRecordStoreError.recordTooLarge
        }
        let payloadURL = recordURL(forDigest: digest)
        if let existing = try WorkLaunchDurableIO.readBounded(
            payloadURL, maximumBytes: maximumRecordBytes) {
            guard existing == payload else {
                throw RuntimeAdoptionRecordStoreError.tamperedRecord
            }
        } else {
            do {
                try WorkLaunchDurableIO.writeNew(
                    payload, to: payloadURL, maximumBytes: maximumRecordBytes)
            } catch WorkLaunchManifestStoreError.recordTooLarge {
                throw RuntimeAdoptionRecordStoreError.recordTooLarge
            } catch {
                throw RuntimeAdoptionRecordStoreError.ioFailure("payload publication")
            }
        }
        let pointer = Pointer(schemaVersion: 1, work: record.work, session: record.session,
                              run: record.run, generation: generation, digest: digest)
        do {
            try WorkLaunchDurableIO.replace(
                encoder.encode(pointer), at: pointerURL(for: record), maximumBytes: 8 * 1024)
        } catch {
            throw RuntimeAdoptionRecordStoreError.ioFailure("pointer publication")
        }
        return RuntimeAdoptionRecordResult(
            record: record,
            generation: RuntimeAdoptionRecordGeneration(generation: generation, digest: digest),
            recordByteCount: recordBytes.count)
    }

    private func readPointer(for record: RuntimeAdoptionRecord) throws
        -> RuntimeAdoptionRecordGeneration?
    {
        try readPointer(for: IdentityKey(work: record.work, session: record.session, run: record.run))
    }

    private func readPointer(for key: IdentityKey) throws
        -> RuntimeAdoptionRecordGeneration?
    {
        let pointer = pointerURL(work: key.work, session: key.session, run: key.run)
        guard let data = try WorkLaunchDurableIO.readBounded(pointer, maximumBytes: 8 * 1024) else {
            return nil
        }
        let decoded: Pointer
        do { decoded = try JSONDecoder().decode(Pointer.self, from: data) }
        catch { throw RuntimeAdoptionRecordStoreError.malformedRecord }
        guard decoded.schemaVersion == 1,
              decoded.work == key.work, decoded.session == key.session, decoded.run == key.run,
              decoded.generation > 0, WorkLaunchDurableIO.validDigest(decoded.digest) else {
            throw RuntimeAdoptionRecordStoreError.identityMismatch
        }
        return RuntimeAdoptionRecordGeneration(generation: decoded.generation, digest: decoded.digest)
    }

    private func decodeEnvelope(_ payload: Data) throws -> Envelope {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: payload) }
        catch { throw RuntimeAdoptionRecordStoreError.malformedRecord }
        guard envelope.schemaVersion == 1,
              envelope.recordByteCount >= 0,
              envelope.recordByteCount <= maximumRecordBytes,
              WorkLaunchDurableIO.validDigest(envelope.digest) else {
            throw RuntimeAdoptionRecordStoreError.tamperedRecord
        }
        return envelope
    }

    private func decodePayload(
        _ payload: Data, key: IdentityKey, pointer: RuntimeAdoptionRecordGeneration
    ) throws -> RuntimeAdoptionRecordResult {
        let envelope = try decodeEnvelope(payload)
        guard envelope.work == key.work, envelope.session == key.session,
              envelope.run == key.run, envelope.record.work == key.work,
              envelope.record.session == key.session, envelope.record.run == key.run,
              envelope.digest == pointer.digest else {
            throw RuntimeAdoptionRecordStoreError.identityMismatch
        }
        try validate(envelope.record)
        let bytes = try Self.canonicalBytes(for: envelope.record)
        guard bytes.count == envelope.recordByteCount else {
            throw RuntimeAdoptionRecordStoreError.tamperedRecord
        }
        guard WorkLaunchDurableIO.digest(bytes) == envelope.digest else {
            throw RuntimeAdoptionRecordStoreError.digestMismatch
        }
        return RuntimeAdoptionRecordResult(
            record: envelope.record, generation: pointer,
            recordByteCount: envelope.recordByteCount)
    }

    private func withPreparedStorage<T>(_ body: () throws -> T) throws -> T {
        try WorkLaunchDurableIO.preparePrivateDirectory(root)
        try WorkLaunchDurableIO.preparePrivateDirectory(payloadDirectory)
        try WorkLaunchDurableIO.preparePrivateDirectory(pointerDirectory)
        let lock = root.appending(path: ".lock", directoryHint: .notDirectory)
        do { return try WorkLaunchDurableIO.withLock(lock, body: body) }
        catch let error as RuntimeAdoptionRecordStoreError { throw error }
        catch let error as WorkLaunchManifestStoreError {
            throw RuntimeAdoptionRecordStoreError.ioFailure(error.localizedDescription)
        }
    }

    private static func canonicalBytes(for record: RuntimeAdoptionRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }
}
