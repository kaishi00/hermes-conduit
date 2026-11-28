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
    /// The chat's title. Kept from the plugin's payload; the line names
    /// the bot instead, since it shows in that chat.
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

    /// Where the chat's line stood: its chat, its dashboard, which of the
    /// chat's turns (counted by the line, from each time one starts), and
    /// whether a turn runs.
    struct Moment: Equatable {
        let chat: String?
        let dashboard: UUID?
        let turn: Int
        let busy: Bool
    }

    /// What a Stop's answer does to the line.
    enum StopLanding: Equatable {
        /// The chat, the dashboard or the turn changed meanwhile: left alone.
        case ignore
        /// Stopped: the line stays away.
        case hide
        /// Couldn't reach the host: the line comes back for that computer, saying so.
        case failed(computer: String)
    }

    /// A Stop's answer counts only for the chat it was pressed in, on the
    /// same dashboard and in the same turn (issue 3424): a turn that ended,
    /// or another that started since, is left alone.
    static func stopLanding(stopped: Bool, computer: String, pressed: Moment, now: Moment) -> StopLanding {
        guard now.busy, now.chat == pressed.chat, now.dashboard == pressed.dashboard, now.turn == pressed.turn else { return .ignore }
        return stopped ? .hide : .failed(computer: computer)
    }

    /// The computer whose failed Stop the line still names after a read:
    /// kept only while the read still shows that computer.
    static func failedStop(_ failedOn: String?, after read: PcControlling?) -> String? {
        read?.computer == failedOn ? failedOn : nil
    }
}
