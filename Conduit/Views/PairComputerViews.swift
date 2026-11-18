//
//  PairComputerViews.swift
//  Conduit
//
//  Pair a Computer (Settings > Connection, or the Camera reading a
//  computer's code): scan the QR code the Conduit desktop app shows, pick
//  the sign-ins to send, confirm it's you, and send them sealed to that
//  computer. Then both screens show the same four words, and the person
//  clicks They match on the computer (ComputerPairing.swift).
//

import SwiftUI

extension CodeScanPurpose {
    /// A computer's pairing code, on the Conduit desktop app.
    static var pairComputer: CodeScanPurpose {
        CodeScanPurpose(
            title: AppLocalization.string("Pair a Computer", table: .connection),
            hint: AppLocalization.string("Point the camera at the code Conduit shows on your computer.", table: .connection),
            unreadable: AppLocalization.string("That code isn't a Conduit pairing code.", table: .connection),
            unsupported: AppLocalization.string("This device can't scan codes.", table: .connection),
            asksHermesForCode: false
        )
    }
}

enum PairComputerText {
    static var title: String { AppLocalization.string("Pair a Computer", table: .connection) }

    static var intro: String {
        AppLocalization.string("Sign in to Conduit on your Windows PC or Mac without typing anything. Open Conduit there, choose Pair with your iPhone, and scan the code it shows.", table: .connection)
    }

    static func failure(_ error: Error) -> String {
        switch error as? ComputerPairing.SendError {
        case .codeGone:
            return AppLocalization.string("This code was replaced or ran out. Make a new one on the computer and scan it again.", table: .connection)
        case .rateLimited:
            return AppLocalization.string("Too many tries. Wait a minute and try again.", table: .connection)
        case .unreachable, nil:
            return AppLocalization.string("Couldn't reach the pairing service. Check your connection and try again.", table: .connection)
        }
    }
}

@MainActor
struct PairComputerSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var link: ComputerPairingLink?
    @State private var scanning = false
    @State private var choices: [ComputerPairingChoice] = []
    @State private var chosen: Set<UUID> = []
    @State private var sending = false
    @State private var words: [String]?
    @State private var failure: String?

    init(link: ComputerPairingLink? = nil) {
        _link = State(initialValue: link)
    }

    var body: some View {
        NavigationStack {
            SettingsDetailContainer {
                content
            }
            .navigationTitle(Text(AppLocalization.string("Pair a Computer", table: .connection)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(words == nil ? AppLocalization.string("Cancel") : AppLocalization.string("Done")) { dismiss() }
                        .disabled(sending)
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .onAppear(perform: loadChoices)
        .sheet(isPresented: $scanning) {
            DashboardCodeScannerSheet(purpose: .pairComputer) { text in
                guard let scanned = ComputerPairingLink(text) else { return false }
                link = scanned
                failure = nil
                words = nil
                scanning = false
                return true
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let words {
            ConduitSettingsSection(title: AppLocalization.string("Check the words", table: .connection), symbol: "checkmark.shield", tint: .conduitAccent) {
                Text(verbatim: PeopleSettingsText.words(words))
                    .scaledFont(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("pairComputer.words")
                Text(AppLocalization.string("Your computer should show these same four words. If it does, click They match there. If it doesn't, click They don't match.", table: .connection))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let link, !link.hasExpired() {
            review
        } else {
            ConduitSettingsSection(title: AppLocalization.string("Pair a Computer", table: .connection), symbol: "desktopcomputer", tint: .conduitAura) {
                Text(verbatim: PairComputerText.intro)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if link?.hasExpired() == true {
                    Label(AppLocalization.string("This code ran out. Make a new one on the computer and scan it again.", table: .connection), systemImage: "clock.badge.exclamationmark")
                        .scaledFont(.subheadline)
                        .foregroundStyle(.orange)
                }
                Button { scanning = true } label: {
                    Label(AppLocalization.string("Scan Code", table: .connection), systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.settingsPrimary)
                .accessibilityIdentifier("pairComputer.scan")
            }
        }
    }

    @ViewBuilder
    private var review: some View {
        ConduitSettingsSection(title: AppLocalization.string("Sign-ins to send", table: .connection), symbol: "key.horizontal", tint: .conduitAccent) {
            if choices.allSatisfy({ $0.host == nil }) {
                Text(AppLocalization.string("Nothing here can be sent: sign in on the computer instead.", table: .connection))
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(choices) { choice in
                if choice.host != nil {
                    Toggle(isOn: Binding(
                        get: { chosen.contains(choice.id) },
                        set: { on in if on { chosen.insert(choice.id) } else { chosen.remove(choice.id) } }
                    )) {
                        choiceLabel(choice)
                    }
                    .disabled(sending)
                } else {
                    choiceLabel(choice)
                }
            }
            Text(AppLocalization.string("Your phone seals these to that computer before they leave, so nobody in between can read them.", table: .connection))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .scaledFont(.subheadline)
                .foregroundStyle(.orange)
        }
        Button { Task { await send() } } label: {
            HStack(spacing: 8) {
                if sending { ProgressView() }
                Text(AppLocalization.string("Send Sign-ins", table: .connection))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.settingsPrimary)
        .disabled(sending || chosenHosts.isEmpty)
        .accessibilityIdentifier("pairComputer.send")
    }

    private func choiceLabel(_ choice: ComputerPairingChoice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: choice.label)
                .scaledFont(.body)
            Text(verbatim: kindText(choice))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func kindText(_ choice: ComputerPairingChoice) -> String {
        switch choice.host?.method {
        case .password: return AppLocalization.string("Saved password", table: .connection)
        case .token: return AppLocalization.string("Session token", table: .connection)
        case nil: return AppLocalization.string("Sign in on the computer", table: .connection)
        }
    }

    private var chosenHosts: [ComputerPairing.Host] {
        choices.filter { chosen.contains($0.id) }.compactMap(\.host)
    }

    private func loadChoices() {
        guard choices.isEmpty else { return }
        choices = appState.computerPairingChoices()
        // The dashboard in use goes by default; the others wait for a tap.
        chosen = Set(choices.filter { $0.isActive && $0.host != nil }.map(\.id))
        if chosen.isEmpty, let first = choices.first(where: { $0.host != nil }) { chosen = [first.id] }
    }

    private func send() async {
        guard let link, !sending else { return }
        guard !link.hasExpired() else {
            failure = AppLocalization.string("This code ran out. Make a new one on the computer and scan it again.", table: .connection)
            return
        }
        let hosts = chosenHosts
        guard !hosts.isEmpty else { return }
        sending = true
        defer { sending = false }
        failure = nil
        // Sign-ins leave the phone only for its owner.
        guard await BiometricAuth.authenticateIfAvailable(reason: AppLocalization.string("Confirm it's you to send your sign-ins.", table: .connection)) else { return }
        do {
            let sealed = try ComputerPairing.seal(ComputerPairing.payload(hosts), to: link.key, inbox: link.inbox)
            try await ComputerPairing.send(sealed.envelope, link: link)
            Haptics.success()
            words = ComputerPairing.words(computerKey: link.key, ephemeralPublic: sealed.ephemeralPublic)
        } catch {
            failure = PairComputerText.failure(error)
        }
    }
}
