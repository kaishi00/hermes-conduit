//
//  PresentedScreens.swift
//  Conduit
//
//  Screens Hermes asks this iPhone to present (V2 phase 4). The first one
//  is a confirmation: Hermes is about to do something the user should OK
//  (send a message, buy, delete) and asks with a title, a preview of what
//  will happen and a label for the action. The user answers by tap, or out
//  loud during a live call; Hermes reads the answer with its
//  `conduit_present` tool. Nothing is confirmed without a tap or the user's
//  own spoken yes. (designs/v2-phase4-presented-screens.md)
//

import Foundation
import UIKit

/// Where a Go confirmation opens Apple Maps (`conduit_maps` navigate): the
/// place as Hermes named it and how to travel.
struct PresentedMapsTarget: Equatable {
    let to: String
    let mode: MapsRequest.Mode

    init(to: String, mode: MapsRequest.Mode = .driving) {
        self.to = to
        self.mode = mode
    }

    init?(json: Any?) {
        guard let entry = json as? [String: Any],
              let to = (entry["to"] as? String).flatMap({ MapsText.cleanOrNil($0, limit: MapsPlaceRef.maxTextLength) })
        else { return nil }
        var mode = MapsRequest.Mode.driving
        if let name = entry["mode"] as? String {
            guard let chosen = MapsRequest.Mode(rawValue: name.lowercased()) else { return nil }
            mode = chosen
        }
        self.init(to: to, mode: mode)
    }
}

/// The room a room's ask comes from (Linked Rooms, Ask me first): your agent
/// in a room with other people's agents asks before it shares something
/// personal about you.
struct PresentedRoom: Equatable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Any room the host names makes it a room's ask, even one without an id:
    /// never an ordinary confirmation whose Edit opens the room's hidden chat.
    init?(json: Any?) {
        guard let entry = json as? [String: Any] else { return nil }
        let id = (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(id: id, name: String(name.prefix(80)))
    }
}

/// Something Hermes put on the screen of the user's voice call with
/// `conduit_show`: a table, steps, a chart. Shown once, never answered.
struct PresentedCard: Identifiable, Equatable {
    /// The Hermes tool that shows one.
    static let toolName = "conduit_show"

    let id: String
    let title: String
    /// What to show, as Markdown.
    let markdown: String
    /// Maps and places drawn above the Markdown, as the card schema
    /// normalized them.
    let cards: [[String: Any]]

    init(id: String, title: String, markdown: String, cards: [[String: Any]] = []) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.cards = cards
    }

    init?(json: Any?) {
        guard let entry = json as? [String: Any],
              let id = entry["id"] as? String, !id.isEmpty,
              let markdown = (entry["markdown"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !markdown.isEmpty else { return nil }
        let cards = RichCardSchema.bundled?.normalizeCards(entry["cards"]) ?? []
        // Markdown that's only the cards' own text (plugin 0.45.1+) would
        // show the places twice beside the drawn cards.
        let isFallback = !cards.isEmpty && entry["fallback"] as? Bool == true
        self.init(id: id, title: (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                  markdown: isFallback ? "" : markdown, cards: cards)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.markdown == rhs.markdown
            && RichCard.cards(lhs.cards) == RichCard.cards(rhs.cards)
    }
}

/// One confirmation Hermes is waiting on.
struct PresentedConfirm: Identifiable, Equatable {
    let id: String
    let title: String
    /// What will happen, as Markdown.
    let preview: String
    /// The primary action's label ("Send").
    let actionLabel: String
    /// Short phrases that confirm it out loud ("send it").
    let spokenYes: [String]
    /// The chat it came from, if any.
    let sessionID: String?
    let expiresAt: Date?
    /// A Go confirmation: confirming opens Apple Maps here.
    let maps: PresentedMapsTarget?
    /// A room's ask: the preview is what your agent would share there, and
    /// Say instead answers with what to say, never by opening the room's
    /// hidden chat.
    let room: PresentedRoom?

    init(id: String, title: String, preview: String, actionLabel: String,
         spokenYes: [String] = [], sessionID: String? = nil, expiresAt: Date? = nil, maps: PresentedMapsTarget? = nil,
         room: PresentedRoom? = nil) {
        self.id = id
        self.title = title
        self.preview = preview
        self.actionLabel = actionLabel
        self.spokenYes = spokenYes
        self.sessionID = sessionID
        self.expiresAt = expiresAt
        self.maps = maps
        self.room = room
    }

    init?(json: Any) {
        guard let entry = json as? [String: Any],
              let id = entry["id"] as? String, !id.isEmpty,
              let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        let label = (entry["action_label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let session = (entry["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expires = (entry["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        self.init(
            id: id,
            title: String(title.prefix(120)),
            preview: String((entry["preview"] as? String ?? "").prefix(4_000)),
            actionLabel: label.isEmpty ? AppLocalization.string("Confirm") : String(label.prefix(32)),
            spokenYes: (entry["spoken_yes"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(5)
                .map { String($0.prefix(40)) },
            sessionID: session,
            expiresAt: expires,
            maps: PresentedMapsTarget(json: entry["maps"]),
            room: PresentedRoom(json: entry["room"])
        )
    }

    func isExpired(at now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// Whether the user's own words confirm it: a plain yes, or one of the
    /// phrases Hermes gave said on its own ("send it", "yes, send it").
    /// Never a question, never a phrase buried in a longer request.
    func isConfirmed(by words: String) -> Bool {
        if VoiceCallDecisionOutcome.isYes(words) { return true }
        guard !words.contains("?"), !words.contains("？") else { return false }
        // What a refusal is, the handset decides, not Hermes: whatever
        // phrases it put in spoken_yes, the user's "no", "cancel" or
        // "wait" in any shipped language, anywhere in their words ("send
        // it, no wait", "absolutely not", "我不想发"), never confirms.
        // "No problem" still does: the handset's own check above
        // classifies it as a yes.
        if VoiceThreadRouting.containsRefusal(words) { return false }
        let said = Self.words(in: words)
        guard !said.isEmpty else { return false }
        let leads: Set<String> = ["yes", "yeah", "yep", "ok", "okay", "sure", "please"]
        return spokenYes.contains { phrase in
            let wanted = Self.words(in: phrase)
            guard !wanted.isEmpty else { return false }
            if said == wanted { return true }
            // "Yes, send it" / "send it please": the phrase with a yes word
            // around it, nothing else.
            guard said.count <= wanted.count + 2, let start = Self.range(of: wanted, in: said) else { return false }
            let extra = Array(said[..<start]) + Array(said[(start + wanted.count)...])
            // A lead word in any language the call's own yes check knows.
            return extra.allSatisfy { leads.contains($0) || VoiceCallDecisionOutcome.isYes($0) }
        }
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func range(of needle: [String], in haystack: [String]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }
}

/// How the user answered a confirmation.
enum PresentedConfirmOutcome: String {
    case confirmed
    case declined
    /// The user wants to change it first; they say or type what.
    case edit
}

enum PresentedConfirmAnswerSource: String {
    case tap
    case voice
    /// Conduit opened Apple Maps for a Go confirmation itself: the user was
    /// in that chat with Conduit open.
    case auto
}

/// Keeps the confirmations Hermes is waiting on in step with the host's
/// `present/exchange` route: answers go up, what still waits comes down.
@MainActor
final class PresentedScreensSync: ObservableObject {
    static let path = "/api/plugins/conduit_push/present/exchange"
    static let capability = "present-v1"
    /// What this Conduit does with a confirmation beyond showing it, told to
    /// the host in each exchange. "show-cards": it shows the cards
    /// `conduit_show` puts on a voice call's screen. "chat-cards": it draws
    /// conduit_show's map and place cards in a chat, so the host offers the
    /// tool there too. "info-cards": it also draws stats, charts, forecasts,
    /// comparisons and steps (plugin 0.46+). "media-cards": photos, videos,
    /// audio and contacts; "live-cards": statuses and cards kept up to date
    /// under a live name (plugin 0.47+); "text-drafts": Send text for a
    /// contact card's message (plugin 0.67+). "room-asks": a room's asks,
    /// answered with Share, Say instead (with the words) or Don't share
    /// (plugin 0.118+, Linked Rooms).
    static let features = ["maps-navigate", "show-cards", "chat-cards", "info-cards", "media-cards", "live-cards",
                           "text-drafts", "room-asks"]
    /// The longest Say instead the host keeps.
    static let maxEditText = 2_000
    /// Card ids remembered as seen, so a card is shown at most once.
    private static let maxSeenCards = 200
    private static let resultsKey = "conduit.presentedScreens.results.v1"
    private static let maxResults = 40

    typealias Request = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]

    /// Waiting confirmations for the dashboard and profile in use, oldest
    /// first. The one on screen is the first.
    @Published private(set) var prompts: [PresentedConfirm] = []

    private let defaults: UserDefaults
    private var syncing = false
    private var syncAgain = false
    private var scope: String?
    /// The newest caller's request, so a coalesced round uses the current
    /// host and profile rather than the first caller's.
    private var latest: (profile: String, installationID: String, isCurrent: @MainActor () -> Bool, request: Request)?
    /// The user's last turn in the call when each confirmation appeared:
    /// words from before it was on screen can't confirm it.
    private(set) var userTurnWhenShown: [String: UUID] = [:]
    /// New cards from Hermes, as each exchange brings them.
    var onCards: (@MainActor (_ cards: [PresentedCard]) -> Void)?
    /// Cards already handed on, oldest first. Nil until the first exchange
    /// with this host and profile, which only notes what's there: those
    /// cards were for a conversation before this app's.
    private var seenCardIDs: [String]?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The confirmation to show now.
    var current: PresentedConfirm? {
        prompts.first { !$0.isExpired() }
    }

    func sync(scope: String, profile: String, installationID: String,
              isCurrent: @escaping @MainActor () -> Bool = { true }, request: @escaping Request) async {
        if self.scope != scope {
            // Another host or profile: its confirmations aren't this one's.
            self.scope = scope
            prompts = []
            userTurnWhenShown = [:]
            seenCardIDs = nil
        }
        latest = (profile, installationID, isCurrent, request)
        if syncing {
            syncAgain = true
            return
        }
        syncing = true
        // The request holds the dashboard bridge: not kept past the sync.
        defer { syncing = false; latest = nil }
        // Every round answers a call that came meanwhile (an answer to send,
        // a tool that finished), and that call has already returned: none is
        // dropped. Rounds never ask for more themselves, so this ends.
        repeat {
            syncAgain = false
            guard let current = self.scope, let next = latest else { return }
            await syncOnce(scope: current, profile: next.profile, installationID: next.installationID,
                           isCurrent: next.isCurrent, request: next.request)
        } while syncAgain
    }

    /// Notes the user's last call turn as a confirmation goes on screen.
    func noteShown(_ promptID: String, userTurn: UUID?) {
        guard userTurnWhenShown[promptID] == nil, let userTurn else { return }
        userTurnWhenShown[promptID] = userTurn
    }

    private func syncOnce(scope: String, profile: String, installationID: String,
                          isCurrent: @MainActor () -> Bool, request: Request) async {
        let answers = results(for: scope)
        let body: [String: Any] = [
            "installation_id": installationID,
            "device": UIDevice.current.name,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "results": answers,
            "features": Self.features,
        ]
        let response: [String: Any]
        do {
            response = try await request(DashboardPath.withProfile(Self.path, profile: profile), body)
        } catch {
            return
        }
        guard response["ok"] as? Bool == true, isCurrent(), self.scope == scope else { return }
        let sentIDs = Set(answers.compactMap { $0["id"] as? String })
        setResults(results(for: scope).filter { !sentIDs.contains($0["id"] as? String ?? "") }, for: scope)
        // Answered here, still listed there until the answer lands: not again.
        let answered = Set(results(for: scope).compactMap { $0["id"] as? String }).union(sentIDs)
        prompts = (response["prompts"] as? [Any] ?? [])
            .compactMap(PresentedConfirm.init(json:))
            .filter { !answered.contains($0.id) && !$0.isExpired() }
        let listed = Set(prompts.map(\.id))
        userTurnWhenShown = userTurnWhenShown.filter { listed.contains($0.key) }
        takeCards(response["cards"])
    }

    private func takeCards(_ json: Any?) {
        let cards = (json as? [Any] ?? []).compactMap(PresentedCard.init(json:))
        guard let seen = seenCardIDs else {
            seenCardIDs = cards.map(\.id)
            return
        }
        let fresh = cards.filter { !seen.contains($0.id) }
        guard !fresh.isEmpty else { return }
        seenCardIDs = Array((seen + fresh.map(\.id)).suffix(Self.maxSeenCards))
        onCards?(fresh)
    }

    /// Records the user's answer and takes the confirmation off screen; the
    /// next sync reports it.
    /// `editText` is a room's ask's Say instead: what the agent says there.
    func answer(_ prompt: PresentedConfirm, outcome: PresentedConfirmOutcome, via source: PresentedConfirmAnswerSource,
                editText: String? = nil) {
        // The first answer wins: a second tap lands on a panel already gone.
        guard let scope, prompts.contains(where: { $0.id == prompt.id }) else { return }
        prompts.removeAll { $0.id == prompt.id }
        var list = results(for: scope).filter { ($0["id"] as? String) != prompt.id }
        var result: [String: Any] = ["id": prompt.id, "outcome": outcome.rawValue, "via": source.rawValue]
        if outcome == .edit, let text = editText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            result["edit_text"] = String(text.prefix(Self.maxEditText))
        }
        list.append(result)
        setResults(Array(list.suffix(Self.maxResults)), for: scope)
    }

    /// Takes confirmations whose time ran out off screen (the host counts
    /// them as expired, never a yes).
    func dropExpired(at now: Date = Date()) {
        guard prompts.contains(where: { $0.isExpired(at: now) }) else { return }
        prompts.removeAll { $0.isExpired(at: now) }
        let listed = Set(prompts.map(\.id))
        userTurnWhenShown = userTurnWhenShown.filter { listed.contains($0.key) }
    }

    /// Leaving a host or profile: nothing of its stays on screen.
    func leave() {
        scope = nil
        latest = nil
        prompts = []
        userTurnWhenShown = [:]
        seenCardIDs = nil
    }

    private func results(for scope: String) -> [[String: Any]] {
        let all = defaults.dictionary(forKey: Self.resultsKey) as? [String: [[String: Any]]] ?? [:]
        return all[scope] ?? []
    }

    private func setResults(_ list: [[String: Any]], for scope: String) {
        var all = defaults.dictionary(forKey: Self.resultsKey) as? [String: [[String: Any]]] ?? [:]
        all[scope] = list.isEmpty ? nil : list
        defaults.set(all, forKey: Self.resultsKey)
    }
}

/// The live call's tool for confirmations: the model reads what waits and
/// answers it, but a confirm only goes through on the user's own words.
/// Descriptions and answers are for the model, not UI copy.
@MainActor
enum PresentVoiceTool {
    static let name = "present_confirm"
    nonisolated static let key = "present"

    static let tool = VoiceHostTool(
        name: name,
        description: "Confirmations Hermes is waiting on, shown on the user's screen as a panel. list: what's waiting. "
            + "confirm: only right after the user said yes or the confirming phrase out loud in this call; Conduit "
            + "checks their words and refuses otherwise. decline: when the user says no or not now. Before asking, "
            + "tell the user in a sentence what it will do (from its title and preview).",
        parameters: [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["list", "confirm", "decline"]],
                "id": ["type": "string", "description": "confirm, decline: the confirmation's id from list."],
            ],
            "required": ["action"],
        ],
        key: key
    )

    private static let alreadyAnswered = ["error": "Already answered on the screen; nothing to do."]

    static func describe(_ prompt: PresentedConfirm) -> [String: Any] {
        var entry: [String: Any] = ["id": prompt.id, "title": prompt.title, "preview": String(prompt.preview.prefix(600)),
                                    "action": prompt.actionLabel]
        if !prompt.spokenYes.isEmpty { entry["confirming_phrases"] = prompt.spokenYes }
        // Your agent asks before it shares this in a room with other people's agents.
        if let room = prompt.room { entry["room"] = room.name }
        return entry
    }

    /// The quiet note a live model gets when one arrives mid-call.
    static func note(for prompt: PresentedConfirm) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: describe(prompt), options: [.sortedKeys])) ?? Data()
        let details = String(data: data, encoding: .utf8) ?? ""
        return "[Hermes put a confirmation on the user's screen: \(details). At the next natural pause, tell the user in a sentence what it will do and ask whether to go ahead; then call \(name) with confirm or decline and its id. Don't interrupt the user for it.]"
    }

    /// One call. `lastUserTurn` is the user's most recent turn in the call,
    /// which a confirm needs to be a yes said after the confirmation appeared.
    static func run(
        _ arguments: [String: Any], sync: PresentedScreensSync,
        lastUserTurn: @escaping @MainActor () -> (id: UUID?, text: String),
        answer: @MainActor (PresentedConfirm, PresentedConfirmOutcome) async -> Void
    ) async -> [String: String] {
        let action = arguments["action"] as? String ?? "list"
        if action == "list" {
            let waiting = sync.prompts.filter { !$0.isExpired() }.map(describe)
            let data = (try? JSONSerialization.data(withJSONObject: waiting, options: [.sortedKeys])) ?? Data()
            return ["confirmations": String(data: data, encoding: .utf8) ?? "[]"]
        }
        guard let id = arguments["id"] as? String,
              let prompt = sync.prompts.first(where: { $0.id == id && !$0.isExpired() }) else {
            return ["error": "No confirmation with that id is waiting. List them again."]
        }
        switch action {
        case "confirm":
            // Their words reach Conduit a moment after the model heard them.
            let shownAfter = sync.userTurnWhenShown[prompt.id]
            let deadline = ContinuousClock.now + .seconds(2)
            func stillWaiting() -> Bool { sync.prompts.contains { $0.id == prompt.id && !$0.isExpired() } }
            func saidYes() -> Bool {
                let turn = lastUserTurn()
                // A turn from before the panel appeared answers something else.
                if let shownAfter, turn.id == shownAfter { return false }
                return prompt.isConfirmed(by: turn.text)
            }
            while !saidYes() {
                guard stillWaiting() else { return alreadyAnswered }
                guard ContinuousClock.now < deadline else {
                    return ["error": "Not confirmed: the user's own words weren't a yes. Ask them, and confirm only after they say yes."]
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return ["error": "Not confirmed."] }
            }
            // Tapped while their words arrived: the tap stands.
            guard stillWaiting() else { return alreadyAnswered }
            await answer(prompt, .confirmed)
            return ["result": "Confirmed. Hermes goes ahead."]
        case "decline":
            guard sync.prompts.contains(where: { $0.id == prompt.id && !$0.isExpired() }) else { return alreadyAnswered }
            await answer(prompt, .declined)
            return ["result": "Declined. Hermes won't do it."]
        default:
            return ["error": "Unknown action."]
        }
    }
}
