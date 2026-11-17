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
    /// gateway the list names (issue 2683); nil when it holds no list (an
    /// error body).
    static func items(listed response: [String: Any], profile: String) -> [NeedsYouItem]? {
        guard let listed = response["waiting"] as? [[String: Any]] else { return nil }
        let gatewayID = (response["gateway_id"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return listed.compactMap { row in
            var item = NeedsYouItem(host: row, profile: profile)
            item?.relayGatewayID = gatewayID
            return item
        }
    }

    /// What the chat waits on, in the App Language.
    var kindLine: String {
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
        let firstRead = !readProfiles.contains(profile)
        readProfiles.insert(profile)
        let fresh = read.filter { !seen.contains($0.id) }
        seen.formUnion(read.map(\.id))
        let merged = (items.filter { $0.profile != profile } + read).sorted { $0.since > $1.since }
        if merged != items { items = merged }
        // A wait that left the list needs no remembering.
        cardsHermesDrew.formIntersection(merged.compactMap { $0.card?.requestID })
        dropBannerNoLongerListed()
        // A wait another combined dashboard listed first (one Hermes saved
        // at two addresses) had its banner there already (issue 2631).
        let listedElsewhere = Set(otherDashboards.values.joined().map(\.hostKey))
        guard !firstRead,
              let newest = fresh.filter({ !isOpenChat($0) && !listedElsewhere.contains($0.hostKey) })
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
        var taken = Set(items.map(\.hostKey))
        var listed = items
        for id in otherDashboards.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            for item in otherDashboards[id] ?? [] where taken.insert(item.hostKey).inserted {
                listed.append(item)
            }
        }
        return listed.sorted { $0.since > $1.since }
    }

    /// Whether a wait is listed already by this dashboard or by another
    /// combined one than `dashboardID`.
    private func heldElsewhere(_ item: NeedsYouItem, than dashboardID: UUID) -> Bool {
        items.contains { $0.hostKey == item.hostKey }
            || otherDashboards.contains { $0.key != dashboardID && $0.value.contains { $0.hostKey == item.hostKey } }
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
        let tagged = read.map { item -> NeedsYouItem in
            var item = item
            item.dashboardID = dashboardID
            return item
        }
        let firstRead = otherReadProfiles[dashboardID]?.contains(profile) != true
        otherReadProfiles[dashboardID, default: []].insert(profile)
        let fresh = tagged.filter { !otherSeen.contains($0.id) }
        otherSeen.formUnion(tagged.map(\.id))
        let merged = ((otherDashboards[dashboardID] ?? []).filter { $0.profile != profile } + tagged)
            .sorted { $0.since > $1.since }
        if merged != otherDashboards[dashboardID] ?? [] {
            otherDashboards[dashboardID] = merged.isEmpty ? nil : merged
        }
        dropBannerNoLongerListed()
        guard !firstRead,
              let newest = fresh.filter({ !heldElsewhere($0, than: dashboardID) && !isOpenChat($0) })
                .max(by: { $0.since < $1.since }) else { return }
        if let banner, banner.since > newest.since { return }
        banner = newest
    }

    /// Another combined dashboard's profiles no longer listed there.
    func forgetOther(_ dashboardID: UUID, profilesOtherThan profiles: Set<String>) {
        guard let listed = otherDashboards[dashboardID] else { return }
        let kept = listed.filter { profiles.contains($0.profile) }
        if kept != listed { otherDashboards[dashboardID] = kept.isEmpty ? nil : kept }
        otherReadProfiles[dashboardID] = otherReadProfiles[dashboardID]?.intersection(profiles)
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
        if !listed.contains(where: { $0.id == banner.id }) { self.banner = nil }
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
