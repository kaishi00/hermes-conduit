//
//  AppState+CombinedPulse.swift
//  Conduit
//
//  All-live stage 4d: a chip per combined dashboard on top of Pulse. Pulse
//  is one per host, its cards' steps (Done, Not now, Do it, ratings) are
//  that host's, so a chip shows that dashboard's Pulse: in place, on that
//  dashboard's own runtime through its kept connection, with no switch
//  (no-switch stage 2). Each other dashboard's chip says how many of its
//  cards are new, read through its kept connection.
//

import Foundation

/// Another combined dashboard's Pulse, as its feed last answered.
struct CombinedDashboardPulse: Equatable {
    let bridge: ObjectIdentifier
    let unseen: Int
    /// Its Pulse chat and the profile it's in, as the feed named them, so
    /// Chats keeps that chat behind its Pulse before it's opened here.
    var homeChatID: String? = nil
    var profile: String? = nil
    let at: Date
}

/// One chip on top of Pulse.
struct PulseDashboardChip: Identifiable, Equatable {
    let dashboardID: UUID
    let badge: V2DashboardBadge
    let unseen: Int
    /// The page shows its Pulse.
    let isShown: Bool
    /// Its kept connection dropped: a tap switches there and signs in.
    var switches = false
    var id: UUID { dashboardID }
}

extension AppState {
    /// How long another dashboard's count stands before Pulse's page reads
    /// it again.
    static let combinedDashboardPulseMaxAge: TimeInterval = 50

    /// Reads each other combined dashboard's Pulse feed through its kept
    /// connection, for its count of new cards. One whose plugin has no
    /// feed has no chip; a read that fails keeps what the chip said.
    func readOtherCombinedDashboardsPulse(force: Bool = false, now: Date = Date()) async {
        let kept = keptDashboardRuntimes.filter { isInCombinedGroup($0.key) && $0.key != activeDashboardID }
        // One that dropped by itself keeps its last list until it's back;
        // out of the group or opened here, it goes.
        if combinedDashboardPulse.keys.contains(where: { !isInCombinedGroup($0) || $0 == activeDashboardID }) {
            combinedDashboardPulse = combinedDashboardPulse.filter { isInCombinedGroup($0.key) && $0.key != activeDashboardID }
        }
        for (id, runtime) in kept.sorted(by: { $0.value.keptAt < $1.value.keptAt }) {
            guard isSceneActive else { return }
            let bridge = ObjectIdentifier(runtime.bridge)
            if !force, let last = combinedDashboardPulse[id], last.bridge == bridge,
               now.timeIntervalSince(last.at) < Self.combinedDashboardPulseMaxAge { continue }
            // Suggestions asked for, as the page it opens asks where they're
            // on: a plugin without them ignores the ask, and the count then
            // matches what that page shows new.
            let path = "\(PulseClient.path)/feed" + PulseClient.feedQuery(proposals: true, looks: false)
            let response = try? await readKeptDashboardJSON(runtime.bridge, path: path)
            // Let go, opened, or out of the group while the read was out.
            guard keptDashboardRuntimes[id]?.bridge === runtime.bridge, activeDashboardID != id,
                  isInCombinedGroup(id), let response, let page = PulseFeedPage(json: response) else { continue }
            // A read started later already stored its count: keep that one.
            if let stored = combinedDashboardPulse[id], stored.at > now { continue }
            combinedDashboardPulse[id] = CombinedDashboardPulse(
                bridge: bridge, unseen: page.unseen, homeChatID: page.homeChatID, profile: page.profile, at: now
            )
        }
    }

    /// The chips on top of Pulse: the dashboard on screen's, then each
    /// other combined dashboard whose Pulse answered, in Saved Dashboards
    /// order. None unless there's another to show.
    var pulseDashboardChips: [PulseDashboardChip] {
        guard let active = activeDashboardID, isInCombinedGroup(active) else { return [] }
        let shown = pulseDashboardID
        let chips: [PulseDashboardChip] = savedDashboardRegistry.dashboards.compactMap { dashboard in
            guard isInCombinedGroup(dashboard.id), let badge = combinedDashboardBadge(dashboard.id) else { return nil }
            let mark = V2DashboardBadge(letter: badge.letter, colorIndex: badge.colorIndex, name: badge.name)
            if dashboard.id == active {
                return PulseDashboardChip(dashboardID: active, badge: mark, unseen: pulseUnseen, isShown: shown == active)
            }
            guard let pulse = combinedDashboardPulse[dashboard.id] else { return nil }
            // Shown here, its feed read on its own runtime knows best; once
            // another is shown, whichever read is newer: the page's last one
            // there (its cards just seen) or the background read since.
            var unseen = pulse.unseen
            let kept = runtime(for: dashboard.id)
            if let runtime = kept, let applied = runtime.pulseFeedAppliedAt,
               shown == dashboard.id || applied.at > pulse.at {
                unseen = runtime.pulseUnseen
            }
            return PulseDashboardChip(
                dashboardID: dashboard.id, badge: mark, unseen: unseen, isShown: shown == dashboard.id,
                switches: kept == nil
            )
        }
        return chips.count > 1 ? chips : []
    }

    /// The dashboard the Pulse page shows: a chip's, while it's kept
    /// connected (no-switch stage 2), else the one on screen.
    var pulseDashboardID: UUID? { pulseRuntime == nil ? activeDashboardID : pulseShownDashboardID }

    /// The runtime of the other combined dashboard the Pulse page shows;
    /// nil while it shows the one on screen's.
    var pulseRuntime: DashboardRuntime? {
        guard let id = pulseShownDashboardID, id != dashboardIDOnScreen else { return nil }
        return runtime(for: id)
    }

    /// What the plugin of the Pulse shown serves: the one on screen's but
    /// while the page shows another dashboard's (its chip), which goes back
    /// as the page leaves, so Settings > Pulse stays the one on screen's.
    var pulsePlugin: NotifierPluginStatus { readingPulseRuntime { notifierPlugin } }

    /// What the Pulse page draws (what its plugin serves, its counts), from
    /// the dashboard it shows.
    func readingPulseRuntime<T>(_ body: () -> T) -> T {
        guard let runtime = pulseRuntime, runtime !== shownRuntime else { return body() }
        return act(onRuntime: runtime, body)
    }

    /// Before the page reads another dashboard's feed in place: what its
    /// plugin serves, read on its own runtime when one signed in quietly
    /// beside this one hasn't been asked yet, so its feed is asked for
    /// suggestions and looks, and its cards get their buttons, as there.
    func readyShownPulseRuntime() async {
        guard pulseRuntime != nil, let id = pulseShownDashboardID else { return }
        await readKeptPluginStatusIfUnknown(id)
    }

    /// Shows another combined dashboard's Pulse in place: the page reads
    /// and acts on its feed through its kept connection, with no switch, so
    /// no call ends either. Its own chip goes back to the one on screen's;
    /// one whose kept connection dropped switches there, signs in and opens
    /// its Pulse (refused during a call).
    func openCombinedPulse(_ dashboardID: UUID) {
        let other = dashboardID != dashboardIDOnScreen
        // A chip whose kept connection dropped (its list stays, below) signs
        // in as a switch does, as the chip did before stage 2.
        if other, runtime(for: dashboardID) == nil {
            guard !refusesCombinedSwitchDuringCall(to: dashboardID) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.switchToCombinedDashboardUntilSettled(dashboardID)
                // Another dashboard picked meanwhile owns the screen.
                guard self.activeDashboardID == dashboardID else { return }
                if self.pulseShownDashboardID != nil { self.pulseShownDashboardID = nil }
                self.openPulse(card: nil)
            }
            return
        }
        let shown: UUID? = other ? dashboardID : nil
        if pulseShownDashboardID != shown { pulseShownDashboardID = shown }
    }

    /// A card's chat on another combined dashboard's Pulse shown in place:
    /// it opens as a chat link naming that dashboard is routed, in place on its
    /// own runtime through its kept connection with no switch (a Bot Chat,
    /// a listed chat or one its list doesn't hold), at the message the card
    /// came from; the link's route switches only when that dashboard can't
    /// open it in place. `dashboard` is the one whose Pulse the page showed
    /// at the tap. False when the card is the dashboard on screen's, the
    /// page has left that Pulse, or its kept connection is gone: the caller
    /// goes on as before (`switchForFarPulseStep`).
    func openFarPulseCardChat(_ card: PulseCard, for dashboard: UUID?) -> Bool {
        guard let id = dashboard, id != dashboardIDOnScreen, pulseDashboardID == id,
              let runtime = runtime(for: id) else { return false }
        // What the card names, as its own Pulse reads it, its profile
        // spelled as that dashboard lists it and its default the one that
        // dashboard named, never the one on screen's.
        let farDefault = profileAppearanceStore.loadDefaultName(dashboardID: id)
        let (hasChat, profile) = act(onRuntime: runtime) {
            (
                pulseCardHasChat(card),
                notificationProfileID(card.profile.isEmpty ? pulseHomeProfile : card.profile, defaultName: farDefault)
            )
        }
        guard hasChat else { return true }
        let reveal = card.messageID.map { ArtifactReveal(messageID: $0, opening: card.chatID) }
        pendingArtifactReveal = reveal
        widgetLaunchCoordinator.supersede()
        // A workstream's hidden chat opens on its bot's profile, as its
        // link does (`openAppLink`). One that can't start (its socket busy
        // with a request, so not handed to that profile now) has said so,
        // and nothing waits to scroll.
        if let workstreamProfile = runtime.botWork.workstreamProfile(forSession: [card.chatID]) {
            let open = openFarWorkstreamInPlace(
                card.chatID, profile: profile ?? workstreamProfile, in: id
            )
            if open == nil, pendingArtifactReveal == reveal { pendingArtifactReveal = nil }
            return true
        }
        // The route tries it in place first, so a call goes on; only a
        // switch it falls back to is refused during one.
        PushNotificationService.shared.routeChatLink(
            ConduitNotificationTarget(
                profile: profile, sessionId: card.chatID, dashboardID: id, type: nil, isChatLink: true
            )
        )
        return true
    }

    /// Do it on a card of another combined dashboard's Pulse shown in
    /// place: the card's own chat, or the Bot Chat Do it goes to there,
    /// opens in place on that dashboard's runtime through its kept
    /// connection with no switch, so a call goes on, and gets the reminder
    /// (or an Ask's `words`) in its composer. `dashboard` is the one whose
    /// Pulse the page showed at the tap. `.notInPlace` for a card of the
    /// dashboard on screen, a page that has left that Pulse, a kept
    /// connection that's gone, and a chat that can only open through a
    /// switch: the caller goes on as before (`switchForFarPulseStep`). A
    /// card from no chat gets a new chat made and opened in place there
    /// (`startFarPulseNewChat`).
    func doFarPulseCard(
        _ card: PulseCard, words: String? = nil, in picked: PulseDoItTarget? = nil, for dashboard: UUID?
    ) async -> FarPulseDoIt {
        guard let id = dashboard, id != dashboardIDOnScreen, pulseDashboardID == id,
              let runtime = runtime(for: id) else { return .notInPlace }
        // What the card may do and where it goes, as its own Pulse reads it.
        let farDefault = profileAppearanceStore.loadDefaultName(dashboardID: id)
        let (allowed, hasChat, bot, profile) = act(onRuntime: runtime) {
            (
                words != nil ? canAskFromPulseCard(card) : canActOnPulseCard(card),
                pulseCardHasChat(card),
                pulseDoItBot(for: card, in: picked),
                notificationProfileID(card.profile.isEmpty ? pulseHomeProfile : card.profile, defaultName: farDefault)
            )
        }
        guard allowed else { return .failed(nil) }
        var chat: PulseActedChat?
        if hasChat {
            let reveal = card.messageID.map { ArtifactReveal(messageID: $0, opening: card.chatID) }
            pendingArtifactReveal = reveal
            // At the tap, kept on purpose though the opens below supersede
            // too: the notification route's own reaches its supersede only
            // after awaits, and a widget launch landing meanwhile must not
            // take the screen (#3265's review).
            widgetLaunchCoordinator.supersede()
            var opened = false
            if let workstreamProfile = runtime.botWork.workstreamProfile(forSession: [card.chatID]) {
                // A workstream's hidden chat opens on its bot's profile.
                // No open in place (its connection let go since): the switch's.
                guard let open = openFarWorkstreamInPlace(card.chatID, profile: profile ?? workstreamProfile, in: id) else {
                    if pendingArtifactReveal == reveal { pendingArtifactReveal = nil }
                    return .notInPlace
                }
                opened = await open.value
            } else {
                let target = ConduitNotificationTarget(
                    profile: profile, sessionId: card.chatID, dashboardID: id, type: nil, isChatLink: true
                )
                guard let outcome = await openFarNotificationInPlace(target, in: id) else {
                    if pendingArtifactReveal == reveal { pendingArtifactReveal = nil }
                    return .notInPlace
                }
                opened = outcome == .opened
            }
            guard opened else {
                if pendingArtifactReveal == reveal { pendingArtifactReveal = nil }
                return .failed(nil)
            }
        } else if let bot {
            guard let open = openFarBotChatInPlace(of: bot, in: id) else { return .notInPlace }
            guard await open.value else { return .failed(nil) }
            // As a bot link's open: its chat comes forward over the Pulse screen.
            dismissSidebarDrawer()
            chat = act(onRuntime: runtime) { pulseActedChat(in: bot) }
        } else {
            // A card from no chat: a new chat in that dashboard's Pulse
            // profile, made and opened there.
            switch await startFarPulseNewChat(profile: profile ?? "default", in: id) {
            case .notInPlace: return .notInPlace
            case .failed(let said): return .failed(said)
            case .started: break
            }
        }
        // Only into that dashboard's chat: another chat opened meanwhile
        // gets nothing, the card's own chat checked by its ids (#3265's
        // review).
        guard farChat?.dashboardID == id, let shown = activeSessionId else { return .failed(nil) }
        if hasChat, shown != card.chatID,
           !act(onRuntime: runtime, { chatOwnSessionIDs(for: shown) }).contains(card.chatID) {
            return .failed(nil)
        }
        prefillComposer(words ?? card.actionMessage)
        return .opened(PulseDoItOpened(chat: chat))
    }

    /// Whether a step tapped on `dashboard`'s Pulse (`pulseDashboardID` at
    /// the tap) still goes ahead there with no switch: the page still shows
    /// that Pulse, the one on screen's or one read through a connection
    /// still kept. A calendar change asks through it
    /// (`applyPulseApproval(_:kind:sharing:from:)`).
    func pulseStepStands(on dashboard: UUID?) -> Bool {
        guard let id = dashboard, pulseDashboardID == id else { return false }
        return runtime(for: id) != nil
    }

    /// Do it's new chat on another combined dashboard's Pulse shown in
    /// place, for a card from no chat: made on that dashboard's Hermes in
    /// `profile` (its Pulse's) through its kept connection, then opened in
    /// place there, as its workstream chats open, with no switch. Nil when
    /// that connection can't take it now (gone, or its socket busy with a
    /// request on another profile): the caller switches there. Failed when
    /// no chat opened, with what to say when there's more than the page's
    /// own line, a chat made there that couldn't then be opened (its
    /// connection dropped meanwhile) included: a switch would make a second one.
    func startFarPulseNewChat(profile: String, in id: UUID) async -> FarPulseNewChat {
        guard id != dashboardIDOnScreen, keptRuntime(id, on: profile) != nil,
              let client = keptDashboardRuntimes[id]?.client else { return .notInPlace }
        let created: (sessionId: String, storedSessionId: String?, profile: String?)
        do {
            if let createSession = chatResumeLifecycleOperations.createSession {
                created = try await createSession(client, nil)
            } else {
                // No model: the profile's default, as New Chat's (#916).
                created = try await client.createSession(inProfile: profile)
            }
        } catch {
            return .failed(UserFacingError.message(for: error))
        }
        // The page left that Pulse meanwhile: nothing opens over what's there now.
        guard !Task.isCancelled, pulseDashboardID == id else { return .failed(nil) }
        if let returned = created.profile, !profilesMatch(returned, profile) {
            return .failed(AppLocalization.string("Hermes created this conversation in \(returned), not \(profile). It was not opened."))
        }
        let chatID = created.sessionId.isEmpty ? (created.storedSessionId ?? "") : created.sessionId
        guard !chatID.isEmpty else {
            return .failed(AppLocalization.string("Hermes didn't finish creating the conversation. Try again."))
        }
        guard let open = openFarWorkstreamInPlace(chatID, profile: profile, in: id) else { return .failed(nil) }
        return await open.value ? .started : .failed(nil)
    }

    /// Before a Pulse card's step on another combined dashboard's Pulse
    /// whose kept connection is gone (a task, Do it): the switch there. A
    /// kept, connected one's task opens in place (`farPulseTaskStore`), and
    /// its Do it too (`doFarPulseCard`), a new chat included. A card's chat link doesn't come here while that
    /// dashboard is kept connected (`openFarPulseCardChat`). `dashboard`
    /// is the one whose Pulse the page showed at the tap (`pulseDashboardID`
    /// then). True when the step can go ahead on that dashboard, the page
    /// still showing its Pulse: never on another one, as a chip picked
    /// meanwhile, a switch or a connection let go would make it.
    func switchForFarPulseStep(for dashboard: UUID?) async -> Bool {
        guard let id = dashboard else { return false }
        guard id != dashboardIDOnScreen else { return pulseDashboardID == id }
        // A chip picked since the tap: no switch for a step the page left.
        guard pulseDashboardID == id, runtime(for: id) != nil else { return false }
        guard !refusesCombinedSwitchDuringCall(to: id) else { return false }
        await switchToCombinedDashboardUntilSettled(id)
        guard !Task.isCancelled, activeDashboardID == id else { return false }
        if pulseShownDashboardID == id { pulseShownDashboardID = nil }
        return pulseDashboardID == id
    }
}

extension AppState {
    /// A Kanban store pointed at another combined dashboard's boards
    /// through its kept connection, for a card's task on its Pulse shown in
    /// place: that board is its own Hermes', so the task opens over the
    /// Pulse page with no switch. Nil when `dashboard` is the one on
    /// screen, the page no longer shows its Pulse, or it isn't kept and
    /// connected (the step then switches there, `switchForFarPulseStep`).
    func farPulseTaskStore(for dashboard: UUID?) -> KanbanStore? {
        guard let id = dashboard, id != dashboardIDOnScreen, pulseDashboardID == id,
              let runtime = runtime(for: id), runtime.isConnected,
              let bridge = runtime.dashboardTicketBridge else { return nil }
        // Its answers kept under its own dashboard, as its Tasks page keeps them there.
        let answers = act(onRuntime: runtime) { screenAnswers(profile: KeptRoute.everyProfile) }
        // The board it loads for the task isn't kept as that Tasks page's pick.
        let store = KanbanStore(keepsBoardPick: false)
        store.configure(requester: bridge, serverIdentity: bridge.baseURL, answers: answers)
        return store
    }

    /// The task `taskID` on the boards `store` reads (another combined
    /// dashboard's, `farPulseTaskStore`), its board loaded, for its sheet.
    /// Throws what the read threw, or that no board there has it.
    func findFarPulseTask(_ taskID: String, in store: KanbanStore) async throws -> KanbanTask {
        // A board that didn't load doesn't stop the lookup: findTask reads
        // every board, and the one it's on is loaded below.
        await store.reload()
        guard let found = try await store.findTask(id: taskID) else {
            throw KanbanServiceError.invalidResponse(
                AppLocalization.string("Couldn't find Kanban task \(taskID) on your boards.", table: .tasks))
        }
        if found.board != store.loadedBoardSlug {
            // Archived tasks too, as the Tasks page's lookup loads them.
            await store.selectBoard(slug: found.board, includeArchived: true)
            guard store.loadedBoardSlug == found.board else {
                throw KanbanServiceError.invalidResponse(store.errorMessage
                    ?? AppLocalization.string("Couldn't find Kanban task \(taskID) on your boards.", table: .tasks))
            }
        }
        return found.task
    }
}

/// A Kanban task of another combined dashboard's Pulse card, open over the
/// Pulse page on that dashboard's own board (`farPulseTaskStore`).
struct FarPulseTaskSheet: Identifiable {
    let id = UUID()
    let dashboardID: UUID
    let store: KanbanStore
    let task: KanbanTask
}

/// How Do it went on another combined dashboard's Pulse shown in place.
/// `startFarPulseNewChat`'s answer.
enum FarPulseNewChat {
    /// That connection can't take it now: the caller switches there.
    case notInPlace
    /// No chat opened, with what to say when there's more than the page's
    /// own line.
    case failed(String?)
    case started
}

enum FarPulseDoIt {
    /// Not one that opens in place: the caller switches there as before.
    case notInPlace
    /// No chat opened, with what to say when there's more than the page's
    /// own line.
    case failed(String?)
    case opened(PulseDoItOpened)
}
