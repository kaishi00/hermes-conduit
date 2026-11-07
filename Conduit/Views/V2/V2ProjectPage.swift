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
    @Environment(\.scenePhase) private var scenePhase
    let project: ProjectSummary
    @State private var detail: ProjectSessionDetail?
    /// The 20 s reads stopped while the page was out of sight.
    @State private var missedReads = false
    @State private var isLoading = true
    /// Pull-to-refresh and the page's own load can overlap; only the
    /// newest one writes back.
    @State private var reloadGeneration = 0
    @State private var collapsedLanes: Set<String> = []
    /// The profile the page opened in: its project is the page's, and a
    /// tap on another profile's chat switches away from it.
    @State private var owner: String?
    /// The same folder's project in the other profiles, and their chats
    /// (issue 1761).
    @State private var otherProfiles: ProjectOtherProfilesRead?
    @State private var otherProfilesReadAt: Date?
    /// The profile picked above the lanes; nil shows every profile.
    @State private var profileFilter: String?
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
    /// On screen: its tab shows, nothing is pushed over it (beside it, on
    /// a wide window, is still on screen) and the app isn't in the background.
    private var pageShows: Bool {
        shell.isTabActive && shell.showsChatRows && scenePhase != .background
    }

    private var startsPlainChat: Bool { newConversationPath == nil && project.isHome }

    private var canStartConversation: Bool { newConversationPath != nil || startsPlainChat }

    private var pageProfile: String { owner ?? appState.activeProfile }

    /// The profiles New conversation can start in: the page's, then each
    /// other profile with this project, in All's order.
    private var newConversationProfiles: [String] {
        guard let read = otherProfiles else { return [pageProfile] }
        let others = appState.projectPageProfiles(besides: pageProfile).filter { profile in
            (read.matches[profile] ?? nil) != nil
                // A profile whose read failed keeps its rows, and its project.
                || read.parts.contains { AppState.profilesMatch($0.profile, profile) }
        }
        return [pageProfile] + others
    }

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
    /// and the page beside the open chat would miss it (issue 1454). Only
    /// while the page's profile is in use: a chat started after a switch
    /// is another profile's, and shows in its part (profileParts).
    private var ownLanes: [ProjectSessionLane] {
        let lanes = detail?.lanes ?? []
        guard AppState.profilesMatch(pageProfile, appState.activeProfile),
              let created = appState.newChatAwaitingListing(in: project) else { return lanes }
        return created.awaiting.lanes(lanes, with: created.row, newLaneID: "\(project.id)-new")
    }

    /// The page's profile, then every other profile's chats in this folder.
    /// A chat just started in another profile (after a switch to it) shows
    /// in that profile's part until its read lists it.
    private var profileParts: [ProjectProfileLanes] {
        var parts = [ProjectProfileLanes(profile: pageProfile, lanes: ownLanes)] + (otherProfiles?.parts ?? [])
        let active = appState.activeProfile
        guard !AppState.profilesMatch(pageProfile, active),
              let created = appState.newChatAwaitingListing(in: project) else { return parts }
        var row = created.row
        if row.profile == nil { row.profile = active }
        let newLaneID = "\(project.id)-\(active)-new"
        if let index = parts.firstIndex(where: { AppState.profilesMatch($0.profile, active) }) {
            parts[index].lanes = created.awaiting.lanes(parts[index].lanes, with: row, newLaneID: newLaneID)
        } else if appState.projectPageProfiles(besides: pageProfile).contains(where: { AppState.profilesMatch($0, active) }) {
            parts.append(ProjectProfileLanes(profile: active, lanes: created.awaiting.lanes([], with: row, newLaneID: newLaneID)))
        }
        return parts
    }

    /// The profiles with chats here, when there are two or more.
    private var mixedProfiles: [String] {
        let profiles = ProjectAcrossProfiles.profilesWithChats(profileParts)
        return profiles.count > 1 ? profiles : []
    }

    /// The picked profile, while it still has chats here.
    private var shownFilter: String? {
        guard let profileFilter, mixedProfiles.contains(profileFilter) else { return nil }
        return profileFilter
    }

    /// Whose chats the header names: the picked profile, or the one profile
    /// with chats here; none while the page mixes them (the row above the
    /// lanes says who, and each row carries its picture).
    private var headerProfile: String? {
        if let shownFilter { return shownFilter }
        guard mixedProfiles.isEmpty else { return nil }
        return ProjectAcrossProfiles.profilesWithChats(profileParts).first ?? pageProfile
    }

    private var lanes: [ProjectSessionLane] {
        ProjectAcrossProfiles.lanes(profileParts, filter: shownFilter)
    }

    var body: some View {
        ZStack {
            V2Backdrop(drifts: false)
            List {
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))

                if !mixedProfiles.isEmpty {
                    profileFilterRow
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                }

                if isLoading && detail == nil && lanes.isEmpty {
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
                            emptyNewConversationButton
                                .buttonStyle(.borderedProminent)
                                .disabled(newConversationDisabled)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if detail != nil || !lanes.isEmpty {
                    // Another profile's chats show though this one's read failed.
                    ForEach(lanes) { lane in
                        laneRows(lane)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Conversations unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Couldn't load this project's conversations.")
                    } actions: {
                        Button("Try Again") { Task { await reload(force: true) } }
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
            .refreshable { await reload(force: true) }
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
                    newConversationButton
                        .disabled(newConversationDisabled)
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
        // Another profile's changes move nothing here: read them every 20 s
        // while the page shows, as All's poll does. Its tab hidden, a chat
        // over it or the app in the background stops the reads (#1827);
        // showing it again reads at once.
        .task(id: "\(project.id)|\(pageShows)") {
            guard pageShows else {
                missedReads = true
                return
            }
            if missedReads {
                missedReads = false
                await reload()
            }
            while true {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                await reload()
            }
        }
        .onChange(of: appState.isConnected) { _, isConnected in
            guard isConnected else { return }
            Task { await reload(force: true) }
        }
        .alert("Delete conversation?", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let session = sessionPendingDeletion else { return }
                sessionPendingDeletion = nil
                Task {
                    if await appState.deleteSession(session) { await reload(force: true) }
                }
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: {
            Text("This permanently deletes the conversation and cannot be undone.")
        }
        .sheet(item: $sessionPendingRename) { session in
            RenameSheet.conversation(session) { title in
                Task {
                    if await appState.renameSession(session, to: title) { await reload(force: true) }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        let runningCount = allSessions.filter { appState.sessionLiveStatus($0) == .working }.count
        let count = detail != nil || !allSessions.isEmpty ? allSessions.count : project.sessionCount
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
                    // Whose chats these are: the page lists one profile's
                    // (issue 1761).
                    if ProjectProfileLabel.shows(in: appState), let headerProfile {
                        ProjectProfileLabel(profile: headerProfile)
                        Text(verbatim: "·")
                    }
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
            // Two profiles' chats can share an id: each row is its profile's.
            ForEach(Array(lane.sessions.enumerated()), id: \.element.projectPageRowID) { index, session in
                sessionRow(session)
                    .v2ListRow(divider: index == lane.sessions.count - 1, dividerInset: 16)
                    .sessionActions(
                        appState: appState,
                        session: session,
                        nest: nil,
                        excludingProjectID: project.id,
                        onRename: { sessionPendingRename = session },
                        onDelete: { sessionPendingDeletion = session },
                        onChanged: { Task { await reload(force: true) } }
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
            if appState.isOtherProfileRow(session) {
                // The switch to its profile, then the chat, as All opens it.
                appState.openListedSession(session)
            } else {
                appState.requestOpenSession(session.id)
            }
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
                    leadingGlyph: true,
                    profileBadge: profileBadge(for: session)
                )
            }
        }
        .buttonStyle(.plain)
        // Its saved copy comes into memory as it shows (issue 1725).
        .onAppear { appState.warmSavedCopy(of: session) }
        .accessibilityHint(AppLocalization.string("Swipe or touch and hold for conversation actions."))
        .v2SelectedTrait(.chat(isActive: appState.isOpenChatRow(session), beside: openBeside))
    }

    /// Each row's profile picture while the page shows two or more
    /// profiles' chats together.
    private func profileBadge(for session: SessionSummary) -> V2ProfileBadge? {
        guard !mixedProfiles.isEmpty, shownFilter == nil else { return nil }
        let profile = appState.rowProfile(session)
        return V2ProfileBadge(
            profile: profile,
            name: appState.profileDisplayName(profile),
            url: appState.profileAvatarURL(for: profile)
        )
    }

    // MARK: - Profiles

    /// All, then each profile with chats here: a pick shows only its chats.
    private var profileFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(profile: nil)
                ForEach(mixedProfiles, id: \.self) { profile in
                    filterChip(profile: profile)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .dynamicTypeSize(...DynamicTypeSize.listRowCap)
    }

    private func filterChip(profile: String?) -> some View {
        let isSelected = shownFilter == profile
        let name = profile.map { appState.profileDisplayName($0) }
        return Button {
            Haptics.selection()
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { profileFilter = profile }
        } label: {
            HStack(spacing: 6) {
                if let profile, let name {
                    ProfileAvatarView(
                        profile: profile,
                        displayName: name,
                        url: appState.profileAvatarURL(for: profile),
                        size: 22
                    )
                    .accessibilityHidden(true)
                    Text(verbatim: name)
                } else {
                    Text("All")
                }
            }
            .scaledFont(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .lineLimit(1)
            .padding(.leading, profile == nil ? 12 : 4)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(minHeight: 32)
            .background {
                if isSelected {
                    Color.clear.conduitGlassControl(cornerRadius: 16, interactive: false)
                } else {
                    Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.map { AppLocalization.string("\($0) profile") } ?? AppLocalization.string("All"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The empty page's New conversation: asks which profile as the
    /// toolbar's does.
    @ViewBuilder
    private var emptyNewConversationButton: some View {
        let choices = newConversationProfiles
        if shownFilter == nil, choices.count > 1 {
            Menu("New conversation") {
                ForEach(choices, id: \.self) { profile in
                    Button {
                        startNewConversation(in: profile)
                    } label: {
                        Text(verbatim: appState.profileDisplayName(profile))
                    }
                }
            }
        } else {
            Button("New conversation") { startNewConversation() }
        }
    }

    /// New conversation: in the picked profile, else a menu of the
    /// profiles with this project when there are two or more.
    @ViewBuilder
    private var newConversationButton: some View {
        let choices = newConversationProfiles
        if shownFilter == nil, choices.count > 1 {
            Menu {
                ForEach(choices, id: \.self) { profile in
                    Button {
                        startNewConversation(in: profile)
                    } label: {
                        Text(verbatim: appState.profileDisplayName(profile))
                    }
                }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel(newConversationLabel)
        } else {
            Button { startNewConversation() } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel(newConversationLabel)
        }
    }

    // MARK: - Actions

    /// A page opened from the saved Chats list before Hermes answered says
    /// it's loading until Hermes is connected, then loads. The other
    /// profiles are read again at most every 20 s, as All's poll does,
    /// unless asked (a pull, Try Again, a reconnect).
    private func reload(force: Bool = false) async {
        guard appState.isConnected else { return }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        // A forced read a newer one supersedes is still owed: the next
        // read takes the other profiles too.
        if force { otherProfilesReadAt = nil }
        isLoading = true
        let pageProfile = owner ?? appState.activeProfile
        owner = pageProfile
        let loaded = await appState.loadProjectSessions(project, inProfile: pageProfile)
        guard !Task.isCancelled, generation == reloadGeneration else { return }
        if let loaded { detail = loaded }
        isLoading = false

        let others = appState.projectPageProfiles(besides: pageProfile)
        guard !others.isEmpty else {
            otherProfiles = nil
            return
        }
        if !force, let readAt = otherProfilesReadAt, Date().timeIntervalSince(readAt) < 20 { return }
        let read = await appState.loadProject(project, inProfiles: others, known: otherProfiles?.matches ?? [:])
        guard !Task.isCancelled, generation == reloadGeneration, var read else { return }
        // A profile whose read failed keeps what the page showed of it.
        for part in otherProfiles?.parts ?? [] where read.failed.contains(part.profile)
            && !read.parts.contains(where: { $0.profile == part.profile }) {
            read.parts.append(part)
        }
        otherProfiles = read
        otherProfilesReadAt = Date()
    }

    /// Starts a session in the project's folder; the conversation pushes
    /// over this page, so Back returns here.
    private func startNewConversation() {
        startNewConversation(in: shownFilter ?? pageProfile)
    }

    private func startNewConversation(in profile: String) {
        if startsPlainChat {
            Haptics.medium()
            appState.startNewChat(inProfile: profile)
            return
        }
        guard let path = newConversationPath else { return }
        Haptics.medium()
        appState.dismissSidebarDrawer()
        appState.createNewSession(cwd: path, inProfile: profile)
    }
}

private extension SessionSummary {
    /// A project page's row: its profile and id, as two profiles' chats can
    /// share an id.
    var projectPageRowID: String { "\(profile ?? "")\u{1F}\(id)" }
}

/// Whose chats a project page shows while they are one profile's (the only
/// one with chats here, or the one picked above the lanes): its picture and
/// name beside the count (issue 1761). Shown with two or more profiles, as
/// the All chip is.
struct ProjectProfileLabel: View {
    @EnvironmentObject private var appState: AppState
    @ScaledMetric(relativeTo: .subheadline) private var avatarSize: CGFloat = 18
    /// Nil names the profile in use.
    let profile: String?

    init(profile: String? = nil) {
        self.profile = profile
    }

    static func shows(in appState: AppState) -> Bool {
        AllProfilesChats.isAvailable(profiles: appState.profiles)
    }

    var body: some View {
        let profile = self.profile ?? appState.activeProfile
        let name = appState.profileDisplayName(profile)
        HStack(spacing: 5) {
            ProfileAvatarView(
                profile: profile,
                displayName: name,
                url: appState.profileAvatarURL(for: profile),
                size: avatarSize
            )
            .accessibilityHidden(true)
            Text(verbatim: name)
                .lineLimit(1)
        }
    }
}
