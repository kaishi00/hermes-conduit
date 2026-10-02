//
//  CustomHeaders.swift
//  Conduit
//
//  Extra request headers for reverse proxies other than Cloudflare Access
//  (Pangolin, Traefik forward-auth, nginx header checks): issue #305.
//
//  Deliberately additive. The Cloudflare service-token path, its Keychain
//  records and its toggle are untouched; extra headers live in their own
//  record and are layered onto the same requests afterwards, never
//  replacing a header the request (or the Cloudflare token) already set.
//
//  Headers are bound to the server ORIGIN they were entered for (scheme,
//  host, port), not to a dashboard UUID: a proxy guards a host, and origin
//  binding means a header can only ever be sent to the server it was typed
//  for. Like the Cloudflare token they are HTTPS/WSS only: cleartext
//  requests never carry them.
//

import Foundation

struct CustomHeader: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum CustomHeaderIssue: Equatable {
    case emptyName
    case invalidName
    case reservedName
    case invalidValue

    var message: String {
        switch self {
        case .emptyName: return AppLocalization.string("Enter a header name.")
        case .invalidName: return AppLocalization.string("This isn’t a valid header name. Use letters, digits, and dashes.")
        case .reservedName: return AppLocalization.string("Conduit manages this header itself, so it can't be set here.")
        case .invalidValue: return AppLocalization.string("Header values can't contain line breaks.")
        }
    }
}

enum CustomHeaderPolicy {
    /// Headers the transport or Conduit itself owns. Setting them would break
    /// framing, websocket upgrades or the dashboard session rather than
    /// authenticate to a proxy.
    static let reservedNames: Set<String> = [
        "host", "cookie", "content-length", "content-type", "transfer-encoding",
        "connection", "upgrade", "keep-alive", "proxy-connection", "te", "trailer",
        "expect", "origin",
    ]

    private static let tokenCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"
    )

    static func issue(for header: CustomHeader) -> CustomHeaderIssue? {
        let name = header.trimmedName
        guard !name.isEmpty else { return .emptyName }
        guard name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }) else { return .invalidName }
        let lowered = name.lowercased()
        guard !reservedNames.contains(lowered), !lowered.hasPrefix("sec-") else { return .reservedName }
        guard !header.value.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F }) else {
            return .invalidValue
        }
        return nil
    }

    /// The headers that may go on the wire: valid ones, names trimmed, the
    /// first entry winning when a name repeats.
    static func sendable(_ headers: [CustomHeader]) -> [CustomHeader] {
        var seen = Set<String>()
        return headers.compactMap { header in
            guard issue(for: header) == nil else { return nil }
            let name = header.trimmedName
            guard seen.insert(name.lowercased()).inserted else { return nil }
            return CustomHeader(id: header.id, name: name, value: header.value)
        }
    }

    /// The origin key headers are bound to. Only secure origins have one;
    /// `wss` shares the `https` origin so websocket upgrades to the same
    /// server match. Default ports are dropped so `:443` and no port agree.
    static func origin(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "wss",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        if let port = url.port, port != 443 {
            return "https://\(hostPart):\(port)"
        }
        return "https://\(hostPart)"
    }

    static func origin(forServerURL serverURL: String) -> String? {
        let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(serverURL))
            ?? serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized) else { return nil }
        return origin(for: url)
    }
}

/// Process-wide, origin-keyed store of extra headers. Request builders run
/// on and off the main actor, so reads are lock-protected and synchronous;
/// the Keychain is read once, lazily, and written through on every change.
final class CustomHeaderStore: @unchecked Sendable {
    static let shared = CustomHeaderStore(
        load: { KeychainHelper.loadCustomHeaders() },
        persist: { KeychainHelper.saveCustomHeaders($0) }
    )

    private let lock = NSLock()
    private let load: () -> [String: [CustomHeader]]
    private let persist: ([String: [CustomHeader]]) -> Void
    private var cache: [String: [CustomHeader]]?

    init(
        load: @escaping () -> [String: [CustomHeader]],
        persist: @escaping ([String: [CustomHeader]]) -> Void
    ) {
        self.load = load
        self.persist = persist
    }

    private func withHeaders<T>(_ body: (inout [String: [CustomHeader]]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        var headers = cache ?? load()
        let result = body(&headers)
        cache = headers
        return result
    }

    /// Everything saved for this server's origin, including entries that
    /// don't validate (the editor shows them so they can be fixed).
    func headers(forServerURL serverURL: String) -> [CustomHeader] {
        guard let origin = CustomHeaderPolicy.origin(forServerURL: serverURL) else { return [] }
        return withHeaders { $0[origin] ?? [] }
    }

    func headers(for url: URL) -> [CustomHeader] {
        guard let origin = CustomHeaderPolicy.origin(for: url) else { return [] }
        return withHeaders { $0[origin] ?? [] }
    }

    /// Replaces this origin's headers. Rows with neither a name nor a value
    /// are dropped; an empty list removes the origin. Returns false when the
    /// address has no secure origin to bind to.
    @discardableResult
    func setHeaders(_ headers: [CustomHeader], forServerURL serverURL: String) -> Bool {
        guard let origin = CustomHeaderPolicy.origin(forServerURL: serverURL) else { return false }
        let kept = headers.filter { !$0.trimmedName.isEmpty || !$0.value.isEmpty }
        let snapshot: [String: [CustomHeader]] = withHeaders { all in
            all[origin] = kept.isEmpty ? nil : kept
            return all
        }
        persist(snapshot)
        return true
    }

    func removeHeaders(forServerURL serverURL: String) {
        setHeaders([], forServerURL: serverURL)
    }

    /// Adds this origin's valid headers to a secure request. A header the
    /// request already carries (Conduit's own bearer token, the Cloudflare
    /// service token) always wins.
    func applying(to request: URLRequest) -> URLRequest {
        guard let url = request.url else { return request }
        let headers = CustomHeaderPolicy.sendable(headers(for: url))
        guard !headers.isEmpty else { return request }
        var request = request
        for header in headers where request.value(forHTTPHeaderField: header.name) == nil {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }

    /// Document-start script that adds the headers to the dashboard page's
    /// same-origin `fetch()` and `XMLHttpRequest` calls, mirroring the
    /// Cloudflare token injection. Empty for cleartext origins or when
    /// nothing is configured.
    func fetchInjectionUserScript(expectedBaseURL: String) -> String {
        guard let origin = CustomHeaderPolicy.origin(forServerURL: expectedBaseURL) else { return "" }
        let headers = CustomHeaderPolicy.sendable(withHeaders { $0[origin] ?? [] })
        guard !headers.isEmpty,
              let headerData = try? JSONSerialization.data(
                withJSONObject: headers.map { [$0.name, $0.value] }
              ),
              let headerLiteral = String(data: headerData, encoding: .utf8),
              let originData = try? JSONSerialization.data(withJSONObject: origin, options: [.fragmentsAllowed]),
              let originLiteral = String(data: originData, encoding: .utf8) else { return "" }
        return """
        (function() {
            var extraHeaders = \(headerLiteral);
            var extraOrigin = \(originLiteral);
            function resolvedURL(input) {
                try {
                    var value = input;
                    if (value && typeof value === 'object' && typeof value.url === 'string') {
                        value = value.url;
                    }
                    return new URL(value, window.location.href);
                } catch (_) {
                    return null;
                }
            }
            function shouldAttach(input) {
                var resolved = resolvedURL(input);
                return window.location.origin === extraOrigin
                    && resolved !== null
                    && resolved.origin === extraOrigin;
            }
            var origFetch = window.fetch;
            if (origFetch) {
                window.fetch = function(input, init) {
                    if (shouldAttach(input)) {
                        init = init || {};
                        var sourceHeaders = init.headers;
                        if (sourceHeaders === undefined
                            && input
                            && typeof input === 'object'
                            && input.headers) {
                            sourceHeaders = input.headers;
                        }
                        var headers = new Headers(sourceHeaders || undefined);
                        extraHeaders.forEach(function(pair) {
                            if (!headers.has(pair[0])) { headers.set(pair[0], pair[1]); }
                        });
                        init.headers = headers;
                    }
                    return origFetch.call(this, input, init);
                };
            }
            var origOpen = XMLHttpRequest.prototype.open;
            var origSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
            var origSend = XMLHttpRequest.prototype.send;
            var eligibleXhrs = new WeakMap();
            var setXhrEligibility = eligibleXhrs.set.bind(eligibleXhrs);
            var getXhrEligibility = eligibleXhrs.get.bind(eligibleXhrs);
            var pageSetNames = new WeakMap();
            var setPageNames = pageSetNames.set.bind(pageSetNames);
            var getPageNames = pageSetNames.get.bind(pageSetNames);
            XMLHttpRequest.prototype.open = function(method, url) {
                setXhrEligibility(this, shouldAttach(url));
                setPageNames(this, {});
                return origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
                var names = getPageNames(this);
                if (names) { names[String(name).toLowerCase()] = true; }
                return origSetRequestHeader.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function(body) {
                if (getXhrEligibility(this) === true) {
                    var names = getPageNames(this) || {};
                    var xhr = this;
                    extraHeaders.forEach(function(pair) {
                        if (!names[pair[0].toLowerCase()]) {
                            origSetRequestHeader.call(xhr, pair[0], pair[1]);
                        }
                    });
                }
                return origSend.apply(this, arguments);
            };
        })();
        """
    }
}

extension URLRequest {
    /// The Cloudflare service token (when configured), then any extra
    /// headers saved for this server. The one call every Conduit request
    /// builder uses to reach a proxied dashboard.
    func applyingProxyHeaders(cloudflare: CloudflareAccessCredentials?, store: CustomHeaderStore = .shared) -> URLRequest {
        store.applying(to: cloudflare?.applying(to: self) ?? self)
    }
}
