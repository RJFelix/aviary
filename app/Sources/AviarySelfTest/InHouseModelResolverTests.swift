import Foundation
@testable import AviaryCore

private func resolverProvider(
    _ id: String,
    models: [String],
    apiKey: String? = "INHOUSE_TOKEN",
    api: String = "openai-completions",
    baseURL: String? = "http://127.0.0.1:1/v1"
) -> ProviderSpec {
    var providerObject: [String: JSONValue] = ["api": .string(api)]
    if let baseURL { providerObject["baseUrl"] = .string(baseURL) }
    let providerJSON: JSONValue = .object(providerObject)
    var provider = ProviderSpec(
        id: id,
        name: nil,
        baseURL: baseURL,
        api: api,
        apiKeyExpression: apiKey,
        authHeader: nil,
        headers: [:],
        models: [])
    provider.models = models.map { modelID in
        ModelSpec(
            id: modelID,
            providerID: id,
            json: .object(["id": .string(modelID)]),
            provider: providerJSON)
    }
    return provider
}

private func resolverConfig(_ providers: [ProviderSpec]) -> ModelsConfig {
    ModelsConfig(
        providers: providers,
        raw: .object([:]),
        fileURL: URL(fileURLWithPath: "/tmp/aviary-model-resolver-models.json"),
        exists: true)
}

private func resolverInputs(
    _ providers: [ProviderSpec],
    auth: AuthInfo = AuthInfo(),
    environment: [String: String] = [:],
    preferences: ModelPreferences = ModelPreferences()
) -> InHouseModelResolver.Inputs {
    InHouseModelResolver.Inputs(
        config: resolverConfig(providers), auth: auth,
        environment: environment, preferences: preferences)
}

func test_inHouseModelResolverQualifiedReferenceWins() throws {
    let inputs = resolverInputs([
        resolverProvider("alpha", models: ["shared"]),
        resolverProvider("beta", models: ["shared"]),
    ], environment: ["INHOUSE_TOKEN": "captured-secret"])

    let result = InHouseModelResolver.resolve("beta/shared", inputs: inputs)
    guard case .success(let selection) = result else {
        XCTFail("qualified provider/model should resolve")
        return
    }
    XCTAssertEqual(selection.providerID, "beta")
    XCTAssertEqual(selection.modelID, "shared")
    XCTAssertEqual(selection.qualifiedID, "beta/shared")
}

func test_inHouseModelResolverBareReferenceRejectsAmbiguity() throws {
    let inputs = resolverInputs([
        resolverProvider("zeta", models: ["shared"]),
        resolverProvider("alpha", models: ["shared"]),
    ], environment: ["INHOUSE_TOKEN": "captured-secret"])

    let result = InHouseModelResolver.resolve("shared", inputs: inputs)
    guard case .failure(.ambiguousModel(let candidates)) = result else {
        XCTFail("a bare model shared by two providers must not choose arbitrarily")
        return
    }
    XCTAssertEqual(candidates, ["alpha/shared", "zeta/shared"])
    if case .failure(let error) = result {
        XCTAssertEqual(error.errorDescription, "The model reference is ambiguous.")
        XCTAssertFalse(error.errorDescription?.contains("alpha") == true)
    }
}

func test_inHouseModelResolverDefaultIsCanonicalAndPreferenceAware() throws {
    let inputs = resolverInputs([
        resolverProvider("zeta", models: ["later", "preferred"]),
        resolverProvider("alpha", models: ["first"]),
    ], environment: ["INHOUSE_TOKEN": "captured-secret"], preferences: ModelPreferences(
        order: ["zeta/preferred"], disabled: []))

    let result = InHouseModelResolver.resolve(nil, inputs: inputs)
    guard case .success(let selection) = result else {
        XCTFail("an available default should resolve")
        return
    }
    XCTAssertEqual(selection.qualifiedID, "zeta/preferred")

    let disabled = resolverInputs(
        [resolverProvider("alpha", models: ["first"])],
        environment: ["INHOUSE_TOKEN": "captured-secret"],
        preferences: ModelPreferences(order: [], disabled: ["alpha/first"]))
    guard case .failure(.noAvailableModels) = InHouseModelResolver.resolve(nil, inputs: disabled)
    else {
        XCTFail("disabled models must not become an implicit default")
        return
    }
}

func test_inHouseModelResolverUnknownAndUnsupportedReferencesFailClosed() throws {
    let inputs = resolverInputs([
        resolverProvider("claude-code", models: ["sonnet"], apiKey: "INHOUSE_TOKEN",
                          api: "claude-code-cli"),
        resolverProvider("alpha", models: ["known"]),
    ], environment: ["INHOUSE_TOKEN": "captured-secret"])

    guard case .failure(.unknownModel) = InHouseModelResolver.resolve(
        "alpha/missing", inputs: inputs) else {
        XCTFail("unknown qualified model should fail explicitly")
        return
    }
    guard case .failure(.unsupportedProvider) = InHouseModelResolver.resolve(
        "claude-code/sonnet", inputs: inputs) else {
        XCTFail("Claude Code must never be selected as an in-house HTTP provider")
        return
    }
    guard case .failure(.unknownModel) = InHouseModelResolver.resolve(
        "sonnet", inputs: inputs) else {
        XCTFail("Claude Code models must not enter bare in-house selection")
        return
    }
}

func test_inHouseModelResolverUsesEffectiveModelAPI() throws {
    var provider = resolverProvider("alpha", models: ["known"])
    provider.models[0].api = "claude-code-cli"
    let inputs = resolverInputs([provider], environment: ["INHOUSE_TOKEN": "captured-secret"])

    guard case .failure(.invalidConfiguration) = InHouseModelResolver.resolve(
        "alpha/known", inputs: inputs) else {
        XCTFail("a model-level Claude Code API override must be rejected")
        return
    }
}

func test_inHouseModelResolverIgnoresCoincidentalCustomAuthWithoutEndpoint() throws {
    var auth = AuthInfo()
    auth.providers.insert("alpha")
    let noEndpoint = resolverInputs(
        [resolverProvider("alpha", models: ["known"], apiKey: nil, baseURL: nil)], auth: auth)
    guard case .failure(.unavailableProvider) = InHouseModelResolver.resolve(
        "alpha/known", inputs: noEndpoint) else {
        XCTFail("custom auth.json entries must not make an HTTP provider without an endpoint reachable")
        return
    }

    let localEndpoint = resolverInputs(
        [resolverProvider("alpha", models: ["known"], apiKey: nil)], auth: auth)
    guard case .success = InHouseModelResolver.resolve("alpha/known", inputs: localEndpoint) else {
        XCTFail("an explicitly configured unauthenticated local endpoint should remain reachable")
        return
    }
}

func test_inHouseModelResolverRejectsConflictingIdentitiesAndMalformedBounds() throws {
    let duplicateProvider = resolverProvider("alpha", models: ["one"])
    guard case .failure(.duplicateProvider) = InHouseModelResolver.resolve(
        nil, inputs: resolverInputs([duplicateProvider, duplicateProvider],
                                     environment: ["INHOUSE_TOKEN": "captured-secret"])) else {
        XCTFail("duplicate provider identities must fail before selection")
        return
    }

    let duplicateModel = resolverProvider("alpha", models: ["one", "one"])
    guard case .failure(.duplicateModel) = InHouseModelResolver.resolve(
        nil, inputs: resolverInputs([duplicateModel],
                                    environment: ["INHOUSE_TOKEN": "captured-secret"])) else {
        XCTFail("duplicate model identities must fail before selection")
        return
    }

    let hugeProvider = resolverProvider(String(repeating: "p", count: 300), models: ["one"])
    let hugeResult = InHouseModelResolver.resolve(
        nil, inputs: resolverInputs([hugeProvider], environment: ["INHOUSE_TOKEN": "captured-secret"]))
    guard case .failure(.invalidConfiguration) = hugeResult else {
        XCTFail("oversized provider ids must fail closed")
        return
    }
    if case .failure(let error) = hugeResult {
        XCTAssertFalse(error.errorDescription?.contains(String(repeating: "p", count: 30)) == true)
    }

    let hugeAPI = resolverProvider("alpha", models: ["one"], api: String(repeating: "sk-secret-", count: 30))
    let apiResult = InHouseModelResolver.resolve(
        nil, inputs: resolverInputs([hugeAPI], environment: ["INHOUSE_TOKEN": "captured-secret"]))
    guard case .failure(.invalidConfiguration) = apiResult else {
        XCTFail("oversized APIs must fail closed")
        return
    }
    if case .failure(let error) = apiResult {
        XCTAssertFalse(error.errorDescription?.contains("sk-secret") == true)
    }

    var mismatched = resolverProvider("alpha", models: ["one"])
    mismatched.models[0].providerID = "other"
    guard case .failure(.invalidConfiguration) = InHouseModelResolver.resolve(
        nil, inputs: resolverInputs([mismatched], environment: ["INHOUSE_TOKEN": "captured-secret"]))
    else {
        XCTFail("a model carrying a foreign provider identity must fail closed")
        return
    }

    let hugeModel = resolverProvider("alpha", models: [String(repeating: "m", count: 300)])
    guard case .failure(.invalidConfiguration) = InHouseModelResolver.resolve(
        nil, inputs: resolverInputs([hugeModel], environment: ["INHOUSE_TOKEN": "captured-secret"]))
    else {
        XCTFail("oversized model ids must fail closed")
        return
    }

    var hugeRoute = resolverProvider("alpha", models: ["one"])
    hugeRoute.baseURL = "http://127.0.0.1/" + String(repeating: "x", count: 8_192)
    guard case .failure(.invalidConfiguration) = InHouseModelResolver.resolve(
        nil, inputs: resolverInputs([hugeRoute], environment: ["INHOUSE_TOKEN": "captured-secret"]))
    else {
        XCTFail("oversized route URLs must fail closed")
        return
    }

    var invalidHeaders = resolverProvider("alpha", models: ["one"])
    invalidHeaders.headers = ["X-Route\nInjected": "value"]
    guard case .failure(.invalidConfiguration) = InHouseModelResolver.resolve(
        nil, inputs: resolverInputs(
            [invalidHeaders], environment: ["INHOUSE_TOKEN": "captured-secret"])) else {
        XCTFail("control characters in static headers must fail closed")
        return
    }

    invalidHeaders.headers = [:]
    invalidHeaders.authHeader = String(repeating: "A", count: 4_097)
    guard case .failure(.invalidConfiguration) = InHouseModelResolver.resolve(
        nil, inputs: resolverInputs(
            [invalidHeaders], environment: ["INHOUSE_TOKEN": "captured-secret"])) else {
        XCTFail("oversized authorization header names must fail closed")
        return
    }
}

func test_inHouseModelResolverDistinguishesAbsentDefaultAndEmptyReference() throws {
    let inputs = resolverInputs(
        [resolverProvider("alpha", models: ["known"])],
        environment: ["INHOUSE_TOKEN": "captured-secret"])
    guard case .success = InHouseModelResolver.resolve(nil, inputs: inputs) else {
        XCTFail("nil means select the configured default")
        return
    }
    for reference in ["", "   ", "\n\t"] {
        guard case .failure(.emptyReference) = InHouseModelResolver.resolve(
            reference, inputs: inputs) else {
            XCTFail("supplied empty/whitespace references must not become defaults")
            return
        }
    }

    let hugeReference = String(repeating: "x", count: 1_100)
    guard case .failure(.invalidReference) = InHouseModelResolver.resolve(
        hugeReference, inputs: inputs) else {
        XCTFail("oversized references must fail closed")
        return
    }
}

func test_inHouseModelResolverDigestIsStableChangingAndNonSecret() throws {
    let first = resolverInputs(
        [resolverProvider("alpha", models: ["known"])],
        environment: ["INHOUSE_TOKEN": "secret-value"])
    let same = resolverInputs(
        [resolverProvider("alpha", models: ["known"])],
        environment: ["INHOUSE_TOKEN": "different-secret-value"])
    let firstSelection = try XCTUnwrap(
        tryResult(InHouseModelResolver.resolve("alpha/known", inputs: first)))
    let sameSelection = try XCTUnwrap(
        tryResult(InHouseModelResolver.resolve("alpha/known", inputs: same)))
    XCTAssertEqual(firstSelection.configurationDigest, sameSelection.configurationDigest,
                   "credential rotation must not put a credential into route identity")
    XCTAssertEqual(firstSelection, sameSelection)

    let changed = resolverInputs(
        [resolverProvider("alpha", models: ["known"], api: "anthropic-messages")],
        environment: ["INHOUSE_TOKEN": "secret-value"])
    let changedSelection = try XCTUnwrap(
        tryResult(InHouseModelResolver.resolve("alpha/known", inputs: changed)))
    XCTAssertNotEqual(firstSelection.configurationDigest, changedSelection.configurationDigest)

    let encoded = String(
        data: try JSONEncoder().encode(firstSelection), encoding: .utf8) ?? ""
    XCTAssertFalse(encoded.contains("secret-value"))
    XCTAssertFalse(firstSelection.configurationDigest.contains("secret-value"))

    var baselineProvider = resolverProvider("alpha", models: ["known"])
    let baselineInputs = resolverInputs(
        [baselineProvider], environment: ["INHOUSE_TOKEN": "secret-value"])
    let baseline = try XCTUnwrap(tryResult(
        InHouseModelResolver.resolve("alpha/known", inputs: baselineInputs)))
    let mutations: [(inout ProviderSpec) -> Void] = [
        { (p: inout ProviderSpec) in p.models[0].reasoning = true },
        { (p: inout ProviderSpec) in p.models[0].contextWindow = 99 },
        { (p: inout ProviderSpec) in p.models[0].maxTokens = 99 },
        { (p: inout ProviderSpec) in p.models[0].inputModalities = ["image"] },
        { (p: inout ProviderSpec) in p.models[0].thinkingLevelMap = ["high": "high"] },
        { (p: inout ProviderSpec) in p.baseURL = "http://127.0.0.1:2/v1" },
    ]
    for (index, mutate) in mutations.enumerated() {
        mutate(&baselineProvider)
        let changedInputs = resolverInputs(
            [baselineProvider], environment: ["INHOUSE_TOKEN": "secret-value"])
        let changedSelection = try XCTUnwrap(tryResult(
            InHouseModelResolver.resolve("alpha/known", inputs: changedInputs)))
        XCTAssertNotEqual(baseline.configurationDigest, changedSelection.configurationDigest,
                           "model/route field drift \(index) must change the digest")
        baselineProvider = resolverProvider("alpha", models: ["known"])
    }

    var headerA = resolverProvider("alpha", models: ["known"])
    headerA.headers = ["X-Route-Token": "secret-header-a"]
    var headerB = headerA
    headerB.headers = ["X-Route-Token": "secret-header-b"]
    let headerSelectionA = try XCTUnwrap(tryResult(InHouseModelResolver.resolve(
        "alpha/known", inputs: resolverInputs([headerA], environment: ["INHOUSE_TOKEN": "secret-value"]))))
    let headerSelectionB = try XCTUnwrap(tryResult(InHouseModelResolver.resolve(
        "alpha/known", inputs: resolverInputs([headerB], environment: ["INHOUSE_TOKEN": "secret-value"]))))
    XCTAssertNotEqual(headerSelectionA.configurationDigest, headerSelectionB.configurationDigest,
                      "behavior-changing extra headers belong to durable route identity")
    XCTAssertFalse(headerSelectionA.configurationDigest.contains("secret-header-a"))
    XCTAssertFalse(headerSelectionB.configurationDigest.contains("secret-header-b"))

    for unsafeURL in [
        "http://user@127.0.0.1:1/v1",
        "http://127.0.0.1:1/v1?tenant=secret",
        "http://127.0.0.1:1/v1#route",
    ] {
        var unsafe = resolverProvider("alpha", models: ["known"])
        unsafe.baseURL = unsafeURL
        XCTAssertNil(tryResult(InHouseModelResolver.resolve(
            "alpha/known", inputs: resolverInputs(
                [unsafe], environment: ["INHOUSE_TOKEN": "secret-value"]))))
    }
}

private func tryResult(
    _ result: Result<InHouseModelSelection, InHouseModelSelectionError>
) -> InHouseModelSelection? {
    if case .success(let selection) = result { return selection }
    return nil
}

func test_inHouseModelResolverIncludesAuthenticatedCodexBuiltin() throws {
    var auth = AuthInfo()
    auth.providers.insert("openai-codex")
    let inputs = resolverInputs([], auth: auth)

    let result = InHouseModelResolver.resolve("openai-codex/gpt-5.6-luna", inputs: inputs)
    guard case .success(let selection) = result else {
        XCTFail("stored Codex auth should make the built-in route selectable")
        return
    }
    XCTAssertEqual(selection.providerID, "openai-codex")
    XCTAssertEqual(selection.modelID, "gpt-5.6-luna")
    XCTAssertTrue(selection.providerIsBuiltIn)
    XCTAssertTrue(selection.modelIsBuiltIn)
}

func test_inHouseModelResolverUsesCapturedEnvironmentAndReturnsNoCredential() throws {
    var captured = ["INHOUSE_TOKEN": "secret-value"]
    let inputs = resolverInputs(
        [resolverProvider("alpha", models: ["known"])], environment: captured)
    captured["INHOUSE_TOKEN"] = "changed-after-capture"

    let result = InHouseModelResolver.resolve("alpha/known", inputs: inputs)
    guard case .success(let selection) = result else {
        XCTFail("the captured environment should be sufficient")
        return
    }
    let encoded = String(data: try JSONEncoder().encode(selection), encoding: .utf8) ?? ""
    XCTAssertFalse(encoded.contains("secret-value"))
    XCTAssertFalse(selection.qualifiedID.contains("secret-value"))

    let missing = resolverInputs(
        [resolverProvider("alpha", models: ["known"])], environment: [:])
    guard case .failure(.unavailableProvider) = InHouseModelResolver.resolve(
        "alpha/known", inputs: missing) else {
        XCTFail("selection must use the supplied environment, not ProcessEnvironment.shared")
        return
    }
}

let casesInHouseModelResolver: [Case] = [
    ("phase3 model resolver: qualified references are exact", {
        try test_inHouseModelResolverQualifiedReferenceWins()
    }),
    ("phase3 model resolver: bare ambiguity is explicit", {
        try test_inHouseModelResolverBareReferenceRejectsAmbiguity()
    }),
    ("phase3 model resolver: defaults are deterministic", {
        try test_inHouseModelResolverDefaultIsCanonicalAndPreferenceAware()
    }),
    ("phase3 model resolver: unknown and CLI providers fail closed", {
        try test_inHouseModelResolverUnknownAndUnsupportedReferencesFailClosed()
    }),
    ("phase3 model resolver: effective model API is enforced", {
        try test_inHouseModelResolverUsesEffectiveModelAPI()
    }),
    ("phase3 model resolver: custom auth cannot invent HTTP reachability", {
        try test_inHouseModelResolverIgnoresCoincidentalCustomAuthWithoutEndpoint()
    }),
    ("phase3 model resolver: identity and bounds are validated", {
        try test_inHouseModelResolverRejectsConflictingIdentitiesAndMalformedBounds()
    }),
    ("phase3 model resolver: absent and empty references differ", {
        try test_inHouseModelResolverDistinguishesAbsentDefaultAndEmptyReference()
    }),
    ("phase3 model resolver: digest is stable, changing, and non-secret", {
        try test_inHouseModelResolverDigestIsStableChangingAndNonSecret()
    }),
    ("phase3 model resolver: authenticated Codex builtin resolves", {
        try test_inHouseModelResolverIncludesAuthenticatedCodexBuiltin()
    }),
    ("phase3 model resolver: environment is captured without secrets", {
        try test_inHouseModelResolverUsesCapturedEnvironmentAndReturnsNoCredential()
    }),
]
