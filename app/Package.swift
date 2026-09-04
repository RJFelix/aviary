// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
// The daemon is intentionally a bounded Work Host product on Linux.  The macOS target keeps
// the complete reader/UI surface; Linux does not compile Apple-only image, MCP bridge, OAuth
// loopback, trash, or relative-date code merely because it happens to live beside the daemon.
let packagePlatforms: [SupportedPlatform]? = nil
let linuxCoreSources: [String] = [
    "AgentTree.swift",
    "AviaryPlatform.swift",
    "AviaryFormatting.swift",
    "Agent.swift",
    "AgentHome.swift",
    "AgentRunner.swift",
    "AnthropicProvider.swift",
    "Artifacts.swift",
    "BuiltInProviders.swift",
    "Builtins.swift",
    "ChatModel.swift",
    "CanonicalAttentionInbox.swift",
    "CanonicalNotifications.swift",
    "CanonicalSessionCatalog.swift",
    "CanonicalWorkRecoveryProjection.swift",
    "ContextManifest.swift",
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
    "LocalWorkHostLaunchResolver.swift",
    "Memory.swift",
    "ModelCatalog.swift",
    "NativeColdResume.swift",
    "NativeSessionCommandJournal.swift",
    "Providers.swift",
    "RunConfiguration.swift",
    "RunJournalBundle.swift",
    "RuntimeHost.swift",
    "SessionCommandController.swift",
    "SessionResume.swift",
    "SessionWriter.swift",
    "Shell.swift",
    "SessionAssembler.swift",
    "ServiceBackedCreateIntentStore.swift",
    "ServiceBackedStartIntentStore.swift",
    "SkillGate.swift",
    "SubAgents.swift",
    "SystemPromptAssembly.swift",
    "TimelineEvent.swift",
    "TimelineJournalWriter.swift",
    "TimelineReducers.swift",
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
    "AviaryPlatformTests.swift",
    "Harness.swift",
    "WorkHostDaemonEndpointTests.swift",
    "WorkHostDaemonProcessTests.swift",
    "WorkHostWorkspaceRegistryTests.swift",
    "WorkLaunchManifestTests.swift",
    "WorkServiceTests.swift",
    "WorkServiceTransportTests.swift",
    "ShellTests.swift",
    "ServiceBackedIntentStoreTests.swift",
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
    targets: [
        .target(
            name: "AviaryCore",
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
