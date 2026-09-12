import Foundation
@testable import AviaryCore

/// Context/ownership fixtures do not claim measured usage or configured prices.
func fixtureProviderAdmission(kind: ActionKind = .provider) -> ProviderAdmission {
    ProviderAdmission(purpose: kind == .compactionProvider ? .compaction : .normal,
        rates: ProviderUsage.RateSnapshot(model: ModelSpec(rpc: .object([
            "id": .string("model"), "provider": .string("provider")
        ]))))
}

func fixtureProviderSettlement(_ permit: EffectPermit) throws -> ProviderSettlement {
    ProviderSettlement(admission: try XCTUnwrap(permit.providerAdmission),
        report: nil, finality: .finalReport)
}

func fixtureProviderManifest(home: AgentHome, bundle: RunJournalBundle) async throws -> ContextManifest {
    let request = ChatRequest(model: "model", messages: [.user("private fixture request")])
    let id = UUID().uuidString
    let prior = await bundle.activeRunContextDeliveredBytes
    let base = try ContextManifest.build(request: request, manifestID: id, requestID: id,
        priorDeliveredBytes: prior)
    let reference = try ContextBodyStore(home: home).retain(
        ContextManifest.bodyData(for: request.messages[0]), authority: bundle.sessionJournal,
        mediaType: "application/vnd.aviary.chat-message+json")
    return try ContextManifest.build(request: request, manifestID: id, requestID: id,
        bodyReferences: [base.components[0].sourceID: reference], priorDeliveredBytes: prior)
}
