//
//  AppState+NeedsYou.swift
//  Conduit
//
//  Hermes is waiting on you (issue 1705): reads every profile's waits from
//  the plugin (NeedsYouStore), and opens a waiting chat at its card. The
//  list, the banner and the chips only open: an approval is answered on its
//  chat's own card, which shows the whole command.
//

import Foundation

extension AppState {
    /// Whether this dashboard's plugin lists what Hermes waits on.
    var servesNeedsYou: Bool {
        notifierPlugin.reports(NeedsYouStore.capability)
    }

    /// The profiles whose waits are read: every one the strip shows.
    var needsYouProfiles: [String] {
        profiles.isEmpty ? [activeProfile] : profiles
    }

    /// Reads every profile's waits. Quiet on failure: a profile that can't
    /// be read, or a connection that dropped for a moment, keeps what it
    /// last showed; only a dashboard without the list clears it. Reads
    /// asked for while one runs (a burst of pushes) make one more read
    /// after it, never several at once.
    func refreshNeedsYou() async {
        await needsYou.coalescing { [weak self] in await self?.readNeedsYou() }
    }

    private func readNeedsYou() async {
        guard servesNeedsYou else {
            if !needsYou.items.isEmpty || needsYou.banner != nil { needsYou.reset(dashboardID: activeDashboardID) }
            return
        }
        guard isConnected, let bridge = dashboardTicketBridge else { return }
        let dashboard = activeDashboardID
        let profiles = needsYouProfiles
        for profile in profiles {
            // Off screen: keep what shows and stop before the next profile.
            guard isSceneActive else { return }
            let path = DashboardPath.withProfile(NeedsYouStore.path, profile: profile)
            guard let response = try? await bridge.requestJSON(path: path, timeoutMilliseconds: 6_000) else { continue }
            // A dashboard switch while the read was out: not this one's.
            guard dashboard == activeDashboardID else { return }
            // An answer with no list (an error body) is a failed read.
            guard let listed = response["waiting"] as? [[String: Any]] else { continue }
            let read = listed.compactMap { NeedsYouItem(host: $0, profile: profile) }
            needsYou.apply(read, profile: profile, dashboardID: dashboard) { [weak self] item in
                self?.isOpenChat(item) ?? false
            }
        }
        needsYou.forget(profilesOtherThan: Set(needsYouProfiles))
    }

    /// Reads while Conduit is on screen, every `pollInterval` seconds. The
    /// root view runs it; it ends with its task.
    func runNeedsYouPoll() async {
        while !Task.isCancelled {
            if isSceneActive { await refreshNeedsYou() }
            try? await Task.sleep(for: .seconds(PollCadence.stretched(NeedsYouStore.pollInterval, by: deviceConditions())))
        }
    }

    /// A push arrived while Conduit is on screen: a new wait reads now, so
    /// its banner shows with the push instead of on the next tick.
    func noteNeedsYouPush() {
        Task { @MainActor [weak self] in await self?.refreshNeedsYou() }
    }

    /// Whether a wait is in the chat on screen, whose card is there, or in
    /// the group room on screen, whose card answers it (issue 2064).
    func isOpenChat(_ item: NeedsYouItem) -> Bool {
        if let roomID = item.roomID { return activeRoomSurface?.room.roomID == roomID }
        // A Bot Chat's own profile, not the strip's selected one.
        guard profilesMatch(item.profile, conversationIdentityProfile),
              let active = activeSessionId, !active.isEmpty else { return false }
        let own = chatOwnSessionIDs(for: active).union([active])
        return item.sessionIDs.contains(where: own.contains)
    }

    /// Opens the waiting chat in its profile and scrolls to its card. In
    /// the chat on screen it only scrolls.
    func openNeedsYou(_ item: NeedsYouItem) {
        needsYou.dismissBanner(item)
        if let roomID = item.roomID {
            // A wait in a group room this Hermes hosts: the room opens (in
            // any profile, since rooms are the dashboard's) with its card.
            dismissSidebarDrawer()
            guard !isOpenChat(item) else { return }
            let viewport = chatViewportTransitionGeneration, roomEpoch = groupRoomEpoch, dashboardID = activeDashboardID
            Task { @MainActor [weak self] in
                // Offline, or Hermes' rooms not read yet: say so, as a chat's
                // open does, unless a chat, room or dashboard opened meanwhile.
                guard let self, await self.openNotificationRoom(roomID) == .retry,
                      self.chatViewportTransitionGeneration == viewport, self.groupRoomEpoch == roomEpoch,
                      self.activeDashboardID == dashboardID else { return }
                self.errorMessage = AppLocalization.string("Couldn't open that chat. Try again.")
            }
            return
        }
        guard let sessionID = item.sessionIDs.first else { return }
        let isOpen = isOpenChat(item)
        // Another profile's chat doesn't open during a call (it says so),
        // so nothing waits to scroll.
        let refused = !isOpen && !profilesMatch(item.profile, activeProfile) && isVoiceCallInProgress
        if !refused {
            // The open chat names itself, so a switch away never takes its reveal.
            pendingNeedsYouReveal = NeedsYouReveal(opening: isOpen ? activeSessionId : sessionID)
        }
        // The Chats list, or a group room, may cover even the open chat:
        // it comes forward.
        dismissSidebarDrawer()
        if isOpen, activeRoomSurface != nil { closeGroupRoom() }
        guard !isOpen else { return }
        openAppLink(.session(id: sessionID, profile: item.profile))
    }

    /// Whether the transcript on screen is the chat a reveal waits for.
    func isShowingChat(for reveal: NeedsYouReveal) -> Bool {
        guard let opening = reveal.opening else { return true }
        guard let active = activeSessionId, !active.isEmpty else { return false }
        return active == opening || chatOwnSessionIDs(for: active).contains(opening)
    }
}
