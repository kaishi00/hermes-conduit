//
//  ProfileConfigWriteQueue.swift
//  Conduit
//
//  Every change to a profile's Hermes config runs here, one after another,
//  app-wide (#1004). Most are a GET, a change and a PUT of the whole
//  document, and Settings pages save independently: voice settings, the
//  speech server page, Local Live and the Model page each have their own
//  savers, some in their own service. Two overlapping round trips read the
//  same old document, and the later PUT puts back what the earlier one
//  changed, such as a speech server key saved a moment before.
//

import Foundation

@MainActor
enum ProfileConfigWriteQueue {
    private static var tail: Task<Void, Never>?

    /// Runs `operation` after every earlier one has finished, failed or
    /// not. Writes are rare, so one queue covers every dashboard and
    /// profile.
    static func run<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// `run`, for an operation that throws.
    static func runThrowing<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let result: Result<T, Error> = await run {
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        return try result.get()
    }
}
