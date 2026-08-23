import SwiftUI

/// Task operator detail (Kanban V2).
///
/// Desktop drawer parity adapted to iPhone navigation:
/// - Assignment/reassignment through the DEDICATED `/reassign` endpoint
///   (reclaim-first, upstream default), never a generic assignee PATCH.
/// - Model/provider/reasoning override visible and editable where the backend
///   permits (PATCH with explicit clear flags), showing inheritance clearly.
/// - Diagnostics with the backend's structured recovery actions (reclaim,
///   copy CLI hint). No recovery mutation is ever invented from text.
/// - Dependencies (Blocked by / Blocks) with replace-current-detail tap
///   navigation — no recursive sheet stacks.
/// - Activity timeline mapping known event kinds to prose; unknown kinds get
///   a graceful fallback.
/// - Richer runs and a dedicated worker-log screen.
///
/// The V1 draft-safety core is PRESERVED: a 4-second poll refreshes comments,
/// runs, events, and metadata but never overwrites unsaved user edits; diffs
/// run against the last-synced server baseline.
struct KanbanTaskDetailView: View {
    /// Editable fields as last synced from the server. The draft fields below
    /// are compared against this so a poll can refresh collections WITHOUT
    /// ever overwriting unsaved user edits.
    private struct ServerBaseline: Equatable {
        var title: String
        var bodyText: String
        var status: String
    }

    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss

    private let initialTask: KanbanTask
    /// Replace-current-detail navigation target for dependency taps. The
    /// sheet never stacks another sheet; it swaps the displayed identity.
    @State private var displayedTaskID: String
    @State private var detail: KanbanTaskDetail?
    // Draft (editable) state — owned by the user until saved.
    @State private var title: String
    @State private var taskBody: String
    @State private var status: String
    @State private var baseline: ServerBaseline
    @State private var remoteChangeNotice: String?
    @State private var comment = ""
    @State private var isSaving = false
    @State private var isAddingComment = false
    @State private var isRequeuing = false
    @State private var isLoadingDetail = false
    @State private var showDeleteConfirmation = false
    @State private var showReassignSheet = false
    @State private var showModelSheet = false
    @State private var modelOverrideDraft = TaskModelOverride()
    /// The CURRENT model-editor sheet session: the task identity the sheet
    /// was opened for plus the SERVER override frozen at open time. "Did the
    /// user edit anything?" is always draft vs THIS baseline — never vs a
    /// later poll — so a no-edit dismissal can never overwrite a concurrent
    /// server change, and a session for task A can never commit against B.
    @State private var modelOverrideSession: KanbanModelOverrideSession?
    @State private var errorMessage: String?
    @State private var refreshErrorMessage: String?

    init(task: KanbanTask) {
        initialTask = task
        _displayedTaskID = State(initialValue: task.id)
        _title = State(initialValue: task.title)
        _taskBody = State(initialValue: task.body ?? "")
        _status = State(initialValue: task.status)
        _baseline = State(initialValue: ServerBaseline(title: task.title, bodyText: task.body ?? "", status: task.status))
    }

    /// The actionable task for the CURRENT displayed identity — the only
    /// object any task-specific render or mutation may go through — or nil
    /// while that identity's detail is loading / failed to load.
    ///
    /// INVARIANT: whenever non-nil, displayedTask.id == displayedTaskID.
    /// The opening task is a legal actionable task ONLY while the screen
    /// still displays the identity it opened with: after a dependency tap
    /// swaps the identity, a slow or failed replacement load must NEVER fall
    /// back to the previous task's data.
    private var displayedTask: KanbanTask? {
        KanbanDetailIdentityPolicy.actionableTask(
            displayedID: displayedTaskID,
            detailTask: detail?.task,
            initialTask: initialTask
        )
    }

    /// True once the displayed identity has an actionable task (loaded
    /// detail, or the still-current opening task).
    private var isDisplayedTaskLoaded: Bool {
        displayedTask != nil
    }

    private var isRunning: Bool {
        displayedTask?.status == "running"
    }

    private var hasUnsavedChanges: Bool {
        KanbanDetailDraftPolicy.isDirty(
            draftTitle: title,
            draftBody: taskBody,
            draftStatus: status,
            baselineTitle: baseline.title,
            baselineBodyText: baseline.bodyText,
            baselineStatus: baseline.status
        )
    }

    private var statusOptions: [KanbanStatusPresentation] {
        var values = KanbanStatusPresentation.manuallySelectableStatuses
        if !values.contains(where: { $0.rawValue == status }) {
            values.insert(KanbanStatusPresentation.forStatus(status), at: 0)
        }
        return values
    }

    private var hasDispatcherFallback: Bool {
        !(store.orchestration?.resolvedDefaultAssignee ?? "").isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Identity gate: while the displayed identity has no
                    // actionable task (a replacement detail is loading or
                    // failed), NO task-specific content renders or acts — the
                    // task this screen opened with must not leak through as
                    // the displayed task's data.
                    if let currentTask = displayedTask {
                        editorSection
                        assignmentExecutionSection
                        if currentTask.status == "ready", (currentTask.assignee ?? "").isEmpty, !hasDispatcherFallback {
                            readyUnassignedCallout
                        }
                        diagnosticsSection
                        dependenciesSection
                        commentsSection
                        activitySection
                        runsSection
                        workerLogLink
                        if let remoteChangeNotice {
                            Text(remoteChangeNotice)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if hasUnsavedChanges {
                            Text("Unsaved edits")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        if let refreshErrorMessage {
                            Text("Refresh failed: \(refreshErrorMessage)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if let errorMessage {
                        // The displayed identity's detail failed to load. The
                        // screen stays on THIS identity (the poll loop keeps
                        // retrying it); the task that opened the screen is
                        // never resurrected as actionable content.
                        loadFailureView(errorMessage)
                    } else {
                        replacementLoadingView
                    }
                }
                .padding(16)
            }
            .background(ConduitBackdrop())
            .navigationTitle("Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    actionsMenu
                }
            }
            // Replace-current-detail: dependency taps swap the polled identity;
            // drafts re-seed because the user navigated away from them.
            .task(id: displayedTaskID) {
                await loadDetail(force: true)
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: KanbanPollingPolicy.detailIntervalNanoseconds)
                    } catch {
                        break
                    }
                    guard !Task.isCancelled else { break }
                    await loadDetail()
                }
            }
            .onChange(of: displayedTaskID) { _, newValue in
                guard newValue != detail?.task.id else { return }
                // Identity switch (dependency tap): drop everything the old
                // identity owned BEFORE the replacement load starts, so the
                // old poll's completion can neither repopulate collections nor
                // flash its errors onto the new screen.
                detail = nil
                isLoadingDetail = false
                isSaving = false
                // Comment-flow spinners are released ONLY through
                // identity-guarded defers, and a stale completion must skip
                // that release — so the swap itself clears the flags (and
                // the unsent draft) the departing identity owned. Otherwise
                // the new identity's Add-comment button and its poll guard
                // stay frozen forever, and A's unsent text could post to B.
                isAddingComment = false
                isRequeuing = false
                comment = ""
                // No sheet/alert may stay armed over the replacement
                // identity: a presented editor or confirmation belongs to
                // the departed task and must never act on the new one.
                showReassignSheet = false
                showModelSheet = false
                showDeleteConfirmation = false
                title = ""
                taskBody = ""
                status = "todo"
                baseline = ServerBaseline(title: "", bodyText: "", status: "todo")
                remoteChangeNotice = nil
                errorMessage = nil
                refreshErrorMessage = nil
                modelOverrideDraft = TaskModelOverride()
                // The open editor session belonged to the departed identity;
                // its dismissal must never commit against the new one.
                modelOverrideSession = nil
            }
            .sheet(isPresented: $showReassignSheet) {
                KanbanReassignSheet(taskID: displayedTaskID, currentAssignee: displayedTask?.assignee)
                    .environmentObject(store)
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showModelSheet) {
                KanbanModelOverrideSheet(value: $modelOverrideDraft)
                    .environmentObject(store)
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: showModelSheet) { wasOpen, nowOpen in
                guard !nowOpen, wasOpen else { return }
                defer { modelOverrideSession = nil }
                // THREE conceptually separate concerns (V2 correctness):
                //   1. draft vs sheet-open baseline -> did the user edit anything?
                //   2. displayed server task NOW     -> authorizes the write and
                //      defines the network target (frozen BELOW, before the
                //      async Task is spawned);
                //   3. post-await identity guard     -> may the completion touch
                //      the CURRENT UI (stale completions stay UI-inert).
                // A no-edit dismissal can NEVER overwrite a server value that
                // changed while the sheet was open; an actual edit is diffed
                // against the captured server snapshot for correct clear/set
                // flags. Freezing the target here closes the dismiss-to-Task
                // scheduling gap: a navigation A -> B between dismissal and
                // execution can never retarget the PATCH to B.
                guard let target = KanbanModelOverrideSessionPolicy.commitTarget(
                    session: modelOverrideSession,
                    draft: modelOverrideDraft,
                    displayedTask: displayedTask,
                    displayedTaskID: displayedTaskID
                ) else { return }
                Task {
                    await commitModelOverride(
                        target.value,
                        startedTask: target.startedTask,
                        expectedID: target.expectedID
                    )
                }
            }
            .alert("Delete this task?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) { Task { await deleteTask() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the task from the selected Hermes board.")
            }
        }
    }

    private var hasAnyServerOverride: Bool {
        guard let task = displayedTask else { return false }
        return !(task.modelOverride ?? "").isEmpty
            || !(task.providerOverride ?? "").isEmpty
            || !(task.reasoningEffort ?? "").isEmpty
    }

    // MARK: - Actions menu

    private var actionsMenu: some View {
        Menu {
            Button {
                if let task = displayedTask {
                    KanbanClipboard.copy(task.id, announcement: "Task ID copied")
                }
            } label: {
                Label("Copy Task ID", systemImage: "doc.on.doc")
            }
            .disabled(!isDisplayedTaskLoaded)
            Button {
                if let task = displayedTask {
                    KanbanClipboard.copy(task.title.isEmpty ? task.id : task.title, announcement: "Title copied")
                }
            } label: {
                Label("Copy Task Title", systemImage: "doc.on.doc.fill")
            }
            .disabled(!isDisplayedTaskLoaded)
            Button {
                showReassignSheet = true
            } label: {
                Label("Reassign…", systemImage: "person.2")
            }
            .disabled(!isDisplayedTaskLoaded)
            Divider()
            // Archive is first-class but NOT destructive upstream (plain
            // archived-status PATCH), so it carries no destructive styling.
            Button {
                Task { await archiveTask() }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(!isDisplayedTaskLoaded || displayedTask?.status == "archived")
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete…", systemImage: "trash")
            }
            .disabled(!isDisplayedTaskLoaded)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Task actions")
    }

    // MARK: - Editor

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $title)
                .font(.headline)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $taskBody)
                .frame(minHeight: 120)
                .padding(4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            Picker("Status", selection: $status) {
                ForEach(statusOptions) { value in
                    Label(value.displayName, systemImage: value.systemImage)
                        .tag(value.rawValue)
                        .disabled(!value.isManuallySelectable)
                }
            }
            .pickerStyle(.menu)
            Button {
                Task { await saveChanges() }
            } label: {
                HStack {
                    Spacer()
                    if isSaving { ProgressView() } else { Text("Save changes") }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.conduitAccent)
            .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Assignment & execution

    private var assignmentExecutionSection: some View {
        ConduitSettingsSection(title: "Assignment & Execution", symbol: "person.crop.rectangle.stack", tint: .conduitAura) {
            HStack(spacing: 8) {
                Text("Assignee")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let assignee = displayedTask?.assignee, !assignee.isEmpty {
                    Text(assignee)
                        .lineLimit(1)
                } else {
                    Text("Unassigned" + (displayedTask?.status == "ready" && hasDispatcherFallback ? " → default" : ""))
                        .foregroundStyle(.secondary)
                }
                Button {
                    showReassignSheet = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.person")
                }
                .accessibilityLabel("Reassign task")
            }
            if let priority = displayedTask?.priority {
                SettingsMetricRow(label: "Priority", value: String(priority))
            }
            if let workspaceKind = displayedTask?.workspaceKind, !workspaceKind.isEmpty,
               let path = displayedTask?.workspacePath, !path.isEmpty {
                SettingsMetricRow(label: "Workspace", value: workspaceKind + ": " + path, lineLimit: 2)
            } else if let path = displayedTask?.workspacePath, !path.isEmpty {
                SettingsMetricRow(label: "Workspace", value: path, lineLimit: 2)
            }
            Button {
                // Begin a NEW sheet session: freeze the server value AT OPEN
                // TIME as both the editor draft and the session baseline.
                // While the sheet is closed the row below renders the server
                // value directly; while it is open, polling may move the
                // server underneath, but "did the user edit?" stays draft vs
                // baseline — the server change is never mistaken for an edit.
                let serverOverride = KanbanModelOverrideDisplayPolicy.override(for: displayedTask)
                modelOverrideSession = KanbanModelOverrideSession(
                    taskID: displayedTaskID,
                    baseline: serverOverride
                )
                modelOverrideDraft = serverOverride
                showModelSheet = true
            } label: {
                HStack(spacing: 8) {
                    Text("Model")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    // Display-only: derived from the loaded server task,
                    // never from the editor draft.
                    Text(KanbanModelOverrideDisplayPolicy.label(for: displayedTask, inheritCopy: "Inherit from profile"))
                        .foregroundStyle(hasAnyServerOverride ? Color.primary : Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityHint("Edits the per-task model, provider, and reasoning override")
            if isRunning, let pid = displayedTask?.workerPid {
                SettingsMetricRow(label: "Worker PID", value: String(pid))
            }
            if let createdBy = displayedTask?.createdBy, !createdBy.isEmpty {
                SettingsMetricRow(label: "Created by", value: createdBy, lineLimit: 1)
            }
            if let failures = displayedTask?.consecutiveFailures, failures > 0 {
                SettingsMetricRow(label: "Consecutive failures", value: String(failures))
            }
            if let failure = displayedTask?.lastFailureError, !failure.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Last failure")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var readyUnassignedCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Ready but unassigned", systemImage: "bolt.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("No profile is attached and Hermes has no default assignee configured, so this task will not run until someone assigns it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                showReassignSheet = true
            } label: {
                Text("Reassign now")
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnosticsSection: some View {
        if let diagnostics = displayedTask?.diagnostics, !diagnostics.isEmpty {
            ConduitSettingsSection(title: "Diagnostics (\(diagnostics.count))", symbol: "stethoscope", tint: .red) {
                ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    diagnosticCard(diagnostic)
                }
            }
        }
    }

    private func diagnosticCard(_ diagnostic: KanbanDiagnostic) -> some View {
        let severityColor = severityTint(diagnostic.severity)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: severityIcon(diagnostic.severity))
                    .foregroundStyle(severityColor)
                Text(diagnostic.title.isEmpty ? diagnostic.kind : diagnostic.title)
                    .font(.subheadline.weight(.semibold))
                if diagnostic.count > 1 {
                    Text("×\(diagnostic.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !diagnostic.detail.isEmpty {
                Text(diagnostic.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(diagnostic.actions.filter { action in
                action.kind == "reclaim" || action.kind == "cli_hint"
            }.enumerated()), id: \.offset) { _, action in
                diagnosticActionButton(action)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(severityColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(severityColor.opacity(0.3), lineWidth: 1)
        }
    }

    /// Only the backend's OWN structured actions are executable: `reclaim`
    /// maps to the dedicated reclaim endpoint, `cli_hint` copies its command.
    /// Anything else renders as inert text; no recovery mutation is ever
    /// invented from returned strings.
    @ViewBuilder
    private func diagnosticActionButton(_ action: KanbanDiagnosticAction) -> some View {
        switch action.kind {
        case "reclaim":
            Button {
                Task { await reclaimTask(reason: nil) }
            } label: {
                Label(action.label.isEmpty ? "Reclaim" : action.label, systemImage: "arrow.clockwise.circle")
            }
            .buttonStyle(.bordered)
            .tint(action.suggested == true ? .conduitAccent : .secondary)
        case "cli_hint":
            Button {
                let command = action.payload?["command"]?.stringValue ?? action.label
                KanbanClipboard.copy(command, announcement: "Recovery command copied")
            } label: {
                Label(action.label.isEmpty ? "Copy command" : action.label, systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }

    private func severityTint(_ severity: String) -> Color {
        switch severity.lowercased() {
        case "critical", "error": return .red
        case "warning": return .orange
        default: return .secondary
        }
    }

    private func severityIcon(_ severity: String) -> String {
        switch severity.lowercased() {
        case "critical": return "exclamationmark.octagon.fill"
        case "error": return "exclamationmark.triangle.fill"
        case "warning": return "exclamationmark.triangle"
        default: return "info.circle"
        }
    }

    // MARK: - Dependencies

    @ViewBuilder
    private var dependenciesSection: some View {
        if let links = detail?.links, !links.parents.isEmpty || !links.children.isEmpty {
            ConduitSettingsSection(title: "Dependencies", symbol: "arrow.triangle.branch", tint: .conduitAura) {
                if !links.parents.isEmpty {
                    dependencyGroup(title: "Blocked by", ids: links.parents)
                }
                if !links.children.isEmpty {
                    dependencyGroup(title: "Blocks", ids: links.children)
                }
            }
        }
    }

    private func dependencyGroup(title: String, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(ids, id: \.self) { linkedID in
                Button {
                    // Replace-current-detail navigation: safe on iPhone, no
                    // recursive sheet stacks.
                    displayedTaskID = linkedID
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(linkedTaskTitle(for: linkedID))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                Text(KanbanShortID.of(linkedID))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                if let linkedStatus = linkedTaskStatus(for: linkedID) {
                                    Text(KanbanStatusPresentation.forStatus(linkedStatus).displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityLabel("Open linked task \(linkedTaskTitle(for: linkedID))")
            }
        }
    }

    private func linkedTaskTitle(for id: String) -> String {
        let title = store.board?.columns.flatMap(\.tasks).first(where: { $0.id == id })?.title
        return title?.isEmpty == false ? title! : KanbanShortID.of(id)
    }

    private func linkedTaskStatus(for id: String) -> String? {
        store.board?.columns.flatMap(\.tasks).first(where: { $0.id == id })?.status
    }

    // MARK: - Comments

    private var commentsSection: some View {
        ConduitSettingsSection(title: "Comments", symbol: "bubble.left.and.bubble.right", tint: .conduitAccent) {
            if let comments = detail?.comments, !comments.isEmpty {
                ForEach(comments) { value in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(value.author).font(.caption.weight(.semibold))
                            Spacer()
                            Text(relativeDate(value.createdAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(value.body).font(.footnote)
                    }
                    .padding(.vertical, 3)
                }
            } else {
                Text("No comments yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $comment)
                .frame(minHeight: 70)
                .padding(4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("New comment")
            if isRunning {
                Text("Comments reach the live worker between turns as an out-of-band note.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await addComment() }
                } label: {
                    HStack {
                        Spacer()
                        if isAddingComment { ProgressView() } else { Label(isRunning ? "Send" : "Add comment", systemImage: "paperplane") }
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingComment)
                if isRunning {
                    // Upstream "Note & requeue": post the note, then reclaim so
                    // the dispatcher re-runs the task with the note in context.
                    Button {
                        Task { await noteAndRequeue() }
                    } label: {
                        HStack {
                            Spacer()
                            if isRequeuing { ProgressView() } else { Label("Note & requeue", systemImage: "arrow.uturn.backward.circle") }
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRequeuing)
                }
            }
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private var activitySection: some View {
        if let events = detail?.events, !events.isEmpty {
            ConduitSettingsSection(title: "Activity (\(events.count))", symbol: "clock.arrow.circlepath", tint: .conduitAccent) {
                ForEach(events.prefix(60)) { event in
                    let row = KanbanActivityFormatter.row(for: event)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(Color.conduitAccent.opacity(0.55))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.label)
                                .font(.caption.weight(.medium))
                            if let extra = row.detail, !extra.isEmpty {
                                Text(extra)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(relativeDate(event.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if events.count > 60 {
                    Text("\(events.count - 60) earlier events hidden")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Runs

    @ViewBuilder
    private var runsSection: some View {
        if let runs = detail?.runs, !runs.isEmpty {
            ConduitSettingsSection(title: "Runs (\(runs.count))", symbol: "terminal", tint: .orange) {
                ForEach(runs) { run in
                    runRow(run)
                }
            }
        }
    }

    private func runRow(_ run: KanbanRun) -> some View {
        let failed = KanbanRunPresentation.isFailed(run)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: failed ? "xmark.octagon.fill" : (run.outcome == "completed" || run.status == "completed" ? "checkmark.circle.fill" : "circle.dotted"))
                    .foregroundStyle(failed ? Color.red : (run.outcome == "completed" || run.status == "completed" ? Color.green : Color.secondary))
                Text(KanbanRunPresentation.outcomeLabel(run))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(failed ? Color.red : Color.primary)
                if let stepKey = run.stepKey, !stepKey.isEmpty {
                    Text(stepKey)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let duration = KanbanRunPresentation.durationText(start: run.startedAt, end: run.endedAt) {
                    Text(duration)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                if let profile = run.profile, !profile.isEmpty {
                    Label(profile, systemImage: "person")
                        .lineLimit(1)
                }
                if let pid = run.workerPID {
                    Text("pid \(pid)")
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Text(relativeDate(run.endedAt ?? run.startedAt))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let error = run.error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            } else if let summary = run.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Worker log

    private var workerLogLink: some View {
        NavigationLink {
            KanbanWorkerLogScreen(taskID: displayedTaskID)
                .environmentObject(store)
        } label: {
            HStack {
                Label("Worker Log", systemImage: "doc.text.magnifyingglass")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Data

    private func loadDetail(force: Bool = false) async {
        // A poll never runs underneath an active save/comment write.
        guard force || (!isSaving && !isAddingComment && !isRequeuing), !isLoadingDetail else { return }
        // Freeze THIS fetch's identity up front. If the operator taps a
        // dependency mid-flight, every completion below is discarded: no
        // data, no error text, no baseline churn may cross identities.
        let expectedID = displayedTaskID
        isLoadingDetail = true
        // A STALE completion must not clear the replacement load's spinner:
        // only the current identity may release the flag.
        defer {
            if displayedTaskID == expectedID { isLoadingDetail = false }
        }
        do {
            let loaded = try await store.fetchTaskDetail(id: expectedID)
            guard displayedTaskID == expectedID else { return }
            guard loaded.task.id == expectedID else {
                // Defensive double-check against a server-side id mismatch.
                // An EMPTY-id payload under a NON-empty displayed identity is
                // a server contract violation: the identity policy correctly
                // refuses to make it actionable, so surface it as THIS
                // identity's load failure (failure view + poll retry) rather
                // than letting the screen spin forever. The empty/empty
                // same-identity case flows through the equality branch above.
                if loaded.task.id.isEmpty, !expectedID.isEmpty {
                    errorMessage = KanbanServiceError.invalidResponse("Task detail returned an invalid id.").localizedDescription
                }
                return
            }
            let server = loaded.task
            if hasUnsavedChanges {
                // Preserve the user's draft. Flag external edits to the same
                // fields so the conflict is visible without destroying input.
                let serverMoved = KanbanDetailDraftPolicy.serverMovedIndependently(
                    serverTitle: server.title,
                    serverBodyText: server.body ?? "",
                    serverStatus: server.status,
                    baselineTitle: baseline.title,
                    baselineBodyText: baseline.bodyText,
                    baselineStatus: baseline.status
                )
                if serverMoved && remoteChangeNotice == nil {
                    remoteChangeNotice = "This task changed on the server. Your unsaved edits are preserved."
                }
            } else {
                title = server.title
                taskBody = server.body ?? ""
                status = server.status
                baseline = ServerBaseline(title: server.title, bodyText: server.body ?? "", status: server.status)
                remoteChangeNotice = nil
            }
            // Recovery from a load-failure state: a successful load for the
            // displayed identity clears the load-failure error so content
            // renders clean. Conditioned on the identity having NO
            // actionable task: on the opening identity (actionable through
            // initialTask while detail is nil) a mutation error raised in
            // that window keeps its existing persistence semantics instead
            // of being wiped by this poll.
            if displayedTask == nil { errorMessage = nil }
            detail = loaded
            refreshErrorMessage = nil
        } catch is CancellationError {
            // The poll loop was replaced (identity switch or dismissal); its
            // cancellation must never render as a user-facing failure.
            return
        } catch {
            guard displayedTaskID == expectedID else { return }
            if detail == nil {
                errorMessage = error.localizedDescription
            } else {
                refreshErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Mutations

    private func saveChanges() async {
        // Freeze the actionable task AND its identity before the first
        // suspension point: this save may only ever touch this task's UI.
        guard let startedTask = displayedTask else { return }
        let expectedID = displayedTaskID
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var patch = KanbanTaskPatch()
        // Diffs run against the last-synced baseline, not the live server
        // snapshot, so an external edit cannot silently drop a user field.
        if trimmedTitle != baseline.title { patch.title = trimmedTitle }
        if taskBody != baseline.bodyText { patch.body = taskBody }
        if status != baseline.status {
            guard KanbanStatusPresentation.canSelectManually(status) else {
                errorMessage = KanbanServiceError.invalidManualStatus(status).localizedDescription
                return
            }
            patch.status = status
        }
        guard !patch.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        // A stale completion must not clear a saving spinner that now belongs
        // to the displayed task's own operations.
        defer {
            if KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) {
                isSaving = false
            }
        }
        do {
            let saved = try await store.updateTask(id: startedTask.id, patch: patch)
            let completion = KanbanDetailMutationPolicy.saveCompletion(
                startedTask: startedTask,
                response: saved,
                displayedTaskID: displayedTaskID
            )
            // After a dependency tap the completion is UI-inert: no draft,
            // baseline, error, or refresh for the task now displayed.
            guard completion.isActive, let savedServer = completion.serverTask else { return }
            title = savedServer.title
            taskBody = savedServer.body ?? taskBody
            status = savedServer.status
            baseline = ServerBaseline(title: savedServer.title, bodyText: savedServer.body ?? taskBody, status: savedServer.status)
            remoteChangeNotice = nil
            await loadDetail(force: true)
        } catch {
            guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Committed immediately on change (desktop parity): PATCH with explicit
    /// clear flags computed against the CAPTURED server snapshot. The
    /// mutation identity (startedTask + expectedID) is frozen by the caller
    /// BEFORE the async Task is spawned; this method deliberately never
    /// re-reads displayedTask/displayedTaskID to choose its network target,
    /// so navigation between dismissal and execution cannot retarget the
    /// PATCH. Post-await identity guards keep the completion UI-inert on any
    /// other displayed identity.
    private func commitModelOverride(_ next: TaskModelOverride, startedTask: KanbanTask, expectedID: String) async {
        let patch = TaskModelOverride.patch(from: startedTask, to: next)
        guard !patch.isEmpty else { return }
        isSaving = true
        defer {
            if KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) {
                isSaving = false
            }
        }
        do {
            _ = try await store.updateTask(id: startedTask.id, patch: patch)
            guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
            await loadDetail(force: true)
        } catch {
            guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func archiveTask() async {
        guard let startedTask = displayedTask, startedTask.status != "archived" else { return }
        let expectedID = displayedTaskID
        do {
            _ = try await store.updateTask(id: startedTask.id, patch: KanbanTaskPatch(status: "archived"))
            guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
            await loadDetail(force: true)
        } catch {
            guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func addComment() async {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let expectedID = displayedTaskID
        isAddingComment = true
        errorMessage = nil
        defer {
            if KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) {
                isAddingComment = false
            }
        }
        do {
            try await store.addComment(taskID: expectedID, body: text)
            guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
            comment = ""
            await loadDetail(force: true)
        } catch {
            guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Note & requeue: two supported mutations composed exactly like the
    /// desktop drawer (comment first, then reclaim) — but with OBSERVABLE
    /// partial success: the draft is consumed the moment the note reaches the
    /// server, and a reclaim failure afterwards is reported as partial
    /// success without ever reposting the note.
    private func noteAndRequeue() async {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let expectedID = displayedTaskID
        isRequeuing = true
        errorMessage = nil
        defer {
            if KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) {
                isRequeuing = false
            }
        }
        let outcome = await KanbanNoteAndRequeueFlow.perform(
            text: text,
            postComment: { body in try await store.addComment(taskID: expectedID, body: body) },
            reclaim: { try await store.reclaimTask(taskID: expectedID) },
            onCommentPosted: {
                // Consume the draft immediately: the note already exists on
                // the server, so a retry after a reclaim failure must never
                // post it a second time.
                if KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) {
                    comment = ""
                }
            }
        )
        guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
        if let message = KanbanNoteAndRequeueFlow.message(for: outcome) {
            errorMessage = message
            return
        }
        await loadDetail(force: true)
    }

    private func reclaimTask(reason: String?) async {
        let expectedID = displayedTaskID
        do {
            try await store.reclaimTask(taskID: expectedID, reason: reason)
            guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
            await loadDetail(force: true)
        } catch {
            guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTask() async {
        guard let startedTask = displayedTask else { return }
        let expectedID = displayedTaskID
        do {
            try await store.deleteTask(id: startedTask.id)
            // A delete started for another identity must NEVER dismiss the
            // screen while it displays this task.
            guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
            dismiss()
        } catch {
            guard KanbanDetailMutationPolicy.completionIsActive(startedTaskID: expectedID, displayedTaskID: displayedTaskID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Replacement identity states

    /// The displayed identity's detail is loading: nothing task-specific may
    /// render or act — in particular, the task the screen opened with must
    /// not leak through as this screen's content.
    private var replacementLoadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading task…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// The displayed identity's detail failed to load: the failure belongs to
    /// THIS identity and the screen stays on it (the poll loop keeps
    /// retrying); the previous task is never resurrected as content.
    private func loadFailureView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Couldn't load this task")
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func relativeDate(_ epoch: Int?) -> String {
        guard let epoch else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: Double(epoch)), relativeTo: Date())
    }
}

// MARK: - Detail identity & mutation ownership policies

/// Identity resolution for the task detail screen (Kanban V2 correctness).
///
/// A task detail screen may only display or mutate data belonging to its
/// current displayed identity. The opening task is a legal actionable task
/// ONLY while the displayed identity is still that task: once a dependency
/// tap swaps the identity, a loading or failed replacement load must NEVER
/// fall back to the previous task's data.
enum KanbanDetailIdentityPolicy {
    /// The actionable task for `displayedID`, or nil while that identity is
    /// not loaded. STRICT invariant: result.id == displayedID whenever
    /// non-nil. A detail task whose id does not equal the displayed id —
    /// including a server task with an EMPTY id under a non-empty displayed
    /// id — is never actionable: the mutation policies gate on
    /// startedTask.id == displayedTaskID, so honoring such a task would aim
    /// PATCH/DELETE at an empty task id and make its own saves silently
    /// inert. The mismatched case renders the loading/failed state and the
    /// poll keeps retrying the displayed identity.
    static func actionableTask(displayedID: String, detailTask: KanbanTask?, initialTask: KanbanTask) -> KanbanTask? {
        if let detailTask, detailTask.id == displayedID {
            return detailTask
        }
        // The opening task may act ONLY for its own identity: after a
        // dependency tap to another id there is deliberately NO fallback.
        return displayedID == initialTask.id ? initialTask : nil
    }
}

/// Async-ownership rules for task-detail mutations (Kanban V2 correctness).
///
/// Every task-specific async operation captures its identity before its
/// first suspension point. After every await, the completion may touch
/// detail UI state ONLY while the identity it started for is still the
/// displayed one — otherwise it is UI-inert: the server write may still
/// finish, but it must not overwrite the displayed task's draft/baseline,
/// surface the old task's error, dismiss the screen, or trigger a refresh
/// for the displayed task.
enum KanbanDetailMutationPolicy {
    static func completionIsActive(startedTaskID: String, displayedTaskID: String) -> Bool {
        startedTaskID == displayedTaskID
    }

    struct SaveCompletion: Equatable {
        /// False → the whole completion is inert: no draft, baseline, error,
        /// or refresh changes are permitted.
        let isActive: Bool
        /// The task whose values seed the draft/baseline when active — ALWAYS
        /// the task that started the save (or its server response), never
        /// whatever task is displayed when the response lands.
        let serverTask: KanbanTask?
    }

    static func saveCompletion(startedTask: KanbanTask, response: KanbanTask?, displayedTaskID: String) -> SaveCompletion {
        guard completionIsActive(startedTaskID: startedTask.id, displayedTaskID: displayedTaskID) else {
            return SaveCompletion(isActive: false, serverTask: nil)
        }
        // A response that does not echo the STARTED task's id is a server
        // contract violation: never let it seed the started task's baseline.
        // An empty-id response is honored only for the empty/empty identity
        // case, mirroring the load path's acceptance rule; the forced reload
        // afterwards re-syncs from the authoritative task.
        let trusted = response.flatMap { $0.id == startedTask.id || ($0.id.isEmpty && startedTask.id.isEmpty) ? $0 : nil } ?? startedTask
        return SaveCompletion(isActive: true, serverTask: trusted)
    }
}

/// Model-row display rules (Kanban V2 correctness).
///
/// The NON-EDITING row derives from the current loaded SERVER task, so an
/// existing override is visible immediately (without opening the editor) and
/// a poll that changes the override updates the row. `modelOverrideDraft` is
/// the ACTIVE EDITOR draft only: it exists solely while the sheet is open
/// and is never a display source (polling can never clobber it).
enum KanbanModelOverrideDisplayPolicy {
    /// The server override to show (and to seed the editor with) for the
    /// displayed task; inherit/empty while none or not yet loaded.
    static func override(for displayedTask: KanbanTask?) -> TaskModelOverride {
        displayedTask.map { TaskModelOverride(task: $0) } ?? TaskModelOverride()
    }

    /// The visible Model-row label.
    static func label(for displayedTask: KanbanTask?, inheritCopy: String) -> String {
        override(for: displayedTask).label(inheritCopy: inheritCopy)
    }
}

/// One model-override editor sheet session: the task identity the sheet was
/// opened for, and the SERVER override value frozen at open time.
struct KanbanModelOverrideSession: Equatable {
    let taskID: String
    let baseline: TaskModelOverride
}

/// Dismissal rules for the model override editor (Kanban V2 correctness).
///
/// Keeps two comparisons conceptually separate:
/// - draft vs sheet-open baseline  -> did the user edit anything?
/// - draft vs current server value -> what wire mutation is required?
///
/// A no-edit dismissal can never overwrite a server value that changed while
/// the sheet was open (the draft matches the baseline, whatever the server
/// now holds), and a session belonging to one task identity never commits
/// against another.
enum KanbanModelOverrideSessionPolicy {
    enum DismissalOutcome: Equatable {
        /// Nothing may be written: no user edit, no session, a foreign
        /// identity, or a session already invalidated by navigation.
        case noWrite
        /// The user edited after opening; commit this value. The wire
        /// mutation is computed against the CURRENT server snapshot at
        /// commit time (correct clear/set semantics).
        case commit(TaskModelOverride)
    }

    static func dismissalOutcome(
        session: KanbanModelOverrideSession?,
        draft: TaskModelOverride,
        displayedTaskID: String
    ) -> DismissalOutcome {
        guard let session else { return .noWrite }
        // A sheet session belongs to exactly one task identity: a session
        // opened for A must never commit against B.
        guard session.taskID == displayedTaskID else { return .noWrite }
        // USER-EDIT test: against the sheet-open baseline, NOT the live
        // server value (which polling may have moved under the sheet).
        guard draft != session.baseline else { return .noWrite }
        return .commit(draft)
    }

    /// The frozen mutation identity for a committed model edit: the edited
    /// value, the DISPLAYED SERVER TASK captured at dismissal (which both
    /// authorizes the write and defines the network target), and its
    /// identity. Computed synchronously at dismissal — BEFORE the async
    /// commit Task is spawned — so the commit can never re-read a different
    /// displayed task to choose what it PATCHes.
    struct CommitTarget: Equatable {
        let value: TaskModelOverride
        let startedTask: KanbanTask
        let expectedID: String
    }

    /// Resolves the commit target at dismissal time. Requires: a session for
    /// the current identity, a REAL user edit (vs the sheet-open baseline),
    /// an actionable displayed task whose id matches the displayed identity,
    /// and an edited value that still differs from the current server
    /// override (no duplicate write). Anything else — including a nil
    /// session (never opened, or reset by navigation), which yields nil
    /// through dismissalOutcome's .noWrite — writes nothing.
    static func commitTarget(
        session: KanbanModelOverrideSession?,
        draft: TaskModelOverride,
        displayedTask: KanbanTask?,
        displayedTaskID: String
    ) -> CommitTarget? {
        guard case .commit(let next) = dismissalOutcome(
            session: session,
            draft: draft,
            displayedTaskID: displayedTaskID
        ) else { return nil }
        guard let serverTask = displayedTask,
              serverTask.id == displayedTaskID,
              next != TaskModelOverride(task: serverTask) else { return nil }
        return CommitTarget(value: next, startedTask: serverTask, expectedID: displayedTaskID)
    }
}

/// Note & requeue as an explicit two-step operation with OBSERVABLE partial
/// success (Kanban V2 correctness): the comment draft is consumed the moment
/// the note reaches the server, and a later reclaim failure is reported as
/// partial success — a retry can never repost the note.
enum KanbanNoteAndRequeueFlow {
    struct Outcome: Equatable {
        /// The note reached the server — the input MUST be consumed now,
        /// whatever happens to the reclaim step.
        let commentPosted: Bool
        /// Full success: note posted AND task requeued.
        let requeued: Bool
        /// Underlying failure detail when the flow did not fully succeed.
        let failureDetail: String?
    }

    static func perform(
        text: String,
        postComment: @MainActor (String) async throws -> Void,
        reclaim: @MainActor () async throws -> Void,
        onCommentPosted: @MainActor () -> Void
    ) async -> Outcome {
        do {
            try await postComment(text)
        } catch {
            return Outcome(commentPosted: false, requeued: false, failureDetail: error.localizedDescription)
        }
        // The note now exists on the server: consume the draft BEFORE the
        // reclaim attempt so a reclaim failure can never double-post it.
        await onCommentPosted()
        do {
            try await reclaim()
        } catch {
            return Outcome(commentPosted: true, requeued: false, failureDetail: error.localizedDescription)
        }
        return Outcome(commentPosted: true, requeued: true, failureDetail: nil)
    }

    /// User-facing wording. A posted note + failed reclaim is PARTIAL success
    /// and must be described as such — the note is already on the server.
    static func message(for outcome: Outcome) -> String? {
        switch (outcome.commentPosted, outcome.requeued, outcome.failureDetail) {
        case (false, _, let detail?):
            return detail
        case (true, false, let detail?):
            return "The note was posted, but the task could not be requeued. (\(detail))"
        default:
            return nil
        }
    }
}

// MARK: - Reassign sheet

/// Dedicated reassignment surface backed by POST /tasks/{id}/reassign with
/// reclaim_first=true (upstream drawer behavior): switching profiles releases
/// a running worker claim first and resets the failure streak.
struct KanbanReassignSheet: View {
    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss
    let taskID: String
    let currentAssignee: String?

    @State private var pendingProfile: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Profiles") {
                    ForEach(store.profiles) { profile in
                        Button {
                            Task { await reassign(to: profile.name) }
                        } label: {
                            HStack {
                                Text(profile.name)
                                Spacer()
                                if profile.name == currentAssignee {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.conduitAccent)
                                }
                                if pendingProfile == profile.name {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(pendingProfile != nil)
                    }
                }
                if (currentAssignee ?? "").isEmpty == false {
                    Section {
                        Button(role: .destructive) {
                            Task { await reassign(to: nil) }
                        } label: {
                            HStack {
                                Text("Unassign (parked — won't run)")
                                if pendingProfile == "__unassign__" { ProgressView() }
                            }
                        }
                        .disabled(pendingProfile != nil)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("Reassign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(pendingProfile != nil)
    }

    private func reassign(to profile: String?) async {
        pendingProfile = profile ?? "__unassign__"
        errorMessage = nil
        defer { pendingProfile = nil }
        do {
            // The dedicated reassignment endpoint (reclaim-first, upstream).
            try await store.reassignTask(taskID: taskID, profile: profile, reclaimFirst: true)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
