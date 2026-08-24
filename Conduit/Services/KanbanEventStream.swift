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
    /// Cancellation-AWARE: if the awaiting task is cancelled (liveness
    /// timeout lost the race), ping must resume throwing promptly instead of
    /// hanging until URLSession/TCP eventually resolves.
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

    /// Exactly-once continuation shared between the pong callback, socket
    /// cancellation, and owner-task cancellation: whichever arrives first
    /// claims the single resume.
    func ping() async throws {
        let gate = PingContinuationGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.register(continuation)
                task.sendPing(pongReceiveHandler: { [gate] error in
                    Task { @MainActor in
                        if let error {
                            gate.resumeIfPending(.failure(error))
                        } else {
                            gate.resumeIfPending(.success(()))
                        }
                    }
                })
            }
        } onCancel: {
            Task { @MainActor in
                gate.resumeIfPending(.failure(CancellationError()))
            }
        }
    }

    func cancel() {
        // Cancels the underlying task, which also fails any registered ping
        // continuation through URLSession's own callback path.
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Single-resume gate for one ping attempt. Cancellation and pong callbacks
/// hop through Task { @MainActor }, so a result can race AHEAD of register():
/// the gate remembers that early result and consumes it at registration -
/// exactly once.
@MainActor
final class PingContinuationGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var resumed = false
    private var pendingResult: Result<Void, Error>?

    func register(_ continuation: CheckedContinuation<Void, Error>) {
        if let pendingResult {
            self.pendingResult = nil
            resumed = true
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
    }

    func resumeIfPending(_ result: Result<Void, Error>) {
        guard !resumed else { return }
        guard let continuation else {
            // No continuation registered yet: remember the FIRST early result
            // so register() delivers it; later attempts stay ignored.
            if pendingResult == nil {
                pendingResult = result
            }
            return
        }
        resumed = true
        self.continuation = nil
        continuation.resume(with: result)
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
    /// Liveness heartbeat cadence while connected.
    static let heartbeatIntervalNanoseconds: UInt64 = 20_000_000_000
    /// Upper bound on how long a liveness ping may stay unanswered before
    /// the socket is retired (bounds dead-peer detection).
    static let pingTimeoutNanoseconds: UInt64 = 10_000_000_000

    /// The bounded-ping primitive: races the socket's ping against a timeout
    /// sleeper. The socket's ping MUST be cancellation-aware (resume throwing
    /// on cancellation) so the losing child unwinds promptly and the group
    /// cannot be held open by a parked pong.
    static func pingBounded(
        socket: KanbanEventSocket,
        timeoutNanoseconds: UInt64,
        sleep: @escaping @MainActor (UInt64) async throws -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await socket.ping()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                do {
                    try await sleep(timeoutNanoseconds)
                    return false
                } catch {
                    return false
                }
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

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
///
/// OWNERSHIP (V3D correction pass): every piece of asynchronous work belongs
/// to exactly ONE tracked handle - loopTask, heartbeatTask, batchTask - plus
/// currentSocket. stop() cancels ALL of them, so a retired generation can
/// never complete a refresh/publication/retry/reconnect after retirement.
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
    typealias BatchHandler = @MainActor (KanbanEventInvalidation) async throws -> KanbanEventBatchOutcome

    private let configuration: Configuration
    private let socketFactory: SocketFactory
    private let ticketMinter: TicketMinter
    private let sleeper: Sleeper
    private let coalescingWindowNanoseconds: UInt64
    private let deferredRetryNanoseconds: UInt64
    /// Dedicated REAL-time sleep for the heartbeat cadence - deliberately
    /// separate from the injected test sleeper so test timing can never
    /// accelerate heartbeats into hot loops.
    private let heartbeatIntervalNanoseconds: UInt64
    private let heartbeatSleeper: @MainActor (UInt64) async throws -> Void
    private let onBatch: BatchHandler

    /// Diagnostics/assertion surface for tests (capped - URLs embed tickets).
    private(set) var issuedURLs: [URL] = []
    private(set) var mintedTickets: [String] = []
    private(set) var recordedBackoffs: [UInt64] = []
    private(set) var cancelledSockets = 0
    private(set) var pingFailures = 0
    private(set) var cursor: Int

    private var runID = 0
    private var loopTask: Task<Void, Never>?
    private var batchRunID = 0
    private var batchTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var currentSocket: (socket: KanbanEventSocket, run: Int)?
    private var pendingTaskIDs: Set<String> = []
    private var pendingBoardInvalidation = false
    private var consecutiveFailures = 0
    private var revisionCounter = 0

    /// Bounded-liveness primitive used for connect-time confirmation and
    /// heartbeats. Production races the ping against a REAL Task.sleep
    /// timeout (never the injected test sleeper), so dead-peer detection is
    /// genuinely bounded and test sleepers cannot skew the race.
    typealias Pinger = @MainActor (KanbanEventSocket) async -> Bool

    init(
        configuration: Configuration,
        socketFactory: @escaping SocketFactory,
        ticketMinter: @escaping TicketMinter,
        sleeper: @escaping Sleeper,
        coalescingWindowNanoseconds: UInt64 = KanbanLiveUpdatePolicy.coalescingWindowNanoseconds,
        deferredRetryNanoseconds: UInt64 = KanbanLiveUpdatePolicy.deferredRetryNanoseconds,
        heartbeatIntervalNanoseconds: UInt64 = KanbanLiveUpdatePolicy.heartbeatIntervalNanoseconds,
        pingTimeoutNanoseconds: UInt64 = KanbanLiveUpdatePolicy.pingTimeoutNanoseconds,
        pinger: Pinger? = nil,
        onBatch: @escaping BatchHandler
    ) {
        self.configuration = configuration
        self.socketFactory = socketFactory
        self.ticketMinter = ticketMinter
        self.sleeper = sleeper
        self.coalescingWindowNanoseconds = coalescingWindowNanoseconds
        self.deferredRetryNanoseconds = deferredRetryNanoseconds
        self.heartbeatIntervalNanoseconds = heartbeatIntervalNanoseconds
        self.heartbeatSleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        self.onBatch = onBatch
        let timeout = pingTimeoutNanoseconds
        self.pinger = pinger ?? { socket in
            await KanbanLiveUpdatePolicy.pingBounded(
                socket: socket,
                timeoutNanoseconds: timeout,
                sleep: { nanoseconds in
                    try await Task.sleep(nanoseconds: nanoseconds)
                }
            )
        }
        cursor = configuration.initialCursor
    }

    private let pinger: Pinger

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
    /// (stop(), OWNING-TASK CANCELLATION, or replacement). The view awaits
    /// THIS. The unstructured loopTask does not observe the owner's
    /// cancellation by itself, so the boundary lives HERE: cancelling the
    /// awaiting task retires the socket/loop/batch/heartbeat immediately and
    /// finally.
    func run() async {
        start()
        await withTaskCancellationHandler {
            guard let task = loopTask else { return }
            await task.value
            // Retirement cleanup even on natural exit.
            retireGeneration()
        } onCancel: {
            // Delivered off the actor: hop back. retireGeneration() is
            // idempotent/FINAL.
            Task { @MainActor [weak self] in
                self?.retireGeneration()
            }
        }
    }

    /// Immediate, FINAL retirement of this generation: loop, heartbeat,
    /// in-flight batch (window/handler/deferred-retry), and the current
    /// socket all die; nothing reconnects, refreshes, publishes, or reports
    /// afterwards. Idempotent.
    func stop() {
        retireGeneration()
    }

    private func retireGeneration() {
        runID += 1
        batchRunID += 1
        loopTask?.cancel()
        loopTask = nil
        batchTask?.cancel()
        batchTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let current = currentSocket {
            current.socket.cancel()
            cancelledSockets += 1
            currentSocket = nil
        }
        pendingTaskIDs.removeAll()
        pendingBoardInvalidation = false
    }

    private func isCurrent(_ myRun: Int) -> Bool {
        !Task.isCancelled && myRun == runID
    }

    private func recordBackoff(_ delay: UInt64) {
        recordedBackoffs.append(delay)
        if recordedBackoffs.count > 50 { recordedBackoffs.removeFirst(recordedBackoffs.count - 50) }
    }

    private func retireConnection(_ socket: KanbanEventSocket) {
        if currentSocket?.socket === socket {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
        socket.cancel()
        cancelledSockets += 1
        if currentSocket?.socket === socket { currentSocket = nil }
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
            currentSocket = (socket, myRun)

            // 4. BOUNDED upgrade confirmation: a silent peer must fail within
            // the ping timeout and flow through normal retirement + backoff -
            // never into receive on a dead socket.
            let confirmed = await pinger(socket)
            guard isCurrent(myRun) else {
                retireConnection(socket)
                return
            }
            if !confirmed {
                pingFailures += 1
                retireConnection(socket)
                await backoff(myRun)
                continue
            }
            consecutiveFailures = 0

            // 5. Heartbeat + receive until failure/cancellation.
            heartbeatTask = Task { [weak self] in
                await self?.heartbeatLoop(myRun, socket: socket)
            }
            do {
                while isCurrent(myRun) {
                    let message = try await socket.receive()
                    guard isCurrent(myRun) else {
                        retireConnection(socket)
                        return
                    }
                    ingest(message, myRun: myRun)
                }
            } catch {
                guard isCurrent(myRun) else { return }
            }

            // 6. Failure path: retire the connection, reconnect same context.
            retireConnection(socket)
            await backoff(myRun)
        }
    }

    /// Liveness ping cadence + bounded dead-peer detection while connected.
    private func heartbeatLoop(_ myRun: Int, socket: KanbanEventSocket) async {
        while isCurrent(myRun) && currentSocket?.socket === socket {
            do {
                try await heartbeatSleeper(heartbeatIntervalNanoseconds)
            } catch {
                return
            }
            guard isCurrent(myRun) && currentSocket?.socket === socket else { return }
            let alive = await pinger(socket)
            guard isCurrent(myRun) && currentSocket?.socket === socket else { return }
            if !alive {
                pingFailures += 1
                retireConnection(socket)
                return   // receive loop observes the close and reconnects
            }
        }
    }

    private func backoff(_ myRun: Int) async {
        let delay = KanbanLiveUpdatePolicy.reconnectDelayNanoseconds(consecutiveFailures: consecutiveFailures)
        recordedBackoffs.append(delay)
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

    private func ingest(_ message: KanbanEventSocketMessage, myRun: Int) {
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
        scheduleFlushIfIdle(myRun)
    }

    private func scheduleFlushIfIdle(_ myRun: Int) {
        guard batchTask == nil else { return }
        batchRunID += 1
        let myBatch = batchRunID
        batchTask = Task { [weak self] in
            await self?.runBatchLifecycle(myRun, batchRun: myBatch)
        }
    }

    /// The FULL batch lifecycle owned by one tracked task: coalescing window,
    /// handler invocation, and (once) the deferred-retry delay. Every await
    /// re-proves both stream ownership AND batch ownership, so a retired
    /// generation can publish nothing after its retirement point.
    private func runBatchLifecycle(_ myRun: Int, batchRun: Int) async {
        // Ownership-safe teardown: clear the handle ONLY if THIS lifecycle
        // still owns it. A cancelled old-generation lifecycle can unwind LATE
        // - after a restarted coordinator already scheduled its own batchTask
        // - and must never clear that newer handle.
        defer {
            if batchRun == batchRunID {
                batchTask = nil
            }
        }
        do {
            try await sleeper(coalescingWindowNanoseconds)
        } catch {
            return
        }
        // Outer loop: pick up events that arrived DURING a previous attempt's
        // handler (they merged into pending). Each pass runs at most one
        // deferred retry, then re-checks for fresh arrivals.
        while !Task.isCancelled, myRun == runID, batchRun == batchRunID {
            var ids = pendingTaskIDs
            var boardInvalidated = pendingBoardInvalidation
            pendingTaskIDs.removeAll()
            pendingBoardInvalidation = false
            guard boardInvalidated || !ids.isEmpty else { return }
            var deferredRetryAvailable = true
            while boardInvalidated || !ids.isEmpty {
                guard isCurrent(myRun), !Task.isCancelled, batchRun == batchRunID else { return }
                revisionCounter += 1
                let invalidation = KanbanEventInvalidation(
                    revision: revisionCounter,
                    context: configuration.stamp,
                    taskIDs: ids,
                    boardInvalidated: boardInvalidated
                )
                let outcome: KanbanEventBatchOutcome
                do {
                    outcome = try await onBatch(invalidation)
                } catch is CancellationError {
                    return   // retired mid-handler: nothing further
                } catch {
                    return   // handler failure: drop the batch, poll converges
                }
                guard isCurrent(myRun), !Task.isCancelled, batchRun == batchRunID else { return }
                if outcome != .retrySoon { break }
                guard deferredRetryAvailable else {
                    // Still busy after the one retry - drop; polling converges.
                    break
                }
                deferredRetryAvailable = false
                do {
                    try await sleeper(deferredRetryNanoseconds)
                } catch {
                    return
                }
                // Fold anything newly pending into the retry batch.
                ids.formUnion(pendingTaskIDs)
                pendingTaskIDs.removeAll()
                boardInvalidated = boardInvalidated || pendingBoardInvalidation
                pendingBoardInvalidation = false
            }
            // Events arriving during the last handler call merged into
            // pending; the next outer-loop pass picks them up via its own
            // snapshot. No redundant re-read/clear needed here.
        }
    }

    // MARK: Test-only ingestion surface

    /// TEST-ONLY: feed a raw text frame into the ingestion pipeline exactly
    /// as a receive() completion would.
    func injectForTesting(text: String) {
        ingest(.text(text), myRun: runID)
    }
}