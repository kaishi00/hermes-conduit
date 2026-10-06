//
//  WatchSoakModel.swift
//  Conduit Watch
//
//  The link test (designs/apple-watch-voice.md, P2): both devices send
//  packets of a call's size at a call's rate for a while, each
//  acknowledging what it receives, and report delivery, round trips and
//  stalls. Only time with the Watch app in front counts toward the wrist-up
//  numbers; what happens with the screen off is logged on its own.
//

import Foundation
import SwiftUI

@MainActor
final class WatchSoakModel: ObservableObject {
    struct Preset: Identifiable, Hashable {
        let id: String
        let title: String
        let interval: TimeInterval
        let upBytes: Int
        let downBytes: Int
    }

    /// A live call: 250 ms of 16 kHz ADPCM up, 250 ms of 24 kHz ADPCM down.
    /// Classic chunks: one second of each.
    static let presets = [
        Preset(id: "live", title: "Live call (4/s)", interval: 0.25, upBytes: 2_030, downBytes: 3_030),
        Preset(id: "classic", title: "Chunks (1/s)", interval: 1, upBytes: 8_030, downBytes: 12_030),
    ]
    static let durations: [TimeInterval] = [60, 300, 600]
    static let maxInFlight = 3

    @Published var preset = WatchSoakModel.presets[0]
    @Published var duration: TimeInterval = 300
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Ready"
    @Published private(set) var watchResult: WatchVoiceWire.SoakResult?
    @Published private(set) var phoneResult: WatchVoiceWire.SoakResult?

    private let link = WatchLink.shared
    private var plan: WatchVoiceWire.SoakPlan?
    private var startedAt: TimeInterval = 0
    private var seq: UInt32 = 0
    private var inFlight = 0
    private var owed = 0
    private var sent = 0
    private var acked = 0
    private var failed = 0
    private var failedWhileAway = 0
    private var merged = 0
    private var roundTrips: [Double] = []
    private var received = 0
    private var lastReceivedAt: TimeInterval?
    private var gaps: [Double] = []
    private var reachabilityDropsInFront = 0
    private var reachabilityChanges = 0
    private var errors: [String] = []
    private var inFrontSeconds: TimeInterval = 0
    private var lastTickAt: TimeInterval = 0
    private var scenePhase: ScenePhase = .active
    private var timer: Timer?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var isInFront: Bool { scenePhase == .active }

    func start() {
        guard !isRunning else { return }
        let plan = WatchVoiceWire.SoakPlan(
            runID: UInt32.random(in: 1...UInt32.max),
            label: preset.id,
            duration: duration,
            interval: preset.interval,
            upBytes: preset.upBytes,
            downBytes: preset.downBytes,
            maxInFlight: Self.maxInFlight
        )
        reset()
        self.plan = plan
        isRunning = true
        status = "Asking the iPhone…"
        link.onSoakPacket = { [weak self] in self?.receivedPacket($0) }
        link.onSoakReachabilityChange = { [weak self] reachable in self?.reachabilityChanged(reachable) }
        WatchProbeLog.shared.note("soakStart", ["runID": Int(plan.runID), "label": plan.label, "durationS": Int(plan.duration)])
        link.send(.soakStart(plan), reply: { [weak self] answer in
            guard let self, self.isRunning else { return }
            // The iPhone refuses while a call runs over the same link.
            guard case .pong? = answer else {
                self.isRunning = false
                self.detachFromLink()
                self.status = "The iPhone is in a call. End it to run the link test."
                WatchProbeLog.shared.note("soakStartRefused", ["runID": Int(plan.runID)])
                return
            }
            self.startedAt = self.now
            self.lastTickAt = self.now
            self.status = "Running"
            self.timer = Timer.scheduledTimer(withTimeInterval: plan.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }, failure: { [weak self] error in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            self.detachFromLink()
            self.status = "Can't reach the iPhone: \(error.localizedDescription)"
            WatchProbeLog.shared.note("soakStartFailed", ["error": error.localizedDescription])
        })
        // An iPhone that never answers leaves nothing waiting.
        let runID = plan.runID
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.timer == nil, self.plan?.runID == runID else { return }
                self.isRunning = false
                self.detachFromLink()
                self.status = "The iPhone didn't answer. Open Conduit on it and try again."
                WatchProbeLog.shared.note("soakStartTimedOut", ["runID": Int(runID)])
            }
        }
    }

    func stop() {
        guard isRunning, let plan else { return }
        timer?.invalidate()
        timer = nil
        isRunning = false
        detachFromLink()
        status = "Collecting the iPhone's numbers…"
        let result = makeResult(plan)
        watchResult = result
        link.send(.soakStop(runID: plan.runID), reply: { [weak self] answer in
            guard let self else { return }
            if case .soakResult(let phone)? = answer { self.phoneResult = phone }
            self.status = "Done"
            self.report(watch: result, phone: self.phoneResult)
        }, failure: { [weak self] error in
            guard let self else { return }
            self.status = "Done (the iPhone's numbers didn't arrive)"
            self.errors.append("soakStop: \(error.localizedDescription)")
            self.report(watch: result, phone: nil)
        })
    }

    private func detachFromLink() {
        link.onSoakPacket = nil
        link.onSoakReachabilityChange = nil
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase != scenePhase else { return }
        scenePhase = phase
        guard isRunning else { return }
        WatchProbeLog.shared.note("soakScenePhase", ["phase": "\(phase)", "reachable": link.isReachable, "atS": Int(now - startedAt)])
    }

    private func tick() {
        guard isRunning, let plan else { return }
        let current = now
        if isInFront { inFrontSeconds += current - lastTickAt }
        lastTickAt = current
        status = "Running \(Int(current - startedAt))s · sent \(sent) · acked \(acked)"
        if current - startedAt >= plan.duration {
            stop()
            return
        }
        owed += 1
        guard inFlight < plan.maxInFlight else { return }
        // Packets owed while too many were in flight go out as one.
        let count = owed
        owed = 0
        if count > 1 { merged += count - 1 }
        seq &+= 1
        let packet = WatchVoicePacket(
            kind: .soak,
            codec: .none,
            callID: plan.runID,
            seq: seq,
            sampleRate: 0,
            sentAtMs: UInt32((current - startedAt) * 1000),
            payload: Data(count: min(60_000, plan.upBytes * count))
        )
        inFlight += 1
        sent += 1
        let inFront = isInFront
        link.send(packet) { [weak self] result in
            guard let self else { return }
            self.inFlight = max(0, self.inFlight - 1)
            switch result {
            case .success(let roundTrip):
                self.acked += 1
                if inFront { self.roundTrips.append(roundTrip) }
            case .failure(let error):
                self.failed += 1
                if !inFront { self.failedWhileAway += 1 }
                if self.errors.count < 10 { self.errors.append(error.localizedDescription) }
            }
        }
    }

    private func receivedPacket(_ packet: WatchVoicePacket) {
        guard isRunning, packet.callID == plan?.runID else { return }
        let current = now
        received += 1
        if let lastReceivedAt, isInFront { gaps.append(current - lastReceivedAt) }
        lastReceivedAt = current
    }

    private func reachabilityChanged(_ reachable: Bool) {
        guard isRunning else { return }
        reachabilityChanges += 1
        if !reachable, isInFront { reachabilityDropsInFront += 1 }
    }

    private func makeResult(_ plan: WatchVoiceWire.SoakPlan) -> WatchVoiceWire.SoakResult {
        WatchVoiceWire.SoakResult(
            side: "watch",
            runID: plan.runID,
            label: plan.label,
            sent: sent,
            acked: acked,
            failed: failed,
            merged: merged,
            rttP50Ms: WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(roundTrips, 0.5)),
            rttP95Ms: WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(roundTrips, 0.95)),
            rttP99Ms: WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(roundTrips, 0.99)),
            rttMaxMs: WatchVoiceStats.milliseconds(roundTrips.max()),
            received: received,
            maxGapMs: WatchVoiceStats.milliseconds(gaps.max()),
            stallsOver1s: gaps.filter { $0 > 1 }.count,
            reachabilityChanges: reachabilityChanges,
            suspendedMs: 0,
            errors: errors
        )
    }

    private func report(watch: WatchVoiceWire.SoakResult, phone: WatchVoiceWire.SoakResult?) {
        WatchProbeLog.shared.report("soakSummary", [
            "runID": Int(watch.runID),
            "label": watch.label,
            "durationS": Int(plan?.duration ?? 0),
            "inFrontS": Int(inFrontSeconds),
            "reachabilityDropsInFront": reachabilityDropsInFront,
            "failedWhileAway": failedWhileAway,
            "watch": Self.fields(watch),
            "phone": phone.map(Self.fields) as Any,
        ])
    }

    static func fields(_ result: WatchVoiceWire.SoakResult) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(result),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func reset() {
        seq = 0
        inFlight = 0
        owed = 0
        sent = 0
        acked = 0
        failed = 0
        failedWhileAway = 0
        merged = 0
        roundTrips = []
        received = 0
        lastReceivedAt = nil
        gaps = []
        reachabilityDropsInFront = 0
        reachabilityChanges = 0
        errors = []
        inFrontSeconds = 0
        watchResult = nil
        phoneResult = nil
    }
}
