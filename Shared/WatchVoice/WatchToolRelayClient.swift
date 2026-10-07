//
//  WatchToolRelayClient.swift
//  Conduit Watch app (built into Conduit too, for its tests)
//
//  A Watch call's web_search and recall_memory through the push relay, over
//  the Watch's own internet, for while the iPhone can't be reached (wrist
//  down). The call's grant came from the iPhone with the session; each
//  lookup is sealed with it (WatchToolRelay.swift), held open on the relay
//  until Hermes answers, and opened here. Anything that doesn't get an
//  answer falls back to the iPhone's path.
//

import Foundation

@MainActor
final class WatchToolRelayClient {
    enum Outcome {
        /// Hermes' answer, as its route would give it.
        case answered([String: Any])
        /// Hermes took the call but didn't answer within the relay's wait.
        case timedOut
        /// Not answered this way; `grantGone` when the grant can't be used
        /// again (closed, expired, spent), `sent` when the call went out,
        /// which spends one of the grant's calls here.
        case unavailable(reason: String, grantGone: Bool, sent: Bool)

        /// For logs.
        var label: String {
            switch self {
            case .answered: return "answered"
            case .timedOut: return "timedOut"
            case .unavailable: return "unavailable"
            }
        }
    }

    /// The relay holds a call 25 s for Hermes; this waits a little longer.
    static let requestTimeout: TimeInterval = 35
    /// A grant this close to its end isn't used.
    static let expiryMargin: TimeInterval = 30

    let grantID: String
    let tools: Set<String>
    let expiresAt: Date?
    private let grantURL: URL
    private let watchKey: String
    private let keys: WatchToolSeal.Keys
    private let maxCalls: Int
    private let session: URLSession
    private(set) var callsSent = 0
    private(set) var isGone = false
    private var inFlight = 0
    private var closing = false
    private var closeSent = false

    /// Nil for a grant that can't be read or doesn't use https.
    /// `protocolClasses` is for tests.
    init?(_ grant: WatchVoiceWire.DirectToolGrant, protocolClasses: [AnyClass]? = nil) {
        guard let base = URL(string: grant.relayURL), base.scheme == "https", base.host != nil,
              grant.grantID.count == 22, WatchToolSeal.data(base64URL: grant.grantID) != nil,
              !grant.watchKey.isEmpty, WatchToolSeal.data(base64URL: grant.watchKey) != nil,
              let root = WatchToolSeal.data(base64URL: grant.key),
              let keys = WatchToolSeal.Keys(root: root) else { return nil }
        grantID = grant.grantID
        tools = Set(grant.tools).intersection(WatchToolAnswer.tools)
        expiresAt = grant.expiresAt
        grantURL = base.appendingPathComponent("v1/watch-tools/grants/\(grant.grantID)")
        watchKey = grant.watchKey
        self.keys = keys
        maxCalls = grant.maxCalls
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout + 5
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        // The relay key travels in a header: never to another host.
        session = URLSession(configuration: configuration, delegate: WatchToolRelayNoRedirects(), delegateQueue: nil)
    }

    /// Whether `name` can go this way now.
    func canRun(_ name: String) -> Bool {
        !isGone && tools.contains(name) && callsSent < maxCalls && !expiresSoon
    }

    /// Whether the grant was closed or spent. One that expires soon isn't
    /// gone: it's skipped until the iPhone renews it.
    private var isSpent: Bool { isGone || callsSent >= maxCalls }

    /// Less than `margin` left.
    func expires(within margin: TimeInterval) -> Bool {
        expiresAt.map { $0.timeIntervalSinceNow < margin } ?? false
    }

    private var expiresSoon: Bool { expires(within: Self.expiryMargin) }

    func run(name: String, query: String) async -> Outcome {
        guard tools.contains(name) else { return .unavailable(reason: "notGranted", grantGone: false, sent: false) }
        guard !isSpent else {
            isGone = true
            return .unavailable(reason: "grantEnded", grantGone: true, sent: false)
        }
        guard !expiresSoon else { return .unavailable(reason: "grantExpiring", grantGone: false, sent: false) }
        let rid = WatchToolSeal.newRequestID()
        let body: Data
        do {
            let plaintext = try WatchToolSeal.json(WatchToolAnswer.request(name: name, query: query))
            guard plaintext.count <= WatchToolSeal.maxCallBytes else { return .unavailable(reason: "tooLarge", grantGone: false, sent: false) }
            let sealed = try WatchToolSeal.seal(plaintext, keys: keys, direction: .call, grantID: grantID, rid: rid)
            body = try WatchToolSeal.json(["rid": rid, "n": sealed.n, "ct": sealed.ct])
        } catch {
            return .unavailable(reason: "sealFailed", grantGone: false, sent: false)
        }
        var request = URLRequest(url: grantURL.appendingPathComponent("calls"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(watchKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        callsSent += 1
        inFlight += 1
        defer {
            inFlight -= 1
            if closing, inFlight == 0 { sendClose() }
        }
        let data: Data
        let status: Int
        do {
            let (received, response) = try await session.data(for: request)
            data = received
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            let code = (error as? URLError)?.code
            return .unavailable(reason: code == .timedOut ? "requestTimedOut" : "network \(code?.rawValue ?? 0)", grantGone: false, sent: true)
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch status {
        case 200:
            guard let n = object?["n"] as? String, let ct = object?["ct"] as? String,
                  let plain = try? WatchToolSeal.open(.init(n: n, ct: ct), keys: keys, direction: .result, grantID: grantID, rid: rid),
                  let answer = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
                return .unavailable(reason: "unreadableAnswer", grantGone: false, sent: true)
            }
            // Hermes' own word that this grant is over: not for the model. A
            // 429 isn't: it's the host's search limit, which the model hears
            // as the iPhone's path would pass it on. (The host's call budget
            // also answers 429, but the Watch stops at the same count first.)
            if answer["ok"] as? Bool == false, let code = answer["status"] as? Int, [403, 410].contains(code) {
                isGone = true
                return .unavailable(reason: "host \(code)", grantGone: true, sent: true)
            }
            return .answered(answer)
        case 504:
            return .timedOut
        case 401, 404, 410:
            isGone = true
            return .unavailable(reason: "relay \(status)", grantGone: true, sent: true)
        default:
            let error = object?["error"] as? String
            if error == "grant_exhausted" { isGone = true }
            return .unavailable(reason: "relay \(status)\(error.map { " \($0)" } ?? "")", grantGone: isGone, sent: true)
        }
    }

    /// Ends the grant on the relay, which tells Hermes, once no lookup
    /// waits on it. Best effort: it expires there anyway.
    func close() {
        isGone = true
        closing = true
        if inFlight == 0 { sendClose() }
    }

    private func sendClose() {
        guard !closeSent else { return }
        closeSent = true
        var request = URLRequest(url: grantURL)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        request.setValue("Bearer \(watchKey)", forHTTPHeaderField: "Authorization")
        let session = self.session
        Task {
            _ = try? await session.data(for: request)
            session.finishTasksAndInvalidate()
        }
    }
}

private final class WatchToolRelayNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
