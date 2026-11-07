import SwiftUI

/// V3B filter sheet: assignee + tenant (client-side over the loaded board),
/// Show Archived (server fetch parameter), Group Running by Profile (persisted
/// preference). Search stays in the header; the active-filter dot lives on the
/// filter button next to it.
struct KanbanBoardFilterSheet: View {
    @Environment(KanbanStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @Binding var includeArchived: Bool
    @Binding var assigneeFilter: String?
    @Binding var tenantFilter: String?
    @Binding var groupRunningByProfile: Bool

    private var assignees: [String] { store.board?.assignees ?? [] }
    private var tenants: [String] { store.board?.tenants ?? [] }

    var body: some View {
        NavigationStack {
            SettingsDetailContainer {
                ConduitSettingsSection(title: AppLocalization.string("Assignee"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
                    ConduitMenuPicker(
                        value: assigneeBinding.wrappedValue,
                        choices: [(id: String?.none, title: AppLocalization.string("All Profiles"))]
                            + assignees.map { (id: String?.some($0), title: $0) },
                        onSelect: { assigneeBinding.wrappedValue = $0 }
                    ) {
                        Text("Assignee").foregroundStyle(.secondary)
                    }
                }
                if !tenants.isEmpty {
                    ConduitSettingsSection(title: AppLocalization.string("Tenant"), symbol: "person.2", tint: .conduitAccent) {
                        ConduitMenuPicker(
                            value: tenantBinding.wrappedValue,
                            choices: [(id: String?.none, title: AppLocalization.string("All Tenants"))]
                                + tenants.map { (id: String?.some($0), title: $0) },
                            onSelect: { tenantBinding.wrappedValue = $0 }
                        ) {
                            Text("Tenant").foregroundStyle(.secondary)
                        }
                    }
                }
                SettingsCard {
                    Toggle("Show Archived", isOn: $includeArchived)
                        .accessibilityLabel("Show archived tasks")
                    Toggle("Group Running by Profile", isOn: $groupRunningByProfile)
                        .accessibilityLabel("Group the Running lane by assignee")
                    Text("Group Running by Profile is a saved preference. Show Archived applies to the board fetch. Assignee and tenant filters are temporary until changed.")
                        .settingsCaption()
                }
                SettingsCard {
                    Button("Reset Filters") {
                        // Transient filters only: the persisted grouping
                        // preference is NOT part of a transient reset.
                        assigneeFilter = nil
                        tenantFilter = nil
                        includeArchived = false
                    }
                }
            }
            // Text fields as Settings draws them.
            .textFieldStyle(.roundedBorder)
            .tint(.conduitAccent)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var assigneeBinding: Binding<String?> {
        Binding(
            get: { assigneeFilter },
            set: { assigneeFilter = $0 }
        )
    }

    private var tenantBinding: Binding<String?> {
        Binding(
            get: { tenantFilter },
            set: { tenantFilter = $0 }
        )
    }
}
