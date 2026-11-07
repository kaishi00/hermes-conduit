//
//  WindowSideInsets.swift
//  Conduit
//
//  A screen inside a navigation stack keeps to the window's safe area at
//  its sides as the shell reads it outside every stack, measured against
//  where the screen actually is, never as UIKit hands it to the stack.
//  An iPhone Duo's inner screen gave a stack the 84 pt of its side status
//  bar where the window had none: on the list column's trailing side
//  beside a chat (#1765), and on the leading side of a window in the left
//  half of a split screen (#1900), where the rows, the transcript and the
//  composer started 84 pt in while the tab bar and the chat's Back didn't.
//  On the Duo's outer screen the Chats stack sized itself wider than the
//  window once and stayed so, sliding its screen 27 pt off the left:
//  padding by the window's insets as numbers kept every too-wide width
//  stable (build 258). Measured, the padding is whatever keeps the screen
//  inside the safe area, wherever the stack put it.
//

import SwiftUI

/// A horizontal span in global coordinates: the window's safe area across,
/// read by a view outside every navigation stack (`windowSafeSpan`), or a
/// screen's own extent.
struct WindowSafeSpan: Equatable {
    var minX: CGFloat
    var maxX: CGFloat

    init(minX: CGFloat, maxX: CGFloat) {
        self.minX = minX
        self.maxX = maxX
    }

    init(_ frame: CGRect) {
        self.init(minX: frame.minX, maxX: frame.maxX)
    }

    /// How far a screen spanning `screen` keeps in from its left and right
    /// edges to stay inside this safe span: the part of it past the span
    /// on each side, never negative. A side already inside takes nothing,
    /// so a column that never reaches the window's edge takes none of its
    /// inset, and a stack wider than the window keeps its screen in view.
    /// Rounded to half points, so a measure's last digits can't make the
    /// layout settle again and again.
    func insets(of screen: WindowSafeSpan) -> (left: CGFloat, right: CGFloat) {
        func settled(_ value: CGFloat) -> CGFloat {
            max(0, (value * 2).rounded() / 2)
        }
        return (settled(minX - screen.minX), settled(screen.maxX - maxX))
    }
}

private struct WindowSafeSpanKey: EnvironmentKey {
    static let defaultValue: WindowSafeSpan? = nil
}

extension EnvironmentValues {
    /// The window's safe area across, in global coordinates, that the
    /// screens in a navigation stack keep to (`windowSideContent()`); nil
    /// where no shell read it (a sheet), and screens keep the safe area
    /// their stack gives them.
    var windowSafeSpan: WindowSafeSpan? {
        get { self[WindowSafeSpanKey.self] }
        set { self[WindowSafeSpanKey.self] = newValue }
    }
}

extension View {
    /// A screen inside a navigation stack: its sides keep to the window's
    /// safe area (`windowSafeSpan`) where the screen reaches past it, in
    /// place of whatever UIKit gave the stack. Applied to each screen in
    /// the stack, the root and every page it pushes, as a margin outside
    /// the stack doesn't reach them.
    func windowSideContent() -> some View {
        modifier(WindowSideContent())
    }
}

private struct WindowSideContent: ViewModifier {
    @Environment(\.windowSafeSpan) private var span
    @Environment(\.layoutDirection) private var layoutDirection
    /// Where the screen is, its side safe area ignored, in global
    /// coordinates. Its own frame, which the padding inside doesn't
    /// change, so measuring it never feeds back into itself.
    @State private var screen: WindowSafeSpan?

    func body(content: Content) -> some View {
        let sides = span.flatMap { span in screen.map { span.insets(of: $0) } } ?? (left: 0, right: 0)
        // Global coordinates run left to right whatever the language.
        let leftToRight = layoutDirection == .leftToRight
        // Values rather than a branch, so the screen keeps its views (and
        // a list its scroll position) when the shell first reads them.
        // The padding goes inside: the outer `ignoresSafeArea` drops the
        // stack's side insets, and the screen then takes the window's. The
        // other way round, it would ignore the padding too.
        content
            .safeAreaPadding(.leading, leftToRight ? sides.left : sides.right)
            .safeAreaPadding(.trailing, leftToRight ? sides.right : sides.left)
            .ignoresSafeArea(.container, edges: span == nil ? Edge.Set() : Edge.Set.horizontal)
            .onGeometryChange(for: WindowSafeSpan.self) { proxy in
                WindowSafeSpan(proxy.frame(in: .global))
            } action: { measured in
                if screen != measured { screen = measured }
            }
    }
}
