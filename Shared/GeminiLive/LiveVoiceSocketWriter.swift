import Foundation
import os

private let liveVoiceWriterLogger = Logger(subsystem: "com.milim.relay", category: "LiveVoiceWriter")

/// Sends one connection's frames in order, one at a time, so a socket that
/// stops taking them holds a short queue instead of a task and payload for
/// every microphone chunk (#999, F1-68). Audio past `maxQueuedAudio`, the
/// frame on the socket included, is dropped as it arrives: the model can't
/// use speech that late. Everything else (text turns and tool answers, a
/// few each turn) is never dropped on its own: past `maxQueuedOther` the
/// socket has stopped taking frames, so the writer gives up on it and fails
/// everything it holds with `Backlogged`, which the session treats as a
/// lost connection and reconnects. Each frame's own failure handler then
/// hands its result back, as for any send that failed.
@MainActor
final class LiveVoiceSocketWriter {
    /// A count of capture chunks, not a time: for Gemini, about two
    /// seconds of the tap's 1,024-frame buffers at 48 kHz (21 ms each),
    /// longer on a route that captures at a lower rate. Grok and Local Live
    /// count their own capture chunks the same way.
    static let defaultMaxQueuedAudio = 96
    /// Text turns, context notes and tool answers come a few a turn; this
    /// many outstanding (the frame on the socket included) means the socket
    /// stopped taking frames.
    static let defaultMaxQueuedOther = 32

    /// The socket stopped taking frames: everything queued failed with this.
    struct Backlogged: Error {}

    private struct Frame {
        let texts: [String]
        let isAudio: Bool
        let done: @MainActor (Error?) -> Void
    }

    let socket: any GeminiLiveSocket
    let maxQueuedAudio: Int
    let maxQueuedOther: Int
    private var queue: [Frame] = []
    private var queuedAudio = 0
    private var queuedOther = 0
    private var drainTask: Task<Void, Never>?
    private var isClosed = false
    private(set) var droppedAudio = 0

    init(
        socket: any GeminiLiveSocket,
        maxQueuedAudio: Int = LiveVoiceSocketWriter.defaultMaxQueuedAudio,
        maxQueuedOther: Int = LiveVoiceSocketWriter.defaultMaxQueuedOther
    ) {
        self.socket = socket
        self.maxQueuedAudio = maxQueuedAudio
        self.maxQueuedOther = maxQueuedOther
    }

    /// Queues `texts` to go out together, in order, after everything queued
    /// before. `done` gets nil once the last one is sent, or the error that
    /// stopped them (a closed writer's is `CancellationError`, a stalled
    /// socket's `Backlogged`). False, with `done` never called, when the
    /// queue is full of audio and this audio was dropped.
    @discardableResult
    func enqueue(_ texts: [String], isAudio: Bool, done: @escaping @MainActor (Error?) -> Void) -> Bool {
        guard !isClosed else {
            done(CancellationError())
            return true
        }
        if isAudio {
            guard queuedAudio < maxQueuedAudio else {
                droppedAudio += 1
                // The first of a run, then every 50th: a slow link that
                // loses speech shows in the log without flooding it.
                if droppedAudio % 50 == 1 {
                    liveVoiceWriterLogger.notice("Live voice audio dropped: \(self.droppedAudio, privacy: .public) frames behind a slow connection")
                }
                return false
            }
            queuedAudio += 1
        } else {
            guard queuedOther < maxQueuedOther else {
                liveVoiceWriterLogger.error("Live voice socket stopped taking frames: \(self.queuedOther, privacy: .public) outstanding")
                fail(with: Backlogged(), also: done)
                return true
            }
            queuedOther += 1
        }
        queue.append(Frame(texts: texts, isAudio: isAudio, done: done))
        if drainTask == nil {
            drainTask = Task { [weak self] in await self?.drain() }
        }
        return true
    }

    /// Fails everything still queued; nothing more is sent.
    func close() {
        fail(with: CancellationError())
    }

    /// Closes the writer, then fails what it held, oldest first, and
    /// `also` last: a handler that sends again finds it closed.
    private func fail(with error: Error, also extra: (@MainActor (Error?) -> Void)? = nil) {
        guard !isClosed else {
            extra?(CancellationError())
            return
        }
        isClosed = true
        drainTask?.cancel()
        drainTask = nil
        let dropped = queue
        queue = []
        queuedAudio = 0
        queuedOther = 0
        for frame in dropped { frame.done(error) }
        extra?(error)
    }

    private func drain() async {
        while !isClosed, !queue.isEmpty {
            let frame = queue.removeFirst()
            var error: Error?
            do {
                for text in frame.texts { try await socket.send(text) }
            } catch let failure {
                error = failure
            }
            // Counted until it left: the bound covers the frame on the
            // socket too. A close meanwhile already reset the count.
            if !isClosed {
                if frame.isAudio { queuedAudio -= 1 } else { queuedOther -= 1 }
            }
            frame.done(error)
            // The socket failed: what waits behind it fails with it, once,
            // rather than each frame trying the dead socket in turn.
            if let error, !isClosed {
                let rest = queue
                queue = []
                queuedAudio = 0
                queuedOther = 0
                for waiting in rest { waiting.done(error) }
                break
            }
        }
        if !isClosed { drainTask = nil }
    }
}
