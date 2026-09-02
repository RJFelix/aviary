import Foundation
@testable import AviaryCore

private func legacySystemPrompt(
    cwd: String, skills: String = "", memory: String = "", includeContextFiles: Bool = true
) -> String {
    var lines = [
        "You are a coding agent working in \(cwd) on a macOS machine.",
        "",
        "You act by running Python in a persistent interpreter — that is your only tool, "
            + "and it is enough. State survives between calls, so build on what you have "
            + "already loaded instead of repeating work.",
        "",
        "`sh(command)` runs a shell command and returns {'stdout','stderr','status'}. Its "
            + "working directory and environment persist across calls, so `sh('cd sub')` "
            + "then `sh('pwd')` does what you would expect. `cwd()` reports where you are.",
        "",
        "Prefer the tools the repository already has — git, grep, and whatever its own "
            + "task runner exposes — over reimplementing them in Python.",
        "",
        "Say what you found, not what you are about to do. When you are finished, stop "
            + "calling tools and answer.",
    ]
    if !memory.isEmpty {
        lines.append("")
        lines.append(memory)
    }
    if !skills.isEmpty {
        lines.append("")
        lines.append(skills)
    }
    for name in includeContextFiles ? ["AGENTS.md", "CLAUDE.md"] : [] {
        let url = URL(fileURLWithPath: cwd).appending(path: name)
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            lines.append("")
            lines.append("## \(name) (from \(cwd))")
            lines.append("")
            lines.append(text.count > 12_000 ? String(text.prefix(12_000)) + "\n…(truncated)" : text)
        }
    }
    return lines.joined(separator: "\n")
}

private func promptAssemblyTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "aviary-prompt-assembly-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func test_systemPromptAssemblyMatchesLegacyForEveryRenderedSection() throws {
    let cwd = try promptAssemblyTempDirectory()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let memory = "## What you have learned before\n\n- secret memory text"
    let skills = "## Skills\n\n- **marker-like** — <available_skills>\n  `## /not-a-file`"
    let agents = "project rules\n"
    let claude = "another project rule"
    try agents.write(to: cwd.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    try claude.write(to: cwd.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)

    let assembly = try SystemPromptAssembly.build(
        cwd: cwd.path, skills: skills, memory: memory, includeContextFiles: true)
    XCTAssertEqual(
        assembly.text,
        legacySystemPrompt(cwd: cwd.path, skills: skills, memory: memory),
        "the producer-side decomposition must not alter provider prompt bytes")
    XCTAssertEqual(
        assembly.sources.map(\.kind),
        [.workingDirectory, .baseInstruction, .memory, .skill, .contextFile, .contextFile])
    XCTAssertTrue(assembly.sources[0].sourceID.hasPrefix("working-directory:path-sha256:"))
    XCTAssertEqual(assembly.sources[1].sourceID, "base-instruction:v1")
    XCTAssertEqual(assembly.sources[2].sourceID, "memory:rendered:v1")
    XCTAssertEqual(assembly.sources[3].sourceID, "skill:rendered:v1")
    XCTAssertTrue(assembly.sources[4].sourceID.hasPrefix("context-file:path-sha256:"))
    XCTAssertTrue(assembly.sources[5].sourceID.hasPrefix("context-file:path-sha256:"))
    XCTAssertEqual(
        assembly.sources.map(\.renderedBody).joined(), assembly.text,
        "headings and separators must belong to an exact source slice")
    XCTAssertEqual(assembly.byteCount, Data(assembly.text.utf8).count)
    let metadata = String(decoding: try JSONEncoder().encode(assembly), as: UTF8.self)
    XCTAssertFalse(metadata.contains(cwd.path), "encoded metadata must not expose cwd")
    XCTAssertFalse(metadata.contains("/AGENTS.md"), "encoded metadata must not expose file paths")
    XCTAssertFalse(metadata.contains("/CLAUDE.md"), "encoded metadata must not expose file paths")
    XCTAssertTrue(metadata.contains("path-sha256:"))
    XCTAssertEqual(
        assembly.sources.map(\.renderedByteOffset),
        [0, assembly.sources[0].renderedByteCount,
         assembly.sources[0..<2].reduce(0) { $0 + $1.renderedByteCount },
         assembly.sources[0..<3].reduce(0) { $0 + $1.renderedByteCount },
         assembly.sources[0..<4].reduce(0) { $0 + $1.renderedByteCount },
         assembly.sources[0..<5].reduce(0) { $0 + $1.renderedByteCount }])
}

func test_systemPromptAssemblyReportsContextStatesAndCharacterTruncation() throws {
    let cwd = try promptAssemblyTempDirectory()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let longText = String(repeating: "é", count: 12_001)
    try longText.write(to: cwd.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
        at: cwd.appending(path: "CLAUDE.md"), withIntermediateDirectories: true)

    let assembly = try SystemPromptAssembly.build(cwd: cwd.path)
    let agents = try XCTUnwrap(assembly.sources.first { $0.label == "AGENTS.md" })
    let claude = try XCTUnwrap(assembly.sources.last { $0.label == "CLAUDE.md" })
    XCTAssertEqual(agents.status, .truncated)
    XCTAssertEqual(agents.fullByteCount, Data(longText.utf8).count)
    XCTAssertEqual(agents.deliveredBody, String(longText.prefix(12_000)))
    XCTAssertEqual(agents.renderedBody, "\n\n## AGENTS.md (from \(cwd.path))\n\n"
        + agents.deliveredBody + "\n…(truncated)")
    XCTAssertEqual(claude.status, .unreadable)
    XCTAssertNil(claude.fullBody)
    XCTAssertEqual(claude.deliveredByteCount, 0)

    let disabled = try SystemPromptAssembly.build(cwd: cwd.path, includeContextFiles: false)
    XCTAssertEqual(disabled.sources.suffix(2).map(\.status), [.disabled, .disabled])
    XCTAssertEqual(disabled.text, legacySystemPrompt(cwd: cwd.path, includeContextFiles: false))
}

func test_systemPromptAssemblyUsesDistinctStableIdentityAndContentDigests() throws {
    let first = try SystemPromptAssembly.build(cwd: "/tmp/project", memory: "one")
    let second = try SystemPromptAssembly.build(cwd: "/tmp/project", memory: "two")
    let firstMemory = try XCTUnwrap(first.sources.first { $0.kind == .memory })
    let secondMemory = try XCTUnwrap(second.sources.first { $0.kind == .memory })
    XCTAssertEqual(firstMemory.sourceID, secondMemory.sourceID)
    XCTAssertEqual(firstMemory.identity, secondMemory.identity)
    XCTAssertNotEqual(firstMemory.fullDigest, secondMemory.fullDigest)
    XCTAssertNotEqual(firstMemory.sourceID, firstMemory.fullDigest)
    XCTAssertNotEqual(firstMemory.deliveredByteCount, firstMemory.renderedByteCount)
    XCTAssertEqual(first.sources[0].sourceID, second.sources[0].sourceID)
}

func test_systemPromptAssemblyRejectsDuplicateIDsAndDoesNotEncodeBodies() throws {
    let first = try PromptSource(
        sourceID: "same", kind: .generated, label: "Generated", fullBody: "credential",
        deliveredBody: "credential")
    let second = try PromptSource(
        sourceID: "same", kind: .generated, label: "Generated", fullBody: "other",
        deliveredBody: "other", renderedByteOffset: Data("credential".utf8).count)
    do {
        _ = try SystemPromptAssembly(text: "credentialother", sources: [first, second])
        XCTFail("duplicate source IDs must fail")
    } catch SystemPromptAssemblyError.duplicateSourceID("same") { }
    catch { XCTFail("wrong error for duplicate source ID: \(error)") }

    let encoded = String(decoding: try JSONEncoder().encode(
        try SystemPromptAssembly(text: "credential", sources: [first])), as: UTF8.self)
    XCTAssertFalse(encoded.contains("credential"), "metadata must not persist raw source text")
    XCTAssertFalse(encoded.contains("other"))
}
