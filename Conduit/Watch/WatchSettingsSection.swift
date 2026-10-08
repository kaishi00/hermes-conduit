//
//  WatchSettingsSection.swift
//  Conduit
//
//  Voice settings > Apple Watch: whether the Watch app is there, what a
//  Watch call may do on Hermes (jobs, approvals), GPT-Live's setup on the
//  Hermes host, and the call log to share for a support question.
//

import SwiftUI

@MainActor
struct WatchSettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject private var link = WatchVoiceLink.shared
    @ObservedObject private var log = WatchPhoneCallLog.shared
    @StateObject private var gptLive = WatchGPTLiveSetup()
    @AppStorage(WatchJobSettings.jobsPerCallKey) private var jobsPerCall = WatchJobSettings.defaultJobsPerCall
    @AppStorage(WatchJobSettings.voiceApprovalsKey) private var voiceApprovals = false
    @State private var confirmingClear = false

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Apple Watch"), symbol: "applewatch", tint: .conduitAura) {
            Label {
                Text(statusLine)
            } icon: {
                Image(systemName: link.isPaired ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Open Conduit on your Watch and tap the microphone to talk to Hermes. Gemini Live runs on the Watch; GPT-Live runs on your Hermes host. Calls keep going with your wrist down and your iPhone locked, and are saved to voice history.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(value: $jobsPerCall, in: 0...WatchJobSettings.maximumJobsPerCall) {
                Text(jobsPerCall == 0
                    ? AppLocalization.string("Jobs per Watch call: through the iPhone")
                    : AppLocalization.string("Jobs per Watch call: \(String(jobsPerCall))"))
            }
            .accessibilityIdentifier("voice.watchJobsPerCall")
            Text("Hermes jobs a Watch call can start, wrist up or down. Each runs as a normal Hermes chat under Voice Jobs, and Hermes' own approval settings apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(AppLocalization.string("Approve from the Watch"), selection: $voiceApprovals) {
                Text("Tap").tag(false)
                Text("Tap or voice").tag(true)
            }
            .disabled(jobsPerCall == 0)
            .accessibilityIdentifier("voice.watchApprovals")
            Text(voiceApprovals
                ? AppLocalization.string("A job's approval request shows on the Watch, and Gemini Live can also take your answer by voice. Voice only ever approves once. Text in a web page or a job's output could try to talk it into approving.")
                : AppLocalization.string("A job's approval request shows on the Watch with Approve and Deny."))
                .font(.caption)
                .foregroundStyle(.secondary)

            gptLiveRow

            VStack(alignment: .leading, spacing: 6) {
                Text("Call log")
                    .font(.subheadline.weight(.semibold))
                Text("Timings and connection events from Watch calls, without what was said. Share it when reporting a problem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    ShareLink(item: log.fileURL) {
                        Label("Share call log", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Text("Clear")
                    }
                    .confirmationDialog(AppLocalization.string("Clear the Watch call log?"), isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button(AppLocalization.string("Clear"), role: .destructive) { log.clear() }
                    }
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var gptLiveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GPT-Live on the Watch")
                .font(.subheadline.weight(.semibold))
            Text("Your Hermes host holds GPT-Live's call for the Watch, with a small runtime it sets up once. The first call sets it up too, but that can take a few minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                gptLiveStatus
                Spacer()
                if gptLive.canPrepare {
                    Button(AppLocalization.string("Set up")) { gptLive.prepare() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("voice.watchGPTLiveSetup")
                }
            }
            .font(.caption)
        }
        .task { await gptLive.refresh() }
    }

    @ViewBuilder
    private var gptLiveStatus: some View {
        switch gptLive.state {
        case .unknown:
            Text("Checking…").foregroundStyle(.secondary)
        case .ready:
            Label(AppLocalization.string("Ready"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Setting up on Hermes…").foregroundStyle(.secondary)
            }
        case .notSetUp:
            Text("Not set up yet").foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason).foregroundStyle(.orange)
        case .unavailable(let reason):
            Text(reason).foregroundStyle(.secondary)
        }
    }

    // `isWatchAppInstalled` has read false at launch with the Watch app
    // installed, so reachability comes first.
    private var statusLine: String {
        guard link.isActivated else { return AppLocalization.string("Checking for an Apple Watch…") }
        guard link.isPaired else { return AppLocalization.string("No Apple Watch is paired with this iPhone.") }
        if link.isReachable || link.isWatchAppInstalled { return AppLocalization.string("Conduit is on your Apple Watch.") }
        return AppLocalization.string("Install Conduit on your Apple Watch from the Watch app on this iPhone.")
    }
}

/// GPT-Live's WebRTC runtime on the Hermes host (watch-audio/status and
/// /prepare): whether a Watch call to GPT-Live can start at once.
@MainActor
final class WatchGPTLiveSetup: ObservableObject {
    enum State: Equatable {
        case unknown
        case ready
        case preparing
        case notSetUp
        case failed(String)
        case unavailable(String)
    }

    /// How often a setup in progress is checked while the screen is up.
    static let pollInterval: Duration = .seconds(3)
    /// Checks give up after this many; the next visit checks again.
    static let maxPolls = 120

    @Published private(set) var state: State = .unknown
    private let client = WatchToolGrantClient.activeDashboard()
    private var polling: Task<Void, Never>?

    var canPrepare: Bool {
        switch state {
        case .notSetUp, .failed: return true
        default: return false
        }
    }

    func refresh() async {
        let appState = AppStateRuntimeRegistry.shared.appState
        guard appState.isConnected else {
            state = .unavailable(AppLocalization.string("Connect to Hermes to check."))
            return
        }
        do {
            apply(try await client.audioStatus(profile: appState.activeProfile))
        } catch {
            state = .unavailable(AppLocalization.string("Your Hermes host doesn't offer GPT-Live for the Watch. Update the Conduit notifier plugin."))
        }
    }

    func prepare() {
        let profile = AppStateRuntimeRegistry.shared.appState.activeProfile
        state = .preparing
        polling?.cancel()
        let client = self.client
        // Holds the setup only weakly: leaving the screen stops the checks.
        polling = Task { [weak self] in
            do {
                let first = try await client.prepareAudio(profile: profile)
                self?.apply(first)
            } catch {
                self?.state = .failed(UserFacingError.message(for: error))
                return
            }
            for _ in 0..<Self.maxPolls {
                guard self?.state == .preparing, !Task.isCancelled else { return }
                do { try await Task.sleep(for: Self.pollInterval) } catch { return }
                guard let status = try? await client.audioStatus(profile: profile) else { continue }
                self?.apply(status)
            }
        }
    }

    private func apply(_ runtime: WatchToolGrantClient.AudioRuntime) {
        switch runtime.runtime {
        case "ready": state = .ready
        case "preparing": state = .preparing
        case "failed": state = .failed(runtime.reason ?? AppLocalization.string("Hermes couldn't set up GPT-Live for the Watch."))
        default: state = .notSetUp
        }
    }
}
