//
//  ConnectionCard.swift
//  Conduit
//
//  The connect card Hermes waits on in a chat (ConnectionActivity): each
//  app, MCP server, plugin or skill the model asked for, with what's left
//  for the user (Connect, set up with its keys, Install, Skip, Try Again),
//  and Continue, which lets Hermes carry on without the rest. The apps
//  directory card lists Hermes' suggestions and opens Browse Apps. As
//  Hermes Desktop's connector, MCP setup and catalog install cards.
//
//  A key typed for a server lives only in this view's state: it goes once
//  onto the socket with the approval and is dropped, never kept on the
//  message, in a cache or a log.
//

import SwiftUI

struct ConnectionCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed (`ChatRowState`).
    private var appState: AppState { rowActions.required }
    /// The keys typed for each row, by row and key. View state only.
    @State private var drafts: [String: [String: String]] = [:]
    /// Rows whose page the user opened from this card: only those say
    /// they wait on the sign-in.
    @State private var opened: Set<String> = []
    @State private var browser: BotMcpBrowserPage?
    /// Safari's cover is up or still going away (that's asynchronous): a
    /// second page waits for it, or it would never show.
    @State private var browserUp = false
    @State private var browsing = false

    var body: some View {
        if let card = message.connection {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: card.isDisplay ? "square.grid.2x2" : "link")
                            .foregroundStyle(tint(card))
                            .accessibilityHidden(true)
                        CardHeaderCaption(timestamp: message.timestamp) {
                            Text(caption(card))
                                .scaledFont(.caption2.weight(.bold))
                                .tracking(0.5)
                                .foregroundStyle(tint(card))
                        }
                        if card.status == .sending {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text(title(card))
                        .scaledFont(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if card.isDisplay {
                    directory(card)
                } else {
                    ForEach(card.targets) { target in
                        row(target, in: card)
                    }
                }

                if card.status == .error, let error = card.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                }

                if card.isOpen, card.unresolved {
                    VStack(alignment: .leading, spacing: 4) {
                        Button(AppLocalization.string("Continue")) {
                            Task { await appState.respondToConnection(messageId: message.id, continues: true) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!card.needsUser)
                        Text(card.isDisplay
                             ? AppLocalization.string("Continue when you're done; Hermes carries on with the apps you connected.", table: .connection)
                             : AppLocalization.string("Continue lets Hermes carry on without what isn't connected yet.", table: .connection))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .chatCard(cornerRadius: 22, tint: tint(card).opacity(0.08))
            .onChange(of: card.settled) { _, settled in
                guard settled else { return }
                drafts = [:]
                browser = nil
                browserUp = false
            }
            .onChange(of: card.targets.filter(\.resolved).map(\.name)) { _, resolved in
                for name in resolved { drafts[name] = nil }
                // The sign-in finished: Safari goes, as on the Apps page.
                if !opened.isDisjoint(with: resolved) {
                    browser = nil
                    opened.subtract(resolved)
                }
            }
            .fullScreenCover(item: $browser, onDismiss: {
                browserUp = false
                Task { await appState.wakeConnection(messageId: message.id) }
            }) { page in
                BotMcpBrowserView(url: page.url, onDone: { browser = nil })
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $browsing) {
                ConnectionDirectorySheet(suggested: card.suggested ?? [])
                    .environmentObject(appState)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ target: ConnectionActivity.Target, in card: ConnectionActivity) -> some View {
        let live = card.isOpen
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                glyph(target)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: target.title)
                        .scaledFont(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(stateWord(target, live: live))
                        .scaledFont(.caption)
                        .foregroundStyle(target.state == .connected && target.discoveryError == nil ? .green : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if live {
                    rowAction(target, in: card)
                }
            }
            .accessibilityElement(children: .contain)

            if let summary = target.summary, target.kind == .plugin || target.kind == .skill {
                Text(verbatim: summary)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let scan = scanLine(target) {
                Label(scan.text, systemImage: scan.symbol)
                    .scaledFont(.caption)
                    .foregroundStyle(scan.warns ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = target.detail ?? target.discoveryError, !target.resolved || target.discoveryError != nil {
                Text(verbatim: detail)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if live, target.asksApproval {
                approval(target, in: card)
            }
        }
    }

    @ViewBuilder
    private func glyph(_ target: ConnectionActivity.Target) -> some View {
        switch target.kind {
        case .connector:
            HostedAppLogo(title: target.title, logo: HostedApps.logoURL(slug: target.name, catalogLogo: nil), size: 32)
        case .mcp, .plugin, .skill:
            Image(systemName: target.kind == .mcp ? "server.rack" : target.kind == .plugin ? "puzzlepiece.extension" : "sparkles")
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(Color.conduitAura)
                .frame(width: 32, height: 32)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    /// Connect opens the app's page; Try Again has Hermes make a new one.
    @ViewBuilder
    private func rowAction(_ target: ConnectionActivity.Target, in card: ConnectionActivity) -> some View {
        if target.opensPage, let url = target.connectURL {
            Button(AppLocalization.string("Connect", table: .connection)) {
                opened.insert(target.name)
                browserUp = true
                browser = BotMcpBrowserPage(url: url)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!card.needsUser || browserUp)
            .accessibilityLabel(Text(verbatim: "\(AppLocalization.string("Connect", table: .connection)) \(target.title)"))
        } else if target.reissues {
            Button(AppLocalization.string("Try Again")) {
                opened.remove(target.name)
                Task { await appState.reissueConnection(messageId: message.id, target: target.name) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!card.needsUser)
            .accessibilityLabel(Text(verbatim: "\(AppLocalization.string("Try Again")) \(target.title)"))
        } else if target.kind == .connector, target.state == .pending {
            // Hermes is still making the sign-in page.
            ProgressView().controlSize(.small)
        }
    }

    /// An install or a server's setup: the keys it asks for, then Install
    /// (or Connect) and Skip.
    @ViewBuilder
    private func approval(_ target: ConnectionActivity.Target, in card: ConnectionActivity) -> some View {
        if let instructions = target.instructions, !target.fields.isEmpty {
            Text(verbatim: instructions)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(target.fields) { field in
            fieldView(field, target: target, disabled: !card.needsUser)
        }
        let typed = values(for: target)
        HStack(spacing: 8) {
            Button {
                Task {
                    await appState.respondToConnection(
                        messageId: message.id,
                        targets: [ConnectionActivity.answer(name: target.name, approve: true, env: typed)]
                    )
                }
            } label: {
                Text(approveTitle(target))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!card.needsUser || !ConnectionActivity.hasRequiredValues(target.fields, in: typed))
            .accessibilityLabel(Text(verbatim: "\(approveTitle(target)) \(target.title)"))

            Spacer(minLength: 0)

            Button(AppLocalization.string("Skip")) {
                drafts[target.name] = nil
                Task {
                    await appState.respondToConnection(
                        messageId: message.id,
                        targets: [ConnectionActivity.answer(name: target.name, approve: false)]
                    )
                }
            }
            .buttonStyle(.bordered)
            .disabled(!card.needsUser)
            .accessibilityLabel(Text(verbatim: "\(AppLocalization.string("Skip")) \(target.title)"))
        }
        .scaledFont(.subheadline.weight(.medium))
    }

    @ViewBuilder
    private func fieldView(_ field: ConnectionActivity.Field, target: ConnectionActivity.Target, disabled: Bool) -> some View {
        let binding = Binding(
            get: { drafts[target.name]?[field.name] ?? field.defaultValue },
            set: { drafts[target.name, default: [:]][field.name] = $0 }
        )
        let label = field.required ? AppLocalization.string("\(field.label) (required)", table: .connection) : field.label
        Group {
            // No .password content type: iOS would offer to save the key
            // to the keychain under Conduit's own domain.
            if field.secret {
                SecureField(label, text: binding)
            } else {
                TextField(label, text: binding)
                    .privacySensitive()
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(disabled)
    }

    /// What the approval sends: each key as typed, a plain one starting
    /// from Hermes' default.
    private func values(for target: ConnectionActivity.Target) -> [String: String] {
        var values: [String: String] = [:]
        for field in target.fields {
            values[field.name] = drafts[target.name]?[field.name] ?? field.defaultValue
        }
        return values
    }

    // MARK: Directory

    @ViewBuilder
    private func directory(_ card: ConnectionActivity) -> some View {
        let suggested = card.suggested ?? []
        if !suggested.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggested, id: \.self) { slug in
                    HStack(spacing: 11) {
                        HostedAppLogo(title: HostedApps.title(slug), logo: HostedApps.logoURL(slug: slug, catalogLogo: nil), size: 28)
                        Text(verbatim: HostedApps.title(slug))
                            .scaledFont(.subheadline.weight(.semibold))
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
        if card.isOpen {
            Button {
                browsing = true
            } label: {
                Label(AppLocalization.string("Browse Apps"), systemImage: "square.grid.2x2")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!card.needsUser || browserUp)
        }
    }

    // MARK: Words

    private func caption(_ card: ConnectionActivity) -> String {
        if card.status == .sending { return AppLocalization.string("SENDING") }
        if card.status == .error { return AppLocalization.string("TRY AGAIN") }
        guard card.isOpen else {
            return card.targets.contains { $0.state == .connected } && !card.isDisplay
                ? AppLocalization.string("CONNECTED", table: .connection)
                : AppLocalization.string("DONE", table: .connection)
        }
        return AppLocalization.string("HERMES IS WAITING", table: .connection)
    }

    private func title(_ card: ConnectionActivity) -> String {
        if card.isDisplay { return AppLocalization.string("Apps Hermes can use for you", table: .connection) }
        let installs = card.targets.allSatisfy { $0.kind == .plugin || $0.kind == .skill }
        return installs && !card.targets.isEmpty
            ? AppLocalization.string("Install for Hermes", table: .connection)
            : AppLocalization.string("Connect for Hermes", table: .connection)
    }

    private func tint(_ card: ConnectionActivity) -> Color {
        if card.status == .error { return .red }
        return card.isOpen ? .orange : .secondary
    }

    private func stateWord(_ target: ConnectionActivity.Target, live: Bool) -> String {
        switch target.state {
        case .connected:
            if target.discoveryError != nil { return AppLocalization.string("Connected, but its tools didn't load", table: .connection) }
            return target.kind == .plugin || target.kind == .skill
                ? AppLocalization.string("Installed")
                : AppLocalization.string("Connected")
        case .skipped:
            return AppLocalization.string("Skipped")
        case .initiated where live && opened.contains(target.name):
            return AppLocalization.string("Waiting for the sign-in…")
        case .failed, .expired:
            return live ? AppLocalization.string("Didn't connect", table: .connection) : AppLocalization.string("Not connected")
        case .pending where target.kind == .plugin || target.kind == .skill:
            return target.alreadyInstalled ? AppLocalization.string("Already installed", table: .connection) : AppLocalization.string("Not installed")
        case .pending, .initiated, .notConnected:
            return AppLocalization.string("Not connected")
        }
    }

    private func approveTitle(_ target: ConnectionActivity.Target) -> String {
        switch target.action {
        case "install": return AppLocalization.string("Install")
        case "enable": return AppLocalization.string("Turn On", table: .connection)
        default: return AppLocalization.string("Connect", table: .connection)
        }
    }

    /// A catalog item's tier and the catalog's scan of it, as they come.
    private func scanLine(_ target: ConnectionActivity.Target) -> (text: String, symbol: String, warns: Bool)? {
        guard target.kind == .plugin || target.kind == .skill else { return nil }
        let tier: String? = switch target.tier ?? "" {
        case "official": AppLocalization.string("Official")
        case "verified": AppLocalization.string("Verified")
        case "community": AppLocalization.string("Community")
        default: nil
        }
        let scan: String? = switch target.scanStatus ?? "" {
        case "passed": AppLocalization.string("Security scan passed", table: .connection)
        case "warnings": AppLocalization.string("Security scan found warnings", table: .connection)
        case "failed": AppLocalization.string("Security scan failed", table: .connection)
        default: nil
        }
        var parts = [tier, scan].compactMap { $0 }
        if let summary = target.scanSummary, target.scanStatus != "passed" { parts.append(summary) }
        guard !parts.isEmpty else { return nil }
        let warns = target.scanStatus == "warnings" || target.scanStatus == "failed"
        return (parts.joined(separator: " · "), warns ? "exclamationmark.shield" : "checkmark.shield", warns)
    }
}

/// Browse Apps from a chat's directory card: the Capabilities directory
/// with Hermes' suggestions first. Connecting there signs in for the
/// profile; the card's Continue tells Hermes.
private struct ConnectionDirectorySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let suggested: [String]
    @State private var model = HostedAppsModel()

    var body: some View {
        NavigationStack {
            HostedAppsDirectoryPage(model: model, suggested: suggested)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppLocalization.string("Done")) { dismiss() }
                    }
                }
        }
        .task(id: appState.hostedAppsScope) {
            model.show(appState)
            guard appState.isConnected else { return }
            await model.reload(appState)
        }
    }
}
