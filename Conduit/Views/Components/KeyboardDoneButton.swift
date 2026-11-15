//
//  KeyboardDoneButton.swift
//  Conduit
//
//  A Done button above the software keyboard, to put it away. A Mac has no
//  software keyboard, so there the toolbar has nothing to sit on and SwiftUI
//  draws its Done on its own in the window's bottom-right corner.
//

import SwiftUI

extension View {
    /// Adds Done above the keyboard, running `action` (usually clearing the
    /// focused field). Left out when the iPhone app runs on a Mac, where a
    /// click elsewhere or Return already ends the editing. `isActive`
    /// false leaves it out: a field on a screen with other fields passes
    /// its own focus, since the keyboard shows every view's items there.
    func keyboardDoneButton(
        identifier: String? = nil,
        isActive: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        modifier(KeyboardDoneButton(identifier: identifier, isActive: isActive, action: action))
    }
}

private struct KeyboardDoneButton: ViewModifier {
    let identifier: String?
    let isActive: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            content
        } else {
            content.toolbar {
                if isActive {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        if let identifier {
                            Button("Done", action: action)
                                .accessibilityIdentifier(identifier)
                        } else {
                            Button("Done", action: action)
                        }
                    }
                }
            }
        }
    }
}
