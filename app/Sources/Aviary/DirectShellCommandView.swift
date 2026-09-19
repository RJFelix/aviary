import AviaryCore
import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// A compact tray for Work-hosted shell commands. The view intentionally accepts the service
/// projection rather than a worker: execution, stop, dismissal, and pending-context truth stay
/// owned by the caller's canonical Work service.
public struct DirectShellCommandTray: View {
    public let entries: [WorkServiceDirectShellEntry]
    public let onStop: (WorkServiceDirectShellEntry) -> Void
    public let onDismiss: (WorkServiceDirectShellEntry) -> Void

    public init(
        entries: [WorkServiceDirectShellEntry],
        onStop: @escaping (WorkServiceDirectShellEntry) -> Void,
        onDismiss: @escaping (WorkServiceDirectShellEntry) -> Void
    ) {
        self.entries = entries
        self.onStop = onStop
        self.onDismiss = onDismiss
    }

    public var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Command activity")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Runs directly on the project's Work Host; it does not start a model turn.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    DirectShellCommandCard(
                        entry: entry,
                        onStop: { onStop(entry) },
                        onDismiss: { onDismiss(entry) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A single command card. A terminal result can be dismissed only while it is still pending
/// model context; dismissal does not remove the action or its output artifact.
public struct DirectShellCommandCard: View {
    public let entry: WorkServiceDirectShellEntry
    public let onStop: () -> Void
    public let onDismiss: () -> Void

    public init(
        entry: WorkServiceDirectShellEntry,
        onStop: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.entry = entry
        self.onStop = onStop
        self.onDismiss = onDismiss
    }

    private var isTerminal: Bool { entry.state.isTerminal }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(Design.tool)
                Text("Run command")
                    .font(.system(size: 13, weight: .semibold))
                DirectShellStatusBadge(entry: entry)
                Spacer(minLength: 5)
                if !isTerminal {
                    Button("Stop", action: onStop)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Design.warning)
                        .help("Stop this command on the Work Host")
                } else if entry.pendingContext {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove command output from the next message")
                    .help("Do not attach this output to the next message")
                }
            }

            HStack(spacing: 7) {
                Label(entry.language.rawValue.uppercased(), systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(attachmentLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(entry.pendingContext ? Design.accent : .secondary)
                Spacer(minLength: 4)
            }

            DirectShellCodeBlock(title: "Command", source: entry.source)

            if let result = entry.result {
                DirectShellOutputBlock(title: "Standard output", capture: result.stdout)
                DirectShellOutputBlock(title: "Error output", capture: result.stderr)
            } else if !isTerminal {
                Label("Waiting for the command to finish…", systemImage: "clock")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                Label("The command ended without retained output.", systemImage: "questionmark.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command activity, \(DirectShellStatusText.title(for: entry))")
    }

    private var attachmentLabel: String {
        entry.pendingContext ? "Included with your next message" : "Not attached"
    }
}

/// Confirmation is deliberately independent of AppModel and LiveRun so the caller can retain
/// the exact captured command and workspace identity until it admits the typed Work request.
public struct DirectShellCommandConfirmation: View {
    public let source: Data
    public let language: DirectShellLanguage
    public let workspaceLabel: String
    public let initialTimeout: TimeInterval?
    public let onConfirm: (TimeInterval?) -> Void
    public let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var timeoutText: String

    public init(
        source: Data,
        language: DirectShellLanguage,
        workspaceLabel: String,
        timeout: TimeInterval? = nil,
        onConfirm: @escaping (TimeInterval?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.source = source
        self.language = language
        self.workspaceLabel = workspaceLabel
        self.initialTimeout = timeout
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _timeoutText = State(initialValue: timeout.map { String(format: "%.2f", $0) } ?? "")
    }

    public init(
        source: String,
        language: DirectShellLanguage,
        workspaceLabel: String,
        timeout: TimeInterval? = nil,
        onConfirm: @escaping (TimeInterval?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.init(
            source: Data(source.utf8), language: language, workspaceLabel: workspaceLabel,
            timeout: timeout, onConfirm: onConfirm, onCancel: onCancel)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Run command?")
                    .font(.headline)
                Text("This runs once on the project's Work Host. It does not ask the model to run it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 7) {
                Label(workspaceLabel, systemImage: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Label(language.rawValue.uppercased(), systemImage: "terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            DirectShellCodeBlock(title: "Exact command", source: source)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Time limit")
                        .font(.system(size: 11, weight: .semibold))
                    TextField("Unlimited", text: $timeoutText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 105)
                    Text("seconds")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Text("Optional — leave blank to let the command run until it exits or is stopped.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let timeoutError {
                    Text(timeoutError)
                        .font(.system(size: 10))
                        .foregroundStyle(Design.warning)
                }
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run command") {
                    guard let timeout = parsedTimeout else {
                        onConfirm(nil)
                        return
                    }
                    onConfirm(timeout)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isTimeoutInputValid)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 560)
    }

    private var parsedTimeout: TimeInterval? {
        let trimmed = timeoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = TimeInterval(trimmed), value.isFinite, value > 0,
              value <= WorkServiceDirectShellBounds.maximumTimeout else { return nil }
        return value
    }

    private var isTimeoutInputValid: Bool {
        let trimmed = timeoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || parsedTimeout != nil
    }

    private var timeoutError: String? {
        let trimmed = timeoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, parsedTimeout == nil else { return nil }
        return "Enter a duration up to 7 days in seconds, or leave blank for unlimited."
    }
}

private struct DirectShellStatusBadge: View {
    let entry: WorkServiceDirectShellEntry

    var body: some View {
        Text(DirectShellStatusText.title(for: entry))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(DirectShellStatusText.tint(for: entry))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(DirectShellStatusText.tint(for: entry).opacity(0.12), in: Capsule())
    }
}

private enum DirectShellStatusText {
    static func title(for entry: WorkServiceDirectShellEntry) -> String {
        if let result = entry.result {
            switch result.status {
            case .exited(let code):
                return code == 0 ? "Completed" : "Failed · exit \(code)"
            case .nonzero(let code): return "Failed · exit \(code)"
            case .signaled(let signal): return "Stopped · signal \(signal)"
            case .canceled: return "Stopped"
            case .timedOut: return "Timed out"
            case .launchFailed, .invalidRequest: return "Could not start"
            case .workerFailed: return "Outcome unclear"
            }
        }
        switch entry.state {
        case .proposed: return "Preparing"
        case .queued: return "Waiting"
        case .running: return "Running"
        case .cancelRequested: return "Stopping"
        case .succeeded: return "Completed"
        case .failed: return "Failed"
        case .canceled: return "Stopped"
        case .indeterminateEffect: return "Outcome unclear"
        case .unknown: return "Status unknown"
        }
    }

    static func tint(for entry: WorkServiceDirectShellEntry) -> Color {
        if !entry.state.isTerminal {
            return entry.state == .cancelRequested ? Design.warning : Design.accent
        }
        if let result = entry.result {
            switch result.status {
            case .exited(let code): return code == 0 ? Design.success : Design.danger
            case .canceled, .timedOut, .signaled: return Design.warning
            case .nonzero, .launchFailed, .invalidRequest, .workerFailed: return Design.danger
            }
        }
        return entry.state == .indeterminateEffect ? Design.danger : .secondary
    }
}

private struct DirectShellCodeBlock: View {
    let title: String
    let source: Data

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copy(source) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            DirectShellTextViewport(text: DirectShellByteDisplay(source).text,
                fontSize: 11, maximumHeight: 170)
        }
    }

    private func copy(_ data: Data) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .string)
        #endif
    }
}

private struct DirectShellOutputBlock: View {
    let title: String
    let capture: DirectShellOutputCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                Text("· \(capture.isComplete ? "" : "at least ")\(capture.totalByteCount) bytes")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !capture.isComplete {
                    Text("Output incomplete").font(.caption).foregroundStyle(Design.warning)
                }
                if capture.omittedByteCount > 0 {
                    Text("\(capture.omittedByteCount) omitted")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Design.warning)
                }
            }
            if capture.totalByteCount == 0 && capture.isComplete {
                Text("No output")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                DirectShellTextViewport(text: DirectShellByteDisplay(capture).text,
                    fontSize: 10.5, maximumHeight: 190)
            }
        }
    }
}

/// A two-axis scroll view otherwise centers short text in an unconstrained content area.
/// Give it a viewport-sized leading edge and an explicit, content-sized vertical budget.
private struct DirectShellTextViewport: View {
    let text: String
    let fontSize: CGFloat
    let maximumHeight: CGFloat

    private var height: CGFloat {
        let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return min(maximumHeight, max(38, CGFloat(lines) * (fontSize + 4) + 18))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(Design.mono(fontSize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(minWidth: max(0, geometry.size.width - 18), alignment: .topLeading)
                    .padding(9)
            }
        }
        .frame(height: height)
        .background(Design.codeBackground, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct DirectShellByteDisplay {
    let text: String

    init(_ data: Data) {
        text = Self.text(for: data)
    }

    init(_ capture: DirectShellOutputCapture) {
        text = Self.text(for: capture)
    }

    private static func text(for data: Data) -> String {
        guard !data.isEmpty else { return "(empty)" }
        guard let value = String(data: data, encoding: .utf8) else {
            return "[binary bytes; retained data shown as base64]\n" + data.base64EncodedString()
        }
        return value.isEmpty ? "(empty)" : value
    }

    private static func text(for capture: DirectShellOutputCapture) -> String {
        guard capture.totalByteCount > 0 else { return "(no output)" }
        if let head = String(data: capture.head, encoding: .utf8),
           let tail = String(data: capture.tail, encoding: .utf8) {
            guard capture.omittedByteCount > 0 else {
                return head.isEmpty ? "(empty)" : head
            }
            return head + "\n\n[\(capture.omittedByteCount) bytes omitted]\n\n" + tail
        }
        var parts = ["[binary bytes; retained data shown as base64]"]
        if !capture.head.isEmpty { parts.append(capture.head.base64EncodedString()) }
        if capture.omittedByteCount > 0 {
            parts.append("[\(capture.omittedByteCount) bytes omitted]")
        }
        if !capture.tail.isEmpty { parts.append(capture.tail.base64EncodedString()) }
        return parts.joined(separator: "\n")
    }
}
