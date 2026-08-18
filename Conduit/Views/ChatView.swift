//
//  ChatView.swift
//  Conduit
//
//  The main chat screen. This is THE APP — everything else is a drawer.
//

import SwiftUI
import UIKit
import ImageIO

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @State private var bottomMarkerMaxY: CGFloat?
    @State private var scrollViewportFrame: CGRect?
    @State private var topVisibleChatID: String?
    @State private var chatMessageScrollTargetCache = ChatMessageScrollTargetCache()
    @State private var renderedScrollSessionKey: ChatScrollSessionKey?
    @State private var renderedScrollContent: ChatRenderedScrollContent?
    @State private var renderedScrollTargets = ChatRenderedScrollTargets()
    @State private var renderedTranscriptRevision: UInt64 = 0
    @State private var renderedViewportTransitionGeneration: UInt64 = 0
    @State private var viewportSnapshotProviderID = UUID()
    @State private var viewport = ChatViewportController()
    // Legacy owner tokens for paths not yet migrated (session transitions,
    // notification handoff finish); Tasks 4-7 remove them.
    @State private var scrollOwnerState = ChatScrollOwnerState()
    @GestureState private var isDraggingChat = false
    @State private var notificationHandoffPending = false
    @State private var notificationHandoffSessionKey: ChatScrollSessionKey?
    @State private var notificationHandoffHasMeasuredLayout = false

    private var scrollViewportMaxY: CGFloat? { scrollViewportFrame?.maxY }

    private var scrollViewportMinY: CGFloat? { scrollViewportFrame?.minY }

    /// Single source of follow-latest truth: the controller's mode. Legacy
    /// writers go through `setLegacyFollowsLatest` until Tasks 4-6 migrate
    /// them; there is no independent followsLatest state anymore.
    private var followsLatest: Bool { viewport.isFollowingLatest }

    private var activeScrollSessionKey: ChatScrollSessionKey? {
        if let canonical = appState.activeChatScrollSessionIdentity.canonicalSessionKey {
            return canonical
        }
        guard let sessionID = appState.activeSessionId else { return nil }
        let fallback = ChatScrollSessionKey(
            profile: appState.activeProfile,
            sessionID: sessionID
        )
        return fallback.isValid ? fallback : nil
    }

    private var activeOrFallbackScrollSessionKey: ChatScrollSessionKey {
        activeScrollSessionKey ?? ChatScrollSessionKey(
            profile: appState.activeProfile,
            sessionID: "new"
        )
    }

    private var topAnchor: String {
        ChatTitleScrollAnchor.id(for: activeOrFallbackScrollSessionKey)
    }

    private var renderedTopAnchor: String {
        ChatTitleScrollAnchor.id(
            for: renderedScrollSessionKey ?? activeOrFallbackScrollSessionKey
        )
    }

    private var bottomAnchor: String {
        let scope = activeOrFallbackScrollSessionKey
        return "chat-latest-\(scope.profile)-\(scope.sessionID)"
    }

    private var isNearBottom: Bool {
        guard let bottomMarkerMaxY, let scrollViewportMaxY else { return true }
        return bottomMarkerMaxY <= scrollViewportMaxY + 40
    }

    private var hasPendingRestoration: Bool {
        appState.chatResumeRestorationRequest != nil
    }

    /// Latest global frames of rendered stable rows for the current scope.
    /// Only message rows report frames (streaming/typing/markers never do),
    /// so ephemeral identifiers cannot enter stable-top observation.
    private var renderedRowFrames: [String: CGRect] {
        guard let scope = renderedScrollScope else { return [:] }
        return renderedScrollTargets.rowFrames(in: scope)
    }

    /// First stable message row intersecting the viewport, in target order —
    /// the row-geometry replacement for reading `topVisibleChatID`.
    private var stableTopMessageID: String? {
        guard let viewportMinY = scrollViewportMinY,
              let viewportMaxY = scrollViewportMaxY else { return nil }
        for target in chatMessageScrollTargetCache.targets {
            guard let frame = renderedRowFrames[target.id] else { continue }
            if frame.maxY > viewportMinY && frame.minY < viewportMaxY {
                return target.id
            }
        }
        return nil
    }

    private var renderedScrollScope: ChatRenderedScrollScope? {
        renderedScrollSessionKey.map {
            ChatRenderedScrollScope(
                sessionKey: $0,
                cacheRevision: chatMessageScrollTargetCache.renderingRevision,
                restorationGeneration: appState.chatResumeRestorationRequest?.generation,
                transcriptRevision: renderedTranscriptRevision,
                viewportTransitionGeneration: renderedViewportTransitionGeneration
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        Color.clear
                            .frame(height: 1)
                            .id(topAnchor)

                        if appState.messages.isEmpty {
                            EmptyChatState().padding(.top, 60)
                        }

                        ForEach(chatMessageScrollTargetCache.targets) { target in
                            MessageBubble(message: target.message)
                                .id(target.id)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: ChatRenderedScrollTargetsPreferenceKey.self,
                                            value: renderedScrollScope.map {
                                                ChatRenderedScrollTargets.row(
                                                    semanticID: target.id,
                                                    scope: $0,
                                                    frame: geometry.frame(in: .global)
                                                )
                                            } ?? ChatRenderedScrollTargets()
                                        )
                                    }
                                }
                        }

                        if !appState.streamingText.isEmpty {
                            StreamingBubble(
                                text: appState.streamingText,
                                active: appState.isBusy
                            )
                            .id("streaming")
                        }

                        if appState.isBusy && appState.streamingText.isEmpty {
                            TypingIndicator().id("typing")
                        }

                        // Keep the scroll target in the lazy layout itself.
                        // A notification can replace the entire transcript at
                        // once; a sibling target can otherwise be measured
                        // against stale content while LazyVStack catches up.
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
                    .scrollTargetLayout()
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .background {
                        // Measure the lazy stack itself, not its final child.
                        // SwiftUI can unload that child after the user scrolls
                        // away, leaving the old "at bottom" value stuck and
                        // suppressing the scroll-to-latest button.
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
                .scrollDismissesKeyboard(.interactively)
                .scrollPosition(id: $topVisibleChatID, anchor: .top)
                .onTapGesture {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ChatViewportFramePreferenceKey.self,
                            value: geometry.frame(in: .global)
                        )
                    }
                }
                .onAppear {
                    renderedScrollSessionKey = activeScrollSessionKey
                    chatMessageScrollTargetCache.update(for: appState.messages)
                    renderedTranscriptRevision = appState.chatTranscriptRevision
                    renderedViewportTransitionGeneration = appState.chatViewportTransitionGeneration
                    appState.installChatViewportSnapshotProvider(
                        id: viewportSnapshotProviderID,
                        capture: {
                            // @State reads through the captured view struct see
                            // current values (State storage is a reference
                            // box), matching the previous binding captures.
                            guard let sessionKey = self.renderedScrollSessionKey else {
                                return nil
                            }
                            guard let snapshot = ChatTitleScrollViewportSnapshot.make(
                                followsLatest: self.followsLatest,
                                topVisibleID: self.stableTopMessageID,
                                topAnchorID: ChatTitleScrollAnchor.id(for: sessionKey),
                                targets: self.chatMessageScrollTargetCache.targets
                            ) else {
                                return nil
                            }
                            return ChatRenderedViewportSnapshot(
                                sessionKey: sessionKey,
                                snapshot: snapshot
                            )
                        }
                    )
                }
                .onDisappear {
                    performViewportEffects(viewport.viewDisappeared(), using: proxy)
                    appState.removeChatViewportSnapshotProvider(id: viewportSnapshotProviderID)
                }
                .task(id: appState.chatResumeRestorationRequest?.generation) {
                    guard let request = appState.chatResumeRestorationRequest else { return }
                    invalidateChatDrag(using: proxy)
                    await applyChatResumeRestoration(request, using: proxy)
                }
                .onPreferenceChange(ChatBottomMarkerPreferenceKey.self) { value in
                    bottomMarkerMaxY = value
                    recordNotificationHandoffLayout()
                    finishNotificationHandoffIfReady(using: proxy)
                    performViewportEffects(
                        viewport.layoutMetricsChanged(facts: currentLayoutFacts()),
                        using: proxy
                    )
                }
                .onPreferenceChange(ChatViewportFramePreferenceKey.self) { value in
                    scrollViewportFrame = value
                    recordNotificationHandoffLayout()
                    finishNotificationHandoffIfReady(using: proxy)
                    performViewportEffects(
                        viewport.layoutMetricsChanged(facts: currentLayoutFacts()),
                        using: proxy
                    )
                }
                .onPreferenceChange(ChatRenderedScrollContentPreferenceKey.self) { value in
                    renderedScrollContent = value
                    guard let value else { return }
                    appState.chatViewportLayoutDidSettle(
                        sessionKey: value.scope.sessionKey,
                        transitionGeneration: value.scope.viewportTransitionGeneration,
                        transcriptRevision: value.scope.transcriptRevision,
                        renderRevision: value.scope.cacheRevision,
                        receivedScopedPreference: true
                    )
                }
                .onPreferenceChange(ChatRenderedScrollTargetsPreferenceKey.self) { value in
                    renderedScrollTargets = value
                    performViewportEffects(
                        viewport.layoutMetricsChanged(facts: currentLayoutFacts()),
                        using: proxy
                    )
                }
                .onChange(of: isDraggingChat) { wasDragging, isDragging in
                    guard wasDragging, !isDragging else { return }
                    performViewportEffects(viewport.userDragGestureEnded(), using: proxy)
                }
                .onChange(of: appState.messages) { _, newMessages in
                    let cacheUpdate = chatMessageScrollTargetCache.update(for: newMessages)
                    renderedTranscriptRevision = appState.chatTranscriptRevision
                    renderedViewportTransitionGeneration = appState.chatViewportTransitionGeneration
                    guard !appState.isOpeningNotificationSession else {
                        notificationHandoffPending = true
                        return
                    }
                    guard ChatMessageScrollUpdatePolicy.shouldReassertLatest(
                        after: cacheUpdate,
                        followsLatest: followsLatest,
                        hasPendingRestoration: hasPendingRestoration,
                        hasNotificationHandoff: notificationHandoffPending
                    ) else { return }
                    ChatViewportTrace.shared.log(
                        "messages reassert pass follows=\(followsLatest) cache=\(cacheUpdate)"
                    )
                    DispatchQueue.main.async {
                        guard ChatMessageScrollUpdatePolicy.shouldReassertLatest(
                            after: cacheUpdate,
                            followsLatest: followsLatest,
                            hasPendingRestoration: appState.chatResumeRestorationRequest != nil,
                            hasNotificationHandoff: appState.isOpeningNotificationSession
                                || notificationHandoffPending
                        ) else { return }
                        scrollToLatest(using: proxy)
                    }
                }
                .onChange(of: appState.chatTranscriptRevision) { _, revision in
                    if chatMessageScrollTargetCache.targets.map(\.message) != appState.messages {
                        chatMessageScrollTargetCache.update(for: appState.messages)
                    }
                    renderedTranscriptRevision = revision
                    renderedViewportTransitionGeneration = appState.chatViewportTransitionGeneration
                }
                .onChange(of: stableTopMessageID) { _, _ in
                    // Persist the browsing position while the old transcript
                    // is still rendered. A session switch clears messages in
                    // the same main-actor turn, so waiting until the switch
                    // callback would leave us with no anchor to save.
                    saveChatScrollPosition(for: renderedScrollSessionKey)
                }
                .onChange(of: followsLatest) { _, _ in
                    saveChatScrollPosition(for: renderedScrollSessionKey)
                }
                .onChange(of: appState.chatScrollRequest) { _, _ in
                    ChatViewportTrace.shared.log("event explicitLatest (send pulse)")
                    performViewportEffects(viewport.explicitLatestRequested(), using: proxy)
                }
                .onChange(of: appState.chatScrollToTopRequest) { _, request in
                    ChatViewportTrace.shared.log("event explicitTop request=\(request)")
                    performViewportEffects(viewport.explicitTopRequested(request: request), using: proxy)
                }
                .onChange(of: appState.activeSessionId) { oldSessionID, newSessionID in
                    guard !appState.isOpeningNotificationSession else {
                        invalidateChatDrag(using: proxy)
                        scrollOwnerState.invalidateForSessionTransition()
                        cancelAutomaticRestoration()
                        notificationHandoffPending = true
                        notificationHandoffSessionKey = activeScrollSessionKey
                        notificationHandoffHasMeasuredLayout = false
                        renderedScrollSessionKey = activeScrollSessionKey
                        if followsLatest {
                            renderedViewportTransitionGeneration = appState.chatViewportTransitionGeneration
                        }
                        return
                    }
                    let identity = appState.activeChatScrollSessionIdentity
                    let oldKey = renderedScrollSessionKey ?? identity.key(for: oldSessionID)
                    let newKey = activeScrollSessionKey
                    if let request = appState.chatResumeRestorationRequest,
                       !identity.areEquivalent(request.sessionKey, newKey) {
                        cancelAutomaticRestoration()
                    }
                    let keysAreEquivalent = identity.areEquivalent(oldKey, newKey)
                    if !keysAreEquivalent {
                        invalidateChatDrag(using: proxy)
                        scrollOwnerState.invalidateForSessionTransition()
                    }
                    renderedScrollSessionKey = newKey
                    if followsLatest {
                        renderedViewportTransitionGeneration = appState.chatViewportTransitionGeneration
                    }
                    guard !keysAreEquivalent else { return }
                    topVisibleChatID = nil
                    let shouldFollowLatest = ChatFollowLatestRelatchPolicy
                        .shouldFollowLatestAfterTransition(isDragging: isDraggingChat)
                    setLegacyFollowsLatest(shouldFollowLatest, using: proxy)
                    if shouldFollowLatest {
                        scrollToLatest(using: proxy)
                    }
                }
                .onChange(of: appState.activeProfile) { _, _ in
                    invalidateChatDrag(using: proxy)
                    scrollOwnerState.invalidateForSessionTransition()
                    let oldKey = renderedScrollSessionKey
                    let newKey = activeScrollSessionKey
                    if let request = appState.chatResumeRestorationRequest,
                       request.sessionKey != newKey {
                        cancelAutomaticRestoration()
                    }
                    topVisibleChatID = nil
                    chatMessageScrollTargetCache = ChatMessageScrollTargetCache()
                    chatMessageScrollTargetCache.update(for: appState.messages)
                    renderedTranscriptRevision = appState.chatTranscriptRevision
                    renderedScrollSessionKey = newKey
                    if followsLatest {
                        renderedViewportTransitionGeneration = appState.chatViewportTransitionGeneration
                    }
                    guard !appState.isOpeningNotificationSession else {
                        notificationHandoffPending = true
                        notificationHandoffSessionKey = newKey
                        notificationHandoffHasMeasuredLayout = false
                        setLegacyFollowsLatest(false, using: proxy)
                        return
                    }
                    guard oldKey != newKey else { return }
                    let shouldFollowLatest = ChatFollowLatestRelatchPolicy
                        .shouldFollowLatestAfterTransition(isDragging: isDraggingChat)
                    setLegacyFollowsLatest(shouldFollowLatest, using: proxy)
                    if shouldFollowLatest {
                        scrollToLatest(using: proxy)
                    }
                }
                .onChange(of: appState.activeChatScrollSessionIdentity) { _, _ in
                    guard !appState.isOpeningNotificationSession else { return }
                    if let activeScrollSessionKey,
                       appState.activeChatScrollSessionIdentity.areEquivalent(
                           renderedScrollSessionKey,
                           activeScrollSessionKey
                    ) {
                        renderedScrollSessionKey = activeScrollSessionKey
                    }
                }
                .onChange(of: appState.isOpeningNotificationSession) { _, isOpening in
                    if isOpening {
                        invalidateChatDrag(using: proxy)
                        scrollOwnerState.invalidateForSessionTransition()
                        cancelAutomaticRestoration()
                        notificationHandoffPending = true
                        notificationHandoffSessionKey = nil
                        notificationHandoffHasMeasuredLayout = false
                        setLegacyFollowsLatest(false, using: proxy)
                    } else {
                        if notificationHandoffPending, notificationHandoffSessionKey == nil {
                            notificationHandoffSessionKey = activeScrollSessionKey
                            notificationHandoffHasMeasuredLayout = bottomMarkerMaxY != nil && scrollViewportMaxY != nil
                        }
                        finishNotificationHandoffIfReady(using: proxy)
                    }
                }
                .onChange(of: appState.streamingText) { _, _ in
                    if followsLatest && !hasPendingRestoration {
                        ChatViewportTrace.shared.log(
                            "streamingText delta scroll follows=\(followsLatest)"
                        )
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
                .onChange(of: appState.isBusy) { _, isBusy in
                    if !isBusy, followsLatest, !hasPendingRestoration {
                        ChatViewportTrace.shared.log("isBusy-end scroll follows=\(followsLatest)")
                        scrollToLatest(using: proxy)
                    }
                }
                .simultaneousGesture(chatDragGesture(proxy: proxy))
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest && !isNearBottom {
                        Button {
                            ChatViewportTrace.shared.log("event explicitLatest (button)")
                            performViewportEffects(
                                viewport.explicitLatestRequested(),
                                using: proxy
                            )
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 44, height: 44)
                        }
                        .conduitGlassControl(cornerRadius: 22, tint: .conduitAccent.opacity(0.14))
                        .accessibilityLabel("Scroll to latest message")
                        .padding(.trailing, 18)
                        .padding(.bottom, 14)
                    }
                }
            }

            // Composer + control bar
            ComposerBar()
        }
        .background(Color.clear)
        .overlay(alignment: .top) {
            if appState.isOpeningNotificationSession {
                Label("Opening conversation…", systemImage: "arrow.down.message")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.12))
                    .padding(.top, 12)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: appState.isOpeningNotificationSession)
        .overlay {
            // Cross-block selection chrome (endpoint handles + copy pill),
            // mounted at screen level so its frame always covers the whole
            // transcript; see MarkdownSelectionHandles.swift.
            MarkdownSelectionChromeRoot()
        }
    }

    private func saveChatScrollPosition(for preferredKey: ChatScrollSessionKey? = nil) {
        let currentKey = preferredKey ?? renderedScrollSessionKey ?? activeScrollSessionKey
        guard let sessionKey = ChatFollowLatestRelatchPolicy.persistenceSessionKey(
            currentKey: currentKey,
            identity: appState.activeChatScrollSessionIdentity
        ) else { return }
        guard let snapshot = currentChatViewportSnapshot() else { return }
        appState.recordChatViewport(snapshot, for: sessionKey)
    }

    private func currentChatViewportSnapshot() -> ChatScrollSnapshot? {
        ChatTitleScrollViewportSnapshot.make(
            followsLatest: followsLatest,
            topVisibleID: stableTopMessageID,
            topAnchorID: renderedTopAnchor,
            targets: chatMessageScrollTargetCache.targets
        )
    }

    private func cancelAutomaticRestoration() {
        appState.cancelChatResumeRestoration()
    }

    private func chatDragGesture(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($isDraggingChat) { _, isDragging, _ in
                isDragging = true
            }
            .onChanged { _ in
                beginChatDragIfNeeded(using: proxy)
            }
    }

    private func beginChatDragIfNeeded(using proxy: ScrollViewProxy) {
        // Only a deliberate user drag opts out of stream following; the
        // controller captures the session and transition that owned the
        // gesture and owns the completion lineage.
        performViewportEffects(
            viewport.userDragBegan(
                sessionKey: renderedScrollSessionKey ?? activeScrollSessionKey,
                viewportTransitionGeneration: appState.chatViewportTransitionGeneration
            ),
            using: proxy
        )
    }

    private func invalidateChatDrag(using proxy: ScrollViewProxy) {
        performViewportEffects(
            viewport.invalidateDrag(hasActiveGesture: isDraggingChat),
            using: proxy
        )
    }

    private func abandonChatDrag(using proxy: ScrollViewProxy) {
        performViewportEffects(viewport.abandonDrag(), using: proxy)
    }

    @MainActor
    private func applyChatResumeRestoration(
        _ request: ChatResumeRestorationRequest,
        using proxy: ScrollViewProxy
    ) async {
        guard restorationRequestIsCurrent(request) else {
            // If the generation is still current but identity drifted,
            // abandon so pendingRestoration doesn't get stuck forever.
            if appState.chatResumeRestorationRequest?.generation == request.generation {
                appState.abandonChatResumeRestoration(generation: request.generation)
            }
            return
        }
        if chatMessageScrollTargetCache.targets.map(\.message) != appState.messages {
            chatMessageScrollTargetCache.update(for: appState.messages)
            renderedTranscriptRevision = appState.chatTranscriptRevision
        }

        var destination = restorationDestination(
            for: request,
            targets: chatMessageScrollTargetCache.targets
        )
        setLegacyFollowsLatest(destination == .latest, using: proxy)
        var restoration = ChatResumeRenderRestorationState(
            generation: request.generation,
            sessionKey: request.sessionKey,
            destination: destination
        )

        while restorationRequestIsCurrent(request) {
            if chatMessageScrollTargetCache.targets.map(\.message) != appState.messages {
                chatMessageScrollTargetCache.update(for: appState.messages)
                renderedTranscriptRevision = appState.chatTranscriptRevision
            }
            destination = restorationDestination(
                for: request,
                targets: chatMessageScrollTargetCache.targets
            )
            restoration.updateDestination(destination)

            switch restoration.nextAction(
                renderedContent: renderedScrollContent,
                installedTargets: renderedScrollTargets,
                cacheRevision: chatMessageScrollTargetCache.renderingRevision,
                transcriptRevision: appState.chatTranscriptRevision,
                topVisibleID: stableTopMessageID,
                isNearBottom: bottomMarkerMaxY != nil
                    && scrollViewportMaxY != nil
                    && isNearBottom
            ) {
            case .wait:
                break
            case .scroll(let destination):
                guard restorationRequestIsCurrent(request) else { return }
                ChatViewportTrace.shared.log(
                    "restoration scroll \(destination) gen=\(request.generation)"
                )
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    switch destination {
                    case .latest:
                        setLegacyFollowsLatest(true, using: proxy)
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    case .anchor(let anchor):
                        setLegacyFollowsLatest(false, using: proxy)
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            case .complete:
                guard restorationRequestIsCurrent(request) else { return }
                ChatViewportTrace.shared.log(
                    "restoration complete gen=\(request.generation)"
                )
                appState.completeChatResumeRestoration(generation: request.generation)
                if destination == .latest {
                    saveChatScrollPosition(for: request.sessionKey)
                }
                return
            case .abandon:
                guard restorationRequestIsCurrent(request) else { return }
                ChatViewportTrace.shared.log(
                    "restoration abandon gen=\(request.generation)"
                )
                appState.abandonChatResumeRestoration(generation: request.generation)
                return
            case .cancelled:
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                restoration.cancel()
                return
            }
        }

        // Loop exited because restorationRequestIsCurrent returned false.
        // If the generation is still current but identity drifted mid-loop,
        // abandon so pendingRestoration doesn't get stuck forever.
        if appState.chatResumeRestorationRequest?.generation == request.generation {
            appState.abandonChatResumeRestoration(generation: request.generation)
        }
    }

    private func restorationDestination(
        for request: ChatResumeRestorationRequest,
        targets: [ChatMessageScrollTarget]
    ) -> ChatResumeViewportDestination {
        switch request.destination {
        case .latest:
            return .latest
        case .snapshot(let snapshot):
            // The resolver returns semantic anchor IDs, but rows are now
            // keyed by message.id (.id(target.id)). Resolve the semantic
            // anchor to its source message.id so the entire restoration
            // state machine operates in one identity space.
            let resolved = ChatResumeViewportResolver.destination(
                for: snapshot,
                availableTargets: ChatScrollTargetAvailability(targets: targets)
            )
            switch resolved {
            case .latest:
                return .latest
            case .anchor(let semanticAnchor):
                let sourceAnchor = targets.first { $0.semanticID == semanticAnchor }?.id ?? semanticAnchor
                return .anchor(sourceAnchor)
            }
        }
    }

    private func restorationRequestIsCurrent(
        _ request: ChatResumeRestorationRequest
    ) -> Bool {
        guard !Task.isCancelled,
              appState.chatResumeRestorationRequest?.generation == request.generation else {
            return false
        }
        let identity = appState.activeChatScrollSessionIdentity
        return identity.areEquivalent(request.sessionKey, activeScrollSessionKey)
    }

    // LEGACY (Tasks 4-6 migrate their callers to controller effects; these
    // disappear once session-change, messages-reassert, isBusy, and handoff
    // paths are routed through the controller).
    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard !hasPendingRestoration else { return }
        let ownerToken = scrollOwnerState.claimLatest()
        let anchorID = bottomAnchor
        ChatViewportTrace.shared.log(
            "scroll latest anchor=\(anchorID) ownerGen=\(ownerToken.generation)"
        )
        withAnimation(ConduitMotion.response) {
            proxy.scrollTo(anchorID, anchor: .bottom)
        }
        // Retry after a short delay: proxy.scrollTo is a silent no-op if the
        // bottom anchor row isn't materialized yet (LazyVStack on a long
        // transcript). A single delayed retry covers the common case where
        // messages arrive on the same main-actor turn.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard let retryAnchor = scrollOwnerState.latestRetryAnchor(
                for: ownerToken,
                currentAnchor: bottomAnchor,
                followsLatest: followsLatest,
                hasPendingRestoration: hasPendingRestoration,
                isCancelled: Task.isCancelled
            ) else { return }
            ChatViewportTrace.shared.log(
                "scroll latest retry anchor=\(retryAnchor) ownerGen=\(ownerToken.generation)"
            )
            withAnimation(ConduitMotion.response) {
                proxy.scrollTo(retryAnchor, anchor: .bottom)
            }
        }
    }

    private func scrollToTop(using proxy: ScrollViewProxy, request: Int) {
        let ownerToken = scrollOwnerState.claimTop(request: request)
        let anchorID = topAnchor
        ChatViewportTrace.shared.log(
            "scroll top anchor=\(anchorID) request=\(request) ownerGen=\(ownerToken.generation)"
        )
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(anchorID, anchor: .top)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard let retryAnchor = scrollOwnerState.topRetryAnchor(
                for: ownerToken,
                currentRequest: appState.chatScrollToTopRequest,
                currentAnchor: topAnchor,
                isCancelled: Task.isCancelled
            ) else { return }
            ChatViewportTrace.shared.log(
                "scroll top retry anchor=\(retryAnchor) request=\(request)"
            )
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(retryAnchor, anchor: .top)
            }
        }
    }

    /// A notification handoff completes only after the destination transcript
    /// has emitted its own geometry. This is a layout fact rather than a timer,
    /// so a long lazy transcript cannot inherit the old conversation's offset.
    private func recordNotificationHandoffLayout() {
        guard notificationHandoffPending,
              appState.activeChatScrollSessionIdentity.areEquivalent(
                notificationHandoffSessionKey,
                activeScrollSessionKey
              ),
              bottomMarkerMaxY != nil,
              scrollViewportMaxY != nil else { return }
        notificationHandoffHasMeasuredLayout = true
    }

    private func finishNotificationHandoffIfReady(using proxy: ScrollViewProxy) {
        guard notificationHandoffPending,
              !appState.isOpeningNotificationSession,
              appState.activeChatScrollSessionIdentity.areEquivalent(
                notificationHandoffSessionKey,
                activeScrollSessionKey
              ),
              notificationHandoffHasMeasuredLayout else { return }
        notificationHandoffPending = false
        notificationHandoffSessionKey = nil
        cancelAutomaticRestoration()
        if case .explicitTop = viewport.mode {
            ChatViewportTrace.shared.log("handoff complete -> top")
            setLegacyFollowsLatest(false, using: proxy)
            // The handoff completes once the destination's bottom-marker
            // geometry arrives, but the lazy top anchor may not be laid out
            // yet. Use the retry-capable path so the viewport still lands at
            // the top once the anchor materializes.
            scrollToTop(using: proxy, request: appState.chatScrollToTopRequest)
            return
        }
        let shouldFollowLatest = ChatFollowLatestRelatchPolicy
            .shouldFollowLatestAfterTransition(isDragging: isDraggingChat)
        if shouldFollowLatest {
            ChatViewportTrace.shared.log("handoff complete -> latest")
            setLegacyFollowsLatest(true, using: proxy)
            _ = scrollOwnerState.claimLatest()
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            ChatViewportTrace.shared.log("handoff complete -> none")
            setLegacyFollowsLatest(false, using: proxy)
        }
    }

    // MARK: - Viewport controller wiring

    private func currentLayoutFacts() -> ChatViewportLayoutFacts {
        let scope = renderedScrollScope
        let frames = renderedRowFrames.map { id, frame in
            ChatRenderedRowFrame(
                id: id,
                minY: frame.minY,
                maxY: frame.maxY,
                scope: scope ?? ChatRenderedScrollScope(
                    sessionKey: activeOrFallbackScrollSessionKey,
                    cacheRevision: 0,
                    restorationGeneration: nil,
                    transcriptRevision: 0,
                    viewportTransitionGeneration: 0
                )
            )
        }
        return ChatViewportLayoutFacts(
            bottomMarkerMaxY: bottomMarkerMaxY,
            viewportMinY: scrollViewportMinY,
            viewportMaxY: scrollViewportMaxY,
            rowFrames: frames,
            renderedScope: scope
        )
    }

    /// Transitional bridge for not-yet-migrated paths that used to assign
    /// `followsLatest`. Callers: restoration loop (Task 5), notification
    /// handoff branches (Task 4), session/profile change (Task 4). This
    /// helper must be gone by Task 7.
    private func setLegacyFollowsLatest(_ following: Bool, using proxy: ScrollViewProxy) {
        performViewportEffects(
            viewport.legacySetFollowingLatest(following),
            using: proxy
        )
    }

    /// The ONLY boundary that executes viewport effects. `runScroll` is the
    /// only place in ChatView that calls ScrollViewProxy.scrollTo.
    @MainActor
    private func performViewportEffects(
        _ effects: [ChatViewportEffect],
        using proxy: ScrollViewProxy
    ) {
        for effect in effects {
            performViewportEffect(effect, using: proxy)
        }
    }

    @MainActor
    private func performViewportEffect(
        _ effect: ChatViewportEffect,
        using proxy: ScrollViewProxy
    ) {
        switch effect {
        case .scroll(let command):
            executeViewportScrollCommand(command, using: proxy)
        case .cancelAutomaticRestoration:
            appState.cancelChatResumeRestoration()
        case .persistViewportSnapshot(let key):
            saveChatScrollPosition(for: key)
        case .flushViewportPersistence:
            appState.flushChatResumeViewport()
        case .completeRestoration(let generation):
            appState.completeChatResumeRestoration(generation: generation)
        case .abandonRestoration(let generation):
            appState.abandonChatResumeRestoration(generation: generation)
        case .scheduleDragEvaluation(let token):
            Task { @MainActor in
                await ChatFollowLatestRelatchPolicy.waitForNextMainActorTurn()
                guard !Task.isCancelled else { return }
                ChatViewportTrace.shared.log(
                    "drag completion evaluate gen=\(token.dragGeneration)"
                )
                performViewportEffects(
                    viewport.evaluateDragCompletion(
                        token,
                        viewportTransitionGeneration: appState.chatViewportTransitionGeneration
                    ),
                    using: proxy
                )
            }
        }
    }

    @MainActor
    private func executeViewportScrollCommand(
        _ command: ChatViewportCommand,
        using proxy: ScrollViewProxy
    ) {
        // Immediate execution: the controller issued this command in the
        // current turn, so it is current by construction. Only the delayed
        // retry re-validates below.
        runViewportScroll(command, using: proxy)
        guard case .delayed(let milliseconds) = command.retry else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled, viewport.isCommandCurrent(command) else { return }
            ChatViewportTrace.shared.log(
                "scroll retry \(command.destination) gen=\(command.generation)"
            )
            runViewportScroll(command, using: proxy)
        }
    }

    @MainActor
    private func runViewportScroll(
        _ command: ChatViewportCommand,
        using proxy: ScrollViewProxy
    ) {
        ChatViewportTrace.shared.log(
            "scroll \(command.destination) gen=\(command.generation) animated=\(command.animated)"
        )
        var transaction = Transaction()
        transaction.animation = command.animated ? ConduitMotion.response : nil
        withTransaction(transaction) {
            switch command.destination {
            case .bottom(let anchorID):
                proxy.scrollTo(anchorID, anchor: .bottom)
            case .top(let anchorID, _):
                proxy.scrollTo(anchorID, anchor: .top)
            case .message(let id):
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }
}

enum ChatTitleScrollAnchor {
    static func id(for sessionKey: ChatScrollSessionKey) -> String {
        "chat-top-\(sessionKey.profile)-\(sessionKey.sessionID)"
    }
}

enum ChatScrollOwner: Equatable {
    case latest
    case explicitTop(request: Int)
    case userDrag
    case sessionTransition
}

struct ChatScrollOwnerToken: Equatable {
    let generation: UInt64
    let owner: ChatScrollOwner
}

enum ChatHandoffCompletionAction: Equatable {
    case top(anchorID: String)
    case latest
    case none
}

struct ChatScrollOwnerState: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var owner: ChatScrollOwner = .latest

    @discardableResult
    mutating func claimLatest() -> ChatScrollOwnerToken {
        advance(to: .latest)
    }

    @discardableResult
    mutating func claimTop(request: Int) -> ChatScrollOwnerToken {
        advance(to: .explicitTop(request: request))
    }

    mutating func invalidateForUserDrag() {
        advance(to: .userDrag)
    }

    mutating func invalidateForSessionTransition() {
        advance(to: .sessionTransition)
    }

    func hasActiveTopOwner(currentRequest: Int) -> Bool {
        guard case .explicitTop(let request) = owner else { return false }
        return request == currentRequest
    }

    func topRetryAnchor(
        for token: ChatScrollOwnerToken,
        currentRequest: Int,
        currentAnchor: String,
        isCancelled: Bool
    ) -> String? {
        guard !isCancelled,
              token == currentToken,
              hasActiveTopOwner(currentRequest: currentRequest) else {
            return nil
        }
        return currentAnchor
    }

    func latestRetryAnchor(
        for token: ChatScrollOwnerToken,
        currentAnchor: String,
        followsLatest: Bool,
        hasPendingRestoration: Bool,
        isCancelled: Bool
    ) -> String? {
        guard !isCancelled,
              token == currentToken,
              owner == .latest,
              followsLatest,
              !hasPendingRestoration else {
            return nil
        }
        return currentAnchor
    }

    func handoffCompletionAction(
        currentTopRequest: Int,
        currentTopAnchor: String,
        shouldFollowLatest: Bool
    ) -> ChatHandoffCompletionAction {
        if hasActiveTopOwner(currentRequest: currentTopRequest) {
            return .top(anchorID: currentTopAnchor)
        }
        return shouldFollowLatest ? .latest : .none
    }

    private var currentToken: ChatScrollOwnerToken {
        ChatScrollOwnerToken(generation: generation, owner: owner)
    }

    @discardableResult
    private mutating func advance(to nextOwner: ChatScrollOwner) -> ChatScrollOwnerToken {
        generation &+= 1
        owner = nextOwner
        return currentToken
    }
}

enum ChatTitleScrollViewportSnapshot {
    static func make(
        followsLatest: Bool,
        topVisibleID: String?,
        topAnchorID: String,
        targets: [ChatMessageScrollTarget]
    ) -> ChatScrollSnapshot? {
        if followsLatest {
            return ChatScrollSnapshot(
                anchorMessageID: nil,
                followsLatest: true
            )
        }
        guard let target = visibleTarget(
            topVisibleID: topVisibleID,
            topAnchorID: topAnchorID,
            targets: targets
        ) else {
            return nil
        }
        return ChatScrollSnapshot(
            anchorMessageID: target.semanticID,
            followsLatest: false,
            anchorMetadata: target.restorationMetadata,
            anchorSourceMessageID: target.id
        )
    }

    private static func visibleTarget(
        topVisibleID: String?,
        topAnchorID: String,
        targets: [ChatMessageScrollTarget]
    ) -> ChatMessageScrollTarget? {
        if topVisibleID == topAnchorID {
            return targets.first
        }
        return targets.first { $0.id == topVisibleID }
    }
}

private struct ChatBottomMarkerPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct ChatViewportFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private struct ChatRenderedScrollContentPreferenceKey: PreferenceKey {
    static var defaultValue: ChatRenderedScrollContent? = nil
    static func reduce(
        value: inout ChatRenderedScrollContent?,
        nextValue: () -> ChatRenderedScrollContent?
    ) {
        value = nextValue() ?? value
    }
}

private struct ChatRenderedScrollTargetsPreferenceKey: PreferenceKey {
    static var defaultValue = ChatRenderedScrollTargets()

    static func reduce(
        value: inout ChatRenderedScrollTargets,
        nextValue: () -> ChatRenderedScrollTargets
    ) {
        ChatRenderedScrollTargets.reduce(value: &value, nextValue: nextValue())
    }
}
// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(message: message)
        case .assistant:
            AssistantBubble(message: message)
        case .reasoning:
            ThinkingCard(message: message)
        case .tool:
            ToolCard(message: message)
        case .clarify:
            ClarifyCard(message: message)
        case .approval:
            ApprovalCard(message: message)
        case .system:
            if let review = message.review ?? MessageNormalizer.reviewActivity(fromText: message.content) {
                ReviewSummaryCard(activity: review, timestamp: message.timestamp)
            } else if let modelChange = MessageNormalizer.modelChangeActivity(
                fromText: message.rawContent ?? message.content
            ) {
                ModelChangeSummaryCard(
                    model: modelChange.model,
                    provider: modelChange.provider,
                    timestamp: message.timestamp
                )
            } else {
                SystemBubble(message: message)
            }
        case .partial:
            AssistantBubble(message: message)
        }
    }
}

struct UserBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                UserMessageContent(message: message)

                MessageTimestampLabel(timestamp: message.timestamp)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct UserMessageContent: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownText(source: message.content, foregroundStyle: .white, usesAccentSurface: true)
            }

            if let attachments = message.attachments {
                ForEach(attachments) { attachment in
                    if attachment.kind == .image {
                        UserImageAttachmentPreview(attachment: attachment)
                    } else {
                        UserDocumentAttachmentChip(attachment: attachment)
                    }
                }
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 11)
        .background(
            LinearGradient(
                colors: [.conduitAccent, .conduitAccent.opacity(0.76)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 21, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: Color.conduitAccent.opacity(0.16), radius: 14, y: 6)
        .textSelection(.enabled)
    }
}

private struct UserImageAttachmentPreview: View {
    let attachment: Attachment
    @EnvironmentObject private var appState: AppState
    @State private var gatewayImage: UIImage?
    @State private var gatewayLoadFailed = false
    @State private var localPreview: UIImage?
    @State private var localPreviewPath: String?
    @State private var localPreviewFailedPath: String?

    /// Body re-evaluates at streaming frame rate, and re-reading + fully
    /// decoding the file each time hitches scrolling. Previews are downsampled
    /// to the display size and shared across rows; NSCache evicts them under
    /// memory pressure. Cost-bounded so a handful of large photos can't
    /// exhaust it before then.
    private static let localImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Cache-only lookup (no decode) so a hit renders on the first frame.
    /// Misses are filled asynchronously — see the `.task` in `body`.
    private var cachedLocalImage: UIImage? {
        guard let url = localFileURL else { return nil }
        return Self.localImageCache.object(forKey: url.path as NSString)
    }

    /// The decoded preview, gated on the path it was decoded for so a stale
    /// value can't leak in if SwiftUI ever reuses this view identity for a
    /// different `attachment.uri`. Today that can't happen — `Attachment` is
    /// `Identifiable` so each id gets fresh `@State`, and uris are immutable —
    /// but this makes the invariant non-load-bearing rather than relying on it.
    private var currentLocalPreview: UIImage? {
        guard localPreviewPath == localFileURL?.path else { return nil }
        return localPreview
    }

    /// True only for a decode failure of the *current* path.
    private var localPreviewFailed: Bool {
        localPreviewFailedPath == localFileURL?.path
    }

    /// Estimated decoded byte cost for NSCache. `bytesPerRow * height` accounts
    /// for the row-alignment padding that a naive `width * height * 4` misses.
    private static func bitmapCost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }

    /// Decodes `url` as a thumbnail sized for the 224pt attachment preview
    /// (~3× retina on the long edge). `nonisolated` makes explicit that this is
    /// pure CoreGraphics and safe to call off the MainActor — which is how the
    /// `.task` below invokes it, so a large photo can't hitch scrolling on a
    /// cache miss. `ShouldCache` is false because the resulting `UIImage` is
    /// already retained by our cache; the default `true` would double-buffer
    /// the decoded bitmap inside ImageIO. Note: the detached caller returns a
    /// non-Sendable `UIImage` across the task boundary — fine under the
    /// project's Swift 5 mode, but it would need a Sendable box if strict
    /// concurrency is ever enabled.
    private nonisolated static func downsampledPreview(url: URL) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: CGFloat(800)
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    private var localFileURL: URL? {
        if let url = URL(string: attachment.uri), url.isFileURL { return url }
        let url = URL(fileURLWithPath: attachment.uri)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        Group {
            if let image = cachedLocalImage ?? currentLocalPreview ?? gatewayImage {
                imagePreview(image)
            } else if isGatewayImage && localFileURL == nil && !gatewayLoadFailed {
                loadingPlaceholder
            } else if localFileURL != nil && !localPreviewFailed {
                // Local file decoding off-main on a cache miss.
                loadingPlaceholder
            } else {
                Label(
                    (gatewayLoadFailed || localPreviewFailed) ? "Image unavailable" : "Image attached",
                    systemImage: (gatewayLoadFailed || localPreviewFailed) ? "photo.badge.exclamationmark" : "photo"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.13), in: Capsule())
            }
        }
        .task(id: "\(attachment.uri)|\(appState.activeProfile)") {
            // Local file: cache hits are already shown by `body` on the first
            // frame via `cachedLocalImage`, so only misses reach here. Decode
            // off the MainActor so a large photo can't hitch scrolling.
            if let url = localFileURL {
                guard currentLocalPreview == nil, cachedLocalImage == nil else { return }
                let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    Self.downsampledPreview(url: url)
                }.value
                guard !Task.isCancelled else { return }
                guard let image else {
                    localPreviewFailedPath = url.path
                    return
                }
                Self.localImageCache.setObject(image, forKey: url.path as NSString, cost: Self.bitmapCost(of: image))
                localPreview = image
                localPreviewPath = url.path
                // Gateway image, fetched through Hermes. The local-file branch
                // returns above, so a local URI never reaches here — which also
                // removes the old `localImage == nil` check that decoded local
                // files on the MainActor before short-circuiting.
            } else if isGatewayImage {
                gatewayImage = nil
                gatewayLoadFailed = false
                guard let dataURL = await appState.gatewayMediaDataURL(
                    for: attachment.uri,
                    profile: appState.activeProfile
                ),
                !Task.isCancelled,
                let image = image(fromDataURL: dataURL) else {
                    guard !Task.isCancelled else { return }
                    gatewayLoadFailed = true
                    return
                }
                gatewayImage = image
            }
        }
    }

    private var loadingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(.white)
            Text("Loading image...")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.13), in: Capsule())
    }

    private var isGatewayImage: Bool {
        attachment.uri.hasPrefix("/")
    }

    private func imagePreview(_ image: UIImage) -> some View {
        Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 224, height: previewHeight(for: image))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }
                .accessibilityLabel("Attached image: \(attachment.name)")
    }

    private func previewHeight(for image: UIImage) -> CGFloat {
        guard image.size.width > 0 else { return 168 }
        return min(260, max(120, 224 * image.size.height / image.size.width))
    }

    private func image(fromDataURL value: String) -> UIImage? {
        guard let data = DataURLLimits.decodeBase64DataURL(value, prefix: "data:image/") else { return nil }
        return UIImage(data: data)
    }
}

private struct UserDocumentAttachmentChip: View {
    let attachment: Attachment

    var body: some View {
        Label(attachment.name, systemImage: "doc")
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.13), in: Capsule())
    }
}

struct AssistantBubble: View {
    let message: ChatMessage
    @EnvironmentObject var appState: AppState
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Keep identity in a compact header so the actual response can use
            // the full reading column instead of inheriting the avatar indent.
            HStack(spacing: 8) {
                ConduitAgentMark(
                    avatarURL: appState.profileAvatarURL(for: appState.activeProfile),
                    displayName: appState.profileDisplayName(appState.activeProfile)
                )

                Text(appState.profileDisplayName(appState.activeProfile))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                MessageTimestampLabel(timestamp: message.timestamp)

            }

            if !message.content.isEmpty {
                MarkdownText(
                    source: message.content,
                    gatewayMediaDataURL: { path in
                        await appState.gatewayMediaDataURL(for: path, profile: appState.activeProfile)
                    }
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let code = message.code {
                ChatCodeBlock(source: code)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 4) {
                Spacer(minLength: 0)

                Button {
                    copyResponse()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.conduitAccent : Color.secondary)
                .accessibilityLabel(copied ? "Response copied" : "Copy response")

                Button {
                    Haptics.medium()
                    Task { await appState.branchFromAssistantMessage(message.id) }
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(appState.isBusy || appState.isBranchingChat)
                .opacity(appState.isBusy || appState.isBranchingChat ? 0.45 : 1)
                .accessibilityLabel("Branch from this response")
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyResponse() {
        UIPasteboard.general.string = message.content
        Haptics.light()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

// MARK: - System Message (slash command output)

struct SystemBubble: View {
    let message: ChatMessage

    private var isRuntimeNotice: Bool {
        MessageNormalizer.systemNoticeText(fromText: message.rawContent ?? message.content) != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isRuntimeNotice ? "info.circle" : "terminal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.conduitAccent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(isRuntimeNotice ? "System" : "Command")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.conduitAccent)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer(minLength: 8)
                    MessageTimestampLabel(timestamp: message.timestamp, tone: .supporting)
                }

                MarkdownText(source: message.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color.conduitAccent.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.conduitAccent.opacity(0.15), lineWidth: 1)
        }
        .padding(.horizontal, 4)
    }
}

private struct ReviewSummaryCard: View {
    let activity: ReviewActivity
    let timestamp: String
    @EnvironmentObject private var appState: AppState
    @State private var expanded = false

    private var details: [String] { activity.details?.filter { !$0.isEmpty } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                guard !details.isEmpty else { return }
                withAnimation(ConduitMotion.response) { expanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "internaldrive.fill")
                        .foregroundStyle(.conduitAura)
                        .frame(width: 28, height: 28)
                        .background(Color.conduitAura.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SELF-IMPROVEMENT REVIEW")
                            .font(.caption2.weight(.bold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        SelectableTextView(
                            text: activity.summary,
                            font: .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold),
                            textColor: .label
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 8)
                    MessageTimestampLabel(timestamp: timestamp, tone: .supporting)
                    if !details.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(details.isEmpty)
            .accessibilityLabel(details.isEmpty ? activity.summary : (expanded ? "Collapse review details" : "Expand review details"))

            if expanded, !details.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                        SelectableTextView(
                            text: detail,
                            font: .preferredFont(forTextStyle: .callout),
                            textColor: .secondaryLabel
                        )
                    }
                }
                .padding(.top, 2)
            }

            if let fullSessionId = activity.fullSessionId, !fullSessionId.isEmpty {
                Button {
                    appState.requestOpenSession(fullSessionId)
                } label: {
                    Label("Open full review", systemImage: "arrow.up.forward.square")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .conduitGlassControl(cornerRadius: 14, tint: .conduitAccent.opacity(0.14))
            }
        }
        .padding(14)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.09))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.conduitAura.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct ModelChangeSummaryCard: View {
    let model: String
    let provider: String
    let timestamp: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.conduitAccent)
                .frame(width: 28, height: 28)
                .background(Color.conduitAccent.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("MODEL UPDATED")
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                SelectableTextView(
                    text: "Model has been changed to \(provider)/\(model)",
                    font: .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold),
                    textColor: .label
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 8)
            MessageTimestampLabel(timestamp: timestamp, tone: .supporting)
        }
        .padding(14)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAccent.opacity(0.07))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.conduitAccent.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ThinkingCard: View {
    let message: ChatMessage
    @EnvironmentObject var appState: AppState
    @State private var expanded = false

    var body: some View {
        if appState.displayPreferences.showReasoning, !message.content.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ConduitAgentMark(
                    avatarURL: appState.profileAvatarURL(for: appState.activeProfile),
                    displayName: appState.profileDisplayName(appState.activeProfile)
                )

                DisclosureGroup(isExpanded: $expanded) {
                    SelectableTextView(
                        text: message.content,
                        font: .preferredFont(forTextStyle: .callout),
                        textColor: .secondaryLabel
                    )
                        .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Label("Thinking", systemImage: "brain.head.profile")
                        MessageTimestampLabel(timestamp: message.timestamp)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .tint(.conduitAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .conduitGlassSurface(cornerRadius: 16, tint: .conduitAccent.opacity(0.06))

                Spacer(minLength: 28)
            }
        }
    }
}

private enum MessageTimestampTone {
    case subtle
    case supporting
}

private struct MessageTimestampLabel: View {
    let timestamp: String
    var tone: MessageTimestampTone = .subtle

    var body: some View {
        if let label = MessageTimestampFormatter.displayString(for: timestamp) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tone == .supporting ? Color.conduitAccent.opacity(0.78) : Color.conduitAccent.opacity(0.70))
                .monospacedDigit()
                .accessibilityLabel("Sent \(label)")
        }
    }
}

enum MessageTimestampFormatter {
    static func displayString(for rawTimestamp: String) -> String? {
        let value = rawTimestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let date = date(from: value) else {
            // Historical and external sessions can already provide a
            // display-ready timestamp. Keep it visible instead of dropping it.
            return value
        }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private static func date(from rawTimestamp: String) -> Date? {
        let value = rawTimestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let number = Double(value) {
            let seconds = number > 10_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }

        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

// MARK: - Tool Card

struct ToolCard: View {
    let message: ChatMessage
    @State private var expanded = false
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.displayPreferences.showToolProgress, let tool = message.tool {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(ConduitMotion.response) {
                        Haptics.light()
                        expanded.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Image(systemName: tool.status == .running ? "gear" : "checkmark.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(tool.status == .running ? .orange : .green)
                                .rotationEffect(.degrees(tool.status == .running ? 360 : 0))
                                .animation(tool.status == .running ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: tool.status)

                            Text(tool.name)
                                .font(.system(.caption, design: .monospaced).bold())
                                .foregroundStyle(.secondary)

                            MessageTimestampLabel(timestamp: message.timestamp, tone: .supporting)

                            Spacer()

                            if expanded {
                                Image(systemName: "chevron.up")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                if !expanded, let preview = collapsedPreview(for: tool) {
                    SelectableTextView(
                        text: preview,
                        font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular),
                        textColor: UIColor(Color.primary.opacity(0.74)),
                        maximumNumberOfLines: 1
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if let input = tool.input, !input.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Input")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.tertiary)
                                SelectableTextView(
                                    text: Self.truncateForDisplay(input, maxLines: 500),
                                    font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular),
                                    textColor: .secondaryLabel,
                                    maximumNumberOfLines: 0
                                )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if let output = tool.output, !output.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.tertiary)
                                SelectableTextView(
                                    text: Self.truncateForDisplay(output, maxLines: 500),
                                    font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular),
                                    textColor: .secondaryLabel,
                                    maximumNumberOfLines: 0
                                )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .conduitGlassSurface(cornerRadius: 18, tint: tool.status == .running ? .conduitAccent.opacity(0.10) : .clear)
            .onAppear {
                if appState.displayPreferences.expandToolsByDefault {
                    expanded = true
                }
            }
        }
    }

    private func collapsedPreview(for tool: ToolActivity) -> String? {
        let raw = (tool.input?.isEmpty == false ? tool.input : tool.output) ?? ""
        let preview = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? nil : preview
    }

    /// Limits tool output rendered in the non-scrolling SelectableTextView to
    /// avoid a single massive layout pass when expanding large command logs or
    /// file reads. Returns the original string if under the cap; otherwise
    /// truncates to the first `maxLines` lines with an ellipsis indicator.
    static func truncateForDisplay(_ text: String, maxLines: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > maxLines else { return text }
        return lines.prefix(maxLines).joined(separator: "\n") + "\n… (\(lines.count - maxLines) more lines)"
    }
}

// MARK: - Clarify Card

struct ClarifyCard: View {
    let message: ChatMessage
    @EnvironmentObject var appState: AppState
    @State private var customAnswer = ""

    var body: some View {
        if let clarify = message.clarify {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.bubble")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle(for: clarify.status))
                            .font(.caption2.weight(.bold))
                            .tracking(0.5)
                            .foregroundStyle(statusColor(for: clarify.status))
                        SelectableTextView(
                            text: clarify.question,
                            font: .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold),
                            textColor: .label
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 8)
                    if clarify.status == .submitting {
                        ProgressView().controlSize(.small)
                    } else if clarify.status == .answered, clarify.answer != nil {
                        // Only this device's accepted answer earns the check;
                        // an answered-elsewhere settle renders no checkmark so
                        // the header agrees with the body copy.
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    MessageTimestampLabel(timestamp: message.timestamp, tone: .supporting)
                }

                if clarify.status == .answered, let answer = clarify.answer {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("YOUR ANSWER")
                            .font(.caption2.weight(.bold))
                            .tracking(0.5)
                            .foregroundStyle(.green)
                        SelectableTextView(
                            text: answer,
                            font: .preferredFont(forTextStyle: .subheadline),
                            textColor: .label
                        )
                    }
                    .padding(12)
                    .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else if clarify.status == .answered {
                    // Answered elsewhere (relay 409): settled, but this device's
                    // rejected text must not display as what Hermes received —
                    // and the disabled controls should not linger either.
                    Text("Answered on another device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(clarify.choices) { choice in
                        Button {
                            send(choice.value, for: clarify)
                        } label: {
                            HStack {
                                Text(choice.label)
                                    .font(.body)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .conduitGlassControl(cornerRadius: 14, tint: .conduitAccent.opacity(0.12))
                            .foregroundStyle(.primary)
                        }
                        .disabled(!canRespond(clarify.status))
                    }

                    HStack(spacing: 8) {
                        TextField(
                            clarify.choices.isEmpty ? "Type your answer…" : "Something else…",
                            text: $customAnswer,
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .submitLabel(.send)
                        .onSubmit { send(customAnswer, for: clarify) }
                        .disabled(!canRespond(clarify.status))

                        Button {
                            send(customAnswer, for: clarify)
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(Color.orange, in: Circle())
                        .disabled(customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canRespond(clarify.status))
                        .opacity(customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canRespond(clarify.status) ? 0.45 : 1)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let error = clarify.error, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .conduitGlassSurface(cornerRadius: 22, tint: .conduitAccent.opacity(0.08))
        }
    }

    private func canRespond(_ status: ClarifyActivity.Status) -> Bool {
        status == .pending || status == .error
    }

    private func send(_ answer: String, for clarify: ClarifyActivity) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canRespond(clarify.status) else { return }
        customAnswer = ""
        Task { await appState.respondToClarify(requestId: clarify.requestId, answer: trimmed) }
    }

    private func statusTitle(for status: ClarifyActivity.Status) -> String {
        switch status {
        case .pending: return "NEEDS YOUR INPUT"
        case .submitting: return "SENDING ANSWER"
        case .answered: return "ANSWERED"
        case .error: return "TRY AGAIN"
        }
    }

    private func statusColor(for status: ClarifyActivity.Status) -> Color {
        switch status {
        case .pending, .submitting: return .orange
        case .answered: return .green
        case .error: return .red
        }
    }
}

// MARK: - Approval Card

struct ApprovalCard: View {
    let message: ChatMessage
    @EnvironmentObject var appState: AppState
    @State private var confirmAlways = false

    var body: some View {
        if let approval = message.approval {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(statusColor(for: approval.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle(for: approval.status))
                            .font(.caption2.weight(.bold))
                            .tracking(0.5)
                            .foregroundStyle(statusColor(for: approval.status))
                        SelectableTextView(
                            text: approval.description,
                            font: .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold),
                            textColor: .label
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 8)
                    if approval.status == .submitting {
                        ProgressView().controlSize(.small)
                    } else if approval.status == .approved || approval.status == .rejected {
                        Image(systemName: approval.status == .approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(statusColor(for: approval.status))
                    }
                    MessageTimestampLabel(timestamp: message.timestamp, tone: .supporting)
                }

                if !approval.command.isEmpty {
                    SelectableTextView(
                        text: approval.command,
                        font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular),
                        textColor: .label,
                        maximumNumberOfLines: 5
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let choice = approval.choice,
                   approval.status == .approved || approval.status == .rejected {
                    Label(decisionTitle(choice), systemImage: approval.status == .approved ? "checkmark" : "xmark")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(statusColor(for: approval.status))
                } else {
                    HStack(spacing: 8) {
                        Button {
                            send("once", for: approval)
                        } label: {
                            Label("Run", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!allows("once", for: approval) || !canRespond(approval.status))

                        if allows("session", for: approval) {
                            Button("Allow session") {
                                send("session", for: approval)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canRespond(approval.status))
                        }

                        if allows("always", for: approval) {
                            Button("Always allow") {
                                confirmAlways = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canRespond(approval.status))
                        }

                        Spacer(minLength: 0)

                        Button("Reject", role: .destructive) {
                            send("deny", for: approval)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!allows("deny", for: approval) || !canRespond(approval.status))
                    }
                    .font(.subheadline.weight(.medium))
                }

                if let error = approval.error, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .conduitGlassSurface(cornerRadius: 22, tint: statusColor(for: approval.status).opacity(0.08))
            .confirmationDialog(
                "Always allow this command?",
                isPresented: $confirmAlways,
                titleVisibility: .visible
            ) {
                Button("Always allow", role: .destructive) {
                    send("always", for: approval)
                }
            } message: {
                Text("Hermes will save this approval pattern for future commands.")
            }
        }
    }

    private func allows(_ choice: String, for approval: ApprovalActivity) -> Bool {
        let choices = approval.choices ?? (approval.smartDenied ? ["once", "deny"] : ["once", "session", "always", "deny"])
        if choice == "always" && !approval.allowPermanent { return false }
        return choices.contains(choice)
    }

    private func canRespond(_ status: ApprovalActivity.Status) -> Bool {
        status == .pending || status == .error
    }

    private func send(_ choice: String, for approval: ApprovalActivity) {
        guard allows(choice, for: approval), canRespond(approval.status) else { return }
        Task { await appState.respondToApproval(messageId: message.id, choice: choice) }
    }

    private func decisionTitle(_ choice: String) -> String {
        switch choice {
        case "once": return "Approved once"
        case "session": return "Approved for this session"
        case "always": return "Always allowed"
        case "deny": return "Rejected"
        default: return choice
        }
    }

    private func statusTitle(for status: ApprovalActivity.Status) -> String {
        switch status {
        case .pending: return "APPROVAL NEEDED"
        case .submitting: return "SENDING DECISION"
        case .approved: return "APPROVED"
        case .rejected: return "REJECTED"
        case .error: return "TRY AGAIN"
        }
    }

    private func statusColor(for status: ApprovalActivity.Status) -> Color {
        switch status {
        case .pending, .submitting: return .orange
        case .approved: return .green
        case .rejected, .error: return .red
        }
    }
}

// MARK: - Streaming Bubble

struct StreamingBubble: View {
    let text: String
    let active: Bool
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Streaming uses the same reading column and Markdown renderer as
            // a completed reply. Only the active mark/status changes, so the
            // final message settles in rather than swapping presentation.
            HStack(spacing: 8) {
                ConduitAgentMark(
                    isActive: true,
                    avatarURL: appState.profileAvatarURL(for: appState.activeProfile),
                    displayName: appState.profileDisplayName(appState.activeProfile)
                )

                Text(appState.profileDisplayName(appState.activeProfile))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(active ? "Responding" : "Finishing")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                ProgressView()
                    .controlSize(.mini)
                    .tint(.conduitAccent)
            }

            StreamingText(
                text: text,
                active: active,
                gatewayMediaDataURL: { path in
                    await appState.gatewayMediaDataURL(for: path, profile: appState.activeProfile)
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ConduitAgentMark(
                isActive: true,
                avatarURL: appState.profileAvatarURL(for: appState.activeProfile),
                displayName: appState.profileDisplayName(appState.activeProfile)
            )

            WorkingStatusLabel()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .conduitGlassSurface(cornerRadius: 16, tint: .conduitAccent.opacity(0.07))
                .accessibilityLabel("\(appState.profileDisplayName(appState.activeProfile)) is working")

            Spacer()
        }
    }
}

private struct WorkingStatusLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let text = "Working…"
    private let cycleDuration = 1.9
    private let sweepFraction = 0.72

    var body: some View {
        Group {
            if reduceMotion {
                label
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    let cycle = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
                    let progress = CGFloat(min(cycle / sweepFraction, 1))

                    label
                        .overlay {
                            GeometryReader { proxy in
                                let highlightWidth = max(proxy.size.width * 0.45, 18)
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        Color.conduitAccent.opacity(0.18),
                                        Color.conduitAccentSoft,
                                        Color.conduitAccent.opacity(0.18),
                                        .clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: highlightWidth)
                                .offset(
                                    x: -highlightWidth
                                        + (proxy.size.width + highlightWidth) * progress
                                )
                            }
                            .mask { label }
                        }
                }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var label: some View {
        Text(text)
    }
}

// MARK: - Empty State

struct EmptyChatState: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 18) {
            ConduitAppIconArtwork(
                assetName: appState.appIconChoice.previewAssetName,
                size: 62
            )
            VStack(spacing: 6) {
                Text("Start a conversation")
                    .font(.title3.weight(.semibold))
                Text("Conduit is ready when you are.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .conduitGlassSurface(cornerRadius: 28, tint: .conduitAccent.opacity(0.06))
    }
}
struct ConduitAgentMark: View {
    var isActive = false
    var avatarURL: URL?
    var displayName = "Hermes"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        ProfileAvatarView(profile: "", displayName: displayName, url: avatarURL)
            .overlay {
                Circle()
                    .strokeBorder(Color.conduitAccent.opacity(isActive ? 0.52 : 0.22), lineWidth: 1)
            }
            .shadow(color: Color.conduitAccent.opacity(isActive ? 0.42 : 0), radius: isBreathing ? 9 : 3)
            .scaleEffect(isBreathing ? 1.06 : 1)
            .task(id: isActive) {
                guard isActive, !reduceMotion else {
                    isBreathing = false
                    return
                }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
    }
}
