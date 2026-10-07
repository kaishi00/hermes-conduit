//
//  ConduitWatchApp.swift
//  Conduit Watch
//
//  Proof of concept for Apple Watch voice (designs/apple-watch-voice.md):
//  a live call through the iPhone, a Gemini call the Watch makes itself
//  (designs/apple-watch-voice-direct.md), the link test and the audio lab,
//  each writing its numbers to a log that also lands on the iPhone.
//

import SwiftUI

@main
struct ConduitWatchApp: App {
    @StateObject private var link = WatchLink.shared
    @StateObject private var call = WatchCallModel()
    @StateObject private var direct = WatchDirectCallModel()
    @StateObject private var soak = WatchSoakModel()
    @StateObject private var lab = WatchLabModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchHomeView()
            }
            .environmentObject(link)
            .environmentObject(call)
            .environmentObject(direct)
            .environmentObject(soak)
            .environmentObject(lab)
        }
        .onChange(of: scenePhase) { _, phase in
            call.scenePhaseChanged(phase)
            direct.scenePhaseChanged(phase)
            soak.scenePhaseChanged(phase)
            lab.scenePhaseChanged(phase)
            WatchProbeLog.shared.note("scenePhase", ["phase": "\(phase)", "reachable": WatchLink.shared.isReachable])
        }
    }
}

struct WatchHomeView: View {
    @EnvironmentObject private var link: WatchLink

    var body: some View {
        List {
            NavigationLink {
                WatchDirectCallView()
            } label: {
                Label("Talk to Gemini (direct)", systemImage: "waveform.badge.mic")
            }
            NavigationLink {
                WatchCallView()
            } label: {
                Label("Talk to Hermes", systemImage: "waveform")
            }
            NavigationLink {
                WatchSoakView()
            } label: {
                Label("Link test", systemImage: "arrow.left.arrow.right")
            }
            NavigationLink {
                WatchLabView()
            } label: {
                Label("Audio lab", systemImage: "speaker.wave.2")
            }
            NavigationLink {
                WatchLogView()
            } label: {
                Label("Log", systemImage: "list.bullet.rectangle")
            }
            Section {
                Text(link.isReachable ? "iPhone reachable" : "iPhone not reachable")
                    .font(.footnote)
                    .foregroundStyle(link.isReachable ? .green : .secondary)
            }
        }
        .navigationTitle("Conduit")
    }
}

struct WatchCallView: View {
    @EnvironmentObject private var call: WatchCallModel
    /// The lab shares the call's audio session and the link test its
    /// channel to the iPhone: neither runs during a call.
    @EnvironmentObject private var lab: WatchLabModel
    @EnvironmentObject private var soak: WatchSoakModel
    @EnvironmentObject private var direct: WatchDirectCallModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                orb
                Text(phaseText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let startBlocked {
                    Text(startBlocked)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                if let notice = call.notice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let caption = call.caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
                if let summary = call.lastTurnSummary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if call.isActive {
                    HStack {
                        Button(call.isMuted ? "Unmute" : "Mute") { call.toggleMute() }
                        Button("End", role: .destructive) { call.end() }
                    }
                    if call.phase == .needsTap {
                        Button("Tap to continue") { call.continueAfterInterruption() }
                    }
                    if call.jobs > 0 {
                        Text("\(call.jobs) job\(call.jobs == 1 ? "" : "s") running")
                            .font(.caption2)
                    }
                } else {
                    Toggle("Full duplex (voice processing)", isOn: $call.fullDuplex)
                        .font(.footnote)
                    Toggle("Keep sending with wrist down", isOn: $call.keepStreamingWristDown)
                        .font(.footnote)
                    Toggle("Hold through dims with a Watch call", isOn: $call.holdWithWatchCall)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Hermes")
    }

    /// Why a call can't start now, if it can't.
    private var startBlocked: String? {
        guard !call.isActive else { return nil }
        if direct.isActive { return "End the Gemini call first." }
        if lab.isBusy || lab.isWatching { return "End the lab test first." }
        if soak.isRunning { return "Stop the link test first." }
        return nil
    }

    /// What a tap on the orb does now.
    private var orbLabel: String {
        if case .live = call.phase { return "Interrupt" }
        // Otherwise the tap does nothing while a call is on: say its state.
        return call.isActive ? phaseText : "Start a call"
    }

    @ViewBuilder
    private var orb: some View {
        let button = Button {
            if call.phase == .needsTap {
                call.continueAfterInterruption()
            } else if call.isActive {
                call.interrupt()
            } else {
                Task { await call.start() }
            }
        } label: {
            Image(systemName: call.isActive ? "waveform.circle.fill" : "mic.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(orbColor)
        }
        .buttonStyle(.plain)
        .disabled(startBlocked != nil)
        .accessibilityLabel(orbLabel)
        if #available(watchOS 11, *) {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private var orbColor: Color {
        switch call.phase {
        case .live(.speaking): return .purple
        case .live(.listening): return .green
        case .unreachable, .needsTap: return .orange
        case .ended: return .secondary
        default: return .blue
        }
    }

    private var phaseText: String {
        switch call.phase {
        case .idle: return "Tap to talk"
        case .starting: return "Connecting…"
        case .live(let phase):
            switch phase {
            case .connecting: return "Connecting…"
            case .listening: return "Listening"
            case .speaking: return "Speaking"
            case .paused: return "Paused"
            case .reconnecting: return "Reconnecting…"
            case .ending: return "Ending…"
            case .ended, .failed: return "Ended"
            }
        case .unreachable: return "Can't reach your iPhone"
        case .needsTap: return "Paused. Tap to continue."
        case .ended(let reason): return reason.map { "Ended: \($0)" } ?? "Ended"
        }
    }
}

/// The Watch's own Gemini Live call (test T2,
/// designs/apple-watch-voice-direct.md): the orb starts it and, while
/// Gemini speaks, stops it.
struct WatchDirectCallView: View {
    @EnvironmentObject private var direct: WatchDirectCallModel
    @EnvironmentObject private var call: WatchCallModel
    @EnvironmentObject private var lab: WatchLabModel
    @EnvironmentObject private var soak: WatchSoakModel
    @AppStorage(WatchDirectCallModel.KeepAlive.key) private var keepAlive = WatchDirectCallModel.KeepAlive.audioSession.rawValue
    @AppStorage(WatchSocketChoice.key) private var socket = WatchSocketChoice.alternate.rawValue
    @AppStorage(WatchDirectCallModel.Reactivation.key) private var reactivate = WatchDirectCallModel.Reactivation.off.rawValue

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let approval = direct.pendingApproval {
                    approvalCard(approval)
                }
                orb
                Text(phaseText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let startBlocked {
                    Text(startBlocked)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                if let caption = direct.caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
                if let summary = direct.lastTurnSummary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let route = direct.route {
                    Text(route)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if direct.isActive {
                    HStack {
                        Button(direct.isMuted ? "Unmute" : "Mute") { direct.toggleMute() }
                        Button("End", role: .destructive) { direct.end() }
                    }
                    let jobs = direct.runningJobs + direct.relayJobsRunning
                    if jobs > 0 {
                        Text("\(jobs) job\(jobs == 1 ? "" : "s") running")
                            .font(.caption2)
                    }
                } else {
                    Picker("Keep running with", selection: $keepAlive) {
                        ForEach(WatchDirectCallModel.KeepAlive.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .font(.footnote)
                    Picker("Socket", selection: $socket) {
                        ForEach(WatchSocketChoice.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .font(.footnote)
                    if keepAlive == WatchDirectCallModel.KeepAlive.audioSession.rawValue {
                        Picker("Reactivate session", selection: $reactivate) {
                            ForEach(WatchDirectCallModel.Reactivation.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("Gemini")
    }

    /// A job's request to run a command (Hermes' approval settings decide
    /// which need one). Approve allows this one command only.
    private func approvalCard(_ approval: WatchJobAnswer.Approval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Approve this command?")
                .font(.headline)
            Text(approval.title)
                .font(.footnote)
                .lineLimit(2)
            if !approval.description.isEmpty {
                Text(approval.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text(approval.command)
                .font(.caption2.monospaced())
                .lineLimit(8)
            HStack {
                Button("Deny", role: .destructive) { direct.answerApproval(approve: false) }
                Button("Approve") { direct.answerApproval(approve: true) }
                    .tint(.green)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.2)))
    }

    /// Why a call can't start now, if it can't.
    private var startBlocked: String? {
        guard !direct.isActive else { return nil }
        if call.isActive { return "End the Hermes call first." }
        if lab.isBusy || lab.isWatching { return "End the lab test first." }
        if soak.isRunning { return "Stop the link test first." }
        return nil
    }

    @ViewBuilder
    private var orb: some View {
        let button = Button {
            if direct.isActive {
                direct.tapOrb()
            } else {
                Task { await direct.start() }
            }
        } label: {
            Image(systemName: direct.isActive ? "waveform.circle.fill" : "mic.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(orbColor)
        }
        .buttonStyle(.plain)
        .disabled(startBlocked != nil)
        .accessibilityLabel(direct.isActive ? (direct.phase == .speaking ? "Interrupt" : phaseText) : "Start a call")
        if #available(watchOS 11, *) {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private var orbColor: Color {
        switch direct.phase {
        case .speaking: return .purple
        case .listening: return .green
        case .needsTap: return .orange
        case .ended, .idle: return .secondary
        default: return .blue
        }
    }

    private var phaseText: String {
        switch direct.phase {
        case .idle: return "Tap to talk"
        case .preparing: return "Asking your iPhone…"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .speaking: return "Speaking"
        case .reconnecting: return "Reconnecting…"
        case .needsTap: return "Paused. Tap to continue."
        case .ending: return "Ending…"
        case .ended(let reason): return reason.map { "Ended: \($0)" } ?? "Ended"
        }
    }
}

struct WatchSoakView: View {
    @EnvironmentObject private var soak: WatchSoakModel
    /// The link test would share the call's channel to the iPhone.
    @EnvironmentObject private var call: WatchCallModel
    @EnvironmentObject private var direct: WatchDirectCallModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !soak.isRunning, call.isActive || direct.isActive {
                    Text("End the call to run the link test.").font(.footnote)
                }
                if !soak.isRunning {
                    Picker("Packets", selection: $soak.preset) {
                        ForEach(WatchSoakModel.presets) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    Picker("Length", selection: $soak.duration) {
                        ForEach(WatchSoakModel.durations, id: \.self) { seconds in
                            Text("\(Int(seconds / 60)) min").tag(seconds)
                        }
                    }
                    Button("Start") { soak.start() }
                        .disabled(call.isActive || direct.isActive)
                } else {
                    Button("Stop", role: .destructive) { soak.stop() }
                }
                Text(soak.status)
                    .font(.footnote)
                if let watch = soak.watchResult {
                    resultView("Watch → iPhone", watch)
                }
                if let phone = soak.phoneResult {
                    resultView("iPhone → Watch", phone)
                }
            }
        }
        .navigationTitle("Link test")
    }

    private func resultView(_ title: String, _ result: WatchVoiceWire.SoakResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text("acked \(result.acked)/\(result.sent), failed \(result.failed), merged \(result.merged)")
            Text("round trip p50 \(result.rttP50Ms ?? -1) p95 \(result.rttP95Ms ?? -1) p99 \(result.rttP99Ms ?? -1) ms")
            Text("received \(result.received), longest gap \(result.maxGapMs ?? -1) ms, stalls \(result.stallsOver1s)")
            if result.suspendedMs > 0 {
                Text("iPhone app paused \(result.suspendedMs) ms")
            }
        }
        .font(.caption2)
    }
}

struct WatchLabView: View {
    @EnvironmentObject private var lab: WatchLabModel
    /// The lab and a call can't share the audio session.
    @EnvironmentObject private var call: WatchCallModel
    @EnvironmentObject private var direct: WatchDirectCallModel

    private var blocked: Bool { lab.isBusy || call.isActive || direct.isActive }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if call.isActive || direct.isActive {
                    Text("End the call to use the lab.").font(.footnote)
                }
                Text("Encoders").font(.headline)
                ForEach(lab.encoders, id: \.self) { Text($0).font(.caption2) }
                Text("Echo").font(.headline)
                Button("Test, processing off") { Task { await lab.runEchoTest(options: .init()) } }
                    .disabled(blocked)
                Button("Test, processing on") { Task { await lab.runEchoTest(options: .init(voiceProcessing: true)) } }
                    .disabled(blocked)
                // The session's voice chat mode, without the engine's
                // processing: whether watchOS cancels any echo itself.
                Button("Test, voice chat mode") { Task { await lab.runEchoTest(options: .init(voiceChatMode: true)) } }
                    .disabled(blocked)
                ForEach(lab.echoResults, id: \.options) { result in
                    Text(String(format: "%@: echo %.0f dB over the room (room %.0f dBFS)", WatchLabModel.label(result.options), result.echoOverNoiseDB, result.noiseDBFS))
                        .font(.caption2)
                }
                // Beside the buttons: at the top it scrolled out of view,
                // so a failed test looked like a dead button.
                Text(lab.status).font(.footnote)
                if lab.hasRecording {
                    Button("Hear what the mic got") { Task { await lab.playRecording() } }
                        .disabled(blocked)
                }
                Text("Interruptions").font(.headline)
                if lab.isWatching {
                    Button("Stop watching", role: .destructive) { lab.stopWatching() }
                } else {
                    Button("Watch the microphone") { Task { await lab.startWatching() } }
                        .disabled(blocked)
                }
            }
        }
        .navigationTitle("Audio lab")
        .onAppear { lab.probeEncoders() }
    }
}

struct WatchLogView: View {
    @ObservedObject private var log = WatchProbeLog.shared

    var body: some View {
        List {
            Button("Clear", role: .destructive) { log.clear() }
            ForEach(Array(log.lines.reversed().enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption2.monospaced())
            }
        }
        .navigationTitle("Log")
    }
}
