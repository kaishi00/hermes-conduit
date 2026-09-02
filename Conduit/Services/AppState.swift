//
//  AppState.swift
//  Conduit
//
//  The session snapshot returned by Hermes is the source of truth for a turn.
//  Stream events enrich that snapshot, but never replace it with a guess after
//  foregrounding, reconnecting, or launching the app again.
//

import SwiftUI
import Combine
import OSLog
import UIKit
import WebKit

private let sessionCatalogLog = Logger(subsystem: "com.milim.conduit", category: "SessionCatalog")
private let titleGenerationLog = Logger(subsystem: "com.milim.conduit", category: "TitleGeneration")
private let sessionYoloLog = Logger(subsystem: "com.milim.conduit", category: "SessionYolo")
/// Foreground/turn-lifecycle decisions: why a refresh chose observation vs
/// resume, and how prompt submissions were classified. Ids only — never
/// prompt text, credentials, or message content.
private let lifecycleLog = Logger(subsystem: "com.milim.conduit", category: "TurnLifecycle")

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
    /// Seam for the initial persisted-history fetch. Receives BOTH the
    /// bounded tail-page request and the legacy one-shot re-read (an echo
    /// without the `order=latest` contract) — the query argument is built by
    /// the production path builder and is not threaded through the seam, so
    /// callables distinguish the two requests by call order (bounded first,
    /// one-shot re-read second, at most once).
    var persistedTranscript: (@MainActor (String, String) async -> PersistedTranscriptFetchOutcome)?
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
    var sendPrompt: (@MainActor (HermesClient, String, String) async throws -> PromptSubmissionOutcome)?
    /// Foreground transport verification. Production calls the client's
    /// `session.list` health check; tests substitute a controllable outcome.
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

    init(
        connectClient: (@MainActor (HermesClient) async throws -> Void)? = nil,
        loadCatalog: (@MainActor (HermesClient, Bool) async throws -> [SessionSummary])? = nil,
        mintTicket: (@MainActor (String) async throws -> String)? = nil,
        openSession: (@MainActor (HermesClient, String, Bool) async throws -> SessionResumeResult)? = nil,
        persistedTranscript: (@MainActor (String, String) async -> PersistedTranscriptFetchOutcome)? = nil,
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
        loadSlashCommands: (@MainActor () async -> Void)? = nil
    ) {
        self.connectClient = connectClient
        self.loadCatalog = loadCatalog
        self.mintTicket = mintTicket
        self.openSession = openSession
        self.persistedTranscript = persistedTranscript
        self.loadEarlierTranscriptPage = loadEarlierTranscriptPage
        self.branchSession = branchSession
        self.setSessionTitle = setSessionTitle
        self.refreshContext = refreshContext
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
    }

    static let live = ChatResumeLifecycleOperations()
}

/// Raw result of fetching a session's persisted history — the dashboard
/// messages endpoint's JSON payload exactly as returned, still to be parsed
/// by AppState's production normalizer path.
enum PersistedTranscriptFetchOutcome {
    case payload([String: Any])
    /// No usable history source: no dashboard bridge, or the gateway predates
    /// the messages endpoint. The caller falls back to the resume RPC that
    /// carries the transcript itself.
    case unavailable
    /// An unrelated history failure (network, authentication, unexpected
    /// payload). It must surface to the caller instead of silently degrading
    /// the resume into a fallback.
    case failed(Error)
}

/// Parsed readiness of the persisted transcript for a resume reconciliation.
enum PersistedTranscriptOutcome {
    case hydrated(PersistedSessionTranscript)
    case unavailable
    case failed(Error)
}

struct PersistedSessionTranscript {
    let resolvedSessionId: String?
    let messages: [ChatMessage]
    /// Pagination echo of the response this transcript was parsed from.
    /// Nil (or an echo without the `order=latest` tail contract) means the
    /// backend served a one-shot full transcript.
    var page: PersistedTranscriptPagination.PageInfo?
}

struct ComposerSubmissionContext: Equatable {
    let profile: String
    let sessionID: String?
    let clientIdentity: ObjectIdentifier?
    let clientEpoch: UUID
    let viewportTransitionGeneration: UInt64
}

/// Owns the profile-scoped session catalog cache and rejects writes from a
/// load that started before a destructive cache mutation. AppState is
/// main-actor isolated, but every dashboard request can re-enter the actor
/// while it awaits WebKit, so a request must not overwrite a newer purge when
/// it resumes.
struct SessionCatalogCache {
    static let fullHistoryRefreshInterval: TimeInterval = 5 * 60

    private(set) var sessionsByKey: [String: [SessionSummary]] = [:]
    private(set) var loadedFullHistoryKeys = Set<String>()
    private(set) var fullHistoryLoadedAt: [String: Date] = [:]
    private(set) var mutationGeneration: UInt64 = 0

    func sessions(forKey key: String) -> [SessionSummary] {
        sessionsByKey[key] ?? []
    }

    func cachedSessions(forKey key: String) -> [SessionSummary]? {
        sessionsByKey[key]
    }

    /// Returns cached rows to merge unless the dashboard supplied a meaningful
    /// authoritative replacement. An empty response is not safe evidence that
    /// a populated catalog was deleted: it can also represent a transient,
    /// malformed, or profile-mismatched response.
    func cachedSessionsToMerge(
        remoteSessions: [SessionSummary],
        isAuthoritative: Bool,
        forKey key: String
    ) -> [SessionSummary] {
        if isAuthoritative && !remoteSessions.isEmpty {
            return []
        }
        return sessions(forKey: key)
    }

    func shouldLoadFullHistory(
        forKey key: String,
        forceRefresh: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !forceRefresh,
              loadedFullHistoryKeys.contains(key),
              let loadedAt = fullHistoryLoadedAt[key] else {
            return true
        }
        return now.timeIntervalSince(loadedAt) >= Self.fullHistoryRefreshInterval
    }

    /// Commits a live and cron snapshot only when no cache mutation occurred
    /// during the load that produced it.
    @discardableResult
    mutating func commit(
        liveSessions: [SessionSummary],
        liveKey: String,
        cronSessions: [SessionSummary]?,
        cronKey: String,
        historyMarkers: [String: Date],
        at generation: UInt64
    ) -> Bool {
        guard generation == mutationGeneration else { return false }
        sessionsByKey[liveKey] = liveSessions
        if let cronSessions {
            sessionsByKey[cronKey] = cronSessions
        }
        for (key, loadedAt) in historyMarkers {
            loadedFullHistoryKeys.insert(key)
            fullHistoryLoadedAt[key] = loadedAt
        }
        return true
    }

    mutating func removeAll() {
        mutationGeneration &+= 1
        sessionsByKey.removeAll()
        loadedFullHistoryKeys.removeAll()
        fullHistoryLoadedAt.removeAll()
    }

    mutating func removeValue(forKey key: String) {
        mutationGeneration &+= 1
        sessionsByKey.removeValue(forKey: key)
        loadedFullHistoryKeys.remove(key)
        fullHistoryLoadedAt.removeValue(forKey: key)
    }

    mutating func removeSession(withIDs sessionIDs: Set<String>) {
        mutationGeneration &+= 1
        for key in sessionsByKey.keys {
            sessionsByKey[key]?.removeAll { cachedSession in
                let cachedIDs = Set([cachedSession.id] + cachedSession.alternateIds)
                return !cachedIDs.isDisjoint(with: sessionIDs)
            }
        }
    }
}

@MainActor
private func scheduleChatResumeReconnectTask(
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

private enum ChatResumeSyncExecutionOutcome: Equatable {
    case completed
    case automaticIntentInvalidated
    case superseded
}

private typealias ChatResumeTransportContinuation = (
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

@MainActor
final class AppState: ObservableObject {

    // MARK: - Connection

    @Published var connection: HermesConnection?
    @Published var client: HermesClient?
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var profiles: [String] = []
    @Published private(set) var sessionFilterOrder: [SessionSource] = [.chat, .discord, .telegram, .api, .webhook, .other]
    /// Stable per-profile gateway-media resolver for settled row content.
    /// Created lazily on first read and reused while the active profile is
    /// unchanged, so ChatView's first body pass already has a resolver
    /// identity (no nil → resolver invalidation sweep over the settled
    /// transcript) and rows' Equatable gates only open on genuine profile
    /// changes. The resolver holds this AppState weakly, so caching it here
    /// creates no retain cycle.
    var gatewayMediaResolver: GatewayMediaDataURLResolver {
        if let cached = cachedGatewayMediaResolver,
           cached.profile == activeProfile {
            return cached.resolver
        }
        let resolver = GatewayMediaDataURLResolver(appState: self, profile: activeProfile)
        cachedGatewayMediaResolver = (activeProfile, resolver)
        return resolver
    }

    private var cachedGatewayMediaResolver: (profile: String, resolver: GatewayMediaDataURLResolver)?

    @Published private(set) var activeProfile: String = "default" {
        didSet { refreshActiveChatScrollSessionIdentity() }
    }
    @Published private(set) var defaultProfileName: String
    @Published private(set) var profileAvatarURLs: [String: URL]
    @Published private(set) var isProfileSwitching = false
    @Published private(set) var appIconChoice: AppIconChoice
    @Published private(set) var dashboardTicketBridge: DashboardTicketBridge?
    private var voiceAssistantObservers: [UUID: @MainActor (VoiceAssistantEvent) -> Void] = [:]

    // MARK: - Session

    @Published var sessions: [SessionSummary] = [] {
        didSet { refreshActiveChatScrollSessionIdentity() }
    }
    @Published var cronSessions: [SessionSummary] = [] {
        didSet { refreshActiveChatScrollSessionIdentity() }
    }
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var supportsProjects = false
    @Published private(set) var projectsLoading = false
    @Published private(set) var archivedSessions: [SessionSummary] = []
    @Published private(set) var pinnedSessionIDs: [String] = []
    @Published private(set) var sessionMutationID: String?
    @Published private(set) var isRefreshingSessionCatalog = false
    @Published var activeSessionId: String? {
        didSet { refreshActiveChatScrollSessionIdentity() }
    }
    @Published private(set) var activeChatScrollSessionIdentity = ChatScrollSessionIdentity.none
    @Published private(set) var chatTranscriptRevision: UInt64 = 0
    @Published var messages: [ChatMessage] = [] {
        didSet {
            chatTranscriptRevision &+= 1
            advanceChatViewportExpectedTranscriptRevisionIfNeeded()
        }
    }
    @Published private(set) var activeSessionTitle = "New conversation"
    /// Persisted-history pagination window of the active conversation.
    /// Drives the "Load earlier messages" affordance; nil means the current
    /// transcript is either a legacy one-shot hydration or not persisted-
    /// history-backed at all, and no older pages exist to fetch.
    @Published private(set) var persistedTranscriptWindow: PersistedTranscriptWindowState?
    @Published private(set) var isChatRefreshing = false
    @Published private(set) var chatResumeBehavior: ChatResumeBehavior = .continueWhereLeftOff
    @Published private(set) var chatReturnSurface: ChatReturnSurface = .conversation
    /// One-shot request for MainView to present the sessions drawer as the
    /// preferred return surface. MainView consumes the latest value once per
    /// increment; the request is only issued for qualifying returns (cold
    /// launch or a real background → active transition) when the preference
    /// is `.sessions` and no explicit navigation or modal owns the surface.
    @Published private(set) var preferredReturnSurfaceRequest: UInt64 = 0
    @Published private(set) var chatResumeRestorationRequest: ChatResumeRestorationRequest?
    @Published private(set) var chatViewportTransitionGeneration: UInt64 = 0
    /// Keeps the current transcript visible while a notification destination is
    /// being prepared, so the chat never appears to jump to an empty canvas.
    @Published private(set) var isOpeningNotificationSession = false
    @Published private(set) var isBranchingChat = false
    @Published private(set) var turnState: TurnState = .idle
    /// Whether `turnState` may have missed server-side turn edges. Set at
    /// lifecycle boundaries where the socket can die or the gateway can change
    /// state unobserved (scene dips, reconnects, ambiguous submissions);
    /// cleared only when an authoritative source (the `session.active_list`
    /// probe, a resume snapshot, or a typed prompt outcome) re-confirms the
    /// state. A stale idle state must not route the next input as a new-turn
    /// `prompt.submit` — Hermes would apply its busy policy to it and the
    /// message would silently join a turn the user never saw start.
    private(set) var turnStateIsStale = false
    @Published private(set) var busyInputMode: BusyInputMode = .steer
    @Published private(set) var displayPreferences = ProfileDisplayPreferences()
    @Published var streamingText = ""
    /// Live, frequently-changing reasoning projection. Streaming reasoning
    /// renders from here at display cadence WITHOUT mutating the settled
    /// `messages` array — per-publish transcript mutation (O(message count)
    /// index scan + copy-on-write copy + revision bump + scroll-target cache
    /// walk) is what made deep agent sessions burn CPU and battery. The card
    /// commits into `messages` exactly once per segment boundary via
    /// `settleReasoningSegmentIntoTranscript()`.
    @Published private(set) var liveReasoningSegment: LiveReasoningSegment?
    /// An explicit user-send request lets ChatView scroll after SwiftUI has
    /// inserted the outgoing bubble, even if the user previously browsed up.
    @Published private(set) var chatScrollRequest = 0
    @Published private(set) var chatScrollToTopRequest = 0

    /// Profile changes and network refreshes are asynchronous. Keep a final
    /// ownership boundary at the published catalog so a stale row can never
    /// render under another workspace while a switch is in flight.
    var activeProfileSessions: [SessionSummary] {
        sessions.filter { sessionBelongsToProfile($0, profile: activeProfile) }
    }

    var activeProfileCronSessions: [SessionSummary] {
        cronSessions.filter { sessionBelongsToProfile($0, profile: activeProfile) }
    }

    /// Kept as a computed compatibility surface for views that only need the
    /// currently-running flag. New code should use `turnState` for actions.
    var isBusy: Bool { turnState.isRunning }
    var composerIsEnabled: Bool { turnState.acceptsComposerActions }

    func composerAction(hasText: Bool, hasAttachments: Bool) -> ComposerAction {
        turnState.composerAction(
            hasText: hasText,
            hasAttachments: hasAttachments,
            busyInputMode: busyInputMode
        )
    }

    var composerPlaceholder: String {
        switch turnState {
        case .running:
            return "\(busyInputMode.title) \(profileDisplayName(activeProfile))…"
        case .synchronizing, .reconnecting:
            return "Checking agent activity…"
        case .unsupportedGateway:
            return "Update Hermes to use chat controls"
        case .idle:
            return "Message \(profileDisplayName(activeProfile))…"
        }
    }

    // MARK: - Runtime

    @Published var runtime = RuntimeState()
    @Published var activeAgents = 0
    @Published private(set) var delegateAgents: [DelegateAgentActivity] = []
    @Published private(set) var workspaceRoot = ""
    @Published private(set) var workspaceEntries: [String: [WorkspaceEntry]] = [:]
    @Published private(set) var expandedWorkspacePaths: Set<String> = []
    @Published private(set) var workspaceLoadingPath: String?
    @Published private(set) var workspaceError: String?
    @Published private(set) var workspacePreview: WorkspaceFilePreview?
    @Published private(set) var workspaceSelectedFile: WorkspaceEntry?
    @Published private(set) var workspaceFileError: String?
    @Published private(set) var workspaceFileLoading = false
    @Published private(set) var gatewayDiagnostics: GatewayDiagnostics?
    @Published private(set) var gatewayDiagnosticsLoading = false
    @Published private(set) var modelVisibility = ModelVisibility()

    // MARK: - UI state

    @Published var themePreference: ThemePreference {
        didSet {
            defaults.set(themePreference.rawValue, forKey: themePreferenceKey)
        }
    }
    @Published var showSidebar = false {
        didSet {
            // Avoid driving the entire presentation hierarchy at streaming
            // cadence while the drawer is animating. The live buffer remains
            // authoritative and is republished as soon as the drawer closes.
            if showSidebar {
                streamingPublishTask?.cancel()
                streamingPublishTask = nil
                hasScheduledStreamingPublish = false
                reasoningPublishTask?.cancel()
                reasoningPublishTask = nil
                hasScheduledReasoningPublish = false
            } else {
                if !streamingBuffer.isEmpty {
                    lastStreamingPublishBurst = max(
                        streamingBuffer.count - streamingText.count,
                        0
                    )
                    lastStreamingPublishDate = Date()
                    streamingText = streamingBuffer
                }
                flushReasoningPublish()
            }
        }
    }
    @Published var showModelPicker = false
    @Published var showContextSheet = false
    @Published var showWorkspaceSheet = false
    @Published var showGatewaySheet = false
    @Published var showAgentsSheet = false
    @Published var showVoiceSheet = false
    /// Mirrors MainView's Settings sheet item so return-surface decisions can
    /// tell whether Settings owns the surface across a background/foreground cycle.
    @Published var isSettingsSheetPresented = false
    @Published var errorMessage: String?
    @Published var showLogin = true
    @Published private(set) var composerPrefillText = ""
    @Published private(set) var composerPrefillToken = UUID()

    // MARK: - Capabilities

    @Published var slashCommands: [SlashCommand] = AppState.builtInSlashCommands
    @Published var skills: [CapabilitySkill] = []
    @Published var toolsets: [CapabilityToolset] = []
    /// Profile that owns the currently displayed skills/toolsets. Rows are
    /// only presentable while this equals the active profile.
    @Published private(set) var capabilitiesProfile: String?
    /// Monotonic request token for capability loads; older requests can never
    /// commit over newer ones (protects the A -> B -> A race).
    private var capabilityLoadGeneration: UInt64 = 0
    @Published var mcpServers: [CapabilityMcpServer] = []
    @Published private(set) var voiceCapabilitySnapshot = VoiceCapabilitySnapshot.unavailable
    @Published private(set) var isVoiceEnabled = false
    @Published private(set) var voiceTranscriptionMode: VoiceTranscriptionMode = .hermes
    @Published private(set) var appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()

    private var voiceAssistantObserverID: UUID?
    lazy var voiceConversationController = VoiceConversationController(
        submit: { [weak self] transcript in
            guard let self else { return false }
            return await self.submitVoiceTranscript(transcript)
        },
        interrupt: { [weak self] in
            await self?.interruptForVoice()
        }
    )
    /// Manual per-message read aloud for completed assistant responses.
    /// TTS-only: independent of the voice conversation and of STT.
    lazy var messageReadAloudController = MessageReadAloudController(
        reportError: { [weak self] message in
            self?.errorMessage = message
        }
    )
    /// The bridge instance the read aloud gateway was built against. The
    /// gateway captures its bridge at init, so a gateway outliving its bridge
    /// (disconnect, re-login, bridge rotation) is dead and must be rebuilt
    /// rather than kept.
    private var readAloudGatewayBridge: DashboardTicketBridge?

    // MARK: - Cron

    @Published var cronJobs: [CronJob] = []
    @Published var cronRuns: [CronRun] = []
    @Published private(set) var cronJobsLoading = false
    @Published private(set) var cronJobActionID: String?

    // MARK: - Lifecycle coordination

    private struct Reconciliation {
        let token: UUID
        let requestedSessionId: String
        var automaticSyncOperationID: UUID?
        var resolvedSessionId: String?
        var acceptedSessionIDs: Set<String>
        let acceptsAnySession: Bool
        let streamTextAtBoundary: String?
        let streamSessionIDAtBoundary: String?
        var bufferedEvents: [StreamEvent] = []

        init(
            token: UUID,
            requestedSessionId: String,
            automaticSyncOperationID: UUID? = nil,
            acceptedSessionIDs: Set<String> = [],
            acceptsAnySession: Bool = false,
            streamTextAtBoundary: String? = nil,
            streamSessionIDAtBoundary: String? = nil,
            bufferedEvents: [StreamEvent] = []
        ) {
            self.token = token
            self.requestedSessionId = requestedSessionId
            self.automaticSyncOperationID = automaticSyncOperationID
            self.acceptedSessionIDs = acceptedSessionIDs
            self.acceptsAnySession = acceptsAnySession
            self.streamTextAtBoundary = streamTextAtBoundary
            self.streamSessionIDAtBoundary = streamSessionIDAtBoundary
            self.bufferedEvents = bufferedEvents
        }

        func accepts(_ sessionId: String) -> Bool {
            guard !sessionId.isEmpty else { return false }
            if acceptsAnySession { return true }
            return acceptedSessionIDs.contains(sessionId)
                || sessionId == requestedSessionId
                || sessionId == resolvedSessionId
        }
    }

    private struct PendingStreamingCompletion {
        let sessionId: String
        let messageId: String?
        let finalContent: String
        let reasoning: String?
    }

    /// One live reasoning segment as projected to the UI: the identity and
    /// mount timestamp are fixed for the segment's lifetime, only `content`
    /// advances at display cadence. Rendering treats it exactly like a
    /// settled `.reasoning` row (same ThinkingCard presentation).
    struct LiveReasoningSegment: Equatable {
        let id: String
        let timestamp: String
        var content: String
    }
    private var reconciliationToken = UUID()
    private var reconciliation: Reconciliation?
    private var activeClientEpoch = UUID()
    private var activeAssistantMessageId: String?
    private var activeReasoningMessageId: String?
    private var receivedReasoningForCurrentTurn = false
    /// Authoritative merged reasoning for the live thinking card. Raw deltas
    /// merge into this buffer immediately; the published transcript is only
    /// republished at a coalesced cadence so an expanded ThinkingCard cannot
    /// monopolize main-actor layout work during a live reasoning stream.
    private var reasoningBuffer = ""
    private var reasoningPublishTask: Task<Void, Never>?
    private var hasScheduledReasoningPublish = false
    private var streamingBuffer = ""
    /// Gateway deltas can arrive much faster than SwiftUI can lay out a chat
    /// transcript. Keep the authoritative buffer intact, but publish at a
    /// display-friendly cadence so an active response cannot monopolize the
    /// main actor (and make sheets or session rows feel untappable).
    private var streamingPublishTask: Task<Void, Never>?
    /// A fast gateway can emit its final delta and completion inside one
    /// publish interval. Keep that final projection alive briefly so the UI's
    /// character reveal can drain instead of jumping straight to the result.
    private var streamingCompletionTask: Task<Void, Never>?
    private var pendingStreamingCompletion: PendingStreamingCompletion?
    private var hasScheduledStreamingPublish = false
    private var lastStreamingPublishBurst = 0
    private var lastStreamingPublishDate: Date?
    private var responseHapticConclusionTask: Task<Void, Never>?
    private var responseHaptics = ResponseHapticState()
    private var scenePhaseTask: Task<Void, Never>?
    private var scenePhaseAttemptID: UUID?
    /// Armed only by a real .background phase. Ordinary inactive → active
    /// transitions (Control Center, incoming-call banner) must not be treated
    /// as reopening the app, so they never arm the preferred return surface.
    private var hasEnteredBackgroundScenePhase = false
    private var hasRequestedColdLaunchReturnSurface = false
    /// Presentation watermark for the preferred return surface: how far
    /// through `preferredReturnSurfaceRequest` MainView has consumed, kept
    /// here (not in view state) so it survives MainView teardown on sign-out.
    private var consumedReturnSurfaceRequest: UInt64 = 0
    private var deferredReturnSurfaceRequest: UInt64?
    private var explicitSessionOpenTask: Task<Bool, Never>?
    private var explicitSessionOpenRequestID: UUID?
    private var activeAutomaticChatResumeWork: ChatResumeAutomaticWorkToken?
    private var chatViewportSnapshotProvider: (
        id: UUID,
        capture: @MainActor () -> ChatRenderedViewportSnapshot?
    )?
    private struct ChatViewportTransition {
        let generation: UInt64
        var hasReplacement = false
        var expectedSessionKey: ChatScrollSessionKey?
        var expectedTranscriptRevision: UInt64?
    }

    private struct AutomaticSyncOperation {
        let id: UUID
        let previousTurnState: TurnState
    }

    private struct AutomaticReconnectOperation {
        let id: UUID
        let previousIsConnecting: Bool
        let previousTurnState: TurnState
    }

    private var chatViewportTransition: ChatViewportTransition?
    private var activeNotificationOpenAttemptID: UUID?
    private var activeAutomaticSyncOperation: AutomaticSyncOperation?
    private var activeAutomaticReconnectOperation: AutomaticReconnectOperation?
    private var reconnectTask: ChatResumeReconnectCancellation?
    private let reconnectScheduler: ChatResumeReconnectScheduler
    private let reconnectExecutor: ChatResumeReconnectExecutor?
    private let chatResumeLifecycleOperations: ChatResumeLifecycleOperations
    /// Coalesces presentation-cache flushes during streaming so we
    /// don't serialize and write UserDefaults on every WebSocket frame.
    private var presentationCacheFlushTask: Task<Void, Never>?
    /// Monotonic fence for deferred presentation-cache writes. Bumped when
    /// the active profile identity changes so a coalesced flush scheduled
    /// under one profile can never land in another profile's namespace.
    private var presentationCacheProfileEpoch = 0
    /// Injectable stand-in for the debounce sleep. Defaults to wall-clock
    /// `Task.sleep`; deterministic tests park a pending flush mid-flight
    /// through this seam instead of racing its timing.
    private let presentationCacheDebounceSuspension: @Sendable (
        Duration
    ) async throws -> Void
    /// A resume without explicit active-turn confirmation can restore a
    /// decision card from local presentation data. Keep the card in memory for
    /// this AppState so another foreground resume can still show it, but strip
    /// it from cache writes until Hermes confirms the turn. Scope the guard to
    /// the session/profile that produced it so a session switch cannot affect
    /// another session's presentation.
    private struct PendingDecisionRestorationGuard {
        let profile: String
        let sessionID: String
        let pendingDecisionKeys: Set<String>
        let restoredAt: Date
        let messages: [ChatMessage]
    }

    private struct SessionYoloWriteBaseline {
        let revisions: [ChatScrollSessionKey: UInt64]
    }

    private var restoredPendingDecisionCardsAwaitingConfirmation: PendingDecisionRestorationGuard?
    /// Timestamp of the last successful coalesced cache flush; used to
    /// enforce a maximum 5-second interval even during continuous streaming.
    private var lastPresentationCacheFlushDate: Date?
    /// Hermes currently starts its automatic title task against the launch
    /// profile's database. Keep a small, one-per-session recovery task for a
    /// secondary profile, then stand down as soon as Hermes has written one.
    private let sessionTitleRecoveryTracker = SessionTitleRecoveryTracker()
    private let sessionRenameOperationsOverride: SessionRenameOperation.Operations?
    private let sessionCatalogLoaderOverride: ((Bool) async throws -> [SessionSummary])?
    /// Test seam mirroring `sessionCatalogLoader`: overrides the dashboard
    /// `/api/profiles` fetch inside `loadProfiles()` so success, failure, and
    /// late-response ordering can be modeled without a live WebKit bridge.
    private let profileDiscoveryLoaderOverride: (@MainActor () async throws -> [String: Any])?
    private var reconnectAttempts = 0
    /// Whether the UI scene is active. Backgrounded scene updates must
    /// complete within ~10s of wall clock before the watchdog kills the app
    /// (0x8BADF00D), so reconnect work is deferred while this is false.
    /// Deliberately true at init: launches head toward active, and blocking
    /// the cold-start restore on the first scene-phase event would regress
    /// startup. `.inactive` is treated like `.background` on purpose — it
    /// immediately precedes backgrounding on home-press, and a socket that
    /// dies under a system overlay is recovered by the `.active` scene task.
    private var isSceneActive = true
    private var connectedAt: Date?
    private var sessionCatalogCache = SessionCatalogCache()
    private var projectsRequestGeneration = 0
    private let sessionPresentationCache: SessionPresentationCache
    private let sessionYoloStore: SessionYoloStore
    private var sessionYoloWriteRevision: UInt64 = 0
    private var sessionYoloWriteRevisions: [ChatScrollSessionKey: UInt64] = [:]
    /// Sessions whose user-initiated YOLO write is awaiting its RPC, tracked
    /// by reference count so overlapping writes for the same session each own
    /// an independent registration. The override store is only updated after
    /// the gateway accepts, so readers (notably the resume re-assert) must not
    /// treat the store as current while any write is in flight.
    private var inFlightSessionYoloWriteCounts: [ChatScrollSessionKey: Int] = [:]
    /// The last session-level `yolo` the gateway itself reported, distinct
    /// from `runtime.yolo`, which also folds in the profile floor and the
    /// stored override.
    private var lastReportedSessionYolo: Bool?

    /// The dashboard's persisted transcript is richer than `session.resume`:
    /// it retains database timestamps, complete tool-call inputs, and other
    /// presentation fields. The resume RPC remains authoritative for live turn
    /// state and any in-flight projection.
    private struct DashboardSessionCatalog {
        let sessions: [SessionSummary]
        /// True only when the dashboard returned a meaningful, terminal
        /// catalog. Empty or unusable responses must remain mergeable with
        /// the previous snapshot instead of evicting it.
        let isAuthoritative: Bool
    }

    private struct TitleGenerationSettings {
        let enabled: Bool
        let language: String?
    }

    private static func localTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// Hermes can omit UI-only fields from persisted history. Retain a bounded
    /// local record so a reload does not drop a timestamp or tool preview.
    private func cacheMessagePresentation(for sessionIDs: [String] = []) {
        let ids = sessionIDs + [
            activeSessionId,
            reconciliation?.requestedSessionId,
            reconciliation?.resolvedSessionId
        ].compactMap { $0 }
        let restorationKeys: Set<String>? = {
            guard let restorationGuard = restoredPendingDecisionCardsAwaitingConfirmation,
                  restorationGuard.profile == activeProfile,
                  activeSessionId == restorationGuard.sessionID else {
                return nil
            }
            return restorationGuard.pendingDecisionKeys
        }()
        let cacheableMessages = restorationKeys.map {
            SessionPresentationCache.removingPendingDecisionPresentation(
                from: messages,
                matching: $0
            )
        } ?? messages
        let pendingDecisionKeys = SessionPresentationCache.pendingDecisionKeys(in: cacheableMessages)
        // Gateway-provided cards do not create a restoration guard, so keep
        // their bounded expiry marker across ordinary cache flushes as well.
        // Push-recorded cards (recordPendingDecision) live only in the store —
        // the in-memory transcript has never seen them — so union in the
        // store's pending keys or the flush would drop the card before the
        // notification-open resume merge could restore it.
        let storedPendingDecisionKeys = sessionPresentationCache.storedPendingDecisionKeys(
            profile: activeProfile,
            sessionIDs: ids
        )
        let pendingDecisionKeysToPreserve = restorationKeys
            ?? pendingDecisionKeys.union(storedPendingDecisionKeys)
        let preservePendingDecisionCards = restorationKeys == nil
            || !pendingDecisionKeys.isEmpty
            || !storedPendingDecisionKeys.isEmpty
        sessionPresentationCache.save(
            cacheableMessages,
            profile: activeProfile,
            sessionIDs: ids,
            preservePendingDecisionCards: preservePendingDecisionCards,
            unconfirmedPendingDecisionKeys: pendingDecisionKeysToPreserve
        )
    }

    /// Coalesces presentation-cache writes during streaming. Instead of
    /// serializing the entire message array to UserDefaults on every
    /// WebSocket frame (30+ times/sec), batch flushes at most once every
    /// 2 seconds (debounce), with a hard 5-second ceiling (max interval)
    /// so continuous streaming can never postpone a flush indefinitely.
    private func schedulePresentationCacheFlush(for sessionId: String) {
        presentationCacheFlushTask?.cancel()
        // Capture the profile identity this deferred write belongs to. The
        // task only keeps the session ID immutable; everything else it reads
        // (messages, reconciliation IDs, restoration guards) is live state.
        let scheduledProfile = activeProfile
        let scheduledEpoch = presentationCacheProfileEpoch
        let suspendForDebounce = presentationCacheDebounceSuspension
        let now = Date()
        let sinceLastFlush = lastPresentationCacheFlushDate
            .map { now.timeIntervalSince($0) }
            ?? .infinity
        // If 5s already elapsed since the last successful write, flush
        // immediately rather than scheduling another debounce.
        let delay: Duration = sinceLastFlush >= 5 ? .zero : .seconds(2)
        presentationCacheFlushTask = Task { [weak self] in
            do {
                try await suspendForDebounce(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            // Stale-execution fence: if the app switched profiles while this
            // flush was parked, the captured session ID no longer describes
            // the live transcript, and writing through the now-active cache
            // namespace would cross-contaminate profiles. switchProfile also
            // flushes and cancels before switching; this guard keeps the
            // operation safe on its own so no caller can forget it.
            guard self.activeProfile == scheduledProfile,
                  self.presentationCacheProfileEpoch == scheduledEpoch else {
                presentationCacheFlushTask = nil
                return
            }
            self.cacheMessagePresentation(for: [sessionId])
            self.lastPresentationCacheFlushDate = Date()
            self.presentationCacheFlushTask = nil
        }
    }

    /// Flushes any pending presentation-cache write immediately (used on
    /// session switch, completion, and scene-phase change).
    private func flushPendingPresentationCache() {
        presentationCacheFlushTask?.cancel()
        presentationCacheFlushTask = nil
        lastPresentationCacheFlushDate = Date()
        cacheMessagePresentation()
    }

    /// Assigns the active profile and fences deferred presentation-cache
    /// work: any coalesced flush scheduled under another profile becomes
    /// stale the moment the identity changes. Call this instead of assigning
    /// `activeProfile` directly so no mutation site can skip the fence.
    ///
    /// Deliberately NOT flushing here: on rollbacks (failed switches) the
    /// still-active identity does not own the restored in-memory content,
    /// so the synchronous outgoing-transcript flush belongs at each forward
    /// transition site (`switchProfile`, `connect(with:profile:)`) where
    /// that ownership is guaranteed. Both fence conditions in
    /// `schedulePresentationCacheFlush` are intentionally redundant — string
    /// equality is the readable guard, the wrapping `&+= 1` (overflows only
    /// after ~9.2×10^18 switches — unreachable) catches A→B→A round-trips —
    /// do not simplify either away.
    private func setActiveProfile(_ newValue: String) {
        guard newValue != activeProfile else { return }
        activeProfile = newValue
        presentationCacheProfileEpoch &+= 1
    }

#if DEBUG
    /// Deterministic-test access to the pending coalesced flush. Awaiting its
    /// value settles every deferred-write decision (cancelled, fenced, or
    /// completed) without wall-clock timing. Test-only plumbing; compiled out
    /// of release builds.
    var presentationCacheFlushOperationForTesting: Task<Void, Never>? {
        presentationCacheFlushTask
    }
#endif

    // MARK: - Persistence

    private let defaults: UserDefaults
    /// Kept outside ChatResumeStore on purpose: the return surface is a
    /// presentation preference, not part of the resume schema.
    static let chatReturnSurfaceKey = "conduit.chatReturnSurface.v1"
    private let activeSessionTitlesByProfileKey = "conduit.activeSessionTitlesByProfile.v1"
    private let pinnedSessionIDsByProfileKey = "conduit.pinnedSessionIdsByProfile.v1"
    private let activeProfileKey = "conduit.activeProfile"
    private let themePreferenceKey = "conduit.themePreference"
    private let dashboardURLKey = "conduit.dashboardURL"
    private let modelVisibilityKey = "conduit.modelVisibility.v1"
    private let profileOrderKey = "conduit.profileOrder.v1"
    private let sessionFilterOrderKey = "conduit.sessionFilterOrder.v1"
    private let reviewSummaryCacheKey = "conduit.reviewSummaryCache.v1"
    private let knownProfilesKey = "conduit.knownProfiles.v1"
    private let chatResumeServerIdentityKey = "conduit.chatResumeServerIdentity.v1"
    private var activeSessionTitlesByProfile: [String: String] = [:]
    private var pinnedSessionIDsByProfile: [String: [String]] = [:]
    private let chatResumeCoordinator: ChatResumeCoordinator
    private let recoverySequence: ChatResumeRecoverySequence
    private let clearSessionPresentationCache: () -> Void
    private let initialChatResumeServerIdentity: String?

    private func mergeCachedReviews(into history: [ChatMessage], sessionId: String) -> [ChatMessage] {
        let records = cachedReviews().filter { $0.profile == activeProfile && $0.sessionId == sessionId }
        guard !records.isEmpty else { return history }
        var merged = history
        for record in records where !merged.contains(where: { $0.review == record.activity }) {
            merged.append(ChatMessage(
                id: record.id,
                role: .system,
                content: record.activity.summary,
                timestamp: record.timestamp,
                review: record.activity
            ))
        }
        return merged.sorted { left, right in
            let leftDate = ISO8601DateFormatter().date(from: left.timestamp) ?? .distantPast
            let rightDate = ISO8601DateFormatter().date(from: right.timestamp) ?? .distantPast
            return leftDate < rightDate
        }
    }

    private func persistReview(_ record: ReviewSummaryRecord) {
        var records = cachedReviews()
        records.removeAll { $0.profile == record.profile && $0.sessionId == record.sessionId && $0.activity == record.activity }
        records.append(record)
        // Keep this small, device-local resilience cache. Hermes remains the
        // source of truth for normal messages; this only preserves summaries
        // that are emitted exclusively as stream events.
        records = Array(records.suffix(200))
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: reviewSummaryCacheKey)
        }
    }

    private func cachedReviews() -> [ReviewSummaryRecord] {
        guard let data = defaults.data(forKey: reviewSummaryCacheKey) else { return [] }
        return (try? JSONDecoder().decode([ReviewSummaryRecord].self, from: data)) ?? []
    }

    init(
        defaults: UserDefaults = .standard,
        chatResumeCoordinator: ChatResumeCoordinator? = nil,
        recoverySequence: ChatResumeRecoverySequence = ChatResumeRecoverySequence(),
        loadSavedConnection shouldLoadSavedConnection: Bool = true,
        clearSessionPresentationCache: @escaping () -> Void = {
            SessionPresentationCache.shared.clear()
        },
        sessionRenameOperations: SessionRenameOperation.Operations? = nil,
        sessionCatalogLoader: ((Bool) async throws -> [SessionSummary])? = nil,
        profileDiscoveryLoader: (@MainActor () async throws -> [String: Any])? = nil,
        reconnectScheduler: ChatResumeReconnectScheduler? = nil,
        reconnectExecutor: ChatResumeReconnectExecutor? = nil,
        chatResumeLifecycleOperations: ChatResumeLifecycleOperations = .live,
        sessionPresentationCache: SessionPresentationCache = .shared,
        sessionYoloStore: SessionYoloStore? = nil,
        presentationCacheDebounceSuspension: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.presentationCacheDebounceSuspension =
            presentationCacheDebounceSuspension
            ?? { duration in try await Task.sleep(for: duration) }
        self.defaults = defaults
        self.sessionPresentationCache = sessionPresentationCache
        self.sessionYoloStore = sessionYoloStore ?? SessionYoloStore(defaults: defaults)
        self.chatResumeCoordinator = chatResumeCoordinator
            ?? ChatResumeCoordinator(store: ChatResumeStore(defaults: defaults))
        self.recoverySequence = recoverySequence
        self.clearSessionPresentationCache = clearSessionPresentationCache
        sessionRenameOperationsOverride = sessionRenameOperations
        sessionCatalogLoaderOverride = sessionCatalogLoader
        profileDiscoveryLoaderOverride = profileDiscoveryLoader
        self.reconnectScheduler = reconnectScheduler ?? scheduleChatResumeReconnectTask
        self.reconnectExecutor = reconnectExecutor
        self.chatResumeLifecycleOperations = chatResumeLifecycleOperations
        self.initialChatResumeServerIdentity = defaults
            .string(forKey: "conduit.chatResumeServerIdentity.v1")
            .flatMap(Self.normalizedChatResumeServerIdentity)
            ?? defaults.string(forKey: "conduit.dashboardURL")
                .flatMap(Self.normalizedChatResumeServerIdentity)
        chatResumeBehavior = self.chatResumeCoordinator.behavior
        chatReturnSurface = defaults.string(forKey: Self.chatReturnSurfaceKey)
            .flatMap(ChatReturnSurface.init(rawValue:)) ?? .conversation
        defaultProfileName = ProfileAppearanceStore.loadDefaultName()
        profileAvatarURLs = ProfileAppearanceStore.loadAvatarURLs()
        appIconChoice = UIApplication.shared.alternateIconName == AppIconChoice.light.alternateIconName ? .light : .dark
        themePreference = ThemePreference(
            rawValue: defaults.string(forKey: themePreferenceKey) ?? ""
        ) ?? .dark
        if let data = defaults.data(forKey: modelVisibilityKey),
           let stored = try? JSONDecoder().decode(ModelVisibility.self, from: data) {
            modelVisibility = stored
        }
        if let savedFilterOrder = defaults.stringArray(forKey: sessionFilterOrderKey) {
            sessionFilterOrder = normalizedSessionFilterOrder(savedFilterOrder)
        }
        activeProfile = defaults.string(forKey: activeProfileKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
        if activeProfile.isEmpty { activeProfile = "default" }
        activeSessionTitlesByProfile = defaults.dictionary(forKey: activeSessionTitlesByProfileKey) as? [String: String] ?? [:]
        if let data = defaults.data(forKey: pinnedSessionIDsByProfileKey),
           let stored = try? JSONDecoder().decode([String: [String]].self, from: data) {
            pinnedSessionIDsByProfile = stored
        }
        // Hydrate the visible profile list from the persisted known-profile
        // cache before any discovery runs. A cold launch must not present an
        // effectively empty list — starting from `[]` is what let a single
        // failed /api/profiles refresh collapse the picker to one entry and
        // persist that degraded list over the complete cache. The union also
        // heals a cache a pre-fix build already degraded: `default` and the
        // remembered active profile are re-added on first launch.
        profiles = orderedProfiles(
            (defaults.stringArray(forKey: knownProfilesKey) ?? []) + [activeProfile, "default"]
        )
        restoreActiveSessionState(for: activeProfile)
        restorePinnedSessions(for: activeProfile)
        if shouldLoadSavedConnection {
            loadSavedConnection()
        }
    }

    func restoreActiveSessionState(for profile: String) {
        clearPendingDecisionRestorationGuard()
        activeSessionId = chatResumeCoordinator.lastSessionID(for: profile)
        activeSessionTitle = activeSessionTitlesByProfile[profile] ?? "New conversation"
    }

    private func restorePinnedSessions(for profile: String) {
        pinnedSessionIDs = pinnedSessionIDsByProfile[profile] ?? []
    }

    private func persistPinnedSessions() {
        guard let data = try? JSONEncoder().encode(pinnedSessionIDsByProfile) else { return }
        defaults.set(data, forKey: pinnedSessionIDsByProfileKey)
    }

    private func pinID(for session: SessionSummary) -> String {
        if let rootID = session.lineageRootId?.trimmingCharacters(in: .whitespacesAndNewlines), !rootID.isEmpty {
            return rootID
        }
        return session.id
    }

    func isSessionPinned(_ session: SessionSummary) -> Bool {
        let ids = Set([pinID(for: session), session.id] + session.alternateIds)
        return pinnedSessionIDs.contains { ids.contains($0) }
    }

    func toggleSessionPinned(_ session: SessionSummary) {
        guard sessionBelongsToProfile(session, profile: activeProfile) else { return }
        let pinID = pinID(for: session)
        if isSessionPinned(session) {
            let ids = Set([pinID, session.id] + session.alternateIds)
            pinnedSessionIDs.removeAll { ids.contains($0) }
        } else {
            pinnedSessionIDs.removeAll { $0 == pinID }
            pinnedSessionIDs.append(pinID)
        }
        pinnedSessionIDsByProfile[activeProfile] = pinnedSessionIDs
        persistPinnedSessions()
    }

    private func removePinnedState(for session: SessionSummary) {
        let ids = Set([pinID(for: session), session.id] + session.alternateIds)
        pinnedSessionIDs.removeAll { ids.contains($0) }
        pinnedSessionIDsByProfile[activeProfile] = pinnedSessionIDs
        persistPinnedSessions()
    }

    private func pendingDecisionRestorationMessages(for sessionID: String) -> [ChatMessage] {
        guard let restorationGuard = restoredPendingDecisionCardsAwaitingConfirmation,
              restorationGuard.profile == activeProfile,
              restorationGuard.sessionID == sessionID else {
            return []
        }
        guard !sessionPresentationCache.isUnconfirmedPendingDecisionExpired(
            since: restorationGuard.restoredAt
        ) else {
            clearPendingDecisionRestorationGuard()
            return []
        }
        return restorationGuard.messages
    }

    private func clearPendingDecisionRestorationGuard() {
        restoredPendingDecisionCardsAwaitingConfirmation = nil
    }

    private func setActiveSessionState(id: String?, title: String? = nil) {
        if activeSessionId != id {
            clearPendingDecisionRestorationGuard()
            resetResponseHapticTurn()
        }
        activeSessionId = id
        if let persistedID = ChatSessionPersistenceIdentity.canonicalID(
            for: id,
            identity: activeChatScrollSessionIdentity,
            catalog: sessions + cronSessions,
            activeProfile: activeProfile
        ) {
            chatResumeCoordinator.rememberSessionID(persistedID, for: activeProfile)
        } else {
            chatResumeCoordinator.rememberSessionID(nil, for: activeProfile)
        }
        if let title {
            activeSessionTitle = title
            activeSessionTitlesByProfile[activeProfile] = title
        }
        persistActiveSessionTitles()
    }

    private func setActiveSessionTitle(_ title: String) {
        activeSessionTitle = title
        activeSessionTitlesByProfile[activeProfile] = title
        persistActiveSessionTitles()
    }

    private func persistActiveSessionTitles() {
        defaults.set(activeSessionTitlesByProfile, forKey: activeSessionTitlesByProfileKey)
    }

    private func cancelScheduledReconnect() {
        reconnectTask?()
        reconnectTask = nil
        recoverySequence.clearQueuedReconnect()
    }

    func setChatResumeBehavior(_ behavior: ChatResumeBehavior) {
        chatResumeCoordinator.setBehavior(behavior)
        cancelOwnedAutomaticSyncOperation()
        activeAutomaticChatResumeWork = nil
        recoverySequence.preserveTransportAfterAutomaticIntentCancellation()
        chatResumeBehavior = chatResumeCoordinator.behavior
        chatResumeRestorationRequest = nil
    }

    /// True when any presented sheet owns the surface other than the sessions
    /// drawer itself. Explicit navigation and existing modals take precedence
    /// over the preferred return surface.
    var isModalSheetPresented: Bool {
        showModelPicker || showContextSheet || showWorkspaceSheet || showGatewaySheet
            || showAgentsSheet || showVoiceSheet || isSettingsSheetPresented
    }

    /// True when an explicit destination exists but has not been routed yet
    /// (a notification tap or voice intent recorded before the app was
    /// connected). Routing services own this fact; only the read lives here,
    /// mirroring how syncSession already defers to a pending notification
    /// target. Explicit navigation outranks the preferred return surface from
    /// the moment the destination exists, not just once routing starts.
    var hasPendingExplicitNavigation: Bool {
        PushNotificationService.shared.pendingTarget != nil
            || PendingVoiceIntentStore.shared.hasPendingIntent
    }

    /// Persisted separately from the resume store: this only changes which
    /// surface is presented first on a qualifying return, and deliberately
    /// issues no presentation request — the next qualifying return picks it up.
    func setChatReturnSurface(_ surface: ChatReturnSurface) {
        guard surface != chatReturnSurface else { return }
        chatReturnSurface = surface
        defaults.set(surface.rawValue, forKey: Self.chatReturnSurfaceKey)
    }

    /// Issues a one-shot preferred-return-surface request. Suppressed while
    /// an explicit destination is pending or being opened, or when a modal
    /// sheet already owns the surface; MainView re-checks at presentation
    /// time as a backstop.
    func requestPreferredReturnSurface() {
        guard chatReturnSurface == .sessions else { return }
        guard !hasPendingExplicitNavigation else { return }
        guard !isOpeningNotificationSession else { return }
        guard !isModalSheetPresented else { return }
        preferredReturnSurfaceRequest &+= 1
    }

    /// MainView's first authenticated appearance in this process is the
    /// cold-launch return. Mid-process re-entries (disconnect → sign back
    /// in) are not cold launches; they rely on the scene-phase path.
    func requestPreferredReturnSurfaceForColdLaunch() {
        guard !hasRequestedColdLaunchReturnSurface else { return }
        hasRequestedColdLaunchReturnSurface = true
        requestPreferredReturnSurface()
    }

    /// Auth teardown (sign-out) is not a qualifying return. Retire any
    /// outstanding preferred-return request at the boundary — claimed,
    /// unclaimed, or deferred — so a MainView recreated on the next sign-in
    /// can never present a stale request. The monotonic counter is left
    /// untouched; only the consumed watermark advances.
    private func retireOutstandingPreferredReturnSurfaceRequests() {
        consumedReturnSurfaceRequest = max(consumedReturnSurfaceRequest, preferredReturnSurfaceRequest)
        deferredReturnSurfaceRequest = nil
    }

    /// Claims the pending preferred-return-surface request for presentation.
    /// Returns true exactly once per issued request — the watermark lives in
    /// AppState, so a MainView recreated after sign-out/sign-in can never
    /// re-present an already-claimed request.
    ///
    /// Consumption semantics: while explicit navigation is pending the claim
    /// defers without consuming; the next unblocked claim of the same request
    /// then drops it, because the explicit route fully won that qualifying
    /// return. In-flight notification opens, modals, and preference changes
    /// consume-and-drop immediately (established precedence losers).
    func claimPreferredReturnSurfacePresentation() -> Bool {
        let current = preferredReturnSurfaceRequest
        guard current > consumedReturnSurfaceRequest else { return false }
        if hasPendingExplicitNavigation {
            deferredReturnSurfaceRequest = current
            return false
        }
        defer { deferredReturnSurfaceRequest = nil }
        if deferredReturnSurfaceRequest == current {
            consumedReturnSurfaceRequest = current
            return false
        }
        consumedReturnSurfaceRequest = current
        guard chatReturnSurface == .sessions,
              !isOpeningNotificationSession,
              !isModalSheetPresented else { return false }
        return true
    }

    func recordChatViewport(_ snapshot: ChatScrollSnapshot, for key: ChatScrollSessionKey) {
        chatResumeCoordinator.recordViewport(snapshot, for: key)
    }

    func installChatViewportSnapshotProvider(
        id: UUID,
        capture: @escaping @MainActor () -> ChatRenderedViewportSnapshot?
    ) {
        chatViewportSnapshotProvider = (id, capture)
    }

    func removeChatViewportSnapshotProvider(id: UUID) {
        guard chatViewportSnapshotProvider?.id == id else { return }
        chatViewportSnapshotProvider = nil
    }

    @discardableResult
    func beginExplicitChatViewportTransition() -> UInt64 {
        if let transition = chatViewportTransition {
            finishChatViewportTransition(generation: transition.generation)
        }
        let renderedViewport = chatViewportSnapshotProvider?.capture()
        chatResumeCoordinator.captureViewportAndFreeze(
            renderedViewport?.snapshot,
            for: renderedViewport?.sessionKey
        )
        chatViewportTransitionGeneration &+= 1
        chatViewportTransition = ChatViewportTransition(
            generation: chatViewportTransitionGeneration
        )
        cancelChatResumeRestoration()
        return chatViewportTransitionGeneration
    }

    private func chatViewportTransitionIsCurrent(generation: UInt64) -> Bool {
        chatViewportTransition?.generation == generation
    }

    private func chatViewportTransitionIsCurrent(_ generation: UInt64?) -> Bool {
        generation.map { chatViewportTransitionIsCurrent(generation: $0) } ?? true
    }

    private func markChatViewportReplacement() {
        guard var transition = chatViewportTransition else { return }
        transition.hasReplacement = true
        chatViewportTransition = transition
    }

    private func noteChatViewportTranscriptReplacement() {
        guard var transition = chatViewportTransition,
              transition.hasReplacement else { return }
        transition.expectedSessionKey = currentChatScrollSessionKey
        transition.expectedTranscriptRevision = chatTranscriptRevision
        chatViewportTransition = transition
    }

    private func advanceChatViewportExpectedTranscriptRevisionIfNeeded() {
        guard var transition = chatViewportTransition,
              transition.hasReplacement,
              transition.expectedTranscriptRevision != nil,
              transition.expectedSessionKey.map({ expected in
                  currentChatScrollSessionKey.map {
                      activeChatScrollSessionIdentity.areEquivalent(expected, $0)
                  } == true
              }) == true else { return }
        transition.expectedTranscriptRevision = chatTranscriptRevision
        chatViewportTransition = transition
    }

    private func cancelChatViewportTransitionIfNoReplacement(generation: UInt64) {
        guard let transition = chatViewportTransition,
              generation == transition.generation,
              !transition.hasReplacement else { return }
        finishChatViewportTransition(generation: generation)
    }

    private func finishChatViewportTransition(generation: UInt64) {
        guard chatViewportTransition?.generation == generation else { return }
        chatViewportTransition = nil
        chatResumeCoordinator.unfreezeViewport()
    }

    private func finishChatViewportTransitionIfNoTranscriptReplacement(
        generation: UInt64
    ) {
        guard let transition = chatViewportTransition,
              transition.generation == generation,
              transition.expectedTranscriptRevision == nil else { return }
        finishChatViewportTransition(generation: generation)
    }

    func chatViewportLayoutDidSettle(
        sessionKey: ChatScrollSessionKey,
        transitionGeneration: UInt64,
        transcriptRevision: UInt64,
        renderRevision: UInt64,
        receivedScopedPreference: Bool
    ) {
        guard let transition = chatViewportTransition,
              transitionGeneration == transition.generation,
              transition.hasReplacement,
              transition.expectedTranscriptRevision == transcriptRevision,
              receivedScopedPreference,
              transition.expectedSessionKey.map({ expected in
                  activeChatScrollSessionIdentity.areEquivalent(expected, sessionKey)
              }) == true,
              activeChatScrollSessionIdentity.areEquivalent(
                sessionKey,
                currentChatScrollSessionKey
              ) else { return }
        finishChatViewportTransition(generation: transitionGeneration)
    }

    private var currentChatScrollSessionKey: ChatScrollSessionKey? {
        if let canonical = activeChatScrollSessionIdentity.canonicalSessionKey {
            return canonical
        }
        guard let activeSessionId else { return nil }
        let fallback = ChatScrollSessionKey(profile: activeProfile, sessionID: activeSessionId)
        return fallback.isValid ? fallback : nil
    }

    func flushChatResumeViewport() {
        chatResumeCoordinator.flush()
    }

    func completeChatResumeRestoration(generation: UInt64) {
        chatResumeCoordinator.completeRestoration(generation: generation)
        if chatResumeRestorationRequest?.generation == generation,
           !chatResumeCoordinator.isCurrent(generation: generation) {
            chatResumeRestorationRequest = nil
        }
    }

    func abandonChatResumeRestoration(generation: UInt64) {
        let abandonedSessionKey = chatResumeRestorationRequest?.generation == generation
            ? chatResumeRestorationRequest?.sessionKey
            : nil
        chatResumeCoordinator.abandonRestoration(generation: generation)
        if chatResumeRestorationRequest?.generation == generation,
           !chatResumeCoordinator.isCurrent(generation: generation) {
            chatResumeRestorationRequest = nil
        }
        if let transition = chatViewportTransition,
           let abandonedSessionKey,
           transition.expectedSessionKey.map({ expected in
               activeChatScrollSessionIdentity.areEquivalent(expected, abandonedSessionKey)
           }) == true {
            finishChatViewportTransition(generation: transition.generation)
        }
    }

    func beginAutomaticChatResumeWork() -> ChatResumeAutomaticWorkToken {
        if let activeAutomaticChatResumeWork,
           chatResumeCoordinator.isCurrent(activeAutomaticChatResumeWork) {
            return activeAutomaticChatResumeWork
        }
        let token = chatResumeCoordinator.beginAutomaticWork()
        activeAutomaticChatResumeWork = token
        return token
    }

    private func automaticChatResumeWorkIsCurrent(
        _ token: ChatResumeAutomaticWorkToken?,
        syncOperationID: UUID? = nil,
        reconnectOperationID: UUID? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              token.map(chatResumeCoordinator.isCurrent) ?? true else { return false }
        if let syncOperationID,
           activeAutomaticSyncOperation?.id != syncOperationID {
            return false
        }
        if let reconnectOperationID,
           activeAutomaticReconnectOperation?.id != reconnectOperationID {
            return false
        }
        return true
    }

    private func transportContinuation(
        purpose: ChatResumeSyncPurpose,
        automaticWorkToken: ChatResumeAutomaticWorkToken?,
        automaticReconnectOperationID: UUID?
    ) -> ChatResumeTransportContinuation? {
        // Checked after every suspension in connect(with:),
        // reconnectForRetry, and the post-connect sync flow — the gate is
        // transport-wide, not reconnect-only: any chat-resume work that goes
        // inactive/backgrounded mid-flight must not keep publishing state
        // (watchdog: 0x8BADF00D). handleScenePhase(.active) re-establishes
        // the transport and syncs the session catalog on return.
        guard !Task.isCancelled, isSceneActive else { return nil }
        if let automaticReconnectOperationID,
           activeAutomaticReconnectOperation?.id != automaticReconnectOperationID {
            return nil
        }
        guard let automaticWorkToken else {
            return (purpose, nil, false)
        }
        if chatResumeCoordinator.isCurrent(automaticWorkToken) {
            return (purpose, automaticWorkToken, false)
        }
        guard purpose == .automaticReturn else { return nil }
        return (.preserveCurrent, nil, true)
    }

    private func synchronizeTransportContinuation(
        purpose: ChatResumeSyncPurpose,
        automaticWorkToken: ChatResumeAutomaticWorkToken?,
        automaticReconnectOperationID: UUID?,
        client: HermesClient,
        profile: String
    ) async -> ChatResumeTransportContinuation? {
        guard transportContinuation(
                purpose: purpose,
                automaticWorkToken: automaticWorkToken,
                automaticReconnectOperationID: automaticReconnectOperationID
              ) != nil,
              let activeClient = self.client,
              activeClient === client,
              activeProfile == profile else { return nil }
        let viewportTransitionGeneration = chatViewportTransitionGeneration
        let outcome = await performSyncSession(
            purpose: purpose,
            using: nil,
            automaticWorkToken: automaticWorkToken
        )
        guard let continuation = transportContinuation(
                purpose: purpose,
                automaticWorkToken: automaticWorkToken,
                automaticReconnectOperationID: automaticReconnectOperationID
              ),
              let activeClient = self.client,
              activeClient === client,
              activeProfile == profile else { return nil }
        guard outcome == .automaticIntentInvalidated,
              continuation.handedOffAutomaticIntent,
              purpose == .automaticReturn,
              chatViewportTransition == nil,
              chatViewportTransitionGeneration == viewportTransitionGeneration else {
            return continuation
        }

        _ = await performSyncSession(
            purpose: .preserveCurrent,
            using: nil,
            automaticWorkToken: nil
        )
        guard let preservedContinuation = transportContinuation(
                purpose: .preserveCurrent,
                automaticWorkToken: nil,
                automaticReconnectOperationID: automaticReconnectOperationID
              ),
              let activeClient = self.client,
              activeClient === client,
              activeProfile == profile else { return nil }
        return (
            preservedContinuation.purpose,
            preservedContinuation.automaticWorkToken,
            true
        )
    }

    func cancelChatResumeRestoration() {
        chatResumeCoordinator.cancelViewportRestoration(
            keepViewportFrozen: chatViewportTransition != nil
        )
        cancelOwnedAutomaticSyncOperation()
        activeAutomaticChatResumeWork = nil
        recoverySequence.preserveTransportAfterAutomaticIntentCancellation()
        chatResumeRestorationRequest = nil
    }

    private func cancelChatResumeTransportRecovery() {
        cancelExplicitSessionOpen()
        cancelScheduledReconnect()
        chatResumeCoordinator.cancelViewportRestoration(
            keepViewportFrozen: chatViewportTransition != nil
        )
        cancelOwnedAutomaticOperations()
        activeAutomaticChatResumeWork = nil
        recoverySequence.cancel()
        chatResumeRestorationRequest = nil
    }

    private func beginAutomaticSyncOperation(
        for token: ChatResumeAutomaticWorkToken?
    ) -> UUID? {
        guard token != nil else { return nil }
        let operation = AutomaticSyncOperation(
            id: UUID(),
            previousTurnState: activeAutomaticSyncOperation?.previousTurnState
                ?? turnState
        )
        activeAutomaticSyncOperation = operation
        return operation.id
    }

    private func finishAutomaticSyncOperation(id: UUID?, restoringBaseline: Bool = false) {
        guard let id, activeAutomaticSyncOperation?.id == id else { return }
        if restoringBaseline,
           let operation = activeAutomaticSyncOperation,
           turnState == .synchronizing {
            turnState = operation.previousTurnState
        }
        activeAutomaticSyncOperation = nil
    }

    private func beginAutomaticReconnectOperation(
        for token: ChatResumeAutomaticWorkToken?
    ) -> UUID? {
        guard token != nil else { return nil }
        let operation = AutomaticReconnectOperation(
            id: UUID(),
            previousIsConnecting: activeAutomaticReconnectOperation?.previousIsConnecting
                ?? isConnecting,
            previousTurnState: activeAutomaticReconnectOperation?.previousTurnState
                ?? turnState
        )
        activeAutomaticReconnectOperation = operation
        return operation.id
    }

    private func finishAutomaticReconnectOperation(id: UUID?, restoringBaseline: Bool = false) {
        guard let id, activeAutomaticReconnectOperation?.id == id else { return }
        if restoringBaseline, let operation = activeAutomaticReconnectOperation {
            if isConnecting {
                isConnecting = operation.previousIsConnecting
            }
            if turnState == .reconnecting {
                turnState = operation.previousTurnState
            }
        }
        activeAutomaticReconnectOperation = nil
    }

    private func cancelOwnedAutomaticOperations() {
        cancelOwnedAutomaticSyncOperation()
        cancelOwnedAutomaticReconnectOperation()
    }

    private func cancelOwnedAutomaticSyncOperation() {
        if let operation = activeAutomaticSyncOperation {
            if turnState == .synchronizing {
                turnState = operation.previousTurnState
            }
            activeAutomaticSyncOperation = nil
        }
    }

    private func cancelOwnedAutomaticReconnectOperation() {
        if let operation = activeAutomaticReconnectOperation {
            if isConnecting {
                isConnecting = operation.previousIsConnecting
            }
            if turnState == .reconnecting {
                turnState = operation.previousTurnState
            }
            activeAutomaticReconnectOperation = nil
        }
    }

    @discardableResult
    func acceptChatResumeConversationReplacement(
        _ replacement: ChatResumeConversationReplacement
    ) -> UInt64 {
        beginExplicitChatViewportTransition()
    }

    @discardableResult
    func prepareChatResumeForConnection(to baseURL: String) -> Bool {
        guard let identity = Self.normalizedChatResumeServerIdentity(baseURL) else { return false }
        let previousIdentity = defaults.string(forKey: chatResumeServerIdentityKey)
            .flatMap(Self.normalizedChatResumeServerIdentity)
            ?? initialChatResumeServerIdentity
        defaults.set(identity, forKey: chatResumeServerIdentityKey)
        guard let previousIdentity, previousIdentity != identity else { return false }

        chatResumeCoordinator.clearResumeState()
        cancelOwnedAutomaticOperations()
        activeAutomaticChatResumeWork = nil
        cancelScheduledReconnect()
        recoverySequence.cancel()
        chatResumeRestorationRequest = nil
        invalidateReconciliation()
        sessionCatalogCache.removeAll()
        sessions = []
        cronSessions = []
        archivedSessions = []
        projects = []
        supportsProjects = false
        projectsLoading = false
        profiles = []
        clearPendingDecisionRestorationGuard()
        activeSessionId = nil
        activeSessionTitle = "New conversation"
        messages = []
        persistedTranscriptWindow = nil
        clearStreamingText()
        resetReasoningTurn()
        activeSessionTitlesByProfile = [:]
        pinnedSessionIDsByProfile = [:]
        pinnedSessionIDs = []
        defaults.removeObject(forKey: activeSessionTitlesByProfileKey)
        defaults.removeObject(forKey: pinnedSessionIDsByProfileKey)
        defaults.removeObject(forKey: reviewSummaryCacheKey)
        defaults.removeObject(forKey: knownProfilesKey)
        clearSessionPresentationCache()
        return true
    }

    private static func normalizedChatResumeServerIdentity(_ baseURL: String) -> String? {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.string
    }

    private func refreshActiveChatScrollSessionIdentity(
        isReconciling: Bool? = nil,
        advanceSettledRevision: Bool = false
    ) {
        let current = activeChatScrollSessionIdentity
        let sessionCatalog = sessions + cronSessions
        let identityCatalog = sessionCatalog.map { session in
            ChatScrollSessionCatalogIdentity(
                profile: session.profile ?? activeProfile,
                canonicalSessionID: session.id,
                alternateSessionIDs: Set(session.alternateIds)
            )
        }
        let updated = ChatScrollSessionIdentityResolver.resolve(
            profile: activeProfile,
            activeSessionID: activeSessionId,
            catalog: identityCatalog,
            requestedSessionID: reconciliation?.requestedSessionId,
            resolvedSessionID: reconciliation?.resolvedSessionId,
            previousIdentity: current,
            isReconciling: isReconciling ?? current.isReconciling,
            advanceSettledRevision: advanceSettledRevision
        )
        if updated != current {
            migrateChatResumePersistenceIfNeeded(
                from: current,
                to: updated,
                catalog: sessionCatalog
            )
            activeChatScrollSessionIdentity = updated
        }
    }

    private func migrateChatResumePersistenceIfNeeded(
        from current: ChatScrollSessionIdentity,
        to updated: ChatScrollSessionIdentity,
        catalog: [SessionSummary]
    ) {
        guard let canonicalKey = updated.canonicalSessionKey,
              let canonicalSession = catalog.first(where: { session in
                  let profile = session.profile ?? canonicalKey.profile
                  return ChatScrollSessionKey(
                      profile: profile,
                      sessionID: session.id
                  ) == canonicalKey
              }) else { return }

        let equivalentSessionIDs = Set(
            ([canonicalSession.id] + canonicalSession.alternateIds).compactMap { sessionID in
                let key = ChatScrollSessionKey(
                    profile: canonicalKey.profile,
                    sessionID: sessionID
                )
                return key.isValid ? key.sessionID : nil
            }
        )

        let persistedKey = chatResumeCoordinator
            .lastSessionID(for: canonicalKey.profile)
            .map { ChatScrollSessionKey(profile: canonicalKey.profile, sessionID: $0) }
        let activeKey = activeSessionId.map {
            ChatScrollSessionKey(profile: canonicalKey.profile, sessionID: $0)
        }
        let candidates = [persistedKey, current.canonicalSessionKey, activeKey]
            .compactMap { $0 }
        guard let runtimeKey = candidates.first(where: {
            $0 != canonicalKey
                && $0.profile == canonicalKey.profile
                && equivalentSessionIDs.contains($0.sessionID)
        }) else { return }

        chatResumeCoordinator.migrateSessionIdentity(from: runtimeKey, to: canonicalKey)
    }

    func makeSettingsSnapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            server: connection?.baseUrl,
            isConnected: isConnected,
            profile: activeProfile,
            defaultProfileName: defaultProfileName,
            theme: themePreference,
            busyInputMode: busyInputMode,
            chatResumeBehavior: chatResumeBehavior,
            chatReturnSurface: chatReturnSurface,
            displayPreferences: displayPreferences,
            cloudflareAccess: KeychainHelper.loadCloudflareAccess(for: connection?.baseUrl)
        )
    }

    func saveCloudflareAccess(clientID: String, clientSecret: String) {
        if let baseURL = connection?.baseUrl,
           let access = CloudflareAccessCredentials.from(clientID: clientID, clientSecret: clientSecret) {
            let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL)) ?? baseURL
            KeychainHelper.saveCloudflareAccess(access, origin: normalized)
        } else {
            KeychainHelper.clearCloudflareAccess()
        }
        if let baseURL = connection?.baseUrl { prepareDashboardBridge(for: baseURL) }
    }

    func removeCloudflareAccess() {
        KeychainHelper.clearCloudflareAccess()
        if let baseURL = connection?.baseUrl { prepareDashboardBridge(for: baseURL) }
    }

    /// Gateway profile IDs remain stable; this is only the device-local label
    /// used for presentation in the chat and profile picker.
    func profileDisplayName(_ profile: String) -> String {
        let normalized = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized.lowercased() == "default" { return defaultProfileName }
        return String(normalized.prefix(1)).uppercased() + String(normalized.dropFirst())
    }

    func profileAvatarURL(for profile: String) -> URL? {
        profileAvatarURLs[profile]
    }

    func saveDefaultProfileName(_ name: String) {
        defaultProfileName = ProfileAppearanceStore.saveDefaultName(name)
    }

    func selectAppIcon(_ choice: AppIconChoice) async -> Bool {
        guard choice != appIconChoice else { return true }
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "This build does not include alternate app icons."
            return false
        }

        return await withCheckedContinuation { continuation in
            UIApplication.shared.setAlternateIconName(choice.alternateIconName) { [weak self] error in
                Task { @MainActor in
                    if let error {
                        self?.errorMessage = "Could not change the app icon: \(error.localizedDescription)"
                        continuation.resume(returning: false)
                    } else {
                        self?.appIconChoice = choice
                        continuation.resume(returning: true)
                    }
                }
            }
        }
    }

    func saveProfileAvatar(_ data: Data, for profile: String) throws {
        profileAvatarURLs[profile] = try ProfileAppearanceStore.saveAvatar(data, for: profile)
    }

    func removeProfileAvatar(for profile: String) {
        ProfileAppearanceStore.removeAvatar(for: profile)
        profileAvatarURLs.removeValue(forKey: profile)
    }

    /// Profile order is only a device-local presentation preference.
    func moveProfile(from index: Int, to destination: Int) {
        guard profiles.indices.contains(index), profiles.indices.contains(destination), index != destination else { return }
        profiles.swapAt(index, destination)
        defaults.set(profiles, forKey: profileOrderKey)
    }

    /// The All pill stays fixed; the remaining session categories are local UI preference.
    func moveSessionFilters(fromOffsets: IndexSet, toOffset: Int) {
        sessionFilterOrder.move(fromOffsets: fromOffsets, toOffset: toOffset)
        defaults.set(sessionFilterOrder.map(\.rawValue), forKey: sessionFilterOrderKey)
    }

    /// The dashboard location is harmless preference data, unlike the one-time
    /// ticket stored in Keychain. Keep it after sign-out so the next login does
    /// not require re-entering a server address.
    var lastDashboardURL: String {
        defaults.string(forKey: dashboardURLKey) ?? connection?.baseUrl ?? ""
    }

    func rememberDashboardURL(_ url: String) {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(url) else { return }
        defaults.set(normalized, forKey: dashboardURLKey)
    }

    func saveModelVisibility(_ visibility: ModelVisibility) {
        let normalized = ModelVisibility(
            hiddenProviders: Array(Set(visibility.hiddenProviders.filter { !$0.isEmpty })).sorted(),
            hiddenModels: Array(Set(visibility.hiddenModels.filter { !$0.isEmpty })).sorted()
        )
        modelVisibility = normalized
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: modelVisibilityKey)
        }
    }

    // MARK: - Connection management

    func loadSavedConnection() {
        if let credentials = KeychainHelper.loadCredentials() {
            Task { await restoreSavedCredentials(credentials) }
        } else if let saved = KeychainHelper.loadConnection() {
            rememberDashboardURL(saved.baseUrl)
            // Keep the authenticated app shell in place while WebKit restores
            // its cookie process. A cold WebKit launch is not evidence that the
            // dashboard sign-in expired.
            connection = saved
            showLogin = false
            isConnecting = true
            turnState = .synchronizing
            Task { await restoreSavedConnection(saved) }
        }
    }

    func connect(with conn: HermesConnection, profile: String = "default") async {
        await connect(
            with: conn,
            profile: profile,
            syncPurpose: .automaticReturn,
            cancelsResumeRestoration: true
        )
    }

    private func connect(
        with conn: HermesConnection,
        profile: String,
        syncPurpose: ChatResumeSyncPurpose,
        cancelsResumeRestoration: Bool,
        automaticWorkToken existingAutomaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticReconnectOperationID: UUID? = nil
    ) async {
        if cancelsResumeRestoration {
            cancelChatResumeTransportRecovery()
        }
        guard let normalizedBaseURL = try? ConnectionURLPolicy.normalizedBaseURL(conn.baseUrl) else {
            isConnecting = false
            isConnected = false
            showLogin = true
            errorMessage = ConnectionURLPolicyError.insecureTransport.localizedDescription
            return
        }
        prepareChatResumeForConnection(to: normalizedBaseURL)
        let automaticWorkToken = syncPurpose == .automaticReturn
            ? (existingAutomaticWorkToken ?? beginAutomaticChatResumeWork())
            : nil
        let ownedAutomaticReconnectOperationID = automaticReconnectOperationID == nil
            ? beginAutomaticReconnectOperation(for: automaticWorkToken)
            : nil
        let transportOperationID = automaticReconnectOperationID
            ?? ownedAutomaticReconnectOperationID
        var handedOffAutomaticIntent = false
        defer {
            if ownedAutomaticReconnectOperationID != nil {
                finishAutomaticReconnectOperation(
                    id: ownedAutomaticReconnectOperationID,
                    restoringBaseline: !handedOffAutomaticIntent
                        && !automaticChatResumeWorkIsCurrent(
                            automaticWorkToken,
                            reconnectOperationID: transportOperationID
                        )
                )
            }
        }
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            reconnectOperationID: transportOperationID
        ) else { return }
        rememberDashboardURL(conn.baseUrl)
        cancelScheduledReconnect()
        isConnecting = true
        showLogin = false
        connection = conn
        if activeProfile != profile {
            // Hard profile boundary for this forward transition: cancel the
            // debounced stream flush and write synchronously while the
            // current profile still owns the in-memory transcript. Mirrors
            // switchProfile(to:reusing:).
            flushPendingPresentationCache()
            sessions = []
            cronSessions = []
            archivedSessions = []
            slashCommands = Self.builtInSlashCommands
        }
        // Fence deferred presentation-cache writes created under the
        // previous profile before transcripts change over.
        setActiveProfile(profile)
        restoreActiveSessionState(for: profile)
        restorePinnedSessions(for: profile)
        defaults.set(profile, forKey: activeProfileKey)
        turnState = .synchronizing
        prepareDashboardBridge(for: conn.baseUrl)

        let previousClient = client
        let client = makeClient(connection: conn, profile: profile)
        self.client = client
        previousClient?.disconnect()

        do {
            try await connectChatResumeClient(client)
            guard let continuation = transportContinuation(
                    purpose: syncPurpose,
                    automaticWorkToken: automaticWorkToken,
                    automaticReconnectOperationID: transportOperationID
                  ),
                  let activeClient = self.client, activeClient === client else { return }
            var continuationPurpose = continuation.purpose
            var continuationAutomaticWorkToken = continuation.automaticWorkToken
            handedOffAutomaticIntent = continuation.handedOffAutomaticIntent
            isConnected = true
            isConnecting = false
            reconnectAttempts = 0
            connectedAt = Date()
            KeychainHelper.saveConnection(conn)

            await loadChatResumeProfiles()
            guard let continuation = transportContinuation(
                purpose: continuationPurpose,
                automaticWorkToken: continuationAutomaticWorkToken,
                automaticReconnectOperationID: transportOperationID
            ) else { return }
            continuationPurpose = continuation.purpose
            continuationAutomaticWorkToken = continuation.automaticWorkToken
            handedOffAutomaticIntent = handedOffAutomaticIntent
                || continuation.handedOffAutomaticIntent
            guard let continuation = await synchronizeTransportContinuation(
                purpose: continuationPurpose,
                automaticWorkToken: continuationAutomaticWorkToken,
                automaticReconnectOperationID: transportOperationID,
                client: client,
                profile: profile
            ) else { return }
            continuationPurpose = continuation.purpose
            continuationAutomaticWorkToken = continuation.automaticWorkToken
            handedOffAutomaticIntent = handedOffAutomaticIntent
                || continuation.handedOffAutomaticIntent
            await loadChatResumeBusyInputMode(using: client)
            guard let continuation = transportContinuation(
                    purpose: continuationPurpose,
                    automaticWorkToken: continuationAutomaticWorkToken,
                    automaticReconnectOperationID: transportOperationID
                  ),
                  let activeClient = self.client, activeClient === client else { return }
            continuationPurpose = continuation.purpose
            continuationAutomaticWorkToken = continuation.automaticWorkToken
            handedOffAutomaticIntent = handedOffAutomaticIntent
                || continuation.handedOffAutomaticIntent
            await loadChatResumeProfileDisplayPreferences()
            guard let continuation = transportContinuation(
                purpose: continuationPurpose,
                automaticWorkToken: continuationAutomaticWorkToken,
                automaticReconnectOperationID: transportOperationID
            ) else { return }
            handedOffAutomaticIntent = handedOffAutomaticIntent
                || continuation.handedOffAutomaticIntent
            Task { await loadChatResumeSlashCommands() }
        } catch {
            guard let continuation = transportContinuation(
                    purpose: syncPurpose,
                    automaticWorkToken: automaticWorkToken,
                    automaticReconnectOperationID: transportOperationID
                  ),
                  let activeClient = self.client, activeClient === client else { return }
            handedOffAutomaticIntent = continuation.handedOffAutomaticIntent
            isConnecting = false
            isConnected = false
            turnState = .reconnecting
            errorMessage = error.localizedDescription
            // Only an explicit dashboard 401/403 may return the user to the
            // sign-in screen. A transient gateway or WebKit startup failure
            // must retain the saved dashboard session and retry.
            showLogin = false
            scheduleReconnect(purpose: continuation.purpose)
        }
    }

    func disconnect() {
        cancelExplicitSessionOpen()
        chatResumeCoordinator.clearResumeState()
        cancelOwnedAutomaticOperations()
        activeAutomaticChatResumeWork = nil
        cancelScheduledReconnect()
        recoverySequence.cancel()
        chatResumeRestorationRequest = nil
        invalidateReconciliation()
        cancelScenePhaseAttempt()
        client?.disconnect()
        isConnected = false
        isConnecting = false
        connectedAt = nil
        KeychainHelper.clearConnection()
        KeychainHelper.clearCredentials()
        KeychainHelper.clearCloudflareAccess()
        // The Keychain mirror of the dashboard cookies is cleared above, but
        // the live session cookies live on in WebKit's persistent default data
        // store and the shared Foundation cookie store. Without removing them,
        // Disconnect is not equivalent to logging out: a still-valid server
        // session could be silently resumed on the next authentication flow.
        // Capture the origin before nulling `connection` and purge both stores.
        let dashboardBaseURL = connection?.baseUrl
        connection = nil
        client = nil
        dashboardTicketBridge?.invalidate()
        dashboardTicketBridge = nil
        voiceConversationController.stop()
        messageReadAloudController.stop()
        // The bridge is invalidated above; a gateway built against it can
        // never open a stream again, so it must not survive the re-login.
        messageReadAloudController.setGateway(nil)
        readAloudGatewayBridge = nil
        showVoiceSheet = false
        voiceCapabilitySnapshot = .unavailable
        isVoiceEnabled = false
        voiceTranscriptionMode = .hermes
        appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
        retireOutstandingPreferredReturnSurfaceRequests()
        showLogin = true
        sessions = []
        archivedSessions = []
        cronSessions = []
        // Sessions can be deleted from another client while signed out; a
        // stale catalog cache would show those rows again after re-sign-in
        // (and the full-history marker would suppress the reload that could
        // correct them).
        sessionCatalogCache.removeAll()
        pinnedSessionIDs = []
        messages = []
        persistedTranscriptWindow = nil
        setActiveSessionState(id: nil, title: "New conversation")
        clearStreamingText()
        resetReasoningTurn()
        turnState = .idle
        defaults.removeObject(forKey: activeSessionTitlesByProfileKey)
        defaults.removeObject(forKey: pinnedSessionIDsByProfileKey)
        activeSessionTitlesByProfile = [:]
        pinnedSessionIDsByProfile = [:]
        defaults.removeObject(forKey: activeProfileKey)
        clearDashboardWebSession(for: dashboardBaseURL)
    }

    /// Removes the dashboard origin's cookies from the WebKit default data
    /// store and the shared Foundation cookie store. The Foundation store is
    /// cleared synchronously first so no rapid reconnect can reuse the native
    /// session cookie; the WebKit store can only be mutated asynchronously, so
    /// it is dispatched as a background task.
    private func clearDashboardWebSession(for dashboardBaseURL: String?) {
        guard let dashboardBaseURL else { return }
        DashboardCookiePersistence.clearNativeCookies(for: dashboardBaseURL)
        Task { @MainActor in
            if let url = URL(string: dashboardBaseURL) {
                await DashboardCookiePersistence.clear(
                    from: WKWebsiteDataStore.default().httpCookieStore,
                    for: url
                )
            }
        }
    }

    private func makeClient(connection: HermesConnection, profile: String) -> HermesClient {
        let client = HermesClient(connection: connection, profile: profile, cloudflareAccess: KeychainHelper.loadCloudflareAccess(for: connection.baseUrl))
        let epoch = UUID()
        activeClientEpoch = epoch
        client.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self, self.activeClientEpoch == epoch else { return }
                self.handleStreamEvent(event)
            }
        }
        client.onDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self, self.activeClientEpoch == epoch else { return }
                self.handleDisconnect()
            }
        }
        return client
    }

    /// Match the React Native client's recovery order: the securely persisted
    /// connection is the first cold-start attempt. The dashboard bridge is
    /// only needed to mint a replacement ticket after that socket actually
    /// disconnects or fails. Requiring a freshly restored WebKit cookie before
    /// every launch was what turned a healthy saved Hermes session into login.
    private func restoreSavedConnection(_ saved: HermesConnection) async {
        prepareDashboardBridge(for: saved.baseUrl)
        await connect(with: saved, profile: activeProfile)
    }

    private func restoreSavedCredentials(_ credentials: DashboardCredentials) async {
        rememberDashboardURL(credentials.baseURL)

        if credentials.requiresFaceID {
            guard BiometricAuth.isFaceIDAvailable,
                  await BiometricAuth.authenticate(reason: "Unlock Conduit") else {
                showLogin = true
                return
            }
        }

        do {
            let authenticatedConnection = try await NativeAuthClient(baseURL: credentials.baseURL, cloudflareAccess: KeychainHelper.loadCloudflareAccess(for: credentials.baseURL)).connect(
                username: credentials.username,
                password: credentials.password
            )
            authenticatedConnection.commitCookies()
            await connect(with: HermesConnection(baseUrl: credentials.baseURL, ticket: authenticatedConnection.ticket), profile: activeProfile)
        } catch is CancellationError {
            // Intentional cancellation (e.g. a superseded connect) is not a
            // login failure; fall back to the login screen silently.
            showLogin = true
        } catch {
            // A rejected saved password falls back to the native login screen
            // without erasing it, allowing the user to correct the account.
            showLogin = true
            errorMessage = error.localizedDescription
        }
    }

    private func prepareDashboardBridge(for baseUrl: String) {
        let normalized = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let access = KeychainHelper.loadCloudflareAccess(for: normalized)
        if dashboardTicketBridge?.baseURL != normalized || dashboardTicketBridge?.cloudflareAccess != access {
            dashboardTicketBridge?.invalidate()
            dashboardTicketBridge = DashboardTicketBridge(baseURL: normalized, cloudflareAccess: access)
        }
    }

    private func requireSignIn(message: String) {
        cancelChatResumeTransportRecovery()
        invalidateReconciliation()
        cancelSecondaryProfileTitleRecovery()
        client?.disconnect()
        client = nil
        isConnected = false
        isConnecting = false
        connectedAt = nil
        connection = nil
        dashboardTicketBridge?.invalidate()
        dashboardTicketBridge = nil
        // A forced sign-out kills the bridge mid-playback; stop the read
        // aloud and drop its gateway the same way Disconnect does.
        messageReadAloudController.stop()
        messageReadAloudController.setGateway(nil)
        readAloudGatewayBridge = nil
        projects = []
        supportsProjects = false
        projectsLoading = false
        KeychainHelper.clearConnection()
        turnState = .idle
        retireOutstandingPreferredReturnSurfaceRequests()
        showLogin = true
        errorMessage = message
    }

    // MARK: - Authoritative reconciliation

    /// The only entry point for cold start, foreground refresh, reconnect, and
    /// manual refresh. It never derives liveness from transcript shape.
    func syncSession() async {
        cancelChatResumeRestoration()
        await syncSession(purpose: .preserveCurrent, using: nil, automaticWorkToken: nil)
    }

    func syncSession(
        purpose: ChatResumeSyncPurpose,
        using existingReconciliationToken: UUID?,
        automaticWorkToken existingAutomaticWorkToken: ChatResumeAutomaticWorkToken?,
        requiredViewportTransitionGeneration: UInt64? = nil
    ) async {
        _ = await performSyncSession(
            purpose: purpose,
            using: existingReconciliationToken,
            automaticWorkToken: existingAutomaticWorkToken,
            requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
        )
    }

    private func performSyncSession(
        purpose: ChatResumeSyncPurpose,
        using existingReconciliationToken: UUID?,
        automaticWorkToken existingAutomaticWorkToken: ChatResumeAutomaticWorkToken?,
        requiredViewportTransitionGeneration: UInt64? = nil
    ) async -> ChatResumeSyncExecutionOutcome {
        guard chatViewportTransitionIsCurrent(
            requiredViewportTransitionGeneration
        ) else { return .superseded }
        let purpose = beginChatResumeRecovery(purpose: purpose)
        let automaticWorkToken = purpose == .automaticReturn
            ? (existingAutomaticWorkToken ?? beginAutomaticChatResumeWork())
            : nil
        guard automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
            return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
        }
        let automaticOperationID = beginAutomaticSyncOperation(for: automaticWorkToken)
        defer {
            finishAutomaticSyncOperation(
                id: automaticOperationID,
                restoringBaseline: !automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                )
            )
        }
        if let existingReconciliationToken,
           !claimReconciliation(
            existingReconciliationToken,
            automaticSyncOperationID: automaticOperationID
           ) {
            return .superseded
        }
        guard let client else {
            if let existingReconciliationToken {
                settleReconciliation(
                    existingReconciliationToken,
                    automaticSyncOperationID: automaticOperationID
                )
            }
            return .completed
        }
        // A notification destination always wins over automatic restoration of
        // the previously active/newest session. Check both before and after
        // the catalog fetch because a notification tap can arrive mid-launch.
        guard PushNotificationService.shared.pendingTarget == nil else {
            cancelChatResumeRestoration()
            if let existingReconciliationToken {
                settleReconciliation(
                    existingReconciliationToken,
                    automaticSyncOperationID: automaticOperationID
                )
            }
            return .superseded
        }
        let token = existingReconciliationToken ?? beginReconciliation()
        guard claimReconciliation(
            token,
            automaticSyncOperationID: automaticOperationID
        ) else { return .superseded }
        let profile = activeProfile
        let retainedActiveTurn = activeTurnCatalogSession()
        turnState = .synchronizing

        do {
            // This intentionally mirrors the proven React Native startup
            // sequence: discover the live gateway's current sessions first,
            // then resume the newest chat. A persisted runtime id can belong
            // to a process that no longer exists after a relaunch.
            let loadedSessions = try await profileSessions(using: client)
            let allSessions = uniqueSessions(
                [retainedActiveTurn].compactMap { $0 } + loadedSessions
            )
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(
                    token,
                    automaticSyncOperationID: automaticOperationID
                )
                return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            }
            guard PushNotificationService.shared.pendingTarget == nil else {
                cancelChatResumeRestoration()
                settleReconciliation(
                    token,
                    automaticSyncOperationID: automaticOperationID
                )
                return .superseded
            }
            guard automaticChatResumeWorkIsCurrent(
                automaticWorkToken,
                syncOperationID: automaticOperationID
            ), chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration) else {
                settleReconciliation(
                    token,
                    automaticSyncOperationID: automaticOperationID
                )
                return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            }
            sessions = allSessions.filter { $0.source != .cron }
            cronSessions = allSessions.filter { $0.source == .cron }

            guard automaticChatResumeWorkIsCurrent(
                automaticWorkToken,
                syncOperationID: automaticOperationID
            ), chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration) else {
                settleReconciliation(
                    token,
                    automaticSyncOperationID: automaticOperationID
                )
                return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            }
            let target = selectChatResumeTarget(
                in: allSessions,
                profile: profile,
                purpose: purpose,
                currentSessionID: activeSessionId,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticOperationID
            )
            if let target {
                let succeeded = await reconcile(
                    sessionId: target.id,
                    using: client,
                    token: token,
                    acceptedSessionIDs: Set([target.id] + target.alternateIds),
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticOperationID,
                    requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
                )
                if !succeeded,
                   purpose == .automaticReturn,
                   automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                   ),
                   token == reconciliationToken,
                   profile == activeProfile {
                    scheduleReconnect(purpose: purpose)
                }
                return succeeded
                    ? .completed
                    : chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            } else {
                await createAndReconcileSession(
                    using: client,
                    profile: profile,
                    token: token,
                    resumePurpose: purpose,
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticOperationID,
                    requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
                )
                return automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                )
                    ? .completed
                    : chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            }
        } catch {
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(
                    token,
                    automaticSyncOperationID: automaticOperationID
                )
                return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            }
            turnState = .reconnecting
            errorMessage = "Failed to load gateway sessions: \(error.localizedDescription)"
            settleReconciliation(
                token,
                automaticSyncOperationID: automaticOperationID
            )
            if purpose == .automaticReturn {
                scheduleReconnect(purpose: purpose)
            }
            return .completed
        }
    }

    private func chatResumeSyncInterruptionOutcome(
        for automaticWorkToken: ChatResumeAutomaticWorkToken?
    ) -> ChatResumeSyncExecutionOutcome {
        guard let automaticWorkToken,
              !chatResumeCoordinator.isCurrent(automaticWorkToken) else {
            return .superseded
        }
        return .automaticIntentInvalidated
    }

    func beginReconciliation() -> UUID {
        let token = UUID()
        let bufferedEvents = reconciliation?.bufferedEvents ?? []
        let streamTextAtBoundary: String?
        let streamSessionIDAtBoundary: String?
        if let existingReconciliation = reconciliation {
            streamTextAtBoundary = existingReconciliation.streamTextAtBoundary
            streamSessionIDAtBoundary = existingReconciliation.streamSessionIDAtBoundary
        } else {
            streamTextAtBoundary = activeSessionId.map { _ in streamingBuffer }
            streamSessionIDAtBoundary = activeSessionId
        }
        reconciliationToken = token
        reconciliation = Reconciliation(
            token: token,
            requestedSessionId: activeSessionId ?? "",
            acceptsAnySession: true,
            streamTextAtBoundary: streamTextAtBoundary,
            streamSessionIDAtBoundary: streamSessionIDAtBoundary,
            bufferedEvents: bufferedEvents
        )
        refreshActiveChatScrollSessionIdentity(isReconciling: true)
        return token
    }

    private func invalidateReconciliation() {
        let wasReconciling = activeChatScrollSessionIdentity.isReconciling
        reconciliationToken = UUID()
        reconciliation = nil
        refreshActiveChatScrollSessionIdentity(
            isReconciling: false,
            advanceSettledRevision: wasReconciling
        )
    }

    @discardableResult
    private func claimReconciliation(
        _ token: UUID,
        automaticSyncOperationID: UUID?
    ) -> Bool {
        guard token == reconciliationToken,
              var reconciliation else { return false }
        reconciliation.automaticSyncOperationID = automaticSyncOperationID
        self.reconciliation = reconciliation
        return true
    }

    @discardableResult
    private func settleReconciliation(
        _ token: UUID,
        automaticSyncOperationID: UUID? = nil
    ) -> Bool {
        guard token == reconciliationToken,
              let activeReconciliation = reconciliation,
              activeReconciliation.automaticSyncOperationID == automaticSyncOperationID else {
            return false
        }
        let wasReconciling = activeChatScrollSessionIdentity.isReconciling
        reconciliation = nil
        refreshActiveChatScrollSessionIdentity(
            isReconciling: false,
            advanceSettledRevision: wasReconciling
        )
        return true
    }

    func selectChatResumeTarget(
        in catalog: [SessionSummary],
        profile: String,
        purpose: ChatResumeSyncPurpose,
        currentSessionID: String?,
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil
    ) -> SessionSummary? {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ) else { return nil }
        if purpose == .automaticReturn {
            chatResumeRestorationRequest = nil
        }
        return chatResumeCoordinator.selectTarget(
            in: catalog,
            profile: profile,
            purpose: purpose,
            currentSessionID: currentSessionID
        )
    }

    @discardableResult
    func beginChatResumeRecovery(
        purpose: ChatResumeSyncPurpose
    ) -> ChatResumeSyncPurpose {
        recoverySequence.register(purpose)
    }

    func chatResumePurposeForDisconnect() -> ChatResumeSyncPurpose {
        recoverySequence.currentPurpose
    }

    func planChatResumeReconnect(
        purpose: ChatResumeSyncPurpose
    ) -> ChatResumeReconnectSchedulingDecision {
        recoverySequence.planReconnect(requestedPurpose: purpose)
    }

    private func publishChatResumeRestorationIfReady(
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil
    ) {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ) else { return }
        guard let sessionKey = activeChatScrollSessionIdentity.canonicalSessionKey else {
            return
        }
        guard let request = chatResumeCoordinator.reconciliationSettled(sessionKey: sessionKey) else {
            // reconciliationSettled returned nil. If there was a pending
            // session key (mismatch path), clear the freeze so viewport
            // recording resumes. If there was no pending key, there's
            // nothing to clean up.
            chatResumeCoordinator.abandonPendingAutomaticSyncIfPending()
            return
        }
        chatResumeRestorationRequest = request
    }

    @discardableResult
    func settleReconciliationAndPublish(
        _ token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil
    ) -> Bool {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ) else {
            settleReconciliation(
                token,
                automaticSyncOperationID: automaticSyncOperationID
            )
            return false
        }
        guard settleReconciliation(
            token,
            automaticSyncOperationID: automaticSyncOperationID
        ) else { return false }
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ) else { return false }
        publishChatResumeRestorationIfReady(
            automaticWorkToken: automaticWorkToken,
            automaticSyncOperationID: automaticSyncOperationID
        )
        cancelScheduledReconnect()
        recoverySequence.complete()
        if automaticWorkToken != nil {
            activeAutomaticChatResumeWork = nil
        }
        return true
    }

    @discardableResult
    private func reconcile(
        sessionId: String,
        using client: HermesClient,
        token: UUID,
        acceptedSessionIDs: Set<String> = [],
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil,
        requiredViewportTransitionGeneration: UInt64? = nil
    ) async -> Bool {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ), chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration) else {
            return false
        }
        let priorReconciliation = reconciliation?.token == token ? reconciliation : nil
        let bufferedEvents = priorReconciliation?.bufferedEvents ?? []
        reconciliation = Reconciliation(
            token: token,
            requestedSessionId: sessionId,
            automaticSyncOperationID: automaticSyncOperationID,
            acceptedSessionIDs: acceptedSessionIDs.union([sessionId]),
            streamTextAtBoundary: priorReconciliation?.streamTextAtBoundary,
            streamSessionIDAtBoundary: priorReconciliation?.streamSessionIDAtBoundary,
            bufferedEvents: bufferedEvents
        )
        refreshActiveChatScrollSessionIdentity(isReconciling: true)
        turnState = .synchronizing
        let profile = activeProfile
        // The resume RPC can overlap a user-initiated config.set. Capture the
        // local-write position before launching either request so a response
        // from the older snapshot cannot clear the newer override.
        let yoloWriteBaseline = sessionYoloWriteBaseline(for: sessionId)

        do {
            // Match Hermes Desktop: fetch the durable transcript and resume the
            // live runtime concurrently. The compact resume (`omit_messages`)
            // keeps the whole persisted transcript out of the WebSocket
            // response; the HTTP endpoint reads the timestamped rows from
            // state.db and hydrates the conversation instead.
            let bridge = dashboardTicketBridge
            // Prefer the compact projection whenever a history source exists
            // to hydrate the transcript — the dashboard bridge, or a test seam
            // standing in for one. A cold bridge does not change the flavor:
            // requestJSON's bounded readiness poll (30 × 100 ms) waits for the
            // page inside the concurrent transcript fetch, so the compact
            // resume is never delayed by that wait, and a bridge still not
            // usable afterwards degrades to the single legacy resume. The
            // legacy resume — cold bridge, gateway without the history route —
            // carries the transcript in the RPC response, whose size is
            // bounded by the socket limit (the pre-compact behavior).
            let compactResume = chatResumeLifecycleOperations.persistedTranscript != nil || bridge != nil
            async let resumedSession = openChatResumeSession(
                sessionId,
                using: client,
                compact: compactResume
            )
            async let transcriptOutcome = persistedTranscriptOutcome(
                sessionId: sessionId,
                profile: profile,
                using: bridge
            )

            var result = try await resumedSession
            var transcript: PersistedSessionTranscript?
            if compactResume {
                switch await transcriptOutcome {
                case .hydrated(let persisted):
                    // The endpoint may resolve a runtime ID to its stored
                    // session ID; only rows belonging to this session may
                    // hydrate the transcript. A foreign identity means the
                    // history source is unusable for this resume — request
                    // the transcript through the resume RPC instead.
                    if transcriptMatchesSession(
                        persisted,
                        requestedSessionId: sessionId,
                        resumedSessionId: result.sessionId
                    ) {
                        transcript = persisted
                    } else {
                        result = try await openChatResumeSession(
                            sessionId,
                            using: client,
                            compact: false
                        )
                    }
                case .unavailable:
                    // No usable history source (missing bridge, or a gateway
                    // predating the messages endpoint): re-resume carrying
                    // the transcript, exactly as pre-compact builds did.
                    result = try await openChatResumeSession(
                        sessionId,
                        using: client,
                        compact: false
                    )
                case .failed(let error):
                    // An unrelated history failure must not be papered over by
                    // a legacy resume that would hide it: surface it instead.
                    throw error
                }
            }
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticSyncOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                chatResumeCoordinator.abandonPendingAutomaticSync()
                return false
            }

            var context = reconciliation
            context?.resolvedSessionId = result.sessionId
            context?.acceptedSessionIDs.insert(result.sessionId)
            reconciliation = context
            refreshActiveChatScrollSessionIdentity(isReconciling: true)

            // Do not replace a live/in-flight projection with a database read
            // that may be a few events behind. Once the turn is settled, the
            // persisted transcript is the exact Desktop source for timestamps,
            // tool previews, and completed response content.
            let transcriptMatches = transcript.map {
                transcriptMatchesSession(
                    $0,
                    requestedSessionId: sessionId,
                    resumedSessionId: result.sessionId
                )
            } ?? false

            // Capture the pre-reconcile transcript and window for the graft
            // decision below before either is replaced. The window write
            // itself happens after the graft: whether the refreshed tail
            // grafted onto the backfilled prefix determines whether the
            // prefix-preservation fact survives into the refreshed window.
            let previousTranscriptMessages = messages
            let priorWindow = persistedTranscriptWindow
            if let transcript, transcriptMatches, result.snapshot.hasLiveProjection, !transcript.messages.isEmpty {
                // Desktop keeps its live projection during an active turn. Seed
                // the same durable presentation details first so the completed
                // portion of a backgrounded turn does not lose its timestamps.
                sessionPresentationCache.save(
                    transcript.messages,
                    profile: profile,
                    sessionIDs: [sessionId, result.sessionId, transcript.resolvedSessionId].compactMap { $0 }
                )
            }
            // A compact resume ships no persisted transcript, so the REST rows
            // are the durable base even while a turn is live: the in-flight
            // projection rides on top through the streaming bubble, matching
            // Desktop's cache-as-base rendering. A resume that carried
            // messages keeps the historical precedence where a live projection
            // wins over the REST read.
            let resumeCarriedTranscript = !result.messages.isEmpty
            let shouldUsePersistedTranscript = transcriptMatches
                && (transcript.map { !$0.messages.isEmpty || !resumeCarriedTranscript } ?? false)
                && (!result.snapshot.hasLiveProjection || !resumeCarriedTranscript)
            let priorWindowForGraft = priorWindowOwnsThisConversation(
                priorWindow,
                requestedSessionId: sessionId,
                resolvedSessionId: transcript?.resolvedSessionId,
                runtimeSessionId: result.sessionId,
                profile: profile
            ) ? priorWindow : nil
            let presentationResult: SessionResumeResult
            var graftedBackfilledPrefix = false
            if let transcript, shouldUsePersistedTranscript {
                // A re-reconciliation replaces only the newest page. Keep
                // everything "Load earlier messages" already backfilled by
                // re-anchoring the refreshed tail onto the older prefix;
                // without this, any reconnect during a browsed long session
                // would silently truncate the visible history back to one
                // page. The graft must survive REPEATED reconciles — the
                // explicit hasBackfilledPrefix flag carries that fact, since
                // the network coverage reset below erases the offset
                // evidence after the first one.
                let grafted = PersistedTranscriptWindow.grafting(
                    refreshedTail: transcript.messages,
                    ontoBackfilled: previousTranscriptMessages,
                    window: priorWindowForGraft
                )
                presentationResult = SessionResumeResult(
                    sessionId: result.sessionId,
                    messages: grafted.messages,
                    snapshot: result.snapshot
                )
                graftedBackfilledPrefix = grafted.grafted
            } else {
                presentationResult = result
            }

            // Persisted-history window bookkeeping. The window describes the
            // REST-fetched display history only — runtime state above is
            // untouched. A pagination echo carrying the `order=latest` tail
            // contract opens the bounded window; a legacy one-shot hydration
            // (or a hydration that failed the session-identity gate) leaves
            // no window, because no older page exists to fetch. A graft that
            // kept the backfilled prefix preserves that fact; a refreshed
            // tail with no safe anchor is authoritative and resets it.
            //
            // The refresh resets coverage to the fetched page even when the
            // graft kept older rows. The next backfills then retrace
            // the backfilled prefix in page-sized increments, each deduped
            // against held rows, until coverage catches up — harmless
            // duplicate requests that self-correct, never gaps. Under-
            // counting is the safe direction: trusting the prior coverage
            // after a server-side rewrite could silently skip rows. A
            // conversation that was already fully backfilled re-lights the
            // affordance once and re-retires on its first terminal page.
            if let transcript, transcriptMatches, let page = transcript.page,
               page.honorsTailContract {
                // The window records EVERY identity the accepted
                // transaction produced — requested, resolved stored, and
                // runtime — so ownership stays self-contained even before
                // the session catalog learns the runtime↔stored alias.
                persistedTranscriptWindow = PersistedTranscriptWindowState(
                    requestedSessionID: sessionId,
                    profile: profile,
                    pageSize: PersistedTranscriptPagination.pageSize,
                    resolvedSessionID: transcript.resolvedSessionId,
                    runtimeSessionID: result.sessionId,
                    nextOffset: page.rawReturned,
                    canLoadEarlier: page.mayHaveOlderRows(fetchedRowCount: page.rawReturned),
                    hasBackfilledPrefix: graftedBackfilledPrefix
                )
            } else {
                persistedTranscriptWindow = nil
            }

            let resumeSessionIDs = [result.sessionId, reconciliation?.requestedSessionId]
                .compactMap { $0 }
            let reconcileExplicitYolo = !hasNewerSessionYoloWrite(
                since: yoloWriteBaseline,
                sessionIDs: resumeSessionIDs
            )

            guard applyChatResume(
                presentationResult,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticSyncOperationID
            ) else {
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                return false
            }
            await refreshChatResumeContext(sessionId: result.sessionId, using: client)

            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticSyncOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                return false
            }

            var bufferedEvents = reconciliation?.token == token
                ? (reconciliation?.bufferedEvents ?? []).filter {
                    reconciliation?.accepts(sessionID(for: $0)) == true
                }
                : []
            if result.snapshot.hasLiveProjection {
                let resumedInflightText = streamingBuffer
                let boundary = reconciliation?.token == token ? reconciliation : nil
                let acceptedSessionIDs: Set<String>
                if let boundary,
                   let boundarySessionID = boundary.streamSessionIDAtBoundary {
                    // Do not infer that a newly returned runtime ID belongs
                    // to this boundary solely because the resume RPC returned
                    // it. Keep only IDs already accepted for the boundary and
                    // known as aliases of that catalog session; an empty
                    // result intentionally disables deduplication rather than
                    // risking text from a different session.
                    acceptedSessionIDs = boundary.acceptedSessionIDs.intersection(
                        knownSessionIDs(for: boundarySessionID)
                    )
                    if !acceptedSessionIDs.contains(result.sessionId) {
                        sessionCatalogLog.debug(
                            "Skipping buffered delta dedup because resumed session \(result.sessionId, privacy: .public) is not a catalog-confirmed alias of the reconciliation boundary"
                        )
                    }
                } else {
                    acceptedSessionIDs = [result.sessionId]
                }
                let knownPrefix: String?
                let coveredText: String?
                if let boundary {
                    knownPrefix = Self.normalizedReconciliationBoundaryPrefix(
                        boundaryText: boundary.streamTextAtBoundary,
                        boundarySessionID: boundary.streamSessionIDAtBoundary,
                        resumedSessionID: result.sessionId,
                        acceptedSessionIDs: acceptedSessionIDs,
                        after: messages
                    )
                    coveredText = Self.reconciliationBoundaryCoverageText(
                        boundaryText: boundary.streamTextAtBoundary,
                        boundarySessionID: boundary.streamSessionIDAtBoundary,
                        resumedSessionID: result.sessionId,
                        acceptedSessionIDs: acceptedSessionIDs,
                        snapshotInflightText: result.snapshot.inflightAssistantText,
                        after: messages
                    )
                } else {
                    knownPrefix = nil
                    coveredText = nil
                }

                // The live bubble was just seeded from the cumulative inflight
                // projection, which already includes deltas emitted while this
                // reconciliation was in flight. Replay only the portion beyond
                // the normalized text captured at the same session boundary.
                bufferedEvents = Self.deduplicatingBufferedEvents(
                    bufferedEvents,
                    againstInflight: resumedInflightText,
                    knownPrefix: knownPrefix,
                    sessionID: result.sessionId,
                    acceptedSessionIDs: acceptedSessionIDs,
                    coveredText: coveredText,
                    hasBoundaryAnchor: boundary?.streamTextAtBoundary?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty == false
                )
            }
            let bufferedYoloAuthority = reconcileExplicitYolo ? result.snapshot.yolo : nil
            // The approval mode is profile-scoped and independent of the
            // per-session YOLO write gate: a user toggle during the resume must
            // not let a stale buffered event re-impose an outdated floor.
            let bufferedApprovalsModeAuthority = result.snapshot.approvalsMode
            bufferedEvents.forEach { event in
                applyStreamEvent(
                    event,
                    authoritativeYolo: bufferedYoloAuthority,
                    authoritativeApprovalsMode: bufferedApprovalsModeAuthority
                )
            }
            let settled = settleReconciliationAndPublish(
                token,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticSyncOperationID
            )
            if settled, reconcileExplicitYolo {
                // Re-assert only after the ownership guard above (token,
                // profile, client) re-validated this reconciliation and after
                // the synchronous settle, so a profile or client switch during
                // the suspending context refresh above cannot push a stale
                // write through the old client for the old profile's session.
                // A user YOLO write that completed since the resume began
                // already pushed the server, so skip instead of duplicating
                // it; one still in flight is skipped inside
                // reassertSessionYolo. The mid-RPC race is accepted: the value
                // was chosen under verified ownership, and the next resume
                // reconciles.
                await reassertSessionYolo(
                    for: result.sessionId,
                    snapshot: result.snapshot,
                    using: client
                )
            }
            return settled

        } catch {
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticSyncOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                return false
            }
            turnState = .reconnecting
            switch error {
            case is LegacyTranscriptOversizedError, DashboardTicketBridgeError.oversizedResponse:
                // Oversized history responses carry their own user-facing
                // copy: the legacy compatibility message for an old backend
                // attempting the whole transcript, neutral copy for a
                // bounded current-Hermes page with one enormous row (which
                // must not claim the backend lacks pagination).
                errorMessage = error.localizedDescription
            default:
                errorMessage = "Failed to restore this conversation: \(error.localizedDescription)"
            }
            settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
            chatResumeCoordinator.abandonPendingAutomaticSync()
            return false
        }
    }

    private func openChatResumeSession(
        _ sessionID: String,
        using client: HermesClient,
        compact: Bool
    ) async throws -> SessionResumeResult {
        if let openSession = chatResumeLifecycleOperations.openSession {
            return try await openSession(client, sessionID, compact)
        }
        if compact {
            return try await client.openSession(sessionID)
        }
        return try await client.openSessionLegacy(sessionID)
    }

    private func refreshChatResumeContext(
        sessionId: String,
        using client: HermesClient
    ) async {
        if let refreshContext = chatResumeLifecycleOperations.refreshContext {
            await refreshContext(client, sessionId)
        } else {
            await refreshContextUsage(sessionId: sessionId, using: client)
        }
    }

    private func createAndReconcileSession(
        using client: HermesClient,
        profile: String,
        token: UUID,
        resumePurpose: ChatResumeSyncPurpose = .preserveCurrent,
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil,
        requiredViewportTransitionGeneration: UInt64? = nil,
        cwd: String? = nil
    ) async {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ), chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration) else { return }
        do {
            let created = try await client.createSession(
                model: runtime.model.isEmpty ? nil : runtime.model,
                provider: runtime.provider.isEmpty ? nil : runtime.provider,
                cwd: cwd
            )
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticSyncOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                chatResumeCoordinator.abandonPendingAutomaticSync()
                return
            }
            if let returnedProfile = created.profile,
               !profilesMatch(returnedProfile, profile) {
                turnState = .idle
                errorMessage = "Hermes created this conversation in \(profileDisplayName(returnedProfile)), not \(profileDisplayName(profile)). It was not opened."
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                chatResumeCoordinator.abandonPendingAutomaticSync()
                await loadSessions(forceRefresh: true)
                return
            }
            let runtimeSessionID = created.sessionId.isEmpty ? (created.storedSessionId ?? "") : created.sessionId
            guard !runtimeSessionID.isEmpty else {
                turnState = .idle
                errorMessage = "Hermes created a conversation without a session ID."
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                chatResumeCoordinator.abandonPendingAutomaticSync()
                return
            }

            // `session.create` already returns the active runtime session.
            // Some Hermes versions do not make its history-resume record
            // available immediately, so resuming here races the persistence
            // layer and leaves the composer stuck synchronizing.
            markChatViewportReplacement()
            setActiveSessionState(id: runtimeSessionID, title: "New conversation")
            messages = []
            persistedTranscriptWindow = nil
            noteChatViewportTranscriptReplacement()
            clearStreamingText()
            activeAssistantMessageId = nil
            resetReasoningTurn()
            turnState = .idle
            errorMessage = nil
            // A fresh conversation has no per-session override and no
            // server-reported flag yet; re-resolve from the profile mode
            // (still valid — it is profile-scoped) so the new chat does not
            // inherit the previous session's effective indicator until the
            // first snapshot arrives.
            lastReportedSessionYolo = nil
            if runtime.approvalsMode != nil {
                applyEffectiveYolo(
                    sessionIDsForOverride: [runtimeSessionID],
                    snapshotYolo: nil,
                    snapshotReportedApprovalsMode: runtime.approvalsMode
                )
            } else {
                runtime.yolo = false
            }

            let storedID = created.storedSessionId ?? runtimeSessionID
            let summary = SessionSummary(
                id: storedID,
                alternateIds: [runtimeSessionID, created.storedSessionId]
                    .compactMap { $0 }
                    .filter { $0 != storedID },
                title: activeSessionTitle,
                model: runtime.model.isEmpty ? "Hermes" : runtime.model,
                updatedLabel: "now",
                profile: activeProfile,
                source: .chat,
                isActive: true,
                isArchived: false,
                lineageRootId: nil
            )
            sessions = [summary] + sessions.map { existing in
                var updated = existing
                updated.isActive = false
                return updated
            }
            if resumePurpose == .automaticReturn {
                _ = selectChatResumeTarget(
                    in: [summary],
                    profile: profile,
                    purpose: resumePurpose,
                    currentSessionID: runtimeSessionID,
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticSyncOperationID
                )
            }
            Task { [weak self] in
                guard let self,
                      self.activeProfile == profile,
                      self.activeSessionId == runtimeSessionID else { return }
                await self.loadSlashCommands()
                await self.loadSessions()
            }
            settleReconciliationAndPublish(
                token,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticSyncOperationID
            )
        } catch {
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticSyncOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                return
            }
            turnState = .idle
            errorMessage = "Failed to create session: \(error.localizedDescription)"
            settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
            chatResumeCoordinator.abandonPendingAutomaticSync()
            if resumePurpose == .automaticReturn {
                scheduleReconnect(purpose: resumePurpose)
            }
        }
    }

    @discardableResult
    func applyChatResume(
        _ result: SessionResumeResult,
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil
    ) -> Bool {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ) else { return false }
        let retainedRestoredMessages = pendingDecisionRestorationMessages(for: result.sessionId)
        markChatViewportReplacement()
        setActiveSessionState(id: result.sessionId, title: "New conversation")
        updateActiveSessionTitle(
            for: result.sessionId,
            fallbackSessionId: reconciliation?.requestedSessionId
        )
        // Pending clarifications and approvals are user-actionable decision
        // events, not merely projections of the gateway's current turn state.
        // Hermes can omit a one-shot decision event from a resume, and
        // `running == false` can describe the preceding text even while the
        // decision remains unresolved. Restore both card types independently
        // of the turn snapshot; the gateway decision key remains authoritative
        // when it includes a resolved record.
        let restorePendingDecisionCards = true
        let sessionIDs = [result.sessionId, reconciliation?.requestedSessionId].compactMap { $0 }
        let gatewayDecisionKeys = Set(result.messages.compactMap(SessionPresentationCache.decisionKey(for:)))
        let retainedMessages = retainedRestoredMessages.filter { message in
            guard let key = SessionPresentationCache.decisionKey(for: message),
                  !gatewayDecisionKeys.contains(key) else {
                return false
            }
            return restorePendingDecisionCards
        }
        let restored = sessionPresentationCache.merge(
            result.messages + retainedMessages,
            profile: activeProfile,
            sessionIDs: sessionIDs,
            includePendingClarifications: restorePendingDecisionCards,
            includePendingApprovals: restorePendingDecisionCards
        )
        messages = mergeCachedReviews(into: restored, sessionId: result.sessionId)
        noteChatViewportTranscriptReplacement()
        let gatewayPendingDecisionKeys = SessionPresentationCache.pendingDecisionKeys(in: result.messages)
        let restoredPendingDecisionKeys = SessionPresentationCache
            .pendingDecisionKeys(in: messages)
            .subtracting(gatewayPendingDecisionKeys)
        let gatewayHasPendingDecision = !gatewayPendingDecisionKeys.isEmpty
        var restoredMessagesAwaitingConfirmation: [ChatMessage] = []
        if result.snapshot.running != true && !restoredPendingDecisionKeys.isEmpty {
            Self.resetSubmittingRestoredDecisions(
                in: &messages,
                matching: restoredPendingDecisionKeys
            )
            restoredMessagesAwaitingConfirmation = messages.filter {
                guard let key = SessionPresentationCache.decisionKey(for: $0),
                      restoredPendingDecisionKeys.contains(key) else {
                    return false
                }
                return SessionPresentationCache.pendingDecisionKey(for: $0) != nil
            }
        } else {
            clearPendingDecisionRestorationGuard()
        }
        let hasPendingDecision = Self.hasPendingDecision(in: messages)
        // Persist the gateway transcript on every resume so fresh rows are not
        // lost. A locally restored card remains in the active AppState for the
        // next foreground cycle. Any pending decision observed without an
        // explicit active-turn signal is persisted with a bounded unconfirmed
        // marker. The marker is intentionally independent from
        // `gatewayConfirmsActiveTurn`: an ambiguous resume may contain a
        // gateway-provided card that still needs the same stale-card guard.
        let gatewayConfirmsActiveTurn = result.snapshot.running == true
            || (result.snapshot.running != false && gatewayHasPendingDecision)
        let unconfirmedPendingDecisionKeys = result.snapshot.running != true
            ? SessionPresentationCache.pendingDecisionKeys(in: messages)
            : []
        let shouldPersistMergedPresentation = gatewayConfirmsActiveTurn
            || !unconfirmedPendingDecisionKeys.isEmpty
        sessionPresentationCache.save(
            shouldPersistMergedPresentation ? messages : result.messages,
            profile: activeProfile,
            sessionIDs: sessionIDs,
            preservePendingDecisionCards: gatewayConfirmsActiveTurn || !unconfirmedPendingDecisionKeys.isEmpty,
            unconfirmedPendingDecisionKeys: unconfirmedPendingDecisionKeys
        )
        if result.snapshot.running != true && !restoredPendingDecisionKeys.isEmpty {
            let restoredAt = sessionPresentationCache.unconfirmedPendingDecisionDate(
                profile: activeProfile,
                sessionIDs: sessionIDs
            ) ?? Date()
            restoredPendingDecisionCardsAwaitingConfirmation = PendingDecisionRestorationGuard(
                profile: activeProfile,
                sessionID: result.sessionId,
                pendingDecisionKeys: restoredPendingDecisionKeys,
                restoredAt: restoredAt,
                messages: restoredMessagesAwaitingConfirmation
            )
        }
        scheduleSecondaryProfileTitleRecovery(
            sessionId: result.sessionId,
            messages: messages
        )
        clearStreamingText()
        if result.snapshot.hasLiveProjection {
            let recoveredText = Self.unpersistedInflightAssistantText(
                result.snapshot.inflightAssistantText,
                after: messages
            )
            streamingBuffer = recoveredText
            streamingText = recoveredText
        }
        activeAssistantMessageId = nil
        resetReasoningTurn()
        applyRuntime(
            result.snapshot,
            for: result.sessionId
        )

        // An omitted running state is ambiguous while a decision or live
        // projection is present, but an explicit false is authoritative: the
        // session is idle even when a pending card remains answerable.
        if result.snapshot.running == nil && (result.snapshot.hasLiveProjection || hasPendingDecision) {
            turnState = .running
        } else if TurnState.fromGatewayRunning(result.snapshot.running) == .unsupportedGateway {
            turnState = .unsupportedGateway
            errorMessage = "This Hermes gateway must support session turn state. Update Hermes to enable message, stop, and steer controls."
            return true
        } else {
            turnState = TurnState.fromGatewayRunning(result.snapshot.running)
        }
        // The resume snapshot is authoritative about the turn state.
        turnStateIsStale = false
        return true
    }

    static func hasPendingDecision(in messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            let clarifyPending = message.clarify?.status == .pending || message.clarify?.status == .submitting
            let approvalPending = message.approval?.status == .pending || message.approval?.status == .submitting
            return clarifyPending || approvalPending
        }
    }

    private static func resetSubmittingRestoredDecisions(
        in messages: inout [ChatMessage],
        matching keys: Set<String>
    ) {
        for index in messages.indices {
            if var clarify = messages[index].clarify,
               clarify.status == .submitting,
               let key = SessionPresentationCache.decisionKey(for: messages[index]),
               keys.contains(key) {
                clarify.status = .pending
                clarify.answer = nil
                clarify.error = nil
                messages[index].clarify = clarify
            }
            if var approval = messages[index].approval,
               approval.status == .submitting,
               let key = SessionPresentationCache.decisionKey(for: messages[index]),
               keys.contains(key) {
                approval.status = .pending
                approval.choice = nil
                approval.error = nil
                messages[index].approval = approval
            }
        }
    }

    /// Deltas buffered while reconciliation ran are usually already contained
    /// in the resume snapshot's cumulative `inflight` projection — replaying
    /// them on top of the seeded live bubble repeats that text. When the exact
    /// stream text at the matching session boundary is known, consume only the
    /// corresponding span of the buffered deltas. Edge whitespace is ignored
    /// consistently with resume seeding, and the raw covered count preserves
    /// event order when deltas carry that whitespace. Interior whitespace is
    /// not rewritten: a mismatch may be real content, so leave it intact.
    /// Without a matching boundary or session, repeated text is ambiguous, so
    /// leave events intact.
    nonisolated static func normalizedReconciliationBoundaryPrefix(
        boundaryText: String?,
        boundarySessionID: String?,
        resumedSessionID: String,
        acceptedSessionIDs: Set<String>,
        after messages: [ChatMessage]
    ) -> String? {
        guard let boundaryText,
              let boundarySessionID,
              !boundarySessionID.isEmpty,
              acceptedSessionIDs.contains(boundarySessionID),
              acceptedSessionIDs.contains(resumedSessionID) else {
            return nil
        }
        return unpersistedInflightAssistantText(boundaryText, after: messages)
    }

    nonisolated static func reconciliationBoundaryCoverageText(
        boundaryText: String?,
        boundarySessionID: String?,
        resumedSessionID: String,
        acceptedSessionIDs: Set<String>,
        snapshotInflightText: String,
        after messages: [ChatMessage]
    ) -> String? {
        guard let boundaryText,
              let boundarySessionID,
              !boundarySessionID.isEmpty,
              acceptedSessionIDs.contains(boundarySessionID),
              acceptedSessionIDs.contains(resumedSessionID) else {
            return nil
        }

        let normalizedBoundaryText = boundaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSnapshotText = snapshotInflightText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedSnapshotText.hasPrefix(normalizedBoundaryText) {
            return String(normalizedSnapshotText.dropFirst(normalizedBoundaryText.count))
        }

        let normalizedUnpersistedBoundary = unpersistedInflightAssistantText(
            boundaryText,
            after: messages
        )
        let normalizedUnpersistedSnapshot = unpersistedInflightAssistantText(
            snapshotInflightText,
            after: messages
        )
        guard normalizedUnpersistedSnapshot.hasPrefix(normalizedUnpersistedBoundary) else {
            return nil
        }
        return String(
            normalizedUnpersistedSnapshot.dropFirst(normalizedUnpersistedBoundary.count)
        )
    }

    nonisolated static func deduplicatingBufferedEvents(
        _ events: [StreamEvent],
        againstInflight inflight: String,
        knownPrefix: String?,
        sessionID: String,
        acceptedSessionIDs: Set<String> = [],
        coveredText explicitCoveredText: String? = nil,
        hasBoundaryAnchor: Bool = false
    ) -> [StreamEvent] {
        let coveredText: String
        if let explicitCoveredText {
            guard let knownPrefix else { return events }
            let normalizedInflight = inflight.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedKnownPrefix = knownPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedInflight.hasPrefix(normalizedKnownPrefix) else {
                return events
            }
            let expectedCoveredText = String(
                normalizedInflight.dropFirst(normalizedKnownPrefix.count)
            )
            let normalizedExplicitCoveredText = explicitCoveredText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let explicitCoverageOverlapsSeededText = Self.suffixPrefixOverlapLengths(
                covered: normalizedExplicitCoveredText,
                buffered: expectedCoveredText
            )
            guard !expectedCoveredText.isEmpty,
                  explicitCoverageOverlapsSeededText.count == 1 else {
                return events
            }
            coveredText = explicitCoveredText
        } else {
            guard let knownPrefix else { return events }
            if inflight.hasPrefix(knownPrefix) {
                coveredText = String(inflight.dropFirst(knownPrefix.count))
            } else {
                let normalizedInflight = inflight.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedKnownPrefix = knownPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalizedInflight.hasPrefix(normalizedKnownPrefix) else {
                    return events
                }
                coveredText = String(
                    normalizedInflight.dropFirst(normalizedKnownPrefix.count)
                )
            }
        }
        let normalizedCoveredText = coveredText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCoveredText.isEmpty else { return events }

        let bufferedDeltaTexts = events.compactMap { event in
            if case .messageDelta(_, let text) = event {
                return text
            }
            return nil
        }
        guard !bufferedDeltaTexts.isEmpty else { return events }

        let deltaSessionIDs = Set(events.compactMap { event in
            if case .messageDelta(let sessionId, _) = event {
                return sessionId
            }
            return nil
        })
        let allowedSessionIDs = acceptedSessionIDs.isEmpty
            ? Set([sessionID])
            : acceptedSessionIDs
        guard deltaSessionIDs.count == 1,
              let deltaSessionID = deltaSessionIDs.first,
              allowedSessionIDs.contains(deltaSessionID) else {
            return events
        }

        if let newTurnIndex = events.firstIndex(where: { event in
            guard case .messageStart(let startSessionID) = event else { return false }
            return allowedSessionIDs.contains(startSessionID)
        }) {
            // A message start observed after the reconciliation boundary is
            // an explicit new-turn marker. Deduplicate any older buffered
            // events, but preserve the marker and everything after it because
            // the same text can be fresh content from the new turn.
            let eventsBeforeNewTurn = Array(events[..<newTurnIndex])
            let eventsAfterNewTurn = Array(events[newTurnIndex...])
            return deduplicatingBufferedEvents(
                eventsBeforeNewTurn,
                againstInflight: inflight,
                knownPrefix: knownPrefix,
                sessionID: sessionID,
                acceptedSessionIDs: acceptedSessionIDs,
                coveredText: explicitCoveredText,
                hasBoundaryAnchor: hasBoundaryAnchor
            ) + eventsAfterNewTurn
        }

        guard hasBoundaryAnchor else {
            // Content equality cannot distinguish a fresh turn that happens
            // to repeat the snapshot. Without a non-empty stream boundary (or
            // the explicit message-start marker above), preserve the events
            // rather than risking loss of genuinely new text.
            return events
        }

        let bufferedDeltaText = bufferedDeltaTexts.joined()
        let normalizedBufferedDeltaText = bufferedDeltaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBufferedDeltaText.isEmpty else { return events }

        let coveredRawCharacters: Int
        if normalizedBufferedDeltaText == normalizedCoveredText {
            coveredRawCharacters = bufferedDeltaText.count
        } else if normalizedBufferedDeltaText.hasPrefix(normalizedCoveredText) {
            let leadingWhitespaceCount = bufferedDeltaText.prefix { $0.isWhitespace }.count
            let coveredEnd = leadingWhitespaceCount + normalizedCoveredText.count
            let coveredTrailingWhitespaceCount = coveredText.reversed().prefix { $0.isWhitespace }.count
            let bufferedTrailingWhitespaceCount = bufferedDeltaText.dropFirst(coveredEnd)
                .prefix { $0.isWhitespace }
                .count
            coveredRawCharacters = coveredEnd + min(
                coveredTrailingWhitespaceCount,
                bufferedTrailingWhitespaceCount
            )
        } else if normalizedCoveredText.hasPrefix(normalizedBufferedDeltaText) {
            coveredRawCharacters = bufferedDeltaText.count
        } else {
            let overlaps = Self.suffixPrefixOverlapLengths(
                covered: normalizedCoveredText,
                buffered: normalizedBufferedDeltaText
            )
            guard overlaps.count == 1, let overlap = overlaps.first else {
                // Repeated content can produce multiple valid alignments. A
                // content-only guess could consume genuinely new text, so
                // preserve the events when the offset is ambiguous.
                return events
            }
            let leadingWhitespaceCount = bufferedDeltaText.prefix { $0.isWhitespace }.count
            coveredRawCharacters = leadingWhitespaceCount + overlap
        }

        var remainingCoverage = coveredRawCharacters
        var deduplicated: [StreamEvent] = []
        deduplicated.reserveCapacity(events.count)
        for event in events {
            guard case .messageDelta(let sessionId, let text) = event else {
                deduplicated.append(event)
                continue
            }
            guard remainingCoverage > 0 else {
                deduplicated.append(event)
                continue
            }

            let consumed = min(remainingCoverage, text.count)
            guard consumed > 0 else {
                deduplicated.append(event)
                continue
            }
            remainingCoverage -= consumed
            let remainder = String(text.dropFirst(consumed))
            if !remainder.isEmpty {
                deduplicated.append(.messageDelta(sessionId: sessionId, text: remainder))
            }
        }
        return deduplicated
    }

    /// Returns every non-empty prefix of `buffered` that is also a suffix of
    /// `covered`. The prefix-function scan stays linear in the cumulative
    /// projection size; callers can reject repeated-content ambiguity when
    /// more than one alignment is possible.
    nonisolated static func suffixPrefixOverlapLengths(
        covered: String,
        buffered: String
    ) -> [Int] {
        let pattern = Array(buffered)
        guard !pattern.isEmpty, !covered.isEmpty else { return [] }

        var prefixLengths = Array(repeating: 0, count: pattern.count)
        var prefixLength = 0
        for index in 1..<pattern.count {
            while prefixLength > 0, pattern[index] != pattern[prefixLength] {
                prefixLength = prefixLengths[prefixLength - 1]
            }
            if pattern[index] == pattern[prefixLength] {
                prefixLength += 1
            }
            prefixLengths[index] = prefixLength
        }

        let text = Array(covered)
        var matched = 0
        var overlaps: [Int] = []
        for (index, character) in text.enumerated() {
            while matched > 0, pattern[matched] != character {
                matched = prefixLengths[matched - 1]
            }
            if pattern[matched] == character {
                matched += 1
            }
            if matched == pattern.count {
                if index == text.count - 1 {
                    overlaps.append(pattern.count)
                }
                matched = prefixLengths[matched - 1]
            }
        }

        while matched > 0 {
            overlaps.append(matched)
            matched = prefixLengths[matched - 1]
        }
        return overlaps
    }

    /// `session.resume.inflight` is a cumulative projection on some gateways.
    /// When its already-persisted prefix is also present in the recovered
    /// transcript, rendering it as the live bubble repeats the last reply.
    /// Keep only the unpersisted suffix so the next delta continues naturally.
    nonisolated static func unpersistedInflightAssistantText(
        _ inflight: String,
        after messages: [ChatMessage]
    ) -> String {
        let recovered = inflight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recovered.isEmpty,
              let persisted = messages.last(where: {
                  $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })?.content.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return recovered
        }

        if recovered == persisted || persisted.hasPrefix(recovered) {
            return ""
        }
        if recovered.hasPrefix(persisted) {
            return String(recovered.dropFirst(persisted.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return recovered
    }

    private func canonicalSessionID(for sessionID: String?) -> String? {
        ChatSessionPersistenceIdentity.canonicalID(
            for: sessionID,
            identity: activeChatScrollSessionIdentity,
            catalog: sessions + cronSessions,
            activeProfile: activeProfile
        )
    }

    /// Derives bookkeeping keys for an explicit profile. Callers must pass
    /// the profile that owns the state being tracked; nothing here consults
    /// mutable activeProfile.
    private func sessionYoloKeys(
        profile: String,
        sessionIDs: [String]
    ) -> Set<ChatScrollSessionKey> {
        var keys = Set<ChatScrollSessionKey>()
        for id in sessionIDs {
            let candidate = ChatScrollSessionKey(profile: profile, sessionID: id)
            if candidate.isValid { keys.insert(candidate) }
        }
        return keys
    }

    /// Current-state reads legitimately consult the active profile.
    private func sessionYoloKeysForCurrentProfile(
        sessionIDs: [String]
    ) -> Set<ChatScrollSessionKey> {
        sessionYoloKeys(profile: activeProfile, sessionIDs: sessionIDs)
    }

    private func sessionYoloWriteBaseline(for sessionID: String) -> SessionYoloWriteBaseline {
        let sessionIDs = [sessionID, canonicalSessionID(for: sessionID)].compactMap { $0 }
        let keys = sessionYoloKeysForCurrentProfile(sessionIDs: sessionIDs)
        return SessionYoloWriteBaseline(
            revisions: Dictionary(uniqueKeysWithValues: keys.map { key in
                (key, sessionYoloWriteRevisions[key] ?? 0)
            })
        )
    }

    private func hasNewerSessionYoloWrite(
        since baseline: SessionYoloWriteBaseline,
        sessionIDs: [String]
    ) -> Bool {
        sessionYoloKeysForCurrentProfile(sessionIDs: sessionIDs).contains { key in
            sessionYoloWriteRevisions[key, default: 0] > baseline.revisions[key, default: 0]
        }
    }

    private func recordSessionYoloWrite(for sessionIDs: [String]) {
        sessionYoloWriteRevision &+= 1
        for key in sessionYoloKeysForCurrentProfile(sessionIDs: sessionIDs) {
            sessionYoloWriteRevisions[key] = sessionYoloWriteRevision
        }
    }

    /// In-flight ownership is registered against explicit keys so the exact
    /// entries created at operation start are the ones cleanup removes -
    /// even when the active profile moved on while the RPC was suspended.
    /// The reference-counted map supports overlapping writes for the same
    /// session: each logical operation owns an independent registration, and
    /// cleanup only removes the key when the last reference is released.
    private func beginSessionYoloWrite(keys: Set<ChatScrollSessionKey>) {
        for key in keys {
            inFlightSessionYoloWriteCounts[key, default: 0] += 1
        }
    }

    private func endSessionYoloWrite(keys: Set<ChatScrollSessionKey>) {
        for key in keys {
            let remaining = inFlightSessionYoloWriteCounts[key, default: 0] - 1
            if remaining > 0 {
                inFlightSessionYoloWriteCounts[key] = remaining
            } else {
                inFlightSessionYoloWriteCounts.removeValue(forKey: key)
            }
        }
    }

#if DEBUG
    /// Test-only view of pending YOLO write ownership. Each entry maps a key
    /// to the number of active operations holding it; a non-empty dictionary
    /// after all operations settled means the bookkeeping leaked.
    var inFlightSessionYoloWriteCountsForTesting: [ChatScrollSessionKey: Int] {
        inFlightSessionYoloWriteCounts
    }
#endif

    private func hasInFlightSessionYoloWrite(sessionIDs: [String]) -> Bool {
        sessionYoloKeysForCurrentProfile(sessionIDs: sessionIDs).contains { key in
            (inFlightSessionYoloWriteCounts[key] ?? 0) > 0
        }
    }

    private func applyRuntime(
        _ snapshot: SessionRuntimeSnapshot,
        for sessionID: String? = nil,
        authoritativeYolo: Bool? = nil,
        authoritativeApprovalsMode: String? = nil
    ) {
        if let model = snapshot.model { runtime.model = model }
        if let provider = snapshot.provider { runtime.provider = provider }
        if let cwd = snapshot.cwd { runtime.cwd = cwd }
        if let percent = snapshot.contextPercent { runtime.contextPercent = normalizedContextPercent(percent, used: snapshot.contextUsed, max: snapshot.contextMax) }
        if let used = snapshot.contextUsed { runtime.contextUsed = used }
        if let max = snapshot.contextMax { runtime.contextMax = max }
        if let count = snapshot.activeAgents { activeAgents = count }
        if let reasoningEffort = snapshot.reasoningEffort {
            runtime.reasoningEffort = reasoningEffort.lowercased() == "none" ? "" : reasoningEffort
        }
        if let fast = snapshot.fast { runtime.fast = fast }
        if let approvalsMode = authoritativeApprovalsMode ?? snapshot.approvalsMode {
            runtime.approvalsMode = approvalsMode
        }
        if let reportedYolo = authoritativeYolo ?? snapshot.yolo {
            lastReportedSessionYolo = reportedYolo
        }
        let requestedSessionID = sessionID ?? activeSessionId
        let resolvedCanonicalSessionID = canonicalSessionID(for: requestedSessionID)
        let sessionIDsForOverride = [resolvedCanonicalSessionID, requestedSessionID]
            .compactMap { $0 }
        if let resolvedCanonicalSessionID,
           let requestedSessionID,
           resolvedCanonicalSessionID != requestedSessionID {
            sessionYoloStore.canonicalizeOverride(
                for: activeProfile,
                canonicalSessionID: resolvedCanonicalSessionID,
                aliases: [requestedSessionID]
            )
        }
        applyEffectiveYolo(
            sessionIDsForOverride: sessionIDsForOverride,
            snapshotYolo: authoritativeYolo ?? snapshot.yolo,
            snapshotReportedApprovalsMode: authoritativeApprovalsMode ?? snapshot.approvalsMode
        )
    }

    /// Resolve the effective session YOLO state from the current profile
    /// approval mode and the stored per-session override. Shared by
    /// `applyRuntime` (snapshot reconciliation) and the Settings save path so
    /// the indicator, the floor, and the Model Picker lock can never disagree
    /// with the saved mode.
    private func applyEffectiveYolo(
        sessionIDsForOverride: [String],
        snapshotYolo: Bool?,
        snapshotReportedApprovalsMode: String?
    ) {
        let storedOverride = sessionYoloStore.storedOverride(
            for: activeProfile,
            sessionIDs: sessionIDsForOverride
        )
        let globalYoloFloor = runtime.approvalsMode?.lowercased() == "off"
        if globalYoloFloor {
            // Hermes auto-approves globally when approvals.mode == "off"; a
            // per-session toggle cannot require approvals. Reflect the server's
            // effective state so the indicator does not claim otherwise.
            runtime.yolo = true
        } else if let storedOverride {
            // The per-session choice is authoritative. The gateway holds the
            // flag in memory only and forgets it on restart, so AppState
            // re-asserts it after resume (see reassertSessionYolo).
            runtime.yolo = storedOverride
        } else if let yolo = snapshotYolo {
            runtime.yolo = yolo
        } else if let mode = snapshotReportedApprovalsMode, mode.lowercased() != "off" {
            // Only the snapshot's own non-off mode report resolves to "approvals
            // apply" — a last-known mode with the signal omitted entirely is
            // unknown, not a disagreement, and must not flicker the indicator.
            runtime.yolo = false
        }
        // Otherwise keep the last-known indicator value; a partial projection
        // omitting the approval fields must not flicker it.
    }

    /// The context breakdown RPC is the gateway's complete accounting source.
    /// Session snapshots may omit it, or expose the percentage as a fraction.
    func refreshContextUsage() async {
        guard let client, let sessionId = activeSessionId else { return }
        await refreshContextUsage(sessionId: sessionId, using: client)
    }

    func applyContextBreakdown(_ breakdown: ContextBreakdown) {
        runtime.contextUsed = breakdown.resolvedUsed
        runtime.contextMax = breakdown.contextMax
        runtime.contextPercent = breakdown.resolvedPercent
    }

    private func refreshContextUsage(sessionId: String, using client: HermesClient) async {
        do {
            let breakdown = try await client.contextBreakdown(sessionId)
            guard self.client === client, activeSessionId == sessionId else { return }
            applyContextBreakdown(breakdown)
        } catch {
            // Context accounting is supplementary to chat recovery. Preserve
            // the latest stream/snapshot values when older gateways lack it.
        }
    }

    private func normalizedContextPercent(_ percent: Double, used: Int?, max: Int?) -> Double {
        if percent > 0 {
            let normalized = (0...1).contains(percent) ? percent * 100 : percent
            return min(Swift.max(normalized, 0), 100)
        }
        if let used, let capacity = max, capacity > 0 {
            return min(Swift.max((Double(used) / Double(capacity)) * 100, 0), 100)
        }
        return 0
    }

    // MARK: - Reconnect and scene lifecycle

    private func handleDisconnect() {
        let wasRunning = isBusy
        isConnected = false
        guard connection != nil else { return }
        turnState = .reconnecting

        if let connectedAt, Date().timeIntervalSince(connectedAt) > 10 {
            reconnectAttempts = 0
        }
        scheduleReconnect(
            immediately: wasRunning,
            purpose: chatResumePurposeForDisconnect()
        )
    }

    func scheduleReconnect(
        immediately: Bool = false,
        purpose: ChatResumeSyncPurpose = .preserveCurrent
    ) {
        guard connection != nil else { return }
        // A cycle scheduled while the scene is inactive can never run, so
        // don't arm a timer or consume the queued reconnect purpose just to
        // discard them when it fires. handleScenePhase(.active) establishes
        // the transport on return instead — and intentionally recovers with
        // .automaticReturn, upgrading the drop-time purpose, since resuming
        // the saved session on foreground is the expected outcome.
        guard isSceneActive else { return }
        if reconnectTask == nil {
            recoverySequence.clearQueuedReconnect()
        }
        let decision = planChatResumeReconnect(purpose: purpose)
        switch decision {
        case .keepExisting:
            return
        case .replace:
            reconnectTask?()
            reconnectTask = nil
        case .schedule:
            break
        }
        let delay = immediately ? 0.1 : min(5.0, pow(2.0, Double(reconnectAttempts)))
        // The backoff step is consumed only when the cycle actually runs.
        // A timer canceled by scene backgrounding — or a cycle dropped for
        // scene inactivity before execution — never counts as a gateway
        // failure, so background/foreground cycling cannot ratchet the
        // retry delay toward its cap without a real failure.
        let incrementsBackoff = !immediately

        reconnectTask = reconnectScheduler(delay) { [weak self] in
            guard let self else { return }
            self.reconnectTask = nil
            let purpose = self.recoverySequence.takeQueuedReconnectPurpose()
                ?? .preserveCurrent
            guard self.isSceneActive else { return }
            if incrementsBackoff { self.reconnectAttempts += 1 }
            await self.executeReconnect(purpose: purpose)
        }
    }

    func reconnect() async {
        cancelChatResumeTransportRecovery()
        await executeReconnect(purpose: .preserveCurrent)
    }

    private func executeReconnect(purpose: ChatResumeSyncPurpose) async {
        // A reconnect cycle mints a ticket, reloads the session catalog, and
        // mutates a series of @Published properties — each driving SwiftUI
        // transactions on the main thread. On a flaky link that churn can
        // saturate the main thread, and a backgrounded scene update then
        // misses its 10s watchdog deadline. Drop the attempt here instead;
        // handleScenePhase(.active) re-establishes the transport on return.
        // This also makes the public reconnect() a no-op while the scene is
        // inactive/backgrounded — the retry is picked up on the next .active.
        guard isSceneActive else { return }
        if let reconnectExecutor {
            await reconnectExecutor(purpose)
        } else {
            await reconnectForRetry(purpose: purpose)
        }
    }

    func reconnectForRetry(purpose requestedPurpose: ChatResumeSyncPurpose) async {
        guard let savedConnection = connection else { return }
        let purpose = beginChatResumeRecovery(purpose: requestedPurpose)
        let automaticWorkToken = purpose == .automaticReturn
            ? beginAutomaticChatResumeWork()
            : nil
        guard automaticChatResumeWorkIsCurrent(automaticWorkToken) else { return }
        let automaticOperationID = beginAutomaticReconnectOperation(for: automaticWorkToken)
        var continuationPurpose = purpose
        var continuationAutomaticWorkToken = automaticWorkToken
        var handedOffAutomaticIntent = false
        func refreshTransportContinuation() -> Bool {
            guard let continuation = transportContinuation(
                purpose: continuationPurpose,
                automaticWorkToken: continuationAutomaticWorkToken,
                automaticReconnectOperationID: automaticOperationID
            ) else { return false }
            continuationPurpose = continuation.purpose
            continuationAutomaticWorkToken = continuation.automaticWorkToken
            handedOffAutomaticIntent = handedOffAutomaticIntent
                || continuation.handedOffAutomaticIntent
            return true
        }
        defer {
            finishAutomaticReconnectOperation(
                id: automaticOperationID,
                restoringBaseline: !handedOffAutomaticIntent
                    && !automaticChatResumeWorkIsCurrent(
                        automaticWorkToken,
                        reconnectOperationID: automaticOperationID
                    )
            )
        }
        if purpose == .automaticReturn, reconnectTask != nil {
            cancelScheduledReconnect()
        }
        // The old socket died: turn edges may have been missed while the
        // transport was down. The sync this cycle runs will re-confirm the
        // state from the authoritative resume snapshot and clear the flag.
        turnStateIsStale = true
        isConnecting = true
        turnState = .reconnecting

        let connection: HermesConnection
        do {
            let ticket = try await mintChatResumeTicket(for: savedConnection)
            guard refreshTransportContinuation() else { return }
            connection = HermesConnection(baseUrl: savedConnection.baseUrl, ticket: ticket)
            self.connection = connection
            KeychainHelper.saveConnection(connection)
        } catch {
            guard refreshTransportContinuation() else { return }
            if let bridgeError = error as? DashboardTicketBridgeError, case .signInRequired = bridgeError {
                if let credentials = KeychainHelper.loadCredentials(),
                   credentials.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == savedConnection.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                    do {
                        let authenticatedConnection = try await NativeAuthClient(baseURL: credentials.baseURL, cloudflareAccess: KeychainHelper.loadCloudflareAccess(for: credentials.baseURL)).connect(
                            username: credentials.username,
                            password: credentials.password
                        )
                        guard refreshTransportContinuation() else { return }
                        authenticatedConnection.commitCookies()
                        // URLSession and WebKit have separate cookie stores.
                        // Reload the bridge so it receives the fresh session.
                        dashboardTicketBridge?.reload()
                        await connect(
                            with: HermesConnection(baseUrl: credentials.baseURL, ticket: authenticatedConnection.ticket),
                            profile: activeProfile,
                            syncPurpose: continuationPurpose,
                            cancelsResumeRestoration: false,
                            automaticWorkToken: continuationAutomaticWorkToken,
                            automaticReconnectOperationID: automaticOperationID
                        )
                        guard refreshTransportContinuation() else { return }
                        return
                    } catch {
                        guard refreshTransportContinuation() else { return }
                        // This only determines whether recovery can be silent.
                        // Preserve the saved credentials for the login screen.
                    }
                }
                guard refreshTransportContinuation() else { return }
                requireSignIn(message: error.localizedDescription)
            } else {
                guard refreshTransportContinuation() else { return }
                isConnected = false
                isConnecting = false
                turnState = .reconnecting
                errorMessage = "Failed to refresh the dashboard session: \(error.localizedDescription)"
                scheduleReconnect(purpose: continuationPurpose)
            }
            return
        }

        let previousClient = client
        guard refreshTransportContinuation() else { return }
        let profile = activeProfile
        let client = makeClient(connection: connection, profile: profile)
        self.client = client
        previousClient?.disconnect()

        do {
            try await connectChatResumeClient(client)
            guard refreshTransportContinuation(),
                  let activeClient = self.client, activeClient === client else { return }
            isConnected = true
            isConnecting = false
            reconnectAttempts = 0
            connectedAt = Date()
            guard let continuation = await synchronizeTransportContinuation(
                purpose: continuationPurpose,
                automaticWorkToken: continuationAutomaticWorkToken,
                automaticReconnectOperationID: automaticOperationID,
                client: client,
                profile: profile
            ) else { return }
            continuationPurpose = continuation.purpose
            continuationAutomaticWorkToken = continuation.automaticWorkToken
            handedOffAutomaticIntent = handedOffAutomaticIntent
                || continuation.handedOffAutomaticIntent
            await loadChatResumeBusyInputMode(using: client)
            guard refreshTransportContinuation(),
                  let activeClient = self.client, activeClient === client else { return }
            await loadChatResumeProfiles()
            guard refreshTransportContinuation(),
                  let activeClient = self.client, activeClient === client else { return }
            await loadChatResumeProfileDisplayPreferences()
            guard refreshTransportContinuation() else { return }
            Task { await loadChatResumeSlashCommands() }
        } catch {
            guard refreshTransportContinuation(),
                  let activeClient = self.client, activeClient === client else { return }
            isConnected = false
            isConnecting = false
            turnState = .reconnecting
            scheduleReconnect(purpose: continuationPurpose)
        }
    }

    private func mintChatResumeTicket(for connection: HermesConnection) async throws -> String {
        if let mintTicket = chatResumeLifecycleOperations.mintTicket {
            return try await mintTicket(connection.baseUrl)
        }
        prepareDashboardBridge(for: connection.baseUrl)
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        return try await dashboardTicketBridge.mintTicket()
    }

    private func connectChatResumeClient(_ client: HermesClient) async throws {
        if let connectClient = chatResumeLifecycleOperations.connectClient {
            try await connectClient(client)
        } else {
            try await client.connect()
        }
    }

    private func loadChatResumeProfiles() async {
        if let loadProfiles = chatResumeLifecycleOperations.loadProfiles {
            await loadProfiles()
        } else {
            await loadProfiles()
        }
    }

    private func loadChatResumeBusyInputMode(using client: HermesClient) async {
        if let loadBusyInputMode = chatResumeLifecycleOperations.loadBusyInputMode {
            await loadBusyInputMode(client)
        } else {
            await loadBusyInputMode(using: client)
        }
    }

    private func loadChatResumeProfileDisplayPreferences() async {
        if let loadProfileDisplayPreferences = chatResumeLifecycleOperations.loadProfileDisplayPreferences {
            await loadProfileDisplayPreferences()
        } else {
            await loadProfileDisplayPreferences()
        }
    }

    private func loadChatResumeSlashCommands() async {
        if let loadSlashCommands = chatResumeLifecycleOperations.loadSlashCommands {
            await loadSlashCommands()
        } else {
            await loadSlashCommands()
        }
    }

    @discardableResult
    func handleScenePhase(_ phase: ScenePhase) -> Task<Void, Never>? {
        if phase != .active {
            responseHapticConclusionTask?.cancel()
            responseHapticConclusionTask = nil
        }
        if let effect = responseHaptics.setForegroundActive(
            ResponseHapticPolicy.treatsAsForegroundActive(phase)
        ) {
            performResponseHapticEffects([effect])
        }
        switch phase {
        case .active:
            isSceneActive = true
            voiceConversationController.setForegroundActive(true)
            messageReadAloudController.setForegroundActive(true)
            // Consume the background arming even while signed out, so a
            // background → active cycle on the login screen doesn't surface
            // a stale request after the user signs back in.
            let didReturnFromBackground = hasEnteredBackgroundScenePhase
            hasEnteredBackgroundScenePhase = false
            guard connection != nil else { return nil }
            // The preferred return surface belongs to the authenticated
            // app: MainView presents the drawer while the automatic resume
            // sync restores the chat underneath, and explicit navigation
            // still wins via the suppression guards on both sides.
            if didReturnFromBackground {
                requestPreferredReturnSurface()
            }
            cancelScenePhaseAttempt()
            // Publish the foreground reconciliation boundary synchronously.
            // ChatView may receive the same scene transition before the health
            // check task runs, so geometry alone must not restore stale rows.
            let token = beginReconciliation()
            let automaticWorkToken = beginAutomaticChatResumeWork()
            let sceneAttemptID = UUID()
            self.scenePhaseAttemptID = sceneAttemptID
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishScenePhaseAttempt(id: sceneAttemptID) }
                guard self.scenePhaseAttemptIsCurrent(sceneAttemptID) else { return }
                if let client = self.client, client.isConnected {
                    // A connect that aborted mid-flight (scene went inactive
                    // before its checkpoint) can leave the UI's transport
                    // flags unpublished — "connecting…" with sends disabled —
                    // even though the socket is alive. Publish the healthy
                    // transport before syncing; the reconnect path manages
                    // these flags for unhealthy sockets.
                    self.isConnected = true
                    self.isConnecting = false
                    lifecycleLog.notice(
                        "Foreground refresh start: transport=retained localTurn=\(self.turnStateLogValue, privacy: .public)"
                    )
                    do {
                        try await self.verifyChatResumeTransportHealth(client)
                        guard self.scenePhaseAttemptIsCurrent(sceneAttemptID),
                              self.automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
                            self.settleReconciliation(token)
                            return
                        }
                        await self.refreshForegroundOnHealthyTransport(
                            using: client,
                            reconciliationToken: token,
                            automaticWorkToken: automaticWorkToken
                        )
                    } catch {
                        guard self.scenePhaseAttemptIsCurrent(sceneAttemptID),
                              self.automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
                            self.settleReconciliation(token)
                            return
                        }
                        lifecycleLog.notice(
                            "Foreground refresh: health check failed (\(error.localizedDescription, privacy: .public)); reconnecting"
                        )
                        await self.reconnectForRetry(purpose: .automaticReturn)
                        self.settleReconciliation(token)
                    }
                } else {
                    guard self.scenePhaseAttemptIsCurrent(sceneAttemptID),
                          self.automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
                        self.settleReconciliation(token)
                        return
                    }
                    lifecycleLog.notice(
                        "Foreground refresh start: transport=missing-or-unhealthy; reconnecting"
                    )
                    await self.reconnectForRetry(purpose: .automaticReturn)
                    self.settleReconciliation(token)
                }
            }
            scenePhaseTask = task
            return task

        case .background:
            isSceneActive = false
            hasEnteredBackgroundScenePhase = true
            // The socket can die while suspended and turn edges can be missed,
            // so the local turn state must be re-confirmed against the
            // authoritative runtime registry before the next composer submit
            // decides between a new turn and a busy submission.
            turnStateIsStale = true
            voiceConversationController.setForegroundActive(false)
            messageReadAloudController.setForegroundActive(false)
            showVoiceSheet = false
            // Drop any armed reconnect timer as well: in-flight cycles abort
            // at their next transportContinuation checkpoint, and foreground
            // activation re-establishes the transport.
            cancelScheduledReconnect()
            // Flush any pending coalesced cache writes before the app
            // suspends — iOS may kill the process before the debounce fires.
            flushPendingPresentationCache()
            // A suspended socket may still look open. Invalidate incomplete
            // snapshots so foreground always obtains a fresh authoritative one.
            invalidateReconciliation()
            cancelScenePhaseAttempt()
            return nil

        case .inactive:
            isSceneActive = false
            // Same reasoning as .background: a dip through Control Center or a
            // system overlay can miss turn edges. This never causes a resume —
            // the foreground path treats staleness as a read-only probe.
            turnStateIsStale = true
            // Reconnects are suppressed during .inactive too, so an armed
            // timer would only fire to be discarded. Drop it here; a socket
            // that dies under a system overlay (incoming call, control
            // center) is recovered by the .active scene task — the same
            // moment the user can see the transcript again.
            cancelScheduledReconnect()
            // The scene treats .inactive like .background for reconnect
            // purposes; formally abort the in-flight scene attempt at the
            // transition too, rather than at its next checkpoint.
            cancelScenePhaseAttempt()
            chatResumeCoordinator.freezeViewport()
            voiceConversationController.setForegroundActive(false)
            messageReadAloudController.setForegroundActive(false)
            return nil

        @unknown default:
            return nil
        }
    }

    private func scenePhaseAttemptIsCurrent(_ id: UUID) -> Bool {
        !Task.isCancelled && scenePhaseAttemptID == id
    }

    private func cancelScenePhaseAttempt() {
        scenePhaseAttemptID = nil
        scenePhaseTask?.cancel()
        scenePhaseTask = nil
        cancelOwnedAutomaticOperations()
    }

    private func finishScenePhaseAttempt(id: UUID) {
        guard scenePhaseAttemptID == id else { return }
        scenePhaseAttemptID = nil
        scenePhaseTask = nil
    }

    private var turnStateLogValue: String {
        switch turnState {
        case .synchronizing: return "synchronizing"
        case .idle: return "idle"
        case .running: return "running"
        case .reconnecting: return "reconnecting"
        case .unsupportedGateway: return "unsupportedGateway"
        }
    }

    // MARK: - Foreground observational refresh

    /// Outcome of the read-only liveness probe for the active conversation.
    private enum ForegroundRuntimeProbe {
        /// A live runtime row matched the active session's identity.
        case live(LiveSessionStatus)
        /// The registry answered but listed no runtime for this session: the
        /// turn ended and its transport went away, or the gateway restarted.
        case absent
        /// The registry could not be read (older gateway, transient RPC
        /// failure). The caller falls back to the resume-based refresh.
        case unavailable(String)
    }

    /// A healthy foreground transition must be observational, not a session
    /// replacement. `session.resume` is a session SWITCH upstream (switch_
    /// session), and the full sync path re-derives the target session,
    /// replaces the transcript, and resets the live reasoning projection — a
    /// harmless background→foreground cycle must not manufacture a semantic
    /// turn boundary. So the healthy-socket path first probes the gateway's
    /// in-memory runtime registry (`session.active_list`), which upstream
    /// guarantees does not resume, focus, or mutate a session, and only falls
    /// back to `session.resume` when the registry proves the live runtime is
    /// gone (or cannot answer).
    private func refreshForegroundOnHealthyTransport(
        using client: HermesClient,
        reconciliationToken token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?
    ) async {
        guard foregroundRefreshOwnsReconciliation(token),
              automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
            settleReconciliation(token)
            return
        }
        let requestedSessionID = activeSessionId
        let probe: ForegroundRuntimeProbe
        if let requestedSessionID {
            probe = await probeForegroundRuntime(
                requestedSessionID: requestedSessionID,
                using: client
            )
        } else {
            probe = .absent
        }
        guard foregroundRefreshOwnsReconciliation(token),
              automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
            settleReconciliation(token)
            return
        }
        switch probe {
        case let .live(row):
            if row.status == "starting" {
                // Runtime present, liveness inconclusive: "starting" also
                // covers promptless agent pre-warm (session.create / cold
                // resume) and transiently masks a running turn during the
                // build window, so it proves neither busy nor idle. Leave the
                // local turn state exactly as the stream left it and let live
                // events own the next edge; never manufacture a resume here.
                lifecycleLog.notice(
                    "Foreground refresh: probe=starting session=\(requestedSessionID ?? "-", privacy: .public) → observation-only, state untouched"
                )
                settleForegroundBoundary(token, automaticWorkToken: automaticWorkToken)
            } else if row.isRunning, !messages.isEmpty {
                // The same turn is still live over a hydrated transcript: keep
                // the session, the transcript, the streaming buffer, and the
                // PR #121 live reasoning projection exactly as they are. Only
                // the buffered events captured while the reconciliation
                // boundary was open need replaying — nothing was replaced, so
                // no dedup is needed.
                lifecycleLog.notice(
                    "Foreground refresh: probe=live status=\(row.status, privacy: .public) session=\(requestedSessionID ?? "-", privacy: .public) → observation-only adopt"
                )
                adoptForegroundRunningState(
                    reconciliationToken: token,
                    automaticWorkToken: automaticWorkToken
                )
            } else if row.isRunning {
                // A running runtime over an empty local transcript means this
                // surface never hydrated (failed resume, or the turn was
                // started from another surface): attach through the full
                // refresh, whose resume returns the live projection.
                lifecycleLog.notice(
                    "Foreground refresh: probe=live localTranscript=empty → resume refresh (attach live projection)"
                )
                await syncSession(
                    purpose: .automaticReturn,
                    using: token,
                    automaticWorkToken: automaticWorkToken
                )
            } else if turnState.isRunning {
                // The turn ended while the app was suspended and the idle edge
                // was missed. Presentation recovery needs the authoritative
                // bounded transcript refresh, which is allowed to resume
                // because nothing is running anymore.
                lifecycleLog.notice(
                    "Foreground refresh: probe=idle localTurn=running → resume refresh (turn ended while away)"
                )
                await syncSession(
                    purpose: .automaticReturn,
                    using: token,
                    automaticWorkToken: automaticWorkToken
                )
            } else {
                // Idle before, idle now: the session is stable and attached.
                lifecycleLog.notice(
                    "Foreground refresh: probe=idle localTurn=idle → no-op"
                )
                turnStateIsStale = false
                _ = settleReconciliationAndPublish(token, automaticWorkToken: automaticWorkToken)
            }
        case .absent:
            // No live runtime for this session: either the turn completed and
            // the registry reaped it while the transport was away, or the
            // gateway restarted and the runtime id is gone. Both need the
            // resume-based refresh to reattach (or recover completed work).
            // `session.resume` reuses a live runtime when one exists, so this
            // cannot create a duplicate runtime for a session that is alive.
            lifecycleLog.notice(
                "Foreground refresh: probe=absent → resume refresh (runtime not live)"
            )
            await syncSession(
                purpose: .automaticReturn,
                using: token,
                automaticWorkToken: automaticWorkToken
            )
        case let .unavailable(reason):
            // Older gateway or transient registry failure: keep the proven
            // resume-based refresh rather than guessing.
            lifecycleLog.notice(
                "Foreground refresh: probe unavailable (\(reason, privacy: .public)) → resume refresh"
            )
            await syncSession(
                purpose: .automaticReturn,
                using: token,
                automaticWorkToken: automaticWorkToken
            )
        }
    }

    /// Read-only registry probe for the active conversation. Matches a row by
    /// ANY identity the conversation is known under (requested, stored, and
    /// runtime aliases), so a runtime-id rotation cannot be mistaken for a
    /// dead runtime while the catalog already knows the alias.
    private func probeForegroundRuntime(
        requestedSessionID: String,
        using client: HermesClient
    ) async -> ForegroundRuntimeProbe {
        do {
            let rows: [LiveSessionStatus]
            if let probeActiveSessions = chatResumeLifecycleOperations.probeActiveSessions {
                rows = try await probeActiveSessions(client)
            } else {
                rows = try await client.activeSessions()
            }
            let acceptedIDs = acceptedIdentitySessionIDs(forRequested: requestedSessionID)
            if let row = rows.first(where: {
                acceptedIDs.contains($0.runtimeSessionId) || acceptedIDs.contains($0.storedSessionId)
            }) {
                return .live(row)
            }
            return .absent
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// Every identity the active conversation answers to: the requested id,
    /// its canonical stored id, and the catalog's confirmed aliases.
    private func acceptedIdentitySessionIDs(forRequested requestedSessionID: String) -> Set<String> {
        var ids = knownSessionIDs(for: requestedSessionID)
        ids.insert(requestedSessionID)
        if let canonical = canonicalSessionID(for: requestedSessionID) {
            ids.insert(canonical)
        }
        if let activeSessionId {
            ids.insert(activeSessionId)
        }
        return ids
    }

    /// Adopts an authoritative running state WITHOUT replacing any
    /// presentation state: no transcript swap, no streaming-buffer reset, no
    /// reasoning-segment reset. Ordering: the probe snapshot is the OLDER
    /// observation, so it establishes the running baseline FIRST; the buffered
    /// events captured while the foreground reconciliation boundary was open
    /// are replayed SECOND — they arrived after the snapshot was taken and the
    /// newest authoritative edge must win (a buffered sessionBusy(false) or
    /// completion therefore settles the turn instead of being overwritten back
    /// to running). applyStreamEvent's active-session gate still applies. The
    /// boundary settles last.
    private func adoptForegroundRunningState(
        reconciliationToken token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?
    ) {
        guard token == reconciliationToken else { return }
        // Probe baseline (older observation).
        setRunning(true)
        turnStateIsStale = false
        // Newer live edges win over the snapshot.
        let bufferedEvents = reconciliation?.bufferedEvents ?? []
        bufferedEvents.forEach { applyStreamEvent($0) }
        _ = settleReconciliationAndPublish(token, automaticWorkToken: automaticWorkToken)
    }

    /// Settles the foreground reconciliation boundary without adopting any
    /// turn state — used when the registry answer is inconclusive ("starting")
    /// so buffered events still land but the local state stays stream-owned.
    private func settleForegroundBoundary(
        _ token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?
    ) {
        guard token == reconciliationToken else { return }
        let bufferedEvents = reconciliation?.bufferedEvents ?? []
        bufferedEvents.forEach { applyStreamEvent($0) }
        _ = settleReconciliationAndPublish(token, automaticWorkToken: automaticWorkToken)
    }

    private func verifyChatResumeTransportHealth(_ client: HermesClient) async throws {
        if let verifyTransportHealth = chatResumeLifecycleOperations.verifyTransportHealth {
            try await verifyTransportHealth(client)
        } else {
            try await client.healthCheck()
        }
    }

    /// Continuation guard for the foreground refresh: the refresh decision may
    /// only mutate state while its reconciliation token still owns the
    /// boundary (a newer transition rotates the token and cancels the task).
    private func foregroundRefreshOwnsReconciliation(_ token: UUID) -> Bool {
        token == reconciliationToken && !Task.isCancelled
    }

    // MARK: - Authoritative turn-state correction

    // MARK: - Session management

    func loadSessions(forceRefresh: Bool = false) async {
        _ = await loadSessions(
            forceRefresh: forceRefresh,
            requiredViewportTransitionGeneration: nil
        )
    }

    @discardableResult
    private func loadSessions(
        forceRefresh: Bool,
        requiredViewportTransitionGeneration: UInt64?
    ) async -> Bool {
        if let requiredViewportTransitionGeneration,
           !chatViewportTransitionIsCurrent(generation: requiredViewportTransitionGeneration) {
            return false
        }
        let activeClient = client
        guard activeClient != nil || sessionCatalogLoaderOverride != nil else { return false }
        let profile = activeProfile
        let retainedActiveTurn = activeTurnCatalogSession()
        do {
            let loadedSessions: [SessionSummary]
            if let sessionCatalogLoaderOverride {
                loadedSessions = try await sessionCatalogLoaderOverride(forceRefresh)
            } else if let activeClient {
                loadedSessions = try await profileSessions(
                    using: activeClient,
                    forceRefresh: forceRefresh
                )
            } else {
                return false
            }
            guard profile == activeProfile else { return false }
            if sessionCatalogLoaderOverride == nil {
                guard let activeClient, self.client === activeClient else { return false }
            }
            guard requiredViewportTransitionGeneration.map({ chatViewportTransitionIsCurrent(generation: $0) }) ?? true else { return false }
            let allSessions = uniqueSessions(
                [retainedActiveTurn].compactMap { $0 } + loadedSessions
            )
            sessions = allSessions.filter { $0.source != .cron }
            cronSessions = allSessions.filter { $0.source == .cron }
            if let activeSessionId { updateActiveSessionTitle(for: activeSessionId) }
            if let activeClient {
                Task { [weak self] in
                    await self?.loadProjects(using: activeClient, profile: profile)
                }
            }
            return true
        } catch {
            guard profile == activeProfile else { return false }
            if sessionCatalogLoaderOverride == nil {
                guard let activeClient, self.client === activeClient else { return false }
            }
            guard requiredViewportTransitionGeneration.map({ chatViewportTransitionIsCurrent(generation: $0) }) ?? true else { return false }
            errorMessage = "Failed to load sessions: \(error.localizedDescription)"
            return false
        }
    }

    /// Replace this profile's in-memory catalog with Hermes' current data.
    /// Use this after database recovery or deletion outside Conduit.
    func refreshSessionCatalog() async {
        guard !isRefreshingSessionCatalog else { return }
        isRefreshingSessionCatalog = true
        defer { isRefreshingSessionCatalog = false }

        let sessionKey = "\(activeProfile):exclude"
        let cronKey = "\(activeProfile):cron"
        sessionCatalogCache.removeValue(forKey: sessionKey)
        sessionCatalogCache.removeValue(forKey: cronKey)
        await loadSessions(forceRefresh: true)
    }

    /// Desktop treats archived conversations as a separate, server-backed
    /// history surface. Keep it separate from the live drawer catalog so an
    /// archive operation cannot briefly reinsert a row into recents.
    func loadArchivedSessions() async {
        let profile = activeProfile
        guard let dashboardTicketBridge else { return }
        do {
            let loaded = try await dashboardArchivedSessions(profile: profile, using: dashboardTicketBridge)
            guard profile == activeProfile else { return }
            archivedSessions = uniqueSessions(loaded.filter { sessionBelongsToProfile($0, profile: profile) })
        } catch {
            guard profile == activeProfile else { return }
            errorMessage = "Could not load archived conversations: \(error.localizedDescription)"
        }
    }

    func archiveSession(_ session: SessionSummary) async -> Bool {
        await setSessionArchived(session, archived: true)
    }

    func restoreArchivedSession(_ session: SessionSummary) async -> Bool {
        await setSessionArchived(session, archived: false)
    }

    private func setSessionArchived(_ session: SessionSummary, archived: Bool) async -> Bool {
        guard sessionMutationID == nil,
              sessionBelongsToProfile(session, profile: activeProfile),
              let dashboardTicketBridge else { return false }
        if archived, isBusy, sessionMatchesActiveSession(session) {
            errorMessage = "Stop the active response before archiving this conversation."
            return false
        }

        let profile = activeProfile
        sessionMutationID = session.id
        defer { sessionMutationID = nil }
        do {
            _ = try await dashboardTicketBridge.requestJSON(
                path: dashboardPath("/api/sessions/\(encodedSessionID(session.id))", profile: profile),
                method: "PATCH",
                body: ["archived": archived]
            )
            guard profile == activeProfile else { return false }

            var updated = session
            updated.isArchived = archived
            if archived {
                sessionYoloStore.clearOverride(
                    for: profile,
                    sessionIDs: [updated.id] + updated.alternateIds
                )
                removeSessionFromLiveCatalog(updated)
                archivedSessions = [updated] + archivedSessions.filter { !sessionMatches($0, updated) }
                removePinnedState(for: updated)
                clearActiveSessionIfNeeded(updated, replacement: .archive)
            } else {
                archivedSessions.removeAll { sessionMatches($0, updated) }
                sessions = [updated] + sessions.filter { !sessionMatches($0, updated) }
            }
            return true
        } catch {
            guard profile == activeProfile else { return false }
            errorMessage = "Could not \(archived ? "archive" : "restore") this conversation: \(error.localizedDescription)"
            return false
        }
    }
    @discardableResult
    func renameSession(_ session: SessionSummary, to title: String) async -> Bool {
        guard let trimmedTitle = SessionRenameOperation.normalizedTitle(
            title,
            currentTitle: session.title
        ),
              sessionMutationID == nil,
              sessionBelongsToProfile(session, profile: activeProfile),
              sessionRenameOperationsOverride != nil || dashboardTicketBridge != nil else { return false }

        let profile = activeProfile
        let knownIDs = [session.id] + session.alternateIds
        let titleRecoveryTaskKeys = Set(knownIDs.filter { !$0.isEmpty }.map { "\(profile)|\($0)" })
        sessionTitleRecoveryTracker.suppress(titleRecoveryTaskKeys)
        sessionMutationID = session.id
        defer {
            sessionMutationID = nil
            sessionTitleRecoveryTracker.unsuppress(titleRecoveryTaskKeys)
        }

        await sessionTitleRecoveryTracker.cancel(titleRecoveryTaskKeys)
        guard profile == activeProfile else { return false }

        let operations: SessionRenameOperation.Operations
        if let sessionRenameOperationsOverride {
            operations = sessionRenameOperationsOverride
        } else {
            guard let dashboardTicketBridge else { return false }
            let activeClient = client
            let runtimeRenameExpected = activeClient != nil
                && activeSessionId.map { knownIDs.contains($0) } == true
            operations = SessionRenameOperation.Operations(
                renameRuntime: activeClient.map { client in
                    { [weak self, weak client] sessionID, title in
                        guard let self, let client else {
                            throw SessionRenameOperation.ContextChanged()
                        }
                        try await client.setSessionTitle(sessionID, title: title)
                        guard profile == self.activeProfile, self.client === client else {
                            throw SessionRenameOperation.ContextChanged()
                        }
                    }
                },
                renameStored: { [weak self, weak dashboardTicketBridge] sessionID, title in
                    guard let self, let dashboardTicketBridge,
                          profile == self.activeProfile,
                          !runtimeRenameExpected || self.client === activeClient else {
                        throw SessionRenameOperation.ContextChanged()
                    }
                    _ = try await dashboardTicketBridge.requestJSON(
                        path: self.dashboardPath(
                            "/api/sessions/\(self.encodedSessionID(sessionID))",
                            profile: profile
                        ),
                        method: "PATCH",
                        body: ["title": title]
                    )
                }
            )
        }

        do {
            guard let result = try await SessionRenameOperation.perform(
                session: session,
                activeSessionID: activeSessionId,
                title: trimmedTitle,
                operations: operations
            ), profile == activeProfile else { return false }
            applyRecoveredSessionTitle(result.title, sessionIDs: result.sessionIDs)
            return true
        } catch is SessionRenameOperation.ContextChanged {
            return false
        } catch {
            guard profile == activeProfile else { return false }
            errorMessage = SessionRenameOperation.failureMessage(error)
            return false
        }
    }

    func deleteSession(_ session: SessionSummary) async -> Bool {
        guard sessionMutationID == nil,
              sessionBelongsToProfile(session, profile: activeProfile),
              let dashboardTicketBridge else { return false }
        if isBusy, sessionMatchesActiveSession(session) {
            errorMessage = "Stop the active response before deleting this conversation."
            return false
        }

        let profile = activeProfile
        sessionMutationID = session.id
        defer { sessionMutationID = nil }
        do {
            _ = try await dashboardTicketBridge.requestJSON(
                path: dashboardPath("/api/sessions/\(encodedSessionID(session.id))", profile: profile),
                method: "DELETE"
            )
            guard profile == activeProfile else { return false }
            sessionYoloStore.clearOverride(
                for: profile,
                sessionIDs: [session.id] + session.alternateIds
            )
            removeSessionFromLiveCatalog(session)
            archivedSessions.removeAll { sessionMatches($0, session) }
            removePinnedState(for: session)
            clearActiveSessionIfNeeded(session, replacement: .delete)
            return true
        } catch {
            guard profile == activeProfile else { return false }
            errorMessage = "Could not delete this conversation: \(error.localizedDescription)"
            return false
        }
    }

    func isSessionMutationInFlight(_ session: SessionSummary) -> Bool {
        sessionMutationID == session.id
    }

    private func encodedSessionID(_ sessionID: String) -> String {
        sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
    }

    private func sessionMatches(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        let left = Set([lhs.id] + lhs.alternateIds)
        let right = Set([rhs.id] + rhs.alternateIds)
        return !left.isDisjoint(with: right)
    }

    private func knownSessionIDs(for sessionID: String) -> Set<String> {
        guard let session = (sessions + cronSessions).first(where: {
            $0.id == sessionID || $0.alternateIds.contains(sessionID)
        }) else {
            return [sessionID]
        }
        return Set([session.id] + session.alternateIds)
    }

    private func sessionMatchesActiveSession(_ session: SessionSummary) -> Bool {
        guard let activeSessionId else { return false }
        return Set([session.id] + session.alternateIds).contains(activeSessionId)
    }

    private func removeSessionFromLiveCatalog(_ session: SessionSummary) {
        sessions.removeAll { sessionMatches($0, session) }
        cronSessions.removeAll { sessionMatches($0, session) }
        // Every non-forced catalog load merges the profile cache back into
        // the published arrays and re-saves the union. A row left in the
        // cache therefore resurrects a deleted or archived conversation on
        // the next foreground or send, until a pull-to-refresh purges it.
        sessionCatalogCache.removeSession(
            withIDs: Set([session.id] + session.alternateIds)
        )
    }

    func clearActiveSessionIfNeeded(
        _ session: SessionSummary,
        replacement: ChatResumeConversationReplacement
    ) {
        guard sessionMatchesActiveSession(session) else { return }
        let transitionGeneration = acceptChatResumeConversationReplacement(replacement)
        markChatViewportReplacement()
        setActiveSessionState(id: nil, title: "New conversation")
        messages = []
        persistedTranscriptWindow = nil
        clearStreamingText()
        activeAssistantMessageId = nil
        resetReasoningTurn()
        turnState = .idle
        finishChatViewportTransition(generation: transitionGeneration)
    }

    /// The Cron tab presents two independent server-backed surfaces: the job
    /// definitions and the cron-session history. Refresh them together so a
    /// newly completed run is visible without visiting the Sessions tab first.
    func refreshCronContent() async {
        async let sessionRefresh: Void = refreshSessionCatalog()
        async let jobsRefresh: Void = loadCronJobs()
        _ = await (sessionRefresh, jobsRefresh)
    }

    @discardableResult
    func openSession(_ sessionId: String) async -> Bool {
        await openSession(sessionId, reusing: nil)
    }

    @discardableResult
    func requestOpenSession(_ sessionId: String) -> Task<Bool, Never> {
        cancelExplicitSessionOpen()
        let requestID = UUID()
        explicitSessionOpenRequestID = requestID
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let opened = await self.openSession(sessionId)
            guard self.explicitSessionOpenRequestID == requestID else { return opened }
            self.explicitSessionOpenRequestID = nil
            self.explicitSessionOpenTask = nil
            return opened
        }
        explicitSessionOpenTask = task
        return task
    }

    private func cancelExplicitSessionOpen() {
        explicitSessionOpenRequestID = nil
        explicitSessionOpenTask?.cancel()
        explicitSessionOpenTask = nil
    }

    private func openSession(
        _ sessionId: String,
        reusing viewportTransitionGeneration: UInt64?
    ) async -> Bool {
        guard let client else { return false }
        let previousTurnState = turnState
        if let session = (sessions + cronSessions).first(where: {
            $0.id == sessionId || $0.alternateIds.contains(sessionId)
        }), !sessionBelongsToProfile(session, profile: activeProfile) {
            errorMessage = "That conversation belongs to another workspace. Switch profiles to open it."
            return false
        }
        let transitionGeneration: UInt64
        if let viewportTransitionGeneration {
            guard chatViewportTransitionIsCurrent(
                generation: viewportTransitionGeneration
            ) else { return false }
            transitionGeneration = viewportTransitionGeneration
        } else {
            transitionGeneration = beginExplicitChatViewportTransition()
        }
        guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
            return false
        }
        markChatViewportReplacement()
        // Atomically switch session identity BEFORE clearing the transcript.
        // This prevents stale stream events from the old session falling
        // through `eventBelongsToActiveSession` and repopulating the
        // cleared message array while reconciliation is in flight.
        flushPendingPresentationCache()
        let token = beginReconciliation()
        let acceptedSessionIDs = knownSessionIDs(for: sessionId)
        setActiveSessionState(id: sessionId)
        messages = []
        persistedTranscriptWindow = nil
        clearStreamingText()
        activeAssistantMessageId = nil
        resetReasoningTurn()
        updateActiveSessionTitle(for: sessionId)
        let reconciled = await reconcile(
            sessionId: sessionId,
            using: client,
            token: token,
            acceptedSessionIDs: acceptedSessionIDs,
            requiredViewportTransitionGeneration: transitionGeneration
        )
        guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
            return false
        }
        if !reconciled {
            finishChatViewportTransition(generation: transitionGeneration)
            if Task.isCancelled, turnState == .synchronizing {
                turnState = previousTurnState
            }
        }
        return reconciled
    }

    /// Routes a notification to its originating profile/session without
    /// allowing the ordinary cold-start session restoration to win first.
    func openNotificationTarget(_ target: ConduitNotificationTarget) async -> Bool {
        guard connection != nil else { return false }
        let notificationAttemptID = UUID()
        activeNotificationOpenAttemptID = notificationAttemptID
        isOpeningNotificationSession = true
        let transitionGeneration = beginExplicitChatViewportTransition()
        defer {
            cancelChatViewportTransitionIfNoReplacement(generation: transitionGeneration)
            finishNotificationOpenAttempt(id: notificationAttemptID)
        }
        guard notificationOpenAttemptIsCurrent(
            id: notificationAttemptID,
            transitionGeneration: transitionGeneration
        ) else { return false }
        let targetProfile = notificationProfileID(target.profile)
        if let targetProfile, targetProfile != activeProfile {
            guard await switchProfile(
                to: targetProfile,
                reusing: transitionGeneration
            ) else { return false }
        }
        guard notificationOpenAttemptIsCurrent(
            id: notificationAttemptID,
            transitionGeneration: transitionGeneration
        ) else {
            return false
        }
        if let targetProfile, activeProfile != targetProfile { return false }
        guard client != nil else { return false }
        showSidebar = false

        // Pushes can arrive before this device has seen the scheduled run.
        // Replace the cached catalog first, then prefer the catalog's stored
        // ID for the notification's runtime/alternate ID. Otherwise the next
        // cold-start recovery only sees the old normal-session list and jumps
        // back to its newest entry.
        // Do not share the sidebar refresh guard here. The notification route
        // needs one authoritative read even if a visual refresh is already in
        // progress, otherwise it can resolve against the stale catalog.
        guard await loadSessions(
            forceRefresh: true,
            requiredViewportTransitionGeneration: transitionGeneration
        ) else { return false }
        guard notificationOpenAttemptIsCurrent(
            id: notificationAttemptID,
            transitionGeneration: transitionGeneration
        ) else {
            return false
        }
        let requestedID = target.sessionId
        let resumableID = NotificationSessionResolver.resumableSessionID(
            for: requestedID,
            in: sessions + cronSessions
        )
        // A decision raised while the app was backgrounded is delivered as a
        // structured payload on the notification (the one-shot gateway stream
        // event was missed). Cache it under both the runtime and resolved
        // stored IDs so the upcoming resume's `merge` restores the card
        // regardless of which identity the gateway resumes against.
        if let decision = target.decision {
            recordNotificationDecision(decision, sessionIDs: [resumableID, requestedID])
        }
        let opened = await openSession(
            resumableID,
            reusing: transitionGeneration
        )
        guard notificationOpenAttemptIsCurrent(
            id: notificationAttemptID,
            transitionGeneration: transitionGeneration
        ) else { return false }
        return opened
    }

    /// Caches a push-delivered decision card so the resume merge can restore
    /// it. The card is recorded as pending and answerable through the existing
    /// `respondToApproval` path; the bounded unconfirmed marker is stamped by
    /// `SessionPresentationCache` so a stale card expires rather than lingering.
    /// The decision's session key must match one of the routed session
    /// identities — a mismatched key could not be answered via
    /// `approval.respond` and would only duplicate or contradict the live card.
    private func recordNotificationDecision(
        _ decision: PendingDecisionPayload,
        sessionIDs: [String]
    ) {
        switch decision {
        case let .approval(sessionKey, description, choices):
            // Compare trimmed on both sides: the payload parser trims the
            // session key, but the routed ids arrive as the notification
            // delivered them.
            let knownKeys = sessionIDs.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard knownKeys.contains(sessionKey) else { return }
            let activity = ApprovalActivity(
                sessionId: sessionKey,
                command: "",
                description: description,
                choices: choices,
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
            let message = ChatMessage(
                id: "approval-\(sessionKey)",
                role: .approval,
                content: description,
                timestamp: Self.localTimestamp(),
                approval: activity
            )
            sessionPresentationCache.recordPendingDecision(
                message,
                profile: activeProfile,
                sessionIDs: sessionIDs
            )
        case let .clarify(requestId, question, choices):
            // Relay-delivered clarify: the plugin middleware minted this id and
            // is polling the relay, so the standard card renders with working
            // buttons routed through respondToRelayClarify.
            let activity = ClarifyActivity(
                requestId: requestId,
                question: question,
                choices: choices.map { ClarifyChoice(label: $0, value: $0) },
                status: .pending,
                answer: nil,
                error: nil
            )
            let message = ChatMessage(
                id: "clarify-\(requestId)",
                role: .clarify,
                content: question,
                timestamp: Self.localTimestamp(),
                clarify: activity
            )
            sessionPresentationCache.recordPendingDecision(
                message,
                profile: activeProfile,
                sessionIDs: sessionIDs
            )
        }
    }

    private func notificationOpenAttemptIsCurrent(
        id: UUID,
        transitionGeneration: UInt64
    ) -> Bool {
        activeNotificationOpenAttemptID == id
            && chatViewportTransitionIsCurrent(generation: transitionGeneration)
    }

    private func finishNotificationOpenAttempt(id: UUID) {
        guard activeNotificationOpenAttemptID == id else { return }
        activeNotificationOpenAttemptID = nil
        isOpeningNotificationSession = false
    }

    private func notificationProfileID(_ notifiedProfile: String?) -> String? {
        guard let notifiedProfile else { return nil }
        let normalized = notifiedProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.caseInsensitiveCompare("default") == .orderedSame
            || normalized.caseInsensitiveCompare(defaultProfileName) == .orderedSame {
            return "default"
        }
        return profiles.first { $0.caseInsensitiveCompare(normalized) == .orderedSame } ?? normalized
    }

    func createNewSession(cwd: String? = nil) async {
        guard !isProfileSwitching, isConnected, !isConnecting, let client else {
            if isProfileSwitching || isConnecting {
                errorMessage = "Wait for the workspace switch to finish before starting a conversation."
            }
            return
        }
        let transitionGeneration = beginExplicitChatViewportTransition()
        defer {
            cancelChatViewportTransitionIfNoReplacement(generation: transitionGeneration)
        }
        let profile = activeProfile
        cacheMessagePresentation()
        activeSessionTitle = "New conversation"
        let token = beginReconciliation()
        turnState = .synchronizing
        await createAndReconcileSession(using: client, profile: profile, token: token, cwd: cwd)
    }

    /// Re-resume the currently visible conversation. This uses the same
    /// snapshot/event buffering path as foreground recovery, so a refresh
    /// during a turn cannot leave the composer with stale busy state.
    func refreshActiveSession() async {
        guard let client, let sessionId = activeSessionId, !isChatRefreshing else { return }
        let transitionGeneration = beginExplicitChatViewportTransition()
        markChatViewportReplacement()
        isChatRefreshing = true
        defer { isChatRefreshing = false }
        let previousMessages = messages

        let token = beginReconciliation()
        let succeeded = await reconcile(
            sessionId: sessionId,
            using: client,
            token: token,
            acceptedSessionIDs: knownSessionIDs(for: sessionId),
            requiredViewportTransitionGeneration: transitionGeneration
        )
        if !succeeded || messages == previousMessages {
            finishChatViewportTransition(generation: transitionGeneration)
        }
        await loadSessions()
    }

    /// Forks only the history through the selected assistant response. The
    /// original conversation remains untouched; the new session becomes active
    /// and is resumed through the normal authoritative recovery path.
    func branchFromAssistantMessage(_ messageId: String) async {
        guard !isBusy, !isBranchingChat, !isProfileSwitching,
              let client,
              let parentSessionId = activeSessionId,
              let messageIndex = messages.firstIndex(where: { $0.id == messageId }),
              messages[messageIndex].role == .assistant else { return }

        let prefix = messages[...messageIndex].compactMap { message -> SessionBranchMessage? in
            guard message.role == .user || message.role == .assistant else { return nil }
            let content = (message.role == .user ? message.rawContent : nil) ?? message.content
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SessionBranchMessage(role: message.role, content: trimmed)
        }
        guard !prefix.isEmpty else {
            errorMessage = "There is no message history to branch from."
            return
        }

        isBranchingChat = true
        defer { isBranchingChat = false }
        let previousTurnState = turnState
        let profile = activeProfile
        turnState = .synchronizing
        let title = "Branch of \(activeSessionTitle)"
        let transitionGeneration = acceptChatResumeConversationReplacement(.branch)
        defer {
            cancelChatViewportTransitionIfNoReplacement(generation: transitionGeneration)
        }

        do {
            let branched: ChatResumeLifecycleOperations.BranchResult
            if let branchSession = chatResumeLifecycleOperations.branchSession {
                branched = try await branchSession(
                    client,
                    parentSessionId,
                    Array(prefix),
                    title,
                    runtime.cwd
                )
            } else {
                branched = try await client.branchSession(
                    parentSessionId: parentSessionId,
                    messages: Array(prefix),
                    title: title,
                    cwd: runtime.cwd
                )
            }
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration),
                  profile == activeProfile,
                  self.client === client else { return }
            if let returnedProfile = branched.profile,
               !profilesMatch(returnedProfile, profile) {
                turnState = previousTurnState
                errorMessage = "Hermes created this branch in \(profileDisplayName(returnedProfile)), not \(profileDisplayName(profile)). It was not opened."
                guard await loadSessions(
                    forceRefresh: true,
                    requiredViewportTransitionGeneration: transitionGeneration
                ), chatViewportTransitionIsCurrent(
                    generation: transitionGeneration
                ) else { return }
                return
            }
            if let setSessionTitle = chatResumeLifecycleOperations.setSessionTitle {
                try? await setSessionTitle(client, branched.sessionId, title)
            } else {
                try? await client.setSessionTitle(branched.sessionId, title: title)
            }
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration),
                  profile == activeProfile,
                  self.client === client else { return }

            let summary = SessionSummary(
                id: branched.storedSessionId ?? branched.sessionId,
                alternateIds: [branched.sessionId, branched.storedSessionId]
                    .compactMap { $0 }
                    .filter { $0 != branched.storedSessionId ?? branched.sessionId },
                title: title,
                model: runtime.model.isEmpty ? "Hermes" : runtime.model,
                updatedLabel: "now",
                profile: activeProfile,
                source: .chat,
                isActive: true,
                isArchived: false,
                lineageRootId: parentSessionId
            )
            sessions = [summary] + sessions.map { existing in
                var updated = existing
                updated.isActive = false
                return updated
            }

            activeSessionTitle = title
            let token = beginReconciliation()
            let reconciled = await reconcile(
                sessionId: branched.sessionId,
                using: client,
                token: token,
                acceptedSessionIDs: knownSessionIDs(for: branched.sessionId),
                requiredViewportTransitionGeneration: transitionGeneration
            )
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration),
                  profile == activeProfile,
                  self.client === client else { return }
            let loadedFinalCatalog = await loadSessions(
                forceRefresh: false,
                requiredViewportTransitionGeneration: transitionGeneration
            )
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration),
                  profile == activeProfile,
                  self.client === client else { return }
            if !reconciled {
                finishChatViewportTransition(generation: transitionGeneration)
                return
            }
            guard loadedFinalCatalog else { return }
        } catch {
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration),
                  profile == activeProfile,
                  self.client === client else { return }
            turnState = previousTurnState
            errorMessage = "Could not branch conversation: \(error.localizedDescription)"
        }
    }

    // MARK: - Composer actions

    func composerSubmissionContext() -> ComposerSubmissionContext {
        ComposerSubmissionContext(
            profile: activeProfile,
            sessionID: activeSessionId,
            clientIdentity: client.map(ObjectIdentifier.init),
            clientEpoch: activeClientEpoch,
            viewportTransitionGeneration: chatViewportTransitionGeneration
        )
    }

    private func isCurrentComposerSubmission(_ context: ComposerSubmissionContext) -> Bool {
        context.profile == activeProfile
            && context.sessionID == activeSessionId
            && context.clientIdentity == client.map(ObjectIdentifier.init)
            && context.clientEpoch == activeClientEpoch
            && context.viewportTransitionGeneration == chatViewportTransitionGeneration
    }

    private func composerSubmissionOwnershipIsCurrent(
        _ context: ComposerSubmissionContext
    ) -> Bool {
        context.profile == activeProfile
            && context.clientIdentity == client.map(ObjectIdentifier.init)
            && context.clientEpoch == activeClientEpoch
            && context.viewportTransitionGeneration == chatViewportTransitionGeneration
    }

    private func composerSessionIDsAreEquivalent(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs || activeChatScrollSessionIdentity.areEquivalent(lhs, rhs) {
            return true
        }
        guard let session = (sessions + cronSessions).first(where: { session in
            let ids = Set([session.id] + session.alternateIds)
            return ids.contains(lhs) || ids.contains(rhs)
        }) else {
            return false
        }
        let ids = Set([session.id] + session.alternateIds)
        return ids.contains(lhs) && ids.contains(rhs)
    }

    private func isCurrentOrAliasedComposerSubmission(
        _ context: ComposerSubmissionContext
    ) -> Bool {
        currentComposerSubmissionContextIfOwnedAndAliased(context) != nil
    }

    private func currentComposerSubmissionContextIfOwnedAndAliased(
        _ context: ComposerSubmissionContext
    ) -> ComposerSubmissionContext? {
        guard composerSubmissionOwnershipIsCurrent(context),
              let activeSessionId,
              composerSessionIDsAreEquivalent(context.sessionID, activeSessionId) else {
            return nil
        }
        return ComposerSubmissionContext(
            profile: context.profile,
            sessionID: activeSessionId,
            clientIdentity: context.clientIdentity,
            clientEpoch: context.clientEpoch,
            viewportTransitionGeneration: context.viewportTransitionGeneration
        )
    }

    private func recoverComposerSubmission(
        using context: ComposerSubmissionContext
    ) async -> ComposerSubmissionContext? {
        // Keep recovery owned by the submission that produced the error. The
        // active actor may have moved to another session while the RPC waited.
        guard isCurrentOrAliasedComposerSubmission(context) else { return nil }
        await syncSession()
        return currentComposerSubmissionContextIfOwnedAndAliased(context)
    }

    func submitComposer(
        text: String,
        attachments: [Attachment] = [],
        context: ComposerSubmissionContext? = nil
    ) async -> Bool {
        let submissionContext = context ?? composerSubmissionContext()
        guard isCurrentComposerSubmission(submissionContext) else { return false }

        // The gateway is already idle while the final visual tail drains.
        // If the user acts first, commit that response synchronously so the
        // new outgoing message retains correct transcript order.
        finalizePendingStreamingCompletion()
        guard composerIsEnabled else { return false }

        // Slash command intercept — handle before normal message/steer logic
        if attachments.isEmpty && Self.parseSlashCommand(text) != nil {
            await executeSlashCommand(text, context: submissionContext)
            return true
        }

        if isBusy {
            guard attachments.isEmpty else {
                errorMessage = "Attachments can only be sent in a new message, after the current response finishes."
                return false
            }

            switch busyInputMode {
            case .steer:
                return await steer(text, context: submissionContext)
            case .interrupt:
                return await redirectOrInterruptAndSend(text, context: submissionContext)
            }
        }

        // A lifecycle/recovery boundary (scene dip, reconnect, ambiguous
        // submission) may have left the local idle state stale while Hermes
        // still considers the session running. Submitting blind would enter
        // Hermes' server-side busy policy with a message the user meant as a
        // new turn — the queued/steered follow-up the user never asked for.
        // One authoritative read-only probe corrects the state before the
        // routing decision. Trusted state never pays for the probe.
        if turnState == .idle, turnStateIsStale,
           await correctStaleIdleTurnState(using: submissionContext) {
            guard attachments.isEmpty else {
                errorMessage = "Attachments can only be sent in a new message, after the current response finishes."
                return false
            }
            switch busyInputMode {
            case .steer:
                lifecycleLog.notice("submitComposer: stale-idle corrected to running → busy steer")
                return await steer(text, context: submissionContext)
            case .interrupt:
                lifecycleLog.notice("submitComposer: stale-idle corrected to running → busy redirect/interrupt")
                return await redirectOrInterruptAndSend(text, context: submissionContext)
            }
        }

        return await sendMessage(
            text,
            attachments: attachments,
            context: submissionContext
        )
    }

    /// Read-only authoritative correction of a possibly stale local idle
    /// state, OWNED BY THIS SUBMISSION. Returns true when the gateway proves
    /// the session is RUNNING (the caller must use the configured busy
    /// action); false when the session is idle (safe to send a new turn) or
    /// the state could not be verified (do not add RPC chatter — fall through
    /// to the ordinary send, whose typed outcome reconciles). If ownership of
    /// the submission was lost across the probe's await (session/profile
    /// handoff), NOTHING is mutated: the session the user switched to keeps
    /// its own stale marker and will run its own correction.
    private func correctStaleIdleTurnState(
        using submissionContext: ComposerSubmissionContext
    ) async -> Bool {
        guard let client, let sessionId = activeSessionId else {
            // Nothing to probe; leave the stale marker for the real owner.
            return false
        }
        // Capture the probe identity BEFORE the await — never re-derive it
        // from the mutable active session afterwards.
        let acceptedIDs = acceptedIdentitySessionIDs(forRequested: sessionId)
        let rows: [LiveSessionStatus]
        do {
            if let probeActiveSessions = chatResumeLifecycleOperations.probeActiveSessions {
                rows = try await probeActiveSessions(client)
            } else {
                rows = try await client.activeSessions()
            }
        } catch {
            // The registry could not be read (older gateway, transient
            // failure). Proceed with the ordinary send rather than blocking
            // the user; the submission's own typed outcome will reconcile.
            // The one-time stale clear is submission-owned so an unsupported
            // gateway does not turn every later submit into probe chatter.
            lifecycleLog.notice(
                "submitComposer: stale-idle probe unavailable; proceeding with send session=\(sessionId, privacy: .public)"
            )
            if isCurrentComposerSubmission(submissionContext) {
                turnStateIsStale = false
            }
            return false
        }
        // Ownership re-check AFTER the await: if the user switched sessions or
        // profiles while the probe was suspended, this result belongs to the
        // OLD conversation and must not mutate the new one's turn state — nor
        // clear its stale marker.
        guard isCurrentComposerSubmission(submissionContext),
              turnState == .idle, turnStateIsStale else {
            lifecycleLog.notice(
                "submitComposer: stale-idle probe superseded by session handoff; no state mutation session=\(sessionId, privacy: .public)"
            )
            return false
        }
        let row = rows.first(where: {
            acceptedIDs.contains($0.runtimeSessionId) || acceptedIDs.contains($0.storedSessionId)
        })
        if let row, row.isRunning {
            lifecycleLog.notice(
                "submitComposer: authoritative probe=live status=\(row.status, privacy: .public) corrects stale idle session=\(sessionId, privacy: .public)"
            )
            // setRunning also clears the pending-decision restoration guard,
            // exactly like a live sessionBusy(true) edge would.
            setRunning(true)
            turnStateIsStale = false
            return true
        }
        // Authoritative idle/absent/starting for THIS submission: the local
        // idle state is confirmed and a starting runtime is not committed
        // busy (pre-warm builds report it too), so send as an ordinary new
        // turn — the typed prompt.submit outcome catches a genuine busy race.
        turnStateIsStale = false
        return false
    }

    func sendMessage(
        _ text: String,
        attachments: [Attachment] = [],
        context: ComposerSubmissionContext? = nil
    ) async -> Bool {
        let submissionContext = context ?? composerSubmissionContext()
        guard isCurrentComposerSubmission(submissionContext) else { return false }
        guard let client, let sessionId = activeSessionId else { return false }
        cancelChatResumeRestoration()
        resetResponseHapticTurn()
        // Durable before/after identity for ambiguous-delivery recovery:
        // everything this conversation held BEFORE the optimistic append, so
        // a later bounded tail read can prove whether the submitted turn
        // landed even when the registry has already gone idle/absent.
        let submissionBaseline = PromptTranscriptBaseline(messages: messages)
        // The identity under probe must be captured BEFORE any await — never
        // re-derived from the mutable active session afterwards.
        let submissionSessionIDs = acceptedIdentitySessionIDs(forRequested: sessionId)

        let userMessage = ChatMessage(
            id: "local-\(Date().timeIntervalSince1970)",
            role: .user,
            content: text,
            rawContent: nil,
            timestamp: Self.localTimestamp(),
            author: nil,
            attachments: attachments.isEmpty ? nil : attachments
        )
        // Mid-turn ordering rule: the outgoing bubble must not land below a
        // still-live reasoning card's eventual commit.
        settleReasoningSegmentIntoTranscript()
        messages.append(userMessage)
        requestChatScrollToLatest()
        cacheMessagePresentation(for: [sessionId])
        clearStreamingText()
        turnState = .running

        for attachment in attachments {
            do {
                if attachment.kind == .image {
                    let base64 = await AttachmentHelper.toBase64(attachment)
                    guard isCurrentComposerSubmission(submissionContext) else { return false }
                    guard !base64.isEmpty else { throw AttachmentError.unreadableFile(attachment.name) }
                    _ = try await client.attachImage(sessionId, base64: base64, filename: attachment.name)
                } else if attachment.name.lowercased().hasSuffix(".pdf") {
                    let base64 = await AttachmentHelper.toBase64(attachment)
                    guard isCurrentComposerSubmission(submissionContext) else { return false }
                    guard !base64.isEmpty else { throw AttachmentError.unreadableFile(attachment.name) }
                    try await client.attachPdf(sessionId, base64: base64, filename: attachment.name)
                } else {
                    let dataUrl = await AttachmentHelper.toDataUrl(attachment)
                    guard isCurrentComposerSubmission(submissionContext) else { return false }
                    guard !dataUrl.isEmpty else { throw AttachmentError.unreadableFile(attachment.name) }
                    try await client.attachFile(sessionId, dataUrl: dataUrl, name: attachment.name)
                }
                guard isCurrentComposerSubmission(submissionContext) else { return false }
            } catch {
                guard isCurrentComposerSubmission(submissionContext) else { return false }
                errorMessage = "Attachment failed: \(error.localizedDescription)"
                await recoverComposerSubmission(using: submissionContext)
                return false
            }
        }

        do {
            let outcome: PromptSubmissionOutcome
            if let sendPrompt = chatResumeLifecycleOperations.sendPrompt {
                outcome = try await sendPrompt(client, sessionId, text)
            } else {
                outcome = try await client.sendPrompt(sessionId, text: text)
            }
            // The gateway accepted the prompt. A session handoff may have
            // happened while the RPC was suspended, but that does not turn a
            // remotely successful send into a local draft failure. All local
            // state writes below are submission-owned: an operation started
            // for session A must never mutate turn state that now belongs to
            // session B.
            lifecycleLog.notice(
                "prompt.submit outcome=\(Self.promptOutcomeLogValue(outcome), privacy: .public) session=\(sessionId, privacy: .public)"
            )
            if isCurrentComposerSubmission(submissionContext) {
                if outcome.isBusySubmission {
                    // Hermes applied its busy policy, which proves THIS
                    // session was RUNNING when the prompt landed — the local
                    // state was stale. Adopt the authoritative busy state so
                    // the composer keeps offering the configured busy action
                    // and the next submission is routed correctly.
                    turnState = .running
                }
                turnStateIsStale = false
            }
            return true
        } catch {
            guard isCurrentComposerSubmission(submissionContext) else { return false }
            if Self.isAmbiguousPromptDelivery(error) {
                lifecycleLog.notice(
                    "prompt.submit ambiguous (\(error.localizedDescription, privacy: .public)); querying authoritative state session=\(sessionId, privacy: .public)"
                )
                let (resolution, reconnected) = await reconcileAmbiguousPromptSubmission(
                    requestedSessionID: sessionId,
                    acceptedSessionIDs: submissionSessionIDs,
                    baseline: submissionBaseline,
                    submittedText: text,
                    submissionContext: submissionContext
                )
                // Every write below is submission-owned: the guard is
                // re-checked inside each branch so a handoff during the
                // recovery awaits cannot leak state into the new session.
                switch resolution {
                case .acceptedRunning:
                    // Hermes accepted the submission and the turn is still
                    // live: keep the optimistic user row and the running turn,
                    // and never re-send the prompt.
                    if isCurrentComposerSubmission(submissionContext) {
                        turnState = .running
                        turnStateIsStale = false
                    }
                    return true
                case .acceptedSettled:
                    // The durable transcript proves the submitted turn landed
                    // and settled (the registry had already gone idle/absent
                    // by the time recovery looked). The submission stays
                    // accepted: the composer remains cleared, nothing is
                    // restored, and the transcript converges on the next
                    // bounded refresh.
                    lifecycleLog.notice(
                        "prompt.submit accepted (durable transcript); turn settled session=\(sessionId, privacy: .public)"
                    )
                    if isCurrentComposerSubmission(submissionContext) {
                        turnState = .idle
                        turnStateIsStale = false
                    }
                    return true
                case .notAccepted:
                    // Authoritative evidence shows Hermes did not accept the
                    // prompt: restore the unsent state exactly once below.
                    lifecycleLog.notice(
                        "prompt.submit not accepted (authoritative); restoring unsent state session=\(sessionId, privacy: .public)"
                    )
                    if isCurrentComposerSubmission(submissionContext) {
                        turnStateIsStale = false
                    }
                case .unresolved:
                    // Acceptance could be neither proven nor disproven. Be
                    // conservative about duplicate delivery: restore rather
                    // than re-send blindly.
                    lifecycleLog.notice(
                        "prompt.submit state unresolved; restoring unsent state session=\(sessionId, privacy: .public)"
                    )
                }
                errorMessage = "Failed to send: \(error.localizedDescription)"
                if !reconnected, isCurrentComposerSubmission(submissionContext) {
                    await recoverComposerSubmission(using: submissionContext)
                }
                // A reconnect inside the recovery already synced the
                // authoritative transcript, so the restoration happened there.
                return false
            }
            errorMessage = "Failed to send: \(error.localizedDescription)"
            await recoverComposerSubmission(using: submissionContext)
            return false
        }
    }

    private static func promptOutcomeLogValue(_ outcome: PromptSubmissionOutcome) -> String {
        switch outcome {
        case .accepted: return "accepted"
        case .steered: return "steered"
        case .redirected: return "redirected"
        case .queued: return "queued"
        }
    }

    /// Which failures leave it genuinely unknown whether Hermes received the
    /// prompt. Two classes are DEFINITIVE rejections: a structured `RpcError`
    /// (the gateway answered, so the prompt was not accepted) and
    /// `notConnected` (`rpc` throws before any bytes leave the device). The
    /// remaining transport failures are ambiguous — the bytes may have
    /// reached Hermes and the turn may already be running — so the
    /// authoritative registry probe decides, and unknown future `HermesError`
    /// cases fail toward the probe rather than toward a blind retry.
    private static func isAmbiguousPromptDelivery(_ error: Error) -> Bool {
        switch error {
        case HermesError.notConnected:
            return false
        case is RpcError:
            return false
        case is HermesError:
            return true
        case is URLError, is CancellationError:
            return true
        default:
            return false
        }
    }

    /// Recovery for a `prompt.submit` whose acknowledgement was lost. Reconnects
    /// the transport if needed, then consults the authoritative runtime
    /// registry: a live turn for this session means the prompt was accepted and
    /// must never be re-sent; an idle/absent session means it was not.
    /// `reconnected` reports whether a transport recovery (with its own full
    /// transcript sync) ran, so the caller can skip a duplicate restoration.
    private enum AmbiguousPromptResolution {
        /// Accepted and still running on the current transport.
        case acceptedRunning
        /// Accepted and proven settled by the durable transcript: the turn ran
        /// to completion before recovery looked (the registry had already gone
        /// idle/absent, which alone cannot prove non-acceptance).
        case acceptedSettled
        /// Authoritative evidence (registry idle/absent AND the durable
        /// transcript advanced without the submitted turn) that the prompt was
        /// not accepted.
        case notAccepted
        /// Neither acceptance nor non-acceptance could be established.
        case unresolved
    }

    private func reconcileAmbiguousPromptSubmission(
        requestedSessionID: String,
        acceptedSessionIDs: Set<String>,
        baseline: PromptTranscriptBaseline,
        submittedText: String,
        submissionContext: ComposerSubmissionContext
    ) async -> (resolution: AmbiguousPromptResolution, reconnected: Bool) {
        var reconnected = false
        var probeClient = client
        if probeClient?.isConnected != true {
            // The transport died around the submission. A reconnect here is a
            // real recovery, and its sync may already surface the accepted
            // turn's persisted rows.
            await reconnectForRetry(purpose: .preserveCurrent)
            probeClient = self.client
            // Only a SUCCESSFUL reconnect (whose sync already restored the
            // authoritative transcript) may skip the caller's restoration; a
            // failed reconnect must fall back to it.
            reconnected = probeClient?.isConnected == true
        }
        guard isCurrentOrAliasedComposerSubmission(submissionContext),
              let probeClient else { return (.unresolved, reconnected) }
        // The alias set was captured from the ORIGINAL submission before any
        // await; it is never re-derived from the mutable active session here.
        let rows: [LiveSessionStatus]
        do {
            if let probeActiveSessions = chatResumeLifecycleOperations.probeActiveSessions {
                rows = try await probeActiveSessions(probeClient)
            } else {
                rows = try await probeClient.activeSessions()
            }
        } catch {
            return (.unresolved, reconnected)
        }
        guard let row = rows.first(where: {
            acceptedSessionIDs.contains($0.runtimeSessionId) || acceptedSessionIDs.contains($0.storedSessionId)
        }) else {
            // No runtime for this conversation anymore: current liveness is
            // gone, but that alone cannot prove non-acceptance — the accepted
            // turn may have completed and been reaped. Verify durably below.
            let transcript = await verifySubmittedTurnInTranscript(
                requestedSessionID: requestedSessionID,
                profile: submissionContext.profile,
                baseline: baseline,
                submittedText: submittedText
            )
            switch transcript {
            case .present: return (.acceptedSettled, reconnected)
            case .absent: return (.notAccepted, reconnected)
            case .indeterminate: return (.unresolved, reconnected)
            }
        }
        if row.isRunning {
            // A committed-busy runtime can only describe an accepted,
            // still-running submission.
            let resolution: AmbiguousPromptResolution = self.client === probeClient
                ? .acceptedRunning
                : .acceptedSettled
            return (resolution, reconnected)
        }
        // The registry is authoritative about CURRENT liveness only: an
        // idle/absent-or-starting runtime cannot by itself prove
        // non-acceptance, because the accepted turn may have completed (and
        // the runtime gone idle or been reaped) before recovery looked. Fall
        // through to the durable transcript.
        let transcript = await verifySubmittedTurnInTranscript(
            requestedSessionID: requestedSessionID,
            profile: submissionContext.profile,
            baseline: baseline,
            submittedText: submittedText
        )
        switch transcript {
        case .present:
            return (.acceptedSettled, reconnected)
        case .absent:
            return (.notAccepted, reconnected)
        case .indeterminate:
            return (.unresolved, reconnected)
        }
    }

    /// Durable before/after identity captured BEFORE the optimistic append.
    /// The submitted turn is proven by ORDERING (rows the conversation did not
    /// hold at submit time) corroborated by user-role content — never by
    /// content alone, since identical texts are legitimate.
    struct PromptTranscriptBaseline {
        let knownMessageIDs: Set<String>
        let knownMessageCount: Int

        init(messages: [ChatMessage]) {
            self.knownMessageIDs = Set(messages.map(\.id))
            self.knownMessageCount = messages.count
        }
    }

    private enum SubmittedTurnEvidence {
        case present
        case absent
        case indeterminate
    }

    /// Bounded tail read (the PR #118 `order=latest` page via the existing
    /// persisted-transcript source) to decide whether an ambiguously
    /// acknowledged prompt actually landed. `profile` comes from the owning
    /// submission context, captured before any await.
    private func verifySubmittedTurnInTranscript(
        requestedSessionID: String,
        profile: String,
        baseline: PromptTranscriptBaseline,
        submittedText: String
    ) async -> SubmittedTurnEvidence {
        let outcome = await persistedTranscriptOutcome(
            sessionId: requestedSessionID,
            profile: profile,
            using: dashboardTicketBridge
        )
        let tail: [ChatMessage]
        let idsAreDurable: Bool
        switch outcome {
        case .hydrated(let persisted):
            tail = persisted.messages
            // A paginated page only comes back when the echo honored the
            // tail contract AND the rows carried durable identity; the
            // legacy one-shot re-read makes no such guarantee.
            idsAreDurable = persisted.page != nil
        case .unavailable, .failed:
            // No usable durable source: acceptance stays unproven.
            return .indeterminate
        }

        let wanted = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNewRow: (ChatMessage) -> Bool = { message in
            !baseline.knownMessageIDs.contains(message.id)
        }
        let contentMatches: (ChatMessage) -> Bool = { message in
            message.role == .user
                && message.content.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }

        if idsAreDurable {
            if tail.contains(where: { isNewRow($0) && contentMatches($0) }) {
                // A user row this conversation did not hold before the
                // submission carries the submitted text: the turn landed.
                // Response rows after it only strengthen the proof; their
                // absence means the accepted turn was interrupted, which is
                // still acceptance.
                return .present
            }
            if tail.contains(where: isNewRow) {
                // The durable transcript advanced past the submit-time
                // baseline without any new user row carrying the submitted
                // text: whatever landed, this prompt did not.
                return .absent
            }
            // The tail is exactly what this conversation already held: no
            // new row at all — the submitted turn never landed.
            return .absent
        }

        // Positional-id fallback (legacy one-shot transcript): row identity
        // cannot distinguish new from old rows, so decide by transcript
        // growth plus the newest user row.
        if tail.count <= baseline.knownMessageCount {
            // Nothing landed beyond what this conversation already held.
            return .absent
        }
        let newestUserRow = tail.last(where: { $0.role == .user })
        if let newestUserRow, contentMatches(newestUserRow) {
            // The transcript grew and its newest user turn carries the
            // submitted text: acceptance, settled.
            return .present
        }
        if tail.contains(where: contentMatches) {
            // Grew with our text present but not newest — an identical older
            // send makes this ambiguous.
            return .indeterminate
        }
        // Grew without the submitted text: this prompt did not land.
        return .absent
    }

    func toggleYolo(context: ComposerSubmissionContext? = nil) async {
        let submissionContext = context ?? composerSubmissionContext()
        _ = await setYoloMode(!runtime.yolo, context: submissionContext)
    }

    @discardableResult
    func setYoloMode(
        _ enabled: Bool,
        context: ComposerSubmissionContext? = nil
    ) async -> Bool {
        let submissionContext = context ?? composerSubmissionContext()
        guard isCurrentComposerSubmission(submissionContext) else { return false }
        guard runtime.approvalsMode?.lowercased() != "off" else {
            // Hermes auto-approves globally under approvals.mode == "off"; the
            // per-session write is a server-side no-op, and persisting an
            // override here would silently resurface when the profile mode
            // changes back. Send nothing and keep the effective floor state.
            runtime.yolo = true
            return true
        }
        guard let client, let sessionId = activeSessionId else { return false }
        let persistedSessionID = canonicalSessionID(for: sessionId) ?? sessionId
        // Ownership is captured ONCE, before the await, from the originating
        // submission profile. begin and the deferred cleanup therefore touch
        // the exact same keys even if the active profile/session changes
        // while the RPC is suspended (profile-switch bookkeeping leak).
        let writeKeys = sessionYoloKeys(
            profile: submissionContext.profile,
            sessionIDs: [sessionId, persistedSessionID]
        )
        beginSessionYoloWrite(keys: writeKeys)
        defer { endSessionYoloWrite(keys: writeKeys) }
        do {
            if let setSessionYolo = chatResumeLifecycleOperations.setSessionYolo {
                try await setSessionYolo(client, sessionId, enabled)
            } else {
                try await client.setSessionYolo(sessionId, enabled: enabled)
            }
            // Hermes accepted the setting. Avoid publishing it into a new
            // session if the composer origin was handed off while awaiting.
            guard isCurrentComposerSubmission(submissionContext) else { return true }
            sessionYoloStore.setOverride(
                enabled,
                for: activeProfile,
                sessionID: persistedSessionID
            )
            recordSessionYoloWrite(for: [sessionId, persistedSessionID])
            lastReportedSessionYolo = enabled
            runtime.yolo = enabled
            return true
        } catch {
            guard isCurrentComposerSubmission(submissionContext) else { return false }
            errorMessage = "Unable to change YOLO mode: \(error.localizedDescription)"
            return false
        }
    }

    /// Re-assert a persisted per-session YOLO override after a resume.
    ///
    /// The Hermes gateway keeps the per-session YOLO flag in memory only and
    /// never persists it (unlike the CLI), so a gateway restart or rebuilt
    /// agent forgets the flag and reverts to the profile default. Re-sending
    /// `config.set` restores the user's explicit choice so the server keeps
    /// honoring it. No-op when the profile approval mode is already "off" (the
    /// flag is then moot), when there is no stored override, when the snapshot
    /// does not report a session-level yolo (unknown is not a disagreement),
    /// or when the server's reported value already matches the override.
    /// Failure is non-fatal: the local override still governs the indicator
    /// and the next resume retries.
    private func reassertSessionYolo(
        for sessionId: String,
        snapshot: SessionRuntimeSnapshot,
        using client: HermesClient
    ) async {
        // Use the same resolved floor source applyRuntime just updated (the
        // snapshot's value when present, else the last-known mode) so the
        // floor decision and the re-assert decision can never diverge when a
        // snapshot omits approvals_mode.
        guard runtime.approvalsMode?.lowercased() != "off" else { return }
        let persistedSessionID = canonicalSessionID(for: sessionId) ?? sessionId
        // A user write awaiting its RPC has not reached the store yet;
        // re-asserting now could read the pre-toggle override and land after
        // the user's write, leaving the server on the stale value. Skip — the
        // user's write settles the server and the next resume reconciles.
        guard !hasInFlightSessionYoloWrite(sessionIDs: [persistedSessionID, sessionId]) else { return }
        guard let override = sessionYoloStore.storedOverride(
            for: activeProfile,
            sessionIDs: [persistedSessionID, sessionId]
        ) else { return }
        // A snapshot that omits the session-level yolo is unknown, not a
        // disagreement; re-asserting on every resume for gateways that omit the
        // field would be pure churn. The gateway's session.info projection
        // reports yolo as a boolean, so a real conflict is always visible.
        guard let reportedYolo = snapshot.yolo, reportedYolo != override else { return }
        do {
            if let setSessionYolo = chatResumeLifecycleOperations.setSessionYolo {
                try await setSessionYolo(client, sessionId, override)
            } else {
                try await client.setSessionYolo(sessionId, enabled: override)
            }
            recordSessionYoloWrite(for: [sessionId, persistedSessionID])
        } catch {
            sessionYoloLog.error(
                "Failed to re-assert session YOLO override \(override, privacy: .public) for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Slash Commands

    /// Keep the common Hermes commands discoverable even when an older gateway
    /// returns only skill entries from `commands.catalog`. Commands Conduit
    /// does not own locally still run through slash.exec / command.dispatch.
    private static let builtInSlashCommands: [SlashCommand] = [
        SlashCommand(name: "new", aliases: ["reset"], description: "Start a new conversation", category: "Session"),
        SlashCommand(name: "branch", aliases: ["fork"], description: "Branch this conversation into a new chat", category: "Session"),
        SlashCommand(name: "model", description: "Open the model and run settings", category: "Session"),
        SlashCommand(name: "yolo", description: "Toggle automatic tool approval", category: "Session"),
        SlashCommand(name: "help", aliases: ["commands"], description: "Show available slash commands", category: "Session"),
        SlashCommand(name: "approvals", description: "Show or set approval mode", category: "Hermes"),
        SlashCommand(name: "agents", aliases: ["tasks"], description: "Show active sessions and tasks", category: "Hermes"),
        SlashCommand(name: "background", aliases: ["bg", "btw"], description: "Run a prompt in the background", category: "Hermes"),
        SlashCommand(name: "compress", aliases: ["compact"], description: "Compress this conversation context", category: "Hermes"),
        SlashCommand(name: "debug", description: "Create a debug report", category: "Hermes"),
        SlashCommand(name: "goal", description: "Manage this session's standing goal", category: "Hermes"),
        SlashCommand(name: "personality", description: "Switch the session personality", category: "Hermes"),
        SlashCommand(name: "queue", aliases: ["q"], description: "Queue a prompt for the next turn", category: "Hermes"),
        SlashCommand(name: "retry", description: "Retry the last user message", category: "Hermes"),
        SlashCommand(name: "rollback", description: "List or restore filesystem checkpoints", category: "Hermes"),
        SlashCommand(name: "save", description: "Save the current transcript", category: "Hermes"),
        SlashCommand(name: "status", description: "Show current session status", category: "Hermes"),
        SlashCommand(name: "steer", description: "Steer the current run", category: "Hermes"),
        SlashCommand(name: "stop", description: "Stop running background processes", category: "Hermes"),
        SlashCommand(name: "tools", description: "List or toggle agent tools", category: "Hermes"),
        SlashCommand(name: "undo", description: "Remove the last user and assistant exchange", category: "Hermes"),
        SlashCommand(name: "usage", description: "Show this session's token usage", category: "Hermes"),
        SlashCommand(name: "version", description: "Show the Hermes Agent version", category: "Hermes")
    ]

    private static func normalizedSlashCatalog(_ payload: AnyCodable) -> [SlashCommand] {
        let object = payload.objectValue ?? [:]
        var commands: [String: SlashCommand] = [:]

        func add(_ command: SlashCommand) {
            guard !command.name.isEmpty, commands[command.name] == nil else { return }
            commands[command.name] = command
        }

        if let categories = object["categories"]?.arrayValue {
            for category in categories {
                guard let categoryObject = category.objectValue else { continue }
                let categoryName = categoryObject["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                for pair in categoryObject["pairs"]?.arrayValue ?? [] {
                    if let command = slashCommand(from: pair, category: categoryName) {
                        add(command)
                    }
                }
            }
        }

        for pair in object["pairs"]?.arrayValue ?? [] {
            if let command = slashCommand(from: pair, category: "Skills & extensions") {
                add(command)
            }
        }

        if let canon = object["canon"]?.objectValue {
            for (rawAlias, rawCanonical) in canon {
                let alias = normalizedSlashName(rawAlias)
                let canonical = normalizedSlashName(rawCanonical.stringValue ?? "")
                guard !alias.isEmpty, alias != canonical, var command = commands[canonical] else { continue }
                if !command.aliases.contains(alias) {
                    command.aliases.append(alias)
                    command.aliases.sort()
                    commands[canonical] = command
                }
            }
        }

        for builtin in builtInSlashCommands {
            if commands[builtin.name] == nil {
                commands[builtin.name] = builtin
            }
        }

        return commands.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func slashCommand(from value: AnyCodable, category: String?) -> SlashCommand? {
        if let pair = value.arrayValue, let rawName = pair.first?.stringValue {
            let name = normalizedSlashName(rawName)
            guard !name.isEmpty else { return nil }
            let description = pair.dropFirst().first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SlashCommand(name: name, description: description?.isEmpty == false ? description! : "Hermes command", category: category)
        }
        guard let object = value.objectValue else { return nil }
        let name = normalizedSlashName(object["name"]?.stringValue ?? object["command"]?.stringValue ?? "")
        guard !name.isEmpty else { return nil }
        return SlashCommand(
            name: name,
            aliases: (object["aliases"]?.arrayValue ?? [])
                .compactMap { $0.stringValue }
                .map { normalizedSlashName($0) }
                .filter { !$0.isEmpty },
            description: object["description"]?.stringValue ?? object["desc"]?.stringValue ?? "Hermes command",
            category: category,
            argsHint: object["args_hint"]?.stringValue ?? object["argsHint"]?.stringValue
        )
    }

    private static func normalizedSlashName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
            .lowercased()
    }

    private static func parseSlashCommand(_ text: String) -> (name: String, argument: String, cleaned: String)? {
        let trimmed = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        guard trimmed.hasPrefix("/") else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        return (normalizedSlashName(String(first)), parts.count > 1 ? String(parts[1]) : "", cleaned)
    }

    func loadSlashCommands() async {
        guard let client else { return }
        let profile = activeProfile
        let sessionID = activeSessionId
        do {
            let result = try await client.commandsCatalog(sessionId: sessionID)
            guard profile == activeProfile, self.client === client else { return }
            slashCommands = Self.normalizedSlashCatalog(result)
        } catch {
            // Non-fatal — keep whatever we have
        }
    }

    private static func normalizeSlashCatalog(_ payload: AnyCodable) -> [SlashCommand] {
        let obj = payload.objectValue ?? [:]
        var commands: [SlashCommand] = []

        // Categories path: [{ name, pairs: [[name, desc], ...] }]
        if let categories = obj["categories"]?.arrayValue, !categories.isEmpty {
            for cat in categories {
                guard let catObj = cat.objectValue else { continue }
                let catName = catObj["name"]?.stringValue
                if let pairs = catObj["pairs"]?.arrayValue {
                    for pair in pairs {
                        if let cmd = pairFromTuple(pair, category: catName) {
                            commands.append(cmd)
                        }
                    }
                }
            }
        }

        // Top-level pairs fallback
        if commands.isEmpty, let pairs = obj["pairs"]?.arrayValue {
            for pair in pairs {
                if let cmd = pairFromTuple(pair, category: nil) {
                    commands.append(cmd)
                }
            }
        }

        // Deduplicate by name, keeping first occurrence
        var seen = Set<String>()
        return commands.filter { cmd in
            if seen.contains(cmd.name) { return false }
            seen.insert(cmd.name)
            return true
        }
    }

    /// Parses a [name, description] tuple from the catalog.
    private static func pairFromTuple(_ pair: AnyCodable, category: String?) -> SlashCommand? {
        if let arr = pair.arrayValue, arr.count >= 1 {
            let name = arr[0].stringValue ?? ""
            let desc = arr.count > 1 ? (arr[1].stringValue ?? "") : ""
            guard !name.isEmpty else { return nil }
            return SlashCommand(name: name, description: desc, category: category)
        }
        // Some gateways return objects instead of tuples
        if let pairObj = pair.objectValue {
            let name = pairObj["name"]?.stringValue ?? pairObj["command"]?.stringValue ?? ""
            let desc = pairObj["description"]?.stringValue ?? pairObj["desc"]?.stringValue ?? ""
            let aliases = pairObj["aliases"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            guard !name.isEmpty else { return nil }
            return SlashCommand(name: name, aliases: aliases, description: desc, category: category)
        }
        return nil
    }

    func executeSlashCommand(
        _ text: String,
        context: ComposerSubmissionContext? = nil
    ) async {
        let submissionContext = context ?? composerSubmissionContext()
        guard isCurrentComposerSubmission(submissionContext) else { return }
        guard let client,
              let sessionId = activeSessionId,
              let command = Self.parseSlashCommand(text) else { return }

        // Client-side special cases
        switch command.name {
        case "new", "reset":
            guard !isProfileSwitching, isConnected, !isConnecting else {
                if isProfileSwitching || isConnecting {
                    errorMessage = "Wait for the workspace switch to finish before starting a conversation."
                }
                return
            }
            cancelChatResumeRestoration()
            await createNewSession()
            return
        case "branch", "fork":
            guard !isBusy else {
                errorMessage = "Stop the active response before branching this conversation."
                return
            }
            guard !isBranchingChat, !isProfileSwitching else { return }
            guard let assistantMessage = messages.last(where: { $0.role == .assistant }) else {
                errorMessage = "There is no assistant response to branch from yet."
                return
            }
            guard let messageIndex = messages.firstIndex(where: { $0.id == assistantMessage.id }),
                  messages[...messageIndex].contains(where: { message in
                      guard message.role == .user || message.role == .assistant else {
                          return false
                      }
                      let content = (message.role == .user ? message.rawContent : nil)
                          ?? message.content
                      return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                errorMessage = "There is no message history to branch from."
                return
            }
            cancelChatResumeRestoration()
            await branchFromAssistantMessage(assistantMessage.id)
            return
        case "model":
            if command.argument.isEmpty {
                cancelChatResumeRestoration()
                showModelPicker = true
                return
            }
        case "yolo":
            if command.argument.isEmpty {
                cancelChatResumeRestoration()
                await toggleYolo(context: submissionContext)
                return
            }
        case "help":
            cancelChatResumeRestoration()
            appendSlashOutput(Self.formatSlashHelp(), context: submissionContext)
            return
        default:
            break
        }

        // Server-side execution
        cancelChatResumeRestoration()
        do {
            let result = try await executeGatewaySlash(
                client: client,
                sessionID: sessionId,
                command: command.cleaned,
                context: submissionContext
            )
            guard isCurrentComposerSubmission(submissionContext) else { return }
            await handleSlashResult(
                result,
                depth: 0,
                aliasArgument: command.argument,
                client: client,
                sessionID: sessionId,
                context: submissionContext
            )
        } catch {
            guard isCurrentComposerSubmission(submissionContext) else { return }
            appendSlashOutput(
                "⚠️ Command failed: \(error.localizedDescription)",
                context: submissionContext
            )
        }
    }

    private func executeGatewaySlash(
        client: HermesClient,
        sessionID: String,
        command: String,
        context: ComposerSubmissionContext? = nil
    ) async throws -> AnyCodable {
        do {
            if let executeSlash = chatResumeLifecycleOperations.executeSlash {
                return try await executeSlash(client, sessionID, command)
            }
            return try await client.executeSlash(sessionId: sessionID, command: command)
        } catch {
            if let context {
                guard isCurrentComposerSubmission(context) else { throw error }
            }
            guard let parsed = Self.parseSlashCommand(command) else { throw error }
            if let dispatchCommand = chatResumeLifecycleOperations.dispatchCommand {
                return try await dispatchCommand(
                    client,
                    sessionID,
                    parsed.name,
                    parsed.argument
                )
            }
            return try await client.dispatchCommand(sessionId: sessionID, name: parsed.name, arg: parsed.argument)
        }
    }

    private func handleSlashResult(
        _ result: AnyCodable,
        depth: Int,
        aliasArgument: String,
        client: HermesClient,
        sessionID: String,
        context: ComposerSubmissionContext
    ) async {
        guard isCurrentComposerSubmission(context) else { return }
        guard depth < 4 else {
            appendSlashOutput("⚠️ Too many command aliases.", context: context)
            return
        }

        let obj = result.objectValue ?? [:]
        let type = obj["type"]?.stringValue ?? ""
        let output = obj["output"]?.stringValue ?? obj["message"]?.stringValue ?? obj["notice"]?.stringValue ?? ""

        switch type {
        case "exec", "plugin":
            // Command executed server-side; show any output
            if !output.isEmpty {
                appendSlashOutput(output, context: context)
            }
        case "send", "skill":
            // These send a prompt — extract the message and send it
            let message = obj["message"]?.stringValue ?? output
            if !message.isEmpty {
                _ = await sendMessage(message, attachments: [], context: context)
            }
        case "prefill":
            if let notice = obj["notice"]?.stringValue, !notice.isEmpty {
                appendSlashOutput(notice, context: context)
            }
            let message = obj["message"]?.stringValue ?? output
            if !message.isEmpty, isCurrentComposerSubmission(context) {
                composerPrefillText = message
                composerPrefillToken = UUID()
            }
        case "alias":
            // Re-execute with the target command
            let target = obj["target"]?.stringValue ?? obj["command"]?.stringValue ?? obj["name"]?.stringValue ?? ""
            if !target.isEmpty {
                do {
                    guard isCurrentComposerSubmission(context) else { return }
                    let nestedCommand = aliasArgument.isEmpty ? target : "\(target) \(aliasArgument)"
                    let nested = try await executeGatewaySlash(
                        client: client,
                        sessionID: sessionID,
                        command: nestedCommand,
                        context: context
                    )
                    guard isCurrentComposerSubmission(context) else { return }
                    await handleSlashResult(
                        nested,
                        depth: depth + 1,
                        aliasArgument: aliasArgument,
                        client: client,
                        sessionID: sessionID,
                        context: context
                    )
                } catch {
                    guard isCurrentComposerSubmission(context) else { return }
                    appendSlashOutput(
                        "⚠️ Alias target failed: \(error.localizedDescription)",
                        context: context
                    )
                }
            } else if !output.isEmpty {
                appendSlashOutput(output, context: context)
            }
        default:
            // Unknown type — show output if present
            if !output.isEmpty {
                appendSlashOutput(output, context: context)
            }
        }
    }

    private func appendSlashOutput(
        _ text: String,
        context: ComposerSubmissionContext? = nil
    ) {
        if let context {
            guard isCurrentComposerSubmission(context) else { return }
        }
        // Mid-turn ordering rule: slash output must not land below the live
        // reasoning card's eventual commit.
        settleReasoningSegmentIntoTranscript()
        messages.append(ChatMessage(
            id: "slash-\(Date().timeIntervalSince1970)",
            role: .system,
            content: text,
            rawContent: nil,
            timestamp: Self.localTimestamp(),
            author: nil
        ))
        cacheMessagePresentation()
    }

    private static func formatSlashHelp() -> String {
        return "**Slash Commands**\n\nType `/` followed by a command name.\n\n**Built-in:**\n• `/new` — Start a new conversation\n• `/model` — Open the model picker\n• `/yolo` — Toggle auto-approve mode\n• `/help` — Show this help\n\nUse the suggestions list to discover gateway commands."
    }

    private func steer(
        _ text: String,
        context: ComposerSubmissionContext? = nil
    ) async -> Bool {
        let submissionContext = context ?? composerSubmissionContext()
        guard isCurrentComposerSubmission(submissionContext) else { return false }
        guard let client, let sessionId = activeSessionId else { return false }
        cancelChatResumeRestoration()
        do {
            if let steer = chatResumeLifecycleOperations.steer {
                try await steer(client, sessionId, text)
            } else {
                try await client.steer(sessionId, text: text)
            }
            // A successful steer is accepted by Hermes even if the user
            // switched sessions while the RPC was suspended. It has no local
            // post-await mutation, so preserve success for draft handling.
            return true
        } catch {
            guard isCurrentOrAliasedComposerSubmission(submissionContext) else { return false }
            errorMessage = error.localizedDescription
            await recoverComposerSubmission(using: submissionContext)
            return false
        }
    }

    /// The modern Hermes path. It interrupts and rebuilds the live model
    /// request while retaining completed work; gateways can also acknowledge a
    /// correction as queued during their agent-build window. Older gateways
    /// retain the established `session.interrupt` then `prompt.submit` flow.
    private func redirectOrInterruptAndSend(
        _ text: String,
        retriedAfterResume: Bool = false,
        context: ComposerSubmissionContext? = nil
    ) async -> Bool {
        let submissionContext = context ?? composerSubmissionContext()
        guard isCurrentComposerSubmission(submissionContext) else { return false }
        guard let client, let sessionId = activeSessionId else { return false }
        cancelChatResumeRestoration()

        do {
            let outcome: SessionRedirectOutcome
            if let redirect = chatResumeLifecycleOperations.redirect {
                outcome = try await redirect(client, sessionId, text)
            } else {
                outcome = try await client.redirect(sessionId, text: text)
            }
            switch outcome {
            case .redirected, .queued:
                if isCurrentOrAliasedComposerSubmission(submissionContext) {
                    appendLocalUserMessage(text)
                }
                return true
            case .rejected:
                // A reject commonly means the turn won the race to completion.
                // Reconcile first so we submit directly when it is already idle
                // instead of surfacing a misleading interrupt failure.
                guard isCurrentOrAliasedComposerSubmission(submissionContext) else { return false }
                guard let recoveredContext = await recoverComposerSubmission(using: submissionContext) else {
                    return false
                }
                guard isCurrentComposerSubmission(recoveredContext) else { return false }
                if turnState == .idle {
                    return await sendMessage(
                        text,
                        attachments: [],
                        context: recoveredContext
                    )
                }
                guard turnState == .running else { return false }
                return await interruptAndSendLegacy(text, context: recoveredContext)
            }
        } catch let error as RpcError {
            guard isCurrentOrAliasedComposerSubmission(submissionContext) else { return false }
            if isUnsupportedRedirect(error) {
                guard let currentContext = currentComposerSubmissionContextIfOwnedAndAliased(submissionContext) else {
                    return false
                }
                return await interruptAndSendLegacy(text, context: currentContext)
            }

            // A runtime session can be rotated while the app was backgrounded.
            // Reconcile once, then retry against the recovered runtime id.
            if !retriedAfterResume, isSessionNotFound(error) {
                guard let recoveredContext = await recoverComposerSubmission(using: submissionContext) else {
                    return false
                }
                guard isCurrentComposerSubmission(recoveredContext) else { return false }
                if turnState == .running {
                    return await redirectOrInterruptAndSend(
                        text,
                        retriedAfterResume: true,
                        context: recoveredContext
                    )
                }
                if turnState == .idle {
                    return await sendMessage(
                        text,
                        attachments: [],
                        context: recoveredContext
                    )
                }
                return false
            }

            errorMessage = "Could not redirect the active response: \(error.localizedDescription)"
            await recoverComposerSubmission(using: submissionContext)
            return false
        } catch {
            guard isCurrentOrAliasedComposerSubmission(submissionContext) else { return false }
            errorMessage = "Could not redirect the active response: \(error.localizedDescription)"
            await recoverComposerSubmission(using: submissionContext)
            return false
        }
    }

    private func interruptAndSendLegacy(
        _ text: String,
        context: ComposerSubmissionContext
    ) async -> Bool {
        guard await interruptForReplacement(context: context) else { return false }
        guard let currentContext = currentComposerSubmissionContextIfOwnedAndAliased(context) else {
            return false
        }
        return await sendMessage(text, attachments: [], context: currentContext)
    }

    private func appendLocalUserMessage(_ text: String) {
        // Hermes records redirect corrections itself. When the correction is
        // just a repeat of the prompt it interrupted, avoid rendering a second
        // identical outgoing bubble while the gateway catches up.
        if let interruption = messages.last,
           interruption.role == .system,
           MessageNormalizer.isUserCorrectionInterruptionNotice(interruption.rawContent ?? interruption.content),
           let previousUser = messages.dropLast().last(where: { $0.role == .user }),
           previousUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
                == text.trimmingCharacters(in: .whitespacesAndNewlines) {
            return
        }
        // Mid-turn ordering rule: a steer/redirect correction bubble must sit
        // above the live reasoning card's eventual commit. Reasoning that
        // resumes after the correction mounts a fresh segment below it,
        // matching the tool-boundary precedent.
        settleReasoningSegmentIntoTranscript()
        messages.append(ChatMessage(
            id: "local-correction-\(Date().timeIntervalSince1970)",
            role: .user,
            content: text,
            rawContent: nil,
            timestamp: Self.localTimestamp(),
            author: nil
        ))
        cacheMessagePresentation()
    }

    private func isUnsupportedRedirect(_ error: RpcError) -> Bool {
        let message = error.message.lowercased()
        return error.code == 4010
            || message.contains("does not support active-turn redirect")
            || message.contains("method not found")
    }

    private func isSessionNotFound(_ error: RpcError) -> Bool {
        error.message.lowercased().contains("session not found")
    }

    private func interruptForReplacement(
        context: ComposerSubmissionContext? = nil
    ) async -> Bool {
        let submissionContext = context ?? composerSubmissionContext()
        guard let currentContext = currentComposerSubmissionContextIfOwnedAndAliased(submissionContext) else {
            return false
        }
        guard let client, let sessionId = currentContext.sessionID else { return false }
        cancelChatResumeRestoration()
        turnState = .synchronizing
        do {
            if let interrupt = chatResumeLifecycleOperations.interrupt {
                try await interrupt(client, sessionId)
            } else {
                try await client.cancel(sessionId)
            }
            guard isCurrentOrAliasedComposerSubmission(currentContext) else { return false }
            return true
        } catch {
            guard isCurrentOrAliasedComposerSubmission(currentContext) else { return false }
            errorMessage = "Could not interrupt the active response: \(error.localizedDescription)"
            await recoverComposerSubmission(using: currentContext)
            return false
        }
    }

    func cancelCurrent() async {
        guard isBusy else { return }
        let submissionContext = composerSubmissionContext()
        guard await interruptForReplacement(context: submissionContext) else { return }
        guard let currentContext = currentComposerSubmissionContextIfOwnedAndAliased(submissionContext) else { return }
        await recoverComposerSubmission(using: currentContext)
    }

    func respondToClarify(requestId: String, answer: String) async {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty,
              let index = messages.firstIndex(where: { $0.clarify?.requestId == requestId }),
              let current = messages[index].clarify,
              current.status == .pending || current.status == .error else { return }

        messages[index].clarify?.status = .submitting
        messages[index].clarify?.answer = trimmedAnswer
        messages[index].clarify?.error = nil
        setRunning(true)
        cacheMessagePresentation()

        // Plugin-minted clarify ids are answered through the relay's decision
        // loop (the gateway's own clarify id never reached this device); the
        // gateway-side middleware polls the relay and resolves the tool call.
        // Routed BEFORE the gateway-client guard: the relay answer needs only
        // the relay registration, and answering from a freshly-resumed push
        // is exactly when the gateway client may still be reconnecting.
        if requestId.hasPrefix(PendingDecisionPayload.relayRequestPrefix) {
            await respondToRelayClarify(requestId: requestId, answer: trimmedAnswer)
            return
        }
        guard let client else {
            messages[index].clarify?.status = .error
            messages[index].clarify?.answer = nil
            messages[index].clarify?.error = "Gateway connection is unavailable."
            cacheMessagePresentation()
            return
        }
        do {
            try await client.respondToClarification(requestId: requestId, answer: trimmedAnswer)
            guard let updatedIndex = messages.firstIndex(where: { $0.clarify?.requestId == requestId }) else { return }
            messages[updatedIndex].clarify?.status = .answered
            cacheMessagePresentation()
        } catch {
            guard let updatedIndex = messages.firstIndex(where: { $0.clarify?.requestId == requestId }) else { return }
            messages[updatedIndex].clarify?.status = .error
            messages[updatedIndex].clarify?.answer = nil
            if Self.isExpiredPromptError(error) {
                messages[updatedIndex].clarify?.error = "This question is no longer active — Hermes timed it out and continued."
            } else {
                messages[updatedIndex].clarify?.error = "Hermes did not accept that answer."
                errorMessage = error.localizedDescription
            }
            cacheMessagePresentation()
        }
    }

    private func respondToRelayClarify(requestId: String, answer: String) async {
        do {
            let outcome = try await PushNotificationService.shared.respondToRelayDecision(
                requestId: requestId,
                answer: answer
            )
            guard let updatedIndex = messages.firstIndex(where: { $0.clarify?.requestId == requestId }) else { return }
            switch outcome {
            case .answered:
                messages[updatedIndex].clarify?.status = .answered
                messages[updatedIndex].clarify?.answer = answer
            case .alreadyAnsweredElsewhere:
                // Another device resolved the decision with its own answer;
                // settle the card but do not display this device's rejected
                // text as if it were what Hermes received.
                messages[updatedIndex].clarify?.status = .answered
                messages[updatedIndex].clarify?.answer = nil
            case .noLongerActive:
                messages[updatedIndex].clarify?.status = .error
                messages[updatedIndex].clarify?.answer = nil
                messages[updatedIndex].clarify?.error = "This question is no longer active — it was timed out or already resolved."
            }
            cacheMessagePresentation()
        } catch {
            guard let updatedIndex = messages.firstIndex(where: { $0.clarify?.requestId == requestId }) else { return }
            messages[updatedIndex].clarify?.status = .error
            messages[updatedIndex].clarify?.answer = nil
            messages[updatedIndex].clarify?.error = error.localizedDescription
            cacheMessagePresentation()
        }
    }

    // MARK: - Profiles and preferences

    /// The dashboard endpoint is authoritative. `session.list` is only a
    /// legacy fallback because it is backed by the gateway's current runtime
    /// database and can otherwise leak or omit profile history.
    private func profileSessions(using client: HermesClient, forceRefresh: Bool = false) async throws -> [SessionSummary] {
        if let loadCatalog = chatResumeLifecycleOperations.loadCatalog {
            return try await loadCatalog(client, forceRefresh)
        }
        let profile = activeProfile
        if let dashboardTicketBridge {
            do {
                let cacheKey = "\(profile):exclude"
                let cronKey = "\(profile):cron"
                let maximumCatalogRetries = 3
                var catalogRetryCount = 0
                while true {
                    let generation = sessionCatalogCache.mutationGeneration
                    let shouldLoadHistory = sessionCatalogCache.shouldLoadFullHistory(
                        forKey: cacheKey,
                        forceRefresh: forceRefresh
                    )
                    let scopedResult = try await dashboardSessions(
                        profile: profile,
                        loadFullHistory: shouldLoadHistory,
                        using: dashboardTicketBridge
                    )
                    let scoped = scopedResult.sessions.filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }

                    let cached = sessionCatalogCache.cachedSessionsToMerge(
                        remoteSessions: scoped,
                        isAuthoritative: scopedResult.isAuthoritative,
                        forKey: cacheKey
                    ).filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    let merged = uniqueSessions(scoped + cached)

                    // Fetch cron sessions separately -- the main query excludes them.
                    let shouldLoadCron = sessionCatalogCache.shouldLoadFullHistory(
                        forKey: cronKey,
                        forceRefresh: forceRefresh
                    )
                    let cachedCronSessions = sessionCatalogCache.cachedSessions(forKey: cronKey)?.filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    let publishedCronSnapshot = self.cronSessions.filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    var didFetchCronSessions = false
                    let cronSessions: [SessionSummary]?
                    if !shouldLoadCron, let cachedCronSessions {
                        cronSessions = cachedCronSessions
                    } else {
                        do {
                            cronSessions = try await dashboardCronSessions(
                                profile: profile,
                                using: dashboardTicketBridge
                            ).filter {
                                sessionBelongsToProfile($0, profile: profile)
                            }
                            didFetchCronSessions = true
                        } catch {
                            // Keep a previous cron snapshot if one exists, but
                            // do not cache an empty result for a failed request.
                            cronSessions = nil
                        }
                    }

                    // A delete/archive/disconnect can run while either request
                    // is suspended. Never let this attempt overwrite the
                    // newer cache state; retry from the authoritative source.
                    guard profile == activeProfile,
                          self.dashboardTicketBridge === dashboardTicketBridge,
                          self.client === client else {
                        throw DashboardTicketBridgeError.notReady
                    }

                    let combined = uniqueSessions(
                        merged + (cronSessions ?? cachedCronSessions ?? publishedCronSnapshot)
                    )
                    if !combined.isEmpty || shouldLoadHistory == false {
                        var historyMarkers: [String: Date] = [:]
                        if scopedResult.isAuthoritative && !scoped.isEmpty {
                            historyMarkers[cacheKey] = Date()
                        }
                        if didFetchCronSessions {
                            historyMarkers[cronKey] = Date()
                        }
                        guard sessionCatalogCache.commit(
                            liveSessions: combined,
                            liveKey: cacheKey,
                            cronSessions: cronSessions,
                            cronKey: cronKey,
                            historyMarkers: historyMarkers,
                            at: generation
                        ) else {
                            catalogRetryCount += 1
                            guard catalogRetryCount < maximumCatalogRetries else {
                                sessionCatalogLog.warning(
                                    "Dashboard catalog mutation retry budget exhausted for \(profile, privacy: .public); using gateway fallback."
                                )
                                break
                            }
                            continue
                        }
                        sessionCatalogLog.notice("Dashboard catalog for \(profile, privacy: .public): \(combined.count, privacy: .public) sessions; \(self.sourceSummary(combined), privacy: .public)")
                        return combined
                    }
                    break
                }
            } catch {
                guard profile == activeProfile,
                      self.dashboardTicketBridge === dashboardTicketBridge,
                      self.client === client else {
                    throw DashboardTicketBridgeError.notReady
                }
                sessionCatalogLog.error("Dashboard history failed; using gateway fallback: \(error.localizedDescription, privacy: .public)")
                // Keep older dashboard installations usable; the gateway is
                // still an authoritative fallback when the history endpoint is
                // unavailable.
            }
        }
        return try await client.sessions().filter {
            sessionBelongsToProfile($0, profile: profile) && $0.messageCount != 0
        }
    }

    /// A profile-scoped request may still return rows from another profile on
    /// older dashboards. Never let an explicitly tagged foreign session enter
    /// this profile's catalog or become selectable through its socket.
    private func sessionBelongsToProfile(_ session: SessionSummary, profile: String) -> Bool {
        guard let owner = session.profile,
              !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return profilesMatch(owner, profile)
    }

    private func profilesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// Mirrors Hermes Desktop's `/api/sessions/{id}/messages` prefetch:
    /// fetches the session's persisted transcript through the dashboard
    /// history route (or the test seam standing in for it) and parses it with
    /// the production normalizer path. The typed outcome lets the resume
    /// reconciliation distinguish a missing history source — which triggers
    /// the legacy full-transcript resume — from an unrelated failure, which
    /// must surface instead of silently degrading.
    ///
    /// The request is explicitly bounded (tail-anchored page of
    /// `PersistedTranscriptPagination.pageSize` rows) so the transport and
    /// normalization cost of opening a conversation is bounded no matter how
    /// large the session grew. A response that carries the `order=latest`
    /// pagination echo answers under the paginated tail contract; one
    /// without it is a legacy one-shot full transcript and hydrates as
    /// before.
    private func persistedTranscriptOutcome(
        sessionId: String,
        profile: String,
        using bridge: DashboardTicketBridge?
    ) async -> PersistedTranscriptOutcome {
        let fetchOutcome = await fetchPersistedHistoryPayload(
            sessionId: sessionId,
            profile: profile,
            query: PersistedTranscriptPagination.tailQuery(offset: 0),
            using: bridge
        )

        switch fetchOutcome {
        case .unavailable:
            return .unavailable
        case .failed(let error):
            // Only STRUCTURAL endpoint absence degrades to the single legacy
            // resume. Transient trouble (429, 5xx, status-0 WebKit/network
            // failures, request timeouts, a bridge that never became ready)
            // surfaces instead: a slow or failing BOUNDED read must never
            // silently become a full-transcript WebSocket transport (the
            // giant-payload path compact resume exists to eliminate).
            if Self.historySourceIsUnavailable(error) {
                sessionCatalogLog.debug("Persisted transcript unavailable for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .unavailable
            }
            sessionCatalogLog.debug("Persisted transcript failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failed(error)
        case .payload(let response):
            guard let rawMessages = Self.persistedMessageRows(in: response) else {
                return .failed(HermesError.invalidResponse)
            }
            let page = PersistedTranscriptPagination.parse(response, rawRowCount: rawMessages.count)

            // A pagination echo WITHOUT the `order=latest` tail contract
            // describes a backend that pages from the oldest end: honoring
            // its offsets would walk the transcript forward from row zero
            // and never reach the newest rows. A paginated-contract page
            // whose rows lack durable identity is equally unpageable —
            // overlap dedup and the graft key on the persisted row ID, and
            // id-less rows would normalize to page-local positional IDs.
            // Either way, re-read one-shot — the exact request
            // pre-pagination Conduit made — and treat the response as the
            // legacy full transcript. Shape-detected from the response,
            // never version-sniffed, and performed at most once.
            if let page, !(page.honorsTailContract
                && PersistedTranscriptWindow.rowsHaveDurableIdentity(rawMessages)) {
                let oneShotOutcome = await fetchPersistedHistoryPayload(
                    sessionId: sessionId,
                    profile: profile,
                    query: PersistedTranscriptPagination.legacyQuery,
                    using: bridge
                )
                switch oneShotOutcome {
                case .payload(let fullResponse):
                    guard let fullRows = Self.persistedMessageRows(in: fullResponse) else {
                        return .failed(HermesError.invalidResponse)
                    }
                    return .hydrated(PersistedSessionTranscript(
                        resolvedSessionId: Self.resolvedSessionId(in: fullResponse) ?? Self.resolvedSessionId(in: response),
                        messages: MessageNormalizer.normalizeMessages(fullRows.map(AnyCodable.from)),
                        page: nil
                    ))
                case .unavailable:
                    return .unavailable
                case .failed(let error):
                    if case DashboardTicketBridgeError.oversizedResponse = error {
                        // The legacy one-shot transcript outgrew the safe
                        // bound: an old backend attempted the entire
                        // transcript. Surface the transcript-specific
                        // compatibility copy.
                        return .failed(LegacyTranscriptOversizedError(limit: DataURLLimits.maxJSONResponseBytes))
                    }
                    if Self.historySourceIsUnavailable(error) {
                        return .unavailable
                    }
                    return .failed(error)
                }
            }

            // The dashboard server returns `messages`; the API-server variant
            // returns `data`, so accept both public Hermes response shapes.
            return .hydrated(PersistedSessionTranscript(
                resolvedSessionId: Self.resolvedSessionId(in: response),
                messages: MessageNormalizer.normalizeMessages(rawMessages.map(AnyCodable.from)),
                page: page
            ))
        }
    }

    private func fetchPersistedHistoryPayload(
        sessionId: String,
        profile: String,
        query: String,
        using bridge: DashboardTicketBridge?
    ) async -> PersistedTranscriptFetchOutcome {
        if let persistedTranscript = chatResumeLifecycleOperations.persistedTranscript {
            return await persistedTranscript(sessionId, profile)
        }
        guard let bridge else { return .unavailable }
        do {
            return .payload(try await bridge.requestJSON(
                path: Self.sessionMessagesPath(sessionId: sessionId, profile: profile, query: query)
            ))
        } catch {
            // requestJSON's readiness poll is the bounded wait for a cold
            // or reloading bridge; whatever it raises is classified with
            // the seam-sourced failures below. Note the bridge caps REST
            // response size (DataURLLimits.maxJSONResponseBytes), so an
            // oversized transcript also lands here rather than silently
            // degrading the resume.
            return .failed(error)
        }
    }

    /// The dashboard server returns `messages`; the API-server variant
    /// returns `data`, so accept both public Hermes response shapes.
    nonisolated static func persistedMessageRows(in response: [String: Any]) -> [Any]? {
        ["messages", "data", "_array"]
            .compactMap { response[$0] as? [Any] }
            .first
    }

    nonisolated static func resolvedSessionId(in response: [String: Any]) -> String? {
        (response["session_id"] as? String) ?? (response["sessionId"] as? String)
    }

    /// Classifies a history-fetch failure as STRUCTURAL ENDPOINT ABSENCE —
    /// the only condition that degrades the initial hydration to the single
    /// legacy full-transcript resume, and the only one that retires the
    /// backfill affordance:
    ///
    ///  - 404/410 — the gateway predates the messages route (or the session
    ///    is gone from it);
    ///  - 501 — the endpoint is explicitly unimplemented.
    ///
    /// Everything else must NOT silently escalate to the unbounded legacy
    /// transport: transient trouble (408/429, any other 5xx, status-0
    /// WebKit/network failures), a bridge that did not become ready or a
    /// request that outlived its deadline (both `.notReady`), an oversized
    /// response, authentication, and every unlisted error surfaces instead.
    /// This is the giant-session safety property: current Hermes can serve
    /// the bounded `include_compacted=true` page slowly for heavily
    /// compacted sessions until upstream bounding lands (#97440), so a slow
    /// bounded read must fail boundedly and retry through reconnect — never
    /// silently become "load the entire transcript over the WebSocket".
    nonisolated static func historySourceIsUnavailable(_ error: Error) -> Bool {
        guard case let DashboardTicketBridgeError.http(status, _) = error else { return false }
        switch status {
        case 404, 410, 501: return true
        default: return false
        }
    }

    nonisolated static func sessionMessagesPath(
        sessionId: String,
        profile: String,
        query: String
    ) -> String {
        let encodedSessionId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        return DashboardPath.withProfile(
            "/api/sessions/\(encodedSessionId)/messages\(query)",
            profile: profile
        )
    }

    /// Whether a persisted-history window from the previous reconciliation
    /// belongs to the conversation this reconcile just accepted. Identity is
    /// compared through the ONE centralized rule with the new transaction's
    /// full identity set (requested, resolved stored, runtime), so a
    /// reconnect keeps the backfilled prefix even when the catalog is
    /// temporarily stale about the stored↔runtime alias.
    private func priorWindowOwnsThisConversation(
        _ window: PersistedTranscriptWindowState?,
        requestedSessionId: String,
        resolvedSessionId: String?,
        runtimeSessionId: String?,
        profile: String
    ) -> Bool {
        guard let window else { return false }
        let conversationIds = PersistedTranscriptWindow.normalizingSessionIDs([
            requestedSessionId, resolvedSessionId, runtimeSessionId
        ])
        return PersistedTranscriptWindow.ownershipHolds(
            window: window,
            conversationSessionIds: conversationIds,
            profile: profile,
            windowAliasIds: catalogAliasIDs(for: window.trustedSessionIDs),
            conversationAliasIds: catalogAliasIDs(for: conversationIds)
        )
    }

    /// Fetches the next older persisted-history page for the active
    /// conversation and prepends it, keeping the user's visible position
    /// stable (ChatView anchors the prepend through the viewport controller).
    /// Strictly user-driven and single-flight: one explicit request at a
    /// time, owned by the window identity captured at request time, and a
    /// response from a session/profile that is no longer current is
    /// discarded without touching state.
    ///
    /// Returns whether a prepend actually published — the view discharges
    /// its viewport anchor when nothing landed, so an armed anchor can never
    /// re-pin on some later unrelated transcript change.
    @discardableResult
    func loadEarlierMessages() async -> Bool {
        guard let window = persistedTranscriptWindow,
              window.canLoadEarlier,
              !window.isLoadingEarlier else {
            return false
        }
        guard persistedTranscriptWindowOwnershipIsCurrent(window) else {
            // No user-facing error for an already-departed conversation —
            // and normally unreachable from a tap, because the affordance
            // exposes this exact ownership truth. The debug capture below
            // is purely diagnostic (it also fires on the legitimate
            // render-to-tap race during a session switch).
            sessionCatalogLog.debug("""
                Older-page backfill rejected ownership of an otherwise-actionable window: \
                requested=\(window.requestedSessionID, privacy: .public) \
                resolved=\(window.resolvedSessionID ?? "none", privacy: .public) \
                runtime=\(window.runtimeSessionID ?? "none", privacy: .public) \
                active=\(self.activeSessionId ?? "none", privacy: .public) \
                windowProfile=\(window.profile, privacy: .public) \
                activeProfile=\(self.activeProfile, privacy: .public)
                """)
            return false
        }
        // Older pages are persisted transcript history: continue against
        // the durable stored identity the hydration resolved (Desktop's
        // `BackfillRequest.storedSessionId` contract) — never the runtime
        // WebSocket ID, and never re-derived from a later catalog refresh.
        let wireSessionId = window.resolvedSessionID ?? window.requestedSessionID
        let requestedSessionId = window.requestedSessionID
        let profile = window.profile
        let offset = window.nextOffset
        var arming = window
        arming.isLoadingEarlier = true
        persistedTranscriptWindow = arming

        let outcome = await fetchOlderTranscriptPage(
            sessionId: wireSessionId,
            profile: profile,
            offset: offset
        )

        // Stale-response guard: the window must still be this exact
        // request's window (same session, same profile, still loading, and
        // no other fetch advanced it meanwhile). Anything else — session
        // switch, profile switch, disconnect re-home — discards the page.
        // The first four conditions identify THIS armed window; only then
        // may the bookkeeping below touch it.
        guard var current = persistedTranscriptWindow,
              current.requestedSessionID == requestedSessionId,
              current.profile == profile,
              current.nextOffset == offset,
              current.isLoadingEarlier else {
            return false
        }
        guard persistedTranscriptWindowOwnershipIsCurrent(current) else {
            // The armed window survived untouched but the conversation
            // moved on underneath it (e.g. activeSessionId cleared by a
            // disconnect). Discard the response whole AND release the
            // single-flight flag so the affordance can re-arm later — a
            // replaced window never reaches this branch.
            current.isLoadingEarlier = false
            persistedTranscriptWindow = current
            return false
        }
        current.isLoadingEarlier = false
        defer { persistedTranscriptWindow = current }

        switch outcome {
        case .payload(let response):
            guard let rawRows = Self.persistedMessageRows(in: response) else {
                // A malformed page is a backfill dead end, not a chat
                // failure: stop offering older pages rather than erroring
                // the already-hydrated conversation.
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .public) returned a malformed payload; retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            // Response ownership: the page must still describe THIS
            // conversation. The SAME centralized identity rule decides —
            // the echoed session_id plays the role of the checked
            // conversation — so an echo is accepted exactly when it is a
            // transaction-captured identity of this window or a
            // catalog-proven alias of one. Never a foreign session's rows;
            // a foreign response neither normalizes into the transcript
            // nor advances coverage.
            if let returnedId = Self.resolvedSessionId(in: response),
               !returnedId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !PersistedTranscriptWindow.ownershipHolds(
                 window: current,
                 conversationSessionIds: [returnedId],
                 profile: current.profile,
                 windowAliasIds: catalogAliasIDs(for: current.trustedSessionIDs),
                 conversationAliasIds: knownSessionIDs(for: returnedId)
               ) {
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .public) returned foreign session \(returnedId, privacy: .public); discarding and retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            let fetchedRowCount = rawRows.count
            let page = PersistedTranscriptPagination.parse(response, rawRowCount: fetchedRowCount)
            // Only pages still answering under the tail contract may splice
            // into the transcript: a response whose echo lost `order=latest`
            // carries oldest-anchored rows with unknown window semantics,
            // and prepending them would break chronology. That response
            // retires the affordance instead.
            guard let page, page.honorsTailContract else {
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .public) lost the tail contract; retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            // Overlap dedup keys on the durable persisted row ID. A page
            // whose rows lack one would normalize to page-local positional
            // IDs that cannot survive across pages — refuse it before it can
            // silently corrupt dedup.
            guard PersistedTranscriptWindow.rowsHaveDurableIdentity(rawRows) else {
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .public) returned rows without durable IDs; retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            var didPrepend = false
            if fetchedRowCount > 0 {
                let normalizedPage = MessageNormalizer.normalizeMessages(rawRows.map(AnyCodable.from))
                // A page boundary can split a tool call from its result row.
                // Fold any trailing call cards back together with the
                // matching held result cards by durable tool-call identity
                // before prepending, so one logical tool run never renders
                // as an orphan call card plus a duplicate standalone result.
                let (olderPage, foldedFromHeld) = PersistedTranscriptWindow.reconcilingToolCallsAcrossBoundary(
                    olderPage: normalizedPage,
                    held: messages
                )
                let merged: [ChatMessage]?
                if foldedFromHeld > 0 {
                    let remainingHeld = messages.dropFirst(foldedFromHeld)
                    if remainingHeld.isEmpty {
                        // Every held row folded into the adjusted page (the
                        // stale-response guard already proved this window is
                        // current): the folded page itself is the whole
                        // transcript. Never fall back to the unfolded page
                        // here — that would resurrect the duplicate the fold
                        // just removed.
                        merged = olderPage.isEmpty ? nil : olderPage
                    } else {
                        merged = PersistedTranscriptWindow.prepending(olderPage, onto: Array(remainingHeld))
                    }
                } else {
                    merged = nil
                }
                if let merged {
                    messages = merged
                    didPrepend = true
                } else if let plain = PersistedTranscriptWindow.prepending(normalizedPage, onto: messages) {
                    messages = plain
                    didPrepend = true
                }
            }
            if didPrepend {
                // The visible transcript now starts with backfilled rows.
                // The reconcile graft relies on this explicit fact to keep
                // preserving the prefix across repeated reconciles — the
                // network coverage reset below erases the offset evidence
                // after the first one.
                current.hasBackfilledPrefix = true
            }
            // A full page means older history may still exist; a short or
            // empty page marks the transcript fully backfilled and retires
            // the affordance. The offset advances by the fetched row count
            // either way, which self-corrects drift: a page that deduped to
            // nothing still moves the next request past the already-held
            // rows.
            current.nextOffset = offset + fetchedRowCount
            current.canLoadEarlier = fetchedRowCount > 0
                && page.mayHaveOlderRows(fetchedRowCount: fetchedRowCount)
            return didPrepend
        case .unavailable:
            // The history source went away mid-conversation; there is no
            // older page to offer.
            current.canLoadEarlier = false
            return false
        case .failed(let error):
            // Only a structurally gone history source retires the
            // affordance; transient trouble — rate limits, slow bounded
            // reads, a temporarily cold bridge — stays retryable through
            // another explicit tap. A failed backfill never loops on its
            // own.
            sessionCatalogLog.debug("Older-page backfill failed for \(wireSessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            current.canLoadEarlier = !Self.historySourceIsUnavailable(error)
            return false
        }
    }

    private func fetchOlderTranscriptPage(
        sessionId: String,
        profile: String,
        offset: Int
    ) async -> PersistedTranscriptFetchOutcome {
        if let loadEarlierTranscriptPage = chatResumeLifecycleOperations.loadEarlierTranscriptPage {
            return await loadEarlierTranscriptPage(sessionId, profile, offset)
        }
        // Backfill never falls through to the initial-hydration seam: that
        // seam cannot carry the offset, and a test wiring mistake would
        // otherwise become a silent always-duplicate affordance.
        guard let bridge = dashboardTicketBridge else { return .unavailable }
        do {
            return .payload(try await bridge.requestJSON(path: Self.sessionMessagesPath(
                sessionId: sessionId,
                profile: profile,
                query: PersistedTranscriptPagination.tailQuery(offset: offset)
            )))
        } catch {
            return .failed(error)
        }
    }

    /// Catalog alias knowledge for a set of session identities: every ID
    /// the live catalog groups with any of them (an unknown ID expands to
    /// just itself).
    private func catalogAliasIDs(for sessionIds: Set<String>) -> Set<String> {
        sessionIds.reduce(into: Set<String>()) { expanded, sessionId in
            expanded.formUnion(knownSessionIDs(for: sessionId))
        }
    }

    /// Ownership gate for the persisted-history window: the window must
    /// belong to the conversation that is actually active. The window's
    /// transaction-captured identities (requested, resolved stored, runtime)
    /// are the primary truth — `applyChatResume` re-homes `activeSessionId`
    /// to the runtime ID long before the catalog learns the alias — while
    /// catalog alias knowledge remains a compatibility source only.
    private func persistedTranscriptWindowOwnershipIsCurrent(
        _ window: PersistedTranscriptWindowState
    ) -> Bool {
        guard let activeId = activeSessionId else { return false }
        return PersistedTranscriptWindow.ownershipHolds(
            window: window,
            conversationSessionIds: [activeId],
            profile: activeProfile,
            windowAliasIds: catalogAliasIDs(for: window.trustedSessionIDs),
            conversationAliasIds: knownSessionIDs(for: activeId)
        )
    }

    /// Whether "Load earlier messages" may be offered AND executed right
    /// now: a hydrated, non-empty transcript whose persisted-history window
    /// still has an older page and belongs to the conversation that is
    /// actually active. The single ownership truth for the ChatView
    /// affordance and the `loadEarlierMessages` action, so the control can
    /// never render for a window the action would reject (the production
    /// no-op regression).
    var canLoadEarlierMessagesForActiveConversation: Bool {
        guard let window = persistedTranscriptWindow,
              window.canLoadEarlier,
              !messages.isEmpty,
              persistedTranscriptWindowOwnershipIsCurrent(window) else {
            return false
        }
        return true
    }

    /// The endpoint may resolve a runtime ID to its stored session ID. Accept
    /// any identifier already known for the selected session, just as Desktop
    /// verifies its REST prefetch before using it for a resumed transcript.
    private func transcriptMatchesSession(
        _ transcript: PersistedSessionTranscript,
        requestedSessionId: String,
        resumedSessionId: String
    ) -> Bool {
        guard let returnedId = transcript.resolvedSessionId,
              !returnedId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }

        var knownIds = Set([requestedSessionId, resumedSessionId])
        if let session = sessions.first(where: { session in
            let ids = [session.id] + session.alternateIds
            return ids.contains(requestedSessionId) || ids.contains(resumedSessionId)
        }) {
            knownIds.insert(session.id)
            knownIds.formUnion(session.alternateIds)
        }
        return knownIds.contains(returnedId)
    }

    private func dashboardSessions(
        profile: String,
        loadFullHistory: Bool,
        using bridge: DashboardTicketBridge
    ) async throws -> DashboardSessionCatalog {
        let maximumPages = loadFullHistory ? 25 : 1
        var sessions: [SessionSummary] = []
        var isAuthoritative = false

        for page in 0..<maximumPages {
            let offset = page * 200
            let response = try await bridge.requestJSON(path: profileSessionsPath(profile, offset: offset))
            let batch = response["sessions"] as? [Any] ?? []
            let normalizedBatch = dashboardOwnedSessions(batch, profile: profile)
            sessions += normalizedBatch

            let rawHasMore = response["has_more"] ?? response["hasMore"]
            let explicitHasMore = rawHasMore.map { booleanValue($0) }
            let nextOffset = integerValue(response["next_offset"] ?? response["nextOffset"])
            let total = integerValue(response["total"])
            let hasExplicitTerminalSignal = explicitHasMore == false
                || (nextOffset.map { $0 <= offset } ?? false)
                || (total.map { offset + batch.count >= $0 } ?? false)
            let hasMore = !hasExplicitTerminalSignal && (
                explicitHasMore == true
                    || (nextOffset ?? 0) > offset
                    || (total.map { offset + batch.count < $0 } ?? false)
                    || batch.count == 200
            )
            if batch.isEmpty {
                // An empty page after a non-empty prefix is not proof that
                // the full catalog was read. Preserve older rows and retry a
                // complete load later instead of evicting the cached suffix.
                break
            }
            if !hasMore {
                isAuthoritative = hasExplicitTerminalSignal && !normalizedBatch.isEmpty
                break
            }
        }

        return DashboardSessionCatalog(
            sessions: sessions,
            isAuthoritative: isAuthoritative
        )
    }

    private func dashboardArchivedSessions(
        profile: String,
        using bridge: DashboardTicketBridge
    ) async throws -> [SessionSummary] {
        var sessions: [SessionSummary] = []
        for page in 0..<25 {
            let offset = page * 200
            let response = try await bridge.requestJSON(path: archivedSessionsPath(profile, offset: offset))
            let batch = response["sessions"] as? [Any] ?? []
            sessions += dashboardOwnedSessions(batch, profile: profile)

            let nextOffset = integerValue(response["next_offset"] ?? response["nextOffset"])
            let total = integerValue(response["total"])
            let hasMore = booleanValue(response["has_more"] ?? response["hasMore"])
                || (nextOffset ?? 0) > offset
                || (total.map { offset + batch.count < $0 } ?? false)
                || batch.count == 200
            if !hasMore || batch.isEmpty { break }
        }
        return sessions
    }

    private func profileSessionsPath(_ profile: String, offset: Int = 0) -> String {
        DashboardPath.withExplicitProfile(
            "/api/profiles/sessions?limit=200&offset=\(offset)&min_messages=1&archived=exclude&order=recent&exclude_sources=cron",
            profile: profile
        )
    }

    private func archivedSessionsPath(_ profile: String, offset: Int = 0) -> String {
        DashboardPath.withExplicitProfile(
            "/api/profiles/sessions?limit=200&offset=\(offset)&min_messages=1&archived=only&order=recent&exclude_sources=cron",
            profile: profile
        )
    }

    /// Fetch cron sessions separately. The main profileSessionsPath uses
    /// exclude_sources=cron, so cron sessions never appear in the normal
    /// dashboard query. This dedicated path uses source=cron to populate
    /// the cron tab in the sidebar.
    private func dashboardCronSessions(
        profile: String,
        using bridge: DashboardTicketBridge
    ) async throws -> [SessionSummary] {
        let response = try await bridge.requestJSON(path: cronSessionsPath(profile, offset: 0))
        let batch = response["sessions"] as? [Any] ?? []
        return dashboardOwnedSessions(batch, profile: profile)
    }

    /// The official profile-session endpoint always tags every row with its
    /// owning profile. Do not substitute the requested profile here: doing so
    /// can relabel a foreign or malformed aggregate row and leak it into the
    /// selected workspace. The socket fallback remains profile-scoped and may
    /// still supply its known client profile to the normalizer.
    private func dashboardOwnedSessions(_ batch: [Any], profile: String) -> [SessionSummary] {
        MessageNormalizer.normalizeSessions(
            AnyCodable.from(["sessions": batch]),
            profile: nil
        ).filter { session in
            guard let owner = session.profile else { return false }
            // Hermes Desktop's sidebar uses min_messages=1. Keep the explicit
            // client-side guard as well for older servers that ignore the
            // query parameter; malformed empty shadow rows must not leak into
            // a profile's visible catalog.
            return profilesMatch(owner, profile) && session.messageCount != 0
        }
    }

    private func cronSessionsPath(_ profile: String, offset: Int = 0) -> String {
        DashboardPath.withExplicitProfile(
            "/api/profiles/sessions?limit=200&offset=\(offset)&min_messages=1&archived=exclude&order=recent&source=cron",
            profile: profile
        )
    }

    /// Hermes Desktop requests only persisted sessions with at least one
    /// message, but keeps a first turn visible while it is still in flight and
    /// the database row has not caught up yet. Retain only that live row; idle
    /// zero-message drafts and malformed profile shadows stay hidden.
    private func activeTurnCatalogSession() -> SessionSummary? {
        guard turnState.isRunning, let activeSessionId else { return nil }
        return (sessions + cronSessions).first { session in
            sessionBelongsToProfile(session, profile: activeProfile)
                && (session.id == activeSessionId || session.alternateIds.contains(activeSessionId))
        }
    }

    private func uniqueSessions(_ values: [SessionSummary]) -> [SessionSummary] {
        var seen = Set<String>()
        return values.filter { session in
            seen.insert("\(session.profile ?? activeProfile):\(session.id)").inserted
        }
    }

    private func sourceSummary(_ values: [SessionSummary]) -> String {
        Dictionary(grouping: values, by: \.source)
            .map { "\($0.key.rawValue)=\($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
    }

    func switchProfile(to profile: String) async {
        _ = await switchProfile(to: profile, reusing: nil)
    }

    @discardableResult
    private func switchProfile(
        to profile: String,
        reusing viewportTransitionGeneration: UInt64?
    ) async -> Bool {
        let target = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != activeProfile, let savedConnection = connection else {
            return false
        }
        guard !isProfileSwitching else { return false }
        // A profile change replaces the voice gateway; any in-flight read
        // aloud belongs to the outgoing profile.
        messageReadAloudController.stop()
        let transitionGeneration: UInt64
        if let viewportTransitionGeneration {
            guard chatViewportTransitionIsCurrent(
                generation: viewportTransitionGeneration
            ) else { return false }
            transitionGeneration = viewportTransitionGeneration
        } else {
            transitionGeneration = beginExplicitChatViewportTransition()
        }
        cancelChatResumeTransportRecovery()
        // Hard profile boundary for this forward transition: cancel the
        // debounced stream flush and write synchronously while the outgoing
        // profile still owns the in-memory transcript. No parked task
        // survives the identity changes below (success or rollback).
        flushPendingPresentationCache()
        cancelSecondaryProfileTitleRecovery()

        // Dismiss keyboard before switching profiles
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        let previousProfile = activeProfile
        let previousApprovalsMode = runtime.approvalsMode
        let previousYolo = runtime.yolo
        let previousLastReportedSessionYolo = lastReportedSessionYolo
        let previousSessions = sessions
        let previousCronSessions = cronSessions
        let previousArchivedSessions = archivedSessions
        let previousProjects = projects
        let previousSupportsProjects = supportsProjects
        isProfileSwitching = true
        defer { isProfileSwitching = false }
        invalidateReconciliation()
        turnState = .synchronizing
        // The next profile's approval mode is unknown until its first session
        // snapshot arrives; don't let the previous profile's floor leak across
        // the switch, and neutralize the indicator to the safe display
        // (approvals required) until the new profile resolves it.
        runtime.approvalsMode = nil
        runtime.yolo = false
        lastReportedSessionYolo = nil

        do {
            let ticket = try await mintChatResumeTicket(for: savedConnection)
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
                return false
            }
            let freshConnection = HermesConnection(baseUrl: savedConnection.baseUrl, ticket: ticket)
            let previousClient = client
            let nextClient = makeClient(connection: freshConnection, profile: target)

            markChatViewportReplacement()
            connection = freshConnection
            client = nextClient
            clearPendingDecisionRestorationGuard()
            // Fence any residual deferred cache write scheduled under the
            // outgoing profile before identities and namespaces change over.
            setActiveProfile(target)
            sessions = []
            cronSessions = []
            archivedSessions = []
            projects = []
            supportsProjects = false
            projectsLoading = false
            slashCommands = Self.builtInSlashCommands
            restoreActiveSessionState(for: target)
            restorePinnedSessions(for: target)
            try await connectChatResumeClient(nextClient)
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration),
                  self.client === nextClient else { return false }
            // Keep the previous socket alive until the new profile has
            // actually connected, so a failed switch has a recovery path.
            previousClient?.disconnect()
            isConnected = true
            connectedAt = Date()
            KeychainHelper.saveConnection(freshConnection)
            defaults.set(target, forKey: activeProfileKey)

            await syncSession(
                purpose: .preserveCurrent,
                using: nil,
                automaticWorkToken: nil,
                requiredViewportTransitionGeneration: transitionGeneration
            )
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
                return false
            }
            finishChatViewportTransitionIfNoTranscriptReplacement(
                generation: transitionGeneration
            )
            await loadChatResumeBusyInputMode(using: nextClient)
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
                return false
            }
            await loadChatResumeProfileDisplayPreferences()
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
                return false
            }
            Task { await loadChatResumeSlashCommands() }
            return true
        } catch {
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
                return false
            }
            errorMessage = "Could not switch workspace: \(error.localizedDescription)"
            clearPendingDecisionRestorationGuard()
            // The pre-switch reset neutralized the approval state; restore it
            // with the rest of the previous profile or a failed switch loses
            // the floor while the previous profile is still the active one.
            runtime.approvalsMode = previousApprovalsMode
            runtime.yolo = previousYolo
            lastReportedSessionYolo = previousLastReportedSessionYolo
            sessions = previousSessions
            cronSessions = previousCronSessions
            archivedSessions = previousArchivedSessions
            projects = previousProjects
            supportsProjects = previousSupportsProjects
            projectsLoading = false
            restoreActiveSessionState(for: previousProfile)
            restorePinnedSessions(for: previousProfile)
            // restoreActiveSessionState/restorePinnedSessions are
            // synchronous and cache-write-free; the pre-flight boundary
            // flush (above) already persisted the outgoing transcript under
            // the previous profile's namespace. setActiveProfile(_:)
            // deliberately does NOT flush: flipping the identity back only
            // re-arms the namespace and bumps the fence epoch, making any
            // flush scheduled under the failed target during the aborted
            // attempt stale.
            setActiveProfile(previousProfile)
            connection = savedConnection
            client?.disconnect()
            client = nil
            isConnected = false
            turnState = .reconnecting
            finishChatViewportTransition(generation: transitionGeneration)
            await reconnect()
            return false
        }
    }

    func loadProfiles() async {
        guard let bridge = dashboardTicketBridge else { return }
        do {
            let response: [String: Any]
            if let profileDiscoveryLoaderOverride {
                response = try await profileDiscoveryLoaderOverride()
            } else {
                response = try await bridge.requestJSON(path: "/api/profiles")
            }
            // Commit gate, same identity pattern as the dashboard catalog
            // loader: a bridge swapped mid-request (server change, re-login,
            // disconnect) makes this response foreign. A late reply from an
            // old connection must not overwrite the live list, and must not
            // repopulate a persisted cache that
            // prepareChatResumeForConnection(to:) already cleared with the
            // previous server's profile names. Discarded silently — profile
            // discovery has no retry loop to feed an error into.
            guard dashboardTicketBridge === bridge else { return }
            let values = response["profiles"] as? [Any] ?? []
            let names = values.compactMap { value -> String? in
                if let name = value as? String { return name }
                return (value as? [String: Any])?["name"] as? String
            }
            // A 200 with no profile names is a degraded payload (dashboard
            // mid-restart, partial deploy, proxy), not authoritative evidence
            // that every profile vanished — Hermes always has `default`. The
            // next line would otherwise collapse the picker and persist that
            // degraded list over the complete cache, the exact bug this
            // function exists to prevent, just via a 200 instead of an error.
            let nextProfiles = names.isEmpty
                ? orderedProfiles(profiles + [activeProfile, "default"])
                : orderedProfiles(names + ["default"])
            profiles = nextProfiles
            defaults.set(nextProfiles, forKey: knownProfilesKey)
            // A non-empty response is authoritative: if the server no longer
            // knows the active profile (deleted externally), re-home onto a
            // valid fallback instead of leaving `activeProfile ∉ profiles` —
            // a state the profile picker cannot represent. The degraded and
            // empty-payload paths already union `activeProfile` in, so only
            // this branch can need the correction.
            if !names.isEmpty, !nextProfiles.contains(activeProfile) {
                // orderedProfiles always unions "default" into a non-empty
                // names list, so the fallback is unconditionally "default";
                // the contains-check stays as cheap defense-in-depth against
                // a future change to that union invariant.
                adoptAuthoritativeFallbackProfile(
                    nextProfiles.contains("default") ? "default" : nextProfiles[0]
                )
                // The abandoned profile-scoped connect/reconnect work can no
                // longer commit (its identity fences now fail), so converge
                // the transport onto the corrected profile. Fire-and-forget:
                // never awaited inside discovery, and idempotent — the next
                // discovery contains the fallback and will not re-adopt.
                if isConnected {
                    Task { await reconnect() }
                }
            }
        } catch {
            guard dashboardTicketBridge === bridge else { return }
            // Profile discovery is additive and monotonic. A failed refresh
            // (bridge still loading, dashboard restart, transient 5xx) must
            // never shrink the visible list or overwrite a complete persisted
            // cache with a degraded fallback — that degradation is exactly
            // how a known profile "disappeared" from the picker until the
            // next successful discovery or a logout/login cycle. Union with
            // the current list so the active profile and the `default`
            // invariant are always represented, then persist the union (a
            // no-op write when the cache is already complete).
            let merged = orderedProfiles(profiles + [activeProfile, "default"])
            profiles = merged
            defaults.set(merged, forKey: knownProfilesKey)
        }
    }

    /// Authoritative discovery reported a server that no longer contains the
    /// active profile (e.g. it was deleted externally). Re-home onto a valid
    /// fallback using the same local hard-boundary sequence as the forward
    /// profile transition in `connect(with:profile:)`: flush the outgoing
    /// transcript under its presentation-cache namespace, clear the
    /// profile-scoped catalogs and transcript, fence-flip the identity,
    /// prune the deleted profile's persisted bookkeeping, restore the
    /// fallback's remembered session/pinned state, and persist the
    /// correction under `activeProfileKey`.
    ///
    /// Deliberately NOT the interactive `switchProfile(to:reusing:)` flow:
    /// that re-resolves the whole connection and would nest reconnects and
    /// capability loads inside this discovery call site. Callers schedule a
    /// fire-and-forget `reconnect()` when the transport is live so the
    /// client converges onto the corrected profile; every catalog read is
    /// filtered and path-prefixed by the explicit profile, so no
    /// cross-profile transcript or cache state leaks in the window before
    /// that reconnect lands.
    private func adoptAuthoritativeFallbackProfile(_ fallback: String) {
        guard fallback != activeProfile else { return }
        // A profile change replaces the voice gateway; any in-flight read
        // aloud belongs to the outgoing profile (same as switchProfile).
        messageReadAloudController.stop()
        flushPendingPresentationCache()
        sessions = []
        cronSessions = []
        archivedSessions = []
        projects = []
        supportsProjects = false
        projectsLoading = false
        slashCommands = Self.builtInSlashCommands
        messages = []
        persistedTranscriptWindow = nil
        clearStreamingText()
        resetReasoningTurn()
        // The next profile's approval mode is unknown until its first session
        // snapshot arrives; don't let the deleted profile's approval floor or
        // YOLO state leak across the re-home — neutralize to the safe display
        // until the fallback profile resolves them (same neutralization as
        // switchProfile).
        runtime.approvalsMode = nil
        runtime.yolo = false
        lastReportedSessionYolo = nil
        // Drop the deleted profile's persisted local bookkeeping so a later
        // re-creation with the same name starts fresh instead of
        // resurrecting obsolete titles and pins.
        activeSessionTitlesByProfile.removeValue(forKey: activeProfile)
        pinnedSessionIDsByProfile.removeValue(forKey: activeProfile)
        persistActiveSessionTitles()
        persistPinnedSessions()
        setActiveProfile(fallback)
        restoreActiveSessionState(for: fallback)
        restorePinnedSessions(for: fallback)
        defaults.set(fallback, forKey: activeProfileKey)
    }

    /// Hermes blocks a clarify/approval prompt for only ~5 minutes server-side
    /// (JSON-RPC error 4009, "no pending … request"), while a restored or
    /// push-delivered card can legitimately outlive it — a notification opened
    /// an hour later is the feature's ordinary case, not an error. Treat that
    /// outcome as "the decision is no longer active" instead of a generic
    /// failure the user can retry forever.
    static func isExpiredPromptError(_ error: Error) -> Bool {
        if let rpcError = error as? RpcError {
            if rpcError.code == 4009 { return true }
            return rpcError.message.lowercased().contains("no pending")
        }
        return error.localizedDescription.lowercased().contains("no pending")
    }

    func respondToApproval(messageId: String, choice: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              let current = messages[index].approval,
              current.status == .pending || current.status == .error else { return }

        messages[index].approval?.status = .submitting
        messages[index].approval?.choice = choice
        messages[index].approval?.error = nil
        setRunning(true)
        cacheMessagePresentation()

        guard let client else {
            messages[index].approval?.status = .error
            messages[index].approval?.choice = nil
            messages[index].approval?.error = "Gateway connection is unavailable."
            cacheMessagePresentation()
            return
        }
        do {
            try await client.respondToApproval(sessionId: current.sessionId, choice: choice)
            guard let updatedIndex = messages.firstIndex(where: { $0.id == messageId }) else { return }
            messages[updatedIndex].approval?.status = choice == "deny" ? .rejected : .approved
            cacheMessagePresentation()
        } catch {
            guard let updatedIndex = messages.firstIndex(where: { $0.id == messageId }) else { return }
            messages[updatedIndex].approval?.status = .error
            messages[updatedIndex].approval?.choice = nil
            if Self.isExpiredPromptError(error) {
                messages[updatedIndex].approval?.error = "This approval is no longer active — Hermes timed it out and continued."
            } else {
                messages[updatedIndex].approval?.error = "Hermes did not accept that decision."
                errorMessage = error.localizedDescription
            }
            cacheMessagePresentation()
        }
    }

    /// Project navigation is always present in the drawer because every current
    /// Hermes profile has the immutable Home project. Load its authoritative
    /// tree independently of the session catalog so opening the drawer never
    /// depends on a manual Session refresh.
    func refreshProjects() async {
        guard let client else { return }
        await loadProjects(using: client, profile: activeProfile)
    }

    private func loadProjects(using client: HermesClient, profile: String) async {
        projectsRequestGeneration += 1
        let generation = projectsRequestGeneration
        projectsLoading = true
        defer {
            if generation == projectsRequestGeneration,
               profile == activeProfile,
               self.client === client {
                projectsLoading = false
            }
        }
        do {
            let loaded = try await client.projects()
            guard generation == projectsRequestGeneration,
                  profile == activeProfile,
                  self.client === client else { return }
            projects = loaded.sorted {
                if $0.isHome != $1.isHome { return $0.isHome }
                if $0.sessionCount != $1.sessionCount { return $0.sessionCount > $1.sessionCount }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            supportsProjects = true
        } catch {
            guard generation == projectsRequestGeneration,
                  profile == activeProfile,
                  self.client === client else { return }
            guard isProjectsUnavailable(error) else { return }
            projects = []
            supportsProjects = false
        }
    }

    private func isProjectsUnavailable(_ error: Error) -> Bool {
        guard let rpcError = error as? RpcError else { return false }
        let message = rpcError.message.lowercased()
        return rpcError.code == -32601
            || message.contains("method not found")
            || message.contains("unknown method")
            || message.contains("projects.tree") && message.contains("not found")
    }

    func loadProjectSessions(_ project: ProjectSummary) async -> ProjectSessionDetail? {
        guard let client, supportsProjects else { return nil }
        let profile = activeProfile
        do {
            let detail = try await client.projectSessions(project.id)
            guard profile == activeProfile, self.client === client else { return nil }
            return detail
        } catch {
            guard profile == activeProfile, self.client === client else { return nil }
            if isProjectsUnavailable(error) {
                projects = []
                supportsProjects = false
            } else {
                errorMessage = "Could not load \(project.title): \(error.localizedDescription)"
            }
            return nil
        }
    }

    @discardableResult
    func createProject(name: String, folders: [String], idea: String) async -> Bool {
        guard let client, supportsProjects else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let uniqueFolders = folders.reduce(into: [String]()) { result, folder in
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !result.contains(trimmed) { result.append(trimmed) }
        }
        guard !trimmedName.isEmpty, !uniqueFolders.isEmpty else { return false }

        let profile = activeProfile
        do {
            guard let created = try await client.createProject(name: trimmedName, folders: uniqueFolders) else {
                throw HermesError.invalidResponse
            }
            guard profile == activeProfile, self.client === client else { return false }
            projects = [created] + projects.filter { $0.id != created.id }
            supportsProjects = true

            let trimmedIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedIdea.isEmpty {
                await writeProjectIdea(trimmedIdea, in: uniqueFolders[0], profile: profile)
            }
            await loadProjects(using: client, profile: profile)
            return true
        } catch {
            guard profile == activeProfile, self.client === client else { return false }
            if isProjectsUnavailable(error) {
                projects = []
                supportsProjects = false
            } else {
                errorMessage = "Could not create the project: \(error.localizedDescription)"
            }
            return false
        }
    }

    /// The project folder picker starts at the same live workspace the chat
    /// browser uses. Folder paths are selected from Hermes' filesystem listing,
    /// not entered as arbitrary strings by the phone.
    var projectFolderPickerRoot: String {
        !runtime.cwd.isEmpty ? runtime.cwd : workspaceRoot
    }

    func workspaceDirectoryEntries(at path: String) async throws -> [WorkspaceEntry] {
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let profile = activeProfile
        guard let encodedPath = DashboardPath.encodedQueryComponent(path) else {
            throw DashboardTicketBridgeError.requestFailed("The workspace path could not be encoded.")
        }
        let result = try await dashboardTicketBridge.requestJSON(
            path: DashboardPath.withProfile("/api/fs/list?path=\(encodedPath)", profile: profile)
        )
        guard profile == activeProfile else { return [] }
        if let error = result["error"] as? String, !error.isEmpty {
            throw DashboardTicketBridgeError.requestFailed(error)
        }
        return ((result["entries"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let name = item["name"] as? String,
                  let entryPath = item["path"] as? String,
                  !name.isEmpty,
                  !entryPath.isEmpty else { return nil }
            return WorkspaceEntry(name: name, path: entryPath, isDirectory: item["isDirectory"] as? Bool ?? false)
        }.sorted {
            $0.isDirectory != $1.isDirectory
                ? $0.isDirectory
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func writeProjectIdea(_ idea: String, in folder: String, profile: String) async {
        guard let dashboardTicketBridge else { return }
        let separator = folder.hasSuffix("/") || folder.hasSuffix("\\") ? "" : "/"
        let path = "\(folder)\(separator)IDEA.md"
        _ = try? await dashboardTicketBridge.requestJSON(
            path: dashboardPath("/api/fs/write-text", profile: profile),
            method: "POST",
            body: ["path": path, "content": idea.hasSuffix("\n") ? idea : "\(idea)\n"]
        )
    }

    private func orderedProfiles(_ values: [String]) -> [String] {
        let discovered = Array(Set(values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
        let savedOrder = defaults.stringArray(forKey: profileOrderKey) ?? []
        let knownOrder = savedOrder.filter { discovered.contains($0) }
        let unordered = discovered
            .filter { !knownOrder.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if savedOrder.isEmpty, let defaultProfile = unordered.first(where: { $0 == "default" }) {
            return [defaultProfile] + unordered.filter { $0 != "default" }
        }
        return knownOrder + unordered
    }

    private func normalizedSessionFilterOrder(_ values: [String]) -> [SessionSource] {
        let defaults: [SessionSource] = [.chat, .discord, .telegram, .api, .webhook, .other]
        let requested = values.compactMap(SessionSource.init(rawValue:))
        let unique = requested.reduce(into: [SessionSource]()) { result, source in
            if !result.contains(source), defaults.contains(source) {
                result.append(source)
            }
        }
        return unique + defaults.filter { !unique.contains($0) }
    }

    // MARK: - Capabilities

    /// Request-scoped result for a capability load. The caller must be able to
    /// know how THIS request ended without consulting global error/skill
    /// state, which can be stale or mutated by unrelated flows.
    enum CapabilityLoadOutcome {
        case success(profile: String)
        case failed(profile: String, message: String)
        case unavailable(profile: String)
        /// The active profile changed mid-request; the result belongs to an
        /// abandoned profile and callers should discard it.
        case superseded(requestedProfile: String, activeProfile: String)

        var isSuperseded: Bool {
            if case .superseded = self { return true }
            return false
        }
    }

    @discardableResult
    func loadCapabilities() async -> CapabilityLoadOutcome {
        capabilityLoadGeneration &+= 1
        let generation = capabilityLoadGeneration
        let profile = activeProfile
        guard let dashboardTicketBridge else { return .unavailable(profile: profile) }
        async let skillsResult = dashboardTicketBridge.requestJSON(path: dashboardPath("/api/skills", profile: profile))
        async let toolsetsResult = dashboardTicketBridge.requestJSON(path: dashboardPath("/api/tools/toolsets", profile: profile))
        // Commit gate: this exact request must still be the newest one AND
        // target the still-active profile (A -> B -> A stale commits rejected).
        func ownsRequest() -> Bool {
            CapabilityLoadPolicy.canCommit(
                generation: generation,
                latestGeneration: capabilityLoadGeneration,
                requestedProfile: profile,
                activeProfile: activeProfile
            )
        }
        do {
            let (skillsResponse, toolsetsResponse) = try await (skillsResult, toolsetsResult)
            guard ownsRequest() else { return .superseded(requestedProfile: profile, activeProfile: activeProfile) }
            let skillsValues = skillsResponse["_array"] as? [Any] ?? []
            self.skills = skillsValues.compactMap(decodeCapabilitySkill)
                .sorted { lhs, rhs in
                    let lhsCat = lhs.category ?? ""
                    let rhsCat = rhs.category ?? ""
                    if lhsCat != rhsCat { return lhsCat < rhsCat }
                    return lhs.name < rhs.name
                }
            let toolsetsValues = toolsetsResponse["_array"] as? [Any] ?? []
            self.toolsets = toolsetsValues.compactMap(decodeCapabilityToolset)
                .sorted { ($0.label ?? $0.name) < ($1.label ?? $1.name) }
            capabilitiesProfile = profile
            return .success(profile: profile)
        } catch {
            guard ownsRequest() else { return .superseded(requestedProfile: profile, activeProfile: activeProfile) }
            errorMessage = "Could not load capabilities: \(error.localizedDescription)"
            return .failed(profile: profile, message: "Could not load capabilities: \(error.localizedDescription)")
        }
    }

    func toggleSkill(name: String, enabled: Bool) async {
        let profile = activeProfile
        // Optimistic update
        if let index = skills.firstIndex(where: { $0.name == name }) {
            skills[index].enabled = enabled
        }
        guard let dashboardTicketBridge else { return }
        do {
            _ = try await dashboardTicketBridge.requestJSON(
                path: "/api/skills/toggle",
                method: "PUT",
                body: ["name": name, "enabled": enabled, "profile": profile]
            )
        } catch {
            // Revert on failure
            guard profile == activeProfile else { return }
            if let index = skills.firstIndex(where: { $0.name == name }) {
                skills[index].enabled = !enabled
            }
            errorMessage = "Could not update skill: \(error.localizedDescription)"
        }
    }

    func toggleToolset(name: String, enabled: Bool) async {
        let profile = activeProfile
        // Optimistic update
        if let index = toolsets.firstIndex(where: { $0.name == name }) {
            toolsets[index].enabled = enabled
        }
        guard let dashboardTicketBridge else { return }
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        do {
            _ = try await dashboardTicketBridge.requestJSON(
                path: "/api/tools/toolsets/\(encodedName)",
                method: "PUT",
                body: ["enabled": enabled, "profile": profile]
            )
        } catch {
            // Revert on failure
            guard profile == activeProfile else { return }
            if let index = toolsets.firstIndex(where: { $0.name == name }) {
                toolsets[index].enabled = !enabled
            }
            errorMessage = "Could not update toolset: \(error.localizedDescription)"
        }
    }

    private func decodeCapabilitySkill(_ value: Any) -> CapabilitySkill? {
        guard let dict = value as? [String: Any], let name = dict["name"] as? String else { return nil }
        return CapabilitySkill(
            name: name,
            description: dict["description"] as? String,
            category: dict["category"] as? String,
            enabled: dict["enabled"] as? Bool ?? false,
            provenance: dict["provenance"] as? String,
            usage: dict["usage"] as? Int
        )
    }

    private func decodeCapabilityToolset(_ value: Any) -> CapabilityToolset? {
        guard let dict = value as? [String: Any], let name = dict["name"] as? String else { return nil }
        let tools = dict["tools"] as? [Any]
        return CapabilityToolset(
            name: name,
            description: dict["description"] as? String,
            enabled: dict["enabled"] as? Bool ?? false,
            configured: dict["configured"] as? Bool,
            label: dict["label"] as? String,
            tools: tools as? [String]
        )
    }

    // MARK: - Scheduled jobs

    func loadCronJobs() async {
        guard !cronJobsLoading else { return }
        let profile = activeProfile
        cronJobsLoading = true
        defer { cronJobsLoading = false }

        do {
            if let dashboardTicketBridge {
                let result = try await dashboardTicketBridge.requestJSON(path: cronDashboardPath("/api/cron/jobs", profile: profile))
                let values = result["_array"] as? [Any] ?? result["jobs"] as? [Any] ?? []
                let jobs = values.compactMap(decodeCronJob)
                guard profile == activeProfile else { return }
                cronJobs = jobs.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            } else if let client {
                let jobs = try await client.listCronJobs()
                guard profile == activeProfile, self.client === client else { return }
                cronJobs = jobs
            }
        } catch {
            guard profile == activeProfile else { return }
            errorMessage = "Could not load scheduled jobs: \(error.localizedDescription)"
        }
    }

    func loadCronRuns(for job: CronJob) async {
        let profile = activeProfile
        do {
            if let dashboardTicketBridge {
                let path = cronDashboardPath("/api/cron/jobs/\(job.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.id)/runs?limit=20", profile: profile)
                let result = try await dashboardTicketBridge.requestJSON(path: path)
                let values = cronRunValues(from: result)
                guard profile == activeProfile else { return }
                let decoded = values.compactMap(decodeCronRun).filter { run in
                    guard let owner = run.profile, !owner.isEmpty else { return true }
                    return profilesMatch(owner, profile)
                }
                if decoded.isEmpty, let client {
                    let fallback = (try? await client.cronRuns()) ?? []
                    guard profile == activeProfile, self.client === client else { return }
                    cronRuns = fallback.filter { run in
                        guard let owner = run.profile, !owner.isEmpty else { return true }
                        return profilesMatch(owner, profile)
                    }
                } else {
                    cronRuns = decoded
                }
            } else if let client {
                let runs = try await client.cronRuns()
                guard profile == activeProfile, self.client === client else { return }
                cronRuns = runs.filter { run in
                    guard let owner = run.profile, !owner.isEmpty else { return true }
                    return profilesMatch(owner, profile)
                }
            }
        } catch {
            guard profile == activeProfile else { return }
            errorMessage = "Could not load scheduled-job runs: \(error.localizedDescription)"
        }
    }

    func performCronAction(_ action: String, for job: CronJob) async -> Bool {
        guard cronJobActionID == nil else { return false }
        let profile = activeProfile
        cronJobActionID = job.id
        defer { cronJobActionID = nil }
        guard let dashboardTicketBridge else { return false }

        do {
            let encodedID = job.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.id
            let result = try await dashboardTicketBridge.requestJSON(
                path: cronDashboardPath("/api/cron/jobs/\(encodedID)/\(action)", profile: profile),
                method: "POST",
                body: ["profile": profile]
            )
            guard profile == activeProfile else { return false }
            if let updated = decodeCronJob(result), let index = cronJobs.firstIndex(where: { $0.id == job.id }) {
                cronJobs[index] = updated
            } else {
                await loadCronJobs()
            }
            return true
        } catch {
            errorMessage = "Could not \(action) scheduled job: \(error.localizedDescription)"
            return false
        }
    }

    private func cronDashboardPath(_ path: String, profile: String) -> String {
        DashboardPath.withExplicitProfile(path, profile: profile)
    }

    private func decodeCronJob(_ value: Any) -> CronJob? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(CronJob.self, from: data)
    }

    private func decodeCronRun(_ value: Any) -> CronRun? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        if let decoded = try? JSONDecoder().decode(CronRun.self, from: data) { return decoded }
        guard let rawObject = value as? [String: Any] else { return nil }
        let object = rawObject["session"] as? [String: Any] ?? rawObject
        guard
              let id = stringValue(object["id"] ?? object["session_id"] ?? object["run_id"]), !id.isEmpty else { return nil }
        return CronRun(
            id: id,
            lastActive: integerValue(object["last_active"] ?? object["lastActive"]),
            model: stringValue(object["model"]),
            preview: stringValue(object["preview"] ?? object["summary"]),
            profile: stringValue(object["profile"]),
            startedAt: integerValue(object["started_at"] ?? object["startedAt"]),
            title: stringValue(object["title"] ?? object["name"])
        )
    }

    private func cronRunValues(from result: [String: Any]) -> [Any] {
        if let values = result["runs"] as? [Any] ?? result["items"] as? [Any] ?? result["_array"] as? [Any] ?? result["data"] as? [Any] {
            return values
        }
        if let nested = result["data"] as? [String: Any] {
            return nested["runs"] as? [Any] ?? nested["items"] as? [Any] ?? []
        }
        if let nested = result["runs"] as? [String: Any] {
            return nested["items"] as? [Any] ?? nested["results"] as? [Any] ?? []
        }
        return []
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? Double(string).map(Int.init) }
        return nil
    }

    private func booleanValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return false
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        let string = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private func loadProfileDisplayPreferences() async {
        let profile = activeProfile
        guard let dashboardTicketBridge else { return }
        do {
            let config = try await dashboardTicketBridge.requestJSON(path: dashboardPath("/api/config", profile: profile))
            guard profile == activeProfile else { return }
            let display = config["display"] as? [String: Any] ?? [:]
            displayPreferences = ProfileDisplayPreferences(
                showReasoning: display["show_reasoning"] as? Bool ?? true,
                showToolProgress: display["tool_progress"] as? String != "off",
                expandToolsByDefault: display["expand_tools"] as? Bool ?? false
            )
        } catch {
            guard profile == activeProfile else { return }
            displayPreferences = ProfileDisplayPreferences()
        }
    }

    func loadProfileSettings(keys: [String]) async -> [String: ProfileSettingValue] {
        let profile = activeProfile
        guard let dashboardTicketBridge else { return [:] }
        do {
            let config = try await dashboardTicketBridge.requestJSON(path: dashboardPath("/api/config", profile: profile))
            guard profile == activeProfile else { return [:] }
            return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
                profileSettingValue(in: config, key: key).map { (key, $0) }
            })
        } catch {
            errorMessage = "Could not load profile settings: \(error.localizedDescription)"
            return [:]
        }
    }

    func loadProfileConfigOptions() async -> ProfileConfigOptions {
        let profile = activeProfile
        guard let dashboardTicketBridge else { return ProfileConfigOptions() }
        var result = ProfileConfigOptions()
        do {
            async let configRequest = dashboardTicketBridge.requestJSON(path: dashboardPath("/api/config", profile: profile))
            async let pluginsRequest = dashboardTicketBridge.requestJSON(path: dashboardPath("/api/dashboard/plugins/hub", profile: profile))
            let (config, plugins) = try await (configRequest, pluginsRequest)
            guard profile == activeProfile else { return result }
            if let personalities = ((config["agent"] as? [String: Any])?["personalities"] as? [String: Any])?.keys {
                result.personalities = personalities.sorted()
            }
            let providers = plugins["providers"] as? [String: Any] ?? [:]
            let memoryOptions = providers["memory_options"] as? [[String: Any]] ?? []
            result.memoryProviders = memoryOptions.compactMap { option in
                option["status"] as? String == "ready" ? option["name"] as? String : nil
            }.sorted()
            let contextOptions = providers["context_options"] as? [[String: Any]] ?? []
            result.contextEngines = Array(Set(result.contextEngines + contextOptions.compactMap { $0["name"] as? String })).sorted()
        } catch {
            // Options are supplementary; retain safe built-ins when an older
            // dashboard does not expose its plugin hub.
        }
        return result
    }

    func loadProfileModelDefaults() async -> ProfileModelDefaults? {
        let profile = activeProfile
        guard let dashboardTicketBridge else { return nil }
        do {
            async let optionsRequest = dashboardTicketBridge.requestJSON(path: dashboardPath("/api/model/options?explicit_only=true", profile: profile))
            async let infoRequest = dashboardTicketBridge.requestJSON(path: dashboardPath("/api/model/info", profile: profile))
            async let configRequest = dashboardTicketBridge.requestJSON(path: dashboardPath("/api/config", profile: profile))
            let (options, info, config) = try await (optionsRequest, infoRequest, configRequest)
            guard profile == activeProfile else { return nil }
            let providers = (AnyCodable.from(options).objectValue?["providers"]?.arrayValue ?? []).compactMap(ProviderInfo.init(from:))
            // Profile config is the persisted default. Hermes stores it under
            // `model.default` and `model.provider`; `/api/model/info` can
            // instead report a currently running session's override.
            let modelConfig = config["model"] as? [String: Any] ?? [:]
            let model = modelConfig["default"] as? String ?? info["model"] as? String ?? ""
            let provider = modelConfig["provider"] as? String ?? info["provider"] as? String ?? ""
            let reasoning = config["reasoning"] as? String ?? config["reasoning_effort"] as? String ?? "medium"
            return ProfileModelDefaults(providers: providers, model: model, provider: provider, reasoning: reasoning)
        } catch {
            errorMessage = "Could not load model defaults: \(error.localizedDescription)"
            return nil
        }
    }

    func setProfileMainModel(provider: String, model: String, reasoning: String) async -> Bool {
        let profile = activeProfile
        guard let dashboardTicketBridge else { return false }
        do {
            let result = try await dashboardTicketBridge.requestJSON(
                path: dashboardPath("/api/model/set", profile: profile),
                method: "POST",
                body: ["model": model, "provider": provider, "scope": "main", "profile": profile]
            )
            if result["confirm_required"] as? Bool == true {
                errorMessage = result["confirm_message"] as? String ?? "Hermes requires confirmation before using this model."
                return false
            }
            var config = try await dashboardTicketBridge.requestJSON(path: dashboardPath("/api/config", profile: profile))
            var modelConfig = config["model"] as? [String: Any] ?? [:]
            modelConfig["default"] = model
            modelConfig["provider"] = provider
            config["model"] = modelConfig
            config["reasoning"] = reasoning
            _ = try await dashboardTicketBridge.requestJSON(
                path: dashboardPath("/api/config", profile: profile),
                method: "PUT",
                body: ["config": config, "profile": profile]
            )
            return true
        } catch {
            errorMessage = "Could not save model defaults: \(error.localizedDescription)"
            return false
        }
    }

    func setProfileSetting(_ key: String, value: ProfileSettingValue) async -> Bool {
        let profile = activeProfile
        guard let dashboardTicketBridge else { return false }
        do {
            if profile == "default" && (key == "context.engine" || key == "memory.provider") {
                let raw = value.textValue ?? ""
                let body = key == "context.engine" ? ["context_engine": raw] : ["memory_provider": raw]
                _ = try await dashboardTicketBridge.requestJSON(path: "/api/dashboard/plugin-providers", method: "PUT", body: body)
                return true
            }
            var config = try await dashboardTicketBridge.requestJSON(path: dashboardPath("/api/config", profile: profile))
            setProfileSettingValue(value, in: &config, key: key)
            _ = try await dashboardTicketBridge.requestJSON(
                path: dashboardPath("/api/config", profile: profile),
                method: "PUT",
                body: ["config": config, "profile": profile]
            )
            if key == "approvals.mode", let mode = value.textValue?.lowercased(), profile == activeProfile {
                // Mirror the saved profile mode immediately and re-resolve the
                // effective indicator state through the same precedence
                // applyRuntime uses, so the floor and the picker lock take
                // effect without waiting for the next session snapshot. The
                // last server-reported session value carries through when
                // known (runtime.yolo may be the floor-forced value, not the
                // session flag); only the floor/override precedence re-runs.
                runtime.approvalsMode = mode
                let requestedSessionID = activeSessionId
                let resolvedCanonicalSessionID = canonicalSessionID(for: requestedSessionID)
                applyEffectiveYolo(
                    sessionIDsForOverride: [resolvedCanonicalSessionID, requestedSessionID]
                        .compactMap { $0 },
                    snapshotYolo: lastReportedSessionYolo ?? runtime.yolo,
                    snapshotReportedApprovalsMode: nil
                )
            }
            return true
        } catch {
            errorMessage = "Could not save \(key): \(error.localizedDescription)"
            return false
        }
    }

    private func profileSettingValue(in config: [String: Any], key: String) -> ProfileSettingValue? {
        let components = key.split(separator: ".").map(String.init)
        var current: Any = config
        for component in components {
            guard let object = current as? [String: Any], let next = object[component] else { return nil }
            current = next
        }
        if let value = current as? Bool { return .bool(value) }
        if let value = current as? String { return .text(value) }
        if let value = current as? NSNumber { return .number(value.doubleValue) }
        return nil
    }

    private func setProfileSettingValue(_ value: ProfileSettingValue, in config: inout [String: Any], key: String) {
        let components = key.split(separator: ".").map(String.init)
        guard let leaf = components.last else { return }
        let rawValue: Any
        switch value {
        case .bool(let value): rawValue = value
        case .text(let value): rawValue = value
        case .number(let value): rawValue = value
        }
        setNestedValue(rawValue, in: &config, path: Array(components.dropLast()), leaf: leaf)
    }

    private func setNestedValue(_ value: Any, in object: inout [String: Any], path: [String], leaf: String) {
        guard let next = path.first else {
            object[leaf] = value
            return
        }
        var child = object[next] as? [String: Any] ?? [:]
        setNestedValue(value, in: &child, path: Array(path.dropFirst()), leaf: leaf)
        object[next] = child
    }

    func setDisplayPreference(_ key: DisplayPreferenceKey, enabled: Bool) async -> Bool {
        let profile = activeProfile
        let previous = displayPreferences
        applyDisplayPreference(key, enabled: enabled)
        guard let dashboardTicketBridge else {
            displayPreferences = previous
            return false
        }

        do {
            var config = try await dashboardTicketBridge.requestJSON(path: dashboardPath("/api/config", profile: profile))
            var display = config["display"] as? [String: Any] ?? [:]
            switch key {
            case .reasoning: display["show_reasoning"] = enabled
            case .toolProgress: display["tool_progress"] = enabled ? "on" : "off"
            case .expandTools: display["expand_tools"] = enabled
            }
            config["display"] = display
            _ = try await dashboardTicketBridge.requestJSON(
                path: dashboardPath("/api/config", profile: profile),
                method: "PUT",
                body: ["config": config, "profile": profile]
            )
            return true
        } catch {
            if activeProfile == profile { displayPreferences = previous }
            errorMessage = "Could not save display preference: \(error.localizedDescription)"
            return false
        }
    }

    private func applyDisplayPreference(_ key: DisplayPreferenceKey, enabled: Bool) {
        switch key {
        case .reasoning: displayPreferences.showReasoning = enabled
        case .toolProgress: displayPreferences.showToolProgress = enabled
        case .expandTools: displayPreferences.expandToolsByDefault = enabled
        }
    }

    private func dashboardPath(_ path: String, profile: String) -> String {
        DashboardPath.withProfile(path, profile: profile)
    }

    private func loadBusyInputMode(using client: HermesClient) async {
        do {
            busyInputMode = try await client.busyInputMode()
        } catch {
            // `steer` is deliberately the safe public default when an older
            // gateway cannot expose this optional preference.
            busyInputMode = .steer
        }
    }

    func setBusyInputMode(_ mode: BusyInputMode) async -> Bool {
        guard let client else { return false }
        let previous = busyInputMode
        busyInputMode = mode
        do {
            if let setBusyInputMode = chatResumeLifecycleOperations.setBusyInputMode {
                try await setBusyInputMode(client, mode)
            } else {
                try await client.setBusyInputMode(mode)
            }
            return true
        } catch {
            busyInputMode = previous
            errorMessage = "Could not save message behavior: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Secondary profile title recovery

    private func cancelSecondaryProfileTitleRecovery() {
        sessionTitleRecoveryTracker.cancelAll()
    }

    private func cancelSecondaryProfileTitleRecovery(
        profile: String,
        sessionIDs: [String]
    ) async {
        let taskKeys = Set(sessionIDs.filter { !$0.isEmpty }.map { "\(profile)|\($0)" })
        await sessionTitleRecoveryTracker.cancel(taskKeys)
    }

    private func titleGenerationSettings(for profile: String) async -> TitleGenerationSettings? {
        guard let dashboardTicketBridge else { return nil }
        do {
            let config = try await dashboardTicketBridge.requestJSON(
                path: dashboardPath("/api/config", profile: profile)
            )
            guard profile == activeProfile else { return nil }
            let enabledSetting = profileSettingValue(
                in: config,
                key: "auxiliary.title_generation.enabled"
            )
            let enabled: Bool
            if let explicit = enabledSetting?.boolValue {
                enabled = explicit
            } else if let raw = enabledSetting?.textValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() {
                enabled = !["false", "0", "off", "no"].contains(raw)
            } else {
                // Hermes defaults this feature to enabled when the setting is
                // absent, so preserve that behavior.
                enabled = true
            }
            let language = profileSettingValue(
                in: config,
                key: "auxiliary.title_generation.language"
            )?.textValue
            return TitleGenerationSettings(enabled: enabled, language: language)
        } catch {
            // Do not spend a title-generation request when we cannot confirm
            // the user's setting through the authenticated dashboard.
            titleGenerationLog.error(
                "Could not read title settings for \(profile, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func scheduleSecondaryProfileTitleRecovery(
        sessionId: String,
        messages: [ChatMessage]
    ) {
        guard let firstUser = messages.first(where: { $0.role == .user })?.content,
              let firstAssistant = messages.first(where: {
                  $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })?.content else { return }
        scheduleSecondaryProfileTitleRecovery(
            sessionId: sessionId,
            userMessage: firstUser,
            assistantMessage: firstAssistant
        )
    }

    private func scheduleSecondaryProfileTitleRecovery(
        sessionId: String,
        userMessage: String,
        assistantMessage: String
    ) {
        let profile = activeProfile
        guard profile != "default",
              let client,
              !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let taskKey = "\(profile)|\(sessionId)"
        guard !sessionTitleRecoveryTracker.isSuppressed(taskKey),
              !sessionTitleRecoveryTracker.hasTask(for: taskKey) else { return }
        let token = UUID()
        let task = Task { [weak self, weak client] in
            defer {
                self?.sessionTitleRecoveryTracker.finish(token, for: taskKey)
            }
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
            } catch {
                return
            }
            guard let self,
                  let client,
                  !Task.isCancelled,
                  self.sessionTitleRecoveryTracker.isCurrent(token, for: taskKey),
                  self.activeProfile == profile,
                  self.client === client else { return }

            do {
                // Give Hermes' built-in asynchronous title task precedence.
                if let existingTitle = try await client.sessionTitle(sessionId) {
                    guard !Task.isCancelled,
                          self.sessionTitleRecoveryTracker.isCurrent(token, for: taskKey),
                          self.activeProfile == profile,
                          self.client === client else { return }
                    self.applyRecoveredSessionTitle(existingTitle, sessionIDs: [sessionId])
                    titleGenerationLog.notice(
                        "Used Hermes title for \(sessionId, privacy: .public) in \(profile, privacy: .public)"
                    )
                    return
                }
                guard let settings = await self.titleGenerationSettings(for: profile),
                      settings.enabled,
                      !Task.isCancelled,
                      self.sessionTitleRecoveryTracker.isCurrent(token, for: taskKey),
                      self.activeProfile == profile,
                      self.client === client else { return }
                guard let generated = try await client.generateSessionTitle(
                    sessionId,
                    userMessage: userMessage,
                    assistantMessage: assistantMessage,
                    language: settings.language
                ), let title = Self.normalizedGeneratedSessionTitle(generated),
                      !Task.isCancelled,
                      self.sessionTitleRecoveryTracker.isCurrent(token, for: taskKey),
                      self.activeProfile == profile,
                      self.client === client else { return }

                try await client.setSessionTitle(sessionId, title: title)
                guard !Task.isCancelled,
                      self.sessionTitleRecoveryTracker.isCurrent(token, for: taskKey),
                      self.activeProfile == profile,
                      self.client === client else { return }
                self.applyRecoveredSessionTitle(title, sessionIDs: [sessionId])
                titleGenerationLog.notice(
                    "Generated title for \(sessionId, privacy: .public) in \(profile, privacy: .public)"
                )
            } catch {
                // Automatic naming is cosmetic. A failed recovery must not
                // interrupt the chat or surface an unrelated error.
                titleGenerationLog.error(
                    "Title recovery failed for \(sessionId, privacy: .public) in \(profile, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        sessionTitleRecoveryTracker.register(task, token: token, for: taskKey)
    }

    static func normalizedGeneratedSessionTitle(_ value: String) -> String? {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let withoutThinking = (try? NSRegularExpression(
            pattern: "(?is)<think\\b[^>]*>.*?</think\\s*>"
        ))?.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: ""
        ) ?? value
        var title = withoutThinking
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
        guard !title.isEmpty else { return nil }
        return String(title.prefix(80))
    }

    private func applyRecoveredSessionTitle(_ title: String, sessionIDs: [String]) {
        let result = SessionRenameOperation.Result(title: title, sessionIDs: sessionIDs)
        let titleSessionIDs = Set(sessionIDs.filter { !$0.isEmpty })
        guard !titleSessionIDs.isEmpty else { return }
        var matchesActiveSession = result.matches(sessionID: activeSessionId)
        func updated(_ session: SessionSummary) -> SessionSummary {
            let updated = result.updating(session)
            guard updated != session else { return session }
            if let activeSessionId,
               Set([session.id] + session.alternateIds).contains(activeSessionId) {
                matchesActiveSession = true
            }
            return updated
        }
        sessions = sessions.map(updated)
        cronSessions = cronSessions.map(updated)
        archivedSessions = archivedSessions.map(updated)
        if matchesActiveSession { setActiveSessionTitle(title) }
    }

    // MARK: - Stream event handling

    func handleStreamEvent(_ event: StreamEvent) {
        if case .sessionTitle(let runtimeSessionId, let storedSessionId, let title) = event {
            let taskKey = "\(activeProfile)|\(runtimeSessionId)"
            sessionTitleRecoveryTracker.cancel(taskKey)
            applyRecoveredSessionTitle(
                title,
                sessionIDs: [runtimeSessionId, storedSessionId]
            )
            return
        }
        if bufferIfReconciling(event) { return }
        applyStreamEvent(event)
    }

    private func bufferIfReconciling(_ event: StreamEvent) -> Bool {
        guard var reconciliation else { return false }
        guard reconciliation.accepts(sessionID(for: event)) else { return false }
        reconciliation.bufferedEvents.append(event)
        self.reconciliation = reconciliation
        return true
    }

    private func sessionID(for event: StreamEvent) -> String {
        switch event {
        case .messageStart(let sessionId), .messageDelta(let sessionId, _),
                .reasoningDelta(let sessionId, _),
                .messageComplete(let sessionId, _, _, _), .messageError(let sessionId, _),
                .messageInterrupted(let sessionId), .sessionBusy(let sessionId, _),
                .sessionInfo(let sessionId, _), .sessionTitle(let sessionId, _, _),
                .toolStart(let sessionId, _, _),
                .toolComplete(let sessionId, _, _), .reviewSummary(let sessionId, _), .clarify(let sessionId, _, _, _),
                .approval(let sessionId, _),
                .contextUpdate(let sessionId, _, _, _), .cwdUpdate(let sessionId, _),
                .modelUpdate(let sessionId, _, _), .agentCount(let sessionId, _),
                .delegateAgent(let sessionId, _):
            return sessionId
        case .unparsed:
            return ""
        }
    }

    private func eventBelongsToActiveSession(_ sessionId: String) -> Bool {
        guard let activeSessionId, !sessionId.isEmpty else { return false }
        if sessionId == activeSessionId { return true }

        if let activeSession = (sessions + cronSessions).first(where: {
            $0.id == activeSessionId || $0.alternateIds.contains(activeSessionId)
        }) {
            let activeIDs = Set([activeSession.id] + activeSession.alternateIds)
            if activeIDs.contains(sessionId) { return true }
        }

        // During resume, the gateway may switch between the requested and
        // runtime IDs before the catalog has caught up. Only accept those
        // aliases when the active ID is part of the same reconciliation set;
        // this prevents a prior session's buffered events from leaking into a
        // newly selected transcript.
        guard let reconciliation,
              reconciliation.acceptedSessionIDs.contains(activeSessionId) else {
            return false
        }
        return reconciliation.acceptedSessionIDs.contains(sessionId)
    }

    private func applyStreamEvent(
        _ event: StreamEvent,
        authoritativeYolo: Bool? = nil,
        authoritativeApprovalsMode: String? = nil
    ) {
        let streamSessionId = sessionID(for: event)
        guard eventBelongsToActiveSession(streamSessionId) else { return }
        defer { schedulePresentationCacheFlush(for: streamSessionId) }
        if let signal = ResponseHapticPolicy.signal(for: event) {
            applyResponseHapticSignal(signal)
        }

        switch event {
        case .messageStart:
            finalizePendingStreamingCompletion()
            // A new turn ends any live reasoning card; settle first so the
            // previous segment keeps its exact buffered text in the
            // transcript.
            settleReasoningSegmentIntoTranscript()
            resetReasoningTurn()
            setRunning(true)
            notifyVoiceAssistant(.started(sessionID: streamSessionId))

        case .messageDelta(_, let text):
            finalizePendingStreamingCompletion()
            streamingBuffer += text
            scheduleStreamingPublish()
            setRunning(true)
            notifyVoiceAssistant(.delta(sessionID: streamSessionId, text: text))

        case .reasoningDelta(_, let text):
            finalizePendingStreamingCompletion()
            receivedReasoningForCurrentTurn = true
            appendReasoning(text)
            setRunning(true)

        case .messageComplete(_, let messageId, let content, let reasoning):
            scheduleStreamingCompletion(
                sessionId: streamSessionId,
                messageId: messageId,
                content: content,
                reasoning: reasoning
            )
            notifyVoiceAssistant(.completed(sessionID: streamSessionId, content: content))

        case .messageError(_, let message):
            settleReasoningSegmentIntoTranscript()
            resetReasoningTurn()
            clearStreamingText()
            errorMessage = message
            setRunning(false)
            notifyVoiceAssistant(.failed(sessionID: streamSessionId, message: message))

        case .messageInterrupted:
            settleReasoningSegmentIntoTranscript()
            resetReasoningTurn()
            clearStreamingText()
            setRunning(false)
            notifyVoiceAssistant(.interrupted(sessionID: streamSessionId))

        case .sessionBusy(_, let busy):
            setRunning(busy)
            if ResponseHapticPolicy.shouldScheduleIdleConclusion(
                isBusy: busy,
                hasPendingConclusion: responseHaptics.pendingConclusion != nil,
                awaitsUserInput: responseAwaitsUserInput
            ) {
                scheduleResponseHapticConclusion(after: 180)
            }

        case .sessionInfo(let sessionID, let snapshot):
            applyRuntime(
                snapshot,
                for: sessionID,
                authoritativeYolo: authoritativeYolo,
                authoritativeApprovalsMode: authoritativeApprovalsMode
            )
            if let running = snapshot.running {
                setRunning(running)
            }

        case .sessionTitle:
            // Title pushes are catalog events and are handled before the
            // active-session stream gate in handleStreamEvent(_:).
            break

        case .toolStart(_, let name, let input):
            if name.lowercased() == "clarify" { break }
            // The tool card must land after a complete reasoning card; commit
            // the coalesced segment before the boundary reorders the
            // transcript. A tool ends the reasoning SEGMENT only — the turn
            // flag survives so completion-carried reasoning cannot duplicate
            // this segment.
            settleReasoningSegmentIntoTranscript()
            resetReasoningSegment()
            flushStreamingPartial()
            messages.append(ChatMessage(
                id: "tool-start-\(Date().timeIntervalSince1970)",
                role: .tool,
                content: "",
                timestamp: Self.localTimestamp(),
                tool: ToolActivity(id: nil, name: name, input: input, output: nil, status: .running)
            ))

        case .toolComplete(_, let name, let output):
            if name.lowercased() == "clarify" { break }
            settleReasoningSegmentIntoTranscript()
            resetReasoningSegment()
            // Update the matching running tool card in place instead of
            // appending a duplicate. This keeps input + output together in
            // one chronological entry, matching how the HTTP API returns
            // stored messages on reload.
            if let index = messages.lastIndex(where: {
                $0.role == .tool && $0.tool?.name == name && $0.tool?.status == .running
            }) {
                let existing = messages[index].tool
                messages[index].tool = ToolActivity(
                    id: existing?.id,
                    name: name,
                    input: existing?.input,
                    output: output,
                    status: .complete
                )
            } else {
                messages.append(ChatMessage(
                    id: "tool-complete-\(Date().timeIntervalSince1970)",
                    role: .tool,
                    content: "",
                    timestamp: Self.localTimestamp(),
                    tool: ToolActivity(id: nil, name: name, input: nil, output: output, status: .complete)
                ))
            }

        case .reviewSummary(let sessionId, let activity):
            let id = "review-summary-\(sessionId)-\(UUID().uuidString)"
            guard !messages.contains(where: { $0.review == activity }) else { return }
            // A mid-turn row must not land below the live reasoning card's
            // eventual commit — settle first so chronology matches the
            // pre-projection transcript.
            settleReasoningSegmentIntoTranscript()
            messages.append(ChatMessage(
                id: id,
                role: .system,
                content: activity.summary,
                timestamp: Self.localTimestamp(),
                review: activity
            ))
            persistReview(ReviewSummaryRecord(
                id: id,
                profile: activeProfile,
                sessionId: sessionId,
                timestamp: Self.localTimestamp(),
                activity: activity
            ))

        case .clarify(_, let requestId, let question, let choices):
            let activity = ClarifyActivity(
                requestId: requestId,
                question: question,
                choices: choices.map { ClarifyChoice(label: $0.label, value: $0.value) },
                status: .pending
            )
            if let index = messages.firstIndex(where: { $0.clarify?.requestId == requestId }) {
                messages[index].content = question
                messages[index].clarify = activity
            } else {
                // A still-pending push-delivered card for the same question is
                // superseded by the live event (different ids: gateway vs
                // plugin-minted), so one logical clarify never renders two
                // answerable cards. Resolved history stays visible, and a
                // .submitting card is left alone: its relay answer may already
                // be in flight and will settle it by request id.
                var supersededRequestIds: [String] = []
                let liveQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                messages.removeAll { message in
                    guard let clarify = message.clarify,
                          clarify.requestId.hasPrefix(PendingDecisionPayload.relayRequestPrefix),
                          clarify.status == .pending,
                          clarify.question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == liveQuestion else {
                        return false
                    }
                    supersededRequestIds.append(clarify.requestId)
                    return true
                }
                // The superseded card must also leave the presentation cache —
                // the ordinary flush re-appends still-pending stored cards, so
                // an in-memory-only removal would resurface as a duplicate
                // answerable card after the next cold-start resume.
                let cacheSessionIDs = [
                    activeSessionId,
                    reconciliation?.requestedSessionId,
                    reconciliation?.resolvedSessionId
                ].compactMap { $0 }
                for requestId in supersededRequestIds {
                    sessionPresentationCache.removePendingDecision(
                        key: "clarify:\(requestId)",
                        profile: activeProfile,
                        sessionIDs: cacheSessionIDs
                    )
                }
                // The clarify row must sit above the live reasoning card's
                // eventual commit — settle the segment before it lands.
                settleReasoningSegmentIntoTranscript()
                messages.append(ChatMessage(
                    id: "clarify-\(requestId)",
                    role: .clarify,
                    content: question,
                    timestamp: Self.localTimestamp(),
                    clarify: activity
                ))
            }
            setRunning(true)

        case .approval(_, let activity):
            if let index = messages.lastIndex(where: {
                $0.approval?.sessionId == activity.sessionId
                    && ($0.approval?.status == .pending || $0.approval?.status == .submitting)
            }) {
                messages[index].content = activity.description
                messages[index].approval = activity
            } else {
                // Same mid-turn ordering rule as clarify above.
                settleReasoningSegmentIntoTranscript()
                messages.append(ChatMessage(
                    id: "approval-\(activity.sessionId)-\(UUID().uuidString)",
                    role: .approval,
                    content: activity.description,
                    timestamp: Self.localTimestamp(),
                    approval: activity
                ))
            }
            setRunning(true)

        case .contextUpdate(_, let percent, let used, let max):
            runtime.contextPercent = normalizedContextPercent(percent, used: used, max: max)
            runtime.contextUsed = used
            runtime.contextMax = max

        case .cwdUpdate(_, let cwd):
            runtime.cwd = cwd

        case .modelUpdate(_, let model, let provider):
            runtime.model = model
            runtime.provider = provider

        case .agentCount(_, let count):
            activeAgents = count

        case .delegateAgent(_, let activity):
            if let index = delegateAgents.firstIndex(where: { $0.id == activity.id }) {
                var updated = activity
                let existing = delegateAgents[index]
                updated.goal = activity.goal == "Delegate agent" ? existing.goal : activity.goal
                updated.stream = (existing.stream + activity.stream).suffix(20).map { $0 }
                delegateAgents[index] = updated
            } else {
                delegateAgents.append(activity)
            }
            activeAgents = delegateAgents.filter { $0.status.isActive }.count

        case .unparsed:
            break
        }
    }

    /// A reasoning delta belongs exactly where Hermes emitted it. Gateways can
    /// send either deltas or repeated cumulative snapshots, so merge both into
    /// one live card rather than creating duplicate thinking boxes. The first
    /// delta of a segment mounts the live projection immediately so the
    /// thinking box appears promptly; every later delta coalesces through
    /// `reasoningBuffer` and republishes the PROJECTION at display cadence.
    /// The settled transcript is touched only once per segment, at the
    /// boundary commit.
    private func appendReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        reasoningBuffer = mergedReasoning(
            existing: reasoningBuffer,
            incoming: text
        )
        guard activeReasoningMessageId != nil else {
            let id = "reasoning-\(Date().timeIntervalSince1970)"
            activeReasoningMessageId = id
            TranscriptPerf.note(.reasoningProjectionPublish)
            liveReasoningSegment = LiveReasoningSegment(
                id: id,
                timestamp: Self.localTimestamp(),
                content: reasoningBuffer
            )
            return
        }
        scheduleReasoningPublish()
    }

    private func scheduleReasoningPublish() {
        guard !showSidebar, !hasScheduledReasoningPublish else { return }
        hasScheduledReasoningPublish = true
        let cardID = activeReasoningMessageId

        reasoningPublishTask = Task { @MainActor [weak self] in
            do {
                // Reasoning updates republish the live projection at this
                // cadence; an expanded ThinkingCard restyles its attributed
                // text and remeasures a growing height on every commit, so
                // ~20 fps keeps the stream readable while leaving the main
                // actor free between layout passes.
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }

            guard !Task.isCancelled, let self else { return }
            self.hasScheduledReasoningPublish = false
            self.reasoningPublishTask = nil
            self.publishReasoningBuffer(liveCardID: cardID)
        }
    }

    /// Stale publish tasks are structurally inert: once a boundary or session
    /// switch has ended the live card, the captured id no longer matches, so
    /// nothing can mutate a finalized or replaced transcript.
    private func publishReasoningBuffer(liveCardID: String?) {
        guard let liveCardID, liveCardID == activeReasoningMessageId,
              var segment = liveReasoningSegment, segment.id == liveCardID,
              segment.content != reasoningBuffer else { return }
        TranscriptPerf.note(.reasoningProjectionPublish)
        segment.content = reasoningBuffer
        liveReasoningSegment = segment
    }

    /// Publish any coalesced reasoning into the live projection immediately.
    /// Non-boundary callers (the sidebar closing) keep the segment streaming;
    /// boundary callers need `settleReasoningSegmentIntoTranscript()`.
    private func flushReasoningPublish() {
        reasoningPublishTask?.cancel()
        reasoningPublishTask = nil
        hasScheduledReasoningPublish = false
        publishReasoningBuffer(liveCardID: activeReasoningMessageId)
    }

    /// Commit the live reasoning segment into the settled transcript EXACTLY
    /// ONCE at a semantic boundary: tool card, completion, error,
    /// interruption, or a new turn. `explicitContent` supersedes the buffered
    /// text (the completion-carried trace replaces what streamed, exactly as
    /// it replaced the in-transcript card content before the projection
    /// existed). Paired with the boundary's `resetReasoning*` call, this
    /// preserves the pre-projection transcript shape: the card is in
    /// `messages`, complete, and no stale publish can touch it afterwards.
    private func settleReasoningSegmentIntoTranscript(explicitContent: String? = nil) {
        reasoningPublishTask?.cancel()
        reasoningPublishTask = nil
        hasScheduledReasoningPublish = false

        func commit(id: String, timestamp: String, content: String) {
            guard !content.isEmpty else { return }
            // Commit and the projection clear below must stay in ONE
            // transaction: ChatView relies on the committed row's id equaling
            // the live segment's id for a seamless live→settled transition —
            // splitting them would transiently duplicate ids in the
            // LazyVStack. The card keeps its mount timestamp; `author`
            // reflects the profile at settle time (indistinguishable unless
            // the profile switches mid-stream).
            TranscriptPerf.note(.reasoningTranscriptMutation)
            messages.append(ChatMessage(
                id: id,
                role: .reasoning,
                content: content,
                timestamp: timestamp,
                author: activeProfile
            ))
            reasoningBuffer = ""
            activeReasoningMessageId = nil
            liveReasoningSegment = nil
        }

        if let segment = liveReasoningSegment, activeReasoningMessageId == segment.id {
            commit(id: segment.id, timestamp: segment.timestamp, content: explicitContent ?? reasoningBuffer)
        } else if let text = explicitContent {
            commit(
                id: "reasoning-\(Date().timeIntervalSince1970)",
                timestamp: Self.localTimestamp(),
                content: text
            )
        }
    }

    /// End the active reasoning SEGMENT without publishing. Used at tool
    /// boundaries: the tool card ends the current thinking card, but the
    /// assistant TURN continues — reasoning may resume in a fresh segment, and
    /// reasoning already streamed this turn still counts at completion.
    private func resetReasoningSegment() {
        reasoningPublishTask?.cancel()
        reasoningPublishTask = nil
        hasScheduledReasoningPublish = false
        reasoningBuffer = ""
        activeReasoningMessageId = nil
        liveReasoningSegment = nil
    }

    /// Restore the ENTIRE per-turn reasoning state machine to its initial
    /// condition. Used when the turn or transcript itself is being replaced
    /// (message boundaries, completion, disconnect, session switch): the old
    /// card must not receive further updates — including from an in-flight
    /// publish — and the next turn's completion-carried reasoning must not
    /// look already-streamed.
    private func resetReasoningTurn() {
        resetReasoningSegment()
        receivedReasoningForCurrentTurn = false
    }

    private func mergedReasoning(existing: String, incoming: String) -> String {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }
        if incoming.hasPrefix(existing) { return incoming }
        if existing.hasSuffix(incoming) { return existing }
        return existing + incoming
    }

    /// Completion sometimes carries the full reasoning trace as well as the
    /// deltas. Prefer that complete value without duplicating an already
    /// streamed card; gateways that only provide completion still get a card
    /// immediately before their final answer. Completion is a boundary: the
    /// trace commits straight into the settled transcript rather than the
    /// live projection. Reachable only when nothing streamed this turn (the
    /// caller gates on `receivedReasoningForCurrentTurn`), so there is never
    /// a live segment to supersede here — `explicitContent` always mounts a
    /// fresh settled card.
    private func finalizeReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        settleReasoningSegmentIntoTranscript(explicitContent: text)
    }

    func requestChatScrollToLatest() {
        chatScrollRequest &+= 1
    }

    func requestChatScrollToTop() {
        chatScrollToTopRequest &+= 1
    }

    private func updateActiveSessionTitle(for sessionId: String, fallbackSessionId: String? = nil) {
        let ids = [sessionId, fallbackSessionId].compactMap { $0 }
        guard let session = (sessions + cronSessions).first(where: { session in
            ids.contains(session.id) || ids.contains(where: session.alternateIds.contains)
        }) else { return }
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        setActiveSessionTitle(title.isEmpty ? "New conversation" : title)
    }

    // MARK: - Chat support surfaces

    func openWorkspace() async {
        guard !runtime.cwd.isEmpty else {
            errorMessage = "Workspace unavailable: Hermes has not reported a working directory for this session yet."
            return
        }
        workspaceRoot = runtime.cwd
        workspaceEntries = [:]
        expandedWorkspacePaths = []
        workspaceError = nil
        workspaceSelectedFile = nil
        workspacePreview = nil
        workspaceFileError = nil
        showWorkspaceSheet = true
        await loadWorkspace(path: runtime.cwd)
    }

    func refreshWorkspace() async {
        guard !workspaceRoot.isEmpty else { return }
        workspaceEntries = [:]
        expandedWorkspacePaths = []
        await loadWorkspace(path: workspaceRoot)
    }

    func toggleWorkspaceFolder(_ entry: WorkspaceEntry) async {
        guard entry.isDirectory else { return }
        if expandedWorkspacePaths.contains(entry.path) {
            expandedWorkspacePaths.remove(entry.path)
            return
        }
        expandedWorkspacePaths.insert(entry.path)
        guard workspaceEntries[entry.path] == nil else { return }
        if !(await loadWorkspace(path: entry.path)) {
            expandedWorkspacePaths.remove(entry.path)
        }
    }

    func previewWorkspaceFile(_ entry: WorkspaceEntry) async {
        guard let dashboardTicketBridge else { return }
        let profile = activeProfile
        workspaceSelectedFile = entry
        workspacePreview = nil
        workspaceFileError = nil
        workspaceFileLoading = true
        defer { workspaceFileLoading = false }
        do {
            guard let path = DashboardPath.encodedQueryComponent(entry.path) else {
                throw DashboardTicketBridgeError.requestFailed("The workspace path could not be encoded.")
            }
            let result = try await dashboardTicketBridge.requestJSON(
                path: DashboardPath.withProfile("/api/fs/read-text?path=\(path)", profile: profile)
            )
            guard profile == activeProfile else { return }
            workspacePreview = WorkspaceFilePreview(
                binary: result["binary"] as? Bool ?? false,
                byteSize: result["byteSize"] as? Int ?? 0,
                language: result["language"] as? String ?? "text",
                mimeType: result["mimeType"] as? String ?? "text/plain",
                text: result["text"] as? String ?? "",
                truncated: result["truncated"] as? Bool ?? false
            )
        } catch {
            workspaceFileError = error.localizedDescription
        }
    }

    func workspaceDownloadURL(for entry: WorkspaceEntry) async -> URL? {
        guard let dashboardTicketBridge else { return nil }
        let profile = activeProfile
        do {
            guard let path = DashboardPath.encodedQueryComponent(entry.path) else {
                throw DashboardTicketBridgeError.requestFailed("The workspace path could not be encoded.")
            }
            let result = try await dashboardTicketBridge.requestJSON(
                path: DashboardPath.withProfile("/api/fs/read-data-url?path=\(path)", profile: profile),
                maxResponseBytes: DataURLLimits.maxJSONResponseBytes
            )
            guard profile == activeProfile else { return nil }
            guard let dataURL = result["dataUrl"] as? String,
                  let data = DataURLLimits.decodeBase64DataURL(dataURL) else {
                throw DashboardTicketBridgeError.requestFailed("The gateway returned an invalid file payload.")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hermes-Conduit-Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString)-\(entry.name)")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            workspaceFileError = error.localizedDescription
            return nil
        }
    }

    /// Hermes messages can refer to generated media as `MEDIA:
    /// /absolute/path.png`, while Desktop persists uploaded images as
    /// `@image:/absolute/path.png`. Keep those paths on the gateway: its
    /// authenticated dashboard returns a data URL that the chat can display
    /// without exposing a gateway filesystem URL to iOS.
    func gatewayMediaDataURL(for path: String, profile: String) async -> String? {
        guard let dashboardTicketBridge else { return nil }
        guard let encodedPath = DashboardPath.encodedQueryComponent(path) else { return nil }
        let endpoint = DashboardPath.withProfile("/api/fs/read-data-url?path=\(encodedPath)", profile: profile)

        do {
            let result = try await dashboardTicketBridge.requestJSON(
                path: endpoint,
                maxResponseBytes: DataURLLimits.maxJSONResponseBytes
            )
            guard let dataURL = result["dataUrl"] as? String,
                  DataURLLimits.isBoundedBase64DataURL(dataURL, prefix: "data:image/") else { return nil }
            return dataURL
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    func loadGatewayDiagnostics() async {
        showGatewaySheet = true
        gatewayDiagnosticsLoading = true
        defer { gatewayDiagnosticsLoading = false }
        guard let dashboardTicketBridge else {
            gatewayDiagnostics = GatewayDiagnostics(gatewayRunning: isConnected, gatewayState: nil, version: nil, pid: nil, connectors: [], logs: [], error: "Dashboard diagnostics are still loading.")
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
                name: item["name"] as? String ?? item["platform"] as? String ?? "Connector",
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
            error: status == nil ? "Could not refresh dashboard status." : nil
        )
    }

    @discardableResult
    private func loadWorkspace(path: String) async -> Bool {
        workspaceLoadingPath = path
        workspaceError = nil
        defer { if workspaceLoadingPath == path { workspaceLoadingPath = nil } }
        do {
            workspaceEntries[path] = try await workspaceDirectoryEntries(at: path)
            return true
        } catch {
            workspaceError = error.localizedDescription
            return false
        }
    }

    private func setRunning(_ running: Bool) {
        guard turnState != .unsupportedGateway else { return }
        if running {
            clearPendingDecisionRestorationGuard()
        }
        turnState = running ? .running : .idle
    }

    private func applyResponseHapticSignal(_ signal: ResponseHapticPolicy.Signal) {
        switch signal {
        case .activity(let playsStart):
            registerResponseActivity(playsStart: playsStart)
        case .tool:
            registerToolHaptic()
        case .failure:
            failResponseHapticTurn()
        case .reset:
            resetResponseHapticTurn()
        }
    }

    private func registerResponseActivity(playsStart: Bool) {
        cancelPendingResponseHapticConclusion()
        performResponseHapticEffects(
            responseHaptics.registerActivity(playsStart: playsStart)
        )
    }

    private func registerToolHaptic() {
        cancelPendingResponseHapticConclusion()
        performResponseHapticEffects(responseHaptics.registerTool(at: Date()))
    }

    private var responseAwaitsUserInput: Bool {
        messages.contains { message in
            message.clarify.map { $0.status == .pending || $0.status == .submitting } == true
                || message.approval.map { $0.status == .pending || $0.status == .submitting } == true
        }
    }

    private func scheduleResponseHapticConclusion(after delayMilliseconds: Int) {
        cancelPendingResponseHapticConclusion()
        guard let conclusion = responseHaptics.scheduleConclusion(
            sessionID: activeSessionId
        ) else { return }
        responseHapticConclusionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.activeSessionId == conclusion.sessionID,
                  let effect = self.responseHaptics.finishConclusion(conclusion) else {
                return
            }
            self.responseHapticConclusionTask = nil
            self.performResponseHapticEffects([effect])
        }
    }

    private func failResponseHapticTurn() {
        responseHapticConclusionTask?.cancel()
        responseHapticConclusionTask = nil
        performResponseHapticEffects(responseHaptics.fail())
    }

    private func resetResponseHapticTurn() {
        responseHapticConclusionTask?.cancel()
        responseHapticConclusionTask = nil
        performResponseHapticEffects(responseHaptics.reset())
    }

    private func cancelPendingResponseHapticConclusion() {
        responseHapticConclusionTask?.cancel()
        responseHapticConclusionTask = nil
        responseHaptics.invalidateConclusion()
    }

    private func performResponseHapticEffects(
        _ effects: [ResponseHapticState.Effect]
    ) {
        for effect in effects {
            switch effect {
            case .responseStarted:
                Haptics.responseStarted()
            case .toolStarted:
                Haptics.toolStarted()
            case .responseConcluded:
                Haptics.responseConcluded()
            case .error:
                Haptics.error()
            case .cancelPattern:
                Haptics.cancelLifecyclePattern()
            }
        }
    }

    /// Voice uses the same submission and active-turn interruption policy as
    /// the composer. Keeping this seam here prevents audio UI from inferring
    /// request state from transcript timing.
    func submitVoiceTranscript(_ transcript: String) async -> Bool {
        await submitComposer(text: transcript, attachments: [])
    }

    /// Stops the authoritative Hermes turn when a spoken stop command or
    /// barge-in wins the race with model generation.
    func interruptForVoice() async {
        await cancelCurrent()
    }

    func makeVoiceGateway() -> HermesVoiceGateway? {
        guard let dashboardTicketBridge, let connection else { return nil }
        return HermesVoiceGateway(
            bridge: dashboardTicketBridge,
            baseURL: connection.baseUrl,
            profile: activeProfile
        )
    }

    var voiceUnavailableReason: String? {
        if !isConnected { return "Connect to Hermes before starting voice." }
        if !isVoiceEnabled { return "Enable voice for this profile in Settings." }
        if voiceTranscriptionMode == .appleOnDevice, !appleSpeechAvailability.canAttemptRecognition {
            switch appleSpeechAvailability {
            case .permissionDenied:
                return "Allow Speech Recognition in iOS Settings to use on-device transcription."
            case .unsupported(let localeIdentifier):
                return "On-device Apple speech recognition is unavailable for \(localeIdentifier)."
            case .ready, .permissionRequired:
                break
            }
        }
        if voiceTranscriptionMode == .hermes, !voiceCapabilitySnapshot.supportsTranscription {
            return voiceCapabilitySnapshot.unavailableReason ?? "This Hermes profile has no ready speech-to-text provider."
        }
        if !voiceCapabilitySnapshot.supportsSpeech {
            return "This Hermes profile has no ready text-to-speech provider."
        }
        return nil
    }

    var canStartVoiceConversation: Bool { voiceUnavailableReason == nil }

    /// TTS-only availability for read aloud: a connected gateway with voice
    /// enabled and a ready speech provider. Deliberately does not require
    /// transcription, mic permission, or Apple Speech — a profile with TTS
    /// but no STT must still be able to read responses aloud.
    var readAloudUnavailableReason: String? {
        // Opening a stream needs the dashboard bridge; while it is absent
        // (mid sign-out, before the connection lands) disable the button
        // instead of failing at tap time. Mirrors makeVoiceGateway().
        guard dashboardTicketBridge != nil, connection != nil else {
            return "Read aloud needs a connected Hermes gateway."
        }
        return MessageReadAloudController.unavailableReason(
            isConnected: isConnected,
            isVoiceEnabled: isVoiceEnabled,
            snapshot: voiceCapabilitySnapshot
        )
    }

    /// Chat bubble entry point for manual read aloud. Toggling the active
    /// message stops it without touching the gateway; starting a different
    /// message takes over from whatever is playing.
    func toggleReadAloud(message: ChatMessage) {
        if messageReadAloudController.isActiveMessage(message.id) {
            messageReadAloudController.stop()
            return
        }
        guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let reason = readAloudUnavailableReason {
            errorMessage = reason
            return
        }
        // The capability refresh keeps the gateway current; this covers the
        // gap before the next refresh has run — including right after a
        // profile switch or re-login, when a stale gateway may still be set.
        if !readAloudGatewayIsCurrent {
            assignReadAloudGateway()
        }
        // Mutual exclusion (reverse of openVoiceConversation / runVoiceTTSTest):
        // the voice conversation and read aloud each own their own playback
        // instance, so a speech test or conversation still speaking must stop
        // before the manual stream opens — otherwise both engines play at once.
        voiceConversationController.stop()
        messageReadAloudController.toggle(messageID: message.id, content: message.content)
    }

    func refreshVoiceCapabilities() async {
        let profile = activeProfile
        guard isConnected, let bridge = dashboardTicketBridge else {
            voiceCapabilitySnapshot = .unavailable
            isVoiceEnabled = false
            voiceConversationController.setGateway(nil)
            refreshReadAloudGateway()
            return
        }
        installVoiceAssistantObserverIfNeeded()
        isVoiceEnabled = defaults.bool(forKey: voiceEnabledPreferenceKey(profile: profile))
        appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
        let service = HermesVoiceConfigurationService(bridge: bridge, profile: profile)
        await service.reload()
        guard profile == activeProfile, bridge === dashboardTicketBridge else { return }
        voiceCapabilitySnapshot = service.snapshot.capability
        let preferences = loadVoiceProfilePreferences(profile: profile)
        voiceTranscriptionMode = preferences.resolvedTranscriptionMode
        voiceConversationController.setProfilePreferences(preferences)
        refreshVoiceControllerGateway()
        refreshReadAloudGateway()
    }

    @discardableResult
    func setVoiceEnabled(_ enabled: Bool) async -> Bool {
        guard isConnected else { return false }
        defaults.set(enabled, forKey: voiceEnabledPreferenceKey(profile: activeProfile))
        isVoiceEnabled = enabled
        refreshVoiceControllerGateway()
        refreshReadAloudGateway()
        if !enabled {
            voiceConversationController.stop()
            showVoiceSheet = false
        }
        return true
    }

    @discardableResult
    func setVoiceTranscriptionMode(_ mode: VoiceTranscriptionMode) async -> Bool {
        appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
        if mode == .appleOnDevice, !appleSpeechAvailability.canAttemptRecognition {
            switch appleSpeechAvailability {
            case .permissionDenied:
                errorMessage = "Speech Recognition permission was denied. Please enable it in Settings > Conduit > Speech Recognition."
            case .unsupported(let localeIdentifier):
                let localeName = Locale.current.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
                errorMessage = "On-device speech recognition is not available for \(localeName)."
            default:
                errorMessage = "On-device speech recognition is unavailable."
            }
            return false
        }
        if mode == .appleOnDevice {
            let permissionResult = await voiceConversationController.requestOnDeviceTranscriptionPermissions()
            appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
            guard permissionResult.passed else {
                errorMessage = permissionResult.message
                return false
            }
        }
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        preferences.transcriptionMode = mode
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        voiceTranscriptionMode = mode
        voiceConversationController.setProfilePreferences(preferences)
        refreshVoiceControllerGateway()
        refreshReadAloudGateway()
        return true
    }

    @discardableResult
    func openVoiceConversation(_ intent: PendingVoiceIntent) async -> Bool {
        guard isConnected else { return false }
        // Mutual exclusion: the voice conversation owns playback while its
        // sheet is open, so a read aloud started before must not continue.
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        if let rawProfile = intent.profile {
            let requestedProfile = rawProfile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !requestedProfile.isEmpty, requestedProfile != activeProfile {
                await switchProfile(to: requestedProfile)
            }
            guard requestedProfile.isEmpty || requestedProfile == activeProfile else {
                errorMessage = "Conduit could not open the requested voice profile."
                return true
            }
        }
        guard isConnected else { return false }
        if turnState.isRunning {
            guard intent.startsFreshConversation else {
                errorMessage = "Stop the current response before starting voice in this conversation."
                return true
            }
            await cancelCurrent()
        }
        await refreshVoiceCapabilities()
        guard canStartVoiceConversation else {
            errorMessage = voiceUnavailableReason
            return true
        }
        let previousSessionID = activeSessionId
        if intent.startsFreshConversation || activeSessionId == nil {
            await createNewSession()
            if intent.startsFreshConversation, activeSessionId == previousSessionID {
                errorMessage = "Hermes could not create the requested voice conversation."
                return true
            }
        }
        guard let sessionID = activeSessionId, let gateway = makeVoiceGateway() else {
            errorMessage = "Hermes could not prepare a voice conversation."
            return true
        }
        voiceConversationController.setGateway(gateway)
        voiceConversationController.beginVoiceTurn(sessionID: sessionID)
        showSidebar = false
        showVoiceSheet = true
        return true
    }

    func closeVoiceConversation() {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        preferences.outputMuted = voiceConversationController.isOutputMuted
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        voiceConversationController.endVoiceSession()
        showVoiceSheet = false
    }

    func runVoiceASRTest() async -> VoiceProviderTestResult {
        await refreshVoiceCapabilities()
        guard isVoiceEnabled else {
            return .failure("Enable voice for this profile before running a speech-to-text test.")
        }
        guard selectedTranscriptionIsAvailable else {
            return .failure(voiceUnavailableReason ?? "The selected speech-to-text option is unavailable.")
        }
        guard let gateway = makeVoiceGateway() else {
            return .failure("Conduit could not connect this test to the selected profile.")
        }
        voiceConversationController.setGateway(gateway)
        let result = await voiceConversationController.runTranscriptionTest()
        appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
        refreshVoiceControllerGateway()
        return result
    }

    func runVoiceTTSTest() async -> VoiceProviderTestResult {
        await refreshVoiceCapabilities()
        guard isVoiceEnabled else {
            return .failure("Enable voice for this profile before running a speech playback test.")
        }
        guard voiceCapabilitySnapshot.supportsSpeech else {
            return .failure(voiceUnavailableReason ?? "The selected assistant speech provider is unavailable.")
        }
        guard let gateway = makeVoiceGateway() else {
            return .failure("Conduit could not connect this test to the selected profile.")
        }
        // The speech test speaks through the voice controller's own playback
        // instance (the same AVSpeech infrastructure read aloud uses, but a
        // separate instance), so the test and a still-playing message would
        // otherwise both produce audio. AppState enforces mutual exclusion in
        // both directions; toggleReadAloud stops this controller in turn.
        messageReadAloudController.stop()
        voiceConversationController.setGateway(gateway)
        return await voiceConversationController.runSpeechTest(
            text: "Conduit voice is ready for this profile."
        )
    }

    private func voiceEnabledPreferenceKey(profile: String) -> String {
        let gateway = connection?.baseUrl.lowercased() ?? "disconnected"
        return "conduit.voice.enabled.v1.\(gateway).\(profile)"
    }

    private func voicePreferencesKey(profile: String) -> String {
        let gateway = connection?.baseUrl.lowercased() ?? "disconnected"
        return "conduit.voice.preferences.v1.\(gateway).\(profile)"
    }

    private var selectedTranscriptionIsAvailable: Bool {
        switch voiceTranscriptionMode {
        case .hermes: return voiceCapabilitySnapshot.supportsTranscription
        case .appleOnDevice: return appleSpeechAvailability.canAttemptRecognition
        }
    }

    private func refreshVoiceControllerGateway() {
        voiceConversationController.setGateway(
            isVoiceEnabled && selectedTranscriptionIsAvailable ? makeVoiceGateway() : nil
        )
    }

    /// Keeps the read aloud gateway in step with capability refreshes without
    /// churning a live instance: swapping the gateway mid-playback would stop
    /// the message. A kept gateway must still match the active profile AND
    /// the live dashboard bridge — a gateway built against an invalidated or
    /// rotated bridge (re-login, profile switch) is rebuilt instead.
    private var readAloudGatewayIsCurrent: Bool {
        guard let gateway = messageReadAloudController.gateway,
              let bridge = dashboardTicketBridge else { return false }
        return gateway.profile == activeProfile && readAloudGatewayBridge === bridge
    }

    private func assignReadAloudGateway() {
        messageReadAloudController.setGateway(makeVoiceGateway())
        readAloudGatewayBridge = dashboardTicketBridge
    }

    private func refreshReadAloudGateway() {
        if readAloudUnavailableReason != nil {
            messageReadAloudController.setGateway(nil)
            readAloudGatewayBridge = nil
            return
        }
        guard !readAloudGatewayIsCurrent else { return }
        assignReadAloudGateway()
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
        appleSpeechAvailability: AppleSpeechRecognitionAvailability? = nil
    ) {
        dashboardTicketBridge = bridge
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

    private func loadVoiceProfilePreferences(profile: String) -> VoiceProfilePreferences {
        guard let data = defaults.data(forKey: voicePreferencesKey(profile: profile)),
              let preferences = try? JSONDecoder().decode(VoiceProfilePreferences.self, from: data) else {
            return VoiceProfilePreferences()
        }
        return preferences
    }

    private func saveVoiceProfilePreferences(_ preferences: VoiceProfilePreferences, profile: String) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: voicePreferencesKey(profile: profile))
    }

    private func installVoiceAssistantObserverIfNeeded() {
        guard voiceAssistantObserverID == nil else { return }
        voiceAssistantObserverID = addVoiceAssistantObserver { [weak self] event in
            self?.voiceConversationController.receiveAssistantEvent(event)
        }
    }

    /// Subscribes to the same authenticated socket events that establish turn
    /// state. Voice playback therefore never infers completion from visible
    /// transcript content or rendering cadence.
    @discardableResult
    func addVoiceAssistantObserver(_ observer: @escaping @MainActor (VoiceAssistantEvent) -> Void) -> UUID {
        let id = UUID()
        voiceAssistantObservers[id] = observer
        return id
    }

    func removeVoiceAssistantObserver(_ id: UUID) {
        voiceAssistantObservers.removeValue(forKey: id)
    }

    private func notifyVoiceAssistant(_ event: VoiceAssistantEvent) {
        voiceAssistantObservers.values.forEach { $0(event) }
    }

    private func scheduleStreamingPublish() {
        guard !showSidebar, !hasScheduledStreamingPublish else { return }
        hasScheduledStreamingPublish = true

        streamingPublishTask = Task { [weak self] in
            do {
                // Coalesce raw deltas just enough to avoid invalidating the
                // transcript for every WebSocket frame. Character pacing is
                // owned by StreamingText after this projection is published.
                try await Task.sleep(for: .milliseconds(33))
            } catch {
                return
            }

            guard !Task.isCancelled, let self else { return }
            let projectedText = self.streamingBuffer
            self.lastStreamingPublishBurst = max(
                projectedText.count - self.streamingText.count,
                0
            )
            self.lastStreamingPublishDate = Date()
            self.streamingText = projectedText
            self.hasScheduledStreamingPublish = false
            self.streamingPublishTask = nil
        }
    }

    private func scheduleStreamingCompletion(
        sessionId: String,
        messageId: String?,
        content: String?,
        reasoning: String?
    ) {
        // messageComplete is a semantic boundary: the thinking card must show
        // its full buffered reasoning immediately, not one cadence later.
        settleReasoningSegmentIntoTranscript()
        streamingCompletionTask?.cancel()
        streamingPublishTask?.cancel()
        streamingPublishTask = nil
        hasScheduledStreamingPublish = false

        let finalContent = content ?? streamingBuffer
        let hasPartials = messages.contains { $0.role == .partial }
        let finalProjection = hasPartials ? streamingBuffer : finalContent
        let newlyPublishedCharacters = max(finalProjection.count - streamingText.count, 0)
        let recentPublishBurst: Int
        if let lastStreamingPublishDate,
           Date().timeIntervalSince(lastStreamingPublishDate) < 0.25 {
            recentPublishBurst = lastStreamingPublishBurst
        } else {
            recentPublishBurst = 0
        }
        let charactersToDrain = max(newlyPublishedCharacters, recentPublishBurst)
        if !finalProjection.isEmpty {
            streamingText = finalProjection
        }
        pendingStreamingCompletion = PendingStreamingCompletion(
            sessionId: sessionId,
            messageId: messageId,
            finalContent: finalContent,
            reasoning: reasoning
        )
        // The gateway turn is complete immediately; only its final visual tail
        // remains buffered. This keeps Send/Stop/Steer state truthful.
        setRunning(false)

        // Completed streams use StreamingText's fast reveal batch. Keep enough
        // time for its per-character fade while capping the visual tail.
        let drainMilliseconds = min(
            1_200,
            max(180, Int((Double(charactersToDrain) / 540.0) * 1_000) + 180)
        )
        scheduleResponseHapticConclusion(after: drainMilliseconds)

        streamingCompletionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(drainMilliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.activeSessionId == sessionId else { return }
            self.finalizePendingStreamingCompletion(cancelResponseHapticConclusion: false)
        }
    }

    private func finalizePendingStreamingCompletion(
        cancelResponseHapticConclusion: Bool = true
    ) {
        guard let pendingStreamingCompletion else { return }
        if cancelResponseHapticConclusion {
            cancelPendingResponseHapticConclusion()
        }
        streamingCompletionTask?.cancel()
        streamingCompletionTask = nil
        self.pendingStreamingCompletion = nil
        finalizeStreamingCompletion(
            sessionId: pendingStreamingCompletion.sessionId,
            messageId: pendingStreamingCompletion.messageId,
            finalContent: pendingStreamingCompletion.finalContent,
            reasoning: pendingStreamingCompletion.reasoning
        )
    }

    private func finalizeStreamingCompletion(
        sessionId: String,
        messageId: String?,
        finalContent: String,
        reasoning: String?
    ) {
        // Reasoning that raced the drain window must not be discarded when
        // the pending completion finalizes.
        settleReasoningSegmentIntoTranscript()
        removeAllPartials()
        // Some gateways repeat the full trace in completion after already
        // emitting reasoning events. Use it only when streaming supplied no
        // reasoning so an existing card is not duplicated.
        if !receivedReasoningForCurrentTurn, let reasoning, !reasoning.isEmpty {
            finalizeReasoning(reasoning)
        }

        let firstTurnUserMessage = messages.first(where: { $0.role == .user })?.content
        let isFirstUserTurn = messages.filter { $0.role == .user }.count == 1
        let resolvedMessageID = messageId
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "assistant-\(Date().timeIntervalSince1970)"
        let systemNotice = MessageNormalizer.systemNoticeText(fromText: finalContent)
        let displayContent = systemNotice ?? finalContent
        let displayRole: MessageRole = systemNotice == nil ? .assistant : .system
        if !displayContent.isEmpty,
           (messages.last?.role != displayRole || messages.last?.content != displayContent) {
            messages.append(ChatMessage(
                id: resolvedMessageID,
                role: displayRole,
                content: displayContent,
                rawContent: systemNotice == nil ? nil : finalContent,
                timestamp: Self.localTimestamp(),
                author: activeProfile
            ))
        }

        clearStreamingText()
        activeAssistantMessageId = nil
        resetReasoningTurn()
        setRunning(false)
        // Cancel any pending coalesced flush and write immediately — the
        // turn is complete so all messages are in their final state.
        flushPendingPresentationCache()
        cacheMessagePresentation(for: [sessionId])

        if displayRole == .assistant,
           isFirstUserTurn,
           let firstTurnUserMessage,
           !finalContent.isEmpty {
            scheduleSecondaryProfileTitleRecovery(
                sessionId: sessionId,
                userMessage: firstTurnUserMessage,
                assistantMessage: finalContent
            )
        }
    }

    /// Flush any accumulated streaming text as a .partial message so tool cards
    /// interleave correctly with assistant text during a turn.
    private func flushStreamingPartial() {
        let buffer = streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !buffer.isEmpty else { return }
        messages.append(ChatMessage(
            id: "partial-\(Date().timeIntervalSince1970)",
            role: .partial,
            content: buffer,
            timestamp: Self.localTimestamp()
        ))
        streamingBuffer = ""
        streamingText = ""
    }

    /// Remove all .partial messages and reset streaming state. Called when
    /// the final assistant message arrives to replace partials with one clean entry.
    private func removeAllPartials() {
        messages.removeAll { $0.role == .partial }
    }

    private func clearStreamingText() {
        streamingCompletionTask?.cancel()
        streamingCompletionTask = nil
        pendingStreamingCompletion = nil
        streamingPublishTask?.cancel()
        streamingPublishTask = nil
        hasScheduledStreamingPublish = false
        lastStreamingPublishBurst = 0
        lastStreamingPublishDate = nil
        streamingBuffer = ""
        streamingText = ""
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let key = "hermes-conduit.connection.v1"
    private static let dashboardCookieKey = "hermes-conduit.dashboard-cookies.v1"
    private static let credentialsKey = "hermes-conduit.credentials.v1"
    private static let cloudflareAccessKey = "hermes-conduit.cloudflare-access.v1"
    private static let pushRegistrationKey = "hermes-conduit.push-registration.v1"
    private static let service = "com.milim.conduit"

    static func saveConnection(_ conn: HermesConnection) {
        guard let data = try? JSONEncoder().encode(conn) else { return }
        save(data, account: key)
    }

    static func saveDashboardCookies(_ data: Data) {
        save(data, account: dashboardCookieKey)
    }

    static func loadDashboardCookies() -> Data? {
        load(account: dashboardCookieKey)
    }

    static func saveCredentials(_ credentials: DashboardCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        save(
            data,
            account: credentialsKey,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    static func loadCredentials() -> DashboardCredentials? {
        guard let data = load(account: credentialsKey) else { return nil }
        return try? JSONDecoder().decode(DashboardCredentials.self, from: data)
    }

    static func clearCredentials() {
        delete(account: credentialsKey)
    }

    static func saveCloudflareAccess(_ access: CloudflareAccessCredentials, origin: String) {
        let stored = CloudflareAccessKeychainRecord(clientID: access.clientID, clientSecret: access.clientSecret, origin: origin)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        save(data, account: cloudflareAccessKey, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    /// Returns credentials only if the stored origin matches the given base URL.
    /// This prevents a token saved for one gateway from leaking to a different host.
    static func loadCloudflareAccess(for baseURL: String? = nil) -> CloudflareAccessCredentials? {
        guard let data = load(account: cloudflareAccessKey),
              let stored = try? JSONDecoder().decode(CloudflareAccessKeychainRecord.self, from: data) else { return nil }
        if let baseURL {
            let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL)) ?? baseURL
            guard stored.origin == normalized else { return nil }
        }
        return stored.credentials
    }

    static func clearCloudflareAccess() {
        delete(account: cloudflareAccessKey)
    }

    static func savePushRegistration(_ data: Data) {
        save(data, account: pushRegistrationKey)
    }

    static func loadPushRegistration() -> Data? {
        load(account: pushRegistrationKey)
    }

    static func clearPushRegistration() {
        delete(account: pushRegistrationKey)
    }

    private static func save(
        _ data: Data,
        account: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        let query = scopedQuery(account: account)
        // Accessibility belongs to a Keychain item at creation. Including it
        // in every update can reject an otherwise valid cookie update.
        let updateStatus = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data
        ] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = accessibility
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func loadConnection() -> HermesConnection? {
        guard let data = load(account: key) else { return nil }
        return try? JSONDecoder().decode(HermesConnection.self, from: data)
    }

    private static func load(account: String) -> Data? {
        load(query: scopedQuery(account: account)) ?? load(query: legacyQuery(account: account))
    }

    private static func load(query: [String: Any]) -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    static func clearConnection() {
        delete(account: key)
        delete(account: dashboardCookieKey)
    }

    private static func delete(account: String) {
        SecItemDelete(scopedQuery(account: account) as CFDictionary)
        SecItemDelete(legacyQuery(account: account) as CFDictionary)
    }

    private static func scopedQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func legacyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
    }
}

// MARK: - Attachment Helper

/// Pure ownership rules for capability loads, extracted for deterministic
/// testing of the rapid-profile-switch races.
enum CapabilityLoadPolicy {
    /// A finished request may commit only while it is still the newest load
    /// AND its profile is still active (A -> B -> A stale commits rejected).
    static func canCommit(
        generation: UInt64,
        latestGeneration: UInt64,
        requestedProfile: String,
        activeProfile: String
    ) -> Bool {
        generation == latestGeneration && requestedProfile == activeProfile
    }

    /// Rows may render only when the snapshot belongs to the active profile.
    static func shouldPresentRows(snapshotProfile: String?, activeProfile: String) -> Bool {
        snapshotProfile == activeProfile
    }

    /// Final rendering boundary for the Capabilities screen. Foreign or absent
    /// snapshots can never resolve to a row-bearing state - toggles must never
    /// appear under a profile they do not belong to.
    enum PresentationState: Equatable {
        case loading
        case failure(String)
        case emptySuccess
        case list(banner: String?)
    }

    static func resolvePresentation(
        snapshotProfile: String?,
        activeProfile: String,
        isLoading: Bool,
        loadError: String?,
        hasRows: Bool
    ) -> PresentationState {
        let ownsSnapshot = shouldPresentRows(
            snapshotProfile: snapshotProfile,
            activeProfile: activeProfile
        )

        // The view's request token guarantees a settled error belongs to the
        // CURRENT request/profile - never to a foreign one. So errors surface
        // before any snapshot-ownership masking; otherwise a failed first
        // load (no snapshot yet) would hide behind an eternal spinner.
        if isLoading {
            return .loading
        }

        if let loadError {
            if ownsSnapshot && hasRows {
                return .list(banner: loadError)
            }
            return .failure(loadError)
        }

        guard ownsSnapshot else {
            // No settled result for this profile yet: never render rows that
            // belong to another profile while the current one is pending.
            return .loading
        }

        return hasRows ? .list(banner: nil) : .emptySuccess
    }
}

enum AttachmentHelper {
    static func toBase64(_ attachment: Attachment) async -> String {
        guard let data = data(for: attachment) else { return "" }
        return data.base64EncodedString()
    }

    static func toDataUrl(_ attachment: Attachment) async -> String {
        guard let data = data(for: attachment) else { return "" }
        let mimeType = attachment.mimeType?.isEmpty == false ? attachment.mimeType! : "application/octet-stream"
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private static func data(for attachment: Attachment) -> Data? {
        guard let url = URL(string: attachment.uri), url.isFileURL else { return nil }
        return try? Data(contentsOf: url)
    }
}

private enum AttachmentError: LocalizedError {
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let name): return "Could not read \(name)."
        }
    }
}
