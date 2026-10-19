# Hermes Conduit

A native iPhone, iPad and Apple Watch app for [Hermes Agent](https://github.com/NousResearch/hermes-agent). Free, no ads, no tracking.

[![App Store](https://img.shields.io/badge/App_Store-Hermes_Conduit-blue)](https://apps.apple.com/us/app/hermes-conduit/id6790977764)
[![Website](https://img.shields.io/badge/Website-hermesconduit.app-blue)](https://hermesconduit.app)
[![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/agrias)

## What it does

Conduit is a touch-first app for your own Hermes agent on iPhone, iPad and Apple Watch, with CarPlay, widgets and Live Activities. It signs in to the Hermes dashboard you run, so your sessions, profiles, bots, tools and scheduled jobs are the same ones you use on desktop. Start a conversation on desktop and pick it up on your phone: the session list is the same because it is the same database.

The app works with any Hermes dashboard on its own. The free [Hermes Conduit Notifier](https://github.com/kaishi00/hermes-conduit-notifier) plugin on your host adds notifications, live voice, Apple Watch calls, rich cards and the phone features below.

## Features

**Chat**

- Streaming replies with Markdown, highlighted code, math, Mermaid diagrams and task lists
- Thinking, tool calls and each turn's steps, shown live or folded away; delegated-agent progress
- Map, place, travel, media, contact and info cards that Hermes draws in the chat
- Attach photos, camera shots and any file; quote a message, react to it, copy it
- Steer, queue or stop a running turn; context meter; slash commands and workspace files
- Branch, pin, archive and delete sessions; project chats; Artifacts browser for every file and page Hermes made
- Saved chats open instantly, and you can type while Conduit reconnects

**Voice**

- Live voice calls with Gemini Live, GPT-Live (ChatGPT subscription or API key), Grok Live, or Local Live on your own speech server, with echo cancellation and talking over Hermes
- Start, check and cancel Hermes jobs by voice; results come back into the call
- Calls stay with their chat, keep going with the screen locked, shrink to a bar while you read, and are saved as chats you can resume
- Hermes calls you: a CallKit call when a job is done, Hermes needs you, or a check you scheduled is due, on the phone or the Watch
- Classic voice and dictation with on-device, Apple, Hermes or your own speech-to-text, spoken Stop and End, wake phrases, and Read Aloud for any reply
- Apple Watch app that calls on its own, CarPlay, Siri and the Action Button

**Tasks, bots and groups**

- Tasks board for Hermes' Kanban tasks
- Bots and their Bot Chats; gateway-hosted group chats with @mentions, files and approvals
- Scheduled jobs: review runs, run now, edit, mute their notifications, delete

**Your phone, if you allow it**

Each is off until you turn it on, and goes only to your own Hermes host, encrypted end to end. The keys are agreed over your dashboard connection, so use HTTPS or a private tunnel such as Tailscale to keep anyone on the network from stepping into that exchange:

- Location and place rules, travel times, directions and navigation
- Calendar and reminders, with each change asked first unless you allow adds
- Apple Health data
- Focus and phone status, alarms and timers, and contacts you pick
- Ask Hermes about what's on your screen, or send anything from Shortcuts or the share sheet

**Notifications and control**

- Approve tools and answer questions straight from a notification, end-to-end encrypted between your host and your phone
- Live Activities on the Lock Screen and in the Dynamic Island while a reply runs
- Home Screen widgets to start a chat or talk in one tap
- Provider, model and reasoning effort switching mid-conversation
- Multiple dashboards and profiles, each with its own credentials and settings
- Capabilities: skills, tools, connectors and plugins, plus Hermes settings and gateway logs
- Native OAuth sign-in through your dashboard, QR code and setup links, Cloudflare Access service tokens
- Face ID or Touch ID lock, credentials in the Keychain
- Available in English, French, German, Indonesian, Italian, Japanese, Korean, Polish, Portuguese (Brazil), Russian, Simplified Chinese, Spanish, Traditional Chinese and Turkish

## Requirements

- iPhone or iPad on iOS 17 or later; Apple Watch app on watchOS 10 or later (some features need newer versions)
- A running Hermes Agent instance with the native dashboard enabled (default port 9119)

## Connecting

1. Make sure your Hermes dashboard is running. If you are not sure, ask your agent: `is the dashboard running?`
2. Find your dashboard address. It is usually `http://your-server-ip:9119`.
3. Open Conduit and enter that address on the login screen.
4. Log in with your dashboard credentials.

**Note:** Conduit connects to the native Hermes dashboard, not the WebUI. The default port is 9119.

If your server is not on your local network, use Tailscale or a reverse proxy to reach it from your phone. Plain HTTP over Tailscale (MagicDNS `.ts.net` domains and `100.64.0.0/10` tailnet IPs) is supported — the traffic is already WireGuard-encrypted.

If the dashboard is behind Cloudflare Access, enable the optional service token on the login screen or in Settings > Connection > Gateway. Conduit stores the client secret in Keychain (scoped to the gateway origin), and injects both Access headers into native authentication requests, WebSocket handshakes, and all in-page WebKit fetches via a document-start user script. Credentials are bound to the gateway URL and cleared when switching to a different host.

**Native OAuth limitation:** service-token headers cannot be attached to the system Safari navigation that opens `/auth/native/authorize`. Native OAuth therefore requires that browser authorization route to be reachable through an interactive Cloudflare policy or without a service-token challenge. The token exchange, refresh, REST, and WebSocket-ticket requests still use the configured service-token headers. A service-token-only challenge in front of the authorize route cannot be bypassed by Conduit and must not silently fall back to embedded Google OAuth.

## Notifications, voice and phone features

Push notifications need a small relay because iOS does not let apps keep a background connection open. Live voice, Apple Watch calls, cards and the phone features need the notifier plugin on your Hermes host. One install covers all of it; the relay and plugin source live in [hermes-conduit-notifier](https://github.com/kaishi00/hermes-conduit-notifier).

Install the notifier plugin on your Hermes instance:

```
hermes plugins install kaishi00/hermes-conduit-notifier --enable
hermes gateway restart
```

Then turn on notifications under Settings > Notifications; Conduit pairs the signed-in profile by itself when no other iPhone receives its notifications; if one does, Settings > Notifications offers to move them to this one. Settings > Conduit plugin shows the installed version and can update it.

The app uses a shared relay by default (`push.milim.dev`) so notifications work out of the box with no extra setup.

**End-to-end encryption.** With notifier 0.5 or later, Conduit gives each pairing its own key over your dashboard connection (never through the relay) and turns encryption on by itself. Notification text, session and profile names, approval and clarify cards, and your clarify answers are then encrypted between your Hermes host and this iPhone; a Notification Service Extension decrypts them on the phone. The relay and Apple only see routing data such as the event type and timing. Settings > Notifications shows which pairings are encrypted.

**Running your own relay.** Apple only delivers notifications for the App Store build when they are signed with its developer's APNs key, so a relay you run yourself can't reach the App Store app, even if you enter its URL under Settings > Notifications > Push relay. A self-hosted relay works with a Conduit build you sign with your own Apple developer account and bundle id (see [Building from source](#building-from-source) and the relay's [self-hosting guide](https://github.com/kaishi00/hermes-conduit-notifier#self-hosting)). If your goal is that the relay can't read your notifications, end-to-end encryption already covers that on the shared relay.

## Building from source

```
git clone https://github.com/kaishi00/hermes-conduit.git
cd hermes-conduit
brew install xcodegen
xcodegen generate
open Conduit.xcodeproj
```

Select your team in Signing & Capabilities, then build and run on your device.

**Requirements:**
- A current Xcode with the iOS 26 and watchOS 26 SDKs or later (CI builds with the default Xcode on GitHub's `macos-26` runners)
- [xcodegen](https://github.com/yonaskolb/XcodeGen)

## Releasing

See [the iOS release workflow](docs/RELEASE_WORKFLOW.md) for the TestFlight and App Store release process.

## Architecture

Conduit is SwiftUI, generated with xcodegen from `project.yml`. Targets: the iPhone and iPad app, the Watch app and its widgets, Home Screen widgets and Live Activities, a Notification Service Extension (decrypts end-to-end encrypted notifications), a Location Push extension, and a share extension.

The app connects to the Hermes dashboard's WebSocket (`/api/ws`) and REST routes after authenticating through the dashboard, as the desktop client does. Plugin features use the notifier's routes under `/api/plugins/conduit_push/`, behind the same dashboard auth.

Key places:
- `Conduit/Services/HermesClient.swift` - WebSocket client and RPC layer
- `Conduit/Services/AppState.swift` (and its `AppState+*.swift` extensions) - state and session lifecycle
- `Conduit/Views/V2/` - the app shell: Chats, Tasks, Bots, Settings
- `Conduit/Voice/` - Classic voice, dictation and the live voice engines (Gemini Live, GPT-Live, Grok Live, Local Live)
- `Conduit/Health`, `Conduit/Location`, `Conduit/Phone` - opt-in phone data sync
- `ConduitWatch/` - the Apple Watch app
- `Shared/` - code shared with the extensions and the Watch

## Privacy

Conduit has no analytics, telemetry, crash-reporting or ad SDKs, and its developer never receives your conversations, voice or phone data. Chats, attachments and opt-in phone data go to your own Hermes host. Live voice calls go to the voice provider you choose (Google, OpenAI or xAI) or your own speech server. The optional push relay delivers notifications and calls through Apple; with end-to-end encryption on, it sees only routing data, not their content.

The full [privacy policy](https://kaishi00.github.io/hermes-conduit-notifier/privacy/) says what each party receives.

## Support

- Website: [hermesconduit.app](https://hermesconduit.app)
- Bug reports: [GitHub issues](https://github.com/kaishi00/hermes-conduit/issues)
- Email: [developer@hermesconduit.app](mailto:developer@hermesconduit.app)

## License

MIT

The live voice orb uses the shader from [Liquid Orb Editor](https://github.com/lersent001/orb) by LerSent001 (MIT); its notice is in `Conduit/Views/LiquidOrb/LiquidOrb.metal`.

## Disclaimer

Hermes Conduit is an independent project and is not affiliated with or endorsed by Nous Research.
