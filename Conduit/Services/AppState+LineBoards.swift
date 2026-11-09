//
//  AppState+LineBoards.swift
//  Conduit
//
//  The boards the open chat's replies name by line (LineBoards): read from
//  the plugin's /boards/desktop once each, when a reply naming one shows.
//

import Foundation

/// What the chat reads its line boards again on: the boards its replies
/// name, and whether the plugin reports the route yet.
struct LineBoardsReadKey: Equatable {
    let ids: [String: [String]]
    let ready: Bool
}

extension AppState {
    /// Reads each board `ids` names that isn't read or being read. One the
    /// plugin answered for but Conduit can't draw isn't asked for again (its
    /// reply reads as it is); one whose read failed is, when its chat shows
    /// again or the plugin reports the route.
    func loadLineBoards(_ ids: [String]) {
        var seen: Set<String> = []  // two replies can name one board
        let wanted = ids.filter { lineBoards[$0] == nil && !lineBoardsAsked.contains($0) && seen.insert($0).inserted }
        guard !wanted.isEmpty, lineBoardsReadOverride != nil || notifierPlugin.reports(LineBoards.capability) else {
            return
        }
        lineBoardsAsked.formUnion(wanted)
        let profile = activeProfile
        let read = lineBoardsReadOverride
        for id in wanted {
            let path = LineBoards.readPath(profile: profile, id: id)
            Task { [weak self] in
                let answer: [String: Any]?
                do {
                    if let read {
                        answer = try await read(path)
                    } else if let bridge = self?.dashboardTicketBridge {
                        answer = try await bridge.requestJSON(path: path)
                    } else {
                        answer = nil
                    }
                } catch {
                    self?.lineBoardsAsked.remove(id)  // asked again later
                    return
                }
                guard let self, let answer, let board = LineBoards.board(answer, id: id) else { return }
                self.lineBoards[id] = board
            }
        }
    }
}
