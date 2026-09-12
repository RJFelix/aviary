import AviaryCore
import Foundation

/// A deliberately opt-in Mac client probe for a Linux Work Host reached through OpenSSH
/// streamlocal forwarding. The forwarding is owned by the caller; this executable only speaks
/// the public Unix transport and therefore proves the real Mac-client -> SSH -> Linux-daemon path.
@main
struct AviaryMacTransportProbe {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        guard let socketPath = environment["AVIARY_MAC_LINUX_STREAMLOCAL_SOCKET"],
              !socketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("set AVIARY_MAC_LINUX_STREAMLOCAL_SOCKET to run the opt-in probe")
            exit(2)
        }

        let clientID = environment["AVIARY_MAC_LINUX_CLIENT_ID"] ?? "mac-streamlocal-probe"
        let expectedHost = environment["AVIARY_MAC_LINUX_EXPECTED_HOST"]
            .map(WorkHostRef.init)
        AviaryTelemetry.configure(serviceName: "aviary", environment: environment)
        let client = WorkServiceUnixSocketClient(
            endpoint: WorkServiceTransportEndpoint(path: socketPath),
            client: ClientRef(clientID), expectedHost: expectedHost)
        do {
            let (handshake, page) = try await AviaryTelemetry.withSpan(
                "aviary.mac.transport_probe", root: true
            ) {
                let handshake = try await client.connect(build: "mac-streamlocal-probe")
                let page = try await client.listWorks(WorkServiceListRequest(
                    client: ClientRef(clientID)))
                AviaryTelemetry.outcome("completed")
                return (handshake, page)
            }
            print(
                "mac->ssh streamlocal->linux handshake accepted host="
                    + handshake.host.workHostID
                    + " instance=" + handshake.hostInstance.instanceID
                    + " works=" + String(page.works.count)
                    + " omissions=" + String(page.omissions.count))
            await client.close()
            await AviaryTelemetry.shutdown(maximumDuration: 2)
            exit(0)
        } catch {
            await client.close()
            await AviaryTelemetry.shutdown(maximumDuration: 2)
            print("mac->ssh streamlocal->linux probe failed")
            exit(1)
        }
    }
}
