//
//  CustomAccentColor.swift
//  Conduit
//
//  An accent colour of the user's own (Settings > Appearance), next to the
//  presets. Shared with the Watch app, which draws the iPhone's pick.
//
//  The pick is only a starting point: each shade Conduit draws keeps the
//  pick's hue and saturation and moves its lightness just far enough to
//  stay readable (WCAG AA, 4.5:1), as the presets are (AccentContrastTests).
//  A pick that already reads well is drawn as picked.
//

import Foundation

struct CustomAccentColor: Hashable, Sendable {
    /// The pick in 8-bit sRGB: what's stored, synced and compared.
    let red: Int
    let green: Int
    let blue: Int

    /// The dark-mode accent: text and tint on the dark backdrop, lightened
    /// until it reads there.
    let darkShade: RGB
    /// The light-mode accent, and the fill of sent bubbles in both modes:
    /// darkened until it reads on the light backdrop, which also gives
    /// white bubble text its 4.5:1.
    let lightShade: RGB

    /// An sRGB colour, components 0...1.
    struct RGB: Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
    }

    /// The pick from components 0...1, rounded to what's stored.
    init(red: Double, green: Double, blue: Double) {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        self.init(bytes: byte(red), byte(green), byte(blue))
    }

    /// "#RRGGBB", as stored under the accent's key in place of a preset's
    /// name. Anything else is nil.
    init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(bytes: Int(value >> 16) & 0xFF, Int(value >> 8) & 0xFF, Int(value) & 0xFF)
    }

    /// The shades are worked out once here: the dynamic accent colours
    /// read them on every resolution.
    private init(bytes red: Int, _ green: Int, _ blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
        let picked = RGB(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        darkShade = Self.adjusted(picked, lighter: true) {
            Self.contrast($0, Self.darkBackdrop) >= Self.minimumContrast
        }
        lightShade = Self.adjusted(picked, lighter: false) {
            Self.contrast($0, Self.lightBackdrop) >= Self.minimumContrast
                && Self.contrast($0, Self.white) >= Self.minimumContrast
        }
    }

    /// Picks compare by what's stored; the shades follow from it.
    static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.red, lhs.green, lhs.blue) == (rhs.red, rhs.green, rhs.blue)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(red)
        hasher.combine(green)
        hasher.combine(blue)
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    var picked: RGB { RGB(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255) }

    // MARK: Shades

    /// `ConduitBackdrop.base` in dark mode, the Watch's backdrop too.
    static let darkBackdrop = RGB(red: 0.045, green: 0.052, blue: 0.072)
    /// `ConduitBackdrop.base` in light mode. White surfaces are lighter, so
    /// a shade readable here is readable there.
    static let lightBackdrop = RGB(red: 0.94, green: 0.95, blue: 0.98)
    static let white = RGB(red: 1, green: 1, blue: 1)
    static let minimumContrast = 4.5

    /// The lighter companion shades (`conduitAccentSoft`), as the presets
    /// have: a step towards white.
    var softDarkShade: RGB { Self.mix(darkShade, towardsWhite: 0.35) }
    var softLightShade: RGB { Self.mix(lightShade, towardsWhite: 0.2) }

    // MARK: Colour maths

    /// WCAG relative luminance.
    static func luminance(_ color: RGB) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// WCAG 2.1 contrast ratio.
    static func contrast(_ lhs: RGB, _ rhs: RGB) -> Double {
        let first = luminance(lhs)
        let second = luminance(rhs)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// `color` with its HSL lightness stepped up or down until `reads`
    /// holds. White reads on the dark backdrop and black on the light one,
    /// so the walk always ends.
    static func adjusted(_ color: RGB, lighter: Bool, until reads: (RGB) -> Bool) -> RGB {
        if reads(color) { return color }
        var (hue, saturation, lightness) = hsl(color)
        let step = lighter ? 0.005 : -0.005
        while true {
            let next = min(max(lightness + step, 0), 1)
            let candidate = rgb(hue: hue, saturation: saturation, lightness: next)
            if reads(candidate) || next == lightness { return candidate }
            lightness = next
        }
    }

    static func mix(_ color: RGB, towardsWhite amount: Double) -> RGB {
        RGB(
            red: color.red + (1 - color.red) * amount,
            green: color.green + (1 - color.green) * amount,
            blue: color.blue + (1 - color.blue) * amount
        )
    }

    static func hsl(_ color: RGB) -> (hue: Double, saturation: Double, lightness: Double) {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let lightness = (high + low) / 2
        let delta = high - low
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch high {
        case color.red: hue = (color.green - color.blue) / delta
        case color.green: hue = (color.blue - color.red) / delta + 2
        default: hue = (color.red - color.green) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, min(saturation, 1), lightness)
    }

    static func rgb(hue: Double, saturation: Double, lightness: Double) -> RGB {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double)
        switch sector {
        case ..<1: (red, green, blue) = (chroma, second, 0)
        case ..<2: (red, green, blue) = (second, chroma, 0)
        case ..<3: (red, green, blue) = (0, chroma, second)
        case ..<4: (red, green, blue) = (0, second, chroma)
        case ..<5: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        let offset = lightness - chroma / 2
        return RGB(
            red: min(max(red + offset, 0), 1),
            green: min(max(green + offset, 0), 1),
            blue: min(max(blue + offset, 0), 1)
        )
    }
}
