import SwiftUI

/// The read-only Bots roster. Every row is a Hermes profile; selecting one
/// resolves (or, only when genuinely missing, creates) the profile's ONE
/// canonical hidden "Bot Chat" and opens it through the ordinary chat stack.
/// Profile CRUD, groups, and presence are deliberately out of Phase 1 scope.
struct BotRosterView: View {
    @EnvironmentObject private var appState: AppState
    /// Language changes must re-render localized strings immediately while
    /// the Bots tab stays selected (same contract as SessionList/CronList).
    @ObservedObject private var appLanguage = AppLanguageStore.shared

    var body: some View {
        Group {
            if visibleBots.isEmpty {
                emptyState
            } else {
                rosterList
            }
        }
        .task(id: rosterRefreshKey) {
            await appState.refreshBotRoster()
            await appState.refreshGroupChatSupport()
        }
    }

    /// `botRoster` keeps EVERY bot (sessions-list hygiene reads the full
    /// canonical registry); meta-hidden rows are hidden from THIS view only.
    private var visibleBots: [BotProfile] {
        appState.botRoster.filter { !$0.isHiddenByMeta }
    }

    /// `profiles.list` is gateway-wide and deliberately sent UNSCOPED: the
    /// roster is fenced by server identity (epoch) and dashboard, never by
    /// the selected dashboard profile. Keying on `activeProfile` made every
    /// profile switch cancel the in-flight refresh and re-fire a
    /// replacement that could only race the single-flight claim.
    private var rosterRefreshKey: String {
        appState.activeDashboardID?.uuidString ?? "-"
    }

    private var rosterList: some View {
        List {
            if case .failed(let message) = appState.botModePhase {
                Section {
                    BotModeNoticeRow(
                        icon: "exclamationmark.triangle",
                        message: message
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .conduitGlassSurface(cornerRadius: 18, tint: .yellow.opacity(0.10))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                }
            }
            Section(AppLocalization.string("Bots")) {
                ForEach(visibleBots) { bot in
                    BotRosterRow(bot: bot)
                }
            }
            groupSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await appState.refreshBotRoster()
            await appState.refreshGroupChatSupport()
        }
        .sheet(isPresented: $showingGroupCreateSheet) {
            GroupCreateSheet()
        }
    }

    /// Hosted Group Chat rows, below the Bots section. Presented only when
    /// the gateway advertised the foundation `groups.*` methods; an
    /// unsupported gateway hides the section entirely (graceful degradation,
    /// never a dead control).
    @State private var showingGroupCreateSheet = false

    @ViewBuilder
    private var groupSection: some View {
        if appState.groupChatPhase == .available {
            Section {
                ForEach(appState.groupRooms) { room in
                    GroupRosterRow(room: room)
                }
                if visibleBots.count >= 2 {
                    Button {
                        Haptics.light()
                        showingGroupCreateSheet = true
                    } label: {
                        Label(
                            AppLocalization.string("New Group Chat"),
                            systemImage: "plus.circle.fill"
                        )
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.conduitAccent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(AppLocalization.string("New Group Chat")))
                }
            } header: {
                Text(AppLocalization.string("Group Chats"))
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch appState.botModePhase {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 140)
        case .loading:
            ProgressView(AppLocalization.string("Loading bots…"))
                .frame(maxWidth: .infinity, minHeight: 140)
        case .gatewayUnsupported:
            ContentUnavailableView {
                Label(
                    AppLocalization.string("Bot Mode requires a newer Hermes gateway."),
                    systemImage: "arrow.triangle.2.circlepath.trianglebadge.exclamationmark"
                )
            } description: {
                Text(AppLocalization.string("Update the gateway, then come back to chat with your bots."))
            } actions: {
                Button(AppLocalization.string("Retry")) {
                    Task { await appState.refreshBotRoster() }
                }
            }
        case .failed(let message):
            if appState.botRoster.isEmpty {
                ContentUnavailableView {
                    Label(
                        AppLocalization.string("Could not load bots."),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(message)
                } actions: {
                    Button(AppLocalization.string("Retry")) {
                        Task { await appState.refreshBotRoster() }
                    }
                }
            } else {
                // Everything loaded earlier is meta-hidden: the user can't
                // see any bot, but the refresh failure must still surface —
                // it may be transient (or a bot was un-hidden server-side).
                ContentUnavailableView {
                    Label(
                        AppLocalization.string("Could not refresh bots."),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(message)
                } actions: {
                    Button(AppLocalization.string("Retry")) {
                        Task { await appState.refreshBotRoster() }
                    }
                }
            }
        case .available:
            ContentUnavailableView {
                Label(
                    AppLocalization.string("No Bots Yet"),
                    systemImage: "person.2"
                )
            } description: {
                Text(AppLocalization.string("Bots you create with Hermes appear here."))
            } actions: {
                Button(AppLocalization.string("Retry")) {
                    Task { await appState.refreshBotRoster() }
                }
            }
        }
    }
}

/// One hosted-room row: name, member count, and the latest chat-message
/// preview. Identity is the durable `room_id` (never the display name — a
/// same-name recreate is a genuinely fresh room upstream).
struct GroupRosterRow: View {
    let room: GroupRoom
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            Task { await appState.openGroupRoom(room) }
        } label: {
            rowCard
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
        .accessibilityLabel(Text(room.name))
        .accessibilityHint(Text(AppLocalization.string("Opens this group chat.")))
    }

    private var rowCard: some View {
        HStack(spacing: 12) {
            roomGlyph
            VStack(alignment: .leading, spacing: 3) {
                Text(room.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(cardBackground)
        .overlay(cardBorder)
        .contentShape(Rectangle())
    }

    private var roomGlyph: some View {
        ZStack {
            Circle()
                .fill(Color.conduitAccent.opacity(0.16))
            Image(systemName: "person.3")
                .font(.caption)
                .foregroundStyle(.conduitAccent)
        }
        .frame(width: 36, height: 36)
    }

    private var cardBackground: some View {
        Color.primary.opacity(0.045)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
    }

    private var subtitleText: String {
        // `groups.list` rooms carry no log preview (the log is the room's
        // own replay surface); the member count is the row's metadata until
        // the next parity slice adds activity previews.
        AppLocalization.string("\(room.members.count) members")
    }
}

/// One roster row. Tap resolves the canonical Bot Chat and opens it; the
/// preview/activity text comes from what `profiles.list` already supplies.
///
/// Rows carry their own rounded card, the same treatment `SessionRow` and
/// `CronJobRow` give the sibling sidebar tabs: a plain-styled `List` with the
/// system row chrome cleared would otherwise render the roster as one
/// sharp-edged slab that ignores the rounded glass surfaces above it.
private struct BotRosterRow: View {
    let bot: BotProfile
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            Task { await appState.openBotChat(for: bot) }
        } label: {
            HStack(spacing: 12) {
                BotMonogramView(bot: bot)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bot.displayLabel)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    subtitleText
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if bot.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
        .accessibilityLabel(Text(bot.displayLabel))
        .accessibilityHint(Text(AppLocalization.string("Opens this bot's chat.")))
    }

    @ViewBuilder
    private var subtitleText: some View {
        let detail = bot.profileDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = bot.canonicalSession?.preview
            ?? bot.lastPreview?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preview.isEmpty {
            Text(preview)
        } else if !detail.isEmpty {
            Text(detail)
        } else {
            // The canonical chat's literal title — a wire identity, never
            // localized.
            Text(BotMode.canonicalChatTitle)
        }
    }
}

/// Static appearance: the profile's configured color when present, else a
/// deterministic hue derived from the profile name (upstream's fallback).
/// Animated/complex avatars are out of Phase 1 scope.
struct BotMonogramView: View {
    let bot: BotProfile
    /// Scales with Dynamic Type so the glyph never clips at accessibility
    /// sizes (a fixed 36x36 frame clipped the letter once `.body` grew).
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
            Text(initial)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(width: avatarSize, height: avatarSize)
    }

    private var initial: String {
        String(bot.displayLabel.prefix(1)).uppercased()
    }

    private var color: Color {
        if let name = bot.appearanceColor, let resolved = botColor(named: name) {
            return resolved
        }
        // Deterministic across launches (Swift's hashValue is per-process
        // salted, so a stable FNV-1a stands in for the name-derived hue).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bot.name.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Color(hue: Double(hash % 360) / 360.0,
                     saturation: 0.45,
                     brightness: 0.6)
    }
}

/// Decodes the small set of named colors Bot Mode's appearance metadata uses.
private func botColor(named name: String) -> Color? {
    switch name.lowercased() {
    case "blue": return .blue
    case "brown": return .brown
    case "cyan": return .cyan
    case "green": return .green
    case "indigo": return .indigo
    case "mint": return .mint
    case "orange": return .orange
    case "pink": return .pink
    case "purple": return .purple
    case "red": return .red
    case "teal": return .teal
    case "yellow": return .yellow
    default: return nil
    }
}

/// A single non-blocking notice row shown above the roster after a refresh
/// failure while a previous roster is still displayed.
private struct BotModeNoticeRow: View {
    let icon: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
