//
//  ReadableContentWidth.swift
//  Conduit
//
//  Conduit's screens were drawn for a phone. On a wide window (an iPad, a
//  Mac, a landscape iPhone) a chat's lines, Settings' cards and a call's captions
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

    /// A chat's column: `ReadableWidth.chat(available:)` wide, its text a
    /// size or more larger as the column grows (`ReadableWidth.columnText`),
    /// so a maximized window shows bigger text rather than longer lines.
    func readableChatColumn() -> some View {
        modifier(ReadableContentWidth(maxWidth: { ReadableWidth.chat(available: $0) }, textBase: ReadableWidth.chat, scalesChatText: true))
    }

    /// Settings' column: `ReadableWidth.settings(available:)` wide, its
    /// text growing with it as a chat's does.
    func readableSettingsColumn() -> some View {
        modifier(ReadableContentWidth(maxWidth: { ReadableWidth.settings(available: $0) }, textBase: ReadableWidth.settings))
    }
}

/// Readable widths for the screens that cap theirs.
enum ReadableWidth {
    /// A chat's transcript and composer: the narrowest its column gets on a
    /// wide window. A wider window widens it (`chat(available:)`).
    static let chat: CGFloat = 760
    /// The widest a chat's column gets, however wide the window, on an
    /// iPhone or iPad (a Mac's: its base times `macLineGrowth` and
    /// `macMaxTextScale`).
    static let chatMax: CGFloat = 1040
    /// The share of the chat's width its column takes between those two.
    static let chatShare: CGFloat = 0.72
    /// Settings' pages: the narrowest their column gets on a wide window.
    /// A wider window widens it (`settings(available:)`).
    static let settings: CGFloat = 720
    /// The widest Settings' column gets on an iPhone or iPad: room for its
    /// text's three steps.
    static let settingsMax: CGFloat = 980
    /// A Chats or Bots list shown on its own on a wide window, the list
    /// beside the chat hidden (`V2ChatListPreference`).
    static let list: CGFloat = 720
    /// A voice call's captions and controls.
    static let call: CGFloat = 640

    /// On a Mac, which draws text styles at one size, a column's text grows
    /// by point size in proportion to the column (`columnText`) rather than
    /// by steps: its lines hold this many times a phone's words before the
    /// text grows (a Mac's own text is smaller, and its window wider)...
    static let macLineGrowth: CGFloat = 1.5
    /// ...and grow until the text is this many times its size, the margins
    /// past that.
    static let macMaxTextScale: CGFloat = 2.2
    /// The share of the window a Mac's column takes.
    static let macShare: CGFloat = 0.8

    /// A chat's column for `available` points of width: the phone's
    /// 760 pt column on an iPad beside the list, growing with a maximized
    /// Mac or iPad window up to `chatMax`, so the text doesn't sit in a
    /// narrow strip in the middle of it. On a Mac it takes most of the
    /// window, its text growing with it.
    static func chat(available: CGFloat, systemGrowsTextStyles: Bool = ScaledFont.systemGrowsTextStyles()) -> CGFloat {
        width(available: available, base: chat, max: chatMax, systemGrowsTextStyles: systemGrowsTextStyles)
    }

    /// Settings' column for `available` points of width, growing with a
    /// maximized window as a chat's does, up to `settingsMax`.
    static func settings(available: CGFloat, systemGrowsTextStyles: Bool = ScaledFont.systemGrowsTextStyles()) -> CGFloat {
        width(available: available, base: settings, max: settingsMax, systemGrowsTextStyles: systemGrowsTextStyles)
    }

    private static func width(available: CGFloat, base: CGFloat, max cap: CGFloat, systemGrowsTextStyles: Bool) -> CGFloat {
        if systemGrowsTextStyles {
            return min(cap, max(base, (available * chatShare).rounded(.down)))
        }
        return min(base * macLineGrowth * macMaxTextScale, max(base, (available * macShare).rounded(.down)))
    }

    /// How many text sizes a column of `column` points steps up from the
    /// system's, for a column that is `base` points wide at the system's
    /// size (a chat's 760, Settings' 720): one for each size whose body
    /// text still fits as many words to a line (body at the default size
    /// is 17, 19, 21 and 23 pt). A phone, and an iPad beside the list,
    /// keep the system's size; a chat column of 1040 pt or more
    /// steps up three.
    static func textSteps(column: CGFloat, base: CGFloat) -> Int {
        let growth = column / base
        return chatTextGrowth.filter { growth >= $0 }.count
    }

    /// The steps a column can take from the system's `size`: none past the
    /// largest standard size, so an accessibility size, already larger,
    /// stays as the user set it.
    static func textSteps(column: CGFloat, base: CGFloat, from size: DynamicTypeSize) -> Int {
        let sizes = ChatTypography.standardDynamicTypeSizes
        guard let index = sizes.firstIndex(of: size) else { return 0 }
        return min(textSteps(column: column, base: base), sizes.count - 1 - index)
    }

    /// What a column `column` points wide sets for its content at the
    /// system's `size`: the Dynamic Type size its own text draws at, the
    /// steps a chat's transcript takes (none outside a chat), and what its
    /// UIKit text and `scaledFont` grow from (nil in a column that doesn't
    /// step its text, `base` nil, so a fixed column inside a stepped one
    /// keeps the stepped one's). Where the system doesn't grow text styles
    /// (a Mac), no steps: the text grows by point size with the column
    /// instead, from `macLineGrowth` times its base width.
    static func columnText(
        column: CGFloat,
        base: CGFloat?,
        scalesChatText: Bool,
        size: DynamicTypeSize,
        systemGrowsTextStyles: Bool = ScaledFont.systemGrowsTextStyles()
    ) -> (size: DynamicTypeSize, chatSteps: Int, text: ColumnText?) {
        guard let base else { return (size, 0, nil) }
        guard systemGrowsTextStyles else {
            let scale = min(macMaxTextScale, max(1, column / (base * macLineGrowth)))
            // In twentieths, so a window drag re-lays the transcript a
            // few times rather than at every point.
            return (size, 0, ColumnText(base: size, scale: (scale * 20).rounded() / 20))
        }
        let steps = textSteps(column: column, base: base, from: size)
        let sizes = ChatTypography.standardDynamicTypeSizes
        let boosted = sizes.firstIndex(of: size).map { sizes[min(sizes.count - 1, $0 + steps)] } ?? size
        return (boosted, scalesChatText ? steps : 0, ColumnText(base: size))
    }

    /// The body text growth each step brings at the default size
    /// (19, 21 and 23 pt over 17).
    static let chatTextGrowth: [CGFloat] = ChatTypography.standardBodySizes
        .dropFirst(ChatTypography.defaultIndex + 1)
        .map { $0 / ChatTypography.standardBodySizes[ChatTypography.defaultIndex] }

    /// The margin on each side that keeps `available` points of width to
    /// `maxWidth`.
    static func margin(available: CGFloat, maxWidth: CGFloat) -> CGFloat {
        max(0, ((available - maxWidth) / 2).rounded(.down))
    }
}

private struct ReadableContentWidth: ViewModifier {
    let maxWidth: (CGFloat) -> CGFloat
    /// The column's width at the system's text size, for a column whose
    /// text steps up as it widens; nil keeps the text as it is.
    var textBase: CGFloat?
    /// A chat's column: its transcript takes the steps too
    /// (`chatWidthTextSteps`).
    var scalesChatText = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        // A reader rather than a measured state, so the first layout is
        // already at its width: a chat restoring its scroll position must
        // not lay its rows out twice.
        GeometryReader { proxy in
            let column = maxWidth(proxy.size.width)
            let layout = ReadableWidth.columnText(column: column, base: textBase, scalesChatText: scalesChatText, size: dynamicTypeSize)
            content
                .safeAreaPadding(.horizontal, ReadableWidth.margin(available: proxy.size.width, maxWidth: column))
                // Centered for content narrower than the window too; the
                // reader alone would put it at the leading edge.
                .frame(width: proxy.size.width, height: proxy.size.height)
                // The column's own text (step rows, cards, the composer)
                // through Dynamic Type; transcript text, which resolves
                // UIKit fonts, by the steps' scale from the system's size
                // (ChatTextAppearance.widened).
                .dynamicTypeSize(layout.size)
                .environment(\.chatWidthTextSteps, layout.chatSteps)
                // Only in a column that steps its text: nil elsewhere, and a
                // fixed column inside one keeps the stepped one's.
                .transformEnvironment(\.columnText) { columnText in
                    if let text = layout.text { columnText = text }
                }
                // On a Mac, the column's plain text grows in points too
                // (`scaledFont` sets the rest). Transformed rather than a
                // branch, so a resize keeps the column's views (and a
                // chat's scroll position).
                .transformEnvironment(\.font) { font in
                    if let text = layout.text, text.scale != 1 { font = ScaledFont.body.font(in: text) }
                }
        }
    }
}
