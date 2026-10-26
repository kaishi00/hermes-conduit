import UIKit

/// A UIKit background task that ends exactly once, whichever comes first:
/// iOS's expiry or the end of the work it keeps running. Both arrive on the
/// main actor, so the task's identifier needs no lock, and the expiry
/// handler iOS calls is a main-actor closure of its own rather than a plain
/// one converted to `@Sendable`.
///
/// Two holds stay as they are: `BackgroundConnectionGrace` ends its task on
/// a timer and starts over on every exit, and `MessageReadAloudController`
/// stops playback at expiry before it ends the task. Both already keep
/// their identifier on the main actor.
@MainActor
final class BackgroundTaskHold {
    typealias BeginTask = @MainActor (_ name: String, _ expired: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    typealias EndTask = @MainActor (UIBackgroundTaskIdentifier) -> Void

    private var taskID = UIBackgroundTaskIdentifier.invalid
    private let endTask: EndTask

    private init(endTask: @escaping EndTask) {
        self.endTask = endTask
    }

    /// Begins a background task named `name` and returns what ends it.
    /// Calling that again, or after the expiry ended the task, does nothing.
    static func begin(_ name: String) -> () -> Void {
        begin(
            name,
            beginTask: { name, expired in
                UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expired)
            },
            endTask: { UIApplication.shared.endBackgroundTask($0) }
        )
    }

    /// `begin(_:)` with UIKit's two calls passed in, so tests can expire a
    /// task.
    static func begin(_ name: String, beginTask: BeginTask, endTask: @escaping EndTask) -> () -> Void {
        let hold = BackgroundTaskHold(endTask: endTask)
        hold.taskID = beginTask(name) { hold.end() }
        return { hold.end() }
    }

    private func end() {
        guard taskID != .invalid else { return }
        endTask(taskID)
        taskID = .invalid
    }
}
