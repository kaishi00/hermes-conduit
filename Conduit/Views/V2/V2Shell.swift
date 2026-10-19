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

import Combine
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
    /// What the active profile's chats produced (Chats bar).
    case artifacts

    static func == (lhs: V2Route, rhs: V2Route) -> Bool {
        switch (lhs, rhs) {
        case (.conversation, .conversation): return true
        case (.artifacts, .artifacts): return true
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
        case .artifacts:
            hasher.combine(2)
        }
    }
}

/// What the shell hands its tabs: the profile switch (with its slide) and
/// where content stands in one.
///
/// Equal when the values are: the shell rebuilds `pickProfile` and
/// `showScheduledRuns` on every render, and a closure never compares equal,
/// so without this every AppState publish would redraw every view that
/// reads the context, the hidden tabs included. Every copy of a closure
/// does the same thing.
/// Values go in `Values`, whose equality is synthesized, so a new one is
/// compared without anyone remembering to.
struct V2ShellContext: Equatable {
    struct Values: Equatable {
        var contentFaded = false
        /// How far content sits off center during a profile switch: it
        /// leaves toward one side and the new profile's arrives from the
        /// other, following the strip (`V2ProfileSwitchContent`).
        var contentShift: CGFloat = 0
        /// False while this tab sits hidden behind the selected one (the
        /// capsule bar keeps visited tabs alive), so its polling can stop.
        var isTabActive = true
        /// True while a screen is pushed over this tab's root (a chat, a
        /// project page), so the root's backdrop can hold still under it.
        var isRootCovered = false
        /// True on a wide iPad window, where Chats and Bots show their list
        /// beside the open chat (`V2SplitLayout`).
        var isSplit = false
        /// Split, with a chat open beside this tab's list.
        var hasChatBeside = false
    }

    var pickProfile: (String) -> Void = { _ in }
    /// Opens Chats filtered to Scheduled, where cron runs are listed.
    var showScheduledRuns: () -> Void = {}
    var values = Values()

    var contentFaded: Bool {
        get { values.contentFaded }
        set { values.contentFaded = newValue }
    }

    var contentShift: CGFloat {
        get { values.contentShift }
        set { values.contentShift = newValue }
    }

    var isTabActive: Bool {
        get { values.isTabActive }
        set { values.isTabActive = newValue }
    }

    var isRootCovered: Bool {
        get { values.isRootCovered }
        set { values.isRootCovered = newValue }
    }

    var isSplit: Bool {
        get { values.isSplit }
        set { values.isSplit = newValue }
    }

    var hasChatBeside: Bool {
        get { values.hasChatBeside }
        set { values.hasChatBeside = newValue }
    }

    static func == (lhs: V2ShellContext, rhs: V2ShellContext) -> Bool {
        lhs.values == rhs.values
    }
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

/// AppState's changes, passed on to a tab's root list only while it shows.
/// Every publish redraws whatever follows AppState, and the Chats list
/// walks the whole catalog to draw (the default profile holds nearly every
/// cron run), so a list kept under a pushed chat cost the chat frames on
/// every update. Hidden, the list waits; shown again, it draws once with
/// everything it missed. Beside a chat (a wide iPad), the list shows but
/// draws at most a few times a second, so a streaming reply's publishes
/// don't each redraw it.
@MainActor
final class V2ShownUpdates: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    /// Set by the list from the shell's context.
    var isShown = true {
        didSet { if isShown, !oldValue, missedUpdate { missedUpdate = false; objectWillChange.send() } }
    }
    /// Set by the list: a chat is open beside it.
    var coalesces = false
    /// How long the list beside a chat waits to draw the publishes since.
    var coalescingDelay: TimeInterval = 0.5
    private var missedUpdate = false
    private var drawScheduled = false
    private var subscription: AnyCancellable?
    private var defaultsSubscription: AnyCancellable?
    /// The list's saved settings, read through here rather than
    /// `@AppStorage`: SwiftUI redraws every `@AppStorage` view on any write
    /// to the defaults, whatever its key, and a chat saves its scroll
    /// position there.
    let defaults: UserDefaults
    private let defaultsKeys: [String]
    private var defaultsValues: [NSObject?]

    /// Read through here by the list's rows, which follow these updates.
    /// Held strongly: AppState never holds the gate, and the sink below
    /// holds the gate weakly.
    let appState: AppState

    init(_ appState: AppState, defaults: UserDefaults = .standard, defaultsKeys: [String] = []) {
        self.appState = appState
        self.defaults = defaults
        self.defaultsKeys = defaultsKeys
        defaultsValues = Self.values(of: defaultsKeys, in: defaults)
        subscription = appState.objectWillChange.sink { [weak self] _ in
            self?.passOn()
        }
        guard !defaultsKeys.isEmpty else { return }
        defaultsSubscription = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                // A write from elsewhere; the list's own go through `set`.
                Task { @MainActor [weak self] in self?.defaultsChanged() }
            }
    }

    /// Saves one of the list's settings and redraws it at once.
    func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        defaultsChanged(atOnce: true)
    }

    private func passOn() {
        guard isShown else { missedUpdate = true; return }
        guard coalesces else { objectWillChange.send(); return }
        guard !drawScheduled else { return }
        drawScheduled = true
        let delay = coalescingDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            drawScheduled = false
            // Covered meanwhile, it waits for the list to show again.
            if isShown { objectWillChange.send() } else { missedUpdate = true }
        }
    }

    /// At once for the list's own write: a tap beside a chat doesn't wait.
    private func defaultsChanged(atOnce: Bool = false) {
        let values = Self.values(of: defaultsKeys, in: defaults)
        guard values != defaultsValues else { return }
        defaultsValues = values
        if atOnce, isShown { objectWillChange.send() } else { passOn() }
    }

    /// Property-list values, compared by `isEqual:`.
    private static func values(of keys: [String], in defaults: UserDefaults) -> [NSObject?] {
        keys.map { defaults.object(forKey: $0) as? NSObject }
    }
}

struct V2Shell: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
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
    @State private var contentShift: CGFloat = 0
    @State private var profileSwitchToken = 0
    /// A tab the shell switched to itself, which skips the selection click.
    @State private var programmaticTab: V2Tab?
    /// A settings link waiting for the Settings tab to open its page.
    @State private var settingsLink: ConduitAppLink.SettingsLink?
    /// The floating bar's height as last laid out (the capsule and the
    /// voice button, with their bottom padding).
    @State private var tabBarHeight: CGFloat = 62
    @AppStorage(V2MainButtonPreference.key) private var mainButtonNewChat = V2MainButtonPreference.defaultValue

    /// Whether the visible tab shows the conversation.
    private var conversationVisible: Bool {
        switch selectedTab {
        case .chats: return chatsPath.last == .conversation
        case .bots: return botsPath.last == .conversation
        case .tasks, .settings: return false
        }
    }

    /// Whether either tab holds the conversation, shown or not.
    private var conversationPushed: Bool {
        chatsPath.contains(.conversation) || botsPath.contains(.conversation)
    }

    /// Whether a screen is pushed over the tab's root. Split, the chat
    /// sits beside the list rather than over it.
    private func isRootCovered(_ tab: V2Tab, split: Bool) -> Bool {
        let path = path(of: tab)
        return split ? path.contains { $0 != .conversation } : !path.isEmpty
    }

    private func path(of tab: V2Tab) -> [V2Route] {
        switch tab {
        case .chats: chatsPath
        case .bots: botsPath
        case .tasks, .settings: []
        }
    }

    /// What the voice button starts: on a project's page, a chat in its
    /// folder; anywhere else in the tabs, a new call. The list's own top
    /// screen decides, so a chat open beside a project's page keeps it.
    private var voiceContext: V2VoiceContext {
        if selectedTab == .chats, case .project(let project)? = V2SplitLayout.listRoutes(chatsPath).last {
            return .project(project)
        }
        return .home
    }

    /// The tabs, one column or split by the window's width, which the
    /// reader already has at the first layout: a wide iPad opens split
    /// rather than laying the tabs out once as a phone's. The width stays
    /// live, so a window resized across the threshold (Stage Manager, Split
    /// View) switches layout and rebuilds the tab's stacks: the paths, and
    /// so the open chat, carry over; the tab's own state (the list's scroll
    /// position, its search) doesn't.
    private var sizedTabs: some View {
        GeometryReader { proxy in
            let split = V2SplitLayout.isSplit(width: proxy.size.width)
            tabs(split: split)
                .environment(\.v2Shell, V2ShellContext(pickProfile: pickProfile, showScheduledRuns: showScheduledRuns, values: .init(contentFaded: contentFaded, contentShift: contentShift, isSplit: split)))
        }
    }

    var body: some View {
        sizedTabs
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
            // The room's screen was popped (Back, the edge swipe, or the
            // return-to-list setting): leave the room, so it stops polling
            // and opens again on its next tap. Moving the screen between
            // tabs keeps it pushed in one of them. Waits out the pop so the
            // outgoing screen doesn't redraw as a chat while it slides away.
            // A row tap in that wait reopens the same room id, which the
            // room id change below can't see: the epoch moved, so the room
            // stays and its screen is pushed again.
            .onChange(of: conversationPushed) { _, pushed in
                guard !pushed, appState.activeRoomSurface != nil else { return }
                let epoch = appState.groupRoomEpoch
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !conversationPushed, appState.activeRoomSurface != nil else { return }
                    if appState.groupRoomEpoch == epoch {
                        appState.closeGroupRoom()
                    } else if !appState.isVoiceCallScreenPresented {
                        openConversation()
                    }
                }
            }
            // Leaving a group room another way (disband, server change)
            // ends that screen.
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

    /// The gold button beside the tabs: voice, or New chat when the user
    /// swapped them (Settings > Appearance). A minimised call still comes
    /// back through it either way.
    @ViewBuilder private var voiceButton: some View {
        if mainButtonNewChat, appState.minimisedLiveVoice == nil {
            V2NewChatButton(context: voiceContext)
        } else {
            V2VoiceButton(context: voiceContext)
        }
    }

    /// The four tabs over a custom glass capsule, the gold voice button
    /// beside it, on every iOS version. iOS 26's own tab bar has no place
    /// for a separate circle: a search-role tab sat inside the bar as a
    /// second Voice item under the button.
    /// Split (a wide iPad window), the bar stays up under the list column,
    /// beside the open chat, on every tab.
    private func tabs(split: Bool) -> some View {
        ZStack {
            ForEach(V2Tab.destinations) { tab in
                // The selected tab shows from the tap's own frame; it joins
                // the visited ones right after.
                if visitedTabs.contains(tab) || selectedTab == tab {
                    let isSelected = selectedTab == tab
                    let rootCovered = isRootCovered(tab, split: split)
                    let chatBeside = split && path(of: tab).contains(.conversation)
                    tabRoot(tab, split: split)
                        .transformEnvironment(\.v2Shell) {
                            $0.isTabActive = isSelected
                            $0.isRootCovered = rootCovered
                            $0.hasChatBeside = chatBeside
                        }
                        // The opened tab shows at once and the one left
                        // hides at once. A fade read as slow, and a slide
                        // only ever ran on the first switch after launch.
                        .opacity(isSelected ? 1 : 0)
                        // Nothing in or on a tab animates with the switch,
                        // whatever transaction the bar's tap carries.
                        .animation(nil, value: selectedTab)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                        .transition(.identity)
                }
            }
        }
        // The bar floats over the screens instead of insetting them: hiding
        // it for a pushed chat then moves only the bar, not the layout of the
        // chat being pushed. Screens that show it keep a fixed clearance
        // (`tabBarClearance`).
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                if split || !conversationVisible {
                    HStack(spacing: 10) {
                        V2CapsuleTabBar(selection: $selectedTab)
                        voiceButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .frame(width: split ? V2SplitLayout.listWidth : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        if abs(height - tabBarHeight) > 0.5 { tabBarHeight = height }
                    }
                    // Lists fade out under the bar, as a chat does under its
                    // composer: iOS 26 draws that edge itself, under the
                    // clearance (`tabBarClearance`).
                    .modifier(V2LegacyTabBarEdge())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: conversationVisible)
        }
        .overlay(alignment: .top) {
            // Animated on its own, so the notice slides in without
            // animating the screen under it.
            ZStack(alignment: .top) {
                if let notice = appState.pinSyncNotice {
                    V2NoticeBanner(notice: notice) { appState.dismissPinSyncNotice(notice.id) }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: appState.pinSyncNotice)
        }
    }

    /// Room under the floating bar for a screen that shows it: its lists
    /// scroll under the bar and stop above it. The same height whether or
    /// not the bar is up, so pushing or popping a chat never re-lays out
    /// the screen under it.
    /// On iOS 26 the clearance is a bar to the lists, so they draw the
    /// system's soft edge under the floating bar.
    private func tabBarClearance<Content: View>(_ content: Content) -> some View {
        content.v2EdgeBar(.bottom) {
            Color.clear
                .frame(height: tabBarHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func tabRoot(_ tab: V2Tab, split: Bool) -> some View {
        switch tab {
        case .chats where split:
            splitColumns(path: $chatsPath, offersNewChat: true) {
                tabBarClearance(V2ChatsView(appState: appState).equatable())
            }
        case .bots where split:
            splitColumns(path: $botsPath, offersNewChat: false) {
                tabBarClearance(V2BotsView())
            }
        case .chats:
            NavigationStack(path: $chatsPath) {
                // Only the list's own changes redraw it, not the shell's
                // (`V2ShownUpdates`).
                tabBarClearance(V2ChatsView(appState: appState).equatable())
                    .navigationDestination(for: V2Route.self, destination: destination)
            }
        case .tasks:
            // Inside the stack, as on Chats and Bots: the lists in it stop
            // above the bar and fade under it.
            NavigationStack {
                tabBarClearance(V2TasksView())
            }
        case .bots:
            NavigationStack(path: $botsPath) {
                tabBarClearance(V2BotsView())
                    .navigationDestination(for: V2Route.self, destination: destination)
            }
        case .settings:
            // Settings puts the clearance inside its own stack, on its home
            // and on every page it pushes (`v2TabBarClearance()`).
            V2SettingsTab(link: $settingsLink)
                .environment(\.v2TabBarClearance, tabBarHeight)
        }
    }

    /// A wide window's Chats or Bots: the list column, with the pages it
    /// pushes (a project, Artifacts), and the open chat beside it. The tab's
    /// path stays the one a phone's stack follows, the conversation last
    /// in it, so every route in and out of a chat works the same; only the
    /// list's own stack leaves the conversation out.
    private func splitColumns<Root: View>(
        path: Binding<[V2Route]>,
        offersNewChat: Bool,
        @ViewBuilder root: () -> Root
    ) -> some View {
        let list = root()
        return HStack(spacing: 0) {
            NavigationStack(path: V2SplitLayout.listPath(path)) {
                list
                    .navigationDestination(for: V2Route.self, destination: destination)
            }
            .frame(width: V2SplitLayout.listWidth)
            // Each column's backdrop stays in its own column.
            .clipped()
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            if path.wrappedValue.contains(.conversation) {
                NavigationStack {
                    V2ConversationScreen()
                }
                // Pushed or popped on a phone, VoiceOver follows; beside
                // the list the column says so itself, opening or closing.
                .onAppear {
                    UIAccessibility.post(notification: .screenChanged, argument: nil)
                }
                .onDisappear {
                    UIAccessibility.post(notification: .screenChanged, argument: nil)
                }
                .clipped()
            } else {
                V2SplitPlaceholder(offersNewChat: offersNewChat)
                    .clipped()
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: V2Route) -> some View {
        switch route {
        case .conversation:
            V2ConversationScreen()
        case .project(let project):
            tabBarClearance(V2ProjectPage(project: project))
        case .artifacts:
            tabBarClearance(V2ArtifactsPage())
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

    /// Cron runs stay out of the All list (SidebarSourceRows): Scheduled
    /// lists them, at the top of Chats rather than behind an open chat.
    private func showScheduledRuns() {
        // The Chats filter and its Sessions/Projects switch (V2ChatsView):
        // Projects would hide the runs.
        UserDefaults.standard.set(V2SessionFilter.scheduled.rawValue, forKey: V2ChatsView.filterKey)
        UserDefaults.standard.set("sessions", forKey: V2ChatsView.presentationKey)
        // The list itself: not a chat, a project or Artifacts over it.
        chatsPath.removeAll()
        visitedTabs.insert(.chats)
        selectTab(.chats)
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

    /// Content slides out toward the side the picked profile isn't on (a
    /// profile to the right in the strip pushes content left, like turning a
    /// page), the profile switches, and the new profile's sessions slide in
    /// from the other side (with the backdrop glow in its color). Under
    /// Reduce Motion it only fades.
    private func pickProfile(_ profile: String) {
        guard profile != appState.activeProfile, !appState.isProfileSwitching else { return }
        Haptics.medium()
        profileSwitchToken &+= 1
        let token = profileSwitchToken
        let distance = reduceMotion ? 0 : Self.profileSwitchDistance * profileSwitchDirection(to: profile)
        withAnimation(ConduitMotion.fadeOut) {
            contentFaded = true
            contentShift = -distance
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ConduitMotion.fadeOutDuration))
            guard token == profileSwitchToken else { return }
            // Out of sight, content moves to the side it arrives from.
            withTransaction(Transaction(animation: nil)) { contentShift = distance }
            await appState.switchProfile(to: profile)
            guard token == profileSwitchToken else { return }
            fadeContentBackIn()
        }
    }

    private static let profileSwitchDistance: CGFloat = 44

    /// 1 when the picked profile sits right of the current one in the strip,
    /// -1 when left. The strip mirrors right to left; the offset doesn't.
    private func profileSwitchDirection(to profile: String) -> CGFloat {
        let profiles = appState.profiles
        guard let from = profiles.firstIndex(of: appState.activeProfile),
              let to = profiles.firstIndex(of: profile) else { return 1 }
        let later: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
        return to < from ? -later : later
    }

    private func fadeContentBackIn() {
        guard contentFaded else { return }
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
            contentFaded = false
            contentShift = 0
        }
    }
}

/// A tab's content during a profile switch: faded and shifted as the shell
/// says. Offset and opacity only, so the move costs no layout.
struct V2ProfileSwitchContent: ViewModifier {
    @Environment(\.v2Shell) private var shell

    func body(content: Content) -> some View {
        content
            .opacity(shell.contentFaded ? 0 : 1)
            .offset(x: shell.contentShift)
            // Out of sight, the old profile's rows take no taps.
            .allowsHitTesting(!shell.contentFaded)
            .accessibilityHidden(shell.contentFaded)
    }
}

extension View {
    func v2ProfileSwitchContent() -> some View {
        modifier(V2ProfileSwitchContent())
    }
}

// MARK: - Split

/// A wide window (an iPad, or a wide iPad window in Split View or Stage
/// Manager) shows Chats and Bots as two columns: the list, and the open
/// chat beside it. It follows the window's width rather than the device,
/// so a narrow iPad window, or an unfolded iPhone Duo, keeps the phone's
/// one column.
enum V2SplitLayout {
    /// The list column: the narrowest iPhone's width, which every V2 list
    /// screen already fits.
    static let listWidth: CGFloat = 375
    /// The least room the chat keeps beside the list.
    static let minimumChatWidth: CGFloat = 430

    static func isSplit(width: CGFloat) -> Bool {
        width >= listWidth + 1 + minimumChatWidth
    }

    /// The list column's stack: the tab's path without the conversation,
    /// which shows beside it. A page pushed or popped in the column keeps
    /// the conversation at the end of the tab's path.
    static func listPath(_ path: Binding<[V2Route]>) -> Binding<[V2Route]> {
        Binding {
            listRoutes(path.wrappedValue)
        } set: { routes, transaction in
            withTransaction(transaction) {
                path.wrappedValue = tabRoutes(listing: routes, keepsConversation: path.wrappedValue.contains(.conversation))
            }
        }
    }

    static func listRoutes(_ path: [V2Route]) -> [V2Route] {
        path.filter { $0 != .conversation }
    }

    static func tabRoutes(listing routes: [V2Route], keepsConversation: Bool) -> [V2Route] {
        let list = listRoutes(routes)
        return keepsConversation ? list + [.conversation] : list
    }
}

/// The chat column with no chat open.
private struct V2SplitPlaceholder: View {
    @EnvironmentObject private var appState: AppState
    /// Chats offers a new chat here; Bots opens a bot's from its list.
    let offersNewChat: Bool

    var body: some View {
        ZStack {
            V2Backdrop(drifts: false)
            VStack(spacing: 18) {
                Image(systemName: offersNewChat ? V2Tab.chats.symbol : V2Tab.bots.symbol)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                if offersNewChat {
                    Button {
                        Haptics.medium()
                        appState.startNewChat()
                    } label: {
                        Label(AppLocalization.string("Start a new conversation"), systemImage: "square.and.pencil")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.conduitAccent)
                    .conduitGlassControl(cornerRadius: 22, tint: .conduitAccent.opacity(0.12))
                    .disabled(!appState.canTapNewChat)
                }
            }
            .padding(24)
        }
        // Bots' has nothing to act on.
        .accessibilityHidden(!offersNewChat)
    }
}

// MARK: - Notice

/// A short notice over the top of the screen, with its own symbol: a pin
/// change that stayed on this iPhone and what Hermes said, or a widget
/// action that couldn't finish. It goes away after a few seconds, or on a
/// tap.
private struct V2NoticeBanner: View {
    let notice: PinSyncNotice
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: notice.systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.conduitAccent)
                    .accessibilityHidden(true)
                Text(notice.message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .conduitGlassControl(cornerRadius: 20, interactive: false)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint(Text(AppLocalization.string("Dismiss")))
        .task(id: notice.id) {
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            dismiss()
        }
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

    /// The same value the views read through `@AppStorage`.
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// Whether the gold button beside the tabs starts a new chat instead of
/// voice, for people who'd rather not talk. Voice then moves to the top
/// bar's New chat slot; a chat's own voice button stays.
enum V2MainButtonPreference {
    static let key = "conduit.v2.mainButtonNewChat"
    static let defaultValue = false
}

private struct V2TabBarClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The floating tab bar's height, for a tab whose own NavigationStack
    /// gives each of its screens the clearance; 0 outside the V2 shell.
    var v2TabBarClearance: CGFloat {
        get { self[V2TabBarClearanceKey.self] }
        set { self[V2TabBarClearanceKey.self] = newValue }
    }
}

extension View {
    /// Room under the V2 floating tab bar, set inside a tab's own
    /// NavigationStack on each screen it shows, as the shell's
    /// `tabBarClearance` does for the other tabs. Nothing outside V2.
    func v2TabBarClearance() -> some View {
        modifier(V2TabBarClearance())
    }
}

private struct V2TabBarClearance: ViewModifier {
    @Environment(\.v2TabBarClearance) private var height

    @ViewBuilder
    func body(content: Content) -> some View {
        if height > 0 {
            content.v2EdgeBar(.bottom) {
                Color.clear
                    .frame(height: height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}

/// Before iOS 26, the capsule bar carries the fading material the lists
/// scroll under, reaching a little above the bar. iOS 26 draws a soft
/// edge under the bar's clearance instead.
private struct V2LegacyTabBarEdge: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.background { V2ScrollEdgeBackground(edge: .bottom).padding(.top, -14) }
        }
    }
}
