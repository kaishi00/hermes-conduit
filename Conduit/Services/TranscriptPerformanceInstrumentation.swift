//
//  TranscriptPerformanceInstrumentation.swift
//  Conduit
//
//  Deterministic counters for measuring transcript rendering work.
//  Tests can reset and read counters to assert that expensive work was
//  avoided. `note()` is `@inline(__always)` so the compiler can strip
//  it in release builds when the body is empty.
//

import Foundation

/// Lightweight counters that measure how much work a transcript operation
/// caused, not how long it took. Every counter is a plain integer — no
/// timers, no wall-clock thresholds.
///
/// Usage in tests:
///   TranscriptPerf.reset()
///   /* trigger operation */
///   XCTAssertEqual(TranscriptPerf.settledMarkdownTextBodyEvaluations, 0)
enum TranscriptPerf {
    // MARK: - Event recording

    /// Record a performance event. In release builds the body is empty
    /// and the compiler can inline/remove the call.
    @inline(__always)
    static func note(_ event: Event) {
        #if DEBUG
        switch event {
        case .settledBubbleBody: storage.settledBubbleBody += 1
        case .settledMarkdownBody: storage.settledMarkdownBody += 1
        case .selectableTextViewUpdate: storage.selectableTextViewUpdate += 1
        case .selectableTextViewTextRebuild: storage.selectableTextViewTextRebuild += 1
        case .textKitMeasurement: storage.textKitMeasurement += 1
        case .rowFramePreferenceUpdate: storage.rowFramePreferenceUpdate += 1
        case .layoutMetricsChanged: storage.layoutMetricsChanged += 1
        case .transcriptChanged: storage.transcriptChanged += 1
        }
        #endif
    }

    /// Record a performance event with a short context string. When
    /// CONDUIT_PERF_TRACE=1 is set (CI diagnostics), each settled-body
    /// evaluation logs its context so a polluted measurement window can be
    /// traced to the exact rows involved. DEBUG builds only.
    @inline(__always)
    static func note(_ event: Event, context: String) {
        #if DEBUG
        note(event)
        if event == .settledMarkdownBody,
           ProcessInfo.processInfo.environment["CONDUIT_PERF_TRACE"] == "1" {
            let snippet = context.prefix(48)
            NSLog("CONDUIT_PERF_TRACE settledMarkdownBody: \(snippet)")
        }
        #endif
    }

    enum Event {
        case settledBubbleBody
        case settledMarkdownBody
        case selectableTextViewUpdate
        case selectableTextViewTextRebuild
        case textKitMeasurement
        case rowFramePreferenceUpdate
        case layoutMetricsChanged
        case transcriptChanged
    }

    // MARK: - Counter accessors

    static var settledMessageBubbleBodyEvaluations: Int {
        get { read(\.settledBubbleBody) }
    }

    static var settledMarkdownTextBodyEvaluations: Int {
        get { read(\.settledMarkdownBody) }
    }

    static var selectableTextViewUpdateCalls: Int {
        get { read(\.selectableTextViewUpdate) }
    }

    static var selectableTextViewTextRebuilds: Int {
        get { read(\.selectableTextViewTextRebuild) }
    }

    static var textKitMeasurementCalls: Int {
        get { read(\.textKitMeasurement) }
    }

    static var rowFramePreferenceUpdates: Int {
        get { read(\.rowFramePreferenceUpdate) }
    }

    static var layoutMetricsChangedCalls: Int {
        get { read(\.layoutMetricsChanged) }
    }

    static var transcriptChangedCalls: Int {
        get { read(\.transcriptChanged) }
    }

    /// Number of messages fingerprinted in the last
    /// `ChatMessageScrollTargetCache.update` call.
    static var lastFingerprintedMessageCount: Int {
        get { read(\.lastFingerprintedMessageCount) }
        set { write(\.lastFingerprintedMessageCount, newValue) }
    }

    /// Total bytes hashed in the last fingerprint update.
    static var lastFingerprintedByteCount: Int {
        get { read(\.lastFingerprintedByteCount) }
        set { write(\.lastFingerprintedByteCount, newValue) }
    }

    /// Times `updateStableTopMessage` scanned targets.
    static var stableTopScanTargetCount: Int {
        get { read(\.stableTopScanTargetCount) }
        set { write(\.stableTopScanTargetCount, newValue) }
    }

    // MARK: - Control

    /// Reset all counters to zero.
    static func reset() {
        #if DEBUG
        storage = Storage()
        #endif
    }

    // MARK: - Private storage

    /// The Storage TYPE must exist in every configuration so the
    /// unconditional `read`/`write` helper signatures compile in Release;
    /// only the stored instance is Debug-only. Release instrumentation is
    /// therefore zero-cost: reads return 0 and writes are compiled out.
    private struct Storage {
        var settledBubbleBody = 0
        var settledMarkdownBody = 0
        var selectableTextViewUpdate = 0
        var selectableTextViewTextRebuild = 0
        var textKitMeasurement = 0
        var rowFramePreferenceUpdate = 0
        var layoutMetricsChanged = 0
        var transcriptChanged = 0
        var lastFingerprintedMessageCount = 0
        var lastFingerprintedByteCount = 0
        var stableTopScanTargetCount = 0
    }

    #if DEBUG
    private static var storage = Storage()
    #endif

    private static func read(_ keyPath: KeyPath<Storage, Int>) -> Int {
        #if DEBUG
        return storage[keyPath: keyPath]
        #else
        _ = keyPath
        return 0
        #endif
    }

    private static func write(_ keyPath: WritableKeyPath<Storage, Int>, _ value: Int) {
        #if DEBUG
        storage[keyPath: keyPath] = value
        #else
        _ = keyPath
        _ = value
        #endif
    }
}
