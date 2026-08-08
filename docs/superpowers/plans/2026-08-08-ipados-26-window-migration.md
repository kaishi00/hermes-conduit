# iPadOS 26 Window Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the iPadOS 26 full-screen compatibility behavior that can leave Conduit in a non-maximized, visually stale orientation window while preserving portrait-only behavior on iPhone.

**Architecture:** Keep orientation policy in the idiom-specific `Info.plist` keys. Remove the deprecated `UIRequiresFullScreen` compatibility flag so iPadOS can manage a resizable SwiftUI `WindowGroup` scene normally, and declare all four iPad orientations required by the iPadOS 26 windowing model. No runtime orientation override or scene delegate is needed for this migration.

**Tech Stack:** SwiftUI, XcodeGen, XCTest, iOS/iPadOS simulator, `xcodebuild`.

## Global Constraints

- The universal `UISupportedInterfaceOrientations` key remains exactly portrait-only for iPhone.
- The iPad-specific orientation key includes portrait, portrait-upside-down, landscape-left, and landscape-right.
- `UIRequiresFullScreen` is absent from the shipped app plist.
- `UIApplicationSupportsMultipleScenes` remains unchanged.
- Do not change unrelated SwiftUI layout or networking behavior in this migration.

### Task 1: Lock the iPadOS 26 plist contract with a failing test

**Files:**
- Modify: `ConduitTests/InterfaceOrientationTests.swift`

**Interfaces:**
- Consumes: the raw shipped `Conduit.app/Info.plist` parser already used by `InterfaceOrientationTests`.
- Produces: a regression contract asserting the iPad orientation set and absence of `UIRequiresFullScreen`.

- [ ] **Step 1: Update the existing iPad contract test before changing production configuration**

Change `testIPadOrientationsIncludeBothLandscapeDirections()` so its expected array is:

```swift
[
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight"
]
```

Then add this assertion to the same test:

```swift
XCTAssertNil(info["UIRequiresFullScreen"])
```

- [ ] **Step 2: Run the targeted test and verify it fails for the missing migration**

Run from `/tmp/hermes-conduit-ipad-orientation`:

```bash
xcodegen=/tmp/xcodegen-device116-source/.build/arm64-apple-macosx/release/xcodegen
"$xcodegen" generate
simulator="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && /Booted/ {print $2; exit}')"
if [ -z "$simulator" ]; then
  simulator="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {print $2; exit}')"
fi
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath /tmp/hermes-conduit-ipados26-red-derived \
  -only-testing:ConduitTests/InterfaceOrientationTests
```

Expected: `testIPadOrientationsIncludeBothLandscapeDirections` fails because the current plist omits `UIInterfaceOrientationPortraitUpsideDown` and still contains `UIRequiresFullScreen`.

- [ ] **Step 3: Commit the failing contract test**

```bash
git add ConduitTests/InterfaceOrientationTests.swift
git commit -m "Test iPadOS 26 windowing contract"
```

### Task 2: Remove the deprecated compatibility mode

**Files:**
- Modify: `Conduit/Info.plist:93-101`

**Interfaces:**
- Consumes: the failing plist contract from Task 1.
- Produces: idiom-specific orientation metadata compatible with iPadOS 26 dynamic scenes.

- [ ] **Step 1: Add portrait-upside-down to the iPad orientation array and remove `UIRequiresFullScreen`**

The resulting section must be:

```xml
<key>UISupportedInterfaceOrientations</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
</array>
<key>UISupportedInterfaceOrientations~ipad</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>
<key>UIApplicationSceneManifest</key>
```

Leave `UIApplicationSceneManifest` and all other plist entries unchanged.

- [ ] **Step 2: Run the targeted orientation tests and plist lint**

```bash
xcodegen=/tmp/xcodegen-device116-source/.build/arm64-apple-macosx/release/xcodegen
"$xcodegen" generate
simulator="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && /Booted/ {print $2; exit}')"
if [ -z "$simulator" ]; then
  simulator="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {print $2; exit}')"
fi
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath /tmp/hermes-conduit-ipados26-green-derived \
  -only-testing:ConduitTests/InterfaceOrientationTests
plutil -lint Conduit/Info.plist
git diff --check
```

Expected: both orientation tests pass, `plutil` reports `OK`, and `git diff --check` is clean.

- [ ] **Step 3: Commit the production configuration**

```bash
git add Conduit/Info.plist
git commit -m "Migrate iPad orientation support for iPadOS 26"
```

### Task 3: Verify the built app and orientation transitions

**Files:**
- Verify: generated `Conduit.app/Info.plist` and simulator-installed app; no source edits expected.

**Interfaces:**
- Consumes: the migrated plist and orientation contract.
- Produces: evidence that iPhone remains portrait-only, iPad supports all orientations, and repeated iPad transitions keep the app full-size and foregrounded.

- [ ] **Step 1: Run the complete iPhone simulator test suite**

Run `xcodegen generate`, select an available iPhone simulator, then:

```bash
simulator="$(
  xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if "iPhone" in device["name"]:
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
'
)"
if [ -z "$simulator" ]; then
  echo "::error::No iPhone simulator found"
  exit 1
fi

xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath /tmp/hermes-conduit-ipados26-full-derived \
  -resultBundlePath /tmp/hermes-conduit-ipados26-full-tests.xcresult
```

Expected: all existing tests pass with zero failures.

- [ ] **Step 2: Build for the iPad simulator and inspect the shipped plist**

```bash
ipad_simulator="$(
  xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if "iPad" in device["name"]:
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
'
)"
if [ -z "$ipad_simulator" ]; then
  echo "::error::No iPad simulator found"
  exit 1
fi

xcodebuild build \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination "platform=iOS Simulator,id=$ipad_simulator" \
  -derivedDataPath /tmp/hermes-conduit-ipados26-ui-derived
plutil -p /tmp/hermes-conduit-ipados26-ui-derived/Build/Products/Debug-iphonesimulator/Conduit.app/Info.plist
```

Expected: the built plist has no `UIRequiresFullScreen`, has four iPad orientations, and keeps the universal portrait-only array.

- [ ] **Step 3: Exercise repeated iPad rotations**

Install and launch the built app on the booted iPad Pro 13-inch simulator. Use the Simulator Rotate control for at least twelve portrait/landscape transitions, recording the rendered frame after each transition. Expected: the app alternates between portrait and landscape, remains foregrounded, and does not settle into a smaller compatibility window.

- [ ] **Step 4: Confirm repository state**

```bash
git diff --check
git status --short --branch
git log --oneline --decorate -6
```

Expected: no uncommitted changes and only the intended test/configuration commits on `agent/ipad-landscape-support`.
