import SwiftUI

enum KanbanPollingPolicy {
    static let boardIntervalNanoseconds: UInt64 = 8_000_000_000
    static let detailIntervalNanoseconds: UInt64 = 4_000_000_000
}

/// Pure draft-reconciliation rules for the task detail surface, extracted so
/// polling behavior is deterministically testable without UI timing.
enum KanbanDetailDraftPolicy {
    static func isDirty(
        draftTitle: String,
        draftBody: String,
        draftStatus: String,
        baselineTitle: String,
        baselineBodyText: String,
        baselineStatus: String
    ) -> Bool {
        draftTitle != baselineTitle
            || draftBody != baselineBodyText
            || draftStatus != baselineStatus
    }

    static func serverMovedIndependently(
        serverTitle: String,
        serverBodyText: String,
        serverStatus: String,
        baselineTitle: String,
        baselineBodyText: String,
        baselineStatus: String
    ) -> Bool {
        serverTitle != baselineTitle
            || serverBodyText != baselineBodyText
            || serverStatus != baselineStatus
    }
}

struct KanbanView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = KanbanStore()
    @State private var selectedTask: KanbanTask?
    @State private var showNewTask = false
    @State private var newTaskStatus = "todo"
    @State private var includeArchived = false
    @State private var searchText = ""
    /// iPhone-native interaction: one selected lane rendered as a vertical
    /// card list behind a horizontally scrolling chip selector.
    @State private var selectedLane: String?

    private var bridgeIdentity: ObjectIdentifier? {
        appState.dashboardTicketBridge.map { ObjectIdentifier($0) }
    }

    /// Configuration/polling key. Deliberately EXCLUDES appState.activeProfile:
    /// Hermes Kanban is a shared cross-profile board anchored at the Hermes
    /// root, so Conduit's UI profile switch does not change Kanban data.
    private var pollingKey: String {
        "\(String(describing: bridgeIdentity))|\(appState.dashboardTicketBridge?.baseURL ?? "")|archived=\(includeArchived)"
    }

    private var visibleColumns: [KanbanColumn] {
        guard let board = store.board else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let columns = KanbanStatusPresentation.orderedColumns(board.columns)
        guard !query.isEmpty else { return columns }
        return columns.map { column in
            KanbanColumn(
                name: column.name,
                tasks: column.tasks.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || $0.body?.localizedCaseInsensitiveContains(query) == true
                        || $0.latestSummary?.localizedCaseInsensitiveContains(query) == true
                        || $0.assignee?.localizedCaseInsensitiveContains(query) == true
                }
            )
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            if store.isLoading && store.board == nil {
                Spacer()
                ProgressView("Loading board…")
                    .tint(.conduitAccent)
                Spacer()
            } else if let errorMessage = store.errorMessage, store.board == nil {
                ContentUnavailableView(
                    "Kanban Unavailable",
                    systemImage: "rectangle.3.group",
                    description: Text(errorMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let board = store.board {
                if visibleColumns.isEmpty {
                    ContentUnavailableView("No Columns", systemImage: "rectangle.3.group")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    laneBoard
                        .refreshable { await store.refresh(includeArchived: includeArchived) }
                        .overlay(alignment: .topTrailing) {
                            VStack(alignment: .trailing, spacing: 6) {
                                if let mutationError = store.mutationErrorMessage {
                                    HStack(spacing: 6) {
                                        Text(mutationError)
                                    Button { store.clearMutationError() } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Dismiss Kanban error")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(8)
                                    .background(.ultraThinMaterial, in: Capsule())
                                } else if let refreshError = store.errorMessage {
                                    Text("Refresh failed: \(refreshError)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(8)
                                        .background(.ultraThinMaterial, in: Capsule())
                                }
                            }
                            .padding(.top, 4)
                        }
                }
            } else {
                ContentUnavailableView("No Board", systemImage: "rectangle.3.group")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .background(ConduitBackdrop())
        .sheet(item: $selectedTask) { task in
            KanbanTaskDetailView(task: task)
                .environmentObject(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showNewTask) {
            KanbanTaskEditorView(initialStatus: newTaskStatus)
                .environmentObject(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: pollingKey) {
            selectedTask = nil
            store.configure(
                requester: appState.dashboardTicketBridge,
                serverIdentity: appState.dashboardTicketBridge?.baseURL ?? ""
            )
            await store.reload(includeArchived: includeArchived)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: KanbanPollingPolicy.boardIntervalNanoseconds)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await store.poll(includeArchived: includeArchived)
            }
        }
    }

    // MARK: - Lane-based iPhone board

    /// Native mobile interaction: horizontally scrolling lane chips over one
    /// vertically scrolling card list for the selected lane. Locked/system
    /// lanes stay visible with their counts but are marked and never offer
    /// creation, matching upstream LOCKED_COLUMNS semantics.
    @ViewBuilder
    private var laneBoard: some View {
        let columns = visibleColumns
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(columns) { column in
                        laneChip(column)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            }
            .frame(height: 34)

            if let column = resolvedLaneColumn(in: columns) {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 9) {
                        ForEach(column.tasks) { task in
                            KanbanCardView(
                                task: task,
                                onOpen: { selectedTask = task },
                                onMove: { status in Task { await move(task, to: status) } },
                                onDelete: { Task { await delete(task) } }
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.bottom, 14)
                }
            } else {
                Spacer()
            }
        }
    }

    private func laneChip(_ column: KanbanColumn) -> some View {
        let presentation = KanbanStatusPresentation.forStatus(column.name)
        let isSelected = resolvedLaneName(columns: visibleColumns) == column.name
        return Button {
            selectedLane = column.name
        } label: {
            HStack(spacing: 6) {
                Image(systemName: presentation.systemImage)
                    .font(.caption2)
                Text(presentation.displayName)
                    .font(.caption.weight(isSelected ? .bold : .semibold))
                Text(String(column.tasks.count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if presentation.isBackendControlled {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .conduitGlassControl(cornerRadius: 15, tint: isSelected ? presentation.tint.opacity(0.16) : .clear)
        .accessibilityLabel(presentation.displayName + ", " + String(column.tasks.count) + " tasks")
    }

    private func resolvedLaneName(columns: [KanbanColumn]) -> String? {
        if let selectedLane, columns.contains(where: { $0.name == selectedLane }) {
            return selectedLane
        }
        // Prefer an unlocked default so the first paint shows actionable work.
        return columns.first(where: { !KanbanStatusPresentation.isLockedDestination($0.name) })?.name ?? columns.first?.name
    }

    private func resolvedLaneColumn(in columns: [KanbanColumn]) -> KanbanColumn? {
        guard let name = resolvedLaneName(columns: columns) else { return nil }
        return columns.first(where: { $0.name == name })
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kanban")
                    .font(.title3.weight(.bold))
                Text(store.selectedBoardMetadata?.name ?? store.selectedBoardMetadata?.slug ?? "Board")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Menu {
                Button {
                    Task { await store.selectBoard(slug: "", includeArchived: includeArchived) }
                } label: {
                    Label("Server current (" + store.currentServerBoardSlug + ")", systemImage: "server.rack")
                }
                ForEach(store.boards) { metadata in
                    Button {
                        Task { await store.selectBoard(slug: metadata.slug, includeArchived: includeArchived) }
                    } label: {
                        HStack {
                            Text(metadata.name ?? metadata.slug)
                            if metadata.slug == store.selectedBoardMetadata?.slug && !store.selectedBoardSlug.isEmpty {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "square.grid.2x2")
                    .frame(width: 36, height: 36)
            }
            .conduitGlassControl(cornerRadius: 14)
            .accessibilityLabel("Choose Kanban board")

            Button {
                Task { await store.refresh(includeArchived: includeArchived) }
            } label: {
                Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .frame(width: 36, height: 36)
            }
            .conduitGlassControl(cornerRadius: 14)
            .disabled(store.isLoading || store.isMutating)
            .accessibilityLabel("Refresh Kanban board")

            Button {
                // Land on the visible lane when it accepts creation; otherwise
                // fall back to the backend's default unlocked lane.
                newTaskStatus = selectedLane.flatMap { lane in
                    KanbanStatusPresentation.canCreateTask(in: lane) ? lane : nil
                } ?? "todo"
                showNewTask = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 36, height: 36)
            }
            .conduitGlassControl(cornerRadius: 14, tint: .conduitAccent.opacity(0.12))
            .disabled(store.board == nil || store.isMutating)
            .accessibilityLabel("New Kanban task")
        }

        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search tasks", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Toggle("Archived", isOn: $includeArchived)
                .toggleStyle(.switch)
                .font(.caption)
                .labelsHidden()
                .accessibilityLabel("Show archived tasks")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .conduitGlassControl(cornerRadius: 15)
    }

    private func move(_ task: KanbanTask, to status: String) async {
        guard task.status != status else { return }
        do {
            _ = try await store.updateTask(id: task.id, patch: KanbanTaskPatch(status: status), includeArchived: includeArchived)
        } catch {
            store.showMutationError(error)
        }
    }

    private func delete(_ task: KanbanTask) async {
        do {
            try await store.deleteTask(id: task.id, includeArchived: includeArchived)
        } catch {
            store.showMutationError(error)
        }
    }
}

private struct KanbanCardView: View {
    let task: KanbanTask
    let onOpen: () -> Void
    let onMove: (String) -> Void
    let onDelete: () -> Void

    private var presentation: KanbanStatusPresentation {
        KanbanStatusPresentation.forStatus(task.status)
    }

    private var statusOptions: [KanbanStatusPresentation] {
        KanbanStatusPresentation.manuallySelectableStatuses
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(presentation.tint)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                Spacer(minLength: 2)
                Menu {
                    Section("Move to") {
                        ForEach(statusOptions) { status in
                            Button {
                                onMove(status.rawValue)
                            } label: {
                                Label(status.displayName, systemImage: status.systemImage)
                            }
                        }
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Task actions")
            }

            if let summary = task.latestSummary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else if let body = task.body, !body.isEmpty {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                if let assignee = task.assignee, !assignee.isEmpty {
                    Label(assignee, systemImage: "person")
                        .lineLimit(1)
                }
                if let priority = task.priority, priority > 0 {
                    Label(String(priority), systemImage: "flag.fill")
                }
                if let comments = task.commentCount, comments > 0 {
                    Label(String(comments), systemImage: "bubble.left")
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(presentation.tint.opacity(0.18), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button { onOpen() } label: { Label("Open", systemImage: "arrow.up.right.square") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }
}

struct KanbanTaskEditorView: View {
    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss
    let initialStatus: String
    @State private var title = ""
    @State private var taskBody = ""
    @State private var assignee = ""
    @State private var priority = 0
    @State private var isSaving = false
    @State private var didCreate = false
    @State private var errorMessage: String?

    private var statusPresentation: KanbanStatusPresentation {
        KanbanStatusPresentation.forStatus(initialStatus)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $title)
                    TextEditor(text: $taskBody)
                        .frame(minHeight: 120)
                    Picker("Priority", selection: $priority) {
                        Text("Normal").tag(0)
                        Text("High").tag(1)
                        Text("Urgent").tag(2)
                        Text("Critical").tag(3)
                    }
                    .pickerStyle(.menu)
                }

                Section("Assignment") {
                    Picker("Profile", selection: $assignee) {
                        Text("Unassigned").tag("")
                        ForEach(store.profiles) { profile in
                            Text(profile.name).tag(profile.name)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Workflow") {
                    Label(statusPresentation.displayName, systemImage: statusPresentation.systemImage)
                        .foregroundStyle(statusPresentation.tint)
                    Text("The board selection is local to this device; creating this task will not switch Hermes' global board.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didCreate ? "Close" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if didCreate {
                            dismiss()
                        } else {
                            Task { await save() }
                        }
                    } label: {
                        if isSaving { ProgressView() } else { Text(didCreate ? "Done" : "Create") }
                    }
                    .disabled((title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !didCreate) || isSaving)
                }
            }
        }
    }

    private func save() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, statusPresentation.isTaskCreatable else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await store.createTask(
                KanbanCreateTaskRequest(
                    title: trimmedTitle,
                    body: taskBody.isEmpty ? nil : taskBody,
                    assignee: assignee.isEmpty ? nil : assignee,
                    priority: priority,
                    triage: initialStatus == "triage"
                ),
                initialStatus: initialStatus
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            if let kanbanError = error as? KanbanServiceError, case .taskCreatedButMoveFailed = kanbanError {
                didCreate = true
            }
        }
    }
}

struct KanbanTaskDetailView: View {
    /// Editable fields as last synced from the server. The draft fields below
    /// are compared against this so a 4-second poll can refresh comments,
    /// runs, and metadata WITHOUT ever overwriting unsaved user edits.
    private struct ServerBaseline: Equatable {
        var title: String
        var bodyText: String
        var status: String
    }

    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss
    let initialTask: KanbanTask
    @State private var detail: KanbanTaskDetail?
    // Draft (editable) state - owned by the user until saved.
    @State private var title: String
    @State private var taskBody: String
    @State private var status: String
    @State private var baseline: ServerBaseline
    @State private var remoteChangeNotice: String?
    @State private var comment = ""
    @State private var isSaving = false
    @State private var isAddingComment = false
    @State private var isLoadingDetail = false
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var refreshErrorMessage: String?

    init(task: KanbanTask) {
        initialTask = task
        _title = State(initialValue: task.title)
        _taskBody = State(initialValue: task.body ?? "")
        _status = State(initialValue: task.status)
        _baseline = State(initialValue: ServerBaseline(title: task.title, bodyText: task.body ?? "", status: task.status))
    }

    private var currentTask: KanbanTask {
        detail?.task ?? initialTask
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    editorSection
                    metadataSection
                    commentsSection
                    runsSection
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
                    Menu {
                        Button(role: .destructive) { showDeleteConfirmation = true } label: {
                            Label("Delete task", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Task actions")
                }
            }
            .task(id: initialTask.id) {
                while !Task.isCancelled {
                    await loadDetail()
                    do {
                        try await Task.sleep(nanoseconds: KanbanPollingPolicy.detailIntervalNanoseconds)
                    } catch {
                        break
                    }
                }
            }
            .alert("Delete this task?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) { Task { await deleteTask() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the task from the selected Hermes board.")
            }
        }
    }

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $title)
                .font(.headline)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $taskBody)
                .frame(minHeight: 150)
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

    private var metadataSection: some View {
        ConduitSettingsSection(title: "Details", symbol: "info.circle", tint: .conduitAura) {
            SettingsMetricRow(label: "ID", value: currentTask.id, lineLimit: 1)
            if let assignee = currentTask.assignee, !assignee.isEmpty {
                SettingsMetricRow(label: "Assignee", value: assignee, lineLimit: 1)
            }
            if let priority = currentTask.priority {
                SettingsMetricRow(label: "Priority", value: String(priority))
            }
            if let workspace = currentTask.workspacePath, !workspace.isEmpty {
                SettingsMetricRow(label: "Workspace", value: workspace, lineLimit: 2)
            }
            if let result = currentTask.result, !result.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Result")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(result)
                        .font(.footnote)
                }
            }
        }
    }

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
                .frame(minHeight: 80)
                .padding(4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            Button {
                Task { await addComment() }
            } label: {
                HStack {
                    Spacer()
                    if isAddingComment { ProgressView() } else { Label("Add comment", systemImage: "paperplane") }
                    Spacer()
                }
            }
            .buttonStyle(.bordered)
            .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingComment)
        }
    }

    @ViewBuilder
    private var runsSection: some View {
        if let runs = detail?.runs, !runs.isEmpty {
            ConduitSettingsSection(title: "Runs", symbol: "terminal", tint: .orange) {
                ForEach(runs) { run in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: run.status == "completed" ? "checkmark.circle" : "circle.dotted")
                            .foregroundStyle(run.status == "completed" ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run.status.capitalized).font(.subheadline.weight(.medium))
                            if let summary = run.summary, !summary.isEmpty {
                                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            if let error = run.error, !error.isEmpty {
                                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func loadDetail(force: Bool = false) async {
        // A poll never runs underneath an active save/comment write.
        guard force || (!isSaving && !isAddingComment), !isLoadingDetail else { return }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let loaded = try await store.fetchTaskDetail(id: initialTask.id)
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
        } catch {
            if detail == nil {
                errorMessage = error.localizedDescription
            } else {
                refreshErrorMessage = error.localizedDescription
            }
        }
    }

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
            // Reconcile the draft with the saved representation and clear the
            // dirty state before the next poll cycle lands.
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

    private func addComment() async {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isAddingComment = true
        errorMessage = nil
        defer { isAddingComment = false }
        do {
            try await store.addComment(taskID: currentTask.id, body: text)
            comment = ""
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
