# Voice settings & provider configuration

How Conduit's Voice settings map onto the Hermes profile configuration, and
what the provider endpoint overrides do and do not change.

## Where TTS requests run

All speech synthesis is relayed through the user's Hermes host: Conduit calls
`/api/audio/speak-stream` (streamed PCM) on the Hermes server and falls back
to `/api/audio/speak` (whole-file) when streaming is unavailable. Conduit
never talks to TTS providers directly, and it never uses Hermes'
`voice.client_direct` credential hand-off — provider API keys remain on the
Hermes host, where Conduit can only see whether each key is set.

## Custom OpenAI-compatible endpoints

The OpenAI TTS provider accepts two endpoint overrides:

- `tts.openai.base_url` — points Hermes at any OpenAI-compatible speech
  endpoint (for example `https://your-host/v1`). This configures the provider
  **Hermes** calls; it does not change the server Conduit connects to, and it
  is not the Hermes dashboard URL.
- `tts.openai.speed` — speech rate multiplier; Hermes accepts 0.25–4.0 and
  Conduit rejects values outside that range rather than rewriting them.

The ElevenLabs provider exposes the analogous `tts.elevenlabs.base_url`
(applied by Hermes to both whole-file and streaming synthesis). Its
`wss_url` key is intentionally not offered: Hermes derives it from
`base_url` when unset.

`tts.openai.instruction` is deliberately **not** editable: upstream Hermes
resolves speaking style through the per-request TTS tool parameter and never
reads that config key.

## Streaming vs fallback

OpenAI-compatible does not guarantee streaming compatibility. Hermes decides
streaming per provider: when its configured provider has a chunked-PCM
implementation, `/api/audio/speak-stream` returns streamed PCM; otherwise the
server explicitly signals `fallback` and Conduit fetches whole-file audio
from `/api/audio/speak`. A provider selected for streaming whose streaming
request fails before producing audio also falls back client-side. Conduit's
provider test therefore reports success only when audible speech data was
actually delivered — a silent stream is a failed test, not a pass.

## What Conduit does not expose

Local-engine and server-administration knobs (Whisper device/compute
settings, Piper paths and tuning, command-provider command definitions,
warm/release commands, process environment) remain Hermes-host
administration concerns and are intentionally not mirrored here. Unknown or
plugin providers discovered by Hermes still appear in the pickers with the
generic model/language/voice fields.
