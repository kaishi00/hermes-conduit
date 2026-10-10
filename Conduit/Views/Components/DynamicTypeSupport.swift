//
//  DynamicTypeSupport.swift
//  Conduit
//
//  Layout helpers for very large text sizes (Settings > Accessibility >
//  Display & Text Size > Larger Text). Content text scales freely; a glyph
//  drawn inside a fixed-size badge or button is capped so it can't spill
//  out of its frame, and rows stack their parts instead of clipping.
//

import SwiftUI

extension DynamicTypeSize {
    /// The largest size a text-style glyph inside a small fixed frame
    /// (22–44 pt) can reach before it overflows the frame.
    static let fixedGlyphCap: DynamicTypeSize = .xxLarge
}

extension View {
    /// Caps a text-style glyph (an SF Symbol or a short label such as a step
    /// number) that sits in a fixed-size frame. Like any
    /// `dynamicTypeSize` cap it applies to the whole subtree, so put it on
    /// the glyph, or on a row that holds only fixed-size glyph buttons.
    func conduitFixedGlyph() -> some View {
        dynamicTypeSize(...DynamicTypeSize.fixedGlyphCap)
    }
}

/// Side by side at regular text sizes, stacked at accessibility sizes, so
/// two short pieces of text don't truncate each other on one line.
/// `verticalAlignment` applies side by side, `horizontalAlignment` stacked.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var horizontalAlignment: HorizontalAlignment = .leading
    var verticalAlignment: VerticalAlignment = .center
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: horizontalAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: verticalAlignment, spacing: spacing))
        layout { content }
    }
}
