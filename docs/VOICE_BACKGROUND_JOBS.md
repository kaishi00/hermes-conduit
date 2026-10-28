# Voice background jobs

Phase 1 of issue #163. A Voice conversation can hand longer work to Hermes and
keep talking while it runs. GPT-Live is not involved yet: this phase uses the
existing Voice pipeline (speech-to-text, Hermes, text-to-speech).

## Spoken commands

Recognized on a finished utterance, after End Conversation and Stop.

| Say | Effect |
|---|---|
| "background job, …" / "start a background job …" / "run in the background …" / 「后台任务…」 / 「在后台运行…」 | Starts a job with the rest of the utterance as its task. |
| "job status" / "background jobs" / 「后台任务状态」 | Speaks the state of each job. |
| "cancel background jobs" / 「取消后台任务」 | Interrupts every running job. |

Status and cancel match the whole utterance only. A start needs the leading
phrase plus a task; a sentence that merely mentions a background never starts
a job. At most three jobs run at once.

## How a job runs

- Each job is a new, ordinary Hermes session (`session.create` +
  `prompt.submit`), titled from the task. It shows up in the session list
  with a waveform badge and can be opened like any chat. Once Hermes has
  answered it, the plugin archives it with Hermes' auto-archive stamp, so
  Hermes Desktop's list doesn't fill up with voice jobs; Conduit keeps
  listing it under its call. That holds while only voice has used it (its
  prompt, and corrections sent as `(voice) <words>`): typing into it brings
  it back for good, and a failed, stopped or pinned job stays listed.
- During a live call, the call screen shows each job the call started: the
  latest above the captions, and every one in the transcript panel where it
  started (`VoiceJobCallAnchor`). Tapping one shows its status and, once it
  finishes, its full final reply over the call, with **Open chat** to leave
  for the job's chat. The reply is already on the phone, so nothing is
  written to the host mid-call (mid-call saves stalled Gemini Live, PR #281).
- Gemini Live and Grok Live also have a `show_on_screen` tool (title and
  Markdown) for anything better seen than heard: tables, Mermaid charts
  (`xychart-beta`, `pie`), steps, image and web links. The card opens over
  the call as it arrives, rendered like a chat reply, and stays in the
  transcript panel where it was shown; the model says it's on screen and
  gives the gist. Cards live only on the phone, for the call (the last 20,
  each up to 20,000 characters), and are not part of the saved call.
  Pictures depend on the model finding a direct image URL. When the phone's
  call screen isn't up (a call only CarPlay shows, a minimised call, the app
  in the background) the tool refuses and the model says it instead.
  GPT-Live has no screen tool yet.
- A phone call can also find one of the user's earlier chats and open it
  ("find the chat where we discussed the GPU setup and open it"). Gemini
  Live and Grok Live call `find_chat` (a few words from the topic) and then
  `open_chat` (the match's number); GPT-Live delegates `Find chat: <words>`
  and `Open chat: <number>`, which Conduit answers itself. The search is
  Hermes' own `GET /api/sessions/search` on the profile in use (ids, message
  text, then titles); a query that matches nothing as a whole is tried a word
  at a time, and a Hermes without the route is searched by the titles of the
  chats Conduit lists. Up to five matches go to the model, numbered, with
  title, age and a line from the chat; it opens one that clearly fits or
  asks which. Opening minimises the call sheet, as **Open chat** does, and
  the call goes on. A call CarPlay shows has nowhere to open a chat, so
  `open_chat` refuses there and the model says so. A found chat can also be
  read into the call so the user can talk about it, opened or not, CarPlay
  included: `read_chat` (the match's number; NON_BLOCKING) or
  `Read chat: <number>` on GPT-Live. It gets the chat's user and Hermes text
  the way a resumed call gets a saved call's: word for word when short, else
  a summary of the older part (a saved call's stored one, else made for the
  read) plus the latest turns, fenced as data. A Watch call (Gemini, Grok,
  GPT-Live) finds and reads chats but can't open one. With conduit_push 0.18 on the host (capability
  `watch-chats`) both tools run through the call's relay grant, wrist up or
  down, and the host keeps the numbered matches `read_chat` names; the
  plugin reads the chat in process and trims the answer to 16 KB. With an
  older plugin a Gemini or Grok Watch call asks the phone instead, wrist up
  only.
- A saved live call gets a line where it started the job ("Started a
  background job: <title>.") with an **Open job** link to the job's chat, so
  the full result is a tap away even when the voice model only summarized it.
  The link is `conduit://session/<id>`, handled in-app by the root view's
  `openURL` action (no URL scheme is registered); other clients show it as an
  inert link. It is stripped from resumed-call context and title prompts. A
  job on another profile gets the line without a link. The link holds only
  the session id and opens on the profile in use, which is the call's own
  profile whenever its transcript is open.
- `VoiceBackgroundJobSupervisor` follows the job through gateway events
  (observed before AppState's active-session filter). `session.active_list`
  is polled as a fallback for a completion event that never arrived.
- Approvals and clarifications stay where they are today: the job's chat and
  the push notification. Voice only says that the job is waiting. Voice
  approvals will be a per-user setting in a later phase.

## Hand-back

Updates are delivered only in a quiet listening window (nobody speaking, no
reply pending or playing):

- A finished job's final message is submitted to the voice conversation's own
  session with a request to summarize it aloud, so follow-up questions have the
  context. If that submission fails, Voice says the job finished and to open
  its chat.
- Failures, cancellations from elsewhere, and "waiting for input" are spoken
  as short local notices without a Hermes turn.
- GPT-Live (#379): a delegation's result (a job's or the chat's reply) waits
  for the same quiet window instead of going out the moment it arrives. A
  pause mid-sentence doesn't count while the user's words are still coming
  in, and the model answers what the user just said first. When the user kept
  talking after asking, the result tells the model to deal with anything they
  said since (passing it on to Hermes if needed) and then say that Hermes has
  come back on the earlier request. Hanging up returns an unsaid result to
  the job, as for other notices, and so does a reconnect that replaces the
  conversation while a result is still on its way (#1223). A quiet result
  the conversation couldn't take yet waits for the next quiet window instead
  of being dropped.
- Gemini Live: a job that finishes while the model is answering something
  else no longer has its result sent on its call straight away (Gemini could
  take it without saying it). The answer waits for the same quiet window; if
  the model still says nothing within 6 seconds, the result is sent again as
  a text turn. A result whose call is withdrawn goes out as a text update,
  and hanging up returns an unsaid one to the job. Grok Live already reported
  results as text turns sent only while quiet.
- A result is checked for being said (#1210). A text update with a job's
  result, the only way Grok Live and Local Live hear one, counts as told once
  the model has said something since; if it hasn't within 6 seconds, the
  result goes out once more and then counts as told, never sent a third
  time. The same goes for Gemini's
  text updates, GPT-Live's delegation results and job notices, and job news
  on Apple Watch calls, whether the job runs on the push relay or on the
  iPhone. A result already sent when the call ends counts as told, as
  before: it isn't carried into the next call.
- `list_jobs` (and Classic's job status, GPT-Live's status note and the
  Watch's job list) names a finished job until its result counts as told: a
  result waiting for a quiet moment, or sent and not yet said or sent again,
  keeps the job listed as finished. Before, a job left the list as soon as its result was
  queued, so a call that never got to say it showed no job and no result.

## Limits of this phase

- The job ledger is in memory. Jobs keep running on the server across app
  restarts, sign-out, and profile switches, but Voice stops following them.
- Voice still suspends when the app goes to the background. Background audio
  and a GPT-Live transport are later phases.

## Live Voice attached to a chat (issue #290)

Live Voice (Gemini, Grok or GPT-Live) started from a chat's mic is attached to that chat for the whole call. So is a call started in CarPlay after picking a chat from its chat list, including one started with CarPlay's Listen button after that pick. A Bot Chat counts: its turns, liveness reads and saved history are addressed to the bot's profile, and its links open the bot's chat (`conduit://bot/<profile>`). Starting it anywhere else (Siri, a wake phrase, CarPlay without a picked chat, a saved call, a room, or the sidebar's New voice call button) leaves it unattached until its first ordinary request. So does starting it from a new chat with no messages yet: there is nothing to continue yet.

**An unattached call takes its first request's chat (#1250).** In Gemini, Qwen, Grok, GPT-Live and Local Live agent mode, on the phone and in CarPlay, the call's first ordinary request runs as a job on the Voice Jobs model, and once Hermes takes it, that job's chat becomes the call's: everything below applies to it from then on, as if the call had started there. Later requests are its next turns, so Hermes has the earlier ones, and wait while the first one still runs; a correction while it runs goes into it, as into the only running job (#472). Background, "quick" and other-profile work still runs as jobs of its own, and a first request of that kind leaves the call unattached. A request said while the first one is still making its chat waits and joins that chat. A first request that finishes starting after the hang-up attaches nothing, and the next call makes its own chat. The chat is the call's, not one of its jobs: it gets no job badge and isn't filed under the call, the call is kept with it when it ends, and Resume Call goes back to it. The saved call notes the first request as "Asked the chat". At hang-up the first request is let go of like the call's other turns there: if it still runs, its reply lands in the chat and no later call announces it. The live model's instructions are written when the call starts, so they don't gain the attached-chat block; `start_job`'s description (Gemini, Qwen, Grok, Local Live) and GPT-Live's delegation rules say how the first request's chat is used. An Apple Watch call has no attached chat, so it keeps its jobs as they are: each later ordinary one is still a job of the call, with its own news and number, but runs as the next turn of the chat its first one made, once nothing else runs there. The Watch marks a `start_job` that isn't kept apart with `joins_call` for the relay (notifier 0.78; an older plugin gives each job its own chat), and the iPhone does the same for the jobs it runs for the call (`continueJob`).

- **Requests become the chat's next turn.** Gemini and Grok get `ask_thread`, and GPT-Live delegations go to the chat. No new session is created. The turn is sent as `(voice) <request>`. Hermes' reply comes back to the live model, which summarizes it unless asked to read it out. The full reply stays in the chat.
- **Web lookups stay lookups.** Gemini and Grok still answer quick facts from the web (weather, news, prices) with their web search, not through the chat. GPT-Live does the same with a `Look up: <query>` delegation when the host has a web search backend (and Web lookups isn't off): Conduit runs the host's search and answers on the delegation, with no Hermes job.
- **Background work is still a job.** A request that asks for work "in the background" or "in a separate chat", or that names another profile, still creates its own Voice Jobs session. The same rule routes Gemini's and Grok's `start_job` in an attached call: the models reach for it out of habit, so a `start_job` without those words goes to the chat like `ask_thread` and is answered with the chat's reply.
- **"Quick, …" runs fast.** A request the user starts with "quick" (or 「快，」) stays out of the chat. Gemini and Grok answer a quick fact with a web search and send quick work that needs Hermes' tools to `start_job`. GPT-Live is told to start the delegation with "Quick:", which Conduit routes to a job. Jobs run on the Voice Jobs model, up to three at once. "Quick question, …" is a figure of speech and still goes to the chat. The call sheet mentions this the first three times a call is attached.
- **"Read the last reply"** (`read_last_reply`, or a GPT-Live delegation asking to read or repeat the last reply) returns the chat's latest assistant message without a new turn. When the chat isn't open, it is read from the chat's saved history. Natural requests count too ("repeat that", "say that again", "read the last message"), and hesitations like "uh" are ignored. On GPT-Live, Conduit also checks the user's own words: if they ask to hear the last reply, Hermes' reply is sent to be read out even when the model answers from memory instead of delegating. A delegation for the same request within 10 seconds is told the reply is already on its way, so it is read once.
- **One voice turn at a time per chat, in order.** Up to three are in flight; a fourth is refused. Each waits for anything already running in the chat (a typed message) to finish. When the chat is open, voice never steers or interrupts typed work, and a typed message that starts just as a voice turn is sent is waited for too. When it isn't, the check and the send are separate round trips: if Hermes reports that it added the voice request to a turn that started in between, or queued it, the voice turn ends and says so rather than sending it again. A gateway that doesn't report this can't be told apart from a new turn. Typing while a voice turn runs follows the composer's Steer/Interrupt setting, as for any running turn.
- **On screen or not.** When the attached chat is open, the turn goes through the composer's own send path, so it shows and streams like a typed message. Otherwise the chat is resumed if it isn't live, and the turn is tied to that runtime before the prompt is submitted, so none of its events are missed. The supervisor follows the turn by its session events, plus the liveness poll as a fallback.
- **Typed turns reach the call quietly (#363).** When a turn the call didn't start finishes in the attached chat (the user typed it, in Conduit or on another device), the live model gets a note with what was typed and Hermes' reply, fenced as data, with the reply clipped to 3,000 characters and the typed text to 2,000. The typed message is included only when the open chat shows it as the one message since the last reply (not one typed on another device, nor one queued behind it), with its attachments named (`[Attached: board.jpg (image)]`): the live models can't see pictures, but Hermes looks at them with its own or its vision helper model, and its reply arrives as text. The note is context, not a turn: Gemini gets it as `clientContent` with `turnComplete: false`, Grok as a conversation item with no `response.create`, and GPT-Live on the `commentary` channel. It goes out only while the call is quiet, and the model is told to stay quiet about it until the user brings it up. Up to three wait at once; older ones are dropped (the chat still has them), and hanging up drops any not yet sent. A typed message that steers a running voice turn is part of that turn and comes back with its reply, not as a note.
- **Hanging up** drops requests still waiting their turn. A turn already sent keeps running in the chat.
- **The call's own transcript is saved separately, under Voice.** The chat gets a "Voice call" marker where the call started, with its length; tapping it opens the saved transcript. The transcript gets a "Started from <chat>" card that opens the chat, and each request the call sent to the chat is noted there as "Asked the chat: … [Open chat]". The chat's card matches on the chat's stored id (a runtime id only names it while open), and only on the open chat's own ids: its row's ids and the durable id Hermes confirmed for its runtime. The chat scroll identity's aliases are not used, since a new chat (or one opened from another) keeps the previous chat's ids there. Resume Call matches a saved call the same way. The work the call handed to Hermes is already in the chat as ordinary turns, so the spoken back-and-forth stays out of the chat and out of Hermes' context for the next typed message (the host also refuses to write a call into an ordinary chat). The link is kept on the device (up to 300 calls), and the host lists every chat's kept calls with the voice tags, so another device adopts the ones it lacks and shows their markers too. Voice lists every chat a call was kept with or started from, beside the call rows.
- **Resume Call goes back to the chat.** Resuming a saved call that was attached to a chat attaches the new call to the same chat, which gets a "Voice call resumed" marker.
