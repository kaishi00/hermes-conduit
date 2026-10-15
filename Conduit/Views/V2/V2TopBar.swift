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
        .background { V2ScrollEdgeBackground() }
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

/// The soft edge content scrolls under: a material that fades out
/// downward, so the bar reads without a hard line.
struct V2ScrollEdgeBackground: View {
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
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .top)
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

    private let pictureSize: CGFloat = 34

    private var profiles: [String] {
        appState.profiles.isEmpty ? [appState.activeProfile] : appState.profiles
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(profiles, id: \.self) { profile in
                        chip(profile)
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

    @ViewBuilder
    private func chip(_ profile: String) -> some View {
        let name = appState.profileDisplayName(profile)
        if profile == appState.activeProfile {
            Button(action: onManage) {
                HStack(spacing: 7) {
                    picture(profile, name: name)
                        .overlay {
                            Circle().strokeBorder(Color.conduitAccent, lineWidth: 1.5)
                        }
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .leading)))
                }
                .padding(.leading, 3)
                .padding(.trailing, 12)
                .padding(.vertical, 3)
                .conduitGlassControl(cornerRadius: 20, interactive: false)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("sidebar.workspace")
            .accessibilityLabel(AppLocalization.string("\(name) profile"))
            .accessibilityHint(AppLocalization.string("Manage profiles"))
            .accessibilityAddTraits(.isSelected)
        } else {
            let unread = appState.profileHasUnread(profile)
            Button {
                shell.pickProfile(profile)
            } label: {
                picture(profile, name: name)
                    .opacity(0.62)
                    .overlay(alignment: .topTrailing) {
                        if unread {
                            Circle()
                                .fill(Color.conduitAccent)
                                .frame(width: 9, height: 9)
                                .overlay { Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1) }
                                .offset(x: 1, y: -1)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(appState.isProfileSwitching)
            .accessibilityLabel(AppLocalization.string("\(name) profile"))
            .accessibilityValue(unread ? AppLocalization.string("Unread") : "")
            .accessibilityHint(AppLocalization.string("Switches to this profile"))
        }
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

    var body: some View {
        // A capsule tab hidden behind the selected one holds still.
        ConduitBackdrop(drifts: drifts && shell.isTabActive, glowTint: appState.profileGlowTint(appState.activeProfile))
    }
}

/// A sliding two-way glass segmented control (Tasks: Board | Scheduled).
struct V2SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    withAnimation(ConduitMotion.overshoot(reduceMotion: reduceMotion)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.primary.opacity(0.10))
                                    .matchedGeometryEffect(id: "segment", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .conduitGlassControl(cornerRadius: 21, interactive: false)
        .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
    }
}
