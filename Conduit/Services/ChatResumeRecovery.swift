//
//  ChatResumeRecovery.swift
//  Conduit
//
//  The seams and steps of resuming a chat: the lifecycle operations
//  tests replace, reconnect scheduling, and the recovery sequence that
//  replays a resume's transport and conversation steps in order.
//  Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

typealias ChatResumeReconnectCancellation = @MainActor () -> Void

typealias ChatResumeReconnectExecutor = @MainActor (ChatResumeSyncPurpose) async -> Void

typealias ChatResumeReconnectScheduler = @MainActor (
    _ delay: TimeInterval,
    _ operation: @escaping @MainActor () async -> Void
) -> ChatResumeReconnectCancellation

struct ChatResumeLifecycleOperations {
    typealias BranchResult = (sessionId: String, storedSessionId: String?, profile: String?)

    var connectClient: (@MainActor (HermesClient) async throws -> Void)?
    var loadCatalog: (@MainActor (HermesClient, Bool) async throws -> [SessionSummary])?
    var mintTicket: (@MainActor (String) async throws -> String)?
    var openSession: (@MainActor (HermesClient, String, Bool) async throws -> SessionResumeResult)?
    /// Profile-aware variant of `openSession`. Preferred over the 3-argument
    /// seam when set, so tests can pin WHICH Hermes profile a resume
    /// addresses (bot chats resume the bot's profile).
    var openSessionWithProfile: (@MainActor (HermesClient, String, Bool, String?) async throws -> SessionResumeResult)?
    /// Seam for the initial persisted-history fetch. Receives the session id,
    /// profile, AND the exact query the production path builder built —
    /// `order=latest offset=0` for the bounded tail page, the legacy one-shot
    /// request for the re-read — so callables can observe the request shape,
    /// not just the call order (bounded first, one-shot re-read second, at
    /// most once).
    var persistedTranscript: (@MainActor (
        String,
        String,
        String
    ) async -> PersistedTranscriptFetchOutcome)?
    /// Seam for older-page backfill requests only (`offset` = the window's
    /// next offset). Distinct from `persistedTranscript` so backfill tests
    /// never collide with initial-hydration fixtures.
    var loadEarlierTranscriptPage: (@MainActor (String, String, Int) async -> PersistedTranscriptFetchOutcome)?
    var branchSession: (@MainActor (
        HermesClient,
        String,
        [SessionBranchMessage],
        String,
        String?
    ) async throws -> BranchResult)?
    var setSessionTitle: (@MainActor (HermesClient, String, String) async throws -> Void)?
    var refreshContext: (@MainActor (HermesClient, String) async -> Void)?
    /// Test seam: awaited by a reconcile right after it applied Hermes'
    /// transcript, before it settles, so a test can act in that window. Nil
    /// in the app, where nothing waits there (issue 1824).
    var afterResumeApplied: (@MainActor (HermesClient, String) async -> Void)?
    var pendingApprovals: (@MainActor (HermesClient, String) async throws -> [ApprovalActivity])?
    /// Profile-aware variant of `pendingApprovals`. Preferred over the 2-argument
    /// seam when set, so tests can pin WHICH Hermes profile a pending approvals
    /// query addresses (bot chats query under the bot's presentation profile).
    var pendingApprovalsWithProfile: (@MainActor (HermesClient, String, String?) async throws -> [ApprovalActivity])?
    /// Decision response seam. Tests can intercept and verify the session,
    /// request ID, choice, and explicit presentation profile passed to the
    /// decision RPC.
    var respondToApproval: (@MainActor (HermesClient, String, String?, String, String?) async throws -> Bool)?
    var sendPrompt: (@MainActor (HermesClient, String, String) async throws -> PromptSubmissionOutcome)?
    /// Test seam for a Queue send (`queued: true`, #842). Not an init
    /// parameter: tests set it on the value.
    var sendQueuedPrompt: (@MainActor (HermesClient, String, String) async throws -> PromptSubmissionOutcome)?
    /// Test seam for one attachment upload (session id, attachment) before
    /// the prompt; returns the `@file:` reference the prompt carries, nil
    /// for an image. Not an init parameter: tests set it on the value.
    var uploadAttachment: (@MainActor (HermesClient, String, Attachment) async throws -> String?)?
    /// Test seams for the two upload RPCs under the production routing:
    /// `image.attach_bytes` (session id, base64, filename) and `file.attach`
    /// (session id, data URL, name; returns the `@file:` reference).
    var attachImageBytes: (@MainActor (HermesClient, String, String, String) async throws -> Void)?
    var attachFileData: (@MainActor (HermesClient, String, String, String) async throws -> String?)?
    /// Foreground transport verification. Production calls the client's
    /// `ping` health check; tests substitute a controllable outcome.
    var verifyTransportHealth: (@MainActor (HermesClient) async throws -> Void)?
    /// Foreground liveness probe against the gateway's runtime registry.
    /// Production calls `session.active_list`; unsupported gateways throw and
    /// the caller degrades to the resume-based refresh.
    var probeActiveSessions: (@MainActor (HermesClient) async throws -> [LiveSessionStatus])?
    var steer: (@MainActor (HermesClient, String, String) async throws -> Void)?
    var redirect: (@MainActor (
        HermesClient,
        String,
        String
    ) async throws -> SessionRedirectOutcome)?
    var interrupt: (@MainActor (HermesClient, String) async throws -> Void)?
    var executeSlash: (@MainActor (HermesClient, String, String) async throws -> AnyCodable)?
    var dispatchCommand: (@MainActor (
        HermesClient,
        String,
        String,
        String
    ) async throws -> AnyCodable)?
    var setBusyInputMode: (@MainActor (HermesClient, BusyInputMode) async throws -> Void)?
    var setSessionYolo: (@MainActor (HermesClient, String, Bool) async throws -> Void)?
    var loadProfiles: (@MainActor () async -> Void)?
    var loadBusyInputMode: (@MainActor (HermesClient) async -> Void)?
    var loadProfileDisplayPreferences: (@MainActor () async -> Void)?
    var loadSlashCommands: (@MainActor () async -> Void)?
    /// Bot Mode's connect-time roster/registry load. Tests substitute it so a
    /// harness never reaches the network for bot evidence; production runs the
    /// ordinary `refreshBotRoster()` (single-flight, epoch-fenced).
    var loadBotRoster: (@MainActor () async -> Void)?
    /// Side-agent start (`prompt.background` / `prompt.btw`). Not an init
    /// parameter: tests set it on the value.
    var startSideAgent: (@MainActor (HermesClient, SideAgentKind, String, String) async throws -> String?)?
    /// `/stop`'s `process.stop`: how many background processes stopped.
    /// Not an init parameter: tests set it on the value.
    var stopProcesses: (@MainActor (HermesClient, String) async throws -> Int)?
    /// `/reload-mcp`'s `reload.mcp` (session, confirm, always) and
    /// `/reload-skills`'s `skills.reload`. Not init parameters: tests set
    /// them on the value.
    var reloadMCP: (@MainActor (HermesClient, String, Bool, Bool) async throws -> MCPReloadOutcome)?
    var reloadSkills: (@MainActor (HermesClient, String) async throws -> String)?
    /// `/undo` and `/retry`: the rewind snapshot, then the rewind itself.
    /// Not init parameters: tests set them on the value.
    var rewindSnapshot: (@MainActor (HermesClient, String) async throws -> SessionRewindSnapshot)?
    var rewindSession: (@MainActor (HermesClient, String, Int, SessionRewindSnapshot) async throws -> SessionRewindReceipt)?
    var compressSession: (@MainActor (
        HermesClient,
        String,
        String?
    ) async throws -> SessionCompressResult)?
    /// Bot Mode roster probe (`profiles.list`).
    var botRoster: (@MainActor (HermesClient) async throws -> BotRosterSnapshot)?
    /// Bot Mode canonical-chat registry lookup (`session.list` exact title).
    var findBotChat: (@MainActor (HermesClient, String) async throws -> [BotChatLookupRow])?
    /// Bot Mode canonical chat creation (`session.create`, hidden).
    var createBotChat: (@MainActor (HermesClient, String) async throws -> (sessionId: String, storedSessionId: String?))?
    /// Bot Mode canonical title write (`session.title`). The fourth
    /// argument is the BOT profile being addressed — it exists so tests can
    /// pin the addressing, and must never be forwarded to the 3-argument
    /// `setSessionTitle` seam used by ordinary (dashboard-profile) renames.
    var titleBotChat: (@MainActor (HermesClient, String, String, String) async throws -> Void)?
    /// Test seam: the WebSocket transport for clients built by makeClient; nil = URLSession.
    var makeTransport: (@MainActor () -> any HermesWebSocketTransport)?
    /// Test seam for the `session.create` of the automatic resume's fresh
    /// chat (`createAndReconcileSession` without a widget lease): client and
    /// cwd in, the created ids out. Not an init parameter: tests set it on
    /// the value.
    var createSession: (@MainActor (HermesClient, String?) async throws -> BranchResult)?
    /// Test seams for a room's new chat (RoomChats.swift): `session.create`
    /// in a profile (nil for the dashboard's), and its title, by the id it
    /// runs under, in that profile. Not init parameters either.
    var createRoomChat: (@MainActor (HermesClient, String?) async throws -> BranchResult)?
    var titleRoomChat: (@MainActor (HermesClient, String, String, String?) async throws -> Void)?
    /// Test seams for the bot editor, client and profile in: its
    /// `profiles.describe`, its MCP page's `mcp.catalog` and
    /// `mcp.servers.list`, and a save's skills, tools and MCP sections
    /// (`profiles.configure`, the sections in, Hermes' answer out). Not init
    /// parameters either.
    var describeBotProfile: (@MainActor (HermesClient, String) async throws -> BotProfileDetails)?
    var botMcpCatalog: (@MainActor (HermesClient, String) async throws -> [BotMcpCatalogEntry])?
    var botMcpServers: (@MainActor (HermesClient, String) async throws -> [BotMcpServerSummary])?
    var configureBotSections: (@MainActor (HermesClient, String, [String: Any]) async throws -> AnyCodable)?

    init(
        connectClient: (@MainActor (HermesClient) async throws -> Void)? = nil,
        loadCatalog: (@MainActor (HermesClient, Bool) async throws -> [SessionSummary])? = nil,
        mintTicket: (@MainActor (String) async throws -> String)? = nil,
        openSession: (@MainActor (HermesClient, String, Bool) async throws -> SessionResumeResult)? = nil,
        openSessionWithProfile: (@MainActor (HermesClient, String, Bool, String?) async throws -> SessionResumeResult)? = nil,
        persistedTranscript: (@MainActor (
            String,
            String,
            String
        ) async -> PersistedTranscriptFetchOutcome)? = nil,
        loadEarlierTranscriptPage: (@MainActor (String, String, Int) async -> PersistedTranscriptFetchOutcome)? = nil,
        branchSession: (@MainActor (
            HermesClient,
            String,
            [SessionBranchMessage],
            String,
            String?
        ) async throws -> BranchResult)? = nil,
        setSessionTitle: (@MainActor (HermesClient, String, String) async throws -> Void)? = nil,
        refreshContext: (@MainActor (HermesClient, String) async -> Void)? = nil,
        afterResumeApplied: (@MainActor (HermesClient, String) async -> Void)? = nil,
        pendingApprovals: (@MainActor (HermesClient, String) async throws -> [ApprovalActivity])? = nil,
        pendingApprovalsWithProfile: (@MainActor (HermesClient, String, String?) async throws -> [ApprovalActivity])? = nil,
        respondToApproval: (@MainActor (HermesClient, String, String?, String, String?) async throws -> Bool)? = nil,
        sendPrompt: (@MainActor (HermesClient, String, String) async throws -> PromptSubmissionOutcome)? = nil,
        verifyTransportHealth: (@MainActor (HermesClient) async throws -> Void)? = nil,
        probeActiveSessions: (@MainActor (HermesClient) async throws -> [LiveSessionStatus])? = nil,
        steer: (@MainActor (HermesClient, String, String) async throws -> Void)? = nil,
        redirect: (@MainActor (
            HermesClient,
            String,
            String
        ) async throws -> SessionRedirectOutcome)? = nil,
        interrupt: (@MainActor (HermesClient, String) async throws -> Void)? = nil,
        executeSlash: (@MainActor (HermesClient, String, String) async throws -> AnyCodable)? = nil,
        dispatchCommand: (@MainActor (
            HermesClient,
            String,
            String,
            String
        ) async throws -> AnyCodable)? = nil,
        setBusyInputMode: (@MainActor (HermesClient, BusyInputMode) async throws -> Void)? = nil,
        setSessionYolo: (@MainActor (HermesClient, String, Bool) async throws -> Void)? = nil,
        loadProfiles: (@MainActor () async -> Void)? = nil,
        loadBusyInputMode: (@MainActor (HermesClient) async -> Void)? = nil,
        loadProfileDisplayPreferences: (@MainActor () async -> Void)? = nil,
        loadSlashCommands: (@MainActor () async -> Void)? = nil,
        loadBotRoster: (@MainActor () async -> Void)? = nil,
        compressSession: (@MainActor (
            HermesClient,
            String,
            String?
        ) async throws -> SessionCompressResult)? = nil,
        botRoster: (@MainActor (HermesClient) async throws -> BotRosterSnapshot)? = nil,
        findBotChat: (@MainActor (HermesClient, String) async throws -> [BotChatLookupRow])? = nil,
        createBotChat: (@MainActor (HermesClient, String) async throws -> (sessionId: String, storedSessionId: String?))? = nil,
        titleBotChat: (@MainActor (HermesClient, String, String, String) async throws -> Void)? = nil,
        makeTransport: (@MainActor () -> any HermesWebSocketTransport)? = nil
    ) {
        self.connectClient = connectClient
        self.loadCatalog = loadCatalog
        self.mintTicket = mintTicket
        self.openSession = openSession
        self.openSessionWithProfile = openSessionWithProfile
        self.persistedTranscript = persistedTranscript
        self.loadEarlierTranscriptPage = loadEarlierTranscriptPage
        self.branchSession = branchSession
        self.setSessionTitle = setSessionTitle
        self.refreshContext = refreshContext
        self.afterResumeApplied = afterResumeApplied
        self.pendingApprovals = pendingApprovals
        self.pendingApprovalsWithProfile = pendingApprovalsWithProfile
        self.respondToApproval = respondToApproval
        self.sendPrompt = sendPrompt
        self.verifyTransportHealth = verifyTransportHealth
        self.probeActiveSessions = probeActiveSessions
        self.steer = steer
        self.redirect = redirect
        self.interrupt = interrupt
        self.executeSlash = executeSlash
        self.dispatchCommand = dispatchCommand
        self.setBusyInputMode = setBusyInputMode
        self.setSessionYolo = setSessionYolo
        self.loadProfiles = loadProfiles
        self.loadBusyInputMode = loadBusyInputMode
        self.loadProfileDisplayPreferences = loadProfileDisplayPreferences
        self.loadSlashCommands = loadSlashCommands
        self.loadBotRoster = loadBotRoster
        self.compressSession = compressSession
        self.botRoster = botRoster
        self.findBotChat = findBotChat
        self.createBotChat = createBotChat
        self.titleBotChat = titleBotChat
        self.makeTransport = makeTransport
    }

    static let live = ChatResumeLifecycleOperations()
}

@MainActor
func scheduleChatResumeReconnectTask(
    after delay: TimeInterval,
    operation: @escaping @MainActor () async -> Void
) -> ChatResumeReconnectCancellation {
    let task = Task { @MainActor in
        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        await operation()
    }
    return { task.cancel() }
}

enum ChatResumeReconnectSchedulingDecision: Equatable {
    case schedule(ChatResumeSyncPurpose)
    case replace(ChatResumeSyncPurpose)
    case keepExisting
}

enum ChatResumeConversationReplacement {
    case branch
    case archive
    case delete
}

enum ChatResumeSyncExecutionOutcome: Equatable {
    case completed
    case automaticIntentInvalidated
    case superseded
}

typealias ChatResumeTransportContinuation = (
    purpose: ChatResumeSyncPurpose,
    automaticWorkToken: ChatResumeAutomaticWorkToken?,
    handedOffAutomaticIntent: Bool
)

final class ChatResumeRecoverySequence {
    private(set) var currentPurpose: ChatResumeSyncPurpose = .preserveCurrent
    private(set) var queuedReconnectPurpose: ChatResumeSyncPurpose?

    @discardableResult
    func register(_ purpose: ChatResumeSyncPurpose) -> ChatResumeSyncPurpose {
        if purpose == .automaticReturn {
            currentPurpose = .automaticReturn
        }
        return currentPurpose
    }

    func planReconnect(
        requestedPurpose: ChatResumeSyncPurpose
    ) -> ChatResumeReconnectSchedulingDecision {
        let purpose = register(requestedPurpose)
        guard let queuedReconnectPurpose else {
            self.queuedReconnectPurpose = purpose
            return .schedule(purpose)
        }
        if queuedReconnectPurpose == .preserveCurrent, purpose == .automaticReturn {
            self.queuedReconnectPurpose = .automaticReturn
            return .replace(.automaticReturn)
        }
        return .keepExisting
    }

    func takeQueuedReconnectPurpose() -> ChatResumeSyncPurpose? {
        defer { queuedReconnectPurpose = nil }
        return queuedReconnectPurpose
    }

    func clearQueuedReconnect() {
        queuedReconnectPurpose = nil
    }

    func preserveTransportAfterAutomaticIntentCancellation() {
        currentPurpose = .preserveCurrent
        if queuedReconnectPurpose != nil {
            queuedReconnectPurpose = .preserveCurrent
        }
    }

    func complete() {
        currentPurpose = .preserveCurrent
        queuedReconnectPurpose = nil
    }

    func cancel() {
        currentPurpose = .preserveCurrent
        queuedReconnectPurpose = nil
    }
}
