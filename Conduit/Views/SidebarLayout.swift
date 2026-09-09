//
//  SidebarLayout.swift
//  Conduit
//
//  Presentation policy for the sessions sidebar. iPhone and compact iPad
//  windows keep the modal drawer; wide iPad windows with the user opt-in
//  host the same SidebarView as a persistent leading column. The decision
//  logic is pure so it can be tested without hosting UI.
//

import SwiftUI

/// How the inbox / sessions surface is currently presented.
enum SidebarPresentation {
    /// Compact layout uses inbox navigation (legacy name: drawer).
    case drawer
    /// Persistent column beside the chat on wide iPad windows. Part of the
    /// root layout — it never touches `appState.showSidebar`.
    case persistent
}

/// Centralized metrics for the persistent sidebar layout.
enum SidebarLayoutMetrics {
    /// Width of the persistent sidebar column.
    static let persistentSidebarWidth: CGFloat = 320
    /// Minimum width the conversation column keeps beside the persistent
    /// sidebar. Below this the layout falls back to the drawer so Split View,
    /// Stage Manager, and narrow resizable windows stay usable.
    static let minimumChatWidth: CGFloat = 430
    /// Windows narrower than this never activate the persistent layout.
    static let minimumPersistentLayoutWidth: CGFloat = persistentSidebarWidth + minimumChatWidth
}

enum SidebarLayoutPolicy {
    /// Resolves how the sessions sidebar should be presented.
    ///
    /// iPhone always uses the drawer. iPad uses the persistent column only
    /// when the user opted in AND the window is wide enough to keep a usable
    /// conversation beside it.
    static func resolvePresentation(
        idiom: UIUserInterfaceIdiom,
        prefersPersistentSidebar: Bool,
        availableWidth: CGFloat
    ) -> SidebarPresentation {
        guard idiom == .pad, prefersPersistentSidebar else { return .drawer }
        guard availableWidth >= SidebarLayoutMetrics.minimumPersistentLayoutWidth else { return .drawer }
        return .persistent
    }

    /// Whether a preferred-return-surface request should present Inbox.
    /// An active persistent sidebar already *is* the Inbox surface, so it
    /// consumes the request without a redundant navigation; compact layouts
    /// present Inbox when it is not already showing.
    static func shouldPresentDrawerForReturnSurface(
        persistentSidebarActive: Bool,
        drawerPresented: Bool
    ) -> Bool {
        if persistentSidebarActive { return false }
        return !drawerPresented
    }
}
