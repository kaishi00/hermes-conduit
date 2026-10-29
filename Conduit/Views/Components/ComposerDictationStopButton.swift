import SwiftUI

/// Send's place while a dictation runs (#1309): a wide Stop, so the words
/// land in the draft to be looked over before anything goes. Send comes
/// back once they're in. Both composers and the full editor show it.
struct ComposerDictationStopButton: View {
    @ObservedObject var dictation: ComposerDictationService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var identifier = "composer.dictation.stop"

    var body: some View {
        let face = dictation.slotFace
        let waits = face == .transcribing
        Button {
            dictation.tapSlot()
        } label: {
            // Named by accessibilityTitle below.
            faceLabel(face)
                .font(.caption.weight(.semibold))
                .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: face)
                .foregroundStyle(waits ? Color.secondary : Color.white)
                // One width for every face, so the row keeps its layout.
                .frame(width: 112, height: ComposerBar.controlSize)
                .padding(.horizontal, 4)
                .contentShape(ComposerBar.controlHitShape)
        }
        .buttonStyle(.plain)
        // Its last words are on their way: stopping now would lose them.
        .disabled(waits)
        .conduitGlassControl(
            cornerRadius: ComposerBar.controlSize / 2,
            tint: waits ? Color.primary.opacity(0.025) : Color.red,
            prominent: !waits,
            interactive: !waits
        )
        .accessibilityShowsLargeContentViewer {
            Label {
                accessibilityTitle(face)
            } icon: {
                Image(systemName: symbol(face))
            }
        }
        .accessibilityLabel(accessibilityTitle(face))
        .accessibilityHint(face == .stop || face == .finishing
            ? AppLocalization.string("Stops dictating; the words stay in the message")
            : "")
        .accessibilityIdentifier(identifier)
    }

    private func faceLabel(_ face: ComposerDictation.SlotFace) -> some View {
        HStack(spacing: 6) {
            if face == .transcribing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbol(face))
            }
            title(face)
                // Longer translations shrink rather than wrap or widen
                // the row.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func title(_ face: ComposerDictation.SlotFace) -> Text {
        switch face {
        case .stop: return Text(AppLocalization.string("Stop"))
        case .cancelStart: return Text(AppLocalization.string("Cancel"))
        case .finishing: return Text(AppLocalization.string("Done"))
        case .transcribing: return Text(AppLocalization.string("Transcribing"))
        }
    }

    private func symbol(_ face: ComposerDictation.SlotFace) -> String {
        switch face {
        case .stop: return "stop.fill"
        case .cancelStart: return "xmark"
        case .finishing: return "checkmark"
        case .transcribing: return "hourglass"
        }
    }

    private func accessibilityTitle(_ face: ComposerDictation.SlotFace) -> Text {
        switch face {
        case .stop: return Text(AppLocalization.string("Stop dictation"))
        case .cancelStart: return Text(AppLocalization.string("Cancel dictation"))
        case .finishing: return Text(AppLocalization.string("Done"))
        case .transcribing: return Text(AppLocalization.string("Transcribing"))
        }
    }
}
