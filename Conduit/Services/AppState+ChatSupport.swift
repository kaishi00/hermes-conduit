//
//  AppState+ChatSupport.swift
//  Conduit
//
//  What the open chat leans on: the workspace, inline images and gateway
//  media, gateway diagnostics, the running state, scroll requests, the
//  session title, and test hooks. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Chat support surfaces

    func requestChatScrollToLatest() {
        chatScrollRequest &+= 1
    }

    func requestChatScrollToTop() {
        chatScrollToTopRequest &+= 1
    }

    func updateActiveSessionTitle(for sessionId: String, fallbackSessionId: String? = nil) {
        let ids = [sessionId, fallbackSessionId].compactMap { $0 }
        guard let session = (sessions + cronSessions).first(where: { session in
            ids.contains(session.id) || ids.contains(where: session.alternateIds.contains)
        }) else { return }
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        setActiveSessionTitle(title.isEmpty ? AppLocalization.string("New conversation") : title)
    }

    /// The drawer shell's + › Workspace (V2 off), which has no Artifacts:
    /// the Folder tab on its own.
    func openWorkspace() {
        // Without the chat's folder it still offers the projects'.
        showWorkspaceSheet = true
    }

    /// Hermes messages can refer to generated media as `MEDIA:
    /// /absolute/path.png`, while Desktop persists uploaded images as
    /// `@image:/absolute/path.png`. Keep those paths on the gateway: its
    /// authenticated dashboard returns a data URL that the chat can display
    /// without exposing a gateway filesystem URL to iOS.
    /// A picture stored inside a persisted message (#652), for when the
    /// file it came from is gone (Hermes clears its media caches after a
    /// day). The message is read once with its pictures inline, however
    /// many of them ask at the same time. One Hermes cannot serve (an older
    /// Hermes without the route, a message that is not a prompt) is not
    /// asked for again until the app restarts; a network failure is.
    func transcriptInlineImageDataURL(_ ref: InlineImageRef) async -> String? {
        let dashboard = activeDashboardID?.uuidString ?? ""
        let key = "\(dashboard)|\(ref.profile)|\(ref.sessionId)|\(ref.rowId)"
        let pictureKey = "\(key)|\(ref.index)"
        guard !shownChat.inlineImageRowsUnavailable.contains(key),
              !shownChat.inlineImageRowsUnavailable.contains(pictureKey) else { return nil }
        let fetch: Task<InlineImageRowFetch, Never>
        if let running = shownChat.inlineImageRowFetches[key] {
            fetch = running
        } else {
            fetch = Task { @MainActor [weak self] in
                guard let self else { return .failed }
                let result = await self.fetchInlineImageRow(ref)
                self.shownChat.inlineImageRowFetches[key] = nil
                if case .unavailable = result { self.shownChat.inlineImageRowsUnavailable.insert(key) }
                return result
            }
            shownChat.inlineImageRowFetches[key] = fetch
        }
        guard case .found(let urls) = await fetch.value else { return nil }
        guard urls.indices.contains(ref.index), let url = urls[ref.index] else {
            // The row holds no copy of this picture (a web link, or fewer
            // pictures than stand-ins), so it is not asked for again.
            shownChat.inlineImageRowsUnavailable.insert(pictureKey)
            return nil
        }
        return url
    }

    enum InlineImageRowFetch {
        case found([String?])
        case unavailable
        case failed
    }

    /// Hermes' timeline route reads one prompt by its row id, pictures
    /// included.
    private func fetchInlineImageRow(_ ref: InlineImageRef) async -> InlineImageRowFetch {
        guard let dashboardTicketBridge else { return .failed }
        do {
            let response = try await dashboardTicketBridge.requestJSON(
                path: Self.inlineImageRowPath(ref),
                // A message's pictures run to a few megabytes on a phone
                // network.
                timeoutMilliseconds: 45_000,
                maxResponseBytes: DataURLLimits.maxJSONResponseBytes
            )
            guard let rows = Self.persistedMessageRows(in: response) else { return .unavailable }
            let urls = MessageNormalizer.inlineImageDataURLs(inRows: rows, rowId: ref.rowId)
            return urls.isEmpty ? .unavailable : .found(urls)
        } catch DashboardTicketBridgeError.oversizedResponse {
            // A stored message never gets smaller, so it is not asked for
            // again.
            return .unavailable
        } catch {
            return Self.historySourceIsUnavailable(error) ? .unavailable : .failed
        }
    }

    nonisolated static func inlineImageRowPath(_ ref: InlineImageRef) -> String {
        let encodedSessionId = ref.sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref.sessionId
        return DashboardPath.withProfile(
            "/api/sessions/\(encodedSessionId)/messages/around?row_id=\(ref.rowId)&limit=1",
            profile: ref.profile
        )
    }

    func gatewayMediaDataURL(for path: String, profile: String) async -> String? {
        if case .dataURL(let dataURL) = await gatewayMediaRead(for: path, profile: profile) { return dataURL }
        return nil
    }

    /// The file's data URL, or why there's none: Hermes answered that it
    /// can't give the file (`gone`), or it couldn't be asked just now
    /// (`failed`: no connection, a cancelled or timed-out ask, a gateway in
    /// trouble), which a later ask may get past (issue 2015).
    func gatewayMediaRead(for path: String, profile: String) async -> GatewayMediaRead {
        guard dashboardTicketBridge != nil else { return .failed }
        guard let encodedPath = DashboardPath.encodedQueryComponent(path) else { return .gone }
        return await dataURLRead(
            endpoint: DashboardPath.withProfile("/api/fs/read-data-url?path=\(encodedPath)", profile: profile)
        )
    }

    /// A route answering `{"dataUrl": …}` as Hermes' read-data-url does: the
    /// gateway's own, or the plugin's for room pictures.
    func dataURLRead(endpoint: String) async -> GatewayMediaRead {
        guard let dashboardTicketBridge else { return .failed }
        do {
            let result = try await dashboardTicketBridge.requestJSON(
                path: endpoint,
                maxResponseBytes: DataURLLimits.maxJSONResponseBytes
            )
            // Any media type: inline images check for `data:image/`
            // themselves, while video, audio and document previews (#195)
            // take whatever the gateway returns.
            guard let dataURL = result["dataUrl"] as? String,
                  DataURLLimits.isBoundedBase64DataURL(dataURL) else { return .gone }
            return .dataURL(dataURL)
        } catch DashboardTicketBridgeError.http(let status, _) {
            return GatewayMediaRead.isRefusal(status: status) ? .gone : .failed
        } catch DashboardTicketBridgeError.oversizedResponse {
            return .gone
        } catch {
            return .failed
        }
    }

    /// Downloads a gateway `MEDIA:` video, audio clip or document to disk
    /// for opening (#569). `/api/fs/read-data-url` caps files at 16 MB on
    /// both ends, so larger ones stream from `/api/fs/download`, which
    /// resolves `path` and `profile` the same way.
    func gatewayMediaFile(
        for path: String,
        profile: String,
        maxBytes: Int = DashboardFileDownloadLimits.maxBytes
    ) async -> GatewayMediaFileResult {
        guard let dashboardTicketBridge,
              let encodedPath = DashboardPath.encodedQueryComponent(path) else { return .unavailable }
        let endpoint = DashboardPath.withProfile("/api/fs/download?path=\(encodedPath)", profile: profile)
        // Read through the presenter so its first-use sweep of old staging
        // folders runs before this download lands there, not after.
        let root = MediaPreviewPresenter.shared.stagingDirectory
        do {
            return .downloaded(try await dashboardTicketBridge.downloadFile(path: endpoint, filename: path, into: root, maxBytes: maxBytes))
        } catch DashboardTicketBridgeError.oversizedResponse {
            return .tooLarge
        } catch {
            return .unavailable
        }
    }

    func loadGatewayDiagnostics() async {
        showGatewaySheet = true
        await refreshGatewayDiagnostics()
    }

    /// Reloads what the Gateway sheet shows without presenting it.
    func refreshGatewayDiagnostics() async {
        gatewayDiagnosticsLoading = true
        defer { gatewayDiagnosticsLoading = false }
        guard let dashboardTicketBridge else {
            // Signed out or never connected, there's no dashboard to ask; what
            // the page keeps on this device still shows under this.
            let error = connection == nil && !isConnecting
                ? AppLocalization.string("Not connected. The gateway's status, connectors and logs show once Conduit reconnects.")
                : AppLocalization.string("Dashboard diagnostics are still loading.")
            gatewayDiagnostics = GatewayDiagnostics(gatewayRunning: isConnected, gatewayState: nil, version: nil, pid: nil, connectors: [], logs: [], error: error)
            return
        }
        async let statusResult = dashboardTicketBridge.requestJSON(path: "/api/status")
        async let platformsResult = dashboardTicketBridge.requestJSON(path: "/api/messaging/platforms")
        async let logsResult = dashboardTicketBridge.requestJSON(path: "/api/logs?lines=80&component=gateway")
        let status = try? await statusResult
        let platforms = try? await platformsResult
        let logs = try? await logsResult
        let connectors = ((platforms?["platforms"] as? [[String: Any]]) ?? []).enumerated().map { index, item in
            GatewayConnector(
                id: item["id"] as? String ?? item["name"] as? String ?? "connector-\(index)",
                name: item["name"] as? String ?? item["platform"] as? String ?? AppLocalization.string("Connector"),
                state: item["state"] as? String ?? item["status"] as? String ?? "unknown",
                error: item["error"] as? String,
                configured: item["configured"] as? Bool,
                enabled: item["enabled"] as? Bool
            )
        }
        gatewayDiagnostics = GatewayDiagnostics(
            gatewayRunning: status?["gateway_running"] as? Bool ?? isConnected,
            gatewayState: status?["gateway_state"] as? String,
            version: status?["version"] as? String,
            pid: status?["gateway_pid"] as? Int,
            connectors: connectors,
            logs: (logs?["lines"] as? [Any] ?? []).map { String(describing: $0) },
            error: status == nil ? AppLocalization.string("Could not refresh dashboard status.") : nil
        )
    }

    /// Takes `updated` as the runtime only when it differs: a same-value
    /// write still publishes AppState once per gateway frame.
    func setRuntime(_ updated: RuntimeState) {
        if runtime != updated { runtime = updated }
    }

    func setActiveAgents(_ count: Int) {
        if activeAgents != count { activeAgents = count }
    }

    func setRunning(_ running: Bool) {
        guard turnState != .unsupportedGateway else { return }
        // Every call is authoritative live evidence, even a re-affirmation:
        // the ambiguity-recovery guard compares revisions, not values.
        shownChat.turnLifecycleEvidence = TurnLifecycleEvidence(
            revision: shownChat.turnLifecycleEvidence.revision &+ 1,
            running: running
        )
        if running {
            clearPendingDecisionRestorationGuard()
        } else {
            // The turn settled. A locally-owned turn whose persisted
            // boundary was never positively observed leaves ordering debt:
            // Hermes persisted its user row at turn start, so the next
            // locally-owned turn must anchor AFTER it.
            recordLocalOrderingDebtForSettledTurn()
            shownChat.locallyOwnedInFlightTurn = nil
            shownChat.runningTurnNoteIDs = []
        }
        // Every message and reasoning delta re-affirms `.running`. Writing
        // the same value would still publish AppState once per gateway frame
        // and re-render every view and open sheet that observes it.
        let next: TurnState = running ? .running : .idle
        if turnState != next { turnState = next }
    }

    /// Records the minimum unresolved persisted-ordering obligation when a
    /// locally-owned turn settles. An unseen boundary owes one canonical user
    /// turn. A boundary observed only while live owes a zero-boundary settled
    /// tail read, because later assistant/tool rows may still have persisted.
    /// Debt counts accumulate when several locally-owned turns settle
    /// without an intervening read; authoritative adoption (a reconcile
    /// replacing the transcript) clears the debt outright. Identity
    /// rotation between turns replaces the slot — an undercount, which
    /// degrades to a spurious-but-safe authoritative reconcile, never to a
    /// silent overshoot.
    private func recordLocalOrderingDebtForSettledTurn() {
        guard let marker = shownChat.locallyOwnedInFlightTurn else { return }
        if !marker.persistedBoundaryObserved {
            recordLocalOrderingDebt(
                sessionIDs: marker.sessionIDs,
                baseline: marker.preSubmitOrderingBaseline
            )
        } else {
            recordLocalOrderingDebt(
                sessionIDs: marker.sessionIDs,
                baseline: marker.preSubmitOrderingBaseline,
                expectedUserTurnIncrement: 0,
                allowTrailingRowsWithoutNewUserBoundary: true
            )
        }
    }

    /// Debt-accounting core. Debt is only meaningful when the ordering
    /// baseline was PROVABLE: an unknown baseline (never hydrated, legacy
    /// gateway) has no ordering metadata to owe — the next turn's
    /// foreground classifies inconclusive and takes the conservative
    /// attach, exactly as before ordering evidence existed.
    func recordLocalOrderingDebt(
        sessionIDs: Set<String>,
        baseline: PersistedOrderingBaseline,
        expectedUserTurnIncrement: Int = 1,
        allowTrailingRowsWithoutNewUserBoundary: Bool = false
    ) {
        guard !baseline.isUnknown else { return }
        if shownChat.pendingLocalOrderingDebt?.sessionIDs == sessionIDs {
            shownChat.pendingLocalOrderingDebt?.expectedUserTurnCount += expectedUserTurnIncrement
            if allowTrailingRowsWithoutNewUserBoundary {
                shownChat.pendingLocalOrderingDebt?.allowTrailingRowsWithoutNewUserBoundary = true
            }
        } else {
            shownChat.pendingLocalOrderingDebt = PendingLocalOrderingDebt(
                sessionIDs: sessionIDs,
                expectedUserTurnCount: expectedUserTurnIncrement,
                allowTrailingRowsWithoutNewUserBoundary: allowTrailingRowsWithoutNewUserBoundary
            )
        }
    }

    /// Test-only: installs the post-connect voice capability state (bridge,
    /// snapshot, preference) without a dashboard round trip, so the read
    /// aloud / voice conversation mutual exclusion can be exercised with
    /// mock controllers. `readAloudGatewayBridge` is set to the same bridge
    /// so a mock read aloud gateway installed on the controller counts as
    /// current and is not replaced by a real one at tap time. Pass
    /// `transcriptionMode` / `appleSpeechAvailability` to pin the route the
    /// capability checks consult; nil leaves the current value.
    func installVoiceCapabilityStateForTesting(
        bridge: DashboardTicketBridge,
        snapshot: VoiceCapabilitySnapshot,
        isVoiceEnabled: Bool,
        transcriptionMode: VoiceTranscriptionMode? = nil,
        appleSpeechAvailability: AppleSpeechRecognitionAvailability? = nil,
        speechOutput: VoiceSpeechOutput? = nil
    ) {
        dashboardTicketBridge = bridge
        if let speechOutput { voiceSpeechOutputChoice = speechOutput }
        readAloudGatewayBridge = bridge
        voiceCapabilitySnapshot = snapshot
        self.isVoiceEnabled = isVoiceEnabled
        if let transcriptionMode { voiceTranscriptionMode = transcriptionMode }
        if let appleSpeechAvailability { self.appleSpeechAvailability = appleSpeechAvailability }
    }

    /// Test-only: installs a dashboard bridge (and nothing else) so profile
    /// discovery can exercise its bridge-identity commit gate — modeled
    /// connection swaps — without the voice capability snapshot plumbing.
    func installDashboardTicketBridgeForTesting(_ bridge: DashboardTicketBridge) {
        dashboardTicketBridge = bridge
    }

    /// Test-only: the connection's display settings read.
    func loadProfileDisplayPreferencesForTesting() async {
        await loadProfileDisplayPreferences()
    }

    /// Test-only: what the host's notifier plugin reported serving.
    func setNotifierPluginStateForTesting(_ state: NotifierPluginStatus.State) {
        notifierPlugin.state = state
    }

    /// Test-only: a group room on screen in place of the chat, or none.
    func setActiveRoomSurfaceForTesting(_ surface: GroupRoomSurface?) {
        activeRoomSurface = surface
    }
}
