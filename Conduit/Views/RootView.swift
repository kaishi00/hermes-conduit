//
//  RootView.swift
//  Conduit
//
//  Root container — handles auth state and scene phase changes.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if appState.showLogin || appState.connection == nil {
                LoginView()
                    .transition(.opacity)
            } else {
                MainView()
                    .transition(.opacity)
            }

            if let bridge = appState.dashboardTicketBridge {
                DashboardTicketBridgeView(bridge: bridge)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.showLogin)
        .onChange(of: scenePhase) { _, newPhase in
            appState.handleScenePhase(newPhase)
        }
    }
}

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("conduit.ipadPersistentSidebar") private var prefersPersistentSidebar = false
    @State private var availableWindowWidth: CGFloat = 0
    @State private var settingsPresentation: SettingsSnapshot?
    @State private var shouldPresentSettingsAfterSidebarDismissal = false

    private var sidebarPresentation: SidebarPresentation {
        SidebarLayoutPolicy.resolvePresentation(
            idiom: UIDevice.current.userInterfaceIdiom,
            prefersPersistentSidebar: prefersPersistentSidebar,
            availableWidth: availableWindowWidth
        )
    }

    private var isPersistentSidebarActive: Bool { sidebarPresentation == .persistent }

    var body: some View {
        sidebarLayoutContent
        .sheet(isPresented: $appState.showModelPicker) {
            ModelPickerView()
                .presentationDetents([.medium, .large])
                .presentationBackground(.clear)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showContextSheet) {
            ContextSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showWorkspaceSheet) {
            WorkspaceBrowserSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showGatewaySheet) {
            GatewayDiagnosticsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showAgentsSheet) {
            DelegateAgentsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showVoiceSheet, onDismiss: appState.closeVoiceConversation) {
            VoiceConversationSheet(
                controller: appState.voiceConversationController,
                profile: appState.activeProfile,
                onClose: appState.closeVoiceConversation
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $settingsPresentation, onDismiss: {
            appState.isSettingsSheetPresented = false
            Task { await appState.refreshVoiceCapabilities() }
        }) { snapshot in
            SettingsView(
                snapshot: snapshot,
                saveTheme: { appState.themePreference = $0 },
                persistBusyInputMode: { mode in await appState.setBusyInputMode(mode) },
                persistChatResumeBehavior: { appState.setChatResumeBehavior($0) },
                persistChatReturnSurface: { appState.setChatReturnSurface($0) },
                loadProfileSettings: { keys in await appState.loadProfileSettings(keys: keys) },
                persistProfileSetting: { key, value in await appState.setProfileSetting(key, value: value) },
                loadProfileConfigOptions: { await appState.loadProfileConfigOptions() },
                loadProfileModelDefaults: { await appState.loadProfileModelDefaults() },
                persistProfileMainModel: { provider, model, reasoning in
                    await appState.setProfileMainModel(provider: provider, model: model, reasoning: reasoning)
                },
                saveDefaultProfileName: { appState.saveDefaultProfileName($0) },
                reconnect: {
                    await appState.reconnect()
                    return appState.isConnected
                },
                disconnect: { appState.disconnect() }
            )
                .presentationDetents([.large])
        }
        .background(windowWidthReader)
        .onPreferenceChange(MainViewWindowWidthKey.self) { availableWindowWidth = $0 }
        .onChange(of: isPersistentSidebarActive) { _, persistentActive in
            // Hard invariant: the persistent layout must never coexist with
            // showSidebar == true — that flag suppresses streaming/reasoning
            // publication. A resize, rotation, or the Appearance toggle can
            // activate the persistent layout while the drawer is presented.
            if persistentActive { appState.dismissSidebarDrawer() }
        }
        .task(id: voiceCapabilityRefreshKey) {
            await appState.refreshVoiceCapabilities()
        }
        // Cold launch: MainView first becoming the authenticated surface is
        // the qualifying return. The hook fires once per process (re-login
        // cycles rely on the scene-phase path instead), then any pending
        // request — including one from scene activation — is consumed.
        .task {
            appState.requestPreferredReturnSurfaceForColdLaunch()
            presentPreferredReturnSurfaceIfNeeded()
        }
        .onChange(of: appState.preferredReturnSurfaceRequest) { _, _ in
            presentPreferredReturnSurfaceIfNeeded()
        }
    }

    /// Routes the sidebar between its two presentations: the existing chat
    /// shell with the modal drawer, or — on wide iPad windows with the
    /// Appearance opt-in — the same SidebarView as a persistent leading
    /// column beside the chat.
    @ViewBuilder
    private var sidebarLayoutContent: some View {
        if isPersistentSidebarActive {
            HStack(spacing: 0) {
                SidebarView(
                    onRequestSettings: presentSettingsFromPersistentSidebar,
                    presentation: .persistent
                )
                .frame(width: SidebarLayoutMetrics.persistentSidebarWidth)

                Divider()
                    .ignoresSafeArea(.container, edges: .vertical)

                chatNavigationContent
            }
        } else {
            chatNavigationContent
        }
    }

    /// The existing chat shell, shared by both sidebar layouts so the drawer
    /// and the persistent column render the identical conversation surface.
    /// Only the drawer affordances (hamburger and left-edge swipe) hide while
    /// the persistent sidebar is visible.
    private var chatNavigationContent: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ChatView()
            }
            .overlay(alignment: .leading) {
                if !isPersistentSidebarActive {
                    EdgePanGesture { appState.showSidebar = true }
                        .frame(width: 25)
                        .ignoresSafeArea()
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !isPersistentSidebarActive {
                        Button {
                            appState.showSidebar = true
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 40, height: 40)
                        }
                        .conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.10))
                        .accessibilityLabel("Open sessions")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Button {
                        appState.requestChatScrollToTop()
                    } label: {
                        Text(appState.activeSessionTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .conduitGlassSurface(cornerRadius: 16, tint: .conduitAccent.opacity(0.06))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(appState.activeSessionTitle)
                    .accessibilityHint("Scroll to top of conversation")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await appState.refreshActiveSession() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .rotationEffect(.degrees(appState.isChatRefreshing ? 360 : 0))
                            .animation(
                                appState.isChatRefreshing
                                    ? .linear(duration: 0.75).repeatForever(autoreverses: false)
                                    : .default,
                                value: appState.isChatRefreshing
                            )
                            .frame(width: 40, height: 40)
                    }
                    .conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.10))
                    .disabled(!appState.isConnected || appState.isChatRefreshing)
                    .accessibilityLabel("Refresh conversation")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionStatusIndicator()
                }
            }
        }
        .sheet(isPresented: $appState.showSidebar, onDismiss: presentSettingsAfterSidebarDismissal) {
            SidebarView(onRequestSettings: presentSettingsFromDrawer)
                .presentationDetents([.large])
                .transaction { transaction in
                    transaction.animation = .easeInOut(duration: 0.15)
                }
        }
    }

    private func presentSettingsFromDrawer() {
        shouldPresentSettingsAfterSidebarDismissal = true
        appState.showSidebar = false
    }

    /// Persistent mode keeps the sidebar visible, so Settings opens directly
    /// instead of waiting for the drawer sheet to dismiss first.
    private func presentSettingsFromPersistentSidebar() {
        appState.isSettingsSheetPresented = true
        settingsPresentation = appState.makeSettingsSnapshot()
    }

    private func presentSettingsAfterSidebarDismissal() {
        guard shouldPresentSettingsAfterSidebarDismissal else { return }
        shouldPresentSettingsAfterSidebarDismissal = false
        appState.isSettingsSheetPresented = true
        settingsPresentation = appState.makeSettingsSnapshot()
    }

    /// Presents the sessions drawer for a preferred-return-surface request.
    /// Consumption semantics (defer-while-pending, claim-once-per-request,
    /// drop on precedence losers) live in AppState so they survive MainView
    /// teardown; this layer only owns the actual sheet presentation. An
    /// active persistent sidebar already shows Sessions, so the request is
    /// consumed without opening a redundant drawer.
    private func presentPreferredReturnSurfaceIfNeeded() {
        guard appState.claimPreferredReturnSurfacePresentation() else { return }
        guard SidebarLayoutPolicy.shouldPresentDrawerForReturnSurface(
            persistentSidebarActive: isPersistentSidebarActive,
            drawerPresented: appState.showSidebar
        ) else { return }
        appState.showSidebar = true
    }

    private var windowWidthReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: MainViewWindowWidthKey.self, value: proxy.size.width)
        }
    }

    private var voiceCapabilityRefreshKey: String {
        "\(appState.isConnected):\(appState.activeProfile)"
    }
}

/// Reports the width of the window hosting MainView so the sidebar layout
/// decision tracks Split View, Stage Manager, and window resizing.
private struct MainViewWindowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Connection Status

struct ConnectionStatusIndicator: View {
    @EnvironmentObject var appState: AppState

    private var color: Color {
        if appState.isConnected {
            return .green
        } else if appState.isConnecting {
            return .orange
        } else {
            return .red
        }
    }

    var body: some View {
        Button {
            Task { await appState.loadGatewayDiagnostics() }
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .shadow(color: color.opacity(0.75), radius: appState.isConnected ? 5 : 0)
                Circle()
                    .stroke(color.opacity(0.38), lineWidth: 1)
                    .frame(width: 19, height: 19)
            }
            .frame(width: 40, height: 40)
        }
        .conduitGlassControl(cornerRadius: 20, tint: color.opacity(0.10))
        .animation(ConduitMotion.response, value: appState.isConnected)
        .accessibilityLabel(appState.isConnected ? "Gateway connected" : "Gateway disconnected")
    }
}


// MARK: - Edge Pan Gesture

/// Detects a left-edge pan gesture to open the sidebar.
/// Uses UIScreenEdgePanGestureRecognizer (~20pt edge width) via UIViewRepresentable.
struct EdgePanGesture: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let gesture = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(context.coordinator.handle(_:))
        )
        gesture.edges = .left
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }

        @objc func handle(_ gesture: UIScreenEdgePanGestureRecognizer) {
            if gesture.state == .began { action() }
        }
    }
}
