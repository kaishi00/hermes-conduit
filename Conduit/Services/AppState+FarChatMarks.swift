//
//  AppState+FarChatMarks.swift
//  Conduit
//
//  Done marks and mutes of the other combined dashboards' chats: each
//  dashboard's plugin keeps its own, so a chat opened in place is marked
//  done and muted on its own dashboard, and its row shows it, without a
//  switch (AppState+ChatDone.swift and AppState+ChatMute.swift read and
//  write them through that dashboard's kept bridge). Its star is kept on
//  this phone under its own dashboard, and its read flag is Hermes' there.
//

import Foundation

extension AppState {
    /// Where a row's Done mark and mute are kept: its own dashboard's
    /// plugin, reached through that dashboard's bridge.
    struct ChatMarksHome {
        let dashboardID: UUID?
        let bridge: DashboardTicketBridge
        let profile: String
        /// The row as its own dashboard lists it.
        let session: SessionSummary
        let plugin: NotifierPluginStatus
    }

    /// Nil when the row's dashboard isn't connected: the one on screen
    /// without a bridge, or another combined one that isn't kept.
    func chatMarksHome(_ session: SessionSummary) -> ChatMarksHome? {
        guard let far = session.combinedDashboardID else {
            guard let bridge = dashboardTicketBridge else { return nil }
            return ChatMarksHome(dashboardID: activeDashboardID, bridge: bridge, profile: rowProfile(session),
                                 session: session, plugin: notifierPlugin)
        }
        guard far != dashboardIDOnScreen, let kept = keptDashboardRuntimes[far] else { return nil }
        let (row, profile) = farChatMarksRow(session, in: far)
        return ChatMarksHome(dashboardID: far, bridge: kept.bridge, profile: profile, session: row,
                             plugin: kept.runtime.notifierPlugin)
    }

    /// Another combined dashboard's row as its own dashboard lists it, and
    /// its profile spelled as that dashboard lists its profiles, which its
    /// reads use. Needs no connection: a dashboard that dropped keeps its
    /// rows, and they keep the marks read last.
    func farChatMarksRow(_ session: SessionSummary, in far: UUID) -> (row: SessionSummary, profile: String) {
        var row = session
        row.combinedDashboardID = nil
        let owner = session.profile.flatMap { $0.isEmpty ? nil : $0 }
            ?? keptDashboardRuntimes[far]?.runtime.activeProfile
            ?? rememberedActiveProfile(for: far) ?? "default"
        let profile = keptDashboardProfiles[far]?.profiles.first { Self.profilesMatch($0, owner) } ?? owner
        return (row, profile)
    }

    /// A dashboard's bridge as it's connected now: the one on screen's, or
    /// a kept one's.
    func chatMarksBridge(_ dashboardID: UUID?) -> DashboardTicketBridge? {
        guard dashboardID != dashboardIDOnScreen else { return runtimeOnScreen.dashboardTicketBridge }
        return dashboardID.flatMap { keptDashboardRuntimes[$0]?.bridge }
    }

    func doneMarks(of dashboardID: UUID?) -> ChatDoneMarks {
        guard dashboardID != dashboardIDOnScreen else { return chatDoneMarks }
        return dashboardID.flatMap { farChatDoneMarks[$0] } ?? ChatDoneMarks(dashboardID: dashboardID)
    }

    func keepChatDoneMarks(_ marks: ChatDoneMarks, of dashboardID: UUID?) {
        guard dashboardID != dashboardIDOnScreen else {
            if marks != chatDoneMarks { chatDoneMarks = marks }
            return
        }
        if let dashboardID, farChatDoneMarks[dashboardID] != marks { farChatDoneMarks[dashboardID] = marks }
    }

    func mutes(of dashboardID: UUID?) -> ChatMutes {
        guard dashboardID != dashboardIDOnScreen else { return chatMutes }
        return dashboardID.flatMap { farChatMutes[$0] } ?? ChatMutes(dashboardID: dashboardID)
    }

    func keepChatMutes(_ mutes: ChatMutes, of dashboardID: UUID?) {
        guard dashboardID != dashboardIDOnScreen else {
            if mutes != chatMutes { chatMutes = mutes }
            return
        }
        if let dashboardID, farChatMutes[dashboardID] != mutes { farChatMutes[dashboardID] = mutes }
    }

    /// How often another combined dashboard's Done marks and mutes are
    /// read: as often as its chats (`combinedDashboardChatsMaxAge`), above
    /// the Needs you pass's 20 s, so a pass inside it reads none (issue
    /// 3282). A mark made here shows at once and holds reads back while it
    /// saves; a pull on the list reads at once.
    static let farChatMarksReadInterval: TimeInterval = combinedDashboardChatsMaxAge

    /// Reads another combined dashboard's Done marks and mutes for
    /// `profiles`, with its chat list: each at most every `farChatMarksReadInterval`, and only
    /// what its plugin keeps.
    func refreshFarChatMarks(_ dashboardID: UUID, profiles: [String], force: Bool = false, now: Date = Date()) {
        guard dashboardID != dashboardIDOnScreen, let kept = keptDashboardRuntimes[dashboardID] else { return }
        // One signed in quietly hasn't read what its plugin serves: the
        // report its bridge already gave, or a read whose answer the next
        // pass finds.
        ensureKeptPluginReport(for: dashboardID)
        let plugin = kept.runtime.notifierPlugin
        if V2ShellPreference.isOn, plugin.reports(ChatDoneMarks.capability) {
            readChatDoneMarks(dashboardID: dashboardID, bridge: kept.bridge, profiles: profiles, force: force,
                              interval: Self.farChatMarksReadInterval, now: now)
        }
        if plugin.reports(ChatMutes.capability) {
            readChatMutes(dashboardID: dashboardID, bridge: kept.bridge, profiles: profiles, force: force,
                          interval: Self.farChatMarksReadInterval, now: now)
        }
    }

    /// The Chats list offers In progress and Done: its own dashboard keeps
    /// Done marks, or another combined one whose rows it shows does. A row
    /// is still marked only where its own dashboard keeps them.
    var chatDoneFilterAvailable: Bool {
        if chatDoneAvailable { return true }
        // Their rows are listed only in All.
        guard V2ShellPreference.isOn, isAllProfilesChatsOn, isInCombinedGroup(dashboardIDOnScreen) else { return false }
        return keptDashboardRuntimes.contains {
            $0.key != dashboardIDOnScreen && isInCombinedGroup($0.key)
                && $0.value.runtime.notifierPlugin.reports(ChatDoneMarks.capability)
        }
    }

    /// Lets go of the marks of a dashboard that left the group or came on
    /// screen, where `chatDoneMarks` and `chatMutes` hold its own.
    func dropFarChatMarksOutsideTheGroup() {
        let gone = Set(farChatDoneMarks.keys).union(farChatMutes.keys).union(farSessionStarsByDashboard.keys)
            .filter { !isInCombinedGroup($0) || $0 == dashboardIDOnScreen }
        guard !gone.isEmpty else { return }
        if farChatDoneMarks.keys.contains(where: { gone.contains($0) }) {
            farChatDoneMarks = farChatDoneMarks.filter { !gone.contains($0.key) }
        }
        if farChatMutes.keys.contains(where: { gone.contains($0) }) {
            farChatMutes = farChatMutes.filter { !gone.contains($0.key) }
        }
        // Its stars stay on this phone; only the copy read for its rows goes.
        farSessionStarsByDashboard = farSessionStarsByDashboard.filter { !gone.contains($0.key) }
    }

    // MARK: - Stars and the read flag

    /// The dashboard another combined dashboard's row is kept on; nil for
    /// the dashboard on screen's own rows.
    func farMarksDashboard(_ session: SessionSummary) -> UUID? {
        guard let far = session.combinedDashboardID, far != dashboardIDOnScreen else { return nil }
        return far
    }

    /// Another combined dashboard's stars: the ones this phone keeps under
    /// that dashboard, which its own Chats list shows once it's on screen.
    func farSessionStars(_ far: UUID) -> SessionStars {
        if let read = farSessionStarsByDashboard[far] { return read }
        let stars = SessionStars(defaults: defaults, scope: Self.dashboardPreferenceBucket(far))
        farSessionStarsByDashboard[far] = stars
        return stars
    }

    /// A far row and the profile its star is kept under, spelled as the
    /// stars already spell it.
    private func farStarRow(_ session: SessionSummary, in far: UUID, stars: SessionStars) -> (row: SessionSummary, profile: String) {
        let (row, profile) = farChatMarksRow(session, in: far)
        return (row, stars.idsByProfile.keys.first { Self.profilesMatch($0, profile) } ?? profile)
    }

    func isFarSessionStarred(_ session: SessionSummary, in far: UUID) -> Bool {
        let stars = farSessionStars(far)
        let (row, profile) = farStarRow(session, in: far, stars: stars)
        return stars.isStarred(row, profile: profile)
    }

    func toggleFarSessionStarred(_ session: SessionSummary, in far: UUID) {
        var stars = farSessionStars(far)
        let (row, profile) = farStarRow(session, in: far, stars: stars)
        stars.set(row, starred: !stars.isStarred(row, profile: profile), profile: profile)
        objectWillChange.send()
        farSessionStarsByDashboard[far] = stars
        stars.save(to: defaults, scope: Self.dashboardPreferenceBucket(far))
    }

    /// A chat deleted on another combined dashboard takes its star with
    /// it, from that dashboard's stars and never the ones in use.
    func dropFarSessionStar(_ session: SessionSummary, profile: String, in far: UUID) {
        var stars = farSessionStars(far)
        var row = session
        row.combinedDashboardID = nil
        let key = stars.idsByProfile.keys.first { Self.profilesMatch($0, profile) } ?? profile
        guard stars.isStarred(row, profile: key) else { return }
        stars.set(row, starred: false, profile: key)
        objectWillChange.send()
        farSessionStarsByDashboard[far] = stars
        stars.save(to: defaults, scope: Self.dashboardPreferenceBucket(far))
    }

    /// Hermes deleted a chat of `dashboardID`'s: its star goes from that
    /// dashboard's stars wherever they're kept now, whether or not the
    /// delete's answer is still the screen's (taken up to the screen
    /// meanwhile, or its kept connection let go), so Starred never lists a
    /// chat that's gone (issue 3252).
    func dropDeletedChatStar(_ session: SessionSummary, profile: String, in dashboardID: UUID?) {
        guard let dashboardID else { return }
        guard dashboardID == dashboardIDOnScreen else {
            dropFarSessionStar(session, profile: profile, in: dashboardID)
            return
        }
        var row = session
        row.combinedDashboardID = nil
        let key = sessionStars.idsByProfile.keys.first { Self.profilesMatch($0, profile) } ?? profile
        guard sessionStars.isStarred(row, profile: key) else { return }
        setSessionStarred(row, starred: false, profile: key)
    }

    /// Hermes' read flag as that dashboard's list last gave it, or as it
    /// was set here since.
    func isFarSessionUnread(_ session: SessionSummary, in far: UUID) -> Bool {
        let (row, profile) = farChatMarksRow(session, in: far)
        return farListedRow(row, profile: profile, in: far)?.isUnread ?? session.isUnread ?? false
    }

    private func farListedRow(_ row: SessionSummary, profile: String, in far: UUID) -> SessionSummary? {
        combinedDashboardChats[far]?.sessions.first {
            $0.id == row.id && Self.profilesMatch($0.profile ?? "default", profile)
        }
    }

    /// A far row's read-flag changes still on their way: the number of the
    /// last one made, and the flag Hermes took last (what the row showed
    /// before the first of them, until one is answered).
    struct FarReadFlagChange {
        var generation: UInt64
        var accepted: Bool?
    }

    private func farReadFlagKey(_ row: SessionSummary, profile: String, in far: UUID) -> String {
        "\(far.uuidString)\u{1F}\(profile.lowercased())\u{1F}\(row.id)"
    }

    /// Sets Hermes' read flag for another combined dashboard's chats, on
    /// that dashboard through its kept connection, one at a time and in
    /// the order they were made, so the last change made is the one kept.
    /// Each row shows it at once. Only a row's last change settles what it
    /// shows: an earlier one's answer leaves the later one showing, and a
    /// refused last one puts back the flag Hermes took last.
    func setFarSessionsUnread(_ sessions: [SessionSummary], in far: UUID, unread: Bool) {
        guard let bridge = keptDashboardRuntimes[far]?.bridge else {
            showSessionMutationNotice(AppLocalization.string("Reconnect to Hermes to change this conversation."))
            return
        }
        let rows = sessions.map { farChatMarksRow($0, in: far) }
        let changes = rows.map { entry -> (key: String, generation: UInt64) in
            let key = farReadFlagKey(entry.row, profile: entry.profile, in: far)
            let shown = keepFarRowUnread(entry.row, profile: entry.profile, in: far, unread: unread)
            var change = farReadFlagChanges[key] ?? FarReadFlagChange(generation: 0, accepted: shown)
            change.generation += 1
            farReadFlagChanges[key] = change
            return (key, change.generation)
        }
        let previous = farReadFlagWriteTail[far]
        let write = Task { @MainActor [weak self] in
            await previous?.value
            for (index, entry) in rows.enumerated() {
                guard let self else { return }
                let (key, generation) = changes[index]
                do {
                    _ = try await self.sendSessionMutation(entry.row.id, body: ["unread": unread], profile: entry.profile,
                                                           bridge: bridge)
                    self.farReadFlagChanges[key]?.accepted = unread
                    // A later change to this row shows already: its own
                    // answer settles the row.
                    guard self.farReadFlagChanges[key]?.generation == generation else { continue }
                    self.farReadFlagChanges[key] = nil
                    // Again, and stamped again, though it may show it
                    // already: a list read that started or landed while
                    // the write was out could put the old flag back.
                    self.keepFarRowUnread(entry.row, profile: entry.profile, in: far, unread: unread)
                } catch {
                    sessionCatalogLog.notice("Read flag not saved: \(LogRedaction.describing(error), privacy: .public)")
                    guard self.farReadFlagChanges[key]?.generation == generation else { continue }
                    let accepted = self.farReadFlagChanges[key]?.accepted
                    self.farReadFlagChanges[key] = nil
                    if let accepted {
                        self.keepFarRowUnread(entry.row, profile: entry.profile, in: far, unread: accepted)
                    }
                }
            }
        }
        farReadFlagWriteTail[far] = write
        Task { @MainActor [weak self] in
            await write.value
            if self?.farReadFlagWriteTail[far] == write { self?.farReadFlagWriteTail[far] = nil }
        }
    }

    /// Shows a far row's read flag on its list, stamped so a list read
    /// started before it can't put the old one back. Returns what it
    /// showed before; nil when its list doesn't hold the row.
    @discardableResult
    private func keepFarRowUnread(_ row: SessionSummary, profile: String, in far: UUID, unread: Bool) -> Bool? {
        guard let chats = combinedDashboardChats[far],
              let index = chats.sessions.firstIndex(where: {
                  $0.id == row.id && Self.profilesMatch($0.profile ?? "default", profile)
              }) else { return nil }
        var sessions = chats.sessions
        let before = sessions[index].isUnread == true
        sessions[index].isUnread = unread
        combinedDashboardChats[far] = CombinedDashboardChats(
            bridge: chats.bridge,
            profiles: chats.profiles,
            sessions: sessions,
            at: chats.at,
            seededAt: Date(),
            cronIDs: chats.cronIDs,
            cronAt: chats.cronAt,
            unreadProfiles: chats.unreadProfiles
        )
        return before
    }
}
