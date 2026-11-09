//
//  AppState+LineBoards.swift
//  Conduit
//
//  The boards the open chat's replies name by line (LineBoards): read from
//  the plugin's /boards/desktop once each, when a reply naming one shows.
//

import Foundation

extension AppState {
    /// Reads each board `ids` names that isn't read or being read. One
    /// that can't be read isn't asked for again: its reply reads as it is.
    func loadLineBoards(_ ids: [String]) {
        let wanted = ids.filter { lineBoards[$0] == nil && !lineBoardsAsked.contains($0) }
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
                if let read {
                    answer = try? await read(path)
                } else if let bridge = self?.dashboardTicketBridge {
                    answer = try? await bridge.requestJSON(path: path)
                } else {
                    answer = nil
                }
                guard let self, let answer, let board = LineBoards.board(answer, id: id) else { return }
                self.lineBoards[id] = board
            }
        }
    }
}
