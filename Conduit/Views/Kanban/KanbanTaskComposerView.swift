import SwiftUI

/// Mobile-native New Task composer (Kanban V2).
///
/// Desktop-parity semantics (see docs/KANBAN_V2_AUDIT.md) in a grouped,
/// push/sheet-driven iPhone form:
/// - Assignment follows Hermes Default/Profile/Parked exactly: Default sends
///   the orchestration-resolved assignee, Parked omits the field.
/// - The workspace selection initializes from the SELECTED BOARD's real
///   `default_workspace_kind` (backend fallback scratch) and shows the board's
///   inherited `default_workdir`.
/// - Model/provider/reasoning is detached form state — nothing here mutates a
///   live chat session.
/// - Skills are task-specific selections serialized exactly as the backend
///   expects (trimmed string array), not capability toggles.
/// - Goal Mode maps to `goal_mode` (+ optional `goal_max_turns`); it is NOT
///   Conduit's chat YOLO setting.
struct KanbanTaskComposerView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(KanbanStore.self) private var store
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let initialStatus: String
    /// The board the sheet was opened for: creating fails if another has
    /// loaded since.
    let expectedContext: KanbanBoardContextStamp?

    @State private var draft = KanbanComposerDraft()
    @State private var isSaving = false
    @State private var didCreate = false
    @State private var errorMessage: String?
    /// Board defaults can land after the sheet opens; seed once, never fight
    /// an explicit user choice.
    @State private var didSeedWorkspaceFromBoard = false

    @State private var showModelSheet = false
    @State private var showSkillsSheet = false
    @State private var showParentSheet = false

    init(initialStatus: String, expectedContext: KanbanBoardContextStamp?) {
        self.initialStatus = initialStatus
        self.expectedContext = expectedContext
    }

    private var statusPresentation: KanbanStatusPresentation {
        KanbanStatusPresentation.forStatus(initialStatus)
    }

    /// Upstream New Task dialog: `useOrchestration()?.resolved_default_assignee || 'default'`.
    private var resolvedDefaultAssignee: String {
        let resolved = store.orchestration?.resolvedDefaultAssignee.trimmingCharacters(in: .whitespaces) ?? ""
        return resolved.isEmpty ? "default" : resolved
    }

    private var boardMetadata: KanbanBoardMetadata? {
        store.selectedBoardMetadata
    }

    private var rosterWithoutDefault: [KanbanProfile] {
        store.profiles.filter { $0.name != resolvedDefaultAssignee }
    }

    var body: some View {
        NavigationStack {
            SettingsDetailContainer {
                basicsSection
                assignmentSection
                executionSection
                dependenciesSection
                laneSection
                if let errorMessage {
                    SettingsCard {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .scaledFont(.footnote)
                    }
                }
            }
            // Text fields as Settings draws them.
            .textFieldStyle(.roundedBorder)
            .tint(.conduitAccent)
            .navigationTitle(didCreate ? AppLocalization.string("Task created") : AppLocalization.string("New task"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didCreate ? AppLocalization.string("Close") : AppLocalization.string("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    creationButton
                }
            }
            .onAppear(perform: seedWorkspaceFromBoard)
            .onChange(of: boardMetadata?.defaultWorkspaceKind) { _, _ in
                seedWorkspaceFromBoard()
            }
            .sheet(isPresented: $showModelSheet) {
                KanbanModelOverrideSheet(value: modelOverrideBinding)
                    .environment(store)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSkillsSheet) {
                KanbanSkillsPickerSheet(selected: skillsBinding)
                    .environmentObject(appState)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showParentSheet) {
                KanbanParentPickerSheet(
                    selectedParentID: parentBinding,
                    excludedTaskID: nil
                )
                .environment(store)
                .presentationDetents([.medium, .large])
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    // MARK: - Sections

    private var basicsSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Basics"), symbol: "square.and.pencil", tint: .conduitAccent) {
            TextField("Title", text: $draft.title)
                .accessibilityLabel("Task title")
            TextEditor(text: $draft.body)
                .frame(minHeight: 100)
                .settingsEditorBox()
                // The empty editor says what it's for, as the Title field does.
                .overlay(alignment: .topLeading) {
                    if draft.body.isEmpty {
                        Text(AppLocalization.string("Description"))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Task description")
            ConduitMenuPicker(
                value: draft.priority,
                choices: [
                    (id: 0, title: AppLocalization.string("Normal")),
                    (id: 1, title: AppLocalization.string("High")),
                    (id: 2, title: AppLocalization.string("Urgent")),
                    (id: 3, title: AppLocalization.string("Critical")),
                ],
                onSelect: { draft.priority = $0 }
            ) {
                Text("Priority").foregroundStyle(.secondary)
            }
        }
    }

    private var assignmentSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Assignment"), symbol: "person.crop.circle", tint: .conduitAccent) {
            ConduitMenuPicker(
                value: assigneeSelectionBinding.wrappedValue,
                choices: [(id: KanbanAssigneeSelection.inheritDefault, title: AppLocalization.string("Default (\(resolvedDefaultAssignee))"))]
                    + rosterWithoutDefault.map { (id: KanbanAssigneeSelection.profile($0.name), title: $0.name) }
                    + [(id: KanbanAssigneeSelection.parked, title: AppLocalization.string("Parked (won't run)"))],
                onSelect: { assigneeSelectionBinding.wrappedValue = $0 }
            ) {
                Text("Assigned to").foregroundStyle(.secondary)
            }
            Text("Default uses Hermes' resolved default assignee (\(resolvedDefaultAssignee)). Parked leaves the task unassigned so no worker claims it.")
                .settingsCaption()
        }
    }

    private var executionSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Execution"), symbol: "gearshape.2", tint: .conduitAccent) {
            ConduitMenuPicker(
                value: draft.workspaceKind,
                choices: KanbanWorkspaceKind.allCases.map { kind in
                    (id: kind, title: kind.displayName + (kind == boardDefaultKind ? AppLocalization.string(" · board default") : ""))
                },
                onSelect: { draft.workspaceKind = $0 }
            ) {
                Text("Workspace").foregroundStyle(.secondary)
            }
            if draft.workspaceKind.allowsPathOverride {
                TextField(
                    boardDefaultDir != nil ? AppLocalization.string("Leave empty to inherit \(boardDefaultDir!)") : AppLocalization.string("Optional path override"),
                    text: $draft.workspacePath
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Workspace path override")
                if let dir = boardDefaultDir {
                    Text("Leave empty to inherit the board's project directory: \(dir)")
                        .settingsCaption()
                } else {
                    Text("Leave empty to inherit the board's project directory.")
                        .settingsCaption()
                }
            }

            modelRow
            skillsRow
            goalModeRows
            if boardDefaultDir != nil && !draft.workspaceKind.allowsPathOverride {
                Text("The board's project directory (\(boardDefaultDir!)) applies to this task.")
                    .settingsCaption()
            }
        }
    }

    private var boardDefaultKind: KanbanWorkspaceKind {
        KanbanWorkspaceKind.initialKind(boardDefault: boardMetadata?.defaultWorkspaceKind)
    }

    private var boardDefaultDir: String? {
        guard let dir = boardMetadata?.defaultWorkdir?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty else { return nil }
        return dir
    }

    private var modelRow: some View {
        Button {
            showModelSheet = true
        } label: {
            HStack {
                Text("Model")
                    .foregroundStyle(.primary)
                Spacer()
                Text(draft.modelOverride.label(inheritCopy: AppLocalization.string("Inherit from profile")))
                    .scaledFont(.callout)
                    .foregroundStyle(draft.modelOverride.isInherited ? .secondary : .primary)
                    .lineLimit(1)
                SettingsChevron()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        // Plain, with a primary title: a row that opens something, as in
        // Settings (see Sheets in Settings' look).
        .buttonStyle(.plain)
        .accessibilityHint("Opens the per-task model, provider, and reasoning override picker")
    }

    private var skillsRow: some View {
        Button {
            showSkillsSheet = true
        } label: {
            HStack {
                Text("Skills")
                    .foregroundStyle(.primary)
                Spacer()
                Text(draft.skills.isEmpty ? AppLocalization.string("None") : AppLocalization.string("\(draft.skills.count) selected"))
                    .scaledFont(.callout)
                    .foregroundStyle(draft.skills.isEmpty ? .secondary : .primary)
                SettingsChevron()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        // Plain, with a primary title: a row that opens something, as in
        // Settings (see Sheets in Settings' look).
        .buttonStyle(.plain)
        .accessibilityHint("Opens the task skill picker")
    }

    @ViewBuilder
    private var goalModeRows: some View {
        Toggle("Goal Mode", isOn: $draft.goalMode)
        if draft.goalMode {
            // Symmetric ladder: Unlimited -> 5 -> 10 -> 15 … and back down to
            // Unlimited; both directions walk the same rungs.
            Stepper(
                "Max turns: \(draft.goalMaxTurns.map(String.init) ?? AppLocalization.string("Unlimited"))",
                onIncrement: {
                    let base = draft.goalMaxTurns ?? 0
                    draft.goalMaxTurns = min(10_000, base + 5)
                },
                onDecrement: {
                    guard let current = draft.goalMaxTurns else { return }
                    draft.goalMaxTurns = current <= 5 ? nil : current - 5
                }
            )
            .accessibilityHint("Bounds how long the Goal Mode worker may loop")
            Text("The worker loops until a judge agrees the goal is met. Leave unlimited only with caution.")
                .settingsCaption()
        }
    }

    private var dependenciesSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Dependencies"), symbol: "link", tint: .conduitAccent) {
            if draft.parents.isEmpty {
                Button {
                    showParentSheet = true
                } label: {
                    HStack {
                        Text("Depends on")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("None")
                            .foregroundStyle(.secondary)
                        SettingsChevron()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ForEach(draft.parents, id: \.self) { parentID in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parentTitle(for: parentID))
                                .scaledFont(.subheadline)
                                .foregroundStyle(.primary)
                            Text(KanbanShortID.of(parentID))
                                .scaledFont(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            draft.parents.removeAll { $0 == parentID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove dependency \(parentTitle(for: parentID))")
                    }
                }
                Button {
                    showParentSheet = true
                } label: {
                    Label("Change…", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.settings)
            }
            Text("The new task stays blocked until its parent completes.")
                .settingsCaption()
        }
    }

    private func parentTitle(for id: String) -> String {
        guard let title = store.board?.columns.flatMap(\.tasks).first(where: { $0.id == id })?.title,
              !title.isEmpty else {
            // Parent left the snapshot (or was filtered); the short ID stays
            // a stable, honest label until the next board load.
            return KanbanShortID.of(id)
        }
        return title
    }

    private var laneSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Lands in"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
            Label(statusPresentation.displayName, systemImage: statusPresentation.systemImage)
                .foregroundStyle(statusPresentation.tint)
            Text("The board selection is local to this device; creating this task will not switch Hermes' global board.")
                .settingsCaption()
        }
    }

    // MARK: - Bindings

    private var assigneeSelectionBinding: Binding<KanbanAssigneeSelection> {
        Binding(
            get: { draft.assignee },
            set: { draft.assignee = $0 }
        )
    }

    private var modelOverrideBinding: Binding<TaskModelOverride> {
        Binding(
            get: { draft.modelOverride },
            set: { draft.modelOverride = $0 }
        )
    }

    private var skillsBinding: Binding<[String]> {
        Binding(
            get: { draft.skills },
            set: { draft.skills = $0 }
        )
    }

    private var parentBinding: Binding<String?> {
        Binding(
            get: { draft.parents.first },
            set: { newValue in
                // Desktop exposes a SINGLE parent even though the API accepts
                // multiple; match the product behavior.
                draft.parents = newValue.map { [$0] } ?? []
            }
        )
    }

    // MARK: - Creation

    private var creationButton: some View {
        Button {
            if didCreate {
                dismiss()
            } else {
                Task { await create() }
            }
        } label: {
            if isSaving {
                ProgressView()
            } else {
                Text(didCreate ? AppLocalization.string("Done") : AppLocalization.string("Create"))
            }
        }
        // Double-submission guard: the saving flag disables re-entry while the
        // request is in flight, and `didCreate` flips the button to Done.
        // Parentheses make the intended grouping explicit:
        // (empty title AND not-yet-created) OR saving right now.
        .disabled((draft.trimmedTitle.isEmpty && !didCreate) || isSaving)
    }

    private func seedWorkspaceFromBoard() {
        guard !didSeedWorkspaceFromBoard else { return }
        guard let metadata = boardMetadata else { return }
        // Derive the initial editor value from the board's REAL configured
        // default (desktop parity), falling back to scratch only when the
        // board carries no default workspace kind. Deliberately ONCE: after
        // this first seed the selection belongs to the operator — silently
        // rewriting it because board metadata refreshed mid-composition
        // would discard an explicit choice.
        draft.workspaceKind = KanbanWorkspaceKind.initialKind(boardDefault: metadata.defaultWorkspaceKind)
        didSeedWorkspaceFromBoard = true
    }

    private func create() async {
        guard !isSaving, !didCreate else { return }
        do {
            // One validation layer decides whether this draft may become a
            // request; views never hand-roll ad hoc checks.
            let request = try KanbanComposerValidator.makeRequest(
                from: draft,
                resolvedDefaultAssignee: resolvedDefaultAssignee
            )
            isSaving = true
            errorMessage = nil
            defer { isSaving = false }
            _ = try await store.createTask(request, initialStatus: initialStatus, expectedContext: expectedContext)
            dismiss()
        } catch let error as KanbanDraftValidationError {
            errorMessage = UserFacingError.message(for: error)
        } catch {
            errorMessage = UserFacingError.message(for: error)
            if let kanbanError = error as? KanbanServiceError,
               case .taskCreatedButMoveFailed = kanbanError {
                // Partial success: the task EXISTS but could not be moved into
                // the requested lane. Flip to the Done state so the user cannot
                // resubmit and duplicate it.
                didCreate = true
            }
        }
    }
}

// MARK: - Model override sheet

/// Provider → Model → Reasoning selection backed by the kanban plugin's
/// curated `/model-options` roster, with a free-text fallback when the server
/// inventory is unavailable. Entirely detached from any live session model.
struct KanbanModelOverrideSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(KanbanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var value: TaskModelOverride

    @State private var providers: [KanbanModelProviderOption] = []
    /// The roster shown is the one kept from last time (#1533): its models
    /// wait for Hermes' answer before one is picked.
    @State private var showsKept = false
    @State private var isLoadingOptions = false
    /// The plugin answered, or its read failed: until then the sheet is
    /// loading, so neither the empty roster's note nor the free-text entry
    /// shows.
    @State private var optionsAnswered = false
    @State private var loadFailed = false
    @State private var query = ""
    @State private var expandedProvider: String?
    @State private var customProvider = ""
    @State private var customModel = ""

    private var inheritCopy: String { AppLocalization.string("Inherit from profile") }

    var body: some View {
        NavigationStack {
            SettingsDetailContainer {
                SettingsCard {
                    Button {
                        value = TaskModelOverride()
                    } label: {
                        HStack {
                            Text(inheritCopy)
                                .foregroundStyle(.primary)
                            Spacer()
                            if value.isInherited {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.conduitAccent)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(value.isInherited)
                    .accessibilityHint("Uses the assigned profile's own model and reasoning settings")
                    Text("An unset override runs the task on the assigned profile's own model, provider, and reasoning effort.")
                        .settingsCaption()
                }

                reasoningSection
                catalogSection
                if loadFailed || (optionsAnswered && providers.isEmpty) {
                    customEntrySection
                }
            }
            // Text fields as Settings draws them.
            .textFieldStyle(.roundedBorder)
            .tint(.conduitAccent)
            .searchable(text: $query, prompt: Text(AppLocalization.string("Search providers or models")))
            .navigationTitle("Model override")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadOptions() }
            .onAppear {
                seedCustomFields()
                showKept()
            }
        }
    }

    private var reasoningSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Reasoning effort"), symbol: "brain", tint: .conduitAccent) {
            ConduitMenuPicker(
                value: effortBinding.wrappedValue,
                choices: [(id: "", title: AppLocalization.string("Inherit"))]
                    + TaskModelOverride.validReasoningEfforts.map { (id: $0, title: displayEffort($0)) },
                onSelect: { effortBinding.wrappedValue = $0 }
            ) {
                Text("Effort").foregroundStyle(.secondary)
            }
        }
    }

    /// Search matches across providers, each naming its provider: several
    /// often serve the same model.
    private var searchMatches: [KanbanModelSearchMatch] {
        let search = ModelSearchQuery(query)
        guard !search.isEmpty else { return [] }
        return providers.flatMap { provider in
            provider.models
                .filter { search.matches([$0, provider.slug, provider.displayName]) }
                .map { KanbanModelSearchMatch(provider: provider, model: $0) }
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Catalog"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
            // Over a kept roster, nothing comes or goes when Hermes answers.
            if isLoadingOptions || !optionsAnswered, !showsKept {
                HStack { ProgressView(); Text("Loading models…") }.foregroundStyle(.secondary)
            }
            if ModelSearchQuery(query).isEmpty {
                ForEach(providers) { provider in
                    providerDisclosure(provider)
                }
            } else {
                let matches = searchMatches
                if matches.isEmpty {
                    Text(verbatim: AppLocalization.string("Nothing matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”."))
                        .foregroundStyle(.secondary)
                }
                ForEach(matches) { match in
                    modelButton(match.model, provider: match.provider, showsProvider: true)
                }
            }
            if loadFailed {
                // A failed read keeps the roster shown, under this.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Could not load models.")
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        loadFailed = false
                        Task { await loadOptions() }
                    }
                }
            } else if optionsAnswered && !isLoadingOptions && providers.isEmpty {
                Text("No curated model catalog available from Hermes — enter a provider and model below.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Curated by Hermes so a worker can always spawn what you pick.")
                .settingsCaption()
        }
    }

    private func providerDisclosure(_ provider: KanbanModelProviderOption) -> some View {
        DisclosureGroup(isExpanded: expandedBinding(provider.slug)) {
            ForEach(provider.models, id: \.self) { model in
                modelButton(model, provider: provider, showsProvider: false)
            }
        } label: {
            Text(provider.displayName)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    private func modelButton(_ model: String, provider: KanbanModelProviderOption, showsProvider: Bool) -> some View {
        let selected = isSelected(provider.slug, model)
        return Button {
            value = TaskModelOverride(provider: provider.slug, model: model, reasoningEffort: value.reasoningEffort)
        } label: {
            HStack {
                if showsProvider {
                    ModelSearchResultText(title: model, provider: provider.displayName)
                } else {
                    Text(model)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.conduitAccent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(showsKept)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customEntrySection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Custom (free text)"), symbol: "pencil", tint: .conduitAccent) {
            TextField("Provider", text: $customProvider)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Model", text: $customModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Use this override") {
                let provider = customProvider.trimmingCharacters(in: .whitespaces)
                let model = customModel.trimmingCharacters(in: .whitespaces)
                value = TaskModelOverride(
                    provider: provider.isEmpty ? nil : provider,
                    model: model.isEmpty ? nil : model,
                    reasoningEffort: value.reasoningEffort
                )
            }
            .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var effortBinding: Binding<String> {
        Binding(
            get: { value.reasoningEffort ?? "" },
            set: { value.reasoningEffort = $0.isEmpty ? nil : $0 }
        )
    }

    private func expandedBinding(_ slug: String) -> Binding<Bool> {
        Binding(
            get: { expandedProvider == slug },
            set: { expandedProvider = $0 ? slug : (expandedProvider == slug ? nil : expandedProvider) }
        )
    }

    private func isSelected(_ providerSlug: String, _ model: String) -> Bool {
        value.provider == providerSlug && value.model == model
    }

    private func displayEffort(_ effort: String) -> String {
        effort == "none" ? AppLocalization.string("None (thinking off)") : effort.capitalized.replacingOccurrences(of: "Xhigh", with: AppLocalization.string("Extra High"))
    }

    private func seedCustomFields() {
        customProvider = value.provider ?? ""
        customModel = value.model ?? ""
    }

    /// The roster as the picker listed it last time, while Hermes is asked
    /// again.
    private func showKept() {
        guard providers.isEmpty, let kept = store.keptModelOptions(), !kept.isEmpty else { return }
        providers = kept
        showsKept = true
        expandCurrentProvider()
    }

    private func loadOptions() async {
        guard providers.isEmpty || showsKept else { return }
        isLoadingOptions = true
        defer {
            isLoadingOptions = false
            optionsAnswered = true
        }
        do {
            providers = try await store.fetchModelOptions().filter { !$0.models.isEmpty }
            showsKept = false
            loadFailed = false
            expandCurrentProvider()
        } catch {
            loadFailed = true
        }
    }

    /// Pre-expands the provider matching the current override.
    private func expandCurrentProvider() {
        guard expandedProvider == nil, let current = value.provider,
              let match = providers.first(where: { $0.slug == current }) else { return }
        expandedProvider = match.slug
    }
}

/// One model the override sheet's search found, with its provider.
private struct KanbanModelSearchMatch: Identifiable {
    let provider: KanbanModelProviderOption
    let model: String

    var id: String { "\(provider.slug)\u{1F}\(model)" }
}

// MARK: - Skills picker

/// Task-specific skill multi-select. This selects WHICH skills a task uses;
/// it deliberately does not enable/disable profile capabilities (that remains
/// Capabilities Settings' job). Seeds from the active Hermes configuration's
/// skill list and allows manual entry for anything unlisted (upstream accepts
/// arbitrary comma-separated names).
struct KanbanSkillsPickerSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: [String]

    @State private var query = ""
    @State private var customName = ""

    /// The skills Capabilities last read, while they're this dashboard's
    /// and profile's: another dashboard's names are no suggestion here.
    /// Kept on the phone, so they're here before Capabilities opens (#1533).
    private var availableSkills: [CapabilitySkill] {
        appState.capabilitiesAreCurrent ? appState.skills : []
    }

    private var filteredSkills: [CapabilitySkill] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return availableSkills }
        return availableSkills.filter {
            $0.name.lowercased().contains(trimmed)
                || ($0.description ?? "").lowercased().contains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            SettingsDetailContainer {
                if !selected.isEmpty {
                    ConduitSettingsSection(title: AppLocalization.string("Selected"), symbol: "checkmark.circle", tint: .conduitAccent) {
                        ForEach(selected, id: \.self) { name in
                            HStack {
                                Text(name)
                                Spacer()
                                Button {
                                    selected.removeAll { $0 == name }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove skill \(name)")
                            }
                        }
                    }
                }

                ConduitSettingsSection(title: AppLocalization.string("Available skills"), symbol: "book", tint: .conduitAccent) {
                    ForEach(filteredSkills) { skill in
                        Button {
                            toggle(skill.name)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name)
                                        .foregroundStyle(.primary)
                                    if let description = skill.description, !description.isEmpty {
                                        Text(description)
                                            .settingsCaption()
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                if isSelected(skill.name) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.conduitAccent)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Skill \(skill.name)")
                        .accessibilityHint(isSelected(skill.name) ? AppLocalization.string("Selected") : AppLocalization.string("Not selected"))
                    }
                    if filteredSkills.isEmpty {
                        Text("No skills match.")
                            .foregroundStyle(.secondary)
                    }
                }

                ConduitSettingsSection(title: AppLocalization.string("Add manually"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
                    HStack {
                        TextField("skill-name", text: $customName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Add") { addCustom() }
                            .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            // Text fields as Settings draws them.
            .textFieldStyle(.roundedBorder)
            .tint(.conduitAccent)
            .searchable(text: $query, prompt: AppLocalization.string("Search skills"))
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { appState.showKeptCapabilities() }
    }

    private func isSelected(_ name: String) -> Bool {
        selected.contains(name)
    }

    private func toggle(_ name: String) {
        if isSelected(name) {
            selected.removeAll { $0 == name }
        } else {
            selected.append(name)
        }
    }

    private func addCustom() {
        let name = customName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !isSelected(name) {
            selected.append(name)
        }
        customName = ""
    }
}

// MARK: - Parent picker

/// Single-parent selection over the CURRENT BOARD snapshot, mirroring
/// Desktop's New Task dialog (one parent, even though the API accepts lists).
struct KanbanParentPickerSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(KanbanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedParentID: String?
    /// Edit flows pass the current task here so nothing can depend on itself.
    let excludedTaskID: String?

    @State private var query = ""

    private var candidates: [KanbanTask] {
        let all = (store.board?.columns ?? []).flatMap(\.tasks)
        let filtered = all.filter { $0.id != excludedTaskID }
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return filtered }
        return filtered.filter {
            $0.title.lowercased().contains(trimmed) || $0.id.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            SettingsDetailContainer {
                SettingsCard {
                    Button {
                        selectedParentID = nil
                    } label: {
                        HStack {
                            Text("— no parent —")
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedParentID == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.conduitAccent)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ForEach(candidates) { task in
                        Button {
                            selectedParentID = task.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        Text(KanbanShortID.of(task.id))
                                            .scaledFont(.caption2.monospaced())
                                        Text(KanbanStatusPresentation.forStatus(task.status).displayName)
                                            .scaledFont(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedParentID == task.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.conduitAccent)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if candidates.isEmpty {
                        Text("No other tasks on this board.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Text fields as Settings draws them.
            .textFieldStyle(.roundedBorder)
            .tint(.conduitAccent)
            .searchable(text: $query, prompt: AppLocalization.string("Search tasks"))
            .navigationTitle("Parent task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
