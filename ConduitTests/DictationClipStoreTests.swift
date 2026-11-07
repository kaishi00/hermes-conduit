//
//  DictationClipStoreTests.swift
//  ConduitTests
//
//  A Hermes dictation's recording on disk: it is there after a relaunch
//  with its attempts, out of backups, and pruned by age, count and half
//  saves only. And when its upload is tried again on its own.
//

import XCTest
@testable import Conduit

final class DictationClipStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationClipStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func clip(recordedAt: Date = Date(), identity: String = "https://hermes.example|default") -> DictationClip {
        DictationClip(id: UUID(), recordedAt: recordedAt, duration: 1, sampleRate: 16_000, identity: identity)
    }

    // MARK: - Store

    func testASavedClipIsThereForTheNextLaunch() throws {
        let pcm = Data((0..<32_000).map { UInt8($0 % 251) })
        let saved = clip()
        try DictationClipStore(directory: directory).save(pcm16: pcm, clip: saved)

        let relaunched = DictationClipStore(directory: directory)
        XCTAssertEqual(relaunched.clips(), [saved])
        XCTAssertEqual(try relaunched.audio(for: saved), pcm)
    }

    func testTheDirectoryStaysOutOfBackups() throws {
        try DictationClipStore(directory: directory).save(pcm16: Data([1, 2]), clip: clip())
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testFailedAttemptsAreKeptAcrossALaunch() throws {
        let store = DictationClipStore(directory: directory)
        var kept = clip()
        try store.save(pcm16: Data([1, 2]), clip: kept)
        kept.attempts = 3
        kept.lastAttemptAt = Date(timeIntervalSince1970: 1_800_000_000)
        kept.lastError = "The Internet connection appears to be offline."
        try store.update(kept)

        let reloaded = try XCTUnwrap(DictationClipStore(directory: directory).clips().first)
        XCTAssertEqual(reloaded.attempts, 3)
        XCTAssertEqual(reloaded.lastAttemptAt, kept.lastAttemptAt)
        XCTAssertEqual(reloaded.lastError, kept.lastError)
    }

    func testClipsAreListedNewestFirstAndRemovedWhole() throws {
        let store = DictationClipStore(directory: directory)
        let older = clip(recordedAt: Date(timeIntervalSinceNow: -60))
        let newer = clip()
        try store.save(pcm16: Data([1]), clip: older)
        try store.save(pcm16: Data([2]), clip: newer)
        XCTAssertEqual(store.clips().map(\.id), [newer.id, older.id])

        store.remove(newer.id)
        XCTAssertEqual(store.clips().map(\.id), [older.id])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(newer.id.uuidString) })
    }

    func testPruneDropsClipsPastTheirAgeAndTheOldestPastCapacity() throws {
        let store = DictationClipStore(directory: directory)
        let now = Date()
        let expired = clip(recordedAt: now.addingTimeInterval(-DictationClipStore.maximumAge - 60))
        try store.save(pcm16: Data([0]), clip: expired)
        let recent = (0..<(DictationClipStore.capacity + 2)).map { clip(recordedAt: now.addingTimeInterval(-Double($0) * 60)) }
        for each in recent { try store.save(pcm16: Data([1]), clip: each) }

        let kept = store.prune(now: now)

        XCTAssertEqual(kept.map(\.id), recent.prefix(DictationClipStore.capacity).map(\.id))
        XCTAssertEqual(store.clips().map(\.id), kept.map(\.id))
    }

    func testPruneRemovesAHalfSavedClipOnlyOnceItIsOld() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let audioOnly = directory.appendingPathComponent(id).appendingPathExtension("pcm")
        try Data([1, 2, 3]).write(to: audioOnly)
        let store = DictationClipStore(directory: directory)

        // A save may still be writing its description.
        store.prune(now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioOnly.path))

        store.prune(now: Date().addingTimeInterval(DictationClipStore.orphanAge + 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioOnly.path))
    }

    func testPruneKeepsAWholeClipItCantReadUntilItIsPastTheAgeLimit() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let audio = directory.appendingPathComponent(id).appendingPathExtension("pcm")
        let unreadable = directory.appendingPathComponent(id).appendingPathExtension("json")
        try Data([1, 2, 3]).write(to: audio)
        try Data("not yet readable".utf8).write(to: unreadable)
        let store = DictationClipStore(directory: directory)

        store.prune(now: Date().addingTimeInterval(DictationClipStore.orphanAge + 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path))

        store.prune(now: Date().addingTimeInterval(DictationClipStore.maximumAge + 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadable.path))
    }

    // MARK: - Retry decision

    func testABriefNetworkGapIsTriedFiveTimesOverAboutTwoMinutes() {
        let offline = URLError(.notConnectedToInternet)
        let waits = (1...DictationUploadRetry.maximumAttempts).map {
            DictationUploadRetry.delay(afterAttempt: $0, failedWith: offline)
        }
        XCTAssertEqual(waits, [.seconds(5), .seconds(15), .seconds(30), .seconds(60), nil])
        XCTAssertEqual(DictationUploadRetry.maximumAttempts, 5)
        XCTAssertEqual(DictationUploadRetry.delays.reduce(.zero, +), .seconds(110))
    }

    func testOnlyFailuresThatCanPassAreTriedAgain() {
        let transient: [Error] = [
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
            URLError(.networkConnectionLost),
            URLError(.cannotConnectToHost),
            DashboardTicketBridgeError.notReady,
            DashboardTicketBridgeError.answeredAfterSwitch,
            DashboardTicketBridgeError.http(status: 0, detail: ""),
            DashboardTicketBridgeError.http(status: 408, detail: ""),
            DashboardTicketBridgeError.http(status: 429, detail: ""),
            DashboardTicketBridgeError.http(status: 502, detail: ""),
            DashboardTicketBridgeError.http(status: 503, detail: ""),
        ]
        let lasting: [Error] = [
            URLError(.cancelled),
            URLError(.badURL),
            URLError(.serverCertificateUntrusted),
            DashboardTicketBridgeError.signInRequired,
            DashboardTicketBridgeError.requestFailed("Speech to text is not configured"),
            DashboardTicketBridgeError.http(status: 400, detail: ""),
            DashboardTicketBridgeError.http(status: 413, detail: "Request body too large"),
            DashboardTicketBridgeError.http(status: 501, detail: ""),
            CancellationError(),
        ]
        for error in transient {
            XCTAssertTrue(DictationUploadRetry.isTransient(error), "\(error)")
            XCTAssertEqual(DictationUploadRetry.delay(afterAttempt: 1, failedWith: error), .seconds(5), "\(error)")
        }
        for error in lasting {
            XCTAssertFalse(DictationUploadRetry.isTransient(error), "\(error)")
            XCTAssertNil(DictationUploadRetry.delay(afterAttempt: 1, failedWith: error), "\(error)")
        }
    }

    @MainActor
    func testRunTriesAgainAfterAGapAndReturnsTheWords() async throws {
        var attempts = 0
        var waits: [Duration] = []
        var failures = 0
        let words = try await DictationUploadRetry.run(
            attempt: {
                attempts += 1
                if attempts < 3 { throw URLError(.networkConnectionLost) }
                return "hello there"
            },
            sleep: { waits.append($0) },
            onFailedAttempt: { _ in failures += 1 }
        )
        XCTAssertEqual(words, "hello there")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(failures, 2)
        XCTAssertEqual(waits, [.seconds(5), .seconds(15)])
    }

    @MainActor
    func testRunGivesUpAfterTheLastAttemptWithItsError() async {
        var attempts = 0
        var waits: [Duration] = []
        do {
            _ = try await DictationUploadRetry.run(
                attempt: {
                    attempts += 1
                    throw URLError(.timedOut)
                },
                sleep: { waits.append($0) }
            )
            XCTFail("Expected the last failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(attempts, DictationUploadRetry.maximumAttempts)
        XCTAssertEqual(waits, DictationUploadRetry.delays)
    }

    @MainActor
    func testRunStopsAtOnceOnAFailureThatWontPass() async {
        var attempts = 0
        do {
            _ = try await DictationUploadRetry.run(
                attempt: {
                    attempts += 1
                    throw DashboardTicketBridgeError.signInRequired
                },
                sleep: { _ in XCTFail("No wait for a failure that won't pass") }
            )
            XCTFail("Expected the failure")
        } catch {
            guard case DashboardTicketBridgeError.signInRequired = error else {
                return XCTFail("Unexpected \(error)")
            }
        }
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testRunEndsWhenCancelledWhileWaiting() async {
        var attempts = 0
        var failures = 0
        do {
            _ = try await DictationUploadRetry.run(
                attempt: {
                    attempts += 1
                    throw URLError(.notConnectedToInternet)
                },
                sleep: { _ in throw CancellationError() },
                onFailedAttempt: { _ in failures += 1 }
            )
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(failures, 1)
    }
}
