//
//  CombinedDashboardBotsView.swift
//  Conduit
//
//  All-live stage 4c: on Bots Home, each other combined dashboard's bots in
//  the same grid as the dashboard on screen's, mixed in the group's one
//  order and marked with their dashboard's badge. A portrait opens (through
//  a switch to its dashboard, the portrait staying put) and moves by drag;
//  rooms and the bot's menu are its own dashboard's, on its own Bots Home.
//

import SwiftUI
import UniformTypeIdentifiers

/// Another combined dashboard's bot in Bots Home's mixed grid: its picture
/// (the one saved on this phone, else its initials) with the dashboard's
/// badge, its name with an ⓘ and its status pill, drawn like this
/// dashboard's portraits: the same size, its ring in its own dashboard's
/// color, and a moving picture plays as theirs do. It
/// moves among them by drag like they do (the group's order), but a hold
/// over a face never starts a room: rooms are each dashboard's own.
struct CombinedDashboardBotPortrait: View {
    @EnvironmentObject private var appState: AppState
    let item: CombinedBotsHomeItem
    let section: CombinedDashboardBotsSection
    /// Another portrait dropped on this one: it takes this one's place.
    let onDrop: (String) -> Void
    /// The ⓘ, and a pill other than Needs you: the switch to its
    /// dashboard, then the bot's overview there.
    let onOverview: () -> Void
    /// Its chats' waits (read through its kept connection), which its pill
    /// counts.
    @ObservedObject var needsYou: NeedsYouStore
    /// VoiceOver's way to arrange the grid, as a drag does.
    var onMoveEarlier: (() -> Void)?
    var onMoveLater: (() -> Void)?

    @Environment(\.v2Shell) private var shell
    @Environment(\.v2OpenBeside) private var openBeside
    @Environment(\.botsHomeCovered) private var covered
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var devicePower = DevicePowerState.shared
    /// 72 at the default Text Size, as this dashboard's portraits, which
    /// stop growing at accessibility1 (about 115).
    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 72
    private var portraitSize: CGFloat { min(scaledSize, 115) }

    private var bot: BotProfile { item.bot }
    private var url: URL? { section.avatars[bot.name] }

    /// Plays only while Bots Home is on screen, as this dashboard's
    /// portraits (BotPortraitCell.animates).
    private var animates: Bool {
        shell.isTabActive && !shell.isRootCovered && !covered
            && scenePhase == .active && !reduceMotion && !devicePower.isLowPowerModeEnabled
    }

    /// The picture as this phone saved it, played when it moves.
    private func face(size: CGFloat, animated: Bool) -> some View {
        BotAvatarView(
            name: bot.name,
            label: bot.displayLabel,
            colorString: bot.appearanceColor,
            image: url.flatMap { ProfileAvatarImageCache.image(at: $0) },
            size: size,
            playback: animated ? playback : nil
        )
    }

    private var playback: AnimatedAvatarPlayback? {
        guard let url, ProfileAvatarImageCache.isAnimated(at: url) else { return nil }
        return .file(url, revision: ProfileAvatarImageCache.revision(of: url))
    }

    /// What it's doing, as its own dashboard's Bots Home shows it.
    private var status: BotPortraitStatus { appState.combinedBotStatus(bot, in: section.dashboardID) }

    var body: some View {
        let status = status
        VStack(spacing: 2) {
            Button(action: open) {
                face(size: portraitSize, animated: animates)
                .padding(4)
                // Keyed apart from this dashboard's bots, which may share
                // its name; once its dashboard is on screen it is one of
                // them, keyed by name, and the chat grows out of it there.
                .modifier(BotZoomSource(name: item.id))
                .modifier(BotPortraitMotion(
                    status: status,
                    color: section.color(bot),
                    highlighted: false,
                    animates: animates,
                    finishedAt: nil
                ))
                .overlay(alignment: .bottomTrailing) {
                    CombinedDashboardBadge.Mark(badge: section.badge, size: 22)
                        .offset(x: 2, y: 2)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .modifier(BotPortraitDrag(name: item.id, enabled: true) {
                face(size: 64, animated: false)
            })
            .accessibilityLabel(Text(bot.displayLabel))
            .accessibilityValue(Text(verbatim: status == .idle ? section.badge.name : "\(section.badge.name), \(status.title)"))
            .accessibilityHint(AppLocalization.string("Switches to that dashboard and opens the chat", table: .chat))
            .accessibilityAction(named: Text(BotStatusPill.overviewTitle)) { onOverview() }
            .accessibilityActions {
                if let wait = appState.combinedBotChatWaits(bot, in: section.dashboardID).first, case .needsYou = status {
                    Button(AppLocalization.string("Needs you")) { appState.openNeedsYou(wait) }
                }
                if let onMoveEarlier {
                    Button(AppLocalization.string("Move Earlier"), action: onMoveEarlier)
                }
                if let onMoveLater {
                    Button(AppLocalization.string("Move Later"), action: onMoveLater)
                }
            }
            // The name and its ⓘ, as this dashboard's portraits have them;
            // at accessibility sizes the ⓘ goes to the status line (Eric,
            // 2026-11-16: the far bots had no ⓘ or status).
            HStack(spacing: 0) {
                Button(action: open) {
                    Text(bot.displayLabel)
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                // The portrait says it, name and all.
                .accessibilityHidden(true)
                if !typeSize.isAccessibilitySize { infoButton }
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 0) {
                statusLine(status)
                if typeSize.isAccessibilitySize { infoButton }
            }
        }
        .onDrop(of: [UTType.text], delegate: LiftedBotDrop { dragged in
            // Back on its own place: taken here and left where it was.
            guard dragged != item.id else { return true }
            onDrop(dragged)
            return true
        })
        // Its work, read through its kept connection each time Bots Home
        // shows, as this dashboard's portraits read theirs.
        .task(id: "\(section.dashboardID)\u{1F}\(bot.name)\u{1F}\(shell.isTabActive)") {
            guard shell.isTabActive else { return }
            await appState.refreshCombinedDashboardBotWork(section.dashboardID, profile: bot.name)
        }
    }

    private func open() {
        Haptics.light()
        appState.openCombinedBot(bot, in: section.dashboardID, zooms: openBeside == nil)
    }

    /// The ⓘ: the bot's overview, on its own dashboard.
    private var infoButton: some View {
        Button {
            Haptics.light()
            onOverview()
        } label: {
            Image(systemName: "info.circle")
                .scaledFont(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .fixedSize()
        .padding(.horizontal, -7)
        .help(BotStatusPill.overviewTitle)
        .accessibilityLabel(Text(BotStatusPill.overviewLabel(bot)))
    }

    /// Its pill, as this dashboard's: nothing when idle, in the same
    /// height. Needs you opens the newest wait in its chats (through the
    /// switch), anything else its overview.
    @ViewBuilder
    private func statusLine(_ status: BotPortraitStatus) -> some View {
        if status == .idle {
            Color.clear
                .frame(width: 1, height: 44)
                .accessibilityHidden(true)
        } else {
            Button {
                Haptics.light()
                if case .needsYou = status, let wait = appState.combinedBotChatWaits(bot, in: section.dashboardID).first {
                    appState.openNeedsYou(wait)
                } else {
                    onOverview()
                }
            } label: {
                BotStatusPill(status: status)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityHidden(true)
        }
    }
}
