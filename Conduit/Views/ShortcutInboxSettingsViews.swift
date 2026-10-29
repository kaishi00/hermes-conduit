//
//  ShortcutInboxSettingsViews.swift
//  Conduit
//
//  Settings > Shortcuts inbox: what this iPhone's Log to Hermes automations
//  kept on the Hermes host, read back sealed for this iPhone alone, and
//  deleted one at a time or all at once.
//

import SwiftUI

struct ShortcutInboxSettingsPage: View {
    @EnvironmentObject private var appState: AppState

    /// The dashboard and profile the page shows: the ones in use when it opened.
    @State private var scope: ShortcutInboxScope?
    @State private var entries: [ShortcutInboxEntry] = []
    @State private var next: ShortcutInboxBrowser.Cursor?
    @State private var waitingCount = 0
    @State private var loaded = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showsDeleteAll = false

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Shortcuts inbox"), symbol: "tray.full", tint: .indigo) {
                Text(AppLocalization.string("What your Shortcuts automations logged with Log to Hermes. Hermes can look these up, and Pulse reads them when it's on. Only this iPhone's events show here, and they're deleted after 30 days."))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                if waitingCount > 0 {
                    Label(AppLocalization.string("\(waitingCount) waiting on this iPhone for the next run"), systemImage: "clock")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .scaledFont(.caption)
                        .foregroundStyle(.orange)
                    Button(AppLocalization.string("Try Again")) { load(before: nil) }
                        .disabled(isWorking)
                }
            }
            ConduitSettingsSection(title: AppLocalization.string("Logged"), symbol: "list.bullet", tint: .indigo) {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if entries.isEmpty && next == nil {
                    Text(AppLocalization.string("Nothing logged from this iPhone. Add Log to Hermes to an automation in the Shortcuts app."))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
                // Older pages stay reachable after the last row on this one is deleted.
                if loaded, let next {
                    Button(AppLocalization.string("Load More")) { load(before: next) }
                        .disabled(isWorking)
                }
            }
            if !entries.isEmpty || next != nil || waitingCount > 0 {
                ConduitSettingsSection(title: AppLocalization.string("Delete"), symbol: "trash", tint: .red) {
                    Button(AppLocalization.string("Delete Everything From This iPhone"), role: .destructive) { showsDeleteAll = true }
                        .disabled(isWorking)
                }
            }
        }
        .navigationTitle(AppLocalization.string("Shortcuts inbox"))
        .task { if !loaded { load(before: nil) } }
        .confirmationDialog(AppLocalization.string("Delete everything this iPhone logged?"), isPresented: $showsDeleteAll,
                            titleVisibility: .visible) {
            Button(AppLocalization.string("Delete Everything"), role: .destructive) { deleteAll() }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("Hermes and Pulse can no longer read it. Your automations keep logging new events."))
        }
    }

    private func row(_ entry: ShortcutInboxEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(entry.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: [entry.source, entry.title].compactMap { $0 }.joined(separator: " · "))
                        .scaledFont(.subheadline)
                        .lineLimit(1)
                    if let text = entry.text {
                        Text(verbatim: text)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if let at = entry.at {
                            Text(at, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                        if let amount = entry.amount {
                            Text(verbatim: amount)
                        }
                    }
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            // Its own element, so VoiceOver reaches it directly.
            Button(role: .destructive) { delete(entry) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isWorking)
            .accessibilityLabel(AppLocalization.string("Delete this event"))
        }
    }

    private static func symbol(_ kind: ShortcutEvent.Kind) -> String {
        switch kind {
        case .notification: return "app.badge"
        case .message: return "message"
        case .email: return "envelope"
        case .transaction: return "creditcard"
        case .nfc: return "wave.3.right"
        case .sound: return "ear"
        case .other: return "square.and.pencil"
        }
    }

    private func browser(_ scope: ShortcutInboxScope) -> ShortcutInboxBrowser {
        ShortcutInboxBrowser(queue: .standard(scope), keys: .keychain(scope))
    }

    private func refreshWaiting() {
        waitingCount = scope.map { ShortcutInboxQueue.standard($0).pending().count } ?? 0
    }

    private func load(before: ShortcutInboxBrowser.Cursor?) {
        if before == nil { scope = appState.shortcutInboxScope }
        refreshWaiting()
        guard let scope, let request = appState.shortcutInboxRequest(for: scope) else {
            loaded = true
            errorMessage = AppLocalization.string("Connect to your Hermes dashboard to see what was logged.")
            return
        }
        isWorking = true
        let inbox = browser(scope)
        Task {
            defer { isWorking = false; loaded = true }
            do {
                let page = try await AppState.shortcutInboxGate.run { try await inbox.page(before: before, request: request) }
                entries = before == nil ? page.entries : entries + page.entries
                next = page.next
                errorMessage = nil
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func delete(_ entry: ShortcutInboxEntry) {
        guard let scope else { return }
        guard let request = appState.shortcutInboxRequest(for: scope) else {
            ShortcutInboxQueue.standard(scope).remove(ids: [entry.id])
            refreshWaiting()
            errorMessage = Self.unreachableDeleteMessage
            return
        }
        isWorking = true
        let inbox = browser(scope)
        Task {
            defer { isWorking = false; refreshWaiting() }
            do {
                _ = try await AppState.shortcutInboxGate.run { try await inbox.delete([entry.id], request: request) }
                entries.removeAll { $0.id == entry.id }
                errorMessage = nil
            } catch {
                errorMessage = Self.deleteMessage(for: error)
            }
        }
    }

    private func deleteAll() {
        guard let scope else { return }
        let request = appState.shortcutInboxRequest(for: scope)
        isWorking = true
        let inbox = browser(scope)
        Task {
            defer { isWorking = false; refreshWaiting() }
            do {
                // What waits here goes even when Hermes can't be reached;
                // what the host keeps goes only when it answers.
                try await AppState.shortcutInboxGate.run { try await inbox.deleteAll(request: request) }
                entries = []
                next = nil
                errorMessage = nil
            } catch {
                errorMessage = Self.deleteMessage(for: error)
            }
        }
    }

    private static func isPluginTooOld(_ error: Error) -> Bool {
        if case DashboardTicketBridgeError.http(let status, let detail) = error {
            return status == 404 || (status == 409 && HostKeyConflict.isNewerPluginStore(detail))
        }
        return false
    }

    private static func message(for error: Error) -> String {
        if isPluginTooOld(error) {
            return AppLocalization.string("Update the Conduit plugin on your Hermes host to see and delete what was logged.")
        }
        return AppLocalization.string("Conduit couldn't reach the inbox on your Hermes host. Try again in a moment.")
    }

    /// A delete that didn't reach the host says so: nothing there changed.
    private static func deleteMessage(for error: Error) -> String {
        isPluginTooOld(error) ? message(for: error) : unreachableDeleteMessage
    }

    private static var unreachableDeleteMessage: String {
        AppLocalization.string("Conduit couldn't reach Hermes, so what it keeps wasn't deleted. Try again once you're connected.")
    }
}
