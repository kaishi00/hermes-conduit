//
//  TranscriptSwapMotion.swift
//  Conduit
//

import SwiftUI
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
    /// The slide the chat about to be drawn comes in with.
    private(set) var expected: BotChatSwap?
    /// How long a swap that was asked for may take to draw. Past it the
    /// open failed or was stood down: a transcript that left comes back,
    /// and a later change of chat doesn't slide for this one.
    var patience: Duration = .seconds(3)
    private var waiting: Task<Void, Never>?

    /// The chat on screen leaves, ahead of the one being opened: the swipe
    /// or the tap is answered at once, while the open runs.
    func leave(_ swap: BotChatSwap) {
        stage?.slideOut(swap)
        wait()
    }

    /// The chat being opened comes in as `swap` once its rows are drawn.
    /// The screen hears of the open and the transcript of its rows in no
    /// set order, so rows drawn a moment ago slide in now.
    func expect(_ swap: BotChatSwap) {
        if let stage, stage.conversationJustChanged {
            settle()
            stage.slideIn(swap)
        } else {
            expected = swap
            wait()
        }
    }

    /// The transcript drew another chat's rows: the slide they come in
    /// with, if one was expected.
    func conversationChanged() -> BotChatSwap? {
        defer { settle() }
        return expected
    }

    private func settle() {
        expected = nil
        waiting?.cancel()
        waiting = nil
    }

    private func wait() {
        waiting?.cancel()
        let patience = patience
        waiting = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: patience) } catch { return }
            // A wait stood down as its sleep ended (the swap drew, or a
            // newer one started its own) isn't this one's to end.
            guard let self, !Task.isCancelled else { return }
            waiting = nil
            expected = nil
            stage?.comeBack()
        }
    }
}

/// The transcript, as `TranscriptSwapMotion` moves it.
@MainActor
protocol TranscriptSwapStage: AnyObject {
    /// Another chat's rows were drawn in this pass of the main thread.
    var conversationJustChanged: Bool { get }
    /// The rows on screen leave, and stay away until `slideIn` or
    /// `comeBack`.
    func slideOut(_ swap: BotChatSwap)
    /// The rows now drawn come in from their side.
    func slideIn(_ swap: BotChatSwap)
    /// Rows that left show again where they were: their chat is still the
    /// open one.
    func comeBack()
}

private struct TranscriptSwapMotionKey: EnvironmentKey {
    static let defaultValue: TranscriptSwapMotion? = nil
}

extension EnvironmentValues {
    /// Set by a screen whose chats slide over one another in place.
    var transcriptSwapMotion: TranscriptSwapMotion? {
        get { self[TranscriptSwapMotionKey.self] }
        set { self[TranscriptSwapMotionKey.self] = newValue }
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
        group.duration = 0.2
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        // Away until the new rows come in, or these come back.
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        return group
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
