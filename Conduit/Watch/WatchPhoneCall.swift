//
//  WatchPhoneCall.swift
//  Conduit
//
//  The P3 fallback (designs/apple-watch-voice.md): a CallKit call on the
//  iPhone for the length of a Watch call, so iOS keeps Conduit running
//  while the phone is locked. A device log showed Conduit
//  suspended about 30 s after the phone went to the background, which
//  ended the call. Opt-in from Voice settings > Apple Watch test, to
//  repeat the locked-phone test with it. Set up the standard way for a
//  CallKit app: `voip` beside `audio` in UIBackgroundModes, and the
//  session CallKit activates configured for a voice call.
//

import AVFAudio
import CallKit
import Foundation

@MainActor
final class WatchPhoneCall: NSObject {
    static let enabledKey = "watchProbe.phoneCallKeepAlive"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The call was ended from the iPhone's call controls.
    var onEndedOnPhone: (() -> Void)?

    private let log: WatchProbePhoneLog
    private let provider: CXProvider
    private let callController = CXCallController()
    /// The call the running Watch call holds.
    private var callUUID: UUID?
    /// This app's calls CallKit hasn't ended yet. One whose end failed is
    /// still on the iPhone, so the next start ends it first: two calls
    /// would change what the locked-phone test measures.
    private var liveUUIDs: Set<UUID> = []
    /// Calls this app asked CallKit to end, so their end action isn't
    /// taken for the iPhone's End button.
    private var endingUUIDs: Set<UUID> = []
    /// The session's setup before the call, put back once CallKit lets go
    /// of the session.
    private var previousSession: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?

    init(log: WatchProbePhoneLog) {
        self.log = log
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        // Nil queue: the delegate runs on the main queue.
        provider.setDelegate(self, queue: nil)
    }

    func start() {
        guard callUUID == nil else { return }
        for stale in liveUUIDs.subtracting(endingUUIDs) { requestEnd(stale) }
        let uuid = UUID()
        callUUID = uuid
        liveUUIDs.insert(uuid)
        // CallKit activates the session as it's configured here. The
        // Watch call's audio never touches it: the Watch plays and
        // records.
        let session = AVAudioSession.sharedInstance()
        if previousSession == nil {
            previousSession = (session.category, session.mode, session.categoryOptions)
        }
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        } catch {
            log.note("phoneCallSessionFailed", ["error": error.localizedDescription])
        }
        let handle = CXHandle(type: .generic, value: "Hermes on Apple Watch")
        callController.request(CXTransaction(action: CXStartCallAction(call: uuid, handle: handle))) { [weak self] error in
            WatchVoiceMain.async {
                guard let self else { return }
                var fields: [String: Any] = ["ok": error == nil, "appState": WatchProbeLiveness.appStateName]
                if let error { fields["error"] = error.localizedDescription }
                self.log.note("phoneCallStart", fields)
                guard error != nil else { return }
                // CallKit never had it, so it never took the session.
                self.liveUUIDs.remove(uuid)
                if self.callUUID == uuid {
                    self.callUUID = nil
                    self.restoreSession()
                }
            }
        }
    }

    func end() {
        guard let uuid = callUUID else { return }
        callUUID = nil
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
                self.log.note("phoneCallEndFailed", ["error": error.localizedDescription])
                // Already gone from CallKit: nothing left to end.
                if (error as? CXErrorCodeRequestTransactionError)?.code == .unknownCallUUID {
                    self.liveUUIDs.remove(uuid)
                }
            }
        }
    }

    private func restoreSession() {
        guard let previousSession else { return }
        self.previousSession = nil
        try? AVAudioSession.sharedInstance().setCategory(previousSession.category, mode: previousSession.mode, options: previousSession.options)
    }
}

extension WatchPhoneCall: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            log.note("phoneCallReset")
            // Every call is gone, and the session with them.
            liveUUIDs.removeAll()
            endingUUIDs.removeAll()
            restoreSession()
            guard callUUID != nil else { return }
            callUUID = nil
            onEndedOnPhone?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        let uuid = action.callUUID
        MainActor.assumeIsolated {
            liveUUIDs.remove(uuid)
            // Only the iPhone's End button ends a call this app didn't.
            guard !endingUUIDs.contains(uuid), callUUID == uuid else { return }
            callUUID = nil
            log.note("phoneCallEndedOnPhone")
            onEndedOnPhone?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { log.note("phoneCallAudioActive", ["appState": WatchProbeLiveness.appStateName]) }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            log.note("phoneCallAudioInactive", ["appState": WatchProbeLiveness.appStateName])
            // CallKit let go of the session. A newer call keeps it as is.
            if callUUID == nil { restoreSession() }
        }
    }
}
