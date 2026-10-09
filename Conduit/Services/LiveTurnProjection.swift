//
//  LiveTurnProjection.swift
//  Conduit
//
//  The running turn's live tail, published apart from AppState.
//

import Combine

/// What a running turn shows while it streams: the reply text so far and the
/// open thinking card. Both change at display cadence (about 20 to 30 times a
/// second for as long as a turn streams), so they publish here and never on
/// AppState. Every view that observes AppState, including the root view of
/// each sheet, re-renders on any AppState publish; a publish here re-renders
/// only the chat's live rows (`ChatLiveTurnRows`).
///
/// AppState owns the one instance and is its only writer (`streamingText`
/// and `liveReasoningSegment` forward here); the coalescing and settling
/// rules stay in AppState.
@MainActor
final class LiveTurnProjection: ObservableObject {
    @Published var streamingText = ""
    @Published var reasoningSegment: AppState.LiveReasoningSegment?
}
