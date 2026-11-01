import Foundation

/// Each bot's work as Conduit last read it, by bot profile, for the Bot
/// Chat's Work strip and panel and a workstream's bar. It opens on the
/// answer kept on the phone and asks the plugin again (#1533).
@MainActor
final class BotWorkStore: ObservableObject {
    @Published private(set) var snapshots: [String: BotWorkSnapshot] = [:]
    /// What the last action said when it did nothing ("W3 can't continue
    /// while it's running"), for the panel to show.
    @Published var lastRefusal: String?
    /// Actions on their way, by ref, so a button isn't tapped twice.
    @Published private(set) var acting: Set<String> = []

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
        lastRefusal = nil
        acting = []
    }

    func begin(_ ref: String) -> Bool { acting.insert(ref).inserted }
    func end(_ ref: String) { acting.remove(ref) }

    /// Every workstream's chat Conduit knows of, on every bot.
    var workstreamSessionIDs: Set<String> {
        snapshots.values.reduce(into: Set<String>()) { $0.formUnion($1.sessionIDs) }
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

extension BotWorkSnapshot {
    func replacing(_ item: BotWorkItem) -> BotWorkSnapshot {
        var copy = self
        copy.items = items.map { $0.ref == item.ref ? item : $0 }
        return copy
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
    /// when it can't: the strip keeps what it showed.
    func refreshBotWork(profile: String) async {
        guard servesBotWorkstreams else { return }
        let answers = screenAnswers(profile: profile)
        let client = botWorkClient(profile: profile)
        if botWork.snapshot(profile) == nil, let kept = client.kept(in: answers) {
            botWork.set(kept)
        }
        guard isConnected else { return }
        do {
            botWork.set(try await client.list(keptIn: answers))
        } catch {
            // Kept as it was; the next refresh asks again.
        }
    }

    /// The user's own action on a workstream, straight to it: Reply, Stop,
    /// Continue or Check first. No Bot Chat turn; the coordinator sees it
    /// in its next note. True when the plugin did it.
    @discardableResult
    func actOnWorkstream(_ item: BotWorkItem, profile: String, action: BotWorkItem.Action, text: String? = nil) async -> Bool {
        guard botWork.begin(item.ref) else { return false }
        defer { botWork.end(item.ref) }
        botWork.lastRefusal = nil
        do {
            if let updated = try await botWorkClient(profile: profile).act(ref: item.ref, action: action, text: text) {
                botWork.replace(updated, profile: profile)
            }
            Haptics.success()
            await refreshBotWork(profile: profile)
            return true
        } catch DashboardTicketBridgeError.http(_, let detail) where !detail.isEmpty {
            botWork.lastRefusal = detail
        } catch {
            botWork.lastRefusal = AppLocalization.string("Couldn't reach this bot's work. Try again in a moment.")
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
        let known = botWork.workstreamSessionIDs
        guard !known.isEmpty else { return false }
        return !known.isDisjoint(with: SessionContentSearch.identities(of: session))
    }

    func isWorkstreamSession(_ id: String) -> Bool {
        botWork.workstreamSessionIDs.contains(id)
    }
}
