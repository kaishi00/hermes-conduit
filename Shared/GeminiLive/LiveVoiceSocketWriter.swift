import Foundation
import os

private let liveVoiceWriterLogger = Logger(subsystem: "com.milim.relay", category: "LiveVoiceWriter")

/// Sends one connection's frames in order, one at a time, so a socket that
/// stops taking them holds a short queue instead of a task and payload for
/// every microphone chunk (#999, F1-68). Audio past `maxQueuedAudio`, the
/// frame on the socket included, is dropped as it arrives: the model can't
/// use speech that late. Everything else (text turns and tool answers, a
/// few each turn) always queues.
@MainActor
final class LiveVoiceSocketWriter {
    /// A count of capture chunks, not a time: about two seconds of the
    /// tap's 1,024-frame buffers at 48 kHz (21 ms each), longer on a route
    /// that captures at a lower rate.
    static let defaultMaxQueuedAudio = 96

    private struct Frame {
        let texts: [String]
        let isAudio: Bool
        let done: @MainActor (Error?) -> Void
    }

    let socket: any GeminiLiveSocket
    let maxQueuedAudio: Int
    private var queue: [Frame] = []
    private var queuedAudio = 0
    private var drainTask: Task<Void, Never>?
    private var isClosed = false
    private(set) var droppedAudio = 0

    init(socket: any GeminiLiveSocket, maxQueuedAudio: Int = LiveVoiceSocketWriter.defaultMaxQueuedAudio) {
        self.socket = socket
        self.maxQueuedAudio = maxQueuedAudio
    }

    /// Queues `texts` to go out together, in order, after everything queued
    /// before. `done` gets nil once the last one is sent, or the error that
    /// stopped them (a closed writer's is `CancellationError`). False, with
    /// `done` never called, when the queue is full of audio and this audio
    /// was dropped.
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
        }
        queue.append(Frame(texts: texts, isAudio: isAudio, done: done))
        if drainTask == nil {
            drainTask = Task { [weak self] in await self?.drain() }
        }
        return true
    }

    /// Fails everything still queued; nothing more is sent.
    func close() {
        isClosed = true
        drainTask?.cancel()
        drainTask = nil
        let dropped = queue
        queue = []
        queuedAudio = 0
        for frame in dropped { frame.done(CancellationError()) }
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
            if frame.isAudio, !isClosed { queuedAudio -= 1 }
            frame.done(error)
            // The socket failed: what waits behind it fails with it, once,
            // rather than each frame trying the dead socket in turn.
            if let error, !isClosed {
                let rest = queue
                queue = []
                queuedAudio = 0
                for waiting in rest { waiting.done(error) }
                break
            }
        }
        if !isClosed { drainTask = nil }
    }
}
