import SwiftUI

/// Settings > Capabilities, as Hermes Desktop's: Skills, Tools, Connectors
/// and Plugins, each its own tab. Scoped to the active Hermes profile. Skills
/// and toolsets still load through AppState (the Board's skill picker reads
/// them too); connectors, plugins and the catalogs live in `CapabilitiesStore`.
struct CapabilitiesView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState
    @StateObject private var store = CapabilitiesStore()
    @AppStorage("capabilities.tab") private var tabRaw = CapabilitiesTab.skills.rawValue
    @State private var searchText = ""
    @State private var capabilitiesLoading = false
    @State private var loadError: String?
    /// Token of the most recent request. An older completion can never clear
    /// the loading flag or set the error of a newer one.
    @State private var capabilityRequestID = UUID()
    /// The profile and dashboard the store was last pointed at. The tabs show
    /// only once it matches, so their first load never runs against the
    /// store's previous (or empty) scope.
    @State private var configuredScope: Scope?

    private struct Scope: Hashable {
        let profile: String
        let dashboard: ObjectIdentifier?
    }

    private var scope: Scope {
        Scope(
            profile: appState.activeProfile,
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
            tabPicker
                .modifier(V2LegacyScrollEdge())
        }
        .searchable(text: $searchText, prompt: searchPrompt)
        // The other settings pages' backdrop and small title.
        .background { SettingsBackdrop() }
        .navigationTitle("Capabilities")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: scope) {
            let scope = self.scope
            store.configure(requester: appState.dashboardTicketBridge, profile: scope.profile)
            configuredScope = scope
            await loadCapabilities()
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
                snapshotProfile: appState.capabilitiesProfile,
                activeProfile: appState.activeProfile
            )
            switch CapabilityLoadPolicy.resolvePresentation(
                snapshotProfile: appState.capabilitiesProfile,
                activeProfile: appState.activeProfile,
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
