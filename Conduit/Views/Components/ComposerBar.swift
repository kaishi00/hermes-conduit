//
//  ComposerBar.swift
//  Conduit
//
//  Composer controls are derived from AppState.turnState. A reconnecting or
//  synchronizing session is intentionally non-interactive until Hermes returns
//  an authoritative `running` value.
//

import AVFoundation
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Equatable by AppState identity, and mounted with `.equatable()`: its
/// StateObject would otherwise make every ChatView redraw rebuild it.
/// It redraws on its own for what it shows (ComposerUpdates), its state
/// and its environment.
struct ComposerBar: View, Equatable {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    /// Redraws only when something the composer shows changes, not on
    /// every AppState publish (ComposerUpdates.swift).
    @StateObject private var updates: ComposerUpdates
    private var appState: AppState { updates.appState }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The text view's own size, which a wide column grows
    /// (`ComposerPasteTextView.bodyFont`).
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.columnText) private var columnText
    @State private var text = ""
    @State private var composerTextHeight = ComposerPasteTextView.minimumHeight
    @State private var attachments: [Attachment] = []
    /// A whole reply attached with its Quote button (#385); it rides along
    /// with the next message.
    @State private var replyReference: ComposerReplyReference?
    @State private var showAttachmentMenu = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showDocumentPicker = false
    @State private var showCamera = false
    @State private var isFocused = false
    @State private var isShowingSlashSuggestions = false
    @State private var composerErrorMessage: String?
    /// NOT view state: the store is owned by AppState because it must
    /// outlive this view's unmount (the room surface swap destroys the
    /// subtree — a `@State` store here would die with the draft it holds).
    private var draftStore: ComposerDraftStore { appState.composerDraftStore }
    @State private var editorIdentity = UUID()
    /// Generation of intentional composer text replacements. Every program
    /// path that replaces the composer content routes through
    /// `replaceComposerText(_:)` and advances this, so the UIKit editor
    /// bridge applies the change exactly once — and, crucially, so ordinary
    /// SwiftUI invalidations (streaming, reasoning, busy state) arrive with
    /// an UNCHANGED revision and can never rewrite the editor or move the
    /// cursor mid-typing.
    @State private var composerRevision: UInt64 = 0
    /// The latest replacement puts the cursor after the text.
    @State private var composerCursorAtEnd = false
    @State private var loadedDraftKey: ComposerDraftKey?
    /// The store's clear count when the draft was loaded: a sign-out or a
    /// server switch since then cleared the store on purpose.
    @State private var loadedDraftClearCount: UInt64 = 0
    @State private var photoImportContext: AsyncAttachmentContext?
    @State private var photoImportGeneration: UInt64 = 0
    @State private var documentImportContext: AsyncAttachmentContext?
    @State private var cameraImportContext: AsyncAttachmentContext?
    @State private var attachmentGeneration: UInt64 = 0
    @State private var suppressNextTextChangeSuggestions = false
    /// Round 6: non-nil presents the Repair Connection wizard seeded from
    /// the failed connection.
    @State private var repairContext: ConnectionRepairContext?
    /// Local, device-only input preference. Until it is set, Return sends
    /// on a Mac and inserts a newline on iPhone and iPad
    /// (`ComposerReturnKey.sendsByDefault`).
    @AppStorage(ComposerReturnKey.preferenceKey) private var returnKeySends = ComposerReturnKey.sendsByDefault
    @AppStorage(AttachmentSizeLimit.preferenceKey) private var attachmentLimitMegabytes = AttachmentSizeLimit.defaultMegabytes
    /// The app's choice for the big button beside the chat (V2); the
    /// profile's own, if any, is in `updates.inputs`.
    @AppStorage(ChatVoiceButtonAction.key) private var appChatVoiceButton = ChatVoiceButtonAction.defaultValue.rawValue
    /// A voice message recorded from the chat's big button (V2).
    @ObservedObject private var voiceMessages = VoiceMessageRecorder.shared
    @Namespace private var glassNamespace
    /// The dictate button types into the draft (#290, #335).
    @StateObject private var dictation = ComposerDictationService()
    /// Hermes dictations whose words never came, kept for Retry.
    @ObservedObject private var dictationClips = DictationClipInbox.shared
    /// The draft as it was when dictation began; dictated text goes after it.
    @State private var dictationPrefix = ""
    /// The draft as dictation last wrote it, so the full editor, which
    /// reports every change the same way, can tell it from typing.
    @State private var dictatedDraft: String?
    /// The full-screen editor for long drafts (#335).
    @State private var isShowingFullEditor = false
    /// V2's conversation: rest as a slim bar until the composer is used.
    @Environment(\.v2ComposerRests) private var restsWhenIdle
    /// A Mac, or an iPad with the room: V2's composer keeps its controls
    /// showing, the big voice button beside it (#1483).
    @Environment(\.composerStaysExpanded) private var staysExpanded
    /// Kept expanded a moment after use ends, so a tap on a control (which
    /// can take focus from the field) doesn't collapse it under the finger.
    @State private var holdsExpanded = false
    @State private var collapseTask: Task<Void, Never>?

    /// AppState lives as long as the app (ConduitApp), so the StateObject
    /// made for the first one is the one every later init names.
    private let appStateID: ObjectIdentifier

    init(appState: AppState) {
        appStateID = ObjectIdentifier(appState)
        _updates = StateObject(wrappedValue: ComposerUpdates(appState))
    }

    nonisolated static func == (lhs: ComposerBar, rhs: ComposerBar) -> Bool {
        lhs.appStateID == rhs.appStateID
    }

    struct AsyncAttachmentContext: Equatable {
        let editorIdentity: UUID
        let draftKey: ComposerDraftKey
        let attachmentGeneration: UInt64
    }

    /// About three lines of body text: below this a draft is short enough
    /// to read in place, so the expand icon stays out of the way.
    static let fullEditorThreshold: CGFloat = 80

    static func showsFullEditorButton(measuredHeight: CGFloat, restingHeight: CGFloat = ComposerPasteTextView.minimumHeight) -> Bool {
        // At large Text Sizes, or in a wide column that grows its text, one
        // line alone can reach 80 pt; the icon still waits for more than a
        // line.
        measuredHeight >= max(fullEditorThreshold, restingHeight + 20)
    }

    /// The text field's height: what it measured, never under one line of
    /// its own font. The state starts at the system's line, and a wide Mac
    /// column's is taller, so its first frame doesn't jump once it measures.
    static func textFrameHeight(measured: CGFloat, resting: CGFloat) -> CGFloat {
        max(measured, resting)
    }

    /// One line of the text view's own font: what the composer goes back
    /// to after a send.
    private var restingTextHeight: CGFloat {
        ComposerPasteTextView.minimumHeight(for: ComposerPasteTextView.bodyFont(in: sizeCategory, from: columnText))
    }

    static func composerDraftKey(for sessionID: String?, profile: String) -> ComposerDraftKey {
        ComposerDraftKey(
            profile: profile,
            sessionID: sessionID ?? ComposerDraftKey.newConversationSessionID
        )
    }

    /// The draft a composer that's leaving it (going away, or handing off
    /// to another chat) keeps: the one in the field, unless the store was
    /// cleared since it was loaded.
    static func draftKeyToKeep(
        loaded: ComposerDraftKey?,
        loadedClearCount: UInt64,
        storeClearCount: UInt64
    ) -> ComposerDraftKey? {
        guard loadedClearCount == storeClearCount else { return nil }
        return loaded
    }

    /// A prefill goes in only over the draft it was made for, or the same
    /// chat under its other id.
    static func shouldApplyPrefill(
        for target: ComposerDraftKey?,
        loaded: ComposerDraftKey?,
        identity: ChatScrollSessionIdentity
    ) -> Bool {
        guard let target, let loaded else { return false }
        return draftKeysAreEquivalent(target, loaded, identity: identity)
    }

    static func draftKeysAreEquivalent(
        _ lhs: ComposerDraftKey,
        _ rhs: ComposerDraftKey,
        identity: ChatScrollSessionIdentity
    ) -> Bool {
        guard lhs.profile == rhs.profile else { return false }
        if lhs == rhs { return true }
        guard !lhs.isNewConversation, !rhs.isNewConversation else { return false }
        return identity.areEquivalent(lhs.sessionID, rhs.sessionID)
    }

    static func shouldAcceptAsyncAttachmentCompletion(
        startedIn origin: AsyncAttachmentContext,
        currentEditorIdentity: UUID,
        currentDraftKey: ComposerDraftKey,
        currentAttachmentGeneration: UInt64
    ) -> Bool {
        origin.editorIdentity == currentEditorIdentity
            && origin.draftKey == currentDraftKey
            && origin.attachmentGeneration == currentAttachmentGeneration
    }

    static func photoImportContext(
        editorIdentity: UUID,
        draftKey: ComposerDraftKey,
        attachmentGeneration: UInt64
    ) -> AsyncAttachmentContext {
        AsyncAttachmentContext(
            editorIdentity: editorIdentity,
            draftKey: draftKey,
            attachmentGeneration: attachmentGeneration
        )
    }

    static func shouldAcceptPhotoPickerCompletion(
        openedIn origin: AsyncAttachmentContext?,
        currentEditorIdentity: UUID,
        currentDraftKey: ComposerDraftKey,
        currentAttachmentGeneration: UInt64
    ) -> Bool {
        guard let origin else { return false }
        return shouldAcceptAsyncAttachmentCompletion(
            startedIn: origin,
            currentEditorIdentity: currentEditorIdentity,
            currentDraftKey: currentDraftKey,
            currentAttachmentGeneration: currentAttachmentGeneration
        )
    }

    static func shouldClearPhotoImportContext(
        completingGeneration: UInt64,
        completingContext: AsyncAttachmentContext,
        currentGeneration: UInt64,
        currentContext: AsyncAttachmentContext?
    ) -> Bool {
        completingGeneration == currentGeneration && completingContext == currentContext
    }

    static func shouldShowSlashSuggestions(
        for text: String,
        isProgrammaticDraftRestore: Bool
    ) -> Bool {
        guard !isProgrammaticDraftRestore else { return false }
        return slashPrefix(in: text) != nil || slashArgumentQuery(in: text) != nil
    }

    private static func slashPrefix(in text: String) -> String? {
        let trimmed = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        guard trimmed.hasPrefix("/") else { return nil }
        let prefix = String(trimmed.dropFirst())
        guard !prefix.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return prefix.lowercased()
    }

    /// `/fast ul` → ("fast", "ul"): the command typed and the first word of
    /// its argument so far, while that word is the last thing typed. Hermes'
    /// subcommands for the command complete it.
    static func slashArgumentQuery(in text: String) -> (command: String, partial: String)? {
        let trimmed = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        guard trimmed.hasPrefix("/"), !trimmed.contains(where: \.isNewline) else { return nil }
        let body = trimmed.drop(while: { $0 == "/" })
        guard let space = body.firstIndex(of: " ") else { return nil }
        let command = body[..<space]
        let partial = body[space...].drop(while: { $0 == " " })
        guard !command.isEmpty, !partial.contains(" ") else { return nil }
        return (command.lowercased(), partial.lowercased())
    }

    /// Hermes' subcommands for the command being typed that start with what
    /// is typed so far, as suggestion rows whose name is `command sub`.
    static func slashArgumentSuggestions(
        for text: String,
        commands: [SlashCommand],
        subcommands: [String: [String]]
    ) -> [SlashCommand] {
        guard let query = slashArgumentQuery(in: text),
              let command = commands.first(where: { $0.name == query.command || $0.aliases.contains(query.command) }),
              let subs = subcommands[command.name] else { return [] }
        return subs
            .filter { $0.lowercased().hasPrefix(query.partial) && $0.lowercased() != query.partial }
            .map { SlashCommand(name: "\(query.command) \($0)", description: "") }
    }

    static func pastedImageAttachmentMetadata(for typeIdentifier: String) -> (name: String, mimeType: String) {
        guard let type = UTType(typeIdentifier),
              type.conforms(to: .image),
              let mimeType = type.preferredMIMEType,
              let filenameExtension = type.preferredFilenameExtension,
              !mimeType.contains("/*") else {
            return ("pasted-image.png", "image/png")
        }
        return ("pasted-image.\(filenameExtension)", mimeType)
    }

    static func pastedImageErrorMessage(_ message: String) -> String {
        AppLocalization.string("Could not paste image: \(message)")
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The only sanctioned way to replace composer content programmatically.
    /// Advances the editor's programmatic revision alongside the text so the
    /// change is applied to the UIKit editor exactly once, and so the bridge
    /// can keep these replacements from ever surfacing as user input — the
    /// user-edit ownership signal lives in that bridge's
    /// `textViewDidChange`, guarded by the same machinery.
    private func replaceComposerText(_ newValue: String, cursorAtEnd: Bool = false) {
        text = newValue
        composerCursorAtEnd = cursorAtEnd
        composerRevision &+= 1
    }

    /// Adds `@tag ` to the draft from the + menu and puts the cursor after it.
    private func mention(_ candidate: MentionAutocomplete.Candidate) {
        Haptics.selection()
        replaceComposerText(MentionAutocomplete.inserting(text, with: candidate), cursorAtEnd: true)
        Task { @MainActor in
            isFocused = true
        }
    }

    /// "New Chat" beside the screenshot: what was typed goes with it, so
    /// none of it is left behind in this chat's draft.
    private func moveScreenshotToNewChat() {
        let carried = text
        replaceComposerText("")
        Task { await appState.moveComposerScreenshotToNewChat(carrying: carried) }
    }

    /// Returns the slash prefix being typed, or nil if the cursor has moved
    /// beyond the command name. Leading whitespace is accepted on purpose.
    private var slashPrefix: String? {
        Self.slashPrefix(in: text)
    }

    private var filteredSlashCommands: [SlashCommand] {
        guard let prefix = slashPrefix else {
            return Self.slashArgumentSuggestions(
                for: text,
                commands: appState.slashCommands,
                subcommands: appState.slashSubcommands
            )
        }
        if prefix.isEmpty {
            return appState.slashCommands
        }
        return appState.slashCommands.filter { cmd in
            cmd.name.lowercased().hasPrefix(prefix) ||
            cmd.aliases.contains(where: { $0.lowercased().hasPrefix(prefix) })
        }
    }

    /// Roster bots matching a trailing `@query`, while the editor has focus.
    private var mentionCandidates: [MentionAutocomplete.Candidate] {
        guard isFocused, let query = MentionAutocomplete.activeQuery(in: text) else { return [] }
        return MentionAutocomplete.filter(appState.composerMentionCandidates, query: query)
    }

    private var action: ComposerAction {
        // A slash command runs on Hermes, so it waits for the chat itself
        // rather than being sent later.
        if appState.composerWaitsForChat, Self.slashPrefix(in: text) != nil { return .unavailable }
        // A waiting screenshot rides on the next new turn only, so while
        // Hermes replies it doesn't turn the typed message into a Queue.
        let screenshotCounts = pendingScreenshot != nil && !appState.turnState.isRunning
        return appState.composerAction(hasText: hasText, hasAttachments: !attachments.isEmpty || screenshotCounts)
    }

    /// A screenshot from Ask Hermes About Screen waiting on this chat. It
    /// is AppState's, not the draft's, so a spoken question can carry it.
    private var pendingScreenshot: Attachment? {
        appState.pendingScreenshot(forSession: appState.activeSessionId)
    }

    /// The chat the composer types into: a saved copy's or a New Chat's
    /// while one is on screen (AppState+PendingSend.swift).
    private var activeDraftKey: ComposerDraftKey {
        appState.composerDraftKeyOnScreen
    }

    private var stopOnly: Bool {
        action == .stop
    }

    private var actionSymbol: String {
        switch action {
        case .stop: return "stop.fill"
        case .steer: return BusyInputMode.steer.symbol
        case .interrupt: return BusyInputMode.interrupt.symbol
        case .queue: return BusyInputMode.queue.symbol
        case .send: return "arrow.up"
        case .unavailable: return showsEmptyDraftSend ? "arrow.up" : "lock"
        }
    }

    /// Beside the big voice button, an empty draft in a chat that takes
    /// messages (not an offline copy or a chat still being made) shows Send dimmed, not the lock of a composer that can't
    /// send at all.
    private var showsEmptyDraftSend: Bool {
        Self.showsEmptyDraftSend(
            action: action,
            voiceButtonBeside: keepsVoiceButtonBeside,
            composerIsEnabled: appState.composerIsEnabled
        )
    }

    static func showsEmptyDraftSend(action: ComposerAction, voiceButtonBeside: Bool, composerIsEnabled: Bool) -> Bool {
        voiceButtonBeside && action == .unavailable && composerIsEnabled
    }

    private var actionTitle: String? {
        nil
    }

    private var actionTint: Color {
        switch action {
        case .stop: return .red
        case .steer, .queue: return .conduitAura
        case .interrupt: return .orange
        case .send: return .conduitAccent
        case .unavailable: return .secondary.opacity(0.48)
        }
    }

    private var actionSurfaceTint: Color {
        action == .unavailable ? Color.primary.opacity(0.025) : actionTint
    }

    /// Solid, so the chat scrolling under the composer never shows
    /// through what is being typed.
    private var composerFoundation: Color {
        colorScheme == .dark
            ? Color(red: 0.072, green: 0.080, blue: 0.106)
            : Color.white
    }

    private var composerStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.09)
    }

    /// The composer with its padding and the handlers for requests from
    /// AppState and the draft. Split from `body` so the type checker takes
    /// the modifier chain in two parts.
    private var composerWithRequestHandlers: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 16) {
                    composerContent
                }
            } else {
                composerContent
            }
        }
        // The voice button beside the resting bar centres on it.
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: V2RestingComposerHeightKey.self, value: rests ? proxy.size.height : 0)
            }
        }
        // Resting, or staying expanded, the voice button keeps its spot on
        // the trailing side.
        .padding(.leading, rests || keepsVoiceButtonBeside ? 16 : (restsWhenIdle ? 12 : 14))
        // A voice message recorded while the button is held keeps it too.
        .padding(.trailing, rests || keepsVoiceButtonBeside || voiceMessages.isHeld ? 84 : (restsWhenIdle ? 12 : 14))
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(restsWhenIdle ? ConduitMotion.ease(reduceMotion: reduceMotion) : nil, value: inUseOrHeld)
        .preference(key: V2ComposerExpandedKey.self, value: restsWhenIdle && !keepsVoiceButtonBeside && !rests)
        .preference(key: V2ComposerTypingKey.self, value: Self.hidesMinimisedCallBar(restsWhenIdle: restsWhenIdle, isFocused: isFocused))
        .onChange(of: composerInUse, initial: true) { _, inUse in
            guard restsWhenIdle else { return }
            composerUseChanged(inUse)
        }
        // One photo picker for both attach buttons (resting and expanded),
        // so it survives the composer expanding under it.
        .photosPicker(
            isPresented: $showAttachmentMenu,
            selection: $photoItems,
            maxSelectionCount: Self.photoPickerSelectionLimit,
            selectionBehavior: .ordered,
            matching: .any(of: [.images, .videos])
        )
        .conduitOutOfProcessAccentTint()
        .onChange(of: text) { _, newValue in
            let isProgrammaticDraftRestore = suppressNextTextChangeSuggestions
            suppressNextTextChangeSuggestions = false
            composerErrorMessage = nil
            if newValue.isEmpty {
                composerTextHeight = restingTextHeight
            }
            // Show suggestions when actively typing a slash command prefix
            withAnimation(ConduitMotion.response) {
                isShowingSlashSuggestions = Self.shouldShowSlashSuggestions(
                    for: newValue,
                    isProgrammaticDraftRestore: isProgrammaticDraftRestore
                )
            }
            // The suggestion row folds while typing and asks once it pauses.
            appState.predictiveDraftChanged(newValue)
        }
        .onChange(of: updates.inputs.prefillToken) { _, _ in
            applyPendingPrefill()
        }
        .onChange(of: updates.inputs.quoteRequest) { _, request in
            applyQuoteRequest(request)
        }
        .onChange(of: updates.inputs.dropRequest) { _, request in
            guard let request, appState.consumeComposerDropRequest(request.id) else { return }
            handleDroppedFiles(request.providers)
        }
        .onChange(of: updates.inputs.predictiveRequest) { _, request in
            applyPredictiveRequest(request)
        }
        .onChange(of: updates.inputs.focusRequest) { _, request in
            applyFocusRequest(request)
        }
        .onChange(of: updates.inputs.dictationRequest) { _, request in
            applyDictationRequest(request)
        }
        .onChange(of: updates.inputs.activeSessionId) { _, sessionID in
            // Another chat: a voice message for the last one is dropped.
            if voiceMessages.isActive, !voiceMessages.isSending, voiceMessages.sessionID != sessionID {
                voiceMessages.cancel()
            }
        }
        .onChange(of: voiceMessages.errorMessage) { _, message in
            // A recording that couldn't start or save has no bar to show
            // its reason in; the composer's own error line does.
            guard let message, !voiceMessages.isActive else { return }
            appState.errorMessage = message
            voiceMessages.errorMessage = nil
        }
        .onChange(of: photoItems) { _, _ in
            handlePhotoSelection()
        }
        .onChange(of: updates.inputs.chatTakeover?.readyToken) { _, _ in
            resendAfterChatTakeover()
        }
        .onChange(of: loadedDraftKey) { _, _ in
            // Back in a chat that was taken over while another was open:
            // its draft is loaded now, so send it.
            resendAfterChatTakeover()
        }
        .onChange(of: action) { _, _ in
            // The composer offers Send again (a turn finished, or sync
            // settled after the refusal).
            resendAfterChatTakeover()
        }
    }

    var body: some View {
        let _ = TranscriptPerf.note(.composerBarBody)
        composerWithRequestHandlers
        .onAppear {
            if loadedDraftKey == nil {
                loadDraft(for: activeDraftKey)
            }
            applyComposerRestoreRequests()
            applyPendingPrefill()
            // A screenshot chat can open before this composer is on screen.
            applyFocusRequest(appState.composerFocusRequest)
        }
        .onChange(of: updates.inputs.draftKeyOnScreen) { _, newKey in
            handoffComposer(to: newKey)
        }
        .onChange(of: updates.inputs.hasRoomSurface) { _, roomActive in
            // The room surface unmounts this composer's subtree. Persist the
            // typed draft BEFORE it goes, so returning to the session
            // restores exactly what the user had typed.
            if roomActive, let key = Self.draftKeyToKeep(
                loaded: loadedDraftKey,
                loadedClearCount: loadedDraftClearCount,
                storeClearCount: draftStore.clearCount
            ) {
                saveDraft(for: key)
            }
        }
        .onChange(of: updates.inputs.takesText) { _, takesText in
            // The sheet has no room for the composer's notices; the inline
            // composer explains why it is locked.
            if !takesText { isShowingFullEditor = false }
        }
        .onChange(of: updates.inputs.isEnabled) { _, enabled in
            if enabled { applyFocusRequest(appState.composerFocusRequest) }
        }
        .onChange(of: updates.inputs.restoreRequests) { _, _ in
            applyComposerRestoreRequests()
        }
        .onChange(of: updates.inputs.isVoiceInUse) { _, inUse in
            // Voice took the microphone: dictation steps aside.
            guard inUse else { return }
            dictation.cancel()
        }
        .onDisappear {
            dictation.cancel()
            if voiceMessages.isActive, !voiceMessages.isSending { voiceMessages.cancel() }
            collapseTask?.cancel()
            collapseTask = nil
            // Dependable second hook: whether this view leaves for a room
            // or the chat is closed (Back, another chat from the list), the
            // field lands in the app-lifetime store under the draft it
            // holds. A sign-out or server switch cleared the store on
            // purpose, so nothing goes back in after one.
            if let key = Self.draftKeyToKeep(
                loaded: loadedDraftKey,
                loadedClearCount: loadedDraftClearCount,
                storeClearCount: draftStore.clearCount
            ) {
                saveDraft(for: key)
            }
        }
        // A session resume can complete before the gateway has refreshed its
        // context accounting. Recheck once the active composer is on screen,
        // rather than making the user open the context sheet to populate it.
        .task(id: updates.inputs.activeSessionId) {
            let sessionID = appState.activeSessionId
            guard sessionID != nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, appState.activeSessionId == sessionID else { return }
            await appState.refreshContextUsage()
        }
        .fileImporter(
            isPresented: $showDocumentPicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true,
            onCompletion: { result in
                let origin = documentImportContext
                handleDocumentSelection(result, startedIn: origin)
                clearDocumentImportContextIfCurrent(origin)
            }
        )
        .fullScreenCover(isPresented: $showCamera, onDismiss: { cameraImportContext = nil }) {
            CameraCapture { image in
                handleCapturedPhoto(image, startedIn: cameraImportContext)
            }
            .ignoresSafeArea()
        }
    }

    private var composerContent: some View {
        VStack(spacing: 0) {
            if showsStateNotice {
                stateNotice
            }

            if let notice = appState.composerNotice {
                composerNoticeLine(notice)
            }

            UndeliveredDictationNotice(
                inbox: dictationClips,
                identity: dictationClipIdentity,
                delivering: appState.dictationClipsOnTheirWay,
                onRetry: retryDictationClip
            )

            if appState.isCompressingActiveSession {
                compressingNotice
            }

            if updates.inputs.isCheckingSend {
                sendingNotice
            }

            if let takeover = appState.activeChatTakeover {
                chatTakeoverNotice(takeover)
            }

            if let composerErrorMessage, !composerErrorMessage.isEmpty {
                pasteErrorNotice(composerErrorMessage)
            }

            if let replyReference {
                replyReferenceChip(replyReference)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }

            if !attachments.isEmpty || pendingScreenshot != nil {
                attachmentStrip
            }

            if isShowingSlashSuggestions && !filteredSlashCommands.isEmpty {
                SlashSuggestionsOverlay(
                    commands: filteredSlashCommands,
                    onSelected: { cmd in
                        replaceComposerText("/\(cmd.name) ")
                        isShowingSlashSuggestions = false
                    }
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if (!isShowingSlashSuggestions || filteredSlashCommands.isEmpty) && !mentionCandidates.isEmpty {
                MentionSuggestionList(candidates: mentionCandidates) { candidate in
                    replaceComposerText(MentionAutocomplete.completing(text, with: candidate))
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // A voice message being recorded or previewed takes the field's
            // place; the draft waits underneath.
            if showsVoiceMessage {
                VoiceMessageBar(recorder: voiceMessages) {
                    Task { await appState.sendRecordedVoiceMessage() }
                }
                    .transition(.opacity)
            } else {
                // The field spans the card; every control sits in the row
                // below it, so a long draft wraps across the full width (#335).
                // Resting (V2), attach and dictate sit beside the field and the
                // row waits.
                HStack(spacing: 2) {
                    if rests {
                        attachmentButton
                            .padding(.leading, 6)
                            .transition(.opacity)
                    }
                    composerField
                    // Resting, the plain mic stays in reach: dictating needs no
                    // tap on the field first. Starting it expands the composer,
                    // whose controls row has the same button.
                    if rests && showsRestingDictateButton {
                        // Spaced like the controls row, so its widened hit
                        // shape stays clear of the field and Stop.
                        dictateButton
                            .padding(.leading, 6)
                            .padding(.trailing, stopOnly ? 6 : 4)
                            .transition(.opacity)
                    }
                    if rests && stopOnly {
                        trailingSlot
                            .padding(.trailing, 4)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, rests ? 6 : 0)
                .padding(.top, rests ? 0 : 6)

                if !rests {
                    controlsRow
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(composerFoundation, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(composerStroke, lineWidth: 1)
        }
        .opacity(appState.turnState == .unsupportedGateway ? 0.7 : 1)
        .animation(ConduitMotion.transition, value: action)
        // Send and the mic give way to dictation's Stop, and come back.
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: dictationHoldsSendSlot)
        .preferredColorScheme(appState.themePreference.colorScheme)
        .sheet(item: $repairContext) { context in
            ConnectionRepairSetupSheet(context: context)
                .environmentObject(appState)
        }
    }

    private var composerField: some View {
        ZStack(alignment: .topLeading) {
            let currentEditorIdentity = editorIdentity
            if text.isEmpty {
                Text(appState.composerPlaceholder)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    // Gone with the first keystroke. The send button's
                    // spring would otherwise fade it out under the words
                    // being typed.
                    .transition(.identity)
            }
            ComposerPasteTextView(
                text: $text,
                isFocused: $isFocused,
                measuredHeight: $composerTextHeight,
                enabled: appState.composerTakesText,
                onPastedImage: { pastedImage in
                    handlePastedImage(pastedImage, editorIdentity: currentEditorIdentity)
                },
                onPastedImageError: { message in
                    handlePastedImageError(message, editorIdentity: currentEditorIdentity)
                },
                editorIdentity: editorIdentity,
                onDroppedFiles: { providers in
                    guard currentEditorIdentity == editorIdentity else { return }
                    handleDroppedFiles(providers)
                },
                onLongTextPaste: { pasted in
                    guard currentEditorIdentity == editorIdentity else { return false }
                    return attachLongPaste(pasted)
                },
                programmaticRevision: composerRevision,
                programmaticCursorAtEnd: composerCursorAtEnd,
                returnKeySends: returnKeySends,
                // May lag one render behind fast typing; the safe
                // failure mode is newline insertion, and
                // submitFromReturnKey() re-checks the live gate.
                canSubmitFromReturn: ComposerReturnKey.canSubmit(action: action) || dictationHoldsSendSlot,
                onSubmitFromReturn: { submitFromReturnKey() },
                onUserEdit: {
                    // Typed here: no later change matching dictation's last
                    // write is dictation's.
                    dictatedDraft = nil
                    appState.noteComposerUserEdit()
                    // Typing ends a dictation: its next result would rewrite
                    // the draft from where it began and drop the keystrokes.
                    // The words so far stay.
                    dictation.yieldToTyping()
                }
            )
            .id(editorIdentity)
            .padding(.leading, 5)
            // Room for the expand icon, so the text wraps before it.
            .padding(.trailing, showsFullEditorButton ? 40 : 5)
            .frame(height: Self.textFrameHeight(measured: composerTextHeight, resting: restingTextHeight))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            if showsFullEditorButton {
                Button {
                    Haptics.selection()
                    // A dictation carries on into the sheet, which has its
                    // own dictate button.
                    isFocused = false
                    isShowingSlashSuggestions = false
                    isShowingFullEditor = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!appState.composerTakesText)
                .accessibilityLabel(Text("Expand editor"))
                .accessibilityIdentifier("composer.expand-editor")
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : ConduitMotion.response, value: showsFullEditorButton)
        .sheet(isPresented: $isShowingFullEditor, onDismiss: {
            // The inline editor only takes programmatic changes, so hand it
            // what was written in the sheet, cursor at the end. An unchanged
            // draft keeps the cursor where it was.
            replaceComposerText(text, cursorAtEnd: true)
            // Typing a slash command in the sheet arms suggestions the sheet
            // never shows; they'd pop up over the unfocused inline field.
            isShowingSlashSuggestions = false
        }) {
            ComposerFullEditor(
                text: $text,
                placeholder: appState.composerPlaceholder,
                enabled: appState.composerTakesText,
                onUserEdit: { edited in
                    // Dictation writing the draft is not typing.
                    // Dictation's last write can be reported after it has
                    // finished, so this doesn't ask whether it is still running.
                    guard ComposerDictation.isTyping(edited, dictationWrote: dictatedDraft) else { return }
                    // Spent: the same text typed again by hand is typing.
                    dictatedDraft = nil
                    appState.noteComposerUserEdit()
                    // As inline: typing ends a dictation, keeping its words.
                    dictation.yieldToTyping()
                },
                onCollapse: { isShowingFullEditor = false },
                canSubmitFromReturn: ComposerReturnKey.canSubmit(action: action) || dictationHoldsSendSlot,
                onSubmitFromReturn: { submitFromReturnKey() },
                // Off while the composer is locked, as on the chat itself.
                onDropFiles: appState.composerIsEnabled ? { providers in handleDroppedFiles(providers) } : nil,
                onLongTextPaste: { pasted in attachLongPaste(pasted) },
                attachments: {
                    // A drop on the editor that left files out says so here,
                    // not only behind the sheet.
                    if let composerErrorMessage, !composerErrorMessage.isEmpty {
                        pasteErrorNotice(composerErrorMessage)
                    }
                    if let replyReference {
                        replyReferenceChip(replyReference)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }
                    if !attachments.isEmpty || pendingScreenshot != nil {
                        attachmentStrip
                    }
                },
                dictateButton: {
                    if !dictationHoldsSendSlot { dictateButton }
                },
                actionButton: {
                    if dictationHoldsSendSlot {
                        ComposerDictationStopButton(dictation: dictation, identifier: "composer.fullEditor.dictation.stop")
                    } else {
                        composerActionButton
                    }
                }
            )
            .preferredColorScheme(appState.themePreference.colorScheme)
        }
    }

    private var showsFullEditorButton: Bool {
        Self.showsFullEditorButton(measuredHeight: composerTextHeight, restingHeight: restingTextHeight)
    }

    /// Anything that needs the full composer: focus, a draft, an
    /// attachment, a reply, dictation, steering a running turn, a notice, or
    /// a control's sheet. A running turn's Stop alone fits the resting bar.
    private var composerInUse: Bool {
        let hasDraft = isFocused || hasText || !attachments.isEmpty || pendingScreenshot != nil
            || replyReference != nil || isShowingFullEditor
        let isDictating = dictation.isDictating || dictation.isStarting || dictation.isTranscribing
        let turnControl = Self.turnControlExpandsComposer(action: action, restsWhenIdle: restsWhenIdle)
        let hasNotice = showsStateNotice || appState.composerNotice != nil || appState.isCompressingActiveSession
            || updates.inputs.isCheckingSend
            || appState.activeChatTakeover != nil || composerErrorMessage != nil
            || !dictationClips.offered(for: dictationClipIdentity, delivering: appState.dictationClipsOnTheirWay).isEmpty
        let pickerUp = showAttachmentMenu || showDocumentPicker || showCamera
        let sheetUp = appState.showModelPicker || appState.showContextSheet || appState.showAgentsSheet
        return hasDraft || isDictating || turnControl || hasNotice || pickerUp || sheetUp || showsVoiceMessage
    }

    /// This chat's voice message, recording or ready to send.
    private var showsVoiceMessage: Bool {
        voiceMessages.isActive && voiceMessages.sessionID == updates.inputs.activeSessionId
    }

    /// Steer and interrupt live in the controls row. Stop does too in the
    /// classic layout, but V2 keeps it in the resting bar, so the big voice
    /// button beside it can start a call while Hermes replies (#762).
    static func turnControlExpandsComposer(action: ComposerAction, restsWhenIdle: Bool) -> Bool {
        switch action {
        case .steer, .interrupt, .queue: return true
        case .stop: return !restsWhenIdle
        case .send, .unavailable: return false
        }
    }

    /// The minimised call bar above a V2 composer hides only while someone
    /// types. A running turn, a notice or a draft left unfocused keeps it,
    /// so a call minimised in a chat can always be brought back (#695).
    static func hidesMinimisedCallBar(restsWhenIdle: Bool, isFocused: Bool) -> Bool {
        restsWhenIdle && isFocused
    }

    /// V2's resting composer: attach and the placeholder in a slim bar.
    private var rests: Bool {
        restsWhenIdle && !staysExpanded && !inUseOrHeld
    }

    /// What animates the bar open and closed. The layout rule changing (a
    /// chat's first measured width, a window resized) switches it at once.
    private var inUseOrHeld: Bool {
        composerInUse || holdsExpanded
    }

    /// V2's composer that stays expanded: the big voice button stays
    /// beside it, so its own voice and dictate buttons give way to it.
    private var keepsVoiceButtonBeside: Bool {
        restsWhenIdle && staysExpanded
    }

    private func composerUseChanged(_ inUse: Bool) {
        collapseTask?.cancel()
        if inUse {
            holdsExpanded = true
            return
        }
        guard holdsExpanded else { return }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            collapseTask = nil
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { holdsExpanded = false }
        }
    }

    /// Attach, model and session status on the left; dictate and the
    /// voice/send slot on the right, like the Codex composer (#335).
    /// The round controls match the context ring, leaving the model chip
    /// more width (#466).
    static let controlSize: CGFloat = 32
    /// Taps land a little outside each control. Half the row spacing, so
    /// neighbours never overlap.
    static var controlHitShape: some Shape { Rectangle().inset(by: -4) }

    /// "42%", for the context ring's large content viewer.
    private var contextPercentLabel: String {
        "\(Int(appState.runtime.contextPercent.rounded()))%"
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            attachmentButton

            modelButton

            if let callID = appState.activeVoiceCallSessionID, appState.canResumeVoiceCall {
                resumeVoiceCallButton(callID)
            }

            Button {
                Haptics.selection()
                appState.showContextSheet = true
            } label: {
                ContextRingView(percent: appState.runtime.contextPercent)
                    .frame(width: Self.controlSize, height: Self.controlSize)
                    .contentShape(Self.controlHitShape)
            }
            .buttonStyle(.plain)
            .accessibilityShowsLargeContentViewer {
                Label(
                    AppLocalization.string("Context \(contextPercentLabel)"),
                    systemImage: "chart.pie"
                )
            }
            .accessibilityLabel("Context usage, \(Int(appState.runtime.contextPercent.rounded())) percent")

            if appState.activeAgents > 0 {
                Button {
                    Haptics.selection()
                    appState.showAgentsSheet = true
                } label: {
                    Label("\(appState.activeAgents)", systemImage: "person.2")
                        .scaledFont(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.conduitAccent)
                        .frame(minWidth: Self.controlSize, minHeight: Self.controlSize)
                        .contentShape(Self.controlHitShape)
                }
                .buttonStyle(.plain)
                .accessibilityShowsLargeContentViewer {
                    Label(
                        AppLocalization.string("Delegate agents, \(Int(appState.activeAgents)) active"),
                        systemImage: "person.2"
                    )
                }
                .accessibilityLabel(AppLocalization.string("Delegate agents, \(Int(appState.activeAgents)) active"))
            }

            if Self.controlsRowShowsDictate(
                holdsSendSlot: dictationHoldsSendSlot,
                voiceButtonBeside: keepsVoiceButtonBeside,
                showsRestingDictateButton: showsRestingDictateButton
            ) {
                dictateButton
            }

            trailingSlot
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
        // Seven controls share one row of fixed 32 pt circles; past this
        // size the model chip shrinks to nothing and glyphs spill out.
        // The typed text above still follows the full Text Size.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// Why the composer is locked. While the chat on screen is on its way
    /// the composer takes a message anyway, so the line about syncing
    /// stays away; an error or a repair still shows.
    private var showsStateNotice: Bool {
        guard !appState.composerIsEnabled else { return false }
        guard appState.composerWaitsForChat else { return true }
        return !(appState.errorMessage ?? "").isEmpty || showsRepairConnection
    }

    private var showsRepairConnection: Bool {
        appState.showsConnectionRepair
    }

    @ViewBuilder
    private var stateNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !appState.composerWaitsForChat {
                HStack(spacing: 8) {
                if appState.turnState != .unsupportedGateway {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(appState.turnState == .unsupportedGateway
                     ? AppLocalization.string("Update this Hermes gateway to recover active turns safely.")
                     : AppLocalization.string("Synchronizing with Hermes before enabling chat controls"))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            if let error = appState.errorMessage, !error.isEmpty {
                Text(error)
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Entering repair hands recovery authority to the user; the
            // automatic retry loop stays stopped until the repair reconnects
            // or the user retries manually.
            if showsRepairConnection {
                Button {
                    Haptics.light()
                    repairContext = appState.beginConnectionRepair()
                } label: {
                    Label("Repair Connection", systemImage: "wrench.and.screwdriver")
                        .scaledFont(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(.conduitAccent)
                .accessibilityIdentifier("composer.repair-connection")
                .accessibilityLabel("Repair Connection")
                .accessibilityHint("Test and fix the failed connection, then reconnect")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// Offered when Hermes refused a send because Hermes Desktop or a
    /// terminal owns this chat (#304). Taking over waits for a reply running
    /// there to finish, then sends the draft again.
    private func chatTakeoverNotice(_ takeover: ChatTakeoverState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                switch takeover.phase {
                case .waiting:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Waiting to take this chat over"))
                case .failed, .heldHere, .unavailable:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .offered, .ready:
                    Image(systemName: takeover.owner == .otherBot ? "person.2" : "desktopcomputer")
                        .foregroundStyle(.secondary)
                }
                Text(Self.chatTakeoverMessage(takeover))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    Haptics.selection()
                    appState.dismissChatTakeover()
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(takeover.phase == .waiting
                    ? AppLocalization.string("Stop waiting")
                    : AppLocalization.string("Dismiss"))
            }

            switch takeover.phase {
            case .offered, .failed:
                Button {
                    Haptics.light()
                    appState.takeOverChat()
                } label: {
                    Label("Take over this chat", systemImage: "arrow.down.to.line")
                        .scaledFont(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(.conduitAccent)
                .accessibilityIdentifier("composer.take-over-chat")
                .accessibilityHint("Makes Conduit the app for this chat, then sends your message")
            case .waiting, .ready, .heldHere, .unavailable:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    static func chatTakeoverMessage(_ takeover: ChatTakeoverState) -> String {
        switch takeover.phase {
        case .offered:
            return takeover.openElsewhereMessage
        case .waiting:
            return takeover.takingOverMessage
        case .ready:
            return AppLocalization.string("This chat is yours now. Send your message again.")
        case .failed(let message), .unavailable(let message):
            return message
        case .heldHere:
            return ChatTakeoverState.heldHereMessage
        }
    }

    /// The chat is Conduit's now: send the refused draft again, exactly as
    /// the Send button would. When that can't happen here (another chat is
    /// open, the composer isn't offering Send, or its draft isn't the refused
    /// message, as after a refused voice turn), the ready notice stays and
    /// asks the user to send again.
    private func resendAfterChatTakeover() {
        guard let takeover = appState.activeChatTakeover, takeover.phase == .ready,
              case .send = action else { return }
        // The refused text carried the quoted reply, if one was attached.
        let outbound = ComposerReplyReference.outboundText(
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            hasAttachments: !attachments.isEmpty,
            replyingTo: replyReference
        )
        guard takeover.isRefusedMessage(outbound, hasAttachments: !attachments.isEmpty) else { return }
        appState.dismissChatTakeover()
        submit()
    }

    /// Small in-flight affordance for the dedicated `session.compress` RPC
    /// (manual compression is LLM-bound and can take minutes). Upstream
    /// exposes no incremental compression progress, so this is deliberately
    /// just a spinner and a label.
    private var compressingNotice: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(AppLocalization.string("Compressing…"))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// A sent message checking Hermes before it shows (#1401): the field
    /// is empty, so this says it's on its way.
    private var sendingNotice: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(AppLocalization.string("Sending…"))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("composer.sending")
    }

    private func pasteErrorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .scaledFont(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if message == Self.cameraAccessMessage {
                Button("Open Settings") {
                    composerErrorMessage = nil
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .scaledFont(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// Scrolls inside the composer card: clipped to the card's width so a
    /// long row never runs past its rounded edges or off-screen (#334).
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let pendingScreenshot {
                    ComposerAttachmentChip(
                        attachment: pendingScreenshot,
                        canRemove: appState.composerIsEnabled
                    ) {
                        appState.discardPendingScreenshot(forSession: appState.activeSessionId)
                    }
                    if appState.canMoveComposerScreenshotToNewChat {
                        ScreenshotNewChatButton(placement: .composer, action: moveScreenshotToNewChat)
                    }
                }
                ForEach(attachments) { attachment in
                    ComposerAttachmentChip(
                        attachment: attachment,
                        canRemove: appState.composerIsEnabled,
                        pastedText: appState.composerIsEnabled ? pastedTextActions(for: attachment.id) : nil
                    ) {
                        attachments.removeAll { $0.id == attachment.id }
                        Self.discardStagedFile(attachment)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity)
        .clipShape(Rectangle())
    }

    private var attachmentButton: some View {
        Menu {
            if CameraCapture.isAvailable {
                Button {
                    openCamera()
                } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
            Button {
                openPhotoLibraryPicker()
            } label: {
                Label("Photo Library", systemImage: "photo")
            }
            Button {
                documentImportContext = asyncAttachmentContext
                showDocumentPicker = true
            } label: {
                Label("Document", systemImage: "doc")
            }
            // V2 keeps the chat's folder in ⋯ › Artifacts (#1389); the
            // drawer shell has no Artifacts, so it stays here.
            if !V2ShellPreference.isOn {
                Button {
                    Haptics.selection()
                    appState.openWorkspace()
                } label: {
                    Label("Workspace", systemImage: "folder")
                }
            }
            // The other bots, for a tag without typing `@` (the same tag
            // the @ list inserts; the chat's own bot is left out).
            let bots = appState.composerMentionCandidates
            if !bots.isEmpty {
                Menu {
                    ForEach(bots) { candidate in
                        Button {
                            mention(candidate)
                        } label: {
                            // Two bots can share a title; the tag tells them apart.
                            Text(verbatim: candidate.title)
                            Text(verbatim: "@\(candidate.tag)")
                        }
                    }
                } label: {
                    Label(AppLocalization.string("Mention a Bot"), systemImage: "at")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(Self.controlHitShape)
        }
        .accessibilityLabel(Text("Attach"))
        // Open while Hermes replies: the files go as Queue (#1146).
        .disabled(!appState.composerIsEnabled)
        .conduitGlassControl(cornerRadius: Self.controlSize / 2, tint: .conduitAccent.opacity(0.08))
        .accessibilityShowsLargeContentViewer {
            Label("Attach", systemImage: "plus")
        }
    }

    /// What the single trailing slot of the input row holds.
    enum TrailingControl: Equatable {
        case voice
        case action
        /// A dictation is running: a wide Stop until its words are in (#1309).
        case dictation
    }

    /// Voice and send share one trailing slot, like Messages (#194): with
    /// nothing to send the slot offers voice (when it's enabled for the
    /// profile), and any sendable draft or live turn swaps it for the
    /// action button. The slot itself never disappears, so the row keeps
    /// its layout as the first character is typed. Dictation has its own
    /// button beside it (#335). While it dictates, the slot is a wide Stop
    /// in its place, and Send shows up once the words are in (#1309).
    static func trailingControl(
        action: ComposerAction,
        showsVoiceButton: Bool,
        holdsDictation: Bool = false
    ) -> TrailingControl {
        if holdsDictation { return .dictation }
        return action == .unavailable && showsVoiceButton ? .voice : .action
    }

    @ViewBuilder
    private var trailingSlot: some View {
        let control = Self.trailingControl(
            action: action,
            showsVoiceButton: appState.showsComposerVoiceButton && !keepsVoiceButtonBeside,
            holdsDictation: dictationHoldsSendSlot
        )
        if #available(iOS 26.0, *) {
            trailingControlButton(control)
                .glassEffectID("composer-action", in: glassNamespace)
        } else {
            trailingControlButton(control)
        }
    }

    @ViewBuilder
    private func trailingControlButton(_ control: TrailingControl) -> some View {
        switch control {
        case .voice: voiceButton
        case .action: composerActionButton
        case .dictation: ComposerDictationStopButton(dictation: dictation)
        }
    }

    /// Send's slot is dictation's Stop until the words are in (#1309), and
    /// the small mic beside it steps aside meanwhile.
    private var dictationHoldsSendSlot: Bool {
        ComposerDictation.holdsSendSlot(isDictating: dictation.isDictating, isStarting: dictation.isStarting)
    }

    /// With other ways to send, a menu whose tap is the action and whose
    /// touch and hold lists them. A context menu on the button lost the
    /// hold to the button's large content viewer, so a hold sent like a
    /// tap; the menu form has no large content viewer (as ChatTitleControl).
    @ViewBuilder
    private var composerActionButton: some View {
        let choices = sendChoices
        if choices.isEmpty {
            Button(action: performComposerAction) {
                composerActionFace
            }
            .disabled(action == .unavailable)
            .modifier(composerActionChrome)
            .accessibilityShowsLargeContentViewer {
                Label {
                    Text(actionTitle ?? accessibilityLabel)
                } icon: {
                    Image(systemName: actionSymbol)
                }
            }
            .accessibilityLabel(accessibilityLabel)
        } else {
            Menu {
                ForEach(choices) { choice in
                    Button {
                        submit(choice)
                    } label: {
                        Label(choice.title, systemImage: choice.symbol)
                    }
                }
            } label: {
                composerActionFace
            } primaryAction: {
                performComposerAction()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .modifier(composerActionChrome)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(AppLocalization.string("Touch and hold for other ways to send"))
            .accessibilityAction(named: Text(accessibilityLabel)) {
                performComposerAction()
            }
            .accessibilityActions {
                ForEach(choices) { choice in
                    Button(choice.title) { submit(choice) }
                }
            }
        }
    }

    private func performComposerAction() {
        if stopOnly {
            endInput(keepingFocus: isFocused || isShowingFullEditor)
            isShowingFullEditor = false
            Haptics.warning()
            Task { await appState.cancelCurrent() }
        } else {
            submit()
        }
    }

    private var composerActionFace: some View {
        HStack(spacing: 6) {
            Image(systemName: actionSymbol)
                .font(.system(size: stopOnly ? 12 : 14, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            if let actionTitle {
                Text(actionTitle)
                    .scaledFont(.caption.weight(.semibold))
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .foregroundStyle(action == .unavailable ? Color.secondary.opacity(0.48) : Color.white)
        .frame(minWidth: actionTitle == nil ? Self.controlSize : 86, minHeight: Self.controlSize)
        .padding(.horizontal, actionTitle == nil ? 0 : 4)
        .contentShape(Self.controlHitShape)
        .animation(ConduitMotion.transition, value: action)
    }

    private var composerActionChrome: ComposerActionChrome {
        ComposerActionChrome(tint: actionSurfaceTint, action: action)
    }

    /// What touch and hold on the action button offers: the busy modes the
    /// tap doesn't use and the side agents (ComposerSendChoice).
    private var sendChoices: [ComposerSendChoice] {
        guard !appState.composerWaitsForChat, pendingScreenshot == nil else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ComposerSendChoice.choices(
            for: action,
            hasAttachments: !attachments.isEmpty,
            isSlashCommand: AppState.parseSlashCommand(trimmed) != nil
        )
    }

    /// The model and effort, truncating first when the row is crowded.
    private var modelButton: some View {
        HStack(spacing: 2) {
            Button {
                openModelPicker()
            } label: {
                HStack(spacing: 5) {
                    Text(appState.runtime.model.isEmpty ? AppLocalization.string("Model") : appState.runtime.model)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if appState.runtime.yolo {
                        Image(systemName: "shield.slash.fill")
                            .scaledFont(.caption2.weight(.bold))
                            .foregroundStyle(Color.orange)
                    }
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The controls row is capped; touch and hold shows the model large.
            .accessibilityShowsLargeContentViewer {
                Text(appState.runtime.model.isEmpty ? AppLocalization.string("Model") : appState.runtime.model)
            }
            .accessibilityLabel(modelAccessibilityLabel)

            if !appState.runtime.model.isEmpty {
                // The model name gives way first, then the effort.
                reasoningMenu
                    .layoutPriority(1)
            }
        }
        .scaledFont(.footnote.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        // The rest of the chip's width still opens the sheet.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { openModelPicker() }
                .accessibilityHidden(true)
        }
    }

    private func openModelPicker() {
        Haptics.selection()
        appState.showModelPicker = true
    }

    /// One tap to change reasoning, the setting changed most, without opening
    /// the Model sheet. Hermes applies it to the live agent at once.
    private var reasoningMenu: some View {
        let current = ReasoningEffortLevel(runtimeEffort: appState.runtime.reasoningEffort)
        return Menu {
            Picker(
                selection: Binding<ReasoningEffortLevel?>(
                    get: { current },
                    set: { level in
                        guard let level, level != current, !appState.isWritingReasoningEffort else { return }
                        Haptics.selection()
                        Task { @MainActor in
                            // The state notice only shows while the composer
                            // is disabled, so report it in the composer's own
                            // notice.
                            if case .failed(let message) = await appState.setReasoningEffort(level.rawValue) {
                                composerErrorMessage = message
                                Haptics.error()
                                UIAccessibility.post(notification: .announcement, argument: message)
                            }
                        }
                    }
                )
            ) {
                ForEach(ReasoningEffortLevel.allCases) { level in
                    Text(level.title).tag(Optional(level))
                }
            } label: {
                Text("Reasoning")
            }
        } label: {
            HStack(spacing: 3) {
                Text(ReasoningEffortLevel.displayTitle(for: appState.runtime.reasoningEffort))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        // Picks land in order: the next waits for this write.
        .disabled(appState.isWritingReasoningEffort)
        .accessibilityShowsLargeContentViewer {
            Text(ReasoningEffortLevel.displayTitle(for: appState.runtime.reasoningEffort))
        }
        .accessibilityLabel(Text("Reasoning"))
        .accessibilityValue(Text(ReasoningEffortLevel.displayTitle(for: appState.runtime.reasoningEffort)))
    }

    /// Return-shortcut entry point. Invokes the exact same submission path
    /// as the composer action button, but only for typed-message actions
    /// (send/steer/interrupt): Return never acts as the stop-only control.
    /// While a dictation runs it does what the Stop in Send's place does
    /// instead, and sends nothing (#1309).
    /// The gate is re-checked here so the existing composer action state —
    /// not the text view — stays authoritative. Reports whether the press
    /// was handled (a message went out, a dictation was stopped, or the
    /// Stop is waiting for its words and the press does nothing), so a
    /// declined shortcut press falls back to the text view's default
    /// newline behavior instead of being swallowed.
    @discardableResult
    private func submitFromReturnKey() -> Bool {
        // Return stands for Send, which is dictation's Stop while it runs.
        if dictationHoldsSendSlot {
            dictation.tapSlot()
            return true
        }
        guard ComposerReturnKey.canSubmit(action: action) else { return false }
        submit()
        return true
    }

    /// `choice` is a long-press pick for this message only; nil keeps the
    /// action the button shows.
    private func submit(_ choice: ComposerSendChoice? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty || pendingScreenshot != nil else { return }
        if appState.composerWaitsForChat {
            queueUntilChatIsReady(trimmed)
            return
        }

        // Send waits out a dictation (#1309), but a predicted reply or a
        // resend can still go mid-dictation: the words so far go out, and
        // late results must not refill the emptied field.
        // The send haptic stands for both.
        // A Hermes dictation still transcribing keeps going instead: none
        // of its words were sent, and they land in the emptied field.
        if !dictation.isTranscribing {
            dictation.onFinish = nil
            dictation.cancel()
        }
        let wasTyping = isFocused || isShowingFullEditor
        isShowingFullEditor = false
        let submittedText = text
        let submittedAttachments = attachments
        // A slash command leaves the reply attached for the next message.
        let submittedReply = ComposerReplyReference.appliesToDraft(
            trimmed,
            hasAttachments: !submittedAttachments.isEmpty
        ) ? replyReference : nil
        let repliedText = ComposerReplyReference.outboundText(
            trimmed,
            hasAttachments: !submittedAttachments.isEmpty,
            replyingTo: submittedReply
        )
        // A side agent takes the message, quote and all, as its command.
        let outboundText = choice?.slashCommand.map { "/\($0) \(repliedText)" } ?? repliedText
        let submittedAction = choice.map { $0.busyInputMode?.composerAction ?? .send } ?? action
        let submittedDraftKey = loadedDraftKey ?? activeDraftKey
        let submittedDraftBucket = draftStore.submissionBucket(for: submittedDraftKey)
        let submittedClearCount = draftStore.clearCount
        let submittedDashboardID = appState.activeDashboardID
        let submittedChatTitle = appState.displayedChatTitle
        // The words may come back after the chat's runtime id has moved on:
        // they go back by its durable id, as a waiting message's do.
        let submittedRestoreKey = submittedDraftKey == activeDraftKey
            ? appState.durableComposerDraftKeyOnScreen : submittedDraftKey
        let submissionContext = appState.composerSubmissionContext()
        rotateAttachmentGeneration()
        collapseSubmittedDraft(clearingReply: submittedReply != nil, keepingFocus: wasTyping)

        switch submittedAction {
        case .send: Haptics.medium()
        case .steer, .queue: Haptics.light()
        case .interrupt: Haptics.warning()
        case .stop, .unavailable: break
        }

        Task {
            let didSubmit = await appState.submitComposer(
                text: outboundText,
                attachments: submittedAttachments,
                context: submissionContext,
                busyMode: choice?.busyInputMode
            )
            guard didSubmit else {
                restoreSubmittedDraftIfNeeded(
                    text: submittedText,
                    attachments: submittedAttachments,
                    replyReference: submittedReply,
                    for: submittedDraftKey,
                    restoringTo: submittedRestoreKey,
                    dashboardID: submittedDashboardID,
                    chatTitle: submittedChatTitle,
                    stoppedQuietly: appState.composerSubmissionStoppedQuietly(submissionContext),
                    clearCount: submittedClearCount
                )
                Haptics.error()
                return
            }
            draftStore.removeDraft(for: submittedDraftBucket)
            guard loadedDraftKey == submittedDraftKey else { return }
            // A prefill the reply asked for (a slash command's) goes in
            // here if its update hasn't put it in yet.
            applyPendingPrefill()
            isShowingSlashSuggestions = Self.shouldShowSlashSuggestions(for: text, isProgrammaticDraftRestore: false)
        }
    }

    /// The chat on screen is still on its way: the message waits in it as
    /// "Sends when connected" and goes once the chat is ready
    /// (AppState+PendingSend.swift). Text only.
    private func queueUntilChatIsReady(_ trimmed: String) {
        guard action == .send, attachments.isEmpty, pendingScreenshot == nil else { return }
        let submittedReply = ComposerReplyReference.appliesToDraft(trimmed, hasAttachments: false)
            ? replyReference : nil
        let submittedDraftKey = loadedDraftKey ?? activeDraftKey
        guard appState.sendWhenConnected(trimmed, replyReference: submittedReply) else {
            Haptics.error()
            return
        }
        if !dictation.isTranscribing {
            dictation.onFinish = nil
            dictation.cancel()
        }
        let wasTyping = isFocused || isShowingFullEditor
        isShowingFullEditor = false
        collapseSubmittedDraft(clearingReply: submittedReply != nil, keepingFocus: wasTyping)
        draftStore.removeDraft(for: submittedDraftKey)
        Haptics.medium()
    }

    /// Words AppState puts back: a waiting message that wasn't sent, or
    /// the one its Edit took back. Into the field when they're this draft's,
    /// otherwise into their chat's stored draft.
    private func applyComposerRestoreRequests() {
        guard let loadedDraftKey else { return }
        for request in appState.composerRestoreRequests where request.dashboardID == appState.activeDashboardID {
            if restoreRequest(request, belongsTo: loadedDraftKey) {
                let restored = ComposerDraft(text: text, attachments: attachments, replyReference: replyReference)
                    .restoring(request.draft)
                // Put back, not typed: a "/cmd" draft opens no suggestions.
                if text != restored.text { suppressNextTextChangeSuggestions = true }
                replaceComposerText(restored.text, cursorAtEnd: true)
                attachments = restored.attachments
                replyReference = restored.replyReference
                if request.focuses {
                    // After this update, as a focus request does.
                    Task { @MainActor in
                        isFocused = true
                    }
                }
            } else {
                let key = draftStore.keys.first { appState.composerDraftKeysAreSameChat($0, request.key) }
                    ?? request.key
                draftStore.save(draftStore.draft(for: key).restoring(request.draft), for: key)
            }
            appState.consumeComposerRestoreRequest(request.id)
        }
    }

    private func restoreRequest(_ request: ComposerRestoreRequest, belongsTo key: ComposerDraftKey) -> Bool {
        guard request.key.profile == key.profile else { return false }
        return appState.composerDraftKeysAreSameChat(request.key, key)
    }

    /// Why a waiting message came back, until the next edit or send.
    private func composerNoticeLine(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: appState.composerNoticeSystemImage)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(notice)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                appState.dismissComposerNotice()
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss notice"))
            .accessibilityValue(Text(notice))
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityIdentifier("composer.notice")
    }

    /// A saved live call: pick it up with a new live call that continues
    /// the same row, as the voice button there does too.
    private func resumeVoiceCallButton(_ callID: String) -> some View {
        Button {
            dismissComposer()
            Haptics.selection()
            Task { await appState.resumeVoiceCall(sessionID: callID) }
        } label: {
            Group {
                if appState.isPreparingVoiceResume {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "phone.arrow.up.right")
                }
            }
            .scaledFont(.subheadline.weight(.semibold))
            .foregroundStyle(Color.conduitAccent)
            .frame(width: Self.controlSize, height: Self.controlSize)
            .contentShape(Self.controlHitShape)
        }
        .buttonStyle(.plain)
        .disabled(appState.isPreparingVoiceResume || appState.voiceWaitsForRunningTurn)
        .conduitGlassControl(cornerRadius: Self.controlSize / 2, tint: .conduitAura.opacity(0.14), interactive: true)
        .accessibilityShowsLargeContentViewer {
            Label(AppLocalization.string("Resume call"), systemImage: "phone.arrow.up.right")
        }
        .accessibilityLabel(AppLocalization.string("Resume call"))
        .accessibilityHint(AppLocalization.string("Starts a new live call that continues this one"))
    }

    /// Opens Voice. A waveform, so it reads as "talk live", apart from the
    /// plain mic that dictates.
    private var voiceButton: some View {
        let canOpenVoice = canOpenVoiceFromComposer
        return Button {
            openVoiceFromComposer()
        } label: {
            Image(systemName: appState.canStartPhoneVoiceConversation ? "waveform" : "waveform.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(canOpenVoice ? Color.accentColor : Color.secondary)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(Self.controlHitShape)
        }
        .buttonStyle(.plain)
        .disabled(!canOpenVoice)
        .conduitGlassControl(
            cornerRadius: Self.controlSize / 2,
            tint: appState.canStartPhoneVoiceConversation ? .conduitAura.opacity(0.14) : .secondary.opacity(0.06),
            interactive: canOpenVoice
        )
        .accessibilityShowsLargeContentViewer {
            Label("Start voice conversation", systemImage: "waveform")
        }
        .accessibilityLabel(Text("Start voice conversation"))
        .accessibilityHint(appState.phoneVoiceUnavailableReason
            ?? AppLocalization.string("Starts a voice call; in a chat with messages, the call works in that chat"))
    }

    /// Tap to dictate into the draft, tap again to stop; the words are
    /// never sent on their own. Neutral glass, so the tinted voice/send
    /// slot stays the one "go" control.
    private var dictateButton: some View {
        let canDictate = canDictateFromComposer
        let isCapturing = dictation.isCapturing
        // A Hermes dictation still transcribing pulses too, and a tap
        // waits for its words.
        let isActive = isCapturing || dictation.isStarting || dictation.isTranscribing
        return Button {
            switch ComposerDictation.tap(
                isCapturing: dictation.isCapturing,
                isStarting: dictation.isStarting,
                canDictate: canDictate,
                isTranscribing: dictation.isTranscribing
            ) {
            case .start: beginDictation()
            case .stop: dictation.stop()
            // Tapped again before the microphone came up.
            case .cancelStart: dictation.cancel()
            case .nothing: break
            }
        } label: {
            Image(systemName: isCapturing ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isCapturing ? Color.red : (canDictate ? Color.primary : Color.secondary))
                // Pulses from the tap, so a start still waiting on
                // permission or the microphone shows it's in flight.
                .symbolEffect(.pulse, isActive: isActive && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(Self.controlHitShape)
        }
        .buttonStyle(.plain)
        .disabled(!canDictate && !isActive)
        .conduitGlassControl(
            cornerRadius: Self.controlSize / 2,
            tint: isCapturing ? .red.opacity(0.16) : .primary.opacity(0.025),
            interactive: canDictate || isActive
        )
        .accessibilityShowsLargeContentViewer {
            Label {
                dictateTitle(isCapturing: isCapturing)
            } icon: {
                Image(systemName: isCapturing ? "mic.fill" : "mic")
            }
        }
        .accessibilityLabel(dictateTitle(isCapturing: isCapturing))
        .accessibilityIdentifier("composer.dictate")
        .accessibilityHint(isCapturing
            ? AppLocalization.string("Stops dictating; the words stay in the message")
            : (dictation.isStarting || dictation.isTranscribing ? "" : (appState.isVoiceInUse
                ? AppLocalization.string("Dictation is unavailable while a voice conversation has the microphone")
                : AppLocalization.string("Types what you say into the message"))))
    }

    private func dictateTitle(isCapturing: Bool) -> Text {
        if isCapturing { return Text("Stop dictation") }
        if dictation.isStarting { return Text("Cancel dictation") }
        if dictation.isTranscribing { return Text("Transcribing") }
        return Text("Dictate")
    }

    private func openVoiceFromComposer() {
        dismissComposer()
        Haptics.selection()
        Task {
            _ = await appState.openVoiceConversation(
                PendingVoiceIntent(
                    profile: appState.activeProfile,
                    startsFreshConversation: false,
                    source: .composer
                )
            )
        }
    }

    private var canOpenVoiceFromComposer: Bool {
        appState.canStartPhoneVoiceConversation && !appState.voiceWaitsForRunningTurn && appState.composerIsEnabled
    }

    private var canDictateFromComposer: Bool {
        appState.composerIsEnabled && !appState.isVoiceInUse
    }

    private func beginDictation() {
        // Reserved first: it ends a dictation still settling, whose
        // callbacks must not be the new ones.
        guard let token = dictation.reserveStart() else { return }
        dictationPrefix = text
        dictatedDraft = nil
        Haptics.medium()
        dictation.onTranscript = { transcript in
            // Typed or replaced since dictation last wrote it: the sheet
            // reports typing only on its next update, which can trail this
            // result. End the dictation instead of writing over the change.
            let prefix: String
            if ComposerDictation.draftIsAsDictationLeftIt(
                text, prefix: dictationPrefix, lastWrite: dictatedDraft
            ) {
                prefix = dictationPrefix
            } else if dictation.isTranscribing {
                // Words that never reached the draft (a Hermes upload)
                // go after whatever it holds now, sent or typed.
                prefix = text
                dictationPrefix = text
            } else {
                dictation.cancel()
                return
            }
            let draft = ComposerDictation.draft(before: prefix, dictated: transcript)
            dictatedDraft = draft
            // The cursor follows the words, so the next dictation or typing
            // carries on after them.
            replaceComposerText(draft, cursorAtEnd: true)
        }
        dictation.onFinish = { _ in
            Haptics.light()
        }
        dictation.onFailure = { message in
            composerErrorMessage = message
        }
        Task {
            do {
                try await dictation.start(token: token, hermesGateway: { appState.makeVoiceGateway() })
            } catch {
                composerErrorMessage = UserFacingError.message(for: error)
            }
        }
    }

    /// Where this composer's dictations keep their recordings: none while
    /// it takes no text, so a locked composer offers nothing to retry.
    private var dictationClipIdentity: String? {
        appState.composerTakesText ? appState.dictationClipIdentity : nil
    }

    /// Retry on a dictation whose words never came: one more upload of
    /// its kept recording. The words go to the draft that was on screen
    /// when it was tapped, even if another chat opened meanwhile.
    private func retryDictationClip(_ clip: DictationClip) {
        guard let gateway = appState.makeVoiceGateway(), let dashboardID = appState.activeDashboardID else {
            composerErrorMessage = AppLocalization.string("Dictation with Hermes needs a connection to Hermes.")
            return
        }
        let key = appState.durableComposerDraftKeyOnScreen
        composerErrorMessage = nil
        Task {
            do {
                let words = try await dictationClips.retry(clip, transcribe: gateway.transcribe)
                guard !words.isEmpty else {
                    composerErrorMessage = AppLocalization.string("No speech was captured.")
                    return
                }
                appState.restoreRetriedDictation(words, clipID: clip.id, dashboardID: dashboardID, key: key)
            } catch is CancellationError {
                return
            } catch is DictationClipUnreadable {
                composerErrorMessage = AppLocalization.string("The recording couldn't be read. Try again in a moment.")
            } catch {
                composerErrorMessage = AppLocalization.string("Hermes couldn't transcribe that: \(UserFacingError.message(for: error))")
            }
        }
    }

    /// Collapse the draft in the same transaction that dismisses the keyboard.
    /// Waiting for the gateway RPC leaves the side controls aligned to the old
    /// multiline field while the keyboard's safe area is already animating.
    /// `keepingFocus`: the user was typing (in the field or the full
    /// editor), which on a Mac or with a hardware keyboard carries on.
    private func collapseSubmittedDraft(clearingReply: Bool, keepingFocus: Bool) {
        endInput(keepingFocus: keepingFocus)
        let updates = {
            replaceComposerText("")
            attachments = []
            if clearingReply { replyReference = nil }
            composerTextHeight = restingTextHeight
        }
        if reduceMotion {
            updates()
        } else {
            withAnimation(ConduitMotion.response) {
                updates()
            }
        }
    }

    private func restoreSubmittedDraftIfNeeded(
        text submittedText: String,
        attachments submittedAttachments: [Attachment],
        replyReference submittedReply: ComposerReplyReference?,
        for key: ComposerDraftKey,
        restoringTo durableKey: ComposerDraftKey,
        dashboardID: UUID?,
        chatTitle: String,
        stoppedQuietly: Bool,
        clearCount: UInt64
    ) {
        // A sign-out or server switch cleared the drafts while it was on
        // its way: the outgoing account's words don't come back.
        guard Self.draftKeyToKeep(loaded: key, loadedClearCount: clearCount, storeClearCount: draftStore.clearCount) != nil else {
            return
        }
        let failed = ComposerDraft(
            text: submittedText,
            attachments: submittedAttachments,
            replyReference: submittedReply
        )
        // AppState hands them to the composer on screen, which may not be
        // this one: leaving the chat mid-send replaces it, and words put in
        // this one's field then were lost (#1401). Words typed meanwhile
        // stay, below the message that didn't go.
        if let dashboardID {
            appState.returnFailedComposerSubmission(
                failed,
                key: durableKey,
                dashboardID: dashboardID,
                title: chatTitle,
                stoppedQuietly: stoppedQuietly
            )
            return
        }
        let restorationKey: ComposerDraftKey
        if Self.draftKeysAreEquivalent(
            key,
            activeDraftKey,
            identity: appState.activeChatScrollSessionIdentity
        ) {
            restorationKey = activeDraftKey
        } else {
            restorationKey = key
        }

        guard loadedDraftKey == restorationKey else {
            draftStore.restoreFailedSubmission(failed, for: restorationKey)
            return
        }
        let restored = ComposerDraft(text: text, attachments: attachments, replyReference: replyReference)
            .restoring(failed)
        // Put back, not typed: a failed "/cmd" opens no suggestions.
        if text != restored.text { suppressNextTextChangeSuggestions = true }
        replaceComposerText(restored.text, cursorAtEnd: true)
        attachments = restored.attachments
        replyReference = restored.replyReference
    }

    /// A screenshot chat opened with the keyboard: the field takes focus.
    private func applyFocusRequest(_ request: ComposerFocusRequest?) {
        // A locked composer keeps the request until it unlocks.
        guard let request, appState.composerIsEnabled else { return }
        appState.consumeComposerFocusRequest(request.id)
        // Left for another chat before it applied: dropped.
        guard request.sessionID == appState.activeSessionId else { return }
        // After this update: the new chat's draft load, which can land in
        // the same update, unfocuses the field.
        Task { @MainActor in
            isFocused = true
        }
    }

    /// The chat's big button asked to dictate: start, as the mic does.
    private func applyDictationRequest(_ request: ComposerDictationRequest?) {
        guard let request else { return }
        appState.consumeComposerDictationRequest(request.id)
        // Left for another chat before it applied: dropped.
        guard request.sessionID == appState.activeSessionId else { return }
        // Already dictating: the button's second tap does what the Stop in
        // Send's place does, a settle included (#1309).
        if dictationHoldsSendSlot {
            dictation.tapSlot()
            return
        }
        switch ComposerDictation.tap(
            isCapturing: dictation.isCapturing,
            isStarting: dictation.isStarting,
            canDictate: canDictateFromComposer,
            isTranscribing: dictation.isTranscribing
        ) {
        case .start: beginDictation()
        // Already dictating: the button's second tap stops it.
        case .stop: dictation.stop()
        case .cancelStart: dictation.cancel()
        case .nothing: break
        }
    }

    /// The resting bar's mic, unless the big button beside the composer
    /// already dictates.
    private var showsRestingDictateButton: Bool {
        Self.showsRestingDictateButton(
            chatVoiceButton: ChatVoiceButtonAction.resolved(
                profile: updates.inputs.chatVoiceButtonOverride,
                app: appChatVoiceButton
            )
        )
    }

    static func showsRestingDictateButton(chatVoiceButton: ChatVoiceButtonAction) -> Bool {
        chatVoiceButton != .dictation
    }

    /// The controls row's mic, unless dictation's Stop holds its slot, or
    /// the big button beside a composer that stays expanded dictates
    /// already, as beside the resting bar.
    static func controlsRowShowsDictate(holdsSendSlot: Bool, voiceButtonBeside: Bool, showsRestingDictateButton: Bool) -> Bool {
        !holdsSendSlot && (!voiceButtonBeside || showsRestingDictateButton)
    }

    /// A quote from the transcript (#385): selected text joins the draft as
    /// a `>` quote with the cursor below it; a reply's Quote button attaches
    /// the whole reply as the "Replying to…" chip. Either way the composer
    /// takes focus for the reply.
    /// A guess from the suggestion row: sent as if typed, put in to edit,
    /// or put after the draft it continues (Predictive.swift).
    private func applyPredictiveRequest(_ request: PredictiveComposerRequest?) {
        guard let request else { return }
        appState.consumePredictiveComposerRequest(request.id)
        // Left for another chat before it applied: dropped.
        guard appState.composerIsEnabled, request.sessionID == appState.activeSessionId,
              Self.shouldApplyPrefill(
                  for: request.draftKey, loaded: loadedDraftKey,
                  identity: appState.activeChatScrollSessionIdentity
              ) else { return }
        appState.noteComposerUserEdit()
        switch request.action {
        case .insert:
            // The draft moved on since the guess was offered.
            guard text == request.draft else { return }
            replaceComposerText(Predictive.inserting(request.text, into: text), cursorAtEnd: true)
            Task { @MainActor in isFocused = true }
        case .edit:
            replaceComposerText(request.text, cursorAtEnd: true)
            Task { @MainActor in isFocused = true }
        case .send:
            // Sent in place of the draft, through the same path as Send.
            replaceComposerText(request.text, cursorAtEnd: true)
            submit()
        }
    }

    private func applyQuoteRequest(_ request: ComposerQuoteRequest?) {
        guard let request else { return }
        appState.consumeComposerQuoteRequest(request.id)
        // The composer can lock in the same update that delivers the quote
        // (the connection dropped); a locked draft takes nothing.
        guard appState.composerIsEnabled else { return }
        // Quoting is composing: a pending automatic chat resume must not
        // switch away from the draft it just changed.
        appState.noteComposerUserEdit()
        let announcement: String
        switch request.content {
        case .text(let quote):
            // A running dictation would rewrite the draft from where it began.
            dictation.yieldToTyping()
            replaceComposerText(ChatQuote.inserting(quote, into: text), cursorAtEnd: true)
            isShowingSlashSuggestions = false
            announcement = AppLocalization.string("Quoted in your message")
        case .reply(let reference):
            withAnimation(reduceMotion ? nil : ConduitMotion.response) {
                replyReference = reference
            }
            announcement = AppLocalization.string("Replying to \(reference.authorName)")
        }
        Haptics.selection()
        isFocused = true
        // VoiceOver hears where the quote went, queued behind what it says
        // about the newly focused composer rather than cut off by it.
        UIAccessibility.post(
            notification: .announcement,
            argument: NSAttributedString(
                string: announcement,
                attributes: [.accessibilitySpeechQueueAnnouncement: true]
            )
        )
    }

    private func replyReferenceChip(_ reference: ComposerReplyReference) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "quote.bubble")
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppLocalization.string("Replying to \(reference.authorName)"))
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(reference.excerpt)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(AppLocalization.string("Sent with your next message"))
            Spacer(minLength: 0)
            Button {
                Haptics.selection()
                withAnimation(reduceMotion ? nil : ConduitMotion.response) {
                    replyReference = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(.body)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("Remove quoted reply"))
            .accessibilityIdentifier("composer.reply-reference.remove")
        }
        .padding(.leading, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Sending, steering, and stopping all move attention back to the live
    /// conversation. The UIKit text view observes this binding and resigns
    /// first responder, which dismisses the software keyboard.
    private func dismissComposer() {
        isFocused = false
        isShowingSlashSuggestions = false
    }

    /// A send or Stop: on a Mac or with a hardware keyboard the field keeps
    /// focus for the next message, as a desktop client's does, when the
    /// user was typing; otherwise the keyboard goes (`dismissComposer`).
    private func endInput(keepingFocus wasTyping: Bool) {
        guard wasTyping, ComposerLayout.keepsFocusAfterSend() else {
            dismissComposer()
            return
        }
        isShowingSlashSuggestions = false
        // After this update: the send rebuilds the field (a new editor
        // identity), and a send from the full editor gives it focus back
        // as the sheet goes.
        Task { @MainActor in isFocused = true }
    }

    private func composerDraftKey(for sessionID: String?) -> ComposerDraftKey {
        Self.composerDraftKey(for: sessionID, profile: appState.activeProfile)
    }

    private var asyncAttachmentContext: AsyncAttachmentContext {
        Self.photoImportContext(
            editorIdentity: editorIdentity,
            draftKey: activeDraftKey,
            attachmentGeneration: attachmentGeneration
        )
    }

    private func shouldAcceptAsyncAttachmentCompletion(startedIn origin: AsyncAttachmentContext) -> Bool {
        Self.shouldAcceptAsyncAttachmentCompletion(
            startedIn: origin,
            currentEditorIdentity: editorIdentity,
            currentDraftKey: activeDraftKey,
            currentAttachmentGeneration: attachmentGeneration
        )
    }

    private func shouldAcceptPhotoPickerCompletion(openedIn origin: AsyncAttachmentContext?) -> Bool {
        Self.shouldAcceptPhotoPickerCompletion(
            openedIn: origin,
            currentEditorIdentity: editorIdentity,
            currentDraftKey: activeDraftKey,
            currentAttachmentGeneration: attachmentGeneration
        )
    }

    static var cameraAccessMessage: String {
        AppLocalization.string("Taking a photo needs camera access. You can allow it in Settings.")
    }

    /// Asks for camera access first when it hasn't been decided, so a "Don't
    /// Allow" never leaves the picker open on a black screen; when access is
    /// off, the composer says so with a way to Settings instead.
    private func openCamera() {
        composerErrorMessage = nil
        let origin = asyncAttachmentContext
        let present = {
            cameraImportContext = origin
            showCamera = true
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            present()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard shouldAcceptAsyncAttachmentCompletion(startedIn: origin) else { return }
                if granted { present() } else { showCameraAccessNotice() }
            }
        default:
            showCameraAccessNotice()
        }
    }

    private func showCameraAccessNotice() {
        composerErrorMessage = Self.cameraAccessMessage
        Haptics.error()
    }

    private func openPhotoLibraryPicker() {
        // A fresh selection each time, so items an earlier import is still
        // staging aren't picked up again.
        photoItems = []
        photoImportContext = asyncAttachmentContext
        photoImportGeneration &+= 1
        showAttachmentMenu = true
    }

    private func saveDraft(for key: ComposerDraftKey) {
        draftStore.save(
            ComposerDraft(text: text, attachments: attachments, replyReference: replyReference),
            for: key
        )
    }

    private func loadDraft(for key: ComposerDraftKey) {
        // Kept under another of the chat's ids (typed over its saved copy,
        // or in the New Chat that created it): it's this chat's draft.
        if !draftStore.hasDraft(for: key),
           let other = draftStore.keys.first(where: { $0 != key && appState.composerDraftKeysAreSameChat($0, key) }) {
            draftStore.migrateDraft(from: other, to: key)
        }
        let draft = draftStore.draft(for: key)
        if text != draft.text {
            suppressNextTextChangeSuggestions = true
        }
        replaceComposerText(draft.text)
        attachments = draft.attachments
        replyReference = draft.replyReference
        loadedDraftKey = key
        loadedDraftClearCount = draftStore.clearCount
        composerTextHeight = restingTextHeight
        isFocused = false
        isShowingSlashSuggestions = false
    }

    private func handoffComposer(to destinationKey: ComposerDraftKey) {
        guard loadedDraftKey != destinationKey else { return }
        // A sign-out or server switch cleared the store on the way here:
        // the field's draft isn't put back, and the destination's loads.
        let keptKey = Self.draftKeyToKeep(
            loaded: loadedDraftKey,
            loadedClearCount: loadedDraftClearCount,
            storeClearCount: draftStore.clearCount
        )
        // The same chat under another id (a saved copy's chat opening, the
        // chat a New Chat created): the field stays as it is, focus and
        // dictation with it.
        if let loadedDraftKey = keptKey, appState.composerDraftKeysAreSameChat(loadedDraftKey, destinationKey) {
            saveDraft(for: destinationKey)
            draftStore.removeDraft(for: loadedDraftKey)
            self.loadedDraftKey = destinationKey
            applyPendingPrefill()
            return
        }
        // Dictated words belong to the draft they started in, and the full
        // editor to the chat it was opened in.
        dictation.cancel()
        isShowingFullEditor = false
        if let loadedDraftKey = keptKey {
            saveDraft(for: loadedDraftKey)
            if Self.draftKeysAreEquivalent(
                loadedDraftKey,
                destinationKey,
                identity: appState.activeChatScrollSessionIdentity
            ) {
                draftStore.migrateDraft(from: loadedDraftKey, to: destinationKey)
            }
        }
        composerErrorMessage = nil
        isFocused = false
        isShowingSlashSuggestions = false
        rotateAttachmentGeneration()
        editorIdentity = UUID()
        loadDraft(for: destinationKey)
        composerTextHeight = restingTextHeight
        isFocused = false
        // A prefill for this chat goes in over its draft; one for a chat
        // left behind is dropped.
        if let target = appState.composerPrefillDraftKey,
           !Self.draftKeysAreEquivalent(target, destinationKey, identity: appState.activeChatScrollSessionIdentity) {
            appState.consumeComposerPrefill(appState.composerPrefillToken)
        } else {
            applyPendingPrefill()
        }
    }

    /// Puts a waiting prefill in once its chat's draft is the one loaded.
    /// Opening a chat with a prefill (Try a test call, Have Hermes watch
    /// for this) changes the chat and the prefill in one update, and that
    /// chat's draft load can run after the prefill: put in first, it was
    /// saved into the chat being left and the new chat opened blank.
    private func applyPendingPrefill() {
        guard Self.shouldApplyPrefill(
            for: appState.composerPrefillDraftKey,
            loaded: loadedDraftKey,
            identity: appState.activeChatScrollSessionIdentity
        ) else { return }
        appState.consumeComposerPrefill(appState.composerPrefillToken)
        replaceComposerText(appState.composerPrefillText)
        isFocused = !text.isEmpty
        isShowingSlashSuggestions = Self.shouldShowSlashSuggestions(for: text, isProgrammaticDraftRestore: false)
    }

    private func rotateAttachmentGeneration() {
        attachmentGeneration &+= 1
        photoImportGeneration &+= 1
        photoItems = []
        photoImportContext = nil
        documentImportContext = nil
        cameraImportContext = nil
        editorIdentity = UUID()
    }

    private func handlePastedImage(_ pastedImage: PastedImage, editorIdentity callbackEditorIdentity: UUID) {
        guard callbackEditorIdentity == editorIdentity else { return }
        composerErrorMessage = nil
        let metadata = Self.pastedImageAttachmentMetadata(
            for: pastedImage.typeIdentifier
        )
        addAttachment(
            data: pastedImage.data,
            name: metadata.name,
            mimeType: metadata.mimeType,
            kind: .image
        )
    }

    /// A paste past `PastedText.characterThreshold` goes in as a text
    /// attachment, written off the main actor. Where the composer can't
    /// take files it stays in the field as before
    /// (`PastedText.chatComposerTakesPaste`). False leaves the paste to the
    /// field.
    private func attachLongPaste(_ pasted: String) -> Bool {
        guard PastedText.chatComposerTakesPaste(
            enabled: appState.composerIsEnabled,
            waitsForChat: appState.composerWaitsForChat
        ) else { return false }
        let limitMegabytes = attachmentLimitMegabytes
        // Past the attachment limit it can't go as a file: the words go in
        // the field, as every paste did before.
        guard PastedText.fits(pasted, limitMegabytes: limitMegabytes) else { return false }
        composerErrorMessage = nil
        let origin = asyncAttachmentContext
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                PastedText.stage(pasted, limitMegabytes: limitMegabytes)
            }.value
            guard shouldAcceptAsyncAttachmentCompletion(startedIn: origin) else {
                if case .staged(let attachment) = outcome { Self.discardStagedFile(attachment) }
                return
            }
            if case .staged(let attachment) = outcome {
                attachments.append(attachment)
                Haptics.light()
            } else {
                // The file couldn't be written: the words go in the field
                // after all, so the paste isn't lost.
                replaceComposerText(PastedText.joined(text, with: pasted), cursorAtEnd: true)
            }
        }
        return true
    }

    /// The sheet behind a pasted text's chip: edits replace its file, and
    /// Paste as text moves it into the field, after what was typed. Clearing
    /// all its text removes it, as × does.
    private func pastedTextActions(for id: String) -> PastedTextActions {
        PastedTextActions(
            save: { edited in
                guard let old = attachments.first(where: { $0.id == id }) else { return }
                guard !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    attachments.removeAll { $0.id == id }
                    Self.discardStagedFile(old)
                    return
                }
                let limitMegabytes = attachmentLimitMegabytes
                guard PastedText.fits(edited, limitMegabytes: limitMegabytes) else {
                    reportImportProblems(oversized: [PastedText.displayName], failed: [], limitMegabytes: limitMegabytes)
                    return
                }
                Task {
                    let outcome = await Task.detached(priority: .userInitiated) {
                        PastedText.restage(old, with: edited, limitMegabytes: limitMegabytes)
                    }.value
                    switch outcome {
                    case .staged(let updated):
                        // Removed or sent meanwhile: the edit has nothing
                        // left to replace.
                        guard let index = attachments.firstIndex(where: { $0.id == id && $0.uri == old.uri }) else {
                            Self.discardStagedFile(updated)
                            return
                        }
                        attachments[index] = updated
                        Self.discardStagedFile(old)
                    case .tooLarge(let name):
                        reportImportProblems(oversized: [name], failed: [], limitMegabytes: limitMegabytes)
                    case .failed(let name):
                        reportImportProblems(oversized: [], failed: [name], limitMegabytes: limitMegabytes)
                    }
                }
            },
            insertAsText: { pasted in
                guard let attachment = attachments.first(where: { $0.id == id }) else { return }
                attachments.removeAll { $0.id == id }
                Self.discardStagedFile(attachment)
                replaceComposerText(PastedText.joined(text, with: pasted), cursorAtEnd: true)
            }
        )
    }

    private func handlePastedImageError(_ message: String, editorIdentity callbackEditorIdentity: UUID) {
        guard callbackEditorIdentity == editorIdentity else { return }
        composerErrorMessage = Self.pastedImageErrorMessage(message)
        Haptics.error()
    }

    /// Photos and videos picked together, numbered in the order they were
    /// tapped (#334).
    static let photoPickerSelectionLimit = 10

    private func handlePhotoSelection() {
        let items = photoItems
        guard !items.isEmpty else { return }
        guard let origin = photoImportContext else {
            photoItems = []
            return
        }
        let completionGeneration = photoImportGeneration
        let limitMegabytes = attachmentLimitMegabytes
        Task {
            var tally = ImportTally()
            for (index, item) in items.enumerated() {
                guard shouldAcceptPhotoPickerCompletion(openedIn: origin) else { break }
                // File copies and JPEG re-encodes stay off the main actor;
                // only the strip update comes back here.
                let outcome = await Task.detached(priority: .userInitiated) {
                    await Self.stagePickedItem(item, ordinal: index + 1, limitMegabytes: limitMegabytes)
                }.value
                guard shouldAcceptPhotoPickerCompletion(openedIn: origin) else {
                    if case .staged(let attachment) = outcome { Self.discardStagedFile(attachment) }
                    break
                }
                record(outcome, in: &tally)
            }
            if shouldAcceptPhotoPickerCompletion(openedIn: origin) {
                finishImport(tally, limitMegabytes: limitMegabytes)
            }
            clearPhotoImportContextIfCurrent(
                completingGeneration: completionGeneration,
                completingContext: origin
            )
        }
    }

    typealias StagedImport = AttachmentStaging.StagedImport

    struct ImportTally {
        var stagedAny = false
        var oversized: [String] = []
        var failed: [String] = []
        var folders: [String]?
    }

    private func record(_ outcome: StagedImport, in tally: inout ImportTally) {
        switch outcome {
        case .staged(let attachment):
            attachments.append(attachment)
            tally.stagedAny = true
        case .tooLarge(let name):
            tally.oversized.append(name)
        case .failed(let name):
            tally.failed.append(name)
        }
    }

    /// One cue per selection: the error haptic and message when anything
    /// was left out, otherwise a light tap if something was staged.
    private func finishImport(_ tally: ImportTally, limitMegabytes: Int) {
        if tally.oversized.isEmpty && tally.failed.isEmpty && tally.folders == nil {
            if tally.stagedAny { Haptics.light() }
            return
        }
        reportImportProblems(
            oversized: tally.oversized,
            failed: tally.failed,
            folders: tally.folders,
            limitMegabytes: limitMegabytes
        )
    }

    /// Copies one picked item into the staging folder under its real name
    /// and type. Videos stay files end to end; images in a format model
    /// providers can't read (HEIC...) are re-encoded as JPEG.
    nonisolated static func stagePickedItem(_ item: PhotosPickerItem, ordinal: Int, limitMegabytes: Int) async -> StagedImport {
        let pickedType = item.supportedContentTypes.first
        let fallbackName = AttachmentTypePolicy.filename(suggested: nil, type: pickedType, ordinal: ordinal)
        if let file = try? await item.loadTransferable(type: PickedMediaFile.self) {
            let type = UTType(filenameExtension: file.url.pathExtension) ?? pickedType
            let name = AttachmentTypePolicy.filename(suggested: file.originalName, type: type, ordinal: ordinal)
            return AttachmentStaging.finishStaging(fileAt: file.url, name: name, type: type, limitMegabytes: limitMegabytes)
        }
        // Some images only hand over their bytes. Videos never take this
        // path: it would hold the whole file in memory.
        guard pickedType?.conforms(to: .image) == true,
              let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            return .failed(fallbackName)
        }
        do {
            let url = try AttachmentStaging.destination(for: fallbackName)
            try data.write(to: url, options: .atomic)
            return AttachmentStaging.finishStaging(fileAt: url, name: fallbackName, type: pickedType, limitMegabytes: limitMegabytes)
        } catch {
            return .failed(fallbackName)
        }
    }

    nonisolated static func discardStagedFile(_ attachment: Attachment) {
        guard let url = URL(string: attachment.uri), url.isFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func reportImportProblems(oversized: [String], failed: [String], folders: [String]? = nil, limitMegabytes: Int) {
        var messages: [String] = []
        if !oversized.isEmpty {
            messages.append(AttachmentSizeLimit.tooLargeMessage(names: oversized, megabytes: limitMegabytes))
        }
        if !failed.isEmpty {
            let list = failed.joined(separator: ", ")
            messages.append(AppLocalization.string("Could not prepare \(list) for upload."))
        }
        if let folders {
            messages.append(AttachmentDrop.folderMessage(names: folders))
        }
        guard !messages.isEmpty else { return }
        composerErrorMessage = messages.joined(separator: "\n")
        Haptics.error()
    }

    private func clearPhotoImportContextIfCurrent(
        completingGeneration: UInt64,
        completingContext: AsyncAttachmentContext
    ) {
        guard Self.shouldClearPhotoImportContext(
            completingGeneration: completingGeneration,
            completingContext: completingContext,
            currentGeneration: photoImportGeneration,
            currentContext: photoImportContext
        ) else { return }
        photoItems = []
        photoImportContext = nil
    }

    private func handleDocumentSelection(
        _ result: Result<[URL], Error>,
        startedIn origin: AsyncAttachmentContext?
    ) {
        guard let origin,
              shouldAcceptAsyncAttachmentCompletion(startedIn: origin) else { return }
        let urls: [URL]
        switch result {
        case .success(let picked):
            urls = picked
        case .failure(let error):
            composerErrorMessage = AppLocalization.string("Could not open the file: \(UserFacingError.message(for: error))")
            Haptics.error()
            return
        }
        let limitMegabytes = attachmentLimitMegabytes
        Task {
            var tally = ImportTally()
            for url in urls {
                guard shouldAcceptAsyncAttachmentCompletion(startedIn: origin) else { break }
                // Copied, checked and (for images) re-encoded off the main
                // actor, like picked photos.
                let outcome = await Task.detached(priority: .userInitiated) {
                    Self.stageDocument(at: url, limitMegabytes: limitMegabytes)
                }.value
                guard shouldAcceptAsyncAttachmentCompletion(startedIn: origin) else {
                    if case .staged(let attachment) = outcome { Self.discardStagedFile(attachment) }
                    break
                }
                record(outcome, in: &tally)
            }
            if shouldAcceptAsyncAttachmentCompletion(startedIn: origin) {
                finishImport(tally, limitMegabytes: limitMegabytes)
            }
        }
    }

    /// Files dropped on the chat or its text field (#1408), staged one by
    /// one like picked documents. A locked composer takes none, as its
    /// Attach menu is off then. A folder isn't attached; the notice names
    /// it and says to drop the files inside.
    private func handleDroppedFiles(_ providers: [NSItemProvider]) {
        guard appState.composerIsEnabled, !providers.isEmpty else { return }
        composerErrorMessage = nil
        let origin = asyncAttachmentContext
        let limitMegabytes = attachmentLimitMegabytes
        let files = providers.filter { !AttachmentDrop.isFolder($0) }
        let hasFolders = files.count < providers.count
        let folderNames = AttachmentDrop.folderNames(in: providers)
        Task {
            var tally = ImportTally()
            if hasFolders { tally.folders = folderNames }
            for (index, provider) in files.enumerated() {
                guard shouldAcceptAsyncAttachmentCompletion(startedIn: origin) else { break }
                let outcome = await AttachmentDrop.stage(provider, ordinal: index + 1, limitMegabytes: limitMegabytes)
                guard shouldAcceptAsyncAttachmentCompletion(startedIn: origin) else {
                    if case .staged(let attachment) = outcome { Self.discardStagedFile(attachment) }
                    break
                }
                record(outcome, in: &tally)
            }
            if shouldAcceptAsyncAttachmentCompletion(startedIn: origin) {
                finishImport(tally, limitMegabytes: limitMegabytes)
            }
        }
    }

    /// Stages a file from the document picker the same way as a picked
    /// photo: size checked before it is read, copied rather than loaded.
    nonisolated static func stageDocument(at url: URL, limitMegabytes: Int) -> StagedImport {
        let name = url.lastPathComponent
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return AttachmentStaging.stageCopy(
            of: url,
            name: name,
            type: UTType(filenameExtension: url.pathExtension),
            limitMegabytes: limitMegabytes
        )
    }

    /// A photo from the Camera item, staged like a picked one: encoded as
    /// JPEG off the main actor, then size checked.
    private func handleCapturedPhoto(_ image: UIImage, startedIn origin: AsyncAttachmentContext?) {
        guard let origin, shouldAcceptAsyncAttachmentCompletion(startedIn: origin) else { return }
        composerErrorMessage = nil
        let limitMegabytes = attachmentLimitMegabytes
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.stageCapturedPhoto(image, limitMegabytes: limitMegabytes)
            }.value
            guard shouldAcceptAsyncAttachmentCompletion(startedIn: origin) else {
                if case .staged(let attachment) = outcome { Self.discardStagedFile(attachment) }
                return
            }
            var tally = ImportTally()
            record(outcome, in: &tally)
            finishImport(tally, limitMegabytes: limitMegabytes)
        }
    }

    nonisolated static func stageCapturedPhoto(_ image: UIImage, limitMegabytes: Int) -> StagedImport {
        let name = AttachmentTypePolicy.jpegFilename(for: "photo")
        guard let data = image.jpegData(compressionQuality: 0.9),
              let url = try? AttachmentStaging.destination(for: name),
              (try? data.write(to: url, options: .atomic)) != nil else { return .failed(name) }
        return AttachmentStaging.finishStaging(fileAt: url, name: name, type: .jpeg, limitMegabytes: limitMegabytes)
    }

    private func clearDocumentImportContextIfCurrent(_ completingContext: AsyncAttachmentContext?) {
        guard documentImportContext == completingContext else { return }
        documentImportContext = nil
    }

    /// Pasted images: written to the staging folder off the main actor and
    /// normalized like picked photos (a pasted HEIC goes up as JPEG).
    private func addAttachment(data: Data, name: String, mimeType: String, kind: Attachment.Kind) {
        guard !data.isEmpty else { return }
        let limitMegabytes = attachmentLimitMegabytes
        guard AttachmentSizeLimit.allows(byteCount: Int64(data.count), megabytes: limitMegabytes) else {
            reportImportProblems(oversized: [name], failed: [], limitMegabytes: limitMegabytes)
            return
        }
        let origin = asyncAttachmentContext
        let type = UTType(mimeType: mimeType)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> StagedImport in
                guard let url = try? AttachmentStaging.destination(for: name),
                      (try? data.write(to: url, options: .atomic)) != nil else { return .failed(name) }
                return AttachmentStaging.finishStaging(fileAt: url, name: name, type: type, limitMegabytes: limitMegabytes)
            }.value
            guard shouldAcceptAsyncAttachmentCompletion(startedIn: origin) else {
                if case .staged(let attachment) = outcome { Self.discardStagedFile(attachment) }
                return
            }
            var tally = ImportTally()
            record(outcome, in: &tally)
            finishImport(tally, limitMegabytes: limitMegabytes)
        }
    }

    private var accessibilityLabel: String {
        switch action {
        case .stop: return AppLocalization.string("Stop response")
        case .steer: return AppLocalization.string("Steer with message")
        case .interrupt: return AppLocalization.string("Interrupt and correct response")
        case .queue: return AppLocalization.string("Queue message")
        case .send: return AppLocalization.string("Send message")
        case .unavailable:
            return showsEmptyDraftSend ? AppLocalization.string("Send message") : AppLocalization.string("Composer unavailable")
        }
    }

    private var modelAccessibilityLabel: String {
        let model = appState.runtime.model.isEmpty ? AppLocalization.string("Model") : appState.runtime.model
        // Reasoning has its own control beside the model name.
        let approvals = appState.runtime.yolo ? AppLocalization.string(", auto-approve enabled") : ""
        let activity = appState.turnState == .running ? AppLocalization.string(", agent working") : ""
        return "\(model)\(approvals)\(activity)"
    }
}

// MARK: - Context Ring

struct ContextRingView: View {
    let percent: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(percent / 100, 1))
                .stroke(Color.conduitAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // Fixed size: it sits inside the fixed 32 pt ring.
            Text("\(String(Int(percent.rounded())))%")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
        }
    }
}

// MARK: - Slash Suggestions Overlay

private struct SlashSuggestionsOverlay: View {
    let commands: [SlashCommand]
    let onSelected: (SlashCommand) -> Void
    @ScaledMetric(relativeTo: .caption2) private var categoryBadgeSize: CGFloat = 9

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, cmd in
                    Button {
                        Haptics.selection()
                        onSelected(cmd)
                    } label: {
                        HStack(spacing: 10) {
                            // Command name
                            HStack(spacing: 0) {
                                Text("/")
                                    .foregroundStyle(.secondary)
                                Text(cmd.name)
                                    .foregroundStyle(.primary)
                            }
                            .scaledFont(.subheadline.monospaced().weight(.semibold))
                            .frame(minWidth: 90, alignment: .leading)

                            // Description
                            if !cmd.description.isEmpty {
                                Text(cmd.description)
                                    .scaledFont(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            // Category badge
                            if let category = cmd.category, !category.isEmpty {
                                Text(category)
                                    .font(.system(size: categoryBadgeSize, weight: .medium))
                                    .foregroundStyle(.conduitAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.conduitAccent.opacity(0.12), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < commands.count - 1 {
                        Divider()
                            .opacity(0.3)
                    }
                }
            }
        }
        .frame(maxHeight: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// The action button's glass, shared by its button and menu forms.
private struct ComposerActionChrome: ViewModifier {
    let tint: Color
    let action: ComposerAction

    func body(content: Content) -> some View {
        content.conduitGlassControl(
            cornerRadius: ComposerBar.controlSize / 2,
            tint: tint,
            prominent: action == .send,
            interactive: action != .unavailable
        )
    }
}
