//
//  ReadableContentWidth.swift
//  Conduit
//
//  Conduit's screens were drawn for a phone. On a wide window (an iPad, a
//  landscape iPhone) a chat's lines, Settings' cards and a call's captions
//  would otherwise run the whole width of the window.
//

import OSLog
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
    /// size or more larger as the column grows (`ReadableWidth.textSteps`),
    /// so a maximized window shows bigger text rather than longer lines.
    func readableChatColumn() -> some View {
        modifier(ReadableContentWidth(maxWidth: ReadableWidth.chat(available:), textBase: ReadableWidth.chat, scalesChatText: true))
    }

    /// Settings' column: `ReadableWidth.settings(available:)` wide, its
    /// text stepping up with it as a chat's does.
    func readableSettingsColumn() -> some View {
        modifier(ReadableContentWidth(maxWidth: ReadableWidth.settings(available:), textBase: ReadableWidth.settings))
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
    /// Settings' pages: the narrowest their column gets on a wide window.
    /// A wider window widens it (`settings(available:)`).
    static let settings: CGFloat = 720
    /// The widest Settings' column gets: room for its text's three steps.
    static let settingsMax: CGFloat = 980
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

    /// Settings' column for `available` points of width, growing with a
    /// maximized window as a chat's does, up to `settingsMax`.
    static func settings(available: CGFloat) -> CGFloat {
        min(settingsMax, max(settings, (available * chatShare).rounded(.down)))
    }

    /// How many text sizes a column of `column` points steps up from the
    /// system's, for a column that is `base` points wide at the system's
    /// size (a chat's 760, Settings' 720): one for each size whose body
    /// text still fits as many words to a line (body at the default size
    /// is 17, 19, 21 and 23 pt). A phone, and an iPad beside the list,
    /// keep the system's size; a maximized window's 1040 pt chat column
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
    /// steps a chat's transcript takes (none outside a chat), and the
    /// system's size as the column's base (nil in a column that doesn't
    /// step its text, `base` nil, so a fixed column inside a stepped one
    /// keeps its base).
    static func columnText(column: CGFloat, base: CGFloat?, scalesChatText: Bool, size: DynamicTypeSize)
        -> (size: DynamicTypeSize, chatSteps: Int, base: DynamicTypeSize?) {
        guard let base else { return (size, 0, nil) }
        let steps = textSteps(column: column, base: base, from: size)
        let sizes = ChatTypography.standardDynamicTypeSizes
        let boosted = sizes.firstIndex(of: size).map { sizes[min(sizes.count - 1, $0 + steps)] } ?? size
        return (boosted, scalesChatText ? steps : 0, size)
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
            let text = ReadableWidth.columnText(column: column, base: textBase, scalesChatText: scalesChatText, size: dynamicTypeSize)
            content
                .safeAreaPadding(.horizontal, ReadableWidth.margin(available: proxy.size.width, maxWidth: column))
                // Centered for content narrower than the window too; the
                // reader alone would put it at the leading edge.
                .frame(width: proxy.size.width, height: proxy.size.height)
                // The column's own text (step rows, cards, the composer)
                // through Dynamic Type; transcript text, which resolves
                // UIKit fonts, by the steps' scale from the system's size
                // (ChatTextAppearance.widened).
                .dynamicTypeSize(text.size)
                .environment(\.chatWidthTextSteps, text.chatSteps)
                // Only in a column that steps its text: nil elsewhere, and a
                // fixed column inside one keeps its base.
                .transformEnvironment(\.chatColumnBaseTextSize) { base in
                    if let columnBase = text.base { base = columnBase }
                }
                .onChange(of: text.size, initial: true) { _, _ in
                    if let textBase {
                        let steps = ReadableWidth.textSteps(column: column, base: textBase, from: dynamicTypeSize)
                        MacTextStepsReport.noteOnce(column: scalesChatText ? "chat" : "settings", steps: steps, from: dynamicTypeSize)
                    }
                }
        }
    }
}

/// What a Mac does with a column's text steps, logged once a launch when
/// the first column that steps its text lays out, steps or none: an iPad
/// app there may draw every Dynamic Type size alike, which left #1393's
/// steps doing nothing, and no build of ours can be probed on the Mac
/// itself. `log show --predicate 'category == "ReadableWidth"'` reads it.
@MainActor
enum MacTextStepsReport {
    private static let log = Logger(subsystem: "com.milim.relay", category: "ReadableWidth")
    private static var noted = false

    static func noteOnce(column: String, steps: Int, from base: DynamicTypeSize, onMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac) {
        guard onMac, !noted else { return }
        noted = true
        let uikit = [UIContentSizeCategory.large, .extraExtraExtraLarge].map {
            Double(UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: $0)).pointSize)
        }
        let swiftUI = [DynamicTypeSize.large, .xxxLarge].map {
            UIHostingController(rootView: Text(verbatim: "Conduit").font(.body).dynamicTypeSize($0))
                .sizeThatFits(in: CGSize(width: 1000, height: 1000)).height.native
        }
        log.notice("\(column, privacy: .public) column: text steps \(steps, privacy: .public) from \(String(describing: base), privacy: .public): UIKit body \(uikit[0], privacy: .public) to \(uikit[1], privacy: .public) pt, SwiftUI body line \(swiftUI[0], privacy: .public) to \(swiftUI[1], privacy: .public) pt")
    }
}
