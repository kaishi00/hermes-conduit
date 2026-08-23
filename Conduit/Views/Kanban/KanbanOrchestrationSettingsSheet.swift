import SwiftUI

/// Mobile-native Orchestration Settings (Kanban V3A).
///
/// Desktop parity (apps/desktop/src/plugins/kanban/orchestration.tsx) in a
/// grouped iPhone form:
/// - "Default" is the wire value "" (empty string) — the backend clears the
///   override and falls back to the active default profile. No Conduit
///   sentinel is ever introduced.
/// - Configured vs resolved values are shown honestly: the Default row reads
///   "Default (coder)" when the server resolves to coder, without implying
///   coder was persisted.
/// - Only changed fields are PUT (the backend writes only present fields).
/// - Saving is ownership-safe through KanbanStore and never touches
///   HermesClient / session transport; upstream nudges nothing for settings.
struct KanbanOrchestrationSettingsSheet: View {
    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss

    // Editor draft, seeded ONCE from the current server snapshot so a
    // background poll can never clobber an in-progress edit.
    @State private var autoDecompose = true
    @State private var autoPromoteChildren = true
    @State private var orchestratorProfile = ""
    @State private var defaultAssignee = ""
    @State private var seed: Seed?
    @State private var isSaving = false
    @State private var notice: String?
    @State private var errorMessage: String?

    private struct Seed: Equatable {
        var autoDecompose: Bool
        var autoPromoteChildren: Bool
        var orchestratorProfile: String
        var defaultAssignee: String
    }

    private var hasChanges: Bool {
        guard let seed else { return false }
        return autoDecompose != seed.autoDecompose
            || autoPromoteChildren != seed.autoPromoteChildren
            || orchestratorProfile != seed.orchestratorProfile
            || defaultAssignee != seed.defaultAssignee
    }

    private var patch: KanbanOrchestrationPatch {
        guard let seed else { return KanbanOrchestrationPatch() }
        return KanbanOrchestrationPatch(
            orchestratorProfile: orchestratorProfile != seed.orchestratorProfile ? orchestratorProfile : nil,
            defaultAssignee: defaultAssignee != seed.defaultAssignee ? defaultAssignee : nil,
            autoDecompose: autoDecompose != seed.autoDecompose ? autoDecompose : nil,
            autoPromoteChildren: autoPromoteChildren != seed.autoPromoteChildren ? autoPromoteChildren : nil
        )
    }

    private var orchestratorSelectionLabel: String {
        if !orchestratorProfile.isEmpty { return orchestratorProfile }
        return KanbanOrchestrationDisplay.defaultOptionLabel(
            configured: "",
            resolved: store.orchestration?.resolvedOrchestratorProfile ?? ""
        )
    }

    private var assigneeSelectionLabel: String {
        if !defaultAssignee.isEmpty { return defaultAssignee }
        return KanbanOrchestrationDisplay.defaultOptionLabel(
            configured: "",
            resolved: store.orchestration?.resolvedDefaultAssignee ?? ""
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.orchestration == nil {
                    ContentUnavailableView(
                        "Orchestration Settings Unavailable",
                        systemImage: "slider.horizontal.3",
                        description: Text("Load a Kanban board to read the server's orchestration settings.")
                    )
                } else {
                    Form {
                        Section {
                            Toggle("Auto Decompose", isOn: $autoDecompose)
                                .accessibilityHint("Fans eligible triage tasks into child task graphs")
                            Toggle("Auto Promote Children", isOn: $autoPromoteChildren)
                                .accessibilityHint("Promotes parent-free decomposed children to Ready")
                        } footer: {
                            Text("Auto Decompose lets the dispatcher decompose eligible triage tasks. Auto Promote Children moves parent-free children to Ready instead of leaving them in To Do.")
                        }

                        Section("Orchestrator Profile") {
                            Picker("Orchestrator Profile", selection: $orchestratorProfile) {
                                Text(orchestratorSelectionLabel).tag("")
                                ForEach(store.profiles) { profile in
                                    Text(profile.name).tag(profile.name)
                                }
                            }
                            .pickerStyle(.menu)
                            Text(footnote(configured: orchestratorProfile, resolved: store.orchestration?.resolvedOrchestratorProfile ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Section("Default Assignee") {
                            Picker("Default Assignee", selection: $defaultAssignee) {
                                Text(assigneeSelectionLabel).tag("")
                                ForEach(store.profiles) { profile in
                                    Text(profile.name).tag(profile.name)
                                }
                            }
                            .pickerStyle(.menu)
                            Text(footnote(configured: defaultAssignee, resolved: store.orchestration?.resolvedDefaultAssignee ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let errorMessage {
                            Section {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                        if let notice {
                            Section {
                                Label(notice, systemImage: "checkmark.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Orchestration Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(!hasChanges || isSaving)
                }
            }
            .onAppear(perform: seedOnce)
            // The sheet may open before orchestration data lands (e.g. right
            // after launch); re-seed the moment it arrives. seedOnce is
            // idempotent, so a later remediation is a no-op.
            .onChange(of: store.orchestration) { _, _ in
                seedOnce()
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func footnote(configured: String, resolved: String) -> String {
        KanbanOrchestrationDisplay.resolveFootnote(configured: configured, resolved: resolved)
    }

    private func seedOnce() {
        guard seed == nil else { return }
        guard let settings = store.orchestration else { return }
        autoDecompose = settings.autoDecompose
        autoPromoteChildren = settings.autoPromoteChildren ?? KanbanOrchestrationSettings.defaultAutoPromoteChildren
        orchestratorProfile = settings.orchestratorProfile
        defaultAssignee = settings.defaultAssignee
        seed = Seed(
            autoDecompose: autoDecompose,
            autoPromoteChildren: autoPromoteChildren,
            orchestratorProfile: orchestratorProfile,
            defaultAssignee: defaultAssignee
        )
    }

    private func save() async {
        guard hasChanges, !patch.isEmpty else { return }
        // Freeze server/board ownership BEFORE the suspension: a completion
        // from a stale generation is UI-inert (its echo must not re-base this
        // sheet against a server that no longer owns the screen).
        let generation = store.currentConfigurationGeneration
        isSaving = true
        errorMessage = nil
        notice = nil
        defer {
            if store.isCurrentConfiguration(generation) {
                isSaving = false
            }
        }
        do {
            // Re-seed from the authoritative echo (when available) so a later
            // poll cannot present stale "unsaved changes"; if the refresh
            // failed the saved draft values still become the new baseline.
            let updated = try await store.updateOrchestration(patch)
            guard store.isCurrentConfiguration(generation) else { return }
            autoDecompose = updated?.autoDecompose ?? autoDecompose
            autoPromoteChildren = updated?.autoPromoteChildren ?? autoPromoteChildren
            orchestratorProfile = updated?.orchestratorProfile ?? orchestratorProfile
            defaultAssignee = updated?.defaultAssignee ?? defaultAssignee
            seed = Seed(
                autoDecompose: autoDecompose,
                autoPromoteChildren: autoPromoteChildren,
                orchestratorProfile: orchestratorProfile,
                defaultAssignee: defaultAssignee
            )
            notice = "Orchestration settings saved."
        } catch {
            guard store.isCurrentConfiguration(generation) else { return }
            // The store owns the current-generation error presentation too;
            // the inline copy keeps the sheet self-contained.
            errorMessage = error.localizedDescription
        }
    }
}
