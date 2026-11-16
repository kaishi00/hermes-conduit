//
//  CombinedDashboardBotsView.swift
//  Conduit
//
//  All-live stage 4c: on Bots Home, under the dashboard on screen's bots,
//  each other combined dashboard's bots, headed by its badge and name. A
//  portrait only opens (through a switch to its dashboard): dragging,
//  rooms and the bot's menu are its own dashboard's, on its own Bots Home.
//

import SwiftUI

struct CombinedDashboardBotsSections: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ForEach(appState.otherCombinedDashboardsBots) { section in
            HStack(alignment: .center, spacing: 8) {
                CombinedDashboardBadge.Mark(badge: section.badge, size: 18)
                    .accessibilityHidden(true)
                Text(verbatim: section.badge.name)
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .frame(minHeight: 44)
            BotPortraitGrid(bots: section.bots) { bot in
                CombinedDashboardBotPortrait(bot: bot, section: section)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
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
