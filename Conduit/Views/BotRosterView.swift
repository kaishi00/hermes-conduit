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
    /// Hidden bots, shown dimmed under the list when opened (Desktop's
    /// "Hidden" disclosure; this session only).
    @State private var showsHiddenBots = false
    /// New Group Chat from a bot's Groups menu starts with that bot picked.
    @State private var groupSheetBot: BotProfile?
    /// V2's Bots tab: its title bar's "+" asks for a new bot here, and the
    /// in-list create card steps aside.
    private let createRequest: Binding<Bool>?

    init(createRequest: Binding<Bool>? = nil) {
        self.createRequest = createRequest
    }

    var body: some View {
        Group {
            // Group rows keep the list up even with no visible bot: a room
            // whose bots are all meta-hidden must stay reachable, and so
            // must the group probe's failure notice.
            // Hidden bots still list (under Hidden), so only an empty
            // roster is empty.
            if appState.botRoster.isEmpty && !hasGroupRows && groupProbeFailure == nil {
                emptyState
                    .safeAreaInset(edge: .top) {
                        if let notice = managementNotice {
                            managementNoticeCard(notice)
                                .padding(.horizontal, 16)
                        }
                    }
            } else {
                rosterList
            }
        }
        .sheet(item: $presentedDesktopGroup) { group in
            DesktopGroupChatView(group: group)
                .environmentObject(appState)
        }
        .sheet(item: $editorMode) { mode in
            BotEditorSheet(mode: mode) { createdName, warning, introduces in
                managementNotice = warning
                guard let createdName,
                      let bot = appState.botRoster.first(where: { $0.name == createdName }) else { return }
                // Desktop opens a new bot's forever chat straight away, and
                // the bot introduces itself when it can reach a model.
                appState.dismissSidebarDrawer()
                Task { await appState.openNewBotChat(for: bot, introduces: introduces) }
            }
            .environmentObject(appState)
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
        .onChange(of: createRequest?.wrappedValue ?? false) { _, requested in
            guard requested else { return }
            createRequest?.wrappedValue = false
            guard canManageBots else { return }
            Haptics.light()
            editorMode = .create
        }
    }

    private var deleteDialogTitle: String {
        guard let bot = pendingDelete else { return "" }
        return AppLocalization.string("Delete \(bot.displayLabel)?")
    }

    /// A dismissible notice for the last management action that needs
    /// explaining. Shown over the list and over the empty state alike, so a
    /// warning is never lost when the roster has nothing visible.
    private func managementNoticeCard(_ notice: String) -> some View {
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
    }

    private var canManageBots: Bool {
        appState.botModePhase == .available && appState.isConnected
    }

    /// `botRoster` keeps EVERY bot (sessions-list hygiene reads the full
    /// canonical registry); meta-hidden rows are hidden from THIS view only.
    private var visibleBots: [BotProfile] {
        appState.botRoster.filter { !$0.isHiddenByMeta }
    }

    private var hiddenBots: [BotProfile] {
        appState.botRoster.filter(\.isHiddenByMeta)
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

    @ViewBuilder
    private var botRows: some View {
        ForEach(visibleBots) { bot in
            botRow(bot)
        }
        if !hiddenBots.isEmpty {
            // Desktop's "Hidden" disclosure: hidden bots keep working, so
            // they stay one tap away to open or unhide.
            Button {
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.2)) { showsHiddenBots.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsHiddenBots ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(AppLocalization.string("Hidden"))
                    Text(verbatim: String(hiddenBots.count))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rosterListRow(divider: false)
            .accessibilityLabel(Text(AppLocalization.string("Hidden bots: \(String(hiddenBots.count))")))
            .accessibilityValue(Text(
                showsHiddenBots ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed")
            ))
            if showsHiddenBots {
                ForEach(hiddenBots) { bot in
                    botRow(bot)
                        .opacity(0.6)
                }
            }
        }
    }

    private func botRow(_ bot: BotProfile) -> some View {
        BotRosterRow(
            bot: bot,
            canManage: canManageBots,
            canDelete: appState.canDeleteBot(bot),
            rooms: botRooms(bot),
            canStartGroup: hostedGroupsAvailable && !bot.isHiddenByMeta && visibleBots.count >= 2,
            actions: BotRosterRow.Actions(
                edit: { editorMode = .edit(bot) },
                togglePin: {
                    Task { managementNotice = await appState.setBotPinned(bot, pinned: !bot.isPinned) }
                },
                toggleHidden: {
                    Task { managementNotice = await appState.setBotHidden(bot, hidden: !bot.isHiddenByMeta) }
                },
                duplicate: {
                    managementNotice = AppLocalization.string("Duplicating \(bot.displayLabel)…")
                    Task { managementNotice = await appState.duplicateBot(bot) }
                },
                newChat: {
                    appState.dismissSidebarDrawer()
                    appState.startNewChat(inProfile: bot.name)
                },
                openRoom: { room in
                    appState.dismissSidebarDrawer()
                    Task { await appState.openGroupRoom(room) }
                },
                newGroup: {
                    appState.errorMessage = nil
                    groupSheetBot = bot
                },
                delete: { pendingDelete = bot }
            )
        )
    }

    /// The hosted group rooms this bot is a member of.
    private func botRooms(_ bot: BotProfile) -> [GroupRoom] {
        guard hostedGroupsAvailable else { return [] }
        return appState.groupRooms.filter { room in
            !room.isDisbanded && room.members.contains {
                $0.profile?.caseInsensitiveCompare(bot.name) == .orderedSame
            }
        }
    }

    private var rosterList: some View {
        List {
            if let notice = managementNotice {
                Section {
                    managementNoticeCard(notice)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
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
                    .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                }
            }
            if !appState.botRoster.isEmpty && createRequest != nil {
                // V2's Bots tab: the page title names the list; a line under
                // the bots says what a bot is. A row, not a footer: a plain
                // List paints footers as an opaque band across the backdrop.
                Section {
                    botRows
                    Text("Each bot is its own profile with one ongoing conversation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                        .rosterListRow(divider: false)
                }
                .listSectionSeparator(.hidden)
            } else if !appState.botRoster.isEmpty {
                Section(AppLocalization.string("Bots")) {
                    botRows
                    if canManageBots {
                        newBotButton
                    }
                }
            } else if canManageBots && createRequest == nil {
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
                .environmentObject(appState)
        }
        .sheet(item: $groupSheetBot) { bot in
            GroupCreateSheet(preselected: [bot.name])
                .environmentObject(appState)
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
                    .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
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
                    .rosterListRow(divider: false)
                    .accessibilityLabel(Text(AppLocalization.string("New Group Chat")))
                }
            } header: {
                if createRequest != nil {
                    // As the Chats list's section headers, in line with the
                    // pictures.
                    Text(AppLocalization.string("Group Chats"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .padding(.leading, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets())
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Text(AppLocalization.string("Group Chats"))
                }
            }
            .listSectionSeparator(.hidden)
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
        .rosterListRow(divider: false)
        .accessibilityLabel(Text(AppLocalization.string("New Bot")))
    }

    private var newGroupCard: some View {
        createCard(title: AppLocalization.string("New Group Chat"))
    }

    /// A create action as a roster row, the accent carrying the "new"
    /// affordance.
    private func createCard(title: String) -> some View {
        RosterGlyphRow(symbol: "plus", title: title, isAction: true)
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
                    AppLocalization.string("Update Hermes to use Bot Mode."),
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
                if canManageBots {
                    Button(AppLocalization.string("New Bot")) {
                        Haptics.light()
                        editorMode = .create
                    }
                    .buttonStyle(.borderedProminent)
                }
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
    @Environment(\.v2OpenBeside) private var openBeside

    var body: some View {
        Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            Task { await appState.openGroupRoom(room) }
        } label: {
            RosterIconRow(title: room.name, subtitle: subtitleText) { size in
                GroupRoomIcon(picture: appState.groupRoomPicture(roomID: room.roomID), members: room.members, size: size)
            }
        }
        .buttonStyle(.plain)
        .rosterListRow(selection: .room(room.roomID, beside: openBeside))
        .accessibilityLabel(Text(room.name))
        .accessibilityValue(Text(subtitleText))
        .accessibilityHint(Text(AppLocalization.string("Opens this group chat.")))
        .v2SelectedTrait(.room(room.roomID, beside: openBeside))
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
/// A chat-style row with no card, like the group rows under it
/// (`RosterGlyphRow`).
private struct BotRosterRow: View {
    let bot: BotProfile
    let canManage: Bool
    let canDelete: Bool
    /// The group rooms it's in, for its Groups menu.
    let rooms: [GroupRoom]
    let canStartGroup: Bool
    let actions: Actions
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2OpenBeside) private var openBeside

    /// What the row's menu and swipe actions do (Desktop's row menu).
    struct Actions {
        let edit: () -> Void
        let togglePin: () -> Void
        let toggleHidden: () -> Void
        let duplicate: () -> Void
        let newChat: () -> Void
        let openRoom: (GroupRoom) -> Void
        let newGroup: () -> Void
        let delete: () -> Void
    }

    var body: some View {
        Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            Task { await appState.openBotChat(for: bot) }
        } label: {
            // V2: a chat-style row, no card. Picture, name and time, then
            // the latest message.
            HStack(spacing: 12) {
                BotMonogramView(bot: bot)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(bot.displayLabel)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if bot.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.primary.opacity(0.35))
                        }
                        Spacer(minLength: 4)
                        if let activity = activityLabel {
                            Text(activity)
                                .font(.footnote)
                                .foregroundStyle(Color.primary.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                    subtitleText
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear.v2RowSelection(selection))
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .overlay(alignment: .bottom) { V2RowDivider(leadingInset: 48) }
        .accessibilityLabel(Text(bot.displayLabel))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text(AppLocalization.string("Opens this bot's chat.")))
        .v2SelectedTrait(selection)
        .contextMenu {
            Button(action: actions.newChat) {
                Label(AppLocalization.string("New Chat"), systemImage: "square.and.pencil")
            }
            if !rooms.isEmpty || canStartGroup {
                Menu {
                    ForEach(rooms) { room in
                        Button {
                            actions.openRoom(room)
                        } label: {
                            Text(verbatim: room.name)
                        }
                    }
                    if canStartGroup {
                        Button(action: actions.newGroup) {
                            Label(AppLocalization.string("New Group Chat"), systemImage: "plus")
                        }
                    }
                } label: {
                    Label(AppLocalization.string("Groups"), systemImage: "person.3")
                }
            }
            if canManage {
                Divider()
                Button(action: actions.togglePin) {
                    Label(
                        bot.isPinned ? AppLocalization.string("Unpin") : AppLocalization.string("Pin"),
                        systemImage: bot.isPinned ? "pin.slash" : "pin"
                    )
                }
                Button(action: actions.toggleHidden) {
                    Label(
                        bot.isHiddenByMeta ? AppLocalization.string("Unhide") : AppLocalization.string("Hide"),
                        systemImage: bot.isHiddenByMeta ? "eye" : "eye.slash"
                    )
                }
                Divider()
                Button(action: actions.edit) {
                    Label(AppLocalization.string("Edit Bot"), systemImage: "pencil")
                }
                Button(action: actions.duplicate) {
                    Label(AppLocalization.string("Duplicate"), systemImage: "plus.square.on.square")
                }
                if canDelete {
                    Divider()
                    Button(role: .destructive, action: actions.delete) {
                        Label(AppLocalization.string("Delete Bot"), systemImage: "trash")
                    }
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canManage {
                if canDelete {
                    // Not a destructive role: that removes the row before the
                    // confirmation is answered, and on a Mac it can blank the list (#1364).
                    Button(action: actions.delete) {
                        Label(AppLocalization.string("Delete Bot"), systemImage: "trash")
                    }
                    .tint(.red)
                }
                Button(action: actions.edit) {
                    Label(AppLocalization.string("Edit Bot"), systemImage: "pencil")
                }
                .tint(.conduitAccent)
            }
        }
    }

    @ViewBuilder
    private var subtitleText: some View {
        Text(subtitleString)
    }

    /// Beside its open Bot Chat on a split window. A bot's row had no
    /// shade in one column, and keeps none.
    private var selection: V2RowSelection {
        .chat(isActive: appState.activeBotChatProfile == bot.name, beside: openBeside, faintAlone: false)
    }

    /// The latest preview, else the description, else the canonical chat's
    /// literal title (a wire identity, never localized).
    private var subtitleString: String {
        let detail = bot.profileDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = bot.canonicalSession?.preview
            ?? bot.lastPreview?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let plain = PreviewText.plain(preview)
        if !plain.isEmpty { return plain }
        if !detail.isEmpty { return detail }
        return BotMode.canonicalChatTitle
    }

    /// When the bot last talked with anyone, short and relative.
    private static let activityFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var activityLabel: String? {
        guard let lastActive = bot.lastActive, lastActive > 0 else { return nil }
        let seconds = lastActive > 10_000_000_000 ? lastActive / 1000 : lastActive
        let formatter = Self.activityFormatter
        formatter.locale = AppLocalization.formattingLocale
        return formatter.localizedString(for: Date(timeIntervalSince1970: seconds), relativeTo: Date())
    }

    /// The pin badge and the subtitle, spoken after the name; the label
    /// alone would leave both visual-only.
    private var accessibilityValue: String {
        let parts = [bot.isPinned ? AppLocalization.string("Pinned") : "", subtitleString, activityLabel ?? ""]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
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
            await appState.loadBotAvatarRetrying(bot)
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

/// What isn't a bot in the Bots list (group chats, create actions), in the
/// bots' chat-style row: an icon in place of the picture, a title and a
/// subtitle, no card.
struct RosterIconRow<Icon: View>: View {
    let title: String
    var subtitle: String? = nil
    /// A create action: the title in gold.
    var isAction = false
    /// A marker after the text (Desktop's computer on its mirrored groups).
    var trailingSymbol: String? = nil
    /// Draws the icon at the given size.
    @ViewBuilder let icon: (CGFloat) -> Icon
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 12) {
            icon(iconSize)
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isAction ? Color.conduitAccent : Color.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.caption)
                    .foregroundStyle(.conduitTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// A roster row with a round gold glyph for its icon (create actions).
struct RosterGlyphRow: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var isAction = false
    var trailingSymbol: String? = nil

    var body: some View {
        RosterIconRow(title: title, subtitle: subtitle, isAction: isAction, trailingSymbol: trailingSymbol) { _ in
            ZStack {
                Circle()
                    .fill(Color.conduitAccent.opacity(0.16))
                Image(systemName: symbol)
                    .font(Font.caption.weight(isAction ? .bold : .regular))
                    .foregroundStyle(Color.conduitAccent)
            }
        }
    }
}

extension View {
    /// A Bots list row's chrome: no system background or separator, 16 pt
    /// side insets, and the row's hairline from the text column.
    func rosterListRow(divider: Bool = true, selection: V2RowSelection = .none) -> some View {
        self
            .listRowBackground(Color.clear.v2RowSelection(selection))
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .overlay(alignment: .bottom) {
                if divider { V2RowDivider(leadingInset: 48) }
            }
    }
}
