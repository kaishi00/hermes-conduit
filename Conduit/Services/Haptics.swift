//
//  Haptics.swift
//  Conduit
//
//  Centralized haptic feedback with a user-toggleable preference, including
//  calibrated response lifecycle patterns and subordinate tool activity.
//

import CoreHaptics
import SwiftUI
import UIKit

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

    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static var coreHapticsEngine: CHHapticEngine?
    private static var lifecyclePatternPlayer: CHHapticPatternPlayer?
    private static var lifecyclePatternTask: Task<Void, Never>?
    private static var lifecyclePatternToken: UUID?
    private static var lifecyclePatternEndsAt = Date.distantPast

#if DEBUG
    static var testEmissionHandler: ((Event) -> Void)?
    static var testSuppressesHardware = false
#endif

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    static func soft() {
        guard enabled else { return }
        softGenerator.impactOccurred()
        softGenerator.prepare()
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
    static func toolStarted() {
        guard enabled, Date() >= lifecyclePatternEndsAt else { return }
        softGenerator.impactOccurred(intensity: 0.65)
        softGenerator.prepare()
    }

    static func responseStarted() {
        guard enabled else { return }
        let token = beginLifecyclePattern(duration: 0.18)
        do {
            let engine: CHHapticEngine
            if let coreHapticsEngine {
                engine = coreHapticsEngine
            } else {
                engine = try CHHapticEngine()
                engine.isAutoShutdownEnabled = true
                coreHapticsEngine = engine
            }
            try engine.start()
            let events = [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: Self.transientParameters(intensity: 1),
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: Self.transientParameters(intensity: 0.59),
                    relativeTime: 0.060
                ),
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: Self.transientParameters(intensity: 0.52),
                    relativeTime: 0.150
                )
            ]
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            lifecyclePatternPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
            lifecyclePatternTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                finishLifecyclePattern(token)
            }
        } catch {
            playResponseStartFallback(token: token)
        }
    }

    static func responseConcluded() {
        guard enabled else { return }
        let token = beginLifecyclePattern(duration: 0.20)
        lightGenerator.impactOccurred(intensity: 0.79)
        lightGenerator.prepare()
        lifecyclePatternTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(173))
                guard lifecyclePatternToken == token, enabled else { return }
                mediumGenerator.impactOccurred(intensity: 1)
                mediumGenerator.prepare()
                finishLifecyclePattern(token)
            } catch {
                return
            }
        }
    }

    static func cancelLifecyclePattern() {
        lifecyclePatternTask?.cancel()
        try? lifecyclePatternPlayer?.stop(atTime: CHHapticTimeImmediate)
        lifecyclePatternTask = nil
        lifecyclePatternPlayer = nil
        lifecyclePatternToken = nil
        lifecyclePatternEndsAt = .distantPast
    }

    static func prepare() {
        softGenerator.prepare()
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

    private static func transientParameters(intensity: Float) -> [CHHapticEventParameter] {
        [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
        ]
    }

    private static func playResponseStartFallback(token: UUID) {
        mediumGenerator.impactOccurred(intensity: 1)
        mediumGenerator.prepare()
        lifecyclePatternTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(60))
                guard lifecyclePatternToken == token, enabled else { return }
                lightGenerator.impactOccurred(intensity: 0.8)
                try await Task.sleep(for: .milliseconds(90))
                guard lifecyclePatternToken == token, enabled else { return }
                lightGenerator.impactOccurred(intensity: 0.7)
                lightGenerator.prepare()
                finishLifecyclePattern(token)
            } catch {
                return
            }
        }
    }

    private static func beginLifecyclePattern(duration: TimeInterval) -> UUID {
        cancelLifecyclePattern()
        let token = UUID()
        lifecyclePatternToken = token
        lifecyclePatternEndsAt = Date().addingTimeInterval(duration)
        return token
    }

    private static func finishLifecyclePattern(_ token: UUID) {
        guard lifecyclePatternToken == token else { return }
        lifecyclePatternPlayer = nil
        lifecyclePatternTask = nil
        lifecyclePatternToken = nil
        lifecyclePatternEndsAt = .distantPast
    }
}
