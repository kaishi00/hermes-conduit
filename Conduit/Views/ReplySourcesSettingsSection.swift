import OSLog
import SwiftUI

private let replySourcesLogger = Logger(subsystem: "com.milim.relay", category: "ReplySources")

/// Settings > Notifications: which sources' replies send "Response ready"
/// (#115). Someone who also talks to Hermes in Desktop, a messaging app or
/// the terminal sees those replies there. Kept per profile by the host's
/// notifier plugin, so it shows only when the plugin offers it.
@MainActor
struct ReplySourcesSettingsSection: View {
    @EnvironmentObject private var appState: AppState
    /// What the host answered for `loadedKey` (the dashboard and profile);
    /// nil until then.
    @State private var settings: [ReplySource: Bool]?
    @State private var loadedKey: String?
    @State private var saving: ReplySource?
    @State private var error: String?

    private var key: String {
        (appState.activeDashboardID?.uuidString ?? "") + "|" + appState.activeProfile
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Replies to messages from"), symbol: "bubble.left.and.text.bubble.right", tint: .conduitAccent) {
            Text(AppLocalization.string("A reply to a message you sent from a source turned off here sends no Response ready notification. Applies to this profile on this dashboard."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if loadedKey == key {
                ForEach(ReplySource.allCases) { source in
                    toggle(source)
                }
            } else if error == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                if loadedKey != key {
                    Button(AppLocalization.string("Try again")) {
                        Task { await load(key) }
                    }
                    .buttonStyle(.settings)
                }
            }
        }
        .task(id: key) { await load(key) }
    }

    private func toggle(_ source: ReplySource) -> some View {
        Toggle(isOn: Binding(
            get: { settings?[source] ?? true },
            set: { value in
                Haptics.selection()
                Task { await save(value, source: source) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(source))
                Text(detail(source)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(.conduitAccent)
        // One change at a time.
        .disabled(saving != nil)
        .accessibilityIdentifier("notifications.reply-source.\(source.rawValue)")
    }

    private func title(_ source: ReplySource) -> String {
        switch source {
        case .conduit: AppLocalization.string("Conduit")
        case .desktop: AppLocalization.string("Hermes Desktop and web")
        case .messaging: AppLocalization.string("Messaging apps")
        case .terminal: AppLocalization.string("Terminal")
        }
    }

    private func detail(_ source: ReplySource) -> String {
        switch source {
        case .conduit: AppLocalization.string("Messages you send in this app, its widgets and your Watch")
        case .desktop: AppLocalization.string("The Hermes Desktop app and the web dashboard")
        case .messaging: AppLocalization.string("Telegram, Discord, Slack and other platforms Hermes is on")
        case .terminal: AppLocalization.string("hermes chat on the host")
        }
    }

    private func load(_ key: String) async {
        if loadedKey != key {
            settings = nil
            loadedKey = nil
            error = nil
        }
        do {
            let read = try await appState.replySourcesClient.settings(profile: appState.activeProfile)
            // Moved on meanwhile. A save still running for this key answers
            // with the host's state after it, which then replaces this.
            guard key == self.key else { return }
            settings = read
            loadedKey = key
        } catch is CancellationError {
            return
        } catch let readError {
            replySourcesLogger.notice("Reply sources not read: \(readError.localizedDescription, privacy: .public)")
            if key == self.key { error = AppLocalization.string("Could not read this setting from the host: \(UserFacingError.message(for: readError))") }
        }
    }

    private func save(_ notify: Bool, source: ReplySource) async {
        let key = key
        guard loadedKey == key, saving == nil, var changed = settings else { return }
        changed[source] = notify
        settings = changed
        saving = source
        error = nil
        defer { saving = nil }
        do {
            let kept = try await appState.replySourcesClient.setNotify(notify, source: source, profile: appState.activeProfile)
            if key == self.key, loadedKey == key { settings = kept }
        } catch let saveError {
            guard key == self.key, loadedKey == key else { return }
            let cancelled = saveError is CancellationError
            if !cancelled {
                Haptics.error()
                replySourcesLogger.notice("Reply sources not saved: \(saveError.localizedDescription, privacy: .public)")
            }
            // Read back what the host kept rather than guess at it.
            saving = nil
            settings = nil
            loadedKey = nil
            await load(key)
            // The change's failure is what the user needs to know, whether
            // or not the read-back worked (Try again shows if it didn't).
            if !cancelled, key == self.key {
                error = AppLocalization.string("Could not change this setting: \(UserFacingError.message(for: saveError))")
            }
        }
    }
}
