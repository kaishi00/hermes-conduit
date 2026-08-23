import Foundation

// MARK: - V3D live-event socket abstraction
//
// The smallest useful transport boundary: production wraps a
// URLSessionWebSocketTask; deterministic tests supply scripted sockets. This
// is NOT a generic networking framework - it exists only so the stream loop,
// cursor, backoff, and cancellation can be tested without real I/O.

enum KanbanEventSocketMessage {
    case text(String)
    case data(Data)

    var decodedFrame: KanbanEventFrame? {
        switch self {
        case .text(let string):
            return try? JSONDecoder().decode(KanbanEventFrame.self, from: Data(string.utf8))
        case .data(let data):
            return try? JSONDecoder().decode(KanbanEventFrame.self, from: data)
        }
    }
}

@MainActor
protocol KanbanEventSocket: AnyObject {
    func receive() async throws -> KanbanEventSocketMessage
    func ping() async throws
    /// Cancellation is final: production cancels with .goingAway.
    func cancel()
}

/// Production adapter over URLSessionWebSocketTask.
final class URLSessionKanbanEventSocket: KanbanEventSocket {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func receive() async throws -> KanbanEventSocketMessage {
        let message = try await task.receive()
        switch message {
        case .string(let string): return .text(string)
        case .data(let data): return .data(data)
        @unknown default: return .text("")
        }
    }

    func ping() async throws {
        // Confirms the authenticated upgrade before treating the connection
        // as established (resets reconnect backoff).
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing(pongReceiveHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

// MARK: - Invalidation batch

/// One coalesced invalidation batch. revision strictly increases per
/// publication; context binds it to the exact board/server snapshot that may
/// act on it.
struct KanbanEventInvalidation: Equatable {
    let revision: Int
    let context: KanbanBoardContextStamp
    let taskIDs: Set<String>
    let boardInvalidated: Bool
}

/// What the batch handler asked the stream to do next.
enum KanbanEventBatchOutcome {
    /// Refresh completed - the batch is fully handled.
    case completed
    /// Store was busy/loading - retry the SAME batch once after a short delay.
    case retrySoon
    /// Context no longer matches - drop the batch permanently.
    case discard
}

// MARK: - Live update policy (pure helpers)

enum KanbanLiveUpdatePolicy {
    /// Fixed trailing coalescing window: the FIRST event starts one short
    /// timer; later events only merge into the pending batch (no debounce
    /// starvation under continuous traffic).
    static let coalescingWindowNanoseconds: UInt64 = 300_000_000
    /// A deferred batch (store busy/loading) retries ONCE after this delay;
    /// if still busy it is dropped - the ordinary poll converges anyway.
    static let deferredRetryNanoseconds: UInt64 = 750_000_000
    /// Bounded reconnect backoff, capped at the last entry.
    static let reconnectBackoffNanoseconds: [UInt64] = [
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
        15_000_000_000,
    ]

    static func reconnectDelayNanoseconds(consecutiveFailures: Int) -> UInt64 {
        guard !reconnectBackoffNanoseconds.isEmpty else { return 0 }
        let index = max(0, consecutiveFailures)
        return reconnectBackoffNanoseconds[min(index, reconnectBackoffNanoseconds.count - 1)]
    }

    /// An integer watermark >= 0 from the authoritative REST snapshot is
    /// required to open a stream. nil/malformed/negative -> live events are
    /// unavailable for this snapshot and polling continues alone (never guess
    /// a historical cursor and never replay the whole table).
    static func isValidInitialWatermark(_ value: Int?) -> Bool {
        guard let value else { return false }
        return value >= 0
    }
}

// MARK: - Stream coordinator

/// Owns ONE live /events subscription for ONE immutable context:
/// ticket minting (a FRESH single-use ticket per connect), URL construction,
/// socket lifecycle, the monotonic cursor, bounded reconnect backoff, event
/// coalescing, and final cancellation. It holds NO board/task cache and
/// performs NO mutations - every batch is handed to onBatch, whose handler
/// drives the authoritative store reload (REST stays canonical).
@MainActor
final class KanbanEventStreamCoordinator {
    struct Configuration {
        let stamp: KanbanBoardContextStamp
        let boardSlug: String
        /// REQUIRED valid integer watermark from the authoritative snapshot
        /// (the view glue refuses to start the stream without one).
        let initialCursor: Int
        let baseURL: String
    }

    typealias SocketFactory = @MainActor (URL) async throws -> KanbanEventSocket
    typealias TicketMinter = @MainActor () async throws -> String
    typealias Sleeper = @MainActor (UInt64) async throws -> Void
    typealias BatchHandler = @MainActor (KanbanEventInvalidation) async -> KanbanEventBatchOutcome

    private let configuration: Configuration
    private let socketFactory: SocketFactory
    private let ticketMinter: TicketMinter
    private let sleeper: Sleeper
    private let coalescingWindowNanoseconds: UInt64
    private let deferredRetryNanoseconds: UInt64
    private let onBatch: BatchHandler

    /// Diagnostics/assertion surface for tests (capped - URLs embed tickets).
    private(set) var issuedURLs: [URL] = []
    private(set) var mintedTickets: [String] = []
    private(set) var recordedBackoffs: [UInt64] = []
    private(set) var cancelledSockets = 0
    private(set) var pingFailures = 0
    private(set) var cursor: Int

    private func recordDiagnostic(_ append: () -> Void) {
        append()
        if issuedURLs.count > 50 { issuedURLs.removeFirst(issuedURLs.count - 50) }
        if mintedTickets.count > 50 { mintedTickets.removeFirst(mintedTickets.count - 50) }
        if recordedBackoffs.count > 50 { recordedBackoffs.removeFirst(recordedBackoffs.count - 50) }
    }

    private var runID = 0
    private var loopTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var currentSocket: KanbanEventSocket?
    private var pendingTaskIDs: Set<String> = []
    private var pendingBoardInvalidation = false
    private var consecutiveFailures = 0
    private var revisionCounter = 0

    init(
        configuration: Configuration,
        socketFactory: @escaping SocketFactory,
        ticketMinter: @escaping TicketMinter,
        sleeper: @escaping Sleeper,
        coalescingWindowNanoseconds: UInt64 = KanbanLiveUpdatePolicy.coalescingWindowNanoseconds,
        deferredRetryNanoseconds: UInt64 = KanbanLiveUpdatePolicy.deferredRetryNanoseconds,
        onBatch: @escaping BatchHandler
    ) {
        self.configuration = configuration
        self.socketFactory = socketFactory
        self.ticketMinter = ticketMinter
        self.sleeper = sleeper
        self.coalescingWindowNanoseconds = coalescingWindowNanoseconds
        self.deferredRetryNanoseconds = deferredRetryNanoseconds
        self.onBatch = onBatch
        cursor = configuration.initialCursor
    }

    var isRunning: Bool { loopTask != nil }

    /// Starts the receive/reconnect loop. Idempotent while running.
    func start() {
        guard loopTask == nil else { return }
        runID += 1
        consecutiveFailures = 0
        let myRun = runID
        loopTask = Task { [weak self] in
            await self?.runLoop(myRun)
        }
    }

    /// Starts the stream and suspends until this generation is retired
    /// (stop(), cancellation, or replacement). The view awaits THIS.
    func run() async {
        start()
        guard let task = loopTask else { return }
        await task.value
        // Retirement cleanup (socket .goingAway etc.) even on cancellation.
        stop()
    }

    /// Immediate, FINAL cancellation: the loop, any pending flush/backoff
    /// delay, and the current socket all die; nothing reconnects or reports
    /// after this. A later start() creates an entirely new generation.
    func stop() {
        runID += 1
        loopTask?.cancel()
        loopTask = nil
        flushTask?.cancel()
        flushTask = nil
        if let socket = currentSocket {
            socket.cancel()
            cancelledSockets += 1
            currentSocket = nil
        }
        pendingTaskIDs.removeAll()
        pendingBoardInvalidation = false
    }

    private func isCurrent(_ myRun: Int) -> Bool {
        !Task.isCancelled && myRun == runID
    }

    private func runLoop(_ myRun: Int) async {
        while isCurrent(myRun) {
            // 1. Fresh single-use ticket EVERY connect - never reuse one.
            let ticket: String
            do {
                ticket = try await ticketMinter()
            } catch {
                guard isCurrent(myRun) else { return }
                await backoff(myRun)
                continue
            }
            guard isCurrent(myRun) else { return }
            mintedTickets.append(ticket)
            if mintedTickets.count > 50 { mintedTickets.removeFirst(mintedTickets.count - 50) }

            // 2. Authenticated URL: concrete board + resume watermark.
            let url: URL?
            do {
                url = try ConnectionURLPolicy.webSocketURL(
                    baseURL: configuration.baseURL,
                    path: "/api/plugins/kanban/events",
                    queryItems: [
                        URLQueryItem(name: "ticket", value: ticket),
                        URLQueryItem(name: "board", value: configuration.boardSlug),
                        URLQueryItem(name: "since", value: String(cursor)),
                    ]
                )
            } catch {
                url = nil
            }
            guard let url else {
                await backoff(myRun)
                continue
            }
            issuedURLs.append(url)
            if issuedURLs.count > 50 { issuedURLs.removeFirst(issuedURLs.count - 50) }

            // 3. Connect.
            let socket: KanbanEventSocket
            do {
                socket = try await socketFactory(url)
            } catch {
                guard isCurrent(myRun) else { return }
                await backoff(myRun)
                continue
            }
            guard isCurrent(myRun) else {
                socket.cancel()
                cancelledSockets += 1
                return
            }
            currentSocket = socket

            // 4. Confirm the authenticated upgrade (optional ping); success
            // resets the reconnect backoff schedule.
            do {
                try await socket.ping()
                consecutiveFailures = 0
            } catch {
                // Ping failures are non-fatal: the receive loop decides.
            }

            // 5. Receive until failure/cancellation. A heartbeat ping loop
            // runs alongside: a silently-dead socket surfaces through ping
            // failure and feeds the normal backoff/reconnect path.
            let heartbeat = Task { [weak self] in
                await self?.heartbeatLoop(myRun, socket: socket)
            }
            defer { heartbeat.cancel() }
            do {
                while isCurrent(myRun) {
                    let message = try await socket.receive()
                    guard isCurrent(myRun) else { return }
                    ingest(message)
                }
            } catch {
                guard isCurrent(myRun) else { return }
            }

            // 6. Failure path: retire the socket, reconnect same context.
            socket.cancel()
            cancelledSockets += 1
            if currentSocket === socket { currentSocket = nil }
            await backoff(myRun)
        }
    }

    /// Periodic liveness ping while connected (review W2): a silently-dead
    /// socket surfaces through ping failure and feeds the normal
    /// backoff/reconnect path. Failures are counted diagnostically.
    private func heartbeatLoop(_ myRun: Int, socket: KanbanEventSocket) async {
        let heartbeatNanoseconds: UInt64 = 20_000_000_000
        while isCurrent(myRun) && currentSocket === socket {
            do {
                try await sleeper(heartbeatNanoseconds)
            } catch {
                return
            }
            guard isCurrent(myRun) && currentSocket === socket else { return }
            do {
                try await socket.ping()
            } catch {
                pingFailures += 1
                socket.cancel()
                return   // receive loop observes the close and reconnects
            }
        }
    }

    private func backoff(_ myRun: Int) async {
        let delay = KanbanLiveUpdatePolicy.reconnectDelayNanoseconds(consecutiveFailures: consecutiveFailures)
        recordedBackoffs.append(delay)
        if recordedBackoffs.count > 50 { recordedBackoffs.removeFirst(recordedBackoffs.count - 50) }
        if recordedBackoffs.count > 50 { recordedBackoffs.removeFirst(recordedBackoffs.count - 50) }
        consecutiveFailures += 1
        do {
            try await sleeper(delay)
        } catch {
            // Cancelled during backoff: ownership re-check exits the loop.
        }
        // Guarantee the actor breathes even when tests inject
        // non-suspending sleepers - a failing minter must never become a
        // non-suspending spin loop that starves the MainActor.
        await Task.yield()
    }

    // MARK: Frame ingestion + coalescing

    /// TEST-ONLY: feed a raw text frame into the ingestion pipeline exactly
    /// as a receive() completion would.
    func injectForTesting(text: String) {
        ingest(.text(text))
    }

    private func ingest(_ message: KanbanEventSocketMessage) {
        // Malformed JSON frames are ignored; the socket loop continues.
        guard let frame = message.decodedFrame else { return }
        // Cursor advances monotonically - never backwards.
        if let frameCursor = frame.cursor, frameCursor > cursor {
            cursor = frameCursor
        }
        guard !frame.events.isEmpty else { return }
        let ids = Set(frame.events.compactMap(\.taskID).filter { !$0.isEmpty })
        pendingTaskIDs.formUnion(ids)
        pendingBoardInvalidation = true
        scheduleFlushIfIdle()
    }

    private func scheduleFlushIfIdle() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.flushAfterWindow()
        }
    }

    private func flushAfterWindow() async {
        do {
            try await sleeper(coalescingWindowNanoseconds)
        } catch {
            return
        }
        await flushNow()
    }

    /// Snapshot + clear the pending batch and hand it to the handler; a
    /// .retrySoon outcome re-runs the SAME batch once after a short delay;
    /// events arriving during handling start their own follow-up flush.
    private func flushNow() async {
        flushTask = nil
        let ids = pendingTaskIDs
        let boardInvalidated = pendingBoardInvalidation
        pendingTaskIDs.removeAll()
        pendingBoardInvalidation = false
        guard boardInvalidated || !ids.isEmpty else { return }
        revisionCounter += 1
        let invalidation = KanbanEventInvalidation(
            revision: revisionCounter,
            context: configuration.stamp,
            taskIDs: ids,
            boardInvalidated: boardInvalidated
        )
        let outcome = await onBatch(invalidation)
        if outcome == .retrySoon {
            // Re-merge the batch into pending with a FRESH revision: the
            // store was busy/loading, so the invalidation must not be lost
            // NOR published out of revision order relative to a follow-up
            // batch that completed first.
            pendingTaskIDs.formUnion(ids)
            pendingBoardInvalidation = pendingBoardInvalidation || boardInvalidated
            scheduleFlushIfIdle()
        }
    }
}