//
//  ConduitWatchApp.swift
//  Conduit Watch
//
//  Proof of concept for Apple Watch voice (designs/apple-watch-voice.md):
//  a live call through the iPhone, the link test and the audio lab, each
//  writing its numbers to a log that also lands on the iPhone.
//

import SwiftUI

@main
struct ConduitWatchApp: App {
    @StateObject private var link = WatchLink.shared
    @StateObject private var call = WatchCallModel()
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
            .environmentObject(soak)
            .environmentObject(lab)
        }
        .onChange(of: scenePhase) { _, phase in
            call.scenePhaseChanged(phase)
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

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                orb
                Text(phaseText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
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
                }
            }
        }
        .navigationTitle("Hermes")
    }

    @ViewBuilder
    private var orb: some View {
        let button = Button {
            if call.isActive {
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
        .accessibilityLabel(call.isActive ? "Interrupt" : "Start a call")
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

struct WatchSoakView: View {
    @EnvironmentObject private var soak: WatchSoakModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(lab.status).font(.footnote)
                Text("Encoders").font(.headline)
                ForEach(lab.encoders, id: \.self) { Text($0).font(.caption2) }
                Text("Echo").font(.headline)
                Button("Test, processing off") { Task { await lab.runEchoTest(voiceProcessing: false) } }
                    .disabled(lab.isBusy)
                Button("Test, processing on") { Task { await lab.runEchoTest(voiceProcessing: true) } }
                    .disabled(lab.isBusy)
                ForEach(lab.echoResults, id: \.voiceProcessing) { result in
                    Text(String(format: "%@: echo %.0f dB over the room (room %.0f dBFS)", result.voiceProcessing ? "On" : "Off", result.echoOverNoiseDB, result.noiseDBFS))
                        .font(.caption2)
                }
                if lab.hasRecording {
                    Button("Hear what the mic got") { Task { await lab.playRecording() } }
                        .disabled(lab.isBusy)
                }
                Text("Interruptions").font(.headline)
                if lab.isWatching {
                    Button("Stop watching", role: .destructive) { lab.stopWatching() }
                } else {
                    Button("Watch the microphone") { Task { await lab.startWatching() } }
                        .disabled(lab.isBusy)
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
                Text(line).font(.system(size: 10, design: .monospaced))
            }
        }
        .navigationTitle("Log")
    }
}
