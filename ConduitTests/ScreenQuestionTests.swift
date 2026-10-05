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
