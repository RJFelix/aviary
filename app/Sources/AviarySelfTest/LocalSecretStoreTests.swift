import Foundation
@testable import AviaryCore

private struct MetadataOnlySecretBackend: LocalSecretStoreBackend {
    func list(namespace: String) throws -> [LocalSecretMetadata] {
        [.init(name: "grok", allowedProviderID: "xai", allowedOrigin: "https://api.example.test")]
    }
    func read(namespace: String, name: String) throws -> LocalSecretBackendRecord? {
        throw LocalSecretStoreError.backendUnavailable
    }
    func insert(namespace: String, name: String, value: Data, metadata: LocalSecretMetadata) throws {
        throw LocalSecretStoreError.backendUnavailable
    }
    func update(namespace: String, name: String, value: Data, metadata: LocalSecretMetadata) throws {
        throw LocalSecretStoreError.backendUnavailable
    }
    func remove(namespace: String, name: String) throws { throw LocalSecretStoreError.backendUnavailable }
}

private func localSecretTestHome() -> AgentHome {
    AgentHome(root: FileManager.default.temporaryDirectory.appending(
        path: "aviary-local-secrets-\(UUID().uuidString)", directoryHint: .isDirectory))
}

private func localSecretTestProvider(
    key: String = "@secret:grok"
) -> ProviderSpec {
    let providerJSON: JSONValue = .object([
        "api": .string("xai-responses"),
        "baseUrl": .string("https://api.example.test/v1"),
    ])
    var provider = ProviderSpec(
        id: "xai",
        name: "Test provider",
        baseURL: "https://api.example.test/v1",
        api: "xai-responses",
        apiKeyExpression: key,
        authHeader: nil,
        headers: [:],
        models: [])
    provider.models = [ModelSpec(
        id: "grok-test",
        providerID: "xai",
        json: .object(["id": .string("grok-test")]),
        provider: providerJSON)]
    return provider
}

func test_localSecretStoreRoundTripsMetadataOnly() throws {
    let home = localSecretTestHome()
    let backend = InMemoryLocalSecretStoreBackend()
    let store = LocalSecretStore(home: home, backend: backend)
    defer { try? FileManager.default.removeItem(at: home.root) }

    try store.save(
        name: "grok",
        value: "sentinel-local-secret-value",
        allowedProviderID: "xai",
        allowedOrigin: "https://API.EXAMPLE.TEST/v1")
    let metadata = try store.list()
    XCTAssertEqual(metadata, [LocalSecretMetadata(
        name: "grok", allowedProviderID: "xai", allowedOrigin: "https://api.example.test")])
    let encoded = String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? ""
    XCTAssertFalse(encoded.contains("sentinel-local-secret-value"))

    XCTAssertEqual(
        try store.resolve(
            name: "grok", providerID: "xai", origin: "https://api.example.test/v1"),
        "sentinel-local-secret-value")
    try store.replace(
        name: "grok",
        value: "rotated-local-secret-value",
        allowedProviderID: "xai",
        allowedOrigin: "https://api.example.test")
    XCTAssertEqual(
        try store.resolve(
            name: "grok", providerID: "xai", origin: "https://api.example.test"),
        "rotated-local-secret-value")
    do {
        try store.save(
            name: "grok", value: "another", allowedProviderID: "xai",
            allowedOrigin: "https://api.example.test")
        XCTFail("saving an existing name must fail")
    } catch let error as LocalSecretStoreError {
        XCTAssertEqual(error, .alreadyExists)
    } catch {
        XCTFail("unexpected save error: \(error)")
    }
    try store.remove(name: "grok")
    XCTAssertTrue(try store.list().isEmpty)

    for invalid in ["bad\rvalue", "bad\nvalue", "bad\u{0}value", " leading-space", "trailing-space "] {
        do {
            try store.save(
                name: "invalid", value: invalid, allowedProviderID: "xai",
                allowedOrigin: "https://api.example.test")
            XCTFail("control/outer-whitespace credential must be rejected")
        } catch let error as LocalSecretStoreError {
            XCTAssertEqual(error, .invalidValue)
        } catch {
            XCTFail("unexpected invalid-value error: \(error)")
        }
    }
}

func test_localSecretStoreScopesProviderAndOriginFailClosed() async throws {
    for expression in ["@secret", "@secret(foo)", "@secret missing-colon"] {
        guard case .secretReference("") = ApiKeyForm.classify(expression) else {
            XCTFail("malformed secure reference \(expression) must not become a literal")
            return
        }
    }
    let home = localSecretTestHome()
    let store = LocalSecretStore(home: home, backend: InMemoryLocalSecretStoreBackend())
    defer { try? FileManager.default.removeItem(at: home.root) }
    try store.save(
        name: "grok", value: "sentinel-scope-secret", allowedProviderID: "xai",
        allowedOrigin: "https://api.example.test/v1")

    do {
        _ = try store.resolve(
            name: "grok", providerID: "other", origin: "https://api.example.test")
        XCTFail("a different provider must not resolve the credential")
    } catch let error as LocalSecretStoreError {
        XCTAssertEqual(error, .providerNotPermitted)
        XCTAssertFalse(String(describing: error).contains("sentinel-scope-secret"))
    } catch {
        XCTFail("unexpected provider scope error: \(error)")
    }
    do {
        _ = try store.resolve(
            name: "grok", providerID: "xai", origin: "https://evil.example.test")
        XCTFail("a different origin must not resolve the credential")
    } catch let error as LocalSecretStoreError {
        XCTAssertEqual(error, .originNotPermitted)
        XCTAssertFalse(String(describing: error).contains("sentinel-scope-secret"))
    } catch {
        XCTFail("unexpected origin scope error: \(error)")
    }
    do {
        _ = try store.resolve(
            name: "missing", providerID: "xai", origin: "https://api.example.test")
        XCTFail("a missing name must not resolve")
    } catch let error as LocalSecretStoreError {
        XCTAssertEqual(error, .missing)
    } catch {
        XCTFail("unexpected missing secret error: \(error)")
    }

    let invalid = await ApiKeyResolver.resolve(
        "@secret:", home: home, providerID: "xai", origin: "https://api.example.test",
        secretStore: store)
    guard case .secretReferenceInvalid = invalid.outcome else {
        XCTFail("an empty secret name must fail closed")
        return
    }
    XCTAssertFalse(invalid.explanation.contains("sentinel-scope-secret"))
    let unavailable = await ApiKeyResolver.resolve(
        "@secret:missing", home: home, providerID: "xai",
        origin: "https://api.example.test", secretStore: store)
    guard case .secretReferenceUnavailable = unavailable.outcome else {
        XCTFail("a missing secret name must fail closed")
        return
    }
    XCTAssertFalse(unavailable.explanation.contains("sentinel-scope-secret"))
}

func test_localSecretStoreMetadataControlsInHouseSelection() throws {
    let home = localSecretTestHome()
    let backend = InMemoryLocalSecretStoreBackend()
    let store = LocalSecretStore(home: home, backend: backend)
    defer { try? FileManager.default.removeItem(at: home.root) }
    let provider = localSecretTestProvider()
    let config = ModelsConfig(
        providers: [provider], raw: .object([:]), fileURL: home.modelsFile, exists: true)
    let metadata = try store.list()
    let noMetadata = InHouseModelResolver.resolve(
        "xai/grok-test",
        inputs: InHouseModelResolver.Inputs(config: config, localSecrets: metadata))
    guard case .failure(.unavailableProvider) = noMetadata else {
        XCTFail("an absent secure credential must not make a provider reachable")
        return
    }

    try store.save(
        name: "grok", value: "sentinel-selection-secret", allowedProviderID: "xai",
        allowedOrigin: "https://api.example.test")
    let withMetadata = InHouseModelResolver.resolve(
        "xai/grok-test",
        inputs: InHouseModelResolver.Inputs(config: config, localSecrets: try store.list()))
    guard case .success(let selection) = withMetadata else {
        XCTFail("a matching metadata record should make the provider reachable")
        return
    }
    XCTAssertEqual(selection.qualifiedID, "xai/grok-test")
}

func test_localSecretStoreTrustedApplicationEligibilityIsNarrow() {
    let app = URL(fileURLWithPath: "/repo/build/Aviary.app", isDirectory: true)
    let appExecutable = app.appending(path: "Contents/MacOS/Aviary")
    let helper = app.appending(path: "Contents/Helpers/aviaryd")
    XCTAssertEqual(
        LocalSecretStore.bundledTrustedApplicationPaths(
            bundleURL: app,
            bundleIdentifier: LocalSecretStore.aviaryBundleIdentifier,
            executableURL: appExecutable),
        [appExecutable.standardizedFileURL.path, helper.standardizedFileURL.path])
    XCTAssertEqual(
        LocalSecretStore.bundledTrustedApplicationPaths(
            bundleURL: app,
            bundleIdentifier: LocalSecretStore.aviaryBundleIdentifier,
            executableURL: helper),
        [appExecutable.standardizedFileURL.path, helper.standardizedFileURL.path])
    XCTAssertTrue(LocalSecretStore.bundledTrustedApplicationPaths(
        bundleURL: app,
        bundleIdentifier: "com.example.other",
        executableURL: appExecutable).isEmpty)
    XCTAssertTrue(LocalSecretStore.bundledTrustedApplicationPaths(
        bundleURL: URL(fileURLWithPath: "/tmp/Fake.app", isDirectory: true),
        bundleIdentifier: LocalSecretStore.aviaryBundleIdentifier,
        executableURL: nil).isEmpty)
    XCTAssertTrue(LocalSecretStore.bundledTrustedApplicationPaths(
        bundleURL: app,
        bundleIdentifier: LocalSecretStore.aviaryBundleIdentifier,
        executableURL: URL(fileURLWithPath: "/tmp/unrelated")).isEmpty)
}

let casesLocalSecrets: [Case] = [
    ("local secrets: model listing never needs credential decryption", {
        let home = localSecretTestHome()
        let store = LocalSecretStore(home: home, backend: MetadataOnlySecretBackend())
        let resolution = await ApiKeyResolver.resolve("@secret:grok", home: home,
            providerID: "xai", origin: "https://api.example.test/v1", secretStore: store)
        XCTAssertEqual(resolution.outcome, .secretReferenceStored)
        XCTAssertTrue(resolution.ok)
        XCTAssertNil(resolution.masked)
        XCTAssertEqual(resolution.length, 0)
        XCTAssertNil(await ApiKeyResolver.resolveActual("@secret:grok", home: home,
            providerID: "xai", origin: "https://api.example.test/v1", secretStore: store))
        XCTAssertFalse(try store.hasScopedMetadata(name: "grok", providerID: "other", origin: "https://api.example.test"))
        XCTAssertFalse(try store.hasScopedMetadata(name: "grok", providerID: "xai", origin: "https://other.example"))
        XCTAssertFalse(try store.hasScopedMetadata(name: "missing", providerID: "xai", origin: "https://api.example.test"))
        let config = ModelsConfig(providers: [localSecretTestProvider()], raw: .object([:]),
            fileURL: home.modelsFile, exists: true)
        XCTAssertEqual(await ModelCatalogBuilder.credentialedProviders(
            config: config, auth: nil, home: home, secretStore: store), ["xai"])
    }),
    ("local secrets: helper authorization is metadata-only and scope checked", {
        let home = localSecretTestHome()
        let store = LocalSecretStore(home: home, backend: InMemoryLocalSecretStoreBackend())
        let record = LocalSecretMetadata(name: "grok", allowedProviderID: "xai", allowedOrigin: "https://api.x.ai")
        try store.save(name: record.name, value: "helper-secret-sentinel", allowedProviderID: record.allowedProviderID,
                       allowedOrigin: record.allowedOrigin)
        XCTAssertTrue(LocalSecretServiceAccess.check(record, store: store))
        XCTAssertFalse(LocalSecretServiceAccess.check(LocalSecretMetadata(name: "grok",
            allowedProviderID: "other", allowedOrigin: record.allowedOrigin), store: store))
        XCTAssertFalse(LocalSecretServiceAccess.check(LocalSecretMetadata(name: "grok",
            allowedProviderID: "xai", allowedOrigin: "https://other.example"), store: store))
        let args = LocalSecretServiceAccess.arguments(home: home, record: record, interactive: true)
        XCTAssertEqual(args.first, "--authorize-local-secret")
        XCTAssertFalse(args.joined().contains("helper-secret-sentinel"))
        XCTAssertEqual(LocalSecretServiceAccess.arguments(home: home, record: record, interactive: false).first,
                       "--check-local-secret")
        XCTAssertNil(LocalSecretServiceAccess.runIfRequested(arguments: ["aviaryd"]))
        XCTAssertEqual(LocalSecretServiceAccess.runIfRequested(arguments: ["aviaryd", "--authorize-local-secret"]), 2)
        XCTAssertEqual(LocalSecretServiceAccess.runIfRequested(arguments: ["aviaryd", "--check-local-secret",
            "grok", "xai", "https://api.x.ai", "relative-home"]), 2)
    }),
    ("local secrets: metadata-only round trip and atomic replace", {
        try test_localSecretStoreRoundTripsMetadataOnly()
    }),
    ("local secrets: provider and origin scope fail closed", {
        try await test_localSecretStoreScopesProviderAndOriginFailClosed()
    }),
    ("local secrets: metadata controls in-house selection", {
        try test_localSecretStoreMetadataControlsInHouseSelection()
    }),
    ("local secrets: trusted application eligibility is narrow", {
        test_localSecretStoreTrustedApplicationEligibilityIsNarrow()
    }),
]
