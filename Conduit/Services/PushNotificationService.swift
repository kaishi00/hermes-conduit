import Foundation
import UIKit
import UserNotifications

struct ConduitNotificationTarget: Equatable, Identifiable {
    let profile: String?
    let sessionId: String
    let type: String?
    /// Structured decision content carried alongside a decision notification.
    /// Lets Conduit render an answerable card from the push payload alone when
    /// the one-shot gateway stream event was missed while the app was
    /// backgrounded. Nil for non-decision notifications.
    let decision: PendingDecisionPayload?
    var id: String { "\(profile ?? "default"):\(sessionId):\(type ?? "")" }

    init(
        profile: String?,
        sessionId: String,
        type: String?,
        decision: PendingDecisionPayload? = nil
    ) {
        self.profile = profile
        self.sessionId = sessionId
        self.type = type
        self.decision = decision
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

enum NotificationSessionResolver {
    /// Hermes notifications identify a live runtime session, while
    /// `session.resume` is keyed by the durable stored session. Catalog rows
    /// retain both identities so a notification can be routed without asking
    /// the gateway to resume a runtime-only key.
    static func resumableSessionID(
        for notificationSessionID: String,
        in sessions: [SessionSummary]
    ) -> String {
        let normalizedID = notificationSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return normalizedID }
        guard let session = sessions.first(where: { session in
            session.id == normalizedID || session.alternateIds.contains(normalizedID)
        }) else {
            return normalizedID
        }
        return session.storedSessionId ?? session.id
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
    @Published var preferences = ConduitNotificationPreferences()
    @Published private(set) var relayMeta: RelayMetaInfo?
    @Published private(set) var isFetchingMeta = false

    private var relayURL: URL {
        if let saved = UserDefaults.standard.string(forKey: "conduit.relayURL"),
           let url = URL(string: saved) {
            return url
        }
        return URL(string: "https://push.milim.dev")!
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
        if isWorking { return "Updating" }
        if isEnabled { return "Enabled" }
        if authorizationStatus == .denied { return "Notifications denied" }
        return "Off"
    }

    init(retryDelay: Duration = .seconds(1.5)) {
        self.retryDelay = retryDelay
        if let data = KeychainHelper.loadPushRegistration(),
           let saved = try? JSONDecoder().decode(StoredRegistration.self, from: data) {
            registration = saved
            preferences = saved.preferences
        }
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
        var request = URLRequest(url: relayURL.appending(path: "/v1/meta"))
        request.setValue("Bearer \(registration.credential)", forHTTPHeaderField: "Authorization")
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
        /// Another device locked this qid first.
        case questionAlreadyLocked
        /// The decision is gone (timed out or completed elsewhere).
        case noLongerActive
    }

    /// Outcome of answering a whole plugin-minted clarify
    /// (`conduit-push-…`) through the relay's decision loop (legacy
    /// single-question shape).
    enum RelayDecisionOutcome {
        case answered
        /// The decision expired (clarify timed out server-side or was answered
        /// on another surface first).
        case noLongerActive
        /// Another device already answered this decision.
        case alreadyAnsweredElsewhere
    }

    enum RelayDecisionError: LocalizedError {
        case unregistered
        case transport(String)
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .unregistered: return "This device is not paired with a push relay."
            case .transport(let message): return "Could not reach the push relay: \(message)"
            case .server(let status): return "The push relay rejected the answer (HTTP \(status))."
            }
        }
    }

    /// Raw relay decision respond result. 404 and 409 are distinct server
    /// states and must not be collapsed: 404 = decision gone, 409 = already
    /// locked (whole decision for the legacy shape, that question only for
    /// the batch shape).
    private enum RelayRespondOutcome {
        case accepted(remaining: [String]?)
        case noLongerActive
        case alreadyLocked
    }

    /// Answers a plugin-minted clarify decision through the relay. The gateway
    /// polls the relay for this answer while its clarify middleware blocks, so
    /// the agent thread unblocks exactly as if `clarify.respond` had been used.
    @discardableResult
    func respondToRelayDecision(
        requestId: String,
        answer: String
    ) async throws -> RelayDecisionOutcome {
        switch try await relayDecisionRespond(requestId: requestId, body: ["answer": answer]) {
        case .accepted: return .answered
        case .alreadyLocked: return .alreadyAnsweredElsewhere
        case .noLongerActive: return .noLongerActive
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
        switch try await relayDecisionRespond(
            requestId: requestId,
            body: ["question_id": questionId, "answer": answer]
        ) {
        case .accepted(let remaining): return .locked(remaining: remaining)
        case .alreadyLocked: return .questionAlreadyLocked
        case .noLongerActive: return .noLongerActive
        }
    }

    /// Shared relay decision POST. Contract: 200 = accepted (body may carry
    /// `remaining`), 404 = decision no longer active, 409 = already locked.
    private func relayDecisionRespond(
        requestId: String,
        body: [String: String]
    ) async throws -> RelayRespondOutcome {
        guard let registration else { throw RelayDecisionError.unregistered }
        var request = URLRequest(url: relayURL.appending(path: "/v1/decisions/\(requestId)/respond"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(registration.credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RelayDecisionError.transport("invalid response")
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
            default:
                throw RelayDecisionError.server(http.statusCode)
            }
        } catch let error as RelayDecisionError {
            throw error
        } catch {
            throw RelayDecisionError.transport(error.localizedDescription)
        }
    }

    func enable() async {
        lastError = nil
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
            lastError = error.localizedDescription
        }
    }

    func disable() async {
        lastError = nil
        isWorking = true
        defer { isWorking = false }
        if let registration {
            do {
                var request = URLRequest(url: relayURL.appending(path: "/v1/installations/\(registration.installationID)"))
                request.httpMethod = "DELETE"
                request.setValue("Bearer \(registration.credential)", forHTTPHeaderField: "Authorization")
                _ = try await URLSession.shared.data(for: request)
            } catch {
                // The local credential is still removed: a later enable creates
                // a fresh, revocable installation rather than retaining stale state.
            }
        }
        registration = nil
        preferences.enabled = false
        KeychainHelper.clearPushRegistration()
    }

    func setPreference(_ keyPath: WritableKeyPath<ConduitNotificationPreferences, Bool>, enabled: Bool) async {
        preferences[keyPath: keyPath] = enabled
        guard registration != nil else { return }
        do {
            try await updateRegistration()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createPairingCode() async {
        pairingCode = nil
        pairingExpiry = nil
        lastError = nil
        guard let registration else {
            lastError = "Enable notifications on this phone before creating a pairing code."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            var request = URLRequest(url: relayURL.appending(path: "/v1/installations/\(registration.installationID)/pairings"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(registration.credential)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let pairing = try JSONDecoder().decode(PairingResponse.self, from: data)
            pairingCode = pairing.pairingCode
            pairingExpiry = pairing.expiresAt
        } catch {
            lastError = error.localizedDescription
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
        guard let target = notificationTarget(from: userInfo) else { return }
        navigationRetryTask?.cancel()
        navigationRetryTask = nil
        pendingTarget = target
        pendingRetryCount = 0
        navigationAttempt += 1
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

    private func notificationTarget(from userInfo: [AnyHashable: Any]) -> ConduitNotificationTarget? {
        let direct = userInfo["conduit"] as? [String: Any]
        let nested = (userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any]
        guard let payload = direct ?? nested,
              let sessionId = payload["session_id"] as? String,
              !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let profile = (payload["profile"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (payload["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConduitNotificationTarget(
            profile: profile?.isEmpty == false ? profile : nil,
            sessionId: sessionId,
            type: type?.isEmpty == false ? type : nil,
            decision: pendingDecision(from: payload)
        )
    }

    /// Parses the structured decision content the relay forwards alongside a
    /// decision notification (see the background-arrival design doc). Returns
    /// nil for non-decision notifications or malformed/unknown payloads so the
    /// notification degrades to its ordinary routing target. An approval
    /// requires a session key to answer, a description to display, and at
    /// least one usable choice — otherwise a cached card could render the
    /// approval view's default action set, which the payload never promised.
    private func pendingDecision(from payload: [String: Any]) -> PendingDecisionPayload? {
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
            if let rawQuestions = decision["questions"] as? [[String: Any]],
               !rawQuestions.isEmpty {
                let questions = rawQuestions.compactMap(Self.pushClarifyQuestion(from:))
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
        let choices = rawChoices
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { ClarifyChoice(label: $0, value: $0) }
        let multiSelect = (entry["multi_select"] as? Bool) == true && !choices.isEmpty
        return ClarifyQuestion(id: qid, question: question, choices: choices, multiSelect: multiSelect)
    }

    private func requestDeviceToken() async throws -> String {
        if let deviceToken { return deviceToken }
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
        let body = RegistrationRequest(bundleID: bundleID, deviceToken: deviceToken, environment: "production", preferences: preferences)
        var request = try jsonRequest(path: "/v1/installations", method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let responseBody = try JSONDecoder().decode(RegistrationResponse.self, from: data)
        registration = StoredRegistration(credential: responseBody.credential, installationID: responseBody.installation.id, preferences: responseBody.installation.preferences ?? preferences)
        preferences = registration!.preferences
        persistRegistration()
    }

    private func updateRegistration(deviceToken: String? = nil) async throws {
        guard let registration else { return }
        let body = UpdateRegistrationRequest(deviceToken: deviceToken ?? self.deviceToken, preferences: preferences)
        var request = try jsonRequest(path: "/v1/installations/\(registration.installationID)", method: "PUT", body: body)
        request.setValue("Bearer \(registration.credential)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        self.registration?.preferences = preferences
        persistRegistration()
    }

    private func jsonRequest<Body: Encodable>(path: String, method: String, body: Body) throws -> URLRequest {
        var request = URLRequest(url: relayURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(RelayError.self, from: data).message) ?? "Push relay request failed."
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
}

private struct RegistrationRequest: Encodable {
    let bundleID: String
    let deviceToken: String
    let environment: String
    let preferences: ConduitNotificationPreferences
    enum CodingKeys: String, CodingKey { case bundleID = "bundle_id", deviceToken = "device_token", environment, preferences }
}

private struct UpdateRegistrationRequest: Encodable {
    let deviceToken: String?
    let preferences: ConduitNotificationPreferences
    enum CodingKeys: String, CodingKey { case deviceToken = "device_token", preferences }
}

private struct RegistrationResponse: Decodable {
    struct Installation: Decodable { let id: String; let preferences: ConduitNotificationPreferences? }
    let credential: String
    let installation: Installation
}

private struct PairingResponse: Decodable {
    let pairingCode: String
    let expiresAt: String?
    enum CodingKeys: String, CodingKey { case pairingCode = "pairing_code", expiresAt = "expires_at" }
}

private struct RelayError: Decodable { let message: String? }

private enum PushNotificationError: LocalizedError {
    case permissionDenied
    case relay(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Allow notifications in Settings to continue."
        case .relay(let message): return message
        }
    }
}
