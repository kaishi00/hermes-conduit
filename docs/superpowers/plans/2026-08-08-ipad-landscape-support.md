# iPad Landscape Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow iPad to rotate between portrait and landscape while keeping iPhone portrait-only.

**Architecture:** Keep orientation policy declarative in the checked-in app `Info.plist`. The universal orientation key remains the iPhone contract, while the `~ipad` idiom-specific key overrides it for iPad. No runtime orientation APIs or SwiftUI layout changes are needed.

**Tech Stack:** iOS 17, SwiftUI, XcodeGen, XCTest, `xcodebuild`.

## Global Constraints

- iPhone remains portrait-only.
- iPad supports portrait, portrait-upside-down, landscape-left, and landscape-right with automatic rotation.
- `UIRequiresFullScreen` is absent so iPadOS can manage dynamic scene sizing.
- Do not change production SwiftUI views for this orientation-only feature.
- Preserve the existing user changes in the main checkout; work in `/tmp/hermes-conduit-ipad-orientation`.

---

### Task 1: Add the failing orientation contract tests

**Files:**
- Create: `ConduitTests/InterfaceOrientationTests.swift`

**Interfaces:**
- Consumes: the built app bundle identified by `com.milim.relay`.
- Produces: XCTest coverage for the universal and iPad-specific orientation arrays.

- [ ] **Step 1: Write the failing tests**

Create `ConduitTests/InterfaceOrientationTests.swift`:

```swift
import XCTest

final class InterfaceOrientationTests: XCTestCase {
    private let appBundleIdentifier = "com.milim.relay"

    func testUniversalOrientationsRemainPortraitOnlyForIPhone() throws {
        let info = try XCTUnwrap(Bundle(identifier: appBundleIdentifier)?.infoDictionary)
        XCTAssertEqual(
            info["UISupportedInterfaceOrientations"] as? [String],
            ["UIInterfaceOrientationPortrait"]
        )
    }

    func testIPadOrientationsIncludeBothLandscapeDirections() throws {
        let info = try XCTUnwrap(Bundle(identifier: appBundleIdentifier)?.infoDictionary)
        XCTAssertEqual(
            info["UISupportedInterfaceOrientations~ipad"] as? [String],
            [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ]
        )
    }
}
```

- [ ] **Step 2: Run the new tests to verify the expected failure**

Run after regenerating the project:

```bash
xcodegen generate
SIMULATOR=$(xcrun simctl list devices available -j | python3 -c '
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
')
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination "platform=iOS Simulator,id=$SIMULATOR" \
  -only-testing:ConduitTests/InterfaceOrientationTests \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' \
  PROVISIONING_PROFILE_SPECIFIER=''
```

Expected: `testUniversalOrientationsRemainPortraitOnlyForIPhone` passes and
`testIPadOrientationsIncludeBothLandscapeDirections` fails because the
iPad-specific plist key does not exist yet.

### Task 2: Add the iPad-specific plist declaration

**Files:**
- Modify: `Conduit/Info.plist` near `UISupportedInterfaceOrientations`

**Interfaces:**
- Consumes: the failing bundle contract from Task 1.
- Produces: a shipped plist whose base key is portrait-only and whose iPad
  override contains all four supported orientations.

- [ ] **Step 1: Add the minimal production configuration**

Keep the existing universal key unchanged and add this sibling key immediately
after its array:

```xml
<key>UISupportedInterfaceOrientations~ipad</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>
```

Remove the deprecated `UIRequiresFullScreen` key if it is present.

- [ ] **Step 2: Run the targeted tests to verify they pass**

Regenerate the project and rerun the Task 1 command. Expected: both orientation
tests pass with zero failures.

- [ ] **Step 3: Validate the plist and commit the implementation**

Run:

```bash
plutil -lint Conduit/Info.plist
git diff --check
git add Conduit/Info.plist ConduitTests/InterfaceOrientationTests.swift
git commit -m "Add iPad landscape orientation support"
```

Expected: `plutil` reports `OK`, the diff has no whitespace errors, and the
commit contains only the plist declaration and its regression tests.

### Task 3: Verify the complete merged application

**Files:**
- Verify: generated `Conduit.xcodeproj` and built app `Info.plist`

**Interfaces:**
- Consumes: the committed orientation declaration and tests from Task 2.
- Produces: evidence that the full app still builds and all tests pass.

- [ ] **Step 1: Run the full simulator suite**

Use the existing dynamic iPhone simulator selection and run:

```bash
set -o pipefail
SIMULATOR=$(xcrun simctl list devices available -j | python3 -c '
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
')
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination "platform=iOS Simulator,id=$SIMULATOR" \
  -configuration Debug \
  -derivedDataPath /tmp/hermes-conduit-ipad-tests-derived \
  -resultBundlePath /tmp/hermes-conduit-ipad-tests.xcresult \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' \
  PROVISIONING_PROFILE_SPECIFIER=''
```

Expected: `Executed 207 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 2: Inspect the generated app plist**

Run:

```bash
plutil -p \
  /tmp/hermes-conduit-ipad-tests-derived/Build/Products/Debug-iphonesimulator/Conduit.app/Info.plist \
  | sed -n '/UISupportedInterfaceOrientations/,+12p'
```

Expected: the built app contains the portrait-only universal array, the
four-entry `UISupportedInterfaceOrientations~ipad` array, and no
`UIRequiresFullScreen` key.

- [ ] **Step 3: Confirm the worktree is clean and report the evidence**

Run:

```bash
git status --short --branch
git log -2 --format='%h %an <%ae> %s'
```

Expected: a clean feature worktree with the implementation commit on top of
the approved design-spec commit.
