import SwiftUI

struct ChatBottomMarkerPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

struct ChatViewportFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

struct ChatRenderedScrollContentPreferenceKey: PreferenceKey {
    static var defaultValue: ChatRenderedScrollContent? = nil
    static func reduce(
        value: inout ChatRenderedScrollContent?,
        nextValue: () -> ChatRenderedScrollContent?
    ) {
        value = nextValue() ?? value
    }
}

struct ChatRenderedScrollTargetsPreferenceKey: PreferenceKey {
    static var defaultValue = ChatRenderedScrollTargets()

    static func reduce(
        value: inout ChatRenderedScrollTargets,
        nextValue: () -> ChatRenderedScrollTargets
    ) {
        ChatRenderedScrollTargets.reduce(value: &value, nextValue: nextValue())
    }
}
