//
//  MacTooltip.swift
//  Conduit
//
//  An icon-only button names itself only to VoiceOver. On a Mac, where a
//  pointer can rest on it, it shows that name as a tooltip too.
//

import SwiftUI

extension View {
    /// Shows `text` as a tooltip when the iPhone app runs on a Mac. Not on
    /// iPhone or iPad: `.help` there also becomes the accessibility hint,
    /// and VoiceOver would read the label a second time.
    func macTooltip(_ text: String) -> some View {
        modifier(MacTooltip(text: text))
    }
}

private struct MacTooltip: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            content.help(text)
        } else {
            content
        }
    }
}
