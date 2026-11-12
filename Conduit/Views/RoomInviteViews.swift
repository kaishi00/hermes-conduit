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
            ? AppLocalization.string("Choose which of your bots join, or decline.", table: .rooms)
            : AppLocalization.string("Shows where the invite stands.", table: .rooms)))
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
    /// Which answer is going: the spinner shows on its button.
    @State private var declining = false
    @State private var actionError: String?
    /// The answer is still on its way to the host.
    @State private var sendingNote: String?
    @State private var confirmingDecline = false
    @State private var joiningAlone = false
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
            // Settings' own pieces, as Bots Home's sheets are (Sheets in Settings' look).
            SettingsDetailContainer {
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.red)
                }
                if let sendingNote {
                    Text(sendingNote)
                        .settingsCaption()
                }
                ConduitSettingsSection(title: AppLocalization.string("Invite", table: .rooms), symbol: "envelope.open", tint: .conduitAccent) {
                    Text(verbatim: RoomInviteText.line(for: invite))
                        .scaledFont(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if invite.status == "waiting", let expiresAt = invite.expiresAt {
                        Text(AppLocalization.string("Answer by \(RoomDraftText.until(expiresAt))", table: .rooms))
                            .settingsCaption()
                    }
                    if !invite.people.isEmpty {
                        Text(AppLocalization.string("Also invited: \(RoomDraftText.names(invite.people))", table: .rooms))
                            .settingsCaption()
                    }
                    if !invite.hostAgents.isEmpty {
                        Text(AppLocalization.string("Their agents: \(RoomDraftText.names(invite.hostAgents))", table: .rooms))
                            .settingsCaption()
                    }
                }
                if appState.linkedRoomInviteIsGone(inviteID) {
                    // The plugin forgot it: nothing here can answer it.
                    Text(AppLocalization.string("This invite isn't on your Hermes any more.", table: .rooms))
                        .settingsCaption()
                } else if invite.status == "waiting" {
                    bringSection(invite)
                    answerSection(invite)
                } else {
                    if invite.justMe {
                        Text(AppLocalization.string("You joined without your bots: you read this room and post in it yourself.", table: .rooms))
                            .settingsCaption()
                    }
                    if !invite.joined.isEmpty {
                        ConduitSettingsSection(title: AppLocalization.string("Your bots", table: .rooms), symbol: "person.2", tint: .conduitAccent) {
                            ForEach(invite.joined, id: \.profile) { agent in
                                Text(verbatim: agent.displayName)
                                    .frame(minHeight: 32, alignment: .leading)
                            }
                        }
                    }
                    if RoomInviteRows.canRemove(invite) {
                        Button(role: .destructive) {
                            appState.dismissRoomInvite(invite.id)
                            dismiss()
                        } label: {
                            Label(AppLocalization.string("Remove"), systemImage: "trash")
                        }
                        .buttonStyle(.settingsDestructive)
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
                AppLocalization.string("Decline \(invite.name)?", table: .rooms),
                isPresented: $confirmingDecline,
                titleVisibility: .visible
            ) {
                Button(AppLocalization.string("Decline", table: .rooms), role: .destructive) { answer(invite, agents: []) }
                Button(AppLocalization.string("Cancel"), role: .cancel) {}
            } message: {
                Text(AppLocalization.string("The person who invited you is told.", table: .rooms))
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
        ConduitSettingsSection(title: AppLocalization.string("Your bots", table: .rooms), symbol: "person.2", tint: .conduitAccent) {
            if placeCount == 0, !readingBots {
                // Why every bot below is disabled, or none is listed.
                Text(AppLocalization.string("This room has no places left for your bots.", table: .rooms))
                    .settingsCaption()
            } else if bots.isEmpty {
                if readingBots {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(AppLocalization.string("None of your bots can join this room.", table: .rooms))
                        .settingsCaption()
                }
            }
            ForEach(bots) { bot in
                botRow(bot, pickedCount: pickedCount, places: invite.places)
                if picked.contains(bot.name), let original = invite.choices[bot.name] {
                    choicesRow(bot, original: original)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("Places for your bots: \(placeCount)", table: .rooms))
                Text(AppLocalization.string(
                    "Each bot starts with its choices from your last room with the same people, else its defaults.", table: .rooms
                ))
            }
            .settingsCaption()
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
                        .scaledFont(.body)
                        .foregroundStyle(.primary)
                    Text(bot.name)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.conduitAccent : Color.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.string("\(bot.displayLabel)'s choices", table: .rooms))
                        .scaledFont(.subheadline)
                        .foregroundStyle(.primary)
                    Text(verbatim: RoomInviteChoicesView.summary(binding.wrappedValue))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                SettingsChevron()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 44)
        .disabled(busy)
    }

    private func answerSection(_ invite: RoomInvite) -> some View {
        let pickedCount = bots(for: invite).filter { picked.contains($0.name) }.count
        return VStack(spacing: 10) {
            Button {
                join(invite)
            } label: {
                HStack(spacing: 8) {
                    Text(AppLocalization.string("Join", table: .rooms))
                    if busy && !declining {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.settingsPrimary)
            .disabled(busy || !RoomInviteLimits.canJoin(picked: pickedCount, places: invite.places))
            // Read it and post in it, with none of your bots.
            if invite.justMeOffered {
                Button {
                    answer(invite, agents: [], justMe: true)
                } label: {
                    HStack(spacing: 8) {
                        Text(AppLocalization.string("Just Me", table: .rooms))
                        if busy && joiningAlone {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.settings)
                .disabled(busy || pickedCount > 0)
                .accessibilityHint(Text(AppLocalization.string("Joins without your bots, to read the room and post in it.", table: .rooms)))
            }
            Button(role: .destructive) {
                confirmingDecline = true
            } label: {
                HStack(spacing: 8) {
                    Text(AppLocalization.string("Decline", table: .rooms))
                    if busy && declining {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.settingsDestructive)
            .disabled(busy)
        }
    }

    private func join(_ invite: RoomInvite) {
        // A read since picking them took some off the invite.
        let unlisted = RoomInviteLimits.unlisted(picked: picked, profiles: invite.profiles)
        guard unlisted.isEmpty else {
            picked.subtract(unlisted)
            actionError = AppLocalization.string("Some of the bots you picked can't join this room any more.", table: .rooms)
            return
        }
        let bots = bots(for: invite).filter { picked.contains($0.name) }
        guard let agents = RoomInviteAgent.agents(for: bots, choices: invite.choices.merging(edited) { _, card in card }) else {
            actionError = AppLocalization.string("Two of these bots would claim the same @handle. Rename one bot's title, then try again.")
            return
        }
        answer(invite, agents: agents)
    }

    /// Joins with `agents`, or declines with none; `justMe` joins with none.
    private func answer(_ invite: RoomInvite, agents: [RoomInviteAgent], justMe: Bool = false) {
        guard !busy else { return }
        busy = true
        declining = agents.isEmpty && !justMe
        joiningAlone = justMe
        actionError = nil
        sendingNote = nil
        Task { @MainActor in
            defer { busy = false }
            switch await appState.answerLinkedRoomInvite(invite, agents: agents, justMe: justMe) {
            case .answered:
                Haptics.success()
                // A declined invite has no row: the card goes with it.
                if agents.isEmpty && !justMe { dismiss() }
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
        // Settings' own pieces: each choice a dropdown in a card (Sheets in Settings' look).
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("What it can do", table: .rooms), symbol: "wrench.and.screwdriver", tint: .conduitAccent) {
                ConduitMenuPicker(value: choices.tools, choices: toolChoices, onSelect: { choices.tools = $0 }) {
                    Text(AppLocalization.string("What it can do", table: .rooms)).foregroundStyle(.secondary)
                }
                Text(RoomAgentChoicesView.toolsDetail(choices, freeBusy: offersData))
                    .settingsCaption()
            }
            ConduitSettingsSection(title: AppLocalization.string("What it may share", table: .rooms), symbol: "hand.raised", tint: .conduitAccent) {
                ConduitMenuPicker(value: choices.share, choices: Self.shareChoices, onSelect: { choices.share = $0 }) {
                    Text(AppLocalization.string("What it may share", table: .rooms)).foregroundStyle(.secondary)
                }
                Text(RoomAgentChoicesView.shareDetail(choices.share))
                    .settingsCaption()
            }
            SettingsCard {
                Toggle(AppLocalization.string("Search my past chats", table: .rooms), isOn: $choices.searchChats)
                    .tint(.conduitAccent)
                Text(AppLocalization.string("It can search your other chats to answer here, other people's messages in them included.", table: .rooms))
                    .settingsCaption()
            }
            ConduitSettingsSection(title: AppLocalization.string("How it takes part", table: .rooms), symbol: "person.wave.2", tint: .conduitAccent) {
                ConduitMenuPicker(value: choices.takesPart, choices: Self.takesPartChoices, onSelect: { choices.takesPart = $0 }) {
                    Text(AppLocalization.string("How it takes part", table: .rooms)).foregroundStyle(.secondary)
                }
                Text(Self.takesPartDetail(choices.takesPart))
                    .settingsCaption()
            }
            ConduitSettingsSection(title: AppLocalization.string("Turns a day", table: .rooms), symbol: "number", tint: .conduitAccent) {
                ConduitMenuPicker(
                    value: choices.dailyLimit,
                    choices: RoomChoices.dailyLimitSteps(including: original.dailyLimit).map { (id: $0, title: Self.number($0)) },
                    onSelect: { choices.dailyLimit = $0 }
                ) {
                    Text(AppLocalization.string("Turns a day", table: .rooms)).foregroundStyle(.secondary)
                }
                Text(AppLocalization.string(
                    "The most turns it takes in this room each day. Once they're used up, it says so and sits out until tomorrow.", table: .rooms
                ))
                .settingsCaption()
            }
        }
        .onChange(of: choices) { _, _ in Haptics.selection() }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// What it can do: Use my data where the plugin shares when you're busy,
    /// else while it's the choice; Custom while it's the choice.
    private var toolChoices: [(id: String, title: String)] {
        var shown: [(id: String, title: String)] = [
            (id: "talk", title: AppLocalization.string("Talk only", table: .rooms)),
            (id: "look", title: AppLocalization.string("Look things up", table: .rooms)),
        ]
        if RoomChoices.offersUseMyData(freeBusy: offersData, current: [original.tools, choices.tools]) {
            shown.append((id: "data", title: AppLocalization.string("Use my data", table: .rooms)))
        }
        if original.tools == "custom" || choices.tools == "custom" {
            shown.append((id: "custom", title: AppLocalization.string("Custom")))
        }
        return shown
    }

    static var shareChoices: [(id: String, title: String)] {
        [(id: "helps", title: AppLocalization.string("What helps", table: .rooms)),
         (id: "ask", title: AppLocalization.string("Ask me first", table: .rooms)),
         (id: "nothing", title: AppLocalization.string("Nothing personal", table: .rooms))]
    }

    static var takesPartChoices: [(id: String, title: String)] {
        [(id: "joins", title: AppLocalization.string("Joins in", table: .rooms)),
         (id: "asked", title: AppLocalization.string("When asked", table: .rooms)),
         (id: "listens", title: AppLocalization.string("Listens only", table: .rooms))]
    }

    /// The card's line under a bot brought: each choice, briefly.
    static func summary(_ choices: RoomChoices) -> String {
        let turnCount = choices.dailyLimit
        return [
            toolsLabel(choices.tools),
            shareLabel(choices.share),
            takesPartLabel(choices.takesPart),
            AppLocalization.string("Turns a day: \(turnCount)", table: .rooms),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    static func toolsLabel(_ tools: String) -> String {
        switch tools {
        case "talk": return AppLocalization.string("Talk only", table: .rooms)
        case "look": return AppLocalization.string("Look things up", table: .rooms)
        case "data": return AppLocalization.string("Use my data", table: .rooms)
        case "custom": return AppLocalization.string("Custom")
        default: return ""
        }
    }

    static func shareLabel(_ share: String) -> String {
        switch share {
        case "helps": return AppLocalization.string("What helps", table: .rooms)
        case "ask": return AppLocalization.string("Ask me first", table: .rooms)
        case "nothing": return AppLocalization.string("Nothing personal", table: .rooms)
        default: return ""
        }
    }

    static func takesPartLabel(_ takesPart: String) -> String {
        switch takesPart {
        case "joins": return AppLocalization.string("Joins in", table: .rooms)
        case "asked": return AppLocalization.string("When asked", table: .rooms)
        case "listens": return AppLocalization.string("Listens only", table: .rooms)
        default: return ""
        }
    }

    /// What each way of taking part means (room_bridge_member.py).
    static func takesPartDetail(_ takesPart: String) -> String {
        switch takesPart {
        case "joins":
            return AppLocalization.string("It takes its turns in the room as the other agents do.", table: .rooms)
        case "asked":
            return AppLocalization.string("It answers only when a new message @mentions it, or @all.", table: .rooms)
        case "listens":
            return AppLocalization.string("It reads along but never answers.", table: .rooms)
        default:
            return ""
        }
    }

    private static func number(_ value: Int) -> String {
        value.formatted(.number.locale(AppLocalization.formattingLocale))
    }
}
