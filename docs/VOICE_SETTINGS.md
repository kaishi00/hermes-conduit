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
  is not the Hermes dashboard URL. Clearing the field removes the override
  key from the profile config, returning the provider to its default.
- `tts.openai.speed` — speech rate multiplier. Upstream clamps values into
  0.25–4.0; Conduit validates and refuses out-of-range or malformed input
  rather than saving something upstream would silently rewrite, and accepts
  comma decimals (`1,5` is stored as `1.5`). Clearing the field removes the
  override key, restoring the upstream/global default. Note: this setting
  applies to Hermes' whole-file OpenAI synthesis — upstream's current PCM
  streaming implementation does not consume it.

The ElevenLabs provider exposes the analogous `tts.elevenlabs.base_url`
(applied by Hermes to both whole-file and streaming synthesis); its
`voice_id`/`model_id` editors write the keys upstream actually reads.
Clearing any text override removes the key from the profile config — Hermes
falls back to the provider default when a key is absent. Its
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

## Keep listening when locked

Classic Voice normally suspends when Conduit leaves the foreground and is
restored, not listening, when the user returns. "Keep listening when locked"
(per profile, off by default) keeps a conversation that is already listening
running instead, through the same path that keeps Voice live while CarPlay
presents it: the capture gate stays open, the transport is recovered in the
background, and no suspension descriptor is recorded. While the phone is
locked, idle silence drops the silent audio and keeps listening instead of
pausing the microphone, and every reply opens the next listening turn even
with Continuous Conversation off, since nobody can tap Listen. The live
voice modes keep running in the background regardless of this setting.

## Unsaved voice calls

Live calls that end before the host has stored them stay in an on-device
outbox (20 calls, 7 days) and are retried whenever the session list loads.
A host that answers that it can't store calls (no notifier plugin route, or
no session store) no longer drops them: Voice settings shows an "Unsaved
voice calls" section saying why, with Save Now to retry at once.

## Minimising a live call

Swiping down the Gemini Live, Grok Live or GPT-Live sheet minimises the call instead of ending it. The call keeps running, and a bar above the composer shows its state, with mute and end controls. When the call is attached to a chat, the bar also names that chat. Tapping the bar, or the composer's voice button, brings the sheet back. End (in the sheet or on the bar), a spoken goodbye, sign-out and server or profile changes still end the call. While minimised the screen can lock as usual; only the full sheet keeps the phone awake. Classic Voice is unchanged: swiping its sheet away still closes it.

## Talking over the agent (barge-in)

Every voice mode lets you cut in by speaking when you wear headphones, AirPods or a wired headset: the microphone stays open while the agent talks, and the agent stops when you start. GPT-Live also allows it on the phone's speaker and in the car, because WebRTC cancels the speaker's echo.

Classic Voice, Gemini Live and Grok Live close the microphone while the agent talks on the speaker, in the car or over AirPlay (plus a short echo tail), because their microphone would hear the agent and it would keep interrupting itself. Use the Interrupt button there instead.

"Talk over it on the speaker" (in the Gemini Live and Grok Live sections, shared by both, off by default) is the experimental way out: the call runs its microphone and speaker on one iOS voice-processing engine, so the agent's own voice is cancelled out of the microphone, and the microphone stays open on every route. If the agent keeps cutting itself off, turn it off. It applies from the next call. Classic Voice is unchanged.

## Live call style

"Live call style" in Voice settings (shown once a live mode is on, shared by Gemini Live, Grok Live and GPT-Live) sets how calls sound, per profile, from the next call:

- **Greet me when a call connects**: the model greets you as soon as the call is live, in one short sentence, then waits. Leave the greeting text empty for one in its own words, or type your own (one line, up to 200 characters). Off by default: the call stays silent until you speak. GPT-Live needs the up-to-date Hermes notifier plugin, which swaps its "wait for the user" opening for a greeting; with an older plugin Conduit asks for the greeting once the call is ready instead. Gemini and Grok get it as the first turn of the call, never again on a reconnect.
- **Tone**: Model default, Relaxed, Neutral or Professional. Model default leaves the model's tone and your Hermes server's voice persona alone; the others add a short style block after the persona that replaces its tone and pace guidance.
- **Backchannels**: on by default. Off tells the model not to say "mm-hmm", "right" and the like while you talk.
- **What Conduit sends** shows the text Conduit adds to the current live mode's instructions, with the style applied. Memory and personality are shown as placeholders, since they are read when a call starts.

## Dictate into the composer

The composer has two buttons on the right of its bottom row. The plain mic dictates: tap it and the words appear in the draft as you speak, after anything already typed; tap it again to stop. Nothing is sent until you send it, and Send shows up beside the mic as soon as there are words, so you can send without stopping first. The waveform button (in the same spot Send takes) opens Voice. Recognition uses Apple's speech recognizer, on the device when the language supports it. Dictation is unavailable while a voice conversation has the microphone. A phone call, Siri, an audio route change or a voice conversation taking the microphone ends dictation, keeping the words so far.
