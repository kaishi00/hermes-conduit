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

    /// One per place in the group (the cap is 4), dark enough for white text.
    static let palette: [Color] = [
        Color(red: 0.20, green: 0.45, blue: 0.85),
        Color(red: 0.75, green: 0.30, blue: 0.55),
        Color(red: 0.15, green: 0.55, blue: 0.40),
        Color(red: 0.80, green: 0.42, blue: 0.10),
        Color(red: 0.45, green: 0.35, blue: 0.80),
        Color(red: 0.55, green: 0.45, blue: 0.20),
    ]

    static func color(_ index: Int) -> Color {
        palette[((index % palette.count) + palette.count) % palette.count]
    }

    var body: some View {
        if let badge = appState.combinedDashboardBadge(dashboardID) {
            // Fixed size: it sits on a fixed-size picture, as the unread dot.
            Text(verbatim: badge.letter)
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Self.color(badge.colorIndex)))
                .overlay { Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1) }
                .fixedSize()
                .accessibilityLabel(Text(verbatim: badge.name))
        }
    }
}
