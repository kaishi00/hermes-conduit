//
//  StartupReads.swift
//  Conduit
//
//  The reads a connection always makes, sent as it starts.
//
//  A launch or a return used to send the profile list once the socket was
//  open, the chat list after that, and the display settings after the chat
//  was resumed: each waited for the one before, though none needs the
//  socket. They go out now with the ticket, and each step takes its answer
//  when it gets there, so on a slow link they cost one round trip together.
//

import Foundation

@MainActor
final class StartupReads {
    /// What the early answers were read under. A step takes one only while
    /// nothing has changed since it was sent: no write through the
    /// dashboard, no change to the chat list, no display setting saved.
    struct Fence: Equatable {
        let writes: Int
        let catalog: UInt64
        let display: Int
    }

    /// An answer, carried from the early read to the step that takes it.
    /// Unchecked because `[String: Any]` isn't Sendable; it never leaves the
    /// main actor, which both the read and the step run on.
    struct Answer: @unchecked Sendable { let json: [String: Any] }

    /// How long an early answer may wait for its step. A connection's steps
    /// reach theirs within seconds; past this the answer is too old to show.
    static let lifetime: TimeInterval = 20

    private struct Entry {
        let task: Task<Answer, Error>
        let fence: Fence
        let sentAt: Date
    }

    private weak var bridge: DashboardTicketBridge?
    private var entries: [String: Entry] = [:]
    /// The last reads sent, so the connect after a ticket mint doesn't send
    /// the same ones again.
    private var lastSent: (paths: [String], at: Date)?
    /// How soon the same reads through the same bridge count as already sent.
    static let resendAfter: TimeInterval = 10

    /// Sends `paths` now through `bridge`, in place of any early reads still
    /// waiting from an earlier connection. The same reads sent through the
    /// same bridge moments ago aren't sent again.
    func send(_ paths: [String], through bridge: DashboardTicketBridge, fence: Fence, now: Date = Date()) {
        if self.bridge === bridge, let lastSent, lastSent.paths == paths,
           now.timeIntervalSince(lastSent.at) < Self.resendAfter {
            return
        }
        cancelWaiting()
        self.bridge = bridge
        lastSent = (paths, now)
        for path in paths where entries[path] == nil {
            // Never through the page: an early read doesn't wait for it or
            // load it. One that can't go out without it is sent again by its
            // step, the usual way.
            let task = Task { @MainActor in Answer(json: try await bridge.readWithoutPage(path: path)) }
            entries[path] = Entry(task: task, fence: fence, sentAt: now)
        }
    }

    /// The early read of `path`, taken once, or nil when there is none this
    /// step may use: none sent, sent through another bridge, sent before a
    /// change (`fence`), or too old.
    func take(_ path: String, through bridge: DashboardTicketBridge, fence: Fence, now: Date = Date()) -> Task<Answer, Error>? {
        guard let entry = entries.removeValue(forKey: path),
              self.bridge === bridge,
              entry.fence == fence,
              now.timeIntervalSince(entry.sentAt) < Self.lifetime else { return nil }
        return entry.task
    }

    /// Paths still waiting to be taken. Readable for tests.
    var waitingPaths: Set<String> { Set(entries.keys) }

    /// Drops every early read, cancelling those still out: a dashboard
    /// switch or sign-out leaves nothing for its steps.
    func clear() {
        cancelWaiting()
        bridge = nil
        lastSent = nil
    }

    private func cancelWaiting() {
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
    }
}

extension StartupReads {
    /// `path` through `bridge`: the early read's answer when this step may
    /// take it, else a read of its own. An early read that couldn't go out
    /// without the page (no session cookie yet) or was refused as signed out
    /// is sent again, the step's way; any other failure is
    /// this step's, since sending the same read again moments later would
    /// only wait for it twice.
    func read(_ path: String, through bridge: DashboardTicketBridge, fence: Fence) async throws -> [String: Any] {
        guard let early = take(path, through: bridge, fence: fence) else {
            return try await bridge.requestJSON(path: path)
        }
        do {
            return try await early.value.json
        } catch DashboardTicketBridgeError.notReady {
            return try await bridge.requestJSON(path: path)
        } catch DashboardTicketBridgeError.signInRequired {
            // The step's own read can go through the page, whose landing
            // decides whether the session really ended.
            return try await bridge.requestJSON(path: path)
        }
    }
}
