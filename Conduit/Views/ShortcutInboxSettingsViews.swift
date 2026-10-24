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

    @State private var entries: [ShortcutInboxEntry] = []
    @State private var next: ShortcutInboxBrowser.Cursor?
    @State private var waiting = 0
    @State private var loaded = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showsDeleteAll = false

    private var browser: ShortcutInboxBrowser {
        ShortcutInboxBrowser(queue: ShortcutInboxQueue(defaults: .standard), keys: .keychain)
    }

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Shortcuts inbox"), symbol: "tray.full", tint: .indigo) {
                Text("What your Shortcuts automations logged with Log to Hermes. Hermes can look these up, and Pulse reads them when it's on. Only this iPhone's events show here, and they go after 14 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if waiting > 0 {
                    Label(AppLocalization.string("\(waiting) waiting on this iPhone for the next run"), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            ConduitSettingsSection(title: AppLocalization.string("Logged"), symbol: "list.bullet", tint: .indigo) {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if entries.isEmpty {
                    Text("Nothing logged from this iPhone. Add Log to Hermes to an automation in the Shortcuts app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                    if let next {
                        Button("Load More") { load(before: next) }
                            .disabled(isWorking)
                    }
                }
            }
            if !entries.isEmpty || waiting > 0 {
                ConduitSettingsSection(title: AppLocalization.string("Delete"), symbol: "trash", tint: .red) {
                    Button("Delete Everything From This iPhone", role: .destructive) { showsDeleteAll = true }
                        .disabled(isWorking)
                }
            }
        }
        .navigationTitle("Shortcuts inbox")
        .task { if !loaded { load(before: nil) } }
        .confirmationDialog("Delete everything this iPhone logged?", isPresented: $showsDeleteAll, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes and Pulse can no longer read it. Your automations keep logging new events.")
        }
    }

    private func row(_ entry: ShortcutInboxEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(entry.kind))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: [entry.source, entry.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .lineLimit(1)
                if let text = entry.text {
                    Text(verbatim: text)
                        .font(.caption)
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
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { delete(entry) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isWorking)
            .accessibilityLabel(Text("Delete"))
        }
        .accessibilityElement(children: .combine)
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

    private func load(before: ShortcutInboxBrowser.Cursor?) {
        waiting = ShortcutInboxQueue(defaults: .standard).pending().count
        guard let request = appState.shortcutInboxRequest() else {
            loaded = true
            errorMessage = AppLocalization.string("Connect to your Hermes dashboard to see what was logged.")
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false; loaded = true }
            do {
                let page = try await browser.page(before: before, request: request)
                entries = before == nil ? page.entries : entries + page.entries
                next = page.next
                errorMessage = nil
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func delete(_ entry: ShortcutInboxEntry) {
        guard let request = appState.shortcutInboxRequest() else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await browser.delete([entry.id], request: request)
                entries.removeAll { $0.id == entry.id }
                errorMessage = nil
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func deleteAll() {
        guard let request = appState.shortcutInboxRequest() else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await browser.deleteAll(request: request)
                entries = []
                next = nil
                waiting = 0
                errorMessage = nil
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    private static func message(for error: Error) -> String {
        if case DashboardTicketBridgeError.http(let status, let detail) = error {
            if status == 404 || (status == 409 && HostKeyConflict.isNewerPluginStore(detail)) {
                return AppLocalization.string("Update the Conduit plugin on your Hermes host to see and delete what was logged.")
            }
        }
        return AppLocalization.string("Conduit couldn't reach the inbox on your Hermes host. Try again in a moment.")
    }
}
