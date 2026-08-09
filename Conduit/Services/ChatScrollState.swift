import Foundation

struct ChatScrollSnapshot: Equatable {
    let anchorMessageID: String?
    let followsLatest: Bool

    static let latest = ChatScrollSnapshot(anchorMessageID: nil, followsLatest: true)
}

struct ChatScrollStateStore {
    private var snapshots: [String: ChatScrollSnapshot] = [:]

    mutating func save(_ snapshot: ChatScrollSnapshot, for sessionID: String) {
        let key = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        snapshots[key] = snapshot
    }

    func snapshot(for sessionID: String) -> ChatScrollSnapshot? {
        snapshots[sessionID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func restoration(
        for sessionID: String,
        availableMessageIDs: Set<String>
    ) -> ChatScrollSnapshot? {
        guard let snapshot = snapshot(for: sessionID) else { return nil }
        guard !snapshot.followsLatest else { return .latest }
        guard let anchor = snapshot.anchorMessageID,
              availableMessageIDs.contains(anchor) else {
            return .latest
        }
        return snapshot
    }
}
