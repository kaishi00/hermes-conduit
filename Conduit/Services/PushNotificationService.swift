import Foundation
import UIKit
import UserNotifications

struct ConduitNotificationTarget: Equatable, Identifiable {
    let profile: String?
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
    var id: String { "\(dashboardID?.uuidString ?? "none"):\(relayGatewayID ?? "nogw"):\(profile ?? "default"):\(sessionId):\(type ?? "")" }

    init(
        profile: String?,
        sessionId: String,
        durableSessionID: String? = nil,
        dashboardID: UUID? = nil,
        hasMalformedDashboardID: Bool = false,
        relayGatewayID: String? = nil,
        type: String?,
        decision: PendingDecisionPayload? = nil,
        call: HermesCallRequest? = nil
    ) {
        self.profile = profile
        self.sessionId = sessionId
        self.durableSessionID = durableSessionID
        self.dashboardID = dashboardID
        self.hasMalformedDashboardID = hasMalformedDashboardID
        self.relayGatewayID = relayGatewayID
        self.type = type
        self.decision = decision
        self.call = call
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
        savedDashboardIDs: [UUID]
    ) -> Outcome {
        if hasMalformedDashboardID {
            return .failClosed(.unrecognizedDashboard)
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
enum PendingDecisionPayload: Equatable {
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
    init(gateways: [RelayMetaInfo.Gateway], activeDashboardID: UUID?, savedDashboardIDs: [UUID]) {
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
                savedDashboardIDs: savedDashboardIDs
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
    static let shared = PushNotificationService()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiry: String?
    @Published private(set) var pendingTarget: ConduitNotificationTarget?
    @Published private(set) var navigationAttempt = 0
    @Published var preferences = ConduitNotificationPreferences() {
        // The Notification Service Extension decides whether a decrypted
        // push shows its real text; it reads this from the App Group.
        didSet { NotificationSharedSettings.showPreviews = preferences.showPreviews }
    }
    /// Relay gateways this iPhone holds an end-to-end encryption key for
    /// (#431). Settings > Notifications marks those pairings encrypted.
    @Published private(set) var encryptedGatewayIDs: Set<String> = []
    @Published private(set) var relayMeta: RelayMetaInfo? {
        // Plaintext from a pairing this iPhone has never seen listed isn't
        // trusted once it holds an encryption key (#431). Kept on failure.
        didSet {
            guard let relayMeta else { return }
            NotificationSharedSettings.knownGatewayIDs = NotificationE2E.knownGatewayIDs(
                listed: Set(relayMeta.gateways.map(\.id)),
                previous: NotificationSharedSettings.knownGatewayIDs,
                // Keys that can't be read count as held.
                holdsKeys: NotificationSharedSettings.keysProvisioned || Self.e2eKeyStore.readRecords()?.isEmpty != true
            )
        }
    }
    @Published private(set) var isFetchingMeta = false
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
    nonisolated static let defaultRelayURL = URL(string: "https://push.milim.dev")!

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
    private let bundleID = "com.milim.relay"
    private var registration: StoredRegistration?
    private var deviceToken: String?
    private var tokenContinuation: CheckedContinuation<String, Error>?
    private var navigationRetryTask: Task<Void, Never>?
    private var pendingRetryCount = 0
    private let maxNotificationRetriesPerTarget = 1
    private let retryDelay: Duration

    var isEnabled: Bool { registration != nil && preferences.enabled }
    var statusText: String {
        if isWorking { return AppLocalization.string("Updating") }
        if isEnabled { return AppLocalization.string("Enabled") }
        if authorizationStatus == .denied { return AppLocalization.string("Notifications denied") }
        return AppLocalization.string("Off")
    }

    init(retryDelay: Duration = .seconds(1.5)) {
        self.retryDelay = retryDelay
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
            preferences = saved.preferences
            if needsRelayStamp { persistRegistration() }
        }
        NotificationSharedSettings.showPreviews = preferences.showPreviews
        refreshEncryptionState()
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
    private var isProvisioningEncryption = false

    func refreshEncryptionState() {
        // Unreadable (a launch before first unlock): keep what was shown.
        guard let records = Self.e2eKeyStore.readRecords() else { return }
        encryptedGatewayIDs = Set(records.map(\.gatewayID))
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
        for profile in profiles {
            let path = DashboardPath.withProfile(Self.e2ePath, profile: profile)
            guard let status = try? await request(path, "GET", nil),
                  let gatewayID = Self.gatewayNeedingEncryptionKey(status: status, installationID: installationID, records: records) else {
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
            // The plugin now holds only this key for the pairing.
            for stale in records
            where stale.installationID == installationID && stale.gatewayID == gatewayID && stale.kid != record.kid {
                Self.e2eKeyStore.remove(kid: stale.kid)
            }
            records.removeAll { $0.installationID == installationID && $0.gatewayID == gatewayID }
            records.append(record)
        }
        refreshEncryptionState()
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
              let record = records.first(where: { $0.gatewayID == gatewayID && $0.installationID == installationID }) else {
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
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                relayMeta = nil
                return
            }
            relayMeta = try JSONDecoder().decode(RelayMetaInfo.self, from: data)
        } catch {
            relayMeta = nil
        }
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
    /// exists when the batch-capable plugin pushed it.
    @discardableResult
    func respondToRelayDecisionQuestion(
        requestId: String,
        questionId: String,
        answer: String
    ) async throws -> RelayQuestionOutcome {
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

    /// Shared relay decision POST. Contract: 200 = accepted (body may carry
    /// `remaining`), 404 = unknown decision, 409 = already locked, 410 =
    /// decision released by the native path.
    private func relayDecisionRespond(
        requestId: String,
        body: [String: String]
    ) async throws -> RelayRespondOutcome {
        guard let registration else { throw RelayDecisionError.unregistered }
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
                throw RelayDecisionError.server(http.statusCode)
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
        guard !isWorking else { return }
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
        // disabled while working, so this only catches the race window.
        guard !isWorking else { return }
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
        guard registration != nil else { return }
        do {
            try await updateRegistration()
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
        // cleared (and useless) once the move lands.
        guard !isWorking else { return }
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
            let pairing = try JSONDecoder().decode(PairingResponse.self, from: data)
            pairingCode = pairing.pairingCode
            pairingExpiry = pairing.expiresAt
        } catch {
            lastError = UserFacingError.message(for: error)
        }
    }

    func didReceiveDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        tokenContinuation?.resume(returning: token)
        tokenContinuation = nil
        if registration != nil {
            Task { try? await updateRegistration() }
        }
    }

    func didFailToRegister(_ error: Error) {
        tokenContinuation?.resume(throwing: error)
        tokenContinuation = nil
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
        guard let registration, registration.voipToken != token else { return }
        Task { try? await updateRegistration() }
    }

    /// A "Hermes wants to talk" notification Conduit posted itself (#449).
    func receiveLocalCallNotification(_ userInfo: [AnyHashable: Any]) {
        guard let target = HermesCallNotifications.localTarget(from: userInfo) else { return }
        route(target)
    }

    private func route(_ target: ConduitNotificationTarget) {
        navigationRetryTask?.cancel()
        navigationRetryTask = nil
        pendingTarget = target
        pendingRetryCount = 0
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
    }

    @discardableResult
    func handleFailedNotificationRoute(_ target: ConduitNotificationTarget) -> Bool {
        guard pendingTarget == target,
              pendingRetryCount < maxNotificationRetriesPerTarget else {
            clearPendingTarget(target)
            return false
        }
        pendingRetryCount += 1
        navigationRetryTask?.cancel()
        let retryDelay = self.retryDelay
        navigationRetryTask = Task { [weak self] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.navigationRetryTask = nil
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
            self?.didFailToRegister(PushNotificationError.tokenTimeout)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            tokenContinuation = continuation
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func register(deviceToken: String) async throws {
        if registration != nil {
            try await updateRegistration(deviceToken: deviceToken)
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
        let body = RegistrationRequest(bundleID: bundleID, deviceToken: deviceToken, environment: "production", preferences: preferences, voipToken: voipToken)
        var request = try jsonRequest(path: "/v1/installations", method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let responseBody = try JSONDecoder().decode(RegistrationResponse.self, from: data)
        registration = StoredRegistration(credential: responseBody.credential, installationID: responseBody.installation.id, preferences: responseBody.installation.preferences ?? preferences, relayURL: issuer.absoluteString)
        // Only a relay that rings (0.9+) keeps it; an older one is asked
        // again at the next update.
        registration?.voipToken = responseBody.installation.voip == true ? voipToken : nil
        preferences = registration!.preferences
        persistRegistration()
    }

    private func updateRegistration(deviceToken: String? = nil) async throws {
        guard let registration else { return }
        let voipToken = self.voipToken
        let voipChange: VoIPTokenChange = registration.voipToken == voipToken ? .keep : (voipToken.map(VoIPTokenChange.set) ?? .clear)
        let body = UpdateRegistrationRequest(deviceToken: deviceToken ?? self.deviceToken, preferences: preferences, voipToken: voipChange)
        var request = try jsonRequest(path: "/v1/installations/\(registration.installationID)", method: "PUT", body: body, credential: registration.credential)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        self.registration?.preferences = preferences
        if voipChange != .keep {
            let rings = (try? JSONDecoder().decode(UpdateRegistrationResponse.self, from: data))?.installation?.voip == true
            self.registration?.voipToken = rings ? voipToken : nil
        }
        persistRegistration()
    }

    private func jsonRequest<Body: Encodable>(path: String, method: String, body: Body, credential: String? = nil) throws -> URLRequest {
        let url = relayURL.appending(path: path)
        // A request carrying the pairing credential enforces the transport
        // policy (HTTPS, or loopback HTTP for self-hosted development).
        if let credential, !RelayTransportPolicy.allowsCredentialTransport(url) {
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
            let detail = (try? JSONDecoder().decode(RelayError.self, from: data).message) ?? AppLocalization.string("Push relay request failed.")
            throw PushNotificationError.relay(detail)
        }
    }

    private func persistRegistration() {
        guard let registration, let data = try? JSONEncoder().encode(registration) else { return }
        KeychainHelper.savePushRegistration(data)
    }
}

private struct StoredRegistration: Codable {
    let credential: String
    let installationID: String
    var preferences: ConduitNotificationPreferences
    /// The relay that issued `credential`. Optional so registrations saved
    /// before it was recorded still decode.
    var relayURL: String?
    /// The PushKit token the relay rings (#449); nil when it has none.
    var voipToken: String? = nil
}

private struct RegistrationRequest: Encodable {
    let bundleID: String
    let deviceToken: String
    let environment: String
    let preferences: ConduitNotificationPreferences
    var voipToken: String? = nil
    enum CodingKeys: String, CodingKey { case bundleID = "bundle_id", deviceToken = "device_token", environment, preferences, voipToken = "voip_token" }
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
    enum CodingKeys: String, CodingKey { case deviceToken = "device_token", preferences, voipToken = "voip_token" }

    /// `voip_token` is left out to keep it, null to clear it.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(deviceToken, forKey: .deviceToken)
        try container.encode(preferences, forKey: .preferences)
        switch voipToken {
        case .keep: break
        case .clear: try container.encodeNil(forKey: .voipToken)
        case .set(let token): try container.encode(token, forKey: .voipToken)
        }
    }
}

private struct RegistrationResponse: Decodable {
    struct Installation: Decodable { let id: String; let preferences: ConduitNotificationPreferences?; let voip: Bool? }
    let credential: String
    let installation: Installation
}

private struct UpdateRegistrationResponse: Decodable {
    struct Installation: Decodable { let voip: Bool? }
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

private struct RelayError: Decodable { let message: String? }

private enum PushNotificationError: LocalizedError {
    case permissionDenied
    case tokenTimeout
    case tokenRequestPending
    case relay(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return AppLocalization.string("Allow notifications in Settings to continue.")
        case .tokenTimeout: return AppLocalization.string("Apple didn't return a push token in time. Check your connection and try again.")
        case .tokenRequestPending: return AppLocalization.string("Still waiting for a push token from Apple. Try again in a moment.")
        case .relay(let message): return message
        }
    }
}
