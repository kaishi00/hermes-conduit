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

/// Permanent deletion from CARDS is a two-step action (Kanban V2
/// correctness). Card entry points — the ellipsis menu AND the context menu —
/// only STAGE a confirmation request; the destructive DELETE is issued solely
/// by an explicit confirmation. Lane moves and Archive stay immediate and
/// non-destructive.
enum KanbanCardDeletePolicy {
    enum Request: Equatable {
        case none
        case confirm(KanbanTask)
        case perform(KanbanTask)
    }

    /// What a card's Delete… entry resolves to: NEVER the destructive
    /// mutation by itself.
    static func cardRequestedDelete(for task: KanbanTask) -> Request {
        .confirm(task)
    }

    /// Cancellation stages nothing.
    static func cancelled() -> Request {
        .none
    }

    /// Only an explicit confirm resolves to the destructive request.
    static func confirmed(staged: KanbanTask?) -> Request {
        staged.map { .perform($0) } ?? .none
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
    /// Permanent deletion from a card is a TWO-STEP action (V2): BOTH card
    /// entry points (ellipsis menu and context menu) stage the task here,
    /// and only an explicit confirmation issues the destructive DELETE.
    /// Archive and lane moves stay immediate.
    @State private var pendingDeleteTask: KanbanTask?

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
            KanbanTaskComposerView(initialStatus: newTaskStatus)
                .environmentObject(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Permanent deletion from cards is CONFIRMED before the DELETE is
        // issued; the wording matches the detail screen's delete alert. The
        // staged task is passed BY VALUE through the alert's presenting
        // binding, so the destructive action never depends on reading
        // mutable state that alert dismissal may already have cleared.
        .alert(
            "Delete this task?",
            isPresented: Binding(
                get: { pendingDeleteTask != nil },
                set: { if !$0 { pendingDeleteTask = nil } }
            ),
            presenting: pendingDeleteTask
        ) { task in
            Button("Delete", role: .destructive) { confirmCardDelete(task) }
            Button("Cancel", role: .cancel) { pendingDeleteTask = nil }
        } message: { _ in
            Text("This permanently removes the task from the selected Hermes board.")
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
                                hasDispatcherFallback: !(store.orchestration?.resolvedDefaultAssignee ?? "").isEmpty,
                                onOpen: { selectedTask = task },
                                onMove: { status in Task { await move(task, to: status) } },
                                onArchive: { Task { await archive(task) } },
                                onDelete: { stageCardDelete(task) }
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.bottom, 14)
                }
                // Navigation invariant: while the newly selected board is
                // still loading, the visible cards belong to the OLD board.
                // Keep them as read-only cached content - no taps, menus,
                // moves, or deletes - until the new snapshot lands.
                .disabled(!store.isSelectedSnapshotLoaded)
                .overlay(alignment: .top) {
                    if !store.isSelectedSnapshotLoaded {
                        Label("Loading \(store.selectedBoardMetadata?.name ?? store.resolvedSelectedBoardSlug)…", systemImage: "hourglass")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
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

    /// THE canonical visible-lane answer. Every consumer — the chip
    /// highlight, the card list, and the New Task button's initial status —
    /// must ask this instead of reading raw `selectedLane`, which stays nil
    /// until the user explicitly taps a chip even though a lane IS resolved
    /// for display (first unlocked lane). See KanbanLanePolicy.
    private var effectiveSelectedLane: String? {
        KanbanLanePolicy.effectiveSelectedLane(selected: selectedLane, columns: visibleColumns)
    }

    private func resolvedLaneName(columns: [KanbanColumn]) -> String? {
        KanbanLanePolicy.effectiveSelectedLane(selected: selectedLane, columns: columns)
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
                // The global + creates relative to the lane the UI actually
                // considers visible (effectiveSelectedLane), NOT the raw chip
                // selection — selectedLane stays nil until a chip is tapped,
                // and falling back to Todo then would ignore the resolved
                // visible lane. Locked lanes collapse to the default unlocked
                // landing status.
                newTaskStatus = KanbanLanePolicy.newTaskInitialStatus(effectiveLane: effectiveSelectedLane)
                showNewTask = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 36, height: 36)
            }
            .conduitGlassControl(cornerRadius: 14, tint: .conduitAccent.opacity(0.12))
            .disabled(store.board == nil || store.isMutating || !store.isSelectedSnapshotLoaded)
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
        // The store owns mutation-error presentation for the CURRENT
        // generation; a completion that lost ownership after a server/board
        // switch is deliberately inert, so there is no second error channel
        // here that could resurface a stale failure.
        _ = try? await store.updateTask(id: task.id, patch: KanbanTaskPatch(status: status), includeArchived: includeArchived)
    }

    /// Upstream archive semantics: a plain PATCH status='archived'
    /// (kanban_db.archive_task). NOT destructive, so no confirmation.
    private func archive(_ task: KanbanTask) async {
        guard task.status != "archived" else { return }
        _ = try? await store.updateTask(id: task.id, patch: KanbanTaskPatch(status: "archived"), includeArchived: includeArchived)
    }

    private func delete(_ task: KanbanTask) async {
        _ = try? await store.deleteTask(id: task.id, includeArchived: includeArchived)
    }

    /// A card's Delete… entry STAGES the shared board-level confirmation; it
    /// never issues the destructive mutation directly.
    private func stageCardDelete(_ task: KanbanTask) {
        if case .confirm(let staged) = KanbanCardDeletePolicy.cardRequestedDelete(for: task) {
            pendingDeleteTask = staged
        }
    }

    /// Only an explicit confirmation resolves the staged request to a
    /// permanent DELETE. The staged task arrives BY VALUE from the alert's
    /// presenting binding, so presentation-dismissal ordering can never
    /// detach the action from its task.
    private func confirmCardDelete(_ staged: KanbanTask) {
        pendingDeleteTask = nil
        guard case .perform(let task) = KanbanCardDeletePolicy.confirmed(staged: staged) else { return }
        Task { await delete(task) }
    }
}

private struct KanbanCardView: View {
    let task: KanbanTask
    /// Whether Hermes has ANY configured default assignee fallback. When not,
    /// an unassigned ready card would silently never run — worth surfacing.
    var hasDispatcherFallback: Bool = true
    let onOpen: () -> Void
    let onMove: (String) -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    private var presentation: KanbanStatusPresentation {
        KanbanStatusPresentation.forStatus(task.status)
    }

    private var statusOptions: [KanbanStatusPresentation] {
        KanbanStatusPresentation.manuallySelectableStatuses.filter { $0.rawValue != task.status }
    }

    private var liveness: KanbanCardLiveness.State? {
        KanbanCardLiveness.state(for: task)
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
                        // The CURRENT lane stays visible but inert, matching
                        // desktop StatusMenu (name === status || !locked): a
                        // non-control child renders as a disabled Menu row.
                        HStack {
                            Label(presentation.displayName, systemImage: presentation.systemImage)
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityHint("Current lane")
                    }
                    Section {
                        Button {
                            copy(text: task.id, notice: "Task ID copied")
                        } label: {
                            Label("Copy Task ID", systemImage: "doc.on.doc")
                        }
                        Button {
                            copy(text: task.title, notice: "Title copied")
                        } label: {
                            Label("Copy Task Title", systemImage: "doc.on.doc.fill")
                        }
                    }
                    Section {
                        // First-class archive: plain PATCH semantics upstream,
                        // so no destructive confirmation language.
                        Button(action: onArchive) {
                            Label("Archive", systemImage: "archivebox")
                        }
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete…", systemImage: "trash")
                        }
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

            operationalFooter
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
        // VoiceOver: expose the whole card as one tappable "Open task" button
        // while keeping the ellipsis menu and context actions intact.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens task details")
        .accessibilityAction(named: "Open task", onOpen)
        .accessibilityAction(named: "Copy task ID") { copy(text: task.id, notice: "Task ID copied") }
        .accessibilityAction(named: "Copy task title") { copy(text: task.title, notice: "Title copied") }
        .contextMenu {
            Button { onOpen() } label: { Label("Open", systemImage: "arrow.up.right.square") }
            ForEach(statusOptions) { status in
                Button { onMove(status.rawValue) } label: {
                    Label("Move to \(status.displayName)", systemImage: status.systemImage)
                }
            }
            Button { copy(text: task.id, notice: "Task ID copied") } label: {
                Label("Copy Task ID", systemImage: "doc.on.doc")
            }
            Button { copy(text: task.title, notice: "Title copied") } label: {
                Label("Copy Task Title", systemImage: "doc.on.doc.fill")
            }
            Divider()
            Button(action: onArchive) { Label("Archive", systemImage: "archivebox") }
            Button(role: .destructive, action: onDelete) { Label("Delete…", systemImage: "trash") }
        }
    }

    /// Selective operational indicators (V2 §20): short ID, child progress,
    /// link counts, diagnostics warnings, run clock / stale heartbeat, and
    /// the genuine silent-failure warning — nothing decorative.
    @ViewBuilder
    private var operationalFooter: some View {
        HStack(spacing: 8) {
            if liveness == .stale {
                Label("no heartbeat", systemImage: "heartbeat.slash")
                    .foregroundStyle(.orange)
            } else if task.status == "running", let elapsed = KanbanCardLiveness.elapsedText(startedAt: task.startedAt) {
                Label(elapsed, systemImage: "timer")
                    .foregroundStyle(KanbanStatusPresentation.forStatus("running").tint)
            }
            if task.status == "ready", (task.assignee ?? "").isEmpty, !hasDispatcherFallback {
                Label("won't run", systemImage: "bolt.slash")
                    .foregroundStyle(.orange)
            }
            if let progress = task.progress, progress.total > 0 {
                Label("\(progress.done)/\(progress.total)", systemImage: "checklist")
            }
            if let comments = task.commentCount, comments > 0 {
                Label(String(comments), systemImage: "bubble.left")
            }
            let links = (task.linkCounts?.parents ?? 0) + (task.linkCounts?.children ?? 0)
            if links > 0 {
                Label(String(links), systemImage: "arrow.triangle.branch")
            }
            if let priority = task.priority, priority > 0 {
                Label(String(priority), systemImage: "flag.fill")
            }
            Spacer(minLength: 0)
            if let warnings = task.warnings, warnings.count > 0 {
                Label(String(warnings.count), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Text(KanbanShortID.of(task.id))
                .font(.caption2.monospaced())
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func copy(text: String, notice: String) {
        KanbanClipboard.copy(text, announcement: notice)
    }
}

// The minimal New Task editor was superseded by KanbanTaskComposerView
// (Conduit/Views/Kanban/KanbanTaskComposerView.swift) in Kanban V2.
