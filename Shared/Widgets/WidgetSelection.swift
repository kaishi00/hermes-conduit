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

/// One of the workspace's other saved chats, listed by the large launcher
/// widget (issue 1532).
struct WidgetChatLink: Equatable {
    let title: String
    let isPinned: Bool
    let link: WidgetLaunchLink
}

struct WidgetEntryModel {
    let titleCopy: WidgetTitleCopy
    let dashboardLabel: String
    let profileLabel: String
    let resumeLink: WidgetLaunchLink
    let newChatLink: WidgetLaunchLink?
    let talkLink: WidgetLaunchLink?
    /// The workspace's other saved chats, pinned then recent, for the large
    /// size. Empty while the title is hidden or the widget needs a refresh.
    var moreChats: [WidgetChatLink] = []

    /// Kept for source compatibility in selection tests and nonlocalized diagnostics.
    var title: String { titleCopy.sourceValue }

    /// What the small size's single tap does: the configured action when
    /// its link exists, otherwise the conversation (or its recovery).
    func smallAction(_ wanted: LauncherSmallAction) -> LauncherSmallAction {
        switch wanted {
        case .conversation: .conversation
        case .newChat: newChatLink == nil ? .conversation : .newChat
        case .talk: talkLink == nil ? .conversation : .talk
        }
    }

    func smallLink(_ wanted: LauncherSmallAction) -> WidgetLaunchLink {
        switch smallAction(wanted) {
        case .conversation: resumeLink
        case .newChat: newChatLink ?? resumeLink
        case .talk: talkLink ?? resumeLink
        }
    }
}

enum WidgetSelection {
    /// How many other chats the large size lists under the shown one.
    static let moreChatsLimit = 4

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
            talkLink: selectedID.flatMap { WidgetLaunchLink(action: .talk, workspace: $0, reference: nil) },
            moreChats: hideTitle || title == .openConduitToRefresh ? [] : moreChats(in: selected, excluding: reference)
        )
    }

    /// The workspace's saved chats other than the shown one, in the
    /// snapshot's order (the last chat used, then pinned, then recent).
    private static func moreChats(in workspace: WidgetWorkspaceSnapshot?, excluding shown: WidgetConversationReference?) -> [WidgetChatLink] {
        guard let workspace else { return [] }
        let links = workspace.choices.lazy
            .filter { $0.reference != shown }
            .compactMap { choice in
                WidgetLaunchLink(action: .resume, workspace: workspace.id, reference: choice.reference)
                    .map { WidgetChatLink(title: choice.title, isPinned: choice.isPinned, link: $0) }
            }
        return Array(links.prefix(moreChatsLimit))
    }

    private static func scopedRecovery(workspace: WidgetWorkspaceID?) -> WidgetLaunchLink {
        if let link = WidgetLaunchLink(action: .open, workspace: workspace, reference: nil) { return link }
        guard let generic = WidgetLaunchLink(action: .open, workspace: nil, reference: nil) else {
            preconditionFailure("The static unscoped Open route must always be encodable")
        }
        return generic
    }
}
