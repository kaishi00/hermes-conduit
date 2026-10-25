//
//  WatchHomeView.swift
//  Conduit Watch
//
//  The home screen: the V2 voice button to talk to Hermes, the voice it
//  will use, and settings.
//

import SwiftUI

struct WatchHomeView: View {
    @EnvironmentObject private var call: WatchVoiceCall
    @EnvironmentObject private var link: WatchLink
    @Environment(\.watchAccent) private var accent

    /// The iPhone found this voice can't start for its Hermes profile.
    private var notSetUp: Bool {
        link.phoneContext?.notSetUp(call.engine.callVoice) == true
    }

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
                            .foregroundStyle(accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(call.engine.title)
                                .font(.footnote.weight(.semibold))
                            WatchEngineDetail(engine: call.engine, notSetUp: notSetUp)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(WatchCard())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Voice: \(call.engine.title)"))
                .accessibilityValue(notSetUp ? Text("Not set up on your Hermes host") : Text(call.engine.detail))
                // Calls from Hermes ring the Watch only while its voice can
                // start (WatchCallVoices).
                if notSetUp, HermesWatchCalls.ringingBuilt, link.phoneContext?.callsRing == true {
                    Text("Calls from Hermes ring only your iPhone until \(call.engine.title) is set up. Voice settings in Conduit on your iPhone show what it needs.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Conduit")
        .watchBackdrop()
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
            WatchVoiceButtonFace(size: 80)
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

/// A voice's line under its name: where it runs, or that the iPhone found
/// it can't start.
struct WatchEngineDetail: View {
    let engine: WatchVoiceEngine
    let notSetUp: Bool

    var body: some View {
        if notSetUp {
            Text("Not set up on your Hermes host")
                .font(.caption2)
                .foregroundStyle(Color.watchAttention)
        } else {
            Text(engine.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Picks the voice the next call talks to.
struct WatchEnginePicker: View {
    @EnvironmentObject private var call: WatchVoiceCall
    @EnvironmentObject private var link: WatchLink
    @Environment(\.dismiss) private var dismiss
    @Environment(\.watchAccent) private var accent

    var body: some View {
        List {
            ForEach(WatchVoiceEngine.allCases) { engine in
                Button {
                    call.engine = engine
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: engine.symbol)
                            .foregroundStyle(accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.title)
                            WatchEngineDetail(engine: engine, notSetUp: link.phoneContext?.notSetUp(engine.callVoice) == true)
                        }
                        Spacer(minLength: 0)
                        if engine == call.engine {
                            Image(systemName: "checkmark")
                                .foregroundStyle(accent)
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
        .watchBackdrop()
    }
}

/// Settings and the call log.
struct WatchSettingsView: View {
    @EnvironmentObject private var link: WatchLink
    @EnvironmentObject private var call: WatchVoiceCall
    @Environment(\.watchAccent) private var accent

    var body: some View {
        List {
            Section {
                Toggle("Call on open", isOn: $call.startsOnOpen)
                    .tint(accent)
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
                    Text(link.isReachable ? String(localized: "iPhone connected") : String(localized: "iPhone not connected right now"))
                } icon: {
                    Image(systemName: link.isReachable ? "iphone" : "iphone.slash")
                }
                .font(.footnote)
                .foregroundStyle(link.isReachable ? .primary : .secondary)
            } footer: {
                Text("Calls need Conduit on your iPhone to start. Once a call is on, it carries on with your wrist down and your iPhone locked.")
            }
            // As the padlock or shield on the iPhone's dashboard row.
            if let encryption = link.phoneContext?.encryption {
                Section {
                    Label {
                        Text(encryption == .quantumSafe ? String(localized: "Notifications quantum-safe") : String(localized: "Notifications encrypted"))
                    } icon: {
                        Image(systemName: encryption == .quantumSafe ? "lock.shield.fill" : "lock.fill")
                            .foregroundStyle(accent)
                    }
                    .font(.footnote)
                } footer: {
                    Text(encryption == .quantumSafe
                        ? String(localized: "Your active dashboard's notifications are end-to-end encrypted and quantum-safe: the relay sees when they arrive, not what they say. Conduit on your iPhone has the details.")
                        : String(localized: "Your active dashboard's notifications are end-to-end encrypted: the relay sees when they arrive, not what they say. Conduit on your iPhone has the details."))
                }
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
        .watchBackdrop()
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
        .watchBackdrop()
        .confirmationDialog("Clear the Watch call log?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { log.clear() }
        }
    }
}
