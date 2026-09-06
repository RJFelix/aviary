import Foundation

/// A configured connection that may contribute Work rows to a catalog refresh.
///
/// The session is deliberately supplied by the caller: the catalog does not discover, launch,
/// stop, attach, or otherwise acquire ownership of a Work Host.  A session may therefore be
/// shared by several GUI projections, and a refresh of one host cannot mutate another session.
public struct WorkServiceCatalogHost: Sendable {
    public let host: WorkHostRef
    public let session: WorkServiceClientSession

    public init(host: WorkHostRef, session: WorkServiceClientSession) {
        self.host = host
        self.session = session
    }
}

public struct WorkServiceCatalogQuarantinedWork: Sendable, Hashable {
    public let work: WorkRef?
    public let diagnostic: String

    public init(work: WorkRef?, diagnostic: String) {
        self.work = work
        self.diagnostic = WorkServiceCatalogBounds.bound(diagnostic)
    }
}

public struct WorkServiceCatalogHostSnapshot: Sendable {
    public let host: WorkHostRef
    public let negotiatedInstance: WorkHostInstanceRef?
    public let connectionState: WorkServiceClientSessionState
    public let sourceCompleteness: WorkServiceSourceCompleteness
    public let works: [WorkServiceWorkDescriptor]
    public let quarantined: [WorkServiceCatalogQuarantinedWork]
    public let omissions: [WorkServiceOmission]
    public let diagnostics: [String]

    public init(host: WorkHostRef, negotiatedInstance: WorkHostInstanceRef?,
                connectionState: WorkServiceClientSessionState,
                sourceCompleteness: WorkServiceSourceCompleteness,
                works: [WorkServiceWorkDescriptor] = [],
                quarantined: [WorkServiceCatalogQuarantinedWork] = [],
                omissions: [WorkServiceOmission] = [], diagnostics: [String] = []) {
        var boundedOmissions = omissions
        var wasBounded = false
        if works.count > WorkServiceCatalogBounds.maxRows {
            wasBounded = true
            boundedOmissions.append(WorkServiceOmission(
                category: "catalog_works",
                count: works.count - WorkServiceCatalogBounds.maxRows,
                diagnostic: "Work rows exceeded the host catalog bound"))
        }
        if quarantined.count > WorkServiceCatalogBounds.maxRows {
            wasBounded = true
            boundedOmissions.append(WorkServiceOmission(
                category: "catalog_quarantine",
                count: quarantined.count - WorkServiceCatalogBounds.maxRows,
                diagnostic: "quarantined rows exceeded the host catalog bound"))
        }
        if diagnostics.count > WorkServiceCatalogBounds.maxDiagnostics {
            wasBounded = true
            boundedOmissions.append(WorkServiceOmission(
                category: "catalog_diagnostics",
                count: diagnostics.count - WorkServiceCatalogBounds.maxDiagnostics,
                diagnostic: "catalog diagnostics exceeded the display bound"))
        }
        self.host = host
        self.negotiatedInstance = negotiatedInstance
        self.connectionState = connectionState
        self.sourceCompleteness = wasBounded || !boundedOmissions.isEmpty
            ? .incomplete : sourceCompleteness
        self.works = Array(works.prefix(WorkServiceCatalogBounds.maxRows))
        self.quarantined = Array(quarantined
            .sorted(by: WorkServiceCatalogBounds.precedesQuarantine)
            .prefix(WorkServiceCatalogBounds.maxRows))
        self.omissions = WorkServiceCatalogBounds.omissions(boundedOmissions)
        self.diagnostics = Array(diagnostics.prefix(WorkServiceCatalogBounds.maxDiagnostics))
            .map(WorkServiceCatalogBounds.bound)
    }

    fileprivate func addingQuarantine(_ entries: [WorkServiceCatalogQuarantinedWork])
        -> WorkServiceCatalogHostSnapshot
    {
        WorkServiceCatalogHostSnapshot(
            host: host, negotiatedInstance: negotiatedInstance, connectionState: connectionState,
            sourceCompleteness: .incomplete, works: works,
            quarantined: quarantined + entries, omissions: omissions, diagnostics: diagnostics)
    }
}

public struct WorkServiceCatalogSnapshot: Sendable {
    public let hosts: [WorkServiceCatalogHostSnapshot]
    public let works: [WorkServiceWorkDescriptor]
    public let sourceCompleteness: WorkServiceSourceCompleteness
    public let omissions: [WorkServiceOmission]
    public let diagnostics: [String]

    public init(hosts: [WorkServiceCatalogHostSnapshot],
                sourceCompleteness: WorkServiceSourceCompleteness,
                works: [WorkServiceWorkDescriptor] = [],
                omissions: [WorkServiceOmission] = [], diagnostics: [String] = []) {
        var boundedOmissions = omissions
        var wasBounded = false
        if hosts.count > WorkServiceCatalog.maxHosts {
            wasBounded = true
            boundedOmissions.append(WorkServiceOmission(
                category: "catalog_hosts", count: hosts.count - WorkServiceCatalog.maxHosts,
                diagnostic: "configured Work Hosts exceeded the catalog bound"))
        }
        if works.count > WorkServiceCatalog.maxGlobalWorks {
            wasBounded = true
            boundedOmissions.append(WorkServiceOmission(
                category: "catalog_works", count: works.count - WorkServiceCatalog.maxGlobalWorks,
                diagnostic: "aggregate Work rows exceeded the catalog bound"))
        }
        if diagnostics.count > WorkServiceCatalogBounds.maxDiagnostics {
            wasBounded = true
            boundedOmissions.append(WorkServiceOmission(
                category: "catalog_diagnostics",
                count: diagnostics.count - WorkServiceCatalogBounds.maxDiagnostics,
                diagnostic: "catalog diagnostics exceeded the display bound"))
        }
        self.hosts = Array(hosts.sorted {
            $0.host.workHostID < $1.host.workHostID
        }.prefix(WorkServiceCatalog.maxHosts))
        self.works = Array(works.sorted {
            WorkServiceCatalogBounds.precedes($0.work, $1.work)
        }.prefix(WorkServiceCatalog.maxGlobalWorks))
        self.sourceCompleteness = wasBounded || !boundedOmissions.isEmpty
            ? .incomplete : sourceCompleteness
        self.omissions = WorkServiceCatalogBounds.omissions(boundedOmissions)
        self.diagnostics = Array(diagnostics.prefix(WorkServiceCatalogBounds.maxDiagnostics))
            .map(WorkServiceCatalogBounds.bound)
    }
}

/// A read-only, bounded projection over several independent Work-service sessions.
public struct WorkServiceCatalog: Sendable {
    public static let maxHosts = 64
    public static let maxPagesPerHost = 256
    public static let maxWorksPerHost = 4_096
    public static let maxGlobalWorks = 16_384

    public init() {}

    public func refresh(_ configuredHosts: [WorkServiceCatalogHost]) async
        -> WorkServiceCatalogSnapshot
    {
        let census = Self.hostCensus(configuredHosts)
        let hostSnapshots = await withTaskGroup(of: WorkServiceCatalogHostSnapshot.self) {
            group in
            for configured in census.unique {
                group.addTask { await Self.refresh(configured) }
            }
            var snapshots = census.conflicts.map { host in
                WorkServiceCatalogHostSnapshot(
                    host: host, negotiatedInstance: nil, connectionState: .disconnected,
                    sourceCompleteness: .incomplete,
                    diagnostics: ["duplicate configured Work Host identity"])
            }
            for await snapshot in group { snapshots.append(snapshot) }
            return snapshots.sorted { $0.host.workHostID < $1.host.workHostID }
        }

        var hostRows = hostSnapshots
        var seen: [WorkRef: (hostIndex: Int, descriptor: WorkServiceWorkDescriptor)] = [:]
        var conflicts: [WorkRef: [(Int, WorkServiceWorkDescriptor)]] = [:]
        for (hostIndex, host) in hostRows.enumerated() {
            for descriptor in host.works {
                if let prior = seen[descriptor.work] {
                    conflicts[descriptor.work, default: [(prior.hostIndex, prior.descriptor)]]
                        .append((hostIndex, descriptor))
                } else {
                    seen[descriptor.work] = (hostIndex, descriptor)
                }
            }
        }

        var diagnostics = census.conflicts.map {
            "duplicate configured Work Host identity \($0.workHostID)"
        }
        for work in conflicts.keys.sorted(by: WorkServiceCatalogBounds.precedes) {
            guard let entries = conflicts[work] else { continue }
            let message = "duplicate Work identity \(work.workHostID)/\(work.workID) across catalog sources"
            diagnostics.append(message)
            for (hostIndex, _) in entries {
                let matching = hostRows[hostIndex].works.filter { $0.work == work }
                let quarantine = matching.map {
                    WorkServiceCatalogQuarantinedWork(work: $0.work, diagnostic: message)
                }
                hostRows[hostIndex] = hostRows[hostIndex]
                    .addingQuarantine(quarantine)
                    .removingWorks(where: { $0.work == work })
            }
        }

        let works = hostRows.flatMap(\.works).sorted {
            WorkServiceCatalogBounds.precedes($0.work, $1.work)
        }
        let globalOverflow = max(0, works.count - Self.maxGlobalWorks)
        let complete = hostRows.allSatisfy { $0.sourceCompleteness == .complete }
            && conflicts.isEmpty && census.omitted == 0 && globalOverflow == 0
        var hostOmissions = hostRows.flatMap(\.omissions)
        if census.omitted > 0 {
            hostOmissions.append(WorkServiceOmission(
                category: "catalog_hosts", count: census.omitted,
                diagnostic: "configured Work Hosts exceeded the refresh bound"))
        }
        let hostDiagnostics = hostRows.flatMap(\.diagnostics)
        return WorkServiceCatalogSnapshot(
            hosts: hostRows, sourceCompleteness: complete ? .complete : .incomplete,
            works: works, omissions: hostOmissions,
            diagnostics: diagnostics + hostDiagnostics)
    }

    private static func hostCensus(_ hosts: [WorkServiceCatalogHost])
        -> (unique: [WorkServiceCatalogHost], conflicts: [WorkHostRef], omitted: Int)
    {
        let ordered = hosts.sorted {
            $0.host.workHostID < $1.host.workHostID
        }
        var selected: [WorkServiceCatalogHost] = []
        var conflicts: [WorkHostRef] = []
        var omitted = 0
        var index = 0
        while index < ordered.count {
            let candidate = ordered[index]
            var end = index + 1
            while end < ordered.count, ordered[end].host == candidate.host { end += 1 }
            guard selected.count + conflicts.count < maxHosts else {
                omitted += 1
                index = end
                continue
            }
            if end - index > 1 {
                conflicts.append(candidate.host)
            } else {
                selected.append(candidate)
            }
            index = end
        }
        return (selected, conflicts, omitted)
    }

    private static func refresh(_ configured: WorkServiceCatalogHost) async
        -> WorkServiceCatalogHostSnapshot
    {
        do {
            let handshake = try await configured.session.connect()
            guard handshake.host == configured.host,
                  handshake.hostInstance.host == configured.host else {
                return WorkServiceCatalogHostSnapshot(
                    host: configured.host, negotiatedInstance: handshake.hostInstance,
                    connectionState: await configured.session.state,
                    sourceCompleteness: .incomplete,
                    diagnostics: ["handshake host identity did not match configured host"])
            }
            do {
                return try await readPages(configured, instance: handshake.hostInstance)
            } catch {
                // Preserve the exact instance that was negotiated even when the subsequent
                // bounded read loses transport.  The UI can distinguish a known host that
                // became unreachable from a host whose identity was never established.
                return WorkServiceCatalogHostSnapshot(
                    host: configured.host, negotiatedInstance: handshake.hostInstance,
                    connectionState: await configured.session.state,
                    sourceCompleteness: .incomplete,
                    diagnostics: [safeDiagnostic(for: error)])
            }
        } catch {
            return WorkServiceCatalogHostSnapshot(
                host: configured.host, negotiatedInstance: nil,
                connectionState: await configured.session.state,
                sourceCompleteness: .incomplete,
                diagnostics: [safeDiagnostic(for: error)])
        }
    }

    private static func safeDiagnostic(for error: Error) -> String {
        switch error {
        case WorkServiceClientSessionError.invalidClient:
            return "Work service client identity is invalid."
        case WorkServiceClientSessionError.unavailable:
            return "Work Host is unavailable."
        case WorkServiceClientSessionError.incompatibleProtocol:
            return "Work Host protocol is incompatible."
        case WorkServiceClientSessionError.hostInstanceMismatch:
            return "Work Host instance did not match discovery."
        case WorkServiceClientSessionError.notConnected:
            return "Work Host connection is not established."
        case WorkServiceClientSessionError.superseded:
            return "Work Host connection attempt was superseded."
        default:
            // Arbitrary Error descriptions can contain endpoint paths, credentials, or remote
            // payloads. Connection state and bounded protocol DTOs carry the actionable truth.
            return "Work service request failed."
        }
    }

    private static func readPages(_ configured: WorkServiceCatalogHost,
                                  instance: WorkHostInstanceRef) async throws
        -> WorkServiceCatalogHostSnapshot
    {
        var pageToken: String?
        var seenTokens = Set<String>()
        var pages = 0
        var descriptors: [WorkServiceWorkDescriptor] = []
        var quarantined: [WorkServiceCatalogQuarantinedWork] = []
        var omissions: [WorkServiceOmission] = []
        var diagnostics: [String] = []
        var complete = true

        while true {
            guard pages < maxPagesPerHost else {
                complete = false
                omissions.append(WorkServiceOmission(
                    category: "catalog_pages", count: 1,
                    diagnostic: "page limit reached before the host produced an end token"))
                break
            }
            pages += 1
            let page = try await configured.session.listWorks(WorkServiceListRequest(
                client: configured.session.client, pageSize: WorkServiceBounds.maxPageSize,
                pageToken: pageToken))
            if page.works.count > WorkServiceBounds.maxPageSize {
                complete = false
                let diagnostic = "host returned more Work rows than its page bound"
                diagnostics.append(diagnostic)
                quarantined.append(contentsOf: page.works
                    .prefix(max(0, WorkServiceCatalogBounds.maxRows - quarantined.count))
                    .map { WorkServiceCatalogQuarantinedWork(
                        work: $0.work, diagnostic: diagnostic) })
                omissions.append(WorkServiceOmission(
                    category: "catalog_page_rows", count: page.works.count,
                    diagnostic: "oversized Work page was quarantined"))
                // Its token and rows are one malformed response. Do not consume either and then
                // continue from an untrusted boundary supplied by a future transport.
                break
            }
            omissions.append(contentsOf: page.omissions)
            if !page.omissions.isEmpty { complete = false }
            let available = max(0, maxWorksPerHost - descriptors.count)
            let acceptedPage = page.works.prefix(available)
            if page.works.count > available {
                complete = false
                omissions.append(WorkServiceOmission(
                    category: "catalog_works", count: page.works.count - available,
                    diagnostic: "host Work row bound dropped part of a page"))
            }
            for descriptor in acceptedPage {
                if descriptor.hostObservation?.sourceCompleteness != nil,
                   descriptor.hostObservation?.sourceCompleteness != .complete {
                    complete = false
                }
                if let diagnostic = validate(descriptor, host: configured.host, instance: instance) {
                    complete = false
                    quarantined.append(WorkServiceCatalogQuarantinedWork(
                        work: descriptor.work, diagnostic: diagnostic))
                } else {
                    descriptors.append(descriptor)
                }
            }
            guard let next = page.nextPageToken else { break }
            if page.works.count > available || descriptors.count >= maxWorksPerHost {
                complete = false
                omissions.append(WorkServiceOmission(
                    category: "catalog_works", count: 1,
                    diagnostic: "host Work row bound reached before the end token"))
                break
            }
            guard !next.isEmpty, next != pageToken, seenTokens.insert(next).inserted else {
                complete = false
                omissions.append(WorkServiceOmission(
                    category: "catalog_pagination", count: 1,
                    diagnostic: "repeated or empty page token; host pagination quarantined"))
                break
            }
            pageToken = next
        }

        var byWork: [WorkRef: [WorkServiceWorkDescriptor]] = [:]
        for descriptor in descriptors { byWork[descriptor.work, default: []].append(descriptor) }
        for work in byWork.keys.sorted(by: WorkServiceCatalogBounds.precedes) {
            guard let duplicates = byWork[work], duplicates.count > 1 else { continue }
            complete = false
            let diagnostic = "duplicate Work identity in one host listing"
            quarantined.append(contentsOf: duplicates.map { _ in
                WorkServiceCatalogQuarantinedWork(work: work, diagnostic: diagnostic)
            })
            descriptors.removeAll { $0.work == work }
        }
        return WorkServiceCatalogHostSnapshot(
            host: configured.host, negotiatedInstance: instance,
            connectionState: await configured.session.state,
            sourceCompleteness: complete ? .complete : .incomplete,
            works: descriptors.sorted { WorkServiceCatalogBounds.precedes($0.work, $1.work) },
            quarantined: quarantined, omissions: omissions, diagnostics: diagnostics)
    }

    private static func validate(_ descriptor: WorkServiceWorkDescriptor,
                                 host: WorkHostRef,
                                 instance: WorkHostInstanceRef) -> String? {
        guard descriptor.work.workHostID == host.workHostID else {
            return "Work identity belongs to a different Work Host"
        }
        guard descriptor.journal.authority.authorityID == host.workHostID else {
            return "Work journal authority does not equal its Work Host"
        }
        guard descriptor.journal.owner == .work(descriptor.work) else {
            return "Work journal owner does not name the descriptor Work"
        }
        if let observation = descriptor.hostObservation, observation.instance != instance {
            return "Work observation belongs to a different negotiated host instance"
        }
        // ClientAttachmentRef is Work-scoped identity.  A repeated id is ambiguous even when
        // the rows claim different clients or Session relationships, so quarantine the entire
        // descriptor before any consumer can first-pick one row.
        var attachmentIDs = Set<ClientAttachmentRef>()
        guard descriptor.attachments.allSatisfy({ attachmentIDs.insert($0.attachment).inserted }) else {
            return "duplicate ClientAttachmentRef within Work descriptor"
        }
        return nil
    }
}

private enum WorkServiceCatalogBounds {
    static let maxRows = 4_096
    static let maxDiagnostics = 32
    static let maxDiagnosticCharacters = 512

    static func bound(_ value: String) -> String {
        String(value.prefix(maxDiagnosticCharacters))
    }

    static func omissions(_ values: [WorkServiceOmission]) -> [WorkServiceOmission] {
        guard values.count > maxDiagnostics else { return values }
        let retained = max(0, maxDiagnostics - 1)
        return Array(values.prefix(retained)) + [WorkServiceOmission(
            category: "catalog_omissions", count: values.count - retained,
            diagnostic: "additional omission records were bounded")]
    }

    static func precedes(_ lhs: WorkRef, _ rhs: WorkRef) -> Bool {
        if lhs.workHostID != rhs.workHostID { return lhs.workHostID < rhs.workHostID }
        return lhs.workID < rhs.workID
    }

    static func precedesQuarantine(
        _ lhs: WorkServiceCatalogQuarantinedWork,
        _ rhs: WorkServiceCatalogQuarantinedWork
    ) -> Bool {
        switch (lhs.work, rhs.work) {
        case let (left?, right?):
            if left != right { return precedes(left, right) }
        case (nil, .some): return false
        case (.some, nil): return true
        case (nil, nil): break
        }
        return lhs.diagnostic < rhs.diagnostic
    }
}

private extension WorkServiceCatalogHostSnapshot {
    func removingWorks(where predicate: (WorkServiceWorkDescriptor) -> Bool)
        -> WorkServiceCatalogHostSnapshot {
        WorkServiceCatalogHostSnapshot(
            host: host, negotiatedInstance: negotiatedInstance, connectionState: connectionState,
            sourceCompleteness: .incomplete, works: works.filter { !predicate($0) },
            quarantined: quarantined, omissions: omissions, diagnostics: diagnostics)
    }
}
