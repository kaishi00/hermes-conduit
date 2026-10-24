# Qwen Live: an independent direct voice provider

Qwen Live and Gemini Live are separate entries in the phone, Watch and
CarPlay voice pickers. Both can be configured on the same Hermes host.
Switching providers in the app does not change server configuration or
require a gateway restart. Audio, tools and transcript code are shared;
credentials, preferences, consent and saved-call identity are separate.

## Host setup

Install the modified notifier and app. Set the following in the Hermes
profile's `.env`:

```dotenv
DASHSCOPE_API_KEY=your-permanent-bailian-key
CONDUIT_QWEN_LIVE_WORKSPACE=your-workspace-id
CONDUIT_QWEN_LIVE_REGION=cn-beijing
CONDUIT_QWEN_LIVE_MODEL=qwen3.8-omni-flash-realtime
CONDUIT_QWEN_LIVE_VOICE=Tina
```

Use the same region for the workspace and key; Singapore is
`ap-southeast-1`. The host voice is a default. In Conduit's Qwen Live
settings, enter another supported voice to override it on this device.
Gemini voice, memory and personality preferences are unaffected.
`GEMINI_API_KEY` / `GOOGLE_API_KEY` continue to configure Gemini normally.
There is no server-side provider selector.

## Network and authorization

- Gemini uses `/gemini-live/status` and `/gemini-live/token`.
- Qwen uses `/qwen-live/status` and `/qwen-live/token`.
- The host returns a temporary Qwen credential, never the permanent key.
- Phone and Watch connect directly to Alibaba Cloud for audio. Credentials
  and tools can use the existing encrypted Watch grant; audio does not.
- Watch reconnects request `qwen_live_token` for Qwen and `live_token` for
  Gemini. A grant for one does not authorize minting the other's token.
- The Watch start message explicitly identifies the selected provider.
  Update both apps together (Watch voice protocol version 4).

Qwen asks for its own Alibaba Cloud consent. Existing Google consent is
preserved and cannot authorize Qwen. Phone-data permissions, memory and
personality sharing also use Qwen's own provider identity, off by default.
Saved calls use `qwen-live`; Gemini calls keep `gemini-live`.

Qwen native search is incompatible with function tools, so it uses Hermes
web search or Hermes jobs. Input is 16 kHz mono PCM; output is 24 kHz PCM.
Qwen reconnects start a new provider session and restore available context.

Incoming-call signaling still uses relay/APNs. Once answered, audio uses
the selected provider's direct connection. CarPlay and Watch reuse the
existing direct-call machinery with the selected provider's credentials.

## Validation limits

Mocked credential and protocol tests do not establish real model access,
latency or background behavior. Build iOS/watchOS and run XCTest on macOS;
then test temporary-key acceptance/expiry, voice selection, interruptions,
tools, reconnects, incoming calls and Watch operation with the wrist down,
on Wi-Fi/cellular and without the phone.

References: [Realtime](https://help.aliyun.com/zh/model-studio/realtime),
[events](https://help.aliyun.com/zh/model-studio/client-events),
[temporary keys](https://help.aliyun.com/zh/model-studio/generate-temporary-api-key).

Input transcription uses `qwen3-asr-flash-realtime`: Alibaba Cloud's
[client-events contract](https://help.aliyun.com/en/model-studio/client-events)
fixes that model value. It is not an independently selectable ASR model.
The adapter requests it so saved calls retain the user's spoken turns.
