import Foundation

#if os(Linux)
/// Small text formatting primitives used by the headless Work Host projection.
///
/// The GUI's richer formatting surface remains in the macOS-only analytics sources. Keeping
/// these few renderings here avoids pulling ``RelativeDateTimeFormatter`` into the Linux daemon.
public enum Fmt {
    public static func tokens(_ value: Int) -> String {
        switch abs(value) {
        case 0: return "0"
        case 1..<1_000: return "\(value)"
        case 1_000..<1_000_000:
            return String(format: "%.1fK", Double(value) / 1_000)
                .replacingOccurrences(of: ".0K", with: "K")
        case 1_000..<1_000_000_000:
            return String(format: "%.2fM", Double(value) / 1_000_000)
        default:
            return String(format: "%.2fB", Double(value) / 1_000_000_000)
        }
    }

    public static func timestamp(_ date: Date) -> String {
        guard date > .distantPast else { return "—" }
        return timestampFormatter.string(from: date)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm:ss"
        return formatter
    }()
}

/// ISO-8601 parsing needed by the Linux memory reader. The full workshop board owns the same
/// policy on macOS, but the daemon deliberately does not compile that GUI-adjacent source.
enum AviaryDateParsing {
    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
#endif
