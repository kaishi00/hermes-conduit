//
//  ChatBackSwipe.swift
//  Conduit
//
//  The chat's own swipe back: a Bot Chat or room grown from its portrait
//  goes home, and a workstream goes to its Bot Chat, by a swipe from
//  anywhere on the chat (`V2ConversationScreen.swipesBack`). It runs beside
//  the transcript's scroll and the text selection's own drags, so it is
//  decided from how the drag starts and what it went through, not only
//  from where it ends, and the chat follows the finger while it can still
//  be let go (issue 3378).
//

import SwiftUI

/// One drag, as the swipe back reads it.
struct BackSwipeDrag: Equatable {
    /// Whether the drag's first movement, past the gesture's 20 pt, went
    /// toward the trailing edge and mostly sideways: nil until it moves. A
    /// drag that starts as a scroll stays one, whatever it drifts to (a
    /// scroll ending at (+100, +55) read as a swipe back).
    private(set) var startedSideways: Bool?
    /// Something else had the drag at some point: a text selection showed
    /// or one of its handles was dragged, it began on something that
    /// scrolls sideways, or the swipe was off. Asked only at the end, a
    /// handle let go could read as no selection on that same touch-up and
    /// close the chat (issue 1948's path that #1953 missed).
    private(set) var held = false

    mutating func moved(_ translation: CGSize, held heldNow: Bool) {
        if startedSideways == nil { startedSideways = Self.startsSideways(translation) }
        if heldNow { held = true }
    }

    /// The swipe is still the drag's: the chat follows the finger.
    var follows: Bool { startedSideways == true && !held }

    /// How far the chat moves with the finger, toward the trailing edge.
    func shift(for translation: CGSize) -> CGFloat {
        follows ? max(0, translation.width) : 0
    }

    /// Let go at `translation`, the drag goes back.
    func goesBack(_ translation: CGSize) -> Bool {
        follows && BotChatSwap.isBackSwipe(translation)
    }

    /// A first movement toward the trailing edge, within 45° of level.
    static func startsSideways(_ translation: CGSize) -> Bool {
        translation.width > 0 && abs(translation.height) < translation.width
    }
}

/// The swipe in progress and how far the chat has followed it. Held by the
/// screen as a reference, so a drag's frames redraw only what moves
/// (`ChatBackSwipeFollow`), not the whole screen.
@MainActor
final class ChatBackSwipe: ObservableObject {
    @Published private(set) var shift: CGFloat = 0
    private var drag = BackSwipeDrag()
    private var dragStart: CGPoint?

    func moved(_ value: DragGesture.Value, held: Bool) {
        moved(from: value.startLocation, by: value.translation, held: held)
    }

    func moved(from start: CGPoint, by translation: CGSize, held: Bool) {
        // A drag the system took (never ended) leaves its state behind:
        // a new start point is a new drag.
        if start != dragStart {
            drag = BackSwipeDrag()
            dragStart = start
        }
        drag.moved(translation, held: held)
        let shift = drag.shift(for: translation)
        if shift != self.shift { self.shift = shift }
    }

    /// The drag ended at `value`: whether it goes back. The chat goes
    /// back to its place either way; going back slides or zooms it on
    /// from there.
    func ended(_ value: DragGesture.Value, held: Bool, reduceMotion: Bool) -> Bool {
        ended(from: value.startLocation, at: value.translation, held: held, reduceMotion: reduceMotion)
    }

    func ended(from start: CGPoint, at translation: CGSize, held: Bool, reduceMotion: Bool) -> Bool {
        if start != dragStart { drag = BackSwipeDrag() }
        drag.moved(translation, held: held)
        let goesBack = drag.goesBack(translation)
        release(reduceMotion: reduceMotion)
        return goesBack
    }

    /// The drag is over, ended or taken by the system.
    func release(reduceMotion: Bool) {
        drag = BackSwipeDrag()
        dragStart = nil
        guard shift != 0 else { return }
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { shift = 0 }
    }
}

/// Moves the chat with the finger while its swipe back is the drag's.
struct ChatBackSwipeFollow: ViewModifier {
    @ObservedObject var swipe: ChatBackSwipe

    func body(content: Content) -> some View {
        content.offset(x: swipe.shift)
    }
}

/// The swipe back on the chat's column, beside the transcript's scroll and
/// the selection's drags.
struct ChatBackSwipeGesture: ViewModifier {
    /// The chat goes back by this swipe (`V2ConversationScreen.swipesBack`).
    let enabled: Bool
    let swipe: ChatBackSwipe
    let reduceMotion: Bool
    /// Whether something else has the drag now (a selection, a sideways
    /// scroller, the swipe turned off).
    let held: () -> Bool
    let goBack: () -> Void
    @GestureState private var dragging = false

    func body(content: Content) -> some View {
        content
            // The chat's column only: a drag in a panel beside it
            // (Artifacts, its divider, the Work panel's swipes) is that
            // panel's.
            .simultaneousGesture(gesture, including: enabled ? .all : .subviews)
            .onChange(of: dragging) { _, now in
                if !now { swipe.release(reduceMotion: reduceMotion) }
            }
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { swipe.moved($0, held: held()) }
            .onEnded { value in
                if swipe.ended(value, held: held(), reduceMotion: reduceMotion) { goBack() }
            }
    }
}
