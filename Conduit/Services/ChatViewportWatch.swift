import CoreGraphics
import Foundation

/// Watches the chat transcript for what a tester would report and saves the
/// recorder's lines (ChatViewportTrace) as a trace when it happens (#1533):
///
/// - A jump: the offset moves more than a screen at once with no finger or
///   momentum on it, and no command, offset write of the scroller's, resize
///   or newly attached scroll view in the second before.
/// - A layout storm: layout runs more than 30 times a second for 3 seconds
///   while no row changes (a reply streaming in grows its row, which
///   counts) and the reader isn't scrolling, which is what a chat that
///   stops taking scrolls and typing would look like.
///
/// Each saves at most once a minute. A stall is MainThreadHangWatchdog's.
@MainActor
final class ChatViewportWatch {
    static let shared = ChatViewportWatch()

    static let stormPassesPerSecond = 30
    static let stormSeconds = 3
    /// How long after a command, a resize or another scroll view a move is
    /// taken as theirs.
    static let askedWindow: CFAbsoluteTime = 1
    /// UIKit's animated offset change runs about a third of a second.
    static let animatedWriteWindow: CFAbsoluteTime = 0.6
    static let saveInterval: CFAbsoluteTime = 60

    private let now: () -> CFAbsoluteTime
    private let save: (ChatTraceReason) -> Void

    private var askedUntil: CFAbsoluteTime = 0
    /// The scroller is writing the offset: the move it makes arrives
    /// inside, and so can a write that move brings on.
    private var writeDepth = 0
    private var savedAt: [ChatTraceReason: CFAbsoluteTime] = [:]
    // The layout storm's count, one second at a time.
    private var second = 0
    private var passes = 0
    private var rowsChanged = false
    private var userMoved = false
    private var stormRun = 0

    init(
        now: @escaping () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent,
        save: @escaping (ChatTraceReason) -> Void = ChatViewportWatch.saveTrace
    ) {
        self.now = now
        self.save = save
    }

    /// ChatView sent the scroller a command (the jump button, Load earlier,
    /// a title tap, another chat or profile): logged, and the moves it
    /// brings are asked for.
    func command(_ text: String) {
        ChatViewportTrace.shared.log("event \(text)")
        askedUntil = max(askedUntil, now() + Self.askedWindow)
    }

    /// A new scroll view, or a new size for it (rotation, a split window, a
    /// Mac window resized): its first moves are layout's, not a jump.
    func surfaceChanged() {
        askedUntil = max(askedUntil, now() + Self.askedWindow)
    }

    /// The scroller writes the offset inside `write`.
    func scrollerWrites(animated: Bool, _ write: () -> Void) {
        writeDepth += 1
        write()
        writeDepth -= 1
        if animated {
            askedUntil = max(askedUntil, now() + Self.animatedWriteWindow)
        }
    }

    /// The scroll view's offset changed.
    func offsetMoved(from old: CGFloat, to new: CGFloat, viewportHeight: CGFloat, byUser: Bool) {
        let time = now()
        roll(to: time)
        if byUser {
            userMoved = true
            return
        }
        guard writeDepth == 0, time >= askedUntil, viewportHeight > 0, abs(new - old) > viewportHeight else { return }
        ChatViewportTrace.shared.log(String(
            format: "jump %.1f -> %.1f with nothing asking (viewport %.1f)", old, new, viewportHeight
        ))
        saveOnce(.jump, at: time)
    }

    /// A layout pass changed the transcript's frames, its size or its
    /// insets.
    func layoutPass() {
        roll(to: now())
        passes += 1
    }

    /// The transcript's rows changed (Hermes' rows, a saved copy's).
    func transcriptChanged() {
        roll(to: now())
        rowsChanged = true
    }

    /// A row changed height (a reply streaming in, a step arriving, a
    /// picture loading): content arriving, as the transcript's rows
    /// changing is.
    func rowResized() {
        transcriptChanged()
    }

    /// Closes the second that ended when `time` is in a new one.
    private func roll(to time: CFAbsoluteTime) {
        let current = Int(time.rounded(.down))
        guard current != second else { return }
        if passes > 10 {
            ChatViewportTrace.shared.log("layout \(passes) passes in 1 s\(rowsChanged ? ", rows changed" : "")\(userMoved ? ", scrolled" : "")")
        }
        if passes > Self.stormPassesPerSecond, !rowsChanged, !userMoved {
            stormRun += 1
        } else {
            stormRun = 0
        }
        if stormRun >= Self.stormSeconds {
            ChatViewportTrace.shared.log("storm: layout over \(Self.stormPassesPerSecond) passes a second for \(stormRun) s with no row changing")
            stormRun = 0
            saveOnce(.storm, at: time)
        }
        // A second with no event in it ended the run.
        if current != second + 1 { stormRun = 0 }
        second = current
        passes = 0
        rowsChanged = false
        userMoved = false
    }

    private func saveOnce(_ reason: ChatTraceReason, at time: CFAbsoluteTime) {
        if let last = savedAt[reason], time - last < Self.saveInterval { return }
        savedAt[reason] = time
        save(reason)
    }

    /// The recorder's lines now, written off the main thread.
    nonisolated static func saveTrace(_ reason: ChatTraceReason) {
        let entries = ChatViewportTrace.shared.entries.suffix(ChatTraceStore.maxRingLines)
        DispatchQueue.global(qos: .utility).async {
            ChatTraceStore().save(reason, lines: entries.map(ChatViewportTrace.line))
        }
    }
}
