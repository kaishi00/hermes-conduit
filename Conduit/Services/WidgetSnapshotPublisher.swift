import Foundation

@MainActor
struct WidgetSnapshotPublisher {
    private let store: WidgetSnapshotStore
    private let reload: () -> Void

    init(store: WidgetSnapshotStore, reload: @escaping () -> Void) {
        self.store = store
        self.reload = reload
    }

    func publish(_ workspace: WidgetWorkspaceSnapshot, current: WidgetWorkspaceID?, language: String) throws {
        var workspaces = Dictionary(uniqueKeysWithValues: (store.read()?.workspaces ?? []).map { ($0.id, $0) })
        workspaces[workspace.id] = workspace
        let snapshot = WidgetSnapshot(
            appLanguage: language,
            currentWorkspaceID: current,
            workspaces: Array(workspaces.values)
        )
        try writeIfChanged(snapshot)
    }

    /// Workspaces of dashboards not on screen (the other combined ones),
    /// written together; the current workspace stays as it is. `over`: the
    /// snapshot as the caller just read it.
    func publish(others: [WidgetWorkspaceSnapshot], over previous: WidgetSnapshot?, language: String) throws {
        var workspaces = Dictionary((previous?.workspaces ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for workspace in others { workspaces[workspace.id] = workspace }
        try writeIfChanged(WidgetSnapshot(
            appLanguage: language,
            currentWorkspaceID: previous?.currentWorkspaceID,
            workspaces: Array(workspaces.values)
        ))
    }

    func remove(dashboardID: UUID) throws {
        guard let previous = store.read() else { return }
        let workspaces = previous.workspaces.filter { $0.id.dashboardID != dashboardID }
        let current = previous.currentWorkspaceID?.dashboardID == dashboardID ? nil : previous.currentWorkspaceID
        try writeIfChanged(WidgetSnapshot(appLanguage: previous.appLanguage, currentWorkspaceID: current, workspaces: workspaces))
    }

    func retainProfiles(_ profiles: Set<String>, dashboardID: UUID) throws {
        guard let previous = store.read() else { return }
        let workspaces = previous.workspaces.filter {
            $0.id.dashboardID != dashboardID || profiles.contains($0.id.profile)
        }
        let current = previous.currentWorkspaceID.flatMap { id in
            id.dashboardID != dashboardID || profiles.contains(id.profile) ? id : nil
        }
        try writeIfChanged(WidgetSnapshot(appLanguage: previous.appLanguage, currentWorkspaceID: current, workspaces: workspaces))
    }

    /// A dashboard renamed (Dashboard names): every workspace of it the
    /// widgets and Siri keep says its new name.
    func relabel(dashboardID: UUID, label: String) throws {
        guard let previous = store.read() else { return }
        let workspaces = previous.workspaces.map { workspace in
            guard workspace.id.dashboardID == dashboardID, workspace.dashboardLabel != label else { return workspace }
            return WidgetWorkspaceSnapshot(
                id: workspace.id, dashboardLabel: label, profileLabel: workspace.profileLabel,
                lastConversation: workspace.lastConversation, choices: workspace.choices, recency: workspace.recency
            )
        }
        try writeIfChanged(WidgetSnapshot(appLanguage: previous.appLanguage, currentWorkspaceID: previous.currentWorkspaceID, workspaces: workspaces))
    }

    func updateLanguage(_ language: String) throws {
        guard let previous = store.read() else { return }
        try writeIfChanged(WidgetSnapshot(appLanguage: language, currentWorkspaceID: previous.currentWorkspaceID, workspaces: previous.workspaces))
    }

    func updateCurrentWorkspace(_ current: WidgetWorkspaceID?, language: String) throws {
        let previous = store.read()
        let selected = current.flatMap { $0.isValid ? $0 : nil }
        try writeIfChanged(WidgetSnapshot(
            appLanguage: language,
            currentWorkspaceID: selected,
            workspaces: previous?.workspaces ?? []
        ))
    }

    private func writeIfChanged(_ snapshot: WidgetSnapshot) throws {
        // The store compares the deterministic encoding with the bytes on
        // disk (WidgetConversationReference equality deliberately ignores
        // botLabel), so an unchanged snapshot is neither written nor reloaded.
        guard try store.write(snapshot) else { return }
        reload()
    }
}
