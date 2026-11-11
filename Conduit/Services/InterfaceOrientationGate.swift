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
    /// The bot's screens open (a sheet, its full screen inside it): while
    /// one is, the screens under it keep their width, so Exit Full Screen
    /// with the phone still turning back, or a Duo folded meanwhile, can't
    /// rebuild the views the sheet opened from either (DeepSeek on #2229).
    private(set) static var layoutHolders = 0
    /// When the last full screen or sheet closed: the phone turns back after it.
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

    /// A bot's screen opened: the screens under it keep their width.
    static func holdLayout() {
        layoutHolders += 1
    }

    /// It closed: they follow the window again once the phone has turned back.
    static func releaseLayout() {
        guard layoutHolders > 0 else { return }
        layoutHolders -= 1
        if layoutHolders == 0 { lastClosed = Date() }
    }

    /// The width a screen under a bot's screen lays itself out by: on an
    /// iPhone, the one it had before the phone turned (`kept`), while the
    /// screen (its sheet or full screen) is open and as the phone turns back. Turned sideways, an
    /// iPhone's window is wide enough to split the tabs into columns and to
    /// put a chat's Work panel beside it; either rebuilds the views the
    /// bot's screen opened from, and its sheet and full screen closed with
    /// them, back to the Bot Chat (Eric 2026-11-11). Its size is still the
    /// window's, under the black.
    static func layoutWidth(live: CGFloat, kept: CGFloat?) -> CGFloat {
        layoutWidth(live: live, kept: kept, idiom: UIDevice.current.userInterfaceIdiom,
                    holders: landscapeHolders + layoutHolders,
                    sinceClosed: lastClosed.map { Date().timeIntervalSince($0) })
    }

    static func layoutWidth(live: CGFloat, kept: CGFloat?, idiom: UIUserInterfaceIdiom,
                            holders: Int, sinceClosed: TimeInterval?) -> CGFloat {
        guard idiom == .phone, let kept, kept > 0,
              holdLeft(holders: holders, sinceClosed: sinceClosed) != nil else { return live }
        return kept
    }

    /// How much longer the screens under it keep their width: for as long
    /// as a bot's screen or its full screen is open, then the rest of the
    /// turn back; nil once they follow the window again.
    static var holdLeft: TimeInterval? {
        holdLeft(holders: landscapeHolders + layoutHolders, sinceClosed: lastClosed.map { Date().timeIntervalSince($0) })
    }

    static func holdLeft(holders: Int, sinceClosed: TimeInterval?) -> TimeInterval? {
        if holders > 0 { return .infinity }
        guard let sinceClosed, sinceClosed < turnBackTime else { return nil }
        return turnBackTime - sinceClosed
    }

    /// Returns once the screens under a full screen may follow the window
    /// again, so a width that changed meanwhile (a Duo folded) is taken up
    /// even if it doesn't change again (Greptile on #2229). While one is
    /// open it looks again every half second; as the phone turns back it
    /// sleeps once, to the end of it.
    static func layoutReleased() async {
        while !Task.isCancelled, let left = holdLeft {
            try? await Task.sleep(for: .seconds(left.isFinite ? left : 0.5))
        }
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
