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

/// A staged destructive delete request: the task captured BY VALUE plus the
/// loaded board/server context (KanbanBoardContextStamp) that staged it.
/// The task id alone is deliberately NOT the ownership token — ids can
/// collide across independent boards/servers.
struct PendingCardDelete: Equatable {
    let task: KanbanTask
    let stamp: KanbanBoardContextStamp

    var taskID: String { task.id }
}

/// Permanent deletion from CARDS is a two-step action (Kanban V2
/// correctness). Card entry points — the ellipsis menu AND the context menu —
/// only STAGE a confirmation request BOUND to the board/server context that
/// staged it; the destructive DELETE is issued solely by an explicit
/// confirmation that still owns that exact context. Lane moves and Archive
/// stay immediate and non-destructive.
enum KanbanCardDeletePolicy {
    enum Request: Equatable {
        case none
        case confirm(PendingCardDelete)
        case perform(KanbanTask)
    }

    /// What a card's Delete… entry resolves to: NEVER the destructive
    /// mutation by itself — always a context-stamped confirmation.
    static func cardRequestedDelete(for task: KanbanTask, stamp: KanbanBoardContextStamp) -> Request {
        .confirm(PendingCardDelete(task: task, stamp: stamp))
    }

    /// Cancellation stages nothing.
    static func cancelled() -> Request {
        .none
    }

    /// FAIL-CLOSED ownership validation at the destructive boundary: the
    /// staged confirmation may resolve to a DELETE only while the store's
    /// currently loaded context is EXACTLY the context that staged it (same
    /// board slug AND same configuration generation) and the visible
    /// snapshot is still the actionable one. After a board switch, a server
    /// reconfigure, or during in-flight board navigation, the stale request
    /// is discarded without sending anything.
    static func confirmed(
        staged: PendingCardDelete?,
        currentStamp: KanbanBoardContextStamp?,
        isSnapshotActionable: Bool
    ) -> Request {
        guard isSnapshotActionable,
              let staged,
              let currentStamp,
              staged.stamp == currentStamp else { return .none }
        return .perform(staged.task)
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
    /// entry points (ellipsis menu and context menu) stage the task here
    /// TOGETHER WITH the loaded board/server context that staged it, and
    /// only an explicit confirmation that still owns that context issues the
    /// destructive DELETE. Archive and lane moves stay immediate.
    @State private var pendingDelete: PendingCardDelete?
    /// V3A board-level administration: orchestration settings sheet,
    /// profile routing descriptions, and the manual dispatcher nudge.
    @State private var showOrchestrationSettings = false
    @State private var showProfileRouting = false
    /// Unobtrusive post-nudge feedback ("Dispatcher nudged"); transient only.
    /// Token-guarded so a rapid second nudge OR a board switch invalidates an
    /// older auto-hide timer (a stale timer must never clear a newer notice).
    @State private var nudgeNoticeState = KanbanNudgeNoticeState()
    /// V3B board administration: editor sheets + staged archive confirmation.
    @State private var showBoardSettings = false
    @State private var showNewBoard = false
    @State private var pendingBoardArchive: PendingBoardArchive?
    /// V3B filters. Assignee/tenant are TRANSIENT view state (never persisted
    /// across servers); Show Archived keeps its existing semantics; Group
    /// Running by Profile is a persisted UI preference (desktop parity).
    @State private var showFilters = false
    @State private var assigneeFilter: String?
    @State private var tenantFilter: String?
    @AppStorage("conduit.kanbanGroupRunningByProfile") private var groupRunningByProfile = false
    /// V3C multi-select + bulk operations. Selection belongs to ONE exact
    /// board/server context captured when selection mode begins; the selected
    /// IDs alone are never ownership.
    @State private var selectionContext: KanbanBoardContextStamp?
    @State private var selectedTaskIDs: Set<String> = []
    @State private var bulkBusy = false
    @State private var bulkLiveness = KanbanEditorLiveness()
    @State private var pendingBulkOperation: PendingBulkOperation?
    @State private var pendingBulkDelete: PendingBulkDelete?
    @State private var showBulkMove = false
    @State private var showBulkAssign = false
    @State private var showBulkPriority = false
    @State private var showBulkFailures = false
    @State private var lastBulkOutcome: KanbanBulkOperationOutcome?
    @State private var bulkNoticeState = KanbanBulkNoticeState()
    @State private var bulkPriorityValue = 0

    private var bridgeIdentity: ObjectIdentifier? {
        appState.dashboardTicketBridge.map { ObjectIdentifier($0) }
    }

    // MARK: - V3C selection state

    private var isSelectionActive: Bool {
        selectionContext != nil
    }

    /// The selection is usable only while its captured stamp still equals the
    /// current actionable loaded context.
    private var isSelectionOwned: Bool {
        KanbanBulkSelectionPolicy.isOwned(
            selectionContext: selectionContext,
            currentStamp: store.loadedContextStamp,
            isSnapshotActionable: store.isSelectedSnapshotLoaded
        )
    }

    private var sortedSelectedIDs: [String] {
        selectedTaskIDs.sorted()
    }

    private func exitSelectionMode() {
        selectionContext = nil
        selectedTaskIDs = []
        pendingBulkOperation = nil
        pendingBulkDelete = nil
        bulkStagedSelection = nil
        showBulkMove = false
        showBulkAssign = false
        showBulkPriority = false
        lastBulkOutcome = nil
        bulkNoticeState.clear()
        showBulkFailures = false
    }

    /// Prune selected IDs against the authoritative loaded board (polling
    /// keeps running during selection mode). Tasks that disappeared from the
    /// board are dropped; lane switches never prune.
    private func pruneSelectionAgainstBoard() {
        guard let board = store.board, !selectedTaskIDs.isEmpty else { return }
        let alive = Set(board.columns.flatMap { $0.tasks.map(\.id) })
        let pruned = KanbanBulkSelectionPolicy.prune(selected: selectedTaskIDs, aliveTaskIDs: alive)
        if pruned != selectedTaskIDs {
            selectedTaskIDs = pruned
            if pruned.isEmpty { exitSelectionMode() }
        }
    }

    /// Configuration/polling key. Deliberately EXCLUDES appState.activeProfile:
    /// Hermes Kanban is a shared cross-profile board anchored at the Hermes
    /// root, so Conduit's UI profile switch does not change Kanban data.
    private var pollingKey: String {
        "\(String(describing: bridgeIdentity))|\(appState.dashboardTicketBridge?.baseURL ?? "")|archived=\(includeArchived)"
    }

    /// Server identity only (bridge + URL). When THIS changes, administrator
    /// sheets (orchestration settings / profiles) owned by the old server
    /// must not remain open over the new one: a settings editor seeded from
    /// A would otherwise sit on top of B. Board selection within the same
    /// server does NOT dismiss them (their data is server-global), and
    /// ordinary board polling never changes this key.
    private var serverIdentityKey: String {
        "\(String(describing: bridgeIdentity))|\(appState.dashboardTicketBridge?.baseURL ?? "")"
    }

    private var visibleColumns: [KanbanColumn] {
        guard let board = store.board else { return [] }
        return KanbanBoardFilterPolicy.visibleColumns(
            board: board,
            search: searchText,
            assignee: assigneeFilter,
            tenant: tenantFilter
        )
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
                                if let nudgeNotice = nudgeNoticeState.notice {
                                    Label(nudgeNotice, systemImage: "checkmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                        .padding(8)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .transition(.opacity)
                                }
                                if let bulkNotice = bulkNoticeState.text {
                                    Label(bulkNotice, systemImage: bulkNoticeState.kind == .success ? "checkmark.circle" : "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(bulkNoticeState.kind == .success ? Color.green : Color.orange)
                                        .padding(8)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .transition(.opacity)
                                }
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
        .sheet(isPresented: $showOrchestrationSettings) {
            KanbanOrchestrationSettingsSheet()
                .environmentObject(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showProfileRouting) {
            KanbanProfileRoutingScreen()
                .environmentObject(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBoardSettings) {
            // Board Settings is tied to the CONCRETE loaded board (never a
            // re-read of the mutable selection); the button is disabled while
            // no loaded metadata exists.
            if let board = loadedBoardMetadata {
                KanbanBoardEditorView(mode: .settings(board: board), includeArchived: includeArchived)
                    .environmentObject(store)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showNewBoard) {
            KanbanBoardEditorView(mode: .create, includeArchived: includeArchived)
                .environmentObject(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFilters) {
            KanbanBoardFilterSheet(
                includeArchived: $includeArchived,
                assigneeFilter: $assigneeFilter,
                tenantFilter: $tenantFilter,
                groupRunningByProfile: $groupRunningByProfile
            )
            .environmentObject(store)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        // V3C: bulk action sheets all consume the FROZEN staged selection;
        // composition can never re-read the live selection or context.
        .sheet(isPresented: $showBulkMove, onDismiss: { bulkStagedSelection = nil }) {
            bulkMoveSheet
        }
        .sheet(isPresented: $showBulkAssign, onDismiss: { bulkStagedSelection = nil }) {
            bulkAssignSheet
        }
        .sheet(isPresented: $showBulkPriority, onDismiss: { bulkStagedSelection = nil }) {
            bulkPrioritySheet
        }
        .sheet(isPresented: $showBulkFailures) {
            bulkFailuresSheet
        }
        .confirmationDialog(
            "Archive Board?",
            isPresented: Binding(
                get: { pendingBoardArchive != nil },
                set: { if !$0 { pendingBoardArchive = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingBoardArchive
        ) { staged in
            Button("Archive", role: .destructive) { confirmBoardArchive(staged) }
            Button("Cancel", role: .cancel) { pendingBoardArchive = nil }
        } message: { staged in
            Text("Archive “\(staged.displayName)”?\nThe board will be removed from the active board list. Its tasks are not being permanently deleted.")
        }
        // Permanent deletion from cards is CONFIRMED before the DELETE is
        // issued; the wording matches the detail screen's delete alert. The
        // staged request (task + staging context) is passed BY VALUE through
        // the alert's presenting binding, so the destructive action never
        // depends on reading mutable state that alert dismissal may already
        // have cleared — and confirmCardDelete re-validates context
        // ownership before anything is sent.
        .alert(
            "Delete this task?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { staged in
            Button("Delete", role: .destructive) { confirmCardDelete(staged) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This permanently removes the task from the selected Hermes board.")
        }
        // V3C: bulk destructive confirmations operate on the STAGED immutable
        // values (frozen ids + context), never on the live selection.
        .confirmationDialog(
            bulkArchiveTitle,
            isPresented: Binding(
                get: { pendingBulkOperation != nil && pendingBulkOperation?.action == .archive },
                set: { if !$0 { pendingBulkOperation = nil; bulkStagedSelection = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingBulkOperation
        ) { staged in
            Button(bulkArchiveActionTitle(count: staged.ids.count), role: .destructive) {
                // Consumed: the stage must not survive into a later action.
                pendingBulkOperation = nil
                bulkStagedSelection = nil
                runBulk(PendingBulkOperation(ids: staged.ids, context: staged.context, action: .archive))
            }
            Button("Cancel", role: .cancel) { pendingBulkOperation = nil; bulkStagedSelection = nil }
        } message: { staged in
            Text("They will be moved out of the active board view. Tasks are not being permanently deleted.")
        }
        .confirmationDialog(
            bulkDeleteTitle,
            isPresented: Binding(
                get: { pendingBulkDelete != nil },
                set: { if !$0 { pendingBulkDelete = nil; bulkStagedSelection = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingBulkDelete
        ) { staged in
            Button(bulkDeleteActionTitle(count: staged.taskIDs.count), role: .destructive) {
                confirmBulkDelete(staged)
            }
            Button("Cancel", role: .cancel) { cancelBulkDelete() }
        } message: { _ in
            Text("This will permanently delete the selected tasks. This action cannot be undone.")
        }
        // Proactive disarm: when the loaded board identity changes, any
        // staged destructive confirmation is now foreign. (The confirm-time
        // ownership check below remains the hard boundary.)
        .onChange(of: store.loadedBoardSlug) { _, _ in
            pendingDelete = nil
            // V3A merge pass: a board switch drops any visible nudge feedback
            // IMMEDIATELY (the alpha success capsule must never linger on
            // beta) and bumps the token so the old auto-hide timer can never
            // mutate a later notice.
            nudgeNoticeState.invalidateOnContextChange()
            // V3B: a staged archive, the board-settings/new-board editors and
            // the filter sheet (board-scoped rosters) belong to the PREVIOUS
            // board - disarm/dismiss them, and clear transient filters so no
            // stale roster value lingers in the UI state.
            pendingBoardArchive = nil
            showBoardSettings = false
            showNewBoard = false
            showFilters = false
            assigneeFilter = nil
            tenantFilter = nil
            // V3C: a board switch invalidates every selected ID - selection
            // is owned by the previous board/server context.
            exitSelectionMode()
        }
        .onChange(of: serverIdentityKey) { _, _ in
            // Server changed: the admin sheets belonged to the old server.
            showOrchestrationSettings = false
            showProfileRouting = false
            showBoardSettings = false
            showNewBoard = false
            showFilters = false
            pendingBoardArchive = nil
            nudgeNoticeState.invalidateOnContextChange()
            exitSelectionMode()
        }
        // V3C: the authoritative board keeps polling during selection mode;
        // prune ghost selections against it (never transfer by index).
        .onChange(of: store.board) { _, _ in
            pruneSelectionAgainstBoard()
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

    /// Manual dispatcher nudge (V3A §5): a lightweight board action with
    /// unobtrusive feedback. The board/server stamp is captured
    /// SYNCHRONOUSLY by nudgeTapped() before any Task; the store revalidates
    /// it at its mutation boundary. No diagnostics are fabricated from the
    /// backend response (the desktop renders none either).
    private func nudgeTapped() {
        guard !store.isMutating, store.isSelectedSnapshotLoaded,
              let stamp = store.loadedContextStamp else { return }
        Task { await nudgeDispatcher(context: stamp) }
    }

    private func nudgeDispatcher(context: KanbanBoardContextStamp) async {
        do {
            try await store.nudgeDispatcher(expectedContext: context, includeArchived: includeArchived)
            // V3A final pass: a /dispatch that succeeded on the OLD server
            // after the UI moved elsewhere is UI-inert - its success must
            // never surface as feedback on the new context.
            guard KanbanNudgePolicy.shouldShowNotice(
                capturedStamp: context,
                currentStamp: store.loadedContextStamp,
                isSnapshotActionable: store.isSelectedSnapshotLoaded
            ) else { return }
            var token = 0
            withAnimation(.easeOut(duration: 0.15)) {
                token = nudgeNoticeState.show("Dispatcher nudged")
            }
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return // cancelled (view dismissed / task replaced): leave as-is
            }
            guard !Task.isCancelled else { return }
            // Only the notice instance whose token is still current may clear
            // itself (a newer nudge or a board switch already invalidated it).
            withAnimation(.easeOut(duration: 0.3)) { nudgeNoticeState.hideIfCurrent(token) }
        } catch {
            // Store-owned mutation error presentation (current generation only).
        }
    }

    // MARK: - V3B board administration helpers

    /// The metadata of the CONCRETE board currently loaded (nil while
    /// loading/navigation keeps a stale snapshot visible).
    private var loadedBoardMetadata: KanbanBoardMetadata? {
        guard let slug = store.loadedBoardSlug else { return nil }
        return store.boards.first { $0.slug == slug }
    }

    /// Archive targets the concrete LOADED board and is refused for the
    /// backend-immortal default board (remove_board raises; surfaced as 400).
    private var canArchiveSelectedBoard: Bool {
        guard let slug = store.loadedBoardSlug,
              store.isSelectedSnapshotLoaded,
              !store.isMutating else { return false }
        return slug != "default"
    }

    /// Stage the archive BY VALUE (slug + name + board/server stamp) at the
    /// menu tap; only an explicit confirmation that still owns the stamp may
    /// archive, and the store revalidates the stamp at its mutation boundary.
    private func stageBoardArchive() {
        guard let slug = store.loadedBoardSlug,
              let stamp = store.loadedContextStamp,
              store.isSelectedSnapshotLoaded else { return }
        let name = loadedBoardMetadata?.name ?? slug
        pendingBoardArchive = PendingBoardArchive(slug: slug, displayName: name, stamp: stamp)
    }

    private func confirmBoardArchive(_ staged: PendingBoardArchive) {
        pendingBoardArchive = nil
        Task {
            try? await store.archiveBoard(
                slug: staged.slug,
                expectedContext: staged.stamp,
                includeArchived: includeArchived
            )
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
                        if KanbanRunningGroupPolicy.shouldApply(lane: column.name, enabled: groupRunningByProfile) {
                            // V3B: Running grouped by profile - AFTER all
                            // filters (the column above is already filtered).
                            ForEach(KanbanRunningGroupPolicy.group(column.tasks)) { group in
                                runningGroupHeader(group)
                                ForEach(group.tasks) { task in
                                    taskCard(task)
                                }
                            }
                        } else {
                            ForEach(column.tasks) { task in
                                taskCard(task)
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.bottom, 14)
                }
                // NOTE: bottom action bar is applied as an overlay on the
                // whole lane board (see laneBoard modifiers).
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
        // V3C: bottom action bar while selection is active (compact height,
        // above the home indicator; safe-area-inset aware).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectionActive {
                bulkActionBar
            }
        }
    }

    // MARK: - V3C card interactions

    @ViewBuilder
    private func taskCard(_ task: KanbanTask) -> some View {
        let isSelected = selectedTaskIDs.contains(task.id)
        let actionsInert = isSelectionActive || bulkBusy
        if isSelectionActive {
            // Selection-mode a11y: announce selection state per card; the
            // base combined "Open task" accessibility behavior stays intact
            // outside selection mode (review M5).
            cardCore(task: task, isSelected: isSelected, actionsInert: actionsInert)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityLabel(selectionA11yLabel(task: task, isSelected: isSelected))
        } else {
            cardCore(task: task, isSelected: isSelected, actionsInert: actionsInert)
        }
    }

    /// Selection-mode VoiceOver label: status/lane context retained + the
    /// selection state (review: never color-only, never strictly ID-only).
    private func selectionA11yLabel(task: KanbanTask, isSelected: Bool) -> Text {
        let lane = KanbanStatusPresentation.forStatus(task.status).displayName
        let body = task.latestSummary ?? task.title
        return Text((isSelected ? "Task \(task.id), selected" : "Task \(task.id), not selected") + ", " + lane + ": " + body)
    }

    private func cardCore(task: KanbanTask, isSelected: Bool, actionsInert: Bool) -> some View {
        let inertMove: (String) -> Void = { _ in }
        let inertTap: () -> Void = {}
        return KanbanCardView(
            task: task,
            hasDispatcherFallback: !(store.orchestration?.resolvedDefaultAssignee ?? "").isEmpty,
            isMenusDisabled: actionsInert,
            onOpen: {
                // Selection mode: normal card tap TOGGLES selection and must
                // never open the detail sheet.
                if isSelectionActive {
                    toggleSelection(task.id)
                } else {
                    selectedTask = task
                }
            },
            onMove: actionsInert ? inertMove : { status in Task { await move(task, to: status) } },
            onArchive: actionsInert ? inertTap : { Task { await archive(task) } },
            onDelete: actionsInert ? inertTap : { stageCardDelete(task) }
        )
        .overlay(alignment: .topTrailing) {
            if isSelectionActive {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        // No long-press gesture: the card's native context menu owns the
        // hold (review M6); "Select tasks" is the reliable entry point.
        .scaleEffect(isSelected && isSelectionActive ? 0.985 : 1)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private func enterSelectionMode() {
        guard !isSelectionActive, let stamp = store.loadedContextStamp, store.isSelectedSnapshotLoaded else { return }
        selectionContext = stamp
        selectedTaskIDs = []
        bulkNoticeState.clear()
        lastBulkOutcome = nil
    }

    private func toggleSelection(_ id: String) {
        guard isSelectionOwned, !bulkBusy else { return }
        if selectedTaskIDs.contains(id) {
            selectedTaskIDs.remove(id)
        } else {
            selectedTaskIDs.insert(id)
        }
        if selectedTaskIDs.isEmpty {
            exitSelectionMode()
        }
    }

    // MARK: - V3C bulk action bar

    private var bulkActionBar: some View {
        HStack(spacing: 10) {
            Text(selectedCountLabel)
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel(selectedCountLabel)
            Spacer()
            if bulkBusy {
                ProgressView().controlSize(.small)
            }
            Button {
                // Placeholder payload: the Move sheet composes the real
                // destination from the FROZEN staged selection.
                stageBulk(.move(""))
            } label: {
                Label("Move", systemImage: "arrow.left.arrow.right")
            }
            .disabled(!canRunBulk || bulkBusy)
            .accessibilityLabel("Move \(selectedTaskIDs.count) selected tasks")
            Button {
                // Placeholder payload: the Assign sheet composes the choice.
                stageBulk(.assign(nil))
            } label: {
                Label("Assign", systemImage: "person.fill.badge.plus")
            }
            .disabled(!canRunBulk || bulkBusy)
            .accessibilityLabel("Assign \(selectedTaskIDs.count) selected tasks")
            Menu {
                Button {
                    // BLOCKER fix: Priority MUST route through the same
                    // staging path as every other action - the sheet then
                    // composes from the frozen stage and can never reuse a
                    // stale stage from an earlier Archive/Delete flow. The
                    // payload value is a placeholder (Apply re-freezes it).
                    stageBulk(.priority(0))
                } label: {
                    Label("Set Priority…", systemImage: "number")
                }
                .disabled(!canRunBulk || bulkBusy)
                Button {
                    stageBulk(.archive)
                } label: {
                    Label("Archive…", systemImage: "archivebox")
                }
                .disabled(!canRunBulk || bulkBusy)
                Button(role: .destructive) {
                    stageBulk(.delete)
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                .disabled(!canRunBulk || bulkBusy)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled(!canRunBulk || bulkBusy)
            .accessibilityLabel("More actions for \(selectedTaskIDs.count) selected tasks")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
    }

    private var selectedCountLabel: String {
        let n = selectedTaskIDs.count
        return n == 1 ? "1 task selected" : "\(n) tasks selected"
    }

    private var canRunBulk: Bool {
        isSelectionOwned && !selectedTaskIDs.isEmpty && !bulkBusy
    }

    private var bulkArchiveTitle: String {
        let n = pendingBulkOperation?.ids.count ?? selectedTaskIDs.count
        return n == 1 ? "Archive 1 Task?" : "Archive \(n) Tasks?"
    }

    private func bulkArchiveActionTitle(count: Int) -> String {
        count == 1 ? "Archive 1" : "Archive \(count)"
    }

    private var bulkDeleteTitle: String {
        let n = pendingBulkDelete?.taskIDs.count ?? selectedTaskIDs.count
        return n == 1 ? "Delete 1 Task?" : "Delete \(n) Tasks?"
    }

    private func bulkDeleteActionTitle(count: Int) -> String {
        count == 1 ? "Delete 1" : "Delete \(count)"
    }

    // MARK: - V3C bulk sheets

    private var bulkMoveSheet: some View {
        NavigationStack {
            List {
                ForEach(KanbanBulkDestinationPolicy.moveDestinations(), id: \.id) { presentation in
                    Button {
                        commitBulkFromStage { staged in
                            PendingBulkOperation(ids: staged.ids, context: staged.context, action: .move(presentation.rawValue))
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: presentation.systemImage)
                                .foregroundStyle(presentation.tint)
                            Text(presentation.displayName)
                            Spacer()
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle(moveSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { commitBulkFromStage(nil) }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var moveSheetTitle: String {
        let n = bulkStagedSelection?.ids.count ?? 0
        return n == 1 ? "Move 1 Task" : "Move \(n) Tasks"
    }

    private var bulkAssignSheet: some View {
        NavigationStack {
            List {
                if store.profiles.isEmpty {
                    Text("No profiles on this server yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.profiles) { profile in
                    Button {
                        commitBulkFromStage { staged in
                            PendingBulkOperation(ids: staged.ids, context: staged.context, action: .assign(profile.name))
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(profile.name)
                            Spacer()
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Section {
                    Button("Unassign") {
                        commitBulkFromStage { staged in
                            PendingBulkOperation(ids: staged.ids, context: staged.context, action: .assign(nil))
                        }
                    }
                }
            }
            .navigationTitle(assignSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { commitBulkFromStage(nil) }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var assignSheetTitle: String {
        let n = bulkStagedSelection?.ids.count ?? 0
        return n == 1 ? "Assign 1 Task" : "Assign \(n) Tasks"
    }

    private var prioritySheetTitle: String {
        let n = bulkStagedSelection?.ids.count ?? 0
        return n == 1 ? "Set Priority" : "Set Priority (\(n) tasks)"
    }

    private var bulkPrioritySheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            // Clamped at Int bounds: the numeric field can
                            // hold Int.max/Int.min pasted values; an
                            // unclamped +/- would trap on overflow.
                            if bulkPriorityValue > Int.min { bulkPriorityValue -= 1 }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(bulkStagedSelection == nil || bulkPriorityValue == Int.min)
                        .accessibilityLabel("Decrease priority")
                        TextField("Priority", value: $bulkPriorityValue, format: .number)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.center)
                            .font(.title3.bold())
                            .monospacedDigit()
                            .accessibilityLabel("Priority value")
                        Button {
                            if bulkPriorityValue < Int.max { bulkPriorityValue += 1 }
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(bulkStagedSelection == nil || bulkPriorityValue == Int.max)
                        .accessibilityLabel("Increase priority")
                    }
                    .padding(.vertical, 4)
                } footer: {
                    // Audited contract: upstream applies the verbatim
                    // integer (direct SQL) - NO bounds exist; this control
                    // validates only that the value parses as Int.
                    Text("Any integer is valid; Hermes stores it verbatim (no bounds upstream).")
                }
            }
            .navigationTitle(prioritySheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { commitBulkFromStage(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply to \(bulkStagedSelection?.ids.count ?? 0)") {
                        // Freeze the numeric value synchronously at Apply; the
                        // operation composes from the FROZEN stage ONLY (never
                        // a stale stage from an earlier flow), and the value
                        // never persists across batches.
                        let value = bulkPriorityValue
                        bulkPriorityValue = 0
                        commitBulkFromStage { staged in
                            KanbanBulkStagePolicy.priorityOperation(
                                staged: staged,
                                value: value,
                                currentStamp: store.loadedContextStamp,
                                isSnapshotActionable: store.isSelectedSnapshotLoaded
                            )
                        }
                    }
                    .disabled(bulkStagedSelection == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var bulkFailuresSheet: some View {
        NavigationStack {
            List {
                if let outcome = lastBulkOutcome {
                    ForEach(KanbanBulkResultPolicy.failures(from: outcome), id: \.id) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Task \(failure.id)")
                                .font(.subheadline.weight(.semibold))
                            Text(failure.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Failed Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showBulkFailures = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Consume the frozen staged selection: build the operation if requested
    /// (and it is still owned), run it, and close the sheet. Sheets are
    /// always dismissed through this path - Cancel is a real control.
    private func commitBulkFromStage(_ build: ((BulkStagedSelection) -> PendingBulkOperation?)?) {
        guard let staged = bulkStagedSelection else { return }
        bulkStagedSelection = nil
        showBulkMove = false
        showBulkAssign = false
        showBulkPriority = false
        guard let build, let operation = build(staged) else { return }
        guard operation.context == store.loadedContextStamp, store.isSelectedSnapshotLoaded else { return }
        runBulk(operation)
    }

    // MARK: - V3C staging + execution

    /// Freeze the selected IDs + context SYNCHRONOUSLY at the tap. The frozen
    /// (ids, context) tuple rides through every sheet/menu/confirmation; the
    /// async body operates only on the immutable PendingBulkOperation.
    @State private var bulkStagedSelection: BulkStagedSelection?

    private func stageBulk(_ action: KanbanBulkAction) {
        guard canRunBulk, let context = selectionContext, let stamp = store.loadedContextStamp, context == stamp else { return }
        // A new operation begins: drop any previous result notice/failure
        // presentation so stale feedback never lingers next to a new flow.
        bulkNoticeState.clear()
        lastBulkOutcome = nil
        showBulkFailures = false
        let frozen = BulkStagedSelection(ids: sortedSelectedIDs, context: stamp)
        bulkStagedSelection = frozen
        switch action {
        case .delete:
            pendingBulkDelete = PendingBulkDelete(taskIDs: frozen.ids, context: frozen.context)
        case .archive:
            pendingBulkOperation = PendingBulkOperation(ids: frozen.ids, context: frozen.context, action: .archive)
        case .move:
            showBulkMove = true
        case .assign:
            showBulkAssign = true
        case .priority:
            showBulkPriority = true
        }
    }

    private func runBulk(_ operation: PendingBulkOperation) {
        let token = bulkLiveness.begin()
        bulkBusy = true
        // A new operation begins: clear any previous result notice - a
        // top-level transport failure must never sit next to a stale
        // "2 updated, 1 failed" banner.
        bulkNoticeState.clear()
        lastBulkOutcome = nil
        showBulkFailures = false
        // Snapshot the operation AND the Show-Archived state synchronously;
        // the async body can never re-read the live selection, context, or
        // visibility preference.
        let archived = includeArchived
        Task {
            await performBulk(operation, token: token, includeArchived: archived)
        }
    }

    private func performBulk(_ operation: PendingBulkOperation, token: Int, includeArchived: Bool) async {
        defer {
            if bulkLiveness.owns(token) { bulkBusy = false }
        }
        let ids = operation.ids
        let context = operation.context
        let outcome: KanbanBulkOperationOutcome
        do {
            switch operation.action {
            case .move(let status):
                outcome = try await store.bulkUpdateTasks(
                    ids: ids,
                    patch: KanbanBulkTaskRequest(ids: ids, status: status),
                    expectedContext: context,
                    includeArchived: includeArchived
                )
            case .assign(let profile):
                outcome = try await store.bulkUpdateTasks(
                    ids: ids,
                    patch: KanbanBulkTaskRequest(ids: ids, assignee: profile ?? "", reclaimFirst: true),
                    expectedContext: context,
                    includeArchived: includeArchived
                )
            case .priority(let value):
                outcome = try await store.bulkUpdateTasks(
                    ids: ids,
                    patch: KanbanBulkTaskRequest(ids: ids, priority: value),
                    expectedContext: context,
                    includeArchived: includeArchived
                )
            case .archive:
                outcome = try await store.bulkUpdateTasks(
                    ids: ids,
                    patch: KanbanBulkTaskRequest(ids: ids, archive: true),
                    expectedContext: context,
                    includeArchived: includeArchived
                )
            case .delete:
                outcome = try await store.bulkDeleteTasks(
                    ids: ids,
                    expectedContext: context,
                    includeArchived: includeArchived
                )
            }
        } catch {
            // Top-level failure: per-ID success cannot be proven - every
            // originally selected ID stays selected; the store has already
            // recorded the mutation error and superseding reload as needed.
            if bulkLiveness.owns(token) { bulkBusy = false }
            return
        }
        guard bulkLiveness.owns(token) else { return }
        guard store.isCurrentConfiguration(operation.context.configurationGeneration) else { return }
        // Partial-failure semantics (Desktop parity): successful IDs leave
        // the selection; failed IDs remain for retry.
        apply(outcome: outcome, to: Set(ids))
    }

    private func apply(outcome: KanbanBulkOperationOutcome, to original: Set<String>) {
        let summary = KanbanBulkResultPolicy.summary(outcome: outcome)
        let keep = KanbanBulkResultPolicy.selectionAfterApplying(outcome: outcome, originalSelection: original)
        let hasFailures = !outcome.failures.isEmpty
        if keep.isEmpty {
            // Full success: exit first, then publish the notice so
            // exitSelectionMode() cannot clear it in the same run (F2).
            exitSelectionMode()
        } else {
            selectedTaskIDs = keep
            lastBulkOutcome = outcome
            if hasFailures {
                showBulkFailures = true
            }
        }
        // Partial failure is AMBER feedback ("N updated, M failed"); full
        // success is green. Token-guarded auto-hide (Nudge pattern).
        var token = 0
        withAnimation(.easeOut(duration: 0.25)) {
            token = bulkNoticeState.show(summary, kind: hasFailures ? .warning : .success)
        }
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            bulkNoticeState.hideIfCurrent(token)
        }
    }

    private func confirmBulkDelete(_ staged: PendingBulkDelete) {
        pendingBulkDelete = nil
        bulkStagedSelection = nil
        runBulk(PendingBulkOperation(ids: staged.taskIDs, context: staged.context, action: .delete))
    }

    private func cancelBulkDelete() {
        pendingBulkDelete = nil
        bulkStagedSelection = nil
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
        .disabled(bulkBusy)
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
            .disabled(isSelectionActive || bulkBusy)

            // V3A board-level administration stays behind ONE extra menu so
            // the main header is not overcrowded (task spec: "Kanban / Board
            // Name [ … ]").
            Menu {
                Button {
                    showBoardSettings = true
                } label: {
                    Label("Board Settings…", systemImage: "slider.vertical.3")
                }
                .disabled(loadedBoardMetadata == nil || store.isMutating || !store.isSelectedSnapshotLoaded)

                Button {
                    showNewBoard = true
                } label: {
                    Label("New Board…", systemImage: "square.badge.plus")
                }
                .disabled(store.isMutating || !store.isSelectedSnapshotLoaded)

                Button {
                    stageBoardArchive()
                } label: {
                    Label("Archive Board…", systemImage: "archivebox")
                }
                .disabled(!canArchiveSelectedBoard)

                Divider()

                Button {
                    showOrchestrationSettings = true
                } label: {
                    Label("Orchestration Settings…", systemImage: "slider.horizontal.3")
                }
                .disabled(store.orchestration == nil && store.isLoading)

                Button {
                    showProfileRouting = true
                } label: {
                    Label("Profiles…", systemImage: "person.3")
                }

                Divider()

                Button {
                    // V3A final pass: capture the board/server stamp
                    // SYNCHRONOUSLY at the tap; a nudge staged for A can
                    // never fire against B.
                    nudgeTapped()
                } label: {
                    Label("Nudge Dispatcher", systemImage: "arrow.forward.circle")
                }
                .disabled(store.isMutating || !store.isSelectedSnapshotLoaded)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 36, height: 36)
            }
            .conduitGlassControl(cornerRadius: 14)
            .accessibilityLabel("Kanban board actions")
            .disabled(bulkBusy || isSelectionActive)

            if !isSelectionActive {
                // V3C: multi-select entry - a primary board action, reachable
                // in one tap (never hidden inside two drop-down menus).
                Button {
                    enterSelectionMode()
                } label: {
                    Image(systemName: "checkmark.circle")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .conduitGlassControl(cornerRadius: 14)
                .accessibilityLabel("Select tasks")
                .accessibilityHint("Enter selection mode to run bulk operations")
                .disabled(store.isMutating || !store.isSelectedSnapshotLoaded || loadedBoardMetadata == nil || bulkBusy)
            } else {
                // Selection mode header: Cancel | N Selected (+ busy).
                HStack(spacing: 10) {
                    Button {
                        if !bulkBusy { exitSelectionMode() }
                    } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(bulkBusy)
                    .accessibilityLabel("Exit selection mode")
                    Text(selectedCountLabel)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityLabel(selectedCountLabel)
                    if bulkBusy {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .conduitGlassControl(cornerRadius: 14)
            }

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
            .disabled(store.board == nil || store.isMutating || !store.isSelectedSnapshotLoaded || isSelectionActive)
            .accessibilityLabel("New Kanban task")
        }

        if !isSelectionActive {
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
                // V3B: assignee/tenant/Show Archived/grouping live behind ONE
                // compact filter button instead of crowding the header.
                Button {
                    showFilters = true
                } label: {
                    Image(systemName: filtersActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(filtersActive ? Color.conduitAccent : Color.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filtersActive ? "Filters active — open filters" : "Open filters")
                .accessibilityHint("Shows assignee, tenant, archived, and running grouping options")
                .disabled(!store.isSelectedSnapshotLoaded)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .conduitGlassControl(cornerRadius: 15)
        }
    }

    /// Active-filter indication for the filter button (sheet-driven filters:
    /// archived toggle, grouping preference, assignee, tenant).
    private var filtersActive: Bool {
        includeArchived
            || groupRunningByProfile
            || !(assigneeFilter ?? "").isEmpty
            || !(tenantFilter ?? "").isEmpty
    }

    /// Group header for the grouped Running lane (accessibility-labeled).
    private func runningGroupHeader(_ group: KanbanRunningGroupPolicy.Group) -> some View {
        HStack(spacing: 6) {
            Text(group.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(String(group.tasks.count))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.displayName), \(group.tasks.count) tasks")
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


    /// A card's Delete… entry STAGES the shared board-level confirmation; it
    /// never issues the destructive mutation directly. The task is captured
    /// BY VALUE together with the loaded board/server context stamp, so the
    /// confirmation can later prove it still owns the store's current
    /// context before deleting.
    private func stageCardDelete(_ task: KanbanTask) {
        // Stage-time gate mirrors the confirm-time gate: only an actionable
        // loaded context may stage a destructive confirmation at all.
        guard let stamp = store.loadedContextStamp, store.isSelectedSnapshotLoaded else { return }
        if case .confirm(let staged) = KanbanCardDeletePolicy.cardRequestedDelete(for: task, stamp: stamp) {
            pendingDelete = staged
        }
    }

    /// Only an explicit confirmation that still owns the staging context
    /// resolves to a permanent DELETE. FAIL-CLOSED: if the board or server
    /// context has changed (different slug, new configuration generation, or
    /// an in-flight board navigation), the stale confirmation is discarded
    /// without any request — even if the new board happens to contain a task
    /// with the same id. The check below is EARLY UX REJECTION only: the
    /// spawned delete passes the staged stamp to the store's context-bound
    /// deleteTask, which re-validates ownership and captures its mutation
    /// context ATOMICALLY — the hard boundary that closes the check-to-
    /// Task-scheduling TOCTOU window.
    private func confirmCardDelete(_ staged: PendingCardDelete) {
        pendingDelete = nil
        guard case .perform(let task) = KanbanCardDeletePolicy.confirmed(
            staged: staged,
            currentStamp: store.loadedContextStamp,
            isSnapshotActionable: store.isSelectedSnapshotLoaded
        ) else { return }
        Task {
            try? await store.deleteTask(
                id: task.id,
                expectedContext: staged.stamp,
                includeArchived: includeArchived
            )
        }
    }
}

private struct KanbanCardView: View {
    let task: KanbanTask
    /// Whether Hermes has ANY configured default assignee fallback. When not,
    /// an unassigned ready card would silently never run — worth surfacing.
    var hasDispatcherFallback: Bool = true
    /// V3C: while multi-select is active or a bulk op is running, the card's
    /// own Move/Archive/Delete controls are HIDDEN (ellipsis menu) or
    /// disabled (context menu) instead of looking enabled-but-inert.
    var isMenusDisabled: Bool = false
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
                if !isMenusDisabled {
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
                } // if !isMenusDisabled
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
                .disabled(isMenusDisabled)
            }
            Button { copy(text: task.id, notice: "Task ID copied") } label: {
                Label("Copy Task ID", systemImage: "doc.on.doc")
            }
            Button { copy(text: task.title, notice: "Title copied") } label: {
                Label("Copy Task Title", systemImage: "doc.on.doc.fill")
            }
            Divider()
            Button(action: onArchive) { Label("Archive", systemImage: "archivebox") }
                .disabled(isMenusDisabled)
            Button(role: .destructive, action: onDelete) { Label("Delete…", systemImage: "trash") }
                .disabled(isMenusDisabled)
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
