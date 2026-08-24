import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// An image the agent asked to look at, read off disk and made affordable to send.
///
/// The whole path either side of this already existed — all three providers serialise
/// `ChatContent.image`, the transcript parses and renders it, resume carries it — and nothing
/// in the app ever produced one. So the gap was never "support vision"; it was this file.
///
/// Two things it insists on, both about cost. Images are billed by area, and a retina
/// screenshot is 3024×1964 before anything has happened: sent as-is that is several thousand
/// tokens for a picture whose legible content would survive being halved. And a model that
/// cannot read images at all should never be handed one — the builtin is not bound in that
/// case, so the failure is "the name does not exist" rather than a provider error nobody can
/// act on.
public struct AttachedImage: Sendable, Hashable {
    public var mimeType: String
    public var base64: String
    public var width: Int
    public var height: Int
    /// Encoded size, which is what actually crosses the wire.
    public var byteCount: Int
    public var path: String
    /// Set when the image was scaled down, so the caller can say so rather than silently
    /// answering a question about a picture the agent did not quite see.
    public var scaledFrom: (width: Int, height: Int)?

    public static func == (a: AttachedImage, b: AttachedImage) -> Bool {
        a.base64 == b.base64 && a.path == b.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(base64)
        hasher.combine(path)
    }

    /// Anthropic's guidance and every other provider's practical limit agree closely enough
    /// that one number serves: beyond roughly 1568px on the long edge, more pixels buy nothing
    /// and cost linearly.
    public static let maxEdge = 1568
    /// A hard stop well under every provider's per-image limit, after downscaling has had its
    /// go. Better a readable error than a 413 from someone else's server.
    public static let maxEncodedBytes = 4 * 1024 * 1024

    public enum Failure: LocalizedError, Sendable {
        case notFound(String)
        case unreadable(String)
        case tooLarge(bytes: Int)

        public var errorDescription: String? {
            switch self {
            case .notFound(let path):
                return "No file at \(path)."
            case .unreadable(let path):
                return "\(path) is not an image this machine can decode. PNG, JPEG, GIF, "
                    + "WebP, HEIC and TIFF all work."
            case .tooLarge(let bytes):
                return "Still \(Fmt.bytes(bytes)) after scaling down, which is past what a "
                    + "provider will take. Crop it to the part that matters."
            }
        }
    }

    /// Read, decode, downscale if worthwhile, and re-encode.
    ///
    /// Re-encoded as PNG or JPEG regardless of what came in, because the set of formats macOS
    /// can *decode* is much larger than the set a model provider accepts — HEIC being the one
    /// that matters, since it is what a Mac screenshot pipeline and every iPhone produce.
    public static func read(path: String) throws -> AttachedImage {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.notFound(url.path)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.unreadable(url.path) }

        let original = (width: image.width, height: image.height)
        let longEdge = max(original.width, original.height)
        var rendered = image
        if longEdge > maxEdge {
            let scale = Double(maxEdge) / Double(longEdge)
            let target = (
                width: max(1, Int((Double(original.width) * scale).rounded())),
                height: max(1, Int((Double(original.height) * scale).rounded())))
            if let scaled = resize(image, to: target) { rendered = scaled }
        }

        // Photographs are enormous as PNG and indistinguishable as JPEG; screenshots are the
        // reverse, and text in a screenshot is exactly what the agent is usually reading.
        let looksPhotographic = rendered.width * rendered.height > 640 * 640
            && image.alphaInfo == .none
        let type: UTType = looksPhotographic ? .jpeg : .png
        guard let data = encode(rendered, as: type) else { throw Failure.unreadable(url.path) }
        guard data.count <= maxEncodedBytes else { throw Failure.tooLarge(bytes: data.count) }

        return AttachedImage(
            mimeType: type == .jpeg ? "image/jpeg" : "image/png",
            base64: data.base64EncodedString(),
            width: rendered.width, height: rendered.height,
            byteCount: data.count, path: url.path,
            scaledFrom: rendered.width == original.width ? nil : original)
    }

    private static func resize(_ image: CGImage, to target: (width: Int, height: Int)) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: target.width, height: target.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, type.identifier as CFString, 1, nil)
        else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// What the builtin hands back to the agent's Python.
    public var summary: JSONValue {
        var out: [String: JSONValue] = [
            "path": .string(path),
            "width": .number(Double(width)),
            "height": .number(Double(height)),
            "bytes": .number(Double(byteCount)),
        ]
        if let scaledFrom {
            out["scaled_from"] = .string("\(scaledFrom.width)×\(scaledFrom.height)")
        }
        return .object(out)
    }
}
