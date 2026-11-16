//
//  BotsHomeFew.swift
//  Conduit
//
//  Bots Home with one or two bots (Eric, 2026-11-15). The grid of small
//  portraits suits three bots or more; with one bot it left the page empty.
//  One bot gets a large portrait, a field to message it from here, its last
//  reply and its work; two get large portraits side by side, each with its
//  last reply, on the way to the grid.
//

import SwiftUI

/// How Bots Home lays its shown bots out.
enum BotsHomeLayout: Equatable {
    /// One bot: a large portrait, the Ask field, its last reply and work.
    case solo
    /// Two bots: large portraits side by side with their last replies.
    case pair
    /// Three or more: the grid of portraits.
    case grid

    /// The large portraits' face at the default Text Size.
    static let largePortrait: CGFloat = 104

    /// At accessibility Text Sizes two large faces outgrow a phone's
    /// width, so two bots take the grid's two columns instead.
    /// `othersShown`: another combined dashboard's bots join the grid, so
    /// one or two of this dashboard's give way to it too (Eric, 2026-11-16).
    static func of(visibleBots: Int, accessibilitySize: Bool, othersShown: Bool = false) -> BotsHomeLayout {
        guard !othersShown else { return .grid }
        switch visibleBots {
        case 1: return .solo
        case 2: return accessibilitySize ? .grid : .pair
        default: return .grid
        }
    }
}

/// The work a lone bot shows on Bots Home: what's open, what waits on the
/// user first, as many as `shown`; the rest is in its overview.
enum BotsHomeWork {
    static let shown = 3

    static func preview(_ snapshot: BotWorkSnapshot?) -> [BotWorkItem] {
        guard let snapshot, snapshot.isOn else { return [] }
        let open = snapshot.items.filter(\.isActive)
        return Array((open.filter(\.needsYou) + open.filter { !$0.needsYou }).prefix(shown))
    }

    /// One formatter for every label, its locale set as it's used, as the
    /// Bots list's rows keep theirs.
    private static let activityFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// When a bot's Bot Chat last moved, short and relative ("12 min.
    /// ago"); nil before it has talked. The roster sends seconds, or
    /// milliseconds from older hosts.
    static func lastActiveLabel(_ lastActive: Double?, now: Date = Date()) -> String? {
        guard let lastActive, lastActive > 0 else { return nil }
        let seconds = lastActive > 10_000_000_000 ? lastActive / 1000 : lastActive
        let formatter = activityFormatter
        formatter.locale = AppLocalization.formattingLocale
        return formatter.localizedString(for: Date(timeIntervalSince1970: seconds), relativeTo: now)
    }
}

/// A bot's last reply in its Bot Chat, read from the chat's history each
/// time Bots Home shows and whenever the chat moves on. Nothing shows until
/// there is one.
struct BotLastReply: View {
    enum Style {
        /// A card that opens the Bot Chat (one bot).
        case card
        /// Two lines under the portrait that open the Bot Chat (two bots).
        case caption
    }

    let bot: BotProfile
    let style: Style
    let onOpen: () -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    @State private var reply: String?
    /// The Bot Chat `reply` was read from: another chat's reply never shows
    /// under this one (a chat Hermes replaced, a bot renamed).
    @State private var replyChatID: String?

    /// Read again when the roster says the chat moved, and, while that chat
    /// is open beside Bots Home (a split window), as its newest
    /// reply changes, which the roster doesn't hear of until its next read.
    /// That's the newest reply row, as `read()` takes it, not the newest
    /// row (a tool step or a steer can follow it), and a finished reply can
    /// replace its row's text under the same id, so the text counts too
    /// (streamed tokens don't touch `messages`).
    private var readKey: String {
        let chat = bot.canonicalSession
        let openTail = appState.activeBotChatProfile == bot.name ? Self.replyKey(appState.messages) : ""
        return [bot.name, chat?.id ?? "", String(chat?.lastActive ?? 0), openTail,
                String(appState.isConnected), String(shell.isTabActive)].joined(separator: "\u{1F}")
    }

    /// The open chat's newest reply as the re-read follows it: the row
    /// voice takes as its last reply (`AppState.latestReplyMessage`), so a
    /// tool step, a steer or an empty reply row after it changes nothing,
    /// and its text replaced under the same id does.
    static func replyKey(_ messages: [ChatMessage]) -> String {
        AppState.latestReplyMessage(in: messages).map { "\($0.id)\u{1E}\($0.content.hashValue)" } ?? ""
    }

    private var when: String? {
        BotsHomeWork.lastActiveLabel(bot.canonicalSession?.lastActive ?? bot.lastActive)
    }

    var body: some View {
        Group {
            if let reply {
                switch style {
                case .card: card(reply)
                case .caption: caption(reply)
                }
            }
        }
        .task(id: readKey) { await read() }
    }

    private func card(_ reply: String) -> some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if let when {
                    Text(verbatim: when)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: reply)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .settingsCard(cornerRadius: 18)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint(Text(AppLocalization.string("Opens this bot's chat.", table: .bots)))
    }

    private func caption(_ reply: String) -> some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            captionText(reply)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint(Text(AppLocalization.string("Opens this bot's chat.", table: .bots)))
    }

    private func captionText(_ reply: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: reply)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let when {
                Text(verbatim: when)
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    /// The newest assistant reply in the bot's Bot Chat, as a call's "what
    /// did it say" reads it: from the open chat when it's on screen, else
    /// the chat's saved history in the bot's own profile.
    private func read() async {
        guard let chat = bot.canonicalSession else {
            reply = nil
            return
        }
        if replyChatID != chat.id {
            reply = nil
            replyChatID = chat.id
        }
        guard shell.isTabActive, appState.isConnected else { return }
        let target = VoiceThreadTarget(
            runtimeSessionID: chat.resolvedID ?? chat.id,
            storedSessionID: chat.id,
            title: BotMode.canonicalChatTitle,
            profile: appState.profilesMatch(bot.name, appState.activeProfile) ? nil : bot.name
        )
        guard let latest = await appState.latestLiveVoiceThreadReplyMessage(target), !Task.isCancelled else { return }
        let plain = PreviewText.plain(latest.message.content)
        reply = plain.isEmpty ? nil : plain
    }
}

/// Bots Home's field for a lone bot: what's typed goes to its Bot Chat,
/// which opens as a portrait's tap opens it, and is sent there.
struct BotsHomeAskField: View {
    let bot: BotProfile
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2OpenBeside) private var openBeside
    @Environment(\.colorScheme) private var colorScheme
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private var words: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !words.isEmpty && !sending && appState.isConnected }

    /// The composer's own solid body and hairline, so the field reads as
    /// the place to type, as it does in a chat.
    private var foundation: Color {
        colorScheme == .dark ? Color(red: 0.072, green: 0.080, blue: 0.106) : Color.white
    }

    private var stroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.09)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField(AppLocalization.string("Message \(bot.displayLabel)…"), text: $text, axis: .vertical)
                .scaledFont(.callout)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.vertical, 13)
                .padding(.leading, 18)
                .accessibilityIdentifier("bots.home.ask")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(canSend ? Color.conduitAccent : Color.secondary.opacity(0.35)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Text(AppLocalization.string("Send")))
            .padding(.trailing, 4)
            .padding(.bottom, 2)
        }
        .background(foundation, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
        }
        // Return makes a new line in this field and the keyboard covers
        // the tab bar, so Done puts it away; a scroll of Bots Home does too.
        // Only while this field has focus: the new room's name field keeps
        // Return as its Done.
        .keyboardDoneButton(identifier: "bots.home.ask.done", isActive: focused) { focused = false }
    }

    private func send() {
        let message = words
        guard canSend else { return }
        Haptics.light()
        sending = true
        focused = false
        appState.askBotFromHome(bot, text: message, zooms: openBeside == nil) { handed in
            sending = false
            // Still here when the chat didn't open, to send again.
            if handed { text = "" }
        }
    }
}

/// A lone bot's open work on Bots Home, as short rows; a row, or Show All,
/// opens its overview, where the work is answered and managed.
struct BotsHomeWorkSection: View {
    let bot: BotProfile
    @ObservedObject var work: BotWorkStore
    let onOverview: () -> Void
    @EnvironmentObject private var appState: AppState

    private var botName: String {
        work.snapshot(bot.name)?.botName ?? bot.displayLabel
    }

    var body: some View {
        let items = appState.servesBotWorkstreams ? BotsHomeWork.preview(work.snapshot(bot.name)) : []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center) {
                    Text(AppLocalization.string("Work"))
                        .scaledFont(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button {
                        Haptics.light()
                        onOverview()
                    } label: {
                        Text(AppLocalization.string("Show All"))
                            .scaledFont(.footnote.weight(.semibold))
                            .foregroundStyle(Color.conduitAccent)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().padding(.leading, 56)
                        }
                        Button {
                            Haptics.light()
                            onOverview()
                        } label: {
                            row(item)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityHint(Text(AppLocalization.string("Shows this bot's work", table: .bots)))
                    }
                }
                .settingsCard(cornerRadius: 18)
            }
        }
    }

    private func row(_ item: BotWorkItem) -> some View {
        HStack(spacing: 12) {
            BotWorkMark(item: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.shownTitle)
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(BotWorkLook.subtitle(item, botName: botName))
                    .scaledFont(.footnote)
                    .foregroundStyle(item.needsYou ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(item.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .scaledFont(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
