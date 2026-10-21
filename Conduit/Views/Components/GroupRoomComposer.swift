//
//  GroupRoomComposer.swift
//  Conduit
//
//  A group chat room's composer: the chat composer's card, attach menu and
//  dictation, without what only a session has (model, context ring, voice,
//  slash commands). It sends through `groups.send`; files go up through the
//  host's plugin first, since a room has no session to stage them in.
//

import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct GroupRoomComposer: View {
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let members: [GroupMember]

    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @FocusState private var isFocused: Bool
    @State private var isUploading = false
    /// The upload in flight, cancelled when the composer goes away.
    @State private var uploadTask: Task<Void, Never>?
    @State private var composerError: String?
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showDocumentPicker = false
    @State private var showCamera = false
    @State private var isShowingFullEditor = false
    @StateObject private var dictation = ComposerDictationService()
    /// The draft as it was when dictation began; dictated text goes after it.
    @State private var dictationPrefix = ""
    /// The draft as dictation last wrote it, to tell its writes from typing.
    @State private var dictatedDraft: String?
    @AppStorage(AttachmentSizeLimit.preferenceKey) private var attachmentLimitMegabytes = AttachmentSizeLimit.defaultMegabytes

    private let controlSize = ComposerBar.controlSize

    private var surface: AppState.GroupRoomSurface? { appState.activeRoomSurface }

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the room takes a message at all right now.
    private var roomAccepts: Bool {
        !appState.activeRoomSendInFlight
            // An ambiguous-outcome pending message owns the composer: retry
            // it explicitly (same event id) or it stays visible — a NEW
            // message typed meanwhile would be silently swallowed.
            && appState.pendingRoomMessage == nil
            && appState.groupCapabilities?.supports("groups.send") == true
            && surface?.room.isDisbanded == false
    }

    private var canSend: Bool {
        (hasText || !attachments.isEmpty) && roomAccepts && !isUploading
    }

    private var isDictationActive: Bool {
        dictation.isCapturing || dictation.isStarting || dictation.isTranscribing
    }

    /// Resting, it is one slim bar: attach beside the field. Anything in
    /// progress opens the controls row under the field.
    private var rests: Bool {
        !isFocused && !hasText && attachments.isEmpty && !isDictationActive && !isUploading
            && composerError == nil
    }

    private var mentionCandidates: [MentionAutocomplete.Candidate] {
        guard isFocused, let query = MentionAutocomplete.activeQuery(in: draft) else { return [] }
        return MentionAutocomplete.filter(MentionAutocomplete.roomCandidates(members), query: query)
    }

    /// Solid, so the chat scrolling under the composer never shows
    /// through what is being typed.
    private var foundation: Color {
        colorScheme == .dark
            ? Color(red: 0.072, green: 0.080, blue: 0.106)
            : Color.white
    }

    private var stroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.09)
    }

    var body: some View {
        VStack(spacing: 0) {
            notices
            if !mentionCandidates.isEmpty {
                MentionSuggestionList(candidates: mentionCandidates) { candidate in
                    draft = MentionAutocomplete.completing(draft, with: candidate)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !attachments.isEmpty {
                attachmentStrip
            }
            HStack(alignment: .bottom, spacing: 2) {
                if rests {
                    attachButton
                        .padding(.leading, 6)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }
                field
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, rests ? 6 : 0)
            if !rests {
                controlsRow
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(foundation, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
        }
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: rests)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: mentionCandidates.isEmpty)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        // The view is keyed by room, so appear/change bracket exactly one
        // room: the draft comes back on reopen and is kept as it changes.
        .onAppear { draft = appState.activeRoomDraft() }
        .onChange(of: draft) { _, text in
            appState.saveActiveRoomDraft(text)
            composerError = nil
            // Typing ends a dictation; the words so far stay.
            if ComposerDictation.isTyping(text, dictationWrote: dictatedDraft), isDictationActive {
                dictatedDraft = nil
                dictation.yieldToTyping()
            }
        }
        .onChange(of: appState.isVoiceInUse) { _, inUse in
            // Voice took the microphone: dictation steps aside.
            if inUse { dictation.cancel() }
        }
        .onDisappear {
            dictation.cancel()
            uploadTask?.cancel()
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: ComposerBar.photoPickerSelectionLimit,
            selectionBehavior: .ordered,
            matching: .any(of: [.images, .videos])
        )
        .conduitOutOfProcessAccentTint()
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            importPhotos(items)
        }
        .fileImporter(
            isPresented: $showDocumentPicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            importDocuments(result)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture { image in
                importCapturedPhoto(image)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingFullEditor) {
            ComposerFullEditor(
                text: $draft,
                placeholder: AppLocalization.string("Message the room"),
                enabled: true,
                onUserEdit: { _ in },
                onCollapse: { isShowingFullEditor = false },
                attachments: {
                    if !attachments.isEmpty { attachmentStrip }
                },
                dictateButton: { dictateButton },
                actionButton: { sendButton }
            )
            .preferredColorScheme(appState.themePreference.colorScheme)
            .environmentObject(appState)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var notices: some View {
        if appState.activeRoomSendInFlight, appState.pendingRoomMessage == nil {
            // A poll can show the message delivered before the send's own
            // answer returns; Send stays off until it does.
            notice(AppLocalization.string("Sending…"), color: .secondary)
        }
        if isUploading {
            notice(AppLocalization.string("Uploading files…"), color: .secondary)
        }
        if appState.pendingRoomMessage != nil, !appState.activeRoomSendInFlight {
            // The pending row owns the composer; say why Send is off
            // instead of leaving a silently disabled button.
            notice(AppLocalization.string(
                "Your previous message is still pending. Retry it from the room, or wait for it to deliver."
            ), color: .secondary)
        }
        // The session surface's error banner lives inside ChatView, which
        // this room surface replaces: room errors must render here.
        if let error = composerError ?? appState.errorMessage, !error.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if error == ComposerBar.cameraAccessMessage {
                    Button(AppLocalization.string("Open Settings")) {
                        composerError = nil
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }

    private var showsExpand: Bool {
        draft.count > 240 || draft.filter({ $0 == "\n" }).count >= 3
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
    }

    private var field: some View {
        TextField(AppLocalization.string("Message the room"), text: $draft, axis: .vertical)
            .lineLimit(1...6)
            .focused($isFocused)
            .padding(.leading, 12)
            // Clear of the expand button once it shows.
            .padding(.trailing, showsExpand ? 44 : 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("room.composer.field")
            .overlay(alignment: .topTrailing) {
                if showsExpand {
                    Button {
                        Haptics.selection()
                        isFocused = false
                        isShowingFullEditor = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(AppLocalization.string("Expand editor")))
                    .transition(.opacity)
                }
            }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            attachButton
            Spacer(minLength: 0)
            dictateButton
            sendButton
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ComposerAttachmentChip(attachment: attachment, canRemove: !isUploading) {
                        attachments.removeAll { $0.id == attachment.id }
                        ComposerBar.discardStagedFile(attachment)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity)
        .clipShape(Rectangle())
    }

    @ViewBuilder
    private var attachButton: some View {
        let canAttach = appState.canAttachRoomFiles
        Menu {
            if canAttach {
                if CameraCapture.isAvailable {
                    Button {
                        openCamera()
                    } label: {
                        Label(AppLocalization.string("Camera"), systemImage: "camera")
                    }
                }
                Button {
                    Haptics.selection()
                    showPhotoPicker = true
                } label: {
                    Label(AppLocalization.string("Photo Library"), systemImage: "photo")
                }
                Button {
                    Haptics.selection()
                    showDocumentPicker = true
                } label: {
                    Label(AppLocalization.string("Document"), systemImage: "doc")
                }
            } else {
                // Older plugins can't store a room's files; say what fixes it.
                Text(AppLocalization.string("Update the Conduit plugin on your Hermes host to send files to group chats."))
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(canAttach ? Color.primary : Color.secondary)
                .frame(width: controlSize, height: controlSize)
                .contentShape(ComposerBar.controlHitShape)
        }
        .accessibilityLabel(Text(AppLocalization.string("Attach")))
        .disabled(isUploading)
        .conduitGlassControl(cornerRadius: controlSize / 2, tint: .conduitAccent.opacity(0.08))
        // The controls row is capped; touch and hold shows each control large.
        .accessibilityShowsLargeContentViewer {
            Label(AppLocalization.string("Attach"), systemImage: "plus")
        }
    }

    /// Tap to dictate into the draft, tap again to stop; the words are
    /// never sent on their own.
    private var dictateButton: some View {
        let canDictate = !appState.isVoiceInUse
        let isCapturing = dictation.isCapturing
        return Button {
            switch ComposerDictation.tap(
                isCapturing: dictation.isCapturing,
                isStarting: dictation.isStarting,
                canDictate: canDictate,
                isTranscribing: dictation.isTranscribing
            ) {
            case .start: beginDictation()
            case .stop: dictation.stop()
            case .cancelStart: dictation.cancel()
            case .nothing: break
            }
        } label: {
            Image(systemName: isCapturing ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isCapturing ? Color.red : (canDictate ? Color.primary : Color.secondary))
                .symbolEffect(.pulse, isActive: isDictationActive && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: controlSize, height: controlSize)
                .contentShape(ComposerBar.controlHitShape)
        }
        .buttonStyle(.plain)
        .disabled(!canDictate && !isDictationActive)
        .conduitGlassControl(
            cornerRadius: controlSize / 2,
            tint: isCapturing ? .red.opacity(0.16) : .primary.opacity(0.025),
            interactive: canDictate || isDictationActive
        )
        .accessibilityShowsLargeContentViewer {
            Label {
                dictateTitle(isCapturing: isCapturing)
            } icon: {
                Image(systemName: isCapturing ? "mic.fill" : "mic")
            }
        }
        .accessibilityLabel(dictateTitle(isCapturing: isCapturing))
    }

    private func dictateTitle(isCapturing: Bool) -> Text {
        if isCapturing { return Text(AppLocalization.string("Stop dictation")) }
        if dictation.isStarting { return Text(AppLocalization.string("Cancel dictation")) }
        if dictation.isTranscribing { return Text(AppLocalization.string("Transcribing")) }
        return Text(AppLocalization.string("Dictate"))
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            Group {
                if isUploading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(canSend || isUploading ? Color.white : Color.secondary.opacity(0.48))
            .frame(width: controlSize, height: controlSize)
            .contentShape(ComposerBar.controlHitShape)
        }
        .disabled(!canSend)
        .conduitGlassControl(
            cornerRadius: controlSize / 2,
            tint: canSend || isUploading ? Color.conduitAccent : Color.primary.opacity(0.025),
            prominent: canSend,
            interactive: canSend
        )
        .accessibilityShowsLargeContentViewer {
            Label(AppLocalization.string("Send"), systemImage: "arrow.up")
        }
        .accessibilityLabel(Text(AppLocalization.string("Send")))
        .accessibilityIdentifier("room.composer.send")
    }

    // MARK: - Sending

    private func send() {
        guard canSend else { return }
        let text = draft
        let files = attachments
        dictation.stop()
        Haptics.light()
        isShowingFullEditor = false
        if files.isEmpty {
            draft = ""
            Task {
                // The pending row owns the text only once AppState REGISTERS
                // the send. A declined send (connection or room changed
                // before the guards ran) hands the text back.
                let registered = await appState.sendGroupRoomMessage(text)
                if !registered {
                    // Anything typed since goes after the text handed back.
                    draft = draft.isEmpty ? text : text + "\n" + draft
                }
            }
            return
        }
        isUploading = true
        let roomID = surface?.room.roomID
        uploadTask = Task {
            defer { isUploading = false }
            let message: String
            do {
                message = try await appState.roomMessageText(text, attachments: files)
            } catch {
                if Task.isCancelled {
                    files.forEach(ComposerBar.discardStagedFile)
                    return
                }
                composerError = AppLocalization.string("Attachment failed: \(UserFacingError.message(for: error))")
                Haptics.error()
                return
            }
            // Left for another room while the files went up: they never go
            // to the room open now. The typed text stays in this room's
            // draft; the picked files went with the composer, so their local
            // copies are dropped.
            guard !Task.isCancelled, appState.activeRoomSurface?.room.roomID == roomID else {
                files.forEach(ComposerBar.discardStagedFile)
                return
            }
            // Uploaded: the composer hands over its text and files now, so a
            // second tap can't send them twice.
            // Typed on after it while the files went up: only the sent
            // text leaves the draft.
            let handedOver = !text.isEmpty && draft.hasPrefix(text)
            if handedOver {
                draft = String(draft.dropFirst(text.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            attachments.removeAll { file in files.contains { $0.id == file.id } }
            let registered = await appState.sendGroupRoomMessage(message)
            if registered {
                files.forEach(ComposerBar.discardStagedFile)
            } else {
                if handedOver, !text.isEmpty { draft = draft.isEmpty ? text : text + "\n" + draft }
                attachments = files + attachments
            }
        }
    }

    // MARK: - Dictation

    private func beginDictation() {
        guard let token = dictation.reserveStart() else { return }
        composerError = nil
        dictationPrefix = draft
        dictatedDraft = nil
        Haptics.medium()
        dictation.onTranscript = { transcript in
            let prefix: String
            if ComposerDictation.draftIsAsDictationLeftIt(draft, prefix: dictationPrefix, lastWrite: dictatedDraft) {
                prefix = dictationPrefix
            } else if dictation.isTranscribing {
                // Words that never reached the draft (a Hermes upload) go
                // after whatever it holds now.
                prefix = draft
                dictationPrefix = draft
            } else {
                dictation.cancel()
                return
            }
            let next = ComposerDictation.draft(before: prefix, dictated: transcript)
            dictatedDraft = next
            draft = next
        }
        dictation.onFinish = { _ in Haptics.light() }
        dictation.onFailure = { message in composerError = message }
        Task {
            do {
                try await dictation.start(token: token, hermesGateway: { appState.makeVoiceGateway() })
            } catch {
                composerError = UserFacingError.message(for: error)
            }
        }
    }

    // MARK: - Attachments

    private func openCamera() {
        composerError = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted { showCamera = true } else { showCameraAccessNotice() }
            }
        default:
            showCameraAccessNotice()
        }
    }

    private func showCameraAccessNotice() {
        composerError = ComposerBar.cameraAccessMessage
        Haptics.error()
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        let limit = GroupRoomFilesClient.stagingLimit(preference: attachmentLimitMegabytes)
        let roomID = surface?.room.roomID
        Task {
            var outcomes: [AttachmentStaging.StagedImport] = []
            for (index, item) in items.enumerated() {
                outcomes.append(await Task.detached(priority: .userInitiated) {
                    await ComposerBar.stagePickedItem(item, ordinal: index + 1, limitMegabytes: limit)
                }.value)
            }
            finishImport(outcomes, limitMegabytes: limit, roomID: roomID)
        }
    }

    private func importDocuments(_ result: Result<[URL], Error>) {
        let urls: [URL]
        switch result {
        case .success(let picked):
            urls = picked
        case .failure(let error):
            composerError = AppLocalization.string("Could not open the file: \(UserFacingError.message(for: error))")
            Haptics.error()
            return
        }
        let limit = GroupRoomFilesClient.stagingLimit(preference: attachmentLimitMegabytes)
        let roomID = surface?.room.roomID
        Task {
            var outcomes: [AttachmentStaging.StagedImport] = []
            for url in urls {
                outcomes.append(await Task.detached(priority: .userInitiated) {
                    ComposerBar.stageDocument(at: url, limitMegabytes: limit)
                }.value)
            }
            finishImport(outcomes, limitMegabytes: limit, roomID: roomID)
        }
    }

    private func importCapturedPhoto(_ image: UIImage) {
        let limit = GroupRoomFilesClient.stagingLimit(preference: attachmentLimitMegabytes)
        let roomID = surface?.room.roomID
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                ComposerBar.stageCapturedPhoto(image, limitMegabytes: limit)
            }.value
            finishImport([outcome], limitMegabytes: limit, roomID: roomID)
        }
    }

    /// One cue per selection: the error and its message when anything was
    /// left out, otherwise a light tap.
    private func finishImport(_ outcomes: [AttachmentStaging.StagedImport], limitMegabytes: Int, roomID: String?) {
        // Left the room while the files were staged: this composer is gone,
        // so their local copies are dropped.
        guard appState.activeRoomSurface?.room.roomID == roomID else {
            for case .staged(let attachment) in outcomes {
                ComposerBar.discardStagedFile(attachment)
            }
            return
        }
        var oversized: [String] = []
        var failed: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .staged(let attachment): attachments.append(attachment)
            case .tooLarge(let name): oversized.append(name)
            case .failed(let name): failed.append(name)
            }
        }
        var messages: [String] = []
        if !oversized.isEmpty {
            messages.append(AttachmentSizeLimit.tooLargeMessage(names: oversized, megabytes: limitMegabytes))
        }
        if !failed.isEmpty {
            let list = failed.joined(separator: ", ")
            messages.append(AppLocalization.string("Could not prepare \(list) for upload."))
        }
        if messages.isEmpty {
            if !outcomes.isEmpty { Haptics.light() }
        } else {
            composerError = messages.joined(separator: "\n")
            Haptics.error()
        }
    }
}
