import Foundation

/// A one-shot helper process authorizes its own Keychain identity. Only metadata enters
/// argv and only an exit status leaves the process; the credential never crosses IPC.
public enum LocalSecretServiceAccess {
    public static func arguments(home: AgentHome, record: LocalSecretMetadata,
                                 interactive: Bool) -> [String] {
        [interactive ? "--authorize-local-secret" : "--check-local-secret",
         record.name, record.allowedProviderID, record.allowedOrigin, home.root.path]
    }

    public static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.dropFirst().contains(where: {
            $0 == "--authorize-local-secret" || $0 == "--check-local-secret"
        }) else { return nil }
        guard arguments.count == 6,
              ["--authorize-local-secret", "--check-local-secret"].contains(arguments[1]),
              arguments[5].hasPrefix("/"), arguments[5].utf8.count <= 4096,
              !arguments[5].unicodeScalars.contains(where: { $0.value < 32 }) else { return 2 }
        let home = AgentHome(root: URL(fileURLWithPath: arguments[5], isDirectory: true))
        let record = LocalSecretMetadata(name: arguments[2], allowedProviderID: arguments[3],
                                         allowedOrigin: arguments[4])
        return check(record, store: LocalSecretStore(home: home,
            allowAuthenticationUI: arguments[1] == "--authorize-local-secret")) ? 0 : 1
    }

    static func check(_ record: LocalSecretMetadata, store: LocalSecretStore) -> Bool {
        do {
            _ = try store.resolve(name: record.name, providerID: record.allowedProviderID,
                                  origin: record.allowedOrigin)
            return true
        } catch { return false }
    }
}
