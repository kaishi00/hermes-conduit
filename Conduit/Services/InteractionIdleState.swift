import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Whether anyone has used Conduit lately. An iPad left on the chat list all
/// night (often set to never auto-lock) would otherwise redraw the drifting
/// backdrop, and every glass surface sampling it, ten times a second until
/// morning. The backdrop holds still once nothing has happened for
/// `idleAfter`, and moves again on the next touch, keystroke, turn, voice
/// conversation or return to the app.
///
/// Not counted: trackpad or mouse-wheel scrolling (no touches), hardware keys
/// that don't change text (arrows, shortcuts, keyboard navigation) and
/// VoiceOver focus moves. Any of them is followed by a tap or typing soon
/// enough; the cost of missing one is a still backdrop, nothing else.
///
/// Main actor only. Only `isIdle` flips publish, so a touch never redraws
/// anything: it just moves the deadline. One timer runs at a time and fires
/// once at the deadline; a touch while it is pending only records the time,
/// and the timer checks again when it fires.
@MainActor
final class InteractionIdleState: ObservableObject {
    nonisolated static let idleAfter: TimeInterval = 120
    static let shared = InteractionIdleState()

    /// Schedules `fire` once after `delay` seconds and returns a cancel action.
    typealias Schedule = (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void

    @Published private(set) var isIdle = false

    private let idleAfter: TimeInterval
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private var lastActivity: TimeInterval
    /// The last touch, keystroke or return to the app. Unlike
    /// `lastActivity`, turn and voice edges don't move it.
    private var lastUse: TimeInterval
    private var turnIsRunning = false
    private var voiceConversationIsShown = false
    /// Cancels the one pending deadline timer; nil when none is scheduled.
    private var cancelPendingWake: (() -> Void)?
    /// Written once in init and read again only in deinit, which can't be
    /// main-actor isolated.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private let notificationCenter: NotificationCenter

    /// Something on screen is in use without touches: a running turn, or a
    /// hands-free voice call.
    private var isHeldAwake: Bool { turnIsRunning || voiceConversationIsShown }

    init(
        idleAfter: TimeInterval = InteractionIdleState.idleAfter,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Schedule = InteractionIdleState.runLoopSchedule,
        notificationCenter: NotificationCenter = .default
    ) {
        self.idleAfter = idleAfter
        self.now = now
        self.schedule = schedule
        self.notificationCenter = notificationCenter
        lastActivity = now()
        lastUse = lastActivity
        // Coming back to the app counts as using it. Typing counts too: a
        // hardware keyboard on an iPad sends no touches.
        let names: [Notification.Name] = [
            UIScene.didActivateNotification,
            UITextField.textDidChangeNotification,
            UITextView.textDidChangeNotification
        ]
        for name in names {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteInteraction() }
            })
        }
        scheduleWakeIfNeeded()
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    /// A touch, a keystroke or the app becoming active: wakes at once and
    /// pushes the deadline back.
    func noteInteraction() {
        lastUse = now()
        noteActivity()
    }

    /// Something happened on screen without the user: wakes the backdrop
    /// and pushes its deadline back, but isn't use (`usedWithin`).
    private func noteActivity() {
        lastActivity = now()
        if isIdle { isIdle = false }
        scheduleWakeIfNeeded()
    }

    /// Whether someone touched, typed in or returned to Conduit within the
    /// last `seconds`. Unlike `isIdle`, a turn or a voice conversation
    /// starting or ending doesn't count: the on-screen report
    /// (ChatOnScreen.swift) asks whether anyone is still looking, and a
    /// queued message sending itself after a turn is nobody.
    func usedWithin(_ seconds: TimeInterval) -> Bool {
        now() - lastUse <= seconds
    }

    /// AppState reports turn edges here, so nothing has to observe AppState
    /// (and redraw on every streamed token) to know a turn is running. A
    /// running turn holds Conduit awake; its end starts the countdown afresh.
    func setTurnRunning(_ running: Bool) {
        guard running != turnIsRunning else { return }
        turnIsRunning = running
        heldAwakeChanged()
    }

    /// A voice conversation on screen holds Conduit awake like a turn: a
    /// hands-free call on an iPad sets no turn and sends no touches, and the
    /// drifting backdrop shows around its sheet.
    func setVoiceConversationShown(_ shown: Bool) {
        guard shown != voiceConversationIsShown else { return }
        voiceConversationIsShown = shown
        heldAwakeChanged()
    }

    /// While held awake no timer is needed; letting go starts the countdown
    /// afresh.
    private func heldAwakeChanged() {
        if isHeldAwake {
            cancelPendingWake?()
            cancelPendingWake = nil
        }
        noteActivity()
    }

    private func scheduleWakeIfNeeded() {
        guard cancelPendingWake == nil, !isHeldAwake else { return }
        let delay = max(lastActivity + idleAfter - now(), 0)
        cancelPendingWake = schedule(delay) { [weak self] in self?.deadlineReached() }
    }

    private func deadlineReached() {
        cancelPendingWake = nil
        guard !isHeldAwake else { return }
        // A timer may run a little early or late; within a second is due.
        if lastActivity + idleAfter - now() > 1 {
            scheduleWakeIfNeeded()
        } else if !isIdle {
            isIdle = true
        }
    }

    /// A main run loop timer, in common modes so it also fires while a scroll
    /// tracks. Generous tolerance: a few seconds late doesn't matter here.
    nonisolated static func runLoopSchedule(
        _ delay: TimeInterval,
        _ fire: @escaping @MainActor () -> Void
    ) -> () -> Void {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

/// Installs `InteractionIdleTouchRecognizer` on the window it lands in, so
/// every touch anywhere in the app counts. Draws nothing and takes no touches.
struct InteractionIdleTouchProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window,
                  !(window.gestureRecognizers ?? []).contains(where: { $0 is InteractionIdleTouchRecognizer })
            else { return }
            window.addGestureRecognizer(InteractionIdleTouchRecognizer())
        }
    }
}

/// Watches touches without taking part in them, like
/// `MarkdownSelectionObserverGestureRecognizer`: it never recognizes, never
/// delays or cancels touches, recognizes alongside everything, never makes
/// another gesture wait for it or waits for one, and fails when the touch
/// ends. Scrolling, buttons and text selection see exactly the touches they
/// would without it.
final class InteractionIdleTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// A long drag keeps Conduit awake, but a move only needs noting now and
    /// then, not at the display's 120 Hz.
    private static let moveNoteInterval: TimeInterval = 5
    private var lastNotedAt: TimeInterval = -.infinity

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        note()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if ProcessInfo.processInfo.systemUptime - lastNotedAt >= Self.moveNoteInterval { note() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finishIfLastTouch(touches, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finishIfLastTouch(touches, event: event)
    }

    private func note() {
        lastNotedAt = ProcessInfo.processInfo.systemUptime
        InteractionIdleState.shared.noteInteraction()
    }

    /// Fails once every finger has lifted, which resets it for the next touch.
    private func finishIfLastTouch(_ touches: Set<UITouch>, event: UIEvent) {
        let stillDown = (event.touches(for: self) ?? []).contains { touch in
            !touches.contains(touch) && touch.phase != .ended && touch.phase != .cancelled
        }
        guard !stillDown else { return }
        // The countdown starts when the finger lifts.
        note()
        state = .failed
    }
}
