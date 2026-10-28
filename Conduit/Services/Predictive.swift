//
//  Predictive.swift
//  Conduit
//
//  Settings > Chat > Predictive: three opt-in guesses Hermes makes about
//  the open chat, all off by default and kept on this device.
//
//  - Suggested replies: after a reply settles, the messages the user will
//    most likely send next, best first. Tap sends, long-press edits.
//  - While I pause: when typing stops for a moment, continuations of the
//    draft and whole messages the user probably means.
//  - Hermes follows up: while the chat is on screen and nobody writes,
//    Hermes is asked whether it wants a turn. A yes sends one hidden turn
//    (Hermes' `display_kind: "hidden"`), at most one per message the user
//    sends.
//
//  The plugin's `POST /predict` (predict.py, plugin 0.80+) answers each one
//  with a fork of the live chat that can't use tools and saves nothing, and
//  answers only this device: `/btw`'s answers go to every client, and Hermes
//  Desktop shows them as notes. Conduit measures every duration it sends;
//  the plugin writes them out, so the model never calculates.
//

import Foundation

enum Predictive {
    static let capability = "predict"
    /// The plugin version that first serves it, named in Settings.
    static let minimumPlugin = "0.80"
    static let path = "/api/plugins/conduit_push/predict"

    // MARK: - Settings (device-only, all off by default)

    static let repliesKey = "conduit.predictive.replies"
    static let replyCountKey = "conduit.predictive.replyCount"
    static let pauseKey = "conduit.predictive.pause"
    static let pauseDelayKey = "conduit.predictive.pauseDelay"
    static let followUpKey = "conduit.predictive.followUp"
    static let followUpDelayKey = "conduit.predictive.followUpDelay"
    static let modelKey = "conduit.predictive.model"

    static let replyCounts = [1, 3, 5]
    static let defaultReplyCount = 3
    /// Seconds of no typing before the draft is asked about.
    static let pauseDelays: [Double] = [0.8, 1.2, 2, 3, 5]
    static let defaultPauseDelay = 1.2
    /// Seconds on screen without writing before the first follow-up check.
    static let followUpDelays = [30, 60, 120, 300]
    static let defaultFollowUpDelay = 60

    /// Which model answers: the chat's own (warm cache), or the profile's
    /// `auxiliary.conduit_predict` on the host.
    enum Model: String, CaseIterable {
        case chat
        case fast
    }

    static func repliesEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: repliesKey) as? Bool ?? false
    }

    static func pauseEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: pauseKey) as? Bool ?? false
    }

    static func followUpEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: followUpKey) as? Bool ?? false
    }

    static func replyCount(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: replyCountKey) as? Int ?? defaultReplyCount
        return replyCounts.contains(stored) ? stored : defaultReplyCount
    }

    static func pauseDelay(_ defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.object(forKey: pauseDelayKey) as? Double ?? defaultPauseDelay
        return pauseDelays.contains(stored) ? stored : defaultPauseDelay
    }

    static func followUpDelay(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: followUpDelayKey) as? Int ?? defaultFollowUpDelay
        return followUpDelays.contains(stored) ? stored : defaultFollowUpDelay
    }

    static func model(_ defaults: UserDefaults = .standard) -> Model {
        (defaults.string(forKey: modelKey)).flatMap(Model.init(rawValue:)) ?? .fast
    }

    // MARK: - Limits

    /// A draft shorter than this says too little to guess from.
    static let minimumDraftCharacters = 3
    /// Follow-up checks for one reply; "not again" ends them sooner.
    static let maximumChecks = 4
    /// The plugin holds "ask again" to this window too (predict.py).
    static let askAgainRange: ClosedRange<Int> = 30...900
    /// How long each kind of answer is waited for. A draft's guesses are
    /// only worth having while the pause lasts.
    static let repliesWait: TimeInterval = 20
    static let draftWait: TimeInterval = 4
    static let turnWait: TimeInterval = 30
    /// Taps on a row that just appeared are ignored this long, so a finger
    /// already on its way can't send.
    static let tapGuard: TimeInterval = 0.4

    // MARK: - Requests and answers

    enum Kind: String {
        case replies
        case draft
        case turn
    }

    /// One guess, best first in a list, with Hermes' probability (0…1).
    struct Guess: Equatable, Hashable {
        let text: String
        let p: Double
    }

    /// What the host says about predictions (`GET /predict`).
    struct HostStatus: Equatable {
        let fastModel: String?
        let today: Int
    }

    /// What a follow-up check decided.
    struct TurnAnswer: Equatable {
        let takeTurn: Bool
        let why: String
        /// Seconds until the next check; nil: not again for this reply.
        let askAgain: Int?
        /// The hidden turn's text, when Hermes wants one.
        let nudge: String?
    }

    /// What Conduit measured for a follow-up check, in whole seconds.
    struct TurnFacts: Equatable {
        let lastReplySeconds: Int
        let onScreenSeconds: Int
        let check: Int
        let localTime: String?
    }

    static func body(
        kind: Kind,
        sessionID: String,
        count: Int,
        draft: String? = nil,
        facts: TurnFacts? = nil,
        language: String,
        model: Model,
        wait: TimeInterval
    ) -> [String: Any] {
        var body: [String: Any] = [
            "session_id": sessionID,
            "kind": kind.rawValue,
            "count": min(max(count, 1), 5),
            "language": language,
            "model": model.rawValue,
            "wait_s": wait,
        ]
        if let draft { body["draft"] = String(draft.prefix(2_000)) }
        if let facts {
            var measured: [String: Any] = [
                "last_reply_s": max(0, facts.lastReplySeconds),
                "on_screen_s": max(0, facts.onScreenSeconds),
                "check": min(max(facts.check, 1), maximumChecks),
                "max_checks": maximumChecks,
            ]
            if let localTime = facts.localTime { measured["local_time"] = localTime }
            body["facts"] = measured
        }
        return body
    }

    /// A guess longer than this is dropped, not shortened: a chip that sends
    /// shows its whole text, so one this long would fill the screen.
    static let maxGuessLength = 200

    /// A list of guesses from the route's answer, best first.
    static func guesses(_ value: Any?) -> [Guess] {
        guard let items = value as? [[String: Any]] else { return [] }
        let found = items.compactMap { item -> Guess? in
            guard let text = item["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= maxGuessLength else { return nil }
            let p = (item["p"] as? NSNumber)?.doubleValue ?? 0.5
            return Guess(text: text, p: min(1, max(0, p)))
        }
        // Ties keep the host's order.
        return found.enumerated()
            .sorted { $0.element.p != $1.element.p ? $0.element.p > $1.element.p : $0.offset < $1.offset }
            .map(\.element)
    }

    static func turnAnswer(_ answer: [String: Any]) -> TurnAnswer {
        let takeTurn = answer["take_turn"] as? Bool ?? false
        let nudge = (answer["nudge"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let again = (answer["ask_again_in_seconds"] as? NSNumber)?.intValue
        return TurnAnswer(
            takeTurn: takeTurn && nudge != nil,
            why: answer["why"] as? String ?? "",
            askAgain: again.map { min(max($0, askAgainRange.lowerBound), askAgainRange.upperBound) },
            nudge: nudge
        )
    }

    /// What is left of `continuation` to offer now: all of it while the
    /// draft is the one it was asked for, the rest when the user has since
    /// typed its start, nothing once the draft went elsewhere.
    static func remainder(of continuation: String, askedFor answered: String, draft current: String) -> String? {
        guard current.hasPrefix(answered) else { return nil }
        let typed = String(current.dropFirst(answered.count))
        guard continuation.hasPrefix(typed) else { return nil }
        let rest = String(continuation.dropFirst(typed.count))
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rest
    }

    /// The draft with a continuation put after it. A continuation that
    /// starts a new word brings its own space.
    static func inserting(_ continuation: String, into draft: String) -> String {
        draft + continuation
    }

    /// "Sunday 09:14", in English for the model: the day and the time the
    /// user sees, so it can tell morning from night.
    static func localTime(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE HH:mm"
        return formatter.string(from: date)
    }

    /// When a message's timestamp says it was written, if it says.
    static func date(fromTimestamp timestamp: String) -> Date? {
        // The chat's own reading: ISO dates and epoch seconds alike.
        MessageTimestampFormatter.date(from: timestamp)
    }
}

/// What the suggestion row above the composer shows. Kept apart from
/// AppState so a new guess redraws the row, not the chat.
@MainActor
final class PredictiveStore: ObservableObject {
    /// The chat and the reply the guesses belong to.
    struct Anchor: Equatable, Hashable {
        let sessionID: String
        let messageID: String
    }

    /// Suggested replies for the anchor's reply.
    @Published private(set) var replies: [Predictive.Guess] = []
    @Published private(set) var anchor: Anchor?
    /// Guesses for a paused draft: continuations and whole messages.
    @Published private(set) var draftNext: [Predictive.Guess] = []
    @Published private(set) var draftReplies: [Predictive.Guess] = []
    /// The draft those guesses were asked for.
    @Published private(set) var answeredDraft: String?
    /// The composer's draft as it stands.
    @Published private(set) var draft = ""
    /// Typing since the last guesses: the row folds to its ✦ button.
    @Published private(set) var isFolded = false
    /// The row hidden in these chats with "Hide for this chat".
    @Published private(set) var hiddenSessions: Set<String> = []
    /// When the row last appeared, for the tap guard.
    private(set) var shownAt = Date.distantPast
    /// Replies Hermes wrote on its own, by message id, with its reason.
    @Published private(set) var followUpReasons: [String: String] = [:]

    func showReplies(_ guesses: [Predictive.Guess], for anchor: Anchor) {
        // New chips, new guard: a finger already on its way to the old
        // ones doesn't land on these.
        if replies != guesses || self.anchor != anchor { shownAt = Date() }
        self.anchor = anchor
        replies = guesses
        isFolded = false
    }

    /// The chat and reply on screen now, or nil while guesses can't show
    /// (a turn running, the list or a room over the chat, the app away).
    @Published private(set) var screen: Anchor?

    func setScreen(_ anchor: Anchor?) {
        guard anchor != screen else { return }
        if let anchor {
            if anchor.sessionID != screen?.sessionID, anchor.sessionID != self.anchor?.sessionID {
                answeredDraft = nil
                draftNext = []
                draftReplies = []
            }
            if anchor != self.anchor {
                replies = []
                self.anchor = nil
            }
            shownAt = Date()
        }
        screen = anchor
    }

    /// Whether the row has anything to show for the chat on screen.
    var isShowing: Bool {
        guard let screen, !hiddenSessions.contains(screen.sessionID) else { return false }
        return !currentReplies.isEmpty || !currentNext.isEmpty
    }

    func showDraftGuesses(next: [Predictive.Guess], replies guesses: [Predictive.Guess], for draft: String) {
        // The user may have typed on meanwhile: what's left still counts.
        guard self.draft.hasPrefix(draft) else { return }
        answeredDraft = draft
        draftNext = next
        draftReplies = guesses
        // Shown while the user is still paused on it; typing on meanwhile
        // keeps them behind the ✦ button.
        guard self.draft == draft else { return }
        isFolded = false
        shownAt = Date()
    }

    /// The composer's text changed. Typing folds the row; an emptied
    /// composer brings back the suggested replies.
    func draftChanged(_ text: String) {
        guard text != draft else { return }
        draft = text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            answeredDraft = nil
            draftNext = []
            draftReplies = []
            isFolded = false
        } else {
            isFolded = true
        }
    }

    func unfold() {
        isFolded = false
        shownAt = Date()
    }

    /// A new turn, another chat, or a switch turned off.
    func clear() {
        screen = nil
        replies = []
        anchor = nil
        answeredDraft = nil
        draftNext = []
        draftReplies = []
        isFolded = false
    }

    func hide(sessionID: String) {
        hiddenSessions.insert(sessionID)
    }

    func noteFollowUp(messageID: String, why: String) {
        followUpReasons[messageID] = why
    }

    func forgetFollowUps() {
        followUpReasons = [:]
        hiddenSessions = []
    }

    /// Sign-out: the guesses, the draft they read and the follow-ups.
    func forgetAll() {
        clear()
        forgetFollowUps()
        draft = ""
    }

    /// Whether a tap now would be on a row that only just appeared.
    func tapIsGuarded(now: Date = Date()) -> Bool {
        now.timeIntervalSince(shownAt) < Predictive.tapGuard
    }

    /// The continuations to offer for the draft as it stands now.
    var currentNext: [Predictive.Guess] {
        guard let answeredDraft else { return [] }
        return draftNext.compactMap { guess in
            Predictive.remainder(of: guess.text, askedFor: answeredDraft, draft: draft)
                .map { Predictive.Guess(text: $0, p: guess.p) }
        }
    }

    /// The whole messages to offer now: a draft's while the user is still
    /// writing it, else the suggested replies when the composer is empty.
    var currentReplies: [Predictive.Guess] {
        if let answeredDraft, draft.hasPrefix(answeredDraft), !draft.isEmpty { return draftReplies }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? replies : []
    }
}

/// A guess the suggestion row hands the composer: sent as is, put in to
/// edit, or put after the draft it continues.
struct PredictiveComposerRequest: Equatable {
    enum Action: Equatable {
        case send
        case edit
        case insert
    }

    let id = UUID()
    let action: Action
    let text: String
    /// The draft the guess was offered for: an insert into a draft that
    /// has changed since does nothing.
    let draft: String
    /// The chat the guess was offered in: a composer showing another one
    /// drops it.
    let sessionID: String
    let draftKey: ComposerDraftKey
}

/// Follow-up checks for the reply on screen.
struct PredictiveFollowUpState {
    /// The reply the checks are for; another reply starts over.
    var anchor: PredictiveStore.Anchor?
    var checks = 0
    /// Hermes said "not again", the checks ran out, or one failed.
    var stopped = false
    /// When the next check is due, as Hermes asked; nil: the first wait.
    var nextCheck: Date?
    /// Since when the chat has been on screen with nobody writing.
    var idleSince = Date()
    /// The user message (by chat and id) a follow-up turn was already
    /// spent on: one per message the user sends.
    var spentOn: String?
}
