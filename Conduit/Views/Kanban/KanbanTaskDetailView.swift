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

    private var currentTask: KanbanTask {
        detail?.task ?? initialTask
    }

    private var isRunning: Bool {
        currentTask.status == "running"
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
                title = ""
                taskBody = ""
                status = "todo"
                baseline = ServerBaseline(title: "", bodyText: "", status: "todo")
                remoteChangeNotice = nil
                errorMessage = nil
                refreshErrorMessage = nil
                modelOverrideDraft = TaskModelOverride()
            }
            .sheet(isPresented: $showReassignSheet) {
                KanbanReassignSheet(taskID: displayedTaskID, currentAssignee: currentTask.assignee)
                    .environmentObject(store)
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showModelSheet) {
                KanbanModelOverrideSheet(value: $modelOverrideDraft)
                    .environmentObject(store)
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: showModelSheet) { wasOpen, nowOpen in
                if !nowOpen && wasOpen {
                    // Commit-on-dismiss (desktop parity: the drawer PATCHes on
                    // change). Diff the edited override against the CURRENT
                    // server snapshot so a poll landing mid-edit can neither
                    // clobber the user nor duplicate the write.
                    let next = modelOverrideDraft
                    if next != TaskModelOverride(task: currentTask) {
                        Task { await commitModelOverride(next) }
                    }
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
        !(currentTask.modelOverride ?? "").isEmpty
            || !(currentTask.providerOverride ?? "").isEmpty
            || !(currentTask.reasoningEffort ?? "").isEmpty
    }

    // MARK: - Actions menu

    private var actionsMenu: some View {
        Menu {
            Button {
                KanbanClipboard.copy(currentTask.id, announcement: "Task ID copied")
            } label: {
                Label("Copy Task ID", systemImage: "doc.on.doc")
            }
            Button {
                KanbanClipboard.copy(currentTask.title.isEmpty ? currentTask.id : currentTask.title, announcement: "Title copied")
            } label: {
                Label("Copy Task Title", systemImage: "doc.on.doc.fill")
            }
            Button {
                showReassignSheet = true
            } label: {
                Label("Reassign…", systemImage: "person.2")
            }
            Divider()
            // Archive is first-class but NOT destructive upstream (plain
            // archived-status PATCH), so it carries no destructive styling.
            Button {
                Task { await archiveTask() }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(currentTask.status == "archived")
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete…", systemImage: "trash")
            }
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
                if let assignee = currentTask.assignee, !assignee.isEmpty {
                    Text(assignee)
                        .lineLimit(1)
                } else {
                    Text("Unassigned" + (currentTask.status == "ready" && hasDispatcherFallback ? " → default" : ""))
                        .foregroundStyle(.secondary)
                }
                Button {
                    showReassignSheet = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.person")
                }
                .accessibilityLabel("Reassign task")
            }
            if let priority = currentTask.priority {
                SettingsMetricRow(label: "Priority", value: String(priority))
            }
            if let workspaceKind = currentTask.workspaceKind, !workspaceKind.isEmpty,
               let path = currentTask.workspacePath, !path.isEmpty {
                SettingsMetricRow(label: "Workspace", value: workspaceKind + ": " + path, lineLimit: 2)
            } else if let path = currentTask.workspacePath, !path.isEmpty {
                SettingsMetricRow(label: "Workspace", value: path, lineLimit: 2)
            }
            Button {
                modelOverrideDraft = TaskModelOverride(task: currentTask)
                showModelSheet = true
            } label: {
                HStack(spacing: 8) {
                    Text("Model")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(modelOverrideDraft.label(inheritCopy: "Inherit from profile"))
                        .foregroundStyle(hasAnyServerOverride ? Color.primary : Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityHint("Edits the per-task model, provider, and reasoning override")
            if isRunning, let pid = currentTask.workerPid {
                SettingsMetricRow(label: "Worker PID", value: String(pid))
            }
            if let createdBy = currentTask.createdBy, !createdBy.isEmpty {
                SettingsMetricRow(label: "Created by", value: createdBy, lineLimit: 1)
            }
            if let failures = currentTask.consecutiveFailures, failures > 0 {
                SettingsMetricRow(label: "Consecutive failures", value: String(failures))
            }
            if let failure = currentTask.lastFailureError, !failure.isEmpty {
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
        if let diagnostics = currentTask.diagnostics, !diagnostics.isEmpty {
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
            guard loaded.task.id == expectedID || loaded.task.id.isEmpty else {
                // Defensive double-check against a server-side id mismatch.
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
        let current = currentTask
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
        defer { isSaving = false }
        do {
            let saved = try await store.updateTask(id: current.id, patch: patch)
            let savedServer = saved ?? currentTask
            title = savedServer.title
            taskBody = savedServer.body ?? taskBody
            status = savedServer.status
            baseline = ServerBaseline(title: savedServer.title, bodyText: savedServer.body ?? taskBody, status: savedServer.status)
            remoteChangeNotice = nil
            await loadDetail(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Committed immediately on change (desktop parity): PATCH with explicit
    /// clear flags computed against the CURRENT server snapshot.
    private func commitModelOverride(_ next: TaskModelOverride) async {
        let patch = TaskModelOverride.patch(from: currentTask, to: next)
        guard !patch.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await store.updateTask(id: currentTask.id, patch: patch)
            await loadDetail(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archiveTask() async {
        guard currentTask.status != "archived" else { return }
        do {
            _ = try await store.updateTask(id: currentTask.id, patch: KanbanTaskPatch(status: "archived"))
            await loadDetail(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addComment() async {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isAddingComment = true
        errorMessage = nil
        defer { isAddingComment = false }
        do {
            try await store.addComment(taskID: displayedTaskID, body: text)
            comment = ""
            await loadDetail(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Note & requeue: two supported mutations composed exactly like the
    /// desktop drawer (comment first, then reclaim).
    private func noteAndRequeue() async {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isRequeuing = true
        errorMessage = nil
        defer { isRequeuing = false }
        do {
            try await store.addComment(taskID: displayedTaskID, body: text)
            try await store.reclaimTask(taskID: displayedTaskID)
            comment = ""
            await loadDetail(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reclaimTask(reason: String?) async {
        do {
            try await store.reclaimTask(taskID: displayedTaskID, reason: reason)
            await loadDetail(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTask() async {
        do {
            try await store.deleteTask(id: currentTask.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func relativeDate(_ epoch: Int?) -> String {
        guard let epoch else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: Double(epoch)), relativeTo: Date())
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
