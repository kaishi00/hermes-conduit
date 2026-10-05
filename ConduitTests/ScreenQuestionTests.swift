//
//  ScreenQuestionTests.swift
//  ConduitTests
//
//  Ask Hermes About Screen: staging the image the Shortcuts action hands
//  over, its pending launch (a screenshot is kept, never dropped, when
//  Hermes can't be reached), and the "Recent chat" rule for where it goes.
//

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Conduit

final class ScreenQuestionTests: XCTestCase {
    private struct NotStaged: Error {}

    private var stagedURLs: [URL] = []

    override func tearDown() {
        for url in stagedURLs {
            try? FileManager.default.removeItem(at: url)
        }
        stagedURLs = []
        super.tearDown()
    }

    // MARK: - Staging

    func testStageScreenshotKeepsPNG() throws {
        let attachment = try staged(AttachmentStaging.stageScreenshot(
            data: imageData(.png),
            filename: "IMG_0042.PNG",
            limitMegabytes: 16
        ))
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.name, "IMG_0042.png")
        XCTAssertEqual(attachment.mimeType, "image/png")
        let url = try XCTUnwrap(URL(string: attachment.uri))
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(AttachmentStaging.imageType(at: url), .png, "A screenshot goes up as captured")
    }

    func testStageScreenshotReencodesTIFFAsJPEG() throws {
        let attachment = try staged(AttachmentStaging.stageScreenshot(
            data: imageData(.tiff),
            filename: "capture.tiff",
            limitMegabytes: 16
        ))
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.name, "capture.jpg")
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        let url = try XCTUnwrap(URL(string: attachment.uri))
        XCTAssertEqual(AttachmentStaging.imageType(at: url), .jpeg)
    }

    func testStageScreenshotNamesUnnamedImageScreenshot() throws {
        let attachment = try staged(AttachmentStaging.stageScreenshot(
            data: imageData(.png),
            filename: nil,
            limitMegabytes: 16
        ))
        XCTAssertEqual(attachment.name, "Screenshot.png")

        let blank = try staged(AttachmentStaging.stageScreenshot(
            data: imageData(.png),
            filename: "   ",
            limitMegabytes: 16
        ))
        XCTAssertEqual(blank.name, "Screenshot.png")
    }

    func testStageScreenshotRefusesNonImage() {
        let outcome = AttachmentStaging.stageScreenshot(
            data: Data("not an image".utf8),
            filename: "notes.txt",
            limitMegabytes: 16
        )
        guard case .failed(let name) = outcome else {
            return XCTFail("Expected a refusal, got \(outcome)")
        }
        XCTAssertEqual(name, "notes")
    }

    func testStageScreenshotRefusesEmptyData() {
        let outcome = AttachmentStaging.stageScreenshot(data: Data(), filename: nil, limitMegabytes: 16)
        guard case .failed = outcome else {
            return XCTFail("Expected a refusal, got \(outcome)")
        }
    }

    func testStageScreenshotRefusesOversizeBeforeWriting() {
        let oversize = Data(count: 2 * 1024 * 1024 + 1)
        let outcome = AttachmentStaging.stageScreenshot(data: oversize, filename: "big.png", limitMegabytes: 1)
        guard case .tooLarge(let name) = outcome else {
            return XCTFail("Expected tooLarge, got \(outcome)")
        }
        XCTAssertEqual(name, "big")
    }

    // MARK: - Pending launch

    func testFactoryBuildsScreenQuestionLaunch() {
        let now = Date(timeIntervalSince1970: 1_000)
        let intent = PendingVoiceLaunchPolicy.makeScreenQuestionPendingIntent(
            request(question: "  What does this error mean?  "),
            profile: "  work  ",
            now: now
        )
        XCTAssertEqual(intent.source, .screenQuestion)
        XCTAssertEqual(intent.profile, "work")
        XCTAssertFalse(intent.startsFreshConversation, "The chat is picked by the recent-chat rule, not by the launch")
        XCTAssertEqual(intent.externalLaunchDeadline, now.addingTimeInterval(PendingVoiceLaunchPolicy.externalLaunchBudget))
        XCTAssertNotNil(intent.externalLaunchElapsedDeadline)
        XCTAssertEqual(intent.screenQuestion?.question, "What does this error mean?")
        XCTAssertEqual(intent.screenQuestion?.attachment.name, "Screenshot.png")
    }

    func testFactoryDropsBlankQuestionAndProfile() {
        let intent = PendingVoiceLaunchPolicy.makeScreenQuestionPendingIntent(
            request(question: "   "),
            profile: " "
        )
        XCTAssertNil(intent.screenQuestion?.question)
        XCTAssertNil(intent.profile)
    }

    func testConnectedScreenQuestionIsReady() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeScreenQuestionPendingIntent(request(), profile: nil, now: now)
        XCTAssertEqual(PendingVoiceLaunchPolicy.readiness(for: intent, connection: connection(.connected), now: now), .ready)
        XCTAssertEqual(PendingVoiceLaunchPolicy.readiness(for: intent, connection: connection(.connecting), now: now), .waiting)
    }

    func testScreenshotWaitsForConduitToSettle() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeScreenQuestionPendingIntent(request(), profile: nil, now: now)
        var settling = connection(.connected)
        settling.isSettling = true
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: settling, now: now), .waiting,
            "Placed now, the screenshot lands on a chat the settling work replaces"
        )
    }

    func testSiriDoesNotWaitForConduitToSettle() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now)
        var settling = connection(.connected)
        settling.isSettling = true
        XCTAssertEqual(PendingVoiceLaunchPolicy.readiness(for: intent, connection: settling, now: now), .ready)
    }

    func testStableFailureKeepsTheScreenshot() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeScreenQuestionPendingIntent(request(), profile: nil, now: now)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: connection(.stableFailure), now: now),
            .failed(message: PendingVoiceLaunchPolicy.screenQuestionFailureMessage)
        )
    }

    func testExpiredLaunchKeepsTheScreenshot() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeScreenQuestionPendingIntent(request(), profile: nil, now: now)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(
                for: intent,
                connection: connection(.connecting),
                now: now.addingTimeInterval(PendingVoiceLaunchPolicy.externalLaunchBudget)
            ),
            .failed(message: PendingVoiceLaunchPolicy.screenQuestionFailureMessage)
        )
    }

    func testHandlerFailureIsTerminal() {
        let intent = PendingVoiceLaunchPolicy.makeScreenQuestionPendingIntent(request(), profile: nil)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.handlerFailure(for: intent),
            .terminal(message: PendingVoiceLaunchPolicy.screenQuestionFailureMessage)
        )
    }

    func testFailureMessageSaysTheScreenshotIsKept() {
        XCTAssertTrue(PendingVoiceLaunchPolicy.screenQuestionFailureMessage.contains("screenshot"))
    }

    func testUsageRecordsLastRun() throws {
        let suite = "ScreenQuestionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(ScreenQuestionUsage.lastUsed(defaults: defaults))
        let ran = Date(timeIntervalSince1970: 1_234_567)
        ScreenQuestionUsage.recordUse(at: ran, defaults: defaults)
        XCTAssertEqual(ScreenQuestionUsage.lastUsed(defaults: defaults), ran)
    }

    // MARK: - Shortcut link

    func testShortcutLinkReadsTheICloudLink() throws {
        let url = ScreenQuestionShortcutLink.shortcutURL(fromConfig: config(#"{"url": " https://www.icloud.com/shortcuts/0a1b2c3d "}"#))
        XCTAssertEqual(url?.absoluteString, "https://www.icloud.com/shortcuts/0a1b2c3d")
        // A real link's id is 32 hex digits; "-" and "_" are allowed in case one isn't.
        let hex = "https://www.icloud.com/shortcuts/7e3f0c1a9b2d4e5f8a6b0c1d2e3f4a5b"
        XCTAssertEqual(ScreenQuestionShortcutLink.shortcutURL(fromConfig: config(#"{"url": "\#(hex)"}"#))?.absoluteString, hex)
        let dashed = "https://www.icloud.com/shortcuts/0a1b-2c3d_4e"
        XCTAssertEqual(ScreenQuestionShortcutLink.shortcutURL(fromConfig: config(#"{"url": "\#(dashed)"}"#))?.absoluteString, dashed)
    }

    func testShortcutLinkOpensOnlyICloudShortcuts() {
        let refused = [
            #"{"url": null}"#,
            #"{}"#,
            #"not json"#,
            #"{"url": "http://www.icloud.com/shortcuts/0a1b2c3d"}"#,
            #"{"url": "https://evil.example/shortcuts/0a1b2c3d"}"#,
            #"{"url": "https://www.icloud.com.evil.example/shortcuts/0a1b2c3d"}"#,
            #"{"url": "https://user@www.icloud.com/shortcuts/0a1b2c3d"}"#,
            #"{"url": "https://www.icloud.com:8443/shortcuts/0a1b2c3d"}"#,
            #"{"url": "https://www.icloud.com/shortcuts/"}"#,
            #"{"url": "https://www.icloud.com/notes/0a1b2c3d"}"#,
            #"{"url": "https://www.icloud.com/shortcuts/0a1b2c3d/extra"}"#,
            #"{"url": "https://www.icloud.com/shortcuts/0a1b2c3d?next=https://evil.example"}"#,
            #"{"url": "https://www.icloud.com/shortcuts/0a1b2c3d#fragment"}"#,
            #"{"url": "https://www.icloud.com/shortcuts/.."}"#,
            #"{"url": "https://www.icloud.com/shortcuts/%2e%2e"}"#
        ]
        for json in refused {
            XCTAssertNil(ScreenQuestionShortcutLink.shortcutURL(fromConfig: config(json)), json)
        }
    }

    func testAddTheShortcutOpensTheLinkTheSiteNames() async {
        var fetched: [URL] = []
        let url = await ScreenQuestionShortcutLink.resolve { requested in
            fetched.append(requested)
            return self.config(#"{"url": "https://www.icloud.com/shortcuts/0a1b2c3d", "updated": "2026-10-05"}"#)
        }
        XCTAssertEqual(fetched, [ScreenQuestionShortcutLink.configURL])
        XCTAssertEqual(url.absoluteString, "https://www.icloud.com/shortcuts/0a1b2c3d")
    }

    func testAddTheShortcutFallsBackToThePage() async {
        let unpublished = await ScreenQuestionShortcutLink.resolve { _ in self.config(#"{"url": null}"#) }
        XCTAssertEqual(unpublished, ScreenQuestionShortcutLink.pageURL, "No link yet: the page shows how to build it")

        let offline = await ScreenQuestionShortcutLink.resolve { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(offline, ScreenQuestionShortcutLink.pageURL)
    }

    // MARK: - Recent chat

    func testScreenshotWithinFiveMinutesContinuesOpenChat() {
        let left = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(ScreenQuestionPolicy.continuesOpenChat(
            lastLeftForegroundAt: left,
            enqueuedAt: left.addingTimeInterval(300),
            hasOpenChat: true
        ))
    }

    func testScreenshotAfterFiveMinutesStartsNewChat() {
        let left = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(ScreenQuestionPolicy.continuesOpenChat(
            lastLeftForegroundAt: left,
            enqueuedAt: left.addingTimeInterval(301),
            hasOpenChat: true
        ))
    }

    func testScreenshotWithoutForegroundHistoryStartsNewChat() {
        XCTAssertFalse(ScreenQuestionPolicy.continuesOpenChat(
            lastLeftForegroundAt: nil,
            enqueuedAt: Date(),
            hasOpenChat: true
        ))
    }

    func testScreenshotWithNoOpenChatStartsNewChat() {
        let left = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(ScreenQuestionPolicy.continuesOpenChat(
            lastLeftForegroundAt: left,
            enqueuedAt: left.addingTimeInterval(5),
            hasOpenChat: false
        ))
    }

    // MARK: - Voice routing

    func testEveryLiveEngineStartsClearedForScreenQuestions() {
        // v1 starts in the profile's own voice mode; the device test takes
        // an engine off this list if it doesn't hand the question to Hermes.
        XCTAssertEqual(ScreenQuestionVoiceRouting.liveEngines, [.gptLive, .geminiLive, .grokLive])
        XCTAssertEqual(ScreenQuestionVoiceRouting.liveEngine(for: .geminiLive), .geminiLive)
        XCTAssertNil(ScreenQuestionVoiceRouting.liveEngine(for: nil), "A classic profile stays classic")
    }

    func testEngineOffTheListUsesClassicVoice() {
        XCTAssertNil(ScreenQuestionVoiceRouting.liveEngine(for: .grokLive, allowed: [.gptLive]))
        XCTAssertEqual(ScreenQuestionVoiceRouting.liveEngine(for: .gptLive, allowed: [.gptLive]), .gptLive)
    }

    func testOpensWithDefaultsToVoice() throws {
        let suite = "ScreenQuestionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ScreenQuestionPreferences.startWith(defaults: defaults), .voice)
        defaults.set("keyboard", forKey: ScreenQuestionPreferences.startWithKey)
        XCTAssertEqual(ScreenQuestionPreferences.startWith(defaults: defaults), .keyboard)
        defaults.set("telepathy", forKey: ScreenQuestionPreferences.startWithKey)
        XCTAssertEqual(ScreenQuestionPreferences.startWith(defaults: defaults), .voice)
    }

    func testScreenshotTakenWhileConduitWasOnScreenCountsAsInUse() {
        let since = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(ScreenQuestionPolicy.wasOnScreen(activeSince: since, enqueuedAt: since.addingTimeInterval(600)))
        XCTAssertTrue(ScreenQuestionPolicy.wasOnScreen(
            activeSince: since,
            enqueuedAt: since.addingTimeInterval(ScreenQuestionPolicy.onScreenGrace)
        ))
        XCTAssertFalse(
            ScreenQuestionPolicy.wasOnScreen(activeSince: since, enqueuedAt: since.addingTimeInterval(1)),
            "The launch brought Conduit up"
        )
        XCTAssertFalse(ScreenQuestionPolicy.wasOnScreen(activeSince: nil, enqueuedAt: since))
    }

    // MARK: - Helpers

    private func staged(
        _ outcome: AttachmentStaging.StagedImport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Attachment {
        guard case .staged(let attachment) = outcome else {
            XCTFail("Expected a staged attachment, got \(outcome)", file: file, line: line)
            throw NotStaged()
        }
        if let url = URL(string: attachment.uri) { stagedURLs.append(url) }
        return attachment
    }

    private func imageData(_ type: UTType) -> Data {
        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create a bitmap context")
            return Data()
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            XCTFail("Could not encode a \(type.identifier) image")
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func config(_ json: String) -> Data {
        Data(json.utf8)
    }

    private func request(question: String? = nil) -> ScreenQuestionRequest {
        ScreenQuestionRequest(
            attachment: Attachment(
                id: "shot",
                name: "Screenshot.png",
                uri: "file:///tmp/Screenshot.png",
                mimeType: "image/png",
                kind: .image
            ),
            question: question,
            startWith: nil,
            enqueuedAt: Date()
        )
    }

    private func connection(_ phase: VoiceLaunchConnectionSnapshot.Phase) -> VoiceLaunchConnectionSnapshot {
        VoiceLaunchConnectionSnapshot(
            isConnected: phase == .connected,
            isConnecting: phase == .connecting,
            hasStableFailureEvidence: phase == .stableFailure,
            classifiedFailure: nil
        )
    }
}
