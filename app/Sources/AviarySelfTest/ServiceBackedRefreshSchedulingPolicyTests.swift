import Foundation
@testable import AviaryCore

private let refreshSchedulingEpoch = Date(timeIntervalSince1970: 1_000)

private func refreshCandidate(
    _ key: String, prompt: Bool = false
) -> ServiceBackedRefreshSchedulingPolicy.Candidate {
    ServiceBackedRefreshSchedulingPolicy.Candidate(
        key: key, needsPromptRefresh: prompt)
}

func testServiceBackedRefreshSchedulingSeparatesPromptAndQuiescentCadence() {
    let candidates = [refreshCandidate("prompt", prompt: true), refreshCandidate("quiet")]
    let initial = ServiceBackedRefreshSchedulingPolicy.recordingExplicitRefresh(
        candidates: candidates, now: refreshSchedulingEpoch, previous: .init())

    let promptPass = ServiceBackedRefreshSchedulingPolicy.plan(
        candidates: candidates,
        now: refreshSchedulingEpoch.addingTimeInterval(1.5), previous: initial)
    XCTAssertEqual(promptPass.selectedKeys, ["prompt"])
    XCTAssertFalse(promptPass.refreshCatalog)

    let quietPass = ServiceBackedRefreshSchedulingPolicy.plan(
        candidates: candidates,
        now: refreshSchedulingEpoch.addingTimeInterval(12), previous: promptPass.state)
    XCTAssertTrue(quietPass.selectedKeys.contains("prompt"))
    XCTAssertTrue(quietPass.selectedKeys.contains("quiet"))
    XCTAssertTrue(quietPass.refreshCatalog)
}

func testServiceBackedRefreshSchedulingFairlyBoundsLargePromptAndQuietSets() {
    let prompt = (0..<40).map { refreshCandidate("prompt-\($0)", prompt: true) }
    let firstPrompt = ServiceBackedRefreshSchedulingPolicy.plan(
        candidates: prompt, now: refreshSchedulingEpoch, previous: .init())
    XCTAssertEqual(firstPrompt.selectedKeys.count, 32)
    let secondPrompt = ServiceBackedRefreshSchedulingPolicy.plan(
        candidates: prompt,
        now: refreshSchedulingEpoch.addingTimeInterval(1.5), previous: firstPrompt.state)
    XCTAssertEqual(Set(firstPrompt.selectedKeys + secondPrompt.selectedKeys), Set(prompt.map(\.key)))

    let quiet = (0..<40).map { refreshCandidate("quiet-\($0)") }
    let firstQuiet = ServiceBackedRefreshSchedulingPolicy.plan(
        candidates: quiet, now: refreshSchedulingEpoch, previous: .init())
    XCTAssertEqual(firstQuiet.selectedKeys.count, 32)
    let secondQuiet = ServiceBackedRefreshSchedulingPolicy.plan(
        candidates: quiet, now: refreshSchedulingEpoch, previous: firstQuiet.state)
    XCTAssertEqual(secondQuiet.selectedKeys.count, 8)
    XCTAssertEqual(Set(firstQuiet.selectedKeys + secondQuiet.selectedKeys), Set(quiet.map(\.key)))
}

func testServiceBackedRefreshSchedulingExplicitAndForcedCatalogAreImmediate() {
    let candidates = [refreshCandidate("one"), refreshCandidate("two", prompt: true)]
    let explicit = ServiceBackedRefreshSchedulingPolicy.recordingExplicitRefresh(
        candidates: candidates, now: refreshSchedulingEpoch, previous: .init())
    let early = ServiceBackedRefreshSchedulingPolicy.plan(
        candidates: candidates,
        now: refreshSchedulingEpoch.addingTimeInterval(0.5), previous: explicit,
        forceCatalogRefresh: true)
    XCTAssertTrue(early.selectedKeys.isEmpty)
    XCTAssertTrue(early.refreshCatalog)
}

func testServiceBackedRefreshSchedulingDeduplicatesAndSurvivesClockRollback() {
    let candidates = [
        refreshCandidate("same"), refreshCandidate("same", prompt: true),
        refreshCandidate("other"),
    ]
    let initial = ServiceBackedRefreshSchedulingPolicy.recordingExplicitRefresh(
        candidates: candidates, now: refreshSchedulingEpoch, previous: .init())
    let rollback = ServiceBackedRefreshSchedulingPolicy.plan(
        candidates: candidates,
        now: refreshSchedulingEpoch.addingTimeInterval(-1), previous: initial)
    XCTAssertEqual(Set(rollback.selectedKeys), Set(["same", "other"]))
    XCTAssertEqual(rollback.selectedKeys.count, 2)
    XCTAssertTrue(rollback.refreshCatalog)
}

let casesServiceBackedRefreshSchedulingPolicy: [Case] = [
    ("service refresh scheduling separates prompt and quiescent cadence", {
        testServiceBackedRefreshSchedulingSeparatesPromptAndQuiescentCadence()
    }),
    ("service refresh scheduling fairly bounds large row sets", {
        testServiceBackedRefreshSchedulingFairlyBoundsLargePromptAndQuietSets()
    }),
    ("service refresh scheduling keeps explicit and forced catalog refresh immediate", {
        testServiceBackedRefreshSchedulingExplicitAndForcedCatalogAreImmediate()
    }),
    ("service refresh scheduling handles duplicate keys and clock rollback", {
        testServiceBackedRefreshSchedulingDeduplicatesAndSurvivesClockRollback()
    }),
]
