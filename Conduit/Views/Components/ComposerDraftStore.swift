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

struct ComposerDraftKey: Hashable {
    static let newConversationSessionID = "new-conversation"

    var profile: String
    var sessionID: String

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
        evictIfNeeded()
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

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            drafts.removeValue(forKey: oldest)
            generations.removeValue(forKey: oldest)
        }
    }

    private func refreshGeneration(for key: ComposerDraftKey) {
        generations[key] = UUID()
    }
}
