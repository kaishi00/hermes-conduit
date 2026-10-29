//
//  V2TopBar.swift
//  Conduit
//
//  The V2 top bar (Chats, Tasks, Settings): the profile picker as a row of
//  profile pictures, and an optional trailing capsule of controls. When the
//  profiles don't fit beside the controls, they get a full-width row of
//  their own and the controls move under it. No large title; the bar floats
//  over a soft blurred scroll edge.
//

import SwiftUI
import UIKit

struct V2TopBar<Trailing: View, LowerLeading: View>: View {
    @EnvironmentObject private var appState: AppState
    @State private var showProfileManager = false
    @State private var showAllProfilesChooser = false
    /// The controls; `true` when they sit on the second row, under the
    /// profiles.
    private let trailing: (Bool) -> Trailing
    /// Leads the second row when the bar stacks (Chats: the filter pill).
    private let lowerLeading: LowerLeading
    private var drawsScrollEdge = true
    /// Chats: an All chip leads the profiles, for every profile's chats in
    /// one list.
    private var leadsWithAllChip = false

    init(@ViewBuilder lowerLeading: () -> LowerLeading,
         @ViewBuilder trailing: @escaping (_ stacked: Bool) -> Trailing) {
        self.lowerLeading = lowerLeading()
        self.trailing = trailing
    }

    var body: some View {
        // Read once: it walks the catalog, and the bar measures both its
        // layouts.
        let unread = V2ProfileStrip.unreadProfiles(appState)
        Group {
            if Trailing.self == EmptyView.self {
                strip(scrolls: true, unread: unread)
            } else {
                // One row while every profile fits beside the controls
                // (one or two, usually); otherwise the profiles get the
                // whole width, where a cut-off one shows that they scroll.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        strip(scrolls: false, unread: unread)
                        Spacer(minLength: 0)
                        trailing(false)
                    }
                    VStack(spacing: 6) {
                        strip(scrolls: true, unread: unread)
                        HStack(spacing: 10) {
                            lowerLeading
                            Spacer(minLength: 0)
                            trailing(true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(minHeight: 52)
        .background {
            if drawsScrollEdge { V2ScrollEdgeBackground() }
        }
        .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
        .sheet(isPresented: $showProfileManager) {
            ProfilePickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showAllProfilesChooser) {
            V2AllProfilesSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environmentObject(appState)
        }
    }

    private func strip(scrolls: Bool, unread: Set<String>) -> some View {
        V2ProfileStrip(
            scrolls: scrolls,
            unread: unread,
            showsAllChip: leadsWithAllChip && AllProfilesChats.isAvailable(profiles: appState.profiles),
            onManage: { showProfileManager = true },
            onChooseAll: { showAllProfilesChooser = true }
        )
    }
}

extension V2TopBar where LowerLeading == EmptyView {
    init(@ViewBuilder trailing: @escaping (_ stacked: Bool) -> Trailing) {
        self.init(lowerLeading: { EmptyView() }, trailing: trailing)
    }
}

extension V2TopBar where Trailing == EmptyView, LowerLeading == EmptyView {
    init() {
        self.init(lowerLeading: { EmptyView() }, trailing: { _ in EmptyView() })
    }
}

extension V2TopBar {
    /// For a header that stacks more controls under the bar and draws one
    /// soft edge behind all of them (Tasks).
    func withoutScrollEdge() -> Self {
        var bar = self
        bar.drawsScrollEdge = false
        return bar
    }

    /// The Chats bar: an All chip before the profiles.
    func withAllProfilesChip() -> Self {
        var bar = self
        bar.leadsWithAllChip = true
        return bar
    }
}

extension View {
    /// Pins `bar` to a screen edge, with this view's lists scrolling under
    /// it and fading out beneath it. On iOS 26 it is a `safeAreaBar`, so the
    /// lists draw the system's soft scroll edge under it; before, and on a
    /// Mac, it is a `safeAreaInset`, and the bar draws
    /// `V2ScrollEdgeBackground` itself (`V2LegacyScrollEdge`).
    @ViewBuilder
    func v2EdgeBar<Bar: View>(_ edge: VerticalEdge, @ViewBuilder bar: () -> Bar) -> some View {
        let content = bar()
        if #available(iOS 26.0, *), V2SystemScrollEdge.isUsed {
            scrollEdgeEffectStyle(.soft, for: edge == .top ? .top : .bottom)
                .safeAreaBar(edge: edge, spacing: 0) { content }
        } else {
            safeAreaInset(edge: edge, spacing: 0) { content }
        }
    }
}

/// Whether bars use the system's scroll edge (iOS 26's `safeAreaBar`).
/// Not when the iPad app runs on a Mac (`isiOSAppOnMac`; Conduit ships no
/// Catalyst build): there, at some window sizes, a chat's composer bar drew
/// a hard edge well above the composer and hid the transcript under it
/// (#1357), so bars keep Conduit's own inset and fade.
enum V2SystemScrollEdge {
    static let isUsed = !ProcessInfo.processInfo.isiOSAppOnMac
}

/// Before iOS 26, and on a Mac, the fading material behind a bar that
/// lists scroll under. iOS 26 draws its own soft edge there (`v2EdgeBar`),
/// which costs less than our blur under a gradient mask on every scroll
/// frame.
struct V2LegacyScrollEdge: ViewModifier {
    var edge: VerticalEdge = .top

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), V2SystemScrollEdge.isUsed {
            content
        } else {
            content.background { V2ScrollEdgeBackground(edge: edge) }
        }
    }
}

/// The soft edge content scrolls under: a material that fades out away
/// from the screen edge, so the bar reads without a hard line. It runs the
/// screen's whole width, past a readable column's margins: kept to a wide
/// window's chat column, it drew a lighter box around the composer on a
/// Mac.
struct V2ScrollEdgeBackground: View {
    /// The screen edge the bar sits on.
    var edge: VerticalEdge = .top

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.85), location: 0.55),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: edge == .top ? .top : .bottom,
                    endPoint: edge == .top ? .bottom : .top
                )
            }
            .ignoresSafeArea(edges: [edge == .top ? .top : .bottom, .horizontal])
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Profile pictures in a row. The selected one sits in a glass capsule with
/// its name; the others are dimmed, with a gold dot when that profile has
/// unread conversations. Tapping the selected one opens the profile manager
/// (photos, order); tapping another switches to it.
///
/// A scrolling strip runs past the bar's side padding to the screen edges
/// and fades out there, so a profile cut off at the edge reads as "more
/// this way". A fixed one (the Chats bar's single row) is as wide as its
/// widest selection, so switching profiles never moves the bar between one
/// row and two.
struct V2ProfileStrip: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let scrolls: Bool
    /// Profiles other than the selected one with unread chats
    /// (`unreadProfiles`).
    let unread: Set<String>
    /// The All chip first (Chats, with two or more profiles).
    var showsAllChip = false
    let onManage: () -> Void
    /// A tap on the selected All chip: which profiles it shows.
    var onChooseAll: () -> Void = {}

    @Namespace private var selection

    /// The All chip's scroll id; no profile is named this.
    private static let allChipID = "\u{1F}all"

    /// All is on and its chip is the selected one.
    private var allSelected: Bool {
        showsAllChip && appState.isAllProfilesChatsOn
    }

    private let pictureSize: CGFloat = 34
    /// The bar's side padding, which the scrolling strip runs into.
    private let edgeBleed: CGFloat = 16

    private var profiles: [String] {
        Self.profiles(appState)
    }

    private static func profiles(_ appState: AppState) -> [String] {
        appState.profiles.isEmpty ? [appState.activeProfile] : appState.profiles
    }

    /// The profiles that get a gold dot. The selected chip never shows one.
    /// Exact match, as the chip's own `isSelected`.
    static func unreadProfiles(_ appState: AppState) -> Set<String> {
        appState.profilesWithUnread(among: profiles(appState).filter { $0 != appState.activeProfile })
    }

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    chips
                        .padding(.horizontal, edgeBleed)
                }
                .scrollClipDisabled()
                // Too few to fill the row: they start at the leading edge
                // instead of centering.
                .defaultScrollAnchor(.leading)
                .mask { edgeFade }
                .padding(.horizontal, -edgeBleed)
                // A new strip (launch, or the bar turning to two rows)
                // starts at the first profile; bring the selected one in.
                // After the first layout pass, or the scroll does nothing.
                .onAppear {
                    Task { @MainActor in proxy.scrollTo(appState.activeProfile, anchor: .center) }
                }
                .onChange(of: appState.activeProfile) { _, profile in
                    withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
                        proxy.scrollTo(profile, anchor: .center)
                    }
                }
            }
        } else {
            chips
                .padding(.trailing, widestNameSlack)
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            if showsAllChip {
                allChip
                    .id(Self.allChipID)
            }
            ForEach(profiles, id: \.self) { profile in
                chip(profile, unread: unread.contains(profile))
                    .id(profile)
            }
        }
        .padding(.vertical, 2)
        .animation(ConduitMotion.overshoot(reduceMotion: reduceMotion), value: appState.activeProfile)
        .animation(ConduitMotion.overshoot(reduceMotion: reduceMotion), value: allSelected)
    }

    /// Opaque except the outer `edgeBleed`, which fades to clear. Taller
    /// than the strip so the glass capsule's edge and the unread dots
    /// aren't clipped.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: edgeBleed)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: edgeBleed)
        }
        .padding(.vertical, -8)
    }

    /// How much wider the selected chip would be with the longest name, so
    /// the fixed row measures the same whichever profile is selected. A
    /// little over, since UIKit's metrics can trail SwiftUI's text by a
    /// point or two.
    private var widestNameSlack: CGFloat {
        let names = profiles.map { appState.profileDisplayName($0) } + (showsAllChip ? [Self.allTitle] : [])
        let widest = names.map(nameWidth).max() ?? 0
        let selected = allSelected ? Self.allTitle : appState.profileDisplayName(appState.activeProfile)
        return max(0, widest - nameWidth(selected)) + 4
    }

    private static var allTitle: String { AppLocalization.string("All") }

    /// The selected chip's name width: subheadline semibold at the bar's
    /// text size.
    private func nameWidth(_ name: String) -> CGFloat {
        let category = UIContentSizeCategory(min(dynamicTypeSize, .pinnedChromeCap))
        let size = UIFont.preferredFont(
            forTextStyle: .subheadline,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        ).pointSize
        let font = UIFont.systemFont(ofSize: size, weight: .semibold)
        return ceil((name as NSString).size(withAttributes: [.font: font]).width)
    }

    /// One view per profile whichever is selected, so a switch moves the
    /// glass capsule and the name across instead of swapping two different
    /// buttons (which also reloaded both pictures).
    private func chip(_ profile: String, unread: Bool) -> some View {
        let name = appState.profileDisplayName(profile)
        let isSelected = !allSelected && profile == appState.activeProfile
        return Button {
            // While a switch runs, every chip is a pick the shell keeps for
            // when it ends (`V2QueuedProfilePick`), the one on screen too.
            let switching = appState.isProfileSwitching || shell.isPickingProfile
            if isSelected, !switching {
                onManage()
            } else if allSelected, profile == appState.activeProfile, !switching {
                // Back to this profile's own list: nothing to switch.
                Haptics.selection()
                appState.setAllProfilesChatsOn(false)
            } else {
                if allSelected { appState.setAllProfilesChatsOn(false) }
                shell.pickProfile(profile)
            }
        } label: {
            HStack(spacing: 7) {
                picture(profile, name: name)
                    .opacity(isSelected ? 1 : 0.62)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.conduitAccent, lineWidth: 1.5)
                            .opacity(isSelected ? 1 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        if unread {
                            Circle()
                                .fill(Color.conduitAccent)
                                .frame(width: 9, height: 9)
                                .overlay { Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1) }
                                .offset(x: 1, y: -1)
                                .transition(.opacity)
                        }
                    }
                if isSelected {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .leading)))
                }
            }
            .padding(.leading, 3)
            .padding(.trailing, isSelected ? 12 : 3)
            .padding(.vertical, 3)
            .background {
                if isSelected {
                    Color.clear
                        .conduitGlassControl(cornerRadius: 20, interactive: false)
                        .matchedGeometryEffect(id: "selectedProfile", in: selection)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        // Tappable while a switch runs: the shell keeps the tap for when
        // it ends (`V2QueuedProfilePick`).
        .buttonStyle(PressableButtonStyle())
        .modifier(DashboardSwitchMenu(enabled: profile == appState.activeProfile))
        .accessibilityIdentifier(isSelected ? "sidebar.workspace" : "v2.profile.\(profile)")
        .accessibilityLabel(AppLocalization.string("\(name) profile"))
        .accessibilityValue(unread ? AppLocalization.string("Unread") : "")
        .accessibilityHint(isSelected && !(appState.isProfileSwitching || shell.isPickingProfile) ? AppLocalization.string("Manage profiles") : AppLocalization.string("Switches to this profile"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// All: up to three of its profiles' pictures, overlapping, and its
    /// name while selected. It shares the glass capsule with the profile
    /// chips, so choosing it slides the capsule over.
    private var allChip: some View {
        let isSelected = allSelected
        let shown = Array(appState.allProfilesIncluded.prefix(3))
        return Button {
            Haptics.selection()
            // The last tap wins: a profile kept for after a running switch
            // no longer goes.
            shell.dropQueuedProfilePick()
            if isSelected {
                onChooseAll()
            } else {
                appState.setAllProfilesChatsOn(true)
            }
        } label: {
            HStack(spacing: 7) {
                ZStack(alignment: .leading) {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, profile in
                        ProfileAvatarView(
                            profile: profile,
                            displayName: appState.profileDisplayName(profile),
                            url: appState.profileAvatarURL(for: profile),
                            size: 22
                        )
                        .offset(x: CGFloat(index) * 6)
                        .zIndex(Double(shown.count - index))
                    }
                }
                .frame(width: pictureSize, height: pictureSize, alignment: .leading)
                .opacity(isSelected ? 1 : 0.62)
                if isSelected {
                    Text(Self.allTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .leading)))
                }
            }
            .padding(.leading, 3)
            .padding(.trailing, isSelected ? 12 : 3)
            .padding(.vertical, 3)
            .background {
                if isSelected {
                    Color.clear
                        .conduitGlassControl(cornerRadius: 20, interactive: false)
                        .matchedGeometryEffect(id: "selectedProfile", in: selection)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier("v2.profile.all")
        .accessibilityLabel(AppLocalization.string("All profiles"))
        .accessibilityHint(isSelected
            ? AppLocalization.string("Chooses which profiles All shows")
            : AppLocalization.string("Shows the chats of several profiles in one list"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func picture(_ profile: String, name: String) -> some View {
        ProfileAvatarView(
            profile: profile,
            displayName: name,
            url: appState.profileAvatarURL(for: profile),
            size: pictureSize
        )
    }
}

/// Long-pressing the active profile's chip (selected, or under All) lists
/// the other saved dashboards, for moving to another Hermes without
/// opening Settings (#288 in the notifier repo). Only with two or more
/// saved; the Profiles sheet lists them too.
private struct DashboardSwitchMenu: ViewModifier {
    @EnvironmentObject private var appState: AppState
    let enabled: Bool

    func body(content: Content) -> some View {
        // Always attached, with the items gated: switching the modifier on
        // and off would rebuild the chip as it becomes (or stops being) the
        // selected one, under its matched-geometry capsule. An empty menu
        // doesn't open.
        content.contextMenu {
            let others = appState.savedDashboardRegistry.dashboards.filter { $0.id != appState.activeDashboardID }
            if enabled && !others.isEmpty {
                Section(AppLocalization.string("Saved Dashboards")) {
                    ForEach(others) { dashboard in
                        Button {
                            Haptics.medium()
                            Task { await appState.switchDashboard(to: dashboard.id) }
                        } label: {
                            Label {
                                Text(verbatim: dashboard.label)
                            } icon: {
                                Image(systemName: "server.rack")
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One glass capsule holding a row of icon buttons (the Chats top bar's
/// view toggle, filter and new chat).
struct V2ControlCapsule<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 2)
        .conduitGlassControl(cornerRadius: 22, interactive: false)
    }
}

/// An icon inside `V2ControlCapsule`: a 36 pt glyph in a 44 pt target.
struct V2CapsuleIcon: View {
    let systemImage: String
    var dot: Color? = nil
    /// The control's on state (Projects showing): the glyph turns gold.
    var tint: Color? = nil

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .conduitFixedGlyph()
            .foregroundStyle(tint ?? Color.primary)
            .frame(width: 36, height: 36)
            .overlay(alignment: .topTrailing) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 8, height: 8)
                        .offset(x: -5, y: 6)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// The root screens' backdrop: drifting while its tab is on screen, its warm
/// glow in the active profile's color, or in `glowProfile`'s when given.
struct V2Backdrop: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    var drifts = true
    /// A tab root's backdrop (Chats, Bots): it also holds still while a chat
    /// or page is pushed over the root, which draws its own.
    var isTabRoot = false
    /// The profile whose color the glow takes instead of the active one: the
    /// open chat's, so a Bot Chat glows in its bot's color.
    var glowProfile: String?

    var body: some View {
        // A capsule tab hidden behind the selected one holds still.
        let covered = isTabRoot && shell.isRootCovered
        ConduitBackdrop(
            drifts: drifts && shell.isTabActive && !covered,
            glowTint: appState.profileGlowTint(glowProfile ?? appState.activeProfile)
        )
    }
}

/// A sliding two-way glass segmented control (Tasks: Board | Scheduled).
///
/// The highlight is one capsule that slides to the selected segment, keyed
/// on the selection itself rather than on the tap's transaction, so it moves
/// even when the selection is stored somewhere that drops the transaction
/// (an `@AppStorage` write does).
struct V2SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private let spacing: CGFloat = 2

    private var selectedIndex: Int? {
        options.firstIndex { $0.value == selection }
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = index == selectedIndex
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .background(alignment: .leading) {
            GeometryReader { proxy in
                let count = CGFloat(max(options.count, 1))
                let width = (proxy.size.width - spacing * (count - 1)) / count
                // An offset doesn't mirror on its own: right to left, the
                // first segment is the rightmost.
                let step = layoutDirection == .rightToLeft ? -(width + spacing) : width + spacing
                if let selectedIndex {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: width)
                        .offset(x: CGFloat(selectedIndex) * step)
                }
            }
        }
        .animation(ConduitMotion.overshoot(reduceMotion: reduceMotion), value: selectedIndex)
        .padding(3)
        .conduitGlassControl(cornerRadius: 21, interactive: false)
        .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
    }
}
