//
//  ComputerSignInViews.swift
//  Conduit
//
//  Sign In from Your Computer: Conduit for desktop's code (Settings ›
//  Conduit on iPhone there), read by the Camera or by Scan Code on the
//  sign-in screen. Nothing is sent before Get Sign-ins; then both screens
//  show the same four words, the computer sends the dashboards picked there,
//  and each signs in here through the sign-in code sheet
//  (ComputerSignIn.swift).
//

import SwiftUI

enum ComputerSignInText {
    static var title: String { AppLocalization.string("Sign In from Your Computer", table: .connection) }

    static func failure(_ error: Error) -> String {
        switch error as? ComputerSignIn.Failure {
        case .codeGone:
            return AppLocalization.string("This code was replaced or ran out. Make a new one on the computer and scan it again.", table: .connection)
        case .rateLimited:
            return AppLocalization.string("Too many tries. Wait a minute and try again.", table: .connection)
        case .unreachable, .lost, nil:
            return AppLocalization.string("Couldn't reach the pairing service. Check your connection and try again.", table: .connection)
        }
    }
}

@MainActor
struct ComputerSignInSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let link: ComputerPairingLink
    @State private var starting = false
    @State private var words: [String]?
    @State private var hosts: [ComputerSignIn.Host] = []
    @State private var signedIn: Set<String> = []
    @State private var signingIn: DashboardConnectLink?
    @State private var signingInHost: String?
    @State private var failure: String?
    @State private var inbox: ComputerSignIn.Inbox?
    @State private var waiting: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            SettingsDetailContainer {
                content
            }
            .navigationTitle(Text(ComputerSignInText.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hosts.isEmpty ? AppLocalization.string("Cancel") : AppLocalization.string("Done")) { dismiss() }
                        .disabled(starting)
                        .accessibilityIdentifier("computerSignIn.close")
                }
            }
        }
        .interactiveDismissDisabled(starting)
        .onDisappear(perform: stop)
        .sheet(item: $signingIn) { link in
            ConnectLinkSheet(link: link) {
                if let host = signingInHost { signedIn.insert(host) }
            }
            .environmentObject(appState)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hosts.isEmpty {
            ConduitSettingsSection(title: AppLocalization.string("Dashboards from your computer", table: .connection), symbol: "desktopcomputer", tint: .conduitAccent) {
                ForEach(hosts) { host in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: host.label).scaledFont(.body)
                            Text(verbatim: URL(string: host.url)?.host ?? host.url)
                                .scaledFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if signedIn.contains(host.id) {
                            Label(AppLocalization.string("Signed in"), systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                        } else {
                            Button(AppLocalization.string("Sign in")) {
                                signingInHost = host.id
                                signingIn = host.connectLink
                            }
                            .buttonStyle(.settings)
                            .accessibilityIdentifier("computerSignIn.signIn")
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(AppLocalization.string("Each one asks before it signs in. Nothing is saved until the sign-in works.", table: .connection))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let words {
            ConduitSettingsSection(title: AppLocalization.string("Check the words", table: .connection), symbol: "checkmark.shield", tint: .conduitAccent) {
                Text(verbatim: PeopleSettingsText.words(words))
                    .scaledFont(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("computerSignIn.words")
                Text(AppLocalization.string("Your computer should show these same four words. If it does, pick the dashboards there and click They match, send.", table: .connection))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ProgressView()
                    Text(AppLocalization.string("Waiting for your computer…", table: .connection))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ConduitSettingsSection(title: ComputerSignInText.title, symbol: "desktopcomputer", tint: .conduitAura) {
                Text(AppLocalization.string("Conduit on your computer can send this phone its Hermes sign-ins, sealed to this phone so nobody in between can read them.", table: .connection))
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if link.hasExpired() {
                    Label(AppLocalization.string("This code ran out. Make a new one on the computer and scan it again.", table: .connection), systemImage: "clock.badge.exclamationmark")
                        .scaledFont(.subheadline)
                        .foregroundStyle(.orange)
                }
                Button { Task { await start() } } label: {
                    HStack(spacing: 8) {
                        if starting { ProgressView() }
                        Text(AppLocalization.string("Get Sign-ins", table: .connection))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.settingsPrimary)
                .disabled(starting || link.hasExpired())
                .accessibilityIdentifier("computerSignIn.start")
            }
        }
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .scaledFont(.subheadline)
                .foregroundStyle(.orange)
        }
    }

    private func start() async {
        guard !starting, !link.hasExpired() else { return }
        starting = true
        defer { starting = false }
        failure = nil
        let inbox = ComputerSignIn.Inbox(mailbox: link.mailbox)
        self.inbox = inbox
        do {
            words = try await ComputerSignIn.begin(inbox, link: link)
            Haptics.success()
        } catch {
            failure = ComputerSignInText.failure(error)
            await ComputerSignIn.finish(inbox)
            self.inbox = nil
            return
        }
        waiting = Task {
            do {
                let received = try await ComputerSignIn.waitForHosts(inbox)
                await ComputerSignIn.finish(inbox)
                self.inbox = nil
                // That computer runs Conduit for desktop: Chats never offers it.
                OtherAppOffer.notePairedComputer()
                Haptics.success()
                hosts = received
            } catch is CancellationError {
                return
            } catch {
                // As a failed start: the inbox goes now, so a retry leaves none behind.
                await ComputerSignIn.finish(inbox)
                self.inbox = nil
                words = nil
                failure = ComputerSignInText.failure(error)
            }
        }
    }

    private func stop() {
        waiting?.cancel()
        waiting = nil
        if let inbox {
            self.inbox = nil
            Task { await ComputerSignIn.finish(inbox) }
        }
    }
}
