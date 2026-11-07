//
//  ServerCertificateSection.swift
//  Conduit
//
//  "Install this certificate" on the HTTPS & certificates page: reads the
//  certificate the dashboard presents and, when only its root is untrusted,
//  saves that root as a profile for the user to install and trust in
//  Settings (ServerCertificateProfile). Conduit itself never accepts it.
//

import SwiftUI

struct ServerCertificateSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    /// The dashboard address the page was opened for.
    let address: String

    private enum Phase: Equatable {
        case idle
        case checking
        case done(ServerCertificateCheck)
    }

    @State private var phase: Phase = .idle
    @State private var profileURL: URL?
    @State private var profileFailed = false
    @State private var checkTask: Task<Void, Never>?

    private var url: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    var body: some View {
        if let url {
            VStack(alignment: .leading, spacing: 14) {
                Text("Install this server’s certificate")
                    .scaledFont(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("If your dashboard uses its own certificate authority or a self-signed certificate, Conduit can save it as a profile for you to install and trust in Settings.")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content(for: url)
            }
            .onChange(of: address) { _, _ in reset() }
            .onDisappear { checkTask?.cancel() }
        }
    }

    @ViewBuilder
    private func content(for url: URL) -> some View {
        switch phase {
        case .idle:
            LoginPrimaryButton(title: AppLocalization.string("Check this server’s certificate")) { start(url) }
                .accessibilityIdentifier("setup.certificate-check")
        case .checking:
            LoginPrimaryButton(title: AppLocalization.string("Checking the certificate…"), isBusy: true) {}
                .disabled(true)
        case .done(let check):
            result(check, url: url)
        }
    }

    @ViewBuilder
    private func result(_ check: ServerCertificateCheck, url: URL) -> some View {
        switch check {
        case .alreadyTrusted:
            ConnectionSetupNote(symbol: "checkmark.seal", text: AppLocalization.string("iOS already trusts this server’s certificate, so certificates aren’t what’s stopping Conduit."))
            checkAgain(url)
        case .installable(let certificate):
            installable(certificate, url: url)
        case .rootNotSent:
            ConnectionSetupNote(symbol: "exclamationmark.triangle", text: AppLocalization.string("The server doesn’t send its certificate authority’s root, so Conduit can’t save it. Install the root certificate from wherever you made your certificates, then turn on full trust for it."))
            checkAgain(url)
        case .notFixedByInstalling(let failure), .unreachable(let failure):
            ConnectionSetupPanel(spacing: 6) {
                Text(verbatim: failure.userTitle)
                    .scaledFont(.subheadline.weight(.semibold))
                Text(verbatim: failure.userMessage)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            checkAgain(url)
        }
    }

    @ViewBuilder
    private func installable(_ certificate: ServerCertificate, url: URL) -> some View {
        let host = url.host ?? address
        ConnectionSetupPanel(spacing: 8) {
            Text(verbatim: certificate.subject.isEmpty ? host : certificate.subject)
                .scaledFont(.subheadline.weight(.semibold))
            Text("SHA-256 fingerprint")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: certificate.sha256Fingerprint)
                .scaledFont(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup.certificate-fingerprint")
        }
        ConnectionSetupNote(symbol: "lock.shield", text: AppLocalization.string("Only install it if this fingerprint matches the one your server reports for this certificate. Anyone between you and the server could present a different one."))
        AskHermesPromptView(
            title: ConnectionSetupPrompt.certificateFingerprint.title,
            prompt: ConnectionSetupPrompt.certificateFingerprint.text
        )
        if let profileURL {
            ShareLink(item: profileURL) {
                Label("Save Certificate Profile", systemImage: "square.and.arrow.down")
                    .scaledFont(.headline)
                    .foregroundStyle(Color.conduitAccent)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .overlay(Capsule().strokeBorder(Color.conduitAccent, lineWidth: 1.5))
                    .contentShape(Capsule())
            }
            .accessibilityIdentifier("setup.certificate-save")
            ConnectionSetupPanel(spacing: 10) {
                ForEach(Array(Self.installSteps.enumerated()), id: \.offset) { index, step in
                    ConnectionSetupListItem(marker: .number(index + 1), text: step)
                }
            }
        } else if profileFailed {
            ConnectionSetupNote(symbol: "exclamationmark.triangle", text: AppLocalization.string("Conduit couldn’t save the profile. Try again."))
            checkAgain(url)
        }
    }

    private func checkAgain(_ url: URL) -> some View {
        Button {
            Haptics.selection()
            start(url)
        } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
                .scaledFont(.callout.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    /// iOS installs a profile from Files and trusts its root only once
    /// turned on in Certificate Trust Settings; a Mac trusts a root its
    /// profile installs.
    static var installSteps: [String] {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            return [
                AppLocalization.string("Save the profile, then open it in Finder."),
                AppLocalization.string("Install it in System Settings → General → Device Management."),
                AppLocalization.string("Come back here and connect again.")
            ]
        }
        return [
            AppLocalization.string("Save the profile to Files, then open it in the Files app."),
            AppLocalization.string("Install it in Settings → General → VPN & Device Management."),
            AppLocalization.string("Turn on full trust for it in Settings → General → About → Certificate Trust Settings."),
            AppLocalization.string("Come back here and connect again.")
        ]
    }

    private func start(_ url: URL) {
        checkTask?.cancel()
        phase = .checking
        profileURL = nil
        profileFailed = false
        checkTask = Task {
            let check = await ServerCertificateInspector.check(url)
            guard !Task.isCancelled else { return }
            if case .installable(let certificate) = check {
                do {
                    profileURL = try ServerCertificateProfile.write(certificate, host: url.host ?? address)
                } catch {
                    profileFailed = true
                }
            }
            phase = .done(check)
        }
    }

    private func reset() {
        checkTask?.cancel()
        phase = .idle
        profileURL = nil
        profileFailed = false
    }
}
