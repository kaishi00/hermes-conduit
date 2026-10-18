import AppIntents
import Foundation

/// A versioned, lossless identity used by WidgetKit to persist picker choices.
/// Display labels and conversation titles are deliberately excluded.
enum WidgetEntityIdentifier {
    private static let workspacePrefix = "widget-workspace-v1:"
    private static let conversationPrefix = "widget-conversation-v1:"

    private struct WorkspacePayload: Codable {
        let dashboardID: UUID
        let profile: String
    }

    private struct ConversationPayload: Codable {
        let dashboardID: UUID
        let workspaceProfile: String
        let reference: ReferencePayload
    }

    private struct ReferencePayload: Codable {
        let kind: WidgetConversationReference.Kind
        let scopeProfile: String
        let botName: String?
        let sessionID: String
        let isUnverified: Bool

        init(_ value: WidgetConversationReference) {
            kind = value.kind
            scopeProfile = value.scopeProfile
            botName = value.botName
            sessionID = value.sessionID
            isUnverified = value.isUnverified
        }

        var value: WidgetConversationReference {
            WidgetConversationReference(kind: kind, scopeProfile: scopeProfile, botName: botName, botLabel: nil, sessionID: sessionID, isUnverified: isUnverified)
        }
    }

    static func workspace(_ value: WidgetWorkspaceID) -> String {
        workspacePrefix + encode(WorkspacePayload(dashboardID: value.dashboardID, profile: value.profile))
    }

    static func decodeWorkspace(_ identifier: String) -> WidgetWorkspaceID? {
        guard identifier.hasPrefix(workspacePrefix),
              let payload: WorkspacePayload = decode(String(identifier.dropFirst(workspacePrefix.count))),
              !payload.profile.isEmpty, payload.profile.count <= 512 else { return nil }
        return WidgetWorkspaceID(dashboardID: payload.dashboardID, profile: payload.profile)
    }

    static func conversation(workspace: WidgetWorkspaceID, reference: WidgetConversationReference) -> String {
        let payload = ConversationPayload(
            dashboardID: workspace.dashboardID,
            workspaceProfile: workspace.profile,
            reference: ReferencePayload(reference)
        )
        return conversationPrefix + encode(payload)
    }

    static func decodeConversation(_ identifier: String) -> (workspace: WidgetWorkspaceID, reference: WidgetConversationReference)? {
        guard identifier.hasPrefix(conversationPrefix),
              let payload: ConversationPayload = decode(String(identifier.dropFirst(conversationPrefix.count))),
              !payload.workspaceProfile.isEmpty, payload.workspaceProfile.count <= 512,
              !payload.reference.scopeProfile.isEmpty, payload.reference.scopeProfile.count <= 512,
              !payload.reference.sessionID.isEmpty, payload.reference.sessionID.count <= 512 else { return nil }
        let reference = payload.reference.value
        guard (reference.kind == .dashboard && reference.botName == nil && reference.scopeProfile == payload.workspaceProfile) ||
                (reference.kind == .bot && reference.botName == reference.scopeProfile) else { return nil }
        return (WidgetWorkspaceID(dashboardID: payload.dashboardID, profile: payload.workspaceProfile), reference)
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let base64 = (try? encoder.encode(value).base64EncodedString()) ?? ""
        return base64.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode<T: Decodable>(_ value: String) -> T? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

struct WidgetWorkspaceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workspace")
    static let defaultQuery = WidgetWorkspaceEntityQuery()

    let workspaceID: WidgetWorkspaceID
    let displayName: String?

    var id: String { WidgetEntityIdentifier.workspace(workspaceID) }
    var displayRepresentation: DisplayRepresentation {
        if let displayName {
            DisplayRepresentation(title: "\(displayName)")
        } else {
            DisplayRepresentation(title: "Workspace")
        }
    }

    init(workspaceID: WidgetWorkspaceID, displayName: String?) {
        self.workspaceID = workspaceID
        self.displayName = displayName
    }

    init?(id: String) {
        guard let workspaceID = WidgetEntityIdentifier.decodeWorkspace(id) else { return nil }
        self.init(workspaceID: workspaceID, displayName: nil)
    }
}

struct WidgetConversationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")
    static let defaultQuery = WidgetConversationEntityQuery()

    let workspaceID: WidgetWorkspaceID
    let reference: WidgetConversationReference
    let displayName: String?

    var id: String { WidgetEntityIdentifier.conversation(workspace: workspaceID, reference: reference) }
    var displayRepresentation: DisplayRepresentation {
        if let displayName {
            DisplayRepresentation(title: "\(displayName)")
        } else {
            DisplayRepresentation(title: "Conversation")
        }
    }

    init(workspaceID: WidgetWorkspaceID, reference: WidgetConversationReference, displayName: String?) {
        self.workspaceID = workspaceID
        self.reference = reference
        self.displayName = displayName
    }

    init?(id: String) {
        guard let identity = WidgetEntityIdentifier.decodeConversation(id) else { return nil }
        self.init(workspaceID: identity.workspace, reference: identity.reference, displayName: nil)
    }
}

struct WidgetWorkspaceEntityQuery: EntityQuery {
    private let snapshotReader: @Sendable () -> WidgetSnapshot?

    init() {
        snapshotReader = { WidgetSnapshotStore.production?.read() }
    }

    init(snapshotReader: @escaping @Sendable () -> WidgetSnapshot?) {
        self.snapshotReader = snapshotReader
    }

    func entities(for identifiers: [WidgetWorkspaceEntity.ID]) async throws -> [WidgetWorkspaceEntity] {
        let snapshot = snapshotReader()
        return identifiers.compactMap { identifier in
            guard let id = WidgetEntityIdentifier.decodeWorkspace(identifier) else { return nil }
            let record = snapshot?.workspaces.first { $0.id == id }
            let name = record.map { "\($0.dashboardLabel) — \($0.profileLabel)" }
            return WidgetWorkspaceEntity(workspaceID: id, displayName: name)
        }
    }

    func suggestedEntities() async throws -> [WidgetWorkspaceEntity] {
        guard let snapshot = snapshotReader() else { return [] }
        return snapshot.workspaces.map {
            WidgetWorkspaceEntity(workspaceID: $0.id, displayName: "\($0.dashboardLabel) — \($0.profileLabel)")
        }
    }
}

struct WidgetConversationEntityQuery: EntityQuery {
    @IntentParameterDependency<LauncherWidgetConfigurationIntent>(\.$workspace) var intent
    private let snapshotReader: @Sendable () -> WidgetSnapshot?

    init() {
        snapshotReader = { WidgetSnapshotStore.production?.read() }
    }

    init(snapshotReader: @escaping @Sendable () -> WidgetSnapshot?) {
        self.snapshotReader = snapshotReader
    }

    func entities(for identifiers: [WidgetConversationEntity.ID]) async throws -> [WidgetConversationEntity] {
        let snapshot = snapshotReader()
        return identifiers.compactMap { identifier in
            guard let identity = WidgetEntityIdentifier.decodeConversation(identifier) else { return nil }
            let record = snapshot?.workspaces.first { $0.id == identity.workspace }
            let choice = record?.choices.first { $0.reference == identity.reference }
            return WidgetConversationEntity(workspaceID: identity.workspace, reference: identity.reference, displayName: choice?.title)
        }
    }

    func suggestedEntities() async throws -> [WidgetConversationEntity] {
        guard let snapshot = snapshotReader() else { return [] }
        let selectedID = intent?.workspace.workspaceID ?? snapshot.currentWorkspaceID
        guard let selectedID, let workspace = snapshot.workspaces.first(where: { $0.id == selectedID }) else { return [] }
        return workspace.choices.map {
            WidgetConversationEntity(workspaceID: selectedID, reference: $0.reference, displayName: $0.title)
        }
    }
}

struct LauncherWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Conduit Widget"
    static let description = IntentDescription("Choose a workspace and conversation for this widget.")

    @Parameter(title: "Workspace") var workspace: WidgetWorkspaceEntity?
    @Parameter(title: "Conversation") var conversation: WidgetConversationEntity?
    @Parameter(title: "Hide conversation title") var hideTitle: Bool?

    var shouldHideTitle: Bool { hideTitle ?? false }

    init() {
        workspace = nil
        conversation = nil
        hideTitle = nil
    }
}
