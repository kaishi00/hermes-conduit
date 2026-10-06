//
//  WatchLiveVoiceAudio.swift
//  Conduit
//
//  The live controller's microphone and speaker when a call was started
//  from the Apple Watch (designs/apple-watch-voice.md): microphone audio
//  arrives from the Watch as 16 kHz PCM16, and the model's 24 kHz speech
//  goes back as IMA ADPCM packets. The controller, its session, tools and
//  transcript are the same ones a call on the phone uses.
//
//  Speech is sent as the model produces it, which is faster than it
//  plays: the first packet of a turn goes out within about a tenth of a
//  second, later ones at most four times a second with up to a second of
//  audio each, and never more than three unacknowledged at once.
//

import Foundation

enum WatchVoiceAudioError: LocalizedError {
    case watchNotStreaming

    var errorDescription: String? {
        switch self {
        case .watchNotStreaming: return "The Watch isn't sending audio right now."
        }
    }
}

@MainActor
final class WatchLiveVoiceInput: GeminiLiveAudioInput {
    /// Speech captured before the call was ready goes to the model once it
    /// is, up to this much (16 kHz PCM16).
    static let preRollLimit = 16_000 * 2 * 5
    static let preRollChunk = 16_000 * 2 / 4

    private weak var host: WatchCallHost?
    var onChunk: (@MainActor (Data) -> Void)?
    var onInterrupted: (@MainActor () -> Void)?
    var onAudioReturned: (@MainActor () -> Void)?
    var cancelsEcho: Bool { host?.fullDuplex ?? false }

    private(set) var isRunning = false
    private var hasStarted = false
    private var preRoll = Data()
    private var isWatchPaused = false

    init(host: WatchCallHost) {
        self.host = host
    }

    /// The Watch asks for its own microphone.
    func requestPermission() async -> Bool { true }

    func start() throws {
        guard host?.isLinked == true else { throw WatchVoiceAudioError.watchNotStreaming }
        // The call's first start goes ahead with the wrist down (lowered
        // while Hermes connected): audio flows once the Watch resumes. A
        // restart after a pause waits for the Watch instead.
        guard !isWatchPaused || !hasStarted else { throw WatchVoiceAudioError.watchNotStreaming }
        isRunning = true
        guard !hasStarted else { return }
        hasStarted = true
        var buffered = preRoll
        preRoll = Data()
        while !buffered.isEmpty {
            let chunk = buffered.prefix(Self.preRollChunk)
            buffered.removeFirst(chunk.count)
            onChunk?(Data(chunk))
        }
    }

    func stop() {
        isRunning = false
    }

    /// Microphone audio from the Watch. Kept only before the call first
    /// listens; afterwards a muted or paused call drops it.
    func receive(_ pcm: Data) {
        if isRunning {
            onChunk?(pcm)
        } else if !hasStarted {
            preRoll.append(pcm)
            if preRoll.count > Self.preRollLimit { preRoll.removeFirst(preRoll.count - Self.preRollLimit) }
        }
    }

    /// The Watch stopped its microphone (wrist down, Siri, a phone call):
    /// the call pauses as it does for an alarm on the phone (#376).
    func watchPaused() {
        isWatchPaused = true
        guard isRunning else { return }
        isRunning = false
        onInterrupted?()
    }

    func watchResumed() {
        isWatchPaused = false
        onAudioReturned?()
    }
}

@MainActor
final class WatchLiveVoiceOutput: GeminiLiveAudioOutput {
    static let maxInFlight = 3
    static let firstPacketAudio: TimeInterval = 0.12
    static let firstPacketWait: TimeInterval = 0.08
    static let packetInterval: TimeInterval = 0.25
    static let maxPacketAudio: TimeInterval = 1
    /// A pause this long in the model's audio starts a new turn.
    static let turnGap: TimeInterval = 1.5

    private weak var host: WatchCallHost?
    private var encoder = IMAADPCM.Encoder()
    private var pending: [Int16] = []
    private var sampleRate: Double = 24_000
    private(set) var turn: UInt32 = 0
    private var turnOpen = false
    private var firstPacketPending = false
    private var turnStartedAt = Date.distantPast
    private var lastPlayAt = Date.distantPast
    private var seq: UInt32 = 0
    private var lastSentSeq: UInt32 = 0
    private var inFlight = 0
    private var lastSendAt = Date.distantPast
    private var awaitingDrain = false
    private var playbackDeadline = Date.distantPast
    private var timer: Timer?

    init(host: WatchCallHost) {
        self.host = host
    }

    /// Until the Watch says it played everything sent, or well after it
    /// should have if that message was lost.
    var isPlaying: Bool {
        awaitingDrain && Date() < playbackDeadline.addingTimeInterval(2)
    }

    func play(_ pcm: Data, sampleRate: Double) throws {
        guard let host, host.isLinked else { throw WatchVoiceAudioError.watchNotStreaming }
        let now = Date()
        if !turnOpen || now.timeIntervalSince(lastPlayAt) > Self.turnGap || sampleRate != self.sampleRate {
            startTurn(at: now, sampleRate: sampleRate)
        }
        lastPlayAt = now
        let samples = WatchVoicePCM.samples(pcm)
        pending.append(contentsOf: samples)
        awaitingDrain = true
        playbackDeadline = max(playbackDeadline, now.addingTimeInterval(0.5))
            .addingTimeInterval(Double(samples.count) / sampleRate)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
        flush()
    }

    func interrupt() {
        let hadAudio = turnOpen || awaitingDrain || !pending.isEmpty
        pending = []
        turnOpen = false
        awaitingDrain = false
        playbackDeadline = .distantPast
        encoder.reset()
        if hadAudio { host?.stopWatchPlayback(turn: turn) }
    }

    func stop() {
        interrupt()
        timer?.invalidate()
        timer = nil
    }

    /// The Watch played out everything up to `seq` of `turn`.
    func watchDrained(turn drainedTurn: UInt32, seq drainedSeq: UInt32) {
        guard drainedTurn == turn, drainedSeq >= lastSentSeq, pending.isEmpty else { return }
        awaitingDrain = false
    }

    private func startTurn(at now: Date, sampleRate: Double) {
        pending = []
        encoder.reset()
        turn &+= 1
        turnOpen = true
        firstPacketPending = true
        turnStartedAt = now
        self.sampleRate = sampleRate
        host?.modelTurnStarted(turn)
    }

    private func flush() {
        guard let host, !pending.isEmpty, inFlight < Self.maxInFlight else { return }
        let now = Date()
        let pendingAudio = Double(pending.count) / sampleRate
        if firstPacketPending {
            guard pendingAudio >= Self.firstPacketAudio || now.timeIntervalSince(turnStartedAt) >= Self.firstPacketWait else { return }
        } else {
            guard now.timeIntervalSince(lastSendAt) >= Self.packetInterval else { return }
        }
        let count = min(pending.count, Int(sampleRate * Self.maxPacketAudio))
        let samples = Array(pending.prefix(count))
        pending.removeFirst(count)
        seq &+= 1
        let packet = WatchVoicePacket(
            kind: .callAudio,
            flags: firstPacketPending ? .turnStart : [],
            codec: .imaADPCM,
            callID: host.callID ?? 0,
            seq: seq,
            turn: turn,
            sampleRate: UInt32(sampleRate),
            sentAtMs: host.millisecondsSinceStart,
            payload: encoder.encode(samples)
        )
        firstPacketPending = false
        inFlight += 1
        lastSendAt = now
        lastSentSeq = seq
        host.send(packet) { [weak self] ok in
            guard let self else { return }
            self.inFlight = max(0, self.inFlight - 1)
            if ok { self.flush() }
        }
    }
}
