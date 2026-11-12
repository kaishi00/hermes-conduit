//
//  CredentialVaultViews.swift
//  Conduit
//
//  Settings > Passwords & logins: the logins, cards and addresses Hermes
//  signs in and fills pages with (its credential vault, `vault.*`), and
//  the password managers it may take logins from. Write-only: the page
//  lists what Hermes describes (a label, the site, a login's email or
//  username) and never a password, which Hermes doesn't send. What the
//  Add form and the Unlock field hold lives only in their own view state.
//

import SwiftUI

struct CredentialVaultSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @State private var snapshot: CredentialVaultSnapshot?
    @State private var loading = false
    @State private var problem: CredentialVaultError?
    @State private var error: String?
    /// Counts the reads, so one a later read overtook never lands.
    @State private var readCount = 0
    @State private var adding = false
    @State private var unlocking: VaultSource?
    @State private var removing: VaultItem?
    /// A source or item a call is out for: its controls wait.
    @State private var busy: Set<String> = []
    /// A manager switched here while Hermes takes it: the switch shows the
    /// new state until the list is read again.
    @State private var switching: [String: Bool] = [:]

    var body: some View {
        SettingsDetailContainer(compact: true) {
            Text(AppLocalization.string("For the \(appState.profileDisplayName(appState.activeProfile)) profile. Ask Hermes to sign in to a site and it asks you for the login once, on the spot, then signs in by itself. Passwords stay encrypted on the Hermes computer and go straight into the page: the model never sees them, and Conduit never shows them.", table: .connection))
                .scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem, snapshot == nil {
                unavailable(problem)
            } else {
                itemsSection
                managersSection
            }
        }
        .navigationTitle(AppLocalization.string("Passwords & logins"))
        .onAppear {
            guard snapshot == nil, let kept = appState.keptCredentialVault() else { return }
            snapshot = kept
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(isPresented: $adding) {
            VaultItemAddSheet { request in
                try await appState.addCredentialVaultItem(request)
                await reload()
            }
        }
        .sheet(item: $unlocking) { source in
            VaultSourceUnlockSheet(source: source) { password in
                try await appState.unlockCredentialVaultSource(source.name, password: password)
                await reload()
            }
        }
        .confirmationDialog(
            AppLocalization.string("Remove this item?", table: .connection),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { item in
            Button(AppLocalization.string("Remove"), role: .destructive) { remove(item) }
        } message: { item in
            Text(AppLocalization.string("Hermes forgets “\(item.label)”. This can't be undone.", table: .connection))
        }
    }

    // MARK: Sections

    private var itemsSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Saved"), symbol: "key.fill", tint: .conduitAccent) {
            if let snapshot {
                if snapshot.items.isEmpty {
                    Text(AppLocalization.string("Nothing saved yet. You don't have to add anything: Hermes asks for a login the first time it needs one. Use Add to enter one ahead of time.", table: .connection))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(snapshot.items) { item in
                    itemRow(item, sources: snapshot.sources)
                }
            } else if !loading, error != nil {
                retryButton
            } else {
                ProgressView().controlSize(.small).accessibilityLabel(AppLocalization.string("Loading…"))
            }
            if let error { Text(error).scaledFont(.caption).foregroundStyle(.red) }
            Button { adding = true } label: {
                Label(AppLocalization.string("Add a login, card or address", table: .connection), systemImage: "plus")
            }
            .buttonStyle(.settings)
            .disabled(snapshot == nil)
            .accessibilityIdentifier("settings.vault.add")
        }
    }

    @ViewBuilder
    private var managersSection: some View {
        if let managers = snapshot?.managers, !managers.isEmpty {
            ConduitSettingsSection(title: AppLocalization.string("Password managers", table: .connection), symbol: "lock.shield", tint: .conduitAura) {
                Text(AppLocalization.string("Hermes picks up a password manager installed on its computer. It asks you to unlock one the first time it needs a login from it; only the manager's session stays in Hermes' memory, never your master password.", table: .connection))
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(managers) { source in
                    managerRow(source)
                }
            }
        }
    }

    private func itemRow(_ item: VaultItem, sources: [VaultSource]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol(for: item))
                .foregroundStyle(Color.conduitAccent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.label).scaledFont(.subheadline.weight(.medium)).lineLimit(1)
                    if item.hasOTP {
                        badge(AppLocalization.string("2FA codes", table: .connection))
                    }
                }
                Text(details(of: item, sources: sources))
                    .scaledFont(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .privacySensitive()
            }
            Spacer(minLength: 8)
            if item.isLocal {
                Button { removing = item } label: {
                    Image(systemName: "trash")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(busy.contains(item.id))
                .accessibilityLabel(AppLocalization.string("Remove \(item.label)"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func managerRow(_ source: VaultSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(source.displayName).scaledFont(.subheadline.weight(.medium))
                badge(source.status)
                Spacer(minLength: 8)
                if source.installed {
                    Toggle(source.displayName, isOn: Binding(get: { switching[source.name] ?? source.enabled }, set: { setEnabled(source, $0) }))
                        .labelsHidden()
                        .tint(.conduitAccent)
                        .disabled(busy.contains(source.name))
                }
            }
            Text(source.caption).scaledFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if source.installed, source.enabled {
                if source.unlocked {
                    Button { lock(source) } label: {
                        Label(AppLocalization.string("Lock", table: .connection), systemImage: "lock")
                    }
                    .buttonStyle(.settings)
                    .disabled(busy.contains(source.name))
                } else {
                    Button { unlocking = source } label: {
                        Label(AppLocalization.string("Unlock", table: .connection), systemImage: "key")
                    }
                    .buttonStyle(.settings)
                    .disabled(busy.contains(source.name))
                }
            }
        }
    }

    private func unavailable(_ problem: CredentialVaultError) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Saved"), symbol: "key.fill", tint: .conduitAccent) {
            Text(problem.errorDescription ?? "")
                .scaledFont(.footnote).foregroundStyle(.secondary)
            retryButton
        }
    }

    private var retryButton: some View {
        Button { Task { await reload() } } label: {
            Label(AppLocalization.string("Try again"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(.settings)
        .disabled(loading)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .scaledFont(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    private func symbol(for item: VaultItem) -> String {
        switch item.knownKind {
        case .payment: "creditcard"
        case .address: "house"
        default: "person.badge.key"
        }
    }

    /// The kind, the login's identifier, the site and where it lives, as
    /// one line of facts.
    private func details(of item: VaultItem, sources: [VaultSource]) -> String {
        var parts: [String] = [item.knownKind?.title ?? item.kind]
        if let identifier = item.identifier { parts.append(identifier) }
        if let origin = item.shownOrigin { parts.append(origin) }
        if !item.isLocal {
            parts.append(sources.first(where: { $0.name == item.source })?.displayName ?? item.source)
        } else if let date = item.createdAt {
            parts.append(AppLocalization.string("Added \(date.formatted(date: .abbreviated, time: .omitted))", table: .connection))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Calls

    /// `retrying`: once, after an answer about the connection or profile
    /// before; the page then asks the one in use.
    private func reload(retrying: Bool = false) async {
        readCount += 1
        let read = readCount
        loading = true
        do {
            let answer = try await appState.loadCredentialVault()
            guard read == readCount else { return }
            // A manager switched on shows its Unlock row as Settings'
            // other switches reveal theirs.
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { snapshot = answer }
            problem = nil
            error = nil
        } catch let failure as CredentialVaultError {
            guard read == readCount else { return }
            if failure == .superseded, !retrying {
                snapshot = nil
                await reload(retrying: true)
                return
            }
            problem = failure
            // Over a kept list, the line under it says why it isn't fresh.
            error = failure.errorDescription
        } catch is CancellationError {
            // The page went away mid-read; the next one asks again.
            if read == readCount { loading = false }
            return
        } catch let failure {
            guard read == readCount else { return }
            // An older Hermes or no connection said so before; this one
            // failed another way, which the list's line says.
            problem = nil
            // A read that fails keeps what's shown.
            error = UserFacingError.message(for: failure)
        }
        loading = false
    }

    /// Runs a change, then reads the vault again; `after` runs once that
    /// read is in, so a switch shows Hermes' state, or the old one when the
    /// change failed.
    private func run(_ id: String, after: @escaping () -> Void = {}, _ call: @escaping () async throws -> Void) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        Task {
            var failed: String?
            do {
                try await call()
            } catch let failure {
                failed = UserFacingError.message(for: failure)
            }
            await reload()
            // The read after it answers for the list, not for the change:
            // a change that failed still says so.
            if let failed { error = failed }
            after()
            busy.remove(id)
        }
    }

    private func remove(_ item: VaultItem) {
        run(item.id) { _ = try await appState.removeCredentialVaultItem(id: item.id) }
    }

    private func setEnabled(_ source: VaultSource, _ enabled: Bool) {
        guard !busy.contains(source.name) else { return }
        switching[source.name] = enabled
        run(source.name, after: { switching[source.name] = nil }) {
            try await appState.setCredentialVaultSource(source.name, enabled: enabled)
        }
    }

    private func lock(_ source: VaultSource) {
        run(source.name) { try await appState.lockCredentialVaultSource(source.name) }
    }
}

/// Unlocks a password manager for Hermes with its master password, which
/// lives in this sheet's state until it goes once onto the socket.
private struct VaultSourceUnlockSheet: View {
    let source: VaultSource
    let unlock: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            SettingsDetailContainer(compact: true) {
                ConduitSettingsSection(title: source.displayName, symbol: "lock.shield", tint: .conduitAura) {
                    Text(AppLocalization.string("Hermes hands your master password to \(source.displayName) on its computer and forgets it. It's never saved, logged or shown to the model.", table: .connection))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // No .password content type: iOS would offer to save the
                    // master password to the keychain under Conduit's domain.
                    SecureField(AppLocalization.string("Master password"), text: $password)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                        .disabled(working)
                        .accessibilityIdentifier("settings.vault.masterPassword")
                    if let error { Text(error).scaledFont(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle(AppLocalization.string("Unlock \(source.displayName)"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(AppLocalization.string("Unlock", table: .connection)) { submit() }
                            .disabled(password.isEmpty)
                    }
                }
            }
        }
        .disabled(working)
        .interactiveDismissDisabled(working)
        .presentationDetents([.medium, .large])
    }

    private func submit() {
        guard !working, !password.isEmpty else { return }
        working = true
        error = nil
        let typed = password
        Task {
            do {
                try await unlock(typed)
                password = ""
                dismiss()
            } catch let failure {
                error = UserFacingError.message(for: failure)
            }
            working = false
        }
    }
}

/// Adds a login, card or address to Hermes' own vault. The fields live in
/// this sheet's state and go once onto the socket.
private struct VaultItemAddSheet: View {
    let save: (VaultItemDraft.Request) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = VaultItemDraft()
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            SettingsDetailContainer(compact: true) {
                Picker(AppLocalization.string("Kind"), selection: $draft.kind) {
                    ForEach(VaultItem.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                ConduitSettingsSection(title: AppLocalization.string("Name and site", table: .connection), symbol: "globe", tint: .conduitAccent) {
                    plainField(AppLocalization.string("Label, like GitHub work account", table: .connection), text: $draft.label)
                    plainField(draft.kind == .login ? AppLocalization.string("Site, like github.com", table: .connection) : AppLocalization.string("Site (optional)", table: .connection), text: $draft.origin, keyboard: .URL)
                    Text(AppLocalization.string("Saved encrypted on the Hermes computer. Conduit keeps none of it and never shows it again.", table: .connection))
                        .scaledFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch draft.kind {
                case .login: loginFields
                case .payment: cardFields
                case .address: addressFields
                }
                if let error { Text(error).scaledFont(.caption).foregroundStyle(.red) }
            }
            .navigationTitle(AppLocalization.string("Add to vault", table: .connection))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                        .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(AppLocalization.string("Save")) { submit() }
                            .accessibilityIdentifier("settings.vault.save")
                    }
                }
            }
            .disabled(working)
        }
        .interactiveDismissDisabled(working)
    }

    private var loginFields: some View {
        ConduitSettingsSection(title: AppLocalization.string("Login", table: .connection), symbol: "person.badge.key", tint: .conduitAura) {
            Picker(AppLocalization.string("Signs in with", table: .connection), selection: $draft.identifierType) {
                ForEach(VaultItemDraft.IdentifierType.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            // No .username / .password content types: iOS would offer to
            // save the site's login to the keychain under Conduit's domain.
            plainField(draft.identifierType.title, text: $draft.identifier, keyboard: draft.identifierType == .email ? .emailAddress : (draft.identifierType == .phone ? .phonePad : .asciiCapable))
                .privacySensitive()
            secretField(AppLocalization.string("Password"), text: $draft.password)
            secretField(AppLocalization.string("Authenticator key (optional)", table: .connection), text: $draft.otpSecret)
            Text(AppLocalization.string("The setup key a site shows when you turn on two-factor sign-in, or its otpauth:// link. With it saved, Hermes makes the codes itself.", table: .connection))
                .scaledFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cardFields: some View {
        ConduitSettingsSection(title: AppLocalization.string("Payment card", table: .connection), symbol: "creditcard", tint: .conduitAura) {
            secretField(AppLocalization.string("Card number", table: .connection), text: $draft.cardNumber, keyboard: .numberPad)
            plainField(AppLocalization.string("Name on card (optional)", table: .connection), text: $draft.cardholderName)
                .privacySensitive()
            HStack {
                plainField(AppLocalization.string("Month", table: .connection), text: $draft.expMonth, keyboard: .numberPad)
                plainField(AppLocalization.string("Year", table: .connection), text: $draft.expYear, keyboard: .numberPad)
                secretField(AppLocalization.string("Security code", table: .connection), text: $draft.cvc, keyboard: .numberPad)
            }
            plainField(AppLocalization.string("Billing postal code (optional)", table: .connection), text: $draft.postalCode)
                .privacySensitive()
        }
    }

    private var addressFields: some View {
        ConduitSettingsSection(title: AppLocalization.string("Postal address", table: .connection), symbol: "house", tint: .conduitAura) {
            Group {
                plainField(AppLocalization.string("Street", table: .connection), text: $draft.addressLine1)
                plainField(AppLocalization.string("Apartment, suite (optional)", table: .connection), text: $draft.addressLine2)
                plainField(AppLocalization.string("City", table: .connection), text: $draft.city)
                plainField(AppLocalization.string("State or region (optional)", table: .connection), text: $draft.state)
                plainField(AppLocalization.string("Postal code", table: .connection), text: $draft.postalCode)
                plainField(AppLocalization.string("Country", table: .connection), text: $draft.country)
            }
            .privacySensitive()
        }
    }

    private func plainField(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(keyboard == .default ? .words : .never)
    }

    private func secretField(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .asciiCapable) -> some View {
        SecureField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }

    private func submit() {
        guard !working else { return }
        switch draft.request() {
        case .failure(let problem):
            error = problem.message
        case .success(let request):
            working = true
            error = nil
            Task {
                do {
                    try await save(request)
                    draft = VaultItemDraft()
                    dismiss()
                } catch let failure {
                    error = UserFacingError.message(for: failure)
                }
                working = false
            }
        }
    }
}
