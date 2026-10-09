# Hermes Conduit

A native iOS client for [Hermes Agent](https://github.com/NousResearch/hermes-agent). Free, no ads, no tracking.

[![App Store](https://img.shields.io/badge/App_Store-Hermes_Conduit-blue)](https://apps.apple.com/us/app/hermes-conduit/id6790977764)
[![Website](https://img.shields.io/badge/Website-hermesconduit.app-blue)](https://hermesconduit.app)
[![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/agrias)

## What it does

Conduit connects directly to your self-hosted Hermes dashboard. Same sessions, same profiles, same capabilities as the desktop client. No relay service, no extra processes, no middleman.

Start a conversation on desktop, pick it up on your phone. The session list is the same because it is the same database.

## Features

**Chat**

- Streaming responses with full Markdown — syntax-highlighted code, math, Mermaid diagrams, task lists
- Tool call inspection, reasoning traces, and delegated-agent progress
- Attach images and any other file (PDFs, documents, code), or paste an image straight into the composer
- Steer or interrupt an active turn mid-flight
- Context usage meter with token counts and a progress ring
- Slash commands and workspace file browsing
- Session branching, pinning, archiving, refresh, and delete

**Voice**

- Push-to-talk voice mode with on-device speech recognition or server-side Whisper
- Live voice conversations via GPT-Live (OpenAI Realtime) and Gemini Live, including web search through Gemini's tool bridge
- CarPlay support — talk to Hermes from the car
- Spoken stop/end commands, continuous-conversation controls, and background audio

**Agents and control**

- Bot Mode — browse your Hermes bots and open their dedicated Bot Chat conversations
- Multiple dashboards — save and switch between Hermes servers with isolated credentials, sessions, and connection state
- Provider and model switching without leaving the conversation, plus reasoning effort controls
- Capabilities tab to toggle skills, tools, and MCP servers
- Scheduled jobs viewer, connector monitoring, and recent gateway logs
- Multi-profile support with per-profile settings

**Sign-in, notifications, platform**

- Native OAuth sign-in for dashboards using Google or other OIDC providers
- Cloudflare Access service-token support
- Push notifications for approvals, input requests, completed responses, failed turns, and background tasks
- Inline approvals so you can approve or reject tool calls without typing
- Face ID lock and Keychain credential storage
- iPhone and iPad (iOS 17+)
- Available in English, German, Spanish, French, Brazilian Portuguese, Russian, Italian, Polish, Korean, Traditional Chinese, Indonesian, Turkish, Japanese and Simplified Chinese

## Requirements

- iOS 17 or later
- iPhone or iPad
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

## Push Notifications

Push notifications require a small relay service because iOS does not allow apps to maintain persistent background connections. The relay source is in the `hermes-conduit-notifier` plugin and the push relay server.

To set up push notifications, install the notifier plugin on your Hermes instance:

```
hermes plugins install kaishi00/hermes-conduit-notifier --enable
hermes gateway restart
```

Then follow the in-app pairing flow under Settings > Notifications.

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
- Xcode 16 or later
- iOS 17 SDK
- [xcodegen](https://github.com/yonaskolb/XcodeGen)

## Releasing

See [the iOS release workflow](docs/RELEASE_WORKFLOW.md) for the TestFlight and App Store release process.

## Architecture

Conduit is pure SwiftUI targeting iOS 17+. The project uses xcodegen for Xcode project generation from `project.yml`.

The app connects to the Hermes dashboard WebSocket endpoint (`/api/ws`) after authenticating through the dashboard login page. All RPC calls route through the dashboard, same as the desktop client. The gateway is never contacted directly.

Key files:
- `Conduit/Services/HermesClient.swift` - WebSocket client and RPC layer
- `Conduit/Services/AppState.swift` - Main state management and session lifecycle
- `Conduit/Services/DashboardTicketBridge.swift` - Authentication bridge
- `Conduit/Views/ChatView.swift` - Chat interface with streaming
- `Conduit/Voice/` - Voice pipeline: push-to-talk plus GPT-Live and Gemini Live conversations

## Privacy

Conduit does not collect, transmit, or store your data on any third-party server. All communication goes directly between the app and your own Hermes instance. The only external connection is the optional push relay, which delivers notifications through Apple; with end-to-end encryption on, it only sees routing data, not their content.

No analytics. No telemetry. No ad frameworks.

## Support

- Website: [hermesconduit.app](https://hermesconduit.app)
- Bug reports: [GitHub issues](https://github.com/kaishi00/hermes-conduit/issues)
- Email: [developer@hermesconduit.app](mailto:developer@hermesconduit.app)

## License

MIT

The live voice orb uses the shader from [Liquid Orb Editor](https://github.com/lersent001/orb) by LerSent001 (MIT); its notice is in `Conduit/Views/LiquidOrb/LiquidOrb.metal`.

## Disclaimer

Hermes Conduit is an independent project and is not affiliated with or endorsed by Nous Research.
