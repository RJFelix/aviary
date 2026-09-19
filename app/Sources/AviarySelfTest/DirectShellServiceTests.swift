import Foundation
@testable import AviaryCore

private struct DirectShellServiceFixture {
    let work = WorkRef(workHostID: "direct-shell-host", workID: "direct-shell-work")
    let client = ClientRef("direct-shell-client")
    let attachment = ClientAttachmentRef("direct-shell-client-attachment")
    let sessionAttachment = SessionAttachmentRef("direct-shell-session-attachment")
    let run = RunRef("direct-shell-run")
    let cursor: JournalCursor
    let host: WorkHostInstanceRef

    init() {
        cursor = JournalCursor(
            journal: .work(work), eventID: "direct-shell-causal-event", sequence: 4)
        host = WorkHostInstanceRef(
            host: WorkHostRef(work.workHostID), instanceID: "direct-shell-instance",
            startIdentity: "direct-shell-start")
    }

    func request(
        operation: WorkServiceDirectShellOperation = .inspect,
        commandID: String = "direct-shell-command",
        language: DirectShellLanguage? = nil,
        source: Data? = nil,
        action: ActionRef? = nil
    ) -> WorkServiceDirectShellRequest {
        WorkServiceDirectShellRequest(
            work: work, journal: .work(work), attachment: attachment,
            command: CommandRef(
                commandID: commandID, client: client,
                sessionAttachment: sessionAttachment, causalCursor: cursor),
            causalWorkCursor: cursor, run: run, operation: operation,
            language: language, source: source, action: action)
    }

    func authorization(
        _ granted: Set<WorkServiceCapability> = [.observe, .inspectArtifacts]
    ) -> WorkServiceAuthorizationOutcome {
        WorkServiceAuthorizationOutcome(
            requested: granted, granted: granted, denied: [])
    }

    func response(
        request: WorkServiceDirectShellRequest,
        commandID: String? = nil,
        authorization: WorkServiceAuthorizationOutcome? = nil
    ) -> WorkServiceDirectShellResponse {
        WorkServiceDirectShellResponse(
            work: work, operation: request.operation,
            commandID: commandID ?? request.command.commandID, host: host,
            causalWorkCursor: request.causalWorkCursor,
            resultingWorkCursor: JournalCursor(
                journal: request.journal, eventID: "direct-shell-result-event", sequence: 5),
            authorization: authorization ?? self.authorization(),
            disposition: .accepted, entries: [])
    }
}

let casesDirectShellService: [Case] = [
    ("Direct shell service DTO: exact request and response round trip", {
        let fixture = DirectShellServiceFixture()
        let request = fixture.request()
        let decodedRequest = try JSONDecoder().decode(
            WorkServiceDirectShellRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decodedRequest, request)
        try decodedRequest.validate()

        let response = fixture.response(request: request)
        let decodedResponse = try JSONDecoder().decode(
            WorkServiceDirectShellResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decodedResponse, response)
        try decodedResponse.validate(for: decodedRequest)
    }),
    ("Direct shell service DTO: response identity and authorization correlate", {
        let fixture = DirectShellServiceFixture()
        let request = fixture.request()
        do {
            try fixture.response(request: request, commandID: "another-command")
                .validate(for: request)
            XCTFail("a response for another command must not correlate")
        } catch WorkServiceProtocolError.invalidRequest { /* expected */ }

        let insufficient = WorkServiceAuthorizationOutcome(
            requested: [.observe], granted: [.observe], denied: [])
        do {
            try fixture.response(request: request, authorization: insufficient)
                .validate(for: request)
            XCTFail("Inspect requires both observe and artifact-inspection authority")
        } catch WorkServiceProtocolError.invalidRequest { /* expected */ }
    }),
    ("Direct shell service DTO: malformed execution input fails closed", {
        let fixture = DirectShellServiceFixture()
        let malformedSources = [
            Data(),
            Data([0x66, 0x00, 0x6f]),
            Data([0xff, 0xfe]),
            Data(repeating: 0x61, count: DirectShellCommandRequest.maximumSourceBytes + 1),
        ]
        for (index, source) in malformedSources.enumerated() {
            do {
                try fixture.request(
                    operation: .run, commandID: "malformed-\(index)",
                    language: .sh, source: source).validate()
                XCTFail("malformed source \(index) must fail validation")
            } catch WorkServiceProtocolError.invalidRequest { /* expected */ }
        }
    }),
    ("Direct shell service: terminal outcome mapping is exact", {
        XCTAssertTrue(DirectShellCommandCanonicalValidation.outcomeMatches(
            .exited(exitCode: 0), state: .succeeded, failureKind: nil))
        XCTAssertTrue(DirectShellCommandCanonicalValidation.outcomeMatches(
            .nonzero(exitCode: 3), state: .failed, failureKind: .task))
        XCTAssertTrue(DirectShellCommandCanonicalValidation.outcomeMatches(
            .signaled(signal: 9), state: .failed, failureKind: .infrastructure))
        XCTAssertTrue(DirectShellCommandCanonicalValidation.outcomeMatches(
            .launchFailed(message: "launch"), state: .failed, failureKind: .infrastructure))
        XCTAssertTrue(DirectShellCommandCanonicalValidation.outcomeMatches(
            .invalidRequest(message: "invalid"), state: .failed, failureKind: .policy))
        XCTAssertTrue(DirectShellCommandCanonicalValidation.outcomeMatches(
            .timedOut, state: .failed, failureKind: .timeout))
        XCTAssertTrue(DirectShellCommandCanonicalValidation.outcomeMatches(
            .canceled, state: .canceled, failureKind: .cancellation))
        XCTAssertFalse(DirectShellCommandCanonicalValidation.outcomeMatches(
            .timedOut, state: .canceled, failureKind: .cancellation))
        XCTAssertFalse(DirectShellCommandCanonicalValidation.outcomeMatches(
            .canceled, state: .failed, failureKind: .task))
        XCTAssertFalse(DirectShellCommandCanonicalValidation.outcomeMatches(
            .workerFailed(message: "indeterminate"), state: .failed,
            failureKind: .task))
    }),
    ("Direct shell service DTO: result bytes are bound to the artifact", {
        let fixture = DirectShellServiceFixture()
        let source = Data("printf artifact".utf8)
        let qualifiedID = WorkServiceCommandLedgerIdentity.commandID(
            client: fixture.client, commandID: "artifact-command")
        let action = DirectShellJournalFormat.action(commandID: qualifiedID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aviary-direct-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await DirectShellCommandWorker(request: DirectShellCommandRequest(
            commandID: qualifiedID, actionID: action.actionID, language: .sh,
            source: source, workingDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"])).wait()
        try result.validate()
        let body = try DirectShellJournalFormat.encoded(result)
        let digest = "sha256:" + AviarySHA256.hash(data: body).map {
            String(format: "%02x", $0)
        }.joined()
        let sourceEvent = EventRef(
            journal: .work(fixture.work), eventID: "artifact-published")
        let reference = TimelineBodyReference(
            authority: .work(fixture.work), referenceID: digest,
            mediaType: DirectShellJournalFormat.resultMediaType,
            byteCount: body.count, digest: digest)
        let artifact = try WorkServiceArtifactDescriptor(
            artifactID: action.actionID + "-output", work: fixture.work,
            label: DirectShellCommandCanonicalValidation.artifactLabel,
            mediaType: DirectShellJournalFormat.resultMediaType,
            byteCount: body.count, digest: digest, available: true,
            bodyReference: reference, sourceEvent: sourceEvent,
            session: SessionRef("artifact-session"),
            sessionAttachment: fixture.sessionAttachment, run: fixture.run,
            action: action, causedByEventID: sourceEvent)
        let command = CommandRef(
            commandID: qualifiedID, client: fixture.client,
            sessionAttachment: fixture.sessionAttachment, causalCursor: fixture.cursor)
        let valid = WorkServiceDirectShellEntry(
            command: command, session: SessionRef("artifact-session"),
            sessionAttachment: fixture.sessionAttachment, run: fixture.run, action: action,
            language: .sh, source: source, state: .succeeded, result: result,
            artifact: artifact, pendingContext: true)
        try valid.validate(work: fixture.work, journal: .work(fixture.work))

        let wrongDigest = "sha256:" + String(repeating: "0", count: 64)
        let alteredReference = TimelineBodyReference(
            authority: .work(fixture.work), referenceID: "altered-result-body",
            mediaType: DirectShellJournalFormat.resultMediaType,
            byteCount: body.count, digest: wrongDigest)
        let alteredArtifact = try WorkServiceArtifactDescriptor(
            artifactID: "altered-result", work: fixture.work, label: "Command output",
            mediaType: DirectShellJournalFormat.resultMediaType,
            byteCount: body.count, digest: wrongDigest, available: true,
            bodyReference: alteredReference, sourceEvent: sourceEvent,
            session: SessionRef("artifact-session"),
            sessionAttachment: fixture.sessionAttachment, run: fixture.run,
            action: action, causedByEventID: sourceEvent)
        let altered = WorkServiceDirectShellEntry(
            command: command, session: SessionRef("artifact-session"),
            sessionAttachment: fixture.sessionAttachment, run: fixture.run, action: action,
            language: .sh, source: source, state: .succeeded, result: result,
            artifact: alteredArtifact, pendingContext: true)
        do {
            try altered.validate(work: fixture.work, journal: .work(fixture.work))
            XCTFail("wire-altered artifact metadata must not authenticate the result")
        } catch WorkServiceProtocolError.invalidRequest { /* expected */ }

        let mismatchedReference = TimelineBodyReference(
            authority: .work(fixture.work), referenceID: "not-the-body-digest",
            mediaType: DirectShellJournalFormat.resultMediaType,
            byteCount: body.count, digest: digest)
        let mismatchedArtifact = try WorkServiceArtifactDescriptor(
            artifactID: action.actionID + "-output", work: fixture.work,
            label: DirectShellCommandCanonicalValidation.artifactLabel,
            mediaType: DirectShellJournalFormat.resultMediaType,
            byteCount: body.count, digest: digest, available: true,
            bodyReference: mismatchedReference, sourceEvent: sourceEvent,
            session: SessionRef("artifact-session"),
            sessionAttachment: fixture.sessionAttachment, run: fixture.run,
            action: action, causedByEventID: sourceEvent)
        let mismatched = WorkServiceDirectShellEntry(
            command: command, session: SessionRef("artifact-session"),
            sessionAttachment: fixture.sessionAttachment, run: fixture.run, action: action,
            language: .sh, source: source, state: .succeeded, result: result,
            artifact: mismatchedArtifact, pendingContext: true)
        do {
            try mismatched.validate(work: fixture.work, journal: .work(fixture.work))
            XCTFail("an artifact reference ID must equal its digest")
        } catch WorkServiceProtocolError.invalidRequest { /* expected */ }
    }),
]
