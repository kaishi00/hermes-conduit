//
//  HostedAppsViews.swift
//  Conduit
//
//  Settings > Capabilities > Connectors > Apps: the apps Hermes reaches
//  through Nous Portal's hosted connectors, as Hermes Desktop's Connectors
//  page draws them, each with its own logo. Your apps sit at the top of
//  the Connectors tab; Browse Apps lists the whole catalog by category; an
//  app's page connects it (its own sign-in page in Safari), lists its
//  accounts to name, sign in again or disconnect, turns it on or off for
//  Hermes and switches its tools. Hermes and the Portal keep every
//  sign-in: nothing here holds one.
//

import SwiftUI
import UIKit
import WebKit

// MARK: The section on the Connectors tab

struct HostedAppsSection: View {
    let model: HostedAppsModel
    let query: String

    private var apps: [HostedApp] { model.snapshot?.apps ?? [] }

    private var yours: [HostedApp] {
        apps.filter { $0.isYours && HostedAppsSection.matches($0, query) }
            .sorted { ($0.needsReconnect ? 0 : 1, $0.title.lowercased()) < ($1.needsReconnect ? 0 : 1, $1.title.lowercased()) }
    }

    /// The catalog's apps a search on the tab finds, beyond yours.
    private var found: [HostedApp] {
        guard !query.isEmpty else { return [] }
        return apps.filter { !$0.isYours && HostedAppsSection.matches($0, query) }.prefix(8).map { $0 }
    }

    static func matches(_ app: HostedApp, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [app.title, app.slug, app.category, app.description].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                if snapshot.available, !(query.isEmpty == false && yours.isEmpty && found.isEmpty) {
                    CapabilitySection(
                        title: AppLocalization.string("Apps"),
                        symbol: "square.grid.3x3.fill",
                        tint: .conduitAura,
                        footer: AppLocalization.string("Signed in through Nous Portal. Hermes keeps the sign-ins; changes apply to new chats.")
                    ) {
                        ForEach(Array(yours.enumerated()), id: \.element.id) { index, app in
                            CapabilityCardRow(divided: index > 0) {
                                HostedAppRow(app: app, model: model)
                            }
                        }
                        ForEach(Array(found.enumerated()), id: \.element.id) { index, app in
                            CapabilityCardRow(divided: index > 0 || !yours.isEmpty) {
                                HostedAppRow(app: app, model: model)
                            }
                        }
                        if query.isEmpty {
                            CapabilityCardRow(divided: !yours.isEmpty) {
                                NavigationLink {
                                    HostedAppsDirectoryPage(model: model)
                                        .v2TabBarClearance()
                                } label: {
                                    CapabilityRowLabel(
                                        symbol: "plus",
                                        title: yours.isEmpty ? AppLocalization.string("Connect an App") : AppLocalization.string("Browse Apps"),
                                        detail: yours.isEmpty
                                            ? AppLocalization.string("Gmail, Slack, Notion and more: sign in once and Hermes can use them.")
                                            : AppLocalization.string("\(snapshot.catalog.count) apps"),
                                        chevron: true
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("capabilities.apps.browse")
                            }
                        }
                    }
                }
            } else if model.error == .unsupported || model.error == nil && !model.loading {
                EmptyView()
            } else if let message = model.errorMessage {
                CapabilityRefreshBanner(message: message)
            }
        }
    }
}

/// One app: its logo, name and state, opening its page.
private struct HostedAppRow: View {
    let app: HostedApp
    let model: HostedAppsModel

    var body: some View {
        NavigationLink {
            HostedAppPage(slug: app.slug, model: model)
                .v2TabBarClearance()
        } label: {
            HStack(spacing: 11) {
                HostedAppLogo(app: app, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: app.title)
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail = HostedAppStyle.rowDetail(app) {
                        Text(verbatim: detail)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let dot = HostedAppStyle.dot(app.state) {
                    Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                if let word = HostedAppStyle.word(app.state) {
                    Text(verbatim: word)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.conduitTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

enum HostedAppStyle {
    static func word(_ state: HostedApp.State) -> String? {
        switch state {
        case .connected: AppLocalization.string("Connected")
        case .expired: AppLocalization.string("Sign in again")
        case .broken: AppLocalization.string("Couldn't connect")
        case .connecting: AppLocalization.string("Finishing sign-in")
        case .available: nil
        case .off: AppLocalization.string("Off")
        case .offByOrganization: AppLocalization.string("Off by your organization")
        case .unknown: AppLocalization.string("Checking")
        }
    }

    static func dot(_ state: HostedApp.State) -> Color? {
        switch state {
        case .connected: .green
        case .expired, .broken: .orange
        case .connecting, .unknown: .yellow
        case .available, .off, .offByOrganization: nil
        }
    }

    /// The account that speaks for the app and how many tools are off, or
    /// the catalog's description for an app not connected.
    static func rowDetail(_ app: HostedApp) -> String? {
        guard app.connected else { return app.description.isEmpty ? nil : app.description }
        var parts: [String] = []
        if let account = app.accounts.first { parts.append(account.name) }
        if app.accounts.count > 1 { parts.append(AppLocalization.string("\(app.accounts.count) accounts")) }
        if !app.disabledTools.isEmpty { parts.append(AppLocalization.string("\(app.disabledTools.count) tools off")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func category(_ id: String) -> String {
        id.isEmpty ? AppLocalization.string("Other") : HostedApps.title(id)
    }
}

// MARK: Browse Apps

struct HostedAppsDirectoryPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let model: HostedAppsModel
    /// Apps Hermes suggested in a chat, listed first in its order.
    var suggested: [String] = []
    @State private var query = ""

    private struct AppGroup: Identifiable {
        let category: String
        let apps: [HostedApp]
        var id: String { category }
    }

    private var groups: [AppGroup] {
        let apps = (model.snapshot?.apps ?? []).filter { HostedAppsSection.matches($0, query) }
        let byCategory = Dictionary(grouping: apps) { HostedAppStyle.category($0.category) }
        return byCategory.keys.sorted { $0.localizedCompare($1) == .orderedAscending }.map { key in
            AppGroup(category: key, apps: (byCategory[key] ?? []).sorted { $0.title.localizedCompare($1.title) == .orderedAscending })
        }
    }

    var body: some View {
        CapabilityTabScroll(refresh: { await model.reload(appState) }) {
            Text(AppLocalization.string("Connect an app once and Hermes can read and act in it for you, in any chat. You sign in on the app's own page; Hermes and Nous Portal keep the sign-in, never Conduit."))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.errorMessage {
                CapabilityRefreshBanner(message: message)
            }
            let groups = self.groups
            if groups.isEmpty {
                CapabilityEmptyState(
                    title: query.isEmpty ? AppLocalization.string("No apps listed") : AppLocalization.string("No matching apps"),
                    symbol: "square.grid.3x3",
                    message: query.isEmpty ? nil : AppLocalization.string("Nothing matches “\(query)”.")
                )
            }
            let picks = suggested.compactMap { slug in
                (model.snapshot?.apps ?? []).first { $0.slug == slug && HostedAppsSection.matches($0, query) }
            }
            if !picks.isEmpty {
                CapabilitySection(title: AppLocalization.string("Suggested"), symbol: "sparkles", tint: .conduitAura) {
                    ForEach(Array(picks.enumerated()), id: \.element.id) { index, app in
                        CapabilityCardRow(divided: index > 0) {
                            HostedAppRow(app: app, model: model)
                        }
                    }
                }
            }
            ForEach(groups) { group in
                CapabilitySection(title: group.category, symbol: "square.grid.2x2", tint: .conduitAura) {
                    ForEach(Array(group.apps.enumerated()), id: \.element.id) { index, app in
                        CapabilityCardRow(divided: index > 0) {
                            HostedAppRow(app: app, model: model)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(AppLocalization.string("Search apps")))
        .navigationTitle(AppLocalization.string("Apps"))
    }
}

// MARK: An app's page

struct HostedAppPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let slug: String
    let model: HostedAppsModel
    @State private var tools: [HostedAppTool]?
    @State private var toolsError: String?
    /// The tools turned off as last switched here, until Hermes' rules
    /// come back with them.
    @State private var switchedOff: [String]?
    @State private var writingRules = false
    @State private var naming: AccountNaming?
    @State private var disconnecting: HostedAppAccount?
    @State private var busyAccount: String?

    private struct AccountNaming: Identifiable {
        let id = UUID()
        /// Nil names a new account.
        let account: HostedAppAccount?
    }

    private var app: HostedApp? { model.snapshot.map { $0.app(slug) } }
    private var policy: HostedAppPolicy? { model.snapshot?.policy }
    private var signingIn: Bool { model.signingIn == slug }
    /// Hermes couldn't give the rules: the switches only read until they're
    /// read again (issue 1998).
    private var rulesFailed: Bool { model.snapshot?.rulesFailed == true }

    private var rulesUnreadLine: some View {
        rulesUnread(AppLocalization.string("Hermes couldn't read the rules just now, so these switches can't change."))
    }

    private func rulesUnread(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(AppLocalization.string("Try Again")) {
                Task { await model.reload(appState) }
            }
            .buttonStyle(.settings)
            .disabled(!appState.isConnected || model.loading)
        }
    }

    private var canAct: Bool { appState.isConnected && !model.showsKept && model.signingIn == nil && !model.browserClosing }
    /// A new account needs the rules read: without them Conduit can't tell
    /// whether the organization turned the app off (issue 2014). Signing an
    /// account in again needs only `canAct`.
    private var canAddAccount: Bool { canAct && !rulesFailed }

    var body: some View {
        SettingsDetailContainer {
            if let app {
                header(app)
                connectionSection(app)
                if app.connected {
                    accountsSection(app)
                    toolsSection(app)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: app)
        .navigationTitle(Text(verbatim: app?.title ?? HostedApps.title(slug)))
        .task(id: app?.connected == true ? slug : nil) {
            guard app?.connected == true, tools == nil else { return }
            await loadTools(refresh: false)
        }
        .onDisappear {
            // Safari over the page isn't leaving it.
            if model.browser == nil, signingIn { model.cancelSignIn() }
        }
        .fullScreenCover(item: Binding(get: { signingIn ? model.browser : nil }, set: { if $0 == nil { model.browserClosed() } }), onDismiss: {
            model.browserDismissed()
        }) { page in
            BotMcpBrowserView(url: page.url, onDone: { model.browserClosed() })
                .ignoresSafeArea()
        }
        .sheet(item: $naming) { naming in
            HostedAccountNameSheet(
                appTitle: app?.title ?? HostedApps.title(slug),
                account: naming.account,
                accounts: app?.accounts ?? []
            ) { name in
                if let account = naming.account {
                    let renamed = try await appState.renameHostedAppAccount(account.connectionID, to: name)
                    model.take(account: renamed)
                } else if rulesFailed {
                    // The sheet keeps the name and says why (issue 2014).
                    throw HostedAppRulesUnread(appTitle: app?.title ?? HostedApps.title(slug))
                } else {
                    model.signIn(slug, alias: name, appState: appState)
                }
            }
        }
        .confirmationDialog(
            AppLocalization.string("Disconnect this account?"),
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible,
            presenting: disconnecting
        ) { account in
            Button(AppLocalization.string("Disconnect"), role: .destructive) { disconnect(account) }
        } message: { account in
            Text(AppLocalization.string("Hermes signs out of “\(account.name)” and can't use it until you connect it again."))
        }
    }

    private func header(_ app: HostedApp) -> some View {
        HStack(alignment: .top, spacing: 14) {
            HostedAppLogo(app: app, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: app.title)
                    .scaledFont(.title3.weight(.semibold))
                Text(verbatim: [HostedAppStyle.category(app.category), HostedAppStyle.word(app.state)].compactMap { $0 }.joined(separator: " · "))
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                if !app.description.isEmpty {
                    Text(verbatim: app.description)
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
    }

    private func connectionSection(_ app: HostedApp) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Connection"), symbol: "link", tint: .conduitAura) {
            if app.state == .offByOrganization {
                Text(AppLocalization.string("Your organization turned \(app.title) off for Hermes."))
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                // From the last rules read: they can be read again here.
                if rulesFailed { rulesUnreadLine }
            } else {
                if app.connected {
                    Toggle(isOn: Binding(get: { app.state != .off }, set: { setEnabled($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalization.string("Let Hermes use \(app.title)"))
                                .scaledFont(.subheadline)
                            Text(AppLocalization.string("Off keeps the sign-in but hides the app's tools."))
                                .scaledFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.conduitAccent)
                    .disabled(!canAct || writingRules || rulesFailed || policy?.revision == nil)
                    // Once the tools list, it says so there, above the switches.
                    if rulesFailed, tools?.isEmpty != false { rulesUnreadLine }
                }
                if let reason = app.statusReason, app.needsReconnect {
                    Text(verbatim: reason)
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !app.connected, rulesFailed, !signingIn {
                    rulesUnread(AppLocalization.string("Hermes couldn't read your organization's rules just now, so it can't tell yet whether \(app.title) is allowed."))
                }
                if !app.connected || app.needsReconnect || app.state == .connecting {
                    Button {
                        Haptics.selection()
                        model.signIn(slug, repairing: app.needsReconnect ? app.accounts.first?.connectionID : nil, appState: appState)
                    } label: {
                        HStack(spacing: 8) {
                            if signingIn { ProgressView().controlSize(.small) }
                            Text(signingIn
                                 ? AppLocalization.string("Waiting for the sign-in…")
                                 : app.needsReconnect ? AppLocalization.string("Sign In Again") : AppLocalization.string("Connect \(app.title)"))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .frame(minHeight: 44)
                    }
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
                    .disabled(app.connected ? !canAct : !canAddAccount)
                    .accessibilityIdentifier("capabilities.apps.connect")
                    if signingIn {
                        Button(AppLocalization.string("Stop Waiting")) { model.cancelSignIn() }
                            .buttonStyle(.settings)
                    }
                }
            }
            if let note = model.notes[slug] {
                Text(verbatim: note)
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.showsKept, appState.isConnected {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppLocalization.string("Checking with Hermes…"))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }
            } else if !appState.isConnected {
                Text(AppLocalization.string("Connect to Hermes to change this app."))
                    .scaledFont(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func accountsSection(_ app: HostedApp) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Accounts"), symbol: "person.crop.circle", tint: .conduitAccent) {
            ForEach(app.accounts) { account in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: account.name)
                            .scaledFont(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(verbatim: accountDetail(account))
                            .scaledFont(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                            .privacySensitive()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if busyAccount == account.connectionID {
                        ProgressView().controlSize(.small)
                    }
                    Menu {
                        Button {
                            naming = AccountNaming(account: account)
                        } label: {
                            Label(account.alias == nil ? AppLocalization.string("Name Account") : AppLocalization.string("Rename Account"), systemImage: "pencil")
                        }
                        Button {
                            model.signIn(slug, repairing: account.connectionID, appState: appState)
                        } label: {
                            Label(AppLocalization.string("Sign In Again"), systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            disconnecting = account
                        } label: {
                            Label(AppLocalization.string("Disconnect"), systemImage: "minus.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!canAct || busyAccount != nil)
                    .accessibilityLabel(AppLocalization.string("Actions for \(account.name)"))
                }
            }
            Button {
                naming = AccountNaming(account: nil)
            } label: {
                Label(AppLocalization.string("Add Another Account"), systemImage: "plus")
            }
            .buttonStyle(.settings)
            .disabled(!canAddAccount)
        }
    }

    private func accountDetail(_ account: HostedAppAccount) -> String {
        var parts: [String] = []
        if account.alias != nil, account.label != account.name { parts.append(account.label) }
        parts.append(HostedAppStyle.word(HostedApp.State(status: account.status)) ?? account.status)
        if account.active, (app?.accounts.count ?? 0) > 1 { parts.append(AppLocalization.string("In use")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func toolsSection(_ app: HostedApp) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Tools"), symbol: "wrench.and.screwdriver", tint: .conduitAccent) {
            if let tools {
                if tools.isEmpty {
                    Text(AppLocalization.string("This app brings no tools."))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                } else {
                    let off = Set(switchedOff ?? app.disabledTools)
                    let locked = policy?.organizationLockedTools(slug, tools: tools) ?? []
                    let onCount = tools.filter { !off.contains($0.slug) && !locked.contains($0.slug) }.count
                    Text(verbatim: AppLocalization.string("\(onCount) tools on") + " · " + AppLocalization.string("Hermes can't use a tool that's off."))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                    if rulesFailed {
                        // An app the organization turned off says it once,
                        // in Connection.
                        if app.state != .offByOrganization { rulesUnreadLine }
                    } else if policy?.revision == nil {
                        Text(AppLocalization.string("Your organization manages these switches."))
                            .scaledFont(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(tools.filter { !$0.deprecated }) { tool in
                        Toggle(isOn: Binding(
                            get: { !off.contains(tool.slug) && !locked.contains(tool.slug) },
                            set: { on in setTool(tool.slug, on: on, off: off) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(verbatim: tool.name)
                                        .scaledFont(.subheadline)
                                        .lineLimit(2)
                                    if let pill = HostedAppStyle.facet(tool.facet) {
                                        CapabilityPill(text: pill.text, tint: pill.tint)
                                    }
                                }
                                if !tool.description.isEmpty {
                                    Text(verbatim: tool.description)
                                        .scaledFont(.caption).foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                        }
                        .tint(.conduitAccent)
                        .disabled(!canAct || writingRules || rulesFailed || policy?.revision == nil || locked.contains(tool.slug))
                    }
                }
            } else if let toolsError {
                Text(verbatim: toolsError)
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                Button {
                    Task { await loadTools(refresh: true) }
                } label: {
                    Label(AppLocalization.string("Try Again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.settings)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppLocalization.string("Reading the tool list…"))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Actions

    private func loadTools(refresh: Bool) async {
        toolsError = nil
        do {
            tools = try await appState.hostedAppTools(slug, refresh: refresh)
        } catch is CancellationError {
        } catch {
            toolsError = UserFacingError.message(for: error)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !writingRules, !rulesFailed else { return }
        writingRules = true
        Haptics.selection()
        let rules = policy
        Task {
            do {
                let taken = try await appState.setHostedApp(slug, enabled: enabled, policy: rules)
                model.take(policy: taken)
                model.note(slug, nil)
            } catch {
                model.note(slug, UserFacingError.message(for: error))
                await model.reload(appState)
            }
            writingRules = false
        }
    }

    private func setTool(_ tool: String, on: Bool, off: Set<String>) {
        guard !writingRules, !rulesFailed else { return }
        var next = off
        if on { next.remove(tool) } else { next.insert(tool) }
        let disabled = next.sorted()
        switchedOff = disabled
        writingRules = true
        Haptics.selection()
        let rules = policy
        Task {
            do {
                let taken = try await appState.setHostedAppTools(slug, disabled: disabled, policy: rules)
                model.take(policy: taken)
                model.note(slug, nil)
            } catch {
                model.note(slug, UserFacingError.message(for: error))
                await model.reload(appState)
            }
            switchedOff = nil
            writingRules = false
        }
    }

    private func disconnect(_ account: HostedAppAccount) {
        busyAccount = account.connectionID
        Task {
            do {
                try await appState.removeHostedAppAccount(account.connectionID)
                model.drop(account: account.connectionID)
                Haptics.success()
                await model.reload(appState)
            } catch {
                model.note(slug, UserFacingError.message(for: error))
            }
            busyAccount = nil
        }
    }
}

extension HostedAppStyle {
    /// What a tool does, when Hermes says: only writing and destructive
    /// tools get a pill.
    static func facet(_ facet: HostedAppTool.Facet) -> CapabilityPillModel? {
        switch facet {
        case .write: CapabilityPillModel(text: AppLocalization.string("Writes"), tint: .orange)
        case .destructive: CapabilityPillModel(text: AppLocalization.string("Deletes"), tint: .red)
        case .read, .unclassified: nil
        }
    }
}

/// Names a new account before its sign-in, or renames one.
/// A new account asked for while the organization's rules are unread.
private struct HostedAppRulesUnread: LocalizedError {
    let appTitle: String
    var errorDescription: String? {
        AppLocalization.string("Hermes couldn't read your organization's rules just now, so it can't tell yet whether \(appTitle) is allowed.")
    }
}

private struct HostedAccountNameSheet: View {
    let appTitle: String
    let account: HostedAppAccount?
    let accounts: [HostedAppAccount]
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var working = false
    @State private var error: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces).lowercased() }
    private var problem: String? {
        trimmed.isEmpty ? nil : HostedApps.accountNameProblem(trimmed, among: accounts, renaming: account?.connectionID)
    }

    var body: some View {
        NavigationStack {
            SettingsDetailContainer(compact: true) {
                ConduitSettingsSection(title: AppLocalization.string("Name"), symbol: "person.crop.circle", tint: .conduitAccent) {
                    Text(account == nil
                         ? AppLocalization.string("A short name tells this \(appTitle) account apart from your others, like work or home. You sign in next.")
                         : AppLocalization.string("Hermes and you call this account by its name, like work or home."))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(AppLocalization.string("work"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { submit() }
                        .disabled(working)
                    if let problem { Text(verbatim: problem).scaledFont(.caption).foregroundStyle(.red) }
                    if let error { Text(verbatim: error).scaledFont(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle(account == nil ? AppLocalization.string("Add Account") : AppLocalization.string("Rename Account"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(account == nil ? AppLocalization.string("Sign In") : AppLocalization.string("Save")) { submit() }
                            .disabled(trimmed.isEmpty || problem != nil)
                    }
                }
            }
        }
        .onAppear { name = account?.alias ?? "" }
        .disabled(working)
        .interactiveDismissDisabled(working)
        .presentationDetents([.medium, .large])
    }

    private func submit() {
        guard !working, !trimmed.isEmpty, problem == nil else { return }
        working = true
        error = nil
        let typed = trimmed
        Task {
            do {
                try await save(typed)
                dismiss()
            } catch let failure {
                error = UserFacingError.message(for: failure)
            }
            working = false
        }
    }
}

// MARK: Logos

/// An app's logo, or its first letter while the logo loads or when none
/// draws.
struct HostedAppLogo: View {
    let title: String
    let logo: URL?
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale

    init(app: HostedApp, size: CGFloat) {
        self.init(title: app.title, logo: app.logo, size: size)
    }

    init(title: String, logo: URL?, size: CGFloat) {
        self.title = title
        self.logo = logo
        self.size = size
    }
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.16)
            } else {
                Text(verbatim: String(title.prefix(1)).uppercased())
                    .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.conduitAura)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: logo) {
            guard let url = logo else { return }
            image = HostedAppLogoLoader.cached(url)
            guard image == nil else { return }
            image = await HostedAppLogoLoader.load(url, pixels: 96 * max(displayScale, 1) / 2)
        }
    }
}

/// Loads app logos within a byte ceiling and keeps them for the session.
/// The vendor logos are SVGs, which ImageIO can't read: those are drawn
/// once by a WebKit view with JavaScript off, one at a time, and the
/// picture kept.
@MainActor
enum HostedAppLogoLoader {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 400
        return cache
    }()
    private static var failed = Set<URL>()
    private static let byteLimit = 512 * 1024

    static func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    /// The apps were read again: a logo that failed (offline a moment, a
    /// server error) gets another try.
    static func retryFailed() { failed.removeAll() }

    static func load(_ url: URL, pixels: CGFloat) async -> UIImage? {
        if let image = cached(url) { return image }
        guard !failed.contains(url) else { return nil }
        guard case .downloaded(let data, _) = await MediaPreviewPresenter.boundedDownloadResult(url, limit: byteLimit) else {
            failed.insert(url)
            return nil
        }
        var image: UIImage?
        if case .image(let raster) = BoundedRemoteImage.decode(data, maxPixelSize: pixels) {
            image = raster
        } else if isSVG(data) {
            image = await SVGLogoRenderer.shared.render(data, points: 64)
        }
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        } else {
            failed.insert(url)
        }
        return image
    }

    nonisolated static func isSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(1024), encoding: .utf8)?.lowercased() else { return false }
        return head.contains("<svg")
    }
}

/// Draws SVG logos into pictures with one hidden WebKit view.
@MainActor
final class SVGLogoRenderer: NSObject, WKNavigationDelegate {
    static let shared = SVGLogoRenderer()

    private var webView: WKWebView?
    private var queue: [(Data, CGFloat, CheckedContinuation<UIImage?, Never>)] = []
    private var current: CheckedContinuation<UIImage?, Never>?
    /// The load drawing now. A callback about another one (a load given
    /// up at the timeout, cancelled by the next) is ignored, so it never
    /// ends the render after it.
    private var currentNavigation: WKNavigation?
    private var currentPoints: CGFloat = 64
    private var timeout: Task<Void, Never>?
    private var generation = 0

    func render(_ svg: Data, points: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            queue.append((svg, points, continuation))
            startNext()
        }
    }

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let (svg, points, continuation) = queue.removeFirst()
        guard let view = preparedView(points: points) else {
            continuation.resume(returning: nil)
            startNext()
            return
        }
        current = continuation
        currentPoints = points
        let side = Int(points)
        let html = "<!doctype html><html><head><meta name=\"viewport\" content=\"width=\(side)\"><style>html,body{margin:0;padding:0;background:transparent}img{display:block;width:\(side)px;height:\(side)px;object-fit:contain}</style></head><body><img src=\"data:image/svg+xml;base64,\(svg.base64EncodedString())\"></body></html>"
        generation += 1
        let render = generation
        currentNavigation = view.loadHTMLString(html, baseURL: nil)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.finish(nil, render: render)
        }
    }

    private func preparedView(points: CGFloat) -> WKWebView? {
        let frame = CGRect(x: -2 * points - 100, y: 0, width: points, height: points)
        if let webView {
            webView.frame = frame
            return webView
        }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: frame, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.navigationDelegate = self
        window.addSubview(view)
        webView = view
        return view
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === currentNavigation else { return }
        let render = generation
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: currentPoints, height: currentPoints)
        configuration.afterScreenUpdates = true
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            self?.finish(image, render: render)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === currentNavigation else { return }
        finish(nil, render: generation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === currentNavigation else { return }
        finish(nil, render: generation)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Only the page it was given: a logo never navigates anywhere.
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(scheme == nil || scheme == "about" ? .allow : .cancel)
    }

    private func finish(_ image: UIImage?, render: Int) {
        guard render == generation, let continuation = current else { return }
        timeout?.cancel()
        timeout = nil
        current = nil
        currentNavigation = nil
        continuation.resume(returning: image)
        startNext()
    }
}
