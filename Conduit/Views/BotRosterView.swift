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
        }
    }

    /// `botRoster` keeps EVERY bot (sessions-list hygiene reads the full
    /// canonical registry); meta-hidden rows are hidden from THIS view only.
    private var visibleBots: [BotProfile] {
        appState.botRoster.filter { !$0.isHiddenByMeta }
    }

    private var rosterRefreshKey: String {
        "\(appState.activeDashboardID?.uuidString ?? "-")/\(appState.activeProfile)"
    }

    private var rosterList: some View {
        List {
            if case .failed(let message) = appState.botModePhase {
                Section {
                    BotModeNoticeRow(
                        icon: "exclamationmark.triangle",
                        message: message
                    )
                }
            }
            Section(AppLocalization.string("Bots")) {
                ForEach(visibleBots) { bot in
                    BotRosterRow(bot: bot)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await appState.refreshBotRoster()
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

/// One roster row. Tap resolves the canonical Bot Chat and opens it; the
/// preview/activity text comes from what `profiles.list` already supplies.
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
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
            Text(initial)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
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
        .padding(.vertical, 2)
    }
}
