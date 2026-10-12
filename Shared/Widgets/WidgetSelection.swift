import Foundation

enum WidgetTitleCopy: Equatable {
    case openConduit
    case openConduitToRefresh
    case resumeChat
    case cached(String)

    var sourceValue: String {
        switch self {
        case .openConduit: "Open Conduit"
        case .openConduitToRefresh: "Open Conduit to refresh"
        case .resumeChat: "Resume chat"
        case let .cached(value): value
        }
    }
}

struct WidgetEntryModel {
    let titleCopy: WidgetTitleCopy
    let dashboardLabel: String
    let profileLabel: String
    let resumeLink: WidgetLaunchLink
    let newChatLink: WidgetLaunchLink?
    let talkLink: WidgetLaunchLink?

    /// Kept for source compatibility in selection tests and nonlocalized diagnostics.
    var title: String { titleCopy.sourceValue }
}

enum WidgetSelection {
    static func resolve(
        snapshot: WidgetSnapshot?,
        workspace: WidgetWorkspaceID?,
        conversation: WidgetConversationReference?,
        conversationWorkspace: WidgetWorkspaceID? = nil,
        hideTitle: Bool = false
    ) -> WidgetEntryModel {
        let selectedID = workspace ?? snapshot?.currentWorkspaceID
        let hasInvalidWorkspace = selectedID.map { !$0.isValid } ?? false
        let selected = hasInvalidWorkspace ? nil : selectedID.flatMap { id in snapshot?.workspaces.first { $0.id == id } }
        let reference = conversation ?? selected?.lastConversation
        let hasMismatchedConversationOwner = conversation != nil && conversationWorkspace != nil && conversationWorkspace != selectedID
        let resumeCandidate: WidgetLaunchLink? = {
            guard let selectedID, let reference else { return nil }
            return WidgetLaunchLink(action: .resume, workspace: selectedID, reference: reference)
        }()
        let hasInvalidTarget = hasInvalidWorkspace ||
            (!hasMismatchedConversationOwner && reference != nil && resumeCandidate == nil)
        let choice = reference.flatMap { ref in selected?.choices.first { $0.reference == ref } }

        if hasInvalidTarget {
            let recoveryWorkspace = selectedID.flatMap { $0.isValid ? $0 : nil }
            return WidgetEntryModel(
                titleCopy: .openConduitToRefresh,
                dashboardLabel: "",
                profileLabel: "",
                resumeLink: scopedRecovery(workspace: recoveryWorkspace),
                newChatLink: nil,
                talkLink: nil
            )
        }

        if hasMismatchedConversationOwner {
            return WidgetEntryModel(
                titleCopy: .openConduitToRefresh,
                dashboardLabel: selected?.dashboardLabel ?? "",
                profileLabel: selected?.profileLabel ?? "",
                resumeLink: scopedRecovery(workspace: selectedID),
                newChatLink: selectedID.flatMap { WidgetLaunchLink(action: .newChat, workspace: $0, reference: nil) },
                talkLink: selectedID.flatMap { WidgetLaunchLink(action: .talk, workspace: $0, reference: nil) }
            )
        }

        let hasMissingWorkspace = selectedID != nil && selected == nil
        let title: WidgetTitleCopy
        if hasMissingWorkspace || (reference != nil && choice == nil) {
            title = .openConduitToRefresh
        } else if selectedID == nil || reference == nil {
            title = .openConduit
        } else if hideTitle {
            title = .resumeChat
        } else {
            title = choice.map { .cached($0.title) } ?? .openConduitToRefresh
        }

        return WidgetEntryModel(
            titleCopy: title,
            dashboardLabel: selected?.dashboardLabel ?? "",
            profileLabel: selected?.profileLabel ?? "",
            resumeLink: resumeCandidate ?? scopedRecovery(workspace: selectedID),
            newChatLink: selectedID.flatMap { WidgetLaunchLink(action: .newChat, workspace: $0, reference: nil) },
            talkLink: selectedID.flatMap { WidgetLaunchLink(action: .talk, workspace: $0, reference: nil) }
        )
    }

    private static func scopedRecovery(workspace: WidgetWorkspaceID?) -> WidgetLaunchLink {
        if let link = WidgetLaunchLink(action: .open, workspace: workspace, reference: nil) { return link }
        guard let generic = WidgetLaunchLink(action: .open, workspace: nil, reference: nil) else {
            preconditionFailure("The static unscoped Open route must always be encodable")
        }
        return generic
    }
}
