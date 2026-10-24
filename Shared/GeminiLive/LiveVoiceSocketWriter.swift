import Foundation

/// Sends one connection's frames in order, one at a time, so a socket that
/// stops taking them holds a short queue instead of a task and payload for
/// every microphone chunk (#999, F1-68). Audio past `maxQueuedAudio` is
/// dropped as it arrives: the model can't use speech that late. Everything
/// else (text turns, tool answers) always queues.
@MainActor
final class LiveVoiceSocketWriter {
    /// About two seconds of 64 ms microphone chunks.
    static let defaultMaxQueuedAudio = 32

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
            if frame.isAudio { queuedAudio -= 1 }
            do {
                for text in frame.texts { try await socket.send(text) }
                frame.done(nil)
            } catch {
                frame.done(error)
            }
        }
        if !isClosed { drainTask = nil }
    }
}
