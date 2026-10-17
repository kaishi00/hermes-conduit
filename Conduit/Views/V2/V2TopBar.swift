//
//  V2TopBar.swift
//  Conduit
//
//  The V2 top bar (Chats, Tasks, Settings): the profile picker as a row of
//  profile pictures, and an optional trailing capsule of controls. No large
//  title; the bar floats over a soft blurred scroll edge.
//

import SwiftUI

struct V2TopBar<Trailing: View>: View {
    @EnvironmentObject private var appState: AppState
    @State private var showProfileManager = false
    private let trailing: Trailing
    private var drawsScrollEdge = true

    init(@ViewBuilder trailing: () -> Trailing) {
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            V2ProfileStrip(onManage: { showProfileManager = true })
            trailing
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
    }
}

extension V2TopBar where Trailing == EmptyView {
    init() {
        self.init { EmptyView() }
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
}

extension View {
    /// Pins `bar` to a screen edge, with this view's lists scrolling under
    /// it and fading out beneath it. On iOS 26 it is a `safeAreaBar`, so the
    /// lists draw the system's soft scroll edge under it; before, it is a
    /// `safeAreaInset`, and the bar draws `V2ScrollEdgeBackground` itself
    /// (`V2LegacyScrollEdge`).
    @ViewBuilder
    func v2EdgeBar<Bar: View>(_ edge: VerticalEdge, @ViewBuilder bar: () -> Bar) -> some View {
        let content = bar()
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edge == .top ? .top : .bottom)
                .safeAreaBar(edge: edge, spacing: 0) { content }
        } else {
            safeAreaInset(edge: edge, spacing: 0) { content }
        }
    }
}

/// Before iOS 26, the fading material behind a bar that lists scroll
/// under. iOS 26 draws its own soft edge there (`v2EdgeBar`), which
/// costs less than our blur under a gradient mask on every scroll frame.
struct V2LegacyScrollEdge: ViewModifier {
    var edge: VerticalEdge = .top

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.background { V2ScrollEdgeBackground(edge: edge) }
        }
    }
}

/// The soft edge content scrolls under: a material that fades out away
/// from the screen edge, so the bar reads without a hard line.
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
            .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Profile pictures in a horizontal scroll. The selected one sits in a glass
/// capsule with its name; the others are dimmed, with a gold dot when that
/// profile has unread conversations. Tapping the selected one opens the
/// profile manager (photos, order); tapping another switches to it.
struct V2ProfileStrip: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onManage: () -> Void

    @Namespace private var selection

    private let pictureSize: CGFloat = 34

    private var profiles: [String] {
        appState.profiles.isEmpty ? [appState.activeProfile] : appState.profiles
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // The selected chip never shows a dot. Exact match, as
                    // the chip's own `isSelected`.
                    let unread = appState.profilesWithUnread(among: profiles.filter { $0 != appState.activeProfile })
                    ForEach(profiles, id: \.self) { profile in
                        chip(profile, unread: unread.contains(profile))
                            .id(profile)
                    }
                }
                .padding(.vertical, 2)
                .animation(ConduitMotion.overshoot(reduceMotion: reduceMotion), value: appState.activeProfile)
            }
            .scrollClipDisabled()
            .onChange(of: appState.activeProfile) { _, profile in
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(profile, anchor: .center)
                }
            }
        }
    }

    /// One view per profile whichever is selected, so a switch moves the
    /// glass capsule and the name across instead of swapping two different
    /// buttons (which also reloaded both pictures).
    private func chip(_ profile: String, unread: Bool) -> some View {
        let name = appState.profileDisplayName(profile)
        let isSelected = profile == appState.activeProfile
        return Button {
            if isSelected {
                onManage()
            } else {
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
        .buttonStyle(PressableButtonStyle())
        .disabled(!isSelected && appState.isProfileSwitching)
        .accessibilityIdentifier(isSelected ? "sidebar.workspace" : "v2.profile.\(profile)")
        .accessibilityLabel(AppLocalization.string("\(name) profile"))
        .accessibilityValue(unread ? AppLocalization.string("Unread") : "")
        .accessibilityHint(isSelected ? AppLocalization.string("Manage profiles") : AppLocalization.string("Switches to this profile"))
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
/// glow in the active profile's color.
struct V2Backdrop: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    var drifts = true
    /// A tab root's backdrop (Chats, Bots): it also holds still while a chat
    /// or page is pushed over the root, which draws its own.
    var isTabRoot = false

    var body: some View {
        // A capsule tab hidden behind the selected one holds still.
        let covered = isTabRoot && shell.isRootCovered
        ConduitBackdrop(
            drifts: drifts && shell.isTabActive && !covered,
            glowTint: appState.profileGlowTint(appState.activeProfile)
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

    private var selectedIndex: Int {
        options.firstIndex { $0.value == selection } ?? 0
    }

    var body: some View {
        HStack(spacing: 2) {
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
                let width = (proxy.size.width - 2 * (count - 1)) / count
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: width)
                    .offset(x: CGFloat(selectedIndex) * (width + 2))
            }
        }
        .animation(ConduitMotion.overshoot(reduceMotion: reduceMotion), value: selectedIndex)
        .padding(3)
        .conduitGlassControl(cornerRadius: 21, interactive: false)
        .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
    }
}
