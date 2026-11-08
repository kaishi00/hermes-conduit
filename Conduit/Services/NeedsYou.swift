//
//  NeedsYou.swift
//  Conduit
//
//  Hermes is waiting on you, across chats and profiles (issue 1705): every
//  chat with an approval or a question waiting on the user, read from the
//  plugin's list of them (GET /waiting, one profile at a time). It feeds the
//  count on each profile's chip, the banner when another chat starts
//  waiting, and the Needs you list. None of them answers anything: each
//  opens the chat at its card (AppState+NeedsYou).
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

    var id: String { "\(profile)\u{1F}\(waitID)" }

    init(
        waitID: String,
        profile: String,
        kind: Kind,
        sessionIDs: [String],
        title: String = "",
        summary: String = "",
        questions: Int = 0,
        since: Date = Date()
    ) {
        self.waitID = waitID
        self.profile = profile
        self.kind = kind
        self.sessionIDs = sessionIDs
        self.title = title
        self.summary = summary
        self.questions = questions
        self.since = since
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
            since: at.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        )
    }

    /// What the chat waits on, in the App Language.
    var kindLine: String {
        switch kind {
        case .approval: return AppLocalization.string("Approval needed")
        case .question where questions > 1: return AppLocalization.string("\(Int(questions)) questions")
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
    /// A wait that began since the last read, in a chat other than the open one.
    @Published private(set) var banner: NeedsYouItem?

    /// The dashboard these were read on: another one's are dropped.
    private(set) var dashboardID: UUID?
    /// Profiles read at least once on this dashboard: the first read of one
    /// shows no banner for what already waited there.
    private var readProfiles: Set<String> = []
    private var seen: Set<String> = []
    private var reading = false
    private var readAgain = false

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
        if let banner, !merged.contains(where: { $0.id == banner.id }) { self.banner = nil }
        guard !firstRead, let newest = fresh.filter({ !isOpenChat($0) }).max(by: { $0.since < $1.since }) else { return }
        // Another profile read in the same refresh may have shown a newer one.
        if let banner, banner.since > newest.since { return }
        banner = newest
    }

    /// A profile no longer listed (removed, or its plugin can't be read).
    func forget(profilesOtherThan profiles: Set<String>) {
        let kept = items.filter { profiles.contains($0.profile) }
        if kept != items { items = kept }
        readProfiles = readProfiles.intersection(profiles)
        if let banner, !kept.contains(where: { $0.id == banner.id }) { self.banner = nil }
    }

    func dismissBanner(_ item: NeedsYouItem? = nil) {
        guard let banner, item == nil || item?.id == banner.id else { return }
        self.banner = nil
    }

    func reset(dashboardID: UUID?) {
        self.dashboardID = dashboardID
        readProfiles = []
        seen = []
        if !items.isEmpty { items = [] }
        banner = nil
    }
}
