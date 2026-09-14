import Foundation
@testable import AviaryCore

private enum RepositoryReviewDiffProjectionFixture {
    static func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aviary-review-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-q"], cwd: root)
        try runGit(["config", "user.email", "aviary-review@example.invalid"], cwd: root)
        try runGit(["config", "user.name", "Aviary Review"], cwd: root)
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try runGit(["add", "--", "tracked.txt"], cwd: root)
        try runGit(["commit", "-q", "-m", "base"], cwd: root)
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        return root
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
            throw NSError(domain: "RepositoryReviewDiffProjectionTests", code: Int(process.terminationStatus))
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    static func remove(_ root: URL) { try? FileManager.default.removeItem(at: root) }
}

private func repositoryReviewProjectionReview(
    diff: String, files: [ObservedRepositoryFile]? = nil,
    diffKinds: [String] = ["unstaged"],
    runID: String = "projection-run", turnID: String = "projection-turn"
) async throws -> ObservedRepositoryReview {
    let root = try RepositoryReviewDiffProjectionFixture.makeRepository()
    defer { RepositoryReviewDiffProjectionFixture.remove(root) }
    let observed = await ObservedRepositoryReviewer().observe(
        cwd: root, runID: runID, turnID: turnID,
        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
    var object = try JSONSerialization.jsonObject(with: observed.encoded()) as! [String: Any]
    if let files {
        object["files"] = try files.map {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
        }
    }
    let retainedSectionCount = diff.components(separatedBy: "diff --git ").dropFirst().count
    object["diffs"] = diffKinds.map { kind in
        [
            "kind": kind,
            "text": diff,
            "byteCount": diff.utf8.count,
            "truncated": false,
            "retainedSectionCount": retainedSectionCount,
        ]
    }
    return try ObservedRepositoryReview.decode(JSONSerialization.data(withJSONObject: object))
}

private func repositoryReviewProjectionDescriptor(
    review: ObservedRepositoryReview,
    artifactID: String = "review-artifact"
) throws -> WorkServiceArtifactDescriptor {
    let work = WorkRef(workHostID: "projection-host", workID: "projection-work")
    let journal = JournalRef.work(work, journalID: "projection-journal")
    let digest = "sha256:" + String(repeating: "a", count: 64)
    let bodyReference = TimelineBodyReference(
        authority: journal, referenceID: digest,
        mediaType: ObservedRepositoryReviewFormat.mediaType,
        byteCount: 1, digest: digest)
    let source = EventRef(journal: journal, eventID: "artifact-event")
    return try WorkServiceArtifactDescriptor(
        artifactID: artifactID, work: work, label: "review.json",
        mediaType: ObservedRepositoryReviewFormat.mediaType,
        byteCount: 1, digest: digest, available: true, bodyReference: bodyReference,
        sourceEvent: source,
        session: SessionRef("projection-session"),
        sessionAttachment: SessionAttachmentRef("projection-attachment"),
        run: RunRef(review.runID), turn: TurnRef(review.turnID),
        action: ActionRef("projection-action"), causedByEventID: source)
}

func testRepositoryReviewDiffProjectionParsesBoundedHunksAndQuotedPaths() async throws {
    let context = String(repeating: "+context line with unicode β\n", count: 32)
    let diff = """
    diff --git "a/a/old name/naïve.txt" "b/b/new name/naïve.txt"
    similarity index 90%
    rename from "a/old name/naïve.txt"
    rename to "b/new name/naïve.txt"
    @@ -1 +1,33 @@ heading
    -old
    +new
    \(context)@@ -20,1 +20,1 @@ second
    -old second
    +new second
    """
    let review = try await repositoryReviewProjectionReview(
        diff: diff,
        files: [ObservedRepositoryFile(
            path: "b/new name/naïve.txt", kind: "tracked", indexStatus: "M", workTreeStatus: "M",
            originalPath: "a/old name/naïve.txt")],
        diffKinds: ["staged", "unstaged"])
    let descriptor = try repositoryReviewProjectionDescriptor(review: review)
    let projection = try RepositoryReviewDiffProjection.prepare(
        review: review, descriptor: descriptor,
        limits: RepositoryReviewDiffLimits(maximumContextBytes: 512))

    XCTAssertTrue(projection.isStructured)
    let section = try XCTUnwrap(projection.sections.first)
    XCTAssertEqual(section.kind, .renamed)
    XCTAssertEqual(section.path, "b/new name/naïve.txt")
    XCTAssertEqual(section.originalPath, "a/old name/naïve.txt")
    XCTAssertEqual(section.hunks.count, 2)
    XCTAssertTrue(section.hunks[0].contextTruncated)
    XCTAssertTrue(section.hunks[0].anchorContextTruncated)
    XCTAssertTrue(section.hunks[0].anchorContext.utf8.count <= 384)
    XCTAssertEqual(section.hunkAnchors(identity: projection.identity).count, 2)
    XCTAssertNotNil(section.fileAnchor(identity: projection.identity))
    XCTAssertEqual(Set(projection.sections.map(\.diffKind)), Set(["staged", "unstaged"]))

    let anchor = try XCTUnwrap(section.hunkAnchors(identity: projection.identity).first)
    XCTAssertTrue(anchor.renderedPrefix.contains("file: \"b/new name/naïve.txt\""))
    XCTAssertFalse(anchor.renderedPrefix.contains("file: b/new name/naïve.txt"))
    do {
        _ = try anchor.composeFeedback("Please keep this change", maximumBytes: 2_000)
    } catch {
        XCTFail("valid anchor should fit composer bounds: \(error)")
    }

    let unquotedLiteralPath = """
    diff --git a/a/old name/naïve.txt b/b/new name/naïve.txt
    rename from a/old name/naïve.txt
    rename to b/new name/naïve.txt
    @@ -1 +1 @@
    -old
    +new
    """
    let unquotedReview = try await repositoryReviewProjectionReview(
        diff: unquotedLiteralPath,
        files: [ObservedRepositoryFile(
            path: "b/new name/naïve.txt", kind: "tracked", indexStatus: ".", workTreeStatus: "M",
            originalPath: "a/old name/naïve.txt")])
    let unquotedDescriptor = try repositoryReviewProjectionDescriptor(review: unquotedReview)
    let unquoted = try RepositoryReviewDiffProjection.prepare(
        review: unquotedReview, descriptor: unquotedDescriptor)
    XCTAssertEqual(unquoted.sections.first?.path, "b/new name/naïve.txt")
    XCTAssertEqual(unquoted.sections.first?.originalPath, "a/old name/naïve.txt")
}

func testRepositoryReviewDiffProjectionFallsBackOnAmbiguousAndMalformedSections() async throws {
    let diff = """
    diff --git a/one b/one b/two
    @@ malformed
    +body
    diff --git a/valid.txt b/valid.txt
    @@ -1 +1 @@
    -old
    +new
    """
    let review = try await repositoryReviewProjectionReview(
        diff: diff,
        files: [ObservedRepositoryFile(
            path: "valid.txt", kind: "tracked", indexStatus: ".", workTreeStatus: "M")])
    let descriptor = try repositoryReviewProjectionDescriptor(review: review)
    let projection = try RepositoryReviewDiffProjection.prepare(review: review, descriptor: descriptor)

    XCTAssertFalse(projection.isStructured)
    XCTAssertEqual(projection.sections.count, 2)
    XCTAssertNil(projection.sections[0].fileAnchor(identity: projection.identity))
    XCTAssertTrue(projection.rawFallbacks.contains { $0.reason.contains("header paths") })
    XCTAssertEqual(projection.sections[1].hunks.count, 1)

    let longPathDiff = "diff --git a/very-long-file-name.txt b/very-long-file-name.txt\n"
        + "@@ -1 +1 @@\n-old\n+new\n"
    let boundedReview = try await repositoryReviewProjectionReview(
        diff: longPathDiff,
        files: [ObservedRepositoryFile(
            path: "very-long-file-name.txt", kind: "tracked", indexStatus: ".", workTreeStatus: "M")])
    let boundedDescriptor = try repositoryReviewProjectionDescriptor(review: boundedReview)
    let bounded = try RepositoryReviewDiffProjection.prepare(
        review: boundedReview, descriptor: boundedDescriptor,
        limits: RepositoryReviewDiffLimits(maximumPathBytes: 8))
    XCTAssertNil(bounded.sections.first?.path)
    XCTAssertTrue(bounded.rawFallbacks.contains { $0.reason.contains("header paths") })

    let duplicateDiff = """
    diff --git a/valid.txt b/valid.txt
    @@ -1 +1 @@
    -old
    +new
    diff --git a/valid.txt b/valid.txt
    @@ -2 +2 @@
    -old2
    +new2
    """
    let duplicateReview = try await repositoryReviewProjectionReview(
        diff: duplicateDiff,
        files: [ObservedRepositoryFile(
            path: "valid.txt", kind: "tracked", indexStatus: ".", workTreeStatus: "M")])
    let duplicateDescriptor = try repositoryReviewProjectionDescriptor(review: duplicateReview)
    let duplicate = try RepositoryReviewDiffProjection.prepare(
        review: duplicateReview, descriptor: duplicateDescriptor)
    XCTAssertEqual(duplicate.sections.count, 1)
    XCTAssertTrue(duplicate.rawFallbacks.contains { $0.reason.contains("duplicate") })
    XCTAssertFalse(duplicate.isStructured)

    let ordinarySource = """
    diff --git a/tracked.txt b/tracked.txt
    @@ -1 +1 @@
    -Subproject commit old
    +Subproject commit new
    """
    let ordinaryReview = try await repositoryReviewProjectionReview(
        diff: ordinarySource,
        files: [ObservedRepositoryFile(
            path: "tracked.txt", kind: "tracked", indexStatus: ".", workTreeStatus: "M")])
    let ordinaryDescriptor = try repositoryReviewProjectionDescriptor(review: ordinaryReview)
    let ordinary = try RepositoryReviewDiffProjection.prepare(
        review: ordinaryReview, descriptor: ordinaryDescriptor)
    XCTAssertEqual(ordinary.sections.first?.kind, .modified)
    XCTAssertEqual(ordinary.sections.first?.hunks.count, 1)

    let conflictingRename = """
    diff --git a/old.txt b/new.txt
    rename from old.txt
    rename to other.txt
    """
    let conflictingReview = try await repositoryReviewProjectionReview(
        diff: conflictingRename,
        files: [ObservedRepositoryFile(
            path: "new.txt", kind: "tracked", indexStatus: ".", workTreeStatus: "M",
            originalPath: "old.txt")])
    let conflictingDescriptor = try repositoryReviewProjectionDescriptor(review: conflictingReview)
    let conflicting = try RepositoryReviewDiffProjection.prepare(
        review: conflictingReview, descriptor: conflictingDescriptor)
    XCTAssertNil(conflicting.sections.first?.fileAnchor(identity: conflicting.identity))
    XCTAssertTrue(conflicting.rawFallbacks.contains { $0.reason.contains("rename-to") })

    let conflictingPatch = """
    diff --git a/file.txt b/file.txt
    --- a/other.txt
    +++ b/file.txt
    @@ -1 +1 @@
    -old
    +new
    """
    let conflictingPatchReview = try await repositoryReviewProjectionReview(
        diff: conflictingPatch,
        files: [ObservedRepositoryFile(
            path: "file.txt", kind: "tracked", indexStatus: ".", workTreeStatus: "M")])
    let conflictingPatchDescriptor = try repositoryReviewProjectionDescriptor(review: conflictingPatchReview)
    let conflictingPatchProjection = try RepositoryReviewDiffProjection.prepare(
        review: conflictingPatchReview, descriptor: conflictingPatchDescriptor)
    XCTAssertNil(conflictingPatchProjection.sections.first?.fileAnchor(
        identity: conflictingPatchProjection.identity))

    let oversizedOctal = "diff --git \"a/bad\\777.txt\" \"b/bad\\777.txt\"\n"
        + "@@ -1 +1 @@\n-old\n+new\n"
    let oversizedOctalReview = try await repositoryReviewProjectionReview(diff: oversizedOctal)
    let oversizedOctalDescriptor = try repositoryReviewProjectionDescriptor(review: oversizedOctalReview)
    let oversizedOctalProjection = try RepositoryReviewDiffProjection.prepare(
        review: oversizedOctalReview, descriptor: oversizedOctalDescriptor)
    XCTAssertTrue(oversizedOctalProjection.rawFallbacks.contains {
        $0.reason.contains("header paths")
    })

    let unterminatedPath = "diff --git \"a/unterminated.txt \"b/unterminated.txt\"\n"
        + "@@ -1 +1 @@\n-old\n+new\n"
    let unterminatedReview = try await repositoryReviewProjectionReview(diff: unterminatedPath)
    let unterminatedDescriptor = try repositoryReviewProjectionDescriptor(review: unterminatedReview)
    let unterminated = try RepositoryReviewDiffProjection.prepare(
        review: unterminatedReview, descriptor: unterminatedDescriptor)
    XCTAssertTrue(unterminated.rawFallbacks.contains { $0.reason.contains("header paths") })

    let malformedRename = "diff --git a/file.txt b/file.txt\n"
        + "rename from \"unterminated\n@@ -1 +1 @@\n-old\n+new\n"
    let malformedRenameReview = try await repositoryReviewProjectionReview(diff: malformedRename)
    let malformedRenameDescriptor = try repositoryReviewProjectionDescriptor(review: malformedRenameReview)
    let malformedRenameProjection = try RepositoryReviewDiffProjection.prepare(
        review: malformedRenameReview, descriptor: malformedRenameDescriptor)
    XCTAssertNil(malformedRenameProjection.sections.first?.fileAnchor(
        identity: malformedRenameProjection.identity))
    XCTAssertTrue(malformedRenameProjection.rawFallbacks.contains { $0.reason.contains("rename-from") })
}

func testRepositoryReviewDiffProjectionRetainsBinaryAndBoundedRawTruth() async throws {
    let diff = "diff --git a/blob.bin b/blob.bin\nBinary files a/blob.bin and b/blob.bin differ\n"
        + String(repeating: "x", count: 512)
    let review = try await repositoryReviewProjectionReview(
        diff: diff,
        files: [ObservedRepositoryFile(
            path: "blob.bin", kind: "tracked", indexStatus: ".", workTreeStatus: "M", isBinary: true)])
    let descriptor = try repositoryReviewProjectionDescriptor(review: review)
    let limits = RepositoryReviewDiffLimits(maximumRawSectionBytes: 32)
    let projection = try RepositoryReviewDiffProjection.prepare(
        review: review, descriptor: descriptor, limits: limits)

    let section = try XCTUnwrap(projection.sections.first)
    XCTAssertEqual(section.kind, .binary)
    XCTAssertTrue(section.rawSectionTruncated)
    XCTAssertTrue(section.hunks.isEmpty)
    XCTAssertNotNil(section.fileAnchor(identity: projection.identity))

    let binaryOnlyReview = try await repositoryReviewProjectionReview(
        diff: "",
        files: [ObservedRepositoryFile(
            path: "binary-only.bin", kind: "tracked", indexStatus: ".", workTreeStatus: "M",
            isBinary: true)],
        diffKinds: [])
    let binaryOnlyDescriptor = try repositoryReviewProjectionDescriptor(review: binaryOnlyReview)
    let binaryOnly = try RepositoryReviewDiffProjection.prepare(
        review: binaryOnlyReview, descriptor: binaryOnlyDescriptor)
    XCTAssertEqual(binaryOnly.sections.count, 1)
    XCTAssertEqual(binaryOnly.sections.first?.diffKind, "unstaged")
    XCTAssertEqual(binaryOnly.sections.first?.kind, .binary)
    XCTAssertNotNil(binaryOnly.sections.first?.fileAnchor(identity: binaryOnly.identity))
}

func testRepositoryReviewFeedbackAnchorRejectsCapacityBeforeTruncatingIdentity() async throws {
    let review = try await repositoryReviewProjectionReview(
        diff: "diff --git a/file.txt b/file.txt\n@@ -1 +1 @@\n-old\n+new\n",
        files: [ObservedRepositoryFile(
            path: "file.txt", kind: "tracked", indexStatus: ".", workTreeStatus: "M")])
    let descriptor = try repositoryReviewProjectionDescriptor(review: review)
    let projection = try RepositoryReviewDiffProjection.prepare(review: review, descriptor: descriptor)
    let anchor = try XCTUnwrap(projection.sections[0].hunkAnchors(identity: projection.identity).first)

    do {
        _ = try anchor.composeFeedback("feedback", maximumBytes: 20)
        XCTFail("identity prefix must not be truncated")
    } catch let error as RepositoryReviewFeedbackAnchor.CompositionError {
        guard case .prefixExceedsCapacity = error else {
            return XCTFail("unexpected composition error: \(error)")
        }
    } catch {
        XCTFail("unexpected error: \(error)")
    }
}

let casesRepositoryReviewDiffProjection: [Case] = [
    ("repository review diff projection: visual lines preserve exact text and unknown markers", {
        let context = " unchanged\n-old\n+new\n\\ No newline at end of file\n@unknown\n+unicode\u{2028}separator\n"
        let hunk = RepositoryReviewDiffHunk(header: "@@ -1,2 +1,2 @@", oldStart: 1, oldCount: 2,
            newStart: 1, newCount: 2, context: context, contextTruncated: true)
        let lines = RepositoryReviewDiffDisplayLine.lines(in: hunk)
        XCTAssertEqual(lines.map(\.kind), [.context, .removal, .addition, .marker, .marker, .addition, .marker])
        XCTAssertEqual(lines.map(\.text).joined(separator: "\n"), context)
        XCTAssertTrue(hunk.contextTruncated)
        XCTAssertEqual(hunk.anchorContext, context)
    }),
    ("repository review diff projection: bounded quoted hunks", {
        try await testRepositoryReviewDiffProjectionParsesBoundedHunksAndQuotedPaths()
    }),
    ("repository review diff projection: malformed fallback", {
        try await testRepositoryReviewDiffProjectionFallsBackOnAmbiguousAndMalformedSections()
    }),
    ("repository review diff projection: binary raw bounds", {
        try await testRepositoryReviewDiffProjectionRetainsBinaryAndBoundedRawTruth()
    }),
    ("repository review diff projection: identity capacity", {
        try await testRepositoryReviewFeedbackAnchorRejectsCapacityBeforeTruncatingIdentity()
    }),
]
