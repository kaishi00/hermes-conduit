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
  dashboard the way your phone does (LAN, Tailscale or a public domain).

## Two ways to use it

| | Classic on your server | Local Live |
|---|---|---|
| What happens | Every time you finish speaking, Hermes answers with its full agent: model, tools and memory. | The same, but as one continuous call instead of separate turns. |
| Feels like | Talking to Hermes, turn by turn. First words take as long as a typed message would. | The same timing as Classic. |
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
```

With only this step, Classic voice listens through your server.

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

Local Live also works on the Apple Watch with plugin 0.48 or later.

## Agent mode (coming)

Today, every Local Live utterance is a full Hermes turn, so even "hey,
what's up?" waits for the agent. Agent mode adds a **front model**: any
OpenAI-compatible model address you choose (the speech server's own LLM, a
local model, or a hosted fast model). The front model holds the conversation
and starts Hermes jobs in the call's chat when there's real work to do. You
hear progress and results as they arrive, the same way GPT-Live works. The
settings will sit under Local Live. Without a front model, Local Live keeps
working as it does today.

## When it doesn't work

- **Test connection fails**: the host can't reach the server. Check the
  address from the Hermes machine, not the phone.
- **"Hasn't asked for words yet"**: the server's model address or key is
  wrong, or the server wasn't restarted after you changed them. Copy the
  setup block again.
- **Local Live unavailable**: the plugin is older than 0.42 (0.48 on the
  Apple Watch), or Hermes lacks
  the dashboard token-route support the model address's key needs. Update Hermes and the
  plugin.
- **The reply hears itself on the speaker**: use headphones for now. Echo
  cancellation and talking over the reply on the speaker are being worked on
  for Local Live. Muting the mic on the server also works, but then you
  can't talk over the reply.

The full API reference (routes, frames and close codes) is in the Conduit
plugin's README, under "Your own speech server" and "Local Live".
