import Foundation
@testable import AviaryCore

private enum CatalogTestError: Error { case unsupported }

private actor CatalogTestConnection: WorkServiceClientConnection {
    let response: WorkServiceHandshakeResponse
    let first: WorkServiceWorkPage
    let later: [String: WorkServiceWorkPage]
    var closed = false

    init(response: WorkServiceHandshakeResponse, first: WorkServiceWorkPage,
         later: [String: WorkServiceWorkPage] = [:]) {
        self.response = response
        self.first = first
        self.later = later
    }

    func close() { closed = true }
    func handshake(_ request: WorkServiceHandshakeRequest) async throws -> WorkServiceHandshakeResponse {
        response
    }
    func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage {
        if let token = request.pageToken { return later[token] ?? first }
        return first
    }
    func describeWork(_ request: WorkServiceDescribeRequest) async throws -> WorkServiceWorkDescriptor { throw CatalogTestError.unsupported }
    func createWork(_ request: WorkServiceCreateWorkRequest) async throws -> WorkServiceCreateWorkResponse { throw CatalogTestError.unsupported }
    func completeWork(_ request: WorkServiceCompleteWorkRequest) async throws -> WorkServiceCommandReceipt { throw CatalogTestError.unsupported }
    func attach(_ request: WorkServiceAttachRequest) async throws -> WorkServiceAttachResponse { throw CatalogTestError.unsupported }
    func detach(_ request: WorkServiceDetachRequest) async throws -> WorkServiceDetachResponse { throw CatalogTestError.unsupported }
    func updateCapabilities(_ request: WorkServiceUpdateCapabilitiesRequest) async throws -> WorkServiceUpdateCapabilitiesResponse { throw CatalogTestError.unsupported }
    func acknowledgeRead(_ request: WorkServiceAcknowledgeReadRequest) async throws -> WorkServiceAcknowledgeReadResponse { throw CatalogTestError.unsupported }
    func snapshot(_ request: WorkServiceSnapshotRequest) async throws -> WorkServiceSnapshot { throw CatalogTestError.unsupported }
    func eventsAfterCursor(_ request: WorkServiceEventsRequest) async throws -> WorkServiceEventPage { throw CatalogTestError.unsupported }
    func fetchArtifact(_ request: WorkServiceArtifactRequest) async throws -> WorkServiceArtifactDescriptor { throw CatalogTestError.unsupported }
    func fetchBody(_ request: WorkServiceBodyRequest) async throws -> WorkServiceBodyResponse { throw CatalogTestError.unsupported }
    func command(_ request: WorkServiceCommandRequest) async throws -> WorkServiceCommandReceipt { throw CatalogTestError.unsupported }
}

private struct CatalogTestLocator: WorkServiceHostLocating {
    let location: WorkServiceHostLocation?
    func locate() async throws -> WorkServiceHostLocation? { location }
}

private func catalogTestJournal(_ work: WorkRef, suffix: String = "journal") throws -> JournalRef {
    try JournalRef(
        journalID: "\(work.workID)-\(suffix)", authority: TimelineAuthorityRef(work.workHostID),
        owner: .work(work))
}

private func catalogTestDescriptor(
    host: WorkHostRef, id: String, journal: JournalRef? = nil,
    observation: WorkServiceHostObservation? = nil
) throws -> WorkServiceWorkDescriptor {
    let work = WorkRef(workHostID: host.workHostID, workID: id)
    return WorkServiceWorkDescriptor(
        work: work, journal: try journal ?? catalogTestJournal(work),
        recordedDisposition: .reusable, execution: .idle, currentRun: nil,
        hostObservation: observation)
}

private func catalogTestSession(
    host: WorkHostRef, instance: WorkHostInstanceRef,
    pages: WorkServiceWorkPage, later: [String: WorkServiceWorkPage] = [:]
) throws -> WorkServiceClientSession {
    let client = ClientRef("catalog-client-\(host.workHostID)")
    let endpoint = WorkServiceTransportEndpoint(path: "/tmp/catalog-\(host.workHostID).sock")
    let location = WorkServiceHostLocation(
        host: host, expectedInstance: instance,
        protocolVersion: WorkServiceProtocol.currentVersion,
        transport: .unixSocket(endpoint))
    let response = WorkServiceHandshakeResponse(
        accepted: true, negotiatedVersion: WorkServiceProtocol.currentVersion,
        supportedRange: WorkServiceProtocol.minimumSupportedVersion ... WorkServiceProtocol.maximumSupportedVersion,
        host: host, hostInstance: instance,
        controlJournal: try JournalRef(
            journalID: "control-\(host.workHostID)", authority: TimelineAuthorityRef(host.workHostID),
            owner: .workHost(host)),
        controlCursor: JournalCursor(
            journal: try JournalRef(
                journalID: "control-\(host.workHostID)", authority: TimelineAuthorityRef(host.workHostID),
                owner: .workHost(host)), sequence: 0),
        capabilities: [.observe])
    let connection = CatalogTestConnection(response: response, first: pages, later: later)
    return try WorkServiceClientSession(
        locator: CatalogTestLocator(location: location), client: client,
        connectionFactory: { _, _ in connection })
}

func testWorkServiceCatalogRefreshesHostsConcurrentlyAndIsolatesUnavailable() async throws {
    let hostA = WorkHostRef("catalog-host-a")
    let instanceA = WorkHostInstanceRef(host: hostA, instanceID: "a-instance", startIdentity: "a-start")
    let workA = try catalogTestDescriptor(host: hostA, id: "work-2")
    let sessionA = try catalogTestSession(
        host: hostA, instance: instanceA,
        pages: WorkServiceWorkPage(works: [workA], nextPageToken: "next"),
        later: ["next": WorkServiceWorkPage(works: [try catalogTestDescriptor(host: hostA, id: "work-1")], nextPageToken: nil)])

    let hostB = WorkHostRef("catalog-host-b")
    let instanceB = WorkHostInstanceRef(host: hostB, instanceID: "b-instance", startIdentity: "b-start")
    let sessionB = try WorkServiceClientSession(
        locator: CatalogTestLocator(location: nil), client: ClientRef("catalog-client-b"))
    let snapshot = await WorkServiceCatalog().refresh([
        WorkServiceCatalogHost(host: hostB, session: sessionB),
        WorkServiceCatalogHost(host: hostA, session: sessionA),
    ])

    XCTAssertEqual(snapshot.hosts.map(\.host), [hostA, hostB])
    XCTAssertEqual(snapshot.hosts[0].negotiatedInstance, instanceA)
    XCTAssertEqual(snapshot.hosts[0].connectionState, .connected(instanceA))
    XCTAssertEqual(snapshot.hosts[0].works.map(\.work.workID), ["work-1", "work-2"])
    XCTAssertEqual(snapshot.hosts[0].sourceCompleteness, .complete)
    XCTAssertEqual(snapshot.hosts[1].connectionState, .unavailable(nil))
    XCTAssertEqual(snapshot.hosts[1].sourceCompleteness, .incomplete)
    XCTAssertEqual(snapshot.works.map(\.work.workID), ["work-1", "work-2"])
    XCTAssertEqual(snapshot.sourceCompleteness, .incomplete)
    _ = instanceB // documents that the unavailable source has a distinct intended identity.
}

func testWorkServiceCatalogQuarantinesDuplicateInvalidAndRepeatedPagination() async throws {
    let host = WorkHostRef("catalog-adversarial-host")
    let instance = WorkHostInstanceRef(host: host, instanceID: "good-instance", startIdentity: "good-start")
    let work = try catalogTestDescriptor(host: host, id: "same")
    let staleObservation = WorkServiceHostObservation(
        instance: WorkHostInstanceRef(host: host, instanceID: "stale-instance", startIdentity: "stale-start"),
        reachability: .observedReachable, currentRun: nil, servedCursor: nil,
        sourceCompleteness: .complete)
    let stale = try catalogTestDescriptor(host: host, id: "stale", observation: staleObservation)
    let foreignWork = WorkRef(workHostID: "other-host", workID: "foreign")
    let foreignJournal = try JournalRef(
        journalID: "foreign-journal", authority: TimelineAuthorityRef("other-host"), owner: .work(foreignWork))
    let invalid = try catalogTestDescriptor(host: host, id: "invalid", journal: foreignJournal)
    let first = WorkServiceWorkPage(works: [work, invalid, stale], nextPageToken: "repeat")
    let session = try catalogTestSession(
        host: host, instance: instance, pages: first,
        later: ["repeat": WorkServiceWorkPage(works: [work], nextPageToken: "repeat")])

    let snapshot = await WorkServiceCatalog().refresh([
        WorkServiceCatalogHost(host: host, session: session)])
    let row = try XCTUnwrap(snapshot.hosts.first)
    XCTAssertTrue(row.works.isEmpty)
    XCTAssertEqual(row.quarantined.count, 4)
    XCTAssertTrue(row.quarantined.contains { $0.diagnostic.contains("authority") })
    XCTAssertTrue(row.quarantined.contains { $0.diagnostic.contains("instance") })
    XCTAssertTrue(row.omissions.contains { $0.category == "catalog_pagination" })
    XCTAssertEqual(row.sourceCompleteness, .incomplete)
    XCTAssertEqual(snapshot.sourceCompleteness, .incomplete)
}

func testWorkServiceCatalogBoundsHostsAndRejectsMalformedPages() async throws {
    let malformedHost = WorkHostRef("catalog-oversized-page-host")
    let malformedInstance = WorkHostInstanceRef(
        host: malformedHost, instanceID: "oversized-instance", startIdentity: "oversized-start")
    let oversizedRows = try (0...WorkServiceBounds.maxPageSize).map {
        try catalogTestDescriptor(host: malformedHost, id: "work-\($0)")
    }
    let malformedSession = try catalogTestSession(
        host: malformedHost, instance: malformedInstance,
        pages: WorkServiceWorkPage(works: oversizedRows, nextPageToken: nil))
    let malformed = await WorkServiceCatalog().refresh([
        WorkServiceCatalogHost(host: malformedHost, session: malformedSession)
    ])
    XCTAssertTrue(malformed.works.isEmpty)
    XCTAssertEqual(malformed.hosts.first?.quarantined.count, oversizedRows.count)
    XCTAssertTrue(malformed.hosts.first?.omissions.contains {
        $0.category == "catalog_page_rows" && $0.count == oversizedRows.count
    } == true)
    XCTAssertEqual(malformed.sourceCompleteness, .incomplete)

    let duplicateHost = WorkHostRef("catalog-duplicate-config-host")
    let duplicateInstance = WorkHostInstanceRef(
        host: duplicateHost, instanceID: "duplicate-instance", startIdentity: "duplicate-start")
    let duplicateSession = try catalogTestSession(
        host: duplicateHost, instance: duplicateInstance,
        pages: WorkServiceWorkPage(works: [], nextPageToken: nil))
    let duplicate = await WorkServiceCatalog().refresh([
        WorkServiceCatalogHost(host: duplicateHost, session: duplicateSession),
        WorkServiceCatalogHost(host: duplicateHost, session: duplicateSession),
    ])
    XCTAssertEqual(duplicate.hosts.count, 1)
    XCTAssertEqual(duplicate.hosts.first?.connectionState, .disconnected)
    XCTAssertEqual(duplicate.sourceCompleteness, .incomplete)
    XCTAssertTrue(duplicate.diagnostics.contains {
        $0.contains("duplicate configured Work Host identity")
    })

    var configured: [WorkServiceCatalogHost] = []
    for index in 0...WorkServiceCatalog.maxHosts {
        let host = WorkHostRef("catalog-bounded-host-\(index)")
        let instance = WorkHostInstanceRef(
            host: host, instanceID: "instance-\(index)", startIdentity: "start-\(index)")
        configured.append(WorkServiceCatalogHost(
            host: host,
            session: try catalogTestSession(
                host: host, instance: instance,
                pages: WorkServiceWorkPage(works: [], nextPageToken: nil))))
    }
    configured.append(configured[0])
    let bounded = await WorkServiceCatalog().refresh(configured)
    let reversed = await WorkServiceCatalog().refresh(Array(configured.reversed()))
    XCTAssertEqual(bounded.hosts.count, WorkServiceCatalog.maxHosts)
    XCTAssertEqual(bounded.sourceCompleteness, .incomplete)
    XCTAssertTrue(bounded.omissions.contains {
        $0.category == "catalog_hosts" && $0.count == 1
    })
    XCTAssertEqual(bounded.hosts.map(\.host), reversed.hosts.map(\.host))
    XCTAssertEqual(bounded.hosts.first?.connectionState, .disconnected)
}

func testWorkServiceCatalogExactHostRowBoundCanFinishCompletely() async throws {
    let host = WorkHostRef("catalog-exact-row-bound-host")
    let instance = WorkHostInstanceRef(
        host: host, instanceID: "exact-bound-instance", startIdentity: "exact-bound-start")
    var pages: [String: WorkServiceWorkPage] = [:]
    let pageCount = WorkServiceCatalog.maxWorksPerHost / WorkServiceBounds.maxPageSize
    for pageIndex in 1..<pageCount {
        let rows = try (0..<WorkServiceBounds.maxPageSize).map { row in
            try catalogTestDescriptor(
                host: host, id: "work-\(pageIndex * WorkServiceBounds.maxPageSize + row)")
        }
        pages["page-\(pageIndex)"] = WorkServiceWorkPage(
            works: rows,
            nextPageToken: pageIndex + 1 < pageCount ? "page-\(pageIndex + 1)" : nil)
    }
    let firstRows = try (0..<WorkServiceBounds.maxPageSize).map {
        try catalogTestDescriptor(host: host, id: "work-\($0)")
    }
    let session = try catalogTestSession(
        host: host, instance: instance,
        pages: WorkServiceWorkPage(works: firstRows, nextPageToken: "page-1"), later: pages)
    let snapshot = await WorkServiceCatalog().refresh([
        WorkServiceCatalogHost(host: host, session: session)
    ])
    XCTAssertEqual(snapshot.works.count, WorkServiceCatalog.maxWorksPerHost)
    XCTAssertEqual(snapshot.sourceCompleteness, .complete)
    XCTAssertTrue(snapshot.omissions.isEmpty)
}

let casesWorkServiceCatalog: [Case] = [
    ("phase3 Work service catalog isolates unavailable hosts and consumes pages", {
        try await testWorkServiceCatalogRefreshesHostsConcurrentlyAndIsolatesUnavailable()
    }),
    ("phase3 Work service catalog quarantines duplicate invalid repeated pages", {
        try await testWorkServiceCatalogQuarantinesDuplicateInvalidAndRepeatedPagination()
    }),
    ("phase3 Work service catalog bounds hosts and rejects malformed pages", {
        try await testWorkServiceCatalogBoundsHostsAndRejectsMalformedPages()
    }),
    ("phase3 Work service catalog accepts an exact complete host row bound", {
        try await testWorkServiceCatalogExactHostRowBoundCanFinishCompletely()
    }),
]
