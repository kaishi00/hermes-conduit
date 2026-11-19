import Foundation

struct ComposerDraft: Equatable {
    var text: String
    var attachments: [Attachment]
    /// A whole reply attached with its Quote button (#385).
    var replyReference: ComposerReplyReference? = nil

    static let empty = ComposerDraft(text: "", attachments: [])

    var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty && replyReference == nil
    }
}

/// A draft's chat: its dashboard as well as its profile and id, since two
/// dashboards can share profile names and ids. Drafts stay across a
/// dashboard switch (issue 2702: opening another combined dashboard's bot
/// switches dashboards).
struct ComposerDraftKey: Hashable {
    static let newConversationSessionID = "new-conversation"

    var dashboard: UUID?
    var profile: String
    var sessionID: String

    init(dashboard: UUID?, profile: String, sessionID: String) {
        self.dashboard = dashboard
        self.profile = profile
        self.sessionID = sessionID
    }

    var isNewConversation: Bool {
        sessionID == Self.newConversationSessionID
    }
}

struct ComposerDraftSubmissionBucket: Equatable {
    let key: ComposerDraftKey
    fileprivate let generation: UUID?
}

@MainActor
final class ComposerDraftStore {
    private let capacity: Int
    private var drafts: [ComposerDraftKey: ComposerDraft] = [:]
    private var order: [ComposerDraftKey] = []
    private var generations: [ComposerDraftKey: UUID] = [:]
    /// The durable id of the chat each draft was saved for, when the list
    /// named one: a key's runtime id can later be handed to another chat
    /// (issue 2782), and the draft stays its own chat's.
    private var owners: [ComposerDraftKey: String] = [:]
    /// How many times `removeAll` ran: a composer loaded before a clear
    /// doesn't put its draft back after it.
    private(set) var clearCount: UInt64 = 0
    /// How many times each dashboard's drafts went on their own (a sign-out
    /// of a dashboard not on screen).
    private var dashboardClearCounts: [UUID: UInt64] = [:]
    /// How many times a server with no saved dashboard had its drafts go
    /// on their own (a switch to a saved dashboard).
    private var unsavedServerClearCount: UInt64 = 0

    init(capacity: Int = 12) {
        self.capacity = max(0, capacity)
    }

    func draft(for key: ComposerDraftKey) -> ComposerDraft {
        guard let draft = drafts[key] else { return .empty }
        touch(key)
        return draft
    }

    /// Saves `draft` under `key`. `owner`, the durable id of the chat it's
    /// for, replaces the one kept; nil keeps it (the same key's chat).
    func save(_ draft: ComposerDraft, for key: ComposerDraftKey, owner: String? = nil) {
        if draft.isEmpty {
            removeDraft(for: key)
            return
        }

        guard capacity > 0 else {
            removeDraft(for: key)
            return
        }

        drafts[key] = draft
        if let owner, !owner.isEmpty { owners[key] = owner }
        refreshGeneration(for: key)
        touch(key)
        evictIfNeeded(in: key.dashboard)
    }

    func hasDraft(for key: ComposerDraftKey) -> Bool {
        drafts[key] != nil
    }

    /// The durable id of the chat the draft under `key` was saved for, nil
    /// when the list named none then.
    func owner(of key: ComposerDraftKey) -> String? {
        drafts[key] == nil ? nil : owners[key]
    }

    /// The keys with a draft, most recently used first.
    var keys: [ComposerDraftKey] {
        order.reversed()
    }

    /// A submission that failed goes back into its chat's draft, above
    /// anything typed there since: neither is lost. `owner` is the durable
    /// id of the chat it's for, as `save` takes it.
    func restoreFailedSubmission(_ draft: ComposerDraft, for key: ComposerDraftKey, owner: String? = nil) {
        save(self.draft(for: key).restoring(draft), for: key, owner: owner)
    }

    func migrateDraft(from source: ComposerDraftKey, to destination: ComposerDraftKey) {
        guard source != destination, let draft = drafts[source] else { return }
        let owner = owners[source]
        removeDraft(for: source)
        save(draft, for: destination, owner: owner)
    }

    /// A draft whose key's runtime id now names another chat goes back
    /// under its own chat's durable id (issue 2782), joined with anything
    /// kept there, so neither chat loses words and the other chat never
    /// shows them.
    func returnDraft(from source: ComposerDraftKey, toOwner owner: String) {
        let destination = ComposerDraftKey(dashboard: source.dashboard, profile: source.profile, sessionID: owner)
        guard source != destination, let draft = drafts[source] else { return }
        removeDraft(for: source)
        save(self.draft(for: destination).restoring(draft), for: destination, owner: owner)
    }

    func submissionBucket(for key: ComposerDraftKey) -> ComposerDraftSubmissionBucket {
        ComposerDraftSubmissionBucket(key: key, generation: generations[key])
    }

    func removeDraft(for key: ComposerDraftKey) {
        drafts.removeValue(forKey: key)
        generations.removeValue(forKey: key)
        owners.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    func removeDraft(for bucket: ComposerDraftSubmissionBucket) {
        guard let generation = bucket.generation,
              generations[bucket.key] == generation else { return }
        removeDraft(for: bucket.key)
    }

    /// A sign-out of a dashboard that isn't on screen: its drafts go, the
    /// other dashboards' stay. Only that dashboard's clear count moves, so
    /// the composer on screen still keeps its own.
    func removeDrafts(forDashboard dashboard: UUID) {
        dashboardClearCounts[dashboard, default: 0] &+= 1
        removeDraftsKept(under: dashboard)
    }

    /// The drafts a server with no saved dashboard left go: nothing can
    /// load them once a saved dashboard is in use. Their clear count moves,
    /// so a composer leaving that server doesn't save its draft back.
    func removeUnsavedServerDrafts() {
        unsavedServerClearCount &+= 1
        removeDraftsKept(under: nil)
    }

    private func removeDraftsKept(under dashboard: UUID?) {
        for key in drafts.keys.filter({ $0.dashboard == dashboard }) {
            removeDraft(for: key)
        }
    }

    /// The clears a draft of `dashboard` has to outlast: every store-wide
    /// one, and its own dashboard's. A send from a dashboard signed out
    /// meanwhile doesn't put its words back, and the dashboard on screen's
    /// composer still keeps its draft (#2708).
    func clearCount(for dashboard: UUID?) -> UInt64 {
        clearCount &+ (dashboard.map { dashboardClearCounts[$0] ?? 0 } ?? unsavedServerClearCount)
    }

    func removeAll() {
        clearCount &+= 1
        drafts.removeAll()
        generations.removeAll()
        owners.removeAll()
        order.removeAll()
    }

    private func touch(_ key: ComposerDraftKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// The cap is each dashboard's: drafts outlive a switch, so one
    /// dashboard's never push out another's (#2708).
    private func evictIfNeeded(in dashboard: UUID?) {
        var held = order.filter { $0.dashboard == dashboard }
        while held.count > capacity {
            removeDraft(for: held.removeFirst())
        }
    }

    private func refreshGeneration(for key: ComposerDraftKey) {
        generations[key] = UUID()
    }
}
