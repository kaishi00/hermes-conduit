//
//  RoomInviteViews.swift
//  Conduit
//
//  Rooms with people you've linked, from the invited side (designs/
//  cross-owner-agents, C3c): an invite's row in Group Chats, and its join
//  card, which brings your bots, each with its choices for the room, or
//  declines. The invites are read with Group Chats' drafts
//  (RoomInvites.swift), and every 5 s while a card is up.
//

import OSLog
import SwiftUI

private let roomInvitesLogger = Logger(subsystem: "com.milim.relay", category: "RoomInvites")

/// An invite in Group Chats: who invited you and until when, where it
/// stands, or why it ended.
struct RoomInviteRosterRow: View {
    let invite: RoomInvite
    let onOpen: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let line = RoomInviteText.rowLine(for: invite)
        Button {
            Haptics.light()
            onOpen()
        } label: {
            RosterGlyphRow(symbol: Self.symbol(for: invite.status), title: invite.name, subtitle: line)
        }
        .buttonStyle(.plain)
        .rosterListRow()
        .accessibilityLabel(Text(verbatim: invite.name))
        .accessibilityValue(Text(verbatim: line))
        .accessibilityHint(Text(invite.status == "waiting"
            ? AppLocalization.string("Choose which of your bots join, or decline.")
            : AppLocalization.string("Shows where the invite stands.")))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if RoomInviteRows.canRemove(invite) {
                Button(AppLocalization.string("Remove")) {
                    appState.dismissRoomInvite(invite.id)
                }
            }
        }
    }

    private static func symbol(for status: String) -> String {
        switch status {
        case "waiting": return "envelope"
        case "joined": return "hourglass"
        case "started": return "checkmark.circle"
        default: return "exclamationmark.circle"
        }
    }
}

/// An invite's join card: the room, who it's from, who else is invited,
/// the host's agents, and until when it can be answered. While it waits on
/// you, the bots the plugin can bring, each with its choices for the room,
/// then Join, or Decline. After, where it stands and your bots in it.
struct RoomInviteSheet: View {
    let inviteID: String
    /// The invite as its row or the notification showed it, while the
    /// list doesn't have it.
    let initial: RoomInvite
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    /// The bots brought, by profile.
    @State private var picked = Set<String>()
    /// Choices changed on the card, by profile. Nothing goes until Join.
    @State private var edited: [String: RoomChoices] = [:]
    @State private var busy = false
    @State private var actionError: String?
    /// The answer is still on its way to the host.
    @State private var sendingNote: String?
    @State private var confirmingDecline = false
    /// The Bots list isn't read yet: opened from its notification.
    @State private var readingBots = true

    init(invite: RoomInvite) {
        inviteID = invite.id
        initial = invite
    }

    private var invite: RoomInvite {
        appState.linkedRoomInvite(inviteID) ?? initial
    }

    /// Your bots it can bring: those whose profile the plugin lists, as
    /// New Group Chat lists them.
    private func bots(for invite: RoomInvite) -> [BotProfile] {
        let profiles = Set(invite.profiles)
        return appState.botRoster.filter { !$0.isHiddenByMeta && profiles.contains($0.name) }
    }

    var body: some View {
        let invite = self.invite
        NavigationStack {
            List {
                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
                if let sendingNote {
                    Text(sendingNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                Section {
                    Text(verbatim: RoomInviteText.line(for: invite))
                    if invite.status == "waiting", let expiresAt = invite.expiresAt {
                        Text(AppLocalization.string("Answer by \(RoomDraftText.until(expiresAt))"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !invite.people.isEmpty {
                        Text(AppLocalization.string("Also invited: \(RoomDraftText.names(invite.people))"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !invite.hostAgents.isEmpty {
                        Text(AppLocalization.string("Their agents: \(RoomDraftText.names(invite.hostAgents))"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if appState.linkedRoomInviteIsGone(inviteID) {
                    // The plugin forgot it: nothing here can answer it.
                    Text(AppLocalization.string("This invite isn't on your Hermes any more."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else if invite.status == "waiting" {
                    bringSection(invite)
                    answerSection(invite)
                } else {
                    if !invite.joined.isEmpty {
                        Section(AppLocalization.string("Your bots")) {
                            ForEach(invite.joined, id: \.profile) { agent in
                                Text(verbatim: agent.displayName)
                            }
                        }
                    }
                    if RoomInviteRows.canRemove(invite) {
                        Section {
                            Button(AppLocalization.string("Remove"), role: .destructive) {
                                appState.dismissRoomInvite(invite.id)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .refreshable { await appState.refreshLinkedRoomInvites() }
            .navigationTitle(invite.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
            .confirmationDialog(
                AppLocalization.string("Decline \(invite.name)?"),
                isPresented: $confirmingDecline,
                titleVisibility: .visible
            ) {
                Button(AppLocalization.string("Decline"), role: .destructive) { answer(invite, agents: []) }
                Button(AppLocalization.string("Cancel"), role: .cancel) {}
            } message: {
                Text(AppLocalization.string("The person who invited you is told."))
            }
        }
        .task {
            defer { readingBots = false }
            guard appState.botRoster.isEmpty else { return }
            await appState.refreshBotRoster()
        }
        .task(id: inviteID) { await follow() }
        // Another dashboard's invites are another Hermes'.
        .onChange(of: appState.activeDashboardID) { _, _ in dismiss() }
    }

    @ViewBuilder
    private func bringSection(_ invite: RoomInvite) -> some View {
        let bots = bots(for: invite)
        let pickedCount = bots.filter { picked.contains($0.name) }.count
        let placeCount = min(invite.places, RoomInviteLimits.maxAgents)
        Section {
            if placeCount == 0, !readingBots {
                // Why every bot below is disabled, or none is listed.
                Text(AppLocalization.string("This room has no places left for your bots."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if bots.isEmpty {
                if readingBots {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(AppLocalization.string("None of your bots can join this room."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(bots) { bot in
                botRow(bot, pickedCount: pickedCount, places: invite.places)
                if picked.contains(bot.name), let original = invite.choices[bot.name] {
                    choicesRow(bot, original: original)
                }
            }
        } header: {
            Text(AppLocalization.string("Your bots"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("Places for your bots: \(placeCount)"))
                Text(AppLocalization.string(
                    "Each bot starts with its choices from your last room with the same people, else its defaults."
                ))
            }
        }
    }

    private func botRow(_ bot: BotProfile, pickedCount: Int, places: Int) -> some View {
        let isSelected = picked.contains(bot.name)
        let canPick = isSelected || RoomInviteLimits.canPick(picked: pickedCount, places: places)
        return Button {
            Haptics.light()
            if isSelected {
                picked.remove(bot.name)
            } else {
                picked.insert(bot.name)
            }
        } label: {
            HStack(spacing: 12) {
                BotMonogramView(bot: bot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayLabel)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(bot.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.conduitAccent : Color.secondary)
            }
            .opacity(canPick ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!canPick || busy)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func choicesRow(_ bot: BotProfile, original: RoomChoices) -> some View {
        let binding = Binding<RoomChoices>(
            get: { edited[bot.name] ?? original },
            set: { edited[bot.name] = $0 }
        )
        return NavigationLink {
            RoomInviteChoicesView(name: bot.displayLabel, original: original, choices: binding,
                                  offersData: appState.canShareFreeBusy)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.string("\(bot.displayLabel)'s choices"))
                    .font(.subheadline)
                Text(verbatim: RoomInviteChoicesView.summary(binding.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(busy)
    }

    private func answerSection(_ invite: RoomInvite) -> some View {
        let pickedCount = bots(for: invite).filter { picked.contains($0.name) }.count
        return Section {
            Button {
                join(invite)
            } label: {
                HStack {
                    Text(AppLocalization.string("Join"))
                        .fontWeight(.semibold)
                    if busy {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(busy || !RoomInviteLimits.canJoin(picked: pickedCount, places: invite.places))
            Button(AppLocalization.string("Decline"), role: .destructive) { confirmingDecline = true }
                .disabled(busy)
        }
    }

    private func join(_ invite: RoomInvite) {
        // A read since picking them took some off the invite.
        let unlisted = RoomInviteLimits.unlisted(picked: picked, profiles: invite.profiles)
        guard unlisted.isEmpty else {
            picked.subtract(unlisted)
            actionError = AppLocalization.string("Some of the bots you picked can't join this room any more.")
            return
        }
        let bots = bots(for: invite).filter { picked.contains($0.name) }
        guard let agents = RoomInviteAgent.agents(for: bots, choices: invite.choices.merging(edited) { _, card in card }) else {
            actionError = AppLocalization.string("Two of these bots would claim the same @handle. Rename one bot's title, then try again.")
            return
        }
        answer(invite, agents: agents)
    }

    /// Joins with `agents`, or declines with none.
    private func answer(_ invite: RoomInvite, agents: [RoomInviteAgent]) {
        guard !busy else { return }
        busy = true
        actionError = nil
        sendingNote = nil
        Task { @MainActor in
            defer { busy = false }
            switch await appState.answerLinkedRoomInvite(invite, agents: agents) {
            case .answered:
                Haptics.success()
                // A declined invite has no row: the card goes with it.
                if agents.isEmpty { dismiss() }
            case .refused(let message):
                Haptics.error()
                roomInvitesLogger.notice("Invite answer refused")
                actionError = message
            case .sending(let message):
                sendingNote = message
            }
        }
    }

    /// Every 5 s while the card is up, for up to 10 minutes: the host may
    /// take it back, and once you've joined, the room starts when everyone
    /// has answered. One that ended won't change. A tick while Conduit is
    /// in the background or not connected is skipped, as the draft sheet
    /// skips them. Pull to read it again.
    private func follow() async {
        for _ in 0..<120 {
            guard !Task.isCancelled, ["waiting", "joined"].contains(invite.status) else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard appState.isSceneActive, appState.isConnected else { continue }
            await appState.refreshLinkedRoomInvites()
        }
    }
}

/// A bot's choices for a room it's invited to, before it joins: what Group
/// Info sets in a room of yours, and how it takes part and its turns a day,
/// which only a room someone else hosts asks. Nothing goes until Join.
struct RoomInviteChoicesView: View {
    let name: String
    /// What the plugin gave it: Use my data and Custom stay offered while
    /// either is this.
    let original: RoomChoices
    @Binding var choices: RoomChoices
    /// The plugin's Use my data says when you're busy, so it's offered.
    var offersData = false
    @ObservedObject private var appLanguage = AppLanguageStore.shared

    var body: some View {
        Form {
            Section {
                Picker(AppLocalization.string("What it can do"), selection: $choices.tools) {
                    Text(AppLocalization.string("Talk only")).tag("talk")
                    Text(AppLocalization.string("Look things up")).tag("look")
                    // Offered where the plugin shares when you're busy; else shown while it's the choice.
                    if RoomChoices.offersUseMyData(freeBusy: offersData, current: [original.tools, choices.tools]) {
                        Text(AppLocalization.string("Use my data")).tag("data")
                    }
                    if original.tools == "custom" || choices.tools == "custom" {
                        Text(AppLocalization.string("Custom")).tag("custom")
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(AppLocalization.string("What it can do"))
            } footer: {
                Text(RoomAgentChoicesView.toolsDetail(choices, freeBusy: offersData))
            }
            Section {
                Picker(AppLocalization.string("What it may share"), selection: $choices.share) {
                    Text(AppLocalization.string("What helps")).tag("helps")
                    Text(AppLocalization.string("Ask me first")).tag("ask")
                    Text(AppLocalization.string("Nothing personal")).tag("nothing")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(AppLocalization.string("What it may share"))
            } footer: {
                Text(RoomAgentChoicesView.shareDetail(choices.share))
            }
            Section {
                Toggle(AppLocalization.string("Search my past chats"), isOn: $choices.searchChats)
                    .tint(.conduitAccent)
            } footer: {
                Text(AppLocalization.string("It can search your other chats to answer here, other people's messages in them included."))
            }
            Section {
                Picker(AppLocalization.string("How it takes part"), selection: $choices.takesPart) {
                    Text(AppLocalization.string("Joins in")).tag("joins")
                    Text(AppLocalization.string("When asked")).tag("asked")
                    Text(AppLocalization.string("Listens only")).tag("listens")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(AppLocalization.string("How it takes part"))
            } footer: {
                Text(Self.takesPartDetail(choices.takesPart))
            }
            Section {
                Picker(AppLocalization.string("Turns a day"), selection: $choices.dailyLimit) {
                    ForEach(RoomChoices.dailyLimitSteps(including: original.dailyLimit), id: \.self) { steps in
                        Text(verbatim: Self.number(steps)).tag(steps)
                    }
                }
            } footer: {
                Text(AppLocalization.string(
                    "The most turns it takes in this room each day. Once they're used up, it says so and sits out until tomorrow."
                ))
            }
        }
        .onChange(of: choices) { _, _ in Haptics.selection() }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The card's line under a bot brought: each choice, briefly.
    static func summary(_ choices: RoomChoices) -> String {
        let turnCount = choices.dailyLimit
        return [
            toolsLabel(choices.tools),
            shareLabel(choices.share),
            takesPartLabel(choices.takesPart),
            AppLocalization.string("Turns a day: \(turnCount)"),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    static func toolsLabel(_ tools: String) -> String {
        switch tools {
        case "talk": return AppLocalization.string("Talk only")
        case "look": return AppLocalization.string("Look things up")
        case "data": return AppLocalization.string("Use my data")
        case "custom": return AppLocalization.string("Custom")
        default: return ""
        }
    }

    static func shareLabel(_ share: String) -> String {
        switch share {
        case "helps": return AppLocalization.string("What helps")
        case "ask": return AppLocalization.string("Ask me first")
        case "nothing": return AppLocalization.string("Nothing personal")
        default: return ""
        }
    }

    static func takesPartLabel(_ takesPart: String) -> String {
        switch takesPart {
        case "joins": return AppLocalization.string("Joins in")
        case "asked": return AppLocalization.string("When asked")
        case "listens": return AppLocalization.string("Listens only")
        default: return ""
        }
    }

    /// What each way of taking part means (room_bridge_member.py).
    static func takesPartDetail(_ takesPart: String) -> String {
        switch takesPart {
        case "joins":
            return AppLocalization.string("It takes its turns in the room as the other agents do.")
        case "asked":
            return AppLocalization.string("It answers only when a new message @mentions it, or @all.")
        case "listens":
            return AppLocalization.string("It reads along but never answers.")
        default:
            return ""
        }
    }

    private static func number(_ value: Int) -> String {
        value.formatted(.number.locale(AppLocalization.formattingLocale))
    }
}
