//
//  PulseFeed.swift
//  Conduit
//
//  The Pulse screen's data (TestFlight and Xcode builds): the cards Pulse
//  brought the user, their ratings, and what the ratings taught it. The
//  plugin keeps all of it (pulse_learning.py) and serves it on
//  /api/plugins/conduit_push/pulse/feed, /rate and /learned. A rating
//  changes what Pulse does on the host: each kind sits on a loudness ladder
//  (push, Pulse screen, morning brief, off) that thumbs move, and a thumbs
//  down's reason adds a lesson the user can undo.
//

import Foundation

/// One thing Pulse brought the user: a follow-up on what Hermes promised,
/// a report on what it saw in the chats, or the morning brief.
struct PulseCard: Equatable, Identifiable {
    let id: Int
    /// "followup", "report" or "brief".
    let kind: String
    /// The loudness it went out at: "push", "screen" or "brief".
    let level: String
    /// What Hermes promised, in Pulse's words.
    let title: String
    /// Hermes' own words in the chat.
    let quote: String
    let news: String
    /// Why Pulse spoke up.
    let why: String
    let profile: String
    let chatID: String
    let chatTitle: String
    /// Hermes' `messages.id` of the promise in its chat.
    let messageID: Int?
    let createdAt: Date?
    let seenAt: Date?
    let briefedAt: Date?
    /// The promise or to-do a follow-up is about (memory's item).
    let itemID: Int?
    /// When the user marked it done on the Pulse screen.
    var doneAt: Date?
    /// "up", "down" or "".
    var rating: String
    var reason: String
    /// Hermes' reply as it wrote it (a report, a brief): bold, links and
    /// lines kept. Parsed once, not on every redraw.
    let formattedNews: AttributedString

    init?(json: Any) {
        guard let object = json as? [String: Any], let id = PulseJSON.int(object["id"]) else { return nil }
        self.id = id
        kind = object["kind"] as? String ?? ""
        level = object["level"] as? String ?? ""
        title = object["title"] as? String ?? ""
        quote = object["quote"] as? String ?? ""
        news = object["news"] as? String ?? ""
        why = object["why"] as? String ?? ""
        profile = object["profile"] as? String ?? ""
        chatID = object["chat_id"] as? String ?? ""
        chatTitle = object["chat_title"] as? String ?? ""
        messageID = PulseJSON.int(object["message_id"])
        createdAt = PulseJSON.date(object["created_at"])
        seenAt = PulseJSON.date(object["seen_at"])
        briefedAt = PulseJSON.date(object["briefed_at"])
        itemID = PulseJSON.int(object["item_id"])
        doneAt = PulseJSON.date(object["done_at"])
        rating = object["rating"] as? String ?? ""
        reason = object["reason"] as? String ?? ""
        formattedNews = Self.formatted(news, markdown: kind != "followup")
    }

    /// Held for the morning brief and not in one yet.
    var isHeld: Bool { level == PulseLevel.brief.rawValue && briefedAt == nil }

    /// Follow-ups take ratings; a report or a brief is Hermes' own reply.
    var isRatable: Bool { kind == "followup" }

    /// A follow-up can be marked done: its promise closes, without a rating.
    var canBeDone: Bool { kind == "followup" && itemID != nil }

    /// A follow-up can be acted on in the chat it came from.
    var isActionable: Bool { kind == "followup" && !chatID.isEmpty && !(news.isEmpty && title.isEmpty) }

    /// What Do it leaves in that chat's composer: the reminder, and the ask
    /// to take care of it, for the user to send or change.
    var actionMessage: String {
        let reminder = news.isEmpty ? title : news
        return AppLocalization.string("Pulse reminded me: \(reminder)\n\nLet's take care of it now.")
    }

    private static func formatted(_ news: String, markdown: Bool) -> AttributedString {
        guard markdown else { return AttributedString(news) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: news, options: options)) ?? AttributedString(news)
    }
}

/// A kind's loudness on the ladder, loudest first.
enum PulseLevel: String, CaseIterable, Identifiable {
    case push, screen, brief, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .push: return AppLocalization.string("Right away, with a notification")
        case .screen: return AppLocalization.string("In Pulse, no notification")
        case .brief: return AppLocalization.string("In the morning brief")
        case .off: return AppLocalization.string("Off")
        }
    }
}

/// Why a thumbs down: each one changes something different on the host.
enum PulseDownReason: String, CaseIterable, Identifiable {
    case notRelevant = "not_relevant"
    case alreadyKnew = "already_knew"
    case tooLate = "too_late"
    case tooOften = "too_often"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notRelevant: return AppLocalization.string("Not relevant")
        case .alreadyKnew: return AppLocalization.string("I already knew")
        case .tooLate: return AppLocalization.string("Too late")
        case .tooOften: return AppLocalization.string("Too often")
        }
    }
}

/// The kinds Pulse brings, as headings.
enum PulseCardKind {
    static func title(_ kind: String) -> String {
        switch kind {
        case "followup": return AppLocalization.string("Follow-ups")
        case "report": return AppLocalization.string("Reports")
        case "brief": return AppLocalization.string("Morning brief")
        default: return kind
        }
    }
}

/// Something a rating taught Pulse, which the user can undo.
struct PulseLesson: Equatable, Identifiable {
    let id: Int
    let kind: String
    /// "level", "rule", "sooner" or "seen".
    let what: String
    /// The level, or a rule's topic.
    let value: String
    /// Why it was learned ("2 thumbs down", "too often", "set").
    let cause: String
    let createdAt: Date?

    init?(json: Any) {
        guard let object = json as? [String: Any], let id = PulseJSON.int(object["id"]),
              let what = object["what"] as? String else { return nil }
        self.id = id
        self.what = what
        kind = object["kind"] as? String ?? ""
        value = object["value"] as? String ?? ""
        cause = object["cause"] as? String ?? ""
        createdAt = PulseJSON.date(object["created_at"])
    }

    /// The lesson in a line, in the app's language.
    var text: String {
        switch what {
        case "level":
            let level = PulseLevel(rawValue: value)?.title ?? value
            return AppLocalization.string("\(PulseCardKind.title(kind)): \(level)")
        case "rule":
            return AppLocalization.string("No updates about “\(value)”")
        case "sooner":
            return AppLocalization.string("Check on promises sooner")
        case "seen":
            return AppLocalization.string("Skip news you already saw in the chat")
        default:
            return what
        }
    }

    /// Why it was learned, in the app's language; nil when set by hand.
    var causeText: String? {
        switch cause {
        case "", "set": return nil
        case "too often": return AppLocalization.string("You said too often")
        case "too late": return AppLocalization.string("You said too late")
        case "already knew": return AppLocalization.string("You said you already knew")
        case "not relevant": return AppLocalization.string("You said not relevant")
        default:
            return cause.hasSuffix("thumbs up") ? AppLocalization.string("After thumbs up")
                : cause.hasSuffix("thumbs down") ? AppLocalization.string("After thumbs down") : cause
        }
    }
}

/// GET /pulse/feed.
struct PulseFeedPage: Equatable {
    var cards: [PulseCard] = []
    var unseen = 0
    var levels: [String: PulseLevel] = [:]
    /// Pulse's own chat, behind the screen (0.56.0); nil from an older
    /// plugin, or before the chat is made.
    var homeChatID: String?

    init() {}

    init?(json: [String: Any]) {
        guard let cards = json["cards"] as? [Any] else { return nil }
        self.cards = cards.compactMap(PulseCard.init(json:))
        unseen = PulseJSON.int(json["unseen"]) ?? 0
        levels = PulseFeedPage.levels(json["levels"])
        let home = (json["home_chat_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        homeChatID = home?.isEmpty == false ? home : nil
    }

    static func levels(_ value: Any?) -> [String: PulseLevel] {
        var levels: [String: PulseLevel] = [:]
        for (kind, raw) in value as? [String: Any] ?? [:] {
            if let level = (raw as? String).flatMap(PulseLevel.init(rawValue:)) { levels[kind] = level }
        }
        return levels
    }

    /// The cards' promises by chat, then by Hermes' message id: the chat
    /// shows a Pulse mark on those messages that opens their card.
    var sources: [String: [Int: Int]] {
        var sources: [String: [Int: Int]] = [:]
        // Oldest first, so a message with several cards opens its newest.
        for card in cards.reversed() where !card.chatID.isEmpty {
            if let message = card.messageID { sources[card.chatID, default: [:]][message] = card.id }
        }
        return sources
    }
}

/// GET /pulse/learned.
struct PulseLearned: Equatable {
    var lessons: [PulseLesson] = []
    var levels: [String: PulseLevel] = [:]

    init() {}

    init?(json: [String: Any]) {
        guard let lessons = json["lessons"] as? [Any] else { return nil }
        self.lessons = lessons.compactMap(PulseLesson.init(json:))
        levels = PulseFeedPage.levels(json["levels"])
    }
}

extension PulseClient {
    func feed() async throws -> PulseFeedPage {
        let response = try await request("\(Self.path)/feed", "GET", nil)
        guard let page = PulseFeedPage(json: response) else { throw HermesError.invalidResponse }
        return page
    }

    /// Marks these cards seen, or every card for nil.
    func markSeen(_ ids: [Int]?) async throws {
        _ = try await request("\(Self.path)/feed/seen", "POST", ["ids": ids.map { $0 as Any } ?? NSNull()])
    }

    /// The lessons the rating made.
    func rate(card: Int, up: Bool, reason: PulseDownReason? = nil) async throws -> [PulseLesson] {
        var body: [String: Any] = ["card": card, "rating": up ? "up" : "down"]
        if let reason, !up { body["reason"] = reason.rawValue }
        let response = try await request("\(Self.path)/rate", "POST", body)
        return (response["learned"] as? [Any] ?? []).compactMap(PulseLesson.init(json:))
    }

    /// Marks a follow-up card done (its promise closes, no rating), or
    /// takes the mark off; whether it changed.
    @discardableResult
    func markDone(card: Int, done: Bool) async throws -> Bool {
        let response = try await request("\(Self.path)/done", "POST", ["card": card, "done": done])
        return response["changed"] as? Bool ?? false
    }

    func learned() async throws -> PulseLearned {
        let response = try await request("\(Self.path)/learned", "GET", nil)
        guard let learned = PulseLearned(json: response) else { throw HermesError.invalidResponse }
        return learned
    }

    func undo(lesson: Int) async throws -> PulseLearned {
        let response = try await request("\(Self.path)/learned/undo", "POST", ["id": lesson])
        guard let learned = PulseLearned(json: response) else { throw HermesError.invalidResponse }
        return learned
    }

    func setLevel(_ level: PulseLevel, for kind: String) async throws -> PulseLearned {
        let response = try await request("\(Self.path)/levels", "PUT", ["kind": kind, "level": level.rawValue])
        guard let learned = PulseLearned(json: response) else { throw HermesError.invalidResponse }
        return learned
    }
}

extension AppState {
    /// The Pulse screen and its button: TestFlight and Xcode builds whose
    /// plugin serves the feed (0.55.0 and later).
    var showsPulseScreen: Bool {
        showsPulseSettings && notifierPlugin.reports(PulseClient.feedCapability)
    }

    /// Reads the feed for the button's badge and the chat's Pulse marks.
    /// A failure keeps what was there.
    func refreshPulseFeed() async {
        guard showsPulseScreen else {
            pulseUnseen = 0
            pulseSources = [:]
            pulseHomeChatID = nil
            return
        }
        let dashboard = activeDashboardID
        guard let page = try? await pulseClient.feed(), activeDashboardID == dashboard else { return }
        applyPulseFeed(page)
    }

    func applyPulseFeed(_ page: PulseFeedPage) {
        if pulseUnseen != page.unseen { pulseUnseen = page.unseen }
        let sources = page.sources
        if sources != pulseSources { pulseSources = sources }
        if page.homeChatID != pulseHomeChatID { pulseHomeChatID = page.homeChatID }
    }

    /// Pulse's own chat: Conduit shows it as the Pulse screen, not in Chats.
    func isPulseHomeChat(_ session: SessionSummary) -> Bool {
        guard let home = pulseHomeChatID, showsPulseScreen, profilesMatch(activeProfile, Self.pulseHomeProfile) else {
            return false
        }
        return session.nestingIDs.contains(home)
    }

    /// A reply Pulse pushed from its own chat opens the Pulse screen, where
    /// it is a card. Decisions, calls and chat links still open the chat, and
    /// so does any reply while a sheet is up, which the screen can't cover.
    func opensPulseScreen(for target: ConduitNotificationTarget) async -> Bool {
        guard target.type == "response.ready", target.decision == nil, target.call == nil, !target.isChatLink,
              target.profile.map({ profilesMatch($0, Self.pulseHomeProfile) }) ?? true,
              showsPulseScreen, !isModalSheetPresented else { return false }
        if pulseHomeChatID == nil { await refreshPulseFeed() }
        guard let home = pulseHomeChatID, home == target.sessionId || home == target.durableSessionID else {
            return false
        }
        openPulse(card: nil)
        return true
    }

    /// The card a message of the open chat has, by Hermes' message id.
    func pulseCards(forChat sessionID: String?) -> [Int: Int] {
        guard let sessionID, !pulseSources.isEmpty else { return [:] }
        if let cards = pulseSources[sessionID] { return cards }
        return canonicalSessionID(for: sessionID).flatMap { pulseSources[$0] } ?? [:]
    }

    /// Opens the Pulse screen at a card (the Pulse mark on a message).
    func openPulse(card: Int?) {
        pulseOpenRequest = PulseOpenRequest(card: card)
    }

    /// Opens the chat a card came from.
    func openPulseCardChat(_ card: PulseCard) {
        guard !card.chatID.isEmpty else { return }
        openAppLink(.session(id: card.chatID, profile: card.profile.isEmpty ? Self.pulseHomeProfile : card.profile))
    }

    /// Opens Pulse's own chat and sends `text` there once it's open (or
    /// leaves it in that chat's composer); false when the chat didn't open.
    func replyInPulseChat(_ text: String, chatID: String) async -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }
        let dashboard = activeDashboardID
        openAppLink(.session(id: chatID, profile: Self.pulseHomeProfile))
        guard await waitForOpenChat(chatID, on: dashboard) else { return false }
        // The chat is open: a send it refused waits in its composer.
        let sent = await sendMessage(message)
        if !sent { prefillComposer(message) }
        return true
    }

    /// Do it on a follow-up card: opens the chat the promise or to-do came
    /// from with the reminder in its composer, ready to send. False when the
    /// chat didn't open.
    func actOnPulseCard(_ card: PulseCard) async -> Bool {
        guard card.isActionable else { return false }
        let dashboard = activeDashboardID
        openPulseCardChat(card)
        guard await waitForOpenChat(card.chatID, on: dashboard) else { return false }
        prefillComposer(card.actionMessage)
        return true
    }

    /// Waits up to ten seconds for `chatID` to be the open chat. Gives up
    /// when the task is cancelled or the dashboard changes meanwhile, so a
    /// same-named chat elsewhere never gets the text.
    private func waitForOpenChat(_ chatID: String, on dashboard: UUID?) async -> Bool {
        for _ in 0..<40 {
            guard activeDashboardID == dashboard, !Task.isCancelled else { return false }
            if activeSessionId == chatID || activeSessionId.flatMap({ canonicalSessionID(for: $0) }) == chatID {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return false
            }
        }
        return false
    }
}

/// A request to show the Pulse screen, at a card or at the top.
struct PulseOpenRequest: Equatable {
    let id = UUID()
    let card: Int?
}

extension PulseClient {
    /// The plugin serves the feed, ratings and lessons (0.55.0).
    static let feedCapability = "pulse_feed"
    /// Settings > Pulse picks Pulse's model (0.57.0).
    static let modelCapability = "pulse_model"
    /// Settings > Pulse sets how much Pulse nudges and its daily token budgets (0.63.0).
    static let nudgeCapability = "pulse_nudge"
    /// Follow-up cards can be marked done (0.64.0).
    static let doneCapability = "pulse_done"
}
