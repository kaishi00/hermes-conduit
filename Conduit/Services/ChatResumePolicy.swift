import Foundation

enum ChatResumeBehavior: String, Codable, CaseIterable {
    case continueWhereLeftOff
    case latestActivity
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
