//
//  ModifierHost.swift
//  Conduit
//
//  Content that may show nothing, whose `onAppear`, `task`, `onChange` and
//  `onReceive` still run.
//

import SwiftUI

/// Holds content that may show nothing, so the modifiers on it still run.
///
/// A `Group` hands its modifiers to each view inside it, so a `Group`
/// whose `if` shows nothing has no view to carry them: its `onAppear` and
/// `task` never run, and a view that waits on its own read to show stays
/// empty for good (Helper models' pages opened blank, 2026-11-07). This
/// keeps a view of no size under the content to carry them. It has a
/// place in its parent stack, so the stack's spacing still applies while
/// nothing shows.
struct ModifierHost<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            content
        }
    }
}
