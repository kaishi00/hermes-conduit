//
//  AppState+VoicePhoto.swift
//  Conduit
//
//  A photo taken with a voice screen's Camera. It waits on the
//  conversation's chat as Ask Hermes About Screen's screenshot does
//  (`setPendingScreenshot`), so the next turn sent there carries it to
//  Hermes, and a live call hears quietly that it's there. Gemini Live and
//  Qwen Live also get it on their own socket and can answer about it at
//  once; GPT-Live, Grok Live and Local Live take no pictures, so they send
//  questions about it to Hermes. Classic voice's every turn goes to Hermes,
//  which sees it with the next one.
//

import UIKit

extension AppState {
    /// The voice screens' Camera: puts the photo on the conversation's
    /// chat. Returns what to tell the user when it couldn't, nil when it's
    /// there.
    func addVoicePhoto(_ image: UIImage) async -> String? {
        let limit = AttachmentSizeLimit.clampedMegabytes(
            UserDefaults.standard.integer(forKey: AttachmentSizeLimit.preferenceKey)
        )
        // The model's small copy is made off the main thread with the photo.
        let wantsFrame = livePhotoController != nil
        let (outcome, frame) = await Task.detached(priority: .userInitiated) {
            (ComposerBar.stageCapturedPhoto(image, limitMegabytes: limit),
             wantsFrame ? LiveVoicePhotoFrame.jpeg(from: image) : nil)
        }.value
        let photo: Attachment
        switch outcome {
        case .staged(let staged):
            photo = staged
        case .tooLarge(let name):
            return AttachmentSizeLimit.tooLargeMessage(names: [name], megabytes: limit)
        case .failed:
            return AppLocalization.string("Conduit couldn't save the photo. Try again.")
        }
        if isLiveVoiceCallActive {
            return await addPhotoToLiveCall(photo, frame: frame)
        }
        // Classic voice talks in the chat on screen: its next turn carries it.
        guard isVoiceInUse, let sessionID = activeSessionId, activeRoomSurface == nil else {
            Self.deleteStagedScreenshot(photo)
            return Self.voicePhotoNoChatMessage
        }
        setPendingScreenshot(photo, forSession: sessionID, kind: .photo)
        return nil
    }

    private static var voicePhotoNoChatMessage: String {
        AppLocalization.string("The photo goes to the chat this conversation is in, and Conduit couldn't open it. Open the chat and try again.")
    }

    /// The running call's conversation when its model takes pictures
    /// (Gemini, Qwen); nil for every other call.
    private var livePhotoController: GeminiLiveConversationController? {
        if isGeminiLiveActive { return geminiLiveController }
        if isQwenLiveActive { return qwenLiveController }
        return nil
    }

    /// Only a turn sent from the chat on screen carries an attachment, so
    /// the call's chat comes on screen first, as for a screenshot. A call
    /// with no chat yet, or one whose chat can't open, keeps nothing.
    private func addPhotoToLiveCall(_ photo: Attachment, frame: Data?) async -> String? {
        guard let thread = voiceBackgroundJobSupervisor.liveThread else {
            Self.deleteStagedScreenshot(photo)
            return AppLocalization.string("The photo goes to the call's chat. Ask for something first, so the call has a chat, then add it.")
        }
        if thread.profile == nil, !isOpenChat(thread) {
            _ = await openSession(thread.storedSessionID ?? thread.runtimeSessionID)
        }
        // The call may have ended, or moved on, while the chat opened.
        guard isLiveVoiceCallActive, voiceBackgroundJobSupervisor.liveThread == thread,
              isOpenChat(thread), let sessionID = activeSessionId else {
            Self.deleteStagedScreenshot(photo)
            return Self.voicePhotoNoChatMessage
        }
        setPendingScreenshot(photo, forSession: sessionID, kind: .photo)
        // The note goes first, so a send that fails at once corrects it.
        let controller = frame == nil ? nil : livePhotoController.flatMap { $0.canShowPhoto ? $0 : nil }
        voiceBackgroundJobSupervisor.notePhotoShared(attachmentURI: photo.uri, seenByModel: controller != nil)
        if let controller, let frame {
            controller.showPhoto(frame) { [weak self] in
                self?.voiceBackgroundJobSupervisor.notePhotoMissedModel(attachmentURI: photo.uri)
            }
        }
        return nil
    }
}
