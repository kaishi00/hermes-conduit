import Foundation

/// A live call's per-chunk wire work, off the main actor (issue 1959).
/// Every live mode streams the microphone at about 50 chunks a second and
/// gets the model's speech at a similar rate, each chunk base64 inside
/// JSON. Building and parsing those frames on the main actor put them in
/// line behind every SwiftUI commit, so a busy screen (a transcript delta
/// storm, a sheet animating) held up the microphone and the speaker. The
/// sessions keep their state on the main actor; only the pure encode and
/// decode steps run here, and each socket still sends and delivers frames
/// one at a time, in order.
enum LiveVoiceWireCoding {
    static func throwingOffMainActor<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    static func offMainActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}
