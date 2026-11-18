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
    /// How many times `removeAll` ran: a composer loaded before a clear
    /// doesn't put its draft back after it.
    private(set) var clearCount: UInt64 = 0
    /// How many times each dashboard's drafts went on their own (a sign-out
    /// of a dashboard not on screen).
    private var dashboardClearCounts: [UUID: UInt64] = [:]

    init(capacity: Int = 12) {
        self.capacity = max(0, capacity)
    }

    func draft(for key: ComposerDraftKey) -> ComposerDraft {
        guard let draft = drafts[key] else { return .empty }
        touch(key)
        return draft
    }

    func save(_ draft: ComposerDraft, for key: ComposerDraftKey) {
        if draft.isEmpty {
            removeDraft(for: key)
            return
        }

        guard capacity > 0 else {
            removeDraft(for: key)
            return
        }

        drafts[key] = draft
        refreshGeneration(for: key)
        touch(key)
        evictIfNeeded(in: key.dashboard)
    }

    func hasDraft(for key: ComposerDraftKey) -> Bool {
        drafts[key] != nil
    }

    /// The keys with a draft, most recently used first.
    var keys: [ComposerDraftKey] {
        order.reversed()
    }

    /// A submission that failed goes back into its chat's draft, above
    /// anything typed there since: neither is lost.
    func restoreFailedSubmission(_ draft: ComposerDraft, for key: ComposerDraftKey) {
        save(self.draft(for: key).restoring(draft), for: key)
    }

    func migrateDraft(from source: ComposerDraftKey, to destination: ComposerDraftKey) {
        guard source != destination, let draft = drafts[source] else { return }
        removeDraft(for: source)
        save(draft, for: destination)
    }

    func submissionBucket(for key: ComposerDraftKey) -> ComposerDraftSubmissionBucket {
        ComposerDraftSubmissionBucket(key: key, generation: generations[key])
    }

    func removeDraft(for key: ComposerDraftKey) {
        drafts.removeValue(forKey: key)
        generations.removeValue(forKey: key)
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

    /// Drafts kept under `dashboard` (nil: a server with no saved
    /// dashboard) go, with no clear count moved: for ones nothing can load.
    func removeDraftsKept(under dashboard: UUID?) {
        for key in drafts.keys.filter({ $0.dashboard == dashboard }) {
            removeDraft(for: key)
        }
    }

    /// The clears a draft of `dashboard` has to outlast: every store-wide
    /// one, and its own dashboard's. A send from a dashboard signed out
    /// meanwhile doesn't put its words back, and the dashboard on screen's
    /// composer still keeps its draft (#2708).
    func clearCount(for dashboard: UUID?) -> UInt64 {
        clearCount &+ (dashboard.flatMap { dashboardClearCounts[$0] } ?? 0)
    }

    func removeAll() {
        clearCount &+= 1
        drafts.removeAll()
        generations.removeAll()
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
