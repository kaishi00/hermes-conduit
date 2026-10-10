//
//  ComposerBar.swift
//  Conduit
//
//  Composer controls are derived from AppState.turnState. A reconnecting or
//  synchronizing session is intentionally non-interactive until Hermes returns
//  an authoritative `running` value.
//

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ComposerBar: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @State private var composerTextHeight = ComposerPasteTextView.minimumHeight
    @State private var attachments: [Attachment] = []
    /// A whole reply attached with its Quote button (#385); it rides along
    /// with the next message.
    @State private var replyReference: ComposerReplyReference?
    @State private var showAttachmentMenu = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showDocumentPicker = false
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
    @State private var photoImportContext: AsyncAttachmentContext?
    @State private var photoImportGeneration: UInt64 = 0
    @State private var documentImportContext: AsyncAttachmentContext?
    @State private var attachmentGeneration: UInt64 = 0
    @State private var suppressNextTextChangeSuggestions = false
    /// Round 6: non-nil presents the Repair Connection wizard seeded from
    /// the failed connection.
    @State private var repairContext: ConnectionRepairContext?
    /// Local, device-only input preference. Defaults to off so existing
    /// users keep Return inserting a newline after updating.
    @AppStorage(ComposerReturnKey.preferenceKey) private var returnKeySends = false
    @AppStorage(AttachmentSizeLimit.preferenceKey) private var attachmentLimitMegabytes = AttachmentSizeLimit.defaultMegabytes
    @Namespace private var glassNamespace
    /// The dictate button types into the draft (#290, #335).
    @StateObject private var dictation = ComposerDictationService()
    /// The draft as it was when dictation began; dictated text goes after it.
    @State private var dictationPrefix = ""
    /// The draft as dictation last wrote it, so the full editor, which
    /// reports every change the same way, can tell it from typing.
    @State private var dictatedDraft: String?
    /// The full-screen editor for long drafts (#335).
    @State private var isShowingFullEditor = false

    struct AsyncAttachmentContext: Equatable {
        let editorIdentity: UUID
        let draftKey: ComposerDraftKey
        let attachmentGeneration: UInt64
    }

    /// About three lines of body text: below this a draft is short enough
    /// to read in place, so the expand icon stays out of the way.
    static let fullEditorThreshold: CGFloat = 80

    static func showsFullEditorButton(measuredHeight: CGFloat) -> Bool {
        measuredHeight >= fullEditorThreshold
    }

    static func composerDraftKey(for sessionID: String?, profile: String) -> ComposerDraftKey {
        ComposerDraftKey(
            profile: profile,
            sessionID: sessionID ?? ComposerDraftKey.newConversationSessionID
        )
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
        return slashPrefix(in: text) != nil
    }

    private static func slashPrefix(in text: String) -> String? {
        let trimmed = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        guard trimmed.hasPrefix("/") else { return nil }
        let prefix = String(trimmed.dropFirst())
        guard !prefix.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return prefix.lowercased()
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
        guard let prefix = slashPrefix else { return [] }
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
        appState.composerAction(hasText: hasText, hasAttachments: !attachments.isEmpty || pendingScreenshot != nil)
    }

    /// A screenshot from Ask Hermes About Screen waiting on this chat. It
    /// is AppState's, not the draft's, so a spoken question can carry it.
    private var pendingScreenshot: Attachment? {
        appState.pendingScreenshot(forSession: appState.activeSessionId)
    }

    private var activeDraftKey: ComposerDraftKey {
        composerDraftKey(for: appState.activeSessionId)
    }

    private var stopOnly: Bool {
        action == .stop
    }

    private var actionSymbol: String {
        switch action {
        case .stop: return "stop.fill"
        case .steer: return BusyInputMode.steer.symbol
        case .interrupt: return BusyInputMode.interrupt.symbol
        case .send: return "arrow.up"
        case .unavailable: return "lock"
        }
    }

    private var actionTitle: String? {
        nil
    }

    private var actionTint: Color {
        switch action {
        case .stop: return .red
        case .steer: return .conduitAura
        case .interrupt: return .orange
        case .send: return .conduitAccent
        case .unavailable: return .secondary.opacity(0.48)
        }
    }

    private var actionSurfaceTint: Color {
        action == .unavailable ? Color.primary.opacity(0.025) : actionTint
    }

    private var composerFoundation: Color {
        colorScheme == .dark
            ? Color(red: 0.072, green: 0.080, blue: 0.106).opacity(0.96)
            : Color.white.opacity(0.94)
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
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .onChange(of: text) { _, newValue in
            let isProgrammaticDraftRestore = suppressNextTextChangeSuggestions
            suppressNextTextChangeSuggestions = false
            composerErrorMessage = nil
            if newValue.isEmpty {
                composerTextHeight = ComposerPasteTextView.minimumHeight
            }
            // Show suggestions when actively typing a slash command prefix
            withAnimation(ConduitMotion.response) {
                isShowingSlashSuggestions = Self.shouldShowSlashSuggestions(
                    for: newValue,
                    isProgrammaticDraftRestore: isProgrammaticDraftRestore
                )
            }
        }
        .onChange(of: appState.composerPrefillToken) { _, _ in
            replaceComposerText(appState.composerPrefillText)
            isFocused = !text.isEmpty
            isShowingSlashSuggestions = slashPrefix != nil
        }
        .onChange(of: appState.composerQuoteRequest) { _, request in
            applyQuoteRequest(request)
        }
        .onChange(of: appState.composerFocusRequest) { _, request in
            applyFocusRequest(request)
        }
        .onChange(of: photoItems) { _, _ in
            handlePhotoSelection()
        }
        .onChange(of: appState.chatTakeover?.readyToken) { _, _ in
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
            // A screenshot chat can open before this composer is on screen.
            applyFocusRequest(appState.composerFocusRequest)
        }
        .onChange(of: activeDraftKey) { _, newKey in
            handoffComposer(to: newKey)
        }
        .onChange(of: appState.activeRoomSurface != nil) { _, roomActive in
            // The room surface unmounts this composer's subtree. Persist the
            // typed draft BEFORE it goes, so returning to the session
            // restores exactly what the user had typed.
            if roomActive {
                saveDraft(for: activeDraftKey)
            }
        }
        .onChange(of: appState.composerIsEnabled) { _, enabled in
            // The sheet has no room for the composer's notices; the inline
            // composer explains why it is locked.
            if !enabled { isShowingFullEditor = false }
            if enabled { applyFocusRequest(appState.composerFocusRequest) }
        }
        .onChange(of: appState.isVoiceInUse) { _, inUse in
            // Voice took the microphone: dictation steps aside.
            guard inUse else { return }
            dictation.cancel()
        }
        .onDisappear {
            dictation.cancel()
            // Dependable second hook: whether this view leaves for a room,
            // a session switch, or teardown, the typed text lands in the
            // app-lifetime store first.
            if appState.activeRoomSurface != nil {
                saveDraft(for: activeDraftKey)
            }
        }
        // A session resume can complete before the gateway has refreshed its
        // context accounting. Recheck once the active composer is on screen,
        // rather than making the user open the context sheet to populate it.
        .task(id: appState.activeSessionId) {
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
    }

    private var composerContent: some View {
        VStack(spacing: 0) {
            if !appState.composerIsEnabled {
                stateNotice
            }

            if appState.isCompressingActiveSession {
                compressingNotice
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

            if !isShowingSlashSuggestions && !mentionCandidates.isEmpty {
                MentionSuggestionList(candidates: mentionCandidates) { candidate in
                    replaceComposerText(MentionAutocomplete.completing(text, with: candidate))
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // The field spans the card; every control sits in the row
            // below it, so a long draft wraps across the full width (#335).
            composerField
                .padding(.horizontal, 6)
                .padding(.top, 6)

            controlsRow
        }
        .background(composerFoundation, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(composerStroke, lineWidth: 1)
        }
        .opacity(appState.turnState == .unsupportedGateway ? 0.7 : 1)
        .animation(ConduitMotion.transition, value: action)
        .preferredColorScheme(appState.themePreference.colorScheme)
        .sheet(item: $repairContext) { context in
            ConnectionRepairSetupSheet(context: context)
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
            }
            ComposerPasteTextView(
                text: $text,
                isFocused: $isFocused,
                measuredHeight: $composerTextHeight,
                enabled: appState.composerIsEnabled,
                onPastedImage: { pastedImage in
                    handlePastedImage(pastedImage, editorIdentity: currentEditorIdentity)
                },
                onPastedImageError: { message in
                    handlePastedImageError(message, editorIdentity: currentEditorIdentity)
                },
                editorIdentity: editorIdentity,
                programmaticRevision: composerRevision,
                programmaticCursorAtEnd: composerCursorAtEnd,
                returnKeySends: returnKeySends,
                // May lag one render behind fast typing; the safe
                // failure mode is newline insertion, and
                // submitFromReturnKey() re-checks the live gate.
                canSubmitFromReturn: ComposerReturnKey.canSubmit(action: action),
                onSubmitFromReturn: { submitFromReturnKey() },
                onUserEdit: {
                    // Typed here: no later change matching dictation's last
                    // write is dictation's.
                    dictatedDraft = nil
                    appState.noteComposerUserEdit()
                    // Typing ends a dictation: its next result would rewrite
                    // the draft from where it began and drop the keystrokes.
                    // The words so far stay.
                    if dictation.isDictating || dictation.isStarting { dictation.cancel() }
                }
            )
            .id(editorIdentity)
            .padding(.leading, 5)
            // Room for the expand icon, so the text wraps before it.
            .padding(.trailing, showsFullEditorButton ? 40 : 5)
            .frame(height: composerTextHeight)
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
                .disabled(!appState.composerIsEnabled)
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
                enabled: appState.composerIsEnabled,
                onUserEdit: { edited in
                    // Dictation writing the draft is not typing.
                    // Dictation's last write can be reported after it has
                    // finished, so this doesn't ask whether it is still running.
                    guard ComposerDictation.isTyping(edited, dictationWrote: dictatedDraft) else { return }
                    // Spent: the same text typed again by hand is typing.
                    dictatedDraft = nil
                    appState.noteComposerUserEdit()
                    // As inline: typing ends a dictation, keeping its words.
                    if dictation.isDictating || dictation.isStarting { dictation.cancel() }
                },
                onCollapse: { isShowingFullEditor = false },
                attachments: {
                    if let replyReference {
                        replyReferenceChip(replyReference)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }
                    if !attachments.isEmpty || pendingScreenshot != nil {
                        attachmentStrip
                    }
                },
                dictateButton: { dictateButton },
                actionButton: { composerActionButton }
            )
            .preferredColorScheme(appState.themePreference.colorScheme)
        }
    }

    private var showsFullEditorButton: Bool {
        Self.showsFullEditorButton(measuredHeight: composerTextHeight)
    }

    /// Attach, model and session status on the left; dictate and the
    /// voice/send slot on the right, like the Codex composer (#335).
    /// The round controls match the context ring, leaving the model chip
    /// more width (#466).
    static let controlSize: CGFloat = 32
    /// Taps land a little outside each control. Half the row spacing, so
    /// neighbours never overlap.
    static var controlHitShape: some Shape { Rectangle().inset(by: -4) }

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
            .accessibilityLabel("Context usage, \(Int(appState.runtime.contextPercent.rounded())) percent")

            if appState.activeAgents > 0 {
                Button {
                    Haptics.selection()
                    appState.showAgentsSheet = true
                } label: {
                    Label("\(appState.activeAgents)", systemImage: "person.2")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.conduitAccent)
                        .frame(minWidth: Self.controlSize, minHeight: Self.controlSize)
                        .contentShape(Self.controlHitShape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Delegate agents, \(Int(appState.activeAgents)) active"))
            }

            dictateButton

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

    @ViewBuilder
    private var stateNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                .font(.footnote)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if let error = appState.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Round 6: Repair Connection appears only once the connection is
            // actually down AND a failed attempt has surfaced — through the
            // typed classified failure or the visible error banner — never
            // during normal automatic recovery, and never uninvited.
            // Entering repair hands recovery authority to the user; the
            // automatic retry loop stays stopped until the repair reconnects
            // or the user retries manually.
            if appState.connection != nil,
               !appState.isConnected,
               (appState.lastConnectionFailure != nil
                   || !(appState.errorMessage ?? "").isEmpty) {
                Button {
                    Haptics.light()
                    repairContext = appState.beginConnectionRepair()
                } label: {
                    Label("Repair Connection", systemImage: "wrench.and.screwdriver")
                        .font(.footnote.weight(.semibold))
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
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.secondary)
                }
                Text(Self.chatTakeoverMessage(takeover))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    Haptics.selection()
                    appState.dismissChatTakeover()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
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
                        .font(.footnote.weight(.semibold))
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
            return AppLocalization.string(
                "This chat is open in Conduit on another device or in the Hermes web chat. Send from there, or close it there and try again."
            )
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
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func pasteErrorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
                        canRemove: appState.composerIsEnabled
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
            Button {
                Haptics.selection()
                Task { await appState.openWorkspace() }
            } label: {
                Label("Workspace", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(Self.controlHitShape)
        }
        .disabled(!appState.composerIsEnabled || appState.isBusy)
        .conduitGlassControl(cornerRadius: Self.controlSize / 2, tint: .conduitAccent.opacity(0.08))
        .photosPicker(
            isPresented: $showAttachmentMenu,
            selection: $photoItems,
            maxSelectionCount: Self.photoPickerSelectionLimit,
            selectionBehavior: .ordered,
            matching: .any(of: [.images, .videos])
        )
    }

    /// What the single trailing slot of the input row holds.
    enum TrailingControl: Equatable {
        case voice
        case action
    }

    /// Voice and send share one trailing slot, like Messages (#194): with
    /// nothing to send the slot offers voice (when it's enabled for the
    /// profile), and any sendable draft or live turn swaps it for the
    /// action button. The slot itself never disappears, so the row keeps
    /// its layout as the first character is typed. Dictation has its own
    /// button beside it (#335), so Send shows up as soon as words land.
    static func trailingControl(action: ComposerAction, showsVoiceButton: Bool) -> TrailingControl {
        action == .unavailable && showsVoiceButton ? .voice : .action
    }

    @ViewBuilder
    private var trailingSlot: some View {
        let control = Self.trailingControl(
            action: action,
            showsVoiceButton: appState.showsComposerVoiceButton
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
        }
    }

    private var composerActionButton: some View {
        Button {
            if stopOnly {
                dismissComposer()
                isShowingFullEditor = false
                Haptics.warning()
                Task { await appState.cancelCurrent() }
            } else {
                submit()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: actionSymbol)
                    .font(.system(size: stopOnly ? 12 : 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                if let actionTitle {
                    Text(actionTitle)
                        .font(.caption.weight(.semibold))
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .foregroundStyle(action == .unavailable ? Color.secondary.opacity(0.48) : Color.white)
            .frame(minWidth: actionTitle == nil ? Self.controlSize : 86, minHeight: Self.controlSize)
            .padding(.horizontal, actionTitle == nil ? 0 : 4)
            .contentShape(Self.controlHitShape)
            .animation(ConduitMotion.transition, value: action)
        }
        .disabled(action == .unavailable)
        .conduitGlassControl(
            cornerRadius: Self.controlSize / 2,
            tint: actionSurfaceTint,
            prominent: action == .send,
            interactive: action != .unavailable
        )
        .accessibilityLabel(accessibilityLabel)
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
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.orange)
                    }
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(modelAccessibilityLabel)

            if !appState.runtime.model.isEmpty {
                // The model name gives way first, then the effort.
                reasoningMenu
                    .layoutPriority(1)
            }
        }
        .font(.footnote.weight(.semibold))
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
        .accessibilityLabel(Text("Reasoning"))
        .accessibilityValue(Text(ReasoningEffortLevel.displayTitle(for: appState.runtime.reasoningEffort)))
    }

    /// Return-shortcut entry point. Invokes the exact same submission path
    /// as the composer action button, but only for typed-message actions
    /// (send/steer/interrupt): Return never acts as the stop-only control.
    /// The gate is re-checked here so the existing composer action state —
    /// not the text view — stays authoritative. Reports whether the message
    /// actually went out, so a declined shortcut press falls back to the
    /// text view's default newline behavior instead of being swallowed.
    @discardableResult
    private func submitFromReturnKey() -> Bool {
        guard ComposerReturnKey.canSubmit(action: action) else { return false }
        submit()
        return true
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty || pendingScreenshot != nil else { return }

        // Send is beside the dictate button, so it can be tapped mid-dictation:
        // the words so far go out, and late results must not refill the
        // emptied field.
        // The send haptic stands for both.
        dictation.onFinish = nil
        dictation.cancel()
        isShowingFullEditor = false
        let submittedText = text
        let submittedAttachments = attachments
        // A slash command leaves the reply attached for the next message.
        let submittedReply = ComposerReplyReference.appliesToDraft(
            trimmed,
            hasAttachments: !submittedAttachments.isEmpty
        ) ? replyReference : nil
        let outboundText = ComposerReplyReference.outboundText(
            trimmed,
            hasAttachments: !submittedAttachments.isEmpty,
            replyingTo: submittedReply
        )
        let submittedAction = action
        let prefillToken = appState.composerPrefillToken
        let submittedDraftKey = loadedDraftKey ?? activeDraftKey
        let submittedDraftBucket = draftStore.submissionBucket(for: submittedDraftKey)
        let submissionContext = appState.composerSubmissionContext()
        rotateAttachmentGeneration()
        collapseSubmittedDraft(clearingReply: submittedReply != nil)

        switch submittedAction {
        case .send: Haptics.medium()
        case .steer: Haptics.light()
        case .interrupt: Haptics.warning()
        case .stop, .unavailable: break
        }

        Task {
            let didSubmit = await appState.submitComposer(
                text: outboundText,
                attachments: submittedAttachments,
                context: submissionContext
            )
            guard didSubmit else {
                restoreSubmittedDraftIfNeeded(
                    text: submittedText,
                    attachments: submittedAttachments,
                    replyReference: submittedReply,
                    for: submittedDraftKey
                )
                Haptics.error()
                return
            }
            draftStore.removeDraft(for: submittedDraftBucket)
            guard loadedDraftKey == submittedDraftKey else { return }
            if appState.composerPrefillToken != prefillToken {
                replaceComposerText(appState.composerPrefillText)
                isFocused = !text.isEmpty
            }
            isShowingSlashSuggestions = slashPrefix != nil
        }
    }

    /// A saved live call: pick it up with a new live call that continues
    /// the same row. A phone glyph, not the waveform, so it isn't mistaken
    /// for the voice button, which always starts a new call.
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
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.conduitAccent)
            .frame(width: Self.controlSize, height: Self.controlSize)
            .contentShape(Self.controlHitShape)
        }
        .buttonStyle(.plain)
        .disabled(appState.isPreparingVoiceResume || appState.isBusy)
        .conduitGlassControl(cornerRadius: Self.controlSize / 2, tint: .conduitAura.opacity(0.14), interactive: true)
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
        let isActive = isCapturing || dictation.isStarting
        return Button {
            switch ComposerDictation.tap(
                isCapturing: dictation.isCapturing,
                isStarting: dictation.isStarting,
                canDictate: canDictate
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
        .accessibilityLabel(isCapturing
            ? Text("Stop dictation")
            : (dictation.isStarting ? Text("Cancel dictation") : Text("Dictate")))
        .accessibilityHint(isCapturing
            ? AppLocalization.string("Stops dictating; the words stay in the message")
            : (dictation.isStarting ? "" : (appState.isVoiceInUse
                ? AppLocalization.string("Dictation is unavailable while a voice conversation has the microphone")
                : AppLocalization.string("Types what you say into the message"))))
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
        appState.canStartPhoneVoiceConversation && !appState.isBusy && appState.composerIsEnabled
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
            guard ComposerDictation.draftIsAsDictationLeftIt(
                text, prefix: dictationPrefix, lastWrite: dictatedDraft
            ) else {
                dictation.cancel()
                return
            }
            let draft = ComposerDictation.draft(before: dictationPrefix, dictated: transcript)
            dictatedDraft = draft
            // The cursor follows the words, so the next dictation or typing
            // carries on after them.
            replaceComposerText(draft, cursorAtEnd: true)
        }
        dictation.onFinish = { _ in
            Haptics.light()
        }
        Task {
            do {
                try await dictation.start(token: token)
            } catch {
                composerErrorMessage = UserFacingError.message(for: error)
            }
        }
    }

    /// Collapse the draft in the same transaction that dismisses the keyboard.
    /// Waiting for the gateway RPC leaves the side controls aligned to the old
    /// multiline field while the keyboard's safe area is already animating.
    private func collapseSubmittedDraft(clearingReply: Bool) {
        dismissComposer()
        let updates = {
            replaceComposerText("")
            attachments = []
            if clearingReply { replyReference = nil }
            composerTextHeight = ComposerPasteTextView.minimumHeight
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
        for key: ComposerDraftKey
    ) {
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
            draftStore.saveIfMissing(
                ComposerDraft(
                    text: submittedText,
                    attachments: submittedAttachments,
                    replyReference: submittedReply
                ),
                for: restorationKey
            )
            return
        }
        // Do not overwrite a new draft if the user already returned to the
        // composer while the failed request was in flight.
        guard text.isEmpty, attachments.isEmpty else { return }
        replaceComposerText(submittedText)
        attachments = submittedAttachments
        if replyReference == nil { replyReference = submittedReply }
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

    /// A quote from the transcript (#385): selected text joins the draft as
    /// a `>` quote with the cursor below it; a reply's Quote button attaches
    /// the whole reply as the "Replying to…" chip. Either way the composer
    /// takes focus for the reply.
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
            if dictation.isDictating || dictation.isStarting { dictation.cancel() }
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
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppLocalization.string("Replying to \(reference.authorName)"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(reference.excerpt)
                    .font(.caption)
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
                    .font(.body)
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
        let draft = draftStore.draft(for: key)
        if text != draft.text {
            suppressNextTextChangeSuggestions = true
        }
        replaceComposerText(draft.text)
        attachments = draft.attachments
        replyReference = draft.replyReference
        loadedDraftKey = key
        composerTextHeight = ComposerPasteTextView.minimumHeight
        isFocused = false
        isShowingSlashSuggestions = false
    }

    private func handoffComposer(to destinationKey: ComposerDraftKey) {
        guard loadedDraftKey != destinationKey else { return }
        // Dictated words belong to the draft they started in, and the full
        // editor to the chat it was opened in.
        dictation.cancel()
        isShowingFullEditor = false
        if let loadedDraftKey {
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
        composerTextHeight = ComposerPasteTextView.minimumHeight
        isFocused = false
    }

    private func rotateAttachmentGeneration() {
        attachmentGeneration &+= 1
        photoImportGeneration &+= 1
        photoItems = []
        photoImportContext = nil
        documentImportContext = nil
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
        if tally.oversized.isEmpty && tally.failed.isEmpty {
            if tally.stagedAny { Haptics.light() }
            return
        }
        reportImportProblems(oversized: tally.oversized, failed: tally.failed, limitMegabytes: limitMegabytes)
    }

    /// Copies one picked item into the staging folder under its real name
    /// and type. Videos stay files end to end; images in a format model
    /// providers can't read (HEIC...) are re-encoded as JPEG.
    nonisolated private static func stagePickedItem(_ item: PhotosPickerItem, ordinal: Int, limitMegabytes: Int) async -> StagedImport {
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

    nonisolated private static func discardStagedFile(_ attachment: Attachment) {
        guard let url = URL(string: attachment.uri), url.isFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func reportImportProblems(oversized: [String], failed: [String], limitMegabytes: Int) {
        var messages: [String] = []
        if !oversized.isEmpty {
            messages.append(AttachmentSizeLimit.tooLargeMessage(names: oversized, megabytes: limitMegabytes))
        }
        if !failed.isEmpty {
            let list = failed.joined(separator: ", ")
            messages.append(AppLocalization.string("Could not prepare \(list) for upload."))
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

    /// Stages a file from the document picker the same way as a picked
    /// photo: size checked before it is read, copied rather than loaded.
    nonisolated private static func stageDocument(at url: URL, limitMegabytes: Int) -> StagedImport {
        let name = url.lastPathComponent
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        if let size = AttachmentSizeLimit.fileSize(at: url),
           !AttachmentSizeLimit.allows(byteCount: size, megabytes: limitMegabytes) {
            return .tooLarge(name)
        }
        do {
            let staged = try AttachmentStaging.destination(for: name)
            try FileManager.default.copyItem(at: url, to: staged)
            return AttachmentStaging.finishStaging(
                fileAt: staged,
                name: name,
                type: UTType(filenameExtension: url.pathExtension),
                limitMegabytes: limitMegabytes
            )
        } catch {
            return .failed(name)
        }
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
        case .send: return AppLocalization.string("Send message")
        case .unavailable: return AppLocalization.string("Composer unavailable")
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
            Text("\(String(Int(percent.rounded())))%")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
        }
    }
}

// MARK: - Slash Suggestions Overlay

private struct SlashSuggestionsOverlay: View {
    let commands: [SlashCommand]
    let onSelected: (SlashCommand) -> Void

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
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .frame(minWidth: 90, alignment: .leading)

                            // Description
                            if !cmd.description.isEmpty {
                                Text(cmd.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            // Category badge
                            if let category = cmd.category, !category.isEmpty {
                                Text(category)
                                    .font(.system(size: 9, weight: .medium))
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
