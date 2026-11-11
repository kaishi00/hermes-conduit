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
    /// When the last of them closed: the phone turns back after it.
    private(set) static var lastClosed: Date?
    /// Long enough for the phone to turn back to portrait once a full
    /// screen closes.
    static let turnBackTime: TimeInterval = 2

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
        lastClosed = Date()
        apply(turnTo: .portrait)
    }

    /// The width a screen under the full screen lays itself out by: on an
    /// iPhone, the one it had before the phone turned (`kept`), while the
    /// full screen is open and as the phone turns back. Turned sideways, an
    /// iPhone's window is wide enough to split the tabs into columns and to
    /// put a chat's Work panel beside it; either rebuilds the views the
    /// bot's screen opened from, and its sheet and full screen closed with
    /// them, back to the Bot Chat (Eric 2026-11-11). Its size is still the
    /// window's, under the black.
    static func layoutWidth(live: CGFloat, kept: CGFloat?) -> CGFloat {
        layoutWidth(live: live, kept: kept, idiom: UIDevice.current.userInterfaceIdiom,
                    landscapeHolders: landscapeHolders,
                    sinceClosed: lastClosed.map { Date().timeIntervalSince($0) })
    }

    /// Returns once the screens under a full screen may follow the window
    /// again, so a width that changed meanwhile (a Duo folded) is taken up
    /// even if it doesn't change again (Greptile on #2229). Only waits on
    /// an iPhone while one is open or the phone is turning back.
    static func layoutReleased() async {
        while !Task.isCancelled, landscapeHolders > 0
                || lastClosed.map({ Date().timeIntervalSince($0) < turnBackTime }) == true {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    static func layoutWidth(live: CGFloat, kept: CGFloat?, idiom: UIUserInterfaceIdiom,
                            landscapeHolders: Int, sinceClosed: TimeInterval?) -> CGFloat {
        guard idiom == .phone, let kept, kept > 0, kept != live else { return live }
        if landscapeHolders > 0 { return kept }
        if let sinceClosed, sinceClosed < turnBackTime { return kept }
        return live
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
