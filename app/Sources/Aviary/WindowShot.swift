import AppKit
import ScreenCaptureKit
import CoreImage

/// Rasterizes one of our own windows to PNG.
///
/// Two paths, in order of fidelity:
///
/// **ScreenCaptureKit** asks the WindowServer for the window as actually composited, which is
/// the only way to get AppKit vibrancy and material layers. `cacheDisplay` asks the view
/// hierarchy to draw itself, and those layers are not drawn by the view — the sidebar came
/// out flat white and the Sessions inspector flat black, which is also why half of Aviary's
/// offscreen snapshots look broken when they are not.
///
/// **`cacheDisplay`** remains the fallback, unchanged, for when Screen Recording has not been
/// granted or ScreenCaptureKit fails for any other reason. It needs no permission and gets
/// everything except those composited layers, so a refused prompt costs fidelity rather than
/// the feature.
///
/// The choice is deliberately not a preference. A screenshot that silently omits a third of
/// the window is a worse default than a one-time permission prompt, and the fallback means
/// the prompt is never load-bearing.
enum WindowShot {

    /// PNG bytes for `window`, or nil if neither path worked.
    ///
    /// `timeout` exists because this sits in front of writing a request to the board, and a
    /// screenshot must never be the reason something you typed is lost. On expiry the
    /// fallback runs, which is synchronous and cannot hang.
    @MainActor
    static func capture(window: NSWindow, timeout: TimeInterval = 4) async -> Data? {
        if let data = await withTimeout(timeout, { await composited(window: window) }) {
            return data
        }
        return drawn(window: window)
    }

    // MARK: The good path

    @MainActor
    static func composited(window: NSWindow) async -> Data? {
        let number = window.windowNumber
        guard number > 0 else { return nil }
        do {
            // This call is what triggers the Screen Recording prompt the first time. It
            // throws rather than blocking when the grant is absent, which is what makes the
            // fallback clean.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: {
                $0.windowID == CGWindowID(number)
            }) else {
                if ProcessInfo.processInfo.environment["AVIARY_CAPTURE_DEBUG"] != nil {
                    let ids = content.windows.map { "\($0.windowID)" }.joined(separator: ",")
                    FileHandle.standardError.write(
                        Data("window \(number) not shareable; saw [\(ids)]\n".utf8))
                }
                return nil
            }

            let scale = window.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int(target.frame.width * scale)
            config.height = Int(target.frame.height * scale)
            config.showsCursor = false
            // Transparent corners rather than black ones: the window is rounded, and the
            // area outside it should read as absent, not as part of the UI.
            config.backgroundColor = .clear
            config.ignoreShadowsSingleWindow = true

            let filter = SCContentFilter(desktopIndependentWindow: target)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            return png(from: image)
        } catch {
            if ProcessInfo.processInfo.environment["AVIARY_CAPTURE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            }
            return nil
        }
    }

    // MARK: The fallback

    @MainActor
    private static func drawn(window: NSWindow) -> Data? {
        guard let view = window.contentView,
              view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Plumbing

    private static func png(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    /// Races a body against a deadline, returning nil if the deadline wins.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ body: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
