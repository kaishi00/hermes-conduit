//
//  AppState+RoomBoards.swift
//  Conduit
//
//  The open room's boards: read from the plugin's /boards/rooms when the
//  room opens and when one of its agents posts, and drawn under each
//  agent's message (RoomBoards).
//

import Foundation

extension AppState {
    /// The open room's boards, by the event id of the message each goes under.
    var activeRoomPlacedBoards: [String: [RichBoard]] {
        RoomBoard.placed(activeRoomBoards, in: activeRoomReplay.events)
    }

    func roomReplayChanged(from old: GroupRoomReplay) {
        let latest = activeRoomReplay.events.last(where: \.isMemberMessage)?.seq
        guard activeRoomReplay.roomID != old.roomID || latest != old.events.last(where: \.isMemberMessage)?.seq
        else { return }
        refreshActiveRoomBoards()
    }

    func refreshActiveRoomBoards() {
        roomBoardsTask?.cancel()
        let roomID = activeRoomReplay.roomID
        guard !roomID.isEmpty, notifierPlugin.reports(RoomBoard.capability) else {
            if !activeRoomBoards.isEmpty { activeRoomBoards = [] }
            return
        }
        let path = RoomBoard.readPath(profile: activeProfile, roomID: roomID)
        let read = roomBoardsReadOverride
        roomBoardsTask = Task { [weak self] in
            let answer: [String: Any]?
            if let read {
                answer = try? await read(path)
            } else if let bridge = self?.dashboardTicketBridge {
                answer = try? await bridge.requestJSON(path: path)
            } else {
                answer = nil
            }
            guard let answer else { return }
            guard let self, !Task.isCancelled, self.activeRoomReplay.roomID == roomID else { return }
            let boards = RoomBoard.boards(answer)
            if boards != self.activeRoomBoards { self.activeRoomBoards = boards }
        }
    }
}
