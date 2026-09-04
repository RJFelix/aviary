import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The kind of material that contributed to a system prompt.
///
/// This is intentionally separate from ``PromptSource/sourceID`` and from the content digest:
/// a source's identity is stable across content changes, while its digest changes when the
/// bytes delivered to the model change.
public enum PromptSourceKind: String, Codable, Sendable, Hashable {
    case baseInstruction = "base_instruction"
    case workingDirectory = "working_directory"
    case contextFile = "context_file"
    case skill
    case memory
    case generated
}

/// What could be observed about a prompt source at assembly time.
public enum PromptSourceStatus: String, Codable, Sendable, Hashable {
    case present
    case truncated
    case missing
    case unreadable
    case disabled
}

public enum SystemPromptAssemblyError: Error, Equatable, Sendable {
    case duplicateSourceID(String)
    case invalidSource(String)
    case unaccountedBytes
}

/// One exact, in-memory slice of the assembled system prompt.
///
/// ``fullBody`` and ``deliveredBody`` are deliberately retained only on this in-memory value.
/// The custom `Encodable` implementation below records sizes and digests, never source text.
/// The delivered body is the selected source content. `renderedBody` is the exact slice in the
/// flattened prompt and includes any separators, headings, or truncation marker belonging to
/// this source. Keeping those concepts separate lets consumers compare delivered content to the
/// full source while still making the source list a lossless decomposition of the prompt.
public struct PromptSource: Sendable, Hashable, Equatable, Encodable {
    public typealias Kind = PromptSourceKind
    public typealias Status = PromptSourceStatus
    public let sourceID: String
    public let kind: PromptSourceKind
    /// A short, non-path display label suitable for a diagnostic surface.
    public let label: String
    /// Stable identity (for example, a canonical path), kept separate from sourceID and digest.
    /// This is an in-memory origin only and is deliberately omitted from encoded metadata.
    public let identity: String?
    public let status: PromptSourceStatus
    /// The complete source body when it was readable. This is not encoded as metadata.
    public let fullBody: String?
    /// The selected source content, before generated framing. This is not encoded.
    public let deliveredBody: String
    /// The exact bytes represented by this source in the flattened prompt. This is not encoded.
    public let renderedBody: String
    /// UTF-8 byte offset of the delivered source content inside `renderedBody`. Prefix/suffix
    /// framing therefore remains explicit and verifiable instead of inferred from marker text.
    public let deliveredByteOffsetInRendered: Int
    /// UTF-8 byte offset of `renderedBody` in the flattened prompt, not a character offset.
    public let renderedByteOffset: Int
    public let fullByteCount: Int?
    public let fullDigest: String?
    public let deliveredByteCount: Int
    public let deliveredDigest: String
    public let renderedByteCount: Int
    public let renderedDigest: String

    public init(
        sourceID: String,
        kind: PromptSourceKind,
        label: String,
        identity: String? = nil,
        status: PromptSourceStatus = .present,
        fullBody: String? = nil,
        deliveredBody: String? = nil,
        renderedBody: String? = nil,
        deliveredByteOffsetInRendered: Int = 0,
        renderedByteOffset: Int = 0
    ) throws {
        guard !sourceID.isEmpty else {
            throw SystemPromptAssemblyError.invalidSource("sourceID must not be empty")
        }
        guard renderedByteOffset >= 0 else {
            throw SystemPromptAssemblyError.invalidSource("renderedByteOffset must not be negative")
        }
        guard deliveredByteOffsetInRendered >= 0 else {
            throw SystemPromptAssemblyError.invalidSource(
                "deliveredByteOffsetInRendered must not be negative")
        }

        let actualDelivered = deliveredBody ?? fullBody ?? ""
        let actualRendered = renderedBody ?? actualDelivered
        switch status {
        case .present, .truncated:
            guard fullBody != nil else {
                throw SystemPromptAssemblyError.invalidSource(
                    "\(status.rawValue) source requires a full body")
            }
        case .missing, .unreadable, .disabled:
            guard fullBody == nil, actualDelivered.isEmpty, actualRendered.isEmpty else {
                throw SystemPromptAssemblyError.invalidSource(
                    "\(status.rawValue) source cannot carry a body")
            }
        }

        self.sourceID = sourceID
        self.kind = kind
        self.label = label
        self.identity = identity
        self.status = status
        self.fullBody = fullBody
        self.deliveredBody = actualDelivered
        self.renderedBody = actualRendered
        self.deliveredByteOffsetInRendered = deliveredByteOffsetInRendered
        self.renderedByteOffset = renderedByteOffset
        if let fullBody {
            let data = Data(fullBody.utf8)
            self.fullByteCount = data.count
            self.fullDigest = Self.digest(data)
        } else {
            self.fullByteCount = nil
            self.fullDigest = nil
        }
        let deliveredData = Data(actualDelivered.utf8)
        self.deliveredByteCount = deliveredData.count
        self.deliveredDigest = Self.digest(deliveredData)
        let renderedData = Data(actualRendered.utf8)
        self.renderedByteCount = renderedData.count
        self.renderedDigest = Self.digest(renderedData)
        let deliveredEnd = deliveredByteOffsetInRendered.addingReportingOverflow(
            deliveredData.count)
        guard !deliveredEnd.overflow, deliveredEnd.partialValue <= renderedData.count,
              renderedData.subdata(
                in: deliveredByteOffsetInRendered..<deliveredEnd.partialValue) == deliveredData else {
            throw SystemPromptAssemblyError.invalidSource(
                "delivered body is not the declared rendered slice")
        }
    }

    /// Compatibility spelling; offsets always refer to the rendered prompt slice.
    public var deliveredByteOffset: Int { renderedByteOffset }

    private static func digest(_ data: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case kind, label, identity, status
        case deliveredByteOffsetInRendered = "delivered_byte_offset_in_rendered"
        case renderedByteOffset = "rendered_byte_offset"
        case fullByteCount = "full_byte_count"
        case fullDigest = "full_digest"
        case deliveredByteCount = "delivered_byte_count"
        case deliveredDigest = "delivered_digest"
        case renderedByteCount = "rendered_byte_count"
        case renderedDigest = "rendered_digest"
    }

    /// Encode metadata only. In particular, neither source body is serialized by default.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(kind, forKey: .kind)
        try c.encode(label, forKey: .label)
        try c.encode(status, forKey: .status)
        try c.encode(deliveredByteOffsetInRendered, forKey: .deliveredByteOffsetInRendered)
        try c.encode(renderedByteOffset, forKey: .renderedByteOffset)
        try c.encodeIfPresent(fullByteCount, forKey: .fullByteCount)
        try c.encodeIfPresent(fullDigest, forKey: .fullDigest)
        try c.encode(deliveredByteCount, forKey: .deliveredByteCount)
        try c.encode(deliveredDigest, forKey: .deliveredDigest)
        try c.encode(renderedByteCount, forKey: .renderedByteCount)
        try c.encode(renderedDigest, forKey: .renderedDigest)
    }
}

/// A lossless, deterministic decomposition of the system prompt sent to an in-house model.
///
/// This type does not replace the canonical flattened system message. It is an auxiliary
/// producer-side projection that can later be attached to that message for context manifests,
/// provenance, and inspection.
public struct SystemPromptAssembly: Sendable, Hashable, Equatable, Encodable {
    public static let schemaVersion = 1

    /// The prompt contract limits each context file to 12,000 characters. Four bytes per UTF-8
    /// scalar plus a small boundary allowance lets us preserve that contract while bounding the
    /// read. A file beyond this byte bound is reported as unreadable rather than retaining a
    /// partial body whose digest would falsely claim to describe the source.
    private static let maximumContextFileBytes = 12_000 * 4 + 4

    /// The exact text to use as the system message. It is intentionally not encoded by default.
    public let text: String
    public let sources: [PromptSource]
    public let byteCount: Int
    public let digest: String

    /// Naming aligned with the context-manifest terminology used by consumers.
    public var flattenedText: String { text }
    public var flattenedByteCount: Int { byteCount }
    public var flattenedDigest: String { digest }

    public init(text: String, sources: [PromptSource]) throws {
        var ids = Set<String>()
        var offset = 0
        var normalized: [PromptSource] = []
        normalized.reserveCapacity(sources.count)
        var bytes = Data()
        for source in sources {
            guard ids.insert(source.sourceID).inserted else {
                throw SystemPromptAssemblyError.duplicateSourceID(source.sourceID)
            }
            let data = Data(source.renderedBody.utf8)
            guard source.renderedByteOffset == offset else {
                throw SystemPromptAssemblyError.invalidSource(
                    "source \(source.sourceID) has an incorrect byte offset")
            }
            bytes.append(data)
            normalized.append(try PromptSource(
                sourceID: source.sourceID, kind: source.kind, label: source.label,
                identity: source.identity, status: source.status, fullBody: source.fullBody,
                deliveredBody: source.deliveredBody, renderedBody: source.renderedBody,
                deliveredByteOffsetInRendered: source.deliveredByteOffsetInRendered,
                renderedByteOffset: offset))
            offset += data.count
        }
        guard String(decoding: bytes, as: UTF8.self) == text,
              bytes.count == Data(text.utf8).count else {
            throw SystemPromptAssemblyError.unaccountedBytes
        }
        self.text = text
        self.sources = normalized
        self.byteCount = bytes.count
        self.digest = Self.digest(bytes)
    }

    /// Reproduces the in-house engine's current system prompt exactly.
    ///
    /// `memory` and `skills` are already-rendered blocks from `MemoryGate` and `SkillGate`.
    /// They are treated as opaque source bodies here so this bounded slice does not change
    /// discovery or selection. Context files are intentionally limited to the two files the
    /// existing builder reads, in its existing order and with its existing 12,000-character
    /// truncation rule.
    public static func build(
        cwd: String,
        skills: String = "",
        memory: String = "",
        includeContextFiles: Bool = true
    ) throws -> SystemPromptAssembly {
        let canonicalCWD = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let workingDirectoryID = "working-directory:path-sha256:\(pathDigest(canonicalCWD))"
        let workingBody = "You are a coding agent working in \(cwd) on a macOS machine."
        let baseBody = "\n\n" + [
            "You act by running Python in a persistent interpreter — that is your only tool, "
                + "and it is enough. State survives between calls, so build on what you have "
                + "already loaded instead of repeating work.",
            "",
            "`sh(command)` runs a shell command and returns {'stdout','stderr','status'}. Its "
                + "working directory and environment persist across calls, so `sh('cd sub')` "
                + "then `sh('pwd')` does what you would expect. `cwd()` reports where you are.",
            "",
            "Prefer the tools the repository already has — git, grep, and whatever its own "
                + "task runner exposes — over reimplementing them in Python.",
            "",
            "Say what you found, not what you are about to do. When you are finished, stop "
                + "calling tools and answer.",
        ].joined(separator: "\n")

        var sourceBodies: [(id: String, kind: PromptSourceKind, label: String, identity: String?,
            status: PromptSourceStatus, full: String?, delivered: String, rendered: String,
            deliveredOffset: Int)] = [
                (workingDirectoryID, .workingDirectory, "Working directory",
                 canonicalCWD, .present, workingBody, workingBody, workingBody, 0),
                ("base-instruction:v1", .baseInstruction, "Base instructions", "base:v1",
                 .present, baseBody, baseBody, baseBody, 0),
            ]

        if !memory.isEmpty {
            sourceBodies.append(("memory:rendered:v1", .memory, "Memory", "memory:rendered:v1",
                                 .present, memory, memory, "\n\n" + memory, 2))
        }
        if !skills.isEmpty {
            sourceBodies.append(("skill:rendered:v1", .skill, "Skills", "skill:rendered:v1",
                                 .present, skills, skills, "\n\n" + skills, 2))
        }

        for name in ["AGENTS.md", "CLAUDE.md"] {
            let identity = URL(fileURLWithPath: cwd).appendingPathComponent(name)
                .standardizedFileURL.path
            let sourceID = "context-file:path-sha256:\(pathDigest(identity))"
            if !includeContextFiles {
                sourceBodies.append((sourceID, .contextFile, name, identity,
                                     .disabled, nil, "", "", 0))
                continue
            }

            let url = URL(fileURLWithPath: cwd).appending(path: name)
            switch readContextFile(url, maximumBytes: Self.maximumContextFileBytes) {
            case .missing:
                sourceBodies.append((sourceID, .contextFile, name, identity,
                                     .missing, nil, "", "", 0))
                continue
            case .unreadable, .oversized:
                sourceBodies.append((sourceID, .contextFile, name, identity,
                                     .unreadable, nil, "", "", 0))
                continue
            case .body(let data):
                guard let fileText = String(data: data, encoding: .utf8) else {
                    sourceBodies.append((sourceID, .contextFile, name, identity,
                                         .unreadable, nil, "", "", 0))
                    continue
                }
                guard !fileText.isEmpty else {
                    sourceBodies.append((sourceID, .contextFile, name, identity,
                                         .present, "", "", "", 0))
                    continue
                }
                let status: PromptSourceStatus = fileText.count > 12_000 ? .truncated : .present
                let content = status == .truncated ? String(fileText.prefix(12_000)) : fileText
                let truncationMarker = status == .truncated ? "\n…(truncated)" : ""
                let framing = "\n\n## \(name) (from \(cwd))\n\n"
                let rendered = framing + content + truncationMarker
                sourceBodies.append((sourceID, .contextFile, name, identity,
                                     status, fileText, content, rendered,
                                     Data(framing.utf8).count))
            }
        }

        var offset = 0
        let sources = try sourceBodies.map { item -> PromptSource in
            let source = try PromptSource(
                sourceID: item.id, kind: item.kind, label: item.label, identity: item.identity,
                status: item.status, fullBody: item.full, deliveredBody: item.delivered,
                renderedBody: item.rendered,
                deliveredByteOffsetInRendered: item.deliveredOffset,
                renderedByteOffset: offset)
            offset += source.renderedByteCount
            return source
        }
        return try SystemPromptAssembly(text: sources.map(\.renderedBody).joined(), sources: sources)
    }

    private static func digest(_ data: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func pathDigest(_ path: String) -> String {
        AviarySHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private enum ContextFileRead {
        case missing
        case unreadable
        case oversized
        case body(Data)
    }

    /// Read one context file through a no-follow descriptor and a byte bound. The descriptor is
    /// opened before metadata and bytes are inspected, so a final-path symlink is rejected and
    /// ordinary small regular files retain their exact bytes. A file that grows past the bound
    /// during the read is rejected as oversized instead of being mistaken for a complete body.
    private static func readContextFile(_ url: URL, maximumBytes: Int) -> ContextFileRead {
        let descriptor = url.path.withCString {
            // O_NONBLOCK is immaterial for regular files but prevents a FIFO/device supplied at
            // the context path from blocking the agent before fstat can reject it.
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : .unreadable
        }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size >= 0 else {
            return .unreadable
        }
        let initialSize = information.st_size
        if initialSize > off_t(maximumBytes) { return .oversized }

        var result = Data()
        result.reserveCapacity(min(maximumBytes, Int(initialSize)))
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard result.count <= maximumBytes - count else { return .oversized }
                result.append(buffer, count: count)
                continue
            }
            if count == 0 {
                // A concurrent truncate/append must not turn a partial body into an apparently
                // complete source. The open descriptor keeps the inode stable, so size is the
                // useful bounded consistency check here.
                guard fstat(descriptor, &information) == 0,
                      information.st_size == initialSize else { return .unreadable }
                return .body(result)
            }
            if errno == EINTR { continue }
            return .unreadable
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case byteCount = "byte_count"
        case digest
        case sources
    }

    /// Encode only a bounded decomposition manifest; the exact prompt and all source bodies
    /// remain in memory for a later capability-gated retention decision.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schemaVersion)
        try c.encode(byteCount, forKey: .byteCount)
        try c.encode(digest, forKey: .digest)
        try c.encode(sources, forKey: .sources)
    }
}
