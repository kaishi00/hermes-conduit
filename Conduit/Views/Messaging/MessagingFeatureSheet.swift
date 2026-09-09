import SwiftUI

struct MessagingFeatureCard: View {
    let open: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title2).foregroundStyle(Color.conduitAccent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Give your bots a shared inbox").font(.headline)
                Text("Keep ongoing DMs and bring multiple bots into group conversations.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Enable messaging", action: open).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("messaging.enable")
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 32, height: 32) }
                .accessibilityLabel("Dismiss messaging introduction")
        }
        .padding(16).background(Color.conduitRaisedSurface, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct MessagingFeatureSheet: View {
    @ObservedObject var store: MessagingStore
    let server: String
    /// Display name of the workspace profile that will own the setup session.
    var workspaceProfileName: String = "current profile"
    var setupWithAgentEnabled: Bool = true
    var onSetupWithAgent: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 46)).foregroundStyle(Color.conduitAccent).accessibilityHidden(true)
                    Text("A shared inbox for your bots").font(.largeTitle.bold())
                    benefit("Ongoing DMs", "Continue the same conversation with a bot, with context carried across replies.", "person.crop.circle")
                    benefit("Group conversations", "Bring profiles together and mention the ones you want to hear from.", "person.2")
                    benefit("Work on your server", "Hermes keeps conversations running while Conduit is closed.", "server.rack")
                    Divider()
                    Text(server).font(.headline).textSelection(.enabled)
                    Text(store.availability.explanation).foregroundStyle(.secondary)
                    if store.isReady {
                        Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                    } else {
                        Text("Set up on Hermes").font(.headline)
                        Text("Install bot-coms with the messaging extra on a compatible Hermes backend, enable the plugins, configure profiles, then check again. Existing sessions keep working during setup.")
                        Text("Conduit cannot install packages or restart Hermes itself. You can start a setup conversation with \(workspaceProfileName), or share the checklist.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let onSetupWithAgent {
                            Button {
                                onSetupWithAgent()
                            } label: {
                                Label("Set up with an agent", systemImage: "bubble.left.and.bubble.right")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!setupWithAgentEnabled)
                            .accessibilityIdentifier("messaging.setup.agent")
                            Text("Uses the current workspace profile (\(workspaceProfileName)). Switch profiles first if you want a different one.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ShareLink(item: MessagingSetupPrompt.shareChecklist) {
                            Label("Share setup checklist", systemImage: "square.and.arrow.up")
                        }
                        Button { Task { await store.refresh() } } label: {
                            if store.isRefreshing { ProgressView() } else { Label("Check again", systemImage: "arrow.clockwise") }
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isRefreshing)
                    }
                }.padding(24)
            }
            .navigationTitle("Messaging").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func benefit(_ title: String, _ description: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).frame(width: 24)
        }
    }
}

/// Settings creates its own discovery owner; agent setup asks RootView to open a session.
struct MessagingSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = MessagingStore()

    private var setupEnabled: Bool {
        appState.isConnected
            && !appState.isConnecting
            && !appState.isProfileSwitching
            && appState.turnState != .synchronizing
    }

    var body: some View {
        MessagingFeatureSheet(
            store: store,
            server: appState.connection?.baseUrl ?? "Hermes",
            workspaceProfileName: appState.profileDisplayName(appState.activeProfile),
            setupWithAgentEnabled: setupEnabled,
            onSetupWithAgent: {
                appState.requestMessagingSetupSession()
            }
        )
        .task(id: appState.dashboardTicketBridge.map(ObjectIdentifier.init)) {
            store.connect(requester: appState.dashboardTicketBridge, scope: appState.connection?.baseUrl ?? "")
            await store.refresh()
        }
    }
}
