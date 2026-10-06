//
//  WatchPhoneCall.swift
//  Conduit
//
//  The P3 fallback (designs/apple-watch-voice.md): a CallKit call on the
//  iPhone for the length of a Watch call, so iOS keeps Conduit running
//  while the phone is locked. The first device log showed Conduit
//  suspended about 30 s after the phone went to the background, which
//  ended the call. Opt-in from Voice settings > Apple Watch test, to
//  repeat the locked-phone test with it.
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
    private var callUUID: UUID?

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

    var isActive: Bool { callUUID != nil }

    func start() {
        guard callUUID == nil else { return }
        let uuid = UUID()
        callUUID = uuid
        // CallKit activates the session as it's configured here.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
        } catch {
            log.note("phoneCallSessionFailed", ["error": error.localizedDescription])
        }
        let handle = CXHandle(type: .generic, value: "Hermes on Apple Watch")
        callController.request(CXTransaction(action: CXStartCallAction(call: uuid, handle: handle))) { [weak self] error in
            WatchVoiceMain.async {
                guard let self else { return }
                self.log.note("phoneCallStart", [
                    "ok": error == nil,
                    "error": error?.localizedDescription as Any,
                    "appState": WatchProbeLiveness.appStateName,
                ])
                if error != nil, self.callUUID == uuid { self.callUUID = nil }
            }
        }
    }

    func end() {
        guard let uuid = callUUID else { return }
        callUUID = nil
        callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
            guard let error else { return }
            WatchVoiceMain.async { self?.log.note("phoneCallEndFailed", ["error": error.localizedDescription]) }
        }
    }
}

extension WatchPhoneCall: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            log.note("phoneCallReset")
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
            // Ours ends here first, so only the iPhone's End button gets
            // this far.
            guard callUUID == uuid else { return }
            callUUID = nil
            log.note("phoneCallEndedOnPhone")
            onEndedOnPhone?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { log.note("phoneCallAudioActive", ["appState": WatchProbeLiveness.appStateName]) }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { log.note("phoneCallAudioInactive", ["appState": WatchProbeLiveness.appStateName]) }
    }
}
