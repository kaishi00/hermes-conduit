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
            guard settings == nil else { return }
            await load()
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
                    choices: [
                        (id: BotWorkSettings.Policy.strict, title: AppLocalization.string("Only Coordinates")),
                        (id: BotWorkSettings.Policy.lookups, title: AppLocalization.string("Also Looks Things Up")),
                    ],
                    onSelect: { binding(\.policy).wrappedValue = $0 }
                ) {
                    Text(AppLocalization.string("What It Does Itself")).foregroundStyle(.secondary)
                }
                caption(settings.policy == .lookups
                    ? AppLocalization.string("It can also search the web, past chats and skills itself before starting work. Quicker for simple questions, but small models pick the wrong way more often.")
                    : AppLocalization.string("Anything that needs a tool goes to a workstream, so its Bot Chat stays free to talk."))
                Stepper(value: binding(\.maxRunning), in: 1...settings.maxRunningLimit) {
                    LabeledContent(AppLocalization.string("Running at Once")) {
                        Text(verbatim: "\(settings.maxRunning)")
                    }
                }
                caption(AppLocalization.string("When this many are running, \(botName) waits for one to finish or sends new work to one that’s already on it."))
            }
        }
        if settings.isOn {
            ConduitSettingsSection(title: AppLocalization.string("Workstream Model"), symbol: "cpu", tint: .purple) {
                NavigationLink {
                    BotModelPicker(provider: providerBinding, model: modelBinding, allowsInherit: true,
                                   inheritTitle: AppLocalization.string("Same as Bot Chat"))
                } label: {
                    SettingsLinkRow(
                        title: AppLocalization.string("Model"),
                        value: settings.workstreamModel?.model ?? AppLocalization.string("Same as Bot Chat")
                    )
                }
                .buttonStyle(.plain)
                if settings.workstreamModel != nil {
                    // Hermes' per-session reasoning, as the Model sheet offers it.
                    ConduitMenuPicker(
                        value: effortBinding.wrappedValue ?? "",
                        choices: [(id: "", title: AppLocalization.string("Default"))]
                            + ReasoningEffortLevel.allCases.map { (id: $0.rawValue, title: $0.title) },
                        onSelect: { effortBinding.wrappedValue = $0.isEmpty ? nil : $0 }
                    ) {
                        Text(AppLocalization.string("Reasoning")).foregroundStyle(.secondary)
                    }
                }
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
