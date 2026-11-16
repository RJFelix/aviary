import Foundation
@testable import AviaryCore

func test_launcherMuseRouteNeverFallsThroughToDirect() {
    let models = [
        ("direct", "one"), ("direct", "two"), ("claude-code", "sonnet"),
        ("muse-code", "muse-spark-1.2"), ("muse-code", "another-muse"),
    ].map { provider, model in
        ModelSpec(rpc: .object(["provider": .string(provider), "id": .string(model)]))
    }
    var selection = LauncherSelection.seeded(route: .direct,
        defaultProviderID: "direct", defaultModelID: "one",
        claudeCodeModelID: "sonnet", models: models)
    selection = selection.selectingModel("two", models: models)
    selection = selection.selectingProvider("muse-code", defaultProviderID: "direct",
        defaultModelID: "one", fallbackClaudeCodeModelID: "sonnet", models: models)
    XCTAssertEqual(selection.route, .museCode)
    XCTAssertEqual(selection.modelID, "muse-spark-1.2")
    selection = selection.selectingModel("another-muse", models: models)
    selection = selection.reconciling(defaultProviderID: "direct", defaultModelID: "one",
        fallbackClaudeCodeModelID: "sonnet", models: models.filter { $0.providerID != "muse-code" })
    XCTAssertEqual(selection.route, .museCode)
    XCTAssertTrue(selection.providerID.isEmpty)
    XCTAssertTrue(selection.modelID.isEmpty)
    selection = selection.reconciling(defaultProviderID: "direct", defaultModelID: "one",
        fallbackClaudeCodeModelID: "sonnet", models: models)
    XCTAssertEqual(selection.modelID, "another-muse")
    for route: LauncherSelection.Route in [.claudeCode, .direct, .museCode] {
        selection = selection.selectingRoute(route, defaultProviderID: "direct",
            defaultModelID: "one", fallbackClaudeCodeModelID: "sonnet", models: models)
        XCTAssertEqual(selection.route, route)
        XCTAssertEqual(selection.modelID, route == .direct ? "two" : route == .claudeCode ? "sonnet" : "another-muse")
    }
    XCTAssertEqual(LauncherSelection.provider(route: .direct, preferred: "muse-code",
        fallback: "claude-code", providers: ["muse-code", "claude-code"]), "")
}

func test_museCatalogPreservesPreferencesAndRejectsForeignRows() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-catalog-\(UUID())")
    let config = ModelsConfig.load(home: AgentHome(root: root))
    let muse = MuseCode.modelSpec(for: "muse-spark-1.2")
    let foreign = ModelSpec(rpc: .object(["provider": .string("meta"), "id": .string("foreign")]))
    var preferences = ModelPreferences()
    preferences.setEnabled(false, for: muse)
    let catalog = ModelCatalogBuilder.build(config: config, auth: nil,
        credentialed: ["muse-code"], preferences: preferences, museModels: [muse, muse, foreign])
    XCTAssertEqual(catalog.models.count, 1)
    XCTAssertEqual(catalog.models.first?.qualifiedID, "muse-code/muse-spark-1.2")
    XCTAssertTrue(catalog.enabled.isEmpty)
    XCTAssertEqual(catalog.reachable.first?.api, "muse-msp")
    let unavailable = ModelCatalogBuilder.build(config: config, auth: nil,
        credentialed: [], preferences: .init(), museModels: [muse])
    XCTAssertTrue(unavailable.enabled.isEmpty)
    XCTAssertTrue(unavailable.unreachable.contains { $0.id == "muse-code" })
}
