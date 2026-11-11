//
//  SystemSettings.swift
//  Conduit
//
//  Where to allow something for Conduit outside the app, worded and
//  opened for the device it runs on. On a Mac the iPad app's settings URLs
//  open its own settings window (Touch Alternatives), not System
//  Settings, and "iPhone Settings" names the wrong device (issue 2208), so
//  each Open Settings button names the pane it needs and the words come
//  in an iPhone, an iPad and a Mac form.
//

import UIKit

enum SystemSettings {
    /// The pane a permission or setting lives in.
    enum Pane: Equatable {
        case notifications
        case microphone
        case speechRecognition
        case camera
        case location
        case contacts
    }

    enum Device: Equatable {
        case iPhone
        case iPad
        case mac

        static var current: Device {
            if ProcessInfo.processInfo.isiOSAppOnMac { return .mac }
            return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        }
    }

    /// The words for the device Conduit runs on.
    static func worded(
        iPhone: @autoclosure () -> String,
        iPad: @autoclosure () -> String,
        mac: @autoclosure () -> String,
        on device: Device = .current
    ) -> String {
        switch device {
        case .iPhone: return iPhone()
        case .iPad: return iPad()
        case .mac: return mac()
        }
    }

    /// Finish setting up's notifications row, and a steps card with a
    /// timer while they're off.
    static var notificationsOffText: String {
        worded(
            iPhone: AppLocalization.string("Notifications are off for Conduit in iPhone Settings."),
            iPad: AppLocalization.string("Notifications are off for Conduit in iPad Settings."),
            mac: AppLocalization.string("Notifications are off for Conduit in System Settings → Notifications.")
        )
    }

    /// Opens the pane. On a Mac, System Settings at that pane (Conduit's
    /// row under Notifications); should macOS turn the link down, the
    /// app's own settings as before. Elsewhere Conduit's page in Settings,
    /// its notifications page for notifications.
    @MainActor
    static func open(_ pane: Pane, on device: Device = .current) {
        let fallback = URL(string: pane == .notifications
            ? UIApplication.openNotificationSettingsURLString
            : UIApplication.openSettingsURLString)
        guard device == .mac, let url = macURL(for: pane, bundleID: Bundle.main.bundleIdentifier) else {
            if let fallback { UIApplication.shared.open(fallback) }
            return
        }
        UIApplication.shared.open(url) { opened in
            guard !opened, let fallback else { return }
            UIApplication.shared.open(fallback)
        }
    }

    /// The System Settings link for the pane on a Mac.
    static func macURL(for pane: Pane, bundleID: String?) -> URL? {
        let link: String
        switch pane {
        case .notifications:
            link = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                + (bundleID.map { "?id=\($0)" } ?? "")
        case .microphone:
            link = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognition:
            link = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .camera:
            link = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .location:
            link = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        case .contacts:
            link = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        }
        return URL(string: link)
    }
}
