import Foundation

enum ChatViewportMode: Equatable {
    case followingLatest
    case browsing
    case restoring
    case explicitTop(request: Int)
    case transitioning
}

/// A scroll command stamped with the ownership generation and session scope
/// at issue time. Delayed retries re-validate through
/// `ChatViewportController.isCommandCurrent`; anything that changed
/// ownership since issuance silently kills the command.
struct ChatViewportCommand: Equatable {
    enum Destination: Equatable {
        case bottom(anchorID: String)
        case top(anchorID: String, request: Int)
        case message(id: String)
    }

    enum Retry: Equatable {
        case delayed(milliseconds: Int)
    }

    let generation: UInt64
    let sessionKey: ChatScrollSessionKey?
    let destination: Destination
    let animated: Bool
    let retry: Retry?
}

enum ChatViewportEffect: Equatable {
    case scroll(ChatViewportCommand)
    case cancelAutomaticRestoration
    case persistViewportSnapshot(for: ChatScrollSessionKey?)
    case flushViewportPersistence
    case completeRestoration(generation: UInt64)
    case abandonRestoration(generation: UInt64)
    case scheduleDragEvaluation(ChatDragCompletionToken)
    /// One coalesced bottom-follow correction is outstanding; the view
    /// executes it on a later MainActor turn (see
    /// ChatViewportController.followCorrectionDue).
    case scheduleFollowCorrection(ChatFollowCorrectionToken)
}

/// Identity of one outstanding coalesced follow correction: the ownership
/// generation, the session it was scheduled under, and a per-schedule
/// sequence number. A correction that comes due after ownership moved on
/// (drag, restoration, handoff, session switch) re-validates against this
/// token and dies silently.
///
/// The sequence number makes every scheduled correction Equatable-distinct
/// even within one ownership generation and session. The view drains
/// corrections through onChange(of: pendingFollowCorrection); two
/// consecutive corrections with equal tokens would be observed as
/// "token A -> token A", which SwiftUI is free to skip — leaving a pending
/// correction nobody executes. The monotonic counter guarantees the
/// nil -> token -> nil -> token-prime transitions always differ.
struct ChatFollowCorrectionToken: Equatable {
    let generation: UInt64
    let sessionKey: ChatScrollSessionKey?
    let sequence: UInt64
}

struct ChatViewportLayoutFacts: Equatable {
    var bottomMarkerMaxY: CGFloat?
    var viewportMinY: CGFloat?
    var viewportMaxY: CGFloat?
    /// Latest global frames of rendered stable rows (retained by the view
    /// across ticks; only rows SwiftUI laid out are present).
    var rowFrames: [ChatRenderedRowFrame]
    var renderedScope: ChatRenderedScrollScope?
    /// When these facts were measured (view-supplied clock stamp, e.g.
    /// CFAbsoluteTimeGetCurrent). Pure input like every other fact: tests
    /// pass synthetic monotonic stamps. Used to rate-limit follow-
    /// correction RE-ARMING after a correction executed — the correction's
    /// own scroll shifts every global frame, and a schedule minted from
    /// that flap (observed 3 ms after execution) is both spurious and
    /// undrainable: it is born inside the drain handler's layout turn,
    /// where SwiftUI may never deliver the onChange that would execute it,
    /// leaving a pending token that silently absorbs all future schedules.
    var timestamp: TimeInterval = 0
}

struct ChatViewportHandoffState: Equatable {
    var sessionKey: ChatScrollSessionKey?
    var hasMeasuredLayout = false

    init(sessionKey: ChatScrollSessionKey?, hasMeasuredLayout: Bool = false) {
        self.sessionKey = sessionKey
        self.hasMeasuredLayout = hasMeasuredLayout
    }
}

/// The single authority over the chat viewport. Pure and deterministic:
/// consumes facts/events, emits effects for the view's single scroll
/// executor. Folds the semantics of ChatScrollOwnerState,
/// ChatDragLifecycleState, ChatFollowLatestRelatchPolicy,
/// ChatMessageScrollUpdatePolicy, and the notification-handoff booleans
/// under ONE ownership generation. Never touches ScrollViewProxy, UIKit,
/// or clocks.
struct ChatViewportController: Equatable {
    private(set) var mode: ChatViewportMode = .followingLatest
    private(set) var generation: UInt64 = 1

    // Identity facts (fed by the view's onChange pipeline).
    private(set) var identity: ChatScrollSessionIdentity = .none
    private(set) var renderedSessionKey: ChatScrollSessionKey?
    private(set) var activeSessionKey: ChatScrollSessionKey?
    private var mirroredViewportTransitionGeneration: UInt64 = 0
    private(set) var renderedTranscriptRevision: UInt64 = 0

    // Transcript facts.
    private(set) var targetCache = ChatMessageScrollTargetCache()
    var targets: [ChatMessageScrollTarget] { targetCache.targets }

    // Layout facts.
    private(set) var bottomMarkerMaxY: CGFloat?
    private(set) var viewportMinY: CGFloat?
    private(set) var viewportMaxY: CGFloat?
    /// First stable (message) row intersecting the viewport, in target
    /// order. Streaming/typing/marker rows never report frames, so
    /// ephemeral identifiers cannot leak into this value.
    private(set) var stableTopMessageID: String?

    // Sub-states (folded ownership systems).
    private var drag = DragLifecycle()
    private var dragGestureActive = false
    private(set) var pendingDragEvaluation: ChatDragCompletionToken?
    /// The single outstanding coalesced follow correction, if any (see
    /// layoutMetricsChanged). At most one exists per unsettled layout
    /// cycle: geometry ticks arriving while one is pending update the
    /// recorded facts but never enqueue a second correction.
    private(set) var pendingFollowCorrection: ChatFollowCorrectionToken?
    /// Monotonic per-schedule discriminator for follow-correction tokens
    /// (wraps like every counter in this type, via &+). Only incremented
    /// when a NEW correction is actually scheduled — duplicate geometry
    /// ticks while one is pending never mint tokens.
    private var followCorrectionSequence: UInt64 = 0
    /// Clock stamp of the most recently recorded layout facts (pure input;
    /// see ChatViewportLayoutFacts.timestamp).
    private var latestFactTimestamp: TimeInterval = 0
    /// Clock stamp of the facts the last executed follow correction scrolled
    /// against. New corrections may not RE-ARM within
    /// followCorrectionRearmInterval of an execution: the correction's own
    /// scroll commit shifts every global frame, and a schedule minted from
    /// that immediate flap both is spurious and can be undrainable (born
    /// inside the drain handler's layout turn, SwiftUI may skip the
    /// onChange delivery — observed live: seq=2 stuck pending forever,
    /// silently absorbing every later schedule).
    private var followCorrectionLastExecutionAt: TimeInterval?

    /// Minimum time after a correction executed before another may arm.
    /// Long enough for the correction's scroll commit to settle global
    /// frames; short enough that genuine streaming growth (bounded already
    /// by the 12 pt regrowth floor) is followed promptly.
    static let followCorrectionRearmInterval: TimeInterval = 0.1
    /// Content bottom (bottomMarkerMaxY) the last scheduled correction ran
    /// against. A correction re-arms only when the content bottom has
    /// MOVED since — a drift that persists with UNCHANGED content (the
    /// scroll already sits at the anchor's bottom; scrollTo cannot reduce
    /// the residual) must not re-arm a correction every MainActor turn, or
    /// the correction itself becomes the layout-churn source it exists to
    /// prevent.
    private var followCorrectionContentBottom: CGFloat?
    private(set) var notificationHandoff: ChatViewportHandoffState?
    private(set) var restoration: RestorationState?

    let nearBottomTolerance: CGFloat
    let followDriftTolerance: CGFloat

    init(nearBottomTolerance: CGFloat = 40, followDriftTolerance: CGFloat = 0.5) {
        self.nearBottomTolerance = nearBottomTolerance
        self.followDriftTolerance = followDriftTolerance
    }

    // MARK: - Derived facts

    var isFollowingLatest: Bool { mode == .followingLatest }

    var restorationIsActive: Bool { restoration != nil && mode == .restoring }

    var isNearBottom: Bool {
        guard let bottomMarkerMaxY, let viewportMaxY else { return true }
        return bottomMarkerMaxY <= viewportMaxY + nearBottomTolerance
    }

    /// The scope the view embeds into rendered-scroll preferences; keeps the
    /// AppState settle handshake fed with the same mirrored facts the old
    /// ChatView @State provided.
    var renderedScrollScope: ChatRenderedScrollScope? {
        renderedSessionKey.map { key in
            ChatRenderedScrollScope(
                sessionKey: key,
                cacheRevision: targetCache.renderingRevision,
                restorationGeneration: restoration?.request.generation,
                transcriptRevision: renderedTranscriptRevision,
                viewportTransitionGeneration: mirroredViewportTransitionGeneration
            )
        }
    }

    var notificationHandoffAwaitingLayout: Bool {
        notificationHandoff.map { !$0.hasMeasuredLayout } ?? false
    }

    // MARK: - Session identity & transitions

    /// Ports the old onChange(activeSessionId) / onChange(activeProfile)
    /// handlers. `viaNotification: true` is the notification-handoff branch:
    /// decisions freeze until the destination transcript has measured its
    /// own layout.
    mutating func renderedSessionChanged(
        to key: ChatScrollSessionKey?,
        identity: ChatScrollSessionIdentity,
        viaNotification: Bool,
        viewportTransitionGeneration: UInt64,
        resetsTranscriptCache: Bool = false
    ) -> [ChatViewportEffect] {
        self.identity = identity
        activeSessionKey = key
        var effects: [ChatViewportEffect] = []
        let wasFollowing = mode == .followingLatest

        if viaNotification {
            if notificationHandoff == nil {
                notificationHandoff = ChatViewportHandoffState(sessionKey: key)
                effects.append(contentsOf: beginHandoffOwnership())
            } else if notificationHandoff?.sessionKey == nil {
                // The opening flag arrived before the destination session
                // did; adopt it now.
                notificationHandoff?.sessionKey = key
            }
            renderedSessionKey = key
            if wasFollowing {
                mirroredViewportTransitionGeneration = viewportTransitionGeneration
            }
            mode = .transitioning
            return effects
        }

        // Cancel a pending restoration that belongs to a different
        // conversation (checked before the equivalence early-return, exactly
        // like the old handler). This runs BEFORE the nil→nil guard below:
        // a session-less re-appear must still clean up a stale restoration
        // from a previous conversation.
        if let request = restoration?.request,
           !identity.areEquivalent(request.sessionKey, key) {
            restoration = nil
            effects.append(.cancelAutomaticRestoration)
        }

        // A nil → nil "change" is not a session switch — there is no
        // session on either side. areEquivalent(nil, nil) is false by
        // definition, so without this guard the first appearance of a
        // session-less transcript took the full switch path (generation
        // bump, drag invalidation, animated bottom scroll with a delayed
        // retry). That in-flight animation crossed the whole transcript and
        // fought the coalesced follow corrections; a session-less appear
        // has nothing to switch away from.
        if renderedSessionKey == nil, key == nil {
            if wasFollowing {
                mirroredViewportTransitionGeneration = viewportTransitionGeneration
            }
            return effects
        }

        let oldKey = renderedSessionKey
        let keysAreEquivalent = identity.areEquivalent(oldKey, key)

        // Adopting the first-ever session key is an adoption, not a switch:
        // the old view assigned it in onAppear without scrolling. The
        // correction-owning session nonetheless CHANGED (nil → key): a
        // correction scheduled before any session existed must not fire a
        // command anchored to the newly adopted session.
        let isFirstAdoption = oldKey == nil && key != nil
        if isFirstAdoption {
            renderedSessionKey = key
            pendingFollowCorrection = nil
            followCorrectionContentBottom = nil
        followCorrectionLastExecutionAt = nil
            if wasFollowing {
                mirroredViewportTransitionGeneration = viewportTransitionGeneration
            }
            return effects
        }

        if !keysAreEquivalent {
            effects.append(contentsOf: invalidateDrag(hasActiveGesture: dragGestureActive))
            generation &+= 1
            pendingFollowCorrection = nil
            followCorrectionContentBottom = nil
        followCorrectionLastExecutionAt = nil
        }
        renderedSessionKey = key
        if wasFollowing {
            mirroredViewportTransitionGeneration = viewportTransitionGeneration
        }
        guard !keysAreEquivalent else { return effects }

        if resetsTranscriptCache {
            targetCache = ChatMessageScrollTargetCache()
        }
        stableTopMessageID = nil
        // Ports ChatFollowLatestRelatchPolicy.shouldFollowLatestAfterTransition.
        let shouldFollowLatest = !dragGestureActive
        mode = shouldFollowLatest ? .followingLatest : .browsing
        if shouldFollowLatest {
            effects.append(.scroll(latestCommand(animated: true)))
        }
        return effects
    }

    /// Ports onChange(activeChatScrollSessionIdentity): adopt the canonical
    /// key spelling when it names the same conversation.
    mutating func activeIdentityRefreshed(
        identity: ChatScrollSessionIdentity,
        key: ChatScrollSessionKey?
    ) -> [ChatViewportEffect] {
        self.identity = identity
        activeSessionKey = key ?? activeSessionKey
        guard notificationHandoff == nil else { return [] }
        if let key, identity.areEquivalent(renderedSessionKey, key) {
            renderedSessionKey = key
        }
        return []
    }

    // MARK: - Transcript changes

    /// Ports the old onChange(messages) reassert policy: cache + revision
    /// mirrors always update; the animated latest reassert fires only while
    /// following with no restoration/handoff in flight.
    /// `activeSessionKey` and `isOpeningNotificationSession` are read
    /// synchronously from AppState at event time so suppression does not
    /// depend on which SwiftUI onChange observer happens to fire first: a
    /// transcript change that lands before the handoff/session observer
    /// still sees the handoff underway and stays inert.
    mutating func transcriptChanged(
        messages: [ChatMessage],
        transcriptRevision: UInt64,
        viewportTransitionGeneration: UInt64,
        isInitialSync: Bool = false,
        activeSessionKey: ChatScrollSessionKey? = nil,
        isOpeningNotificationSession: Bool = false
    ) -> [ChatViewportEffect] {
        TranscriptPerf.note(.transcriptChanged)
        if let activeSessionKey {
            self.activeSessionKey = activeSessionKey
        }
        let update = targetCache.update(for: messages)
        renderedTranscriptRevision = transcriptRevision
        mirroredViewportTransitionGeneration = viewportTransitionGeneration
        guard !isInitialSync,
              update != .unchanged,
              mode == .followingLatest,
              restoration == nil,
              notificationHandoff == nil,
              !isOpeningNotificationSession else { return [] }
        // The animated reassert owns the follow for this change (it carries
        // its own delayed retry); a coalesced correction pending from an
        // earlier drift tick would only fight the in-flight animation.
        pendingFollowCorrection = nil
        followCorrectionContentBottom = nil
        followCorrectionLastExecutionAt = nil
        return [.scroll(latestCommand(animated: true))]
    }

    // MARK: - Layout facts

    /// Geometry reports facts; this is the ONLY place layout input can
    /// change ownership (relatch), and it can never issue a scroll on the
    /// same tick it relatches (ports relatchFollowsLatestIfSettled +
    /// rendered-growth following).
    mutating func layoutMetricsChanged(
        facts: ChatViewportLayoutFacts
    ) -> [ChatViewportEffect] {
        TranscriptPerf.note(.layoutMetricsChanged)
        bottomMarkerMaxY = facts.bottomMarkerMaxY
        viewportMinY = facts.viewportMinY
        viewportMaxY = facts.viewportMaxY
        latestFactTimestamp = facts.timestamp

        let previousStableTop = stableTopMessageID
        updateStableTopMessage(rowFrames: facts.rowFrames)

        var effects: [ChatViewportEffect] = []
        if stableTopMessageID != previousStableTop {
            effects.append(.persistViewportSnapshot(for: renderedSessionKey))
        }

        var relatchedThisTick = false
        if case .explicitTop = mode, isNearBottom, !dragGestureActive {
            // A title tap pins the viewport near the top; once the user
            // returns near the bottom, hand ownership back to latest so
            // auto-follow resumes.
            generation &+= 1
            mode = .followingLatest
            relatchedThisTick = true
        } else if mode == .browsing,
                  isNearBottom,
                  restoration == nil,
                  notificationHandoff == nil,
                  !dragGestureActive {
            mode = .followingLatest
            relatchedThisTick = true
        }
        if relatchedThisTick {
            // Freshly (re)following: the next drift tick must be allowed to
            // pin the viewport flush even when the content bottom itself has
            // not moved since the last correction cycle.
            followCorrectionContentBottom = nil
        followCorrectionLastExecutionAt = nil
        }

        guard !relatchedThisTick,
              mode == .followingLatest,
              restoration == nil,
              notificationHandoff == nil else { return effects }

        // Follow actual rendered growth — COALESCED. Geometry preference
        // callbacks fire many times per layout cycle (bottom marker,
        // viewport frame, row frames), and this method used to emit a
        // synchronous scrollTo for EACH drift tick; the scroll itself
        // perturbs layout, which re-fires the preferences, which scrolled
        // again — the geometry → scrollTo → geometry feedback that lands
        // the main thread inside ScrollViewCommitMutation and trips the
        // 0x8BADF00D scene watchdog when rich content height settles
        // repeatedly. Now the newest facts are recorded immediately, ONE
        // correction is scheduled for a later MainActor turn, and
        // followCorrectionDue re-validates against the latest facts — so
        // one rendering/layout update produces at most one bottom scroll,
        // while genuinely new growth (streaming) still gets followed.
        //
        // Re-arm also requires MEANINGFUL new growth beyond the last
        // corrected content bottom. The bottom marker is a global-frame
        // measurement: the correction's own scroll moves it, streaming
        // reveal changes it in sub-line steps, and layout refinements flap
        // it — re-arming on every >0.5pt change reproduced the storm one
        // MainActor turn apart (measured: 7 scrolls in 44 ms during a
        // hosted streaming fixture). The regrowth threshold bounds the
        // correction rate by the CONTENT growth rate, and the settled
        // bottom is adopted as the new base whenever the viewport sits at
        // or past it.
        //
        // Finally, re-arm is rate-limited after an EXECUTED correction:
        // the scroll commit shifts every global frame, and a schedule
        // minted from that flap is born inside the drain handler's layout
        // turn where SwiftUI may never deliver the onChange that would
        // execute it — an undrainable pending token that silently absorbs
        // every future schedule (observed live in the hosted streaming
        // fixture). The interval lets those frames settle first; genuine
        // growth re-arms on a later tick.
        let rearmIntervalElapsed = followCorrectionLastExecutionAt
            .map { latestFactTimestamp - $0 >= Self.followCorrectionRearmInterval }
            ?? true
        if rearmIntervalElapsed,
           pendingFollowCorrection == nil,
           let bottom = bottomMarkerMaxY,
           let viewport = viewportMaxY {
            switch Self.followCorrectionDecision(
                bottom: bottom,
                viewport: viewport,
                settledFloor: followCorrectionContentBottom,
                driftTolerance: followDriftTolerance,
                regrowthTolerance: Self.followCorrectionRegrowthTolerance
            ) {
            case .schedule:
                followCorrectionContentBottom = bottom
                followCorrectionSequence &+= 1
                let token = ChatFollowCorrectionToken(
                    generation: generation,
                    sessionKey: renderedSessionKey ?? activeSessionKey,
                    sequence: followCorrectionSequence
                )
                pendingFollowCorrection = token
                effects.append(.scheduleFollowCorrection(token))
            case .adoptSettledBottom:
                followCorrectionContentBottom = bottom
            case .idle:
                break
            }
        }
        return effects
    }

    /// Minimum content-bottom growth beyond the last corrected position
    /// before another correction cycle may arm. About half a body-text
    /// line: streaming reveal steps and layout refinements accumulate
    /// against it instead of re-arming a correction per frame.
    static let followCorrectionRegrowthTolerance: CGFloat = 12

    /// Pure decision for the coalesced follow-correction re-arm policy.
    enum FollowCorrectionDecision: Equatable {
        /// Drift beyond tolerance AND new content beyond the regrowth
        /// threshold: arm one correction.
        case schedule
        /// The viewport sits at/past the recorded content bottom (the last
        /// scroll landed, or content shrank): adopt this bottom as the new
        /// measurement base.
        case adoptSettledBottom
        /// Nothing to do.
        case idle
    }

    static func followCorrectionDecision(
        bottom: CGFloat,
        viewport: CGFloat,
        settledFloor: CGFloat?,
        driftTolerance: CGFloat,
        regrowthTolerance: CGFloat
    ) -> FollowCorrectionDecision {
        if bottom - viewport > driftTolerance {
            guard let settledFloor else { return .schedule }
            // Meaningful GROWTH beyond the last corrected bottom.
            if bottom > settledFloor + regrowthTolerance { return .schedule }
            // Meaningful SHRINK below the last corrected bottom (content
            // collapsed: a table paged, an image failed, rows unmounted)
            // while drift remains: the stale high floor would ignore future
            // growth until the bottom climbed back past
            // floor + regrowthTolerance even though the real baseline moved
            // down. Rebase by scheduling — the caller records the new
            // (lower) bottom as the floor and the correction re-pins the
            // viewport to the collapsed content.
            if bottom < settledFloor - regrowthTolerance { return .schedule }
            // Bottom within the flap window of the floor: layout noise from
            // the correction's own scroll commit. Re-arming here reproduced
            // the storm one MainActor turn apart.
            return .idle
        }
        // At (or past) the bottom: adopt any lower settled bottom so future
        // growth is measured from where the content actually sits.
        if let settledFloor, bottom < settledFloor {
            return .adoptSettledBottom
        }
        return .idle
    }

    /// Executes the outstanding coalesced follow correction. The view
    /// schedules this on the next MainActor turn; by then the facts below
    /// are the newest ones recorded, so a drift that resolved itself
    /// (animated transcript reassert already landed, user scrolled,
    /// ownership moved) dies without scrolling, and a correction for an
    /// ownership generation that is gone dies silently.
    ///
    /// Session ownership is validated against the SAME session the emitted
    /// command would use — activeSessionKey ?? renderedSessionKey, exactly
    /// what latestCommand anchors to. A correction scheduled for session A
    /// must never produce a scroll command for session B just because the
    /// active identity changed between schedule and drain; a mismatched
    /// (non-equivalent) session kills the correction and clears the
    /// pending token so it cannot linger. Equivalent spellings of the SAME
    /// conversation (runtime alias → canonical refresh) still pass, so
    /// ordinary identity resolution never breaks following.
    mutating func followCorrectionDue(
        _ token: ChatFollowCorrectionToken
    ) -> [ChatViewportEffect] {
        guard pendingFollowCorrection == token else { return [] }
        pendingFollowCorrection = nil
        guard mode == .followingLatest,
              restoration == nil,
              notificationHandoff == nil else { return [] }
        guard tokenOwnsCurrentSession(token) else { return [] }
        guard let bottom = bottomMarkerMaxY,
              let viewport = viewportMaxY,
              bottom - viewport > followDriftTolerance else { return [] }
        // Stamp the execution so re-arming waits out the scroll commit's
        // global-frame flap (see layoutMetricsChanged).
        followCorrectionLastExecutionAt = latestFactTimestamp
        return [.scroll(latestCommand(animated: false, retry: nil))]
    }

    /// The session a follow-correction scroll command would anchor to —
    /// the exact spelling latestCommand uses, so validation and emission
    /// can never disagree.
    private var followCorrectionCommandSession: ChatScrollSessionKey? {
        activeSessionKey ?? renderedSessionKey
    }

    /// True when a token scheduled under one session may still scroll under
    /// the current ownership: either both sides are session-less, or the
    /// token's session is an equivalent spelling of the command session
    /// (same conversation).
    private func tokenOwnsCurrentSession(_ token: ChatFollowCorrectionToken) -> Bool {
        let commandSession = followCorrectionCommandSession
        guard let tokenSession = token.sessionKey else {
            return commandSession == nil
        }
        guard let commandSession else { return false }
        return identity.areEquivalent(tokenSession, commandSession)
    }

    // MARK: - Drag lifecycle (folded ChatDragLifecycleState)

    /// Called on every drag-changed callback; only the first one for a
    /// gesture is a deliberate drag.
    mutating func userDragBegan(
        sessionKey: ChatScrollSessionKey?,
        viewportTransitionGeneration: UInt64
    ) -> [ChatViewportEffect] {
        dragGestureActive = true
        guard drag.begin(
            sessionKey: sessionKey,
            viewportTransitionGeneration: viewportTransitionGeneration
        ) else { return [] }
        generation &+= 1
        pendingDragEvaluation = nil
        pendingFollowCorrection = nil
        followCorrectionContentBottom = nil
        followCorrectionLastExecutionAt = nil
        restoration = nil
        mode = .browsing
        return [.cancelAutomaticRestoration]
    }

    mutating func userDragGestureEnded() -> [ChatViewportEffect] {
        dragGestureActive = false
        pendingDragEvaluation = nil
        guard let token = drag.finish() else { return [] }
        pendingDragEvaluation = token
        return [.scheduleDragEvaluation(token)]
    }

    /// Runs after the next main-actor turn (the view schedules it): a
    /// completion from an older gesture/viewport/session silently dies; a
    /// current one relatches near the bottom and then persists.
    mutating func evaluateDragCompletion(
        _ completed: ChatDragCompletionToken,
        viewportTransitionGeneration: UInt64
    ) -> [ChatViewportEffect] {
        if pendingDragEvaluation == completed {
            pendingDragEvaluation = nil
        }
        let current = drag.currentToken(
            sessionKey: renderedSessionKey ?? activeSessionKey,
            viewportTransitionGeneration: viewportTransitionGeneration
        )
        // Ports ChatFollowLatestRelatchPolicy.isCompletionCurrent. A new
        // chat can acquire its first server session ID without replacing
        // the viewport; the transition generation distinguishes that
        // identity resolution from an actual transcript transition.
        let sameSession = completed.sessionKey == nil
            || completed.sessionKey == current.sessionKey
            || identity.areEquivalent(completed.sessionKey, current.sessionKey)
        let isCurrent = completed.dragGeneration == current.dragGeneration
            && completed.viewportTransitionGeneration == current.viewportTransitionGeneration
            && sameSession
            && !dragGestureActive
            && restoration == nil
            && notificationHandoff == nil
        guard isCurrent else { return [] }

        // Relatch decision BEFORE persistence.
        if mode == .browsing, isNearBottom {
            mode = .followingLatest
        }
        return [
            .persistViewportSnapshot(for: completed.sessionKey),
            .flushViewportPersistence,
        ]
    }

    /// Ports invalidateChatDrag: kills the running gesture's completion.
    /// Does not end the gesture fact itself — userDragGestureEnded still
    /// arrives when the finger lifts.
    mutating func invalidateDrag(hasActiveGesture: Bool) -> [ChatViewportEffect] {
        let hadActiveWork = hasActiveGesture || drag.hasActiveCompletion
        drag.invalidate(hasActiveGesture: hasActiveGesture)
        if hadActiveWork {
            generation &+= 1
            pendingDragEvaluation = nil
        }
        return []
    }

    /// Ports abandonChatDrag (view reappeared). The gesture fact dies with
    /// the lifecycle: a stale true would suppress relatch/follow forever
    /// since no userDragGestureEnded ever arrives for an abandoned gesture.
    mutating func abandonDrag() -> [ChatViewportEffect] {
        drag.abandon()
        dragGestureActive = false
        pendingDragEvaluation = nil
        generation &+= 1
        return []
    }

    // MARK: - Explicit user commands

    /// Send, down-arrow, latest button: forces follow-latest and wins over
    /// automatic restoration.
    mutating func explicitLatestRequested() -> [ChatViewportEffect] {
        effectsForExplicitOwnershipChange()
        restoration = nil
        mode = .followingLatest
        return [.cancelAutomaticRestoration, .scroll(latestCommand(animated: true))]
    }

    /// Conversation-title tap: pins the viewport to the conversation top.
    /// Repeated taps are independently observable through `request`.
    mutating func explicitTopRequested(request: Int) -> [ChatViewportEffect] {
        effectsForExplicitOwnershipChange()
        restoration = nil
        mode = .explicitTop(request: request)
        return [.cancelAutomaticRestoration, .scroll(topCommand(request: request))]
    }

    // MARK: - Notification handoff

    /// The destination transcript must emit its own geometry before the
    /// viewport may move: a long lazy transcript cannot inherit the old
    /// conversation's offset.
    mutating func notificationHandoffBegan(
        destination: ChatScrollSessionKey?
    ) -> [ChatViewportEffect] {
        var effects: [ChatViewportEffect] = []
        if notificationHandoff == nil {
            notificationHandoff = ChatViewportHandoffState(sessionKey: destination)
            effects.append(contentsOf: beginHandoffOwnership())
        }
        if let destination {
            renderedSessionKey = destination
            activeSessionKey = destination
        }
        if case .explicitTop = mode {
            // A title tap that already claimed top ownership survives the
            // handoff (the old owner state let the current top owner win
            // handoff completion).
        } else {
            mode = .transitioning
        }
        return effects
    }

    mutating func notificationHandoffLayoutMeasured() -> [ChatViewportEffect] {
        if notificationHandoff != nil {
            notificationHandoff?.hasMeasuredLayout = true
        }
        return []
    }

    /// The view calls this when the opening flag clears and the destination
    /// session is the active one (ports finishNotificationHandoffIfReady).
    mutating func notificationHandoffDestinationReady(
        activeKey: ChatScrollSessionKey?
    ) -> [ChatViewportEffect] {
        guard var pending = notificationHandoff else { return [] }
        // Key mismatch or unmeasured destination: keep the handoff pending —
        // the old code retried on every subsequent geometry tick rather than
        // dropping the handoff.
        let destinationKey = pending.sessionKey ?? activeKey
        guard identity.areEquivalent(destinationKey, activeKey) else { return [] }
        if pending.sessionKey == nil {
            pending.sessionKey = activeKey
            // Old code inferred measured-ness from current geometry when the
            // key was adopted at flag-clear time, and persisted the adoption
            // even when readiness failed — keep that so a later tick builds
            // on the adopted key instead of re-deriving it.
            pending.hasMeasuredLayout = bottomMarkerMaxY != nil && viewportMaxY != nil
            notificationHandoff = pending
        }
        guard pending.hasMeasuredLayout else { return [] }
        notificationHandoff = nil

        generation &+= 1
        if case .explicitTop(let request) = mode {
            // A title tap issued during the handoff still wins once the
            // destination is render-ready; the retry-capable path covers a
            // not-yet-materialized top anchor.
            return [.scroll(topCommand(request: request))]
        }
        guard !dragGestureActive else {
            mode = .browsing
            return []
        }
        mode = .followingLatest
        return [.scroll(latestCommand(animated: false, retry: nil))]
    }

    // MARK: - Automatic restoration (view half)

    /// Ports the entry of applyChatResumeRestoration: adopt the request,
    /// resolve the destination against the current targets, and own the
    /// viewport while the poll loop runs.
    mutating func restorationRequested(
        _ request: ChatResumeRestorationRequest
    ) -> [ChatViewportEffect] {
        // A published restoration can be overtaken by a session switch
        // before the SwiftUI .task adopts it. A stale request must never
        // claim the viewport — abandon it through the existing AppState
        // contract immediately instead of waiting for the check budget.
        let currentKey = renderedSessionKey ?? activeSessionKey
        guard identity.areEquivalent(request.sessionKey, currentKey) else {
            return [.abandonRestoration(generation: request.generation)]
        }
        effectsForExplicitOwnershipChange()
        restoration = RestorationState(
            request: request,
            destination: resolveRestorationDestination(for: request)
        )
        mode = .restoring
        return []
    }

    /// The published request disappeared on the AppState side (completed,
    /// abandoned, or cancelled elsewhere).
    mutating func restorationSystemCancelled() -> [ChatViewportEffect] {
        guard restoration != nil else { return [] }
        restoration = nil
        if mode == .restoring {
            mode = .browsing
        }
        return []
    }

    /// One poll iteration (Task 5 ports the full algorithm; the tick is
    /// view-scheduled every 25ms while `restorationIsActive`).
    mutating func restorationTick(
        messages: [ChatMessage],
        transcriptRevision: UInt64,
        viewportTransitionGeneration: UInt64,
        renderedContent: ChatRenderedScrollContent?,
        installedTargets: ChatRenderedScrollTargets,
        topVisibleID: String?,
        isNearBottom: Bool
    ) -> [ChatViewportEffect] {
        guard var state = restoration else { return [] }
        if state.request.destination != .latest {
            // Keep resolving against fresh targets (duplicates may have
            // changed; anchor may only appear after reconciliation).
            let update = targetCache.update(for: messages)
            renderedTranscriptRevision = transcriptRevision
            mirroredViewportTransitionGeneration = viewportTransitionGeneration
            if update != .unchanged {
                state.destination = resolveRestorationDestination(for: state.request)
                state.lastScrollCheck = nil
            }
        }

        // Equivalence-based session match: the rendered scope's key might be a
        // runtime alias of the request's canonical key (or vice versa). The
        // admission check in restorationRequested already uses
        // identity.areEquivalent — the poll must agree on the same semantics.
        let scopeMatches = renderedContent.map {
            identity.areEquivalent($0.scope.sessionKey, state.request.sessionKey)
        } ?? false
        let action = state.nextAction(
            renderedContent: renderedContent,
            installedTargets: installedTargets,
            cacheRevision: targetCache.renderingRevision,
            transcriptRevision: transcriptRevision,
            topVisibleID: topVisibleID,
            isNearBottom: isNearBottom,
            sessionMatches: scopeMatches
        )
        restoration = state
        switch action {
        case .wait:
            return []
        case .scroll(let destination):
            let command: ChatViewportCommand
            switch destination {
            case .latest:
                command = latestCommand(animated: false, retry: nil)
            case .anchor(let anchor):
                command = ChatViewportCommand(
                    generation: generation,
                    sessionKey: renderedSessionKey ?? activeSessionKey,
                    destination: .message(id: anchor),
                    animated: false,
                    retry: nil
                )
            }
            return [.scroll(command)]
        case .complete:
            restoration = nil
            let wasLatest = state.destination == .latest
            mode = wasLatest ? .followingLatest : .browsing
            var effects: [ChatViewportEffect] = [
                .completeRestoration(generation: state.request.generation)
            ]
            if wasLatest {
                effects.append(.persistViewportSnapshot(for: state.request.sessionKey))
            }
            return effects
        case .abandon:
            restoration = nil
            mode = .browsing
            return [.abandonRestoration(generation: state.request.generation)]
        case .cancelled:
            restoration = nil
            mode = .browsing
            return []
        }
    }

    // MARK: - View lifecycle

    mutating func viewDisappeared() -> [ChatViewportEffect] {
        pendingFollowCorrection = nil
        followCorrectionContentBottom = nil
        followCorrectionLastExecutionAt = nil
        return abandonDrag()
    }

    // MARK: - Command currency

    func isCommandCurrent(_ command: ChatViewportCommand) -> Bool {
        guard command.generation == generation else { return false }
        let sessionMatches = command.sessionKey == nil
            || identity.areEquivalent(command.sessionKey, renderedSessionKey)
            || identity.areEquivalent(command.sessionKey, activeSessionKey)
        switch command.destination {
        case .bottom:
            return sessionMatches && mode == .followingLatest && restoration == nil
        case .top(_, let request):
            guard case .explicitTop(let currentRequest) = mode else { return false }
            return sessionMatches && currentRequest == request
        case .message:
            return sessionMatches && mode == .restoring && restoration != nil
        }
    }

    // MARK: - Snapshots

    func renderedViewportSnapshot() -> ChatRenderedViewportSnapshot? {
        guard let sessionKey = renderedSessionKey else { return nil }
        guard let snapshot = ChatTitleScrollViewportSnapshot.make(
            followsLatest: isFollowingLatest,
            topVisibleID: stableTopMessageID,
            topAnchorID: ChatTitleScrollAnchor.id(for: sessionKey),
            targets: targetCache.targets
        ) else { return nil }
        return ChatRenderedViewportSnapshot(sessionKey: sessionKey, snapshot: snapshot)
    }

    // MARK: - Private

    private mutating func effectsForExplicitOwnershipChange() {
        _ = invalidateDrag(hasActiveGesture: dragGestureActive)
        generation &+= 1
        pendingFollowCorrection = nil
        followCorrectionContentBottom = nil
        followCorrectionLastExecutionAt = nil
    }

    private mutating func beginHandoffOwnership() -> [ChatViewportEffect] {
        _ = invalidateDrag(hasActiveGesture: dragGestureActive)
        generation &+= 1
        pendingFollowCorrection = nil
        followCorrectionContentBottom = nil
        followCorrectionLastExecutionAt = nil
        restoration = nil
        return [.cancelAutomaticRestoration]
    }

    private var activeOrFallbackSessionKey: ChatScrollSessionKey {
        if let activeSessionKey { return activeSessionKey }
        if let renderedSessionKey { return renderedSessionKey }
        return ChatScrollSessionKey(profile: identity.profile ?? "", sessionID: "new")
    }

    private var bottomAnchorID: String {
        let key = activeOrFallbackSessionKey
        return "chat-latest-\(key.profile)-\(key.sessionID)"
    }

    private var topAnchorID: String {
        let key = activeOrFallbackSessionKey
        return ChatTitleScrollAnchor.id(for: key)
    }

    private func latestCommand(
        animated: Bool,
        retry: ChatViewportCommand.Retry? = .delayed(milliseconds: 150)
    ) -> ChatViewportCommand {
        ChatViewportCommand(
            generation: generation,
            sessionKey: activeSessionKey ?? renderedSessionKey,
            destination: .bottom(anchorID: bottomAnchorID),
            animated: animated,
            retry: retry
        )
    }

    private func topCommand(request: Int) -> ChatViewportCommand {
        ChatViewportCommand(
            generation: generation,
            sessionKey: activeSessionKey ?? renderedSessionKey,
            destination: .top(anchorID: topAnchorID, request: request),
            animated: false,
            retry: .delayed(milliseconds: 150)
        )
    }

    /// Stable-top detection operates purely over the rendered frames the
    /// layout pass supplied: filter to rows intersecting the viewport, then
    /// take the smallest transcript order. Work is O(rendered rows) — never
    /// a scan of the full transcript target list, which in a deep
    /// conversation is hundreds of entries per geometry tick.
    private mutating func updateStableTopMessage(rowFrames: [ChatRenderedRowFrame]) {
        guard let viewportMinY, let viewportMaxY else {
            stableTopMessageID = nil
            return
        }
        TranscriptPerf.stableTopScanTargetCount = rowFrames.count
        stableTopMessageID = rowFrames
            .filter { $0.maxY > viewportMinY && $0.minY < viewportMaxY }
            .min(by: { $0.order < $1.order })?
            .id
    }

    private func resolveRestorationDestination(
        for request: ChatResumeRestorationRequest
    ) -> ChatResumeViewportDestination {
        switch request.destination {
        case .latest:
            return .latest
        case .snapshot(let snapshot):
            // The resolver returns semantic anchor IDs, but rows are keyed
            // by message.id. Resolve the semantic anchor to its source
            // message.id so the restoration state machine operates in one
            // identity space.
            let resolved = ChatResumeViewportResolver.destination(
                for: snapshot,
                availableTargets: ChatScrollTargetAvailability(targets: targetCache.targets)
            )
            switch resolved {
            case .latest:
                return .latest
            case .anchor(let semanticAnchor):
                let sourceAnchor = targetCache.targets
                    .first { $0.semanticID == semanticAnchor }?.id ?? semanticAnchor
                return .anchor(sourceAnchor)
            }
        }
    }
}

// MARK: - Folded sub-states

/// Verbatim fold of ChatDragLifecycleState: owns the drag completion token
/// lineage (which gesture, which session, which transition generation).
private struct DragLifecycle: Equatable {
    private(set) var generation: UInt64 = 0
    private var activeCompletion: ChatDragCompletionToken?
    private var activeGestureInvalidated = false

    var hasActiveCompletion: Bool { activeCompletion != nil }

    mutating func begin(
        sessionKey: ChatScrollSessionKey?,
        viewportTransitionGeneration: UInt64
    ) -> Bool {
        guard activeCompletion == nil, !activeGestureInvalidated else { return false }
        generation &+= 1
        activeCompletion = ChatDragCompletionToken(
            dragGeneration: generation,
            sessionKey: sessionKey,
            viewportTransitionGeneration: viewportTransitionGeneration
        )
        return true
    }

    mutating func invalidate(hasActiveGesture: Bool) {
        generation &+= 1
        if hasActiveGesture || activeCompletion != nil {
            activeGestureInvalidated = true
        }
    }

    mutating func abandon() {
        generation &+= 1
        activeCompletion = nil
        activeGestureInvalidated = false
    }

    mutating func finish() -> ChatDragCompletionToken? {
        defer {
            activeCompletion = nil
            activeGestureInvalidated = false
        }
        guard !activeGestureInvalidated else { return nil }
        return activeCompletion
    }

    func currentToken(
        sessionKey: ChatScrollSessionKey?,
        viewportTransitionGeneration: UInt64
    ) -> ChatDragCompletionToken {
        ChatDragCompletionToken(
            dragGeneration: generation,
            sessionKey: sessionKey,
            viewportTransitionGeneration: viewportTransitionGeneration
        )
    }
}

/// Verbatim fold of ChatResumeRenderRestorationState's algorithm: the
/// view-owned half of restoration decides, purely from supplied layout
/// observations, whether to wait / scroll / complete / abandon.
struct RestorationState: Equatable {
    let request: ChatResumeRestorationRequest
    var destination: ChatResumeViewportDestination
    private(set) var checkCount = 0
    var lastScrollCheck: Int?
    private var isCancelled = false

    static let maximumChecks = 80
    static let retryInterval = 4

    init(request: ChatResumeRestorationRequest, destination: ChatResumeViewportDestination) {
        self.request = request
        self.destination = destination
    }

    mutating func cancel() {
        isCancelled = true
    }

    enum Action: Equatable {
        case wait
        case scroll(ChatResumeViewportDestination)
        case complete
        case abandon
        case cancelled
    }

    /// `sessionMatches` is computed by the controller using
    /// identity.areEquivalent so that runtime/stored/canonical aliases all
    /// pass the scope gate — matching the admission check in
    /// restorationRequested. RestorationState itself stays pure and
    /// unaware of ChatScrollSessionIdentity.
    mutating func nextAction(
        renderedContent: ChatRenderedScrollContent?,
        installedTargets: ChatRenderedScrollTargets,
        cacheRevision: UInt64,
        transcriptRevision: UInt64,
        topVisibleID: String?,
        isNearBottom: Bool,
        sessionMatches: Bool
    ) -> Action {
        guard !isCancelled else { return .cancelled }
        checkCount += 1

        guard let renderedContent,
              renderedContent.scope.restorationGeneration == request.generation,
              sessionMatches,
              renderedContent.scope.cacheRevision == cacheRevision,
              renderedContent.scope.transcriptRevision == transcriptRevision else {
            return checkCount > Self.maximumChecks ? .abandon : .wait
        }

        if lastScrollCheck != nil,
           targetIsInstalled(in: installedTargets, scope: renderedContent.scope),
           destinationIsConfirmed(topVisibleID: topVisibleID, isNearBottom: isNearBottom) {
            return .complete
        }

        guard checkCount <= Self.maximumChecks else { return .abandon }

        if lastScrollCheck.map({ checkCount - $0 >= Self.retryInterval }) ?? true {
            lastScrollCheck = checkCount
            return .scroll(destination)
        }

        return .wait
    }

    private func targetIsInstalled(
        in installedTargets: ChatRenderedScrollTargets,
        scope: ChatRenderedScrollScope
    ) -> Bool {
        switch destination {
        case .latest:
            return installedTargets.contains(
                bottom: "chat-latest-\(scope.sessionKey.profile)-\(scope.sessionKey.sessionID)",
                in: scope
            )
        case .anchor(let anchor):
            return installedTargets.contains(row: anchor, in: scope)
        }
    }

    private func destinationIsConfirmed(
        topVisibleID: String?,
        isNearBottom: Bool
    ) -> Bool {
        switch destination {
        case .latest:
            return isNearBottom
        case .anchor(let anchor):
            return topVisibleID == anchor
        }
    }
}
