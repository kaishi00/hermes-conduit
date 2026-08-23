import SwiftUI

/// V3B filter sheet: assignee + tenant (client-side over the loaded board),
/// Show Archived (server fetch parameter), Group Running by Profile (persisted
/// preference). Search stays in the header; the active-filter dot lives on the
/// filter button next to it.
struct KanbanBoardFilterSheet: View {
    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss

    @Binding var includeArchived: Bool
    @Binding var assigneeFilter: String?
    @Binding var tenantFilter: String?
    @Binding var groupRunningByProfile: Bool

    private var assignees: [String] { store.board?.assignees ?? [] }
    private var tenants: [String] { store.board?.tenants ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section("Assignee") {
                    Picker("Assignee", selection: assigneeBinding) {
                        Text("All Profiles").tag(String?.none)
                        ForEach(assignees, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .pickerStyle(.menu)
                }
                if !tenants.isEmpty {
                    Section("Tenant") {
                        Picker("Tenant", selection: tenantBinding) {
                            Text("All Tenants").tag(String?.none)
                            ForEach(tenants, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                Section {
                    Toggle("Show Archived", isOn: $includeArchived)
                        .accessibilityLabel("Show archived tasks")
                    Toggle("Group Running by Profile", isOn: $groupRunningByProfile)
                        .accessibilityLabel("Group the Running lane by assignee")
                } footer: {
                    Text("Group Running by Profile is a saved preference. Show Archived applies to the board fetch. Assignee and tenant filters are temporary until changed.")
                }
                Section {
                    Button("Reset Filters") {
                        // Transient filters only: the persisted grouping
                        // preference is NOT part of a transient reset.
                        assigneeFilter = nil
                        tenantFilter = nil
                        includeArchived = false
                    }
                }
            }
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
