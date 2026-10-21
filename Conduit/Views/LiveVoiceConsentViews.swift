//
//  LiveVoiceConsentViews.swift
//  Conduit
//
//  The one-time question before a live voice mode first sends the user's
//  voice to its provider (#827, App Review 5.1.2(i)): in the call screen
//  when the phone shows the call, on its own sheet after a CarPlay or Watch
//  call stopped on it, and the row in each mode's Voice settings that shows
//  the answer and takes it back.
//

import SwiftUI

/// Names the company and what goes to it, with Allow and Not Now.
struct LiveVoiceConsentPanel: View {
    let mode: LiveVoiceModeName
    let onAllow: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "waveform.badge.mic")
                    .font(.largeTitle)
                    .foregroundStyle(Color.conduitAccent)
                    .accessibilityHidden(true)
                Text(AppLocalization.string("Send your voice to \(mode.company)?"))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(AppLocalization.string("During a \(mode.displayName) call, Conduit sends your microphone audio, the transcript, and the context and tool results Hermes adds to \(mode.company). Their terms and privacy policy apply."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(AppLocalization.string("Conduit asks once for each provider. You can take it back in Settings > Voice."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 4) {
                    Button(action: onAllow) {
                        Text(AppLocalization.string("Allow"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.settingsPrimary)
                    Button(action: onNotNow) {
                        Text(AppLocalization.string("Not Now"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.settings)
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The phone's own ask, after a call it wasn't showing (CarPlay, the
/// Watch) stopped for want of consent. Allowing doesn't start a call: the
/// user starts it again where they were.
struct LiveVoiceConsentSheet: View {
    let mode: LiveVoiceModeName
    let onAnswer: (Bool) -> Void

    var body: some View {
        ZStack {
            ConduitBackdrop()
            VStack(spacing: 0) {
                Text(verbatim: mode.displayName)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 20)
                LiveVoiceConsentPanel(mode: mode, onAllow: { onAnswer(true) }, onNotNow: { onAnswer(false) })
            }
            .readableContentWidth(ReadableWidth.call)
        }
    }
}

/// In a live mode's Voice settings: who hears the call, and whether the
/// user has allowed it, with the way to take it back.
struct LiveVoiceConsentRow: View {
    @EnvironmentObject private var appState: AppState
    let mode: LiveVoiceModeName
    @State private var granted: Bool

    init(mode: LiveVoiceModeName) {
        self.mode = mode
        _granted = State(initialValue: LiveVoiceProviderConsent.isGranted(mode))
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.string("Your voice goes to \(mode.company)"))
                    .font(.footnote)
                Text(granted ? AppLocalization.string("Allowed") : AppLocalization.string("Asks before the first call"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if granted {
                Button(AppLocalization.string("Take back")) {
                    appState.setLiveVoiceConsent(false, for: mode)
                }
                .buttonStyle(.settings)
                .accessibilityHint(AppLocalization.string("Ends a running call on this iPhone. The next call asks again."))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LiveVoiceProviderConsent.didChange)) { _ in
            granted = LiveVoiceProviderConsent.isGranted(mode)
        }
    }
}
