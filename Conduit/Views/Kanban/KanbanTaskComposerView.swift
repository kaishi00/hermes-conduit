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
    @EnvironmentObject private var store: KanbanStore
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let initialStatus: String

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

    init(initialStatus: String) {
        self.initialStatus = initialStatus
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
            Form {
                basicsSection
                assignmentSection
                executionSection
                dependenciesSection
                laneSection
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(didCreate ? "Task created" : "New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didCreate ? "Close" : "Cancel") { dismiss() }
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
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSkillsSheet) {
                KanbanSkillsPickerSheet(selected: skillsBinding)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showParentSheet) {
                KanbanParentPickerSheet(
                    selectedParentID: parentBinding,
                    excludedTaskID: nil
                )
                .presentationDetents([.medium, .large])
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    // MARK: - Sections

    private var basicsSection: some View {
        Section("Basics") {
            TextField("Title", text: $draft.title)
                .accessibilityLabel("Task title")
            TextEditor(text: $draft.body)
                .frame(minHeight: 100)
                .accessibilityLabel("Task description")
            Picker("Priority", selection: $draft.priority) {
                Text("Normal").tag(0)
                Text("High").tag(1)
                Text("Urgent").tag(2)
                Text("Critical").tag(3)
            }
        }
    }

    private var assignmentSection: some View {
        Section {
            Picker("Assigned to", selection: assigneeSelectionBinding) {
                Text("Default (\(resolvedDefaultAssignee))")
                    .tag(KanbanAssigneeSelection.inheritDefault)
                ForEach(rosterWithoutDefault) { profile in
                    Text(profile.name).tag(KanbanAssigneeSelection.profile(profile.name))
                }
                Text("Parked (won't run)")
                    .tag(KanbanAssigneeSelection.parked)
            }
        } header: {
            Text("Assignment")
        } footer: {
            Text("Default uses Hermes' resolved default assignee (\(resolvedDefaultAssignee)). Parked leaves the task unassigned so no worker claims it.")
        }
    }

    private var executionSection: some View {
        Section {
            Picker("Workspace", selection: $draft.workspaceKind) {
                ForEach(KanbanWorkspaceKind.allCases) { kind in
                    Text(kind.displayName + (kind == boardDefaultKind ? " · board default" : ""))
                        .tag(kind)
                }
            }
            if draft.workspaceKind.allowsPathOverride {
                TextField(
                    boardDefaultDir != nil ? "Leave empty to inherit \(boardDefaultDir!)" : "Optional path override",
                    text: $draft.workspacePath
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Workspace path override")
                if let dir = boardDefaultDir {
                    Text("Leave empty to inherit the board's project directory: \(dir)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Leave empty to inherit the board's project directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            modelRow
            skillsRow
            goalModeRows
        } header: {
            Text("Execution")
        } footer: {
            if boardDefaultDir != nil && !draft.workspaceKind.allowsPathOverride {
                Text("The board's project directory (\(boardDefaultDir!)) applies to this task.")
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
                Text(draft.modelOverride.label(inheritCopy: "Inherit from profile"))
                    .font(.callout)
                    .foregroundStyle(draft.modelOverride.isInherited ? .secondary : .primary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
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
                Text(draft.skills.isEmpty ? "None" : "\(draft.skills.count) selected")
                    .font(.callout)
                    .foregroundStyle(draft.skills.isEmpty ? .secondary : .primary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityHint("Opens the task skill picker")
    }

    @ViewBuilder
    private var goalModeRows: some View {
        Toggle("Goal Mode", isOn: $draft.goalMode)
        if draft.goalMode {
            // Symmetric ladder: Unlimited -> 5 -> 10 -> 15 … and back down to
            // Unlimited; both directions walk the same rungs.
            Stepper(
                "Max turns: \(draft.goalMaxTurns.map(String.init) ?? "Unlimited")",
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dependenciesSection: some View {
        Section {
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
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                ForEach(draft.parents, id: \.self) { parentID in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parentTitle(for: parentID))
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Text(KanbanShortID.of(parentID))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            draft.parents.removeAll { $0 == parentID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .accessibilityLabel("Remove dependency \(parentTitle(for: parentID))")
                    }
                }
                Button {
                    showParentSheet = true
                } label: {
                    Label("Change…", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } header: {
            Text("Dependencies")
        } footer: {
            Text("The new task stays blocked until its parent completes.")
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
        Section {
            Label(statusPresentation.displayName, systemImage: statusPresentation.systemImage)
                .foregroundStyle(statusPresentation.tint)
            Text("The board selection is local to this device; creating this task will not switch Hermes' global board.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Lands in")
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
                Text(didCreate ? "Done" : "Create")
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
            _ = try await store.createTask(request, initialStatus: initialStatus)
            dismiss()
        } catch let error as KanbanDraftValidationError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
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
    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss
    @Binding var value: TaskModelOverride

    @State private var providers: [KanbanModelProviderOption] = []
    @State private var isLoadingOptions = false
    @State private var loadFailed = false
    @State private var query = ""
    @State private var expandedProvider: String?
    @State private var customProvider = ""
    @State private var customModel = ""

    private var inheritCopy: String { "Inherit from profile" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        value = TaskModelOverride()
                    } label: {
                        HStack {
                            Text(inheritCopy)
                            Spacer()
                            if value.isInherited {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.conduitAccent)
                            }
                        }
                    }
                    .disabled(value.isInherited)
                    .accessibilityHint("Uses the assigned profile's own model and reasoning settings")
                } footer: {
                    Text("An unset override runs the task on the assigned profile's own model, provider, and reasoning effort.")
                }

                reasoningSection
                catalogSection
                if loadFailed || providers.isEmpty {
                    customEntrySection
                }
            }
            .navigationTitle("Model override")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadOptions() }
            .onAppear(perform: seedCustomFields)
        }
    }

    private var reasoningSection: some View {
        Section("Reasoning effort") {
            Picker("Effort", selection: effortBinding) {
                Text("Inherit").tag("")
                ForEach(TaskModelOverride.validReasoningEfforts, id: \.self) { effort in
                    Text(displayEffort(effort)).tag(effort)
                }
            }
        }
    }

    private var filteredProviders: [KanbanModelProviderOption] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return providers }
        return providers.compactMap { provider in
            if provider.slug.lowercased().contains(trimmed) || provider.displayName.lowercased().contains(trimmed) {
                return provider
            }
            let models = provider.models.filter { $0.lowercased().contains(trimmed) }
            return models.isEmpty ? nil : KanbanModelProviderOption(slug: provider.slug, label: provider.label, models: models)
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        Section {
            if isLoadingOptions {
                HStack { ProgressView(); Text("Loading models…") }.foregroundStyle(.secondary)
            }
            ForEach(filteredProviders) { provider in
                providerDisclosure(provider)
            }
            if !isLoadingOptions && providers.isEmpty {
                Text("No curated model catalog available from Hermes — enter a provider and model below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Catalog")
        } footer: {
            Text("Curated by Hermes so a worker can always spawn what you pick.")
        }
    }

    private func providerDisclosure(_ provider: KanbanModelProviderOption) -> some View {
        DisclosureGroup(isExpanded: expandedBinding(provider.slug)) {
            ForEach(provider.models, id: \.self) { model in
                Button {
                    value = TaskModelOverride(provider: provider.slug, model: model, reasoningEffort: value.reasoningEffort)
                } label: {
                    HStack {
                        Text(model)
                        Spacer()
                        if isSelected(provider.slug, model) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.conduitAccent)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        } label: {
            Text(provider.displayName)
        }
    }

    private var customEntrySection: some View {
        Section("Custom (free text)") {
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
        effort == "none" ? "None (thinking off)" : effort.capitalized.replacingOccurrences(of: "Xhigh", with: "Extra High")
    }

    private func seedCustomFields() {
        customProvider = value.provider ?? ""
        customModel = value.model ?? ""
    }

    private func loadOptions() async {
        guard providers.isEmpty else { return }
        isLoadingOptions = true
        defer { isLoadingOptions = false }
        do {
            providers = try await store.fetchModelOptions().filter { !$0.models.isEmpty }
            // Pre-expand the provider matching the current override.
            if let current = value.provider,
               let match = providers.first(where: { $0.slug == current }) {
                expandedProvider = match.slug
            }
        } catch {
            loadFailed = true
        }
    }
}

// MARK: - Skills picker

/// Task-specific skill multi-select. This selects WHICH skills a task uses;
/// it deliberately does not enable/disable profile capabilities (that remains
/// Capabilities Settings' job). Seeds from the active Hermes configuration's
/// skill list and allows manual entry for anything unlisted (upstream accepts
/// arbitrary comma-separated names).
struct KanbanSkillsPickerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: [String]

    @State private var query = ""
    @State private var customName = ""

    private var availableSkills: [CapabilitySkill] {
        appState.skills
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
            Form {
                if !selected.isEmpty {
                    Section("Selected") {
                        ForEach(selected, id: \.self) { name in
                            HStack {
                                Text(name)
                                Spacer()
                                Button {
                                    selected.removeAll { $0 == name }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("Remove skill \(name)")
                            }
                        }
                    }
                }

                Section {
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
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                if isSelected(skill.name) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.conduitAccent)
                                }
                            }
                        }
                        .accessibilityLabel("Skill \(skill.name)")
                        .accessibilityHint(isSelected(skill.name) ? "Selected" : "Not selected")
                    }
                    if filteredSkills.isEmpty {
                        Text("No skills match.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Available skills")
                }

                Section("Add manually") {
                    HStack {
                        TextField("skill-name", text: $customName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Add") { addCustom() }
                            .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search skills")
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
    @EnvironmentObject private var store: KanbanStore
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
            Form {
                Button {
                    selectedParentID = nil
                } label: {
                    HStack {
                        Text("— no parent —")
                        Spacer()
                        if selectedParentID == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.conduitAccent)
                        }
                    }
                }
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
                                        .font(.caption2.monospaced())
                                    Text(KanbanStatusPresentation.forStatus(task.status).displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selectedParentID == task.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.conduitAccent)
                            }
                        }
                    }
                }
                if candidates.isEmpty {
                    Text("No other tasks on this board.")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Search tasks")
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
