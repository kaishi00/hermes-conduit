//
//  WindowCornerClearance.swift
//  Conduit
//
//  A bar Conduit draws itself at the top of a screen (the tabs' top bars,
//  Bots Home's header, a sheet's header) keeps its controls clear of what
//  iOS stands in the window's top corners. On an iPhone Duo's inner screen
//  in portrait the clock, wifi and battery stand in a panel in the top
//  trailing corner, below the top of the safe area: the Chats bar's Folder
//  and Pulse buttons sat under it (a tester's TestFlight report,
//  2026-11-26). iPadOS 26's window controls stand in a top leading corner
//  the same way. iOS reports neither as a top inset, only through the
//  corner-adaptive safe area (iOS 26), which a system navigation bar
//  follows on its own and a bar of our own has to read.
//

import SwiftUI
import UIKit

/// How far the window's top corners reach into a bar, at each side, past
/// the safe area the bar already keeps to.
struct WindowCornerReach: Equatable {
    var leading: CGFloat
    var trailing: CGFloat

    static let zero = WindowCornerReach(leading: 0, trailing: 0)

    /// The room between a corner's panel and the control beside it.
    static let gap: CGFloat = 8

    /// A side's padding: the bar's own, or more where a corner reaches
    /// further in than it. A screen's rounded corner (a couple of points,
    /// the Duo's outer screen) stays inside the bar's own padding.
    static func padding(_ base: CGFloat, reach: CGFloat) -> CGFloat {
        reach > 0 ? max(base, reach + gap) : base
    }

    /// The reach from a view's insets with the corners adapted
    /// horizontally and without: what the corners add, never less than
    /// nothing.
    init(adapted: NSDirectionalEdgeInsets, plain: NSDirectionalEdgeInsets) {
        leading = max(0, adapted.leading - plain.leading)
        trailing = max(0, adapted.trailing - plain.trailing)
    }

    init(leading: CGFloat, trailing: CGFloat) {
        self.leading = leading
        self.trailing = trailing
    }
}

extension View {
    /// Pads the bar `base` at its sides, and further at a side where a
    /// window corner reaches into it (`WindowCornerReach`). Where nothing
    /// does (an iPhone, a full-screen iPad, before iOS 26), it is
    /// `.padding(.horizontal, base)`.
    ///
    /// - Parameters:
    ///   - outer: padding a container already gives the bar at both sides
    ///     (the drawer's column), counted toward the clearance: the bar
    ///     adds only what the corner needs past it.
    ///   - symmetric: both sides take the larger side's padding, so a
    ///     centered title stays centered (a sheet's header).
    func cornerClearingHorizontalPadding(_ base: CGFloat, outer: CGFloat = 0, symmetric: Bool = false) -> some View {
        modifier(CornerClearingHorizontalPadding(base: base, outer: outer, symmetric: symmetric))
    }
}

extension WindowCornerReach {
    /// The leading and trailing padding a bar takes (see
    /// `cornerClearingHorizontalPadding`).
    func paddings(base: CGFloat, outer: CGFloat = 0, symmetric: Bool = false) -> (leading: CGFloat, trailing: CGFloat) {
        let leading = Self.padding(base + outer, reach: self.leading) - outer
        let trailing = Self.padding(base + outer, reach: self.trailing) - outer
        if symmetric {
            let both = max(leading, trailing)
            return (both, both)
        }
        return (leading, trailing)
    }
}

private struct CornerClearingHorizontalPadding: ViewModifier {
    let base: CGFloat
    let outer: CGFloat
    let symmetric: Bool
    @State private var reach = WindowCornerReach.zero

    func body(content: Content) -> some View {
        let paddings = reach.paddings(base: base, outer: outer, symmetric: symmetric)
        content
            .padding(.leading, paddings.leading)
            .padding(.trailing, paddings.trailing)
            // The reader spans the whole bar, padding included: the
            // padding never changes its frame, so it can't feed back.
            .background {
                WindowCornerReader { reach = $0 }
                    .accessibilityHidden(true)
            }
    }
}

/// Reads `WindowCornerReach` for the frame it's laid out in, again
/// whenever its place, the window or the safe area changes (a Duo folded
/// or turned, an iPad window moved).
private struct WindowCornerReader: UIViewRepresentable {
    let onChange: (WindowCornerReach) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.read()
    }

    final class ReaderView: UIView {
        var onChange: ((WindowCornerReach) -> Void)?
        private var reported: WindowCornerReach?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            read()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            read()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            read()
        }

        func read() {
            guard window != nil else { return }
            let reach: WindowCornerReach
            if #available(iOS 26.0, *) {
                reach = WindowCornerReach(
                    adapted: directionalEdgeInsets(for: .safeArea(cornerAdaptation: .horizontal)),
                    plain: directionalEdgeInsets(for: .safeArea())
                )
            } else {
                reach = .zero
            }
            guard reach != reported else { return }
            reported = reach
            // Not during the layout pass that read it.
            DispatchQueue.main.async { [onChange] in onChange?(reach) }
        }
    }
}
