//
//  DashboardCodeScanner.swift
//  Conduit
//
//  Scan Code on the address step: the camera reads a sign-in code Hermes
//  showed as a QR code, or a dashboard address shown as text (a tap picks
//  it). Under the camera, the prompt that asks Hermes for a code.
//  Settings > Multiplayer's Scan reads a Link invite's QR code with the same
//  sheet (CodeScanPurpose.linkInvite).
//

import AVFoundation
import os
import SwiftUI
import Vision
import VisionKit

/// What the scanner sheet looks for, and the words around the camera.
struct CodeScanPurpose {
    let title: String
    let hint: String
    let unreadable: String
    let unsupported: String
    /// Under the camera, the prompt that asks Hermes for a sign-in code.
    let asksHermesForCode: Bool

    /// A dashboard's sign-in code, or its address shown as text.
    static var signIn: CodeScanPurpose {
        CodeScanPurpose(
            title: AppLocalization.string("Scan Code", table: .connection),
            hint: AppLocalization.string("Point the camera at the code Hermes shows. For an address shown as text, tap it.", table: .connection),
            unreadable: AppLocalization.string("That code isn't a dashboard address.", table: .connection),
            unsupported: AppLocalization.string("This device can't scan codes. Type or paste the address instead.", table: .connection),
            asksHermesForCode: true
        )
    }

    /// A Link invite's QR code, on the other person's phone.
    static var linkInvite: CodeScanPurpose {
        CodeScanPurpose(
            title: AppLocalization.string("Scan Invite", table: .connection),
            hint: AppLocalization.string("Point the camera at the invite's QR code on the other person's phone.", table: .connection),
            unreadable: AppLocalization.string("That code isn't a Link invite.", table: .connection),
            unsupported: AppLocalization.string("This device can't scan codes. Paste the invite instead.", table: .connection),
            asksHermesForCode: false
        )
    }
}

struct DashboardCodeScannerSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss
    var purpose: CodeScanPurpose = .signIn
    /// Takes what was read; false keeps the camera looking.
    let onScan: (String) -> Bool

    @State private var access: CameraAccess = .checking
    @State private var showsUnreadable = false
    @State private var unreadableCount = 0

    enum CameraAccess {
        case checking
        case allowed
        case denied
        /// No camera, or a phone without the scanner (the simulator).
        case unsupported
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(spacing: 16) {
                        camera
                        Text(verbatim: purpose.hint)
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                        if purpose.asksHermesForCode {
                            AskHermesPromptView(
                                title: ConnectionSetupPrompt.signInCode.title,
                                prompt: ConnectionSetupPrompt.signInCode.text
                            )
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(Text(verbatim: purpose.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                        .accessibilityIdentifier("scan.cancel")
                }
            }
        }
        .task { await checkAccess() }
        .task(id: unreadableCount) {
            guard unreadableCount > 0 else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            showsUnreadable = false
        }
    }

    @ViewBuilder
    private var camera: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.85))
            switch access {
            case .checking:
                ProgressView()
                    .tint(.white)
            case .allowed:
                DashboardCodeScanner { text in
                    if onScan(text) { return }
                    showsUnreadable = true
                    unreadableCount += 1
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: purpose.unreadable
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityLabel(purpose.title)
                .accessibilityHint(purpose.hint)
            case .denied:
                cameraNotice(
                    AppLocalization.string("Scanning a code needs camera access. You can allow it in Settings.", table: .connection),
                    opensSettings: true
                )
            case .unsupported:
                cameraNotice(purpose.unsupported, opensSettings: false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .overlay(alignment: .bottom) {
            if showsUnreadable {
                Text(verbatim: purpose.unreadable)
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsUnreadable)
    }

    private func cameraNotice(_ text: String, opensSettings: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera")
                .scaledFont(.title2)
                .foregroundStyle(Color.white.opacity(0.8))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .scaledFont(.callout)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if opensSettings {
                Button(AppLocalization.string("Open Settings")) {
                    SystemSettings.open(.camera)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(.conduitAccent)
            }
        }
        .padding(24)
    }

    /// Asks for the camera first when it hasn't been decided, so the
    /// scanner never opens on a black screen.
    private func checkAccess() async {
        guard DataScannerViewController.isSupported else {
            access = .unsupported
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = DataScannerViewController.isAvailable ? .allowed : .denied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            access = granted && DataScannerViewController.isAvailable ? .allowed : .denied
        default:
            access = .denied
        }
    }
}

/// VisionKit's live scanner: a QR code is taken as soon as it is seen; a
/// URL in text waits for a tap, so a half-read line is never used.
struct DashboardCodeScanner: UIViewControllerRepresentable {
    private static let logger = Logger(subsystem: "com.milim.relay", category: "login")
    let onRead: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr]), .text(textContentType: .URL)],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onRead = onRead
        if !scanner.isScanning {
            do {
                try scanner.startScanning()
            } catch {
                // The sheet checked the camera first, so this is rare; the
                // next update tries again.
                Self.logger.error("Code scanner didn't start: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onRead: onRead)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onRead: (String) -> Void
        /// The code read last: a code stays in view for many frames.
        private var lastRead: String?

        init(onRead: @escaping (String) -> Void) {
            self.onRead = onRead
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue {
                    read(payload)
                    return
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            switch item {
            case .barcode(let code):
                if let payload = code.payloadStringValue { read(payload, again: true) }
            case .text(let text):
                read(text.transcript, again: true)
            @unknown default:
                break
            }
        }

        private func read(_ payload: String, again: Bool = false) {
            guard again || payload != lastRead else { return }
            lastRead = payload
            onRead(payload)
        }
    }
}
