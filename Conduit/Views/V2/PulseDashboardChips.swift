//
//  PulseDashboardChips.swift
//  Conduit
//
//  All-live stage 4d (Eric, 2026-11-15: "Chip per instance on top"): on
//  top of Pulse, a chip per combined dashboard, its badge and name and how
//  many of its cards are new. The chip of the Pulse shown is selected;
//  another's shows that dashboard's Pulse in place, through its kept
//  connection, with no switch (no-switch stage 2). Only the group has them.
//

import SwiftUI

struct PulseDashboardChips: View {
    /// The Pulse page's held updates (`V2PulsePageHost`): hidden, it
    /// doesn't redraw on AppState's publishes (audit 1722).
    @EnvironmentObject private var updates: V2ShownUpdates
    private var appState: AppState { updates.appState }

    var body: some View {
        let chips = appState.pulseDashboardChips
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips) { chip in
                        PulseDashboardChipButton(chip: chip)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }
}

private struct PulseDashboardChipButton: View {
    /// The Pulse page's held updates (`V2PulsePageHost`): hidden, it
    /// doesn't redraw on AppState's publishes (audit 1722).
    @EnvironmentObject private var updates: V2ShownUpdates
    private var appState: AppState { updates.appState }
    let chip: PulseDashboardChip

    /// How many of its cards are new, as the page's own line says it.
    private var newCards: String {
        let count: Int = chip.unseen
        return count > 0 ? AppLocalization.string("\(count) new since you last looked", table: .pulse) : ""
    }

    var body: some View {
        Button {
            guard !chip.isShown else { return }
            Haptics.selection()
            appState.openCombinedPulse(chip.dashboardID)
        } label: {
            HStack(spacing: 6) {
                CombinedDashboardBadge.Mark(badge: chip.badge, size: 18)
                Text(verbatim: chip.badge.name)
                    .scaledFont(.footnote.weight(chip.isShown ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if chip.unseen > 0 {
                    Text(verbatim: String(chip.unseen))
                        .scaledFont(.caption2.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.conduitAccent))
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(chip.isShown ? Color.conduitAccent.opacity(0.18) : Color.secondary.opacity(0.10))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.listRowCap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: chip.badge.name))
        .accessibilityValue(newCards)
        .accessibilityHint(chip.isShown ? "" : chip.switches
            ? AppLocalization.string("Switches to that dashboard and shows its Pulse", table: .pulse)
            : AppLocalization.string("Shows that dashboard's Pulse, without switching", table: .pulse))
        .accessibilityAddTraits(chip.isShown ? [.isButton, .isSelected] : .isButton)
    }
}
