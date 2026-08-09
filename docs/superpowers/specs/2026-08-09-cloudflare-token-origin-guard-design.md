# Cloudflare Access Token Origin Guard

## Goal

Prevent Cloudflare Access service-token headers from reaching subframes or
cross-origin requests made by the authentication and dashboard WebViews,
while preserving same-origin dashboard authentication.

## Current boundary

`CloudflareAccessCredentials.fetchInjectionUserScript` embeds the client ID
and secret into JavaScript. `AuthWebView` and `DashboardTicketBridge` install
that script with `forMainFrameOnly: false`, and the script adds the headers to
every intercepted `fetch` and `XMLHttpRequest`. Credential strings currently
escape only single quotes, so backslashes and other JavaScript-sensitive input
can change the generated source.

## Design

1. Serialize the client ID, client secret, and expected dashboard origin as
   JSON string literals rather than interpolating manually escaped strings.
2. Pass the normalized dashboard origin into the generated script.
3. Install the script with `forMainFrameOnly: true` in both WebViews.
4. Require both the current document origin and the fully resolved request
   origin to equal the configured dashboard origin before adding either
   Cloudflare header. Relative URLs resolve against the current document.
5. Leave initial native requests and same-origin dashboard `fetch`/XHR traffic
   unchanged. Cross-origin OAuth pages, third-party frames, redirects, and
   external API requests receive no service-token headers.

## Components

- `CloudflareAccess.swift`: generate origin-scoped, safely serialized
  injection JavaScript.
- `LoginView.swift`: install the script only in the main frame and provide the
  configured dashboard origin.
- `DashboardTicketBridge.swift`: apply the same main-frame and origin-scoped
  policy to the background ticket WebView.
- `CloudflareAccessTests.swift`: cover quotes, backslashes, control characters,
  same-origin requests, and cross-origin rejection.

## Error and compatibility behavior

If a value cannot be serialized or the expected origin is unavailable, the
injection script will be omitted rather than emitting unsafe JavaScript. The
existing native request path remains responsible for the initial dashboard
request. Service-token mode therefore fails closed for the affected WebView
request without changing non-Cloudflare connections.

## Verification

- Run focused Cloudflare tests through the real `CloudflareAccessCredentials`
  script-generation boundary.
- Confirm the regression tests fail before the implementation and pass after
  it.
- Run the complete iOS simulator test suite and inspect the final diff for
  unrelated changes.
- Manually verify that a same-origin dashboard request remains eligible and a
  cross-origin request or subframe cannot receive the headers.

## Scope boundary

This change does not address remote Markdown image loading, dashboard cookie
logout, presentation-cache lifetime, or push-relay credential binding. Those
remain separate maintenance work.
