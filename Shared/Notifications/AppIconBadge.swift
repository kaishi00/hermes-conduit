import Foundation

/// The number on Conduit's app icon (issue 3458): how many chats wait on the
/// user, each counted once. Shared with the Notification Service Extension,
/// which counts a push in as it arrives so the number moves while Conduit
/// isn't running; Conduit counts again whenever what it knows changes.
///
/// A chat counts when it has a reply the user hasn't seen or an approval or
/// question waiting (Needs you). What Conduit knows (its Chats list's unread
/// rows, Needs you) and the notifications still in Notification Center are
/// both counted, a chat named by both once. A notification for a chat Conduit
/// knows is read, or a wait it knows was answered, is left out (`cleared`),
/// since a chat read on another device keeps its notification here.
enum AppIconBadge {
    enum Mode: String, CaseIterable, Identifiable {
        /// Every chat with an unseen reply or a wait.
        case chats
        /// Only chats with an approval or question waiting.
        case needsYou
        case off

        var id: String { rawValue }
    }

    /// One chat the number counts: the ids it goes by (its runtime and
    /// stored ids, `room:<id>` for a group room) and whether it waits on the
    /// user.
    struct Chat: Codable, Hashable {
        var ids: [String]
        var waits: Bool

        init(ids: [String], waits: Bool) {
            var seen = Set<String>()
            self.ids = ids
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            self.waits = waits
        }

        func shares(_ other: Chat) -> Bool { !Set(ids).isDisjoint(with: other.ids) }
        func shares(_ ids: [String]) -> Bool { !Set(self.ids).isDisjoint(with: ids) }
    }

    /// What Conduit last counted, for the extension to count a push in.
    struct Ledger: Codable, Equatable {
        /// The chats Conduit knows wait on the user.
        var known: [Chat] = []
        /// Notifications' chats Conduit knows are read or answered.
        var cleared: [[String]] = []
    }

    /// A finished reply, failure or task: unread until the chat is opened.
    static let replyTypes: Set<String> = ["response.ready", "turn.failed", "background_task.finished"]
    /// An approval or question (NeedsYouStore.notificationTypes).
    static let waitTypes: Set<String> = ["approval.needed", "input.needed"]

    /// Whether a push of `type` counts under `mode`.
    static func counts(type: String?, mode: Mode) -> Bool {
        guard let type else { return false }
        switch mode {
        case .chats: return replyTypes.contains(type) || waitTypes.contains(type)
        case .needsYou: return waitTypes.contains(type)
        case .off: return false
        }
    }

    /// The chat a notification is for, from the extension's chat note
    /// (ReadChatHint) or a push's routing; nil for one that names no chat
    /// or doesn't count under `mode`.
    static func chat(note: [String: String], mode: Mode) -> Chat? {
        let type = note["type"]
        guard counts(type: type, mode: mode) else { return nil }
        let room = note["room_id"].map { "room:\($0)" }
        let chat = Chat(
            ids: [note["session_id"], note["stored_session_id"], room].compactMap { $0 },
            waits: waitTypes.contains(type ?? "")
        )
        return chat.ids.isEmpty ? nil : chat
    }

    /// How many chats: `known` and `delivered` (less the `cleared` ones)
    /// and `arriving` (a push being shown, never cleared), each chat once.
    static func count(known: [Chat], delivered: [Chat], cleared: [[String]] = [], arriving: Chat? = nil, mode: Mode) -> Int {
        guard mode != .off else { return 0 }
        let kept = delivered.filter { chat in !cleared.contains { chat.shares($0) } }
        let counted = (known + kept + (arriving.map { [$0] } ?? []))
            .filter { mode == .chats || $0.waits }
        // Chats that share an id are one; merging can join groups.
        var groups: [Set<String>] = []
        for chat in counted where !chat.ids.isEmpty {
            var merged = Set(chat.ids)
            groups.removeAll { group in
                guard !group.isDisjoint(with: merged) else { return false }
                merged.formUnion(group)
                return true
            }
            groups.append(merged)
        }
        return groups.count
    }

    /// The ledger once a push for `chat` has shown: a new reply in a chat
    /// read before is unread again.
    static func arrived(_ chat: Chat, in ledger: Ledger) -> Ledger {
        var ledger = ledger
        ledger.cleared.removeAll { chat.shares($0) }
        return ledger
    }

    // MARK: Stored in the App Group

    private static let modeKey = "conduit.notifications.badgeMode"
    private static let ledgerKey = "conduit.notifications.badgeLedger"

    static var mode: Mode {
        get { NotificationSharedSettings.defaults?.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .chats }
        set { NotificationSharedSettings.defaults?.set(newValue.rawValue, forKey: modeKey) }
    }

    static var ledger: Ledger {
        get {
            guard let data = NotificationSharedSettings.defaults?.data(forKey: ledgerKey) else { return Ledger() }
            return (try? JSONDecoder().decode(Ledger.self, from: data)) ?? Ledger()
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            NotificationSharedSettings.defaults?.set(data, forKey: ledgerKey)
        }
    }
}

extension AppIconBadge {
    /// The chat a delivered (or arriving) notification is for: the
    /// extension's chat note, else a plaintext push's own routing.
    static func chat(userInfo: [AnyHashable: Any], mode: Mode) -> Chat? {
        guard mode != .off else { return nil }
        if let note = ReadChatHint.read(userInfo) {
            return chat(note: note.compactMapValues { $0 as? String }, mode: mode)
        }
        guard userInfo[NotificationE2E.userInfoKey] == nil, NotificationE2E.routingStub(userInfo) != nil else { return nil }
        return chat(note: ReadChatHint.note(NotificationE2E.plaintextRouting(userInfo)), mode: mode)
    }
}
