//
//  ReadableContentWidth.swift
//  Conduit
//
//  Conduit's screens were drawn for a phone. On a wide window (an iPad, a
//  landscape iPhone) a chat's lines, Settings' cards and a call's captions
//  would otherwise run the whole width of the window.
//

import SwiftUI

extension View {
    /// Keeps the content to `maxWidth`, centered, on a wider window. The
    /// content fills the space it's offered, so it suits a screen's whole
    /// content rather than a view with a size of its own. The
    /// margins go into the safe area rather than a frame: a backdrop that
    /// ignores the safe area still fills the window, and a scroll view still
    /// scrolls from its margins with its content inset. Nothing changes on a
    /// window narrower than `maxWidth`.
    func readableContentWidth(_ maxWidth: CGFloat) -> some View {
        modifier(ReadableContentWidth(maxWidth: { _ in maxWidth }))
    }

    /// Keeps the content to a column that widens with the window, as
    /// `ReadableWidth.chat(available:)` does for a chat.
    func readableContentWidth(scaling maxWidth: @escaping (CGFloat) -> CGFloat) -> some View {
        modifier(ReadableContentWidth(maxWidth: maxWidth))
    }
}

/// Readable widths for the screens that cap theirs.
enum ReadableWidth {
    /// A chat's transcript and composer: the narrowest its column gets on a
    /// wide window. A wider window widens it (`chat(available:)`).
    static let chat: CGFloat = 760
    /// The widest a chat's column gets, however wide the window.
    static let chatMax: CGFloat = 1040
    /// The share of the chat's width its column takes between those two.
    static let chatShare: CGFloat = 0.72
    /// Settings' pages.
    static let settings: CGFloat = 720
    /// A Chats or Bots list shown on its own on a wide window, the list
    /// beside the chat hidden (`V2ChatListPreference`).
    static let list: CGFloat = 720
    /// A voice call's captions and controls.
    static let call: CGFloat = 640

    /// A chat's column for `available` points of width: the phone's
    /// 760 pt column on an iPad beside the list, growing with a maximized
    /// Mac or iPad window up to `chatMax`, so the text doesn't sit in a
    /// narrow strip in the middle of it.
    static func chat(available: CGFloat) -> CGFloat {
        min(chatMax, max(chat, (available * chatShare).rounded(.down)))
    }

    /// The margin on each side that keeps `available` points of width to
    /// `maxWidth`.
    static func margin(available: CGFloat, maxWidth: CGFloat) -> CGFloat {
        max(0, ((available - maxWidth) / 2).rounded(.down))
    }
}

private struct ReadableContentWidth: ViewModifier {
    let maxWidth: (CGFloat) -> CGFloat

    func body(content: Content) -> some View {
        // A reader rather than a measured state, so the first layout is
        // already at its width: a chat restoring its scroll position must
        // not lay its rows out twice.
        GeometryReader { proxy in
            content
                .safeAreaPadding(.horizontal, ReadableWidth.margin(available: proxy.size.width, maxWidth: maxWidth(proxy.size.width)))
                // Centered for content narrower than the window too; the
                // reader alone would put it at the leading edge.
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
