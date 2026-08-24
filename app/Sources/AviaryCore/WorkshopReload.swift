import Foundation

/// The decisions behind rebuilding Aviary after the workshop has changed Aviary.
///
/// Separated from the SwiftUI object that acts on them so they can be tested without a
/// window, a process, or a compiler. Each one is a place where a plausible-looking shortcut
/// is wrong, which is the argument for pinning them down rather than leaving them inline.
public enum WorkshopReload {

    /// Where the app was launched from, which decides both how to rebuild it and how to start
    /// it again.
    public enum LaunchMode: Equatable, Sendable {
        /// `build/Aviary.app`, as `just build` produces and `just run` opens.
        case bundle(path: String)
        /// A bare SwiftPM binary — `just compile`, then running it directly.
        case binary(path: String, release: Bool)

        public var describedTarget: String {
            switch self {
            case .bundle(let path): return (path as NSString).lastPathComponent
            case .binary(_, let release): return release ? "release binary" : "debug binary"
            }
        }

        /// The executable a rebuild is expected to replace.
        public var executablePath: String {
            switch self {
            case .bundle(let path): return path + "/Contents/MacOS/Aviary"
            case .binary(let path, _): return path
            }
        }
    }

    /// Work out how this copy of Aviary was started.
    ///
    /// Rebuilding the *other* configuration would succeed and change nothing you can see,
    /// which is the most confusing outcome available — so this reads the running image's own
    /// path instead of assuming a default.
    public static func launchMode(
        executablePath: String, bundlePath: String, hasCheckout: Bool
    ) -> LaunchMode? {
        if bundlePath.hasSuffix(".app") { return .bundle(path: bundlePath) }
        // `.build/debug/Aviary` or `.build/release/Aviary`, as SwiftPM lays it out. Matched on
        // whole path components rather than a substring, so a checkout that happens to sit
        // under a directory named `release` is not mistaken for a release build.
        if executablePath.contains("/.build/") {
            let parts = executablePath.split(separator: "/").map(String.init)
            guard let buildIndex = parts.firstIndex(of: ".build") else {
                return .binary(path: executablePath, release: false)
            }
            let configuration = parts.count > buildIndex + 1 ? parts[buildIndex + 1] : ""
            return .binary(path: executablePath, release: configuration == "release")
        }
        // Anything else can still be rebuilt if there is a checkout to rebuild from.
        guard hasCheckout, !executablePath.isEmpty else { return nil }
        return .binary(path: executablePath, release: false)
    }

    /// The request that just became done, given what each request was last seen as.
    ///
    /// Two properties are load-bearing and neither is free. It fires on the *transition* to
    /// done, so a log write that merely mentions an already-finished request rebuilds nothing.
    /// And a request seen as done for the first time is **not** a transition — that is a
    /// request which was already finished when this window opened, and treating it as news is
    /// how an app rebuilds itself every time it launches.
    public static func completion(
        board: WorkshopBoard, lastSeen: [String: WorkshopStatus]
    ) -> (completed: WorkshopRequest?, lastSeen: [String: WorkshopStatus]) {
        var seen = lastSeen
        var completed: WorkshopRequest?
        for request in board.requests {
            let previous = seen[request.id]
            seen[request.id] = request.status
            guard let previous, previous != .done, request.status == .done else { continue }
            // The last one wins if several finished at once, and the build covers all of them
            // regardless — it builds the tree, not the request.
            completed = request
        }
        return (completed, seen)
    }

    /// The first real errors out of a build log.
    ///
    /// `swift build` output is mostly notes, and the useful line is rarely the last one: the
    /// tail of a failed build is `error: emit-module command failed`, which says nothing about
    /// what is wrong.
    ///
    /// Two kinds of duplication have to go, and each one doubles the banner on its own. A
    /// single error repeats once per compilation its file takes part in, so identical lines are
    /// collapsed. And every diagnostic is followed by a source-excerpt line that restates it
    /// under a caret — `|                `- error: cannot find 'nope' in scope` — which contains
    /// `error:` and is *not* an identical string, so it survives naive deduplication and shows
    /// every mistake twice.
    public static func firstErrors(in output: String, limit: Int = 4) -> String {
        var seen = Set<String>()
        var errors: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard text.contains("error:") else { continue }
            // The source-excerpt restatement, which begins with the gutter pipe.
            guard !text.hasPrefix("|"), !text.hasPrefix("`-") else { continue }
            if seen.insert(text).inserted { errors.append(text) }
        }
        guard !errors.isEmpty else {
            // Nothing said "error:", so it failed in a way this does not model. The tail is a
            // poor answer, but it beats a banner announcing a failure and describing nothing.
            return output.split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(3).map { String($0).trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
        }
        return errors.prefix(limit).joined(separator: "\n")
    }

    /// Whether a build actually replaced the executable.
    ///
    /// Compared rather than trusted: a request that only touched documentation, the agent's
    /// brief, or the board itself builds cleanly and changes nothing, and offering a relaunch
    /// for that teaches you to ignore the banner. An unreadable stamp counts as changed —
    /// better a needless relaunch offered than a real one withheld.
    public static func binaryChanged(before: String?, after: String?) -> Bool {
        guard let before, let after else { return true }
        return before != after
    }

    /// Size and mtime of a file, which is enough to say whether a build replaced it.
    public static func stamp(ofFileAt path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)@\(mtime)"
    }

    /// The command that rebuilds a given launch mode.
    public static func buildCommand(
        for mode: LaunchMode, repoRoot: URL
    ) -> (executable: String, arguments: [String], cwd: URL) {
        switch mode {
        case .bundle:
            // The whole bundle, not just the binary: the plist, the icon and the ad-hoc
            // signature are part of what makes the running app the app, and a fresh Mach-O
            // dropped into a stale bundle is not what `just build` produces.
            return ("/bin/bash",
                    [repoRoot.appending(path: "scripts/bundle-app.sh").path, "release"],
                    repoRoot)
        case .binary(_, let release):
            var arguments = ["build", "--product", "Aviary"]
            if release { arguments += ["-c", "release"] }
            return ("/usr/bin/swift", arguments, repoRoot.appending(path: "app"))
        }
    }
}
