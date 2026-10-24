//
//  ConnectionFailureTests+MetricKit.swift
//  ConduitTests
//
//  The on-device MetricKit report store shown in Diagnostics & logs: its
//  pruning and dedupe, the summary parser over payload JSON shaped like
//  MetricKit's own, and the shared export file. An extension of an
//  existing diagnostics class, so the CI planner gains no new class.
//

import XCTest
@testable import Conduit

extension ConnectionFailureTests {
    private var metricKitUTC: TimeZone { TimeZone(identifier: "UTC")! }

    /// A fresh temporary folder per test, removed when the test ends.
    private func metricKitDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricKitReports-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A store whose reports and share file both live in temporary folders.
    private func metricKitStore() -> MetricKitReportStore {
        var store = MetricKitReportStore(directory: metricKitDirectory())
        store.exportDirectory = metricKitDirectory()
        return store
    }

    private func metricKitDay(_ index: Int) -> Date {
        // 2026-10-01 00:00:00 UTC plus whole days.
        Date(timeIntervalSince1970: 1_790_812_800 + TimeInterval(index) * 86_400)
    }

    /// A day's MXMetricPayload JSON in MetricKit's format: the SDK's
    /// property names (MXMetricPayload.h and the metric headers) as keys,
    /// measurements as strings with units, hangs as a histogram whose
    /// buckets are keyed by index (or an array when `bucketsAsArray`).
    private func metricKitMetricJSON(cpu: String = "312 sec", foreground: String = "62 min", background: String = "240 sec",
                            cellularDown: String = "12000 kB", cellularUp: String = "300 kB",
                            wifiDown: String = "340 MB", wifiUp: String = "20000 kB",
                            writes: String = "45000 kB", hangBuckets: [Int] = [2, 1],
                            hangKey: String = "histogrammedAppHangTime", bucketsAsArray: Bool = false) -> Data {
        let bucketList: [[String: Any]] = hangBuckets.enumerated().map { index, count in
            ["bucketStart": "\(index * 100) ms", "bucketEnd": "\((index + 1) * 100) ms", "bucketCount": count]
        }
        var bucketMap: [String: Any] = [:]
        for (index, bucket) in bucketList.enumerated() { bucketMap[String(index)] = bucket }
        let buckets: Any = bucketsAsArray ? bucketList : bucketMap
        let object: [String: Any] = [
            "appVersion": "0.1.15",
            "timeStampBegin": "2026-10-17 00:00:00 +0000",
            "timeStampEnd": "2026-10-17 23:59:00 +0000",
            "metaData": ["deviceType": "iPhone17,1", "osVersion": "iPhone OS 27.0", "regionFormat": "US"],
            "cpuMetrics": ["cumulativeCPUTime": cpu, "cumulativeCPUInstructions": "100 kiloinstructions"],
            "applicationTimeMetrics": [
                "cumulativeForegroundTime": foreground,
                "cumulativeBackgroundTime": background,
                "cumulativeBackgroundAudioTime": "30 sec",
                "cumulativeBackgroundLocationTime": "0 sec",
            ],
            "networkTransferMetrics": [
                "cumulativeCellularDownload": cellularDown,
                "cumulativeCellularUpload": cellularUp,
                "cumulativeWifiDownload": wifiDown,
                "cumulativeWifiUpload": wifiUp,
            ],
            "diskIOMetrics": ["cumulativeLogicalWrites": writes],
            "applicationResponsivenessMetrics": [
                hangKey: ["histogramNumBuckets": hangBuckets.count, "histogramValue": buckets],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func metricKitDiagnosticJSON(crashes: Int = 0, hangs: Int = 0, cpu: Int = 0, diskWrites: Int = 0, launches: Int = 0, tag: String = "") -> Data {
        func items(_ count: Int, _ kind: String) -> [[String: Any]] {
            (0..<count).map { _ in ["diagnosticMetaData": ["kind": kind, "tag": tag], "callStackTree": ["callStacks": []]] }
        }
        let object: [String: Any] = [
            "timeStampBegin": "2026-10-17 10:00:00 +0000",
            "timeStampEnd": "2026-10-17 10:00:00 +0000",
            "crashDiagnostics": items(crashes, "crash"),
            "hangDiagnostics": items(hangs, "hang"),
            "cpuExceptionDiagnostics": items(cpu, "cpu"),
            "diskWriteExceptionDiagnostics": items(diskWrites, "disk"),
            "appLaunchDiagnostics": items(launches, "launch"),
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Storing

    func testMetricKitSaveWritesOneFilePerPayload() {
        let store = metricKitStore()
        XCTAssertTrue(store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1)))
        XCTAssertTrue(store.save(metricKitDiagnosticJSON(hangs: 1), kind: .diagnostics, begin: metricKitDay(0), end: metricKitDay(0)))
        XCTAssertEqual(store.entries(.metrics).count, 1)
        XCTAssertEqual(store.entries(.diagnostics).count, 1)
        XCTAssertEqual(store.entries(.metrics).first?.begin, metricKitDay(0))
        XCTAssertEqual(store.entries(.metrics).first?.end, metricKitDay(1))
    }

    func testMetricKitSaveRefusesWhatIsNotAJSONObject() {
        let store = metricKitStore()
        XCTAssertFalse(store.save(Data("not json".utf8), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1)))
        XCTAssertFalse(store.save(Data("[1,2]".utf8), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1)))
        XCTAssertTrue(store.entries(.metrics).isEmpty)
    }

    func testMetricKitEntriesIgnoreForeignFiles() throws {
        let store = metricKitStore()
        store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1))
        try Data("x".utf8).write(to: store.directory.appendingPathComponent("notes.json"))
        try Data("{}".utf8).write(to: store.directory.appendingPathComponent("metrics-1-2.json"))
        XCTAssertEqual(store.entries(.metrics).count, 1)
        XCTAssertTrue(store.entries(.diagnostics).isEmpty)
    }

    // MARK: - Dedupe

    /// pastPayloads at launch can hand back a day the subscriber already
    /// stored, and its JSON keys need not come in the same order.
    func testMetricKitMetricsDedupeByTimeRange() {
        let store = metricKitStore()
        XCTAssertTrue(store.save(metricKitMetricJSON(cpu: "312 sec"), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1)))
        XCTAssertFalse(store.save(metricKitMetricJSON(cpu: "312 sec"), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1)))
        XCTAssertFalse(store.save(metricKitMetricJSON(cpu: "400 sec"), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1)))
        XCTAssertTrue(store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(1), end: metricKitDay(2)))
        XCTAssertEqual(store.entries(.metrics).count, 2)
    }

    func testMetricKitDiagnosticsDedupeByTimeRangeAndContent() {
        let store = metricKitStore()
        XCTAssertTrue(store.save(metricKitDiagnosticJSON(hangs: 1, tag: "a"), kind: .diagnostics, begin: metricKitDay(0), end: metricKitDay(0)))
        XCTAssertFalse(store.save(metricKitDiagnosticJSON(hangs: 1, tag: "a"), kind: .diagnostics, begin: metricKitDay(0), end: metricKitDay(0)))
        // A second diagnostic in the same range is a different report.
        XCTAssertTrue(store.save(metricKitDiagnosticJSON(crashes: 1, tag: "b"), kind: .diagnostics, begin: metricKitDay(0), end: metricKitDay(0)))
        XCTAssertEqual(store.entries(.diagnostics).count, 2)
    }

    // MARK: - Pruning

    func testMetricKitPruneKeepsTheNewestMetricDays() {
        var store = metricKitStore()
        store.maxMetrics = 3
        for index in [4, 0, 2, 1, 3] {
            store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(index), end: metricKitDay(index + 1))
        }
        XCTAssertEqual(store.entries(.metrics).map(\.begin), [metricKitDay(2), metricKitDay(3), metricKitDay(4)])
    }

    func testMetricKitPruneKeepsTheNewestDiagnosticsByCount() {
        var store = metricKitStore()
        store.maxDiagnostics = 2
        for index in 0..<4 {
            store.save(metricKitDiagnosticJSON(hangs: 1), kind: .diagnostics, begin: metricKitDay(index), end: metricKitDay(index))
        }
        XCTAssertEqual(store.entries(.diagnostics).map(\.begin), [metricKitDay(2), metricKitDay(3)])
    }

    /// A past payload older than every kept day is pruned at once, so it
    /// isn't reported as new on every launch.
    func testMetricKitSaveOfAPayloadOlderThanEverythingKeptReportsNothingNew() {
        var store = metricKitStore()
        store.maxMetrics = 2
        store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(5), end: metricKitDay(6))
        store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(6), end: metricKitDay(7))
        XCTAssertFalse(store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(1), end: metricKitDay(2)))
        XCTAssertEqual(store.entries(.metrics).map(\.begin), [metricKitDay(5), metricKitDay(6)])
    }

    func testMetricKitPruneHoldsDiagnosticsToTheByteBudgetButKeepsTheNewest() {
        var store = metricKitStore()
        store.maxDiagnosticBytes = 1
        for index in 0..<3 {
            store.save(metricKitDiagnosticJSON(hangs: 1), kind: .diagnostics, begin: metricKitDay(index), end: metricKitDay(index))
        }
        XCTAssertEqual(store.entries(.diagnostics).map(\.begin), [metricKitDay(2)])
    }

    // MARK: - Summary parser

    func testMetricKitDayMetricsParseMetricKitMeasurementStrings() throws {
        let metrics = try XCTUnwrap(MetricKitDayMetrics(payloadJSON: metricKitMetricJSON()))
        XCTAssertEqual(metrics.cpuSeconds, 312)
        XCTAssertEqual(metrics.foregroundSeconds, 3720)
        XCTAssertEqual(metrics.backgroundSeconds, 240)
        XCTAssertEqual(metrics.cellularDownloadBytes, 12_000_000)
        XCTAssertEqual(metrics.cellularUploadBytes, 300_000)
        XCTAssertEqual(metrics.wifiDownloadBytes, 340_000_000)
        XCTAssertEqual(metrics.wifiUploadBytes, 20_000_000)
        XCTAssertEqual(metrics.diskWriteBytes, 45_000_000)
        XCTAssertEqual(metrics.hangs, 3)
    }

    func testMetricKitDayMetricsLeaveMissingMetricsNil() throws {
        let json = try JSONSerialization.data(withJSONObject: ["cpuMetrics": ["cumulativeCPUTime": "1.5 hr"]])
        let metrics = try XCTUnwrap(MetricKitDayMetrics(payloadJSON: json))
        XCTAssertEqual(metrics.cpuSeconds, 5400)
        XCTAssertNil(metrics.foregroundSeconds)
        XCTAssertNil(metrics.wifiDownloadBytes)
        XCTAssertNil(metrics.hangs)
        XCTAssertNil(MetricKitDayMetrics(payloadJSON: Data("nope".utf8)))
    }

    /// The SDK names the property histogrammedApplicationHangTime while
    /// MetricKit's JSON has used histogrammedAppHangTime; buckets can come
    /// keyed by index or as an array.
    func testMetricKitHangCountAcceptsBothKeysAndBucketShapes() throws {
        for key in ["histogrammedAppHangTime", "histogrammedApplicationHangTime"] {
            for asArray in [false, true] {
                let json = metricKitMetricJSON(hangBuckets: [4, 2, 1], hangKey: key, bucketsAsArray: asArray)
                XCTAssertEqual(try XCTUnwrap(MetricKitDayMetrics(payloadJSON: json)).hangs, 7, "\(key), array: \(asArray)")
            }
        }
    }

    func testMetricKitMeasurementUnits() {
        XCTAssertEqual(MetricKitDayMetrics.seconds("250 ms"), 0.25)
        XCTAssertEqual(MetricKitDayMetrics.seconds("2 min"), 120)
        XCTAssertEqual(MetricKitDayMetrics.seconds("7 s"), 7)
        XCTAssertEqual(MetricKitDayMetrics.seconds(NSNumber(value: 9)), 9)
        XCTAssertNil(MetricKitDayMetrics.seconds("3 parsecs"))
        XCTAssertEqual(MetricKitDayMetrics.bytes("1.2e+07 kB"), 12_000_000_000)
        // A number that doesn't parse whole is dropped, not misread.
        XCTAssertNil(MetricKitDayMetrics.seconds("10,5 sec"))
        XCTAssertNil(MetricKitDayMetrics.bytes("1,500 kB"))
        XCTAssertNil(MetricKitDayMetrics.bytes("12abc kB"))
        XCTAssertEqual(MetricKitDayMetrics.bytes("2 GB"), 2_000_000_000)
        XCTAssertEqual(MetricKitDayMetrics.bytes("512 B"), 512)
        XCTAssertNil(MetricKitDayMetrics.bytes(nil))
    }

    func testMetricKitSummaryFormatsSurviveBadValues() {
        XCTAssertEqual(MetricKitReportSummary.duration(3725), "1h02m")
        XCTAssertEqual(MetricKitReportSummary.duration(.infinity), "?")
        XCTAssertEqual(MetricKitReportSummary.duration(1e300), "?")
        XCTAssertEqual(MetricKitReportSummary.duration(-5), "?")
        XCTAssertEqual(MetricKitReportSummary.megabytes(.nan), "?")
    }

    func testMetricKitDiagnosticCounts() {
        let counts = MetricKitDiagnosticCounts(payloadJSON: metricKitDiagnosticJSON(crashes: 1, hangs: 2, cpu: 3, diskWrites: 4, launches: 5))
        XCTAssertEqual(counts, MetricKitDiagnosticCounts(crashes: 1, hangs: 2, cpuExceptions: 3, diskWriteExceptions: 4, launches: 5))
        XCTAssertEqual(counts.total, 15)
        XCTAssertEqual(MetricKitDiagnosticCounts(payloadJSON: Data()).total, 0)
    }

    func testMetricKitSummaryUsesTheLatestDayAndAllDiagnostics() {
        let store = metricKitStore()
        store.save(metricKitMetricJSON(cpu: "1 sec"), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1))
        store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(16), end: metricKitDay(17))
        store.save(metricKitDiagnosticJSON(crashes: 1, hangs: 1), kind: .diagnostics, begin: metricKitDay(3), end: metricKitDay(3))
        store.save(metricKitDiagnosticJSON(hangs: 1, diskWrites: 1), kind: .diagnostics, begin: metricKitDay(5), end: metricKitDay(5))
        let summary = store.summary(timeZone: metricKitUTC)
        XCTAssertEqual(summary.days, 2)
        XCTAssertEqual(summary.latest?.cpuSeconds, 312)
        XCTAssertEqual(summary.diagnostics, MetricKitDiagnosticCounts(crashes: 1, hangs: 2, cpuExceptions: 0, diskWriteExceptions: 1))
        XCTAssertEqual(summary.text, """
        Days stored: 2, latest 2026-10-17: CPU 5m12s, fg 1h02m, bg 4m00s, cell 12.3 MB, Wi-Fi 360.0 MB, disk 45.0 MB, hangs 3
        Diagnostics: crashes 1, hangs 2, CPU exceptions 0, disk-write exceptions 1, slow launches 0
        """)
    }

    func testMetricKitEmptySummary() {
        let summary = metricKitStore().summary(timeZone: metricKitUTC)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.text, "No MetricKit reports yet.")
    }

    // MARK: - Export

    func testMetricKitExportHoldsEveryPayloadAndTheSummary() throws {
        let store = metricKitStore()
        store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(1), end: metricKitDay(2))
        store.save(metricKitMetricJSON(cpu: "1 sec"), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1))
        store.save(metricKitDiagnosticJSON(hangs: 1), kind: .diagnostics, begin: metricKitDay(1), end: metricKitDay(1))
        let url = try XCTUnwrap(store.writeExport(now: metricKitDay(3), appVersion: "0.1.15 (162)", timeZone: metricKitUTC))
        XCTAssertEqual(url.lastPathComponent, MetricKitReportStore.exportFileName)
        // Kept out of the reports folder, so it adds no long-lived copy.
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, store.exportDirectory.standardizedFileURL)
        let data = try Data(contentsOf: url)
        // Compact: no pretty-printing of deep call-stack trees.
        XCTAssertFalse(data.contains(UInt8(ascii: "\n")))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["appVersion"] as? String, "0.1.15 (162)")
        XCTAssertEqual(document["generated"] as? String, "2026-10-04T00:00:00Z")
        XCTAssertEqual(document["summary"] as? String, store.summary(timeZone: metricKitUTC).text)
        let metrics = try XCTUnwrap(document["metricPayloads"] as? [[String: Any]])
        XCTAssertEqual(metrics.count, 2)
        // Oldest first.
        XCTAssertEqual((metrics[0]["cpuMetrics"] as? [String: Any])?["cumulativeCPUTime"] as? String, "1 sec")
        XCTAssertEqual((document["diagnosticPayloads"] as? [Any])?.count, 1)
        // Says what is shared: diagnostics carry call stacks.
        XCTAssertTrue(try XCTUnwrap(document["about"] as? String).contains("call stacks"))
    }

    func testMetricKitExportWithNothingStoredRemovesTheFile() throws {
        let store = metricKitStore()
        store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1))
        XCTAssertNotNil(store.writeExport(now: metricKitDay(1), appVersion: "test", timeZone: metricKitUTC))
        try FileManager.default.removeItem(at: store.entries(.metrics)[0].url)
        XCTAssertNil(store.writeExport(now: metricKitDay(1), appVersion: "test", timeZone: metricKitUTC))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.exportURL.path))
    }

    func testMetricKitAnExistingFolderIsKeptOutOfBackupsOnEveryWrite() throws {
        let store = metricKitStore()
        // A folder an older build or a restore left in backups.
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        XCTAssertNotEqual(try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertTrue(store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1)))
        // A fresh URL: resource values are cached per URL.
        let fresh = URL(fileURLWithPath: store.directory.path, isDirectory: true)
        XCTAssertEqual(try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testMetricKitTheShareFileIsReusedUntilSomethingNewIsStored() async throws {
        let store = metricKitStore()
        let reports = MetricKitReports(store: store)
        // Read from disk each time: URL.resourceValues caches.
        func modified(_ url: URL) throws -> Date? {
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        }
        store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1))
        let first = await reports.load()
        let url = try XCTUnwrap(first.exportURL)
        XCTAssertFalse(first.exportFailed)
        // An old stamp makes a rewrite visible however fast the test runs.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        let again = await reports.load()
        XCTAssertEqual(again.exportURL, url)
        XCTAssertEqual(try modified(url), stamp, "Nothing new: the file isn't written again")

        store.save(metricKitMetricJSON(cpu: "500 sec"), kind: .metrics, begin: metricKitDay(1), end: metricKitDay(2))
        _ = await reports.load()
        XCTAssertNotEqual(try modified(url), stamp, "A new report rewrites it")
    }

    func testMetricKitAShareFileThatCantBeWrittenSaysSo() async throws {
        let store = metricKitStore()
        // A file where the share folder should be: the export can't be written.
        let blocked = store.exportDirectory
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocked)
        store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1))
        let loaded = await MetricKitReports(store: store).load()
        XCTAssertFalse(loaded.summary.isEmpty)
        XCTAssertNil(loaded.exportURL)
        XCTAssertTrue(loaded.exportFailed, "Reports are stored: the page says the file failed rather than look empty")

        let empty = await MetricKitReports(store: metricKitStore()).load()
        XCTAssertFalse(empty.exportFailed, "No reports is not a failure")
    }

    /// A reports folder that can't be read is not "no reports": the share
    /// file already written stays, rather than being deleted.
    func testMetricKitAnUnreadableReportsFolderKeepsTheShareFile() async throws {
        let store = metricKitStore()
        let reports = MetricKitReports(store: store)
        store.save(metricKitMetricJSON(), kind: .metrics, begin: metricKitDay(0), end: metricKitDay(1))
        let first = await reports.load()
        let url = try XCTUnwrap(first.exportURL)

        // A file where the reports folder was: listing it fails.
        try FileManager.default.removeItem(at: store.directory)
        try Data("x".utf8).write(to: store.directory)
        XCTAssertEqual(store.writeExport(now: metricKitDay(1), appVersion: "test", timeZone: metricKitUTC), url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let again = await reports.load()
        XCTAssertEqual(again.exportURL, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The share file survives a failed read")
        XCTAssertEqual(again.summary, first.summary, "The summary last read stays, not an empty one")
        XCTAssertFalse(again.summary.isEmpty)
    }
}
