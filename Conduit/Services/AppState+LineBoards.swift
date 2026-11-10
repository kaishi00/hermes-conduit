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
    /// plugin no longer has, or answered for in a shape Conduit can't draw,
    /// is gone: not asked for again, and its reply says a board was there
    /// (issue 2093). One whose read failed otherwise is asked again, when
    /// its chat shows again or the plugin reports the route.
    func loadLineBoards(_ ids: [String]) {
        // Board ids are the host's own: another Hermes or profile reads afresh.
        let scope = "\(activeDashboardID?.uuidString ?? "")/\(activeProfile)"
        if lineBoardsScope != scope {
            lineBoardsScope = scope
            lineBoards = [:]
            lineBoardsGone = []
            lineBoardsAsked = []
        }
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
                    guard let self, self.lineBoardsScope == scope else { return }
                    if Self.lineBoardIsGone(error) {
                        self.lineBoardsGone.insert(id)  // stays asked: the plugin said it's gone
                    } else {
                        self.lineBoardsAsked.remove(id)  // asked again later
                    }
                    return
                }
                guard let self, self.lineBoardsScope == scope else { return }  // read for another host
                guard let answer else {
                    self.lineBoardsAsked.remove(id)  // no bridge yet: asked again later
                    return
                }
                guard let board = LineBoards.board(answer, id: id) else {
                    self.lineBoardsGone.insert(id)
                    return
                }
                self.lineBoards[id] = board
            }
        }
    }

    /// The plugin answered that it has no such board (404 "That board is
    /// gone", or an id it won't read), rather than that it couldn't answer.
    nonisolated static func lineBoardIsGone(_ error: Error) -> Bool {
        guard case DashboardTicketBridgeError.http(let status, _) = error else { return false }
        return [400, 404, 410].contains(status)
    }
}
