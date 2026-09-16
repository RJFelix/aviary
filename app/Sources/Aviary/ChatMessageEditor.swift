import AppKit
import SwiftUI

/// A plain-text editor with native selection/undo and chat-specific Return handling.
/// Placeholder and insertion point share the same text-container geometry.
struct ChatMessageEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var canSubmit: Bool
    var onSubmit: () -> Void
    var accessibilityLabel: String = "Message"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView()
        let editor = scroll.documentView as! ChatTextView
        editor.delegate = context.coordinator
        update(editor, context: context)
        return scroll
    }

    /// Shared with the native editor probe, including the viewport sizing behavior.
    static func makeScrollView() -> ChatScrollView {
        let scroll = ChatScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let editor = ChatTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 64))
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.minSize = NSSize(width: 0, height: 44)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ChatTextView else { return }
        update(editor, context: context)
    }

    private func update(_ editor: ChatTextView, context: Context) {
        context.coordinator.parent = self
        editor.placeholder = placeholder
        editor.canSubmit = canSubmit
        editor.onSubmit = onSubmit
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.setAccessibilityHelp("Return sends. Shift-Return adds a new line.")
        // Streaming/status redraws must not replace the editor buffer or its selection.
        if editor.string != text, !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: location,
                length: min(selection.length, length - location)))
        }
        editor.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatMessageEditor
        init(_ parent: ChatMessageEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ChatTextView else { return }
            parent.text = editor.string
            editor.needsDisplay = true
        }
    }

    final class ChatScrollView: NSScrollView {
        override func tile() {
            super.tile()
            guard let editor = documentView as? ChatTextView else { return }
            let viewport = contentSize
            // Clicking anywhere in the visible editor must reach its text view, even when
            // empty. Long text remains vertically resizable beyond this minimum.
            if editor.minSize != viewport { editor.minSize = viewport }
            let documentSize = NSSize(width: viewport.width,
                height: max(viewport.height, editor.frame.height))
            if editor.frame.size != documentSize { editor.setFrameSize(documentSize) }
        }
    }

    final class ChatTextView: NSTextView {
        var placeholder = ""
        var canSubmit = false
        var onSubmit: () -> Void = {}

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let newlineModifiers: NSEvent.ModifierFlags = [.shift, .option, .control]
            if isReturn, !hasMarkedText(), event.modifierFlags.intersection(newlineModifiers).isEmpty {
                if canSubmit && !event.isARepeat { onSubmit() }
                return
            }
            super.keyDown(with: event)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty else { return }
            let inset = textContainerInset
            (placeholder as NSString).draw(in: NSRect(
                x: inset.width, y: inset.height,
                width: max(0, bounds.width - 2 * inset.width),
                height: max(0, bounds.height - 2 * inset.height)),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}
