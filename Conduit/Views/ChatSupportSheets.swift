//
//  ChatSupportSheets.swift
//  Conduit
//
//  Support surfaces shared by the chat header and composer. These use the
//  authenticated dashboard bridge already owned by AppState, matching the
//  React client instead of opening unauthenticated URLs in a browser.
//

import SwiftUI

struct GatewayDiagnosticsSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    /// The report copied last, so "Copied" clears once a newer step lands.
    @State private var copiedTimelineReport: String?
    @State private var confirmingRestart = false
    /// Pushed inside Settings > Connection rather than shown as its own sheet.
    var embedded = false

    var body: some View {
        if embedded {
            page
        } else {
            NavigationStack { page }
        }
    }

    private var page: some View {
        ZStack {
            ConduitBackdrop()
            ScrollView {
                VStack(spacing: 22) {
                    summary
                    lastConnection
                    DeviceReportsSection()
                    connectors
                    logs
                }
                .padding(16)
            }
        }
        .navigationTitle(embedded ? AppLocalization.string("Diagnostics & logs") : AppLocalization.string("Gateway"))
        .navigationBarTitleDisplayMode(.inline)
        // Pushed, it keeps the Settings pages' bar.
        .toolbarBackground(embedded ? .automatic : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { confirmingRestart = true } label: {
                    Image(systemName: "restart")
                }
                .disabled(!appState.canRestartGateway)
                .accessibilityLabel(AppLocalization.string("Restart Gateway"))
                .accessibilityIdentifier("gateway.restart")
                Button { Task { await appState.refreshGatewayDiagnostics() } } label: {
                    if appState.gatewayDiagnosticsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .accessibilityLabel(AppLocalization.string("Refresh gateway diagnostics"))
            }
        }
        .gatewayRestartConfirmation(isPresented: $confirmingRestart)
        // Pushed from Settings it only reloads; loading also raises the sheet.
        .task {
            if embedded {
                await appState.refreshGatewayDiagnostics()
            } else {
                await appState.loadGatewayDiagnostics()
            }
        }
    }

    private var summary: some View {
        let diagnostics = appState.gatewayDiagnostics
        let running = diagnostics?.gatewayRunning ?? appState.isConnected
        return ConduitSettingsSection(title: running ? AppLocalization.string("Connected") : AppLocalization.string("Disconnected"), symbol: "radio", tint: running ? .green : .red) {
            SettingsMetricRow(label: AppLocalization.string("Gateway"), value: diagnostics?.gatewayState ?? (running ? AppLocalization.string("Online") : AppLocalization.string("Unavailable")))
            if let version = diagnostics?.version { SettingsMetricRow(label: AppLocalization.string("Version"), value: version) }
            if let pid = diagnostics?.pid { SettingsMetricRow(label: AppLocalization.string("Process"), value: AppLocalization.string("PID \(String(pid))")) }
            if let error = diagnostics?.error {
                Text(error).scaledFont(.footnote).foregroundStyle(.red)
            }
            GatewayRestartStatusView()
            if !running && !appState.activeGatewayRestart.isInProgress {
                Button { Task { await appState.reconnect() } } label: {
                    Label(AppLocalization.string("Retry connection"), systemImage: "arrow.clockwise")
                        .scaledFont(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 44)
                }
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
            }
        }
    }

    /// Where the last launch, return or reconnect spent its time (#417):
    /// numbers someone on a slow network can paste into an issue. The report
    /// itself is an English diagnostic log, like the gateway logs below.
    private var lastConnection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Last connection"), symbol: "stopwatch", tint: .conduitAccent) {
            // The timeline isn't @Published, so recording a step re-renders
            // nothing. Re-read it every second while this sheet is open, so
            // steps still landing during a slow start show up, and Copy takes
            // what is on screen.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 14) {
                    lastConnectionContent
                }
            }
        }
    }

    /// The connection timeline, then the last call from Hermes (#449) and
    /// the last Grok Live, Qwen Live or Local Live call's steps, so one Copy takes them all.
    private var lastConnectionReport: String? {
        let reports = [appState.connectionTimeline?.report, HermesCallTrace.shared.timeline?.report, LiveCallTrace.shared.report].compactMap { $0 }
        return reports.isEmpty ? nil : reports.joined(separator: "\n\n")
    }

    @ViewBuilder
    private var lastConnectionContent: some View {
        if let report = lastConnectionReport {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: report)
                    .scaledFont(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = report
                    copiedTimelineReport = report
                } label: {
                    Label("Copy", systemImage: copiedTimelineReport == report ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.settings)
                .accessibilityLabel("Copy connection timeline")
                .accessibilityValue(copiedTimelineReport == report ? AppLocalization.string("Copied") : "")
                if copiedTimelineReport == report {
                    Text("Copied")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } else {
            Text("No connection has been timed since Conduit opened.")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var connectors: some View {
        let configuredConnectors = (appState.gatewayDiagnostics?.connectors ?? []).filter { $0.configured != false }
        return ConduitSettingsSection(title: AppLocalization.string("Connectors"), symbol: "point.3.connected.trianglepath.dotted", tint: .conduitAura) {
            if configuredConnectors.isEmpty {
                Text("No configured connectors were reported.").scaledFont(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(configuredConnectors) { connector in
                    HStack(spacing: 10) {
                        Circle().fill(connectorColor(connector.state)).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connector.name).scaledFont(.subheadline.weight(.medium))
                            Text([connector.state, connector.error].compactMap { $0 }.joined(separator: " · "))
                                .scaledFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var logs: some View {
        ConduitSettingsSection(title: AppLocalization.string("Recent gateway logs"), symbol: "text.alignleft", tint: .conduitAccent) {
            let lines = appState.gatewayDiagnostics?.logs ?? []
            if lines.isEmpty {
                Text("No gateway log lines were returned.").scaledFont(.footnote).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(lines.joined(separator: "\n"))
                        .scaledFont(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func connectorColor(_ state: String) -> Color {
        switch state.lowercased() {
        case "connected", "running", "ready", "online": return .green
        case "connecting", "starting": return .orange
        default: return .red
        }
    }
}

/// The drawer shell's + › Workspace (V2 off), which has no Artifacts: the
/// Folder tab on its own, at the chat's folder (#1389).
struct WorkspaceSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                WorkspaceFolderView(includesChat: true, handlesReveals: true)
            }
            .navigationTitle(Text("Folder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct DelegateAgentsSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(spacing: 22) {
                        ConduitSettingsSection(title: AppLocalization.string("Delegate agents"), symbol: "person.2", tint: .conduitAccent) {
                            Text(activeSummary).scaledFont(.footnote).foregroundStyle(.secondary)
                        }
                        if appState.delegateAgents.isEmpty {
                            ContentUnavailableView("No delegate agents", systemImage: "person.2.slash", description: Text("Delegate activity for this conversation will appear here."))
                                .padding(.top, 44)
                        } else {
                            ForEach(appState.delegateAgents) { agent in
                                DelegateAgentCard(agent: agent)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Delegate agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task { await appState.refreshDelegateAgents() }
    }

    private var activeSummary: String {
        let activeCount = appState.delegateAgents.filter(\.status.isActive).count
        return activeCount == 0 ? AppLocalization.string("Latest delegation activity") : AppLocalization.string("\(activeCount) working now")
    }
}

private struct DelegateAgentCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let agent: DelegateAgentActivity
    @State private var expanded = true
    @State private var steering = false
    @State private var steerText = ""
    @State private var confirmingStop = false
    @State private var showingTail = false
    @State private var working = false
    @State private var note: (text: String, isError: Bool)?

    /// Hermes takes Steer, Stop and live output only for an agent it named
    /// and still runs (#820).
    private var controllable: Bool { agent.status == .running && agent.hasGatewayID && !agent.sessionId.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Button { withAnimation { expanded.toggle() } } label: {
                    HStack(spacing: 10) {
                        Circle().fill(statusColor).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.goal.isEmpty ? AppLocalization.string("Delegate agent") : agent.goal).scaledFont(.subheadline.weight(.semibold)).lineLimit(2)
                            Text([agent.model, agent.currentTool, agent.status.label].compactMap { $0 }.joined(separator: " · "))
                                .scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").scaledFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
                .accessibilityValue(expanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
                if controllable {
                    controlsMenu
                }
            }
            if let note {
                Text(note.text).scaledFont(.caption).foregroundStyle(note.isError ? .red : .secondary)
            }
            if expanded {
                if agent.stream.isEmpty {
                    Text(agent.summary ?? (agent.status.isActive ? AppLocalization.string("Waiting for activity…") : AppLocalization.string("No stream output returned.")))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(agent.stream.suffix(10)) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.kind == .tool ? "›" : "•").foregroundStyle(line.isError ? .red : .conduitAccent)
                            Text(line.text).scaledFont(.footnote).foregroundStyle(line.isError ? .red : .secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .conduitGlassSurface(cornerRadius: 20, tint: statusColor.opacity(0.06))
        .alert("Steer this agent", isPresented: $steering) {
            TextField("What should it do differently?", text: $steerText, axis: .vertical)
            Button("Send") { sendSteer() }
                .disabled(steerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { steerText = "" }
        } message: {
            Text("The agent reads this at its next step.")
        }
        .confirmationDialog("Stop this agent?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop agent", role: .destructive) { stop() }
        } message: {
            Text("The agent stops where it is. The chat carries on without its result.")
        }
        .sheet(isPresented: $showingTail) {
            DelegateAgentTailSheet(
                title: agent.goal.isEmpty ? AppLocalization.string("Delegate agent") : agent.goal,
                isRunning: { appState.delegateAgents.first(where: { $0.id == agent.id && $0.sessionId == agent.sessionId })?.status.isActive ?? false },
                load: { await appState.tailDelegateAgent(agent) }
            )
        }
    }

    private var controlsMenu: some View {
        Menu {
            Button { steering = true } label: { Label("Steer…", systemImage: "arrow.triangle.turn.up.right.circle") }
            Button { showingTail = true } label: { Label("Live output", systemImage: "text.alignleft") }
            Button(role: .destructive) { confirmingStop = true } label: { Label("Stop agent", systemImage: "stop.circle") }
        } label: {
            Group {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis.circle").scaledFont(.body).foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .disabled(working)
        .accessibilityLabel(AppLocalization.string("Agent actions"))
        .accessibilityIdentifier("delegateAgent.actions")
    }

    private func sendSteer() {
        guard !working else { return }
        let text = steerText
        steerText = ""
        working = true
        Task {
            let result = await appState.steerDelegateAgent(agent, text: text)
            working = false
            switch result {
            case .done: note = (AppLocalization.string("Sent. The agent reads it at its next step."), false)
            case .notRunning: note = (AppLocalization.string("This agent has already finished."), true)
            case .failed:
                // Kept for Steer… again, so a dropped send isn't retyped.
                steerText = text
                note = (AppLocalization.string("Couldn't reach this agent."), true)
            }
        }
    }

    private func stop() {
        guard !working else { return }
        working = true
        Task {
            let result = await appState.interruptDelegateAgent(agent)
            working = false
            switch result {
            case .done: note = nil
            case .notRunning: note = (AppLocalization.string("This agent has already finished."), true)
            case .failed: note = (AppLocalization.string("Couldn't reach this agent."), true)
            }
        }
    }

    private var statusColor: Color {
        switch agent.status {
        case .queued: return .orange
        case .running: return .conduitAccent
        case .completed: return .green
        case .failed: return .red
        case .interrupted: return .secondary
        }
    }
}

/// The end of one delegate agent's live transcript, read again every two
/// seconds while the agent runs (#820).
private struct DelegateAgentTailSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss
    let title: String
    let isRunning: () -> Bool
    let load: () async -> SubagentTail?
    @State private var tail: SubagentTail?
    @State private var loaded = false
    @State private var failed = false
    /// New output scrolls into view until the reader drags; Latest resumes.
    @State private var following = true

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if let tail, tail.available, !tail.text.isEmpty {
                                if tail.truncated {
                                    Text("Showing the latest output only.").scaledFont(.caption).foregroundStyle(.secondary)
                                }
                                Text(verbatim: tail.text)
                                    .scaledFont(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if !loaded {
                                ProgressView().frame(maxWidth: .infinity).padding(.top, 44)
                            } else {
                                ContentUnavailableView(
                                    failed ? AppLocalization.string("Couldn't load output") : AppLocalization.string("No output yet"),
                                    systemImage: "text.alignleft",
                                    description: Text(failed ? AppLocalization.string("Hermes didn't send this agent's output.") : AppLocalization.string("Output appears here once the agent writes some."))
                                )
                                .padding(.top, 44)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                    }
                    .simultaneousGesture(DragGesture().onChanged { _ in following = false })
                    .onChange(of: tail) { _, _ in
                        if following { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            if !following {
                                Button {
                                    following = true
                                    withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                                } label: {
                                    Label("Latest", systemImage: "arrow.down.to.line")
                                }
                                .accessibilityLabel(AppLocalization.string("Jump to latest activity"))
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            while !Task.isCancelled {
                let next = await load()
                failed = next == nil
                if let next { tail = next }
                loaded = true
                guard isRunning() else { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// iOS's own MetricKit reports for Conduit (MetricKitReports): a short
/// English summary of the latest day and a file to share, for battery and
/// data questions. Nothing here is uploaded; a new crash or hang is
/// offered once on its own card (CrashReportOffer).
private struct DeviceReportsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @State private var loaded: MetricKitReports.Loaded?
    @State private var loading = false

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Device reports"), symbol: "chart.bar.doc.horizontal", tint: .conduitAccent) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Usage, network and hang reports iOS makes about once a day. They stay on this device until you share them.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                Text("After a crash or freeze, Conduit asks once whether to send that report to its developer.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                if let summary = loaded?.summary, !summary.isEmpty {
                    // A summary, so it wraps rather than scrolling sideways.
                    Text(verbatim: summary.text)
                        .scaledFont(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if loading {
                    ProgressView().controlSize(.small)
                } else if let exportURL = loaded?.exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share device reports", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.settings)
                    .accessibilityLabel(AppLocalization.string("Share device reports"))
                    .accessibilityIdentifier("diagnostics.shareDeviceReports")
                } else if loaded?.exportFailed == true {
                    // Reports are stored but the file to share isn't: say so
                    // rather than leave the page looking empty.
                    Text("Couldn't write the device reports file.")
                        .scaledFont(.footnote)
                        .foregroundStyle(.red)
                    Button { Task { await load() } } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.settings)
                    .accessibilityIdentifier("diagnostics.retryDeviceReports")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        loaded = await MetricKitReports.shared.load()
        loading = false
    }
}
