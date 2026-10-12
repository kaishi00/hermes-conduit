import Foundation

enum WidgetLaunchAction: String, Codable, CaseIterable {
    case open
    case resume
    case newChat
    case talk
}

struct WidgetLaunchLink: Equatable {
    let action: WidgetLaunchAction
    let workspace: WidgetWorkspaceID?
    let reference: WidgetConversationReference?
    private let encodedURL: URL

    init?(action: WidgetLaunchAction, workspace: WidgetWorkspaceID?, reference: WidgetConversationReference?) {
        let canonicalReference = reference.map {
            WidgetConversationReference(kind: $0.kind, scopeProfile: $0.scopeProfile, botName: $0.botName, botLabel: nil, sessionID: $0.sessionID, isUnverified: $0.isUnverified)
        }
        guard workspace.map(Self.isValid) ?? true,
              canonicalReference.map(Self.isValid) ?? true else { return nil }
        switch action {
        case .open:
            guard canonicalReference == nil else { return nil }
        case .resume:
            guard workspace != nil, let canonicalReference else { return nil }
            if canonicalReference.kind == .dashboard, canonicalReference.scopeProfile != workspace?.profile { return nil }
        case .newChat, .talk:
            guard workspace != nil, canonicalReference == nil else { return nil }
        }
        guard let encodedURL = Self.makeURL(action: action, workspace: workspace, reference: canonicalReference) else { return nil }
        self.action = action
        self.workspace = workspace
        self.reference = canonicalReference
        self.encodedURL = encodedURL
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "conduit",
              components.host?.lowercased() == "widget",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              let route = Self.routeAction(from: components.percentEncodedPath),
              let action = WidgetLaunchAction(rawValue: route) else { return nil }

        let items = components.queryItems ?? []
        let known = Set(["dashboard", "profile", "kind", "scope", "bot", "session", "unverified"])
        guard items.allSatisfy({ known.contains($0.name) }),
              Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ $0.value != nil }) else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        let hasDashboard = values["dashboard"] != nil
        let hasProfile = values["profile"] != nil
        guard hasDashboard == hasProfile else { return nil }
        let workspace: WidgetWorkspaceID?
        if let dashboard = values["dashboard"], let profile = values["profile"],
           let uuid = UUID(uuidString: dashboard), !profile.isEmpty, profile.count <= 512 {
            workspace = WidgetWorkspaceID(dashboardID: uuid, profile: profile)
        } else if hasDashboard || hasProfile {
            return nil
        } else {
            workspace = nil
        }

        let identityKeys: Set<String> = ["kind", "scope", "bot", "session", "unverified"]
        let hasIdentity = items.contains { identityKeys.contains($0.name) }
        let reference: WidgetConversationReference?
        if hasIdentity {
            guard workspace != nil,
                  let kindName = values["kind"], let kind = WidgetConversationReference.Kind(rawValue: kindName),
                  let scope = values["scope"], !scope.isEmpty, scope.count <= 512,
                  let session = values["session"], !session.isEmpty, session.count <= 512,
                  let verified = values["unverified"], verified == "true" || verified == "false" else { return nil }
            let bot = values["bot"]
            switch kind {
            case .dashboard:
                guard bot == nil, scope == workspace?.profile else { return nil }
            case .bot:
                guard let bot, !bot.isEmpty, bot == scope else { return nil }
            }
            reference = WidgetConversationReference(kind: kind, scopeProfile: scope, botName: bot, botLabel: nil, sessionID: session, isUnverified: verified == "true")
        } else {
            guard identityKeys.allSatisfy({ values[$0] == nil }) else { return nil }
            reference = nil
        }
        guard let parsed = Self(action: action, workspace: workspace, reference: reference) else { return nil }
        self = parsed
    }

    var url: URL { encodedURL }

    private static func routeAction(from path: String) -> String? {
        guard path.hasPrefix("/v1/"), path.dropFirst(4).isEmpty == false,
              !path.dropFirst(4).contains("/"), !path.contains("%") else { return nil }
        return String(path.dropFirst(4))
    }

    private static func isValid(_ workspace: WidgetWorkspaceID) -> Bool {
        !workspace.profile.isEmpty && workspace.profile.count <= 512
    }

    private static func isValid(_ reference: WidgetConversationReference) -> Bool {
        guard !reference.scopeProfile.isEmpty, reference.scopeProfile.count <= 512,
              !reference.sessionID.isEmpty, reference.sessionID.count <= 512 else { return false }
        switch reference.kind {
        case .dashboard: return reference.botName == nil
        case .bot: return reference.botName == reference.scopeProfile
        }
    }

    private static func makeURL(action: WidgetLaunchAction, workspace: WidgetWorkspaceID?, reference: WidgetConversationReference?) -> URL? {
        var components = URLComponents()
        components.scheme = "conduit"
        components.host = "widget"
        components.path = "/v1/\(action.rawValue)"
        var items: [URLQueryItem] = []
        if let workspace {
            items += [URLQueryItem(name: "dashboard", value: workspace.dashboardID.uuidString.lowercased()), URLQueryItem(name: "profile", value: workspace.profile)]
        }
        if let reference {
            items += [
                URLQueryItem(name: "kind", value: reference.kind.rawValue),
                URLQueryItem(name: "scope", value: reference.scopeProfile),
                URLQueryItem(name: "session", value: reference.sessionID),
                URLQueryItem(name: "unverified", value: reference.isUnverified ? "true" : "false")
            ]
            if let bot = reference.botName { items.append(URLQueryItem(name: "bot", value: bot)) }
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}
