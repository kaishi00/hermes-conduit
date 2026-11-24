//
//  NeedsYou.swift
//  Conduit
//
//  Hermes is waiting on you, across chats and profiles (issue 1705): every
//  chat with an approval or a question waiting on the user, read from the
//  plugin's list of them (GET /waiting, one profile at a time). It feeds the
//  count on each profile's chip, the banner when another chat starts
//  waiting, and the Needs you list. None of them answers anything: each
//  opens the chat at its card (AppState+NeedsYou). A question Hermes drew no
//  card for in the chat (the turn ran in another Hermes process) brings its
//  card with its row, and the chat draws that one (issue 2556).
//

import Foundation

/// One chat Hermes waits on the user in, as the plugin lists it.
struct NeedsYouItem: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case approval
        case question
    }

    /// The plugin's id for this wait: a new wait in the same chat gets a new one.
    let waitID: String
    /// The profile whose list named it.
    let profile: String
    let kind: Kind
    /// The ids the chat goes by (its stored id first, then the runtime's).
    let sessionIDs: [String]
    /// The chat's title when the plugin could read it; empty otherwise.
    let title: String
    /// An approval's description (Hermes' words), or a question's text.
    let summary: String
    /// How many questions a batch holds; 0 for an approval.
    let questions: Int
    let since: Date
    /// The group room this Hermes hosts that the wait is in (notifier
    /// 0.150.1+): its row opens the room, whose card answers it, not the
    /// bot's hidden chat there (issue 2064). Nil for a chat's wait.
    let roomID: String?
    /// A question's card as its push carried it (notifier 0.177.17+): the
    /// chat draws it when Hermes drew none there, since an open Conduit gets
    /// no notification to tap (issue 2556). Nil for an approval.
    let card: PendingDecisionPayload?
    /// Another combined dashboard's wait, read through its kept connection
    /// (all-live stage 4a). Nil for the dashboard on screen's.
    var dashboardID: UUID? = nil
    /// The relay gateway the profile's list said it pairs through (notifier
    /// 0.177.30+): the card's answer is sealed for it (issue 2683).
    var relayGatewayID: String? = nil
    /// A question the bot asked that waits past its turn (work_propose, or
    /// a clarify kept after it ran out; notifier 0.189.0+). Its row opens
    /// the chat that asked, as every row does (the list only opens): it's
    /// answered there in a reply, or with a tap on the bot's Work panel.
    var asked: BotWorkCoordination.Item? = nil

    var id: String {
        dashboardID.map { "\($0.uuidString)\u{1F}\(hostKey)" } ?? hostKey
    }

    /// The wait as its Hermes names it, whichever saved dashboard read it:
    /// the plugin's ids are random, so two dashboards reaching one Hermes
    /// (saved at two addresses) give the same key (issue 2631).
    var hostKey: String { "\(profile)\u{1F}\(waitID)" }

    init(
        waitID: String,
        profile: String,
        kind: Kind,
        sessionIDs: [String],
        title: String = "",
        summary: String = "",
        questions: Int = 0,
        since: Date = Date(),
        roomID: String? = nil,
        card: PendingDecisionPayload? = nil
    ) {
        self.waitID = waitID
        self.profile = profile
        self.kind = kind
        self.sessionIDs = sessionIDs
        self.title = title
        self.summary = summary
        self.questions = questions
        self.since = since
        self.roomID = roomID
        self.card = card
    }

    /// One row of the plugin's `waiting` list; nil when it names no chat.
    init?(host: [String: Any], profile: String) {
        guard let waitID = host["id"] as? String, !waitID.isEmpty,
              let kind = (host["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        let ids = (host["session_ids"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { return nil }
        let at = (host["at"] as? NSNumber)?.doubleValue
        self.init(
            waitID: waitID,
            profile: profile,
            kind: kind,
            sessionIDs: ids,
            title: (host["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            summary: (host["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            questions: (host["questions"] as? NSNumber)?.intValue ?? 0,
            // A host that sends no time: one fixed date, so the row neither
            // reads "now" forever nor changes on every read.
            since: at.map { Date(timeIntervalSince1970: $0) } ?? .distantPast,
            roomID: (host["room"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 },
            card: kind == .question ? PushNotificationService.waitingQuestionCard(from: host) : nil
        )
    }

    /// A profile's `/waiting` answer as its rows, each carrying the relay
    /// gateway the list names (issue 2683): this device's own, among the
    /// `gateways` of a profile that notifies several (issue 2758), else the
    /// main pairing's; nil when it holds no list (an error body).
    static func items(listed response: [String: Any], profile: String,
                      installationID: String? = nil) -> [NeedsYouItem]? {
        guard let listed = response["waiting"] as? [[String: Any]] else { return nil }
        func trimmed(_ value: String?) -> String? {
            value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let own = trimmed(installationID.flatMap { (response["gateways"] as? [String: Any])?[$0.lowercased()] as? String })
        let gatewayID = own ?? trimmed(response["gateway_id"] as? String)
        let waits = listed.compactMap { row in
            var item = NeedsYouItem(host: row, profile: profile)
            item?.relayGatewayID = gatewayID
            return item
        }
        let asked = (response["questions"] as? [[String: Any]] ?? []).compactMap { row in
            var item = NeedsYouItem(question: row, profile: profile)
            item?.relayGatewayID = gatewayID
            return item
        }
        return waits + asked
    }

    /// One of the list's `questions` (notifier 0.189.0+); nil when it isn't
    /// open or names no chat to open.
    init?(question row: [String: Any], profile: String) {
        guard let asked = BotWorkCoordination.Item(row: row), asked.kind == .proposal,
              asked.canAnswer || (asked.answersInWords && asked.status == "open") else { return nil }
        let ids = (row["session_ids"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { return nil }
        self.init(waitID: "asked-\(asked.id)", profile: profile, kind: .question, sessionIDs: ids,
                  title: (row["chat_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                  summary: asked.text.trimmingCharacters(in: .whitespacesAndNewlines), questions: 1, since: asked.at)
        self.asked = asked
    }

    /// What the chat waits on, in the App Language.
    var kindLine: String {
        if let asked, asked.goingAhead, let state = asked.stateText { return state }
        switch kind {
        case .approval: return AppLocalization.string("Approval needed")
        case .question where questions > 1: return AppLocalization.string("\(Int(questions)) questions", table: .chat)
        case .question: return AppLocalization.string("Question")
        }
    }

    /// The line under the title: an approval's description drawn as the
    /// chat's card draws it (Hermes' texts in the App Language, hidden
    /// characters shown), a question as Hermes wrote it.
    var summaryLine: String {
        switch kind {
        case .approval: return ApprovalDisplayText.revealingHidden(HermesApprovalText.description(summary))
        case .question: return ApprovalDisplayText.revealingHidden(summary)
        }
    }
}

/// The chat to scroll to its waiting card once it's open: the newest
/// question, approval or input card, as the jump button finds it.
struct NeedsYouReveal: Equatable {
    /// The chat it is for (being opened, or the open one); nil: any.
    let opening: String?
    let expires: Date

    init(opening: String?, now: Date = Date()) {
        self.opening = opening
        // As ArtifactReveal: a chat that takes long to open doesn't jump
        // later, out of nowhere.
        self.expires = now.addingTimeInterval(20)
    }
}

/// Every profile's waits, as last read. Its own observable, so a read
/// redraws only what shows it (the chips, the banner, the list).
@MainActor
final class NeedsYouStore: ObservableObject {
    static let capability = "waiting-list"
    static let path = "/api/plugins/conduit_push/waiting"
    /// The notifications of a wait, which open on its card.
    static let notificationTypes: Set<String> = ["approval.needed", "input.needed"]
    /// Between reads while Conduit is on screen. A push of a new wait reads
    /// at once, so this only catches what no push said (answered elsewhere,
    /// a host that sends none).
    static let pollInterval: TimeInterval = 20
    /// How long the banner stays before it goes by itself. The wait stays
    /// on the chips and in the list.
    static let bannerSeconds: TimeInterval = 10

    /// Newest first, every profile's.
    @Published private(set) var items: [NeedsYouItem] = []
    /// The other combined dashboards' waits, read through their kept
    /// connections (all-live stage 4a), newest first in each. Apart from
    /// `items`, so a profile chip counts only the dashboard on screen's.
    @Published private(set) var otherDashboards: [UUID: [NeedsYouItem]] = [:]
    /// A wait that began since the last read, in a chat other than the open one.
    @Published private(set) var banner: NeedsYouItem?

    /// The dashboard these were read on: another one's are dropped.
    private(set) var dashboardID: UUID?
    /// Profiles read at least once on this dashboard: the first read of one
    /// shows no banner for what already waited there.
    private var readProfiles: Set<String> = []
    private var seen: Set<String> = []
    /// The same for each other combined dashboard, kept through a switch:
    /// a dashboard's first read of a profile shows no banner either.
    private var otherReadProfiles: [UUID: Set<String>] = [:]
    private var otherSeen: Set<String> = []
    private var reading = false
    private var readAgain = false
    /// Questions whose card Hermes drew itself: the row's copy stays out of
    /// the chat for good, even once Hermes' card is answered and the list,
    /// read a moment before, still names the wait (issue 2556).
    private(set) var cardsHermesDrew: Set<String> = []

    func noteHermesDrewCard(for requestID: String) {
        cardsHermesDrew.insert(requestID)
    }

    /// A question's card drawn into the chat on screen from its row
    /// (`AppState.showWaitingQuestionCards`): where it went, so it's taken
    /// back once the plugin lets the wait go (issue 2828).
    struct DrawnCard: Equatable {
        let requestID: String
        /// The list's profile, whose read decides.
        let profile: String
        let decisionKey: String
        let presentationProfile: String
        let cacheSessionIDs: [String]
    }

    private(set) var cardsDrawnHere: [String: DrawnCard] = [:]

    func noteDrewCard(_ card: DrawnCard) {
        cardsDrawnHere[card.requestID] = card
    }

    /// The cards drawn here for `profile` whose waits its list read just now
    /// no longer names, forgotten as they're handed back: the plugin gave
    /// the question up (it ran out, or was answered elsewhere), and an
    /// answer would be refused.
    func takeCardsNoLongerListed(profile: String) -> [DrawnCard] {
        // A profile matches its own spelling in any case (issue 2726).
        let listed = Set(items.filter { AppState.profilesMatch($0.profile, profile) }.compactMap { $0.card?.requestID })
        let gone = cardsDrawnHere.values.filter { AppState.profilesMatch($0.profile, profile) && !listed.contains($0.requestID) }
        for card in gone { cardsDrawnHere[card.requestID] = nil }
        return gone.sorted { $0.requestID < $1.requestID }
    }

    /// Runs `read`, or, while one runs, has it run once more after: a
    /// burst of asks makes at most one more read, and reads never overlap
    /// (an older one landing last would bring back an answered wait).
    func coalescing(_ read: @escaping @MainActor () async -> Void) async {
        guard !reading else {
            readAgain = true
            return
        }
        reading = true
        // Unstructured, so a follow-up a push asked for still runs when the
        // caller (the sheet's task) is cancelled.
        await Task { @MainActor in
            defer { self.reading = false }
            repeat {
                self.readAgain = false
                await read()
            } while self.readAgain
        }.value
    }

    func count(for profile: String, matches: (String, String) -> Bool) -> Int {
        items.reduce(0) { $0 + (matches($1.profile, profile) ? 1 : 0) }
    }

    /// A profile's list as just read. `isOpenChat` says whether a wait is
    /// in the chat on screen, which gets no banner (its card is there).
    func apply(
        _ read: [NeedsYouItem],
        profile: String,
        dashboardID: UUID?,
        isOpenChat: (NeedsYouItem) -> Bool
    ) {
        if dashboardID != self.dashboardID { reset(dashboardID: dashboardID) }
        let read = read.filter { !answeredLately($0, on: dashboardID) }
        let firstRead = !readProfiles.contains(profile)
        readProfiles.insert(profile)
        let fresh = read.filter { !seen.contains($0.id) }
        seen.formUnion(read.map(\.id))
        let merged = (items.filter { $0.profile != profile } + read).sorted { $0.since > $1.since }
        if merged != items { items = merged }
        // A wait that left the list needs no remembering.
        cardsHermesDrew.formIntersection(merged.compactMap { $0.card?.requestID })
        dropBannerNoLongerListed()
        // Another dashboard's banner for a wait this read lists as open
        // here: one Hermes saved twice, its room already on screen.
        if let banner, banner.dashboardID != nil,
           read.contains(where: { Self.sameWait($0, banner) && isOpenChat($0) }) {
            self.banner = nil
        }
        // A wait another combined dashboard listed first (one Hermes saved
        // at two addresses) had its banner there already (issue 2631),
        // under any spelling of its profile (#2800 review).
        let listedElsewhere = Array(otherDashboards.values.joined())
        guard !firstRead,
              let newest = fresh.filter({ item in
                  !isOpenChat(item) && !listedElsewhere.contains { Self.sameWait($0, item) }
              })
                .max(by: { $0.since < $1.since }) else { return }
        // Another profile read in the same refresh may have shown a newer one.
        if let banner, banner.since > newest.since { return }
        banner = newest
    }

    /// Every wait, the dashboard on screen's and the other combined
    /// ones', newest first: the Needs you list. A wait another dashboard
    /// also lists (one Hermes saved at two addresses) shows once, as this
    /// dashboard's, as the Chats list does (issue 2631).
    var everyItem: [NeedsYouItem] {
        guard !otherDashboards.isEmpty else { return items }
        // One wait once, under any spelling of its profile (`sameWait`): a
        // re-cased copy listed for a moment under both isn't two (issue 2770).
        var listed = items
        for id in otherDashboards.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            for item in otherDashboards[id] ?? [] where !listed.contains(where: { Self.sameWait($0, item) }) {
                listed.append(item)
            }
        }
        return listed.sorted { $0.since > $1.since }
    }

    /// Whether a wait is listed already by this dashboard or by another
    /// combined one than `dashboardID`.
    private func heldElsewhere(_ item: NeedsYouItem, than dashboardID: UUID) -> Bool {
        items.contains { Self.sameWait($0, item) }
            || otherDashboards.contains { $0.key != dashboardID && $0.value.contains { Self.sameWait($0, item) } }
    }

    /// One profile's list on another combined dashboard, as just read
    /// through its kept connection. A new wait there shows the banner, as
    /// one here does, unless another dashboard lists it too (one Hermes
    /// saved at two addresses) or its chat is the one on screen, which
    /// that twin can reach (issue 2631).
    func applyOther(
        _ read: [NeedsYouItem],
        profile: String,
        dashboardID: UUID,
        isOpenChat: (NeedsYouItem) -> Bool = { _ in false }
    ) {
        guard dashboardID != self.dashboardID else { return }
        let tagged = read.filter { !answeredLately($0, on: dashboardID) }.map { item -> NeedsYouItem in
            var item = item
            item.dashboardID = dashboardID
            return item
        }
        // A profile matches its own spelling in any case, as forgetOther
        // does: a re-cased name replaces its rows rather than doubling them.
        let sameProfile: (String) -> Bool = { AppState.profilesMatch($0, profile) }
        let firstRead = otherReadProfiles[dashboardID]?.contains(where: sameProfile) != true
        otherReadProfiles[dashboardID] = (otherReadProfiles[dashboardID] ?? []).filter { !sameProfile($0) }.union([profile])
        // A wait already listed under another spelling isn't new.
        let listedBefore = Set((otherDashboards[dashboardID] ?? []).filter { sameProfile($0.profile) }.map(\.waitID))
        let fresh = tagged.filter { !otherSeen.contains($0.id) && !listedBefore.contains($0.waitID) }
        otherSeen.formUnion(tagged.map(\.id))
        let merged = ((otherDashboards[dashboardID] ?? []).filter { !sameProfile($0.profile) } + tagged)
            .sorted { $0.since > $1.since }
        if merged != otherDashboards[dashboardID] ?? [] {
            otherDashboards[dashboardID] = merged.isEmpty ? nil : merged
        }
        dropBannerNoLongerListed()
        // A banner up for a wait whose room is now open (another
        // dashboard's room opened in place): its card is on screen.
        if let banner, banner.dashboardID == dashboardID,
           tagged.contains(where: { Self.sameWait($0, banner) && isOpenChat($0) }) {
            self.banner = nil
        }
        guard !firstRead,
              let newest = fresh.filter({ !heldElsewhere($0, than: dashboardID) && !isOpenChat($0) })
                .max(by: { $0.since < $1.since }) else { return }
        if let banner, banner.since > newest.since { return }
        banner = newest
    }

    /// Another combined dashboard's profiles no longer listed there.
    func forgetOther(_ dashboardID: UUID, profilesOtherThan profiles: Set<String>) {
        guard let listed = otherDashboards[dashboardID] else { return }
        // A profile matches its own spelling in any case (issue 2726).
        func listedStill(_ profile: String) -> Bool { profiles.contains { AppState.profilesMatch($0, profile) } }
        let kept = listed.filter { listedStill($0.profile) }
        if kept != listed { otherDashboards[dashboardID] = kept.isEmpty ? nil : kept }
        otherReadProfiles[dashboardID] = otherReadProfiles[dashboardID]?.filter(listedStill)
        dropBannerNoLongerListed()
    }

    /// Only the combined dashboards still kept beside the one on screen
    /// keep their waits: one let go, out of the group or signed out of
    /// says nothing more.
    func forgetOtherDashboards(otherThan kept: Set<UUID>) {
        let gone = Set(otherDashboards.keys).union(otherReadProfiles.keys).subtracting(kept)
        guard !gone.isEmpty else { return }
        for id in gone {
            otherDashboards.removeValue(forKey: id)
            otherReadProfiles.removeValue(forKey: id)
        }
        let prefixes = gone.map { "\($0.uuidString)\u{1F}" }
        otherSeen = otherSeen.filter { id in !prefixes.contains { id.hasPrefix($0) } }
        dropBannerNoLongerListed()
    }

    private func dropBannerNoLongerListed() {
        guard let banner else { return }
        let listed = banner.dashboardID.map { otherDashboards[$0] ?? [] } ?? items
        // The same wait under another spelling of its profile still counts.
        if !listed.contains(where: { Self.sameWait($0, banner) }) { self.banner = nil }
    }

    /// One wait whatever the case of its profile's name (issue 2726).
    static func sameWait(_ a: NeedsYouItem, _ b: NeedsYouItem) -> Bool {
        a.waitID == b.waitID && AppState.profilesMatch(a.profile, b.profile)
    }

    /// A question the user just answered here leaves at once, so the asking
    /// chat's card moves on to the next even when the read behind it fails.
    /// Drops it from the dashboard it belongs to (screen `items` or kept
    /// `otherDashboards`) and its twins.
    func dropAnsweredQuestion(_ questionID: String, profile: String, dashboardID: UUID?,
                              alsoOn twins: Set<UUID> = [], now: Date = Date()) {
        let waitID = "asked-\(questionID)"
        func answered(_ item: NeedsYouItem) -> Bool { item.waitID == waitID && AppState.profilesMatch(item.profile, profile) }
        if let dashboardID, dashboardID != self.dashboardID {
            answeredQuestions.removeAll { now.timeIntervalSince($0.at) >= Self.answeredQuestionHold }
            answeredQuestions.append((waitID, profile, now, Set([Optional(dashboardID)]).union(twins.map { Optional($0) })))
            for id in Set([dashboardID]).union(twins) {
                if id == self.dashboardID {
                    let kept = items.filter { !answered($0) }
                    if kept != items { items = kept }
                } else if let listed = otherDashboards[id] {
                    let kept = listed.filter { !answered($0) }
                    if kept != listed { otherDashboards[id] = kept.isEmpty ? nil : kept }
                }
            }
            dropBannerNoLongerListed()
            return
        }
        guard dashboardID == self.dashboardID else { return }
        // A read already out when it was answered can't bring it back for
        // a while: the read after the answer lists it no more (issue 2980).
        answeredQuestions.removeAll { now.timeIntervalSince($0.at) >= Self.answeredQuestionHold }
        answeredQuestions.append((waitID, profile, now, Set([self.dashboardID]).union(twins.map { Optional($0) })))
        // The same Hermes saved as another combined dashboard lists the
        // same question: its copy goes too, rather than at its next read.
        for twin in twins where twin != self.dashboardID {
            guard let listed = otherDashboards[twin] else { continue }
            let kept = listed.filter { !answered($0) }
            if kept != listed { otherDashboards[twin] = kept.isEmpty ? nil : kept }
        }
        let kept = items.filter { !answered($0) }
        guard kept != items else {
            dropBannerNoLongerListed()
            return
        }
        items = kept
        dropBannerNoLongerListed()
    }

    /// How long a question answered here stays out of a read that lists it
    /// (one started before the answer landed).
    static let answeredQuestionHold: TimeInterval = 30
    /// Questions answered here lately, by wait id and profile.
    /// A question id is its Hermes' own, so each names the dashboards it
    /// was answered on: this one and its twins (one Hermes saved twice).
    private var answeredQuestions: [(waitID: String, profile: String, at: Date, dashboards: Set<UUID?>)] = []

    /// Whether `item`, as listed by `dashboardID`, is a question answered
    /// here within the hold.
    private func answeredLately(_ item: NeedsYouItem, on dashboardID: UUID?, now: Date = Date()) -> Bool {
        answeredQuestions.contains {
            $0.waitID == item.waitID && AppState.profilesMatch($0.profile, item.profile)
                && $0.dashboards.contains(dashboardID) && now.timeIntervalSince($0.at) < Self.answeredQuestionHold
        }
    }

    /// A profile no longer listed (removed, or its plugin can't be read).
    func forget(profilesOtherThan profiles: Set<String>) {
        let kept = items.filter { profiles.contains($0.profile) }
        if kept != items { items = kept }
        readProfiles = readProfiles.intersection(profiles)
        dropBannerNoLongerListed()
    }

    func dismissBanner(_ item: NeedsYouItem? = nil) {
        guard let banner, item == nil || item?.id == banner.id else { return }
        self.banner = nil
    }

    func reset(dashboardID: UUID?) {
        self.dashboardID = dashboardID
        readProfiles = []
        seen = []
        cardsHermesDrew = []
        cardsDrawnHere = [:]
        if !items.isEmpty { items = [] }
        // The one now on screen is read as this dashboard's from here.
        if let dashboardID {
            otherDashboards.removeValue(forKey: dashboardID)
            otherReadProfiles.removeValue(forKey: dashboardID)
        }
        banner = nil
    }
}

/// Runs one read at a time; reads asked for while one runs make one more
/// after it, never several at once.
@MainActor
final class ReadCoalescer {
    private var reading = false
    private var readAgain = false

    func coalescing(_ read: @escaping @MainActor () async -> Void) async {
        guard !reading else {
            readAgain = true
            return
        }
        reading = true
        // Unstructured, so a follow-up still runs when the caller is cancelled.
        await Task { @MainActor in
            defer { self.reading = false }
            repeat {
                self.readAgain = false
                await read()
            } while self.readAgain
        }.value
    }
}
