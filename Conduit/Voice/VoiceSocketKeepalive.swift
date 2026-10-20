//
//  VoiceSocketKeepalive.swift
//  Conduit
//

import Foundation

/// Keepalive pings on a dashboard voice socket (speak-stream,
/// transcribe-stream). Tailscale relays, carrier NATs and proxies drop an
/// idle connection without a close, and a dead socket's receive never
/// fails: nothing comes back while the speaker pauses or a reply waits on
/// tools, so the stream only found out at its finish timeout, or not at
/// all before the end of the utterance (#787). The chat socket
/// (HermesClient) and the Watch bridge (#879) already ping for this.
///
/// Like the chat socket's, it pings only a quiet socket: any frame from
/// Hermes is proof of life, so a socket busy streaming audio (whose pong
/// may queue behind seconds of PCM on a slow path) is never judged by its
/// pings. Misses are counted like the Watch bridge's: two in a row (about
/// three quiet intervals) and `onSilent` runs once. The first ping can go
/// out before a slow upgrade completes; a handshake that takes that long
/// gets the same fallback as a refused one.
@MainActor
final class VoiceSocketKeepalive {
    nonisolated static let interval: Duration = .seconds(10)

    // nonisolated(unsafe): deinit cancels it; cancel() is thread-safe.
    nonisolated(unsafe) private var loop: Task<Void, Never>?
    private var pings = WatchPingWatchdog()
    private var heardSinceTick = false
    private var onSilent: (@MainActor () -> Void)?

    init(
        socket: any HermesSpeechSocket,
        interval: Duration = VoiceSocketKeepalive.interval,
        onSilent: @escaping @MainActor () -> Void
    ) {
        self.onSilent = onSilent
        loop = Task { [weak self, weak socket] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, let socket else { return }
                self.pingIfQuiet(socket)
            }
        }
    }

    deinit {
        loop?.cancel()
    }

    /// A frame arrived: the socket is alive, and owes no answer to a ping.
    func heard() {
        heardSinceTick = true
    }

    /// The stream is over, or closed its socket itself: no more pings, and
    /// a late answer changes nothing.
    func stop() {
        onSilent = nil
        loop?.cancel()
        loop = nil
    }

    private func pingIfQuiet(_ socket: any HermesSpeechSocket) {
        guard onSilent != nil else { return }
        if heardSinceTick {
            heardSinceTick = false
            pings = WatchPingWatchdog()
            return
        }
        guard !pings.pingDue() else { return silent() }
        socket.sendPing { [weak self] error in
            Task { @MainActor [weak self] in self?.answered(ok: error == nil) }
        }
    }

    private func answered(ok: Bool) {
        guard onSilent != nil else { return }
        if pings.answered(ok: ok) { silent() }
    }

    private func silent() {
        guard let onSilent else { return }
        stop()
        onSilent()
    }
}
