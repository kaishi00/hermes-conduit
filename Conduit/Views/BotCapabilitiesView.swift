import SwiftUI

/// The bot editor's Skills, Tools and MCP page: toggles over the profile's
/// `profiles.describe` lists (upstream `profile-config.tsx`). A new bot's
/// lists come from its Start From profile, since its own doesn't exist yet.
struct BotCapabilitiesView: View {
    @Binding var capabilities: BotCapabilities
    /// New Bot's Skip Bundled Skills: there are no skills to toggle.
    let skillsSkipped: Bool
    /// The profile the lists were read from, for New Bot's footer.
    let sourceLabel: String?
    /// New Bot starting fresh: the lists are the main profile's, though
    /// the bot gets Hermes' bundled skills (as on Desktop).
    var freshProfile = false

    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var skillFilter = ""

    var body: some View {
        List {
            Section {
                if skillsSkipped {
                    Text(AppLocalization.string("Skip Bundled Skills is on, so this bot starts with no skills."))
                        .foregroundStyle(.secondary)
                } else if capabilities.skills.isEmpty {
                    Text(AppLocalization.string("No skills installed."))
                        .foregroundStyle(.secondary)
                } else {
                    TextField(AppLocalization.string("Filter skills"), text: $skillFilter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    // Keyed by name: a filter change must not hand one
                    // skill's row to another.
                    ForEach(visibleSkillNames, id: \.self) { name in
                        if let index = capabilities.skills.firstIndex(where: { $0.name == name }) {
                            toggle($capabilities.skills[index])
                        }
                    }
                }
            } header: {
                Text(AppLocalization.string("Skills"))
            } footer: {
                if freshProfile {
                    Text(AppLocalization.string("A fresh profile gets Hermes' bundled skills. These lists show the main profile's."))
                } else if let sourceLabel, !skillsSkipped {
                    Text(AppLocalization.string("Starts from what \(sourceLabel) has installed."))
                }
            }
            Section {
                if capabilities.toolsets.isEmpty {
                    Text(AppLocalization.string("No tools to choose from."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(capabilities.toolsets.indices, id: \.self) { index in
                        toggle($capabilities.toolsets[index])
                            // Hermes reads no tools as its default tools, so
                            // the last one on stays on.
                            .disabled(!capabilities.canTurnOffToolset(at: index))
                    }
                }
            } header: {
                Text(AppLocalization.string("Tools"))
            } footer: {
                Text(verbatim: AppLocalization.string("With every tool on, the bot follows Hermes' default tools.")
                    + " " + AppLocalization.string("At least one tool stays on."))
            }
            Section {
                if capabilities.mcpServers.isEmpty {
                    Text(AppLocalization.string("No MCP servers set up."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(capabilities.mcpServers.indices, id: \.self) { index in
                        toggle($capabilities.mcpServers[index])
                    }
                }
            } header: {
                Text(verbatim: "MCP")
            } footer: {
                Text(AppLocalization.string("Add new MCP servers from Hermes on your computer."))
            }
        }
        .navigationTitle(AppLocalization.string("Skills, Tools and MCP"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var visibleSkillNames: [String] {
        let query = skillFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = capabilities.skills.map(\.name)
        guard !query.isEmpty else { return names }
        return names.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func toggle(_ item: Binding<BotCapability>) -> some View {
        Toggle(isOn: item.enabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.wrappedValue.label ?? item.wrappedValue.name)
                if !item.wrappedValue.description.isEmpty {
                    Text(verbatim: item.wrappedValue.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}
