//
//  DictationClipInboxTests.swift
//  ConduitTests
//
//  The kept Hermes dictations the composer offers: hidden while their
//  dictation owns them, offered once let go or after a relaunch, only for
//  their own host and profile, and gone only once their words are in.
//

import XCTest
@testable import Conduit

@MainActor
final class DictationClipInboxTests: XCTestCase {
    private static let identity = "https://hermes.example|default"
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationClipInboxTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeInbox() -> DictationClipInbox {
        DictationClipInbox(store: DictationClipStore(directory: directory))
    }

    /// Four minutes of 16 kHz PCM16, like the dictation that was lost.
    private let recording = Data(count: 16_000 * 2 * 240)

    func testAKeptRecordingIsOnDiskButHiddenWhileItsDictationOwnsIt() async throws {
        let inbox = makeInbox()
        let clip = try await keepRecording(in: inbox)

        XCTAssertEqual(clip.duration, 240)
        XCTAssertEqual(DictationClipStore(directory: directory).clips().map(\.id), [clip.id])
        XCTAssertTrue(inbox.offered(for: Self.identity).isEmpty, "Still uploading: no Retry yet")

        inbox.release(clip.id)
        XCTAssertEqual(inbox.offered(for: Self.identity).map(\.id), [clip.id])
    }

    func testOnlyItsOwnHostAndProfileOfferIt() async throws {
        let inbox = makeInbox()
        let clip = try await keepRecording(in: inbox)
        inbox.release(clip.id)

        XCTAssertTrue(inbox.offered(for: "https://hermes.example|work").isEmpty)
        XCTAssertTrue(inbox.offered(for: "https://other.example|default").isEmpty)
        XCTAssertTrue(inbox.offered(for: nil).isEmpty)
        XCTAssertTrue(inbox.offered(for: Self.identity, delivering: [clip.id]).isEmpty, "Its words are on their way to a draft")
    }

    func testARecordingNeverDeliveredIsOfferedAfterARelaunch() async throws {
        let first = makeInbox()
        let clip = try await keepRecording(in: first)
        first.attemptFailed(clip.id, error: URLError(.notConnectedToInternet))
        await first.filesWritten()
        // Conduit stopped here: the dictation never let it go.

        let relaunched = makeInbox()
        await relaunched.load()
        let offered = try XCTUnwrap(relaunched.offered(for: Self.identity).first)
        XCTAssertEqual(offered.id, clip.id)
        XCTAssertEqual(offered.attempts, 1)
        XCTAssertNotNil(offered.lastError)
        XCTAssertNotNil(offered.lastAttemptAt)
    }

    func testDeliveredWordsTakeTheRecordingOffDisk() async throws {
        let inbox = makeInbox()
        let clip = try await keepRecording(in: inbox)
        inbox.delivered(clip.id)
        await inbox.filesWritten()

        XCTAssertTrue(inbox.clips.isEmpty)
        XCTAssertTrue(DictationClipStore(directory: directory).clips().isEmpty)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(names.isEmpty, "\(names)")
    }

    func testRetrySendsTheKeptRecordingAndLeavesItUntilTheWordsAreIn() async throws {
        let inbox = makeInbox()
        let clip = try await keepRecording(in: inbox)
        inbox.release(clip.id)
        var sent: VoiceCapturedAudio?

        let words = try await inbox.retry(clip) { audio in
            sent = audio
            return "the words that were lost"
        }

        XCTAssertEqual(words, "the words that were lost")
        XCTAssertEqual(sent?.pcm16Data, recording)
        XCTAssertEqual(sent?.sampleRate, 16_000)
        XCTAssertEqual(sent?.duration, 240)
        XCTAssertTrue(inbox.retrying.isEmpty)
        XCTAssertEqual(inbox.clips.map(\.id), [clip.id], "Deleted only once a draft has the words")
    }

    func testAFailedRetryKeepsTheRecordingAndCountsTheAttempt() async throws {
        let inbox = makeInbox()
        let clip = try await keepRecording(in: inbox)
        inbox.release(clip.id)

        do {
            _ = try await inbox.retry(clip) { _ in throw URLError(.timedOut) }
            XCTFail("Expected the failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        await inbox.filesWritten()

        XCTAssertTrue(inbox.retrying.isEmpty)
        XCTAssertEqual(inbox.offered(for: Self.identity).map(\.id), [clip.id])
        XCTAssertEqual(DictationClipStore(directory: directory).clips().first?.attempts, 1)
    }

    func testARetryThatHearsNothingDeletesAShortRecording() async throws {
        let inbox = makeInbox()
        let kept = await inbox.keep(pcm16: Data(count: 16_000 * 2 * 5), sampleRate: 16_000, identity: Self.identity)
        let clip = try XCTUnwrap(kept)
        inbox.release(clip.id)

        let words = try await inbox.retry(clip) { _ in "" }
        await inbox.filesWritten()

        XCTAssertEqual(words, "")
        XCTAssertTrue(inbox.clips.isEmpty)
        XCTAssertTrue(DictationClipStore(directory: directory).clips().isEmpty)
    }

    func testARetryThatHearsNothingKeepsALongRecording() async throws {
        let inbox = makeInbox()
        let clip = try await keepRecording(in: inbox)
        inbox.release(clip.id)

        let words = try await inbox.retry(clip) { _ in "" }
        await inbox.filesWritten()

        XCTAssertEqual(words, "")
        XCTAssertEqual(inbox.offered(for: Self.identity).map(\.id), [clip.id], "Four minutes of silence isn't trusted")
        XCTAssertEqual(DictationClipStore(directory: directory).clips().map(\.id), [clip.id])
    }

    func testARetryWhoseAudioIsGoneDropsTheRow() async throws {
        let inbox = makeInbox()
        let clip = try await keepRecording(in: inbox)
        inbox.release(clip.id)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(clip.id.uuidString).appendingPathExtension("pcm"))
        var uploads = 0

        do {
            _ = try await inbox.retry(clip) { _ in
                uploads += 1
                return "never"
            }
            XCTFail("Expected the missing audio to end the Retry")
        } catch {
            XCTAssertTrue(error is CancellationError, "Ends quietly, not as a transcription failure: \(error)")
        }
        await inbox.filesWritten()

        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(inbox.offered(for: Self.identity).isEmpty, "Nothing left to retry")
        XCTAssertTrue(DictationClipStore(directory: directory).clips().isEmpty)
    }

    func testARetryWhoseAudioCantBeReadKeepsTheRowAndSaysSo() async throws {
        let inbox = makeInbox()
        let clip = try await keepRecording(in: inbox)
        inbox.release(clip.id)
        let audio = directory.appendingPathComponent(clip.id.uuidString).appendingPathExtension("pcm")
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: false)
        var uploads = 0

        do {
            _ = try await inbox.retry(clip) { _ in
                uploads += 1
                return "never"
            }
            XCTFail("Expected the unreadable audio to end the Retry")
        } catch {
            XCTAssertTrue(error is DictationClipUnreadable, "Says the recording can't be read: \(error)")
        }
        await inbox.filesWritten()

        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(inbox.offered(for: Self.identity).map(\.id), [clip.id], "Still there to retry")
    }

    func testARecordingItsDictationStillOwnsIsNotRetried() async throws {
        let inbox = makeInbox()
        let clip = try await keepRecording(in: inbox)
        var uploads = 0

        do {
            _ = try await inbox.retry(clip) { _ in
                uploads += 1
                return "twice"
            }
            XCTFail("Expected no second upload")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(uploads, 0)
    }

    private func keepRecording(in inbox: DictationClipInbox, file: StaticString = #filePath, line: UInt = #line) async throws -> DictationClip {
        let kept = await inbox.keep(pcm16: recording, sampleRate: 16_000, identity: Self.identity)
        return try XCTUnwrap(kept, file: file, line: line)
    }
}
