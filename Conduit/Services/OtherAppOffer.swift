//
//  OtherAppOffer.swift
//  Conduit
//
//  Conduit for desktop, offered from here (docs/FEATURE_MAP.md, Each app
//  points to the other). Conduit names itself on its gateway socket
//  (X-Conduit-Platform: ios, beside X-Conduit-Client), and the plugin notes
//  which Conduit apps reach a host (/link-status's `clients`, plugin 0.207).
//  Chats shows a card once, under the last chat, only where no Conduit for
//  desktop has used the host and this phone never paired a computer, after
//  Conduit has been used on three days; sharing its link or closing it
//  retires it for good. Settings > About > Conduit for desktop is there at
//  any time.
//

import Foundation

enum OtherAppOffer {
    static let desktopURL = URL(string: "https://hermesconduit.app/desktop/")!
    static let linkStatusPath = "/api/plugins/conduit_push/link-status"
    static let platformHeader = "X-Conduit-Platform"
    static let platform = "ios"
    /// Days Conduit was used before the card shows: never on the first run.
    static let daysBeforeOffer = 3

    static let daysKey = "conduit.otherApp.days"
    static let doneKey = "conduit.otherApp.desktopCardDone"
    static let pairedComputerKey = "conduit.otherApp.pairedComputer"

    struct HostClients: Equatable {
        /// Conduit for desktop has reached this host, on any profile.
        var desktopSeen: Bool
        /// It has a socket open there now.
        var desktopOpen: Bool
    }

    /// /link-status's answer; nil for a plugin before 0.207, which doesn't say.
    static func hostClients(from response: [String: Any]) -> HostClients? {
        guard let clients = response["clients"] as? [String: Any],
              let desktop = clients["desktop"] as? [String: Any] else { return nil }
        let open = ((desktop["open_sockets"] as? NSNumber)?.intValue ?? 0) > 0
        let seen = desktop["seen_at"] is NSNumber
        return HostClients(desktopSeen: seen || open, desktopOpen: open)
    }

    /// The card shows only when nothing says this person already has Conduit for desktop.
    static func offersDesktop(_ clients: HostClients?, daysUsed: Int, done: Bool, pairedComputer: Bool) -> Bool {
        guard !done, !pairedComputer, daysUsed >= daysBeforeOffer, let clients else { return false }
        return !clients.desktopSeen
    }

    /// Notes today as a day Conduit was used; returns how many days that
    /// makes. Counting stops at the threshold, so the list stays tiny.
    @discardableResult
    static func noteDayUsed(now: Date = Date(), calendar: Calendar = .current, defaults: UserDefaults = .standard) -> Int {
        var days = defaults.stringArray(forKey: daysKey) ?? []
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let today = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        if !days.contains(today), days.count < daysBeforeOffer {
            days.append(today)
            defaults.set(days, forKey: daysKey)
        }
        return days.count
    }

    static func isDone(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: doneKey)
    }

    /// Sharing the card's link, or closing it, retires it for good.
    static func retire(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: doneKey)
    }

    /// A computer paired from this phone runs Conduit for desktop.
    static func notePairedComputer(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pairedComputerKey)
    }

    static func pairedComputer(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pairedComputerKey)
    }

    /// Reads the dashboard in use's /link-status; nil when it can't say.
    @MainActor
    static func readHostClients(_ bridge: DashboardTicketBridge?) async -> HostClients? {
        guard let bridge,
              let response = try? await bridge.requestJSON(path: linkStatusPath, timeoutMilliseconds: 8_000) else { return nil }
        return hostClients(from: response)
    }

    /// Whether Chats shows the card now, for the dashboard in use.
    @MainActor
    static func shouldOfferDesktop(_ bridge: DashboardTicketBridge?) async -> Bool {
        let days = noteDayUsed()
        let eligible = HostClients(desktopSeen: false, desktopOpen: false)
        guard offersDesktop(eligible, daysUsed: days, done: isDone(), pairedComputer: pairedComputer()) else { return false }
        let clients = await readHostClients(bridge)
        return offersDesktop(clients, daysUsed: days, done: isDone(), pairedComputer: pairedComputer())
    }
}
