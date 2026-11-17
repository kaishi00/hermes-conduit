//
//  AppState+LinkedRoomsInGroups.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Linked Rooms' drafts removed
//  from Group Chats; Linked Rooms' invites removed from Group Chats.
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

// MARK: - Linked Rooms' drafts removed from Group Chats

extension AppState {
    private static let dismissedRoomDraftsKey = "conduit.roomDrafts.dismissed.v1"

    /// The ended drafts removed from Group Chats (RoomDrafts.swift). Room
    /// ids are unique, so one list serves every dashboard; it keeps the
    /// newest 200.
    var dismissedRoomDraftIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.dismissedRoomDraftsKey) ?? [])
    }

    func dismissRoomDraft(_ roomID: String) {
        var ids = defaults.stringArray(forKey: Self.dismissedRoomDraftsKey) ?? []
        guard !ids.contains(roomID) else { return }
        objectWillChange.send()
        ids.append(roomID)
        defaults.set(Array(ids.suffix(200)), forKey: Self.dismissedRoomDraftsKey)
    }
}

// MARK: - Linked Rooms' invites removed from Group Chats

extension AppState {
    private static let dismissedRoomInvitesKey = "conduit.roomInvites.dismissed.v1"

    /// The invites removed from Group Chats once they started or ended
    /// (RoomInvites.swift), by their Link and room. One list serves every
    /// dashboard; it keeps the newest 200.
    var dismissedRoomInviteIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.dismissedRoomInvitesKey) ?? [])
    }

    func dismissRoomInvite(_ id: String) {
        var ids = defaults.stringArray(forKey: Self.dismissedRoomInvitesKey) ?? []
        if !ids.contains(id) {
            objectWillChange.send()
            ids.append(id)
            defaults.set(Array(ids.suffix(200)), forKey: Self.dismissedRoomInvitesKey)
        }
        removeRoomInviteOnHermes(id)
    }

    /// The Hermes takes it off too, so every phone stops listing it, not
    /// only this one (Eric, 2026-11-16: a withdrawn invite removed on one
    /// phone kept showing on another). Hidden here at once either way; a
    /// plugin before 0.177.23, or a failed request, leaves it hidden only
    /// here, as before.
    private func removeRoomInviteOnHermes(_ id: String) {
        guard notifierPlugin.reports(RoomInvitesClient.removeCapability),
              let invite = linkedRoomInvite(id), RoomInviteRows.canRemove(invite), !invite.removed else { return }
        let client = roomInvitesClient
        Task { @MainActor [weak self] in
            guard let removed = try? await client.remove(invite) else { return }
            self?.adoptLinkedRoomInvite(removed, from: client.dashboardID)
        }
    }
}

