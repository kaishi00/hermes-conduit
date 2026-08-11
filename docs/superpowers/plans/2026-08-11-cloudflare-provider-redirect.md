# Cloudflare Provider Redirect Handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Conduit fall through to its existing WebView authentication flow when Hermes provider discovery returns a redirect, including the Cloudflare Access `302` reported in issue #37.

**Architecture:** Keep `LoginView` unchanged and reuse its existing empty-provider fallback. Add a small injectable `URLSession` seam to `NativeAuthClient` so tests can exercise real response classification, then classify `3xx` provider responses as an empty provider list while retaining errors for `4xx`/`5xx` responses. No Cloudflare-only mode or Hermes Desktop changes.

**Tech Stack:** Swift 5.9, Foundation `URLSession`, XCTest, XcodeGen, Xcodebuild.

## Global Constraints

- Preserve the existing native password-login and WebSocket-ticket flow.
- Preserve the existing Cloudflare service-token request headers.
- Treat only provider-discovery redirects as WebView fallback signals.
- Keep ordinary client/server errors visible to the user.
- Do not change Hermes server behavior or Hermes Desktop.

---

### Task 1: Add a failing provider-discovery redirect test

**Files:**
- Create: `ConduitTests/NativeAuthClientTests.swift`

**Interfaces:**
- Consumes: `NativeAuthClient.authProviders()` and its injectable `URLSession` initializer parameter, which will be added in Task 2.
- Produces: A regression test proving that a `302` response from `/api/auth/providers` must resolve as an empty provider list rather than throw `AuthClientError.providerDiscoveryFailed`.

- [ ] **Step 1: Create the test fixture and failing test**

Create a `URLProtocol` test double that returns a `302` response with a Cloudflare Access login `Location` header for the `redirect.example` host. Register the protocol for the test, construct `NativeAuthClient` with the existing production initializer, and assert that `try await client.authProviders()` returns `[]`. Register and unregister the protocol in the test class lifecycle so the first red run exercises the current production session without requiring a production-only test seam.

The test must include `@testable import Conduit`, use XCTest async assertions, and keep the response body empty because the behavior depends on the HTTP status and redirect location, not JSON parsing.

- [ ] **Step 2: Generate the project and run only the new test**

Run:

```bash
xcodegen generate
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:ConduitTests/NativeAuthClientTests/testProviderDiscoveryRedirectFallsBackToWebView \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected result before production changes: the test fails because `authProviders()` throws `providerDiscoveryFailed("HTTP 302")`.

### Task 2: Implement the minimal redirect classification

**Files:**
- Modify: `Conduit/Services/NativeAuthClient.swift:42-66`

**Interfaces:**
- Consumes: The failing test's registered protocol and the existing production session construction.
- Produces: `NativeAuthClient.init(baseURL:cloudflareAccess:session:)` with a default `nil` session for production, and `authProviders()` returning `[]` for `300...399` responses.

- [ ] **Step 1: Add the optional session injection without changing production defaults**

Change the initializer signature to:

```swift
init(
    baseURL: String,
    cloudflareAccess: CloudflareAccessCredentials? = nil,
    session: URLSession? = nil
)
```

Use the supplied session when non-`nil`; otherwise construct the existing cookie-enabled session with `SecureRedirectDelegate`. Update the final test to use the injected session so tests no longer rely on global protocol registration. Do not alter the default production configuration.

- [ ] **Step 2: Classify provider redirects as the existing empty-provider signal**

Immediately after the `HTTPURLResponse` guard in `authProviders()`, add:

```swift
if (300...399).contains(http.statusCode) {
    return []
}
```

Leave the existing `200...299` success parsing and non-2xx error path intact for all other statuses.

- [ ] **Step 3: Re-run the focused test**

Run the Task 1 command again. Expected result: `NativeAuthClientTests/testProviderDiscoveryRedirectFallsBackToWebView` passes.

### Task 3: Add preservation and header-coverage tests

**Files:**
- Modify: `ConduitTests/NativeAuthClientTests.swift`

**Interfaces:**
- Consumes: The real `NativeAuthClient.authProviders()` response classification and request construction.
- Produces: Coverage for successful provider discovery, server-error preservation, and Cloudflare headers on the discovery probe.

- [ ] **Step 1: Add successful-provider and server-error fixtures**

Extend the URLProtocol fixture with deterministic responses keyed by host:

- `providers.example`: `200` with `{"providers":[{"name":"basic","supports_password":true}]}`.
- `server-error.example`: `500` with `{"error":"origin unavailable"}`.

Add tests asserting that the successful response returns one password-capable provider and the `500` response throws `AuthClientError.providerDiscoveryFailed` containing `HTTP 500` or the parsed error detail.

- [ ] **Step 2: Add a Cloudflare-header request assertion**

For a `200` response on `headers.example`, configure the test protocol to record the incoming request and assert that `CF-Access-Client-Id` is `test-client-id` and `CF-Access-Client-Secret` is `test-client-secret` when the client is initialized with matching `CloudflareAccessCredentials`.

- [ ] **Step 3: Run the focused test class**

Run:

```bash
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:ConduitTests/NativeAuthClientTests \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected result: all `NativeAuthClientTests` pass, including redirect fallback, successful provider parsing, server-error preservation, and Cloudflare header coverage.

### Task 4: Run full verification and prepare the PR

**Files:**
- Verify: `Conduit/Services/NativeAuthClient.swift`
- Verify: `ConduitTests/NativeAuthClientTests.swift`
- Verify: `docs/superpowers/specs/2026-08-11-cloudflare-provider-redirect-design.md`
- Verify: `docs/superpowers/plans/2026-08-11-cloudflare-provider-redirect.md`

**Interfaces:**
- Consumes: The completed implementation and regression suite.
- Produces: A clean, reviewable branch for Conduit issue #37.

- [ ] **Step 1: Run the complete repository test command**

Generate the project and run the same simulator-selection and `xcodebuild test` command used by `.github/workflows/ci.yml`, with code signing disabled.

- [ ] **Step 2: Inspect the final diff and repository state**

Run:

```bash
git diff --check
git diff --stat origin/main...HEAD
git status --short --branch
```

Confirm the diff contains only the design/plan records, `NativeAuthClient.swift`, and `NativeAuthClientTests.swift`; confirm the original checkout's unrelated dirty files are not present in this worktree.

- [ ] **Step 3: Commit the implementation and tests**

```bash
git add Conduit/Services/NativeAuthClient.swift ConduitTests/NativeAuthClientTests.swift
git commit -m "Handle Cloudflare auth redirects during provider discovery"
```

- [ ] **Step 4: Push and open a draft PR against `main`**

Push `agent/conduit-issue-37-cloudflare-redirect`, then open a draft PR in `kaishi00/hermes-conduit` with `Fixes #37`. The PR body must explain that redirects now enter the existing WebView path, ordinary errors remain fatal, and Cloudflare-only mode is intentionally excluded.
