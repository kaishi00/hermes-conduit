//
//  ConnectionSetupView.swift
//  Conduit
//
//  Guided Connection Setup wizard. The routing lives in
//  ConnectionSetupFlow (unit-tested); this view renders the model's current
//  step and forwards taps as model transitions. Round 1's TLS and Cloudflare
//  quick checks remain available as direct troubleshooting surfaces, reachable
//  from failure-driven help destinations.
//
//  The assistant is strictly opt-in: it opens only from the login card's
//  entry point or a Troubleshoot Connection action, never automatically, and
//  stores no completion state.
//

import SwiftUI
import UIKit

// MARK: - Round-6 Repair sheet

/// The shared Repair-mode presentation used by every failure surface (the
/// composer banner and the login card), so seeding, the intentionally
/// unreachable login handoff, and the activation handler cannot drift
/// between them.
struct ConnectionRepairSetupSheet: View {
    let context: ConnectionRepairContext
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ConnectionSetupView(
            initialDestination: .repairConnection,
            initialDraft: context.draft,
            initialCloudflareAccess: context.cloudflareAccess,
            initialCloudflareOriginURL: context.cloudflareOriginURL,
            repairFailure: context.failure,
            onComplete: { _ in
                // Unreachable in Repair mode: the Review's final actions are
                // Reconnect Now / Sign In to Reconnect.
            },
            onRepair: appState.connectionRepairActivationHandler()
        )
    }
}

struct ConnectionSetupView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var flow: ConnectionSetupFlow
    @State private var showNotSureGuidance = false
    /// The in-flight staged-test task. Cancelled on any exit from the test
    /// screen and on dismissal; late probe events are additionally dropped
    /// by the flow's generation guard, so correctness never relies on view
    /// destruction.
    @State private var testTask: Task<Void, Never>?
    /// Sign In to Reconnect / Sign In Again while its capability check
    /// runs: cancelled when the step changes or the wizard goes away.
    @State private var repairSignInTask: Task<Void, Never>?
    @State private var repairSignInToken = UUID()
    /// Round 6 (Repair): the memory-only validated native transaction from
    /// the current successful test, bound to the revision/generation that
    /// produced it. One-shot: consumed by Reconnect Now whether activation
    /// succeeds or fails, and invalidated by edits, newer runs, and
    /// cancellation. Never logged, never persisted.
    @State private var repairCandidate: ConnectionRepairCandidate?
    @State private var isActivating = false
    @State private var activationFailure: ConnectionFailure?
    @State private var showRepairSignIn = false
    @State private var repairSignInConfiguration: ConnectionSetupResult?
    /// What Sign In to Reconnect opens; set together with the
    /// configuration right before the sheet is presented.
    @State private var repairSignIn: DashboardInteractiveSignIn?
    @State private var repairNativeOAuthDashboardID = UUID()
    private let onComplete: (ConnectionSetupResult) -> Void
    /// Round 6 (Repair): the explicit activation boundary. Nil outside
    /// Repair mode, in which case the Review shows its normal context action.
    private let onRepair: ((ConnectionRepairHandoff) async -> ConnectionRepairActivationOutcome)?
    private let prober: any ConnectionSetupTesting

    init(
        initialDestination: ConnectionHelpDestination,
        initialDraft: ConnectionSetupDraft = ConnectionSetupDraft(),
        initialCloudflareAccess: CloudflareAccessCredentials? = nil,
        initialCloudflareOriginURL: String = "",
        repairFailure: ConnectionFailure? = nil,
        onComplete: @escaping (ConnectionSetupResult) -> Void,
        onRepair: ((ConnectionRepairHandoff) async -> ConnectionRepairActivationOutcome)? = nil
    ) {
        _flow = State(initialValue: ConnectionSetupFlow(
            entry: initialDestination,
            draft: initialDraft,
            inheritedCloudflareAccess: initialCloudflareAccess,
            inheritedCloudflareOriginURL: initialCloudflareOriginURL,
            repairFailure: repairFailure
        ))
        self.onComplete = onComplete
        self.onRepair = onRepair
        self.prober = Self.makeProber()
    }

    private static func makeProber() -> any ConnectionSetupTesting {
        #if DEBUG
        if let stub = ConnectionSetupTestProbeStub.fromLaunchArguments() { return stub }
        #endif
        return ConnectionSetupProbe()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                Group {
                    switch flow.step {
                    case .connectionDetails, .loginCredentials, .connectionTest, .review:
                        ConnectionSetupForm(
                            flow: $flow,
                            onStartTest: { startTestRun() },
                            onComplete: { result in
                                onComplete(result)
                                dismiss()
                            },
                            repairReview: repairReview,
                            settingsReview: settingsReview
                        )
                    default:
                        ScrollView {
                            content
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 28)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("connection-setup.content")
                    }
                }
            }
            .onChange(of: flow.step) { _, newStep in
                // A sign-in started from this step opens nothing elsewhere.
                stopRepairSignIn()
                // Leaving the test screen for any editable step cancels the
                // probe; a success advance to Review does not.
                guard newStep != .connectionTest, newStep != .review else { return }
                stopTestRun()
            }
            .onDisappear {
                stopRepairSignIn()
                stopTestRun()
            }
            .navigationTitle("Connection Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if flow.canGoBack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            flow.back()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier("setup.back")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("connection-setup.done")
                }
            }
            .sheet(isPresented: $showRepairSignIn) {
                repairSignInSheet
            }
        }
    }

    /// The Repair review's action model, nil outside Repair mode. The
    /// candidate's currency is evaluated here — the flow's staged success
    /// must still be current at exactly the revision and generation that
    /// produced the candidate.
    private var repairReview: ConnectionSetupRepairReview? {
        guard flow.isRepairingConnection, onRepair != nil else { return nil }
        let candidateCurrent = repairCandidate?.isCurrent(
            hasCurrentSuccessfulTest: flow.hasCurrentSuccessfulTest,
            testGeneration: flow.testGeneration,
            testSucceededAtRevision: flow.testSucceededAtRevision
        ) ?? false
        return ConnectionSetupRepairReview(
            isInteractive: flow.testState.requiresInteractiveSignIn || flow.testState.requiresSignInChoice,
            offersPasswordSignIn: flow.testState.requiresSignInChoice,
            isCandidateAvailable: candidateCurrent,
            activationFailure: activationFailure,
            isActivating: isActivating,
            reconnectNow: { reconnectNow() },
            signInToReconnect: { beginRepairSignIn() },
            enterCredentials: { flow.enterCredentialsForSignInChoice() },
            testAgain: { testAgainAfterFailedActivation() }
        )
    }

    /// The Settings entry's review model, nil elsewhere. Sign In Again goes
    /// through the same explicit sign-in and activation as Repair's Sign In
    /// to Reconnect, so it needs the activation handler too.
    private var settingsReview: ConnectionSetupSettingsReview? {
        guard flow.enteredFromCurrentConnection else { return nil }
        return ConnectionSetupSettingsReview(
            isSessionConnected: appState.isConnected,
            offersSignInAgain: onRepair != nil && ConnectionSetupSettingsReview.offersSignInAgain(
                for: flow,
                activeDashboardURL: appState.connection?.baseUrl ?? appState.lastDashboardURL
            ),
            isSigningIn: isActivating,
            signInFailure: activationFailure,
            signInAgain: { beginRepairSignIn() }
        )
    }

    /// Interactive repair sign-in, pointed at the tested address with the
    /// wizard's same-origin Cloudflare state. Native-capable OAuth providers
    /// use the external-browser PKCE flow; other interactive deployments keep
    /// the existing AuthWebView. Sign-in happens only on this explicit action.
    @ViewBuilder
    private var repairSignInSheet: some View {
        if let configuration = repairSignInConfiguration, let repairSignIn {
            switch repairSignIn {
            case .nativeOAuth(let provider):
                NativeOAuthSignInSheet(
                    baseURL: configuration.serverURL,
                    cloudflareAccess: flow.cloudflareAccessForDraft(),
                    provider: provider,
                    dashboardID: repairNativeOAuthDashboardID,
                    onSuccess: { result in
                        Task { @MainActor in
                            showRepairSignIn = false
                            await activate(.nativeOAuth(
                                result: result,
                                baseURL: configuration.serverURL,
                                configuration: configuration
                            ))
                        }
                    },
                    onError: { error in
                        showRepairSignIn = false
                        activationFailure = ConnectionFailureClassifier.classify(error)
                    }
                )
            case .browser:
                AuthWebView(
                    url: configuration.serverURL,
                    cloudflareAccess: flow.cloudflareAccessForDraft(),
                    dashboardIDProvider: { [appState, url = configuration.serverURL] in
                        appState.resolveDashboardID(forURL: url, registerIfMissing: true)
                    },
                    // Repair targets are always registered dashboards: reuse
                    // their own identified WebKit store (read-only resolution —
                    // no render-time registration).
                    websiteDataStoreIdentifier: appState.resolveDashboardID(
                        forURL: configuration.serverURL,
                        registerIfMissing: false
                    ),
                    onTicket: { ticket, baseURL in
                        Task { @MainActor in
                            showRepairSignIn = false
                            await activate(.browserSignIn(
                                ticket: ticket,
                                baseURL: baseURL,
                                configuration: configuration
                            ))
                        }
                    },
                    onError: { classifiedFailure, _ in
                        showRepairSignIn = false
                        // Sign-in failure consumed no transaction: the user may
                        // retry sign-in directly, without re-testing.
                        activationFailure = classifiedFailure
                    }
                )
                .explainingPasskeys()
            }
        } else {
            // Unreachable: the sheet is only presented with a configuration
            // and a sign-in.
            Color.clear.onAppear { showRepairSignIn = false }
        }
    }

    // MARK: - Repair activation (Round 6)

    private func reconnectNow() {
        guard !isActivating,
              let candidate = repairCandidate,
              candidate.isCurrent(
                hasCurrentSuccessfulTest: flow.hasCurrentSuccessfulTest,
                testGeneration: flow.testGeneration,
                testSucceededAtRevision: flow.testSucceededAtRevision
              ),
              let onRepair else { return }
        // The candidate is one-shot: consumed here, whether activation
        // succeeds or fails. A failed activation requires a fresh test.
        repairCandidate = nil
        Task { @MainActor in
            await activate(.native(candidate))
        }
    }

    private func beginRepairSignIn() {
        guard !isActivating, flow.canUseSettings, onRepair != nil else { return }
        guard let result = flow.complete() else { return }
        // The staged test already decided the sign-in through the shared
        // resolver; a choice's browser sign-in checks native capability now
        // that it is picked. That answer counts only for the draft and test
        // it started from: an edit or a newer test while it ran opens
        // nothing.
        let request = ConnectionRepairSignInRequest(
            configuration: result,
            revision: flow.draftRevision,
            generation: flow.testGeneration
        )
        let testState = flow.testState
        let access = flow.cloudflareAccessForDraft()
        // A request goes out only for a choice's capability check.
        let resolver = DashboardSignInResolver(supportsNativeOAuth: {
            try await NativeAuthClient(baseURL: request.configuration.serverURL, cloudflareAccess: access)
                .supportsNativeOAuth()
        })
        isActivating = true
        repairSignInTask?.cancel()
        let token = UUID()
        repairSignInToken = token
        repairSignInTask = Task { @MainActor in
            // A cancelled sign-in hands the activity back at once
            // (stopRepairSignIn); only the current one ends it here.
            defer {
                if repairSignInToken == token {
                    isActivating = false
                    repairSignInTask = nil
                }
            }
            let resolved: DashboardInteractiveSignIn?
            do {
                resolved = try await ConnectionRepairSignIn.signIn(for: testState, resolver: resolver)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, request.isCurrent(in: flow) else { return }
                activationFailure = ConnectionFailureClassifier.classify(error)
                return
            }
            guard !Task.isCancelled, request.isCurrent(in: flow), let interactive = resolved else { return }
            if case .nativeOAuth = interactive {
                guard let dashboardID = appState.resolveDashboardID(
                    forURL: request.configuration.serverURL,
                    registerIfMissing: true
                ) else {
                    activationFailure = .unexpectedServerResponse
                    return
                }
                repairNativeOAuthDashboardID = dashboardID
            }
            repairSignIn = interactive
            repairSignInConfiguration = request.configuration
            showRepairSignIn = true
        }
    }

    private func testAgainAfterFailedActivation() {
        activationFailure = nil
        flow.invalidateTestForRepairRetry()
    }

    private func activate(_ handoff: ConnectionRepairHandoff) async {
        guard let onRepair else { return }
        activationFailure = nil
        isActivating = true
        let outcome = await onRepair(handoff)
        isActivating = false
        switch outcome {
        case .activated:
            UIAccessibility.post(
                notification: .announcement,
                argument: AppLocalization.string("Reconnected to Hermes.")
            )
            dismiss()
        case .failed(let failure):
            UIAccessibility.post(
                notification: .announcement,
                argument: failure.userTitle
            )
            // Stay on Review: the candidate is consumed (Reconnect Now can
            // neither re-fire nor be retried automatically), and the footer
            // renders the classified failure with Test Connection Again —
            // which invalidates the staged result only when the user asks.
            activationFailure = failure
        }
    }

    // MARK: - Staged connection test

    private func startTestRun() {
        // Credentials are optional here: provider discovery decides whether a
        // password applies, so an interactive-auth dashboard is testable
        // without typing one first. A fresh run also clears the spent
        // activation failure of any previous reconnect attempt.
        activationFailure = nil
        guard let run = try? flow.draft.testConfiguration(),
              let generation = flow.beginTest() else { return }
        let access = flow.cloudflareAccessForDraft()
        let prober = prober
        let flow = $flow
        testTask?.cancel()
        testTask = Task { @MainActor in
            let acquisition = await prober.runTest(result: run, cloudflareAccess: access, onEvent: { event in
                // Announce only events the model actually applied — dropped
                // stale events never speak.
                guard flow.wrappedValue.applyTestEvent(event, generation: generation) else { return }
                // One completion announcement per run, in the wording the
                // screen shows for this context; individual stage
                // transitions stay quiet.
                if let announcement = ConnectionSetupTestState.completionAnnouncement(
                    for: event,
                    repairing: flow.wrappedValue.isRepairingConnection
                ) {
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            })
            // Round 6 (Repair): promote the validated transaction into the
            // reconnect candidate ONLY while the flow still shows the staged
            // success this run produced — a superseded or cancelled run's
            // acquisition is dropped, exactly like its late events.
            guard let acquisition,
                  !Task.isCancelled,
                  flow.wrappedValue.hasCurrentSuccessfulTest,
                  flow.wrappedValue.testGeneration == generation else { return }
            repairCandidate = ConnectionRepairCandidate(
                configuration: acquisition.configuration,
                nativeConnection: acquisition.nativeConnection,
                validatedRevision: flow.wrappedValue.testSucceededAtRevision ?? 0,
                generation: generation
            )
        }
    }

    private func stopRepairSignIn() {
        guard let task = repairSignInTask else { return }
        task.cancel()
        repairSignInTask = nil
        repairSignInToken = UUID()
        isActivating = false
    }

    private func stopTestRun() {
        testTask?.cancel()
        testTask = nil
        // Leaving the test step resets RUNNING work. A sealed success (and
        // its candidate) survives non-editing Back/forward walks — the
        // candidate's currency is still enforced at use time — so the view
        // and the flow model never disagree about whether a test is current.
        let wasRunning = flow.testState.isRunning
        flow.cancelTest()
        if wasRunning {
            repairCandidate = nil
        }
    }

    // MARK: - Step routing

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .dashboard: dashboardStep
        case .credentials: credentialsStep
        case .accessMethod: accessMethodStep
        case .lan: lanBranch
        case .tailscale: tailscaleBranch
        case .reverseProxy: reverseProxyBranch
        case .connectionDetails, .loginCredentials, .connectionTest, .review: EmptyView()
        case .tlsTroubleshooting: troubleshootingStep(.tls)
        case .cloudflareTroubleshooting: troubleshootingStep(.cloudflare)
        }
    }

    // MARK: - Step 1: Dashboard readiness

    private var dashboardStep: some View {
        readinessQuestion(
            symbol: "server.rack",
            question: AppLocalization.string("Is your Hermes dashboard running?"),
            explanation: AppLocalization.string("Hermes Conduit connects to a Hermes dashboard you (or your assistant) run yourself. The dashboard has to be up before Conduit can reach it."),
            selectedAnswer: flow.dashboardAnswer,
            onAnswer: { flow.answerDashboard($0) },
            guidance: { dashboardGuidance }
        )
    }

    @ViewBuilder
    private var dashboardGuidance: some View {
        switch flow.dashboardAnswer {
        case .no:
            AskHermesPromptView(title: ConnectionSetupPrompt.dashboardNotRunning.title, prompt: ConnectionSetupPrompt.dashboardNotRunning.text)
            continueButton(AppLocalization.string("Dashboard is ready")) { flow.confirmDashboardReady() }
                .accessibilityIdentifier("setup.continue")
        case .unknown:
            AskHermesPromptView(title: ConnectionSetupPrompt.dashboardUnknown.title, prompt: ConnectionSetupPrompt.dashboardUnknown.text)
            continueButton(AppLocalization.string("Dashboard is ready")) { flow.confirmDashboardReady() }
                .accessibilityIdentifier("setup.continue")
        default:
            EmptyView()
        }
    }

    // MARK: - Authentication recovery: dashboard credentials

    private var credentialsStep: some View {
        readinessQuestion(
            symbol: "person.badge.key",
            question: AppLocalization.string("Do you have your Hermes dashboard login credentials?"),
            explanation: AppLocalization.string("This means the Hermes dashboard username and password you sign in with — not Tailscale, Cloudflare, or Apple credentials."),
            selectedAnswer: flow.credentialsAnswer,
            onAnswer: { flow.answerCredentials($0) },
            guidance: { credentialsGuidance }
        )
    }

    @ViewBuilder
    private var credentialsGuidance: some View {
        switch flow.credentialsAnswer {
        case .no:
            AskHermesPromptView(title: ConnectionSetupPrompt.credentialsMissing.title, prompt: ConnectionSetupPrompt.credentialsMissing.text)
            continueButton(AppLocalization.string("Credentials are ready")) { flow.confirmCredentialsReady() }
                .accessibilityIdentifier("setup.continue")
        case .unknown:
            AskHermesPromptView(title: ConnectionSetupPrompt.credentialsUnknown.title, prompt: ConnectionSetupPrompt.credentialsUnknown.text)
            continueButton(AppLocalization.string("Credentials are ready")) { flow.confirmCredentialsReady() }
                .accessibilityIdentifier("setup.continue")
        default:
            EmptyView()
        }
    }

    // MARK: - Step 2: Access method

    private var accessMethodStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            ConnectionSetupHeader(
                symbol: "point.3.connected.trianglepath.dotted",
                progress: flow.progressLabel,
                progressStep: flow.progressStep,
                title: AppLocalization.string("How will this iPhone or iPad reach Hermes?"),
                detail: AppLocalization.string("Pick how Conduit should reach your self-hosted Hermes dashboard. You can change this later.")
            )

            let existingAddress = flow.draft.existingServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !existingAddress.isEmpty {
                ConnectionSetupCard {
                    ConnectionSetupChoiceRow(
                        icon: "server.rack",
                        title: AppLocalization.string("Use or edit current dashboard address"),
                        detail: existingAddress,
                        identifier: "setup.use-existing"
                    ) {
                        flow.useExistingAddress()
                    }
                }
            }

            ConnectionSetupCard {
                ConnectionSetupChoiceRow(
                    icon: "wifi",
                    title: ConnectionAccessMethod.lan.displayTitle,
                    detail: AppLocalization.string("Use this when Conduit and the Hermes machine are on the same home or local network."),
                    identifier: "setup.method-lan"
                ) {
                    flow.selectAccessMethod(.lan)
                }
                ConnectionSetupChoiceRow(
                    icon: "lock.shield",
                    title: ConnectionAccessMethod.tailscale.displayTitle,
                    detail: AppLocalization.string("Use Tailscale when you want to reach Hermes securely while away from home."),
                    badge: AppLocalization.string("Recommended for remote access"),
                    showsDivider: true,
                    identifier: "setup.method-tailscale"
                ) {
                    flow.selectAccessMethod(.tailscale)
                }
                ConnectionSetupChoiceRow(
                    icon: "globe",
                    title: ConnectionAccessMethod.reverseProxy.displayTitle,
                    detail: AppLocalization.string("Use this if you already access Hermes through an HTTPS hostname you manage."),
                    showsDivider: true,
                    identifier: "setup.method-reverseProxy"
                ) {
                    flow.selectAccessMethod(.reverseProxy)
                }
            }

            notSureGuidance
        }
    }

    private var notSureGuidance: some View {
        ConnectionSetupCard {
            // A disclosure row is a full-width target: the help toggle must
            // not require hitting the label text.
            ConnectionSetupChoiceRow(
                icon: "questionmark.circle",
                title: AppLocalization.string("I’m not sure"),
                accessory: .disclosure(expanded: showNotSureGuidance),
                identifier: "setup.method-notsure"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showNotSureGuidance.toggle()
                }
            }

            if showNotSureGuidance {
                VStack(alignment: .leading, spacing: 12) {
                    ConnectionSetupListItem(marker: .bullet, text: AppLocalization.string("Using Conduit at home, on the same network as the Hermes machine? Choose “I’m on the same network as Hermes”."))
                    ConnectionSetupListItem(marker: .bullet, text: AppLocalization.string("Need access away from home without existing remote access? Choose Tailscale — the simplest secure option."))
                    ConnectionSetupListItem(marker: .bullet, text: AppLocalization.string("Already operating an HTTPS domain or reverse proxy for Hermes? Choose “I already have a domain or reverse proxy”."))
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .overlay(alignment: .top) { V2RowDivider(leadingInset: 16) }
                .transition(.opacity)
            }
        }
    }

    // MARK: - LAN branch

    private var lanBranch: some View {
        branchShell(
            symbol: "wifi",
            title: AppLocalization.string("Same network as Hermes"),
            intro: AppLocalization.string("Here is what you will need to connect Conduit over your local network:"),
            prompt: .lanDetails
        ) {
            ConnectionSetupPanel {
                ConnectionSetupListItem(marker: .check, text: AppLocalization.string("The Hermes dashboard is running."))
                ConnectionSetupListItem(marker: .check, text: AppLocalization.string("You can sign in to the Hermes dashboard."))
                ConnectionSetupListItem(marker: .check, text: AppLocalization.string("You know the Hermes machine’s local IP address."))
                ConnectionSetupListItem(marker: .check, text: AppLocalization.string("You know the dashboard port."))
                ConnectionSetupListItem(marker: .check, text: AppLocalization.string("This device is on the same reachable network."))
            }
        }
    }

    // MARK: - Tailscale branch

    private var tailscaleBranch: some View {
        branchShell(
            symbol: "lock.shield",
            title: AppLocalization.string("Reach Hermes with Tailscale"),
            intro: AppLocalization.string("Tailscale gives you secure access from anywhere, including the recommended Tailscale Serve path:"),
            prompt: .tailscaleServe
        ) {
            ConnectionSetupPanel {
                ConnectionSetupListItem(marker: .number(1), text: AppLocalization.string("Tailscale is installed on the Hermes machine."))
                ConnectionSetupListItem(marker: .number(2), text: AppLocalization.string("Tailscale is installed on this iPhone or iPad."))
                ConnectionSetupListItem(marker: .number(3), text: AppLocalization.string("Both are signed in to the same tailnet."))
                ConnectionSetupListItem(marker: .number(4), text: AppLocalization.string("The Hermes dashboard is running."))
                ConnectionSetupListItem(marker: .number(5), text: AppLocalization.string("Hermes configures Tailscale Serve for the dashboard."))
                ConnectionSetupListItem(marker: .number(6), text: AppLocalization.string("Hermes tells you the address to enter into Conduit."))
            }
            ConnectionSetupNote(
                symbol: "hand.raised",
                text: AppLocalization.string("Conduit never installs or configures Tailscale, and it doesn’t assume an address or port — Hermes tells you what to use.")
            )
        }
    }

    // MARK: - Reverse-proxy branch

    private var reverseProxyBranch: some View {
        branchShell(
            symbol: "globe",
            title: AppLocalization.string("Use your existing HTTPS domain"),
            intro: AppLocalization.string("This branch is only for HTTPS infrastructure you already operate — Conduit does not guide you through creating one."),
            prompt: .reverseProxyDetails
        ) {
            ConnectionSetupPanel {
                Text("You will need:")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ConnectionSetupListItem(marker: .bullet, text: AppLocalization.string("Your existing HTTPS Hermes dashboard URL — for example https://hermes.example.com, https://hermes.example.com:9443, or https://example.com/hermes."))
                ConnectionSetupListItem(marker: .bullet, text: AppLocalization.string("Any custom port."))
                ConnectionSetupListItem(marker: .bullet, text: AppLocalization.string("Any path prefix your proxy uses."))
                ConnectionSetupListItem(marker: .bullet, text: AppLocalization.string("A way to sign in to the dashboard."))
            }
            ConnectionSetupNote(
                symbol: "lock.shield",
                text: AppLocalization.string("Conduit will not ask you to expose a raw public port, create firewall rules, or bypass certificate checks.")
            )
        }
    }

    // MARK: - Troubleshooting surfaces (Round-1 content retained)

    private func troubleshootingStep(_ topic: ConnectionHelpDestination) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Topic", selection: topicBinding) {
                Text(ConnectionHelpDestination.tls.displayName).tag(ConnectionHelpDestination.tls)
                Text(ConnectionHelpDestination.cloudflare.displayName).tag(ConnectionHelpDestination.cloudflare)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("setup.troubleshooting-picker")

            ConnectionSetupHeader(
                symbol: topic == .tls ? "lock.shield" : "cloud",
                title: topic.displayName,
                detail: topic == .tls
                    ? AppLocalization.string("Checks for HTTPS and certificate problems when connecting to your dashboard.")
                    : AppLocalization.string("Checks for Cloudflare Access service-token problems when connecting to your dashboard.")
            )

            ConnectionSetupPanel(spacing: 14) {
                ForEach(Array(topic.checks.enumerated()), id: \.offset) { _, check in
                    ConnectionSetupListItem(marker: .check, text: check)
                }
            }
        }
    }

    private var topicBinding: Binding<ConnectionHelpDestination> {
        Binding(
            get: { flow.step == .cloudflareTroubleshooting ? .cloudflare : .tls },
            set: { flow.showTroubleshooting($0) }
        )
    }

    // MARK: - Reusable pieces

    private func readinessQuestion(
        symbol: String,
        question: String,
        explanation: String,
        selectedAnswer: ConnectionSetupAnswer?,
        onAnswer: @escaping (ConnectionSetupAnswer) -> Void,
        @ViewBuilder guidance: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ConnectionSetupHeader(
                symbol: symbol,
                progress: flow.progressLabel,
                progressStep: flow.progressStep,
                title: question,
                detail: explanation
            )

            ConnectionSetupCard {
                ConnectionSetupChoiceRow(
                    title: AppLocalization.string("Yes"),
                    accessory: .checkmark(selected: selectedAnswer == .yes),
                    identifier: "setup.answer-yes"
                ) {
                    onAnswer(.yes)
                }
                ConnectionSetupChoiceRow(
                    title: AppLocalization.string("No"),
                    accessory: .checkmark(selected: selectedAnswer == .no),
                    showsDivider: true,
                    identifier: "setup.answer-no"
                ) {
                    onAnswer(.no)
                }
                ConnectionSetupChoiceRow(
                    title: AppLocalization.string("I don’t know"),
                    accessory: .checkmark(selected: selectedAnswer == .unknown),
                    showsDivider: true,
                    identifier: "setup.answer-unknown"
                ) {
                    onAnswer(.unknown)
                }
            }

            guidance()
        }
    }

    private func branchShell<Needs: View>(
        symbol: String,
        title: String,
        intro: String,
        prompt: ConnectionSetupPrompt,
        @ViewBuilder needs: () -> Needs
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ConnectionSetupHeader(symbol: symbol, title: title, detail: intro)
            needs()
            AskHermesPromptView(title: prompt.title, prompt: prompt.text)
            continueButton(AppLocalization.string("I have the connection details")) { flow.confirmDetailsReady() }
                .accessibilityIdentifier("setup.details-ready")
        }
    }

    private func continueButton(_ label: String, action: @escaping () -> Void) -> some View {
        LoginPrimaryButton(title: label, action: action)
    }
}

// MARK: - Round-1 troubleshooting content (retained)

extension ConnectionHelpDestination {
    var displayName: String {
        switch self {
        case .start: return AppLocalization.string("Getting started")
        case .dashboard: return AppLocalization.string("Dashboard address")
        case .credentials: return AppLocalization.string("Credentials")
        case .network: return AppLocalization.string("Network & reachability")
        case .tls: return AppLocalization.string("HTTPS & certificates")
        case .cloudflare: return "Cloudflare Access"
        case .currentConnection: return AppLocalization.string("Current connection")
        case .repairConnection: return AppLocalization.string("Repair connection")
        }
    }

    /// Static quick checks shown on the troubleshooting surfaces. Only the
    /// TLS and Cloudflare topics are reachable (they are the direct
    /// troubleshooting entries); the other destinations route to wizard
    /// questions, so they carry no checks. Safe by construction: never
    /// recommends exposing the dashboard to the public internet or weakening
    /// HTTPS.
    var checks: [String] {
        switch self {
        case .tls:
            return [
                AppLocalization.string("If you use your own certificate authority, install its profile on this device (Settings → General → VPN & Device Management), then turn on full trust for its root certificate (Settings → General → About → Certificate Trust Settings)."),
                AppLocalization.string("Check the server certificate’s expiration and validity dates."),
                AppLocalization.string("Confirm this device’s date and time are correct.")
            ]
        case .cloudflare:
            return [
                AppLocalization.string("Verify the Client ID and Secret belong to a Cloudflare Access service token for this application."),
                AppLocalization.string("Make sure a Service Auth policy allows that token to reach this Access application."),
                AppLocalization.string("Or turn off \"Use Cloudflare Access service token\" to sign in interactively through the in-app browser.")
            ]
        case .start, .dashboard, .credentials, .network, .currentConnection, .repairConnection:
            return []
        }
    }
}
