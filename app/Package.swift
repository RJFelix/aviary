// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
// The daemon is intentionally a bounded Work Host product on Linux.  The macOS target keeps
// the complete reader/UI surface; Linux does not compile Apple-only image, MCP bridge, OAuth
// loopback, trash, or relative-date code merely because it happens to live beside the daemon.
let packagePlatforms: [SupportedPlatform]? = nil
let linuxCoreSources: [String] = [
    "AttachmentQualifiedIdentity.swift",
    "AviaryTelemetry.swift",
    "AviaryBoundedSpanProcessor.swift",
    "AviaryProviderTelemetry.swift",
    "AviaryTelemetryHTTPClient.swift",
    "AgentTree.swift",
    "AviaryPlatform.swift",
    "AviaryFormatting.swift",
    "Agent.swift",
    "AgentHome.swift",
    "AgentRunner.swift",
    "AgentChildExecutionResource.swift",
    "WorkAgentChildAdmissionQueue.swift",
    "WorkAgentHandleJournal.swift",
    "WorkAgentChildCoordinator.swift",
    "WorkAgentChildPilot.swift",
    "AnthropicProvider.swift",
    "Artifacts.swift",
    "BoundedTimelineReducerProjection.swift",
    "BuiltInProviders.swift",
    "Builtins.swift",
    "ChatModel.swift",
    "CanonicalAttentionInbox.swift",
    "CanonicalInputDeliveryProjection.swift",
    "CanonicalNotifications.swift",
    "CanonicalSessionCatalog.swift",
    "CanonicalWorkRecoveryProjection.swift",
    "ContextManifest.swift",
    "DisposableTimelineProjectionStore.swift",
    "Goals.swift",
    "HostedInHouseWork.swift",
    "InHouseModelResolver.swift",
    "InHouseWorkFactory.swift",
    "JSONValue.swift",
    "JournalBackedWorkService.swift",
    "Library.swift",
    "LinuxSessionSummary.swift",
    "LineFramer.swift",
    "LocalTimelineCatalog.swift",
    "LocalTimelineProjectionReader.swift",
    "LocalTimelineProjectionSource.swift",
    "LocalSessionHistoryProjectionReader.swift",
    "LocalWorkHostLaunchResolver.swift",
    "Memory.swift",
    "ModelCatalog.swift",
    "NativeColdResume.swift",
    "NativeSessionCommandJournal.swift",
    "ObservedRepositoryReview.swift",
    "PersistentProjectionRadixMap.swift",
    "PersistentSessionHistoryIndex.swift",
    "PersistentSessionExactState.swift",
    "PersistentWorkExactState.swift",
    "Providers.swift",
    "RecordedModelContextProjection.swift",
    "RunConfiguration.swift",
    "RunJournalBundle.swift",
    "RuntimeHost.swift",
    "SessionCommandController.swift",
    "SessionResume.swift",
    "SessionWriter.swift",
    "Shell.swift",
    "SessionAssembler.swift",
    "ServiceBackedCreateIntentStore.swift",
    "ServiceBackedCreateSessionIntentStore.swift",
    "ServiceBackedDraftStore.swift",
    "ServiceBackedGUIOrchestration.swift",
    "ServiceBackedGUIControlPolicy.swift",
    "ServiceBackedRefreshSchedulingPolicy.swift",
    "RepositoryReviewDiffProjection.swift",
    "ChatInteractionPresentation.swift",
    "ServiceBackedCommandNoticePolicy.swift",
    "ServiceBackedControlResultPolicy.swift",
    "ServiceBackedStartIntentStore.swift",
    "SkillGate.swift",
    "SubAgents.swift",
    "SystemPromptAssembly.swift",
    "TimelineEvent.swift",
    "TimelineJournalWriter.swift",
    "TimelineReducers.swift",
    "TimelineReducerTransitions.swift",
    "TimelineSessionReducerTransitions.swift",
    "Transcript.swift",
    "WebSearch.swift",
    "WorkHostControlJournal.swift",
    "WorkHostDaemonCoordinator.swift",
    "WorkHostDaemonEndpoint.swift",
    "WorkHostDaemonRuntime.swift",
    "WorkHostRegistry.swift",
    "WorkHostWorkspaceRegistry.swift",
    "WorkLaunchManifest.swift",
    "WorkService.swift",
    "WorkServiceAttachedWorkController.swift",
    "WorkActionPresentation.swift",
    "ChatActivityPresentation.swift",
    "WorkServiceAttachedWorkCheckpointStore.swift",
    "WorkServiceAttachedWorkIntentStore.swift",
    "WorkServiceCatalog.swift",
    "WorkServiceClientIdentity.swift",
    "WorkServiceClientSession.swift",
    "WorkServiceHostLocator.swift",
    "WorkServiceTransport.swift",
    "WireLog.swift",
]
let linuxSelfTestSources: [String] = [
    "AviaryTelemetryTests.swift",
    "AviaryTelemetryAgentTests.swift",
    "AviaryTelemetryContextTests.swift",
    "AviaryTelemetryDrainTests.swift",
    "AviaryTelemetryRepositoryReviewTests.swift",
    "AviaryTelemetryTransportTests.swift",
    "AviaryTelemetryHTTPClientTests.swift",
    "AviaryTelemetryDeliveryTests.swift",
    "HostedDeferredDeliveryTelemetryTests.swift",
    "JournalBackedSnapshotCoherenceTests.swift",
    "RuntimeHostTelemetryTests.swift",
    "WorkAgentChildTelemetryTests.swift",
    "AttachmentQualifiedIdentityTests.swift",
    "AviaryDigestFormattingTests.swift",
    "AviaryPlatformTests.swift",
    "BoundedTimelineReducerProjectionTests.swift",
    "DisposableTimelineProjectionStoreTests.swift",
    "Harness.swift",
    "LocalTimelineProjectionReaderTests.swift",
    "LocalTimelineProjectionSourceTests.swift",
    "LocalSessionHistoryProjectionReaderTests.swift",
    "ObservedRepositoryReviewAgentTests.swift",
    "ObservedRepositoryReviewTests.swift",
    "PersistentProjectionRadixMapTests.swift",
    "PersistentSessionHistoryIndexTests.swift",
    "PersistentSessionExactStateTests.swift",
    "PersistentWorkExactStateTests.swift",
    "RecordedModelContextProjectionTests.swift",
    "WorkHostDaemonEndpointTests.swift",
    "WorkHostDaemonProcessTests.swift",
    "WorkHostWorkspaceRegistryTests.swift",
    "WorkLaunchManifestTests.swift",
    "WorkReducerTransitionTests.swift",
    "WorkServiceTests.swift",
    "WorkActionPresentationTests.swift",
    "ChatActivityPresentationTests.swift",
    "WorkServiceCreateSessionTests.swift",
    "WorkServiceTransportTests.swift",
    "ShellTests.swift",
    "SessionReducerTransitionTests.swift",
    "ServiceBackedIntentStoreTests.swift",
    "ServiceBackedDraftStoreTests.swift",
    "ServiceBackedGUIOrchestrationTests.swift",
    "ServiceBackedGUIControlPolicyTests.swift",
    "ServiceBackedRefreshSchedulingPolicyTests.swift",
    "RepositoryReviewDiffProjectionTests.swift",
    "ChatInteractionPresentationTests.swift",
    "ServiceBackedCommandNoticePolicyTests.swift",
    "ServiceBackedControlResultPolicyTests.swift",
    "LinuxSelfTestMain.swift",
]
#else
let packagePlatforms: [SupportedPlatform]? = [.macOS(.v15)]
let linuxCoreSources: [String]? = nil
let linuxSelfTestSources: [String]? = nil
#endif

#if os(macOS)
let guiProducts: [Product] = [
    .executable(name: "Aviary", targets: ["Aviary"]),
]
let guiTargets: [Target] = [
    .executableTarget(
        name: "Aviary",
        dependencies: ["AviaryCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
let macTransportProbeProducts: [Product] = [
    .executable(name: "AviaryMacTransportProbe", targets: ["AviaryMacTransportProbe"]),
]
let macTransportProbeTargets: [Target] = [
    .executableTarget(
        name: "AviaryMacTransportProbe",
        dependencies: ["AviaryCore"],
        path: "Sources/AviaryMacTransportProbe",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
#else
let guiProducts: [Product] = []
let guiTargets: [Target] = []
let macTransportProbeProducts: [Product] = []
let macTransportProbeTargets: [Target] = []
#endif

let package = Package(
    name: "Aviary",
    platforms: packagePlatforms,
    products: [
        .executable(name: "aviaryd", targets: ["aviaryd"]),
        .executable(name: "AviarySelfTest", targets: ["AviarySelfTest"]),
        .library(name: "AviaryCore", targets: ["AviaryCore"]),
    ] + guiProducts + macTransportProbeProducts,
    dependencies: [
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", exact: "2.5.1"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", exact: "2.5.1"),
    ],
    targets: [
        .target(
            name: "AviaryCore",
            dependencies: [
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
            ],
            sources: linuxCoreSources,
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "aviaryd",
            dependencies: ["AviaryCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Not a `.testTarget`: this machine's toolchain is Command Line Tools only,
        // which ships neither XCTest nor swift-testing. Running the suite as an
        // executable keeps it usable everywhere. See Sources/AviarySelfTest/Harness.swift.
        .executableTarget(
            name: "AviarySelfTest",
            dependencies: ["AviaryCore"],
            sources: linuxSelfTestSources,
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ] + guiTargets + macTransportProbeTargets
)
