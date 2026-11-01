import Foundation

/// Each bot's work as Conduit last read it, by bot profile, for the Bot
/// Chat's Work strip and panel and a workstream's bar. It opens on the
/// answer kept on the phone and asks the plugin again (#1533).
@MainActor
final class BotWorkStore: ObservableObject {
    @Published private(set) var snapshots: [String: BotWorkSnapshot] = [:] {
        didSet { workstreamSessionIDs = snapshots.values.reduce(into: Set<String>()) { $0.formUnion($1.sessionIDs) } }
    }
    /// What the last action on each bot's work said when it did nothing
    /// ("W3 can't continue while it's running"), for its panel to show.
    @Published private(set) var refusals: [String: String] = [:]
    /// Actions on their way, by bot and ref, so a button isn't tapped twice.
    @Published private(set) var acting: Set<String> = []
    /// Every workstream's chat Conduit knows of, on every bot, worked out
    /// once per list rather than for each chat row.
    private(set) var workstreamSessionIDs: Set<String> = []
    /// Bots whose list is being read, so two views showing it share one read.
    private var reading: Set<String> = []
    /// Bumped by a server change (every bot) and by an action (its bot), so
    /// a list read before either never lands over what came after it.
    private var epoch = 0
    private var actions: [String: Int] = [:]

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

    func replace(_ item: BotWorkItem, profile: String) {
        guard let snapshot = snapshots[profile] else { return }
        snapshots[profile] = snapshot.replacing(item)
    }

    func clear() {
        snapshots = [:]
        refusals = [:]
        acting = []
        reading = []
        epoch += 1
    }

    func refusal(_ profile: String) -> String? { refusals[profile] }

    func setRefusal(_ text: String?, profile: String) {
        guard refusals[profile] != text else { return }
        refusals[profile] = text
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
    func endReading(_ profile: String) { reading.remove(profile) }

    /// Whether a chat row is one of a bot's workstreams, by any of its ids.
    func isWorkstream(_ session: SessionSummary) -> Bool {
        guard !workstreamSessionIDs.isEmpty else { return false }
        return !workstreamSessionIDs.isDisjoint(with: SessionContentSearch.identities(of: session))
    }

    /// The workstream a chat is, with its bot's profile.
    func workstream(forSession ids: Set<String>) -> (profile: String, item: BotWorkItem)? {
        guard !ids.isEmpty else { return nil }
        for (profile, snapshot) in snapshots {
            if let item = snapshot.item(forSession: ids) { return (profile, item) }
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

    /// Shows the bot's kept work first, then asks the plugin again. Quiet
    /// when it can't: the strip keeps what it showed. One read per bot at a
    /// time, so the strip and the panel showing it never race.
    func refreshBotWork(profile: String) async {
        guard servesBotWorkstreams else { return }
        let answers = screenAnswers(profile: profile)
        let client = botWorkClient(profile: profile)
        if botWork.snapshot(profile) == nil, let kept = client.kept(in: answers) {
            botWork.set(kept)
        }
        guard isConnected, botWork.beginReading(profile) else { return }
        defer { botWork.endReading(profile) }
        let mark = botWork.mark(profile)
        do {
            let listed = try await client.list(keptIn: answers)
            // Read before a server change or an action on this bot: the
            // next read has what came after.
            guard botWork.isCurrent(mark, profile: profile) else { return }
            botWork.set(listed)
        } catch {
            // Kept as it was; the next refresh asks again.
        }
    }

    /// The user's own action on a workstream, straight to it: Reply, Stop,
    /// Continue or Check first. No Bot Chat turn; the coordinator sees it
    /// in its next note. True when the plugin did it.
    @discardableResult
    func actOnWorkstream(_ item: BotWorkItem, profile: String, action: BotWorkItem.Action, text: String? = nil) async -> Bool {
        guard botWork.begin(item.ref, profile: profile) else { return false }
        defer { botWork.end(item.ref, profile: profile) }
        botWork.setRefusal(nil, profile: profile)
        // A list read while this is on its way may predate it: it's dropped.
        botWork.noteAction(profile)
        let mark = botWork.mark(profile)
        do {
            let updated = try await botWorkClient(profile: profile).act(ref: item.ref, action: action, text: text)
            // After a server change the row isn't this server's.
            guard botWork.mark(profile).epoch == mark.epoch else { return false }
            botWork.noteAction(profile)
            if let updated {
                botWork.replace(updated, profile: profile)
            }
            Haptics.success()
            // The buttons free up now; the list is read again behind them.
            Task { await refreshBotWork(profile: profile) }
            return true
        } catch DashboardTicketBridgeError.http(_, let detail) where !detail.isEmpty {
            botWork.setRefusal(detail, profile: profile)
        } catch {
            botWork.setRefusal(AppLocalization.string("Couldn't reach this bot's work. Try again in a moment."), profile: profile)
        }
        Haptics.warning()
        await refreshBotWork(profile: profile)
        return false
    }

    /// The bot whose work the open chat is, and the workstream: the bar
    /// over a workstream's chat.
    var activeWorkstream: (profile: String, item: BotWorkItem)? {
        guard let id = activeSessionId, !id.isEmpty, activeRoomSurface == nil else { return nil }
        return botWork.workstream(forSession: chatOwnSessionIDs(for: id).union([id]))
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

    /// Whether a row is one of a bot's workstreams: hidden in Hermes, and
    /// left out of Chats, search and All profiles here, as a Bot Chat is.
    func isWorkstreamRow(_ session: SessionSummary) -> Bool {
        botWork.isWorkstream(session)
    }

    func isWorkstreamSession(_ id: String) -> Bool {
        botWork.workstreamSessionIDs.contains(id)
    }
}
