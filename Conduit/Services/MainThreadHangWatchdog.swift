import Foundation
import os

/// DEBUG builds only: notices when the main thread stops returning to its
/// run loop for several seconds and writes what the chat viewport recorded
/// just before (ChatViewportTrace) to Documents/hangs and the unified log.
/// It is for the Mac transcript freeze, where SwiftUI's lazy stack loops on
/// the main thread with no app code in the stack, so only the moments before
/// it say what set it off. A Conduit Dev build (scripts/mac-dev-build.sh)
/// runs it.
final class MainThreadHangWatchdog: @unchecked Sendable {
    static let shared = MainThreadHangWatchdog()

    /// How long the main thread can be away before it counts as a hang.
    static let threshold: TimeInterval = 5

    private let lock = NSLock()
    private var lastBeat = Date()
    private var reportedHangStart: Date?
    private var breadcrumbs: [String] = []
    private let breadcrumbLimit = 600
    private var timer: DispatchSourceTimer?
    private let logger = Logger(subsystem: "com.milim.relay", category: "hang")

    /// A copy of each trace line, readable while the main thread is stuck.
    func record(_ line: String) {
        lock.lock()
        breadcrumbs.append(line)
        if breadcrumbs.count > breadcrumbLimit {
            breadcrumbs.removeFirst(breadcrumbs.count - breadcrumbLimit)
        }
        lock.unlock()
    }

    @MainActor
    func start() {
        #if DEBUG
        guard timer == nil else { return }
        let beat = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.beat() }
        RunLoop.main.add(beat, forMode: .common)
        let check = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        check.schedule(deadline: .now() + 1, repeating: 1)
        check.setEventHandler { [weak self] in self?.check() }
        check.resume()
        timer = check
        logger.notice("Hang watchdog running (threshold \(Self.threshold, privacy: .public) s)")
        #endif
    }

    private func beat() {
        lock.lock()
        let hangStart = reportedHangStart
        lastBeat = Date()
        reportedHangStart = nil
        lock.unlock()
        if let hangStart {
            let seconds = Date().timeIntervalSince(hangStart)
            logger.fault("Main thread back after \(seconds, format: .fixed(precision: 1), privacy: .public) s")
            write(name: "recovered", text: String(format: "Main thread back after %.1f s\n", seconds))
        }
    }

    private func check() {
        lock.lock()
        let stalled = Date().timeIntervalSince(lastBeat)
        guard stalled >= Self.threshold, reportedHangStart == nil else {
            lock.unlock()
            return
        }
        reportedHangStart = lastBeat
        let lines = breadcrumbs
        let since = lastBeat
        lock.unlock()

        let header = "Main thread stuck for \(Int(stalled)) s, last back at \(since) (pid \(getpid()))"
        let report = ([header, "", "Last \(lines.count) viewport trace lines, oldest first:"] + lines).joined(separator: "\n")
        logger.fault("\(header, privacy: .public)")
        for line in lines.suffix(80) {
            logger.fault("trace: \(line, privacy: .public)")
        }
        write(name: "hang", text: report + "\n")
    }

    private func write(name: String, text: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent("hangs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? text.write(to: folder.appendingPathComponent("\(stamp)-\(name).txt"), atomically: true, encoding: .utf8)
    }
}
