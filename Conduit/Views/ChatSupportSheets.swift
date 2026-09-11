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
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(spacing: 14) {
                        summary
                        connectors
                        logs
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Gateway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await appState.loadGatewayDiagnostics() } } label: {
                        if appState.gatewayDiagnosticsLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .accessibilityLabel("Refresh gateway diagnostics")
                }
            }
        }
        .task { await appState.loadGatewayDiagnostics() }
    }

    private var summary: some View {
        let diagnostics = appState.gatewayDiagnostics
        let running = diagnostics?.gatewayRunning ?? appState.isConnected
        return ConduitSettingsSection(title: running ? "Connected" : "Disconnected", symbol: "radio", tint: running ? .green : .red) {
            SettingsMetricRow(label: String(localized: "Gateway"), value: diagnostics?.gatewayState ?? (running ? "Online" : "Unavailable"))
            if let version = diagnostics?.version { SettingsMetricRow(label: String(localized: "Version"), value: version) }
            if let pid = diagnostics?.pid { SettingsMetricRow(label: "Process", value: "PID \(pid)") }
            if let error = diagnostics?.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if !running {
                Button { Task { await appState.reconnect() } } label: {
                    Label("Retry connection", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
            }
        }
    }

    private var connectors: some View {
        let configuredConnectors = (appState.gatewayDiagnostics?.connectors ?? []).filter { $0.configured != false }
        return ConduitSettingsSection(title: "Connectors", symbol: "point.3.connected.trianglepath.dotted", tint: .conduitAura) {
            if configuredConnectors.isEmpty {
                Text("No configured connectors were reported.").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(configuredConnectors) { connector in
                    HStack(spacing: 10) {
                        Circle().fill(connectorColor(connector.state)).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connector.name).font(.subheadline.weight(.medium))
                            Text([connector.state, connector.error].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var logs: some View {
        ConduitSettingsSection(title: String(localized: "Recent gateway logs"), symbol: "text.alignleft", tint: .conduitAccent) {
            let lines = appState.gatewayDiagnostics?.logs ?? []
            if lines.isEmpty {
                Text("No gateway log lines were returned.").font(.footnote).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(lines.joined(separator: "\n"))
                        .font(.caption.monospaced())
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

struct WorkspaceBrowserSheet: View {
    @EnvironmentObject private var appState: AppState
    @State private var previewOpen = false

    private var rows: [(entry: WorkspaceEntry, depth: Int)] {
        flatten(appState.workspaceEntries[appState.workspaceRoot] ?? [], depth: 0)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                Group {
                    if appState.workspaceRoot.isEmpty {
                        ContentUnavailableView("Workspace unavailable", systemImage: "folder.badge.questionmark", description: Text("Hermes has not reported a working directory for this session yet."))
                    } else {
                        List(rows, id: \.entry.id) { row in
                            Button {
                                if row.entry.isDirectory {
                                    Task { await appState.toggleWorkspaceFolder(row.entry) }
                                } else {
                                    previewOpen = true
                                    Task { await appState.previewWorkspaceFile(row.entry) }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: row.entry.isDirectory ? "folder.fill" : "doc.text")
                                        .foregroundStyle(row.entry.isDirectory ? .conduitAccent : .secondary)
                                    Text(row.entry.name).lineLimit(1)
                                    Spacer()
                                    if row.entry.isDirectory {
                                        Image(systemName: appState.expandedWorkspacePaths.contains(row.entry.path) ? "chevron.down" : "chevron.right")
                                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.leading, CGFloat(row.depth) * 18)
                            }
                            .tint(.primary)
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle(workspaceTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await appState.refreshWorkspace() } } label: {
                        if appState.workspaceLoadingPath == appState.workspaceRoot { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .accessibilityLabel("Refresh workspace")
                }
            }
        }
        .sheet(isPresented: $previewOpen) {
            WorkspaceFilePreviewSheet()
                .presentationDetents([.medium, .large])
        }
    }

    private var workspaceTitle: String {
        let name = URL(fileURLWithPath: appState.workspaceRoot).lastPathComponent
        return name.isEmpty ? String(localized: "Workspace") : name
    }

    private func flatten(_ entries: [WorkspaceEntry], depth: Int) -> [(entry: WorkspaceEntry, depth: Int)] {
        entries.flatMap { entry in
            var result = [(entry: entry, depth: depth)]
            if entry.isDirectory, appState.expandedWorkspacePaths.contains(entry.path) {
                result += flatten(appState.workspaceEntries[entry.path] ?? [], depth: depth + 1)
            }
            return result
        }
    }
}

private struct WorkspaceFilePreviewSheet: View {
    @EnvironmentObject private var appState: AppState
    @State private var downloadURL: URL?

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if appState.workspaceFileLoading {
                            ProgressView("Loading preview…").frame(maxWidth: .infinity, minHeight: 180)
                        } else if let error = appState.workspaceFileError {
                            ContentUnavailableView("Couldn’t preview file", systemImage: "exclamationmark.triangle", description: Text(error))
                        } else if let preview = appState.workspacePreview {
                            fileMetadata(preview)
                            if preview.binary {
                                ContentUnavailableView("Binary file", systemImage: "doc.fill", description: Text("Use Save to Files to download this file."))
                            } else {
                                Text(preview.text.isEmpty ? "This file is empty." : preview.text)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        } else {
                            ContentUnavailableView("Select a file", systemImage: "doc.text")
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(appState.workspaceSelectedFile?.name ?? "File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let downloadURL {
                        ShareLink(item: downloadURL, preview: SharePreview(appState.workspaceSelectedFile?.name ?? String(localized: "Workspace file"))) {
                            Label("Save to Files", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button { download() } label: { Image(systemName: "arrow.down.circle") }
                            .accessibilityLabel("Prepare file for download")
                    }
                }
            }
        }
    }

    private func fileMetadata(_ preview: WorkspaceFilePreview) -> some View {
        ConduitSettingsSection(title: String(localized: "File"), symbol: "doc", tint: .conduitAccent) {
            SettingsMetricRow(label: String(localized: "Type"), value: preview.language)
            SettingsMetricRow(label: String(localized: "Size"), value: ByteCountFormatter.string(fromByteCount: Int64(preview.byteSize), countStyle: .file))
            if preview.truncated { Text("Preview is truncated; save the file for its full contents.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func download() {
        guard let entry = appState.workspaceSelectedFile else { return }
        Task { downloadURL = await appState.workspaceDownloadURL(for: entry) }
    }
}

struct DelegateAgentsSheet: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(spacing: 12) {
                        ConduitSettingsSection(title: String(localized: "Delegate agents"), symbol: "person.2", tint: .conduitAccent) {
                            Text(activeSummary).font(.footnote).foregroundStyle(.secondary)
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
    }

    private var activeSummary: String {
        let active = appState.delegateAgents.filter(\.status.isActive).count
        return active == 0 ? String(localized: "Latest delegation activity") : String(localized: "\(String(active)) working now")
    }
}

private struct DelegateAgentCard: View {
    let agent: DelegateAgentActivity
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.goal).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text([agent.model, agent.currentTool, agent.status.label].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
            if expanded {
                if agent.stream.isEmpty {
                    Text(agent.summary ?? (agent.status.isActive ? String(localized: "Waiting for activity…") : "No stream output returned."))
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(agent.stream.suffix(10)) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.kind == .tool ? "›" : "•").foregroundStyle(line.isError ? .red : .conduitAccent)
                            Text(line.text).font(.footnote).foregroundStyle(line.isError ? .red : .secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .conduitGlassSurface(cornerRadius: 20, tint: statusColor.opacity(0.06))
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
