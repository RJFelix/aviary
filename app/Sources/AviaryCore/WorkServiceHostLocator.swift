import Foundation

/// A transport-neutral description of where a Work service can be reached.
///
/// The location deliberately excludes a PID, filesystem descriptor path, or publication time.
/// Those are discovery diagnostics, not Work identity or liveness evidence. A client establishes
/// reachability only after connecting and matching the exact handshake host instance.
public struct WorkServiceHostLocation: Hashable, Sendable {
    public enum Transport: Hashable, Sendable {
        case unixSocket(WorkServiceTransportEndpoint)
    }

    public let host: WorkHostRef
    public let expectedInstance: WorkHostInstanceRef
    public let protocolVersion: Int
    public let transport: Transport

    public init(
        host: WorkHostRef,
        expectedInstance: WorkHostInstanceRef,
        protocolVersion: Int,
        transport: Transport
    ) {
        self.host = host
        self.expectedInstance = expectedInstance
        self.protocolVersion = protocolVersion
        self.transport = transport
    }
}

/// Discovery and connection are separate crossings. A locator returns an untrusted candidate;
/// the client must still perform a protocol handshake and match ``expectedInstance`` exactly.
public protocol WorkServiceHostLocating: Sendable {
    func locate() async throws -> WorkServiceHostLocation?
}

/// Finds the daemon published by the Work Host that owns one local AgentHome.
///
/// This type never launches or terminates `aviaryd`. Closing the GUI therefore cannot acquire
/// process-lifetime ownership merely because it used local discovery.
public struct LocalWorkServiceHostLocator: WorkServiceHostLocating, Sendable {
    public let layout: WorkHostDaemonEndpointLayout

    public init(home: AgentHome, workHost: WorkHostRef) {
        self.layout = WorkHostDaemonEndpointLayout(home: home, workHost: workHost)
    }

    public init(layout: WorkHostDaemonEndpointLayout) {
        self.layout = layout
    }

    public func locate() async throws -> WorkServiceHostLocation? {
        guard let descriptor = try WorkHostDaemonEndpointPublisher.discover(layout: layout) else {
            return nil
        }
        return WorkServiceHostLocation(
            host: descriptor.hostInstance.host,
            expectedInstance: descriptor.hostInstance,
            protocolVersion: descriptor.workServiceProtocolVersion,
            transport: .unixSocket(descriptor.endpoint))
    }
}
