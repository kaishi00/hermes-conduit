//
//  ReadAloudPlayerBar.swift
//  Conduit
//
//  While a reply is read aloud, a small player sits where the minimised
//  call bar does (#759): pause and resume, the Read Aloud speed (changeable
//  while it plays) and stop.
//

import SwiftUI

struct ReadAloudPlayerBar: View {
    @ObservedObject var controller: MessageReadAloudController
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            if let reading = controller.nowReading {
                row(reading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: controller.nowReading?.messageID)
    }

    private var status: String {
        if case .preparing = controller.state { return AppLocalization.string("Preparing…") }
        return controller.isPaused ? AppLocalization.string("Paused") : AppLocalization.string("Reading aloud")
    }

    private func row(_ reading: MessageReadAloudController.NowReading) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.conduitAccent)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: reading.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)

            ReadAloudControls(controller: controller)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .conduitGlassControl(cornerRadius: 20, tint: Color.conduitAccent.opacity(0.10))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// Pause or resume, speed and stop.
struct ReadAloudControls: View {
    @ObservedObject var controller: MessageReadAloudController

    private var isPlaying: Bool {
        if case .playing = controller.state { return true }
        return false
    }

    private var isActive: Bool {
        switch controller.state {
        case .preparing, .playing: return true
        case .idle, .failed: return false
        }
    }

    private let buttonSide: CGFloat = 44
    private let symbolFont: Font = .body.weight(.semibold)

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Picker(selection: Binding(
                    get: { controller.speed },
                    set: { speed in
                        Haptics.light()
                        controller.setSpeed(speed)
                    }
                )) {
                    ForEach(ReadAloudSpeed.allCases) { speed in
                        Text(verbatim: speed.label).tag(speed)
                    }
                } label: {
                    Text(AppLocalization.string("Speed"))
                }
            } label: {
                Text(verbatim: controller.speed.label)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minWidth: buttonSide, minHeight: buttonSide)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(AppLocalization.string("Speed")))
            .accessibilityValue(Text(verbatim: controller.speed.label))

            Button {
                Haptics.light()
                controller.togglePause()
            } label: {
                Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                    .font(symbolFont)
                    .frame(minWidth: buttonSide, minHeight: buttonSide)
                    .contentShape(Rectangle())
            }
            .disabled(!isPlaying)
            .accessibilityLabel(controller.isPaused
                ? Text(AppLocalization.string("Resume reading response"))
                : Text(AppLocalization.string("Pause reading response")))

            Button {
                Haptics.medium()
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(symbolFont)
                    .frame(minWidth: buttonSide, minHeight: buttonSide)
                    .contentShape(Rectangle())
            }
            .disabled(!isActive)
            .accessibilityLabel(Text(AppLocalization.string("Stop reading response")))
        }
        .foregroundStyle(Color.conduitAccent)
    }
}
