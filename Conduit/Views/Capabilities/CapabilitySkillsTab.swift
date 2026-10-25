//
//  CapabilitySkillsTab.swift
//  Conduit
//
//  Settings > Capabilities > Skills, as Hermes Desktop's Skills tab: the
//  profile's skills, most used first, each with its switch and its own
//  page (SKILL.md), then the official catalog's skills to install.
//

import SwiftUI

struct CapabilitySkillsTab: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: CapabilitiesStore
    let query: String
    let refresh: () async -> Void
    @AppStorage("capabilities.skills.mostUsedFirst") private var mostUsedFirst = true
    @State private var bulkRunning = false
    @State private var rowsMemo = CapabilityListMemo<RowsInput, Rows>()

    private struct RowsInput: Equatable {
        let skills: [CapabilitySkill]
        let catalog: [OfficialSkill]
        let query: String
        let mostUsedFirst: Bool
    }

    private struct Rows {
        let installed: [CapabilitySkill]
        let available: [OfficialSkill]
    }

    private var currentRows: Rows {
        rowsMemo.value(for: RowsInput(
            skills: appState.skills,
            catalog: store.officialSkills,
            query: query,
            mostUsedFirst: mostUsedFirst
        )) { input in
            Rows(
                installed: CapabilitySkillOrdering.sorted(
                    input.skills.filter { CapabilitySkillOrdering.matches($0, query: input.query) },
                    mostUsedFirst: input.mostUsedFirst
                ),
                available: CapabilitySkillOrdering.available(
                    input.catalog,
                    installedNames: Set(input.skills.map(\.name)),
                    query: input.query
                )
            )
        }
    }

    var body: some View {
        let rows = currentRows
        let installed = rows.installed
        let available = rows.available
        CapabilityTabScroll(refresh: {
            await refresh()
            await store.loadOfficialSkills()
        }) {
            if installed.isEmpty && available.isEmpty {
                CapabilityEmptyState(
                    title: query.isEmpty ? AppLocalization.string("No skills yet") : AppLocalization.string("No matching skills"),
                    symbol: "puzzlepiece.extension",
                    message: query.isEmpty ? nil : AppLocalization.string("Nothing matches “\(query)”.")
                )
            }
            if !installed.isEmpty {
                CapabilitySection(
                    title: AppLocalization.string("Installed"),
                    symbol: "puzzlepiece.extension",
                    footer: AppLocalization.string("Changes apply to new sessions.")
                ) {
                    optionsMenu
                } content: {
                    ForEach(Array(installed.enumerated()), id: \.element.name) { index, skill in
                        CapabilityCardRow(divided: index > 0) {
                            CapabilitySkillRow(skill: skill, store: store) { enabled in
                                Task { await appState.toggleSkill(name: skill.name, enabled: enabled) }
                            }
                        }
                    }
                }
            }
            if !available.isEmpty {
                CapabilitySection(
                    title: AppLocalization.string("Available to install"),
                    symbol: "arrow.down.circle",
                    tint: .conduitAura,
                    footer: AppLocalization.string("From Hermes' official skills catalog. Hermes scans each skill before it installs.")
                ) {
                    ForEach(Array(available.enumerated()), id: \.element.id) { index, skill in
                        CapabilityCardRow(divided: index > 0) {
                            OfficialSkillRow(skill: skill, store: store, reload: refresh)
                        }
                    }
                }
            }
        }
        .task(id: store.profile) {
            if store.officialSkills.isEmpty { await store.loadOfficialSkills() }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Picker(selection: $mostUsedFirst) {
                Text("Most used first").tag(true)
                Text("Least used first").tag(false)
            } label: {
                Text("Sort")
            }
            Divider()
            Button {
                setAll(appState.skills, enabled: true)
            } label: {
                Label(AppLocalization.string("Turn All On"), systemImage: "checkmark.circle")
            }
            Button {
                setAll(appState.skills, enabled: false)
            } label: {
                Label(AppLocalization.string("Turn All Off"), systemImage: "circle")
            }
            Button {
                setAll(appState.skills.filter { ($0.usage ?? 0) == 0 }, enabled: false)
            } label: {
                Label(AppLocalization.string("Turn Off Unused"), systemImage: "moon.zzz")
            }
        } label: {
            if bulkRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(bulkRunning)
        .accessibilityLabel(Text("Skill options"))
    }

    /// One switch at a time, as Hermes takes them; skills already in that
    /// state are left alone. A dashboard or profile switch midway stops it:
    /// the rest were this list's, not the next one's.
    private func setAll(_ skills: [CapabilitySkill], enabled: Bool) {
        let targets = skills.filter { $0.enabled != enabled }.map(\.name)
        guard !bulkRunning, !targets.isEmpty, let rows = appState.capabilitiesOwner else { return }
        Haptics.selection()
        bulkRunning = true
        Task {
            for name in targets {
                await appState.toggleSkill(name: name, enabled: enabled, rows: rows)
            }
            bulkRunning = false
        }
    }
}

enum CapabilitySkillStyle {
    static func symbol(_ provenance: String?) -> String {
        switch provenance {
        case "hub": return "bag"
        case "bundled": return "shippingbox"
        case "agent": return "sparkles"
        default: return "puzzlepiece.extension"
        }
    }

    /// Learned (written by the agent) and Hub skills say so; built-in ones
    /// carry nothing, as on Desktop.
    static func provenancePill(_ provenance: String?) -> CapabilityPillModel? {
        switch provenance {
        case "agent": return CapabilityPillModel(text: AppLocalization.string("Learned"), tint: .green)
        case "hub": return CapabilityPillModel(text: AppLocalization.string("Hub"))
        default: return nil
        }
    }
}

/// Not an AppState observer: its tab already re-renders it when the skill
/// changes, and hundreds of observing rows each redid their body on every
/// AppState publish.
private struct CapabilitySkillRow: View {
    let skill: CapabilitySkill
    let store: CapabilitiesStore
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink {
                CapabilitySkillDetailPage(name: skill.name, store: store)
                    .v2TabBarClearance()
            } label: {
                CapabilityRowLabel(
                    symbol: CapabilitySkillStyle.symbol(skill.provenance),
                    active: skill.enabled,
                    title: skill.name,
                    subtitle: CapabilitySkillOrdering.prettyCategory(skill.category),
                    pills: [CapabilitySkillStyle.provenancePill(skill.provenance)].compactMap { $0 },
                    detail: skill.description,
                    meta: (skill.usage ?? 0) > 0 ? CapabilityFormat.uses(skill.usage ?? 0) : nil
                )
            }
            .buttonStyle(.plain)
            Toggle(isOn: Binding(
                get: { skill.enabled },
                set: { enabled in setEnabled(enabled) }
            )) {
                Text(verbatim: skill.name)
            }
            .labelsHidden()
            .tint(.conduitAccent)
        }
    }
}

private struct OfficialSkillRow: View {
    let skill: OfficialSkill
    @ObservedObject var store: CapabilitiesStore
    let reload: () async -> Void

    private var state: CapabilityInstallState? { store.skillInstalls[skill.identifier] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                NavigationLink {
                    OfficialSkillDetailPage(skill: skill, store: store, reload: reload)
                        .v2TabBarClearance()
                } label: {
                    CapabilityRowLabel(
                        symbol: "arrow.down.circle",
                        active: false,
                        title: skill.name,
                        subtitle: CapabilitySkillOrdering.prettyCategory(skill.category),
                        detail: skill.description
                    )
                }
                .buttonStyle(.plain)
                CapabilityRowButton(title: AppLocalization.string("Install"), busy: state == .running) {
                    install()
                }
                .accessibilityLabel(Text("Install \(skill.name)"))
            }
            if case .failed(let reason) = state {
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 41)
                    .padding(.bottom, 8)
            }
        }
    }

    private func install() {
        Haptics.selection()
        Task {
            if await store.installSkill(skill) {
                Haptics.success()
                await reload()
            }
        }
    }
}

/// A skill's page: what it is, its switch, and its SKILL.md.
struct CapabilitySkillDetailPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let name: String
    @ObservedObject var store: CapabilitiesStore
    @State private var document: SkillFrontmatter?
    @State private var loadError: String?

    /// Reads again for another dashboard or profile, and once the store
    /// has been pointed at it.
    private var detailScope: CapabilityDetailScope {
        let owner = appState.currentCapabilitiesOwner
        return CapabilityDetailScope(owner: owner, ready: store.serves(owner))
    }

    /// Only while the list is this dashboard's and profile's.
    private var skill: CapabilitySkill? {
        appState.capabilitiesAreCurrent ? appState.skills.first { $0.name == name } : nil
    }

    var body: some View {
        SettingsDetailContainer {
            if let skill {
                CapabilitySkillHeader(
                    title: skill.name,
                    description: skill.description,
                    pills: [
                        CapabilityPillModel(text: CapabilitySkillOrdering.prettyCategory(skill.category)),
                        CapabilitySkillStyle.provenancePill(skill.provenance)
                    ].compactMap { $0 },
                    usage: skill.usage
                ) {
                    Toggle(isOn: Binding(
                        get: { skill.enabled },
                        set: { enabled in Task { await appState.toggleSkill(name: skill.name, enabled: enabled) } }
                    )) {
                        Text("Turned on")
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(.conduitAccent)
                }
            }
            if appState.capabilitiesAreCurrent {
                CapabilitySkillDocument(document: document, error: loadError)
            }
            Text("Changes apply to new sessions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        .navigationTitle(Text(verbatim: name))
        // Read again for another dashboard or profile.
        .task(id: detailScope) {
            let owner = appState.currentCapabilitiesOwner
            document = nil
            loadError = nil
            guard store.serves(owner) else { return }
            do {
                let content = try await store.skillContent(name: name)
                guard appState.currentCapabilitiesOwner == owner, store.serves(owner), !Task.isCancelled else { return }
                document = SkillFrontmatter.parse(content)
            } catch {
                guard appState.currentCapabilitiesOwner == owner, store.serves(owner), !Task.isCancelled else { return }
                loadError = UserFacingError.message(for: error)
            }
        }
    }
}

/// A catalog skill's page before it's installed: its SKILL.md and Install.
struct OfficialSkillDetailPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let skill: OfficialSkill
    @ObservedObject var store: CapabilitiesStore
    let reload: () async -> Void
    @State private var document: SkillFrontmatter?
    @State private var loadError: String?
    /// The dashboard and profile the page was opened for: its installed
    /// state, Install and SKILL.md belong to them, and after a switch the
    /// page shows only the skill's name and description.
    @State private var openedFor: CapabilitySnapshotOwner?

    private var isCurrent: Bool {
        guard let openedFor else { return false }
        return appState.currentCapabilitiesOwner == openedFor && store.serves(openedFor)
    }

    private var state: CapabilityInstallState? { store.skillInstalls[skill.identifier] }
    private var installed: Bool {
        store.officialSkills.first { $0.identifier == skill.identifier }?.installed ?? skill.installed
    }

    var body: some View {
        SettingsDetailContainer {
            CapabilitySkillHeader(
                title: skill.name,
                description: skill.description,
                pills: [
                    CapabilityPillModel(text: CapabilitySkillOrdering.prettyCategory(skill.category)),
                    CapabilityPillModel(text: AppLocalization.string("Official"), tint: .conduitAura)
                ],
                usage: nil
            ) {
                if !isCurrent {
                    EmptyView()
                } else if installed {
                    Label(AppLocalization.string("Installed"), systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Button {
                        Haptics.selection()
                        Task {
                            guard isCurrent else { return }
                            if await store.installSkill(skill) {
                                Haptics.success()
                                await reload()
                            }
                        }
                    } label: {
                        Label(
                            state == .running ? AppLocalization.string("Installing…") : AppLocalization.string("Install"),
                            systemImage: "arrow.down.circle"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .frame(minHeight: 44)
                    }
                    .disabled(state == .running)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
                    if case .failed(let reason) = state {
                        Text(verbatim: reason)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            if isCurrent {
                CapabilitySkillDocument(document: document, error: loadError)
            }
        }
        .navigationTitle(Text(verbatim: skill.name))
        // Again on a return to the dashboard and profile it was opened for,
        // in case a switch cut the first read short.
        .task(id: isCurrent) {
            if openedFor == nil { openedFor = appState.currentCapabilitiesOwner }
            guard isCurrent, document == nil else { return }
            do {
                let content = try await store.skillPreview(identifier: skill.identifier)
                guard isCurrent, !Task.isCancelled else { return }
                document = SkillFrontmatter.parse(content)
                loadError = nil
            } catch {
                guard isCurrent, !Task.isCancelled else { return }
                loadError = UserFacingError.message(for: error)
            }
        }
    }
}

/// A skill page's top card: its name, what it does, its pills, and the
/// control (its switch, or Install).
private struct CapabilitySkillHeader<Control: View>: View {
    let title: String
    let description: String?
    let pills: [CapabilityPillModel]
    let usage: Int?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .font(.title3.weight(.semibold))
            if let description, !description.isEmpty {
                Text(verbatim: description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No description.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(pills, id: \.self) { pill in
                    CapabilityPill(text: pill.text, tint: pill.tint)
                }
                if let usage, usage > 0 {
                    Text(verbatim: CapabilityFormat.uses(usage))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .settingsCard()
    }
}

/// A SKILL.md: its frontmatter as rows, then its body as written.
private struct CapabilitySkillDocument: View {
    let document: SkillFrontmatter?
    let error: String?

    /// The name and description are in the card above.
    private var fields: [SkillFrontmatter.Field] {
        (document?.fields ?? []).filter { $0.key != "name" && $0.key != "description" }
    }

    var body: some View {
        if let error {
            Text(verbatim: error)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        } else if let document {
            if !fields.isEmpty {
                ConduitSettingsSection(title: AppLocalization.string("Details"), symbol: "list.bullet", tint: .conduitAura) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                        SettingsMetricRow(label: field.key, value: field.value, lineLimit: 3)
                    }
                }
            }
            if !document.body.isEmpty {
                ConduitSettingsSection(title: AppLocalization.string("Instructions"), symbol: "doc.text", tint: .conduitAccent) {
                    Text(verbatim: document.body)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
    }
}
