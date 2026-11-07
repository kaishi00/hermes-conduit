//
//  RichComposedCard.swift
//  Conduit
//
//  A card Hermes builds itself (issue 1946): sections of elements (text,
//  metrics, badges, icons, pictures, progress bars, dividers, fields and
//  buttons), and the buttons any card can carry at its foot. Conduit owns
//  the look: Hermes picks roles and tones, never fonts or colors. A button
//  opens a link, copies, sends a message as the user, or taps: the tap
//  reaches Hermes through the plugin's /boards/taps route, then the user's
//  message about it goes, and Hermes hears the card as the user saw it and
//  the fields as they left them. A tap is the user's OK for exactly what
//  the card showed (Eric, 2026-11-07).
//

import SwiftUI

/// A tone Hermes picks for an element; Conduit picks its color.
enum RichTone: String, Hashable {
    case neutral, accent, good, warning, bad

    init(json value: Any?) {
        self = (value as? String).flatMap(RichTone.init(rawValue:)) ?? .neutral
    }
}

struct RichButton: Equatable, Hashable {
    enum Action: String { case open, copy, send, tap }
    enum Style: String { case primary, plain, destructive }

    let label: String
    let action: Action
    /// tap: what Hermes hears was tapped.
    let id: String?
    /// open: the link; copy: the text; send: the message.
    let target: String?
    let symbol: String?
    let style: Style
    /// Asked before it goes.
    let confirm: String?

    init?(json: [String: Any]) {
        guard let label = json["label"] as? String,
              let action = (json["action"] as? String).flatMap(Action.init(rawValue:)) else { return nil }
        self.label = label
        self.action = action
        id = json["id"] as? String
        target = json["target"] as? String
        symbol = json["symbol"] as? String
        style = (json["style"] as? String).flatMap(Style.init(rawValue:)) ?? .plain
        confirm = json["confirm"] as? String
        switch action {
        case .tap: guard id != nil else { return nil }
        case .open, .copy, .send: guard target != nil else { return nil }
        }
    }

    /// An open button's link, when it's one the card may open.
    var openURL: URL? {
        guard action == .open, let target, RichCardSchema.isOpenable(target) else { return nil }
        return URL(string: target)
    }
}

struct RichField: Equatable, Hashable {
    enum Input: String { case text, choice, toggle, date, number }

    let id: String
    let input: Input
    let label: String?
    let value: String?
    let lines: Int
    let options: [String]
    let min: Double?
    let max: Double?
    let placeholder: String?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let input = (json["input"] as? String).flatMap(Input.init(rawValue:)) else { return nil }
        self.id = id
        self.input = input
        label = json["label"] as? String
        value = json["value"] as? String
        lines = (json["lines"] as? Int) ?? 1
        options = json["options"] as? [String] ?? []
        min = (json["min"] as? NSNumber)?.doubleValue
        max = (json["max"] as? NSNumber)?.doubleValue
        placeholder = json["placeholder"] as? String
    }

    /// A number field's text as the schema writes it (a comma, as a
    /// German or French keypad types it, read as the decimal point), or nil
    /// when it isn't a number within min and max, which the host would drop.
    /// Left empty, it's empty.
    func numberText(_ text: String) -> String? {
        let number = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if number.isEmpty { return "" }
        guard number.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Double(number) else { return nil }
        if let min, value < min { return nil }
        if let max, value > max { return nil }
        return number
    }

    /// The range a number field takes, written with its own numbers, for
    /// the hint under one that's out of it.
    var numberRange: String {
        func written(_ value: Double) -> String {
            value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        }
        switch (min, max) {
        case let (low?, high?): return "\(written(low)) – \(written(high))"
        case let (low?, nil): return "≥ \(written(low))"
        case let (nil, high?): return "≤ \(written(high))"
        case (nil, nil): return "0–9"
        }
    }

    /// What it starts filled in with: a toggle starts off, a date today
    /// (what its picker shows).
    var startingValue: String {
        if let value { return value }
        switch input {
        case .toggle: return "off"
        case .date: return RichFieldDates.text(.now, timed: false)
        case .text, .choice, .number: return ""
        }
    }
}

struct RichElement: Equatable, Hashable {
    enum Kind: String { case text, metric, badge, icon, image, progress, divider, field, button }
    enum Role: String { case heading, body, caption, mono }

    let kind: Kind
    let text: String?
    let role: Role
    let tone: RichTone
    let value: String?
    let label: String?
    let change: String?
    let symbol: String?
    let url: URL?
    let progress: Double?
    let field: RichField?
    let button: RichButton?

    init?(json: [String: Any]) {
        guard let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        self.kind = kind
        text = json["text"] as? String
        role = (json["role"] as? String).flatMap(Role.init(rawValue:)) ?? .body
        tone = RichTone(json: json["tone"])
        value = json["value"] as? String
        label = json["label"] as? String
        change = json["change"] as? String
        symbol = json["symbol"] as? String
        url = RichJSON.webURL(json["url"]).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        progress = (json["progress"] as? NSNumber)?.doubleValue
        field = kind == .field ? RichField(json: json) : nil
        button = kind == .button ? RichButton(json: json) : nil
        switch kind {
        case .text, .badge: guard text != nil else { return nil }
        case .metric: guard value != nil else { return nil }
        case .icon: guard symbol != nil else { return nil }
        case .image: guard url != nil else { return nil }
        case .progress: guard progress != nil else { return nil }
        case .divider: break
        case .field: guard field != nil else { return nil }
        case .button: guard button != nil else { return nil }
        }
    }
}

struct RichSection: Equatable, Hashable {
    let row: Bool
    /// Folded until the card is opened.
    let more: Bool
    let elements: [RichElement]

    init?(json: [String: Any]) {
        row = json["layout"] as? String == "row"
        more = json["more"] as? Bool ?? false
        elements = (json["items"] as? [[String: Any]] ?? []).compactMap(RichElement.init(json:))
        guard !elements.isEmpty else { return nil }
    }
}

// MARK: - Taps

/// What a card's send and tap buttons go through: the open chat's, while a
/// message can go. Nil where they can't (a group room, the call screen,
/// the saved copy, a chat on its way), where only open and copy work.
struct RichCardActionContext {
    /// The ids the chat is known by (more come as they're confirmed), so
    /// what's typed in or tapped on one chat's card never shows on the same
    /// card in another (RichCardFieldMemory, RichCardTapMemory).
    let sessionIDs: [String]
    /// A send or tap can go now: Hermes is free and connected and the
    /// composer is on, as for a board's follow-ups.
    let canSend: Bool
    /// Holds the composer's draft: a send or tap waits for an empty one, as
    /// a follow-up does, since it goes in the draft's place.
    let composer: PredictiveStore?
    /// Sends a message as the user's.
    let send: @MainActor (_ text: String) -> Void
    /// Posts the tap, then sends the user's message about it; nil when the
    /// plugin has no /boards/taps.
    let tap: (@MainActor (_ body: [String: Any], _ message: String) async throws -> Void)?

    static let capability = "card-taps"
    static let path = "/api/plugins/conduit_push/boards/taps"

    static func tapPath(profile: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "profile", value: profile)]
        return path + "?" + (components.percentEncodedQuery ?? "")
    }

    /// The message the user sends with a tap: what they tapped and on what.
    /// The title goes only while the message stays a plain one (a title
    /// naming a file would make it a reference).
    static func message(label: String, title: String?) -> String {
        guard let title, !title.isEmpty, RichCardSchema.isPlainMessage("\(label) · \(title)") else { return label }
        return "\(label) · \(title)"
    }

    /// Whether the message about a tap the host took may go now: only to
    /// the chat and profile it was tapped in, while the composer is on and
    /// holds no draft (the message goes in the draft's place, so words typed
    /// while the tap was on its way keep the button tappable instead).
    static func mayFollowUp(tappedIn sessionIDs: [String], profile: String, openSessionIDs: [String],
                            openProfile: String, composerIsEnabled: Bool, draft: String) -> Bool {
        composerIsEnabled && !Set(openSessionIDs).isDisjoint(with: sessionIDs) && openProfile == profile
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether two sets of a chat's ids are the same chat: they share an id
    /// (a chat gains ids as they're confirmed), or neither is a chat.
    static func sameChat(_ one: Set<String>, _ other: Set<String>) -> Bool {
        one.isEmpty && other.isEmpty || !one.isDisjoint(with: other)
    }
}

private struct RichCardActionContextKey: EnvironmentKey {
    static let defaultValue: RichCardActionContext? = nil
}

extension EnvironmentValues {
    /// The open chat's way to send from a card; nil where only open and
    /// copy buttons work.
    var richCardActions: RichCardActionContext? {
        get { self[RichCardActionContextKey.self] }
        set { self[RichCardActionContextKey.self] = newValue }
    }
}

/// What the user typed in a card's fields and whether it was opened, kept
/// for the session while the card is drawn again (a board's tab switched
/// back to), by the card's normalized JSON and the chat: a changed card
/// starts over, and the same card in another chat starts on its own. A
/// chat is matched by any of its ids, as it gains them while it's open.
@MainActor
final class RichCardFieldMemory {
    static let shared = RichCardFieldMemory()
    static let maxCards = 50

    private struct Entry {
        let card: String
        var chat: Set<String>
        var values: [String: String]
        var open: Bool
    }

    /// Least recently kept first, so the card being typed in stays.
    private var entries: [Entry] = []

    func kept(card: RichCard, chat: [String]) -> (values: [String: String], open: Bool)? {
        entries.last(where: { matches($0, card: card, chat: Set(chat)) }).map { ($0.values, $0.open) }
    }

    func keep(card: RichCard, chat: [String], values: [String: String], open: Bool) {
        let ids = Set(chat)
        var entry = Entry(card: card.normalizedJSON, chat: ids, values: values, open: open)
        if let index = entries.lastIndex(where: { matches($0, card: card, chat: ids) }) {
            entry.chat.formUnion(entries.remove(at: index).chat)
        }
        entries.append(entry)
        if entries.count > Self.maxCards { entries.removeFirst(entries.count - Self.maxCards) }
    }

    private func matches(_ entry: Entry, card: RichCard, chat: Set<String>) -> Bool {
        entry.card == card.normalizedJSON && RichCardActionContext.sameChat(entry.chat, chat)
    }
}

/// The taps on their way or sent, so a button shows it went until Hermes
/// shows the card again (a new card is new buttons) or two minutes pass.
@MainActor
final class RichCardTapMemory: ObservableObject {
    static let shared = RichCardTapMemory()
    static let holdSeconds: TimeInterval = 120

    enum State: Equatable { case sending, sent }

    @Published private(set) var taps: [String: (state: State, at: Date, chat: Set<String>)] = [:]

    static func key(card: RichCard, button: String) -> String {
        "\(card.normalizedJSON)\u{1F}\(button)"
    }

    /// The tap's state in this chat: the same card in another chat wasn't tapped.
    func state(_ key: String, chat: [String], now: Date = .now) -> State? {
        guard let tap = taps[key], now.timeIntervalSince(tap.at) < Self.holdSeconds,
              RichCardActionContext.sameChat(tap.chat, Set(chat)) else { return nil }
        return tap.state
    }

    func set(_ key: String, _ state: State?, chat: [String]) {
        taps = taps.filter { Date.now.timeIntervalSince($0.value.at) < Self.holdSeconds }
        if let state {
            taps[key] = (state: state, at: .now, chat: Set(chat))
            // Nothing else may redraw the button when the hold passes.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.holdSeconds + 0.5))
                self?.objectWillChange.send()
            }
        } else {
            taps[key] = nil
        }
    }
}
