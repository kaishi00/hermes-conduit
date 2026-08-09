# Image Paste Provider Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore image insertion from iOS 27's “Photo to paste” keyboard action and link the fix to GitHub issue #26.

**Architecture:** Extend the existing ImagePasteTextView UIKit bridge with the item-provider paste entry point while preserving its legacy paste override. Image data continues through the existing ComposerBar.onPastedImage attachment flow; no backend or model changes are required.

**Tech Stack:** Swift 5.9, UIKit, SwiftUI, Uniform Type Identifiers, NSItemProvider, XCTest, XcodeGen, Xcode 26.

## Global Constraints

- The image should enter the existing composer attachment flow and appear as a pending image attachment before the user sends the message.
- Preserve the current paste(_:) implementation for older paste behavior.
- Delegate non-image item providers to UIKit's default implementation so text paste continues to work.
- The implementation will handle the first image provider supplied by the keyboard action.
- Validate the “Photo to paste” action on the user's physical iOS 27 device.

---

## File Map

- Modify: Conduit/Views/Components/ComposerPasteTextView.swift — add item-provider image detection and asynchronous data loading while retaining legacy paste behavior.
- Create: ConduitTests/ComposerPasteTextViewTests.swift — exercise the item-provider image callback and ordinary text fallback through the real ImagePasteTextView.
- Create: docs/superpowers/specs/2026-08-09-image-paste-provider-design.md — approved design record, already committed in the feature worktree.

### Task 1: Add the failing image-provider regression test

**Files:**
- Create: ConduitTests/ComposerPasteTextViewTests.swift

**Interfaces:**
- Consumes: ImagePasteTextView.paste(itemProviders:) and its onPastedImage: ((Data) -> Void)? callback.
- Produces: A failing test proving that an image NSItemProvider must deliver its data to the composer callback.

- [ ] **Step 1: Create the test file with a real image provider**

~~~
import Foundation
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Conduit

final class ComposerPasteTextViewTests: XCTestCase {
    func testPasteItemProvidersDeliversImageData() {
        let view = ImagePasteTextView()
        let expectedData = Data([0x89, 0x50, 0x4E, 0x47])
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(expectedData, nil)
            return nil
        }

        let callback = expectation(description: "pasted image callback")
        view.onPastedImage = { data in
            XCTAssertEqual(data, expectedData)
            callback.fulfill()
        }

        view.paste(itemProviders: [provider])

        wait(for: [callback], timeout: 1.0)
    }
}
~~~

- [ ] **Step 2: Generate the Xcode project and run only the new test**

Run:

~~~
xcodegen generate
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:ConduitTests/ComposerPasteTextViewTests/testPasteItemProvidersDeliversImageData \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' \
  PROVISIONING_PROFILE_SPECIFIER=''
~~~

Expected: the test compiles and fails because the current ImagePasteTextView does not override paste(itemProviders:), so the callback expectation is not fulfilled.

If the named simulator is unavailable, substitute an available iOS simulator UDID from xcrun simctl list devices available while keeping the same -only-testing selector.

### Task 2: Implement the minimal item-provider image path

**Files:**
- Modify: Conduit/Views/Components/ComposerPasteTextView.swift

**Interfaces:**
- Consumes: [NSItemProvider] passed to UIKit's paste API and the existing onPastedImage callback.
- Produces: One asynchronous image-data callback for the first image-capable provider; UIKit fallback for non-image providers.

- [ ] **Step 1: Import Uniform Type Identifiers**

Add:

~~~
import UniformTypeIdentifiers
~~~

- [ ] **Step 2: Add the item-provider override immediately before the legacy override**

Use the provider's registered image-conforming type so PNG, JPEG, HEIC, and other image representations are accepted:

~~~
override func paste(itemProviders: [NSItemProvider]) {
    guard let provider = itemProviders.first(where: { provider in
        provider.registeredTypeIdentifiers.contains { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }
    }),
    let imageType = provider.registeredTypeIdentifiers.first(where: { identifier in
        UTType(identifier)?.conforms(to: .image) == true
    }) else {
        super.paste(itemProviders: itemProviders)
        return
    }

    provider.loadDataRepresentation(forTypeIdentifier: imageType) { [weak self] data, _ in
        guard let data, !data.isEmpty else { return }
        DispatchQueue.main.async {
            self?.onPastedImage?(data)
        }
    }
}
~~~

The method must not touch UIPasteboard.general; the item provider owns the asynchronous representation. Leave the existing paste(_:) implementation unchanged so older paste sources remain supported.

- [ ] **Step 3: Re-run the focused test**

Run the Task 1 xcodebuild test command again.

Expected: testPasteItemProvidersDeliversImageData passes and the callback receives the provider's exact data.

- [ ] **Step 4: Commit the focused implementation**

~~~
git add Conduit/Views/Components/ComposerPasteTextView.swift ConduitTests/ComposerPasteTextViewTests.swift
git commit -m "Fix image paste from item providers"
~~~

### Task 3: Verify text fallback and the complete test suite

**Files:**
- Modify: ConduitTests/ComposerPasteTextViewTests.swift

**Interfaces:**
- Consumes: The production item-provider override from Task 2.
- Produces: Regression coverage for non-image provider fallback and complete test evidence.

- [ ] **Step 1: Add a real text-provider fallback test**

Add this test to the test class:

~~~
func testPasteItemProvidersFallsBackToTextViewForText() {
    let view = ImagePasteTextView()
    view.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
    view.isEditable = true
    view.becomeFirstResponder()

    let provider = NSItemProvider(object: NSString(string: "pasted text"))
    view.paste(itemProviders: [provider])

    let textInserted = expectation(description: "text pasted")
    let deadline = Date().addingTimeInterval(1.0)
    func checkText() {
        if view.text == "pasted text" {
            textInserted.fulfill()
        } else if Date() < deadline {
            DispatchQueue.main.async { checkText() }
        }
    }
    checkText()

    wait(for: [textInserted], timeout: 1.0)
}
~~~

- [ ] **Step 2: Run both focused composer tests**

Run:

~~~
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:ConduitTests/ComposerPasteTextViewTests \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' \
  PROVISIONING_PROFILE_SPECIFIER=''
~~~

Expected: both composer tests pass with zero failures.

- [ ] **Step 3: Run the full CI-equivalent test command**

Generate the project, select an available iPhone simulator dynamically, and run:

~~~
set -euo pipefail
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
  -resultBundlePath TestResults.xcresult \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' \
  PROVISIONING_PROFILE_SPECIFIER=''
~~~

Expected: the complete ConduitTests suite passes with zero failures and the command exits 0.

- [ ] **Step 4: Inspect the final diff**

Run:

~~~
git diff origin/main...HEAD --check
git status -sb
git diff origin/main...HEAD --stat
git diff origin/main...HEAD -- Conduit/Views/Components/ComposerPasteTextView.swift ConduitTests/ComposerPasteTextViewTests.swift
~~~

Confirm the production diff only adds item-provider image handling and the test diff only covers image delivery and text fallback.

### Task 4: Validate on the physical iOS 27 device

**Files:**
- No source changes expected.

**Interfaces:**
- Consumes: The signed/debug app build from the feature worktree and the physical iOS 27 device.
- Produces: Direct confirmation of the reported keyboard action.

- [ ] **Step 1: Build and install the app using the connected-device workflow**

Use the available Xcode/device workflow to build the Conduit scheme for the connected iOS 27 device. If the device is not discoverable, record that limitation and retain the simulator test evidence.

- [ ] **Step 2: Reproduce issue #26**

On the device:

1. Copy an image or screenshot.
2. Open Conduit and enter a chat.
3. Focus the composer.
4. Tap the keyboard's “Photo to paste” action.
5. Confirm the image preview/attachment appears in the composer without sending.

- [ ] **Step 3: Verify ordinary text paste remains usable**

Paste text into the same composer and confirm it appears as editable composer text rather than an attachment.

### Task 5: Publish the issue-linked draft PR

**Files:**
- No additional source changes expected after verification.

**Interfaces:**
- Consumes: Verified commits on agent/fix-issue-26-image-paste.
- Produces: A GitHub draft PR targeting main and closing issue #26 when merged.

- [ ] **Step 1: Confirm GitHub CLI access and branch scope**

~~~
gh --version
gh auth status
git status -sb
git log --oneline origin/main..HEAD
~~~

Expected: authenticated gh, only the design and image-paste commits ahead of origin/main, and no unrelated working-tree changes.

- [ ] **Step 2: Push the feature branch**

~~~
git push -u origin agent/fix-issue-26-image-paste
~~~

- [ ] **Step 3: Open a draft PR with issue linkage**

Use the GitHub connector when available; otherwise use:

~~~
gh pr create --draft \
  --base main \
  --head agent/fix-issue-26-image-paste \
  --title "Fix iOS image paste from keyboard providers" \
  --body-file /tmp/hermes-conduit-issue-26-pr-body.md
~~~

The PR body must state the root cause, explain that the existing attachment pipeline is reused, list the focused/full test results, record physical-device validation, and include Closes #26.
