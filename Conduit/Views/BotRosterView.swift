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
    /// The bot whose Bot Overview shows (Bots Home's Overview pill).
    @State private var overviewBot: BotProfile?
    /// Edit Bot tapped in the overview: the editor opens once it's gone,
    /// since a sheet can't open over it from here.
    @State private var editAfterOverview: BotProfile?
    /// Repair Connection opened from Bots Home's top.
    @State private var repairContext: ConnectionRepairContext?
    /// A room being started on Bots Home, its bots in the order they came
    /// (empty: none). Nothing reaches the host until Create.
    @State private var newRoom = BotRoomBuild()
    @State private var showingNewRoomSheet = false
    @State private var showingReorder = false
    @Environment(\.v2Shell) private var shell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// V2's Bots tab: its title bar's "+" asks for a new bot here, and the
    /// in-list create card steps aside.
    private let createRequest: Binding<Bool>?
    @Environment(\.v2OpenBeside) private var openBeside

    init(createRequest: Binding<Bool>? = nil) {
        self.createRequest = createRequest
    }

    var body: some View {
        Group {
            // Group rows keep the list up even with no visible bot: a room
            // whose bots are all meta-hidden must stay reachable, and so
            // must the group probe's failure notice.
            // Hidden bots still list (under Hidden), so only an empty
            // roster is empty. Until Hermes answers, the list is the one it
            // gave last time (#1533).
            if appState.shownBotRoster.isEmpty && !hasGroupRows && groupProbeFailure == nil {
                emptyState
                    .safeAreaInset(edge: .top) {
                        VStack(spacing: 12) {
                            homeCards
                            if let notice = managementNotice {
                                managementNoticeCard(notice)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
            } else {
                rosterList
                    .environment(\.botsHomeCovered, coveredBySheet)
                    .safeAreaInset(edge: .bottom) {
                        if !newRoom.isEmpty {
                            newRoomBar
                        }
                    }
            }
        }
        // Leaving Bots, or a room no longer possible, drops the room being
        // started: nothing was made.
        .onChange(of: shell.isTabActive) { _, active in
            if !active { newRoom.clear() }
        }
        .onChange(of: canStartRoomHere) { _, can in
            if !can { newRoom.clear() }
        }
        .onChange(of: visibleBotNames) { _, _ in
            let kept = newRoom.pruned(visible: visibleBotNames)
            if kept != newRoom { newRoom = kept }
        }
        .sheet(isPresented: $showingNewRoomSheet) {
            GroupCreateSheet(
                preselected: Set(newRoomBots.map(\.name)),
                suggestedName: joinedNames(newRoomBots),
                onCreated: { newRoom.clear() }
            )
            .environmentObject(appState)
        }
        .sheet(isPresented: $showingReorder) {
            BotReorderSheet()
                .environmentObject(appState)
        }
        .sheet(item: $presentedDesktopGroup) { group in
            DesktopGroupChatView(group: group)
                .environmentObject(appState)
        }
        .sheet(item: $repairContext) { context in
            ConnectionRepairSetupSheet(context: context)
                .environmentObject(appState)
        }
        .sheet(item: $overviewBot, onDismiss: {
            if let bot = editAfterOverview {
                editAfterOverview = nil
                editorMode = .edit(bot)
            }
        }) { bot in
            BotOverviewSheet(
                work: appState.botWork,
                profile: bot.name,
                onEdit: canManageBots ? { (edited: BotProfile) in
                    editAfterOverview = edited
                    overviewBot = nil
                } : nil,
                onChat: {
                    overviewBot = nil
                    appState.beginOpeningBotChat(bot.name)
                    // Grows out of its portrait, as from a tap on it
                    // (Eric 2026-11-04), unless it opens beside the list.
                    if openBeside == nil { appState.botZoom.tap(bot.name) }
                    Task {
                        if await !appState.openBotChat(for: bot) { appState.botZoom.openFailed(bot.name) }
                        appState.endOpeningBotChat(bot.name)
                    }
                },
                onClose: { overviewBot = nil },
                // A workstream opened from its list counts as its bot's, so
                // it and its Bot Chat shrink back into the portrait too. Its
                // open (a link) says nothing when it fails, so a failed one
                // leaves the arm to go stale (BotZoomArm.window).
                onWillOpenWork: openBeside == nil ? { appState.botZoom.tap(bot.name) } : nil
            )
            .environmentObject(appState)
        }
        .sheet(item: $editorMode) { mode in
            BotEditorSheet(mode: mode) { createdName, warning, introduces in
                managementNotice = warning
                guard let createdName,
                      let bot = appState.botRoster.first(where: { $0.name == createdName }) else { return }
                // Desktop opens a new bot's forever chat straight away, and
                // the bot introduces itself when it can reach a model.
                appState.beginOpeningBotChat(bot.name)
                Task {
                    await appState.openNewBotChat(for: bot, introduces: introduces)
                    appState.endOpeningBotChat(bot.name)
                }
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
                    .scaledFont(.caption.weight(.semibold))
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
        appState.shownBotRoster.filter { !$0.isHiddenByMeta }
    }

    private var hiddenBots: [BotProfile] {
        appState.shownBotRoster.filter(\.isHiddenByMeta)
    }

    /// A new group picks from Hermes' bots, never the kept copy's.
    private var canStartGroups: Bool {
        hostedGroupsAvailable && appState.botRoster.lazy.filter { !$0.isHiddenByMeta }.count >= 2
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
        !appState.shownGroupRooms.isEmpty || !appState.shownDesktopGroupChats.isEmpty
    }

    private var groupProbeFailure: String? {
        if case .failed(let message) = appState.groupChatPhase { return message }
        return nil
    }

    /// Bots Home: every bot as a portrait, three across on a phone, in
    /// the roster's own order, so a bot never moves for being busy. Hidden
    /// bots follow under their disclosure, dimmed, as on the list.
    @ViewBuilder
    private var portraitGrid: some View {
        BotPortraitGrid(bots: visibleBots, onDropAtEnd: dropAtEnd) { portrait($0) }
            .modifier(BotsTalkingRoomsReader())
            .rosterListRow(divider: false)
        if !hiddenBots.isEmpty {
            hiddenDisclosure
            if showsHiddenBots {
                BotPortraitGrid(bots: hiddenBots) { portrait($0) }
                    .opacity(0.6)
                    .rosterListRow(divider: false)
            }
        }
    }

    @ViewBuilder
    private var botRows: some View {
        ForEach(visibleBots) { bot in
            botRow(bot)
        }
        if !hiddenBots.isEmpty {
            hiddenDisclosure
            if showsHiddenBots {
                ForEach(hiddenBots) { bot in
                    botRow(bot)
                        .opacity(0.6)
                }
            }
        }
    }

    /// Desktop's "Hidden" disclosure: hidden bots keep working, so they
    /// stay one tap away to open or unhide.
    private var hiddenDisclosure: some View {
        Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.2)) { showsHiddenBots.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showsHiddenBots ? "chevron.down" : "chevron.right")
                    .scaledFont(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Text(AppLocalization.string("Hidden"))
                Text(verbatim: String(hiddenBots.count))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .scaledFont(.footnote.weight(.semibold))
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
    }

    private func botRow(_ bot: BotProfile) -> some View {
        BotRosterRow(
            bot: bot,
            canManage: canManageBots,
            canDelete: appState.canDeleteBot(bot),
            rooms: botRooms(bot),
            canStartGroup: canStartGroups && !bot.isHiddenByMeta,
            actions: actions(for: bot)
        )
    }

    /// Bots Home's portrait of a bot: its chat, its Overview and the row's
    /// menu.
    private func portrait(_ bot: BotProfile) -> some View {
        BotPortraitCell(
            bot: bot,
            work: appState.botWork,
            menu: BotRosterMenu(
                bot: bot,
                canManage: canManageBots,
                canDelete: appState.canDeleteBot(bot),
                rooms: botRooms(bot),
                canStartGroup: canStartGroups && !bot.isHiddenByMeta,
                actions: actions(for: bot)
            ),
            onOverview: { overviewBot = bot },
            // A hidden bot can't join a room, so its tap still opens its chat.
            room: newRoom.isEmpty || bot.isHiddenByMeta ? .off : (isInNewRoom(bot.name) ? .member : .notMember),
            onDrop: { dragged, merge in handleDrop(dragged, on: bot, merge: merge) },
            canMerge: { dragged in canMerge(dragged, with: bot) },
            onToggleRoom: { toggleNewRoom(bot) }
        )
    }

    // MARK: - Arranging and starting rooms (Bots Home)

    private var canStartRoomHere: Bool {
        canStartGroups && createRequest != nil
    }

    private func isInNewRoom(_ name: String) -> Bool {
        newRoom.contains(name)
    }

    /// Whether `dragged`, held over `target`'s face, starts a room with it
    /// (the same test the drop makes).
    private func canMerge(_ dragged: String, with target: BotProfile) -> Bool {
        guard canStartRoomHere, !target.isHiddenByMeta,
              dragged.caseInsensitiveCompare(target.name) != .orderedSame,
              let draggedBot = appState.shownBotRoster.first(where: {
                  $0.name.caseInsensitiveCompare(dragged) == .orderedSame
              }) else { return false }
        // A room that's full takes no one new.
        return !draggedBot.isHiddenByMeta && newRoom.fits([target.name, draggedBot.name])
    }

    /// A portrait dropped on another: held over its face, the two start a
    /// room (or the dropped one joins the room being started); else it
    /// moves before it.
    private func handleDrop(_ dragged: String, on target: BotProfile, merge: Bool) {
        if merge, canMerge(dragged, with: target),
           let draggedBot = appState.shownBotRoster.first(where: { $0.name.caseInsensitiveCompare(dragged) == .orderedSame }) {
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
                addToNewRoom([target.name, draggedBot.name])
            }
            return
        }
        Haptics.selection()
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
            appState.moveBot(dragged, before: target.name, shown: appState.shownBotRoster.map(\.name))
        }
    }

    private func dropAtEnd(_ dragged: String) {
        Haptics.selection()
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
            appState.moveBot(dragged, before: nil, shown: appState.shownBotRoster.map(\.name))
        }
    }

    private func addToNewRoom(_ names: [String]) {
        guard newRoom.add(names) else {
            Haptics.warning()
            managementNotice = AppLocalization.string("A room holds up to 6 bots.")
            return
        }
    }

    /// Taking a bot out always works; adding one only while it's shown.
    private func toggleNewRoom(_ bot: BotProfile) {
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
            if isInNewRoom(bot.name) {
                newRoom.remove(bot.name)
            } else if !bot.isHiddenByMeta {
                addToNewRoom([bot.name])
            }
        }
    }

    private func cancelNewRoom() {
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { newRoom.clear() }
    }

    /// The room's bots that are still shown and not hidden: a bot hidden or
    /// deleted meanwhile leaves the room (onChange of visibleBotNames).
    private var newRoomBots: [BotProfile] {
        newRoom.names.compactMap { name in
            visibleBots.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    private var visibleBotNames: [String] { visibleBots.map(\.name) }

    /// "Atlas and Furina", in the App Language like the rest of the app
    /// (the suggested room name is kept as typed, so it matters).
    private func joinedNames(_ bots: [BotProfile]) -> String {
        let formatter = ListFormatter()
        formatter.locale = AppLocalization.formattingLocale
        return formatter.string(from: bots.map(\.displayLabel)) ?? bots.map(\.displayLabel).joined(separator: ", ")
    }

    /// The bar a room being started shows at the bottom: its bots (a tap
    /// takes one out), Cancel, and Create, which opens New Group Chat with
    /// them picked and a name suggested: the confirmation.
    private var newRoomBar: some View {
        let bots = newRoomBots
        return HStack(spacing: 12) {
            HStack(spacing: -22) {
                ForEach(bots) { bot in
                    Button {
                        toggleNewRoom(bot)
                    } label: {
                        BotMonogramView(bot: bot, size: 30)
                            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                            // A 44 pt target; the next face's sits on top
                            // where they overlap, as the faces do.
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(AppLocalization.string("Take \(bot.displayLabel) out")))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.string("New room"))
                    .scaledFont(.subheadline.weight(.semibold))
                Text(verbatim: bots.count < 2
                     ? AppLocalization.string("Drag or tap bots to add them.")
                     : joinedNames(bots))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(AppLocalization.string("Cancel"), action: cancelNewRoom)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("bots.newRoom.cancel")
            Button(AppLocalization.string("Create")) {
                Haptics.light()
                showingNewRoomSheet = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.conduitAccent)
            .disabled(bots.count < 2)
            .accessibilityIdentifier("bots.newRoom.create")
        }
        .padding(12)
        .conduitGlassSurface(cornerRadius: 22)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func actions(for bot: BotProfile) -> BotRosterRow.Actions {
        BotRosterRow.Actions(
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
            delete: { pendingDelete = bot },
            startRoom: createRequest == nil || bot.isHiddenByMeta ? nil : {
                // Into the room being started, if there is one.
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
                    addToNewRoom([bot.name])
                }
            },
            reorder: createRequest == nil ? nil : { showingReorder = true }
        )
    }

    /// The hosted group rooms this bot is a member of.
    private func botRooms(_ bot: BotProfile) -> [GroupRoom] {
        appState.shownGroupRooms.filter { room in
            !room.isDisbanded && room.members.contains {
                $0.profile?.caseInsensitiveCompare(bot.name) == .orderedSame
            }
        }
    }

    /// Bots Home is where the app opens: finishing setup and a failed
    /// connection's repair are offered at its top, as on Sessions.
    @ViewBuilder
    private var homeCards: some View {
        if createRequest != nil {
            if appState.showsFinishSetup {
                V2FinishSetupCard()
            }
            if appState.showsConnectionRepair {
                V2ConnectionRepairCard(identifier: "bots.repair-connection") { repairContext = $0 }
            }
        }
    }

    /// One of this screen's sheets is up over the grid.
    private var coveredBySheet: Bool {
        overviewBot != nil || showingNewRoomSheet || showingReorder || presentedDesktopGroup != nil
            || repairContext != nil || editorMode != nil || showingGroupCreateSheet || groupSheetBot != nil
    }

    /// Bots Home (V2's Bots tab) is a scroll view, not a List: a List
    /// takes a touch and hold and a drag for its whole row, so the
    /// portraits' grid, one row, lifted as one under the first bot's menu,
    /// and no portrait could be dragged (Eric 2026-11-03).
    private var rosterList: some View {
        Group {
            if createRequest != nil {
                homeScroll
            } else {
                plainList
            }
        }
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

    private var homeScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if appState.showsFinishSetup || appState.showsConnectionRepair {
                    VStack(spacing: 12) { homeCards }
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                        .padding(.bottom, 12)
                }
                if let notice = managementNotice {
                    managementNoticeCard(notice)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 3)
                }
                if case .failed(let message) = appState.botModePhase {
                    botModeFailure(message)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 3)
                }
                if !appState.shownBotRoster.isEmpty {
                    if !appState.talkingRooms.isEmpty {
                        BotsLiveRooms()
                            .rosterListRow(divider: false)
                    }
                    portraitGrid
                        .padding(.bottom, 8)
                }
                homeGroupSection
            }
            .environment(\.rosterRowsInScroll, true)
        }
        .scrollContentBackground(.hidden)
    }

    private func botModeFailure(_ message: String) -> some View {
        BotModeNoticeRow(
            icon: "exclamationmark.triangle",
            message: message
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassSurface(cornerRadius: 18, tint: .yellow.opacity(0.10))
    }

    private var plainList: some View {
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
                    botModeFailure(message)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                }
            }
            if !appState.shownBotRoster.isEmpty {
                Section(AppLocalization.string("Bots")) {
                    botRows
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
    }

    /// Group Chat rows, below the Bots section: hosted rooms (once the
    /// gateway advertised the foundation `groups.*` methods, or the ones it
    /// listed last time until it answers — an unsupported gateway never
    /// shows a dead control) plus the group chats Hermes Desktop mirrored to
    /// the gateway, which need no `groups.*` support.
    @State private var showingGroupCreateSheet = false

    private var showsGroupSection: Bool {
        hostedGroupsAvailable || hasGroupRows || groupProbeFailure != nil
    }

    @ViewBuilder
    private var groupRows: some View {
        if let message = groupProbeFailure {
            // A probe failure must explain itself — an absent section
            // is indistinguishable from "this gateway has no groups".
            botModeFailure(message)
                .padding(.vertical, 3)
                .rosterListRow(divider: false)
        }
        ForEach(appState.shownGroupRooms) { room in
            GroupRosterRow(room: room)
        }
        ForEach(appState.shownDesktopGroupChats) { group in
            DesktopGroupRosterRow(group: group) {
                presentedDesktopGroup = group
            }
        }
    }

    private func startNewGroup() {
        Haptics.light()
        // The sheet renders the shared error; start clean.
        appState.errorMessage = nil
        showingGroupCreateSheet = true
    }

    @ViewBuilder
    private var groupSection: some View {
        if showsGroupSection {
            Section(AppLocalization.string("Group Chats")) {
                groupRows
                if canStartGroups {
                    Button(action: startNewGroup) {
                        newGroupCard
                    }
                    .buttonStyle(.plain)
                    .rosterListRow(divider: false)
                    .accessibilityLabel(Text(AppLocalization.string("New Group Chat")))
                }
            }
            .listSectionSeparator(.hidden)
        }
    }

    /// Bots Home's Group Chats: a heading in line with the pictures, with
    /// New Group Chat as its +, as New Bot is the title bar's.
    @ViewBuilder
    private var homeGroupSection: some View {
        if showsGroupSection {
            HStack(alignment: .center) {
                Text(AppLocalization.string("Group Chats"))
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if canStartGroups {
                    // New Bot's glass +, at its 44 pt size.
                    Button(action: startNewGroup) {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .conduitFixedGlyph()
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .conduitGlassControl(cornerRadius: 22, interactive: false)
                    .accessibilityLabel(Text(AppLocalization.string("New Group Chat")))
                    .accessibilityIdentifier("bots.newGroupChat")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(minHeight: 44)
            VStack(spacing: 0) {
                groupRows
            }
            .padding(.bottom, 16)
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
            if appState.shownBotRoster.isEmpty {
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
        /// Bots Home only: start a room with this bot, adding others by a
        /// tap or a drag, and Reorder Bots.
        var startRoom: (() -> Void)?
        var reorder: (() -> Void)?
    }

    var body: some View {
        Button {
            Haptics.light()
            appState.beginOpeningBotChat(bot.name)
            Task {
                await appState.openBotChat(for: bot)
                appState.endOpeningBotChat(bot.name)
            }
        } label: {
            // V2: a chat-style row, no card. Picture, name and time, then
            // the latest message.
            HStack(spacing: 12) {
                BotMonogramView(bot: bot)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(bot.displayLabel)
                            .scaledFont(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if bot.isPinned {
                            Image(systemName: "pin.fill")
                                .scaledFont(.caption2.weight(.bold))
                                .foregroundStyle(Color.primary.opacity(0.35))
                        }
                        Spacer(minLength: 4)
                        if let activity = activityLabel {
                            Text(activity)
                                .scaledFont(.footnote)
                                .foregroundStyle(Color.primary.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                    subtitleText
                        .scaledFont(.subheadline)
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
            BotRosterMenu(bot: bot, canManage: canManage, canDelete: canDelete, rooms: rooms,
                          canStartGroup: canStartGroup, actions: actions)
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

/// A bot's menu, on its Bots list row and its Bots Home portrait
/// (Desktop's row menu).
private struct BotRosterMenu: View {
    let bot: BotProfile
    let canManage: Bool
    let canDelete: Bool
    let rooms: [GroupRoom]
    let canStartGroup: Bool
    let actions: BotRosterRow.Actions

    var body: some View {
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
        if canStartGroup, let startRoom = actions.startRoom {
            Button(action: startRoom) {
                Label(AppLocalization.string("Start a Room with…"), systemImage: "person.2.badge.plus")
            }
        }
        if let reorder = actions.reorder {
            Button(action: reorder) {
                Label(AppLocalization.string("Reorder Bots"), systemImage: "arrow.up.arrow.down")
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
}

/// A bot's face on the roster and in group pickers: its gateway-stored
/// picture (the one Hermes Desktop shows) once fetched, else its initial on
/// its color.
struct BotMonogramView: View {
    let bot: BotProfile
    @EnvironmentObject private var appState: AppState
    /// Scales with Dynamic Type so the glyph never clips at accessibility
    /// sizes (a fixed 36x36 frame clipped the letter once `.body` grew).
    @ScaledMetric private var avatarSize: CGFloat

    /// `size` at the default Text Size: 36 on a row, larger on Bots Home's
    /// portraits.
    init(bot: BotProfile, size: CGFloat = 36) {
        self.bot = bot
        _avatarSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        BotAvatarView(
            name: bot.name,
            label: bot.displayLabel,
            colorString: bot.appearanceColor,
            image: appState.botAvatarImage(for: bot),
            size: avatarSize
        )
        // Connecting fetches again: a kept row's fetch fails offline.
        .task(id: "\(bot.name)|\(bot.hasAvatar)|\(appState.botAvatarGeneration)|\(appState.isConnected)") {
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
                .scaledFont(.footnote)
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
                    .scaledFont(.callout.weight(.semibold))
                    .foregroundStyle(isAction ? Color.conduitAccent : Color.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .scaledFont(.caption)
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
                    .scaledFont(ScaledFont.caption.weight(isAction ? .bold : .regular))
                    .foregroundStyle(Color.conduitAccent)
            }
        }
    }
}

extension View {
    /// A Bots list row's chrome: no system background or separator, 16 pt
    /// side insets, and the row's hairline from the text column. On Bots
    /// Home, a scroll view rather than a List, the row pads itself.
    func rosterListRow(divider: Bool = true, selection: V2RowSelection = .none) -> some View {
        modifier(RosterListRow(divider: divider, selection: selection))
    }
}

private struct RosterRowsInScrollKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The roster's rows are in Bots Home's scroll view, not a List.
    var rosterRowsInScroll: Bool {
        get { self[RosterRowsInScrollKey.self] }
        set { self[RosterRowsInScrollKey.self] = newValue }
    }
}

private struct RosterListRow: ViewModifier {
    let divider: Bool
    let selection: V2RowSelection
    @Environment(\.rosterRowsInScroll) private var inScroll

    func body(content: Content) -> some View {
        if inScroll {
            content
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .v2RowSelection(selection)
                .overlay(alignment: .bottom) {
                    if divider { V2RowDivider(leadingInset: 64).padding(.trailing, 16) }
                }
        } else {
            content
                .listRowBackground(Color.clear.v2RowSelection(selection))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .overlay(alignment: .bottom) {
                    if divider { V2RowDivider(leadingInset: 48) }
                }
        }
    }
}
