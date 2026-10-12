import Foundation

struct WidgetWorkspaceID: Codable, Hashable {
    let dashboardID: UUID
    let profile: String

    init(dashboardID: UUID, profile: String) {
        self.dashboardID = dashboardID
        self.profile = profile
    }

    var isValid: Bool { !profile.isEmpty && profile.count <= 512 }

    private enum CodingKeys: String, CodingKey { case dashboardID, profile }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let profile = try values.decode(String.self, forKey: .profile)
        guard !profile.isEmpty, profile.count <= 512 else {
            throw DecodingError.dataCorruptedError(forKey: .profile, in: values, debugDescription: "Invalid workspace profile")
        }
        self.init(dashboardID: try values.decode(UUID.self, forKey: .dashboardID), profile: profile)
    }
}

struct WidgetConversationReference: Codable, Hashable {
    enum Kind: String, Codable { case dashboard, bot }

    let kind: Kind
    let scopeProfile: String
    let botName: String?
    let botLabel: String?
    let sessionID: String
    let isUnverified: Bool

    init(kind: Kind, scopeProfile: String, botName: String?, botLabel: String?, sessionID: String, isUnverified: Bool) {
        self.kind = kind
        self.scopeProfile = scopeProfile
        self.botName = botName
        self.botLabel = botLabel
        self.sessionID = sessionID
        self.isUnverified = isUnverified
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.scopeProfile == rhs.scopeProfile && lhs.botName == rhs.botName &&
            lhs.sessionID == rhs.sessionID && lhs.isUnverified == rhs.isUnverified
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(scopeProfile)
        hasher.combine(botName)
        hasher.combine(sessionID)
        hasher.combine(isUnverified)
    }

    private enum CodingKeys: String, CodingKey { case kind, scopeProfile, botName, botLabel, sessionID, isUnverified }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        let scope = try values.decode(String.self, forKey: .scopeProfile)
        let bot = try values.decodeIfPresent(String.self, forKey: .botName)
        let label = try values.decodeIfPresent(String.self, forKey: .botLabel)
        let session = try values.decode(String.self, forKey: .sessionID)
        let unverified = try values.decode(Bool.self, forKey: .isUnverified)
        guard !scope.isEmpty, scope.count <= 512, !session.isEmpty, session.count <= 512,
              (kind == .dashboard && bot == nil) || (kind == .bot && bot == scope) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Invalid conversation identity")
        }
        self.init(kind: kind, scopeProfile: scope, botName: bot, botLabel: label, sessionID: session, isUnverified: unverified)
    }
}

struct WidgetConversationChoice: Codable, Hashable {
    let reference: WidgetConversationReference
    let title: String
    let isPinned: Bool
    let recency: Double

    init(reference: WidgetConversationReference, title: String, isPinned: Bool, recency: Double) {
        self.reference = reference
        self.title = title
        self.isPinned = isPinned
        self.recency = recency
    }
}

struct WidgetWorkspaceSnapshot: Codable, Hashable {
    let id: WidgetWorkspaceID
    let dashboardLabel: String
    let profileLabel: String
    let lastConversation: WidgetConversationReference?
    let choices: [WidgetConversationChoice]
    let recency: Double

    init(id: WidgetWorkspaceID, dashboardLabel: String, profileLabel: String, lastConversation: WidgetConversationReference?, choices: [WidgetConversationChoice], recency: Double) {
        self.id = id
        self.dashboardLabel = dashboardLabel
        self.profileLabel = profileLabel
        self.lastConversation = lastConversation
        self.choices = Self.boundedChoices(choices, lastConversation: lastConversation)
        self.recency = recency
    }

    private static func boundedChoices(_ choices: [WidgetConversationChoice], lastConversation: WidgetConversationReference?) -> [WidgetConversationChoice] {
        let prioritized = choices.sorted(by: preferred)
        var seen = Set<WidgetConversationReference>()
        let unique = prioritized.filter { seen.insert($0.reference).inserted }
        let last = unique.first { $0.reference == lastConversation }
        let rest = unique.filter { $0.reference != lastConversation }.sorted(by: preferred)
        return Array(([last].compactMap { $0 } + rest).prefix(20))
    }

    private static func preferred(_ lhs: WidgetConversationChoice, _ rhs: WidgetConversationChoice) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
        if lhs.reference.kind != rhs.reference.kind { return lhs.reference.kind.rawValue < rhs.reference.kind.rawValue }
        if lhs.reference.scopeProfile != rhs.reference.scopeProfile { return lhs.reference.scopeProfile < rhs.reference.scopeProfile }
        if lhs.reference.botName != rhs.reference.botName { return (lhs.reference.botName ?? "") < (rhs.reference.botName ?? "") }
        if lhs.reference.sessionID != rhs.reference.sessionID { return lhs.reference.sessionID < rhs.reference.sessionID }
        if lhs.reference.isUnverified != rhs.reference.isUnverified { return !lhs.reference.isUnverified }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return (lhs.reference.botLabel ?? "") < (rhs.reference.botLabel ?? "")
    }

    private enum CodingKeys: String, CodingKey { case id, dashboardLabel, profileLabel, lastConversation, choices, recency }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(WidgetWorkspaceID.self, forKey: .id),
            dashboardLabel: try values.decode(String.self, forKey: .dashboardLabel),
            profileLabel: try values.decode(String.self, forKey: .profileLabel),
            lastConversation: try values.decodeIfPresent(WidgetConversationReference.self, forKey: .lastConversation),
            choices: try values.decode([WidgetConversationChoice].self, forKey: .choices),
            recency: try values.decode(Double.self, forKey: .recency)
        )
    }
}

struct WidgetSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let appLanguage: String
    let currentWorkspaceID: WidgetWorkspaceID?
    let workspaces: [WidgetWorkspaceSnapshot]

    init(appLanguage: String, currentWorkspaceID: WidgetWorkspaceID?, workspaces: [WidgetWorkspaceSnapshot]) {
        schemaVersion = Self.currentSchemaVersion
        self.appLanguage = appLanguage
        self.currentWorkspaceID = currentWorkspaceID
        var seen = Set<WidgetWorkspaceID>()
        self.workspaces = Array(workspaces.filter { seen.insert($0.id).inserted }.sorted {
            if ($0.id == currentWorkspaceID) != ($1.id == currentWorkspaceID) { return $0.id == currentWorkspaceID }
            if $0.recency != $1.recency { return $0.recency > $1.recency }
            if $0.id.dashboardID != $1.id.dashboardID { return $0.id.dashboardID.uuidString < $1.id.dashboardID.uuidString }
            return $0.id.profile < $1.id.profile
        }.prefix(100))
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, appLanguage, currentWorkspaceID, workspaces }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values, debugDescription: "Unsupported widget snapshot schema")
        }
        let language = try values.decode(String.self, forKey: .appLanguage)
        let current = try values.decodeIfPresent(WidgetWorkspaceID.self, forKey: .currentWorkspaceID)
        let records = try values.decode([WidgetWorkspaceSnapshot].self, forKey: .workspaces)
        self.init(appLanguage: language, currentWorkspaceID: current, workspaces: records)
    }
}
