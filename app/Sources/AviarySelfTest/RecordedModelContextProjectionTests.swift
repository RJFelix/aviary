import Foundation
@testable import AviaryCore

private let projectionTestHost = WorkHostRef("projection-test-host")
private let projectionTestWork = WorkRef(
    workHostID: projectionTestHost.workHostID, workID: "projection-test-work")
private let projectionTestWorkJournal = JournalRef.work(
    projectionTestWork, journalID: "projection-test-work-journal")
private let projectionTestSession = SessionRef("projection-test-session")
private let projectionTestSessionJournal = JournalRef.session(
    projectionTestSession, journalID: "projection-test-session-journal",
    authority: TimelineAuthorityRef(projectionTestHost.workHostID))

func testRecordedModelContextProjectionFromSessionSnapshot() throws {
    let body = TimelineBodyReference(
        authority: projectionTestSessionJournal, referenceID: "body-1",
        mediaType: "text/plain", byteCount: 5, digest: "sha256:body")
    let component = ContextComponent(
        componentID: "context-component:system", inclusionID: "include-system",
        sourceID: "/private/workspace/AGENTS.md", mode: .pinned,
        deliveryMode: .truncated, measuredBytes: 100, includedBytes: 20,
        deliveredBytes: 20, fullByteCount: 100, bodyReference: body,
        digest: "sha256:prompt", omitted: false)
    let compactionSource = EventRef(
        journal: projectionTestSessionJournal, eventID: "compaction-source")
    let compactionComponent = ContextComponent(
        componentID: "context-component:compaction", inclusionID: "include-compaction",
        sourceID: "compaction-summary", sourceProvenance: compactionSource,
        mode: .compactionSummary, deliveryMode: .summary, measuredBytes: 42,
        includedBytes: 42, deliveredBytes: 42, fullByteCount: 42,
        digest: "sha256:" + String(repeating: "a", count: 64), omitted: false)
    let source = ContextManifestSource(
        sourceID: "/private/workspace/AGENTS.md", inclusionID: "prompt-1",
        kind: .contextFile, status: .present, label: "secret-token=do-not-display",
        fullByteCount: 100, fullDigest: "sha256:full", deliveredByteCount: 20,
        deliveredDigest: "sha256:delivered", renderedByteCount: 24,
        renderedDigest: "sha256:rendered", deliveredBodyReference: body)
    let manifest = ContextManifest(
        manifestID: "manifest-1", requestID: "request-1", modelID: "model-1",
        components: [component, compactionComponent], omissions: [ContextManifestOmission(
            omissionID: "omission-1", sourceID: "/private/workspace/AGENTS.md",
            reason: "prompt bound", measuredBytes: 100)],
        cumulativeDeliveredBytes: 20, systemPromptAssemblyID: "assembly-1",
        systemPromptSources: [source])
    var snapshot = SessionSnapshot()
    snapshot.session = projectionTestSession
    snapshot.contextManifest = manifest
    snapshot.contextComponents = [component, compactionComponent]
    snapshot.contextBoundaryEventID = "context-1"
    snapshot.compactionBoundaryEventID = "compact-1"
    snapshot.compactionSummary = "summary containing private material"
    snapshot.activeRun = RunRef("run-1")
    snapshot.contextCumulativeDeliveredBytesByRun = ["run-1": 20]

    let projection = RecordedModelContextProjection(snapshot)
    XCTAssertEqual(projection.availability, .observed)
    XCTAssertTrue(projection.manifestID?.hasPrefix("context-manifest-sha256:") == true)
    XCTAssertEqual(projection.components.count, 2)
    XCTAssertEqual(projection.components[0].bodyReference, body)
    XCTAssertEqual(projection.components[0].sourceID.hasPrefix("context-source-sha256:"), true)
    XCTAssertEqual(projection.sources?.count, 1)
    XCTAssertEqual(projection.sources?[0].label, "Context file")
    XCTAssertEqual(projection.cumulativeDeliveredBytes, 20)
    XCTAssertEqual(projection.compactionSummaryInspectionRequired, false)
    XCTAssertEqual(projection.compactionSummaryByteCount, 42)
    XCTAssertEqual(projection.compactionSummaryDigest, "sha256:" + String(repeating: "a", count: 64))
    XCTAssertTrue(projection.compactionBoundaryEventID?.hasPrefix("compaction-boundary-sha256:") == true)
    let encoded = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
    XCTAssertFalse(encoded.contains("secret-token=do-not-display"))
    XCTAssertFalse(encoded.contains("summary containing private material"))
    XCTAssertFalse(encoded.contains("/private/workspace/AGENTS.md"))
    XCTAssertFalse(encoded.contains("context-component:system"))
    XCTAssertFalse(encoded.contains("include-system"))
    XCTAssertFalse(encoded.contains("manifest-1"))
    XCTAssertFalse(encoded.contains("request-1"))
    XCTAssertFalse(encoded.contains("assembly-1"))
    XCTAssertFalse(encoded.contains("prompt bound"))

    var invalid = snapshot
    invalid.semanticProjectionValid = false
    let invalidProjection = RecordedModelContextProjection(invalid)
    XCTAssertEqual(invalidProjection.availability, .invalid)
    XCTAssertEqual(invalidProjection.components.count, 0)
    XCTAssertNil(invalidProjection.sources)
    XCTAssertNil(invalidProjection.contextBoundaryEventID)
    XCTAssertNil(invalidProjection.compactionBoundaryEventID)
    XCTAssertNil(invalidProjection.compactionSummaryByteCount)
    let invalidEncoded = String(
        decoding: try JSONEncoder().encode(invalidProjection), as: UTF8.self)
    XCTAssertFalse(invalidEncoded.contains("secret-token=do-not-display"))
    XCTAssertFalse(invalidEncoded.contains("body-1"))
    let incompleteSource = RecordedModelContextProjection(
        snapshot, sourceCompleteness: .incomplete)
    XCTAssertEqual(incompleteSource.availability, .invalid)
    XCTAssertEqual(incompleteSource.components.count, 0)
    XCTAssertEqual(RecordedModelContextProjection(SessionSnapshot()).availability, .unavailable)
}

func testCanonicalWorkingStateProjectionIsBoundedAndPrivate() throws {
    let workspace = try WorkHostWorkspaceID("workspace-12345678-1234-1234-1234-123456789abc")
    let attachment = SessionAttachmentRef("session-attachment")
    let clientAttachment = ClientAttachmentRef("client-attachment")
    let client = ClientRef("projection-client")
    let authorization = WorkServiceAuthorizationOutcome(
        requested: [], granted: [], denied: [])
    let serviceAttachment = WorkServiceClientAttachment(
        attachment: clientAttachment, client: client, session: projectionTestSession,
        sessionJournal: projectionTestSessionJournal, sessionAttachment: attachment,
        authorization: authorization)
    let workCursor = JournalCursor(journal: projectionTestWorkJournal, sequence: 3)
    let sessionCursor = JournalCursor(journal: projectionTestSessionJournal, sequence: 2)
    let relationship = WorkServiceSessionAttachmentDescriptor(
        session: projectionTestSession, sessionJournal: projectionTestSessionJournal,
        sessionAttachment: attachment, publication: .mirrored,
        causalSessionCursor: JournalCursor(journal: projectionTestSessionJournal, sequence: 0),
        sessionCursor: sessionCursor,
        causalWorkCursor: JournalCursor(journal: projectionTestWorkJournal, sequence: 1),
        resultingWorkCursor: workCursor, capabilities: [])
    let currentRun = RunRef("run-current")
    let artifact = try WorkServiceArtifactDescriptor(
        artifactID: "artifact-secret-name", work: projectionTestWork,
        label: "private artifact label", mediaType: "text/private-secret",
        sourceEvent: EventRef(journal: projectionTestWorkJournal, eventID: "artifact-source"),
        session: projectionTestSession, sessionAttachment: attachment, run: currentRun)
    let descriptor = try WorkServiceWorkDescriptor(
        work: projectionTestWork, journal: projectionTestWorkJournal,
        recordedDisposition: .reusable, execution: .running, currentRun: currentRun,
        currentRunSession: projectionTestSession, currentRunSessionAttachment: attachment,
        configuration: WorkServiceWorkConfiguration(workspaceID: workspace),
        hostObservation: nil, attachments: [serviceAttachment],
        sessionAttachments: [relationship], artifacts: [artifact])
    var work = WorkSnapshot()
    work.journal = projectionTestWorkJournal
    work.work = projectionTestWork
    work.workHost = projectionTestHost
    work.lifecycle = .active
    work.execution = .running
    work.lastSequence = workCursor.sequence
    work.lastEventID = "work-tip"
    work.activeRun = currentRun
    work.activeRunSession = projectionTestSession
    work.activeRunSessionAttachment = attachment
    work.attachedSessionIDs = [projectionTestSession.sessionID]
    work.sessionAttachments[attachment.attachmentID] = WorkSessionAttachmentSnapshot(
        attachment: attachment, session: projectionTestSession)
    work.observedRunIDs = ["run-1", currentRun.runID]
    work.handles = Dictionary(uniqueKeysWithValues: (0..<300).map {
        ("handle-\($0)", WorkHandleSnapshot(handle: HandleRef("handle-\($0)"), state: "running"))
    })
    work.childStates = Dictionary(uniqueKeysWithValues: (0..<300).map {
        ("child-\($0)", "running")
    })
    work.actions = Dictionary(uniqueKeysWithValues: (0..<300).map {
        let id = "action-\($0)"
        return (id, WorkActionSnapshot(
            action: ActionRef(id), state: .running, kind: .python,
            intent: "private action intent \($0)", target: "/private/path/\($0)"))
    })
    let recoveryCoverage = RecoveryCoverage(
        operation: .reattachLiveHost,
        planes: [.timeline: .preserved, .runtimeNamespace: .unknown],
        caveats: ["credential=do-not-display"])
    work.recovery = [recoveryCoverage]
    work.recordedRecovery = (0..<39).map { index in
        RecordedRecoveryCoverage(
            coverage: recoveryCoverage,
            sourceEvent: EventRef(
                journal: projectionTestWorkJournal, eventID: "recovery-work-\(index)"),
            session: projectionTestSession, work: projectionTestWork,
            workJournal: projectionTestWorkJournal, workHost: projectionTestHost,
            sessionAttachment: attachment, run: RunRef("run-1"))
    }
    work.recordedRecovery.append(RecordedRecoveryCoverage(
        coverage: recoveryCoverage,
        sourceEvent: EventRef(
            journal: projectionTestWorkJournal, eventID: "recovery-work-current"),
        session: projectionTestSession, work: projectionTestWork,
        workJournal: projectionTestWorkJournal, workHost: projectionTestHost,
        sessionAttachment: attachment, run: currentRun))
    var session = SessionSnapshot()
    session.journal = projectionTestSessionJournal
    session.session = projectionTestSession
    session.lifecycle = .active
    session.activeRun = currentRun
    session.lastSequence = sessionCursor.sequence
    session.lastEventID = "session-tip"
    session.attachments[attachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: attachment, work: projectionTestWork, cursor: workCursor)
    session.recordedRecovery = (0..<19).map { index in
        RecordedRecoveryCoverage(
            coverage: recoveryCoverage,
            sourceEvent: EventRef(
                journal: projectionTestSessionJournal, eventID: "recovery-session-\(index)"),
            session: projectionTestSession, work: projectionTestWork,
            workJournal: projectionTestWorkJournal, workHost: projectionTestHost,
            sessionAttachment: attachment, run: RunRef("run-1"))
    }
    session.recordedRecovery.append(RecordedRecoveryCoverage(
        coverage: recoveryCoverage,
        sourceEvent: EventRef(
            journal: projectionTestSessionJournal, eventID: "recovery-session-current"),
        session: projectionTestSession, work: projectionTestWork,
        workJournal: projectionTestWorkJournal, workHost: projectionTestHost,
        sessionAttachment: attachment, run: currentRun))
    let namespace = RuntimeHost.Namespace(bindings: (0..<300).map {
        RuntimeHost.Binding(
            name: "token-\($0)", type: "Secret", repr: "raw-secret-value-\($0)", length: nil)
    }, cwd: "/private/workspace")
    let project: (WorkServiceWorkDescriptor) -> CanonicalWorkingStateProjection = { candidate in
        CanonicalWorkingStateProjection(
            descriptor: candidate, attachment: serviceAttachment, workSnapshot: work,
            sessionSnapshot: session,
            workCursor: JournalCursor(
                journal: projectionTestWorkJournal, eventID: "work-tip",
                sequence: workCursor.sequence),
            sessionCursor: JournalCursor(
                journal: projectionTestSessionJournal, eventID: "session-tip",
                sequence: sessionCursor.sequence),
            workSourceCompleteness: .complete, sessionSourceCompleteness: .complete)
    }
    let projection = project(descriptor)
    XCTAssertEqual(projection.isCanonical, true)
    XCTAssertEqual(projection.canonicalityFailures, [])
    XCTAssertEqual(projection.actions.count, CanonicalWorkingStateProjection.maximumActions)
    XCTAssertEqual(projection.omittedActionCount, 44)
    XCTAssertEqual(projection.handles.count, CanonicalWorkingStateProjection.maximumHandles)
    XCTAssertEqual(projection.omittedHandleCount, 44)
    XCTAssertEqual(projection.children.count, CanonicalWorkingStateProjection.maximumChildren)
    XCTAssertEqual(projection.omittedChildCount, 44)
    XCTAssertEqual(projection.artifacts.count, 1)
    XCTAssertEqual(projection.namespace.availability, .notExposed)
    let namespaceProjection = CanonicalNamespaceMetadata(namespace)
    XCTAssertEqual(namespaceProjection.bindings.count, 256)
    XCTAssertEqual(namespaceProjection.omittedBindingCount, 44)
    XCTAssertEqual(namespaceProjection.cwdIdentityDigest != nil, true)
    XCTAssertEqual(namespaceProjection.bindings.first?.typeCategory, "object")
    XCTAssertTrue(namespaceProjection.bindings.first?.typeIdentityDigest.hasPrefix("sha256:") == true)
    XCTAssertEqual(projection.recovery.count, CanonicalWorkingStateProjection.maximumRecoveryClaims)
    XCTAssertEqual(projection.recovery[0].source, .workJournal)
    XCTAssertEqual(projection.recovery[0].sourceEvent.eventID, "recovery-work-current")
    XCTAssertEqual(projection.recovery[16].sourceEvent.eventID, "recovery-session-current")
    XCTAssertTrue(projection.recovery.contains { $0.sourceEvent.eventID == "recovery-work-38" })
    XCTAssertTrue(projection.recovery.contains { $0.sourceEvent.eventID == "recovery-session-18" })
    XCTAssertFalse(projection.recovery.contains { $0.sourceEvent.eventID == "recovery-work-0" })
    XCTAssertFalse(projection.recovery.contains { $0.sourceEvent.eventID == "recovery-session-0" })
    XCTAssertTrue(projection.recovery.contains { $0.source == .sessionJournal })
    XCTAssertEqual(projection.omittedWorkRecoveryCount, 24)
    XCTAssertEqual(projection.omittedSessionRecoveryCount, 4)
    XCTAssertEqual(projection.omittedRecoveryCount, 28)
    XCTAssertTrue(projection.recovery[0].sessionID.hasPrefix("recovery-session-sha256:"))
    XCTAssertTrue(projection.recovery[0].runID.hasPrefix("recovery-run-sha256:"))
    XCTAssertEqual(CanonicalWorkingHandle(
        WorkHandleSnapshot(handle: HandleRef("canceled"), state: "canceled")).state, .canceled)
    XCTAssertEqual(CanonicalWorkingHandle(
        WorkHandleSnapshot(handle: HandleRef("succeeded"), state: "succeeded")).state, .succeeded)
    XCTAssertEqual(CanonicalWorkingChild(id: "done", state: "done").state, .done)
    XCTAssertEqual(CanonicalWorkingChild(id: "completed", state: "completed").state, .unknown)
    let encoded = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
    XCTAssertFalse(encoded.contains("raw-secret-value"))
    XCTAssertFalse(encoded.contains("/private/workspace"))
    XCTAssertFalse(encoded.contains("private artifact label"))
    XCTAssertFalse(encoded.contains("text/private-secret"))
    XCTAssertFalse(encoded.contains("private-artifact-digest"))
    XCTAssertFalse(encoded.contains("private action intent"))
    XCTAssertFalse(encoded.contains("credential=do-not-display"))
    let namespaceEncoded = String(
        decoding: try JSONEncoder().encode(namespaceProjection), as: UTF8.self)
    XCTAssertFalse(namespaceEncoded.contains("Secret"))
    XCTAssertFalse(namespaceEncoded.contains("raw-secret-value"))

    let artifactOmittedDescriptor = try WorkServiceWorkDescriptor(
        work: projectionTestWork, journal: projectionTestWorkJournal,
        recordedDisposition: .reusable, execution: .running, currentRun: currentRun,
        currentRunSession: projectionTestSession, currentRunSessionAttachment: attachment,
        configuration: WorkServiceWorkConfiguration(workspaceID: workspace),
        hostObservation: nil, attachments: [serviceAttachment],
        sessionAttachments: [relationship], artifacts: [artifact], omissions: [
            WorkServiceOmission(category: "artifacts", count: 2),
            WorkServiceOmission(category: "artifact_metadata", count: 3),
        ])
    let artifactPartial = project(artifactOmittedDescriptor)
    XCTAssertTrue(artifactPartial.isCanonical)
    XCTAssertEqual(artifactPartial.lifecycle, .active)
    XCTAssertEqual(artifactPartial.artifactIndexCompleteness, .incomplete)
    XCTAssertEqual(artifactPartial.attachmentIndexCompleteness, .complete)
    XCTAssertEqual(artifactPartial.omittedArtifactCount, 2)
    XCTAssertEqual(artifactPartial.omittedArtifactMetadataCount, 3)

    let rowTruncatedArtifact = try WorkServiceArtifactDescriptor(
        artifactID: "artifact-row-truncated", work: projectionTestWork,
        label: "artifact", available: false, metadataWasTruncated: true,
        sourceEvent: EventRef(journal: projectionTestWorkJournal, eventID: "row-source"),
        session: projectionTestSession, sessionAttachment: attachment, run: currentRun)
    let rowTruncatedDescriptor = try WorkServiceWorkDescriptor(
        work: projectionTestWork, journal: projectionTestWorkJournal,
        recordedDisposition: .reusable, execution: .running, currentRun: currentRun,
        currentRunSession: projectionTestSession, currentRunSessionAttachment: attachment,
        configuration: WorkServiceWorkConfiguration(workspaceID: workspace),
        hostObservation: nil, attachments: [serviceAttachment],
        sessionAttachments: [relationship], artifacts: [rowTruncatedArtifact])
    let rowTruncatedProjection = project(rowTruncatedDescriptor)
    XCTAssertTrue(rowTruncatedProjection.isCanonical)
    XCTAssertEqual(rowTruncatedProjection.artifactIndexCompleteness, .incomplete)
    XCTAssertEqual(rowTruncatedProjection.omittedArtifactMetadataCount, 1)

    let unknownArtifactIndexDescriptor = try WorkServiceWorkDescriptor(
        work: projectionTestWork, journal: projectionTestWorkJournal,
        recordedDisposition: .reusable, execution: .running, currentRun: currentRun,
        currentRunSession: projectionTestSession, currentRunSessionAttachment: attachment,
        configuration: WorkServiceWorkConfiguration(workspaceID: workspace),
        hostObservation: nil, attachments: [serviceAttachment],
        sessionAttachments: [relationship], artifacts: [],
        omissions: [WorkServiceOmission(category: "artifact_index", count: 1)])
    let unknownArtifactIndex = project(unknownArtifactIndexDescriptor)
    XCTAssertTrue(unknownArtifactIndex.isCanonical)
    XCTAssertEqual(unknownArtifactIndex.artifactIndexCompleteness, .unknown)
    XCTAssertEqual(unknownArtifactIndex.omittedArtifactCount, 0)
    XCTAssertEqual(unknownArtifactIndex.unclassifiedDescriptorOmissionCount, 0)

    let attachmentsOmittedDescriptor = try WorkServiceWorkDescriptor(
        work: projectionTestWork, journal: projectionTestWorkJournal,
        recordedDisposition: .reusable, execution: .running, currentRun: currentRun,
        currentRunSession: projectionTestSession, currentRunSessionAttachment: attachment,
        configuration: WorkServiceWorkConfiguration(workspaceID: workspace),
        hostObservation: nil, attachments: [serviceAttachment],
        sessionAttachments: [relationship], artifacts: [artifact],
        omissions: [WorkServiceOmission(category: "attachments", count: 7)])
    let attachmentPartial = project(attachmentsOmittedDescriptor)
    XCTAssertTrue(attachmentPartial.isCanonical)
    XCTAssertEqual(attachmentPartial.artifactIndexCompleteness, .complete)
    XCTAssertEqual(attachmentPartial.attachmentIndexCompleteness, .incomplete)
    XCTAssertEqual(attachmentPartial.omittedAttachmentCount, 7)

    let futureOmissionDescriptor = try WorkServiceWorkDescriptor(
        work: projectionTestWork, journal: projectionTestWorkJournal,
        recordedDisposition: .reusable, execution: .running, currentRun: currentRun,
        currentRunSession: projectionTestSession, currentRunSessionAttachment: attachment,
        configuration: WorkServiceWorkConfiguration(workspaceID: workspace),
        hostObservation: nil, attachments: [serviceAttachment],
        sessionAttachments: [relationship], artifacts: [artifact],
        omissions: [WorkServiceOmission(category: "future_descriptor_plane", count: 4)])
    let futureOmission = project(futureOmissionDescriptor)
    XCTAssertTrue(futureOmission.isCanonical)
    XCTAssertEqual(futureOmission.lifecycle, .active)
    XCTAssertEqual(futureOmission.unclassifiedDescriptorCompleteness, .unknown)
    XCTAssertEqual(futureOmission.unclassifiedDescriptorOmissionCount, 4)

    let selectedAttachmentOmittedDescriptor = try WorkServiceWorkDescriptor(
        work: projectionTestWork, journal: projectionTestWorkJournal,
        recordedDisposition: .reusable, execution: .running, currentRun: currentRun,
        currentRunSession: projectionTestSession, currentRunSessionAttachment: attachment,
        configuration: WorkServiceWorkConfiguration(workspaceID: workspace),
        hostObservation: nil, attachments: [], sessionAttachments: [relationship],
        artifacts: [artifact],
        omissions: [WorkServiceOmission(category: "attachments", count: 1)])
    let selectedAttachmentOmitted = project(selectedAttachmentOmittedDescriptor)
    XCTAssertFalse(selectedAttachmentOmitted.isCanonical)
    XCTAssertTrue(
        selectedAttachmentOmitted.canonicalityFailures.contains(.reciprocalAttachmentMissing))

    let duplicateClientDescriptor = try WorkServiceWorkDescriptor(
        work: projectionTestWork, journal: projectionTestWorkJournal,
        recordedDisposition: .reusable, execution: .running, currentRun: currentRun,
        currentRunSession: projectionTestSession, currentRunSessionAttachment: attachment,
        configuration: WorkServiceWorkConfiguration(workspaceID: workspace),
        hostObservation: nil, attachments: [serviceAttachment, WorkServiceClientAttachment(
            attachment: clientAttachment, client: ClientRef("conflicting-client"),
            session: projectionTestSession, sessionJournal: projectionTestSessionJournal,
            sessionAttachment: attachment, authorization: authorization)],
        sessionAttachments: [relationship], artifacts: [artifact])
    XCTAssertFalse(project(duplicateClientDescriptor).isCanonical)

    let otherSession = SessionRef("conflicting-session")
    let otherJournal = JournalRef.session(
        otherSession, journalID: "conflicting-session-journal",
        authority: TimelineAuthorityRef(projectionTestHost.workHostID))
    let duplicateRelationshipDescriptor = try WorkServiceWorkDescriptor(
        work: projectionTestWork, journal: projectionTestWorkJournal,
        recordedDisposition: .reusable, execution: .running, currentRun: currentRun,
        currentRunSession: projectionTestSession, currentRunSessionAttachment: attachment,
        configuration: WorkServiceWorkConfiguration(workspaceID: workspace),
        hostObservation: nil, attachments: [serviceAttachment], sessionAttachments: [
            relationship,
            WorkServiceSessionAttachmentDescriptor(
                session: otherSession, sessionJournal: otherJournal,
                sessionAttachment: attachment, publication: .mirrored,
                causalSessionCursor: JournalCursor(journal: otherJournal, sequence: 0),
                sessionCursor: JournalCursor(journal: otherJournal, sequence: 1),
                causalWorkCursor: JournalCursor(
                    journal: projectionTestWorkJournal, sequence: 1),
                resultingWorkCursor: workCursor, capabilities: []),
        ], artifacts: [artifact])
    XCTAssertFalse(project(duplicateRelationshipDescriptor).isCanonical)

    var unrelatedSession = session
    unrelatedSession.attachments.removeAll()
    let unjoined = CanonicalWorkingStateProjection(
        descriptor: descriptor, attachment: serviceAttachment, workSnapshot: work,
        sessionSnapshot: unrelatedSession,
        workCursor: JournalCursor(
            journal: projectionTestWorkJournal, eventID: "work-tip", sequence: workCursor.sequence),
        sessionCursor: JournalCursor(
            journal: projectionTestSessionJournal, eventID: "session-tip", sequence: sessionCursor.sequence),
        workSourceCompleteness: .complete, sessionSourceCompleteness: .complete)
    XCTAssertFalse(unjoined.isCanonical)
    XCTAssertEqual(unjoined.recovery.count, 0)

    let incomplete = CanonicalWorkingStateProjection(
        descriptor: descriptor, attachment: serviceAttachment, workSnapshot: work,
        sessionSnapshot: session,
        workCursor: JournalCursor(
            journal: projectionTestWorkJournal, eventID: "work-tip", sequence: workCursor.sequence),
        sessionCursor: JournalCursor(
            journal: projectionTestSessionJournal, eventID: "session-tip", sequence: sessionCursor.sequence),
        workSourceCompleteness: .incomplete, sessionSourceCompleteness: .complete)
    XCTAssertFalse(incomplete.isCanonical)
    XCTAssertEqual(incomplete.lifecycle, .unknown)
    XCTAssertEqual(incomplete.execution, .unknown)
    XCTAssertEqual(incomplete.actions.count, 0)
    XCTAssertEqual(incomplete.handles.count, 0)
    XCTAssertEqual(incomplete.recovery.count, 0)
    XCTAssertEqual(incomplete.namespace.availability, .unavailable)
}

let casesRecordedModelContextProjection: [Case] = [
    ("phase2 context inspector: recorded provider crossing is metadata only", {
        try testRecordedModelContextProjectionFromSessionSnapshot()
    }),
    ("phase2 context inspector: canonical working state is bounded and private", {
        try testCanonicalWorkingStateProjectionIsBoundedAndPrivate()
    }),
]
