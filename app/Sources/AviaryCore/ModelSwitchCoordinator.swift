import Foundation

/// The durable boundary for an in-house model switch.
///
/// Provider construction can resolve secrets and, for some configurations, invoke helper
/// processes. Keep that effect behind a small Core seam so the production driver and its
/// failure behaviour are testable without importing the SwiftUI target. The caller records a
/// request before this boundary; `Agent.switchModel` records the effective model change before
/// mutating the live provider.
public enum ModelSwitchCoordinator {
    public struct Failure: LocalizedError, Sendable, Equatable {
        public let message: String

        public init(_ message: String) { self.message = message }

        public var errorDescription: String? { message }
    }

    public typealias ProviderFactory = @Sendable
        (ModelSpec, ProviderSpec) async -> Result<ChatProvider, Failure>

    /// Record the request and then resolve the provider. A latched/failed writer returns before
    /// invoking `makeProvider`, so a journal failure cannot be followed by secret resolution or
    /// another provider-side effect.
    public static func prepare(
        writer: SessionWriter,
        model: ModelSpec,
        provider: ProviderSpec,
        makeProvider: @escaping ProviderFactory
    ) async -> Result<ChatProvider, Failure> {
        guard case .healthy = await writer.writerHealth else {
            return .failure(Failure(
                "The session journal is unavailable; model switch was not attempted."))
        }
        do {
            try await writer.appendNote(
                "Requested model switch to \(model.qualifiedID).",
                customType: "aviary.model-switch-intent")
        } catch {
            return .failure(Failure(
                "Could not record the model switch: \(error.localizedDescription)"))
        }
        return await makeProvider(model, provider)
    }
}
