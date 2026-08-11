# Cloudflare Provider Discovery Redirect Design

## Goal

Fix Conduit issue #37 so a Cloudflare Access redirect during dashboard auth-provider discovery does not appear as a fatal provider-probe error. Conduit should fall through to its existing dashboard WebView sign-in path, which already carries configured Cloudflare service-token headers.

## Scope

This change covers only the provider-discovery redirect fallback and regression tests. It preserves the existing native username/password flow, native Cloudflare header injection, and origin-scoped WebView injection. It does not add a Cloudflare-Access-only mode or modify Hermes Desktop.

## Current behavior

`LoginView.connect()` calls `NativeAuthClient.authProviders()` before deciding whether to use native password login or the WebView. `NativeAuthClient` rejects every response outside `200...299`, so a Cloudflare Access `3xx` response becomes `providerDiscoveryFailed` and prevents the WebView fallback from opening.

## Design

`NativeAuthClient.authProviders()` will return an empty provider list for a redirect response. An empty provider list already selects `AuthWebView` in `LoginView`, preserving the existing edge-authenticated browser flow. Ordinary client and server errors remain failures, so this does not hide authentication or connectivity errors. Successful provider responses and the password-login/ticket sequence are unchanged.

The redirect handling will be covered by focused tests for provider discovery, alongside the existing successful response behavior. The tests will use a URL loading protocol or equivalent injectable session boundary so they exercise the real response classification without depending on a live Cloudflare tenant.

## Acceptance criteria

1. A `3xx` response from `/api/auth/providers` does not produce `Could not check dashboard sign-in options: HTTP 302`.
2. The caller receives the existing empty-provider signal and opens the WebView path.
3. `4xx` and `5xx` provider responses still produce `providerDiscoveryFailed`.
4. A successful provider response still exposes its providers, including password-capable providers.
5. No Cloudflare-only authentication mode, Hermes server change, or Hermes Desktop change is included.

## Verification

Run the focused provider-discovery tests, the full Conduit test suite, and the repository’s generated Xcode project build/test command where the local Xcode toolchain permits.
