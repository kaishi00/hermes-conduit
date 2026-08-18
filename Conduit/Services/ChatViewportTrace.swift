import Foundation
import os

/// Ring-buffer recorder for viewport decisions. ChatView logs every event
/// sent to ChatViewportController and every effect executed; the dump is the
/// Phase-0/Phase-8 evidence trail for "never more than one current scroll
/// owner/command generation". Recording exists only in DEBUG builds; the
/// type stays visible in all configurations so call sites compile clean.
@MainActor
final class ChatViewportTrace {
    struct Entry: Equatable {
        let time: CFAbsoluteTime
        let text: String
    }

    static let shared = ChatViewportTrace()

    #if DEBUG
    private(set) var entries: [Entry] = []
    private let limit = 600
    private let logger = Logger(subsystem: "com.milim.relay", category: "viewport")

    func log(_ text: String) {
        entries.append(Entry(time: CFAbsoluteTimeGetCurrent(), text: text))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        logger.debug("\(text, privacy: .public)")
    }

    func dump() -> String {
        entries.map { entry in
            String(format: "%.3f %@", entry.time, entry.text)
        }.joined(separator: "\n")
    }

    func reset() {
        entries.removeAll()
    }
    #else
    func log(_ text: String) {}
    func dump() -> String { "" }
    func reset() {}
    #endif
}
