import Foundation
import UIKit
import UserNotifications

struct ConduitNotificationTarget: Equatable, Identifiable {
    let profile: String?
    let sessionId: String
    let type: String?
    var id: String { "\(profile ?? "default"):\(sessionId):\(type ?? "")" }
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
        guard !normalizedID.isEmpty else { return notificationSessionID }
        guard let session = sessions.first(where: { session in
            session.id == normalizedID || session.alternateIds.contains(normalizedID)
        }) else {
            return notificationSessionID
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

    enum CodingKeys: String, CodingKey {
        case enabled
        case approvalNeeded = "approval_needed"
        case inputNeeded = "input_needed"
        case responseReady = "response_ready"
        case turnFailed = "turn_failed"
        case backgroundTaskFinished = "background_task_finished"
        case completionSound = "completion_sound"
        case showPreviews = "show_previews"
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

    var isEnabled: Bool { registration != nil && preferences.enabled }
    var statusText: String {
        if isWorking { return "Updating" }
        if isEnabled { return "Enabled" }
        if authorizationStatus == .denied { return "Notifications denied" }
        return "Off"
    }

    private init() {
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
        pendingTarget = target
        navigationAttempt += 1
    }

    func clearPendingTarget(_ target: ConduitNotificationTarget) {
        guard pendingTarget == target else { return }
        pendingTarget = nil
    }

    func discardPendingTarget(_ target: ConduitNotificationTarget) {
        clearPendingTarget(target)
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
            type: type?.isEmpty == false ? type : nil
        )
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
