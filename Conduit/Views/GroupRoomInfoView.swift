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
    /// A refusal's title and the plugin's words.
    @State private var refusal: (title: String, message: String)?
    /// Whether the sheet is still up, for a room chat that fails after Done.
    @State private var presence = Presence()

    private final class Presence {
        var shown = true
    }

    var body: some View {
        NavigationStack {
            List {
                if let copy = appState.activeRoomSurface?.copy {
                    RoomCopyHostSection(copy: copy)
                }
                if let room = appState.activeRoomSurface?.room {
                    memberSection(room)
                }
                roomChatSection
                if appState.canLeaveActiveRoom {
                    Section {
                        Button(role: .destructive) {
                            confirmingLeave = true
                        } label: {
                            Label(AppLocalization.string("Leave Room"), systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .disabled(working)
                    }
                }
            }
            .confirmationDialog(
                takingOut.map { RoomLeaveText.takeOutTitle(GroupRoomTurns.displayName(of: $0)) } ?? "",
                isPresented: Binding(get: { takingOut != nil }, set: { if !$0 { takingOut = nil } }),
                titleVisibility: .visible,
                presenting: takingOut
            ) { member in
                Button(AppLocalization.string("Take Out"), role: .destructive) {
                    takeOut(member)
                }
                Button(AppLocalization.string("Cancel"), role: .cancel) {}
            } message: { member in
                Text(verbatim: takeOutMessage(member))
            }
            .confirmationDialog(RoomLeaveText.leaveTitle, isPresented: $confirmingLeave, titleVisibility: .visible) {
                Button(AppLocalization.string("Leave Room"), role: .destructive) {
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
            .navigationTitle(appState.activeRoomSurface?.room.name ?? AppLocalization.string("Group Info"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { presence.shown = true }
            .onDisappear { presence.shown = false }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
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
        Section {
            ForEach(members, id: \.identityKey) { member in
                if offersChoices, !member.isPeer, member.out == nil, let profile = member.profile, !profile.isEmpty {
                    NavigationLink {
                        RoomAgentChoicesView(
                            roomID: room.roomID,
                            profile: profile,
                            name: GroupRoomTurns.displayName(of: member)
                        )
                    } label: {
                        GroupRoomMemberRow(member: member, route: nil)
                    }
                    .modifier(TakeOutActions(enabled: appState.canTakeOut(member) && !working) {
                        takingOut = member
                    })
                } else {
                    GroupRoomMemberRow(
                        member: member,
                        route: member.out == nil ? appState.activeRoomDriverStatus?.routeStatus(for: member) : nil
                    )
                    .modifier(TakeOutActions(enabled: appState.canTakeOut(member) && !working) {
                        takingOut = member
                    })
                }
            }
        } header: {
            Text(AppLocalization.string("Members"))
        } footer: {
            if offersChoices {
                Text(AppLocalization.string("Tap one of your agents to choose what it may do and share here."))
            }
        }
    }
}

extension GroupRoomInfoSheet {
    /// Each of your agents in a room with other people's opens a private
    /// chat about it, or asks there for its notes (C5b).
    @ViewBuilder
    private var roomChatSection: some View {
        let agents = appState.activeRoomChatAgents
        if !agents.isEmpty {
            Section {
                ForEach(agents, id: \.profile) { agent in
                    Button {
                        openRoomChat(with: agent, wrapUp: false)
                    } label: {
                        Label(RoomChatText.ask(agent.name), systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .disabled(working)
                    Button {
                        openRoomChat(with: agent, wrapUp: true)
                    } label: {
                        Label(RoomChatText.wrapUp(agent.name), systemImage: "checklist")
                    }
                    .disabled(working)
                }
            } header: {
                Text(verbatim: RoomChatText.sectionTitle)
            } footer: {
                Text(verbatim: RoomChatText.footer)
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
            show(result, refusedTitle: AppLocalization.string("Could not take this agent out"))
        }
    }

    private func leave() {
        working = true
        Task { @MainActor in
            let result = await appState.leaveActiveRoom()
            working = false
            show(result, refusedTitle: AppLocalization.string("Could not leave this room"))
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

/// Take Out on a member's row, by swipe and context menu.
private struct TakeOutActions: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if enabled {
                    Button(AppLocalization.string("Take Out"), role: .destructive, action: action)
                }
            }
            .contextMenu {
                if enabled {
                    Button(role: .destructive, action: action) {
                        Label(AppLocalization.string("Take Out"), systemImage: "person.badge.minus")
                    }
                }
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
            return (AppLocalization.string("Cut off: its Hermes no longer accepts this room"), "exclamationmark.triangle")
        case .unreachable:
            return (AppLocalization.string("Can't be reached. Hermes keeps trying."), "wifi.exclamationmark")
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let trouble {
                    Label(trouble.text, systemImage: trouble.symbol)
                        .font(.footnote)
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
        Form {
            if let choices, loadedKey == key {
                if !choices.saved {
                    Section {
                        Text(AppLocalization.string("These are \(name)'s defaults. A change here applies to this room only."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                toolsSection(choices)
                shareSection(choices)
                Section {
                    Toggle(AppLocalization.string("Search my past chats"), isOn: Binding(
                        get: { self.choices?.searchChats ?? false },
                        set: { on in change("search_chats", to: on) { $0.searchChats = on } }
                    ))
                    .tint(.conduitAccent)
                } footer: {
                    Text(AppLocalization.string("It can search your other chats to answer here, other people's messages in them included."))
                }
                noteSection(choices)
            } else if error == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    if loadedKey != key {
                        Button(AppLocalization.string("Try again")) {
                            Task { await load(key) }
                        }
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
        Section {
            Picker(AppLocalization.string("What it can do"), selection: Binding(
                get: { self.choices?.tools ?? "talk" },
                set: { tools in change("tools", to: tools) { $0.tools = tools } }
            )) {
                Text(AppLocalization.string("Talk only")).tag("talk")
                Text(AppLocalization.string("Look things up")).tag("look")
                // Offered where the plugin shares when you're busy; else shown while it's the choice.
                if appState.canShareFreeBusy || choices.tools == "data" {
                    Text(AppLocalization.string("Use my data")).tag("data")
                }
                if choices.tools == "custom" {
                    Text(AppLocalization.string("Custom")).tag("custom")
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text(AppLocalization.string("What it can do"))
        } footer: {
            Text(Self.toolsDetail(choices, freeBusy: appState.canShareFreeBusy))
        }
    }

    private func shareSection(_ choices: RoomChoices) -> some View {
        Section {
            Picker(AppLocalization.string("What it may share"), selection: Binding(
                get: { self.choices?.share ?? "ask" },
                set: { share in change("share", to: share) { $0.share = share } }
            )) {
                Text(AppLocalization.string("What helps")).tag("helps")
                Text(AppLocalization.string("Ask me first")).tag("ask")
                Text(AppLocalization.string("Nothing personal")).tag("nothing")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text(AppLocalization.string("What it may share"))
        } footer: {
            Text(Self.shareDetail(choices.share))
        }
    }

    private func noteSection(_ choices: RoomChoices) -> some View {
        Section {
            TextField(
                AppLocalization.string("Anything it should keep in mind here"),
                text: $noteDraft,
                axis: .vertical
            )
            .lineLimit(3...8)
            .onChange(of: noteDraft) { _, text in
                let clipped = RoomChoicesClient.clippedNote(text)
                if clipped != text { noteDraft = clipped }
            }
            if noteDraft != choices.note {
                HStack {
                    Button(AppLocalization.string("Cancel")) { noteDraft = choices.note }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button(AppLocalization.string("Save")) {
                        let note = noteDraft
                        change("note", to: note) { $0.note = note }
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                }
            }
        } header: {
            Text(AppLocalization.string("Note for this room"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("\(name) reads this on each of its turns here. It isn't posted to the room."))
                // RoomChoicesClient.noteLimit: past it, typing stops.
                Text(AppLocalization.string("A note holds up to 1,000 characters."))
            }
        }
    }

    /// `freeBusy`: the plugin's Use my data says when you're busy.
    static func toolsDetail(_ choices: RoomChoices, freeBusy: Bool) -> String {
        switch choices.tools {
        case "talk":
            return AppLocalization.string("It answers from what it knows, without tools.")
        case "data" where freeBusy:
            return AppLocalization.string("It can search the web and X, read web pages and look at images, and say when you're busy from the calendar you share with Hermes: only the times, never what, where or with whom. It shares those times without asking.")
        case "look", "data":
            return AppLocalization.string("It can search the web and X, read web pages and look at images.")
        case "custom" where choices.customTools.isEmpty:
            return AppLocalization.string("No tools are picked for it on your Hermes.")
        case "custom":
            let tools = choices.customTools.joined(separator: ", ")
            return AppLocalization.string("Only the tools picked on your Hermes: \(tools)")
        default:
            return ""
        }
    }

    static func shareDetail(_ share: String) -> String {
        switch share {
        case "helps":
            return AppLocalization.string("What helps the room, but nothing sensitive: no health, money, passwords, or what others told you in private.")
        case "ask":
            return AppLocalization.string("Before it shares anything personal, it asks you in Conduit.")
        case "nothing":
            return AppLocalization.string("It shares nothing personal about you, even when asked.")
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
