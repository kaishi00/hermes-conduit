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
