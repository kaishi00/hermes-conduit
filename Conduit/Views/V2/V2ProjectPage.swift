//
//  V2ProjectPage.swift
//  Conduit
//
//  A project's page, pushed from Chats › Projects with the tab bar still up.
//  Its sessions are drawn as a tree: each lane (a folder Hermes groups the
//  project's sessions by) as a collapsible folder row, its sessions under it
//  on a thread line. New chat here starts in the project's folder.
//

import SwiftUI

struct V2ProjectPage: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(V2MainButtonPreference.key) private var mainButtonNewChat = V2MainButtonPreference.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.v2Shell) private var shell
    @Environment(\.v2OpenBeside) private var openBeside
    let project: ProjectSummary
    @State private var detail: ProjectSessionDetail?
    @State private var isLoading = true
    /// Pull-to-refresh and the page's own load can overlap; only the
    /// newest one writes back.
    @State private var reloadGeneration = 0
    @State private var collapsedLanes: Set<String> = []
    @State private var sessionPendingDeletion: SessionSummary?
    @State private var sessionPendingRename: SessionSummary?

    private var newConversationPath: String? {
        guard let path = project.primaryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }

    /// Home (chats in no project) has no folder: its new chat is a plain
    /// one, which lands in Home. Other folderless projects offer none,
    /// since the chat wouldn't show up in them.
    private var startsPlainChat: Bool { newConversationPath == nil && project.isHome }

    private var canStartConversation: Bool { newConversationPath != nil || startsPlainChat }

    private var newConversationDisabled: Bool {
        if startsPlainChat { return !appState.canTapNewChat }
        return appState.turnState == .synchronizing || appState.offlineChatPresentation != nil
    }

    private var newConversationLabel: String {
        startsPlainChat ? AppLocalization.string("New Chat") : AppLocalization.string("New conversation in \(project.title)")
    }

    private var allSessions: [SessionSummary] {
        lanes.flatMap(\.sessions)
    }

    /// Hermes' lanes, with the chat just started here on top of its folder's
    /// until Hermes lists it: Hermes stores a chat with its first message,
    /// and the page beside the open chat would miss it (issue 1454).
    private var lanes: [ProjectSessionLane] {
        let lanes = detail?.lanes ?? []
        guard let created = appState.newChatAwaitingListing(in: project) else { return lanes }
        return created.awaiting.lanes(lanes, with: created.row, newLaneID: "\(project.id)-new")
    }

    var body: some View {
        ZStack {
            V2Backdrop(drifts: false)
            List {
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))

                if isLoading && detail == nil {
                    ProgressView("Loading conversations…")
                        .frame(maxWidth: .infinity, minHeight: 140)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if detail != nil, lanes.allSatisfy({ $0.sessions.isEmpty }) {
                    ContentUnavailableView {
                        Label("No Conversations", systemImage: "tray")
                    } description: {
                        Text("This project does not have any conversations yet.")
                    } actions: {
                        if canStartConversation {
                            Button("New conversation", action: startNewConversation)
                                .buttonStyle(.borderedProminent)
                                .disabled(newConversationDisabled)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if detail != nil {
                    ForEach(lanes) { lane in
                        laneRows(lane)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Conversations unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Couldn't load this project's conversations.")
                    } actions: {
                        Button("Try Again") { Task { await reload() } }
                            .buttonStyle(.borderedProminent)
                            // Offline it couldn't run; reconnecting reloads.
                            .disabled(!appState.isConnected)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .modifier(V2SoftTopScrollEdge(isOn: true))
            .refreshable { await reload() }
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mainButtonNewChat {
                // The gold button beside the tabs makes this project's new
                // chats instead (Settings > Appearance): voice sits here,
                // unless a chat beside the list shows its own.
                if !shell.hasChatVoiceBeside {
                    ToolbarItem(placement: .topBarTrailing) {
                        V2VoiceButton(context: .project(project), style: .toolbar)
                    }
                }
            } else if canStartConversation {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: startNewConversation) {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(newConversationDisabled)
                    .accessibilityLabel(newConversationLabel)
                    .macTooltip(newConversationLabel)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MinimisedLiveVoiceBar()
        }
        // Read again when the chats list's catalog changes: beside the open
        // chat on a wide window the page stays on screen (issue 1454).
        .task(id: "\(project.id)|\(appState.chatListCatalogGeneration)") { await reload() }
        .onChange(of: appState.isConnected) { _, isConnected in
            guard isConnected, detail == nil else { return }
            Task { await reload() }
        }
        .alert("Delete conversation?", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let session = sessionPendingDeletion else { return }
                sessionPendingDeletion = nil
                Task {
                    if await appState.deleteSession(session) { await reload() }
                }
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: {
            Text("This permanently deletes the conversation and cannot be undone.")
        }
        .sheet(item: $sessionPendingRename) { session in
            RenameSheet.conversation(session) { title in
                Task {
                    if await appState.renameSession(session, to: title) { await reload() }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        let runningCount = allSessions.filter { appState.sessionLiveStatus($0) == .working }.count
        let count = detail.map { _ in allSessions.count } ?? project.sessionCount
        return HStack(alignment: .center, spacing: 16) {
            V2ProjectTile(project: project, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.title)
                    .scaledFont(.title.weight(.bold))
                    .lineLimit(2)
                if let path = newConversationPath {
                    Text(path)
                        .scaledFont(.footnote.monospaced())
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: 4) {
                    Text("\(count) conversations")
                    if runningCount > 0 {
                        Text(verbatim: "·")
                        Text("\(runningCount) running")
                    }
                }
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Lanes

    @ViewBuilder
    private func laneRows(_ lane: ProjectSessionLane) -> some View {
        let isCollapsed = collapsedLanes.contains(lane.id)
        Button {
            Haptics.light()
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
                if isCollapsed { collapsedLanes.remove(lane.id) } else { collapsedLanes.insert(lane.id) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .scaledFont(.caption2.weight(.bold))
                    .conduitFixedGlyph()
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12)
                Image(systemName: "folder")
                    .scaledFont(.subheadline)
                    .foregroundStyle(V2ProjectTile.color(for: project))
                Text(lane.title)
                    .scaledFont(.callout.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let path = lanePath(lane) {
                    Text(path)
                        .scaledFont(.caption.monospaced())
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 6)
                Text(String(lane.sessions.count))
                    .scaledFont(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.listRowCap)
        .accessibilityLabel(Text([lane.title, lanePath(lane)].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityValue(Text(AppLocalization.string(isCollapsed ? "Collapsed" : "Expanded")))
        .accessibilityHint(Text(AppLocalization.string("\(lane.sessions.count) sessions")))
        .accessibilityAddTraits(.isHeader)
        .v2ListRow(divider: isCollapsed, dividerInset: 16)

        if !isCollapsed {
            ForEach(Array(lane.sessions.enumerated()), id: \.element.id) { index, session in
                sessionRow(session)
                    .v2ListRow(divider: index == lane.sessions.count - 1, dividerInset: 16)
                    .sessionActions(
                        appState: appState,
                        session: session,
                        nest: nil,
                        excludingProjectID: project.id,
                        onRename: { sessionPendingRename = session },
                        onDelete: { sessionPendingDeletion = session },
                        onChanged: { Task { await reload() } }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// The lane's folder, relative to the project's when it sits inside it
    /// (".worktrees/voice-v2"), else as Hermes reports it.
    private func lanePath(_ lane: ProjectSessionLane) -> String? {
        guard let raw = lane.path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let root = newConversationPath {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if raw.hasPrefix(prefix) { return String(raw.dropFirst(prefix.count)) }
        }
        return raw
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            appState.requestOpenSession(session.id)
        } label: {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 1.5)
                    .padding(.leading, 21)
                    .padding(.trailing, 4)
                V2SessionRow(
                    title: session.title,
                    time: session.updatedLabel,
                    preview: appState.v2RowPreview(for: session),
                    status: appState.v2RowStatus(for: session),
                    isUnread: appState.isSessionUnread(session),
                    isPinned: appState.isSessionPinned(session),
                    isStarred: appState.isSessionStarred(session),
                    selection: .chat(isActive: appState.isOpenChatRow(session), beside: openBeside),
                    leadingGlyph: true
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(AppLocalization.string("Swipe or touch and hold for conversation actions."))
        .v2SelectedTrait(.chat(isActive: appState.isOpenChatRow(session), beside: openBeside))
    }

    // MARK: - Actions

    /// A page opened from the saved Chats list before Hermes answered says
    /// it's loading until Hermes is connected, then loads.
    private func reload() async {
        guard appState.isConnected else { return }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        let loaded = await appState.loadProjectSessions(project)
        guard !Task.isCancelled, generation == reloadGeneration else { return }
        if let loaded { detail = loaded }
        isLoading = false
    }

    /// Starts a session in the project's folder; the conversation pushes
    /// over this page, so Back returns here.
    private func startNewConversation() {
        if startsPlainChat {
            Haptics.medium()
            appState.startNewChat()
            return
        }
        guard let path = newConversationPath else { return }
        Haptics.medium()
        appState.dismissSidebarDrawer()
        Task { await appState.createNewSession(cwd: path) }
    }
}
