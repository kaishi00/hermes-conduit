import Foundation
import WidgetKit

extension AppState {
    var widgetStore: WidgetSnapshotStore? {
        widgetSnapshotStoreOverride ?? WidgetSnapshotStore.production
    }

    private var widgetReload: () -> Void {
        if let widgetSnapshotReloadOverride { return widgetSnapshotReloadOverride }
        let store = widgetStore
        return {
            WidgetCenter.shared.reloadTimelines(ofKind: ConduitWidgetKind.native)
            WidgetCenter.shared.reloadTimelines(ofKind: ConduitWidgetKind.character)
            // Spotlight and Siri know the same chats the widget offers.
            MainActor.assumeIsolated { ConduitChatSpotlight.refresh(from: store) }
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

        for bot in orderedBots(botRoster) where !bot.isHiddenByMeta {
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
           !choices.contains(where: {
               $0.reference.kind == .bot && $0.reference.sessionID == lastReference.sessionID
                   && $0.reference.botName == lastReference.botName
           }) {
            // Labelled as titled, so a label saved earlier (the main bot's
            // "Default") reads as the bot does now.
            let title = Self.botConversationTitle(for: lastReference, mainName: profileDisplayName("default"))
            let saved = Self.widgetReference(from: lastReference)
            let labelled = WidgetConversationReference(
                kind: saved.kind, scopeProfile: saved.scopeProfile, botName: saved.botName,
                botLabel: title, sessionID: saved.sessionID, isUnverified: saved.isUnverified
            )
            choices.append(WidgetConversationChoice(
                reference: labelled,
                title: title,
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

    /// The other combined dashboards' chats and Bot Chats in the widgets'
    /// snapshot, a workspace per profile, from the reads through their kept
    /// connections: Siri, Spotlight, Send to Hermes and the launcher
    /// widget's picker know them as they know the dashboard on screen's,
    /// rather than as they were on its last visit (no-switch plan stage 2).
    /// The current workspace stays the one on screen.
    func publishCombinedWidgetWorkspaces() {
        guard widgetSnapshotPublicationSuppressionDepth == 0, let store = widgetStore,
              isInCombinedGroup(activeDashboardID) else { return }
        let previous = Dictionary((store.read()?.workspaces ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var workspaces: [WidgetWorkspaceSnapshot] = []
        for dashboard in savedDashboardRegistry.dashboards where dashboard.id != activeDashboardID {
            guard isInCombinedGroup(dashboard.id), let chats = combinedDashboardChats[dashboard.id] else { continue }
            workspaces += Self.combinedWidgetWorkspaces(
                dashboardID: dashboard.id,
                dashboardLabel: dashboard.label,
                profiles: chats.profiles,
                sessions: chats.sessions,
                bots: combinedDashboardBots[dashboard.id]?.bots,
                botsProfile: rememberedActiveProfile(for: dashboard.id) ?? "default",
                previous: previous
            )
        }
        guard !workspaces.isEmpty else { return }
        let publisher = WidgetSnapshotPublisher(store: store, reload: widgetReload)
        do { try publisher.publish(others: workspaces, language: AppLanguageStore.shared.selection.rawValue) }
        catch { /* Widget data is a best-effort cache; the last valid one stays. */ }
    }

    /// Another combined dashboard's workspaces, one per profile it was read
    /// for: each profile's chats (no cron runs or Bot Chats, as on screen),
    /// and its Bot Chats in `botsProfile`'s, the profile a switch there
    /// resumes on, as the dashboard on screen lists its bots in the profile
    /// in use. Until its roster is read, its chats are unverified, as on
    /// screen before the roster's evidence. A chat's pin is Hermes' flag,
    /// else what the snapshot last said; the label and last chat are the
    /// snapshot's, since only a visit there knows them.
    static func combinedWidgetWorkspaces(
        dashboardID: UUID,
        dashboardLabel: String,
        profiles: [String],
        sessions: [SessionSummary],
        bots: [BotProfile]?,
        botsProfile: String,
        previous: [WidgetWorkspaceID: WidgetWorkspaceSnapshot]
    ) -> [WidgetWorkspaceSnapshot] {
        let roster = bots ?? []
        var botsHome = profiles.first { profilesMatch($0, botsProfile) } ?? profiles.first
        if roster.isEmpty { botsHome = nil }
        return profiles.compactMap { profile -> WidgetWorkspaceSnapshot? in
            let id = WidgetWorkspaceID(dashboardID: dashboardID, profile: profile)
            guard id.isValid else { return nil }
            let before = previous[id]
            let pinnedBefore = Set((before?.choices ?? []).filter(\.isPinned).map(\.reference.sessionID))
            var choices = sessions.compactMap { session -> WidgetConversationChoice? in
                guard profilesMatch(session.profile ?? "", profile), !session.isArchived, session.source != .cron,
                      !BotChatHygiene.isCanonicalBotChatRow(session, roster: roster) else { return nil }
                let durableID = session.storedSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
                let sessionID = (durableID?.isEmpty == false ? durableID : nil) ?? session.id
                let reference = widgetReference(from: .dashboard(profile: profile, sessionID: sessionID, isUnverified: bots == nil))
                guard isWidgetSafe(reference) else { return nil }
                return WidgetConversationChoice(
                    reference: reference,
                    title: session.title,
                    isPinned: session.isPinned ?? pinnedBefore.contains(sessionID),
                    recency: session.lastActivityAt ?? 0
                )
            }
            if profile == botsHome {
                for bot in roster where !bot.isHiddenByMeta {
                    guard let canonical = bot.canonicalSession, !canonical.id.isEmpty else { continue }
                    let reference = widgetReference(from: .bot(botName: bot.name, label: bot.displayLabel, sessionID: canonical.id))
                    guard isWidgetSafe(reference) else { continue }
                    choices.append(WidgetConversationChoice(
                        reference: reference,
                        title: bot.displayLabel,
                        isPinned: bot.isPinned,
                        recency: canonical.lastActive ?? 0
                    ))
                }
            }
            let named = roster.first { profilesMatch($0.name, profile) }?.displayLabel
            let profileLabel = before?.profileLabel ?? named
                ?? (BotManagement.isDefaultProfile(profile) ? ProfileAppearanceStore.defaultName
                    : String(profile.prefix(1)).uppercased() + String(profile.dropFirst()))
            return WidgetWorkspaceSnapshot(
                id: id,
                dashboardLabel: dashboardLabel,
                profileLabel: profileLabel,
                lastConversation: before?.lastConversation,
                choices: choices,
                recency: choices.map(\.recency).max() ?? 0
            )
        }
    }

    func publishWidgetLanguage() {
        guard let store = widgetStore else { return }
        let publisher = WidgetSnapshotPublisher(store: store, reload: widgetReload)
        do { try publisher.updateLanguage(AppLanguageStore.shared.selection.rawValue) }
        catch { /* Retain the last valid snapshot if the cache cannot be written. */ }
        publishWidgetSnapshot()
        // The Pulse and Plan limits widgets word what they show in the app's language.
        reloadPulseWidget()
        reloadUsageWidget()
    }

    func publishWidgetCurrentWorkspace(dashboardID: UUID?, profile: String) {
        guard let store = widgetStore else { return }
        let current = dashboardID.map { WidgetWorkspaceID(dashboardID: $0, profile: profile) }
        let publisher = WidgetSnapshotPublisher(store: store, reload: widgetReload)
        do { try publisher.updateCurrentWorkspace(current, language: AppLanguageStore.shared.selection.rawValue) }
        catch { /* Keep the prior valid cache if atomic replacement fails. */ }
    }

    /// The widgets' and Siri's copy of a dashboard's name, after a rename.
    func relabelWidgetSnapshot(dashboardID: UUID) {
        guard let store = widgetStore, let label = savedDashboardRegistry.dashboard(with: dashboardID)?.label else { return }
        let publisher = WidgetSnapshotPublisher(store: store, reload: widgetReload)
        do { try publisher.relabel(dashboardID: dashboardID, label: label) }
        catch { /* Keep the previous valid cache if atomic replacement fails. */ }
    }

    func removeWidgetSnapshot(dashboardID: UUID) {
        guard let store = widgetStore else { return }
        let publisher = WidgetSnapshotPublisher(store: store, reload: widgetReload)
        do { try publisher.remove(dashboardID: dashboardID) }
        catch { /* Keep the previous valid cache if atomic replacement fails. */ }
        removePulseWidget(dashboardID: dashboardID)
        removeUsageWidget(dashboardID: dashboardID)
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
            botLabel: reference.botLabel,
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
