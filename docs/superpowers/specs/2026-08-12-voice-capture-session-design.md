# Voice Capture Session Recovery Design

## Context

On an iPhone 16 Pro Max running iOS 27, the Voice settings action **Record ASR** fails before transcription with:

> The operation couldn't be completed. (com.apple.coreaudio.avfaudio error -10868.)

The same failure occurs when the selected transcription provider is Hermes or **On this iPhone**, which places the failure in the shared microphone-capture path rather than in either speech-to-text provider. The user reports that the same device and OS worked before build 120.

The build history narrows what this repository can explain. There is no retained build-113 snapshot; the earliest source snapshot is build 114. `AVAudioCaptureService`, `AVSpeechPlaybackService`, `VoiceConversationController`, the microphone permission description, and the audio-session setup are byte-for-byte unchanged from build 114 through the current build 126 source. Build 120 itself changes the local-network URL policy and build number, not voice or audio code. The first audio-adjacent source change after build 119 is the custom `CHHapticEngine` added to the build-126 train after build 125. The current haptic engine is created with `CHHapticEngine()`; Apple documents that this form creates its own audio session when no session is supplied. A separate haptic audio session can contend with the voice capture session during `AVAudioEngine` startup. The capture path also asks the hardware for a preferred 16 kHz rate and enables both Bluetooth HFP and A2DP even though it converts the route's actual input format to 16 kHz after capture.

## Goals

- Make voice capture start reliably after response haptics have run or been interrupted.
- Keep ASR output at the existing canonical 16 kHz mono PCM16 format for both Hermes and Apple on-device transcription.
- Let `AVAudioEngine` use the active route's actual hardware input format and perform conversion after capture.
- Keep bidirectional Bluetooth microphone routing available while avoiding an output-only A2DP preference in the voice session.
- Preserve the existing UIKit haptic fallback and response lifecycle behavior.
- Add deterministic tests for the audio-session and haptic-session policies.
- Provide route/format diagnostics when the device audio engine still rejects startup.

## Non-goals

- Changing Hermes or Apple speech-recognition APIs.
- Changing the 16 kHz WAV/PCM contract sent to transcription providers.
- Rewriting the voice conversation state machine.
- Adding a separate recording implementation just for the settings test.
- Supporting audio capture from a Bluetooth A2DP-only input; A2DP is output-only and cannot provide the microphone path required by voice capture.
- Claiming physical iOS 27 validation from the available iOS 26.5 simulator.

## Root-cause hypothesis

The leading hypothesis for the current build is the custom Core Haptics engine owning a separate audio session; this does not prove that the regression began exactly at build 120. Apple’s Core Haptics API explicitly distinguishes an engine associated with an existing `AVAudioSession` from an engine that creates its own session, and documents audio-session interruption as a haptic-engine stop reason. When the voice capture service later changes category, activates the session, and starts its input audio unit, the independent haptic session can leave the audio graph in a format or interruption state that produces `-10868`. If build 125 can be reproduced on the same device and succeeds while build 126 fails, that makes this hypothesis strong; if build 125 also fails, the route-native capture hardening becomes the primary path and haptics is not the release-boundary explanation.

The capture code has a second fragility: it requests 16 kHz as the hardware preferred rate even though the code already supports conversion from the route’s native format. Device hardware may select a different actual rate, and voice-chat input routes are not required to accept the requested preference. Removing that unnecessary hardware constraint makes the capture path tolerant of the actual iPhone route without changing the provider format.

## Architecture

### Shared haptic audio-session ownership

Update `Haptics` so its custom engine is created with `AVAudioSession.sharedInstance()` and is explicitly configured as haptics-only. The existing stopped/reset handlers remain responsible for clearing the active pattern and will discard an engine stopped by an audio-session interruption so the next response creates a clean engine. The UIKit fallback continues to handle unsupported hardware or engine-start failures.

This keeps Conduit’s haptic and voice features on one audio-session boundary instead of allowing Core Haptics to create an independent session. It does not make the haptic engine responsible for configuring the voice category; `AVAudioCaptureService` remains the owner of microphone activation.

### Route-native microphone capture

Introduce a small value-oriented `VoiceAudioSessionConfiguration` used by `AVAudioCaptureService` and unit tests. Its capture policy is:

- category: `.playAndRecord`;
- mode: `.voiceChat`;
- options: `.allowBluetoothHFP` and `.defaultToSpeaker`;
- no preferred hardware sample rate;
- canonical conversion output: 16,000 Hz, one channel, PCM16.

`configureSession()` applies the category and activates the shared session without forcing the hardware rate. `startEngine()` verifies that input is available, queries the active input node’s actual format, and installs the existing nil-format tap. `AVAudioConverter` continues to resample that route-native Float32 input into the canonical 16 kHz PCM16 buffer.

If the session or input format is unavailable, or `AVAudioEngine.start()` throws, the service records a concise user-facing failure and logs the route name, session sample rate, input sample rate, channel count, and error code for device diagnostics. Logs must not include audio contents, credentials, or transcript text.

### Provider boundary

No provider-specific branching is added to capture. `VoiceConversationController.runTranscriptionTest()` remains responsible for recording, finishing the WAV, and then choosing Hermes or Apple transcription. A failure before `finishUtterance()` therefore remains a capture failure visible in the settings status, and both provider choices exercise the same repaired path.

## Error handling and lifecycle

- Starting capture after a haptic response uses the shared session and route-native format.
- A haptic engine interrupted by microphone activation is discarded; future haptics fall back or recreate cleanly.
- `AVAudioCaptureService.stop()` continues to remove the input tap, stop the engine, reset conversion state, and deactivate the shared audio session.
- Route changes continue to invalidate the converter and lazily rebuild the nil-format tap if capture should remain active.
- Existing microphone and speech permission messages are unchanged.
- The raw Core Audio error is not presented as the only diagnostic path in logs; the settings UI receives the existing localized failure message.

## Testing

### Policy tests

- The haptic engine policy uses the shared `AVAudioSession` and haptics-only playback.
- The voice capture policy does not request a hardware sample rate.
- The voice capture policy preserves Bluetooth microphone support and excludes A2DP from the capture options.
- The canonical output policy remains 16 kHz, mono, PCM16.

### Controller regression tests

- A capture-start failure is returned before either Hermes or Apple transcription is invoked.
- Hermes and Apple provider modes both continue to consume the same `VoiceCapturedAudio` contract after capture succeeds.

### Device acceptance

On the reported iPhone 16 Pro Max running iOS 27:

1. If available, run build 125 and build 126 on the same device and OS; record whether the failure follows the build boundary.
2. Launch the candidate build after a normal chat response has produced response haptics.
3. Open Voice settings and press **Record ASR** with Hermes selected.
4. Repeat with **On this iPhone** selected.
5. Repeat after backgrounding and returning to the app.
6. Confirm that both tests record and reach provider transcription instead of showing `-10868`.
7. Confirm that TTS and response haptics still work after the ASR test.

The available local simulator is iOS 26.5 and cannot prove the reported iOS 27 physical-device case. Local unit tests and any simulator test suite remain useful for compile and policy coverage, but the iPhone acceptance steps are required before treating the device regression as closed.

## Integration boundary

The feature branch is based on current `main`. The PR targets `main`. After the PR is merged, its merge commit will be cherry-picked into `release/0.1.3`; no release build or TestFlight packaging is part of this change.
