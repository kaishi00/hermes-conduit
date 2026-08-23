import SwiftUI

/// V3B: Board administration editor — one native sheet for New Board and
/// Board Settings.
///
/// Ownership follows the V2/V3A editor discipline:
/// - seeded once from an immutable server baseline; dirty = draft vs baseline;
/// - the mutation identity (concrete board slug, board/server stamp) and the
///   submitted patch/payload are frozen synchronously in the tap handler
///   BEFORE any Task is spawned;
/// - the store revalidates the captured stamp back-to-back with its operation
///   capture (Settings is board-scoped; creation is server-scoped);
/// - a stale completion is UI-inert, while the local busy flag is still
///   released through the liveness token;
/// - controls are disabled while saving, so a completion can never clobber an
///   in-flight edit.
enum KanbanBoardEditorMode {
    case create
    case settings(board: KanbanBoardMetadata)
}

struct KanbanBoardEditorView: View {
    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss

    private let mode: KanbanBoardEditorMode
    /// Matches the board's Show Archived state so every post-mutation
    /// reconcile preserves the visible snapshot (review W2).
    private let includeArchived: Bool

    @State private var name = ""
    @State private var descriptionText = ""
    @State private var projectID: String?
    @State private var workspaceRow: WorkspaceRow = .none
    @State private var customPath = ""
    @State private var slug = ""
    @State private var manualSlug = false
    /// The most recent AUTHORITATIVE server metadata this editor accepted —
    /// the wire baseline for every PATCH. Advances on every successful Save
    /// so a later save is never compared against the sheet-opening state
    /// (review 2). mode.settings(board:) stays valuable only for the original
    /// target slug + initial seed.
    @State private var serverBaseline: KanbanBoardMetadata?
    @State private var seedDraft: KanbanBoardEditorDraft?
    @State private var isSaving = false
    @State private var liveness = KanbanEditorLiveness()
    @State private var notice: String?
    @State private var errorMessage: String?

    /// The PICKER row is a plain enum: a typed path lives in customPath and
    /// is folded in at submit time — never embedded in a Picker tag (review
    /// W1: an empty tag value would silently drop the typed path).
    enum WorkspaceRow: Hashable {
        case projectDefault
        case none
        case custom
    }

    init(mode: KanbanBoardEditorMode, includeArchived: Bool = false) {
        self.mode = mode
        self.includeArchived = includeArchived
    }

    private var board: KanbanBoardMetadata? {
        if case .settings(let board) = mode { return board }
        return nil
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private var resolvedSlug: String {
        if manualSlug { return slug.trimmingCharacters(in: .whitespacesAndNewlines) }
        return KanbanBoardSlugPolicy.derivedSlug(from: name)
    }

    private var hasValidSlug: Bool {
        KanbanBoardSlugPolicy.isValid(resolvedSlug)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveWorkspaceChoice: KanbanDefaultWorkspaceChoice {
        switch workspaceRow {
        case .projectDefault: return .projectDefault
        case .none: return .none
        case .custom: return .custom(customPath.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private var currentDraft: KanbanBoardEditorDraft {
        KanbanBoardEditorDraft(
            name: trimmedName,
            description: descriptionText,
            projectID: projectID,
            workspace: normalizedWorkspaceChoice
        )
    }

    private var isDirty: Bool {
        guard let seedDraft else { return false }
        return currentDraft != seedDraft
    }

    /// Effective-directory PREVIEW from the CURRENT DRAFT: selecting another
    /// project immediately shows its primary repo — never the sheet-opening
    /// board's stale workdir (review 3/G).
    private var effectiveDirectory: String? {
        KanbanBoardWorkspacePresentation.previewDirectory(
            workspace: effectiveWorkspaceChoice,
            projectID: projectID,
            projects: store.projects
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                basicsSection
                projectSection
                workspaceSection
                if let effective = effectiveDirectory {
                    Section {
                        Label(effective, systemImage: "folder")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } header: {
                        Text("Effective Directory")
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if let notice {
                    Section {
                        Label(notice, systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isCreate ? "New Board" : "Board Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isCreate ? "Cancel" : "Close") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submitTapped()
                    } label: {
                        if isSaving { ProgressView() } else { Text(isCreate ? "Create" : "Save") }
                    }
                    .disabled(!canSubmit || isSaving)
                }
            }
            .onAppear(perform: seedOnce)
        }
        .interactiveDismissDisabled(isSaving)
        // Board Settings belongs to a CONCRETE loaded board: dismiss it the
        // moment the loaded board identity changes (the store fails closed
        // underneath even if a race slips through).
        .onChange(of: store.loadedBoardSlug) { _, _ in
            if !isCreate { dismiss() }
        }
    }

    private var canSubmit: Bool {
        if isCreate {
            return hasValidSlug && !trimmedName.isEmpty
        }
        return isDirty
    }

    private var basicsSection: some View {
        Section {
            TextField("Name", text: $name)
                .accessibilityLabel("Board name")
            if isCreate {
                Toggle("Edit slug manually", isOn: $manualSlug)
                    .font(.footnote)
                    .accessibilityLabel("Edit slug manually (advanced)")
                if manualSlug {
                    TextField("Slug", text: $slug)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Board slug")
                        .overlay(alignment: .trailing) {
                            if !hasValidSlug && !slug.isEmpty {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .accessibilityLabel("Invalid slug")
                            }
                        }
                } else {
                    Text("Slug: \(resolvedSlug)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Generated slug \(resolvedSlug)")
                }
            } else if let board {
                LabeledContent("Slug", value: board.slug)
                    .accessibilityLabel("Slug is immutable: \(board.slug)")
            }
            TextEditor(text: $descriptionText)
                .frame(minHeight: 90)
                .accessibilityLabel("Board description")
        } header: {
            Text("Basics")
        } footer: {
            if isCreate && !trimmedName.isEmpty && !hasValidSlug {
                Text("The slug must be 1-64 lowercase letters or numbers, with hyphens or underscores after the first character.")
            } else if isCreate {
                Text("The slug is generated from the name (like Desktop) and cannot be changed after creation.")
            } else {
                Text("The slug is immutable after creation.")
            }
        }
        .disabled(isSaving)
    }

    private var projectSection: some View {
        Section {
            Picker("Project", selection: projectBinding) {
                Text("No Project").tag(String?.none)
                ForEach(store.projects) { project in
                    Text(project.name).tag(String?.some(project.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Project scope")
            if store.projects.isEmpty {
                Text("No projects on this server yet — the board stays unscoped (scratch workspaces).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Project")
        }
        .disabled(isSaving)
    }

    private var projectBinding: Binding<String?> {
        Binding(
            get: { projectID },
            set: { newValue in
                projectID = newValue
                // Snapping: picking a project follows it by default; dropping
                // it returns to scratch - unless the user already entered a
                // custom directory.
                if newValue != nil {
                    if workspaceRow != .custom || customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        workspaceRow = .projectDefault
                    }
                } else if workspaceRow == .projectDefault {
                    workspaceRow = .none
                }
            }
        )
    }

    private var workspaceSection: some View {
        Section {
            Picker("Default Workspace", selection: $workspaceRow) {
                if projectID != nil {
                    // With a project selected, "None/Scratch" is not
                    // representable upstream: the server mirrors the project's
                    // primary repo whenever a project is set without an
                    // explicit workdir (review B-1). The row is hidden so the
                    // editor can never submit that phantom combination.
                    Text("Project Default").tag(WorkspaceRow.projectDefault)
                } else {
                    Text("None / Scratch").tag(WorkspaceRow.none)
                }
                Text("Custom Directory…").tag(WorkspaceRow.custom)
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Default workspace")
            if workspaceRow == .custom {
                TextField("Absolute directory path", text: $customPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Custom workspace directory")
            }
        } header: {
            Text("Default Workspace")
        } footer: {
            if projectID != nil, workspaceRow == .projectDefault {
                Text("New tasks mirror the project's primary repository.")
            } else if workspaceRow == .none {
                Text("New tasks use scratch workspaces.")
            }
        }
        .disabled(isSaving)
    }

    private func seedOnce() {
        guard seedDraft == nil, let board else { return }
        serverBaseline = board
        let effectiveProject = (board.projectID ?? "").isEmpty ? nil : board.projectID
        let derivedWorkspace = KanbanBoardWorkspacePresentation.derive(from: board, projects: store.projects)
        applyWorkspacePresentation(derivedWorkspace)
        name = board.name ?? ""
        descriptionText = board.description ?? ""
        projectID = effectiveProject
        slug = board.slug
        seedDraft = currentDraft
    }

    /// The ONE path that materializes a workspace representation into the
    /// editor rows (initial seed AND post-save authoritative echo).
    private func applyWorkspacePresentation(_ derived: KanbanDefaultWorkspaceChoice) {
        switch derived {
        case .projectDefault:
            workspaceRow = .projectDefault
        case .none:
            workspaceRow = .none
        case .custom(let path):
            workspaceRow = .custom
            customPath = path
        }
    }

    /// Synchronous tap handler: freezes the mutation identity (concrete slug
    /// for settings; server scope for create), the submitted payload/patch,
    /// the server generation and the busy state BEFORE scheduling.
    private func submitTapped() {
        guard canSubmit, !isSaving,
              let stamp = store.loadedContextStamp else { return }
        let generation = store.currentConfigurationGeneration
        let operationID = liveness.begin()
        isSaving = true
        errorMessage = nil
        notice = nil
        let draft = currentDraft
        if isCreate {
            let request = KanbanBoardPatchPolicy.createRequest(
                slug: resolvedSlug,
                name: trimmedName,
                description: descriptionText,
                projectID: draft.projectID,
                workspace: draft.workspace
            )
            Task {
                await performCreate(
                    request: request,
                    context: stamp,
                    generation: generation,
                    operationID: operationID
                )
            }
        } else {
            guard let baseline = serverBaseline else {
                if liveness.owns(operationID) { isSaving = false }
                return
            }
            // PATCH built from the LATEST authoritative metadata this editor
            // accepted — never the sheet-opening state (review 2/E).
            let patch = KanbanBoardPatchPolicy.patch(baseline: baseline, draft: draft, projects: store.projects)
            let targetSlug = baseline.slug
            Task {
                await performUpdate(
                    slug: targetSlug,
                    patch: patch,
                    context: stamp,
                    generation: generation,
                    operationID: operationID
                )
            }
        }
    }

    /// .projectDefault with no project selected is not a legal wire state;
    /// fall back to playing it safe (no workdir change implied).
    private var normalizedWorkspaceChoice: KanbanDefaultWorkspaceChoice {
        if workspaceRow == .projectDefault, (projectID ?? "").isEmpty {
            return .none
        }
        return effectiveWorkspaceChoice
    }

    private func performCreate(
        request: KanbanCreateBoardRequest,
        context: KanbanBoardContextStamp,
        generation: Int,
        operationID: Int
    ) async {
        do {
            _ = try await store.createBoard(request, expectedContext: context, includeArchived: includeArchived)
            if liveness.owns(operationID) { isSaving = false }
            guard store.isCurrentConfiguration(generation) else { return }
            // The sheet dismisses: the authoritative reload already switched
            // the UI onto the new board, which IS the feedback (review A-1).
            dismiss()
        } catch {
            if liveness.owns(operationID) { isSaving = false }
            guard store.isCurrentConfiguration(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func performUpdate(
        slug: String,
        patch: KanbanUpdateBoardPatch,
        context: KanbanBoardContextStamp,
        generation: Int,
        operationID: Int
    ) async {
        guard !patch.isEmpty else {
            if liveness.owns(operationID) { isSaving = false }
            return
        }
        do {
            // Concurrent completions cannot race the baseline: the store's
            // single-live-mutation gate serializes PATCHes and this editor's
            // liveness token discards echoes from older operations.
            let updated = try await store.updateBoard(
                slug: slug,
                patch: patch,
                expectedContext: context,
                includeArchived: includeArchived
            )
            if liveness.owns(operationID) { isSaving = false }
            guard store.isCurrentConfiguration(generation) else { return }
            // The authoritative echo ADVANCES the server baseline FIRST; the
            // workspace rows materialize through the same canonical
            // derivation as the initial seed (review 3/D).
            serverBaseline = updated
            let derived = KanbanBoardWorkspacePresentation.derive(from: updated, projects: store.projects)
            applyWorkspacePresentation(derived)
            name = updated.name ?? ""
            descriptionText = updated.description ?? ""
            projectID = (updated.projectID ?? "").isEmpty ? nil : updated.projectID
            seedDraft = currentDraft
            notice = "Board settings saved."
        } catch {
            if liveness.owns(operationID) { isSaving = false }
            guard store.isCurrentConfiguration(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }
}
