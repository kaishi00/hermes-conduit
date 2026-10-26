import Foundation
import UIKit
import UserNotifications
import os

private let pushTokenLogger = Logger(subsystem: "com.milim.relay", category: "PushToken")

/// A block observer that's removed when its owner goes away.
private final class NotificationObserverToken {
    var token: NSObjectProtocol?
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

struct ConduitNotificationTarget: Equatable, Identifiable {
    let profile: String?
    /// The bot's name in Hermes as the Bots list shows it (`profile_name`),
    /// for a call screen to name the caller; nil when Hermes gave it none or
    /// an older notifier didn't say. Never routes: `profile` does. Only calls
    /// read it, and a call's payload is the copy that carries it.
    let profileName: String?
    /// The runtime identity the notification names. Hermes notifications
    /// identify the live routing session; this is never treated as a durable
    /// conversation id on its own.
    let sessionId: String
    /// The durable conversation identity when the payload explicitly carries
    /// one (`stored_session_id`, or Hermes-native `session_key`). Optional:
    /// older notifier builds send routing only, and a nil value must degrade
    /// to alias resolution — never to reinterpreting the runtime id as
    /// durable.
    let durableSessionID: String?
    /// The opaque Conduit dashboard UUID the relay stamped onto the push
    /// (multi-server routing, #148). Nil for pre-dashboard relays and
    /// gateways.
    let dashboardID: UUID?
    /// The authenticated relay gateway's opaque id — the decision-routing
    /// discriminator. Retained with a pushed relay decision and echoed back
    /// when answering it, so same-id decisions parked by two gateways can
    /// never be cross-answered. Purely relay-routing metadata: it is NOT
    /// Conduit's saved-dashboard identity (that is `dashboardID`).
    let relayGatewayID: String?
    /// The payload carried a `dashboard_id` that is not a valid UUID. That
    /// identity cannot be matched to any saved dashboard, so routing must
    /// fail closed instead of degrading to the legacy unscoped route.
    let hasMalformedDashboardID: Bool
    let type: String?
    /// Structured decision content carried alongside a decision notification.
    /// Lets Conduit render an answerable card from the push payload alone when
    /// the one-shot gateway stream event was missed while the app was
    /// backgrounded. Nil for non-decision notifications.
    let decision: PendingDecisionPayload?
    /// The call a "Hermes wants to talk" notification carries (#449); nil
    /// for every other notification.
    let call: HermesCallRequest?
    /// Opened from a chat link (`conduit://session/<id>?profile=…&dashboard=…`),
    /// not a notification. Neither switches profile or dashboard while a call
    /// runs (`call == nil` decides that), since the switch would end the
    /// call: a chat link says to end it, as it can be tapped again then, and
    /// a notification, gone once tapped, opens when the call ends.
    let isChatLink: Bool
    var id: String { "\(dashboardID?.uuidString ?? "none"):\(relayGatewayID ?? "nogw"):\(profile ?? "default"):\(sessionId):\(type ?? "")" }

    init(
        profile: String?,
        profileName: String? = nil,
        sessionId: String,
        durableSessionID: String? = nil,
        dashboardID: UUID? = nil,
        hasMalformedDashboardID: Bool = false,
        relayGatewayID: String? = nil,
        type: String?,
        decision: PendingDecisionPayload? = nil,
        call: HermesCallRequest? = nil,
        isChatLink: Bool = false
    ) {
        self.profile = profile
        self.profileName = profileName
        self.sessionId = sessionId
        self.durableSessionID = durableSessionID
        self.dashboardID = dashboardID
        self.hasMalformedDashboardID = hasMalformedDashboardID
        self.relayGatewayID = relayGatewayID
        self.type = type
        self.decision = decision
        self.call = call
        self.isChatLink = isChatLink
    }
}

/// Dashboard ownership gate for push routing (#148 / B3): a push originating
/// from dashboard A must never be processed against active dashboard B, even
/// when profile, session, and request ids all collide. Resolution is pure so
/// the collision matrix is exhaustively testable.
@MainActor
enum NotificationDashboardOwnership {
    enum Failure: Equatable {
        /// The payload named a dashboard UUID (valid or malformed) that no
        /// saved dashboard claims.
        case unrecognizedDashboard
        /// The payload carries no dashboard identity and more than one
        /// dashboard is saved: ownership cannot be established without
        /// guessing, so it fails closed.
        case unscopedPush
    }

    enum Outcome: Equatable {
        /// The push belongs to the active dashboard (or is a legacy unscoped
        /// push with at most one saved dashboard): route normally.
        case route
        /// The push belongs to another KNOWN saved dashboard: switch/connect
        /// that dashboard first; only after it is active may the decision be
        /// recorded or the session opened.
        case switchFirst(dashboardID: UUID)
        /// Ownership cannot be established: never open, never record.
        case failClosed(Failure)
    }

    static func resolve(
        targetDashboardID: UUID?,
        hasMalformedDashboardID: Bool,
        activeDashboardID: UUID?,
        savedDashboardIDs: [UUID],
        targetGatewayID: String? = nil,
        activeDashboardGatewayIDs: Set<String> = []
    ) -> Outcome {
        if hasMalformedDashboardID {
            return .failClosed(.unrecognizedDashboard)
        }
        // The push came from the host the active dashboard is signed in to:
        // that host told this dashboard its relay gateway id, over its
        // signed-in connection and only for a pairing with this iPhone. A
        // pairing bound to another saved entry for the same host (or to one
        // since removed) still belongs here, and switching away would tear
        // down the connection that can open it. The id comes from the relay
        // stamp, as `dashboard_id` does: the relay is already trusted to
        // route.
        if activeDashboardID != nil, let targetGatewayID,
           activeDashboardGatewayIDs.contains(targetGatewayID) {
            return .route
        }
        if let id = targetDashboardID {
            if id == activeDashboardID { return .route }
            if savedDashboardIDs.contains(id) { return .switchFirst(dashboardID: id) }
            return .failClosed(.unrecognizedDashboard)
        }
        // Legacy push without a dashboard identity: retain single-dashboard
        // compatibility, but never guess between several saved dashboards.
        return savedDashboardIDs.count <= 1
            ? .route
            : .failClosed(.unscopedPush)
    }
}

/// The structured card content for a decision notification. Approval is
/// session-keyed (`approval.respond { choice, session_id }`), so a payload
/// carrying the session key is fully answerable. Clarify is keyed by a
/// plugin-minted id (`conduit-push-…`) whose answers return through the push
/// relay rather than the gateway — the gateway's own clarify id is unreachable
/// to plugins (see the background-arrival design docs).
enum PendingDecisionPayload: Equatable, Codable {
    case approval(sessionKey: String, description: String, choices: [String])
    case clarify(requestId: String, question: String, choices: [String])
    /// Batch decision payload (current notifier): the full question set with
    /// gateway qids preserved. Consumed into the same `ClarifyActivity`
    /// batch model as native clarifies — no separate push card exists.
    case clarifyBatch(requestId: String, questions: [ClarifyQuestion])

    /// Request ids minted by the notifier plugin's clarify loop; answers to
    /// these route through the relay instead of `clarify.respond`.
    static let relayRequestPrefix = "conduit-push-"
}

/// A tap waiting for a call, as PushNotificationService keeps it across a
/// relaunch: what its open needs (a notification's, so it carries no call
/// and is no chat link), and when its wait began.
private struct WaitingTap: Codable {
    let profile: String?
    let profileName: String?
    let sessionId: String
    let durableSessionID: String?
    let dashboardID: UUID?
    let relayGatewayID: String?
    let type: String?
    let decision: PendingDecisionPayload?
    let waitingSince: Date
}

/// Relay + paired-plugin compatibility state (`GET /v1/meta`), rendered in
/// Settings > Notifications so users can see when the notifier plugin or the
/// relay needs an update for decision cards to work. Capability flags (not
/// version parsing) drive the checks; a relay without the endpoint (older or
/// self-hosted pre-0.2) surfaces as `nil` and renders an unknown state.
struct RelayMetaInfo: Decodable, Equatable {
    struct Gateway: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let pluginVersion: String?
        let pluginCapabilities: [String]
        let lastEventAt: String?
        /// The opaque Conduit dashboard UUID this gateway's pairing is bound
        /// to (#148). Nil for gateways paired through a pre-dashboard relay —
        /// their pushes arrive unscoped and routing applies the legacy
        /// single-dashboard compatibility rule.
        let dashboardID: String?

        var supportsApprovalCards: Bool { pluginCapabilities.contains("approval-decisions") }
        var supportsClarifyCards: Bool { pluginCapabilities.contains("clarify-loop") }

        /// A gateway that has sent events but never reported a plugin version
        /// runs a pre-0.2 notifier — every 0.2+ event carries the version, so
        /// any version-less event is one. Only this evidence justifies the
        /// update prompt; a gateway that has sent nothing stays "waiting".
        var hasSentEventsButNeverReported: Bool { pluginVersion == nil && lastEventAt != nil }

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case pluginVersion = "plugin_version"
            case pluginCapabilities = "plugin_capabilities"
            case lastEventAt = "last_event_at"
            case dashboardID = "dashboard_id"
        }
    }

    let version: String
    let capabilities: [String]
    let gateways: [Gateway]

    var supportsDecisionCards: Bool { capabilities.contains("decisions") }
    /// The relay sends the agent's on-demand locate to a location push token.
    var supportsLocationPush: Bool { capabilities.contains("location-push") }

    /// One malformed gateway record must not hide the whole section: decode
    /// gateway rows lossily so a single incompatible record degrades to just
    /// its row while the relay and other gateways still render.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        var gateways: [Gateway] = []
        var array = try container.nestedUnkeyedContainer(forKey: .gateways)
        while !array.isAtEnd {
            if let gateway = try? array.decode(Gateway.self) {
                gateways.append(gateway)
            } else {
                _ = try? array.decode(Empty.self)
            }
        }
        self.gateways = gateways
    }

    private struct Empty: Decodable {}

    private enum CodingKeys: String, CodingKey {
        case version
        case capabilities
        case gateways
    }
}

/// The relay's gateway list sorted by dashboard for Settings > Notifications.
/// The relay lists every gateway paired with this iPhone, across all saved
/// dashboards, so showing the list as-is reads another dashboard's notifier
/// as this one's. Sorting uses the same ownership rule push routing applies,
/// so each row says what a push from that pairing would actually do.
struct NotificationDashboardPairings: Equatable {
    /// Pairings whose pushes route to the active dashboard.
    private(set) var thisDashboard: [RelayMetaInfo.Gateway] = []
    /// Pairings from before dashboard scoping while several dashboards are
    /// saved: their pushes fail closed until they are paired again.
    private(set) var unscoped: [RelayMetaInfo.Gateway] = []
    /// Pairings that belong to another saved dashboard.
    private(set) var otherDashboardsCount = 0
    /// Pairings bound to a dashboard no longer saved on this iPhone (or a
    /// malformed binding): routing fails them closed, and there is nothing
    /// to switch to.
    private(set) var unrecognizedCount = 0

    /// Pairings are judged against the selected dashboard. With none
    /// selected (it was just removed) there is nothing to judge them
    /// against: routing's one-dashboard fallback would otherwise list a
    /// legacy pairing as the selected dashboard's, and "your other
    /// dashboards" would be relative to nothing. Nothing is listed or counted.
    @MainActor
    init(
        gateways: [RelayMetaInfo.Gateway],
        activeDashboardID: UUID?,
        savedDashboardIDs: [UUID],
        activeDashboardGatewayIDs: Set<String> = []
    ) {
        guard activeDashboardID != nil else { return }
        for gateway in gateways {
            // Parsed like a push payload's `dashboard_id`: blank is unscoped,
            // anything else that isn't a UUID is malformed.
            let raw = gateway.dashboardID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let dashboardID = UUID(uuidString: raw)
            let outcome = NotificationDashboardOwnership.resolve(
                targetDashboardID: dashboardID,
                hasMalformedDashboardID: !raw.isEmpty && dashboardID == nil,
                activeDashboardID: activeDashboardID,
                savedDashboardIDs: savedDashboardIDs,
                targetGatewayID: gateway.id,
                activeDashboardGatewayIDs: activeDashboardGatewayIDs
            )
            switch outcome {
            case .route:
                thisDashboard.append(gateway)
            case .failClosed(.unscopedPush):
                unscoped.append(gateway)
            case .switchFirst:
                otherDashboardsCount += 1
            case .failClosed(.unrecognizedDashboard):
                unrecognizedCount += 1
            }
        }
    }
}

/// Transport policy for the user-configurable relay URL. The pairing
/// credential is a bearer secret: it is only sent over HTTPS, with one
/// clearly bounded exception — plain HTTP to a loopback host, where the
/// credential never leaves the machine (self-hosted local relay
/// development). Arbitrary cleartext relays are refused rather than
/// silently allowed.
enum RelayTransportPolicy {
    static func allowsCredentialTransport(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        if scheme == "http", let host = url.host?.lowercased() {
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }
        return false
    }
}

/// MainActor-scoped like the identity index it consults; every caller
/// (AppState routing, notification handling, tests) already runs there.
@MainActor
enum NotificationSessionResolver {
    /// How a notification's routing identity was resolved to the conversation
    /// it opens. The basis is diagnostics vocabulary: it names the evidence
    /// source that decided the route, never the conversation's content.
    enum RouteBasis: Equatable {
        /// The payload explicitly carried the durable id.
        case explicitDurable
        /// A live catalog row positively contains the runtime id.
        case catalogAlias
        /// The shared identity index holds a positively confirmed mapping.
        case confirmedAlias
        /// No positive durable evidence exists. The notification's own
        /// runtime id is resumed directly — the legacy behavior, and the
        /// only id this route may name: an unknown runtime identity is never
        /// reinterpreted as some other conversation's durable id.
        case legacyRuntime
    }

    struct Route: Equatable {
        /// The id a `session.resume` should address.
        let resumeTargetID: String
        /// The positively established durable identity, when one exists.
        let durableSessionID: String?
        let basis: RouteBasis
    }

    /// Resolves a notification target to the conversation it should open.
    ///
    /// Priority is the evidence hierarchy: an explicit durable id outranks
    /// everything; a live catalog row containing the runtime id is next (the
    /// freshest positive alias evidence); the confirmed identity index
    /// fills the gap a stale or omitted catalog leaves; and only when NO
    /// positive durable evidence exists does the raw runtime id flow
    /// through. There is deliberately no newest-chat, ordering, or
    /// similarity fallback: a notification can only ever open the
    /// conversation its payload named.
    static func route(
        target: ConduitNotificationTarget,
        catalog: [SessionSummary],
        identityIndex: ConversationIdentityIndex,
        profile: String
    ) -> Route {
        let runtimeID = target.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let durable = target.durableSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !durable.isEmpty {
            return Route(
                resumeTargetID: durable,
                durableSessionID: durable,
                basis: .explicitDurable
            )
        }
        // Catalog rows are scoped like the rest of identity resolution: an
        // explicitly labeled foreign-profile row never routes this profile's
        // notification (nil stays caller-scoped).
        if let row = catalog.first(where: { row in
            if let rowProfile = row.profile?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
               !rowProfile.isEmpty,
               rowProfile != profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                return false
            }
            return row.id == runtimeID || row.alternateIds.contains(runtimeID)
        }) {
            let durable = (row.storedSessionId ?? row.id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Route(
                resumeTargetID: durable,
                durableSessionID: durable,
                basis: .catalogAlias
            )
        }
        if let confirmed = identityIndex.durableID(forRuntime: runtimeID, profile: profile) {
            return Route(
                resumeTargetID: confirmed,
                durableSessionID: confirmed,
                basis: .confirmedAlias
            )
        }
        return Route(
            resumeTargetID: runtimeID,
            durableSessionID: nil,
            basis: .legacyRuntime
        )
    }
}

struct ConduitNotificationPreferences: Codable, Equatable {
    var enabled = true
    var approvalNeeded = true
    var inputNeeded = true
    var responseReady = true
    var turnFailed = true
    var backgroundTaskFinished = true
    var completionSound = true
    /// Sound for approval.needed / input.needed pushes. Those wait on the
    /// user (approvals time out and fail closed), so they chime by default.
    var attentionSound = true
    var showPreviews = false
    /// Independent of `showPreviews`: controls whether pushes carry structured
    /// decision content (answerable approval cards). Defaults on because the
    /// feature's audience is exactly the approval-gate crowd; privacy-focused
    /// users can turn just this off.
    var decisionCards = true

    enum CodingKeys: String, CodingKey {
        case enabled
        case approvalNeeded = "approval_needed"
        case inputNeeded = "input_needed"
        case responseReady = "response_ready"
        case turnFailed = "turn_failed"
        case backgroundTaskFinished = "background_task_finished"
        case completionSound = "completion_sound"
        case attentionSound = "attention_sound"
        case showPreviews = "show_previews"
        case decisionCards = "decision_cards"
    }
}

extension ConduitNotificationPreferences {
    /// Decoding must tolerate registrations persisted by older builds, which
    /// predate later-added keys — a `keyNotFound` failure would make the
    /// `try?` in the init drop the whole stored registration and silently
    /// disable push for an upgrading user. Every key falls back to its
    /// default when absent. (Declared in an extension so the synthesized
    /// `init()` is preserved.)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        approvalNeeded = try container.decodeIfPresent(Bool.self, forKey: .approvalNeeded) ?? true
        inputNeeded = try container.decodeIfPresent(Bool.self, forKey: .inputNeeded) ?? true
        responseReady = try container.decodeIfPresent(Bool.self, forKey: .responseReady) ?? true
        turnFailed = try container.decodeIfPresent(Bool.self, forKey: .turnFailed) ?? true
        backgroundTaskFinished = try container.decodeIfPresent(Bool.self, forKey: .backgroundTaskFinished) ?? true
        completionSound = try container.decodeIfPresent(Bool.self, forKey: .completionSound) ?? true
        attentionSound = try container.decodeIfPresent(Bool.self, forKey: .attentionSound) ?? true
        showPreviews = try container.decodeIfPresent(Bool.self, forKey: .showPreviews) ?? false
        decisionCards = try container.decodeIfPresent(Bool.self, forKey: .decisionCards) ?? true
    }
}

@MainActor
final class PushNotificationService: ObservableObject {
    static let shared = PushNotificationService(keptTaps: .standard)

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isWorking = false
    /// A pairing with a host is running (the button or the automatic one).
    @Published private(set) var isPairing = false
    @Published private(set) var lastError: String?
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiry: String?
    @Published private(set) var pendingTarget: ConduitNotificationTarget?
    @Published private(set) var navigationAttempt = 0
    /// The pending tap's open stopped for a call it would have ended: it
    /// waits, however long the call lasts, and opens once it has ended,
    /// unless a newer tap replaces it. It's kept in `keptTaps` meanwhile,
    /// so it waits again after a relaunch (`restoreWaitingTap`).
    @Published private(set) var pendingRouteAwaitsCall = false
    @Published var preferences = ConduitNotificationPreferences() {
        // The Notification Service Extension decides whether a decrypted
        // push shows its real text; it reads this from the App Group.
        didSet { NotificationSharedSettings.showPreviews = preferences.showPreviews }
    }
    /// Relay gateways this iPhone holds an end-to-end encryption key for
    /// (#431). Settings > Notifications marks those pairings encrypted.
    @Published private(set) var encryptedGatewayIDs: Set<String> = []
    /// What each host last said about its key (`GET /e2e`), so the padlock
    /// only shows when the host holds the same key as this iPhone.
    @Published private(set) var encryptionConfirmations: [String: EncryptionConfirmation] = PushNotificationService.loadEncryptionConfirmations()
    /// Settings > Notifications > Rotate: the next provisioning run gives
    /// every pairing that can rotate a new key.
    private var rotationRequested = false
    /// Inline rotations whose reply didn't arrive, by gateway: the host
    /// answers a resend with the same reply, so the new key isn't lost.
    private var pendingRotations: [String: NotificationKeyRotation.Pending] = [:]
    /// Pairings whose host took an inline rotation this iPhone verified but
    /// couldn't save to the Keychain. The rotation stays pending, so the next
    /// connect asks the host again; until then Settings > Notifications says
    /// so instead of showing a padlock for a key the host no longer uses.
    @Published private(set) var unsavedRotationGatewayIDs: Set<String> = []
    @Published private(set) var relayMeta: RelayMetaInfo? {
        // Plaintext from a pairing this iPhone has never seen listed isn't
        // trusted once it holds an encryption key (#431). Kept on failure.
        didSet {
            guard let relayMeta else { return }
            // A relay that sends locates now (or no longer) gets the token.
            if relayMeta.supportsLocationPush != oldValue?.supportsLocationPush { queueRegistrationUpdate() }
            NotificationSharedSettings.knownGatewayIDs = NotificationE2E.knownGatewayIDs(
                listed: Set(relayMeta.gateways.map(\.id)),
                previous: NotificationSharedSettings.knownGatewayIDs,
                // Keys that can't be read count as held.
                holdsKeys: NotificationSharedSettings.keysProvisioned || Self.e2eKeyStore.readRecords()?.isEmpty != true
            )
        }
    }
    @Published private(set) var isFetchingMeta = false
    /// The last metadata fetch didn't get an answer (`relayMeta` keeps the
    /// one before, if any).
    @Published private(set) var relayMetaFetchFailed = false
    /// The relay answered 404 to `/v1/meta` (it predates version reporting),
    /// so returning to the front doesn't ask it again.
    private var relayLacksMetaRoute = false
    /// Set after this phone moves to a different relay: pairings live on
    /// the relay, so every Hermes profile has to pair again.
    @Published private(set) var relayNotice: String?

    /// Relay decision-routing discriminators retained from parsed pushes:
    /// request id → the authenticated relay gateway id the push arrived
    /// from. Answering a parked decision echoes this back so two gateways
    /// holding same-id decisions can never be cross-answered. Session-only:
    /// a card restored after relaunch answers through the relay's legacy
    /// resolution (unambiguous → answered; ambiguous → fail closed).
    private var relayGatewayIDsByRequestID: [String: String] = [:]

    /// The discriminator to echo for this request id, if one was retained.
    func relayGatewayID(forRequestID requestID: String) -> String? {
        relayGatewayIDsByRequestID[requestID] ?? Self.encryptedDecisionGatewayIDs()[requestID]
    }

    /// Encrypted decisions keep their gateway across relaunches: the answer
    /// has to be sealed for that pairing, and plaintext is rejected. Only
    /// verified pushes are kept, newest last, capped.
    static let encryptedDecisionGatewaysKey = "conduit.e2e.decisionGateways"
    private static let encryptedDecisionGatewaysLimit = 64

    private static func encryptedDecisionGatewayIDs() -> [String: String] {
        let pairs = UserDefaults.standard.array(forKey: encryptedDecisionGatewaysKey) as? [[String]] ?? []
        var map: [String: String] = [:]
        for pair in pairs where pair.count == 2 { map[pair[0]] = pair[1] }
        return map
    }

    private func persistEncryptedGatewayID(for target: ConduitNotificationTarget) {
        guard let gatewayID = target.relayGatewayID else { return }
        let requestID: String
        switch target.decision {
        case .clarify(let id, _, _): requestID = id
        case .clarifyBatch(let id, _): requestID = id
        default: return
        }
        var pairs = (UserDefaults.standard.array(forKey: Self.encryptedDecisionGatewaysKey) as? [[String]] ?? [])
            .filter { $0.count == 2 && $0[0] != requestID }
        pairs.append([requestID, gatewayID])
        UserDefaults.standard.set(Array(pairs.suffix(Self.encryptedDecisionGatewaysLimit)), forKey: Self.encryptedDecisionGatewaysKey)
    }

    /// The respond body for a relay decision answer: answer, optional batch
    /// question scoping, and the retained gateway discriminator. Static so
    /// the wire contract is testable without the singleton.
    static func respondBody(
        requestID: String,
        answer: String,
        questionID: String? = nil,
        relayGatewayID: String?
    ) -> [String: String] {
        var body = ["answer": answer]
        if let questionID { body["question_id"] = questionID }
        if let relayGatewayID { body["gateway_id"] = relayGatewayID }
        return body
    }

    nonisolated static let relayURLDefaultsKey = "conduit.relayURL"
    /// Upstream's shared relay.
    nonisolated static let upstreamRelayURL = URL(string: "https://push.milim.dev")!
    /// The Info.plist key carrying the build's `CONDUIT_DEFAULT_RELAY_URL`.
    nonisolated static let defaultRelayInfoKey = "ConduitDefaultRelayURL"
    /// The relay used when Settings is blank: the one the build names, so a
    /// build signed for its own relay needs no source edit, else upstream's.
    nonisolated static let defaultRelayURL = buildDefaultRelayURL(info: Bundle.main.infoDictionary)

    /// The relay a build's Info.plist names, if it is a usable HTTPS relay
    /// URL; anything else (empty, unexpanded, cleartext) is upstream's relay.
    nonisolated static func buildDefaultRelayURL(info: [String: Any]?) -> URL {
        guard let value = (info?[defaultRelayInfoKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = usableRelayURL(value),
              url.scheme?.lowercased() == "https" else {
            return upstreamRelayURL
        }
        return url
    }

    /// The relay a saved Settings value points at. Blank (or
    /// whitespace-only) means the default relay, and so does anything
    /// without a host, which Settings would never have saved.
    nonisolated static func configuredRelayURL(from saved: String?) -> URL {
        if let trimmed = saved?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty,
           let url = usableRelayURL(trimmed) {
            return url
        }
        return defaultRelayURL
    }

    /// Whether a Settings value can be saved: blank (the default relay) or
    /// a URL with a host that the transport policy accepts (HTTPS, or HTTP
    /// to a loopback relay). Anything else would either silently fall back
    /// to the default in `configuredRelayURL(from:)` or be refused later,
    /// after it was already saved.
    nonisolated static func isValidRelayInput(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // Same check as `configuredRelayURL(from:)`, so a value that
        // passes here is exactly the relay that will be used.
        guard let url = usableRelayURL(trimmed) else {
            return false
        }
        return RelayTransportPolicy.allowsCredentialTransport(url)
    }

    /// The relay chosen in Settings > Notifications.
    var configuredRelayURL: URL {
        Self.configuredRelayURL(from: UserDefaults.standard.string(forKey: Self.relayURLDefaultsKey))
    }

    /// Where relay requests go: the relay that issued this phone's
    /// credential, so editing the Settings field never sends that
    /// credential to a different host. Only with no registration (nothing
    /// to leak) does the configured relay apply. An issuer that isn't a
    /// usable relay URL yields nil: its credential must not go anywhere,
    /// least of all to the configured relay.
    nonisolated static func requestRelayURL(issuer: String?, configured: URL) -> URL? {
        guard let issuer else { return configured }
        return usableRelayURL(issuer)
    }

    /// The one check for "is this a relay URL": it parses and names a
    /// host. Used for the configured relay, Settings input and stored
    /// issuers alike; anything else (e.g. "https:") is unusable.
    nonisolated static func usableRelayURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// Stands in for an unusable issuer. It fails the transport policy, so
    /// every credential-bearing request is refused before it is sent.
    nonisolated static let unusableRelayURL = URL(string: "unusable-relay:refused")!

    /// Whether two relay URLs name the same relay, ignoring cosmetic
    /// differences (case of scheme and host, default port, trailing
    /// slash) so an edit like adding "/" doesn't force a move and re-pair.
    /// An unusable issuer is never "the same", so Settings offers a move,
    /// which registers afresh and recovers.
    nonisolated static func isSameRelay(_ issuer: String?, _ configured: URL) -> Bool {
        guard let issuer, let issuerURL = usableRelayURL(issuer),
              let lhs = URLComponents(url: issuerURL, resolvingAgainstBaseURL: false),
              let rhs = URLComponents(url: configured, resolvingAgainstBaseURL: false) else {
            return false
        }
        func key(_ c: URLComponents) -> String {
            let scheme = c.scheme?.lowercased() ?? ""
            let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
            let port = c.port ?? defaultPort
            var path = c.path
            while path.hasSuffix("/") { path.removeLast() }
            return "\(scheme)://\(c.host?.lowercased() ?? ""):\(port.map(String.init) ?? "")\(path)"
        }
        return key(lhs) == key(rhs)
    }

    /// `applyRelayChange()` moves the registration when the configured
    /// relay changes.
    private var relayURL: URL {
        Self.requestRelayURL(issuer: registration?.relayURL, configured: configuredRelayURL)
            ?? Self.unusableRelayURL
    }
    /// The bundle ID the relay sends this app's pushes to: the app's own,
    /// so a build under another bundle ID registers as itself.
    private let bundleID = PushNotificationService.registrationBundleID(Bundle.main.bundleIdentifier)

    nonisolated static func registrationBundleID(_ identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return "com.milim.relay" }
        return identifier
    }

    private var registration: StoredRegistration? {
        didSet { relayHasLocationToken = registration?.locationToken != nil }
    }
    /// The relay holds this iPhone's location push token, so Hermes can ask
    /// it for a fresh position (Settings > Location says when not, #287).
    @Published private(set) var relayHasLocationToken = false
    /// Sends a registration update to the relay; tests answer it instead.
    var sendRegistrationUpdate: @MainActor (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }
    private var deviceToken: String?
    private var tokenContinuation: CheckedContinuation<String, Error>?
    /// Registration proof: the relay pushes a one-time nonce to the device
    /// token, and the registration (or a move to a new token) sends it back.
    private var awaitingTokenChallenge = false
    private var receivedTokenChallenge: String?
    private var tokenChallengeContinuation: CheckedContinuation<String, Error>?
    /// Callers waiting for another proof to finish: each nonce works once.
    private var tokenProofWaiters: [CheckedContinuation<Void, Never>] = []
    private var navigationRetryTask: Task<Void, Never>?
    /// Retrying a failed open is bounded by time from the tap, not by a
    /// count (#789): a cold launch on a slow network can fail several reads
    /// while it connects and loads the session catalog, and the tap should
    /// still open once it has. A disconnected app makes no attempt (the
    /// route waits for `isConnected`), and the reconnect retries the target
    /// while it is still pending.
    private var pendingRetryCount = 0
    private var pendingRouteDeadline: ContinuousClock.Instant?
    /// Whether an open of the pending tap has started, and when its
    /// scheduled retry last came due: the two that decide whether a run
    /// past the window may still open it (`beginNotificationRoute`).
    private var pendingRouteOpenStarted = false
    private var pendingRouteRetryFiredAt: ContinuousClock.Instant?
    /// How late after coming due a scheduled retry may still start past the
    /// window. Its run normally follows at once; one held back longer (the
    /// app was suspended meanwhile) is a late open like any other.
    private let scheduledRetryStartAllowance: Duration = .seconds(2)
    private let retryDelay: Duration
    private let maxRetryDelay: Duration = .seconds(8)
    private let routeRetryWindow: Duration
    private let now: () -> ContinuousClock.Instant
    /// Where a tap waiting for a call is kept (`WaitingTap`); nil keeps it
    /// only in memory.
    private let keptTaps: UserDefaults?
    private let date: () -> Date
    static let waitingTapKey = "conduit.notifications.waitingTap"
    /// How long after its wait began a kept tap still opens after a
    /// relaunch: closing Conduit ends a call on the phone, and a launch
    /// much later shouldn't switch workspace for an old tap.
    static let waitingTapLifetime: TimeInterval = 2 * 3600

    var isEnabled: Bool { registration != nil && preferences.enabled }
    var statusText: String {
        if isWorking { return AppLocalization.string("Updating") }
        if isEnabled { return AppLocalization.string("Enabled") }
        if authorizationStatus == .denied { return AppLocalization.string("Notifications denied") }
        return AppLocalization.string("Off")
    }

    init(
        retryDelay: Duration = .seconds(1),
        routeRetryWindow: Duration = .seconds(30),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        keptTaps: UserDefaults? = nil,
        date: @escaping () -> Date = Date.init
    ) {
        self.retryDelay = retryDelay
        self.routeRetryWindow = routeRetryWindow
        self.now = now
        self.keptTaps = keptTaps
        self.date = date
        if let data = KeychainHelper.loadPushRegistration(),
           var saved = try? JSONDecoder().decode(StoredRegistration.self, from: data) {
            // Registrations saved before the relay was recorded don't say
            // which relay issued them, and that can't be recovered. The
            // configured relay is where their requests have been going, so
            // it's the best guess; forcing a move instead would make every
            // existing user re-pair. If an older build changed the relay
            // after registering, the installation on the original relay
            // stays orphaned, as it already was.
            let needsRelayStamp = saved.relayURL == nil
            if needsRelayStamp {
                saved.relayURL = configuredRelayURL.absoluteString
            }
            registration = saved
            // didSet doesn't run in init.
            relayHasLocationToken = saved.locationToken != nil
            preferences = saved.preferences
            if needsRelayStamp { persistRegistration() }
        }
        NotificationSharedSettings.showPreviews = preferences.showPreviews
        NotificationSharedSettings.appLanguage = AppLanguage.current.rawValue
        refreshEncryptionState()
        restoreWaitingTap()
    }

    // MARK: End-to-end encryption (#431)

    /// Where pairing keys live: the Keychain, shared with the Notification
    /// Service Extension. The unsigned simulator host has no keychain access
    /// group, so tests pass records to the parameterized functions instead.
    static let e2eKeyStore: E2EKeyStoring = KeychainE2EKeyStore()
    /// Messages already routed from a tap, shared with the extension's
    /// delivery records.
    static let e2eSeenStore: E2ESeenStore = .shared

    static let e2ePath = "/api/plugins/conduit_push/e2e"
    /// Settings > Notifications disables Rotate while a run is under way.
    @Published private(set) var isProvisioningEncryption = false

    func refreshEncryptionState() {
        // Unreadable (a launch before first unlock): keep what was shown.
        guard let records = Self.e2eKeyStore.readRecords() else { return }
        encryptedGatewayIDs = Set(records.filter { $0.retiredAt == nil }.map(\.gatewayID))
        encryptionRecords = records
    }

    /// The stored keys as last read, for the padlock; nil until they could
    /// be read (before first unlock).
    @Published private(set) var encryptionRecords: [E2EKeyRecord]?

    /// What a host confirmed about its pairing's key.
    struct EncryptionConfirmation: Codable, Equatable {
        /// The key the host seals with.
        let kid: String
        /// The host's plugin keeps a replaced key, so this iPhone rotates.
        let rotates: Bool
    }

    /// Whether a pairing's notifications are private, for the padlock.
    enum EncryptionAssurance: Equatable {
        /// The host seals with a key only this iPhone holds, and it's fresh.
        case ensured(keyCreatedAt: Date, rotates: Bool, quantumSafe: Bool)
        /// This iPhone holds a key the host hasn't confirmed yet (it does
        /// on the next connect to its dashboard).
        case unconfirmed
        /// The host seals with a key this iPhone doesn't hold (lost, or a
        /// change that never finished): pushes show generic text until the
        /// next connect sets up a new one.
        case mismatched
        /// The key is past its rotation date and the grace period, so a
        /// rotation keeps failing.
        case overdue(keyCreatedAt: Date)
        case notEncrypted
    }

    nonisolated static func encryptionAssurance(
        gatewayID: String,
        installationID: String?,
        records: [E2EKeyRecord],
        confirmation: EncryptionConfirmation?,
        now: Date = Date()
    ) -> EncryptionAssurance {
        let current = NotificationE2E.currentRecord(gatewayID: gatewayID, installationID: installationID, records: records)
        guard let confirmation else { return current == nil ? .notEncrypted : .unconfirmed }
        guard let held = records.first(where: {
            $0.kid == confirmation.kid && $0.gatewayID == gatewayID && $0.installationID == installationID
        }) else {
            return .mismatched
        }
        if confirmation.rotates,
           now.timeIntervalSince(held.createdAt) >= NotificationE2E.keyMaxAge + NotificationE2E.previousKeyGrace {
            return .overdue(keyCreatedAt: held.createdAt)
        }
        return .ensured(keyCreatedAt: held.createdAt, rotates: confirmation.rotates,
                        quantumSafe: held.suite == NotificationKeyRotation.suitePQ)
    }

    func encryptionAssurance(gatewayID: String) -> EncryptionAssurance {
        // Keys that can't be read can't open anything: the row explains
        // that instead of waiting on a host check.
        guard let records = encryptionRecords else { return .notEncrypted }
        // The host moved to a key this iPhone couldn't save.
        if unsavedRotationGatewayIDs.contains(gatewayID) { return .mismatched }
        return Self.encryptionAssurance(
            gatewayID: gatewayID,
            installationID: registration?.installationID,
            records: records,
            confirmation: encryptionConfirmations[gatewayID]
        )
    }

    /// Whether any of these pairings can rotate its key now.
    func canRotateEncryptionKeys(gatewayIDs: [String]) -> Bool {
        gatewayIDs.contains { encryptionConfirmations[$0]?.rotates == true }
    }

    /// Settings > Notifications > Rotate: new keys on the next provisioning
    /// run, which the caller starts.
    func requestEncryptionKeyRotation() {
        rotationRequested = true
    }

    private static let encryptionConfirmationsKey = "conduit.e2e.confirmations"

    nonisolated private static func loadEncryptionConfirmations() -> [String: EncryptionConfirmation] {
        guard let data = UserDefaults.standard.data(forKey: encryptionConfirmationsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: EncryptionConfirmation].self, from: data)) ?? [:]
    }

    private func setEncryptionConfirmation(_ confirmation: EncryptionConfirmation?, gatewayID: String) {
        encryptionConfirmations[gatewayID] = confirmation
        if let data = try? JSONEncoder().encode(encryptionConfirmations) {
            UserDefaults.standard.set(data, forKey: Self.encryptionConfirmationsKey)
        }
    }

    /// The host's key for a pairing is the one this iPhone treats as
    /// current: a key the host took after a rotation whose answer never
    /// arrived comes back, and the others for the pairing are retired.
    private func adoptConfirmedKey(kid: String, installationID: String, gatewayID: String, records: inout [E2EKeyRecord], now: Date) {
        for (index, record) in records.enumerated()
        where record.installationID == installationID && record.gatewayID == gatewayID {
            let retiredAt: Date? = record.kid == kid ? nil : (record.retiredAt ?? now)
            guard retiredAt != record.retiredAt, Self.e2eKeyStore.save(record.retired(at: retiredAt)) else { continue }
            records[index] = record.retired(at: retiredAt)
        }
    }

    /// Gives every pairing of this dashboard's profiles that belongs to this
    /// iPhone an end-to-end encryption key, over the dashboard connection so
    /// the secret never passes through the relay. A pairing whose key the
    /// plugin already holds is left alone; one the plugin holds a key for
    /// that this iPhone lacks (a reinstall, or a save that never finished)
    /// gets a new one. The key only counts as established, and the
    /// downgrade rule only applies, after the plugin confirms it.
    func provisionEncryption(
        dashboardID: UUID,
        profiles: [String],
        request: (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]
    ) async {
        // One run at a time: two overlapping runs would each post a key for
        // the same pairing, and the plugin and this iPhone could keep
        // different ones.
        guard !isProvisioningEncryption, let installationID = registration?.installationID else { return }
        isProvisioningEncryption = true
        defer { isProvisioningEncryption = false }
        // Keys that can't be read right now: new ones would replace them on
        // the plugin and leave them orphaned here. Provisioning runs again on
        // the next connect.
        Self.e2eKeyStore.removeUnparseable()
        guard var records = Self.e2eKeyStore.readRecords() else { return }
        // Keys a rotation replaced over a week ago: the host dropped them too.
        let now = Date()
        let expiredKIDs = Set(NotificationE2E.expiredRecords(records, now: now).map(\.kid))
        for kid in expiredKIDs { Self.e2eKeyStore.remove(kid: kid) }
        records.removeAll { expiredKIDs.contains($0.kid) }
        // A marker with no keys means they are gone for good (a restore to
        // another iPhone drops this-device-only Keychain items but brings the
        // App Group marker back). Start over as on the first key; the marker
        // stays, so plaintext stays untrusted until then.
        let markerWasSet = NotificationSharedSettings.keysProvisioned
        // Keys without the marker (a lost file, or a reinstall that kept the
        // Keychain): put it back so unreadable keys still fail closed.
        if !records.isEmpty { guard NotificationSharedSettings.markKeysProvisioned() else { return } }
        if records.isEmpty && relayMeta == nil {
            // The keyless pairings plaintext stays trusted for are fixed when
            // the first key is stored: make sure they are known by then.
            await refreshMeta()
            // Without the relay's list the frozen set would be empty and
            // every keyless pairing would lose routing for good. Provisioning
            // runs again on the next connect.
            guard relayMeta != nil else { return }
        }
        // A tap on Rotate is used up only once a pairing got a new key; a run
        // that rotates nothing (no host reached, or none that can rotate)
        // keeps it for the next one.
        let forceRotation = rotationRequested
        rotationRequested = false
        var rotatedAny = false
        // Pairings that got a new key in this run, so a lost reply's resend
        // and a Rotate tap don't rotate the same pairing twice.
        var rotatedGateways: Set<String> = []
        defer {
            rotationRequested = Self.rotationStillRequested(
                atStart: forceRotation, tappedSince: rotationRequested, rotatedAny: rotatedAny
            )
        }
        for profile in profiles {
            let path = DashboardPath.withProfile(Self.e2ePath, profile: profile)
            guard let status = try? await request(path, "GET", nil) else { continue }
            // Unregistered or moved relays while the request was out: what
            // the host says is about a pairing this iPhone no longer has, so
            // no key is adopted, retired or rotated for it.
            guard registration?.installationID == installationID else { break }
            let rotates = Self.hostKeepsReplacedKeys(status: status)
            // Inline rotation (notifier 0.72+): the best suite both sides run.
            let inlineSuite = NotificationKeyRotation.suite(hostSuites: status["rotate_suites"] as? [String] ?? [])
            if let statusGateway = status["gateway_id"] as? String, let pending = pendingRotations[statusGateway],
               (status["e2e"] as? [String: Any])?["kid"] as? String == pending.kidNew {
                // The host took a rotation whose reply was lost, or whose key
                // couldn't be saved: ask again.
                let outcome = await finishInlineRotation(pending, dashboardID: dashboardID, profile: profile,
                                                         records: &records, request: request)
                if outcome == .rotated {
                    rotatedAny = true
                    rotatedGateways.insert(statusGateway)
                }
                // Still not saved: it stays pending for the next connect
                // rather than handing a key over through the dashboard now.
                // Otherwise the dashboard handover below stays the fallback.
                if outcome.waitsForNextConnect { continue }
            }
            guard let gatewayID = Self.gatewayNeedingEncryptionKey(status: status, installationID: installationID, records: records) else {
                if let held = Self.confirmedKey(status: status, installationID: installationID, records: records) {
                    adoptConfirmedKey(kid: held.kid, installationID: installationID, gatewayID: held.gatewayID, records: &records, now: now)
                    setEncryptionConfirmation(EncryptionConfirmation(kid: held.kid, rotates: rotates), gatewayID: held.gatewayID)
                    // The host seals with a key this iPhone holds: no new key
                    // is waiting to be saved.
                    unsavedRotationGatewayIDs.remove(held.gatewayID)
                    let hostAsks = status["rotate"] as? Bool == true || forceRotation
                    let rotatedThisRun = rotatedGateways.contains(held.gatewayID)
                    if let inlineSuite,
                       Self.wantsInlineRotation(held: held, suite: inlineSuite, hostAsks: hostAsks, rotatedThisRun: rotatedThisRun) {
                        if await rotateInline(held, suite: inlineSuite, dashboardID: dashboardID, profile: profile,
                                              records: &records, request: request) == .rotated {
                            rotatedAny = true
                            rotatedGateways.insert(held.gatewayID)
                        }
                    } else if rotates && hostAsks && !rotatedThisRun,
                              await rotateEncryptionKey(of: held, dashboardID: dashboardID, profile: profile, path: path,
                                                        records: &records, request: request) {
                        rotatedAny = true
                        rotatedGateways.insert(held.gatewayID)
                    }
                }
                continue
            }
            let record = NotificationE2E.newRecord(
                installationID: installationID,
                gatewayID: gatewayID,
                dashboardID: dashboardID.uuidString,
                profile: profile
            )
            let body: [String: Any] = [
                "installation_id": installationID,
                "gateway_id": gatewayID,
                "kid": record.kid,
                "secret": NotificationE2E.base64URL(record.secret),
            ]
            guard let response = try? await request(path, "POST", body),
                  response["ok"] as? Bool == true,
                  response["kid"] as? String == record.kid else {
                continue
            }
            // Unregistered or moved relays while the request was out: the
            // key belongs to a pairing this iPhone no longer has.
            guard registration?.installationID == installationID else { break }
            // The first key freezes the keyless pairings plaintext may still
            // come from, and the marker goes down before the key so no
            // stored key ever exists without it.
            let firstKey = records.isEmpty
            if firstKey {
                guard let relayMeta else { break }
                // Starting over after lost keys, the set still only shrinks.
                NotificationSharedSettings.knownGatewayIDs = NotificationE2E.knownGatewayIDs(
                    listed: Set(relayMeta.gateways.map(\.id)),
                    previous: NotificationSharedSettings.knownGatewayIDs,
                    holdsKeys: markerWasSet
                )
            }
            guard NotificationSharedSettings.markKeysProvisioned() else { break }
            guard Self.e2eKeyStore.save(record) else {
                if firstKey && !markerWasSet { NotificationSharedSettings.clearKeysProvisioned() }
                continue
            }
            // The plugin now seals with this key. An older plugin dropped the
            // one it replaced; a newer one keeps it for a week, and so do we.
            for stale in records
            where stale.installationID == installationID && stale.gatewayID == gatewayID && stale.kid != record.kid {
                if rotates, stale.retiredAt == nil, Self.e2eKeyStore.save(stale.retired(at: now)) { continue }
                if !rotates { Self.e2eKeyStore.remove(kid: stale.kid) }
            }
            records = records.compactMap { stale in
                guard stale.installationID == installationID && stale.gatewayID == gatewayID else { return stale }
                return rotates ? (stale.retiredAt == nil ? stale.retired(at: now) : stale) : nil
            }
            records.append(record)
            rotatedAny = true
            rotatedGateways.insert(gatewayID)
            setEncryptionConfirmation(EncryptionConfirmation(kid: record.kid, rotates: rotates), gatewayID: gatewayID)
            // An inline rotation the handed-over key replaces can't be
            // answered any more.
            pendingRotations[gatewayID] = nil
            unsavedRotationGatewayIDs.remove(gatewayID)
            // That key crossed the dashboard connection: replace it at once
            // with one from a key exchange, so only this handover depends on
            // the connection.
            if let inlineSuite,
               await rotateInline(record, suite: inlineSuite, dashboardID: dashboardID, profile: profile,
                                  records: &records, request: request) == .rotated {
                rotatedAny = true
            }
        }
        refreshEncryptionState()
    }

    /// Whether a pairing's key should rotate inline now: the host asks (age
    /// or a request), the key was handed over through the dashboard (so only
    /// that connection protected it), or this iPhone can now run a better
    /// suite than the one that made it (an update to iOS 26).
    /// A pairing that already got a new key in this run waits for the next.
    nonisolated static func wantsInlineRotation(held: E2EKeyRecord, suite: String, hostAsks: Bool, rotatedThisRun: Bool = false) -> Bool {
        if rotatedThisRun { return false }
        if hostAsks || held.suite == nil { return true }
        return suite == NotificationKeyRotation.suitePQ && held.suite != NotificationKeyRotation.suitePQ
    }

    /// Whether a Rotate tap is still owed after a provisioning run: one the
    /// run started with, or one made while it ran, is used up once the run
    /// gave a pairing a new key (a tap during a rotation joins it); a run
    /// that rotated nothing keeps it for the next.
    nonisolated static func rotationStillRequested(atStart: Bool, tappedSince: Bool, rotatedAny: Bool) -> Bool {
        !rotatedAny && (atStart || tappedSince)
    }

    /// How an inline rotation's request ended.
    enum InlineRotationOutcome: Equatable {
        /// The host wasn't reached: it may have rotated, so the request is
        /// kept for a resend.
        case unreachable
        /// Refused, unverifiable or for a pairing this iPhone no longer
        /// has: the current key stays and the request is dropped.
        case refused
        /// Verified, but the new key couldn't be saved: the request is kept
        /// so the next connect asks again and derives the same key.
        case unsaved
        case rotated

        /// Whether the pending request is kept for a resend.
        var keepsPending: Bool { self == .unreachable || self == .unsaved }

        /// Whether a resend that ended this way leaves the pairing alone
        /// until the next connect: a verified key the Keychain refused is
        /// asked for again then, not replaced by a dashboard handover in the
        /// same run. An unreachable or refusing host still gets the handover.
        var waitsForNextConnect: Bool { self == .unsaved }
    }

    /// Rotates a pairing's key through a key exchange sealed with the
    /// current key, so the new secret never crosses the dashboard connection.
    @discardableResult
    private func rotateInline(
        _ current: E2EKeyRecord,
        suite: String,
        dashboardID: UUID,
        profile: String,
        records: inout [E2EKeyRecord],
        request: (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]
    ) async -> InlineRotationOutcome {
        guard let pending = try? NotificationKeyRotation.start(current: current, suite: suite) else { return .refused }
        pendingRotations[current.gatewayID] = pending
        return await finishInlineRotation(pending, dashboardID: dashboardID, profile: profile, records: &records, request: request)
    }

    private func finishInlineRotation(
        _ pending: NotificationKeyRotation.Pending,
        dashboardID: UUID,
        profile: String,
        records: inout [E2EKeyRecord],
        request: (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]
    ) async -> InlineRotationOutcome {
        let gatewayID = pending.current.gatewayID
        let outcome = await sendInlineRotation(pending, dashboardID: dashboardID, profile: profile,
                                               records: &records, request: request)
        if !outcome.keepsPending { pendingRotations[gatewayID] = nil }
        switch outcome {
        case .unsaved: unsavedRotationGatewayIDs.insert(gatewayID)
        case .refused, .rotated: unsavedRotationGatewayIDs.remove(gatewayID)
        case .unreachable: break
        }
        return outcome
    }

    private func sendInlineRotation(
        _ pending: NotificationKeyRotation.Pending,
        dashboardID: UUID,
        profile: String,
        records: inout [E2EKeyRecord],
        request: (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]
    ) async -> InlineRotationOutcome {
        let path = DashboardPath.withProfile(NotificationKeyRotation.path, profile: profile)
        let response: [String: Any]
        do {
            response = try await request(path, "POST", pending.request)
        } catch {
            // The host may have rotated already: asked again later.
            return .unreachable
        }
        let now = Date()
        // Unregistered or moved relays while the request was out: the key
        // would belong to a pairing this iPhone no longer has.
        guard registration?.installationID == pending.current.installationID,
              response["ok"] as? Bool == true,
              let reply = response["rotation"] as? [String: Any],
              let record = try? NotificationKeyRotation.finish(pending, reply: reply, dashboardID: dashboardID.uuidString,
                                                                profile: profile, now: now) else {
            // Refused or unverifiable: the current key stays, and asking
            // again would get the same answer. A host that did rotate reports
            // a key this iPhone lacks, and the next connect hands over a
            // fresh one.
            return .refused
        }
        guard Self.e2eKeyStore.save(record) else {
            // The host seals with the new key now, so its pushes show generic
            // text until this iPhone holds it. The next connect asks again
            // (the host answers the same request the same way) instead of
            // handing a key over through the dashboard.
            return .unsaved
        }
        records.append(record)
        adoptConfirmedKey(kid: record.kid, installationID: record.installationID, gatewayID: record.gatewayID, records: &records, now: now)
        setEncryptionConfirmation(EncryptionConfirmation(kid: record.kid, rotates: true), gatewayID: record.gatewayID)
        return .rotated
    }

    /// Whether the host keeps a replaced key for answers in flight, so new
    /// keys lose nothing (notifier 0.71+, which reports `rotate`).
    nonisolated static func hostKeepsReplacedKeys(status: [String: Any]) -> Bool {
        (status["rotate"] as? Bool) != nil
    }

    /// The key this iPhone holds that the host says it seals with, or nil.
    nonisolated static func confirmedKey(status: [String: Any], installationID: String, records: [E2EKeyRecord]) -> E2EKeyRecord? {
        guard status["ok"] as? Bool == true,
              status["paired"] as? Bool == true,
              status["crypto"] as? Bool != false,
              status["installation_id"] as? String == installationID,
              let gatewayID = status["gateway_id"] as? String,
              let kid = (status["e2e"] as? [String: Any])?["kid"] as? String else {
            return nil
        }
        return records.first { $0.kid == kid && $0.gatewayID == gatewayID && $0.installationID == installationID }
    }

    /// Hands the host a new key for a pairing that already has one. The new
    /// key is saved before it is sent, so a push sealed with it always opens;
    /// the old one stays a week for pushes and answers already on their way.
    /// True once the host took it.
    private func rotateEncryptionKey(
        of current: E2EKeyRecord,
        dashboardID: UUID,
        profile: String,
        path: String,
        records: inout [E2EKeyRecord],
        request: (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]
    ) async -> Bool {
        let now = Date()
        // Retired until the host takes it: answers stay sealed with the key
        // the host is known to hold.
        let record = NotificationE2E.newRecord(
            installationID: current.installationID,
            gatewayID: current.gatewayID,
            dashboardID: dashboardID.uuidString,
            profile: profile,
            now: now
        ).retired(at: now)
        guard Self.e2eKeyStore.save(record) else { return false }
        records.append(record)
        let body: [String: Any] = [
            "installation_id": record.installationID,
            "gateway_id": record.gatewayID,
            "kid": record.kid,
            "secret": NotificationE2E.base64URL(record.secret),
        ]
        let response: [String: Any]
        do {
            response = try await request(path, "POST", body)
        } catch {
            // The host may have taken it with the answer lost: the key stays
            // (retired) so its pushes open, and the next connect adopts it if
            // the host reports it.
            return false
        }
        // Unregistered or moved relays while the request was out (as for a
        // first key): the key belongs to a pairing this iPhone no longer has.
        guard response["ok"] as? Bool == true, response["kid"] as? String == record.kid,
              registration?.installationID == record.installationID else {
            Self.e2eKeyStore.remove(kid: record.kid)
            records.removeAll { $0.kid == record.kid }
            return false
        }
        adoptConfirmedKey(kid: record.kid, installationID: record.installationID, gatewayID: record.gatewayID, records: &records, now: now)
        setEncryptionConfirmation(EncryptionConfirmation(kid: record.kid, rotates: true), gatewayID: record.gatewayID)
        return true
    }

    /// The relay gateway id of a profile's pairing that still needs a key
    /// from this iPhone, or nil: not paired, paired with another device, an
    /// old pairing without a gateway id, a host that can't encrypt, or a key
    /// this iPhone already holds.
    nonisolated static func gatewayNeedingEncryptionKey(status: [String: Any], installationID: String, records: [E2EKeyRecord]) -> String? {
        guard status["ok"] as? Bool == true,
              status["paired"] as? Bool == true,
              status["crypto"] as? Bool != false,
              status["installation_id"] as? String == installationID,
              let gatewayID = status["gateway_id"] as? String, !gatewayID.isEmpty else {
            return nil
        }
        if let kid = (status["e2e"] as? [String: Any])?["kid"] as? String,
           records.contains(where: { $0.kid == kid && $0.gatewayID == gatewayID && $0.installationID == installationID }) {
            return nil
        }
        return gatewayID
    }

    /// Forgets the keys of an installation this iPhone no longer uses.
    private func removeEncryptionKeys(installationID: String) {
        // Unreadable now: the keys stay inert (no envelope matches them) and
        // go on the next removal.
        if let stored = Self.e2eKeyStore.readRecords() {
            for record in stored where record.installationID == installationID {
                Self.e2eKeyStore.remove(kid: record.kid)
            }
        }
        // With no key left, the next first key freezes a fresh set. Only on
        // a real read: an unreadable store may still hold other keys.
        if Self.e2eKeyStore.readRecords()?.isEmpty == true {
            NotificationSharedSettings.knownGatewayIDs = []
            NotificationSharedSettings.clearKeysProvisioned()
            encryptionConfirmations = [:]
            UserDefaults.standard.removeObject(forKey: Self.encryptionConfirmationsKey)
        }
        UserDefaults.standard.removeObject(forKey: Self.encryptedDecisionGatewaysKey)
        refreshEncryptionState()
    }

    /// A clarify answer for a gateway with an encryption key is sealed for
    /// it; the plugin rejects plaintext from an encrypted pairing.
    nonisolated static func sealedRespondBody(
        _ body: [String: String],
        requestID: String,
        installationID: String?,
        records: [E2EKeyRecord]
    ) throws -> [String: String] {
        guard let gatewayID = body["gateway_id"],
              let answer = body["answer"],
              let record = NotificationE2E.currentRecord(gatewayID: gatewayID, installationID: installationID, records: records) else {
            return body
        }
        var sealed = body
        sealed["answer"] = try NotificationE2E.sealAnswer(answer, record: record, requestID: requestID, questionID: body["question_id"])
        return sealed
    }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Loads relay + plugin compatibility state for Settings > Notifications.
    /// Nil after a completed fetch (also on 404 from older/self-hosted relays)
    /// renders as unknown; `isFetchingMeta` distinguishes that from an
    /// in-flight request so the UI never diagnoses "predates version
    /// reporting" while still loading.
    func refreshMeta() async {
        guard let registration else {
            relayMeta = nil
            relayMetaFetchFailed = false
            relayLacksMetaRoute = false
            isFetchingMeta = false
            return
        }
        isFetchingMeta = true
        defer { isFetchingMeta = false }
        let request: URLRequest
        do {
            // An insecure custom relay URL degrades to the unknown-meta state
            // instead of shipping the credential over cleartext.
            request = authorizedRequest(
                url: try authenticatedRelayURL("/v1/meta"),
                credential: registration.credential
            )
        } catch {
            relayMeta = nil
            // Never asked, so not an older relay: Settings says it can't reach it.
            relayMetaFetchFailed = true
            return
        }
        var status: Int?
        var fetched: RelayMetaInfo?
        if let (data, response) = try? await URLSession.shared.data(for: request) {
            status = (response as? HTTPURLResponse)?.statusCode
            if status == 200 { fetched = try? JSONDecoder().decode(RelayMetaInfo.self, from: data) }
        }
        relayMeta = Self.relayMetaAfterFetch(previous: relayMeta, status: status, fetched: fetched)
        relayMetaFetchFailed = status != 404 && (status != 200 || fetched == nil)
        relayLacksMetaRoute = status == 404
        // The relay answers again: an update that failed while it couldn't
        // (a cleared location token) goes now. Nothing changed, nothing sent.
        if status == 200, fetched != nil { _ = queueRegistrationUpdate() }
    }

    /// The relay's metadata after a fetch: what it said; nil from a relay
    /// without the route (404, it predates version reporting); and after a
    /// failure (offline, a relay error, an unreadable answer) the last one
    /// it said. A passing outage mustn't read as an older relay: without
    /// `location-push` the next registration update would clear the
    /// location-push token, and locates and Maps wakes would stop.
    nonisolated static func relayMetaAfterFetch(previous: RelayMetaInfo?, status: Int?, fetched: RelayMetaInfo?) -> RelayMetaInfo? {
        if status == 200, let fetched { return fetched }
        return status == 404 ? nil : previous
    }

    /// Outcome of answering ONE question of a batch relay decision
    /// (`question_id` scoped). The relay applies first-answer-wins per
    /// question: only the targeted qid locks; other qids stay open.
    enum RelayQuestionOutcome: Equatable {
        /// The qid locked. `remaining` mirrors the relay's open-qid list when
        /// reported; nil means the relay did not say.
        case locked(remaining: [String]?)
        /// Another device locked this qid first. Only this question settles
        /// as answered elsewhere; siblings stay open.
        case questionAlreadyLocked
        /// The relay RELEASED the whole decision (the native gateway path
        /// resolved the clarify): the entire pushed card must be retired.
        case decisionReleased
        /// The decision is gone (timed out or completed elsewhere).
        case noLongerActive
    }

    /// Outcome of answering a whole plugin-minted clarify
    /// (`conduit-push-…`) through the relay's decision loop (legacy
    /// single-question shape).
    enum RelayDecisionOutcome {
        case answered
        /// The decision expired (clarify timed out server-side), was answered
        /// on another surface first, or was released by the native path.
        case noLongerActive
        /// Another device already answered this decision.
        case alreadyAnsweredElsewhere
    }

    enum RelayDecisionError: LocalizedError {
        case unregistered
        case transport(String)
        case server(Int)
        case insecureTransport
        /// Longer than the relay takes (413 `answer_too_large`).
        case answerTooLarge

        var errorDescription: String? {
            switch self {
            case .unregistered:
                return AppLocalization.string("This iPhone isn't set up to answer from notifications. Set it up again in Settings > Notifications.")
            case .transport(let message):
                return AppLocalization.string("Couldn't send your answer: \(message)")
            case .server:
                return AppLocalization.string("Your answer wasn't accepted. Open the chat in Conduit and answer there.")
            case .insecureTransport:
                return AppLocalization.string("The notification relay address must start with https://. Fix it in Settings > Notifications.")
            case .answerTooLarge:
                return AppLocalization.string("That answer is too long to send from a notification card. Open the chat in Conduit and answer there.")
            }
        }
    }

    /// Composes a credential-bearing relay endpoint and enforces the
    /// transport policy before any `Authorization: Bearer` header is attached.
    func authenticatedRelayURL(_ path: String) throws -> URL {
        let url = relayURL.appending(path: path)
        guard RelayTransportPolicy.allowsCredentialTransport(url) else {
            throw RelayDecisionError.insecureTransport
        }
        return url
    }

    private func authorizedRequest(url: URL, credential: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Raw relay decision respond result. 404, 409, and 410 are distinct
    /// server states and must not be collapsed: 404 = unknown decision,
    /// 409 = already locked (whole decision for the legacy shape, that
    /// question only for the batch shape), 410 = the decision was RELEASED
    /// because the native gateway path resolved the clarify.
    private enum RelayRespondOutcome {
        case accepted(remaining: [String]?)
        case noLongerActive
        case alreadyLocked
        case released
    }

    // MARK: - Live Activities (#605)

    /// The installation whose relay answered 404 for the Live Activity
    /// route; pairing with another relay tries again.
    private var liveActivitiesUnsupportedInstallation: String?

    /// What a Live Activity token registration's HTTP status says about the
    /// relay's route: a success confirms it, a 404 means the relay has
    /// none, anything else says nothing.
    nonisolated static func liveActivityRouteExists(registrationStatus status: Int) -> Bool? {
        switch status {
        case 200..<300: true
        case 404: false
        default: nil
        }
    }

    /// Registers the push token of the Live Activity Conduit started for a
    /// chat, under the ids the chat is known by (at most 6, the relay's
    /// limit), so the host's progress reports reach it. Best effort: without
    /// notifications, or on a relay without the route, the activity is only
    /// updated while Conduit runs. Returns the installation whose relay
    /// took the token, the one case the Conduit plugin can update and end
    /// it by push; nil otherwise.
    @discardableResult
    func registerLiveActivity(token: String, sessionIDs: [String]) async -> String? {
        guard let registration, liveActivitiesUnsupportedInstallation != registration.installationID,
              !sessionIDs.isEmpty else { return nil }
        let routeExists = await sendLiveActivity(
            LiveActivityRegistration(pushToken: token, sessionIDs: Array(sessionIDs.prefix(6))),
            method: "PUT",
            registration: registration
        )
        return routeExists == true ? registration.installationID : nil
    }

    /// The activity ended on the phone: the relay forgets its token.
    func unregisterLiveActivity(token: String) async {
        guard let registration, liveActivitiesUnsupportedInstallation != registration.installationID else { return }
        await sendLiveActivity(LiveActivityRemoval(pushToken: token), method: "DELETE", registration: registration)
    }

    /// Sends a token's registration or removal; for a registration, what
    /// its answer says about the relay's route (nil when it says nothing).
    @discardableResult
    private func sendLiveActivity<Body: Encodable>(_ body: Body, method: String, registration: StoredRegistration) async -> Bool? {
        do {
            let request = try jsonRequest(
                path: "/v1/installations/\(registration.installationID)/live-activities",
                method: method,
                body: body,
                credential: registration.credential
            )
            let (_, response) = try await URLSession.shared.data(for: request)
            // Only a registration's answer says whether the relay has the
            // route.
            guard method == "PUT", let status = (response as? HTTPURLResponse)?.statusCode,
                  let routeExists = Self.liveActivityRouteExists(registrationStatus: status) else { return nil }
            if !routeExists {
                liveActivitiesUnsupportedInstallation = registration.installationID
            }
            return routeExists
        } catch {
            // The activity still updates while Conduit runs.
            return nil
        }
    }

    /// Answers a plugin-minted clarify decision through the relay. The gateway
    /// polls the relay for this answer while its clarify middleware blocks, so
    /// the agent thread unblocks exactly as if `clarify.respond` had been used.
    @discardableResult
    func respondToRelayDecision(
        requestId: String,
        answer: String
    ) async throws -> RelayDecisionOutcome {
        let body = Self.respondBody(
            requestID: requestId,
            answer: answer,
            relayGatewayID: relayGatewayID(forRequestID: requestId)
        )
        switch try await relayDecisionRespond(requestId: requestId, body: body) {
        case .accepted: return .answered
        case .alreadyLocked: return .alreadyAnsweredElsewhere
        case .released, .noLongerActive: return .noLongerActive
        }
    }

    /// Answers ONE question of a batch relay decision. Requires a relay +
    /// notifier pair that ships the batch decision contract; a batch card only
    /// exists when the batch-capable plugin pushed it. An empty `answer`
    /// leaves a form's question blank (`blankAnswer`).
    @discardableResult
    func respondToRelayDecisionQuestion(
        requestId: String,
        questionId: String,
        answer: String
    ) async throws -> RelayQuestionOutcome {
        var answer = answer
        if answer.isEmpty {
            let sealed = relayGatewayID(forRequestID: requestId).flatMap { gatewayID in
                NotificationE2E.currentRecord(gatewayID: gatewayID, installationID: registration?.installationID, records: Self.e2eKeyStore.records())
            } != nil
            // The relay may have been updated since it last said what it takes.
            if !sealed, relayMeta?.capabilities.contains(Self.clarifySkipCapability) != true { await refreshMeta() }
            answer = Self.blankAnswer(sealed: sealed, relayCapabilities: relayMeta?.capabilities)
        }
        let body = Self.respondBody(
            requestID: requestId,
            answer: answer,
            questionID: questionId,
            relayGatewayID: relayGatewayID(forRequestID: requestId)
        )
        switch try await relayDecisionRespond(
            requestId: requestId,
            body: body
        ) {
        case .accepted(let remaining): return .locked(remaining: remaining)
        case .alreadyLocked: return .questionAlreadyLocked
        case .released: return .decisionReleased
        case .noLongerActive: return .noLongerActive
        }
    }

    /// The relay takes a blank answer to one question of a batch, a form's
    /// field left empty (relay 0.18).
    nonisolated static let clarifySkipCapability = "clarify-skip"
    /// What a blank goes as where the relay can't take one: Hermes reads it
    /// as the answer.
    nonisolated static let leftBlankAnswer = "(left blank)"

    /// What a question left blank sends through the relay: empty, sealed for
    /// an encrypted pairing (any relay takes that) or plain to a relay that
    /// takes a blank; else `leftBlankAnswer`.
    nonisolated static func blankAnswer(sealed: Bool, relayCapabilities: [String]?) -> String {
        sealed || relayCapabilities?.contains(clarifySkipCapability) == true ? "" : leftBlankAnswer
    }

    /// The relay takes a plaintext clarify answer of at most this many
    /// UTF-16 units once trimmed (relay MAX_ANSWER_CHARS). Sealed, an answer
    /// this long also stays under its sealed-answer cap.
    nonisolated static let maximumDecisionAnswerCharacters = 2_000

    /// Why `answer` can't go through the relay, checked before it's sealed.
    nonisolated static func decisionAnswerError(_ answer: String) -> RelayDecisionError? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.utf16.count > maximumDecisionAnswerCharacters ? .answerTooLarge : nil
    }

    /// A refused answer: the relay says 413 `answer_too_large` for one
    /// over its limits.
    nonisolated static func decisionError(status: Int, data: Data) -> RelayDecisionError {
        if status == 413 { return .answerTooLarge }
        return .server(status)
    }

    /// Shared relay decision POST. Contract: 200 = accepted (body may carry
    /// `remaining`), 404 = unknown decision, 409 = already locked, 410 =
    /// decision released by the native path.
    private func relayDecisionRespond(
        requestId: String,
        body: [String: String]
    ) async throws -> RelayRespondOutcome {
        guard let registration else { throw RelayDecisionError.unregistered }
        if let answer = body["answer"], let error = Self.decisionAnswerError(answer) { throw error }
        var request = URLRequest(url: try authenticatedRelayURL("/v1/decisions/\(requestId)/respond"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(registration.credential)", forHTTPHeaderField: "Authorization")
        let sealed = try Self.sealedRespondBody(
            body,
            requestID: requestId,
            installationID: registration.installationID,
            records: Self.e2eKeyStore.records()
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: sealed)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RelayDecisionError.transport(AppLocalization.string("invalid response"))
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let remaining = json?["remaining"] as? [String]
            switch http.statusCode {
            case 200:
                return .accepted(remaining: remaining)
            case 404:
                return .noLongerActive
            case 409:
                return .alreadyLocked
            case 410:
                return .released
            default:
                throw Self.decisionError(status: http.statusCode, data: data)
            }
        } catch let error as RelayDecisionError {
            throw error
        } catch {
            throw RelayDecisionError.transport(UserFacingError.message(for: error))
        }
    }

    func enable() async {
        // The Enable button is disabled while working, but a second tap can
        // land before that state reaches the view.
        guard !isWorking, !isPairing else { return }
        lastError = nil
        relayNotice = nil
        preferences.enabled = true
        isWorking = true
        defer { isWorking = false }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await refresh()
            guard granted || authorizationStatus == .authorized || authorizationStatus == .provisional else {
                throw PushNotificationError.permissionDenied
            }
            let token = try await requestDeviceToken()
            try await register(deviceToken: token)
        } catch {
            lastError = UserFacingError.message(for: error)
        }
    }

    func disable() async {
        // Same one-operation-at-a-time rule as enable(), so a revoke never
        // interleaves with an in-flight registration. A tap that lands
        // mid-operation is dropped rather than queued; the button is
        // disabled while working or pairing, so this only catches the race
        // window. Not mid-pairing: the plugin would claim for a revoked
        // installation.
        guard !isWorking, !isPairing else { return }
        lastError = nil
        relayNotice = nil
        isWorking = true
        defer { isWorking = false }
        await revokeRegistration()
        preferences.enabled = false
    }

    /// True while this phone is registered with a relay other than the one
    /// saved in Settings, i.e. a move was saved but hasn't succeeded yet.
    var relayMovePending: Bool {
        guard let registration else { return false }
        return !Self.isSameRelay(registration.relayURL, configuredRelayURL)
    }

    /// Moves this phone to the configured relay after the user changes it
    /// in Settings (#255). It registers with the new relay first and only
    /// then revokes the installation on the old one, so a relay that is
    /// unreachable or refused leaves the working registration in place.
    /// With notifications off there is nothing to move; the next
    /// `enable()` uses the new relay.
    func applyRelayChange() async {
        // One move at a time: overlapping moves would each register, and
        // all but the last installation would be orphaned on the new relay.
        guard !isWorking else { return }
        // A pairing in flight claims for the current installation; the move
        // waits for it rather than being dropped.
        while isPairing {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        guard !isWorking else { return }
        // A failure against the previous relay no longer describes the
        // current setup, whether or not there is a registration to move.
        lastError = nil
        guard let previous = registration, relayMovePending else {
            await refreshMeta()
            return
        }
        guard RelayTransportPolicy.allowsCredentialTransport(configuredRelayURL) else {
            lastError = RelayDecisionError.insecureTransport.localizedDescription
            return
        }
        relayNotice = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let token = try await requestDeviceToken()
            // Cleared so `register` creates an installation on the
            // configured relay instead of updating the old one.
            registration = nil
            try await register(deviceToken: token)
        } catch {
            // Still registered with the old relay, which keeps working;
            // Settings offers the move again.
            registration = previous
            lastError = UserFacingError.message(for: error)
            return
        }
        await revokeInstallation(previous)
        removeEncryptionKeys(installationID: previous.installationID)
        relayMeta = nil
        relayMetaFetchFailed = false
        relayLacksMetaRoute = false
        pairingCode = nil
        pairingExpiry = nil
        // Gateway discriminators belong to the old relay; echoing one to
        // the new relay could only fail or mis-route.
        relayGatewayIDsByRequestID.removeAll()
        relayNotice = AppLocalization.string("Moved to the new relay. Pair each Hermes profile again to keep receiving notifications.")
        await refreshMeta()
    }

    /// Best-effort revoke on the issuing relay, then drop the local
    /// credential either way: a later enable creates a fresh, revocable
    /// installation rather than retaining stale state.
    private func revokeRegistration() async {
        if let registration {
            await revokeInstallation(registration)
            removeEncryptionKeys(installationID: registration.installationID)
        }
        registration = nil
        KeychainHelper.clearPushRegistration()
    }

    /// Best-effort DELETE of `installation` on the relay that issued it.
    private func revokeInstallation(_ installation: StoredRegistration) async {
        guard let base = Self.requestRelayURL(issuer: installation.relayURL, configured: configuredRelayURL) else {
            return
        }
        let url = base.appending(path: "/v1/installations/\(installation.installationID)")
        guard RelayTransportPolicy.allowsCredentialTransport(url) else { return }
        var request = authorizedRequest(url: url, credential: installation.credential)
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
    }

    func setPreference(_ keyPath: WritableKeyPath<ConduitNotificationPreferences, Bool>, enabled: Bool) async {
        preferences[keyPath: keyPath] = enabled
        // Queued behind any update on its way: two quick switches never
        // race, so the relay can't end on the older preferences.
        guard let update = queueRegistrationUpdate() else { return }
        do {
            try await update.value
        } catch {
            lastError = UserFacingError.message(for: error)
        }
    }

    /// Creates a pairing code bound to the given dashboard. The identity is
    /// REQUIRED (#148): new pairings are always dashboard-scoped so the relay
    /// can stamp every later push with an owner. (Pre-existing unscoped
    /// pairings remain routable through the legacy compatibility policy —
    /// Conduit just never creates new ones.)
    func createPairingCode(dashboardID: UUID) async {
        // Not mid-move: a code created against the old relay would be
        // cleared (and useless) once the move lands. Not mid-pairing either.
        guard !isWorking, !isPairing else { return }
        pairingCode = nil
        pairingExpiry = nil
        lastError = nil
        guard let registration else {
            lastError = AppLocalization.string("Turn on notifications on this device before creating a pairing code.")
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let pairing = try await requestPairingCode(registration: registration, dashboardID: dashboardID)
            pairingCode = pairing.pairingCode
            pairingExpiry = pairing.expiresAt
        } catch {
            lastError = UserFacingError.message(for: error)
        }
    }

    /// A new one-time pairing code from the relay, bound to `dashboardID`.
    private func requestPairingCode(registration: StoredRegistration, dashboardID: UUID) async throws -> PairingResponse {
        var request = authorizedRequest(
            url: try authenticatedRelayURL("/v1/installations/\(registration.installationID)/pairings"),
            credential: registration.credential
        )
        request.httpMethod = "POST"
        // Bind the pairing to the dashboard (#148): the relay persists
        // this UUID at claim time, and every later push derived from that
        // gateway credential is stamped with it. Older relays ignore the
        // body, which keeps pre-dashboard relays working.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairingCreateRequest(dashboardID: dashboardID.uuidString))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(PairingResponse.self, from: data)
    }

    /// This iPhone's relay installation, which a profile's pairing names.
    var installationID: String? { registration?.installationID }

    static let pairPath = "/api/plugins/conduit_push/pair"
    /// Past the host's own wait: it claims the code at the relay with a
    /// 15 s timeout (plugin_api PAIR_TIMEOUT_S), then writes the pairing.
    /// Giving up first would leave the host paired with no key handed over.
    static let pairTimeoutMilliseconds = 25_000

    /// Who a profile's notifications go to, from the plugin's
    /// `GET /e2e?profile=` answer.
    enum ProfilePairing: Equatable {
        case unpaired
        case thisDevice
        /// Another iPhone, or this one before it re-registered.
        case otherDevice
    }

    static func profilePairing(status: [String: Any], installationID: String) -> ProfilePairing {
        guard status["paired"] as? Bool == true else { return .unpaired }
        return status["installation_id"] as? String == installationID ? .thisDevice : .otherDevice
    }

    /// Pairs `profile` on the dashboard's host without a code to type
    /// (plugin 0.24+): a new code from the relay goes to the plugin over
    /// the signed-in dashboard connection, and the plugin claims it, the
    /// same claim `hermes conduit-push pair` makes. `request` reaches that
    /// dashboard. Returns the relay gateway id the plugin claimed, when it
    /// says.
    @discardableResult
    func pairProfile(
        _ profile: String,
        dashboardID: UUID,
        request: (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]
    ) async throws -> String? {
        // Not mid-move: a code from the old relay is useless once the move lands.
        guard !isWorking, !isPairing, let registration else { throw DashboardTicketBridgeError.notReady }
        // One pairing at a time: the button and the automatic one can't
        // overlap. Its own flag, so the notifications switch doesn't read
        // "Updating" meanwhile.
        isPairing = true
        defer { isPairing = false }
        // The relay the code is minted at is the one the host claims it at,
        // even if a relay move lands meanwhile.
        let relay = relayURL
        let pairing = try await requestPairingCode(registration: registration, dashboardID: dashboardID)
        guard self.registration?.installationID == registration.installationID else {
            throw DashboardTicketBridgeError.notReady
        }
        let body: [String: Any] = ["pairing_code": pairing.pairingCode, "relay_url": relay.absoluteString]
        let response = try await request(DashboardPath.withProfile(Self.pairPath, profile: profile), "POST", body)
        // Notifications turned off or moved meanwhile: that installation is
        // gone, so its pairing is nothing to confirm or refresh.
        guard self.registration?.installationID == registration.installationID else {
            throw DashboardTicketBridgeError.notReady
        }
        guard response["ok"] as? Bool == true, response["installation_id"] as? String == registration.installationID else {
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("The plugin didn't confirm the pairing."))
        }
        await refreshMeta()
        return response["gateway_id"] as? String
    }

    func didReceiveDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        tokenContinuation?.resume(returning: token)
        tokenContinuation = nil
        // Every launch and return to the front asks for the token; only a
        // new one goes to the relay, which shares one budget for device
        // changes across all phones. Registrations saved before the token
        // was recorded send it once. One that fails shows in Settings >
        // Notifications and goes again the next time Conduit comes to the
        // front.
        if registration?.deviceToken == token {
            clearTokenUpdateError()
            return
        }
        observeTokenUpdate(queueRegistrationUpdate(deviceToken: token))
    }

    private var tokenUpdateError: String?

    /// A token update that fails shows in Settings until one goes.
    private func observeTokenUpdate(_ update: Task<Void, Error>?) {
        guard let update else { return }
        Task { [weak self] in
            guard let self else { return }
            switch await update.result {
            case .failure(let error):
                lastError = UserFacingError.message(for: error)
                tokenUpdateError = lastError
            case .success:
                clearTokenUpdateError()
            }
        }
    }

    /// A token the relay has clears the failure a refresh left, not another.
    private func clearTokenUpdateError() {
        if tokenUpdateError != nil, lastError == tokenUpdateError { lastError = nil }
        tokenUpdateError = nil
    }

    /// Asks iOS for this launch's push token, and again each time Conduit
    /// comes to the front. The token can change (a restore, a new phone),
    /// and a relay still sending to the old one gets 200 from Apple while
    /// nothing reaches this phone (notifier #119).
    func refreshDeviceTokenAtLaunch() {
        // Turning notifications on later asks for the token itself.
        guard registration != nil else { return }
        if becomeActiveObserver.token == nil {
            becomeActiveObserver.token = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.requestCurrentDeviceToken()
                    self?.refreshMetaIfUnknown()
                }
            }
        }
        requestCurrentDeviceToken()
        refreshMetaIfUnknown()
    }

    /// Whether the relay sends locates decides what happens to the location
    /// push token, so it's asked at launch (and on return while unknown),
    /// not only when Settings > Notifications opens (notifier #287). Once
    /// known, a token change an earlier update failed to send goes again
    /// (nothing is sent when nothing changed).
    private func refreshMetaIfUnknown() {
        guard registration != nil, !isFetchingMeta, !relayLacksMetaRoute else { return }
        guard relayMeta == nil else {
            queueRegistrationUpdate()
            return
        }
        Task { await refreshMeta() }
    }

    /// Removed with the service (only tests make more than one).
    private let becomeActiveObserver = NotificationObserverToken()

    private func requestCurrentDeviceToken() {
        guard registration != nil else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didFailToRegister(_ error: Error) {
        if tokenContinuation == nil {
            // A launch or return-to-front refresh: shown in Settings >
            // Notifications, and the next return asks again.
            pushTokenLogger.error("Push token refresh failed: \(LogRedaction.message(error), privacy: .public)")
            if registration != nil {
                lastError = UserFacingError.message(for: error)
                tokenUpdateError = lastError
            }
        }
        failTokenRequest(error)
    }

    private func failTokenRequest(_ error: Error) {
        tokenContinuation?.resume(throwing: error)
        tokenContinuation = nil
    }

    /// The nonce in the relay's registration challenge push, or nil.
    nonisolated static func tokenChallenge(in userInfo: [AnyHashable: Any]) -> String? {
        guard let nonce = userInfo["conduit_token_challenge"] as? String,
              nonce.utf8.count == 43,
              nonce.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { return nil }
        return nonce
    }

    /// A challenge push arrived; one nobody is waiting for is dropped.
    func receiveTokenChallenge(_ nonce: String) {
        guard awaitingTokenChallenge else { return }
        if let continuation = tokenChallengeContinuation {
            tokenChallengeContinuation = nil
            continuation.resume(returning: nonce)
        } else {
            receivedTokenChallenge = nonce
        }
    }

    private func failTokenChallenge(_ error: Error) {
        tokenChallengeContinuation?.resume(throwing: error)
        tokenChallengeContinuation = nil
    }

    /// Asks the relay to push a nonce to `deviceToken` and waits for it.
    private func proveDeviceToken(_ deviceToken: String, timeout: Duration = .seconds(20)) async throws -> String {
        while awaitingTokenChallenge {
            await withCheckedContinuation { tokenProofWaiters.append($0) }
        }
        // A caller that gave up while it waited doesn't start a proof.
        try Task.checkCancellation()
        awaitingTokenChallenge = true
        receivedTokenChallenge = nil
        defer {
            awaitingTokenChallenge = false
            receivedTokenChallenge = nil
            let waiters = tokenProofWaiters
            tokenProofWaiters = []
            waiters.forEach { $0.resume() }
        }
        let body = TokenChallengeRequest(bundleID: bundleID, deviceToken: deviceToken, environment: "production")
        var request = try jsonRequest(path: "/v1/token-challenges", method: "POST", body: body)
        // The whole proof stays near the push wait, not URLSession's minute.
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        // The push can beat the relay's answer.
        if let nonce = receivedTokenChallenge { return nonce }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.failTokenChallenge(PushNotificationError.tokenProofTimeout)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            tokenChallengeContinuation = continuation
        }
    }

    /// The relay wants proof that this phone holds the device token (0.16+).
    nonisolated static func requiresTokenProof(response: URLResponse, data: Data) -> Bool {
        guard (response as? HTTPURLResponse)?.statusCode == 403 else { return false }
        return (try? JSONDecoder().decode(RelayErrorBody.self, from: data))?.error == "token_proof_required"
    }

    func receiveNotificationPayload(_ userInfo: [AnyHashable: Any]) {
        let records = Self.e2eKeyStore.records()
        let evaluation = NotificationE2E.evaluate(
            userInfo,
            records: records,
            knownGatewayIDs: NotificationSharedSettings.knownGatewayIDs,
            keysProvisioned: NotificationSharedSettings.keysProvisioned
        )
        guard var target = Self.target(for: evaluation, userInfo: userInfo) else { return }
        if case .verified(let verified) = evaluation {
            // A sealed message routes once: a replay of it can't open
            // anything after the original was tapped.
            guard Self.e2eSeenStore.insert(verified.envelope.replayKey, namespace: "routed") else { return }
        }
        if !preferences.decisionCards, target.decision != nil {
            // Encrypted pushes always carry the card (the relay can't strip
            // it); the preference still decides whether Conduit uses it.
            target = ConduitNotificationTarget(
                profile: target.profile,
                profileName: target.profileName,
                sessionId: target.sessionId,
                durableSessionID: target.durableSessionID,
                dashboardID: target.dashboardID,
                hasMalformedDashboardID: target.hasMalformedDashboardID,
                relayGatewayID: target.relayGatewayID,
                type: target.type,
                decision: nil,
                call: target.call
            )
        }
        retainRelayGatewayID(for: target)
        if case .verified = evaluation { persistEncryptedGatewayID(for: target) }
        route(target)
    }

    // MARK: Ringing calls (#449 step 2)

    /// What a VoIP push rings for (HermesNativeCalls).
    struct VoIPCall {
        /// The call, routed like a tap on its notification; nil when the
        /// push routes nowhere (no call in it, or it can't be trusted).
        let target: ConduitNotificationTarget?
        /// When the relay sent it; nil from a relay that didn't say.
        let sentAt: Date?
        /// A sealed push that already rang once.
        let replayed: Bool
    }

    /// The call a VoIP push carries, under the same end-to-end rules as a
    /// notification tap (`receiveNotificationPayload`). Synchronous: the
    /// PushKit callback reports the call before it returns.
    func receiveVoIPCall(_ userInfo: [AnyHashable: Any], now: Date = Date()) -> VoIPCall {
        let evaluation = NotificationE2E.evaluate(
            userInfo,
            records: Self.e2eKeyStore.records(),
            knownGatewayIDs: NotificationSharedSettings.knownGatewayIDs,
            keysProvisioned: NotificationSharedSettings.keysProvisioned,
            now: now
        )
        let sentAt = Self.voipSentAt(userInfo)
        guard let target = Self.target(for: evaluation, userInfo: userInfo), target.call != nil else {
            return VoIPCall(target: nil, sentAt: sentAt, replayed: false)
        }
        if case .verified(let verified) = evaluation {
            guard Self.e2eSeenStore.insert(verified.envelope.replayKey, namespace: "rang") else {
                return VoIPCall(target: target, sentAt: sentAt, replayed: true)
            }
            persistEncryptedGatewayID(for: target)
        }
        return VoIPCall(target: target, sentAt: sentAt, replayed: false)
    }

    /// The relay's `sent_at` (seconds since 1970), outside any sealed
    /// envelope.
    static func voipSentAt(_ userInfo: [AnyHashable: Any]) -> Date? {
        let direct = userInfo["conduit"] as? [String: Any]
        let nested = (userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any]
        guard let seconds = (direct?["sent_at"] as? NSNumber) ?? (nested?["sent_at"] as? NSNumber) else { return nil }
        return Date(timeIntervalSince1970: seconds.doubleValue)
    }

    /// The PushKit token calls ring on; nil while the phone can't ring
    /// (CallKit is off in this storefront, or PushKit has given none).
    private(set) var voipToken: String?

    /// HermesNativeCalls has a new PushKit token, or none any more: the
    /// relay learns it with the registration.
    func updateVoIPToken(_ token: String?) {
        voipToken = token
        queueRegistrationUpdate()
    }

    /// The Apple Watch's own PushKit token, which calls from Hermes ring on
    /// too (designs/hermes-calls-watch.md). Kept across launches: the Watch
    /// sends it again only when it changes.
    private(set) var watchVoIPToken: String? = UserDefaults.standard.string(forKey: PushNotificationService.watchVoIPTokenKey)
    static let watchVoIPTokenKey = "hermesCalls.watchVoIPToken"

    /// The voice a Watch call answers with, as the Watch last said (a
    /// WatchCallVoices.Voice raw value); nil from an older Watch app.
    private(set) var watchEngine: String? = UserDefaults.standard.string(forKey: PushNotificationService.watchEngineKey)
    static let watchEngineKey = "hermesCalls.watchEngine"

    /// Which Watch voices can start, as AppState last found them.
    private(set) var watchCallVoices: WatchCallVoices = UserDefaults.standard.data(forKey: PushNotificationService.watchCallVoicesKey)
        .flatMap { try? JSONDecoder().decode(WatchCallVoices.self, from: $0) } ?? WatchCallVoices()
    static let watchCallVoicesKey = "hermesCalls.watchCallVoices"

    /// The Watch app has a new PushKit token, or none any more, or another
    /// voice.
    func updateWatchVoIPToken(_ token: String?, engine: String?) {
        watchVoIPToken = token
        watchEngine = engine
        UserDefaults.standard.set(token, forKey: Self.watchVoIPTokenKey)
        UserDefaults.standard.set(engine, forKey: Self.watchEngineKey)
        queueRegistrationUpdate()
    }

    func updateWatchCallVoices(_ voices: WatchCallVoices) {
        guard voices != watchCallVoices else { return }
        watchCallVoices = voices
        UserDefaults.standard.set(try? JSONEncoder().encode(voices), forKey: Self.watchCallVoicesKey)
        queueRegistrationUpdate()
    }

    /// The APNs token for the agent's on-demand locate (the Location Push
    /// extension), while background location sharing is on; nil otherwise.
    private(set) var locationToken: String?
    /// LocationBackgroundMonitor has said this launch whether there is a
    /// token: until then a nil `locationToken` means "not known yet".
    private var locationTokenReported = false

    /// LocationBackgroundMonitor has a new location push token, or none.
    func updateLocationToken(_ token: String?) {
        guard token != locationToken || !locationTokenReported else { return }
        locationToken = token
        locationTokenReported = true
        queueRegistrationUpdate()
    }

    /// The token the relay gets: only one whose relay says it sends locates.
    private var relayLocationToken: String? {
        relayMeta?.supportsLocationPush == true ? locationToken : nil
    }

    /// What an update does to the relay's location token. Until this launch
    /// has heard whether the relay sends locates, and whether there is a
    /// token (`reported`), nothing: neither is kept across launches, and
    /// taking "not heard yet" for "no" cleared the token at every launch, so
    /// locates found none (notifier #287).
    nonisolated static func locationTokenChange(registered: String?, current: String?, reported: Bool,
                                                relaySendsLocates: Bool?) -> VoIPTokenChange {
        guard let relaySendsLocates, reported || !relaySendsLocates else { return .keep }
        let wanted = relaySendsLocates ? current : nil
        if registered == wanted { return .keep }
        return wanted.map(VoIPTokenChange.set) ?? .clear
    }

    private func locationTokenChange(registered: String?) -> VoIPTokenChange {
        Self.locationTokenChange(registered: registered, current: locationToken, reported: locationTokenReported,
                                 relaySendsLocates: relayMeta?.supportsLocationPush)
    }

    private var ringingWatchVoIPToken: String? {
        Self.ringingWatchToken(phone: voipToken, watch: watchVoIPToken, engine: watchEngine, voices: watchCallVoices)
    }

    /// The Watch rings only alongside this phone (while the phone doesn't
    /// ring, the relay has neither token), and only while the voice it
    /// answers with can start: the Watch has no Classic voice to fall back
    /// on (WatchCallVoices).
    static func ringingWatchToken(phone: String?, watch: String?, engine: String?, voices: WatchCallVoices) -> String? {
        guard phone != nil, voices.rings(engine: engine) else { return nil }
        return watch
    }

    /// Every registration update goes through here, one after another,
    /// each sending the tokens and preferences as they are by then. An
    /// update still on its way may carry other ones, so whether this one has
    /// anything new is decided when its turn comes; a device token the
    /// relay hasn't accepted yet always counts as new.
    @discardableResult
    private func queueRegistrationUpdate(deviceToken: String? = nil) -> Task<Void, Error>? {
        guard registration != nil else { return nil }
        let previous = registrationUpdate
        let update = Task {
            _ = await previous?.result
            guard let registration else { return }
            // A token the relay hasn't accepted yet rides any later update,
            // so one that failed at launch goes again (a relay meta refresh
            // queues one); the same token twice sends once.
            let tokenChanged = (deviceToken ?? self.deviceToken).map { $0 != registration.deviceToken } ?? false
            guard tokenChanged || registration.preferences != preferences
                    || registration.voipToken != voipToken || registration.watchVoipToken != ringingWatchVoIPToken
                    || locationTokenChange(registered: registration.locationToken) != .keep else { return }
            try await updateRegistration(deviceToken: deviceToken)
        }
        registrationUpdate = update
        return update
    }
    private var registrationUpdate: Task<Void, Error>?

    /// A "Hermes wants to talk" notification Conduit posted itself (#449).
    func receiveLocalCallNotification(_ userInfo: [AnyHashable: Any]) {
        guard let target = HermesCallNotifications.localTarget(from: userInfo) else { return }
        route(target)
    }

    /// A call from Hermes answered with Conduit on screen opens as its
    /// notification's Talk button would (#449).
    func routeAnsweredHermesCall(_ target: ConduitNotificationTarget) {
        route(target)
    }

    /// A chat link for another profile or dashboard
    /// (`conduit://session/<id>?profile=…&dashboard=…`) opens as a
    /// notification for that chat would.
    func routeChatLink(_ target: ConduitNotificationTarget) {
        route(target)
    }

    private func route(_ target: ConduitNotificationTarget) {
        navigationRetryTask?.cancel()
        navigationRetryTask = nil
        pendingTarget = target
        pendingRetryCount = 0
        pendingRouteDeadline = now().advanced(by: routeRetryWindow)
        pendingRouteOpenStarted = false
        pendingRouteRetryFiredAt = nil
        pendingRouteAwaitsCall = false
        forgetWaitingTap()
        navigationAttempt += 1
    }

    /// Retains the push's relay gateway discriminator for every relay
    /// request id the decision carries, so a later answer echoes it.
    private func retainRelayGatewayID(for target: ConduitNotificationTarget) {
        guard let gatewayID = target.relayGatewayID else { return }
        switch target.decision {
        case .clarify(let requestID, _, _):
            relayGatewayIDsByRequestID[requestID] = gatewayID
        case .clarifyBatch(let requestID, _):
            relayGatewayIDsByRequestID[requestID] = gatewayID
        case .approval:
            // Approvals answer through the gateway's approval.respond
            // directly; the relay discriminator is never involved.
            break
        case .none:
            // A plain routing push carries no decision at all.
            break
        }
    }

    func clearPendingTarget(_ target: ConduitNotificationTarget) {
        guard pendingTarget == target else { return }
        navigationRetryTask?.cancel()
        navigationRetryTask = nil
        pendingTarget = nil
        pendingRetryCount = 0
        pendingRouteDeadline = nil
        pendingRouteOpenStarted = false
        pendingRouteRetryFiredAt = nil
        pendingRouteAwaitsCall = false
        forgetWaitingTap()
    }

    /// An open of `target` is starting: a retry still waiting would only
    /// cancel it when it fires, so it stands down. Returns false, clearing
    /// the target, when the tap already had an open and its window has run
    /// out: the app went offline mid-open or while a retry was due, and the
    /// reconnect came too late for that tap to open now (#789). A tap's
    /// first open always runs, however slowly the launch connected, and so
    /// does the retry the window's end scheduled, when it starts on time.
    @discardableResult
    func beginNotificationRoute(_ target: ConduitNotificationTarget) -> Bool {
        guard pendingTarget == target else { return true }
        navigationRetryTask?.cancel()
        navigationRetryTask = nil
        let startedAt = now()
        if pendingRouteAwaitsCall {
            // The call it waited for has ended: the tap opens as if just
            // made, with a window of its own.
            pendingRouteAwaitsCall = false
            forgetWaitingTap()
            pendingRetryCount = 0
            pendingRouteDeadline = startedAt.advanced(by: routeRetryWindow)
            pendingRouteRetryFiredAt = nil
            pendingRouteOpenStarted = true
            return true
        }
        let scheduledRetry = pendingRouteRetryFiredAt.map {
            $0.duration(to: startedAt) <= scheduledRetryStartAllowance
        } ?? false
        pendingRouteRetryFiredAt = nil
        if pendingRouteOpenStarted, !scheduledRetry,
           let deadline = pendingRouteDeadline, startedAt >= deadline {
            clearPendingTarget(target)
            return false
        }
        pendingRouteOpenStarted = true
        return true
    }

    /// The route ran while the app is offline: a retry that came due now
    /// has nothing to open, and the reconnect that opens the tap is not it.
    func notificationRouteAwaitsConnection(_ target: ConduitNotificationTarget) {
        guard pendingTarget == target else { return }
        pendingRouteRetryFiredAt = nil
    }

    /// The open stopped for a call it would have ended: the tap stays
    /// pending until the call ends, with no retry or window meanwhile. The
    /// route runs again at once, to wait there for the call to end.
    func notificationRouteAwaitsCall(_ target: ConduitNotificationTarget) {
        guard pendingTarget == target else { return }
        navigationRetryTask?.cancel()
        navigationRetryTask = nil
        pendingRouteRetryFiredAt = nil
        pendingRouteAwaitsCall = true
        keepWaitingTap(target)
        navigationAttempt += 1
    }

    /// Waits until two checks in a row, `interval` apart, find `isReady`
    /// (no call, and Conduit on screen): a call changing hands isn't over,
    /// and a switch waits for the screen. The checks run on a timer since
    /// not every call's end changes state a view observes. False when
    /// cancelled first.
    static func waitForCallToEnd(
        interval: Duration,
        isReady: () -> Bool,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> Bool {
        var readyBefore = false
        while true {
            let ready = isReady()
            if ready, readyBefore { return true }
            readyBefore = ready
            do { try await sleep(interval) } catch { return false }
        }
    }

    private func keepWaitingTap(_ target: ConduitNotificationTarget) {
        guard let keptTaps else { return }
        let tap = WaitingTap(
            profile: target.profile,
            profileName: target.profileName,
            sessionId: target.sessionId,
            durableSessionID: target.durableSessionID,
            dashboardID: target.dashboardID,
            relayGatewayID: target.relayGatewayID,
            type: target.type,
            decision: target.decision,
            waitingSince: date()
        )
        keptTaps.set(try? JSONEncoder().encode(tap), forKey: Self.waitingTapKey)
    }

    private func forgetWaitingTap() {
        keptTaps?.removeObject(forKey: Self.waitingTapKey)
    }

    /// A tap that was waiting for a call when Conduit closed waits again:
    /// its notification is gone, and closing Conduit ended any call on the
    /// phone, so it opens once Conduit is on screen with no call. Not one
    /// older than `waitingTapLifetime`.
    private func restoreWaitingTap() {
        guard let keptTaps, pendingTarget == nil, let data = keptTaps.data(forKey: Self.waitingTapKey) else { return }
        guard let tap = try? JSONDecoder().decode(WaitingTap.self, from: data),
              (0..<Self.waitingTapLifetime).contains(date().timeIntervalSince(tap.waitingSince)) else {
            forgetWaitingTap()
            return
        }
        let target = ConduitNotificationTarget(
            profile: tap.profile,
            profileName: tap.profileName,
            sessionId: tap.sessionId,
            durableSessionID: tap.durableSessionID,
            dashboardID: tap.dashboardID,
            relayGatewayID: tap.relayGatewayID,
            type: tap.type,
            decision: tap.decision
        )
        retainRelayGatewayID(for: target)
        pendingTarget = target
        pendingRouteAwaitsCall = true
        navigationAttempt += 1
    }

    /// Schedules another open of `target` after one that can still succeed
    /// failed, backing off (1 s, 2 s, 4 s, then every 8 s) until the window
    /// that started at the tap runs out; the failure after that clears the
    /// target. Returns whether a retry is scheduled.
    @discardableResult
    func handleFailedNotificationRoute(_ target: ConduitNotificationTarget) -> Bool {
        guard pendingTarget == target, let deadline = pendingRouteDeadline else {
            clearPendingTarget(target)
            return false
        }
        let failedAt = now()
        guard failedAt < deadline else {
            clearPendingTarget(target)
            return false
        }
        let backoff = min(self.retryDelay * (1 << min(pendingRetryCount, 3)), maxRetryDelay)
        let retryDelay = min(backoff, failedAt.duration(to: deadline))
        // When the retry is due, not when its task wakes: a sleep that ran
        // out while the app was suspended wakes late, and that is a late
        // open like any other.
        let dueAt = failedAt.advanced(by: retryDelay)
        pendingRetryCount += 1
        navigationRetryTask?.cancel()
        navigationRetryTask = Task { [weak self] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.navigationRetryTask = nil
            self.pendingRouteRetryFiredAt = dueAt
            self.navigationAttempt += 1
        }
        return true
    }

    /// Parses the routing payload into a notification target. Static and
    /// internal so the dashboard-identity parsing rules are testable without
    /// the singleton's registration state.
    static func parseNotificationTarget(from userInfo: [AnyHashable: Any]) -> ConduitNotificationTarget? {
        parseNotificationTarget(
            from: userInfo,
            records: e2eKeyStore.records(),
            knownGatewayIDs: NotificationSharedSettings.knownGatewayIDs,
            keysProvisioned: NotificationSharedSettings.keysProvisioned
        )
    }

    /// End-to-end encryption decides what a push may drive (#431): a sealed
    /// push routes only from its verified content and the pairing its key
    /// belongs to; plaintext routes only for pairings that never set up
    /// encryption; anything else routes nowhere.
    static func parseNotificationTarget(
        from userInfo: [AnyHashable: Any],
        records: [E2EKeyRecord],
        knownGatewayIDs: Set<String>,
        keysProvisioned: Bool,
        now: Date = Date()
    ) -> ConduitNotificationTarget? {
        target(
            for: NotificationE2E.evaluate(userInfo, records: records, knownGatewayIDs: knownGatewayIDs, keysProvisioned: keysProvisioned, now: now),
            userInfo: userInfo
        )
    }

    private static func target(for evaluation: NotificationE2E.Evaluation, userInfo: [AnyHashable: Any]) -> ConduitNotificationTarget? {
        switch evaluation {
        case .legacy:
            return parsePlaintextNotificationTarget(from: userInfo)
        case .untrusted:
            return nil
        case .verified(let verified):
            return target(from: verified.routingPayload)
        }
    }

    private static func parsePlaintextNotificationTarget(from userInfo: [AnyHashable: Any]) -> ConduitNotificationTarget? {
        let direct = userInfo["conduit"] as? [String: Any]
        let nested = (userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any]
        // The relay's optimized APNs layout keeps the structured decision
        // ONLY in body.conduit, with the top-level conduit copy reduced to a
        // routing stub for raw-APNs readers — so whichever copy actually
        // carries a decision must win, nested first (that is where the
        // optimized layout puts it). Payloads without a decision anywhere
        // fall back to plain routing, preferring the legacy top-level copy.
        // A call's details travel the same way (#449).
        let payload: [String: Any]
        if nested?["decision"] is [String: Any] || nested?["call"] is [String: Any] {
            payload = nested ?? [:]
        } else if direct?["decision"] is [String: Any] || direct?["call"] is [String: Any] {
            payload = direct ?? [:]
        } else {
            payload = direct ?? nested ?? [:]
        }
        return target(from: payload)
    }

    private static func target(from payload: [String: Any]) -> ConduitNotificationTarget? {
        guard let sessionId = payload["session_id"] as? String,
              !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let durableSessionID = Self.routingDurableSessionID(from: payload)
        let profile = (payload["profile"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileName = (payload["profile_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (payload["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The relay stamps `dashboard_id` (an opaque Conduit dashboard UUID)
        // from the authenticated gateway's pairing binding. A malformed value
        // is preserved as its own failure mode: it must fail closed, never
        // degrade to the legacy unscoped route.
        let rawDashboardID = (payload["dashboard_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMalformedDashboardID: Bool
        let dashboardID: UUID?
        if let rawDashboardID, !rawDashboardID.isEmpty {
            if let uuid = UUID(uuidString: rawDashboardID) {
                dashboardID = uuid
                hasMalformedDashboardID = false
            } else {
                dashboardID = nil
                hasMalformedDashboardID = true
            }
        } else {
            dashboardID = nil
            hasMalformedDashboardID = false
        }
        // The relay gateway discriminator is opaque routing metadata from
        // the authenticated-gateway-stamped payload; retained verbatim.
        let rawRelayGatewayID = (payload["gateway_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ConduitNotificationTarget(
            profile: profile?.isEmpty == false ? profile : nil,
            profileName: profileName?.isEmpty == false ? profileName : nil,
            sessionId: sessionId,
            durableSessionID: durableSessionID,
            dashboardID: dashboardID,
            hasMalformedDashboardID: hasMalformedDashboardID,
            relayGatewayID: rawRelayGatewayID?.isEmpty == false ? rawRelayGatewayID : nil,
            type: type?.isEmpty == false ? type : nil,
            decision: pendingDecision(from: payload),
            call: HermesCallRequest.parse(payload["call"], type: type)
        )
    }

    /// The durable conversation id a routing payload may explicitly carry
    /// (`stored_session_id`, or the Hermes-native `session_key` spelling).
    /// Only a top-level routing field counts: an approval card's
    /// `decision.session_key` is the answer key for `approval.respond`, not
    /// this conversation's routing identity, and must not be promoted into
    /// one. Older notifier builds send neither field; nil degrades to alias
    /// resolution.
    private static func routingDurableSessionID(from payload: [String: Any]) -> String? {
        for key in ["stored_session_id", "session_key"] {
            guard let value = payload[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Parses the structured decision content the relay forwards alongside a
    /// decision notification (see the background-arrival design doc). Returns
    /// nil for non-decision notifications or malformed/unknown payloads so the
    /// notification degrades to its ordinary routing target. An approval
    /// requires a session key to answer, a description to display, and at
    /// least one usable choice — otherwise a cached card could render the
    /// approval view's default action set, which the payload never promised.
    private static func pendingDecision(from payload: [String: Any]) -> PendingDecisionPayload? {
        guard let decision = payload["decision"] as? [String: Any],
              let kind = (decision["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !kind.isEmpty else {
            return nil
        }
        switch kind {
        case "approval":
            guard let sessionKey = (decision["session_key"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !sessionKey.isEmpty,
                let description = (decision["description"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !description.isEmpty,
                let rawChoices = decision["choices"] as? [Any] else {
                return nil
            }
            let choices = rawChoices
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !choices.isEmpty else { return nil }
            return .approval(sessionKey: sessionKey, description: description, choices: choices)
        case "clarify":
            // The request id must be a plugin-minted `conduit-push-…` id: any
            // other id would be routed to the gateway's clarify.respond, which
            // can never resolve it.
            guard let requestId = (decision["request_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                requestId.hasPrefix(PendingDecisionPayload.relayRequestPrefix),
                requestId.count > PendingDecisionPayload.relayRequestPrefix.count else {
                return nil
            }
            // Batch form (current notifier): questions[] with qids preserved.
            // The parser upholds the same guarantees as the native parser:
            // duplicate qids collapse (first wins) so SwiftUI Identifiable
            // lists and per-question answer targets stay unambiguous.
            if let rawQuestions = decision["questions"] as? [[String: Any]],
               !rawQuestions.isEmpty {
                var questions: [ClarifyQuestion] = []
                var seenQids = Set<String>()
                for entry in rawQuestions {
                    guard let question = Self.pushClarifyQuestion(from: entry),
                          seenQids.insert(question.id).inserted else { continue }
                    questions.append(question)
                }
                if !questions.isEmpty {
                    return .clarifyBatch(requestId: requestId, questions: questions)
                }
                // A questions[] payload where nothing survived falls through
                // to the legacy scalar decoding below.
            }
            guard let question = (decision["question"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !question.isEmpty else {
                return nil
            }
            let choices = ((decision["choices"] as? [Any])?
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }) ?? []
            return .clarify(requestId: requestId, question: question, choices: choices)
        default:
            return nil
        }
    }

    /// One pushed batch question. The plugin relays the gateway's wire entry
    /// (qid/question/choices/multi_select); qids are preserved as identity —
    /// they are NOT synthetic, so per-question relay answers can address
    /// them.
    private static func pushClarifyQuestion(from entry: [String: Any]) -> ClarifyQuestion? {
        guard let question = (entry["question"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !question.isEmpty else {
            return nil
        }
        guard let qid = (entry["qid"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !qid.isEmpty else {
            return nil
        }
        let rawChoices = entry["choices"] as? [Any] ?? []
        // Duplicate choice values collapse (first wins) — they would render
        // as duplicate rows and answer ambiguously.
        var seenValues = Set<String>()
        let choices = rawChoices
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenValues.insert($0).inserted }
            .map { ClarifyChoice(label: $0, value: $0) }
        let multiSelect = (entry["multi_select"] as? Bool) == true && !choices.isEmpty
        return ClarifyQuestion(id: qid, question: question, choices: choices, multiSelect: multiSelect)
    }

    private func requestDeviceToken(timeout: Duration = .seconds(20)) async throws -> String {
        if let deviceToken { return deviceToken }
        // One request at a time: a second would overwrite the pending
        // continuation and leave its caller waiting forever.
        guard tokenContinuation == nil else {
            throw PushNotificationError.tokenRequestPending
        }
        // APNs can stay silent. Without a timeout, callers that hold
        // `isWorking` would keep the notification controls, including the
        // relay field, disabled until relaunch.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            // No-op if the token already arrived (continuation is nil).
            self?.failTokenRequest(PushNotificationError.tokenTimeout)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            tokenContinuation = continuation
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func register(deviceToken: String) async throws {
        if registration != nil {
            try await queueRegistrationUpdate(deviceToken: deviceToken)?.value
            return
        }
        // No registration yet, so `relayURL` is the configured relay.
        let issuer = relayURL
        // The credential it issues could never be used over a transport
        // the policy refuses, so don't register there at all.
        guard RelayTransportPolicy.allowsCredentialTransport(issuer) else {
            throw RelayDecisionError.insecureTransport
        }
        let voipToken = self.voipToken
        let watchToken = ringingWatchVoIPToken
        let locationToken = relayLocationToken
        var body = RegistrationRequest(bundleID: bundleID, deviceToken: deviceToken, environment: "production", preferences: preferences, voipToken: voipToken, watchVoipToken: watchToken, locationToken: locationToken)
        var (data, response) = try await URLSession.shared.data(for: jsonRequest(path: "/v1/installations", method: "POST", body: body))
        if Self.requiresTokenProof(response: response, data: data) {
            body.tokenProof = try await proveDeviceToken(deviceToken)
            (data, response) = try await URLSession.shared.data(for: jsonRequest(path: "/v1/installations", method: "POST", body: body))
        }
        try validate(response: response, data: data)
        let responseBody = try JSONDecoder().decode(RegistrationResponse.self, from: data)
        registration = StoredRegistration(credential: responseBody.credential, installationID: responseBody.installation.id, preferences: responseBody.installation.preferences ?? preferences, relayURL: issuer.absoluteString, deviceToken: deviceToken)
        // Only a relay that rings (0.9+) keeps it; an older one is asked
        // again at the next update.
        registration?.voipToken = responseBody.installation.voip == true ? voipToken : nil
        // Likewise the Watch's, on a relay that rings it (0.10+).
        registration?.watchVoipToken = responseBody.installation.watchVoip == true ? watchToken : nil
        // And the location push token, which goes only to a relay that
        // says it sends locates (`location-push`).
        registration?.locationToken = responseBody.installation.location != false ? locationToken : nil
        preferences = registration!.preferences
        persistRegistration()
        // A PushKit token that came while this was on its way goes next
        // (at first launch both arrive together), and so does a newer push
        // token.
        if self.voipToken != voipToken || ringingWatchVoIPToken != watchToken || relayLocationToken != locationToken
            || (self.deviceToken.map { $0 != deviceToken } ?? false) {
            observeTokenUpdate(queueRegistrationUpdate())
        }
    }

    private func updateRegistration(deviceToken: String? = nil) async throws {
        guard let registration else { return }
        let voipToken = self.voipToken
        let voipChange: VoIPTokenChange = registration.voipToken == voipToken ? .keep : (voipToken.map(VoIPTokenChange.set) ?? .clear)
        let watchToken = ringingWatchVoIPToken
        let watchChange: VoIPTokenChange = registration.watchVoipToken == watchToken ? .keep : (watchToken.map(VoIPTokenChange.set) ?? .clear)
        let locationToken = relayLocationToken
        let locationChange = locationTokenChange(registered: registration.locationToken)
        // What the relay keeps once this lands, rather than whatever the
        // preferences are by then.
        let sentPreferences = preferences
        var body = UpdateRegistrationRequest(deviceToken: deviceToken ?? self.deviceToken, preferences: sentPreferences, voipToken: voipChange, watchVoipToken: watchChange, locationToken: locationChange)
        let path = "/v1/installations/\(registration.installationID)"
        let data: Data
        do {
            var (sent, response) = try await sendRegistrationUpdate(jsonRequest(path: path, method: "PUT", body: body, credential: registration.credential))
            // A new device token needs the same proof as registering it.
            if Self.requiresTokenProof(response: response, data: sent), let token = body.deviceToken {
                body.tokenProof = try await proveDeviceToken(token)
                (sent, response) = try await sendRegistrationUpdate(jsonRequest(path: path, method: "PUT", body: body, credential: registration.credential))
            }
            try validate(response: response, data: sent)
            data = sent
        } catch {
            // Superseded meanwhile: its failure is about an installation
            // that is gone, not one to report.
            guard self.registration?.installationID == registration.installationID else { return }
            throw error
        }
        // The relay moved (or push was turned off) while this was on its
        // way: its answer describes an installation that is gone.
        guard self.registration?.installationID == registration.installationID else { return }
        self.registration?.preferences = sentPreferences
        if let token = body.deviceToken {
            self.registration?.deviceToken = token
            if token == self.deviceToken { clearTokenUpdateError() }
        }
        let installation = (try? JSONDecoder().decode(UpdateRegistrationResponse.self, from: data))?.installation
        // Another update sent a newer token meanwhile, and this one may
        // have landed after it: the newer token goes again, last.
        var newerToken = false
        if voipChange != .keep {
            let rings = installation?.voip == true
            self.registration?.voipToken = rings ? voipToken : nil
            newerToken = rings && voipToken != self.voipToken
        }
        if watchChange != .keep {
            let rings = installation?.watchVoip == true
            self.registration?.watchVoipToken = rings ? watchToken : nil
            newerToken = newerToken || (rings && watchToken != ringingWatchVoIPToken)
        }
        if locationChange != .keep {
            let locates = installation?.location != false
            self.registration?.locationToken = locates ? locationToken : nil
            newerToken = newerToken || (locates && locationToken != relayLocationToken)
        }
        persistRegistration()
        // A switch flipped meanwhile goes next, if no update queued since
        // has sent it already.
        if newerToken || preferences != sentPreferences { queueRegistrationUpdate() }
    }

    private func jsonRequest<Body: Encodable>(path: String, method: String, body: Body, credential: String? = nil) throws -> URLRequest {
        let url = relayURL.appending(path: path)
        // A request carrying the pairing credential enforces the transport
        // policy (HTTPS, or loopback HTTP for self-hosted development).
        if credential != nil, !RelayTransportPolicy.allowsCredentialTransport(url) {
            throw RelayDecisionError.insecureTransport
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let credential {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PushNotificationError.relay(Self.relayErrorMessage(data: data))
        }
    }

    /// What a relay refusal means, from its `{"error": "<code>"}` body
    /// (relay/src/server.mjs): a known code as a sentence, another code
    /// named, and a `message` (no relay sends one today) as it is.
    nonisolated static func relayErrorMessage(data: Data) -> String {
        let body = try? JSONDecoder().decode(RelayErrorBody.self, from: data)
        switch body?.error {
        case "unauthorized":
            return AppLocalization.string("The push relay no longer knows this iPhone. Turn notifications off and on again in Settings > Notifications.")
        case "invalid_topic", "production_only":
            return AppLocalization.string("The push relay can't send to this build of Conduit. Check the relay's APNs settings.")
        case "invalid_device_token", "token_proof_required", "token_proof_invalid":
            return AppLocalization.string("The push relay couldn't confirm this iPhone's push token. Try again.")
        case "installation_limit_reached", "gateway_limit_reached":
            return AppLocalization.string("The push relay has no room for this iPhone. Ask whoever runs it to make room.")
        case "rate_limited":
            return AppLocalization.string("The push relay is busy. Try again in a minute.")
        case "answer_too_large":
            return RelayDecisionError.answerTooLarge.errorDescription ?? ""
        case let code? where !code.isEmpty:
            return AppLocalization.string("Push relay request failed (\(code)).")
        default:
            if let message = body?.message, !message.isEmpty { return message }
            return AppLocalization.string("Push relay request failed.")
        }
    }

    private func persistRegistration() {
        guard let registration, let data = try? JSONEncoder().encode(registration) else { return }
        KeychainHelper.savePushRegistration(data)
    }
}

private struct LiveActivityRegistration: Encodable {
    let pushToken: String
    let sessionIDs: [String]

    enum CodingKeys: String, CodingKey {
        case pushToken = "push_token"
        case sessionIDs = "session_ids"
    }
}

private struct LiveActivityRemoval: Encodable {
    let pushToken: String

    enum CodingKeys: String, CodingKey {
        case pushToken = "push_token"
    }
}

private struct StoredRegistration: Codable {
    let credential: String
    let installationID: String
    var preferences: ConduitNotificationPreferences
    /// The relay that issued `credential`. Optional so registrations saved
    /// before it was recorded still decode.
    var relayURL: String?
    /// The APNs token the relay last accepted. Nil for registrations saved
    /// before it was recorded.
    var deviceToken: String? = nil
    /// The PushKit token the relay rings (#449); nil when it has none.
    var voipToken: String? = nil
    /// The Apple Watch's PushKit token the relay rings too.
    var watchVoipToken: String? = nil
    /// The location push token the relay sends locates to.
    var locationToken: String? = nil
}

private struct RegistrationRequest: Encodable {
    let bundleID: String
    let deviceToken: String
    let environment: String
    let preferences: ConduitNotificationPreferences
    var voipToken: String? = nil
    var watchVoipToken: String? = nil
    var locationToken: String? = nil
    /// The relay's pushed nonce, once it asked for one.
    var tokenProof: String? = nil
    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id", deviceToken = "device_token", environment, preferences, voipToken = "voip_token"
        case watchVoipToken = "watch_voip_token", locationToken = "location_token", tokenProof = "token_proof"
    }
}

private struct TokenChallengeRequest: Encodable {
    let bundleID: String
    let deviceToken: String
    let environment: String
    enum CodingKeys: String, CodingKey { case bundleID = "bundle_id", deviceToken = "device_token", environment }
}

/// What an update does to the relay's PushKit token.
enum VoIPTokenChange: Equatable {
    case keep
    case clear
    case set(String)
}

struct UpdateRegistrationRequest: Encodable {
    let deviceToken: String?
    let preferences: ConduitNotificationPreferences
    var voipToken: VoIPTokenChange = .keep
    var watchVoipToken: VoIPTokenChange = .keep
    var locationToken: VoIPTokenChange = .keep
    /// The relay's pushed nonce, when the device token changed.
    var tokenProof: String? = nil
    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token", preferences, voipToken = "voip_token", watchVoipToken = "watch_voip_token"
        case locationToken = "location_token", tokenProof = "token_proof"
    }

    /// A token is left out to keep it, null to clear it.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(deviceToken, forKey: .deviceToken)
        try container.encodeIfPresent(tokenProof, forKey: .tokenProof)
        try container.encode(preferences, forKey: .preferences)
        for (change, key) in [(voipToken, CodingKeys.voipToken), (watchVoipToken, CodingKeys.watchVoipToken), (locationToken, CodingKeys.locationToken)] {
            switch change {
            case .keep: break
            case .clear: try container.encodeNil(forKey: key)
            case .set(let token): try container.encode(token, forKey: key)
            }
        }
    }
}

private struct RegistrationResponse: Decodable {
    struct Installation: Decodable {
        let id: String
        let preferences: ConduitNotificationPreferences?
        let voip: Bool?
        let watchVoip: Bool?
        let location: Bool?
        enum CodingKeys: String, CodingKey { case id, preferences, voip, watchVoip = "watch_voip", location }
    }
    let credential: String
    let installation: Installation
}

private struct UpdateRegistrationResponse: Decodable {
    struct Installation: Decodable {
        let voip: Bool?
        let watchVoip: Bool?
        let location: Bool?
        enum CodingKeys: String, CodingKey { case voip, watchVoip = "watch_voip", location }
    }
    let installation: Installation?
}

private struct PairingCreateRequest: Encodable {
    let dashboardID: String
    enum CodingKeys: String, CodingKey { case dashboardID = "dashboard_id" }
}

private struct PairingResponse: Decodable {
    let pairingCode: String
    let expiresAt: String?
    enum CodingKeys: String, CodingKey { case pairingCode = "pairing_code", expiresAt = "expires_at" }
}

/// A relay refusal: `error` is its code; `message` only as a fallback.
private struct RelayErrorBody: Decodable {
    let error: String?
    let message: String?
}

private enum PushNotificationError: LocalizedError {
    case permissionDenied
    case tokenTimeout
    case tokenRequestPending
    case tokenProofTimeout
    case relay(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return AppLocalization.string("Allow notifications in Settings to continue.")
        case .tokenTimeout: return AppLocalization.string("Apple didn't return a push token in time. Check your connection and try again.")
        case .tokenRequestPending: return AppLocalization.string("Still waiting for a push token from Apple. Try again in a moment.")
        case .tokenProofTimeout: return AppLocalization.string("The push relay's check didn't reach this iPhone in time. Check your connection and try again.")
        case .relay(let message): return message
        }
    }
}
