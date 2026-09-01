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
    @State private var renderedScrollContent: ChatRenderedScrollContent?
    @State private var renderedScrollTargets = ChatRenderedScrollTargets()
    @State private var viewportSnapshotProviderID = UUID()
    @State private var viewport = ChatViewportController()
    /// The animated bottom command whose delayed retry is still armed. A
    /// coalesced follow correction must not execute while this is set: the
    /// animation is mid-flight toward the bottom, the measured drift is
    /// transient, and a second scrollTo against the same anchor mid-
    /// animation churns the lazy realization (observed as settled-row
    /// re-materialization in the hosted transcript fixture). The retry
    /// itself guarantees the animated command lands.
    @State private var armedAnimatedBottomRetry: ChatViewportCommand?
    /// Lifecycle-aware backfill task: cancelled when the view disappears so
    /// a late response cannot mutate viewport state after teardown. (The
    /// session/profile staleness of the response itself is AppState's
    /// concern — this is view-lifetime only.)
    @State private var backfillViewportTask: Task<Void, Never>?
    @GestureState private var isDraggingChat = false

    private var renderedScrollSessionKey: ChatScrollSessionKey? { viewport.renderedSessionKey }

    private var scrollViewportMaxY: CGFloat? { scrollViewportFrame?.maxY }

    private var scrollViewportMinY: CGFloat? { scrollViewportFrame?.minY }

    /// Single source of follow-latest truth: the controller's mode.
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

    private var chatMessageScrollTargets: [ChatMessageScrollTarget] {
        viewport.targets
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

    /// Whether "Load earlier messages" is offered right now. AppState owns
    /// the complete truth — window state, transcript content, and
    /// active-conversation ownership — the exact predicate
    /// `loadEarlierMessages` enforces, so the control can never render for
    /// a window the action would silently reject.
    private var transcriptBackfillAvailable: Bool {
        appState.canLoadEarlierMessagesForActiveConversation
    }

    private var transcriptBackfillIsLoading: Bool {
        appState.persistedTranscriptWindow?.isLoadingEarlier == true
    }

    /// Transcript-top affordance for bounded history: fetches the next older
    /// page and prepends it. The currently visible row is captured as the
    /// viewport anchor before the fetch so the prepend lands without moving
    /// the user's position. Label-exposed for accessibility — never
    /// icon-only — and the loading state is announced by the combined
    /// progress row.
    private var transcriptTopBackfillControl: some View {
        Group {
            if transcriptBackfillIsLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading earlier messages")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } else {
                Button {
                    // A second tap while the first backfill is in flight
                    // must not overwrite the armed anchor (the single-flight
                    // guard in AppState would then discard nothing and the
                    // discharge below would kill the first request's anchor).
                    guard !transcriptBackfillIsLoading else { return }
                    ChatViewportTrace.shared.log("event loadEarlier")
                    let armedKey = renderedScrollSessionKey ?? activeScrollSessionKey
                    viewport.olderPageBackfillRequested(
                        anchorMessageID: viewport.stableTopMessageID,
                        sessionKey: armedKey
                    )
                    backfillViewportTask?.cancel()
                    backfillViewportTask = Task { @MainActor in
                        let didPrepend = await appState.loadEarlierMessages()
                        guard !Task.isCancelled else { return }
                        if !didPrepend {
                            // Nothing landed (short page, transient failure,
                            // all-duplicate page): discharge the anchor so it
                            // can never re-pin on a later unrelated change.
                            // Scoped to the session this tap armed — a stale
                            // task must not clobber a newer conversation's
                            // anchor.
                            viewport.prependAnchorDischarged(matching: armedKey)
                        }
                    }
                } label: {
                    Label("Load earlier messages", systemImage: "clock.arrow.circlepath")
                        .font(.footnote.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.12))
                .accessibilityLabel("Load earlier messages")
                .accessibilityHint("Fetches the next older page of this conversation")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    /// Latest global frames + transcript order of rendered stable rows for
    /// the current scope. Only message rows report frames (streaming/typing/
    /// markers never do), so ephemeral identifiers cannot enter stable-top
    /// observation.
    private var renderedRowFrames: [String: ChatRenderedRowGeometry] {
        guard let scope = renderedScrollScope else { return [:] }
        return renderedScrollTargets.rowFrames(in: scope)
    }

    private var renderedScrollScope: ChatRenderedScrollScope? {
        viewport.renderedScrollScope
    }

    /// The chat-only text-size preference (issue #85). Local, device-only
    /// @AppStorage like ComposerReturnKey — never synced to Hermes or the
    /// profile. Injected once here so every transcript Markdown path
    /// (settled, streaming, large-document, tables, code) resolves the same
    /// typography, while non-chat subtrees keep the `.default` environment
    /// value and today's appearance.
    @AppStorage(ChatTypography.preferenceKey) private var chatTextSizeRaw = ChatTypography.defaultSize.rawValue

    private var chatTextSize: ChatTextSize {
        ChatTypography.resolve(rawValue: chatTextSizeRaw)
    }

    var body: some View {
        let _ = TranscriptPerf.note(.chatViewBody)
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                sessionObservers(
                    proxy: proxy,
                    content: transcriptObservers(
                        proxy: proxy,
                        content: lifecycleObservers(
                            proxy: proxy,
                            content: chatScrollView(proxy: proxy)
                        )
                    )
                )
            }

            // Composer + control bar
            ComposerBar()
        }
        .environment(\.chatTextSize, chatTextSize)
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

    // MARK: - Scroll construction (layered so the type-checker can cope)

    private func chatScrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                Color.clear
                    .frame(height: 1)
                    .id(topAnchor)

                if transcriptBackfillAvailable {
                    transcriptTopBackfillControl
                }

                if appState.messages.isEmpty {
                    EmptyChatState().padding(.top, 60)
                }

                // Iterate the targets collection directly: wrapping it in
                // Array(enumerated()) copied the entire transcript into a
                // fresh tuple array on EVERY body evaluation — O(message
                // count) allocation churn at streaming/reasoning cadence in
                // deep sessions. Row identity (target.id) and the transcript
                // order needed by row geometry (target.order, maintained by
                // the scroll-target cache) are unchanged.
                ForEach(chatMessageScrollTargets) { target in
                    MessageBubble(message: target.message, gatewayResolver: appState.gatewayMediaResolver)
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
                }

                // Live reasoning renders from the projection, not the settled
                // transcript: per-publish reasoning changes re-render only
                // this card, never the ForEach data or the scroll-target
                // cache. Chronology matches the pre-projection transcript —
                // thinking streams at the tail, before the assistant answer.
                if let segment = appState.liveReasoningSegment {
                    ThinkingCard(
                        message: ChatMessage(
                            id: segment.id,
                            role: .reasoning,
                            content: segment.content,
                            timestamp: segment.timestamp,
                            author: appState.activeProfile
                        )
                    )
                    .id(segment.id)
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

    private func lifecycleObservers(proxy: ScrollViewProxy, content: some View) -> some View {
        content
            .onAppear {
                performViewportEffects(
                    viewport.renderedSessionChanged(
                        to: activeScrollSessionKey,
                        identity: appState.activeChatScrollSessionIdentity,
                        viaNotification: false,
                        viewportTransitionGeneration: appState.chatViewportTransitionGeneration
                    ),
                    using: proxy
                )
                performViewportEffects(
                    viewport.transcriptChanged(
                        messages: appState.messages,
                        transcriptRevision: appState.chatTranscriptRevision,
                        viewportTransitionGeneration: appState.chatViewportTransitionGeneration,
                        isInitialSync: true
                    ),
                    using: proxy
                )
                appState.installChatViewportSnapshotProvider(
                    id: viewportSnapshotProviderID,
                    capture: {
                        // @State reads through the captured view struct see
                        // current values (State storage is a reference box).
                        self.viewport.renderedViewportSnapshot()
                    }
                )
            }
            .onDisappear {
                performViewportEffects(viewport.viewDisappeared(), using: proxy)
                backfillViewportTask?.cancel()
                appState.removeChatViewportSnapshotProvider(id: viewportSnapshotProviderID)
            }
            .task(id: appState.chatResumeRestorationRequest?.generation) {
                guard let request = appState.chatResumeRestorationRequest else { return }
                await runViewportRestoration(request, using: proxy)
            }
            .onPreferenceChange(ChatBottomMarkerPreferenceKey.self) { value in
                bottomMarkerMaxY = value
                // Facts first: the handoff readiness decision reads the
                // controller's geometry copy, so it must see this tick.
                performViewportEffects(
                    viewport.layoutMetricsChanged(facts: currentLayoutFacts()),
                    using: proxy
                )
                recordNotificationHandoffLayout()
                finishNotificationHandoffIfReady(using: proxy)
            }
            .onPreferenceChange(ChatViewportFramePreferenceKey.self) { value in
                scrollViewportFrame = value
                performViewportEffects(
                    viewport.layoutMetricsChanged(facts: currentLayoutFacts()),
                    using: proxy
                )
                recordNotificationHandoffLayout()
                finishNotificationHandoffIfReady(using: proxy)
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
            .onChange(of: viewport.pendingFollowCorrection) { _, pending in
                // The coalesced follow-correction executor: the controller
                // scheduled (state changed) from a geometry preference
                // callback; SwiftUI delivers this observer on the update
                // turn that change created — after the layout pass, riding
                // its transaction, at most once per pending token.
                guard let pending else { return }
                executePendingFollowCorrection(pending, using: proxy)
            }
    }

    private func transcriptObservers(proxy: ScrollViewProxy, content: some View) -> some View {
        content
            .onChange(of: appState.messages) { _, _ in
                performViewportEffects(
                    viewport.transcriptChanged(
                        messages: appState.messages,
                        transcriptRevision: appState.chatTranscriptRevision,
                        viewportTransitionGeneration: appState.chatViewportTransitionGeneration,
                        activeSessionKey: activeScrollSessionKey,
                        isOpeningNotificationSession: appState.isOpeningNotificationSession
                    ),
                    using: proxy
                )
            }
            .onChange(of: appState.chatResumeRestorationRequest) { oldRequest, newRequest in
                guard oldRequest != nil, newRequest == nil else { return }
                // The published request disappeared on the AppState side
                // (completed/abandoned/cancelled elsewhere).
                performViewportEffects(
                    viewport.restorationSystemCancelled(),
                    using: proxy
                )
            }
            .onChange(of: followsLatest) { _, _ in
                saveChatScrollPosition(for: renderedScrollSessionKey)
            }
    }

    private func sessionObservers(proxy: ScrollViewProxy, content: some View) -> some View {
        content
            .onChange(of: appState.chatScrollRequest) { _, _ in
                ChatViewportTrace.shared.log("event explicitLatest (send pulse)")
                performViewportEffects(viewport.explicitLatestRequested(), using: proxy)
            }
            .onChange(of: appState.chatScrollToTopRequest) { _, request in
                ChatViewportTrace.shared.log("event explicitTop request=\(request)")
                performViewportEffects(
                    viewport.explicitTopRequested(request: request),
                    using: proxy
                )
            }
            .onChange(of: appState.activeSessionId) { _, _ in
                ChatViewportTrace.shared.log(
                    "event sessionChanged viaNotification=\(appState.isOpeningNotificationSession)"
                )
                performViewportEffects(
                    viewport.renderedSessionChanged(
                        to: activeScrollSessionKey,
                        identity: appState.activeChatScrollSessionIdentity,
                        viaNotification: appState.isOpeningNotificationSession,
                        viewportTransitionGeneration: appState.chatViewportTransitionGeneration
                    ),
                    using: proxy
                )
            }
            .onChange(of: appState.activeProfile) { _, _ in
                ChatViewportTrace.shared.log(
                    "event profileChanged viaNotification=\(appState.isOpeningNotificationSession)"
                )
                // Mirror-only transcript sync: the session-change event below
                // owns the single follow scroll for a real switch, so a
                // profile change cannot emit a duplicate latest command.
                performViewportEffects(
                    viewport.transcriptChanged(
                        messages: appState.messages,
                        transcriptRevision: appState.chatTranscriptRevision,
                        viewportTransitionGeneration: appState.chatViewportTransitionGeneration,
                        isInitialSync: true,
                        activeSessionKey: activeScrollSessionKey,
                        isOpeningNotificationSession: appState.isOpeningNotificationSession
                    ),
                    using: proxy
                )
                performViewportEffects(
                    viewport.renderedSessionChanged(
                        to: activeScrollSessionKey,
                        identity: appState.activeChatScrollSessionIdentity,
                        viaNotification: appState.isOpeningNotificationSession,
                        viewportTransitionGeneration: appState.chatViewportTransitionGeneration
                    ),
                    using: proxy
                )
            }
            .onChange(of: appState.activeChatScrollSessionIdentity) { _, _ in
                performViewportEffects(
                    viewport.activeIdentityRefreshed(
                        identity: appState.activeChatScrollSessionIdentity,
                        key: activeScrollSessionKey
                    ),
                    using: proxy
                )
            }
            .onChange(of: appState.isOpeningNotificationSession) { _, isOpening in
                if isOpening {
                    ChatViewportTrace.shared.log("event notificationHandoffBegan")
                    performViewportEffects(
                        viewport.notificationHandoffBegan(destination: nil),
                        using: proxy
                    )
                } else {
                    performViewportEffects(
                        viewport.notificationHandoffDestinationReady(activeKey: activeScrollSessionKey),
                        using: proxy
                    )
                }
            }
    }

    private func saveChatScrollPosition(for preferredKey: ChatScrollSessionKey? = nil) {
        let currentKey = preferredKey ?? renderedScrollSessionKey ?? activeScrollSessionKey
        guard let sessionKey = ChatViewportPersistenceSupport.persistenceSessionKey(
            currentKey: currentKey,
            identity: appState.activeChatScrollSessionIdentity
        ) else { return }
        guard let snapshot = currentChatViewportSnapshot() else { return }
        appState.recordChatViewport(snapshot, for: sessionKey)
    }

    private func currentChatViewportSnapshot() -> ChatScrollSnapshot? {
        viewport.renderedViewportSnapshot()?.snapshot
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

    /// Controller-driven restoration: the .task restarts whenever the
    /// published request generation changes; each tick feeds the controller
    /// current observations and executes its effects. Cancellation comes
    /// from task identity (generation change / view teardown) or the
    /// system-cancel onChange; identity drift cancels via the session-change
    /// event. All retries are bounded inside the controller.
    @MainActor
    private func runViewportRestoration(
        _ request: ChatResumeRestorationRequest,
        using proxy: ScrollViewProxy
    ) async {
        performViewportEffects(viewport.restorationRequested(request), using: proxy)
        while !Task.isCancelled, viewport.restorationIsActive {
            let effects = viewport.restorationTick(
                messages: appState.messages,
                transcriptRevision: appState.chatTranscriptRevision,
                viewportTransitionGeneration: appState.chatViewportTransitionGeneration,
                renderedContent: renderedScrollContent,
                installedTargets: renderedScrollTargets,
                topVisibleID: viewport.stableTopMessageID,
                isNearBottom: viewport.isNearBottom
            )
            performViewportEffects(effects, using: proxy)
            guard viewport.restorationIsActive else { return }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
        }
    }

    /// A notification handoff completes only after the destination transcript
    /// has emitted its own geometry. This is a layout fact rather than a
    /// timer, so a long lazy transcript cannot inherit the old conversation's
    /// offset. The controller owns the handoff state; these helpers feed it
    /// facts and ask for the completion decision.
    private func recordNotificationHandoffLayout() {
        guard viewport.notificationHandoffAwaitingLayout,
              let handoffKey = viewport.notificationHandoff?.sessionKey,
              appState.activeChatScrollSessionIdentity.areEquivalent(
                handoffKey,
                activeScrollSessionKey
              ),
              bottomMarkerMaxY != nil,
              scrollViewportMaxY != nil else { return }
        _ = viewport.notificationHandoffLayoutMeasured()
    }

    private func finishNotificationHandoffIfReady(using proxy: ScrollViewProxy) {
        guard !appState.isOpeningNotificationSession else { return }
        performViewportEffects(
            viewport.notificationHandoffDestinationReady(activeKey: activeScrollSessionKey),
            using: proxy
        )
    }

    // MARK: - Viewport controller wiring

    private func currentLayoutFacts() -> ChatViewportLayoutFacts {
        let scope = renderedScrollScope
        let frames = renderedRowFrames.map { id, geometry in
            ChatRenderedRowFrame(
                id: id,
                minY: geometry.frame.minY,
                maxY: geometry.frame.maxY,
                order: geometry.order,
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
            renderedScope: scope,
            timestamp: CFAbsoluteTimeGetCurrent()
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
                await ChatViewportPersistenceSupport.waitForNextMainActorTurn()
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
        case .scheduleFollowCorrection(let token):
            ChatViewportTrace.shared.log(
                "follow correction scheduled seq=\(token.sequence) gen=\(token.generation)"
            )
            // Executed by the pendingFollowCorrection observer below: the
            // correction must ride the SwiftUI update turn that the
            // scheduling state change already created — never its own
            // MainActor task (a standalone task commits a separate layout
            // transaction, which re-materializes lazy rows the transcript
            // fixtures measure), and never synchronously inside the geometry
            // preference callback that scheduled it (that
            // scrollTo → layout → preference → scrollTo loop is the
            // ScrollViewCommitMutation watchdog storm).
            break
        }
    }

    /// Executes the coalesced bottom-follow correction on the update turn
    /// that the controller's pending-correction state change created. This
    /// is the ONLY place a follow correction scrolls. MainActor-isolated to
    /// match the neighboring scroll-execution entry points: it mutates
    /// viewport state, writes the trace ring, and drives ScrollViewProxy.
    @MainActor
    private func executePendingFollowCorrection(
        _ token: ChatFollowCorrectionToken,
        using proxy: ScrollViewProxy
    ) {
        if let armed = armedAnimatedBottomRetry {
            // An animated bottom command is still in flight with its own
            // retry armed; a correction now would fight the animation. Drop
            // this cycle — genuinely new growth schedules a fresh one.
            ChatViewportTrace.shared.log(
                "follow correction skipped, animated retry armed gen=\(armed.generation)"
            )
            _ = viewport.followCorrectionDue(token)
            return
        }
        ChatViewportTrace.shared.log(
            "follow correction due gen=\(token.generation)"
        )
        performViewportEffects(
            viewport.followCorrectionDue(token),
            using: proxy
        )
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
        if case .bottom = command.destination {
            // Mark the flight window: the retry disarms below, and follow
            // corrections defer to the animation meanwhile.
            armedAnimatedBottomRetry = command
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            if armedAnimatedBottomRetry == command {
                armedAnimatedBottomRetry = nil
            }
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
            case .prependAnchor(let id):
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

/// Routes a transcript row to its presentation. The expensive settled
/// content of each row type lives behind an Equatable gate (see
/// SettledAssistantMessageContent and friends) so a streaming publish —
/// which re-creates every mounted row through this switch — cannot force
/// settled Markdown presentation to re-evaluate.
struct MessageBubble: View {
    let message: ChatMessage
    let gatewayResolver: GatewayMediaDataURLResolver?
    @EnvironmentObject var appState: AppState

    var body: some View {
        let _ = TranscriptPerf.note(.settledBubbleBody)
        switch message.role {
        case .user:
            UserBubble(message: message, gatewayResolver: gatewayResolver)
        case .assistant:
            AssistantBubble(
                message: message,
                readAloudController: appState.messageReadAloudController,
                gatewayResolver: gatewayResolver
            )
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
            AssistantBubble(
                message: message,
                readAloudController: appState.messageReadAloudController,
                gatewayResolver: gatewayResolver
            )
        }
    }
}

struct UserBubble: View {
    let message: ChatMessage
    let gatewayResolver: GatewayMediaDataURLResolver?
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.chatTextSize) private var chatTextSize

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                UserMessageContent(
                    message: message,
                    gatewayResolver: gatewayResolver,
                    sizeCategory: sizeCategory,
                    chatTextSize: chatTextSize
                )
                    .equatable()

                MessageTimestampLabel(timestamp: message.timestamp)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// Settled user-row content: Markdown plus attachment previews. Equatable
/// over the message and the stable gateway resolver so streaming publishes
/// cannot re-evaluate it (same contract as
/// SettledAssistantMessageContent). Internal (not private) so the gate
/// contract is directly testable.
struct UserMessageContent: View, Equatable {
    let message: ChatMessage
    let gatewayResolver: GatewayMediaDataURLResolver?
    /// Explicit Dynamic Type input — see SettledAssistantMessageContent.
    let sizeCategory: ContentSizeCategory
    /// Explicit chat text-size input (issue #85): a preference change must
    /// re-open the gate and re-render, while ordinary streaming publishes —
    /// which leave both explicit inputs equal — keep the isolation.
    let chatTextSize: ChatTextSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.gatewayResolver === rhs.gatewayResolver
            && lhs.sizeCategory == rhs.sizeCategory
            && lhs.chatTextSize == rhs.chatTextSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownText(source: message.content, foregroundStyle: .white, usesAccentSurface: true)
            }

            if let attachments = message.attachments {
                ForEach(attachments) { attachment in
                    if attachment.kind == .image {
                        UserImageAttachmentPreview(attachment: attachment, gatewayResolver: gatewayResolver)
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
    let gatewayResolver: GatewayMediaDataURLResolver?
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
        .task(id: "\(attachment.uri)|\(gatewayResolver?.profile ?? "")") {
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
            } else if isGatewayImage, let gatewayResolver {
                gatewayImage = nil
                gatewayLoadFailed = false
                guard let dataURL = await gatewayResolver.dataURL(for: attachment.uri),
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

/// The settled half of an assistant row: identity header, Markdown body,
/// and code block. Equatable over immutable message presentation inputs so
/// a streaming publish re-creating this view is a no-op (`.equatable()`
/// skips body evaluation when inputs compare equal). Dynamic Type changes
/// still invalidate through the `\.sizeCategory` environment read.
struct SettledAssistantMessageContent: View, Equatable {
    let message: ChatMessage
    let displayName: String
    let avatarURL: URL?
    let gatewayResolver: GatewayMediaDataURLResolver?
    /// Explicit Dynamic Type input (read by the shell): equality describes
    /// every visual input, so a category change re-opens the gate and
    /// re-renders with fresh fonts (the Markdown render cache keys on the
    /// content size category). Other presentation traits the subtree
    /// consumes are render-time adaptive — color scheme resolves through
    /// UIKit trait collections, layout direction through TextKit — and do
    /// not require body re-evaluation.
    let sizeCategory: ContentSizeCategory
    /// Explicit chat text-size input (issue #85): equality describes every
    /// typography input, so a preference change re-opens the gate and
    /// re-renders (the render cache keys on the chat-size identity), while
    /// unrelated streaming publishes — equal inputs — stay gated.
    let chatTextSize: ChatTextSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.displayName == rhs.displayName
            && lhs.avatarURL == rhs.avatarURL
            && lhs.gatewayResolver === rhs.gatewayResolver
            && lhs.sizeCategory == rhs.sizeCategory
            && lhs.chatTextSize == rhs.chatTextSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Keep identity in a compact header so the actual response can use
            // the full reading column instead of inheriting the avatar indent.
            HStack(spacing: 8) {
                ConduitAgentMark(
                    avatarURL: avatarURL,
                    displayName: displayName
                )

                Text(displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                MessageTimestampLabel(timestamp: message.timestamp)

            }

            if !message.content.isEmpty {
                MarkdownText(
                    source: message.content,
                    gatewayMediaDataURL: gatewayResolver.map { resolver in
                        { path in await resolver.dataURL(for: path) }
                    }
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let code = message.code {
                ChatCodeBlock(source: code)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The dynamic half of an assistant row: copy/branch controls that depend
/// on busy state, kept small so their per-publish re-evaluation is cheap.
struct AssistantMessageActions: View {
    let message: ChatMessage
    @EnvironmentObject private var appState: AppState
    @State private var copied = false

    var body: some View {
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

/// The read-aloud control surface. This is deliberately the ONLY part of
/// an assistant row that observes the shared read-aloud controller, so a
/// playback state transition re-renders a 34pt button instead of every
/// response's Markdown in the transcript.
struct ReadAloudButton: View {
    let message: ChatMessage
    @ObservedObject var controller: MessageReadAloudController
    @EnvironmentObject private var appState: AppState

    private var isActive: Bool {
        controller.isActiveMessage(message.id)
    }

    private var unavailable: Bool {
        appState.readAloudUnavailableReason != nil
    }

    var body: some View {
        Button {
            if isActive {
                Haptics.medium()
            } else {
                Haptics.light()
            }
            appState.toggleReadAloud(message: message)
        } label: {
            Group {
                if case .preparing(let id) = controller.state, id == message.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isActive ? "stop.fill" : "speaker.wave.2")
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.conduitAccent : Color.secondary)
        .disabled(unavailable && !isActive)
        .opacity(unavailable && !isActive ? 0.45 : 1)
        .accessibilityLabel(isActive ? "Stop reading response" : "Read response aloud")
    }
}

struct AssistantBubble: View {
    let message: ChatMessage
    /// Held as a plain reference (not @ObservedObject): forwarding a
    /// controller instance must not subscribe this whole bubble to every
    /// read-aloud state transition. Only ReadAloudButton observes it.
    let readAloudController: MessageReadAloudController
    let gatewayResolver: GatewayMediaDataURLResolver?
    @EnvironmentObject var appState: AppState
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.chatTextSize) private var chatTextSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettledAssistantMessageContent(
                message: message,
                displayName: appState.profileDisplayName(appState.activeProfile),
                avatarURL: appState.profileAvatarURL(for: appState.activeProfile),
                gatewayResolver: gatewayResolver,
                sizeCategory: sizeCategory,
                chatTextSize: chatTextSize
            )
            .equatable()

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                AssistantMessageActions(message: message)

                if message.role == .assistant {
                    ReadAloudButton(message: message, controller: readAloudController)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - System Message (slash command output)

struct SystemBubble: View {
    let message: ChatMessage

    private var isRuntimeNotice: Bool {
        // Rows Hermes projected onto the timeline via `display_kind` are
        // runtime notices by construction, even though their projected text
        // (e.g. "Resumed interrupted turn") matches no legacy marker.
        message.displayKind != nil
            || MessageNormalizer.systemNoticeText(fromText: message.rawContent ?? message.content) != nil
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

/// Review activity summary. Intentionally OUTSIDE the chat text-size
/// preference (issue #85): these status/activity cards — like tool cards —
/// are not ordinary transcript Markdown and keep their fixed typography.
/// (Of the system-message surfaces, only `SystemBubble`'s Markdown body
/// follows `ChatTypography`.)
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

/// Model-change summary. Intentionally OUTSIDE the chat text-size
/// preference (issue #85) — a status/activity card with fixed typography;
/// see ReviewSummaryCard.
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

/// Settled reasoning-row content, gated the same way as assistant/user
/// content: identical presentation inputs skip body evaluation during
/// unrelated AppState publishes. Internal (not private) so the gate
/// contract is directly testable.
struct SettledThinkingCardContent: View, Equatable {
    let message: ChatMessage
    let displayName: String
    let avatarURL: URL?
    /// Explicit Dynamic Type input — see SettledAssistantMessageContent.
    let sizeCategory: ContentSizeCategory
    /// Explicit chat text-size input — see SettledAssistantMessageContent.
    let chatTextSize: ChatTextSize
    @State private var expanded = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.displayName == rhs.displayName
            && lhs.avatarURL == rhs.avatarURL
            && lhs.sizeCategory == rhs.sizeCategory
            && lhs.chatTextSize == rhs.chatTextSize
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ConduitAgentMark(
                avatarURL: avatarURL,
                displayName: displayName
            )

            DisclosureGroup(isExpanded: $expanded) {
                SelectableTextView(
                    text: message.content,
                    font: ChatTypography.font(for: .thinking, chatSize: chatTextSize),
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

struct ThinkingCard: View {
    let message: ChatMessage
    @EnvironmentObject var appState: AppState
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.chatTextSize) private var chatTextSize

    var body: some View {
        if appState.displayPreferences.showReasoning, !message.content.isEmpty {
            SettledThinkingCardContent(
                message: message,
                displayName: appState.profileDisplayName(appState.activeProfile),
                avatarURL: appState.profileAvatarURL(for: appState.activeProfile),
                sizeCategory: sizeCategory,
                chatTextSize: chatTextSize
            )
            .equatable()
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

/// Settled tool-row content, gated on the message and expansion default so
/// streaming publishes skip its SelectableTextView measurement work.
private struct SettledToolCardContent: View, Equatable {
    let message: ChatMessage
    let expandToolsByDefault: Bool
    /// Explicit Dynamic Type input — see SettledAssistantMessageContent.
    let sizeCategory: ContentSizeCategory
    @State private var expanded = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.expandToolsByDefault == rhs.expandToolsByDefault
            && lhs.sizeCategory == rhs.sizeCategory
    }

    var body: some View {
        if let tool = message.tool {
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
                                    text: ToolCard.truncateForDisplay(input, maxLines: 500),
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
                                    text: ToolCard.truncateForDisplay(output, maxLines: 500),
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
                if expandToolsByDefault {
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
}

struct ToolCard: View {
    let message: ChatMessage
    @EnvironmentObject var appState: AppState
    @Environment(\.sizeCategory) private var sizeCategory

    var body: some View {
        if appState.displayPreferences.showToolProgress, message.tool != nil {
            SettledToolCardContent(
                message: message,
                expandToolsByDefault: appState.displayPreferences.expandToolsByDefault,
                sizeCategory: sizeCategory
            )
            .equatable()
        }
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
