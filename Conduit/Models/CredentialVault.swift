//
//  CredentialVault.swift
//  Conduit
//
//  Settings > Passwords & logins: Hermes' credential vault (`vault.*`, the
//  gateway's Settings > Credential Vault in Hermes Desktop). Hermes keeps
//  the logins, cards and addresses it signs in and fills pages with, and
//  answers with their metadata only. What the user types into the Add
//  form or an Unlock field goes once onto the socket and nowhere else.
//

import Foundation

/// One saved login, card or address as `vault.list` describes it: never a
/// password, card number or address line, which Hermes doesn't send.
struct VaultItem: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Codable, Sendable {
        case login, payment, address
        var id: String { rawValue }

        var title: String {
            switch self {
            case .login: AppLocalization.string("Login")
            case .payment: AppLocalization.string("Payment card")
            case .address: AppLocalization.string("Postal address")
            }
        }
    }

    let id: String
    /// Hermes' own kind name; one Conduit doesn't know yet shows as is.
    let kind: String
    let label: String
    let origin: String?
    /// A login's email, phone number or username. Hermes treats it as
    /// metadata (the agent types it), not as a secret.
    let identifier: String?
    let identifierType: String?
    /// As Hermes wrote it (ISO 8601, microseconds and all).
    let created: String?
    /// An authenticator key is saved: Hermes makes the 2FA codes itself.
    let hasOTP: Bool
    /// Where it lives: `local` for Hermes' own vault, else the password
    /// manager's name (`bitwarden`, `onepassword`).
    let source: String

    var knownKind: Kind? { Kind(rawValue: kind) }
    /// Only Hermes' own vault removes items; a password manager's are
    /// managed in that manager.
    var isLocal: Bool { source == VaultSource.localName }

    var createdAt: Date? {
        guard let created else { return nil }
        // ISO8601DateFormatter takes milliseconds; Python writes micro.
        let trimmed = created.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return MessageTimestampFormatter.date(from: trimmed)
    }

    /// The origin without its scheme, or nil when the label already says it
    /// (a login saved on a sign-in page is named for the page's host).
    var shownOrigin: String? {
        guard let origin, !origin.isEmpty else { return nil }
        let host = origin.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        return host == label ? nil : host
    }

    init(id: String, kind: String, label: String, origin: String? = nil, identifier: String? = nil, identifierType: String? = nil, created: String? = nil, hasOTP: Bool = false, source: String = VaultSource.localName) {
        self.id = id
        self.kind = kind
        self.label = label
        self.origin = origin
        self.identifier = identifier
        self.identifierType = identifierType
        self.created = created
        self.hasOTP = hasOTP
        self.source = source
    }

    init?(object: [String: AnyCodable]) {
        guard let id = object["id"]?.stringValue, !id.isEmpty,
              let kind = object["kind"]?.stringValue else { return nil }
        let label = object["label"]?.stringValue ?? ""
        let identifier = object["identifier"]?.stringValue
        self.init(
            id: id,
            kind: kind,
            label: label,
            origin: object["origin"]?.stringValue,
            identifier: identifier?.isEmpty == true ? nil : identifier,
            identifierType: object["identifier_type"]?.stringValue,
            created: object["created_at"]?.stringValue,
            hasOTP: object["has_otp"]?.boolValue ?? false,
            source: object["backend"]?.stringValue ?? VaultSource.localName
        )
    }
}

/// A place Hermes takes logins from (`vault.sources`): its own vault, then
/// each password manager it supports.
struct VaultSource: Identifiable, Equatable, Codable, Sendable {
    static let localName = "local"

    let name: String
    let displayName: String
    let enabled: Bool
    let needsUnlock: Bool
    let unlocked: Bool
    /// The manager's command-line tool is on the Hermes host.
    let installed: Bool

    var id: String { name }
    var isLocal: Bool { name == Self.localName }

    init(name: String, displayName: String, enabled: Bool, needsUnlock: Bool, unlocked: Bool, installed: Bool) {
        self.name = name
        self.displayName = displayName
        self.enabled = enabled
        self.needsUnlock = needsUnlock
        self.unlocked = unlocked
        self.installed = installed
    }

    init?(object: [String: AnyCodable]) {
        guard let name = object["name"]?.stringValue, !name.isEmpty else { return nil }
        let display = object["display_name"]?.stringValue ?? ""
        self.init(
            name: name,
            displayName: display.isEmpty ? name : display,
            enabled: object["enabled"]?.boolValue ?? false,
            needsUnlock: object["needs_unlock"]?.boolValue ?? false,
            unlocked: object["unlocked"]?.boolValue ?? false,
            installed: object["installed"]?.boolValue ?? false
        )
    }

    /// The source's state in a word, as its row's badge says it.
    var status: String {
        if !installed { return AppLocalization.string("Not detected") }
        if !enabled { return AppLocalization.string("Off") }
        return unlocked ? AppLocalization.string("Unlocked") : AppLocalization.string("Locked")
    }

    /// What the state means for the agent, under the row's name.
    var caption: String {
        if !installed {
            return AppLocalization.string("Not detected. Install the \(displayName) command-line tool on the Hermes computer and sign in to it; Hermes picks it up automatically.")
        }
        if !enabled { return AppLocalization.string("Detected but turned off for Hermes.") }
        if unlocked {
            return AppLocalization.string("Unlocked for this session. Locks itself after 30 minutes idle or when Hermes closes.")
        }
        return AppLocalization.string("Detected. Hermes asks you to unlock it when it needs a login, or unlock it now.")
    }
}

/// What Settings > Passwords & logins shows: the items and the sources,
/// kept on the phone so the page opens on them (#1533). Metadata only.
struct CredentialVaultSnapshot: Equatable, Codable, Sendable {
    var items: [VaultItem]
    var sources: [VaultSource]

    /// The password managers, without Hermes' own vault.
    var managers: [VaultSource] { sources.filter { !$0.isLocal } }
}

/// The Add form's fields. They live in the form's own state and go once
/// onto the socket as `vault.add`'s secret; nothing here is kept.
struct VaultItemDraft: Equatable {
    enum IdentifierType: String, CaseIterable, Identifiable {
        case email, phone, username
        var id: String { rawValue }

        var title: String {
            switch self {
            case .email: AppLocalization.string("Email")
            case .phone: AppLocalization.string("Phone")
            case .username: AppLocalization.string("Username")
            }
        }
    }

    /// What `vault.add` takes.
    struct Request: Equatable {
        let kind: String
        let label: String
        let origin: String?
        let secret: [String: String]
    }

    var kind: VaultItem.Kind = .login
    var label = ""
    var origin = ""
    var identifierType: IdentifierType = .email
    var identifier = ""
    var password = ""
    var otpSecret = ""
    var cardNumber = ""
    var cardholderName = ""
    var expMonth = ""
    var expYear = ""
    var cvc = ""
    var postalCode = ""
    var addressLine1 = ""
    var addressLine2 = ""
    var city = ""
    var state = ""
    var country = ""

    /// The request this draft makes, or why it can't be saved yet, in the
    /// words the form shows.
    func request() -> Result<Request, DraftProblem> {
        let typedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOrigin = Self.normalizedOrigin(typedOrigin)
        if !typedOrigin.isEmpty, normalizedOrigin == nil { return .failure(.origin) }
        if kind == .login, normalizedOrigin == nil { return .failure(.origin) }
        var name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // A login named for nothing is named for its site, as Hermes names
        // one saved on a sign-in page.
        if name.isEmpty, let normalizedOrigin, let host = URLComponents(string: normalizedOrigin)?.host { name = host }
        guard !name.isEmpty else { return .failure(.label) }

        var secret: [String: String] = [:]
        func put(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { secret[key] = trimmed }
        }
        switch kind {
        case .login:
            let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            // The password goes as typed; spaces alone are no password.
            guard !id.isEmpty, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.login) }
            secret["identifier_type"] = identifierType.rawValue
            secret["identifier"] = id
            secret["password"] = password
            // Sites show the key in groups; Hermes takes it without the
            // spaces and dashes (an otpauth:// link has neither).
            let key = otpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            put("otp_secret", key.lowercased().hasPrefix("otpauth://") ? key : key.filter { !$0.isWhitespace && $0 != "-" })
        case .payment:
            let digits = cardNumber.filter { !$0.isWhitespace && $0 != "-" }
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return .failure(.cardNumber) }
            guard let month = Int(expMonth.trimmingCharacters(in: .whitespacesAndNewlines)), (1...12).contains(month) else { return .failure(.expiry) }
            let year = expYear.trimmingCharacters(in: .whitespacesAndNewlines)
            guard [2, 4].contains(year.count), year.allSatisfy(\.isNumber) else { return .failure(.expiry) }
            guard !cvc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.cvc) }
            secret["card_number"] = digits
            secret["exp_month"] = String(format: "%02d", month)
            secret["exp_year"] = year
            put("cvc", cvc)
            put("cardholder_name", cardholderName)
            put("billing_postal_code", postalCode)
        case .address:
            put("address_line1", addressLine1)
            put("address_line2", addressLine2)
            put("city", city)
            put("state", state)
            put("postal_code", postalCode)
            put("country", country)
            guard ["address_line1", "city", "postal_code", "country"].allSatisfy({ secret[$0] != nil }) else { return .failure(.address) }
        }
        return .success(Request(kind: kind.rawValue, label: name, origin: normalizedOrigin, secret: secret))
    }

    enum DraftProblem: Error, Equatable {
        case label, origin, login, cardNumber, expiry, cvc, address

        var message: String {
            switch self {
            case .label: AppLocalization.string("Give it a label.")
            case .origin: AppLocalization.string("Enter the site's address, like github.com.")
            case .login: AppLocalization.string("Enter the login's email or username and its password.")
            case .cardNumber: AppLocalization.string("Enter the card number.")
            case .expiry: AppLocalization.string("Enter the expiry month (1 to 12) and year.")
            case .cvc: AppLocalization.string("Enter the security code.")
            case .address: AppLocalization.string("Enter the street, city, postal code and country.")
            }
        }
    }

    /// The site as Hermes keys a login by it, `scheme://host[:port]`: a bare
    /// host gets https, a path or query is dropped. Nil when there's no host.
    static func normalizedOrigin(_ typed: String) -> String? {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        let withScheme = value.contains("://") ? value : "https://" + value
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        // An IPv6 address keeps its brackets, whichever way this OS's
        // URLComponents gives it (with them on iOS 26, without on older).
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var origin = "\(scheme)://\(bracketed)"
        if let port = components.port, !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) {
            origin += ":\(port)"
        }
        return origin
    }
}
