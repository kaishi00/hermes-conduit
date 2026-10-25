import UIKit

/// A UIKit background task that ends exactly once, whichever comes first:
/// iOS's expiry or the end of the work it keeps running. Both arrive on the
/// main actor, so the task's identifier needs no lock, and the expiry
/// handler iOS calls is a main-actor closure of its own rather than a plain
/// one converted to `@Sendable`.
@MainActor
final class BackgroundTaskHold {
    private var taskID = UIBackgroundTaskIdentifier.invalid

    private init() {}

    /// Begins a background task named `name` and returns what ends it.
    /// Calling that again, or after the expiry ended the task, does nothing.
    static func begin(_ name: String) -> () -> Void {
        let hold = BackgroundTaskHold()
        hold.taskID = UIApplication.shared.beginBackgroundTask(withName: name) {
            hold.end()
        }
        return { hold.end() }
    }

    private func end() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}
