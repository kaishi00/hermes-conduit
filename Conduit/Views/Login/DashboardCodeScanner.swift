//
//  DashboardCodeScanner.swift
//  Conduit
//
//  Scan Code on the address step: the camera reads a sign-in code Hermes
//  showed as a QR code, or a dashboard address shown as text (a tap picks
//  it). Under the camera, the prompt that asks Hermes for a code.
//

import AVFoundation
import os
import SwiftUI
import Vision
import VisionKit

struct DashboardCodeScannerSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss
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
                        Text("Point the camera at the code Hermes shows. For an address shown as text, tap it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                        AskHermesPromptView(
                            title: ConnectionSetupPrompt.signInCode.title,
                            prompt: ConnectionSetupPrompt.signInCode.text
                        )
                    }
                    .padding(16)
                }
            }
            .navigationTitle(Text("Scan Code"))
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
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityLabel(AppLocalization.string("Camera"))
            case .denied:
                cameraNotice(
                    AppLocalization.string("Scanning a code needs camera access. You can allow it in Settings."),
                    opensSettings: true
                )
            case .unsupported:
                cameraNotice(AppLocalization.string("This device can't scan codes. Type or paste the address instead."), opensSettings: false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .overlay(alignment: .bottom) {
            if showsUnreadable {
                Text("That code isn't a dashboard address.")
                    .font(.footnote.weight(.semibold))
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
                .font(.title2)
                .foregroundStyle(Color.white.opacity(0.8))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if opensSettings {
                Button(AppLocalization.string("Open Settings")) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
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
