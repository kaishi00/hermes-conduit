//
//  ReadAloudNowPlaying.swift
//  Conduit
//
//  Lock screen, Control Center, and headphone controls for Read Aloud
//  (#373). iOS shows them only while Conduit owns a non-mixable playback
//  session; when Read Aloud mixes under other media the info is set but the
//  system keeps showing the other app, which is the intended behaviour.
//

import Foundation
import MediaPlayer

/// The remote actions Read Aloud answers. Each returns false when it was
/// refused (nothing playing to pause, a reply that already settled).
struct ReadAloudRemoteCommands {
    var pause: @MainActor () -> Bool
    var resume: @MainActor () -> Bool
    var togglePause: @MainActor () -> Bool
    var stop: @MainActor () -> Bool
}

@MainActor
protocol ReadAloudNowPlayingPresenting: AnyObject {
    /// Publishes the reply as the Now Playing item and starts answering
    /// remote commands with `commands`.
    func begin(title: String, commands: ReadAloudRemoteCommands)
    func setPaused(_ paused: Bool)
    /// Clears the item and stops answering remote commands. Idempotent.
    func end()
}

@MainActor
final class SystemReadAloudNowPlaying: ReadAloudNowPlayingPresenting {
    private var targets: [(MPRemoteCommand, Any)] = []
    /// Commands `begin()` hid; `end()` restores them.
    private var hiddenCommands: [MPRemoteCommand] = []

    func begin(title: String, commands: ReadAloudRemoteCommands) {
        end()
        let center = MPRemoteCommandCenter.shared()
        register(center.pauseCommand) { commands.pause() }
        register(center.playCommand) { commands.resume() }
        register(center.togglePlayPauseCommand) { commands.togglePause() }
        register(center.stopCommand) { commands.stop() }
        // A spoken reply has no tracks, seeking, or speed control here:
        // hide the lock-screen buttons that would do nothing.
        hiddenCommands = Self.unsupportedCommands(center).filter(\.isEnabled)
        for command in hiddenCommands {
            command.isEnabled = false
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: AppLocalization.string("Read Aloud"),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }

    func setPaused(_ paused: Bool) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0.0 : 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func end() {
        guard !targets.isEmpty else { return }
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets.removeAll()
        for command in hiddenCommands {
            command.isEnabled = true
        }
        hiddenCommands.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private static func unsupportedCommands(_ center: MPRemoteCommandCenter) -> [MPRemoteCommand] {
        [
            center.nextTrackCommand,
            center.previousTrackCommand,
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.seekForwardCommand,
            center.seekBackwardCommand,
            center.changePlaybackPositionCommand,
            center.changePlaybackRateCommand,
        ]
    }

    private func register(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Bool) {
        command.isEnabled = true
        let target = command.addTarget { _ in
            // Delivered on the main thread in practice, which lets a refused
            // action report failure; the queue is not documented, so hop
            // rather than trap if it ever isn't.
            guard Thread.isMainThread else {
                Task { @MainActor in _ = action() }
                return .success
            }
            return MainActor.assumeIsolated { action() } ? .success : .commandFailed
        }
        targets.append((command, target))
    }
}

extension ReadAloudNowPlaying {
    /// A short Now Playing title from the reply: its first spoken line.
    static func title(for content: String) -> String {
        let spoken = SpokenTextFilter.filter(content)
        let source = spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? content : spoken
        // Markdown emphasis and code markers read as noise on the lock
        // screen; heading, quote, and list markers too.
        let firstLine = source
            .split(whereSeparator: \.isNewline)
            .map { line in
                String(line.filter { $0 != "*" && $0 != "`" })
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#>-•").union(.whitespaces))
            }
            .first { !$0.isEmpty } ?? ""
        guard firstLine.count > maxTitleLength else { return firstLine }
        return String(firstLine.prefix(maxTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static let maxTitleLength = 80
}

enum ReadAloudNowPlaying {}
