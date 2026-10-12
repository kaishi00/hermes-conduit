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
