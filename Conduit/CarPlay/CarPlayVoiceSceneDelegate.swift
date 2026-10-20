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
            CarPlayMapsHandoff.scene = templateApplicationScene
            CarPlayVoiceCoordinator.shared.handleConnect(interfaceController)
        }
    }

    /// Conduit's screen in the car comes back to the front (from Maps, a
    /// podcast app, the car's home screen). The connection may have died
    /// while another app was up (#1060).
    func sceneWillEnterForeground(_ scene: UIScene) {
        MainActor.assumeIsolated {
            CarPlayVoiceCoordinator.shared.handleSceneWillEnterForeground()
        }
    }

    /// The car's back button reports here, so a list that leaves the screen
    /// stops being kept current.
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        MainActor.assumeIsolated {
            CarPlayVoiceCoordinator.shared.handleTemplateDidDisappear(aTemplate)
        }
    }

    /// The voice screen coming back on top ends browsing.
    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        MainActor.assumeIsolated {
            CarPlayVoiceCoordinator.shared.handleTemplateDidAppear(aTemplate)
        }
    }

    /// The phone left the car. The protocol's name is
    /// `didDisconnectInterfaceController:`: a method named like
    /// `didConnect`'s (`didDisconnect:`) is never called, and the call
    /// would keep its audio session after the car is gone.
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        MainActor.assumeIsolated {
            CarPlayMapsHandoff.scene = nil
            CarPlayVoiceCoordinator.shared.handleDisconnect()
        }
    }
}
