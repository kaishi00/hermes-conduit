//
//  ConduitChatEntity.swift
//  Conduit
//
//  Hermes chats as things iOS knows about: Spotlight finds them by title,
//  Siri opens one by name ("Open Trip planning in Conduit"), and Send to
//  Hermes offers a chat picker instead of a name to type.
//
//  The chats are the launcher widget's: the snapshot the app writes for
//  the widget and the Share extension (pinned and recent chats and the Bot
//  Chats of each workspace the app has shown, up to 20 a workspace). Only
//  their titles and where they live are indexed, on the phone; no message
//  is. Opening one goes through the widget's own launch, so a chat on
//  another dashboard or profile switches there first, as a widget tap does.
//
//  Saved shortcuts bind to these types' names and to the entity's id (the
//  widget's conversation id): never rename them.
//

import AppIntents
import CoreSpotlight
import Foundation
import os

@available(iOS 16.0, *)
struct ConduitChatEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Hermes chat")
    static let defaultQuery = ConduitChatEntityQuery()

    let workspace: WidgetWorkspaceID
    let reference: WidgetConversationReference
    /// The chat's title, a Bot Chat's bot name. Nil when the chat is no
    /// longer among the snapshot's (a saved shortcut's older pick).
    let title: String?
    /// "Dashboard — Profile", as the widget's workspace picker reads.
    let place: String?

    var id: String { WidgetEntityIdentifier.conversation(workspace: workspace, reference: reference) }

    var displayRepresentation: DisplayRepresentation {
        let name = title ?? AppLocalization.string("Chat")
        let image = DisplayRepresentation.Image(systemName: reference.kind == .bot ? "person.crop.circle" : "bubble.left")
        guard let place else { return DisplayRepresentation(title: "\(name)", image: image) }
        return DisplayRepresentation(title: "\(name)", subtitle: "\(place)", image: image)
    }
}

@available(iOS 18.0, *)
extension ConduitChatEntity: IndexedEntity {}

/// The chats in a widget snapshot, as entities. Pure, so tests can feed it
/// a snapshot.
enum ConduitChatCatalog {
    /// Every chat, the workspace in use first, each workspace in the
    /// snapshot's order (the last chat, then pinned, then recent).
    @available(iOS 16.0, *)
    static func entities(in snapshot: WidgetSnapshot?) -> [ConduitChatEntity] {
        guard let snapshot else { return [] }
        return snapshot.workspaces.flatMap { workspace in
            workspace.choices.map {
                ConduitChatEntity(workspace: workspace.id, reference: $0.reference, title: $0.title,
                                  place: "\(workspace.dashboardLabel) — \(workspace.profileLabel)")
            }
        }
    }

    /// The chat a saved id names. One the snapshot no longer lists is still
    /// returned, untitled, so a saved shortcut keeps its pick; opening or
    /// sending to it then says whether the chat is still there.
    @available(iOS 16.0, *)
    static func entity(id: String, in snapshot: WidgetSnapshot?) -> ConduitChatEntity? {
        guard let identity = WidgetEntityIdentifier.decodeConversation(id) else { return nil }
        if let listed = entities(in: snapshot).first(where: { $0.id == id }) { return listed }
        return ConduitChatEntity(workspace: identity.workspace, reference: identity.reference, title: nil, place: nil)
    }

    /// Chats whose title holds every word of `text`, in any case or accent.
    @available(iOS 16.0, *)
    static func matching(_ text: String, in snapshot: WidgetSnapshot?) -> [ConduitChatEntity] {
        let words = text.split(whereSeparator: \.isWhitespace).map { String($0) }
        guard !words.isEmpty else { return [] }
        return entities(in: snapshot).filter { chat in
            guard let title = chat.title else { return false }
            return words.allSatisfy { title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

@available(iOS 16.0, *)
struct ConduitChatEntityQuery: EntityStringQuery {
    private let snapshotReader: @Sendable () -> WidgetSnapshot?

    init() {
        snapshotReader = { WidgetSnapshotStore.production?.read() }
    }

    init(snapshotReader: @escaping @Sendable () -> WidgetSnapshot?) {
        self.snapshotReader = snapshotReader
    }

    func entities(for identifiers: [ConduitChatEntity.ID]) async throws -> [ConduitChatEntity] {
        let snapshot = snapshotReader()
        return identifiers.compactMap { ConduitChatCatalog.entity(id: $0, in: snapshot) }
    }

    func entities(matching string: String) async throws -> [ConduitChatEntity] {
        ConduitChatCatalog.matching(string, in: snapshotReader())
    }

    func suggestedEntities() async throws -> [ConduitChatEntity] {
        ConduitChatCatalog.entities(in: snapshotReader())
    }
}

/// Opens a chat in Conduit: from Spotlight, Siri, or a shortcut.
@available(iOS 16.0, *)
struct OpenConduitChatIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Open a Hermes chat in Conduit.")

    /// iOS 17–25 declaration; see `StartVoiceConversationIntent`. Must stay
    /// a boolean literal for the App Intents metadata processor.
    @available(iOS, deprecated: 26.0, message: "Use supportedModes on iOS 26+; retained for iOS 17–25.")
    static let openAppWhenRun: Bool = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    @Parameter(title: "Chat")
    var target: ConduitChatEntity

    init() {}

    init(target: ConduitChatEntity) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        // The widget's launch: it switches dashboard and profile, waits for
        // the connection and says when the chat isn't there any more.
        guard let link = WidgetLaunchLink(action: .resume, workspace: target.workspace, reference: target.reference) else {
            throw ShortcutSendError(message: AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
        }
        _ = AppStateRuntimeRegistry.shared.appState.routeWidgetLaunchURL(link.url)
        return .result()
    }
}

/// Keeps Spotlight's copy of the chats and Siri's chat names in step with
/// the widget snapshot. Called after each snapshot write that changed it.
@MainActor
enum ConduitChatSpotlight {
    private static let logger = Logger(subsystem: "com.milim.relay", category: "spotlight")
    private static var pending: Task<Void, Never>?
    private static var generation = 0

    static func refresh(from store: WidgetSnapshotStore?) {
        // Siri matches spoken chat names only against what it was told.
        SiriProfileShortcuts.refresh()
        guard #available(iOS 18.0, *) else { return }
        generation += 1
        let mine = generation
        let previous = pending
        previous?.cancel()
        pending = Task { @MainActor in
            // One replacement at a time: an older one that already started
            // finishes before this one deletes, so it can't put its list back.
            await previous?.value
            // Writes come in bursts (each profile's list, then its bots).
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, mine == generation else { return }
            let chats = ConduitChatCatalog.entities(in: store?.read())
            let index = CSSearchableIndex.default()
            do {
                // Whole, so a chat that left the snapshot leaves Spotlight.
                try await index.deleteAppEntities(ofType: ConduitChatEntity.self)
                // A newer list waits behind this one and replaces it.
                guard mine == generation else { return }
                if !chats.isEmpty { try await index.indexAppEntities(chats) }
            } catch {
                logger.error("Spotlight chat index failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
