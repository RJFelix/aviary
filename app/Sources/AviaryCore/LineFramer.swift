import Foundation

/// Splits a byte stream into LF-delimited records, holding a partial trailing record
/// across reads.
///
/// LF only, and a trailing CR tolerated. Generic line readers are not usable here: they also
/// break on U+2028 and U+2029, which are legal inside JSON strings and do occur in agent
/// transcripts. Learned from the harness's RPC documentation and kept after it, because every
/// line-delimited JSON transport Aviary speaks — the runtime host's Unix socket, MCP's stdio
/// client/bridge, and Claude Code's stream — has the same requirement.
final class LineFramer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "aviary.line-framer")
    private let maxLineBytes: Int?
    private var carry = Data()
    private var discardingOversizedLine = false
    private var overflowCount = 0

    init(maxLineBytes: Int? = nil) {
        self.maxLineBytes = maxLineBytes.map { max(1, $0) }
    }

    func feed(_ chunk: Data) -> [Data] {
        queue.sync {
            if discardingOversizedLine {
                guard let nl = chunk.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
                let after = chunk.index(after: nl)
                carry = Data(chunk[after...])
                discardingOversizedLine = false
            } else {
                carry.append(chunk)
            }
            var lines: [Data] = []
            while let nl = carry.firstIndex(of: UInt8(ascii: "\n")) {
                let byteCount = carry.distance(from: carry.startIndex, to: nl)
                var line = carry.subdata(in: carry.startIndex..<nl)
                carry.removeSubrange(carry.startIndex...nl)
                if let maxLineBytes, byteCount > maxLineBytes {
                    overflowCount += 1
                    continue
                }
                if line.last == UInt8(ascii: "\r") { line.removeLast() }
                if !line.isEmpty { lines.append(line) }
            }
            if let maxLineBytes, carry.count > maxLineBytes {
                // Drop the partial oversized record and resynchronize at its next LF. This
                // keeps an untrusted socket from growing memory without bound while preserving
                // later valid frames on the same connection.
                carry.removeAll(keepingCapacity: false)
                discardingOversizedLine = true
                overflowCount += 1
            }
            return lines
        }
    }

    func takeOverflowCount() -> Int {
        queue.sync {
            let count = overflowCount
            overflowCount = 0
            return count
        }
    }
}
