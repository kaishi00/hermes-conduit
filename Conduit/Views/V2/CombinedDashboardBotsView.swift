//
//  CombinedDashboardBotsView.swift
//  Conduit
//
//  All-live stage 4c: on Bots Home, after the dashboard on screen's bots and
//  in the same grid, each other combined dashboard's bots, marked with its
//  badge. A portrait only opens (through a switch to its dashboard): dragging,
//  rooms and the bot's menu are its own dashboard's, on its own Bots Home.
//

import SwiftUI

/// The other combined dashboards' bots as cells of Bots Home's own grid,
/// after the dashboard on screen's bots, in Saved Dashboards order: one set
/// of bots, each marked with its dashboard's badge (Eric, 2026-11-16).
struct CombinedDashboardBotCells: View {
    let sections: [CombinedDashboardBotsSection]

    var body: some View {
        ForEach(sections) { section in
            ForEach(section.bots) { bot in
                CombinedDashboardBotPortrait(bot: bot, section: section)
            }
        }
    }
}

/// Another combined dashboard's bot: its picture (the one saved on this
/// phone, else its initials) with the dashboard's badge, and its name.
private struct CombinedDashboardBotPortrait: View {
    @EnvironmentObject private var appState: AppState
    let bot: BotProfile
    let section: CombinedDashboardBotsSection

    var body: some View {
        Button {
            Haptics.light()
            appState.openCombinedBot(bot, in: section.dashboardID)
        } label: {
            VStack(spacing: 8) {
                ProfileAvatarView(
                    profile: bot.name,
                    displayName: bot.displayLabel,
                    url: section.avatars[bot.name],
                    size: 76
                )
                .overlay(alignment: .bottomTrailing) {
                    CombinedDashboardBadge.Mark(badge: section.badge, size: 22)
                        .offset(x: 2, y: 2)
                }
                Text(bot.displayLabel)
                    .scaledFont(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bot.displayLabel))
        .accessibilityValue(Text(verbatim: section.badge.name))
        .accessibilityHint(AppLocalization.string("Switches to that dashboard and opens the chat", table: .chat))
        .accessibilityAddTraits(.isButton)
    }
}
