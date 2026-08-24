import SwiftUI
import AviaryCore

/// "The request you asked for is built — take it."
///
/// Deliberately a banner rather than a modal or a Workshop-tab detail. A rebuild finishes
/// while you are doing something else, which is the whole design: the slow part happens
/// unasked so the click is instant. That only pays off if the offer finds you wherever you
/// are, and only if it can be ignored — so it sits at the top of the window on every screen
/// and never takes focus.
struct ReloadBanner: View {
    @Environment(AppModel.self) private var model
    @State private var showingError = false

    var body: some View {
        switch model.reloader.phase {
        case .idle:
            EmptyView()
        case .building(_, let title):
            shell(tint: Design.accent) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Rebuilding Aviary — ").font(.system(size: 11.5))
                        + Text(title).font(.system(size: 11.5, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(model.reloader.launchMode?.describedTarget ?? "")
                        .font(Design.mono(9.5)).foregroundStyle(.tertiary)
                }
            }
        case .ready(_, let title):
            shell(tint: Design.success) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11)).foregroundStyle(Design.success)
                        Text("Built — ").font(.system(size: 11.5))
                            + Text(title).font(.system(size: 11.5, weight: .semibold))
                        if let seconds = model.reloader.lastBuildDuration {
                            Text(Fmt.duration(seconds))
                                .font(Design.numeric(10)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 10)
                        Button("Relaunch") { model.reloadNow() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .keyboardShortcut("r", modifiers: [.command, .shift])
                        dismissButton
                    }
                    // The cost of taking the offer, when there is one. Stated here because
                    // this is the moment of the decision, not buried in a preference.
                    if let cost = model.reloadCost {
                        Text(cost)
                            .font(.system(size: 10)).foregroundStyle(Design.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .unchanged(_, let title):
            shell(tint: Design.accent) {
                HStack(spacing: 8) {
                    Image(systemName: "equal.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("\(title) is done, and the binary did not change — nothing to reload.")
                        .font(.system(size: 11.5))
                    Spacer(minLength: 8)
                    dismissButton
                }
            }
        case .failed(_, let title, let detail):
            shell(tint: Design.danger) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(Design.danger)
                        Text("\(title) does not build").font(.system(size: 11.5, weight: .semibold))
                        Spacer(minLength: 10)
                        Button(showingError ? "Hide" : "Show") { showingError.toggle() }
                            .buttonStyle(.link).font(.system(size: 10.5))
                        Button("Tell the agent") { tellTheAgent(detail) }
                            .buttonStyle(.bordered).controlSize(.small)
                        dismissButton
                    }
                    // No relaunch offered, and that is the point of showing this at all: the
                    // binary is unchanged, so relaunching would show you the old app while you
                    // believed you were looking at the new one.
                    if showingError {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(detail)
                                .font(Design.mono(10))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxHeight: 80)
                    } else {
                        Text(detail.split(separator: "\n").first.map(String.init) ?? detail)
                            .font(Design.mono(10)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var dismissButton: some View {
        Button {
            model.reloader.phase = .idle
        } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help("Dismiss. The build is done either way.")
    }

    /// Hand the build failure back to the board as a note.
    ///
    /// The agent marked this done and it does not compile, which is exactly the thing it needs
    /// to know and the one thing it cannot observe — it is not the process that builds.
    private func tellTheAgent(_ detail: String) {
        guard let request = currentRequest else { return }
        model.addNote("This was marked done but the build fails:\n\n" + detail, to: request)
        model.reloader.phase = .idle
        model.toast = AppModel.Toast(message: "Build failure noted on \(request.id).")
    }

    private var currentRequest: WorkshopRequest? {
        guard let id = model.reloader.phase.requestID else { return nil }
        return model.board.requests.first { $0.id == id }
    }

    private func shell<Content: View>(
        tint: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 720)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 3)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
