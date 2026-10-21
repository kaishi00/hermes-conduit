import SwiftUI

/// Form rendering only: navigation and final validation stay in the flow.
struct ConnectionSetupForm: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Binding var flow: ConnectionSetupFlow
    let onStartTest: () -> Void
    let onComplete: (ConnectionSetupResult) -> Void
    /// Round 6: non-nil only in Repair mode, where the Review's final
    /// actions are Reconnect Now / Sign In to Reconnect instead of the
    /// login-form handoff or the Settings Done/apply paths.
    let repairReview: ConnectionSetupRepairReview?
    /// Non-nil only for the Settings current-connection entry: whether the
    /// session is connected, and Sign In Again when the test found that the
    /// active dashboard signs in through a browser.
    var settingsReview: ConnectionSetupSettingsReview? = nil
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
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            // On the scroll view itself: set on a parent, the identifier
            // would also replace the pinned button's own.
            .accessibilityIdentifier("connection-setup.content")
            // The form steps' Continue stays pinned above the keyboard, so
            // it is never hidden behind it while a field is being edited.
            .safeAreaInset(edge: .bottom, spacing: 0) { pinnedAction }
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

    @ViewBuilder
    private var pinnedAction: some View {
        switch flow.step {
        case .connectionDetails:
            nextButton(AppLocalization.string("Continue")) { flow.submitDetails() }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
        case .loginCredentials:
            nextButton(AppLocalization.string("Continue")) { flow.submitCredentials() }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
        default:
            EmptyView()
        }
    }

    /// The details screen's glyph follows the way in.
    private var methodSymbol: String {
        if flow.draft.usesExistingAddress { return "server.rack" }
        switch flow.accessMethod {
        case .lan: return "wifi"
        case .tailscale: return "lock.shield"
        case .reverseProxy: return "globe"
        case nil: return "link"
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            if flow.draft.usesExistingAddress || flow.accessMethod == .reverseProxy {
                ConnectionSetupHeader(
                    symbol: methodSymbol,
                    title: flow.draft.methodTitle,
                    detail: flow.draft.usesExistingAddress
                        ? AppLocalization.string("Review or edit your current dashboard address, including its port and path.")
                        : AppLocalization.string("Paste the full HTTPS dashboard address Hermes supplied, including any port or path.")
                )
                ConnectionSetupField(title: AppLocalization.string("Dashboard address")) {
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
                        .loginFieldChrome(isFocused: focusedField == .url)
                }.id(Field.url)
            } else {
                ConnectionSetupHeader(
                    symbol: methodSymbol,
                    title: flow.draft.methodTitle,
                    detail: flow.accessMethod == .lan
                        ? AppLocalization.string("Enter the local IP address and port Hermes gave you. You don’t need to type http://.")
                        : AppLocalization.string("Enter the Tailscale hostname or address Hermes gave you. Tailscale Serve hostnames use HTTPS; leave the port blank unless Hermes supplied one.")
                )
                ConnectionSetupField(title: flow.accessMethod == .lan ? AppLocalization.string("Private LAN IP address") : AppLocalization.string("Tailscale hostname / address")) {
                    TextField(flow.accessMethod == .lan ? AppLocalization.string("Local IP address") : AppLocalization.string("Tailscale host or address"), text: hostBinding)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .host)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .port }
                        .accessibilityIdentifier("setup.host")
                        .accessibilityLabel(flow.accessMethod == .lan ? AppLocalization.string("Private LAN IP address") : AppLocalization.string("Tailscale hostname or address"))
                        .loginFieldChrome(isFocused: focusedField == .host)
                }.id(Field.host)
                ConnectionSetupField(title: flow.accessMethod == .lan ? AppLocalization.string("Port") : AppLocalization.string("Port (optional)")) {
                    TextField("Port supplied by Hermes", text: portBinding)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                        .accessibilityIdentifier("setup.port")
                        .accessibilityLabel(flow.accessMethod == .lan ? AppLocalization.string("Dashboard port") : AppLocalization.string("Dashboard port (optional)"))
                        .loginFieldChrome(isFocused: focusedField == .port)
                }.id(Field.port)
                if flow.accessMethod == .tailscale,
                   !ConnectionSetupAddressBuilder.isServeHostname(flow.draft.tailscale.host) {
                    VStack(alignment: .leading, spacing: 8) {
                        ConnectionSetupCard {
                            ConduitMenuPicker(
                                value: flow.draft.tailscaleScheme,
                                choices: [
                                    (id: Optional<ConnectionSetupScheme>.none, title: AppLocalization.string("Choose scheme")),
                                    (id: Optional(ConnectionSetupScheme.http), title: "HTTP"),
                                    (id: Optional(ConnectionSetupScheme.https), title: "HTTPS")
                                ],
                                onSelect: { flow.draft.tailscaleScheme = $0 }
                            ) {
                                Text("Connection scheme")
                            }
                            .padding(.horizontal, 4)
                            .accessibilityIdentifier("setup.scheme")
                        }
                        ConnectionSetupNote(text: AppLocalization.string("For a direct address, choose the scheme Hermes supplied."))
                    }
                }
            }
            if let address = try? ConnectionSetupAddressBuilder.build(flow.draft) {
                ConnectionSetupAddressCard(title: AppLocalization.string("Dashboard address"), address: address)
            }
            validationNotice
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 20) {
            ConnectionSetupHeader(
                symbol: "person.badge.key",
                title: AppLocalization.string("Dashboard credentials"),
                detail: AppLocalization.string("Use your Hermes dashboard username and password. These are not your Tailscale, Cloudflare, or Apple credentials.")
            )
            ConnectionSetupField(title: AppLocalization.string("Dashboard username")) {
                TextField("Dashboard username", text: $flow.draft.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .accessibilityIdentifier("setup.username")
                    .accessibilityLabel("Dashboard username")
                    .loginFieldChrome(isFocused: focusedField == .username)
            }.id(Field.username)
            ConnectionSetupField(title: AppLocalization.string("Dashboard password")) {
                SecureField("Dashboard password", text: $flow.draft.password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { flow.submitCredentials() }
                    .accessibilityIdentifier("setup.password")
                    .accessibilityLabel("Dashboard password")
                    .loginFieldChrome(isFocused: focusedField == .password)
            }.id(Field.password)
            validationNotice
        }
    }

    // MARK: - Round 4: staged connection test

    @ViewBuilder
    private var connectionTest: some View {
        VStack(alignment: .leading, spacing: 20) {
            ConnectionSetupHeader(
                symbol: "stethoscope",
                title: AppLocalization.string("Test connection"),
                detail: AppLocalization.string("Conduit will check the dashboard address and how it signs in, and try a username and password only if you entered them. Nothing is saved, and Conduit won’t connect yet — you’ll confirm everything on the Review screen.")
            )
            // Entries that skipped the details form (the Settings
            // current-connection and Repair entries) still show what is
            // being tested.
            if (flow.enteredFromCurrentConnection || flow.isRepairingConnection),
               let address = try? ConnectionSetupAddressBuilder.build(flow.draft) {
                ConnectionSetupAddressCard(title: AppLocalization.string("Dashboard address"), address: address)
            }

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
                LoginPrimaryButton(title: AppLocalization.string("Continue")) { flow.continueToReview() }
                    .accessibilityIdentifier("setup.test.continue")
                if flow.testState.requiresSignInChoice {
                    signInChoiceEnterCredentialsButton
                }
            } else if !flow.testState.isRunning {
                LoginPrimaryButton(title: AppLocalization.string("Test Connection")) { onStartTest() }
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
        ConnectionSetupBanner(tone: .pending) {
            Text(ConnectionSetupTestState.credentialsRequiredMessage)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup.test.credentials-required")
            Button(AppLocalization.string("Enter Credentials")) {
                flow.editAfterFailedTest(.loginCredentials)
            }
            .buttonStyle(.settingsPrimary)
            .accessibilityIdentifier("setup.test.enter-credentials")
        }
    }

    /// The sign-in-choice outcome's password path: test a username and
    /// password now instead of choosing on the login screen.
    private var signInChoiceEnterCredentialsButton: some View {
        Button(AppLocalization.string("Enter Credentials")) { flow.enterCredentialsForSignInChoice() }
            .buttonStyle(.settings)
            .accessibilityIdentifier("setup.test.choice-enter-credentials")
    }

    @ViewBuilder
    private func failedTestRecovery(stage: ConnectionSetupTestStage, failure: ConnectionFailure) -> some View {
        let plan = ConnectionSetupTestRecoveryPlan.plan(for: stage, failure: failure)
        ConnectionSetupBanner(tone: .failure) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: failure.userTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                // The stable classified copy — never a raw error string.
                Text(failure.userMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup.test.failure")
            }
            AdaptiveStack(spacing: 8) {
                Button(plan.remediationLabel) {
                    flow.editAfterFailedTest(plan.remediationStep)
                }
                .buttonStyle(.settingsPrimary)
                .accessibilityIdentifier(
                    plan.remediationStep == .connectionDetails ? "setup.test.edit-details" : "setup.test.edit-credentials"
                )
                if plan.offersRetry {
                    Button(AppLocalization.string("Try Again")) { onStartTest() }
                        .buttonStyle(.settings)
                        .accessibilityIdentifier("setup.test.retry")
                }
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 20) {
            ConnectionSetupHeader(symbol: "checkmark.seal", title: AppLocalization.string("Review"))
            // The staged result that authorizes this screen: a current
            // successful test or the interactive-auth outcome.
            if flow.canUseSettings {
                if let settingsReview, settingsReview.offersSignInAgain {
                    // Settings, for the dashboard Conduit is set up for:
                    // the next step is signing in, here. Never "return to
                    // the login screen" while the app shell is up.
                    ConnectionSetupBanner(tone: .pending) {
                        Text(ConnectionSetupSettingsReview.signInAgainMessage(connected: settingsReview.isSessionConnected))
                            .font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("setup.test.sign-in-again")
                    }
                } else if flow.testState.requiresInteractiveSignIn {
                    // The user has NOT authenticated: say what happens next
                    // instead of claiming success. Never "Login successful".
                    ConnectionSetupBanner(tone: .pending) {
                        Text(flow.isRepairingConnection
                             ? ConnectionSetupTestState.repairInteractiveMessage
                             : ConnectionSetupTestState.interactiveReadyMessage)
                            .font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("setup.test.interactive-ready")
                    }
                } else if flow.testState.requiresSignInChoice {
                    ConnectionSetupBanner(tone: .pending) {
                        Text(flow.isRepairingConnection
                             ? ConnectionSetupTestState.repairSignInChoiceMessage
                             : ConnectionSetupTestState.signInChoiceMessage)
                            .font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("setup.test.sign-in-choice")
                    }
                } else if repairReview?.activationFailure != nil {
                    // Repair: the explicit reconnect failed after a verified
                    // test. The failure text below carries the meaning — the
                    // "ready to use" headline would contradict it.
                } else {
                    ConnectionSetupBanner(tone: .success) {
                        Text(ConnectionSetupTestState.readyMessage)
                            .font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("setup.test.ready")
                    }
                }
            }
            // Revalidate for rendering only: a draft that stopped validating
            // after reaching Review must never silently blank the card.
            reviewContent
            if flow.canUseSettings {
                // The per-stage outcomes behind the result.
                ConnectionSetupStageList(state: flow.testState)
            }
            if let repair = repairReview {
                repairReviewFooter(repair)
            } else {
                ConnectionSetupNote(text: flow.enteredFromCurrentConnection
                     ? ConnectionSetupSettingsReview.applyNote(connected: settingsReview?.isSessionConnected ?? true)
                     : AppLocalization.string("These settings will fill the login form. Tap Continue there when you’re ready."))
                    .accessibilityIdentifier("setup.review.apply-note")
                validationNotice
                // From Settings with unchanged, successfully tested settings
                // there is nothing to apply — Done simply closes the wizard.
                if let settingsReview, settingsReview.offersSignInAgain {
                    // Sign In Again is the primary action.
                    settingsSignInAgain(settingsReview)
                    Button(useSettingsTitle) {
                        if let result = flow.complete() { onComplete(result) }
                    }
                    .buttonStyle(.settings)
                    .disabled(!reviewIsValid || settingsReview.isSigningIn)
                    .accessibilityIdentifier("setup.use-settings")
                } else {
                    LoginPrimaryButton(title: useSettingsTitle) {
                        if let result = flow.complete() { onComplete(result) }
                    }
                    .disabled(!reviewIsValid)
                    .accessibilityIdentifier("setup.use-settings")
                }
                if flow.canUseSettings, flow.testState.requiresSignInChoice {
                    signInChoiceEnterCredentialsButton
                }
            }
        }
    }

    private var useSettingsTitle: String {
        flow.testedSettingsUnchanged ? AppLocalization.string("Done") : AppLocalization.string("Use these settings")
    }

    /// Settings' Sign In Again: opens the sign-in the test decided for the
    /// active dashboard, and reconnects when it finishes.
    @ViewBuilder
    private func settingsSignInAgain(_ review: ConnectionSetupSettingsReview) -> some View {
        if review.isSigningIn {
            LoginPrimaryButton(title: AppLocalization.string("Reconnecting…"), isBusy: true) {}
                .disabled(true)
                .accessibilityIdentifier("setup.review.reconnecting")
        } else {
            if let failure = review.signInFailure {
                ConnectionSetupBanner(tone: .failure) {
                    Text(failure.userMessage)
                        .font(.subheadline)
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("setup.review.sign-in-again-failure")
                }
            }
            LoginPrimaryButton(title: AppLocalization.string("Sign In Again")) { review.signInAgain() }
                .accessibilityIdentifier("setup.review.sign-in-again")
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
            LoginPrimaryButton(title: AppLocalization.string("Reconnecting…"), isBusy: true) {}
                .disabled(true)
                .accessibilityIdentifier("setup.review.reconnecting")
        } else {
            if let failure = repair.activationFailure {
                ConnectionSetupBanner(tone: .failure) {
                    Text(failure.userMessage)
                        .font(.subheadline)
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("setup.review.reconnect-failure")
                }
            }
            if repair.isInteractive {
                LoginPrimaryButton(title: AppLocalization.string("Sign In to Reconnect")) { repair.signInToReconnect() }
                    .accessibilityIdentifier("setup.review.sign-in-reconnect")
                if repair.offersPasswordSignIn {
                    Button(AppLocalization.string("Enter Credentials")) { repair.enterCredentials() }
                        .buttonStyle(.settings)
                        .accessibilityIdentifier("setup.review.enter-credentials")
                }
            } else if repair.isCandidateAvailable {
                LoginPrimaryButton(title: AppLocalization.string("Reconnect Now")) { repair.reconnectNow() }
                    .accessibilityIdentifier("setup.review.reconnect-now")
            } else {
                LoginPrimaryButton(title: AppLocalization.string("Test Connection Again")) { repair.testAgain() }
                    .accessibilityIdentifier("setup.review.test-again")
            }
        }
    }

    @ViewBuilder private var reviewContent: some View {
        switch flow.reviewState() {
        case .success(let result):
            ConnectionSetupCard {
                reviewValue(AppLocalization.string("Connection method"), flow.draft.methodTitle, first: true)
                reviewValue(AppLocalization.string("Dashboard address"), result.serverURL)
                if !result.username.isEmpty {
                    reviewValue(AppLocalization.string("Username"), result.username)
                }
                if result.password.isEmpty {
                    // Only reachable through the interactive-auth acceptance:
                    // discovery proved this dashboard signs in via the browser
                    // (or offers it alongside a password the user has not
                    // entered), so the absent password is expected.
                    reviewValue(
                        AppLocalization.string("Password"),
                        flow.testState.requiresSignInChoice
                            ? AppLocalization.string("Not entered")
                            : AppLocalization.string("None — browser sign-in")
                    )
                } else {
                    reviewValue(AppLocalization.string("Password"), AppLocalization.string("Entered"))
                }
            }
        case .failure(let error):
            ConnectionSetupBanner(tone: .failure) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These settings can’t be used yet. Go Back to edit them, then return here.")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(error.message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("setup.review-invalid")
            }
        }
    }

    private var reviewIsValid: Bool {
        guard flow.canUseSettings else { return false }
        if case .success = flow.reviewState() { return true }
        return false
    }

    @ViewBuilder private var validationNotice: some View {
        if let error = flow.validationError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .accessibilityHidden(true)
                Text(error.message)
                    .font(.footnote.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup.validation")
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 4)
        }
    }

    /// A summary row: the name in small secondary type over its value.
    private func reviewValue(_ title: String, _ value: String, first: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if !first { V2RowDivider(leadingInset: 16) }
        }
    }

    private func nextButton(_ title: String, action: @escaping () -> Void) -> some View {
        LoginPrimaryButton(title: title) {
            focusedField = nil
            action()
        }
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
        ConnectionSetupCard {
            ForEach(Array(ConnectionSetupTestStage.allCases.enumerated()), id: \.element.id) { index, stage in
                ConnectionSetupStageRow(
                    stage: stage,
                    stageState: state[stage],
                    label: state.rowLabel(for: stage),
                    accessibilityLabel: state.accessibilityLabel(for: stage)
                )
                .overlay(alignment: .top) {
                    if index > 0 { V2RowDivider(leadingInset: 50) }
                }
            }
        }
    }
}

struct ConnectionSetupStageRow: View {
    let stage: ConnectionSetupTestStage
    let stageState: ConnectionSetupStageState
    let label: String
    let accessibilityLabel: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            marker
                .conduitFixedGlyph()
                .frame(width: 22)
            Text(label)
                .font(.subheadline.weight(stageState == .pending ? .regular : .semibold))
                .foregroundStyle(stageState == .pending ? Color.primary.opacity(0.58) : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
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
                .font(.body)
                .foregroundStyle(.conduitTertiary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(.green)
        case .requiresInteractiveSignIn, .requiresCredentials, .requiresSignInChoice:
            // An open circle in the accent color: deliberately not a
            // checkmark (the user has not authenticated) and not an error
            // mark (nothing failed). All are partial outcomes — text and
            // VoiceOver carry which one it is.
            Image(systemName: "circle")
                .font(.body)
                .foregroundStyle(.conduitAccent)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.body)
                .foregroundStyle(.red)
        }
    }
}
