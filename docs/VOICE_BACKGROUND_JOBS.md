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
- A saved live call gets a line where it started the job ("Started a
  background job: <title>.") with an **Open job** link to the job's chat, so
  the full result is a tap away even when the voice model only summarized it.
  The link is `conduit://session/<id>`, handled in-app by the root view's
  `openURL` action (no URL scheme is registered); other clients show it as an
  inert link. It is stripped from resumed-call context and title prompts. A
  job on another profile gets the line without a link.
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

## Limits of this phase

- The job ledger is in memory. Jobs keep running on the server across app
  restarts, sign-out, and profile switches, but Voice stops following them.
- Voice still suspends when the app goes to the background. Background audio
  and a GPT-Live transport are later phases.

## Live Voice attached to a chat (issue #290)

Live Voice (Gemini, Grok or GPT-Live) started from a chat's mic is attached to that chat for the whole call. Starting it anywhere else (Siri, a wake phrase, CarPlay, a saved call, a Bot Chat, a room, or the sidebar's New voice call button) leaves it unattached, as before. So does starting it from a new chat with no messages yet: there is nothing to continue, so its work runs as jobs on the Voice Jobs model.

- **Requests become the chat's next turn.** Gemini and Grok get `ask_thread`, and GPT-Live delegations go to the chat. No new session is created. The turn is sent as `(voice) <request>`. Hermes' reply comes back to the live model, which summarizes it unless asked to read it out. The full reply stays in the chat.
- **Web lookups stay lookups.** Gemini and Grok still answer quick facts from the web (weather, news, prices) with their web search, not through the chat.
- **Background work is still a job.** `start_job`, or a GPT-Live delegation that asks for it "in the background" or "in a separate chat", still creates its own Voice Jobs session.
- **"Quick, …" runs fast.** A request the user starts with "quick" (or 「快，」) stays out of the chat. Gemini and Grok answer a quick fact with a web search and send quick work that needs Hermes' tools to `start_job`. GPT-Live is told to start the delegation with "Quick:", which Conduit routes to a job. Jobs run on the Voice Jobs model, up to three at once. "Quick question, …" is a figure of speech and still goes to the chat. The call sheet mentions this the first three times a call is attached.
- **"Read the last reply"** (`read_last_reply`, or a GPT-Live delegation asking to read or repeat the last reply) returns the chat's latest assistant message without a new turn. When the chat isn't open, it is read from the chat's saved history.
- **One voice turn at a time per chat, in order.** Up to three are in flight; a fourth is refused. Each waits for anything already running in the chat (a typed message) to finish. When the chat is open, voice never steers or interrupts typed work, and a typed message that starts just as a voice turn is sent is waited for too. When it isn't, the check and the send are separate round trips: if Hermes reports that it added the voice request to a turn that started in between, or queued it, the voice turn ends and says so rather than sending it again. A gateway that doesn't report this can't be told apart from a new turn. Typing while a voice turn runs follows the composer's Steer/Interrupt setting, as for any running turn.
- **On screen or not.** When the attached chat is open, the turn goes through the composer's own send path, so it shows and streams like a typed message. Otherwise the chat is resumed if it isn't live, and the turn is tied to that runtime before the prompt is submitted, so none of its events are missed. The supervisor follows the turn by its session events, plus the liveness poll as a fallback.
- **Hanging up** drops requests still waiting their turn. A turn already sent keeps running in the chat.
- The call's own transcript is still saved separately, under Voice.
