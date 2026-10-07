//
//  HermesLiveTranscription.swift
//  Conduit
//

import Foundation

/// Live speech-to-text over Hermes' `/api/audio/transcribe-stream` socket
/// (`stt.streaming`). Conduit sends `{"sample_rate": N}`, then binary PCM16
/// frames, then `{"eos": true}`. Hermes answers `partial` frames while it
/// recognizes speech and one `final`, or an `error`, after which the
/// recording is uploaded as before.
///
/// An `error` frame before any partial and before the end of speech means
/// this profile has no live STT (stt.streaming off, a provider without a
/// live wire), so `onUnavailable` tells the conversation to stop opening it.
/// A transport failure (a network blip, a Hermes without the socket) only
/// sends this utterance to the upload; the next one tries again.
@MainActor
final class HermesLiveTranscription: VoiceLiveTranscription {
    private enum Outcome {
        case final(String)
        case failed
        /// Hermes answered `error`: no live STT here.
        case refused
    }

    private let socket: any HermesSpeechSocket
    private let onPartial: @MainActor (String) -> Void
    private let onUnavailable: @MainActor () -> Void
    private let finishTimeout: Duration
    private var receiveTask: Task<Void, Never>?
    /// Sends run one after another so frames reach Hermes in order.
    private var sendChain: Task<Void, Never>?
    private var outcome: Outcome?
    private var waiter: CheckedContinuation<String?, Never>?
    private var sawPartial = false
    private var ended = false

    init(
        socket: any HermesSpeechSocket,
        sampleRate: Double,
        finishTimeout: Duration = .seconds(10),
        onPartial: @escaping @MainActor (String) -> Void,
        onUnavailable: @escaping @MainActor () -> Void
    ) {
        self.socket = socket
        self.finishTimeout = finishTimeout
        self.onPartial = onPartial
        self.onUnavailable = onUnavailable
        enqueue(.string("{\"sample_rate\":\(Int(sampleRate))}"))
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    deinit {
        receiveTask?.cancel()
        sendChain?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
    }

    func push(_ pcm16: Data) {
        guard outcome == nil, !ended, !pcm16.isEmpty else { return }
        enqueue(.data(pcm16))
    }

    /// The final transcript, or nil when the upload must be used instead
    /// (an error, an empty result, or no answer within the timeout).
    func finish() async -> String? {
        if let outcome { return Self.transcript(outcome) }
        // One caller per session; a second waits for nothing.
        guard !ended else { return nil }
        ended = true
        enqueue(.string("{\"eos\":true}"))
        let timeout = Task { [weak self, finishTimeout] in
            try? await Task.sleep(for: finishTimeout)
            guard !Task.isCancelled else { return }
            self?.resolve(.failed)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: Self.transcript(outcome))
            } else {
                waiter = continuation
            }
        }
    }

    func cancel() {
        ended = true
        resolve(.failed)
    }

    private func enqueue(_ message: URLSessionWebSocketTask.Message) {
        let previous = sendChain
        sendChain = Task { [weak self, socket] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await socket.send(message)
            } catch {
                self?.resolve(.failed)
            }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, outcome == nil {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                resolve(.failed)
                return
            }
            guard let frame = Self.frame(message), let type = frame["type"] as? String else { continue }
            switch type {
            case "partial":
                let text = (frame["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, outcome == nil else { continue }
                sawPartial = true
                onPartial(text)
            case "final":
                resolve(.final(frame["transcript"] as? String ?? ""))
            case "error":
                resolve(.refused)
            default:
                continue
            }
        }
    }

    private func resolve(_ result: Outcome) {
        guard outcome == nil else { return }
        outcome = result
        if case .refused = result, !sawPartial, !ended { onUnavailable() }
        waiter?.resume(returning: Self.transcript(result))
        waiter = nil
        receiveTask?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
    }

    /// Hermes' own clients fall back to the recording on an empty live
    /// result, which a whole-file pass can still fill.
    private static func transcript(_ outcome: Outcome) -> String? {
        guard case .final(let text) = outcome else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func frame(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
