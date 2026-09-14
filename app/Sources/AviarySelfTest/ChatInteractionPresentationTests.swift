import AviaryCore

let casesChatInteractionPresentation: [Case] = [
    ("chat interaction: status hierarchy preserves every source and prioritizes uncertainty", {
        typealias Item = ChatStatusPresentation.Item
        let entries: [Item] = [
            .init(source: .stopReceipt, tone: .information, title: "Stop delivered", message: "Exact stop receipt"),
            .init(source: .projectionLimits, tone: .information, title: "Limits", message: "Partial history"),
            .init(source: .command, tone: .uncertain, title: "Unknown delivery", message: "Do not resend"),
            .init(source: .chatError, tone: .danger, title: "Error", message: "Exact error"),
            .init(source: .project, tone: .warning, title: "Project", message: "Confirm folder"),
            .init(source: .inputDeliveryLimits, tone: .warning, title: "Input limits", message: "Partial history")
        ]
        let result = ChatStatusPresentation(items: entries)
        XCTAssertEqual(result.primary?.source, .command)
        XCTAssertEqual(result.primary?.symbol, "questionmark.circle.fill")
        XCTAssertEqual(result.attentionCount, 4)
        XCTAssertEqual(result.items.count, 6)
        XCTAssertEqual(result.items.map(\.source), [.command, .chatError, .project, .inputDeliveryLimits, .stopReceipt, .projectionLimits])
        for entry in entries { XCTAssertTrue(result.items.contains(entry)) }
        XCTAssertEqual(ChatStatusPresentation(items: Array(entries.reversed())).items, result.items)
        XCTAssertEqual(entries[0].message, "Exact stop receipt")
    }),
    ("chat interaction: receipt success cannot hide warning or missing evidence", {
        let result = ChatStatusPresentation(items: [
            .init(source: .command, tone: .success, title: "Acknowledged", message: "Receipt only"),
            .init(source: .projectionLimits, tone: .information, title: "Partial", message: "Unknowns remain"),
            .init(source: .inputDeliveryLimits, tone: .warning, title: "Delivery incomplete", message: "Do not infer retry safety")
        ])
        XCTAssertEqual(result.primary?.source, .inputDeliveryLimits)
        XCTAssertEqual(result.items.last?.source, .projectionLimits)
        XCTAssertEqual(result.attentionCount, 1)
        let empty = ChatStatusPresentation(items: [])
        XCTAssertNil(empty.primary)
        XCTAssertEqual(empty.attentionCount, 0)
        let receipt = ChatStatusPresentation(items: result.items.filter { $0.source != .inputDeliveryLimits })
        XCTAssertEqual(receipt.primary?.tone, .success)
        XCTAssertEqual(receipt.attentionCount, 0)
        let stopped = ChatStatusPresentation(items: [
            .init(source: .projectionLimits, tone: .information, title: "Partial", message: "Unknowns remain"),
            .init(source: .stopReceipt, tone: .information, title: "Stop request delivered", message: "Receipt only")
        ])
        XCTAssertEqual(stopped.primary?.source, .stopReceipt)
        let subsequent = ChatStatusPresentation(items: stopped.items + [
            .init(source: .command, tone: .success, title: "Acknowledged", message: "Later receipt")
        ])
        XCTAssertEqual(subsequent.primary?.source, .command)
    }),
    ("chat interaction: delivery choice preserves capabilities and explains timing", {
        XCTAssertEqual(ChatBusyDelivery.available(supportsGuidance: false, supportsFollowUp: false), [])
        XCTAssertEqual(ChatBusyDelivery.available(supportsGuidance: true, supportsFollowUp: false), [.guideCurrentWork])
        XCTAssertEqual(ChatBusyDelivery.available(supportsGuidance: false, supportsFollowUp: true), [.followUp])
        XCTAssertEqual(ChatBusyDelivery.available(supportsGuidance: true, supportsFollowUp: true), [.followUp, .guideCurrentWork])
        XCTAssertEqual(ChatBusyDelivery.followUp.label, "Follow-up message")
        XCTAssertEqual(ChatBusyDelivery.guideCurrentWork.symbol, "arrow.turn.down.right")
        XCTAssertEqual(ChatBusyDelivery.followUp.symbol, "text.append")
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
    ("chat interaction: composer status preserves uncertain handoff precedence", {
        let unresolved = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: true,
            persistenceNotice: "A less specific persistence warning",
            commandInFlight: true,
            commandState: .ended,
            hasExited: true,
            acceptsInput: true,
            isStreaming: false,
            availableDeliveries: [.followUp],
            effectiveDelivery: .followUp,
            draftIsEmpty: false)
        XCTAssertEqual(unresolved.kind, .blocked)
        XCTAssertEqual(unresolved.symbol, "exclamationmark.triangle.fill")
        XCTAssertTrue(unresolved.text.contains("Delivery needs checking"))
        XCTAssertTrue(unresolved.text.contains("will not be sent again automatically"))

        let inFlight = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: false,
            persistenceNotice: "A less specific persistence warning",
            commandInFlight: true,
            commandState: .ended,
            hasExited: true,
            acceptsInput: true,
            isStreaming: false,
            availableDeliveries: [.followUp],
            effectiveDelivery: .followUp,
            draftIsEmpty: false)
        XCTAssertEqual(inFlight.kind, .blocked)
        XCTAssertEqual(inFlight.symbol, "hourglass")
        XCTAssertTrue(inFlight.text.contains("confirm receipt"))
        XCTAssertTrue(inFlight.text.contains("will not send another copy"))
    }),
    ("chat interaction: composer status explains exact blockers before delivery hints", {
        let ended = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: false, persistenceNotice: nil,
            commandInFlight: false, commandState: .ended, hasExited: true,
            acceptsInput: true, isStreaming: false,
            availableDeliveries: [.followUp], effectiveDelivery: .followUp,
            draftIsEmpty: false)
        XCTAssertEqual(ended.kind, .blocked)
        XCTAssertTrue(ended.text.contains("session has ended"))

        let endingFlag = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: false, persistenceNotice: nil,
            commandInFlight: false, commandState: .idle, hasExited: false,
            isEnding: true, acceptsInput: true, isStreaming: false,
            availableDeliveries: [], effectiveDelivery: nil,
            draftIsEmpty: false)
        XCTAssertEqual(endingFlag.kind, .blocked)
        XCTAssertTrue(endingFlag.text.contains("session is ending"))

        let canceling = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: false, persistenceNotice: nil,
            commandInFlight: false, commandState: .canceling, hasExited: false,
            acceptsInput: true, isStreaming: true,
            availableDeliveries: [.followUp], effectiveDelivery: .followUp,
            draftIsEmpty: false)
        XCTAssertEqual(canceling.kind, .blocked)
        XCTAssertTrue(canceling.text.contains("stopping after its current step"))

        let noRoute = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: false, persistenceNotice: nil,
            commandInFlight: false, commandState: .running, hasExited: false,
            acceptsInput: false, isStreaming: true,
            availableDeliveries: [], effectiveDelivery: nil,
            draftIsEmpty: false)
        XCTAssertEqual(noRoute.kind, .blocked)
        XCTAssertTrue(noRoute.text.contains("No message route"))

        let admissionDeniedDespiteRoute = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: false, persistenceNotice: nil,
            commandInFlight: false, commandState: .running, hasExited: false,
            acceptsInput: false, isStreaming: true,
            availableDeliveries: [.followUp], effectiveDelivery: .followUp,
            draftIsEmpty: false)
        XCTAssertEqual(admissionDeniedDespiteRoute.kind, .blocked)
        XCTAssertTrue(admissionDeniedDespiteRoute.text.contains("current recorded state"))
        XCTAssertFalse(admissionDeniedDespiteRoute.text.contains("separate message"))
    }),
    ("chat interaction: composer status distinguishes information from admission", {
        let persistence = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: false,
            persistenceNotice: "Private draft storage is unavailable.",
            commandInFlight: false, commandState: .idle, hasExited: false,
            acceptsInput: true, isStreaming: false,
            availableDeliveries: [], effectiveDelivery: nil,
            draftIsEmpty: true)
        XCTAssertEqual(persistence.kind, .information)
        XCTAssertEqual(persistence.text, "Private draft storage is unavailable.")

        let empty = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: false, persistenceNotice: nil,
            commandInFlight: false, commandState: .idle, hasExited: false,
            acceptsInput: true, isStreaming: false,
            availableDeliveries: [], effectiveDelivery: nil,
            draftIsEmpty: true)
        XCTAssertEqual(empty.kind, .information)
        XCTAssertEqual(empty.symbol, "pencil")

        let guidance = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: false, persistenceNotice: nil,
            commandInFlight: false, commandState: .running, hasExited: false,
            acceptsInput: true, isStreaming: true,
            availableDeliveries: [.followUp, .guideCurrentWork],
            effectiveDelivery: .guideCurrentWork,
            draftIsEmpty: false)
        XCTAssertEqual(guidance.kind, .information)
        XCTAssertEqual(guidance.symbol, ChatBusyDelivery.guideCurrentWork.symbol)
        XCTAssertEqual(guidance.text, ChatBusyDelivery.guideCurrentWork.explanation)

        let mismatchedSelection = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: false, persistenceNotice: nil,
            commandInFlight: false, commandState: .running, hasExited: false,
            acceptsInput: true, isStreaming: true,
            availableDeliveries: [.followUp], effectiveDelivery: .guideCurrentWork,
            draftIsEmpty: false)
        XCTAssertEqual(mismatchedSelection.kind, .blocked)
        XCTAssertTrue(mismatchedSelection.text.contains("Choose where"))

        let malformedRouteBeatsPersistence = ChatComposerStatusPresentation.resolve(
            hasUnresolvedDraftHandoff: false,
            persistenceNotice: "Private draft storage is unavailable.",
            commandInFlight: false, commandState: .running, hasExited: false,
            acceptsInput: true, isStreaming: true,
            availableDeliveries: [], effectiveDelivery: nil,
            draftIsEmpty: true)
        XCTAssertEqual(malformedRouteBeatsPersistence.kind, .blocked)
        XCTAssertTrue(malformedRouteBeatsPersistence.text.contains("No message route"))
        XCTAssertFalse(malformedRouteBeatsPersistence.text.contains("storage"))
    }),
    ("chat interaction: stale service header is static and qualified", {
        let local = ChatRunHeaderStatusPresentation.resolve(
            commandState: .running, isStreaming: true, hasExited: false,
            isServiceBacked: false, serviceSourceIsCurrent: false)
        XCTAssertEqual(local.label, "Working")
        XCTAssertTrue(local.showsPulse)
        XCTAssertFalse(local.isNeutral)

        let currentService = ChatRunHeaderStatusPresentation.resolve(
            commandState: .running, isStreaming: true, hasExited: false,
            isServiceBacked: true, serviceSourceIsCurrent: true)
        XCTAssertEqual(currentService.label, "Working")
        XCTAssertTrue(currentService.showsPulse)
        XCTAssertFalse(currentService.isNeutral)

        let staleService = ChatRunHeaderStatusPresentation.resolve(
            commandState: .running, isStreaming: true, hasExited: false,
            isServiceBacked: true, serviceSourceIsCurrent: false)
        XCTAssertEqual(staleService.label, "Last recorded: Working")
        XCTAssertEqual(staleService.symbol, "clock")
        XCTAssertFalse(staleService.showsPulse)
        XCTAssertTrue(staleService.isNeutral)

        let staleEndedService = ChatRunHeaderStatusPresentation.resolve(
            commandState: .ended, isStreaming: false, hasExited: true,
            isServiceBacked: true, serviceSourceIsCurrent: false)
        XCTAssertEqual(staleEndedService.label, "Last recorded: Agent session ended")
        XCTAssertFalse(staleEndedService.showsPulse)
        XCTAssertTrue(staleEndedService.isNeutral)
    }),
]
