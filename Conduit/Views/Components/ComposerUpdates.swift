import Combine
import Foundation

/// Everything ComposerBar's body reads from AppState. The composer redraws
/// when one of these changes, not on every AppState publish: rebuilding it
/// was half of each publish's cost in an open chat.
///
/// A value the body newly reads from AppState must be added here, or the
/// composer shows it only when something else here changes.
struct ComposerInputs: Equatable {
    let activeProfile: String
    let activeSessionId: String?
    let activeDashboardID: UUID?
    let draftKeyOnScreen: ComposerDraftKey
    let scrollSessionIdentity: ChatScrollSessionIdentity
    let turnState: TurnState
    let isBusy: Bool
    let isEnabled: Bool
    let waitsForChat: Bool
    let takesText: Bool
    /// `composerAction(hasText:hasAttachments:)` for each draft shape.
    let actions: [ComposerAction]
    let placeholder: String
    let shortPlaceholder: String
    let notice: String?
    let errorMessage: String?
    let isConnected: Bool
    let hasConnection: Bool
    let lastConnectionFailure: ConnectionFailure?
    let showsConnectionRepair: Bool
    let isCompressing: Bool
    let isCheckingSend: Bool
    let chatTakeover: ChatTakeoverState?
    let activeChatTakeover: ChatTakeoverState?
    let hasRoomSurface: Bool
    let runtime: RuntimeState
    let isWritingReasoningEffort: Bool
    let activeAgents: Int
    let showModelPicker: Bool
    let showContextSheet: Bool
    let showAgentsSheet: Bool
    let colorScheme: ThemePreference
    let slashCommands: [SlashCommand]
    let mentionCandidates: [MentionAutocomplete.Candidate]
    let pendingScreenshot: Attachment?
    let canMoveScreenshotToNewChat: Bool
    let prefillToken: UUID
    let prefillText: String
    let prefillDraftKey: ComposerDraftKey?
    let quoteRequest: ComposerQuoteRequest?
    let dropRequest: AttachmentDropRequest?
    let predictiveRequest: PredictiveComposerRequest?
    let focusRequest: ComposerFocusRequest?
    let dictationRequest: ComposerDictationRequest?
    let restoreRequests: [ComposerRestoreRequest]
    let isVoiceInUse: Bool
    let showsVoiceButton: Bool
    let phoneVoiceUnavailableReason: String?
    let activeVoiceCallSessionID: String?
    let canResumeVoiceCall: Bool
    let isPreparingVoiceResume: Bool
    let chatVoiceButtonOverride: String?

    @MainActor
    init(_ appState: AppState) {
        activeProfile = appState.activeProfile
        activeSessionId = appState.activeSessionId
        activeDashboardID = appState.activeDashboardID
        draftKeyOnScreen = appState.composerDraftKeyOnScreen
        scrollSessionIdentity = appState.activeChatScrollSessionIdentity
        turnState = appState.turnState
        isBusy = appState.isBusy
        isEnabled = appState.composerIsEnabled
        waitsForChat = appState.composerWaitsForChat
        takesText = appState.composerTakesText
        actions = [(false, false), (true, false), (false, true), (true, true)].map {
            appState.composerAction(hasText: $0.0, hasAttachments: $0.1)
        }
        placeholder = appState.composerPlaceholder
        shortPlaceholder = appState.composerShortPlaceholder
        notice = appState.composerNotice
        errorMessage = appState.errorMessage
        isConnected = appState.isConnected
        hasConnection = appState.connection != nil
        lastConnectionFailure = appState.lastConnectionFailure
        showsConnectionRepair = appState.showsConnectionRepair
        isCompressing = appState.isCompressingActiveSession
        isCheckingSend = appState.composerSendIsChecking
        chatTakeover = appState.chatTakeover
        activeChatTakeover = appState.activeChatTakeover
        hasRoomSurface = appState.activeRoomSurface != nil
        runtime = appState.runtime
        isWritingReasoningEffort = appState.isWritingReasoningEffort
        activeAgents = appState.activeAgents
        showModelPicker = appState.showModelPicker
        showContextSheet = appState.showContextSheet
        showAgentsSheet = appState.showAgentsSheet
        colorScheme = appState.themePreference
        slashCommands = appState.slashCommands
        mentionCandidates = appState.composerMentionCandidates
        pendingScreenshot = appState.pendingScreenshot(forSession: appState.activeSessionId)
        canMoveScreenshotToNewChat = appState.canMoveComposerScreenshotToNewChat
        prefillToken = appState.composerPrefillToken
        prefillText = appState.composerPrefillText
        prefillDraftKey = appState.composerPrefillDraftKey
        quoteRequest = appState.composerQuoteRequest
        dropRequest = appState.composerDropRequest
        predictiveRequest = appState.predictiveComposerRequest
        focusRequest = appState.composerFocusRequest
        dictationRequest = appState.composerDictationRequest
        restoreRequests = appState.composerRestoreRequests
        isVoiceInUse = appState.isVoiceInUse
        showsVoiceButton = appState.showsComposerVoiceButton
        phoneVoiceUnavailableReason = appState.phoneVoiceUnavailableReason
        activeVoiceCallSessionID = appState.activeVoiceCallSessionID
        canResumeVoiceCall = appState.canResumeVoiceCall
        isPreparingVoiceResume = appState.isPreparingVoiceResume
        chatVoiceButtonOverride = appState.chatVoiceButtonOverride
    }
}

/// ComposerBar observes this instead of AppState. An AppState publish comes
/// before the change lands, so the check waits for the main queue's next
/// turn (still before the frame draws), once for any number of publishes.
@MainActor
final class ComposerUpdates: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    /// Held strongly: AppState never holds this, and the sink below holds
    /// it weakly.
    let appState: AppState
    /// What the composer shows now. Its effects (`onChange`, `task(id:)`)
    /// key on these too, so a value they wait on can't be left out.
    private(set) var inputs: ComposerInputs
    private var checkPending = false
    private var subscription: AnyCancellable?

    init(_ appState: AppState) {
        self.appState = appState
        inputs = ComposerInputs(appState)
        // AppState publishes on the main thread; a send from anywhere else
        // hops there first rather than touching this object off it.
        subscription = appState.objectWillChange.sink { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.scheduleCheck() }
            } else {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.scheduleCheck() }
                }
            }
        }
    }

    private func scheduleCheck() {
        guard !checkPending else { return }
        checkPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        checkPending = false
        let next = ComposerInputs(appState)
        guard next != inputs else { return }
        objectWillChange.send()
        inputs = next
    }
}
