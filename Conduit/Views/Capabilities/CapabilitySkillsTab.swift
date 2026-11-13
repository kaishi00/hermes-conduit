//
//  CapabilitySkillsTab.swift
//  Conduit
//
//  Settings > Capabilities > Skills, as Hermes Desktop's Skills tab: the
//  profile's skills, most used first, each with its switch and its own
//  page (SKILL.md), under the Skill Hub, then the official catalog's
//  skills to install by category.
//

import SwiftUI

struct CapabilitySkillsTab: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let store: CapabilitiesStore
    let query: String
    let refresh: () async -> Void
    @AppStorage("capabilities.skills.mostUsedFirst") private var mostUsedFirst = true
    @State private var bulkRunning = false
    /// The category the skills to install are filtered to, if one.
    @State private var availableCategory: String?
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
            if installed.isEmpty && available.isEmpty && !store.officialSkillsLoading && !store.officialSkillsFailed {
                CapabilityEmptyState(
                    title: query.isEmpty ? AppLocalization.string("No skills yet", table: .bots) : AppLocalization.string("No matching skills"),
                    symbol: "puzzlepiece.extension",
                    message: query.isEmpty ? nil : AppLocalization.string("Nothing matches “\(query)”.")
                )
            }
            // The hub leads, as Apps does on Connectors: it would
            // otherwise wait below every installed skill.
            if query.isEmpty, !store.skillHubMissing {
                CapabilitySection(
                    title: AppLocalization.string("Skill Hub"),
                    symbol: "bag",
                    tint: .conduitAura
                ) {
                    SkillHubEntryRow(store: store, reload: refresh)
                }
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
                            CapabilitySkillRow(skill: skill, store: store, canChange: appState.canChangeCapabilities) { enabled in
                                Task { await appState.toggleSkill(name: skill.name, enabled: enabled) }
                            }
                        }
                    }
                }
            }
            if let updates = store.hubSkillUpdates {
                HubSkillUpdatesCard(state: updates, updating: store.skillsUpdate == .running, canUpdate: appState.canChangeCapabilities) {
                    updateHubSkills()
                }
            }
            if case .failed(let reason) = store.skillsUpdate {
                Text(verbatim: AppLocalization.string("Updating hub skills failed: \(reason)", table: .bots))
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
            }
            if available.isEmpty, store.officialSkillsLoading || store.officialSkillsFailed {
                CapabilitySection(
                    title: AppLocalization.string("Available to install", table: .bots),
                    symbol: "arrow.down.circle",
                    tint: .conduitAura
                ) {
                    if store.officialSkillsLoading {
                        CapabilityLoadingRow()
                    } else {
                        CapabilityLoadFailedRow { await store.loadOfficialSkills() }
                    }
                }
            }
            if !available.isEmpty {
                // A picked category stays in the menu after a search or an
                // install empties it, as the plugin catalog's does, so the
                // menu and the list always agree.
                let categories = CapabilitySkillOrdering.categories(available, keeping: availableCategory)
                let chosen = availableCategory
                let groups = CapabilitySkillOrdering.grouped(available, category: chosen)
                CapabilitySection(
                    title: AppLocalization.string("Available to install", table: .bots),
                    symbol: "arrow.down.circle",
                    tint: .conduitAura,
                    footer: AppLocalization.string("From Hermes' official skills catalog. Hermes scans each skill before it installs.", table: .bots)
                ) {
                    if categories.count > 1 || chosen != nil {
                        categoryMenu(categories, chosen: chosen)
                    }
                } content: {
                    if groups.isEmpty {
                        Text("No matching skills")
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    }
                    ForEach(groups) { group in
                        if groups.count > 1 {
                            Text(verbatim: CapabilitySkillOrdering.prettyCategory(group.category))
                                .scaledFont(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 12)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(Array(group.skills.enumerated()), id: \.element.id) { index, skill in
                            CapabilityCardRow(divided: index > 0) {
                                OfficialSkillRow(skill: skill, store: store, reload: refresh)
                            }
                        }
                    }
                }
            }
        }
        .task(id: store.profile) {
            if store.officialSkills.isEmpty || store.showsKept.contains(.officialSkills) { await store.loadOfficialSkills() }
        }
    }

    /// The skills to install by category, as the plugin catalog's
    /// Browse All filters by one.
    private func categoryMenu(_ categories: [String], chosen: String?) -> some View {
        let title = chosen.map(CapabilitySkillOrdering.prettyCategory) ?? AppLocalization.string("All Categories")
        return Menu {
            Picker(selection: $availableCategory) {
                Text("All Categories").tag(String?.none)
                ForEach(categories, id: \.self) { category in
                    Text(verbatim: CapabilitySkillOrdering.prettyCategory(category)).tag(String?.some(category))
                }
            } label: {
                Text("Category")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .scaledFont(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .scaledFont(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.conduitAccent)
        }
        .accessibilityLabel(Text("Category"))
        .accessibilityValue(Text(verbatim: title))
    }

    private var optionsMenu: some View {
        Menu {
            Picker(selection: $mostUsedFirst) {
                Text("Most used first").tag(true)
                Text("Least used first").tag(false)
            } label: {
                Text("Sort")
            }
            if appState.skills.contains(where: { $0.provenance == "hub" }) {
                Button {
                    Haptics.selection()
                    Task { await store.checkHubSkillUpdates() }
                } label: {
                    Label(AppLocalization.string("Check for Updates"), systemImage: "arrow.down.circle")
                }
                .disabled(store.hubSkillUpdates == .checking)
                Button {
                    updateHubSkills()
                } label: {
                    Label(AppLocalization.string("Update Hub Skills", table: .bots), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.skillsUpdate == .running || !appState.canChangeCapabilities)
            }
            Divider()
            // They pick their skills from the list shown: a kept one waits
            // for Hermes' answer.
            Group {
                Button {
                    setAll(appState.skills, enabled: true)
                } label: {
                    Label(AppLocalization.string("Turn All On", table: .bots), systemImage: "checkmark.circle")
                }
                Button {
                    setAll(appState.skills, enabled: false)
                } label: {
                    Label(AppLocalization.string("Turn All Off", table: .bots), systemImage: "circle")
                }
                Button {
                    setAll(appState.skills.filter { ($0.usage ?? 0) == 0 }, enabled: false)
                } label: {
                    Label(AppLocalization.string("Turn Off Unused", table: .bots), systemImage: "moon.zzz")
                }
            }
            .disabled(appState.capabilitiesAreKept || !appState.canChangeCapabilities)
        } label: {
            if bulkRunning || store.skillsUpdate == .running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "ellipsis.circle")
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(bulkRunning)
        .accessibilityLabel(Text("Skill options"))
    }

    private func updateHubSkills() {
        Haptics.selection()
        Task {
            if await store.updateHubSkills() {
                Haptics.success()
                await refresh()
            }
        }
    }

    /// One switch at a time, as Hermes takes them; skills already in that
    /// state are left alone. A dashboard or profile switch midway stops it:
    /// the rest were this list's, not the next one's.
    private func setAll(_ skills: [CapabilitySkill], enabled: Bool) {
        let targets = skills.filter { $0.enabled != enabled }.map(\.name)
        guard !bulkRunning, !appState.capabilitiesAreKept, !targets.isEmpty, let rows = appState.capabilitiesOwner else { return }
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

/// Check for Updates' answer under the installed skills: which hub skills
/// have a newer version, with Update Hub Skills, or that every one is
/// current.
private struct HubSkillUpdatesCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let state: HubSkillUpdatesState
    let updating: Bool
    let canUpdate: Bool
    let update: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppLocalization.string("Checking the hub for updates…", table: .bots))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }
            case .found(let updates) where updates.isEmpty:
                Label(AppLocalization.string("Hub skills are up to date.", table: .bots), systemImage: "checkmark.circle")
                    .scaledFont(.footnote).foregroundStyle(.secondary)
            case .found(let updates):
                Text(AppLocalization.string("Updates available: \(updates.map(\.name).joined(separator: ", "))", table: .bots))
                    .scaledFont(.footnote)
                Button {
                    update()
                } label: {
                    if updating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(AppLocalization.string("Update Hub Skills", table: .bots), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.settingsPrimary)
                .disabled(updating || !canUpdate)
            case .failed(let reason):
                Text(verbatim: AppLocalization.string("Couldn't check for updates: \(reason)", table: .bots))
                    .scaledFont(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
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
        case "agent": return CapabilityPillModel(text: AppLocalization.string("Learned", table: .bots), tint: .green)
        case "hub": return CapabilityPillModel(text: AppLocalization.string("Hub", table: .bots))
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
    /// Off with no dashboard to write through (AppState's canChangeCapabilities).
    let canChange: Bool
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
            .disabled(!canChange)
            .tint(.conduitAccent)
        }
    }
}

private struct OfficialSkillRow: View {
    @EnvironmentObject private var appState: AppState
    let skill: OfficialSkill
    let store: CapabilitiesStore
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
                .disabled(!appState.canChangeCapabilities)
                .accessibilityLabel(Text("Install \(skill.name)"))
            }
            if case .failed(let reason) = state {
                Text(verbatim: reason)
                    .scaledFont(.caption)
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
    let store: CapabilitiesStore
    @Environment(\.dismiss) private var dismiss
    @State private var document: SkillFrontmatter?
    @State private var loadError: String?
    @State private var confirmsRemove = false

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
                            .scaledFont(.subheadline.weight(.semibold))
                    }
                    .disabled(!appState.canChangeCapabilities)
                    .tint(.conduitAccent)
                    if skill.provenance == "hub" {
                        removeControl
                    }
                }
            }
            if appState.capabilitiesAreCurrent {
                CapabilitySkillDocument(document: document, error: loadError)
            }
            Text("Changes apply to new sessions.")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        .navigationTitle(Text(verbatim: name))
        // Before the first frame, so the page doesn't open on a spinner.
        .onAppear { if document == nil { showKept() } }
        // Read again for another dashboard or profile.
        .task(id: detailScope) {
            showKept()
            let owner = appState.currentCapabilitiesOwner
            guard store.serves(owner) else { return }
            do {
                let content = try await store.skillContent(name: name)
                guard appState.currentCapabilitiesOwner == owner, store.serves(owner), !Task.isCancelled else { return }
                document = SkillFrontmatter.parse(content)
            } catch {
                guard appState.currentCapabilitiesOwner == owner, store.serves(owner), !Task.isCancelled else { return }
                // A read that fails keeps the SKILL.md shown.
                if document == nil { loadError = UserFacingError.message(for: error) }
            }
        }
    }

    /// A skill from the hub comes off the profile as it went on
    /// (`hermes skills uninstall`).
    @ViewBuilder
    private var removeControl: some View {
        let state = store.skillRemovals[name]
        Button(role: .destructive) {
            confirmsRemove = true
        } label: {
            if state == .running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Removing…")
                }
            } else {
                Label(AppLocalization.string("Remove Skill", table: .bots), systemImage: "trash")
            }
        }
        .scaledFont(.subheadline)
        .disabled(state == .running || !appState.canChangeCapabilities)
        .confirmationDialog(Text("Remove \(name)?"), isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button(AppLocalization.string("Remove Skill", table: .bots), role: .destructive) { remove() }
        } message: {
            Text("This deletes the skill from your host. You can install it again from the Skill Hub.")
        }
        if case .failed(let reason) = state {
            Text(verbatim: reason)
                .scaledFont(.caption)
                .foregroundStyle(.red)
        }
    }

    private func remove() {
        let owner = appState.currentCapabilitiesOwner
        guard store.serves(owner) else { return }
        Haptics.selection()
        Task {
            guard await store.removeHubSkill(name: name) else { return }
            Haptics.success()
            _ = await appState.loadCapabilities()
            if appState.currentCapabilitiesOwner == owner { dismiss() }
        }
    }

    /// The SKILL.md as the page showed it last time on this dashboard and
    /// profile, while Hermes is asked again (#1533).
    private func showKept() {
        loadError = nil
        document = store.serves(appState.currentCapabilitiesOwner)
            ? store.keptSkillContent(name: name).map(SkillFrontmatter.parse)
            : nil
    }
}

/// A catalog skill's page before it's installed: its SKILL.md and Install.
struct OfficialSkillDetailPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let skill: OfficialSkill
    let store: CapabilitiesStore
    let reload: () async -> Void
    @State private var document: SkillFrontmatter?
    @State private var loadError: String?
    /// The dashboard and profile the page was opened for: its installed
    /// state, Install and SKILL.md belong to them, and after a switch the
    /// page shows only the skill's name and description.
    @State private var openedFor: CapabilitySnapshotOwner?
    /// Hermes answered: the SKILL.md shown is its, not the one kept.
    @State private var answered = false

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
                        .scaledFont(.subheadline.weight(.semibold))
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
                            state == .running ? AppLocalization.string("Installing…", table: .bots) : AppLocalization.string("Install"),
                            systemImage: "arrow.down.circle"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .frame(minHeight: 44)
                    }
                    // Off with no dashboard to write through, as the switches are.
                    .disabled(state == .running || !appState.canChangeCapabilities)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
                    if case .failed(let reason) = state {
                        Text(verbatim: reason)
                            .scaledFont(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            if isCurrent {
                CapabilitySkillDocument(document: document, error: loadError)
            }
        }
        .navigationTitle(Text(verbatim: skill.name))
        // Before the first frame, so the page doesn't open on a spinner.
        .onAppear { showKept() }
        // Again on a return to the dashboard and profile it was opened for,
        // in case a switch cut the first read short.
        .task(id: isCurrent) {
            showKept()
            guard isCurrent, !answered else { return }
            do {
                let content = try await store.skillPreview(identifier: skill.identifier)
                guard isCurrent, !Task.isCancelled else { return }
                document = SkillFrontmatter.parse(content)
                loadError = nil
                answered = true
            } catch {
                guard isCurrent, !Task.isCancelled else { return }
                // A read that fails keeps the SKILL.md shown.
                if document == nil { loadError = UserFacingError.message(for: error) }
            }
        }
    }

    /// The SKILL.md as the page showed it last time, while Hermes is asked
    /// again (#1533).
    private func showKept() {
        if openedFor == nil { openedFor = appState.currentCapabilitiesOwner }
        guard isCurrent, document == nil else { return }
        document = store.keptSkillPreview(identifier: skill.identifier).map(SkillFrontmatter.parse)
    }
}

/// A skill page's top card: its name, what it does, its pills, and the
/// control (its switch, or Install).
struct CapabilitySkillHeader<Control: View>: View {
    let title: String
    let description: String?
    let pills: [CapabilityPillModel]
    let usage: Int?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .scaledFont(.title3.weight(.semibold))
            if let description, !description.isEmpty {
                Text(verbatim: description)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No description.")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(pills, id: \.self) { pill in
                    CapabilityPill(text: pill.text, tint: pill.tint)
                }
                if let usage, usage > 0 {
                    Text(verbatim: CapabilityFormat.uses(usage))
                        .scaledFont(.caption.monospacedDigit())
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
struct CapabilitySkillDocument: View {
    let document: SkillFrontmatter?
    let error: String?

    /// The name and description are in the card above.
    private var fields: [SkillFrontmatter.Field] {
        (document?.fields ?? []).filter { $0.key != "name" && $0.key != "description" }
    }

    var body: some View {
        if let error {
            Text(verbatim: error)
                .scaledFont(.footnote)
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
                ConduitSettingsSection(title: AppLocalization.string("Instructions", table: .bots), symbol: "doc.text", tint: .conduitAccent) {
                    Text(verbatim: document.body)
                        .scaledFont(.caption.monospaced())
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
