//
//  PcControl.swift
//  Conduit
//
//  Control from Hermes (plugin 0.205+, `pc-asks`): which chat's bot is
//  controlling which of the user's computers, from the plugin's
//  `GET /pc/state`, for the line over that chat with Stop
//  (`POST /pc/stop`). The ask itself is a confirm prompt
//  (PresentedComputer in PresentedScreens.swift).
//

import Foundation

/// One computer a chat is controlling: it acted there in the last minute.
struct PcControlling: Equatable, Identifiable {
    let computer: String
    /// The computer's name, as the user gave it in Conduit for desktop.
    let name: String
    /// The Hermes session driving it.
    let session: String
    let chat: String

    var id: String { computer }

    static let capability = "pc-asks"
    static let statePath = "/api/plugins/conduit_push/pc/state"
    static let stopPath = "/api/plugins/conduit_push/pc/stop"
    /// How often the line is read while the chat's turn runs.
    static let refreshInterval: Duration = .seconds(4)

    init(computer: String, name: String, session: String, chat: String) {
        self.computer = computer
        self.name = name
        self.session = session
        self.chat = chat
    }

    init?(json: Any) {
        guard let entry = json as? [String: Any],
              let computer = entry["computer"] as? String, !computer.isEmpty,
              let session = entry["session"] as? String, !session.isEmpty
        else { return nil }
        let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(computer: computer, name: String(name.prefix(80)), session: session,
                  chat: String(((entry["chat"] as? String) ?? "").prefix(120)))
    }

    /// The computers `/pc/state` lists.
    static func all(response: [String: Any]) -> [PcControlling] {
        (response["controlling"] as? [Any] ?? []).compactMap(PcControlling.init(json:))
    }

    /// The one the open chat drives, by any id it goes by.
    static func forChat(_ list: [PcControlling], sessionIDs: Set<String>) -> PcControlling? {
        list.first { sessionIDs.contains($0.session) }
    }
}
