import SwiftUI
import UIKit

/// Whether a group room's transcript follows the latest event, by the chat
/// screen's rules (ChatScrollEngine): only the user's own scrolling leaves
/// following, and only bringing the transcript back near the bottom (or an
/// explicit jump or send) returns to it. Events arriving below never change
/// it, so reading history while a member works stays put.
enum GroupRoomFollow {
    /// The chat screen's tolerance (ChatScrollEngine.nearBottomTolerance).
    static let nearBottomTolerance: CGFloat = 40

    /// The follow state after a scroll or layout change. Being near the
    /// bottom always follows (a trim or a shorter row can land the reader
    /// there); otherwise only the user's own scroll leaves following, and a
    /// change they didn't drive (new rows, a programmatic scroll) keeps
    /// `current`.
    static func following(
        current: Bool,
        userScrolling: Bool,
        distanceFromBottom: CGFloat,
        landing: Bool = false
    ) -> Bool {
        // A landing's own animated scroll can pass near the bottom (the
        // content may grow after its first frame): it decides once it's
        // over, unless the user takes over.
        if landing, !userScrolling { return current }
        if distanceFromBottom <= nearBottomTolerance { return true }
        return userScrolling ? false : current
    }

    /// The member message a following transcript lands at the top of when
    /// new events arrive, as a long chat reply stops at its start (#365):
    /// the first one after the row that was last before them. Nil scrolls
    /// to the bottom as before: nothing new from a member, or that row is
    /// gone (another room).
    static func replyStart(in events: [GroupEvent], after previousLastID: String?) -> String? {
        guard let previousLastID,
              let index = events.lastIndex(where: { $0.id == previousLastID }) else { return nil }
        return events[(index + 1)...].first(where: \.isMemberMessage)?.id
    }
}

/// The follow decision, shared by reference: the transcript's scroll gates
/// read it in the same turn a drag changes it, while the jump button waits
/// for the published copy.
final class GroupRoomFollowFlag {
    var isFollowing = true
    /// A landing at a new member message is scrolling there (landAtTop):
    /// only the user's own scroll or the landing's end decides.
    var isLanding = false
    /// Stamps each landing, so an earlier landing's end can't end a later
    /// one still scrolling.
    var landingGeneration = 0
    /// Decides again from where the transcript is now, for a programmatic
    /// scroll that may not move the offset at all (set by the locator).
    var reevaluate: (@MainActor () -> Void)?
}

/// Placed behind the room's transcript stack inside its ScrollView. Finds
/// the UIScrollView SwiftUI renders it with and reports follow changes from
/// the user's drags (iOS 17 has no SwiftUI API for scroll geometry).
struct GroupRoomScrollLocator: UIViewRepresentable {
    let flag: GroupRoomFollowFlag
    /// The published copy, for what the view draws.
    @Binding var isFollowing: Bool

    func makeUIView(context: Context) -> GroupRoomScrollLocatorView {
        GroupRoomScrollLocatorView(flag: flag)
    }

    func updateUIView(_ view: GroupRoomScrollLocatorView, context: Context) {
        view.flag = flag
        flag.reevaluate = { [weak view] in view?.reevaluate() }
        let binding = $isFollowing
        view.onChange = { following in
            // KVO can land mid-update; write the binding after it.
            DispatchQueue.main.async { binding.wrappedValue = following }
        }
    }

    static func dismantleUIView(_ view: GroupRoomScrollLocatorView, coordinator: ()) {
        view.disconnect()
    }
}

final class GroupRoomScrollLocatorView: UIView {
    var flag: GroupRoomFollowFlag
    var onChange: ((Bool) -> Void)?

    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var lastAdjustedInsets = UIEdgeInsets.zero

    init(flag: GroupRoomFollowFlag) {
        self.flag = flag
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            disconnect()
        } else {
            connectIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        connectIfNeeded()
        // adjustedContentInset (safe area, keyboard) is not KVO-observable;
        // a change to it re-lays out the content, which lands here.
        if let scrollView, scrollView.adjustedContentInset != lastAdjustedInsets {
            lastAdjustedInsets = scrollView.adjustedContentInset
            scrolled()
        }
    }

    func disconnect() {
        observations.forEach { $0.invalidate() }
        observations = []
        scrollView = nil
    }

    private func connectIfNeeded() {
        guard window != nil else { return }
        var candidate = superview
        while let view = candidate, !(view is UIScrollView) {
            candidate = view.superview
        }
        guard let found = candidate as? UIScrollView, found !== scrollView else { return }
        disconnect()
        scrollView = found
        observations = [
            found.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                Self.onMain { self?.scrolled() }
            },
            found.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                Self.onMain { self?.scrolled() }
            },
            // Bounds origin is the offset; a size change is the keyboard,
            // rotation or split view.
            found.observe(\.contentInset, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                Self.onMain { self?.scrolled() }
            },
            found.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue?.size != change.newValue?.size else { return }
                Self.onMain { self?.scrolled() }
            },
        ]
    }

    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { body() }
        }
    }

    func reevaluate() {
        flag.isLanding = false
        scrolled()
    }

    private func scrolled() {
        guard let scrollView else { return }
        let distance = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
            - (scrollView.contentOffset.y + scrollView.bounds.height)
        let userScrolling = scrollView.isTracking || scrollView.isDecelerating
        if userScrolling { flag.isLanding = false }
        let next = GroupRoomFollow.following(
            current: flag.isFollowing,
            userScrolling: userScrolling,
            distanceFromBottom: distance,
            landing: flag.isLanding
        )
        guard next != flag.isFollowing else { return }
        flag.isFollowing = next
        onChange?(next)
    }
}
