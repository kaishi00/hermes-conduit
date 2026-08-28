//
//  ComposerReturnKey.swift
//  Conduit
//
//  Policy layer for the optional hardware-keyboard Return shortcut in the
//  chat composer. The UIKit text view only classifies the keystroke (Return
//  with or without Shift held); this type owns the send-vs-newline decision
//  so it stays pure and unit-testable. ComposerBar remains the sole
//  authority on which composer action is actually available.
//

import Foundation

enum ComposerReturnKey {
    /// Local, device-only input preference backed by UserDefaults via
    /// @AppStorage. It is presentation/input state for this device and is
    /// never synchronized to the Hermes profile or gateway.
    static let preferenceKey = "conduit.composerReturnKeySends"

    /// What the text view should do with one hardware Return press.
    enum Decision: Equatable {
        case submit
        case insertNewline
    }

    /// Pure shortcut policy:
    /// - With the preference off, Return keeps its default newline behavior.
    /// - Shift-Return always inserts a newline, even when the shortcut is on.
    /// - A non-submittable composer never swallows Return; it falls back to
    ///   the default newline behavior instead.
    static func decision(
        returnKeySends: Bool,
        shiftPressed: Bool,
        canSubmit: Bool
    ) -> Decision {
        guard returnKeySends, !shiftPressed, canSubmit else { return .insertNewline }
        return .submit
    }

    /// Whether the composer's currently valid action may be triggered from
    /// Return. Only typed-message actions qualify. A running response with an
    /// empty composer is stop-only; Return must never act as the Stop button.
    static func canSubmit(action: ComposerAction) -> Bool {
        switch action {
        case .send, .steer, .interrupt: return true
        case .stop, .unavailable: return false
        }
    }
}
