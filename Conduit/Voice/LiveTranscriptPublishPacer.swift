//
//  LiveTranscriptPublishPacer.swift
//  Conduit
//
//  A live call's transcript grows a word at a time, several times a
//  second from each side. Publishing every word re-rendered the whole call
//  screen (and the minimised bar while browsing chats), and its merged
//  timeline, per word (issue 1960). The pacer publishes a line added or
//  removed at once, and a line that only grew at most every `spacing`,
//  with a trailing publish so the last words always show.
//

import Combine
import Foundation

@MainActor
final class LiveTranscriptPublishPacer {
    /// Ten updates a second: captions still read as live, and nobody reads
    /// faster than that.
    static let spacing: TimeInterval = 0.1

    /// Fires after the transcript changes, at the pace it publishes.
    let changes = PassthroughSubject<Void, Never>()

    private let publish: @MainActor () -> Void
    private let now: () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var publishedCount = 0
    private var lastPublish: Date?
    private var pending: Task<Void, Never>?

    /// `publish` tells observers (the owner's `objectWillChange`).
    init(
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        publish: @escaping @MainActor () -> Void
    ) {
        self.now = now
        self.sleep = sleep
        self.publish = publish
    }

    /// Called after every change to the transcript, with its new length.
    func changed(count: Int) {
        let at = now()
        if count != publishedCount || lastPublish.map({ at.timeIntervalSince($0) >= Self.spacing }) ?? true {
            fire(count: count, at: at)
            return
        }
        guard pending == nil else { return }
        let wait = Self.spacing - at.timeIntervalSince(lastPublish ?? at)
        let sleep = sleep
        pending = Task { [weak self] in
            await sleep(max(wait, 0))
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.fire(count: self.publishedCount, at: self.now())
        }
    }

    private func fire(count: Int, at: Date) {
        pending?.cancel()
        pending = nil
        publishedCount = count
        lastPublish = at
        publish()
        changes.send()
    }
}
