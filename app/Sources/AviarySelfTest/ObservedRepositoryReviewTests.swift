import Foundation
@testable import AviaryCore

private enum ObservedRepositoryReviewFixture {
    static func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aviary-observed-repository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-q"], cwd: root)
        try runGit(["config", "user.email", "aviary-self-test@example.invalid"], cwd: root)
        try runGit(["config", "user.name", "Aviary SelfTest"], cwd: root)
        try write("initial\n", to: root.appendingPathComponent("tracked.txt"))
        try runGit(["add", "--", "tracked.txt"], cwd: root)
        try runGit(["commit", "-q", "-m", "initial"], cwd: root)
        return root
    }

    static func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url)
    }

    @discardableResult
    static func runGit(_ arguments: [String], cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = ProcessEnvironment.shared.snapshot
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "git failed"
            throw NSError(domain: "ObservedRepositoryReviewTests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    static func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ObservedRepositoryReviewCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class ObservedRepositoryReviewTimeouts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    func append(_ value: TimeInterval) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func reviewAt(_ root: URL, runID: String = "run-1", turnID: String = "turn-1") async -> ObservedRepositoryReview {
    await ObservedRepositoryReviewer().observe(
        cwd: root, runID: runID, turnID: turnID,
        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

func testObservedRepositoryReviewCleanAndDeterministic() async throws {
    let root = try ObservedRepositoryReviewFixture.makeRepository()
    defer { ObservedRepositoryReviewFixture.remove(root) }
    let first = await reviewAt(root)
    let second = await reviewAt(root)
    XCTAssertEqual(first.status, .clean)
    XCTAssertTrue(first.files.isEmpty)
    XCTAssertNotNil(first.head?.oid)
    XCTAssertEqual(first.scope, "current_working_tree")
    XCTAssertEqual(first.attribution, "not_attributed")
    XCTAssertEqual(first.mediaType, ObservedRepositoryReviewFormat.mediaType)
    XCTAssertEqual(try first.encoded(), try second.encoded(), "a supplied timestamp makes encoding deterministic")
    XCTAssertFalse(String(decoding: try first.encoded(), as: UTF8.self).contains(root.path))
    XCTAssertEqual(try ObservedRepositoryReview.decode(first.encoded()), first)
}

func testObservedRepositoryReviewDisablesConfiguredFSMonitorHelper() async throws {
    let root = try ObservedRepositoryReviewFixture.makeRepository()
    defer { ObservedRepositoryReviewFixture.remove(root) }
    let helperRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("aviary-fsmonitor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: helperRoot, withIntermediateDirectories: true)
    defer { ObservedRepositoryReviewFixture.remove(helperRoot) }
    let sentinel = helperRoot.appendingPathComponent("fsmonitor-ran")
    let helper = helperRoot.appendingPathComponent("fsmonitor-helper.sh")
    try Data("""
    #!/bin/sh
    printf ran > "\(sentinel.path)"
    sleep 5
    """.utf8).write(to: helper)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: helper.path)
    try ObservedRepositoryReviewFixture.runGit(
        ["config", "core.fsmonitor", helper.path], cwd: root)

    let started = Date()
    let review = await reviewAt(root, runID: "run-fsmonitor", turnID: "turn-fsmonitor")
    XCTAssertEqual(review.status, .clean)
    XCTAssertTrue(Date().timeIntervalSince(started) < 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path),
                   "the read-only observer must disable configured fsmonitor helpers")
}

func testObservedRepositoryReviewCapturesStagedAndUnstagedTrackedDiffs() async throws {
    let root = try ObservedRepositoryReviewFixture.makeRepository()
    defer { ObservedRepositoryReviewFixture.remove(root) }
    try ObservedRepositoryReviewFixture.write("staged\n", to: root.appendingPathComponent("tracked.txt"))
    try ObservedRepositoryReviewFixture.runGit(["add", "--", "tracked.txt"], cwd: root)
    let trackedSensitiveText = "unstaged\nhost=\(root.path)\ntoken=tracked-content-secret\n"
    try ObservedRepositoryReviewFixture.write(
        trackedSensitiveText, to: root.appendingPathComponent("tracked.txt"))
    let review = await reviewAt(root)
    XCTAssertEqual(review.status, .changes)
    let tracked = try XCTUnwrap(review.files.first(where: { $0.path == "tracked.txt" }))
    XCTAssertEqual(tracked.indexStatus, "M")
    XCTAssertEqual(tracked.workTreeStatus, "M")
    XCTAssertEqual(review.diffs.map(\.kind), ["staged", "unstaged"])
    XCTAssertTrue(review.diffs.allSatisfy {
        $0.text?.contains("staged") == true || $0.text?.contains("unstaged") == true
    })
    XCTAssertTrue(review.diffs.contains {
        $0.kind == "unstaged"
            && $0.text?.contains(root.path) == true
            && $0.text?.contains("tracked-content-secret") == true
    })
    XCTAssertTrue(String(decoding: try review.encoded(), as: UTF8.self).contains(root.path),
                  "inspect-artifact authorization protects arbitrary tracked diff content")
    XCTAssertTrue(review.coverage.stagedDiffObserved)
    XCTAssertTrue(review.coverage.unstagedDiffObserved)
}

func testObservedRepositoryReviewPreservesNulDelimitedRenamePaths() async throws {
    let root = try ObservedRepositoryReviewFixture.makeRepository()
    defer { ObservedRepositoryReviewFixture.remove(root) }
    try ObservedRepositoryReviewFixture.write("question\n", to: root.appendingPathComponent("question-source"))
    try ObservedRepositoryReviewFixture.write("bang\n", to: root.appendingPathComponent("bang-source"))
    try ObservedRepositoryReviewFixture.runGit(["add", "--", "question-source", "bang-source"], cwd: root)
    try ObservedRepositoryReviewFixture.runGit(["commit", "-q", "-m", "rename sources"], cwd: root)
    try ObservedRepositoryReviewFixture.runGit(["mv", "question-source", "? renamed file"], cwd: root)
    try ObservedRepositoryReviewFixture.runGit(["mv", "bang-source", "! renamed file"], cwd: root)
    let review = await reviewAt(root, runID: "run-rename", turnID: "turn-rename")
    XCTAssertEqual(review.status, .changes)
    let question = try XCTUnwrap(review.files.first(where: { $0.path == "? renamed file" }))
    let bang = try XCTUnwrap(review.files.first(where: { $0.path == "! renamed file" }))
    XCTAssertEqual(question.originalPath, "question-source")
    XCTAssertEqual(bang.originalPath, "bang-source")
    XCTAssertFalse(review.files.contains { $0.path == "question-source" || $0.path == "bang-source" })
}

func testObservedRepositoryReviewUntrackedAndIgnoredBodiesAreNeverRetained() async throws {
    let root = try ObservedRepositoryReviewFixture.makeRepository()
    defer { ObservedRepositoryReviewFixture.remove(root) }
    let secret = "untracked body must never appear in a repository review"
    try ObservedRepositoryReviewFixture.write(secret, to: root.appendingPathComponent("secret.txt"))
    let review = await reviewAt(root)
    XCTAssertEqual(review.status, .changes)
    XCTAssertTrue(review.files.contains { $0.path == "secret.txt" && $0.isUntracked })
    let encoded = String(decoding: try review.encoded(), as: UTF8.self)
    XCTAssertFalse(encoded.contains(secret))
    XCTAssertTrue(review.omissions.contains { $0.kind == "untracked_body" && $0.path == "secret.txt" })

    try FileManager.default.removeItem(at: root.appendingPathComponent("secret.txt"))
    try ObservedRepositoryReviewFixture.write("ignored.txt\n", to: root.appendingPathComponent(".gitignore"))
    try ObservedRepositoryReviewFixture.runGit(["add", "--", ".gitignore"], cwd: root)
    try ObservedRepositoryReviewFixture.runGit(["commit", "-q", "-m", "ignore"], cwd: root)
    try ObservedRepositoryReviewFixture.write("ignored body", to: root.appendingPathComponent("ignored.txt"))
    let ignored = await reviewAt(root)
    XCTAssertEqual(ignored.status, .clean, "ignored-only content is excluded from working-tree changes")
    XCTAssertTrue(ignored.files.contains { $0.path == "ignored.txt" && $0.isIgnored })
    XCTAssertTrue(ignored.omissions.contains { $0.kind == "ignored" && $0.path == "ignored.txt" })
}

func testObservedRepositoryReviewDoesNotMisclassifyRepositoryDiscoveryFailure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aviary-not-a-repository-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { ObservedRepositoryReviewFixture.remove(root) }
    let review = await reviewAt(root)
    XCTAssertEqual(review.status, .notRepository)
    XCTAssertNil(review.repositoryIdentityDigest)
    XCTAssertTrue(review.diffs.isEmpty)

    let emptyGit = root.appendingPathComponent("empty-git-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: emptyGit, withIntermediateDirectories: true)
    defer { ObservedRepositoryReviewFixture.remove(emptyGit) }
    try FileManager.default.createDirectory(
        at: emptyGit.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let emptyGitReview = await reviewAt(emptyGit, runID: "run-empty-git", turnID: "turn-empty-git")
    XCTAssertEqual(emptyGitReview.status, .failed,
                   "an empty .git is repository evidence, not ordinary absence")
    XCTAssertFalse(emptyGitReview.omissions.contains { $0.kind == "not_repository" })

    let corruptGit = root.appendingPathComponent("corrupt-git-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: corruptGit, withIntermediateDirectories: true)
    defer { ObservedRepositoryReviewFixture.remove(corruptGit) }
    try ObservedRepositoryReviewFixture.write(
        "gitdir: /definitely/missing\n", to: corruptGit.appendingPathComponent(".git"))
    let corruptGitReview = await reviewAt(
        corruptGit, runID: "run-corrupt-git", turnID: "turn-corrupt-git")
    XCTAssertEqual(corruptGitReview.status, .failed,
                   "a corrupt .git file is repository evidence, not ordinary absence")
    XCTAssertFalse(corruptGitReview.omissions.contains { $0.kind == "not_repository" })

    let dubiousRunner: ObservedRepositoryReviewer.CommandRunner = { arguments, _, _ in
        XCTAssertEqual(arguments, ["rev-parse", "--show-toplevel"])
        return ObservedRepositoryGitCommandResult(
            stdout: Data(), stderr: Data("fatal: detected dubious ownership\n".utf8),
            exitCode: 128)
    }
    let dubious = await ObservedRepositoryReviewer(commandRunner: dubiousRunner).observe(
        cwd: root, runID: "run-dubious", turnID: "turn-dubious",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(dubious.status, .failed)
    XCTAssertFalse(dubious.omissions.contains { $0.kind == "not_repository" })
}

func testObservedRepositoryReviewTreatsUnparsedGitEvidenceAsBounded() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aviary-malformed-review-\(UUID().uuidString)")
    let malformedStatus = Data([0xff, 0])
    let malformedStatusRunner: ObservedRepositoryReviewer.CommandRunner = { arguments, cwd, _ in
        if arguments == ["rev-parse", "--show-toplevel"] {
            return ObservedRepositoryGitCommandResult(stdout: cwd.path)
        }
        if arguments == ["rev-parse", "--verify", "HEAD"] {
            return ObservedRepositoryGitCommandResult(
                stdout: "0123456789abcdef0123456789abcdef01234567\n")
        }
        if arguments == ["symbolic-ref", "--quiet", "--short", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "main\n")
        }
        if arguments.first == "status" {
            return ObservedRepositoryGitCommandResult(
                stdout: malformedStatus, stderr: Data(), exitCode: 0)
        }
        return ObservedRepositoryGitCommandResult()
    }
    let statusReview = await ObservedRepositoryReviewer(
        commandRunner: malformedStatusRunner
    ).observe(
        cwd: root, runID: "run-invalid-status", turnID: "turn-invalid-status",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(statusReview.status, .bounded)
    XCTAssertTrue(statusReview.coverage.bounded)
    XCTAssertTrue(statusReview.diffs.isEmpty)
    XCTAssertTrue(statusReview.omissions.contains { $0.kind == "invalid_status" })
    XCTAssertEqual(try ObservedRepositoryReview.decode(statusReview.encoded()), statusReview)

    let changedStatus = "1 .M N... 100644 100644 100644 abcdef0 abcdef0 tracked.txt\0"
    let malformedDiffRunner: ObservedRepositoryReviewer.CommandRunner = { arguments, cwd, _ in
        if arguments == ["rev-parse", "--show-toplevel"] {
            return ObservedRepositoryGitCommandResult(stdout: cwd.path)
        }
        if arguments == ["rev-parse", "--verify", "HEAD"] {
            return ObservedRepositoryGitCommandResult(
                stdout: "0123456789abcdef0123456789abcdef01234567\n")
        }
        if arguments == ["symbolic-ref", "--quiet", "--short", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "main\n")
        }
        if arguments.first == "status" {
            return ObservedRepositoryGitCommandResult(stdout: changedStatus)
        }
        return ObservedRepositoryGitCommandResult(
            stdout: Data([0xff]), stderr: Data(), exitCode: 0)
    }
    let diffReview = await ObservedRepositoryReviewer(
        commandRunner: malformedDiffRunner
    ).observe(
        cwd: root, runID: "run-invalid-diff", turnID: "turn-invalid-diff",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(diffReview.status, .bounded)
    XCTAssertTrue(diffReview.coverage.bounded)
    XCTAssertTrue(diffReview.diffs.isEmpty)
    XCTAssertTrue(diffReview.omissions.contains { $0.kind == "invalid_diff" })
    XCTAssertEqual(try ObservedRepositoryReview.decode(diffReview.encoded()), diffReview)
}

func testObservedRepositoryReviewExcludesBinaryAndSubmoduleBodies() async throws {
    let root = try ObservedRepositoryReviewFixture.makeRepository()
    defer { ObservedRepositoryReviewFixture.remove(root) }
    let binaryPath = "binary photo-β.bin"
    try Data([0, 1, 2, 0, 3, 4]).write(to: root.appendingPathComponent(binaryPath))
    try ObservedRepositoryReviewFixture.runGit(["add", "--", binaryPath], cwd: root)
    try ObservedRepositoryReviewFixture.runGit(["commit", "-q", "-m", "binary"], cwd: root)
    try Data([0, 1, 9, 0, 3, 4]).write(to: root.appendingPathComponent(binaryPath))
    let binary = await reviewAt(root, runID: "run-binary", turnID: "turn-binary")
    XCTAssertEqual(binary.status, .changes)
    XCTAssertTrue(binary.files.contains { $0.path == binaryPath && $0.isBinary })
    XCTAssertTrue(binary.diffs.isEmpty)
    XCTAssertTrue(binary.omissions.contains { $0.kind == "binary" && $0.path == binaryPath })

    let submoduleStatus = "1 M. S... 160000 160000 160000 abcdef0 abcdef0 submodule\0"
    let submoduleDiff = "diff --git a/submodule b/submodule\n--- a/submodule\n+++ b/submodule\n@@ -1 +1 @@\n-Subproject commit abc\n+Subproject commit def\n"
    let runner: ObservedRepositoryReviewer.CommandRunner = { arguments, cwd, _ in
        if arguments == ["rev-parse", "--show-toplevel"] { return ObservedRepositoryGitCommandResult(stdout: cwd.path) }
        if arguments == ["rev-parse", "--verify", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "0123456789abcdef0123456789abcdef01234567\n")
        }
        if arguments == ["symbolic-ref", "--quiet", "--short", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "main\n")
        }
        if arguments.first == "status" { return ObservedRepositoryGitCommandResult(stdout: submoduleStatus) }
        return ObservedRepositoryGitCommandResult(stdout: submoduleDiff)
    }
    let submodule = await ObservedRepositoryReviewer(commandRunner: runner).observe(
        cwd: root, runID: "run-submodule", turnID: "turn-submodule",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(submodule.status, .changes)
    XCTAssertTrue(submodule.files.contains { $0.path == "submodule" && $0.isSubmodule })
    XCTAssertTrue(submodule.diffs.isEmpty)
    XCTAssertTrue(submodule.omissions.contains { $0.kind == "submodule" && $0.path == "submodule" })
}

func testObservedRepositoryReviewSuppressesDiffOnFenceConflict() async throws {
    let counter = ObservedRepositoryReviewCallCounter()
    let statusA = "1 .M N... 100644 100644 100644 abcdef0 abcdef0 tracked.txt\0"
    let statusB = "1 .M N... 100644 100644 100644 abcdef0 abcdef0 changed.txt\0"
    let runner: ObservedRepositoryReviewer.CommandRunner = { arguments, cwd, _ in
        _ = cwd
        let call = counter.next()
        if arguments == ["rev-parse", "--show-toplevel"] {
            return ObservedRepositoryGitCommandResult(stdout: cwd.path)
        }
        if arguments == ["rev-parse", "--verify", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "0123456789abcdef0123456789abcdef01234567\n")
        }
        if arguments == ["symbolic-ref", "--quiet", "--short", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "main\n")
        }
        if arguments.first == "status" {
            return ObservedRepositoryGitCommandResult(stdout: call < 9 ? statusA : statusB)
        }
        let diff = "diff --git a/tracked.txt b/tracked.txt\n--- a/tracked.txt\n+++ b/tracked.txt\n@@ -1 +1 @@\n-a\n+b\n"
        return ObservedRepositoryGitCommandResult(stdout: diff)
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aviary-fenced-review-\(UUID().uuidString)")
    let review = await ObservedRepositoryReviewer(commandRunner: runner).observe(
        cwd: root, runID: "run-conflict", turnID: "turn-conflict",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(review.status, .unstableConflict)
    XCTAssertTrue(review.diffs.isEmpty)
    XCTAssertTrue(review.omissions.contains { $0.kind == "conflict" })

    let truncationCounter = ObservedRepositoryReviewCallCounter()
    let truncationRunner: ObservedRepositoryReviewer.CommandRunner = { arguments, cwd, _ in
        if arguments == ["rev-parse", "--show-toplevel"] {
            return ObservedRepositoryGitCommandResult(stdout: cwd.path)
        }
        if arguments == ["rev-parse", "--verify", "HEAD"] {
            return ObservedRepositoryGitCommandResult(
                stdout: "0123456789abcdef0123456789abcdef01234567\n")
        }
        if arguments == ["symbolic-ref", "--quiet", "--short", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "main\n")
        }
        if arguments.first == "status" {
            return ObservedRepositoryGitCommandResult(
                stdout: statusA,
                stdoutTruncated: truncationCounter.next() == 1)
        }
        return ObservedRepositoryGitCommandResult()
    }
    let truncationConflict = await ObservedRepositoryReviewer(
        commandRunner: truncationRunner
    ).observe(
        cwd: root, runID: "run-truncation-conflict", turnID: "turn-truncation-conflict",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(truncationConflict.status, .unstableConflict)
    XCTAssertEqual(
        try ObservedRepositoryReview.decode(truncationConflict.encoded()),
        truncationConflict)
}

func testObservedRepositoryReviewBoundsHugeStatusAndTimeout() async throws {
    let timeoutRunner: ObservedRepositoryReviewer.CommandRunner = { _, _, _ in
        ObservedRepositoryGitCommandResult(timedOut: true)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aviary-timeout")
    let timedOut = await ObservedRepositoryReviewer(commandRunner: timeoutRunner).observe(
        cwd: root, runID: "run-timeout", turnID: "turn-timeout",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(timedOut.status, .timedOut)

    let huge = String(repeating: "x", count: 80_000)
    let counter = ObservedRepositoryReviewCallCounter()
    let hugeRunner: ObservedRepositoryReviewer.CommandRunner = { arguments, cwd, _ in
        _ = counter.next()
        if arguments == ["rev-parse", "--show-toplevel"] { return ObservedRepositoryGitCommandResult(stdout: cwd.path) }
        if arguments == ["rev-parse", "--verify", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "0123456789abcdef0123456789abcdef01234567\n")
        }
        if arguments == ["symbolic-ref", "--quiet", "--short", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "main\n")
        }
        if arguments.first == "status" { return ObservedRepositoryGitCommandResult(stdout: huge) }
        return ObservedRepositoryGitCommandResult()
    }
    let tinyLimits = ObservedRepositoryReviewLimits(
        commandStdoutBytes: 64, commandStderrBytes: 64, diffBytes: 64,
        pathBytes: 64, stringBytes: 128, fileCount: 8, omissionCount: 8,
        totalArtifactBytes: 1, timeout: 1)
    let bounded = await ObservedRepositoryReviewer(commandRunner: hugeRunner).observe(
        cwd: root, runID: "run-huge", turnID: "turn-huge",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000), limits: tinyLimits)
    XCTAssertEqual(bounded.status, .failed)
    XCTAssertTrue(bounded.coverage.bounded)
    XCTAssertFalse(bounded.coverage.statusObserved)
    XCTAssertNil(bounded.fenceBefore)
    XCTAssertNil(bounded.fenceAfter)
    XCTAssertTrue(try bounded.encoded().count <= tinyLimits.totalArtifactBytes)
    XCTAssertEqual(try ObservedRepositoryReview.decode(bounded.encoded()), bounded)

    let largeRoot = try ObservedRepositoryReviewFixture.makeRepository()
    defer { ObservedRepositoryReviewFixture.remove(largeRoot) }
    try Data(repeating: 0x61, count: 700_000)
        .write(to: largeRoot.appendingPathComponent("tracked.txt"))
    let large = await reviewAt(largeRoot, runID: "run-large", turnID: "turn-large")
    XCTAssertEqual(large.status, .bounded,
                   "an unchanged oversized diff is incomplete, not evidence of a race")
    XCTAssertTrue(large.diffs.isEmpty)
    XCTAssertTrue(large.coverage.bounded)

    XCTAssertEqual(ObservedRepositoryReviewLimits(timeout: .nan).timeout, 8)
    XCTAssertEqual(ObservedRepositoryReviewLimits(timeout: .infinity).timeout, 8)
    XCTAssertEqual(
        ObservedRepositoryReviewLimits(timeout: .greatestFiniteMagnitude).timeout,
        ObservedRepositoryReviewLimits.maximumTimeout)

    let hostileLimits = try JSONDecoder().decode(
        ObservedRepositoryReviewLimits.self,
        from: Data("""
        {
          "commandStdoutBytes": -1,
          "commandStderrBytes": 9223372036854775807,
          "diffBytes": -1,
          "pathBytes": 9223372036854775807,
          "stringBytes": -1,
          "fileCount": 9223372036854775807,
          "omissionCount": -1,
          "totalArtifactBytes": 9223372036854775807,
          "timeout": -100
        }
        """.utf8))
    XCTAssertEqual(hostileLimits.commandStdoutBytes, 1)
    XCTAssertEqual(hostileLimits.commandStderrBytes, 1024 * 1024)
    XCTAssertEqual(hostileLimits.diffBytes, 1)
    XCTAssertEqual(hostileLimits.pathBytes, 64 * 1024)
    XCTAssertEqual(hostileLimits.stringBytes, 1)
    XCTAssertEqual(hostileLimits.fileCount, 10_000)
    XCTAssertEqual(hostileLimits.omissionCount, 1)
    XCTAssertEqual(
        hostileLimits.totalArtifactBytes,
        ObservedRepositoryReviewLimits.maximumTotalArtifactBytes)
    XCTAssertEqual(hostileLimits.timeout, 0.01)

    let manyEntries = (0..<2_001).map {
        "? file-\(String(format: "%04d", $0))\0"
    }.joined()
    let manyEntriesRunner: ObservedRepositoryReviewer.CommandRunner = { arguments, cwd, _ in
        if arguments == ["rev-parse", "--show-toplevel"] {
            return ObservedRepositoryGitCommandResult(stdout: cwd.path)
        }
        if arguments == ["rev-parse", "--verify", "HEAD"] {
            return ObservedRepositoryGitCommandResult(
                stdout: "0123456789abcdef0123456789abcdef01234567\n")
        }
        if arguments == ["symbolic-ref", "--quiet", "--short", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "main\n")
        }
        if arguments.first == "status" {
            return ObservedRepositoryGitCommandResult(stdout: manyEntries)
        }
        return ObservedRepositoryGitCommandResult()
    }
    let metadataBounded = await ObservedRepositoryReviewer(
        commandRunner: manyEntriesRunner
    ).observe(
        cwd: root, runID: "run-many", turnID: "turn-many",
        limits: ObservedRepositoryReviewLimits(fileCount: 2, omissionCount: 2))
    XCTAssertEqual(metadataBounded.status, .bounded)
    XCTAssertTrue(metadataBounded.coverage.bounded)
    XCTAssertEqual(metadataBounded.files.count, 2)
    XCTAssertEqual(metadataBounded.omissions.count, 2)
    XCTAssertTrue(metadataBounded.omissions.contains { $0.kind == "projection_limit" })

    let aboveDefaults = await ObservedRepositoryReviewer(
        commandRunner: manyEntriesRunner
    ).observe(
        cwd: root, runID: "run-wire-max", turnID: "turn-wire-max",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000),
        limits: ObservedRepositoryReviewLimits(
            fileCount: 3_000, omissionCount: 3_000,
            totalArtifactBytes: ObservedRepositoryReviewLimits.maximumTotalArtifactBytes))
    XCTAssertEqual(aboveDefaults.status, .changes)
    XCTAssertEqual(aboveDefaults.files.count, 2_001)
    XCTAssertEqual(aboveDefaults.omissions.count, 2_001)
    XCTAssertEqual(
        try ObservedRepositoryReview.decode(aboveDefaults.encoded()), aboveDefaults,
        "wire decoding uses the fixed format maxima, not one producer's default limits")

    let timeouts = ObservedRepositoryReviewTimeouts()
    let timeoutAwareRunner: ObservedRepositoryReviewer.CommandRunner = { arguments, cwd, timeout in
        timeouts.append(timeout)
        if arguments == ["rev-parse", "--show-toplevel"] { return ObservedRepositoryGitCommandResult(stdout: cwd.path) }
        if arguments == ["rev-parse", "--verify", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "0123456789abcdef0123456789abcdef01234567\n")
        }
        if arguments == ["symbolic-ref", "--quiet", "--short", "HEAD"] {
            return ObservedRepositoryGitCommandResult(stdout: "main\n")
        }
        if arguments.first == "status" { return ObservedRepositoryGitCommandResult() }
        return ObservedRepositoryGitCommandResult()
    }
    _ = await ObservedRepositoryReviewer(commandRunner: timeoutAwareRunner).observe(
        cwd: largeRoot, runID: "run-deadline", turnID: "turn-deadline",
        observedAt: Date(timeIntervalSince1970: 1_700_000_000),
        limits: ObservedRepositoryReviewLimits(timeout: 0.2))
    let observedTimeouts = timeouts.snapshot()
    XCTAssertTrue(!observedTimeouts.isEmpty)
    XCTAssertTrue(observedTimeouts.allSatisfy { $0 > 0 && $0 <= 0.2 })
    XCTAssertTrue(observedTimeouts.allSatisfy { value in
        guard let index = observedTimeouts.firstIndex(of: value), index > 0 else { return true }
        return value <= observedTimeouts[index - 1] + 0.001
    })
}

func testObservedRepositoryReviewRejectsForgedCodableMutants() async throws {
    let root = try ObservedRepositoryReviewFixture.makeRepository()
    defer { ObservedRepositoryReviewFixture.remove(root) }
    try ObservedRepositoryReviewFixture.write("forged\n", to: root.appendingPathComponent("tracked.txt"))
    let review = await reviewAt(root, runID: "run-forged", turnID: "turn-forged")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: review.encoded()) as? [String: Any])

    func rejects(_ mutate: (inout [String: Any]) -> Void) {
        var value = object
        mutate(&value)
        do {
            _ = try ObservedRepositoryReview.decode(JSONSerialization.data(withJSONObject: value))
            XCTFail("forged review should be rejected")
        } catch {
            Harness.countAssertion()
        }
    }

    rejects { value in value["repositoryIdentityDigest"] = "sha256:not-hex" }
    rejects { value in
        value["status"] = "unstable_conflict"
    }
    rejects { value in
        var files = value["files"] as! [[String: Any]]
        files[0]["path"] = "../escape"
        value["files"] = files
    }
    rejects { value in
        var head = value["head"] as! [String: Any]
        head["detached"] = true
        value["head"] = head
    }
    rejects { value in
        var coverage = value["coverage"] as! [String: Any]
        coverage["statusObserved"] = false
        value["coverage"] = coverage
    }
    rejects { value in
        var fence = value["fenceAfter"] as! [String: Any]
        fence["statusDigest"] = "sha256:" + String(repeating: "f", count: 64)
        value["fenceAfter"] = fence
    }
    rejects { value in
        var files = value["files"] as! [[String: Any]]
        files[0]["isUntracked"] = true
        value["files"] = files
    }
    rejects { value in
        value["status"] = "unstable_conflict"
        var omissions = value["omissions"] as! [[String: Any]]
        omissions.removeAll { ($0["kind"] as? String) == "conflict" }
        value["omissions"] = omissions
    }
    rejects { value in
        var before = value["fenceBefore"] as! [String: Any]
        var after = value["fenceAfter"] as! [String: Any]
        before["statusTruncated"] = true
        after["statusTruncated"] = true
        value["fenceBefore"] = before
        value["fenceAfter"] = after
    }
    rejects { value in
        var diffs = value["diffs"] as! [[String: Any]]
        diffs[0]["truncated"] = true
        value["diffs"] = diffs
    }
    rejects { value in
        value["status"] = "unstable_conflict"
        var omissions = value["omissions"] as! [[String: Any]]
        omissions.append(["kind": "conflict", "detail": "forged conflict"])
        value["omissions"] = omissions
        value["diffs"] = []
    }
    rejects { value in
        value["status"] = "changes"
        value["files"] = []
        value["diffs"] = []
    }
    rejects { value in
        value["status"] = "timed_out"
        value["head"] = NSNull()
        value["fenceBefore"] = NSNull()
        value["fenceAfter"] = NSNull()
        value["repositoryIdentityDigest"] = NSNull()
        value["files"] = []
        value["diffs"] = []
        value["omissions"] = []
        var coverage = value["coverage"] as! [String: Any]
        coverage["statusObserved"] = false
        coverage["bounded"] = false
        value["coverage"] = coverage
    }
    rejects { value in
        value["status"] = "cancelled"
        value["head"] = NSNull()
        value["fenceBefore"] = NSNull()
        value["fenceAfter"] = NSNull()
        value["repositoryIdentityDigest"] = NSNull()
        value["files"] = []
        value["diffs"] = []
        value["omissions"] = []
        var coverage = value["coverage"] as! [String: Any]
        coverage["statusObserved"] = false
        coverage["bounded"] = true
        value["coverage"] = coverage
    }
}

func testObservedRepositoryReviewRejectsEarlierRunBodyUnderLaterArtifactDescriptor() async throws {
    let root = try ObservedRepositoryReviewFixture.makeRepository()
    defer { ObservedRepositoryReviewFixture.remove(root) }
    let review = await reviewAt(root, runID: "R1", turnID: "T1")
    let body = try review.encoded()
    let digest = "sha256:" + AviarySHA256.hash(data: body).description
    let work = WorkRef(workHostID: "review-binding-host", workID: "review-binding-work")
    let journal = JournalRef.work(work, journalID: "review-binding-journal")
    let bodyReference = TimelineBodyReference(
        authority: journal, referenceID: digest,
        mediaType: ObservedRepositoryReviewFormat.mediaType,
        byteCount: body.count, digest: digest)
    let laterArtifact = try WorkServiceArtifactDescriptor(
        artifactID: "review-R2-T2", work: work, label: "review",
        mediaType: ObservedRepositoryReviewFormat.mediaType,
        byteCount: body.count, digest: digest, available: true,
        bodyReference: bodyReference,
        sourceEvent: EventRef(journal: journal, eventID: "artifact-R2-T2"),
        session: SessionRef("producer-session"),
        sessionAttachment: SessionAttachmentRef("producer-attachment"),
        run: RunRef("R2"), turn: TurnRef("T2"), action: ActionRef("A2"),
        causedByEventID: EventRef(journal: journal, eventID: "action-start-R2"))
    XCTAssertFalse(review.matchesCanonicalSource(of: laterArtifact))
    let decoded = try ObservedRepositoryReview.decode(body)
    XCTAssertFalse(decoded.matchesCanonicalSource(of: laterArtifact))
    let matchingArtifact = try WorkServiceArtifactDescriptor(
        artifactID: "review-R1-T1", work: work, label: "review",
        mediaType: ObservedRepositoryReviewFormat.mediaType,
        byteCount: body.count, digest: digest, available: true,
        bodyReference: bodyReference,
        sourceEvent: EventRef(journal: journal, eventID: "artifact-R1-T1"),
        session: SessionRef("producer-session"),
        sessionAttachment: SessionAttachmentRef("producer-attachment"),
        run: RunRef("R1"), turn: TurnRef("T1"), action: ActionRef("A1"),
        causedByEventID: EventRef(journal: journal, eventID: "action-start-R1"))
    XCTAssertTrue(decoded.matchesCanonicalSource(of: matchingArtifact))
}

let casesObservedRepositoryReview: [Case] = [
    ("Phase 4B repository review: clean and deterministic", { try await testObservedRepositoryReviewCleanAndDeterministic() }),
    ("Phase 4B repository review: configured fsmonitor helper disabled", { try await testObservedRepositoryReviewDisablesConfiguredFSMonitorHelper() }),
    ("Phase 4B repository review: staged and unstaged tracked diffs", { try await testObservedRepositoryReviewCapturesStagedAndUnstagedTrackedDiffs() }),
    ("Phase 4B repository review: NUL-delimited rename paths", { try await testObservedRepositoryReviewPreservesNulDelimitedRenamePaths() }),
    ("Phase 4B repository review: untracked and ignored privacy", { try await testObservedRepositoryReviewUntrackedAndIgnoredBodiesAreNeverRetained() }),
    ("Phase 4B repository review: discovery failure is not misclassified", { try await testObservedRepositoryReviewDoesNotMisclassifyRepositoryDiscoveryFailure() }),
    ("Phase 4B repository review: unparsed Git evidence is bounded", { try await testObservedRepositoryReviewTreatsUnparsedGitEvidenceAsBounded() }),
    ("Phase 4B repository review: binary and submodule omissions", { try await testObservedRepositoryReviewExcludesBinaryAndSubmoduleBodies() }),
    ("Phase 4B repository review: fence conflict suppresses diff", { try await testObservedRepositoryReviewSuppressesDiffOnFenceConflict() }),
    ("Phase 4B repository review: timeout and huge output bounds", { try await testObservedRepositoryReviewBoundsHugeStatusAndTimeout() }),
    ("Phase 4B repository review: forged Codable mutants rejected", { try await testObservedRepositoryReviewRejectsForgedCodableMutants() }),
    ("Phase 4B repository review: earlier-run body cannot satisfy later artifact", { try await testObservedRepositoryReviewRejectsEarlierRunBodyUnderLaterArtifactDescriptor() }),
]
