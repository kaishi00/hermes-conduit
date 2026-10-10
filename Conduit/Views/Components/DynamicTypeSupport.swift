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
    /// Fixed headers above a scrolling list (the session drawer's workspace
    /// chip, tabs, New Chat row and filter chips) stop here, so at the
    /// largest sizes they don't fill the screen and leave the list no room.
    static let pinnedChromeCap: DynamicTypeSize = .accessibility1
    /// List rows stop here: past it a two-line row fills most of a small
    /// screen.
    static let listRowCap: DynamicTypeSize = .accessibility3
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
/// two short pieces of text don't truncate each other on one line. It reads
/// the environment's size, so under a `dynamicTypeSize` cap below the
/// accessibility sizes it stays side by side.
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

/// Children side by side in equal widths. Its ideal width is the widest
/// child's times the count, so inside a `ViewThatFits` it is only chosen
/// when every child fits its share, not just when the total does.
struct EqualWidthHStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let width = proposal.width ?? (ideal.map(\.width).max() ?? 0) * CGFloat(subviews.count) + gaps
        let cellWidth = max(0, (width - gaps) / CGFloat(subviews.count))
        let height = subviews
            .map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: proposal.height)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let cellWidth = max(0, (bounds.width - gaps) / CGFloat(subviews.count))
        var x = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: cellWidth, height: bounds.height)
            )
            x += cellWidth + spacing
        }
    }
}
