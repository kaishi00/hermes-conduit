//
//  PulseFeed.swift
//  Conduit
//
//  The Pulse screen's data (TestFlight and Xcode builds): the cards Pulse
//  brought the user, their ratings, and what the ratings taught it. The
//  plugin keeps all of it (pulse_learning.py) and serves it on
//  /api/plugins/conduit_push/pulse/feed, /rate and /learned. A rating
//  changes what Pulse does on the host: each kind sits on a loudness ladder
//  (push, Pulse screen, morning brief, off), and a thumbs down's reason adds
//  a lesson the user can undo. Before 0.80.3 thumbs moved a kind along the
//  ladder; from then (`pulse_learns`) thumbs, Do it and Done teach Pulse
//  what to bring up and how loudly, and a kind's level is the loudest it gets.
//

import Foundation

/// One thing Pulse brought the user: a follow-up on what Hermes promised,
/// a report on what it saw in the chats, or the morning brief.
struct PulseCard: Equatable, Identifiable {
    let id: Int
    /// "followup", "noticed" (one of a report's items), "report" or "brief".
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
    /// What a report item is about ("date", "promise"…) on a "noticed" card.
    let topic: String
    /// The morning brief it went out in (0.68.0): the brief's own card and
    /// the held cards it brought share it, and show together.
    let brief: String
    /// Swiped away ("Not now"): in Done and cleared, nothing learned.
    var dismissedAt: Date?
    /// Not now until a time (later today, tomorrow, next week): when it
    /// comes back as new (0.78.3), nil for one swiped away for good.
    var restUntil: Date?
    /// When it was marked done: by the user on the Pulse screen, or by
    /// Pulse after Do it, once the chat showed it got done.
    var doneAt: Date?
    /// "user" or "pulse".
    var doneBy: String
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
        topic = object["topic"] as? String ?? ""
        brief = object["brief"] as? String ?? ""
        dismissedAt = PulseJSON.date(object["dismissed_at"])
        restUntil = PulseJSON.date(object["rest_until"])
        doneAt = PulseJSON.date(object["done_at"])
        doneBy = object["done_by"] as? String ?? ""
        rating = object["rating"] as? String ?? ""
        reason = object["reason"] as? String ?? ""
        formattedNews = Self.formatted(news, markdown: kind != "followup")
    }

    /// Held for the morning brief and not in one yet.
    var isHeld: Bool { level == PulseLevel.brief.rawValue && briefedAt == nil }

    /// One of a report's items, on its own card.
    var isNoticed: Bool { kind == "noticed" }

    /// A report item Pulse found on its own, in a chat it didn't remember,
    /// the calendar, reminders or the Shortcuts inbox: nothing remembered
    /// is behind it.
    var isFound: Bool { isNoticed && itemID == nil }

    /// Done or swiped away: it goes under Done and cleared.
    var isCleared: Bool { doneAt != nil || dismissedAt != nil }

    /// Follow-ups and report items take ratings; a whole report or a brief
    /// is Hermes' own reply.
    var isRatable: Bool { kind == "followup" || isNoticed }

    /// A follow-up, or a report item drawn from something Pulse remembers,
    /// can be marked done: that thing closes, without a rating. One Pulse
    /// found on its own can be too, by a plugin that takes it
    /// (AppState.canMarkPulseCardDone).
    var canBeDone: Bool { (kind == "followup" || isNoticed) && itemID != nil }

    /// It can be acted on in the chat the remembered thing came from.
    var isActionable: Bool {
        (kind == "followup" || (isNoticed && itemID != nil)) && !chatID.isEmpty && hasReminder
    }

    /// Do it has a reminder to leave in the composer.
    var hasReminder: Bool { !(news.isEmpty && title.isEmpty) }

    /// The card's heading: a report item's topic, else its kind.
    var heading: String { isNoticed ? PulseCardKind.topic(topic) : PulseCardKind.title(kind) }

    /// What Do it leaves in that chat's composer: the reminder, and an ask
    /// that fits what the card is about, for the user to send or change.
    /// Something the user meant to do gets taken care of; what Hermes said
    /// it would do (a follow-up, a promise) gets a go-ahead; a date ahead,
    /// getting ready; something watched, where it stands; an interest, more
    /// about it; anything else, a look.
    var actionMessage: String {
        let reminder = news.isEmpty ? title : news
        switch kind == "followup" ? "promise" : topic {
        case "promise":
            return AppLocalization.string("Pulse reminded me: \(reminder)\n\nGo ahead with it now.")
        case "commitment", "reminder", "intention", "follow-up":
            return AppLocalization.string("Pulse reminded me: \(reminder)\n\nLet's take care of it now.")
        case "date":
            return AppLocalization.string("Pulse brought this up: \(reminder)\n\nHelp me get ready for it.")
        case "watch":
            return AppLocalization.string("Pulse brought this up: \(reminder)\n\nWhere does that stand now?")
        case "interest":
            return AppLocalization.string("Pulse brought this up: \(reminder)\n\nTell me more.")
        default:
            return AppLocalization.string("Pulse brought this up: \(reminder)\n\nLet's look into it.")
        }
    }

    private static func formatted(_ news: String, markdown: Bool) -> AttributedString {
        guard markdown else { return AttributedString(news) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: news, options: options)) ?? AttributedString(news)
    }
}

/// The Pulse screen's order: morning briefs with the cards they brought
/// (or their summary alone), then what's still open, then what's done or swiped away.
struct PulseLayout: Equatable {
    struct Brief: Equatable, Identifiable {
        let card: PulseCard
        /// The held cards it brought, oldest first.
        let items: [PulseCard]

        var id: Int { card.id }
        /// Brought no held cards (0.76.0): the brief is its summary alone.
        var isSummary: Bool { items.isEmpty }
        var left: Int { items.filter { !$0.isCleared }.count }
        /// Every card it brought is done or swiped away.
        var isHandled: Bool { left == 0 }
    }

    /// Briefs still holding something open, newest first, then the newest
    /// brief even when it's all handled (it folds to one row).
    var briefs: [Brief] = []
    var open: [PulseCard] = []
    /// Done or swiped away, newest first, with older briefs all handled.
    var cleared: [PulseCard] = []
    var clearedBriefs: [Brief] = []

    init() {}

    /// `keeping`: cards that stay where they are though cleared (the one a
    /// push or a Pulse mark opened).
    init(cards: [PulseCard], keeping: Set<Int> = []) {
        var grouped: [String: [PulseCard]] = [:]
        for card in cards where !card.brief.isEmpty && card.kind != "brief" {
            grouped[card.brief, default: []].append(card)
        }
        var taken: Set<Int> = []
        var newest = true
        for card in cards where card.kind == "brief" && !card.brief.isEmpty {
            let items = grouped[card.brief] ?? []
            let brief = Brief(card: card, items: items.sorted { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) })
            taken.insert(card.id)
            taken.formUnion(items.map(\.id))
            if !brief.isHandled || newest || keeping.contains(card.id) || items.contains(where: { keeping.contains($0.id) }) {
                briefs.append(brief)
            } else {
                clearedBriefs.append(brief)
            }
            newest = false
        }
        for card in cards where !taken.contains(card.id) {
            if card.isCleared && !keeping.contains(card.id) { cleared.append(card) } else { open.append(card) }
        }
    }

    /// A brief that brought nothing counts as one.
    var clearedCount: Int { cleared.count + clearedBriefs.reduce(0) { $0 + max(1, $1.items.count) } }

    /// Nothing left on the screen: no open card, no brief with cards left,
    /// and no brief that is its summary alone (it lists what's still open).
    var isCaughtUp: Bool { open.isEmpty && briefs.allSatisfy { $0.isHandled && !$0.isSummary } }
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
        case "noticed": return AppLocalization.string("Noticed")
        default: return kind
        }
    }

    /// A report item's topic (pulse_report.KINDS on the host).
    static func topic(_ topic: String) -> String {
        switch topic {
        case "commitment": return AppLocalization.string("Commitment")
        case "promise": return AppLocalization.string("Promise")
        case "date": return AppLocalization.string("Date")
        case "follow-up": return AppLocalization.string("Follow-up")
        case "reminder": return AppLocalization.string("Reminder")
        case "watch": return AppLocalization.string("Watching")
        case "intention": return AppLocalization.string("Plan")
        case "interest": return AppLocalization.string("Interest")
        case "fact": return AppLocalization.string("Worth knowing")
        default: return AppLocalization.string("Noticed")
        }
    }

    /// What a lesson is about: a card kind's heading, else a report item's
    /// topic, which a report card's reasons teach about (0.80.3).
    static func name(_ kind: String) -> String {
        ["followup", "report", "brief", "noticed"].contains(kind) ? title(kind) : topic(kind)
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
            return AppLocalization.string("\(PulseCardKind.name(kind)): \(level)")
        case "rule":
            return AppLocalization.string("No updates about “\(value)”")
        case "sooner":
            return kind == "followup" ? AppLocalization.string("Check on promises sooner")
                : AppLocalization.string("\(PulseCardKind.name(kind)): Bring up sooner")
        case "seen":
            return kind == "followup" ? AppLocalization.string("Skip news you already saw in the chat")
                : AppLocalization.string("\(PulseCardKind.name(kind)): Skip what you already know")
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
    /// Why Pulse is quiet now, and when it speaks up again (0.80.2); nil
    /// while it isn't, and from an older plugin.
    var quietNow: PulseQuietReason?
    var quietEndsAt: Date?

    init() {}

    init?(json: [String: Any]) {
        guard let cards = json["cards"] as? [Any] else { return nil }
        self.cards = cards.compactMap(PulseCard.init(json:))
        unseen = PulseJSON.int(json["unseen"]) ?? 0
        levels = PulseFeedPage.levels(json["levels"])
        let home = (json["home_chat_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        homeChatID = home?.isEmpty == false ? home : nil
        quietNow = (json["quiet_now"] as? String).flatMap(PulseQuietReason.init(rawValue:))
        quietEndsAt = quietNow == nil ? nil : PulseJSON.date(json["quiet_ends_at"])
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

    /// Under each kind's level in What Pulse learned: what moves it. With a
    /// plugin that learns (`pulse_learns`) the level is the loudest Pulse
    /// gets, and thumbs teach it within that instead of moving the level.
    static func levelsFooter(learns: Bool) -> String {
        learns
            ? AppLocalization.string("The loudest Pulse gets for each. Within that, your thumbs, Do it and Done teach it what to bring up and how loudly.")
            : AppLocalization.string("Thumbs move these too: two down make it quieter, two up louder.")
    }

    /// What Pulse learned with no lessons yet. With a plugin that learns, a
    /// plain thumbs teaches Pulse without adding a lesson: only a thumbs
    /// down's reason does.
    static func noLessons(learns: Bool) -> String {
        learns
            ? AppLocalization.string("Nothing yet. When you give a reason with a thumbs down, what it changes shows up here.")
            : AppLocalization.string("Nothing yet. Rate Pulse's cards and what it learns shows up here.")
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

    /// Marks a card done (a promise behind it closes, no rating), or takes
    /// the mark off; whether it changed.
    @discardableResult
    func markDone(card: Int, done: Bool) async throws -> Bool {
        let response = try await request("\(Self.path)/done", "POST", ["card": card, "done": done])
        return PulseJSON.bool(response["changed"]) ?? false
    }

    /// Do it on a card: Pulse reads the chat it opened once Hermes has
    /// answered and marks the card done if it got done. Only the card is
    /// named: a new chat Do it started for an item from no chat is found by
    /// the reminder's words, which it shares with the card (notifier #362).
    func acted(card: Int) async throws {
        _ = try await request("\(Self.path)/acted", "POST", ["card": card])
    }

    /// Not now: swipes a card away (nothing learned) until later today,
    /// tomorrow or next week (`until`, 0.78.3), or for good, or puts it
    /// back; whether it changed, and when it comes back.
    @discardableResult
    func dismiss(card: Int, dismissed: Bool, until: PulseRest? = nil) async throws -> PulseDismissal {
        var body: [String: Any] = ["card": card, "dismissed": dismissed]
        if let until { body["until"] = until.rawValue }
        let response = try await request("\(Self.path)/dismiss", "POST", body)
        return PulseDismissal(changed: PulseJSON.bool(response["changed"]) ?? false,
                              restUntil: PulseJSON.date(response["rest_until"]))
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
    /// plugin serves the feed (0.55.0 and later). Until the plugin answers
    /// after a launch or a reconnect, a dashboard that had Pulse keeps it.
    var showsPulseScreen: Bool {
        (showsPulseSettings && notifierPlugin.reports(PulseClient.feedCapability))
            || (appInstallSource != .appStore && pulsePluginUnanswered && pulseHomeChat != nil)
    }

    /// Whether the plugin hasn't answered since the launch or the last reconnect.
    private var pulsePluginUnanswered: Bool { notifierPlugin.state == .unknown }

    /// Pulse's own chat: the feed's, or until the feed is read, the one it named last time here.
    var pulseHomeChat: String? {
        pulseHomeChatID ?? activeDashboardID.flatMap { pulseRememberedHomes[$0.uuidString] }
    }

    /// A plugin that answered without the feed (or predates reporting):
    /// this dashboard has no Pulse chat to hide or remember.
    func forgetPulseHomeIfGone() {
        guard !pulsePluginUnanswered, !notifierPlugin.reports(PulseClient.feedCapability) else { return }
        if pulseHomeChatID != nil { pulseHomeChatID = nil }
        rememberPulseHome(nil)
    }

    /// Reads the feed for the button's badge and the chat's Pulse marks.
    /// A failure keeps what was there.
    func refreshPulseFeed() async {
        guard showsPulseScreen else {
            pulseUnseen = 0
            pulseSources = [:]
            pulseHomeChatID = nil
            if !pulsePluginUnanswered { rememberPulseHome(nil) }  // the plugin said: no Pulse here
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
        rememberPulseHome(page.homeChatID)
    }

    /// Pulse's own chat: Conduit shows it as the Pulse screen, not in Chats.
    func isPulseHomeChat(_ session: SessionSummary) -> Bool {
        // By the row's own profile: in All a row can be another profile's.
        guard let home = pulseHomeChat, showsPulseScreen, profilesMatch(rowProfile(session), Self.pulseHomeProfile) else {
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
        if pulseHomeChat == nil { await refreshPulseFeed() }
        guard let home = pulseHomeChat, home == target.sessionId || home == target.durableSessionID else {
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

    /// The card links a chat to open: not Pulse's own, which is hidden (a
    /// report's or brief's cards point there).
    func pulseCardHasChat(_ card: PulseCard) -> Bool {
        !card.chatID.isEmpty && card.chatID != pulseHomeChat
    }

    /// Done on this card: a follow-up's or a remembered report item's
    /// (0.64.0), or one Pulse found on its own (0.77.0).
    func canMarkPulseCardDone(_ card: PulseCard) -> Bool {
        notifierPlugin.reports(PulseClient.doneCapability)
            && (card.canBeDone || card.isFound && notifierPlugin.reports(PulseClient.foundActionsCapability))
    }

    /// Do it on this card: one about something Pulse remembers, or a report
    /// item Pulse found on its own (0.77.0).
    func canActOnPulseCard(_ card: PulseCard) -> Bool {
        card.isActionable
            || card.isFound && card.hasReminder && notifierPlugin.reports(PulseClient.foundActionsCapability)
    }

    /// Why? on this card: a follow-up's reason, or any other card's once the
    /// plugin gives each report item its candidate's reason (0.80.1). A
    /// plugin from before gave report and brief cards stock lines, not reasons.
    func explainsPulseCard(_ card: PulseCard) -> Bool {
        !card.why.isEmpty && (card.kind == "followup" || notifierPlugin.reports(PulseClient.cardWhyCapability))
    }

    /// A thumbs down on this card asks why: a follow-up's, or a report
    /// card's once the plugin acts on its reasons (0.80.3). Before, a report
    /// card's reason changed nothing, so its thumbs down was enough.
    func asksPulseDownReason(_ card: PulseCard) -> Bool {
        card.kind == "followup" || card.isNoticed && notifierPlugin.reports(PulseClient.learnsCapability)
    }

    /// Opens the chat a card came from.
    /// It opens at the message the card came from, as an artifact's Show
    /// in chat does, whatever the chat would otherwise land on.
    func openPulseCardChat(_ card: PulseCard) {
        guard pulseCardHasChat(card) else { return }
        pendingArtifactReveal = card.messageID.map { ArtifactReveal(messageID: $0, opening: card.chatID) }
        openAppLink(.session(id: card.chatID, profile: card.profile.isEmpty ? Self.pulseHomeProfile : card.profile))
    }

    /// Do it: opens the chat the card came from with the reminder in its
    /// composer, ready to send. A card from no chat (a report item from the
    /// calendar, reminders or the Shortcuts inbox) gets a new chat in Pulse's
    /// profile, where Pulse reads what came of it, and only the chat that
    /// New Chat made gets the reminder (startPulseNewChat). False when no
    /// chat opened.
    func actOnPulseCard(_ card: PulseCard) async -> Bool {
        guard canActOnPulseCard(card), pulseNewChatRefusal(for: card) == nil else { return false }
        let dashboard = activeDashboardID
        if pulseCardHasChat(card) {
            openPulseCardChat(card)
            guard await waitForOpenChat(card.chatID, on: dashboard) else { return false }
        } else {
            if !profilesMatch(activeProfile, Self.pulseHomeProfile) {
                // The switch returns with Pulse's profile connected and its chat open.
                guard await switchProfileForPulse(), activeDashboardID == dashboard,
                      profilesMatch(activeProfile, Self.pulseHomeProfile) else { return false }
            }
            guard await startPulseNewChat() != nil, activeDashboardID == dashboard else { return false }
        }
        prefillComposer(card.actionMessage)
        return true
    }

    /// Why Do it can't start a new chat for a card from no chat right now,
    /// for the Pulse screen to say before a chat covers it; nil when it can,
    /// or when the card has a chat of its own. Do it starts its chat only
    /// when New Chat can start one at once (startPulseNewChat, by
    /// canStartNewChatNow): connecting or synchronizing, New Chat would make
    /// one that waits, and a New Chat already starting or waiting comes
    /// first. From another profile, a call stops the switch, as it does New
    /// Chat's (startNewChat(inProfile:)).
    func pulseNewChatRefusal(for card: PulseCard) -> String? {
        guard !pulseCardHasChat(card) else { return nil }
        if !profilesMatch(activeProfile, Self.pulseHomeProfile), isVoiceCallInProgress {
            return AppLocalization.string("End the call to open a chat in another profile.")
        }
        guard isConnected || isConnecting else {
            return AppLocalization.string("Couldn't start a new chat. Check your connection and try again.")
        }
        if isProfileSwitching {
            return AppLocalization.string("Wait for the workspace switch to finish before starting a conversation.")
        }
        // Connecting, synchronizing, an offline copy on screen, or no client yet.
        if !canStartNewChatNow {
            return AppLocalization.string("Conduit is still connecting to your dashboard. Try again in a moment.")
        }
        if isStartingNewChat || showsPendingNewChat {
            return AppLocalization.string("Another new chat is starting. Try again in a moment.")
        }
        return nil
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
    /// After Do it, Pulse marks the card done itself once the chat shows it (0.64.0).
    static let actedCapability = "pulse_acted"
    /// Cards can be swiped away, and briefs name the cards they brought (0.68.0).
    static let dismissCapability = "pulse_dismiss"
    /// The morning brief comes every day with what's still open (0.76.0).
    static let dailyBriefCapability = "pulse_daily_brief"
    /// Done and Do it take report items Pulse found on its own, and one found
    /// in a chat points at that chat (0.77.0).
    static let foundActionsCapability = "pulse_found_actions"
    /// Settings > Pulse takes a note to Pulse, in the user's own words (0.78.2).
    static let noteCapability = "pulse_note"
    /// Not now asks until when: later today, tomorrow or next week, and the
    /// card comes back as new then (0.78.3).
    static let restCapability = "pulse_rest"
    /// A report card's why is its reason (why now, where it came from),
    /// for Why? on the card (0.80.1).
    static let cardWhyCapability = "pulse_card_why"
    /// Quiet times: quiet days and a vacation in Settings > Pulse, and Quiet
    /// for today on the Pulse screen and on a Pulse notification (0.80.2).
    static let quietCapability = "pulse_quiet"
    /// Pulse learns from thumbs, Do it and Done what to bring up and how
    /// loudly, and a kind's level is the loudest it gets (0.80.3).
    static let learnsCapability = "pulse_learns"
}

/// What Not now puts a card off until, as the plugin names it.
enum PulseRest: String, CaseIterable, Identifiable {
    case laterToday = "later_today"
    case tomorrow
    case nextWeek = "next_week"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .laterToday: AppLocalization.string("Later today")
        case .tomorrow: AppLocalization.string("Tomorrow")
        case .nextWeek: AppLocalization.string("Next week")
        }
    }

    /// The Undo bar's line once a card is put off.
    var undoMessage: String {
        switch self {
        case .laterToday: AppLocalization.string("Put off until later today. It comes back as new then.")
        case .tomorrow: AppLocalization.string("Put off until tomorrow. It comes back as new then.")
        case .nextWeek: AppLocalization.string("Put off until next week. It comes back as new then.")
        }
    }

    /// What the dialog offers: later today only while it is still today's
    /// to give. From 22:30 the plugin makes it tomorrow (three hours, by
    /// 23:00, and never under half an hour), so it would say tomorrow twice.
    static func choices(now: Date = Date(), calendar: Calendar = .current) -> [PulseRest] {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let lateEvening = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) >= 22 * 60 + 30
        return lateEvening ? [.tomorrow, .nextWeek] : allCases
    }

    /// The choice a time the plugin set comes to, for the Undo bar: later
    /// today, tomorrow, or next week (the brief's day a week on).
    static func returning(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> PulseRest {
        switch Self.days(to: date, now: now, calendar: calendar) {
        case ...0: .laterToday
        case 1: .tomorrow
        default: .nextWeek
        }
    }

    /// When a card put off comes back, as its cleared row says it: later
    /// today, tomorrow, a weekday this week, or next week.
    static func backText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let ahead = Self.days(to: date, now: now, calendar: calendar)
        if ahead <= 0 { return AppLocalization.string("Back later today") }
        if ahead == 1 { return AppLocalization.string("Back tomorrow") }
        if ahead < 7 {
            let weekday = Date.FormatStyle(locale: AppLocalization.formattingLocale, calendar: calendar,
                                           timeZone: calendar.timeZone).weekday(.wide)
            return AppLocalization.string("Back on \(date.formatted(weekday))")
        }
        return AppLocalization.string("Back next week")
    }

    /// Days from `now` to `date`'s day, not from the clock: a time already
    /// past is today.
    static func days(to date: Date, now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }
}

/// The plugin's answer to Not now or Put back.
struct PulseDismissal: Equatable {
    let changed: Bool
    let restUntil: Date?
}
