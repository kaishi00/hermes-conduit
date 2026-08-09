import Foundation

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

    /// JavaScript injected at document start so that every `fetch()` and
    /// `XMLHttpRequest` originating inside the WKWebView includes the
    /// Cloudflare Access service-token headers. Without this, only the
    /// initial navigation request carries the headers; subsequent API/ticket
    /// fetches issued by the dashboard page or by DashboardTicketBridge's
    /// evaluated scripts would be rejected by Cloudflare Service Auth.
    var fetchInjectionUserScript: String {
        guard isConfigured else { return "" }
        guard let idLiteral = javaScriptStringLiteral(clientID),
              let secretLiteral = javaScriptStringLiteral(clientSecret) else { return "" }
        return """
        (function() {
            var cfId = \(idLiteral);
            var cfSecret = \(secretLiteral);
            var origFetch = window.fetch;
            if (origFetch) {
                window.fetch = function(input, init) {
                    init = init || {};
                    if (init.headers instanceof Headers) {
                        init.headers.set('CF-Access-Client-Id', cfId);
                        init.headers.set('CF-Access-Client-Secret', cfSecret);
                    } else {
                        init.headers = Object.assign({}, init.headers || {});
                        init.headers['CF-Access-Client-Id'] = cfId;
                        init.headers['CF-Access-Client-Secret'] = cfSecret;
                    }
                    return origFetch.call(this, input, init);
                };
            }
            var origOpen = XMLHttpRequest.prototype.open;
            var origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
                this._cfHeadersApplied = false;
                return origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function(body) {
                if (!this._cfHeadersApplied) {
                    this.setRequestHeader('CF-Access-Client-Id', cfId);
                    this.setRequestHeader('CF-Access-Client-Secret', cfSecret);
                    this._cfHeadersApplied = true;
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
