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

/// Opens the camera from its face and hands the photo to `onPhoto`, which
/// answers with what to tell the user when the photo couldn't be added.
struct VoicePhotoButton<Face: View>: View {
    let onPhoto: @MainActor (UIImage) async -> String?
    /// The button's look; call `open` to bring up the camera.
    @ViewBuilder let face: (_ open: @escaping () -> Void) -> Face

    @State private var showsCamera = false
    @State private var failure: String?

    /// No camera, no button (the simulator, a Mac).
    static var isAvailable: Bool { CameraCapture.isAvailable }

    var body: some View {
        face({ showsCamera = true })
            .fullScreenCover(isPresented: $showsCamera) {
                CameraCapture { image in
                    Task { @MainActor in
                        failure = await onPhoto(image)
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
    let onPhoto: @MainActor (UIImage) async -> String?

    var body: some View {
        VoicePhotoButton(onPhoto: onPhoto) { open in
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
