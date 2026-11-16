import Foundation

/// Writes references and model metadata only; this API never accepts credential bytes.
public enum XAIProviderSetup {
    public static let providerID = "xai"
    public static let baseURL = "https://api.x.ai/v1"
    public static let suggestedModelID = "grok-4.7"

    public enum Failure: Error, LocalizedError {
        case invalidName, invalidConfiguration, existingProviderConflict
        public var errorDescription: String? {
            switch self {
            case .invalidName: return "Use a valid secret name and model ID."
            case .invalidConfiguration: return "The existing models configuration could not be read safely. It was not changed."
            case .existingProviderConflict: return "A different provider already uses the xai ID. Its configuration was not changed."
            }
        }
    }

    public static func configuration(_ raw: JSONValue, modelID: String,
                                     secretName: String) throws -> JSONValue {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard (1...128).contains(modelID.utf8.count),
              (1...64).contains(secretName.utf8.count),
              modelID.unicodeScalars.allSatisfy(allowed.contains),
              secretName.unicodeScalars.allSatisfy(allowed.contains) else {
            throw Failure.invalidName
        }
        guard var root = raw.objectValue else { throw Failure.invalidConfiguration }
        if let existing = root["providers"], existing.objectValue == nil {
            throw Failure.invalidConfiguration
        }
        var providers = root["providers"]?.objectValue ?? [:]
        var provider = providers[providerID]?.objectValue ?? [:]
        if let existing = providers[providerID] {
            guard existing.objectValue != nil,
                  existing["baseUrl"]?.stringValue == baseURL,
                  existing["api"]?.stringValue == "xai-responses" else {
                throw Failure.existingProviderConflict
            }
        }
        if let models = provider["models"], models.arrayValue == nil {
            throw Failure.invalidConfiguration
        }
        var models = provider["models"]?.arrayValue ?? []
        if !models.contains(where: { $0["id"]?.stringValue == modelID }) {
            // Limits/prices are deliberately unknown unless supplied by an actual catalog.
            models.append(.object(["id": .string(modelID), "name": .string(modelID),
                                   "reasoning": true, "input": .array(["text", "image"])]))
        }
        provider["name"] = "SpaceXAI · Grok"
        provider["baseUrl"] = .string(baseURL)
        provider["api"] = "xai-responses"
        provider["apiKey"] = .string("@secret:\(secretName)")
        provider["models"] = .array(models)
        providers[providerID] = .object(provider)
        root["providers"] = .object(providers)
        return .object(root)
    }

    public static func save(home: AgentHome, modelID: String, secretName: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: home.root, withIntermediateDirectories: true)
        let url = home.modelsFile
        var raw: JSONValue = .object([:])
        if fm.fileExists(atPath: url.path) {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? NSNumber, size.intValue <= 5 * 1024 * 1024,
                  let bytes = fm.contents(atPath: url.path), let parsed = JSONValue.parse(bytes) else {
                throw Failure.invalidConfiguration
            }
            raw = parsed
        }
        let next = try configuration(raw, modelID: modelID, secretName: secretName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(next)
        if fm.fileExists(atPath: url.path) {
            let backup = home.root.appendingPathComponent("models.json.aviary-bak-\(UUID().uuidString)")
            try fm.copyItem(at: url, to: backup)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try bytes.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
