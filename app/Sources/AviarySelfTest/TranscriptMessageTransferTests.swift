import Foundation
@testable import AviaryCore

/// Focused transfer tests. Registration remains in `main.swift`, alongside the other self-test
/// case arrays, so this file stays safe for package targets that compile tests independently.
func test_transcriptMessageTransferPreservesExactRoleText() throws {
    var item = TranscriptItem(
        id: "assistant-1", kind: .assistant, timestamp: Date(timeIntervalSince1970: 1))
    let markdown = "  **keep Markdown**\n\n- and whitespace  "
    item.blocks = [.text(markdown), .thinking("hidden reasoning")]

    XCTAssertEqual(TranscriptMessageTransfer.authoredText(for: item), markdown)
}

func test_transcriptMessageTransferUsesUserBlocksOnly() throws {
    var item = TranscriptItem(
        id: "user-1", kind: .user, timestamp: Date(timeIntervalSince1970: 1))
    let markdown = "\n  **keep user whitespace**  \n"
    item.blocks = [.text(markdown)]
    item.text = "unrelated legacy field"

    XCTAssertEqual(TranscriptMessageTransfer.authoredText(for: item), markdown)
}

func test_transcriptMessageTransferStripsOnlyAgentEnvelope() throws {
    var item = TranscriptItem(
        id: "agent-1", kind: .agentMessage, timestamp: Date(timeIntervalSince1970: 1))
    item.text = "[from child]\nMessage id: msg-1\n\n  **keep**\n"

    XCTAssertEqual(
        TranscriptMessageTransfer.authoredText(for: item), "  **keep**\n")
}

func test_transcriptMessageTransferDoesNotUseUnrelatedItemText() throws {
    var item = TranscriptItem(
        id: "note-1", kind: .note, timestamp: Date(timeIntervalSince1970: 1))
    item.text = "not a message"

    XCTAssertNil(TranscriptMessageTransfer.authoredText(for: item))
}
