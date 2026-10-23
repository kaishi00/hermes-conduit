//
//  AppState+VoiceMessage.swift
//  Conduit
//
//  Sending a recorded voice message (VoiceMessageRecorder) in the open
//  chat: the audio goes as a file attachment, like any file the composer
//  attaches, and the prompt carries what was said.
//

import Foundation
import UniformTypeIdentifiers

extension AppState {
    /// Why a voice message can't go right now, or nil when it can.
    var voiceMessageUnavailableReason: String? {
        switch composerAction(hasText: true, hasAttachments: true) {
        case .send:
            return nil
        case .steer, .interrupt, .queue, .stop:
            return AppLocalization.string("Voice messages send once the reply has finished.")
        case .unavailable:
            return AppLocalization.string("Voice messages send once Conduit is connected to the chat.")
        }
    }

    /// Starts a voice message in the open chat.
    func startVoiceMessage() async {
        let recorder = VoiceMessageRecorder.shared
        guard !recorder.isActive else { return }
        await recorder.start(
            sessionID: activeSessionId,
            hermesGateway: { [weak self] in self?.makeVoiceGateway() }
        )
    }

    /// Sends the recorder's finished message in the chat it was made for.
    /// Returns false when it couldn't: the recording stays, with a reason,
    /// so it can be sent again or thrown away.
    @discardableResult
    func sendRecordedVoiceMessage() async -> Bool {
        let recorder = VoiceMessageRecorder.shared
        // The composer's own limit (Settings), as for any attached file.
        let limitMegabytes = AttachmentSizeLimit.clampedMegabytes(
            UserDefaults.standard.object(forKey: AttachmentSizeLimit.preferenceKey) as? Int
                ?? AttachmentSizeLimit.defaultMegabytes
        )
        guard let recording = recorder.recording, !recorder.isSending else { return false }
        recorder.isSending = true
        defer { recorder.isSending = false }
        guard recorder.sessionID == activeSessionId else {
            // Another chat opened meanwhile: not this one's message.
            recorder.cancel()
            return false
        }
        if let reason = voiceMessageUnavailableReason {
            recorder.errorMessage = reason
            return false
        }
        let context = composerSubmissionContext()
        let name = recording.url.lastPathComponent
        let source = recording.url
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                let staged = try AttachmentStaging.destination(for: name)
                try FileManager.default.copyItem(at: source, to: staged)
                return AttachmentStaging.finishStaging(
                    fileAt: staged,
                    name: name,
                    type: UTType(filenameExtension: "m4a"),
                    limitMegabytes: limitMegabytes
                )
            } catch {
                return AttachmentStaging.StagedImport.failed(name)
            }
        }.value
        let attachment: Attachment
        switch outcome {
        case .staged(let staged):
            attachment = staged
        case .tooLarge:
            recorder.errorMessage = AppLocalization.string("This voice message is larger than your attachment size limit.")
            return false
        case .failed:
            recorder.errorMessage = AppLocalization.string("Couldn't prepare the voice message.")
            return false
        }
        // Still this chat's, and nobody threw it away while it was copied.
        guard recorder.recording == recording, activeSessionId == context.sessionID else {
            if let staged = URL(string: attachment.uri) { try? FileManager.default.removeItem(at: staged) }
            return false
        }
        let text = VoiceMessage.promptText(duration: recording.duration, transcript: recording.transcript)
        Haptics.medium()
        let sent = await submitComposer(text: text, attachments: [attachment], context: context)
        guard sent else {
            if recorder.recording == recording {
                recorder.errorMessage = AppLocalization.string("Couldn't send the voice message. Try again.")
            }
            Haptics.error()
            return false
        }
        if recorder.recording == recording { recorder.finishSending() }
        return true
    }
}
