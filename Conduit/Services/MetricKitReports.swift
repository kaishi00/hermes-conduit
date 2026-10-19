//
//  MetricKitReports.swift
//  Conduit
//
//  The daily reports iOS writes about Conduit through MetricKit: CPU time,
//  time in the foreground and background, network bytes, disk writes and
//  hangs (MXMetricPayload), plus hang, crash, CPU and disk-write exception
//  diagnostics, and slow-launch diagnostics (MXDiagnosticPayload). Kept on
//  this device as the payloads' own JSON, newest few weeks only, so a
//  battery or data question about a real day of use can be answered with
//  numbers. Settings > Gateway > Diagnostics & logs shares them as one
//  file; nothing is uploaded.
//
//  The summary is a diagnostic log, English only like the connection
//  timeline next to it. watchOS has no MetricKit, so this is iPhone and iPad
//  only.
//

import CryptoKit
import Foundation
import MetricKit
import os

/// A store that stops writing would otherwise look just like a device with
/// no reports yet.
private let metricKitLog = Logger(subsystem: "com.milim.relay", category: "metrickit")

enum MetricKitReportKind: String, CaseIterable {
    /// A day of usage numbers.
    case metrics
    /// Hangs, crashes and resource exceptions.
    case diagnostics
}

/// The stored payloads: one JSON file each, named by kind, time range and
/// content, in a folder of their own. Not thread-safe; `MetricKitReports`
/// calls it from one serial queue.
struct MetricKitReportStore {
    struct Entry: Equatable {
        let url: URL
        let kind: MetricKitReportKind
        let begin: Date
        let end: Date
        let contentHash: String
    }

    let directory: URL
    /// Where the share file goes: the temporary folder, written when
    /// Diagnostics & logs opens and something changed since, so it is never
    /// a long-lived second copy of the reports.
    var exportDirectory = FileManager.default.temporaryDirectory
    /// About two weeks of days, enough to compare before and after a change.
    var maxMetrics = 14
    var maxDiagnostics = 30
    /// A diagnostic carries call stacks and can be large, so diagnostics are
    /// also held to a byte budget. The newest is always kept.
    var maxDiagnosticBytes = 8_000_000

    static let exportFileName = "conduit-device-reports.json"

    /// Application Support, not backed up: reports describe this device only.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DeviceReports", isDirectory: true)
    }

    var exportURL: URL { exportDirectory.appendingPathComponent(Self.exportFileName) }

    /// Stores one payload's JSON unless it is already here, then prunes.
    /// A day's metrics are the same report whatever their bytes, so they
    /// dedupe by time range alone; two diagnostics can share a range, so
    /// they also compare content. Returns whether anything new is kept: a
    /// payload older than everything kept is pruned straight away.
    @discardableResult
    func save(_ json: Data, kind: MetricKitReportKind, begin: Date, end: Date) -> Bool {
        guard let normalized = Self.normalized(json) else {
            metricKitLog.error("A \(kind.rawValue, privacy: .public) report wasn't a JSON object; not kept")
            return false
        }
        let hash = Self.hash(normalized)
        let beginSeconds = Int(begin.timeIntervalSince1970.rounded(.down))
        let endSeconds = Int(end.timeIntervalSince1970.rounded(.down))
        let duplicate = entries(kind).contains { entry in
            Int(entry.begin.timeIntervalSince1970) == beginSeconds
                && Int(entry.end.timeIntervalSince1970) == endSeconds
                && (kind == .metrics || entry.contentHash == hash)
        }
        guard !duplicate else { return false }
        let url = directory.appendingPathComponent("\(kind.rawValue)-\(beginSeconds)-\(endSeconds)-\(hash).json")
        do {
            try prepareDirectory()
            try normalized.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            metricKitLog.error("Couldn't keep a \(kind.rawValue, privacy: .public) report: \(Self.logged(error), privacy: .public)")
            return false
        }
        prune()
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// One kind's payloads, oldest first.
    func entries(_ kind: MetricKitReportKind) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { Self.entry(for: $0) }
            .filter { $0.kind == kind }
            .sorted { ($0.end, $0.begin, $0.url.lastPathComponent) < ($1.end, $1.begin, $1.url.lastPathComponent) }
    }

    /// Keeps the newest of each kind within its caps.
    func prune() {
        let metrics = entries(.metrics)
        for entry in metrics.dropLast(maxMetrics) {
            try? FileManager.default.removeItem(at: entry.url)
        }
        var bytes = 0
        var kept = 0
        for entry in entries(.diagnostics).reversed() {
            let size = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if kept > 0 && (kept >= maxDiagnostics || bytes + size > maxDiagnosticBytes) {
                try? FileManager.default.removeItem(at: entry.url)
            } else {
                kept += 1
                bytes += size
            }
        }
    }

    func summary(timeZone: TimeZone = .current) -> MetricKitReportSummary {
        let metrics = entries(.metrics)
        let latest = metrics.last.flatMap { entry in
            (try? Data(contentsOf: entry.url)).flatMap { MetricKitDayMetrics(payloadJSON: $0) }
        }
        var counts = MetricKitDiagnosticCounts()
        for entry in entries(.diagnostics) {
            if let data = try? Data(contentsOf: entry.url) {
                counts.add(MetricKitDiagnosticCounts(payloadJSON: data))
            }
        }
        return MetricKitReportSummary(
            days: metrics.count,
            latestDay: metrics.last?.begin,
            latest: latest,
            diagnostics: counts,
            timeZone: timeZone
        )
    }

    /// Writes every stored payload into one JSON file to share, or removes
    /// the file when nothing is stored. Returns the file when there is one.
    @discardableResult
    func writeExport(now: Date = Date(), appVersion: String = MetricKitReportStore.appVersion, timeZone: TimeZone = .current) -> URL? {
        let metrics = entries(.metrics)
        let diagnostics = entries(.diagnostics)
        guard !metrics.isEmpty || !diagnostics.isEmpty else {
            try? FileManager.default.removeItem(at: exportURL)
            return nil
        }
        func payloads(_ entries: [Entry]) -> [Any] {
            entries.compactMap { entry in
                (try? Data(contentsOf: entry.url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            }
        }
        let document: [String: Any] = [
            "about": "MetricKit reports iOS delivered to Conduit on this device: daily usage numbers, and crash, hang, launch and resource diagnostics with their call stacks and exception messages. Nothing was uploaded.",
            "generated": ISO8601DateFormatter().string(from: now),
            "appVersion": appVersion,
            "summary": summary(timeZone: timeZone).text,
            "metricPayloads": payloads(metrics),
            "diagnosticPayloads": payloads(diagnostics),
        ]
        do {
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            // Not pretty-printed: deep call-stack trees would grow several times.
            let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            try data.write(to: exportURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return exportURL
        } catch {
            metricKitLog.error("Couldn't write the device reports file: \(Self.logged(error), privacy: .public)")
            return nil
        }
    }

    /// An error's domain and code only: a file error's text names the
    /// app's container and the report files.
    static func logged(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Creates the folder when it's missing, and on every write makes sure
    /// it is protected until first unlock and left out of backups (a restore
    /// or an older build may have left it otherwise). A folder that can't be
    /// kept out of backups takes no report: diagnostics carry call stacks.
    private func prepareDirectory() throws {
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.setAttributes(protection, ofItemAtPath: directory.path)
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        }
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    /// Sorted keys, so the same payload hashes the same however it arrived.
    private static func normalized(_ json: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: json), object is [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func entry(for url: URL) -> Entry? {
        guard url.pathExtension == "json" else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count == 4,
              let kind = MetricKitReportKind(rawValue: String(parts[0])),
              let begin = TimeInterval(parts[1]),
              let end = TimeInterval(parts[2]) else { return nil }
        return Entry(
            url: url,
            kind: kind,
            begin: Date(timeIntervalSince1970: begin),
            end: Date(timeIntervalSince1970: end),
            contentHash: String(parts[3])
        )
    }
}

/// A few headline numbers from one MXMetricPayload's JSON. MetricKit writes
/// measurements as strings with units ("100 sec", "80000 kB"); a metric
/// iOS left out stays nil.
struct MetricKitDayMetrics: Equatable {
    var cpuSeconds: Double?
    var foregroundSeconds: Double?
    var backgroundSeconds: Double?
    var cellularDownloadBytes: Double?
    var cellularUploadBytes: Double?
    var wifiDownloadBytes: Double?
    var wifiUploadBytes: Double?
    var diskWriteBytes: Double?
    /// Hangs in the day's hang-time histogram.
    var hangs: Int? = nil

    init(cpuSeconds: Double? = nil, foregroundSeconds: Double? = nil, backgroundSeconds: Double? = nil,
         cellularDownloadBytes: Double? = nil, cellularUploadBytes: Double? = nil,
         wifiDownloadBytes: Double? = nil, wifiUploadBytes: Double? = nil,
         diskWriteBytes: Double? = nil, hangs: Int? = nil) {
        self.cpuSeconds = cpuSeconds
        self.foregroundSeconds = foregroundSeconds
        self.backgroundSeconds = backgroundSeconds
        self.cellularDownloadBytes = cellularDownloadBytes
        self.cellularUploadBytes = cellularUploadBytes
        self.wifiDownloadBytes = wifiDownloadBytes
        self.wifiUploadBytes = wifiUploadBytes
        self.diskWriteBytes = diskWriteBytes
        self.hangs = hangs
    }

    init?(payloadJSON: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: payloadJSON)) as? [String: Any] else { return nil }
        let cpu = root["cpuMetrics"] as? [String: Any]
        let time = root["applicationTimeMetrics"] as? [String: Any]
        let network = root["networkTransferMetrics"] as? [String: Any]
        let disk = root["diskIOMetrics"] as? [String: Any]
        let responsiveness = root["applicationResponsivenessMetrics"] as? [String: Any]
        cpuSeconds = Self.seconds(cpu?["cumulativeCPUTime"])
        foregroundSeconds = Self.seconds(time?["cumulativeForegroundTime"])
        backgroundSeconds = Self.seconds(time?["cumulativeBackgroundTime"])
        cellularDownloadBytes = Self.bytes(network?["cumulativeCellularDownload"])
        cellularUploadBytes = Self.bytes(network?["cumulativeCellularUpload"])
        wifiDownloadBytes = Self.bytes(network?["cumulativeWifiDownload"])
        wifiUploadBytes = Self.bytes(network?["cumulativeWifiUpload"])
        diskWriteBytes = Self.bytes(disk?["cumulativeLogicalWrites"])
        // The property is histogrammedApplicationHangTime; MetricKit's JSON
        // has used histogrammedAppHangTime. Its buckets come keyed by index
        // or as an array.
        let histogram = (responsiveness?["histogrammedAppHangTime"] ?? responsiveness?["histogrammedApplicationHangTime"]) as? [String: Any]
        let buckets: [Any]? = (histogram?["histogramValue"] as? [String: Any]).map { Array($0.values) }
            ?? histogram?["histogramValue"] as? [Any]
        if let buckets {
            hangs = buckets.reduce(0) { total, bucket in
                total + (((bucket as? [String: Any])?["bucketCount"] as? NSNumber)?.intValue ?? 0)
            }
        }
    }

    /// "100 sec", "2 min", "1.5 hr", "250 ms" or a bare number of seconds.
    static func seconds(_ value: Any?) -> Double? {
        guard let (number, unit) = measurement(value) else { return nil }
        switch unit {
        case "", "s", "sec", "secs", "second", "seconds": return number
        case "ms", "msec": return number / 1000
        case "µs", "us": return number / 1_000_000
        case "min", "mins", "minute", "minutes": return number * 60
        case "h", "hr", "hrs", "hour", "hours": return number * 3600
        default: return nil
        }
    }

    /// "80000 kB", "12 MB", "512 B" or a bare number of bytes. MetricKit's
    /// units are decimal (UnitInformationStorage), so a kB is 1,000 bytes.
    static func bytes(_ value: Any?) -> Double? {
        guard let (number, unit) = measurement(value) else { return nil }
        switch unit.lowercased() {
        case "", "b", "byte", "bytes": return number
        case "kb": return number * 1_000
        case "mb": return number * 1_000_000
        case "gb": return number * 1_000_000_000
        case "tb": return number * 1_000_000_000_000
        case "kib": return number * 1_024
        case "mib": return number * 1_048_576
        case "gib": return number * 1_073_741_824
        default: return nil
        }
    }

    /// "<number> <unit>": the number must parse whole ("1.2e+07" yes,
    /// "10,5" no), so a locale-formatted value is dropped, not misread.
    private static func measurement(_ value: Any?) -> (Double, String)? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? (double, "") : nil
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(separator: " ", maxSplits: 1)
        guard let number = Double(String(parts[0])), number.isFinite else { return nil }
        let unit = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return (number, unit)
    }
}

/// How many of each diagnostic the stored MXDiagnosticPayloads hold.
struct MetricKitDiagnosticCounts: Equatable {
    var crashes = 0
    var hangs = 0
    var cpuExceptions = 0
    var diskWriteExceptions = 0
    /// Slow launches.
    var launches = 0

    init(crashes: Int = 0, hangs: Int = 0, cpuExceptions: Int = 0, diskWriteExceptions: Int = 0, launches: Int = 0) {
        self.crashes = crashes
        self.hangs = hangs
        self.cpuExceptions = cpuExceptions
        self.diskWriteExceptions = diskWriteExceptions
        self.launches = launches
    }

    init(payloadJSON: Data) {
        let root = (try? JSONSerialization.jsonObject(with: payloadJSON)) as? [String: Any] ?? [:]
        func count(_ key: String) -> Int { (root[key] as? [Any])?.count ?? 0 }
        crashes = count("crashDiagnostics")
        hangs = count("hangDiagnostics")
        cpuExceptions = count("cpuExceptionDiagnostics")
        diskWriteExceptions = count("diskWriteExceptionDiagnostics")
        launches = count("appLaunchDiagnostics")
    }

    var total: Int { crashes + hangs + cpuExceptions + diskWriteExceptions + launches }

    mutating func add(_ other: MetricKitDiagnosticCounts) {
        crashes += other.crashes
        hangs += other.hangs
        cpuExceptions += other.cpuExceptions
        diskWriteExceptions += other.diskWriteExceptions
        launches += other.launches
    }
}

/// What Diagnostics & logs shows above the Share button.
struct MetricKitReportSummary: Equatable {
    var days: Int
    var latestDay: Date?
    var latest: MetricKitDayMetrics?
    var diagnostics: MetricKitDiagnosticCounts
    var timeZone: TimeZone = .current

    var isEmpty: Bool { days == 0 && diagnostics.total == 0 }

    /// English diagnostic text, a line for the latest day and one for the
    /// diagnostics, for example
    /// "Days stored: 3, latest 2026-10-17: CPU 5m12s, fg 1h02m, bg 4m00s, cell 12.3 MB, Wi-Fi 340.0 MB, disk 45.0 MB, hangs 2".
    var text: String {
        var lines: [String] = []
        if days > 0 {
            var head = "Days stored: \(days)"
            if let latestDay {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = timeZone
                formatter.dateFormat = "yyyy-MM-dd"
                head += ", latest \(formatter.string(from: latestDay))"
            }
            var parts: [String] = []
            if let latest {
                if let value = latest.cpuSeconds { parts.append("CPU \(Self.duration(value))") }
                if let value = latest.foregroundSeconds { parts.append("fg \(Self.duration(value))") }
                if let value = latest.backgroundSeconds { parts.append("bg \(Self.duration(value))") }
                if let value = Self.sum(latest.cellularDownloadBytes, latest.cellularUploadBytes) { parts.append("cell \(Self.megabytes(value))") }
                if let value = Self.sum(latest.wifiDownloadBytes, latest.wifiUploadBytes) { parts.append("Wi-Fi \(Self.megabytes(value))") }
                if let value = latest.diskWriteBytes { parts.append("disk \(Self.megabytes(value))") }
                if let value = latest.hangs { parts.append("hangs \(value)") }
            }
            lines.append(parts.isEmpty ? head : head + ": " + parts.joined(separator: ", "))
        }
        if diagnostics.total > 0 {
            lines.append("Diagnostics: crashes \(diagnostics.crashes), hangs \(diagnostics.hangs), CPU exceptions \(diagnostics.cpuExceptions), disk-write exceptions \(diagnostics.diskWriteExceptions), slow launches \(diagnostics.launches)")
        }
        return lines.isEmpty ? "No MetricKit reports yet." : lines.joined(separator: "\n")
    }

    private static func sum(_ a: Double?, _ b: Double?) -> Double? {
        guard a != nil || b != nil else { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    static func duration(_ seconds: Double) -> String {
        // A day holds 86,400 s; anything far past that is a bad value.
        guard seconds.isFinite, seconds >= 0, seconds < 100_000_000 else { return "?" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        if hours > 0 { return String(format: "%dh%02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm%02ds", minutes, secs) }
        return "\(secs)s"
    }

    static func megabytes(_ bytes: Double) -> String {
        guard bytes.isFinite else { return "?" }
        return String(format: "%.1f MB", bytes / 1_000_000)
    }
}

/// The MetricKit subscriber, registered once at launch. Payloads are
/// written on a background queue, and the share file is written when
/// Diagnostics & logs opens. Unchecked Sendable: all its state is read and
/// written on `queue` only.
final class MetricKitReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitReports()

    private let queue = DispatchQueue(label: "com.milim.relay.metrickit", qos: .utility)
    private let store: MetricKitReportStore
    private var started = false

    init(store: MetricKitReportStore = MetricKitReportStore(directory: MetricKitReportStore.defaultDirectory)) {
        self.store = store
    }

    /// Subscribes, and keeps what iOS delivered before the subscriber
    /// existed. Off the main thread; calling it again does nothing.
    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            MXMetricManager.shared.add(self)
            let manager = MXMetricManager.shared
            receive(metrics: manager.pastPayloads, diagnostics: manager.pastDiagnosticPayloads)
        }
    }

    /// What Diagnostics & logs shows: the summary and the share file, or
    /// that the file couldn't be written.
    struct Loaded {
        var summary: MetricKitReportSummary
        var exportURL: URL?
        /// Reports are stored, but the share file couldn't be written.
        var exportFailed: Bool
    }

    /// The stored files and app version the share file was last written
    /// from: opening the page again with nothing new reuses it rather than
    /// serializing every payload again. Only touched on `queue`.
    private var lastExport: (files: [String], appVersion: String, timeZone: String)?

    /// The summary, and a current share file, off the main thread at the
    /// page's priority (someone is waiting on it).
    func load() async -> Loaded {
        await withCheckedContinuation { continuation in
            queue.async(qos: .userInitiated, flags: .enforceQoS) { [self] in
                let summary = store.summary()
                guard !summary.isEmpty else {
                    // Nothing to offer: no share file either.
                    try? FileManager.default.removeItem(at: store.exportURL)
                    lastExport = nil
                    continuation.resume(returning: Loaded(summary: summary, exportURL: nil, exportFailed: false))
                    return
                }
                let files = (MetricKitReportKind.allCases.flatMap { store.entries($0) }).map(\.url.lastPathComponent)
                let version = MetricKitReportStore.appVersion
                let timeZone = TimeZone.current.identifier
                if let lastExport, lastExport.files == files, lastExport.appVersion == version,
                   lastExport.timeZone == timeZone,
                   FileManager.default.fileExists(atPath: store.exportURL.path) {
                    continuation.resume(returning: Loaded(summary: summary, exportURL: store.exportURL, exportFailed: false))
                    return
                }
                let url = store.writeExport(appVersion: version)
                lastExport = url == nil ? nil : (files, version, timeZone)
                continuation.resume(returning: Loaded(summary: summary, exportURL: url, exportFailed: url == nil))
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        queue.async { [self] in receive(metrics: payloads, diagnostics: []) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async { [self] in receive(metrics: [], diagnostics: payloads) }
    }

    private func receive(metrics: [MXMetricPayload], diagnostics: [MXDiagnosticPayload]) {
        for payload in metrics {
            store.save(payload.jsonRepresentation(), kind: .metrics, begin: payload.timeStampBegin, end: payload.timeStampEnd)
        }
        for payload in diagnostics {
            store.save(payload.jsonRepresentation(), kind: .diagnostics, begin: payload.timeStampBegin, end: payload.timeStampEnd)
        }
    }
}
