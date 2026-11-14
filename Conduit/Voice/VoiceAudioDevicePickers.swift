//
//  VoiceAudioDevicePickers.swift
//  Conduit
//
//  The microphone and output pickers (issue 2389): iOS's own input picker
//  (iOS 26: the microphone, its Mic Mode and a level meter; iOS remembers
//  the choice for Conduit) and its route picker for where the voice plays.
//  Settings > Voice and every call screen's header show them. iOS owns the
//  choices: Conduit never sets a Mic Mode or an output of its own.
//

import AVFoundation
import AVKit
import Combine
import os
import SwiftUI
import UIKit

private let devicePickerLogger = Logger(subsystem: "com.milim.relay", category: "VoiceAudio")

/// The names of the microphone and the output the voice uses now, as iOS
/// names them ("iPhone Microphone", "AirPods Pro", "Speaker").
@MainActor
final class VoiceAudioRouteNames: ObservableObject {
    static let shared = VoiceAudioRouteNames()

    @Published private(set) var input: String?
    @Published private(set) var output: String?
    private var observers: [NSObjectProtocol] = []

    /// Whether this device offers the pickers: an iPhone or iPad, not
    /// Conduit running on a Mac, where macOS chooses devices itself.
    static var isAvailable: Bool {
        !ProcessInfo.processInfo.isiOSAppOnMac
    }

    private init() {
        refresh()
        let center = NotificationCenter.default
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        // A session that isn't recording has no input in its route; the
        // microphone the user chose is still the one the next call takes.
        let inputName = route.inputs.first?.portName ?? session.preferredInput?.portName
        let outputName = route.outputs.first?.portName
        if input != inputName { input = inputName }
        if output != outputName { output = outputName }
    }
}

/// Presents iOS's input picker. The picker lists inputs only for a session
/// that records, so outside a call it holds a capture lease (`.voiceChat`,
/// the mode Mic Mode applies to) while it is up, and lets it go when it
/// closes. During a call the call's session already records.
@MainActor
final class VoiceInputPicker: NSObject, ObservableObject {
    private var interaction: AnyObject?
    private var lease: VoiceAudioLease?
    /// The preferred input when the picker opened: a dismissal that leaves
    /// it as it was picked nothing.
    private var preferredInputAtPresent: String?
    private let coordinator: VoiceAudioSessionCoordinator

    init(coordinator: VoiceAudioSessionCoordinator = .shared) {
        self.coordinator = coordinator
    }

    /// iOS 26 has the in-app picker. Before it, `present()` opens Control
    /// Center's Mic Mode, which iOS offers only while a call records.
    static var hasInputPicker: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    fileprivate func attach(to view: UIView) {
        guard interaction == nil else { return }
        if #available(iOS 26.0, *) {
            let picker = AVInputPickerInteraction()
            picker.delegate = self
            view.addInteraction(picker)
            interaction = picker
        }
    }

    func present() {
        guard #available(iOS 26.0, *), let picker = interaction as? AVInputPickerInteraction else {
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
            return
        }
        guard !picker.isPresented else { return }
        if !coordinator.hasCaptureOwner, lease == nil {
            do {
                lease = try coordinator.acquire(.conversationCapture)
            } catch {
                devicePickerLogger.error("input picker could not take the session: \(LogRedaction.describing(error), privacy: .public)")
                return
            }
        }
        preferredInputAtPresent = AVAudioSession.sharedInstance().preferredInput?.uid
        picker.present()
    }

    /// Lets the session go when the picker closes, or the screen holding it does.
    func releaseSession() {
        guard let lease else { return }
        self.lease = nil
        coordinator.release(lease)
    }
}

@available(iOS 26.0, *)
extension VoiceInputPicker: AVInputPickerInteraction.Delegate {
    nonisolated func inputPickerInteractionWillBeginPresenting(_ interaction: AVInputPickerInteraction) {}
    nonisolated func inputPickerInteractionDidEndPresenting(_ interaction: AVInputPickerInteraction) {}
    nonisolated func inputPickerInteractionWillBeginDismissing(_ interaction: AVInputPickerInteraction) {}
    nonisolated func inputPickerInteractionDidEndDismissing(_ interaction: AVInputPickerInteraction) {
        MainActor.assumeIsolated {
            // Closing the picker without a change keeps the fallback's
            // restore; re-picking the input already preferred reads the
            // same, and the restore wins that rarer case.
            if AVAudioSession.sharedInstance().preferredInput?.uid != preferredInputAtPresent {
                VoiceBuiltInMicrophoneFallback.userPickedInput()
            }
            releaseSession()
            // Without a lease of its own the session stays; the names
            // still change with the pick.
            VoiceAudioRouteNames.shared.refresh()
        }
    }
}

/// The view the input picker's interaction hangs on.
private struct VoiceInputPickerAnchor: UIViewRepresentable {
    let picker: VoiceInputPicker

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        picker.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// iOS's route picker with its own glyph hidden: the label under it shows,
/// and a tap anywhere on it opens the system's list of outputs. VoiceOver
/// reaches the picker's own button, which reads as Output and the device.
private struct VoiceOutputPickerOverlay: UIViewRepresentable {
    let device: String?

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .clear
        view.activeTintColor = .clear
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        for case let button as UIButton in uiView.subviews {
            button.accessibilityLabel = AppLocalization.string("Output")
            button.accessibilityValue = device
            button.accessibilityHint = AppLocalization.string("Chooses where the voice plays", table: .voice)
        }
    }
}

/// A call header's two buttons: the microphone (and its Mic Mode) and the
/// output, each naming the device on now.
struct VoiceCallAudioDeviceButtons: View {
    @ObservedObject private var names = VoiceAudioRouteNames.shared
    @StateObject private var picker = VoiceInputPicker()

    var body: some View {
        if VoiceAudioRouteNames.isAvailable {
            HStack(spacing: 8) {
                Button { picker.present() } label: {
                    capsule(symbol: "mic.fill", name: names.input)
                }
                .buttonStyle(.plain)
                .background(VoiceInputPickerAnchor(picker: picker))
                .accessibilityLabel(Text(AppLocalization.string("Microphone", table: .voice)))
                .accessibilityValue(Text(verbatim: names.input ?? ""))
                .accessibilityHint(Text(AppLocalization.string("Chooses the microphone and its Mic Mode", table: .voice)))

                capsule(symbol: "speaker.wave.2.fill", name: names.output)
                    .accessibilityHidden(true)
                    .overlay(VoiceOutputPickerOverlay(device: names.output))
            }
            .onAppear { names.refresh() }
            .onDisappear { picker.releaseSession() }
        }
    }

    private func capsule(symbol: String, name: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .scaledFont(.caption2.weight(.bold))
                .accessibilityHidden(true)
            if let name, !name.isEmpty {
                Text(verbatim: name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .scaledFont(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 160)
        .conduitGlassControl(cornerRadius: 14)
        // A 44 pt tap target without moving the header.
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .padding(.vertical, -6)
    }
}

/// Settings > Voice > Microphone and output.
struct VoiceAudioDeviceSettingsSection: View {
    @ObservedObject private var names = VoiceAudioRouteNames.shared
    @StateObject private var picker = VoiceInputPicker()

    var body: some View {
        if VoiceAudioRouteNames.isAvailable {
            ConduitSettingsSection(title: AppLocalization.string("Microphone and output", table: .voice), symbol: "headphones", tint: .conduitAccent) {
                if VoiceInputPicker.hasInputPicker {
                    Button { picker.present() } label: {
                        row(title: AppLocalization.string("Microphone", table: .voice), value: names.input)
                    }
                    .buttonStyle(.plain)
                    .background(VoiceInputPickerAnchor(picker: picker))
                    .accessibilityHint(Text(AppLocalization.string("Chooses the microphone and its Mic Mode", table: .voice)))
                    .accessibilityIdentifier("voice.audioDevices.microphone")
                    caption(AppLocalization.string("Choose the microphone calls use and its Mic Mode, such as Voice Isolation to keep the room's sound out or Wide Spectrum to pick up everyone nearby. iOS remembers your choice for Conduit's calls.", table: .voice))
                } else {
                    caption(AppLocalization.string("Mic Mode, such as Voice Isolation to keep the room's sound out, is in Control Center during a call. On iOS 26 and later you can choose the microphone and its Mic Mode here.", table: .voice))
                }
                row(title: AppLocalization.string("Output"), value: names.output)
                    .accessibilityHidden(true)
                    .overlay(VoiceOutputPickerOverlay(device: names.output))
                    .accessibilityIdentifier("voice.audioDevices.output")
                caption(AppLocalization.string("Calls play on the headset, AirPods or car that's connected, otherwise on the speaker; calls from Hermes start on the earpiece, like a phone call. Both pickers are on the call screen too.", table: .voice))
                caption(AppLocalization.string("There is no level to set for when the microphone opens. Classic voice listens for your voice above the room's noise and adjusts as the room changes; in the live modes the provider decides when you start and stop speaking.", table: .voice))
            }
            .onAppear { names.refresh() }
            .onDisappear { picker.releaseSession() }
        }
    }

    private func row(title: String, value: String?) -> some View {
        HStack {
            Text(verbatim: title)
            Spacer(minLength: 12)
            if let value, !value.isEmpty {
                Text(verbatim: value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.up.chevron.down")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
    }
}
