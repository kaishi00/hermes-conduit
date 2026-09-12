import SwiftUI

/// Form rendering only: navigation and final validation stay in the flow.
struct ConnectionSetupForm: View {
    @Binding var flow: ConnectionSetupFlow
    let onStartTest: () -> Void
    let onComplete: (ConnectionSetupResult) -> Void
    /// Round 6: non-nil only in Repair mode, where the Review's final
    /// actions are Reconnect Now / Sign In to Reconnect instead of the
    /// login-form handoff or the Settings Done/apply paths.
    let repairReview: ConnectionSetupRepairReview?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case host, port, url, username, password }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch flow.step {
                    case .connectionDetails: details
                    case .loginCredentials: credentials
                    case .connectionTest: connectionTest
                    case .review: review
                    default: EmptyView()
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focusedField) { _, field in
                guard let field else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(field, anchor: .center) }
            }
            .onChange(of: flow.step) { _, _ in focusedField = nil }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .accessibilityIdentifier("setup.keyboard-done")
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(flow.draft.methodTitle).font(.title2.weight(.semibold))
            if flow.draft.usesExistingAddress || flow.accessMethod == .reverseProxy {
                Text(flow.draft.usesExistingAddress
                     ? "Review or edit your current dashboard address, including its port and path."
                     : "Paste the full HTTPS dashboard address Hermes supplied, including any port or path.")
                    .foregroundStyle(.secondary)
                labeled(String(localized: "Dashboard address")) {
                    TextField("Dashboard address", text: fullURLBinding)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .url)
                        .submitLabel(.next)
                        .onSubmit { flow.submitDetails() }
                        .accessibilityIdentifier("setup.url")
                        .accessibilityLabel("Dashboard address")
                }.id(Field.url)
            } else {
                Text(flow.accessMethod == .lan
                     ? "Enter the local IP address and port Hermes gave you. You don’t need to type http://."
                     : "Enter the Tailscale hostname or address Hermes gave you. Tailscale Serve hostnames use HTTPS; leave the port blank unless Hermes supplied one.")
                    .foregroundStyle(.secondary)
                labeled(flow.accessMethod == .lan ? String(localized: "Private LAN IP address") : "Tailscale hostname / address") {
                    TextField(flow.accessMethod == .lan ? String(localized: "Local IP address") : String(localized: "Tailscale host or address"), text: hostBinding)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .host)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .port }
                        .accessibilityIdentifier("setup.host")
                        .accessibilityLabel(flow.accessMethod == .lan ? String(localized: "Private LAN IP address") : String(localized: "Tailscale hostname or address"))
                }.id(Field.host)
                labeled(flow.accessMethod == .lan ? String(localized: "Port") : String(localized: "Port (optional)")) {
                    TextField("Port supplied by Hermes", text: portBinding)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                        .accessibilityIdentifier("setup.port")
                        .accessibilityLabel(flow.accessMethod == .lan ? String(localized: "Dashboard port") : String(localized: "Dashboard port (optional)"))
                }.id(Field.port)
                if flow.accessMethod == .tailscale,
                   !ConnectionSetupAddressBuilder.isServeHostname(flow.draft.tailscale.host) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("For a direct address, choose the scheme Hermes supplied.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Picker("Connection scheme", selection: $flow.draft.tailscaleScheme) {
                            Text("Choose scheme").tag(Optional<ConnectionSetupScheme>.none)
                            Text("HTTP").tag(Optional(ConnectionSetupScheme.http))
                            Text("HTTPS").tag(Optional(ConnectionSetupScheme.https))
                        }
                        .accessibilityIdentifier("setup.scheme")
                        .accessibilityLabel("Connection scheme")
                    }
                }
            }
            if let address = try? ConnectionSetupAddressBuilder.build(flow.draft) {
                Text(address).font(.subheadline).textSelection(.enabled)
                    .accessibilityIdentifier("setup.address-preview")
            }
            validationNotice
            nextButton("Continue") { flow.submitDetails() }
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Dashboard credentials").font(.title2.weight(.semibold))
            Text("Use your Hermes dashboard username and password. These are not your Tailscale, Cloudflare, or Apple credentials.")
                .foregroundStyle(.secondary)
            labeled(String(localized: "Dashboard username")) {
                TextField("Dashboard username", text: $flow.draft.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .accessibilityIdentifier("setup.username")
                    .accessibilityLabel("Dashboard username")
            }.id(Field.username)
            labeled(String(localized: "Dashboard password")) {
                SecureField("Dashboard password", text: $flow.draft.password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { flow.submitCredentials() }
                    .accessibilityIdentifier("setup.password")
                    .accessibilityLabel("Dashboard password")
            }.id(Field.password)
            validationNotice
            nextButton("Continue") { flow.submitCredentials() }
        }
    }

    // MARK: - Round 4: staged connection test

    @ViewBuilder
    private var connectionTest: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Test connection").font(.title2.weight(.semibold))
            // Entries that skipped the details form (the Settings
            // current-connection and Repair entries) still show what is
            // being tested.
            if (flow.enteredFromCurrentConnection || flow.isRepairingConnection),
               let address = try? ConnectionSetupAddressBuilder.build(flow.draft) {
                Text(address).font(.subheadline).textSelection(.enabled)
                    .accessibilityIdentifier("setup.address-preview")
            }
            Text("Conduit will check the dashboard address and try your credentials now. Nothing is saved, and Conduit won’t connect yet — you’ll confirm everything on the Review screen.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ConnectionSetupStageList(state: flow.testState)

            if let failure = flow.testState.failedFailure,
               let stage = flow.testState.failedStage {
                failedTestRecovery(stage: stage, failure: failure)
            } else if flow.testState.requiresCredentials {
                // Partial outcome, not a failure: server and dashboard
                // passed, no login was attempted, and the missing secret is
                // the only thing between the user and a full test.
                credentialsRequiredRecovery
            } else if flow.canUseSettings {
                // Reachable after returning Back from Review: a passing or
                // interactive outcome is still current, so continue without
                // re-testing.
                Button("Continue") { flow.continueToReview() }
                    .buttonStyle(.borderedProminent)
                    .tint(.conduitAccent)
                    .accessibilityIdentifier("setup.test.continue")
            } else if !flow.testState.isRunning {
                Button("Test Connection") { onStartTest() }
                    .buttonStyle(.borderedProminent)
                    .tint(.conduitAccent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("setup.test.run")
            }
        }
    }

    /// The credentials-required partial outcome's recovery: Enter
    /// Credentials is the primary action and routes to the existing
    /// credentials step (leaving the test step invalidates the partial
    /// result, so returning runs a fresh full test). Retry is deliberately
    /// absent — retrying with the same missing credentials would be
    /// pointless, and no login attempt occurred, so there is no
    /// rate-limit concern.
    @ViewBuilder
    private var credentialsRequiredRecovery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ConnectionSetupTestState.credentialsRequiredMessage)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup.test.credentials-required")
            Button("Enter Credentials") {
                flow.editAfterFailedTest(.loginCredentials)
            }
            .buttonStyle(.borderedProminent)
            .tint(.conduitAccent)
            .accessibilityIdentifier("setup.test.enter-credentials")
        }
    }

    @ViewBuilder
    private func failedTestRecovery(stage: ConnectionSetupTestStage, failure: ConnectionFailure) -> some View {
        let plan = ConnectionSetupTestRecoveryPlan.plan(for: stage, failure: failure)
        VStack(alignment: .leading, spacing: 12) {
            // The stable classified copy — never a raw error string.
            Text(failure.userMessage)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup.test.failure")
            HStack(spacing: 16) {
                Button(plan.remediationLabel) {
                    flow.editAfterFailedTest(plan.remediationStep)
                }
                .buttonStyle(.borderedProminent)
                .tint(.conduitAccent)
                .accessibilityIdentifier(
                    plan.remediationStep == .connectionDetails ? "setup.test.edit-details" : "setup.test.edit-credentials"
                )
                if plan.offersRetry {
                    Button("Try Again") { onStartTest() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("setup.test.retry")
                }
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Review").font(.title2.weight(.semibold))
            // The staged result that authorizes this screen: a current
            // successful test or the interactive-auth outcome, shown with
            // its per-stage outcomes.
            if flow.canUseSettings {
                ConnectionSetupStageList(state: flow.testState)
                if flow.testState.requiresInteractiveSignIn {
                    // The user has NOT authenticated: say what happens next
                    // instead of claiming success. Never "Login successful".
                    Text(flow.isRepairingConnection
                         ? ConnectionSetupTestState.repairInteractiveMessage
                         : ConnectionSetupTestState.interactiveReadyMessage)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("setup.test.interactive-ready")
                } else if repairReview?.activationFailure != nil {
                    // Repair: the explicit reconnect failed after a verified
                    // test. The failure text below carries the meaning — the
                    // "ready to use" headline would contradict it.
                } else {
                    Text(ConnectionSetupTestState.readyMessage)
                        .font(.headline)
                        .accessibilityIdentifier("setup.test.ready")
                }
            }
            // Revalidate for rendering only: a draft that stopped validating
            // after reaching Review must never silently blank the card.
            reviewContent
            if let repair = repairReview {
                repairReviewFooter(repair)
            } else {
                Text(flow.enteredFromCurrentConnection
                     ? String(localized: "Applying saves these settings for your next reconnect. Your current session stays connected.")
                     : String(localized: "These settings will fill the login form. You’ll tap Connect there when you’re ready."))
                    .foregroundStyle(.secondary)
                validationNotice
                // From Settings with unchanged, successfully tested settings
                // there is nothing to apply — Done simply closes the wizard.
                Button(flow.testedSettingsUnchanged ? String(localized: "Done") : String(localized: "Use these settings")) {
                    if let result = flow.complete() { onComplete(result) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!reviewIsValid)
                .accessibilityIdentifier("setup.use-settings")
            }
        }
    }

    /// Round 6: the Repair review's final actions. Reconnect Now requires a
    /// current validated candidate (a consumed one forces a fresh test);
    /// Sign In to Reconnect opens the existing AuthWebView; an activation
    /// failure is shown classified with the explicit next step. Never an
    /// automatic retry, never an automatic reconnection.
    @ViewBuilder
    private func repairReviewFooter(_ repair: ConnectionSetupRepairReview) -> some View {
        if repair.isActivating {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reconnecting…")
                    .font(.headline)
            }
            .accessibilityIdentifier("setup.review.reconnecting")
        } else {
            if let failure = repair.activationFailure {
                Text(failure.userMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup.review.reconnect-failure")
            }
            if repair.isInteractive {
                Button("Sign In to Reconnect") { repair.signInToReconnect() }
                    .buttonStyle(.borderedProminent)
                    .tint(.conduitAccent)
                    .accessibilityIdentifier("setup.review.sign-in-reconnect")
            } else if repair.isCandidateAvailable {
                Button("Reconnect Now") { repair.reconnectNow() }
                    .buttonStyle(.borderedProminent)
                    .tint(.conduitAccent)
                    .accessibilityIdentifier("setup.review.reconnect-now")
            } else {
                Button("Test Connection Again") { repair.testAgain() }
                    .buttonStyle(.borderedProminent)
                    .tint(.conduitAccent)
                    .accessibilityIdentifier("setup.review.test-again")
            }
        }
    }

    @ViewBuilder private var reviewContent: some View {
        switch flow.reviewState() {
        case .success(let result):
            reviewValue(String(localized: "Connection method"), flow.draft.methodTitle)
            reviewValue(String(localized: "Dashboard address"), result.serverURL)
            if !result.username.isEmpty {
                reviewValue(String(localized: "Username"), result.username)
            }
            if result.password.isEmpty {
                // Only reachable through the interactive-auth acceptance:
                // discovery proved this dashboard signs in via the browser,
                // so the absent password is expected, not an omission.
                reviewValue(String(localized: "Password"), String(localized: "None — browser sign-in"))
            } else {
                reviewValue(String(localized: "Password"), String(localized: "Entered"))
            }
        case .failure(let error):
            VStack(alignment: .leading, spacing: 8) {
                Text("These settings can’t be used yet. Go Back to edit them, then return here.")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(error.message).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("setup.review-invalid")
        }
    }

    private var reviewIsValid: Bool {
        guard flow.canUseSettings else { return false }
        if case .success = flow.reviewState() { return true }
        return false
    }

    @ViewBuilder private var validationNotice: some View {
        if let error = flow.validationError {
            Text(error.message).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup.validation")
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func reviewValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) {
            focusedField = nil
            action()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("setup.next")
    }

    private var fullURLBinding: Binding<String> {
        flow.draft.usesExistingAddress ? $flow.draft.existingServerURL : $flow.draft.reverseProxyURL
    }
    private var hostBinding: Binding<String> {
        flow.accessMethod == .lan ? $flow.draft.lan.host : $flow.draft.tailscale.host
    }
    private var portBinding: Binding<String> {
        flow.accessMethod == .lan ? $flow.draft.lan.port : $flow.draft.tailscale.port
    }
}

/// The staged connection-test diagnostic list: one row per stage with a
/// state marker. Meaning is carried by text and VoiceOver state words, never
/// by color alone.
struct ConnectionSetupStageList: View {
    let state: ConnectionSetupTestState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ConnectionSetupTestStage.allCases) { stage in
                ConnectionSetupStageRow(
                    stage: stage,
                    stageState: state[stage],
                    label: state.rowLabel(for: stage),
                    accessibilityLabel: state.accessibilityLabel(for: stage)
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))
    }
}

struct ConnectionSetupStageRow: View {
    let stage: ConnectionSetupTestStage
    let stageState: ConnectionSetupStageState
    let label: String
    let accessibilityLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            marker
            Text(label)
                .font(.subheadline.weight(stageState == .pending ? .regular : .semibold))
            Spacer(minLength: 0)
        }
        // One VoiceOver element per stage: the objective name plus a state
        // word, so success/failure never rides on icon or color alone. The
        // format comes from the model, which pins it in tests.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("setup.test.stage.\(stage.identifierName)")
    }

    @ViewBuilder
    private var marker: some View {
        switch stageState {
        case .pending:
            Image(systemName: "circle")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        case .running:
            ProgressView()
                .controlSize(.small)
                .padding(.top, 3)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .padding(.top, 2)
        case .requiresInteractiveSignIn, .requiresCredentials:
            // An open circle in the accent color: deliberately not a
            // checkmark (the user has not authenticated) and not an error
            // mark (nothing failed). Both are partial outcomes — text and
            // VoiceOver carry which one it is.
            Image(systemName: "circle")
                .font(.footnote)
                .foregroundStyle(.conduitAccent)
                .padding(.top, 2)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.top, 2)
        }
    }
}
