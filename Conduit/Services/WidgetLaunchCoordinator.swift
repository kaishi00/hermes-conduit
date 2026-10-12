import Foundation

enum WidgetLaunchOutcome: Equatable {
    case handled
    case deferred
    case failed(String)
}

/// Ownership for one delivered widget action. The coordinator supplies the
/// generation/deadline predicate; the AppState adapter can additionally bind
/// the exact selected workspace once that switch has completed.
@MainActor
final class WidgetLaunchLease {
    private let baseIsCurrent: () -> Bool
    private var targetIsCurrent: (() -> Bool)?
    private var captureConsumed = false
    private let consumeCapture: () -> Void
    private let failLaunch: (String) -> Void

    init(
        isCurrent: @escaping () -> Bool,
        captureDidStart: @escaping () -> Void = {},
        fail: @escaping (String) -> Void = { _ in }
    ) {
        baseIsCurrent = isCurrent
        consumeCapture = captureDidStart
        failLaunch = fail
    }

    var isCurrent: Bool {
        captureConsumed || (baseIsCurrent() && (targetIsCurrent?() ?? true))
    }

    func bindTargetOwnership(_ check: @escaping () -> Bool) {
        targetIsCurrent = check
    }

    func fail(_ message: String) { failLaunch(message) }

    func initialCaptureAuthorization() -> WidgetInitialCaptureAuthorization {
        WidgetInitialCaptureAuthorization(lease: self)
    }

    fileprivate func consumeInitialCapture() {
        guard !captureConsumed, isCurrent else { return }
        captureConsumed = true
        consumeCapture()
    }
}

/// A one-shot bridge from a pending widget launch to the voice controller.
/// It remains revocable until the input actually starts. After that point the
/// established conversation and its ordinary resume controls are independent
/// of the launch deadline.
@MainActor
final class WidgetInitialCaptureAuthorization {
    private weak var lease: WidgetLaunchLease?
    private var captureStarted = false

    fileprivate init(lease: WidgetLaunchLease) {
        self.lease = lease
    }

    var mayStartCapture: Bool {
        captureStarted || (lease?.isCurrent ?? false)
    }

    func captureDidStart() {
        guard !captureStarted, let lease, lease.isCurrent else { return }
        captureStarted = true
        lease.consumeInitialCapture()
    }
}

/// A process-local, foreground router. Duplicate delivery is coalesced only
/// while an equivalent request is pending; a later tap gets a new generation.
@MainActor
final class WidgetLaunchCoordinator {
    typealias Operation = @MainActor (WidgetLaunchLink, WidgetLaunchLease) async -> WidgetLaunchOutcome

    private final class Request {
        let link: WidgetLaunchLink
        let generation: UInt64
        let deadline: Duration
        var stage: Stage = .prepare
        var inFlight = false
        var task: Task<Void, Never>?
        var expiryTask: Task<Void, Never>?

        init(link: WidgetLaunchLink, generation: UInt64, deadline: Duration) {
            self.link = link
            self.generation = generation
            self.deadline = deadline
        }
    }

    private enum Stage { case prepare, perform }

    /// How long a widget launch may wait for readiness; the lease deadline
    /// and the expiry task both use it.
    static let launchTimeout: Duration = .seconds(30)

    private let now: () -> Duration
    private let prepare: Operation
    private let perform: Operation
    private let finish: @MainActor (WidgetLaunchOutcome) -> Void
    private var generation: UInt64 = 0
    private var request: Request?
    private var activeLease: WidgetLaunchLease?
    private var activeLeaseExpiryTask: Task<Void, Never>?
    private var handedOffTalkGeneration: UInt64?
    private var activeTalkDeadline: Duration?

    init(
        now: @escaping () -> Duration,
        prepare: @escaping Operation,
        perform: @escaping Operation,
        finish: @escaping @MainActor (WidgetLaunchOutcome) -> Void
    ) {
        self.now = now
        self.prepare = prepare
        self.perform = perform
        self.finish = finish
    }

    var hasPendingRequest: Bool { request != nil }

    func receive(_ link: WidgetLaunchLink) {
        if let request, request.link == link, request.inFlight { return }
        supersede()
        generation &+= 1
        let next = Request(link: link, generation: generation, deadline: now() + Self.launchTimeout)
        request = next
        activeLease = makeLease(generation: next.generation, deadline: next.deadline)
        let requestGeneration = next.generation
        next.expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.launchTimeout) } catch { return }
            guard let self, self.generation == requestGeneration else { return }
            if let request = self.request, request.generation == requestGeneration {
                self.expire(request)
            } else {
                self.expireHandedOffTalk(generation: requestGeneration)
            }
        }
        activeLeaseExpiryTask = next.expiryTask
        advance(next)
    }

    /// A newer user destination, sign-out, or true background invalidates
    /// both pending work and any Talk capture custody handed to a controller.
    func supersede() {
        generation &+= 1
        let old = request
        request = nil
        activeLease = nil
        handedOffTalkGeneration = nil
        activeTalkDeadline = nil
        activeLeaseExpiryTask?.cancel()
        activeLeaseExpiryTask = nil
        old?.task?.cancel()
        old?.expiryTask?.cancel()
    }

    func readinessChanged() {
        guard let request else {
            if let handedOffTalkGeneration,
               let activeTalkDeadline,
               now() >= activeTalkDeadline {
                expireHandedOffTalk(generation: handedOffTalkGeneration)
            }
            return
        }
        guard lease(for: request).isCurrent else {
            expire(request)
            return
        }
        advance(request)
    }

    func currentLease(for link: WidgetLaunchLink) -> WidgetLaunchLease? {
        guard let request, request.link == link else { return nil }
        return lease(for: request)
    }

    private func lease(for request: Request) -> WidgetLaunchLease {
        activeLease ?? makeLease(generation: request.generation, deadline: request.deadline)
    }

    private func makeLease(generation leaseGeneration: UInt64, deadline: Duration) -> WidgetLaunchLease {
        WidgetLaunchLease(
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.generation == leaseGeneration && self.now() < deadline
            },
            captureDidStart: { [weak self] in
                guard let self, self.generation == leaseGeneration else { return }
                self.generation &+= 1
                self.activeLease = nil
                self.handedOffTalkGeneration = nil
                self.activeTalkDeadline = nil
                self.activeLeaseExpiryTask?.cancel()
                self.activeLeaseExpiryTask = nil
                // Capture may begin synchronously while `perform` is still
                // returning. Retire pending ownership without cancelling
                // that same operation or leaving the return-surface gate set.
                if let request = self.request, request.generation == leaseGeneration {
                    request.expiryTask?.cancel()
                    self.request = nil
                }
            },
            fail: { [weak self] message in
                guard let self, self.generation == leaseGeneration else { return }
                if let request = self.request, request.generation == leaseGeneration {
                    self.terminate(request, outcome: .failed(message))
                }
            }
        )
    }

    private func advance(_ request: Request) {
        guard self.request === request, !request.inFlight else { return }
        let lease = lease(for: request)
        guard lease.isCurrent else { expire(request); return }
        request.inFlight = true
        request.task = Task { @MainActor [weak self, weak request] in
            guard let self, let request else { return }
            let outcome: WidgetLaunchOutcome
            if request.stage == .prepare {
                outcome = await self.prepare(request.link, lease)
                guard self.isCurrent(request), lease.isCurrent else { return }
                switch outcome {
                case .handled:
                    request.stage = .perform
                case .deferred:
                    request.inFlight = false
                    request.task = nil
                    return
                case .failed:
                    self.terminate(request, outcome: outcome)
                    return
                }
            }
            guard self.isCurrent(request), lease.isCurrent else { return }
            let performed = await self.perform(request.link, lease)
            guard self.isCurrent(request), lease.isCurrent else { return }
            switch performed {
            case .deferred:
                request.inFlight = false
                request.task = nil
            case .handled, .failed:
                self.terminate(request, outcome: performed)
            }
        }
    }

    private func isCurrent(_ request: Request) -> Bool {
        self.request === request && generation == request.generation
    }

    private func expire(_ request: Request) {
        guard isCurrent(request) else { return }
        terminate(request, outcome: .failed(AppLocalization.string("WidgetLaunch.Expired")))
    }

    private func expireHandedOffTalk(generation leaseGeneration: UInt64) {
        guard generation == leaseGeneration,
              handedOffTalkGeneration == leaseGeneration,
              activeLease?.isCurrent != true else { return }
        handedOffTalkGeneration = nil
        activeLease = nil
        activeTalkDeadline = nil
        activeLeaseExpiryTask = nil
        generation &+= 1
        finish(.failed(AppLocalization.string("WidgetLaunch.Expired")))
    }

    private func terminate(_ request: Request, outcome: WidgetLaunchOutcome) {
        guard isCurrent(request) else { return }
        request.task?.cancel()
        let retainTalkCaptureDeadline = request.link.action == .talk && !isFailure(outcome)
        if !retainTalkCaptureDeadline {
            request.expiryTask?.cancel()
            activeLeaseExpiryTask?.cancel()
            activeLeaseExpiryTask = nil
        } else {
            handedOffTalkGeneration = request.generation
            activeTalkDeadline = request.deadline
        }
        request.inFlight = false
        self.request = nil
        if !retainTalkCaptureDeadline { activeLease = nil }
        finish(outcome)
    }

    private func isFailure(_ outcome: WidgetLaunchOutcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }
}
