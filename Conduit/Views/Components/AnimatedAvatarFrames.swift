//
//  AnimatedAvatarFrames.swift
//  Conduit
//
//  Plays a moving picture (AnimatedAvatar) inside a face. Callers draw the
//  still first frame and put this over it, only where the face is what
//  you're looking at (a Bots Home portrait, the Bot Overview, the editors).
//  Rows, transcripts, menus and pickers keep the still.
//

import ImageIO
import SwiftUI

/// What to play: the picture file on the phone (ProfileAppearanceStore's
/// copy of the Hermes picture), or a fresh pick not saved yet.
enum AnimatedAvatarPlayback: Equatable {
    case file(URL, revision: Int)
    case data(Data)
}

/// The frames over the still. Plays only while the app is active and not
/// with Reduce Motion or in Low Power Mode, the rules Bots Home's portrait
/// motion follows; otherwise it draws nothing and the still shows.
struct AnimatedAvatarFrames: View {
    let playback: AnimatedAvatarPlayback
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var devicePower = DevicePowerState.shared
    @StateObject private var player = AnimatedAvatarPlayer()

    private var plays: Bool {
        scenePhase == .active && !reduceMotion && !devicePower.isLowPowerModeEnabled
    }

    var body: some View {
        // A ZStack with a clear base, not a Group: a Group hands its
        // modifiers to its children, and with no frame yet it has none, so
        // onAppear never ran and nothing ever played (Eric, 2026-11-06: a
        // GIF and a video both stayed still).
        ZStack {
            Color.clear
            if plays, let frame = player.frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
        }
        .onAppear { if plays { player.play(playback) } }
        .onDisappear { player.stop() }
        .onChange(of: plays) { _, plays in
            if plays { player.play(playback) } else { player.stop() }
        }
        .onChange(of: playback) { _, playback in
            if plays { player.play(playback) } else { player.stop() }
        }
        // Decorative over the still: taps go to whatever holds the face.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// ImageIO's own player (CGAnimateImage…WithBlock): it decodes one frame at
/// a time on its schedule and calls back on the main queue, so a moving
/// face holds one frame in memory, not all of them.
@MainActor
final class AnimatedAvatarPlayer: ObservableObject {
    @Published private(set) var frame: CGImage?
    /// Each play's own number; a callback from an older play stops it.
    private var current = 0

    func play(_ playback: AnimatedAvatarPlayback) {
        stop()
        let mine = current
        let block: CGImageSourceAnimationBlock = { [weak self] _, image, stop in
            MainActor.assumeIsolated {
                guard let self, self.current == mine else {
                    stop.pointee = true
                    return
                }
                self.frame = image
            }
        }
        switch playback {
        case .file(let url, _):
            _ = CGAnimateImageAtURLWithBlock(url as CFURL, nil, block)
        case .data(let data):
            _ = CGAnimateImageDataWithBlock(data as CFData, nil, block)
        }
    }

    func stop() {
        current &+= 1
        if frame != nil { frame = nil }
    }
}
