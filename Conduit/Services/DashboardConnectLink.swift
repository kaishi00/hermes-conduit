//
//  DashboardConnectLink.swift
//  Conduit
//
//  A sign-in code for a dashboard:
//  `conduit://connect?url=<address>&username=<name>&password=<password>`,
//  scanned as a QR code or tapped as a link. Hermes makes one when asked
//  (ConnectionSetupPrompt.signInCode). It only fills in a sign-in: Conduit
//  asks first, nothing connects until the user taps Sign in, and nothing is
//  saved until the sign-in works.
//
//  The password is a secret. The description leaves it out, and the link is
//  never logged or kept past the sheet that shows it.
//

import Foundation

struct DashboardConnectLink: Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    let id = UUID()
    /// The dashboard address as the code gave it, possibly without a scheme.
    let address: String
    let username: String?
    let password: String?

    static let host = "connect"

    /// Reads a `conduit://connect` link. An address is required; a name
    /// given twice makes the link unreadable rather than picking one.
    init?(url: URL) {
        guard url.scheme?.lowercased() == ConduitAppLink.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == Self.host,
              components.path.isEmpty || components.path == "/" else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String?? {
            let matches = items.filter { $0.name == name }
            guard matches.count <= 1 else { return .none }
            return .some(matches.first?.value)
        }
        guard case .some(let address) = value("url"),
              case .some(let username) = value("username"),
              case .some(let password) = value("password") else { return nil }
        let trimmedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedAddress.isEmpty else { return nil }
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.address = trimmedAddress
        self.username = trimmedUsername.isEmpty ? nil : trimmedUsername
        // A password is used exactly as given.
        self.password = (password?.isEmpty ?? true) ? nil : password
    }

    var description: String {
        "DashboardConnectLink(address: \(address), username: \(username == nil ? "none" : "set"), password: \(password == nil ? "none" : "set"))"
    }

    var debugDescription: String { description }

    // MARK: Scans

    /// What a scanned code or tapped address says.
    enum Scan {
        /// A sign-in code: Conduit asks before signing in.
        case link(DashboardConnectLink)
        /// A plain dashboard address.
        case address(String)
        /// Not something Conduit can sign in to.
        case unreadable
    }

    /// Reads a QR code's text, or a URL recognized in text.
    static func scan(_ text: String) -> Scan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return .unreadable }
        if let url = URL(string: trimmed), url.scheme?.lowercased() == ConduitAppLink.scheme {
            return DashboardConnectLink(url: url).map(Scan.link) ?? .unreadable
        }
        guard LoginAddress.candidates(trimmed).contains(where: { (try? ConnectionURLPolicy.normalizedBaseURL($0)) != nil }) else {
            return .unreadable
        }
        return .address(trimmed)
    }
}

extension LoginAddress {
    /// Whether an address names the computer it is typed on (localhost,
    /// 127.x, ::1). In a code Hermes made, that is Hermes' own computer,
    /// which the phone can't reach that way.
    static func isOnlyOnHermesComputer(_ typed: String) -> Bool {
        guard let host = URLComponents(string: bestGuess(typed))?.host?.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "0.0.0.0"
            || host.hasPrefix("127.")
    }
}

extension AppState {
    /// A `conduit://connect` link opened Conduit or was tapped in a chat:
    /// the sign-in code sheet asks about it. Returns false for other links.
    func routeConnectLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == ConduitAppLink.scheme,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased() == DashboardConnectLink.host else {
            return false
        }
        // An unreadable code is still a connect link: it opens nothing else.
        if let link = DashboardConnectLink(url: url) {
            pendingConnectLink = link
        }
        return true
    }
}
