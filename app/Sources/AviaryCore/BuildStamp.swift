import Foundation

/// When the running bundle was built, and whether the source has moved since.
///
/// This exists because of a specific, expensive failure. Three rounds of fixes to a menu were
/// evaluated against an app bundle four hours older than the code that fixed it: `swift build`
/// produces `.build/…/Aviary`, `just shot` renders from a third binary, and the thing actually
/// double-clicked is `build/Aviary.app`. All three can disagree, and nothing on screen said so
/// — so a correct fix and a missing rebuild are indistinguishable from the outside, and the
/// obvious reading of "still broken" is that the diagnosis was wrong.
///
/// The check is deliberately one-directional. It reports that the source is *ahead* of the
/// build, which is the case that misleads; a build ahead of the checkout is just a dirty tree.
public struct BuildStamp: Sendable, Equatable {
    /// When `bundle-app.sh` assembled this bundle.
    public var builtAt: Date?
    /// The short SHA it was built from.
    public var commit: String?

    public init(builtAt: Date?, commit: String?) {
        self.builtAt = builtAt
        self.commit = commit
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> BuildStamp {
        BuildStamp(
            builtAt: ISO8601.date(bundle.infoDictionary?["AviaryBuildStamp"] as? String),
            commit: (bundle.infoDictionary?["AviaryBuildCommit"] as? String)
                .flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 })
    }

    /// A build with no stamp is one assembled before stamping existed, or run straight out of
    /// SwiftPM. Neither can be compared, and guessing would produce a warning that never clears.
    public var isStamped: Bool { builtAt != nil }

    public var summary: String {
        guard let builtAt else { return "unstamped build" }
        let stamp = DateFormatter()
        stamp.dateFormat = "d MMM HH:mm"
        return "built \(stamp.string(from: builtAt))" + (commit.map { " · \($0)" } ?? "")
    }

    /// How far the checkout has moved past this build, in commits, or nil when it has not.
    ///
    /// Counted rather than merely flagged: "3 commits behind" is actionable in a way that
    /// "out of date" is not, and it distinguishes a stale bundle from a tree someone is
    /// mid-edit in.
    public static func commitsSinceBuild(repoRoot: URL, stamp: BuildStamp) -> Int? {
        guard let commit = stamp.commit else { return nil }
        let out = run(["git", "-C", repoRoot.path, "rev-list", "--count", "\(commit)..HEAD"])
        guard let text = out?.trimmingCharacters(in: .whitespacesAndNewlines),
              let count = Int(text), count > 0
        else { return nil }
        return count
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
