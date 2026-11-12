//
//  AppState+VoiceConversation.swift
//  Conduit
//
//  Voice conversations and Read Aloud: what can start one, voice
//  preferences, switching voice modes, opening and closing a call, CarPlay,
//  waiting for the transport, and the voice tests in Settings. Moved out
//  of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Voice conversations and Read Aloud

    /// Hermes' surface for a spoken turn: its note asks for plain, short,
    /// speakable prose in the model input only. The same send also marks
    /// `voice_turn`, so Hermes answers on its voice model when one is set.
    static let spokenPromptSurface = "voice-live"

    /// Voice uses the same submission and active-turn interruption policy as
    /// the composer. Keeping this seam here prevents audio UI from inferring
    /// request state from transcript timing.
    func submitVoiceTranscript(_ transcript: String) async -> Bool {
        // Said while the connection is coming back from a drop (a car
        // losing signal): the turn, and a yes or no in it, wait for the
        // connection rather than fail (#1060).
        await waitForTransportIfDropped()
        // A yes or no to the one card waiting answers it first (Hermes can't
        // approve for the user); Hermes then hears the words and how it went.
        await answerWaitingBySpeech(transcript)
        // Marks this exact text as a spoken turn for the prompt.submit it
        // reaches, so Hermes asks for a reply meant to be read aloud. A typed
        // send interleaving on another text never matches.
        spokenSubmissionText = transcript
        defer { spokenSubmissionText = nil }
        return await submitComposerForCall(text: transcript)
    }

    /// Speech while Hermes thinks: the words steer the running turn, as
    /// the composer's Steer does, whatever the composer's busy mode is.
    /// With no running turn the controller sends them as a new turn; a
    /// failed steer is never resubmitted, so it can't duplicate the words.
    func steerForVoice(_ text: String) async -> VoiceSteerOutcome {
        // A yes or no to the approval the running turn waits on (or another
        // card waiting) answers it, and the turn goes on from there.
        // Mid-reconnect, wait for the chat to be back first (#1060).
        await waitForTransportIfDropped()
        if await answerWaitingBySpeech(text) { return .steered }
        switch turnState {
        case .running:
            return await steer(text, surfacesFailure: false) ? .steered : .failed
        case .idle, .unsupportedGateway:
            return .noRunningTurn
        case .synchronizing, .reconnecting:
            // The turn may still be running server-side: don't start a
            // second one with the user's words.
            return .failed
        }
    }

    /// Stops the authoritative Hermes turn when a spoken stop command,
    /// barge-in, or Voice orphan cancellation wins the race with model
    /// generation. Reports whether the cancellation succeeded.
    func interruptForVoice() async -> Bool {
        await cancelCurrent()
    }

    /// Any cancel of the open chat's turn (Voice's, the composer's Stop,
    /// /stop, a send that replaces the turn) notes it first, so a Voice
    /// conversation never hears it again (`takeVoiceEventAfterCancel`).
    /// Only a turn the chat shows running is cancelled, so only that one is
    /// noted. The socket may know the chat by any of its ids: those its
    /// listing gives (chats or cron chats) and those a resume admitted, as
    /// `eventBelongsToActiveSession` takes them.
    func noteRunningTurnBeforeCancel(in sessionId: String) {
        guard isBusy else { return }
        let client = self.client
        let lookup: (String) -> Int? = runningTurnGenerationLookup ?? { client?.runningTurnGeneration(for: $0) }
        func names(_ session: SessionSummary) -> Bool {
            session.id == sessionId || session.alternateIds.contains(sessionId)
        }
        let summary = sessions.first(where: names) ?? cronSessions.first(where: names)
        var ids = [sessionId] + (summary.map { [$0.id] + $0.alternateIds } ?? [])
        if let reconciliation, reconciliation.acceptedSessionIDs.contains(sessionId) {
            ids += reconciliation.acceptedSessionIDs.sorted()
        }
        guard let generation = ids.compactMap(lookup).max() else { return }
        noteVoiceCancelledTurn(sessionId: sessionId, generation: generation)
    }

    /// Holds that turn's later events back from Voice (`takeVoiceEventAfterCancel`).
    func noteVoiceCancelledTurn(sessionId: String, generation: Int) {
        voiceCancelledTurns[sessionId] = generation
        lastVoiceCancelNoteWrite += 1
        voiceCancelNoteWrites[sessionId] = lastVoiceCancelNoteWrite
    }

    /// A chat's note and the write that made it, as a cancel found them.
    struct VoiceCancelNote: Equatable {
        let generation: Int?
        let write: Int?
    }

    func voiceCancelNote(in sessionId: String) -> VoiceCancelNote {
        VoiceCancelNote(generation: voiceCancelledTurns[sessionId], write: voiceCancelNoteWrites[sessionId])
    }

    /// A cancel that failed puts back the note it found, since that turn
    /// still runs, but only while the note is still the one it left
    /// (`write`, the write that stood after it noted): another cancel of
    /// the chat that noted meanwhile keeps its note, even one naming the
    /// same turn.
    func restoreVoiceCancelNote(in sessionId: String, to note: VoiceCancelNote, ifStill write: Int?) {
        guard voiceCancelNoteWrites[sessionId] == write else { return }
        voiceCancelledTurns[sessionId] = note.generation
        voiceCancelNoteWrites[sessionId] = note.write
    }

    /// The turn a cancel actually stopped. A stale generation makes the
    /// cancel read the chat again and stop the turn Hermes names there:
    /// newer than the one noted before it, lower when this socket's number
    /// was too high (a stale refusal corrects it), or the only one known
    /// when this socket never saw it start. The note becomes that turn, so
    /// its words stay held and the next turn's are not.
    /// `wasRunning`: whether the chat showed a turn running before the
    /// cancel; a chat that wasn't notes nothing. `write`: the chat's note as
    /// this cancel left it; one another cancel wrote meanwhile is theirs.
    func noteVoiceStoppedTurn(sessionId: String, generation: Int?, wasRunning: Bool, ifStill write: Int?) {
        guard wasRunning, let generation, voiceCancelNoteWrites[sessionId] == write,
              generation != voiceCancelledTurns[sessionId] else { return }
        noteVoiceCancelledTurn(sessionId: sessionId, generation: generation)
    }

    /// What Voice hears of the stream event being handled, given the turn
    /// a cancel noted: nil for that turn's words (or an earlier turn's), by
    /// the execution generation the event names; an event of a later turn
    /// ends the watch, clearing the chat's notes (hence "take": call it once
    /// per event, as `notifyVoiceAssistant` does). Such a turn can stream a few words after its cancel,
    /// and once the next question owns the chat they'd be taken as its
    /// reply (#1696). Events a resume held keep their number for the
    /// replay. An event that reaches Voice belongs to the open chat (its
    /// aliases included), so the watch holds while that chat is open, under
    /// whichever id it now goes by; each chat keeps its own note, so a
    /// cancel elsewhere doesn't end it. Only the session authority numbers
    /// turns, so on `hermes dashboard` nothing is noted or held.
    ///
    /// The words are held (`.started`, `.delta`, `.interim`), and the
    /// turn's end (its completion, failure or interruption) reaches Voice
    /// as an end with no words: a conversation still waiting on it (stopped from the chat, not by
    /// Voice) finishes what it already said and listens again, as after any
    /// reply, without speaking or writing the rest the user stopped; one
    /// already waiting on the next question ignores it until that
    /// question's reply starts, so the stopped turn never fails or ends
    /// that wait.
    private func takeVoiceEventAfterCancel(_ event: VoiceAssistantEvent) -> VoiceAssistantEvent? {
        guard let generation = handledStreamEventGeneration else { return event }
        // The open chat can hold a note under each of its ids (Voice's
        // cancel names the open chat, the composer's its runtime id): the
        // newest one counts, and a later turn ends them all.
        let notes = voiceCancelledTurns.filter { $0.key == activeSessionId || eventBelongsToActiveSession($0.key) }
        guard let cancelled = notes.values.max() else { return event }
        guard generation <= cancelled else {
            notes.keys.forEach {
                voiceCancelledTurns[$0] = nil
                voiceCancelNoteWrites[$0] = nil
            }
            return event
        }
        switch event {
        case .completed, .failed, .interrupted: return .completed(sessionID: event.sessionID, content: nil)
        default: return nil
        }
    }

    /// Who speaks Classic voice replies for the active profile.
    var voiceSpeechOutput: VoiceSpeechOutput {
        .resolved(chosen: voiceSpeechOutputChoice, snapshot: voiceCapabilitySnapshot)
    }

    /// `fallsBackToOnDeviceSpeech`: a Hermes reply that fails before any
    /// audio is spoken on this iPhone instead. Settings' speech test turns it
    /// off, because it checks the Hermes provider itself.
    /// `profile`: another profile on this host to speak as (a group room's
    /// bot); nil is the active one. Whether read aloud is offered, and
    /// whether Hermes or this iPhone speaks, still follow the active
    /// profile's Voice settings.
    func makeVoiceGateway(fallsBackToOnDeviceSpeech: Bool = true, profile: String? = nil) -> HermesVoiceGateway? {
        guard let dashboardTicketBridge, let connection else { return nil }
        return HermesVoiceGateway(
            bridge: dashboardTicketBridge,
            baseURL: connection.baseUrl,
            profile: profile ?? activeProfile,
            profileParameter: notifierPlugin.dashboardProfileParameter,
            speechOutput: { [weak self] in self?.voiceSpeechOutput ?? .onDevice },
            makeOnDeviceSpeech: { onStart, onPCM16 in OnDeviceSpeechStream(onStart: onStart, onPCM16: onPCM16) },
            fallsBackToOnDeviceSpeech: fallsBackToOnDeviceSpeech
        )
    }

    /// What stops the classic Voice conversation from starting, as a cause
    /// the phone and CarPlay can each name with where to fix it.
    var voiceSetupIssue: VoiceSetupIssue? {
        if !isConnected { return .notConnected }
        if !isVoiceEnabled { return .voiceOff }
        if voiceTranscriptionMode == .appleOnDevice, !appleSpeechAvailability.canAttemptRecognition {
            switch appleSpeechAvailability {
            case .permissionDenied:
                return .speechRecognitionDenied
            case .unsupported(let localeIdentifier):
                return .speechRecognitionUnsupported(locale: localeIdentifier)
            case .ready, .permissionRequired:
                break
            }
        }
        if voiceTranscriptionMode == .hermes, !voiceCapabilitySnapshot.supportsTranscription {
            return .noSpeechToText(detail: voiceCapabilitySnapshot.unavailableReason)
        }
        if voiceSpeechOutput == .hermes, !voiceCapabilitySnapshot.supportsSpeech {
            return .noTextToSpeech
        }
        return nil
    }

    var voiceUnavailableReason: String? { voiceSetupIssue?.message }

    var canStartVoiceConversation: Bool { voiceUnavailableReason == nil }

    /// The phone's voice entry points (composer mic, Siri/intents that open
    /// the sheet): Gemini Live brings its own speech in and out, so it only
    /// needs a connection (the host's plugin is checked, and any refusal
    /// reported, when the sheet opens). CarPlay routes to Gemini Live on its
    /// own; classic-only surfaces (suspension restore, provider tests) keep
    /// `voiceUnavailableReason`.
    var phoneVoiceUnavailableReason: String? {
        if isQwenLiveEnabled || isGeminiLiveEnabled || isGPTLiveEnabled || isGrokLiveEnabled || isLocalLiveEnabled {
            return isConnected ? nil : VoiceSetupIssue.notConnected.message
        }
        return voiceUnavailableReason
    }

    var canStartPhoneVoiceConversation: Bool { phoneVoiceUnavailableReason == nil }

    /// Whether the composer offers its voice button (in the trailing slot it
    /// shares with send). Voice the user turned off for this profile is not
    /// offered, so an empty composer shows the action button instead
    /// (#194); a switch never touched reads as on. While enabled, the button stays and shows its
    /// disabled state for transient or provider problems. This reads the
    /// persisted per-profile preference rather than `isVoiceEnabled`, which
    /// is reset while a connection re-establishes (the button must not blink
    /// out then) and lags a profile switch until capabilities reload. The
    /// key is scoped to the current connection, so this only bridges
    /// reconnects to the same gateway (with no connection the key falls back
    /// to a "disconnected" bucket, but no composer is shown then). Re-renders
    /// ride `activeProfile` and the `isVoiceEnabled` publish in
    /// `setVoiceEnabled` and the first setup in `refreshVoiceCapabilities`,
    /// the only writers of the persisted key.
    var showsComposerVoiceButton: Bool {
        persistedVoiceEnabled(profile: activeProfile) || isQwenLiveEnabled || isGeminiLiveEnabled || isGPTLiveEnabled || isGrokLiveEnabled || isLocalLiveEnabled
    }

    /// The active profile's saved Voice switch, which Settings > Voice
    /// shows: `isVoiceEnabled` is false while Conduit isn't connected,
    /// and a switch shown off then reads as turned off. With no connection
    /// there is no server to read it for (the "disconnected" key is never
    /// written), so it falls back to `isVoiceEnabled`.
    var activeProfileVoiceSwitch: Bool {
        connection == nil ? isVoiceEnabled : persistedVoiceEnabled(profile: activeProfile)
    }

    /// The profile's saved Voice switch. Voice is on out of the box, so a
    /// switch never touched reads as on; only the user turns it off.
    private func persistedVoiceEnabled(profile: String) -> Bool {
        let key = voiceEnabledPreferenceKey(profile: profile)
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    /// TTS-only availability for read aloud: a connected gateway with voice
    /// enabled and a ready speech provider. Deliberately does not require
    /// transcription, mic permission, or Apple Speech — a profile with TTS
    /// but no STT must still be able to read responses aloud.
    var readAloudUnavailableReason: String? {
        readAloudCapabilityUnavailableReason ?? readAloudAudioBusyReason
    }

    /// Read Aloud never plays over a call or the microphone (issue 1770):
    /// the call's microphone would hear it as the user talking (its echo
    /// cancelling knows only its own voice), and two voices would talk at
    /// once. A tap is refused rather than ending the call; the live modes
    /// and Classic stop Read Aloud as they open, and dictation or a voice
    /// message taking the microphone ends it (onTakenOverByCapture).
    var readAloudAudioBusyReason: String? {
        if isCallHoldingAudio {
            return AppLocalization.string("Read aloud can't play during a call.")
        }
        if VoiceAudioSessionCoordinator.shared.hasCaptureOwner {
            return AppLocalization.string("Read aloud can't play while the microphone is in use.")
        }
        return nil
    }

    /// A call holds the audio: Classic or a live mode (open or minimised),
    /// or a call from Hermes. The speech test isn't a call: Read Aloud
    /// takes over from it.
    var isCallHoldingAudio: Bool {
        showVoiceSheet || isLiveVoiceCallActive || voiceConversationController.hasConversationSession
            || minimisedLiveVoice != nil || isNativeHermesCallActive
            || VoiceAudioSessionCoordinator.shared.isInNativeCall
    }

    /// Whether this profile's Hermes can read aloud at all; the gateway is
    /// kept only while it can.
    private var readAloudCapabilityUnavailableReason: String? {
        // Opening a stream needs the dashboard bridge; while it is absent
        // (mid sign-out, before the connection lands) disable the button
        // instead of failing at tap time. Mirrors makeVoiceGateway().
        guard dashboardTicketBridge != nil, connection != nil else {
            return AppLocalization.string("Read aloud needs a connection to Hermes. Wait for Conduit to reconnect, then try again.")
        }
        return MessageReadAloudController.unavailableReason(
            isConnected: isConnected,
            isVoiceEnabled: isVoiceEnabled,
            snapshot: voiceCapabilitySnapshot,
            speechOutput: voiceSpeechOutput
        )
    }

    /// Chat bubble entry point for manual read aloud. Toggling the active
    /// message stops it without touching the gateway; starting a different
    /// message takes over from whatever is playing.
    func toggleReadAloud(message: ChatMessage) {
        // The saved copy is read-only and has no gateway to speak through.
        guard offlineChatPresentation == nil else { return }
        toggleReadAloud(messageID: message.id, content: message.content)
    }

    /// A group room message read aloud. Its id is the room's and the
    /// event's, so it can never be taken for a chat message. With Hermes
    /// speaking, a bot's message is read with its own profile's voice
    /// (`memberProfile`); a profile Hermes can't speak for falls back to
    /// this iPhone's voice, as any failed Hermes read does.
    func toggleRoomReadAloud(eventID: String, text: String, memberProfile: String? = nil) {
        guard let roomID = activeRoomSurface?.room.roomID else { return }
        toggleReadAloud(
            messageID: Self.roomReadAloudID(roomID: roomID, eventID: eventID),
            content: text,
            speakingAs: memberProfile
        )
    }

    static func roomReadAloudID(roomID: String, eventID: String) -> String {
        "room:\(roomID):\(eventID)"
    }

    /// The profile a read aloud speaks as besides the active one: a room
    /// bot's own, or nil when none was given or it is the active profile.
    static func readAloudSpeaker(_ requested: String?, activeProfile: String) -> String? {
        guard let profile = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty,
              profile.caseInsensitiveCompare(activeProfile) != .orderedSame else { return nil }
        return profile
    }

    /// The profile a kept read aloud gateway speaks as: the bot it last
    /// spoke as while the profile active then still is, else the active one.
    static func readAloudKeptProfile(
        speaker: (profile: String, activeProfile: String)?,
        activeProfile: String
    ) -> String {
        guard let speaker, speaker.activeProfile == activeProfile else { return activeProfile }
        return speaker.profile
    }

    /// Read replies aloud (notifier issue 674): the open chat's turn is
    /// read as it streams, as a voice turn's is spoken.
    private func followReplyAloud(_ event: VoiceAssistantEvent) {
        messageReadAloudController.followReply(event) { [weak self] in
            self?.readyAutomaticReadAloud(roomID: nil, speakingAs: nil) ?? false
        }
    }

    /// Read replies aloud in the open group room: each bot message that
    /// arrived since `old`, read one after another in its bot's voice. Not
    /// the messages the room's first read brings, which were there before.
    func readNewRoomMessagesAloud(after old: GroupRoomReplay) {
        let replay = activeRoomReplay
        guard ReadRepliesAloud.isOn(defaults), !replay.roomID.isEmpty, replay.roomID == old.roomID,
              let surface = activeRoomSurface, surface.room.roomID == replay.roomID else { return }
        // The room's first read isn't read aloud. A room hosted elsewhere
        // (a copy) never marks its log read; its opening tail does instead,
        // so the first message an empty copy gets is read.
        let firstReadDone = surface.copy == nil ? activeRoomLogRead == replay.roomID : activeRoomCopyTailRead
        guard firstReadDone else { return }
        let roomID = replay.roomID
        for event in replay.memberMessages(since: old) {
            let profile = GroupRoomTurns.speaker(of: event, members: surface.room.members)?.profile
            let messageID = Self.roomReadAloudID(roomID: roomID, eventID: event.id)
            let content = GroupMessageParts(event.messageText ?? "").text
            if let queued = roomReadAloudQueueOverride {
                queued(messageID, content)
                continue
            }
            messageReadAloudController.enqueue(messageID: messageID, content: content) { [weak self] in
                self?.readyAutomaticReadAloud(roomID: roomID, speakingAs: profile) ?? false
            }
        }
    }

    /// Whether Read replies aloud may start reading now, in the open chat
    /// (`roomID` nil) or that room, with the gateway ready for the speaker.
    /// Silent when it can't: the speaker button says why.
    private func readyAutomaticReadAloud(roomID: String?, speakingAs: String?) -> Bool {
        guard ReadRepliesAloud.isOn(defaults), readAloudUnavailableReason == nil else { return false }
        if let roomID {
            guard activeRoomSurface?.room.roomID == roomID else { return false }
        } else {
            // A room over the chat, or the chat's saved copy, isn't the chat.
            guard activeRoomSurface == nil, offlineChatPresentation == nil else { return false }
        }
        let speaker = Self.readAloudSpeaker(speakingAs, activeProfile: activeProfile)
        if !readAloudGateway(isCurrentFor: speaker ?? activeProfile) {
            assignReadAloudGateway(speakingAs: speaker)
        }
        // As a tap does: a speech test still speaking gives way.
        voiceConversationController.stop()
        return true
    }

    func toggleReadAloud(messageID: String, content: String, speakingAs: String? = nil) {
        if messageReadAloudController.isActiveMessage(messageID) {
            messageReadAloudController.stop()
            return
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let reason = readAloudUnavailableReason {
            errorMessage = reason
            return
        }
        // The capability refresh keeps the gateway current; this covers the
        // gap before the next refresh has run — including right after a
        // profile switch or re-login, when a stale gateway may still be set.
        // A bot's message speaks as its profile; anything else as the
        // active one, which also takes back a gateway a bot left behind.
        let speaker = Self.readAloudSpeaker(speakingAs, activeProfile: activeProfile)
        if !readAloudGateway(isCurrentFor: speaker ?? activeProfile) {
            assignReadAloudGateway(speakingAs: speaker)
        }
        // Mutual exclusion (reverse of runVoiceTTSTest): the voice
        // controller and read aloud each own their own playback instance,
        // so a speech test still speaking must stop before the manual
        // stream opens — otherwise both engines play at once. A call is
        // never ended here: readAloudUnavailableReason refuses the tap.
        voiceConversationController.stop()
        messageReadAloudController.toggle(messageID: messageID, content: content)
    }

    func refreshVoiceCapabilities() async {
        let profile = activeProfile
        guard isConnected, let bridge = dashboardTicketBridge else {
            voiceCapabilitySnapshot = .unavailable
            isVoiceEnabled = false
            voiceConversationController.setGateway(nil)
            refreshReadAloudGateway()
            return
        }
        installVoiceAssistantObserverIfNeeded()
        let enabledKey = voiceEnabledPreferenceKey(profile: profile)
        // Voice is on out of the box: a profile whose switch was never
        // touched starts with it on, and with defaults that need nothing
        // installed (below). A switch the user turned off stays off.
        let isFirstVoiceSetup = defaults.object(forKey: enabledKey) == nil
        isVoiceEnabled = persistedVoiceEnabled(profile: profile)
        appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
        let service = HermesVoiceConfigurationService(
            requester: voiceCapabilityRequesterForTesting ?? bridge,
            profile: profile,
            profileParameter: { [weak self] in self?.notifierPlugin.dashboardProfileParameter ?? "profile" }
        )
        await service.reload()
        guard profile == activeProfile, bridge === dashboardTicketBridge else { return }
        if isFirstVoiceSetup, defaults.object(forKey: enabledKey) == nil {
            defaults.set(true, forKey: enabledKey)
            await applyFirstVoiceSetupDefaults(profile: profile, service: service)
            guard profile == activeProfile, bridge === dashboardTicketBridge else { return }
        }
        voiceCapabilitySnapshot = service.snapshot.capability
        var preferences = loadVoiceProfilePreferences(profile: profile)
        // PR #159 authority, enforced centrally: while the controller owns a
        // live Voice session for THIS profile, its live mute is
        // authoritative over the persisted blob. Ownership is keyed on the
        // profile the session was opened for, so a refresh for another
        // profile never carries a live mute across ownership.
        if voiceConversationController.hasLiveVoiceSession,
           voiceControllerSessionProfile == profile {
            preferences.outputMuted = voiceConversationController.isOutputMuted
        }
        voiceTranscriptionMode = preferences.resolvedTranscriptionMode
        voiceSpeechOutputChoice = preferences.speechOutput
        continuousConversationEnabled = preferences.continuousConversation
        keepVoiceListeningWhenLocked = preferences.keepListeningWhenLocked ?? false
        voicePushToTalkEnabled = preferences.pushToTalk ?? false
        chatVoiceButtonOverride = preferences.chatVoiceButton
        voiceConversationController.setProfilePreferences(preferences)
        // Voice settings shows this profile's unsaved calls, not the last one's.
        publishVoiceCallSaveStatus()
        refreshVoiceControllerGateway()
        refreshReadAloudGateway()
    }

    /// Voice settings' one-switch defaults (VoiceSetupDefaults), applied
    /// once to a profile whose Voice was never set up, so classic Voice
    /// (and CarPlay) work without a visit to Settings: speech to text on
    /// this iPhone unless a choice was saved. Replies are spoken on this
    /// iPhone unless the profile has its own Hermes voice
    /// (`voiceSpeechOutput`), so Hermes' speech config is never changed.
    /// Everything is written for `profile`, the one `service` reads, even
    /// if the active profile changes while Hermes answers.
    private func applyFirstVoiceSetupDefaults(profile: String, service: HermesVoiceConfigurationService) async {
        guard configuredLiveVoiceEngine(profile: profile) == nil else { return }
        var preferences = loadVoiceProfilePreferences(profile: profile)
        let plan = VoiceSetupDefaults.plan(
            transcriptionModeChosen: preferences.transcriptionMode != nil,
            appleSpeechAvailability: appleSpeechAvailability,
            snapshot: service.snapshot
        )
        if plan.usesOnDeviceTranscription {
            // Speech Recognition is asked for on the first utterance. The
            // caller loads these preferences into the controller next.
            preferences.transcriptionMode = .appleOnDevice
            saveVoiceProfilePreferences(preferences, profile: profile)
        }
    }

    @discardableResult
    func setVoiceEnabled(_ enabled: Bool) async -> Bool {
        guard isConnected else { return false }
        defaults.set(enabled, forKey: voiceEnabledPreferenceKey(profile: activeProfile))
        isVoiceEnabled = enabled
        refreshVoiceControllerGateway()
        refreshReadAloudGateway()
        if !enabled {
            voiceConversationController.stop()
            suspendedVoiceConversation = nil
            voiceSheetShouldAutoListen = false
            voiceControllerSessionProfile = nil
            showVoiceSheet = false
            clearClassicVoiceCards()
        }
        return true
    }

    @discardableResult
    func setVoiceTranscriptionMode(_ mode: VoiceTranscriptionMode) async -> Bool {
        appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
        if mode == .appleOnDevice, !appleSpeechAvailability.canAttemptRecognition {
            switch appleSpeechAvailability {
            case .permissionDenied:
                errorMessage = SystemSettings.worded(
                    iPhone: AppLocalization.string("Speech Recognition permission was denied. Please enable it in Settings > Conduit > Speech Recognition."),
                    iPad: AppLocalization.string("Speech Recognition permission was denied. Please enable it in Settings > Conduit > Speech Recognition."),
                    mac: AppLocalization.string("Speech Recognition permission was denied. Please enable it in System Settings → Privacy & Security → Speech Recognition.")
                )
            case .unsupported(let localeIdentifier):
                let localeName = Locale.current.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
                errorMessage = AppLocalization.string("On-device speech recognition is not available for \(localeName).")
            default:
                errorMessage = AppLocalization.string("On-device speech recognition is unavailable.")
            }
            return false
        }
        if mode == .appleOnDevice {
            let permissionResult = await voiceConversationController.requestOnDeviceTranscriptionPermissions()
            appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
            guard permissionResult.passed else {
                errorMessage = permissionResult.message
                return false
            }
        }
        updateActiveProfileVoicePreferences { $0.transcriptionMode = mode }
        voiceTranscriptionMode = mode
        refreshVoiceControllerGateway()
        refreshReadAloudGateway()
        return true
    }

    /// Who speaks Classic voice replies for the active profile. The
    /// gateways read it per reply, so the next reply uses the new choice.
    @discardableResult
    func setVoiceSpeechOutput(_ output: VoiceSpeechOutput) -> Bool {
        guard isConnected else { return false }
        updateActiveProfileVoicePreferences { $0.speechOutput = output }
        voiceSpeechOutputChoice = output
        refreshVoiceControllerGateway()
        // A fresh gateway: the kept one may have given up on Hermes speech,
        // which must not outlast the person choosing it again.
        refreshReadAloudGateway(rebuild: true)
        return true
    }

    @discardableResult
    func setContinuousConversation(_ enabled: Bool) -> Bool {
        guard isConnected else { return false }
        updateActiveProfileVoicePreferences { $0.continuousConversation = enabled }
        continuousConversationEnabled = enabled
        return true
    }

    /// "Keep listening when locked". Applies the next time Conduit leaves
    /// the foreground; a conversation already suspended stays suspended.
    @discardableResult
    func setKeepVoiceListeningWhenLocked(_ enabled: Bool) -> Bool {
        guard isConnected else { return false }
        updateActiveProfileVoicePreferences { $0.keepListeningWhenLocked = enabled ? true : nil }
        keepVoiceListeningWhenLocked = enabled
        return true
    }

    /// Push to talk in Classic voice (#886): hold to speak, release to
    /// send. Applies from the next press, also in an open conversation.
    @discardableResult
    func setVoicePushToTalk(_ enabled: Bool) -> Bool {
        guard isConnected else { return false }
        updateActiveProfileVoicePreferences { $0.pushToTalk = enabled ? true : nil }
        voicePushToTalkEnabled = enabled
        return true
    }

    /// The big button beside a chat's composer on this profile: nil
    /// follows the app's choice (Settings > Appearance).
    @discardableResult
    func setChatVoiceButtonOverride(_ action: ChatVoiceButtonAction?) -> Bool {
        guard isConnected else { return false }
        updateActiveProfileVoicePreferences { $0.chatVoiceButton = action?.rawValue }
        chatVoiceButtonOverride = action?.rawValue
        return true
    }

    /// Saves an edited spoken Stop phrase list for the active profile and
    /// reapplies it to the live controller. Goes through the shared Voice
    /// preference mutation path so live mute is preserved exactly per
    /// `hasLiveVoiceSession` authority (PR #159 semantics). Entries are
    /// canonicalized (trimmed, de-duplicated, blanks dropped) at this
    /// boundary — the single write authority for phrase lists.
    /// Returns false when nothing was saved (disconnected).
    @discardableResult
    func setSpokenStopPhrases(_ phrases: [String]) -> Bool {
        // Same connected-state policy as `setContinuousConversation`: the
        // preference key is gateway-qualified, and a write while
        // disconnected would land in the orphaned "disconnected" namespace.
        guard isConnected else { return false }
        updateActiveProfileVoicePreferences {
            $0.spokenStopPhrases = VoiceSpokenCommands.storedPhrases(phrases, builtIns: VoiceSpokenCommandDefaults.stopPhrases)
        }
        return true
    }

    /// Saves an edited spoken End Conversation phrase list. Same contract as
    /// `setSpokenStopPhrases`; an intentionally emptied list persists as
    /// empty and disables that spoken-command category.
    @discardableResult
    func setSpokenEndConversationPhrases(_ phrases: [String]) -> Bool {
        guard isConnected else { return false }
        updateActiveProfileVoicePreferences {
            $0.spokenEndConversationPhrases = VoiceSpokenCommands.storedPhrases(phrases, builtIns: VoiceSpokenCommandDefaults.endConversationPhrases)
        }
        return true
    }

    /// Loads the active profile's preference blob, applies `mutate`, and
    /// reapplies it to the live controller.
    ///
    /// Live `isOutputMuted` is authoritative only while a Voice session is
    /// actually armed (`hasLiveVoiceSession`). Otherwise the controller may
    /// still hold the previous profile's mute until
    /// `refreshVoiceCapabilities()` resyncs, so the loaded profile's
    /// persisted `outputMuted` is left unchanged.
    private func updateActiveProfileVoicePreferences(
        _ mutate: (inout VoiceProfilePreferences) -> Void
    ) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        mutate(&preferences)
        if voiceConversationController.hasLiveVoiceSession {
            preferences.outputMuted = voiceConversationController.isOutputMuted
        }
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        voiceConversationController.setProfilePreferences(preferences)
    }

    /// The profile's live voice mode, in the order a voice launch tries
    /// them; nil when the profile uses classic voice. `gateway` reads it for
    /// a server Conduit isn't connected to yet.
    func configuredLiveVoiceEngine(profile: String, gateway: String? = nil) -> VoiceCallEngine? {
        let preferences = loadVoiceProfilePreferences(profile: profile, gateway: gateway)
        if preferences.geminiLiveEnabled { return .geminiLive }
        if preferences.qwenLiveEnabled { return .qwenLive }
        if preferences.gptLiveEnabled { return .gptLive }
        if preferences.grokLiveEnabled { return .grokLive }
        if preferences.localLiveEnabled { return .localLive }
        return nil
    }

    /// The mode a voice screen's call is in, for its mode menu: the engine
    /// it runs on (nil for classic voice).
    func voiceModeSwitch(for engine: VoiceCallEngine?) -> VoiceModeSwitch {
        // Read only for Local Live: the call screens ask on every redraw.
        let localAgent = engine == .localLive ? isLocalLiveAgent : true
        let current = VoiceModeChoice(engine: engine, localAgent: localAgent)
        return VoiceModeSwitch(current: current, movesOnCurrent: current.engine != engine) { [weak self] choice in
            Task { @MainActor in await self?.switchVoiceMode(to: choice) }
        }
    }

    /// How long a voice screen takes to slide away, so the next mode's
    /// screen isn't presented while the last one is still on its way out.
    static let voiceModeSwitchSheetHandoff: Duration = .milliseconds(450)

    /// The longest a switch waits for a live screen's dismissal to land.
    static let voiceModeSwitchDismissalTimeout: Duration = .milliseconds(1500)

    /// The chat a mode switch starts the new mode in: Classic's open chat,
    /// else the live call's attached chat, else the chat a Local Live call
    /// made for itself (from Home, or after its chat was deleted, issue 1797).
    static func voiceModeSwitchThread(
        classicChat: VoiceThreadTarget?, classicWasOpen: Bool,
        liveThread: VoiceThreadTarget?, localLiveOwnChat: VoiceThreadTarget?,
        isDeleted: (VoiceThreadTarget) -> Bool = { _ in false }
    ) -> VoiceThreadTarget? {
        // An own chat deleted since is gone: the new mode starts with none.
        classicWasOpen ? classicChat : (liveThread ?? localLiveOwnChat.flatMap { isDeleted($0) ? nil : $0 })
    }

    private enum VoiceModeHandoff {
        /// Open the new mode, in this chat.
        case proceed(VoiceThreadTarget?)
        case stop
    }

    /// The first half of a mode switch: the call hangs up, the mode is
    /// saved, and its screen slides away. A second pick meanwhile is
    /// dropped: two switches interleaving could save one mode and open
    /// another. A pick on the new mode's screen is a switch of its own.
    private func handOffVoiceMode(to choice: VoiceModeChoice) async -> VoiceModeHandoff {
        guard !isSwitchingVoiceMode else { return .stop }
        isSwitchingVoiceMode = true
        defer {
            isSwitchingVoiceMode = false
            voiceModeSwitchDismissing = nil
        }
        // Classic voice works in the open chat; a live call in its attached
        // one, or the chat a Local Live call made for itself (from Home, or
        // after its chat was deleted, issue 1797).
        let classicWasOpen = showVoiceSheet
        let thread = Self.voiceModeSwitchThread(
            classicChat: classicWasOpen ? liveVoiceThreadForOpenChat() : nil, classicWasOpen: classicWasOpen,
            liveThread: voiceBackgroundJobSupervisor.liveThread, localLiveOwnChat: localLiveOwnChat,
            isDeleted: { [voiceBackgroundJobSupervisor] in voiceBackgroundJobSupervisor.isDeletedChat($0) }
        )
        let shownLiveScreen: VoiceCallEngine? = showQwenLiveSheet ? .qwenLive
            : showGeminiLiveSheet ? .geminiLive
            : showGPTLiveSheet ? .gptLive
            : showGrokLiveSheet ? .grokLive
            : showLocalLiveSheet ? .localLive
            : nil
        voiceModeSwitchDismissing = shownLiveScreen
        if classicWasOpen || voiceConversationController.hasLiveVoiceSession { closeVoiceConversation() }
        endLiveVoiceCall()
        applyVoiceMode(choice)
        guard isConnected else {
            errorMessage = AppLocalization.string("Reconnect to Hermes to start voice.")
            return .stop
        }
        // Cancelled (a boundary tore the app's state down): nothing starts.
        do {
            if shownLiveScreen != nil {
                // Until the live screen's dismissal lands, with a ceiling.
                let deadline = ContinuousClock.now + Self.voiceModeSwitchDismissalTimeout
                while voiceModeSwitchDismissing != nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
            } else if classicWasOpen {
                try await Task.sleep(for: Self.voiceModeSwitchSheetHandoff)
            }
        } catch {
            return .stop
        }
        // Something else started voice meanwhile (Siri, a call from Hermes).
        guard isConnected, !isVoiceInUse, minimisedLiveVoice == nil else { return .stop }
        // Deleted during the wait: the new mode starts without it.
        return .proceed(thread.flatMap { voiceBackgroundJobSupervisor.isDeletedChat($0) ? nil : $0 })
    }

    /// Picks another voice mode from a call screen. It is saved as the
    /// profile's mode, as Settings > Voice > Voice mode saves it, and the
    /// call hangs up and starts again in the new mode, in the chat it was
    /// working in.
    func switchVoiceMode(to choice: VoiceModeChoice) async {
        guard case .proceed(let thread) = await handOffVoiceMode(to: choice) else { return }
        switch choice.engine {
        case .geminiLive: openGeminiLiveConversation(attachingTo: thread)
        case .qwenLive: openQwenLiveConversation(attachingTo: thread)
        case .gptLive: openGPTLiveConversation(attachingTo: thread)
        case .grokLive: openGrokLiveConversation(attachingTo: thread)
        case .localLive: openLocalLiveConversation(attachingTo: thread)
        case nil:
            // Classic voice talks in the open chat: the call's chat opens
            // first. A call with no chat, or one in a Bot Chat off screen,
            // starts a new conversation, as a new call does.
            var inChat = thread.map { isOpenChat($0) } ?? false
            if let thread, !inChat, thread.profile == nil {
                switch await openSessionOutcome(thread.storedSessionID ?? thread.runtimeSessionID) {
                case .opened: inChat = true
                case .superseded: return
                case .failed:
                    errorMessage = AppLocalization.string("Couldn't open that chat for voice.")
                    return
                }
            }
            let started = await openVoiceConversation(PendingVoiceIntent(
                profile: activeProfile,
                startsFreshConversation: !inChat,
                source: inChat ? .composer : .newCall
            ))
            // Hermes dropped while the chat opened: say so, not nothing.
            if !started, !isVoiceInUse, errorMessage == nil {
                errorMessage = AppLocalization.string("Reconnect to Hermes to start voice.")
            }
        }
    }

    /// Saves `choice` as the profile's voice mode. Turning one live mode on
    /// turns the others off; Classic is every live mode off.
    func applyVoiceMode(_ choice: VoiceModeChoice) {
        switch choice {
        case .classic:
            setQwenLiveEnabled(false)
            setGeminiLiveEnabled(false)
            setGPTLiveEnabled(false)
            setGrokLiveEnabled(false)
            setLocalLiveEnabled(false)
        case .gemini: setGeminiLiveEnabled(true)
        case .qwen: setQwenLiveEnabled(true)
        case .gpt: setGPTLiveEnabled(true)
        case .grok: setGrokLiveEnabled(true)
        case .local:
            setLocalLiveAgent(true)
            setLocalLiveEnabled(true)
        }
    }

    @discardableResult
    func openVoiceConversation(
        _ intent: PendingVoiceIntent,
        widgetLease: WidgetLaunchLease? = nil,
        initialCaptureAuthorization: WidgetInitialCaptureAuthorization? = nil
    ) async -> Bool {
        guard isConnected else { return false }
        // Siri or the Action button naming no profile: the hands-free one.
        let intent = applyingHandsFreeProfile(to: intent)
        guard widgetLease?.isCurrent != false else { return false }
        if widgetLease != nil, isVoiceCallInProgress {
            errorMessage = AppLocalization.string("End the call before starting another voice conversation.")
            return true
        }
        if intent.source != .hermesCall { keepVoiceFromHermesCallCleanup() }
        voiceLaunchesInFlight += 1
        defer {
            voiceLaunchesInFlight -= 1
            scheduleWakeRefresh()
        }
        // The mode is the requested profile's (Siri may name another one).
        let requestedProfile = intent.profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetProfile = requestedProfile.isEmpty ? activeProfile : requestedProfile
        // Live Voice started from a chat's mic, or for a screenshot chat,
        // works in that chat.
        let startsInOpenChat = intent.source == .composer || intent.source == .screenQuestion || intent.source == .hermesCall
        let thread = startsInOpenChat && targetProfile == activeProfile ? liveVoiceThreadForOpenChat() : nil
        var liveEngine = configuredLiveVoiceEngine(profile: targetProfile)
        // Voice from a saved call's row picks that call up: the same row,
        // not another one beside it.
        if liveEngine != nil, targetProfile == activeProfile,
           let callID = Self.savedCallToResume(source: intent.source, openCallID: activeVoiceCallSessionID, canResume: canResumeVoiceCall) {
            return await resumeVoiceCall(sessionID: callID)
        }
        // A call from Hermes opens with its news, which Local Live has no
        // model of its own to say outside agent mode: classic voice takes
        // it. In agent mode its fast model says it (#1376). The call made
        // that choice when it was answered: a live opening waits in
        // pendingHermesCall, and a classic one was queued for classic voice.
        if intent.source == .hermesCall, liveEngine == .localLive, pendingHermesCall == nil {
            liveEngine = nil
        }
        if intent.source == .screenQuestion {
            // The device-test gate: an engine not cleared for screen
            // questions takes them in classic voice.
            liveEngine = ScreenQuestionVoiceRouting.liveEngine(for: liveEngine)
        }
        if let liveEngine {
            if targetProfile != activeProfile {
                if let widgetLease {
                    _ = await switchProfile(to: targetProfile, reusing: nil, widgetLease: widgetLease)
                } else {
                    await switchProfile(to: targetProfile)
                }
                guard widgetLease?.isCurrent != false else { return false }
                guard targetProfile == activeProfile else {
                    errorMessage = AppLocalization.string("Conduit could not open the requested voice profile.")
                    return true
                }
                guard isConnected else { return false }
            }
            switch liveEngine {
            case .geminiLive: return openGeminiLiveConversation(attachingTo: thread, initialCaptureAuthorization: initialCaptureAuthorization)
            case .qwenLive: return openQwenLiveConversation(attachingTo: thread, initialCaptureAuthorization: initialCaptureAuthorization)
            case .gptLive: return openGPTLiveConversation(attachingTo: thread, initialCaptureAuthorization: initialCaptureAuthorization)
            case .grokLive: return openGrokLiveConversation(attachingTo: thread, initialCaptureAuthorization: initialCaptureAuthorization)
            case .localLive: return openLocalLiveConversation(attachingTo: thread, initialCaptureAuthorization: initialCaptureAuthorization)
            }
        }
        // Mutual exclusion: the voice conversation owns playback while its
        // sheet is open, so a read aloud started before must not continue.
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        let outcome = await prepareVoiceConversation(
            profile: intent.profile,
            startsFreshConversation: intent.startsFreshConversation,
            widgetLease: widgetLease
        )
        guard widgetLease?.isCurrent != false else { return false }
        switch outcome {
        case .deferred:
            return false
        case .failed(let message):
            // A rejected attach never presents the Voice sheet: surface the
            // failure through the app-level error path instead.
            errorMessage = message
            return true
        case .handled:
            break
        }
        // Phone presentation: the prepared conversation is shown in the
        // Voice sheet. CarPlay attaches through prepareVoiceConversation /
        // attachToLiveVoiceConversation instead and never mutates
        // these presentation flags.
        showSidebar = false
        voiceConversationController.installInitialWidgetCaptureAuthorization(initialCaptureAuthorization)
        // A connected car shows its voice screen before the sheet's
        // auto-listen opens the microphone.
        CarPlayVoiceCoordinator.shared.conversationStartingOnPhone(in: self)
        // A call muted in CallKit before its voice opened keeps the mic off.
        voiceSheetShouldAutoListen = !(intent.source == .hermesCall && isNativeHermesCallMuted)
        showVoiceSheet = true
        // The sheet is now the presenting Voice surface: re-assert the gate
        // before the sheet's auto-listen runs (with CarPlay absent the gate
        // was false while the sheet was closed).
        reassertVoiceSurfaceGate()
        return true
    }

    /// Outcome of the logical Voice conversation preparation. `.deferred`
    /// means "not connected yet": the phone router keeps the request pending,
    /// and CarPlay settles into its error state. `.handled` means the logical
    /// Voice preparation SUCCEEDED — an existing live conversation was
    /// attached, or a new/continued conversation was armed. `.failed(String)`
    /// means the preparation was REJECTED without arming a usable Voice
    /// conversation (capability unavailable, no session, no gateway, session
    /// creation failed, turn conflict): the message must be surfaced and NO
    /// Voice presentation attached.
    enum VoiceConversationPrepareOutcome: Equatable {
        case deferred
        case handled
        case failed(String)
    }

    /// Prepare/acquire the LOGICAL Voice conversation — capability refresh,
    /// profile selection, session continuation/creation, Voice gateway
    /// installation — with no phone presentation attached. Split out of
    /// `openVoiceConversation` so the CarPlay surface can open Voice through
    /// the exact same checks; the phone flow additionally presents the sheet.
    ///
    /// If a Voice conversation is already live, this re-arms it in place
    /// (fresh gateway on the same session) without clearing the transcript.
    func prepareVoiceConversation(
        profile: String?,
        startsFreshConversation: Bool,
        widgetLease: WidgetLaunchLease? = nil
    ) async -> VoiceConversationPrepareOutcome {
        // The classic conversation (e.g. CarPlay) takes over from Gemini
        // Live: the two voice modes never run at once.
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        if let rawProfile = profile {
            let requestedProfile = rawProfile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !requestedProfile.isEmpty, requestedProfile != activeProfile {
                if let widgetLease {
                    _ = await switchProfile(to: requestedProfile, reusing: nil, widgetLease: widgetLease)
                } else {
                    await switchProfile(to: requestedProfile)
                }
                guard widgetLease?.isCurrent != false else { return .deferred }
            }
            guard requestedProfile.isEmpty || requestedProfile == activeProfile else {
                errorMessage = AppLocalization.string("Conduit could not open the requested voice profile.")
                return .failed(AppLocalization.string("Conduit could not open the requested voice profile."))
            }
        }
        guard isConnected else { return .deferred }
        if voiceConversationController.hasLiveVoiceSession, !startsFreshConversation {
            // Another Voice presentation is attaching to the existing logical
            // conversation (the sheet presentation is the caller's job): no
            // beginVoiceTurn, no transcript reset, no session churn, no
            // in-flight-turn cancellation. This intentionally precedes the
            // generic turn-running rejection — a running turn owned by the
            // shared Voice session is the attachment, not a conflict.
            guard attachToLiveVoiceConversation() else {
                return .failed(voiceUnavailableReason
                    ?? AppLocalization.string("Hermes could not reattach the live voice conversation."))
            }
            return .handled
        }
        if turnState.isRunning {
            guard startsFreshConversation else {
                errorMessage = AppLocalization.string("Stop the current response before starting voice in this conversation.")
                return .failed(AppLocalization.string("Stop the current response before starting voice in this conversation."))
            }
            _ = await interruptForVoice()
            guard widgetLease?.isCurrent != false else { return .deferred }
        }
        await refreshVoiceCapabilities()
        guard widgetLease?.isCurrent != false else { return .deferred }
        guard canStartVoiceConversation else {
            errorMessage = voiceUnavailableReason
            return .failed(voiceUnavailableReason ?? AppLocalization.string("Voice is unavailable."))
        }
        let previousSessionID = activeSessionId
        classicVoiceChatToArchive = nil
        if startsFreshConversation || activeSessionId == nil {
            let created = await createNewSession(widgetLease: widgetLease)
            guard widgetLease?.isCurrent != false else { return .deferred }
            // Only the chat this creation opened, while it is still open,
            // is the call's own: a chat another creation opened meanwhile
            // is neither filed under Voice nor archived with the call.
            let ownChat = created.flatMap { activeSessionId == $0 ? $0 : nil }
            if startsFreshConversation, ownChat == nil {
                errorMessage = AppLocalization.string("Hermes could not create the requested voice conversation.")
                return .failed(AppLocalization.string("Hermes could not create the requested voice conversation."))
            }
            // A chat voice started is filed under Voice; one the user spoke
            // into partway stays a chat.
            if let created = ownChat, created != previousSessionID {
                tagVoiceSessions(Array(knownSessionIDs(for: created)), kind: .classic)
                // Archived when this call ends, like a live call's own row (#1124).
                classicVoiceChatToArchive = (created, activeProfile, activeDashboardID)
            }
        }
        guard let sessionID = activeSessionId, let gateway = makeVoiceGateway() else {
            errorMessage = AppLocalization.string("Hermes could not prepare a voice conversation.")
            return .failed(AppLocalization.string("Hermes could not prepare a voice conversation."))
        }
        // A fresh user-initiated open supersedes any stale suspension (e.g.
        // a descriptor retained across sign-out, or one whose reconciliation
        // task is still in flight): it must never fail-close this new
        // session on a later scene cycle.
        suspendedVoiceConversation = nil
        voiceConversationController.setGateway(gateway)
        voiceConversationController.beginVoiceTurn(sessionID: sessionID)
        voiceControllerSessionProfile = activeProfile
        return .handled
    }

    /// Attach the CALLING presentation (phone Voice sheet, CarPlay surface)
    /// to an ALREADY-LIVE logical Voice conversation. Never restarts a turn,
    /// never clears the transcript, never creates a session, never cancels an
    /// in-flight turn: it re-asserts the presentation-surface gate (the phone
    /// may be locked with a gate left false by an earlier CarPlay-only
    /// disconnect) and re-arms the gateway reference when needed. The
    /// restoration descriptor is retired only AFTER the attach is known to
    /// succeed, so a failed re-arm leaves the phone-restoration path intact.
    @discardableResult
    func attachToLiveVoiceConversation() -> Bool {
        guard voiceConversationController.hasLiveVoiceSession else { return false }
        // Both gates, not just the capture gate: attaching a presentation
        // means the app is on screen too, and an in-flight runtime operation
        // (the next Listen, a provider test) must not be discarded as
        // backgrounded work.
        reassertVoiceSurfaceGate()
        if !voiceConversationController.isGatewayAttached {
            refreshVoiceControllerGateway()
        }
        guard voiceConversationController.isGatewayAttached else { return false }
        suspendedVoiceConversation = nil
        return true
    }

    /// CarPlay surface presented. Re-asserts the Voice gate: the phone scene
    /// may be inactive with a gate left false by an earlier CarPlay-only
    /// disconnect (no scene-phase event fires while the phone is locked, so
    /// nothing else heals it), and the driver's next Listen must be able to
    /// re-arm capture. No-op while the phone scene is active.
    func handleCarPlayVoiceSurfaceActivated() {
        reassertVoiceSurfaceGate()
        recoverTransportForCarPlayIfNeeded(immediately: true)
    }

    /// CarPlay connected while no phone screen is in the foreground. When the
    /// car launched Conduit there is no phone scene at all, so no scene-phase
    /// event ever said the phone isn't on screen, and `isSceneActive` kept
    /// its launch value: CarPlay never re-armed a connection that failed or
    /// dropped, and kept trying to connect until the phone app was opened
    /// (#378). The phone's own `.active` takes over again when it opens.
    func handleCarPlayConnectedWithoutPhoneScreen() {
        guard isSceneActive else { return }
        isSceneActive = false
        publishVoiceRuntimeGates()
        recoverTransportForCarPlayIfNeeded(immediately: true)
    }

    /// CarPlay can connect while the phone is locked with a transport that
    /// died during an earlier background suspension. No scene-phase event
    /// will re-establish it until the phone is unlocked, so the CarPlay
    /// surface starts the reconnect itself. A restore or connect already in
    /// flight owns the flow and is left alone.
    /// While the phone scene is active its own foreground recovery owns the
    /// transport, so CarPlay never arms a competing cycle then.
    ///
    /// Only the CarPlay connect itself retries immediately. Every other
    /// re-arm (scene dips, a deferred Voice prepare, a failed restore) goes
    /// through the normal backoff, so a drive with frequent phone-scene
    /// transitions cannot keep a dead gateway on a fixed 0.1s retry.
    func recoverTransportForCarPlayIfNeeded(immediately: Bool = false) {
        // A conversation kept running while locked relies on the transport
        // the same way, and so do a call the Apple Watch started and a call
        // from Hermes answered in CallKit, and a shortcut send running.
        guard isCarPlayVoiceSurfaceActive || isLockedVoiceSurfaceActive || isWatchVoiceCallActive || isNativeHermesCallActive
                || isShortcutSendRunning,
              !isSceneActive,
              connection != nil,
              !isConnected,
              !isConnecting else { return }
        scheduleReconnect(immediately: immediately, purpose: chatResumePurposeForDisconnect())
    }

    /// Conduit's screen in the car came back to the front: the driver
    /// returned from Maps or a podcast app. With another app on the car's
    /// screen and nothing playing, iOS may have suspended Conduit, and the
    /// chat connection can have died without Conduit noticing (#1060). A
    /// dead connection reconnects now rather than at the end of its
    /// backoff, and one that still looks open is pinged at once.
    func handleCarPlaySceneWillEnterForeground() {
        guard isCarPlayVoiceSurfaceActive, !isSceneActive else { return }
        if isConnected {
            // The same check a network change runs: ping, close if
            // unanswered. A socket that turns out dead reconnects through
            // the ordinary backoff (at most 8 s while CarPlay is up).
            client?.networkPathChanged()
        } else {
            reconnectNowForWaitingVoice("CarPlay on screen")
        }
    }

    /// Reconnects at once, skipping the backoff, because someone is waiting
    /// on Hermes right now: the driver back on Conduit's car screen, or a
    /// call's request to Hermes (#1060). The backoff paces a gateway that is
    /// down; a phone that lost signal on the road has usually got it back
    /// by the time someone asks. A cycle already under way is left alone.
    func reconnectNowForWaitingVoice(_ reason: String) {
        guard connection != nil, !isConnected, !isConnecting,
              !signInRequiredForReconnect, canRunTransportRecovery else { return }
        // Without a usable network path no attempt can work: the parked
        // cycle reconnects the moment the path comes back.
        guard deviceConditions().pathSatisfied else { return }
        let purpose = recoverySequence.takeQueuedReconnectPurpose() ?? chatResumePurposeForDisconnect()
        reconnectTask?()
        reconnectTask = nil
        // The backoff count stays: one spoken request after another against
        // a gateway that is down must not keep resetting it. A connect
        // resets it.
        noteConnectionStep(reason)
        scheduleReconnect(immediately: true, purpose: purpose)
    }

    /// The client for a call's request to Hermes (start a job, send to a
    /// chat, steer a reply). While the chat connection is coming back from a
    /// drop, as it often is in a car, the request reconnects at once and
    /// waits, up to `voiceRequestConnectionWait`, for the reconnect to have
    /// resumed the chat as well: until then Hermes may no longer hold the
    /// chat's runtime and refuses what is sent to it. That replaces failing
    /// on the spot and leaving the call to say it didn't go through (#1060).
    /// A wait that runs out throws `notConnected`. A connect already under
    /// way (a cold launch's too) is waited for the same way. Without one
    /// nothing waits, and the result is what it was before: the current
    /// client, or `notConnected` without one.
    func clientForVoiceRequest() async throws -> HermesClient {
        if await waitForTransportIfDropped(), !isConnected || isResumingAfterDrop {
            throw HermesError.notConnected
        }
        guard let client else { throw HermesError.notConnected }
        return client
    }

    /// `clientForVoiceRequest`'s wait on its own, for Classic voice's turns
    /// and steers, which go through the composer. True when it waited.
    @discardableResult
    func waitForTransportIfDropped() async -> Bool {
        await checkQuietTransportOffScreen()
        guard voiceRequestWaitsForTransport else { return false }
        reconnectNowForWaitingVoice("Voice request waiting")
        await awaitTransportForVoiceRequest(timeout: voiceRequestConnectionWait)
        return true
    }

    /// How long a socket may have been quiet before a request made off
    /// screen checks it first.
    static let quietTransportCheckAfter: TimeInterval = PollCadence.keepaliveForeground

    /// A request to Hermes made while Conduit is off screen: in the car, on
    /// a locked phone, in a Watch call or a call from Hermes. iOS may have
    /// held Conduit suspended before CarPlay or the call woke it, and a
    /// socket that died meanwhile still looks open: a GPT-Live call started
    /// in the car ran (it starts over plain HTTP), but every request it
    /// handed Hermes waited on the dead socket until it timed out, and the
    /// call said Hermes wasn't available, while one started on the phone
    /// worked (#1362). The phone coming on screen pings first and
    /// reconnects a socket that doesn't answer; so does this, for a socket
    /// that has been quiet, and the request then waits for the reconnect as
    /// after any drop. Requests at the same time share one check. A
    /// shortcut send off screen checks the same way before it sends (#2164).
    func checkQuietTransportOffScreen() async {
        if let running = quietTransportCheckTask {
            await running.value
            return
        }
        guard !isSceneActive, isConnected, let client else { return }
        let check = Task { @MainActor [weak self] in
            guard let self, await self.quietTransportLiveness(client) == false else { return }
            self.noteConnectionStep("Connection check before a voice request")
            // The close reaches handleDisconnect a moment later.
            await self.awaitConnectionDropped(timeout: .seconds(2))
        }
        quietTransportCheckTask = check
        await check.value
        quietTransportCheckTask = nil
    }

    private func awaitConnectionDropped(timeout: Duration) async {
        guard isConnected else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await connected in self.$isConnected.values where !connected { return }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    /// A drop is under way that a reconnect from here can repair: the socket
    /// is down and coming back, or it is back and the reconnect is still
    /// resuming the chat.
    private var voiceRequestWaitsForTransport: Bool {
        guard connection != nil, canRunTransportRecovery, !signInRequiredForReconnect else { return false }
        if !isConnected { return isConnecting || turnState == .reconnecting }
        return isResumingAfterDrop
    }

    /// The socket is back and the reconnect is still resuming the chat. An
    /// ordinary chat open also syncs, but its turn state isn't stale: a
    /// request then goes on as before rather than wait on it.
    private var isResumingAfterDrop: Bool {
        turnState == .reconnecting || (turnState == .synchronizing && turnStateIsStale)
    }

    private func awaitTransportForVoiceRequest(timeout: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                let states = self.$isConnected.combineLatest(self.$isConnecting, self.$turnState).values
                for await (connected, connecting, turn) in states {
                    if connected, turn != .reconnecting, turn != .synchronizing { return }
                    // Signed out, or sign-in needed: no reconnect is coming.
                    if self.connection == nil || self.signInRequiredForReconnect { return }
                    // A cycle that ended without arming the next one hands
                    // off to the backoff. scheduleReconnect keeps its own
                    // gate on who may reconnect.
                    if !connected, !connecting, self.reconnectTask == nil {
                        self.scheduleReconnect(purpose: self.chatResumePurposeForDisconnect())
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Called by the CarPlay coordinator when the CarPlay Voice surface goes
    /// away. While the phone scene is active, the phone still presents Voice
    /// and nothing is touched. With no active Voice surface left, this is
    /// exactly the PR #161 background boundary: the sheet's presentation
    /// intent (if any) survives through the suspended descriptor, and a
    /// CarPlay-only conversation is released — never treated as spoken
    /// Goodbye, which is Close.
    func handleCarPlayVoiceSurfaceRemoved() {
        guard !hasActiveVoiceSurface else { return }
        // State the app-foreground fact at the boundary that owns the
        // decision instead of relying on the caller having called
        // `setCarPlayVoiceSurfaceActive(false)` first: `fence()` in the CarPlay
        // coordinator reaches here directly. Re-stating an unchanged value is
        // free, and suspension itself only writes the capture gate.
        voiceConversationController.setApplicationForegroundActive(hasForegroundApplicationSurface)
        suspendVoiceConversationForBackground()
    }

    /// Drops the Classic voice card sheet and anything waiting to join it,
    /// so nothing from the old call, account or profile shows afterwards.
    func clearClassicVoiceCards() {
        classicVoiceCard = nil
        classicVoiceCardParts = []
    }

    func closeVoiceConversation() {
        // Explicit Close (button, swipe, spoken End Conversation) beats any
        // lifecycle suspension: the conversation is not restorable.
        suspendedVoiceConversation = nil
        voiceSheetShouldAutoListen = false
        clearClassicVoiceCards()
        // Live-mute persistence obeys the PR #159 authority rule: the
        // controller's mute wins only for the profile that owns the session.
        // A same-profile close that arrives after the controller was
        // already torn down (e.g. audio interruption) still persists; a
        // close arriving after a profile flip (the sheet's deferred
        // onDismiss) persists nothing.
        if voiceConversationController.hasLiveVoiceSession
            || voiceControllerSessionProfile == activeProfile {
            var preferences = loadVoiceProfilePreferences(profile: activeProfile)
            preferences.outputMuted = voiceConversationController.isOutputMuted
            saveVoiceProfilePreferences(preferences, profile: activeProfile)
        }
        voiceConversationController.endVoiceSession()
        voiceControllerSessionProfile = nil
        archiveClassicVoiceChatIfStarted()
        // A Hermes call's opening never carries over to a later conversation.
        voiceBackgroundJobSupervisor.clearCallOpening()
        showVoiceSheet = false
        // Close removes the surface the capture gate was open for, so restate
        // the gates from bookkeeping rather than leaving the capture gate
        // stale-true until the next lifecycle event (a CarPlay-presented
        // conversation keeps it open by the same rule).
        reassertVoiceSurfaceGate()
    }

    private func archiveClassicVoiceChatIfStarted() {
        guard let chat = classicVoiceChatToArchive else { return }
        classicVoiceChatToArchive = nil
        guard chat.dashboardID == activeDashboardID else { return }
        // The tag was written under every id the chat had; the host's row
        // answers to its stored one, so the rest are refused and ignored.
        let ids = Array(knownSessionIDs(for: chat.chatID))
        Task { [weak self] in
            await self?.voiceTagChain?.value
            for id in ids {
                guard let self, self.activeDashboardID == chat.dashboardID else { return }
                do {
                    if try await self.voiceHistoryClient.archiveClassicChat(sessionID: id, profile: chat.profile) { return }
                } catch {
                    // An older plugin has no route, and a chat nobody spoke in has no row.
                    Self.voiceHistoryLog.debug("Archiving a Classic voice chat failed: \(LogRedaction.describing(error), privacy: .public)")
                }
            }
        }
    }

    func runVoiceASRTest() async -> VoiceProviderTestResult {
        guard !isCallHoldingAudio else { return .failure(AppLocalization.string("End the call to run this test.")) }
        // Ownership first: a playing read aloud must release its standalone
        // lease before anything else in this flow — the capability refresh
        // and the capture test itself — can claim conversation-capture
        // ownership or await the network.
        messageReadAloudController.stop()
        await refreshVoiceCapabilities()
        guard isVoiceEnabled else {
            return .failure(AppLocalization.string("Enable voice for this profile before running a speech-to-text test."))
        }
        guard selectedTranscriptionIsAvailable else {
            return .failure(voiceUnavailableReason ?? AppLocalization.string("The selected speech-to-text option is unavailable."))
        }
        guard let gateway = makeVoiceGateway() else {
            return .failure(AppLocalization.string("Conduit could not connect this test to the selected profile."))
        }
        voiceConversationController.setGateway(gateway)
        let result = await voiceConversationController.runTranscriptionTest()
        appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
        refreshVoiceControllerGateway()
        return result
    }

    func runVoiceTTSTest() async -> VoiceProviderTestResult {
        // The call's microphone would hear the test as the user (issue 1770).
        guard !isCallHoldingAudio else { return .failure(AppLocalization.string("End the call to run this test.")) }
        await refreshVoiceCapabilities()
        guard isVoiceEnabled else {
            return .failure(AppLocalization.string("Enable voice for this profile before running a speech playback test."))
        }
        guard voiceSpeechOutput != .hermes || voiceCapabilitySnapshot.supportsSpeech else {
            return .failure(voiceUnavailableReason ?? AppLocalization.string("The selected assistant speech provider is unavailable."))
        }
        guard let gateway = makeVoiceGateway(fallsBackToOnDeviceSpeech: false) else {
            return .failure(AppLocalization.string("Conduit could not connect this test to the selected profile."))
        }
        // The speech test speaks through the voice controller's own playback
        // instance (the same AVSpeech infrastructure read aloud uses, but a
        // separate instance), so the test and a still-playing message would
        // otherwise both produce audio. AppState enforces mutual exclusion in
        // both directions; toggleReadAloud stops this controller in turn.
        messageReadAloudController.stop()
        voiceConversationController.setGateway(gateway)
        return await voiceConversationController.runSpeechTest(
            text: AppLocalization.string("Conduit voice is ready for this profile.")
        )
    }

    private func voiceEnabledPreferenceKey(profile: String) -> String {
        let gateway = connection?.baseUrl.lowercased() ?? "disconnected"
        return "conduit.voice.enabled.v1.\(gateway).\(profile)"
    }

    /// `gateway` is the server to read for when it isn't the connection's.
    private func voicePreferencesKey(profile: String, gateway: String? = nil) -> String {
        let server = (gateway ?? connection?.baseUrl)?.lowercased() ?? "disconnected"
        return "conduit.voice.preferences.v1.\(server).\(profile)"
    }

    private var selectedTranscriptionIsAvailable: Bool {
        switch voiceTranscriptionMode {
        case .hermes: return voiceCapabilitySnapshot.supportsTranscription
        case .appleOnDevice: return appleSpeechAvailability.canAttemptRecognition
        // Whether the server answers is learnt per utterance and in Settings' test.
        case .speechServer: return true
        }
    }

    func refreshVoiceControllerGateway() {
        voiceConversationController.setGateway(
            isVoiceEnabled && selectedTranscriptionIsAvailable ? makeVoiceGateway() : nil
        )
    }

    /// Keeps the read aloud gateway in step with capability refreshes without
    /// churning a live instance: swapping the gateway mid-playback would stop
    /// the message. A kept gateway must still match the active profile AND
    /// the live dashboard bridge — a gateway built against an invalidated or
    /// rotated bridge (re-login, profile switch) is rebuilt instead.
    private var readAloudGatewayIsCurrent: Bool {
        readAloudGateway(isCurrentFor: Self.readAloudKeptProfile(speaker: readAloudSpeaker, activeProfile: activeProfile))
    }

    private func readAloudGateway(isCurrentFor profile: String) -> Bool {
        guard let gateway = messageReadAloudController.gateway,
              let bridge = dashboardTicketBridge else { return false }
        // A gateway built before the plugin listed dashboard-profiles names the wrong parameter.
        let parameter = (gateway as? HermesVoiceGateway)?.profileParameter ?? notifierPlugin.dashboardProfileParameter
        return gateway.profile == profile && readAloudGatewayBridge === bridge
            && parameter == notifierPlugin.dashboardProfileParameter
    }

    /// `speakingAs`: a room bot's profile, so Hermes reads its message with
    /// that profile's own voice. Nil is the active profile.
    private func assignReadAloudGateway(speakingAs profile: String? = nil) {
        readAloudSpeaker = profile.map { ($0, activeProfile) }
        if let factory = readAloudGatewayFactoryForTesting {
            messageReadAloudController.setGateway(factory(profile ?? activeProfile))
        } else {
            messageReadAloudController.setGateway(makeVoiceGateway(profile: profile))
        }
        readAloudGatewayBridge = dashboardTicketBridge
    }

    func refreshReadAloudGateway(rebuild: Bool = false) {
        if readAloudCapabilityUnavailableReason != nil {
            messageReadAloudController.setGateway(nil)
            readAloudGatewayBridge = nil
            readAloudSpeaker = nil
            return
        }
        guard rebuild || !readAloudGatewayIsCurrent else { return }
        assignReadAloudGateway()
    }

    func loadVoiceProfilePreferences(profile: String, gateway: String? = nil) -> VoiceProfilePreferences {
        guard let data = defaults.data(forKey: voicePreferencesKey(profile: profile, gateway: gateway)),
              let preferences = try? JSONDecoder().decode(VoiceProfilePreferences.self, from: data) else {
            return VoiceProfilePreferences()
        }
        return preferences
    }

    /// The active profile's persisted Voice preferences, for display surfaces
    /// (settings editors seed from this). Mutations go through the dedicated
    /// setters, never by writing this value back.
    var activeProfileVoicePreferences: VoiceProfilePreferences {
        loadVoiceProfilePreferences(profile: activeProfile)
    }

    func saveVoiceProfilePreferences(_ preferences: VoiceProfilePreferences, profile: String) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: voicePreferencesKey(profile: profile))
    }

    /// The active profile's Voice preferences as stored, for the
    /// preferences shared with other devices (#1089); nil when never set.
    var storedActiveVoicePreferencesData: Data? {
        defaults.data(forKey: voicePreferencesKey(profile: activeProfile))
    }

    /// Takes Voice preferences another device saved for this profile. Never
    /// during a call (the sync holds them back until it ends). The rest of
    /// Voice catches up as on a profile switch.
    func adoptSyncedVoicePreferences(_ preferences: VoiceProfilePreferences) {
        var preferences = preferences
        // Blobs merged across devices can carry several live engines on;
        // keep the one configuredLiveVoiceEngine reads, in its order.
        if preferences.geminiLiveEnabled { preferences.qwenLiveEnabled = false }
        if preferences.geminiLiveEnabled || preferences.qwenLiveEnabled { preferences.gptLiveEnabled = false }
        if preferences.geminiLiveEnabled || preferences.qwenLiveEnabled || preferences.gptLiveEnabled { preferences.grokLiveEnabled = false }
        if preferences.geminiLiveEnabled || preferences.qwenLiveEnabled || preferences.gptLiveEnabled || preferences.grokLiveEnabled { preferences.localLiveEnabled = false }
        objectWillChange.send()
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        voiceConversationController.setProfilePreferences(preferences)
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
        Task { await refreshVoiceCapabilities() }
    }

    /// A call or Voice conversation is open: synced preferences wait.
    var holdsSyncedVoicePreferences: Bool {
        showVoiceSheet || showQwenLiveSheet || showGeminiLiveSheet || showGPTLiveSheet || showGrokLiveSheet || showLocalLiveSheet
            || hasActiveVoiceSurface || voiceConversationController.hasLiveVoiceSession
    }

    private func installVoiceAssistantObserverIfNeeded() {
        guard voiceAssistantObserverID == nil else { return }
        voiceAssistantObserverID = addVoiceAssistantObserver { [weak self] event in
            self?.voiceConversationController.receiveAssistantEvent(event)
        }
    }

    /// Subscribes to the same authenticated socket events that establish turn
    /// state. Voice playback therefore never infers completion from visible
    /// transcript content or rendering cadence.
    @discardableResult
    func addVoiceAssistantObserver(_ observer: @escaping @MainActor (VoiceAssistantEvent) -> Void) -> UUID {
        let id = UUID()
        voiceAssistantObservers[id] = observer
        return id
    }

    func removeVoiceAssistantObserver(_ id: UUID) {
        voiceAssistantObservers.removeValue(forKey: id)
    }

    func notifyVoiceAssistant(_ event: VoiceAssistantEvent) {
        guard let heard = takeVoiceEventAfterCancel(event) else { return }
        voiceAssistantObservers.values.forEach { $0(heard) }
        followReplyAloud(heard)
    }
}
