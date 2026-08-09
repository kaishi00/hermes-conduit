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

struct ResponseHapticState {
    enum Effect: Equatable {
        case responseStarted
        case toolStarted
        case responseConcluded
        case error
        case cancelPattern
    }

    struct Conclusion: Equatable {
        let token: UUID
        let sessionID: String?
    }

    private(set) var pendingConclusion: Conclusion?
    private(set) var isActive = false
    private(set) var startPlayed = false
    private(set) var foregroundActive = true
    private var lastToolDate: Date?
    private var suppressesFeedbackUntilReset = false

    mutating func setForegroundActive(_ active: Bool) -> Effect? {
        foregroundActive = active
        guard active else {
            pendingConclusion = nil
            isActive = false
            startPlayed = false
            lastToolDate = nil
            suppressesFeedbackUntilReset = true
            return .cancelPattern
        }
        return nil
    }

    mutating func registerActivity(playsStart: Bool) -> [Effect] {
        guard foregroundActive, !suppressesFeedbackUntilReset else { return [] }
        pendingConclusion = nil
        isActive = true
        guard playsStart, !startPlayed else { return [] }
        startPlayed = true
        return [.responseStarted]
    }

    mutating func registerTool(at date: Date) -> [Effect] {
        var effects = registerActivity(playsStart: false)
        guard foregroundActive,
              lastToolDate.map({ date.timeIntervalSince($0) >= 0.25 }) ?? true else {
            return effects
        }
        lastToolDate = date
        effects.append(.toolStarted)
        return effects
    }

    mutating func scheduleConclusion(sessionID: String?) -> Conclusion? {
        guard isActive else { return nil }
        let conclusion = Conclusion(token: UUID(), sessionID: sessionID)
        pendingConclusion = conclusion
        return conclusion
    }

    mutating func finishConclusion(_ conclusion: Conclusion) -> Effect? {
        guard pendingConclusion == conclusion else { return nil }
        pendingConclusion = nil
        isActive = false
        startPlayed = false
        lastToolDate = nil
        return foregroundActive ? .responseConcluded : nil
    }

    mutating func fail() -> [Effect] {
        let shouldNotify = isActive && foregroundActive
        var effects = reset()
        if shouldNotify { effects.append(.error) }
        return effects
    }

    mutating func reset() -> [Effect] {
        pendingConclusion = nil
        isActive = false
        startPlayed = false
        lastToolDate = nil
        suppressesFeedbackUntilReset = false
        return [.cancelPattern]
    }

    mutating func invalidateConclusion() {
        pendingConclusion = nil
    }
}

enum ResponseHapticPolicy {
    enum Signal: Equatable {
        case activity(playsStart: Bool)
        case tool
        case failure
        case reset
    }

    static func signal(for event: StreamEvent) -> Signal? {
        switch event {
        case .messageStart, .reasoningDelta, .clarify, .approval:
            return .activity(playsStart: false)
        case .messageDelta:
            return .activity(playsStart: true)
        case .toolStart(_, let name, _):
            return name.lowercased() == "clarify" ? nil : .tool
        case .delegateAgent(_, let activity):
            return activity.stream.contains { $0.kind == .tool } ? .tool : nil
        case .messageError:
            return .failure
        case .messageInterrupted:
            return .reset
        default:
            return nil
        }
    }

    static func shouldScheduleIdleConclusion(
        isBusy: Bool,
        hasPendingConclusion: Bool,
        awaitsUserInput: Bool
    ) -> Bool {
        !isBusy && !hasPendingConclusion && !awaitsUserInput
    }
}

@MainActor
enum Haptics {
    enum Event: Equatable {
        case soft
        case light
        case medium
        case rigid
        case success
        case error
        case warning
        case selection
        case toolStarted
        case responseStarted
        case responseConcluded
    }

#if DEBUG
    static var testEmissionHandler: ((Event) -> Void)?
    static var testSuppressesHardware = false
#endif

    static let preferenceKey = "conduit.haptics"


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


    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: preferenceKey)
            if !newValue {
                cancelLifecyclePattern()
            }
        }
    }

    static func soft() {
        guard emit(.soft) else { return }
        softGenerator.impactOccurred()
        softGenerator.prepare()
    }

    static func light() {
        guard emit(.light) else { return }
        lightGenerator.impactOccurred()
        lightGenerator.prepare()
    }

    static func medium() {
        guard emit(.medium) else { return }
        mediumGenerator.impactOccurred()
        mediumGenerator.prepare()
    }

    static func rigid() {
        guard emit(.rigid) else { return }
        rigidGenerator.impactOccurred()
        rigidGenerator.prepare()
    }

    static func success() {
        guard emit(.success) else { return }
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    static func error() {
        guard emit(.error) else { return }
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }

    static func warning() {
        guard emit(.warning) else { return }
        notificationGenerator.notificationOccurred(.warning)
        notificationGenerator.prepare()
    }

    static func selection() {
        guard emit(.selection) else { return }
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func toolStarted() {
        guard Date() >= lifecyclePatternEndsAt, emit(.toolStarted) else { return }
        softGenerator.impactOccurred(intensity: 0.65)
        softGenerator.prepare()
    }

    static func responseStarted() {
        guard emit(.responseStarted) else { return }
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
        guard emit(.responseConcluded) else { return }
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

    private static func emit(_ event: Event) -> Bool {
        guard enabled else { return false }
#if DEBUG
        testEmissionHandler?(event)
        guard !testSuppressesHardware else { return false }
#endif
        return true
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
