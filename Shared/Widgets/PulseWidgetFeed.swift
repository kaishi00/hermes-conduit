import Foundation
import Security

/// What the Pulse widget reads Pulse with (issue 2190): the dashboard in
/// use, a host pass for it (as the Location Push extension's, see
/// LocationHostClient.swift) and the Pulse features its plugin serves.
/// Conduit keeps it in the notifications App Group's Keychain while a Pulse
/// widget is on the Home Screen, and removes it otherwise, so the widget
/// reloads with fresh cards (every Pulse push asks it to, and WidgetKit
/// every so often) without Conduit running.
struct PulseWidgetAccess: Codable, Equatable {
    let dashboardID: UUID
    let pass: LocationHostPass
    /// The plugin's capabilities that decide a card's buttons.
    let capabilities: [String]

    func serves(_ capability: String) -> Bool { capabilities.contains(capability) }

    static let looksCapability = "pulse_looks"
    static let doneCapability = "pulse_done"
    static let foundActionsCapability = "pulse_found_actions"
    static let dismissCapability = "pulse_dismiss"
    static let restCapability = "pulse_rest"
    /// The ones the widget reads; the rest aren't kept.
    static let widgetCapabilities: Set<String> = [
        looksCapability, doneCapability, foundActionsCapability, dismissCapability, restCapability,
    ]
}

/// The access item, beside the location host pass in the notifications App
/// Group's Keychain: readable after first unlock, never synced.
enum PulseWidgetKeychain {
    /// NotificationE2E.appGroup, which the widget doesn't compile.
    static let accessGroup = "group.com.milim.relay.notifications"
    static let service = "com.milim.relay.pulse-widget"
    static let account = "access.v1"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    static func load() -> PulseWidgetAccess? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(PulseWidgetAccess.self, from: data)
    }

    /// Whether the Keychain took it.
    @discardableResult
    static func save(_ access: PulseWidgetAccess) -> Bool {
        guard let data = try? JSONEncoder().encode(access) else { return false }
        if load() == access { return true }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// The widget's rows from Pulse's feed as the plugin answers it: the same
/// cards the Pulse screen lists open, with the buttons it offers them
/// (ConduitTests check this against PulseCard and AppState, which the
/// screen uses).
enum PulseWidgetFeed {
    static let base = "/api/plugins/conduit_push/pulse"

    static func feedPath(looks: Bool) -> String { base + "/feed" + (looks ? "?looks=1" : "") }

    /// The snapshot for a feed answer. `heading` words a card's topic or
    /// kind in the app's language.
    static func snapshot(from feed: [String: Any], access: PulseWidgetAccess, appLanguage: String,
                         heading: (_ kind: String, _ topic: String) -> String) -> PulseWidgetSnapshot? {
        guard let raw = feed["cards"] as? [Any] else { return nil }
        let cards = raw.compactMap { $0 as? [String: Any] }.filter(isListed)
            .sorted { (number($0["created_at"]) ?? 0) > (number($1["created_at"]) ?? 0) }
        let quiet = (feed["quiet_now"] as? String).map { !$0.isEmpty } ?? false
        let rows = cards.prefix(PulseWidgetSnapshot.maximumCards).compactMap { card -> PulseWidgetCard? in
            guard let id = int(card["id"]) else { return nil }
            let kind = card["kind"] as? String ?? ""
            let markdown = kind != "followup"
            let look = card["look"] as? [String: Any]
            let line = look?["line"] as? String ?? ""
            let news = card["news"] as? String ?? ""
            let words = news.isEmpty ? card["title"] as? String ?? "" : news
            return PulseWidgetCard(
                id: id,
                heading: heading(kind, card["topic"] as? String ?? ""),
                headline: plain(line.isEmpty ? words : line, markdown: markdown),
                sentence: line.isEmpty ? "" : plain(look?["detail"] as? String ?? "", markdown: markdown),
                offersDone: offersDone(card, access: access),
                offersDoIt: offersDoIt(card, access: access),
                offersLater: access.serves(PulseWidgetAccess.dismissCapability)
            )
        }
        return PulseWidgetSnapshot(
            dashboardID: access.dashboardID, appLanguage: appLanguage, cards: rows, openCount: cards.count,
            nextLookAt: nil,
            quietUntil: quiet ? number(feed["quiet_ends_at"]).map(Date.init(timeIntervalSince1970:)) ?? .distantFuture : nil
        )
    }

    /// Open follow-ups and report items, as the screen lists them: not done,
    /// put off or a suggestion, and not held for the morning brief; whole
    /// reports and briefs are Hermes' own replies.
    static func isListed(_ card: [String: Any]) -> Bool {
        let kind = card["kind"] as? String ?? ""
        guard kind == "followup" || kind == "noticed" else { return false }
        guard number(card["done_at"]) == nil, number(card["dismissed_at"]) == nil else { return false }
        let held = card["level"] as? String == "brief" && number(card["briefed_at"]) == nil
        return !held
    }

    /// PulseCard.canBeDone, and AppState.canMarkPulseCardDone's plugin checks.
    static func offersDone(_ card: [String: Any], access: PulseWidgetAccess) -> Bool {
        guard access.serves(PulseWidgetAccess.doneCapability) else { return false }
        return int(card["item_id"]) != nil || isFound(card) && access.serves(PulseWidgetAccess.foundActionsCapability)
    }

    /// AppState.canActOnPulseCard, without a pick's Ask (whose words are
    /// for the user to change first, which a widget can't).
    static func offersDoIt(_ card: [String: Any], access: PulseWidgetAccess) -> Bool {
        guard !asks(card) else { return false }
        let kind = card["kind"] as? String ?? ""
        let hasReminder = !((card["news"] as? String ?? "").isEmpty && (card["title"] as? String ?? "").isEmpty)
        let actionable = (kind == "followup" || kind == "noticed" && int(card["item_id"]) != nil)
            && (!(card["chat_id"] as? String ?? "").isEmpty || card["topic"] as? String == "deadline"
                || card["kanban_task"] is String)
            && hasReminder
        return actionable || isFound(card) && hasReminder && access.serves(PulseWidgetAccess.foundActionsCapability)
    }

    /// A report item Pulse found on its own: nothing remembered behind it.
    static func isFound(_ card: [String: Any]) -> Bool {
        card["kind"] as? String == "noticed" && int(card["item_id"]) == nil
    }

    /// Its pick offers Ask, as PulseLook.Action reads one.
    static func asks(_ card: [String: Any]) -> Bool {
        let actions = (card["look"] as? [String: Any])?["actions"] as? [Any] ?? []
        return actions.contains { raw in
            guard let action = raw as? [String: Any], action["does"] as? String == "ask" else { return false }
            let label = (action["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let say = (action["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !label.isEmpty && !say.isEmpty
        }
    }

    /// Plain words for the widget: markdown and extra lines dropped.
    static func plain(_ text: String, markdown: Bool) -> String {
        var words = text
        if markdown {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            if let parsed = try? AttributedString(markdown: text, options: options) { words = String(parsed.characters) }
        }
        return words.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The English key of a card's heading, as PulseCardKind words it: a
    /// report item's topic, else its kind.
    static func headingKey(kind: String, topic: String) -> String {
        guard kind == "noticed" else { return kind == "followup" ? "Follow-ups" : "Noticed" }
        switch topic {
        case "commitment": return "Commitment"
        case "promise": return "Promise"
        case "date": return "Date"
        case "follow-up": return "Follow-up"
        case "reminder": return "Reminder"
        case "watch": return "Watching"
        case "intention": return "Plan"
        case "interest": return "Interest"
        case "fact": return "Worth knowing"
        case "deadline": return "Deadline"
        case "next": return "Next step"
        default: return "Noticed"
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func int(_ value: Any?) -> Int? {
        number(value).flatMap { Int(exactly: $0.rounded(.towardZero)) }
    }
}
