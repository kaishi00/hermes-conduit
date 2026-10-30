//
//  ComposerLayout.swift
//  Conduit
//
//  Whether the composer rests as a slim bar until it is used or stays
//  expanded with its controls showing (#1483): compact on an iPhone,
//  expanded on an iPad with the room for it and always on a Mac.
//

import GameController
import SwiftUI
import UIKit

enum ComposerLayout {
    /// The chat's width from which an iPad keeps the composer expanded:
    /// the controls row, the model chip readable, and the big voice button
    /// beside it.
    static let expandedMinimumWidth: CGFloat = 600

    static func staysExpanded(
        width: CGFloat,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom,
        onMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac
    ) -> Bool {
        if onMac { return true }
        guard idiom != .phone else { return false }
        return width >= expandedMinimumWidth
    }

    /// Whether the field keeps focus after a send, so the next message can
    /// be typed straight away as in a desktop client: on a Mac, or with a
    /// hardware keyboard. With only the on-screen keyboard it goes down, so
    /// the reply has the screen.
    static func keepsFocusAfterSend(
        onMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac,
        hardwareKeyboard: Bool = GCKeyboard.coalesced != nil
    ) -> Bool {
        onMac || hardwareKeyboard
    }
}

private struct ComposerStaysExpandedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The chat's composer keeps its controls showing rather than resting
    /// (`ComposerLayout`).
    var composerStaysExpanded: Bool {
        get { self[ComposerStaysExpandedKey.self] }
        set { self[ComposerStaysExpandedKey.self] = newValue }
    }
}

extension View {
    /// Sets `composerStaysExpanded` from the width this view is given.
    func composerLayoutFromWidth() -> some View {
        modifier(ComposerLayoutFromWidth())
    }
}

private struct ComposerLayoutFromWidth: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.composerStaysExpanded, ComposerLayout.staysExpanded(width: width))
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
                }
            }
    }
}
