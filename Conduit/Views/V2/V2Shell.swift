//
//  V2Shell.swift
//  Conduit
//
//  Conduit V2's navigation shell: four tabs (Chats, Tasks, Bots, Settings)
//  in place of the sessions drawer. It is new presentation over the same
//  AppState: the open conversation is still AppState's one active session,
//  and `showSidebar` keeps meaning "the chat is covered", which here is
//  "no conversation is pushed on the visible tab". Everything that already
//  uncovers the chat (a notification, a widget, a row tap) therefore pushes
//  the conversation, and everything that asks for the sessions list pops it.
//

import SwiftUI

/// The shell's four destinations.
enum V2Tab: String, Identifiable, Hashable {
    case chats
    case tasks
    case bots
    case settings

    /// The tabs the bar lists.
    static let destinations: [V2Tab] = [.chats, .tasks, .bots, .settings]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return AppLocalization.string("Chats")
        case .tasks: return AppLocalization.string("Tasks")
        case .bots: return AppLocalization.string("Bots")
        case .settings: return AppLocalization.string("Settings")
        }
    }

    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .tasks: return "checklist"
        case .bots: return "person.2"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// Screens pushed inside a tab.
enum V2Route: Hashable {
    /// The open conversation (AppState's active session or room).
    case conversation
    /// A project's page, its sessions drawn as a tree.
    case project(ProjectSummary)

    static func == (lhs: V2Route, rhs: V2Route) -> Bool {
        switch (lhs, rhs) {
        case (.conversation, .conversation): return true
        case let (.project(left), .project(right)): return left.id == right.id
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .conversation:
            hasher.combine(0)
        case .project(let project):
            hasher.combine(1)
            hasher.combine(project.id)
        }
    }
}

/// What the shell hands its tabs: the profile switch (with its fade) and
/// whether content is faded out for one.
struct V2ShellContext {
    var pickProfile: (String) -> Void = { _ in }
    var contentFaded = false
    /// False while this tab sits hidden behind the selected one (the capsule
    /// bar keeps visited tabs alive), so its polling can stop.
    var isTabActive = true
}

private struct V2ShellContextKey: EnvironmentKey {
    static let defaultValue = V2ShellContext()
}

extension EnvironmentValues {
    var v2Shell: V2ShellContext {
        get { self[V2ShellContextKey.self] }
        set { self[V2ShellContextKey.self] = newValue }
    }
}

struct V2Shell: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: V2Tab = .chats
    /// The app opens on the Chats list. Nothing is pushed during the
    /// launch's first layout: a push then, even without animation, left the
    /// app never idle.
    @State private var chatsPath: [V2Route] = []
    @State private var botsPath: [V2Route] = []
    /// The custom bar keeps a tab alive once it has been opened, so its
    /// scroll position and pushed screens survive switching away.
    @State private var visitedTabs: Set<V2Tab> = [.chats]
    @State private var contentFaded = false
    @State private var profileSwitchToken = 0
    /// A tab the shell switched to itself, which skips the selection click.
    @State private var programmaticTab: V2Tab?
    /// A settings link waiting for the Settings tab to open its page.
    @State private var settingsLink: ConduitAppLink.SettingsLink?

    /// Whether the visible tab shows the conversation.
    private var conversationVisible: Bool {
        switch selectedTab {
        case .chats: return chatsPath.last == .conversation
        case .bots: return botsPath.last == .conversation
        case .tasks, .settings: return false
        }
    }

    /// What the voice button starts: on a project's page, a chat in its
    /// folder; anywhere else in the tabs, a new call.
    private var voiceContext: V2VoiceContext {
        if selectedTab == .chats, case .project(let project)? = chatsPath.last {
            return .project(project)
        }
        return .home
    }

    var body: some View {
        tabs
            .environment(\.v2Shell, V2ShellContext(pickProfile: pickProfile, contentFaded: contentFaded))
            .onChange(of: conversationVisible, initial: true) { _, visible in
                // Covered means streaming rows needn't redraw and the chat
                // doesn't count as seen (AppState.showSidebar).
                if appState.showSidebar == visible {
                    appState.showSidebar = !visible
                }
            }
            .onChange(of: appState.showSidebar) { _, covered in
                if !covered, !conversationVisible {
                    // A call's screen covers the chat on its own; the list
                    // stays where it was behind it.
                    if appState.isVoiceCallScreenPresented {
                        appState.showSidebar = true
                    } else {
                        openConversation()
                    }
                } else if covered, conversationVisible {
                    closeConversation()
                }
            }
            // Leaving a group room from its own toolbar ends that screen.
            .onChange(of: appState.activeRoomSurface?.room.roomID) { old, new in
                // Leaving: whichever tab holds the room's screen, even one
                // that isn't showing, drops it so it doesn't come back.
                if old != nil, new == nil {
                    if chatsPath.last == .conversation { chatsPath.removeLast() }
                    if botsPath.last == .conversation { botsPath.removeLast() }
                } else if new != nil, !conversationVisible, !appState.isVoiceCallScreenPresented {
                    // A room opened without a row tap (just created) shows.
                    openConversation()
                }
            }
            .onChange(of: selectedTab) { _, tab in
                visitedTabs.insert(tab)
                // Only a tab the user picked clicks; a chat or link that
                // switches tabs for them doesn't.
                if programmaticTab == tab {
                    programmaticTab = nil
                } else {
                    Haptics.selection()
                }
            }
            .onChange(of: appState.activeProfile) { _, _ in
                fadeContentBackIn()
            }
            .onChange(of: appState.settingsLinkRequest) { _, page in
                guard let page else { return }
                appState.settingsLinkRequest = nil
                guard !appState.isModalSheetPresented else { return }
                settingsLink = page
                visitedTabs.insert(.settings)
                selectTab(.settings)
            }
            .onDisappear {
                // Sign-in replaces the shell; nothing covers the chat there.
                appState.showSidebar = false
            }
    }

    private var voiceButton: some View {
        V2VoiceButton(context: voiceContext)
    }

    /// The four tabs over a custom glass capsule, the gold voice button
    /// beside it, on every iOS version. iOS 26's own tab bar has no place
    /// for a separate circle: a search-role tab sat inside the bar as a
    /// second Voice item under the button.
    private var tabs: some View {
        ZStack {
            ForEach(V2Tab.destinations) { tab in
                if visitedTabs.contains(tab) {
                    let isSelected = selectedTab == tab
                    tabRoot(tab)
                        .transformEnvironment(\.v2Shell) { $0.isTabActive = isSelected }
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !conversationVisible {
                HStack(spacing: 10) {
                    V2CapsuleTabBar(selection: $selectedTab)
                    voiceButton
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: conversationVisible)
    }

    @ViewBuilder
    private func tabRoot(_ tab: V2Tab) -> some View {
        switch tab {
        case .chats:
            NavigationStack(path: $chatsPath) {
                V2ChatsView()
                    .navigationDestination(for: V2Route.self, destination: destination)
            }
        case .tasks:
            NavigationStack {
                V2TasksView()
            }
        case .bots:
            NavigationStack(path: $botsPath) {
                V2BotsView()
                    .navigationDestination(for: V2Route.self, destination: destination)
            }
        case .settings:
            V2SettingsTab(link: $settingsLink)
        }
    }

    @ViewBuilder
    private func destination(_ route: V2Route) -> some View {
        switch route {
        case .conversation:
            V2ConversationScreen()
        case .project(let project):
            V2ProjectPage(project: project)
        }
    }

    // MARK: - Conversation routing

    /// Pushes the conversation: in Bots when a bot's chat opened from there,
    /// otherwise in Chats. Only one tab ever holds it, since both would show
    /// the same active session.
    private func openConversation() {
        let target: V2Tab = selectedTab == .bots ? .bots : .chats
        switch target {
        case .bots:
            chatsPath.removeAll { $0 == .conversation }
            if botsPath.last != .conversation { botsPath.append(.conversation) }
        default:
            botsPath.removeAll { $0 == .conversation }
            if chatsPath.last != .conversation { chatsPath.append(.conversation) }
        }
        visitedTabs.insert(target)
        selectTab(target)
    }

    private func selectTab(_ tab: V2Tab) {
        guard selectedTab != tab else { return }
        programmaticTab = tab
        selectedTab = tab
    }

    private func closeConversation() {
        switch selectedTab {
        case .chats:
            if chatsPath.last == .conversation { chatsPath.removeLast() }
        case .bots:
            if botsPath.last == .conversation { botsPath.removeLast() }
        case .tasks, .settings:
            break
        }
    }

    // MARK: - Profile switching

    /// Content fades out, the profile switches, and content fades back with
    /// the new profile's sessions (and the backdrop glow in its color).
    private func pickProfile(_ profile: String) {
        guard profile != appState.activeProfile, !appState.isProfileSwitching else { return }
        Haptics.medium()
        profileSwitchToken &+= 1
        let token = profileSwitchToken
        withAnimation(ConduitMotion.fadeOut) { contentFaded = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            guard token == profileSwitchToken else { return }
            await appState.switchProfile(to: profile)
            guard token == profileSwitchToken else { return }
            fadeContentBackIn()
        }
    }

    private func fadeContentBackIn() {
        guard contentFaded else { return }
        withAnimation(ConduitMotion.settle) { contentFaded = false }
    }
}

// MARK: - Capsule tab bar

/// The tab bar: four items in a glass capsule, the selection
/// highlight sliding between them on the overshoot spring.
private struct V2CapsuleTabBar: View {
    @Binding var selection: V2Tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(V2Tab.destinations) { tab in
                let isSelected = selection == tab
                Button {
                    withAnimation(ConduitMotion.overshoot(reduceMotion: reduceMotion)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .conduitFixedGlyph()
                        Text(tab.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Color.conduitAccent : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color.primary.opacity(0.08))
                                .matchedGeometryEffect(id: "selection", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                .accessibilityShowsLargeContentViewer {
                    Label(tab.title, systemImage: tab.symbol)
                }
            }
        }
        .padding(4)
        .conduitGlassControl(cornerRadius: 28, interactive: false)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

/// The switch between V2's tab shell and the drawer shell it replaces.
enum V2ShellPreference {
    static let key = "conduit.useV2Shell"
    static let defaultValue = true
}
