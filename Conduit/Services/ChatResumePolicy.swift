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
        currentSessionID: String?,
        activeProfile: String? = nil
    ) -> SessionSummary? {
        // Filter to the active profile when available so sessions from
        // other profiles don't interfere with ID matching or fallback.
        // Use case-insensitive comparison to match AppState.profilesMatch.
        let scoped = activeProfile.map { profile in
            catalog.filter { entry in
                guard let entryProfile = entry.profile else { return true }
                return entryProfile.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(profile.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }
        } ?? catalog

        let requestedID = purpose == .preserveCurrent ? currentSessionID : savedSessionID
        if purpose == .preserveCurrent || behavior == .continueWhereLeftOff,
           let requestedID,
           let matched = scoped.first(where: {
                $0.id == requestedID || $0.alternateIds.contains(requestedID)
           }) {
            return matched
        }
        return scoped.first(where: { $0.source == .chat })
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
