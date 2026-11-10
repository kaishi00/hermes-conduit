import SwiftUI

/// Edit Bot > Work: how a bot's Bot Chat coordinates its work. Whether it
/// does at all, what it may do itself, how many workstreams run at once,
/// what a restart does with cut-off work, and what its workstreams ask
/// approval for (designs/bot-mode-coordinator C.4, C.7, C.11). The plugin
/// keeps them, so each change saves as it's made and every device agrees.
struct BotWorkSettingsView: View {
    let profile: String
    let botName: String

    @EnvironmentObject private var appState: AppState
    @State private var settings: BotWorkSettings?
    @State private var loadFailed = false
    @State private var isSaving = false
    @State private var saveFailed = false
    /// The Workstream Model page's pick: it sets the provider, then the
    /// model, and the model's write saves the two together.
    @State private var pickedProvider = ""
    /// Hermes' helper model slot the plugin's work watch reads with, in
    /// this bot's profile; nil until read, or on a plugin without it.
    @State private var watchSlot: HelperModelSlot?
    /// Names the newest slot read: an older one that answers later is
    /// dropped.
    @State private var watchReads = 0

    var body: some View {
        // Settings' own page: cards with their names over them, menus for
        // choices and captions inside the card, so Work reads like the
        // Settings tab (Eric 2026-11-05).
        SettingsDetailContainer {
            if let settings {
                content(settings)
                    // One change at a time: a tap while one saves isn't lost unseen.
                    .disabled(isSaving)
            } else if loadFailed {
                ConduitSettingsSection(title: AppLocalization.string("Work"), symbol: "exclamationmark.triangle", tint: .orange) {
                    Text(AppLocalization.string("Couldn’t load the work settings."))
                        .foregroundStyle(.secondary)
                    Button(AppLocalization.string("Try Again")) {
                        Task { await load() }
                    }
                    .buttonStyle(.settings)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
        .navigationTitle(AppLocalization.string("Work"))
        // Again when the connection comes back: a page opened while the
        // app reconnects (just back in the foreground) read nothing.
        .task(id: appState.isConnected) {
            if settings == nil { await load() }
            await readWatchSlot()
        }
        // Back from its page, or set on Models & providers meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: HelperModelSlot.saved)) { _ in
            Task { await readWatchSlot() }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func content(_ settings: BotWorkSettings) -> some View {
        if saveFailed {
            Text(AppLocalization.string("Couldn’t save that change. Try again."))
                .scaledFont(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
        }
        ConduitSettingsSection(title: AppLocalization.string("Work"), symbol: "arrow.triangle.branch", tint: .conduitAccent) {
            if settings.unavailable != nil {
                Text(AppLocalization.string("Workstreams can’t run on this Hermes."))
                if let reason = settings.unavailable {
                    caption(reason)
                }
            }
            Toggle(AppLocalization.string("Coordinate Work"), isOn: binding(\.isOnSetting))
                .tint(.conduitAccent)
            caption(settings.isOn
                ? AppLocalization.string("\(botName) starts a chat of its own for longer tasks, works on them in the background, and tells you in its Bot Chat when they’re done.")
                : AppLocalization.string("\(botName) does everything in its Bot Chat itself. Work that’s already running carries on."))
            if settings.isOn {
                ConduitMenuPicker(
                    value: settings.policy,
                    choices: Self.policyChoices(settings),
                    onSelect: { binding(\.policy).wrappedValue = $0 }
                ) {
                    Text(AppLocalization.string("What It Does Itself")).foregroundStyle(.secondary)
                }
                caption(Self.policyCaption(settings.policy, botName: botName))
                let stepChoices = Self.quickStepsChoices(settings)
                if settings.policy == .lookups, let steps = settings.quickSteps, stepChoices.count > 1 {
                    ConduitMenuPicker(
                        value: steps,
                        choices: stepChoices,
                        onSelect: { binding(\.quickSteps).wrappedValue = $0 }
                    ) {
                        Text(AppLocalization.string("Steps in One Turn")).foregroundStyle(.secondary)
                    }
                    caption(AppLocalization.string("\(botName) does up to \(String(steps)) steps of a task in its Bot Chat. A task that needs more carries on in the background."))
                }
                Stepper(value: binding(\.maxRunning), in: 1...settings.maxRunningLimit) {
                    LabeledContent(AppLocalization.string("Running at Once")) {
                        Text(verbatim: "\(settings.maxRunning)")
                    }
                }
                caption(AppLocalization.string("When this many are running, \(botName) waits for one to finish or sends new work to one that’s already on it."))
            }
        }
        if settings.isOn, let coordination = settings.coordination {
            ConduitSettingsSection(title: AppLocalization.string("Coordination"), symbol: "point.3.connected.trianglepath.dotted", tint: .blue) {
                ConduitMenuPicker(
                    value: coordination,
                    choices: [
                        (id: BotWorkSettings.Coordination.ask, title: AppLocalization.string("Ask Me First")),
                        (id: BotWorkSettings.Coordination.auto, title: AppLocalization.string("Automatic")),
                        (id: BotWorkSettings.Coordination.off, title: AppLocalization.string("Off")),
                    ],
                    onSelect: { binding(\.coordination).wrappedValue = $0 }
                ) {
                    Text(AppLocalization.string("Between Workstreams")).foregroundStyle(.secondary)
                }
                caption(Self.coordinationCaption(coordination, botName: botName))
                if coordination != .off {
                    caption(AppLocalization.string("This doesn’t change what workstreams may do: their approvals stay as set under Safety."))
                    if let watchSlot {
                        // The same slot as Models & providers > Helper
                        // models, in this bot's profile.
                        NavigationLink {
                            HelperModelPage(slot: watchSlot, settings: watchModelSettings)
                        } label: {
                            ModelChooserLinkRow(title: AppLocalization.string("Watch Model"), value: watchSlot.value)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bot.work.watchModel")
                        caption(AppLocalization.string("A helper model reads what workstreams report while they work and tells \(botName) when one may affect another. A small, fast model is enough."))
                    }
                }
            }
        }
        if settings.isOn {
            ConduitSettingsSection(title: AppLocalization.string("Workstream Model"), symbol: "cpu", tint: .purple) {
                NavigationLink {
                    // Hermes' per-session reasoning, as the Model sheet offers
                    // it, beside the model it runs with.
                    BotModelPicker(
                        provider: providerBinding, model: modelBinding, allowsInherit: true,
                        inheritTitle: AppLocalization.string("Same as Bot Chat"),
                        // Shown from the start, so the first pick keeps the
                        // page open for its reasoning; it waits for a model.
                        reasoning: ModelChooserReasoning(
                            effort: effortBinding.wrappedValue ?? "",
                            inheritTitle: AppLocalization.string("Default"),
                            disabled: settings.workstreamModel == nil,
                            set: { effortBinding.wrappedValue = $0.isEmpty ? nil : $0 }
                        )
                    )
                } label: {
                    // The model and provider as the catalog names them.
                    let lines = ModelChooserLinkRow.lines(
                        pick: settings.workstreamModel.map { ModelChooserPick(provider: $0.provider, model: $0.model) },
                        providers: appState.keptModelProviders(),
                        defaultTitle: AppLocalization.string("Same as Bot Chat"),
                        reasoning: settings.workstreamModel == nil ? nil : effortBinding.wrappedValue.flatMap { $0.isEmpty ? nil : ReasoningEffortLevel.displayTitle(for: $0) }
                    )
                    ModelChooserLinkRow(title: AppLocalization.string("Model"), value: lines.value, detail: lines.detail)
                }
                .buttonStyle(.plain)
                caption(AppLocalization.string("New workstreams start on this model. Work that’s already running keeps its own."))
            }
            ConduitSettingsSection(title: AppLocalization.string("Safety"), symbol: "checkmark.shield", tint: .green) {
                ConduitMenuPicker(
                    value: settings.afterRestart,
                    choices: [
                        (id: BotWorkSettings.AfterRestart.continue, title: AppLocalization.string("Continue Safe Work")),
                        (id: BotWorkSettings.AfterRestart.ask, title: AppLocalization.string("Ask Me First")),
                    ],
                    onSelect: { binding(\.afterRestart).wrappedValue = $0 }
                ) {
                    Text(AppLocalization.string("After a Restart")).foregroundStyle(.secondary)
                }
                caption(AppLocalization.string("Work cut off during a step that can change things always waits for you. This is for the rest."))
                ConduitMenuPicker(
                    value: settings.approvals,
                    choices: [
                        (id: BotWorkSettings.Approvals.chats, title: AppLocalization.string("Same as Chats")),
                        (id: BotWorkSettings.Approvals.ask, title: AppLocalization.string("Ask Me First")),
                        (id: BotWorkSettings.Approvals.off, title: AppLocalization.string("Don’t Ask")),
                    ],
                    onSelect: { binding(\.approvals).wrappedValue = $0 }
                ) {
                    Text(AppLocalization.string("Approvals in Workstreams")).foregroundStyle(.secondary)
                }
                caption(Self.approvalsCaption(settings, botName: botName))
            }
        }
    }

    /// What the Bot Chat may do itself, by what the user notices rather than
    /// by tools (Eric 2026-11-08, notifier issue 619). Everything Here only
    /// where the plugin takes it.
    static func policyChoices(_ settings: BotWorkSettings) -> [(id: BotWorkSettings.Policy, title: String)] {
        var choices: [(id: BotWorkSettings.Policy, title: String)] = [
            (id: .lookups, title: AppLocalization.string("Quick Things Here"))
        ]
        if settings.policies.contains(.open) || settings.policy == .open {
            choices.append((id: .open, title: AppLocalization.string("Everything Here")))
        }
        choices.append((id: .strict, title: AppLocalization.string("Only Coordinates")))
        return choices
    }

    /// The step counts the plugin takes, with the bot's own when it isn't
    /// one of them.
    static func quickStepsChoices(_ settings: BotWorkSettings) -> [(id: Int, title: String)] {
        var counts = settings.quickStepsChoices.filter { $0 > 0 }
        if let steps = settings.quickSteps, !counts.contains(steps) { counts.append(steps) }
        return counts.sorted().map { (id: $0, title: String($0)) }
    }

    /// What the chosen setting means, in what the user will notice.
    static func policyCaption(_ policy: BotWorkSettings.Policy, botName: String) -> String {
        switch policy {
        case .open:
            return AppLocalization.string("\(botName) does everything in its Bot Chat, and runs work in the background only when you ask or it’s clearly long. The chat is busy while it works.")
        case .strict:
            return AppLocalization.string("Everything but cards, maps, notifications, memories and its questions to you runs in the background, so its Bot Chat is always free to talk.")
        case .lookups, .off:
            return AppLocalization.string("\(botName) answers and does quick things in its Bot Chat. Anything that takes longer runs in the background, and you’re told there when it’s done.")
        }
    }

    /// What the Coordination choice means, in what the user will notice.
    static func coordinationCaption(_ coordination: BotWorkSettings.Coordination, botName: String) -> String {
        switch coordination {
        case .ask:
            return AppLocalization.string("\(botName) follows what each workstream finds and changes. When one affects another, it tells you what it recommends and asks before it starts, stops or redirects work.")
        case .auto:
            return AppLocalization.string("\(botName) keeps its workstreams in step on its own. When one affects another, it can start, stop or redirect work, and tells you in a line when it did.")
        case .off:
            return AppLocalization.string("\(botName) only passes on what its workstreams report.")
        }
    }

    /// What the workstreams' approvals choice means on this bot.
    static func approvalsCaption(_ settings: BotWorkSettings, botName: String) -> String {
        switch settings.approvals {
        case .chats where settings.chatApprovals == "off":
            return AppLocalization.string("Approvals are off for this bot in Hermes, so its chats and workstreams run without asking.")
        case .chats:
            return AppLocalization.string("Workstreams ask for approval as this bot’s chats do in Hermes.")
        case .ask where settings.chatApprovals == "off":
            return AppLocalization.string("Approvals are off for this bot in Hermes, so no approval card comes. Its workstreams are told to wait for your own go-ahead before a step that can’t be undone.")
        case .ask:
            return AppLocalization.string("Before a step that can’t be undone, workstreams wait for your own go-ahead, never \(botName)’s alone.")
        case .off:
            return AppLocalization.string("Workstreams run commands without asking for approval. Commands Hermes never runs stay blocked.")
        }
    }

    /// A control's binding: shows the change at once, saves it, and puts
    /// it back if the plugin didn't keep it.
    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<BotWorkSettings, Value>) -> Binding<Value> {
        Binding(
            get: { (settings ?? BotWorkSettings())[keyPath: keyPath] },
            set: { value in
                guard let old = settings, old[keyPath: keyPath] != value, !isSaving else { return }
                var new = old
                new[keyPath: keyPath] = value
                Haptics.light()
                settings = new
                Task { await save(new, from: old) }
            }
        )
    }

    /// The workstream model's reasoning: nil for the model's default.
    private var effortBinding: Binding<String?> {
        Binding(
            get: { settings?.workstreamModel.flatMap { $0.reasoningEffort.isEmpty ? nil : $0.reasoningEffort } },
            set: { effort in
                guard let old = settings, old.workstreamModel != nil, !isSaving else { return }
                var new = old
                new.workstreamModel?.reasoningEffort = effort ?? ""
                guard new.workstreamModel != old.workstreamModel else { return }
                Haptics.light()
                settings = new
                Task { await save(new, from: old) }
            }
        )
    }

    /// The picker's provider: kept until its model comes.
    private var providerBinding: Binding<String> {
        Binding(
            get: { pickedProvider.isEmpty ? (settings?.workstreamModel?.provider ?? "") : pickedProvider },
            set: { pickedProvider = $0 }
        )
    }

    /// The picker's model: saves the pick with its provider ("" for the
    /// Bot Chat's own).
    private var modelBinding: Binding<String> {
        Binding(
            get: { settings?.workstreamModel?.model ?? "" },
            set: { model in
                let provider = pickedProvider
                pickedProvider = ""
                guard let old = settings, !isSaving else { return }
                // A new model keeps the reasoning picked for the last one.
                let picked = model.isEmpty ? nil : BotWorkSettings.Model(
                    model: model, provider: provider, reasoningEffort: old.workstreamModel?.reasoningEffort ?? "")
                guard picked != old.workstreamModel else { return }
                var new = old
                new.workstreamModel = picked
                Haptics.light()
                settings = new
                Task { await save(new, from: old) }
            }
        )
    }

    /// The work watch's slot in this bot's profile, as the Helper models
    /// pages set it.
    private var watchModelSettings: VoiceReplyModelSettingsModel {
        let profile = profile
        let appState = appState
        return VoiceReplyModelSettingsModel(
            kept: { appState.keptHelperModel(task: HelperModelSlot.workWatch, inProfile: profile) },
            keptProviders: { appState.keptModelProviders(inProfile: profile) },
            load: { try await appState.loadHelperModel(task: HelperModelSlot.workWatch, inProfile: profile) },
            loadProviders: { await appState.loadModelProviders(inProfile: profile) },
            save: { await appState.setHelperModel($0, confirmed: $1, profile: profile) }
        )
    }

    /// Kept first, then Hermes, tried as often as the settings' read. A
    /// read that fails keeps what was shown; only the newest read's answer
    /// is shown.
    private func readWatchSlot() async {
        watchReads += 1
        let read = watchReads
        if watchSlot == nil {
            watchSlot = appState.keptHelperModels(inProfile: profile)?.first { $0.id == HelperModelSlot.workWatch }
        }
        for attempt in 0..<Self.loadAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(attempt))
                if Task.isCancelled { return }
            }
            if let loaded = try? await appState.loadHelperModels(inProfile: profile) {
                guard read == watchReads else { return }
                watchSlot = loaded.first { $0.id == HelperModelSlot.workWatch }
                return
            }
            if Task.isCancelled || read != watchReads { return }
        }
    }

    /// A read can miss while the dashboard's bridge settles (a reconnect, a
    /// busy plugin), so it tries again twice, a second and then two apart,
    /// before saying it couldn't (Eric 2026-11-03).
    private func load() async {
        loadFailed = false
        for attempt in 0..<Self.loadAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(attempt))
                if Task.isCancelled { return }
            }
            if let loaded = await appState.loadBotWorkSettings(profile: profile) {
                settings = loaded
                return
            }
            if Task.isCancelled { return }
        }
        if settings == nil { loadFailed = true }
    }

    static let loadAttempts = 3

    private func save(_ new: BotWorkSettings, from old: BotWorkSettings) async {
        isSaving = true
        defer { isSaving = false }
        if let saved = await appState.saveBotWorkSettings(new, from: old, profile: profile) {
            saveFailed = false
            settings = saved
        } else {
            saveFailed = true
            settings = old
        }
    }
}
