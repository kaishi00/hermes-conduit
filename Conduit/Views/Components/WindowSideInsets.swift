//
//  WindowSideInsets.swift
//  Conduit
//
//  A screen inside a navigation stack takes the window's side safe area as
//  the shell reads it outside the stack, not as UIKit hands it to the
//  stack. An iPhone Duo's inner screen gave a stack the 84 pt of its side
//  status bar where the window had none: on the list column's trailing
//  side beside a chat (#1765), and on the leading side of a window in the
//  left half of a split screen (#1900), where the rows, the transcript and
//  the composer started 84 pt in while the tab bar and the chat's Back
//  didn't.
//

import SwiftUI

/// The window's safe area at its sides, read by a view outside every
/// navigation stack, less the sides a column doesn't reach.
struct WindowSideInsets: Equatable {
    var leading: CGFloat
    var trailing: CGFloat

    init(leading: CGFloat, trailing: CGFloat) {
        self.leading = leading
        self.trailing = trailing
    }

    init(_ insets: EdgeInsets) {
        self.init(leading: insets.leading, trailing: insets.trailing)
    }

    /// A column's share: the window's inset on the sides it reaches, none
    /// on a side that meets another column.
    func reaching(_ edges: HorizontalEdge.Set) -> WindowSideInsets {
        WindowSideInsets(
            leading: edges.contains(.leading) ? leading : 0,
            trailing: edges.contains(.trailing) ? trailing : 0
        )
    }
}

private struct WindowSideInsetsKey: EnvironmentKey {
    static let defaultValue: WindowSideInsets? = nil
}

extension EnvironmentValues {
    /// The side safe area the screens in this column take
    /// (`windowSideContent()`); nil where no shell read it (a sheet), and
    /// screens keep the safe area their stack gives them.
    var windowSideInsets: WindowSideInsets? {
        get { self[WindowSideInsetsKey.self] }
        set { self[WindowSideInsetsKey.self] = newValue }
    }
}

extension View {
    /// A screen inside a navigation stack: its sides take the column's
    /// share of the window's safe area (`windowSideInsets`) in place of
    /// whatever UIKit gave the stack. Applied to each screen in the stack,
    /// the root and every page it pushes, as a margin outside the stack
    /// doesn't reach them.
    func windowSideContent() -> some View {
        modifier(WindowSideContent())
    }
}

private struct WindowSideContent: ViewModifier {
    @Environment(\.windowSideInsets) private var insets

    func body(content: Content) -> some View {
        // Values rather than a branch, so the screen keeps its views (and
        // a list its scroll position) when the shell first reads them.
        // The padding goes inside: the outer `ignoresSafeArea` drops the
        // stack's side insets, and the screen then takes the window's. The
        // other way round, it would ignore the padding too, and a window
        // with side insets of its own (a landscape iPhone's sensor) would
        // lose them.
        content
            .safeAreaPadding(.leading, insets?.leading ?? 0)
            .safeAreaPadding(.trailing, insets?.trailing ?? 0)
            .ignoresSafeArea(.container, edges: insets == nil ? Edge.Set() : Edge.Set.horizontal)
    }
}
