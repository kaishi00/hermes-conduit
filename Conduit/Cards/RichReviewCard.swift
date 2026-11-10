//
//  RichReviewCard.swift
//  Conduit
//
//  A review card (plugin 0.147+): options Hermes drew for the user to look
//  at and mark, when a choice is easier to see than to describe. One
//  decision is a quick pick the user taps in the chat; several open the
//  review sheet, where each decision is marked Approve, Change or Skip with
//  a note, and Send goes. The card carries labels and ids only: the pages
//  the options open are kept on the host, round by round, and read from the
//  plugin's GET /boards/reviews when the card is drawn (RichReviewLoader).
//  The marks go as a tap (POST /boards/taps, action "review"), then the
//  user's message about them, as a card's tap button does. In Bot Mode the
//  card names the workstream that made the options (`for`), and the plugin
//  sends the marks on to it, every round (Eric, 2026-11-08).
//

import Foundation

struct RichReview: Equatable, Hashable {
    enum Layout: String {
        case side, `switch`, beforeAfter = "before_after"
    }

    /// The review on the host: rv- and 16 hex digits.
    let id: String
    let round: Int
    /// The workstream it belongs to, like W3.
    let forRef: String?
    let decisions: [RichReviewDecision]
    /// Decisions an earlier round settled.
    let settled: [RichReviewSettled]

    init?(json: Any?) {
        guard let json = json as? [String: Any], let id = json["id"] as? String, RichCardSchema.isReviewID(id) else {
            return nil
        }
        let decisions = (json["decisions"] as? [[String: Any]] ?? []).compactMap(RichReviewDecision.init(json:))
        guard !decisions.isEmpty else { return nil }
        self.id = id
        round = (json["round"] as? NSNumber)?.intValue ?? 1
        forRef = (json["for"] as? String).flatMap { RichCardSchema.isWorkRef($0) ? $0 : nil }
        self.decisions = decisions
        settled = (json["settled"] as? [[String: Any]] ?? []).compactMap(RichReviewSettled.init(json:))
    }

    /// One decision is picked in the chat; several open the review sheet.
    var isQuickPick: Bool { decisions.count == 1 }

    /// Whether any option opens a page the host keeps (pictures don't).
    var hasPages: Bool { decisions.contains { $0.options.contains { $0.kind == .page } } }
}

struct RichReviewDecision: Equatable, Hashable, Identifiable {
    let id: String
    let title: String
    let text: String?
    let layout: RichReview.Layout
    let options: [RichReviewOption]

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let title = json["title"] as? String else { return nil }
        // One option per id: a picker tells them apart by it.
        var seen: Set<String> = []
        let options = (json["options"] as? [[String: Any]] ?? []).compactMap(RichReviewOption.init(json:))
            .filter { seen.insert($0.id).inserted }
        guard options.count >= 2 else { return nil }
        self.id = id
        self.title = title
        text = json["text"] as? String
        layout = (json["layout"] as? String).flatMap(RichReview.Layout.init(rawValue:)) ?? .side
        self.options = options
    }

    func option(_ id: String?) -> RichReviewOption? {
        options.first { $0.id == id }
    }
}

struct RichReviewOption: Equatable, Hashable, Identifiable {
    enum Kind: String { case page, image }

    let id: String
    let label: String
    let text: String?
    let recommended: Bool
    let kind: Kind
    /// A picture's https link.
    let url: URL?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let label = json["label"] as? String,
              let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        let url = (json["url"] as? String).flatMap(URL.init(string:))
        if kind == .image, url?.scheme?.lowercased() != "https" { return nil }
        self.id = id
        self.label = label
        text = json["text"] as? String
        recommended = json["recommended"] as? Bool ?? false
        self.kind = kind
        self.url = kind == .image ? url : nil
    }

    /// "B · Line", as the user's message names it.
    var name: String { "\(id) · \(label)" }
}

struct RichReviewSettled: Equatable, Hashable {
    let title: String
    let approved: Bool
    let choice: String?

    init?(json: [String: Any]) {
        guard let title = json["title"] as? String, let mark = json["mark"] as? String,
              mark == "approve" || mark == "skip" else { return nil }
        self.title = title
        approved = mark == "approve"
        choice = json["choice"] as? String
    }
}

/// The user's mark on one decision.
struct RichReviewMark: Equatable, Hashable {
    enum Kind: String, CaseIterable { case approve, change, skip }

    var kind: Kind
    /// The option approved, or the one to change from.
    var option: String?
    var note: String = ""

    /// Whether it can be sent: an approval names its option.
    var isComplete: Bool { kind != .approve || option != nil }

    var json: [String: Any] {
        var json: [String: Any] = ["mark": kind.rawValue]
        if kind != .skip, let option { json["option"] = option }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { json["note"] = RichReviewMark.capped(note) }
        return json
    }

    /// The plugin's cap on a note (card_actions cuts a note at MAX_VALUE_CHARS).
    static let maxNote = 2_000

    /// A note as the host keeps it, counted as it counts: in Unicode scalars.
    static func capped(_ note: String) -> String {
        guard note.unicodeScalars.count > maxNote else { return note }
        return String(String.UnicodeScalarView(note.unicodeScalars.prefix(maxNote)))
    }
}

/// A round as the host keeps it: the pages its options open, by decision
/// and option id ("d1/A"), how many rounds the review has, and the marks
/// sent on it.
struct RichReviewRound: Equatable {
    let round: Int
    let rounds: Int
    let pages: [String: String]
    /// What its pages come to, in bytes.
    let pageBytes: Int
    let marks: [String: RichReviewMark]
    let note: String?
    let decisions: [RichReviewDecision]

    init?(json: [String: Any]) {
        guard let round = (json["round"] as? NSNumber)?.intValue,
              let rounds = (json["rounds"] as? NSNumber)?.intValue else { return nil }
        self.round = round
        self.rounds = rounds
        // Host text, bounded as every other page Conduit previews: a page
        // over the preview's 4 MB ceiling isn't drawn, nor pages past the
        // round's own budget (the plugin keeps a round under 6 MB).
        var pages: [String: String] = [:]
        var bytes = 0
        for (key, value) in (json["pages"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let page = value as? String else { continue }
            let size = page.utf8.count
            guard size <= HTMLPreviewPage.maximumDocumentBytes, bytes + size <= Self.maxPageBytes else { continue }
            bytes += size
            pages[key] = page
        }
        self.pages = pages
        pageBytes = bytes
        // One decision per id, as the card has them.
        var seen: Set<String> = []
        decisions = (json["decisions"] as? [[String: Any]] ?? []).compactMap(RichReviewDecision.init(json:))
            .filter { seen.insert($0.id).inserted }
        let given = json["marks"] as? [String: Any]
        var marks: [String: RichReviewMark] = [:]
        for entry in given?["decisions"] as? [[String: Any]] ?? [] {
            guard let decision = entry["decision"] as? String,
                  let kind = (entry["mark"] as? String).flatMap(RichReviewMark.Kind.init(rawValue:)) else { continue }
            marks[decision] = RichReviewMark(kind: kind, option: entry["option"] as? String,
                                             note: RichReviewMark.capped(entry["note"] as? String ?? ""))
        }
        self.marks = marks
        note = (given?["note"] as? String).map(RichReviewMark.capped)
    }

    /// The most page text a round keeps.
    static let maxPageBytes = 8 * 1024 * 1024

    var wasSent: Bool { !marks.isEmpty || note != nil }

    func page(decision: String, option: String) -> String? {
        pages["\(decision)/\(option)"]
    }
}

enum RichReviewTap {
    static let action = "review"

    /// What the marks' tap carries: the round's marks, the round's note,
    /// and the words the message starts with, so the plugin hears the
    /// message in the user's language.
    static func body(card: RichCard, review: RichReview, marks: [String: RichReviewMark], note: String,
                     label: String) -> [String: Any] {
        let entries: [[String: Any]] = review.decisions.compactMap { decision in
            guard let mark = marks[decision.id], mark.isComplete else { return nil }
            var json = mark.json
            json["decision"] = decision.id
            return json
        }
        var given: [String: Any] = ["round": review.round, "marks": entries, "label": label]
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { given["note"] = RichReviewMark.capped(note) }
        let cardJSON = card.normalizedJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        return ["card": cardJSON, "action": action, "review": given]
    }

    /// The user's message about the marks: "Picked B · Line" for a quick
    /// pick, "Sent review · Recipe app home" otherwise, kept a plain message.
    static func message(label: String, review: RichReview, marks: [String: RichReviewMark], title: String?) -> String {
        if review.isQuickPick, let decision = review.decisions.first, let mark = marks[decision.id],
           mark.kind == .approve, let option = decision.option(mark.option) {
            let text = "\(label) \(option.name)"
            return RichCardSchema.isPlainMessage(text) ? text : label
        }
        return RichCardActionContext.message(label: label, title: title)
    }
}

/// Reads a review's round from the host (GET /boards/reviews), kept for
/// the launch: a card drawn again shows its pages without asking again.
@MainActor
final class RichReviewLoader {
    static let shared = RichReviewLoader()

    static let capability = "review-cards"
    static let path = "/api/plugins/conduit_push/boards/reviews"
    private static let keptRounds = 12
    /// The most page text the kept rounds hold together.
    static let keptPageBytes = 24 * 1024 * 1024

    /// The connected Hermes' answer for a path; nil while none is
    /// connected (AppState sets it).
    var read: (@MainActor (String) async throws -> [String: Any])?
    private var rounds: [String: RichReviewRound] = [:]
    private var order: [String] = []

    enum LoadError: Error {
        case notConnected, gone
    }

    static func readPath(id: String, round: Int?) -> String {
        var components = URLComponents()
        var items = [URLQueryItem(name: "id", value: id)]
        if let round { items.append(URLQueryItem(name: "round", value: String(round))) }
        components.queryItems = items
        return path + "?" + (components.percentEncodedQuery ?? "")
    }

    /// A round; `fresh` asks again (its marks may have gone since).
    func round(_ id: String, _ number: Int, fresh: Bool = false) async throws -> RichReviewRound {
        let key = "\(id)#\(number)"
        if !fresh, let kept = rounds[key] { return kept }
        guard RichCardSchema.isReviewID(id), let read else { throw LoadError.notConnected }
        let answer = try await read(Self.readPath(id: id, round: number))
        guard let round = Self.checkedRound(answer["review"], id: id) else { throw LoadError.gone }
        if rounds[key] == nil { order.append(key) }
        rounds[key] = round
        // The newest rounds stay, a dozen at most and their pages within
        // the budget; the one just read always does.
        while order.count > 1,
              order.count > Self.keptRounds || order.compactMap({ rounds[$0]?.pageBytes }).reduce(0, +) > Self.keptPageBytes {
            rounds[order.removeFirst()] = nil
        }
        return round
    }

    /// A round as the host answered it, its decisions checked as a review
    /// card's are (the schema's caps on decisions, options and their text);
    /// nil when it isn't one.
    static func checkedRound(_ value: Any?, id: String) -> RichReviewRound? {
        guard var json = value as? [String: Any] else { return nil }
        if let decisions = json["decisions"] {
            json["decisions"] = RichCardSchema.bundled?.normalizeReviewDecisions(decisions, id: id) ?? []
        }
        return RichReviewRound(json: json)
    }

    /// A round already read this launch, without asking the host.
    func kept(_ id: String, _ number: Int) -> RichReviewRound? {
        rounds["\(id)#\(number)"]
    }

    /// Forgets a round, after the user sent marks on it.
    func forget(_ id: String, _ number: Int) {
        let key = "\(id)#\(number)"
        rounds[key] = nil
        order.removeAll { $0 == key }
    }
}
