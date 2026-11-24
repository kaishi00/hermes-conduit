import XCTest
@testable import Conduit

/// A Bot Chat's cover: shown over the chat open before, it lifts once the
/// coming chat's own rows are laid out, never waiting for Hermes' rows,
/// and at a cap or on any other end at the latest.
extension BotModeTests {

    func testTheCoverStaysOverTheChatOpenBefore() {
        var lift = BotChatCoverLift()
        XCTAssertEqual(lift.coverChanged(coming: "atlas", openBotChat: "zhongli"), .show)
        XCTAssertTrue(lift.shows)
        XCTAssertEqual(lift.coverChanged(coming: "atlas", openBotChat: "zhongli"), .none)
        XCTAssertEqual(lift.ownRowsLaidOut(), .none, "the chat open before's rows lift nothing")
        XCTAssertEqual(lift.capReached(), .none)
        XCTAssertTrue(lift.shows)
    }

    func testItLiftsOnceTheComingChatsOwnRowsAreLaidOut() {
        var lift = BotChatCoverLift()
        _ = lift.coverChanged(coming: "atlas", openBotChat: "zhongli")
        XCTAssertEqual(lift.coverChanged(coming: nil, openBotChat: "Atlas"), .awaitRows)
        XCTAssertTrue(lift.shows, "the open chat's rows are still to be laid out")
        XCTAssertEqual(lift.coverChanged(coming: nil, openBotChat: "Atlas"), .none, "one wait")
        XCTAssertEqual(lift.ownRowsLaidOut(), .lift)
        XCTAssertFalse(lift.shows)
        XCTAssertEqual(lift.capReached(), .none)
    }

    func testItLiftsAtTheCap() {
        var lift = BotChatCoverLift()
        _ = lift.coverChanged(coming: "atlas", openBotChat: nil)
        _ = lift.coverChanged(coming: nil, openBotChat: "atlas")
        XCTAssertEqual(lift.capReached(), .lift)
        XCTAssertFalse(lift.shows)
    }

    func testAnOpenThatFailsLiftsItAtOnce() {
        var lift = BotChatCoverLift()
        _ = lift.coverChanged(coming: "atlas", openBotChat: "zhongli")
        XCTAssertEqual(lift.coverChanged(coming: nil, openBotChat: "zhongli"), .lift)
        XCTAssertFalse(lift.shows)
        // Waiting for rows, another chat opened.
        _ = lift.coverChanged(coming: "atlas", openBotChat: nil)
        _ = lift.coverChanged(coming: nil, openBotChat: "atlas")
        XCTAssertEqual(lift.coverChanged(coming: nil, openBotChat: nil), .lift)
        // A newer tap while waiting covers again.
        _ = lift.coverChanged(coming: "atlas", openBotChat: nil)
        _ = lift.coverChanged(coming: nil, openBotChat: "atlas")
        XCTAssertEqual(lift.coverChanged(coming: "rei", openBotChat: "atlas"), .none)
        XCTAssertTrue(lift.shows)
        XCTAssertFalse(lift.awaitsRows)
        XCTAssertEqual(lift.ownRowsLaidOut(), .none, "atlas's rows don't lift rei's cover")
    }

    /// The fade plays in Core Animation, at up to 120 Hz, and the cover
    /// takes no taps once lifted.
    @MainActor
    func testTheFadeLiftsTheCoverAtTheCapOrOnTheRows() async throws {
        let fade = BotChatCoverFade()
        fade.cap = .milliseconds(20)
        let cover = UIView()
        fade.cover = cover
        fade.place()
        XCTAssertEqual(cover.layer.opacity, 0)
        fade.coverChanged(coming: "atlas", openBotChat: nil, animated: false)
        XCTAssertEqual(cover.layer.opacity, 1)
        XCTAssertTrue(cover.isUserInteractionEnabled)
        XCTAssertFalse(cover.accessibilityElementsHidden)
        XCTAssertFalse(fade.shown.covers, "published after the update it ran in")
        for _ in 0..<200 where !fade.shown.covers {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(fade.shown.covers)
        fade.coverChanged(coming: nil, openBotChat: "atlas", animated: true)
        XCTAssertEqual(cover.layer.opacity, 1, "waits for the rows")
        XCTAssertTrue(fade.shown.covers, "the chat under it stays from VoiceOver through the row wait")
        for _ in 0..<200 where cover.layer.opacity != 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(cover.layer.opacity, 0)
        for _ in 0..<200 where fade.shown.covers {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(fade.shown.covers)
        XCTAssertFalse(cover.isUserInteractionEnabled)
        XCTAssertTrue(cover.accessibilityElementsHidden)

        // The coming chat's own rows laid out lift it before the cap.
        fade.cap = .seconds(30)
        fade.coverChanged(coming: "rei", openBotChat: "atlas", animated: true)
        XCTAssertEqual(cover.layer.opacity, 1)
        fade.coverChanged(coming: nil, openBotChat: "rei", animated: true)
        fade.ownRowsLaidOut()
        XCTAssertEqual(cover.layer.opacity, 0)
        let animation = BotChatCoverFade.fade(from: 1, to: 0, reduceMotion: false)
        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertEqual(animation.duration, 0.3, accuracy: 0.001)
        XCTAssertEqual(animation.preferredFrameRateRange.preferred, 120)
        XCTAssertEqual(BotChatCoverFade.fade(from: 1, to: 0, reduceMotion: true).duration, 0.22, accuracy: 0.001)
    }
}
