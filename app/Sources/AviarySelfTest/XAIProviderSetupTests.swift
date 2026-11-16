import Foundation
@testable import AviaryCore

let casesXAIProviderSetup: [(String, () async throws -> Void)] = [
    ("provider setup: test cannot route credentials through a model override", {
        let provider = ProviderSpec(id: "fixture", baseURL: nil, api: "xai-responses",
            apiKeyExpression: "fixture", headers: [:], models: [])
        let model = ModelSpec(id: "grok-fixture", providerID: "fixture", json: .object([
            "baseUrl": "https://model-override.invalid/v1", "api": "openai-completions"
        ]), provider: .object([:]))
        let result = await ProviderTester.test(provider: provider, model: model)
        XCTAssertFalse(result.ok)
        XCTAssertNil(result.httpStatus)
        XCTAssertTrue(result.detail.contains("No baseUrl configured"))
    }),
    ("provider setup: Grok keeps references and unrelated config", {
        let raw: JSONValue = .object(["custom": 42, "providers": .object([
            "other": .object(["apiKey": "OTHER_KEY", "quirk": true])])])
        let next = try XAIProviderSetup.configuration(raw, modelID: "grok-4.7", secretName: "grok")
        XCTAssertEqual(next["custom"], raw["custom"])
        XCTAssertEqual(next.path("providers.other"), raw.path("providers.other"))
        XCTAssertEqual(next.path("providers.xai.apiKey")?.stringValue, "@secret:grok")
        XCTAssertEqual(next.path("providers.xai.api")?.stringValue, "xai-responses")
        XCTAssertNil(next.path("providers.xai.models.0.cost"))
        let again = try XAIProviderSetup.configuration(next, modelID: "grok-4.7", secretName: "grok2")
        XCTAssertEqual(again.path("providers.xai.models")?.arrayValue?.count, 1)
        XCTAssertEqual(again.path("providers.xai.apiKey")?.stringValue, "@secret:grok2")
    }),
    ("provider setup: Grok refuses malformed and conflicting config", {
        for raw: JSONValue in [.null, .object(["providers": true]), .object([
            "providers": .object(["xai": .object(["baseUrl": "https://other.example"])])])] {
            do {
                _ = try XAIProviderSetup.configuration(raw, modelID: "grok-4.7", secretName: "grok")
                XCTFail("invalid existing config was overwritten")
            } catch { }
        }
        do {
            _ = try XAIProviderSetup.configuration(.object([:]), modelID: "grok\nsecret", secretName: "grok")
            XCTFail("invalid model accepted")
        } catch { }
        XCTAssertTrue(true)
    }),
    ("provider setup: Grok saves with backup", {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ag-\(UUID().uuidString)")
        let home = AgentHome(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try XAIProviderSetup.save(home: home, modelID: "grok-4.7", secretName: "grok")
        let first = try Data(contentsOf: home.modelsFile)
        try XAIProviderSetup.save(home: home, modelID: "grok-4.7", secretName: "grok2")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("models.json.aviary-bak-") })
        XCTAssertEqual(try Data(contentsOf: backup), first)
        XCTAssertEqual(ModelsConfig.load(home: home).providers.first?.apiKeyExpression, "@secret:grok2")
    }),
]
