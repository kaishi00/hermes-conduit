//
//  DelegationRoutingViews.swift
//  Conduit
//
//  Settings > Memory & delegation > Subagent routing: how each subagent
//  gets its model (Default, Model routes, Profile routes or a plugin's
//  own mode), and the routes of the chosen mode. Hermes Desktop's Model >
//  Subagents > Routing is the reference; the routes come from the Advanced
//  Delegation plugin.
//

import SwiftUI

/// What the section reads and writes, on the profile the page is for.
struct DelegationRoutingActions {
    let kept: () -> DelegationRouting?
    let load: () async throws -> DelegationRouting
    let choose: (String) async throws -> Void
    let saveModelRoutes: (DelegationRouting) async throws -> (routes: [DelegationRouting.ModelRoute], defaultRoute: String?)
    let saveProfileRoutes: (DelegationRouting) async throws -> (routes: [DelegationRouting.ProfileRoute], defaultRoute: String?)
    /// The model catalog the route sheet picks from.
    let keptModels: () -> ProfileModelDefaults?
    let loadModels: () async -> ProfileModelDefaults?
}

struct DelegationRoutingSettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let actions: DelegationRoutingActions
    /// Tells the page the routing it shows, so Delegate model can say it
    /// isn't used in a routed mode.
    let onRouting: (DelegationRouting?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var routing: DelegationRouting?
    /// Hermes' answer is in. Until then the kept routing is only shown: it
    /// has no route's key preview, which a save sends back.
    @State private var answered = false
    @State private var unsupported = false
    @State private var loadFailed = false
    @State private var working = false
    @State private var error: String?
    /// Counts the reads, so an older answer never lands over a newer one.
    @State private var readCount = 0
    @State private var models: ProfileModelDefaults?
    @State private var editing: RouteEditing?
    @State private var deleting: DelegationRouting.ModelRoute?
    @State private var descriptions: [String: String] = [:]
    @FocusState private var describing: String?

    /// The route sheet: a new route, or the one it edits.
    struct RouteEditing: Identifiable {
        let route: DelegationRouting.ModelRoute?
        var id: String { route?.name ?? "\u{1F}new" }
    }

    var body: some View {
        if !unsupported {
            VStack(alignment: .leading, spacing: 24) {
                ConduitSettingsSection(title: AppLocalization.string("Subagent routing"), symbol: "signpost.right.and.left", tint: .conduitAccent) {
                    Text("How each subagent gets its model.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                    if let routing {
                        modeRows(routing)
                        status(routing)
                        if !answered && loadFailed {
                            Button(AppLocalization.string("Try Again")) { Task { await reload() } }
                                .buttonStyle(.settings)
                        }
                    } else if loadFailed {
                        Text("Could not load subagent routing.")
                            .scaledFont(.footnote).foregroundStyle(.secondary)
                        Button(AppLocalization.string("Try Again")) { Task { await reload() } }
                            .buttonStyle(.settings)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if let error { Text(error).scaledFont(.caption).foregroundStyle(.red) }
                }
                if let routing, routing.configured == DelegationRouting.modelMapMode {
                    modelRoutes(routing)
                }
                if let routing, routing.configured == DelegationRouting.profileRoutesMode {
                    profileRoutes(routing)
                }
            }
            .onAppear {
                guard routing == nil, let kept = actions.kept() else { return }
                show(kept)
                models = models ?? actions.keptModels()
            }
            .task { await reload() }
            .sheet(item: $editing) { editing in
                DelegationModelRouteSheet(
                    route: editing.route,
                    taken: (routing?.modelRoutes ?? []).map(\.name).filter { $0 != editing.route?.name },
                    models: models,
                    save: { route in try await saveRoute(route, replacing: editing.route?.name) }
                )
            }
            .confirmationDialog(
                AppLocalization.string("Delete route \(deleting?.name ?? "")?"),
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible,
                presenting: deleting
            ) { route in
                Button(AppLocalization.string("Delete route"), role: .destructive) { deleteRoute(route) }
            } message: { route in
                Text(deleteMessage(route))
            }
        }
    }

    // MARK: Modes

    private func modeRows(_ routing: DelegationRouting) -> some View {
        VStack(spacing: 8) {
            ForEach(routing.modeChoices, id: \.self) { mode in
                let selected = mode == routing.configured
                let available = routing.isAvailable(mode)
                let blocked = selected && routing.blockedReason != nil
                Button { choose(mode) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? (blocked ? Color.orange : Color.conduitAccent) : Color.secondary)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: modeLabel(mode, routing))
                                    .scaledFont(.subheadline.weight(.medium))
                                    .foregroundStyle(available || selected ? Color.primary : Color.secondary)
                                if selected {
                                    pill(blocked ? AppLocalization.string("Not running") : AppLocalization.string("In use"), tint: blocked ? .orange : .conduitAccent)
                                } else if !available {
                                    pill(AppLocalization.string("Plugin"), tint: .secondary)
                                }
                            }
                            Text(verbatim: modeSummary(mode, routing))
                                .scaledFont(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selected || !available || !answered || working)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("settings.delegationRouting.\(mode)")
            }
        }
    }

    private func modeLabel(_ mode: String, _ routing: DelegationRouting) -> String {
        switch mode {
        case DelegationRouting.defaultMode: AppLocalization.string("Default")
        case DelegationRouting.modelMapMode: AppLocalization.string("Model routes")
        case DelegationRouting.profileRoutesMode: AppLocalization.string("Profile routes")
        default: routing.backend(mode).map { $0.label.isEmpty ? $0.name : $0.label } ?? mode
        }
    }

    private func modeSummary(_ mode: String, _ routing: DelegationRouting) -> String {
        switch mode {
        case DelegationRouting.defaultMode: return AppLocalization.string("Every subagent runs on the delegate model below.")
        case DelegationRouting.modelMapMode: return AppLocalization.string("Name a few models. The agent picks one for each subagent.")
        case DelegationRouting.profileRoutesMode: return AppLocalization.string("Subagents run as one of your profiles, with its own model, skills and keys.")
        default:
            let summary = routing.backend(mode)?.summary ?? ""
            return summary.isEmpty ? AppLocalization.string("From a plugin. Its settings live with that plugin.") : summary
        }
    }

    /// Why the saved mode can't run, or where the plugin modes come from,
    /// and what Delegate model below means in this mode.
    @ViewBuilder
    private func status(_ routing: DelegationRouting) -> some View {
        if let blocked = routing.blockedReason {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(verbatim: blocked).scaledFont(.footnote.weight(.medium))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text("This mode is saved, so Hermes refuses every subagent instead of quietly using Default.")
                    .scaledFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                useDefaultButton
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
        } else if routing.routesOwnSubagentModel {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: inactiveReason(routing))
                    .scaledFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                useDefaultButton
            }
        }
        if DelegationRouting.pluginModes.contains(where: { !routing.isAvailable($0) }) {
            Label {
                Text("Model routes and Profile routes come from the Advanced Delegation plugin. Install it or turn it on in Capabilities > Plugins.")
                    .scaledFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
            }
        }
    }

    private var useDefaultButton: some View {
        Button(AppLocalization.string("Switch to Default")) { choose(DelegationRouting.defaultMode) }
            .buttonStyle(.settings)
            .disabled(!answered || working)
    }

    /// What a subagent that picks no route runs on, as Desktop says it.
    private func inactiveReason(_ routing: DelegationRouting) -> String {
        switch routing.configured {
        case DelegationRouting.modelMapMode:
            if let route = routing.defaultModelRoute {
                return AppLocalization.string("Model routes pick each subagent's model, so Delegate model below isn't used. Subagents that pick no route use \(route).")
            }
            return AppLocalization.string("Model routes pick each subagent's model, so Delegate model below isn't used. Subagents that pick no route use the chat's model.")
        case DelegationRouting.profileRoutesMode:
            if let profile = routing.defaultProfileRoute {
                return AppLocalization.string("Profile routes pick each subagent's profile, so Delegate model below isn't used. Subagents that pick no profile run as \(profile).")
            }
            return AppLocalization.string("Profile routes pick each subagent's profile, so Delegate model below isn't used. Subagents that pick no profile use the chat's model.")
        default:
            return AppLocalization.string("\(modeLabel(routing.configured, routing)) decides each subagent's model, so Delegate model below isn't used.")
        }
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(verbatim: text)
            .scaledFont(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    // MARK: Model routes

    private func modelRoutes(_ routing: DelegationRouting) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Model routes"), symbol: "shippingbox", tint: .conduitAura) {
            Text("The agent reads each route's name and description to pick one for a subagent.")
                .scaledFont(.footnote).foregroundStyle(.secondary)
            if routing.modelRoutes.isEmpty {
                Text("No routes yet. Until you add one, subagents use the chat's model.")
                    .scaledFont(.footnote).foregroundStyle(.secondary)
            }
            ForEach(routing.modelRoutes) { route in
                routeRow(route, isDefault: routing.defaultModelRoute == route.name, routing: routing)
            }
            Button { editing = RouteEditing(route: nil) } label: { Label(AppLocalization.string("Add route"), systemImage: "plus") }
                .buttonStyle(.settings)
                .disabled(!answered || working)
                .accessibilityIdentifier("settings.delegationRouting.addRoute")
        }
    }

    private func routeRow(_ route: DelegationRouting.ModelRoute, isDefault: Bool, routing: DelegationRouting) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { editing = RouteEditing(route: route) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: route.name)
                            .scaledFont(.subheadline.weight(.semibold).monospaced())
                            .lineLimit(1)
                        if isDefault { pill(AppLocalization.string("Default"), tint: .conduitAccent) }
                    }
                    Text(verbatim: route.description)
                        .scaledFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: route.facts.joined(separator: " · "))
                        .scaledFont(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button { editing = RouteEditing(route: route) } label: { Label(AppLocalization.string("Edit"), systemImage: "pencil") }
                if !isDefault {
                    Button { saveModelRoutes(routing.defaultingModelRoute(route.name)) } label: { Label(AppLocalization.string("Make default"), systemImage: "star") }
                }
                Button(role: .destructive) { deleting = route } label: { Label(AppLocalization.string("Delete"), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(AppLocalization.string("More")))
            .accessibilityValue(Text(verbatim: route.name))
        }
        .disabled(!answered || working)
    }

    private func deleteMessage(_ route: DelegationRouting.ModelRoute) -> String {
        let next = routing?.removingModelRoute(route.name)
        if routing?.defaultModelRoute == route.name, let fallback = next?.defaultModelRoute {
            return AppLocalization.string("Subagents can no longer pick it. It's the default route, so \(fallback) becomes the default.")
        }
        return AppLocalization.string("Subagents can no longer pick it.")
    }

    private func deleteRoute(_ route: DelegationRouting.ModelRoute) {
        guard let routing else { return }
        saveModelRoutes(routing.removingModelRoute(route.name))
    }

    /// The sheet's save: Hermes' answer, or why it refused, for the sheet.
    private func saveRoute(_ route: DelegationRouting.ModelRoute, replacing original: String?) async throws {
        guard let routing else { throw DelegationRoutingError.notConnected }
        try await writeModelRoutes(routing.upsertingModelRoute(route, replacing: original))
    }

    private func saveModelRoutes(_ next: DelegationRouting) {
        run { try await writeModelRoutes(next) }
    }

    private func writeModelRoutes(_ next: DelegationRouting) async throws {
        let saved = try await actions.saveModelRoutes(next)
        readCount += 1
        guard var shown = routing else { return }
        shown.modelRoutes = saved.routes
        shown.defaultModelRoute = saved.defaultRoute
        show(shown)
    }

    // MARK: Profile routes

    private func profileRoutes(_ routing: DelegationRouting) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Profiles subagents can run as"), symbol: "person.2", tint: .conduitAura) {
            Text("Each profile you turn on brings its own model, skills, persona and keys.")
                .scaledFont(.footnote).foregroundStyle(.secondary)
            let listed = routing.profileRoutes.map(\.name)
            // A listed profile deleted since stays on screen, to turn off.
            let names = routing.profiles + listed.filter { !routing.profiles.contains($0) }
            if names.isEmpty {
                Text("No other profiles yet.")
                    .scaledFont(.footnote).foregroundStyle(.secondary)
            }
            ForEach(names, id: \.self) { name in
                profileRow(name, routing: routing, missing: !routing.profiles.contains(name))
            }
        }
    }

    private func profileRow(_ name: String, routing: DelegationRouting, missing: Bool) -> some View {
        let entry = routing.profileRoutes.first { $0.name == name }
        let isDefault = routing.defaultProfileRoute == name
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { entry != nil },
                set: { on in saveProfileRoutes(routing.togglingProfileRoute(name, on: on)) }
            )) {
                HStack(spacing: 6) {
                    Text(verbatim: missing ? AppLocalization.string("\(name) (profile no longer exists)") : name)
                        .scaledFont(.subheadline.weight(.medium))
                    if entry != nil && isDefault { pill(AppLocalization.string("Default"), tint: .conduitAccent) }
                }
            }
            .tint(.conduitAccent)
            .disabled(!answered || working || (missing && entry == nil))
            if entry != nil {
                TextField(AppLocalization.string("When to use it (optional)"), text: Binding(
                    get: { descriptions[name] ?? entry?.description ?? "" },
                    set: { descriptions[name] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .focused($describing, equals: name)
                .submitLabel(.done)
                .onSubmit { commitDescription(name) }
                .disabled(!answered || working)
                if !isDefault {
                    Button(AppLocalization.string("Make default")) { saveProfileRoutes(routing.defaultingProfileRoute(name)) }
                        .buttonStyle(.settings)
                        .disabled(!answered || working)
                }
            }
        }
        .padding(.vertical, 2)
        .onChange(of: describing) { previous, _ in
            if previous == name { commitDescription(name) }
        }
    }

    private func commitDescription(_ name: String) {
        guard let routing, let typed = descriptions[name] else { return }
        let stored = routing.profileRoutes.first { $0.name == name }?.description ?? ""
        guard typed.trimmingCharacters(in: .whitespacesAndNewlines) != stored else {
            descriptions[name] = nil
            return
        }
        saveProfileRoutes(routing.describingProfileRoute(name, typed))
    }

    private func saveProfileRoutes(_ next: DelegationRouting) {
        run {
            let saved = try await actions.saveProfileRoutes(next)
            readCount += 1
            guard var shown = routing else { return }
            shown.profileRoutes = saved.routes
            shown.defaultProfileRoute = saved.defaultRoute
            descriptions = [:]
            show(shown)
        }
    }

    // MARK: Reads and writes

    private func choose(_ mode: String) {
        guard let routing, mode != routing.configured else { return }
        run {
            try await actions.choose(mode)
            await reload()
        }
    }

    /// One change at a time; a failed one says why, and the page reads
    /// Hermes again so it shows what Hermes holds.
    private func run(_ change: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await change()
            } catch is CancellationError {
            } catch let failure {
                await reload()
                error = UserFacingError.message(for: failure)
            }
            working = false
        }
    }

    private func reload() async {
        readCount += 1
        let read = readCount
        loadFailed = false
        if models == nil { models = actions.keptModels() }
        do {
            let loaded = try await actions.load()
            guard read == readCount else { return }
            answered = true
            show(loaded)
        } catch DelegationRoutingError.unsupported {
            guard read == readCount else { return }
            unsupported = true
            routing = nil
            onRouting(nil)
        } catch is CancellationError {
        } catch {
            guard read == readCount else { return }
            loadFailed = true
        }
        if let loadedModels = await actions.loadModels() { models = loadedModels }
    }

    private func show(_ next: DelegationRouting) {
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { routing = next }
        onRouting(next)
    }
}

/// Adds or edits one model route. Every key of the route it edits that the
/// sheet doesn't show goes back as Hermes sent it.
private struct DelegationModelRouteSheet: View {
    let route: DelegationRouting.ModelRoute?
    let taken: [String]
    let models: ProfileModelDefaults?
    let save: (DelegationRouting.ModelRoute) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DelegationModelRouteDraft()
    @State private var working = false
    @State private var error: String?
    @State private var started = false

    private var providers: [ProviderInfo] { models?.providers ?? [] }

    /// A provider or model the catalog doesn't list stays visible, so a
    /// hand-written route is never shown as a different one.
    private var providerChoices: [(id: String, title: String)] {
        let listed = providers.map { (id: $0.name, title: $0.title) }
        let current = draft.provider.isEmpty || listed.contains(where: { $0.id == draft.provider }) ? [] : [(id: draft.provider, title: draft.provider)]
        let none = draft.provider.isEmpty ? [(id: "", title: AppLocalization.string("Choose a provider"))] : []
        return none + current + listed
    }

    private var modelChoices: [(id: String, title: String)] {
        let listed = (providers.first { $0.name == draft.provider }?.models ?? []).map { (id: $0.id, title: $0.label ?? $0.id) }
        let current = draft.model.isEmpty || listed.contains(where: { $0.id == draft.model }) ? [] : [(id: draft.model, title: draft.model)]
        let none = draft.model.isEmpty ? [(id: "", title: AppLocalization.string("Choose a model"))] : []
        return none + current + listed
    }

    var body: some View {
        NavigationStack {
            SettingsDetailContainer(compact: true) {
                ConduitSettingsSection(title: AppLocalization.string("Route"), symbol: "signpost.right", tint: .conduitAccent) {
                    Text("The agent reads the name and description to decide which route a subagent takes.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(AppLocalization.string("Name, like fast"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("settings.delegationRoute.name")
                    TextField(AppLocalization.string("When to use it, like quick lookups and summaries"), text: $draft.description, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("settings.delegationRoute.description")
                }
                ConduitSettingsSection(title: AppLocalization.string("Model"), symbol: "cpu", tint: .conduitAura) {
                    if providers.isEmpty {
                        Text("Hermes hasn't listed its models yet. Close this and open it again in a moment.")
                            .scaledFont(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ConduitMenuPicker(value: draft.provider, choices: providerChoices, onSelect: chooseProvider) {
                        Text("Provider").foregroundStyle(.secondary)
                    }
                    if draft.provider.isEmpty, let endpoint = route?.baseURL, !endpoint.isEmpty {
                        Text(AppLocalization.string("Runs on its endpoint, \(endpoint)."))
                            .scaledFont(.caption).foregroundStyle(.secondary)
                    }
                    ConduitMenuPicker(value: draft.model, choices: modelChoices, onSelect: { draft.model = $0 }) {
                        Text("Model").foregroundStyle(.secondary)
                    }
                    ConduitMenuPicker(
                        value: draft.reasoningEffort,
                        choices: [(id: "", title: AppLocalization.string("Subagent default"))] + DelegationModelRouteDraft.reasoningEfforts.map { (id: $0, title: $0.capitalized) },
                        onSelect: { draft.reasoningEffort = $0 }
                    ) {
                        Text("Reasoning effort").foregroundStyle(.secondary)
                    }
                    ConduitMenuPicker(
                        value: draft.serviceTier,
                        choices: [
                            (id: "", title: AppLocalization.string("Subagent default")),
                            (id: "normal", title: AppLocalization.string("Normal")),
                            (id: "fast", title: AppLocalization.string("Fast")),
                            (id: "ultrafast", title: AppLocalization.string("Ultrafast")),
                        ],
                        onSelect: { draft.serviceTier = $0 }
                    ) {
                        Text("Speed").foregroundStyle(.secondary)
                    }
                    Text("Speed applies only on models that offer it.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).scaledFont(.caption).foregroundStyle(.red) }
            }
            .navigationTitle(route == nil ? AppLocalization.string("New model route") : AppLocalization.string("Edit model route"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                        .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(route == nil ? AppLocalization.string("Add") : AppLocalization.string("Save")) { submit() }
                            .accessibilityIdentifier("settings.delegationRoute.save")
                    }
                }
            }
            .disabled(working)
        }
        .interactiveDismissDisabled(working)
        .onAppear {
            guard !started else { return }
            started = true
            if let route { draft = DelegationModelRouteDraft(route: route) }
        }
    }

    /// A model the new provider doesn't list isn't carried over to it.
    private func chooseProvider(_ next: String) {
        guard next != draft.provider else { return }
        draft.provider = next
        let listed = providers.first { $0.name == next }?.models ?? []
        if !listed.contains(where: { $0.id == draft.model }) { draft.model = listed.first?.id ?? "" }
    }

    private func submit() {
        guard !working else { return }
        switch draft.route(taken: taken, editing: route) {
        case .failure(let problem):
            error = problem.message
        case .success(let next):
            working = true
            error = nil
            Task {
                do {
                    try await save(next)
                    dismiss()
                } catch let failure {
                    error = UserFacingError.message(for: failure)
                }
                working = false
            }
        }
    }
}
