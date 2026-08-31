import Foundation
import WebKit

/// Cloudflare's Access login page runs a Turnstile-backed verification that
/// scores the bare WKWebView user agent as automation, so the interactive
/// sign-in fails inside the app while the same login succeeds in Safari on
/// the same device (issue #117). Appending the tokens Safari carries but a
/// default WKWebView omits ("Version/… Safari/…") before the first load
/// lets the legitimate Cloudflare/IdP flow verify. "Safari/604.1" is Apple's
/// frozen WebKit build marker (an identity token, not an OS version — it has
/// been constant across every iOS Safari release), and "Version/…" tracks
/// the current OS; the device part of the UA keeps coming from WebKit
/// itself. No credentials or navigation policy are affected.
enum WebViewUserAgent {
    static func safariCompatibilitySuffix() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var versionText = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 {
            versionText += ".\(version.patchVersion)"
        }
        return "Version/\(versionText) Safari/604.1"
    }

    /// Must run before the web view loads anything: WebKit ignores user-agent
    /// changes once a page has started loading.
    static func apply(to configuration: WKWebViewConfiguration) {
        configuration.applicationNameForUserAgent = safariCompatibilitySuffix()
    }
}

struct CloudflareAccessKeychainRecord: Codable, Equatable {
    let clientID: String
    let clientSecret: String
    let origin: String

    var credentials: CloudflareAccessCredentials? {
        CloudflareAccessCredentials.from(clientID: clientID, clientSecret: clientSecret)
    }

    init(clientID: String, clientSecret: String, origin: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.origin = origin
    }

    /// Custom decode: origin defaults to "" when absent, so legacy
    /// keychain records (pre-origin-binding) don't crash on load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try container.decode(String.self, forKey: .clientID)
        clientSecret = try container.decode(String.self, forKey: .clientSecret)
        origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? ""
    }
}

struct CloudflareAccessCredentials: Equatable, CustomStringConvertible {
    let clientID: String
    let clientSecret: String

    var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.isEmpty
    }

    var description: String {
        isConfigured ? "CloudflareAccessCredentials(enabled: true)" : "CloudflareAccessCredentials(enabled: false)"
    }

    func applying(to request: URLRequest) -> URLRequest {
        guard isConfigured else { return request }
        var request = request
        request.setValue(clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        return request
    }

    private func javaScriptStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8),
              literal.first == "\"",
              literal.last == "\"" else { return nil }
        return literal
    }

    /// JavaScript injected at document start so that same-origin dashboard
    /// `fetch()` and `XMLHttpRequest` calls inside the WKWebView include the
    /// Cloudflare Access service-token headers. The script is intentionally
    /// scoped to the configured dashboard origin; native requests still apply
    /// the headers directly to the initial dashboard request.
    func fetchInjectionUserScript(expectedBaseURL: String) -> String {
        guard isConfigured,
              let normalizedBaseURL = try? ConnectionURLPolicy.normalizedBaseURL(expectedBaseURL),
              let baseURLLiteral = javaScriptStringLiteral(normalizedBaseURL),
              let idLiteral = javaScriptStringLiteral(clientID),
              let secretLiteral = javaScriptStringLiteral(clientSecret) else { return "" }
        return """
        (function() {
            var cfId = \(idLiteral);
            var cfSecret = \(secretLiteral);
            var cfOrigin = new URL(\(baseURLLiteral)).origin;
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
                return window.location.origin === cfOrigin
                    && resolved !== null
                    && resolved.origin === cfOrigin;
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
                        headers.set('CF-Access-Client-Id', cfId);
                        headers.set('CF-Access-Client-Secret', cfSecret);
                        init.headers = headers;
                    }
                    return origFetch.call(this, input, init);
                };
            }
            var origOpen = XMLHttpRequest.prototype.open;
            var origSend = XMLHttpRequest.prototype.send;
            var eligibleXhrs = new WeakMap();
            var setXhrEligibility = eligibleXhrs.set.bind(eligibleXhrs);
            var getXhrEligibility = eligibleXhrs.get.bind(eligibleXhrs);
            XMLHttpRequest.prototype.open = function(method, url) {
                setXhrEligibility(this, shouldAttach(url));
                return origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function(body) {
                if (getXhrEligibility(this) === true) {
                    this.setRequestHeader('CF-Access-Client-Id', cfId);
                    this.setRequestHeader('CF-Access-Client-Secret', cfSecret);
                }
                return origSend.apply(this, arguments);
            };
        })();
        """
    }
}

extension CloudflareAccessCredentials {
    static func from(clientID: String, clientSecret: String) -> CloudflareAccessCredentials? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !clientSecret.isEmpty else { return nil }
        return CloudflareAccessCredentials(clientID: id, clientSecret: clientSecret)
    }
}
