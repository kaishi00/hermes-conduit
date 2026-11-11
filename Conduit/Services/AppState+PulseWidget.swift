//
//  AppState+PulseWidget.swift
//  Conduit
//
//  The Pulse widget (issue 2190). The widget reads Pulse's feed itself,
//  with a host pass Conduit keeps for it while one is on the Home Screen
//  (PulseWidgetAccess), so it shows new cards without Conduit running:
//  every Pulse push reloads it (the Notification Service Extension), and
//  so does WidgetKit every half hour or so. Done and Not now go to the host
//  from the widget the same way. Do it sends a message to a chat, which
//  takes Conduit's connection: iOS runs it here, in the background
//  (PulseWidgetDoItIntent), the way a shortcut's send runs (#2164).
//

import Foundation
import WidgetKit

/// The app's side of the widget's Do it.
enum PulseWidgetRunner {
    static func run(_ action: PulseWidgetAction, card: Int, dashboard: String) async {
        guard let dashboardID = UUID(uuidString: dashboard) else { return }
        await runOnMain(action, card: card, dashboardID: dashboardID)
    }

    @MainActor
    private static func runOnMain(_ action: PulseWidgetAction, card: Int, dashboardID: UUID) async {
        await AppStateRuntimeRegistry.shared.appState.runPulseWidgetAction(action, card: card, dashboardID: dashboardID)
    }
}

extension AppState {
    var pulseWidgetStore: PulseWidgetStore? {
        pulseWidgetStoreOverride ?? PulseWidgetStore.production
    }

    func reloadPulseWidget() {
        if let pulseWidgetReloadOverride { return pulseWidgetReloadOverride() }
        WidgetCenter.shared.reloadTimelines(ofKind: ConduitWidgetKind.pulse)
    }

    /// Whether a Pulse widget is on the Home Screen; nil when WidgetKit
    /// couldn't say.
    private func hasPulseWidget() async -> Bool? {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let kinds = (try? result.get())?.map(\.kind)
                continuation.resume(returning: kinds?.contains(ConduitWidgetKind.pulse))
            }
        }
    }

    /// Keeps what the widget reads Pulse with current: the dashboard in
    /// use, its host pass and the Pulse features its plugin serves. Only
    /// while a Pulse widget is on the Home Screen and the plugin has said it
    /// serves Pulse here; otherwise the item goes, and so does what the
    /// widget showed when it's another dashboard's. At each connect, each
    /// return to the screen, and when a native sign-in's token rotates.
    func savePulseWidgetAccess() async {
        guard let dashboardID = activeDashboardID else { return }
        // Another dashboard is in use now: the widget stops reading the old
        // one's before this one has connected.
        if let kept = PulseWidgetKeychain.load(), kept.dashboardID != dashboardID {
            removePulseWidget(dashboardID: kept.dashboardID)
        }
        guard let bridge = dashboardTicketBridge, notifierPlugin.state != .unknown else { return }
        let installed = showsPulseScreen ? await hasPulseWidget() : false
        // WidgetKit couldn't list the widgets: what the widget has stays.
        guard let installed else { return }
        guard installed else {
            removePulseWidget()
            return
        }
        guard let pass = await dashboardHostPass(bridge: bridge, dashboardID: dashboardID),
              activeDashboardID == dashboardID, showsPulseScreen else { return }
        let capabilities = PulseWidgetAccess.widgetCapabilities.filter { notifierPlugin.reports($0) }.sorted()
        let access = PulseWidgetAccess(dashboardID: dashboardID, pass: pass, capabilities: capabilities)
        let before = PulseWidgetKeychain.load()
        guard PulseWidgetKeychain.save(access) else { return }
        // Another dashboard, a new sign-in or different features: read again.
        if before?.dashboardID != dashboardID || before?.capabilities != capabilities
            || before?.pass.headers != pass.headers {
            if let kept = pulseWidgetStore?.read(), kept.dashboardID != dashboardID { pulseWidgetStore?.remove() }
            reloadPulseWidget()
        }
    }

    /// No Pulse on the dashboard in use (the plugin said so), no Pulse
    /// widget, or `dashboardID` removed or signed out of: the widget can't
    /// read Pulse any more and shows nothing of it.
    func removePulseWidget(dashboardID: UUID? = nil) {
        let access = PulseWidgetKeychain.load()
        let kept = pulseWidgetStore?.read()
        // Each goes only when it's the named dashboard's (or none was named).
        var changed = false
        if let access, dashboardID == nil || access.dashboardID == dashboardID {
            PulseWidgetKeychain.clear()
            changed = true
        }
        if let kept, dashboardID == nil || kept.dashboardID == dashboardID, pulseWidgetStore?.remove() == true {
            changed = true
        }
        if changed { reloadPulseWidget() }
    }

    /// A feed read in Conduit (the Pulse screen's, the Chats button's) or the
    /// screen's own change (Done, Not now, Undo): when the open cards differ
    /// from what the widget last had, it reads again, so it never shows a
    /// card handled on the screen.
    func pulseWidgetFeedChanged(_ page: PulseFeedPage) {
        let open = Dictionary(
            page.cards.filter { $0.isRatable && !$0.isCleared && !$0.isHeld && !$0.isProposal }
                .map { ($0.id, $0.createdAt?.timeIntervalSince1970 ?? 0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard open != pulseWidgetCardsSeen else { return }
        pulseWidgetCardsSeen = open
        reloadPulseWidget()
    }

    /// The widget's Do it, with Conduit in the background or not running:
    /// on the dashboard the widget showed, which must be the one in use (a
    /// button never switches dashboards), against the card as the feed has
    /// it now. The widget then shows the row as sent, or why it wasn't.
    func runPulseWidgetAction(_ action: PulseWidgetAction, card id: Int, dashboardID: UUID) async {
        guard action == .doIt else { return }
        guard beginPulseWidgetDoIt(card: id, dashboardID: dashboardID) else { return }
        defer { pulseWidgetDoItsRunning.remove(PulseWidgetLink(dashboardID: dashboardID, card: id)) }
        // As a shortcut's run: it may reconnect on its own while it lasts.
        shortcutSendsRunning += 1
        defer { endShortcutSend() }
        releaseLaunchDashboardChoice(for: "a Pulse widget button")
        let deadline = Date().addingTimeInterval(Self.pulseWidgetRunTime)
        let note: String?
        do {
            try await doPulseCardFromWidget(id, dashboardID: dashboardID, deadline: deadline)
            note = nil
            markPulseWidgetRow(id, dashboardID: dashboardID)
        } catch PulseWidgetDoItSkip.nothingToDo {
            note = nil
        } catch let error as ShortcutSendError {
            note = error.message
        } catch {
            note = PulseRefusal.message(for: error)
        }
        guard let note, let store = pulseWidgetStore, let kept = store.read(), kept.dashboardID == dashboardID else { return }
        if (try? store.write(kept.with(note: .some(note), noteAt: Date()))) == true { reloadPulseWidget() }
    }

    /// Whether a widget Do it may send: not while one for the same card on
    /// the same dashboard is sending, nor on a row the widget shows as sent.
    /// Reserves the card when it may; the caller frees it.
    func beginPulseWidgetDoIt(card id: Int, dashboardID: UUID) -> Bool {
        if let kept = pulseWidgetStore?.read(), kept.dashboardID == dashboardID,
           kept.cards.first(where: { $0.id == id })?.sentAt != nil { return false }
        return pulseWidgetDoItsRunning.insert(PulseWidgetLink(dashboardID: dashboardID, card: id)).inserted
    }

    /// iOS gives an intent about 30 seconds.
    static let pulseWidgetRunTime: TimeInterval = 25

    /// The row Do it sent shows so until Pulse sees the thing done.
    private func markPulseWidgetRow(_ id: Int, dashboardID: UUID) {
        guard let store = pulseWidgetStore, let kept = store.read(), kept.dashboardID == dashboardID else { return }
        let marked = kept.cards.map { row -> PulseWidgetCard in
            var row = row
            if row.id == id { row.sentAt = Date() }
            return row
        }
        if (try? store.write(kept.with(cards: marked, note: .some(nil)))) == true { reloadPulseWidget() }
    }

    /// Sends the card's Do it message; throws `nothingToDo` when the card
    /// was handled meanwhile, takes no Do it now, or the widget showed
    /// another dashboard (it reads the one in use when it reloads).
    private func doPulseCardFromWidget(_ id: Int, dashboardID: UUID, deadline: Date) async throws {
        guard await connectForBackgroundRun(deadline: deadline) else { throw ShortcutSendError.notConnected }
        guard activeDashboardID == dashboardID else { throw PulseWidgetDoItSkip.nothingToDo }
        // Which cards take Do it depends on what the plugin serves.
        if notifierPlugin.state == .unknown { await refreshNotifierPluginStatus() }
        guard showsPulseScreen, activeDashboardID == dashboardID else { throw PulseWidgetDoItSkip.nothingToDo }
        let client = pulseClient
        let page = try await client.feed(proposals: pulseSuggests, looks: pulseLooks)
        guard activeDashboardID == dashboardID else { throw PulseWidgetDoItSkip.nothingToDo }
        // Pulse's chat and profile as the host names them now, which a card
        // from no chat goes to.
        applyPulseFeed(page)
        guard let card = page.cards.first(where: { $0.id == id }), !card.isCleared,
              canActOnPulseCard(card), !canAskFromPulseCard(card) else { throw PulseWidgetDoItSkip.nothingToDo }
        try await sendPulseCardFromWidget(card, deadline: deadline)
        // Pulse reads the chat once Hermes has answered and marks the card
        // done itself, as after the screen's Do it.
        if canMarkPulseCardDone(card), notifierPlugin.reports(PulseClient.actedCapability) {
            try? await client.acted(card: card.id)
        }
    }

    /// Do it from the widget: the card's message goes to the chat it came
    /// from, or for one from no chat (the calendar, reminders, the
    /// Shortcuts inbox, a Kanban task's worker) to a new chat in Pulse's
    /// profile, where Pulse reads what came of it, as the screen's Do it
    /// would open them. The widget has no composer, so it's sent as it is.
    private func sendPulseCardFromWidget(_ card: PulseCard, deadline: Date) async throws {
        guard let dashboardID = activeDashboardID else { throw ShortcutSendError.notConnected }
        var request = ShortcutSendRequest(text: card.actionMessage, chatName: nil, profile: pulseHomeProfile,
                                          waitsForAnswer: false)
        if pulseCardHasChat(card) {
            let profile = card.profile.isEmpty ? pulseHomeProfile : card.profile
            request.chat = ShortcutPickedChat(
                dashboardID: dashboardID,
                reference: WidgetConversationReference(kind: .dashboard, scopeProfile: profile, botName: nil, botLabel: nil,
                                                       sessionID: card.chatID, isUnverified: false),
                title: card.chatTitle.isEmpty ? nil : card.chatTitle
            )
        } else {
            request.newChatTitle = PulseWidgetFeed.plain(card.title.isEmpty ? card.news : card.title,
                                                         markdown: card.kind != "followup")
        }
        _ = try await ShortcutSender(backend: makeShortcutSendBackend()).send(request, deadline: deadline)
    }

    /// A tap on the Pulse widget: the Pulse screen, at the card tapped, on
    /// the dashboard the widget showed, switching to it first as a tapped
    /// Pulse push does, but never during a call.
    func openPulseFromWidget(_ link: PulseWidgetLink) {
        releaseLaunchDashboardChoice(for: "the Pulse widget")
        if link.dashboardID == activeDashboardID {
            openPulse(card: link.card)
            return
        }
        guard savedDashboardRegistry.dashboard(with: link.dashboardID) != nil else {
            removePulseWidget(dashboardID: link.dashboardID)
            return
        }
        guard !isVoiceCallInProgress else {
            showCallRefusal(AppLocalization.string("End the call to open a chat in another workspace."))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.switchDashboard(to: link.dashboardID)
            guard self.activeDashboardID == link.dashboardID else { return }
            self.openPulse(card: link.card)
        }
    }
}

/// The widget's Do it found nothing to send.
private enum PulseWidgetDoItSkip: Error {
    case nothingToDo
}
