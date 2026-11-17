//
//  CombinedDashboardBotsView.swift
//  Conduit
//
//  All-live stage 4c: on Bots Home, each other combined dashboard's bots in
//  the same grid as the dashboard on screen's, mixed in the group's one
//  order and marked with their dashboard's badge. A portrait opens (through
//  a switch to its dashboard, the portrait staying put) and moves by drag;
//  held over another's face, or another held over its, it starts a room
//  that brings it from its own Hermes. The bot's menu is its own
//  dashboard's, on its own Bots Home.
//

import SwiftUI
import UniformTypeIdentifiers

/// Another combined dashboard's bot in Bots Home's mixed grid: its picture
/// (the one saved on this phone, else its starter face) with the dashboard's
/// badge, its name with an ⓘ and its status pill, drawn like this
/// dashboard's portraits: the same size, its ring in its own dashboard's
/// color, and a moving picture plays as theirs do. It
/// moves among them by drag like they do (the group's order), and a hold
/// over its face starts a room, as over theirs: a draft here that brings it
/// from its own Hermes over an own Link (Eric, 2026-11-16).
struct CombinedDashboardBotPortrait: View {
    @EnvironmentObject private var appState: AppState
    let item: CombinedBotsHomeItem
    let section: CombinedDashboardBotsSection
    /// Another portrait dropped on this one: held still over its face
    /// (`merge`), the two start a room; else it takes this one's place.
    let onDrop: (String, Bool) -> Void
    /// Whether the bot in hand, held over this face, starts a room with it.
    let canMerge: (String) -> Bool
    /// The room being started on Bots Home: this bot in it, or not.
    let room: BotPortraitRoom
    /// A tap while a room is being started: in or out of it.
    let onToggleRoom: () -> Void
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
    /// A bot in hand over this one, and held still over its face long
    /// enough to start a room (BotDragPayload.mergeDwell), as this
    /// dashboard's portraits.
    @State private var isTargeted = false
    @State private var mergeReady = false
    @State private var mergeReadyEndedAt: Date?
    @State private var dwell: Task<Void, Never>?
    @State private var dwellAnchor: CGPoint?
    @State private var faceFrame: CGRect = .zero
    @State private var cellInWindow: CGRect = .zero

    private var bot: BotProfile { item.bot }
    /// Its kept connection, so a new one reads its work again.
    private var keptAt: TimeInterval {
        appState.keptDashboardRuntimes[section.dashboardID]?.keptAt.timeIntervalSinceReferenceDate ?? 0
    }
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
            colorString: bot.shownColor,
            image: url.flatMap { ProfileAvatarImageCache.image(at: $0) },
            size: size,
            playback: animated ? playback : nil,
            face: bot.faceLook
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
                // Where a merge's hold counts (BotDragPayload.mergeZone).
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BotPortraitCellSpace.name)) } action: { faceFrame = $0 }
                .padding(4)
                // Keyed apart from this dashboard's bots, which may share
                // its name; once its dashboard is on screen it is one of
                // them, keyed by name, and the chat grows out of it there.
                .modifier(BotZoomSource(name: item.id))
                .modifier(BotPortraitMotion(
                    status: status,
                    color: mergeReady ? Color.conduitAccent : section.color(bot),
                    highlighted: mergeReady || room == .member,
                    animates: animates,
                    finishedAt: nil
                ))
                .scaleEffect(mergeReady ? 1.1 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if mergeReady || room == .member {
                        Image(systemName: mergeReady ? "plus" : "checkmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.black)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.conduitAccent))
                            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                            .offset(x: 2, y: 2)
                            .accessibilityHidden(true)
                    } else {
                        CombinedDashboardBadge.Mark(badge: section.badge, size: 22)
                            .offset(x: 2, y: 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .modifier(BotPortraitDrag(name: item.id, enabled: true) {
                face(size: 64, animated: false)
            })
            .accessibilityLabel(Text(bot.displayLabel))
            .accessibilityValue(Text(verbatim: [section.badge.name, room.valuePart ?? "", status == .idle ? "" : status.title]
                .filter { !$0.isEmpty }.joined(separator: ", ")))
            // While a room is being started, its tap puts it in or takes it
            // out, as this dashboard's portraits say.
            .accessibilityHint(room.hint ?? AppLocalization.string("Switches to that dashboard and opens the chat", table: .chat))
            .accessibilityAction(named: Text(BotStatusPill.overviewTitle)) { onOverview() }
            .accessibilityActions {
                if case .needsYou = status, let wait = appState.combinedBotChatWaitThePillOpens(bot, in: section.dashboardID) {
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
        .coordinateSpace(name: BotPortraitCellSpace.name)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cellInWindow = $0 }
        .onDrop(of: [UTType.text], delegate: LiftedBotDrop(
            entered: beginTargeting,
            exited: endTargeting,
            updated: hover(at:)
        ) { dragged in
            // Back on its own place: taken here and left where it was.
            guard dragged != item.id else { return true }
            let merge = BotDragPayload.dropMerges(mergeReady: mergeReady, endedAt: mergeReadyEndedAt)
            endTargeting()
            mergeReadyEndedAt = nil
            onDrop(dragged, merge)
            return true
        })
        // Its work, read through its kept connection each time Bots Home
        // shows, as this dashboard's portraits read theirs.
        // A reconnect while Bots Home stays up reads it again too.
        .task(id: "\(section.dashboardID)\u{1F}\(bot.name)\u{1F}\(shell.isTabActive)\u{1F}\(keptAt)") {
            guard shell.isTabActive else { return }
            await appState.refreshCombinedDashboardBotWork(section.dashboardID, profile: bot.name)
        }
    }

    private func open() {
        Haptics.light()
        // While a room is being started, a tap puts it in or takes it out.
        if room != .off {
            onToggleRoom()
            return
        }
        appState.openCombinedBot(bot, in: section.dashboardID, zooms: openBeside == nil)
    }

    private func beginTargeting() {
        guard let lifted = BotDragPayload.lifted, lifted != item.id else { return }
        isTargeted = true
        mergeReady = false
        mergeReadyEndedAt = nil
        dwell?.cancel()
        dwellAnchor = nil
    }

    /// Held still over the face for `mergeDwell`, it swells for a room;
    /// carried on, or off the face, it lets go and a drop moves it.
    private func hover(at reported: CGPoint) {
        guard isTargeted, let lifted = BotDragPayload.lifted else { return }
        let location = BotDragPayload.cellPoint(reported, cellInWindow: cellInWindow)
        guard canMerge(lifted), BotDragPayload.mergeZone(face: faceFrame).contains(location) else {
            dwell?.cancel()
            dwell = nil
            dwellAnchor = nil
            if mergeReady {
                mergeReadyEndedAt = nil
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { mergeReady = false }
            }
            return
        }
        if let anchor = dwellAnchor, BotDragPayload.staysStill(location, from: anchor) { return }
        if mergeReady {
            mergeReadyEndedAt = nil
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { mergeReady = false }
        }
        dwellAnchor = location
        dwell?.cancel()
        dwell = Task { @MainActor in
            try? await Task.sleep(for: BotDragPayload.mergeDwell)
            guard !Task.isCancelled, isTargeted, BotDragPayload.lifted == lifted else { return }
            Haptics.medium()
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { mergeReady = true }
        }
    }

    private func endTargeting() {
        if mergeReady { mergeReadyEndedAt = Date() }
        dwell?.cancel()
        dwell = nil
        dwellAnchor = nil
        isTargeted = false
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { mergeReady = false }
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
                if case .needsYou = status, let wait = appState.combinedBotChatWaitThePillOpens(bot, in: section.dashboardID) {
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
