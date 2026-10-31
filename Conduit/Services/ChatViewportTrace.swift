import Foundation
import os

/// The chat transcript's recorder, in every build (#1533): the last 2,000
/// things the transcript did. ChatView logs the commands it sends to
/// ChatScrollEngine (ChatViewportWatch.command), the engine logs each offset
/// it writes with the rule that asked, its mode changes and what SwiftUI
/// reported, and the scroll view logs its size and inset changes. A line
/// names counts, sizes, offsets and timings, never message text, titles or
/// file names. The watchers (ChatViewportWatch, MainThreadHangWatchdog) save
/// the ring as a trace (ChatTraceStore) when the chat jumps, its layout runs
/// nonstop or the main thread stalls. Debug builds also stream each line to
/// the console (category viewport).
///
/// Lines come from the main thread; a stall's watchdog reads them from its
/// own queue while the main thread is stuck, so the ring holds a lock.
final class ChatViewportTrace: @unchecked Sendable {
    struct Entry: Equatable {
        let time: CFAbsoluteTime
        let text: String
    }

    static let shared = ChatViewportTrace()

    /// About 200 KB of lines.
    static let limit = 2_000
    /// The relay's longest line (notifier relay/src/crash-reports.mjs).
    static let maxLineLength = 160

    private let lock = NSLock()
    private var ring: [Entry] = []
    /// Where the next line goes once the ring is full: its oldest.
    private var oldest = 0
    #if DEBUG
    private let logger = Logger(subsystem: "com.milim.relay", category: "viewport")
    #endif

    func log(_ message: @autoclosure () -> String) {
        let text = String(message().prefix(Self.maxLineLength))
        let entry = Entry(time: CFAbsoluteTimeGetCurrent(), text: text)
        lock.lock()
        if ring.count < Self.limit {
            ring.append(entry)
        } else {
            ring[oldest] = entry
            oldest = (oldest + 1) % Self.limit
        }
        lock.unlock()
        #if DEBUG
        logger.debug("\(text, privacy: .public)")
        #endif
    }

    /// Oldest first.
    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ring[oldest...]) + Array(ring[..<oldest])
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ring.isEmpty
    }

    /// The newest `count` lines, oldest first, as a trace writes them.
    func lines(last count: Int = limit) -> [String] {
        entries.suffix(count).map(Self.line)
    }

    /// The time, then the line, in only the characters the relay takes.
    static func line(_ entry: Entry) -> String {
        sanitized(String(format: "%.3f ", entry.time) + entry.text)
    }

    /// The relay's trace characters: letters, digits, spaces and
    /// ()._,:;+=<>/#%[]-. Anything else becomes "_", and a line keeps its
    /// first 160.
    static func sanitized(_ text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(text.utf8.count, maxLineLength))
        for scalar in text.unicodeScalars {
            guard bytes.count < maxLineLength else { break }
            if scalar.isASCII, traceCharacters.contains(UInt8(scalar.value)) {
                bytes.append(UInt8(scalar.value))
            } else {
                bytes.append(UInt8(ascii: "_"))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static let traceCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ()._,:;+=<>/#%[]-".utf8
    )

    func dump() -> String {
        lines().joined(separator: "\n")
    }

    func reset() {
        lock.lock()
        ring.removeAll()
        oldest = 0
        lock.unlock()
    }
}
