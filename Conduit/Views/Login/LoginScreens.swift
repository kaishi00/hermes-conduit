//
//  LoginScreens.swift
//  Conduit
//
//  The V2 sign-in screens: the saved dashboards, the address step (first
//  launch and the Add a dashboard sheet), and the sign-in step pushed after
//  it. LoginFlowModel holds the flow; these only draw it.
//

import SwiftUI

// MARK: - The address step

enum LoginAddressContext {
    /// The sign-in screen with nothing saved yet.
    case firstLaunch
    /// The Add a dashboard sheet.
    case addSheet

    /// Accessibility identifiers: the first launch keeps the `login.*` ones
    /// the UI tests know; the sheet's own don't collide with them.
    var identifierPrefix: String {
        switch self {
        case .firstLaunch: return "login"
        case .addSheet: return "add-dashboard"
        }
    }
}

struct LoginAddressStep: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var flow: LoginFlowModel
    let context: LoginAddressContext
    @FocusState private var focusedField: LoginField?
    /// Set only by the user's Cloudflare switch, so a filled-in token never
    /// scrolls the form away from its top.
    @State private var revealCloudflare = false

    var body: some View {
        // A keyboard-aware scroll view: at compact heights with the keyboard
        // up, the focused field (the Cloudflare fields too) scrolls into view
        // instead of hiding behind it. minHeight keeps the layout when it
        // fits.
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .frame(minHeight: geometry.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focusedField) { _, field in
                    guard let field else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(field, anchor: .center)
                    }
                }
                .onChange(of: revealCloudflare) { _, requested in
                    guard requested else { return }
                    revealCloudflare = false
                    // One runloop turn later: the fields mount in the same
                    // transaction, and scrolling to them before that no-ops.
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(LoginField.cloudflareClientID, anchor: .center)
                        }
                    }
                }
            }
        }
        .keyboardDoneButton { focusedField = nil }
    }

    private var prefix: String { context.identifierPrefix }

    private var content: some View {
        VStack(spacing: 22) {
            if context == .firstLaunch {
                Spacer(minLength: 32)
                LoginHeader(style: .firstLaunch)
                    .padding(.bottom, 4)
            }
            addressSection
            advancedCard
            if let failure = flow.failure(at: .address) {
                LoginFailureCard(failure: failure, flow: flow)
            }
            Spacer(minLength: 12)
            VStack(spacing: 6) {
                LoginPrimaryButton(
                    title: flow.isWorking ? AppLocalization.string("Connecting…") : AppLocalization.string("Continue"),
                    isBusy: flow.isWorking
                ) {
                    focusedField = nil
                    Task { await flow.continueFromAddress() }
                }
                .disabled(!flow.canContinue)
                .accessibilityIdentifier("\(prefix).connect")
                LoginHelpLink(identifier: "\(prefix).connection-setup") {
                    focusedField = nil
                    flow.connectionSetupDestination = .start
                }
            }
        }
        .loginReadableWidth()
        .padding(.horizontal, 16)
        .padding(.top, context == .addSheet ? 12 : 0)
        .padding(.bottom, 12)
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(addressLabel)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.body.weight(.medium))
                    .conduitFixedGlyph()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(text: $flow.address, prompt: Text(verbatim: "mac.tailnet.ts.net:9119")) {
                    Text(addressLabel)
                }
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("\(prefix).server-url")
                .focused($focusedField, equals: .server)
                .submitLabel(LoginField.server.submitKeyboardLabel(cloudflareTokenEntryEnabled: flow.cloudflareEnabled))
                .onSubmit { submit(from: .server) }
            }
            .loginFieldChrome(isFocused: focusedField == .server)
            .id(LoginField.server)
            Text(AppLocalization.string("No need to type https://. Conduit checks how this dashboard signs in next."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            HStack(spacing: 10) {
                // The system paste control: it reads the clipboard only when
                // tapped, so iOS asks nothing first.
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !pasted.isEmpty else { return }
                    DispatchQueue.main.async {
                        flow.address = pasted
                        flow.clearFailure()
                    }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .tint(.conduitAccent)
                .accessibilityIdentifier("\(prefix).paste")
                // A sign-in code from Hermes, or an address on another screen.
                Button {
                    Haptics.selection()
                    focusedField = nil
                    flow.showsScanner = true
                } label: {
                    Label(AppLocalization.string("Scan Code"), systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.conduitAccent)
                .disabled(flow.isWorking)
                .accessibilityIdentifier("\(prefix).scan")
            }
            .padding(.top, 2)
        }
    }

    private var addressLabel: String {
        context == .firstLaunch
            ? AppLocalization.string("Your Hermes dashboard address")
            : AppLocalization.string("Dashboard address")
    }

    private var advancedCard: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.selection()
                focusedField = nil
                withAnimation(ConduitMotion.response) { flow.showsAdvanced.toggle() }
            } label: {
                LoginRowLabel(
                    icon: "slider.horizontal.3",
                    title: AppLocalization.string("Advanced"),
                    detail: AppLocalization.string("Cloudflare Access token, extra headers"),
                    accessory: flow.showsAdvanced ? .expanded : .collapsed
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(prefix).advanced")
            if flow.showsAdvanced {
                advancedFields
                    .padding(16)
                    .overlay(alignment: .top) { V2RowDivider(leadingInset: 16) }
            }
        }
        .settingsCard()
    }

    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Use Cloudflare Access service token", isOn: Binding(
                get: { flow.cloudflareEnabled },
                set: { enabled in
                    flow.cloudflareEnabled = enabled
                    revealCloudflare = enabled
                    // Turning the section off mid-typing unmounts the field;
                    // drop focus so the keyboard never dangles.
                    if !enabled,
                       focusedField == .cloudflareClientID || focusedField == .cloudflareClientSecret {
                        focusedField = nil
                    }
                }
            ))
            .tint(.conduitAccent)
            .font(.callout.weight(.semibold))
            // Stable handles for the UI tests, apart from the copy; the Add
            // sheet's own don't repeat the sign-in screen's.
            .accessibilityIdentifier("\(prefix).cloudflare-toggle")
            if flow.cloudflareEnabled {
                TextField("Cloudflare Client ID", text: $flow.cloudflareClientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("\(prefix).cloudflare-client-id")
                    .focused($focusedField, equals: .cloudflareClientID)
                    .submitLabel(LoginField.cloudflareClientID.submitKeyboardLabel(cloudflareTokenEntryEnabled: true))
                    .onSubmit { submit(from: .cloudflareClientID) }
                    .loginFieldChrome(isFocused: focusedField == .cloudflareClientID)
                    .id(LoginField.cloudflareClientID)
                SecureField("Cloudflare Client Secret", text: $flow.cloudflareClientSecret)
                    .accessibilityIdentifier("\(prefix).cloudflare-client-secret")
                    .focused($focusedField, equals: .cloudflareClientSecret)
                    .submitLabel(LoginField.cloudflareClientSecret.submitKeyboardLabel(cloudflareTokenEntryEnabled: true))
                    .onSubmit { submit(from: .cloudflareClientSecret) }
                    .loginFieldChrome(isFocused: focusedField == .cloudflareClientSecret)
                    .id(LoginField.cloudflareClientSecret)
                Text("Used only to reach this Cloudflare-protected dashboard; the secret stays in Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                focusedField = nil
                flow.extraHeadersRequest = LoginExtraHeadersRequest(
                    serverURL: LoginAddress.bestGuess(flow.address)
                )
            } label: {
                HStack {
                    Text(AppLocalization.string("Extra headers"))
                        .font(.callout.weight(.semibold))
                    Spacer()
                    let count = extraHeaderCount
                    if count > 0 {
                        Text(verbatim: String(count))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.conduitTertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(flow.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("\(prefix).extra-headers")
        }
    }

    /// Valid extra headers saved for the address typed so far.
    private var extraHeaderCount: Int {
        _ = flow.extraHeadersRevision
        let address = LoginAddress.bestGuess(flow.address)
        return CustomHeaderPolicy.sendable(CustomHeaderStore.shared.headers(forServerURL: address)).count
    }

    /// Return walks the focus chain and submits only at its end.
    private func submit(from field: LoginField) {
        if let next = field.submitDestination(cloudflareTokenEntryEnabled: flow.cloudflareEnabled) {
            focusedField = next
        } else {
            focusedField = nil
            Task { await flow.continueFromAddress() }
        }
    }
}

// MARK: - The sign-in step

struct LoginCredentialsPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var flow: LoginFlowModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: LoginField?
    @State private var revealsPassword = false

    var body: some View {
        ZStack {
            ConduitBackdrop()
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        content
                            .frame(minHeight: geometry.size.height)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: focusedField) { _, field in
                        guard let field else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(field, anchor: .center)
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("Sign in"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .keyboardDoneButton { focusedField = nil }
        .onAppear {
            flow.refreshBiometrics()
            // Straight to the empty field: the username is often filled in.
            if flow.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                focusedField = .username
            } else if flow.password.isEmpty {
                focusedField = .password
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Face ID may have been set up meanwhile.
            if phase == .active { flow.refreshBiometrics() }
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            if let target = flow.target {
                targetCard(target)
            }
            fields
            LoginSignInOptionsCard(flow: flow)
            if let failure = flow.failure(at: .credentials) {
                LoginFailureCard(failure: failure, flow: flow)
            }
            Spacer(minLength: 12)
            VStack(spacing: 6) {
                LoginPrimaryButton(
                    title: flow.isWorking ? AppLocalization.string("Connecting…") : AppLocalization.string("Sign in"),
                    isBusy: flow.isWorking
                ) {
                    focusedField = nil
                    Task { await flow.signIn() }
                }
                .disabled(!flow.canSignIn)
                .accessibilityIdentifier("login.sign-in")
                if flow.target?.browserOffer != nil {
                    Button {
                        Haptics.selection()
                        focusedField = nil
                        Task { await flow.signInWithBrowserInstead() }
                    } label: {
                        Label(AppLocalization.string("Sign in with browser instead"), systemImage: "safari")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.conduitAccent)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(flow.isWorking)
                    .accessibilityIdentifier("login.browser-sign-in")
                }
            }
        }
        .loginReadableWidth()
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private func targetCard(_ target: LoginTarget) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.body.weight(.medium))
                .conduitFixedGlyph()
                .foregroundStyle(Color.conduitAccent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: target.label)
                    .font(.callout.weight(.semibold))
                Text(verbatim: LoginAddress.displayHost(target.baseURL))
                    .font(.subheadline)
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text("Password")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard()
        .accessibilityElement(children: .combine)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Username")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            TextField("Username", text: $flow.username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("login.username")
                .focused($focusedField, equals: .username)
                .submitLabel(LoginField.username.submitKeyboardLabel(cloudflareTokenEntryEnabled: false))
                .onSubmit { submit(from: .username) }
                .loginFieldChrome(isFocused: focusedField == .username)
                .id(LoginField.username)
            Text("Password")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 6)
            HStack(spacing: 4) {
                Group {
                    if revealsPassword {
                        TextField("Password", text: $flow.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("Password", text: $flow.password)
                    }
                }
                .textContentType(.password)
                .accessibilityIdentifier("login.password")
                .focused($focusedField, equals: .password)
                .submitLabel(LoginField.password.submitKeyboardLabel(cloudflareTokenEntryEnabled: false))
                .onSubmit { submit(from: .password) }
                Button {
                    revealsPassword.toggle()
                    focusedField = .password
                } label: {
                    Image(systemName: revealsPassword ? "eye.slash" : "eye")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealsPassword ? AppLocalization.string("Hide password") : AppLocalization.string("Show password"))
            }
            .loginFieldChrome(isFocused: focusedField == .password, trailingPadding: 4)
            .id(LoginField.password)
        }
    }

    private func submit(from field: LoginField) {
        if let next = field.submitDestination(cloudflareTokenEntryEnabled: false) {
            focusedField = next
        } else {
            focusedField = nil
            Task { await flow.signIn() }
        }
    }
}

/// Save sign-in, and Face ID or Touch ID, for a password sign-in: on the
/// sign-in step and a sign-in code's sheet.
struct LoginSignInOptionsCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var flow: LoginFlowModel

    var body: some View {
        VStack(spacing: 0) {
            LoginSwitchRow(
                title: AppLocalization.string("Save sign-in"),
                detail: AppLocalization.string("Signs you back in on its own when the session ends."),
                isOn: Binding(get: { flow.saveSignIn }, set: { flow.setSaveSignIn($0) }),
                identifier: "login.save-sign-in"
            )
            // Face ID and Touch ID share this setting; the wording follows
            // the phone's sensor. A phone without one shows no row.
            if flow.biometrics.isAvailable {
                LoginSwitchRow(
                    title: flow.biometrics.kind == .touchID
                        ? AppLocalization.string("Use Touch ID")
                        : AppLocalization.string("Use Face ID"),
                    detail: flow.biometrics.kind == .touchID
                        ? AppLocalization.string("Touch ID unlocks the saved sign-in when Conduit opens.")
                        : AppLocalization.string("Face ID unlocks the saved sign-in when Conduit opens."),
                    isOn: $flow.useBiometrics,
                    identifier: "login.biometric-toggle"
                )
                .disabled(!flow.saveSignIn)
                .overlay(alignment: .top) { V2RowDivider(leadingInset: 16) }
            }
        }
        .settingsCard()
    }
}

// MARK: - Saved dashboards

/// The sign-in screen when dashboards are saved: each is one tap away.
struct LoginDashboardsScreen: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @ObservedObject var flow: LoginFlowModel
    let addDashboard: () -> Void

    @State private var signIns: [UUID: SavedSignInKind] = [:]
    @State private var biometricKind: BiometricAuth.Kind?
    @State private var pendingRemoval: SavedDashboard?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(minHeight: geometry.size.height)
            }
        }
        // Keychain reads stay off the render path: the kinds are worked out
        // when the list or the sign-in state changes.
        .task { refreshSignIns() }
        .onChange(of: appState.savedDashboardRegistry) { _, _ in refreshSignIns() }
        .onChange(of: appState.isConnecting) { _, _ in refreshSignIns() }
        .onChange(of: flow.isWorking) { _, _ in refreshSignIns() }
        .confirmationDialog(
            AppLocalization.string("Remove Dashboard?"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Remove Dashboard"), role: .destructive) {
                if let dashboard = pendingRemoval {
                    flow.clearFailure()
                    appState.removeDashboard(dashboard.id)
                }
                pendingRemoval = nil
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text("This dashboard's saved sign-in and cookies will be deleted from this device. Other dashboards are not affected.")
        }
    }

    private var dashboards: [SavedDashboard] {
        appState.savedDashboardRegistry.dashboards
    }

    private var content: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 28)
            LoginHeader(style: .welcomeBack)
            if let failure = flow.failure(at: .address) {
                LoginFailureCard(failure: failure, flow: flow)
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(
                    title: AppLocalization.string("Your dashboards"),
                    symbol: "server.rack",
                    tint: .conduitAccent
                )
                VStack(spacing: 0) {
                    ForEach(Array(dashboards.enumerated()), id: \.element.id) { index, dashboard in
                        row(dashboard, first: index == 0)
                    }
                }
                .settingsCard()
            }
            Button {
                Haptics.selection()
                addDashboard()
            } label: {
                LoginRowLabel(
                    icon: "plus.circle",
                    title: AppLocalization.string("Add a dashboard"),
                    detail: AppLocalization.string("Paste or type its address"),
                    accessory: .chevron
                )
            }
            .buttonStyle(.plain)
            .disabled(flow.isWorking)
            .settingsCard()
            .accessibilityIdentifier("login.add-dashboard")
            Spacer(minLength: 12)
            VStack(spacing: 4) {
                LoginHelpLink(identifier: "login.connection-setup") {
                    flow.connectionSetupDestination = .start
                }
                Text("Your sign-in stays on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .loginReadableWidth()
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func row(_ dashboard: SavedDashboard, first: Bool) -> some View {
        let failure = flow.failure(at: .dashboard(dashboard.id))
        VStack(spacing: 0) {
            Button {
                Haptics.selection()
                Task { await flow.open(dashboard) }
            } label: {
                LoginRowLabel(
                    icon: "server.rack",
                    title: dashboard.label,
                    detail: LoginAddress.displayHost(dashboard.normalizedURL),
                    status: failure == nil ? status(for: dashboard) : nil,
                    accessory: isConnecting(dashboard) ? .progress : .chevron
                )
            }
            .buttonStyle(.plain)
            .disabled(flow.isWorking && flow.workingDashboardID != dashboard.id)
            .accessibilityIdentifier("login.dashboard.row")
            .contextMenu {
                Button(role: .destructive) {
                    pendingRemoval = dashboard
                } label: {
                    Label(AppLocalization.string("Remove Dashboard"), systemImage: "trash")
                }
                // Not while it connects: the connection would register it
                // again.
                .disabled(isConnecting(dashboard))
            }
            if let failure {
                LoginFailureCard(failure: failure, flow: flow, isInline: true)
                    .padding(.leading, 56)
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
            }
        }
        .background(failure == nil ? Color.clear : Color.red.opacity(0.07))
        .overlay(alignment: .top) {
            if !first { V2RowDivider(leadingInset: 56) }
        }
    }

    private func isConnecting(_ dashboard: SavedDashboard) -> Bool {
        flow.workingDashboardID == dashboard.id
            || (dashboard.id == appState.activeDashboardID && appState.isConnecting && !flow.isWorking)
    }

    private func status(for dashboard: SavedDashboard) -> LoginRowLabel.Status? {
        var text: String
        let icon: String
        var tint: Color = Color.primary.opacity(0.58)
        if isConnecting(dashboard) {
            text = AppLocalization.string("Connecting…")
            icon = "arrow.triangle.2.circlepath"
        } else {
            // Unknown until the first Keychain read: no line, rather than
            // a "Sign in needed" that is wrong for a moment.
            guard let kind = signIns[dashboard.id] else { return nil }
            switch kind {
            case .biometric:
                if biometricKind == .touchID {
                    text = AppLocalization.string("Signs in with Touch ID")
                    icon = "touchid"
                } else {
                    text = AppLocalization.string("Signs in with Face ID")
                    icon = "faceid"
                }
            case .password, .session:
                text = AppLocalization.string("Saved sign-in")
                icon = "key"
            case .signInNeeded:
                text = AppLocalization.string("Sign in needed")
                icon = "clock"
                tint = .orange
            }
        }
        if dashboards.count > 1, dashboard.id == appState.activeDashboardID {
            text = AppLocalization.string("\(text) · Last used")
        }
        return LoginRowLabel.Status(text: text, icon: icon, tint: tint)
    }

    private func refreshSignIns() {
        let biometrics = BiometricAuth.status
        biometricKind = biometrics.kind
        var kinds: [UUID: SavedSignInKind] = [:]
        for dashboard in dashboards {
            var kind = appState.savedSignIn(for: dashboard.id)
            // With Face ID off the row opens its sign-in page, so it says
            // a sign-in is needed.
            if kind == .biometric, !biometrics.isAvailable { kind = .signInNeeded }
            kinds[dashboard.id] = kind
        }
        signIns = kinds
    }
}

// MARK: - Shared pieces

/// The logo over the screen's greeting.
struct LoginHeader: View {
    enum Style {
        case firstLaunch
        case welcomeBack
    }

    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let style: Style

    var body: some View {
        let iconSize: CGFloat = style == .firstLaunch ? 84 : 64
        VStack(spacing: style == .firstLaunch ? 14 : 12) {
            Image(iconAssetName)
                .resizable()
                .scaledToFill()
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous)
                        .strokeBorder(Color.conduitAccent.opacity(0.28), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 5, y: 4)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                switch style {
                case .firstLaunch:
                    Text("Conduit")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("A focused home for your Hermes work")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                case .welcomeBack:
                    Text("Welcome back")
                        .font(.title2.weight(.semibold))
                    Text("Choose a dashboard to connect to.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
    }

    private var iconAssetName: String {
        switch appState.themePreference {
        case .light:
            return AppIconChoice.light.previewAssetName
        case .dark:
            return AppIconChoice.dark.previewAssetName
        case .system:
            return colorScheme == .dark ? AppIconChoice.dark.previewAssetName : AppIconChoice.light.previewAssetName
        }
    }
}

/// A row in a sign-in card: the gold glyph, the name over a short detail and
/// an optional status line, and a trailing chevron, disclosure or spinner.
struct LoginRowLabel: View {
    enum Accessory {
        case chevron
        case collapsed
        case expanded
        case progress
        /// Nothing to tap: the row only tells.
        case hidden
    }

    struct Status {
        let text: String
        let icon: String
        let tint: Color
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let title: String
    let detail: String
    var status: Status? = nil
    var accessory: Accessory = .chevron

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .conduitFixedGlyph()
                .foregroundStyle(Color.conduitAccent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if let status {
                    HStack(spacing: 5) {
                        Image(systemName: status.icon)
                            .font(.caption.weight(.semibold))
                            .conduitFixedGlyph()
                            .accessibilityHidden(true)
                        Text(verbatim: status.text)
                            .font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(status.tint)
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 8)
            switch accessory {
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.conduitTertiary)
                    .accessibilityHidden(true)
            case .collapsed, .expanded:
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.conduitTertiary)
                    .rotationEffect(.degrees(accessory == .expanded ? 180 : 0))
                    .accessibilityHidden(true)
            case .progress:
                ProgressView()
            case .hidden:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

/// A switch row in a sign-in card, its explanation under the name.
struct LoginSwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let identifier: String

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.callout.weight(.semibold))
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.conduitAccent)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 60)
        .accessibilityIdentifier(identifier)
    }
}

/// The gold capsule that moves the flow on (Continue, Sign in).
struct LoginPrimaryButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    var isBusy = false
    let action: () -> Void

    /// Dark text on the dark theme's gold, white on the light theme's brown.
    private static let labelColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.82) : .white
    })

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .tint(Self.labelColor)
                }
                Text(verbatim: title)
                    .font(.headline)
                if !isBusy {
                    Image(systemName: "arrow.right")
                        .font(.headline)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(Self.labelColor)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(Color.conduitAccent, in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// "Need help connecting?": opens the Connection Setup assistant.
struct LoginHelpLink: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Label("Need help connecting?", systemImage: "questionmark.circle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// A failure where it happened, with what can be done about it.
struct LoginFailureCard: View {
    @EnvironmentObject private var appState: AppState
    let failure: ConnectionFailurePresentation
    @ObservedObject var flow: LoginFlowModel
    /// Under a dashboard's row, inside its card, rather than a card of its
    /// own.
    var isInline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.red)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: failure.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.red)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("login.error.title")
                    if !failure.message.isEmpty {
                        Text(verbatim: failure.message)
                            .font(.footnote)
                            .foregroundStyle(Color.primary.opacity(0.72))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if failure.offersRecoveryActions {
                AdaptiveStack(spacing: 8) {
                    // A dashboard whose sign-in ended (an auth proxy whose
                    // session expired, Hermes' own sign-in) is retried by
                    // signing in again: the retry opens that sign-in.
                    Button(failure.asksToSignInAgain ? AppLocalization.string("Sign In Again") : AppLocalization.string("Try Again")) {
                        Haptics.selection()
                        Task { await flow.retry() }
                    }
                    .buttonStyle(LoginCapsuleButtonStyle(prominent: true))
                    .disabled(flow.isWorking)
                    .accessibilityIdentifier(failure.asksToSignInAgain ? "login.error.sign-in-again" : "login.error.try-again")

                    if let destination = failure.helpDestination {
                        Button(AppLocalization.string("Troubleshoot Connection")) {
                            flow.connectionSetupDestination = destination
                        }
                        .buttonStyle(LoginCapsuleButtonStyle())
                        .accessibilityIdentifier("login.error.troubleshoot")
                    }

                    // A failed SAVED sign-in is a failed existing connection:
                    // offer the repair flow seeded from it. The typed failure
                    // proves where it came from (typed sign-ins never set
                    // it).
                    if flow.savedRepairAvailable, appState.lastConnectionFailure != nil {
                        Button(AppLocalization.string("Repair Connection")) {
                            flow.beginRepair()
                        }
                        .buttonStyle(LoginCapsuleButtonStyle())
                        .accessibilityIdentifier("login.repair-connection")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isInline ? 0 : 14)
        .background {
            if !isInline {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.red.opacity(0.07))
            }
        }
        .overlay {
            if !isInline {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.18), lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The failure card's small capsules: gold for the retry, glass otherwise.
struct LoginCapsuleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.82) : .white
            }) : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(
                prominent ? Color.conduitAccent : Color.primary.opacity(0.08),
                in: Capsule()
            )
            .overlay {
                if !prominent {
                    Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// A sign-in screen's column on a wide screen (an iPad, a wide window): a
/// readable width in the middle rather than edge to edge, as wide as the
/// cards Hermes shows in a chat at the default text size. It grows with the
/// text size, as UIKit's readable content guide does. An iPhone is
/// narrower, so it never applies there.
private struct LoginReadableWidth: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var maxWidth: CGFloat = 560

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// A sign-in screen's column: see `LoginReadableWidth`.
    func loginReadableWidth() -> some View {
        modifier(LoginReadableWidth())
    }

    /// A sign-in field: a quiet rounded well that turns gold while focused.
    func loginFieldChrome(isFocused: Bool, trailingPadding: CGFloat = 14) -> some View {
        self
            .padding(.leading, 14)
            .padding(.trailing, trailingPadding)
            .frame(minHeight: 52)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.conduitAccent.opacity(0.55) : Color.primary.opacity(0.14),
                        lineWidth: 1
                    )
            }
    }
}

// MARK: - Presentations

/// The sheets a sign-in flow presents, shared by the sign-in screen and the
/// Add a dashboard sheet.
struct LoginFlowPresentations: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var flow: LoginFlowModel
    /// The Connection Setup assistant's result. By default it fills in the
    /// address step.
    var onSetupResult: ((ConnectionSetupResult) -> Void)? = nil
    /// Runs once the assistant is gone, for a sheet that should follow it.
    var onSetupDismissed: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .sheet(item: $flow.connectionSetupDestination, onDismiss: onSetupDismissed) { destination in
                ConnectionSetupView(
                    initialDestination: destination,
                    initialDraft: ConnectionSetupDraft(
                        existingServerURL: LoginAddress.bestGuess(flow.address),
                        username: flow.username,
                        password: flow.password
                    ),
                    // The probe may reuse this same-origin service token; the
                    // assistant checks the origin itself before sending it
                    // and never shows, edits or saves it.
                    initialCloudflareAccess: flow.typedCloudflare,
                    initialCloudflareOriginURL: LoginAddress.bestGuess(flow.address)
                ) { result in
                    if let onSetupResult {
                        onSetupResult(result)
                    } else {
                        flow.applySetupResult(result)
                    }
                }
                .environmentObject(appState)
            }
            .sheet(item: $flow.connectionRepairContext) { context in
                ConnectionRepairSetupSheet(context: context)
                    .environmentObject(appState)
            }
            .sheet(item: $flow.extraHeadersRequest) { request in
                CustomHeadersEditorSheet(
                    serverURL: request.serverURL,
                    headers: CustomHeaderStore.shared.headers(forServerURL: request.serverURL)
                ) { headers in
                    CustomHeaderStore.shared.setHeaders(headers, forServerURL: request.serverURL)
                    flow.extraHeadersRevision += 1
                }
            }
            .sheet(item: $flow.nativeOAuthRequest) { request in
                NativeOAuthSignInSheet(
                    baseURL: request.baseURL,
                    cloudflareAccess: request.cloudflare,
                    provider: request.provider,
                    dashboardID: request.dashboardID,
                    onSuccess: { result in
                        Task { @MainActor in
                            await flow.nativeOAuthSucceeded(result, request: request)
                        }
                    },
                    onError: { error in
                        flow.nativeOAuthFailed(error)
                    }
                )
            }
            .sheet(isPresented: $flow.showsScanner, onDismiss: { flow.scannerDismissed() }) {
                DashboardCodeScannerSheet { text in
                    flow.scanned(text)
                }
            }
            .sheet(item: $flow.pendingLink) { link in
                ConnectLinkSheet(link: link) {
                    flow.onSignedIn()
                }
                .environmentObject(appState)
            }
            .sheet(item: $flow.browserRequest) { request in
                AuthWebView(
                    url: request.baseURL,
                    cloudflareAccess: request.cloudflare,
                    dashboardIDProvider: { [appState] in
                        appState.resolveDashboardID(forURL: request.baseURL, registerIfMissing: true)
                    },
                    websiteDataStoreIdentifier: request.webKitStoreID,
                    onTicket: { ticket, baseURL in
                        // The dashboard only bridges the sign-in: close it
                        // before the session starts, so Conduit takes over
                        // as soon as the ticket arrives.
                        Task { @MainActor in
                            await flow.browserDeliveredTicket(ticket, baseURL: baseURL)
                        }
                    },
                    onError: { classifiedFailure, detail in
                        flow.browserFailed(classifiedFailure, detail: detail)
                    }
                )
                .asSignInSheet()
            }
    }
}

// MARK: - Add a dashboard

/// Adds a dashboard without leaving what's on screen: Cancel leaves the
/// current chat alone. Used from the sign-in screen's list and from
/// Settings > Saved Dashboards.
struct AddDashboardSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow = LoginFlowModel()
    @State private var seeded = false
    /// Filled in from the Connection Setup assistant, when it led here.
    var seed: LoginSeed? = nil
    /// Runs after the sheet closes on a sign-in.
    var onSignedIn: () -> Void = {}

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                LoginAddressStep(flow: flow, context: .addSheet)
            }
            .navigationTitle(Text("Add a dashboard"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // A sign-in under way finishes or fails first, as the
                    // swipe down waits for it.
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                        .disabled(flow.isWorking)
                        .accessibilityIdentifier("add-dashboard.cancel")
                }
            }
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
            guard !seeded else { return }
            seeded = true
            if let seed { flow.apply(seed) }
        }
        // Cancel leaves nothing behind: a browser or single sign-on attempt
        // saves its dashboard before anyone signs in.
        .onDisappear { flow.discardUnfinishedDashboards() }
    }
}
