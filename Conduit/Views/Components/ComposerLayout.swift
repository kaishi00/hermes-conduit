//
//  ComposerLayout.swift
//  Conduit
//
//  Whether the composer rests as a slim bar until it is used or stays
//  expanded with its controls showing (#1483): compact on an iPhone,
//  expanded on an iPad with the room for it and always on a Mac.
//

import Combine
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
    /// be typed straight away as in a desktop client: on a Mac, or on an
    /// iPad with a hardware keyboard. An iPhone always lets it go, keyboard
    /// or not, so the reply has the screen.
    static func keepsFocusAfterSend(
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom,
        onMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac,
        hardwareKeyboard: Bool = GCKeyboard.coalesced != nil
    ) -> Bool {
        if onMac { return true }
        return idiom != .phone && hardwareKeyboard
    }

    /// Whether a chat or room opens with its composer focused, ready to
    /// type, as in a desktop client: on a Mac (issue 1692), as New Chat
    /// already did there. An iPhone or iPad keeps the keyboard down until
    /// the field is tapped, so it doesn't cover what just opened.
    static func focusesOnOpen(onMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac) -> Bool {
        onMac
    }

    /// Whether ⌘V in an open conversation's transcript pastes into its
    /// composer (issue 1692): on a Mac, where the transcript keeps the
    /// keys once a click there put the composer's focus away.
    static func transcriptTakesPaste(onMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac) -> Bool {
        onMac
    }

    /// An opened conversation's composer may take focus now: nothing is
    /// presented in front, and no other text field (the list's search, a
    /// rename) holds focus, whose typing it would take over.
    @MainActor static var openMayTakeFocus: Bool {
        KeyboardCommands.nothingInFront && !ReturnKeyTextView.anotherFieldHasFocus
    }
}

/// Which composer ⌘V in a transcript pastes into.
enum ComposerPasteTarget: Equatable {
    /// The open chat's (ComposerBar).
    case chat
    /// The open group room's (GroupRoomComposer).
    case room
}

/// ⌘V in the open conversation's transcript on a Mac (issue 1692): the
/// composer on screen for the target takes focus and the paste, as if ⌘V
/// had come to its field (`ReturnKeyTextView.pasteOnceFocused`).
@MainActor
enum ComposerPaste {
    static let requests = PassthroughSubject<ComposerPasteTarget, Never>()

    /// The clipboard holds something a composer takes: words, a link, a
    /// picture or a file, all of which list a type. Read from its types
    /// only, so asking never raises the paste prompt.
    static var clipboardHasSomething: Bool {
        !UIPasteboard.general.types.isEmpty
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
