//
//  InlineAudioClip.swift
//  Conduit
//
//  Inline playback for audio in a chat (#439): an agent's `MEDIA:` clip
//  (Hermes text-to-speech, a generated recording) or an audio file the user
//  attached. Images preview inline; audio used to be a card that only
//  opened full screen, so a voice reply took two taps and a modal to hear.
//  Now the row has play/pause and a scrubber, and the expand button still
//  opens Quick Look for save/share.
//
//  One clip plays at a time across the app, through `ChatAudioClipPlayer`.
//  The bytes are fetched on the first play (never while scrolling past)
//  and dropped when the clip stops, so a transcript full of clips holds no
//  audio in memory. A format AVFoundation can't decode (Ogg is the usual
//  one) says so on the row, and the expand button still opens the file.
//

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ChatAudioClipPlayer: NSObject, ObservableObject {
    static let shared = ChatAudioClipPlayer()

    enum Phase: Equatable {
        case loading
        case playing
        case paused
    }

    struct Clip: Equatable {
        let id: String
        var phase: Phase
        var duration: TimeInterval
    }

    /// The playing clip's position, published apart from `clip` so the
    /// 250 ms ticks only redraw the one scrubber that shows it, not every
    /// audio row observing the player.
    final class Progress: ObservableObject {
        @Published var currentTime: TimeInterval = 0
    }

    /// Why a clip has no playback, kept so its row can say so.
    enum Problem: Equatable {
        /// The bytes could not be fetched (missing on the host, too large).
        case unavailable
        /// The bytes arrived but AVFoundation can't decode them here.
        case unsupported
    }

    /// The clip that is loading, playing or paused, if any.
    @Published private(set) var clip: Clip?
    @Published private(set) var problems: [String: Problem] = [:]
    let progress = Progress()

    private var player: AVAudioPlayer?
    private var lease: VoiceAudioLease?
    private var loadTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private let coordinator: VoiceAudioSessionCoordinator

    /// Optional rather than defaulted: a default argument is evaluated
    /// outside the main actor, where `.shared` can't be read.
    init(coordinator: VoiceAudioSessionCoordinator? = nil) {
        self.coordinator = coordinator ?? .shared
        super.init()
        // A phone call or alarm pauses the player underneath us; mirror it
        // so the row shows Play rather than a frozen Pause.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Play, pause or resume `id`, stopping any other clip first. `load`
    /// returns the file's bytes; it runs only when the clip is not loaded.
    func toggle(id: String, filename: String, load: @escaping () async -> Data?) {
        if let clip, clip.id == id {
            switch clip.phase {
            case .playing: pause()
            case .paused: resume()
            case .loading: stop()
            }
            return
        }
        stop()
        problems[id] = nil
        clip = Clip(id: id, phase: .loading, duration: 0)
        progress.currentTime = 0
        let hint = Self.fileTypeHint(for: filename)
        loadTask = Task { [weak self] in
            let data = await load()
            guard let self, !Task.isCancelled, self.clip?.id == id else { return }
            self.loadTask = nil
            guard let data else {
                self.clip = nil
                self.problems[id] = .unavailable
                return
            }
            guard let player = try? AVAudioPlayer(data: data, fileTypeHint: hint), player.duration > 0 else {
                self.clip = nil
                self.problems[id] = .unsupported
                return
            }
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            self.clip = Clip(id: id, phase: .paused, duration: player.duration)
            self.resume()
        }
    }

    func seek(id: String, to time: TimeInterval) {
        guard let player, clip?.id == id else { return }
        player.currentTime = min(max(0, time), player.duration)
        progress.currentTime = player.currentTime
    }

    /// Stops `id` if it is the current clip. Rows call this as they leave
    /// the screen, so nothing plays without a visible control.
    func stop(id: String) {
        guard clip?.id == id else { return }
        stop()
    }

    /// Stops and forgets the current clip, releasing its audio.
    func stop() {
        loadTask?.cancel()
        loadTask = nil
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player?.delegate = nil
        player = nil
        clip = nil
        releaseLease()
    }

    private func pause() {
        player?.pause()
        progressTask?.cancel()
        progressTask = nil
        if let player { progress.currentTime = player.currentTime }
        clip?.phase = .paused
        releaseLease()
    }

    private func resume() {
        guard let player else { return }
        if lease == nil {
            // Playback still starts if the session can't be claimed: the
            // clip then plays under whatever category is already active.
            lease = try? coordinator.acquire(.standalonePlayback)
        }
        guard player.play() else {
            releaseLease()
            clip?.phase = .paused
            return
        }
        clip?.phase = .playing
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, let player = self.player else { return }
                self.progress.currentTime = player.currentTime
            }
        }
    }

    private func releaseLease() {
        guard let lease else { return }
        self.lease = nil
        coordinator.release(lease)
    }

    private func finished(_ finishedPlayer: AVAudioPlayer) {
        guard finishedPlayer === player else { return }
        // Keep the clip loaded at its start, so Play replays it at once.
        progressTask?.cancel()
        progressTask = nil
        finishedPlayer.currentTime = 0
        progress.currentTime = 0
        clip?.phase = .paused
        releaseLease()
    }

    /// A file that stops decoding partway is reported like one that never
    /// decoded, rather than looking like an ordinary paused clip.
    private func failedDecoding(_ failedPlayer: AVAudioPlayer) {
        guard failedPlayer === player, let id = clip?.id else { return }
        stop()
        problems[id] = .unsupported
    }

    @objc nonisolated private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor [weak self] in
            guard let self, self.clip?.phase == .playing else { return }
            self.pause()
        }
    }

    nonisolated static func fileTypeHint(for filename: String) -> String? {
        let ext = (MediaPreviewPresenter.sanitizedFilename(filename) as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.identifier
    }

    /// "1:05", or "1:02:05" past an hour.
    nonisolated static func timeLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

extension ChatAudioClipPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finished(player) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.failedDecoding(player) }
    }
}

/// The row for one audio clip: play/pause, a scrubber with times once it is
/// loaded, and an expand button that opens Quick Look (save/share).
struct InlineAudioClipView: View {
    enum Style {
        /// An agent reply: a bordered card on the transcript background.
        case card
        /// The user's own bubble: white on the accent gradient.
        case bubble
    }

    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject private var player = ChatAudioClipPlayer.shared
    let id: String
    let name: String
    let filename: String
    let style: Style
    /// True while the full-screen preview is being fetched.
    let opening: Bool
    /// True when the last full-screen open failed.
    var openFailed = false
    let load: () async -> Data?
    let openFull: () -> Void
    @ScaledMetric(relativeTo: .body) private var playSize: CGFloat = 40
    @ScaledMetric(relativeTo: .footnote) private var expandSize: CGFloat = 32

    private var clip: ChatAudioClipPlayer.Clip? {
        player.clip?.id == id ? player.clip : nil
    }

    private var problem: ChatAudioClipPlayer.Problem? { player.problems[id] }

    private var primary: Color { style == .bubble ? .white : .primary }
    private var secondary: Color { style == .bubble ? .white.opacity(0.78) : .secondary }
    private var tint: Color { style == .bubble ? .white : .conduitAccent }

    var body: some View {
        HStack(spacing: 10) {
            playButton
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button {
                // Quick Look has its own player; don't play underneath it.
                player.stop(id: id)
                openFull()
            } label: {
                Group {
                    if opening {
                        ProgressView().tint(secondary)
                    } else {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.footnote.weight(.semibold))
                    }
                }
                .foregroundStyle(secondary)
                .frame(width: expandSize, height: expandSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Open full screen"))
            .accessibilityHint(Text("Opens full screen with save and share"))
        }
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(background)
        .onDisappear { player.stop(id: id) }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .card:
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                }
        case .bubble:
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.13))
        }
    }

    private var playButton: some View {
        Button {
            player.toggle(id: id, filename: filename, load: load)
        } label: {
            ZStack {
                Circle().fill(tint.opacity(style == .bubble ? 0.22 : 0.14))
                if clip?.phase == .loading {
                    ProgressView().tint(tint)
                } else {
                    Image(systemName: clip?.phase == .playing ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: playSize, height: playSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(clip?.phase == .playing ? Text("Pause") : Text("Play"))
        .accessibilityValue(Text(verbatim: name))
    }

    @ViewBuilder
    private var detail: some View {
        if let clip, clip.duration > 0 {
            AudioClipScrubber(
                progress: player.progress,
                duration: clip.duration,
                tint: tint,
                secondary: secondary,
                seek: { player.seek(id: id, to: $0) }
            )
        } else {
            Text(verbatim: detailText)
                .font(.caption)
                .foregroundStyle(secondary)
                .lineLimit(2)
        }
    }

    private var detailText: String {
        switch problem {
        case .unavailable: return AppLocalization.string("Couldn't open this file")
        case .unsupported: return AppLocalization.string("Can't play this format here. Open it full screen instead.")
        case nil: return openFailed ? AppLocalization.string("Couldn't open this file") : AppLocalization.string("Audio")
        }
    }
}

/// Scrubber and times for the clip that is loaded. The only view that
/// observes the position, so playback ticks redraw just this.
private struct AudioClipScrubber: View {
    @ObservedObject var progress: ChatAudioClipPlayer.Progress
    let duration: TimeInterval
    let tint: Color
    let secondary: Color
    let seek: (TimeInterval) -> Void

    private var timeText: String {
        "\(ChatAudioClipPlayer.timeLabel(progress.currentTime)) / \(ChatAudioClipPlayer.timeLabel(duration))"
    }

    var body: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(get: { progress.currentTime }, set: seek),
                in: 0...duration
            )
            .tint(tint)
            .controlSize(.mini)
            .accessibilityLabel(Text("Playback position"))
            .accessibilityValue(Text(verbatim: timeText))
            Text(verbatim: timeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(secondary)
                .fixedSize()
        }
    }
}
