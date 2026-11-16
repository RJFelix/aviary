import Foundation

/// Explicit developer self-check for GUI-to-helper Keychain access. It can only operate on a
/// disposable UUID namespace and a fixed non-secret sentinel, never on user credential names.
public enum LocalSecretKeychainProbe {
    public static func runIfRequested(arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: "--keychain-self-check") else { return nil }
        guard arguments.count == index + 3,
              let id = UUID(uuidString: arguments[index + 2]) else { return 2 }
        let home = AgentHome(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("aviary-keychain-check-\(id.uuidString)"))
        let store = LocalSecretStore(home: home)
        let sentinel = "aviary-keychain-self-check-not-a-real-key"
        do {
            switch arguments[index + 1] {
            case "save":
                try store.save(name: "self-check", value: sentinel,
                    allowedProviderID: "aviary-self-check", allowedOrigin: "https://keychain-self-check.invalid")
            case "read":
                guard try store.resolve(name: "self-check", providerID: "aviary-self-check",
                    origin: "https://keychain-self-check.invalid") == sentinel else { return 1 }
            case "remove": try store.remove(name: "self-check")
            default: return 2
            }
            print("Keychain self-check succeeded.")
            return 0
        } catch {
            // Never include Security.framework diagnostics or a credential value.
            print("Keychain self-check failed.")
            return 1
        }
    }
}
