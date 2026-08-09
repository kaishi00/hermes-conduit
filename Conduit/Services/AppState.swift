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

private let sessionCatalogLog = Logger(subsystem: "com.milim.conduit", category: "SessionCatalog")
private let titleGenerationLog = Logger(subsystem: "com.milim.conduit", category: "TitleGeneration")

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
    var openSession: (@MainActor (HermesClient, String) async throws -> SessionResumeResult)?
    var branchSession: (@MainActor (
        HermesClient,
        String,
        [SessionBranchMessage],
        String,
        String?
    ) async throws -> BranchResult)?
    var setSessionTitle: (@MainActor (HermesClient, String, String) async throws -> Void)?
    var refreshContext: (@MainActor (HermesClient, String) async -> Void)?
    var sendPrompt: (@MainActor (HermesClient, String, String) async throws -> Void)?
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
    var loadProfiles: (@MainActor () async -> Void)?
    var loadBusyInputMode: (@MainActor (HermesClient) async -> Void)?
    var loadProfileDisplayPreferences: (@MainActor () async -> Void)?
    var loadSlashCommands: (@MainActor () async -> Void)?

    init(
        connectClient: (@MainActor (HermesClient) async throws -> Void)? = nil,
        loadCatalog: (@MainActor (HermesClient, Bool) async throws -> [SessionSummary])? = nil,
        mintTicket: (@MainActor (String) async throws -> String)? = nil,
        openSession: (@MainActor (HermesClient, String) async throws -> SessionResumeResult)? = nil,
        branchSession: (@MainActor (
            HermesClient,
            String,
            [SessionBranchMessage],
            String,
            String?
        ) async throws -> BranchResult)? = nil,
        setSessionTitle: (@MainActor (HermesClient, String, String) async throws -> Void)? = nil,
        refreshContext: (@MainActor (HermesClient, String) async -> Void)? = nil,
        sendPrompt: (@MainActor (HermesClient, String, String) async throws -> Void)? = nil,
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
        loadProfiles: (@MainActor () async -> Void)? = nil,
        loadBusyInputMode: (@MainActor (HermesClient) async -> Void)? = nil,
        loadProfileDisplayPreferences: (@MainActor () async -> Void)? = nil,
        loadSlashCommands: (@MainActor () async -> Void)? = nil
    ) {
        self.connectClient = connectClient
        self.loadCatalog = loadCatalog
        self.mintTicket = mintTicket
        self.openSession = openSession
        self.branchSession = branchSession
        self.setSessionTitle = setSessionTitle
        self.refreshContext = refreshContext
        self.sendPrompt = sendPrompt
        self.steer = steer
        self.redirect = redirect
        self.interrupt = interrupt
        self.executeSlash = executeSlash
        self.dispatchCommand = dispatchCommand
        self.setBusyInputMode = setBusyInputMode
        self.loadProfiles = loadProfiles
        self.loadBusyInputMode = loadBusyInputMode
        self.loadProfileDisplayPreferences = loadProfileDisplayPreferences
        self.loadSlashCommands = loadSlashCommands
    }

    static let live = ChatResumeLifecycleOperations()
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
    @Published private(set) var isChatRefreshing = false
    @Published private(set) var chatResumeBehavior: ChatResumeBehavior = .continueWhereLeftOff
    @Published private(set) var chatResumeRestorationRequest: ChatResumeRestorationRequest?
    @Published private(set) var chatViewportTransitionGeneration: UInt64 = 0
    /// Keeps the current transcript visible while a notification destination is
    /// being prepared, so the chat never appears to jump to an empty canvas.
    @Published private(set) var isOpeningNotificationSession = false
    @Published private(set) var isBranchingChat = false
    @Published private(set) var turnState: TurnState = .idle
    @Published private(set) var busyInputMode: BusyInputMode = .steer
    @Published private(set) var displayPreferences = ProfileDisplayPreferences()
    @Published var streamingText = ""
    /// An explicit user-send request lets ChatView scroll after SwiftUI has
    /// inserted the outgoing bubble, even if the user previously browsed up.
    @Published private(set) var chatScrollRequest = 0

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
            } else if !streamingBuffer.isEmpty {
                lastStreamingPublishBurst = max(
                    streamingBuffer.count - streamingText.count,
                    0
                )
                lastStreamingPublishDate = Date()
                streamingText = streamingBuffer
            }
        }
    }
    @Published var showModelPicker = false
    @Published var showContextSheet = false
    @Published var showWorkspaceSheet = false
    @Published var showGatewaySheet = false
    @Published var showAgentsSheet = false
    @Published var showVoiceSheet = false
    @Published var errorMessage: String?
    @Published var showLogin = true
    @Published private(set) var composerPrefillText = ""
    @Published private(set) var composerPrefillToken = UUID()

    // MARK: - Capabilities

    @Published var slashCommands: [SlashCommand] = AppState.builtInSlashCommands
    @Published var skills: [CapabilitySkill] = []
    @Published var toolsets: [CapabilityToolset] = []
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
        var bufferedEvents: [StreamEvent] = []

        init(
            token: UUID,
            requestedSessionId: String,
            automaticSyncOperationID: UUID? = nil,
            acceptedSessionIDs: Set<String> = [],
            acceptsAnySession: Bool = false,
            bufferedEvents: [StreamEvent] = []
        ) {
            self.token = token
            self.requestedSessionId = requestedSessionId
            self.automaticSyncOperationID = automaticSyncOperationID
            self.acceptedSessionIDs = acceptedSessionIDs
            self.acceptsAnySession = acceptsAnySession
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

    private var reconciliationToken = UUID()
    private var reconciliation: Reconciliation?
    private var activeClientEpoch = UUID()
    private var activeAssistantMessageId: String?
    private var activeReasoningMessageId: String?
    private var receivedReasoningForCurrentTurn = false
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
    private var scenePhaseTask: Task<Void, Never>?
    private var scenePhaseAttemptID: UUID?
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
    /// Timestamp of the last successful coalesced cache flush; used to
    /// enforce a maximum 5-second interval even during continuous streaming.
    private var lastPresentationCacheFlushDate: Date?
    /// Hermes currently starts its automatic title task against the launch
    /// profile's database. Keep a small, one-per-session recovery task for a
    /// secondary profile, then stand down as soon as Hermes has written one.
    private let sessionTitleRecoveryTracker = SessionTitleRecoveryTracker()
    private let sessionRenameOperationsOverride: SessionRenameOperation.Operations?
    private let sessionCatalogLoaderOverride: ((Bool) async throws -> [SessionSummary])?
    private var reconnectAttempts = 0
    private var connectedAt: Date?
    private var profileSessionCache: [String: [SessionSummary]] = [:]
    private var projectsRequestGeneration = 0
    private var loadedFullSessionHistory = Set<String>()
    private let sessionPresentationCache = SessionPresentationCache.shared

    /// The dashboard's persisted transcript is richer than `session.resume`:
    /// it retains database timestamps, complete tool-call inputs, and other
    /// presentation fields. The resume RPC remains authoritative for live turn
    /// state and any in-flight projection.
    private struct PersistedSessionTranscript {
        let resolvedSessionId: String?
        let messages: [ChatMessage]
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
        sessionPresentationCache.save(messages, profile: activeProfile, sessionIDs: ids)
    }

    /// Coalesces presentation-cache writes during streaming. Instead of
    /// serializing the entire message array to UserDefaults on every
    /// WebSocket frame (30+ times/sec), batch flushes at most once every
    /// 2 seconds (debounce), with a hard 5-second ceiling (max interval)
    /// so continuous streaming can never postpone a flush indefinitely.
    private func schedulePresentationCacheFlush(for sessionId: String) {
        presentationCacheFlushTask?.cancel()
        let now = Date()
        let sinceLastFlush = lastPresentationCacheFlushDate
            .map { now.timeIntervalSince($0) }
            ?? .infinity
        // If 5s already elapsed since the last successful write, flush
        // immediately rather than scheduling another debounce.
        let delay: Duration = sinceLastFlush >= 5 ? .zero : .seconds(2)
        presentationCacheFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
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

    // MARK: - Persistence

    private let defaults: UserDefaults
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
        reconnectScheduler: ChatResumeReconnectScheduler? = nil,
        reconnectExecutor: ChatResumeReconnectExecutor? = nil,
        chatResumeLifecycleOperations: ChatResumeLifecycleOperations = .live
    ) {
        self.defaults = defaults
        self.chatResumeCoordinator = chatResumeCoordinator
            ?? ChatResumeCoordinator(store: ChatResumeStore(defaults: defaults))
        self.recoverySequence = recoverySequence
        self.clearSessionPresentationCache = clearSessionPresentationCache
        sessionRenameOperationsOverride = sessionRenameOperations
        sessionCatalogLoaderOverride = sessionCatalogLoader
        self.reconnectScheduler = reconnectScheduler ?? scheduleChatResumeReconnectTask
        self.reconnectExecutor = reconnectExecutor
        self.chatResumeLifecycleOperations = chatResumeLifecycleOperations
        self.initialChatResumeServerIdentity = defaults
            .string(forKey: "conduit.chatResumeServerIdentity.v1")
            .flatMap(Self.normalizedChatResumeServerIdentity)
            ?? defaults.string(forKey: "conduit.dashboardURL")
                .flatMap(Self.normalizedChatResumeServerIdentity)
        chatResumeBehavior = self.chatResumeCoordinator.behavior
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
        restoreActiveSessionState(for: activeProfile)
        restorePinnedSessions(for: activeProfile)
        if shouldLoadSavedConnection {
            loadSavedConnection()
        }
    }

    func restoreActiveSessionState(for profile: String) {
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

    private func setActiveSessionState(id: String?, title: String? = nil) {
        activeSessionId = id
        if let persistedID = ChatSessionPersistenceIdentity.canonicalID(
            for: id,
            identity: activeChatScrollSessionIdentity,
            catalog: sessions + cronSessions
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
        guard !Task.isCancelled else { return nil }
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
        profileSessionCache.removeAll()
        loadedFullSessionHistory.removeAll()
        sessions = []
        cronSessions = []
        archivedSessions = []
        projects = []
        supportsProjects = false
        projectsLoading = false
        profiles = []
        activeSessionId = nil
        activeSessionTitle = "New conversation"
        messages = []
        clearStreamingText()
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
            sessions = []
            cronSessions = []
            archivedSessions = []
            slashCommands = Self.builtInSlashCommands
        }
        activeProfile = profile
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
        connection = nil
        client = nil
        dashboardTicketBridge = nil
        voiceConversationController.stop()
        showVoiceSheet = false
        voiceCapabilitySnapshot = .unavailable
        isVoiceEnabled = false
        voiceTranscriptionMode = .hermes
        appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
        showLogin = true
        sessions = []
        archivedSessions = []
        pinnedSessionIDs = []
        messages = []
        setActiveSessionState(id: nil, title: "New conversation")
        clearStreamingText()
        turnState = .idle
        defaults.removeObject(forKey: activeSessionTitlesByProfileKey)
        defaults.removeObject(forKey: pinnedSessionIDsByProfileKey)
        activeSessionTitlesByProfile = [:]
        pinnedSessionIDsByProfile = [:]
        defaults.removeObject(forKey: activeProfileKey)
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
            let ticket = try await NativeAuthClient(baseURL: credentials.baseURL, cloudflareAccess: KeychainHelper.loadCloudflareAccess(for: credentials.baseURL)).connect(
                username: credentials.username,
                password: credentials.password
            )
            await connect(with: HermesConnection(baseUrl: credentials.baseURL, ticket: ticket), profile: activeProfile)
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
        dashboardTicketBridge = nil
        projects = []
        supportsProjects = false
        projectsLoading = false
        KeychainHelper.clearConnection()
        turnState = .idle
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
        reconciliationToken = token
        reconciliation = Reconciliation(
            token: token,
            requestedSessionId: activeSessionId ?? "",
            acceptsAnySession: true,
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
        guard let sessionKey = activeChatScrollSessionIdentity.canonicalSessionKey,
              let request = chatResumeCoordinator.reconciliationSettled(sessionKey: sessionKey) else {
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
        let bufferedEvents = reconciliation?.token == token
            ? reconciliation?.bufferedEvents ?? []
            : []
        reconciliation = Reconciliation(
            token: token,
            requestedSessionId: sessionId,
            automaticSyncOperationID: automaticSyncOperationID,
            acceptedSessionIDs: acceptedSessionIDs.union([sessionId]),
            bufferedEvents: bufferedEvents
        )
        refreshActiveChatScrollSessionIdentity(isReconciling: true)
        turnState = .synchronizing
        let profile = activeProfile

        do {
            // Match Hermes Desktop: fetch the durable transcript and resume the
            // live runtime concurrently. `session.resume` intentionally uses a
            // compact projection which omits persisted timestamps, while the
            // HTTP endpoint reads the timestamped rows from state.db.
            let bridge = dashboardTicketBridge
            async let resumedSession = openChatResumeSession(
                sessionId,
                using: client
            )
            async let persistedTranscript = dashboardSessionTranscript(
                sessionId: sessionId,
                profile: profile,
                using: bridge
            )

            let result = try await resumedSession
            let transcript = await persistedTranscript
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
            let shouldUsePersistedTranscript = !result.snapshot.hasLiveProjection
                && transcriptMatches
                && (transcript.map { !$0.messages.isEmpty || result.messages.isEmpty } ?? false)
            let presentationResult: SessionResumeResult
            if let transcript, shouldUsePersistedTranscript {
                presentationResult = SessionResumeResult(
                    sessionId: result.sessionId,
                    messages: transcript.messages,
                    snapshot: result.snapshot
                )
            } else {
                presentationResult = result
            }

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

            let bufferedEvents = reconciliation?.token == token
                ? (reconciliation?.bufferedEvents ?? []).filter {
                    reconciliation?.accepts(sessionID(for: $0)) == true
                }
                : []
            bufferedEvents.forEach(applyStreamEvent)
            return settleReconciliationAndPublish(
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
                return false
            }
            turnState = .reconnecting
            errorMessage = "Failed to restore this conversation: \(error.localizedDescription)"
            settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
            return false
        }
    }

    private func openChatResumeSession(
        _ sessionID: String,
        using client: HermesClient
    ) async throws -> SessionResumeResult {
        if let openSession = chatResumeLifecycleOperations.openSession {
            return try await openSession(client, sessionID)
        }
        return try await client.openSession(sessionID)
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
                return
            }
            if let returnedProfile = created.profile,
               !profilesMatch(returnedProfile, profile) {
                turnState = .idle
                errorMessage = "Hermes created this conversation in \(profileDisplayName(returnedProfile)), not \(profileDisplayName(profile)). It was not opened."
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                await loadSessions(forceRefresh: true)
                return
            }
            let runtimeSessionID = created.sessionId.isEmpty ? (created.storedSessionId ?? "") : created.sessionId
            guard !runtimeSessionID.isEmpty else {
                turnState = .idle
                errorMessage = "Hermes created a conversation without a session ID."
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                return
            }

            // `session.create` already returns the active runtime session.
            // Some Hermes versions do not make its history-resume record
            // available immediately, so resuming here races the persistence
            // layer and leaves the composer stuck synchronizing.
            markChatViewportReplacement()
            setActiveSessionState(id: runtimeSessionID, title: "New conversation")
            messages = []
            noteChatViewportTranscriptReplacement()
            clearStreamingText()
            activeAssistantMessageId = nil
            activeReasoningMessageId = nil
            receivedReasoningForCurrentTurn = false
            turnState = .idle
            errorMessage = nil

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
        markChatViewportReplacement()
        setActiveSessionState(id: result.sessionId, title: "New conversation")
        updateActiveSessionTitle(
            for: result.sessionId,
            fallbackSessionId: reconciliation?.requestedSessionId
        )
        let restored = sessionPresentationCache.merge(
            result.messages,
            profile: activeProfile,
            sessionIDs: [result.sessionId, reconciliation?.requestedSessionId].compactMap { $0 },
            includePendingClarifications: result.snapshot.running == true,
            includePendingApprovals: result.snapshot.running == true
        )
        messages = mergeCachedReviews(into: restored, sessionId: result.sessionId)
        noteChatViewportTranscriptReplacement()
        cacheMessagePresentation(for: [result.sessionId])
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
        activeReasoningMessageId = nil
        receivedReasoningForCurrentTurn = false
        applyRuntime(result.snapshot)

        if TurnState.fromGatewayRunning(result.snapshot.running) == .unsupportedGateway {
            turnState = .unsupportedGateway
            errorMessage = "This Hermes gateway must support session turn state. Update Hermes to enable message, stop, and steer controls."
            return true
        }

        turnState = TurnState.fromGatewayRunning(result.snapshot.running)
        return true
    }

    /// `session.resume.inflight` is a cumulative projection on some gateways.
    /// When its already-persisted prefix is also present in the recovered
    /// transcript, rendering it as the live bubble repeats the last reply.
    /// Keep only the unpersisted suffix so the next delta continues naturally.
    static func unpersistedInflightAssistantText(
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

    private func applyRuntime(_ snapshot: SessionRuntimeSnapshot) {
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
        if let yolo = snapshot.yolo {
            runtime.yolo = yolo
        } else if let approvalsMode = snapshot.approvalsMode {
            runtime.yolo = approvalsMode.lowercased() == "off"
        }
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
        if !immediately { reconnectAttempts += 1 }

        reconnectTask = reconnectScheduler(delay) { [weak self] in
            guard let self else { return }
            self.reconnectTask = nil
            let purpose = self.recoverySequence.takeQueuedReconnectPurpose()
                ?? .preserveCurrent
            await self.executeReconnect(purpose: purpose)
        }
    }

    func reconnect() async {
        cancelChatResumeTransportRecovery()
        await executeReconnect(purpose: .preserveCurrent)
    }

    private func executeReconnect(purpose: ChatResumeSyncPurpose) async {
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
                        let ticket = try await NativeAuthClient(baseURL: credentials.baseURL, cloudflareAccess: KeychainHelper.loadCloudflareAccess(for: credentials.baseURL)).connect(
                            username: credentials.username,
                            password: credentials.password
                        )
                        guard refreshTransportContinuation() else { return }
                        // URLSession and WebKit have separate cookie stores.
                        // Reload the bridge so it receives the fresh session.
                        dashboardTicketBridge?.reload()
                        await connect(
                            with: HermesConnection(baseUrl: credentials.baseURL, ticket: ticket),
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
        switch phase {
        case .active:
            voiceConversationController.setForegroundActive(true)
            guard connection != nil else { return nil }
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
                    do {
                        try await client.healthCheck()
                        guard self.scenePhaseAttemptIsCurrent(sceneAttemptID),
                              self.automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
                            self.settleReconciliation(token)
                            return
                        }
                        await self.syncSession(
                            purpose: .automaticReturn,
                            using: token,
                            automaticWorkToken: automaticWorkToken
                        )
                    } catch {
                        guard self.scenePhaseAttemptIsCurrent(sceneAttemptID),
                              self.automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
                            self.settleReconciliation(token)
                            return
                        }
                        await self.reconnectForRetry(purpose: .automaticReturn)
                        self.settleReconciliation(token)
                    }
                } else {
                    guard self.scenePhaseAttemptIsCurrent(sceneAttemptID),
                          self.automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
                        self.settleReconciliation(token)
                        return
                    }
                    await self.reconnectForRetry(purpose: .automaticReturn)
                    self.settleReconciliation(token)
                }
            }
            scenePhaseTask = task
            return task

        case .background:
            voiceConversationController.setForegroundActive(false)
            showVoiceSheet = false
            // Flush any pending coalesced cache writes before the app
            // suspends — iOS may kill the process before the debounce fires.
            flushPendingPresentationCache()
            // A suspended socket may still look open. Invalidate incomplete
            // snapshots so foreground always obtains a fresh authoritative one.
            invalidateReconciliation()
            cancelScenePhaseAttempt()
            return nil

        case .inactive:
            chatResumeCoordinator.freezeViewport()
            voiceConversationController.setForegroundActive(false)
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
            requiredViewportTransitionGeneration.map {
                chatViewportTransitionIsCurrent(generation: $0)
            } ?? true else { return false }
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
            requiredViewportTransitionGeneration.map {
                chatViewportTransitionIsCurrent(generation: $0)
            } ?? true else { return false }
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
        profileSessionCache.removeValue(forKey: sessionKey)
        profileSessionCache.removeValue(forKey: cronKey)
        loadedFullSessionHistory.remove(sessionKey)
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
        clearStreamingText()
        activeAssistantMessageId = nil
        activeReasoningMessageId = nil
        receivedReasoningForCurrentTurn = false
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

    private func openSession(
        _ sessionId: String,
        reusing viewportTransitionGeneration: UInt64?
    ) async -> Bool {
        guard let client else { return false }
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
        clearStreamingText()
        activeAssistantMessageId = nil
        activeReasoningMessageId = nil
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
        let matchingSession = (sessions + cronSessions).first { session in
            session.id == requestedID || session.alternateIds.contains(requestedID)
        }
        let opened = await openSession(
            matchingSession?.id ?? requestedID,
            reusing: transitionGeneration
        )
        guard notificationOpenAttemptIsCurrent(
            id: notificationAttemptID,
            transitionGeneration: transitionGeneration
        ) else { return false }
        return opened
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

    func submitComposer(text: String, attachments: [Attachment] = []) async -> Bool {
        // The gateway is already idle while the final visual tail drains.
        // If the user acts first, commit that response synchronously so the
        // new outgoing message retains correct transcript order.
        finalizePendingStreamingCompletion()
        guard composerIsEnabled else { return false }

        // Slash command intercept — handle before normal message/steer logic
        if attachments.isEmpty && Self.parseSlashCommand(text) != nil {
            await executeSlashCommand(text)
            return true
        }

        if isBusy {
            guard attachments.isEmpty else {
                errorMessage = "Attachments can only be sent in a new message, after the current response finishes."
                return false
            }

            switch busyInputMode {
            case .steer:
                return await steer(text)
            case .interrupt:
                return await redirectOrInterruptAndSend(text)
            }
        }

        return await sendMessage(text, attachments: attachments)
    }

    func sendMessage(_ text: String, attachments: [Attachment] = []) async -> Bool {
        guard let client, let sessionId = activeSessionId else { return false }
        cancelChatResumeRestoration()

        let userMessage = ChatMessage(
            id: "local-\(Date().timeIntervalSince1970)",
            role: .user,
            content: text,
            rawContent: nil,
            timestamp: Self.localTimestamp(),
            author: nil,
            attachments: attachments.isEmpty ? nil : attachments
        )
        messages.append(userMessage)
        requestChatScrollToLatest()
        cacheMessagePresentation(for: [sessionId])
        clearStreamingText()
        turnState = .running

        for attachment in attachments {
            do {
                if attachment.kind == .image {
                    let base64 = await AttachmentHelper.toBase64(attachment)
                    guard !base64.isEmpty else { throw AttachmentError.unreadableFile(attachment.name) }
                    _ = try await client.attachImage(sessionId, base64: base64, filename: attachment.name)
                } else if attachment.name.lowercased().hasSuffix(".pdf") {
                    let base64 = await AttachmentHelper.toBase64(attachment)
                    guard !base64.isEmpty else { throw AttachmentError.unreadableFile(attachment.name) }
                    try await client.attachPdf(sessionId, base64: base64, filename: attachment.name)
                } else {
                    let dataUrl = await AttachmentHelper.toDataUrl(attachment)
                    guard !dataUrl.isEmpty else { throw AttachmentError.unreadableFile(attachment.name) }
                    try await client.attachFile(sessionId, dataUrl: dataUrl, name: attachment.name)
                }
            } catch {
                errorMessage = "Attachment failed: \(error.localizedDescription)"
                await syncSession()
                return false
            }
        }

        do {
            if let sendPrompt = chatResumeLifecycleOperations.sendPrompt {
                try await sendPrompt(client, sessionId, text)
            } else {
                try await client.sendPrompt(sessionId, text: text)
            }
            return true
        } catch {
            errorMessage = "Failed to send: \(error.localizedDescription)"
            await syncSession()
            return false
        }
    }

    func toggleYolo() async {
        _ = await setYoloMode(!runtime.yolo)
    }

    @discardableResult
    func setYoloMode(_ enabled: Bool) async -> Bool {
        guard let client, let sessionId = activeSessionId else { return false }
        do {
            try await client.setSessionYolo(sessionId, enabled: enabled)
            runtime.yolo = enabled
            return true
        } catch {
            errorMessage = "Unable to change YOLO mode: \(error.localizedDescription)"
            return false
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

    func executeSlashCommand(_ text: String) async {
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
                await toggleYolo()
                return
            }
        case "help":
            cancelChatResumeRestoration()
            appendSlashOutput(Self.formatSlashHelp())
            return
        default:
            break
        }

        // Server-side execution
        cancelChatResumeRestoration()
        do {
            let result = try await executeGatewaySlash(client: client, sessionID: sessionId, command: command.cleaned)
            await handleSlashResult(result, depth: 0, aliasArgument: command.argument)
        } catch {
            appendSlashOutput("⚠️ Command failed: \(error.localizedDescription)")
        }
    }

    private func executeGatewaySlash(
        client: HermesClient,
        sessionID: String,
        command: String
    ) async throws -> AnyCodable {
        do {
            if let executeSlash = chatResumeLifecycleOperations.executeSlash {
                return try await executeSlash(client, sessionID, command)
            }
            return try await client.executeSlash(sessionId: sessionID, command: command)
        } catch {
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

    private func handleSlashResult(_ result: AnyCodable, depth: Int, aliasArgument: String) async {
        guard depth < 4 else {
            appendSlashOutput("⚠️ Too many command aliases.")
            return
        }

        let obj = result.objectValue ?? [:]
        let type = obj["type"]?.stringValue ?? ""
        let output = obj["output"]?.stringValue ?? obj["message"]?.stringValue ?? obj["notice"]?.stringValue ?? ""

        switch type {
        case "exec", "plugin":
            // Command executed server-side; show any output
            if !output.isEmpty {
                appendSlashOutput(output)
            }
        case "send", "skill":
            // These send a prompt — extract the message and send it
            let message = obj["message"]?.stringValue ?? output
            if !message.isEmpty {
                await sendMessage(message, attachments: [])
            }
        case "prefill":
            if let notice = obj["notice"]?.stringValue, !notice.isEmpty {
                appendSlashOutput(notice)
            }
            let message = obj["message"]?.stringValue ?? output
            if !message.isEmpty {
                composerPrefillText = message
                composerPrefillToken = UUID()
            }
        case "alias":
            // Re-execute with the target command
            let target = obj["target"]?.stringValue ?? obj["command"]?.stringValue ?? obj["name"]?.stringValue ?? ""
            if !target.isEmpty {
                do {
                    guard let client, let sessionId = activeSessionId else { return }
                    let nestedCommand = aliasArgument.isEmpty ? target : "\(target) \(aliasArgument)"
                    let nested = try await executeGatewaySlash(client: client, sessionID: sessionId, command: nestedCommand)
                    await handleSlashResult(nested, depth: depth + 1, aliasArgument: aliasArgument)
                } catch {
                    appendSlashOutput("⚠️ Alias target failed: \(error.localizedDescription)")
                }
            } else if !output.isEmpty {
                appendSlashOutput(output)
            }
        default:
            // Unknown type — show output if present
            if !output.isEmpty {
                appendSlashOutput(output)
            }
        }
    }

    private func appendSlashOutput(_ text: String) {
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

    private func steer(_ text: String) async -> Bool {
        guard let client, let sessionId = activeSessionId else { return false }
        cancelChatResumeRestoration()
        do {
            if let steer = chatResumeLifecycleOperations.steer {
                try await steer(client, sessionId, text)
            } else {
                try await client.steer(sessionId, text: text)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            await syncSession()
            return false
        }
    }

    /// The modern Hermes path. It interrupts and rebuilds the live model
    /// request while retaining completed work; gateways can also acknowledge a
    /// correction as queued during their agent-build window. Older gateways
    /// retain the established `session.interrupt` then `prompt.submit` flow.
    private func redirectOrInterruptAndSend(_ text: String, retriedAfterResume: Bool = false) async -> Bool {
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
                appendLocalUserMessage(text)
                return true
            case .rejected:
                // A reject commonly means the turn won the race to completion.
                // Reconcile first so we submit directly when it is already idle
                // instead of surfacing a misleading interrupt failure.
                await syncSession()
                if turnState == .idle {
                    return await sendMessage(text, attachments: [])
                }
                guard turnState == .running else { return false }
                return await interruptAndSendLegacy(text)
            }
        } catch let error as RpcError {
            if isUnsupportedRedirect(error) {
                return await interruptAndSendLegacy(text)
            }

            // A runtime session can be rotated while the app was backgrounded.
            // Reconcile once, then retry against the recovered runtime id.
            if !retriedAfterResume, isSessionNotFound(error) {
                await syncSession()
                if turnState == .running {
                    return await redirectOrInterruptAndSend(text, retriedAfterResume: true)
                }
                if turnState == .idle {
                    return await sendMessage(text, attachments: [])
                }
                return false
            }

            errorMessage = "Could not redirect the active response: \(error.localizedDescription)"
            await syncSession()
            return false
        } catch {
            errorMessage = "Could not redirect the active response: \(error.localizedDescription)"
            await syncSession()
            return false
        }
    }

    private func interruptAndSendLegacy(_ text: String) async -> Bool {
        guard await interruptForReplacement() else { return false }
        return await sendMessage(text, attachments: [])
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

    private func interruptForReplacement() async -> Bool {
        guard let client, let sessionId = activeSessionId else { return false }
        cancelChatResumeRestoration()
        turnState = .synchronizing
        do {
            if let interrupt = chatResumeLifecycleOperations.interrupt {
                try await interrupt(client, sessionId)
            } else {
                try await client.cancel(sessionId)
            }
            return true
        } catch {
            errorMessage = "Could not interrupt the active response: \(error.localizedDescription)"
            await syncSession()
            return false
        }
    }

    func cancelCurrent() async {
        guard isBusy else { return }
        guard await interruptForReplacement() else { return }
        await syncSession()
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
            messages[updatedIndex].clarify?.error = "Hermes did not accept that answer."
            errorMessage = error.localizedDescription
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
                let shouldLoadHistory = forceRefresh || !loadedFullSessionHistory.contains(cacheKey)
                let scoped = try await dashboardSessions(
                    profile: profile,
                    loadFullHistory: shouldLoadHistory,
                    using: dashboardTicketBridge
                ).filter { sessionBelongsToProfile($0, profile: profile) }

                let cached = forceRefresh ? [] : (profileSessionCache[cacheKey] ?? []).filter {
                    sessionBelongsToProfile($0, profile: profile)
                }
                let merged = uniqueSessions(scoped + cached)
                // Fetch cron sessions separately -- the main query excludes them.
                let cronKey = "\(profile):cron"
                let cronSessions: [SessionSummary]
                if !forceRefresh, let cached = profileSessionCache[cronKey] {
                    cronSessions = cached.filter { sessionBelongsToProfile($0, profile: profile) }
                } else {
                    cronSessions = ((try? await dashboardCronSessions(profile: profile, using: dashboardTicketBridge)) ?? []).filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    profileSessionCache[cronKey] = cronSessions
                }
                let combined = uniqueSessions(merged + cronSessions)
                if !combined.isEmpty || shouldLoadHistory == false {
                    loadedFullSessionHistory.insert(cacheKey)
                    sessionCatalogLog.notice("Dashboard catalog for \(profile, privacy: .public): \(combined.count, privacy: .public) sessions; \(self.sourceSummary(combined), privacy: .public)")
                    profileSessionCache[cacheKey] = combined
                    return combined
                }
            } catch {
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

    /// Mirrors Hermes Desktop's `/api/sessions/{id}/messages` prefetch. The
    /// dashboard server returns `messages`; the API-server variant returns
    /// `data`, so accept both public Hermes response shapes.
    private func dashboardSessionTranscript(
        sessionId: String,
        profile: String,
        using bridge: DashboardTicketBridge?
    ) async -> PersistedSessionTranscript? {
        guard let bridge else { return nil }

        do {
            let response = try await bridge.requestJSON(
                path: sessionMessagesPath(sessionId: sessionId, profile: profile)
            )
            let rawMessages = ["messages", "data", "_array"]
                .compactMap { response[$0] as? [Any] }
                .first
            guard let rawMessages else { return nil }

            let resolvedSessionId = (response["session_id"] as? String)
                ?? (response["sessionId"] as? String)
            return PersistedSessionTranscript(
                resolvedSessionId: resolvedSessionId,
                messages: MessageNormalizer.normalizeMessages(rawMessages.map(AnyCodable.from))
            )
        } catch {
            // Older gateways can omit the endpoint. The compact resume path and
            // presentation cache remain a safe fallback in that case.
            sessionCatalogLog.debug("Persisted transcript unavailable for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func sessionMessagesPath(sessionId: String, profile: String) -> String {
        let encodedSessionId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        return dashboardPath("/api/sessions/\(encodedSessionId)/messages", profile: profile)
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
    ) async throws -> [SessionSummary] {
        let maximumPages = loadFullHistory ? 25 : 1
        var sessions: [SessionSummary] = []

        for page in 0..<maximumPages {
            let offset = page * 200
            let response = try await bridge.requestJSON(path: profileSessionsPath(profile, offset: offset))
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
        cacheMessagePresentation()
        cancelSecondaryProfileTitleRecovery()

        // Dismiss keyboard before switching profiles
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        let previousProfile = activeProfile
        let previousSessions = sessions
        let previousCronSessions = cronSessions
        let previousArchivedSessions = archivedSessions
        let previousProjects = projects
        let previousSupportsProjects = supportsProjects
        isProfileSwitching = true
        defer { isProfileSwitching = false }
        invalidateReconciliation()
        turnState = .synchronizing

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
            activeProfile = target
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
            activeProfile = previousProfile
            sessions = previousSessions
            cronSessions = previousCronSessions
            archivedSessions = previousArchivedSessions
            projects = previousProjects
            supportsProjects = previousSupportsProjects
            projectsLoading = false
            restoreActiveSessionState(for: previousProfile)
            restorePinnedSessions(for: previousProfile)
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
        guard let dashboardTicketBridge else { return }
        do {
            let response = try await dashboardTicketBridge.requestJSON(path: "/api/profiles")
            let values = response["profiles"] as? [Any] ?? []
            let names = values.compactMap { value -> String? in
                if let name = value as? String { return name }
                return (value as? [String: Any])?["name"] as? String
            }
            profiles = orderedProfiles(names + ["default"])
            defaults.set(profiles, forKey: knownProfilesKey)
        } catch {
            // Profile discovery is additive. A working chat must not be
            // replaced by an error just because an older dashboard lacks it.
            if profiles.isEmpty { profiles = orderedProfiles([activeProfile]) }
            defaults.set(profiles, forKey: knownProfilesKey)
        }
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
            messages[updatedIndex].approval?.error = "Hermes did not accept that decision."
            errorMessage = error.localizedDescription
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

    func loadCapabilities() async {
        let profile = activeProfile
        guard let dashboardTicketBridge else { return }
        async let skillsResult = dashboardTicketBridge.requestJSON(path: dashboardPath("/api/skills", profile: profile))
        async let toolsetsResult = dashboardTicketBridge.requestJSON(path: dashboardPath("/api/tools/toolsets", profile: profile))
        do {
            let (skillsResponse, toolsetsResponse) = try await (skillsResult, toolsetsResult)
            guard profile == activeProfile else { return }
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
        } catch {
            guard profile == activeProfile else { return }
            errorMessage = "Could not load capabilities: \(error.localizedDescription)"
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

    private func applyStreamEvent(_ event: StreamEvent) {
        let streamSessionId = sessionID(for: event)
        guard eventBelongsToActiveSession(streamSessionId) else { return }
        defer { schedulePresentationCacheFlush(for: streamSessionId) }

        switch event {
        case .messageStart:
            finalizePendingStreamingCompletion()
            activeReasoningMessageId = nil
            receivedReasoningForCurrentTurn = false
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
            clearStreamingText()
            activeReasoningMessageId = nil
            errorMessage = message
            setRunning(false)
            notifyVoiceAssistant(.failed(sessionID: streamSessionId, message: message))

        case .messageInterrupted:
            clearStreamingText()
            activeReasoningMessageId = nil
            setRunning(false)
            notifyVoiceAssistant(.interrupted(sessionID: streamSessionId))

        case .sessionBusy(_, let busy):
            setRunning(busy)

        case .sessionInfo(_, let snapshot):
            applyRuntime(snapshot)
            if let running = snapshot.running {
                setRunning(running)
            }

        case .sessionTitle:
            // Title pushes are catalog events and are handled before the
            // active-session stream gate in handleStreamEvent(_:).
            break

        case .toolStart(_, let name, let input):
            if name.lowercased() == "clarify" { break }
            activeReasoningMessageId = nil
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
            activeReasoningMessageId = nil
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
    /// one live card rather than creating duplicate thinking boxes.
    private func appendReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        if let id = activeReasoningMessageId,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].content = mergedReasoning(
                existing: messages[index].content,
                incoming: text
            )
            return
        }

        let id = "reasoning-\(Date().timeIntervalSince1970)"
        messages.append(ChatMessage(
            id: id,
            role: .reasoning,
            content: text,
            timestamp: Self.localTimestamp(),
            author: activeProfile
        ))
        activeReasoningMessageId = id
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
    /// immediately before their final answer.
    private func finalizeReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        if let id = activeReasoningMessageId,
           let index = messages.firstIndex(where: { $0.id == id }) {
            if text.hasPrefix(messages[index].content) {
                messages[index].content = text
            } else if messages[index].content != text {
                messages[index].content = text
            }
            return
        }
        appendReasoning(text)
    }

    func requestChatScrollToLatest() {
        chatScrollRequest &+= 1
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
        turnState = running ? .running : .idle
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

    func refreshVoiceCapabilities() async {
        let profile = activeProfile
        guard isConnected, let bridge = dashboardTicketBridge else {
            voiceCapabilitySnapshot = .unavailable
            isVoiceEnabled = false
            voiceConversationController.setGateway(nil)
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
    }

    @discardableResult
    func setVoiceEnabled(_ enabled: Bool) async -> Bool {
        guard isConnected else { return false }
        defaults.set(enabled, forKey: voiceEnabledPreferenceKey(profile: activeProfile))
        isVoiceEnabled = enabled
        refreshVoiceControllerGateway()
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
        return true
    }

    @discardableResult
    func openVoiceConversation(_ intent: PendingVoiceIntent) async -> Bool {
        guard isConnected else { return false }
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

        streamingCompletionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(drainMilliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.activeSessionId == sessionId else { return }
            self.finalizePendingStreamingCompletion()
        }
    }

    private func finalizePendingStreamingCompletion() {
        guard let pendingStreamingCompletion else { return }
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
        activeReasoningMessageId = nil
        receivedReasoningForCurrentTurn = false
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
