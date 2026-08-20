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
//  Once the accumulated text crosses the large-document threshold, the
//  component switches to a bounded mode: everything behind the live tail is
//  promoted into immutable chunks (rendered once through the ordinary
//  cached path) and only the tail — a window of a few KB — keeps
//  re-rendering per tick. Without this, a 1 MB stream re-parses and
//  re-lays-out the whole document at 30 fps (measured 0.8–3.3 s per frame).
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

    // MARK: Small-stream state (existing behavior)

    @State private var targetCharacters: [Character] = []
    @State private var visibleCharacters: [Character] = []
    @State private var revealDates: [Date] = []
    @State private var isAnimating = false

    // MARK: Large-stream state
    //
    // Bookkeeping is scalar-first (character/byte counts updated by O(delta)
    // arithmetic) so a tick never walks the accumulated megabytes; index
    // math happens only at promotion boundaries, which are rare.

    /// True once the accumulated text has crossed the large-document
    /// threshold; the component never switches back mid-stream (a message
    /// only grows while streaming).
    @State private var isLargeStream = false
    /// The accumulated target text (append-only while the stream grows).
    @State private var largeAccumulated = ""
    /// Character count of `largeAccumulated`, tracked incrementally.
    @State private var largeAccumulatedChars = 0
    /// Index into `largeAccumulated` up to which characters are revealed.
    @State private var largeRevealedEnd: String.Index?
    /// Character count of the revealed prefix, tracked incrementally.
    @State private var largeRevealedChars = 0
    /// UTF-8 offset of the revealed prefix, tracked incrementally.
    @State private var largeRevealedBytes = 0
    /// UTF-8 offset of the prefix already promoted into stable chunks.
    @State private var largePromotedBytes = 0
    /// Source slices of promoted chunks; each renders once through the
    /// ordinary (cached) MarkdownText path and never re-parses.
    @State private var largeStableChunks: [String] = []
    /// Incremental safe-boundary scanner over `largeAccumulated`.
    @State private var largeScanner = MarkdownStableBoundaryScanner()

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    private let fadeDuration = 0.18

    /// Tail window: the live region kept out of the stable chunks so it can
    /// keep re-parsing per tick. Same order as the chunk target, so a tick's
    /// whole-document work stays bounded by ~2 chunks.
    private static let largeTailWindowBytes = MarkdownLargeDocumentPolicy.chunkTargetBytes

    var body: some View {
        if isLargeStream {
            largeBody
                .onAppear { updateTarget(text) }
                .onChange(of: text) { _, newText in updateTarget(newText) }
                .onReceive(timer) { date in largeReveal(at: date) }
        } else {
            smallBody
        }
    }

    // MARK: Small stream

    private var smallBody: some View {
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
        if isLargeStream {
            updateLargeTarget(newText)
            return
        }

        // Cross into large mode instead of growing the per-character
        // machinery past the threshold: seed the large state with everything
        // accumulated so far (revealed wholesale — the animation that
        // matters is the tail that keeps streaming).
        if MarkdownLargeDocumentPolicy.isLargeDocument(newText) {
            enterLargeMode(with: newText)
            return
        }

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

    // MARK: Large stream

    private var largeBody: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: reduceMotion || !isAnimating
            )
        ) { timeline in
            VStack(alignment: .leading, spacing: 10) {
                // Chunks and the tail parse in isolation, so reference
                // definitions elsewhere in the stream do not resolve while
                // streaming — they render literally until the message
                // settles, at which point the settled view parses the whole
                // message and resolves them message-wide.
                ForEach(Array(largeStableChunks.enumerated()), id: \.offset) { _, chunk in
                    MarkdownText(
                        source: chunk,
                        gatewayMediaDataURL: gatewayMediaDataURL,
                        isStreaming: false
                    )
                }
                MarkdownText(
                    source: largeTailSource,
                    gatewayMediaDataURL: gatewayMediaDataURL,
                    newestCharacterOpacities: characterOpacities(at: timeline.date),
                    isStreaming: true
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion {
                revealAllLargeImmediately()
            }
        }
    }

    /// The not-yet-promoted remainder of the revealed prefix — the only part
    /// that re-renders per tick.
    private var largeTailSource: String {
        guard let revealedEnd = largeRevealedEnd else { return "" }
        return String(largeAccumulated[revealedEnd...])
    }

    /// (Re)seeds large mode from `fullText`. Used on first crossing and on a
    /// non-append target (branch swap / regeneration), which resets
    /// everything — matching the small-mode reset semantics.
    private func enterLargeMode(with fullText: String) {
        largeAccumulated = fullText
        largeAccumulatedChars = fullText.count
        largeRevealedEnd = fullText.endIndex
        largeRevealedChars = fullText.count
        largeRevealedBytes = fullText.utf8.count
        largePromotedBytes = 0
        largeStableChunks = []
        largeScanner = MarkdownStableBoundaryScanner()
        // The scanner needs the full history to know fence state from any
        // later promotion point onward.
        _ = largeScanner.append(fullText)
        isLargeStream = true
        targetCharacters = []
        visibleCharacters = []
        revealDates = []

        if reduceMotion {
            revealAllLargeImmediately()
        } else {
            promoteLargeChunks()
        }
    }

    private func updateLargeTarget(_ newText: String) {
        // A lazily-recreated view (scrolling far away and back) reseeds; a
        // non-append target resets.
        guard largeRevealedEnd != nil, newText.hasPrefix(largeAccumulated) else {
            enterLargeMode(with: newText)
            return
        }

        let delta = String(newText.dropFirst(largeAccumulatedChars))
        guard !delta.isEmpty else { return }
        largeAccumulated = newText
        largeAccumulatedChars += delta.count
        // String.Index is only valid for the instance it was created from;
        // re-derive the reveal cursor in the replaced string from its
        // tracked UTF-8 offset (whole-character aligned by construction).
        let utf8 = largeAccumulated.utf8
        if largeRevealedBytes <= utf8.count,
           let offsetIndex = utf8.index(utf8.startIndex, offsetBy: largeRevealedBytes, limitedBy: utf8.endIndex),
           let revealed = String.Index(offsetIndex, within: largeAccumulated) {
            largeRevealedEnd = revealed
        }
        _ = largeScanner.append(delta)

        if reduceMotion {
            // Everything already arrived is shown instantly; per-tick reveal
            // is disabled under reduce motion.
            largeRevealedEnd = newText.endIndex
            largeRevealedChars = largeAccumulatedChars
            largeRevealedBytes = newText.utf8.count
            revealAllLargeImmediately()
        }
    }

    private func largeReveal(at date: Date) {
        guard !reduceMotion else { return }

        revealDates.removeAll {
            date.timeIntervalSince($0) >= fadeDuration
        }

        guard var revealedEnd = largeRevealedEnd else { return }
        let remaining = largeAccumulatedChars - largeRevealedChars
        if remaining <= 0 {
            let shouldAnimate = !revealDates.isEmpty
            if isAnimating != shouldAnimate { isAnimating = shouldAnimate }
            if !active {
                // The stream is finished and fully revealed: drain the
                // scanner's trailing partial line so a document ending in a
                // closing fence (without a final newline) still promotes at
                // real boundaries instead of hard-cutting inside the block.
                largeScanner.finish()
            }
            promoteLargeChunks()
            return
        }

        let batchSize = revealBatchSize(for: remaining)
        let revealCount = min(batchSize, remaining)
        let baseDate = max(date, revealDates.last ?? date)
        let stagger = min(0.012, 0.028 / Double(revealCount))

        // Walk only the batch: O(revealCount) per tick regardless of how
        // large the accumulated document has become.
        for offset in 0..<revealCount {
            let current = revealedEnd
            revealedEnd = largeAccumulated.index(after: revealedEnd)
            largeRevealedBytes += String(largeAccumulated[current]).utf8.count
            revealDates.append(baseDate.addingTimeInterval(Double(offset) * stagger))
        }
        largeRevealedEnd = revealedEnd
        largeRevealedChars += revealCount
        isAnimating = true
        promoteLargeChunks()
    }

    /// Promotes revealed-but-stable content into immutable chunks whenever
    /// more than the tail window of it has accumulated. Boundary selection
    /// (safe scanner boundary, with hard-cut fallback for unbroken blocks)
    /// lives in the pure, unit-tested `LargeStreamPromotion`.
    private func promoteLargeChunks() {
        while let next = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: largePromotedBytes,
            revealedBytes: largeRevealedBytes,
            tailWindowBytes: Self.largeTailWindowBytes,
            lastSafeBoundary: largeScanner.lastSafeBoundary
        ) {
            // Index conversion is linear in the accumulated string, but
            // promotions happen only every few KB of growth, so this stays
            // amortized O(delta).
            let utf8 = largeAccumulated.utf8
            guard
                let startUTF8 = utf8.index(utf8.startIndex, offsetBy: largePromotedBytes, limitedBy: utf8.endIndex),
                let endUTF8 = utf8.index(utf8.startIndex, offsetBy: next, limitedBy: utf8.endIndex),
                let start = String.Index(startUTF8, within: largeAccumulated),
                let end = String.Index(endUTF8, within: largeAccumulated),
                start < end
            else { return }

            largeStableChunks.append(String(largeAccumulated[start..<end]))
            largePromotedBytes = next
        }
    }

    private func revealAllLargeImmediately() {
        largeRevealedChars = largeAccumulatedChars
        largeRevealedBytes = largeAccumulated.utf8.count
        largeRevealedEnd = largeAccumulated.endIndex
        revealDates = []
        isAnimating = false
        promoteLargeChunks()
    }
}
