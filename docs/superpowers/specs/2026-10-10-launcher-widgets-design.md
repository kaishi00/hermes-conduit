# Conduit launcher widgets

Date: 2026-10-10. Status: approved by the user in conversation. Implementation has not started.
> **Superseded 2026-10-14:** the planned App Group `group.com.milim.relay.widgets` could not be registered (globally taken by another team). The shipped group is `group.com.milim.relay.launcher`, assigned to both `com.milim.relay` and `com.milim.relay.widgets`; see docs/WIDGETS.md.

## Goal and first-version scope

Give iPhone and iPad users attractive Home Screen access to Conduit. Ship two medium widget gallery entries, **Native** and **Conduit-chan**, with shared functionality:

- Tap the conversation title to resume the last conversation or open a configured conversation.
- **New Chat** opens a fresh text conversation.
- **Talk** opens Conduit and starts a fresh voice conversation through its existing foreground voice flow.

Each widget instance can follow the current dashboard/workspace profile or select a saved workspace. An optional saved conversation selection replaces the default last-conversation target. Users can add either style or both, with independent configuration.

Live agent/task status and attention counts are deferred to a separate Live Activity feature. This change does not implement Live Activities, background widget networking, inline approvals, prompt presets, extra widget sizes, or changes to Siri/Watch/CarPlay behavior.

## Source baseline and workspace discipline

The current working checkout is `release/0.1.11` at `bbf59c0`, with unrelated local changes. A read-only fetch established current development `origin/main` at `46f25da3` on 2026-10-10. Implementation must use an isolated worktree from the then-current development main and recheck relevant source before editing; do not rewrite the release checkout or Mac release/version state.

Current main already has:

- The registered `conduit` URL scheme, `ConduitAppLink`, and a root external-link delivery path.
- Typed conversation identity/resume state and dashboard/profile switching with authentication ownership checks.
- A foreground voice launch path and an in-memory pending Siri voice mailbox.
- Conduit-chan artwork, adaptive amber accents, app-language support, and a notification service extension.

The existing notification App Group contains notification encryption material. Give the widget a separate launcher-only group, `group.com.milim.relay.widgets`, containing display metadata and identifiers. Do not expose the notification group, Keychain, credentials, server tickets, or conversation transcripts to the widget.

## Visual design

Use the two in-chat concepts as layout references, adapting geometry to actual WidgetKit content margins and medium-family sizes.

**Native:** a small Conduit mark, dashboard/profile label, a prominent conversation title, and balanced New Chat/Talk links. Saved information gives the widget a useful identity without a live indicator.

**Conduit-chan:** the existing character artwork occupies the trailing area; readable text and launch links occupy the leading area. Use a subtle surface gradient only where needed to preserve contrast.

Both layouts expose the same three launch destinations. Artwork is decorative; action names remain explicit. Use system typography, accessible labels, Dynamic Type, and availability-guarded support for tinted/clear widget rendering. Conversation titles are marked privacy-sensitive and can be hidden through a widget configuration option; hidden titles retain a generic Resume/Open Chat link. Do not add live connection dots, activity counts, or an updated-time label to this saved-content launcher.

## Components and shared data

Add one iOS 17+ `ConduitWidgets` extension, embedded by the app, exporting both widget kinds through a `WidgetBundle`. Define its target and resources in `project.yml`; regenerate with XcodeGen and follow the current generated-project source-control policy. Preserve app version/build numbers during feature work.

Place the small shared launcher model, snapshot reader, configuration entities, and URL encoding in `Shared/Widgets`. Compile only that directory into the widget; the app already includes `Shared`. Keep live application services out of the extension.

The app publishes a versioned, atomically replaced snapshot in the dedicated App Group. Each workspace is identified by **saved dashboard UUID plus exact workspace profile**, with display labels, the last conversation reference/title, and a bounded saved-conversation list. References retain conversation kind and owning profile, including Bot Chats; a profile name or bare session ID is insufficient identity.

Retain at most 100 workspace records and 20 saved conversation choices per workspace, prioritizing the last conversation and pinned conversations before recent ones. Configured conversations that disappear from the snapshot show **Open Conduit to refresh** rather than being replaced by another conversation. Cache eviction is not evidence that a conversation was deleted; only an authoritative app-side response can report a missing conversation. Widget pickers query this local snapshot only; choices become available after the app has visited/refreshed that workspace.

Publish after successful workspace/session selection, catalog/title changes, relevant profile changes, and account removal/sign-out. Coalesce identical projections rather than writing on every stream frame. Request reloads for the two launcher widget kinds when the projection changes. Ordinary network loss retains saved launch destinations; removing a dashboard/profile removes its metadata. Store the selected app language for widget copy.

Default configuration follows the current workspace; a fixed selection remains fixed when the app switches elsewhere. Every displayed timeline entry captures its exact workspace, and tapping it opens that displayed workspace even if the app has switched meanwhile. With no usable workspace, show **Open Conduit** leading to normal setup. A known workspace without a resumable conversation keeps New Chat/Talk available and shows **Open Conduit** in the conversation area.

## Launch routing and lifecycle

Use WidgetKit `Link` destinations and the existing `conduit` scheme. Add a separately parsed, versioned widget route namespace without expanding what existing session/job links are allowed to do. URL data contains identifiers and action only, never a gateway URL or authentication material.

Handle the route once in the foreground app. Its typed request contains the action, dashboard UUID, workspace profile, and optional full conversation reference. Validate against the saved registry and known scope; malformed or removed targets cannot fall back to whichever dashboard happens to be active.

A shared app-owned launch coordinator queues during cold start, resolves the requested dashboard/profile through existing connection/authentication methods, and executes only while its ownership token is current. Explicit widget navigation takes precedence over automatic resume. A newer explicit navigation or sign-out supersedes an older queued request. Recheck dashboard/profile/generation after every suspension.

Respect the current active-call conflict policy before changing workspace or conversation; show its existing refusal instead of silently interrupting a voice call. Keep the existing external session-link restrictions, including external Bot Chat rejection. Widget-owned Bot Chat targets require the typed local reference and the app's ownership validation; they do not make the older general session-link namespace more permissive.

- **Resume/Open Chat:** open the exact displayed/configured reference through existing conversation identity and Bot Chat routing. A missing/deleted target reports its unavailability and leaves the user in that workspace; never open an unrelated recent chat.
- **New Chat:** create one session after target readiness. Coalesce repeated identical taps while that launch is in flight; a later tap after completion remains a new request.
- **Talk:** invoke the existing fresh-conversation foreground voice path after authentication and connection. Honor current voice settings/capability checks. Microphone capture occurs only in the foreground app and only for a still-current request.

Pending requests remain process-local after OS URL delivery. Expire them after 30 seconds using a monotonic deadline, including time spent connecting or authenticating. Stable connection failure, canceled authentication, missing scope, or expiry terminates the action with ordinary app feedback. No old Talk request may activate voice on a much later reconnect. Existing notification, Siri, internal-link, and iPad single-window routing must keep their established behavior.

## Validation and acceptance

Add focused unit coverage for snapshot identity/configuration, malformed routes, workspace/conversation collisions, removed targets, coalescing, expiry, supersession, and route-versus-automatic-restore ownership. Exercise warm/cold launch for Resume, New Chat, and Talk, including authentication cancellation, offline failure, Bot Chat references, and navigation changes during authentication. Verify Talk creates a fresh conversation once and cannot capture audio before foreground readiness.

Build the app and embedded widget extension with relevant XCTest coverage using the established harness when a Mac/simulator is available; review new compiler warnings. Inspect both widgets on iPhone/iPad, both together with different configurations, light/dark/tinted/clear appearance, larger accessibility text, hidden-title configuration, and no-account/missing-conversation states. Source checks or a browser concept preview do not prove WidgetKit/device behavior.

Hosted CI v4 and the exact-head `CI Gate` remain authoritative for a future PR. A release/TestFlight candidate requires hosted Nightly on its exact release head. The user-supplied instructions and current main's CI v4 policy override historical local exhaustive-gate text in release documentation. Do not run that retired gate. If CI planning/tooling needs a necessary change, run both required planner validation and CI-tooling unit suites.

Signing integration needs a widget App ID/provisioning profile and the launcher App Group assigned to the app and widget. Record any unavailable Mac, simulator, signing, or hosted validation explicitly. This design does not authorize commits, pushes, PR creation, merges, releases, or TestFlight uploads.

## Apple references

- [Linking to specific app scenes](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity)
- [WidgetBundle](https://developer.apple.com/documentation/SwiftUI/WidgetBundle)
- [AppIntentConfiguration](https://developer.apple.com/documentation/widgetkit/appintentconfiguration)
- [Configuring App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [Accented rendering and Liquid Glass](https://developer.apple.com/documentation/widgetkit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass)
