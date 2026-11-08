//
//  TransientReadRetry.swift
//  Conduit
//
//  A read whose failure shows a notice (Bots Home's Group Chats probe, the
//  bot roster) asks again a few times on its own, 2, 4, 8 and 16 s apart, so
//  the notice clears once Hermes answers, even when the app never saw the
//  connection drop (a socket that came back by itself). A success resets it.
//

import Foundation

@MainActor
struct TransientReadRetry {
    /// Seconds before each retry; none after the last.
    static let delays: [Double] = [2, 4, 8, 16]

    private(set) var attempts = 0
    private var task: Task<Void, Never>?

    /// The read answered, or a new server or dashboard starts over: the
    /// next failure starts the delays again.
    mutating func succeeded() {
        attempts = 0
        task?.cancel()
        task = nil
    }

    /// Asks again after the next delay, once one is left. A retry already
    /// waiting is replaced, so failures never stack.
    mutating func schedule(_ retry: @escaping @MainActor () async -> Void) {
        guard let delay = Self.delay(after: attempts) else { return }
        attempts += 1
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            // In a task of its own: the read's success resets this retry,
            // which cancels the waiting task, and the rest of the read (the
            // room list after the probe) must not run cancelled.
            Task { @MainActor in await retry() }
        }
    }

    static func delay(after attempts: Int) -> Double? {
        attempts < delays.count ? delays[attempts] : nil
    }
}
