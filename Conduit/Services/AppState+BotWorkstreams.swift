import Foundation
import OSLog

private let botWorkLogger = Logger(subsystem: "com.milim.relay", category: "BotWork")

/// Each bot's work as Conduit last read it, by bot profile, for the Bot
/// Chat's Work strip and panel and a workstream's bar. It opens on the
/// answer kept on the phone and asks the plugin again (#1533).
@MainActor
final class BotWorkStore: ObservableObject {
    @Published private(set) var snapshots: [String: BotWorkSnapshot] = [:] {
        didSet {
            let ids = snapshots.values.reduce(into: Set<String>()) { $0.formUnion($1.sessionIDs) }
            guard ids != workstreamSessionIDs else { return }
            workstreamSessionIDs = ids
            workstreamsGeneration &+= 1
            onWorkstreamsChanged?()
        }
    }
    /// Called when the set of workstream chats changes, so lists already
    /// shown (All profiles, search, the Chats list) leave out one that just became known.
    var onWorkstreamsChanged: (@MainActor () -> Void)?
    /// What the last action on each bot's work said when it did nothing
    /// ("W3 can't continue while it's running"), for its panel to show.
    /// The last refusal per bot, with the workstream it was for.
    struct Refusal: Equatable {
        let ref: String?
        let text: String
    }
    @Published private(set) var refusals: [String: Refusal] = [:]
    /// Each bot's Resolved list as far as it was read, while its panel
    /// shows it.
    @Published private(set) var resolvedLists: [String: ResolvedList] = [:]
    /// Actions on their way, by bot and ref, so a button isn't tapped twice.
    @Published private(set) var acting: Set<String> = []
    /// Every workstream's chat Conduit knows of, on every bot, worked out
    /// once per list rather than for each chat row.
    private(set) var workstreamSessionIDs: Set<String> = []
    /// Bumped when `workstreamSessionIDs` changes, for the lists kept by it.
    private(set) var workstreamsGeneration = 0
    /// Bots whose list is being read, so two views showing it share one read.
    private var reading: Set<String> = []
    /// When a call's request last read a bot's work before deciding it isn't
    /// a workstream's: again only after a minute while it still hasn't
    /// loaded, so a host whose list won't load doesn't hold every request up
    /// and one failed read isn't the last.
    var callPreReads: [String: Date] = [:]
    static let callPreReadRetry: TimeInterval = 60
    private var rereads: Set<String> = []
    /// Bumped by a server change (every bot) and by an action (its bot), so
    /// a list read before either never lands over what came after it.
    private var epoch = 0
    private var actions: [String: Int] = [:]

    struct ResolvedList: Equatable {
        var items: [BotWorkItem] = []
        var more = false
        var isLoading = false
        var failed = false
    }

    func resolvedList(_ profile: String) -> ResolvedList? { resolvedLists[profile] }

    func setResolvedList(_ list: ResolvedList?, profile: String) {
        guard resolvedLists[profile] != list else { return }
        resolvedLists[profile] = list
    }

    /// A row the user resolved joins the top of the Resolved list, one
    /// started for it if none was read, so its chat, if open, still knows
    /// it (the rest pages in after it); one reopened leaves it.
    func fileResolved(_ item: BotWorkItem, profile: String) {
        guard var list = resolvedLists[profile] else {
            if item.isClosed { resolvedLists[profile] = ResolvedList(items: [item], more: true) }
            return
        }
        list.items.removeAll { $0.ref == item.ref }
        if item.isClosed { list.items.insert(item, at: 0) }
        resolvedLists[profile] = list
    }

    struct ReadMark: Equatable {
        let epoch: Int
        let actions: Int
    }

    func mark(_ profile: String) -> ReadMark { ReadMark(epoch: epoch, actions: actions[profile, default: 0]) }
    func isCurrent(_ mark: ReadMark, profile: String) -> Bool { mark == self.mark(profile) }
    func noteAction(_ profile: String) { actions[profile, default: 0] += 1 }

    func snapshot(_ profile: String) -> BotWorkSnapshot? { snapshots[profile] }

    func set(_ snapshot: BotWorkSnapshot) {
        guard snapshots[snapshot.profile] != snapshot else { return }
        snapshots[snapshot.profile] = snapshot
    }

    /// A row as an action left it; `reopened` puts one back from the
    /// Resolved list.
    func replace(_ item: BotWorkItem, profile: String, reopened: Bool = false) {
        guard let snapshot = snapshots[profile] else { return }
        snapshots[profile] = reopened ? snapshot.reopening(item) : snapshot.replacing(item)
    }

    func clear() {
        snapshots = [:]
        resolvedLists = [:]
        refusals = [:]
        acting = []
        reading = []
        rereads = []
        callPreReads = [:]  // another server's bots: read again there
        epoch += 1
    }

    /// A bot's refusal for the panel; with `ref`, only one for that
    /// workstream, so a late refusal for W1 never shows on W2's bar.
    func refusal(_ profile: String, ref: String? = nil) -> String? {
        guard let refusal = refusals[profile] else { return nil }
        if let ref, refusal.ref != ref { return nil }
        return refusal.text
    }

    func setRefusal(_ text: String?, profile: String, ref: String? = nil) {
        let refusal = text.map { Refusal(ref: ref, text: $0) }
        guard refusals[profile] != refusal else { return }
        refusals[profile] = refusal
    }

    static func actingKey(profile: String, ref: String) -> String { "\(profile)\u{1F}\(ref)" }

    func isActing(_ ref: String, profile: String) -> Bool {
        acting.contains(Self.actingKey(profile: profile, ref: ref))
    }

    func begin(_ ref: String, profile: String) -> Bool {
        acting.insert(Self.actingKey(profile: profile, ref: ref)).inserted
    }

    func end(_ ref: String, profile: String) {
        acting.remove(Self.actingKey(profile: profile, ref: ref))
    }

    func beginReading(_ profile: String) -> Bool { reading.insert(profile).inserted }
    func isReading(_ profile: String) -> Bool { reading.contains(profile) }
    func endReading(_ profile: String) { reading.remove(profile) }
    /// An action asked for a read while one was on its way, which its mark
    /// will drop: the read under way goes again when it's done.
    func readAgain(_ profile: String) { rereads.insert(profile) }
    func takeReadAgain(_ profile: String) -> Bool { rereads.remove(profile) != nil }

    /// Whether a chat row is one of a bot's workstreams, by any of its ids.
    func isWorkstream(_ session: SessionSummary) -> Bool {
        Self.isWorkstream(session, among: workstreamSessionIDs)
    }

    /// The same rule over a list of workstream ids.
    nonisolated static func isWorkstream(
        _ session: SessionSummary,
        among workstreamSessionIDs: Set<String>
    ) -> Bool {
        guard !workstreamSessionIDs.isEmpty else { return false }
        return !workstreamSessionIDs.isDisjoint(with: SessionContentSearch.identities(of: session))
    }

    /// The workstream a chat is, with its bot's profile.
    func workstream(forSession ids: Set<String>) -> (profile: String, item: BotWorkItem)? {
        guard !ids.isEmpty else { return nil }
        for (profile, snapshot) in snapshots {
            if let item = snapshot.item(forSession: ids) { return (profile, item) }
        }
        // A resolved one, opened from the Resolved list.
        for (profile, list) in resolvedLists {
            if let item = list.items.first(where: { $0.kind == .workstream && $0.fromCall.isEmpty && ids.contains($0.sessionID) }) {
                return (profile, item)
            }
        }
        return nil
    }
}


extension AppState {
    /// Whether the host's plugin serves the Work panel's routes.
    var servesBotWorkstreams: Bool { notifierPlugin.reports(BotWorkstreamsClient.capability) }

    func botWorkClient(profile: String) -> BotWorkstreamsClient {
        BotWorkstreamsClient(
            profile: profile,
            parameter: notifierPlugin.dashboardProfileParameter,
            request: { [weak self] path, method, body in
                guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
                return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: 30_000)
            }
        )
    }

    /// A voice call's job kept in its bot's registry (M5), so the Work
    /// panel lists it as a call's. Best effort, off the job's path: a
    /// plugin without the route, or a bot whose work is off, keeps none.
    func keepVoiceJobInRegistry(profile: String?, sessionID: String, title: String, instructions: String,
                                fromWatch: Bool, callChat: String? = nil, endedWith: String? = nil,
                                call: String? = nil) {
        guard let via = Self.voiceJobAdoptVia(plugin: notifierPlugin, sessionID: sessionID, fromWatch: fromWatch)
        else { return }
        let bot = profile ?? activeProfile
        let client = botWorkClient(profile: bot)
        let dashboard = activeDashboardID
        Task { @MainActor [weak self] in
            var kept = false
            _ = await AppState.adoptOnce(
                stillCurrent: { AppState.sameDashboard(madeOn: dashboard, now: self?.activeDashboardID, appAlive: self != nil) },
                send: { _ = try await client.adopt(sessionID: sessionID, title: title, via: via, goal: instructions,
                                                   chat: callChat, result: endedWith, call: call)
                        kept = true },
                wait: { try? await Task.sleep(for: .seconds(3)) },
                failed: { attempt, error in
                    botWorkLogger.notice("Keeping a voice job in its bot's work registry failed (try \(attempt, privacy: .public)): \(String(describing: type(of: error)), privacy: .public) \(String(describing: error))")
                }
            )
            // The Work panel shows it now rather than at its next read.
            if kept { await self?.refreshBotWork(profile: bot) }
        }
    }

    /// A call that kept a job with `chat` ended: the bot's plugin sends what
    /// its Bot Chat's call held (Classic never saves its turns with the
    /// chat, so this is its only end). Best effort, on the dashboard in use.
    func voiceCallLeftChat(profile: String?, chat: String, call: String? = nil) {
        guard notifierPlugin.reports(BotWorkstreamsClient.callEndedCapability), !chat.isEmpty else { return }
        let client = botWorkClient(profile: profile ?? activeProfile)
        let dashboard = activeDashboardID
        Task { @MainActor [weak self] in
            _ = await AppState.adoptOnce(
                stillCurrent: { AppState.sameDashboard(madeOn: dashboard, now: self?.activeDashboardID, appAlive: self != nil) },
                send: { try await client.callEnded(chat: chat, call: call) },
                wait: { try? await Task.sleep(for: .seconds(3)) },
                failed: { attempt, error in
                    botWorkLogger.notice("Telling the bot's work a call ended failed (try \(attempt, privacy: .public)): \(String(describing: type(of: error)), privacy: .public)")
                }
            )
        }
    }

    /// A request from a call kept with one of a bot's workstreams' chats
    /// (Eric 2026-11-02): it goes into the workstream's own session through
    /// its bot's plugin, which takes it as an interrupt while the
    /// workstream works and as its next turn otherwise; no job session is
    /// made. What to tell the call (for the live model, not localized), or
    /// nil when the chat isn't a workstream's.
    func sendCallRequestToWorkstream(_ thread: VoiceThreadTarget, _ request: String) async -> String? {
        let ids = Set([thread.runtimeSessionID, thread.storedSessionID ?? ""].filter { !$0.isEmpty })
        let bot = thread.profile ?? activeProfile
        if botWork.workstream(forSession: ids) == nil, botWork.snapshot(bot) == nil,
           botWork.callPreReads[bot].map({ Date().timeIntervalSince($0) >= BotWorkStore.callPreReadRetry }) ?? true {
            botWork.callPreReads[bot] = Date()
            // Its bot's work isn't read yet (just after a launch): read it
            // before the request becomes a job of its own.
            await refreshBotWork(profile: bot)
        }
        // A read already under way (the launch's own): its answer, not a
        // job, decides, for up to five seconds.
        var waited = 0
        while botWork.workstream(forSession: ids) == nil, botWork.snapshot(bot) == nil,
              botWork.isReading(bot), waited < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard let (profile, item) = botWork.workstream(forSession: ids) else {
            // A workstream's chat whose row isn't loaded (an older resolved
            // one): still no job of its own.
            guard botWork.workstreamSessionIDs.isDisjoint(with: ids) else {
                return "This workstream isn't loaded right now, so that wasn't passed on. Say so, and suggest opening it from the Work panel."
            }
            return nil
        }
        let words = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return "There were no words to pass on." }
        // Another action on it is on its way (a Stop or Reply from the Work
        // panel): nothing was sent, so a retry can't send it twice.
        guard !botWork.isActing(item.ref, profile: profile) else {
            return "This workstream is busy with another action, so that wasn't passed on yet. Say so, and offer to try again in a moment."
        }
        guard await actOnWorkstream(item, profile: profile, action: .send, text: words) else {
            return "Hermes couldn't pass that to this workstream just now. Say so, and offer to try again."
        }
        return Self.workstreamCallSent
    }

    /// What a workstream's call is told once its request went in.
    static let workstreamCallSent = "Sent to this workstream, in its own session: if it was working, Hermes takes this as an interrupt and keeps its work so far; otherwise it starts on it now. Its reply shows in the workstream's chat and its bot's Work panel, not on this call, so don't guess it."

    /// Sends a voice job's adopt, and once more after `wait` if that one
    /// fails: a dropped request would leave the job out of the panel for
    /// good. Only while `stillCurrent` (the dashboard the job was made on;
    /// the client's transport reads the current one). How many were sent.
    @discardableResult
    static func adoptOnce(stillCurrent: () -> Bool, send: () async throws -> Void, wait: () async -> Void,
                          failed: (Int, Error) -> Void) async -> Int {
        var sent = 0
        for attempt in 1...2 {
            guard stillCurrent() else { return sent }
            sent += 1
            do {
                try await send()
                return sent
            } catch {
                failed(attempt, error)
                if attempt == 1 { await wait() }
            }
        }
        return sent
    }

    /// Whether an adopt still goes to the dashboard its job was made on:
    /// never once the app moved to another, or is gone.
    nonisolated static func sameDashboard(madeOn: UUID?, now: UUID?, appAlive: Bool) -> Bool {
        appAlive && now == madeOn
    }

    /// The call a job is kept as ("phone" or "watch"), or nil when none is
    /// sent: a plugin that doesn't keep bot work (`work-adopt`), or no session.
    nonisolated static func voiceJobAdoptVia(plugin: NotifierPluginStatus, sessionID: String, fromWatch: Bool) -> String? {
        guard plugin.reports(BotWorkstreamsClient.adoptCapability), !sessionID.isEmpty else { return nil }
        return fromWatch ? "watch" : "phone"
    }

    /// Whether the host's plugin serves Edit Bot > Work.
    var servesBotWorkSettings: Bool { notifierPlugin.reports(BotWorkSettingsClient.capability) }

    func botWorkSettingsClient(profile: String) -> BotWorkSettingsClient {
        BotWorkSettingsClient(
            profile: profile,
            parameter: notifierPlugin.dashboardProfileParameter,
            request: { [weak self] path, method, body in
                guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
                return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: 30_000)
            }
        )
    }

    /// A bot's work settings, or nil when they couldn't be read.
    func loadBotWorkSettings(profile: String) async -> BotWorkSettings? {
        guard servesBotWorkSettings, isConnected else {
            botWorkLogger.notice("Work settings not read: \(self.servesBotWorkSettings ? "not connected" : "plugin doesn't serve them", privacy: .public)")
            return nil
        }
        do {
            return try await botWorkSettingsClient(profile: profile).load()
        } catch {
            botWorkLogger.notice("Reading the work settings failed: \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Saves the user's change to a bot's work settings; the settings as the
    /// plugin keeps them now, or nil when it didn't save. Turning the
    /// coordinator on or off shows in the Bot Chat on its next read.
    func saveBotWorkSettings(_ settings: BotWorkSettings, from old: BotWorkSettings,
                             profile: String) async -> BotWorkSettings? {
        let change = settings.change(from: old)
        guard !change.isEmpty else { return settings }
        guard servesBotWorkSettings, isConnected,
              let saved = try? await botWorkSettingsClient(profile: profile).save(change) else { return nil }
        if saved.policy != old.policy {
            Task { await refreshBotWork(profile: profile) }
        }
        return saved
    }

    /// A bot's work as read. The open chat's title reads it too (a
    /// workstream's chat takes its task's title), and the chat screen
    /// watches only AppState, so it's told when that changes.
    private func setBotWork(_ snapshot: BotWorkSnapshot) {
        whileKeepingTitle { botWork.set(snapshot) }
        // An open workstream's chat shows its checklist as its Tasks line.
        refreshWorkPlan()
    }

    /// Runs a change to the bots' work and tells the chat screen when the
    /// open chat's task title changed with it.
    private func whileKeepingTitle(_ change: () -> Void) {
        let before = activeWorkstream?.item.shownTitle
        let stoppable = workstreamStoppedByComposer != nil
        change()
        // Its title and the composer's Stop both read the open workstream.
        if activeWorkstream?.item.shownTitle != before || (workstreamStoppedByComposer != nil) != stoppable {
            objectWillChange.send()
        }
    }

    /// Shows the bot's kept work first, then asks the plugin again. Quiet
    /// when it can't: the strip keeps what it showed. One read per bot at a
    /// time, so the strip and the panel showing it never race.
    func refreshBotWork(profile: String, afterAction: Bool = false) async {
        guard servesBotWorkstreams else { return }
        let answers = screenAnswers(profile: profile)
        let client = botWorkClient(profile: profile)
        if botWork.snapshot(profile) == nil, let kept = client.kept(in: answers) {
            setBotWork(kept)
        }
        guard isConnected else { return }
        guard botWork.beginReading(profile) else {
            // The read under way predates the action, so it's dropped: it
            // reads again when it's done, and the row shows what came after.
            if afterAction { botWork.readAgain(profile) }
            return
        }
        defer { botWork.endReading(profile) }
        repeat {
            let mark = botWork.mark(profile)
            do {
                let listed = try await client.list(keptIn: answers)
                // Read before a server change or an action on this bot: the
                // next read has what came after.
                guard botWork.isCurrent(mark, profile: profile) else { continue }
                setBotWork(listed)
            } catch {
                // Kept as it was; the next refresh asks again.
            }
        } while botWork.takeReadAgain(profile)
    }

    /// The user's own action on a workstream, straight to it: Reply, Stop,
    /// Continue or Check first. No Bot Chat turn; the coordinator sees it
    /// in its next note. True when the plugin did it.
    @discardableResult
    func actOnWorkstream(_ item: BotWorkItem, profile: String, action: BotWorkItem.Action, text: String? = nil,
                         requestID: String? = nil) async -> Bool {
        guard botWork.begin(item.ref, profile: profile) else { return false }
        defer { botWork.end(item.ref, profile: profile) }
        botWork.setRefusal(nil, profile: profile)
        // A list read while this is on its way may predate it: it's dropped.
        botWork.noteAction(profile)
        let mark = botWork.mark(profile)
        do {
            let updated = try await botWorkClient(profile: profile).act(ref: item.ref, action: action, text: text,
                                                                         requestID: requestID)
            // A call's job stopped here is stopped for its call too, not
            // settled as finished when its session goes quiet: the stop went
            // in, even if the server changed meanwhile.
            if action == .stop, !item.call.isEmpty {
                voiceBackgroundJobSupervisor.stoppedFromWorkPanel(sessionID: item.sessionID)
            }
            // After a server change the row isn't this server's (the plugin did it all the same).
            guard botWork.mark(profile).epoch == mark.epoch else { return true }
            botWork.noteAction(profile)
            if let updated {
                whileKeepingTitle {
                    botWork.replace(updated, profile: profile, reopened: action == .reopen)
                    botWork.fileResolved(updated, profile: profile)
                }
                refreshWorkPlan()
            }
            Haptics.success()
            // The buttons free up now; the list is read again behind them.
            Task { await refreshBotWork(profile: profile, afterAction: true) }
            return true
        } catch {
            // After a server change the refusal isn't this server's either.
            guard botWork.mark(profile).epoch == mark.epoch else { return false }
            if case DashboardTicketBridgeError.http(_, let detail) = error, !detail.isEmpty {
                botWork.setRefusal(detail, profile: profile, ref: item.ref)
            } else {
                botWork.setRefusal(AppLocalization.string("Couldn't reach this bot's work. Try again in a moment."),
                                   profile: profile, ref: item.ref)
            }
        }
        Haptics.warning()
        // The refusal shows now; the row is read again behind it.
        Task { await refreshBotWork(profile: profile, afterAction: true) }
        return false
    }

    /// Approve once or deny the approval a workstream's "Needs you" card
    /// shows, as its chat's card would; the chat still offers it too. The
    /// plugin answers it by its request id, in the process the workstream
    /// runs in (Hermes answers a session's approvals only there). When the
    /// workstream's chat is open with that card, its card answers it, so the
    /// card shows the answer. True when Hermes took it.
    @discardableResult
    func answerWorkstreamApproval(_ approval: BotWorkItem.Approval, item: BotWorkItem, profile: String,
                                  approve: Bool) async -> Bool {
        if let message = messages.first(where: { message in
            guard let shown = message.approval, shown.status == .pending || shown.status == .error else { return false }
            return shown.requestId == approval.requestID
        }) {
            guard botWork.begin(item.ref, profile: profile) else { return false }
            defer { botWork.end(item.ref, profile: profile) }
            botWork.setRefusal(nil, profile: profile)
            botWork.noteAction(profile)
            await respondToApproval(messageId: message.id, choice: approve ? "once" : "deny")
            let status = messages.first { $0.id == message.id }?.approval?.status
            let took = status == .approved || status == .rejected
            if took {
                Haptics.success()
            } else if status == .expired || status == .error {
                Haptics.warning()
                // Gone only when Hermes says so; a failed send leaves it to try again.
                let text = status == .expired
                    ? AppLocalization.string("\(item.ref) isn't waiting on that any more.")
                    : AppLocalization.string("Couldn't reach this bot's work. Try again in a moment.")
                botWork.setRefusal(text, profile: profile, ref: item.ref)
            } else if status == .pending || status == .submitting {
                // The chat's card didn't take it (its send was held back):
                // the tap says so instead of looking dead.
                Haptics.warning()
                botWork.setRefusal(AppLocalization.string("Couldn't reach this bot's work. Try again in a moment."),
                                   profile: profile, ref: item.ref)
            }
            // Otherwise (the chat changed meanwhile) the refresh below says where it is.
            Task { await refreshBotWork(profile: profile, afterAction: true) }
            return took
        }
        return await actOnWorkstream(item, profile: profile, action: approve ? .approve : .deny,
                                     requestID: approval.requestID)
    }

    /// The bot's Resolved list: its first page, or the next one (`more`).
    func loadResolvedWork(profile: String, more: Bool = false) async {
        guard servesBotWorkstreams else { return }
        var list = botWork.resolvedList(profile) ?? BotWorkStore.ResolvedList()
        guard isConnected else {
            // Offline: say so, instead of a spinner nothing will end.
            if !list.isLoading, !list.failed {
                list.failed = true
                botWork.setResolvedList(list, profile: profile)
            }
            return
        }
        guard !list.isLoading else { return }
        // The oldest closed time shown: a last row without one would ask
        // for the first page again, and Show more would never grow.
        let before = more ? list.items.compactMap(\.closedAt).min() : nil
        list.isLoading = true
        list.failed = false
        botWork.setResolvedList(list, profile: profile)
        let mark = botWork.mark(profile)
        do {
            let page = try await botWorkClient(profile: profile).resolved(before: before)
            guard botWork.mark(profile).epoch == mark.epoch else { return }
            // Read before an action on this bot (a reopen it'd put back):
            // read again from the top.
            guard botWork.isCurrent(mark, profile: profile) else {
                var stale = botWork.resolvedList(profile) ?? list
                stale.isLoading = false
                botWork.setResolvedList(stale, profile: profile)
                await loadResolvedWork(profile: profile)
                return
            }
            var now = botWork.resolvedList(profile) ?? list
            let shown = more ? now.items : []
            let refs = Set(shown.map(\.ref))
            now.items = shown + page.items.filter { !refs.contains($0.ref) }
            now.more = page.more
            now.isLoading = false
            // The open chat may be one of these (its title is its task's).
            whileKeepingTitle { botWork.setResolvedList(now, profile: profile) }
        } catch {
            guard botWork.mark(profile).epoch == mark.epoch else { return }
            var now = botWork.resolvedList(profile) ?? list
            now.isLoading = false
            now.failed = true
            botWork.setResolvedList(now, profile: profile)
        }
    }

    /// The bot whose work the open chat is, and the workstream: the bar
    /// over a workstream's chat.
    var activeWorkstream: (profile: String, item: BotWorkItem)? {
        guard let id = activeSessionId, !id.isEmpty, activeRoomSurface == nil else { return nil }
        return botWork.workstream(forSession: chatOwnSessionIDs(for: id).union([id]))
    }

    /// The open workstream when the composer's Stop stops it: its turn runs
    /// in the plugin, not on this chat's socket, so the plugin stops it.
    var workstreamStoppedByComposer: (profile: String, item: BotWorkItem)? {
        guard let open = activeWorkstream, !open.item.isClosed, open.item.actions.contains(.stop) else { return nil }
        return open
    }

    /// A workstream's chat, on its bot's profile, as its link opens it.
    func openWorkstream(_ item: BotWorkItem, profile: String) {
        guard !item.sessionID.isEmpty else { return }
        openAppLink(.session(id: item.sessionID, profile: profile))
    }

    /// Back to the Bot Chat coordinating a workstream.
    func openCoordinator(profile: String) {
        openAppLink(.bot(profile: profile))
    }

    /// Whether a row is one of a bot's workstreams, left out of Chats,
    /// search and All profiles here, as a Bot Chat is. Hermes hides an open
    /// one; a resolved one is shown there so Desktop's links open it
    /// (notifier #540), so these lists go by the plugin's list of them.
    func isWorkstreamRow(_ session: SessionSummary) -> Bool {
        botWork.isWorkstream(session)
    }

    /// Each bot whose work this app hasn't read yet, read once as the
    /// roster lands: a resolved workstream is shown in Hermes (notifier
    /// #540), so its chat leaves the Chats list only once its bot's list of
    /// workstreams is known, whether or not its Bot Chat was opened.
    func readUnreadBotsWork() {
        guard servesBotWorkstreams else { return }
        for bot in botRoster where botWork.snapshot(bot.name) == nil {
            Task { await refreshBotWork(profile: bot.name) }
        }
    }

    func isWorkstreamSession(_ id: String) -> Bool {
        botWork.workstreamSessionIDs.contains(id)
    }

    /// A workstream that just became known leaves the lists already shown:
    /// All profiles drops its row, and search and the Chats list redraw without it.
    func workstreamsChanged() {
        if allProfilesCatalog.sessions.contains(where: isWorkstreamRow) {
            allProfilesCatalog.sessions.removeAll(where: isWorkstreamRow)
        } else {
            // Nothing published changed; search's rows are worked out as
            // the Chats screen draws, so it draws again.
            objectWillChange.send()
        }
    }
}
