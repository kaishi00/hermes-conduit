//
//  PendingVoiceIntentStore.swift
//  Conduit
//

import Foundation
import Combine

@MainActor
final class PendingVoiceIntentStore: ObservableObject {
    static let shared = PendingVoiceIntentStore()

    @Published private(set) var revision: UInt64 = 0
    private var pending: PendingVoiceIntent?

    /// True while an enqueued intent has not been routed. The store owns this
    /// fact; presentation decisions (e.g. the preferred return surface) read
    /// it rather than duplicating routing logic.
    var hasPendingIntent: Bool { pending != nil }

    func enqueue(_ intent: PendingVoiceIntent) {
        // One voice sheet can only honor one launch request. The newest source
        // is intentional: it reflects the user's latest explicit action.
        pending = intent
        revision &+= 1
    }

    func take() -> PendingVoiceIntent? {
        defer { pending = nil }
        return pending
    }

    func clear() {
        pending = nil
        revision &+= 1
    }
}

@MainActor
final class PendingVoiceIntentRouter {
    typealias Handler = (PendingVoiceIntent) async -> Bool

    private let store: PendingVoiceIntentStore

    init(store: PendingVoiceIntentStore = .shared) { self.store = store }

    /// The UI/app-state integration calls this only after it is authenticated
    /// and connected. A handler may return false to retain the intent for a
    /// later lifecycle pass.
    func routePending(using handler: Handler) async {
        guard let intent = store.take() else { return }
        if !(await handler(intent)) { store.enqueue(intent) }
    }
}
