import Foundation

/// Documents an agent produced, written to disk instead of into the reply.
///
/// The occasion for this: a session was asked for a report, wrote several thousand excellent
/// words, and delivered them as one assistant message. Everything about that is wrong for the
/// thing produced — it cannot be opened, edited, diffed or sent to anyone, and it is billed
/// into the context of every subsequent turn.
///
/// Storage is Aviary's, not Python's. The kernel does not know the session id and has no
/// business choosing a directory, so `artifact()` is a callback like `remember()` and this is
/// what serves it. That also means the same bytes land in the same place whichever engine is
/// driving, which is the invariant `Builtins` exists to protect.
public enum ArtifactFormat: String, Sendable, Hashable, CaseIterable {
    case markdown = "md"
    case text = "txt"
    case html

    /// The extension written on disk. Same as the name the agent passes, deliberately: two
    /// vocabularies for one concept is a lookup table nobody remembers to update.
    public var fileExtension: String { rawValue }

    public var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .text: return "Plain text"
        case .html: return "HTML"
        }
    }

    /// Accepts the obvious synonyms as well as the canonical name.
    ///
    /// Not politeness. The call that gets this wrong is the one that already spent the tokens
    /// writing the report, and losing a finished document to `format='markdown'` is a bad
    /// trade for a stricter parser.
    public static func parse(_ raw: String) -> ArtifactFormat? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "md", "markdown", "mdown": return .markdown
        case "txt", "text", "plain": return .text
        case "html", "htm": return .html
        default: return nil
        }
    }

    public static var supportedList: String {
        allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }
}

/// Writes a session's artifacts, and never overwrites one.
///
/// Mirrors `ScheduleStore`: constructed from the home and the session id, so the caller does
/// not have to know the layout.
public struct ArtifactStore: Sendable, Hashable {
    public let home: AgentHome
    public let sessionID: String

    public init(home: AgentHome, sessionID: String) {
        self.home = home
        self.sessionID = sessionID
    }

    public var directory: URL { home.artifactDocuments(forSession: sessionID) }

    /// One written document, in the shape the agent gets back.
    public struct Written: Sendable, Hashable {
        /// The filename stem. Unique within the session because the filename is, which makes
        /// it something the agent can refer to in a later turn without holding a path.
        public var id: String
        public var title: String
        public var format: ArtifactFormat
        public var url: URL
        public var byteCount: Int

        /// The reply `artifact()` returns.
        public var payload: JSONValue {
            .object([
                "id": .string(id),
                "title": .string(title),
                "format": .string(format.rawValue),
                "path": .string(url.path),
                "bytes": .number(Double(byteCount)),
            ])
        }

        public var note: ArtifactNote {
            ArtifactNote(
                title: title, format: format.rawValue, byteCount: byteCount, path: url.path)
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case emptyText
        case unsupportedFormat(String)
        case couldNotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .emptyText:
                return "artifact() needs some text to write."
            case .unsupportedFormat(let raw):
                return "artifact() cannot write '\(raw)'. Supported formats: "
                    + "\(ArtifactFormat.supportedList)."
            case .couldNotWrite(let detail):
                return "Could not write the artifact: \(detail)"
            }
        }
    }

    @discardableResult
    public func write(text: String, title: String?, format rawFormat: String) throws -> Written {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyText
        }
        guard let format = ArtifactFormat.parse(rawFormat) else {
            throw Failure.unsupportedFormat(rawFormat)
        }
        let resolvedTitle = Self.resolveTitle(title, text: text)
        let data = Data(text.utf8)

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure.couldNotWrite(error.localizedDescription)
        }

        // Never overwrite. An agent that writes "Findings" twice in a session means two
        // documents, and silently replacing the first destroys work with no error anywhere —
        // the same class of loss this whole feature exists to prevent.
        //
        // `.withoutOverwriting` rather than trusting the existence check: the check and the
        // write are not one operation, and a sub-agent writing concurrently into its parent's
        // session is a real arrangement here.
        let stem = Self.slug(resolvedTitle)
        for attempt in 1...200 {
            let candidate = attempt == 1 ? stem : "\(stem)-\(attempt)"
            let url = directory.appending(path: "\(candidate).\(format.fileExtension)")
            do {
                try data.write(to: url, options: .withoutOverwriting)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                && error.code == NSFileWriteFileExistsError
            {
                continue
            } catch {
                throw Failure.couldNotWrite(error.localizedDescription)
            }
            return Written(
                id: candidate, title: resolvedTitle, format: format, url: url,
                byteCount: data.count)
        }
        throw Failure.couldNotWrite(
            "200 artifacts in this session are already named '\(stem)'. Give this one a "
                + "distinct title.")
    }

    /// Everything written for this session, newest last.
    public func list() -> [Written] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> Written? in
            guard let format = ArtifactFormat.parse(url.pathExtension) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let stem = url.deletingPathExtension().lastPathComponent
            return Written(
                id: stem, title: stem, format: format, url: url, byteCount: size)
        }.sorted { $0.id < $1.id }
    }

    // MARK: Naming

    /// A title for an untitled document.
    ///
    /// Taken from the text's own first heading, because a report almost always opens with one
    /// and `artifact-3.md` is a file nobody opens again.
    static func resolveTitle(_ given: String?, text: String) -> String {
        if let given {
            let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let stripped = line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*_ \t"))
            if !stripped.isEmpty { return String(stripped.prefix(120)) }
        }
        return "Untitled"
    }

    /// A filename stem from a title: lowercase, ASCII, hyphen-separated.
    ///
    /// Conservative on purpose. A title is model-written text and may hold slashes, dots and
    /// leading hyphens, all of which mean something to a filesystem or an argument parser.
    static func slug(_ title: String) -> String {
        var out = ""
        var pendingSeparator = false
        for scalar in title.folding(options: .diacriticInsensitive, locale: .current).unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber, scalar.isASCII {
                if pendingSeparator, !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(Character(scalar).lowercased())
            } else {
                pendingSeparator = true
            }
        }
        let capped = String(out.prefix(60))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return capped.isEmpty ? "artifact" : capped
    }
}

/// What the transcript records when an artifact is written.
///
/// Labelled lines rather than JSON: any reader that has never heard of an artifact — an older
/// Aviary, a `cat` of the JSONL, the raw pane — shows the note verbatim and it still says what
/// happened and where the file is. The card in the transcript is a nicety on top of that, not
/// the only way to read it.
public struct ArtifactNote: Sendable, Hashable {
    public static let customType = "aviary.artifact"

    public var title: String
    public var format: String
    public var byteCount: Int
    public var path: String

    public init(title: String, format: String, byteCount: Int, path: String) {
        self.title = title
        self.format = format
        self.byteCount = byteCount
        self.path = path
    }

    public var url: URL { URL(fileURLWithPath: path) }

    public var text: String {
        """
        Artifact: \(title)
        Format: \(format)
        Bytes: \(byteCount)
        Path: \(path)
        """
    }

    /// Read one back. Forgiving in the house style: an unknown line is ignored, and only a
    /// missing title or path makes this not an artifact note at all.
    public static func parse(_ text: String) -> ArtifactNote? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        guard let title = fields["artifact"], !title.isEmpty,
              let path = fields["path"], !path.isEmpty
        else { return nil }
        return ArtifactNote(
            title: title, format: fields["format"] ?? "",
            byteCount: Int(fields["bytes"] ?? "") ?? 0, path: path)
    }
}

extension TranscriptItem {
    /// The artifact this row records, if it records one.
    ///
    /// Parsed in the core rather than in the view, because a view that parses is a view that
    /// has to be tested by looking at it.
    public var artifact: ArtifactNote? {
        guard customType == ArtifactNote.customType else { return nil }
        return ArtifactNote.parse(plainText)
    }
}
