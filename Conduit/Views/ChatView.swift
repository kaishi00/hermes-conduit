//
//  ChatView.swift
//  Conduit
//
//  The main chat screen. This is THE APP — everything else is a drawer.
//

import SwiftUI
import UIKit
import ImageIO

private struct OptionalAccessibilityHint: ViewModifier {
    let hint: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(Text(verbatim: hint))
        } else {
            content
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @State private var viewportSnapshotProviderID = UUID()
    /// V2: someone is typing in the composer, which hides the minimised
    /// call's bar.
    @State private var composerTyping = false
    @Environment(\.accessibilityReduceMotion) private var composerReduceMotion
    /// V2: the composer floats over the transcript, which scrolls on under
    /// it and fades, instead of ending at a hard edge above it.
    @Environment(\.v2ComposerRests) private var composerFloats
    /// Owns the viewport: follows the latest message, holds the reader's
    /// place while browsing, restores saved positions. It reads and sets the
    /// transcript's UIScrollView directly (ChatScrollSurfaceLocator), so
    /// scroll ticks never reach SwiftUI state; it publishes only when a value
    /// the body renders from (`renderInputs`) changes. The jump buttons
    /// observe `scrollEngine.chrome` on their own (ChatJumpControls).
    @StateObject private var scrollEngine = ChatScrollEngine()
    /// Not observable on purpose: one stable instance rows read when built
    /// and write when tapped (see ChatRowDisclosure).
    @State private var rowDisclosure = ChatRowDisclosure()
    /// A run of steps opened or closed: its rows join or leave the stack.
    @State private var stepToggleRevision: UInt64 = 0
    /// The transcript scroll view's identity; a new one builds it again
    /// (ChatScrollEngineEvent.rebuildTranscript).
    @State private var transcriptScrollID = 0
    /// Carries the engine's requests to AppState and ScrollViewProxy. Holds
    /// both weakly, so the engine never retains this view.
    @State private var scrollEventRouter = ChatScrollEventRouter()
    @Environment(\.scenePhase) private var scenePhase
    /// Lifecycle-aware backfill task: cancelled when the view disappears so
    /// a late response cannot mutate viewport state after teardown. (The
    /// session/profile staleness of the response itself is AppState's
    /// concern — this is view-lifetime only.)
    @State private var backfillViewportTask: Task<Void, Never>?
    @State private var latestAnimationTask: Task<Void, Never>?
    /// The overview of every pinned reply, from the pinned bar (#918).
    @State private var showsPinnedReplies = false
    /// The pin whose label is being edited from the bar (#1147).
    @State private var labelingPin: PinnedReply?
    /// Gives up on an overview reveal whose reply the opened chat hasn't
    /// loaded (an older part of it).
    @State private var pinnedRevealFallbackTask: Task<Void, Never>?
    /// The reveal that fallback is for; another reveal replaces it.
    @State private var pinnedRevealFallbackReveal: PinnedReplyReveal?

    private var viewportInputs: ChatScrollRenderInputs { scrollEngine.renderInputs }

    /// The saved copy is on screen: over an empty transcript, or over any
    /// transcript for a chat picked in the saved list.
    private var showsOfflineCopy: Bool {
        appState.showsOfflineChatCopy
    }

    /// A message sent while this live chat was on its way, waiting below
    /// its rows. The saved copy and a New Chat show their own.
    private var livePendingComposerSend: PendingComposerSend? {
        guard !showsOfflineCopy, !appState.showsPendingNewChat else { return nil }
        return appState.pendingComposerSendOnScreen
    }

    private var renderedScrollSessionKey: ChatScrollSessionKey? { viewportInputs.renderedSessionKey }

    private var activeScrollSessionKey: ChatScrollSessionKey? {
        Self.activeScrollSessionKey(in: appState)
    }

    private var activeOrFallbackScrollSessionKey: ChatScrollSessionKey {
        Self.activeOrFallbackScrollSessionKey(in: appState)
    }

    @MainActor
    static func activeScrollSessionKey(in appState: AppState) -> ChatScrollSessionKey? {
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

    @MainActor
    static func activeOrFallbackScrollSessionKey(in appState: AppState) -> ChatScrollSessionKey {
        activeScrollSessionKey(in: appState) ?? ChatScrollSessionKey(
            profile: appState.activeProfile,
            sessionID: "new"
        )
    }

    static func bottomAnchorID(for key: ChatScrollSessionKey) -> String {
        "chat-latest-\(key.profile)-\(key.sessionID)"
    }

    private var topAnchor: String {
        ChatTitleScrollAnchor.id(for: activeOrFallbackScrollSessionKey)
    }

    /// Read from the engine; `viewportInputs.targetsRevision` is the cache's
    /// rendering revision, so any target change re-runs the body (with or
    /// without a rendered session).
    private var chatMessageScrollTargets: [ChatMessageScrollTarget] {
        _ = viewportInputs.targetsRevision
        return scrollEngine.targets
    }

    /// The rows the transcript lays out: a step that draws nothing (hidden,
    /// or inside a collapsed run) is left out, or the stack would space it
    /// like any row (ChatStepPlacement.drawsRow). Its scroll target stays.
    /// Without such a step, the targets themselves, uncopied.
    private var drawnMessageScrollTargets: [ChatMessageScrollTarget] {
        let targets = chatMessageScrollTargets
        _ = stepToggleRevision
        let preferences = appState.displayPreferences
        let isBusy = appState.isBusy
        let draws: (ChatMessageScrollTarget) -> Bool = { target in
            target.drawsRow(preferences: preferences, isBusy: isBusy, disclosure: rowDisclosure)
        }
        guard targets.contains(where: { !draws($0) }) else { return targets }
        return targets.filter(draws)
    }

    private var bottomAnchor: String {
        Self.bottomAnchorID(for: activeOrFallbackScrollSessionKey)
    }

    /// The tool running in this turn, for the working line. Looks back only
    /// to the turn's own rows.
    private var runningToolName: String? {
        guard appState.isBusy else { return nil }
        return Self.runningToolName(in: appState.messages)
    }

    /// Its input, so a Tool Search batch names what it runs.
    private var runningToolInput: String? {
        guard appState.isBusy else { return nil }
        return Self.runningTool(in: appState.messages)?.input
    }

    /// "Messaging Atlas…" while a delivery to a teammate runs, as its step
    /// says; nil for any other tool.
    private var runningToolTitle: String? {
        guard appState.isBusy, let tool = Self.runningTool(in: appState.messages),
              let key = BotTeammateMessages.deliveryTarget(toolName: tool.name, input: tool.input) else { return nil }
        let name = BotTeammateMessages.displayName(for: key, in: appState.botRoster)
        return AppLocalization.string("Messaging \(name)…")
    }

    static func runningToolName(in messages: [ChatMessage]) -> String? {
        runningTool(in: messages)?.name
    }

    static func runningTool(in messages: [ChatMessage]) -> ToolActivity? {
        // Back to the turn's start: a long turn can run many tools. A steer
        // joins the running turn rather than starting one.
        for message in messages.reversed() {
            if message.role == .user && !message.isSteer { return nil }
            if message.role == .tool, let tool = message.tool, tool.status == .running {
                return tool
            }
        }
        return nil
    }

    /// When the running turn began, for the working line's timer.
    private var turnStartedAt: Date? {
        guard appState.isBusy else { return nil }
        return Self.turnStart(in: appState.messages)
    }

    static func turnStart(in messages: [ChatMessage]) -> Date? {
        guard let message = messages.last(where: { $0.role == .user && !$0.isSteer }) else { return nil }
        return MessageTimestampFormatter.date(from: message.timestamp)
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
                        .scaledFont(.footnote.weight(.semibold))
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
                    scrollEngine.olderPageBackfillRequested(sessionKey: armedKey)
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
                            scrollEngine.prependAnchorDischarged(matching: armedKey)
                        }
                    }
                } label: {
                    Label("Load earlier messages", systemImage: "clock.arrow.circlepath")
                        .scaledFont(.footnote.weight(.semibold))
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

    /// The minimised call bar and the composer, below the transcript.
    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            // A live call swiped down keeps running; its bar sits here
            // (in V2, not while someone types in the composer).
            if !composerTyping {
                MinimisedLiveVoiceBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            planDock
            // Predictive guesses (off unless turned on in Settings > Chat).
            PredictiveRow(store: appState.predictive, appState: appState)
            // Composer + control bar. Equatable: it redraws for what it
            // shows, not for every redraw of this view.
            ComposerBar(appState: appState).equatable()
        }
        // The transcript's bottom inset follows this bar; a following chat
        // keeps its end above it when chips or the dock come and go.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
            scrollEngine.bottomBarResized()
        }
    }

    private var renderedScrollScope: ChatRenderedScrollScope? {
        viewportInputs.renderedScrollScope
    }

    /// Test-only seam for the dormancy fixtures (PR #201 review): ChatView
    /// re-writes `\.chatTextSize` at its own root from the shared
    /// @AppStorage preference — an environment write no OUTER harness pin
    /// can dominate (the nearer write wins). When non-nil, that inner write
    /// resolves to this value instead, so shared preference state cannot
    /// leak into (or churn) a measured fixture. Production never sets it
    /// (nil) and the preference decides exactly as before.
    var chatTextSizeOverride: ChatTextSize? = nil

    /// The chat-only text-size preference (issue #85). Local, device-only
    /// @AppStorage like ComposerReturnKey — never synced to Hermes or the
    /// profile. Injected once here so every transcript Markdown path
    /// (settled, streaming, large-document, tables, code) resolves the same
    /// typography, while non-chat subtrees keep the `.default` environment
    /// value and today's appearance.
    @AppStorage(ChatTypography.preferenceKey) private var chatTextSizeRaw = ChatTypography.defaultSize.rawValue
    /// Settings > Chat's Long replies switch, so the scroll engine hears a
    /// change while the chat is open (ChatReplyRoom).
    @AppStorage(ChatReplyStartPreference.key) private var stopsAtReplyStart = ChatReplyStartPreference.defaultOn
    /// The chat text style (typeface), stored and injected beside the size.
    @AppStorage(ChatTypography.fontStylePreferenceKey) private var chatFontStyleRaw = ChatFontStyle.standard.rawValue

    /// A wide window's column steps its text up (`readableChatColumn`).
    @Environment(\.chatWidthTextSteps) private var chatWidthTextSteps
    @Environment(\.columnText) private var columnText

    private var chatTextSize: ChatTextAppearance {
        ChatTextAppearance(
            size: chatTextSizeOverride ?? ChatTypography.resolve(rawValue: chatTextSizeRaw),
            style: chatTextSizeOverride == nil ? ChatTypography.resolveStyle(rawValue: chatFontStyleRaw) : .standard
        )
        .widened(steps: chatWidthTextSteps, in: chatTextSizeOverride == nil ? columnText : nil)
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
            // VoiceOver reads only the saved copy while it is up.
            .accessibilityHidden(showsOfflineCopy || appState.showsPendingNewChat)
            // A chat picked in the saved list covers a transcript still up
            // from before (a profile switch): that one is hidden, not drawn
            // under it. It stays laid out, so its scroll position holds.
            .opacity(showsOfflineCopy || appState.showsPendingNewChat ? 0 : 1)
            // The read-only saved copy (#99) sits OVER the live scroll view
            // instead of feeding it: the live view stays mounted with the
            // same empty transcript a cold launch always had, so its viewport
            // ownership, restoration, and follow logic are untouched. The
            // first real transcript clears the copy in the same update.
            // A New Chat on its way covers both, as the empty chat it will be.
            .overlay {
                if appState.showsPendingNewChat {
                    PendingNewChatView()
                } else if showsOfflineCopy, let offline = appState.offlineChatPresentation {
                    OfflineChatTranscriptView(presentation: offline)
                        // Its own scroll view: the chat's jump can't reach it.
                        .environment(\.quotedReplyJump, nil)
                        // Its pictures page among its own.
                        .environment(\.imageGallery, appState.savedChatImageGallery)
                }
            }

            if !composerFloats {
                bottomBar
            }
        }
        .v2EdgeBar(.bottom) {
            if composerFloats {
                bottomBar
            }
        }
        .onPreferenceChange(V2ComposerTypingKey.self) { typing in
            withAnimation(ConduitMotion.ease(reduceMotion: composerReduceMotion)) {
                composerTyping = typing
            }
        }
        .environment(\.chatTextSize, chatTextSize)
        .environment(\.markdownTablePlainCells, true)
        .environment(\.markdownJoinsProseRuns, true)
        // Text draws until a touch, a selection or assistive technology
        // needs its text view: rows scrolling in mount no UITextViews.
        .environment(\.selectableTextDrawsUntilTouched, true)
        // Gateway videos, audio and documents open from a download (#569).
        .environment(\.gatewayMediaFiles, appState.gatewayMediaResolver)
        // A tapped picture pages through the chat's pictures.
        .environment(\.imageGallery, appState.chatImageGallery)
        // Pictures' sizes from earlier launches, read once off the main
        // thread, so rows above take their final height (#1238).
        .task { await TranscriptPictureMemory.loadKeptSizes() }
        .background(Color.clear)
        // Files dragged onto the chat (Finder on a Mac, Files on an iPad)
        // are staged in the composer for the user to send (#1408).
        .attachmentDropTarget(isEnabled: appState.composerIsEnabled) { providers in
            appState.dropIntoComposer(providers)
        }
        .overlay(alignment: .top) {
            if appState.isOpeningNotificationSession {
                Label("Opening conversation…", systemImage: "arrow.down.message")
                    .scaledFont(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.12))
                    .padding(.top, 12)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: appState.isOpeningNotificationSession)
        .animation(.easeInOut(duration: 0.2), value: appState.minimisedLiveVoice)
        .overlay {
            // Cross-block selection chrome (endpoint handles + copy pill),
            // mounted at screen level so its frame always covers the whole
            // transcript; see MarkdownSelectionHandles.swift.
            MarkdownSelectionChromeRoot()
        }
        // Selected transcript text can be quoted into the composer (#385),
        // from the native selection menu and the cross-block pill alike,
        // while the composer takes input.
        .environment(
            \.chatQuoteAction,
            ChatQuoteAction(
                owner: appState,
                isAvailable: appState.canQuoteIntoComposer,
                handler: appState.quoteIntoComposer
            )
        )
        // A "Replying to" card's tap scrolls to the reply it quoted.
        .environment(
            \.quotedReplyJump,
            QuotedReplyJumpAction(owner: appState) { [weak appState = appState] quote, messageID in
                appState?.showQuotedReply(quote, quotedIn: messageID) ?? false
            }
        )
        // The rows show AppState through this, not by observing it.
        .chatRows()
        .sheet(isPresented: $showsPinnedReplies) {
            PinnedRepliesSheet(fromOpenChat: true)
                .environmentObject(appState)
        }
        .pinnedReplyLabelEditor($labelingPin) { pin, label in
            appState.setPinnedReplyLabel(pin, to: label)
        }
    }

    // MARK: - Scroll construction (layered so the type-checker can cope)

    private func chatScrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: ChatStepStyle.transcriptRowSpacing) {
                Color.clear
                    .frame(height: 1)
                    .id(topAnchor)

                if transcriptBackfillAvailable {
                    transcriptTopBackfillControl
                }

                if appState.messages.isEmpty && appState.offlineChatPresentation == nil
                    && livePendingComposerSend == nil {
                    EmptyChatState().padding(.top, 60)
                }

                // Iterate the targets collection directly: wrapping it in
                // Array(enumerated()) copied the entire transcript into a
                // fresh tuple array on EVERY body evaluation — O(message
                // count) allocation churn at streaming/reasoning cadence in
                // deep sessions. Row identity (target.id) and the transcript
                // order needed by row geometry (target.order, maintained by
                // the scroll-target cache) are unchanged.
                ForEach(drawnMessageScrollTargets) { target in
                    MessageBubble(
                        message: target.message,
                        gatewayResolver: appState.gatewayMediaResolver,
                        step: target.step,
                        stepsAbove: target.stepsAbove,
                        reviewRun: target.reviewRun
                    )
                        .equatable()
                        .id(target.id)
                        .background {
                            // Measured in the stack's own coordinate space,
                            // so the value changes only when layout does,
                            // never on a scroll tick.
                            GeometryReader { geometry in
                                let frame = geometry.frame(
                                    in: CoordinateSpace.named(ChatScrollEngine.coordinateSpaceName)
                                )
                                Color.clear.preference(
                                    key: ChatScrollRowFramesPreferenceKey.self,
                                    value: [
                                        target.id: ChatScrollRowFrame(
                                            minY: frame.minY,
                                            maxY: frame.maxY,
                                            order: target.order
                                        ),
                                    ]
                                )
                            }
                        }
                }

                // The running turn's live tail observes only the live
                // projection, so a streaming tick re-renders these rows and
                // never this body, the composer, or an open sheet.
                ChatLiveTurnRows(
                    projection: appState.liveTurn,
                    isBusy: appState.isBusy,
                    author: appState.activeProfile,
                    currentToolName: runningToolName,
                    currentToolInput: runningToolInput,
                    currentToolTitle: runningToolTitle,
                    turnStartedAt: turnStartedAt,
                    repliesElsewhere: appState.activeChatRepliesElsewhere
                )

                if let pending = livePendingComposerSend {
                    PendingComposerSendBubble(pending: pending)
                        .reportsLiveRowFrame(id: "pending-send")
                }

                // Fallback target for ScrollViewProxy before the engine has
                // found the scroll view. The composer is a bar the scroll
                // view already insets for (V2's safe-area bar, or the
                // stack below it), so the latest row ends one row spacing
                // (plus this row's 1 pt) above it; extra padding here was
                // empty space over the composer. OfflineChatTranscriptView
                // ends with the same row.
                Color.clear
                    .frame(height: 1)
                    .id(bottomAnchor)
            }
            .coordinateSpace(.named(ChatScrollEngine.coordinateSpaceName))
            .environment(\.chatRowDisclosure, rowDisclosure)
            .onReceive(rowDisclosure.groupToggles.$revision) { stepToggleRevision = $0 }
            .background {
                ChatScrollSurfaceLocator(engine: scrollEngine)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            // Room under a sent message for its reply to stream into (#1436).
            .modifier(ChatReplyRoomFrame(room: scrollEngine.replyRoom))
            .background {
                GeometryReader { _ in
                    Color.clear.preference(
                        key: ChatRenderedScrollContentPreferenceKey.self,
                        value: renderedScrollScope.map(ChatRenderedScrollContent.init(scope:))
                    )
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .id(transcriptScrollID)
        // Inside the pinned replies' inset: before iOS 26 the transcript's
        // fade is a mask, which would fade their card too.
        .modifier(V2SoftTopScrollEdge(isOn: composerFloats, underChatHeader: true))
        // The open chat's pinned replies (#918), over the transcript's top.
        .safeAreaInset(edge: .top, spacing: 0) { pinnedReplyBar }
        .onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
        .overlay(alignment: .bottomTrailing) {
            ChatJumpControls(
                chrome: scrollEngine.chrome,
                pendingClarifyMessageID: appState.pendingClarifyMessageID,
                pendingKind: appState.pendingDecisionKind,
                jumpToQuestion: { id in scrollEngine.explicitMessageRequested(id: id) },
                jumpToLatest: { requestLatest(animated: true) },
                followingChanged: {
                    scrollEventRouter.saveChatScrollPosition(for: renderedScrollSessionKey)
                }
            )
        }
    }

    /// The open chat's plan, docked above the composer (ChatCards.swift).
    /// It is in the composer's stack, so the transcript's bottom inset
    /// grows by its height rather than the plan covering messages.
    @ViewBuilder
    private var planDock: some View {
        if appState.showsChatCards {
            // composerTyping is V2's focused-composer flag; the classic
            // shell never sets it, so there the plan never keeps to its line.
            ChatPlanDock(
                cards: appState.chatCards,
                isCompact: ChatPlanDock.keepsToLine(composerFocused: composerTyping)
            )
        }
    }

    private func lifecycleObservers(proxy: ScrollViewProxy, content: some View) -> some View {
        content
            .onChange(of: appState.chatTranscriptRevision) { appState.refreshChatCards() }
            .onChange(of: appState.activeSessionId) { appState.refreshChatCards() }
            .onAppear {
                appState.refreshChatCards()
                installScrollEngineCallbacks(proxy: proxy)
                scrollEngine.setPaused(scenePhase == .background)
                scrollEngine.renderedSessionChanged(
                    to: activeScrollSessionKey,
                    identity: appState.activeChatScrollSessionIdentity,
                    viaNotification: false,
                    viewportTransitionGeneration: appState.chatViewportTransitionGeneration
                )
                scrollEngine.transcriptChanged(
                    messages: appState.messages,
                    transcriptRevision: appState.chatTranscriptRevision,
                    viewportTransitionGeneration: appState.chatViewportTransitionGeneration,
                    isInitialSync: true
                )
                scrollEngine.trackMessageVisibility(of: appState.pendingClarifyMessageID)
                // An unread open that finished before this view was up.
                takeReplyStartLanding()
                appState.installChatViewportSnapshotProvider(
                    id: viewportSnapshotProviderID,
                    capture: { [weak engine = scrollEngine] in
                        engine?.renderedViewportSnapshot()
                    }
                )
            }
            .onDisappear {
                scrollEngine.viewDisappeared()
                // Reinstalled on appear; late events go nowhere meanwhile.
                scrollEngine.onEvent = nil
                scrollEventRouter.proxy = nil
                scrollEventRouter.rebuildTranscript = nil
                backfillViewportTask?.cancel()
                latestAnimationTask?.cancel()
                pinnedRevealFallbackTask?.cancel()
                pinnedRevealFallbackTask = nil
                pinnedRevealFallbackReveal = nil
                appState.removeChatViewportSnapshotProvider(id: viewportSnapshotProviderID)
            }
            // Names for the steps Conduit has no words of its own for.
            .task(id: "\(appState.activeDashboardID?.uuidString ?? "")|\(appState.activeProfile)|\(appState.dashboardTicketBridge != nil)") {
                await appState.loadToolCatalogIfNeeded()
            }
            .task(id: appState.chatResumeRestorationRequest?.generation) {
                guard let request = appState.chatResumeRestorationRequest else { return }
                await runViewportRestoration(request)
            }
            // The same chat open on another device: a turn that went quiet
            // here, or one the other device ran, is checked against the
            // live registry while this chat shows. Each turn edge checks at
            // once.
            .task(id: "\(appState.activeSessionId ?? "")|\(appState.isBusy)|\(scenePhase == .active)|\(appState.showSidebar)") {
                guard scenePhase == .active, !appState.showSidebar else { return }
                appState.openChatSyncBecameVisible()
                while !Task.isCancelled {
                    await appState.openChatSyncTick()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .onPreferenceChange(ChatRenderedScrollContentPreferenceKey.self) { value in
                guard let value else { return }
                appState.chatViewportLayoutDidSettle(
                    sessionKey: value.scope.sessionKey,
                    transitionGeneration: value.scope.viewportTransitionGeneration,
                    transcriptRevision: value.scope.transcriptRevision,
                    renderRevision: value.scope.cacheRevision,
                    receivedScopedPreference: true
                )
            }
            .onPreferenceChange(ChatScrollRowFramesPreferenceKey.self) { frames in
                scrollEngine.rowFramesChanged(frames)
            }
            .onChange(of: stopsAtReplyStart) { _, _ in
                scrollEngine.replyStartPreferenceChanged()
            }
            .onPreferenceChange(ChatScrollLiveRowFramesPreferenceKey.self) { frames in
                scrollEngine.liveRowFramesChanged(frames)
            }
            .onChange(of: scenePhase) { _, phase in
                // In the background iOS still lays this view out for
                // app-switcher snapshots, and a backgrounded app gets little
                // CPU; the engine leaves the offset alone until it is back.
                scrollEngine.setPaused(phase == .background)
            }
    }

    private func transcriptObservers(proxy: ScrollViewProxy, content: some View) -> some View {
        content
            .onChange(of: appState.messages) { _, _ in
                scrollEngine.transcriptChanged(
                    messages: appState.messages,
                    transcriptRevision: appState.chatTranscriptRevision,
                    viewportTransitionGeneration: appState.chatViewportTransitionGeneration,
                    activeSessionKey: activeScrollSessionKey
                )
            }
            .onChange(of: appState.pendingClarifyMessageID) { _, id in
                scrollEngine.trackMessageVisibility(of: id)
            }
            // An Artifacts screen's "Show in chat": once the row is in and
            // any restore is done.
            .onChange(of: appState.chatTranscriptRevision) { _, _ in
                revealPendingArtifact()
                revealPendingPinnedReply()
                appState.refreshOpenChatPinnedReplies()
            }
            .onChange(of: appState.pendingArtifactReveal) { _, _ in revealPendingArtifact() }
            .onChange(of: appState.pendingPinnedReplyReveal) { _, _ in revealPendingPinnedReply() }
            // A "Replying to" card's tap (issue 1420): the reply it quoted.
            .onChange(of: appState.pendingQuotedReplyJump) { _, jump in
                guard let jump else { return }
                appState.pendingQuotedReplyJump = nil
                scrollEngine.explicitMessageRequested(id: jump.messageID)
            }
            .onAppear {
                revealPendingArtifact()
                revealPendingPinnedReply()
            }
            .onChange(of: appState.chatResumeRestorationRequest) { oldRequest, newRequest in
                guard oldRequest != nil, newRequest == nil else { return }
                // The published request disappeared on the AppState side
                // (completed/abandoned/cancelled elsewhere).
                scrollEngine.restorationSystemCancelled()
                // A pinned reply waiting on the restore goes now.
                revealPendingPinnedReply()
            }
    }

    private func revealPendingArtifact() {
        guard let reveal = appState.pendingArtifactReveal else { return }
        guard reveal.expires > Date() else {
            appState.pendingArtifactReveal = nil
            return
        }
        guard appState.chatResumeRestorationRequest == nil, appState.isShowingChat(for: reveal),
              let id = ArtifactReveal.rowID(for: reveal.messageID, in: appState.messages) else { return }
        appState.pendingArtifactReveal = nil
        // After this update's layout, so the engine knows the row.
        DispatchQueue.main.async { scrollEngine.explicitMessageRequested(id: id) }
    }

    /// The overview's pinned reply (#918), once its chat shows and has the
    /// row.
    private func revealPendingPinnedReply() {
        guard let reveal = appState.pendingPinnedReplyReveal else { return }
        guard reveal.expires > Date() else {
            appState.pendingPinnedReplyReveal = nil
            return
        }
        guard appState.chatResumeRestorationRequest == nil, appState.isShowingChat(for: reveal),
              !appState.messages.isEmpty else { return }
        guard let id = PinnedReplies.messageID(
            for: reveal.pin, in: appState.messages, among: appState.openChatPinnedReplies
        ) else {
            // The chat shows but not the reply: give its transcript a moment
            // to finish loading, then go as close as the bar goes.
            if pinnedRevealFallbackTask != nil {
                guard pinnedRevealFallbackReveal != reveal else { return }
                pinnedRevealFallbackTask?.cancel()
            }
            pinnedRevealFallbackReveal = reveal
            pinnedRevealFallbackTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                // A cancelled task leaves the slot alone: whoever cancelled
                // it cleared it, and a newer task may hold it now.
                guard !Task.isCancelled else { return }
                pinnedRevealFallbackTask = nil
                pinnedRevealFallbackReveal = nil
                guard appState.pendingPinnedReplyReveal == reveal,
                      appState.isShowingChat(for: reveal) else { return }
                appState.pendingPinnedReplyReveal = nil
                jumpToPinnedReply(reveal.pin)
            }
            return
        }
        pinnedRevealFallbackTask?.cancel()
        pinnedRevealFallbackTask = nil
        pinnedRevealFallbackReveal = nil
        appState.pendingPinnedReplyReveal = nil
        let passage = reveal.pin.passage
        DispatchQueue.main.async {
            scrollEngine.explicitMessageRequested(id: id)
            if let passage { PinnedPassageFlasher.flash(passage, inMessage: id) }
        }
    }

    /// The bar over the transcript while the open chat has pinned replies.
    @ViewBuilder
    private var pinnedReplyBar: some View {
        let pins = appState.openChatPinnedReplies
        if !pins.isEmpty, !showsOfflineCopy, !appState.showsPendingNewChat {
            PinnedReplyBar(
                pins: pins,
                jump: { pin in jumpToPinnedReply(pin) },
                unpin: { pin in appState.unpinReply(pin) },
                label: { pin in labelingPin = pin },
                showAll: { showsPinnedReplies = true }
            )
            .id(appState.activeSessionId)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// A pinned reply not loaded yet sits in an older part of the chat: the
    /// top of the transcript, where Load earlier messages is, is as close
    /// as the chat can go.
    private func jumpToPinnedReply(_ pin: PinnedReply) {
        if let id = PinnedReplies.messageID(for: pin, in: appState.messages, among: appState.openChatPinnedReplies) {
            ChatViewportTrace.shared.log("event explicitPinnedReply (bar)")
            scrollEngine.explicitMessageRequested(id: id)
            if let passage = pin.passage { PinnedPassageFlasher.flash(passage, inMessage: id) }
        } else {
            ChatViewportTrace.shared.log("event explicitTop (pinned reply not loaded)")
            scrollEngine.explicitTopRequested()
            UIAccessibility.post(
                notification: .announcement,
                argument: AppLocalization.string("This reply is earlier in the chat. Load earlier messages to reach it.")
            )
        }
    }

    private func sessionObservers(proxy: ScrollViewProxy, content: some View) -> some View {
        content
            .onChange(of: appState.chatScrollRequest) { _, _ in
                ChatViewportTrace.shared.log("event explicitLatest (send pulse)")
                requestLatest(animated: false, armsReplyHold: true)
            }
            .onChange(of: appState.chatReplyStartLandingRequest) { _, _ in
                takeReplyStartLanding()
            }
            .onChange(of: appState.chatScrollToTopRequest) { _, request in
                ChatViewportTrace.shared.log("event explicitTop request=\(request)")
                scrollEngine.explicitTopRequested()
            }
            .onChange(of: appState.activeSessionId) { _, _ in
                ChatViewportTrace.shared.log(
                    "event sessionChanged viaNotification=\(appState.isOpeningNotificationSession)"
                )
                scrollEngine.renderedSessionChanged(
                    to: activeScrollSessionKey,
                    identity: appState.activeChatScrollSessionIdentity,
                    viaNotification: appState.isOpeningNotificationSession,
                    viewportTransitionGeneration: appState.chatViewportTransitionGeneration
                )
            }
            .onChange(of: appState.activeProfile) { _, _ in
                ChatViewportTrace.shared.log(
                    "event profileChanged viaNotification=\(appState.isOpeningNotificationSession)"
                )
                scrollEngine.transcriptChanged(
                    messages: appState.messages,
                    transcriptRevision: appState.chatTranscriptRevision,
                    viewportTransitionGeneration: appState.chatViewportTransitionGeneration,
                    isInitialSync: true,
                    activeSessionKey: activeScrollSessionKey
                )
                scrollEngine.renderedSessionChanged(
                    to: activeScrollSessionKey,
                    identity: appState.activeChatScrollSessionIdentity,
                    viaNotification: appState.isOpeningNotificationSession,
                    viewportTransitionGeneration: appState.chatViewportTransitionGeneration
                )
            }
            .onChange(of: appState.activeChatScrollSessionIdentity) { _, _ in
                scrollEngine.activeIdentityRefreshed(
                    identity: appState.activeChatScrollSessionIdentity,
                    key: activeScrollSessionKey
                )
            }
            .onChange(of: appState.isOpeningNotificationSession) { _, isOpening in
                if isOpening {
                    ChatViewportTrace.shared.log("event notificationHandoffBegan")
                    scrollEngine.notificationHandoffBegan()
                } else {
                    scrollEngine.notificationHandoffFinished()
                }
            }
    }

    private func takeReplyStartLanding() {
        guard appState.takeChatReplyStartLanding() else { return }
        ChatViewportTrace.shared.log("event replyStartLanding (unread chat opened)")
        scrollEngine.replyStartLandingRequested()
    }

    /// Send and the jump-to-latest button. An animated jump gets one final
    /// pin once the animation has had time to land.
    private func requestLatest(animated: Bool, armsReplyHold: Bool = false) {
        scrollEngine.explicitLatestRequested(animated: animated, armsReplyHold: armsReplyHold)
        latestAnimationTask?.cancel()
        guard animated else { return }
        latestAnimationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(ChatScrollEngine.latestAnimationDuration))
            guard !Task.isCancelled else { return }
            scrollEngine.latestAnimationFinished()
        }
    }

    /// Engine-driven restoration: the .task restarts whenever the published
    /// request generation changes and ticks every 25 ms until the engine has
    /// placed the saved row, given up, or been cancelled (a drag, a session
    /// switch, or the request going away). All retries are bounded inside
    /// the engine.
    @MainActor
    private func runViewportRestoration(_ request: ChatResumeRestorationRequest) async {
        scrollEngine.restorationRequested(request)
        while !Task.isCancelled,
              scrollEngine.restorationTick(transcriptRevision: appState.chatTranscriptRevision) {
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
        }
    }

    // MARK: - Scroll engine wiring

    private func installScrollEngineCallbacks(proxy: ScrollViewProxy) {
        let router = scrollEventRouter
        router.appState = appState
        router.engine = scrollEngine
        rowDisclosure.engine = scrollEngine
        rowDisclosure.currentConversation = { [weak appState = appState] in
            appState?.activeChatScrollSessionIdentity ?? .none
        }
        router.proxy = proxy
        router.rebuildTranscript = { transcriptScrollID &+= 1 }
        scrollEngine.holdsRepliesAtStart = { ChatReplyStartPreference.isOn }
        scrollEngine.liveTailShowing = { [weak appState = appState] in
            guard let appState else { return false }
            let live = appState.liveTurn
            return appState.isBusy || appState.activeChatRepliesElsewhere
                || !live.streamingText.isEmpty || live.reasoningSegment != nil
                || (appState.pendingComposerSendOnScreen != nil
                    && !appState.showsOfflineChatCopy && !appState.showsPendingNewChat)
        }
        scrollEngine.onEvent = { [weak engine = scrollEngine, weak router] event in
            // Requests made while handling a UIKit callback can land in the
            // middle of a SwiftUI update; they run on the next turn.
            if engine?.isHandlingSurfaceCallback == true {
                DispatchQueue.main.async { router?.handle(event) }
            } else {
                router?.handle(event)
            }
        }
    }
}

/// Carries ChatScrollEngine's requests to AppState (persistence,
/// restoration outcomes) and to ScrollViewProxy (reveals before the engine
/// has a scroll view). Everything is held weakly, so the engine's callback
/// cannot keep the chat view or AppState alive.
@MainActor
private final class ChatScrollEventRouter {
    weak var appState: AppState?
    weak var engine: ChatScrollEngine?
    var proxy: ScrollViewProxy?
    /// Builds the transcript's scroll view again (`transcriptScrollID`).
    var rebuildTranscript: (@MainActor () -> Void)?

    func handle(_ event: ChatScrollEngineEvent) {
        guard let appState else { return }
        switch event {
        case .persistSnapshot(let key):
            saveChatScrollPosition(for: key)
        case .flushPersistence:
            appState.flushChatResumeViewport()
        case .cancelAutomaticRestoration:
            appState.cancelChatResumeRestoration()
        case .completeRestoration(let generation):
            appState.completeChatResumeRestoration(generation: generation)
        case .abandonRestoration(let generation):
            appState.abandonChatResumeRestoration(generation: generation)
        case .revealRow(let id):
            scrollWithoutAnimation { $0.scrollTo(id, anchor: .top) }
        case .revealLatest:
            let anchor = ChatView.bottomAnchorID(
                for: ChatView.activeOrFallbackScrollSessionKey(in: appState)
            )
            scrollWithoutAnimation { $0.scrollTo(anchor, anchor: .bottom) }
        case .revealTop:
            let anchor = ChatTitleScrollAnchor.id(
                for: ChatView.activeOrFallbackScrollSessionKey(in: appState)
            )
            scrollWithoutAnimation { $0.scrollTo(anchor, anchor: .top) }
        case .rebuildTranscript:
            rebuildTranscript?()
        }
    }

    func saveChatScrollPosition(for preferredKey: ChatScrollSessionKey? = nil) {
        guard let appState, let engine else { return }
        let currentKey = preferredKey
            ?? engine.renderedSessionKey
            ?? ChatView.activeScrollSessionKey(in: appState)
        guard let sessionKey = ChatViewportPersistenceSupport.persistenceSessionKey(
            currentKey: currentKey,
            identity: appState.activeChatScrollSessionIdentity
        ) else { return }
        guard let snapshot = engine.renderedViewportSnapshot()?.snapshot else { return }
        // Saved once the reader stops scrolling (recordViewport).
        appState.recordChatViewport(snapshot, for: sessionKey) { [weak engine] in
            engine?.isUserScrolling ?? false
        }
    }

    private func scrollWithoutAnimation(_ body: (ScrollViewProxy) -> Void) {
        guard let proxy else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { body(proxy) }
    }
}

/// The jump-to-latest and go-to-what-Hermes-waits-on button. It observes the
/// engine's chrome on its own, so leaving the latest message, or the button
/// appearing and going, re-renders this button and not the transcript.
private struct ChatJumpControls: View {
    @ObservedObject var chrome: ChatScrollChrome
    let pendingClarifyMessageID: String?
    /// What the waiting card is: the button says so.
    let pendingKind: PendingDecisionKind
    let jumpToQuestion: @MainActor (String) -> Void
    let jumpToLatest: @MainActor () -> Void
    let followingChanged: @MainActor () -> Void

    private var jumpIcon: String {
        switch pendingKind {
        case .question: return "questionmark.bubble"
        case .approval: return "checkmark.shield"
        case .input: return "key"
        }
    }

    private var jumpTitle: String {
        switch pendingKind {
        case .question: return AppLocalization.string("Go to your question")
        case .approval: return AppLocalization.string("Go to the approval")
        case .input: return AppLocalization.string("Go to the request")
        }
    }

    private var jumpAccessibilityLabel: String {
        switch pendingKind {
        case .question: return AppLocalization.string("Go to the question that needs your answer")
        case .approval: return AppLocalization.string("Go to the approval")
        case .input: return AppLocalization.string("Go to the request that needs your input")
        }
    }

    var body: some View {
        let inputs = chrome.inputs
        let hasPendingClarify = pendingClarifyMessageID != nil
            && inputs.visibilityTrackedMessageID == pendingClarifyMessageID
            && inputs.isVisibilityTrackedMessageOffscreen
        ZStack(alignment: .bottomTrailing) {
            // Keeps the onChange below in place while no button shows.
            Color.clear.frame(width: 0, height: 0)
            // Both actions share this overlay slot; the offscreen pending
            // question takes priority, and latest reappears when it is visible.
            if inputs.showsJumpToLatest || hasPendingClarify {
                Button {
                    ChatViewportTrace.shared.log(
                        hasPendingClarify
                            ? "event explicitPendingClarify (button)"
                            : "event explicitLatest (button)"
                    )
                    if hasPendingClarify, let pendingClarifyMessageID {
                        jumpToQuestion(pendingClarifyMessageID)
                    } else {
                        jumpToLatest()
                    }
                } label: {
                    if hasPendingClarify {
                        HStack(spacing: 7) {
                            Image(systemName: jumpIcon)
                            Text(jumpTitle)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .scaledFont(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 44, height: 44)
                    }
                }
                .conduitGlassControl(
                    cornerRadius: 22,
                    tint: (hasPendingClarify ? Color.orange : Color.conduitAccent).opacity(0.14)
                )
                .accessibilityLabel(
                    hasPendingClarify
                        ? jumpAccessibilityLabel
                        : AppLocalization.string("Scroll to latest message")
                )
                .modifier(OptionalAccessibilityHint(
                    hint: hasPendingClarify && pendingKind == .question
                        ? AppLocalization.string("Scrolls to the pending question in the conversation")
                        : nil
                ))
                .padding(.trailing, 18)
                .padding(.bottom, 14)
            }
        }
        .onChange(of: inputs.isFollowingLatest) { _, _ in followingChanged() }
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

private struct ChatRenderedScrollContentPreferenceKey: PreferenceKey {
    static var defaultValue: ChatRenderedScrollContent? = nil
    static func reduce(
        value: inout ChatRenderedScrollContent?,
        nextValue: () -> ChatRenderedScrollContent?
    ) {
        value = nextValue() ?? value
    }
}

/// The transcript's content takes at least the height the scroll engine
/// asks for while a sent message's reply is on its way, so the message can
/// sit at the top with the reply streaming in under it (ChatReplyRoom).
/// Observed here alone, so a change re-runs only this frame.
private struct ChatReplyRoomFrame: ViewModifier {
    @ObservedObject var room: ChatReplyRoom

    func body(content: Content) -> some View {
        content.frame(minHeight: room.minContentHeight, alignment: .top)
    }
}

/// Frames of the message rows SwiftUI has laid out, keyed by message id.
private struct ChatScrollRowFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [String: ChatScrollRowFrame] = [:]

    static func reduce(
        value: inout [String: ChatScrollRowFrame],
        nextValue: () -> [String: ChatScrollRowFrame]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Frames of the rows below the messages (the running turn's live rows, a
/// send waiting on screen) SwiftUI has laid out, keyed by row id. The scroll
/// engine reads them only to tell a blank viewport from one showing them.
private struct ChatScrollLiveRowFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [String: ChatScrollRowFrame] = [:]

    static func reduce(
        value: inout [String: ChatScrollRowFrame],
        nextValue: () -> [String: ChatScrollRowFrame]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    /// Reports this live row's frame in the transcript stack
    /// (ChatScrollLiveRowFramesPreferenceKey).
    func reportsLiveRowFrame(id: String) -> some View {
        background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: CoordinateSpace.named(ChatScrollEngine.coordinateSpaceName))
                Color.clear.preference(
                    key: ChatScrollLiveRowFramesPreferenceKey.self,
                    value: [id: ChatScrollRowFrame(minY: frame.minY, maxY: frame.maxY, order: Int.max)]
                )
            }
        }
    }
}
// MARK: - Message Bubble

/// Routes a transcript row to its presentation. The expensive settled
/// content of each row type lives behind an Equatable gate (see
/// SettledAssistantMessageContent and friends) so a streaming publish —
/// which re-creates every mounted row through this switch — cannot force
/// settled Markdown presentation to re-evaluate.
///
/// Equatable on what it is handed, and mounted with `.equatable()`: the
/// transcript redraws on every publish and would otherwise rebuild each
/// row. What a row shows from AppState comes through `rowState`, which
/// redraws it on its own.
struct MessageBubble: View, Equatable {
    let message: ChatMessage
    let gatewayResolver: GatewayMediaDataURLResolver?
    /// A thinking or tool row's place in its turn's run of steps, which
    /// draws as one card. Nil outside the chat transcript.
    var step: ChatStepPlacement? = nil
    /// On a reply, the run of steps above it when it has thinking (the
    /// reply's Show thinking). Nil outside the chat transcript.
    var stepsAbove: ChatStepGroup? = nil
    /// A review's place in its run of reviews, which folds into one line.
    /// Nil outside the chat transcript.
    var reviewRun: ChatReviewPlacement? = nil

    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message && lhs.gatewayResolver === rhs.gatewayResolver && lhs.step == rhs.step
            && lhs.stepsAbove == rhs.stepsAbove && lhs.reviewRun == rhs.reviewRun
    }
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed: what a row shows comes from `rowState`.
    private var appState: AppState { rowActions.required }
    @Environment(\.openURL) private var openURL
    @Environment(\.chatRowDisclosure) private var rowDisclosure

    var body: some View {
        let _ = TranscriptPerf.note(.settledBubbleBody)
        switch message.role {
        case .user:
            if message.isSteer {
                SteerBubble(message: message)
            } else if let inbound = BotTeammateMessages.inbound(message.content) {
                // A teammate bot's delivery is an event in the chat, not
                // something the user said (Desktop's agent message note).
                VStack(spacing: 4) {
                    TeammateMessageNote(
                        inbound: inbound,
                        roster: appState.botRoster,
                        appState: appState,
                        disclosureID: message.id
                    )
                    // The agent can react to it like any user turn.
                    if !message.reactions.isEmpty {
                        MessageReactionChips(
                            reactions: message.reactions,
                            agentName: rowState.agentIdentity.name
                        )
                    }
                }
            } else {
                UserBubble(
                    message: message,
                    gatewayResolver: gatewayResolver,
                    agentName: message.reactions.isEmpty ? "" : rowState.agentIdentity.name
                )
            }
        case .assistant:
            if let note = VoiceJobLinkNote(text: message.content) {
                // A saved call's job or chat line: a card that opens it. Not a
                // reply, so it has no read-aloud or reaction controls.
                VoiceJobLinkCard(note: note, timestamp: message.timestamp) {
                    openURL(note.link.url)
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let sender = rowState.teammateReplies[message.id] {
                // The bot answering a teammate, not the user: folded, as on
                // Desktop ("Replied to Atlas", the reply a tap away).
                TeammateReplyNote(
                    name: BotTeammateMessages.displayName(for: sender, in: appState.botRoster),
                    disclosureID: message.id
                ) {
                    AssistantBubble(
                        message: message,
                        readAloudController: appState.messageReadAloudController,
                        gatewayResolver: gatewayResolver
                    )
                }
            } else if let why = rowState.followUpReasons[message.id] {
                // A reply Hermes wrote on its own (Predictive follow-ups).
                VStack(alignment: .leading, spacing: 4) {
                    PredictiveFollowUpTag(why: why)
                    AssistantBubble(
                        message: message,
                        readAloudController: appState.messageReadAloudController,
                        gatewayResolver: gatewayResolver,
                        stepsAbove: stepsAbove
                    )
                }
            } else {
                AssistantBubble(
                    message: message,
                    readAloudController: appState.messageReadAloudController,
                    gatewayResolver: gatewayResolver,
                    stepsAbove: stepsAbove
                )
            }
        case .reasoning:
            if let step {
                ChatStepRow(message: message, placement: step)
            } else {
                ThinkingCard(message: message)
            }
        case .tool:
            // A finished clarify from history reads as its answered card,
            // not the raw tool call (#394). Like the live card it shows
            // whatever the tool-progress setting: it is part of the
            // conversation, not tool progress.
            if let tool = message.tool,
               let clarify = ClarifyActivity.historyRecord(for: tool, rowID: message.id) {
                ClarifyCard(message: message.presenting(clarify))
            } else if let tool = message.tool, case let cards = RichCard.cards(for: tool), !cards.isEmpty {
                // Maps and places Hermes showed (conduit_show): drawn from
                // the call's saved answer, so they come back with the chat,
                // whatever the tool-progress setting. A live card shows
                // only where it was last brought up to date.
                let current = RichCard.current(cards, row: message.id, latestLiveRows: rowState.latestLiveRows)
                Group {
                    if current.isEmpty {
                        RichLiveUpdatedLine(title: cards.first?.title)
                    } else {
                        RichCardsView(cards: current)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let step {
                ChatStepRow(message: message, placement: step)
            } else {
                ToolCard(message: message)
            }
        case .clarify:
            ClarifyCard(message: message)
        case .approval:
            ApprovalCard(message: message)
        case .inputPrompt:
            InputPromptCard(message: message)
        case .system:
            // A call card finds its call through AppState: this redraws it
            // when the links change.
            let _ = rowState.voiceCallLinksRevision
            if message.displayKind == VoiceCallChatLink.displayKind, let link = appState.voiceCallLink(markerID: message.id) {
                VoiceCallMarkerCard(link: link, origin: false) {
                    appState.openVoiceCallTranscript(markerID: link.markerID)
                }
            } else if message.displayKind == VoiceCallChatLink.originDisplayKind, let link = appState.voiceCallLink(markerID: message.id) {
                VoiceCallMarkerCard(link: link, origin: true) {
                    appState.openVoiceCallChat(markerID: link.originMarkerID)
                }
            } else if let review = message.review ?? MessageNormalizer.reviewActivity(fromText: message.content) {
                if let reviewRun, reviewRun.run.count >= 2, reviewRun.index == 0, let disclosure = rowDisclosure {
                    ReviewRunCard(run: reviewRun.run, disclosure: disclosure, toggles: disclosure.groupToggles) {
                        ReviewSummaryCard(activity: review, timestamp: message.timestamp)
                    }
                } else {
                    ReviewSummaryCard(activity: review, timestamp: message.timestamp)
                }
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
    /// Names the agent for the reaction chips' VoiceOver labels. Passed in
    /// so the bubble doesn't observe AppState.
    var agentName = ""
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

                // The agent can react to the user's messages.
                if !message.reactions.isEmpty {
                    MessageReactionChips(
                        reactions: message.reactions,
                        agentName: agentName
                    )
                }

                HStack(spacing: 2) {
                    Spacer(minLength: 0)
                    MessageTimestampLabel(timestamp: message.timestamp)
                    UserMessageCopyButton(message: message)
                    UserMessageMoreMenu(message: message)
                }
            }
        }
    }
}

/// "Message from Atlas" with Atlas's face: a teammate bot's delivery,
/// centered and quiet, with what it said one tap away.
struct TeammateMessageNote: View {
    let inbound: BotTeammateMessages.Inbound
    /// Resolved from the roster, and again when it changes: the row's
    /// equality leaves the roster out, so a roster that lands after the row
    /// would otherwise leave the signed name.
    @State private var bot: BotProfile?
    @State private var name: String
    /// Loads the face; held, not observed, like the rows' AppState.
    let appState: AppState
    /// The row's key in `disclosure`, so a rebuilt row stays open.
    let disclosureID: String
    @Environment(\.chatRowDisclosure) private var disclosure
    /// Nil until tapped here: a rebuilt row takes what the reader chose
    /// from `disclosure`.
    @State private var tapped: Bool?
    @State private var image: UIImage?
    @ScaledMetric(relativeTo: .footnote) private var faceSize: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(inbound: BotTeammateMessages.Inbound, roster: [BotProfile], appState: AppState, disclosureID: String) {
        self.inbound = inbound
        self.disclosureID = disclosureID
        let bot = Self.resolve(inbound, in: roster)
        _bot = State(initialValue: bot)
        _name = State(initialValue: bot?.displayLabel ?? inbound.sender)
        self.appState = appState
        _image = State(initialValue: bot.flatMap { appState.botAvatarImage(for: $0) })
    }

    private var expanded: Bool {
        tapped ?? disclosure?.isExpanded(disclosureID, default: false) ?? false
    }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                Haptics.selection()
                let opens = !expanded
                // Tells the scroll engine first, as every row that opens
                // does: following the running turn would pin the growing
                // row's bottom instead of keeping it where it was tapped.
                disclosure?.willToggle(disclosureID, to: opens)
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { tapped = opens }
            } label: {
                HStack(spacing: 6) {
                    BotAvatarView(
                        name: bot?.name ?? inbound.handle,
                        label: name,
                        colorString: bot?.appearanceColor,
                        image: image,
                        size: faceSize
                    )
                    Text(AppLocalization.string("Message from \(name)"))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !inbound.body.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .scaledFont(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(inbound.body.isEmpty)
            .accessibilityHint(Text(
                inbound.body.isEmpty ? ""
                    : expanded
                    ? AppLocalization.string("Hides what the bot said.")
                    : AppLocalization.string("Shows what the bot said.")
            ))
            .accessibilityValue(Text(
                inbound.body.isEmpty ? ""
                    : expanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed")
            ))

            if expanded {
                // Bots write Markdown; it reads as a reply does.
                MarkdownText(source: inbound.body)
                    .scaledFont(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .frame(maxWidth: 520)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .onReceive(appState.$botRoster) { roster in
            let resolved = Self.resolve(inbound, in: roster)
            guard resolved != bot else { return }
            bot = resolved
            name = resolved?.displayLabel ?? inbound.sender
            image = resolved.flatMap { appState.botAvatarImage(for: $0) }
        }
        .task(id: bot.map { "\($0.name)|\($0.hasAvatar)" }) {
            guard let bot, bot.hasAvatar, image == nil else { return }
            await appState.loadBotAvatarRetrying(bot)
            // The roster may have named another bot meanwhile.
            guard !Task.isCancelled, self.bot?.name == bot.name else { return }
            image = appState.botAvatarImage(for: bot)
        }
    }

    private static func resolve(_ inbound: BotTeammateMessages.Inbound, in roster: [BotProfile]) -> BotProfile? {
        BotTeammateMessages.bot(named: inbound.handle, in: roster)
            ?? BotTeammateMessages.bot(named: inbound.sender, in: roster)
    }
}

/// A bot's reply to a teammate's delivery, folded to "Replied to Atlas"
/// (Desktop's inter-agent reply notice). Tap shows the reply as usual.
struct TeammateReplyNote<Reply: View>: View {
    let name: String
    /// The row's key in `disclosure`, so a rebuilt row stays open.
    let disclosureID: String
    @ViewBuilder let reply: () -> Reply
    @Environment(\.chatRowDisclosure) private var disclosure
    /// Nil until tapped here (see TeammateMessageNote).
    @State private var tapped: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool {
        tapped ?? disclosure?.isExpanded(disclosureID, default: false) ?? false
    }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                Haptics.selection()
                let opens = !expanded
                disclosure?.willToggle(disclosureID, to: opens)
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { tapped = opens }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.right")
                        .scaledFont(.caption2)
                        .accessibilityHidden(true)
                    Text(AppLocalization.string("Replied to \(name)"))
                        .scaledFont(.footnote)
                        .multilineTextAlignment(.center)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityHint(Text(
                expanded
                    ? AppLocalization.string("Hides the reply.")
                    : AppLocalization.string("Shows the reply.")
            ))
            .accessibilityValue(Text(
                expanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed")
            ))

            if expanded {
                reply()
                    .transition(.opacity)
            }
        }
    }
}

/// Copies a sent message's text (#697), as replies have a copy button. A
/// quoted reply copies only what the user wrote.
struct UserMessageCopyButton: View {
    /// Worked out once, not on each re-render of the row.
    private let text: String

    init(message: ChatMessage) {
        text = Self.copyText(for: message)
    }

    static func copyText(for message: ChatMessage) -> String {
        let text = ReplyQuoteEnvelope.parse(message.content)?.message ?? message.content
        // A voice message copies what was said.
        return VoiceMessage.parse(text)?.transcript ?? text
    }

    var body: some View {
        if text.contains(where: { !$0.isWhitespace }) {
            GroupMessageCopyButton(text: text, label: .message)
        }
    }
}

/// The ⋯ beside a sent message's Copy (issue 1420): Quote puts its words
/// in the draft, and Edit and resend takes it back, with everything after
/// it, to change and send again.
struct UserMessageMoreMenu: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed: what a row shows comes from `rowState`.
    private var appState: AppState { rowActions.required }
    @State private var confirmsEdit = false
    /// Worked out once, not on each re-render of the row.
    private let hasText: Bool
    /// Only typed words come back: a message with pictures, files or a
    /// recording can't be put back as it was.
    private let canEdit: Bool

    init(message: ChatMessage) {
        self.message = message
        hasText = UserMessageCopyButton.copyText(for: message).contains(where: { !$0.isWhitespace })
        canEdit = hasText && (message.attachments ?? []).isEmpty && VoiceMessage.parse(message.content) == nil
    }

    var body: some View {
        Menu {
            Button {
                appState.quoteOwnMessageIntoComposer(message)
            } label: {
                Label(AppLocalization.string("Quote"), systemImage: "text.quote")
            }
            .disabled(!rowState.canQuoteIntoComposer || !hasText)

            if canEdit {
                Button {
                    let messages = appState.messages
                    let later = messages.firstIndex { $0.id == message.id }.map { index in
                        messages[(index + 1)...].contains { $0.role == .user }
                    } ?? false
                    if later {
                        confirmsEdit = true
                    } else {
                        editAndResend(confirmedLaterTurns: false)
                    }
                } label: {
                    Label(AppLocalization.string("Edit and resend"), systemImage: "pencil")
                }
                .disabled(rowState.isBusy || rowState.isOffline || !rowState.canQuoteIntoComposer)
            }
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(.footnote.weight(.semibold))
                // A full-size tap target in the footer, as Copy's.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .padding(-6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(AppLocalization.string("More"))
        .accessibilityIdentifier("chat.messageMoreMenu")
        .confirmationDialog(
            AppLocalization.string("Edit and resend this message?"),
            isPresented: $confirmsEdit,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Edit and resend"), role: .destructive) {
                editAndResend(confirmedLaterTurns: true)
            }
        } message: {
            Text(AppLocalization.string("Your later messages and the replies to them leave the chat, and this one goes back in the composer to change and send again."))
        }
    }

    private func editAndResend(confirmedLaterTurns: Bool) {
        Haptics.medium()
        Task { await appState.editAndResend(message, confirmedLaterTurns: confirmedLaterTurns) }
    }
}

/// A message steered into a running turn (issue #337). Right-aligned like
/// the user's own bubble, but a lighter outlined surface with the steering
/// glyph, so it reads as guidance delivered mid-turn rather than a new prompt.
struct SteerBubble: View {
    let message: ChatMessage
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.chatTextSize) private var chatTextSize

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                SteerMessageContent(
                    message: message,
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

/// Settled steer-row content, behind the same Equatable gate as
/// UserMessageContent so streaming publishes cannot re-evaluate it.
struct SteerMessageContent: View, Equatable {
    let message: ChatMessage
    /// Explicit Dynamic Type input — see SettledAssistantMessageContent.
    let sizeCategory: ContentSizeCategory
    /// Explicit chat text-size input — see UserMessageContent.
    let chatTextSize: ChatTextAppearance

    /// One line of the reply's body text, for the icon's box.
    private var bodyLineHeight: CGFloat {
        ChatTypography.font(for: .body, appearance: chatTextSize, environmentCategory: sizeCategory).lineHeight
    }

    var body: some View {
        let reply = ReplyQuoteEnvelope.parse(message.content)
        // Markdown draws in UIKit text views, which give SwiftUI no text
        // baseline: top-align the icon in a box one body line tall.
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: BusyInputMode.steer.symbol)
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(.conduitAura)
                .frame(height: bodyLineHeight)
                .accessibilityHidden(true)
            if let reply {
                VStack(alignment: .leading, spacing: 8) {
                    ReplyReferenceQuoteCard(quote: reply.quote, onAccentSurface: false, quotedIn: message.id)
                    MarkdownText(source: reply.message)
                }
            } else {
                MarkdownText(source: message.content)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(
            Color.conduitAura.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 21, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .strokeBorder(Color.conduitAura.opacity(0.32), lineWidth: 1)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppLocalization.string("Steered: \(reply?.message ?? message.content)"))
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
    let chatTextSize: ChatTextAppearance

    static func == (lhs: Self, rhs: Self) -> Bool {
        // One comparison expression for every configuration — see
        // SettledAssistantMessageContent.== for why the DEBUG recording below
        // must never be a second copy of the field list.
        let equal = lhs.message == rhs.message
            && lhs.gatewayResolver === rhs.gatewayResolver
            && lhs.sizeCategory == rhs.sizeCategory
            && lhs.chatTextSize == rhs.chatTextSize
        #if DEBUG
        if !equal {
            var fields: [String] = []
            if lhs.message != rhs.message { fields.append("message") }
            if lhs.gatewayResolver !== rhs.gatewayResolver { fields.append("gatewayResolver") }
            if lhs.sizeCategory != rhs.sizeCategory { fields.append("sizeCategory") }
            if lhs.chatTextSize != rhs.chatTextSize { fields.append("chatTextSize") }
            TranscriptPerf.noteGateReopen(component: "UserMessageContent", fields: fields)
        }
        #endif
        return equal
    }

    @ViewBuilder private var attachmentViews: some View {
        if let attachments = message.attachments {
            ForEach(attachments) { attachment in
                if attachment.kind == .image {
                    UserImageAttachmentPreview(attachment: attachment, gatewayResolver: gatewayResolver)
                } else {
                    UserDocumentAttachmentChip(attachment: attachment, gatewayResolver: gatewayResolver)
                }
            }
        }
    }

    var body: some View {
        // A message that quoted a whole reply (#385) shows a compact
        // "Replying to" card instead of the full quote.
        let reply = ReplyQuoteEnvelope.parse(message.content)
        let text = reply?.message ?? message.content
        // A voice message: the recording, then what was said.
        let voice = VoiceMessage.parse(text)
        VStack(alignment: .leading, spacing: 9) {
            if let reply {
                ReplyReferenceQuoteCard(quote: reply.quote, quotedIn: message.id)
            }

            if let voice {
                attachmentViews
                if !voice.transcript.isEmpty {
                    HugsIdealWidth {
                        Text(verbatim: voice.transcript)
                            .scaledFont(.subheadline)
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel(AppLocalization.string("Transcript: \(voice.transcript)"))
                }
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The text fills the column for its own layout; a sent
                // bubble fits a short message instead.
                HugsIdealWidth {
                    MarkdownText(source: text, foregroundStyle: .white, usesAccentSurface: true)
                }
            }

            if voice == nil {
                attachmentViews
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 11)
        .background {
            // The shadow is the bubble shape's own. Cast by the whole bubble,
            // it was worked out again from the text's UIKit views on every
            // frame the chat scrolled.
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.conduitUserBubble, .conduitUserBubbleShade],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.conduitAccent.opacity(0.16), radius: 14, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
        }
        .textSelection(.enabled)
    }
}

/// A long press on a picture from older history shows what Hermes' vision
/// saw in it (#887), which Hermes used to save in the message itself.
private struct ImageDescriptionMenu: ViewModifier {
    let description: String?

    func body(content: Content) -> some View {
        if let description {
            content.contextMenu {
                Section("Description") {
                    Text(description)
                }
                Button {
                    UIPasteboard.general.string = description
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        } else {
            content
        }
    }
}

/// Offers its content no more width than the content would take
/// unbounded: a view that fills whatever it's offered, as Markdown text
/// does, takes only its natural width when that is narrower.
struct HugsIdealWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(contentProposal(proposal, content: content))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }

    private func contentProposal(_ proposal: ProposedViewSize, content: LayoutSubview) -> ProposedViewSize {
        guard let width = proposal.width, width.isFinite else { return proposal }
        let ideal = content.sizeThatFits(.unspecified).width
        return ProposedViewSize(width: min(width, ideal), height: proposal.height)
    }
}

private struct UserImageAttachmentPreview: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let attachment: Attachment
    let gatewayResolver: GatewayMediaDataURLResolver?
    @State private var gatewayImage: UIImage?
    /// The cache key `gatewayImage` was loaded for, so a reused view never
    /// shows the picture it held before.
    @State private var gatewayImageKey: String?
    /// The chat's pictures, which the viewer pages through.
    @Environment(\.imageGallery) private var imageGallery
    /// The cache key a load from Hermes failed for.
    @State private var gatewayFailedKey: String?
    @State private var localPreview: UIImage?
    @State private var localPreviewPath: String?
    @State private var localPreviewFailedPath: String?
    /// The chat's scroll engine, which says when a picture that will grow
    /// its row shows (#1238).
    @Environment(\.chatRowDisclosure) private var disclosure
    /// The row's frame, and the picture waiting to show in it.
    @StateObject private var arrival = ChatRowArrival()

    /// Cache-only lookup (no decode) so a hit renders on the first frame.
    /// Misses are filled asynchronously — see the `.task` in `body`.
    private var cachedLocalImage: UIImage? {
        guard let key = memoryCacheKey else { return nil }
        return TranscriptPictureMemory.previews.object(forKey: key as NSString)
    }

    /// A cache hit as the row shows it: on its first frame, or where the
    /// row has its height already. A row laid out with its loading line
    /// (another row of the same picture decoded it since) takes it
    /// through the task, which asks the scroll engine (#1238).
    private var shownCachedImage: UIImage? {
        guard let cached = cachedLocalImage, arrival.holds(previewHeight(for: cached.size)) else { return nil }
        return cached
    }

    /// Which picture the row loads.
    private var loadIdentity: String {
        "\(attachment.uri)|\(inlineImageIdentity)|\(gatewayResolver?.imageCacheKey(for: attachment) ?? "")"
    }

    /// The photo's own path when it is on this device, else where a picture
    /// from Hermes is kept on the phone.
    private var memoryCacheKey: String? {
        localFileURL?.path ?? gatewayResolver?.imageCacheKey(for: attachment)
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

    /// True only for a failed load of the *current* picture from Hermes.
    private var gatewayLoadFailed: Bool {
        gatewayFailedKey != nil && gatewayFailedKey == gatewayResolver?.imageCacheKey(for: attachment)
    }

    /// True only for a decode failure of the *current* path.
    private var localPreviewFailed: Bool {
        localPreviewFailedPath == localFileURL?.path
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
        // A picture known only by its place inside its message has no path.
        guard !attachment.uri.isEmpty else { return nil }
        if let url = URL(string: attachment.uri), url.isFileURL { return url }
        let url = URL(fileURLWithPath: attachment.uri)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        Group {
            if let image = shownCachedImage ?? currentLocalPreview ?? currentGatewayImage {
                imagePreview(image)
            } else if loadsFromHermes && localFileURL == nil && !gatewayLoadFailed {
                placeholder
                    .modifier(ImageDescriptionMenu(description: attachment.imageDescription))
                    .modifier(OptionalAccessibilityHint(hint: attachment.imageDescription))
            } else if localFileURL != nil && !localPreviewFailed {
                // Local file decoding off-main on a cache miss.
                placeholder
                    .modifier(ImageDescriptionMenu(description: attachment.imageDescription))
                    .modifier(OptionalAccessibilityHint(hint: attachment.imageDescription))
            } else {
                Label(
                    (gatewayLoadFailed || localPreviewFailed) ? AppLocalization.string("Image unavailable") : AppLocalization.string("Image attached"),
                    systemImage: (gatewayLoadFailed || localPreviewFailed) ? "photo.badge.exclamationmark" : "photo"
                )
                .scaledFont(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.13), in: Capsule())
                .modifier(ImageDescriptionMenu(description: attachment.imageDescription))
                .modifier(OptionalAccessibilityHint(hint: attachment.imageDescription))
            }
        }
        .chatRowFrame(arrival)
        // A picture still waiting to show is dropped with the row; the task
        // loads it again when the row is back.
        .onDisappear { arrival.rowDisappeared() }
        // Handed another picture: whatever still waits was the last one's.
        .onChange(of: loadIdentity) { arrival.rowDisappeared() }
        .task(id: loadIdentity) {
            // Local file: cache hits show in `body` on the first frame via
            // `shownCachedImage`, and one decoded since by another row of
            // it arrives here. Misses decode off the MainActor so a large
            // photo can't hitch scrolling.
            if let url = localFileURL {
                guard currentLocalPreview == nil, shownCachedImage == nil else { return }
                if let cached = cachedLocalImage {
                    let path = url.path
                    arrival.arrive(rowHeight: previewHeight(for: cached.size), engine: disclosure?.engine) {
                        localPreview = cached
                        localPreviewPath = path
                    }
                    return
                }
                let generation = TranscriptImageCache.generation
                let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    Self.downsampledPreview(url: url)
                }.value
                guard !Task.isCancelled else { return }
                guard let image else {
                    let path = url.path
                    // Its label shows already when the task restarts as
                    // the row comes back.
                    if localPreviewFailedPath != path {
                        placeFailure { localPreviewFailedPath = path }
                    }
                    return
                }
                // Shows once the reader's scrolling allows, kept and its
                // size remembered then: either would resize the loading
                // line on its own first.
                arrival.arrive(rowHeight: previewHeight(for: image.size), engine: disclosure?.engine) {
                    if generation == TranscriptImageCache.generation {
                        TranscriptPictureMemory.previews.setObject(image, forKey: url.path as NSString, cost: TranscriptPictureMemory.bitmapCost(of: image))
                        TranscriptPictureMemory.rememberSize(image.size, for: url.path)
                    }
                    localPreview = image
                    localPreviewPath = url.path
                }
                // A picture from Hermes. The local-file branch returns above,
                // so a local URI never reaches here — which also removes the
                // old `localImage == nil` check that decoded local files on
                // the MainActor before short-circuiting.
            } else if loadsFromHermes, let gatewayResolver,
                      let cacheKey = gatewayResolver.imageCacheKey(for: attachment) {
                // Held by the view too, so the picture stays when the
                // shared cache evicts it while this row is on screen; one
                // decoded since by another row of it arrives like a load.
                if let cached = cachedLocalImage {
                    place(cached, as: cacheKey, generation: TranscriptImageCache.generation)
                    return
                }
                // One that failed keeps its label while it loads again.
                gatewayImage = nil
                // Kept on the phone from an earlier load (#652). Read
                // first: after a sign-out it shows, but isn't remembered.
                let keptGeneration = TranscriptImageCache.generation
                if let image = await Self.keptPreview(for: cacheKey) {
                    guard !Task.isCancelled else { return }
                    place(image, as: cacheKey, generation: keptGeneration)
                    return
                }
                guard !Task.isCancelled else { return }
                // The server file, else the copy Hermes stored inside the
                // message: Hermes clears the files that came in through chat
                // platforms after a day.
                // Read first: a sign-out during the fetch keeps it off the phone.
                let generation = TranscriptImageCache.generation
                var dataURL: String?
                if isGatewayImage {
                    dataURL = await gatewayResolver.dataURL(for: attachment.uri)
                }
                if dataURL == nil, !Task.isCancelled, let ref = attachment.inlineImage {
                    dataURL = await gatewayResolver.inlineImageDataURL(ref)
                }
                guard !Task.isCancelled else { return }
                guard let dataURL, let image = await Self.keep(dataURL, as: cacheKey, generation: generation) else {
                    if gatewayFailedKey != cacheKey {
                        placeFailure { gatewayFailedKey = cacheKey }
                    }
                    return
                }
                guard !Task.isCancelled else { return }
                place(image, as: cacheKey, generation: generation)
            }
        }
    }

    /// A picture that won't load gives its place to the label once the
    /// reader's scrolling allows (ChatRowArrival), a height only the
    /// label's layout tells.
    private func placeFailure(_ mark: @escaping () -> Void) {
        arrival.arrive(rowHeight: nil, engine: disclosure?.engine, show: mark)
    }

    /// Puts a picture from Hermes in the row once the reader's scrolling
    /// allows (ChatRowArrival), remembering it then: remembered first,
    /// its size would resize the loading line on its own. After a sign-out
    /// it shows, but isn't remembered.
    private func place(_ image: UIImage, as key: String, generation: Int) {
        arrival.arrive(rowHeight: previewHeight(for: image.size), engine: disclosure?.engine) {
            if generation == TranscriptImageCache.generation {
                remember(image, as: key)
            } else {
                gatewayImage = image
                gatewayImageKey = key
            }
        }
    }

    private func remember(_ image: UIImage, as key: String) {
        TranscriptPictureMemory.previews.setObject(image, forKey: key as NSString, cost: TranscriptPictureMemory.bitmapCost(of: image))
        TranscriptPictureMemory.rememberSize(image.size, for: key)
        gatewayImage = image
        gatewayImageKey = key
    }

    private var currentGatewayImage: UIImage? {
        guard let gatewayImageKey, gatewayImageKey == memoryCacheKey else { return nil }
        return gatewayImage
    }

    /// Which picture inside its message this is, so a message that later
    /// gains the way back to its pictures loads them again.
    private var inlineImageIdentity: String {
        attachment.inlineImage.map { "\($0.profile)/\($0.sessionId)/\($0.rowId)/\($0.index)" } ?? ""
    }

    /// The picture kept on the phone under `key`, decoded off the
    /// MainActor at preview size.
    private static func keptPreview(for key: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            TranscriptImageCache.cachedFile(for: key, touch: true).flatMap { Self.downsampledPreview(url: $0) }
        }.value
    }

    /// Keeps the picture in `dataURL` on the phone and decodes it at
    /// preview size, both off the MainActor. A failed write still shows it.
    private static func keep(_ dataURL: String, as key: String, generation: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let file = TranscriptImageCache.store(dataURL: dataURL, for: key, generation: generation) {
                return Self.downsampledPreview(url: file)
            }
            return DataURLLimits.decodeBase64DataURL(dataURL, prefix: "data:image/").flatMap { UIImage(data: $0) }
        }.value
    }

    /// The picture's size when it's known before it loads (remembered when
    /// it last loaded, on this launch or an earlier one). A row scrolled
    /// back into view then takes its final height at once instead of
    /// growing from the loading line (#1238).
    private var reservedSize: CGSize? {
        memoryCacheKey.flatMap(TranscriptPictureMemory.size(for:))
    }

    /// At the reserved size when it was known as the row was first laid
    /// out: one remembered after (another row of the same picture, or a
    /// cold launch's kept sizes loading) would resize the loading line on
    /// its own.
    @ViewBuilder private var placeholder: some View {
        if let size = reservedSize, arrival.holds(previewHeight(for: size)) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.13))
                .frame(width: 224, height: previewHeight(for: size))
                .overlay { ProgressView().tint(.white) }
                .accessibilityElement()
                .accessibilityLabel(Text("Loading image…"))
        } else {
            loadingPlaceholder
        }
    }

    private var loadingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(.white)
            Text("Loading image…")
        }
        .scaledFont(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.13), in: Capsule())
    }

    private var isGatewayImage: Bool {
        attachment.uri.hasPrefix("/")
    }

    /// Fetched through Hermes: by its server file, or as the copy stored
    /// inside its message.
    private var loadsFromHermes: Bool {
        isGatewayImage || attachment.inlineImage != nil
    }

    private func imagePreview(_ image: UIImage) -> some View {
        Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 224, height: previewHeight(for: image.size))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }
                .opensMediaPreview { openPreview(showing: image) }
                .modifier(ImageDescriptionMenu(description: attachment.imageDescription))
                .accessibilityLabel("Attached image: \(attachment.imageDescription ?? attachment.name)")
                .accessibilityAddTraits(.isImage)
    }

    /// Opens the full-resolution original among the chat's pictures: the
    /// local file when the photo is still on this device, otherwise the
    /// bytes re-fetched from Hermes, with the row's copy shown meanwhile.
    /// The row keeps only the downsampled/decoded image, never the original
    /// bytes, so an image-heavy transcript doesn't pin them all in memory.
    private func openPreview(showing image: UIImage) {
        guard let item = ImageGalleryItem.attachment(attachment, resolver: gatewayResolver) else { return }
        ImageGallery.open(item, in: imageGallery, placeholder: image)
    }

    private func previewHeight(for size: CGSize) -> CGFloat {
        guard size.width > 0 else { return 168 }
        return min(260, max(120, 224 * size.height / size.width))
    }

}

/// The name a previewed attachment is saved/shared under: the display name,
/// borrowing the stored path's extension when the name has none so the
/// share sheet and Quick Look still recognize the type.
enum AttachmentPreviewFilename {
    static func make(name: String, uri: String) -> String {
        let uriName = MediaPreviewPresenter.sanitizedFilename(uri)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return uriName }
        let cleanName = MediaPreviewPresenter.sanitizedFilename(trimmed)
        let uriExtension = (uriName as NSString).pathExtension
        guard !uriExtension.isEmpty else { return cleanName }
        // The stored path's extension describes the bytes; a display name
        // that disagrees (or has none) would make Quick Look pick the wrong
        // renderer.
        let nameExtension = (cleanName as NSString).pathExtension
        if nameExtension.caseInsensitiveCompare(uriExtension) == .orderedSame { return cleanName }
        let stem = nameExtension.isEmpty ? cleanName : (cleanName as NSString).deletingPathExtension
        return MediaPreviewPresenter.truncatedFilename("\(stem).\(uriExtension)")
    }
}

private struct UserDocumentAttachmentChip: View {
    let attachment: Attachment
    let gatewayResolver: GatewayMediaDataURLResolver?
    @State private var loading = false
    @State private var failed = false
    @State private var openTask: Task<Void, Never>?

    private var localFileURL: URL? {
        if let url = URL(string: attachment.uri), url.isFileURL {
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let url = URL(fileURLWithPath: attachment.uri)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Audio the user attached plays in place, like the agent's (#439).
    private var isAudio: Bool {
        GatewayMediaKind(path: attachment.name) == .audio || GatewayMediaKind(path: attachment.uri) == .audio
    }

    var body: some View {
        Group {
            if isAudio {
                InlineAudioClipView(
                    id: "attachment:\(attachment.uri)",
                    // A recorded voice message, not a file the user picked.
                    name: VoiceMessage.isVoiceMessageFile(attachment.name)
                        ? AppLocalization.string("Voice message")
                        : attachment.name,
                    filename: AttachmentPreviewFilename.make(name: attachment.name, uri: attachment.uri),
                    style: .bubble,
                    opening: loading,
                    openFailed: failed,
                    load: loadAudio,
                    openFull: open
                )
            } else {
                chip
            }
        }
        .onDisappear {
            openTask?.cancel()
            openTask = nil
            loading = false
        }
    }

    private var chip: some View {
        HStack(spacing: 6) {
            Label(AttachmentTypePolicy.displayName(for: attachment), systemImage: AttachmentTypePolicy.symbolName(for: attachment))
                .lineLimit(1)
            if loading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
        }
        .scaledFont(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.13), in: Capsule())
        .opensMediaPreview(open)
    }

    /// The clip's bytes: the local file while it is still on this device,
    /// otherwise fetched from Hermes. Read and decoded off the main actor.
    private func loadAudio() async -> Data? {
        if let localFileURL {
            return await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: localFileURL, options: .mappedIfSafe)
            }.value
        }
        guard attachment.uri.hasPrefix("/"), let gatewayResolver,
              let dataURL = await gatewayResolver.dataURL(for: attachment.uri) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            DataURLLimits.decodeBase64DataURL(dataURL)
        }.value
    }

    private func open() {
        if let localFileURL {
            failed = !MediaPreviewPresenter.shared.present(fileURL: localFileURL, title: AttachmentTypePolicy.displayName(for: attachment))
            return
        }
        guard !loading, attachment.uri.hasPrefix("/"), let gatewayResolver else { return }
        loading = true
        failed = false
        // Cancelled on disappear, so a slow fetch can't pop a preview over
        // whatever screen the user moved on to.
        openTask = Task {
            var presented = false
            if let dataURL = await gatewayResolver.dataURL(for: attachment.uri), !Task.isCancelled {
                presented = await MediaPreviewPresenter.shared.present(
                    dataURL: dataURL,
                    filename: AttachmentPreviewFilename.make(name: attachment.name, uri: attachment.uri)
                )
            }
            guard !Task.isCancelled else { return }
            loading = false
            failed = !presented
        }
    }
}

/// The settled half of an assistant row: identity header, Markdown body,
/// and code block. Equatable over immutable message presentation inputs so
/// a streaming publish re-creating this view is a no-op (`.equatable()`
/// skips body evaluation when inputs compare equal). Dynamic Type changes
/// still invalidate through the `\.sizeCategory` environment read.
struct SettledAssistantMessageContent: View, Equatable {
    let message: ChatMessage
    /// The agent this reply speaks as — the owning bot inside a Bot Chat,
    /// else the active workspace profile. One value so the gate's equality
    /// covers the whole face (name, photo, bot picture and color).
    let identity: ConversationAgentIdentity
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
    let chatTextSize: ChatTextAppearance

    static func == (lhs: Self, rhs: Self) -> Bool {
        // ONE comparison expression for every configuration: the field list a
        // gate actually compares must never diverge between DEBUG (what the
        // tests exercise) and Release (what ships). The DEBUG-only recording
        // below observes the outcome and cannot change it.
        let equal = lhs.message == rhs.message
            && lhs.identity == rhs.identity
            && lhs.gatewayResolver === rhs.gatewayResolver
            && lhs.sizeCategory == rhs.sizeCategory
            && lhs.chatTextSize == rhs.chatTextSize
        #if DEBUG
        // Consultation counter: a fixture asserting "the gate reported no
        // input change" is vacuous unless the gate was reached at all, and a
        // hosting shape that re-creates the subtree without consulting the
        // comparison leaves the report list empty too.
        TranscriptPerf.note(.settledContentGateComparison)
        if !equal {
            var fields: [String] = []
            if lhs.message != rhs.message { fields.append("message") }
            if lhs.identity != rhs.identity { fields.append("identity") }
            if lhs.gatewayResolver !== rhs.gatewayResolver { fields.append("gatewayResolver") }
            if lhs.sizeCategory != rhs.sizeCategory { fields.append("sizeCategory") }
            if lhs.chatTextSize != rhs.chatTextSize { fields.append("chatTextSize") }
            TranscriptPerf.noteGateReopen(component: "SettledAssistantMessageContent", fields: fields)
        }
        #endif
        return equal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Keep identity in a compact header so the actual response can use
            // the full reading column instead of inheriting the avatar indent.
            HStack(spacing: 8) {
                ConduitAgentMark(identity: identity)

                Text(identity.name)
                    .scaledFont(.caption.weight(.semibold))
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

/// The dynamic half of an assistant row: the copy control (quote, branch
/// and pin sit in `AssistantMessageMoreMenu`), kept small so its
/// per-publish re-evaluation is cheap.
struct AssistantMessageActions: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed: what a row shows comes from `rowState`.
    private var appState: AppState { rowActions.required }
    @State private var copied = false

    var body: some View {
        Button {
            copyResponse()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .scaledFont(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? Color.conduitAccent : Color.secondary)
        .accessibilityLabel(copied ? AppLocalization.string("Response copied") : AppLocalization.string("Copy response"))
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

/// The ⋯ at the end of a reply's row (#1147): Quote, Branch and Pin reply,
/// so the row keeps a few icons while each action stays a tap away, and
/// Show thinking while Settings > Chat's Thinking is On request.
struct AssistantMessageMoreMenu: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    /// The thinking right above the reply (ChatThinkingReveal).
    var thinking: ChatThinkingReveal? = nil
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed: what a row shows comes from `rowState`.
    private var appState: AppState { rowActions.required }

    @State private var confirmsRetry = false

    private var hasText: Bool {
        message.content.contains(where: { !$0.isWhitespace })
    }

    var body: some View {
        Menu {
            // Attaches this whole reply to the next message (#385); the
            // composer plays the haptic when the chip lands.
            Button {
                appState.replyInComposer(to: message)
            } label: {
                Label(AppLocalization.string("Quote"), systemImage: "quote.bubble")
            }
            .disabled(!rowState.canQuoteIntoComposer || !hasText)

            Button {
                Haptics.medium()
                Task { await appState.branchFromAssistantMessage(message.id) }
            } label: {
                Label(AppLocalization.string("Branch"), systemImage: "arrow.triangle.branch")
            }
            .disabled(rowState.isBusy || rowState.isBranchingChat || rowState.isOffline)

            // The newest reply only, while it answers the last message sent:
            // /retry sends that message again (issue 1420).
            if message.id == rowState.retryableReplyID {
                Button {
                    if AppState.latestTurnRanTools(in: appState.messages) {
                        confirmsRetry = true
                    } else {
                        retry()
                    }
                } label: {
                    Label(AppLocalization.string("Retry"), systemImage: "arrow.clockwise")
                }
                .disabled(rowState.isBusy || rowState.isOffline || !rowState.canQuoteIntoComposer)
            }

            // The whole reply; a selection's menu pins a passage.
            if rowState.canPinReplies {
                let isPinned = rowState.pinnedMessageIDs.contains(message.id)
                Button {
                    Haptics.light()
                    appState.togglePinnedReply(appState.messages.first { $0.id == message.id } ?? message)
                } label: {
                    Label(
                        AppLocalization.string(isPinned ? "Unpin reply" : "Pin reply"),
                        systemImage: isPinned ? "pin.slash.fill" : "pin.fill"
                    )
                }
                .disabled(!hasText)
            }

            if let thinking {
                Button(action: thinking.toggle) {
                    Label(thinking.title, systemImage: ChatStepStyle.thinking.symbol)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(AppLocalization.string("More"))
        .accessibilityIdentifier("chat.replyMoreMenu")
        // Steps run again: a file written, a message sent, twice.
        .confirmationDialog(
            AppLocalization.string("Retry this reply?"),
            isPresented: $confirmsRetry,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Retry")) {
                retry()
            }
        } message: {
            Text(AppLocalization.string("Steps ran for this reply, and retrying runs them again."))
        }
    }

    /// As typing /retry: the reply goes and your last message is sent again.
    private func retry() {
        Haptics.medium()
        Task { _ = await appState.submitComposer(text: "/retry") }
    }
}

/// A reply's ⋯ when the run above it has thinking that Settings > Chat's
/// Thinking keeps for On request: it follows the runs' toggles, so the item reads Hide thinking
/// once that thinking shows, whichever menu showed it.
private struct AssistantMessageMoreMenuWithThinking: View {
    let message: ChatMessage
    let run: ChatStepGroup
    let disclosure: ChatRowDisclosure
    @ObservedObject var toggles: ChatStepGroupToggles

    var body: some View {
        AssistantMessageMoreMenu(
            message: message,
            thinking: ChatThinkingReveal(group: run, disclosure: disclosure)
        )
    }
}

/// The read-aloud control surface. This is deliberately the ONLY part of
/// an assistant row that observes the shared read-aloud controller, so a
/// playback state transition re-renders a 34pt button instead of every
/// response's Markdown in the transcript.
struct ReadAloudButton: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    @ObservedObject var controller: MessageReadAloudController
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed: what a row shows comes from `rowState`.
    private var appState: AppState { rowActions.required }

    private var isActive: Bool {
        controller.isActiveMessage(message.id)
    }

    /// Paused from the lock screen or headphones (#373): the button resumes.
    private var isPaused: Bool {
        isActive && controller.isPaused
    }

    private var unavailable: Bool {
        rowState.readAloudUnavailable || rowState.isOffline
    }

    var body: some View {
        Button {
            if isPaused {
                Haptics.light()
                controller.resume()
                return
            }
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
                    Image(systemName: isPaused ? "play.fill" : isActive ? "stop.fill" : "speaker.wave.2")
                }
            }
            .scaledFont(.subheadline.weight(.semibold))
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.conduitAccent : Color.secondary)
        .disabled(unavailable && !isActive)
        .opacity(unavailable && !isActive ? 0.45 : 1)
        .accessibilityLabel(
            isPaused ? AppLocalization.string("Resume reading response")
                : isActive ? AppLocalization.string("Stop reading response")
                : AppLocalization.string("Read response aloud")
        )
    }
}

struct AssistantBubble: View {
    let message: ChatMessage
    /// Held as a plain reference (not @ObservedObject): forwarding a
    /// controller instance must not subscribe this whole bubble to every
    /// read-aloud state transition. Only ReadAloudButton observes it.
    let readAloudController: MessageReadAloudController
    let gatewayResolver: GatewayMediaDataURLResolver?
    /// The run of steps above the reply, when it has thinking.
    var stepsAbove: ChatStepGroup? = nil
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowActions) private var rowActions
    @Environment(\.chatRowDisclosure) private var disclosure
    /// Acted on, not observed: what a row shows comes from `rowState`.
    private var appState: AppState { rowActions.required }
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.chatTextSize) private var chatTextSize
    @State private var showsTapback = false

    var body: some View {
        // Mirrors MessageBubble's settled-bubble counter so the dormancy
        // fixtures can prove a re-created row's body chain actually ran
        // (and therefore that the Equatable gate below was consulted)
        // instead of the update being pruned above the gate. Release
        // builds compile the note out.
        let _ = TranscriptPerf.note(.settledBubbleBody)
        let identity = rowState.agentIdentity
        VStack(alignment: .leading, spacing: 6) {
            SettledAssistantMessageContent(
                message: message,
                identity: identity,
                gatewayResolver: gatewayResolver,
                sizeCategory: sizeCategory,
                chatTextSize: chatTextSize
            )
            .equatable()
            // Pin sits in the reply's long-press menu, not its action row
            // (#918): Pin for the selected passage, Pin reply for all of it
            // (#1147). A pinned passage's jump flashes it in this text.
            .environment(\.chatPinReplyAction, rowState.canPinReplies
                ? ChatPinReplyAction(message: message, appState: appState)
                : nil)

            if !message.reactions.isEmpty {
                MessageReactionChips(
                    reactions: message.reactions,
                    agentName: identity.name,
                    onTap: rowState.canReact(to: message) ? { showsTapback = true } : nil
                )
            }

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if message.role == .assistant {
                    MessageReactButton(message: message, isPresented: $showsTapback)
                }

                AssistantMessageActions(message: message)

                if message.role == .assistant {
                    ReadAloudButton(message: message, controller: readAloudController)
                }

                if let run = stepsAbove, let disclosure, rowState.displayPreferences.offersShowThinking {
                    AssistantMessageMoreMenuWithThinking(
                        message: message,
                        run: run,
                        disclosure: disclosure,
                        toggles: disclosure.groupToggles
                    )
                } else {
                    AssistantMessageMoreMenu(message: message)
                }
            }
            .padding(.top, 2)
            // Fixed 34 pt buttons: larger glyphs would overlap each other.
            .conduitFixedGlyph()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - System Message (slash command output)

struct SystemBubble: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
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
                .scaledFont(.footnote.weight(.medium))
                .foregroundStyle(.conduitAccent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(isRuntimeNotice ? AppLocalization.string("System") : AppLocalization.string("Command"))
                        .scaledFont(.caption2.weight(.semibold))
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
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.columnText) private var columnText
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let activity: ReviewActivity
    let timestamp: String
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed (`ChatRowState`).
    private var appState: AppState { rowActions.required }
    @Environment(\.chatRowDisclosure) private var disclosure
    @State private var expanded = false

    private var details: [String] { activity.details?.filter { !$0.isEmpty } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                guard !details.isEmpty else { return }
                disclosure?.willToggle(nil, to: !expanded)
                withAnimation(ConduitMotion.response) { expanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "internaldrive.fill")
                            .foregroundStyle(.conduitAura)
                            .frame(width: 28, height: 28)
                            .background(Color.conduitAura.opacity(0.14), in: Circle())
                        CardHeaderCaption(timestamp: timestamp) {
                            Text("SELF-IMPROVEMENT REVIEW")
                                .scaledFont(.caption2.weight(.bold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                        }
                        if !details.isEmpty {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .scaledFont(.caption.weight(.semibold))
                                .conduitFixedGlyph()
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                        }
                    }
                    SelectableTextView(
                        text: activity.summary,
                        font: .preferredFont(forTextStyle: .subheadline, in: sizeCategory, from: columnText).withTraits(.traitBold),
                        textColor: .label
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(details.isEmpty)
            .accessibilityLabel(details.isEmpty ? activity.summary : (expanded ? AppLocalization.string("Collapse review details") : AppLocalization.string("Expand review details")))

            if expanded, !details.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                        SelectableTextView(
                            text: detail,
                            font: .preferredFont(forTextStyle: .callout, in: sizeCategory, from: columnText),
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
                        .scaledFont(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 42)
                }
                .background(Color.conduitAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(14)
        .chatCard(cornerRadius: 18, tint: .conduitAura.opacity(0.09))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.conduitAura.opacity(0.18), lineWidth: 1)
        }
    }
}

/// A run of two or more reviews (ChatReviewRun): one line with the count
/// and the last one's time, and the first review's card under it while
/// open (the run's other rows draw theirs). Like ReviewSummaryCard, outside
/// the chat text-size preference.
private struct ReviewRunCard<FirstCard: View>: View {
    let run: ChatReviewRun
    let disclosure: ChatRowDisclosure
    @ObservedObject var toggles: ChatStepGroupToggles
    @ViewBuilder let firstCard: FirstCard

    var body: some View {
        let expanded = disclosure.isGroupExpanded(run.id, default: false)
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(ConduitMotion.response) {
                    Haptics.light()
                    disclosure.willToggleGroup(run.id, to: !expanded)
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "internaldrive.fill")
                        .foregroundStyle(.conduitAura)
                        .frame(width: 28, height: 28)
                        .background(Color.conduitAura.opacity(0.14), in: Circle())
                    CardHeaderCaption(timestamp: run.lastTimestamp) {
                        Text("\(run.count) self-improvement reviews")
                            .scaledFont(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .scaledFont(.caption.weight(.semibold))
                        .conduitFixedGlyph()
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .chatCard(cornerRadius: 18, tint: .conduitAura.opacity(0.09))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.conduitAura.opacity(0.18), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))

            if expanded {
                firstCard
            }
        }
    }
}

/// Model-change summary. Intentionally OUTSIDE the chat text-size
/// preference (issue #85) — a status/activity card with fixed typography;
/// see ReviewSummaryCard.
private struct ModelChangeSummaryCard: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.columnText) private var columnText
    let model: String
    let provider: String
    let timestamp: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.conduitAccent)
                    .frame(width: 28, height: 28)
                    .background(Color.conduitAccent.opacity(0.14), in: Circle())
                CardHeaderCaption(timestamp: timestamp) {
                    Text("MODEL UPDATED")
                        .scaledFont(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                }
            }
            SelectableTextView(
                text: AppLocalization.string("Model has been changed to \(provider)/\(model)"),
                font: .preferredFont(forTextStyle: .subheadline, in: sizeCategory, from: columnText).withTraits(.traitBold),
                textColor: .label
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .chatCard(cornerRadius: 18, tint: .conduitAccent.opacity(0.07))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.conduitAccent.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A voice call started from this chat: the marker opens its spoken turns,
/// kept with the chat (#556) or, for older calls and hosts, saved as their
/// own session. In such a session (`origin`), the same card leads back to
/// the chat.
private struct VoiceCallMarkerCard: View {
    let link: VoiceCallChatLink
    let origin: Bool
    let open: () -> Void

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
    private static let timestampFormatter = ISO8601DateFormatter()

    private var duration: String? {
        Self.durationFormatter.string(from: max(0, link.endedAt.timeIntervalSince(link.startedAt)))
    }

    private var title: String {
        if origin { return AppLocalization.string("Started from \(link.chatTitle)") }
        return link.resumed ? AppLocalization.string("Voice call resumed") : AppLocalization.string("Voice call")
    }

    private var detail: String {
        if origin { return AppLocalization.string("Open chat") }
        return duration.map { AppLocalization.string("\($0) · Open transcript") } ?? AppLocalization.string("Open transcript")
    }

    private var started: String? {
        MessageTimestampFormatter.displayString(for: Self.timestampFormatter.string(from: link.startedAt))
    }

    /// Title, length (not on the origin card) and start time; the action
    /// stays in the hint.
    private var spokenLabel: String {
        [title, origin ? nil : duration, started.map { AppLocalization.string("Started \($0)") }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: origin ? "bubble.left.and.bubble.right.fill" : "phone.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.conduitAccent)
                    .frame(width: 28, height: 28)
                    .background(Color.conduitAccent.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                // The start time on the short detail line, so a long title
                // ("Started from" a chat) keeps the row's width (#1440).
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Text(detail)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let started {
                            Text(started)
                                .scaledFont(.caption2.weight(.medium))
                                .foregroundStyle(Color.conduitAccent.opacity(0.78))
                                .monospacedDigit()
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }
                }
                Image(systemName: "chevron.right")
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.conduitTertiary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatCard(cornerRadius: 18, tint: .conduitAccent.opacity(0.07))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.conduitAccent.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(origin ? AppLocalization.string("Opens the chat this call was started from") : AppLocalization.string("Opens the call's transcript")))
    }
}

/// Settled reasoning-row content, gated the same way as assistant/user
/// content: identical presentation inputs skip body evaluation during
/// unrelated AppState publishes. Internal (not private) so the gate
/// contract is directly testable.
struct SettledThinkingCardContent: View, Equatable {
    let message: ChatMessage
    /// Explicit Dynamic Type input — see SettledAssistantMessageContent.
    let sizeCategory: ContentSizeCategory
    /// Explicit chat text-size input — see SettledAssistantMessageContent.
    let chatTextSize: ChatTextAppearance
    /// Drawn inside a run's card: no card of its own, its time taken in
    /// place of the clock time.
    var grouped = false
    @Environment(\.chatRowDisclosure) private var disclosure
    /// Nil until tapped here: a rebuilt row (the live card settling, a lazy
    /// row coming back) takes what the reader chose from `disclosure`.
    @State private var expanded: Bool?

    private var isExpanded: Bool {
        expanded ?? disclosure?.isExpanded(message.id, default: false) ?? false
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.sizeCategory == rhs.sizeCategory
            && lhs.chatTextSize == rhs.chatTextSize
            && lhs.grouped == rhs.grouped
    }

    var body: some View {
        // V2: a quiet step row on the full reading column, no avatar column.
        VStack(alignment: .leading, spacing: 0) {
            Button {
                let opens = !isExpanded
                disclosure?.willToggle(message.id, to: opens)
                withAnimation(ConduitMotion.response) {
                    expanded = opens
                }
            } label: {
                HStack(spacing: 11) {
                    ChatStepIcon(symbol: ChatStepStyle.thinking.symbol, tint: ChatStepStyle.thinking.tint)
                    AdaptiveStack(spacing: 6) {
                        Text(AppLocalization.string("Thinking"))
                            .scaledFont(.body)
                            .foregroundStyle(.secondary)
                        ChatStepTimeLabel(timestamp: message.timestamp, duration: message.stepDuration, grouped: grouped)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(.conduitTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, ChatStepStyle.rowHorizontalPadding)
                .padding(.vertical, ChatStepStyle.rowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))

            if isExpanded {
                SelectableTextView(
                    text: message.content,
                    font: ChatTypography.font(for: .thinking, appearance: chatTextSize),
                    textColor: .secondaryLabel
                )
                .padding(.leading, ChatStepStyle.contentInset)
                .padding(.trailing, ChatStepStyle.rowHorizontalPadding)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .chatStepCard(!grouped)
    }
}

struct ThinkingCard: View {
    let message: ChatMessage
    var grouped = false
    /// Its run's Show thinking, with Settings > Chat's Thinking On request.
    var shownAnyway = false
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed: what a row shows comes from `rowState`.
    private var appState: AppState { rowActions.required }
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.chatTextSize) private var chatTextSize

    var body: some View {
        if rowState.displayPreferences.showReasoning || shownAnyway, !message.content.isEmpty {
            SettledThinkingCardContent(
                message: message,
                sizeCategory: sizeCategory,
                chatTextSize: chatTextSize,
                grouped: grouped
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
                .scaledFont(.caption2.weight(.medium))
                .foregroundStyle(tone == .supporting ? Color.conduitAccent.opacity(0.78) : Color.conduitAccent.opacity(0.70))
                .monospacedDigit()
                .accessibilityLabel(AppLocalization.string("Sent \(label)"))
        }
    }
}

/// An activity card's caption with its time on the right (#1440); the
/// card's text runs the full width below the row. The time keeps its one
/// line and is laid out first, so a long caption wraps beside it (a raw
/// time that doesn't parse truncates only past the row's width), and at
/// the accessibility text
/// sizes the time goes under the caption, as on VoiceJobLinkCard.
private struct CardHeaderCaption<Caption: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let timestamp: String
    @ViewBuilder let caption: Caption

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            caption
                .frame(maxWidth: .infinity, alignment: .leading)
            MessageTimestampLabel(timestamp: timestamp, tone: .supporting)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
    }
}

/// A step's time: how long it took when known; else, on a step standing
/// alone, when it happened.
private struct ChatStepTimeLabel: View {
    let timestamp: String
    let duration: TimeInterval?
    let grouped: Bool
    var tone: MessageTimestampTone = .subtle

    var body: some View {
        if let text = ChatStepTiming.text(duration) {
            Text(text)
                .scaledFont(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(ChatStepTiming.spokenText(duration) ?? text)
        } else if !grouped {
            MessageTimestampLabel(timestamp: timestamp, tone: tone)
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

    static func date(from rawTimestamp: String) -> Date? {
        let value = rawTimestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let number = Double(value) {
            let seconds = number > 10_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }

        if let date = internetDateFormatter.date(from: value) { return date }
        return fractionalInternetDateFormatter.date(from: value)
    }

    // Shared parsers: building an ISO8601DateFormatter is expensive, and
    // this runs for every mounted row on each streaming publish.
    private static let internetDateFormatter = ISO8601DateFormatter()
    private static let fractionalInternetDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Tool Card

/// Settled tool-row content, gated on the message and expansion default so
/// streaming publishes skip its SelectableTextView measurement work.
private struct SettledToolCardContent: View, Equatable {
    let message: ChatMessage
    /// The step's words, named from Hermes' tools catalog when Conduit has
    /// none of its own.
    let label: ChatStepLabel
    let expandToolsByDefault: Bool
    /// Explicit Dynamic Type input — see SettledAssistantMessageContent.
    let sizeCategory: ContentSizeCategory
    /// Drawn inside a run's card; see SettledThinkingCardContent.
    var grouped = false
    /// Resolves a picture or audio file a tool made on the Hermes host.
    var gatewayResolver: GatewayMediaDataURLResolver?
    @Environment(\.chatRowDisclosure) private var disclosure
    /// Nil until tapped here; see SettledThinkingCardContent.
    @State private var tapped: Bool?
    /// Names the teammate a delivery messaged; read, not observed.
    @Environment(\.chatRowActions) private var rowActions
    /// Its `botLabels` redraw that name once the roster loads.
    @Environment(\.chatRowState) private var rowState

    /// Open from the start when tools expand by default, rather than opening
    /// on appear: a row that grows after its first layout moves everything
    /// below it.
    private var expanded: Bool {
        tapped ?? disclosure?.isExpanded(message.id, default: expandToolsByDefault) ?? expandToolsByDefault
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.label == rhs.label
            && lhs.expandToolsByDefault == rhs.expandToolsByDefault
            && lhs.sizeCategory == rhs.sizeCategory
            && lhs.grouped == rhs.grouped
            && lhs.gatewayResolver === rhs.gatewayResolver
    }

    /// A delivery to a teammate bot, unless it failed: Desktop shows a
    /// failed one as the plain step it was.
    private func delivery(_ tool: ToolActivity) -> BotTeammateMessages.Delivery? {
        guard let delivery = BotTeammateMessages.delivery(toolName: tool.name, input: tool.input, output: tool.output)
        else { return nil }
        if tool.status == .complete, let presentation, presentation.error != nil || presentation.exitCode != nil {
            return nil
        }
        return delivery
    }

    private func teammateName(_ key: String) -> String {
        let _ = rowState.botLabels
        return BotTeammateMessages.displayName(for: key, in: rowActions?.appState.botRoster ?? [])
    }

    /// "Messaged Atlas" for a delivery to a teammate bot, as Desktop shows
    /// it; otherwise the step's own words.
    private func stepTitle(
        _ delivery: BotTeammateMessages.Delivery?,
        running: Bool
    ) -> String {
        guard let delivery else { return running ? label.runningTitle : label.doneTitle }
        let name = teammateName(delivery.target)
        return running
            ? AppLocalization.string("Messaging \(name)…")
            : AppLocalization.string("Messaged \(name)")
    }

    /// The readable part of a finished call's result, if Conduit has one.
    private var presentation: ToolResultPresentation? {
        guard let tool = message.tool, tool.status == .complete else { return nil }
        return ToolResultPresentation.cached(toolName: tool.name, output: tool.output)
    }

    var body: some View {
        if let tool = message.tool {
            let style = ChatStepStyle(toolName: tool.name)
            let running = tool.status == .running
            let delivery = delivery(tool)
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    let opens = !expanded
                    disclosure?.willToggle(message.id, to: opens)
                    withAnimation(ConduitMotion.response) {
                        Haptics.light()
                        tapped = opens
                    }
                } label: {
                    // V2: plain words for what the step did, what it was
                    // about underneath, and the tool's own name only once
                    // it is opened.
                    HStack(spacing: ChatStepStyle.iconGap) {
                        ChatStepIcon(symbol: style.symbol, tint: style.tint)

                        VStack(alignment: .leading, spacing: 1) {
                            // Large text: the time goes under the words
                            // instead of squeezing them.
                            AdaptiveStack(spacing: 6) {
                                Text(stepTitle(delivery, running: running))
                                    .scaledFont(.body)
                                    .foregroundStyle(running ? Color.conduitAccent : Color.primary)
                                    .lineLimit(sizeCategory.isAccessibilityCategory ? nil : 1)
                                ChatStepTimeLabel(
                                    timestamp: message.timestamp,
                                    duration: tool.duration,
                                    grouped: grouped,
                                    tone: .supporting
                                )
                            }
                            // A delivery's subject is what was said, not the
                            // command that sent it.
                            if !expanded, let subject = delivery?.message.flatMap({ ChatStepSubject.line(from: $0) })
                                ?? label.action
                                ?? ChatStepSubject.line(from: tool.input)
                                ?? ChatStepSubject.line(from: tool.output) {
                                Text(subject)
                                    .scaledFont(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }

                        Spacer(minLength: 8)

                        if running {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(Color.conduitAccent)
                                .accessibilityHidden(true)
                        }

                        Image(systemName: "chevron.down")
                            .scaledFont(.caption.weight(.semibold))
                            .foregroundStyle(.conduitTertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, ChatStepStyle.rowHorizontalPadding)
                    .padding(.vertical, ChatStepStyle.rowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tool.name)
                            .scaledFont(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(.conduitTertiary)
                        if let detail = label.detail {
                            Text(detail)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        let presentation = self.presentation
                        if let presentation {
                            ToolResultBodyView(presentation: presentation, gatewayResolver: gatewayResolver)
                        }
                        if let input = tool.input, !input.isEmpty {
                            ToolRawTextSection(
                                title: AppLocalization.string("Input"),
                                text: ToolResultPresentation.cachedPrettyJSON(input) ?? input
                            )
                        }
                        if let output = tool.output, !output.isEmpty {
                            // What the tool returned, word for word, under
                            // the readable part above.
                            ToolRawTextSection(
                                title: AppLocalization.string("Output"),
                                text: ToolResultPresentation.cachedPrettyJSON(output) ?? output
                            )
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.leading, ChatStepStyle.contentInset)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // A terminal delivery waits for the teammate's answer: it
                // reads as their message, as on Desktop.
                if !running, let delivery, let reply = delivery.reply, let appState = rowActions?.appState {
                    TeammateMessageNote(
                        inbound: BotTeammateMessages.Inbound(
                            sender: teammateName(delivery.target),
                            handle: delivery.target,
                            body: reply
                        ),
                        roster: appState.botRoster,
                        appState: appState,
                        disclosureID: message.id + "#teammate-reply"
                    )
                    .padding(.bottom, 8)
                }
            }
            .chatStepCard(!grouped)
        }
    }
}

struct ToolCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    var grouped = false
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed: what a row shows comes from `rowState`.
    private var appState: AppState { rowActions.required }
    @Environment(\.sizeCategory) private var sizeCategory

    var body: some View {
        if rowState.displayPreferences.showToolProgress, message.tool != nil {
            SettledToolCardContent(
                message: message,
                label: ChatStepLabel(
                    toolName: message.tool?.name ?? "",
                    input: message.tool?.input,
                    catalog: rowState.toolCatalog
                ),
                expandToolsByDefault: rowState.displayPreferences.expandToolsByDefault,
                sizeCategory: sizeCategory,
                grouped: grouped,
                gatewayResolver: appState.gatewayMediaResolver
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
        return lines.prefix(maxLines).joined(separator: "\n") + AppLocalization.string("\n… (\(lines.count - maxLines) more lines)")
    }
}

/// One labeled block of a tool's raw input or result, in monospace.
private struct ToolRawTextSection: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.columnText) private var columnText
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(.caption2.bold())
                .foregroundStyle(.conduitTertiary)
            SelectableTextView(
                text: ToolCard.truncateForDisplay(text, maxLines: ToolResultPresentation.displayLineLimit),
                font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1, in: sizeCategory, from: columnText).pointSize, weight: .regular),
                textColor: .secondaryLabel,
                maximumNumberOfLines: 0
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Clarify Card

/// Where the visible question text lives on one clarification card. The
/// header always renders the returned text exactly once; rows render their
/// own titles only in a batch, so a single question is never title-less and
/// a batch summary is never duplicated.
enum ClarifyCardLayout {
    /// One question: the header carries the question itself and the row
    /// renders controls only — the exact legacy clarify card layout.
    case singleQuestion
    /// Several questions: the header summarizes once and every row carries
    /// its own question title.
    case batch

    init(questionCount: Int) {
        self = questionCount > 1 ? .batch : .singleQuestion
    }

    /// Text rendered in the card header beneath the status title.
    func headerText(for activity: ClarifyActivity) -> String {
        switch self {
        case .singleQuestion:
            return activity.questions.first?.question ?? ""
        case .batch:
            return AppLocalization.string("Hermes asked \(activity.questions.count) questions before it can continue")
        }
    }

    /// Whether a question row draws its own title line.
    var rowsShowTitles: Bool {
        switch self {
        case .singleQuestion: return false
        case .batch: return true
        }
    }
}

struct ClarifyCard: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.columnText) private var columnText
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed (`ChatRowState`).
    private var appState: AppState { rowActions.required }
    // Per-question draft state, keyed by the gateway qid: typed custom text
    // and in-progress picks (a multi-select's, or any form field's). Picks
    // intentionally buffer locally — an RPC fires only on that question's
    // confirm, or the form's Send.
    @State private var customAnswers: [String: String] = [:]
    @State private var multiSelections: [String: Set<String>] = [:]
    // A form's choice fields the user answers in their own words
    // ("Something else…").
    @State private var ownAnswerFields: Set<String> = []

    var body: some View {
        if let clarify = message.clarify {
            let layout = ClarifyCardLayout(questionCount: clarify.questions.count)
            let displayStatus = clarify.presentationStatus
            // Fields filled in and sent together (`isForm`), while any of
            // them still waits.
            let showsForm = clarify.isForm && clarify.hasPendingDecision
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.bubble")
                            .foregroundStyle(.orange)
                        CardHeaderCaption(timestamp: message.timestamp) {
                            Text(statusTitle(for: displayStatus))
                                .scaledFont(.caption2.weight(.bold))
                                .tracking(0.5)
                                .foregroundStyle(statusColor(for: displayStatus))
                        }
                        if displayStatus == .submitting {
                            ProgressView().controlSize(.small)
                        } else if displayStatus == .answered,
                                  clarify.questions.contains(where: { $0.answer != nil }) {
                            // Only an answer this device holds earns the check;
                            // an answered-elsewhere settle renders no checkmark so
                            // the header agrees with the body copy.
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    SelectableTextView(
                        text: layout.headerText(for: clarify),
                        font: .preferredFont(forTextStyle: .subheadline, in: sizeCategory, from: columnText).withTraits(.traitBold),
                        textColor: .label
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if showsForm {
                    Text("Fill in what you know, and leave the rest blank.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(clarify.questions) { question in
                    ClarifyQuestionRow(
                        question: question,
                        showsTitle: layout.rowsShowTitles,
                        isFormField: clarify.isForm,
                        customAnswer: bindingForCustomAnswer(question),
                        selection: bindingForSelection(question),
                        typesOwnAnswer: bindingForOwnAnswer(question),
                        onSend: { answer in send(answer, for: question, in: clarify) },
                        onConfirmMultiSelect: { confirmMultiSelect(for: question, in: clarify) }
                    )
                }

                if showsForm {
                    let canSend = canSendForm(clarify)
                    Button {
                        sendForm(clarify)
                    } label: {
                        HStack {
                            Text("Send")
                                .scaledFont(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "arrow.up")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.conduitAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.primary)
                    }
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.45)
                    .accessibilityHint("Fill in what you know, and leave the rest blank.")
                }

                if let error = clarify.error, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle")
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .chatCard(cornerRadius: 22, tint: .conduitAccent.opacity(0.08))
        }
    }

    private func bindingForCustomAnswer(_ question: ClarifyQuestion) -> Binding<String> {
        Binding(
            get: { customAnswers[question.id] ?? "" },
            set: { customAnswers[question.id] = $0 }
        )
    }

    private func bindingForSelection(_ question: ClarifyQuestion) -> Binding<Set<String>> {
        Binding(
            get: { multiSelections[question.id] ?? [] },
            set: { multiSelections[question.id] = $0 }
        )
    }

    private func bindingForOwnAnswer(_ question: ClarifyQuestion) -> Binding<Bool> {
        Binding(
            get: { ownAnswerFields.contains(question.id) },
            set: { typing in
                if typing {
                    ownAnswerFields.insert(question.id)
                } else {
                    ownAnswerFields.remove(question.id)
                }
            }
        )
    }

    private func send(_ answer: String, for question: ClarifyQuestion, in clarify: ClarifyActivity) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, question.isAnswerable else { return }
        // Keep the typed answer available if submission fails.
        Task { await appState.respondToClarify(requestId: clarify.requestId, questionId: question.id, answer: trimmed) }
    }

    /// What each open field of a form holds, by qid; empty when left blank.
    private func formAnswers(for clarify: ClarifyActivity) -> [String: String] {
        var answers: [String: String] = [:]
        for question in clarify.questions where question.isAnswerable {
            let typed = question.isFreeText || ownAnswerFields.contains(question.id)
                ? customAnswers[question.id] ?? ""
                : ""
            answers[question.id] = question.formAnswer(picked: multiSelections[question.id] ?? [], typed: typed)
        }
        return answers
    }

    /// A form sends once something in it is filled in, or once Hermes
    /// already has an answer from it (a retry where only blanks are left),
    /// and not while it is sending.
    private func canSendForm(_ clarify: ClarifyActivity) -> Bool {
        guard clarify.needsAnswer, !clarify.questions.contains(where: { $0.status == .submitting }) else { return false }
        return formAnswers(for: clarify).values.contains { !$0.isEmpty }
            || clarify.questions.contains { $0.status == .answered && !$0.isSkipped }
    }

    private func sendForm(_ clarify: ClarifyActivity) {
        guard canSendForm(clarify) else { return }
        // The fields keep what was typed if a question fails to send.
        let answers = formAnswers(for: clarify)
        Task { await appState.respondToClarifyForm(requestId: clarify.requestId, answers: answers) }
    }

    private func confirmMultiSelect(for question: ClarifyQuestion, in clarify: ClarifyActivity) {
        // Preserve the gateway's choice order rather than selection order.
        let values = question.choices.filter { multiSelections[question.id]?.contains($0.value) == true }
            .map(\.value)
        guard !values.isEmpty else { return }
        send(ClarifyQuestion.multiSelectAnswer(values), for: question, in: clarify)
    }

    private func statusTitle(for status: ClarifyActivity.Status) -> String {
        switch status {
        case .pending: return AppLocalization.string("NEEDS YOUR INPUT")
        case .submitting: return AppLocalization.string("SENDING ANSWER")
        case .answered: return AppLocalization.string("ANSWERED")
        case .error: return AppLocalization.string("TRY AGAIN")
        case .expired: return AppLocalization.string("EXPIRED")
        }
    }

    private func statusColor(for status: ClarifyActivity.Status) -> Color {
        switch status {
        case .pending, .submitting: return .orange
        case .answered: return .green
        case .error: return .red
        case .expired: return .secondary
        }
    }
}

/// One question inside a clarification card: single-choice buttons, genuine
/// multi-select toggles with a confirm step, or a free-text field. Each row
/// owns its answer/lock lifecycle — one question submitting or failing never
/// disables its siblings, and an accepted answer renders locked. In a batch
/// each row draws its own grouped box and title; a single-question card keeps
/// the legacy flat layout (the card header already carries the title). A
/// form's row is a field instead, sent with the card's one Send.
struct ClarifyQuestionRow: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.columnText) private var columnText
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let question: ClarifyQuestion
    var showsTitle: Bool = true
    /// A form's field (`ClarifyActivity.isForm`): a text box, or a menu of
    /// the choices, with no send of its own.
    var isFormField: Bool = false
    @Binding var customAnswer: String
    @Binding var selection: Set<String>
    /// A form's choice field the user answers in their own words.
    var typesOwnAnswer: Binding<Bool> = .constant(false)
    let onSend: (String) -> Void
    let onConfirmMultiSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                HStack(alignment: .top, spacing: 6) {
                    SelectableTextView(
                        text: question.question,
                        font: .preferredFont(forTextStyle: .subheadline, in: sizeCategory, from: columnText).withTraits(.traitBold),
                        textColor: .label
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    statusIcon
                }
            }
            // Without a title (single-question card) the card header already
            // carries the question text and the status title/icon.

            switch question.status {
            case .answered:
                answeredBlock
            case .expired:
                Text("No longer active")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            case .submitting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Locking your answer…")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            case .pending, .error:
                controls
                if let error = question.error, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle")
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(showsTitle ? 12 : 0)
        .background {
            if showsTitle {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch question.status {
        case .answered:
            // A field left blank says Skipped below instead.
            if !question.isSkipped {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(.caption)
                    .foregroundStyle(.green)
            }
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .scaledFont(.caption)
                .foregroundStyle(.red)
        case .expired:
            Image(systemName: "clock.badge.xmark")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        case .pending, .submitting:
            EmptyView()
        }
    }

    @ViewBuilder
    private var answeredBlock: some View {
        if question.isSkipped {
            // A form's field left blank: Hermes read it as skipped.
            Label(AppLocalization.string("Skipped"), systemImage: "forward")
                .scaledFont(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        } else if let answer = question.resolvedAnswer, !answer.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR ANSWER")
                    .scaledFont(.caption2.weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(.green)
                SelectableTextView(
                    text: answer,
                    font: .preferredFont(forTextStyle: .subheadline, in: sizeCategory, from: columnText),
                    textColor: .label
                )
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            // Answered elsewhere (relay 409): settled, but this device's
            // rejected text must not display as what Hermes received.
            Text("Answered on another device")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if isFormField {
            formField
        } else if question.multiSelect {
            multiSelectControls
        } else {
            singleChoiceControls
        }
    }

    /// A form's field: a text box for an open question, or a menu of the
    /// choices that also takes the user's own words. Nothing here sends;
    /// left alone, the field goes back blank.
    @ViewBuilder
    private var formField: some View {
        if question.isFreeText {
            formTextField
        } else {
            Menu {
                ForEach(question.choices) { choice in
                    Button {
                        pick(choice.value)
                    } label: {
                        if selection.contains(choice.value) {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                    // Several picks in one go.
                    .menuActionDismissBehavior(question.multiSelect ? .disabled : .automatic)
                }
                Divider()
                Button {
                    typeOwnAnswer()
                } label: {
                    if typesOwnAnswer.wrappedValue {
                        Label(AppLocalization.string("Something else…"), systemImage: "checkmark")
                    } else {
                        Text(AppLocalization.string("Something else…"))
                    }
                }
                if hasFormPick {
                    Button(AppLocalization.string("Leave blank")) {
                        leaveBlank()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(formMenuTitle)
                        .scaledFont(.body)
                        .foregroundStyle(hasFormPick ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.conduitAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(!isAnswerable)
            .accessibilityLabel(question.question)
            .accessibilityValue(formMenuTitle)

            if typesOwnAnswer.wrappedValue {
                formTextField
            }
        }
    }

    private var formTextField: some View {
        TextField(AppLocalization.string("Type your answer…"), text: $customAnswer, axis: .vertical)
            .lineLimit(1...4)
            .disabled(!isAnswerable)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            // Named by its question for VoiceOver, like a choice field's menu.
            .accessibilityLabel(question.question)
    }

    /// What a form's choice field shows: the picks, or Choose while blank.
    private var formMenuTitle: String {
        var parts = question.choices.filter { selection.contains($0.value) }.map(\.label)
        if typesOwnAnswer.wrappedValue {
            parts.append(AppLocalization.string("Something else…"))
        }
        return parts.isEmpty ? AppLocalization.string("Choose") : parts.joined(separator: ", ")
    }

    private var hasFormPick: Bool {
        !selection.isEmpty || typesOwnAnswer.wrappedValue
    }

    private func pick(_ value: String) {
        guard isAnswerable else { return }
        if question.multiSelect {
            toggle(value)
        } else {
            selection = [value]
            typesOwnAnswer.wrappedValue = false
        }
    }

    private func typeOwnAnswer() {
        guard isAnswerable else { return }
        if question.multiSelect {
            typesOwnAnswer.wrappedValue.toggle()
        } else {
            // One answer: the user's words take the pick's place.
            selection = []
            typesOwnAnswer.wrappedValue = true
        }
    }

    private func leaveBlank() {
        selection = []
        typesOwnAnswer.wrappedValue = false
        customAnswer = ""
    }

    @ViewBuilder
    private var singleChoiceControls: some View {
        ForEach(question.choices) { choice in
            Button {
                onSend(choice.value)
            } label: {
                HStack {
                    Text(choice.label)
                        .scaledFont(.body)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .scaledFont(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.conduitAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.primary)
            }
            .disabled(!isAnswerable)
        }

        HStack(spacing: 8) {
            TextField(
                question.choices.isEmpty ? AppLocalization.string("Type your answer…") : AppLocalization.string("Something else…"),
                text: $customAnswer,
                axis: .vertical
            )
            .lineLimit(1...4)
            .submitLabel(.send)
            .onSubmit { submitCustomAnswer() }
            .disabled(!isAnswerable)

            Button {
                submitCustomAnswer()
            } label: {
                Image(systemName: "arrow.up")
                    .scaledFont(.subheadline.weight(.bold))
                    .conduitFixedGlyph()
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("Send answer"))
            .foregroundStyle(.white)
            .background(Color.orange, in: Circle())
            .disabled(!canSubmitCustomAnswer)
            .opacity(canSubmitCustomAnswer ? 1 : 0.45)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var multiSelectControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(question.choices) { choice in
                Button {
                    toggle(choice.value)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selection.contains(choice.value) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(choice.value) ? Color.orange : Color.secondary)
                            .accessibilityHidden(true)
                        Text(choice.label)
                            .scaledFont(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Color.conduitAccent.opacity(selection.contains(choice.value) ? 0.2 : 0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isAnswerable)
                // VoiceOver announces "«choice», selected/not selected" from
                // one label + trait pair; the decorative checkmark image is
                // hidden so the state is never announced twice.
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(selection.contains(choice.value) ? .isSelected : [])
            }

            Button {
                onConfirmMultiSelect()
            } label: {
                HStack {
                    Text(confirmTitle)
                        .scaledFont(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.up")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.conduitAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.primary)
            }
            .disabled(selection.isEmpty || !isAnswerable)
            .opacity(selection.isEmpty || !isAnswerable ? 0.45 : 1)

            HStack(spacing: 8) {
                TextField(
                    "Or type a custom answer…",
                    text: $customAnswer,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .submitLabel(.send)
                .onSubmit { submitCustomAnswer() }
                .disabled(!isAnswerable)

                Button {
                    submitCustomAnswer()
                } label: {
                    Image(systemName: "arrow.up")
                        .scaledFont(.subheadline.weight(.bold))
                        .conduitFixedGlyph()
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Send answer"))
                .foregroundStyle(.white)
                .background(Color.orange, in: Circle())
                .disabled(!canSubmitCustomAnswer)
                .opacity(canSubmitCustomAnswer ? 1 : 0.45)
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var confirmTitle: String {
        selection.isEmpty ? AppLocalization.string("Select to confirm") : AppLocalization.string("Confirm \(selection.count) selected")
    }

    private var isAnswerable: Bool {
        question.isAnswerable
    }

    private var canSubmitCustomAnswer: Bool {
        isAnswerable && !customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toggle(_ value: String) {
        guard isAnswerable else { return }
        // Explicit copy-mutate-assign through the binding (a Binding<Set>'s
        // wrappedValue also supports in-place mutation, but the explicit form
        // makes the write-back unmistakable).
        var updated = selection
        if !updated.insert(value).inserted {
            updated.remove(value)
        }
        selection = updated
    }

    private func submitCustomAnswer() {
        guard canSubmitCustomAnswer else { return }
        onSend(customAnswer)
    }
}

// MARK: - Approval Card

/// An approval's command with every line reachable before Run: drawn in
/// full while it fits `maxHeight`, scrolled inside that height past it, so
/// one long heredoc can't make its chat row thousands of points tall. The
/// height is settled in the first layout pass, from a hidden copy of the
/// content measured at the offered width: no measure-then-shrink, so the
/// chat list never sees the row at full length.
struct ApprovalCommandBox<Content: View>: View {
    /// About this many lines show before the command scrolls.
    static var maxLines: CGFloat { 12 }

    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ApprovalCommandHeightLayout(maxHeight: maxHeight) {
            content()
                .hidden()
                .accessibilityHidden(true)
            ScrollView(.vertical) {
                content()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
        }
    }
}

/// Two subviews: the first is measured at the offered width with no height
/// limit, and the box takes that height up to `maxHeight`; the second (the
/// scroll view) is laid out in exactly that box.
private struct ApprovalCommandHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let natural = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
        subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

struct ApprovalCard: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.columnText) private var columnText
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed (`ChatRowState`).
    private var appState: AppState { rowActions.required }
    @State private var confirmAlways = false
    /// The approval as drawn when Always allow was tapped: the confirmation
    /// answers that one, even if the card changes while it is up.
    @State private var alwaysShown: ApprovalActivity?

    var body: some View {
        if let approval = message.approval {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(statusColor(for: approval.status))
                            .accessibilityHidden(true)
                        CardHeaderCaption(timestamp: message.timestamp) {
                            Text(statusTitle(for: approval.status))
                                .scaledFont(.caption2.weight(.bold))
                                .tracking(0.5)
                                .foregroundStyle(statusColor(for: approval.status))
                        }
                        if approval.status == .submitting {
                            ProgressView().controlSize(.small)
                        } else if approval.status == .approved || approval.status == .rejected {
                            Image(systemName: approval.status == .approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(statusColor(for: approval.status))
                        } else if approval.status == .expired {
                            Image(systemName: "clock.badge.xmark")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    SelectableTextView(
                        text: ApprovalDisplayText.revealingHidden(approval.description),
                        font: .preferredFont(forTextStyle: .subheadline, in: sizeCategory, from: columnText).withTraits(.traitBold),
                        textColor: .label
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !approval.command.isEmpty {
                    let commandFont = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1, in: sizeCategory, from: columnText).pointSize, weight: .regular)
                    ApprovalCommandBox(maxHeight: ApprovalCommandBox<EmptyView>.maxLines * commandFont.lineHeight) {
                        SelectableTextView(
                            text: ApprovalDisplayText.revealingHidden(approval.command),
                            font: commandFont,
                            textColor: .label
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                        .padding(12)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if approval.status == .approved || approval.status == .rejected {
                    let text = approval.choice.map { decisionTitle($0) } ?? statusTitle(for: approval.status)
                    Label(text, systemImage: approval.status == .approved ? "checkmark" : "xmark")
                        .scaledFont(.subheadline.weight(.medium))
                        .foregroundStyle(statusColor(for: approval.status))
                } else if approval.status == .expired {
                    let explanation = approval.error?.isEmpty == false
                        ? approval.error!
                        : AppLocalization.string("This approval is no longer active — Hermes timed it out and continued.")
                    // The gateway's text can carry the same hidden marks
                    // as the command.
                    Text(verbatim: ApprovalDisplayText.revealingHidden(explanation))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Longer translations (German, Russian, French) don't fit
                    // four buttons on one phone-width row, so the buttons fall
                    // back to two rows instead of truncating their titles.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            runButton(approval)
                            allowButtons(approval)
                            Spacer(minLength: 0)
                            rejectButton(approval)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                runButton(approval)
                                Spacer(minLength: 0)
                                rejectButton(approval)
                            }
                            if allows("session", for: approval) || allows("always", for: approval) {
                                HStack(spacing: 8) {
                                    allowButtons(approval)
                                }
                            }
                        }
                        // When even two per row don't fit (large text,
                        // narrow screens): one button per row.
                        VStack(alignment: .leading, spacing: 8) {
                            runButton(approval)
                            allowButtons(approval)
                            rejectButton(approval)
                        }
                    }
                    .scaledFont(.subheadline.weight(.medium))
                }

                if approval.status != .expired, let error = approval.error, !error.isEmpty {
                    Label(ApprovalDisplayText.revealingHidden(error), systemImage: "exclamationmark.circle")
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .chatCard(cornerRadius: 22, tint: statusColor(for: approval.status).opacity(0.08))
            .confirmationDialog(
                "Always allow this command?",
                isPresented: $confirmAlways,
                titleVisibility: .visible,
                presenting: alwaysShown
            ) { shown in
                Button("Always allow", role: .destructive) {
                    send("always", for: shown)
                }
            } message: { _ in
                Text("Hermes will save this approval pattern for future commands.")
            }
        }
    }

    private func runButton(_ approval: ApprovalActivity) -> some View {
        Button {
            send("once", for: approval)
        } label: {
            Label("Run", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!allows("once", for: approval) || !canRespond(approval.status))
    }

    @ViewBuilder
    private func allowButtons(_ approval: ApprovalActivity) -> some View {
        if allows("session", for: approval) {
            Button("Allow session") {
                send("session", for: approval)
            }
            .buttonStyle(.bordered)
            .disabled(!canRespond(approval.status))
        }

        if allows("always", for: approval) {
            Button("Always allow") {
                alwaysShown = approval
                confirmAlways = true
            }
            .buttonStyle(.bordered)
            .disabled(!canRespond(approval.status))
        }
    }

    private func rejectButton(_ approval: ApprovalActivity) -> some View {
        Button("Reject", role: .destructive) {
            send("deny", for: approval)
        }
        .buttonStyle(.bordered)
        .disabled(!allows("deny", for: approval) || !canRespond(approval.status))
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
        Task { await appState.respondToApproval(messageId: message.id, choice: choice, shown: approval) }
    }

    private func decisionTitle(_ choice: String) -> String {
        switch choice {
        case "once": return AppLocalization.string("Approved once")
        case "session": return AppLocalization.string("Approved for this session")
        case "always": return AppLocalization.string("Always allowed")
        case "deny": return AppLocalization.string("Rejected")
        default: return choice
        }
    }

    private func statusTitle(for status: ApprovalActivity.Status) -> String {
        switch status {
        case .pending: return AppLocalization.string("APPROVAL NEEDED")
        case .submitting: return AppLocalization.string("SENDING DECISION")
        case .approved: return AppLocalization.string("APPROVED")
        case .rejected: return AppLocalization.string("REJECTED")
        case .expired: return AppLocalization.string("EXPIRED")
        case .error: return AppLocalization.string("TRY AGAIN")
        }
    }

    private func statusColor(for status: ApprovalActivity.Status) -> Color {
        switch status {
        case .pending, .submitting: return .orange
        case .approved: return .green
        case .rejected, .expired, .error: return .red
        }
    }
}

/// Private-input prompt: a sudo password, a secret, a password-manager
/// unlock, a website's login or its one-time code. What the user types lives
/// only in this view's state: it is handed to AppState once on submit and
/// cleared, never stored on the message.
struct InputPromptCard: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.columnText) private var columnText
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed (`ChatRowState`).
    private var appState: AppState { rowActions.required }
    /// The typed secret. Deliberately view state only — never AppState, the
    /// message model or any cache — even though a lazy transcript can drop
    /// it if the row scrolls far away: retyping is the accepted cost of the
    /// value never outliving this card.
    @State private var value = ""
    /// vault.save_login: the account's email or username (the password is
    /// `value`). View state only, like `value`.
    @State private var identifier = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if let prompt = message.inputPrompt {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: prompt.kind))
                            .foregroundStyle(statusColor(for: prompt.status))
                            .accessibilityHidden(true)
                        CardHeaderCaption(timestamp: message.timestamp) {
                            Text(statusTitle(for: prompt.status))
                                .scaledFont(.caption2.weight(.bold))
                                .tracking(0.5)
                                .foregroundStyle(statusColor(for: prompt.status))
                        }
                        if prompt.status == .submitting {
                            ProgressView().controlSize(.small)
                        } else if prompt.status == .expired {
                            Image(systemName: "clock.badge.xmark")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(prompt.title)
                        .scaledFont(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let note = explanation(for: prompt) {
                    Text(note)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let detail = detail(for: prompt), !detail.isEmpty {
                    SelectableTextView(
                        text: detail,
                        font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1, in: sizeCategory, from: columnText).pointSize, weight: .regular),
                        textColor: .label,
                        maximumNumberOfLines: 5
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                switch prompt.status {
                case .submitted:
                    Label(AppLocalization.string("Sent"), systemImage: "checkmark")
                        .scaledFont(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                case .skipped:
                    Label(AppLocalization.string("Skipped"), systemImage: "forward")
                        .scaledFont(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                case .expired:
                    Text(prompt.error.flatMap { $0.isEmpty ? nil : $0 }
                         ?? AppLocalization.string("This request is no longer active."))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                case .pending, .submitting, .error:
                    fields(for: prompt)

                    HStack(spacing: 8) {
                        Button {
                            submit(prompt)
                        } label: {
                            Label(sendTitle(for: prompt.kind), systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!prompt.isAnswerable || answer(for: prompt) == nil)

                        Spacer(minLength: 0)

                        Button(skipTitle(for: prompt.kind)) {
                            skip(prompt)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!prompt.isAnswerable)
                    }
                    .scaledFont(.subheadline.weight(.medium))
                }

                if prompt.status == .error, let error = prompt.error, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle")
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .chatCard(cornerRadius: 22, tint: statusColor(for: prompt.status).opacity(0.08))
            .onChange(of: prompt.status) { _, status in
                // Drop the typed value once the request is settled either
                // way. A failed send (.error) keeps it so the user can retry
                // without retyping; it never leaves this view's state.
                if status == .submitted || status == .skipped || status == .expired {
                    value = ""
                    identifier = ""
                }
            }
        }
    }

    @ViewBuilder
    private func fields(for prompt: InputPromptActivity) -> some View {
        switch prompt.kind {
        case .vaultSaveLogin:
            // No .username / .password content types: once the card
            // settles, iOS would offer to save the site's login to the
            // keychain under Conduit's own domain.
            TextField(AppLocalization.string("Email or username"), text: $identifier)
                .privacySensitive()
                .accessibilityHint(AppLocalization.string("Save & sign in gives Hermes this login for the site. The model never sees the password."))
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit { fieldFocused = true }
                .inputPromptField()
                .disabled(!prompt.isAnswerable)
            SecureField(placeholder(for: prompt.kind), text: $value)
                .accessibilityHint(AppLocalization.string("Save & sign in gives Hermes this login for the site. The model never sees the password."))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit { submit(prompt) }
                .inputPromptField()
                .disabled(!prompt.isAnswerable)
        case .vaultCode:
            // Shown as typed, like Hermes Desktop: a short code is not worth
            // masking and a typo must be visible. .oneTimeCode offers the
            // code a text message or email just brought; letters come first
            // because an email's code can have them.
            TextField(placeholder(for: prompt.kind), text: $value)
                .accessibilityHint(AppLocalization.string("Enter code has Hermes type it into the page. The model never sees it."))
                .privacySensitive()
                .textContentType(.oneTimeCode)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit { submit(prompt) }
                .inputPromptField()
                .disabled(!prompt.isAnswerable)
        case .sudo, .secret, .vaultUnlock:
            // No .textContentType(.password): it would offer to save
            // a sudo or password-manager master password to the
            // system keychain.
            SecureField(placeholder(for: prompt.kind), text: $value)
                .accessibilityHint(AppLocalization.string("Send gives Hermes this value. Skip lets it continue without one."))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit { submit(prompt) }
                .inputPromptField()
                .disabled(!prompt.isAnswerable)
        }
    }

    private func submit(_ prompt: InputPromptActivity) {
        guard prompt.isAnswerable, let answer = answer(for: prompt) else { return }
        fieldFocused = false
        Task { await appState.respondToInputPrompt(messageId: message.id, value: answer) }
    }

    /// What Send gives Hermes, or nil while there is nothing to send.
    private func answer(for prompt: InputPromptActivity) -> String? {
        switch prompt.kind {
        case .vaultSaveLogin:
            return InputPromptActivity.loginAnswer(identifier: identifier, password: value)
        case .vaultCode:
            let code = InputPromptActivity.codeAnswer(value)
            return code.isEmpty ? nil : code
        case .sudo, .secret, .vaultUnlock:
            // Sent untrimmed: a password may legitimately contain spaces.
            return hasValue ? value : nil
        }
    }

    /// Whitespace alone is not an answer (Hermes would store it as the
    /// secret); only a real value enables Send. Deliberate trade-off: an
    /// all-space password cannot be entered here, while one merely
    /// containing spaces is sent untrimmed.
    private var hasValue: Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func skip(_ prompt: InputPromptActivity) {
        guard prompt.isAnswerable else { return }
        value = ""
        identifier = ""
        fieldFocused = false
        Task { await appState.respondToInputPrompt(messageId: message.id, value: nil) }
    }

    private func detail(for prompt: InputPromptActivity) -> String? {
        switch prompt.kind {
        case .sudo: return prompt.command
        case .secret: return prompt.envVar
        case .vaultUnlock, .vaultCode: return nil
        // The exact origin, so the user sees which site gets the login.
        case .vaultSaveLogin: return prompt.origin
        }
    }

    private func explanation(for prompt: InputPromptActivity) -> String? {
        switch prompt.kind {
        case .vaultSaveLogin:
            return AppLocalization.string("Hermes reached this sign-in page and has no login for it. It's saved encrypted where Hermes runs and filled into the page; the model never sees the password.")
        case .vaultCode:
            return AppLocalization.string("The site is asking for a one-time code from a text message, email or authenticator app. Hermes types it into the page; the model never sees it.")
        case .sudo, .secret, .vaultUnlock:
            return nil
        }
    }

    private func iconName(for kind: InputPromptActivity.Kind) -> String {
        switch kind {
        case .sudo: return "lock.shield"
        case .secret: return "key"
        case .vaultUnlock: return "lock.rectangle.stack"
        case .vaultSaveLogin: return "person.badge.key"
        case .vaultCode: return "number"
        }
    }

    private func placeholder(for kind: InputPromptActivity.Kind) -> String {
        switch kind {
        case .sudo: return AppLocalization.string("sudo password")
        case .secret: return AppLocalization.string("Secret value")
        case .vaultUnlock: return AppLocalization.string("Master password")
        case .vaultSaveLogin: return AppLocalization.string("Password")
        // Not "Code": some languages read that key as program code.
        case .vaultCode: return AppLocalization.string("Verification code")
        }
    }

    private func sendTitle(for kind: InputPromptActivity.Kind) -> String {
        switch kind {
        case .vaultSaveLogin: return AppLocalization.string("Save & sign in")
        case .vaultCode: return AppLocalization.string("Enter code")
        case .sudo, .secret, .vaultUnlock: return AppLocalization.string("Send")
        }
    }

    private func skipTitle(for kind: InputPromptActivity.Kind) -> String {
        switch kind {
        case .vaultSaveLogin: return AppLocalization.string("Don't save")
        case .sudo, .secret, .vaultUnlock, .vaultCode: return AppLocalization.string("Skip")
        }
    }

    private func statusTitle(for status: InputPromptActivity.Status) -> String {
        switch status {
        case .pending: return AppLocalization.string("INPUT NEEDED")
        case .submitting: return AppLocalization.string("SENDING")
        case .submitted: return AppLocalization.string("SENT")
        case .skipped: return AppLocalization.string("SKIPPED")
        case .expired: return AppLocalization.string("EXPIRED")
        case .error: return AppLocalization.string("TRY AGAIN")
        }
    }

    private func statusColor(for status: InputPromptActivity.Status) -> Color {
        switch status {
        case .pending, .submitting: return .orange
        case .submitted: return .green
        case .skipped: return .secondary
        case .expired, .error: return .red
        }
    }
}

private extension View {
    /// The input card's field well.
    func inputPromptField() -> some View {
        padding(10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Live Turn Rows

/// The running turn's live tail at the end of the transcript: the open
/// thinking card, the streaming reply, or the working indicator. It observes
/// `LiveTurnProjection` directly, which publishes at streaming cadence, so
/// those ticks stop here instead of re-running ChatView's body. The rows sit
/// in the transcript's LazyVStack as its own children, as they did inline.
struct ChatLiveTurnRows: View {
    @ObservedObject var projection: LiveTurnProjection
    let isBusy: Bool
    let author: String
    /// The tool running now, named on the working line.
    var currentToolName: String?
    /// Its input, for a batch's names.
    var currentToolInput: String?
    /// Its own words for it, when it has them ("Messaging Atlas…").
    var currentToolTitle: String?
    /// When the turn began, for the working line's timer.
    var turnStartedAt: Date?
    /// Another device is getting this chat's reply.
    var repliesElsewhere = false

    var body: some View {
        // Live reasoning renders from the projection, not the settled
        // transcript: per-publish reasoning changes re-render only this
        // card, never the ForEach data or the scroll-target cache.
        // Chronology matches the pre-projection transcript — thinking
        // streams at the tail, before the assistant answer.
        if let segment = projection.reasoningSegment {
            ThinkingCard(
                message: ChatMessage(
                    id: segment.id,
                    role: .reasoning,
                    content: segment.content,
                    timestamp: segment.timestamp,
                    author: author
                )
            )
            .id(segment.id)
            .reportsLiveRowFrame(id: segment.id)
        }

        if !projection.streamingText.isEmpty {
            StreamingBubble(
                text: projection.streamingText,
                active: isBusy
            )
            .id("streaming")
            .reportsLiveRowFrame(id: "streaming")
        }

        if (isBusy && projection.streamingText.isEmpty) || repliesElsewhere {
            ChatWorkingLine(
                currentToolName: currentToolName,
                currentToolInput: currentToolInput,
                currentToolTitle: currentToolTitle,
                isThinking: projection.reasoningSegment != nil,
                startedAt: turnStartedAt,
                repliesElsewhere: repliesElsewhere
            )
            .id("typing")
            .reportsLiveRowFrame(id: "typing")
        }
    }
}

// MARK: - Streaming Bubble

struct StreamingBubble: View {
    let text: String
    let active: Bool
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowActions) private var rowActions
    /// Acted on, not observed: what a row shows comes from `rowState`.
    private var appState: AppState { rowActions.required }

    var body: some View {
        let identity = rowState.agentIdentity
        return VStack(alignment: .leading, spacing: 6) {
            // Streaming uses the same reading column and Markdown renderer as
            // a completed reply. Only the active mark/status changes, so the
            // final message settles in rather than swapping presentation.
            HStack(spacing: 8) {
                ConduitAgentMark(
                    isActive: true,
                    identity: identity
                )

                Text(identity.name)
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(active ? AppLocalization.string("Responding") : AppLocalization.string("Finishing"))
                    .scaledFont(.caption2.weight(.medium))
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
                    await appState.gatewayMediaDataURL(for: path, profile: rowState.activeProfile)
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Empty State

/// A New Chat Hermes hasn't created yet, drawn as the live transcript draws
/// an empty chat, so the real one takes its place without a jump.
private struct PendingNewChatView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.v2ComposerRests) private var composerFloats

    var body: some View {
        ScrollView {
            LazyVStack(spacing: ChatStepStyle.transcriptRowSpacing) {
                Color.clear
                    .frame(height: 1)
                // A message sent before Hermes created the chat waits in it.
                if let pending = appState.pendingComposerSendOnScreen {
                    PendingComposerSendBubble(pending: pending)
                } else {
                    EmptyChatState().padding(.top, 60)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
        }
        .modifier(V2SoftTopScrollEdge(isOn: composerFloats, underChatHeader: true))
        .accessibilityIdentifier("pending-new-chat")
    }
}

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
                    .scaledFont(.title3.weight(.semibold))
                Text("Conduit is ready when you are.")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .conduitGlassSurface(cornerRadius: 28, tint: .conduitAccent.opacity(0.06))
    }
}
struct ConduitAgentMark: View {
    var isActive = false
    /// Required on purpose: a call site that forgets it would render a
    /// workspace face inside a Bot Chat — the very bug this type exists to
    /// prevent — so the compiler catches the omission.
    let identity: ConversationAgentIdentity
    /// The ring and breath color: the profile's glow, else the gold accent.
    var glow: Color?

    /// One breath in and out: 1.1 s each way, eased at both ends.
    static let breathDuration: TimeInterval = 2.2
    /// The mark breathes for the whole turn, redrawing its glow each frame.
    /// A forever animation runs at the display's rate; 30 fps looks the same
    /// on a 30 pt avatar at half the frames or less.
    static let breathingFramesPerSecond: Double = 30

    /// 0 at rest, 1 at the full breath.
    static func breath(at elapsed: TimeInterval) -> CGFloat {
        CGFloat((1 - cos(2 * .pi * elapsed / breathDuration)) / 2)
    }

    var body: some View {
        if isActive {
            ConduitBreathing { breath in
                mark
                    .shadow(color: (glow ?? .conduitAccent).opacity(0.42), radius: 3 + 6 * breath)
                    .scaleEffect(1 + 0.06 * breath)
            }
        } else {
            // At rest the glow is invisible, so there's no shadow to draw:
            // this mark heads every answer in the chat.
            mark
        }
    }

    private var mark: some View {
        face
            .overlay {
                Circle()
                    .strokeBorder((glow ?? .conduitAccent).opacity(isActive ? 0.52 : 0.22), lineWidth: 1)
            }
    }

    /// Same size as ProfileAvatarView's default face (one shared constant);
    /// the bot face sizes itself to it.
    private static let faceSize: CGFloat = ProfileAvatarView.defaultSize

    /// A Bot Chat's agent wears the roster's own face — `BotAvatarView`, the
    /// one definition of the initial-on-color recipe, so the face's styling
    /// can never drift from the Bots tab (the initial keeps the captured
    /// label by design); ordinary conversations keep ProfileAvatarView's
    /// photo-or-gold-monogram.
    @ViewBuilder
    private var face: some View {
        if let botFace = identity.botFace {
            BotAvatarView(
                name: botFace.name,
                label: identity.name,
                colorString: botFace.colorString,
                image: botFace.image,
                size: Self.faceSize
            )
        } else {
            ProfileAvatarView(profile: "", displayName: identity.name, url: identity.photoURL)
        }
    }
}

/// Breathes under the backdrop's rules: only while the app is active, and
/// not with Reduce Motion, in Low Power Mode or while the phone runs hot.
/// Each start (a new turn, or coming back to the app) begins at rest.
private struct ConduitBreathing<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var devicePower = DevicePowerState.shared
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        if ConduitBackdropMotionPolicy.shouldAnimate(
            drifts: true,
            sceneIsActive: scenePhase == .active,
            reduceMotion: reduceMotion,
            lowPowerMode: devicePower.isLowPowerModeEnabled,
            // It breathes only while the chat shows work in progress (a
            // turn, or compacting), never on an idle screen left alone, so
            // the backdrop's idle pause doesn't apply.
            idle: false,
            thermalState: devicePower.thermalState
        ) {
            ConduitBreathingTimeline(content: content)
        } else {
            content(0)
        }
    }
}

/// Drives a breath from the moment it appears, so each turn's breathing
/// starts at rest. Timed by system uptime like the backdrop, so a clock
/// change mid-turn can't jump the phase.
private struct ConduitBreathingTimeline<Content: View>: View {
    @State private var startedAt = ProcessInfo.processInfo.systemUptime
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / ConduitAgentMark.breathingFramesPerSecond)) { _ in
            content(ConduitAgentMark.breath(at: ProcessInfo.processInfo.systemUptime - startedAt))
        }
    }
}

/// V2 (iOS 26): the transcript (or a pushed page's list) fades out under the
/// header instead of the navigation bar's edge ending it at a line.
/// A chat's transcript (`underChatHeader`) fades out under the chat's header
/// before iOS 26 too: its text turns transparent across the navigation bar,
/// as under a bar's fade (`V2LegacyEdgeBar`), rather than a material
/// drawn behind the header.
struct V2SoftTopScrollEdge: ViewModifier {
    let isOn: Bool
    var underChatHeader = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if isOn {
                content.scrollEdgeEffectStyle(.soft, for: .top)
            } else {
                content
            }
        } else {
            if isOn && underChatHeader {
                content.mask { headerFade }
            } else {
                content
            }
        }
    }

    /// Opaque below the navigation bar, fading out to clear across it.
    private var headerFade: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.15), location: 0.45),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.safeAreaInsets.top)
                Color.black
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// A card inside the transcript (a question, an approval, a call): a
    /// faint fill in its tint with a hairline, like the settings cards. Not
    /// glass: glass redraws what is behind it on every frame the content
    /// under it moves, so each glass card cost a redraw per frame of scroll.
    func chatCard(cornerRadius: CGFloat, tint: Color = .clear) -> some View {
        background(tint, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .settingsCard(cornerRadius: cornerRadius)
    }
}
