import UIKit

/// The transcript's collection view and its layout, reduced to what
/// TranscriptScroller reads and writes (#1533, the transcript rewrite).
/// Frames are in the scroll view's content space, laid out or estimated:
/// every row the transcript draws has one, so any place in it is found at
/// once, with no pass to wait for. Tests use a fake.
@MainActor
protocol TranscriptScrollSurface: AnyObject {
    var contentOffsetY: CGFloat { get }
    var contentHeight: CGFloat { get }
    var viewportHeight: CGFloat { get }
    var insetTop: CGFloat { get }
    var insetBottom: CGFloat { get }
    /// A finger on the transcript.
    var isTracking: Bool { get }
    /// A fling still moving it.
    var isDecelerating: Bool { get }
    /// The least content height the layout's last pass gave the transcript:
    /// what `reserveContentHeight` asked for, once a pass has taken it.
    var reservedContentHeight: CGFloat { get }
    /// Reports back through `TranscriptScroller.surfaceScrolled` before it
    /// returns, as UIKit does. A write under a finger or during a fling
    /// leaves it moving from the new offset, as setting UIKit's
    /// `contentOffset` does (`setContentOffset(_:animated: false)` would
    /// stop a fling).
    func setContentOffsetY(_ y: CGFloat, animated: Bool)
    /// The row's frame; nil for a row the transcript doesn't draw.
    func frame(ofRow id: String) -> TranscriptRowFrame?
    /// The rows whose frames cross `band`, top first.
    func rows(crossing band: ClosedRange<CGFloat>) -> [TranscriptRowFrame]
    /// The least content height for the layout to give the transcript from
    /// its next pass: room under a sent message for its reply (#1436). Zero
    /// for none.
    func reserveContentHeight(_ height: CGFloat)
}

extension TranscriptScrollSurface {
    var minOffsetY: CGFloat { -insetTop }

    var maxOffsetY: CGFloat {
        max(minOffsetY, contentHeight + insetBottom - viewportHeight)
    }

    var distanceFromBottom: CGFloat { maxOffsetY - contentOffsetY }

    func clampedOffsetY(_ y: CGFloat) -> CGFloat {
        min(max(y, minOffsetY), maxOffsetY)
    }

    /// What the reader sees, in content space: under the bar above the
    /// transcript, above the one below it.
    var visibleBand: ClosedRange<CGFloat> {
        let top = contentOffsetY + insetTop
        return top...max(top, contentOffsetY + viewportHeight - insetBottom)
    }
}

/// One row's frame in the transcript's content space.
struct TranscriptRowFrame: Equatable {
    let id: String
    let minY: CGFloat
    let maxY: CGFloat
}

/// What the scroller asks of its view. Everything else (following, keeping
/// the reader's row, placing a saved place) it does on the surface itself.
enum TranscriptScrollerEvent: Equatable {
    case persistSnapshot(ChatScrollSessionKey?)
    case flushPersistence
    case cancelAutomaticRestoration
    case completeRestoration(generation: UInt64)
    case abandonRestoration(generation: UInt64)
}

/// The viewport values ChatView renders from. Published only when one of
/// them changes, so scrolling itself never re-evaluates the chat.
struct ChatScrollRenderInputs: Equatable {
    var renderedSessionKey: ChatScrollSessionKey?
    var renderedScrollScope: ChatRenderedScrollScope?
    /// The target cache's rendering revision. The scope above carries it
    /// too, but only while a session is rendered; rows without a session
    /// key must still re-run the body when they change.
    var targetsRevision: UInt64 = 0
}

/// The viewport values the chat's jump buttons render from. They change as
/// the reader scrolls (a drag leaves the latest message, the jump button
/// appears a screen up), so they publish on their own object: ChatView
/// re-running for them would re-run every row in the transcript, a hitch at
/// the start of each scroll.
struct ChatScrollChromeInputs: Equatable {
    var isFollowingLatest = true
    var showsJumpToLatest = false
    var visibilityTrackedMessageID: String? = nil
    var isVisibilityTrackedMessageOffscreen = false
}

/// The values the chat's jump buttons draw from, on their own object so the
/// chat doesn't redraw as the reader scrolls.
@MainActor
final class TranscriptScrollChrome: ObservableObject {
    @Published fileprivate(set) var inputs = ChatScrollChromeInputs()
}

/// Settings > Chat: a reply longer than the screen stops at its start
/// instead of following its end (#365). Device setting, shared through
/// Sync across devices; on by default.
enum ChatReplyStartPreference {
    static let key = "conduit.chat.stopAtReplyStart"
    static let defaultOn = true

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn
    }
}

/// Owns the chat transcript's scroll position (#1533, the transcript
/// rewrite): a state machine in plain Swift, apart from UIKit, so its rules
/// can be read and tested whole. It keeps the rules of the lazy stack's
/// scroll engine it replaced (TranscriptScrollerTests ported that engine's
/// tests rule by rule) without the work the stack made for them: every row
/// has a frame here, so a place is found at once.
///
/// - Following: the reader is at the latest message, and each layout pass
///   puts them back there in that pass, with no animation.
/// - Browsing: the reader is on a row (their anchor: the first row starting
///   on screen, and where its top sits). When rows above it change height
///   (a picture loading, a card measuring, a page of earlier messages
///   arriving), the pass that changes them moves the offset by as much, so
///   what the reader looks at stays still, under a finger and through a
///   fling too. That one rule replaces the old prepend hold, the card
///   shifts and the blank-screen rebuild.
/// - Restoring: a saved place waits for its transcript and its row; placed,
///   the reader is browsing there, or following at the end.
///
/// Only the reader leaves following (a drag, or opening or closing a row),
/// and only the end of the chat or a command brings them back: a move that
/// isn't a finger's and leaves them within `nearBottomTolerance` of the end
/// follows again, and momentum away from it never does.
///
/// Within following, a reply stops at its start (#365, Settings > Chat's
/// Long replies): the sent message moves to the top with room under it for
/// the reply (#1436), and a reply that outgrows the screen leaves the
/// reader browsing there. An unread chat opens at the same stop.
///
/// Only the scroller writes the offset, and the recorder
/// (ChatViewportTrace) names the rule behind each write.
@MainActor
final class TranscriptScroller: ObservableObject {
    enum Mode: Equatable {
        case following
        case browsing
        case restoring
    }

    /// Where a browsing reader is: rows, each with where its top sits from
    /// the visible top (positive below it). The first one the layout still
    /// draws decides; the rest stand in for it when it goes (a send waiting
    /// on screen becoming the chat's own row, the reply streaming in
    /// becoming the saved one).
    struct Anchor: Equatable {
        struct Place: Equatable {
            let id: String
            let top: CGFloat
        }

        var places: [Place]
    }

    /// A saved place to put the reader back at, asked for when the
    /// transcript was at `transcriptRevision`: those rows are drawn first.
    struct Restoration: Equatable {
        let request: ChatResumeRestorationRequest
        let transcriptRevision: UInt64
    }

    /// Which row a browsing reader is taken to be on.
    private enum AnchorChoice {
        /// The first row starting on screen: what the reader looks at, which
        /// a row above it growing (a picture loading at the top of a tall
        /// row) doesn't move.
        case firstOnScreen
        /// The row at the screen's top: what's above a row the reader opens
        /// or closes stays still, the row itself included.
        case topOfScreen
        /// A row the reader asked for or tapped, when it's on screen; else
        /// the row at the screen's top.
        case row(String)
    }

    static let nearBottomTolerance: CGFloat = 40
    /// How long an animated move to the end holds off pinning.
    static let latestAnimationDuration: TimeInterval = 0.4
    /// How far below the viewport's top the stop leaves the user's message:
    /// where a new chat's first message sits, so a new chat doesn't move at
    /// all (#1436).
    static let replyStartTopGap: CGFloat = 37
    /// How long after the reader opens or closes a row the scroller checks
    /// whether they are still at the end: the row animates open with
    /// ConduitMotion.response (a 0.34 s spring).
    static let disclosureSettleDelay: TimeInterval = 0.5
    /// How long a saved place waits for its transcript and its row before
    /// it's dropped. Time in the background doesn't count.
    static let restorationDeadline: TimeInterval = 2

    var onEvent: (@MainActor (TranscriptScrollerEvent) -> Void)?
    @Published private(set) var renderInputs = ChatScrollRenderInputs()
    let chrome = TranscriptScrollChrome()
    private var renderInputsPublishScheduled = false
    /// Settings > Chat's "Stop at the start of long replies" (#365).
    var holdsRepliesAtStart: @MainActor () -> Bool = { false }

    private(set) var mode: Mode = .following {
        didSet {
            if mode != oldValue { ChatViewportTrace.shared.log("mode \(oldValue) -> \(mode)") }
        }
    }
    private(set) var anchor: Anchor?
    private(set) var identity: ChatScrollSessionIdentity = .none
    private(set) var renderedSessionKey: ChatScrollSessionKey?
    private(set) var activeSessionKey: ChatScrollSessionKey?
    private(set) var renderedTranscriptRevision: UInt64 = 0
    private var mirroredViewportTransitionGeneration: UInt64 = 0
    private(set) var targetCache = ChatMessageScrollTargetCache()
    /// The targets' ids: which rows on screen are the chat's messages.
    private var targetIDs: Set<String> = []
    private(set) var restoration: Restoration?
    /// Bumped by each restoration asked for or dropped, and by a pause, so
    /// only the latest deadline acts.
    private var restorationDeadlineGeneration: UInt64 = 0
    /// The foreground time a saved place has waited, and when the current
    /// stretch of it began: time in the background doesn't count.
    private var restorationWaited: TimeInterval = 0
    private var restorationWaitResumed: TimeInterval = 0
    private(set) var topVisibleMessageID: String?
    private(set) var showsJumpToLatest = false
    private(set) var isPaused = false
    private(set) var isDragging = false
    private(set) weak var surface: TranscriptScrollSurface?
    private var surfaceCallbackDepth = 0
    /// The scroller's own writes report back through `surfaceScrolled`
    /// before they return: not the reader's moves.
    private var writeDepth = 0
    private var lastObservedOffsetY: CGFloat?
    /// The bottom inset the last pass saw. A change is a bar under the
    /// transcript changing height (the composer, Predictive's chips, the
    /// plan dock, a call's bar, the keyboard).
    private var lastInsetBottom: CGFloat?
    /// The bottom inset when the current drag began.
    private var insetAtDragStart: CGFloat?
    /// Moving a browsing reader up to the end a shrinking bar left them
    /// past: not their move back to it.
    private var closingBarGap = false
    /// A finger, a fling or an animated move kept a following reader from
    /// being put back at the end (content grew, a bar changed): the first
    /// moment at rest does it.
    private var pinOwed = false
    private var latestAnimationUntil: TimeInterval?
    /// Bumped by each animated move to the end and anything that ends one,
    /// so only the latest move's landing pins.
    private var latestAnimationGeneration: UInt64 = 0
    /// Bumped by every row the reader opens or closes, and by a drag, the
    /// commands, a session switch and a restoration, so only the latest
    /// settle check acts.
    private var disclosureGeneration: UInt64 = 0
    private var visibilityTrackedMessageID: String?
    private var isVisibilityTrackedMessageOffscreen = false
    /// A reply below the user's latest message may still outgrow the screen
    /// and stop at its start. Armed by a send, a turn started elsewhere, or
    /// opening a chat with an unread reply; the jump to latest, the other
    /// commands and a session switch disarm it, and so does a reader
    /// already below the reply's start.
    private(set) var replyHoldArmed = false {
        didSet {
            if replyHoldArmed != oldValue { ChatViewportTrace.shared.log("hold \(replyHoldArmed ? "armed" : "disarmed")") }
            if !replyHoldArmed { replyRoomArmed = false }
            refreshReplyRoom()
        }
    }
    /// The hold is for a reply still to come (a send, or a turn started
    /// elsewhere), not one already there (an unread chat opened): the
    /// transcript makes room under the message for it, and the first move
    /// to the stop animates.
    private(set) var replyRoomArmed = false {
        didSet {
            replyRoomLanding = replyRoomArmed
            replyRoomLaidOut = false
            refreshReplyRoom()
        }
    }
    /// The content height the room asks for (`reserveContentHeight`).
    private(set) var replyRoomHeight: CGFloat = 0
    /// The room has been laid out once: from then on following holds the
    /// stop even while the content is briefly shorter than it (the room
    /// catching up with a keyboard or a row shrinking), instead of chasing
    /// the end down and back up.
    private var replyRoomLaidOut = false
    /// The first move to the stop after a send is still to come.
    private var replyRoomLanding = false
    /// The user message the latest turn answers, by id, so a new one (a
    /// turn started on another device) arms the hold.
    private var latestUserRowID: String?
    /// An unread chat just opened: once its transcript is in, it lands at
    /// the start of its latest reply instead of the end.
    private var replyStartLandingPending = false
    /// The viewport transition of the open that asked for the landing, so
    /// the switch that open makes doesn't drop it.
    private var replyStartLandingGeneration: UInt64?
    /// Landed there, and the reader hasn't moved since: the end of a
    /// notification's handoff doesn't take them to the end.
    private var landedAtReplyStart = false
    /// The rows drawn are saved ones standing in for the chat's. Hermes'
    /// first rows after them are the chat's first sync: a user message among
    /// them (a turn started elsewhere since) doesn't arm the hold, as when
    /// the chat opened on no rows.
    private var transcriptIsProvisional = false
    private let now: () -> TimeInterval
    private let prefersReducedMotion: @MainActor () -> Bool
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    init(
        now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
        prefersReducedMotion: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled },
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, body in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) }
        }
    ) {
        self.now = now
        self.prefersReducedMotion = prefersReducedMotion
        self.schedule = schedule
    }

    // MARK: - Derived facts

    var targets: [ChatMessageScrollTarget] { targetCache.targets }

    var isFollowingLatest: Bool { mode == .following }

    var restorationIsActive: Bool { restoration != nil }

    /// True while handling a callback from UIKit (the scroll view, its pan
    /// gesture or the layout). Those can arrive in the middle of a SwiftUI
    /// update, so the view defers state writes and AppState calls made from
    /// them.
    var isHandlingSurfaceCallback: Bool { surfaceCallbackDepth > 0 }

    var isNearBottom: Bool {
        guard let surface else { return true }
        return surface.distanceFromBottom <= Self.nearBottomTolerance
    }

    /// A finger on the chat, or a fling still moving it.
    var isUserScrolling: Bool {
        isDragging || surface?.isTracking == true || surface?.isDecelerating == true
    }

    var latestAnimationInFlight: Bool {
        latestAnimationUntil.map { now() < $0 } ?? false
    }

    /// The scope the view embeds into its rendered-content preference; keeps
    /// the AppState layout-settle handshake fed.
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

    /// Track one row's visibility without publishing on every scroll tick:
    /// the chrome changes only when it crosses the viewport's edge.
    func trackMessageVisibility(of id: String?) {
        guard visibilityTrackedMessageID != id else {
            refreshTrackedMessageVisibility()
            return
        }
        visibilityTrackedMessageID = id
        refreshTrackedMessageVisibility(forcePublish: true)
    }

    // MARK: - Surface

    func attach(_ surface: TranscriptScrollSurface) {
        self.surface = surface
        lastObservedOffsetY = surface.contentOffsetY
        lastInsetBottom = surface.insetBottom
        surface.reserveContentHeight(replyRoomHeight)
        layoutChanged()
        landAtReplyStartIfPending()
        placeRestorationIfReady()
    }

    func detach(_ surface: TranscriptScrollSurface) {
        guard self.surface === surface else { return }
        self.surface = nil
    }

    /// A layout pass changed the content's size, the viewport's, the insets
    /// or rows' frames. Runs inside that pass, so what it writes is drawn
    /// with it. The view calls it from its collection view's layout pass,
    /// which compares the adjusted insets, so a bar's change is seen with
    /// its final inset: nothing checks again on later turns, as the
    /// engine's bar check did (#1431).
    func layoutChanged() {
        TranscriptPerf.note(.layoutMetricsChanged)
        ChatViewportWatch.shared.layoutPass()
        surfaceCallbackDepth += 1
        defer { surfaceCallbackDepth -= 1 }
        guard let surface, !isPaused else { return }
        let barChanged = lastInsetBottom.map { abs($0 - surface.insetBottom) > 0.5 } ?? false
        lastInsetBottom = surface.insetBottom
        // A bar that changed under a finger or a fling: the end it leaves
        // is taken once they let go.
        if barChanged, isUserScrolling { pinOwed = true }
        refreshReplyRoom()
        switch mode {
        case .following:
            if canPinWhileFollowing(surface) {
                pin(surface)
            } else {
                pinOwed = true
            }
        case .browsing:
            keepAnchor(on: surface, barChanged: barChanged)
            if mode == .browsing { refreshTopVisibleRow(persist: true) }
        case .restoring:
            placeRestorationIfReady()
        }
        refreshTrackedMessageVisibility()
        refreshJumpButton()
    }

    /// The offset changed (the reader, a fling, UIKit, or the scroller's
    /// own write), or a fling came to rest (scrollViewDidEndDecelerating:
    /// its last move can still say it's moving).
    func surfaceScrolled() {
        surfaceCallbackDepth += 1
        defer { surfaceCallbackDepth -= 1 }
        guard let surface, !isPaused else { return }
        let previousOffsetY = lastObservedOffsetY
        lastObservedOffsetY = surface.contentOffsetY
        // Momentum carrying the content toward older messages. A flick can
        // end within the relatch distance and still travel far.
        let deceleratingAway = surface.isDecelerating
            && previousOffsetY.map { surface.contentOffsetY < $0 - 0.5 } == true
        // A move that isn't the scroller's: the reader is on whatever row
        // it left them on.
        if mode == .browsing, writeDepth == 0 {
            captureAnchor(on: surface)
        }
        if mode != .following {
            refreshTopVisibleRow(persist: mode == .browsing)
        }
        if mode == .browsing,
           !closingBarGap,
           !surface.isTracking,
           !deceleratingAway,
           surface.distanceFromBottom <= Self.nearBottomTolerance {
            setMode(.following)
            emit(.persistSnapshot(renderedSessionKey))
        } else if mode == .following,
                  deceleratingAway,
                  surface.distanceFromBottom > Self.nearBottomTolerance {
            setMode(.browsing)
            emit(.persistSnapshot(renderedSessionKey))
        }
        // Not an else: a reader who relatched above may have done it past
        // the end. At rest, a following reader a finger or a fling kept from
        // the end, or one over empty space under the last message (the
        // content shrank, and UIKit never clamps), is put back now.
        if writeDepth == 0, !isDragging, canPinWhileFollowing(surface),
           pinOwed || surface.distanceFromBottom < -0.5 {
            pin(surface)
        }
        refreshTrackedMessageVisibility()
        refreshJumpButton()
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if restoration != nil {
            if paused {
                // The deadline counts foreground time only: it stops here,
                // and the return arms what's left.
                restorationWaited += now() - restorationWaitResumed
                restorationDeadlineGeneration &+= 1
            } else {
                armRestorationDeadline()
            }
        }
        guard !paused else { return }
        // Catch up on whatever changed while backgrounded.
        layoutChanged()
        surfaceScrolled()
        landAtReplyStartIfPending()
        placeRestorationIfReady()
    }

    // MARK: - User drag

    func userDragBegan() {
        surfaceCallbackDepth += 1
        defer { surfaceCallbackDepth -= 1 }
        isDragging = true
        cancelDisclosureSettle()
        cancelLatestAnimation()
        dropRestoration()
        replyStartLandingPending = false
        landedAtReplyStart = false
        emit(.cancelAutomaticRestoration)
        insetAtDragStart = surface?.insetBottom
        if mode != .browsing {
            setMode(.browsing)
            emit(.persistSnapshot(renderedSessionKey))
        }
    }

    func userDragEnded() {
        surfaceCallbackDepth += 1
        defer { surfaceCallbackDepth -= 1 }
        isDragging = false
        if let surface, !surface.isDecelerating {
            // Near the end is measured against the end as it was when the
            // finger came down: a bar that moved under it is not where the
            // reader let go, either way.
            let barShift = surface.insetBottom - (insetAtDragStart ?? surface.insetBottom)
            if mode == .browsing, surface.distanceFromBottom - barShift <= Self.nearBottomTolerance {
                setMode(.following)
            }
            if mode == .following, pinOwed || surface.distanceFromBottom < -0.5 {
                pin(surface)
            } else if mode == .browsing, surface.distanceFromBottom < -0.5 {
                // Let go past the end a bar shrinking under the finger made:
                // up to it, still browsing.
                closingBarGap = true
                write(surface.maxOffsetY, animated: false, on: surface, by: "close bar gap")
                closingBarGap = false
                captureAnchor(on: surface)
            }
        }
        if mode != .following { pinOwed = false }
        insetAtDragStart = nil
        emit(.persistSnapshot(renderedSessionKey))
        // A fling saves once it comes to rest (`isUserScrolling`).
        if surface?.isDecelerating != true {
            emit(.flushPersistence)
        }
    }

    // MARK: - Opening and closing rows

    /// The reader is about to open or close a row (Thinking, a tool card,
    /// "Show all"), `rowID` when the row has one. The row they tapped must
    /// stay where it is, which following would undo by pinning the new end,
    /// so this is the reader taking over, like a drag: browsing, on the row
    /// they tapped, else the row at the screen's top, so what's above the
    /// toggle doesn't move. Once the row has animated, a reader still at the
    /// end (the row was short, or it closed) follows again.
    func userWillToggleRow(_ rowID: String? = nil) {
        // Momentum is not excluded: following would pin the opened row's
        // new end as soon as the momentum ended.
        guard !isPaused, !isDragging, surface?.isTracking != true else { return }
        cancelLatestAnimation()
        replyStartLandingPending = false
        landedAtReplyStart = false
        if restoration != nil {
            dropRestoration()
            emit(.cancelAutomaticRestoration)
        }
        let wasBrowsing = mode == .browsing
        let choice: AnchorChoice = rowID.map(AnchorChoice.row) ?? .topOfScreen
        setMode(.browsing, anchoringOn: choice)
        // Already browsing, the mode keeps its anchor.
        if wasBrowsing, let surface { captureAnchor(on: surface, choosing: choice) }
        if !wasBrowsing { emit(.persistSnapshot(renderedSessionKey)) }
        cancelDisclosureSettle()
        let generation = disclosureGeneration
        schedule(Self.disclosureSettleDelay) { [weak self] in
            guard let self, generation == self.disclosureGeneration else { return }
            self.disclosureSettled()
        }
    }

    private func disclosureSettled() {
        guard mode == .browsing, !isPaused, !isDragging, let surface,
              !surface.isTracking, !surface.isDecelerating,
              surface.distanceFromBottom <= Self.nearBottomTolerance else { return }
        setMode(.following)
        pin(surface)
        emit(.persistSnapshot(renderedSessionKey))
    }

    // MARK: - Session identity

    /// A different conversation is rendered (session or profile change,
    /// first appearance, or a notification opening one). A real switch lands
    /// on the latest message, unanimated.
    func renderedSessionChanged(
        to key: ChatScrollSessionKey?,
        identity: ChatScrollSessionIdentity,
        viaNotification: Bool,
        viewportTransitionGeneration: UInt64
    ) {
        self.identity = identity
        activeSessionKey = key
        mirroredViewportTransitionGeneration = viewportTransitionGeneration
        defer { renderInputsMayHaveChanged() }

        if let request = restoration?.request,
           viaNotification || !identity.areEquivalent(request.sessionKey, key) {
            dropRestoration()
            if mode == .restoring { setMode(.following) }
            emit(.cancelAutomaticRestoration)
        }
        if renderedSessionKey == nil, key == nil { return }

        let previous = renderedSessionKey
        renderedSessionKey = key
        // Adopting the first key is not a switch, and the same key or an
        // equivalent spelling of the same conversation is not one either.
        if !viaNotification, previous == nil || previous == key || identity.areEquivalent(previous, key) {
            return
        }
        ChatViewportTrace.shared.log("switch")
        cancelLatestAnimation()
        cancelDisclosureSettle()
        anchor = nil
        topVisibleMessageID = nil
        // The new conversation's first transcript names its latest user
        // message without arming; an open with an unread reply asks for its
        // landing after this, or in the same update when it lands from its
        // saved rows: that landing, asked for by this switch's transition,
        // stays.
        replyHoldArmed = false
        latestUserRowID = nil
        if replyStartLandingGeneration == nil || replyStartLandingGeneration != viewportTransitionGeneration {
            replyStartLandingPending = false
        }
        landedAtReplyStart = false
        refreshTrackedMessageVisibility()
        guard !isDragging else {
            setMode(.browsing)
            return
        }
        setMode(.following)
        pinIfShown()
    }

    /// Adopts the canonical spelling of the rendered conversation's key.
    func activeIdentityRefreshed(
        identity: ChatScrollSessionIdentity,
        key: ChatScrollSessionKey?
    ) {
        self.identity = identity
        activeSessionKey = key ?? activeSessionKey
        if let key, identity.areEquivalent(renderedSessionKey, key) {
            renderedSessionKey = key
        }
        renderInputsMayHaveChanged()
    }

    /// A notification is opening a conversation: it lands on the latest
    /// message, so a restoration waiting gives way.
    func notificationHandoffBegan() {
        dropRestoration()
        // A new open goes to the end: an earlier landing or hold no longer
        // keeps it away.
        disarmReplyHold()
        emit(.cancelAutomaticRestoration)
        guard !isDragging else { return }
        setMode(.following)
        pinIfShown()
    }

    func notificationHandoffFinished() {
        // An unread reply the open landed on (or is about to) stays put.
        guard !isDragging, restoration == nil,
              !replyStartLandingPending, !landedAtReplyStart else { return }
        setMode(.following)
        pinIfShown()
    }

    // MARK: - Transcript

    func transcriptChanged(
        messages: [ChatMessage],
        transcriptRevision: UInt64,
        viewportTransitionGeneration: UInt64,
        isInitialSync: Bool = false,
        isProvisional: Bool = false,
        activeSessionKey: ChatScrollSessionKey? = nil
    ) {
        ChatViewportTrace.shared.log("transcript n=\(messages.count) revision \(transcriptRevision)")
        ChatViewportWatch.shared.transcriptChanged()
        TranscriptPerf.note(.transcriptChanged)
        if let activeSessionKey {
            self.activeSessionKey = activeSessionKey
        }
        let update = targetCache.update(for: messages)
        renderedTranscriptRevision = transcriptRevision
        mirroredViewportTransitionGeneration = viewportTransitionGeneration
        let followsProvisionalRows = transcriptIsProvisional
        transcriptIsProvisional = isProvisional
        defer { renderInputsMayHaveChanged() }
        if update != .unchanged {
            targetIDs = Set(targetCache.targets.map(\.id))
            noteLatestUserRow(arming: !isInitialSync && !followsProvisionalRows)
            if replyStartLandingPending {
                schedule(0) { [weak self] in
                    self?.landAtReplyStartIfPending()
                }
            }
            if mode == .following, !isInitialSync, let surface, !isPaused, canPinWhileFollowing(surface) {
                // Usually a no-op: the new rows have not been laid out yet,
                // and the pass that lays them out pins again.
                pin(surface)
            }
        }
        // The rows a saved place waited for may be these.
        placeRestorationIfReady()
    }

    // MARK: - Explicit commands

    /// Send, or the jump-to-latest button. `animated` is honored only for a
    /// short distance. A send arms the reply hold for the answer to come;
    /// the button goes to the end, past any hold.
    func explicitLatestRequested(animated: Bool, armsReplyHold: Bool = false) {
        // A finger on the transcript wins over a command.
        if surface?.isTracking == true { return }
        dropRestoration()
        replyHoldArmed = armsReplyHold
        replyRoomArmed = armsReplyHold
        replyStartLandingPending = false
        landedAtReplyStart = false
        cancelDisclosureSettle()
        emit(.cancelAutomaticRestoration)
        setMode(.following)
        // In the background, setPaused(false) catches up and pins; with no
        // surface yet, attaching it does.
        guard !isPaused, let surface else { return }
        let distance = surface.distanceFromBottom
        if animated, !prefersReducedMotion(), distance > 0.5, distance <= surface.viewportHeight * 3 {
            startLatestAnimation(to: surface.maxOffsetY, on: surface, by: "latest")
        } else {
            cancelLatestAnimation()
            // A send's hold is for the message being sent. Its row may reach
            // the scroller after this command, and the stop of the message
            // before it would leave the reader browsing above the new one.
            pin(surface, ignoringHold: armsReplyHold)
        }
        refreshTrackedMessageVisibility()
        refreshJumpButton()
    }

    /// A row the reader asked for (the answerable clarification): at the
    /// top, browsing there, so later rows don't move it. The pause guard is
    /// defensive: a backgrounded screen can't be tapped, and a stale jump
    /// isn't replayed when the app returns.
    func explicitMessageRequested(id: String) {
        guard !id.isEmpty,
              !isPaused,
              let surface,
              !surface.isTracking,
              targetIDs.contains(id),
              let frame = surface.frame(ofRow: id) else { return }
        dropRestoration()
        cancelLatestAnimation()
        disarmReplyHold()
        cancelDisclosureSettle()
        emit(.cancelAutomaticRestoration)
        setMode(.browsing)
        let target = surface.clampedOffsetY(frame.minY - surface.insetTop)
        if abs(surface.contentOffsetY - target) > 0.5 {
            write(target, animated: false, on: surface, by: "message")
        }
        if mode == .browsing { captureAnchor(on: surface, choosing: .row(id)) }
        refreshTrackedMessageVisibility()
        refreshJumpButton()
    }

    /// Conversation-title tap: go to the top of the conversation.
    func explicitTopRequested() {
        if surface?.isTracking == true { return }
        dropRestoration()
        cancelLatestAnimation()
        disarmReplyHold()
        cancelDisclosureSettle()
        emit(.cancelAutomaticRestoration)
        setMode(.browsing)
        guard !isPaused, let surface else { return }
        if abs(surface.contentOffsetY - surface.minOffsetY) > 0.5 {
            write(surface.minOffsetY, animated: false, on: surface, by: "top")
            if mode == .browsing { captureAnchor(on: surface) }
        } else {
            // Already there (a short chat): no offset change will report,
            // so following is weighed here.
            surfaceScrolled()
        }
    }

    /// Settings > Chat's Long replies switch changed (here or synced from
    /// another device): the room under a sent message goes or comes back
    /// now, not at the next layout.
    func replyStartPreferenceChanged() {
        refreshReplyRoom()
        guard !isPaused, let surface, canPinWhileFollowing(surface), !isDragging else { return }
        pin(surface)
        refreshJumpButton()
    }

    // MARK: - Opening an unread reply

    /// An unread chat was opened and its transcript is in: it lands at the
    /// start of its latest reply, where the reply would have stopped had
    /// the chat been open (#365). Runs on the next turn, so the transcript,
    /// and the end of a notification's handoff, reach the scroller first.
    /// `viewportTransitionGeneration`: the open's transition, when it asks
    /// before its switch reaches the scroller (it lands from saved rows).
    func replyStartLandingRequested(viewportTransitionGeneration: UInt64? = nil) {
        guard holdsRepliesAtStart() else { return }
        replyStartLandingPending = true
        replyStartLandingGeneration = viewportTransitionGeneration
        schedule(0) { [weak self] in
            self?.landAtReplyStartIfPending()
        }
    }

    private func landAtReplyStartIfPending() {
        // With no surface yet, attaching one lands; in the background, the
        // return does; a transcript without the user's message yet, its
        // arrival.
        let targets = targetCache.targets
        guard replyStartLandingPending, let surface, !isPaused,
              let userIndex = targets.lastIndex(where: { $0.message.role == .user }) else { return }
        replyStartLandingPending = false
        // Switched off since the request.
        guard holdsRepliesAtStart() else { return }
        // A reader who already scrolled, or a restoration placing them,
        // keeps their place.
        guard mode == .following, !isUserScrolling, restoration == nil else { return }
        let userRowID = targets[userIndex].id
        latestUserRowID = userRowID
        replyHoldArmed = true
        // The reply is already there: no room under it.
        replyRoomArmed = false
        landedAtReplyStart = true
        ChatViewportTrace.shared.log("landing at reply start")
        // The user's message not drawn yet: following stops at the hold once
        // it is.
        guard let hold = replyHoldOffset(on: surface) else { return }
        let target = surface.clampedOffsetY(hold)
        // A short reply ends within reach: following, the hold left armed
        // for it to stop at as it grows.
        if surface.maxOffsetY - target > Self.nearBottomTolerance {
            setMode(.browsing)
            emit(.persistSnapshot(renderedSessionKey))
        }
        if abs(surface.contentOffsetY - target) > 0.5 {
            write(target, animated: false, on: surface, by: "reply start")
        }
        if mode == .browsing { captureAnchor(on: surface, choosing: .row(userRowID)) }
        refreshTrackedMessageVisibility()
        refreshJumpButton()
    }

    // MARK: - Automatic restoration

    /// A saved place to put the reader back at (the chat they left, its
    /// pending question), asked for when the transcript was at
    /// `transcriptRevision`. It's placed once those rows are drawn and its
    /// row has a frame: now, or at the pass, transcript or return from the
    /// background that brings them. `restorationDeadline` gives up.
    func restorationRequested(_ request: ChatResumeRestorationRequest, transcriptRevision: UInt64) {
        guard identity.areEquivalent(request.sessionKey, renderedSessionKey ?? activeSessionKey) else {
            emit(.abandonRestoration(generation: request.generation))
            return
        }
        cancelLatestAnimation()
        cancelDisclosureSettle()
        restoration = Restoration(request: request, transcriptRevision: transcriptRevision)
        setMode(.restoring)
        // A replacement request keeps the mode but changes the generation
        // the rendered scope reports.
        renderInputsMayHaveChanged()
        scheduleRestorationDeadline()
        placeRestorationIfReady()
    }

    /// The published request went away on the AppState side.
    func restorationSystemCancelled() {
        guard restoration != nil else { return }
        dropRestoration()
        leaveRestoring()
    }

    private func placeRestorationIfReady() {
        guard let state = restoration, let surface, !isPaused,
              renderedTranscriptRevision >= state.transcriptRevision,
              identity.areEquivalent(state.request.sessionKey, renderedSessionKey ?? activeSessionKey) else { return }
        switch resolveRestorationDestination(for: state.request) {
        case .latest:
            dropRestoration()
            setMode(.following)
            pin(surface)
        case .anchor(let id):
            guard let frame = surface.frame(ofRow: id) else { return }
            dropRestoration()
            ChatViewportTrace.shared.log("restore at \(id)")
            let target = surface.clampedOffsetY(frame.minY - surface.insetTop)
            if surface.maxOffsetY - target <= Self.nearBottomTolerance {
                setMode(.following)
                pin(surface)
            } else {
                setMode(.browsing)
                if abs(surface.contentOffsetY - target) > 0.5 {
                    write(target, animated: false, on: surface, by: "restore")
                }
                if mode == .browsing { captureAnchor(on: surface, choosing: .row(id)) }
            }
            topVisibleMessageID = id
        }
        emit(.persistSnapshot(state.request.sessionKey))
        emit(.completeRestoration(generation: state.request.generation))
        refreshTrackedMessageVisibility()
        refreshJumpButton()
    }

    private func scheduleRestorationDeadline() {
        restorationWaited = 0
        armRestorationDeadline()
    }

    /// Arms the deadline for the foreground time the saved place has left.
    /// A pause disarms it, so a timer that comes due in the background and
    /// runs on the return, before the scroller hears of the return, does
    /// nothing.
    private func armRestorationDeadline() {
        restorationDeadlineGeneration &+= 1
        guard !isPaused else { return }
        let generation = restorationDeadlineGeneration
        restorationWaitResumed = now()
        schedule(max(0, Self.restorationDeadline - restorationWaited)) { [weak self] in
            guard let self, generation == self.restorationDeadlineGeneration,
                  let state = self.restoration else { return }
            ChatViewportTrace.shared.log("restore abandoned")
            self.dropRestoration()
            self.leaveRestoring()
            self.emit(.abandonRestoration(generation: state.request.generation))
        }
    }

    private func dropRestoration() {
        restoration = nil
        restorationDeadlineGeneration &+= 1
    }

    /// Following at the end, else browsing where the reader is.
    private func leaveRestoring() {
        guard mode == .restoring else { return }
        setMode(isNearBottom ? .following : .browsing)
    }

    // MARK: - Lifecycle

    func viewDisappeared() {
        // The view asks again on return if the request is still published.
        restorationSystemCancelled()
        isDragging = false
        cancelLatestAnimation()
        // A landing belongs to the open that asked for it. The hold stays
        // armed: the reply may still be running when the chat is back.
        replyStartLandingPending = false
        landedAtReplyStart = false
    }

    // MARK: - Snapshots

    func renderedViewportSnapshot() -> ChatRenderedViewportSnapshot? {
        guard let sessionKey = renderedSessionKey,
              let snapshot = ChatTitleScrollViewportSnapshot.make(
                followsLatest: isFollowingLatest,
                topVisibleID: topVisibleMessageID,
                topAnchorID: ChatTitleScrollAnchor.id(for: sessionKey),
                targets: targetCache.targets
              ) else { return nil }
        return ChatRenderedViewportSnapshot(sessionKey: sessionKey, snapshot: snapshot)
    }

    // MARK: - Browsing

    /// A browsing reader stays on their row: when rows above it change
    /// height, rows arrive above it (Load earlier) or it goes (a stand-in
    /// takes over), the offset moves by as much, in the pass that does it.
    /// A finger or a fling keeps going when the offset is set, so the row
    /// under it stays put too; past an end is theirs, to bounce back from.
    private func keepAnchor(on surface: TranscriptScrollSurface, barChanged: Bool) {
        guard let anchor, let target = offset(of: anchor, on: surface) else {
            captureAnchor(on: surface)
            return
        }
        if isUserScrolling {
            guard target >= surface.minOffsetY - 0.5, target <= surface.maxOffsetY + 0.5,
                  abs(target - surface.contentOffsetY) > 0.5 else { return }
            write(target, animated: false, on: surface, by: "keep row")
            return
        }
        // Rows under the reader went, and the end is above where their row
        // would put them: nothing there is worth staying on, so they're back
        // at the latest message, following it. A bar shrinking under them is
        // not that: they stay browsing at the new end.
        if target > surface.maxOffsetY + 0.5, !barChanged {
            setMode(.following)
            emit(.persistSnapshot(renderedSessionKey))
            pin(surface)
            return
        }
        let clamped = surface.clampedOffsetY(target)
        if abs(clamped - surface.contentOffsetY) > 0.5 {
            closingBarGap = barChanged
            write(clamped, animated: false, on: surface, by: barChanged ? "close bar gap" : "keep row")
            closingBarGap = false
        }
        // Held short of their row by an end: the reader is where they ended
        // up, which the next pass keeps.
        if abs(clamped - target) > 0.5, mode == .browsing {
            captureAnchor(on: surface)
        }
    }

    /// The offset that puts the anchor's first row still drawn where the
    /// anchor has it.
    private func offset(of anchor: Anchor, on surface: TranscriptScrollSurface) -> CGFloat? {
        for place in anchor.places {
            if let frame = surface.frame(ofRow: place.id) {
                return frame.minY - place.top - surface.insetTop
            }
        }
        return nil
    }

    private func captureAnchor(on surface: TranscriptScrollSurface, choosing choice: AnchorChoice = .firstOnScreen) {
        let band = surface.visibleBand
        let top = band.lowerBound
        let onScreen = surface.rows(crossing: band)
        let startsOnScreen = onScreen.firstIndex { $0.minY >= top - 0.5 }
        let first: Int?
        switch choice {
        case .firstOnScreen:
            first = startsOnScreen
        case .topOfScreen:
            first = nil
        case .row(let id):
            first = onScreen.firstIndex { $0.id == id }
        }
        var rows: [TranscriptRowFrame] = []
        if let first {
            rows.append(onScreen[first])
            rows.append(contentsOf: onScreen[(first + 1)...])
            rows.append(contentsOf: onScreen[..<first].reversed())
        } else {
            rows = onScreen
        }
        // The row above stands in when everything on screen goes (a reply
        // filling the screen settling into the chat's own row).
        let above = surface.rows(crossing: (top - surface.viewportHeight)...top)
            .last(where: { $0.maxY <= top + 0.5 })
        if let above, !rows.contains(where: { $0.id == above.id }) {
            rows.append(above)
        }
        // The Load earlier row stays first as a page lands under it, so
        // staying on it would take the reader to that page: it stands in
        // last.
        if let index = rows.firstIndex(where: { $0.id == TranscriptRow.loadEarlierID }) {
            rows.append(rows.remove(at: index))
        }
        anchor = rows.isEmpty ? nil : Anchor(places: rows.map { Anchor.Place(id: $0.id, top: $0.minY - top) })
    }

    /// The first of the chat's messages on screen, for the saved place.
    private func refreshTopVisibleRow(persist: Bool) {
        guard let surface else { return }
        let row = surface.rows(crossing: surface.visibleBand).first(where: { targetIDs.contains($0.id) })
        guard row?.id != topVisibleMessageID else { return }
        topVisibleMessageID = row?.id
        if persist {
            emit(.persistSnapshot(renderedSessionKey))
        }
    }

    // MARK: - Following

    /// Following, with no finger, momentum or animated move on the content.
    private func canPinWhileFollowing(_ surface: TranscriptScrollSurface) -> Bool {
        mode == .following && !surface.isTracking && !surface.isDecelerating && !latestAnimationInFlight
    }

    private func pinIfShown() {
        // In the background the offset is left alone; setPaused(false)
        // catches up and pins. With no surface yet, attaching one does.
        guard !isPaused, let surface else { return }
        pin(surface)
        refreshJumpButton()
    }

    private func pin(_ surface: TranscriptScrollSurface, ignoringHold: Bool = false) {
        pinOwed = false
        var target = surface.maxOffsetY
        var landsAtHold = false
        if !ignoringHold, let hold = replyHoldOffset(on: surface) {
            if replyRoomArmed, replyRoomHeight > 0, surface.contentHeight >= replyRoomHeight - 0.5 {
                replyRoomLaidOut = true
            }
            if surface.contentOffsetY > hold + 0.5 {
                // Already below the reply's start (the reader came back down
                // to its end): following goes on to the end.
                replyHoldArmed = false
            } else if replyRoomArmed, replyRoomLaidOut,
                      surface.contentHeight <= max(replyRoomHeight, surface.reservedContentHeight) + 0.5 {
                // The content is no taller than the room under the message:
                // the reply still fits there. The room may lag a pass behind
                // a keyboard or bar changing height, or a row shrinking, so
                // the end can sit a little above or below the stop for a
                // moment; what shows there is empty room, so the reader stays.
                target = hold
                landsAtHold = true
            } else if target > hold {
                // The reply runs past the screen: stop at its start, where
                // the pin of an earlier pass left off or just past it, never
                // above. Within the near-bottom distance this is still
                // following; past it, the reader is left browsing there, on
                // the message, and later growth below never moves them. The
                // hold stays armed: should the content shrink back under the
                // stop, following stops here again as the reply grows.
                target = hold
                if surface.maxOffsetY - hold > Self.nearBottomTolerance {
                    setMode(.browsing)
                    emit(.persistSnapshot(renderedSessionKey))
                }
            }
        }
        // The sent message's move to the top, once its room is there: one
        // animated move, after which the reply fills in below.
        let animates = replyRoomLanding && landsAtHold
            && target - surface.contentOffsetY > Self.nearBottomTolerance && !prefersReducedMotion()
        if landsAtHold { replyRoomLanding = false }
        guard abs(surface.contentOffsetY - target) > 0.5 else { return }
        if animates {
            startLatestAnimation(to: target, on: surface, by: "pin")
            return
        }
        write(target, animated: false, on: surface, by: "pin")
        if mode == .browsing { captureAnchor(on: surface) }
    }

    /// An animated move to the end (the jump button, a sent message moving
    /// to the top): no pin until it has landed, then one for what grew
    /// meanwhile.
    private func startLatestAnimation(to target: CGFloat, on surface: TranscriptScrollSurface, by rule: String) {
        latestAnimationGeneration &+= 1
        let generation = latestAnimationGeneration
        latestAnimationUntil = now() + Self.latestAnimationDuration
        write(target, animated: true, on: surface, by: rule)
        schedule(Self.latestAnimationDuration) { [weak self] in
            guard let self, generation == self.latestAnimationGeneration else { return }
            self.latestAnimationFinished()
        }
    }

    private func latestAnimationFinished() {
        guard latestAnimationUntil != nil else { return }
        latestAnimationUntil = nil
        guard mode == .following, let surface, !isPaused, !surface.isTracking else { return }
        pin(surface)
        refreshJumpButton()
    }

    private func cancelLatestAnimation() {
        latestAnimationUntil = nil
        latestAnimationGeneration &+= 1
    }

    // MARK: - Long replies

    /// Where following stops for the reply the hold is armed for: the
    /// offset that puts the user's latest message at the top of the
    /// viewport, `replyStartTopGap` below it, with the reply under it
    /// (#1436). A message taller than a third of the screen shows only its
    /// last third there. Nil while unarmed, switched off, or for a message
    /// the transcript doesn't draw (following then pins the end).
    private func replyHoldOffset(on surface: TranscriptScrollSurface) -> CGFloat? {
        guard replyHoldArmed, holdsRepliesAtStart(),
              let id = latestUserRowID, let frame = surface.frame(ofRow: id) else { return nil }
        let visibleHeight = surface.viewportHeight - surface.insetTop - surface.insetBottom
        let messageTop = frame.minY - surface.insetTop - Self.replyStartTopGap
        let messageTail = frame.maxY - surface.insetTop - visibleHeight / 3
        return max(surface.minOffsetY, messageTop, messageTail)
    }

    /// The content height that makes the stop reachable while the reply
    /// still fits under the message: the stop plus a screen. A message not
    /// drawn yet keeps the room that is there: a send lands in the room the
    /// last reply left, and nothing moves until the new message's own room
    /// is known.
    private func refreshReplyRoom() {
        var height: CGFloat = 0
        if replyRoomArmed, holdsRepliesAtStart() {
            guard let surface, let hold = replyHoldOffset(on: surface) else { return }
            height = (hold + surface.viewportHeight - surface.insetBottom).rounded(.up)
        }
        guard height != replyRoomHeight else { return }
        ChatViewportTrace.shared.log(String(format: "replyRoom minContentHeight %.1f", height))
        replyRoomHeight = height
        surface?.reserveContentHeight(height)
    }

    private func disarmReplyHold() {
        replyHoldArmed = false
        replyStartLandingPending = false
        landedAtReplyStart = false
    }

    /// Follows the transcript's latest user message. A new one in a live
    /// transcript (a turn started on another device, or a send's row) arms
    /// the hold; the first transcript of a conversation only names it.
    private func noteLatestUserRow(arming: Bool) {
        let latest = targetCache.targets.last(where: { $0.message.role == .user })?.id
        guard latest != latestUserRowID else { return }
        let previous = latestUserRowID
        latestUserRowID = latest
        // No user message left to stop under (the transcript was cleared).
        if latest == nil { replyHoldArmed = false }
        if arming, previous != nil, latest != nil {
            replyHoldArmed = true
            replyRoomArmed = true
        }
    }

    // MARK: - Private

    /// Every offset the scroller writes: the recorder names the rule that
    /// asked, and ChatViewportWatch takes the move it makes as asked for.
    private func write(_ y: CGFloat, animated: Bool, on surface: TranscriptScrollSurface, by rule: String) {
        ChatViewportTrace.shared.log(String(
            format: "write %@: %.1f -> %.1f%@ (content %.1f, viewport %.1f)",
            rule, surface.contentOffsetY, y, animated ? " animated" : "", surface.contentHeight, surface.viewportHeight
        ))
        writeDepth += 1
        defer { writeDepth -= 1 }
        ChatViewportWatch.shared.scrollerWrites(animated: animated) {
            surface.setContentOffsetY(y, animated: animated)
        }
    }

    /// Browsing starts on the row the reader is on (`choice`); leaving it
    /// forgets the row, and any pin owed to following.
    private func setMode(_ newMode: Mode, anchoringOn choice: AnchorChoice = .firstOnScreen) {
        guard mode != newMode else { return }
        mode = newMode
        if newMode == .browsing {
            pinOwed = false
            if let surface { captureAnchor(on: surface, choosing: choice) }
        } else {
            anchor = nil
        }
        refreshJumpButton()
        renderInputsMayHaveChanged()
    }

    private func emit(_ event: TranscriptScrollerEvent) {
        onEvent?(event)
    }

    private func cancelDisclosureSettle() {
        disclosureGeneration &+= 1
    }

    /// Publishes `renderInputs` and `chrome` if any of their values changed.
    /// A change made while handling a UIKit callback can land in the middle
    /// of a SwiftUI update, where publishing is not allowed, so it goes out
    /// on the next main-queue turn instead (coalesced).
    private func renderInputsMayHaveChanged() {
        guard isHandlingSurfaceCallback else {
            publishRenderInputs()
            return
        }
        guard !renderInputsPublishScheduled else { return }
        renderInputsPublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderInputsPublishScheduled = false
            self.publishRenderInputs()
        }
    }

    private func publishRenderInputs() {
        let inputs = ChatScrollRenderInputs(
            renderedSessionKey: renderedSessionKey,
            renderedScrollScope: renderedScrollScope,
            targetsRevision: targetCache.renderingRevision
        )
        if inputs != renderInputs {
            renderInputs = inputs
        }
        let chromeInputs = ChatScrollChromeInputs(
            isFollowingLatest: isFollowingLatest,
            showsJumpToLatest: showsJumpToLatest,
            visibilityTrackedMessageID: visibilityTrackedMessageID,
            isVisibilityTrackedMessageOffscreen: isVisibilityTrackedMessageOffscreen
        )
        if chromeInputs != chrome.inputs {
            chrome.inputs = chromeInputs
        }
    }

    private func refreshJumpButton() {
        let shows = mode == .browsing
            && (surface?.distanceFromBottom ?? 0) > Self.nearBottomTolerance
        guard shows != showsJumpToLatest else { return }
        showsJumpToLatest = shows
        renderInputsMayHaveChanged()
    }

    private func refreshTrackedMessageVisibility(forcePublish: Bool = false) {
        let isOffscreen: Bool
        if let id = visibilityTrackedMessageID,
           let surface,
           let frame = surface.frame(ofRow: id) {
            let band = surface.visibleBand
            isOffscreen = !(frame.maxY > band.lowerBound && frame.minY < band.upperBound)
        } else {
            // A row without a frame isn't drawn, so the jump to it is
            // still useful.
            isOffscreen = visibilityTrackedMessageID != nil
        }
        let visibilityChanged = isVisibilityTrackedMessageOffscreen != isOffscreen
        isVisibilityTrackedMessageOffscreen = isOffscreen
        guard forcePublish || visibilityChanged else { return }
        renderInputsMayHaveChanged()
    }

    private func resolveRestorationDestination(
        for request: ChatResumeRestorationRequest
    ) -> ChatResumeViewportDestination {
        switch request.destination {
        case .latest:
            return .latest
        case .snapshot(let snapshot):
            return resolveSnapshotRestorationDestination(snapshot)
        case .pendingClarify(let messageID, let fallbackSnapshot):
            if let target = targetCache.targets.first(where: { $0.id == messageID }),
               let clarify = target.message.clarify,
               clarify.needsAnswer {
                return .anchor(messageID)
            }
            // The answer may have landed after reconciliation selected this
            // row; prefer the saved viewport to restoring a resolved card.
            guard let fallbackSnapshot else { return .latest }
            return resolveSnapshotRestorationDestination(fallbackSnapshot)
        }
    }

    private func resolveSnapshotRestorationDestination(
        _ snapshot: ChatScrollSnapshot
    ) -> ChatResumeViewportDestination {
        // The resolver speaks semantic ids; rows are keyed by message id.
        let resolved = ChatResumeViewportResolver.destination(
            for: snapshot,
            availableTargets: ChatScrollTargetAvailability(targets: targetCache.targets)
        )
        switch resolved {
        case .latest:
            return .latest
        case .anchor(let semanticAnchor):
            let sourceAnchor = targetCache.targets
                .first { $0.semanticID == semanticAnchor }?.restorationAnchorID ?? semanticAnchor
            return .anchor(sourceAnchor)
        }
    }
}
