//
//  DictationClipInbox.swift
//  Conduit
//
//  The Hermes dictations whose words haven't reached a draft yet
//  (DictationClipStore). A running dictation keeps its recording here
//  before it goes up and owns it until its words land; one it couldn't
//  deliver is let go and offered in the composer with Retry and Delete,
//  as is one left by an earlier run that stopped first.
//

import Foundation
import OSLog

private let dictationClipLog = Logger(subsystem: "com.milim.relay", category: "DictationClips")

/// A Retry whose kept recording is on disk but can't be read yet.
struct DictationClipUnreadable: Error {}

@MainActor
final class DictationClipInbox: ObservableObject {
    static let shared = DictationClipInbox()

    /// An upload with nothing to show for a recording this long is kept
    /// for Retry: Hermes answers empty only for quiet audio.
    static let quietClipLimit: TimeInterval = 10
    /// A dictation ended while still listening keeps a recording this long
    /// or longer; a shorter one is a tap and a release.
    static let shortestKept: TimeInterval = 2

    /// Kept recordings, newest first.
    @Published private(set) var clips: [DictationClip] = []
    /// Recordings a running dictation still owns: not offered.
    @Published private(set) var owned: Set<UUID> = []
    /// Recordings a Retry is uploading.
    @Published private(set) var retrying: Set<UUID> = []

    private let store: DictationClipStore
    /// File work runs off the main actor, one operation at a time, in the
    /// order it was asked for.
    private var fileWork: Task<Void, Never>?

    init(store: DictationClipStore = DictationClipStore()) {
        self.store = store
    }

    /// At launch: drops what is too old, then offers what's left.
    func load() async {
        let kept = await onDisk { $0.prune() }.value
        // A dictation that kept one meanwhile has it at the front already.
        clips = clips + kept.filter { clip in !clips.contains { $0.id == clip.id } }
    }

    /// Recordings to offer in a composer for this host and profile, apart
    /// from any whose words are already on their way to a draft.
    func offered(for identity: String?, delivering: Set<UUID> = []) -> [DictationClip] {
        guard let identity else { return [] }
        return clips.filter { clip in
            clip.identity == identity && !owned.contains(clip.id) && !delivering.contains(clip.id)
        }
    }

    /// Writes a finished recording to disk before it goes up. The caller
    /// owns it until it calls `delivered` or `release`. Nil when it
    /// couldn't be written: the upload goes ahead from memory, as before.
    func keep(pcm16: Data, sampleRate: Double, identity: String, recordedAt: Date = Date()) async -> DictationClip? {
        let clip = DictationClip(
            id: UUID(),
            recordedAt: recordedAt,
            duration: Double(pcm16.count) / 2 / sampleRate,
            sampleRate: sampleRate,
            identity: identity
        )
        owned.insert(clip.id)
        let saved = await onDisk { store -> Bool in
            do {
                try store.save(pcm16: pcm16, clip: clip)
                return true
            } catch {
                dictationClipLog.error("Couldn't keep a dictation's recording: \(String(describing: error), privacy: .private)")
                store.remove(clip.id)
                return false
            }
        }.value
        guard saved else {
            owned.remove(clip.id)
            return nil
        }
        clips.insert(clip, at: 0)
        return clip
    }

    /// An upload of it failed: counted on disk, so a retry after a restart
    /// still knows.
    func attemptFailed(_ id: UUID, error: Error, at date: Date = Date()) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].attempts += 1
        clips[index].lastAttemptAt = date
        clips[index].lastError = UserFacingError.message(for: error)
        let clip = clips[index]
        onDisk { store in
            do {
                try store.update(clip)
            } catch {
                dictationClipLog.error("Couldn't note a dictation's failed upload: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Its dictation is over without its words: offer it.
    func release(_ id: UUID) {
        owned.remove(id)
    }

    /// Its words are in a draft, or the person deleted it: gone from disk.
    func delivered(_ id: UUID) {
        owned.remove(id)
        retrying.remove(id)
        clips.removeAll { $0.id == id }
        onDisk { store in
            store.remove(id)
            store.prune()
        }
    }

    /// A Retry: one upload of the kept recording. Returns its words; the
    /// caller puts them in a draft, then calls `delivered`. Empty words
    /// mean Hermes heard none: a short recording is deleted, a long one
    /// kept, since Hermes answers empty only for quiet audio.
    func retry(
        _ clip: DictationClip,
        transcribe: @MainActor (VoiceCapturedAudio) async throws -> String
    ) async throws -> String {
        guard !owned.contains(clip.id), retrying.insert(clip.id).inserted else { throw CancellationError() }
        defer { retrying.remove(clip.id) }
        let pcm16: Data
        do {
            pcm16 = try await onDisk { store in Result { try store.audio(for: clip) } }.value.get()
        } catch {
            // Hermes was never asked, so this isn't a failed transcription.
            // Audio that's gone leaves nothing to retry: the row goes too,
            // quietly. One that can't be read yet stays, and says so.
            if case CocoaError.fileReadNoSuchFile = error {
                delivered(clip.id)
                throw CancellationError()
            }
            dictationClipLog.error("Couldn't read a kept dictation for Retry: \(String(describing: error), privacy: .private)")
            throw DictationClipUnreadable()
        }
        do {
            let words = try await transcribe(.dictation(pcm16: pcm16, sampleRate: clip.sampleRate))
            // Nothing heard: a short recording goes, a long one stays, as
            // after its first upload (quietClipLimit).
            if words.isEmpty, clip.duration < Self.quietClipLimit { delivered(clip.id) }
            return words
        } catch {
            attemptFailed(clip.id, error: error)
            throw error
        }
    }

    /// Returns once the file work asked for so far is done.
    func filesWritten() async {
        await fileWork?.value
    }

    @discardableResult
    private func onDisk<Value: Sendable>(
        _ work: @escaping @Sendable (DictationClipStore) -> Value
    ) -> Task<Value, Never> {
        let previous = fileWork
        let store = store
        let task = Task.detached(priority: .userInitiated) { () -> Value in
            await previous?.value
            return work(store)
        }
        fileWork = Task { _ = await task.value }
        return task
    }
}

extension AppState {
    /// The host and profile a dictation started now keeps its recording
    /// for: the composer offers only those.
    var dictationClipIdentity: String? {
        makeVoiceGateway()?.identity
    }

    /// Recordings whose words a Retry got and a composer hasn't taken yet.
    var dictationClipsOnTheirWay: Set<UUID> {
        Set(composerRestoreRequests.compactMap(\.dictationClipID))
    }

    /// A Retry's words, for the draft on screen when it was tapped: into
    /// the field while that draft is open, otherwise into its stored draft.
    /// A chat deleted meanwhile can't be reopened, so they go to the draft
    /// on screen now, as a failed send's words do. The recording goes once
    /// they're there.
    func restoreRetriedDictation(_ words: String, clipID: UUID, dashboardID: UUID, key: ComposerDraftKey) {
        let chatIsGone = !key.isNewConversation
            && dashboardID == activeDashboardID
            && key.profile == activeProfile
            && conversationIsGone(sessionIDs: [key.sessionID], dashboardID: dashboardID, profile: key.profile)
        composerRestoreRequests.append(ComposerRestoreRequest(
            dashboardID: dashboardID,
            key: chatIsGone ? durableComposerDraftKeyOnScreen : key,
            draft: ComposerDraft(text: words, attachments: []),
            focuses: false,
            pending: nil,
            dictationClipID: clipID
        ))
    }
}
