# Cloudflare Access Token Origin Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restrict Cloudflare Access service-token headers to same-origin main-frame dashboard requests in both WebViews, with safe JavaScript serialization and regression coverage.

**Architecture:** `CloudflareAccessCredentials` will generate an origin-scoped script from JSON string literals. `AuthWebView` and `DashboardTicketBridge` will pass the normalized dashboard URL and install the script for the main frame only. The script will independently check the current document origin and each resolved fetch/XHR destination before mutating request headers.

**Tech Stack:** Swift, Foundation `JSONSerialization`, SwiftUI `UIViewRepresentable`, WebKit `WKUserScript`, XCTest, XcodeGen, `xcodebuild` on iOS Simulator.

## Global Constraints

- Keep service-token headers off subframes and every cross-origin request.
- Preserve initial native dashboard requests and same-origin dashboard `fetch`/XHR behavior.
- Fail closed by omitting the injection script when a credential or expected origin cannot be serialized.
- Do not modify remote Markdown loading, dashboard logout, presentation-cache lifetime, or push-relay credential binding.
- Preserve existing local workspace changes by working only in the isolated worktree.

---

## File map

- Modify `Conduit/Services/CloudflareAccess.swift`: add JSON-safe literal generation and origin-aware fetch/XHR guards.
- Modify `Conduit/Views/LoginView.swift`: pass the normalized dashboard URL and set `forMainFrameOnly: true`.
- Modify `Conduit/Services/DashboardTicketBridge.swift`: use the same origin-aware script and main-frame restriction.
- Modify `ConduitTests/CloudflareAccessTests.swift`: prove escaping, origin scoping, and fail-closed generation.
- Regenerate `Conduit.xcodeproj` with XcodeGen; do not hand-edit generated project files.

### Task 1: Prove safe credential serialization

**Files:**

- Modify: `ConduitTests/CloudflareAccessTests.swift`
- Modify: `Conduit/Services/CloudflareAccess.swift`

**Interfaces:**

- Existing `CloudflareAccessCredentials.fetchInjectionUserScript` behavior remains covered while the serializer is extracted.
- The implementation will use one internal JSON-string-literal helper for credentials and URLs.

- [ ] **Step 1: Write the failing regression test**

Add `testFetchInjectionEscapesBackslashesAndControlCharacters` using a client ID
and secret containing a backslash, quote, newline, and tab. Assert that the
generated source contains JSON-escaped literals and does not contain raw
control characters inside the assigned values.

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

~~~bash
xcodebuild -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ConduitTests/CloudflareAccessTests \
  test
~~~

Expected: the new assertion fails because the current implementation only
escapes single quotes.

- [ ] **Step 3: Implement minimal JSON literal serialization**

Replace manual quote replacement with a helper equivalent to:

~~~swift
private func javaScriptStringLiteral(_ value: String) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
          let literal = String(data: data, encoding: .utf8),
          literal.first == "\"",
          literal.last == "\"" else { return nil }
    return literal
}
~~~

Use the helper for both credential values and return an empty script if either
literal cannot be produced.

- [ ] **Step 4: Run the focused test to verify it passes**

Run the same focused `xcodebuild` command and confirm the new test passes with
the existing Cloudflare tests.

- [ ] **Step 5: Commit the serializer change**

~~~bash
git add Conduit/Services/CloudflareAccess.swift ConduitTests/CloudflareAccessTests.swift
git commit -m "fix: serialize Cloudflare injection credentials safely"
~~~

### Task 2: Add origin and frame guards

**Files:**

- Modify: `ConduitTests/CloudflareAccessTests.swift`
- Modify: `Conduit/Services/CloudflareAccess.swift`

**Interfaces:**

- Replace the app-facing script property with `fetchInjectionUserScript(expectedBaseURL: String) -> String`.
- The script will define `cfOrigin` from the serialized expected base URL and attach headers only when `window.location.origin === cfOrigin` and the resolved request origin equals `cfOrigin`.

- [ ] **Step 1: Write the failing origin-scope tests**

Add tests that generate the script for `https://dashboard.example/hermes` and
assert it contains the exact current-document and resolved-request origin
guards, plus a test that an unconfigured credential returns an empty script.
Keep the existing header and quote tests pointed at the new method.

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

~~~bash
xcodebuild -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ConduitTests/CloudflareAccessTests \
  test
~~~

Expected: the origin-guard assertions fail because the current script has no
configured dashboard origin or cross-origin eligibility check.

- [ ] **Step 3: Implement the guarded fetch/XHR script**

Generate `cfOrigin` with `new URL(<serialized expected base URL>).origin`.
Resolve string, URL, and Request-like fetch inputs against
`window.location.href`; for XHR, evaluate the URL during `open`. Only mutate
headers when both the document origin and resolved request origin equal
`cfOrigin`. Keep the existing `Headers` and plain-object handling for
eligible requests.

- [ ] **Step 4: Run the focused tests to verify they pass**

Run the focused Cloudflare test command again and confirm all origin, escaping,
and existing credential tests pass.

- [ ] **Step 5: Commit the origin guard**

~~~bash
git add Conduit/Services/CloudflareAccess.swift ConduitTests/CloudflareAccessTests.swift
git commit -m "fix: scope Cloudflare headers to dashboard origin"
~~~

### Task 3: Apply the boundary to both WebViews

**Files:**

- Modify: `Conduit/Views/LoginView.swift`
- Modify: `Conduit/Services/DashboardTicketBridge.swift`

**Interfaces:**

- Both callers pass the normalized dashboard URL to
  `fetchInjectionUserScript(expectedBaseURL:)`.
- Both callers install `WKUserScript(..., forMainFrameOnly: true)`.

- [ ] **Step 1: Update `AuthWebView.makeUIView`**

Normalize the dashboard URL before configuring the user script, pass that
normalized value into the script generator, and change the user-script option
to `forMainFrameOnly: true`. Leave the initial `URLRequest` and its native
Cloudflare headers unchanged.

- [ ] **Step 2: Update `DashboardTicketBridge.init`**

Use the already normalized `baseURL` when generating the script and install it
for the main frame only. Keep the existing cookie restoration and dashboard
navigation policy unchanged.

- [ ] **Step 3: Search for remaining unsafe call sites**

Run:

~~~bash
rg -n "fetchInjectionUserScript|forMainFrameOnly" Conduit
~~~

Expected: both Cloudflare injection call sites pass an expected base URL and
use `forMainFrameOnly: true`; unrelated WebKit scripts may retain their own
frame policy.

- [ ] **Step 4: Commit the WebView boundary changes**

~~~bash
git add Conduit/Views/LoginView.swift Conduit/Services/DashboardTicketBridge.swift
git commit -m "fix: restrict Cloudflare injection to dashboard main frames"
~~~

### Task 4: Verify, publish, and open the PR

**Files:**

- Modify: regenerated `Conduit.xcodeproj` only if XcodeGen changes it.

- [ ] **Step 1: Regenerate the Xcode project and inspect the diff**

~~~bash
/opt/homebrew/bin/xcodegen generate
git diff --check
git status --short
~~~

Expected: no unrelated source changes and no whitespace errors.

- [ ] **Step 2: Run the focused regression suite**

~~~bash
xcodebuild -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ConduitTests/CloudflareAccessTests \
  test
~~~

Expected: all Cloudflare tests pass.

- [ ] **Step 3: Run the full simulator suite**

~~~bash
set -o pipefail
xcodebuild -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test -resultBundlePath /tmp/conduit-cloudflare-token-guard.xcresult \
  | tee /tmp/conduit-cloudflare-token-guard.log | tail -160
~~~

Expected: `** TEST SUCCEEDED **` and zero test failures.

- [ ] **Step 4: Inspect the final diff and branch status**

~~~bash
git diff origin/agent/release-118-docs...HEAD --stat
git diff --check
git status -sb
~~~

Expected: only the approved design/plan docs, Cloudflare generator, two WebView
call sites, and focused tests are present.

- [ ] **Step 5: Push the branch**

~~~bash
git push -u origin agent/cloudflare-token-origin-guard
~~~

- [ ] **Step 6: Open a draft PR against `agent/release-118-docs`**

Use the GitHub app after the push with this title:

~~~text
Fix Cloudflare Access token injection origin leakage
~~~

The body should state that the old script injected credentials into subframes
and cross-origin requests, that the fix uses JSON literals plus main-frame and
same-origin guards, and that focused and full simulator tests passed. Link
issue #20 and identify the remaining findings as out of scope.
