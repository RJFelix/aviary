import Foundation

/// Block structure in an agent's prose.
///
/// The transcript used to render prose with `AttributedString(markdown:)` in
/// `inlineOnlyPreservingWhitespace` mode, which was a deliberate trade: full markdown parsing
/// collapses the newlines that structure an answer, and losing them makes a long reply
/// significantly harder to read. The cost of that trade was that every block construct —
/// headings, lists, fenced code, quotes, tables — rendered as its own literal syntax. A model
/// that writes a four-item numbered list got four lines beginning with a digit and a dot.
///
/// This resolves the trade rather than picking a side: split the text into blocks here, then
/// render inline markdown *within* each block. Newlines are preserved because block structure
/// is what decides them, not a general-purpose parser.
///
/// Deliberately not a CommonMark implementation. It handles what agents actually emit, and
/// where it cannot recognise something it falls through to a paragraph, so unrecognised input
/// degrades to exactly the old behaviour instead of disappearing.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// Inline-markdown prose. Internal newlines are hard breaks, kept as written.
    case paragraph(String)
    case list(MarkdownList)
    case quote([MarkdownBlock])
    case code(language: String?, source: String)
    case rule
    case table(MarkdownTable)
}

public struct MarkdownList: Equatable, Sendable {
    public var ordered: Bool
    public var items: [MarkdownListItem]

    public init(ordered: Bool, items: [MarkdownListItem]) {
        self.ordered = ordered
        self.items = items
    }
}

public struct MarkdownListItem: Equatable, Sendable {
    /// Nesting level, 0 for a top-level item.
    public var depth: Int
    /// The literal marker, so an ordered list that starts at 3 still reads as 3.
    public var marker: String
    public var text: String
    /// `nil` for a plain item; a checkbox state for a task-list item.
    public var checked: Bool?

    public init(depth: Int, marker: String, text: String, checked: Bool? = nil) {
        self.depth = depth
        self.marker = marker
        self.text = text
        self.checked = checked
    }
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }

    public var header: [String]
    public var alignments: [Alignment]
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

public enum MarkdownParser {
    /// Split prose into blocks.
    ///
    /// Single pass over the lines. A fence is checked before anything else, because the whole
    /// point of a fenced block is that its contents are not markdown.
    public static func blocks(from text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var out: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            if let fence = fenceMarker(trimmed) {
                let (block, next) = readFence(lines, from: i, fence: fence)
                out.append(block)
                i = next
                continue
            }

            if let heading = heading(trimmed) {
                out.append(heading)
                i += 1
                continue
            }

            if isRule(trimmed) {
                out.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                let (block, next) = readQuote(lines, from: i)
                out.append(block)
                i = next
                continue
            }

            if let table = readTable(lines, from: i) {
                out.append(table.0)
                i = table.1
                continue
            }

            if listMarker(line) != nil {
                let (block, next) = readList(lines, from: i)
                out.append(block)
                i = next
                continue
            }

            let (block, next) = readParagraph(lines, from: i)
            out.append(block)
            i = next
        }

        return out
    }

    // MARK: Fenced code

    /// The fence run and its character, or nil.
    ///
    /// Both fence characters are recognised, and the run length is carried so a fence inside a
    /// longer fence does not close it — which is how a model shows fenced markdown at all.
    private static func fenceMarker(_ trimmed: String) -> (char: Character, count: Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }.count
        guard run >= 3 else { return nil }
        // An info string may not contain a backtick, so ``` inline code never opens a block.
        if first == "`", trimmed.dropFirst(run).contains("`") { return nil }
        return (first, run)
    }

    private static func readFence(
        _ lines: [String], from start: Int, fence: (char: Character, count: Int)
    ) -> (MarkdownBlock, Int) {
        let opener = lines[start].trimmingCharacters(in: .whitespaces)
        let info = String(opener.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        var i = start + 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if let close = fenceMarker(trimmed), close.char == fence.char,
               close.count >= fence.count,
               trimmed.drop(while: { $0 == fence.char }).isEmpty
            {
                i += 1
                break
            }
            body.append(lines[i])
            i += 1
        }
        // An unclosed fence runs to the end rather than swallowing the block: a truncated
        // reply is the common cause, and showing the code is better than showing nothing.
        return (.code(language: info.isEmpty ? nil : info.lowercased(),
                      source: body.joined(separator: "\n")), i)
    }

    // MARK: Headings and rules

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        // ATX requires a space; `#hashtag` is prose, not a heading.
        guard rest.first == " " || rest.isEmpty else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
            // Closing hashes are decoration in some styles.
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        return .heading(level: hashes, text: text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        for char in ["-", "*", "_"] as [Character] {
            let stripped = trimmed.filter { !$0.isWhitespace }
            if stripped.count >= 3, stripped.allSatisfy({ $0 == char }) { return true }
        }
        return false
    }

    // MARK: Quotes

    private static func readQuote(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        var inner: [String] = []
        var i = start
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var stripped = String(trimmed.dropFirst())
            if stripped.hasPrefix(" ") { stripped.removeFirst() }
            inner.append(stripped)
            i += 1
        }
        // Recursive, so a quoted list or a quoted fence keeps its structure. The parser cannot
        // loop here: the quote prefix is consumed before the recursion.
        return (.quote(blocks(from: inner.joined(separator: "\n"))), i)
    }

    // MARK: Lists

    private struct Marker {
        var indent: Int
        var text: String
        var ordered: Bool
        var marker: String
        var checked: Bool?
    }

    private static func listMarker(_ line: String) -> Marker? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first else { return nil }

        func withTask(_ rest: Substring) -> (String, Bool?) {
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard text.count >= 3, text.first == "[", text.dropFirst(2).first == "]" else {
                return (text, nil)
            }
            let mark = text[text.index(after: text.startIndex)]
            guard mark == " " || mark == "x" || mark == "X" else { return (text, nil) }
            let after = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return (after, mark != " ")
        }

        if first == "-" || first == "*" || first == "+" {
            let rest = body.dropFirst()
            // A bare `-` is an empty item; `-word` is prose, and `---` was already a rule.
            guard rest.isEmpty || rest.first == " " else { return nil }
            let (text, checked) = withTask(rest)
            return Marker(indent: indent, text: text, ordered: false,
                          marker: String(first), checked: checked)
        }

        guard first.isNumber else { return nil }
        let digits = body.prefix { $0.isNumber }
        guard digits.count <= 9 else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let delim = afterDigits.first, delim == "." || delim == ")" else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return nil }
        let (text, checked) = withTask(rest)
        return Marker(indent: indent, text: text, ordered: true,
                      marker: String(digits) + String(delim), checked: checked)
    }

    private static func readList(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        guard let first = listMarker(lines[start]) else {
            return readParagraph(lines, from: start)
        }
        var items: [MarkdownListItem] = []
        // Indent columns seen so far, so depth reflects nesting order rather than an assumed
        // two- or four-space step. Models are inconsistent about which they use, sometimes
        // within one reply.
        var indents: [Int] = [first.indent]
        var i = start
        var sawBlank = false

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // One blank line inside a list is loose spacing; two ends it.
                if sawBlank { break }
                sawBlank = true
                i += 1
                continue
            }

            if let marker = listMarker(line) {
                let depth: Int
                if let level = indents.lastIndex(where: { $0 <= marker.indent }) {
                    // Outdenting discards the levels it left, so a later re-indent to the same
                    // column lands at the same depth rather than accumulating.
                    indents.removeSubrange((level + 1)...)
                    if indents[level] < marker.indent {
                        indents.append(marker.indent)
                        depth = level + 1
                    } else {
                        depth = level
                    }
                } else {
                    // Indented less than the item that opened the list. Treat that column as
                    // the new root rather than inventing a negative depth.
                    indents.insert(marker.indent, at: 0)
                    depth = 0
                }
                items.append(MarkdownListItem(depth: depth, marker: marker.marker,
                                             text: marker.text, checked: marker.checked))
                sawBlank = false
                i += 1
                continue
            }

            // A continuation line belongs to the item above when it is indented past the
            // list's own indent, or when the list is tight and it simply follows on.
            let indent = line.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if !items.isEmpty, indent > first.indent || !sawBlank {
                items[items.count - 1].text += "\n" + trimmed
                sawBlank = false
                i += 1
                continue
            }
            break
        }

        return (.list(MarkdownList(ordered: first.ordered, items: items)), i)
    }

    // MARK: Tables

    /// A pipe table, recognised only when the delimiter row is present.
    ///
    /// Requiring the delimiter matters: prose containing a pipe is far more common in agent
    /// output than a table is, and a permissive check turns `a | b` into a one-column table.
    private static func readTable(_ lines: [String], from start: Int) -> (MarkdownBlock, Int)? {
        guard start + 1 < lines.count else { return nil }
        let headerLine = lines[start].trimmingCharacters(in: .whitespaces)
        let delimLine = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|"), delimLine.contains("|") else { return nil }

        let header = cells(headerLine)
        let delims = cells(delimLine)
        guard header.count == delims.count, !header.isEmpty else { return nil }

        var alignments: [MarkdownTable.Alignment] = []
        for delim in delims {
            let d = delim.trimmingCharacters(in: .whitespaces)
            guard d.count >= 1, d.allSatisfy({ $0 == "-" || $0 == ":" }), d.contains("-") else {
                return nil
            }
            switch (d.hasPrefix(":"), d.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }

        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("|") else { break }
            var row = cells(trimmed)
            // Ragged rows are padded or clipped rather than rejected: a table with one short
            // row is still a table, and the alternative is showing the reader raw pipes.
            if row.count < header.count {
                row += Array(repeating: "", count: header.count - row.count)
            } else if row.count > header.count {
                row = Array(row.prefix(header.count))
            }
            rows.append(row)
            i += 1
        }

        return (.table(MarkdownTable(header: header, alignments: alignments, rows: rows)), i)
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = Substring(line)
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|") { trimmed = trimmed.dropLast() }
        // Split on unescaped pipes only, so `\|` can appear in a cell.
        var out: [String] = []
        var current = ""
        var escaped = false
        for ch in trimmed {
            if escaped {
                current.append(ch == "|" ? "|" : ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }

    // MARK: Paragraphs

    private static func readParagraph(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        var body: [String] = []
        var i = start
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            // A block construct interrupts a paragraph. Tables do not: the delimiter row is
            // only meaningful directly under a header, and checking here would make the very
            // common `a - b` prose line start one.
            if i > start,
               fenceMarker(trimmed) != nil || heading(trimmed) != nil || isRule(trimmed)
                   || trimmed.hasPrefix(">") || listMarker(line) != nil
            {
                break
            }
            body.append(line)
            i += 1
        }
        // Newlines survive, which is the whole reason this parser exists.
        return (.paragraph(body.joined(separator: "\n")), max(i, start + 1))
    }
}
