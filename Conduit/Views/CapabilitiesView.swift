import SwiftUI

/// Settings > Capabilities, as Hermes Desktop's: Skills, Tools, Connectors
/// and Plugins, each its own tab. Scoped to the active Hermes profile. Skills
/// and toolsets still load through AppState (the Board's skill picker reads
/// them too); connectors, plugins and the catalogs live in `CapabilitiesStore`.
/// Every tab opens on what it showed last time, kept on the phone, while it
/// asks Hermes again (#1533).
struct CapabilitiesView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState
    @State private var store = CapabilitiesStore()
    @AppStorage("capabilities.tab") private var tabRaw = CapabilitiesTab.skills.rawValue
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    /// The scope whose unvisited tabs a search has already loaded.
    @State private var searchLoadedScope: Scope?
    @State private var countsMemo = CapabilityListMemo<CountsInput, [CapabilitiesTab: Int]>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var capabilitiesLoading = false
    @State private var loadError: String?
    /// Token of the most recent request. An older completion can never clear
    /// the loading flag or set the error of a newer one.
    @State private var capabilityRequestID = UUID()
    /// The profile and dashboard the store was last pointed at. The tabs show
    /// only once it matches, so their first load never runs against the
    /// store's previous (or empty) scope. It's pointed before the first
    /// frame, and on a switch before the next one, so the kept lists show
    /// with no loader first.
    @State private var configuredScope: Scope?

    private struct Scope: Hashable {
        let profile: String
        /// The dashboard open, so a switch made offline, with no bridge
        /// either side, points the store at the new one's kept lists.
        let dashboardID: UUID?
        let dashboard: ObjectIdentifier?
    }

    private var scope: Scope {
        Scope(
            profile: appState.activeProfile,
            dashboardID: appState.activeDashboardID,
            dashboard: appState.dashboardTicketBridge.map { ObjectIdentifier($0) }
        )
    }

    private var tab: CapabilitiesTab {
        CapabilitiesTab(rawValue: tabRaw) ?? .skills
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if configuredScope == scope {
                tabContent
                    .id(scope)
            } else {
                loadingView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .v2EdgeBar(.top) {
            VStack(spacing: 0) {
                searchField
                tabPicker
                otherTabMatches
            }
        }
        // The other settings pages' backdrop and small title.
        .background { SettingsBackdrop() }
        .navigationTitle("Capabilities")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear(perform: configure)
        .onChange(of: scope) { _, _ in configure() }
        .task(id: scope) {
            configure()
            await loadCapabilities()
        }
        .task(id: SearchLoad(scope: configuredScope, searching: !query.isEmpty)) {
            await loadForSearch()
        }
    }

    /// Points the store at the active dashboard and profile, and shows
    /// what the tabs showed last time there.
    private func configure() {
        let scope = self.scope
        guard configuredScope != scope else { return }
        store.configure(
            requester: appState.dashboardTicketBridge,
            profile: scope.profile,
            answers: appState.screenAnswers(profile: scope.profile),
            dashboardAnswers: appState.screenAnswers(profile: AppState.KeptRoute.everyProfile)
        )
        appState.showKeptCapabilities()
        configuredScope = scope
    }

    // MARK: Search

    private struct SearchLoad: Hashable {
        let scope: Scope?
        let searching: Bool
    }

    private struct CountsInput: Equatable {
        let query: String
        let sources: CapabilitySearchCounts.Sources
    }

    /// Always on screen, rather than `.searchable`'s field that hides until
    /// the list is pulled down. One search for all four tabs: switching tabs
    /// keeps it.
    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(searchPrompt, text: $searchText)
                    .textFieldStyle(.plain)
                    .scaledFont(.subheadline)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
                    .accessibilityIdentifier("capabilities.search")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLocalization.string("Clear search"))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(minHeight: 40)
            .conduitGlassSurface(cornerRadius: 20)
            if searchFocused {
                Button(AppLocalization.string("Cancel")) {
                    searchText = ""
                    searchFocused = false
                }
                .scaledFont(.subheadline.weight(.medium))
                .foregroundStyle(Color.conduitAccent)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: searchFocused)
        .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    /// What the search finds on the other tabs, each a button to go there.
    @ViewBuilder
    private var otherTabMatches: some View {
        // Kept until the query or what it searches changes: this bar
        // re-renders on every AppState and store publish.
        let counts = countsMemo.value(for: CountsInput(query: query, sources: searchSources)) {
            CapabilitySearchCounts.counts(query: $0.query, in: $0.sources)
        }
        let others = CapabilitiesTab.allCases.filter { $0 != tab && (counts[$0] ?? 0) > 0 }
        if !others.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text(verbatim: AppLocalization.string("Also in"))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(others) { other in
                        Button {
                            tabRaw = other.rawValue
                        } label: {
                            Text(verbatim: "\(other.title) \((counts[other] ?? 0).formatted())")
                                .scaledFont(.footnote.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.conduitAccent.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.conduitAccent)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel(Text(verbatim: AppLocalization.string("Show matches in \(other.title)")))
                        .accessibilityValue(Text(verbatim: (counts[other] ?? 0).formatted()))
                    }
                }
                .padding(.horizontal, 16)
            }
            .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
            .padding(.bottom, 8)
        }
    }

    private var searchSources: CapabilitySearchCounts.Sources {
        guard !query.isEmpty else { return CapabilitySearchCounts.Sources() }
        // Skills and tools only once they're this profile's.
        let ownRows = CapabilityLoadPolicy.shouldPresentRows(
            snapshot: appState.capabilitiesOwner,
            active: appState.currentCapabilitiesOwner
        )
        return CapabilitySearchCounts.Sources(
            skills: ownRows ? appState.skills : [],
            officialSkills: store.officialSkills,
            toolsets: ownRows ? appState.toolsets : [],
            servers: store.servers,
            connectorCatalog: store.connectorCatalog,
            plugins: store.plugins,
            pluginCatalog: store.pluginCatalog
        )
    }

    /// A search reads the tabs not opened yet, once per profile, so their
    /// finds can show.
    private func loadForSearch() async {
        guard !query.isEmpty, let scope = configuredScope, scope == self.scope,
              searchLoadedScope != scope else { return }
        let store = self.store
        await withTaskGroup(of: Void.self) { group in
            if store.officialSkills.isEmpty || store.showsKept.contains(.officialSkills) {
                group.addTask { await store.loadOfficialSkills() }
            }
            if !store.connectorsLoaded || store.connectorsError != nil { group.addTask { _ = await store.loadConnectors() } }
            if !store.pluginsLoaded || store.pluginsError != nil { group.addTask { await store.loadPlugins() } }
        }
        // Only a full read counts: one cleared mid-read or failed, or a
        // kept list Hermes hasn't answered, is tried again on the next search.
        if !Task.isCancelled, configuredScope == scope, !store.officialSkills.isEmpty,
           !store.showsKept.contains(.officialSkills),
           store.connectorsLoaded, store.connectorsError == nil,
           store.pluginsLoaded, store.pluginsError == nil {
            searchLoadedScope = scope
        }
    }

    private var tabPicker: some View {
        Picker(AppLocalization.string("Capabilities"), selection: $tabRaw) {
            ForEach(CapabilitiesTab.allCases) { tab in
                Text(verbatim: tab.title).tag(tab.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .onChange(of: tabRaw) { _, _ in Haptics.selection() }
    }

    private var searchPrompt: String {
        switch tab {
        case .skills: return AppLocalization.string("Search skills")
        case .tools: return AppLocalization.string("Search tools")
        case .connectors: return AppLocalization.string("Search connectors")
        case .plugins: return AppLocalization.string("Search plugins")
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .skills, .tools:
            // Single authoritative rendering boundary: foreign snapshots can
            // never reach a row-bearing state, so stale toggles can never fire
            // mutations against the wrong profile. A refresh of rows this
            // profile already shows keeps them on screen.
            let hasRows = !appState.skills.isEmpty || !appState.toolsets.isEmpty
            let showsOwnRows = hasRows && CapabilityLoadPolicy.shouldPresentRows(
                snapshot: appState.capabilitiesOwner,
                active: appState.currentCapabilitiesOwner
            )
            switch CapabilityLoadPolicy.resolvePresentation(
                snapshot: appState.capabilitiesOwner,
                active: appState.currentCapabilitiesOwner,
                isLoading: capabilitiesLoading && !showsOwnRows,
                loadError: loadError,
                hasRows: hasRows
            ) {
            case .loading:
                loadingView
            case .failure(let message):
                CapabilityTabScroll(refresh: loadCapabilities) {
                    CapabilityEmptyState(
                        title: AppLocalization.string("Couldn't Load"),
                        symbol: "exclamationmark.triangle",
                        message: message
                    ) {
                        Task { await loadCapabilities() }
                    }
                }
            case .emptySuccess:
                // A profile with nothing installed still has the catalog.
                skillsOrTools
            case .list(let banner):
                skillsOrTools
                    .overlay(alignment: .top) {
                        if let banner {
                            CapabilityRefreshBanner(message: banner)
                                .padding(.horizontal, 16)
                                .padding(.top, 6)
                        }
                    }
            }
        case .connectors:
            CapabilityConnectorsTab(store: store, query: query)
        case .plugins:
            CapabilityPluginsTab(store: store, query: query)
        }
    }

    @ViewBuilder
    private var skillsOrTools: some View {
        if tab == .skills {
            CapabilitySkillsTab(store: store, query: query, refresh: loadCapabilities)
        } else {
            CapabilityToolsTab(store: store, query: query, refresh: loadCapabilities)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 0) {
            Spacer()
            ProgressView("Loading capabilities…")
                .tint(.conduitAccent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
        let requested = appState.currentCapabilitiesOwner
        let outcome = await appState.loadCapabilities()

        guard capabilityRequestID == myToken else { return }
        capabilitiesLoading = false
        guard appState.currentCapabilitiesOwner == requested, !outcome.isSuperseded else { return }

        loadError = Self.localError(
            for: outcome,
            hasData: CapabilityLoadPolicy.shouldPresentRows(
                snapshot: appState.capabilitiesOwner,
                active: requested
            ) && (!appState.skills.isEmpty || !appState.toolsets.isEmpty)
        )
    }

    /// Pure mapping from a request outcome to this screen's local failure
    /// presentation. Loaded data always stays visible; a failed refresh with a
    /// populated cache surfaces through the banner instead of wiping content.
    static func localError(for outcome: AppState.CapabilityLoadOutcome, hasData: Bool) -> String? {
        switch outcome {
        case .success:
            return hasData ? nil : AppLocalization.string("No capabilities found.")
        case .failed(_, let message):
            return message
        case .unavailable:
            return AppLocalization.string("Connect to a Hermes dashboard to load capabilities.")
        case .superseded:
            return nil
        }
    }
}
