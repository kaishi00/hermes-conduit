//
//  VoiceMessageBar.swift
//  Conduit
//
//  The composer while a voice message is recorded, then previewed: throw
//  it away, stop, listen back and send. Shown in place of the message
//  field; the typed draft waits underneath.
//

import SwiftUI

struct VoiceMessageBar: View {
    @ObservedObject var recorder: VoiceMessageRecorder
    /// Sends the recorded message. A closure rather than AppState, so the
    /// bar doesn't redraw with every AppState change.
    let send: () -> Void

    private static let controlSize: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                discardButton
                switch recorder.phase {
                case .recorded:
                    if let recording = recorder.recording {
                        preview(recording)
                        sendButton
                    }
                default:
                    VoiceMessageRecordingRow(meter: recorder.meter, phase: recorder.phase, isHeld: recorder.isHeld)
                    if !recorder.isHeld {
                        stopButton
                    }
                }
            }
            if recorder.phase == .recorded, let words = recorder.recording?.transcript, !words.isEmpty {
                Text(verbatim: words)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 6)
                    .accessibilityLabel(AppLocalization.string("Transcript: \(words)"))
            }
            if let message = recorder.errorMessage {
                Text(verbatim: message)
                    .scaledFont(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var discardButton: some View {
        Button {
            Haptics.light()
            recorder.cancel()
        } label: {
            Image(systemName: "trash")
                .scaledFont(.body.weight(.semibold))
                .conduitFixedGlyph()
                .foregroundStyle(.secondary)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.isSending)
        .accessibilityLabel(AppLocalization.string("Delete voice message"))
    }

    private var stopButton: some View {
        Button {
            Haptics.light()
            Task { await recorder.stop() }
        } label: {
            Group {
                if recorder.phase == .recording {
                    Image(systemName: "stop.fill")
                        .scaledFont(.body.weight(.semibold))
                        .conduitFixedGlyph()
                        .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: Self.controlSize, height: Self.controlSize)
            .background(Color.red, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.phase != .recording)
        .accessibilityLabel(AppLocalization.string("Stop recording"))
    }

    private func preview(_ recording: VoiceMessageRecorder.Recording) -> some View {
        InlineAudioClipView(
            id: "voice-message-preview:\(recording.url.lastPathComponent)",
            name: AppLocalization.string("Voice message, \(VoiceMessage.durationLabel(recording.duration))"),
            filename: recording.url.lastPathComponent,
            style: .card,
            opening: false,
            load: {
                let url = recording.url
                return await Task.detached { try? Data(contentsOf: url) }.value
            },
            openFull: {},
            showsOpenButton: false
        )
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            Group {
                if recorder.isSending {
                    ProgressView().tint(Color.black.opacity(0.82))
                } else {
                    Image(systemName: "arrow.up")
                        .scaledFont(.body.weight(.bold))
                        .conduitFixedGlyph()
                        .foregroundStyle(Color.black.opacity(0.82))
                }
            }
            .frame(width: Self.controlSize, height: Self.controlSize)
            .background(Color.conduitAccent, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.isSending)
        .accessibilityLabel(AppLocalization.string("Send voice message"))
    }
}

/// The recording's red dot, time and moving level bars. Observes only the
/// meter, so its many updates redraw this row and nothing else.
private struct VoiceMessageRecordingRow: View {
    @ObservedObject var meter: VoiceMessageRecorder.Meter
    let phase: VoiceMessageRecorder.Phase
    let isHeld: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(phase == .recording ? 1 : 0.4)
            Text(verbatim: VoiceMessage.durationLabel(meter.elapsed))
                .scaledFont(.subheadline.monospacedDigit().weight(.semibold))
            if isHeld {
                Text(AppLocalization.string("Release to send, slide away to cancel"))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else if phase == .starting {
                Text(AppLocalization.string("Starting…"))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                levelBars
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.string("Recording voice message, \(VoiceMessage.durationLabel(meter.elapsed))"))
    }

    private var levelBars: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(paddedLevels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 3, height: 4 + 18 * CGFloat(level))
            }
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }

    /// Always the full row of bars, quiet ones first until it fills.
    private var paddedLevels: [Float] {
        let missing = VoiceMessageRecorder.levelCount - meter.levels.count
        return Array(repeating: 0, count: max(0, missing)) + meter.levels
    }
}
