import OSLog
import SwiftUI

private let roomChoicesLogger = Logger(subsystem: "com.milim.relay", category: "RoomChoices")

/// Group Info, from the room menu in both shells: who's in the open room,
/// which agents are yours, and what the room last found on the way to the
/// others. In a room with a member from another installation, each of your
/// agents opens its choices for the room, when the host's plugin keeps them
/// (designs/cross-owner-agents, C1).
@MainActor
struct GroupRoomInfoSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// The room the sheet opened on (a copy by its Link and room, since
    /// room ids are only unique per host): another room closes it.
    @State private var roomID: String?
    /// The member a Take Out asks about.
    @State private var takingOut: GroupMember?
    @State private var confirmingLeave = false
    @State private var working = false
    /// What each of your agents may do here, by profile, read when Group
    /// Info opens and again when you come back from its choices: shown on
    /// its row, so nobody has to guess why a bot won't look something up.
    @State private var agentTools: [String: RoomChoices] = [:]
    /// A refusal's title and the plugin's words.
    @State private var refusal: (title: String, message: String)?
    /// Whether the sheet is still up, for a room chat that fails after Done.
    @State private var presence = Presence()

    private final class Presence {
        var shown = true
    }

    var body: some View {
        NavigationStack {
            // Settings' own pieces, as Bots Home's sheets are (Sheets in Settings' look).
            SettingsDetailContainer {
                if let copy = appState.activeRoomSurface?.copy {
                    RoomCopyHostSection(copy: copy)
                }
                if let room = appState.activeRoomSurface?.room {
                    memberSection(room)
                }
                roomChatSection
                if appState.canLeaveActiveRoom {
                    Button(role: .destructive) {
                        confirmingLeave = true
                    } label: {
                        Label(AppLocalization.string("Leave Room", table: .rooms), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.settingsDestructive)
                    .disabled(working)
                }
            }
            .confirmationDialog(
                takingOut.map { RoomLeaveText.takeOutTitle(GroupRoomTurns.displayName(of: $0)) } ?? "",
                isPresented: Binding(get: { takingOut != nil }, set: { if !$0 { takingOut = nil } }),
                titleVisibility: .visible,
                presenting: takingOut
            ) { member in
                Button(AppLocalization.string("Take Out", table: .rooms), role: .destructive) {
                    takeOut(member)
                }
                Button(AppLocalization.string("Cancel"), role: .cancel) {}
            } message: { member in
                Text(verbatim: takeOutMessage(member))
            }
            .confirmationDialog(RoomLeaveText.leaveTitle, isPresented: $confirmingLeave, titleVisibility: .visible) {
                Button(AppLocalization.string("Leave Room", table: .rooms), role: .destructive) {
                    leave()
                }
                Button(AppLocalization.string("Cancel"), role: .cancel) {}
            } message: {
                if let copy = appState.activeRoomSurface?.copy {
                    Text(verbatim: RoomLeaveText.leaveMessage(copy))
                }
            }
            .alert(
                refusal?.title ?? "",
                isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
            ) {
                Button(AppLocalization.string("OK"), role: .cancel) { refusal = nil }
            } message: {
                Text(verbatim: refusal?.message ?? "")
            }
            .navigationTitle(appState.activeRoomSurface?.room.name ?? AppLocalization.string("Group Info", table: .rooms))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { presence.shown = true }
            .onDisappear { presence.shown = false }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
        // Its own, not the room screen's: V2 raises this sheet outside
        // GroupChatView, which sets them for V1.
        .environment(\.groupRoomLooks, appState.activeRoomLooksShown)
        .onAppear { roomID = openRoomKey }
        // Who left or was taken out since the room opened.
        .task { await appState.refreshActiveRoomPeople() }
        .onChange(of: openRoomKey) { _, id in
            if id != roomID { dismiss() }
        }
    }

    @ViewBuilder
    private func memberSection(_ room: GroupRoom) -> some View {
        // Named as the bots are now, as in the room, with their owners.
        let members = GroupRoomTurns.members(appState.activeRoomMembers, namedBy: appState.botRoster)
        // Choices matter only beside other people's agents.
        let offersChoices = appState.canSetRoomChoices && members.contains(where: \.isPeer)
        let choiceProfiles = offersChoices
            ? Array(Set(members.filter { !$0.isPeer && $0.out == nil }.compactMap(\.profile).filter { !$0.isEmpty })).sorted()
            : []
        ConduitSettingsSection(title: AppLocalization.string("Members", table: .rooms), symbol: "person.3", tint: .conduitAccent) {
            ForEach(members, id: \.identityKey) { member in
                let canTakeOut = appState.canTakeOut(member) && !working
                HStack(spacing: 8) {
                    if offersChoices, !member.isPeer, member.out == nil, let profile = member.profile, !profile.isEmpty {
                        NavigationLink {
                            RoomAgentChoicesView(
                                roomID: room.roomID,
                                profile: profile,
                                name: GroupRoomTurns.displayName(of: member)
                            )
                        } label: {
                            HStack {
                                GroupRoomMemberRow(member: member, route: nil)
                                Spacer(minLength: 8)
                                if let tools = agentTools[profile].map({ RoomInviteChoicesView.toolsLabel($0.tools) }),
                                   !tools.isEmpty {
                                    Text(tools)
                                        .scaledFont(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                SettingsChevron()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        GroupRoomMemberRow(
                            member: member,
                            route: member.out == nil ? appState.activeRoomDriverStatus?.routeStatus(for: member) : nil
                        )
                        Spacer(minLength: 8)
                    }
                    if canTakeOut {
                        Menu {
                            Button(role: .destructive) {
                                takingOut = member
                            } label: {
                                Label(AppLocalization.string("Take Out", table: .rooms), systemImage: "person.badge.minus")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .scaledFont(.body)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text(AppLocalization.string("Take Out", table: .rooms)))
                    }
                }
                .frame(minHeight: 44)
                .modifier(TakeOutActions(enabled: canTakeOut) {
                    takingOut = member
                })
            }
            if offersChoices {
                Text(AppLocalization.string("Tap one of your agents to choose what it may do and share here. Other people choose for theirs.", table: .rooms))
                    .settingsCaption()
            }
        }
        // Read on each appearance (so again on coming back from an agent's
        // choices) and when the agents that offer choices change. Leaving
        // cancels a read, so an older one never lands over a newer one.
        .task(id: choiceProfiles) {
            guard !choiceProfiles.isEmpty else { return }
            await loadAgentTools(roomID: room.roomID, profiles: choiceProfiles)
        }
    }

    /// Each agent's choices for the room, one read each; one that fails
    /// shows no line rather than a wrong one.
    private func loadAgentTools(roomID: String, profiles: [String]) async {
        let client = appState.roomChoicesClient
        var read: [String: RoomChoices] = [:]
        // A room holds at most six agents, so one read after another.
        for profile in profiles {
            if let choices = try? await client.choices(roomID: roomID, profile: profile) { read[profile] = choices }
        }
        // Left (or a newer read started), or another room opened meanwhile.
        guard !Task.isCancelled, appState.activeRoomSurface?.room.roomID == roomID else { return }
        if read != agentTools { agentTools = read }
    }
}

extension GroupRoomInfoSheet {
    /// Each of your agents in a room with other people's opens a private
    /// chat about it, or asks there for its notes (C5b).
    @ViewBuilder
    private var roomChatSection: some View {
        let agents = appState.activeRoomChatAgents
        if !agents.isEmpty {
            ConduitSettingsSection(title: RoomChatText.sectionTitle, symbol: "bubble.left.and.text.bubble.right", tint: .conduitAccent) {
                ForEach(agents, id: \.profile) { agent in
                    Button {
                        openRoomChat(with: agent, wrapUp: false)
                    } label: {
                        Label(RoomChatText.ask(agent.name), systemImage: "bubble.left.and.text.bubble.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.settings)
                    .disabled(working)
                    Button {
                        openRoomChat(with: agent, wrapUp: true)
                    } label: {
                        Label(RoomChatText.wrapUp(agent.name), systemImage: "checklist")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.settings)
                    .disabled(working)
                }
                Text(verbatim: RoomChatText.footer)
                    .settingsCaption()
            }
        }
    }

    private func openRoomChat(with agent: RoomChatAgent, wrapUp: Bool) {
        working = true
        Task { @MainActor in
            let failure = await appState.openRoomChat(with: agent, wrapUp: wrapUp) { [presence] in presence.shown }
            working = false
            if let failure {
                Haptics.error()
                refusal = (RoomChatText.failureTitle, failure)
            }
        }
    }

    private var openRoomKey: String? {
        appState.activeRoomSurface.map { $0.copy?.id ?? $0.room.roomID }
    }

    private func takeOutMessage(_ member: GroupMember) -> String {
        let name = GroupRoomTurns.displayName(of: member)
        if let copy = appState.activeRoomSurface?.copy {
            return RoomLeaveText.takeOutMessage(name, in: copy)
        }
        return RoomLeaveText.takeOutMessage(name, owner: member.owner)
    }

    private func takeOut(_ member: GroupMember) {
        working = true
        Task { @MainActor in
            let result = await appState.takeOut(member)
            working = false
            show(result, refusedTitle: AppLocalization.string("Could not take this agent out", table: .rooms))
        }
    }

    private func leave() {
        working = true
        Task { @MainActor in
            let result = await appState.leaveActiveRoom()
            working = false
            show(result, refusedTitle: AppLocalization.string("Could not leave this room", table: .rooms))
        }
    }

    private func show(_ result: RoomLeaveResult, refusedTitle: String) {
        switch result {
        case .done:
            Haptics.success()
        case .refused(let message):
            Haptics.error()
            refusal = (refusedTitle, message)
        case .sending(let message):
            refusal = (RoomLeaveText.stillSendingTitle, message)
        }
    }
}

/// Take Out on a member's row, by a long press (its ⋯ menu beside it).
private struct TakeOutActions: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        // A card has no swipe: the row's ⋯ and a long press take it out. A
        // row that can't be taken out has no menu, not an empty one.
        if enabled {
            content
                .contextMenu {
                    Button(role: .destructive, action: action) {
                        Label(AppLocalization.string("Take Out", table: .rooms), systemImage: "person.badge.minus")
                    }
                }
        } else {
            content
        }
    }
}

/// One member in Group Info: its picture and name, whose it is ("Your
/// agent", "Mona's agent"), and the trouble the room last found on the way
/// to it.
private struct GroupRoomMemberRow: View {
    let member: GroupMember
    let route: GroupPeerRoute.Status?

    private var trouble: (text: String, symbol: String)? {
        switch route {
        case .cutOff:
            return (AppLocalization.string("Cut off: its Hermes no longer accepts this room", table: .rooms), "exclamationmark.triangle")
        case .unreachable:
            return (AppLocalization.string("Can't be reached. Hermes keeps trying.", table: .rooms), "wifi.exclamationmark")
        case .ready, .other, nil:
            return nil
        }
    }

    var body: some View {
        let name = GroupRoomTurns.displayName(of: member)
        HStack(spacing: 12) {
            GroupMemberAvatar(member: member, name: name, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                Text(GroupRoomTurns.ownerLine(of: member))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                if let trouble {
                    Label(trouble.text, systemImage: trouble.symbol)
                        .scaledFont(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the plugin holds one of your agents to in a room with other
/// people's agents: what it can do, what it may share, past-chat search,
/// and a note it reads on each of its turns there. How it takes part and
/// its turns a day count only in a room someone else hosts, which an
/// invite's join card sets (RoomInviteViews.swift).
/// Each change sends only that choice, and the page shows what the plugin
/// answers, for the dashboard it asked.
@MainActor
struct RoomAgentChoicesView: View {
    @EnvironmentObject private var appState: AppState
    let roomID: String
    let profile: String
    let name: String

    /// What the plugin answered for `loadedKey`; nil until then.
    @State private var choices: RoomChoices?
    @State private var loadedKey: String?
    @State private var saving = false
    @State private var error: String?
    @State private var noteDraft = ""

    private var key: String {
        "\(appState.activeDashboardID?.uuidString ?? "")|\(roomID)|\(profile)"
    }

    var body: some View {
        // Settings' own pieces: each choice a dropdown in a card (Sheets in Settings' look).
        SettingsDetailContainer {
            if let choices, loadedKey == key {
                if !choices.saved {
                    Text(AppLocalization.string("These are \(name)'s defaults. A change here applies to this room only.", table: .rooms))
                        .settingsCaption()
                }
                toolsSection(choices)
                shareSection(choices)
                SettingsCard {
                    Toggle(AppLocalization.string("Search my past chats", table: .rooms), isOn: Binding(
                        get: { self.choices?.searchChats ?? false },
                        set: { on in change("search_chats", to: on) { $0.searchChats = on } }
                    ))
                    .tint(.conduitAccent)
                    Text(AppLocalization.string("It can search your other chats to answer here, other people's messages in them included.", table: .rooms))
                        .settingsCaption()
                }
                // A plugin without Run work sends no run_work.
                if choices.runWork != nil {
                    SettingsCard {
                        Toggle(AppLocalization.string("Run work", table: .rooms), isOn: Binding(
                            get: { self.choices?.runWork ?? false },
                            set: { on in change("run_work", to: on) { $0.runWork = on } }
                        ))
                        .tint(.conduitAccent)
                        Text(AppLocalization.string("It can start work for this room, like research or code. Before each start, and before it sends the work more, it asks you on your phone: Start, Change it or Don't start. What the work finds reaches the room only as your share choices allow.", table: .rooms))
                            .settingsCaption()
                    }
                }
                noteSection(choices)
            } else if error == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            if let error {
                SettingsCard {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.red)
                    if loadedKey != key {
                        Button(AppLocalization.string("Try again")) {
                            Task { await load(key) }
                        }
                        .buttonStyle(.settings)
                    }
                }
            }
        }
        // One change at a time.
        .disabled(saving)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: key) { await load(key) }
    }

    private func toolsSection(_ choices: RoomChoices) -> some View {
        var tools: [(id: String, title: String)] = [
            (id: "talk", title: AppLocalization.string("Talk only", table: .rooms)),
            (id: "look", title: AppLocalization.string("Look things up", table: .rooms)),
        ]
        // Offered where the plugin shares when you're busy; else shown while it's the choice.
        if RoomChoices.offersUseMyData(freeBusy: appState.canShareFreeBusy, current: [choices.tools]) {
            tools.append((id: "data", title: AppLocalization.string("Use my data", table: .rooms)))
        }
        if choices.tools == "custom" {
            tools.append((id: "custom", title: AppLocalization.string("Custom")))
        }
        return ConduitSettingsSection(title: AppLocalization.string("What it can do", table: .rooms), symbol: "wrench.and.screwdriver", tint: .conduitAccent) {
            ConduitMenuPicker(value: choices.tools, choices: tools, onSelect: { picked in
                change("tools", to: picked) { $0.tools = picked }
            }) {
                Text(AppLocalization.string("What it can do", table: .rooms)).foregroundStyle(.secondary)
            }
            Text(Self.toolsDetail(choices, freeBusy: appState.canShareFreeBusy))
                .settingsCaption()
        }
    }

    private func shareSection(_ choices: RoomChoices) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("What it may share", table: .rooms), symbol: "hand.raised", tint: .conduitAccent) {
            ConduitMenuPicker(value: choices.share, choices: RoomInviteChoicesView.shareChoices, onSelect: { picked in
                change("share", to: picked) { $0.share = picked }
            }) {
                Text(AppLocalization.string("What it may share", table: .rooms)).foregroundStyle(.secondary)
            }
            Text(Self.shareDetail(choices.share))
                .settingsCaption()
        }
    }

    private func noteSection(_ choices: RoomChoices) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Note for this room", table: .rooms), symbol: "note.text", tint: .conduitAccent) {
            TextField(
                AppLocalization.string("Anything it should keep in mind here", table: .rooms),
                text: $noteDraft,
                axis: .vertical
            )
            .lineLimit(3...8)
            .settingsEditorBox()
            .onChange(of: noteDraft) { _, text in
                let clipped = RoomChoicesClient.clippedNote(text)
                if clipped != text { noteDraft = clipped }
            }
            if noteDraft != choices.note {
                HStack(spacing: 10) {
                    Button(AppLocalization.string("Cancel")) { noteDraft = choices.note }
                        .buttonStyle(.settings)
                    Spacer()
                    Button(AppLocalization.string("Save")) {
                        let note = noteDraft
                        change("note", to: note) { $0.note = note }
                    }
                    .buttonStyle(.settingsPrimary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("\(name) reads this on each of its turns here. It isn't posted to the room.", table: .rooms))
                // RoomChoicesClient.noteLimit: past it, typing stops.
                Text(AppLocalization.string("A note holds up to 1,000 characters.", table: .rooms))
            }
            .settingsCaption()
        }
    }

    /// `freeBusy`: the plugin's Use my data says when you're busy.
    static func toolsDetail(_ choices: RoomChoices, freeBusy: Bool) -> String {
        switch choices.tools {
        case "talk":
            return AppLocalization.string("It answers from what it knows, without tools.", table: .rooms)
        case "data" where freeBusy:
            return AppLocalization.string("It can search the web and X, read web pages and look at images, and say when you're busy from the calendar you share with Hermes: only the times, never what, where or with whom, as What it may share allows.", table: .rooms)
        case "look", "data":
            return AppLocalization.string("It can search the web and X, read web pages and look at images.", table: .rooms)
        case "custom" where choices.customTools.isEmpty:
            return AppLocalization.string("No tools are picked for it on your Hermes.", table: .rooms)
        case "custom":
            let tools = choices.customTools.joined(separator: ", ")
            return AppLocalization.string("Only the tools picked on your Hermes: \(tools)", table: .rooms)
        default:
            return ""
        }
    }

    static func shareDetail(_ share: String) -> String {
        switch share {
        case "helps":
            return AppLocalization.string("What helps the room, but nothing sensitive: no health, money, passwords, or what others told you in private.", table: .rooms)
        case "ask":
            return AppLocalization.string("Before it shares anything personal, it asks you in Conduit.", table: .rooms)
        case "nothing":
            return AppLocalization.string("It shares nothing personal about you, even when asked.", table: .rooms)
        default:
            return ""
        }
    }

    /// Shows the change, sends only it, then shows what the plugin kept.
    /// The save is under way from here, not from when its task starts, so a
    /// second change can't send a save whose answer lands after the newer
    /// one's.
    private func change(_ choice: String, to value: Any, apply: (inout RoomChoices) -> Void) {
        guard loadedKey == key, !saving, var changed = choices else { return }
        apply(&changed)
        guard changed != choices else { return }
        Haptics.selection()
        choices = changed
        saving = true
        Task { await save([choice: value]) }
    }

    private func load(_ key: String) async {
        if loadedKey != key {
            choices = nil
            loadedKey = nil
            error = nil
        }
        do {
            let read = try await appState.roomChoicesClient.choices(roomID: roomID, profile: profile)
            // Moved on meanwhile.
            guard key == self.key else { return }
            choices = read
            noteDraft = read.note
            loadedKey = key
        } catch is CancellationError {
            return
        } catch let readError {
            roomChoicesLogger.notice("Room choices not read: \(LogRedaction.message(readError), privacy: .public)")
            if key == self.key {
                error = AppLocalization.string("Could not read this setting from the host: \(UserFacingError.message(for: readError))")
            }
        }
    }

    private func save(_ change: [String: Any]) async {
        defer { saving = false }
        let key = key
        guard loadedKey == key else { return }
        error = nil
        do {
            let kept = try await appState.roomChoicesClient.set(change, roomID: roomID, profile: profile)
            guard key == self.key, loadedKey == key else { return }
            choices = kept
            if change["note"] != nil { noteDraft = kept.note }
        } catch let saveError {
            guard key == self.key, loadedKey == key else { return }
            let cancelled = saveError is CancellationError
            if !cancelled {
                Haptics.error()
                roomChoicesLogger.notice("Room choices not saved: \(LogRedaction.message(saveError), privacy: .public)")
            }
            // Read back what the plugin kept rather than guess at it. A note
            // being written stays, saved or not.
            let draft = noteDraft
            saving = false
            choices = nil
            loadedKey = nil
            await load(key)
            if loadedKey == key { noteDraft = draft }
            if !cancelled, key == self.key {
                error = AppLocalization.string("Could not change this setting: \(UserFacingError.message(for: saveError))")
            }
        }
    }
}
