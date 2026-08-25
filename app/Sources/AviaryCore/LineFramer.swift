import Foundation

/// Splits a byte stream into LF-delimited records, holding a partial trailing record
/// across reads.
///
/// LF only, and a trailing CR tolerated. Generic line readers are not usable here: they also
/// break on U+2028 and U+2029, which are legal inside JSON strings and do occur in agent
/// transcripts. Learned from the harness's RPC documentation and kept after it, because every
/// stdio protocol Aviary speaks — the runtime host, the MCP client and bridge, Claude Code's
/// stream — has the same requirement.
final class LineFramer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "aviary.line-framer")
    private var carry = Data()

    func feed(_ chunk: Data) -> [Data] {
        queue.sync {
            carry.append(chunk)
            var lines: [Data] = []
            while let nl = carry.firstIndex(of: UInt8(ascii: "\n")) {
                var line = carry.subdata(in: carry.startIndex..<nl)
                carry.removeSubrange(carry.startIndex...nl)
                if line.last == UInt8(ascii: "\r") { line.removeLast() }
                if !line.isEmpty { lines.append(line) }
            }
            return lines
        }
    }
}
