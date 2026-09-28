import UIKit

/// The scroll view the chat transcript renders in, reduced to what
/// ChatScrollEngine reads and writes. The app backs it with the UIScrollView
/// SwiftUI already uses for the transcript (ChatScrollSurfaceLocator); tests
/// use a fake.
@MainActor
protocol ChatScrollSurface: AnyObject {
    var contentOffsetY: CGFloat { get }
    var contentHeight: CGFloat { get }
    var viewportHeight: CGFloat { get }
    var insetTop: CGFloat { get }
    var insetBottom: CGFloat { get }
    var isTracking: Bool { get }
    var isDecelerating: Bool { get }
    /// Content-space y of the transcript stack's origin. Row frames are
    /// reported in the stack's own coordinate space; adding this puts them in
    /// the scroll view's content space.
    var transcriptOriginY: CGFloat { get }
    func setContentOffsetY(_ y: CGFloat, animated: Bool)
}

extension ChatScrollSurface {
    var minOffsetY: CGFloat { -insetTop }

    var maxOffsetY: CGFloat {
        max(minOffsetY, contentHeight + insetBottom - viewportHeight)
    }

    var distanceFromBottom: CGFloat { maxOffsetY - contentOffsetY }

    func clampedOffsetY(_ y: CGFloat) -> CGFloat {
        min(max(y, minOffsetY), maxOffsetY)
    }
}

/// Frame of one rendered message row in the transcript stack's coordinate
/// space. These frames only change when layout changes, not on every scroll
/// tick. `order` is the row's transcript position.
struct ChatScrollRowFrame: Equatable {
    let minY: CGFloat
    let maxY: CGFloat
    let order: Int
}

/// What the engine asks its view to do. Everything else (following, prepend
/// anchoring, restoration placement) the engine does directly on the surface.
enum ChatScrollEngineEvent: Equatable {
    case persistSnapshot(ChatScrollSessionKey?)
    case flushPersistence
    case cancelAutomaticRestoration
    case completeRestoration(generation: UInt64)
    case abandonRestoration(generation: UInt64)
    /// A row that has not been laid out yet: the view asks SwiftUI to scroll
    /// it into place (ScrollViewProxy) so it gets a frame.
    case revealRow(id: String)
    /// No surface is attached yet; the view falls back to ScrollViewProxy.
    case revealLatest
    case revealTop
}

/// The viewport values ChatView renders from. Published only when one of
/// them changes, so scrolling itself never re-evaluates the chat.
struct ChatScrollRenderInputs: Equatable {
    var renderedSessionKey: ChatScrollSessionKey?
    var isFollowingLatest = true
    var renderedScrollScope: ChatRenderedScrollScope?
    var showsJumpToLatest = false
}

/// Owns the chat viewport. Three rules replace the old follow-correction
/// machinery:
///
/// 1. Following latest: whenever the content or viewport size changes, the
///    offset is set to the bottom in the same layout pass (UIKit's KVO fires
///    while SwiftUI lays out, before anything is drawn). No animation, no
///    retries, no corrections on a later turn, so there is nothing to
///    overshoot or snap.
/// 2. Browsing: the offset is left alone. UIKit keeps the distance from the
///    top, so messages arriving below never move what the user is reading.
///    The one change above the reader, a "Load earlier messages" prepend,
///    keeps the distance from the bottom instead.
/// 3. Only the user leaves following (a drag), and only being near the
///    bottom (or an explicit command) returns to it.
@MainActor
final class ChatScrollEngine: ObservableObject {
    enum Mode: Equatable {
        case following
        case browsing
        case restoring
    }

    struct Restoration: Equatable {
        let request: ChatResumeRestorationRequest
        var destination: ChatResumeViewportDestination
        var checks = 0
        var lastRevealCheck: Int?
        var placed = false
    }

    struct PrependAnchor: Equatable {
        let sessionKey: ChatScrollSessionKey?
        /// Content height minus offset when the backfill was requested: the
        /// distance from the content bottom to the viewport top. Keeping it
        /// constant keeps every row below the prepended page in place.
        let bottomDistance: CGFloat
        var landedAt: TimeInterval?
    }

    static let nearBottomTolerance: CGFloat = 40
    static let maximumRestorationChecks = 80
    static let restorationRevealInterval = 4
    /// How long a landed prepend keeps holding the reader's position while
    /// the prepended rows' estimated heights settle.
    static let prependHoldDuration: TimeInterval = 0.6
    /// How long an animated jump to latest suspends pinning.
    static let latestAnimationDuration: TimeInterval = 0.4
    static let coordinateSpaceName = "chat-transcript-stack"

    var onEvent: (@MainActor (ChatScrollEngineEvent) -> Void)?
    @Published private(set) var renderInputs = ChatScrollRenderInputs()
    private var renderInputsPublishScheduled = false

    private(set) var mode: Mode = .following
    private(set) var identity: ChatScrollSessionIdentity = .none
    private(set) var renderedSessionKey: ChatScrollSessionKey?
    private(set) var activeSessionKey: ChatScrollSessionKey?
    private(set) var renderedTranscriptRevision: UInt64 = 0
    private var mirroredViewportTransitionGeneration: UInt64 = 0
    private(set) var targetCache = ChatMessageScrollTargetCache()
    private(set) var restoration: Restoration?
    private(set) var prependAnchor: PrependAnchor?
    private(set) var topVisibleMessageID: String?
    private(set) var showsJumpToLatest = false
    private(set) var isPaused = false
    private(set) var isDragging = false
    private var latestAnimationUntil: TimeInterval?
    private var rowFrames: [String: ChatScrollRowFrame] = [:]
    private(set) weak var surface: ChatScrollSurface?
    private var surfaceCallbackDepth = 0
    private let now: () -> TimeInterval
    private let prefersReducedMotion: @MainActor () -> Bool

    init(
        now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
        prefersReducedMotion: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    ) {
        self.now = now
        self.prefersReducedMotion = prefersReducedMotion
    }

    // MARK: - Derived facts

    var targets: [ChatMessageScrollTarget] { targetCache.targets }

    var isFollowingLatest: Bool { mode == .following }

    var restorationIsActive: Bool { restoration != nil }

    /// True while handling a callback from UIKit (scroll view KVO or the pan
    /// gesture). Those can arrive in the middle of a SwiftUI update, so the
    /// view defers state writes and AppState calls made from them.
    var isHandlingSurfaceCallback: Bool { surfaceCallbackDepth > 0 }

    var isNearBottom: Bool {
        guard let surface else { return true }
        return surface.distanceFromBottom <= Self.nearBottomTolerance
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

    // MARK: - Surface

    func attach(_ surface: ChatScrollSurface) {
        self.surface = surface
        surfaceLayoutChanged()
    }

    func detach(_ surface: ChatScrollSurface) {
        guard self.surface === surface else { return }
        self.surface = nil
    }

    /// Content size, viewport size or insets changed. Runs inside the layout
    /// pass that changed them.
    func surfaceLayoutChanged() {
        TranscriptPerf.note(.layoutMetricsChanged)
        surfaceCallbackDepth += 1
        defer { surfaceCallbackDepth -= 1 }
        guard let surface, !isPaused else { return }
        holdPrependAnchor(on: surface)
        if mode == .following,
           !surface.isTracking,
           !surface.isDecelerating,
           !latestAnimationInFlight {
            pin(surface)
        }
        refreshJumpButton()
    }

    /// The offset changed (user scroll, deceleration, or one of ours).
    func surfaceScrolled() {
        surfaceCallbackDepth += 1
        defer { surfaceCallbackDepth -= 1 }
        guard let surface, !isPaused else { return }
        if mode != .following {
            refreshTopVisibleRow(persist: mode == .browsing)
        }
        if mode == .browsing,
           !surface.isTracking,
           surface.distanceFromBottom <= Self.nearBottomTolerance {
            setMode(.following)
            emit(.persistSnapshot(renderedSessionKey))
        }
        refreshJumpButton()
    }

    func rowFramesChanged(_ frames: [String: ChatScrollRowFrame]) {
        rowFrames = frames
        guard mode == .browsing, !isPaused else { return }
        refreshTopVisibleRow(persist: true)
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        guard !paused else { return }
        // Catch up on whatever changed while backgrounded.
        surfaceLayoutChanged()
        surfaceScrolled()
    }

    // MARK: - User drag

    func userDragBegan() {
        surfaceCallbackDepth += 1
        defer { surfaceCallbackDepth -= 1 }
        isDragging = true
        latestAnimationUntil = nil
        prependAnchor = nil
        restoration = nil
        emit(.cancelAutomaticRestoration)
        if mode != .browsing {
            setMode(.browsing)
            emit(.persistSnapshot(renderedSessionKey))
        }
    }

    func userDragEnded() {
        surfaceCallbackDepth += 1
        defer { surfaceCallbackDepth -= 1 }
        isDragging = false
        if mode == .browsing,
           let surface,
           !surface.isDecelerating,
           surface.distanceFromBottom <= Self.nearBottomTolerance {
            setMode(.following)
        }
        emit(.persistSnapshot(renderedSessionKey))
        emit(.flushPersistence)
    }

    // MARK: - Session identity

    /// A different conversation is rendered (session or profile change,
    /// first appearance, or a notification opening one). A real switch lands
    /// on the latest message unanimated.
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
            restoration = nil
            if mode == .restoring { mode = .following }
            emit(.cancelAutomaticRestoration)
        }
        if renderedSessionKey == nil, key == nil { return }

        let previous = renderedSessionKey
        renderedSessionKey = key
        // Adopting the first key is not a switch, and an equivalent spelling
        // of the same conversation is not one either.
        if !viaNotification, previous == nil || identity.areEquivalent(previous, key) {
            return
        }
        prependAnchor = nil
        latestAnimationUntil = nil
        topVisibleMessageID = nil
        rowFrames = [:]
        guard !isDragging else {
            mode = .browsing
            return
        }
        mode = .following
        pinOrReveal()
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
    /// message, so an automatic restoration in flight gives way.
    func notificationHandoffBegan() {
        if restoration != nil {
            restoration = nil
        }
        emit(.cancelAutomaticRestoration)
        guard !isDragging else { return }
        setMode(.following)
        pinOrReveal()
    }

    func notificationHandoffFinished() {
        guard !isDragging, restoration == nil else { return }
        setMode(.following)
        pinOrReveal()
    }

    // MARK: - Transcript

    func transcriptChanged(
        messages: [ChatMessage],
        transcriptRevision: UInt64,
        viewportTransitionGeneration: UInt64,
        isInitialSync: Bool = false,
        activeSessionKey: ChatScrollSessionKey? = nil
    ) {
        TranscriptPerf.note(.transcriptChanged)
        if let activeSessionKey {
            self.activeSessionKey = activeSessionKey
        }
        let frontRowBefore = targetCache.targets.first?.id
        let update = targetCache.update(for: messages)
        renderedTranscriptRevision = transcriptRevision
        mirroredViewportTransitionGeneration = viewportTransitionGeneration
        defer { renderInputsMayHaveChanged() }
        guard update != .unchanged else { return }

        if let anchor = prependAnchor, anchor.landedAt == nil {
            landPrependIfNeeded(anchor, frontRowBefore: frontRowBefore)
        }
        if var restoration {
            restoration.destination = resolveRestorationDestination(for: restoration.request)
            restoration.placed = false
            self.restoration = restoration
        }
        if mode == .following, !isInitialSync, let surface, !isPaused,
           !surface.isTracking, !latestAnimationInFlight {
            // Usually a no-op: the new rows have not been laid out yet, and
            // the content-size change that follows pins again.
            pin(surface)
        }
    }

    // MARK: - Older-page backfill

    /// "Load earlier messages" was tapped. Following needs nothing (content
    /// added above cannot move a bottom-pinned viewport); a reader in the
    /// middle keeps their distance from the content bottom.
    func olderPageBackfillRequested(sessionKey: ChatScrollSessionKey?) {
        guard mode == .browsing, let surface else { return }
        prependAnchor = PrependAnchor(
            sessionKey: sessionKey,
            bottomDistance: surface.contentHeight - surface.contentOffsetY
        )
    }

    /// The backfill finished without prepending anything.
    func prependAnchorDischarged(matching sessionKey: ChatScrollSessionKey?) {
        guard let anchor = prependAnchor, anchor.landedAt == nil else { return }
        if anchor.sessionKey == nil || identity.areEquivalent(anchor.sessionKey, sessionKey) {
            prependAnchor = nil
        }
    }

    // MARK: - Explicit commands

    /// Send, or the jump-to-latest button. `animated` is honored only for a
    /// short distance: a long animated scroll through lazily measured rows is
    /// what used to overshoot.
    func explicitLatestRequested(animated: Bool) {
        restoration = nil
        prependAnchor = nil
        emit(.cancelAutomaticRestoration)
        setMode(.following)
        guard let surface, !isPaused else {
            emit(.revealLatest)
            return
        }
        let distance = surface.distanceFromBottom
        if animated, !prefersReducedMotion(), distance > 0.5, distance <= surface.viewportHeight * 3 {
            latestAnimationUntil = now() + Self.latestAnimationDuration
            surface.setContentOffsetY(surface.maxOffsetY, animated: true)
        } else {
            latestAnimationUntil = nil
            pin(surface)
        }
        refreshJumpButton()
    }

    /// The view calls this once an animated jump to latest has had time to
    /// land; pins the final position in case the content grew meanwhile.
    func latestAnimationFinished() {
        guard latestAnimationUntil != nil else { return }
        latestAnimationUntil = nil
        guard mode == .following, let surface, !isPaused, !surface.isTracking else { return }
        pin(surface)
        refreshJumpButton()
    }

    /// Conversation-title tap: go to the top of the conversation.
    func explicitTopRequested() {
        restoration = nil
        prependAnchor = nil
        latestAnimationUntil = nil
        emit(.cancelAutomaticRestoration)
        setMode(.browsing)
        guard let surface, !isPaused else {
            emit(.revealTop)
            return
        }
        surface.setContentOffsetY(surface.minOffsetY, animated: false)
        surfaceScrolled()
    }

    // MARK: - Automatic restoration

    func restorationRequested(_ request: ChatResumeRestorationRequest) {
        guard identity.areEquivalent(request.sessionKey, renderedSessionKey ?? activeSessionKey) else {
            emit(.abandonRestoration(generation: request.generation))
            return
        }
        prependAnchor = nil
        latestAnimationUntil = nil
        restoration = Restoration(
            request: request,
            destination: resolveRestorationDestination(for: request)
        )
        setMode(.restoring)
    }

    /// The published request went away on the AppState side.
    func restorationSystemCancelled() {
        guard restoration != nil else { return }
        restoration = nil
        guard mode == .restoring else { return }
        setMode(isNearBottom ? .following : .browsing)
    }

    /// One placement attempt; the view calls this every 25 ms while it
    /// returns true.
    @discardableResult
    func restorationTick(transcriptRevision: UInt64) -> Bool {
        guard var state = restoration else { return false }
        state.checks += 1
        guard state.checks <= Self.maximumRestorationChecks else {
            restoration = nil
            setMode(isNearBottom ? .following : .browsing)
            emit(.abandonRestoration(generation: state.request.generation))
            return false
        }
        guard let surface,
              !isPaused,
              surface.contentHeight > 0,
              renderedTranscriptRevision == transcriptRevision,
              identity.areEquivalent(state.request.sessionKey, renderedSessionKey ?? activeSessionKey) else {
            restoration = state
            return true
        }

        switch state.destination {
        case .latest:
            restoration = nil
            setMode(.following)
            pin(surface)
            emit(.completeRestoration(generation: state.request.generation))
            emit(.persistSnapshot(state.request.sessionKey))
            return false
        case .anchor(let id):
            guard let frame = rowFrames[id] else {
                let reveal = state.lastRevealCheck.map {
                    state.checks - $0 >= Self.restorationRevealInterval
                } ?? true
                if reveal { state.lastRevealCheck = state.checks }
                restoration = state
                if reveal { emit(.revealRow(id: id)) }
                return true
            }
            let target = surface.clampedOffsetY(
                surface.transcriptOriginY + frame.minY - surface.insetTop
            )
            if state.placed, abs(surface.contentOffsetY - target) <= 1 {
                restoration = nil
                topVisibleMessageID = id
                setMode(surface.distanceFromBottom <= Self.nearBottomTolerance ? .following : .browsing)
                emit(.completeRestoration(generation: state.request.generation))
                return false
            }
            state.placed = true
            restoration = state
            surface.setContentOffsetY(target, animated: false)
            return true
        }
    }

    // MARK: - Lifecycle

    func viewDisappeared() {
        isDragging = false
        prependAnchor = nil
        latestAnimationUntil = nil
    }

    /// The last reported frame of a laid-out row, in the stack's space.
    func rowFrame(for id: String) -> ChatScrollRowFrame? {
        rowFrames[id]
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

    // MARK: - Private

    private var latestAnimationInFlight: Bool {
        latestAnimationUntil.map { now() < $0 } ?? false
    }

    private func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        refreshJumpButton()
        renderInputsMayHaveChanged()
    }

    private func emit(_ event: ChatScrollEngineEvent) {
        onEvent?(event)
    }

    /// Publishes `renderInputs` if any of them changed. A change made while
    /// handling a UIKit callback can land in the middle of a SwiftUI update,
    /// where publishing is not allowed, so it goes out on the next main-queue
    /// turn instead (coalesced).
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
            isFollowingLatest: isFollowingLatest,
            renderedScrollScope: renderedScrollScope,
            showsJumpToLatest: showsJumpToLatest
        )
        if inputs != renderInputs {
            renderInputs = inputs
        }
    }

    private func pin(_ surface: ChatScrollSurface) {
        let target = surface.maxOffsetY
        guard abs(surface.contentOffsetY - target) > 0.5 else { return }
        surface.setContentOffsetY(target, animated: false)
    }

    private func pinOrReveal() {
        if let surface, !isPaused {
            pin(surface)
        } else {
            emit(.revealLatest)
        }
        refreshJumpButton()
    }

    private func landPrependIfNeeded(_ anchor: PrependAnchor, frontRowBefore: String?) {
        // A prepend replaces the front row and keeps the old one. Streaming
        // or a turn completing leaves the front row alone and must not
        // consume the anchor.
        let targets = targetCache.targets
        guard targets.first?.id != frontRowBefore,
              frontRowBefore == nil || targets.contains(where: { $0.id == frontRowBefore }) else {
            return
        }
        guard mode == .browsing,
              anchor.sessionKey == nil || identity.areEquivalent(anchor.sessionKey, renderedSessionKey) else {
            prependAnchor = nil
            return
        }
        var landed = anchor
        landed.landedAt = now()
        prependAnchor = landed
    }

    private func holdPrependAnchor(on surface: ChatScrollSurface) {
        guard let anchor = prependAnchor, let landedAt = anchor.landedAt else { return }
        guard now() - landedAt <= Self.prependHoldDuration, mode == .browsing else {
            prependAnchor = nil
            return
        }
        guard !surface.isTracking else { return }
        let target = surface.clampedOffsetY(surface.contentHeight - anchor.bottomDistance)
        if abs(surface.contentOffsetY - target) > 0.5 {
            surface.setContentOffsetY(target, animated: false)
        }
    }

    private func refreshTopVisibleRow(persist: Bool) {
        guard let surface else { return }
        TranscriptPerf.stableTopScanTargetCount = rowFrames.count
        let visibleTop = surface.contentOffsetY + surface.insetTop - surface.transcriptOriginY
        let visibleBottom = surface.contentOffsetY + surface.viewportHeight
            - surface.insetBottom - surface.transcriptOriginY
        var best: (id: String, order: Int)?
        for (id, frame) in rowFrames where frame.maxY > visibleTop && frame.minY < visibleBottom {
            if best.map({ frame.order < $0.order }) ?? true {
                best = (id, frame.order)
            }
        }
        guard best?.id != topVisibleMessageID else { return }
        topVisibleMessageID = best?.id
        if persist {
            emit(.persistSnapshot(renderedSessionKey))
        }
    }

    private func refreshJumpButton() {
        let shows = mode != .following
            && (surface?.distanceFromBottom ?? 0) > Self.nearBottomTolerance
        guard shows != showsJumpToLatest else { return }
        showsJumpToLatest = shows
        renderInputsMayHaveChanged()
    }

    private func resolveRestorationDestination(
        for request: ChatResumeRestorationRequest
    ) -> ChatResumeViewportDestination {
        switch request.destination {
        case .latest:
            return .latest
        case .snapshot(let snapshot):
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
                    .first { $0.semanticID == semanticAnchor }?.id ?? semanticAnchor
                return .anchor(sourceAnchor)
            }
        }
    }
}
