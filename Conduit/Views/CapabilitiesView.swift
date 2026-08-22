import SwiftUI

/// Settings-owned capabilities browser. It remains scoped to the active Hermes
/// profile and intentionally reuses AppState's existing loading/mutation APIs.
struct CapabilitiesView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var capabilitiesLoading = false
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            if capabilitiesLoading && appState.skills.isEmpty && appState.toolsets.isEmpty {
                Spacer()
                ProgressView("Loading capabilities…")
                    .tint(.conduitAccent)
                Spacer()
            } else if let loadError, appState.skills.isEmpty && appState.toolsets.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    skillsSection
                    toolsetsSection
                }
                .searchable(text: $searchText, prompt: "Search skills")
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                .refreshable { await loadCapabilities() }
            }
        }
        .navigationTitle("Capabilities")
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: appState.activeProfile) { await loadCapabilities() }
    }

    @ViewBuilder
    private var skillsSection: some View {
        if !filteredSkills.isEmpty {
            if hasCategories {
                ForEach(skillsByCategory, id: \.0) { category, skills in
                    Section(category) {
                        ForEach(skills) { skill in
                            CapabilitySkillRow(skill: skill)
                        }
                    }
                }
            } else {
                Section("Skills") {
                    ForEach(filteredSkills) { skill in
                        CapabilitySkillRow(skill: skill)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var toolsetsSection: some View {
        if !filteredToolsets.isEmpty {
            Section("Toolsets") {
                ForEach(filteredToolsets) { toolset in
                    CapabilityToolsetRow(toolset: toolset)
                }
            }
        }
    }

    private var filteredSkills: [CapabilitySkill] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.skills }
        return appState.skills.filter { skill in
            skill.name.localizedCaseInsensitiveContains(query)
                || skill.description?.localizedCaseInsensitiveContains(query) == true
                || skill.category?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var filteredToolsets: [CapabilityToolset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.toolsets }
        return appState.toolsets.filter { toolset in
            toolset.name.localizedCaseInsensitiveContains(query)
                || toolset.label?.localizedCaseInsensitiveContains(query) == true
                || toolset.description?.localizedCaseInsensitiveContains(query) == true
                || toolset.tools?.joined(separator: " ").localizedCaseInsensitiveContains(query) == true
        }
    }

    private var hasCategories: Bool {
        filteredSkills.contains { $0.category?.isEmpty == false }
    }

    private var skillsByCategory: [(String, [CapabilitySkill])] {
        Dictionary(grouping: filteredSkills) { skill in
            let category = skill.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return category.isEmpty ? "Other" : category
        }
        .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private func loadCapabilities() async {
        capabilitiesLoading = true
        defer { capabilitiesLoading = false }
        await appState.loadCapabilities()
        if let error = appState.errorMessage, error.localizedCaseInsensitiveContains("capabil") {
            loadError = error
        } else {
            loadError = nil
        }
    }
}

private struct CapabilitySkillRow: View {
    @EnvironmentObject var appState: AppState
    let skill: CapabilitySkill

    private var provenanceIcon: String? {
        switch skill.provenance {
        case "hub": return "bag"
        case "bundled": return "shippingbox"
        case "agent": return "wrench"
        default: return nil
        }
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { skill.enabled },
            set: { newValue in
                Task { await appState.toggleSkill(name: skill.name, enabled: newValue) }
            }
        )) {
            HStack(spacing: 11) {
                Image(systemName: provenanceIcon ?? "puzzlepiece.extension")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(skill.enabled ? .conduitAccent : .secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        (skill.enabled ? Color.conduitAccent : Color.secondary).opacity(0.13),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if let category = skill.category, !category.isEmpty {
                            Text(category)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.conduitAura.opacity(0.14), in: Capsule())
                        }
                    }
                    if let desc = skill.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .tint(.conduitAccent)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
    }
}

private struct CapabilityToolsetRow: View {
    @EnvironmentObject var appState: AppState
    let toolset: CapabilityToolset

    var body: some View {
        Toggle(isOn: Binding(
            get: { toolset.enabled },
            set: { newValue in
                Task { await appState.toggleToolset(name: toolset.name, enabled: newValue) }
            }
        )) {
            HStack(spacing: 11) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(toolset.enabled ? .conduitAccent : .secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        (toolset.enabled ? Color.conduitAccent : Color.secondary).opacity(0.13),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(toolset.label ?? toolset.name.capitalized)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let desc = toolset.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let tools = toolset.tools, !tools.isEmpty {
                        Text(tools.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
                Image(systemName: toolset.configured == true ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(toolset.configured == true ? .green : .secondary)
            }
        }
        .tint(.conduitAccent)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
    }
}
