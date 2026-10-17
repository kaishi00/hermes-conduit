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
/// Equal when the values are: the shell rebuilds `pickProfile` on every
/// render, and a closure never compares equal, so without this every
/// AppState publish would redraw every view that reads the context, the
/// hidden tabs included. Every copy of the closure does the same thing.
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
    }

    var pickProfile: (String) -> Void = { _ in }
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
    /// The last selected tab. Set after the switch, so the transition of a
    /// first visit reads the tab it left and slides in from that side.
    @State private var lastTab: V2Tab = .chats
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

    /// Whether a screen is pushed over the tab's root.
    private func isRootCovered(_ tab: V2Tab) -> Bool {
        switch tab {
        case .chats: return !chatsPath.isEmpty
        case .bots: return !botsPath.isEmpty
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
            .environment(\.v2Shell, V2ShellContext(pickProfile: pickProfile, values: .init(contentFaded: contentFaded, contentShift: contentShift)))
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
                lastTab = tab
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

    private static let tabSlideDistance: CGFloat = 28

    /// Where `tab` waits while `shown` is on screen: a little toward its
    /// side of the bar (right of `shown` waits right), so opening it slides
    /// it in from there. Zero for the shown tab and under Reduce Motion.
    private func tabSlideOffset(_ tab: V2Tab, from shown: V2Tab) -> CGFloat {
        guard !reduceMotion,
              let index = V2Tab.destinations.firstIndex(of: tab),
              let shownIndex = V2Tab.destinations.firstIndex(of: shown),
              index != shownIndex else { return 0 }
        // The bar mirrors right to left; the offset doesn't.
        let later: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
        return (index > shownIndex ? later : -later) * Self.tabSlideDistance
    }

    /// The four tabs over a custom glass capsule, the gold voice button
    /// beside it, on every iOS version. iOS 26's own tab bar has no place
    /// for a separate circle: a search-role tab sat inside the bar as a
    /// second Voice item under the button.
    private var tabs: some View {
        ZStack {
            ForEach(V2Tab.destinations) { tab in
                // The selected tab shows from the tap's own frame; it joins
                // the visited ones right after.
                if visitedTabs.contains(tab) || selectedTab == tab {
                    let isSelected = selectedTab == tab
                    let rootCovered = isRootCovered(tab)
                    tabRoot(tab)
                        .transformEnvironment(\.v2Shell) {
                            $0.isTabActive = isSelected
                            $0.isRootCovered = rootCovered
                        }
                        // Nothing inside a tab animates with the switch.
                        .animation(nil, value: selectedTab)
                        // Only the tab being opened moves: it slides the last
                        // few points in from its side of the bar as it fades
                        // in; the one left goes at once. Fading two full
                        // screens of glass and backdrop into each other
                        // dropped frames, and a plain swap read as a blink.
                        // A hidden tab waits off center on its own side, so
                        // the slide needs no start state. Scoped to offset
                        // and opacity.
                        .animation(isSelected ? ConduitMotion.tabSlideIn : nil) {
                            $0.offset(x: tabSlideOffset(tab, from: selectedTab))
                        }
                        .animation(isSelected ? ConduitMotion.tabFadeIn : nil) {
                            $0.opacity(isSelected ? 1 : 0)
                        }
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                        // A tab's first visit inserts it already selected:
                        // the same slide and fade from the tab it left, each
                        // on its own timing (no slide under Reduce Motion).
                        .transition(
                            AnyTransition.offset(x: tabSlideOffset(tab, from: lastTab))
                                .animation(ConduitMotion.tabSlideIn)
                                .combined(with: AnyTransition.opacity.animation(ConduitMotion.tabFadeIn))
                        )
                }
            }
        }
        // The bar floats over the screens instead of insetting them: hiding
        // it for a pushed chat then moves only the bar, not the layout of the
        // chat being pushed. Screens that show it keep a fixed clearance
        // (`tabBarClearance`).
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                if !conversationVisible {
                    HStack(spacing: 10) {
                        V2CapsuleTabBar(selection: $selectedTab)
                        voiceButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
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
    private func tabRoot(_ tab: V2Tab) -> some View {
        switch tab {
        case .chats:
            NavigationStack(path: $chatsPath) {
                tabBarClearance(V2ChatsView())
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
