//
//  ConnectLinkSheet.swift
//  Conduit
//
//  "Sign in to <name>?" for a sign-in code (DashboardConnectLink), scanned
//  or tapped as a link. It shows which dashboard and which username, with
//  Save sign-in and Face ID, and signs in only on the tap. The code's
//  password is saved only once the sign-in works, like a typed one.
//

import SwiftUI

struct ConnectLinkSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var flow = LoginFlowModel()
    @State private var seeded = false
    let link: DashboardConnectLink
    /// Runs after the sheet closes on a sign-in.
    var onSignedIn: () -> Void = {}

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    content
                }
            }
            .navigationTitle(Text("Sign-in code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // A sign-in under way finishes or fails first, as the
                    // swipe down waits for it.
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                        .disabled(flow.isWorking)
                        .accessibilityIdentifier("connect-link.cancel")
                }
            }
            // A code without a password, or with one the dashboard refused,
            // continues on the sign-in step.
            .navigationDestination(isPresented: $flow.showsCredentials) {
                LoginCredentialsPage(flow: flow)
            }
        }
        .modifier(LoginFlowPresentations(flow: flow))
        .interactiveDismissDisabled(flow.isWorking)
        .onAppear {
            flow.attach(appState)
            flow.onSignedIn = {
                dismiss()
                onSignedIn()
            }
            flow.refreshBiometrics()
            guard !seeded else { return }
            seeded = true
            flow.apply(LoginSeed(
                address: link.address,
                username: link.username ?? "",
                password: link.password ?? "",
                cloudflare: LoginSeed.blank.cloudflare
            ))
        }
        .onChange(of: scenePhase) { _, phase in
            // Face ID may have been set up meanwhile.
            if phase == .active { flow.refreshBiometrics() }
        }
        // Cancel leaves nothing behind, as on Add a dashboard: a browser or
        // single sign-on attempt saves its dashboard before anyone signs in.
        .onDisappear { flow.discardUnfinishedDashboards() }
    }

    // MARK: What the code says

    /// The saved dashboard at the code's address, by either scheme.
    private var savedDashboard: SavedDashboard? {
        LoginAddress.candidates(link.address)
            .compactMap { try? ConnectionURLPolicy.normalizedBaseURL($0) }
            .compactMap { appState.savedDashboardRegistry.dashboard(atNormalizedURL: $0) }
            .first
    }

    private var address: String {
        savedDashboard?.normalizedURL ?? LoginAddress.bestGuess(link.address)
    }

    private var name: String {
        savedDashboard?.label ?? SavedDashboardLabel.derive(from: address)
    }

    private var isOnlyOnHermesComputer: Bool {
        LoginAddress.isOnlyOnHermesComputer(link.address)
    }

    private var signsInWithPassword: Bool {
        link.username != nil && link.password != nil
    }

    // MARK: Layout

    private var content: some View {
        VStack(spacing: 18) {
            header
            details
            if isOnlyOnHermesComputer {
                LoginFailureCard(failure: LoginFlowModel.onlyOnHermesComputerNotice, flow: flow)
            } else {
                if signsInWithPassword {
                    LoginSignInOptionsCard(flow: flow)
                }
                if let failure = flow.failure(at: .address) {
                    LoginFailureCard(failure: failure, flow: flow)
                }
                VStack(spacing: 8) {
                    LoginPrimaryButton(
                        title: flow.isWorking ? AppLocalization.string("Connecting…") : AppLocalization.string("Sign in"),
                        isBusy: flow.isWorking
                    ) {
                        Task { await flow.signInFromLink() }
                    }
                    .disabled(flow.isWorking)
                    .accessibilityIdentifier("connect-link.sign-in")
                    Text("Nothing is saved until the sign-in works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 4)
            }
        }
        .loginReadableWidth()
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.conduitAccent)
                .frame(width: 64, height: 64)
                .background(Color.conduitAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
            Text(AppLocalization.string("Sign in to \(name)?"))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Check the address before you sign in. Conduit connects only when you tap Sign in.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var details: some View {
        VStack(spacing: 0) {
            LoginRowLabel(
                icon: "server.rack",
                title: name,
                detail: LoginAddress.displayHost(address),
                status: savedDashboard == nil
                    ? LoginRowLabel.Status(text: AppLocalization.string("New dashboard"), icon: "plus.circle", tint: .conduitAccent)
                    : LoginRowLabel.Status(text: AppLocalization.string("Saved dashboard"), icon: "checkmark.circle", tint: Color.primary.opacity(0.58)),
                accessory: .hidden
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connect-link.dashboard")
            if let username = link.username {
                LoginRowLabel(
                    icon: "person",
                    title: username,
                    detail: link.password == nil
                        ? AppLocalization.string("You type the password next.")
                        : AppLocalization.string("The code includes the password."),
                    accessory: .hidden
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("connect-link.username")
                .overlay(alignment: .top) { V2RowDivider(leadingInset: 56) }
            }
        }
        .settingsCard()
    }
}
