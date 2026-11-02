//
//  PeopleSettingsViews.swift
//  Conduit
//
//  Settings > People (designs/cross-owner-agents, C2): getting this Hermes
//  ready for rooms with other people's agents (RoomSetup.swift), the people
//  it's linked with, and the invites still waiting (RoomLinks.swift). Link
//  with someone makes an invite, and Scan and Paste open one someone sent
//  (RoomLinkSheets.swift). Each Link's rules say what that person's Hermes
//  may ask yours (LinkAsks.swift, C7).
//

import OSLog
import SwiftUI

private let peopleLogger = Logger(subsystem: "com.milim.relay", category: "People")

/// What Settings > People says, apart from its views.
enum PeopleSettingsText {
    /// A Link's status, or nil for one a newer plugin added.
    static func status(of link: RoomLink) -> String? {
        switch link.status {
        case "linked":
            return AppLocalization.string("Linked")
        case "waiting":
            return AppLocalization.string("Waiting for \(link.name)'s Hermes to confirm")
        case "unanswered":
            return AppLocalization.string("\(link.name)'s Hermes never confirmed. Ask them for a new invite.")
        default:
            return nil
        }
    }

    /// What Set up does, one line each, in the order the plugin does it.
    static func setupLines(_ state: RoomSetupState, profileName: String) -> [String] {
        let changes = Set(state.changes)
        let address = state.apiServer.address
        var lines: [String] = []
        if changes.contains("api_server_key") {
            lines.append(AppLocalization.string("Turn on Hermes' API server at \(address), with a new key that stays on your Hermes"))
        } else if changes.contains("api_server_enabled") || changes.contains("api_server_port") {
            lines.append(AppLocalization.string("Turn on Hermes' API server at \(address), with the key it has"))
        }
        if changes.contains("profile_key") {
            lines.append(AppLocalization.string("Give \(profileName) its own key for the API server, which serves a profile's agent only with that profile's key"))
        }
        if changes.contains("ceiling") {
            lines.append(AppLocalization.string("Save the tools rooms may let \(profileName) use"))
        }
        if changes.contains("plugin_tools") {
            lines.append(AppLocalization.string("Keep tools that plugins and Hermes updates add out of rooms until you add them here"))
        }
        if changes.contains("approvals") {
            lines.append(AppLocalization.string("Turn \(profileName)'s approvals back on, since rooms refuse an agent that runs tools without asking"))
        }
        if state.needs.contains("restart") {
            lines.append(AppLocalization.string("Restart the gateway, which starts the API server"))
        }
        return lines
    }

    /// The tools rooms may let the profile's agent use.
    static func tools(_ state: RoomSetupState, profileName: String) -> String {
        let labels = state.ceiling.map(state.label(of:))
        guard !labels.isEmpty else {
            return AppLocalization.string("Rooms can't let \(profileName) use tools: it only talks there.")
        }
        let list = labels.formatted(.list(type: .and).locale(AppLocalization.formattingLocale))
        return AppLocalization.string("Rooms may let \(profileName) use \(list).")
    }

    /// The MCP servers rooms may let the profile's agent use, or nil with none.
    static func mcpServers(_ state: RoomSetupState, profileName: String) -> String? {
        guard !state.mcpServers.isEmpty else { return nil }
        let list = state.mcpServers.formatted(.list(type: .and).locale(AppLocalization.formattingLocale))
        return AppLocalization.string("MCP servers too: \(list), in rooms whose Custom choice names their tools.")
    }

    /// Four fingerprint words, as both sides read them out.
    static func words(_ words: [String]) -> String {
        words.joined(separator: " · ")
    }
}

/// Settings > People: this Hermes' setup for rooms with other people's
/// agents, the people it's linked with and the invites waiting. Shown while
/// the host's plugin keeps Links (`room-links`).
@MainActor
struct PeopleSettingsPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState

    /// What the plugin answered, and for which dashboard.
    private struct Loaded {
        let key: String
        let list: RoomLinksList
        let identity: RoomIdentity
    }

    @State private var loaded: Loaded?
    @State private var loadError: String?
    /// A read that failed once the page showed the Links, which stay up.
    @State private var refreshError: String?
    @State private var actionError: String?
    /// The Link or invite a request is changing: one at a time. A request
    /// lets go of it only while it's still its own, as another dashboard's
    /// can start once the page shows that one.
    @State private var changingID: String?
    @State private var unlinking: RoomLink?
    @State private var linking = false
    @State private var scanning = false
    /// What the scanner read, opened once its sheet has closed: one sheet
    /// can't show over another.
    @State private var scanned: RoomLinkURL?
    @State private var opened: RoomLinkURL?
    @State private var pasteError: String?

    /// Links are the installation's, so the dashboard is the whole key.
    private var key: String { appState.activeDashboardID?.uuidString ?? "" }

    private var shown: Loaded? { loaded?.key == key ? loaded : nil }

    /// While a Link waits for the other side's Hermes, the page reads the
    /// list again now and then. Sorted, so the same Links in another order
    /// don't start the wait over.
    private var waitingIDs: [String] {
        shown?.list.links.filter { $0.status == "waiting" }.map(\.id).sorted() ?? []
    }

    var body: some View {
        let profile = appState.activeProfile
        SettingsDetailContainer {
            if appState.canSetUpRooms {
                RoomSetupSection(profile: profile, profileName: appState.profileDisplayName(profile))
            } else {
                ConduitSettingsSection(title: AppLocalization.string("This Hermes"), symbol: "server.rack", tint: .conduitAura) {
                    Text(AppLocalization.string("Update the Conduit plugin on your Hermes host to set it up for rooms from here."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            linksSection
            // What each linked person's Hermes may ask yours, on a plugin that answers asks.
            if appState.canSetLinkAsks, let links = shown?.list.links.filter({ $0.status == "linked" }), !links.isEmpty {
                LinkAsksSection(linkIDs: links.map(\.id))
            }
            if let invites = shown?.list.invites, !invites.isEmpty {
                invitesSection(invites)
            }
        }
        .navigationTitle(Text(AppLocalization.string("People")))
        .task(id: key) { await load(key) }
        .task(id: waitingIDs) { await followWaitingLinks() }
        .confirmationDialog(unlinkTitle, isPresented: unlinkPresented, titleVisibility: .visible, presenting: unlinking) { link in
            Button(AppLocalization.string("Unlink"), role: .destructive) { unlink(link) }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: { link in
            Text(AppLocalization.string("This unlinks \(link.name)'s Hermes from yours, on both sides. Linking again takes a new invite."))
        }
        .sheet(isPresented: $linking, onDismiss: { Task { await load(key) } }) {
            RoomLinkInviteSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $scanning, onDismiss: { openScanned() }) {
            DashboardCodeScannerSheet(purpose: .linkInvite) { text in
                guard let invite = RoomLinkURL(text) else { return false }
                scanned = invite
                scanning = false
                return true
            }
        }
        .sheet(item: $opened, onDismiss: { Task { await load(key) } }) { invite in
            RoomLinkOpenedSheet(invite: invite)
                .environmentObject(appState)
        }
    }

    private func openScanned() {
        guard let scanned else { return }
        self.scanned = nil
        opened = scanned
    }

    private var unlinkTitle: String {
        guard let unlinking else { return "" }
        return AppLocalization.string("Unlink \(unlinking.name)?")
    }

    private var unlinkPresented: Binding<Bool> {
        Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } })
    }

    private var linksSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Linked with"), symbol: "link", tint: .conduitAccent) {
            Text(AppLocalization.string("A Link lets you and someone else bring your agents into rooms together. It grants nothing by itself: in each room, you choose what your agents may do."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let shown {
                linkActions(shown.identity)
                yourWords(shown.identity)
                // Nothing waits in the mailbox without a Link or an invite.
                if !shown.list.mailboxReading, !shown.list.links.isEmpty || !shown.list.invites.isEmpty {
                    Label(AppLocalization.string("Nothing on your Hermes reads its rooms mailbox right now, so what the other side sends waits there, for up to 7 days."), systemImage: "tray.and.arrow.down")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button(AppLocalization.string("Check again")) { Task { await load(key) } }
                        .buttonStyle(.settings)
                        .disabled(changingID != nil)
                }
                if shown.list.links.isEmpty {
                    Text(AppLocalization.string("No Links yet."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shown.list.links) { link in
                        linkRow(link)
                    }
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button(AppLocalization.string("Try again")) { Task { await load(key) } }
                    .buttonStyle(.settings)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            if let refreshError {
                Label(refreshError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button(AppLocalization.string("Try again")) { Task { await load(key) } }
                    .buttonStyle(.settings)
                    .disabled(changingID != nil)
            }
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Link with someone, and an invite someone sent: scanned from their
    /// phone or pasted. A Hermes that can't make Links offers none.
    @ViewBuilder
    private func linkActions(_ identity: RoomIdentity) -> some View {
        Button {
            Haptics.selection()
            pasteError = nil
            linking = true
        } label: {
            Label(AppLocalization.string("Link with someone"), systemImage: "link.badge.plus")
        }
        .buttonStyle(.settingsPrimary)
        .disabled(!identity.crypto)
        HStack(spacing: 10) {
            Text(AppLocalization.string("Have an invite?"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                Haptics.selection()
                pasteError = nil
                scanning = true
            } label: {
                Label(AppLocalization.string("Scan"), systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.conduitAccent)
            // The system paste control: it reads the clipboard only when
            // tapped, so iOS asks nothing first.
            PasteButton(payloadType: String.self) { strings in
                let found = strings.compactMap(RoomLinkURL.find(in:)).first
                Task { @MainActor in
                    if let found {
                        pasteError = nil
                        opened = found
                    } else {
                        pasteError = AppLocalization.string("The clipboard has no Link invite.")
                    }
                }
            }
            .buttonBorderShape(.capsule)
            .labelStyle(.titleAndIcon)
            .tint(.conduitAccent)
        }
        .disabled(!identity.crypto)
        if let pasteError {
            Text(verbatim: pasteError)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func yourWords(_ identity: RoomIdentity) -> some View {
        if !identity.crypto {
            Label(AppLocalization.string("This Hermes can't make Links: Linked Rooms needs Python's cryptography package, which it doesn't have. Install it where Hermes runs, then restart Hermes' dashboard."), systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else if let words = identity.words {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("Your Hermes' words"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(verbatim: PeopleSettingsText.words(words))
                    .font(.body.weight(.semibold))
                    .textSelection(.enabled)
                Text(AppLocalization.string("Someone opening your invite sees these four words. Read them to each other: if theirs match, the invite is yours."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(AppLocalization.string("Your Hermes gets its four words when it first makes or accepts an invite."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func linkRow(_ link: RoomLink) -> some View {
        let words = PeopleSettingsText.words(link.words)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: link.name)
                    .font(.subheadline.weight(.semibold))
                if let status = PeopleSettingsText.status(of: link) {
                    Text(verbatim: status)
                        .font(.footnote)
                        .foregroundStyle(link.status == "unanswered" ? Color.orange : Color.secondary)
                }
                Text(verbatim: AppLocalization.string("Words: \(words)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if changingID == link.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(AppLocalization.string("Unlink"), role: .destructive) { unlinking = link }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .disabled(changingID != nil)
                    .accessibilityValue(Text(verbatim: link.name))
            }
        }
    }

    private func invitesSection(_ invites: [RoomLinkInvite]) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Invites waiting"), symbol: "envelope", tint: .conduitAccent) {
            Text(AppLocalization.string("Each invite works once, for whoever opens it first, until it runs out."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(invites) { invite in
                inviteRow(invite)
            }
        }
    }

    private func inviteRow(_ invite: RoomLinkInvite) -> some View {
        let until = invite.expiresAt.formatted(
            .dateTime.weekday(.abbreviated).hour().minute().locale(AppLocalization.formattingLocale)
        )
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: AppLocalization.string("Shows you as \(invite.name)"))
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: AppLocalization.string("Works until \(until)"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if changingID == invite.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(AppLocalization.string("Cancel invite"), role: .destructive) { cancel(invite) }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .disabled(changingID != nil)
                    .accessibilityValue(Text(verbatim: [invite.name, until].formatted(.list(type: .and, width: .narrow).locale(AppLocalization.formattingLocale))))
            }
        }
    }

    /// Reads the Links and this Hermes' words, or only the Links when
    /// `keepingIdentity`, as the words don't change once it has them. A read
    /// that fails once the page shows them leaves them up and says so, until
    /// one works again.
    private func load(_ key: String, keepingIdentity: Bool = false) async {
        if loaded?.key != key {
            loaded = nil
            refreshError = nil
            actionError = nil
            pasteError = nil
            changingID = nil
            unlinking = nil
        }
        loadError = nil
        let client = appState.roomLinksClient
        do {
            let list = try await client.list()
            let identity: RoomIdentity
            if keepingIdentity, loaded?.key == key, let known = loaded?.identity {
                identity = known
            } else {
                identity = try await client.identity()
            }
            guard key == self.key else { return }
            loaded = Loaded(key: key, list: list, identity: identity)
            refreshError = nil
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, key == self.key else { return }
            peopleLogger.notice("Links not read: \(LogRedaction.message(error), privacy: .public)")
            let text = AppLocalization.string("Could not read your Links: \(RoomLinksClient.message(for: error))")
            if loaded?.key == key { refreshError = text } else { loadError = text }
        }
    }

    /// Every 5 s for up to 3 minutes: a confirm comes within seconds while
    /// the other Hermes runs, or not until it's back.
    private func followWaitingLinks() async {
        guard !waitingIDs.isEmpty else { return }
        let key = key
        for _ in 0..<36 {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, key == self.key else { return }
            if changingID != nil { continue }
            await load(key, keepingIdentity: true)
            if waitingIDs.isEmpty { return }
        }
    }

    private func unlink(_ link: RoomLink) {
        guard changingID == nil else { return }
        let key = key
        changingID = link.id
        actionError = nil
        Task {
            defer { if changingID == link.id { changingID = nil } }
            do {
                // False when it was already gone: the list says the same.
                _ = try await appState.roomLinksClient.unlink(link.id)
                guard key == self.key else { return }
                Haptics.success()
            } catch {
                guard !(error is CancellationError), key == self.key else { return }
                Haptics.error()
                peopleLogger.notice("Link not removed: \(LogRedaction.message(error), privacy: .public)")
                actionError = AppLocalization.string("Could not unlink \(link.name): \(RoomLinksClient.message(for: error))")
            }
            await load(key)
            // One whose answer didn't come may have gone through: the list says.
            if loaded?.key == key, loaded?.list.links.contains(where: { $0.id == link.id }) == false { actionError = nil }
        }
    }

    private func cancel(_ invite: RoomLinkInvite) {
        guard changingID == nil else { return }
        let key = key
        changingID = invite.id
        actionError = nil
        Task {
            defer { if changingID == invite.id { changingID = nil } }
            do {
                // False when it was used or ran out meanwhile.
                _ = try await appState.roomLinksClient.cancel(inviteID: invite.id)
                guard key == self.key else { return }
                Haptics.success()
            } catch {
                guard !(error is CancellationError), key == self.key else { return }
                Haptics.error()
                peopleLogger.notice("Invite not cancelled: \(LogRedaction.message(error), privacy: .public)")
                actionError = AppLocalization.string("Could not cancel the invite: \(RoomLinksClient.message(for: error))")
            }
            await load(key)
            if loaded?.key == key, loaded?.list.invites.contains(where: { $0.id == invite.id }) == false { actionError = nil }
        }
    }
}

/// What each linked person's Hermes may ask yours (LinkAsks.swift): whether
/// you're free on a date and questions, and the profile that answers when
/// there's more than one. Read once the page shows the Links, and again when
/// they change.
@MainActor
struct LinkAsksSection: View {
    /// The Links the page shows as linked, in its order.
    let linkIDs: [String]

    @EnvironmentObject private var appState: AppState

    @State private var loaded: (key: String, links: [LinkAskRulesEntry])?
    @State private var loadError: String?
    @State private var actionError: String?
    /// The Link a change is saving: one at a time.
    @State private var changingID: String?

    private var key: String { (appState.activeDashboardID?.uuidString ?? "") + "|" + linkIDs.joined(separator: ",") }

    private var shown: [LinkAskRulesEntry] {
        guard let loaded, loaded.key == key else { return [] }
        let byID = Dictionary(loaded.links.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return linkIDs.compactMap { byID[$0] }
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("What they can ask"), symbol: "questionmark.bubble", tint: .conduitAccent) {
            Text(AppLocalization.string("A linked person's Hermes can ask yours whether you're free on a date, or ask you a question. You choose how each is answered. Nothing else they send is answered."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if loaded?.key == key {
                ForEach(shown) { link in
                    linkRules(link)
                }
                // A read again that failed leaves the rules up and says so.
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button(AppLocalization.string("Try again")) { Task { await load(key) } }
                        .buttonStyle(.settings)
                        .disabled(changingID != nil)
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button(AppLocalization.string("Try again")) { Task { await load(key) } }
                    .buttonStyle(.settings)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .task(id: key) { await load(key) }
    }

    private func linkRules(_ link: LinkAskRulesEntry) -> some View {
        let profiles = appState.profiles
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: AppLocalization.string("What \(link.name)'s Hermes can ask"))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if changingID == link.id {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            ConduitMenuPicker(
                value: link.rules.freeOn,
                choices: LinkAskRules.freeOnChoices.map { (id: $0, title: LinkAskText.freeOnTitle($0)) },
                onSelect: { change(link, "free_on", to: $0) }
            ) {
                Text(AppLocalization.string("Free on a date")).foregroundStyle(.secondary)
            }
            ConduitMenuPicker(
                value: link.rules.questions,
                choices: LinkAskRules.questionChoices.map { (id: $0, title: LinkAskText.questionsTitle($0)) },
                onSelect: { change(link, "questions", to: $0) }
            ) {
                Text(AppLocalization.string("Questions")).foregroundStyle(.secondary)
            }
            // Only one profile: it's the one that answers.
            if profiles.count > 1 {
                ConduitMenuPicker(
                    value: link.rules.profile,
                    choices: (profiles.contains(link.rules.profile) ? profiles : profiles + [link.rules.profile])
                        .map { (id: $0, title: appState.profileDisplayName($0)) },
                    onSelect: { change(link, "profile", to: $0) }
                ) {
                    Text(AppLocalization.string("Answered by")).foregroundStyle(.secondary)
                }
            }
            Text(verbatim: LinkAskText.caption(link.rules, name: link.name,
                                               profileName: appState.profileDisplayName(link.rules.profile)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(changingID != nil)
    }

    private func load(_ key: String) async {
        loadError = nil
        do {
            let links = try await appState.linkAsksClient.rules()
            guard key == self.key else { return }
            loaded = (key, links)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, key == self.key else { return }
            peopleLogger.notice("Link rules not read: \(LogRedaction.message(error), privacy: .public)")
            loadError = AppLocalization.string("Could not read what they can ask: \(RoomLinksClient.message(for: error))")
        }
    }

    private func change(_ link: LinkAskRulesEntry, _ rule: String, to value: String) {
        guard changingID == nil else { return }
        let key = key
        changingID = link.id
        actionError = nil
        Task {
            defer { if changingID == link.id { changingID = nil } }
            do {
                let rules = try await appState.linkAsksClient.set([rule: value], linkID: link.id)
                guard key == self.key, let loaded, loaded.key == key else { return }
                self.loaded = (key, loaded.links.map { $0.id == link.id ? LinkAskRulesEntry(id: $0.id, name: $0.name, status: $0.status, rules: rules) : $0 })
                Haptics.selection()
            } catch {
                guard !(error is CancellationError), key == self.key else { return }
                Haptics.error()
                peopleLogger.notice("Link rules not changed: \(LogRedaction.message(error), privacy: .public)")
                actionError = AppLocalization.string("Could not change what \(link.name)'s Hermes can ask: \(RoomLinksClient.message(for: error))")
            }
        }
    }
}

/// Settings > People's host setup for the profile in use: what this Hermes
/// needs before rooms with other people's agents can reach the profile's
/// agent, and Set up, which the plugin does on the host (room_setup.py).
/// Once it's ready, Change picks the tools rooms may let the agent use.
@MainActor
struct RoomSetupSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let profile: String
    let profileName: String

    private struct Outcome {
        let text: String
        var trouble = false
        /// The API server may still come up: Check again reads it.
        var checksAgain = false
    }

    /// What the plugin answered for `loadedKey`.
    @State private var state: RoomSetupState?
    @State private var loadedKey: String?
    @State private var picked: Set<String> = []
    /// The MCP servers picked, on a plugin that can name them.
    @State private var pickedServers: Set<String> = []
    @State private var editing = false
    /// A Set up is on its way, for this profile or the one shown before:
    /// one at a time, as the plugin does them.
    @State private var working = false
    @State private var loadError: String?
    /// How the last Set up and its restart went.
    @State private var outcome: Outcome?
    /// A read that failed once the section showed what the host needs.
    @State private var refreshError: String?
    /// Hermes' words while chats run on the gateway, which restarting it
    /// now would stop.
    @State private var busyRestart: String?
    @State private var confirmsChange = false
    /// Set when the gateway restarts: the section reads the API server
    /// again until it runs or says why not.
    @State private var restartWait: UUID?
    /// The API server's error from before the restart, which the first
    /// reads after it may still show.
    @State private var errorBeforeRestart: String?
    /// The key the section shows now, which a request that comes back
    /// checks its own against: `key` there is the section's as it was, with
    /// the profile it had then.
    @State private var currentKey: String?

    private var key: String { "\(appState.activeDashboardID?.uuidString ?? "")|\(profile)" }

    private var shown: RoomSetupState? { loadedKey == key ? state : nil }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("This Hermes"), symbol: "server.rack", tint: .conduitAura) {
            if let state = shown {
                content(state)
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button(AppLocalization.string("Try again")) { Task { await load(key) } }
                    .buttonStyle(.settings)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            if let refreshError {
                Label(refreshError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button(AppLocalization.string("Try again")) { Task { await load(key) } }
                    .buttonStyle(.settings)
                    .disabled(working)
            }
            if let outcome {
                Text(verbatim: outcome.text)
                    .font(.footnote)
                    .foregroundStyle(outcome.trouble ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if outcome.checksAgain {
                    Button(AppLocalization.string("Check again")) {
                        self.outcome = nil
                        Task { await load(key) }
                    }
                    .buttonStyle(.settings)
                }
            }
        }
        .task(id: key) {
            currentKey = key
            await load(key)
        }
        .task(id: restartWait) { await followRestart() }
        .confirmationDialog(AppLocalization.string("Restart the gateway now?"), isPresented: busyPresented, titleVisibility: .visible) {
            Button(AppLocalization.string("Restart now"), role: .destructive) { setUp(interrupt: true) }
            Button(AppLocalization.string("Later"), role: .cancel) {}
        } message: {
            Text(verbatim: busyMessage)
        }
        .confirmationDialog(AppLocalization.string("Change what rooms may use?"), isPresented: $confirmsChange, titleVisibility: .visible) {
            Button(AppLocalization.string("Change")) { setUp() }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            // Each room pins its members' tools, approvals and turn limit
            // when it starts (designs/cross-owner-agents, decision 13).
            Text(AppLocalization.string("\(profileName) then stops answering in rooms already started with other people's agents, which hold it to the tools it had when they started. New rooms use these."))
        }
    }

    private var busyPresented: Binding<Bool> {
        Binding(get: { busyRestart != nil }, set: { if !$0 { busyRestart = nil } })
    }

    private var busyMessage: String {
        let stops = AppLocalization.string("Chats running on it stop if it restarts now.")
        guard let words = busyRestart, !words.isEmpty else { return stops }
        return "\(words)\n\n\(stops)"
    }

    @ViewBuilder
    private func content(_ state: RoomSetupState) -> some View {
        if !state.blockers.isEmpty {
            Text(AppLocalization.string("This Hermes can't be set up for rooms yet:"))
                .font(.subheadline.weight(.semibold))
            ForEach(Array(state.blockers.enumerated()), id: \.offset) { _, blocker in
                Label(blocker.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            Button(AppLocalization.string("Check again")) {
                outcome = nil
                Task { await load(key) }
            }
            .buttonStyle(.settings)
            .disabled(working)
        } else if state.ready && !editing {
            Label(AppLocalization.string("Ready for rooms"), systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            SettingsMetricRow(label: AppLocalization.string("API server"), value: state.apiServer.address, statusDot: .green, lineLimit: 1)
            Text(verbatim: PeopleSettingsText.tools(state, profileName: profileName))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let servers = PeopleSettingsText.mcpServers(state, profileName: profileName) {
                Text(verbatim: servers)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(AppLocalization.string("Change")) {
                Haptics.selection()
                picked = Set(state.ceiling)
                pickedServers = Set(state.mcpServers)
                outcome = nil
                editing = true
            }
            .buttonStyle(.settings)
            .disabled(working)
        } else {
            if !state.ready {
                Text(AppLocalization.string("Rooms reach your agents through Hermes' API server. For \(profileName), Set up will:"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(PeopleSettingsText.setupLines(state, profileName: profileName), id: \.self) { line in
                    Label(line, systemImage: "checkmark")
                        .font(.footnote)
                }
                if let error = state.apiServer.error {
                    Text(verbatim: AppLocalization.string("The API server didn't start the last time: \(error)"))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            toolChoices(state)
            if state.apiServer.enabled {
                Text(AppLocalization.string("Hermes' API server is already on, so other apps that use it with \(profileName), such as Open WebUI, get only these tools too."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if editing {
                    Button(AppLocalization.string("Cancel")) {
                        picked = Set(state.ceiling)
                        pickedServers = Set(state.mcpServers)
                        editing = false
                    }
                    .buttonStyle(.settings)
                }
                Spacer(minLength: 0)
                if working {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(editing ? AppLocalization.string("Save") : AppLocalization.string("Set up")) {
                    if state.changesSavedCeiling(picking: picked, servers: pickedServers) { confirmsChange = true } else { setUp() }
                }
                .buttonStyle(.settingsPrimary)
                .disabled(working || (editing && picked == Set(state.ceiling)
                    && state.mcpServersToSave(picking: pickedServers) == nil))
            }
        }
    }

    private func toolChoices(_ state: RoomSetupState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.string("Tools rooms may let \(profileName) use"))
                .font(.subheadline.weight(.semibold))
            ForEach(state.choices) { choice in
                Toggle(isOn: Binding(
                    get: { picked.contains(choice.id) },
                    set: { on in
                        Haptics.selection()
                        if on { picked.insert(choice.id) } else { picked.remove(choice.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: choice.label)
                            .font(.subheadline)
                        if !choice.description.isEmpty {
                            Text(verbatim: choice.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.conduitAccent)
                .disabled(working)
            }
            Text(AppLocalization.string("Each room's choices work within these. Tools added later, by a plugin, an MCP server or a Hermes update, stay out of rooms until you add them here."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let servers = state.mcpChoices, !servers.isEmpty {
                Text(AppLocalization.string("MCP servers rooms may let \(profileName) use"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 6)
                ForEach(servers, id: \.self) { server in
                    Toggle(isOn: Binding(
                        get: { pickedServers.contains(server) },
                        set: { on in
                            Haptics.selection()
                            if on { pickedServers.insert(server) } else { pickedServers.remove(server) }
                        }
                    )) {
                        Text(verbatim: server)
                            .font(.subheadline)
                    }
                    .tint(.conduitAccent)
                    .disabled(working)
                }
                Text(AppLocalization.string("Off unless you turn one on. A server's tools then work only in rooms whose Custom choice names them, and its own approvals still apply."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Reads what the host needs. The tools picked follow what it saved,
    /// except while they're being changed.
    private func load(_ key: String) async {
        guard key == currentKey else { return }
        if loadedKey != key {
            state = nil
            loadedKey = nil
            editing = false
            outcome = nil
            refreshError = nil
            busyRestart = nil
            confirmsChange = false
            restartWait = nil
        }
        loadError = nil
        do {
            let read = try await appState.roomSetupClient.state(profile: profile)
            guard key == currentKey else { return }
            show(read, key: key)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, key == currentKey else { return }
            peopleLogger.notice("Room setup not read: \(LogRedaction.message(error), privacy: .public)")
            let text = AppLocalization.string("Could not read this setting from the host: \(RoomLinksClient.message(for: error))")
            if loadedKey == key { refreshError = text } else { loadError = text }
        }
    }

    private func show(_ read: RoomSetupState, key: String) {
        let first = loadedKey != key
        state = read
        loadedKey = key
        refreshError = nil
        if first || !editing {
            picked = Set(read.ceiling)
            pickedServers = Set(read.mcpServers)
        }
    }

    /// Saves the tools picked when they changed, and sets up whatever else
    /// the host needs.
    private func setUp(interrupt: Bool = false) {
        guard let state = shown, !working else { return }
        let key = key
        let ceiling = state.ceilingToSave(picking: picked)
        let servers = state.mcpServersToSave(picking: pickedServers)
        working = true
        outcome = nil
        Task {
            defer { working = false }
            do {
                let result = try await appState.roomSetupClient.setUp(profile: profile, ceiling: ceiling, mcpServers: servers,
                                                                      interrupt: interrupt)
                guard key == currentKey else { return }
                Haptics.success()
                editing = false
                show(result.state, key: key)
                follow(result)
            } catch {
                guard !(error is CancellationError), key == currentKey else { return }
                Haptics.error()
                peopleLogger.notice("Room setup not saved: \(LogRedaction.message(error), privacy: .public)")
                outcome = Outcome(text: AppLocalization.string("Could not set this Hermes up: \(RoomLinksClient.message(for: error))"), trouble: true)
                // A blocker that came up since shows in place of Set up.
                await load(key)
            }
        }
    }

    /// What the gateway's restart did after a save. What was saved stays
    /// whatever it did.
    private func follow(_ result: RoomSetupResult) {
        guard let restart = result.restart else {
            outcome = Outcome(text: AppLocalization.string("Saved"))
            return
        }
        if restart.busy {
            outcome = Outcome(text: AppLocalization.string("Saved. The API server starts the next time the gateway restarts."))
            busyRestart = restart.error ?? ""
        } else if restart.started {
            outcome = Outcome(text: AppLocalization.string("Saved. The gateway is restarting to start the API server…"))
            errorBeforeRestart = result.state.apiServer.error
            restartWait = UUID()
        } else {
            let why = restart.error ?? AppLocalization.string("Hermes didn't say why.")
            outcome = Outcome(text: AppLocalization.string("Saved, but the gateway didn't restart: \(why)"), trouble: true)
        }
    }

    /// Every 2 s for up to 30 s after the restart starts.
    private func followRestart() async {
        guard restartWait != nil else { return }
        let key = key
        for check in 1...15 {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, key == currentKey else { return }
            guard let read = try? await appState.roomSetupClient.state(profile: profile), key == currentKey else { continue }
            show(read, key: key)
            let server = read.apiServer
            if server.running {
                outcome = Outcome(text: AppLocalization.string("The gateway restarted, and its API server runs at \(server.address)."))
                restartWait = nil
                return
            }
            // The error from before the restart counts once the new gateway
            // had time to write its own.
            if let error = server.error, error != errorBeforeRestart || check >= 5 {
                outcome = Outcome(text: AppLocalization.string("The gateway restarted, but its API server isn't running: \(error)"), trouble: true)
                restartWait = nil
                return
            }
        }
        outcome = Outcome(text: AppLocalization.string("The gateway is taking a while to start its API server."), checksAgain: true)
        restartWait = nil
    }
}
