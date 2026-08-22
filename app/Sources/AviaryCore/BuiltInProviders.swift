import Foundation

/// Providers that authenticate by OAuth and so never appear in `models.json`.
///
/// The catalogue is transcribed from the harness's `models.generated.ts` rather than invented,
/// for the same reason as everything else in the Codex path: the model id goes to OpenAI, and a
/// name this client sends that no known harness sends is an anomaly. `contextWindow`,
/// `maxTokens`, the costs and the `thinkingLevelMap` are copied too — the map in particular is
/// load-bearing, because it is what turns a requested effort into the value the route accepts,
/// and `null` in it means *omit the field* rather than send a default.
///
/// Dated, because this list moves: transcribed 2026-08-22 from the vendored harness at
/// `harness/packages/ai/src/models.generated.ts`. Re-transcribe rather than extend by guess.
public enum BuiltInProviders {

    public static func openAICodex(auth: AuthInfo? = nil) -> ProviderSpec {
        var spec = ProviderSpec(
            id: "openai-codex",
            name: "ChatGPT Plus/Pro (Codex Subscription)",
            baseURL: "https://chatgpt.com/backend-api",
            api: "openai-codex-responses",
            apiKeyExpression: nil,
            authHeader: nil,
            headers: [:],
            models: codexModels)
        spec.isBuiltIn = true
        spec.hasStoredAuth = auth?.providers.contains("openai-codex") ?? false
        spec.authKind = auth?.kinds["openai-codex"]
        return spec
    }

    static func model(
        _ id: String, _ name: String, cost: (Double, Double, Double, Double),
        thinking: [String: String?]? = nil, contextWindow: Int = 272_000,
        maxTokens: Int = 128_000
    ) -> ModelSpec {
        var m = ModelSpec(rpc: .object([
            "id": .string(id),
            "name": .string(name),
            "provider": .string("openai-codex"),
            "api": .string("openai-codex-responses"),
            "baseUrl": .string("https://chatgpt.com/backend-api"),
            "reasoning": .bool(true),
            "input": .array([.string("text"), .string("image")]),
        ]))
        m.contextWindow = contextWindow
        m.maxTokens = maxTokens
        m.costInput = cost.0
        m.costOutput = cost.1
        m.costCacheRead = cost.2
        m.costCacheWrite = cost.3
        m.thinkingLevelMap = thinking
        m.isBuiltIn = true
        return m
    }

    /// `xhigh`/`minimal`/`max` handling differs per model family, and those differences are
    /// real — sending `minimal` to a model whose map sends it to `null` must omit `reasoning`
    /// entirely, which is why the value is an optional inside the dictionary.
    static let fiveSix: [String: String?] = ["xhigh": "xhigh", "minimal": nil, "max": "max"]
    static let fiveTwo: [String: String?] = ["xhigh": "xhigh", "minimal": "low"]

    public static let codexModels: [ModelSpec] = [
        model("gpt-5.6-terra", "GPT-5.6 Terra", cost: (2.5, 15, 0.25, 3.125), thinking: fiveSix),
        model("gpt-5.6-sol", "GPT-5.6 Sol", cost: (5, 30, 0.5, 6.25), thinking: fiveSix),
        model("gpt-5.6-luna", "GPT-5.6 Luna", cost: (1, 6, 0.1, 1.25), thinking: fiveSix),
        model("gpt-5.5", "GPT-5.5", cost: (5, 30, 0.5, 0), thinking: fiveTwo),
        model("gpt-5.4", "GPT-5.4", cost: (2.5, 15, 0.25, 0), thinking: fiveTwo),
        model("gpt-5.4-mini", "GPT-5.4 Mini", cost: (0.75, 4.5, 0.075, 0), thinking: fiveTwo),
        model("gpt-5.3-codex", "GPT-5.3 Codex", cost: (1.75, 14, 0.175, 0), thinking: fiveTwo),
        model("gpt-5.3-codex-spark", "GPT-5.3 Codex Spark", cost: (0, 0, 0, 0),
              thinking: fiveTwo, contextWindow: 128_000),
        model("gpt-5.2-codex", "GPT-5.2 Codex", cost: (1.75, 14, 0.175, 0), thinking: fiveTwo),
        model("gpt-5.2", "GPT-5.2", cost: (1.75, 14, 0.175, 0), thinking: fiveTwo),
        model("gpt-5.1-codex-max", "GPT-5.1 Codex Max", cost: (1.25, 10, 0.125, 0)),
        model("gpt-5.1-codex-mini", "GPT-5.1 Codex Mini", cost: (0.25, 2, 0.025, 0),
              thinking: ["minimal": "medium", "low": "medium", "medium": "medium", "high": "high"]),
        model("gpt-5.1", "GPT-5.1", cost: (1.25, 10, 0.125, 0)),
    ]
}
