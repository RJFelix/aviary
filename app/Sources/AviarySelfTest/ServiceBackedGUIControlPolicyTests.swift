import AviaryCore
import Foundation

private let guiPolicySessionA = SessionRef("gui-policy-session-a")
private let guiPolicySessionB = SessionRef("gui-policy-session-b")
private let guiPolicyAttachmentA = SessionAttachmentRef("gui-policy-attachment-a")
private let guiPolicyAttachmentB = SessionAttachmentRef("gui-policy-attachment-b")
private let guiPolicyRun = RunRef("gui-policy-run")

private func guiPolicy(
    execution: WorkServiceExecutionState,
    currentRun: RunRef? = nil,
    ownerSession: SessionRef? = nil,
    ownerAttachment: SessionAttachmentRef? = nil,
    attachedSession: SessionRef? = guiPolicySessionA,
    attachedAttachment: SessionAttachmentRef? = guiPolicyAttachmentA,
    capabilities: Set<WorkServiceCapability>,
    canonical: Bool = true,
    recovery: Bool = false,
    refresh: Bool = false
) -> ServiceBackedGUIControlPolicy {
    ServiceBackedGUIControlPolicy(
        execution: execution,
        currentRun: currentRun,
        currentRunSession: ownerSession,
        currentRunSessionAttachment: ownerAttachment,
        attachedSession: attachedSession,
        attachedSessionAttachment: attachedAttachment,
        capabilities: capabilities,
        isCanonical: canonical,
        needsRecovery: recovery,
        requiresRefresh: refresh)
}

func testServiceBackedGUIControlPolicyRoutesFirstInputToStart() {
    let policy = guiPolicy(
        execution: .idle, capabilities: [.observe, .control, .start, .send, .end])
    XCTAssertTrue(policy.hasExactRunOwner)
    XCTAssertTrue(policy.requiresStartForNextInput)
    XCTAssertTrue(policy.canSubmitText)
    XCTAssertFalse(policy.canEnd)
    XCTAssertTrue(policy.canRetryPendingCommand(kind: .start))
    XCTAssertFalse(policy.canRetryPendingCommand(kind: .send))

    let noControl = guiPolicy(execution: .idle, capabilities: [.observe, .start])
    XCTAssertFalse(noControl.requiresStartForNextInput)
    XCTAssertFalse(noControl.canSubmitText)
}

func testServiceBackedGUIControlPolicyAllowsSameSessionGUIsAndRejectsOtherSession() {
    let granted: Set<WorkServiceCapability> = [
        .observe, .control, .send, .steer, .queue, .cancel, .end,
    ]
    let sameSession = guiPolicy(
        execution: .running, currentRun: guiPolicyRun,
        ownerSession: guiPolicySessionA, ownerAttachment: guiPolicyAttachmentA,
        capabilities: granted)
    XCTAssertTrue(sameSession.hasExactRunOwner)
    XCTAssertTrue(sameSession.canSubmitText)
    XCTAssertTrue(sameSession.canEnd)
    XCTAssertTrue(sameSession.commandCapabilities.supportsSteering)
    XCTAssertTrue(sameSession.commandCapabilities.supportsQueuedFollowUps)
    XCTAssertTrue(sameSession.commandCapabilities.supports(.agentLoop))
    XCTAssertTrue(sameSession.canRetryPendingCommand(kind: .send))
    XCTAssertFalse(sameSession.canRetryPendingCommand(kind: .start))

    let otherSession = guiPolicy(
        execution: .running, currentRun: guiPolicyRun,
        ownerSession: guiPolicySessionB, ownerAttachment: guiPolicyAttachmentB,
        capabilities: granted)
    XCTAssertFalse(otherSession.hasExactRunOwner)
    XCTAssertFalse(otherSession.canSubmitText)
    XCTAssertFalse(otherSession.canEnd)
    XCTAssertFalse(otherSession.commandCapabilities.supportsSteering)
    XCTAssertFalse(otherSession.commandCapabilities.supportsQueuedFollowUps)
    XCTAssertFalse(otherSession.commandCapabilities.supports(.agentLoop))
    XCTAssertFalse(otherSession.canRetryPendingCommand(kind: .send))

    let malformedRun = guiPolicy(
        execution: .running, currentRun: RunRef(""),
        ownerSession: guiPolicySessionA, ownerAttachment: guiPolicyAttachmentA,
        capabilities: granted)
    XCTAssertFalse(malformedRun.hasExactRunOwner)
    XCTAssertFalse(malformedRun.canSubmitText)
}

func testServiceBackedGUIControlPolicyWithholdsRecoveryAndCatchUp() {
    let granted: Set<WorkServiceCapability> = [
        .observe, .control, .send, .steer, .queue, .cancel, .end,
    ]
    for policy in [
        guiPolicy(
            execution: .running, currentRun: guiPolicyRun,
            ownerSession: guiPolicySessionA, ownerAttachment: guiPolicyAttachmentA,
            capabilities: granted, canonical: false),
        guiPolicy(
            execution: .running, currentRun: guiPolicyRun,
            ownerSession: guiPolicySessionA, ownerAttachment: guiPolicyAttachmentA,
            capabilities: granted, recovery: true),
        guiPolicy(
            execution: .running, currentRun: guiPolicyRun,
            ownerSession: guiPolicySessionA, ownerAttachment: guiPolicyAttachmentA,
            capabilities: granted, refresh: true),
    ] {
        XCTAssertTrue(policy.hasExactRunOwner)
        XCTAssertFalse(policy.canSubmitText)
        XCTAssertFalse(policy.canEnd)
        XCTAssertFalse(policy.commandCapabilities.supportsSteering)
        XCTAssertFalse(policy.commandCapabilities.supportsQueuedFollowUps)
        XCTAssertFalse(policy.commandCapabilities.supports(.agentLoop))
        XCTAssertFalse(policy.canRetryPendingCommand(kind: .send))
    }
}

func testServiceBackedGUIControlPolicyDistinguishesSettledAndNonActionableStates() {
    let granted: Set<WorkServiceCapability> = [
        .observe, .control, .send, .end,
    ]
    let settled = guiPolicy(
        execution: .idle, currentRun: guiPolicyRun,
        ownerSession: guiPolicySessionA, ownerAttachment: guiPolicyAttachmentA,
        capabilities: granted)
    XCTAssertFalse(settled.requiresStartForNextInput)
    XCTAssertTrue(settled.canSubmitText)
    XCTAssertTrue(settled.canEnd)

    for execution in [
        WorkServiceExecutionState.held, .canceling, .ending, .recoveryRequired, .unknown,
    ] {
        let policy = guiPolicy(
            execution: execution, currentRun: guiPolicyRun,
            ownerSession: guiPolicySessionA, ownerAttachment: guiPolicyAttachmentA,
            capabilities: granted)
        XCTAssertFalse(policy.canSubmitText)
        XCTAssertEqual(
            policy.canEnd,
            execution == .held || execution == .canceling)
    }
}

let casesServiceBackedGUIControlPolicy: [Case] = [
    ("phase3 GUI control policy routes first input to Start", {
        testServiceBackedGUIControlPolicyRoutesFirstInputToStart()
    }),
    ("phase3 GUI control policy qualifies same-Session controllers", {
        testServiceBackedGUIControlPolicyAllowsSameSessionGUIsAndRejectsOtherSession()
    }),
    ("phase3 GUI control policy withholds recovery and catch-up", {
        testServiceBackedGUIControlPolicyWithholdsRecoveryAndCatchUp()
    }),
    ("phase3 GUI control policy distinguishes settled and unavailable states", {
        testServiceBackedGUIControlPolicyDistinguishesSettledAndNonActionableStates()
    }),
]
