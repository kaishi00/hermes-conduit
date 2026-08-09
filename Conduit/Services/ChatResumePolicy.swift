import Foundation

enum ChatResumeBehavior: String, Codable, CaseIterable {
    case continueWhereLeftOff
    case latestActivity
}

extension ChatResumeBehavior {
    var title: String {
        switch self {
        case .continueWhereLeftOff:
            "Continue where I left off"
        case .latestActivity:
            "Jump to latest activity"
        }
    }
}

enum ChatResumeSyncPurpose: Equatable {
    case automaticReturn
    case preserveCurrent
}

enum ChatResumeSessionResolver {
    static func target(
        in catalog: [SessionSummary],
        behavior: ChatResumeBehavior,
        purpose: ChatResumeSyncPurpose,
        savedSessionID: String?,
        currentSessionID: String?
    ) -> SessionSummary? {
        let requestedID = purpose == .preserveCurrent ? currentSessionID : savedSessionID
        if purpose == .preserveCurrent || behavior == .continueWhereLeftOff,
           let requestedID,
           let matched = catalog.first(where: {
               $0.id == requestedID || $0.alternateIds.contains(requestedID)
           }) {
            return matched
        }
        return catalog.first(where: { $0.source == .chat })
    }
}

enum ChatResumeViewportDestination: Equatable {
    case latest
    case anchor(String)
}

enum ChatResumeViewportResolver {
    static func destination(
        for snapshot: ChatScrollSnapshot,
        availableTargets: ChatScrollTargetAvailability
    ) -> ChatResumeViewportDestination {
        guard !snapshot.followsLatest else { return .latest }
        if let anchor = snapshot.anchorMessageID,
           availableTargets.contains(anchor),
           snapshot.anchorMetadata == nil
            || availableTargets.metadata(for: anchor) == snapshot.anchorMetadata {
            return .anchor(anchor)
        }

        guard let sourceMessageID = snapshot.anchorSourceMessageID,
              let refreshedAnchor = availableTargets.semanticID(
                forSourceMessageID: sourceMessageID
              ),
              availableTargets.metadata(for: refreshedAnchor) != nil else {
            return .latest
        }
        return .anchor(refreshedAnchor)
    }
}
