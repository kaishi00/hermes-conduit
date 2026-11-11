import UIKit

/// Which way the iPhone app may turn. Conduit stays in portrait on an
/// iPhone; a bot's screen in full screen turns sideways too, so a wide
/// desktop fills the phone (Eric 2026-11-11). The iPad turns everywhere, as
/// it always has. Info.plist lists landscape for the iPhone only so this
/// can allow it; `ConduitAppDelegate` asks here.
@MainActor
enum InterfaceOrientationGate {
    /// The full screens that turn sideways now open.
    private(set) static var landscapeHolders = 0

    static var supported: UIInterfaceOrientationMask {
        supported(idiom: UIDevice.current.userInterfaceIdiom, landscapeHolders: landscapeHolders)
    }

    static func supported(idiom: UIUserInterfaceIdiom, landscapeHolders: Int) -> UIInterfaceOrientationMask {
        guard idiom == .phone else { return .all }
        return landscapeHolders > 0 ? .allButUpsideDown : .portrait
    }

    /// A full screen that turns sideways opened: it turns to landscape now,
    /// and the phone may turn it back and forth while it's open.
    static func allowLandscape() {
        landscapeHolders += 1
        guard landscapeHolders == 1 else { return }
        // The side the phone is already turned to, if it's sideways. A device
        // turned left shows the interface turned right.
        apply(turnTo: UIDevice.current.orientation == .landscapeRight ? .landscapeLeft : .landscapeRight)
    }

    /// It closed: back to portrait once none is open.
    static func endLandscape() {
        guard landscapeHolders > 0 else { return }
        landscapeHolders -= 1
        guard landscapeHolders == 0 else { return }
        apply(turnTo: .portrait)
    }

    private static func apply(turnTo orientation: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
        }
    }
}
