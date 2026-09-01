import Foundation
@testable import AviaryCore

/// Regression for the production model-switch boundary: a latched journal must stop the
/// provider factory before it can resolve a secret or start a helper process. The SwiftUI driver
/// uses this Core coordinator, so the test does not duplicate a lower-level writer assertion.
func test_modelSwitchCoordinatorFailsClosedBeforeProviderResolution() async throws {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var wasInvoked: Bool {
            lock.lock(); defer { lock.unlock() }
            return count > 0
        }

        func invoke() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }
    }

    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
    await writer.injectFailure(.beforeWrite)
    let probe = Probe()
    let provider = ProviderSpec(
        id: "secret-route", name: nil, baseURL: "https://example.test", api: "openai-completions",
        apiKeyExpression: "!printf should-not-run", authHeader: nil, headers: [:], models: [])

    let result = await ModelSwitchCoordinator.prepare(
        writer: writer, model: fakeModel(), provider: provider,
        makeProvider: { _, _ in
            probe.invoke()
            return .failure(ModelSwitchCoordinator.Failure(
                "provider factory was unexpectedly invoked"))
        })

    guard case .failure(let detail) = result else {
        XCTFail("a failed journal must reject the model switch")
        return
    }
    XCTAssertTrue(detail.message.contains("journal"), detail.message)
    XCTAssertFalse(probe.wasInvoked, "provider resolution crossed a failed journal boundary")
    await writer.close()
}
