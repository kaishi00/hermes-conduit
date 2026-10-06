//
//  WatchSystemCall.swift
//  Conduit Watch
//
//  An experiment for the dimmed-screen drops (designs/apple-watch-voice.md,
//  the wrist-down phase): a CallKit call on the Watch for the length of a
//  call. A device log showed the link to the iPhone dropping each time the
//  Watch's screen dimmed, 15 to 25 s after it woke, with the wrist up. A
//  VoIP call is how a watchOS voice app keeps running through a dim or a
//  lowered wrist; the log shows whether the link holds with it. Opt-in
//  from the call screen.
//

import AVFAudio
import CallKit
import Foundation

@MainActor
final class WatchSystemCall: NSObject {
    /// How long a start waits for CallKit to hand over the audio session.
    static let activationTimeout: TimeInterval = 3

    /// The call was ended from the Watch's own call controls.
    var onEndedBySystem: (() -> Void)?
    /// CallKit has the call.
    private(set) var isHolding = false

    private let provider: CXProvider
    private let callController = CXCallController()
    private var callUUID: UUID?
    /// This app's calls CallKit hasn't ended yet. One whose end failed is
    /// still on the Watch, so the next start ends it first: two calls
    /// would change what the experiment measures.
    private var liveUUIDs: Set<UUID> = []
    /// Calls this app asked CallKit to end, so their end action isn't
    /// taken for the Watch's End button.
    private var endingUUIDs: Set<UUID> = []
    private var activation: CheckedContinuation<Bool, Never>?

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: configuration)
        super.init()
        // Nil queue: the delegate runs on the main queue.
        provider.setDelegate(self, queue: nil)
    }

    /// Starts the call and waits, a few seconds at most, until CallKit
    /// activates the audio session. False if the call didn't start or the
    /// session never came; the Watch's call goes on either way.
    func start() async -> Bool {
        guard callUUID == nil, activation == nil else { return false }
        for stale in liveUUIDs.subtracting(endingUUIDs) { requestEnd(stale) }
        let uuid = UUID()
        callUUID = uuid
        liveUUIDs.insert(uuid)
        // CallKit activates the session as it's configured here: the same
        // setup the call's audio uses, so the audio start changes nothing.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, policy: .default, options: [])
        } catch {
            WatchProbeLog.shared.note("systemCallSessionFailed", ["error": error.localizedDescription])
        }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let handle = CXHandle(type: .generic, value: "Hermes")
        let activated = await withCheckedContinuation { continuation in
            activation = continuation
            callController.request(CXTransaction(action: CXStartCallAction(call: uuid, handle: handle))) { [weak self] error in
                WatchVoiceMain.async {
                    guard let self else { return }
                    var fields: [String: Any] = ["ok": error == nil]
                    if let error { fields["error"] = error.localizedDescription }
                    WatchProbeLog.shared.note("systemCallStart", fields)
                    guard error != nil else { return }
                    // CallKit never had it.
                    self.liveUUIDs.remove(uuid)
                    guard self.callUUID == uuid else { return }
                    self.callUUID = nil
                    self.isHolding = false
                    self.finishActivation(false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationTimeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.callUUID == uuid, self.activation != nil else { return }
                    WatchProbeLog.shared.note("systemCallNoSession")
                    self.finishActivation(false)
                }
            }
        }
        WatchProbeLog.shared.note("systemCallReady", [
            "activated": activated,
            "holding": isHolding,
            "ms": Int((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000),
        ])
        return activated
    }

    func end() {
        finishActivation(false)
        guard let uuid = callUUID else { return }
        callUUID = nil
        isHolding = false
        requestEnd(uuid)
    }

    private func requestEnd(_ uuid: UUID) {
        endingUUIDs.insert(uuid)
        callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
            WatchVoiceMain.async {
                guard let self else { return }
                self.endingUUIDs.remove(uuid)
                guard let error else {
                    self.liveUUIDs.remove(uuid)
                    return
                }
                WatchProbeLog.shared.note("systemCallEndFailed", ["error": error.localizedDescription])
                // Already gone from CallKit: nothing left to end.
                if (error as? CXErrorCodeRequestTransactionError)?.code == .unknownCallUUID {
                    self.liveUUIDs.remove(uuid)
                }
            }
        }
    }

    private func finishActivation(_ activated: Bool) {
        guard let activation else { return }
        self.activation = nil
        activation.resume(returning: activated)
    }
}

extension WatchSystemCall: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            WatchProbeLog.shared.note("systemCallReset")
            // Every call is gone.
            liveUUIDs.removeAll()
            endingUUIDs.removeAll()
            finishActivation(false)
            isHolding = false
            guard callUUID != nil else { return }
            callUUID = nil
            onEndedBySystem?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let uuid = action.callUUID
        // Ended or reset before CallKit got to it: leave no call behind.
        guard MainActor.assumeIsolated({ callUUID == uuid }) else {
            action.fail()
            return
        }
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        action.fulfill()
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
        MainActor.assumeIsolated { isHolding = true }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        let uuid = action.callUUID
        MainActor.assumeIsolated {
            liveUUIDs.remove(uuid)
            // Only the Watch's End button ends a call this app didn't.
            guard !endingUUIDs.contains(uuid), callUUID == uuid else { return }
            callUUID = nil
            isHolding = false
            finishActivation(false)
            WatchProbeLog.shared.note("systemCallEndedOnWatch")
            onEndedBySystem?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            WatchProbeLog.shared.note("systemCallAudioActive")
            finishActivation(true)
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { WatchProbeLog.shared.note("systemCallAudioInactive") }
    }
}
