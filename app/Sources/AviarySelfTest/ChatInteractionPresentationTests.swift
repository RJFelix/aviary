import AviaryCore

let casesChatInteractionPresentation: [Case] = [
    ("chat interaction: delivery choice preserves capabilities and explains timing", {
        XCTAssertEqual(ChatBusyDelivery.available(supportsGuidance: false, supportsFollowUp: false), [])
        XCTAssertEqual(ChatBusyDelivery.available(supportsGuidance: true, supportsFollowUp: false), [.guideCurrentWork])
        XCTAssertEqual(ChatBusyDelivery.available(supportsGuidance: false, supportsFollowUp: true), [.followUp])
        XCTAssertEqual(ChatBusyDelivery.available(supportsGuidance: true, supportsFollowUp: true), [.followUp, .guideCurrentWork])
        XCTAssertTrue(ChatBusyDelivery.guideCurrentWork.explanation.contains("does not interrupt"))
        XCTAssertTrue(ChatBusyDelivery.followUp.explanation.contains("separate message"))
        XCTAssertEqual(ChatBusyDelivery.afterSubmission(submitted: .guideCurrentWork, current: .guideCurrentWork, handedOff: true), .followUp)
        XCTAssertEqual(ChatBusyDelivery.afterSubmission(submitted: .guideCurrentWork, current: .guideCurrentWork, handedOff: false), .guideCurrentWork)
        XCTAssertEqual(ChatBusyDelivery.afterSubmission(submitted: .followUp, current: .guideCurrentWork, handedOff: true), .guideCurrentWork)
    }),
    ("chat interaction: state copy never equates termination with success", {
        XCTAssertEqual(ChatInteractionPresentation.stateLabel(.idle), "Ready")
        XCTAssertEqual(ChatInteractionPresentation.stateLabel(.running), "Working")
        XCTAssertEqual(ChatInteractionPresentation.stateLabel(.failed), "Needs attention")
        XCTAssertEqual(ChatInteractionPresentation.stateLabel(.ended), "Agent session ended")
        XCTAssertEqual(ChatInteractionPresentation.stateLabel(.canceling), "Stopping after current step")
        XCTAssertTrue(ChatInteractionPresentation.stopExplanation.contains("may finish first"))
    }),
]
