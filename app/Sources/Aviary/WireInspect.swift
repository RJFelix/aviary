import Foundation
import AviaryCore

/// `Aviary --analyse-wire <file.jsonl>` — print a recorded payload's composition and exit.
///
/// The same decomposition the Context view renders, on stdout. Useful for checking the
/// analyser against a real payload without opening a window, and for answering "where did
/// my input tokens go" from a shell.
enum WireInspect {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--analyse-wire")
    }

    static func runIfRequested() {
        guard isRequested else { return }
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--analyse-wire"), args.count > i + 1 else {
            FileHandle.standardError.write(Data("usage: Aviary --analyse-wire <file.jsonl>\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: args[i + 1])
        // Optional: anchor the estimates to a real billed input count.
        let actual = args.firstIndex(of: "--input-tokens").flatMap { j -> Int? in
            args.count > j + 1 ? Int(args[j + 1]) : nil
        }

        let records = WireLog.read(url: url)
        let requests = records.filter { $0.kind == .request }
        print("\(records.count) record(s), \(requests.count) request(s)")
        guard let req = requests.last, let payload = req.payload else {
            print("no request payload found")
            exit(1)
        }

        let a = WireLog.analyse(payload: payload)
        print("shape   \(a.shape)")
        print("model   \(a.modelID ?? "—")")
        print("session \(req.sessionID ?? "—")")
        print("payload \(a.totalCharacters) chars  ≈\(a.estimatedTokens) tokens"
            + (actual.map { "   billed input \($0)" } ?? ""))
        print("")
        print("PART".padding(toLength: 46, withPad: " ", startingAt: 0)
            + "     chars   tokens   share")

        func show(_ s: PayloadSegment, depth: Int, childLimit: Int) {
            let indent = String(repeating: "  ", count: depth)
            let label = indent + s.label
            let tokens = actual.map {
                s.scaledTokens(payloadCharacters: a.totalCharacters, actualTokens: $0)
            } ?? s.estimatedTokens
            let share = 100 * s.share(of: a.totalCharacters)
            let clipped = label.count > 46 ? String(label.prefix(45)) + "…" : label
            print(clipped.padding(toLength: 46, withPad: " ", startingAt: 0)
                + String(format: " %9d %8d %6.1f%%", s.characters, tokens, share))
            for c in s.children.prefix(childLimit) {
                show(c, depth: depth + 1, childLimit: max(3, childLimit / 2))
            }
            if s.children.count > childLimit {
                print(indent + "  … \(s.children.count - childLimit) more")
            }
        }

        for s in a.segments { show(s, depth: 0, childLimit: 8) }
        exit(0)
    }
}
