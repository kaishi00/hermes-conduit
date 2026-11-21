//
//  AppState+NeedsYou.swift
//  Conduit
//
//  Hermes is waiting on you (issue 1705): reads every profile's waits from
//  the plugin (NeedsYouStore), and opens a waiting chat at its card. The
//  list, the banner and the chips only open: an approval is answered on its
//  chat's own card, which shows the whole command. A question whose chat
//  has no card gets the one its row carries (issue 2556).
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
        // The other combined dashboards are read beside this one's, never
        // ahead of it: a slow one doesn't hold back a push's wait here.
        let others = Task { @MainActor [weak self] in await self?.refreshOtherCombinedDashboards() }
        await needsYou.coalescing { [weak self] in
            await self?.readNeedsYou()
        }
        await others.value
    }

    /// The other combined dashboards' waits, chats (less often, stage 4b),
    /// bots (every few minutes, stage 4c) and group chats (once a minute),
    /// read through their kept connections, coalesced apart from this
    /// dashboard's reads.
    func refreshOtherCombinedDashboards() async {
        await otherCombinedReads.coalescing { [weak self] in
            await self?.readOtherCombinedDashboardsNeedsYou()
            await self?.readOtherCombinedDashboardsChats()
            await self?.readOtherCombinedDashboardsBots()
            await self?.readOtherCombinedDashboardsRooms()
        }
    }

    /// Whether Needs you has a list to show: this dashboard's plugin keeps
    /// one, or another combined dashboard listed a wait.
    var offersNeedsYouList: Bool {
        servesNeedsYou || !needsYou.otherDashboards.isEmpty
    }

    /// The other combined dashboards' waits, each read through its kept
    /// connection for every one of its profiles (all-live stage 4a). Quiet
    /// on failure, as this dashboard's: a profile that can't be read keeps
    /// what it showed, and a dashboard let go says nothing more.
    func readOtherCombinedDashboardsNeedsYou() async {
        let kept = keptDashboardRuntimes.filter { isInCombinedGroup($0.key) && $0.key != activeDashboardID }
        needsYou.forgetOtherDashboards(otherThan: Set(kept.keys))
        keptDashboardProfiles = keptDashboardProfiles.filter { id, read in
            kept[id].map { ObjectIdentifier($0.bridge) == read.bridge } == true
        }
        for (id, runtime) in kept.sorted(by: { $0.value.keptAt < $1.value.keptAt }) {
            guard isSceneActive else { return }
            guard let profiles = await keptDashboardProfileNames(id, runtime) else { continue }
            // Its plugin's capabilities, asked once per kept connection, so a
            // dashboard on an IP address takes its Hermes' name with no bots
            // shown, and a plugin without the route isn't asked every poll
            // (Dashboard names).
            if combinedDashboardNameReads[id] != ObjectIdentifier(runtime.bridge) {
                combinedDashboardNameReads[id] = ObjectIdentifier(runtime.bridge)
                _ = await combinedDashboardCapabilities(id, runtime)
            }
            // A room's id is its host's own: another Hermes' room can share
            // the open room's id, so a room wait counts as open only from a
            // dashboard of this one's Hermes (issue 2631), bots or none
            // (issue 2741).
            // Asked per item, after the read: the read itself can bring
            // the shared wait that makes the two one Hermes.
            func sameHermes() -> Bool {
                let hermes = combinedHermesGroups
                return hermes[activeDashboardID] != nil && hermes[activeDashboardID] == hermes[id]
            }
            for profile in profiles {
                guard isSceneActive else { return }
                let path = DashboardPath.withProfile(NeedsYouStore.path, profile: profile)
                let response = try? await readKeptDashboardJSON(runtime.bridge, path: path)
                // Let go, or opened, while the read was out: not this pass's.
                guard keptDashboardRuntimes[id]?.bridge === runtime.bridge, activeDashboardID != id else { break }
                guard let listed = response.flatMap({ NeedsYouItem.items(listed: $0, profile: profile, installationID: PushNotificationService.shared.installationID) }) else { continue }
                // A profile a strip tap found deleted while the read was
                // out stays gone (issue 2646).
                guard currentKeptProfiles(id, else: profiles).contains(where: { profilesMatch($0, profile) }) else { continue }
                needsYou.applyOther(
                    listed,
                    profile: profile,
                    dashboardID: id,
                    isOpenChat: { Self.otherDashboardWaitIsOpen($0, sameHermes: sameHermes, isOpenChat: self.isOpenChat) }
                )
            }
            if keptDashboardRuntimes[id]?.bridge === runtime.bridge {
                needsYou.forgetOther(id, profilesOtherThan: Set(currentKeptProfiles(id, else: profiles)))
            }
        }
    }

    /// Whether another combined dashboard's wait is the chat on screen's, so
    /// it doesn't banner: a room wait only from a dashboard of this one's
    /// Hermes, since another Hermes' room can share the open room's id
    /// (issue 2631, tested in issue 2655).
    static func otherDashboardWaitIsOpen(
        _ item: NeedsYouItem,
        sameHermes: () -> Bool,
        isOpenChat: (NeedsYouItem) -> Bool
    ) -> Bool {
        (item.roomID == nil || sameHermes()) && isOpenChat(item)
    }

    /// A kept dashboard's profiles as last read, a read since the pass
    /// began included; the pass's own list when none is kept.
    private func currentKeptProfiles(_ id: UUID, else profiles: [String]) -> [String] {
        keptDashboardProfiles[id]?.profiles ?? profiles
    }

    /// How long a kept dashboard's profile list stands before a pass reads
    /// it again: a profile made or deleted there shows within this.
    static let keptDashboardProfilesMaxAge: TimeInterval = 300

    /// A kept dashboard's profiles, read through its bridge once per kept
    /// connection and again every few minutes, or at once when `fresh`.
    /// The last list when a read again fails; nil when none could be read.
    func keptDashboardProfileNames(
        _ id: UUID, _ runtime: KeptDashboardRuntime, fresh: Bool = false, now: Date = Date()
    ) async -> [String]? {
        let bridge = ObjectIdentifier(runtime.bridge)
        let last = keptDashboardProfiles[id].flatMap { $0.bridge == bridge ? $0 : nil }
        if !fresh, let last, now.timeIntervalSince(last.at) < Self.keptDashboardProfilesMaxAge { return last.profiles }
        // Kept anew (opened and left again) while the read was out: the
        // list that switch seeded is newer than this read.
        let keptAt = runtime.keptAt
        guard let response = try? await readKeptDashboardJSON(runtime.bridge, path: "/api/profiles"),
              keptDashboardRuntimes[id]?.bridge === runtime.bridge else { return last?.profiles }
        guard keptDashboardRuntimes[id]?.keptAt == keptAt else { return keptDashboardProfiles[id]?.profiles }
        let names = (response["profiles"] as? [Any] ?? []).compactMap { value -> String? in
            if let name = value as? String { return name }
            return (value as? [String: Any])?["name"] as? String
        }
        // Hermes always has `default`; an empty list is a degraded reply.
        guard !names.isEmpty else { return last?.profiles }
        let profiles = names.contains("default") ? names : ["default"] + names
        keptDashboardProfiles[id] = (bridge, profiles, now)
        return profiles
    }

    func readKeptDashboardJSON(_ bridge: DashboardTicketBridge, path: String) async throws -> [String: Any] {
        if let keptDashboardJSONReader { return try await keptDashboardJSONReader(bridge, path) }
        return try await bridge.requestJSON(path: path, timeoutMilliseconds: 6_000)
    }

    /// A combined dashboard's badge (all-live stage 4): the first letter of
    /// its name on its color, or its place in the group where two names
    /// start alike (SavedDashboardLabel.badgeLetters). The color is its
    /// place among the combined dashboards in Saved Dashboards order, so no
    /// two in the group share one. Nil outside the group.
    func combinedDashboardBadge(_ id: UUID) -> (letter: String, colorIndex: Int, name: String)? {
        let members = savedDashboardRegistry.dashboards.filter { savedDashboardRegistry.combinedGroupIDs.contains($0.id) }
        guard let index = members.firstIndex(where: { $0.id == id }) else { return nil }
        let names = members.map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (SavedDashboardLabel.badgeLetters(names)[index], index, names[index])
    }

    private func readNeedsYou() async {
        guard servesNeedsYou else {
            // Another combined dashboard's banner stays for its time.
            if !needsYou.items.isEmpty || (needsYou.banner != nil && needsYou.banner?.dashboardID == nil) {
                needsYou.reset(dashboardID: activeDashboardID)
            }
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
            guard let read = NeedsYouItem.items(listed: response, profile: profile, installationID: PushNotificationService.shared.installationID) else { continue }
            needsYou.apply(read, profile: profile, dashboardID: dashboard) { [weak self] item in
                self?.isOpenChat(item) ?? false
            }
            takeBackQuestionCardsNoLongerListed(profile: profile)
        }
        needsYou.forget(profilesOtherThan: Set(needsYouProfiles))
        showWaitingQuestionCards()
    }

    /// Draws a listed question's card in the chat on screen when it has
    /// none (issue 2556). Hermes draws no card when the turn runs in
    /// another Hermes process than the one Conduit is attached to (a
    /// scheduled job's turn in a Bot Chat), and the plugin's card reached
    /// the chat only from a tapped notification, which an open Conduit
    /// never gets. The card is the notification's, answered through the
    /// relay; Hermes' own card waiting on the same question, or the same
    /// card already there (answered too), keeps it out: one question is one
    /// card. An older card of Hermes', answered or run out, that asked the
    /// same thing doesn't: the question asked again needs its card.
    func showWaitingQuestionCards() {
        guard needsYou.items.contains(where: { $0.card != nil }),
              // A transcript still being restored takes it afterwards.
              chatResumeRestorationRequest == nil,
              let openID = activeSessionId, !openID.isEmpty else { return }
        for item in needsYou.items where item.roomID == nil {
            guard let card = item.card,
                  let key = Self.pendingDecisionEvictionKey(for: card),
                  let pushed = Self.notificationClarifyActivity(for: card),
                  !needsYou.cardsHermesDrew.contains(pushed.requestId),
                  isOpenChat(item) else { continue }
            // Its answer goes through the relay, sealed for the profile's
            // pairing like a notification's: the card came from no push
            // that named its gateway (issue 2683). Kept for a card already
            // drawn too, one restored at relaunch included: whether its
            // answer may go unsealed is worked out at the send, and one
            // with no key here while the profile has one under another
            // gateway is refused (Eric, 2026-11-18, issue 2692).
            if let gatewayID = needsYouCardGatewayID(item) {
                PushNotificationService.shared.retainRelayGatewayID(
                    gatewayID, forRequestID: pushed.requestId,
                    sealContext: .init(gatewayID: gatewayID, dashboardID: activeDashboardID, profile: item.profile)
                )
            }
            guard !messages.contains(where: { SessionPresentationCache.decisionKey(for: $0) == key }) else { continue }
            if Self.hermesCardHoldsQuestion(pushed, in: messages) {
                // Its answer leaves the wait listed until the next read.
                needsYou.noteHermesDrewCard(for: pushed.requestId)
                continue
            }
            let openIDs = presentationCacheSessionIDs(for: openID)
            let profile = presentationProfile(for: openID)
            recordNotificationDecision(
                card,
                sessionIDs: item.sessionIDs + openIDs,
                cacheSessionIDs: openIDs,
                profile: profile
            )
            needsYou.noteDrewCard(.init(requestID: pushed.requestId, profile: item.profile, decisionKey: key,
                                        presentationProfile: profile, cacheSessionIDs: openIDs))
            messages = sessionPresentationCache.merge(
                messages,
                profile: profile,
                sessionIDs: openIDs,
                includePendingClarifications: true
            )
        }
    }

    /// Hermes' own card `answered` took this iPhone's answer: a listed
    /// question it asks is that card's, so the row's copy stays out, and one
    /// already drawn, unanswered, goes. The plugin names the wait until its
    /// clarify call returns, so a read just after the answer would otherwise
    /// draw the answered question again, and a read made while Hermes' card
    /// was still waiting may never have noted it (one made while the chat
    /// was being restored, notifier#965).
    func keepQuestionCopiesOut(answeredOn answered: ClarifyActivity) {
        guard !answered.requestId.hasPrefix(PendingDecisionPayload.relayRequestPrefix) else { return }
        // Only the open chat's waits: the answered card is in it, and the
        // same words asked in another chat are another question.
        for item in needsYou.items where item.roomID == nil && isOpenChat(item) {
            guard let card = item.card,
                  let pushed = Self.notificationClarifyActivity(for: card),
                  Self.pushCardSupersededBy(pushed, live: answered) else { continue }
            needsYou.noteHermesDrewCard(for: pushed.requestId)
        }
        removePushCardsSuperseded(by: answered)
    }

    /// Takes back the question cards drawn from `profile`'s rows whose
    /// waits its list no longer names (issue 2828): the plugin forgets a
    /// wait it gives up, the question run out or answered elsewhere, and
    /// the relay refuses a late answer. The question isn't lost: its clarify
    /// call ends with the wait, and Hermes' own record of it comes into the
    /// chat as a finished card (`ClarifyActivity.historyRecord`), with its
    /// choices and Answer in a message once it ran out (issue 2850), so
    /// keeping this copy would draw it twice. Still unanswered only: a card this
    /// iPhone answered keeps its answer. Its saved copy goes too, so a
    /// reopen within the day doesn't bring it back over Hermes' own record.
    func takeBackQuestionCardsNoLongerListed(profile: String) {
        for drawn in needsYou.takeCardsNoLongerListed(profile: profile) {
            sessionPresentationCache.removePendingDecision(
                key: drawn.decisionKey,
                profile: drawn.presentationProfile,
                sessionIDs: drawn.cacheSessionIDs
            )
            let isDrawn = { (message: ChatMessage) in
                SessionPresentationCache.decisionKey(for: message) == drawn.decisionKey
                    && SessionPresentationCache.pendingDecisionKey(for: message) != nil
            }
            if messages.contains(where: isDrawn) { messages.removeAll(where: isDrawn) }
        }
    }

    /// The relay gateway a question's card drawn from its row answers
    /// through: the one the row's list named, else the profile's pairing
    /// key on this iPhone, else the gateway the host last reported for it.
    func needsYouCardGatewayID(_ item: NeedsYouItem) -> String? {
        let notifications = PushNotificationService.shared
        return Self.needsYouCardGatewayID(
            listed: item.relayGatewayID,
            dashboardID: activeDashboardID,
            profile: item.profile,
            installationID: notifications.installationID,
            records: PushNotificationService.e2eKeyStore.records(),
            reported: activeDashboardID.flatMap { reportedRelayGatewayID(of: $0, profile: item.profile) }
        )
    }

    nonisolated static func needsYouCardGatewayID(
        listed: String?,
        dashboardID: UUID?,
        profile: String,
        installationID: String?,
        records: [E2EKeyRecord],
        reported: String?
    ) -> String? {
        if let listed, !listed.isEmpty { return listed }
        // An older plugin's list names none: a key this iPhone holds for
        // the profile names its gateway, so an encrypted pairing never
        // gets a plaintext answer.
        let keyed = records
            .filter { record in
                record.installationID == installationID && record.retiredAt == nil
                    && record.dashboardID == dashboardID?.uuidString
                    && record.profile.map { profilesMatch($0, profile) } == true
            }
            .max { $0.createdAt < $1.createdAt }
        return keyed?.gatewayID ?? reported
    }

    /// Whether a row-drawn card's answer must be sealed though this iPhone
    /// holds no key for `gatewayID`: it holds a current one for the profile
    /// on this dashboard under another gateway, so the pairing changed since
    /// (re-paired elsewhere, or a key not handed over yet), and plaintext
    /// would reach the relay only for the plugin to refuse it (issue 2692).
    nonisolated static func needsYouCardMustSeal(
        gatewayID: String,
        dashboardID: UUID?,
        profile: String,
        installationID: String?,
        records: [E2EKeyRecord]
    ) -> Bool {
        guard NotificationE2E.currentRecord(gatewayID: gatewayID, installationID: installationID, records: records) == nil else {
            return false
        }
        return records.contains { record in
            record.installationID == installationID && record.retiredAt == nil
                && record.gatewayID != gatewayID
                && record.dashboardID == dashboardID?.uuidString
                && record.profile.map { profilesMatch($0, profile) } == true
        }
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

    /// Whether a wait is in the chat on screen, whose card is there (a
    /// question's drawn from its row when Hermes drew none), or in
    /// the group room on screen, whose card answers it (issue 2064).
    func isOpenChat(_ item: NeedsYouItem) -> Bool {
        if let roomID = item.roomID {
            // A linked room's copy is another host's room, whatever its id.
            return activeRoomSurface?.copy == nil && activeRoomSurface?.room.roomID == roomID
        }
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
        // Another combined dashboard's: switch to it (through its kept
        // connection, no sign-in), then open as one of its own.
        if let dashboardID = item.dashboardID, dashboardID != activeDashboardID {
            guard !refusesCombinedSwitchDuringCall() else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Open as soon as its sync settles, as its bots do.
                await self.switchToCombinedDashboardUntilSettled(dashboardID)
                guard self.activeDashboardID == dashboardID else { return }
                var own = item
                own.dashboardID = nil
                self.openNeedsYou(own)
            }
            return
        }
        if let roomID = item.roomID {
            // A wait in a group room this Hermes hosts: the room opens (in
            // any profile, since rooms are the dashboard's) with its card.
            dismissSidebarDrawer()
            guard !isOpenChat(item) else { return }
            let viewport = chatViewportTransitionGeneration, roomEpoch = groupRoomEpoch, dashboardID = activeDashboardID
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A chat, room or dashboard opened since the tap owns the screen.
                let owned = {
                    self.chatViewportTransitionGeneration == viewport && self.groupRoomEpoch == roomEpoch
                        && self.activeDashboardID == dashboardID
                }
                guard owned() else { return }
                // Offline, or Hermes' rooms not read yet: say so, as a chat's
                // open does, unless something opened meanwhile.
                guard await self.openNotificationRoom(roomID) == .retry, owned() else { return }
                self.errorMessage = AppLocalization.string("Couldn't open that chat. Try again.")
            }
            return
        }
        guard let sessionID = item.sessionIDs.first else { return }
        let isOpen = isOpenChat(item)
        // Another profile's chat doesn't open during a call (it says so),
        // so nothing waits to scroll.
        let refused = !isOpen && !profilesMatch(item.profile, activeProfile) && isCallEndingProfileSwitch
        // A question asked past its turn has no card in its chat to scroll to: the chat just opens.
        if item.asked != nil {
            // Nor does an earlier wait's reveal scroll it to another card,
            // unless this open is refused and that chat still opens.
            if !refused { pendingNeedsYouReveal = nil }
        } else if !refused {
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

extension AppState {
    /// What a live call is told about the questions its bot asked that
    /// wait past their turn (plugin 0.189.0+), from the Needs you list:
    /// the user hears them when they ask what waits on them, and answers by
    /// voice. The answer goes to Hermes as a request, whose spoken turn
    /// records it for the chat that asked (plugin 0.191.0+). Empty when
    /// none waits for `profile`.
    func liveAskedQuestionsInstructions(profile: String? = nil) -> String {
        let bot = profile ?? conversationIdentityProfile
        return Self.askedQuestionsBlock(
            needsYou.items.filter { Self.profilesMatch($0.profile, bot) }.compactMap(\.asked)
        )
    }

    /// The block itself, oldest first; at most `askedQuestionsSpoken` of them.
    nonisolated static func askedQuestionsBlock(_ asked: [BotWorkCoordination.Item]) -> String {
        let open = asked.filter { $0.status == "open" }.sorted { $0.at < $1.at }.prefix(askedQuestionsSpoken)
        guard !open.isEmpty else { return "" }
        let lines = open.map { question -> String in
            var line = "- \(question.id): «\(question.text.trimmingCharacters(in: .whitespacesAndNewlines))»"
            if !question.choices.isEmpty {
                line += " Choices: «" + question.choices.joined(separator: "», «") + "»."
            } else if !question.answersInWords {
                line += " A yes or no."
            }
            if !question.recommended.isEmpty { line += " Hermes recommends «\(question.recommended)»." }
            return line
        }
        return "\n\nQuestions Hermes asked the user that still wait on their answer (on their Needs you list):\n"
            + lines.joined(separator: "\n")
            + "\nSay them when the user asks what's waiting on them, reading the choices out. When they answer one, "
            + "send their answer to Hermes as a request that names its id, like \"My answer to P7: <what they said>\": "
            + "Hermes records it, and the chat that asked acts on it."
    }

    nonisolated static let askedQuestionsSpoken = 5
}
