//
//  CapabilityToggleWrites.swift
//  Conduit
//
//  The skill and toolset switches in Settings > Capabilities (AppState).
//  Hermes saves each one by rewriting config.yaml, so they reach it one
//  after another, in the order they were flipped. A failed write puts a
//  switch back to what Hermes last confirmed, and only when no newer flip
//  of that switch is still to come; that flip decides, and reports its own
//  failure.
//

import Foundation

@MainActor
final class CapabilityToggleWrites {
    struct Outcome {
        /// Nil also when a newer flip of the switch replaced this one: the
        /// newer one says whether it went through.
        let error: Error?
        /// The value to show again after a failure; nil to leave the row.
        let restore: Bool?
    }

    private struct Pending {
        /// What Hermes last confirmed for the switch.
        var confirmed: Bool
        /// The newest flip of it.
        var newest: UInt64
    }

    private var pending: [String: Pending] = [:]
    private var flips: UInt64 = 0
    private var tail: Task<Void, Never>?

    /// Runs `write` once every switch flipped before it has been written.
    /// `current` is the switch as shown before this flip.
    func send(
        _ key: String,
        enabled: Bool,
        current: Bool,
        write: @escaping @MainActor () async throws -> Void
    ) async -> Outcome {
        flips &+= 1
        let flip = flips
        pending[key, default: Pending(confirmed: current, newest: flip)].newest = flip
        let previous = tail
        let turn = Task { () -> Error? in
            await previous?.value
            do {
                try await write()
                return nil
            } catch {
                return error
            }
        }
        tail = Task { _ = await turn.value }
        let error = await turn.value
        guard var state = pending[key] else { return Outcome(error: error, restore: nil) }
        if error == nil { state.confirmed = enabled }
        // A newer flip of this switch is still on its way: it decides.
        guard state.newest == flip else {
            pending[key] = state
            return Outcome(error: nil, restore: nil)
        }
        pending[key] = nil
        return Outcome(error: error, restore: error == nil ? nil : state.confirmed)
    }
}
