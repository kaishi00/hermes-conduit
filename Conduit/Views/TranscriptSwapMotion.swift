//
//  TranscriptSwapMotion.swift
//  Conduit
//

import UIKit

/// The slide between a Bot Chat and its workstream (`BotChatSwap`), played
/// by the transcript's own view rather than by SwiftUI.
///
/// The two chats share one screen, so the transcript's rows are swapped in
/// place, and the swap is the busiest moment the screen has: every row on
/// screen is made and measured again, in one pass of several hundred
/// milliseconds on the main thread. An animation SwiftUI runs needs the main
/// thread for each of its frames, so the slide it ran there had none to play
/// in (a device trace, 2026-11-14: one frame held over 300 ms). Core
/// Animation's own run in the render server, whatever the main thread does:
/// the chat on screen leaves as the swap is asked for, and the new one
/// comes in with the pass that draws its rows.
@MainActor
final class TranscriptSwapMotion {
    /// What plays the slide: the open chat's transcript.
    weak var stage: TranscriptSwapStage?
    /// The slide the chat being opened comes in with.
    private(set) var expected: BotChatSwap?
    /// The chat `expected` was asked for, as the transcript names it.
    private(set) var expectedConversation: String?
    /// The chat being opened is the one the transcript draws, and only
    /// its rows are still to come (Hermes hasn't sent them, and it has no
    /// saved ones).
    private(set) var chatIsOnStage = false
    /// How long a swap that was asked for may take to draw. Past it the
    /// open failed or was stood down: a transcript that left comes back,
    /// and a later change of chat doesn't slide for this one.
    var patience: Duration = .seconds(3)
    /// How long the chat's rows may take once the transcript draws the
    /// chat. Past it the chat has none, and what it does show (an empty
    /// chat's welcome) comes back.
    var rowsPatience: Duration = .milliseconds(800)
    private var waiting: Task<Void, Never>?

    /// The chat on screen leaves, ahead of the one being opened: the swipe
    /// or the tap is answered at once, while the open runs.
    func leave(_ swap: BotChatSwap) {
        // A chat left while its own rows were still waited for no longer
        // has a slide to come in with.
        expected = nil
        expectedConversation = nil
        chatIsOnStage = false
        stage?.slideOut(swap, atOnce: true)
        wait(patience)
    }

    /// The chat being opened, `conversation` as the transcript names it,
    /// comes in as `swap` once its rows are drawn. The screen hears of the
    /// open and the transcript of its rows in no set order, so rows drawn
    /// a moment ago slide in now. Until they're drawn, what the transcript
    /// shows steps aside: the chat being left, or the opened chat's
    /// welcome while it has no rows yet. Heard of later than that, with
    /// the chat already showing, nothing moves: rows that slid away then
    /// would have nothing to bring them back (the first re-trace of
    /// #2458's second build, every open).
    func expect(_ swap: BotChatSwap, conversation: String) {
        guard let stage else {
            expected = swap
            expectedConversation = conversation
            chatIsOnStage = false
            wait(patience)
            return
        }
        let onStage = stage.shownConversation == conversation
        // Asked again for the chat whose rows are being waited for (the
        // screen places a chat a second time once the open chat's id is
        // in): the wait goes on, so the rows still slide in. Only that
        // chat's: another chat's rows on stage take their own slide.
        if onStage, expected != nil, chatIsOnStage, expectedConversation == conversation {
            expected = swap
            expectedConversation = conversation
            return
        }
        let justDrawn = onStage && stage.conversationJustChanged
        if onStage, stage.showsChatRows || !justDrawn {
            settle()
            if justDrawn {
                stage.slideIn(swap)
            } else {
                stage.comeBack()
            }
            return
        }
        expected = swap
        expectedConversation = conversation
        chatIsOnStage = onStage
        if !stage.rowsAreAway { stage.slideOut(swap, atOnce: false) }
        wait(onStage ? rowsPatience : patience)
    }

    /// The transcript drew rows, another chat's when `conversationChanged`:
    /// the slide they come in with, once they are the expected chat's own
    /// rows (`chatRows`), not its welcome or a status line.
    func rowsDrawn(conversationChanged: Bool, chatRows: Bool) -> BotChatSwap? {
        guard let swap = expected else { return nil }
        if conversationChanged { chatIsOnStage = true }
        guard chatIsOnStage else { return nil }
        if chatRows {
            settle()
            return swap
        }
        if conversationChanged { wait(rowsPatience) }
        return nil
    }

    /// Whether the swap still to come was asked for another chat than
    /// `conversation`, whose rows the transcript just drew: a second swap
    /// the screen hasn't heard of yet (issue 2513). Those rows wait for
    /// the screen to ask their own slide in this pass, rather than come in
    /// with the first swap's.
    func waitsForAnotherChat(than conversation: String?) -> Bool {
        guard expected != nil, let expectedConversation else { return false }
        return expectedConversation != conversation
    }

    private func settle() {
        expected = nil
        expectedConversation = nil
        chatIsOnStage = false
        waiting?.cancel()
        waiting = nil
    }

    private func wait(_ patience: Duration) {
        waiting?.cancel()
        waiting = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: patience) } catch { return }
            // A wait stood down as its sleep ended (the swap drew, or a
            // newer one started its own) isn't this one's to end.
            guard let self, !Task.isCancelled else { return }
            waiting = nil
            expected = nil
            expectedConversation = nil
            chatIsOnStage = false
            stage?.comeBack()
        }
    }
}

/// The transcript, as `TranscriptSwapMotion` moves it.
@MainActor
protocol TranscriptSwapStage: AnyObject {
    /// The chat whose rows are drawn, as the chat view names it.
    var shownConversation: String? { get }
    /// Another chat's rows were drawn in this pass of the main thread.
    var conversationJustChanged: Bool { get }
    /// The rows drawn include the chat's own (a message, a turn under
    /// way), not only its welcome or a status line, nor still the rows of
    /// the chat it took over from.
    var showsChatRows: Bool { get }
    /// The rows slid away and wait for `slideIn` or `comeBack`.
    var rowsAreAway: Bool { get }
    /// The rows on screen leave, and stay away until `slideIn` or
    /// `comeBack`. `atOnce` sends the slide to the render server before
    /// returning, for a tap whose open keeps the main thread next; never
    /// from inside a view update.
    func slideOut(_ swap: BotChatSwap, atOnce: Bool)
    /// The rows now drawn come in from their side.
    func slideIn(_ swap: BotChatSwap)
    /// Rows that left show again where they were: their chat is still the
    /// open one, or it has nothing else to show.
    func comeBack()
}

/// The rows a transcript held as its chat changed. The pass that changes
/// the chat still carries the last chat's rows, and the new one's follow a
/// pass or more later (a device log, #2458: a workstream's conversation
/// drawn with its Bot Chat's 60 rows, then the welcome, then its own 21
/// some 240 ms on), so a slide played on that pass moved the chat being
/// left. Rows count as the new chat's once its own rows differ from these:
/// the chat's own rows only, as the carried ones lose a Bot Chat's Load
/// earlier (a second device log: 61 rows shown, 60 carried).
struct TranscriptRowsOfChatLeft {
    private var ids: [String]?

    mutating func chatChanged(showing rows: [TranscriptRow]) {
        ids = Self.chatRowIDs(rows)
    }

    /// Whether `rows` are still the ones the chat left showed.
    mutating func areStill(_ rows: [TranscriptRow]) -> Bool {
        guard let ids else { return false }
        if Self.chatRowIDs(rows) == ids { return true }
        self.ids = nil
        return false
    }

    private static func chatRowIDs(_ rows: [TranscriptRow]) -> [String] {
        rows.filter(\.isChatRow).map(\.id)
    }
}

/// The slide's shape, apart from the layer it plays on.
enum TranscriptSwapSlide {
    static let key = "conduit.transcriptSwap"

    /// Where the chat leaving goes, in widths toward the trailing edge: a
    /// pop's goes off that edge under the finger, a push's steps a little
    /// toward the leading one, under the chat coming in.
    static func leavingShift(_ swap: BotChatSwap) -> CGFloat {
        swap == .back ? 1 : -0.3
    }

    /// Where the chat coming in starts, in widths toward the trailing
    /// edge: a push's off that edge, a pop's a little toward the leading
    /// one, where a pushed-over screen waits.
    static func arrivingShift(_ swap: BotChatSwap) -> CGFloat {
        swap == .forward ? 1 : -0.3
    }

    /// How faint the chat coming in starts.
    static func arrivingOpacity(_ swap: BotChatSwap) -> Float {
        swap == .forward ? 0.4 : 0
    }

    static func out(from layer: CALayer, by distance: CGFloat) -> CAAnimation {
        let shown = layer.presentation() ?? layer
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = shown.value(forKeyPath: "transform.translation.x") ?? 0
        move.toValue = distance
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown.opacity
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        // Quick off the mark and slow to finish: it answers the finger at
        // once and is still moving when the open's rows come in, a few
        // hundred milliseconds later on a long chat.
        group.duration = outDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // Away until the new rows come in, or these come back.
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        return group
    }

    static let outDuration: TimeInterval = 0.35

    /// The rows themselves while a picture of them slides out: unseen
    /// where they are, until the new chat's slide in or they come back.
    static func unseen() -> CAAnimation {
        let hide = CABasicAnimation(keyPath: "opacity")
        hide.fromValue = 0
        hide.toValue = 0
        hide.duration = 1
        hide.fillMode = .forwards
        hide.isRemovedOnCompletion = false
        return hide
    }

    static func `in`(from distance: CGFloat, opacity: Float) -> CAAnimation {
        let move = CASpringAnimation(perceptualDuration: 0.32, bounce: 0)
        move.keyPath = "transform.translation.x"
        move.fromValue = distance
        move.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 1
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = move.settlingDuration
        fade.duration = 0.32
        return group
    }

    static func back(from layer: CALayer) -> CAAnimation {
        let shown = layer.presentation() ?? layer
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = shown.value(forKeyPath: "transform.translation.x") ?? 0
        move.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown.opacity
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.2
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return group
    }
}
