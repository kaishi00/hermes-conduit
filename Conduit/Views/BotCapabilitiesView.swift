import SafariServices
import SwiftUI

/// The bot editor's Skills page: the profile's skills by Hermes' category,
/// each folded under a row that says how many are on, with a search over
/// them all (Eric, 2026-11-11). `profiles.describe` names the skills only;
/// the dashboard's list for the profile adds their categories and
/// descriptions. Without it they're one list, as before.
struct BotSkillsView: View {
    @Binding var capabilities: BotCapabilities
    /// New Bot's Skip Bundled Skills: there are no skills to toggle.
    let skillsSkipped: Bool
    /// The profile the lists were read from, for New Bot's footer.
    let sourceLabel: String?
    /// The profile whose dashboard list gives the categories: the bot's
    /// own, or New Bot's Start From profile.
    let detailsProfile: String?
    /// False while the lists are the ones Hermes gave last time, until it
    /// answers again (#1533): nothing can change then.
    var editable = true

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var query = ""
    /// The dashboard's skills for the profile: kept until it answers, nil
    /// when it never has.
    @State private var details: [CapabilitySkill]?
    @State private var detailsRead = false
    /// The categories unfolded. A search unfolds every one it matches.
    @State private var open: Set<String> = []

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Skills"), symbol: "book", tint: .conduitAccent) {
                if skillsSkipped {
                    Text(AppLocalization.string("Skip Bundled Skills is on, so this bot starts with no skills.", table: .bots))
                        .foregroundStyle(.secondary)
                } else if capabilities.skills.isEmpty {
                    Text(AppLocalization.string("No skills installed.", table: .bots))
                        .foregroundStyle(.secondary)
                } else {
                    TextField(AppLocalization.string("Search skills"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    skillRows
                }
                if let sourceLabel, !skillsSkipped {
                    Text(AppLocalization.string("Starts from what \(sourceLabel) has installed.", table: .bots))
                        .settingsCaption()
                }
            }
        }
        .navigationTitle(AppLocalization.string("Skills"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let detailsProfile, details == nil, !detailsRead, !skillsSkipped else { return }
            details = appState.keptBotSkillDetails(profile: detailsProfile)
        }
        .task {
            guard let detailsProfile, !detailsRead, !skillsSkipped else { return }
            let read = await appState.loadBotSkillDetails(profile: detailsProfile)
            guard !Task.isCancelled else { return }
            // A read that fails keeps the kept categories up.
            if let read { details = read }
            detailsRead = true
        }
    }

    @ViewBuilder
    private var skillRows: some View {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let details {
            let groups = BotSkillGrouping.grouped(capabilities.skills, details: details, query: query)
            if groups.isEmpty {
                Text(AppLocalization.string("No skills match."))
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                if searching {
                    // A search shows every group it matches, open: the
                    // name is a plain label then, not a fold to tap.
                    Text(verbatim: group.title)
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    rows(group.rows)
                } else {
                    SettingsFoldRow(
                        title: group.title,
                        detail: BotCapabilities.onSummary(group.rows),
                        isOn: Binding(
                            get: { open.contains(group.title) },
                            set: { isOpen in
                                if isOpen { open.insert(group.title) } else { open.remove(group.title) }
                            }
                        )
                    )
                    if open.contains(group.title) {
                        rows(group.rows)
                    }
                }
            }
        } else {
            let shown = BotSkillGrouping.matching(capabilities.skills, query: query)
            if shown.isEmpty {
                Text(AppLocalization.string("No skills match."))
                    .foregroundStyle(.secondary)
            }
            rows(shown)
        }
    }

    private func rows(_ rows: [BotCapability]) -> some View {
        BotCapabilityRows(rows: rows, editable: editable, keepsOneOn: false) { name, on in
            guard editable else { return }
            capabilities.setEnabled(\.skills, name: name, on: on)
        }
        .equatable()
    }
}

/// The bot editor's Tools page: the profile's toolsets, as Hermes' `hermes
/// tools` checklist gives them.
struct BotToolsView: View {
    @Binding var capabilities: BotCapabilities
    /// False while the lists are the ones Hermes gave last time.
    var editable = true

    @ObservedObject private var appLanguage = AppLanguageStore.shared

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Tools"), symbol: "wrench.and.screwdriver", tint: .blue) {
                if capabilities.toolsets.isEmpty {
                    Text(AppLocalization.string("No tools to choose from.", table: .bots))
                        .foregroundStyle(.secondary)
                } else {
                    // Hermes reads no tools as its default tools, so the
                    // last one on stays on.
                    BotCapabilityRows(rows: capabilities.toolsets, editable: editable, keepsOneOn: true) { name, on in
                        guard editable else { return }
                        capabilities.setEnabled(\.toolsets, name: name, on: on)
                    }
                    .equatable()
                    Text(AppLocalization.string("With every tool on, the bot follows Hermes' default tools. At least one tool stays on.", table: .bots))
                        .settingsCaption()
                }
            }
        }
        .navigationTitle(AppLocalization.string("Tools"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The bot editor's MCP page: switches over the profile's
/// `profiles.describe` servers (upstream `profile-config.tsx`). Edit Bot
/// also adds servers from Hermes' MCP catalog, with their keys or an OAuth
/// sign-in (upstream `mcp-setup.tsx`), and ones typed in with Add MCP
/// Server, the Connectors tab's sheet. Skills and Tools are pages of their
/// own beside it (BotSkillsView, BotToolsView).
struct BotMcpServersView: View {
    @Binding var capabilities: BotCapabilities
    /// The bot whose profile catalog servers go into: Edit Bot's. Nil on
    /// New Bot, whose profile doesn't exist yet.
    var mcpProfile: String? = nil
    /// False while the lists are the ones Hermes gave last time, until it
    /// answers again (#1533): nothing can change then.
    var editable = true

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    /// The catalog and sign-in state; nil until read, or when Hermes
    /// doesn't offer them.
    @State private var mcpSetup: BotMcpSetupSnapshot?
    @State private var mcpSetupRead = false
    /// The catalog and sign-ins shown are Hermes' last answer, until it
    /// answers again: Add and Sign In wait for it.
    @State private var mcpSetupKept = false
    @State private var mcpSetupReading = false
    /// The server being added or signed in.
    @State private var mcpBusy: String?
    @State private var mcpNotice: MCPNotice?
    @State private var keysEntry: BotMcpCatalogEntry?
    @State private var addingServer = false
    /// The Hermes Add MCP Server was opened on: it writes there or nowhere.
    @State private var addOwner: DashboardRuntimeOwner?
    /// Whether the server Add MCP Server just wrote is on and signs in
    /// with OAuth.
    @State private var added: (enabled: Bool, oauth: Bool) = (true, false)
    @State private var browser: BotMcpBrowserPage?
    @State private var signInTask: Task<Void, Never>?

    private struct MCPNotice: Equatable {
        let text: String
        let isError: Bool
    }

    var body: some View {
        // Settings' own page, as Edit Bot that pushes it (Eric 2026-11-05).
        SettingsDetailContainer {
            ConduitSettingsSection(title: SettingsNames.mcp, symbol: "server.rack", tint: .purple) {
                if let mcpNotice {
                    Text(verbatim: mcpNotice.text)
                        .scaledFont(.footnote)
                        .foregroundStyle(mcpNotice.isError ? Color.red : Color.secondary)
                }
                if capabilities.mcpServers.isEmpty {
                    Text(AppLocalization.string("No MCP servers set up.", table: .bots))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(capabilities.mcpServers.map(\.name), id: \.self) { name in
                        if let index = capabilities.mcpServers.firstIndex(where: { $0.name == name }) {
                            toggle($capabilities.mcpServers[index])
                            if mcpSetup?.servers[name]?.needsSignIn == true {
                                signInRow(name)
                            }
                        }
                    }
                }
                if mcpProfile != nil, mcpSetup != nil {
                    Button {
                        mcpNotice = nil
                        addOwner = appState.currentDashboardRuntimeOwner()
                        addingServer = true
                    } label: {
                        Label(AppLocalization.string("Add MCP Server", table: .bots), systemImage: "plus")
                    }
                    .buttonStyle(.settings)
                    .disabled(mcpBusy != nil || !canSetUpServers)
                }
                Group {
                    if mcpProfile == nil {
                        Text(AppLocalization.string("Add MCP servers in Edit Bot, once the bot is made.", table: .bots))
                    } else if mcpSetup == nil && mcpSetupRead {
                        Text(AppLocalization.string("Add new MCP servers from Hermes on your computer.", table: .bots))
                    } else if mcpSetupKept && mcpSetupRead {
                        // Hermes didn't answer: Add and Sign In wait over the
                        // kept catalog until it does.
                        VStack(alignment: .leading, spacing: 6) {
                            Text(AppLocalization.string("Add new MCP servers from Hermes on your computer.", table: .bots))
                            Button(AppLocalization.string("Try Again")) {
                                Task { await readMcpSetup() }
                            }
                            .buttonStyle(.settings)
                            .disabled(mcpSetupReading)
                        }
                    }
                }
                .settingsCaption()
            }
            if let mcpSetup, !offeredServers(mcpSetup).isEmpty {
                ConduitSettingsSection(title: AppLocalization.string("Hermes' MCP Catalog", table: .bots), symbol: "square.grid.2x2", tint: .purple) {
                    ForEach(offeredServers(mcpSetup)) { entry in
                        catalogRow(entry)
                    }
                    Text(AppLocalization.string("Adding a server writes it to this bot's profile right away. Its keys and sign-ins stay on Hermes.", table: .bots))
                        .settingsCaption()
                }
            }
        }
        .navigationTitle(Text(verbatim: SettingsNames.mcp))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // Leaving the page gives up a sign-in. Safari covering it
            // doesn't: the cover is up then.
            if browser == nil { signInTask?.cancel() }
        }
        .onAppear {
            guard let mcpProfile, mcpSetup == nil, !mcpSetupRead else { return }
            mcpSetup = appState.keptBotMcpSetup(profile: mcpProfile)
            mcpSetupKept = mcpSetup != nil
        }
        .task {
            guard !mcpSetupRead else { return }
            await readMcpSetup()
        }
        .sheet(item: $keysEntry) { entry in
            BotMcpKeysSheet(entry: entry) { keys in add(entry, keys: keys) }
        }
        .sheet(isPresented: $addingServer) { addServerSheet }
        .fullScreenCover(item: $browser) { page in
            BotMcpBrowserView(url: page.url) {
                browser = nil
                signInTask?.cancel()
            }
            .ignoresSafeArea()
            // Safari gone without the flow closing it (the editor torn down
            // under it): give the sign-in up. After a finished sign-in the
            // task is already done, so this does nothing.
            .onDisappear { signInTask?.cancel() }
        }
    }

    // MARK: MCP setup

    /// Add and Sign In write to Hermes at once: only over Hermes' own
    /// lists and catalog.
    private var canSetUpServers: Bool { editable && !mcpSetupKept }

    private func readMcpSetup() async {
        guard let mcpProfile, !mcpSetupReading else { return }
        mcpSetupReading = true
        let read = await appState.loadBotMcpSetup(profile: mcpProfile)
        mcpSetupReading = false
        // Cut off by leaving the page: it reads again when it shows.
        guard !Task.isCancelled else { return }
        // A read that fails keeps the kept setup up.
        if read != nil || !mcpSetupKept {
            mcpSetup = read
            mcpSetupKept = false
        }
        mcpSetupRead = true
    }

    private func offeredServers(_ setup: BotMcpSetupSnapshot) -> [BotMcpCatalogEntry] {
        BotMcpSetup.offered(setup.catalog, configured: capabilities.mcpServers.map(\.name))
    }

    private func catalogRow(_ entry: BotMcpCatalogEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                if !entry.description.isEmpty {
                    Text(verbatim: entry.description)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !entry.requires.isEmpty {
                    Text(AppLocalization.string("Needs \(entry.requires.joined(separator: ", "))", table: .bots))
                        .scaledFont(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if mcpBusy == entry.name {
                ProgressView()
            } else {
                Button(AppLocalization.string("Add")) {
                    if entry.requires.isEmpty {
                        add(entry, keys: [:])
                    } else {
                        keysEntry = entry
                    }
                }
                .buttonStyle(.settings)
                .disabled(mcpBusy != nil || !canSetUpServers)
                .accessibilityLabel(Text(AppLocalization.string("Add \(entry.name)")))
            }
        }
    }

    private func signInRow(_ name: String) -> some View {
        HStack {
            Text(AppLocalization.string("Needs a sign-in to connect.", table: .bots))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if mcpBusy == name {
                ProgressView()
            } else {
                Button(AppLocalization.string("Sign In")) { signIn(name) }
                    .buttonStyle(.settings)
                    .disabled(mcpBusy != nil || !canSetUpServers)
                    .accessibilityLabel(Text(AppLocalization.string("Sign in to \(name)", table: .bots)))
            }
        }
    }

    private func add(_ entry: BotMcpCatalogEntry, keys: [String: String]) {
        guard let mcpProfile, mcpBusy == nil else { return }
        mcpBusy = entry.name
        mcpNotice = nil
        Task {
            let outcome = await appState.addBotMcpServer(profile: mcpProfile, entry: entry, keys: keys)
            mcpBusy = nil
            report(outcome, name: entry.name, description: entry.description)
        }
    }

    /// Add MCP Server for this bot's profile: the sheet shows what Hermes
    /// refused; once Hermes wrote it, the page signs it in or tests it.
    private var addServerSheet: some View {
        let profile = mcpProfile ?? ""
        let owner = addOwner
        return ConnectorAddSheet(profileName: appState.profileDisplayName(profile)) { name, entry, bearerToken in
            added = try await appState.addCustomMcpServer(
                profile: profile, name: name, entry: entry, bearerToken: bearerToken, openedOn: owner
            )
        } onAdded: { name in
            // One the JSON turned off stays off, and isn't tested.
            guard added.enabled else {
                report(.ready, name: name, description: "", enabled: false)
                return
            }
            if added.oauth {
                report(.needsSignIn, name: name, description: "")
                return
            }
            mcpBusy = name
            Task {
                let outcome = await appState.testAddedBotMcpServer(profile: profile, name: name)
                mcpBusy = nil
                report(outcome, name: name, description: "")
            }
        }
    }

    /// What an add came to: the server on in the list (Hermes turns a new
    /// server on), then its sign-in, or what its test said.
    private func report(_ outcome: BotMcpInstallOutcome, name: String, description: String, enabled: Bool = true) {
        if outcome.wasAdded, !capabilities.mcpServers.contains(where: { $0.name == name }) {
            capabilities.mcpServers.append(
                BotCapability(name: name, description: description, enabled: enabled)
            )
        }
        switch outcome {
        case .ready:
            Haptics.success()
            mcpNotice = MCPNotice(text: AppLocalization.string("Added \(name).", table: .bots), isError: false)
        case .needsSignIn:
            mcpSetup?.servers[name] = BotMcpServerSummary(name: name, auth: "oauth", oauthTokensPresent: false)
            signIn(name)
        case .addedWithProblem(let message):
            Haptics.warning()
            mcpNotice = MCPNotice(text: AppLocalization.string("Added \(name), but it did not connect: \(message)", table: .bots), isError: true)
        case .failed(let message):
            Haptics.warning()
            mcpNotice = MCPNotice(text: message, isError: true)
        }
    }

    private func signIn(_ name: String) {
        guard let mcpProfile, signInTask == nil else { return }
        mcpBusy = name
        mcpNotice = nil
        signInTask = Task {
            let outcome = await appState.signInBotMcpServer(profile: mcpProfile, name: name) { url in
                browser = BotMcpBrowserPage(url: url)
            }
            browser = nil
            mcpBusy = nil
            signInTask = nil
            switch outcome {
            case .signedIn:
                Haptics.success()
                mcpSetup?.servers[name] = BotMcpServerSummary(name: name, auth: "oauth", oauthTokensPresent: true)
                mcpNotice = MCPNotice(text: AppLocalization.string("Signed in to \(name).", table: .bots), isError: false)
            case .cancelled:
                break
            case .failed(let message):
                Haptics.warning()
                mcpNotice = MCPNotice(text: AppLocalization.string("Could not sign in to \(name): \(message)", table: .bots), isError: true)
            }
        }
    }

    private func toggle(_ item: Binding<BotCapability>) -> some View {
        Toggle(isOn: item.enabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.wrappedValue.label ?? item.wrappedValue.name)
                if !item.wrappedValue.description.isEmpty {
                    Text(verbatim: item.wrappedValue.description)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .tint(.conduitAccent)
        .disabled(!editable)
    }
}

/// A list of skill or toolset switches, keyed by name so a filter change
/// or Hermes' answer never hands one row's switch to another. Equatable on
/// what it shows: Edit Bot redraws on every AppState publish, and a long
/// skills list redrawn with it made the page lag. Lazy, so only the rows
/// on screen are built.
struct BotCapabilityRows: View, Equatable {
    let rows: [BotCapability]
    let editable: Bool
    /// The toolsets: the last one on can't be turned off, since no tools
    /// on would save as Hermes' default tools.
    let keepsOneOn: Bool
    let onSet: (String, Bool) -> Void
    /// Observed here: the equality skips a redraw from above, and the
    /// locked row's hint must still follow an App Language switch.
    @ObservedObject private var appLanguage = AppLanguageStore.shared

    init(rows: [BotCapability], editable: Bool, keepsOneOn: Bool, onSet: @escaping (String, Bool) -> Void) {
        self.rows = rows
        self.editable = editable
        self.keepsOneOn = keepsOneOn
        self.onSet = onSet
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows == rhs.rows && lhs.editable == rhs.editable && lhs.keepsOneOn == rhs.keepsOneOn
    }

    var body: some View {
        let onCount = keepsOneOn ? rows.lazy.filter(\.enabled).count : 0
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(rows) { row in
                let locked = keepsOneOn && row.enabled && onCount <= 1
                Toggle(isOn: Binding(get: { row.enabled }, set: { onSet(row.name, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.label ?? row.name)
                        if !row.description.isEmpty {
                            Text(verbatim: row.description)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .tint(.conduitAccent)
                .disabled(!editable || locked)
                .accessibilityHint(locked
                    ? Text(AppLocalization.string("At least one tool stays on.", table: .bots))
                    : Text(verbatim: ""))
            }
        }
    }
}

/// The sign-in page an MCP server's OAuth opens.
struct BotMcpBrowserPage: Identifiable {
    let id = UUID()
    let url: URL
}

/// Safari for an MCP sign-in. Done gives up the sign-in; a finished one
/// closes it from the flow.
struct BotMcpBrowserView: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .cancel
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDone: () -> Void

        init(onDone: @escaping () -> Void) {
            self.onDone = onDone
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDone()
        }
    }
}

/// The keys a catalog server needs, typed before Hermes adds it
/// (Desktop's Set Up fields). They go to Hermes and aren't kept here.
struct BotMcpKeysSheet: View {
    let entry: BotMcpCatalogEntry
    let onAdd: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            SettingsDetailContainer {
                ConduitSettingsSection(title: AppLocalization.string("Keys", table: .bots), symbol: "key", tint: .conduitAccent) {
                    ForEach(entry.requires, id: \.self) { envVar in
                        SecureField(
                            text: Binding(
                                get: { values[envVar] ?? "" },
                                set: { values[envVar] = $0 }
                            ),
                            prompt: Text(verbatim: envVar)
                        ) {
                            Text(verbatim: envVar)
                        }
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    Text(AppLocalization.string("Hermes stores these in the bot's profile and checks that \(entry.name) connects. Leave one empty to set it on Hermes instead.", table: .bots))
                        .settingsCaption()
                }
            }
            .navigationTitle(Text(verbatim: entry.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Add")) {
                        onAdd(values)
                        dismiss()
                    }
                }
            }
        }
    }
}
