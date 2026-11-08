//
//  SkillHubViews.swift
//  Conduit
//
//  Settings > Capabilities > Skills > Browse Skill Hub: Hermes' skill hub,
//  as Hermes Desktop's skill catalog browses it. The Hermes Index's
//  featured skills, a search across every source Hermes has (skills.sh,
//  GitHub, ClawHub and the rest) or one of them, and a skill's page with
//  Hermes' security scan of it, its SKILL.md and Install.
//

import SwiftUI

enum SkillHubStyle {
    /// How far Hermes trusts a skill's source.
    static func trustPill(_ trust: String) -> CapabilityPillModel {
        switch trust {
        case "builtin": return CapabilityPillModel(text: AppLocalization.string("Official"), tint: .conduitAura)
        case "trusted": return CapabilityPillModel(text: AppLocalization.string("Trusted"), tint: .green)
        default: return CapabilityPillModel(text: AppLocalization.string("Community"))
        }
    }

    /// A source's name as Hermes labels it.
    static func sourceLabel(_ source: String, in hub: SkillHubSnapshot?) -> String {
        hub?.sources.first { $0.id == source }?.label ?? source
    }

    static func severityTint(_ severity: String) -> Color {
        switch severity {
        case "critical", "high": return .red
        case "medium": return .orange
        default: return .secondary
        }
    }

    static func severityLabel(_ severity: String) -> String {
        switch severity {
        case "critical": return AppLocalization.string("Critical")
        case "high": return AppLocalization.string("High")
        case "medium": return AppLocalization.string("Medium")
        default: return AppLocalization.string("Low")
        }
    }
}

/// The Skills tab's way into the hub.
struct SkillHubEntryRow: View {
    let store: CapabilitiesStore
    let reload: () async -> Void

    var body: some View {
        NavigationLink {
            SkillHubBrowsePage(store: store, reload: reload)
                .v2TabBarClearance()
        } label: {
            CapabilityRowLabel(
                symbol: "bag",
                title: AppLocalization.string("Browse Skill Hub"),
                detail: AppLocalization.string("Search skills.sh, GitHub, ClawHub and the other sources Hermes has."),
                chevron: true
            )
        }
        .buttonStyle(.plain)
    }
}

struct SkillHubBrowsePage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let store: CapabilitiesStore
    let reload: () async -> Void
    @State private var query = ""
    /// Nil searches every source.
    @State private var source: String?
    @State private var results: SkillHubResults?
    @State private var searching = false
    @State private var searchError: String?

    private struct SearchKey: Equatable {
        let query: String
        let source: String?
        let owner: CapabilitySnapshotOwner?
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var installed: [String: String] { store.hubInstalled }

    var body: some View {
        CapabilityTabScroll(refresh: { await store.loadSkillHub() }) {
            sourcePicker
            if trimmedQuery.isEmpty {
                featured
            } else {
                searchResults
            }
        }
        .navigationTitle(Text("Skill Hub"))
        .searchable(text: $query, prompt: Text("Search skills"))
        .task(id: store.profile) {
            if store.skillHub == nil || store.showsKept.contains(.skillHub) { await store.loadSkillHub() }
        }
        // Asks once typing pauses, and again for another source.
        .task(id: SearchKey(query: trimmedQuery, source: source, owner: appState.currentCapabilitiesOwner)) {
            await search()
        }
    }

    @ViewBuilder
    private var sourcePicker: some View {
        let sources = store.skillHub?.searchableSources ?? []
        if sources.count > 1 {
            Menu {
                Picker(selection: $source) {
                    Text("All Sources").tag(String?.none)
                    ForEach(sources) { source in
                        Text(verbatim: source.label).tag(String?.some(source.id))
                    }
                } label: {
                    Text("Source")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .accessibilityHidden(true)
                    Text(verbatim: source.map { SkillHubStyle.sourceLabel($0, in: store.skillHub) } ?? AppLocalization.string("All Sources"))
                        .scaledFont(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .scaledFont(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.conduitAccent)
                .padding(.horizontal, 4)
            }
            .accessibilityLabel(Text("Source"))
        }
    }

    @ViewBuilder
    private var featured: some View {
        if let hub = store.skillHub {
            if !hub.featured.isEmpty {
                CapabilitySection(
                    title: AppLocalization.string("Featured"),
                    symbol: "star",
                    tint: .conduitAura,
                    footer: AppLocalization.string("Popular skills from the Hermes Index. Hermes scans each skill before it installs.")
                ) {
                    rows(hub.featured, hub: hub)
                }
            } else {
                CapabilityEmptyState(
                    title: AppLocalization.string("Search the skill hub"),
                    symbol: "magnifyingglass",
                    message: AppLocalization.string("Type what a skill should do. Hermes searches \(hub.searchableSources.map(\.label).formatted(.list(type: .and))).")
                )
            }
            if let error = store.skillHubError {
                CapabilityRefreshBanner(message: error)
            }
        } else if store.skillHubMissing {
            CapabilityEmptyState(
                title: AppLocalization.string("No skill hub on this Hermes"),
                symbol: "bag",
                message: AppLocalization.string("Update Hermes to browse and install skills from the hub.")
            )
        } else if let error = store.skillHubError {
            CapabilityEmptyState(
                title: AppLocalization.string("Couldn't reach the skill hub"),
                symbol: "exclamationmark.triangle",
                message: error,
                retry: { Task { await store.loadSkillHub() } }
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if let results {
            if results.results.isEmpty {
                CapabilityEmptyState(
                    title: AppLocalization.string("No matching skills"),
                    symbol: "magnifyingglass",
                    message: [AppLocalization.string("Nothing matches “\(trimmedQuery)”."), timedOutNote(results)]
                        .compactMap { $0 }
                        .joined(separator: " ")
                )
            } else {
                CapabilitySection(
                    title: AppLocalization.string("Results"),
                    symbol: "magnifyingglass",
                    footer: timedOutNote(results)
                ) {
                    rows(results.results, hub: store.skillHub)
                }
            }
        } else if let searchError {
            CapabilityEmptyState(
                title: AppLocalization.string("The search didn't finish"),
                symbol: "exclamationmark.triangle",
                message: searchError,
                retry: { Task { await search(now: true) } }
            )
        }
        if searching {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
    }

    private func rows(_ skills: [HubSkill], hub: SkillHubSnapshot?) -> some View {
        ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
            CapabilityCardRow(divided: index > 0) {
                HubSkillRow(skill: skill, hub: hub, installed: installed[skill.identifier] != nil, store: store, reload: reload)
            }
        }
    }

    private func timedOutNote(_ results: SkillHubResults) -> String? {
        guard !results.timedOut.isEmpty else { return nil }
        let names = results.timedOut.map { SkillHubStyle.sourceLabel($0, in: store.skillHub) }
        return AppLocalization.string("\(names.formatted(.list(type: .and))) didn't answer in time.")
    }

    private func search(now: Bool = false) async {
        let text = trimmedQuery
        guard !text.isEmpty else {
            results = nil
            searchError = nil
            searching = false
            return
        }
        // Another search's results never stand in for this one's.
        results = nil
        searchError = nil
        if !now {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
        }
        let owner = appState.currentCapabilitiesOwner
        guard store.serves(owner) else { return }
        searching = true
        defer { if text == trimmedQuery { searching = false } }
        do {
            let answer = try await store.searchSkillHub(text, source: source)
            guard !Task.isCancelled, text == trimmedQuery, appState.currentCapabilitiesOwner == owner else { return }
            results = answer
            searchError = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), text == trimmedQuery else { return }
            results = nil
            searchError = UserFacingError.message(for: error)
        }
    }
}

private struct HubSkillRow: View {
    let skill: HubSkill
    let hub: SkillHubSnapshot?
    let installed: Bool
    let store: CapabilitiesStore
    let reload: () async -> Void

    private var pills: [CapabilityPillModel] {
        var pills = [SkillHubStyle.trustPill(skill.trustLevel)]
        if installed { pills.append(CapabilityPillModel(text: AppLocalization.string("Installed"), tint: .green)) }
        return pills
    }

    var body: some View {
        NavigationLink {
            HubSkillDetailPage(skill: skill, store: store, reload: reload)
                .v2TabBarClearance()
        } label: {
            CapabilityRowLabel(
                symbol: installed ? "checkmark.circle" : "arrow.down.circle",
                active: installed,
                title: skill.name,
                subtitle: skill.source.isEmpty ? nil : SkillHubStyle.sourceLabel(skill.source, in: hub),
                pills: pills,
                detail: skill.description,
                chevron: true
            )
        }
        .buttonStyle(.plain)
    }
}

/// A hub skill's page: what it is and where it's from, Hermes' scan of it,
/// Install, and its SKILL.md.
struct HubSkillDetailPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    let skill: HubSkill
    let store: CapabilitiesStore
    let reload: () async -> Void
    @State private var scan: SkillHubScan?
    @State private var scanError: String?
    @State private var document: SkillFrontmatter?
    @State private var documentError: String?
    /// The dashboard and profile the page was opened for: Install, the scan
    /// and the SKILL.md belong to them.
    @State private var openedFor: CapabilitySnapshotOwner?

    private var isCurrent: Bool {
        guard let openedFor else { return false }
        return appState.currentCapabilitiesOwner == openedFor && store.serves(openedFor)
    }

    private var state: CapabilityInstallState? { store.skillInstalls[skill.identifier] }
    private var installed: Bool { store.hubInstalled[skill.identifier] != nil }

    var body: some View {
        SettingsDetailContainer {
            CapabilitySkillHeader(
                title: skill.name,
                description: skill.description,
                pills: [
                    skill.source.isEmpty ? nil : CapabilityPillModel(text: SkillHubStyle.sourceLabel(skill.source, in: store.skillHub)),
                    SkillHubStyle.trustPill(skill.trustLevel)
                ].compactMap { $0 },
                usage: nil
            ) {
                if isCurrent { control }
                if let url = skill.repoURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label(AppLocalization.string("View Source"), systemImage: "arrow.up.right.square")
                            .scaledFont(.subheadline)
                    }
                    .tint(.conduitAccent)
                }
            }
            if isCurrent {
                scanSection
                CapabilitySkillDocument(document: document, error: documentError)
            }
        }
        .navigationTitle(Text(verbatim: skill.name))
        .onAppear { if openedFor == nil { openedFor = appState.currentCapabilitiesOwner } }
        .task(id: isCurrent) {
            guard isCurrent else { return }
            async let scanned: Void = runScan()
            async let previewed: Void = loadPreview()
            _ = await (scanned, previewed)
        }
    }

    @ViewBuilder
    private var control: some View {
        if installed {
            Label(AppLocalization.string("Installed"), systemImage: "checkmark.circle.fill")
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            Button {
                install()
            } label: {
                Label(
                    state == .running ? AppLocalization.string("Installing…") : AppLocalization.string("Install"),
                    systemImage: "arrow.down.circle"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
            }
            // Hermes refuses a skill its scan blocks; it waits for the scan.
            .disabled(state == .running || !appState.canChangeCapabilities || scan == nil || scan?.policy == .block)
            .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
            if case .failed(let reason) = state {
                Text(verbatim: reason)
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
            } else if scan == nil, scanError == nil {
                Text("Install waits for Hermes' security scan.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            } else if scanError != nil {
                Text("Hermes couldn't scan this skill, so it can't be installed from here.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Security Scan"), symbol: "checkmark.shield", tint: scanTint) {
            if let scan {
                VStack(alignment: .leading, spacing: 8) {
                    Label(policyTitle(scan.policy), systemImage: policySymbol(scan.policy))
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(scanTint)
                    if let text = scan.policyReason ?? scan.summary {
                        Text(verbatim: text)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(scan.findings) { finding in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                CapabilityPill(text: SkillHubStyle.severityLabel(finding.severity), tint: SkillHubStyle.severityTint(finding.severity))
                                if !finding.category.isEmpty {
                                    Text(verbatim: finding.category)
                                        .scaledFont(.caption.weight(.semibold))
                                }
                            }
                            if !finding.description.isEmpty {
                                Text(verbatim: finding.description)
                                    .scaledFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let location = finding.location {
                                Text(verbatim: location)
                                    .scaledFont(.caption2.monospaced())
                                    .foregroundStyle(.conduitTertiary)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let scanError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: scanError)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                    Button(AppLocalization.string("Try Again")) { Task { await runScan() } }
                        .buttonStyle(.bordered)
                        .tint(.conduitAccent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Hermes is scanning this skill…")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var scanTint: Color {
        switch scan?.policy {
        case .allow: return .green
        case .ask: return .orange
        case .block: return .red
        case nil: return .conduitAura
        }
    }

    private func policyTitle(_ policy: SkillHubScan.Policy) -> String {
        switch policy {
        case .allow: return AppLocalization.string("No problems found")
        case .ask: return AppLocalization.string("Worth a look before you install it")
        case .block: return AppLocalization.string("Hermes won't install this skill")
        }
    }

    private func policySymbol(_ policy: SkillHubScan.Policy) -> String {
        switch policy {
        case .allow: return "checkmark.shield.fill"
        case .ask: return "exclamationmark.shield.fill"
        case .block: return "xmark.shield.fill"
        }
    }

    private func runScan() async {
        let owner = openedFor
        scanError = nil
        do {
            let result = try await store.scanHubSkill(identifier: skill.identifier)
            guard openedFor == owner, isCurrent, !Task.isCancelled else { return }
            scan = result
        } catch {
            guard openedFor == owner, isCurrent, !Task.isCancelled, !(error is CancellationError) else { return }
            scanError = UserFacingError.message(for: error)
        }
    }

    private func loadPreview() async {
        if document == nil { document = store.keptSkillPreview(identifier: skill.identifier).map(SkillFrontmatter.parse) }
        do {
            let content = try await store.skillPreview(identifier: skill.identifier)
            guard isCurrent, !Task.isCancelled else { return }
            document = SkillFrontmatter.parse(content)
            documentError = nil
        } catch {
            guard isCurrent, !Task.isCancelled else { return }
            // A read that fails keeps the SKILL.md shown.
            if document == nil { documentError = UserFacingError.message(for: error) }
        }
    }

    private func install() {
        guard isCurrent, scan != nil, scan?.policy != .block else { return }
        Haptics.selection()
        Task {
            if await store.installSkill(identifier: skill.identifier) {
                Haptics.success()
                await reload()
            }
        }
    }
}
