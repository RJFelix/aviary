import SwiftUI

struct ChatWindowTitleKey: PreferenceKey {
    static var defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

struct ChatWindowSubtitleKey: PreferenceKey {
    static var defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

private struct UsesChatWindowTitleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesChatWindowTitle: Bool {
        get { self[UsesChatWindowTitleKey.self] }
        set { self[UsesChatWindowTitleKey.self] = newValue }
    }
}
