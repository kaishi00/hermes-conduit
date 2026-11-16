//
//  CombinedDashboardBadge.swift
//  Conduit
//
//  A combined dashboard's badge (all-live stage 4, Eric 2026-11-15: "First
//  letter on a color"): marks a row of the combined lists that belongs to
//  another dashboard than the one on screen. Only the group has badges.
//

import SwiftUI

struct CombinedDashboardBadge: View {
    @EnvironmentObject private var appState: AppState
    let dashboardID: UUID
    var size: CGFloat = 16

    /// One per place in the group, dark enough for white text.
    static let palette: [Color] = [
        Color(red: 0.20, green: 0.45, blue: 0.85),
        Color(red: 0.75, green: 0.30, blue: 0.55),
        Color(red: 0.15, green: 0.55, blue: 0.40),
        Color(red: 0.80, green: 0.42, blue: 0.10),
        Color(red: 0.45, green: 0.35, blue: 0.80),
        Color(red: 0.55, green: 0.45, blue: 0.20),
    ]

    /// The palette's hues, which a color past it keeps clear of.
    static let paletteHues: [Double] = [0.603, 0.907, 0.438, 0.076, 0.704, 0.119]

    /// Past the palette (a group of seven or more), a hue of its own: the
    /// middle of the widest gap left between the palette's hues and the
    /// ones before it. Yellows and greens, light by nature, are
    /// darkened, so white text reads on each.
    static func color(_ index: Int) -> Color {
        guard index >= palette.count else { return palette[max(index, 0)] }
        let hue = generatedHue(index)
        let light = hue > 0.10 && hue < 0.45
        return Color(hue: hue, saturation: 0.70, brightness: light ? 0.48 : 0.62)
    }

    /// The hue for a place past the palette: the middle of the widest gap
    /// between the palette's hues and the places past it before this one.
    static func generatedHue(_ index: Int) -> Double {
        var taken = paletteHues
        var hue = 0.0
        for _ in palette.count...max(index, palette.count) {
            let sorted = taken.sorted()
            var best = (gap: 0.0, middle: 0.0)
            for (at, start) in sorted.enumerated() {
                let end = at + 1 < sorted.count ? sorted[at + 1] : sorted[0] + 1
                if end - start > best.gap {
                    best = (end - start, (start + (end - start) / 2).truncatingRemainder(dividingBy: 1))
                }
            }
            hue = best.middle
            taken.append(hue)
        }
        return hue
    }

    var body: some View {
        if let badge = appState.combinedDashboardBadge(dashboardID) {
            Mark(badge: V2DashboardBadge(letter: badge.letter, colorIndex: badge.colorIndex, name: badge.name), size: size)
        }
    }

    /// The circle itself, for a row that already knows its badge.
    struct Mark: View {
        let badge: V2DashboardBadge
        var size: CGFloat = 16

        var body: some View {
            // Fixed size: it sits on a fixed-size picture, as the unread dot.
            Text(verbatim: badge.letter)
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: size, height: size)
                .background(Circle().fill(CombinedDashboardBadge.color(badge.colorIndex)))
                .overlay { Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1) }
                .fixedSize()
                .accessibilityLabel(Text(verbatim: badge.name))
        }
    }
}
