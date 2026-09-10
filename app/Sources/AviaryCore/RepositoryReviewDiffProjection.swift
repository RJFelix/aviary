import Foundation

/// The authenticated identity of a repository-review artifact.  It is copied from the exact
/// descriptor selected by the Work controller; review body fields never supply or replace it.
public struct RepositoryReviewFeedbackIdentity: Codable, Hashable, Sendable {
    public let artifactID: String
    public let artifactDigest: String
    public let work: WorkRef
    public let session: SessionRef
    public let sessionAttachment: SessionAttachmentRef
    public let run: RunRef
    public let turn: TurnRef

    public enum ValidationError: Error, Equatable, Sendable {
        case notRepositoryReview
        case missingDigest
        case missingTurn
    }

    public init(descriptor: WorkServiceArtifactDescriptor) throws {
        guard descriptor.mediaType == ObservedRepositoryReviewFormat.mediaType else {
            throw ValidationError.notRepositoryReview
        }
        guard let digest = descriptor.digest, !digest.isEmpty else {
            throw ValidationError.missingDigest
        }
        guard let turn = descriptor.turn else { throw ValidationError.missingTurn }
        self.artifactID = descriptor.artifactID
        self.artifactDigest = digest
        self.work = descriptor.work
        self.session = descriptor.session
        self.sessionAttachment = descriptor.sessionAttachment
        self.run = descriptor.run
        self.turn = turn
    }
}

public struct RepositoryReviewDiffLimits: Codable, Equatable, Sendable {
    public let maximumSections: Int
    public let maximumHunksPerSection: Int
    public let maximumRawSectionBytes: Int
    public let maximumFallbackBytes: Int
    public let maximumContextBytes: Int
    /// A smaller evidence bound for feedback anchors. Display context may be larger, but the
    /// complete identity prefix plus this context must still fit the draft composer.
    public let maximumAnchorContextBytes: Int
    public let maximumPathBytes: Int
    public let maximumOmissions: Int

    public static let `default` = Self(
        maximumSections: 512,
        maximumHunksPerSection: 128,
        maximumRawSectionBytes: 64 * 1024,
        maximumFallbackBytes: 64 * 1024,
        maximumContextBytes: 8 * 1024,
        maximumAnchorContextBytes: 384,
        maximumPathBytes: 4 * 1024,
        maximumOmissions: 256)

    public init(
        maximumSections: Int = 512,
        maximumHunksPerSection: Int = 128,
        maximumRawSectionBytes: Int = 64 * 1024,
        maximumFallbackBytes: Int = 64 * 1024,
        maximumContextBytes: Int = 8 * 1024,
        maximumAnchorContextBytes: Int = 384,
        maximumPathBytes: Int = 4 * 1024,
        maximumOmissions: Int = 256
    ) {
        self.maximumSections = min(4_096, max(1, maximumSections))
        self.maximumHunksPerSection = min(1_024, max(1, maximumHunksPerSection))
        self.maximumRawSectionBytes = min(4 * 1024 * 1024, max(256, maximumRawSectionBytes))
        self.maximumFallbackBytes = min(4 * 1024 * 1024, max(256, maximumFallbackBytes))
        self.maximumContextBytes = min(256 * 1024, max(0, maximumContextBytes))
        self.maximumAnchorContextBytes = min(64 * 1024, max(0, maximumAnchorContextBytes))
        self.maximumPathBytes = min(64 * 1024, max(1, maximumPathBytes))
        self.maximumOmissions = min(4_096, max(1, maximumOmissions))
    }
}

public enum RepositoryReviewDiffFileKind: String, Codable, Hashable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case binary
    case submodule
    case unknown
}

public struct RepositoryReviewDiffRawFallback: Codable, Hashable, Sendable {
    public let diffKind: String
    public let text: String
    public let truncated: Bool
    public let reason: String

    public init(diffKind: String, text: String, truncated: Bool, reason: String) {
        self.diffKind = diffKind
        self.text = text
        self.truncated = truncated
        self.reason = reason
    }
}

public struct RepositoryReviewFeedbackAnchor: Codable, Hashable, Sendable {
    public let identity: RepositoryReviewFeedbackIdentity
    public let diffKind: String
    public let path: String
    public let originalPath: String?
    public let hunkHeader: String?
    public let context: String
    public let contextTruncated: Bool

    public init(
        identity: RepositoryReviewFeedbackIdentity,
        diffKind: String,
        path: String,
        originalPath: String?,
        hunkHeader: String?,
        context: String,
        contextTruncated: Bool
    ) {
        self.identity = identity
        self.diffKind = diffKind
        self.path = path
        self.originalPath = originalPath
        self.hunkHeader = hunkHeader
        self.context = context
        self.contextTruncated = contextTruncated
    }

    /// Stable, explicit metadata placed before user text.  The identity portion is never capped;
    /// callers receive a capacity error instead of a misleading partial artifact identity.
    public var renderedPrefix: String {
        var lines = [
            "Repository review feedback",
            "artifact_id: \(Self.quoted(identity.artifactID))",
            "artifact_digest: \(Self.quoted(identity.artifactDigest))",
            "work_host_id: \(Self.quoted(identity.work.workHostID))",
            "work_id: \(Self.quoted(identity.work.workID))",
            "session: \(Self.quoted(identity.session.sessionID))",
            "session_attachment: \(Self.quoted(identity.sessionAttachment.attachmentID))",
            "run: \(Self.quoted(identity.run.runID))",
            "turn: \(Self.quoted(identity.turn.turnID))",
            "diff: \(Self.quoted(diffKind))",
            "file: \(Self.quoted(path))",
        ]
        if let originalPath { lines.append("renamed_from: \(Self.quoted(originalPath))") }
        if let hunkHeader { lines.append("hunk: \(Self.quoted(hunkHeader))") }
        if !context.isEmpty {
            lines.append("context:")
            lines.append(context)
            if contextTruncated { lines.append("[context truncated by review bounds]") }
        }
        lines.append("feedback:")
        return lines.joined(separator: "\n")
    }

    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let result = String(data: data, encoding: .utf8) else { return "\"\"" }
        return result
    }

    public enum CompositionError: Error, Equatable, Sendable {
        case emptyFeedback
        case invalidCapacity
        case prefixExceedsCapacity(requiredBytes: Int, maximumBytes: Int)
    }

    /// Compose bounded literal feedback for the existing revision draft.  Only the user text may
    /// be shortened, at extended-grapheme boundaries; the complete anchor prefix is all-or-nothing.
    public func composeFeedback(_ text: String, maximumBytes: Int = 2_000) throws -> String {
        guard maximumBytes > 0 else { throw CompositionError.invalidCapacity }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompositionError.emptyFeedback
        }
        let prefix = renderedPrefix + "\n"
        let prefixBytes = prefix.utf8.count
        guard prefixBytes + 1 <= maximumBytes else {
            throw CompositionError.prefixExceedsCapacity(
                requiredBytes: prefixBytes + 1, maximumBytes: maximumBytes)
        }
        let remaining = maximumBytes - prefixBytes
        var used = 0
        var end = text.startIndex
        for character in text {
            let count = String(character).utf8.count
            guard used <= remaining - count else { break }
            used += count
            end = text.index(after: end)
        }
        let bounded = String(text[..<end])
        guard !bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompositionError.emptyFeedback
        }
        return prefix + bounded
    }
}

public struct RepositoryReviewDiffHunk: Codable, Hashable, Sendable {
    public let header: String
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let context: String
    public let contextTruncated: Bool
    public let anchorContext: String
    public let anchorContextTruncated: Bool

    public init(
        header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
        context: String, contextTruncated: Bool, anchorContext: String? = nil,
        anchorContextTruncated: Bool? = nil
    ) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.context = context
        self.contextTruncated = contextTruncated
        let candidateAnchorContext = anchorContext ?? context
        if candidateAnchorContext.utf8.count <= context.utf8.count {
            self.anchorContext = candidateAnchorContext
            self.anchorContextTruncated = anchorContextTruncated ?? contextTruncated
        } else {
            self.anchorContext = context
            self.anchorContextTruncated = true
        }
    }
}

public struct RepositoryReviewDiffSection: Codable, Hashable, Sendable {
    public let diffKind: String
    public let path: String?
    public let originalPath: String?
    public let kind: RepositoryReviewDiffFileKind
    public let hunks: [RepositoryReviewDiffHunk]
    public let rawSection: String
    public let rawSectionTruncated: Bool
    public let fallbackReason: String?

    public init(
        diffKind: String, path: String?, originalPath: String?,
        kind: RepositoryReviewDiffFileKind, hunks: [RepositoryReviewDiffHunk],
        rawSection: String, rawSectionTruncated: Bool, fallbackReason: String?
    ) {
        self.diffKind = diffKind
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.hunks = hunks
        self.rawSection = rawSection
        self.rawSectionTruncated = rawSectionTruncated
        self.fallbackReason = fallbackReason
    }

    public func fileAnchor(identity: RepositoryReviewFeedbackIdentity)
        -> RepositoryReviewFeedbackAnchor? {
        let fileOnlyFallback = fallbackReason ==
            "binary diff body was excluded by the observation contract"
            || fallbackReason == "submodule diff body was excluded by the observation contract"
        guard let path, fallbackReason == nil || fileOnlyFallback else {
            return nil
        }
        return RepositoryReviewFeedbackAnchor(
            identity: identity, diffKind: diffKind, path: path, originalPath: originalPath,
            hunkHeader: nil, context: "", contextTruncated: false)
    }

    public func hunkAnchors(identity: RepositoryReviewFeedbackIdentity)
        -> [RepositoryReviewFeedbackAnchor] {
        guard let path, fallbackReason == nil else { return [] }
        return hunks.map {
            RepositoryReviewFeedbackAnchor(
                identity: identity, diffKind: diffKind, path: path,
                originalPath: originalPath, hunkHeader: $0.header,
                context: $0.anchorContext, contextTruncated: $0.anchorContextTruncated)
        }
    }
}

public struct RepositoryReviewDiffProjection: Codable, Hashable, Sendable {
    public let identity: RepositoryReviewFeedbackIdentity
    public let sections: [RepositoryReviewDiffSection]
    public let rawFallbacks: [RepositoryReviewDiffRawFallback]
    public let omissions: [String]
    public let isStructured: Bool

    public static func prepare(
        review: ObservedRepositoryReview,
        descriptor: WorkServiceArtifactDescriptor,
        limits: RepositoryReviewDiffLimits = .default
    ) throws -> Self {
        try Self(review: review, descriptor: descriptor, limits: limits)
    }

    public init(
        review: ObservedRepositoryReview,
        descriptor: WorkServiceArtifactDescriptor,
        limits: RepositoryReviewDiffLimits = .default
    ) throws {
        let identity = try RepositoryReviewFeedbackIdentity(descriptor: descriptor)
        guard review.matchesCanonicalSource(of: descriptor) else {
            throw RepositoryReviewFeedbackIdentity.ValidationError.notRepositoryReview
        }
        self.identity = identity
        var sections: [RepositoryReviewDiffSection] = []
        var fallbacks: [RepositoryReviewDiffRawFallback] = []
        var omissions: [String] = []
        var seenSectionKeys = Set<String>()
        var structurallyComplete = true

        func recordOmission(_ value: String) {
            guard omissions.count < limits.maximumOmissions else { return }
            omissions.append(value)
        }

        for diff in review.diffs {
            guard diff.kind == "staged" || diff.kind == "unstaged" else {
                structurallyComplete = false
                recordOmission("unknown diff kind")
                continue
            }
            guard let text = diff.text, !text.isEmpty else { continue }
            if diff.truncated {
                structurallyComplete = false
                fallbacks.append(Self.fallback(
                    diffKind: diff.kind, text: text, limit: limits.maximumFallbackBytes,
                    reason: "diff text was truncated by the observation boundary"))
                continue
            }
            let rawSections = Self.splitSections(text)
            guard diff.retainedSectionCount == rawSections.count else {
                structurallyComplete = false
                fallbacks.append(Self.fallback(
                    diffKind: diff.kind, text: text, limit: limits.maximumFallbackBytes,
                    reason: "retained diff section count did not match the observation"))
                continue
            }
            guard !rawSections.isEmpty else {
                structurallyComplete = false
                fallbacks.append(Self.fallback(
                    diffKind: diff.kind, text: text, limit: limits.maximumFallbackBytes,
                    reason: "diff did not contain a line-start diff header"))
                continue
            }
            for raw in rawSections {
                guard sections.count < limits.maximumSections else {
                    structurallyComplete = false
                    recordOmission("diff section count exceeded review bounds")
                    fallbacks.append(Self.fallback(
                        diffKind: diff.kind, text: raw, limit: limits.maximumFallbackBytes,
                        reason: "diff section omitted by review bounds"))
                    continue
                }
                let parsed = Self.parseSection(
                    raw, diffKind: diff.kind, files: review.files, limits: limits)
                if let path = parsed.section.path {
                    let key = "\(diff.kind)\u{0}\(path)"
                    guard seenSectionKeys.insert(key).inserted else {
                        structurallyComplete = false
                        fallbacks.append(Self.fallback(
                            diffKind: diff.kind, text: raw, limit: limits.maximumFallbackBytes,
                            reason: "duplicate diff stream and file path"))
                        continue
                    }
                }
                sections.append(parsed.section)
                if let reason = parsed.reason {
                    structurallyComplete = false
                    fallbacks.append(Self.fallback(
                        diffKind: diff.kind, text: raw, limit: limits.maximumFallbackBytes,
                        reason: reason))
                }
            }
        }

        // Binary/submodule bodies are intentionally absent from ObservedRepositoryDiff.  Add
        // truthful file-only anchors from status metadata, without assigning them to an unknown
        // staged/unstaged stream.
        for file in review.files where file.isBinary || file.isSubmodule {
            let fileKind: RepositoryReviewDiffFileKind = file.isSubmodule ? .submodule : .binary
            var diffKinds: [String] = []
            if file.indexStatus != "." { diffKinds.append("staged") }
            if file.workTreeStatus != "." { diffKinds.append("unstaged") }
            guard !diffKinds.isEmpty else {
                recordOmission("binary or submodule file had no unambiguous diff stream")
                structurallyComplete = false
                continue
            }
            for diffKind in diffKinds {
                guard sections.count < limits.maximumSections else {
                    structurallyComplete = false
                    recordOmission("binary or submodule section omitted by review bounds")
                    continue
                }
                let key = "\(diffKind)\u{0}\(file.path)"
                guard seenSectionKeys.insert(key).inserted else {
                    structurallyComplete = false
                    recordOmission("duplicate diff stream and file path")
                    continue
                }
                sections.append(RepositoryReviewDiffSection(
                    diffKind: diffKind, path: file.path, originalPath: file.originalPath,
                    kind: fileKind, hunks: [], rawSection: "", rawSectionTruncated: false,
                    fallbackReason: fileKind == .binary
                        ? "binary diff body was excluded by the observation contract"
                        : "submodule diff body was excluded by the observation contract"))
            }
        }

        self.sections = sections
        self.rawFallbacks = fallbacks
        self.omissions = omissions
        self.isStructured = structurallyComplete
    }

    private static func fallback(
        diffKind: String, text: String, limit: Int, reason: String
    ) -> RepositoryReviewDiffRawFallback {
        let capped = cap(text, bytes: limit)
        return RepositoryReviewDiffRawFallback(
            diffKind: diffKind, text: capped.value, truncated: capped.truncated, reason: reason)
    }

    private static func splitSections(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var current = ""
        for (index, line) in lines.enumerated() {
            let suffix = index + 1 < lines.count ? "\n" : ""
            if line.hasPrefix("diff --git ") && !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += line + suffix
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func parseSection(
        _ raw: String,
        diffKind: String,
        files: [ObservedRepositoryFile],
        limits: RepositoryReviewDiffLimits
    ) -> (section: RepositoryReviewDiffSection, reason: String?) {
        let lines = raw.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let header = lines.first ?? ""
        let paths = parseHeaderPaths(header, maximumPathBytes: limits.maximumPathBytes)
        var path = paths?.newPath
        var originalPath: String?
        var reason: String?
        if paths == nil {
            reason = "diff header paths were malformed or ambiguous"
            path = nil
            originalPath = nil
        }

        var kind: RepositoryReviewDiffFileKind = .modified
        var sawMalformedHunk = false
        var hunkStarts: [Int] = []
        var firstHunkIndex: Int?
        var renameFrom: String?
        var renameTo: String?
        var sawRenameFrom = false
        var sawRenameTo = false
        var patchOldPath: String?
        var patchNewPath: String?
        var sawPatchOldPath = false
        var sawPatchNewPath = false
        var sawBinaryMarker = false
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("@@") {
                firstHunkIndex = firstHunkIndex ?? index
                if parseHunkHeader(line) != nil { hunkStarts.append(index) }
                else { sawMalformedHunk = true }
                continue
            }
            guard firstHunkIndex == nil else { continue }
            if line.hasPrefix("new file mode ") { kind = .added }
            if line.hasPrefix("deleted file mode ") { kind = .deleted }
            if line.hasPrefix("rename from ") {
                sawRenameFrom = true
                renameFrom = parsePathValue(
                    String(line.dropFirst(12)), maximumPathBytes: limits.maximumPathBytes)
            }
            if line.hasPrefix("rename to ") {
                sawRenameTo = true
                renameTo = parsePathValue(
                    String(line.dropFirst(10)), maximumPathBytes: limits.maximumPathBytes)
            }
            if line.hasPrefix("--- ") {
                sawPatchOldPath = true
                patchOldPath = parsePatchPath(
                    String(line.dropFirst(4)), maximumPathBytes: limits.maximumPathBytes)
            }
            if line.hasPrefix("+++ ") {
                sawPatchNewPath = true
                patchNewPath = parsePatchPath(
                    String(line.dropFirst(4)), maximumPathBytes: limits.maximumPathBytes)
            }
            if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
                sawBinaryMarker = true
            }
        }
        if let paths {
            if sawRenameFrom && renameFrom == nil {
                reason = reason ?? "rename-from path was malformed"
            }
            if sawRenameTo && renameTo == nil {
                reason = reason ?? "rename-to path was malformed"
            }
            if let renameFrom {
                if renameFrom != paths.oldPath {
                    reason = reason ?? "rename-from path disagreed with the diff header"
                    originalPath = nil
                    path = nil
                } else {
                    originalPath = renameFrom
                }
            }
            if let renameTo {
                if renameTo != paths.newPath {
                    reason = reason ?? "rename-to path disagreed with the diff header"
                    path = nil
                } else {
                    path = renameTo
                }
            }
            if sawRenameFrom || sawRenameTo { kind = .renamed }
            func patchAgrees(_ patchPath: String?, headerPath: String, allowNull: Bool) -> Bool {
                guard let patchPath else { return true }
                if allowNull && patchPath == "/dev/null" { return true }
                return patchPath == headerPath
            }
            if (sawPatchOldPath && (patchOldPath == nil || !patchAgrees(
                patchOldPath, headerPath: paths.oldPath, allowNull: kind == .added)))
                || (sawPatchNewPath && (patchNewPath == nil || !patchAgrees(
                    patchNewPath, headerPath: paths.newPath, allowNull: kind == .deleted))) {
                reason = reason ?? "patch file paths disagreed with the diff header"
            }
        }
        if sawMalformedHunk { reason = reason ?? "a hunk header was malformed" }
        if kind == .renamed && (path == nil || originalPath == nil) {
            reason = reason ?? "rename paths were malformed or ambiguous"
        }
        if let paths, paths.oldPath != paths.newPath, kind != .renamed {
            reason = reason ?? "different header paths lacked rename evidence"
        }
        if path == nil && kind != .binary && kind != .submodule {
            reason = reason ?? "file path was not proven"
        }
        if let path, !scopedFileExists(
            path: path, originalPath: originalPath, diffKind: diffKind, files: files) {
            reason = reason ?? "file path was not present in the scoped status"
        }
        if let file = path.flatMap({ path in files.first { $0.path == path } }) {
            if file.isBinary { kind = .binary }
            if file.isSubmodule { kind = .submodule }
            if sawBinaryMarker && !file.isBinary {
                reason = reason ?? "binary marker lacked matching binary file status"
            }
        }
        var hunks: [RepositoryReviewDiffHunk] = []
        if !sawMalformedHunk {
            for (offset, start) in hunkStarts.prefix(limits.maximumHunksPerSection).enumerated() {
                guard let range = parseHunkHeader(lines[start]) else { continue }
                let end = offset + 1 < hunkStarts.count
                    ? hunkStarts[offset + 1] : lines.count
                let body = Array(lines[(start + 1)..<end])
                guard body.allSatisfy({ $0.isEmpty || $0.first == " " || $0.first == "+"
                    || $0.first == "-" || $0.first == "\\" }) else {
                    reason = reason ?? "a hunk body contained an invalid line"
                    continue
                }
                var oldLines = 0
                var newLines = 0
                for line in body {
                    guard let first = line.first else { continue }
                    switch first {
                    case " ": oldLines += 1; newLines += 1
                    case "-": oldLines += 1
                    case "+": newLines += 1
                    default: break
                    }
                }
                guard oldLines == range.oldCount, newLines == range.newCount else {
                    reason = reason ?? "hunk body line counts did not match its header"
                    continue
                }
                let capped = cap(body.joined(separator: "\n"), bytes: limits.maximumContextBytes)
                let anchorCapped = cap(
                    body.joined(separator: "\n"),
                    bytes: min(limits.maximumAnchorContextBytes, limits.maximumContextBytes))
                hunks.append(RepositoryReviewDiffHunk(
                    header: lines[start], oldStart: range.oldStart, oldCount: range.oldCount,
                    newStart: range.newStart, newCount: range.newCount,
                    context: capped.value, contextTruncated: capped.truncated,
                    anchorContext: anchorCapped.value,
                    anchorContextTruncated: anchorCapped.truncated))
            }
            if hunkStarts.count > limits.maximumHunksPerSection {
                reason = reason ?? "hunk count exceeded review bounds"
            }
        }
        let rawValue = cap(raw, bytes: limits.maximumRawSectionBytes)
        return (RepositoryReviewDiffSection(
            diffKind: diffKind, path: path, originalPath: originalPath, kind: kind,
            hunks: hunks, rawSection: rawValue.value, rawSectionTruncated: rawValue.truncated,
            fallbackReason: reason), reason)
    }

    private static func scopedFileExists(
        path: String,
        originalPath: String?,
        diffKind: String,
        files: [ObservedRepositoryFile]
    ) -> Bool {
        files.contains { file in
            guard file.path == path else { return false }
            let streamObserved = diffKind == "staged"
                ? file.indexStatus != "." : file.workTreeStatus != "."
            guard streamObserved else { return false }
            return file.originalPath == originalPath
        }
    }

    private static func parseHunkHeader(_ line: String)
        -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let pattern = #"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@(?: .*)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func number(_ index: Int, default value: Int = 1) -> Int? {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: line) else { return value }
            return Int(line[swiftRange])
        }
        guard let oldStart = number(1), let oldCount = number(2),
              let newStart = number(3), let newCount = number(4) else { return nil }
        return (oldStart, oldCount, newStart, newCount)
    }

    private static func parseHeaderPaths(
        _ line: String, maximumPathBytes: Int
    ) -> (oldPath: String, newPath: String)? {
        guard line.hasPrefix("diff --git ") else { return nil }
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.first == "\"" {
            let bytes = Array(rest.utf8)
            guard let first = parseQuotedToken(bytes, start: 0) else { return nil }
            var secondStart = first.end
            while secondStart < bytes.count && (bytes[secondStart] == 0x20 || bytes[secondStart] == 0x09) {
                secondStart += 1
            }
            guard let second = parseQuotedToken(bytes, start: secondStart),
                  let oldPath = validHeaderPath(first.value, maximumBytes: maximumPathBytes),
                  let newPath = validHeaderPath(second.value, maximumBytes: maximumPathBytes) else {
                return nil
            }
            guard bytes[second.end...].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return nil }
            return (oldPath, newPath)
        }
        let bytes = Array(rest.utf8)
        guard rest.hasPrefix("a/") else { return nil }
        var candidates: [(String, String)] = []
        if bytes.count >= 5 {
            for index in 2..<(bytes.count - 2) where bytes[index] == 0x20
                && bytes[index + 1] == UInt8(ascii: "b") && bytes[index + 2] == UInt8(ascii: "/") {
                let old = String(decoding: bytes[2..<index], as: UTF8.self)
                let new = String(decoding: bytes[(index + 3)...], as: UTF8.self)
                if let old = validRepositoryPath(old, maximumBytes: maximumPathBytes),
                   let new = validRepositoryPath(new, maximumBytes: maximumPathBytes) {
                    candidates.append((old, new))
                }
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func parsePatchPath(_ value: String, maximumPathBytes: Int) -> String? {
        let token = value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? value
        if token == "/dev/null" { return token }
        if token.first == "\"" {
            guard let parsed = parseQuotedToken(Array(token.utf8), start: 0),
                  parsed.end == token.utf8.count else { return nil }
            return validHeaderPath(parsed.value, maximumBytes: maximumPathBytes)
        }
        return validHeaderPath(token, maximumBytes: maximumPathBytes)
    }

    private static func parsePathValue(_ value: String, maximumPathBytes: Int) -> String? {
        if value.first == "\"" {
            guard let parsed = parseQuotedToken(Array(value.utf8), start: 0),
                  parsed.end == value.utf8.count else { return nil }
            return validRepositoryPath(parsed.value, maximumBytes: maximumPathBytes)
        }
        return validRepositoryPath(value, maximumBytes: maximumPathBytes)
    }

    private static func parseQuotedToken(_ bytes: [UInt8], start: Int)
        -> (value: String, end: Int)? {
        guard start < bytes.count, bytes[start] == 0x22 else { return nil }
        var output: [UInt8] = []
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                return String(data: Data(output), encoding: .utf8).map { ($0, index + 1) }
            }
            if byte != 0x5c { output.append(byte); index += 1; continue }
            guard index + 1 < bytes.count else { return nil }
            let escaped = bytes[index + 1]
            switch escaped {
            case 0x22, 0x5c: output.append(escaped); index += 2
            case 0x6e: output.append(0x0a); index += 2
            case 0x72: output.append(0x0d); index += 2
            case 0x74: output.append(0x09); index += 2
            case 0x30...0x37:
                var value = 0
                var end = index + 1
                while end < bytes.count && end < index + 4,
                      (0x30...0x37).contains(bytes[end]) {
                    value = value * 8 + Int(bytes[end] - 0x30)
                    end += 1
                }
                guard value <= 255 else { return nil }
                output.append(UInt8(value)); index = end
            default: return nil
            }
        }
        return nil
    }

    private static func validHeaderPath(_ path: String, maximumBytes: Int) -> String? {
        guard let repositoryPath = validRepositoryPath(path, maximumBytes: maximumBytes) else {
            return nil
        }
        let normalized = repositoryPath.hasPrefix("a/") || repositoryPath.hasPrefix("b/")
            ? String(repositoryPath.dropFirst(2)) : repositoryPath
        return normalized.isEmpty ? nil : normalized
    }

    private static func validRepositoryPath(_ path: String, maximumBytes: Int) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("."),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              path.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7f
                      && !(0x80...0x9f).contains(scalar.value)
                      && scalar.value != 0x2028 && scalar.value != 0x2029
              }) else { return nil }
        guard path.utf8.count <= maximumBytes else { return nil }
        return path
    }

    private static func cap(_ value: String, bytes limit: Int) -> (value: String, truncated: Bool) {
        guard value.utf8.count > limit else { return (value, false) }
        var used = 0
        var end = value.startIndex
        for character in value {
            let count = String(character).utf8.count
            guard used <= limit - count else { break }
            used += count
            end = value.index(after: end)
        }
        return (String(value[..<end]), true)
    }
}
