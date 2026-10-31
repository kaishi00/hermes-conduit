//
//  ChatTraceStore.swift
//  Conduit
//
//  Chat traces (#1533): the chat recorder's lines (ChatViewportTrace) saved
//  when a watcher sees what a tester would report, a chat jumping, its
//  layout running nonstop, the main thread stalling or the blank-screen
//  recovery rebuilding the transcript, or when the user sends them from
//  Diagnostics & logs. A trace names counts, sizes, offsets and timings,
//  never message text, titles or file names. The newest stall trace rides
//  with the crash or freeze report Conduit offers once (CrashReportOffer),
//  and Diagnostics & logs sends or shares the rest. They go to the
//  developer's relay (`POST /v1/crash-reports`, kind `chat`, notifier
//  relay/src/crash-reports.mjs, 0.25+).
//

import Foundation
import os

private let chatTraceLog = Logger(subsystem: "com.milim.relay", category: "chat-traces")

/// What saved a trace. The relay takes these names (TRACE_REASONS).
enum ChatTraceReason: String, CaseIterable {
    /// The offset moved more than a screen with no finger, momentum or
    /// command behind it.
    case jump
    /// The main thread didn't come back to its run loop for 2 s.
    case stall
    /// Layout ran more than 30 times a second for 3 s with no row changing.
    case storm
    /// The blank-screen recovery rebuilt the transcript's scroll view.
    case rebuild
    /// The user sent the chat's trace from Diagnostics & logs.
    case manual
}

/// The traces kept on this device, in Application Support/ChatTraces: the
/// five newest, one text file each, named for when it was saved, why, and
/// the build that saved it. Callers keep its file work off the main thread.
struct ChatTraceStore {
    struct Trace: Equatable {
        let fileName: String
        let savedAt: Date
        let reason: ChatTraceReason
        let appVersion: String
        let build: String
    }

    static let maxKept = 5
    /// The relay takes 2,000 lines: a trace's two heading lines and a
    /// stall's closing line leave the ring this many.
    static let maxRingLines = 1_997
    static let exportFileName = "conduit-chat-traces.txt"

    /// Application Support, not backed up: a trace describes this device.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ChatTraces", isDirectory: true)
    }

    var directory: URL = Self.defaultDirectory
    var exportDirectory = FileManager.default.temporaryDirectory

    /// Writes a trace of `lines` and keeps the newest five. Returns its file
    /// name, or nil when there was nothing to save or it couldn't be written.
    @discardableResult
    func save(
        _ reason: ChatTraceReason,
        lines: [String],
        now: Date = Date(),
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
        build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
        os: String = ProcessInfo.processInfo.operatingSystemVersionString,
        device: String = CrashReportUpload.deviceModel
    ) -> String? {
        guard !lines.isEmpty else { return nil }
        let version = Self.namePart(appVersion)
        let buildPart = Self.namePart(build)
        let milliseconds = Int((now.timeIntervalSince1970 * 1000).rounded(.down))
        let name = "\(milliseconds)-\(reason.rawValue)-\(version)-\(buildPart).txt"
        let heading = [
            "Conduit chat trace: \(reason.rawValue), saved \(ISO8601DateFormatter().string(from: now))",
            "Conduit \(appVersion) (\(build)), \(os), \(device)",
        ].map(ChatViewportTrace.sanitized)
        let text = (heading + lines.suffix(Self.maxRingLines)).joined(separator: "\n") + "\n"
        do {
            try prepareDirectory()
            try Data(text.utf8).write(
                to: directory.appendingPathComponent(name),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            chatTraceLog.error("Couldn't save a chat trace: \(MetricKitReportStore.logged(error), privacy: .public)")
            return nil
        }
        for trace in traces().dropFirst(Self.maxKept) {
            remove(trace.fileName)
        }
        chatTraceLog.notice("Saved a chat trace (\(reason.rawValue, privacy: .public))")
        return name
    }

    /// The saved traces, newest first.
    func traces() -> [Trace] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap(Self.trace(named:)).sorted { ($0.savedAt, $0.fileName) > ($1.savedAt, $1.fileName) }
    }

    /// A trace's lines, its heading included.
    func lines(of trace: Trace) -> [String]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(trace.fileName)) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return lines.isEmpty ? nil : lines
    }

    /// Adds a line at the end: how a stall ended, once it did.
    func append(_ line: String, to fileName: String) {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return }
        let text = String(decoding: data, as: UTF8.self) + ChatViewportTrace.sanitized(line) + "\n"
        try? Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove(_ fileName: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    /// The newest stall trace saved within a MetricKit diagnostic's span:
    /// what the chat did before the freeze that diagnostic reports.
    func stall(between begin: Date, and end: Date) -> Trace? {
        traces().first { $0.reason == .stall && $0.savedAt >= begin && $0.savedAt <= end }
    }

    /// What the recorder holds now (not saved), then every saved trace,
    /// newest first, in one text file to share. Nil when there's neither.
    func writeExport(current: [String]) -> URL? {
        let saved = traces().compactMap { lines(of: $0) }
        let url = exportDirectory.appendingPathComponent(Self.exportFileName)
        var sections = saved.map { $0.joined(separator: "\n") }
        if !current.isEmpty {
            sections.insert((["Conduit chat trace: now, not saved"] + current).joined(separator: "\n"), at: 0)
        }
        guard !sections.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            try Data((sections.joined(separator: "\n\n") + "\n").utf8).write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return url
        } catch {
            chatTraceLog.error("Couldn't write the chat traces file: \(MetricKitReportStore.logged(error), privacy: .public)")
            return nil
        }
    }

    /// "1793404144357-jump-2.2.1-245.txt".
    static func trace(named name: String) -> Trace? {
        guard name.hasSuffix(".txt") else { return nil }
        let parts = name.dropLast(4).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let milliseconds = Double(parts[0]),
              let reason = ChatTraceReason(rawValue: String(parts[1])) else { return nil }
        return Trace(
            fileName: name,
            savedAt: Date(timeIntervalSince1970: milliseconds / 1000),
            reason: reason,
            appVersion: String(parts[2]),
            build: String(parts[3])
        )
    }

    /// A version or build as a file name keeps it: letters, digits and dots.
    private static func namePart(_ text: String) -> String {
        let kept = String(text.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == ".") }.map(Character.init))
        return kept.isEmpty ? "unknown" : String(kept.prefix(32))
    }

    /// Protected until first unlock and left out of backups.
    private func prepareDirectory() throws {
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        }
    }
}

/// A trace's part of a post to the relay.
enum ChatTraceUpload {
    static func object(_ trace: ChatTraceStore.Trace, lines: [String]) -> [String: Any] {
        ["reason": trace.reason.rawValue, "lines": Array(lines.prefix(maxLines))]
    }

    /// The relay's MAX_TRACE_LINES.
    static let maxLines = 2_000

    enum Result: Equatable {
        case sent
        /// The recorder holds nothing and nothing is saved.
        case nothing
        /// The relay takes no reports (404).
        case unsupported
        case failed
    }

    /// Diagnostics & logs' Send: saves what the recorder holds now, then
    /// posts it and every trace saved before, newest first. Each one the
    /// relay takes leaves the device; one it refuses stays for Try again.
    static func sendAll(
        store: ChatTraceStore = ChatTraceStore(),
        relayURL: URL = PushNotificationService.upstreamRelayURL,
        session: URLSession = .shared
    ) async -> Result {
        let current = ChatViewportTrace.shared.lines(last: ChatTraceStore.maxRingLines)
        let traces = await Task.detached(priority: .utility) { () -> [(ChatTraceStore.Trace, [String])] in
            // Read before saving: the save keeps five, and the oldest of
            // those still goes.
            let saved = store.traces().compactMap { trace in store.lines(of: trace).map { (trace, $0) } }
            guard let name = store.save(.manual, lines: current),
                  let trace = ChatTraceStore.trace(named: name),
                  let lines = store.lines(of: trace) else { return saved }
            return [(trace, lines)] + saved
        }.value
        guard !traces.isEmpty else { return .nothing }
        for (trace, lines) in traces {
            let response = await CrashReportUpload.post(CrashReportUpload.body(chatTrace: trace, lines: lines), to: relayURL, session: session)
            switch response.status {
            case 200..<300:
                await Task.detached(priority: .utility) { store.remove(trace.fileName) }.value
            case 404:
                return .unsupported
            default:
                // Before relay 0.25 a chat trace is refused (400): kept for
                // Try again once it's deployed.
                return .failed
            }
        }
        return .sent
    }
}
