//
//  Haptics.swift
//  Conduit
//
//  Centralized haptic feedback with a user-toggleable preference.
//  Usage: Haptics.light() / Haptics.medium() / Haptics.success() / Haptics.selection()
//

import SwiftUI

@MainActor
enum Haptics {
    static let preferenceKey = "conduit.haptics"

    enum Event: Equatable {
        case light
        case medium
        case rigid
        case success
        case error
        case warning
        case selection
    }

    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()

#if DEBUG
    static var testEmissionHandler: ((Event) -> Void)?
    static var testSuppressesHardware = false
#endif

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    static func light() {
        emit(.light) {
            lightGenerator.impactOccurred()
            lightGenerator.prepare()
        }
    }

    static func medium() {
        emit(.medium) {
            mediumGenerator.impactOccurred()
            mediumGenerator.prepare()
        }
    }

    static func rigid() {
        emit(.rigid) {
            rigidGenerator.impactOccurred()
            rigidGenerator.prepare()
        }
    }

    static func success() {
        emit(.success) {
            notificationGenerator.notificationOccurred(.success)
            notificationGenerator.prepare()
        }
    }

    static func error() {
        emit(.error) {
            notificationGenerator.notificationOccurred(.error)
            notificationGenerator.prepare()
        }
    }

    static func warning() {
        emit(.warning) {
            notificationGenerator.notificationOccurred(.warning)
            notificationGenerator.prepare()
        }
    }

    static func selection() {
        emit(.selection) {
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        }
    }
    static func selectionChanged(_ changed: Bool) {
        guard changed else { return }
        selection()
    }

    static func mutationCompleted(_ succeeded: Bool) {
        succeeded ? success() : error()
    }

    static func prepare() {
        lightGenerator.prepare()
        mediumGenerator.prepare()
        rigidGenerator.prepare()
        notificationGenerator.prepare()
        selectionGenerator.prepare()
    }

    private static func emit(_ event: Event, action: () -> Void) {
        guard enabled else { return }
#if DEBUG
        testEmissionHandler?(event)
        guard !testSuppressesHardware else { return }
#endif
        action()
    }
}
