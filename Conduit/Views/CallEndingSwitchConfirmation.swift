//
//  CallEndingSwitchConfirmation.swift
//  Conduit
//
//  A profile or a saved dashboard picked by hand while a call runs. The
//  switch tears the call down (one live connection), so the pick asks
//  first rather than ending the call without a word (issue 2390). A live
//  call on the phone goes on across a switch to another profile on the
//  same dashboard (all-live stage 2), so that pick doesn't ask. Moves
//  Conduit makes for a tap (a notification, a chat link, a widget, Pulse)
//  refuse during a call instead and say so (#1297): those can wait, a
//  pick is the user asking for the switch now.
//

import SwiftUI

/// A switch waiting on the user's answer: where it goes, and the switch.
struct CallEndingSwitch: Identifiable {
    let id = UUID()
    /// The profile's or the dashboard's name, as the picker shows it.
    let destination: String
    let perform: () -> Void
}

extension AppState {
    /// Runs `perform` now, or, while a call runs anywhere (this screen,
    /// minimised, CarPlay, the Watch, a call from Hermes), hands it to
    /// `pending` so the view asks first. A switch to another profile
    /// (`profileOnly`) runs at once when the call goes on across it: a
    /// live call on the phone, through the kept socket (all-live stage 2).
    func switchEndingCall(
        to destination: String,
        profileOnly: Bool = false,
        pending: inout CallEndingSwitch?,
        perform: @escaping () -> Void
    ) {
        guard profileOnly ? isCallEndingProfileSwitch : isVoiceCallInProgress else {
            perform()
            return
        }
        pending = CallEndingSwitch(destination: destination, perform: perform)
    }

    /// The question in `pending` asked about the call running then. Once
    /// no call runs it no longer applies: it closes and nothing switches,
    /// so a call that starts afterwards is never ended by an answer about
    /// the one before (issue 2460). The user picks again, and a call
    /// running then asks again.
    func closeCallEndingSwitchOnceCallsEnd(_ pending: inout CallEndingSwitch?) {
        guard pending != nil, !isVoiceCallInProgress else { return }
        pending = nil
    }
}

extension View {
    /// Asks before a switch in `pending` ends the call.
    func callEndingSwitchConfirmation(_ pending: Binding<CallEndingSwitch?>) -> some View {
        modifier(CallEndingSwitchConfirmationModifier(pending: pending))
    }
}

private struct CallEndingSwitchConfirmationModifier: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @Binding var pending: CallEndingSwitch?

    func body(content: Content) -> some View {
        content
        .onChange(of: appState.isVoiceCallInProgress) { _, _ in
            appState.closeCallEndingSwitchOnceCallsEnd(&pending)
        }
        .confirmationDialog(
            AppLocalization.string("End the call and switch?", table: .voice),
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { request in
            Button(AppLocalization.string("End Call and Switch"), role: .destructive) {
                pending = nil
                request.perform()
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {
                pending = nil
            }
        } message: { request in
            Text(AppLocalization.string("Switching to \(request.destination) ends the call that's running."))
        }
    }
}
