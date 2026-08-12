//
//  StreamingText.swift
//  Conduit
//
//  Character-paced streaming text reveal.
//
//  Tokens arrive in unpredictable bursts from the WebSocket. This component
//  decouples visual reveal from data arrival. Characters are admitted at a
//  steady, adaptive pace and retain individual reveal timestamps, allowing
//  the Markdown renderer to fade the newest glyphs independently.
//

import SwiftUI

struct StreamingText: View {
    /// The full text accumulated so far from stream deltas.
    let text: String
    /// Whether streaming is still active. A completed stream uses the fastest
    /// reveal batch while its final projection drains.
    let active: Bool
    var gatewayMediaDataURL: ((String) async -> String?)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targetCharacters: [Character] = []
    @State private var visibleCharacters: [Character] = []
    @State private var revealDates: [Date] = []
    @State private var isAnimating = false

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    private let fadeDuration = 0.18

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: reduceMotion || !isAnimating
            )
        ) { timeline in
            MarkdownText(
                source: String(visibleCharacters),
                gatewayMediaDataURL: gatewayMediaDataURL,
                newestCharacterOpacities: characterOpacities(at: timeline.date),
                isStreaming: true
            )
        }
        .onAppear {
            updateTarget(text)
        }
        .onChange(of: text) { _, newText in
            updateTarget(newText)
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion {
                visibleCharacters = targetCharacters
                revealDates = []
                isAnimating = false
            } else {
                updateTarget(text)
            }
        }
        .onReceive(timer) { date in
            revealCharacters(at: date)
        }
    }

    private func updateTarget(_ newText: String) {
        let newTarget = Array(newText)
        if newTarget.count < visibleCharacters.count ||
            !newTarget.starts(with: visibleCharacters) {
            visibleCharacters = []
            revealDates = []
        }
        targetCharacters = newTarget

        if reduceMotion {
            visibleCharacters = newTarget
            revealDates = []
            isAnimating = false
        } else if visibleCharacters.count < targetCharacters.count {
            isAnimating = true
        }
    }

    private func revealCharacters(at date: Date) {
        guard !reduceMotion else { return }

        revealDates.removeAll {
            date.timeIntervalSince($0) >= fadeDuration
        }
        let remaining = targetCharacters.count - visibleCharacters.count
        guard remaining > 0 else {
            let shouldAnimate = !revealDates.isEmpty
            if isAnimating != shouldAnimate {
                isAnimating = shouldAnimate
            }
            return
        }

        let batchSize = revealBatchSize(for: remaining)
        let revealCount = min(batchSize, remaining)
        let firstIndex = visibleCharacters.count
        let baseDate = max(date, revealDates.last ?? date)
        let stagger = min(0.012, 0.028 / Double(revealCount))

        for offset in 0..<revealCount {
            visibleCharacters.append(targetCharacters[firstIndex + offset])
            revealDates.append(baseDate.addingTimeInterval(Double(offset) * stagger))
        }
        isAnimating = true
    }

    private func revealBatchSize(for remaining: Int) -> Int {
        if !active { return min(remaining, 18) }
        switch remaining {
        case 481...: return 18
        case 241...480: return 12
        case 121...240: return 8
        case 61...120: return 5
        case 21...60: return 3
        default: return 2
        }
    }

    private func characterOpacities(at date: Date) -> [Double] {
        guard !reduceMotion,
              let firstFadingIndex = revealDates.firstIndex(where: {
                  date.timeIntervalSince($0) < fadeDuration
              }) else { return [] }

        return revealDates[firstFadingIndex...].map { revealDate in
            let progress = date.timeIntervalSince(revealDate) / fadeDuration
            return min(max(progress, 0.04), 1)
        }
    }
}
