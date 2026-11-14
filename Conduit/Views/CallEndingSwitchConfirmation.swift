//
//  CallEndingSwitchConfirmation.swift
//  Conduit
//
//  A profile or a saved dashboard picked by hand while a call runs. The
//  switch tears the call down (one live connection), so the pick asks
//  first rather than ending the call without a word (issue 2390). Moves
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
    /// `pending` so the view asks first.
    func switchEndingCall(
        to destination: String,
        pending: inout CallEndingSwitch?,
        perform: @escaping () -> Void
    ) {
        guard isVoiceCallInProgress else {
            perform()
            return
        }
        pending = CallEndingSwitch(destination: destination, perform: perform)
    }
}

extension View {
    /// Asks before a switch in `pending` ends the call.
    func callEndingSwitchConfirmation(_ pending: Binding<CallEndingSwitch?>) -> some View {
        modifier(CallEndingSwitchConfirmationModifier(pending: pending))
    }
}

private struct CallEndingSwitchConfirmationModifier: ViewModifier {
    @Binding var pending: CallEndingSwitch?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            AppLocalization.string("End the call and switch?", table: .voice),
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { request in
            Button(AppLocalization.string("End Call and Switch", table: .voice), role: .destructive) {
                pending = nil
                request.perform()
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {
                pending = nil
            }
        } message: { request in
            Text(AppLocalization.string("Switching to \(request.destination) ends the call that's running.", table: .voice))
        }
    }
}
