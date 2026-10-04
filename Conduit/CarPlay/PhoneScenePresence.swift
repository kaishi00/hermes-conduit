//
//  PhoneScenePresence.swift
//  Conduit
//
//  Whether Conduit's phone screen is in the foreground. CarPlay can run the
//  app with the phone screen in the background, or with no phone screen at
//  all when the car launched Conduit (#378). Work that needs the phone
//  screen (the dashboard page WebKit keeps running only while it is on
//  screen) asks here instead of assuming it.
//

import UIKit

@MainActor
enum PhoneScenePresence {
    /// True while a phone window scene is in the foreground, active or
    /// passing through inactive (Control Center, a Face ID prompt). A phone
    /// scene in the background, or none at all, is false.
    static var isInForeground: Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            guard scene.session.role == .windowApplication else { return false }
            switch scene.activationState {
            case .foregroundActive, .foregroundInactive: return true
            case .background, .unattached: return false
            @unknown default: return false
            }
        }
    }
}
