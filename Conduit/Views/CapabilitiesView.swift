import SwiftUI

/// Settings-owned capabilities browser. It remains scoped to the active Hermes
/// profile and intentionally reuses AppState's existing loading/mutation APIs.
struct CapabilitiesView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var capabilitiesLoading = false
    @State private var loadError: String?
    /// Token of the most recent request. An older completion can never clear
    /// the loading flag or set the error of a newer one.
    @State private var capabilityRequestID = UUID()

    var body: some View {
        // Single authoritative rendering boundary: foreign snapshots can never
        // reach a row-bearing state, so stale toggles can never fire mutations
        // against the wrong profile.
        Group {
            switch CapabilityLoadPolicy.resolvePresentation(
                snapshotProfile: appState.capabilitiesProfile,
                activeProfile: appState.activeProfile,
                isLoading: capabilitiesLoading,
                loadError: loadError,
                hasRows: !appState.skills.isEmpty || !appState.toolsets.isEmpty
            ) {
        case .loading:
            VStack(spacing: 0) {
                Spacer()
                ProgressView("Loading capabilities…")
                    .tint(.conduitAccent)
                Spacer()
            }
        case .failure(let message):
            VStack(spacing: 0) {
                ContentUnavailableView(
                    "Couldn't Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .refreshable { await loadCapabilities() }
        case .emptySuccess:
            VStack(spacing: 0) {
                ContentUnavailableView(
                    "No capabilities found",
                    systemImage: "tray",
                    description: Text("This profile has no enabled skills or toolsets.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .refreshable { await loadCapabilities() }
        case .list(let banner):
            List {
                skillsSection
                toolsetsSection
            }
            .searchable(text: $searchText, prompt: "Search skills")
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .refreshable { await loadCapabilities() }
            .overlay(alignment: .top) {
                if let banner {
                    Text("Refresh failed: \(banner)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 6)
                }
            }
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
        // Request token: an older completion must never clear the newer
        // request's loading flag or overwrite its error state (rapid A->B or
        // A->B->A switching).
        let myToken = UUID()
        capabilityRequestID = myToken
        capabilitiesLoading = true
        // A genuinely newer request starts with clean local error state; the
        // token guard below keeps any older completion from re-setting it.
        loadError = nil
        let requestedProfile = appState.activeProfile
        let outcome = await appState.loadCapabilities()

        guard capabilityRequestID == myToken else { return }
        capabilitiesLoading = false
        guard appState.activeProfile == requestedProfile, !outcome.isSuperseded else { return }

        loadError = Self.localError(
            for: outcome,
            hasData: CapabilityLoadPolicy.shouldPresentRows(
                snapshotProfile: appState.capabilitiesProfile,
                activeProfile: requestedProfile
            ) && (!appState.skills.isEmpty || !appState.toolsets.isEmpty)
        )
    }

    /// Pure mapping from a request outcome to this screen's local failure
    /// presentation. Loaded data always stays visible; a failed refresh with a
    /// populated cache surfaces through the banner instead of wiping content.
    static func localError(for outcome: AppState.CapabilityLoadOutcome, hasData: Bool) -> String? {
        switch outcome {
        case .success:
            return hasData ? nil : "No capabilities found."
        case .failed(_, let message):
            return message
        case .unavailable:
            return "Connect to a Hermes dashboard to load capabilities."
        case .superseded:
            return nil
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
