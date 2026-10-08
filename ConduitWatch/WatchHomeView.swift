//
//  WatchHomeView.swift
//  Conduit Watch
//
//  The home screen: one big button to talk to Hermes, the voice it will
//  use, and settings.
//

import SwiftUI

struct WatchHomeView: View {
    @EnvironmentObject private var call: WatchVoiceCall

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                startButton
                Text("Talk to Hermes")
                    .font(.headline)
                NavigationLink {
                    WatchEnginePicker()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: call.engine.symbol)
                            .foregroundStyle(Color.watchAura)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(call.engine.title)
                                .font(.footnote.weight(.semibold))
                            Text(call.engine.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(Text("Voice: \(call.engine.title)"))
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Conduit")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    WatchSettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("Settings"))
            }
        }
    }

    @ViewBuilder
    private var startButton: some View {
        let button = Button {
            call.start()
        } label: {
            WatchVoiceOrb(mood: .ready, size: 84)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Start a call"))
        if #available(watchOS 11, *) {
            // Double tap starts a call too.
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }
}

/// Picks the voice the next call talks to.
struct WatchEnginePicker: View {
    @EnvironmentObject private var call: WatchVoiceCall
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(WatchVoiceEngine.allCases) { engine in
                Button {
                    call.engine = engine
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: engine.symbol)
                            .foregroundStyle(Color.watchAura)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.title)
                            Text(engine.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if engine == call.engine {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.watchAura)
                        }
                    }
                }
                .accessibilityAddTraits(engine == call.engine ? .isSelected : [])
            }
            Section {
                Text("Your iPhone sets up each call with your Hermes profile's memory, persona and voice settings. Calls are saved to your iPhone's voice history.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Voice")
    }
}

/// Settings and the call log.
struct WatchSettingsView: View {
    @EnvironmentObject private var link: WatchLink
    @EnvironmentObject private var call: WatchVoiceCall

    var body: some View {
        List {
            Section {
                Toggle("Call on open", isOn: $call.startsOnOpen)
            } footer: {
                Text("Opening Conduit starts a call right away. Turn this off to start each call with a tap.")
            }
            Section {
                NavigationLink {
                    WatchEnginePicker()
                } label: {
                    Label("Voice", systemImage: "waveform")
                }
                NavigationLink {
                    WatchLogView()
                } label: {
                    Label("Call log", systemImage: "list.bullet.rectangle")
                }
            }
            Section {
                Label {
                    Text(link.isReachable ? "iPhone connected" : "iPhone not connected right now")
                } icon: {
                    Image(systemName: link.isReachable ? "iphone" : "iphone.slash")
                }
                .font(.footnote)
                .foregroundStyle(link.isReachable ? .primary : .secondary)
            } footer: {
                Text("Calls need Conduit on your iPhone to start. Once a call is on, it carries on with your wrist down and your iPhone locked.")
            }
            if let version {
                Section {
                    Text("Version \(version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("Settings")
    }

    private var version: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

/// The Watch's side of the call log, newest first. The iPhone keeps the
/// whole log, Watch lines included, to share from Voice settings.
struct WatchLogView: View {
    @ObservedObject private var log = WatchCallLog.shared
    @State private var confirmingClear = false

    /// Newest first, each line keyed by its running number.
    private var numberedLines: [(number: Int, text: String)] {
        let first = log.firstLineNumber
        return log.lines.enumerated().reversed().map { (number: first + $0.offset, text: $0.element) }
    }

    var body: some View {
        List {
            Section {
                Text("Every call's log also reaches your iPhone, where Voice settings > Apple Watch can share it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Text("Clear")
            }
            ForEach(numberedLines, id: \.number) { line in
                Text(verbatim: line.text)
                    .font(.caption2.monospaced())
            }
        }
        .navigationTitle("Call log")
        .confirmationDialog("Clear the Watch call log?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { log.clear() }
        }
    }
}
