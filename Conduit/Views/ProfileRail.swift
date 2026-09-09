import SwiftUI

/// Chats home character shelf: pinned profiles wrap in a grid; unpinned stack below.
struct ProfileShelf: View {
    @EnvironmentObject private var appState: AppState
    var pinnedSize: CGFloat = ConduitInboxMetrics.profileRailSizePhone
    var unpinnedSize: CGFloat = ConduitInboxMetrics.profileShelfUnpinnedSize
    var onSelectProfile: (String) -> Void

    private var visibleProfiles: [String] {
        appState.profiles.isEmpty ? [appState.activeProfile] : appState.profiles
    }

    private var pinnedProfiles: [String] {
        let known = Set(visibleProfiles)
        return appState.pinnedProfileIDs.filter { known.contains($0) }
    }

    private var unpinnedProfiles: [String] {
        let pinned = Set(pinnedProfiles)
        return visibleProfiles.filter { !pinned.contains($0) }
    }

    private var pinnedColumns: [GridItem] {
        [GridItem(.adaptive(minimum: pinnedSize + 12, maximum: pinnedSize + 28), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !pinnedProfiles.isEmpty {
                    LazyVGrid(columns: pinnedColumns, alignment: .leading, spacing: 16) {
                        ForEach(pinnedProfiles, id: \.self) { profile in
                            pinnedCell(profile)
                        }
                    }
                }

                if !unpinnedProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if !pinnedProfiles.isEmpty {
                            Text("More")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.conduitSecondaryText)
                                .padding(.bottom, 4)
                        }
                        ForEach(unpinnedProfiles, id: \.self) { profile in
                            unpinnedRow(profile)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func pinnedCell(_ profile: String) -> some View {
        let selected = profile == appState.activeProfile
        let switching = appState.isProfileSwitching
        return Button {
            guard !switching else { return }
            onSelectProfile(profile)
        } label: {
            VStack(spacing: 8) {
                AgentAvatar(
                    profileID: profile,
                    displayName: appState.profileDisplayName(profile),
                    photoURL: appState.profileAvatarURL(for: profile),
                    size: pinnedSize,
                    showsSelectionRing: selected,
                    state: appState.avatarState(for: profile)
                )
                .opacity(switching && !selected ? 0.55 : 1)

                Text(appState.profileDisplayName(profile))
                    .font(.caption.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.conduitPrimaryText : Color.conduitSecondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: pinnedSize + 8)
            }
        }
        .buttonStyle(.plain)
        .disabled(switching && !selected)
        .contextMenu { pinMenu(for: profile) }
        .accessibilityLabel(appState.profileDisplayName(profile))
        .accessibilityValue(appState.avatarState(for: profile).label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Opens conversations for this profile")
    }

    private func unpinnedRow(_ profile: String) -> some View {
        let selected = profile == appState.activeProfile
        let switching = appState.isProfileSwitching
        return Button {
            guard !switching else { return }
            onSelectProfile(profile)
        } label: {
            HStack(spacing: 14) {
                AgentAvatar(
                    profileID: profile,
                    displayName: appState.profileDisplayName(profile),
                    photoURL: appState.profileAvatarURL(for: profile),
                    size: unpinnedSize,
                    showsSelectionRing: selected,
                    state: appState.avatarState(for: profile)
                )
                .opacity(switching && !selected ? 0.55 : 1)

                Text(appState.profileDisplayName(profile))
                    .font(.body.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.conduitPrimaryText : Color.conduitSecondaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.conduitSecondaryText)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(switching && !selected)
        .contextMenu { pinMenu(for: profile) }
        .accessibilityLabel(appState.profileDisplayName(profile))
        .accessibilityValue(appState.avatarState(for: profile).label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Opens conversations for this profile")
    }

    @ViewBuilder
    private func pinMenu(for profile: String) -> some View {
        Button {
            Haptics.light()
            withAnimation(ConduitMotion.response) {
                appState.toggleProfilePinned(profile)
            }
        } label: {
            Label(
                appState.isProfilePinned(profile) ? "Unpin" : "Pin",
                systemImage: appState.isProfilePinned(profile) ? "pin.slash" : "pin"
            )
        }
    }
}

/// Legacy horizontal rail kept for any non-inbox callers; Chats uses `ProfileShelf`.
struct ProfileRail: View {
    @EnvironmentObject private var appState: AppState
    var size: CGFloat = ConduitInboxMetrics.profileRailSizePhone
    var onSelectProfile: (String) -> Void

    var body: some View {
        ProfileShelf(
            pinnedSize: size,
            unpinnedSize: min(size, ConduitInboxMetrics.profileShelfUnpinnedSize),
            onSelectProfile: onSelectProfile
        )
    }
}

/// Bottom sheet: New chat + sessions for the active profile (after switch-then-present).
struct ProfileSessionsSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var shell: AppShellState
    @Environment(\.dismiss) private var dismiss

    var initiallySearching: Bool = false
    var onOpenConversation: (String) -> Void
    var onCreateConversation: () -> Void

    @State private var isSearchActive = false
    @State private var searchText = ""
    @State private var sessionPendingDeletion: SessionSummary?
    @State private var sessionPendingRename: SessionSummary?
    @State private var sessionRenameTitle = ""
    @AppStorage("conduit.sessionSourceFilter") private var selectedSourceRaw: String = "all"

    private var selectedSource: SessionSource? {
        selectedSourceRaw == "all" ? nil : SessionSource(rawValue: selectedSourceRaw)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                if isSearchActive {
                    searchBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                if let selectedSource {
                    HStack {
                        Text("Filtered: \(selectedSource.label)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.conduitPrimaryText)
                        Spacer()
                        Button {
                            selectedSourceRaw = "all"
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                        }
                        .accessibilityLabel("Clear source filter")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.conduitRaisedSurface, in: Capsule())
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }

                sessionList
            }
            .background(Color.conduitCanvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        clearSearch()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.selection()
                        withAnimation(ConduitMotion.response) {
                            isSearchActive.toggle()
                            if !isSearchActive {
                                searchText = ""
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel(isSearchActive ? "Hide search" : "Search conversations")
                }
            }
        }
        .onAppear {
            if initiallySearching {
                isSearchActive = true
            }
        }
        .alert("Delete conversation?", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let session = sessionPendingDeletion else { return }
                sessionPendingDeletion = nil
                Task { await appState.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: {
            Text("This permanently deletes the conversation and cannot be undone.")
        }
        .alert("Rename conversation", isPresented: Binding(
            get: { sessionPendingRename != nil },
            set: { if !$0 { sessionPendingRename = nil } }
        )) {
            TextField("Conversation title", text: $sessionRenameTitle)
            Button("Rename") {
                guard let session = sessionPendingRename,
                      let title = SessionRenameOperation.normalizedTitle(
                          sessionRenameTitle,
                          currentTitle: session.title
                      ) else { return }
                sessionPendingRename = nil
                Task { await appState.renameSession(session, to: title) }
            }
            .disabled(SessionRenameOperation.normalizedTitle(
                sessionRenameTitle,
                currentTitle: sessionPendingRename?.title ?? ""
            ) == nil)
            Button("Cancel", role: .cancel) { sessionPendingRename = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AgentAvatar(
                profileID: appState.activeProfile,
                displayName: appState.profileDisplayName(appState.activeProfile),
                photoURL: appState.profileAvatarURL(for: appState.activeProfile),
                size: 52,
                showsSelectionRing: true,
                state: appState.avatarState(for: appState.activeProfile)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.profileDisplayName(appState.activeProfile))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.conduitPrimaryText)
                    .lineLimit(1)
                Text("Conversations")
                    .font(.subheadline)
                    .foregroundStyle(Color.conduitSecondaryText)
            }

            Spacer(minLength: 0)

            Button {
                guard !shell.isCreatingConversation else { return }
                Haptics.medium()
                shell.isCreatingConversation = true
                clearSearch()
                // Parent dismisses the sheet and creates after onDismiss.
                onCreateConversation()
            } label: {
                Text("New chat")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .conduitPrimaryActionControl(cornerRadius: 18)
            }
            .buttonStyle(.plain)
            .disabled(appState.turnState == .synchronizing || shell.isCreatingConversation)
            .accessibilityLabel("New chat")
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.conduitSecondaryText)
            TextField("Search conversations", text: $searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.conduitSecondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            Button("Cancel") {
                clearSearch()
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .conduitRaisedSurface(cornerRadius: 14)
    }

    private var sessionList: some View {
        List {
            if displayedSessions.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "tray",
                    description: Text(emptyDescription)
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !pinnedSessions.isEmpty {
                Section {
                    ForEach(pinnedSessions) { session in
                        sessionRow(session)
                    }
                } header: {
                    Text("Pinned")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.conduitSecondaryText)
                        .textCase(nil)
                }
            }

            if !unpinnedSessions.isEmpty {
                Section {
                    ForEach(unpinnedSessions) { session in
                        sessionRow(session)
                    }
                } header: {
                    Text(pinnedSessions.isEmpty ? "Chats" : "Recent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.conduitSecondaryText)
                        .textCase(nil)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .refreshable {
            await appState.refreshSessionCatalog()
        }
    }

    private var emptyTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No Matches"
        }
        if let selectedSource {
            return "No \(selectedSource.label) Chats"
        }
        return "No Chats"
    }

    private var emptyDescription: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try a different search."
        }
        return "Start a new chat to begin."
    }

    private var allSessions: [SessionSummary] {
        let nonArchived = appState.activeProfileSessions.filter { !$0.isArchived }
        guard let selectedSource else { return nonArchived }
        return nonArchived.filter { $0.source == selectedSource }
    }

    private var displayedSessions: [SessionSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allSessions }
        return allSessions.filter { session in
            [session.title, session.model, session.id, session.source.label]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var pinnedSessions: [SessionSummary] {
        displayedSessions.filter { appState.isSessionPinned($0) }
    }

    private var unpinnedSessions: [SessionSummary] {
        displayedSessions.filter { !appState.isSessionPinned($0) }
    }

    private func clearSearch() {
        isSearchActive = false
        searchText = ""
        shell.isConversationSearchActive = false
        shell.conversationSearchText = ""
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        let selected: Bool = {
            guard let active = appState.activeSessionId else { return false }
            return appState.activeChatScrollSessionIdentity.areEquivalent(session.id, active)
                || session.id == active
        }()
        return Button {
            Haptics.light()
            clearSearch()
            // Parent dismisses the sheet and navigates after onDismiss.
            onOpenConversation(session.id)
        } label: {
            ConversationRow(
                session: session,
                secondaryLine: appState.inboxSecondaryLine(for: session),
                isPinned: appState.isSessionPinned(session),
                isSelected: selected
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Haptics.selection()
                sessionRenameTitle = session.title
                sessionPendingRename = session
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            .disabled(appState.isSessionMutationInFlight(session))

            Button {
                Haptics.light()
                appState.toggleSessionPinned(session)
            } label: {
                Label(
                    appState.isSessionPinned(session) ? "Unpin" : "Pin",
                    systemImage: appState.isSessionPinned(session) ? "pin.slash" : "pin"
                )
            }

            Button {
                Task {
                    Haptics.mutationCompleted(await appState.archiveSession(session))
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(appState.isSessionMutationInFlight(session))

            Button(role: .destructive) {
                Haptics.warning()
                sessionPendingDeletion = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(appState.isSessionMutationInFlight(session))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                Haptics.light()
                appState.toggleSessionPinned(session)
            } label: {
                Label(
                    appState.isSessionPinned(session) ? "Unpin" : "Pin",
                    systemImage: appState.isSessionPinned(session) ? "pin.slash" : "pin"
                )
            }
            .tint(.conduitAccent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task {
                    Haptics.mutationCompleted(await appState.archiveSession(session))
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.orange)
            .disabled(appState.isSessionMutationInFlight(session))

            Button(role: .destructive) {
                Haptics.warning()
                sessionPendingDeletion = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(appState.isSessionMutationInFlight(session))
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
    }
}
