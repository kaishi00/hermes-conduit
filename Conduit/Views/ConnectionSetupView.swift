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
    @Environment(\.dismiss) private var dismiss
    @State private var flow: ConnectionSetupFlow
    @State private var showNotSureGuidance = false
    /// The in-flight staged-test task. Cancelled on any exit from the test
    /// screen and on dismissal; late probe events are additionally dropped
    /// by the flow's generation guard, so correctness never relies on view
    /// destruction.
    @State private var testTask: Task<Void, Never>?
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
                        repairReview: repairReview
                    )
                default:
                    ScrollView {
                        content
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .accessibilityIdentifier("connection-setup.content")
            .onChange(of: flow.step) { _, newStep in
                // Leaving the test screen for any editable step cancels the
                // probe; a success advance to Review does not.
                guard newStep != .connectionTest, newStep != .review else { return }
                stopTestRun()
            }
            .onDisappear { stopTestRun() }
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
            isInteractive: flow.testState.requiresInteractiveSignIn,
            isCandidateAvailable: candidateCurrent,
            activationFailure: activationFailure,
            isActivating: isActivating,
            reconnectNow: { reconnectNow() },
            signInToReconnect: { beginRepairSignIn() },
            testAgain: { testAgainAfterFailedActivation() }
        )
    }

    /// The existing AuthWebView, pointed at the tested address with the
    /// wizard's same-origin Cloudflare state. The probe never hosts a
    /// WebView; sign-in happens only on this explicit action.
    @ViewBuilder
    private var repairSignInSheet: some View {
        if let configuration = repairSignInConfiguration {
            AuthWebView(
                url: configuration.serverURL,
                cloudflareAccess: flow.cloudflareAccessForDraft(),
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
        } else {
            // Unreachable: the sheet is only presented with a configuration.
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
        repairSignInConfiguration = result
        showRepairSignIn = true
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
                argument: "Reconnected to Hermes."
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
                // One completion announcement per run; individual stage
                // transitions stay quiet.
                switch event {
                case .succeeded(.authentication):
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: ConnectionSetupTestState.readyMessage
                    )
                case .requiresInteractiveSignIn(.authentication):
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: ConnectionSetupTestState.interactiveReadyMessage
                    )
                case .requiresCredentials(.authentication):
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: ConnectionSetupTestState.credentialsRequiredMessage
                    )
                case .failed(_, let failure):
                    UIAccessibility.post(notification: .announcement, argument: failure.userTitle)
                default:
                    break
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
            progress: flow.progressLabel,
            question: String(localized: "Is your Hermes dashboard running?"),
            explanation: "Hermes Conduit connects to a Hermes dashboard you (or your assistant) run yourself. "
                + "The dashboard has to be up before Conduit can reach it.",
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
            continueButton("Dashboard is ready") { flow.confirmDashboardReady() }
                .accessibilityIdentifier("setup.continue")
        case .unknown:
            AskHermesPromptView(title: ConnectionSetupPrompt.dashboardUnknown.title, prompt: ConnectionSetupPrompt.dashboardUnknown.text)
            continueButton("Dashboard is ready") { flow.confirmDashboardReady() }
                .accessibilityIdentifier("setup.continue")
        default:
            EmptyView()
        }
    }

    // MARK: - Step 2: Dashboard credentials

    private var credentialsStep: some View {
        readinessQuestion(
            progress: flow.progressLabel,
            question: String(localized: "Do you have your Hermes dashboard login credentials?"),
            explanation: String(localized: "This means the Hermes dashboard username and password you sign in with — not Tailscale, ")
                + "Cloudflare, or Apple credentials.",
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
            continueButton("Credentials are ready") { flow.confirmCredentialsReady() }
                .accessibilityIdentifier("setup.continue")
        case .unknown:
            AskHermesPromptView(title: ConnectionSetupPrompt.credentialsUnknown.title, prompt: ConnectionSetupPrompt.credentialsUnknown.text)
            continueButton("Credentials are ready") { flow.confirmCredentialsReady() }
                .accessibilityIdentifier("setup.continue")
        default:
            EmptyView()
        }
    }

    // MARK: - Step 3: Access method

    private var accessMethodStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let progress = flow.progressLabel {
                stepLabel(progress)
            }
            Text("How will this iPhone or iPad reach Hermes?")
                .font(.title3.weight(.semibold))
            Text("Pick how Conduit should reach your self-hosted Hermes dashboard. You can change this later.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !flow.draft.existingServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continueButton("Use or edit current dashboard address") { flow.useExistingAddress() }
                    .accessibilityIdentifier("setup.use-existing")
            }

            methodCard(
                title: ConnectionAccessMethod.lan.displayTitle,
                supporting: "Use this when Conduit and the Hermes machine are on the same home or local network.",
                identifier: "setup.method-lan"
            ) {
                flow.selectAccessMethod(.lan)
            }

            methodCard(
                title: ConnectionAccessMethod.tailscale.displayTitle,
                supporting: "Use Tailscale when you want to reach Hermes securely while away from home.",
                badge: String(localized: "Recommended for remote access"),
                identifier: "setup.method-tailscale"
            ) {
                flow.selectAccessMethod(.tailscale)
            }

            methodCard(
                title: ConnectionAccessMethod.reverseProxy.displayTitle,
                supporting: "Use this if you already access Hermes through an HTTPS hostname you manage.",
                identifier: "setup.method-reverseProxy"
            ) {
                flow.selectAccessMethod(.reverseProxy)
            }

            notSureGuidance
        }
    }

    private var notSureGuidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showNotSureGuidance.toggle()
            } label: {
                HStack {
                    Label("I’m not sure", systemImage: "questionmark.circle")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showNotSureGuidance ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("setup.method-notsure")

            if showNotSureGuidance {
                VStack(alignment: .leading, spacing: 10) {
                    guidanceBullet("Using Conduit at home, on the same network as the Hermes machine? Choose Same Network.")
                    guidanceBullet("Need access away from home without existing remote access? Choose Tailscale — the simplest secure option.")
                    guidanceBullet("Already operating an HTTPS domain or reverse proxy for Hermes? Choose Existing Domain.")
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))
    }

    // MARK: - LAN branch

    private var lanBranch: some View {
        branchShell(
            title: String(localized: "Same network as Hermes"),
            intro: "Here is what you will need to connect Conduit over your local network:",
            needs: [
                "The Hermes dashboard is running.",
                "You have dashboard login credentials.",
                "You know the Hermes machine’s local IP address.",
                "You know the dashboard port.",
                "This device is on the same reachable network."
            ],
            prompt: .lanDetails
        )
    }

    // MARK: - Tailscale branch

    private var tailscaleBranch: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reach Hermes with Tailscale")
                .font(.title3.weight(.semibold))
            Text("Tailscale gives you secure access from anywhere, including the recommended Tailscale Serve path:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                numberedStep(1, "Tailscale is installed on the Hermes machine.")
                numberedStep(2, "Tailscale is installed on this iPhone or iPad.")
                numberedStep(3, "Both are signed in to the same tailnet.")
                numberedStep(4, "The Hermes dashboard is running.")
                numberedStep(5, "Hermes configures Tailscale Serve for the dashboard.")
                numberedStep(6, "Hermes tells you the address to enter into Conduit.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))

            Text("Conduit never installs or configures Tailscale, and it doesn’t assume an address or port — Hermes tells you what to use.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AskHermesPromptView(title: ConnectionSetupPrompt.tailscaleServe.title, prompt: ConnectionSetupPrompt.tailscaleServe.text)
            continueButton("I have the connection details") { flow.confirmDetailsReady() }
                .accessibilityIdentifier("setup.details-ready")
        }
    }

    // MARK: - Reverse-proxy branch

    private var reverseProxyBranch: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Use your existing HTTPS domain")
                .font(.title3.weight(.semibold))
            Text("This branch is only for HTTPS infrastructure you already operate — Conduit does not guide you through creating one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Text("You will need:")
                    .font(.subheadline.weight(.semibold))
                guidanceBullet("Your existing HTTPS Hermes dashboard URL — for example https://hermes.example.com, https://hermes.example.com:9443, or https://example.com/hermes.")
                guidanceBullet("Any custom port.")
                guidanceBullet("Any path prefix your proxy uses.")
                guidanceBullet("Your dashboard login credentials.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))

            Text("Conduit will not ask you to expose a raw public port, create firewall rules, or bypass certificate checks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AskHermesPromptView(title: ConnectionSetupPrompt.reverseProxyDetails.title, prompt: ConnectionSetupPrompt.reverseProxyDetails.text)
            continueButton("I have the connection details") { flow.confirmDetailsReady() }
                .accessibilityIdentifier("setup.details-ready")
        }
    }

    // MARK: - Troubleshooting surfaces (Round-1 content retained)

    private func troubleshootingStep(_ topic: ConnectionHelpDestination) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Topic", selection: topicBinding) {
                Text(ConnectionHelpDestination.tls.displayName).tag(ConnectionHelpDestination.tls)
                Text(ConnectionHelpDestination.cloudflare.displayName).tag(ConnectionHelpDestination.cloudflare)
            }
            .font(.subheadline)
            .accessibilityIdentifier("setup.troubleshooting-picker")

            Text(topic == .tls
                ? "Checks for HTTPS and certificate problems when connecting to your dashboard."
                : "Checks for Cloudflare Access service-token problems when connecting to your dashboard.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(topic.checks.enumerated()), id: \.offset) { _, check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.conduitAccent)
                            .padding(.top, 2)
                        Text(check)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))
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
        progress: String?,
        question: String,
        explanation: String,
        selectedAnswer: ConnectionSetupAnswer?,
        onAnswer: @escaping (ConnectionSetupAnswer) -> Void,
        @ViewBuilder guidance: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let progress {
                stepLabel(progress)
            }
            Text(question)
                .font(.title3.weight(.semibold))
            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            answerRow("Yes", selected: selectedAnswer == .yes, identifier: "setup.answer-yes") {
                onAnswer(.yes)
            }
            answerRow(String(localized: "No"), selected: selectedAnswer == .no, identifier: "setup.answer-no") {
                onAnswer(.no)
            }
            answerRow(String(localized: "I don’t know"), selected: selectedAnswer == .unknown, identifier: "setup.answer-unknown") {
                onAnswer(.unknown)
            }

            guidance()
        }
    }

    private func answerRow(
        _ label: String,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.conduitAccent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 14, tint: .conduitAura.opacity(0.06))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func methodCard(
        title: String,
        supporting: String,
        badge: String? = nil,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.conduitAccent.opacity(0.15), in: Capsule())
                        .foregroundStyle(.conduitAccent)
                }
                Text(supporting)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 16, tint: .conduitAura.opacity(0.06))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func branchShell(
        title: String,
        intro: String,
        needs: [String],
        prompt: ConnectionSetupPrompt
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(intro)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(needs.enumerated()), id: \.offset) { _, need in
                    guidanceBullet(need)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))

            AskHermesPromptView(title: prompt.title, prompt: prompt.text)
            continueButton("I have the connection details") { flow.confirmDetailsReady() }
                .accessibilityIdentifier("setup.details-ready")
        }
    }

    private func numberedStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.conduitAccent)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.conduitAccent)
            .accessibilityIdentifier("setup.step-label")
    }

    private func continueButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.conduitAccent)
    }

    private func guidanceBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.conduitAccent)
                .padding(.top, 6)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Round-1 troubleshooting content (retained)

extension ConnectionHelpDestination {
    var displayName: String {
        switch self {
        case .start: return String(localized: "Getting started")
        case .dashboard: return String(localized: "Dashboard address")
        case .credentials: return "Credentials"
        case .network: return String(localized: "Network & reachability")
        case .tls: return String(localized: "HTTPS & certificates")
        case .cloudflare: return "Cloudflare Access"
        case .currentConnection: return String(localized: "Current connection")
        case .repairConnection: return String(localized: "Repair connection")
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
                String(localized: "If you use your own certificate authority, install and trust its root certificate on this device (Settings → General → VPN & Device Management → Certificate Trust Settings)."),
                String(localized: "Check the server certificate’s expiration and validity dates."),
                String(localized: "Confirm this device’s date and time are correct.")
            ]
        case .cloudflare:
            return [
                String(localized: "Verify the Client ID and Secret belong to a Cloudflare Access service token for this application."),
                String(localized: "Make sure a Service Auth policy allows that token to reach this Access application."),
                String(localized: "Or turn off \"Use Cloudflare Access service token\" to sign in interactively through the in-app browser.")
            ]
        case .start, .dashboard, .credentials, .network, .currentConnection, .repairConnection:
            return []
        }
    }
}
