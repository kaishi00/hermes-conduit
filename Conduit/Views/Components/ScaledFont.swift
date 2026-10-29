//
//  ScaledFont.swift
//  Conduit
//
//  The app's text styles, set with `.scaledFont(.caption)` rather than
//  `.font(.caption)`. Everywhere the system sizes them by Dynamic Type, they
//  are exactly the text style. On a Mac, which draws every text style at its
//  default size whatever size the view asks for, a wide column that steps
//  its text up (`readableChatColumn`, `readableSettingsColumn`) has them set
//  in points instead, at iOS's size for the stepped one.
//

import SwiftUI

/// A text style with the changes the app makes to it.
struct ScaledFont: Equatable {
    var style: Font.TextStyle
    var weight: Font.Weight?
    /// A design asked for with `system(_:design:weight:)`.
    var design: Font.Design?
    var monospacedFamily = false
    var monospacedDigits = false

    static let largeTitle = ScaledFont(style: .largeTitle)
    static let title = ScaledFont(style: .title)
    static let title2 = ScaledFont(style: .title2)
    static let title3 = ScaledFont(style: .title3)
    static let headline = ScaledFont(style: .headline)
    static let subheadline = ScaledFont(style: .subheadline)
    static let body = ScaledFont(style: .body)
    static let callout = ScaledFont(style: .callout)
    static let footnote = ScaledFont(style: .footnote)
    static let caption = ScaledFont(style: .caption)
    static let caption2 = ScaledFont(style: .caption2)

    static func system(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil) -> ScaledFont {
        ScaledFont(style: style, weight: weight, design: design)
    }

    func weight(_ weight: Font.Weight) -> ScaledFont {
        var font = self
        font.weight = weight
        return font
    }

    func bold() -> ScaledFont { weight(.bold) }

    func monospaced() -> ScaledFont {
        var font = self
        font.monospacedFamily = true
        return font
    }

    func monospacedDigit() -> ScaledFont {
        var font = self
        font.monospacedDigits = true
        return font
    }

    /// The font, in points at iOS's size for `size` when there is one
    /// (`pointSizedText`), else the text style itself.
    func font(pointSizedAt size: DynamicTypeSize? = nil) -> Font {
        var font: Font
        if let size, let points = Self.points(style, at: size) {
            font = .system(
                size: points,
                weight: weight ?? (style == .headline ? .semibold : .regular),
                design: monospacedFamily ? .monospaced : design ?? .default
            )
        } else {
            if design != nil {
                font = .system(style, design: design)
            } else {
                font = Self.textStyle(style)
            }
            if let weight { font = font.weight(weight) }
            if monospacedFamily { font = font.monospaced() }
        }
        if monospacedDigits { font = font.monospacedDigit() }
        return font
    }

    private static func textStyle(_ style: Font.TextStyle) -> Font {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        default: .body
        }
    }

    /// iOS's point size for `style` at each standard size, extra small to
    /// extra extra extra large (Apple's Dynamic Type sizes).
    static let standardPoints: [Font.TextStyle: [CGFloat]] = [
        .largeTitle: [31, 32, 33, 34, 36, 38, 40],
        .title: [25, 26, 27, 28, 30, 32, 34],
        .title2: [19, 20, 21, 22, 24, 26, 28],
        .title3: [17, 18, 19, 20, 22, 24, 26],
        .headline: [14, 15, 16, 17, 19, 21, 23],
        .body: ChatTypography.standardBodySizes,
        .callout: [13, 14, 15, 16, 18, 20, 22],
        .subheadline: [12, 13, 14, 15, 17, 19, 21],
        .footnote: [12, 12, 12, 13, 15, 17, 19],
        .caption: [11, 11, 11, 12, 14, 16, 18],
        .caption2: [11, 11, 11, 11, 13, 15, 17],
    ]

    /// `style`'s iOS size at `size`; nil at an accessibility size.
    static func points(_ style: Font.TextStyle, at size: DynamicTypeSize) -> CGFloat? {
        guard let index = ChatTypography.standardDynamicTypeSizes.firstIndex(of: size) else { return nil }
        return standardPoints[style]?[index]
    }

    /// Whether the system grows text styles with Dynamic Type: not on a
    /// Mac, which draws body text at one size for every standard size.
    static func systemGrowsTextStyles(drawn: [CGFloat] = ChatTypography.drawnBodySizes) -> Bool {
        guard let largest = drawn.last else { return true }
        return largest > drawn[ChatTypography.defaultIndex]
    }
}

extension View {
    /// `font`'s text style, or iOS's size for the stepped one in points
    /// where the system doesn't grow it (`pointSizedText`).
    func scaledFont(_ font: ScaledFont) -> some View {
        modifier(ScaledFontModifier(font: font))
    }
}

private struct ScaledFontModifier: ViewModifier {
    let font: ScaledFont
    @Environment(\.pointSizedText) private var pointSizedText

    func body(content: Content) -> some View {
        content.font(font.font(pointSizedAt: pointSizedText))
    }
}

private struct PointSizedTextEnvironmentKey: EnvironmentKey {
    static let defaultValue: DynamicTypeSize? = nil
}

extension EnvironmentValues {
    /// The Dynamic Type size a column stepped its text up to, where the
    /// system doesn't draw it (a Mac): `scaledFont` sets text styles in
    /// points at iOS's size for it. Nil everywhere else.
    var pointSizedText: DynamicTypeSize? {
        get { self[PointSizedTextEnvironmentKey.self] }
        set { self[PointSizedTextEnvironmentKey.self] = newValue }
    }
}
