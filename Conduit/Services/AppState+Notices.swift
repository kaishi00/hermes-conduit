//
//  AppState+Notices.swift
//  Conduit
//
//  The notices shown over the app: a refused call, CarPlay failing, and
//  the general notice. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Notices over the app

    /// Says something briefly over the V2 lists and over a call's screen
    /// (`pinSyncNotice` carries every such notice).
    func showNotice(_ message: String, systemImage: String) {
        publishNotice(PinSyncNotice(message: message, systemImage: systemImage))
    }

    /// A tap a call kept from switching says why, over the screen and over
    /// the call's own: `errorMessage` shows only while the composer is
    /// locked or the connection needs repair, and a call does neither. Only
    /// V2 draws the notice: the drawer shell keeps its error line, as
    /// before, which says nothing during the call (`clearCallRefusal`).
    func showCallRefusal(_ message: String, drawsNotices: Bool = V2ShellPreference.isOn) {
        if drawsNotices {
            showNotice(message, systemImage: "exclamationmark.triangle.fill")
        } else {
            errorMessage = message
            callRefusalOnErrorLine = message
        }
    }

    /// The call a tap waited for is over, or a newer tap replaced it: the
    /// drawer shell's error line drops the refusal it still has, or the line
    /// would say a tap waits just as the next switch locks the composer and
    /// shows it.
    func clearCallRefusal() {
        if let refusal = callRefusalOnErrorLine, errorMessage == refusal { errorMessage = nil }
        callRefusalOnErrorLine = nil
    }

    /// No call, and Conduit on screen (not only launched in the background,
    /// where a waiting tap is restored too): a tap or a retry waiting for a
    /// call goes through then.
    var callWaitCanEnd: Bool { !isVoiceCallInProgress && isSceneActive && sceneHasBeenActive }

    /// Says on the phone why a call failed in the car: at once when the
    /// phone is on screen, otherwise when it next comes on. The composer's
    /// error line shows only while the composer is locked, so the notice
    /// over the screen carries it.
    func showCarPlayFailure(_ message: String, phoneOnScreen: Bool) {
        if phoneOnScreen {
            carPlayFailureForPhone = nil
            showNotice(message, systemImage: "car.fill")
        } else {
            carPlayFailureForPhone = message
        }
    }

    /// The car moved on from `message`: the phone no longer needs it.
    func clearCarPlayFailure(_ message: String) {
        if carPlayFailureForPhone == message { carPlayFailureForPhone = nil }
        if pinSyncNotice?.message == message { pinSyncNotice = nil }
    }

    /// The phone's screen came on: a failure from the car shows now.
    func presentCarPlayFailureIfWaiting() {
        guard let message = carPlayFailureForPhone else { return }
        carPlayFailureForPhone = nil
        showNotice(message, systemImage: "car.fill")
    }

    func publishNotice(_ notice: PinSyncNotice) {
        pinSyncNotice = notice
        UIAccessibility.post(notification: .announcement, argument: notice.message)
    }
}
