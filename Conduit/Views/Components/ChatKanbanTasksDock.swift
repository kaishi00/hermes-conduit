//
//  ChatKanbanTasksDock.swift
//  Conduit
//
//  The Kanban tasks the open chat handed to the board (desktop issue 553):
//  a line above the composer, "2 Kanban tasks in progress", drawn like the
//  plan's, opening a sheet with a row per task (its lane, who has it, its
//  board and, while it's blocked, why). A row opens the task over the chat,
//  with Open in Tasks for the full board (desktop issue 593). Red while one
//  is blocked; "Kanban tasks finished" once none is open, until the chat
//  changes or × hides it.
//

import SwiftUI

struct ChatKanbanTasksDock: View {
    let appState: AppState
    /// The open chat: another starts with none.
    let openChatID: String?
    /// The chat's turn is running: its end is read again, since that turn
    /// may have put cards on the board.
    let isBusy: Bool
    /// The chat shows (the app is active, the tab and the chat on screen).
    let isShowing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tasks: [ChatKanbanTask] = []
    @State private var seenOpen: Set<String> = []
    @State private var hidden = false
    @State private var showsSheet = false

    private var anyOpen: Bool { tasks.contains(where: \.isOpen) }
    private var anyBlocked: Bool { tasks.contains(where: \.isBlocked) }
    /// Only over the chat it belongs to: not over a saved copy of another.
    private var shows: Bool { !tasks.isEmpty && !hidden && isShowing }

    var body: some View {
        Group {
            if shows {
                strip.transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, 12)
        .padding(.bottom, shows ? 6 : 0)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: tasks)
        .onChange(of: openChatID) {
            tasks = []
            seenOpen = []
            hidden = false
            showsSheet = false
        }
        // A task that opens again (or a new one) shows the line again.
        .onChange(of: anyOpen) { _, open in if open { hidden = false } }
        // Read as the chat opens (mid-turn too) and as each turn ends, then
        // every 15 s while a task is still open and the chat shows.
        .task(id: "\(openChatID ?? "")|\(isBusy)|\(isShowing)") {
            guard openChatID != nil, isShowing else { return }
            repeat {
                await read()
                guard anyOpen else { return }
                try? await Task.sleep(for: ChatKanbanTasks.refreshInterval)
            } while !Task.isCancelled
        }
        .sheet(isPresented: $showsSheet) {
            ChatKanbanTasksSheet(appState: appState, tasks: tasks, canOpenInTasks: appState.canOpenChatKanbanTask) { task in
                showsSheet = false
                appState.openChatKanbanTask(task)
            }
        }
    }

    private func read() async {
        let asked = openChatID
        guard let answer = await appState.loadOpenChatKanbanTasks(), !Task.isCancelled, openChatID == asked else { return }
        seenOpen.formUnion(answer.tasks.filter(\.isOpen).map(\.id))
        tasks = ChatKanbanTasks.shown(answer.tasks, seenOpen: seenOpen)
    }

    private var strip: some View {
        HStack(spacing: 4) {
            Button {
                Haptics.selection()
                showsSheet = true
            } label: {
                HStack(spacing: 8) {
                    if anyOpen, !anyBlocked {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    } else {
                        Image(systemName: anyBlocked ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(anyBlocked ? Color.red : Color.green)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: ChatKanbanTasks.label(tasks))
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(anyBlocked ? Color.red : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up")
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityHint(Text(AppLocalization.string("Shows the chat’s Kanban tasks", table: .chat)))
            if !anyOpen {
                Button {
                    hidden = true
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(AppLocalization.string("Dismiss")))
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .conduitGlassControl(cornerRadius: 20, tint: .clear)
    }
}

/// Each of the chat's Kanban tasks, from its line. A row opens its task over
/// the chat, on its own board, so reading it never leaves the conversation;
/// the task's Open in Tasks goes on to the full board (desktop issue 593).
private struct ChatKanbanTasksSheet: View {
    let appState: AppState
    let tasks: [ChatKanbanTask]
    /// Tasks shows this dashboard's boards: a far chat's tasks open here,
    /// on their own dashboard, but not there.
    let canOpenInTasks: Bool
    let openInTasks: (ChatKanbanTask) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var opened: ChatKanbanTaskSheet?
    @State private var loadingID: String?
    @State private var failure: String?
    /// Only the last tap's task opens: an earlier, slower read drops.
    @State private var request = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tasks) { task in
                        Button { open(task) } label: { row(task) }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text(AppLocalization.string("Opens the task on the board", table: .pulse)))
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let failure {
                            Text(verbatim: failure).foregroundStyle(.red)
                        }
                        Text(AppLocalization.string("Cards this chat put on the Kanban board. Hermes’ workers run them in the background.", table: .chat))
                    }
                }
            }
            .navigationTitle(Text(verbatim: ChatKanbanTasks.label(tasks)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $opened) { sheet in
            KanbanTaskDetailView(task: sheet.task, openInTasks: canOpenInTasks ? { openInTasks(sheet.chatTask) } : nil)
                .environment(sheet.store)
                .environmentObject(appState)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    /// The task, read on its own board, then opened over the chat.
    private func open(_ task: ChatKanbanTask) {
        request += 1
        let asked = request
        failure = nil
        guard let store = appState.chatKanbanTaskStore() else {
            loadingID = nil
            failure = AppLocalization.string("Kanban is not connected.", table: .tasks)
            return
        }
        loadingID = task.id
        Task {
            defer { if request == asked { loadingID = nil } }
            do {
                let found = try await appState.loadChatKanbanTask(task, in: store)
                guard request == asked else { return }
                opened = ChatKanbanTaskSheet(chatTask: task, store: store, task: found)
            } catch is CancellationError {
                return
            } catch {
                guard request == asked else { return }
                failure = UserFacingError.message(for: error)
            }
        }
    }

    private func row(_ task: ChatKanbanTask) -> some View {
        let status = KanbanStatusPresentation.forStatus(task.status)
        let boards = Set(tasks.map(\.board))
        let detail = [task.assignee, boards.count > 1 || task.board != "default" ? task.boardName : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: status.systemImage)
                    .foregroundStyle(status.tint)
                    .accessibilityHidden(true)
                Text(verbatim: task.title)
                    .scaledFont(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 6)
                if loadingID == task.id {
                    ProgressView().controlSize(.small)
                } else {
                    Text(verbatim: status.displayName)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .scaledFont(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = task.error {
                Text(verbatim: error)
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// One of the chat's Kanban tasks, open over the chat on its own board.
private struct ChatKanbanTaskSheet: Identifiable {
    let id = UUID()
    let chatTask: ChatKanbanTask
    let store: KanbanStore
    let task: KanbanTask
}
