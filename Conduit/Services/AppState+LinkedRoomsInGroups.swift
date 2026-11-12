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
        guard !ids.contains(id) else { return }
        objectWillChange.send()
        ids.append(id)
        defaults.set(Array(ids.suffix(200)), forKey: Self.dismissedRoomInvitesKey)
    }
}

