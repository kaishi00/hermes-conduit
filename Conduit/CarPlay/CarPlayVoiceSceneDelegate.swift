//
//  CarPlayVoiceSceneDelegate.swift
//  Conduit
//
//  The scene delegate declared in Info.plist for
//  `CPTemplateApplicationSceneSessionRoleApplication`. Thin by design: every
//  decision lives in CarPlayVoiceCoordinator and AppState. The non-window
//  `didConnect` variant is used — Conduit is a voice-conversation CarPlay
//  app, not a navigation app.
//

import CarPlay
import UIKit

final class CarPlayVoiceSceneDelegate: NSObject, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        // UISceneDelegate callbacks run on the main thread.
        MainActor.assumeIsolated {
            interfaceController.delegate = self
            CarPlayVoiceCoordinator.shared.handleConnect(interfaceController)
        }
    }

    /// The car's back button reports here, so a list that leaves the screen
    /// stops being kept current.
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        MainActor.assumeIsolated {
            CarPlayVoiceCoordinator.shared.handleTemplateDidDisappear(aTemplate)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        MainActor.assumeIsolated {
            CarPlayVoiceCoordinator.shared.handleDisconnect()
        }
    }
}
