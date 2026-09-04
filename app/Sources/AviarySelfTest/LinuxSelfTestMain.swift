#if os(Linux)
import Foundation
@testable import AviaryCore

typealias Case = (String, () async throws -> Void)

private func test_linuxSHA256KnownVectors() {
    let vectors: [(String, String)] = [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (
            "The quick brown fox jumps over the lazy dog. "
                + "The quick brown fox jumps over the lazy dog.",
            "635241ac823ee4a81fbb410c92be616b0a89191083d8d7b5d232c823dc8df4f5"
        ),
    ]
    for (input, expected) in vectors {
        let actual = AviarySHA256.hash(data: Data(input.utf8)).description
        XCTAssertEqual(actual, expected)
    }
}

private func test_linuxSecureRandomUsesBoundedOSBytes() throws {
    let first = try AviarySecureRandom.bytes(count: 32)
    let second = try AviarySecureRandom.bytes(count: 32)
    XCTAssertEqual(first.count, 32)
    XCTAssertEqual(second.count, 32)
    XCTAssertNotEqual(first, second, "two kernel random reads unexpectedly repeated")
    XCTAssertEqual(try AviarySecureRandom.bytes(count: 0), [])
    XCTAssertEqual(AviarySecureRandom.uuidString().count, 36)
}

private func test_linuxISO8601DateParsing() {
    let fractional = AviaryDateParsing.parseDate("2026-09-03T23:45:12.125Z")
    let plain = AviaryDateParsing.parseDate("2026-09-03T23:45:12Z")
    XCTAssertNotNil(fractional)
    XCTAssertNotNil(plain)
    XCTAssertNil(AviaryDateParsing.parseDate("not-a-date"))
    XCTAssertNil(AviaryDateParsing.parseDate(nil))
}

@main
enum LinuxSelfTestMain {
    static func main() async {
        await Harness.run([
            ("Shell: no implicit stdin inherits the controlling terminal", {
                try await test_shellRunDetachesImplicitStdin()
            }),
            ("Shell: explicit stdin remains connected", {
                try await test_shellRunStillDeliversExplicitStdin()
            }),
            ("Shell: login commands execute without interactive job control", {
                try await test_loginShellExecutesWithoutInteractiveJobControl()
            }),
            ("Shell: concurrent login environment loads coalesce", {
                try await test_processEnvironmentCoalescesConcurrentLoads()
            }),
            ("Linux platform: SHA-256 known vectors", {
                test_linuxSHA256KnownVectors()
            }),
            ("Linux platform: secure random length and nonrepeat", {
                try test_linuxSecureRandomUsesBoundedOSBytes()
            }),
            ("Linux platform: ISO-8601 memory date parsing", {
                test_linuxISO8601DateParsing()
            }),
            ("Linux platform: bounded URLSession streaming and cancellation", {
                try await test_linuxURLSessionStreamingBoundsAndCancellation()
            }),
            ("Work service: transport handshake and read projection", {
                try await test_workServiceTransportHandshakeAndReadProjection()
            }),
            ("Work service: transport independent clients and ordered mutations", {
                try await test_workServiceTransportSupportsIndependentClientsAndOrderedMutations()
            }),
            ("Work service: transport typed errors and identity fence", {
                try await test_workServiceTransportPreservesTypedErrorsAndIdentityFence()
            }),
            ("Work Host: endpoint publication and discovery", {
                try test_workHostDaemonEndpointPublishesBoundedNonLivenessDiscovery()
            }),
            ("Work Host: endpoint generation ownership", {
                try test_workHostDaemonEndpointOldGenerationCannotRemoveReplacement()
            }),
            ("Work Host: workspace registry stable reopen", {
                try test_workHostWorkspaceRegistryStableAcrossReopen()
            }),
            ("Work Host: workspace registry concurrent convergence", {
                try test_workHostWorkspaceRegistryConcurrentSamePathConverges()
            }),
            ("Work Host: real aviaryd process and client round-trip", {
                try await test_aviarydNormalModeServesDurableCatalogWithoutCwdPromotion()
            }),
            ("Work Host: real aviaryd process survives client reconnect", {
                try await test_aviarydSubprocessSurvivesClientExitAndSecondClientAttaches()
            }),
            ("Work Host: real aviaryd process parent lease", {
                try await test_aviarydSubprocessParentLeasePreventsOrphans()
            }),
        ])
    }
}
#endif
