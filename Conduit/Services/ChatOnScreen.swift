//
//  ChatOnScreen.swift
//  Conduit
//
//  Tells the notifier plugin which chat Conduit has on screen while its
//  reply runs, so the reply that lands there sends no "reply ready" push
//  (plugin chat_on_screen.py, 0.55+). Conduit on the iPhone already hides
//  a banner while it's in front; this covers the paired iPhone and its
//  Watch while the user reads on a Mac or an iPad, and the moments around a
//  reply on the phone itself.
//
//  Only while a turn runs in the open chat, and only while someone used
//  Conduit in the last two minutes: an idle chat left open sends nothing,
//  and a long turn left running on a Mac lets its reply push. The renewal stretches with Low Power and Low Data Mode like the
//  app's other timed reads (PowerPolicy.swift), and the hold stays three
//  renewals long, so a stretched renewal never lets it lapse.
//

import Foundation

enum ChatOnScreen {
    static let capability = "chat-on-screen"
    static let path = "/api/plugins/conduit_push/notifications/on-screen"
    /// How often a held chat is renewed while its turn runs, before
    /// `DeviceConditions` stretch it.
    static let renewal: TimeInterval = 30
    /// The hold covers this many renewals: one lost on the way doesn't end it.
    static let renewalsPerHold = 3
    /// The plugin's own bound (chat_on_screen.py MAX_HOLD_S).
    static let maximumHoldSeconds = 600
    /// The plugin's own bound (chat_on_screen.py MAX_IDS).
    static let maximumIDs = 16
    /// A report never holds a send or a scene change up; it gives up after this.
    static let timeoutMilliseconds = 5_000
    /// Nobody has touched or typed in Conduit for this long: a long turn on a
    /// Mac or an iPad that never locks is likely being left, so its hold is
    /// released and its reply pushes, as Desktop's 2-minute rule does.
    static let engagedWindow: TimeInterval = 120

    /// What the host holds: a chat, by its own ids, under a profile.
    struct Claim: Equatable {
        var profile: String
        var sessionIDs: [String]

        init(profile: String, sessionIDs: some Sequence<String>) {
            self.profile = profile
            self.sessionIDs = Array(Set(sessionIDs).filter { !$0.isEmpty }.sorted().prefix(ChatOnScreen.maximumIDs))
        }
    }

    /// Whether the connected plugin takes on-screen reports.
    static func isTaken(by plugin: NotifierPluginStatus) -> Bool {
        plugin.reports(capability)
    }

    /// The device kind the plugin keeps one hold for. CarPlay and Siri are
    /// where a message came from, never where a chat is read.
    @MainActor static var device: String {
        switch TurnSurface.device {
        case .ipad: return "ipad"
        case .mac: return "mac"
        case .vision: return "vision"
        case .iphone, .carplay, .siri: return "iphone"
        }
    }

    /// The wait between renewals under `conditions`.
    static func renewalInterval(under conditions: DeviceConditions) -> TimeInterval {
        PollCadence.stretched(renewal, by: conditions)
    }

    /// The hold a renewal every `interval` asks for.
    static func holdSeconds(renewingEvery interval: TimeInterval) -> Int {
        min(maximumHoldSeconds, Int((interval * Double(renewalsPerHold)).rounded(.up)))
    }

    /// The route's body: `claim` held for `holdSeconds`, or released (0).
    static func body(device: String, claim: Claim?, holdSeconds: Int) -> [String: Any] {
        guard let claim, holdSeconds > 0 else { return ["device": device, "hold_s": 0] }
        return ["device": device, "session_ids": claim.sessionIDs, "hold_s": min(holdSeconds, maximumHoldSeconds)]
    }
}

extension ChatOnScreen {
    /// What Conduit has told the host, and what to tell it next.
    struct Tracker: Equatable {
        enum Action: Equatable {
            /// Hold `claim` now and renew it until `stopRenewing`.
            case startRenewing(Claim)
            /// Stop renewing; the last hold runs out on its own, so the
            /// reply's own hooks still see it.
            case stopRenewing
            /// The user left the chat: the host holds nothing for this device.
            case release(Claim)
        }

        /// The chat the host may still hold, renewed or running out.
        private(set) var held: Claim?
        private(set) var isRenewing = false

        /// `wanted` is the chat on screen, nil when none is (another chat,
        /// the list, Conduit not in front, a plugin without the route).
        mutating func update(wanted: Claim?, turnRunning: Bool) -> [Action] {
            var actions: [Action] = []
            if let held, held != wanted {
                if isRenewing {
                    isRenewing = false
                    actions.append(.stopRenewing)
                }
                // The same chat learning another id mid-turn: the next hold
                // replaces this one, with nothing let go in between.
                if !(wanted != nil && turnRunning) {
                    actions.append(.release(held))
                }
                self.held = nil
            }
            guard let wanted else { return actions }
            if turnRunning {
                if !isRenewing {
                    isRenewing = true
                    held = wanted
                    actions.append(.startRenewing(wanted))
                }
            } else if isRenewing {
                isRenewing = false
                actions.append(.stopRenewing)
            }
            return actions
        }
    }
}

/// The notifications a chat on screen has made read (#1579): those this
/// device holds for the chat, under any of its ids, that a tap would open
/// here (NotificationDashboardOwnership, as routing decides). One that
/// waits on the user (an approval, a question, a call, a calendar change)
/// stays until it's answered, and one Conduit can't read never matches.
/// Session ids are the host's own and unique across its profiles, so a
/// Bot Chat's pushes clear with it whichever profile is in use.
@MainActor
enum ReadChatNotifications {
    static let waitingTypes: Set<String> = ["approval.needed", "input.needed", "call.requested", "phone.changes"]

    static func identifiers(
        of delivered: [(identifier: String, target: ConduitNotificationTarget?)],
        sessionIDs: Set<String>,
        activeDashboardID: UUID?,
        savedDashboardIDs: [UUID],
        activeDashboardGatewayIDs: Set<String>
    ) -> [String] {
        delivered.compactMap { identifier, target in
            guard let target, !waitingTypes.contains(target.type ?? ""), target.decision == nil, target.call == nil,
                  sessionIDs.contains(target.sessionId)
                    || target.durableSessionID.map({ sessionIDs.contains($0) }) == true,
                  NotificationDashboardOwnership.resolve(
                    targetDashboardID: target.dashboardID,
                    hasMalformedDashboardID: target.hasMalformedDashboardID,
                    activeDashboardID: activeDashboardID,
                    savedDashboardIDs: savedDashboardIDs,
                    targetGatewayID: target.relayGatewayID,
                    activeDashboardGatewayIDs: activeDashboardGatewayIDs
                  ) == .route else { return nil }
            return identifier
        }
    }
}
