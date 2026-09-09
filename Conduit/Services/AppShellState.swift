import Foundation
import SwiftUI

/// Compact shell presentation owner for the authenticated root.
///
/// Owns whether Inbox or Conversation is the compact destination, the current
/// conversation-open request, list transient presentation state, and which
/// messaging destination (if any) occupies the conversation host. It does
/// not own selected session identity, recovery, transport, or turn state —
/// those remain on `AppState`. Messaging IDs never enter Hermes session keys.
@MainActor
final class AppShellState: ObservableObject {
    enum CompactRoute: Equatable, Hashable {
        case inbox
        case conversation
    }

    struct ConversationOpenRequest: Equatable {
        let generation: UInt64
        let sessionID: String?
        let reason: Reason

        enum Reason: Equatable {
            case rowSelection
            case newConversation
            case notification
            case voice
            case branch
            case project
            case scheduled
            case resume
            case returnSurface
        }
    }

    @Published private(set) var compactRoute: CompactRoute = .inbox
    /// When non-nil, the conversation host shows messaging instead of ChatView.
    @Published private(set) var messagingDestination: MessagingDestination?
    /// One-shot: after leaving messaging, Inbox should open this profile's sessions sheet.
    @Published private(set) var pendingSessionsProfile: String?
    @Published var isConversationSearchActive = false
    @Published var conversationSearchText = ""
    @Published var isCreatingConversation = false

    private(set) var openRequestGeneration: UInt64 = 0
    private(set) var pendingOpen: ConversationOpenRequest?

    /// Transient list UI that must reset when the active profile changes.
    func resetListTransientState() {
        isConversationSearchActive = false
        conversationSearchText = ""
    }

    /// Begins an explicit conversation presentation. Returns the generation
    /// that must be admitted before the route may change.
    @discardableResult
    func beginConversationOpen(
        sessionID: String?,
        reason: ConversationOpenRequest.Reason
    ) -> UInt64 {
        openRequestGeneration &+= 1
        let request = ConversationOpenRequest(
            generation: openRequestGeneration,
            sessionID: sessionID,
            reason: reason
        )
        pendingOpen = request
        return request.generation
    }

    /// Admits a completed open against the current request. A superseded
    /// asynchronous open must not push an old destination.
    @discardableResult
    func admitConversationOpen(
        generation: UInt64,
        sessionID: String?
    ) -> Bool {
        guard let pending = pendingOpen, pending.generation == generation else {
            return false
        }
        if let expected = pending.sessionID, let sessionID,
           expected != sessionID {
            return false
        }
        pendingOpen = nil
        messagingDestination = nil
        compactRoute = .conversation
        isCreatingConversation = false
        return true
    }

    /// Rejects a pending open without changing the current route.
    func rejectConversationOpen(generation: UInt64) {
        guard pendingOpen?.generation == generation else { return }
        pendingOpen = nil
        isCreatingConversation = false
    }

    func showInbox() {
        pendingOpen = nil
        isCreatingConversation = false
        messagingDestination = nil
        compactRoute = .inbox
    }

    func showConversationWithoutOpenRequest() {
        // Persistent iPad already shows chat beside inbox; compact callers
        // that only need to reveal an already-selected conversation use this.
        // Hermes session reveal clears any messaging overlay.
        messagingDestination = nil
        compactRoute = .conversation
    }

    /// Present a DM or group in the conversation host without touching Hermes
    /// session identity.
    func showMessaging(_ destination: MessagingDestination) {
        pendingOpen = nil
        isCreatingConversation = false
        pendingSessionsProfile = nil
        messagingDestination = destination
        compactRoute = .conversation
    }

    func clearMessagingDestination() {
        messagingDestination = nil
    }

    /// Leave messaging for inbox, then ask Inbox to open the profile's sessions.
    func requestProfileSessionsAfterMessaging(_ profile: String) {
        pendingOpen = nil
        isCreatingConversation = false
        messagingDestination = nil
        pendingSessionsProfile = profile
        compactRoute = .inbox
    }

    func consumePendingSessionsProfile() -> String? {
        let value = pendingSessionsProfile
        pendingSessionsProfile = nil
        return value
    }

    /// Prefer Inbox for return-surface presentation without inventing a
    /// second foreground observer. Persistent layouts consume without a push.
    static func shouldPresentInboxForReturnSurface(
        persistentSidebarActive: Bool,
        alreadyShowingInbox: Bool
    ) -> Bool {
        if persistentSidebarActive { return false }
        return !alreadyShowingInbox
    }
}
