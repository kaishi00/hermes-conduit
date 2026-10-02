import SwiftUI

/// The Bots roster. Every row is a Hermes profile; selecting one resolves
/// (or, only when genuinely missing, creates) the profile's ONE canonical
/// hidden "Bot Chat" and opens it through the ordinary chat stack. Bots are
/// created, edited (look, picture, description, personality), pinned and
/// deleted here, through the same gateway records Hermes Desktop uses.
struct BotRosterView: View {
    @EnvironmentObject private var appState: AppState
    /// Language changes must re-render localized strings immediately while
    /// the Bots tab stays selected (same contract as SessionList/CronList).
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var presentedDesktopGroup: DesktopGroupChat?
    @State private var editorMode: BotEditorSheet.Mode?
    @State private var pendingDelete: BotProfile?
    /// Outcome of the last management action that needs explaining (a
    /// failed delete, a save whose picture did not land).
    @State private var managementNotice: String?

    var body: some View {
        Group {
            // Group rows keep the list up even with no visible bot: a room
            // whose bots are all meta-hidden must stay reachable, and so
            // must the group probe's failure notice.
            if visibleBots.isEmpty && !hasGroupRows && groupProbeFailure == nil {
                emptyState
            } else {
                rosterList
            }
        }
        .sheet(item: $presentedDesktopGroup) { group in
            DesktopGroupChatView(group: group)
        }
        .sheet(item: $editorMode) { mode in
            BotEditorSheet(mode: mode) { createdName, warning in
                managementNotice = warning
                guard let createdName,
                      let bot = appState.botRoster.first(where: { $0.name == createdName }) else { return }
                // Desktop opens a new bot's forever chat straight away.
                appState.dismissSidebarDrawer()
                Task { await appState.openBotChat(for: bot) }
            }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { bot in
            Button(AppLocalization.string("Delete Bot"), role: .destructive) {
                Task {
                    let error = await appState.deleteBot(bot)
                    if error == nil { Haptics.success() } else { Haptics.warning() }
                    managementNotice = error
                }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(AppLocalization.string("This permanently removes the bot's profile, chats, memory and skills from the gateway."))
        }
        .task(id: rosterRefreshKey) {
            await appState.refreshBotRoster()
            await appState.refreshGroupChatSupport()
        }
    }

    private var deleteDialogTitle: String {
        guard let bot = pendingDelete else { return "" }
        return AppLocalization.string("Delete \(bot.displayLabel)?")
    }

    private var canManageBots: Bool {
        appState.botModePhase == .available && appState.isConnected
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
    /// Connection is part of the key: sign-out tears the group state down,
    /// and a same-dashboard sign-in must probe it again.
    private var rosterRefreshKey: String {
        "\(appState.activeDashboardID?.uuidString ?? "-")|\(appState.isConnected)"
    }

    private var hostedGroupsAvailable: Bool {
        appState.groupChatPhase == .available
    }

    private var hasGroupRows: Bool {
        (hostedGroupsAvailable && !appState.groupRooms.isEmpty)
            || !appState.desktopGroupChats.isEmpty
    }

    private var groupProbeFailure: String? {
        if case .failed(let message) = appState.groupChatPhase { return message }
        return nil
    }

    private var rosterList: some View {
        List {
            if let notice = managementNotice {
                Section {
                    HStack(alignment: .top) {
                        BotModeNoticeRow(icon: "exclamationmark.circle", message: notice)
                        Spacer(minLength: 0)
                        Button {
                            managementNotice = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(AppLocalization.string("Dismiss")))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .conduitGlassSurface(cornerRadius: 18, tint: .yellow.opacity(0.10))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                }
            }
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
            if !visibleBots.isEmpty {
                Section(AppLocalization.string("Bots")) {
                    ForEach(visibleBots) { bot in
                        BotRosterRow(
                            bot: bot,
                            canManage: canManageBots,
                            canDelete: appState.canDeleteBot(bot),
                            onEdit: { editorMode = .edit(bot) },
                            onTogglePin: {
                                Task {
                                    managementNotice = await appState.setBotPinned(bot, pinned: !bot.isPinned)
                                }
                            },
                            onDelete: { pendingDelete = bot }
                        )
                    }
                    if canManageBots {
                        newBotButton
                    }
                }
            } else if canManageBots {
                Section(AppLocalization.string("Bots")) {
                    newBotButton
                }
            }
            groupSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await appState.reloadBotRoster()
            await appState.refreshGroupChatSupport()
        }
        .sheet(isPresented: $showingGroupCreateSheet) {
            GroupCreateSheet()
        }
    }

    /// Group Chat rows, below the Bots section: hosted rooms (only when the
    /// gateway advertised the foundation `groups.*` methods — an unsupported
    /// gateway never shows a dead control) plus the group chats Hermes
    /// Desktop mirrored to the gateway, which need no `groups.*` support.
    @State private var showingGroupCreateSheet = false

    @ViewBuilder
    private var groupSection: some View {
        if hostedGroupsAvailable || !appState.desktopGroupChats.isEmpty || groupProbeFailure != nil {
            Section {
                if let message = groupProbeFailure {
                    // A probe failure must explain itself — an absent section
                    // is indistinguishable from "this gateway has no groups".
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
                if hostedGroupsAvailable {
                    ForEach(appState.groupRooms) { room in
                        GroupRosterRow(room: room)
                    }
                }
                ForEach(appState.desktopGroupChats) { group in
                    DesktopGroupRosterRow(group: group) {
                        presentedDesktopGroup = group
                    }
                }
                if hostedGroupsAvailable && visibleBots.count >= 2 {
                    Button {
                        Haptics.light()
                        // The sheet renders the shared error; start clean.
                        appState.errorMessage = nil
                        showingGroupCreateSheet = true
                    } label: {
                        newGroupCard
                    }
                    .buttonStyle(.plain)
                    // Same row chrome as the room cards above: a plain List
                    // otherwise paints its own opaque, sharp-edged slab.
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    .accessibilityLabel(Text(AppLocalization.string("New Group Chat")))
                }
            } header: {
                Text(AppLocalization.string("Group Chats"))
            }
        }
    }

    private var newBotButton: some View {
        Button {
            Haptics.light()
            editorMode = .create
        } label: {
            createCard(title: AppLocalization.string("New Bot"))
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
        .accessibilityLabel(Text(AppLocalization.string("New Bot")))
    }

    private var newGroupCard: some View {
        createCard(title: AppLocalization.string("New Group Chat"))
    }

    /// A create action as a roster card: the rows' glyph, padding, fill and
    /// border, with the accent carrying the "new" affordance.
    private func createCard(title: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.conduitAccent.opacity(0.16))
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.conduitAccent)
            }
            .frame(width: 36, height: 36)
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.conduitAccent)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
                Button(AppLocalization.string("New Bot")) {
                    editorMode = .create
                }
                .buttonStyle(.borderedProminent)
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
    let canManage: Bool
    let canDelete: Bool
    let onEdit: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
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
        .contextMenu {
            if canManage {
                Button(action: onEdit) {
                    Label(AppLocalization.string("Edit Bot"), systemImage: "pencil")
                }
                Button(action: onTogglePin) {
                    Label(
                        bot.isPinned ? AppLocalization.string("Unpin") : AppLocalization.string("Pin"),
                        systemImage: bot.isPinned ? "pin.slash" : "pin"
                    )
                }
                if canDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label(AppLocalization.string("Delete Bot"), systemImage: "trash")
                    }
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canManage {
                if canDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label(AppLocalization.string("Delete Bot"), systemImage: "trash")
                    }
                }
                Button(action: onEdit) {
                    Label(AppLocalization.string("Edit Bot"), systemImage: "pencil")
                }
                .tint(.conduitAccent)
            }
        }
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

/// A bot's face on the roster and in group pickers: its gateway-stored
/// picture (the one Hermes Desktop shows) once fetched, else its initial on
/// its color.
struct BotMonogramView: View {
    let bot: BotProfile
    @EnvironmentObject private var appState: AppState
    /// Scales with Dynamic Type so the glyph never clips at accessibility
    /// sizes (a fixed 36x36 frame clipped the letter once `.body` grew).
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36

    var body: some View {
        BotAvatarView(
            name: bot.name,
            label: bot.displayLabel,
            colorString: bot.appearanceColor,
            image: appState.botAvatarImage(for: bot),
            size: avatarSize
        )
        .task(id: "\(bot.name)|\(bot.hasAvatar)|\(appState.botAvatarGeneration)") {
            await appState.loadBotAvatarIfNeeded(bot)
        }
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
