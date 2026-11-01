//
//  BotWorkViews.swift
//  Conduit
//
//  Bot workstreams in the app: the Work strip under a Bot Chat's top bar
//  ("2 working · 1 needs you"), the Work panel it opens (a sheet on a
//  phone, a column beside the chat on a wide window), and the bar over a
//  workstream's own chat ("Furina's work · W3", Back to Furina, Stop,
//  Continue, Check first). The user's actions go straight to the
//  workstream through the plugin, with no Bot Chat turn.
//

import SwiftUI

/// Reads a bot's work while something shows it: often while work runs,
/// now and then otherwise.
private struct BotWorkRefresh: ViewModifier {
    @EnvironmentObject private var appState: AppState
    let profile: String

    static let busyInterval: UInt64 = 5_000_000_000
    static let idleInterval: UInt64 = 20_000_000_000

    func body(content: Content) -> some View {
        content.task(id: "\(profile)\u{1F}\(appState.isConnected)\u{1F}\(appState.servesBotWorkstreams)") {
            while !Task.isCancelled {
                await appState.refreshBotWork(profile: profile)
                let snapshot = appState.botWork.snapshot(profile)
                let busy = (snapshot?.workingCount ?? 0) > 0 || (snapshot?.items.contains { $0.status == "starting" } ?? false)
                try? await Task.sleep(nanoseconds: busy ? Self.busyInterval : Self.idleInterval)
            }
        }
    }
}

extension View {
    func refreshesBotWork(profile: String) -> some View {
        modifier(BotWorkRefresh(profile: profile))
    }
}

/// Under a Bot Chat's top bar while the bot has work.
struct BotWorkStrip: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var work: BotWorkStore
    let profile: String
    let isPanelOpen: Bool
    let onOpen: () -> Void

    var body: some View {
        Group {
            if let snapshot = work.snapshot(profile), snapshot.isOn, let text = snapshot.stripText {
                Button {
                    Haptics.light()
                    onOpen()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: snapshot.needsYouCount > 0 ? "exclamationmark.circle.fill" : "square.stack.3d.up")
                            .foregroundStyle(snapshot.needsYouCount > 0 ? Color.orange : Color.conduitAccent)
                            .accessibilityHidden(true)
                        Text(text)
                            .scaledFont(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: isPanelOpen ? "chevron.up" : "chevron.down")
                            .scaledFont(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .conduitGlassSurface(cornerRadius: 16, interactive: true)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .accessibilityLabel(text)
                .accessibilityHint(AppLocalization.string("Shows this bot's work"))
                .accessibilityIdentifier("botWork.strip")
            }
        }
        .refreshesBotWork(profile: profile)
    }
}

/// The bot's work: Active, then Recent. Each row opens its chat; a
/// workstream's row has its checklist and what the user can do with it.
struct BotWorkPanel: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var work: BotWorkStore
    let profile: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Work")
                    .scaledFont(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    Haptics.light()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Close"))
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 8)
            if let refusal = work.lastRefusal {
                Text(refusal)
                    .scaledFont(.footnote)
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            List {
                if let snapshot = work.snapshot(profile) {
                    if snapshot.items.isEmpty {
                        Text("No work yet")
                            .scaledFont(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !snapshot.active.isEmpty {
                        Section("Active") {
                            ForEach(snapshot.active) { item in
                                BotWorkRow(item: item, profile: profile, isActing: work.acting.contains(item.ref))
                            }
                        }
                    }
                    if !snapshot.recent.isEmpty {
                        Section("Recent") {
                            ForEach(snapshot.recent) { item in
                                BotWorkRow(item: item, profile: profile, isActing: work.acting.contains(item.ref))
                            }
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .refreshesBotWork(profile: profile)
        .accessibilityIdentifier("botWork.panel")
    }
}

/// One piece of work: its title, where it is, its last result, and its
/// checklist and actions once opened.
private struct BotWorkRow: View {
    @EnvironmentObject private var appState: AppState
    let item: BotWorkItem
    let profile: String
    let isActing: Bool
    @State private var expanded = false
    @State private var reply = ""

    private var tint: Color {
        switch item.status {
        case "needs_you", "interrupted": return .orange
        case "failed": return .red
        case "ready": return .green
        case "starting", "running", "waiting": return .conduitAccent
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Haptics.light()
                withAnimation(ConduitMotion.response) { expanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.ref)
                            .scaledFont(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(item.shownTitle)
                            .scaledFont(.body.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(expanded ? nil : 1)
                        Spacer(minLength: 4)
                        Text(item.statusText)
                            .scaledFont(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    }
                    if let doing = item.doing {
                        Text(doing)
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 1)
                    } else if !item.error.isEmpty, item.status != "done" {
                        Text(item.error)
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 2)
                    }
                    if !item.result.isEmpty {
                        Text(item.result)
                            .scaledFont(.footnote)
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .lineLimit(expanded ? 12 : 2)
                    } else if item.kind != .workstream, !item.goal.isEmpty {
                        Text(item.goal)
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? 8 : 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(AppLocalization.string("Shows more"))
            if expanded {
                if !item.checklist.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(item.checklist) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: line.state == .done ? "checkmark.circle.fill"
                                      : line.state == .doing ? "circle.dotted" : "circle")
                                    .scaledFont(.caption)
                                    .foregroundStyle(line.state == .done ? Color.green
                                                     : line.state == .doing ? Color.conduitAccent : Color.secondary)
                                    .accessibilityHidden(true)
                                Text(line.text)
                                    .scaledFont(.footnote)
                                    .foregroundStyle(line.state == .todo ? Color.secondary : Color.primary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(BotWorkItem.statusWord(line.state == .done ? "done"
                                                                       : line.state == .doing ? "running" : "waiting"))
                        }
                    }
                    .padding(.vertical, 2)
                }
                actions
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("botWork.row.\(item.ref)")
    }

    @ViewBuilder private var actions: some View {
        if item.kind == .workstream {
            HStack(spacing: 8) {
                if !item.sessionID.isEmpty {
                    actionButton(AppLocalization.string("Open chat"), symbol: "bubble.left.and.bubble.right") {
                        appState.openWorkstream(item, profile: profile)
                    }
                }
                if item.actions.contains(.check) {
                    actionButton(AppLocalization.string("Check first"), symbol: "questionmark.circle") {
                        Task { await appState.actOnWorkstream(item, profile: profile, action: .check) }
                    }
                }
                if item.actions.contains(.continue) {
                    actionButton(AppLocalization.string("Continue"), symbol: "play.fill") {
                        Task { await appState.actOnWorkstream(item, profile: profile, action: .continue) }
                    }
                }
                if item.actions.contains(.stop) {
                    actionButton(AppLocalization.string("Stop"), symbol: "stop.fill") {
                        Task { await appState.actOnWorkstream(item, profile: profile, action: .stop) }
                    }
                }
            }
            .disabled(isActing || !appState.isConnected)
            if item.actions.contains(.send) {
                HStack(spacing: 8) {
                    TextField(AppLocalization.string("Reply in \(item.ref)"), text: $reply, axis: .vertical)
                        .scaledFont(.subheadline)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        Task {
                            if await appState.actOnWorkstream(item, profile: profile, action: .send, text: text) {
                                reply = ""
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.conduitAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isActing || !appState.isConnected
                              || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(AppLocalization.string("Send"))
                }
            }
        }
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .scaledFont(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// Over a workstream's own chat: whose work it is, the way back to the
/// Bot Chat coordinating it, and Stop, Continue or Check first.
struct WorkstreamBar: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var work: BotWorkStore
    let profile: String
    let item: BotWorkItem

    private var botName: String {
        work.snapshot(profile)?.botName ?? profile
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Haptics.light()
                appState.openCoordinator(profile: profile)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .scaledFont(.caption.weight(.bold))
                        .accessibilityHidden(true)
                    Text(AppLocalization.string("Back to \(botName)"))
                        .scaledFont(.footnote.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.conduitAccent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workstream.back")
            Text(AppLocalization.string("\(botName)’s work · \(item.ref)"))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Group {
                if item.actions.contains(.check) {
                    barButton(AppLocalization.string("Check first"), action: .check)
                }
                if item.actions.contains(.continue) {
                    barButton(AppLocalization.string("Continue"), action: .continue)
                }
                if item.actions.contains(.stop) {
                    barButton(AppLocalization.string("Stop"), action: .stop)
                }
            }
            .disabled(work.acting.contains(item.ref) || !appState.isConnected)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .conduitGlassSurface(cornerRadius: 16)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .refreshesBotWork(profile: profile)
        .accessibilityIdentifier("workstream.bar")
    }

    private func barButton(_ title: String, action: BotWorkItem.Action) -> some View {
        Button(title) {
            Haptics.light()
            Task { await appState.actOnWorkstream(item, profile: profile, action: action) }
        }
        .scaledFont(.footnote.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// What shows over the open chat: a Bot Chat's Work strip, or the bar over
/// one of a bot's workstreams. Watches the bots' work itself, so the chat
/// screen redraws only when this does.
struct BotWorkHeader: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var work: BotWorkStore
    let isPanelOpen: Bool
    let onOpenPanel: () -> Void

    var body: some View {
        if let profile = appState.activeBotChatProfile {
            BotWorkStrip(work: work, profile: profile, isPanelOpen: isPanelOpen, onOpen: onOpenPanel)
        } else if let workstream = appState.activeWorkstream {
            WorkstreamBar(work: work, profile: workstream.profile, item: workstream.item)
        } else if appState.shownBotRoster.contains(where: { $0.name == appState.activeProfile }),
                  work.snapshot(appState.activeProfile) == nil {
            // A workstream opened from a link or a push before its bot's
            // work was read: read it once, so its bar can show.
            Color.clear
                .frame(height: 0)
                .task(id: appState.activeProfile) { await appState.refreshBotWork(profile: appState.activeProfile) }
        }
    }
}
