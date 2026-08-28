//
//  ComposerBar.swift
//  Conduit
//
//  Composer controls are derived from AppState.turnState. A reconnecting or
//  synchronizing session is intentionally non-interactive until Hermes returns
//  an authoritative `running` value.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ComposerBar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @State private var composerTextHeight = ComposerPasteTextView.minimumHeight
    @State private var attachments: [Attachment] = []
    @State private var showAttachmentMenu = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showDocumentPicker = false
    @State private var isFocused = false
    @State private var isShowingSlashSuggestions = false
    @State private var composerErrorMessage: String?
    @State private var draftStore = ComposerDraftStore()
    @State private var editorIdentity = UUID()
    @State private var loadedDraftKey: ComposerDraftKey?
    @State private var photoImportContext: AsyncAttachmentContext?
    @State private var photoImportGeneration: UInt64 = 0
    @State private var documentImportContext: AsyncAttachmentContext?
    @State private var attachmentGeneration: UInt64 = 0
    @State private var suppressNextTextChangeSuggestions = false
    /// Local, device-only input preference. Defaults to off so existing
    /// users keep Return inserting a newline after updating.
    @AppStorage(ComposerReturnKey.preferenceKey) private var returnKeySends = false
    @Namespace private var glassNamespace

    struct AsyncAttachmentContext: Equatable {
        let editorIdentity: UUID
        let draftKey: ComposerDraftKey
        let attachmentGeneration: UInt64
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
        "Could not paste image: \(message)"
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private var action: ComposerAction {
        appState.composerAction(hasText: hasText, hasAttachments: !attachments.isEmpty)
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
        case .steer: return "arrow.triangle.branch"
        case .interrupt: return "arrow.uturn.backward"
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

    private var fieldFoundation: Color {
        colorScheme == .dark ? Color.white.opacity(0.065) : Color.black.opacity(0.035)
    }

    private var fieldStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    var body: some View {
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
            text = appState.composerPrefillText
            isFocused = !text.isEmpty
            isShowingSlashSuggestions = slashPrefix != nil
        }
        .onChange(of: photoItem) { _, _ in
            handlePhotoSelection()
        }
        .onAppear {
            guard loadedDraftKey == nil else { return }
            loadDraft(for: activeDraftKey)
        }
        .onChange(of: activeDraftKey) { _, newKey in
            handoffComposer(to: newKey)
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

            if let composerErrorMessage, !composerErrorMessage.isEmpty {
                pasteErrorNotice(composerErrorMessage)
            }

            if !attachments.isEmpty {
                attachmentStrip
            }

            sessionControls

            if isShowingSlashSuggestions && !filteredSlashCommands.isEmpty {
                SlashSuggestionsOverlay(
                    commands: filteredSlashCommands,
                    onSelected: { cmd in
                        text = "/\(cmd.name) "
                        isShowingSlashSuggestions = false
                    }
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
                attachmentButton
                voiceButton

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
                        returnKeySends: returnKeySends,
                        // May lag one render behind fast typing; the safe
                        // failure mode is newline insertion, and
                        // submitFromReturnKey() re-checks the live gate.
                        canSubmitFromReturn: ComposerReturnKey.canSubmit(action: action),
                        onSubmitFromReturn: { submitFromReturnKey() }
                    )
                    .id(editorIdentity)
                    .padding(.horizontal, 5)
                    .frame(height: composerTextHeight)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(fieldFoundation, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(fieldStroke, lineWidth: 1)
                }
                .animation(ConduitMotion.response, value: isFocused)

                composerAction
            }
            .padding(10)
        }
        .background(composerFoundation, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(composerStroke, lineWidth: 1)
        }
        .opacity(appState.turnState == .unsupportedGateway ? 0.7 : 1)
        .animation(ConduitMotion.transition, value: action)
        .preferredColorScheme(appState.themePreference.colorScheme)
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
                 ? "Update this Hermes gateway to recover active turns safely."
                 : "Synchronizing with Hermes before enabling chat controls")
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

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: attachment.kind == .image ? "photo" : "doc")
                            .font(.caption)
                        Text(attachment.name)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            Haptics.light()
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .disabled(!appState.composerIsEnabled)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .conduitGlassSurface(cornerRadius: 16, tint: .conduitAccent.opacity(0.07))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
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
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .disabled(!appState.composerIsEnabled || appState.isBusy)
        .conduitGlassControl(cornerRadius: 22, tint: .conduitAccent.opacity(0.08))
        .photosPicker(isPresented: $showAttachmentMenu, selection: $photoItem)
    }

    @ViewBuilder
    private var composerAction: some View {
        if #available(iOS 26.0, *) {
            composerActionButton
                .glassEffectID("composer-action", in: glassNamespace)
        } else {
            composerActionButton
        }
    }

    private var composerActionButton: some View {
        Button {
            if stopOnly {
                dismissComposer()
                Haptics.warning()
                Task { await appState.cancelCurrent() }
            } else {
                submit()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: actionSymbol)
                    .font(.system(size: stopOnly ? 14 : 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                if let actionTitle {
                    Text(actionTitle)
                        .font(.caption.weight(.semibold))
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .foregroundStyle(action == .unavailable ? Color.secondary.opacity(0.48) : Color.white)
            .frame(minWidth: actionTitle == nil ? 44 : 94, minHeight: 44)
            .padding(.horizontal, actionTitle == nil ? 0 : 4)
            .animation(ConduitMotion.transition, value: action)
        }
        .disabled(action == .unavailable)
        .conduitGlassControl(
            cornerRadius: 22,
            tint: actionSurfaceTint,
            prominent: action == .send,
            interactive: action != .unavailable
        )
        .accessibilityLabel(accessibilityLabel)
    }

    private var sessionControls: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.selection()
                appState.showModelPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .foregroundStyle(Color.conduitAccent)
                        .symbolEffect(
                            .variableColor.iterative,
                            options: .repeating,
                            isActive: appState.turnState == .running && !reduceMotion
                        )
                    Text(appState.runtime.model.isEmpty ? "Model" : appState.runtime.model)
                        .lineLimit(1)
                    if !appState.runtime.reasoningEffort.isEmpty {
                        Text("/")
                            .foregroundStyle(.secondary)
                        Text(formatEffort(appState.runtime.reasoningEffort))
                            .foregroundStyle(Color.conduitAccent)
                            .lineLimit(1)
                    }
                    if appState.runtime.yolo {
                        Image(systemName: "shield.slash.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.orange)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(modelAccessibilityLabel)

            Button {
                Haptics.selection()
                appState.showContextSheet = true
            } label: {
                HStack(spacing: 5) {
                    ContextRingView(percent: appState.runtime.contextPercent)
                        .frame(width: 32, height: 32)
                }
                .frame(minWidth: 36, minHeight: 36)
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
                        .frame(minWidth: 36, minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delegate agents, \(appState.activeAgents) active")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 1)
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
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        let submittedText = text
        let submittedAttachments = attachments
        let submittedAction = action
        let prefillToken = appState.composerPrefillToken
        let submittedDraftKey = loadedDraftKey ?? activeDraftKey
        let submittedDraftBucket = draftStore.submissionBucket(for: submittedDraftKey)
        let submissionContext = appState.composerSubmissionContext()
        rotateAttachmentGeneration()
        collapseSubmittedDraft()

        switch submittedAction {
        case .send: Haptics.medium()
        case .steer: Haptics.light()
        case .interrupt: Haptics.warning()
        case .stop, .unavailable: break
        }

        Task {
            let didSubmit = await appState.submitComposer(
                text: trimmed,
                attachments: submittedAttachments,
                context: submissionContext
            )
            guard didSubmit else {
                restoreSubmittedDraftIfNeeded(
                    text: submittedText,
                    attachments: submittedAttachments,
                    for: submittedDraftKey
                )
                Haptics.error()
                return
            }
            draftStore.removeDraft(for: submittedDraftBucket)
            guard loadedDraftKey == submittedDraftKey else { return }
            if appState.composerPrefillToken != prefillToken {
                text = appState.composerPrefillText
                isFocused = !text.isEmpty
            }
            isShowingSlashSuggestions = slashPrefix != nil
        }
    }

    private var voiceButton: some View {
        Button {
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
        } label: {
            Image(systemName: appState.canStartVoiceConversation ? "mic.fill" : "mic.slash")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .disabled(!appState.canStartVoiceConversation || appState.isBusy || !appState.composerIsEnabled)
        .conduitGlassControl(
            cornerRadius: 22,
            tint: appState.canStartVoiceConversation ? .conduitAura.opacity(0.14) : .secondary.opacity(0.06),
            interactive: appState.canStartVoiceConversation
        )
        .accessibilityLabel("Start voice conversation")
        .accessibilityHint(appState.voiceUnavailableReason ?? "Opens voice controls over this conversation")
    }

    /// Collapse the draft in the same transaction that dismisses the keyboard.
    /// Waiting for the gateway RPC leaves the side controls aligned to the old
    /// multiline field while the keyboard's safe area is already animating.
    private func collapseSubmittedDraft() {
        dismissComposer()
        let updates = {
            text = ""
            attachments = []
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
                ComposerDraft(text: submittedText, attachments: submittedAttachments),
                for: restorationKey
            )
            return
        }
        // Do not overwrite a new draft if the user already returned to the
        // composer while the failed request was in flight.
        guard text.isEmpty, attachments.isEmpty else { return }
        text = submittedText
        attachments = submittedAttachments
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
        photoImportContext = asyncAttachmentContext
        photoImportGeneration &+= 1
        showAttachmentMenu = true
    }

    private func saveDraft(for key: ComposerDraftKey) {
        draftStore.save(ComposerDraft(text: text, attachments: attachments), for: key)
    }

    private func loadDraft(for key: ComposerDraftKey) {
        let draft = draftStore.draft(for: key)
        if text != draft.text {
            suppressNextTextChangeSuggestions = true
        }
        text = draft.text
        attachments = draft.attachments
        loadedDraftKey = key
        composerTextHeight = ComposerPasteTextView.minimumHeight
        isFocused = false
        isShowingSlashSuggestions = false
    }

    private func handoffComposer(to destinationKey: ComposerDraftKey) {
        guard loadedDraftKey != destinationKey else { return }
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
        photoItem = nil
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

    private func handlePhotoSelection() {
        guard let item = photoItem else { return }
        guard let origin = photoImportContext else {
            photoItem = nil
            return
        }
        let completionGeneration = photoImportGeneration
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               shouldAcceptPhotoPickerCompletion(openedIn: origin) {
                addAttachment(data: data, name: "photo.jpg", mimeType: "image/jpeg", kind: .image)
            }
            clearPhotoImportContextIfCurrent(
                completingGeneration: completionGeneration,
                completingContext: origin
            )
        }
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
        photoItem = nil
        photoImportContext = nil
    }

    private func handleDocumentSelection(
        _ result: Result<[URL], Error>,
        startedIn origin: AsyncAttachmentContext?
    ) {
        guard let origin,
              shouldAcceptAsyncAttachmentCompletion(startedIn: origin) else { return }
        guard case .success(let urls) = result else { return }
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            addAttachment(
                data: data,
                name: url.lastPathComponent,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                kind: type?.conforms(to: .image) == true ? .image : .document
            )
        }
    }

    private func clearDocumentImportContextIfCurrent(_ completingContext: AsyncAttachmentContext?) {
        guard documentImportContext == completingContext else { return }
        documentImportContext = nil
    }

    private func addAttachment(data: Data, name: String, mimeType: String, kind: Attachment.Kind) {
        guard !data.isEmpty else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hermes-Conduit-Attachments", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
            try data.write(to: url, options: .atomic)
            attachments.append(Attachment(id: UUID().uuidString, name: name, uri: url.absoluteString, mimeType: mimeType, kind: kind))
            Haptics.light()
        } catch {
            appState.errorMessage = "Could not prepare \(name) for upload."
            Haptics.error()
        }
    }

    private func formatEffort(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "none" || lower == "off" { return "Off" }
        if lower == "xhigh" { return "Extra High" }
        return lower.capitalized
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    private var accessibilityLabel: String {
        switch action {
        case .stop: return "Stop response"
        case .steer: return "Steer with message"
        case .interrupt: return "Interrupt and correct response"
        case .send: return "Send message"
        case .unavailable: return "Composer unavailable"
        }
    }

    private var modelAccessibilityLabel: String {
        let model = appState.runtime.model.isEmpty ? "Model" : appState.runtime.model
        let reasoning = appState.runtime.reasoningEffort.isEmpty
            ? "reasoning not set"
            : "reasoning \(formatEffort(appState.runtime.reasoningEffort))"
        let approvals = appState.runtime.yolo ? ", auto-approve enabled" : ""
        let activity = appState.turnState == .running ? ", agent working" : ""
        return "\(model), \(reasoning)\(approvals)\(activity)"
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
            Text("\(Int(percent.rounded()))%")
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
