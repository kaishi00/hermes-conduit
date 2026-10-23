import UIKit

/// Keeps Conduit running for a short while after it leaves the screen, so
/// the chat socket keeps answering Hermes' pings through a quick trip to
/// another app (notifier #296). Hermes pings every 20 s and gives up after
/// 20 s more; once iOS suspends the app nothing answers, and a return after
/// that has to reconnect. With the hold, a switch away of up to about a
/// minute comes back to the same open socket.
///
/// iOS grants about 30 s of background time and nothing longer for a plain
/// socket: there is no background mode that keeps a chat connection open.
@MainActor
final class BackgroundConnectionGrace {
    /// Under iOS's ~30 s allowance, so the hold always ends on our side
    /// rather than at iOS's deadline.
    static let window: TimeInterval = 25

    private let beginTask: (_ expired: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    private let endTask: (UIBackgroundTaskIdentifier) -> Void
    private let sleep: (TimeInterval) async -> Void
    private let window: TimeInterval
    /// Ends the running hold's task; each hold owns its own, so a late
    /// expiry or timer can only end the hold it belongs to, and the task
    /// still ends if this object goes away first.
    private var endCurrentTask: (() -> Void)?
    private var holdGeneration = 0
    private var timer: Task<Void, Never>?

    init(
        window: TimeInterval = BackgroundConnectionGrace.window,
        beginTask: ((_ expired: @escaping () -> Void) -> UIBackgroundTaskIdentifier)? = nil,
        endTask: ((UIBackgroundTaskIdentifier) -> Void)? = nil,
        sleep: ((TimeInterval) async -> Void)? = nil
    ) {
        self.window = window
        self.beginTask = beginTask ?? { expired in
            UIApplication.shared.beginBackgroundTask(
                withName: "conduit.chatSocket.grace",
                expirationHandler: expired
            )
        }
        self.endTask = endTask ?? { UIApplication.shared.endBackgroundTask($0) }
        self.sleep = sleep ?? { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    var isHolding: Bool { endCurrentTask != nil }

    /// Conduit left the screen with an open socket. A hold already running
    /// starts over.
    func begin() {
        end()
        holdGeneration += 1
        let generation = holdGeneration
        var taskID = UIBackgroundTaskIdentifier.invalid
        let endTask = endTask
        let endThisTask = {
            guard taskID != .invalid else { return }
            endTask(taskID)
            taskID = .invalid
        }
        let finish: @MainActor () -> Void = { [weak self] in
            endThisTask()
            guard let self, self.holdGeneration == generation else { return }
            self.timer?.cancel()
            self.timer = nil
            self.endCurrentTask = nil
        }
        taskID = beginTask {
            // UIKit delivers this on the main thread in practice, but it is
            // not documented: hop rather than trap if it ever isn't.
            if Thread.isMainThread {
                MainActor.assumeIsolated { finish() }
            } else {
                DispatchQueue.main.async { finish() }
            }
        }
        guard taskID != .invalid else { return }
        endCurrentTask = endThisTask
        let window = window
        let sleep = sleep
        timer = Task { @MainActor in
            await sleep(window)
            guard !Task.isCancelled else { return }
            finish()
        }
    }

    /// Back on screen, the socket dropped, or signed out.
    func end() {
        timer?.cancel()
        timer = nil
        let endTask = endCurrentTask
        endCurrentTask = nil
        endTask?()
    }
}
