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

    /// How many chats wait on the user in `profile`.
    func needsYouCount(for profile: String) -> Int {
        needsYou.count(for: profile, matches: profilesMatch)
    }

    /// Reads every profile's waits (or only `only`). Quiet on failure: a
    /// profile that can't be read keeps what it last showed.
    func refreshNeedsYou(only: String? = nil) async {
        guard servesNeedsYou, isConnected, let bridge = dashboardTicketBridge else {
            if !needsYou.items.isEmpty || needsYou.banner != nil { needsYou.reset(dashboardID: activeDashboardID) }
            return
        }
        let dashboard = activeDashboardID
        let profiles = only.map { [$0] } ?? needsYouProfiles
        for profile in profiles {
            let path = DashboardPath.withProfile(NeedsYouStore.path, profile: profile)
            guard let response = try? await bridge.requestJSON(path: path, timeoutMilliseconds: 6_000) else { continue }
            // A dashboard switch while the read was out: not this one's.
            guard dashboard == activeDashboardID else { return }
            let read = (response["waiting"] as? [[String: Any]] ?? [])
                .compactMap { NeedsYouItem(host: $0, profile: profile) }
            needsYou.apply(read, profile: profile, dashboardID: dashboard) { [weak self] item in
                self?.isOpenChat(item) ?? false
            }
        }
        if only == nil { needsYou.forget(profilesOtherThan: Set(needsYouProfiles)) }
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

    /// Whether a wait is in the chat on screen, whose card is there.
    func isOpenChat(_ item: NeedsYouItem) -> Bool {
        guard profilesMatch(item.profile, activeProfile),
              let active = activeSessionId, !active.isEmpty else { return false }
        let own = chatOwnSessionIDs(for: active).union([active])
        return item.sessionIDs.contains(where: own.contains)
    }

    /// Opens the waiting chat in its profile and scrolls to its card. In
    /// the chat on screen it only scrolls.
    func openNeedsYou(_ item: NeedsYouItem) {
        needsYou.dismissBanner(item)
        guard let sessionID = item.sessionIDs.first else { return }
        let isOpen = isOpenChat(item)
        // Another profile's chat doesn't open during a call (it says so),
        // so nothing waits to scroll.
        let refused = !isOpen && !profilesMatch(item.profile, activeProfile) && isVoiceCallInProgress
        if !refused {
            pendingNeedsYouReveal = NeedsYouReveal(opening: isOpen ? nil : sessionID)
        }
        guard !isOpen else { return }
        dismissSidebarDrawer()
        openAppLink(.session(id: sessionID, profile: item.profile))
    }

    /// Whether the transcript on screen is the chat a reveal waits for.
    func isShowingChat(for reveal: NeedsYouReveal) -> Bool {
        guard let opening = reveal.opening else { return true }
        guard let active = activeSessionId, !active.isEmpty else { return false }
        return active == opening || chatOwnSessionIDs(for: active).contains(opening)
    }
}
