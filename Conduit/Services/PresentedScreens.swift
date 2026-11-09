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
    /// Run work's ask (plugin 0.137+): your agent asks before it starts work
    /// for the room, or sends to it, answered Start, Change it or Don't start.
    let work: Bool

    init(id: String, name: String, work: Bool = false) {
        self.id = id
        self.name = name
        self.work = work
    }

    /// Any room the host names makes it a room's ask, even one without an id:
    /// never an ordinary confirmation whose Edit opens the room's hidden chat.
    init?(json: Any?) {
        guard let entry = json as? [String: Any] else { return nil }
        let id = (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(id: id, name: String(name.prefix(80)), work: entry["work"] as? Bool == true)
    }
}

/// The Link a Link's ask comes from (asks between linked agents, C7): a
/// linked person's Hermes asks yours, and what the plugin's rule would answer
/// waits for you. Only an answer there is to Share: a question has none, so
/// it's answered with Say instead or Don't share.
struct PresentedLink: Equatable {
    let id: String
    let name: String
    /// Whether there's an answer to Share (the host refuses a confirm
    /// otherwise).
    let share: Bool

    init(id: String, name: String, share: Bool) {
        self.id = id
        self.name = name
        self.share = share
    }

    /// Any Link the host names makes it a Link's ask, even one that can't be
    /// read; one that doesn't say there's something to share has nothing
    /// to Share.
    init?(json: Any?) {
        guard let json, !(json is NSNull) else { return nil }
        let entry = json as? [String: Any] ?? [:]
        let id = (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(id: id, name: String(name.prefix(80)), share: entry["share"] as? Bool == true)
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
    /// A Link's ask: a linked person's Hermes asks yours. The preview is the
    /// answer to Share, or their question when there's none.
    let link: PresentedLink?

    init(id: String, title: String, preview: String, actionLabel: String,
         spokenYes: [String] = [], sessionID: String? = nil, expiresAt: Date? = nil, maps: PresentedMapsTarget? = nil,
         room: PresentedRoom? = nil, link: PresentedLink? = nil) {
        self.id = id
        self.title = title
        self.preview = preview
        self.actionLabel = actionLabel
        self.spokenYes = spokenYes
        self.sessionID = sessionID
        self.expiresAt = expiresAt
        self.maps = maps
        self.room = room
        self.link = link
    }

    /// A room's or a Link's ask: answered with Share, Say instead or Don't
    /// share, never Edit in a chat.
    var isAsk: Bool { room != nil || link != nil }

    /// Whether it has something to confirm: a Link's question doesn't.
    var canConfirm: Bool { link?.share ?? true }

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
            room: PresentedRoom(json: entry["room"]),
            link: PresentedLink(json: entry["link"])
        )
    }

    func isExpired(at now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// Whether the user's own words confirm it: a plain yes, or one of the
    /// phrases Hermes gave said on its own ("send it", "yes, send it").
    /// Never a question, never a phrase buried in a longer request.
    /// `bareYes` false takes only its phrases: Classic voice never says a
    /// Link's ask aloud, so a plain yes may have meant something else.
    func isConfirmed(by words: String, bareYes: Bool = true) -> Bool {
        // Nothing to Share: no yes confirms it.
        guard canConfirm else { return false }
        if bareYes, VoiceCallDecisionOutcome.isYes(words) { return true }
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

    /// Whether the user's own words turn it down: an answer led by a no, a
    /// cancel, a don't or a wait, as the handset reads one in any shipped
    /// language ("no", "don't send it", "not now", "我不想发"), or a
    /// refusal said with its verb ("decline it"). Never a question, a yes
    /// with more words ("yes, no problem"), not knowing, or a no somewhere
    /// inside other words ("I have no problem with that"): the model's
    /// judgment, or something it read, can't answer for the user, and
    /// anything unclear leaves the panel for their tap.
    func isDeclined(by words: String) -> Bool {
        // A question ("can't we wait?") asks; it doesn't answer.
        guard !words.contains("?"), !words.contains("？"), !VoiceCallDecisionOutcome.isYes(words) else { return false }
        // A no in its own clause before a refusal ("不，拒绝", "いや、断る")
        // isn't the refusal's not.
        if let rest = Self.afterCJKNo(words), isDeclined(by: rest) { return true }
        // A Chinese or Japanese question ends a clause in its marker
        // ("取消吗", "取消吗，谢谢").
        let clauseEnds = words.components(separatedBy: CharacterSet(charactersIn: ",;:—–，；：、.!。！\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
        guard !clauseEnds.contains(where: { clause in Self.cjkQuestionEnds.contains { clause.hasSuffix($0) } }),
              !Self.cjkAskPairs.contains(where: { words.contains($0) }) else { return false }
        // Not knowing isn't a no ("no idea", "not sure").
        let folded = words.lowercased().replacingOccurrences(of: "’", with: "'")
        guard !Self.unsure.contains(where: { folded.contains($0) }) else { return false }
        let said = Self.words(in: words)
        guard !Self.unsureWords.contains(where: { Self.range(of: $0, in: said) != nil }),
              !Self.cjkUnsure.contains(where: { words.contains($0) }) else { return false }
        // Asked not to refuse ("don't decline it", "don't cancel the
        // email", "不要取消") isn't a no.
        guard !VoiceThreadRouting.negatesRefusalVerb(words), !Self.negatesActionNo(said, in: words),
              !Self.cjkNegatedCancels.contains(where: { words.contains($0) }) else { return false }
        switch VoiceThreadRouting.heldRequestAnswer(words) {
        // A no with a change after it ("no, make it for Alex", "never mind,
        // make it Wednesday") asks for the change, which the panel's edit
        // takes. A no on its own, or one said with its action ("don't
        // share", "cancel the email"), declines.
        case .no(let change):
            // A yes after the no ("no, send it", "no, go ahead") contradicts
            // it: the tap decides.
            guard !Self.laterClauseSaysYes(words) else { return false }
            return change == nil
                || (Self.isCJKSendRefusal(words) && Self.isOneClause(words))
                || (((Self.opens(said, with: Self.actionNos) && (!Self.ledByBareNo(said) || Self.saysOneBareNo(said, words)))
                    || (Self.opens(said, with: Self.refusalLeads) && Self.saysOneBareNo(said, words)
                        && VoiceThreadRouting.containsRefusalVerb(words)))
                    && Self.isOneClause(words))
        // A wait holds; it doesn't refuse ("hold on", "wait, I'm not
        // ready"). "Not now" does, and a not yet with a change in it ("wait,
        // make it Wednesday") asks for that change, not a no.
        case .notYet(let change):
            return change == nil
                && !Self.laterClauseSaysYes(words)
                && (VoiceThreadRouting.containsNegation(words) || Self.cjkNotYet.contains(where: { words.contains($0) }))
                && !Self.opens(said, with: Self.neutralWaits)
        case .yes: return false
        // A refusal verb ("decline it") or a not on the send itself
        // ("我不想发", "送らないで") declines, unless a change follows it
        // ("I refuse, send it to Bob instead").
        case .other:
            return (VoiceThreadRouting.containsRefusalVerb(words) || Self.isCJKSendRefusal(words)) && Self.isOneClause(words)
        }
    }

    /// A not on the send and no other not: "我没有说不发" (I didn't say
    /// not to send) denies the refusal.
    private static func isCJKSendRefusal(_ words: String) -> Bool {
        guard let phrase = cjkSendRefusals.first(where: { words.contains($0) }),
              let range = words.range(of: phrase) else { return false }
        // A Chinese send verb ends its word: "不用发愁" (no need to worry)
        // isn't about sending.
        if let last = phrase.last, "发發送".contains(last), let next = words[range.upperBound...].first,
           next.isLetter, !cjkSendFollowers.contains(next) {
            return false
        }
        let rest = words.replacingOccurrences(of: phrase, with: " ")
        return !cjkNots.contains(where: { rest.contains($0) })
    }

    /// What may follow a Chinese send verb and keep it about sending
    /// ("不要发了", "别发给他", "不要发短信").
    private static let cjkSendFollowers: Set<Character> = ["了", "吧", "啊", "呀", "啦", "嘛", "给", "給", "到", "出", "过", "過", "这", "這", "那", "邮", "郵", "消", "信", "送", "短", "微", "电", "電", "文", "照", "图", "圖", "链", "鏈", "语", "語", "它", "个", "個", "条", "條", "封", "帖"]

    /// Chinese, Japanese and Korean nots.
    private static let cjkNots = ["不", "没", "沒", "别", "別", "ない", "ません", "않", "못", "마", "말"]

    /// The marks that end a Chinese, Japanese or Korean question.
    private static let cjkQuestionEnds = ["吗", "嗎", "么", "麼", "呢", "か", "かな", "까", "까요", "나요"]
    /// A Chinese question asked by saying both ("要不要发", "是不是取消").
    private static let cjkAskPairs = [
        "要不要", "是不是", "发不发", "發不發", "送不送", "可不可以", "能不能", "行不行", "好不好", "用不用", "需不需要",
    ]
    /// A not on sending, in Chinese, Japanese or Korean.
    private static let cjkSendRefusals = [
        "不想发", "不想發", "不想送", "不用发", "不用發", "不用送", "不要发", "不要發", "不要送", "别发", "別發", "别送", "別送", "不发", "不發",
        "送らないで", "送信しないで", "보내지 마", "보내지마", "보내지 말",
    ]

    /// Led by a no but not one: a hit only keeps the panel up for the tap.
    private static let unsure = ["not sure", "no idea", "no clue", "no problem", "no worries", "no rush",
        "don't know", "dont know", "do not know", "don't remember", "dont remember", "do not remember", "can't remember",
        "can't say", "cannot say"]
    /// Not knowing in the other shipped languages, as whole words.
    private static let unsureWords: [[String]] = [
        "no sé", "no lo sé", "ni idea", "não sei", "nao sei", "não faço ideia", "je ne sais pas", "je sais pas",
        "aucune idée", "ich weiß nicht", "weiß nicht", "weiss nicht", "keine ahnung", "non lo so", "non so",
        "nessuna idea", "nie wiem", "не знаю", "понятия не имею", "bilmiyorum", "emin değilim", "tidak tahu",
        "tak tahu", "nggak tahu", "gak tahu", "tidak yakin",
    ].map { words(in: $0) }
    /// Whether the answer, past the words the handset skips before its lead
    /// ("well", "oh", "um"), opens with one of the phrases. A Chinese,
    /// Japanese or Korean phrase may run into the next words.
    private static func opens(_ said: [String], with phrases: [[String]]) -> Bool {
        let skipped = VoiceThreadRouting.answerJoiners.map { words(in: $0) }
        var rest = said[...]
        while let first = rest.first {
            if VoiceThreadRouting.fillers.contains(first) || leadingSkips.contains(first) || politeWords.contains(first) {
                rest = rest.dropFirst()
            } else if let joiner = skipped.first(where: { !$0.isEmpty && rest.starts(with: $0) }) {
                rest = rest.dropFirst(joiner.count)
            } else {
                break
            }
        }
        return phrases.contains { phrase in
            guard let lead = phrase.first else { return false }
            if phrase.count == 1, let scalar = lead.unicodeScalars.first, scalar.value >= 0x2E80 {
                return rest.first?.hasPrefix(lead) == true
            }
            return rest.starts(with: phrase)
        }
    }

    /// Whether the words say one thing: a second clause after a no that
    /// names its action ("don't send it to Alex; send it to Bob") is a
    /// change, not a no.
    private static func isOneClause(_ text: String) -> Bool {
        let breaks = CharacterSet(charactersIn: ",;:—–，；：、.!。！\n")
        // A polite ending ("…, please", "…, thanks") or a bare no before
        // the action ("no, cancel the email") isn't a second clause, but
        // any other is, short ones too ("don't send it, send it to Bob").
        // A joiner said without the comma ("… and send it to Bob") starts
        // one too.
        let clauses = text.unicodeScalars.split(whereSeparator: { breaks.contains($0) })
            .map { words(in: String(String.UnicodeScalarView($0))) }
            .flatMap { $0.split(whereSeparator: { clauseJoiners.contains($0) }).map(Array.init) }
            .filter { clause in !clause.isEmpty && !clause.allSatisfy { politeWords.contains($0) || leadingSkips.contains($0) } }
        return clauses.count <= 1
    }

    /// Thanks and please in the shipped languages: a clause of only these
    /// adds nothing.
    private static let politeWords: Set<String> = [
        "please", "pls", "thanks", "thank", "you", "thx", "cheers", "bitte", "danke", "schön", "por", "favor", "gracias",
        "s", "il", "vous", "plaît", "merci", "per", "favore", "grazie", "obrigado", "obrigada", "пожалуйста", "спасибо",
        "proszę", "dziękuję", "dzięki", "lütfen", "teşekkürler", "sağol", "tolong", "terima", "kasih", "makasih",
        "谢谢", "謝謝", "请", "請", "お願いします", "ありがとう", "부탁해요", "감사합니다", "고마워",
    ]

    /// Said before a no that names its action, and skipped to find it
    /// ("please cancel the email", "no, cancel the email").
    private static let leadingSkips: Set<String> = [
        "please", "pls", "bitte", "no", "nope", "nah", "nein", "non", "não", "nao", "nie", "нет", "hayır", "tidak",
    ]

    private static let clauseJoiners: Set<String> = [
        "and", "then", "but", "instead", "und", "dann", "aber", "stattdessen", "y", "pero", "luego", "et", "mais", "puis",
        "e", "ma", "poi", "и", "а", "но", "потом", "ale", "potem", "ve", "ama", "sonra", "dan", "tapi", "lalu",
    ]

    /// A no that names its action: what follows it is what's turned down.
    private static let actionNos: [[String]] = [
        "don't", "dont", "do not", "nicht", "cancel", "stop", "abort", "drop", "scrap", "skip", "ditch", "abbrechen", "storniere", "cancela", "cancelar",
        "annule", "annuler", "annulez", "anula", "anular", "annulla", "отмени", "отменить", "anuluj", "iptal",
        "batalkan", "batal", "取消", "キャンセル", "취소",
    ].map { words(in: $0) }

    /// Whether a clause after the first says yes ("no, send it"), or the
    /// words after a no do when the transcript dropped the comma ("no send
    /// it", "no wait go ahead").
    private static func laterClauseSaysYes(_ text: String) -> Bool {
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: ",;:—–，；：、.!。！\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // A thanks or please isn't a yes here ("no, thanks").
        func saysYes(_ clause: String) -> Bool {
            !words(in: clause).allSatisfy { politeWords.contains($0) } && VoiceCallDecisionOutcome.isYes(clause)
        }
        if let first = clauses.first {
            let said = words(in: first)
            let rest = said.drop(while: { bareNos.contains($0) || VoiceThreadRouting.fillers.contains($0) || noTurnArounds.contains($0) })
            if bareNos.contains(said.first ?? ""), let next = rest.first, !["don", "dont", "do", "not", "never", "nicht"].contains(next),
               saysYes(rest.joined(separator: " ")) { return true }
        }
        return clauses.dropFirst().contains(where: saysYes)
    }

    /// Words between a no and the yes that takes it back ("no wait, send it").
    private static let noTurnArounds: Set<String> = ["wait", "actually", "oh", "sorry", "warte", "espera", "attends", "aspetta", "espere", "подожди", "czekaj", "bekle", "tunggu"]

    /// The answer after a Chinese, Japanese or Korean no in its own clause
    /// ("不，拒绝", "いや、断る"), where that no isn't the not of the verb.
    private static func afterCJKNo(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a mark sets the no apart: "不要 拒绝" is one "don't refuse".
        for no in ["不", "不不", "いや", "いいえ", "아니", "아니요", "아뇨"] {
            for mark in ["，", ",", "、", "。"] where trimmed.hasPrefix(no + mark) {
                let rest = String(trimmed.dropFirst(no.count + mark.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return rest.isEmpty ? nil : rest
            }
        }
        return nil
    }

    /// Whether a not comes right before a cancel ("don't cancel", "nicht
    /// abbrechen"), or a German nicht after it in the same clause
    /// ("Storniere es nicht"): the user turned the cancel down, not the
    /// request.
    private static func negatesActionNo(_ said: [String], in text: String) -> Bool {
        let nots: Set<String> = ["t", "not", "dont", "nicht", "never"]
        let cancels = Set(actionNos.filter { $0.count == 1 }.map { $0[0] }).subtracting(nots)
        if zip(said, said.dropFirst()).contains(where: { nots.contains($0) && cancels.contains($1) }) { return true }
        return text.components(separatedBy: CharacterSet(charactersIn: ",;:—–，；：、.!。！\n")).contains { clause in
            let clauseWords = words(in: clause)
            guard let cancel = clauseWords.firstIndex(where: { cancels.contains($0) }) else { return false }
            return clauseWords[(cancel + 1)...].contains("nicht")
        }
    }

    private static let cjkNegatedCancels = [
        "不要取消", "别取消", "別取消", "不取消", "不用取消", "キャンセルしないで", "キャンセルしない", "취소하지",
    ]

    /// Whether the answer opens with a bare no, which may be the next
    /// verb's not ("no cancelar el envío") rather than an answer.
    private static func ledByBareNo(_ said: [String]) -> Bool {
        guard let first = said.first(where: { !VoiceThreadRouting.fillers.contains($0) }) else { return false }
        return bareNos.contains(first)
    }

    /// A no said on its own and only once: a second one is the verb's not
    /// ("no, no lo rechazo", I don't reject it).
    private static func saysOneBareNo(_ said: [String], _ text: String) -> Bool {
        noStandsAlone(text) && said.filter { bareNos.contains($0) }.count <= 1
    }

    private static let bareNos: Set<String> = ["no", "nope", "nah", "nein", "non", "não", "nao", "nie", "нет", "hayır", "tidak"]

    /// Whether the no before a refusal is a clause of its own ("no, lo
    /// rechazo"), not the verb's not ("no lo rechazo", I don't reject it).
    private static func noStandsAlone(_ text: String) -> Bool {
        let breaks = CharacterSet(charactersIn: ",;:—–，；：、.!。！\n")
        guard let first = text.unicodeScalars.split(whereSeparator: { breaks.contains($0) })
            .map({ words(in: String(String.UnicodeScalarView($0))) })
            .first(where: { !$0.isEmpty }) else { return false }
        return first.allSatisfy { leadingSkips.contains($0) || politeWords.contains($0) || VoiceThreadRouting.fillers.contains($0) }
    }

    /// The user's own refusal after a no ("no, I refuse", "no, decline
    /// it"), not someone else's ("no, Alex declined it").
    private static let refusalLeads: [[String]] = [
        "decline", "refuse", "reject", "deny", "veto", "i refuse", "i decline", "i reject", "i deny",
        "ablehnen", "lehne", "ich lehne", "rechaza", "rechazo", "recházalo", "lo rechazo", "la rechazo", "je refuse", "je le refuse", "je la refuse", "rejette", "refusez",
        "rifiuta", "rifiuto", "lo rifiuto", "la rifiuto", "rejeita", "recuso", "eu recuso", "recusa", "отклони", "отклоните", "отказываюсь", "я отказываюсь",
        "odrzuć", "odmawiam", "reddet", "reddediyorum", "tolak", "saya menolak", "拒绝", "拒絕", "拒否", "断る", "断って", "お断り",
    ].map { words(in: $0) }

    /// The handset's not-yet leads with no not in them: a wait.
    private static let neutralWaits: [[String]] = (VoiceThreadRouting.answerNotYetLeads + VoiceThreadRouting.cjkAnswerNotYetLeads)
        .filter { lead in !VoiceThreadRouting.containsNegation(lead) && !cjkNotYet.contains(where: { lead.contains($0) }) }
        .map { words(in: $0) }

    /// A not yet whose not sits inside it ("先不", "还没", "先别", "まだ", "아직").
    private static let cjkNotYet = ["不", "没", "沒", "别", "別", "まだ", "아직"]
    private static let cjkUnsure = ["不知道", "不确定", "不確定", "わからない", "分からない", "わかりません", "分かりません", "모르겠", "몰라"]

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
    /// contact card's message (plugin 0.67+); "board-cards": tables,
    /// timelines, checklists, lists, progress and callouts, up to 12 cards
    /// as a stack or tabs, and follow-ups (plugin 0.128+); "room-boards": a
    /// group room's boards under its agents' messages (plugin 0.129+);
    /// "diff-cards": changes line by line (plugin 0.133+); "composed-cards":
    /// cards Hermes builds itself, and buttons and fields on any card
    /// (plugin 0.140+). "review-cards": options to look at and mark, a
    /// quick pick or a review in rounds (plugin 0.147+). "room-asks": a
    /// room's asks, answered with Share, Say instead (with the words) or
    /// Don't share (plugin 0.118+, Linked Rooms). "link-asks": a linked
    /// person's Hermes' asks, the same way, with Share only when there's an
    /// answer to share (plugin 0.120+). "room-work": a room's ask to start
    /// work for it (Run work), answered Start, Change it (with what to do
    /// instead) or Don't start (plugin 0.137+).
    static let features = ["maps-navigate", "show-cards", "chat-cards", "info-cards", "media-cards", "live-cards",
                           "text-drafts", "board-cards", "room-boards", "diff-cards", "composed-cards", "review-cards", "room-asks", "link-asks",
                           "room-work"]
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
        // Nothing to confirm (a Link's question): never sent as a Share.
        if outcome == .confirmed, !prompt.canConfirm { return }
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

    /// Answers still waiting to reach a dashboard's host, a Say instead's
    /// words included, go with its saved chats when it's signed out of or
    /// removed (issue 2041): the next sign-in may be another account. Nil
    /// forgets every dashboard's.
    func forgetAnswers(dashboardID: UUID?) {
        guard let dashboardID else {
            defaults.removeObject(forKey: Self.resultsKey)
            return
        }
        guard var all = defaults.dictionary(forKey: Self.resultsKey) as? [String: [[String: Any]]] else { return }
        let prefix = "\(dashboardID.uuidString)|"
        all = all.filter { !$0.key.hasPrefix(prefix) }
        if all.isEmpty {
            defaults.removeObject(forKey: Self.resultsKey)
        } else {
            defaults.set(all, forKey: Self.resultsKey)
        }
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
            + "checks their words and refuses otherwise. decline: only right after the user said no or not now out "
            + "loud in this call; Conduit checks their words too and refuses otherwise. Before asking, "
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
        if let room = prompt.room {
            // Run work: it asks before it starts work for that room, or sends its
            // running work more (confirm does it).
            let key = !room.work ? "room" : prompt.actionLabel == "Send" ? "sends_to_work_for_room" : "starts_work_for_room"
            entry[key] = room.name.isEmpty ? "a room" : room.name
            // Work never starts on a plain yes, which may have answered something else.
            if room.work { entry["plain_yes_counts"] = false }
        }
        // A linked person's Hermes asks; a question has nothing to confirm.
        if let link = prompt.link {
            entry["asked_by"] = link.name.isEmpty ? "a linked person's Hermes" : "\(link.name)'s Hermes"
            if !link.share { entry["can_confirm"] = false }
        }
        return entry
    }

    /// The quiet note a live model gets when one arrives mid-call.
    static func note(for prompt: PresentedConfirm) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: describe(prompt), options: [.sortedKeys])) ?? Data()
        let details = String(data: data, encoding: .utf8) ?? ""
        if !prompt.canConfirm {
            return "[A linked person's Hermes asked the user something on their screen: \(details). At the next natural pause, tell the user in a sentence; they type their answer on the panel, or call \(name) with decline and its id if they say no, they won't answer. Don't interrupt the user for it.]"
        }
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
            guard prompt.canConfirm else {
                return ["error": "Nothing to confirm: it's their question. The user answers it on the panel with Say instead, or decline it if they don't want to."]
            }
            // Room work takes only its phrase ("start it"), never a bare yes.
            let bareYes = prompt.room?.work != true
            guard await userSaid({ prompt.isConfirmed(by: $0, bareYes: bareYes) }, to: prompt, sync: sync,
                                 lastUserTurn: lastUserTurn) else {
                guard stillWaiting(prompt, sync: sync) else { return alreadyAnswered }
                // Room work takes only its phrase, so asking for a yes wouldn't do.
                if prompt.room?.work == true {
                    guard let phrase = prompt.spokenYes.first else {
                        return ["error": "Not confirmed. Ask the user to answer it on the screen."]
                    }
                    let what = prompt.actionLabel == "Send" ? "send to work" : "start work"
                    return ["error": "Not confirmed: a plain yes doesn't \(what). Ask the user to say \"\(phrase)\", and confirm only after they do."]
                }
                return ["error": "Not confirmed: the user's own words weren't a yes. Ask them, and confirm only after they say yes."]
            }
            // Tapped while their words arrived: the tap stands.
            guard stillWaiting(prompt, sync: sync) else { return alreadyAnswered }
            await answer(prompt, .confirmed)
            return ["result": "Confirmed. Hermes goes ahead."]
        case "decline":
            // Like a confirm, a decline is the user's: their own no, said
            // after it appeared. Else the panel stays for their tap.
            guard await userSaid({ prompt.isDeclined(by: $0) }, to: prompt, sync: sync, lastUserTurn: lastUserTurn) else {
                guard stillWaiting(prompt, sync: sync) else { return alreadyAnswered }
                return ["error": "Not declined: the user's own words weren't a no. It stays on their screen for them to answer; ask them, and decline only after they say no."]
            }
            // Tapped while their words arrived: the tap stands.
            guard stillWaiting(prompt, sync: sync) else { return alreadyAnswered }
            await answer(prompt, .declined)
            return ["result": "Declined. Hermes won't do it."]
        default:
            return ["error": "Unknown action."]
        }
    }

    private static func stillWaiting(_ prompt: PresentedConfirm, sync: PresentedScreensSync) -> Bool {
        sync.prompts.contains { $0.id == prompt.id && !$0.isExpired() }
    }

    /// Whether the user's last turn, said after `prompt` appeared, answers
    /// it as `answers` reads it. Their words reach Conduit a moment after
    /// the model heard them, so they're waited for, up to 2 seconds, while
    /// it still waits.
    private static func userSaid(
        _ answers: @escaping @MainActor (String) -> Bool, to prompt: PresentedConfirm, sync: PresentedScreensSync,
        lastUserTurn: @escaping @MainActor () -> (id: UUID?, text: String)
    ) async -> Bool {
        let shownAfter = sync.userTurnWhenShown[prompt.id]
        let deadline = ContinuousClock.now + .seconds(2)
        func said() -> Bool {
            let turn = lastUserTurn()
            // A turn from before the panel appeared answers something else.
            if let shownAfter, turn.id == shownAfter { return false }
            return answers(turn.text)
        }
        while !said() {
            guard stillWaiting(prompt, sync: sync), ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        return true
    }
}
