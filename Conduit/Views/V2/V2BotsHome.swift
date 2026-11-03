//
//  V2BotsHome.swift
//  Conduit
//
//  Bots Home, Conduit's first tab: every bot as a portrait, three across on
//  a phone, with Pulse and Artifacts as small shortcuts under the title.
//  A portrait opens the bot's Bot Chat; the pill under its name opens its
//  Bot Overview (its chat, its work and its artifacts) and says what its
//  work is doing. Group Chats follow the bots
//  (designs/bot-mode-coordinator/bots-home-ui.md, layout A).
//

import SwiftUI

/// A named shortcut under Bots Home's title: Pulse, Artifacts.
struct V2ShortcutPill: View {
    let systemImage: String
    let title: String
    var tint: Color = .primary
    /// Something new behind it (Pulse's unseen cards).
    var dot = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            if dot {
                Circle()
                    .fill(Color.conduitAccent)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .conduitGlassControl(cornerRadius: 20, interactive: false)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Pulse and Artifacts, under Bots Home's title. Both are global: Pulse
/// isn't any one bot's, and Artifacts lists every bot's with the
/// profile's own.
struct BotsHomeShortcuts: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            if appState.showsPulseScreen {
                V2PulseButton(named: true)
            }
            NavigationLink(value: V2Route.artifacts) {
                V2ShortcutPill(systemImage: "square.grid.2x2", title: AppLocalization.string("Artifacts"))
            }
            .buttonStyle(PressableButtonStyle())
            .simultaneousGesture(TapGesture().onEnded { Haptics.selection() })
            .accessibilityLabel(AppLocalization.string("Artifacts"))
            .accessibilityIdentifier("bots.artifacts")
            Spacer(minLength: 0)
        }
    }
}

/// The bots as a grid of portraits. Three across on a phone; as many as
/// fit at about the same size on a wider column, and fewer at the largest
/// Text Sizes, where a name needs the room.
struct BotPortraitGrid<Cell: View>: View {
    let bots: [BotProfile]
    @ViewBuilder let cell: (BotProfile) -> Cell
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
            : [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 10)]
        LazyVGrid(columns: columns, alignment: .center, spacing: 22) {
            ForEach(bots) { bot in
                cell(bot)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// What a bot's Overview pill says: what needs the user first, then what's
/// working, else just "Overview". It never names the policy: that's a
/// setting, in Edit Bot.
enum BotPortraitStatus: Equatable {
    case needsYou(Int)
    case working(Int)
    case idle

    static func of(_ snapshot: BotWorkSnapshot?) -> BotPortraitStatus {
        guard let snapshot, snapshot.isOn else { return .idle }
        if snapshot.needsYouCount > 0 { return .needsYou(snapshot.needsYouCount) }
        if snapshot.workingCount > 0 { return .working(snapshot.workingCount) }
        return .idle
    }

    var title: String {
        switch self {
        case .needsYou(let count): return AppLocalization.string("\(count) needs you")
        case .working(let count): return AppLocalization.string("\(count) working")
        case .idle: return AppLocalization.string("Overview")
        }
    }

    var tint: Color {
        switch self {
        case .needsYou: return .orange
        case .working: return .conduitAccent
        case .idle: return .secondary
        }
    }

    var symbol: String? {
        switch self {
        case .needsYou: return "exclamationmark.circle.fill"
        case .working: return "arrow.triangle.2.circlepath"
        case .idle: return nil
        }
    }
}

/// One bot on Bots Home: its portrait in its own color, its name, and its
/// Overview pill. The portrait and name open the Bot Chat; the pill opens
/// the overview. A long press has the Bots list's row menu.
struct BotPortraitCell<MenuContent: View>: View {
    let bot: BotProfile
    @ObservedObject var work: BotWorkStore
    let menu: MenuContent
    let onOverview: () -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2OpenBeside) private var openBeside
    @ScaledMetric(relativeTo: .body) private var portraitSize: CGFloat = 72

    private var status: BotPortraitStatus { .of(work.snapshot(bot.name)) }

    private var color: Color { BotAvatarView.color(for: bot.appearanceColor, name: bot.name) }

    /// Beside its open Bot Chat on a split window.
    private var selection: V2RowSelection {
        .chat(isActive: appState.activeBotChatProfile == bot.name, beside: openBeside, faintAlone: false)
    }

    var body: some View {
        let status = status
        VStack(spacing: 6) {
            Button {
                Haptics.light()
                appState.dismissSidebarDrawer()
                Task { await appState.openBotChat(for: bot) }
            } label: {
                VStack(spacing: 8) {
                    portrait(status)
                    Text(bot.displayLabel)
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .contextMenu { menu }
            .accessibilityLabel(Text(bot.displayLabel))
            .accessibilityValue(Text(accessibilityValue(status)))
            .accessibilityHint(Text(AppLocalization.string("Opens this bot's chat.")))
            .v2SelectedTrait(selection)

            Button {
                Haptics.light()
                onOverview()
            } label: {
                pill(status)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text(AppLocalization.string("\(bot.displayLabel)’s overview")))
            .accessibilityValue(Text(verbatim: status == .idle ? "" : status.title))
            .accessibilityIdentifier("bots.overview.\(bot.name)")
        }
        // The pill's words: read once each time Bots Home shows or
        // connects, not polled (the Bot Chat and its overview poll).
        .task(id: "\(bot.name)\u{1F}\(appState.isConnected)\u{1F}\(appState.servesBotWorkstreams)") {
            await appState.refreshBotWork(profile: bot.name)
        }
    }

    private func portrait(_ status: BotPortraitStatus) -> some View {
        BotMonogramView(bot: bot, size: portraitSize)
            .padding(4)
            .overlay {
                Circle()
                    .strokeBorder(selection == .open ? Color.conduitAccent : color.opacity(0.85),
                                  lineWidth: selection == .open ? 3 : 2)
            }
            .shadow(color: color.opacity(0.45), radius: 14)
            .overlay(alignment: .topTrailing) {
                if case .needsYou = status {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.orange))
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
    }

    private func pill(_ status: BotPortraitStatus) -> some View {
        HStack(spacing: 4) {
            if let symbol = status.symbol {
                Image(systemName: symbol)
                    .scaledFont(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            Text(verbatim: status.title)
                .scaledFont(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 11)
        .frame(minHeight: 28)
        .background(Capsule().fill(status == .idle ? Color.primary.opacity(0.07) : status.tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(status == .idle ? Color.primary.opacity(0.10) : status.tint.opacity(0.35),
                                        lineWidth: 1))
        // A 44-point target round the smaller pill.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func accessibilityValue(_ status: BotPortraitStatus) -> String {
        let parts = [bot.isPinned ? AppLocalization.string("Pinned") : "", status == .idle ? "" : status.title]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A bot's overview: who it is, its chat a tap away, its work (the Work
/// panel's list) and what its chats produced. From Bots Home's pill, and
/// from the line under a Bot Chat's title on a phone, where Chat just
/// closes it.
struct BotOverviewSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var work: BotWorkStore
    let profile: String
    /// Edit Bot, for a bot that can be edited here; nil hides it.
    var onEdit: ((BotProfile) -> Void)?
    /// Its Bot Chat: opens it from Bots Home, closes the sheet over it.
    let onChat: () -> Void
    let onClose: () -> Void

    enum Section: Hashable {
        case work
        case artifacts
    }

    @State private var section: Section = .work

    private var bot: BotProfile? {
        appState.shownBotRoster.first { AppState.profilesMatch($0.name, profile) }
    }

    private var botName: String {
        bot?.displayLabel ?? work.snapshot(profile)?.botName ?? appState.profileDisplayName(profile)
    }

    /// Work shows where the plugin keeps a bot's work; elsewhere the
    /// overview is its chat and its artifacts.
    private var showsWork: Bool { appState.servesBotWorkstreams }

    private var shown: Section { showsWork ? section : .artifacts }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Button {
                    Haptics.light()
                    onChat()
                } label: {
                    Label(AppLocalization.string("Chat with \(botName)"), systemImage: "bubble.left.fill")
                        .scaledFont(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.conduitAccent)
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .accessibilityIdentifier("botOverview.chat")
                if showsWork {
                    Picker(AppLocalization.string("Overview"), selection: $section) {
                        Text(AppLocalization.string("Work")).tag(Section.work)
                        Text(AppLocalization.string("Artifacts")).tag(Section.artifacts)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                }
                switch shown {
                case .work:
                    BotWorkPanel(work: work, profile: profile, onClose: onClose, showsHeader: false)
                case .artifacts:
                    BotArtifactsList(profile: profile, willShowInChat: onClose)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // A workstream opened from its list shows its own chat.
        .onChange(of: appState.activeSessionId) { _, _ in onClose() }
        .accessibilityIdentifier("botOverview")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let bot {
                    BotMonogramView(bot: bot, size: 52)
                } else {
                    ProfileAvatarView(profile: profile, displayName: botName,
                                      url: appState.profileAvatarURL(for: profile), size: 52)
                        .clipShape(Circle())
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: botName)
                    .scaledFont(.title3.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if showsWork, let text = work.snapshot(profile)?.stripText {
                    Text(verbatim: text)
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let bot, let onEdit {
                Button {
                    Haptics.light()
                    onEdit(bot)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Edit Bot"))
            }
            Button {
                Haptics.light()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("Close"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}
