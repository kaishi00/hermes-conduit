# Mistral voice agents in Conduit

Conduit's live voice modes are either the provider's own agent (GPT-Live,
Gemini Live) or Hermes answering each turn (Classic, Local Live). Mistral's
voice agents are the first kind: Mistral runs the loop — Voxtral transcribes,
a text model answers, Voxtral speaks — and Conduit joins the room for audio
and hands the agent's function calls to Hermes, the way GPT-Live's
delegations work.

Nothing here is wired into a call screen yet. This page records what the
Mistral API actually does, so the mode and its settings sheet can be built
against facts instead of a guess.

## How a session runs

```
Conduit ──POST /voxtral-agent/session──▶ Hermes host ──POST /v1/audio/sessions──▶ Mistral
        ◀── server_url, participant_token ─────────────◀── id, token, expires_at ──
Conduit ── joins the LiveKit room: mic track up, agent track down ──▶ Mistral
Mistral ── RPC `mistral.function_tool` ──▶ Conduit ──▶ Hermes job
Mistral ── data `voice_agent.events` ──▶ Conduit ──▶ transcript, agent state
```

The Mistral API key stays on the host: the phone only ever holds the
session's participant token, which expires with the session. That is the
same rule the other providers follow — Conduit keeps no provider key on
the phone.

## What was checked against the live API

| Call | Result |
|---|---|
| `POST /v1/audio/sessions` | `{id, participant_token, server_url: wss://livekit.mistral.ai, expires_at, function_tools}` |
| with `tts.voice_id` = a cloned voice | accepted; the session speaks in that voice |
| with a client-side `function` tool | declaration echoed back in `function_tools` |
| `DELETE /v1/audio/sessions/{id}` | 204 |
| `POST /v1/audio/voices` | creates a cloned voice from `sample_audio` (base64 MP3/WAV) + `languages` + `retention_notice` |
| `POST /v1/client/sessions` | `rt_…` token, ~900 s, model-scoped — the direct path for Voxtral realtime STT/TTS |

## Agent settings the API has

Every field below exists in `mistralai 3.7.0`'s own request models. Nothing
outside them is offered in Conduit.

- `instructions`, `welcome_message`
- `llm.model` — the only LLM field; there is no temperature or token limit
- `stt.model`, `stt.language`, `stt.context_bias` (words to expect),
  `stt.target_streaming_delay_ms` (80–1200, or 2400),
  `stt.turn_detection` (`start_threshold`, `eager_end_threshold`,
  `end_threshold`, `min_silence_ms`, `end_timeout_ms`)
- `tts.model`, `tts.voice_id` (preset or cloned), `tts.expressiveness`
  (accepted by the API, disabled upstream — shown disabled)
- `turn.allow_interruptions`, `turn.inactivity` (`timeout_ms`,
  `max_reminders`, `messages`)
- `tools`: server-side `web_search`, `document_library`, `connector`;
  client-side `function {name, description, parameters}`
- `agent_id` / `agent_version`, to run a saved agent from Mistral Studio,
  with per-session overrides on top

Not available on an agent, and so not offered: `phoneme_hints` (that is on
the offline `/v1/audio/speech` request only), and any sampling control.

## The event and RPC shapes

Events arrive as JSON on the room's `voice_agent.events` data channel:

- `transcription.segment {id, role, content, final, ts}` — cumulative: a
  segment with an id already seen replaces that line
- `tool_call.started {id, name}` / `tool_call.ended {id, name, arguments,
  status, result?}`
- `agent.state.changed {old_state, state}`
- `session.updated`, `error {message, fatal, code}`

Function calls arrive over LiveKit RPC, method `mistral.function_tool`, with
`{name, arguments}` and a string answer that is the tool's result.

`Shared/MistralLive/MistralLiveProtocol.swift` decodes and encodes exactly
these shapes, and `ConduitTests/MistralLiveProtocolTests.swift` covers them.

## Plan

1. **Wire format and host contract** (this change): the protocol and its
   tests.
2. **The room and the mode**: LiveKit's Swift SDK for the room, a
   `MistralLiveSession` behind the same seam as the other live sessions, the
   mode in Voice settings, `start_job` first.
3. **Tuning and cloning**: the full settings sheet above, saved agents with
   pinned versions, and recording a reference clip in the app to create,
   list and delete cloned voices.

LiveKit's Swift SDK brings its own WebRTC build (`livekit/webrtc-xcframework`,
LK-prefixed) beside the one GPT-Live uses (`stasel/WebRTC` 153.0.0). The
prefixing exists so both can be linked, but the pair is the first thing to
prove in step 2; a host-side audio bridge is the fallback if they can't
share an app.
