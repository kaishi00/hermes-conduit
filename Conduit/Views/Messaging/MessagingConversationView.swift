import SwiftUI

struct MessagingConversationView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var owner: MessagingStore
    @StateObject private var model: MessagingConversationStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sizeCategory) private var sizeCategory
    @AppStorage(ChatTypography.preferenceKey) private var chatTextSizeRaw = ChatTypography.defaultSize.rawValue
    @State private var recipients: Set<String> = []
    @State private var showMembers = false
    @State private var showRuns = false
    @State private var confirmDeleteGroup = false
    @State private var viewport = ChatViewportController()
    @State private var bottomMarkerMaxY: CGFloat?
    @State private var scrollViewportFrame: CGRect?
    @State private var renderedScrollTargets = ChatRenderedScrollTargets()
    @State private var transcriptRevision: UInt64 = 0
    @State private var armedAnimatedBottomRetry: ChatViewportCommand?
    @State private var backfillViewportTask: Task<Void, Never>?
    @State private var scrollToLatestPulse = 0
    @GestureState private var isDraggingTranscript = false
    /// When true, the conversation host owns navigation chrome (Back / title).
    var embedsInHost: Bool = false
    var onClose: (() -> Void)? = nil
    let openSessions: (String) -> Void

    init(
        destination: MessagingDestination,
        owner: MessagingStore,
        embedsInHost: Bool = false,
        onClose: (() -> Void)? = nil,
        openSessions: @escaping (String) -> Void
    ) {
        self.owner = owner
        self.embedsInHost = embedsInHost
        self.onClose = onClose
        _model = StateObject(wrappedValue: MessagingConversationStore(destination: destination, owner: owner))
        self.openSessions = openSessions
    }

    private var chatTextSize: ChatTextSize {
        ChatTypography.resolve(rawValue: chatTextSizeRaw)
    }

    private var title: String {
        model.history?.conversation.title
            ?? owner.profiles.first { $0.id == model.destination.profileID }?.displayName
            ?? "Messages"
    }

    private var scrollSessionKey: ChatScrollSessionKey {
        MessagingConversationChrome.sessionKey(for: model.destination)
    }

    private var scrollIdentity: ChatScrollSessionIdentity {
        MessagingConversationChrome.identity(for: model.destination)
    }

    private var followsLatest: Bool { viewport.isFollowingLatest }

    private var isNearBottom: Bool {
        guard let bottomMarkerMaxY, let viewportMaxY = scrollViewportFrame?.maxY else { return true }
        return bottomMarkerMaxY <= viewportMaxY + 40
    }

    private var topAnchor: String {
        ChatTitleScrollAnchor.id(for: scrollSessionKey)
    }

    private var bottomAnchor: String {
        "chat-latest-\(scrollSessionKey.profile)-\(scrollSessionKey.sessionID)"
    }

    private var transcriptMessages: [ChatMessage] {
        (model.history?.messages ?? []).map(chatMessage(from:))
    }

    private var messagesByID: [String: MessagingMessage] {
        Dictionary((model.history?.messages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    private var renderedScrollScope: ChatRenderedScrollScope? {
        viewport.renderedScrollScope
    }

    var body: some View {
        Group {
            if embedsInHost {
                conversationBody
            } else {
                NavigationStack {
                    conversationBody
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { standaloneToolbar }
                }
            }
        }
        .environment(\.chatTextSize, chatTextSize)
        .sheet(isPresented: $showMembers) {
            if let conversation = model.history?.conversation {
                MessagingGroupSettingsSheet(model: model, owner: owner, conversation: conversation)
            }
        }
        .sheet(isPresented: $showRuns) {
            NavigationStack {
                List(model.history?.runs ?? []) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profileName(run.profile)).font(.headline)
                        Text(run.status.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.secondary)
                        if !run.detail.isEmpty { Text(run.detail).font(.footnote) }
                        if ["queued", "running"].contains(run.status) {
                            Button("Cancel run", role: .destructive) { Task { await model.cancelRun(run.id) } }
                        }
                    }
                }.navigationTitle("Runs")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showRuns = false } } }
            }
        }
        .alert("Delete this group?", isPresented: $confirmDeleteGroup) {
            Button("Delete group", role: .destructive) {
                Task {
                    if await model.deleteGroup() { close() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Messages and session bindings for this group are removed. Hermes chat history is kept.")
        }
        .onChange(of: model.draft) { _, _ in model.saveDraft() }
        .onChange(of: owner.generation) { _, _ in close() }
        .task(id: "\(scenePhase)-\(model.prefersUrgentPolling)") {
            guard scenePhase == .active else { return }
            if model.pending != nil { await model.checkDelivery() }
            while !Task.isCancelled {
                await model.load()
                do { try await Task.sleep(for: model.historyPollInterval) } catch { return }
            }
        }
    }

    private var conversationBody: some View {
        VStack(spacing: 0) {
            if embedsInHost {
                HStack {
                    Spacer(minLength: 0)
                    messagingActionsMenu
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            if !model.canWrite { Text(owner.availability.explanation).font(.footnote).padding() }
            ScrollViewReader { proxy in
                messagingObservers(
                    proxy: proxy,
                    content: messagingScrollView(proxy: proxy)
                )
            }
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            activeRunPresence
            if model.history?.conversation.archived == true {
                Button("Reopen conversation") { Task { await model.updateUserState(["archived": false]) } }.padding()
            } else {
                composer
            }
        }
        .background(Color.conduitCanvas)
    }

    private func messagingScrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Color.clear
                    .frame(height: 1)
                    .id(topAnchor)

                if model.history?.before != nil {
                    Button {
                        let armedKey = viewport.renderedSessionKey ?? scrollSessionKey
                        viewport.olderPageBackfillRequested(
                            anchorMessageID: viewport.stableTopMessageID,
                            sessionKey: armedKey
                        )
                        backfillViewportTask?.cancel()
                        backfillViewportTask = Task { @MainActor in
                            let front = model.history?.messages.first?.id
                            await model.load(older: true)
                            guard !Task.isCancelled else { return }
                            if model.history?.messages.first?.id == front {
                                viewport.prependAnchorDischarged(matching: armedKey)
                            }
                        }
                    } label: {
                        Label("Load earlier messages", systemImage: "clock.arrow.circlepath")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.12))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                if model.history?.messages.isEmpty != false {
                    ContentUnavailableView(
                        "Message \(title)",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("This conversation stays here as your bot starts new runs.")
                    )
                }

                ForEach(viewport.targets) { target in
                    if let message = messagesByID[target.id] {
                        messagingBubble(message)
                            .id(target.id)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: ChatRenderedScrollTargetsPreferenceKey.self,
                                        value: renderedScrollScope.map {
                                            ChatRenderedScrollTargets.row(
                                                semanticID: target.id,
                                                scope: $0,
                                                frame: geometry.frame(in: .global),
                                                order: target.order
                                            )
                                        } ?? ChatRenderedScrollTargets()
                                    )
                                }
                            }
                            .background(GeometryReader { geometry in
                                Color.clear.preference(
                                    key: MessagingVisibleMessages.self,
                                    value: [message.sequence: geometry.frame(in: .named("messagingScroll"))]
                                )
                            })
                    }
                }

                Color.clear
                    .frame(height: 1)
                    .padding(.bottom, 126)
                    .id(bottomAnchor)
                    .background {
                        GeometryReader { _ in
                            Color.clear.preference(
                                key: ChatRenderedScrollTargetsPreferenceKey.self,
                                value: renderedScrollScope.map {
                                    ChatRenderedScrollTargets.bottom(
                                        anchorID: bottomAnchor,
                                        scope: $0
                                    )
                                } ?? ChatRenderedScrollTargets()
                            )
                        }
                    }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .preference(
                            key: ChatBottomMarkerPreferenceKey.self,
                            value: geometry.frame(in: .global).maxY
                        )
                        .preference(
                            key: ChatRenderedScrollContentPreferenceKey.self,
                            value: renderedScrollScope.map(ChatRenderedScrollContent.init(scope:))
                        )
                }
            }
        }
        .coordinateSpace(name: "messagingScroll")
        .conversationKeyboardDismissal()
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ChatViewportFramePreferenceKey.self,
                    value: geometry.frame(in: .global)
                )
            }
        }
        .simultaneousGesture(messagingDragGesture(proxy: proxy))
        .overlay(alignment: .bottomTrailing) {
            if !followsLatest && !isNearBottom {
                ScrollToLatestButton {
                    ChatViewportTrace.shared.log("event explicitLatest (button)")
                    performViewportEffects(viewport.explicitLatestRequested(), using: proxy)
                }
            }
        }
        .onPreferenceChange(MessagingVisibleMessages.self) { frames in
            guard scenePhase == .active else { return }
            let viewportHeight = scrollViewportFrame?.height ?? 0
            if let sequence = frames.filter({ $0.value.maxY > 0 && $0.value.maxY <= viewportHeight + 40 }).keys.max() {
                Task { await model.markRead(through: sequence) }
            }
        }
    }

    private func messagingObservers(proxy: ScrollViewProxy, content: some View) -> some View {
        content
            .onAppear {
                performViewportEffects(
                    viewport.renderedSessionChanged(
                        to: scrollSessionKey,
                        identity: scrollIdentity,
                        viaNotification: false,
                        viewportTransitionGeneration: 1
                    ),
                    using: proxy
                )
                performViewportEffects(
                    viewport.transcriptChanged(
                        messages: transcriptMessages,
                        transcriptRevision: transcriptRevision,
                        viewportTransitionGeneration: 1,
                        isInitialSync: true
                    ),
                    using: proxy
                )
            }
            .onDisappear {
                backfillViewportTask?.cancel()
                performViewportEffects(viewport.viewDisappeared(), using: proxy)
            }
            .onPreferenceChange(ChatBottomMarkerPreferenceKey.self) { value in
                bottomMarkerMaxY = value
                performViewportEffects(
                    viewport.layoutMetricsChanged(facts: currentLayoutFacts()),
                    using: proxy
                )
            }
            .onPreferenceChange(ChatViewportFramePreferenceKey.self) { value in
                scrollViewportFrame = value
                performViewportEffects(
                    viewport.layoutMetricsChanged(facts: currentLayoutFacts()),
                    using: proxy
                )
            }
            .onPreferenceChange(ChatRenderedScrollTargetsPreferenceKey.self) { value in
                renderedScrollTargets = value
                performViewportEffects(
                    viewport.layoutMetricsChanged(facts: currentLayoutFacts()),
                    using: proxy
                )
            }
            .onChange(of: isDraggingTranscript) { wasDragging, isDragging in
                guard wasDragging, !isDragging else { return }
                performViewportEffects(viewport.userDragGestureEnded(), using: proxy)
            }
            .onChange(of: viewport.pendingFollowCorrection) { _, pending in
                guard let pending else { return }
                executePendingFollowCorrection(pending, using: proxy)
            }
            .onChange(of: model.history?.messages) { _, _ in
                transcriptRevision &+= 1
                performViewportEffects(
                    viewport.transcriptChanged(
                        messages: transcriptMessages,
                        transcriptRevision: transcriptRevision,
                        viewportTransitionGeneration: 1,
                        activeSessionKey: scrollSessionKey
                    ),
                    using: proxy
                )
            }
            .onChange(of: scrollToLatestPulse) { _, _ in
                performViewportEffects(viewport.explicitLatestRequested(), using: proxy)
            }
    }

    private func currentLayoutFacts() -> ChatViewportLayoutFacts {
        let scope = renderedScrollScope
        let frames: [ChatRenderedRowFrame]
        if let scope {
            frames = renderedScrollTargets.rowFrames(in: scope).map { id, geometry in
                ChatRenderedRowFrame(
                    id: id,
                    minY: geometry.frame.minY,
                    maxY: geometry.frame.maxY,
                    order: geometry.order,
                    scope: scope
                )
            }
        } else {
            frames = []
        }
        return ChatViewportLayoutFacts(
            bottomMarkerMaxY: bottomMarkerMaxY,
            viewportMinY: scrollViewportFrame?.minY,
            viewportMaxY: scrollViewportFrame?.maxY,
            rowFrames: frames,
            renderedScope: scope,
            timestamp: CFAbsoluteTimeGetCurrent()
        )
    }

    private func messagingDragGesture(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($isDraggingTranscript) { _, isDragging, _ in
                isDragging = true
            }
            .onChanged { _ in
                performViewportEffects(
                    viewport.userDragBegan(
                        sessionKey: viewport.renderedSessionKey ?? scrollSessionKey,
                        viewportTransitionGeneration: 1
                    ),
                    using: proxy
                )
            }
    }

    @MainActor
    private func performViewportEffects(
        _ effects: [ChatViewportEffect],
        using proxy: ScrollViewProxy
    ) {
        for effect in effects {
            switch effect {
            case .scroll(let command):
                executeViewportScrollCommand(command, using: proxy)
            case .scheduleDragEvaluation(let token):
                Task { @MainActor in
                    await ChatViewportPersistenceSupport.waitForNextMainActorTurn()
                    guard !Task.isCancelled else { return }
                    performViewportEffects(
                        viewport.evaluateDragCompletion(
                            token,
                            viewportTransitionGeneration: 1
                        ),
                        using: proxy
                    )
                }
            case .scheduleFollowCorrection:
                break
            case .cancelAutomaticRestoration, .persistViewportSnapshot, .flushViewportPersistence,
                 .completeRestoration, .abandonRestoration:
                break
            }
        }
    }

    @MainActor
    private func executePendingFollowCorrection(
        _ token: ChatFollowCorrectionToken,
        using proxy: ScrollViewProxy
    ) {
        if armedAnimatedBottomRetry != nil {
            _ = viewport.followCorrectionDue(token)
            return
        }
        performViewportEffects(viewport.followCorrectionDue(token), using: proxy)
    }

    @MainActor
    private func executeViewportScrollCommand(
        _ command: ChatViewportCommand,
        using proxy: ScrollViewProxy
    ) {
        ConversationViewportScrolling.run(command, using: proxy)
        guard case .delayed(let milliseconds) = command.retry else { return }
        if case .bottom = command.destination {
            armedAnimatedBottomRetry = command
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            if armedAnimatedBottomRetry == command {
                armedAnimatedBottomRetry = nil
            }
            guard !Task.isCancelled, viewport.isCommandCurrent(command) else { return }
            ConversationViewportScrolling.run(command, using: proxy)
        }
    }

    @ViewBuilder
    private func messagingBubble(_ message: MessagingMessage) -> some View {
        let chat = chatMessage(from: message)
        if message.author == "user" {
            UserBubble(message: chat, gatewayResolver: nil)
        } else if let profile = owner.profiles.first(where: { $0.id == message.author }) {
            SettledAssistantMessageContent(
                message: chat,
                displayName: profile.displayName,
                avatarURL: appState.profileAvatarURL(for: profile.name),
                profileID: profile.name,
                gatewayResolver: nil,
                sizeCategory: sizeCategory,
                chatTextSize: chatTextSize
            )
            .equatable()
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            SettledAssistantMessageContent(
                message: chat,
                displayName: profileName(message.author),
                avatarURL: nil,
                profileID: message.author,
                gatewayResolver: nil,
                sizeCategory: sizeCategory,
                chatTextSize: chatTextSize
            )
            .equatable()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chatMessage(from message: MessagingMessage) -> ChatMessage {
        ChatMessage(
            id: message.id,
            role: message.author == "user" ? .user : .assistant,
            content: MessagingMentionDisplay.rewriteBody(message.body, profiles: owner.profiles),
            timestamp: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: message.createdAt)),
            author: message.author == "user" ? nil : message.author
        )
    }

    @ToolbarContentBuilder
    private var standaloneToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Bots") { close() }
        }
        ToolbarItem(placement: .primaryAction) {
            messagingActionsMenu
        }
    }

    private var messagingActionsMenu: some View {
        HStack {
            if participants.count == 1, let profile = participants.first {
                Button("Sessions") { openSessions(profile.name) }
            }
            Menu {
                ForEach(participants) { profile in
                    Button("\(profile.displayName) sessions") { openSessions(profile.name) }
                }
                Button("Runs") { showRuns = true }
                if let conversation = model.history?.conversation {
                    if conversation.kind == "group" {
                        Button("Members and group settings") { showMembers = true }
                    }
                    Button(conversation.pinned ? "Unpin" : "Pin") {
                        Task { await model.updateUserState(["pinned": !conversation.pinned]) }
                    }
                    Button(conversation.muted ? "Unmute" : "Mute") {
                        Task { await model.updateUserState(["muted": !conversation.muted]) }
                    }
                    Button(conversation.archived ? "Reopen" : "Archive (work continues)") {
                        Task { await model.updateUserState(["archived": !conversation.archived]) }
                    }
                    if conversation.kind == "group" {
                        Button("Delete group", role: .destructive) {
                            confirmDeleteGroup = true
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Conversation actions")
        }
    }

    private var participants: [MessagingProfile] {
        let ids = model.history?.conversation.profiles ?? model.destination.profileID.map { [$0] } ?? []
        return owner.profiles.filter { ids.contains($0.id) }
    }

    private func profileName(_ id: String) -> String {
        owner.profiles.first { $0.id == id }?.displayName ?? id
    }

    private func close() {
        if embedsInHost {
            onClose?()
        } else {
            dismiss()
        }
    }

    private var activePresence: [MessagingRunPresence.Item] {
        MessagingRunPresence.collapsed(model.history?.runs ?? [])
    }

    @ViewBuilder
    private var activeRunPresence: some View {
        let items = activePresence
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ForEach(items) { item in
                        presenceMark(for: item)
                    }
                    Spacer(minLength: 0)
                }
                ForEach(items.filter(\.showsDetail)) { item in
                    Text(item.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("messaging.run-presence")
        } else if model.awaitingReply {
            HStack {
                MessagingAwaitingReplyDots()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
    }

    private func presenceMark(for item: MessagingRunPresence.Item) -> some View {
        let profile = owner.profiles.first { $0.id == item.profile }
        let displayName = profile?.displayName ?? profileName(item.profile)
        let profileID = profile?.name ?? item.profile
        return ConduitAgentMark(
            isActive: true,
            avatarURL: appState.profileAvatarURL(for: profileID),
            displayName: displayName,
            profileID: profileID,
            state: item.avatarState
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName) is \(item.accessibilityPhrase)")
        .accessibilityIdentifier("messaging.run-presence.\(item.profile)")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.history?.conversation.kind == "group" {
                Menu {
                    ForEach(participants) { profile in
                        Toggle(profile.displayName, isOn: Binding(get: { recipients.contains(profile.id) }, set: { value in
                            if value { recipients.insert(profile.id) } else { recipients.remove(profile.id) }
                        }))
                    }
                } label: {
                    Label(
                        recipients.isEmpty
                            ? "To: Auto"
                            : "To: " + recipients.sorted().map(profileName).joined(separator: ", "),
                        systemImage: "at"
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.conduitPrimaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.conduitRaisedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityLabel("Choose responders")
            }
            if model.pending != nil {
                Button("Check delivery") { Task { await model.checkDelivery() } }
                    .disabled(model.sending || !model.canWrite)
            }
            ComposerBar(
                showsModelPicker: false,
                messaging: MessagingComposerAdapter(
                    placeholder: "Message \(title)…",
                    canWrite: model.canWrite,
                    isSending: model.sending,
                    hasPending: model.pending != nil,
                    editorAccessibilityIdentifier: "messaging.composer",
                    draftKey: MessagingConversationChrome.draftKey(for: model.destination),
                    seedDraft: model.draft,
                    onDraftChange: { model.draft = $0 },
                    onSend: { text in
                        let ok = await model.send(recipients: recipients.sorted(), text: text)
                        if ok { scrollToLatestPulse &+= 1 }
                        return ok
                    }
                )
            )
        }
        .background(Color.conduitCanvas.opacity(0.98))
    }
}

private struct MessagingVisibleMessages: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
