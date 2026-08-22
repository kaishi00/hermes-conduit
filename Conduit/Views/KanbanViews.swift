import SwiftUI

enum KanbanPollingPolicy {
    static let boardIntervalNanoseconds: UInt64 = 8_000_000_000
    static let detailIntervalNanoseconds: UInt64 = 4_000_000_000
}

struct KanbanView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = KanbanStore()
    @State private var selectedTask: KanbanTask?
    @State private var showNewTask = false
    @State private var newTaskStatus = "todo"
    @State private var includeArchived = false
    @State private var searchText = ""

    private var bridgeIdentity: ObjectIdentifier? {
        appState.dashboardTicketBridge.map { ObjectIdentifier($0) }
    }

    private var configurationKey: String {
        "\(String(describing: bridgeIdentity))|\(appState.dashboardTicketBridge?.baseURL ?? "")|\(appState.activeProfile)"
    }

    private var pollingKey: String {
        "\(configurationKey)|archived=\(includeArchived)"
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
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(visibleColumns) { column in
                                KanbanColumnView(
                                    column: column,
                                    onOpenTask: { selectedTask = $0 },
                                    onAddTask: { status in
                                        newTaskStatus = status
                                        showNewTask = true
                                    },
                                    onMoveTask: { task, status in
                                        Task { await move(task, to: status) }
                                    },
                                    onDeleteTask: { task in
                                        Task { await delete(task) }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 12)
                    }
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
                profile: appState.activeProfile,
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
                newTaskStatus = "todo"
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

private struct KanbanColumnView: View {
    let column: KanbanColumn
    let onOpenTask: (KanbanTask) -> Void
    let onAddTask: (String) -> Void
    let onMoveTask: (KanbanTask, String) -> Void
    let onDeleteTask: (KanbanTask) -> Void

    private var presentation: KanbanStatusPresentation {
        KanbanStatusPresentation.forStatus(column.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: presentation.systemImage)
                    .foregroundStyle(presentation.tint)
                Text(presentation.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(String(column.tasks.count))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if presentation.isTaskCreatable {
                    Button { onAddTask(column.name) } label: {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Add task to " + presentation.displayName)
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(column.tasks) { task in
                        KanbanCardView(
                            task: task,
                            onOpen: { onOpenTask(task) },
                            onMove: { onMoveTask(task, $0) },
                            onDelete: { onDeleteTask(task) }
                        )
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(minHeight: 160, maxHeight: 560)
        }
        .padding(11)
        .frame(width: 286, alignment: .topLeading)
        .conduitGlassSurface(cornerRadius: 22, tint: presentation.tint.opacity(0.06))
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
    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss
    let initialTask: KanbanTask
    @State private var detail: KanbanTaskDetail?
    @State private var title: String
    @State private var taskBody: String
    @State private var status: String
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
    }

    private var currentTask: KanbanTask {
        detail?.task ?? initialTask
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
        guard force || (!isSaving && !isAddingComment), !isLoadingDetail else { return }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let loaded = try await store.fetchTaskDetail(id: initialTask.id)
            detail = loaded
            title = loaded.task.title
            taskBody = loaded.task.body ?? ""
            status = loaded.task.status
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
        if trimmedTitle != current.title { patch.title = trimmedTitle }
        if taskBody != (current.body ?? "") { patch.body = taskBody }
        if status != current.status {
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
            _ = try await store.updateTask(id: current.id, patch: patch)
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
