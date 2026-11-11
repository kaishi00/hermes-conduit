//
//  VoicePhotoButton.swift
//  Conduit
//
//  The voice screens' Camera: take a photo mid-conversation and it joins
//  the conversation's chat, for the next request to Hermes (and, in Gemini
//  Live and Qwen Live, for the call's own model). See
//  `AppState.addVoicePhoto`.
//

import SwiftUI
import UIKit

/// Opens the camera from its face and hands the photo to `appState`, with
/// the conversation it was opened for; an alert says why when the photo
/// couldn't be added.
struct VoicePhotoButton<Face: View>: View {
    let appState: AppState
    /// The button's look; call `open` to bring up the camera.
    @ViewBuilder let face: (_ open: @escaping () -> Void) -> Face

    @State private var showsCamera = false
    @State private var target: VoicePhotoTarget?
    @State private var failure: String?

    var body: some View {
        face({
            target = appState.voicePhotoTarget
            showsCamera = true
        })
            .fullScreenCover(isPresented: $showsCamera) {
                CameraCapture { image in
                    guard let target else { return }
                    Task { @MainActor in
                        failure = await appState.addVoicePhoto(image, for: target)
                        if failure == nil { Haptics.selection() }
                    }
                }
                .ignoresSafeArea()
            }
            .alert(
                AppLocalization.string("The photo wasn't added"),
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
            ) {
                Button(AppLocalization.string("OK"), role: .cancel) {}
            } message: {
                Text(verbatim: failure ?? "")
            }
    }
}

/// The Camera in a call's row of round buttons.
struct LiveVoiceCallPhotoButton: View {
    let appState: AppState

    var body: some View {
        VoicePhotoButton(appState: appState) { open in
            LiveVoiceCallButton(
                symbol: "camera.fill",
                title: AppLocalization.string("Camera"),
                voiceOverLabel: AppLocalization.string("Take a photo"),
                voiceOverHint: AppLocalization.string("Adds a photo to the chat for your next question"),
                action: open
            )
        }
    }
}
