import AppKit

/// Native key-event regression using a private editor, never a real chat or provider.
enum ChatEditorProbe {
    @MainActor static func runIfRequested() {
        guard CommandLine.arguments.contains("--chat-editor-probe") else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = ChatMessageEditor.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 160)
        window.contentView = scroll
        scroll.tile()
        let editor = scroll.documentView as! ChatMessageEditor.ChatTextView
        window.makeFirstResponder(editor)
        var submissions = 0
        editor.onSubmit = { submissions += 1 }
        func require(_ condition: Bool, _ reason: String) {
            guard condition else {
                FileHandle.standardError.write(Data("chat editor probe FAILED: \(reason)\n".utf8))
                exit(1)
            }
        }
        require(editor.frame.height >= scroll.contentSize.height,
                "empty editor must cover the viewport")
        require(editor.frame.width == scroll.contentSize.width && !scroll.hasHorizontalScroller,
                "editor must follow viewport width")
        require(editor.textContainerInset == NSSize(width: 8, height: 10)
                && editor.textContainer?.lineFragmentPadding == 0,
                "placeholder and caret must share container insets")
        func key(_ modifiers: NSEvent.ModifierFlags = [], code: UInt16 = 36, repeated: Bool = false) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: repeated, keyCode: code)!
            editor.keyDown(with: event)
        }
        editor.string = "A **literal** message"
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.canSubmit = true
        key()
        require(submissions == 1 && editor.string == "A **literal** message", "Return must submit exact text")
        key(.shift)
        require(submissions == 1 && editor.string.hasSuffix("\n"), "Shift-Return must insert a newline")
        key(.command)
        require(submissions == 2, "Command-Return remains an alias")
        key([], code: 76)
        require(submissions == 3, "Keypad Return submits")
        key(repeated: true)
        require(submissions == 3, "Holding Return must not repeatedly submit")
        editor.canSubmit = false
        let prior = editor.string
        key()
        require(submissions == 3 && editor.string == prior, "Disabled Return cannot send or alter draft")
        editor.canSubmit = true
        editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        require(editor.hasMarkedText(), "IME fixture must have marked text")
        key()
        require(submissions == 3, "Return during IME composition must not send")
        let target = LiveRun.productionRunPaneVisualFixture(
            items: [], pendingInputs: [], deliveryAttention: [], actions: [], draft: "")
        let transferred = "  **Exact text**\n\nNo automatic send.  "
        require(AgentMessageDraftTransfer.prepare(transferred, for: target), "empty chat accepts draft")
        require(target.draft == transferred && target.items.isEmpty && !target.serviceCommandInFlight,
                "forwarding preserves bytes and does not dispatch")
        require(!AgentMessageDraftTransfer.prepare("overwrite", for: target)
                && target.draft == transferred, "forwarding cannot replace an existing draft")
        target.setDraft(" \n ")
        require(!AgentMessageDraftTransfer.prepare(transferred, for: target)
                && target.draft == " \n ", "whitespace draft must be preserved")
        print("chat editor: viewport, Return/Shift/Command/keypad/repeat, disabled, IME and draft forwarding PASS")
        exit(0)
    }
}
