import Foundation
import WidgetKit

extension AppState {
    var widgetStore: WidgetSnapshotStore? {
        widgetSnapshotStoreOverride ?? WidgetSnapshotStore.production
    }

    private var widgetReload: () -> Void {
        if let widgetSnapshotReloadOverride { return widgetSnapshotReloadOverride }
        return {
            WidgetCenter.shared.reloadTimelines(ofKind: ConduitWidgetKind.native)
            WidgetCenter.shared.reloadTimelines(ofKind: ConduitWidgetKind.character)
        }
    }

    func publishWidgetSnapshot() {
        guard widgetSnapshotPublicationSuppressionDepth == 0,
              let store = widgetStore,
              let dashboardID = activeDashboardID,
              let dashboard = savedDashboardRegistry.dashboard(with: dashboardID),
              widgetSettledCatalogOwner == WidgetWorkspaceID(dashboardID: dashboardID, profile: activeProfile)
        else { return }

        let workspaceID = WidgetWorkspaceID(dashboardID: dashboardID, profile: activeProfile)
        guard workspaceID.isValid else { return }
        let lastReference = chatResumeWidgetReference(for: activeProfile).flatMap { reference in
            let value = Self.widgetReference(from: reference)
            return Self.isWidgetSafe(value) ? reference : nil
        }
        var choices = activeProfileSessions.compactMap { session -> WidgetConversationChoice? in
            guard !session.isArchived,
                  session.source != .cron else { return nil }
            let durableID = session.storedSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionID = (durableID?.isEmpty == false ? durableID : nil) ?? session.id
            let reference = SessionReference.dashboard(
                profile: activeProfile,
                sessionID: sessionID,
                isUnverified: !widgetBotEvidenceIsAvailable
            )
            let widgetReference = Self.widgetReference(from: reference)
            guard Self.isWidgetSafe(widgetReference) else { return nil }
            return WidgetConversationChoice(
                reference: widgetReference,
                title: session.title,
                isPinned: isSessionPinned(session),
                recency: session.lastActivityAt ?? 0
            )
        }

        for bot in botRoster where !bot.isHiddenByMeta {
            guard let canonical = bot.canonicalSession,
                  !canonical.id.isEmpty else { continue }
            let reference = SessionReference.bot(botName: bot.name, label: bot.displayLabel, sessionID: canonical.id)
            let widgetReference = Self.widgetReference(from: reference)
            guard Self.isWidgetSafe(widgetReference) else { continue }
            choices.append(WidgetConversationChoice(
                reference: widgetReference,
                title: bot.displayLabel,
                isPinned: bot.isPinned,
                recency: canonical.lastActive ?? 0
            ))
        }
        if let lastReference,
           lastReference.kind == .bot,
           // By chat, not label: a label saved earlier (the main bot's
           // "Default" before #1457) mustn't list the same chat twice.
           !choices.contains(where: { $0.reference.kind == .bot && $0.reference.sessionID == lastReference.sessionID }) {
            choices.append(WidgetConversationChoice(
                reference: Self.widgetReference(from: lastReference),
                title: Self.botConversationTitle(for: lastReference, mainName: profileDisplayName("default")),
                isPinned: false,
                recency: 0
            ))
        }

        let snapshot = WidgetWorkspaceSnapshot(
            id: workspaceID,
            dashboardLabel: dashboard.label,
            profileLabel: profileDisplayName(activeProfile),
            lastConversation: lastReference.map(Self.widgetReference(from:)),
            choices: choices,
            recency: choices.map(\.recency).max() ?? 0
        )
        let publisher = WidgetSnapshotPublisher(store: store, reload: widgetReload)
        do {
            try publisher.publish(snapshot, current: workspaceID, language: AppLanguageStore.shared.selection.rawValue)
        } catch {
            // Widget data is a best-effort cache. A failed atomic write leaves
            // the previous valid snapshot available to the extension.
        }
    }

    func publishWidgetLanguage() {
        guard let store = widgetStore else { return }
        let publisher = WidgetSnapshotPublisher(store: store, reload: widgetReload)
        do { try publisher.updateLanguage(AppLanguageStore.shared.selection.rawValue) }
        catch { /* Retain the last valid snapshot if the cache cannot be written. */ }
        publishWidgetSnapshot()
    }

    func publishWidgetCurrentWorkspace(dashboardID: UUID?, profile: String) {
        guard let store = widgetStore else { return }
        let current = dashboardID.map { WidgetWorkspaceID(dashboardID: $0, profile: profile) }
        let publisher = WidgetSnapshotPublisher(store: store, reload: widgetReload)
        do { try publisher.updateCurrentWorkspace(current, language: AppLanguageStore.shared.selection.rawValue) }
        catch { /* Keep the prior valid cache if atomic replacement fails. */ }
    }

    func removeWidgetSnapshot(dashboardID: UUID) {
        guard let store = widgetStore else { return }
        let publisher = WidgetSnapshotPublisher(store: store, reload: widgetReload)
        do { try publisher.remove(dashboardID: dashboardID) }
        catch { /* Keep the previous valid cache if atomic replacement fails. */ }
    }

    func retainWidgetProfiles(_ profiles: Set<String>, dashboardID: UUID) {
        guard let store = widgetStore else { return }
        let publisher = WidgetSnapshotPublisher(store: store, reload: widgetReload)
        do { try publisher.retainProfiles(profiles, dashboardID: dashboardID) }
        catch { /* Keep the previous valid cache if atomic replacement fails. */ }
    }

    func chatResumeWidgetReference(for profile: String) -> SessionReference? {
        chatResumeLastSessionReference(for: profile)
    }

    static func widgetReference(from reference: SessionReference) -> WidgetConversationReference {
        WidgetConversationReference(
            kind: reference.kind == .bot ? .bot : .dashboard,
            scopeProfile: reference.scopeProfile,
            botName: reference.botName,
            // A label that is only the id names nothing (the main bot's
            // "Default" saved before #1457).
            botLabel: reference.botLabel.flatMap {
                isIDOnlyBotLabel($0, profile: reference.botName ?? reference.scopeProfile) ? nil : $0
            },
            sessionID: reference.sessionID,
            isUnverified: reference.isUnverified
        )
    }

    static func sessionReference(from reference: WidgetConversationReference) -> SessionReference {
        SessionReference(
            kind: reference.kind == .bot ? .bot : .dashboard,
            scopeProfile: reference.scopeProfile,
            botName: reference.botName,
            botLabel: reference.botLabel,
            sessionID: reference.sessionID,
            isUnverified: reference.isUnverified
        )
    }

    private static func isWidgetSafe(_ reference: WidgetConversationReference) -> Bool {
        guard !reference.scopeProfile.isEmpty, reference.scopeProfile.count <= 512,
              !reference.sessionID.isEmpty, reference.sessionID.count <= 512 else { return false }
        switch reference.kind {
        case .dashboard: return reference.botName == nil
        case .bot: return reference.botName == reference.scopeProfile
        }
    }
}
