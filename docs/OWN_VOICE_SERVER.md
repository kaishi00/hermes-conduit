# Use your own voice server

Conduit can keep your voice on machines you run. A speech server you host
listens to you and speaks the replies, and Hermes still does the work. This
guide covers what to run, what to enter in Conduit, and which voice mode to
pick.

Everything goes through your Hermes host: the phone and Watch only ever talk
to Hermes, and the Conduit plugin on the host relays audio to your speech
server. The speech server never needs to be reachable from outside your
network.

## What you need

- Hermes with the Conduit plugin (conduit_push) **0.42 or later** (0.48 or
  later for Local Live on the Apple Watch).
- A speech server that speaks the OpenAI Realtime WebSocket protocol. The
  tested one is Hugging Face
  [speech-to-speech](https://github.com/huggingface/speech-to-speech)
  (`speech-to-speech serve`), a third-party project: review what it exposes
  on your network before you run it. It can run on the Hermes machine or another
  one on your network (an LXC, a GPU box, a Mac).
- For Local Live, the speech server must be able to reach your Hermes
  dashboard the way your phone does (LAN, Tailscale or a public domain),
  unless it only reads text aloud, **Hermes answers** is on (see A
  server with a model of its own), or its own model answers Live > Local:
  then the plugin runs each turn, or hands the server the call's tools, and
  the server never asks the dashboard.

## Two ways to use it

| | Classic on your server | Local Live |
|---|---|---|
| What happens | Every time you finish speaking, Hermes answers with its full agent: model, tools and memory. | The same, but as one continuous call instead of separate turns. In agent mode a fast model answers instead and hands real work to Hermes (see Agent mode). |
| Feels like | Talking to Hermes, turn by turn. First words take as long as a typed message would. | The same timing as Classic. In agent mode replies start sooner. |
| Server setup | Steps 1 and 2 | Steps 1 to 3 |

## Step 1: tell Hermes where the server is

In Conduit, open **Settings > Voice**. Under **Private voice**, tap **Your
speech server** and enter its address, for example
`ws://192.168.1.20:8765/v1/realtime` (a bare host gets `/v1/realtime`
added). Tap **Test connection**. The host dials the server and reports what
it found.

Plain `ws://` works only for private, loopback and Tailscale addresses and
LAN-style names (`localhost`, `.local`, `.lan`, `.internal`, `.home.arpa`,
`.ts.net`). Anything public needs `wss://`. speech-to-speech has no sign-in
of its own, so keep it on your network. If you put it behind an auth proxy,
set its key in the same screen.

Conduit saves this as `voice.speech_server` in the profile's `config.yaml`:

```yaml
voice:
  speech_server:
    url: ws://192.168.1.20:8765/v1/realtime
    # api_key: ...       optional, written only when you set a key
    # api_key_file: ...  optional, added by hand: read the key from a file (plugin 0.47.1+)
    # drive_turns: true  the Hermes answers switch (plugin 0.173+)
    # own_model: true    its own model answers Live > Local (plugin 0.175+)
    # model: ...         optional: the model a hosted service is asked for (plugin 0.174+)
    # voice: ...         optional: the voice it speaks in (plugin 0.174+)
    # transcription_model: ...  optional: the model that writes its transcripts (plugin 0.174+)
```

With only this step, Classic voice listens through your server.

## A server with a model of its own

A hosted realtime model (OpenAI Realtime, Alibaba's Qwen realtime, or any
service that speaks the OpenAI Realtime protocol) answers by itself: it has
no setting to point at Conduit, so the server side of steps 2 and 3 below (the
model address, the key and the launch command) doesn't apply to it, and left
alone it would talk to you with its own model while Hermes never got a
turn. For such a server, turn on **Hermes answers** under **Your speech
server** (plugin 0.173 or later). The plugin then runs every turn: the
server only listens and reads the replies aloud, and Hermes, or the fast
model in agent mode, does the answering. This works in Classic, Local Live,
agent mode and on the Apple Watch, and there is nothing to set up on the
server. In Conduit you still choose how it is used: tap **Your speech server
speaks too** for Classic (step 2), or pick **Local Live** under **Voice mode**
(step 3).

Enter the service's address with `wss://` and its key in step 1. With plugin
0.174 or later, **Known servers** above the address fills the rest in for the
services Conduit knows by name (OpenAI Realtime, Qwen Audio Realtime, and
Hugging Face speech-to-speech, which gets only an example address): the
address, or an example of it to finish with your own workspace, the model,
a voice, a transcription model and the Hermes answers switch. Tap **Save**
to keep them. For any other service, type what it needs into **Model**
(added to the address as `?model=` unless the address names one), **Voice**
and **Transcription model** (some services send no transcripts until one is
named); all three are optional and stay empty for a server that needs none.
**Test connection** also says when the server has a model of its own and the
switch is off.

Your voice goes to that service and it bills you for it. A model asked to
read text aloud usually does, but not always: if it answers instead of
reading two sentences in a row, the call ends and says so.

Leave the switch off for speech-to-speech and other servers you point at
Conduit. If one of those answers a call by itself, step 2's screen says so
and names the switch.

## Step 2: let the server speak the replies too (Classic)

Under **Private voice**, tap **Your speech server speaks too**. Conduit then
shows a **Model address** and a **Key**. The server speaks Hermes' replies
in its own voice by asking that address for the words.

Start speech-to-speech pointed at them:

```bash
speech-to-speech serve --llm_backend chat-completions \
  --responses_api_base_url https://<your dashboard>/api/plugins/conduit_push/local-live/v1 \
  --responses_api_api_key <key from Conduit> \
  --model_name conduit --stream_batch_sentences 1 \
  --num_pipelines 2
```

`serve` listens on `127.0.0.1` only. When it runs on a different machine from
Hermes, add `--host 0.0.0.0` (or that machine's LAN address) and keep the
port closed to anything outside your network.

`--num_pipelines 2` lets the server listen while it speaks. **Copy setup for
your agent** copies all of this as one block, so you can hand it to your
Hermes agent or whoever runs the server. Conduit shows when the server last
asked for words. "Hasn't asked yet" means the address or key on the server
is wrong, or the server hasn't been restarted.

## Step 3: pick Local Live

Under **Voice mode**, pick **Local Live**. It uses the same server, address
and key as step 2, so there's nothing more to set on the server. A call
starts when you tap the voice button. The status screen stays on
"Connecting" until the server has asked Hermes once, so a wrong address
shows up right away.

A server that only reads text aloud (it won't answer on its own) never asks
the model address: the plugin asks Hermes, or the fast model in agent mode,
for each reply and sends the server the words to read. There the call is
ready once the plugin's first exchange with Hermes is done, and "Hasn't
asked yet" in step 2 is expected. With **Hermes answers** on, any server is
used this way, and step 2's screen says there is nothing to set up.

Local Live also works on the Apple Watch with plugin 0.48 or later and
watchOS 11 or later, and in CarPlay.

## Agent mode

Picked under **Voice mode** as **Live > Local**, Local Live adds a **fast
model** in front of Hermes: any OpenAI-compatible model address you choose
(the speech server's own LLM, a local model such as llama.cpp, Ollama, vLLM
or LM Studio, or a hosted fast model). It holds the conversation and answers
right away, and real work goes to Hermes as jobs with their cards in the
call's chat, the same way GPT-Live works. Set the fast model's address,
model and key in step 3 of that screen. Without a fast model, Hermes answers
each turn itself, which is slower to start talking. On a server that only
reads text aloud the fast model answers too, from plugin 0.153.0, and its
replies are read back a sentence at a time like Hermes'. On the Apple
Watch, Hermes still answers each turn itself.

### The speech server's own model as the fast model

A hosted realtime model can hold the call itself instead of a separate fast
model, the way Grok Live's model does. With plugin 0.175 or later, turn on
**The speech server's own model answers** in step 3 of **Live > Local**. The
plugin then gives the server the call's instructions and tools when the call
connects: its model listens, answers and speaks, and hands real work to
Hermes as jobs, with their cards in the call's chat. The call's
instructions go to that service, with the profile's SOUL.md when **Use
Hermes personality** is on. It takes the place of the fast model, so none
needs to be set, and of **Hermes answers** for these calls.

Only Live > Local calls on the phone (and in CarPlay) are answered that way.
Classic voice, Classic's hands-free option and Apple Watch calls on the same
server still get Hermes' replies, read aloud by it, as with **Hermes
answers** on. The server has to take tools and instructions on its session,
as OpenAI Realtime and Qwen's realtime models do; one that only reads text
aloud refuses the call and says why.

Without agent mode (step 3 above), Local Live keeps every utterance a
full Hermes turn. In CarPlay it is listed as Classic, and a call from Hermes
on it opens classic voice, which says why Hermes called. In agent mode a call
from Hermes opens Local Live and the fast model says it.

## When it doesn't work

- **Test connection fails**: the host can't reach the server. Check the
  address from the Hermes machine, not the phone.
- **"Hasn't asked for words yet"**: the server's model address or key is
  wrong, or the server wasn't restarted after you changed them. Copy the
  setup block again.
- **The server answers by itself and Hermes never does**: it has a model of
  its own. Turn on **Hermes answers** under **Your speech server** (see A
  server with a model of its own).
- **"Your speech server doesn't read text back as it's given"**: with
  **Hermes answers** on, the server's model answered the sentences instead of
  reading them. Try another model on that service, or a server that reads
  text aloud.
- **Local Live unavailable**: the plugin is older than 0.42 (0.48 on the
  Apple Watch), or Hermes lacks
  the dashboard token-route support the model address's key needs. Update Hermes and the
  plugin.
- **The reply hears itself on the speaker**: use headphones for now. Echo
  cancellation and talking over the reply on the speaker are being worked on
  for Local Live. Muting the mic on the server also works, but then you
  can't talk over the reply. The Interrupt button still stops it: Conduit
  sends your server a `response.cancel`, so a server that keeps its mic shut
  while it speaks can listen again right away. On a server that only reads
  text back, the cancel reaches it after a sentence it already finished
  from plugin 0.88.
- **Silence while Hermes works, though your server says a filler**: on a
  server that only reads text back, a line it says on its own while Hermes
  works ("let me look that up") plays from plugin 0.134.8, and Hermes'
  answer follows once it ends. Talking over it or Interrupt stops it like
  the reply.

The full API reference (routes, frames and close codes) is in the Conduit
plugin's README, under "Your own speech server" and "Local Live".
