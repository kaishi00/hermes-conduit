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
  with a waveform badge and can be opened like any chat.
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
  the job, as for other notices.
- Gemini Live: a job that finishes while the model is answering something
  else no longer has its result sent on its call straight away (Gemini could
  take it without saying it). The answer waits for the same quiet window; if
  the model still says nothing within 6 seconds, the result is sent again as
  a text turn. A result whose call is withdrawn goes out as a text update,
  and hanging up returns an unsaid one to the job. Grok Live already reported
  results as text turns sent only while quiet.

## Limits of this phase

- The job ledger is in memory. Jobs keep running on the server across app
  restarts, sign-out, and profile switches, but Voice stops following them.
- Voice still suspends when the app goes to the background. Background audio
  and a GPT-Live transport are later phases.

## Live Voice attached to a chat (issue #290)

Live Voice (Gemini, Grok or GPT-Live) started from a chat's mic is attached to that chat for the whole call. Starting it anywhere else (Siri, a wake phrase, CarPlay, a saved call, a Bot Chat, a room, or the sidebar's New voice call button) leaves it unattached, as before. So does starting it from a new chat with no messages yet: there is nothing to continue, so its work runs as jobs on the Voice Jobs model.

- **Requests become the chat's next turn.** Gemini and Grok get `ask_thread`, and GPT-Live delegations go to the chat. No new session is created. The turn is sent as `(voice) <request>`. Hermes' reply comes back to the live model, which summarizes it unless asked to read it out. The full reply stays in the chat.
- **Web lookups stay lookups.** Gemini and Grok still answer quick facts from the web (weather, news, prices) with their web search, not through the chat.
- **Background work is still a job.** A request that asks for work "in the background" or "in a separate chat", or that names another profile, still creates its own Voice Jobs session. The same rule routes Gemini's and Grok's `start_job` in an attached call: the models reach for it out of habit, so a `start_job` without those words goes to the chat like `ask_thread` and is answered with the chat's reply.
- **"Quick, …" runs fast.** A request the user starts with "quick" (or 「快，」) stays out of the chat. Gemini and Grok answer a quick fact with a web search and send quick work that needs Hermes' tools to `start_job`. GPT-Live is told to start the delegation with "Quick:", which Conduit routes to a job. Jobs run on the Voice Jobs model, up to three at once. "Quick question, …" is a figure of speech and still goes to the chat. The call sheet mentions this the first three times a call is attached.
- **"Read the last reply"** (`read_last_reply`, or a GPT-Live delegation asking to read or repeat the last reply) returns the chat's latest assistant message without a new turn. When the chat isn't open, it is read from the chat's saved history. Natural requests count too ("repeat that", "say that again", "read the last message"), and hesitations like "uh" are ignored. On GPT-Live, Conduit also checks the user's own words: if they ask to hear the last reply, Hermes' reply is sent to be read out even when the model answers from memory instead of delegating. A delegation for the same request within 10 seconds is told the reply is already on its way, so it is read once.
- **One voice turn at a time per chat, in order.** Up to three are in flight; a fourth is refused. Each waits for anything already running in the chat (a typed message) to finish. When the chat is open, voice never steers or interrupts typed work, and a typed message that starts just as a voice turn is sent is waited for too. When it isn't, the check and the send are separate round trips: if Hermes reports that it added the voice request to a turn that started in between, or queued it, the voice turn ends and says so rather than sending it again. A gateway that doesn't report this can't be told apart from a new turn. Typing while a voice turn runs follows the composer's Steer/Interrupt setting, as for any running turn.
- **On screen or not.** When the attached chat is open, the turn goes through the composer's own send path, so it shows and streams like a typed message. Otherwise the chat is resumed if it isn't live, and the turn is tied to that runtime before the prompt is submitted, so none of its events are missed. The supervisor follows the turn by its session events, plus the liveness poll as a fallback.
- **Typed turns reach the call quietly (#363).** When a turn the call didn't start finishes in the attached chat (the user typed it, in Conduit or on another device), the live model gets a note with what was typed and Hermes' reply, fenced as data, with the reply clipped to 3,000 characters and the typed text to 2,000. The typed message is included only when the open chat shows it as the one message since the last reply (not one typed on another device, nor one queued behind it), with its attachments named (`[Attached: board.jpg (image)]`): the live models can't see pictures, but Hermes looks at them with its own or its vision helper model, and its reply arrives as text. The note is context, not a turn: Gemini gets it as `clientContent` with `turnComplete: false`, Grok as a conversation item with no `response.create`, and GPT-Live on the `commentary` channel. It goes out only while the call is quiet, and the model is told to stay quiet about it until the user brings it up. Up to three wait at once; older ones are dropped (the chat still has them), and hanging up drops any not yet sent. A typed message that steers a running voice turn is part of that turn and comes back with its reply, not as a note.
- **Hanging up** drops requests still waiting their turn. A turn already sent keeps running in the chat.
- **The call's own transcript is saved separately, under Voice.** The chat gets a "Voice call" marker where the call started, with its length; tapping it opens the saved transcript. The transcript gets a "Started from <chat>" card that opens the chat, and each request the call sent to the chat is noted there as "Asked the chat: … [Open chat]". The chat's card matches on the chat's stored id (a runtime id only names it while open). The work the call handed to Hermes is already in the chat as ordinary turns, so the spoken back-and-forth stays out of the chat and out of Hermes' context for the next typed message (the host also refuses to write a call into an ordinary chat). The link is kept on the device (up to 300 calls), so another device shows no marker.
- **Resume Call goes back to the chat.** Resuming a saved call that was attached to a chat attaches the new call to the same chat, which gets a "Voice call resumed" marker.
