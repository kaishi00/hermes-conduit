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
//  a lesson the user can undo. Before 0.81.1 thumbs moved a kind along the
//  ladder; from then (`pulse_learns`) thumbs, Do it and Done teach Pulse
//  what to bring up and how loudly, and a kind's level is the loudest it gets.
//  From 0.84.0 (`pulse_explains`) it shows what it learned: a card's Why?
//  names the biggest part learning played, What Pulse learned lists what
//  learning holds with Reset, and What Pulse left out lists what the reports
//  didn't bring up, with Bring it up. From 0.86.0 (`pulse_hours`) a thumbs
//  down's Wrong time puts the card away until a better time and keeps its
//  kind's notifications out of that part of the day, and Not now's later
//  today ends when the night starts. From 0.88.0 (`pulse_dates`) Pulse
//  brings up birthdays and anniversaries every year and looks two weeks
//  ahead once a day, and What Pulse left out names the look ahead for what
//  it left out. From 0.90.0 (`pulse_inbox`) Pulse memory keeps deadlines
//  from the Shortcuts inbox: a deadline's card can be done, and Do it
//  starts a new chat, as it came from none. From 0.96.0 (`pulse_look`)
//  Pulse's turns look things up before they write, and a card's Why? says
//  what its turn looked at. From 0.98.0 (`pulse_proposals`) an event or
//  reminder a turn would add is a suggestion on a card of its own, with Add
//  and Not now: the phone that tapped Add applies it without its own card.
//  From 0.106.0 (`pulse_next`) a report can bring up a next step, after
//  something got done or an event ended, with a level of its own in What
//  Pulse learned. From 0.107.0 a card whose Do it stalled comes back once,
//  and its Why? says when Do it was tapped. From 0.117.1 a card from a
//  Kanban task's worker names the task: it links the task, and Do it
//  starts a new chat.
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
    /// The Kanban task whose worker's session its chat is (0.117.1): Hermes
    /// won't reopen that as a chat, so the card shows the task instead and
    /// Do it starts a new chat. "" for a worker whose task wasn't named,
    /// nil for a card from a chat or from no chat.
    let kanbanTask: String?
    /// Hermes' `messages.id` of the promise in its chat.
    let messageID: Int?
    let createdAt: Date?
    let seenAt: Date?
    let briefedAt: Date?
    /// The promise or to-do a follow-up is about (memory's item).
    let itemID: Int?
    /// What a report item is about ("date", "promise"…) on a "noticed" card.
    let topic: String
    /// Why it came back after a Do it that stalled (0.107.0): "unsent" (nothing
    /// was sent from the chat) or "not_done" (Pulse's checks found it not
    /// done); "" for a card that never came back.
    let back: String
    /// When that Do it was tapped.
    let backActedAt: Date?
    /// The morning brief it went out in (0.68.0): the brief's own card and
    /// the held cards it brought share it, and show together.
    let brief: String
    /// Swiped away ("Not now"), or put away by Wrong time on a thumbs down
    /// (0.86.0): in Done and cleared.
    var dismissedAt: Date?
    /// Not now until a time (later today, tomorrow, next week), or Wrong
    /// time until a better one (0.86.0): when it comes back as new
    /// (0.78.3), nil for one swiped away for good.
    var restUntil: Date?
    /// When it was marked done: by the user on the Pulse screen, or by
    /// Pulse once a chat showed it got done, after Do it or (0.87.0)
    /// wherever it was done.
    var doneAt: Date?
    /// "user" or "pulse".
    var doneBy: String
    /// "up", "down" or "".
    var rating: String
    var reason: String
    var ratedAt: Date?
    /// Hermes' reply as it wrote it (a report, a brief): bold, links and
    /// lines kept. Parsed once, not on every redraw.
    let formattedNews: AttributedString
    /// The biggest part what Pulse learned played in bringing it up, for
    /// its Why? (0.84.0); nil when learning added next to nothing.
    let learned: PulsePreference?
    /// What the turn that brought it up looked at first, by source
    /// (pulse_tools labels: "calendar", "phone", "contacts", "maps", "web";
    /// 0.96.0; "location", 0.100.0), for its Why?. Never the queries.
    let looked: [String]
    /// A suggestion's (kind "proposal", 0.98.0): what Add puts on the phone,
    /// and where it stands.
    var proposal: PulseProposal?

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
        kanbanTask = object["kanban_task"] as? String
        messageID = PulseJSON.int(object["message_id"])
        createdAt = PulseJSON.date(object["created_at"])
        seenAt = PulseJSON.date(object["seen_at"])
        briefedAt = PulseJSON.date(object["briefed_at"])
        itemID = PulseJSON.int(object["item_id"])
        topic = object["topic"] as? String ?? ""
        back = object["back"] as? String ?? ""
        backActedAt = PulseJSON.date(object["back_acted_at"])
        brief = object["brief"] as? String ?? ""
        dismissedAt = PulseJSON.date(object["dismissed_at"])
        restUntil = PulseJSON.date(object["rest_until"])
        doneAt = PulseJSON.date(object["done_at"])
        doneBy = object["done_by"] as? String ?? ""
        rating = object["rating"] as? String ?? ""
        reason = object["reason"] as? String ?? ""
        ratedAt = PulseJSON.date(object["rated_at"])
        formattedNews = Self.formatted(news, markdown: kind != "followup")
        learned = PulsePreference(json: object["learned"], chatPlace: PulsePreference.chatPlace(profile, chatID),
                                  chatTitle: chatTitle)
        looked = PulseJSON.strings(object["looked"])
        proposal = PulseProposal(json: object["proposal"])
    }

    /// Held for the morning brief and not in one yet.
    var isHeld: Bool { level == PulseLevel.brief.rawValue && briefedAt == nil }

    /// Put away by Wrong time, not by Not now: the plugin rates it and puts
    /// it away at the same moment, and a rating stays when the card is put
    /// back and swiped away again.
    var isAwayForWrongTime: Bool {
        guard let dismissedAt, let ratedAt, reason == PulseDownReason.wrongTime.rawValue else { return false }
        return abs(dismissedAt.timeIntervalSince(ratedAt)) < 1
    }

    /// One of a report's items, on its own card.
    var isNoticed: Bool { kind == "noticed" }

    /// A report item Pulse found on its own, in a chat it didn't remember,
    /// the calendar, reminders or the Shortcuts inbox: nothing remembered
    /// is behind it.
    var isFound: Bool { isNoticed && itemID == nil }

    /// A suggestion Pulse made instead of changing the phone (0.98.0).
    var isProposal: Bool { kind == PulseProposal.kind }

    /// Done or swiped away, or a suggestion that's settled (added, or not):
    /// it goes under Done and cleared.
    var isCleared: Bool {
        doneAt != nil || dismissedAt != nil || (isProposal && proposal?.isOpen != true)
    }

    /// Put away by Not now or Wrong time, and not done meanwhile. One Pulse
    /// marks done while it rests (0.87.0) doesn't come back at its time, so
    /// it shows as done, and Undo leaves it put away.
    var isResting: Bool { dismissedAt != nil && doneAt == nil }

    /// A cleared card's label: what put it away and when it comes back, or,
    /// done (while it rested too), who saw it done.
    var clearedTitle: String {
        guard isResting else {
            return doneBy == "pulse" ? AppLocalization.string("Done, seen in the chat") : AppLocalization.string("Done")
        }
        let away = isAwayForWrongTime ? PulseDownReason.wrongTime.title : AppLocalization.string("Not now")
        guard let restUntil else { return away }
        return away + " · " + PulseRest.backText(restUntil)
    }

    /// What Undo of Done does, for VoiceOver: a card put away stays away;
    /// one about something Pulse remembers has that thing checked on again;
    /// any other is back on the list.
    var undoDoneHint: String {
        if dismissedAt != nil { return AppLocalization.string("Keeps the card put away") }
        return itemID != nil ? AppLocalization.string("Pulse checks on it again")
            : AppLocalization.string("Puts the card back on the list")
    }

    /// Follow-ups and report items take ratings; a whole report or a brief
    /// is Hermes' own reply.
    var isRatable: Bool { kind == "followup" || isNoticed }

    /// A follow-up, or a report item drawn from something Pulse remembers,
    /// can be marked done: that thing closes, without a rating. One Pulse
    /// found on its own can be too, by a plugin that takes it
    /// (AppState.canMarkPulseCardDone).
    var canBeDone: Bool { (kind == "followup" || isNoticed) && itemID != nil }

    /// It can be acted on in the chat the remembered thing came from, or in
    /// a new one for a deadline from the Shortcuts inbox (0.90.0), which
    /// came from no chat, or for one from a Kanban task's worker (0.117.1).
    var isActionable: Bool {
        (kind == "followup" || (isNoticed && itemID != nil))
            && (!chatID.isEmpty || topic == "deadline" || kanbanTask != nil)
            && hasReminder
    }

    /// Do it has a reminder to leave in the composer.
    var hasReminder: Bool { !(news.isEmpty && title.isEmpty) }

    /// The card's heading: a report item's topic, else its kind.
    var heading: String { isNoticed ? PulseCardKind.topic(topic) : PulseCardKind.title(kind) }

    /// Why a card came back after a Do it that stalled, in the app's
    /// language, for its Why? in place of the plugin's English (0.107.0);
    /// nil for one that never came back, or a reason this build doesn't know.
    func backText(now: Date = Date()) -> String? {
        guard let backActedAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.locale = AppLocalization.formattingLocale
        let when = formatter.localizedString(for: backActedAt, relativeTo: now)
        switch back {
        case "unsent": return AppLocalization.string("You tapped Do it \(when) but didn't send it.")
        case "not_done": return AppLocalization.string("You tapped Do it \(when), and it isn't done yet.")
        default: return nil
        }
    }

    /// What the turn that brought it up looked at first, as its Why? says
    /// it (0.96.0); nil when it looked at nothing.
    var lookedText: String? {
        let names = looked.compactMap(PulseCardKind.lookedSource)
        guard !names.isEmpty else { return nil }
        let list = names.formatted(.list(type: .and).locale(AppLocalization.formattingLocale))
        return AppLocalization.string("Before writing this, Pulse looked at \(list).")
    }

    /// What Do it leaves in that chat's composer: the reminder, and an ask
    /// that fits what the card is about, for the user to send or change.
    /// Something the user meant to do gets taken care of; what Hermes said
    /// it would do (a follow-up, a promise) gets a go-ahead; a date ahead,
    /// getting ready; a deadline, taking care of it before then; a next
    /// step (0.106.0), taking care of it like a plan; something
    /// watched, where it stands; an interest, more about it; anything else,
    /// a look.
    /// One from a Kanban task's worker asks Hermes to get the task going
    /// again: the work happens on the board, not in a chat.
    var actionMessage: String {
        let reminder = news.isEmpty ? title : news
        if let kanbanTask {
            return kanbanTask.isEmpty
                ? AppLocalization.string("Pulse reminded me: \(reminder)\n\nIt came up in the work on a Kanban task. Find the task on the board, and if it's stuck, get it going again.")
                : AppLocalization.string("Pulse reminded me: \(reminder)\n\nIt came up in the work on Kanban task \(kanbanTask). Check the task on the board, and if it's stuck, get it going again.")
        }
        switch kind == "followup" ? "promise" : topic {
        case "promise":
            return AppLocalization.string("Pulse reminded me: \(reminder)\n\nGo ahead with it now.")
        case "commitment", "reminder", "intention", "follow-up", "next":
            return AppLocalization.string("Pulse reminded me: \(reminder)\n\nLet's take care of it now.")
        case "date":
            return AppLocalization.string("Pulse brought this up: \(reminder)\n\nHelp me get ready for it.")
        case "deadline":
            return AppLocalization.string("Pulse brought this up: \(reminder)\n\nHelp me take care of it before then.")
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

/// A suggestion Pulse made instead of changing the phone (0.98.0,
/// `pulse_proposals`): an event or reminder its turn would have added, kept
/// for the user's Add. Its card follows the phone change Add asked for.
struct PulseProposal: Equatable {
    /// A suggestion card's kind.
    static let kind = "proposal"

    enum State: String {
        /// Waiting for Add or Not now.
        case waiting
        /// Add asked the phone for it, and the phone hasn't said yet.
        case adding
        case added
        /// Added, then changed on the phone.
        case changed
        /// The phone couldn't add it (`note` says why).
        case failed
        /// Not now, or the phone's own card said no.
        case notAdded = "not_added"
        /// Its time passed before Add, or its turn ended without its message.
        case expired
        /// Undo asked the phone to take it off.
        case removing
        case removed
    }

    let id: Int
    /// "add_event" or "add_reminder".
    let kind: String
    /// What it adds and where, written by the plugin from the change itself
    /// ("Add to Personal: Dinner at Nopa, Sat 25 Oct, 19:00 to 21:00").
    let line: String
    var state: State
    /// The phone's reason, when it couldn't add it or changed it.
    var note: String
    let expiresAt: Date?
    /// The phone change Add asked for, and Undo's: the phone that tapped
    /// applies it without its own card (AppState.applyPulseApproval).
    var changeID: String?
    var undoID: String?

    /// Nil for a state this app doesn't know: the card shows no buttons.
    init?(json: Any?) {
        guard let object = json as? [String: Any], let id = PulseJSON.int(object["id"]),
              let state = (object["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }
        self.id = id
        self.state = state
        kind = object["kind"] as? String ?? ""
        line = object["line"] as? String ?? ""
        note = object["note"] as? String ?? ""
        expiresAt = PulseJSON.date(object["expires_at"])
        changeID = (object["change_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        undoID = (object["undo_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var isEvent: Bool { kind == "add_event" }

    /// Still to settle: waiting for Add, or on its way to the phone.
    var isOpen: Bool { state == .waiting || state == .adding }

    /// Undo takes it off the phone again.
    var canUndo: Bool { state == .added || state == .changed }

    /// On its way to or off the phone.
    var isInFlight: Bool { state == .adding || state == .removing }

    /// Where it stands, as its card says it once Add was tapped (or it
    /// settled without it).
    var stateText: String {
        switch state {
        case .waiting: return ""
        case .adding: return AppLocalization.string("Adding…")
        case .added:
            return isEvent ? AppLocalization.string("Added to your calendar")
                : AppLocalization.string("Added to your reminders")
        case .changed: return AppLocalization.string("Added, then changed on your phone")
        case .failed: return AppLocalization.string("Couldn't add it")
        case .notAdded: return AppLocalization.string("Not added")
        case .expired: return AppLocalization.string("Expired")
        case .removing: return AppLocalization.string("Removing…")
        case .removed:
            return isEvent ? AppLocalization.string("Removed from your calendar")
                : AppLocalization.string("Removed from your reminders")
        }
    }
}

/// The Pulse screen's order: the newest morning brief with the cards it
/// brought (or its summary alone), then what's still open, then what's done
/// or swiped away.
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

        /// Its cards still open, by id, each with when it came, which a
        /// fold notes.
        var openCards: [Int: Double] {
            let open = items.filter { !$0.isCleared }.map { ($0.id, ($0.createdAt ?? .distantPast).timeIntervalSince1970) }
            return Dictionary(open, uniquingKeysWith: { first, _ in first })
        }

        /// Shown as one row: folded from its header (`folded`, its
        /// `openCards` then) until it's opened again, or with every card it
        /// brought handled, unless `opened` on this visit. Not once a card in
        /// it is open that wasn't then, or has come again since: one back
        /// from Not now or Wrong time (the host makes it new again), or put
        /// back with Undo.
        /// Nor while `focused`, the card a Pulse mark or Bring it up opened
        /// (a push opens the screen at its top), is it or one of its cards.
        func isFolded(folded: [Int: Double]?, opened: Bool, focused: Int?) -> Bool {
            if let focused, focused == id || items.contains(where: { $0.id == focused }) { return false }
            if let folded, openCards.allSatisfy({ card, at in folded[card].map { abs($0 - at) < 0.001 } ?? false }) {
                return true
            }
            return !isSummary && isHandled && !opened
        }
    }

    /// The newest brief, even when it's all handled (it folds to one row):
    /// each morning's replaces the one before. Also an older one a Pulse
    /// mark or Bring it up opened.
    var briefs: [Brief] = []
    /// What's still open, older briefs' open cards among it: each stays on
    /// the screen as a card of its own once a newer brief has come.
    var open: [PulseCard] = []
    /// Done or swiped away, newest first, with older briefs and what they
    /// brought that's handled.
    var cleared: [PulseCard] = []
    var clearedBriefs: [Brief] = []

    init() {}

    /// `keeping`: cards that stay where they are though cleared (the one a
    /// Pulse mark or Bring it up opened).
    init(cards: [PulseCard], keeping: Set<Int> = []) {
        var grouped: [String: [PulseCard]] = [:]
        // A suggestion is always a card of its own, with its Add and Undo:
        // the plugin puts one on the screen, never holds it for a brief.
        for card in cards where !card.brief.isEmpty && card.kind != "brief" && !card.isProposal {
            grouped[card.brief, default: []].append(card)
        }
        var taken: Set<Int> = []
        var newest = true
        for card in cards where card.kind == "brief" && !card.brief.isEmpty {
            var items = (grouped[card.brief] ?? []).sorted { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
            taken.insert(card.id)
            if newest || keeping.contains(card.id) {
                briefs.append(Brief(card: card, items: items))
            } else {
                // A newer brief came: this one goes to Done with what it
                // brought that's handled, and the rest stay as cards of their own.
                items = items.filter { $0.isCleared && !keeping.contains($0.id) }
                clearedBriefs.append(Brief(card: card, items: items))
            }
            taken.formUnion(items.map(\.id))
            newest = false
        }
        for card in cards where !taken.contains(card.id) {
            if card.isCleared && !keeping.contains(card.id) { cleared.append(card) } else { open.append(card) }
        }
    }

    /// The brief that brought `card`, with cards left or all handled.
    func brief(bringing card: Int) -> Brief? {
        (briefs + clearedBriefs).first { brief in brief.items.contains { $0.id == card } }
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
    /// It came at a bad time, which says nothing about whether it was
    /// worth bringing up (0.86.0): it comes back at a better time, and a
    /// card that came with a notification keeps its kind's notifications
    /// out of that part of the day.
    case wrongTime = "wrong_time"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notRelevant: return AppLocalization.string("Not relevant")
        case .alreadyKnew: return AppLocalization.string("I already knew")
        case .tooLate: return AppLocalization.string("Too late")
        case .tooOften: return AppLocalization.string("Too often")
        case .wrongTime: return AppLocalization.string("Wrong time")
        }
    }

    /// The reasons the plugin acts on: Wrong time from 0.86.0.
    static func offered(knowsHours: Bool) -> [PulseDownReason] {
        knowsHours ? allCases : allCases.filter { $0 != .wrongTime }
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
        case PulseProposal.kind: return AppLocalization.string("Suggestion")
        default: return kind
        }
    }

    /// What a Pulse turn looked at (pulse_tools labels, 0.96.0), as Why?
    /// names it; nil for a source this app doesn't know.
    static func lookedSource(_ label: String) -> String? {
        switch label {
        case "calendar": return AppLocalization.string("your calendar")
        case "phone": return AppLocalization.string("your phone")
        case "contacts": return AppLocalization.string("your contacts")
        case "maps": return AppLocalization.string("Maps")
        case "web": return AppLocalization.string("the web")
        case "location": return AppLocalization.string("where you are")
        default: return nil
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
        case "deadline": return AppLocalization.string("Deadline")
        case "next": return AppLocalization.string("Next step")
        default: return AppLocalization.string("Noticed")
        }
    }

    /// What a lesson is about: a card kind's heading, else a report item's
    /// topic, which a report card's reasons teach about (0.81.1).
    static func name(_ kind: String) -> String {
        switch kind {
        case "followup", "report", "brief", "noticed": return title(kind)
        case "deadline": return AppLocalization.string("Deadlines")
        case "next": return AppLocalization.string("Next steps")
        default: return topic(kind)
        }
    }
}

/// Something a rating taught Pulse, which the user can undo.
struct PulseLesson: Equatable, Identifiable {
    let id: Int
    let kind: String
    /// "level", "rule", "sooner", "seen", "reset" (whose kind is the
    /// scope it forgot, 0.84.0) or "part" (no notifications in a part of
    /// the day, 0.86.0).
    let what: String
    /// The level, a rule's topic, what a reset forgot, or the part of the
    /// day: "morning", "midday", "evening" or "night".
    let value: String
    /// Why it was learned ("2 thumbs down", "too often", "set").
    let cause: String
    let createdAt: Date?
    /// A reset of what was learned about a chat: the chat's title (0.84.0).
    let chatTitle: String

    init?(json: Any) {
        guard let object = json as? [String: Any], let id = PulseJSON.int(object["id"]),
              let what = object["what"] as? String else { return nil }
        self.id = id
        self.what = what
        kind = object["kind"] as? String ?? ""
        value = object["value"] as? String ?? ""
        cause = object["cause"] as? String ?? ""
        createdAt = PulseJSON.date(object["created_at"])
        chatTitle = object["chat_title"] as? String ?? ""
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
        case "reset":
            // A reset is about what learning held (its kind is the scope), or everything.
            return kind == "everything" ? AppLocalization.string("Forgot everything learned before this")
                : AppLocalization.string("Reset: \(PulsePreference.subject(scope: kind, value: value, chatTitle: chatTitle))")
        case "part":
            let name = PulseCardKind.name(kind)
            switch value {
            case "morning": return AppLocalization.string("\(name): No notifications in the morning")
            case "midday": return AppLocalization.string("\(name): No notifications in the middle of the day")
            case "evening": return AppLocalization.string("\(name): No notifications in the evening")
            case "night": return AppLocalization.string("\(name): No notifications at night")
            default: return AppLocalization.string("\(name): No notifications at that time of day")
            }
        default:
            return what
        }
    }

    /// Why it was learned, in the app's language; nil when set by hand.
    var causeText: String? {
        switch cause {
        case "", "set", "reset": return nil
        case "too often": return AppLocalization.string("You said too often")
        case "too late": return AppLocalization.string("You said too late")
        case "already knew": return AppLocalization.string("You said you already knew")
        case "not relevant": return AppLocalization.string("You said not relevant")
        case "wrong time": return AppLocalization.string("You said wrong time")
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
    /// The night (0.86.0), for Not now's choices; nil when there's none,
    /// and from an older plugin.
    var night: PulseNight?
    /// The morning brief's time in minutes into the day (0.86.0), for Not
    /// now's choices at night; nil from an older plugin.
    var briefTime: Int?

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
        night = PulseNight(json: json["night"])
        briefTime = (json["brief_time"] as? String).flatMap(PulseReportTime.minutes)
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
    /// What learning holds, strongest first (0.84.0); empty from an older plugin.
    var preferences: [PulsePreference] = []

    init() {}

    init?(json: [String: Any]) {
        guard let lessons = json["lessons"] as? [Any] else { return nil }
        self.lessons = lessons.compactMap(PulseLesson.init(json:))
        levels = PulseFeedPage.levels(json["levels"])
        preferences = (json["preferences"] as? [Any] ?? []).compactMap { PulsePreference(json: $0) }
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

    /// What Pulse learned with nothing that stands out yet.
    static var noPreferences: String {
        AppLocalization.string("Nothing stands out yet. The more you use thumbs, Do it and Done, the more Pulse learns what to bring up.")
    }
}

/// What Pulse learned about one thing (pulse_prefs, 0.84.0): one of What
/// Pulse learned's preferences, or the biggest part learning played in
/// bringing a card up (its Why?) or keeping something out.
struct PulsePreference: Equatable, Identifiable {
    /// "all" (Pulse's cards in general), "kind", "place" (a chat, an area
    /// of life or where Pulse found it), "timely" ("yes": overdue or due
    /// within a day) or "loud" (a kind's loudness from pushes acted on
    /// within the hour).
    let scope: String
    /// The kind, the place ("chat:<profile>:<chat id>", "area:work",
    /// "source:calendar"), or "yes" or "no"; "" for "all".
    let value: String
    /// How far it moves things, in log-odds: above 0, more of it (or louder).
    let effect: Double
    /// The votes behind it lately, and how useful they found it.
    let useful: Double
    let votes: Double
    /// "loud": how many pushes acted on within the hour earned it.
    let pushCount: Int
    /// A chat's title, for a chat; "" when Pulse doesn't know it.
    let chatTitle: String

    var id: String { scope + "|" + value }

    /// `chatTitle` names the chat at `chatPlace` (a card's, or a left-out
    /// item's), when the plugin didn't name one.
    init?(json: Any?, chatPlace: String = "", chatTitle: String = "") {
        guard let object = json as? [String: Any], let scope = object["scope"] as? String,
              Self.scopes.contains(scope), let effect = PulseJSON.double(object["effect"]) else { return nil }
        self.scope = scope
        value = object["value"] as? String ?? ""
        self.effect = effect
        useful = max(0, PulseJSON.double(object["useful"]) ?? 0)
        votes = max(0, PulseJSON.double(object["votes"]) ?? 0)
        pushCount = max(0, PulseJSON.int(object["pushes"]) ?? 0)
        let named = object["chat_title"] as? String ?? ""
        self.chatTitle = named.isEmpty && !chatPlace.isEmpty && value == chatPlace ? chatTitle : named
    }

    private static let scopes: Set<String> = ["all", "kind", "place", "timely", "loud"]

    /// A chat's place, as learning names it (pulse_prefs.place).
    static func chatPlace(_ profile: String, _ chatID: String) -> String {
        chatID.isEmpty ? "" : "chat:\(profile):\(chatID)"
    }

    /// Reset takes it back: all but the lean over Pulse's cards in
    /// general, which every vote makes, so only Start over forgets it.
    var canReset: Bool { scope != "all" }

    /// What it's about, as What Pulse learned and Why? name it.
    var subject: String { Self.subject(scope: scope, value: value, chatTitle: chatTitle) }

    static func subject(scope: String, value: String, chatTitle: String) -> String {
        switch scope {
        case "all":
            return AppLocalization.string("Pulse's cards in general")
        case "kind":
            return AppLocalization.string("“\(PulseCardKind.name(value))” cards")
        case "loud":
            return AppLocalization.string("How loudly “\(PulseCardKind.name(value))” cards come up")
        case "timely":
            return value == "yes" ? AppLocalization.string("What's overdue or due within a day")
                : AppLocalization.string("What isn't due within a day")
        default:
            if value.hasPrefix("area:") {
                return AppLocalization.string("Things about “\(PulsePlace.area(String(value.dropFirst(5))))”")
            }
            if value.hasPrefix("source:") {
                return AppLocalization.string("Things from “\(PulsePlace.source(String(value.dropFirst(7))))”")
            }
            return chatTitle.isEmpty ? AppLocalization.string("Things from a chat")
                : AppLocalization.string("Things from “\(chatTitle)”")
        }
    }

    /// Which way it moves things, how strongly, and the votes behind it
    /// lately (as they came, not faded as learning fades them).
    var detail: String {
        if scope == "loud" {
            let louder = AppLocalization.string("Louder")
            return pushCount > 0
                ? louder + " · " + AppLocalization.string("After \(pushCount) notifications you acted on within the hour")
                : louder
        }
        var parts = [effect > 0 ? AppLocalization.string("Brings up more") : AppLocalization.string("Brings up less"), strength]
        if votes > 0 {
            parts.append(AppLocalization.string("Useful \(Self.number(useful)) out of \(Self.number(votes)) lately"))
        }
        return parts.joined(separator: " · ")
    }

    /// How strongly it moves things, as the notifier's `pulse learned` words it.
    var strength: String {
        let size = abs(effect)
        return size >= 1.5 ? AppLocalization.string("Strong effect")
            : size >= 0.5 ? AppLocalization.string("Moderate effect") : AppLocalization.string("Slight effect")
    }

    /// Votes count Do it and Done as parts of one (opened, something sent,
    /// done), so they can be fractions.
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(AppLocalization.formattingLocale))
    }
}

/// Where a learned place points when it isn't a chat: an area of life, or
/// where Pulse found it (pulse_candidates.AREAS and SOURCES).
enum PulsePlace {
    static func area(_ area: String) -> String {
        switch area {
        case "work": AppLocalization.string("Work and career")
        case "personal": AppLocalization.string("Personal matters")
        case "health": AppLocalization.string("Health and wellbeing")
        case "home": AppLocalization.string("Home and household")
        case "money": AppLocalization.string("Money and finances")
        case "social": AppLocalization.string("Friends and family")
        case "travel": AppLocalization.string("Trips and travel")
        default: AppLocalization.string("Other matters")
        }
    }

    static func source(_ source: String) -> String {
        switch source {
        case "calendar": AppLocalization.string("Calendar")
        case "reminders": AppLocalization.string("Reminders")
        case "notes": AppLocalization.string("Hermes' notes")
        case "jobs": AppLocalization.string("Scheduled jobs")
        case "tools": AppLocalization.string("Tools")
        case "inbox": AppLocalization.string("Shortcuts inbox")
        default: AppLocalization.string("Chats")
        }
    }
}

/// Something the latest reports, or the latest look ahead (0.88.0),
/// considered and left out, and why (GET /pulse/left_out, 0.84.0): What
/// Pulse left out lists it, with Bring it up.
struct PulseLeftOut: Equatable, Identifiable {
    /// Its candidate in the journal, which Bring it up names.
    let id: Int
    /// What it's about (a report item's topic, as its card would say).
    let kind: String
    let text: String
    /// Why it stayed out: "quieted" (what the user did with things like
    /// it), "muted" (a "not relevant" rule on its chat), "off" (its kind's
    /// level), "over_limit" (the report was full), "skipped" (the model's
    /// reason, in `skip`), "not_picked", "resting" (rated down or put off,
    /// in `skip`) or "unanswered".
    let decision: String
    let skip: String
    /// What learning held against it, for one learning kept out.
    let learned: PulsePreference?
    let chatTitle: String
    let createdAt: Date?
    /// What left it out: "report", or "look_ahead" (0.88.0: the daily look
    /// two weeks ahead). Before 0.88.0 only reports did, and it's "".
    let from: String
    /// The card Bring it up made of it; nil until then.
    var cardID: Int?

    init?(json: Any) {
        guard let object = json as? [String: Any], let id = PulseJSON.int(object["id"]),
              let text = object["text"] as? String, !text.isEmpty else { return nil }
        self.id = id
        self.text = text
        kind = object["kind"] as? String ?? ""
        decision = object["decision"] as? String ?? ""
        skip = object["skip"] as? String ?? ""
        chatTitle = object["chat_title"] as? String ?? ""
        createdAt = PulseJSON.date(object["created_at"])
        from = object["from"] as? String ?? ""
        cardID = PulseJSON.int(object["card_id"])
        learned = PulsePreference(json: object["learned"],
                                  chatPlace: PulsePreference.chatPlace(object["profile"] as? String ?? "",
                                                                       object["chat_id"] as? String ?? ""),
                                  chatTitle: chatTitle)
    }

    /// Kept out by what the user taught Pulse or set, rather than by the
    /// report's own picking.
    var isKeptOut: Bool { ["quieted", "muted", "off"].contains(decision) }

    /// Left out by the daily look ahead rather than a report.
    var isLookAhead: Bool { from == "look_ahead" }

    /// Why it stayed out, in a line.
    var reason: String {
        switch decision {
        case "quieted": return AppLocalization.string("What you did with cards like this kept it out")
        case "muted": return AppLocalization.string("You said things from this chat aren't relevant")
        case "off": return AppLocalization.string("You turned this kind off")
        case "over_limit":
            return isLookAhead ? AppLocalization.string("Picked, but the look ahead was full")
                : AppLocalization.string("Picked, but the report was full")
        case "not_picked":
            return isLookAhead ? AppLocalization.string("Not picked in the look ahead")
                : AppLocalization.string("Not picked for the report")
        case "unanswered":
            return isLookAhead ? AppLocalization.string("The look ahead passed over it")
                : AppLocalization.string("The report passed over it")
        case "resting":
            return skip == "rated" ? AppLocalization.string("Resting after your thumbs down")
                : AppLocalization.string("Resting after you said Not now")
        default:
            switch skip {
            case "done": return AppLocalization.string("Already done")
            case "covered": return AppLocalization.string("Your calendar, reminders or a scheduled job covers it")
            case "raised": return AppLocalization.string("Brought up lately, and nothing changed since")
            case "rated": return AppLocalization.string("You said before that it wasn't useful")
            case "minor": return AppLocalization.string("Too minor to bring up")
            default: return AppLocalization.string("Pulse chose to leave it out")
            }
        }
    }
}

extension PulseClient {
    /// `proposals`: the screen shows suggestion cards (0.98.0); without it
    /// the plugin leaves them out and doesn't count them unseen.
    func feed(proposals: Bool = false) async throws -> PulseFeedPage {
        let response = try await request("\(Self.path)/feed" + (proposals ? "?proposals=1" : ""), "GET", nil)
        guard let page = PulseFeedPage(json: response) else { throw HermesError.invalidResponse }
        return page
    }

    /// Add on a suggestion (0.98.0): the plugin asks the phone for the
    /// change from what it kept. The suggestion, with the change's id.
    func addProposal(_ id: Int) async throws -> PulseProposal {
        try await proposal(id, "add")
    }

    /// Not now on a suggestion: it won't be added, and its card goes.
    func dismissProposal(_ id: Int) async throws -> PulseProposal {
        try await proposal(id, "dismiss")
    }

    /// Undo on an added suggestion: the plugin asks the phone to delete it.
    /// The suggestion, with the delete's id.
    func undoProposal(_ id: Int) async throws -> PulseProposal {
        try await proposal(id, "undo")
    }

    private func proposal(_ id: Int, _ action: String) async throws -> PulseProposal {
        let response = try await request("\(Self.path)/proposals/\(id)/\(action)", "POST", [:])
        guard let proposal = PulseProposal(json: response["proposal"]) else { throw HermesError.invalidResponse }
        return proposal
    }

    /// Marks these cards seen, or for nil every card the feed shows:
    /// suggestion cards only with `proposals` (0.98.0), as `feed`.
    func markSeen(_ ids: [Int]?, proposals: Bool = false) async throws {
        var body: [String: Any] = ["ids": ids.map { $0 as Any } ?? NSNull()]
        if proposals { body["proposals"] = true }
        _ = try await request("\(Self.path)/feed/seen", "POST", body)
    }

    /// The lessons the rating made, and for Wrong time, when the card
    /// comes back.
    func rate(card: Int, up: Bool, reason: PulseDownReason? = nil) async throws -> PulseRated {
        var body: [String: Any] = ["card": card, "rating": up ? "up" : "down"]
        if let reason, !up { body["reason"] = reason.rawValue }
        let response = try await request("\(Self.path)/rate", "POST", body)
        return PulseRated(lessons: (response["learned"] as? [Any] ?? []).compactMap(PulseLesson.init(json:)),
                          restUntil: PulseJSON.date(response["rest_until"]))
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

    /// Forgets what Pulse learned about one thing, or everything for nil
    /// (0.84.0): what's learned now, with the reset among the lessons,
    /// where Undo takes it back.
    func reset(_ preference: PulsePreference?) async throws -> PulseLearned {
        let body: [String: Any] = preference.map { ["scope": $0.scope, "value": $0.value] }
            ?? ["scope": "everything", "value": ""]
        let response = try await request("\(Self.path)/learned/reset", "POST", body)
        guard let learned = PulseLearned(json: response) else { throw HermesError.invalidResponse }
        return learned
    }

    /// What the latest reports left out, and why (0.84.0).
    func leftOut() async throws -> [PulseLeftOut] {
        let response = try await request("\(Self.path)/left_out", "GET", nil)
        guard let entries = response["left_out"] as? [Any] else { throw HermesError.invalidResponse }
        return entries.compactMap(PulseLeftOut.init(json:))
    }

    /// Makes a card on the Pulse screen of something a report left out: the
    /// card, or the one it already became.
    func bringUp(_ id: Int) async throws -> PulseCard {
        let response = try await request("\(Self.path)/left_out/bring_up", "POST", ["id": id])
        guard let raw = response["card"], let card = PulseCard(json: raw) else { throw HermesError.invalidResponse }
        return card
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
        guard let page = try? await pulseClient.feed(proposals: pulseSuggests), activeDashboardID == dashboard else {
            return
        }
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
    /// report's or brief's cards point there), nor a Kanban task's worker,
    /// which Hermes won't reopen as a chat (the card shows its task).
    func pulseCardHasChat(_ card: PulseCard) -> Bool {
        !card.chatID.isEmpty && card.chatID != pulseHomeChat && card.kanbanTask == nil
    }

    /// The Kanban task a card from a worker links to, when it was named.
    func pulseCardTask(_ card: PulseCard) -> String? {
        card.kanbanTask.flatMap { $0.isEmpty ? nil : $0 }
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

    /// Why? on this card: its reason, what Pulse learned played in it,
    /// which goes with the rest of what learning shows (0.84.0), or what its
    /// turn looked at first (0.96.0).
    func explainsPulseCard(_ card: PulseCard) -> Bool {
        explainsPulseCardReason(card) || (pulseExplainsLearning && card.learned != nil)
            || (pulseLooksFirst && card.lookedText != nil)
    }

    /// A follow-up's reason, or any other card's once the plugin gives each
    /// report item its candidate's reason (0.80.1). A plugin from before
    /// gave report and brief cards stock lines, not reasons.
    func explainsPulseCardReason(_ card: PulseCard) -> Bool {
        !card.why.isEmpty && (card.kind == "followup" || notifierPlugin.reports(PulseClient.cardWhyCapability))
    }

    /// What Pulse learned lists what learning holds with Reset, and What
    /// Pulse left out shows (0.84.0).
    var pulseExplainsLearning: Bool { notifierPlugin.reports(PulseClient.explainsCapability) }

    /// Pulse's turns look things up before they write (0.96.0): Settings >
    /// Pulse's switch, and Why? says what a card's turn looked at.
    var pulseLooksFirst: Bool { notifierPlugin.reports(PulseClient.lookCapability) }

    /// An event or reminder a Pulse turn would add comes as a suggestion
    /// card with Add (0.98.0): the feed brings them to an app that asks.
    var pulseSuggests: Bool { notifierPlugin.reports(PulseClient.proposalsCapability) }

    /// Pulse reads where the user is with Where you are on (0.100.0):
    /// Settings > Pulse's switch.
    var pulseReadsWhere: Bool { notifierPlugin.reports(PulseClient.whereCapability) }

    /// Settings > Pulse's Hide private reminders on the Lock Screen, and
    /// how much each Pulse push may interrupt (0.104.0).
    var pulseHidesPrivate: Bool { notifierPlugin.reports(PulseClient.privateCapability) }

    /// A thumbs down on this card asks why: a follow-up's, or a report
    /// card's once the plugin acts on its reasons (0.81.1). Before, a report
    /// card's reason changed nothing, so its thumbs down was enough.
    func asksPulseDownReason(_ card: PulseCard) -> Bool {
        card.kind == "followup" || card.isNoticed && notifierPlugin.reports(PulseClient.learnsCapability)
    }

    /// The reasons a thumbs down offers: Wrong time once the plugin picks
    /// the time (0.86.0).
    var pulseDownReasons: [PulseDownReason] {
        PulseDownReason.offered(knowsHours: notifierPlugin.reports(PulseClient.hoursCapability))
    }

    /// Settings > Calendar & phone > People says Pulse brings up the picked
    /// people's birthdays: where Pulse shows, with a plugin that does (0.88.0).
    var pulseBringsUpBirthdays: Bool {
        showsPulseSettings && notifierPlugin.reports(PulseClient.datesCapability)
    }

    /// Settings > Shortcuts inbox says Pulse keeps the deadlines it finds
    /// there, and deleting an event deletes them: where Pulse shows, with a
    /// plugin that does (0.90.0).
    var pulseKeepsInboxDeadlines: Bool {
        showsPulseSettings && notifierPlugin.reports(PulseClient.inboxCapability)
    }

    /// The same for the inbox Settings > Shortcuts inbox shows (`scope`):
    /// only the active dashboard's, the one whose plugin answered, and only
    /// Pulse's own profile's, the one inbox Pulse reads.
    func pulseKeepsDeadlines(from scope: ShortcutInboxScope?) -> Bool {
        guard pulseKeepsInboxDeadlines, let scope, scope.dashboardID == activeDashboardID else { return false }
        return profilesMatch(scope.profile, Self.pulseHomeProfile)
    }

    /// Opens the chat a card came from.
    /// It opens at the message the card came from, as an artifact's Show
    /// in chat does, whatever the chat would otherwise land on.
    func openPulseCardChat(_ card: PulseCard) {
        guard pulseCardHasChat(card) else { return }
        pendingArtifactReveal = card.messageID.map { ArtifactReveal(messageID: $0, opening: card.chatID) }
        openAppLink(.session(id: card.chatID, profile: card.profile.isEmpty ? Self.pulseHomeProfile : card.profile))
    }

    /// Opens the Kanban task a card from its worker names, in Tasks.
    func openPulseCardTask(_ card: PulseCard) {
        guard let task = pulseCardTask(card) else { return }
        kanbanTaskOpenRequest = KanbanTaskOpenRequest(taskID: task, dashboardID: activeDashboardID)
    }

    /// Do it: opens the chat the card came from with the reminder in its
    /// composer, ready to send. A card from no chat (a report item from the
    /// calendar, reminders or the Shortcuts inbox) or from a Kanban task's
    /// worker gets a new chat in Pulse's
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
    /// loudly, and a kind's level is the loudest it gets (0.81.1).
    static let learnsCapability = "pulse_learns"
    /// Pulse shows what it learned: a card's part learning played, what
    /// learning holds with reset, and what the reports left out with Bring
    /// it up (0.84.0).
    static let explainsCapability = "pulse_explains"
    /// Pulse picks the time: the night in Settings > Pulse, waits while the
    /// user is busy, and a thumbs down's Wrong time (0.86.0).
    static let hoursCapability = "pulse_hours"
    /// Pulse brings up birthdays and anniversaries every year, the picked
    /// people's included, and looks two weeks ahead once a day; What Pulse
    /// left out says what the look ahead left out (0.88.0).
    static let datesCapability = "pulse_dates"
    /// Pulse memory keeps deadlines from the Shortcuts inbox, like a trial
    /// ending or a bill due: Settings > Pulse's switch, What Pulse
    /// remembers' Deadlines, and deadline cards with a level of their own
    /// in What Pulse learned (0.90.0).
    static let inboxCapability = "pulse_inbox"
    /// Pulse's report, brief and follow-up turns look things up before they
    /// write (calendar, phone and contacts reads, Maps between named places,
    /// web search on a follow-up), switched in Settings > Pulse, and each
    /// card says what its turn looked at (0.96.0).
    static let lookCapability = "pulse_look"
    /// An event or reminder a Pulse turn would add is a suggestion on a card
    /// of its own, with Add, Not now and Undo (0.98.0).
    static let proposalsCapability = "pulse_proposals"
    /// Pulse reads where the user is with Where you are on: Settings >
    /// Pulse's switch, a remembered item's place in What Pulse remembers,
    /// and "where you are" in what a card's turn looked at (0.100.0).
    static let whereCapability = "pulse_where"
    /// Hide private reminders on the Lock Screen: Settings > Pulse's switch,
    /// and a private push's body in the app's language (0.104.0).
    static let privateCapability = "pulse_private"
}

/// What Not now puts a card off until, as the plugin names it. Wrong time
/// puts a card away until a time of the plugin's, told the same way.
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
    /// to give. The plugin gives three hours, by 23:00 and by the night's
    /// start (0.86.0), and never under half an hour, so from half an hour
    /// before then it makes it tomorrow. At night it gives ten minutes
    /// before the next morning brief (`brief`, minutes into the day; 07:00,
    /// the brief's own default, when the feed doesn't say), so once today's
    /// brief has gone, or is under forty minutes away, it's tomorrow's, as
    /// Tomorrow is. It would say tomorrow twice.
    static func choices(now: Date = Date(), night: PulseNight? = nil, brief: Int? = nil,
                        calendar: Calendar = .current) -> [PulseRest] {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        var end = 23 * 60
        if let night {
            if night.contains(minute) {
                let today = (brief ?? 7 * 60) - 10 - minute >= 30
                return today ? allCases : [.tomorrow, .nextWeek]
            }
            if night.start > minute { end = min(end, night.start) }
        }
        return minute >= end - 30 ? [.tomorrow, .nextWeek] : allCases
    }

    /// The choice a time the plugin set comes to, for the Undo bar (Not
    /// now's or Wrong time's): later today, tomorrow, or next week (the
    /// brief's day a week on).
    static func returning(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> PulseRest {
        switch Self.days(to: date, now: now, calendar: calendar) {
        case ...0: .laterToday
        case 1: .tomorrow
        default: .nextWeek
        }
    }

    /// When a card put off, by Not now or Wrong time, comes back, as its
    /// cleared row says it: later today, tomorrow, a weekday this week, or
    /// next week.
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

/// The plugin's answer to a rating.
struct PulseRated: Equatable {
    let lessons: [PulseLesson]
    /// Wrong time put the card away until then (0.86.0).
    let restUntil: Date?
}
