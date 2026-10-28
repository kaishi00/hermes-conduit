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
        /// True on a window wide enough to split, whether or not the user
        /// hid the list (`V2ChatListPreference`): the chat offers the
        /// list's toggle.
        var canSplit = false
        /// Split, with a chat open beside this tab's list.
        var hasChatBeside = false
        /// The tab's list column shows chat rows: its list or a project's
        /// page is on top (`V2SplitLayout.showsChatRows`).
        var showsChatRows = true
        /// That chat shows its own voice button (a group room has none),
        /// so the list column leaves voice to it.
        var hasChatVoiceBeside = false
        /// A switch picked from the profile strip is under way, from the
        /// first tap's fade-out until the switch is over.
        var isPickingProfile = false
    }

    var pickProfile: (String) -> Void = { _ in }
    /// Drops a profile tap kept for after the running switch: a later tap
    /// on All decides instead.
    var dropQueuedProfilePick: () -> Void = {}
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

    var canSplit: Bool {
        get { values.canSplit }
        set { values.canSplit = newValue }
    }

    var hasChatBeside: Bool {
        get { values.hasChatBeside }
        set { values.hasChatBeside = newValue }
    }

    var showsChatRows: Bool {
        get { values.showsChatRows }
        set { values.showsChatRows = newValue }
    }

    var hasChatVoiceBeside: Bool {
        get { values.hasChatVoiceBeside }
        set { values.hasChatVoiceBeside = newValue }
    }

    var isPickingProfile: Bool {
        get { values.isPickingProfile }
        set { values.isPickingProfile = newValue }
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
/// don't each redraw it. While the list scrolls it waits too, and draws
/// once when the scroll comes to rest: right after launch the connection,
/// catalog, projects and live statuses publish many times a second, and a
/// redraw of the whole list on each cost the scroll its frames.
@MainActor
final class V2ShownUpdates: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    /// Set by the list from the shell's context.
    var isShown = true {
        didSet {
            // Covered, it isn't scrolling: what the scroll held waits for
            // the list to show again.
            if !isShown { endScrolling() }
            if isShown, !oldValue, missedUpdate { missedUpdate = false; draw() }
        }
    }
    /// Set by the list: a chat is open beside it.
    var coalesces = false
    /// Whether a list it draws is scrolling (a drag, a fling, or a scroll
    /// the app runs). Each list reports its own scroll, so one list's
    /// teardown during the Sessions/Projects slide doesn't end another's.
    var isScrolling: Bool { !scrollingLists.isEmpty }
    private var scrollingLists: Set<AnyHashable> = []

    /// A list's scroll moved on a phase or came to rest. Each new phase
    /// (a drag, then the fling after it) restarts the hold.
    func setScrolling(_ scrolling: Bool, by list: AnyHashable) {
        if scrolling {
            scrollingLists.insert(list)
            scrollStartedAt = now()
        } else if scrollingLists.remove(list) != nil, scrollingLists.isEmpty {
            scrollEnded()
        }
    }

    /// Every scroll ends: the list is covered, or the app left the screen,
    /// where a scroll view may never report coming to rest.
    func endScrolling() {
        guard isScrolling else { return }
        scrollingLists.removeAll()
        scrollEnded()
    }

    private func scrollEnded() {
        // The next scroll's hold gets a timer of its own.
        holdLimitTask?.cancel()
        holdLimitTask = nil
        guard missedScrollUpdate else { return }
        missedScrollUpdate = false
        passOn()
    }
    /// A scroll that never rests (a slow drag held on screen) draws what it
    /// held back after this long, so the list doesn't stay stale.
    var scrollHoldLimit: TimeInterval = 2
    private var scrollStartedAt = Date.distantPast
    private var missedScrollUpdate = false
    private var holdLimitTask: Task<Void, Never>?
    /// The clock the hold reads; tests set their own.
    var now: () -> Date = Date.init
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
        guard !holdsForScroll() else { holdForScroll(); return }
        guard coalesces else { draw(); return }
        guard !drawScheduled else { return }
        drawScheduled = true
        let delay = coalescingDelay
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { self?.drawScheduled = false; return }
            guard let self else { return }
            drawScheduled = false
            // Covered meanwhile, it waits for the list to show again;
            // scrolling, for the scroll to rest.
            if !isShown {
                missedUpdate = true
            } else if holdsForScroll() {
                holdForScroll()
            } else {
                draw()
            }
        }
    }

    /// Scrolling, and the hold since the scroll started (or since the last
    /// draw during it) hasn't run out.
    private func holdsForScroll() -> Bool {
        isScrolling && now().timeIntervalSince(scrollStartedAt) < scrollHoldLimit
    }

    /// Holds a publish until the scroll rests, or until the hold runs out
    /// even if nothing else publishes meanwhile.
    private func holdForScroll() {
        missedScrollUpdate = true
        guard holdLimitTask == nil else { return }
        let wait = max(scrollHoldLimit - now().timeIntervalSince(scrollStartedAt), 0.05)
        holdLimitTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            guard let self else { return }
            holdLimitTask = nil
            // A draw meanwhile restarted the hold; passing on holds again.
            if missedScrollUpdate { passOn() }
        }
    }

    /// A draw during a scroll restarts its hold.
    private func draw() {
        if isScrolling { scrollStartedAt = now() }
        missedScrollUpdate = false
        objectWillChange.send()
    }

    /// At once for the list's own write: a tap beside a chat doesn't wait.
    private func defaultsChanged(atOnce: Bool = false) {
        let values = Self.values(of: defaultsKeys, in: defaults)
        guard values != defaultsValues else { return }
        defaultsValues = values
        if atOnce, isShown { draw() } else { passOn() }
    }

    /// Property-list values, compared by `isEqual:`.
    private static func values(of keys: [String], in defaults: UserDefaults) -> [NSObject?] {
        keys.map { defaults.object(forKey: $0) as? NSObject }
    }
}

extension View {
    /// Tells `updates` while this scroll view moves, so a burst of publishes
    /// waits for it to rest (iOS 18; earlier systems draw each one).
    func v2HoldsUpdatesWhileScrolling(_ updates: V2ShownUpdates) -> some View {
        modifier(V2ScrollHold(updates: updates))
    }
}

private struct V2ScrollHold: ViewModifier {
    let updates: V2ShownUpdates
    /// This list, among the ones `updates` draws.
    @State private var id = UUID()
    /// VoiceOver reads the rows as they scroll by, so they stay current.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    updates.setScrolling(phase != .idle && !voiceOver, by: id)
                }
                .onDisappear { updates.setScrolling(false, by: id) }
        } else {
            content
        }
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
    /// A profile tapped while a switch runs, switched to once it ends.
    @State private var queuedProfilePick = V2QueuedProfilePick()
    /// A switch picked from the strip is running, from the first tap's
    /// fade-out until the switch is over.
    @State private var isPickingProfile = false
    /// A strip pick is still fading out and hasn't started its switch: a
    /// switch started elsewhere meanwhile doesn't bring the content back.
    @State private var isFadingOutForPick = false
    /// A tab the shell switched to itself, which skips the selection click.
    @State private var programmaticTab: V2Tab?
    /// A settings link waiting for the Settings tab to open its page.
    @State private var settingsLink: ConduitAppLink.SettingsLink?
    /// The floating bar's height as last laid out (the capsule and the
    /// voice button, with their bottom padding).
    @State private var tabBarHeight: CGFloat = 62
    @AppStorage(V2MainButtonPreference.key) private var mainButtonNewChat = V2MainButtonPreference.defaultValue
    @AppStorage(V2ChatListPreference.key) private var chatListBeside = V2ChatListPreference.defaultValue

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
    /// position, its search) doesn't. Hiding the list (the chat's toggle,
    /// Settings > Appearance) gives a wide window the phone's one column
    /// the same way.
    private var sizedTabs: some View {
        GeometryReader { proxy in
            let canSplit = V2SplitLayout.isSplit(width: proxy.size.width)
            let split = V2SplitLayout.isSplit(width: proxy.size.width, showsList: chatListBeside)
            tabs(split: split, canSplit: canSplit)
                .environment(\.v2Shell, V2ShellContext(pickProfile: { pickProfile($0) }, dropQueuedProfilePick: { queuedProfilePick = V2QueuedProfilePick() }, showScheduledRuns: showScheduledRuns, values: .init(contentFaded: contentFaded, contentShift: contentShift, isSplit: split, canSplit: canSplit, isPickingProfile: isPickingProfile)))
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
                // The new profile's chats show as soon as it's active (its
                // saved list, until the live one lands), not once the whole
                // switch is over. A tap kept for after this switch keeps the
                // content out instead, so it doesn't flicker in and out
                // between the two.
                guard queuedProfilePick.profile == nil, !isFadingOutForPick else { return }
                fadeContentBackIn()
            }
            .onChange(of: appState.isProfileSwitching) { _, switching in
                // A strip switch drains its own kept tap when it ends; this
                // is for a switch started elsewhere (the picker sheet,
                // CarPlay).
                guard !switching, !isPickingProfile else { return }
                guard let next = queuedProfilePick.take(
                    landedOn: appState.activeProfile,
                    dashboardID: appState.activeDashboardID
                ) else {
                    // A strip pick that waited behind it came to nothing.
                    fadeContentBackIn()
                    return
                }
                // Its haptic came with the tap.
                pickProfile(next, haptic: false)
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
    /// back through it either way. Voice steps aside for a chat open beside
    /// the list, whose own voice button (and its way back to a minimised
    /// call) sits by the composer: two gold buttons read as a duplicate.
    @ViewBuilder private func voiceButton(chatVoiceBeside: Bool) -> some View {
        if mainButtonNewChat, appState.minimisedLiveVoice == nil {
            V2NewChatButton(context: voiceContext)
        } else if !chatVoiceBeside {
            V2VoiceButton(context: voiceContext)
        }
    }

    /// The four tabs over a custom glass capsule, the gold voice button
    /// beside it, on every iOS version. iOS 26's own tab bar has no place
    /// for a separate circle: a search-role tab sat inside the bar as a
    /// second Voice item under the button.
    /// Split (a wide iPad window), the bar stays up under the list column,
    /// beside the open chat. Settings opens where the chat would be, the
    /// Chats list kept beside it (`V2SplitLayout.settingsBesideList`).
    /// A wide window's screens with no list column (Tasks, a list the user
    /// hid beside the chat) center their content, and the bar centers
    /// under it rather than sitting alone in the corner.
    private func tabs(split: Bool, canSplit: Bool) -> some View {
        let settingsBeside = V2SplitLayout.settingsBesideList(split: split)
        return ZStack {
            ForEach(V2Tab.destinations) { tab in
                // The selected tab shows from the tap's own frame; it joins
                // the visited ones right after. Split, Settings shows in
                // the Chats tab's chat column instead of a tab of its own.
                if (visitedTabs.contains(tab) || selectedTab == tab || (settingsBeside && tab == .chats && selectedTab == .settings)),
                   !(settingsBeside && tab == .settings) {
                    let isSelected = selectedTab == tab || (settingsBeside && tab == .chats && selectedTab == .settings)
                    let rootCovered = isRootCovered(tab, split: split)
                    // Settings in the chat column covers the chat.
                    let chatShown = !(tab == .chats && selectedTab == .settings)
                    let chatBeside = split && chatShown && path(of: tab).contains(.conversation)
                    let chatVoiceBeside = chatShown && V2SplitLayout.hasChatVoiceBeside(split: split, path: path(of: tab), inRoom: appState.activeRoomSurface != nil)
                    tabRoot(tab, split: split, canSplit: canSplit)
                        // Split, the list marks what shows beside it.
                        .environment(\.v2OpenBeside, split ? V2SplitLayout.openBeside(chatBeside: chatBeside, roomID: appState.activeRoomSurface?.room.roomID) : nil)
                        .transformEnvironment(\.v2Shell) {
                            $0.isTabActive = isSelected
                            $0.isRootCovered = rootCovered
                            $0.hasChatBeside = chatBeside
                            $0.showsChatRows = V2SplitLayout.showsChatRows(split: split, path: path(of: tab))
                            $0.hasChatVoiceBeside = chatVoiceBeside
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
                        voiceButton(chatVoiceBeside: V2SplitLayout.hasChatVoiceBeside(split: split, path: path(of: selectedTab), inRoom: appState.activeRoomSurface != nil))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .frame(width: canSplit ? V2SplitLayout.listWidth : nil)
                    .frame(maxWidth: .infinity, alignment: V2SplitLayout.tabBarUnderList(split: split, tab: selectedTab) ? .leading : .center)
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
    private func tabRoot(_ tab: V2Tab, split: Bool, canSplit: Bool) -> some View {
        switch tab {
        case .chats where split:
            splitColumns(path: $chatsPath, offersNewChat: true, hostsSettings: true) {
                tabBarClearance(V2ChatsView(appState: appState).equatable())
            }
        case .bots where split:
            splitColumns(path: $botsPath, offersNewChat: false, hostsSettings: false) {
                tabBarClearance(V2BotsView())
            }
        case .chats:
            NavigationStack(path: $chatsPath) {
                // Only the list's own changes redraw it, not the shell's
                // (`V2ShownUpdates`).
                listRoot(tabBarClearance(V2ChatsView(appState: appState).equatable()), alone: canSplit)
                    .navigationDestination(for: V2Route.self) { destination($0, alone: canSplit) }
            }
        case .tasks:
            // Inside the stack, as on Chats and Bots: the lists in it stop
            // above the bar and fade under it.
            NavigationStack {
                tabBarClearance(V2TasksView())
            }
        case .bots:
            NavigationStack(path: $botsPath) {
                listRoot(tabBarClearance(V2BotsView()), alone: canSplit)
                    .navigationDestination(for: V2Route.self) { destination($0, alone: canSplit) }
            }
        case .settings:
            // Settings puts the clearance inside its own stack, on its home
            // and on every page it pushes (`v2TabBarClearance()`).
            V2SettingsTab(link: $settingsLink)
                .environment(\.v2TabBarClearance, tabBarHeight)
        }
    }

    /// A Chats or Bots list, or a page it pushes, in one column. `alone` is
    /// a wide window whose user hid the list beside the chat: the list
    /// keeps to a readable column rather than running the window's width.
    /// Inside the stack, so a chat pushed over it keeps its own width.
    @ViewBuilder
    private func listRoot<Content: View>(_ content: Content, alone: Bool) -> some View {
        if alone {
            content.readableContentWidth(ReadableWidth.list)
        } else {
            content
        }
    }

    /// A wide window's Chats or Bots: the list column, with the pages it
    /// pushes (a project, Artifacts), and the open chat beside it. The tab's
    /// path stays the one a phone's stack follows, the conversation last
    /// in it, so every route in and out of a chat works the same; only the
    /// list's own stack leaves the conversation out.
    /// `hostsSettings`: Chats, whose chat column also holds Settings while
    /// that tab is picked. It stays mounted once opened, as a hidden tab
    /// does, so its pushed page survives a trip to a chat and back.
    private func splitColumns<Root: View>(
        path: Binding<[V2Route]>,
        offersNewChat: Bool,
        hostsSettings: Bool,
        @ViewBuilder root: () -> Root
    ) -> some View {
        let list = root()
        let showsSettings = hostsSettings && selectedTab == .settings
        return HStack(spacing: 0) {
            NavigationStack(path: V2SplitLayout.listPath(path)) {
                list
                    .navigationDestination(for: V2Route.self) { destination($0) }
            }
            .frame(width: V2SplitLayout.listWidth)
            // Each column's backdrop stays in its own column.
            .clipped()
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            ZStack {
                Group {
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
                    } else {
                        V2SplitPlaceholder(offersNewChat: offersNewChat)
                    }
                }
                .opacity(showsSettings ? 0 : 1)
                .allowsHitTesting(!showsSettings)
                .accessibilityHidden(showsSettings)
                if hostsSettings, showsSettings || visitedTabs.contains(.settings) {
                    // No bar under this column: the bar sits under the list.
                    V2SettingsTab(link: $settingsLink)
                        .environment(\.v2TabBarClearance, 0)
                        .transformEnvironment(\.v2Shell) {
                            $0.isTabActive = showsSettings
                            // Its own root: a page over the list doesn't cover it.
                            $0.isRootCovered = false
                        }
                        .opacity(showsSettings ? 1 : 0)
                        .allowsHitTesting(showsSettings)
                        .accessibilityHidden(!showsSettings)
                }
            }
            .animation(nil, value: selectedTab)
            .clipped()
        }
    }

    /// `alone`: a wide window with the list hidden, where the list's pages
    /// keep to its readable column (`listRoot`); a chat caps itself.
    @ViewBuilder
    private func destination(_ route: V2Route, alone: Bool = false) -> some View {
        switch route {
        case .conversation:
            V2ConversationScreen()
        case .project(let project):
            listRoot(tabBarClearance(V2ProjectPage(project: project)), alone: alone)
        case .artifacts:
            listRoot(tabBarClearance(V2ArtifactsPage()), alone: alone)
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
    private func pickProfile(_ profile: String, haptic: Bool = true) {
        // A switch takes a moment on a real dashboard: a tap meanwhile (its
        // fade-out included) is kept rather than dropped, and the last one
        // goes once it ends.
        if appState.isProfileSwitching || isPickingProfile {
            queuedProfilePick.tap(profile, dashboardID: appState.activeDashboardID)
            if haptic { Haptics.medium() }
            // The profile showing is on its way out: its chats leave now
            // rather than stay tappable until the kept pick goes.
            withAnimation(ConduitMotion.fadeOut) { contentFaded = true }
            return
        }
        // This tap is the newest: a pick still kept from a switch that
        // just ended elsewhere no longer goes.
        queuedProfilePick = V2QueuedProfilePick()
        guard profile != appState.activeProfile else { return }
        if haptic { Haptics.medium() }
        isPickingProfile = true
        isFadingOutForPick = true
        profileSwitchToken &+= 1
        let token = profileSwitchToken
        let distance = reduceMotion ? 0 : Self.profileSwitchDistance * profileSwitchDirection(to: profile)
        withAnimation(ConduitMotion.fadeOut) {
            contentFaded = true
            contentShift = -distance
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ConduitMotion.fadeOutDuration))
            // Only a newer strip pick moves the token, and it owns
            // isPickingProfile from then on.
            guard token == profileSwitchToken else { return }
            isFadingOutForPick = false
            // Out of sight, content moves to the side it arrives from.
            withTransaction(Transaction(animation: nil)) { contentShift = distance }
            var target = profile
            // A tap in the fade-out is the latest word: back on the profile
            // already showing means no switch at all, another one replaces
            // this target.
            if queuedProfilePick.profile != nil {
                guard let next = queuedProfilePick.take(
                    landedOn: appState.activeProfile,
                    dashboardID: appState.activeDashboardID
                ) else {
                    isPickingProfile = false
                    fadeContentBackIn()
                    return
                }
                target = next
            }
            // A switch started elsewhere (CarPlay) in the fade-out would
            // refuse this one: it waits behind it, unless a later tap
            // already does.
            if appState.isProfileSwitching {
                if queuedProfilePick.profile == nil {
                    queuedProfilePick.tap(target, dashboardID: appState.activeDashboardID)
                }
                isPickingProfile = false
                return
            }
            await appState.switchProfile(to: target)
            guard token == profileSwitchToken else { return }
            isPickingProfile = false
            // A tap kept during this switch goes now, with the content
            // still out of sight.
            if let next = queuedProfilePick.take(
                landedOn: appState.activeProfile,
                dashboardID: appState.activeDashboardID
            ) {
                pickProfile(next, haptic: false)
                // It started its own switch, which brings the content back.
                guard token == profileSwitchToken else { return }
            }
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
/// one column. The user can hide the list on a wide window too
/// (`V2ChatListPreference`).
/// The profile tapped in the strip (or picked in CarPlay's agent list)
/// while a switch is running. Only the last tap counts; once the switch
/// ends, it goes there, unless that's where the switch landed.
struct V2QueuedProfilePick: Equatable {
    private(set) var profile: String?
    /// The dashboard the tap was made on: a profile name means nothing on
    /// another one.
    private(set) var dashboardID: UUID?

    mutating func tap(_ profile: String, dashboardID: UUID?) {
        self.profile = profile
        self.dashboardID = dashboardID
    }

    /// The profile to switch to now that the switch ended on `landed`, on
    /// the dashboard `dashboardID`.
    mutating func take(landedOn landed: String, dashboardID: UUID?) -> String? {
        defer {
            profile = nil
            self.dashboardID = nil
        }
        guard self.dashboardID == dashboardID else { return nil }
        return profile == landed ? nil : profile
    }
}

enum V2SplitLayout {
    /// The list column: the narrowest iPhone's width, which every V2 list
    /// screen already fits.
    static let listWidth: CGFloat = 375
    /// The least room the chat keeps beside the list.
    static let minimumChatWidth: CGFloat = 430

    static func isSplit(width: CGFloat) -> Bool {
        width >= listWidth + 1 + minimumChatWidth
    }

    /// Split, unless the user hid the list: then a wide window keeps one
    /// column, the chat pushed over the list as on a phone.
    static func isSplit(width: CGFloat, showsList: Bool) -> Bool {
        showsList && isSplit(width: width)
    }

    /// Split, with a chat open beside the list that shows its own voice
    /// button by the composer (a group room has none): the list column's
    /// voice buttons step aside for it.
    static func hasChatVoiceBeside(split: Bool, path: [V2Route], inRoom: Bool) -> Bool {
        split && path.contains(.conversation) && !inRoom
    }

    /// The bar sits under the list column only where there is one: Chats
    /// and Bots, split, and Settings beside the Chats list. Tasks, and a
    /// list shown alone, center it under the screen.
    static func tabBarUnderList(split: Bool, tab: V2Tab) -> Bool {
        split && tab != .tasks
    }

    /// Split, Settings opens in the chat's column with the Chats list kept
    /// beside it, rather than alone across the window.
    static func settingsBesideList(split: Bool) -> Bool {
        split
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

    /// Whether the tab's list column shows chat rows: the list, or a
    /// project's page, on top of its stack. Split, a chat beside the column
    /// doesn't cover it; one column, the chat covers whatever is under it.
    static func showsChatRows(split: Bool, path: [V2Route]) -> Bool {
        switch (split ? listRoutes(path) : path).last {
        case nil, .project?: return true
        case .conversation?, .artifacts?: return false
        }
    }

    /// What the list marks as open beside it: a group room takes the
    /// chat's place without changing the open chat, so its row is marked
    /// rather than the chat's.
    static func openBeside(chatBeside: Bool, roomID: String?) -> V2OpenBeside {
        guard chatBeside else { return .nothing }
        return roomID.map(V2OpenBeside.room) ?? .chat
    }

    static func listRoutes(_ path: [V2Route]) -> [V2Route] {
        path.filter { $0 != .conversation }
    }

    static func tabRoutes(listing routes: [V2Route], keepsConversation: Bool) -> [V2Route] {
        let list = listRoutes(routes)
        return keepsConversation ? list + [.conversation] : list
    }
}

/// What a split window's chat column shows, for the list beside it to
/// mark (#1363). The environment holds nil off a split window, where the
/// list never shows beside what it opened.
enum V2OpenBeside: Equatable {
    /// The placeholder, or Settings in the chat's column.
    case nothing
    /// The open chat (`activeSessionId`), a Bot Chat included.
    case chat
    /// A group room, by its id.
    case room(String)
}

private struct V2OpenBesideKey: EnvironmentKey {
    static let defaultValue: V2OpenBeside? = nil
}

extension EnvironmentValues {
    var v2OpenBeside: V2OpenBeside? {
        get { self[V2OpenBesideKey.self] }
        set { self[V2OpenBesideKey.self] = newValue }
    }
}

/// How a list row marks the conversation it opens.
enum V2RowSelection: Equatable {
    case none
    /// One column: the faint shade a phone's Chats row has long kept for
    /// the open chat.
    case faint
    /// Beside the open chat on a split window: picked out at a glance, so
    /// nobody has to match the chat's title to the list (#1363).
    case open

    /// A chat's row. `isActive`: it is the open chat. `faintAlone`: a row
    /// that keeps the faint shade in one column (Chats and project rows;
    /// a bot's row never had one).
    static func chat(isActive: Bool, beside: V2OpenBeside?, faintAlone: Bool = true) -> V2RowSelection {
        guard let beside else { return isActive && faintAlone ? .faint : .none }
        return isActive && beside == .chat ? .open : .none
    }

    /// A group room's row, marked only while the room shows beside it.
    static func room(_ roomID: String, beside: V2OpenBeside?) -> V2RowSelection {
        beside == .room(roomID) ? .open : .none
    }
}

/// The open conversation's row beside the list: a rounded accent tint with
/// a fine accent edge, as the persistent sidebar marks it. A shape behind
/// the row, so it never reads as the gold unread dot or the Running
/// spinner on it.
struct V2OpenRowHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.conduitAccent.opacity(0.13))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.conduitAccent.opacity(0.32), lineWidth: 1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A list row's background for its selection. The row adds VoiceOver's
    /// Selected to its own element (`v2SelectedTrait`).
    func v2RowSelection(_ selection: V2RowSelection) -> some View {
        background {
            switch selection {
            case .open: V2OpenRowHighlight()
            case .faint: Color.primary.opacity(0.05)
            case .none: EmptyView()
            }
        }
    }

    /// Selected, for VoiceOver, on the open conversation's row beside the
    /// list. After the row's own accessibility element.
    func v2SelectedTrait(_ selection: V2RowSelection) -> some View {
        accessibilityAddTraits(selection == .open ? .isSelected : [])
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
                    .foregroundStyle(.conduitTertiary)
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
/// change that stayed on this iPhone and what Hermes said, a widget action
/// that couldn't finish, or a tap a call kept from switching (over the
/// call's screen too, RootView). It goes away after a few seconds, or on a
/// tap.
struct V2NoticeBanner: View {
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

/// Whether a wide window shows the Chats or Bots list beside the open chat
/// (#1164). Off, the chat takes the whole window, as on a phone. Kept on
/// this device only: it depends on the screen, so it isn't synced.
enum V2ChatListPreference {
    static let key = "conduit.v2.chatListBeside"
    static let defaultValue = true
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

/// Before iOS 26, and on a Mac, the capsule bar carries the fading
/// material the lists scroll under, reaching a little above the bar.
/// iOS 26 draws a soft edge under the bar's clearance instead.
private struct V2LegacyTabBarEdge: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), V2SystemScrollEdge.isUsed {
            content
        } else {
            content.background { V2ScrollEdgeBackground(edge: .bottom).padding(.top, -14) }
        }
    }
}
