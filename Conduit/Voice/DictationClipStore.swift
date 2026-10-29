//
//  DictationClipStore.swift
//  Conduit
//
//  A Hermes dictation's recording, kept on this iPhone until its words are
//  in the draft. The whole recording used to live only in memory and went
//  up once: a dropped connection, a failed upload or Conduit being stopped
//  meant the words were gone. Now it is written here before it goes up,
//  tried again a few times on a brief network gap, and left for the
//  person to retry (or delete) when it still couldn't go, after a restart
//  too (DictationClipInbox).
//

import Foundation

/// One kept recording: 16 kHz mono PCM16 in `<id>.pcm`, described by
/// `<id>.json`.
struct DictationClip: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordedAt: Date
    let duration: TimeInterval
    let sampleRate: Double
    /// The host and profile it was recorded for (HermesVoiceGateway's
    /// identity): only their composer offers it, and a retry goes there.
    let identity: String
    /// Uploads tried so far, and how the last one failed.
    var attempts = 0
    var lastAttemptAt: Date?
    var lastError: String?
}

/// The recordings on disk, in Application Support, out of iCloud backups.
/// Each method is one short file operation; callers keep the big writes and
/// reads off the main actor.
struct DictationClipStore: Sendable {
    /// Unclaimed recordings go after two weeks; at most this many are kept.
    static let maximumAge: TimeInterval = 14 * 24 * 60 * 60
    static let capacity = 20
    /// A recording with no description, or the reverse, is a save that
    /// never finished: removed once it is this old, never while a save may
    /// still be writing it.
    static let orphanAge: TimeInterval = 10 * 60
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    let directory: URL

    init(directory: URL = Self.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("DictationClips", isDirectory: true)
    }

    /// Writes the recording, then its description: a clip is only listed
    /// once both are on disk.
    func save(pcm16: Data, clip: DictationClip) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(values)
        try pcm16.write(to: audioURL(clip.id), options: Self.writeOptions)
        try update(clip)
    }

    /// Rewrites a clip's description (its attempts).
    func update(_ clip: DictationClip) throws {
        try JSONEncoder().encode(clip).write(to: metadataURL(clip.id), options: Self.writeOptions)
    }

    /// Every complete clip, newest first. One that can't be read is left
    /// for `prune` rather than failing the rest.
    func clips() -> [DictationClip] {
        let decoder = JSONDecoder()
        let fileManager = FileManager.default
        return files(withExtension: "json").compactMap { url -> DictationClip? in
            guard let data = try? Data(contentsOf: url),
                  let clip = try? decoder.decode(DictationClip.self, from: data),
                  fileManager.fileExists(atPath: audioURL(clip.id).path) else { return nil }
            return clip
        }
        .sorted { $0.recordedAt > $1.recordedAt }
    }

    func audio(for clip: DictationClip) throws -> Data {
        try Data(contentsOf: audioURL(clip.id))
    }

    func remove(_ id: UUID) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: metadataURL(id))
        try? fileManager.removeItem(at: audioURL(id))
    }

    /// Removes clips past `maximumAge`, the oldest past `capacity`, and
    /// half-saved files past `orphanAge`. A whole clip it can't read (the
    /// iPhone hasn't been unlocked since it restarted) stays until it is
    /// past `maximumAge` by its files' dates. Returns the clips kept.
    @discardableResult
    func prune(now: Date = Date()) -> [DictationClip] {
        var kept: [DictationClip] = []
        for clip in clips() {
            if now.timeIntervalSince(clip.recordedAt) > Self.maximumAge || kept.count >= Self.capacity {
                remove(clip.id)
            } else {
                kept.append(clip)
            }
        }
        let keptIDs = Set(kept.map(\.id.uuidString))
        let fileManager = FileManager.default
        for url in files(withExtension: "json") + files(withExtension: "pcm") {
            guard !keptIDs.contains(url.deletingPathExtension().lastPathComponent) else { continue }
            let partner = url.deletingPathExtension().appendingPathExtension(url.pathExtension == "json" ? "pcm" : "json")
            let limit = fileManager.fileExists(atPath: partner.path) ? Self.maximumAge : Self.orphanAge
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > limit {
                try? fileManager.removeItem(at: url)
            }
        }
        return kept
    }

    private func audioURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("pcm")
    }

    private func metadataURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func files(withExtension pathExtension: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return urls.filter { $0.pathExtension == pathExtension }
    }
}

/// When a kept recording's upload is tried again on its own: a few times
/// over about two minutes, so a brief network gap or a host restarting
/// doesn't cost the words. Past that, or on an answer that won't change
/// (a sign-in, a refused recording), it waits for the person's Retry.
enum DictationUploadRetry {
    /// The waits between attempts: five attempts, 110 seconds of waiting.
    static let delays: [Duration] = [.seconds(5), .seconds(15), .seconds(30), .seconds(60)]

    static var maximumAttempts: Int { delays.count + 1 }

    /// The wait before trying again once attempt `attempt` (from 1) failed
    /// with `error`, or nil to stop.
    static func delay(afterAttempt attempt: Int, failedWith error: Error) -> Duration? {
        guard isTransient(error), delays.indices.contains(attempt - 1) else { return nil }
        return delays[attempt - 1]
    }

    /// No connection, a timeout, the dashboard still connecting, or the host
    /// overloaded or restarting. Not a sign-in, a 4xx or Hermes' own
    /// transcription error: the same recording would fail the same way.
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case DashboardTicketBridgeError.notReady, DashboardTicketBridgeError.answeredAfterSwitch:
            return true
        case DashboardTicketBridgeError.http(let status, _):
            return status == 0 || status == 408 || status == 429 || (status >= 500 && status != 501)
        case let error as URLError:
            return transientNetworkErrors.contains(error.code)
        default:
            return false
        }
    }

    /// The connection dropped or never came up; not a bad address, a
    /// certificate or a cancel.
    private static let transientNetworkErrors: Set<URLError.Code> = [
        .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
        .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
        .secureConnectionFailed, .cannotLoadFromNetwork, .backgroundSessionWasDisconnected,
    ]

    /// Runs `attempt` until it succeeds or `delay` says stop, then throws
    /// the last failure. Each failure goes to `onFailedAttempt` first.
    /// Cancellation ends it at once.
    @MainActor
    static func run(
        attempt: () async throws -> String,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onFailedAttempt: (Error) -> Void = { _ in }
    ) async throws -> String {
        var number = 1
        while true {
            do {
                return try await attempt()
            } catch {
                try Task.checkCancellation()
                onFailedAttempt(error)
                guard let wait = delay(afterAttempt: number, failedWith: error) else { throw error }
                try await sleep(wait)
                number += 1
            }
        }
    }
}
