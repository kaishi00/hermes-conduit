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
        modifier(ReadableContentWidth(maxWidth: maxWidth))
    }
}

/// Readable widths for the screens that cap theirs.
enum ReadableWidth {
    /// A chat's transcript and composer.
    static let chat: CGFloat = 760
    /// Settings' pages.
    static let settings: CGFloat = 720
    /// A voice call's captions and controls.
    static let call: CGFloat = 640

    /// The margin on each side that keeps `available` points of width to
    /// `maxWidth`.
    static func margin(available: CGFloat, maxWidth: CGFloat) -> CGFloat {
        max(0, ((available - maxWidth) / 2).rounded(.down))
    }
}

private struct ReadableContentWidth: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        // A reader rather than a measured state, so the first layout is
        // already at its width: a chat restoring its scroll position must
        // not lay its rows out twice.
        GeometryReader { proxy in
            content
                .safeAreaPadding(.horizontal, ReadableWidth.margin(available: proxy.size.width, maxWidth: maxWidth))
                // Centered for content narrower than the window too; the
                // reader alone would put it at the leading edge.
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
