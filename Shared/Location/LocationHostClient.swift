//
//  LocationHostClient.swift
//  Conduit
//
//  Dashboard requests without the app: the Location Push extension answers
//  a locate while Conduit isn't running, and a background wake may come
//  before Conduit has reconnected. Both send with a host pass the app keeps
//  up to date in the App Group Keychain whenever it has a working
//  connection to the bound dashboard: the dashboard's address and the
//  headers its own requests carry there (the session cookies, or a native
//  sign-in's access token, plus any Cloudflare Access and custom proxy
//  headers). The pass never refreshes a sign-in itself: a native sign-in's
//  refresh token rotates, and a copy refreshed here would sign the app out.
//  A pass that has expired or is refused just means nothing is sent.
//

import Foundation

struct LocationHostPass: Codable, Equatable {
    var dashboardID: UUID
    /// The dashboard's normalized base URL (scheme, host, port, path prefix).
    var baseURL: String
    /// Request headers: Cookie or Authorization, and proxy headers.
    var headers: [String: String]
    /// When the credential in it stops working, when known.
    var expiresAt: Date?
    var savedAt: Date

    func isUsable(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > now.addingTimeInterval(30)
    }
}

enum LocationHostError: Error, Equatable {
    case noPass
    case signInRequired
    case http(status: Int, detail: String)
}

enum LocationHostClient {
    static let base = "/api/plugins/conduit_push/location"

    /// `path` with `?profile=` for a named profile, as the app's requests.
    static func withProfile(_ path: String, profile: String) -> String {
        guard !profile.isEmpty, profile != "default",
              let encoded = profile.addingPercentEncoding(withAllowedCharacters: profileAllowed) else { return path }
        return "\(path)\(path.contains("?") ? "&" : "?")profile=\(encoded)"
    }

    private static let profileAllowed: CharacterSet = {
        var characters = CharacterSet.alphanumerics
        characters.insert(charactersIn: "-._~")
        return characters
    }()

    /// The JSON object the dashboard answers with.
    static func requestJSON(
        pass: LocationHostPass,
        path: String,
        method: String,
        body: [String: Any]?,
        timeout: TimeInterval = 15,
        now: Date = Date()
    ) async throws -> [String: Any] {
        guard pass.isUsable(at: now) else { throw LocationHostError.signInRequired }
        guard let url = URL(string: pass.baseURL + path), let base = URL(string: pass.baseURL),
              url.scheme == base.scheme, url.host == base.host, url.port == base.port else {
            throw LocationHostError.noPass
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (name, value) in pass.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method.uppercased() != "GET", let scheme = url.scheme, let host = url.host {
            // Same-origin, as the dashboard page's own fetch.
            let port = url.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(port)", forHTTPHeaderField: "Origin")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocationHostError.http(status: 0, detail: "No response from the dashboard.")
        }
        if (300...399).contains(http.statusCode) || http.statusCode == 401 || http.statusCode == 403 {
            // A redirect is to sign-in or elsewhere: either way the pass no longer works.
            throw LocationHostError.signInRequired
        }
        let value = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        let object = value as? [String: Any]
        guard (200...299).contains(http.statusCode) else {
            let detail = (object?["detail"] ?? object?["error"] ?? object?["message"]) as? String
            throw LocationHostError.http(status: http.statusCode, detail: detail ?? "HTTP \(http.statusCode)")
        }
        // Every plugin route answers a JSON object. A 2xx without one (a
        // proxy's or portal's page, or nothing) stored nothing: counting it
        // as sent would drop the location.
        guard let object else {
            throw LocationHostError.http(status: http.statusCode, detail: "The answer wasn't from the Conduit plugin.")
        }
        return object
    }

    /// No cookie jar, and redirects come back as the response.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// Seals a batch and posts it to `/location/ingest`.
enum LocationIngest {
    /// The ingest body for a batch.
    static func body(_ batch: LocationBatch, key: LocationCrypto.SessionKey) throws -> [String: Any] {
        var batch = batch
        // A key from before maps can't open a maps request: the host isn't
        // told this iPhone answers them until the key is agreed again.
        if !key.answersMaps { batch.features = [] }
        return try LocationCrypto.envelope(plaintext: batch.plaintext(), key: key, batchID: batch.batchID)
    }
}
