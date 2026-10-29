//
//  UndeliveredDictationNotice.swift
//  Conduit
//
//  A Hermes dictation whose words never came, above the composer: its
//  recording is still on this iPhone (DictationClipInbox), so Retry sends
//  it again and Delete lets it go. Shown until one of them is tapped,
//  after a restart too.
//

import SwiftUI

struct UndeliveredDictationNotice: View {
    @ObservedObject var inbox: DictationClipInbox
    /// The host and profile the composer dictates for; nil offers nothing.
    let identity: String?
    /// Recordings whose words are already on their way to a draft.
    var delivering: Set<UUID> = []
    let onRetry: (DictationClip) -> Void

    @State private var confirmingDelete: DictationClip?

    var body: some View {
        let clips = inbox.offered(for: identity, delivering: delivering)
        if !clips.isEmpty {
            VStack(spacing: 0) {
                ForEach(clips) { clip in
                    row(clip)
                }
            }
            .confirmationDialog(
                AppLocalization.string("Delete this recording? Its words haven't been transcribed."),
                isPresented: Binding(
                    get: { confirmingDelete != nil },
                    set: { if !$0 { confirmingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: confirmingDelete
            ) { clip in
                Button(AppLocalization.string("Delete"), role: .destructive) {
                    inbox.delivered(clip.id)
                }
                Button(AppLocalization.string("Cancel"), role: .cancel) {}
            }
        }
    }

    private func row(_ clip: DictationClip) -> some View {
        let message = AppLocalization.string("Your \(VoiceMessage.durationLabel(clip.duration)) dictation wasn't transcribed. Its recording is saved.")
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if inbox.retrying.contains(clip.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel(AppLocalization.string("Transcribing"))
            } else {
                Button {
                    onRetry(clip)
                } label: {
                    Text(AppLocalization.string("Retry"))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityValue(Text(message))
                Button {
                    confirmingDelete = clip
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Delete"))
                .accessibilityValue(Text(message))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityIdentifier("composer.undeliveredDictation.\(clip.id.uuidString)")
    }
}
