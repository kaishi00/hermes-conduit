# Voice Capture Session Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the shared iOS microphone capture path start reliably after Core Haptics activity or route changes while preserving the existing 16 kHz mono PCM16 transcription contract.

**Architecture:** Keep `AVAudioCaptureService` as the sole owner of microphone-session activation and route-native input capture. Move its category/options/output-format choices into a value-oriented policy tested without hardware. Configure Core Haptics as a haptics-only engine bound to the shared `AVAudioSession`, discard stale engines after stops/resets, and add safe startup diagnostics for the physical-device failure path.

**Tech Stack:** Swift 5.9, SwiftUI, AVFAudio, CoreHaptics, OSLog, XCTest, XcodeGen, iOS deployment target 17.0.

## Global Constraints

- Keep the canonical transcription output at 16,000 Hz, one channel, PCM16.
- Do not change Hermes or Apple speech-recognition provider APIs.
- Keep `.playAndRecord` with `.voiceChat`, Bluetooth HFP input support, and speaker fallback.
- Do not request a preferred hardware sample rate; convert the active route's actual input format after capture.
- Do not include audio contents, transcripts, credentials, or session secrets in diagnostics.
- Do not claim physical iOS 27 validation from the available iOS 26.5 simulator.
- The PR targets `main`; after merge, cherry-pick the merge commit into `release/0.1.3`; do not package a build in this change.

---

### Task 1: Add the route-native audio-session policy

**Files:**
- Create: `Conduit/Voice/VoiceAudioSessionConfiguration.swift`
- Create: `ConduitTests/VoiceAudioSessionConfigurationTests.swift`

**Interfaces:**
- Produces `VoiceAudioSessionConfiguration.capture` with `category`, `mode`, `options`, `outputSampleRate`, and `outputChannelCount` properties.
- Later tasks consume the policy from `AVAudioCaptureService` and the tests consume it without activating real audio hardware.

- [ ] **Step 1: Write the failing policy tests**

Create `ConduitTests/VoiceAudioSessionConfigurationTests.swift` with tests that assert the exact capture policy:

```swift
import AVFAudio
import XCTest
@testable import Conduit

final class VoiceAudioSessionConfigurationTests: XCTestCase {
    func testCaptureUsesInputCapableVoiceChatBluetoothPolicy() {
        let configuration = VoiceAudioSessionConfiguration.capture

        XCTAssertEqual(configuration.category.rawValue, AVAudioSession.Category.playAndRecord.rawValue)
        XCTAssertEqual(configuration.mode.rawValue, AVAudioSession.Mode.voiceChat.rawValue)
        XCTAssertTrue(configuration.options.contains(.allowBluetooth))
        XCTAssertTrue(configuration.options.contains(.defaultToSpeaker))
        XCTAssertFalse(configuration.options.contains(.allowBluetoothA2DP))
    }

    func testCapturePreservesCanonicalProviderFormat() {
        let configuration = VoiceAudioSessionConfiguration.capture

        XCTAssertEqual(configuration.outputSampleRate, 16_000)
        XCTAssertEqual(configuration.outputChannelCount, 1)
    }
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run:

```bash
xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -derivedDataPath /tmp/conduit-voice-capture-policy \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ConduitTests/VoiceAudioSessionConfigurationTests
```

Expected: compilation fails because `VoiceAudioSessionConfiguration` does not yet exist.

- [ ] **Step 3: Implement the policy value**

Create `Conduit/Voice/VoiceAudioSessionConfiguration.swift`:

```swift
import AVFAudio

struct VoiceAudioSessionConfiguration: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let outputSampleRate: Double
    let outputChannelCount: AVAudioChannelCount

    static let capture = Self(
        category: .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetooth, .defaultToSpeaker],
        outputSampleRate: 16_000,
        outputChannelCount: 1
    )
}
```

- [ ] **Step 4: Run the policy tests to verify they pass**

Run the command from Step 2. Expected: both tests pass.

- [ ] **Step 5: Commit the policy unit**

```bash
git add Conduit/Voice/VoiceAudioSessionConfiguration.swift ConduitTests/VoiceAudioSessionConfigurationTests.swift
git commit -m "test: define voice audio session policy"
```

### Task 2: Bind Core Haptics to the shared session

**Files:**
- Modify: `Conduit/Services/Haptics.swift:144-370`
- Modify: `ConduitTests/HapticsTests.swift`

**Interfaces:**
- Produces `HapticsEnginePolicy.response` with `usesSharedAudioSession == true` and `playsHapticsOnly == true`.
- `Haptics.makeCoreHapticsEngine()` consumes that policy and creates `CHHapticEngine(audioSession: AVAudioSession.sharedInstance())`.

- [ ] **Step 1: Write the failing haptics policy test**

Add this test to the existing `@MainActor` `HapticsTests` class:

```swift
func testResponseEngineUsesSharedHapticsOnlyPolicy() {
    XCTAssertTrue(Haptics.enginePolicy.usesSharedAudioSession)
    XCTAssertTrue(Haptics.enginePolicy.playsHapticsOnly)
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -derivedDataPath /tmp/conduit-haptics-policy \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ConduitTests/HapticsTests/testResponseEngineUsesSharedHapticsOnlyPolicy
```

Expected: compilation fails because `Haptics.enginePolicy` does not yet exist.

- [ ] **Step 3: Implement the shared-session haptic policy and lifecycle reset**

In `Conduit/Services/Haptics.swift`, add the value type before `Haptics`:

```swift
struct HapticsEnginePolicy: Equatable {
    let usesSharedAudioSession: Bool
    let playsHapticsOnly: Bool

    static let response = Self(
        usesSharedAudioSession: true,
        playsHapticsOnly: true
    )
}
```

Inside `Haptics`, add:

```swift
static let enginePolicy = HapticsEnginePolicy.response
```

Update `makeCoreHapticsEngine()` so it selects the shared-session initializer from `enginePolicy`, sets `engine.playsHapticsOnly` before starting the engine, and retains the existing auto-shutdown behavior. The stopped handler must clear the pattern/player state and set `coreHapticsEngine = nil` for the stopped engine; the reset handler must continue to clear the engine and player state. This makes audio-session interruptions and stale auto-shutdown engines recreate cleanly.

- [ ] **Step 4: Run the focused haptics tests to verify they pass**

Run the command from Step 2. Expected: the policy test and the existing haptics tests pass without requiring hardware haptic output.

- [ ] **Step 5: Commit the haptics change**

```bash
git add Conduit/Services/Haptics.swift ConduitTests/HapticsTests.swift
git commit -m "fix: bind response haptics to shared audio session"
```

### Task 3: Make capture route-native and diagnose startup failures

**Files:**
- Modify: `Conduit/Voice/AVAudioCaptureService.swift:6-159,218-235`
- Modify: `ConduitTests/VoiceConversationControllerTests.swift:74-102,589-615`

**Interfaces:**
- `AVAudioCaptureService` consumes `VoiceAudioSessionConfiguration.capture` for session category/options and canonical output format.
- `VoiceConversationController` continues to receive the same `AudioCaptureService` errors; no provider-specific behavior changes.

- [ ] **Step 1: Add the controller regression test**

Extend `MockCapture` with an optional `startError: Error? = nil`, make `startListening(includePreRoll:)` throw that error after recording the attempted start, and add this test to `VoiceConversationControllerTests`:

```swift
func testTranscriptionTestReportsCaptureStartFailureBeforeProviderCall() async {
    let capture = MockCapture(
        permissionGranted: true,
        startError: VoiceAudioError.unavailable("Microphone capture could not start.")
    )
    let gateway = MockGateway()
    let controller = VoiceConversationController(
        capture: capture,
        playback: MockPlayback(),
        gateway: gateway,
        submit: { _ in true },
        interrupt: {}
    )

    let result = await controller.runTranscriptionTest(duration: 0)

    XCTAssertFalse(result.passed)
    XCTAssertEqual(result.message, "Microphone capture could not start.")
    XCTAssertEqual(gateway.transcriptionCount, 0)
}
```

- [ ] **Step 2: Run the new controller test to verify it fails**

Run:

```bash
xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -derivedDataPath /tmp/conduit-capture-failure \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ConduitTests/VoiceConversationControllerTests/testTranscriptionTestReportsCaptureStartFailureBeforeProviderCall
```

Expected: compilation fails because `MockCapture` has no `startError` initializer parameter.

- [ ] **Step 3: Implement the minimal capture policy and cleanup path**

In `AVAudioCaptureService.swift`:

1. Import `OSLog` and define a private voice-audio logger with subsystem `com.milim.conduit` and category `VoiceAudio`.
2. Build `outputFormat` from `VoiceAudioSessionConfiguration.capture.outputSampleRate` and `.outputChannelCount`.
3. Replace the existing `setCategory` options with `VoiceAudioSessionConfiguration.capture.options`, remove `.allowBluetoothA2DP`, and remove `setPreferredSampleRate(16_000)`.
4. Keep `setActive(true)` as the final session-configuration call before engine startup.
5. Route `startListening`, `beginBargeInMonitoring`, and `resume` through one private activation helper that configures the session, starts the engine if needed, and on failure logs diagnostics, calls `stop()` to remove any partially installed tap/deactivate the session, then rethrows the original error.
6. Keep the nil-format tap and `AVAudioConverter` conversion unchanged so the route's actual input format is converted to the same 16 kHz mono PCM16 output.
7. When startup fails, log only stage, error domain/code, current input port types, session sample rate, session input-channel count, input-node sample rate, and input-node channel count. Use OSLog privacy `.public` for those diagnostic values and do not log buffers, transcripts, URLs, cookies, or credentials.
8. On a route-change restart failure, perform the same cleanup before yielding `.interrupted`.

The diagnostic helper should have this shape so the fields remain explicit and bounded:

```swift
private func logStartupFailure(_ error: Error) {
    let nsError = error as NSError
    let inputFormat = engine.inputNode.inputFormat(forBus: 0)
    let inputPorts = session.currentRoute.inputs
        .map { $0.portType.rawValue }
        .joined(separator: ",")
    audioCaptureLog.error(
        "Capture start failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) ports=\(inputPorts, privacy: .public) sessionRate=\(session.sampleRate, privacy: .public) sessionChannels=\(session.inputNumberOfChannels, privacy: .public) inputRate=\(inputFormat.sampleRate, privacy: .public) inputChannels=\(inputFormat.channelCount, privacy: .public)"
    )
}
```

- [ ] **Step 4: Run the controller regression test to verify it passes**

Run the command from Step 2. Expected: the new test passes, existing transcription tests remain green, and the provider is not called when capture startup throws.

- [ ] **Step 5: Run all voice and haptics tests**

Run:

```bash
xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -derivedDataPath /tmp/conduit-voice-capture-focused \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ConduitTests/VoiceConversationControllerTests \
  -only-testing:ConduitTests/VoiceAudioSessionConfigurationTests \
  -only-testing:ConduitTests/HapticsTests \
  -only-testing:ConduitTests/InteractionHapticsTests \
  -only-testing:ConduitTests/ResponseHapticStateTests
```

Expected: all selected tests pass. The simulator may still report its existing Audio Unit diagnostic because it has no physical microphone route; that does not substitute for device acceptance.

- [ ] **Step 6: Commit the capture change**

```bash
git add Conduit/Voice/AVAudioCaptureService.swift ConduitTests/VoiceConversationControllerTests.swift
git commit -m "fix: use route-native voice capture startup"
```

### Task 4: Verify the complete change and prepare the integration handoff

**Files:**
- Verify: `Conduit/Voice/VoiceAudioSessionConfiguration.swift`
- Verify: `Conduit/Voice/AVAudioCaptureService.swift`
- Verify: `Conduit/Services/Haptics.swift`
- Verify: `ConduitTests/VoiceAudioSessionConfigurationTests.swift`
- Verify: `ConduitTests/VoiceConversationControllerTests.swift`
- Verify: `ConduitTests/HapticsTests.swift`

**Interfaces:**
- No new public API or provider contract is introduced.
- The feature branch remains based on current `main` and contains only the design, tests, and audio-session implementation.

- [ ] **Step 1: Regenerate the ignored Xcode project**

Run:

```bash
/Users/agrias/bin/bin/xcodegen generate
```

Expected: `Conduit.xcodeproj` regenerates successfully and remains ignored by Git.

- [ ] **Step 2: Run the complete unit suite**

Run:

```bash
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -derivedDataPath /tmp/conduit-voice-capture-final \
  CODE_SIGNING_ALLOWED=NO
```

Expected: the full suite succeeds with zero test failures.

- [ ] **Step 3: Perform static and worktree checks**

Run:

```bash
git diff --check
git status --short --branch
git log --oneline --decorate -4
```

Expected: no whitespace errors, no unrelated files, and the original checkout at `/Users/agrias/Documents/Conduit` remains untouched.

- [ ] **Step 4: Push the feature branch and open the PR against `main`**

Push `codex/voice-capture-session-fix`, create the PR against `main`, and describe the physical-device acceptance requirement. Do not create a release build or TestFlight artifact.

- [ ] **Step 5: After CI/review approval, merge and cherry-pick the merge commit**

Merge the PR into `main`, fetch the resulting merge commit, check out `release/0.1.3`, cherry-pick that merge commit, and push the release branch. Verify both branches contain the same fix; leave build/TestFlight packaging for a later request.

- [ ] **Step 6: Run the physical-device acceptance checklist**

On the iPhone 16 Pro Max running iOS 27, test build 126 or the PR build after a normal response haptic, after notification launch, after background/foreground, and with both Hermes and **On this iPhone** selected. Confirm Record ASR starts, captures, reaches transcription, and that TTS and response haptics still work afterward. Capture the new route/format diagnostics if `-10868` remains.
