# Feature map

Features that have siblings: other screens, voice modes or notifier pieces
that must do the same thing. A change that reaches one sibling and not the
others leaves a gap that users find later. Each entry lists the siblings,
where their code lives, the rulings that decide how they behave, and the gaps
already known.

Before changing a feature, read its entry and put every sibling on the plan.
In the PR, say for each sibling whether it's done, not needed (and why), or
left as a gap, and update the entry in the same PR. Nobody tends the map
separately: a feature with siblings and no entry gets one in the PR that
changes it, and a fix that brings a sibling in line with a change it missed
adds that sibling to the entry. A refactor that changes no behavior and no
user-facing or model-facing text has no siblings and needs no new entry; if it
moves code an entry's Code lists, it updates those paths and the Checked line.
[CONTRIBUTING.md](../CONTRIBUTING.md) has the rules.

An entry holds the current state only; history stays in the PRs it cites.
Keep each to about a screen, and split one that grows past that. Every entry
has Siblings, Code, Rulings, Open gaps and a Checked line (the date of the
last check against the code, and the PR that checked it; an entry seeded from
main may name a commit). `scripts/check-feature-map.py` runs in CI: it checks
that shape, that every path in backticks exists, and that an entry a PR adds
or edits names that PR on its Checked line (on a PR into `pulse` or
`linked-rooms` that merges main, one main changed since that branch last took
it that matches main's copy came in with main). A path that starts with
notifier/ is in
[hermes-conduit-notifier](https://github.com/kaishi00/hermes-conduit-notifier),
checked against its main.

**Sibling sets.** Most entries draw on these. A change to one member is
checked against the rest, and where one can't follow, the PR says so and the
maintainer decides (2026-10-20).

- Voice modes: Classic (hands-free on a speech server too), Gemini Live, Qwen Live, Grok
  Live, GPT-Live, Local Live (agent mode, and Hermes turns).
- Where a call runs: the phone's call screen, the minimised call bar,
  CarPlay, a call from Hermes (CallKit, locked phone), the Apple Watch.
- Phone features: reminders, calendar, alarms and timers, contacts, health,
  location.
- Chat surfaces: chats, project chats, Bot Chat, group rooms.
- Text that describes a behavior: Settings captions, the briefings and tool
  results models read, the notifier's tool descriptions and skills,
  README.md and docs/.

## Hermes is waiting on you

An approval, a clarify question or a phone change that Hermes can't go on
without.

**Siblings:** chat card · notification · Classic voice (phone, CarPlay) ·
Gemini Live · Qwen Live · Grok Live · GPT-Live · Local Live · Watch calls ·
a call from Hermes about it · a confirmation Hermes shows on the call screen · group
rooms · your agents' approvals in rooms other people host · a room's ask to
its owner (Ask me first; app side C5c on the `linked-rooms` branch only, see
Linked Rooms) · a linked person's ask to its owner (asks between linked agents;
app side C7 on the `linked-rooms` branch only, see Linked Rooms) · the resume
jump · what models and Settings say about it

| Where | Says it | Answer by voice | Card on screen |
|---|---|---|---|
| Classic | approvals, and questions with their numbered choices | approvals and phone changes, yes or no; a question's answer, by number, label or own words | over the voice sheet (approval or question card); not on CarPlay |
| Gemini, Qwen, Grok, GPT-Live | a job's approval or question, with its choices | job approvals, once or deny; job questions by number or own words | above the job strip: the call's chat card, else the job's Run and Reject or choices |
| Local Live | approvals and questions, with choices | yes or no; a question's answer | as Gemini (one call screen) |
| Watch | job approvals; a call from Hermes' question or approval | Gemini, Qwen, Grok and Local Live answer the call's question, and its approval when "Approve from the Watch" is "Tap or voice"; GPT-Live answers questions only | Approve once and Deny |
| Group rooms | no voice | no voice | Run and Reject above the composer |

A call Hermes made about an approval or question is briefed from the
chat's card: every question with its numbered choices (marked
"(Recommended)" as Hermes wrote them), the command and why, and what Hermes
wrote before asking. The user answers by voice: `answer_approval` and
`answer_question` on Gemini, Qwen, Grok and Local Live agent mode, "Approve:",
"Deny:" and "Answer:" on GPT-Live. A number or "the recommended one" sends
what that choice's tap sends. Hermes is paused while it waits, so asking it
to explain goes as the answer itself, starting "Before I choose:". On the
Watch the iPhone reads the plugin's copy (`GET /calls/waiting`) and the
answer goes to the host through the grant's `answer_call`, bound to the
call's chat (plugin 0.70.0, capability hermes-call-answers). On Local Live
the host answers with the user's words (`_local_live_call_answer`).

Several questions with at least one to type in are a form (`isForm`): the
chat card shows a field for each, a text box or a menu of its choices
(with Something else… and Leave blank), and one Send. A field left blank
goes back empty, which Hermes reads as skipped, and shows Skipped, in
history too. A single question, or choices only, keeps the card that
answers each one. Voice asks a form one question at a time, saying it may
be left blank, and "skip" in the app's languages leaves it so
(`HermesCallWaiting.isSkip`; the plugin's `is_skip` for the Watch); a job's
card on the call screen has Leave blank. Through the relay a blank goes
empty when sealed or to relay 0.18 (capability clarify-skip), else as
"(left blank)". Conduit's chat note asks Hermes for a form when it needs
several details only the user can give (notifier 0.82).

**Code**
- Chat card: `Conduit/Views/ChatView.swift` (ApprovalCard, ClarifyCard, ClarifyQuestionRow's form field), `Conduit/Services/ApprovalDisplayText.swift`, `Conduit/Services/AppState.swift` (respondToApproval, legacyApprovalTarget, respondToClarifyForm)
- Forms and blank answers: `Conduit/Models/Models.swift` (ClarifyActivity.isForm, ClarifyQuestion.formAnswer, isSkipped), `Conduit/Models/ClarifyHistoryRecord.swift`, `Conduit/Services/HermesClient.swift` (pendingClarifyActivity), `Conduit/Services/PushNotificationService.swift` (blankAnswer)
- What waits, and spoken picks: `Conduit/Voice/HermesCallWaiting.swift` (block, answerRule, pickedChoices, spokenQuestion, isSkip)
- Classic and Local Live: `Conduit/Services/AppState+SpokenApprovals.swift` (answerQuestionBySpeech, noteClarifyForClassicVoice, openChatWaitingCards), `Conduit/Voice/SpokenApprovals.swift`, `Conduit/Voice/VoiceConversationController.swift` (noteApprovalWaiting), `Conduit/Views/VoiceConversationSheet.swift` (VoiceApprovalPanel), `Conduit/Voice/LocalLive/LocalLiveTurnRunner.swift` (approvalLine, waitingQuestion)
- Live modes: `Conduit/Voice/VoiceBackgroundJobs.swift` (waitingNotice, answerJobApproval, answerJobQuestion), `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift`, `Conduit/Voice/GPTLive/GPTLiveConversationController.swift` (jobApprovalRule), `Conduit/Views/LiveVoiceCallJobs.swift` (LiveVoiceWaitingPanel), `Conduit/Views/LiveVoiceCallSheet.swift`
- Call from Hermes: `Conduit/Voice/HermesCalls.swift` (instructionBlock), `Conduit/Services/AppState+HermesCalls.swift` (liveHermesCallInstructions, noteHermesCallChatWaiting, answerHermesCallApproval, answerHermesCallQuestion, watchHermesCallWaiting)
- Phone changes: `Conduit/Phone/PhoneChangeConfirmation.swift`, `Conduit/Phone/PhoneVoiceTools.swift` (confirmsChange)
- Call-screen confirmations: `Conduit/Services/PresentedScreens.swift` (PresentedConfirm.isConfirmed), `Conduit/Views/PresentedConfirmPanel.swift`, `Conduit/Views/RootView.swift` (presentedConfirmOverlay), `Conduit/Voice/VoiceBackgroundJobs.swift` (VoiceThreadRouting.containsRefusal), tests in `ConduitTests/PresentedScreensTests.swift`
- Watch: `ConduitWatch/WatchCallView.swift` (WatchApprovalCard), `ConduitWatch/WatchDirectCallModel.swift` (answerCallThroughRelay, answerApprovalByVoice, answer: said as a text update when the call reconnects), `ConduitWatch/WatchBridgeCallModel.swift` (answerCall), `Shared/WatchVoice/WatchCallAnswer.swift`, `Shared/WatchVoice/WatchJobRelay.swift`, `Conduit/Watch/WatchDirectBroker.swift` (grants), `Conduit/Watch/WatchToolGrantClient.swift` (answer_sessions, answer_approvals), `Conduit/Watch/WatchSettingsSection.swift`
- Group rooms: `Conduit/Views/GroupChatView.swift` (GroupApprovalCard)
- Resume jump: `Conduit/Services/ChatResumeCoordinator.swift` (pendingClarifyMessageID, PendingDecisionKind), `Conduit/Views/ChatView.swift` ("Go to your question", "Go to the approval", "Go to the request" for an input card)
- Settings text: `Conduit/Views/GeminiLiveViews.swift`, `Conduit/Views/HermesCallSettingsViews.swift` (the alert-call captions)
- When a call about it rings: `notifier/calls.py` (alert, _quiet_at_screen, _at_screen, SCREEN_ALERT_DELAY_S), `notifier/calls_store.py` (add_alert)
- Rooms other people host: `notifier/room_approvals.py` (your agents' approvals there, the session their notification names, the answer through this Hermes' API server), `notifier/dashboard/api/linked_rooms.py` (/rooms/approvals, /rooms/approvals/answer, capability room-approvals), `notifier/cli.py` (rooms approvals, approve, deny)
- Notifier: `notifier/events.py` (the push), `notifier/clarify_loop.py` (a call's answer wins), `notifier/calls_store.py` (the waiting copy, map_answer, is_skip, may_leave_blank), `notifier/calls.py` (follow_approval), `notifier/__init__.py` (the approval hook), `notifier/dashboard/api/hermes_calls.py` (/calls/waiting), `notifier/dashboard/api/watch_local_live.py` (answer_call, _local_live_call_answer), `notifier/phone_tool.py` (the wording models read), `notifier/turn_surface.py` (FORM_HINT), `notifier/relay/src/server.mjs` (a batch question's blank answer)
- Background time: `Conduit/Services/BackgroundTaskHold.swift` (the Watch broker's grant answers keep Conduit running through it)

**Rulings**
- A spoken answer counts only when exactly one item is waiting, and for an approval it can only approve once or deny; a question takes a choice or the user's own words (2026-10-20, #991; questions answered by voice too, Eric 2026-10-24, #1194).
- A phone change needs the user's own yes, as their next words after the reply that asked (2026-10-20, #991, #1051).
- Only the user's own words answer: never the model's judgment, a web page or a job's output (2026-10-20, #991).
- What a refusal is, the handset decides: on a call-screen confirmation, a no, cancel, wait or refuse verb in the user's words, in any shipped language, vetoes whatever Hermes listed in spoken_yes. Classic approvals and phone changes take only the handset's own yes, so no Hermes-listed phrase reaches them (2026-10-24, #1042, #1191).
- A spoken pick that points at one choice ("two", "the recommended one", its label) sends what its tap sends; anything else goes to Hermes as the user's words (2026-10-24, #1194).
- Asking Hermes to explain while it waits is the answer itself, starting "Before I choose:" (for an approval, a deny's reason, only on the Watch's Local Live, whose host denies with the user's words; the other approval answers carry no reason), since its turn is paused on the prompt (2026-10-24, #1194).
- On the Watch, an approval is answered by voice only with "Approve from the Watch" on "Tap or voice" (the grant's `answer_approvals`), and never by GPT-Live; `answer_call` answers only the call's own chat (2026-10-24, #1194, notifier #343).
- A call from Hermes rings a Watch on Local Live too: the speech server says why Hermes called, the host takes the user's words as the answer, and what they say after goes to the Watch call's own chat (Eric 2026-10-24, replacing the iPhone-only rule; #1194, notifier #343).
- CarPlay shows no card: Apple allows only the voice control template while voice runs, so the ask is spoken and the listening window takes the answer (2026-10-24, #1194).
- Classic's notice tells the user to hold to talk under push to talk, and to answer on the card while the microphone is paused (2026-10-24, #1194).
- The resume jump and its button go to the newest question, approval or input card (a password, login or code) waiting on the user (2026-10-24, #1194; input cards 2026-10-26, #1301).
- A voice mode says an approval went only once Hermes took it: the phone's modes read the gateway's `resolved` count (expired otherwise), and the Watch's `answer_call` and Local Live wait up to 10 seconds for the plugin's follower to settle it, saying it didn't go through when no pending request was the one read out, and taking back an answer nothing picked up (2026-10-24, notifier 0.70.1).
- Most questions stay multiple choice: only several questions with one to type in make a form. A form sends once something in it is filled in, and its blank fields go to Hermes as skipped (Eric 2026-10-26, #1294, notifier #391).
- An approval one of your agents' turns waits for in a room someone else hosts is answered only on your own Hermes, once or deny, never by the room's host. Its notification goes out as for any chat, named by the agent's hidden chat for the room, which the chat card's `approval.respond` can't reach (4001 on Hermes c73cbcc4), so the plugin's list names that `session_key` and the answer goes through POST /rooms/approvals/answer. A call from Hermes about one answers it as about any other approval, since `calls.follow_approval` answers Hermes' own queue by that key (2026-10-27, notifier #416).
- "Skip" leaves only a form's question blank. Only a choice the words name whole ("Pass") is picked instead, not one inside them ("leave it blank" beside a choice called Blank), and a question or a negation ("don't skip it") is an answer; the phone and the plugin read it the same way (2026-10-26, #1294, notifier #391).
- On the chat card, here, on Classic voice's screen and on a live call's screen (VoiceApprovalPanel, which LiveVoiceWaitingPanel shows, draws the same cards), the card's caption and its time share the top row, the time on the right on one line (a long caption wraps beside it), and the description or question runs the card's full width below, never in a column beside the time; at the accessibility text sizes the time goes under the caption (2026-10-29, #1507, issue #1440).

**Open gaps**
- Group rooms: the card's failure line shows the error text raw, while the chat card reveals hidden characters in its error and expiry text (#951 follow-up).
- Your agents' approvals in rooms other people host have no card in the app yet, and their notification opens a hidden chat the app doesn't show, whose card couldn't answer them. C3 (on `linked-rooms`) adds the card, matched to the notification by its `session_key`; until then `hermes conduit-push rooms approvals`, `approve` and `deny` answer them, as does a call from Hermes about one.

**Checked:** 2026-10-30, #1544 (a call from Hermes about an approval or question waits longer while the user is at a screen, an approval until shortly before Hermes would deny it; the card, the notification and the voice answers unchanged; notifier #479); 2026-10-30, #1524 (group rooms' Markdown gets the connected Hermes' resolver for Desktop cards; approval cards unchanged); 2026-10-29, #1507 (the chat card's time top right, its description or question full width below, #1440); 2026-10-29, #1497 (a linked person's ask to its owner in the siblings, notifier #465); 2026-10-29, #1485 (a room's ask to its owner in the siblings; the call-screen confirmation's panel and overlay listed in Code); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1449 (Local Live's screen shows a reply's attached files); 2026-10-27, #1351 (your agents' approvals in rooms other people host, notifier #416); 2026-10-26, #1301 (the jump button goes to input cards too); 2026-10-26, #1294 (clarify forms: a field for each question and one Send, blanks skipped on every transport, "skip" by voice; notifier #391); 2026-10-26, #1247 (the Watch broker's grant answers keep Conduit running through BackgroundTaskHold); 2026-10-25, Qwen in the siblings, the table and the Watch row, at #1182, carried in #1235; 2026-10-24, at #1221, for a Watch call's answer or voice approval whose reply lands while the call reconnects (said as a text update, not dropped); at #1207 (notifier 0.70.1), for the Watch's "approved" when nothing ran; at #1194 (after #1188, the approval card's shield); at #1191: message.interim ends a Local Live reply's approval wait and a voice job's needs-input state, as other output does (#912 review); the chat card's #951/#952 follow-ups; the call-screen confirmation's refusal veto (#1042).

## Passwords, logins and codes Hermes asks for

A value only the user may give, typed on a card and sent straight to the
tool that asked, never into the chat or to the model: a sudo password, a
secret, a password manager's master password, a website's login (Hermes is
on its sign-in page and has none saved) or a website's one-time code.
Hermes asks with a server request (`sudo`, `secret`, `vault.unlock_prompt`,
`vault.save_login`, `vault.code`), answered `{value}`; an empty value skips.

**Siblings:** chat card (chats, project chats, Bot Chat) · reopening the
chat (a resume's `open_requests`) and Hermes withdrawing it
(`request.cancel`) · the jump button · Classic voice's screen and the call
screen · the minimised call bar · voice modes saying Hermes waits ·
a voice job's card · CarPlay · Watch calls · a call from Hermes · Hermes
Desktop's dialogs (upstream, the reference) · notification · group rooms ·
a card opened before a profile switch that kept the socket (its request
moves to the new profile's client, so `request.cancel` still withdraws it) ·
Text (not needed: no README, docs, Settings or model-facing text describes
these prompts)

**Code**
- Requests: `Conduit/Services/HermesClient.swift` (handleServerRequest, respondToInputPrompt; openServerRequestIDs, approvalQueueIDs and clarifySessions, which adoptSocket moves to the client taking over a socket at a profile switch), `Conduit/Services/StreamEventParser.swift` (request.cancel), `Conduit/Models/Models.swift` (InputPromptActivity: from, loginAnswer, codeAnswer)
- Reopening: `Conduit/Models/Models.swift` (InputPromptActivity.pending(inOpenRequests:)), `Conduit/Services/HermesClient.swift` (resumeSessionObject, which refuses a replayed request no card can show)
- Card: `Conduit/Views/ChatView.swift` (InputPromptCard), `Conduit/Services/AppState.swift` (applyInputPromptActivity, expireInputPrompt, respondToInputPrompt)
- Jump button: `Conduit/Services/ChatResumeCoordinator.swift` (pendingClarifyMessageID, PendingDecisionKind), `Conduit/Views/ChatView.swift` (ChatJumpControls)
- Voice screens: `Conduit/Services/AppState+SpokenApprovals.swift` (openChatWaitingCards, openChatWaitingInputs), `Conduit/Views/VoiceConversationSheet.swift` (VoiceApprovalPanel), `Conduit/Views/LiveVoiceCallJobs.swift` (LiveVoiceWaitingPanel)
- Voice lines: `Conduit/Voice/LocalLive/LocalLiveTurnRunner.swift` (needsInputLine), `Conduit/Voice/VoiceBackgroundJobs.swift` (waitingNotice)
- Tests: `ConduitTests/HermesClientTests.swift`, `ConduitTests/ClarifyBatchStateTests.swift`, `ConduitTests/ChatResumeCoordinatorTests.swift`

**Rulings**
- What the user types lives only in the card's view state and goes once onto the socket: never on the message, in a cache, a log or a notification. The card is live-only; reopening the chat brings it back from `open_requests`. A card shown before a profile switch never sends: it expires (2026-10-26, #259, #1301).
- Never asked or answered by voice: Local Live and a voice job's notice say Hermes waits and where, the other live modes only show the card on the call screen, and Classic voice shows it too, but no listening window opens for it and nothing asks for the value aloud. A live call's open microphone and Classic's barge-in still hear the room, so a user who reads a code out loud is heard like any other speech (2026-10-26, #1301).
- A website login names the exact origin it is saved for, its title the origin's own host, or the origin itself when it has none (never a separately sent site name), and goes as JSON `{identifier, password}`, the identifier trimmed and the password as typed (spaces alone are no password, as on the other cards); a code drops the spaces and dashes a site groups it with. As in Hermes Desktop: the code is shown as typed, Don't save and Skip answer empty, and the code request's `hint` is not shown (Hermes always sends it empty) (2026-10-26, #1299, #1301).
- No password or username autofill type on the login card: iOS would offer to save the site's login under Conduit's own domain. The code field offers a code from a text message or email (2026-10-26, #1301).
- On the chat card, here, on Classic voice's screen and on a live call's screen (VoiceApprovalPanel, which LiveVoiceWaitingPanel shows, draws the same card), the card's caption and its time share the top row, the time on the right on one line (a long caption wraps beside it), and the title runs the card's full width below, never in a column beside the time; at the accessibility text sizes the time goes under the caption (2026-10-29, #1507, issue #1440).

**Open gaps**
- Notification: none for any of these. Hermes gives plugins no hook on server requests, and `browser_vault` can't tell before it runs whether it will ask (a saved authenticator key fills codes itself).
- Group rooms show no card for these.
- Classic voice says nothing when one arrives, so on CarPlay, which shows no card, the conversation sits on thinking until it is answered on the phone. Its spoken notices open a listening window for the answer, which these must not have; a notice without one is still to build.
- A voice job waiting on one shows no card on the call screen or Classic voice's screen: the job keeps only that it needs input, so the call says to open it in Conduit (waitingNotice). The same goes for Watch calls, which have no card at all.
- The minimised call bar shows no card, as for approvals and questions; opening the call shows it. A call from Hermes is never about one: the plugin calls only for approvals and questions.

**Checked:** 2026-10-29, #1507 (the card's time top right, its title full width below, #1440); 2026-10-28, #1452 (open requests move with a socket kept across a profile switch); 2026-10-26, #1301 (website logins and codes, #1299).

## Voice follow-ups

What the user adds or changes by voice while Hermes is already working on
their request.

**Siblings:** Gemini Live · Qwen Live · Grok Live · GPT-Live · Local Live · Classic
(phone, CarPlay) · Watch calls · the composer's Steer, Interrupt and Queue ·
the outcome text each model is told

| Where | Add to the work | Change or stop it |
|---|---|---|
| Gemini, Qwen, Grok, Local Live agent | `interrupt_job` with kind add: `session.steer` | kind change, or none: `session.redirect` |
| GPT-Live | "Add to job N:": steer | "Job N:": redirect |
| Local Live, Hermes turns | none | a correction redirects the running reply |
| Classic | speech while Hermes thinks, or over its acknowledgement, steers it | talking over the reply starts a new turn |
| Watch | the relay's `interrupt_job` carries the kind; GPT-Live reads "Add to job N:" | as on the phone |

**Code**
- Gemini, Grok and Local Live agent: `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift` (interrupt_job)
- GPT-Live: `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift` ("Job N:", "Add to job N:")
- Local Live, Hermes turns: `Conduit/Voice/LocalLive/LocalLiveTurnRunner.swift`
- Classic: `Conduit/Services/AppState.swift` (steerForVoice), `Conduit/Voice/VoiceConversationController.swift` (isSteerAvailable), `Conduit/Voice/VoiceSpeechDetector.swift`
- Jobs: `Conduit/Voice/VoiceBackgroundJobs.swift` (followUp, VoiceFollowUpOutcome)
- Steer and redirect calls: `Conduit/Services/HermesClient.swift`
- Composer: `Conduit/Views/Components/ComposerBar.swift`
- Watch: `Shared/WatchVoice/WatchJobRelay.swift`, `Shared/WatchVoice/WatchBridgeDelegation.swift`, `ConduitWatch/WatchBridgeCallModel.swift`
- Notifier (Watch relay jobs run on the host): `notifier/dashboard/api/watch_jobs.py`

**Rulings**
- The voice model judges what the user meant, Conduit enforces and routes it, and Hermes reads the user's own words (2026-10-08, #451).
- "Add" goes as `session.steer`; "change", hold and cancel go as `session.redirect`. No kind, or a refused steer, falls back to redirect. The same in every live mode (2026-10-21, #1157).
- An unattached call with one running job and no job number follows up into that job; "New job:" starts another (2026-10-09, #472). Once the call has taken its first request's chat, a follow-up goes into that request while it runs, and "New job:" is the chat's next turn (Eric, 2026-10-25, #1252).
- Steering in the chat never waits for an OK (2026-10-08, #451).
- A job's follow-up words go to Hermes as `(voice) <words>`, as the call's chat turns do, on the phone and on the Watch's relay, so a job's chat that only voice used still leaves Desktop's list once answered (Voice in the chats list). Local Live's own Hermes turns and Classic's steer stay plain: those chats aren't jobs, and their archive goes by the call (2026-10-28, #1445, notifier #442).

**Open gaps**
- After a steer the model is still told Hermes "changes course now": steer and redirect both end as `.interrupted`, and the text has four copies, in `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift`, `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift`, `Shared/WatchVoice/WatchJobRelay.swift` and `Shared/WatchVoice/WatchBridgeDelegation.swift` (#1157).

**Checked:** 2026-10-30, #1527 (the composer's Steer, Queue and Interrupt keep the field's focus on a Mac or with a hardware keyboard, see Composer focus after a send); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1445 (a job's follow-up words are marked as voice's); 2026-10-27, #1390 (Classic: speech over Hermes' acknowledgement steers); 2026-10-25, at #1252, for a call that took its first request's chat; Qwen in the siblings and the table, at #1182, carried in #1235; 2026-10-23, seeded from main at 64d53c3.

## Job results during calls

How a background job's result, failure or question reaches the user while a
call is still going, and what of it stays after.

**Siblings:** Classic · Gemini Live · Qwen Live · Grok Live · GPT-Live · Local Live (agent
mode, Hermes turns) · Watch calls · CarPlay · the call screen's job cards ·
the saved transcript's job cards · `docs/VOICE_BACKGROUND_JOBS.md`

| Where | How a result arrives |
|---|---|
| Classic | Hermes summarizes it in the call's own session; failures and questions are short spoken notices |
| Gemini | on the job's own tool call once the model is quiet; sent again as text after 6 s of silence |
| Grok | a text turn, sent only while quiet; sent once more if the model says nothing for 6 s |
| GPT-Live | on the delegation, after the user has finished talking; sent once more if the model says nothing for 6 s |
| Local Live agent | an update, as in Grok, checked the same way |
| Local Live, Hermes turns | dropped: Hermes' reply is already the call's turn |
| Watch | the relay's job news, at the next quiet moment; sent once more if the model says nothing for 6 s |

**Code**
- All modes: `Conduit/Voice/VoiceBackgroundJobs.swift` (takeNotice, outcomePrompt, showOnScreen, VoiceJobCallAnchor)
- Gemini and Grok: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift`, `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift`
- GPT-Live: `Conduit/Voice/GPTLive/GPTLiveConversationController.swift` (userQuietInterval, confirmResultSaid), `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift`
- Local Live: `Conduit/Voice/LocalLive/LocalLiveNoticeRoute.swift`
- Classic: `Conduit/Voice/VoiceConversationController.swift`
- Call screen: `Conduit/Views/LiveVoiceCallJobs.swift` (LiveVoiceJobCard, LiveVoiceCallTimeline), `Conduit/Services/AppState+PresentedScreens.swift` (cards Hermes shows)
- Saved transcript: `Conduit/Services/AppState.swift` (voiceJobStartedNote), `Conduit/Voice/VoiceJobLinkNote.swift`, `Conduit/Views/VoiceJobLinkCard.swift`
- Job lists (list_jobs, Classic's status, GPT-Live's status note): `Conduit/Voice/VoiceBackgroundJobs.swift` (listedJobs), `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift` (listResult); the Watch's: `Shared/WatchVoice/WatchJobRelay.swift` (listing), `ConduitWatch/WatchDirectCallModel.swift` (apply, for the iPhone's answer), `Conduit/Watch/WatchDirectBroker.swift` (listedJobs; result, for the jobs the iPhone runs), `Shared/WatchVoice/WatchVoiceWire.swift` (DirectToolResult.newsJobs), `notifier/dashboard/api/watch_jobs.py` (_WatchJobs.list)
- Watch: `Shared/WatchVoice/WatchJobRelay.swift` (notice), `ConduitWatch/WatchDirectCallModel.swift` (checkNewsSpoken, answer, lostAnswerText), `ConduitWatch/WatchBridgeCallModel.swift` (checkNewsSpoken), `Conduit/Watch/WatchDirectBroker.swift` (lateAnswers, jobRefusal)
- Notifier (Watch relay jobs): `notifier/dashboard/api/watch_jobs.py`
- Background time: `Conduit/Services/BackgroundTaskHold.swift` (the Watch broker's tool and poll answers)

**Rulings**
- A result never talks over the user: it waits for a quiet moment, and the model answers what the user just said first (2026-10-04, #381).
- Results show during the call as job cards on the call screen, on the phone only, with no writes to the host mid-call (2026-10-03, #364).
- The saved transcript links each job the call started, drawn as a card (2026-10-03, #358; 2026-10-18, #758).
- Local Live agent calls announce results; calls that hand each turn to Hermes drop them (2026-10-23, #1160).
- A result that can't go out now is kept, never dropped: GPT-Live's quiet replies wait with the spoken ones, and replies still on their way when a conversation ends or is replaced go back to pending, as Gemini's unsent answers become text updates (2026-10-24, #1223).
- On the Watch, a job answered as accepted that Hermes then refuses is taken back as news, and an answer that can't go on its call while the session reconnects is said as a text update, as the phone's fallback is (2026-10-24, #1221).
- The request whose chat an unattached call took is the call's, not a job of it: its line in the saved transcript is "Asked the chat", a settled job no longer owns its chat's events (the call's later turns and typed turns there are theirs), and at hang-up it is let go of like the call's chat turns, never announced or listed to a later call. Its result is told as a chat reply; a failure keeps the job's failure notice, since its reason is a raw start or Hermes error, not a line to speak. While it runs it counts as one of the chat's three requests in flight and, being real work on Hermes, one of the call's three running jobs, and it stays on the call's job list and its job card, so the model can still correct or cancel it, "cancel all" included (2026-10-25, #1252).

**Open gaps**
- GPT-Live's model can't put a card on the call screen: Gemini, Grok and Local Live agent have `show_on_screen`, GPT-Live has no marker for it. Cards Hermes shows still appear (#366).

**Checked:** 2026-10-29, #1491 (a job result's or card's picture opens in the picture viewer); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1449 (live models are told of a file by name, never its path); 2026-10-28, #1424 (tool steps in the call trace stay with their call); 2026-10-28, #1407 (a line ending in a file-path link isn't read as a saved call's job note); 2026-10-26, #1247 (the Watch broker's tool and poll answers keep Conduit running through BackgroundTaskHold); 2026-10-25, at #1252, for the request whose chat an unattached call took; Qwen in the siblings, at #1182, carried in #1235; at #1224: a result counts as told once the model says something after it or once it has gone out twice (one resend, GPT-Live and Watch included), and a job stays on the job lists until then (#1210), a direct Watch call's iPhone-run jobs included; one already sent when the call ends counts as told, never carried into the next call. Earlier at #1223, for GPT-Live's replies that couldn't go out; at #1221, for the Watch's late refusals and answers lost to a reconnect; at 78f21da; at #1191; at #1220: a cut screen card reads fences as "Code fences in messages" says.

## Tools and consent in calls

What a call can do for the user (phone features, health and location reads,
finding chats, web lookups) and the consent each needs.

**Siblings:** Gemini Live · Qwen Live · Grok Live · GPT-Live · Local Live agent · Classic
(Hermes' own tools) · Watch calls · CarPlay · the phone features set · the
consent screens · the tool text each model reads, in Conduit and the notifier

**Code**
- Phone tools: `Conduit/Phone/PhoneVoiceTools.swift`, `Conduit/Phone/PhoneChangeConfirmation.swift`
- Host reads for live modes: `Conduit/Voice/VoiceHostTools.swift` (VoiceHostTool, gptLiveRules), `Conduit/Services/AppState+VoiceHostTools.swift`
- Declarations: `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift` (declarations, watchDeclarations); GPT-Live markers: `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift`
- Chats by voice: `Conduit/Voice/VoiceChatFinder.swift`, `Shared/WatchVoice/VoiceChatToolText.swift`
- Provider consent: `Conduit/Voice/LiveVoiceProviderConsent.swift`, `Conduit/Services/AppState+LiveVoiceConsent.swift`, `Conduit/Views/LiveVoiceConsentViews.swift`
- Consent for reads, per mode: `Conduit/Views/HealthSettingsViews.swift`, `Conduit/Views/LocationSettingsViews.swift`, `Conduit/Views/PhoneSettingsViews.swift`
- Watch: `Conduit/Watch/WatchDirectBroker.swift` (directToken: consent checked again once the token is minted), `Conduit/Watch/WatchToolGrantClient.swift`, `Shared/WatchVoice/WatchToolRelay.swift`
- Notifier: `notifier/phone_tool.py`, `notifier/health_tool.py`, `notifier/location_tool.py`, `notifier/maps_tool.py`, `notifier/conduit_first.py`, `notifier/dashboard/api/phone_data.py` (/voice-tools), `notifier/relay/src/watch-tools.mjs`
- Background time: `Conduit/Services/BackgroundTaskHold.swift` (the Watch broker's directToken and tool answers)

**Rulings**
- Live calls do phone actions on the device rather than handing them to Hermes (2026-10-20, #991).
- Live modes read health, location and calendar through the host's /voice-tools, with consent for each voice mode that names its provider, off by default (2026-10-14, #585, notifier #104).
- A live provider hears nothing until the user agrees, once per provider on the device; Local Live never asks (2026-10-20, #1052). Qwen asks for Alibaba Cloud on its own, and a Watch token minted while the user took consent back is dropped, not sent (2026-10-25, #1182).
- Conduit's tools come first: models use them before handing work to Hermes or older routes such as gog (2026-10-16, #634, notifier #121).
- With asking first on, a held request goes to Hermes only on the user's own yes, read the same way in every live mode: Gemini, Grok and Local Live's send_request and GPT-Live's next delegation. A no drops it, other words change it or keep it waiting (2026-10-24, #1223).

**Open gaps**
- The consent ask doesn't cover Classic with cloud speech through the host, or Local Live (#1052).
- A Watch Gemini call can't be ended from the phone when consent is taken back (#1052).
- Watch GPT-Live and Local Live calls have no phone tools, and the Watch doesn't announce Hermes' phone changes (#994).
- Classic finds and reads old chats through Hermes' session_search but can't open one in Conduit (#535).

**Checked:** 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1449 (live models are told of a file by name, never its path); 2026-10-26, #1305 (VoiceChatFinder's search leaves Kanban workers out; see Kanban workers' transcripts); 2026-10-26, #1247 (the Watch broker's token and tool answers keep Conduit running through BackgroundTaskHold); 2026-10-25, Qwen in the siblings, and a Watch token minted after consent was withdrawn, at #1182, carried in #1235; 2026-10-24, at #1223, for send_request's yes; 2026-10-23, seeded from main at 64d53c3; at #1191, Location's rule delete says when no dashboard is open (#972 review), which changes nothing about consent.

## Acknowledging work handed to Hermes

What a live model says when it hands a request to Hermes, so the user knows
it heard without hearing the same line every time; also Classic's delivery
of Hermes' own acknowledgements while its turn runs.

**Siblings:** Gemini Live · Qwen Live · Grok Live · GPT-Live · Local Live agent ·
Watch calls · CarPlay · calls from Hermes · the web lookup heads-up · the
instructions preview in Voice settings · Classic (Hermes speaks for itself:
its `message.interim` notes are said as they arrive) · Local Live, Hermes turns (not needed: Hermes' reply is the
turn) · the notifier (no acknowledgement text there; it already sends `message.interim`) · Settings captions and
README (none: nothing describes the wording) · docs/VOICE_SETTINGS.md (Classic's acknowledgement and cutting it short)

**Code**
- The shared rule: `Shared/GeminiLive/LiveVoiceAcknowledgement.swift`; Grok and Local Live's job-claim rule (no acknowledgement text): `Shared/GrokLive/GrokLiveProtocol.swift` (jobClaimInstructions)
- Gemini, Qwen and the Watch: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift` (instructions, acknowledgementPrompt for a quiet start_job); Grok and Local Live build the same instructions with acknowledgesOnceStarted
- The Voice settings preview shows the instructions as sent: `Conduit/Services/AppState.swift` (liveVoiceInstructionsPreview)
- Where each call builds them, phone, CarPlay and Watch: `Conduit/Services/AppState.swift` (localLiveAgentSetup, prepareWatchDirectCall, prepareWatchGrokCall)
- GPT-Live, phone and Watch: `Conduit/Voice/GPTLive/GPTLiveConversationController.swift` (briefingRules; claimsToSendToHermes, which takes an acknowledgement-only turn with no delegation as a send)
- Local Live agent: `Shared/LocalLive/LocalLiveProtocol.swift` (agentInstructions)
- Conduit's own tools need none: `Conduit/Voice/VoiceHostTools.swift`
- Web lookups: `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift` (lookupAnswerNote)
- Classic, phone and CarPlay: `Conduit/Services/AppState.swift` (notifyVoiceAssistant), `Conduit/Voice/VoiceTypes.swift` (VoiceAssistantEvent), `Conduit/Voice/VoiceConversationController.swift` (receiveAssistantEvent, drainSpeechQueue, isAcknowledgementSteerable); tests in `ConduitTests/AppStateReasoningStreamTests.swift` and `ConduitTests/VoiceConversationControllerTests.swift`

**Rulings**
- Each handoff gets a word or a few, in the model's own words and different each time; Hermes is named at most once on a call, or when the user asks who's doing it; telling the user what it's about to do counts as the acknowledgement (2026-10-25, #1251).
- Gemini and Qwen (phone and Watch) say it before start_job; Grok and Local Live (phone and Watch) only once start_job returns started; GPT-Live before the delegation (2026-10-25, #1251).
- GPT-Live's send-claim fallback counts a turn that is only an acknowledgement ("On it.", "One moment, checking.") as well as one naming Hermes, so fewer mentions don't let an undelegated request drop; "Sure." or "Okay." alone never counts. A bare "On it." with no delegation is taken as a send on purpose: the model only says it for work (2026-10-25, #1251).
- A web lookup's heads-up is said once, varied, and the answer opens without it (2026-10-05, #404).
- Conduit's own tools answer fast and need no acknowledgement (on main by 2026-10-22, b41f56c).
- Classic says Hermes' own acknowledgement (`message.interim`) as it arrives, then goes back to thinking: it is not the end of the turn and opens no listening window. Commentary already streamed is said once, and a final reply that only repeats the acknowledgement isn't said again. Cutting the acknowledgement short (talking over it, Interrupt, CarPlay's Stop, a push to talk press) steers the turn instead of cancelling it (Eric 2026-10-27, from #1384, carried in #1390).

**Open gaps**
- GPT-Live's send-claim fallback reads English phrases only: an acknowledgement in other words or another language, with no delegation, can still go unsent until the user asks again; and a short reply made only of acknowledgement words ("Let me look.") counts as a send even when the model meant to answer itself (#1251).

**Checked:** 2026-10-27, #1390 (Classic says Hermes' acknowledgements, carried from #1384); 2026-10-25, at #1251.

## Starting a call

Every way a call starts, and which chat it joins.

**Siblings:** the chat's voice button (chats, project chats, Bot Chat) · the
top bar's call button · Home's main button (its own entry, Voice beside the tabs) · the sidebar's New voice call ·
Siri, Shortcuts and the Action button · the wake phrase · widgets · CarPlay ·
the Apple Watch · Resume Call · group rooms · a call from Hermes (its own
entry) · the hands-free profile (Settings > Voice > Watch and Siri calls, its
caption, README.md's Apple Watch line)

**Code**
- Start paths: `Conduit/Voice/VoiceTypes.swift` (PendingVoiceIntent.Source), `Conduit/Services/AppState.swift` (prepareVoiceConversation, voiceWaitsForRunningTurn)
- Which chat: `Conduit/Services/AppState.swift` (liveVoiceThreadForOpenChat, savedCallToResume, keepVoiceCallWithAdoptedChat); an unattached call's first request's chat: `Conduit/Voice/VoiceBackgroundJobs.swift` (adoptCallChat, callChatJobRuns, callChatClaim, waitForCallChatClaim), `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift` (startBackgroundJob), `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift` (send), `Shared/WatchVoice/VoiceJobRouting.swift` (wantsJobOfItsOwn); on the Watch: `Shared/WatchVoice/WatchJobRelay.swift` (joinsCall), `ConduitWatch/WatchBridgeCallModel.swift` (startArguments), `ConduitWatch/WatchDirectCallModel.swift` (joins_call), `Conduit/Watch/WatchDirectBroker.swift` (WatchCallJobSupervisor.callChat, startingCallChat, callIsLive), `Conduit/Voice/VoiceBackgroundJobs.swift` (markOpensCallChat), `Conduit/Voice/VoiceBackgroundJobs.swift` (continueJob), `notifier/dashboard/api/watch_jobs.py` (_WatchJobs._continue_session)
- Chat voice button: `Conduit/Views/V2/V2VoiceButton.swift`, `Conduit/Views/V2/ChatVoiceButtonAction.swift`, `Conduit/Views/V2/V2ConversationScreen.swift` (voiceButtonBottomPadding, V2RestingComposerHeightKey: level with the resting composer, or with the bottom of one that stays expanded, see Composer at rest and expanded), `Conduit/Views/Components/ComposerBar.swift` (the resting bar's height, keepsVoiceButtonBeside), `Conduit/Services/AppState+VoiceMessage.swift`, `Conduit/Voice/VoiceMessageRecorder.swift`
- Siri and Shortcuts: `Conduit/Intents/StartVoiceConversationIntent.swift`; wake phrase: `Conduit/Voice/Wake/WakeLifecycleCoordinator.swift`
- CarPlay: `Conduit/CarPlay/CarPlayVoiceCoordinator.swift` (CarPlayVoiceMode current and listed, conversationStartingOnPhone, prepareWaitingForConnection, establishLiveVoice, performOpenChat, openChatOnPhone, selectVoiceMode), `Conduit/CarPlay/CarPlayBrowseTemplates.swift` (CarPlayVoiceMode.all, choice), `Conduit/Services/AppState.swift` (start…ForCarPlay, releaseCarPlay… per live mode)
- A start's late answers: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift` (callEpoch, isStarting; Gemini, Qwen, Grok, Local Live), `Conduit/Voice/GPTLive/GPTLiveConversationController.swift` (startAttempt), `Conduit/Voice/VoiceConversationController.swift` (operationGeneration), `ConduitWatch/WatchDirectCallModel.swift` (callID)
- Watch: `ConduitWatch/WatchHomeView.swift`, `ConduitWatch/TalkToHermesIntent.swift`
- Which profile: `Conduit/Services/AppState+HandsFreeProfile.swift` (handsFreeProfile, setHandsFreeProfileChoice, watchCallProfile, applyingHandsFreeProfile, jobProfile), `Conduit/Views/HandsFreeProfileSettingsSection.swift` (in `Conduit/Views/VoiceSettingsView.swift`), Siri's: `Conduit/Services/AppState.swift` (openVoiceConversation, presentWaitingCallIfNeeded); a Watch call on its own profile: `Conduit/Services/AppState.swift` (watchDirectConnection, watchConnectionIsCurrent, watchDirectToken, watchCallJobSession, the job backend's createSession, searchChatsForVoice and readChatForVoice, each told the call's profile by WatchCallJobSupervisor, make…Client), `Conduit/Voice/VoiceBackgroundJobs.swift` (startJob's callsModel, findChats and readFoundChat's profile), `Conduit/Watch/WatchDirectBroker.swift` (WatchDirectConnection.phoneProfile, WatchCallJobSupervisor.callProfile, makeBridge), `Conduit/Services/AppState+VoiceHostTools.swift` (each read's `profile`), `Conduit/Services/AppState+HermesCalls.swift` (the Watch's voices, checked on the hands-free profile), `Conduit/Watch/WatchSettingsSection.swift` (GPT-Live's setup); tests: `ConduitTests/HandsFreeProfileTests.swift`
- A chat open elsewhere: its own entry (Chat open elsewhere)
- How an attached call behaves: `docs/VOICE_BACKGROUND_JOBS.md`
- Background time: `Conduit/Services/BackgroundTaskHold.swift` (the Watch broker's start answers, direct, bridge, Grok and Local Live)

**Rulings**
- A live call started from a chat joins that chat for the whole call, and its requests become the chat's turns (2026-10-02, #312). An empty chat counts as a chat (2026-10-16, #679).
- Started anywhere else, a live call stands alone until its first ordinary request: once Hermes takes that job, its chat becomes the call's, as if the call had started there. Background, quick and other-profile work still runs apart, and a first request of that kind leaves the call unattached. A request said while that chat is still being made joins it, on the iPhone and in a Watch call the iPhone runs jobs for; one that finishes starting after the hang-up attaches nothing and is let go of like the call's other requests, and the next call makes its own (Eric, 2026-10-25, #1252, for #1250; replaces #312's "stands alone"; the races from #1253's tests).
- A Watch call does the same with its jobs: each later ordinary one is still a job of the call, with its own news, but runs as the next turn of the chat the first made, on the relay (notifier 0.78, `joins_call`) and on the iPhone alike. The call is saved as its own, as Watch calls are. A request still waiting its turn when the call ends goes no further, as a phone call's (2026-10-25, #1252, notifier #369).
- In a chat with a saved call, the voice button resumes that call (2026-10-16, #679).
- A call always takes over a chat that Desktop holds, whatever the setting, and "Take over automatically" is on by default (2026-10-21, #1066).
- Classic can't start while a reply runs; live calls start beside it (2026-10-18, #767).
- The chat's voice button does what the user picks: Live call, Voice message or Dictation, for all profiles or per profile (2026-10-22, #1134).
- A start that was stopped, or that a newer start replaced, changes nothing when its checks answer late, in every voice mode; a CarPlay start waiting for Hermes stops quietly when the voice mode changes, and the next tap starts the new mode (2026-10-24, #1223).
- A chat picked from CarPlay's list shows Thinking while it opens. A live call (every live mode) waits at most 3 seconds for the phone to show that chat, then starts attached to it while the phone goes on opening it; Classic talks in the open chat, so it waits for the open. A start that never began (Hermes dropped just before it) leaves the car on Ready, or Error when Hermes is gone, never on Thinking (2026-10-27, #1370, from #1362).
- A call started away from the iPhone's screen runs on the hands-free profile picked in Settings > Voice > Watch and Siri calls, saved per dashboard on the device: the Apple Watch's calls (its app, complication and Action button), and Siri's or the Action button's when the shortcut names no profile. Off, the default, follows the profile open on the iPhone, as before; a profile the dashboard no longer lists follows it too. A Watch call runs there without switching the iPhone: its setup, token, lookups, phone tools, jobs (the iPhone's and the relay's) and saved call are that profile's, its later ordinary jobs still share the first one's chat, and a switch on the iPhone still ends it. A Siri start switches the iPhone to it, as a shortcut that names a profile does. A shortcut that names a profile, and "for <name>, …" work, still go where named; a call from Hermes answered on the Watch keeps its own profile. CarPlay keeps its agent list and the profile open on the iPhone, and the wake phrase listens on that one too (Eric 2026-10-31, #1573, issue 1564: Watch and Siri, not CarPlay).
- CarPlay starts every live mode the profile can be set to, Local Live in agent mode (Live > Local) included, and its voice list saves the mode as Settings > Voice > Voice mode does. Classic's hands-free option on the speech server runs there as on the phone, on Local Live's controller with each turn going to Hermes, and is listed as Classic; a call from Hermes on it opens classic voice, which the car follows (Eric 2026-10-27, #1378, from #1376).

**Open gaps**
- Group rooms have no voice button setting, and the Watch and CarPlay don't follow it (#1134).
- When a Classic call can't take over its chat, it shows a generic error (#1066).
- A Watch call on another profile asks Hermes' chat search for that profile's chats; on a plugin without that route (before 0.18) it falls back to the titles Conduit has listed, which hold that profile's chats only while All profiles is on (#1573).
- A Siri or Action button start that switches the iPhone's profile (one the shortcut names, or the hands-free profile) shows no waiting call screen while the switch runs; the call opens once it's done (#1573).

**Checked:** 2026-10-31, #1573 (Watch and Siri calls start on the hands-free profile, a Watch call without switching the iPhone, issue 1564); 2026-10-30, #1541 (at accessibility Text Sizes the resting bar's placeholder keeps to one line, so the voice button centres on a one-line bar; see Composer at rest and expanded); 2026-10-29, #1512 (the voice button stays beside a composer that stays expanded on a Mac or a wide iPad, issue 1483); 2026-10-29, #1476 (the chat's voice button centres on a resting composer taller than it, as when a long placeholder wraps); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1413 (the Siri and Shortcuts profile picker shows each profile's Conduit name, see Profile names); 2026-10-28, #1424 (a call starts its trace; Qwen Live calls are traced too); 2026-10-27, #1378 (CarPlay starts Local Live, agent mode and Classic's hands-free option, #1376); 2026-10-27, at #1370 (a chat picked in CarPlay shows Thinking, and a live call waits at most 3 s for the phone to open it); 2026-10-26, at #1319 (Home's main button points to its own entry); 2026-10-26, #1247 (the Watch broker's start answers keep Conduit running through BackgroundTaskHold); 2026-10-25, at #1252: an unattached phone or CarPlay call takes its first ordinary request's chat, and a Watch call runs its later ordinary jobs there (notifier #369); 2026-10-25, #1261, the chat-open-elsewhere code moved to its own entry; Qwen starts through the shared controller, at #1182, carried in #1235; 2026-10-24, at #1223, for a start's late answers and CarPlay's mode switch; 2026-10-23, seeded from main at 64d53c3.

## Switching voice mode in a call

The voice mode menu on a call screen: it ends the call and starts again in the
mode picked, in the same chat, and Voice settings keep the new mode.

**Siblings:** the mode capsule under a live call's title (Gemini, Qwen, Grok,
GPT-Live, Local Live) · Classic's mode capsule · a failed live call's Switch
voice button · Voice settings' mode picker · CarPlay and the Apple Watch (no
mode menu)

**Code**
- Menu and capsule: `Conduit/Views/VoiceModeMenu.swift` (VoiceModeMenu, VoiceModeCapsule), `Conduit/Voice/VoiceModeChoice.swift` (VoiceModeSwitch)
- The switch: `Conduit/Services/AppState.swift` (voiceModeSwitch, switchVoiceMode)
- Live call screen: `Conduit/Views/LiveVoiceCallSheet.swift` (VoiceModeCapsule under the title; LiveVoiceCallModeMenuButton on a failed call), shown from `Conduit/Views/GeminiLiveViews.swift` and `Conduit/Views/GPTLiveViews.swift`
- Classic: `Conduit/Views/VoiceConversationSheet.swift` (VoiceModeCapsule), shown from `Conduit/Views/RootView.swift`
- Tests: `ConduitTests/AppStateVoiceCapabilityTests+VoiceModeSwitch.swift`

**Rulings**
- Picking the call's own mode leaves the call as it is, except a hands-free Local Live call listed as Classic, which moves (VoiceModeSwitch.movesOnCurrent).
- A failed live call offers Switch voice beside Try again, so a mode that keeps refusing (a plan's limit, a provider's outage) needn't end the conversation (#964).
- Switch voice is a round button like the call's others: only the glyph is the menu's label, and the caption sits under it, hidden from VoiceOver since the menu carries the name. On iOS 26 a menu draws its glass over its whole label, so a caption inside it made a large slab that clipped the caption (2026-10-27, #1355).

**Open gaps**
- CarPlay and the Watch have no mode menu: a call there changes mode only through Voice settings.
- Switch voice's caption no longer opens the menu; only the round glyph does (#1355).

**Checked:** 2026-10-27, added at #1355 (Switch voice on a failed call is a round button).

## Voice beside the tabs

The gold button beside the tab bar, and where voice goes when it is swapped
for New chat, on a phone and on a split iPad or Mac window.

**Siblings:** the round button (Voice, or New chat by Settings > Appearance >
Main button) · voice in the Chats top bar and a project page's toolbar when
swapped · the chat's own voice button (Starting a call) · a minimised call's
way back · the iPad split layout, with the list shown or hidden (#1164) ·
Tasks and Settings on a wide window · Bots and Bot Chat · group rooms · the
Main button caption · a list the user widened (Resizable columns on a split
window)

**Code**
- Round button and bar: `Conduit/Views/V2/V2Shell.swift` (voiceButton, tabs, splitColumns' hostsSettings, V2SplitLayout.hasChatVoiceBeside, V2SplitLayout.tabBarUnderList, V2SplitLayout.settingsBesideList, V2MainButtonPreference)
- Swapped voice: `Conduit/Views/V2/V2ChatsView.swift` (trailingControls), `Conduit/Views/V2/V2ProjectPage.swift` (toolbar)
- Caption: `Conduit/Views/AuxiliaryViews.swift` (Main button)
- Tests: `ConduitTests/V2SplitLayoutTests.swift`

**Rulings**
- Swapped, the round button starts a new chat and voice moves to the top bar; a minimised call turns it back into voice (2026-10-17, #707).
- Split, a chat beside the list that shows its own voice button takes voice: the round voice button, and the swapped top bar and project page voice, step aside while it shows; New chat stays. A group room has none, so the list keeps its voice beside one (Eric, 2026-10-26, #1319).
- The round button's touch-and-hold Recent menu goes with it while a chat is beside the list; the chat's own button offers a call or dictation, not Recent, so closing the chat brings the menu back (2026-10-26, #1319).
- Split, Settings opens in the chat's column with the Chats list kept beside it, and the bar stays under the list; a chat tapped there opens in Chats. Tasks and a list shown alone have no list column and center the bar under the screen, at the list column's width (Eric, 2026-10-26, #1319; replaces #1169's bar kept at the leading edge).
- Under a list the user widened, the bar keeps the standard list width, centered under the list's column (2026-10-29, #1492, see Resizable columns on a split window).

**Open gaps**
- Recent isn't reachable beside a chat on a split window (see Rulings).

**Checked:** 2026-10-29, #1492 (the bar under a widened list); 2026-10-26, at #1319.

## The open chat in the list beside it

How the list marks the conversation open beside it on a split iPad or Mac
window, so nobody has to match the chat's title to a row (#1363).

**Siblings:** Chats rows (top-level, a nest's job rows, message-search
matches, All's rows from another profile) · a project page's rows · the
Bots list's bot rows (their Bot Chat) and group room rows · Desktop group
chats (a sheet, never beside the list, so nothing to mark) · Settings in the
chat's column and the empty placeholder (nothing marked) · the list hidden,
and a phone (one column) · the drawer shell's persistent sidebar (V2 off) ·
the unread dot and the Running and Approve signals on the same rows · text:
no Settings caption or doc describes it

**Code**
- What shows beside the list: `Conduit/Views/V2/V2Shell.swift` (V2OpenBeside, the v2OpenBeside environment set in tabs(), V2SplitLayout.openBeside, V2RowSelection, V2OpenRowHighlight, v2RowSelection, v2SelectedTrait)
- Rows: `Conduit/Views/V2/V2SessionRow.swift` (V2SessionRow, V2ContentMatchRow), `Conduit/Views/V2/V2ChatsView.swift` (V2ChatsRow's selection, contentSearchRow), `Conduit/Views/V2/V2ProjectPage.swift`, `Conduit/Views/BotRosterView.swift` (BotRosterRow, GroupRosterRow, rosterListRow)
- Drawer shell: `Conduit/Views/SidebarView.swift` (SessionRow's isSelected)
- Which row is open: `Conduit/Services/AppState.swift` (isOpenChatRow)
- Tests: `ConduitTests/V2SplitLayoutTests.swift` (testV2SplitListMarksWhatShowsBesideIt), `ConduitTests/SessionRenameTests.swift` (testANewChatStaysListedWhileOpenUntilHermesListsIt)

**Rulings**
- Split, the row of what shows beside the list gets a rounded accent tint with a fine accent edge, as the persistent sidebar marks its open chat, and VoiceOver says Selected. A shape behind the row, so it reads apart from the gold unread dot and the Running spinner on it (2026-10-27, #1371).
- Only on a split window: a phone and a wide window with the list hidden keep their one-column look, the Chats and project rows' faint shade included (Eric, 2026-10-27, #1371: for larger screens with the sidebar).
- A group room takes the chat's place without changing the open chat, so beside a room only the room's row is marked; with Settings or the placeholder in the chat's column nothing is (2026-10-27, #1371).
- Another profile's row in All is never the open chat, whatever its id (2026-10-27, #1371).
- A row is the open chat by any id it goes by (its stored id, its aliases), or by the stored id Hermes confirmed for the runtime id the chat is open under: a chat New Chat made is open by its runtime id and listed by its stored one (2026-10-28, issue 1454, #1456).

**Open gaps**
- None known.

**Checked:** 2026-10-29, #1492 (tabs() gained the bar's width under a widened list; what shows beside the list is unchanged); 2026-10-28, #1456 (rows match the open chat by its aliases); 2026-10-27, added at #1371.

## A new chat in the list

A chat started here shows in the list at once, though Hermes lists a chat
only once its first message is stored (issue 1454: on a Mac the new chat
stayed out of the list beside it until the user went away and back).

**Siblings:** the Chats list beside the open chat (iPad, Mac) and on a phone
after Back · All profiles (the profile in use's rows are its own list) · a
project's page beside the chat, and Home's page for a plain chat · the
Projects view's and the main list's project sorting (Project chats in Chats)
· the drawer shell's persistent sidebar (V2 off; reads the same list) ·
every way a chat is made: New Chat, a project's new conversation, the empty
canvas's send, a widget's or Shortcut's New Chat, /new, a Classic call's
fresh chat · not needed: a Shortcut's send to a new chat, a voice
job's chat and a Local Live call's own chat from Home or Siri (made in the background and sent to at once, never opened, so the
registry poll lists them as it does a chat from another device), a branch (stored with its parent's messages, so
Hermes lists it, and its own create waits for that read), CarPlay's chat
list and the widget's pickers (they pick a chat to talk to, and the open one
is already open), the Watch (no list) · text: no Settings caption or doc
describes it

**Code**
- Keeping the row: `Conduit/Services/AppState.swift` (newChatAwaitingListing, set in createAndReconcileSession for createNewSession; newChatRowAwaitingListing and settleNewChatAwaitingListing, in loadSessions and syncSession's catalog; chatListListedIDs; knownProjectID; loadProjectSessions, quiet when a newer read cancels it), `Conduit/Services/ChatSync.swift` (NewChatAwaitingListing)
- Project page: `Conduit/Views/V2/V2ProjectPage.swift` (lanes, the task keyed on chatListCatalogGeneration)
- Tests: `ConduitTests/SessionRenameTests.swift` (testANewChatStaysListedWhileOpenUntilHermesListsIt, testANewChatLeftEmptyLeavesTheList, testANewChatBelongsToTheProjectItStartedIn, testANewChatGoesOnTopOfItsFoldersLaneOnAProjectPage)

**Rulings**
- The row the create puts in stays through every catalog read while it is the open chat, until Hermes lists it; then Hermes' row, with its title, takes over. Opening another chat ends the wait (the registry poll and project sorting stop counting it at once, the list drops it at the next read), so an empty chat left behind leaves the list, as Hermes keeps no row for it (2026-10-28, issue 1454, #1456).
- Only a chat someone started (createNewSession): one a sync starts because there was nothing to resume waits for Hermes, as before.
- It still counts as unlisted for the registry poll, so the poll reads the catalog in for it as for a chat started on another device. A first turn that compressed lists it under a new tip, matched by its lineage root.
- It is marked as the open chat beside the list, though it is open by its runtime id: the row by any of its ids, Hermes' row by the stored id the create confirmed (The open chat in the list beside it).
- A project's page shows it on top of the lane of the folder it started in (Hermes names that folder in the lane's path, or in its label when the two are one), else in a new Recent lane on top; Home's page shows a plain chat in a Recent lane. The page reads Hermes' list again whenever the chats list changes, from a list read or a chat sync. It follows while it stays beside the chat (2026-10-28, #1456).

**Open gaps**
- None known.

**Checked:** 2026-10-28, added at #1456.

## Chat open elsewhere

What Conduit does when Hermes refuses a send because something else holds the
chat (SESSION_NOT_OWNED): Hermes Desktop or a terminal with a claim, or the
gateway's ledger running other work in it, like another bot's message in a
Bot Chat.

**Siblings:** the composer's offer and automatic takeover · a call's request
in the open chat (Classic, Local Live, the live modes) · a call's request off
screen (CarPlay and Watch calls too) · chats, project chats and Bot Chat ·
Pulse's own takeover · the plugin's takeover route · the idle claim release
(a profile switch keeps Conduit's socket, see Chats top bar and search, so the
outgoing profile's idle chats are let go by this release after 60 s, as a chat
left for another in the same profile is, where the socket's close used to let
them go at the switch; a running turn keeps its claim either way, #1452) ·
Settings > Chat > Take over automatically and its caption · the plugin's
update notice

**Code**
- Offer, owner and sentences: `Conduit/Services/ChatTakeover.swift` (ChatTakeoverState.owner, ChatTakeoverClient, ChatTakeoverOutcome)
- Flow: `Conduit/Services/AppState.swift` (noteChatOwnedElsewhere, takeOverChat, chatTakeoverProfile, runChatTakeover, noteChatTakeoverOwner, submitComposerForCall, takeOverChatForCall, sendCallPromptTakingOver), shown by `Conduit/Views/Components/ComposerBar.swift`
- Setting: `Conduit/Views/AuxiliaryViews.swift` (Take over automatically)
- Plugin: `notifier/chat_takeover.py` (take_over_session, gateway_queue_owner), `notifier/dashboard/api/chats.py` (/sessions/takeover), `notifier/pulse_host.py` (take_over), `notifier/conduit_claims.py` (idle claim release)

**Rulings**
- Only another process's claim is dropped, never while it runs a turn; this dashboard's own claims answer same_host (2026-10-02, #304; notifier #33, #101).
- A call always takes over, whatever the setting, and Take over automatically is on by default (2026-10-21, #1066).
- A Bot Chat's takeover asks the bot's profile, where its claims and ledger live (2026-10-25, #1261).
- While the gateway's ledger holds the chat, nothing is dropped: the route answers busy, surface `bot` for another bot's message, and Conduit says the bot is answering another bot and sends once it finishes. Other queued work answers surface `gateway`, which reads as another Hermes window (it's a platform message or a job Hermes runs there), and is waited for the same way (2026-10-25, #1261; notifier #374).

**Open gaps**
- The offer can't name a bot until the route answers: Hermes' ledger refusal names no owner, so with Take over automatically off the offer reads "another Hermes window" until the tap (#1261).
- A ledger row Hermes marks `unknown` only clears when it's discarded in Hermes; Conduit waits on it like a busy chat, then says to try again (#1261).
- Classic shows a generic error when it can't take over (#1066).
- Desktop isn't told it lost the chat and shows stale history until reopened (needs Hermes, #304).

**Checked:** 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1452 (a profile switch keeps the socket, so claims go by the idle release); 2026-10-25, #1261.

## Ending a call and what gets saved

What happens to a call's words, its jobs and Hermes' memory when it ends.

**Siblings:** a call joined to a chat · a call on its own · a Bot Chat call ·
Classic in a chat it created · Watch calls · CarPlay calls · calls from
Hermes · Resume Call · memory at call end (notifier)

**Code**
- Recording and saving: `Conduit/Voice/VoiceHistory.swift` (VoiceTranscriptRecorder, VoiceTranscriptSaveRequest, VoiceCallChatLink, VoiceTranscriptOutbox, VoiceCallCheckpoint)
- In the app: `Conduit/Services/AppState.swift` (chatCallReconnectWindow, isArchivedVoiceChat, saveWatchVoiceCall, checkpointVoiceCall)
- The call's card in its chat: `Conduit/Views/ChatView.swift` (VoiceCallMarkerCard), `Conduit/Views/VoiceChatCallTranscriptSheet.swift`
- Watch: `Conduit/Watch/WatchDirectBroker.swift`, `ConduitWatch/WatchDirectCallModel.swift` (trimTranscript), `ConduitWatch/WatchBridgeCallModel.swift` (trimTranscript), `Shared/WatchVoice/WatchVoiceWire.swift` (DirectTranscript)
- Notifier: `notifier/dashboard/api/voice_calls.py` (/voice/sessions, /voice/chat-calls, /voice/archive), `notifier/voice_archive.py`
- Background time: `Conduit/Services/BackgroundTaskHold.swift` (`AppState.beginVoiceTranscriptBackgroundTask`, the Watch broker's revoke and late revoke)

**Rulings**
- A call's turns go to the host only when the call ends; saving mid-call stalled Gemini (2026-10-01, #281).
- While a call runs its unsaved turns are kept in the on-device outbox, within 10 seconds of a turn settling and on a 15-second timer, so a call the app loses mid-way is saved later. A checkpoint with nothing new (no turn, job or chat change) writes nothing, and a call cut short is measured to its last checkpoint (2026-10-24, #1220, from #1002). Gemini, Qwen, Grok, GPT-Live and Local Live share this path; Classic saves in its own chat, and the Watch saves once at the end.
- A saved call keeps the session source "desktop"; its voice tags live in their own meta key, since a session's source picks the agent's toolsets (2026-09-30).
- A call joined to a chat is kept with the chat, not in a second session, and a reconnect within 120 seconds continues the same call (2026-10-13, #574, notifier #98). So is a call that took its first request's chat: that chat is the call's, not one of its jobs, and Resume Call goes back to it (2026-10-25, #1252). A Watch call has no attached chat on the phone, so it is still saved as its own.
- A call that stands alone, and a chat a Classic call created, are archived when the call ends; a typed turn brings them back (2026-10-22, #1127, notifier #295). So is each of its jobs' chats once Hermes has answered it (its own entry, Voice in the chats list; 2026-10-28, #1445, notifier #442).
- Ending a call runs Hermes' session-end hooks and memory commit; a call kept with its chat writes memory under the chat (2026-10-06, notifier #46; 2026-10-13, notifier #98).
- A call's turns stay in memory until the host has them; each capture starts after the last line it took, and rescans only when the engine changed a line before it (2026-10-24, #1222, from #1004).
- A Watch call, in every voice mode, keeps only the newest 40 KB of its transcript while it runs, the most its saved call can carry. Lines still in use (an open line, the user turn a tool call answers) and a single newest turn over 40 KB are kept whole; the saved call clips them (2026-10-24, #1221).
- The call's card in its chat keeps its start time on the short detail line under the title, so a long title ("Started from" a chat) has the card's width (2026-10-29, #1507, issue #1440).

**Open gaps**
- None known.

**Checked:** 2026-10-29, #1507 (the call card's start time under its title, #1440); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1445 (a call's jobs leave Desktop's list once answered); 2026-10-26, #1247 (the closing transcript save and the Watch broker's revokes keep Conduit running through BackgroundTaskHold); 2026-10-25, at #1252, for a call kept with its first request's chat; Qwen joins the shared save path (`qwen-live` history), at #1182, carried in #1235; 2026-10-24, at #1222 (capture cursor); at #1221, for the Watch's transcript tail; at 78f21da; at #1191: a saved screen turn cut at the plugin's limit keeps its last line unless it can be half a fence (#926 review); at #1220: quiet checkpoints, and a saved turn's cut closes a long fence with one as long, within the plugin's limit.

## Voice in the chats list

What voice leaves in the chats lists: saved calls, the chats calls were kept
with, Classic voice chats and voice jobs, in Conduit and in Hermes Desktop.

**Siblings:** the Chats list's Voice filter (iPhone, iPad, Mac) · the
sidebar's Voice source · nests under a call or a chat · the Archived screen
· content search · Hermes Desktop's list (what the plugin archives) · a call
kept with its chat · a call row · a chat Classic made · voice jobs (phone,
CarPlay, Classic, the Watch's relay and the iPhone's jobs for a Watch call)
· the chat an unattached call took · `docs/VOICE_BACKGROUND_JOBS.md` · the
notifier's README

**Code**
- Filing and listing: `Conduit/Services/AppState.swift` (sessionCategory, voiceCallChatFilter, isArchivedVoiceChat, refreshVoiceSessionTags, adoptHostChatCalls), `Conduit/Voice/VoiceHistory.swift` (VoiceSessionTag, VoiceHostChatCall, VoiceCallChatLinks adopt and chatIDs)
- Lists: `Conduit/Views/V2/V2ChatsView.swift` (V2FilterSelection.rows), `Conduit/Views/SidebarView.swift` (SidebarSourceRows), `Conduit/Models/SessionNesting.swift`
- A job's follow-up words: `Conduit/Voice/VoiceBackgroundJobs.swift` (sendFollowUp, threadTurnText)
- Notifier: `notifier/voice_archive.py` (archive_answered_job, settled_voice_job, bring_back), `notifier/__init__.py` (_on_session_end, _pre_llm_call), `notifier/dashboard/api/voice_calls.py` (/voice/tags with chat_calls, set_voice_tag, /voice/archive), `notifier/dashboard/api/watch_jobs.py` (_WatchJobs._follow_up)

**Rulings**
- Hermes Desktop's list keeps only the chats people work in: a call's own row and a chat Classic made are archived when the call ends (Eric 2026-10-22, #1127, notifier #295), and a voice job's chat each time Hermes answers what voice asked there, at its turn's end or when Conduit tags it after the call. All with Hermes' auto-archive stamp, so a turn in one brings it back (Eric 2026-10-28, #1445, notifier #442).
- A job's chat is archived only while voice alone has used it: every request in it is a job prompt, the Watch's next request or `(voice) ` words. Typed into, it stays listed for good; failed, stopped, running, pinned or user-archived, it's left as it is. The chat an unattached call took for its first request is the call's, never tagged a job (on the phone or the Watch's relay), and stays listed (2026-10-28, #1445, notifier #442).
- Conduit lists every row the plugin archived as if it weren't, and its Archived screen leaves them out (2026-10-22, #1127).
- Voice lists the call rows, the chats Classic made and every chat a call was kept with or started from, on every device: the host lists each chat's kept calls with the voice tags (the latest 300; a chat deleted in Desktop leaves it when next asked), and a device adopts the ones it lacks, so their chats show the call cards too. Such a chat keeps its own icon and source (Eric 2026-10-28, #1445, notifier #442).

**Open gaps**
- A Bot Chat's calls are kept in the bot's profile, so another device doesn't adopt them (#1445).
- Desktop doesn't group voice rows under their call; archiving is how they stay out of its list (would need Hermes).

**Checked:** 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1445.

## The user's words in a call's transcript

How each voice mode turns the provider's transcription of what the user said
into one line per utterance, on screen and in the saved call.

**Siblings:** Gemini Live · Qwen Live · Grok Live · GPT-Live · Local Live ·
Classic (speech server) · Watch calls · CarPlay · a call from Hermes · the
saved transcript (see Ending a call and what gets saved)

**Code**
- Gemini and Qwen: `Shared/GeminiLive/GeminiLiveProtocol.swift` (inputTranscription), `Shared/GeminiLive/QwenLiveSocket.swift` (maps Qwen's one completed transcript per item)
- Grok: `Shared/GrokLive/GrokLiveProtocol.swift` (InputTranscriptStage), `Shared/GrokLive/GrokLiveSession.swift` (pendingInput, finishInput); the phone's calls, CarPlay and calls from Hermes build it in `Conduit/Services/AppState.swift`, and the Watch runs the same session (`ConduitWatch/WatchDirectCallModel.swift`)
- Local Live: `Shared/LocalLive/LocalLiveSession.swift`, decoding with Grok's protocol
- GPT-Live: `Conduit/Voice/GPTLive/GPTLiveProtocol.swift` (inputTranscript deltas, the turn assembler)
- Classic: `Conduit/Voice/SpeechServerTranscription.swift`
- Shared controller: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift` (appends each piece to the open user line)
- Tests: `ConduitTests/GrokLiveVoiceTests.swift`

**Rulings**
- What the controller gets is appended, never replaced, so a mode hands on either deltas (Gemini, GPT-Live) or each utterance once, whole (Qwen, Grok, Local Live).
- Grok: xAI sends `conversation.item.input_audio_transcription.completed` several times per item, drafts with `status` `in_progress` that rewrite each other, then one `completed`, before the reply's transcript. Only the completed one is kept; drafts are never appended. An item that never gets one keeps its newest draft when the next item starts, the connection is replaced, or the call ends or fails. A snapshot with no status goes through once per item, as the Realtime protocol sends it; with no item id either, every time. A draft with no item id is replaced by the next snapshot with none (2026-10-27, #1347, for #1324).
- Local Live drops a snapshot its server marks `in_progress` and keeps the rest (2026-10-27, #1347, for #1324).

**Open gaps**
- None known.

**Checked:** 2026-10-28, #1424 (Grok and Local Live sessions trace turns; transcripts unchanged); 2026-10-27, #1347.

## The Watch call log

Timings and connection events from Watch calls, never what was said, kept
on the Watch and sent to the iPhone, where the user shares them for a
support question.

**Siblings:** the Watch's batcher and its unsent file · the Watch's own log
file and its Clear button · the iPhone's copy, with Share call log and Clear
Log in Voice settings > Apple Watch · the iPhone's own Watch-call lines
(WatchVoiceLink)

**Code**
- Watch: `ConduitWatch/WatchCallLog.swift`, `ConduitWatch/WatchHomeView.swift` (Clear), `Shared/WatchVoice/WatchCallLogBatch.swift`
- iPhone: `Conduit/Watch/WatchPhoneCallLog.swift`, `Conduit/Watch/WatchVoiceLink.swift` (note), `Conduit/Watch/WatchSettingsSection.swift`

**Rulings**
- Lines travel in batches of up to 50 lines or 32 KB, about 30 seconds after the oldest, and at once around a call's end.
- While WatchConnectivity can't deliver, the waiting lines keep to 600 lines and 300 KB in memory and when the next run restores them, and the unsent file is written again from them once it passes twice that; past the budget the oldest go, and a first `watchLogDropped` line says how many (2026-10-24, #1221).
- The iPhone appends whatever lines arrive, the dropped line included.

**Open gaps**
- None known.

**Checked:** 2026-10-24, at #1221.

## GPT-Live's runtime for the Watch

Watch calls to GPT-Live run WebRTC on the Hermes host, in a helper under a
small Python environment the plugin makes once with aiortc.

**Siblings:** the plugin's prepare and status routes · the Set up row and its
caption in Voice settings > Apple Watch · `engines` in a Watch grant, which
lists GPT-Live only once the runtime is ready · the reason a Watch hears when
it starts GPT-Live without one · the notifier README's Watch audio section

**Code**
- Host: `notifier/dashboard/api/watch_audio.py` (_WatchAudioRuntime), `notifier/dashboard/watch_audio_helper.py`, `notifier/tests/test_watch_audio.py`
- iPhone: `Conduit/Watch/WatchSettingsSection.swift` (Set up, the runtime's state), `Conduit/Watch/WatchToolGrantClient.swift` (prepareAudio, audioStatus)
- Watch calls: `Conduit/Watch/WatchDirectBroker.swift` (prepareRuntime, the "takes a few minutes" refusal), `Shared/WatchVoice/WatchVoiceWire.swift` (AudioBridge.engines)
- Text: `notifier/README.md` (Watch audio)
- Background time: `Conduit/Services/BackgroundTaskHold.swift` (the Watch broker's bridge start)

**Rulings**
- The plugin never installs into Hermes' own Python: it makes its own environment, with venv and pip from the Python Hermes runs, else uv. A Hermes Python that already has both aiortc and av is used as it is, with Hermes' import path.
- The environment is made without Hermes' PYTHONPATH and pip runs isolated, so it gets its own copy of every package aiortc needs, even ones Hermes already has. The helper runs isolated in that environment and can't see Hermes' packages (2026-10-25, #1254, notifier #370).
- The environment counts as ready only once its marker names the plugin's aiortc pin; a failed prepare writes none, so the next Set up makes it again.

**Open gaps**
- None known.

**Checked:** 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-26, #1247 (the Watch broker's bridge start keeps Conduit running through BackgroundTaskHold); 2026-10-25, at #1254.

## A Watch call with no network

watchOS gives a Watch call's live socket ("low-level networking") a route
apart from the Watch's ordinary internet, so a Watch that browses fine
through the iPhone can still have every socket refused with -1009 (#1346).

**Siblings:** GPT-Live (the host bridge) · Gemini and Qwen (their own
socket) · Grok and Local Live (the host bridge) · a call from Hermes answered
on the Watch, which runs the same calls · the end message · the call log's
lines · phone, CarPlay and CallKit calls, which reconnect on the iPhone's own
network (Reconnecting to Hermes) · watchOS 10: the home screen's note, Settings' Call on open (hidden there), a call
started any other way (the button, the watch face complication, Siri and the Action button), and calls from Hermes ringing the Watch ("Calls from Hermes" records it) · README.md's requirements · docs/OWN_VOICE_SERVER.md (Local Live on the Watch)

**Code**
- Shared rule: `Shared/WatchVoice/WatchNoNetwork.swift`, tests in `ConduitTests/WatchAudioBridgeTests.swift`
- GPT-Live: `ConduitWatch/WatchBridgeCallModel.swift` (socketEvent, offlineRefusals in the call's end line)
- Gemini, Qwen, Grok, Local Live: `ConduitWatch/WatchDirectCallModel.swift` (endIfNoNetwork, `directNoNetwork`)
- The message: `ConduitWatch/WatchVoiceCall.swift` (WatchCallEnd.noNetwork)
- watchOS 10: `ConduitWatch/WatchVoiceCall.swift` (callsWork, WatchCallEnd.oldWatchOS, start, startOnOpenIfWanted), `ConduitWatch/WatchHomeView.swift` (the note, WatchSettingsView hides Call on open), `ConduitWatch/WatchCallView.swift` (no Try again), `ConduitWatch/HermesWatchCalls.swift` (sendToken, receive)

**Rulings**
- A call none of whose sockets has opened ends on the second socket refused for no network (-1009, or data not allowed or roaming off), saying the Watch couldn't get a network connection and to keep the iPhone nearby with Bluetooth on or join Wi-Fi on the Watch. The first refusal is retried, since the route can come up just after the audio session activates. Once any socket has opened, a drop is the call's to rejoin as before (2026-10-27, #1349, for #1346).
- On watchOS 10 Watch calls don't start: watchOS refuses their sockets whatever the audio route, Bluetooth headphones included (reporter's test, #1346). The home screen says so under the button (naming the iPhone's ring only where calls from Hermes ring), Settings hides Call on open and it doesn't start one, a call started any other way ends at once with the same message and no Try again, and the Watch sends the iPhone no call token, without waiting for PushKit's, so calls from Hermes ring the iPhone alone. Eric chose saying so before the call over trying CallKit, which no one could test (2026-10-31, #1591, #1593). Whether watchOS 11 to 26 get the network isn't verified; watchOS 27 does.

**Open gaps**
- There's no iPhone-carried audio route to fall back on: the first Watch design carried audio through the iPhone and stopped whenever it locked or Conduit was suspended (designs/apple-watch-voice-direct.md).

**Checked:** 2026-10-31, #1593; 2026-10-31, #1591.

## Calls from Hermes

Hermes rings the user (a job is done, it waits on an answer, a scheduled
check), and the call has to ring, start and talk everywhere it can be
answered.

**Siblings:** CallKit on the phone (unlocked, locked, in another app) ·
CarPlay · the Apple Watch (every voice, Local Live included) · each voice mode that answers (Classic, Gemini,
Qwen, Grok, GPT-Live, Local Live agent mode; Local Live otherwise opens Classic) · the missed-call notification ·
Bot Chat calls · the call trace · the notifier's call tool and skill ·
Pulse (it may call only once the user opts in) · moving to a new iPhone
(Settings > Notifications' Pair button, the Watch's ring that follows the
pairing, Hermes call settings' notice, the relay's registrations, the host's
log of where a call rang) · where the turn came from, for alert calls (Hermes
Desktop, the web dashboard, a terminal, the chat open in Conduit on any
device) and Settings' "Wait while I'm at a screen"

**Code**
- Ringing and answering: `Conduit/Voice/HermesNativeCalls.swift` (receive, stopsWatchRing, startWatchCall), `Conduit/Voice/HermesCalls.swift`, `Conduit/Services/AppState+HermesCalls.swift` (answerHermesCall, hermesCallAudioActivated), `Conduit/Services/AppState.swift` (openVoiceConversation, usesLocalLiveAgent: which voice a call opens)
- Caller name: `Shared/WatchVoice/HermesRing.swift` (HermesCallerName)
- Trace: `Conduit/Voice/HermesCallTrace.swift`
- CarPlay: `Conduit/CarPlay/CarPlayVoiceCoordinator.swift`
- Watch: `ConduitWatch/HermesWatchCalls.swift` (followPhone, phoneCallMuted, leavePhone), `Conduit/Watch/WatchVoiceLink.swift` (startAnsweredCall), `Conduit/Services/AppState+HandsFreeProfile.swift` (watchCallProfile: the calling profile), `Shared/WatchVoice/WatchCallVoices.swift` (rings), `Conduit/Watch/WatchDirectBroker.swift` (prepareLocalLive)
- Answered on the Watch, kept on the iPhone's headset: `Conduit/Voice/HermesNativeCalls.swift` (keepsWatchAnswer, keepFromWatch, startedOnWatch, watchControlChanged, muteOnWatch, inAppMuteChanged, endOnWatch), `Conduit/Services/AppState+HermesCalls.swift` (nativeCallVoiceMuted), `Shared/WatchVoice/HermesRing.swift` (HermesRingControl), `ConduitWatch/WatchVoiceCall.swift` (onPhone), `ConduitWatch/WatchCallView.swift`, `ConduitWatch/WatchDirectCallModel.swift` and `ConduitWatch/WatchBridgeCallModel.swift` (callOnPhone), `Shared/WatchVoice/WatchVoiceWire.swift` (callOnPhone, callsToken's phoneHeadset), `Conduit/Watch/WatchDirectBroker.swift` (handle: a kept call's start gets callOnPhone), `Conduit/Watch/WatchVoiceLink.swift` (callsToken: phoneHeadset), `notifier/relay/src/rings.mjs` (setControl, readControl, adopt)
- Settings: `Conduit/Views/HermesCallSettingsViews.swift` (the notice that the Watch rings for another iPhone)
- Alert calls at a screen: `notifier/calls.py` (_quiet_at_screen, _at_screen, SCREEN_ALERT_DELAY_S), `notifier/calls_store.py` (`quiet_at_screen`), `notifier/reply_sources.py` (turn_source), `notifier/chat_on_screen.py` (on_screen), `Conduit/Voice/HermesCalls.swift` (HermesCallSettings.quietAtScreen), `Conduit/Views/HermesCallSettingsViews.swift` ("Wait while I'm at a screen")
- A new iPhone: `Conduit/Views/AuxiliaryViews.swift` (oneTapPairing: what a Pair tap did), `Conduit/Services/PushNotificationService.swift` (watchRingsForAnotherIPhone; a Watch token the relay let go goes again), `notifier/relay/src/store.mjs` (setWantedWatchVoipToken, gatewayRevoked), `notifier/relay/src/server.mjs` (DELETE /v1/gateways/current's `replaced_by`; the call answer's `watch`), `notifier/relay_urls.py` (replaced_pairing_query), `notifier/client.py` (_revoke_replaced, call_delivery), `notifier/dashboard/api/pairing.py` (_revoke_replaced_pairing)
- Notifier: `notifier/call_tool.py`, `notifier/calls.py` (_deliver_waited: the wait at a turn's end; _wait_at_exit: the exit's wait for retries), `notifier/client.py` (_drain_at_exit: the fallback push those retries queue), `notifier/calls_store.py`, `notifier/call_watches.py`, `notifier/skills/calling-the-user/SKILL.md`, `notifier/relay/src/rings.mjs`
- Background time: `Conduit/Services/BackgroundTaskHold.swift` (HermesNativeCalls' settleRing, startWatchCall, keepFromWatch, muteOnWatch, endOnWatch)

**Rulings**
- Answering is the only tap: the call opens its chat and starts talking by itself (2026-10-10, #508).
- A declined or missed call is told to Hermes in that chat's next turn, with no second ring (2026-10-10, #518, notifier #78).
- Hermes speaks first on a call it made (2026-10-11, #546, notifier #89).
- The call screen names the calling profile; the main profile goes by its Conduit name (2026-10-11, #541). A bot goes by its name as the Bots list shows it (the push's `profile_name`), else its capitalized id; a main profile never named in Conduit (or named "Hermes", which reads the same) goes by its bot's name rather than "Hermes" (Eric 2026-10-25, #1257, notifier #372).
- A call about an approval or question is briefed from the chat's card, not the push's short reason, and answered by voice everywhere it can be (see "Hermes is waiting on you"; 2026-10-24, #1194, notifier #343).
- A Watch that answers starts the call through the relay, since its link to the iPhone is down under the call screen (2026-10-11, #526, notifier #82).
- Answered on the Watch while the iPhone has a headset on (AirPods, wired), the call stays on the iPhone and plays there, whatever the Watch's voice: the iPhone answers its own ring with its own voice mode, and the Watch's call screen keeps Mute and End, shared through the relay's ring control. Every mute reaches the other device: CallKit's on either call screen, and Conduit's own (the call screen's Mute, the minimised bar, Classic's paused microphone). A relay restart mid-call loses nothing: each device writes its state again and reads on, and a change made while the relay was down is retried. With no headset on the iPhone, or a relay older than 0.17, the Watch takes it as before (Eric 2026-10-24, #1225, notifier #354).
- In the car, CarPlay rings and the Watch stays quiet (2026-10-14, #602).
- Answered on the Watch, the call runs on the profile that called (on the dashboard in use), whichever profile the iPhone has open or the hands-free setting names; until #1573 it ran on the iPhone's (Eric 2026-10-31, #1573, issue 1564: part of the Watch and Siri design he picked, as the issue asked).
- A call muted in CallKit before its voice is running starts muted in every voice: classic voice since #558, the live modes since #1378 (their controllers' `startsMuted`, from AppState's hermesCallStartsMuted; GPT-Live hands it to GPTLiveSession so the WebRTC track is created disabled).
- On a profile set to Local Live in agent mode, a call from Hermes opens Local Live, and its fast model says why Hermes called; on Classic's hands-free option it opens Classic, which says it. Since #1194 the call asked for Local Live but the voice start still turned it into Classic (2026-10-27, #1378, from #1376).
- A call from a cron job rings like one from a chat. Hermes runs a restart-safe cron job in a worker process that exits right after the turn, so the turn's end waits for the call request to reach the relay, up to 3 seconds (the failed turn's alert call and held calls swept then too, all in one wait), and the worker's exit then waits up to 10 more for its retries, and up to 3 after that for the usual push they fall back to (2026-10-26, notifier #389, issue #388).
- After a move to a new iPhone the Watch's ring follows the pairing: the old iPhone's registration still holds the Watch's PushKit token, which the new one can't simply take (notifier #146), so the host that pairs a profile with the new iPhone names it when it revokes the old pairing and the token moves there, if the new iPhone asked for it; an old iPhone a re-pair leaves with no pairing lets it go, and an unpair keeps it. Until then Hermes call settings say the Watch still rings for the other iPhone, and the Pair button says what it did. The host logs where each call rang (2026-10-28, #1441, notifier #440).
- An alert call about a turn the user is following on a screen waits longer, and a failed turn there sends its push instead of calling: 10 minutes instead of one, or until 90 seconds before Hermes would give up on the approval or question if that's sooner (`approvals.timeout`, 3.5 minutes into an approval by default; the clarify timeout), never under a minute, so the call can still be answered. That applies when its message came from Hermes Desktop or the web dashboard (an app socket with a browser user agent), from a terminal (`cli`, or Hermes' TUI with no app socket), or Conduit has its chat on screen on any device. Longer, not never, so a user who walks away still hears about it. A turn whose source can't be told calls after a minute, as before. On by default ("Wait while I'm at a screen", shown with alert calls on); calls the user asked for and Hermes' own calls are unchanged (Eric 2026-10-30, #1544, notifier #479, issue notifier #474)

**Open gaps**
- A ring for another iPhone still reaches the Watch, which can't tell it apart, and its answer goes to that iPhone: an old iPhone still paired with some profile keeps the Watch's token until that profile is paired here too (notifier #440).
- A sealed push carries no profile to the Watch, so its call screen says "Hermes" (#541).
- A Watch on watchOS 10 never rings: it sends the iPhone no call token and rings no push, since its calls get no network ("A Watch call with no network", #1591, #1346). The iPhone rings alone.
- Whether a call rings the Watch is checked on the hands-free profile, while an answered call runs on the profile that called: a caller whose profile can't start the Watch's voice rings the Watch, and the answer says why it can't start. A call from another dashboard's profile runs on the iPhone's profile, as the push's dashboard isn't the one in use (#1573).
- The first push after install, before the first status read, can still switch dashboards, and missed-call outcomes are keyed by the pushed dashboard id (#1096).

**Checked:** 2026-10-31, #1593 (a Watch on watchOS 10 sends its nil token without waiting for PushKit); 2026-10-31, #1591 (a Watch on watchOS 10 sends no call token and doesn't ring); 2026-10-31, #1573 (a call answered on the Watch runs on the calling profile, issue 1564); 2026-10-30, #1544 (alert calls wait longer at a screen, failed turns there push, notifier #474); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1449 (a file in the reply a call is about is named, never its path); 2026-10-28, #1441 (the Watch's ring follows a re-pair to a new iPhone, with notifier #440; the iPhone sends the token the Watch reports at each Watch launch, held or not, so a Watch back with it asks for its ring again; the Pair button says what it did); 2026-10-27, #1378 (a call on Local Live in agent mode opens Local Live, on the phone and in CarPlay); 2026-10-26, #1291 (a call from a cron job's worker waits for the relay before the worker exits, notifier #389, issue #388); 2026-10-26, #1247 (the ring's settle and a Watch answer's start, keep, mute and end keep Conduit running through BackgroundTaskHold); 2026-10-25, #1257 (the caller's name from `profile_name` on the phone, the Watch and the missed call); Qwen among the modes that answer, and its mute on a call kept on the iPhone's headset (nativeCallVoiceMuted), at #1182, carried in #1235; 2026-10-24, #1225: a call answered on the Watch stays on the iPhone's headset (#1204); at #1194.

## Audio route, Speaker and mute

Where the voice comes out, who owns the audio session, and what mutes what.

**Siblings:** Classic · Gemini, Qwen, Grok and Local Live (default and
echo-cancelling audio) · GPT-Live (WebRTC) · calls from Hermes (CallKit's
Speaker button) · CarPlay · AirPods and Bluetooth · Read Aloud · the call
screen's Mute and Silence · the minimised call bar · a Watch-answered call
kept on the iPhone's headset (the Watch's Mute and End)

**Code**
- Session owner: `Conduit/Voice/VoiceAudioSessionCoordinator.swift` (ensureConversationSpeaker, isNativeCallAudioActive), `Conduit/Voice/VoiceAudioSessionConfiguration.swift`
- Playback: `Conduit/Voice/AVSpeechPlaybackService.swift` (resumeOnFreshEngine), `Conduit/Voice/VoiceAudioEngineRecovery.swift`
- Live audio: `Conduit/Voice/GPTLive/GPTLiveAudioLink.swift`, `Conduit/Voice/GeminiLive/LiveVoiceEchoCancellingAudio.swift`, `Conduit/Voice/EchoCancellingVoiceConversationAudio.swift`
- Mute and Silence: `Conduit/Views/LiveVoiceCallSheet.swift`, `Conduit/Views/MinimisedLiveVoiceBar.swift`, `Conduit/Voice/HeadsetMicrophoneMute.swift`
- A Watch answer kept on the iPhone's headset: `Conduit/Voice/HermesNativeCalls.swift` (keepsWatchAnswer, muteOnWatch, inAppMuteChanged), `Conduit/Services/AppState+HermesCalls.swift` (nativeCallVoiceMuted), `ConduitWatch/HermesWatchCalls.swift` (phoneCallMuted)
- Read Aloud: `Conduit/Voice/MessageReadAloudController.swift`, `Conduit/Views/ReadAloudPlayerBar.swift`
- Background time: `Conduit/Services/BackgroundTaskHold.swift` (HermesNativeCalls' muteOnWatch)

**Rulings**
- During a call from Hermes, CallKit owns the audio session: Conduit never deactivates or re-activates it, so the Speaker button stays true (2026-10-21, #1093; 2026-10-23, #1148).
- A conversation's replies move from the earpiece to the speaker, never during a CallKit call (2026-10-19, #943).
- Silence mutes the assistant's voice apart from the microphone; its speech is dropped, not held, and job news waits for unmute (2026-10-09, #488).
- An alarm or phone call pauses a live call, which comes back when the audio does (2026-10-04, #380).
- A call from Hermes answered on the Watch plays on the iPhone's headset when one is on there (AirPods, wired, never the car's); the Watch's Mute and End control it like a phone call's, and a mute from any of Conduit's own controls reaches the Watch (Eric 2026-10-24, #1225).

**Open gaps**
- Silence isn't on CarPlay or the minimised bar (#488).
- Classic still ends with "Audio was interrupted." when an alarm or phone call takes the audio, where live calls pause; only CarPlay and calls from Hermes restart it (#380, #1155).

**Checked:** 2026-10-30, #1524 (Read Aloud reads a Desktop card as a short note; route, Speaker and mute unchanged); 2026-10-26, #1247 (a mute reaching the Watch keeps Conduit running through BackgroundTaskHold); 2026-10-25, Qwen in the siblings, and its mute reaching the Watch, at #1182, carried in #1235; 2026-10-24, #1225: the Watch's Mute and End for a call kept on the iPhone's headset; seeded from main at 64d53c3.

## Talking over Hermes

Speaking while Hermes talks or thinks: barge-in, talk-over, steering, push to
talk, and how long the microphone waits.

**Siblings:** Classic (phone, CarPlay, locked phone) · Gemini Live · Qwen
Live · Grok Live · GPT-Live · Local Live · Watch calls · headset, speaker and car routes ·
push to talk · Continuous Conversation · the Action, headset and CarPlay
buttons · the Interrupt button, CarPlay's Stop and the Watch orb · the
notifier's Local Live read-back relay (phone socket and Watch bridge) · docs/VOICE_SETTINGS.md and
docs/OWN_VOICE_SERVER.md · the notifier's README (read-back)

| Mode | On a headset | On the speaker or in the car |
|---|---|---|
| Classic | talk-over starts a new turn; speech while Hermes thinks, or over its acknowledgement, steers | the same, with "Talk over it on the speaker" on |
| Gemini, Qwen, Grok, Local Live | barge-in | barge-in with "Talk over it on the speaker" on |
| GPT-Live | barge-in (WebRTC cancels the echo) | barge-in |

**Code**
- Routes: `Conduit/Voice/VoiceBargeInRoutePolicy.swift`
- Classic: `Conduit/Voice/VoiceConversationController.swift` (isTalkOverAvailable, isSteerAvailable, isAcknowledgementSteerable, beginPushToTalk), `Conduit/Voice/VoiceSpeechDetector.swift`, `Conduit/Voice/EchoCancellingVoiceConversationAudio.swift`
- Live modes: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift`, `Conduit/Voice/GeminiLive/LiveVoiceEchoCancellingAudio.swift`, `Conduit/Voice/GPTLive/GPTLiveConversationController.swift`
- Interrupt: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift` (interruptSpeaking), `Shared/GeminiLive/GeminiLiveSessionControlling.swift` (cancelResponse), `Shared/LocalLive/LocalLiveSession.swift` (cancelResponse), `Shared/LocalLive/LocalLiveProtocol.swift` (responseCancel), `ConduitWatch/WatchDirectCallModel.swift` (tapOrb), `notifier/dashboard/api/local_live_read_back.py` (_LocalLiveReadBack.from_client, _stop; the phone's socket and the Watch's bridge both run it)
- Push to talk surfaces: `Conduit/Services/AppState.swift` (pushToTalkSurfaceAvailable)
- Settings: `Conduit/Views/VoiceSettingsView.swift`, `Conduit/Views/GeminiLiveViews.swift`, `Conduit/Views/GrokLiveViews.swift`

**Rulings**
- In Classic, talking over a spoken reply stops it and starts a new turn; speech while Hermes thinks steers it (2026-10-04, #391). Hermes' acknowledgement while it works isn't the reply: talking over it, Interrupt, CarPlay's Stop or a push to talk press stops it and steers the running turn (2026-10-27, #1390).
- Talking over on the speaker is opt-in, "Talk over it on the speaker", off by default, one setting shared by Qwen, Gemini, Grok and Classic, which each mode's caption says (2026-10-03, #351; Classic 2026-10-04, #393; Qwen 2026-10-25, #1182).
- Push to talk is per profile and off by default. While held no silence timer runs; a press while Hermes speaks interrupts, while it thinks steers. CarPlay and calls from Hermes stay hands-free (2026-10-22, #1106).
- Interrupt (CarPlay's Stop and the Watch orb too) stops what plays on the device. In Local Live (the phone's Interrupt, CarPlay's Stop and the Watch orb) it also sends the speech server `response.cancel`, which the read-back relay passes on even when no sentence is in progress, so a server that shuts its own microphone while its reply plays listens again; nothing is guessed from the audio, and background jobs go on. Gemini, Grok and Qwen stop only what plays here: their servers hear the user over the reply and keep no gate (2026-10-27, #1331, notifier #404, from #1325).
- With Continuous Conversation on, the default, Classic keeps listening through silence instead of pausing the microphone (2026-10-10, #520).

**Open gaps**
- Push to talk is Classic only: not the live modes, the Watch, or the Action, headset and CarPlay buttons (#1106).

**Checked:** 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-27, #1390 (Classic: cutting Hermes' acknowledgement short steers); 2026-10-27, #1378 (CarPlay's Stop on Local Live tells the server too); 2026-10-27, #1331 (Interrupt tells a Local Live server, #1325); 2026-10-25, Qwen in the siblings, the table and the shared caption, at #1182, carried in #1235; 2026-10-23, seeded from main at 64d53c3.

## Files Hermes attaches, in what voices say

A reply can attach a file with Hermes' `MEDIA:<path>` tag (text_to_speech
answers with one) or carry a delivery directive (`[[audio_as_voice]]`). The
chat shows the file; nothing that speaks the reply reads the tag out, and
no live model is handed the path to read out either.

**Siblings:** Read Aloud · Classic voice's spoken reply (phone, CarPlay) ·
Local Live's spoken and shown split (the call's screen shows the file) ·
live read-back of a reply asked for again, and the result a Hermes call
reads out · job results, chat replies (a job's thread reply, and the open
chat's latest reply in a chat call's instructions) and read_chat as Gemini, Qwen, Grok,
GPT-Live and Local Live get them, on the phone and the Watch, and a
Hermes call's reply in its instructions · the
notifier's line for a spoken turn, which tells the model its answer is
heard · chat bubbles (the file card)

**Code**
- The tag grammar: `Conduit/Views/Components/GatewayMediaTags.swift` (removingTags, namingFiles; also built into the Watch app, `project.yml`)
- Streaming speech: `Conduit/Voice/SpokenMediaTagFilter.swift`, used by `Conduit/Voice/SpokenTextFilter.swift` (Classic, Read Aloud's Now Playing) and `Conduit/Voice/LocalLive/SpokenVisualSplitter.swift` (Local Live, which puts the files on the call's screen)
- Read Aloud: `Conduit/Voice/MessageReadAloudController.swift` (toggle)
- Live read-back: `Conduit/Voice/VoiceReadBack.swift` (plainSpeech)
- What live models are handed: `Conduit/Voice/VoiceBackgroundJobs.swift` (completionPrompt, threadReplyPrompt, replyBlock), `Conduit/Services/AppState.swift` (liveVoiceThreadInstructions: the open chat's latest reply), `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift` (a job's tool response, read_chat), `Shared/WatchVoice/WatchJobRelay.swift` (WatchJobAnswer.completionPrompt), `Shared/WatchVoice/VoiceChatToolText.swift` (readResult, and delegatedRead for GPT-Live's "Read chat:" in `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift` and the Watch's `Shared/WatchVoice/WatchToolRelay.swift`)
- A Hermes call's result: `Conduit/Voice/HermesCalls.swift` (instructionBlock names files; spokenBrief uses plainSpeech)
- Local Live's screen: `Conduit/Voice/LocalLive/LocalLiveTurnRunner.swift` (finish)
- What the model reads: `notifier/turn_surface.py` (SPOKEN_HINT)
- Tests: `ConduitTests/HermesVoiceGatewayTimeoutTests+LocalLive.swift` (testSpokenVisualSplitterLeavesFileTagsUnsaid), `ConduitTests/GeminiLiveVoiceTests.swift` (testSpokenMediaTagFilter…, testSpokenTextFilterLeavesFileTagsUnsaid), `ConduitTests/VoiceBackgroundJobTests.swift` (testLiveModelsAreToldOfAFileNotItsPath, plainSpeech), `notifier/tests/test_turn_surface.py`

**Rulings**
- A tag is never said, and a line that was only a tag says nothing; the words around it, and a link's label or an image's alt text, are said as written. A tag in a `>` quote is text, as Hermes doesn't deliver it, and is said like the rest of the quote. A quoted tag needs a path: one starting at a root, a home folder or a drive, or ending in a known extension, so "social media: \"we're live!\"" is words in speech, for live models and in the chat bubble alike (#1449). A quoted line's path is text too, so it is said and handed to live models as written; Hermes sends no file for it (2026-10-28, #1434, after a Local voice call on the farm read "MEDIA:/opt/data/cache/audio/tts_….mp3" out and its microphone heard "media." back).
- Streaming voices hold from where a tag may begin (with its emphasis or `[label](`) to the end of its line, and only while it can still be one: `MEDIA:` with a path after it, or a directive. Prose such as "social media: we shipped" is said as it comes; a `[` with no `]` waits up to 80 characters, then is said as it comes (Local Live's splitter, older than this, holds a `[` until its `)` or the line's end, for links). Once a tag may have begun, the rest of its line waits for the line's end, the price of a reply being said the same however it is split (#1449). Text that can't start a tag goes out as it came, its chunks unchanged ("One " then "turn."), so a space said before a tag that arrives later stays, and "Hello!" is said while a "!" after a space or mark waits for a possible image.
- Local Live puts a tagged file on the call's screen, as the chat shows it (a tag written as a link included), even when the model showed its own card or the call cut the reply off for its own line (#1449).
- A live model is told of a file by name ("(a file in the chat: report.pdf)"), never its path: a job's result, a chat reply, a chat read into the call and the reply a Hermes call is about alike (#1449).
- A spoken message's line tells the model its answer is heard: say it in words, not with text_to_speech or a sound file of its own; a file the user asks for is still fine. Hermes' own spoken-reply note isn't on every Hermes (2026-10-28, #1434, notifier #444, 0.115.1).

**Open gaps**
- None known.

**Checked:** 2026-10-30, #1524 (Hermes Desktop's directives are read alongside, with their own entry, Cards made for Hermes Desktop); 2026-10-28, #1434, carried in #1449.

## Qwen direct voice

A live call on Alibaba Cloud's Qwen realtime model, from the phone or the
Watch, with temporary credentials the notifier mints.

**Siblings:** phone direct voice · Watch direct voice · CarPlay · incoming
Hermes calls · tools and jobs · consent · saved transcripts · notifier tokens

**Code**
- Adapter: `Shared/GeminiLive/QwenLiveSocket.swift`, `Shared/GeminiLive/GeminiLiveSession.swift`
- Credentials: `Shared/GeminiLive/GeminiLiveToken.swift`, `Conduit/Voice/GeminiLive/GeminiLiveTokenClient.swift`
- Watch wire: `Shared/WatchVoice/WatchDirectWire.swift`, `Shared/WatchVoice/WatchVoiceWire.swift`
- Provider setup: `docs/QWEN_LIVE.md`; notifier: `notifier/dashboard/api/gemini_qwen_live.py`
- Plugin capability inventory: `Conduit/Views/ConduitPluginViews.swift` (separate Gemini/Qwen feature entries)
- Lifecycle/recovery: `Conduit/Watch/WatchDirectBroker.swift` (directToken, tokenRefusalAfterMint), `ConduitWatch/WatchDirectCallModel.swift`, `Conduit/CarPlay/CarPlayVoiceCoordinator.swift`
- Watch relay token: `Shared/WatchVoice/WatchToolRelayClient.swift` (keeps `qwen_live_token` beside `live_token`), tests in `ConduitTests/WatchVoiceWireTests.swift`
- Which provider runs: `Conduit/Services/AppState.swift` (configuredLiveVoiceEngine, isQwenLiveEnabled, resumeVoiceCall, adoptSyncedVoicePreferences); what models read: `Conduit/Services/AppState+AgentSettings.swift` (voice.mode, voice.qwen.*, voice.live.save_calls)
- Phone entry, shared settings and captions: `Conduit/Services/AppState.swift`, `Conduit/Views/AuxiliaryViews.swift`, `Conduit/Views/GeminiLiveViews.swift`, `Conduit/Views/VoiceChatCallTranscriptSheet.swift`
- Picker/setup identity: `Conduit/Voice/VoiceModeChoice.swift`, `Conduit/Views/VoiceSettingsView.swift`, `Conduit/Voice/VoiceSetupIssue.swift`
- Saved-call preferences/identity: `Conduit/Voice/VoiceTypes.swift`, `Conduit/Voice/VoiceHistory.swift`
- Watch transport and diagnostics: `ConduitWatch/WatchGeminiSocket.swift`
- Watch capability compatibility tests: `ConduitTests/HermesCallsTests.swift` (legacy plugins, Qwen-only and concurrent providers)
- Background time: `Conduit/Services/BackgroundTaskHold.swift` (the Watch broker's directToken)

**Rulings**
- Gemini and Qwen are independent picker entries, concurrently configurable on
  the host, with separate preferences, consent, data permissions and saved
  call identity. Shared controllers/adapters must not combine their product
  identities (2026-10-24, maintainer request on #1182).
- Both providers connect directly from the device. Watch starts explicitly
  name the provider; reconnect grants authorize the selected token tool only,
  and a token minted after the call ended or its provider's consent was
  withdrawn never reaches the Watch (Gemini too).
- With both providers' flags on (a synced blob merged across devices), Gemini
  wins everywhere: normal routing, a resumed call, CarPlay and voice.mode.
- Qwen voice can be selected on the phone independently of Gemini, with the
  host's configured voice as fallback. Qwen uses Hermes search functions.
- Hermes reads and changes Qwen's lookups, memory and personality
  (voice.qwen.*) as it does the other providers'. The Qwen voice is a typed
  name, and the settings Hermes sees have no free-text kind, so it stays
  phone-only (#1235 review).
- Qwen inherits job approvals/questions, follow-up steering, quiet job-result
  delivery, barge-in, the audio routes, bounded socket sends and calls from
  Hermes through the shared direct-call controller/tool bridge, and is named
  in those entries ("Hermes is waiting on you", "Voice follow-ups", "Job
  results during calls", "Tools and consent in calls", "Calls from Hermes",
  "Audio route, Speaker and mute", "Talking over Hermes", "Live-call sends on
  a slow connection"), which apply to Qwen as to Gemini. Provider consent and
  history stay separate.

**Open gaps**
- Real credentials, entitlement, voice availability and Watch background
  behavior need device testing; mocked tests cannot establish them.
- A screen question on a Qwen profile falls back to Classic voice:
  `Conduit/Services/AppState+ScreenQuestion.swift` (ScreenQuestionVoiceRouting.liveEngines)
  lists GPT-Live, Gemini and Grok only, until Qwen is device-tested there.

**Checked:** 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1424 (QwenLiveSocket traces turn detection and speech start and end); 2026-10-26, #1247 (the Watch broker's token answers keep Conduit running through BackgroundTaskHold); 2026-10-25, voice.qwen.* and save_calls naming Qwen, the Watch's qwen_live_token, a token minted after consent was withdrawn, provider precedence and the screen-question gap, at #1182, carried in #1235; 2026-10-24, #1182: independent provider routes and regression tests.

## Texting someone for the user

Hermes writes a text for someone ("text my wife her flight landed") and
puts it on a contact card; Send text opens Messages with the number and
the text filled in, and the user taps Send there.

**Siblings:** typed chats (conduit_show) · the call screen (Gemini, Grok and
Local Live show_on_screen, and Classic through Hermes) · GPT-Live · the saved
call transcript · group rooms · the Watch · CarPlay · an iPad without
Messages · what conduit_show, conduit_contacts and the voice contacts tool
tell models · Settings > Contacts' caption

**Code**
- Card and Send text: `Conduit/Cards/RichMediaCard.swift` (RichPerson.message), `Conduit/Cards/RichMediaCardViews.swift` (RichPersonRow, RichTextComposeSheet)
- Schema: `Conduit/Cards/card-schema.json`, `Conduit/Cards/RichCardSchema.swift`; feature "text-drafts" in `Conduit/Services/PresentedScreens.swift`
- Live models' show_on_screen text: `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift`
- Notifier: `notifier/cards/card-schema.json` (people[].message), `notifier/card_schema.py`, `notifier/show_tool.py` (TEXT_DRAFTS_FEATURE), `notifier/phone_tool.py` (CONTACTS_SCHEMA, VOICE_CONTACTS_DESCRIPTION)

**Rulings**
- Nothing is sent for the user: Messages opens filled in and only their tap sends it, so models say it's ready, never that it was sent (2026-10-23, #1159).
- A text needs the person's phone; one without is dropped (2026-10-23, #1159).
- A Conduit that doesn't say "text-drafts" gets the card without the text, and Hermes hears to put the text in its reply (2026-10-23, #1159).

**Open gaps**
- No queued send for when the user isn't looking: CarPlay and the Watch show no card, and a locked phone waits for the user to open the chat (#1159).
- GPT-Live can't put the card on the call screen itself; it asks Hermes (#366).
- Group rooms draw no cards, so no Send text there.
- Line breaks in the text become spaces, as in every card's text.
- Hermes doesn't hear whether the user sent or cancelled it.

**Checked:** 2026-10-23, at #1174.

## Message row actions

The controls on a message: the row under a reply, the row under your own
message, their long-press and selection menus, and the same actions in the
other chat surfaces.

**Siblings:** chats, project chats and Bot Chat (one row view) · group rooms ·
the selection menu · the long-press menu · VoiceOver labels · pinned replies
(the bar, and the sheet from the chat and from the Chats list) · your own
message's row · the "Replying to" card on a sent message, on a steered
one and in group rooms · /undo and /retry, which Edit and resend and Retry run · the composer's
restore of words put back (failed sends, the waiting message's Edit) · the
chat's saved copy, whose rows stand in while it opens or offline

**Code**
- Reply row: `Conduit/Views/ChatView.swift` (AssistantMessageActions, ReadAloudButton, AssistantMessageMoreMenu), `Conduit/Views/Components/MessageReactionViews.swift` (MessageReactButton)
- Your own message's row: `Conduit/Views/ChatView.swift` (UserMessageCopyButton, UserMessageMoreMenu)
- Edit and resend, Retry: `Conduit/Services/AppState.swift` (editAndResend, rewindTurn, rewindLastTurns, latestTurnRanTools); tests in `ConduitTests/AppStateSessionCompressTests.swift` and `ConduitTests/ChatQuoteTests.swift`
- "Replying to" card and its jump: `Conduit/Views/Components/ChatQuote.swift` (ReplyReferenceQuoteCard, QuotedReplyJump), `Conduit/Services/AppState.swift` (showQuotedReply, quotedReplyMessageID, showQuotedRoomMessage, quotedRoomMessageID), `Conduit/Views/GroupChatView.swift` (GroupUserBubble, the room's pendingQuotedReplyJump), `Conduit/Views/ChatView.swift` (UserMessageContent, SteerMessageContent, pendingQuotedReplyJump), `Conduit/Services/TranscriptScroller.swift` (explicitMessageRequested, a room's jump too)
- Edit and resend's words in the composer: `Conduit/Views/Components/ComposerBar.swift` (applyComposerRestoreRequests), `Conduit/Models/PendingComposerSend.swift` (ComposerDraft.restoring)
- Which reply offers Retry: `Conduit/Views/ChatRowState.swift` (ChatRowFacts.retryableReplyID, from the rows drawn, worked out by `Conduit/Views/TranscriptModel.swift`)
- The saved copy's rows: the chat's own rows while they stand in, their cards' jump turned off in `Conduit/Views/ChatView.swift` (quotedReplyJump); Edit and resend, Branch, Retry and Read aloud off through `Conduit/Views/ChatRowState.swift` (isOffline)
- Selection and long-press menus: `Conduit/Views/Components/SelectableTextView.swift`
- Group rooms: `Conduit/Views/GroupChatView.swift` (GroupMessageCopyButton, GroupMessageQuoteButton, GroupReadAloudButton)
- Pins: `Conduit/Views/PinnedReplyViews.swift`, `Conduit/Models/PinnedReplies.swift` (overview), `Conduit/Services/AppState+PinnedReplies.swift`, `Conduit/Services/AppState.swift` (deleteBot, forgetBotChatPinnedReplies), the sheet's Chats-list entry points in `Conduit/Views/SidebarView.swift` and `Conduit/Views/V2/V2ChatsView.swift` (showPinnedReplies)
- Read Aloud: `Conduit/Voice/MessageReadAloudController.swift`, `Conduit/Views/ReadAloudPlayerBar.swift`
- Branch (the ⋯ menu, /branch and /fork): `Conduit/Services/AppState.swift` (branchFromAssistantMessage), `Conduit/Services/HermesClient.swift` (branchSession); tests in `ConduitTests/AppStateChatResumeTests.swift`

**Rulings**
- A reply's row is React, Copy, Read aloud and ⋯ (Quote, Branch, Retry on the newest reply (2026-10-28, issue 1420, #1446), Pin reply, and Show thinking when the run above it has thinking that Settings keeps for On request (see Steps in a turn)); no more icons of their own under messages (2026-10-23, #1156; 2026-10-25, #1243).
- Pin lives in the long-press and selection menus, not the row: Pin for a passage, Pin reply for the whole reply (2026-10-20, #982 and #1097; 2026-10-23, #1156).
- A branch opens by the stored id `session.create` names, and by its runtime id only when Hermes names none: Hermes' `session.resume` finds sessions only by stored id or title, so the runtime id is "session not found" (2026-10-27, issue 1400, #1402).
- Your own message's row is Copy and ⋯ (Quote, Edit and resend). Quote puts its words in the draft as a `>` quote, as a selection's Quote does (2026-10-28, issue 1420, #1446).
- Edit and resend takes back the message and everything after it through Hermes' rewind, as /undo does, and puts its words back ahead of whatever is typed in that chat's draft (even when another chat opened meanwhile), a quoted reply as its "Replying to" chip. When the composer already holds a different chip, the restored one comes back as a `>` quote, for a send that didn't go too; it asks first when later messages would go, and takes nothing back when Hermes' history holds later messages it didn't ask about (sent from another device), loading them so the next try asks. /undo and /retry keep their words in their chat's draft too when another chat opened while they ran. Not offered for a message with pictures, files or a recording, which can't come back as they were. There is no edit in place: the model already answered the original (2026-10-28, issue 1420, #1446).
- Retry is on the newest reply only while it answers the last message sent (a message after it, stopped or unanswered, is what /retry would resend), runs /retry, and asks first when the newest turn ran steps, since retrying runs them again (2026-10-28, issue 1420, #1446).
- Tapping a "Replying to" card scrolls to the reply it quoted, in a chat and in a group room (a member's message), found by its words since the envelope carries no id; one not in the loaded transcript says so. A waiting message's card, and a room's message still sending, looks through the whole transcript, since it comes last. Desktop groups, read-only, and the saved copy, whose rows stand in until Hermes sends the chat's (so Edit and resend and Retry are off there), keep a card that doesn't jump (2026-10-28, issue 1420, #1446; the copy drawn as the chat's own rows since 2026-10-30, #1550).
- Double-tap and long-press on text stay text selection; reactions come from React or a reaction chip (2026-10-07, #437).
- Read Aloud has no estimated follow-along highlight; only exact word timings from Hermes would bring it back (2026-10-19, #923).
- A quoted reply travels in the message text, since Hermes has no field for hidden context (2026-10-04, #387).
- Deleting a bot drops its Bot Chat pins under every profile, not only the one in use (#982 follow-up, #1191).
- The Pinned replies sheet opened from a chat starts on This chat, with All chats a tap away and that chat's section first; the filter shows while this chat and another both have pins, and once shown stays until the sheet closes, so unpinning this chat's last pin leaves This chat empty. Opened from the Chats list it lists every chat by latest pin (2026-10-25, issue 1267, #1269).

**Open gaps**
- Group rooms still show Copy, Quote and Read aloud as three icons, with no React and no ⋯ (#1156). Edit and resend and Retry are not needed there: a room is shared and has no rewind.

**Checked:** 2026-10-31, #1590 (a group room's jump goes through its own TranscriptScroller too, the quoted message at the top with the room browsing there, without the animation the room's stack gave it; Code); 2026-10-31, #1577 (the jump goes through TranscriptScroller now that chats draw on the transcript; Code); 2026-10-31, #1566 (the jump's rule in TranscriptScroller, not called yet; Code); 2026-10-31, #1565 (the reply offering Retry, and the latest one reactions go to, are worked out once per change of the rows drawn; Code); 2026-10-31, #1552 (a deleted bot's kept settings answers go with its pins and held rows; pins unchanged); 2026-10-30, #1550 (the saved copy's rows are drawn by the chat's own row view while they stand in; their cards still don't jump and Hermes' actions stay off); 2026-10-30, #1524 (Read Aloud says a Desktop card's note, and a quote chip names one); 2026-10-28, #1446 (your own message's ⋯ with Quote and Edit and resend, Retry in the newest reply's ⋯, the "Replying to" card's jump in chats and group rooms, ComposerDraft.restoring keeps a second chip as a quote for failed sends too, the saved copy's cards don't jump, /undo and /retry words kept when the chat changes; selection and long-press menus unchanged); 2026-10-27, #1402 (Branch opens the new chat by its stored id; the row, menus and pins needed no change); 2026-10-26, #1311 (a drawn reply's text view is laid out as it mounts; selection and long-press menus unchanged); #1282 (carrying the ⋯'s Show thinking from #1243); the pinned replies sheet's This chat / All chats filter at #1269; 2026-10-24, pins at 78f21daa plus the #982 follow-ups; a deleted bot's pins at #1191.

## Conduit plugin update

Updating (or installing) the Conduit plugin on the dashboard's host from
Conduit, and telling the user when it's done.

**Siblings:** the update notice over the main screen · Settings > Conduit
plugin (same status rows, Update and Cancel) · the Settings and Chats notice
that opens it · Settings > Notifications' Compatibility links to the plugin
page (host and pairing rows) · Finish setting up's plugin row · Settings > Conduit plugin >
Update notices, which decides when all three ask · the host-run update on the
notifier (`/self/update`) and its push when it ends · the phone-run steps for
a plugin without it · every profile that turns the plugin on, which the dashboard links to the main install (`notifier/profile_copies.py`) · Pulse's loop, which runs in the dashboard (`notifier/pulse.py`, its lease in `notifier/pulse_store.py`) · the plugin's CHANGELOG.md (What's New) · what the
confirmation and README say about restarts

**Code**
- Updater and state: `Conduit/Services/NotifierPluginUpdate.swift` (NotifierPluginUpdater, NotifierPluginUpdateSlot), `Conduit/Services/AppState+NotifierPluginUpdate.swift` (the run, reconnecting after it, settled outcomes)
- Status and offer: `Conduit/Services/NotifierPluginStatus.swift` (updateAvailable, updateRecommended, noticeVersion, noticeDismissalVersion, noticeOffer), `Conduit/Services/NotifierPluginLatestVersion.swift`, `Conduit/Services/NotifierPluginNoticeChannel.swift`, `Conduit/Services/NotifierPluginChangelog.swift`, `Conduit/Services/AppState.swift` (notifierPluginNoticeChannel, setNotifierPluginNoticeChannel, applyNotifierPluginNoticeChannel, dismissedPluginUpdates), `Conduit/Services/AppState+FinishSetup.swift` (FinishSetupStatus.plugin, pluginDoneNote)
- Views: `Conduit/Views/ConduitPluginViews.swift` (NotifierPluginUpdateBanner, NotifierPluginUpdateStatusView, ConduitPluginSettingsDetail), `Conduit/Views/AuxiliaryViews.swift` (NotifierPluginUpdateNotice; Settings > Notifications' Compatibility links read `needsAttention`), `Conduit/Views/V2/V2FinishSetupCard.swift`
- Gateway restart it reuses: `Conduit/Services/GatewayRestart.swift`
- Notifier: `notifier/dashboard/api/self_update.py` (/self/update, /self/restart, finish_self_update_after_restart, _point_profiles), `notifier/profile_copies.py` (every profile on the main install, also run from `notifier/__init__.py` register), `notifier/dashboard/api/capabilities.py` (/capabilities), `notifier/CHANGELOG.md`, `notifier/channels.yaml`
- Tests: `ConduitTests/GatewayRestartTests+PluginUpdate.swift`, `notifier/tests/test_self_update.py`, `notifier/tests/test_install_scan.py`, `notifier/upstream/test_install_scan.py` (Hermes' own scanner over the shipped files, on every notifier PR)

**Rulings**
- No automatic updates: restarts are the user's call; the notice offers each version once (Never offers none, below), and Update runs the whole update (2026-10-13, #582, Eric).
- App Store builds are asked only below the stable floor, TestFlight and Xcode builds for every version on notifier main (2026-10-20, #984; 2026-10-23, #1166, Eric). Superseded: Automatic is gone, and Stable versions only is the default for every build, Automatic's users included, so TestFlight and Xcode builds ask for the stable version too unless the user picks Every new version. Conduit no longer reads where it was installed from. A plugin release a build needs between App Store builds gets there by raising channels.yaml's `stable:` (2026-10-30, #1529, Eric: too many plugin updates).
- The notice stays until the update truly ends: after the host is done, it shows Reconnecting until Conduit is back, has read the new plugin and the gateway serves, and only then says the plugin is ready. A failure the plugin's report contradicts (the new version runs) reads as ready, not as a silent close (2026-10-24, Eric's report on build 228).
- A gateway restart that takes the dashboard down with it (a service manager restarting both) still finishes the host job: the restarted dashboard marks it done when it loaded the new version (2026-10-24, notifier 0.69.1).
- Every process the update restarts runs the new code at once, Pulse's loop included: a dashboard restarted by its service manager (a new pid) takes Pulse over from the old one without waiting out its lease (2026-10-26, notifier #392, Eric's report on 0.81.1).
- The notice's What's New opens the notes in a sheet, presented by the notes it shows (a sheet item, not a flag); Settings shows the same notes inline in a disclosure (2026-10-25, Eric's report of a blank sheet, #1227).
- Update notices has a Never choice: the notice, the Settings card and Finish setting up never ask for an update (a newer version, a missing feature, a plugin below this build's floor), only for the restart of an update already on the host. A missing plugin is still offered for install: installing isn't updating. Settings > Notifications' Compatibility host link follows the same `needsAttention`, so under Never it points at the plugin page only for an install, a restart or a plugin that isn't running; its pairing-row link for an outdated pairing still shows, being on a Settings page rather than a prompt. Settings > Conduit plugin still lists missing features and offers the update whatever the choice (`updateAvailable` ignores it); Finish setting up shows done, saying a newer version or the missing features wait in Settings. "Not now" on a restart (under any choice) belongs to the version on disk, so the next update's restart asks again, and a "Not now" prunes only its own dashboard's older ones. It began as malaiwah's "Only when needed" (#1521), tied to `recommendedVersion`; that hand-set floor (0.48.0) sits below the stable one, so Eric made it plain Never (2026-10-30, #1529; Michel's first-time walkthrough found the same update asked for in four places).
- Every file the plugin ships passes Hermes' install scan, which reads the whole checkout (the contract tests and the relay included) and refuses a dangerous verdict even with --force: no literal that looks like a token outside test folders (2026-10-27, notifier #418, Eric's host stuck on 0.84.1).
- An update reaches every profile that turns the plugin on. Hermes loads a profile's chat-turn plugins from its own plugins/ folder only (its dashboard falls back to the main home's), so the dashboard links each such profile's plugins/conduit_push to the main install when it starts, before an update restarts the gateway, and when the main copy loads. A copy the profile had of its own (a clone's) moves to its plugins-backup/, never deleted. Where no link can be made, the main install is copied in, marked as ours and replaced when it falls behind. A profile counts when its config lists the plugin in plugins.enabled, or has no plugins.enabled list (Hermes then loads what's installed) and holds a copy already. A profile whose allow-list leaves the plugin out or disables it, whose config can't be read, or whose own copy is newer than the main install (a build put there on purpose) is left alone. This isn't an automatic update: it runs what the user already updated to (2026-10-31, notifier #482, issue #1538: Eric's Nahida, Raiden and Zhongli ran 0.1.0 from July, so their pushes had no chat title and opened nothing).
- No high finding either: one makes the verdict caution, which the one-tap update can't confirm, so it holds every host on the old version just as surely. The notifier's upstream contract runs Hermes' own scanner on every PR and fails on a high or critical finding; README examples write a secret as a placeholder (`<token>`), never as a shell variable (2026-10-29, notifier #467, issue #1500: the crash report curl examples held hosts on 0.119.x).

**Open gaps**
- Hermes Desktop's own serve process on the host keeps the old plugin until Desktop restarts; nothing tells the user.
- A dashboard without a fixed basic-auth secret signs Conduit out at every restart; the updater signs in again, but the chat may land on the sign-in screen.

**Checked:** 2026-10-31, #1557 with notifier #482 (issue #1538): a profile's turns load only its own plugins folder, so the dashboard links every profile that turns the plugin on to the main install; the app's update path, notice and version check needed no change, as they read the main install every profile now runs; 2026-10-30, #1529 (carrying #1521): the in-chat notice, the Settings card and Finish setting up all read `updateRecommended`, so the choice reaches each, from launch; Settings' Update reads `updateAvailable`, which it leaves alone; under Never, Finish setting up still offers the update for a plugin older than 0.4, which can't report anything, as the setup step it is; the confirmation, README, CHANGELOG.md and the notifier needed no change (the update itself is unchanged); 2026-10-29, #1501 with notifier #467: Hermes' scan held the update at caution over two README curl examples (issue #1500); the app's update path and its error text needed no change; 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-27, at #1350 with notifier #418: Hermes' install scan refused 0.95.0 over upstream/conftest.py's token; the app's update path needed no change; 2026-10-26, at #1293 with notifier #392: the dashboard restart itself needed no change (systemd restarts it with the gateway, elsewhere the update re-execs it); 2026-10-25, Qwen Live's feature row and the qwen-live capability in the update nudge, at #1182, carried in #1235; at #1230 (the phone-run install and update requests wait in the profile config queue, the host-run update doesn't); at #1222; at #1227: the notice's What's New sheet opened blank; Settings' disclosure and the notifier's CHANGELOG.md needed no change.

## Notifications

What a push says, in which language, where tapping it goes, and when it
stays quiet.

**Siblings:** reply (and the notification Hermes writes for it, `conduit_notify`, with its Chat activity row; a fork of the chat sends none: Predictions, step summaries' /btw, the self-improvement review) · approval · question · failed turn · tasks and cron ·
phone changes · missed call · Pulse (pulse.noticed, pulse.brief, pulse.followup, each with
how much it may interrupt, and private ones; see Pulse) ·
room invites (room.invite; app side on the `linked-rooms` branch only, see Linked Rooms) ·
the Watch (mirrors the iPhone) · Bot Chat ·
the Live Activity's who-line (names a Bot Chat's bot, `Conduit/Services/AppState.swift` turnStarted call) ·
the notification service extension · the relay's plain copy and a push's interruption level ·
Settings > Notifications (Show in notifications: Generic, Chat names, Full previews) · end-to-end encryption (keys, rotation, the
padlock or shield in Settings > Notifications, on the dashboard rows of
Saved Dashboards and the Profiles sheet, and in the Watch's Settings) · the privacy policy (notifier
docs/privacy: what the relay gets for each kind, and what end-to-end encryption seals)

**Code**
- Extension: `ConduitNotificationService/NotificationService.swift`, `ConduitNotificationService/NotificationLocalization.swift` (a private Pulse push's line in the App Language, see Pulse)
- Shared copy: `Shared/Notifications/NotificationCopy.swift`, `Shared/NotificationE2E.swift`
- Inline key rotation: `Conduit/Services/NotificationKeyRotation.swift` (the exchange), `Conduit/Services/PushNotificationService.swift` (provisionEncryption, rotateInline, finishInlineRotation: when to rotate, resends and pending rotations)
- App: `Conduit/Services/PushNotificationService.swift` (NotificationDetail and the preferences' `detail`, mirrored to the extension; the relay registration and its updates; a tap's retries, its wait for a call, and the waiting tap kept across a relaunch), `Conduit/ConduitApp.swift` (the route that opens a tap), `Conduit/Services/AppState.swift` (openNotificationTarget, routeBotOwnedNotification, showCallRefusal and clearCallRefusal, callWaitCanEnd), `Conduit/Views/RootView.swift` (callTopBanners: the notice over a call's screen), `Conduit/Services/ChatOnScreen.swift`, `Conduit/Services/AppState+ChatOnScreen.swift`, `Conduit/Services/CronNotifications.swift`, `Conduit/Services/ReplySourceNotifications.swift`
- Missed calls: `Conduit/Voice/HermesCalls.swift`
- The tool's row in a chat's activity: `Conduit/Views/ChatActivityRows.swift` (phoneTools)
- Categories: `Conduit/Services/NotificationCategories.swift` registers the call and Pulse categories together (each registration replaces the set; the call's category is still defined in HermesCalls.swift), and `Conduit/ConduitApp.swift` handles Pulse's Quiet for today (see Pulse)
- Settings: `Conduit/Views/AuxiliaryViews.swift` (notificationDetailPicker), `Conduit/Views/SavedDashboardsView.swift` (padlock on dashboard rows, also shown by `Conduit/Views/ProfilePickerSheet.swift`, which reuses `SavedDashboardRowLabel`; worked out by `AppState.notificationsEncryption(of:)` in `Conduit/Services/AppState.swift`)
- Watch padlock: `Conduit/Services/AppState+HermesCalls.swift` (shareWatchCallVoices), `Conduit/ConduitApp.swift` (the `.task`s that re-share the Watch context when the notifications state settles and when the active dashboard changes), `Shared/WatchVoice/WatchCallVoices.swift` (WatchPhoneContext.notificationsEncryption), `ConduitWatch/WatchHomeView.swift` (WatchSettingsView: the label and its footer say quantum-safe when the shield shows)
- Notifier: `notifier/forks.py` (a fork of a chat sends nothing as its turn), `notifier/events.py` (push_event, plain_text, media_free, sanitize_decision, sanitize_call, sanitize_room), `notifier/client.py` (enqueue, _drain_at_exit; relay_takes and RELAY_GATED, the events only a relay that lists them gets), `notifier/session_titles.py` (title, bot_name: a Bot Chat's bot name), `notifier/chat_on_screen.py`, `notifier/e2e.py`, `notifier/notify_tool.py` (conduit_notify: the headline a turn's reply push carries), `notifier/relay/src/apns.mjs`, `notifier/relay/src/server.mjs` (notificationFor, genericCopy, shouldDeliver; the gateway's GET /v1/meta; a push's interruption level and relevance score), `notifier/relay/src/store.mjs` (the preferences and their defaults), `notifier/pulse_push.py` (a Pulse push's level and whether it's private)
- Privacy policy: `notifier/docs/privacy/index.html` (what the relay gets for notification delivery, room invites among it, and what end-to-end encryption seals)

**Rulings**
- Notifications follow the App Language: the extension builds the words from the event's title_label and session_title (2026-10-23, #1158, notifier #326).
- Pushes are titled with the Hermes session title (2026-10-12, notifier #93 and #94).
- How much a push says is Settings > Notifications > Show in notifications: Generic (the default) says only what happened; Chat names adds the chat's title and the profile over the generic body, never Hermes' words, and never a host title Conduit didn't write from `title_label` (it may quote a tool's prompt); Full previews adds the host's text. With either of the last two the subtitle names the profile: its bot's name, else its id capitalized (Eric 2026-10-28, #1448), left out for an unnamed `default` profile and when the title already ends with it, ignoring case and surrounding spaces (#1425). A room invite has no chat, so Chat names keeps its generic title and body. The relay's plain copy follows the same levels (`show_chat_names`, relay 0.22; an older relay shows Chat names as Generic). Keeping them off the Lock Screen is iOS's own Show Previews, which the caption points to (2026-10-28, issue #1415, #1416, notifier #436).
- Hermes writes its own notification with `conduit_notify` (a title up to 60 characters, a body up to 300), and it has no push of its own: the turn's reply push carries it as a sealed `headline` instead of the reply's opening, so a turn still sends one push and a silent or muted reply sends none. Only Full previews shows it, as the title over its body, with the chat's title and the profile in the subtitle; Generic and Chat names show the reply's usual copy. A subagent can't write one, Pulse turns keep their own copy, and the relay's plain copy never gets it (redaction drops it). It belongs to the turn that wrote it: the turn's end drops it, so a turn that ends with no reply never lends it to the next (2026-10-28, Eric chose to build it, issue #1415, #1425, notifier #438).
- No push shows a host path: replies (Bot Chat and Pulse included), background tasks, failed turns, questions, approvals, calls, updates and phone changes show each MEDIA tag as 📎 and the file's name, or its type when the name is only a hash, in the plain and the sealed copy alike, and so do the answer card and the call screen that come with them; a reply's fenced code stays as written (2026-10-24, Eric's review, #1212, notifier #348).
- A reply's push stays quiet while its chat is on screen and in use (2026-10-22, #1132, notifier #301), and while a Predictive follow-up Hermes took in that chat runs, even with nobody touching the phone (2026-10-26, #1281); that includes replies to messages queued ahead of it while Conduit waits for its turn, through the fourth, which ends the wait, since the chat on screen shows them anyway (2026-10-26, Eric, #1290).
- Only a chat's own turns push. A fork of the chat, which Hermes runs under the chat's session id (Predictions' `/predict`, step summaries' /btw, the self-improvement review), sends no reply, failure, approval or question push, no alert call, and doesn't start, move or end the chat's Live Activity, even on a Hermes that runs plugin hooks for forks; its tool calls still meet the room rules and Pulse's gate (Hermes 0.21 among them; Hermes' own 2026-09-10 fix keeps them out on newer ones). The plugin marks each fork's run and treats it as a subagent's run (2026-10-29, Michel, #1495 carrying #1489, notifier #464 carrying #462).
- A Pulse morning brief's push says only the brief's first line, cut to 200 characters; the lines under it are for its card (2026-10-25, notifier #357).
- Each Pulse push says how much it may interrupt, decided in code, never by the model. Time-sensitive: a pick held for a place at its moment, a reminder for a place as the user gets there or leaves, the same for a kind of shop walking past comes near (2026-10-28, notifier #435), and a follow-up that can't wait (its check said it's urgent, or it went at night or in a closed part of the day because later would be no use), at most three a day in the user's time zone, then active. Passive (Notification Center, with no sound or lit screen): anything else that goes while the phone says the user is busy (an event, or a Focus that holds calls; driving doesn't count), and a report whose pushed picks are all interests or far off. Active: the rest, the morning brief included. The reply carries `level` beside the envelope as routing, so the relay sees it with encryption on and `redact on` keeps it; the relay (0.20, `push-levels`) sets the alert's interruption level and relevance score (0.2, 0.5, 0.9), and an older relay sends it at the default level, as every other push goes. A build without the Time Sensitive Notifications entitlement gets a time-sensitive push as active (2026-10-27, Eric chose to build the gaps in order; notifier #424, #1379).
- A Pulse push about someone's birthday or anniversary, or whose words are about a gift, a surprise, health or money, says only "Pulse has something for you." while Hide private reminders on the Lock Screen is on (the default), whatever Show in notifications says: its words never leave the host in a push, the sealed payload says `private` for the extension to write that line in the App Language, and its card shows everything. A pairing with no key gets the line in English (2026-10-27, notifier #424, #1379).
- A push from a Bot Chat opens the Bot Chat (2026-10-16, #654), and a call from one opens the bot (2026-10-16, #630).
- A push from a Bot Chat names its bot as the Bots list does: its Bot Mode title, else its display name, else its profile id capitalized (Eric 2026-10-28, #1448, notifier #445), never "default" for a named bot. Every push carries that name as `profile_name` (sealed with the content), which calls and the relay's plain copy use (2026-10-25, Eric's report, #1257, notifier #372).
- Notification status in Settings is for the active dashboard only (2026-10-05, #395).
- A notification from another workspace or profile, tapped during a call, doesn't switch to it: the switch would end the call, so the tap waits and opens once the call has ended and Conduit is on screen, however long the call lasts, and a notice over the screen says so, over a call's own screen too (with V2 off the drawer shell has no notice and keeps its error line, as before, which shows nothing during a call and drops it once the call ends or a newer tap replaces the waiting one). A newer tap replaces it. If Conduit closes meanwhile (which ends a call on the phone), the tap waits again at the next launch, unless it's over two hours old. A chat link, or a widget's or Shortcut's launch for another workspace, says to end the call first instead, in the same notice, since either can be tapped again and a tapped notification is gone. A call from Hermes opening its own chat (answered, or its notification tapped, a missed call's included) still switches, since talking to Hermes leaves the other call. Every call counts: on screen or minimised, Classic voice, CarPlay, the Watch and a call from Hermes (2026-10-26, #1297; found in #1286's review, where only chat links refused; waiting for the call, the notice and the relaunch came from #1297's reviews).
- Encryption keys rotate: every 7 days (30 before inline rotation), on Settings > Notifications > Rotate, or when the host asks (`hermes conduit-push e2e rotate`). The phone saves the new key before sending it, and both sides keep the replaced key 7 days for pushes and answers in flight. Rotation is per pairing and below every event kind, so reply, approval, question, failed turn, tasks and cron, phone changes, missed call, Pulse and Bot Chat pushes need no change. On the condition that nothing already working is disrupted: a pairing that never rotates (an older app or notifier) keeps sealing and opening pushes and answers with its one key, tested on both sides (2026-10-24, #1197 and notifier #344, Eric).
- The relay's plain copy is for pairings with no key. Rotation leaves it untouched: it neither reads nor changes the copy, and a pairing with no key never rotates (2026-10-24, #1197 and notifier #344, Eric).
- Keys rotate inline through a key exchange sealed with the current key (notifier 0.72+, `POST /e2e/rotate`): ML-KEM-768 with X25519 on iOS 26, X25519 alone below. A key handed over through the dashboard is replaced at once, and the next rotation after an update to iOS 26 is quantum-safe; the handover stays as the fallback when the chain breaks. Approved on the condition that iOS 17 to 25, older notifiers and the dashboard handover keep working as today (2026-10-24, #1213 and notifier #349, Eric).
- A quantum-safe pairing shows a shield (`lock.shield.fill`) instead of the padlock, in Settings > Notifications, on dashboard rows, and in the Watch's Settings for the iPhone's active dashboard. Approved on the condition that iOS 17 to 25, older notifiers and the dashboard handover keep working as today (2026-10-24, #1213 and notifier #349, Eric).
- The padlock is closed only when the host confirmed it seals with the key this iPhone holds, and that key isn't past 7 days plus the 7-day overlap. A host whose notifier can't rotate (before 0.71) keeps a closed padlock at any key age, with a caption asking for an update, since nothing on the phone could rotate it. A host that can't rotate is never shown as broken, so pairing with an older notifier is not disrupted (2026-10-24, #1197 and notifier #344, Eric).
- A cron job's push goes out though its worker process exits right after the turn: the host's exit waits for queued pushes, up to 3 seconds (after up to 10 for a call request still retrying, whose fallback is one of them) (2026-10-26, notifier #389, issue #388).
- A room invite is a push of its own (room.invite), which the relay sends only to a phone whose Conduit turned its `room_invite` preference on: off until then, and for preferences stored before it, since an app that doesn't know the type shows it as a reply ("Response ready", its generic copy for a type it doesn't know). A relay from before 0.21 refuses the type, so the plugin sends one only to a relay whose GET /v1/meta lists `room-invites`, read with the pairing's credential and held an hour. End-to-end encryption seals the room, its ids included, with the rest; with previews off the relay's copy ("Room invite", "Someone you've linked with invited you to a room.") leaves out the room's name and who it's from and keeps the Link's and room's ids to route the tap, as redaction does. It waits on the user, so it chimes with the attention sound (2026-10-27, #1381, notifier #425).
- Your agents' turns in a room someone else hosts send no reply or failure push and no automatic alert call: the room shows them, on its home's side, and the hidden chat each runs in (`Group: <room id>`) isn't one Conduit opens. Their approvals and questions still notify (2026-10-27, #1381, notifier #425; the gap #1351 recorded).

**Open gaps**
- Rotation narrows what a leaked key opens, but a key copied while in use still opens the pushes captured with it; there is no per-message ratchet.
- Still English: the relay's plain copy (pairings with no key), the redacted decision text, and a clarify body with no arguments (#1158).
- A private Pulse push is found by English words only: a gift, a surprise, health or money said in another language shows its words. Birthdays and anniversaries are found from what Pulse remembers, in any language (notifier #424).
- Conduit doesn't have the Time Sensitive Notifications entitlement yet, so a time-sensitive Pulse push arrives as active. It waits for the capability on the app's identifier and a regenerated Hermes Conduit App Store profile, since signing is manual (#1379).
- "Notify me when" choices are one set per iPhone, not per dashboard: the relay keeps one set per installation (#395).
- A registration update landing after a relay move is dropped rather than written onto the new registration (#865 follow-up, #1191); the move itself has no test seam (it registers through URLSession.shared).
- No app on main turns `room_invite` on, so room invites reach no phone yet: on the `linked-rooms` branch, C3c turns it on, with the invite push's copy in the App Language, its tap to the join card and Settings > Notifications' Room invites (see Linked Rooms).

**Checked:** 2026-10-30, #1542 (All history stays after the host's 2000 limit and stops at the oldest reading; the stores needed no change); 2026-10-29, #1517 (the `pulse` branch merged into main: the app paths it lists are on main now; nothing else changed); 2026-10-29, #1495, carrying #1489 (a chat's forks send no push, notifier #464 carrying #462; the extension, the relay, encryption and Settings needed no change); 2026-10-28, #1457 (the main bot's pushes take its Conduit name, see Profile names); 2026-10-28, #1448 (an unnamed profile's id capitalized in the subtitle and in Bot Chat pushes, notifier #445); #1427 (a pick or reminder for a kind of shop walking past comes near pushes time-sensitive as a place's does, notifier #435); #1425 (the notification Hermes writes with `conduit_notify`, notifier #438, closing issue #1415's last gap; the relay, calls and encryption needed no change); #1416 (Show in notifications with Chat names and the profile subtitle, issue #1415, with notifier #436 for the relay's plain copy; the Watch mirrors it, and calls, encryption and decision cards needed no change); 2026-10-27, at #1383, carrying #1379 from the `pulse` branch (a Pulse push's level and private ones, with notifier #424: the extension's private line in the App Language; other pushes, the relay's plain copy, encryption and Settings > Notifications needed no change); #1381 with notifier #425 (room invite pushes, which the relay sends only to a Conduit that turns them on, and no reply or failure push for your agents' turns in rooms hosted elsewhere; the app's side waits for C3c on the `linked-rooms` branch); 2026-10-26, #1297 (a notification tapped during a call no longer switches and opens once the call ends, the gap #1292 recorded, kept across a relaunch, with a notice over the call's screen too, and so does one whose Bot Mode check fails during the call; the extension, the relay's copy, encryption and Settings needed no change); #1290 (the hold covers replies queued ahead of a follow-up); #1291 (queued pushes go out before a cron job's worker exits, notifier #389, issue #388); #1292 (Pulse pushes' Quiet for today button, from #1285 on the `pulse` branch, and a push tapped during a call, found in #1286's review; see Pulse); #1281 (a Predictive follow-up holds its chat's push); 2026-10-25, #1257 (a Bot Chat's push names its bot; `profile_name` for calls, the relay's plain copy and the Live Activity; notifier #372); the morning brief's push at notifier #357, carried in #1237; 2026-10-24, at #1213 (inline rotation, the shield and the Watch's row and footer; a pairing rotates at most once per run, a Rotate tap during a rotation joins it, and a verified key the Keychain refused stays pending and is shown as such; fork CI #85); #1212 (MEDIA tags in pushes, answer cards and the call screen); keys and padlock at #1197, carried in #1217 (fork CI #82); the registration update race at #1191; its relay registration error log redacted (bare hosts) at #1219.

## Pulse

Hermes speaking up on its own: the report a few times a day, the morning
brief, the daily look two weeks ahead and follow-ups, each landing as cards
on the Pulse screen, with what Pulse remembers from the chats (birthdays and
anniversaries every year among it) and the deadlines it finds in the
Shortcuts inbox, and what it learns from what the user does with its cards.
Before it writes it can look things up, and an event or reminder worth
adding comes as a suggestion the user adds with a tap. After something gets
done or an event ends it can bring up what comes next, and a card whose Do
it stalled comes back once. Once the user turns
it on, it knows where they are (see Where you are, for Pulse), and each push
says how much it may interrupt (see Notifications). It's a beta, on main and in
every build, App Store ones included.

**Siblings:** the Pulse screen (cards and their Why?, what Pulse looked at first among it, next steps and cards back after a Do it that stalled, with Why? saying when Do it was tapped, suggestion cards with Add, Not now and Undo, the morning brief's block and its fold, New and Earlier, thumbs
and the one-tap reason, Wrong time among them, Not now until later today, tomorrow or next week, Done and
Undo, Do it, Quiet for today and the quiet banner) · What Pulse learned (the
loudest each kind gets, what learning holds with Reset and Start over, the lessons
reasons and resets made, Undo) · What Pulse left out (the reports' and the look ahead's, and Bring it up) · Settings > Pulse (on and
off, model, nudge, budgets, home chat, the note to Pulse, quiet times and the night, deadlines from Shortcuts, Look things up first, Where you are and Walking past under it, Hide private reminders on the Lock Screen) · What
Pulse remembers (each kind, a yearly fact's day, where a deadline from the Shortcuts inbox came from, and the place a promise waits for) · Pulse
pushes (kinds pulse.noticed, pulse.brief and pulse.followup, titled per the
Notifications rulings, opening the Pulse screen, with Quiet for today, how much each may interrupt, and private ones) · the Watch (Pulse pushes there,
Quiet for today's button and a private push's line included; unchecked, see Open gaps) · a call from Hermes (Pulse may call only
once the user opts in) · the hidden Pulse chat · the notifier's loop (report, brief, the look ahead,
follow-ups, memory), its routes under /pulse and its capabilities · the Shortcuts inbox
(the report and the morning brief read it, and with Pulse memory on, new
events bring watches' checks forward and memory keeps the deadlines in them;
deleting events in Settings > Shortcuts inbox deletes those, and its page
says so) · the phone's calendar and reminders
(the report, the morning brief and the look ahead read them, the candidate list the events that ended since the last report, Pulse's turns look them up, a suggestion's Add and
Undo ask the phone for a change that the app that tapped applies without the phone's own card, and a push waits
while an event is on) · the people
picked in Settings > Calendar & phone > People (the look ahead brings up their birthdays, and People's caption says
so with a plugin that does) · the phone's status
and Focus (a push waits while it's driving or a Focus holds Hermes's calls, and Pulse's turns look up the status,
the contacts and the alarms) · Maps (Pulse's turns look up places they name, and from where the user is or a saved
place only with Where you are on) · where the user is (see Where you are, for Pulse) · web search (a follow-up about something said in a chat) · Phone change errors (the calendar and phone
tools' `pulse_turn` refusal, and what a suggestion's refusals say) · Phone data sync with the host (a change
approved on a card; past events within the window shared, read on the host for next steps) · Hermes's scheduled jobs and
its notes (the report reads them, with each job's health) · a new chat Do it starts, for an item from
no chat or from a Kanban task's worker · the Kanban task such a card links, opened in Tasks › Board · the `hermes conduit-push pulse` commands

**Code**
- App: `Conduit/Views/V2/V2PulsePage.swift` (the screen, the morning brief's block, What Pulse learned, What Pulse left out, suggestion cards with Add, Not now, Undo and its question), `Conduit/Views/V2/V2ChatsView.swift` (V2PulseButton in the Chats bar, Pulse's chat left out of the list and content search), `Conduit/Views/V2/V2VoiceButton.swift` (Pulse's chat left out of voice recents), `Conduit/Views/PhoneSettingsViews.swift` (People's caption on birthdays, with a plugin that reports `pulse_dates`), `Conduit/Views/V2/V2Shell.swift` (the `.pulse` route, full screen on a phone), `Conduit/Services/PulseFeed.swift` (cards, marks, ratings, which cards take Done and Do it and which ask why on a thumbs down, Do it's message per topic, a deadline's and a next step's among them, the brief's layout, which chat is Pulse's, what Pulse learned and left out, what a card's Why? says learning did, what Pulse looked at and when a card back after a stalled Do it had Do it tapped, and a suggestion's states and its Add, Not now and Undo calls), `Conduit/Services/AppState+Pulse.swift` and `Conduit/Services/AppState.swift` (opensPulseScreen, for pushes; pulseRememberedHomes, Pulse's chat per dashboard across launches; pulseFoldedBriefs, the briefs folded per dashboard across launches, the newest 30 of each and the one just folded; unfoldPulseCard, a card put back open in a folded brief; startPulseNewChat, the new chat Do it fills; quietPulseForToday, Quiet for today from a notification, which a call keeps from switching dashboards and which keeps the state Pulse answers with for Settings > Pulse), `Conduit/Services/PulseSettings.swift` and `Conduit/Views/PulseSettingsViews.swift` (Settings > Pulse, quiet times, deadlines from Shortcuts, Look things up first, Where you are and Walking past, Hide private reminders on the Lock Screen, What Pulse remembers, a yearly fact's day, where a deadline came from and the place a promise waits for, and what a suggestion's refusals say), `Conduit/Services/AppState+PhoneSync.swift` (applyPulseApproval) and `Conduit/Phone/PhoneSyncEngine.swift` (approveFromCard: a change approved on a card, applied without the phone's own card), `Conduit/Views/ShortcutInboxSettingsViews.swift` (Settings > Shortcuts inbox's caption and delete-all message on Pulse's deadlines, with a plugin that reports `pulse_inbox`), `Shared/Notifications/PulseNotifications.swift` and `ConduitNotificationService/NotificationService.swift` (which Pulse pushes get Quiet for today), `Shared/Notifications/NotificationCopy.swift` (a private push's line, in the App Language), `Shared/NotificationE2E.swift` (pulseQuietGateways, the hosts whose pushes offer it, shared with the extension), `Conduit/Services/NotificationCategories.swift` and `Conduit/ConduitApp.swift` (its button, done in the background, and the retry), `Conduit/Services/PushNotificationService.swift` (pulseQuietTarget, the push's dashboard and gateway, checked again on the tap; pulseQuietAwaitsCall and takePendingPulseQuiet, the retry's wait for a call, kept across a relaunch on the day it was pressed); a card from a Kanban task's worker: `Conduit/Services/PulseFeed.swift` (kanbanTask, its Do it message, pulseCardHasChat, pulseCardTask, openPulseCardTask), `Conduit/Views/V2/V2PulsePage.swift` (sourceLink, taskLink), `Conduit/Services/AppState.swift` (kanbanTaskOpenRequest), `Conduit/Views/V2/V2Shell.swift` and `Conduit/Views/V2/V2TasksView.swift` (Tasks › Board for it), `Conduit/Views/KanbanViews.swift` (openRequestedTask) and `Conduit/Services/KanbanStore.swift` (findTask, on whichever board holds it)
- Loop: `notifier/pulse.py` (the tick, the report's candidate run, cards from turns, push copy, the model Pulse's calls outside its chat run on), `notifier/pulse_delivery.py`, `notifier/pulse_host.py`, `notifier/pulse_hermes.py`, `notifier/chat_takeover.py`
- Report: `notifier/pulse_report.py` (what it reads, the note to Pulse), `notifier/pulse_candidates.py` (the candidate list, which reads the note too, the router and the 30-day journal, which What Pulse left out lists)
- Memory, follow-ups and the brief: `notifier/pulse_memory.py`, `notifier/pulse_followup.py` (its checks read the note to Pulse), `notifier/pulse_brief.py` (what the brief reads: held cards, open items, the phone, the inbox, the note to Pulse, and what Pulse remembers related to today's events, from `today_related` in `notifier/pulse_places.py`)
- Quiet times: `notifier/pulse_quiet.py` (whether Pulse is quiet now, and until when); the tick's gates in `notifier/pulse.py`
- The right time: `notifier/pulse_hours.py` (the night, the parts of the day, when news is useful, and whether the user is busy); follow-ups' holds in `notifier/pulse_followup.py`, the report's caps in `notifier/pulse_candidates.py`, and the events on now in `notifier/phone_store.py`
- What happened since an item came up: `notifier/pulse_evidence.py` (later chats and cron runs, background processes); follow-up, held-reminder, brief-card, found-card and Do it checks read it with the item's chat in `notifier/pulse_followup.py`, its continuation through `notifier/pulse_hermes.py` (`chain_messages`), the phone's calendar and reminders and the report in `notifier/pulse_report.py`
- Yearly dates and the look ahead: `notifier/pulse_dates.py` (the dates that come back every year, from the picked people's birthdays in `notifier/phone_store.py` and memory's yearly facts, and their lead times), `notifier/pulse_ahead.py` (once a day before the brief: what it reads, its candidates, decided by `notifier/pulse_candidates.py`, and its cards, held for the brief); its run in `notifier/pulse.py`'s memory run, journaled by `notifier/pulse_store.py` (`add_run`, `journaled_refs`, `release_held`)
- Deadlines from the Shortcuts inbox: `notifier/pulse_memory.py` (`read_inbox`, its instructions and checks, after the chats in `notifier/pulse.py`'s memory run; `forget_inbox` in the tick, `forget_deleted` and `stop_inbox`), `notifier/inbox_store.py` (`received`, `present`), `notifier/pulse_store.py` (`keep_inbox`, which moves the inbox mark in the same write), their lead times in `notifier/pulse_dates.py` and their section and cards in `notifier/pulse_ahead.py`, their level in `notifier/pulse_learning.py`, and the inbox routes that delete theirs in `notifier/dashboard/api/phone_data.py`
- What got done elsewhere: memory's close marks the thing's cards in `notifier/pulse_store.py` (`advance`, `found_cards`, `unmark_done`'s `put_back_at`, which keeps the checks off a card put back, and `end_rest`, which ends a done card's rest at its time without bringing it back), reminded commitments and word endings in `notifier/pulse_memory.py`, and the found-card checks and `read_first` in `notifier/pulse_followup.py`
- Learning: `notifier/pulse_prefs.py` (what thumbs, Do it and Done teach, how loudly things come up, and what a reset forgets); reasons, lessons and levels: `notifier/pulse_learning.py`; outcomes: `notifier/pulse_ledger.py`; store, with the signals: `notifier/pulse_store.py`
- Looking first and suggestions: `notifier/pulse_tools.py` (what a Pulse turn may call, and its caps), `notifier/pulse.py` (`pre_tool_call`, default deny), `notifier/pulse_proposals.py` (a suggestion kept, its card, Add, Not now and Undo, and what the card says), `notifier/phone_tool.py` (`proposed_add`, and the `pulse_turn` refusal), `notifier/phone_store.py` (`check_change`, `change_outcome`, and `add_change`'s `ask` and `change_id`), `notifier/pulse_store.py` (the proposals table, `swap_proposal`)
- How a push goes: `notifier/pulse_push.py` (its level, at most three time-sensitive a day, and whether it's private), `notifier/pulse.py` (`push_copy`), `notifier/events.py` and `notifier/e2e.py` (`level` beside the envelope, `private` sealed), `notifier/relay/src/server.mjs` (the alert's `interruption-level` and `relevance-score`)
- Where the user is: see Where you are, for Pulse
- A card from a Kanban task's worker: `notifier/pulse_hermes.py` (`worker_tasks`: which chats are a worker, and the task its prompt names), `notifier/pulse_followup.py` (`worker_tasks` per profile, and the Do it check reading the new chat for one), `notifier/pulse_control.py` (`kanban_task` in `feed` and `bring_up`)
- Control: `notifier/pulse_control.py` (shared by the commands and the routes), `notifier/cli.py`, `notifier/dashboard/api/pulse.py` (/pulse)
- Tests: `notifier/tests/test_pulse.py` (with memory's closes), `notifier/tests/test_pulse_learning.py` (ratings, cards and the brief, and the checks that mark cards done), `notifier/tests/test_pulse_candidates.py`, `notifier/tests/test_pulse_prefs.py` (the learning), `notifier/tests/test_pulse_personas.py` (personas over two weeks, each against the same run without learning), `notifier/tests/test_pulse_hours.py` (the night, waiting while busy, when news is useful, Wrong time), `notifier/tests/test_pulse_dates.py` (the yearly dates, their lead times and the look ahead), `notifier/tests/test_pulse_inbox.py` (deadlines from the Shortcuts inbox: what's kept, when they come up, and how they're forgotten), `notifier/tests/test_pulse_tools.py` (what a Pulse turn may look up), `notifier/tests/test_pulse_proposals.py` (suggestions: kept, carded, added once, followed and undone), `notifier/tests/test_pulse_push.py` (a push's level and private pushes), `notifier/tests/test_pulse_places.py` (the brief's items related to today's events, with Where you are's tests); the app's `ConduitTests/PulseFeedTests.swift` (cards and their Why?, the brief's fold, What Pulse learned, What Pulse left out and what the look ahead left out, People's caption, Wrong time, Not now's choices at night, a card marked done while it's put off, a deadline's card and the Shortcuts inbox page's caption, what Pulse looked at, suggestion cards and their states, a next step's card, and a card back after a stalled Do it), `ConduitTests/PulseSettingsTests.swift` (Settings > Pulse, quiet times, the night, deadlines from Shortcuts, Look things up first, Where you are, Hide private reminders, a yearly fact's day, where a deadline came from and a promise's place in What Pulse remembers, and a suggestion's refusals), `ConduitTests/PhoneSyncTests.swift` (a change approved on a card), `ConduitTests/NotificationCopyTests.swift` (which Pulse pushes offer Quiet for today, and a private push's line) and `ConduitTests/NotificationDashboardOwnershipTests.swift` (which dashboard Quiet for today acts on)

**Rulings**
- The app side is on main and shows in every build, App Store ones included, wherever the plugin serves Pulse (Eric, 2026-10-29, #1517, which merged the `pulse` branch; until then it lived only on `pulse`, for internal testers, #1092). The notifier side is on its main, off by default (2026-10-21, notifier #275).
- No Pulse chat in sight: reports and the brief land as cards on the Pulse screen, and the home chat is hidden from Chats, search and voice recents (2026-10-22, #1116, notifier #291). The app remembers each dashboard's Pulse chat, so after a relaunch the Pulse button shows and the chat stays hidden at once; the remembered chat follows the feed, and goes when the feed names none, the plugin answers without Pulse or the dashboard is removed (2026-10-25, #1234, Eric's report: Pulse showed as a chat for a while after reopening).
- Pulse learns in code, not as a line in a prompt. Thumbs, Do it (opened, something sent, got done) and Done are signals it learns from slowly, older ones counting for less: which kinds, chats and timings are worth bringing up, and how loudly, a push acted on within the hour making its kind louder. The report's candidates and the follow-ups go by what it learned. Not now, and a card opened and left alone, teach nothing. A kind's level (push now, Pulse screen, brief, off) is the loudest it gets, as the user set it or "too often" did, and learning moves things only below it. A promise Hermes made that's overdue, and a commitment or asked reminder due within a day, come up whatever learning says, within that level. A thumbs-down asks one tap for why, on a report card too once the plugin reports `pulse_learns`, and the reason acts at once for the card's kind (a report card's topic), as What Pulse learned says. Two thumbs no longer step a kind along the ladder, and the steps they made before are retired once (2026-10-26, Eric asked for the five improvements; notifier #385, #1286; before, thumbs moved a kind along the ladder, 2026-10-22, notifier #284). Each report item is its own card with its own thumbs (2026-10-23, notifier #330).
- A report that finds nothing leaves no card (2026-10-23, notifier #324).
- The morning brief comes every day at its time (07:00 by default, an hour before the first report) and sums up what's still open: what's due or on the calendar today, open promises and things the user said they'd do, and what the phone's automations logged. Held news still comes as its own cards under it, and a brief that brought none shows as its summary block. Read, it folds from its header to one row saying when it came and what's left in it, and stays folded on that phone, across launches, until it's opened again; one whose cards are all handled folds by itself. A Pulse mark pointing into a folded brief opens it, and so does a card in it that comes back open, from Not now or with Undo; a Pulse push opens the screen at its top, where a new brief shows open until it's folded (2026-10-26, Eric asked for a way to fold the brief once it's been read; #1306). Each morning's brief replaces the one before: an older brief goes to Done with what it brought that's handled, and its cards still open stay on the screen as cards of their own; an older brief a Pulse mark points into, at it or one of its cards, shows whole (2026-10-29, Eric's report: new briefs stacked on the old ones; #1482). The next report leaves out what the brief already brought up, unless something about it changed. Settings > Pulse says the brief comes every day only to a plugin that reports `pulse_daily_brief` (2026-10-25, notifier #357, #1234, Eric's report: a 05:00 brief with nothing held never came).
- Not now hides a card without teaching Pulse anything, and the plain one (no time chosen) rests the item a week (2026-10-23, #1173, notifier #334); it stays neutral when Pulse learns from ratings (2026-10-24, Eric).
- Not now asks until when: later today (three hours, by 23:00 and by the night's start, or at night ten minutes before the next morning brief; not offered when that's under half an hour away on the phone's clock, or tomorrow), tomorrow or next week (those two ten minutes before the morning brief, in time for it). The card leaves the list and the thing it's about rests until then, and its cleared row, in a morning brief too, and the Undo bar say when it comes back. At that time it comes back as new, at the top, without a push, and one about something Pulse remembers, or a report item Pulse found on its own, has its chat read first, like a held card's before the brief: done meanwhile, it's marked done instead, and a card no run got to comes back unread rather than late. Nothing is learned either way. An app from before, or a plugin that doesn't report `pulse_rest`, keeps the plain Not now: the card stays away and the thing rests a week (2026-10-26, Eric asked for the five improvements; notifier #380, #1278. The night's start and the brief at night came with Pulse at the right time, 2026-10-26, when Eric chose to build the gaps in order; notifier #399, #1318).
- Report cards have Why? too. The candidate list gives each pick its reason (why now, and where it came from) apart from its line, the card carries it, and the app shows Why? on a report card when the plugin reports `pulse_card_why` and the reason isn't empty; a report written without the list has none. With a plugin from before, only follow-up cards show Why?, since every other card's why was a stock line. Before, the report line ended with the reason in brackets, every report item's card had the same stock why, which the app never showed, and a whole report's card showed a stock line, now cleared from earlier cards too (2026-10-26, Eric asked for the five improvements; notifier #381, #1283).
- What learning decided shows, and can be undone. A card's Why? names the biggest part learning played in bringing it up (a kind, a chat, an area of life or where Pulse found it, a timing, or how loudly a kind comes up), how strongly, and the votes behind it lately. What Pulse learned lists what learning holds, strongest first, each with Reset, and Start over forgets all of it; each is a lesson Undo takes back, and the levels and the lessons from reasons stay. The lean over Pulse's cards in general, which every vote makes, goes only with Start over. What Pulse left out lists what the latest reports considered and left out, and why: what learning or the user's own rules kept out first, then the report's own picking. Bring it up makes one a card on the Pulse screen without a push, and its thumbs, Do it and Done then teach Pulse about things like it. The app shows these to a plugin that reports `pulse_explains` (2026-10-26, Eric chose to build slice 3 of designs/pulse-learning.md; notifier #394, #1302).
- Pulse picks the time for a push. The night, in Settings > Pulse (22:00 to 07:00 by default, or none), holds a follow-up's push for the morning brief, or until the night ends when the brief comes over two hours later. A push also waits while an event on the phone's calendar is on (not all-day, free, cancelled or declined), while the phone said it was driving or on CarPlay in the last 15 minutes, or while a Focus that holds Hermes's calls is on; past three hours it comes up on the Pulse screen without one. Each check says when its news is useful (any time, office hours, the morning or the evening), and news is held until then and checked again first. What's urgent, or due before it would come (a day with no time counts as due by that day's night start), goes anyway. Wrong time on a thumbs down puts the card away until a better time and teaches nothing about the card; on a card that pushed it also keeps that kind from pushing in that part of the day (morning, midday, evening or night), a lesson Undo takes back. The report's picks are capped the same way, and at night go into the brief. Why? says what held a card. The app offers Wrong time and the Night row to a plugin that reports `pulse_hours` (2026-10-26, Eric: "The same reminder might be incredibly useful at 9 AM and infuriating at 11 PM", and he chose to build the gaps in order; notifier #399, #1318).
- Pulse gets louder on its own only within the channels and intensity the user allowed. It never turns on a channel they turned off and never grants calling: calls need an opt-in, and adding the kinds that may call asks first (2026-10-24, Eric).
- Tone stays out of what Pulse learns, and a reason given on a thumbs-down applies at once (2026-10-24, Eric).
- Pulse pushes follow the Notifications rulings: App Language from title_label, titled with the session title (2026-10-23, notifier #334).
- Code picks the report's items from a candidate list the model makes, and every candidate is journaled for 30 days (2026-10-24, notifier #337).
- Before Pulse speaks up about an item it reads what happened since, wherever: the item's chat and its continuation, other chats and cron runs on the same subject, what Hermes runs in the background, and the phone's calendar and reminders. That holds for follow-up checks, held reminders, cards waiting for the brief, the report, Do it checks and the checks of a report item Pulse found on its own. Pulse's own hidden chat stays out of the evidence (2026-10-24, Eric; notifier #346, #347). A long chat counts whole: checks read its newest lines and then its earlier ones on the same subject, and the report never takes an earlier turn in Pulse's own chat as news (2026-10-25, notifier #364, Eric's report: a card blamed a reminder job for bringing back finished items).
- Main reached `pulse` by merge commits, never a squash, so archives didn't re-stitch old conflicts (2026-10-24, #1186; build 228's stitch lost the Chats Pulse button). #1517 merged `pulse` into main the same way; Pulse work goes to main from then on.
- Done and Do it work on every report item, one Pulse found on its own included. Do it opens the chat it was found in, or, for one from the calendar, reminders, Hermes's notes or scheduled jobs, or the Shortcuts inbox, a new chat in the dashboard's default profile, with the reminder in the composer, and only in the chat Do it's New Chat made. It starts that chat only when New Chat can start one at once: connecting, during a profile switch or with another new chat on its way, the Pulse screen says why instead. The Do it check then reads that chat with the others on the subject. Done on a found item marks only the card, and the next report reads it as done. On a found item the app shows them only to a plugin that reports `pulse_found_actions`; with an older plugin they stay on items about something Pulse remembers (2026-10-25, Eric; notifier #362, #1240; Eric asked why date and worth-knowing cards couldn't be acted on).
- What's finished stays finished. A reminder sent on with Do it, and Hermes's answer to it, can close a remembered item but never add one, and a commitment Pulse learns of more than half a day after its time (reading older chats) is kept as expired, never reminded (2026-10-25, Eric; notifier #364, Eric's report: a card blamed a reminder job for bringing back finished items).
- What got done elsewhere leaves the Pulse screen. When memory reads a chat that shows a remembered thing done or called off, the thing closes and its cards (follow-ups and report items, about it or about what it replaced) get Pulse's done mark in the same write, shown as "Done, seen in the chat": a held card leaves the brief, and one put off with Not now or Wrong time shows as done and doesn't come back. A commitment Pulse reminded the user of stays closable for two weeks, so an answer in any chat, or to the reminder, closes it; said again, it's a new item with its own reminder. A report item Pulse found on its own has its chats read again a day after it came and once more a day later, while it's on the screen and under three days old, at most three a run and last, on what the follow-up checks leave; held for the brief or put off with Not now, it's read before it goes in or comes back, like a remembered one, and one tapped Do it on is left to Do it's check; one found outside the chats is read without Pulse's own chat. Undo takes Pulse's mark off and reopens the thing while that close still holds it, and a card that was put off stays put off. A card put back after any of Pulse's marks isn't read again for a mark: it goes to the brief as it is, stays on the screen, or comes back from Not now unread, and only a new close or a new Do it marks it again. Pulse's marks teach nothing. On the Pulse screen, a card marked done while it's put off shows as done, with Undo, in a morning brief too, and one put off with Wrong time shows that reason under it, as a done card shows its reason (2026-10-26, Eric: "is there a way that pulse recognizes in later scans that a previously surfaced card is taken care of?"; notifier #400, #1326).
- After a plugin update the restarted dashboard takes Pulse over at once: a loop lease stamped with an older build is free, and one whose process has exited doesn't read as an older copy running, so Settings > Pulse and `pulse status` warn only while a process that loaded an older build really runs (2026-10-26, notifier #392, Eric's report: Pulse said the dashboard ran old code for a couple of minutes after the update had restarted it).
- Settings > Pulse's model runs all of Pulse: its turns (the reports and the morning brief), memory, the report's candidate list, and follow-up, held-reminder, brief-card, found-card and Do it checks. On Default the calls outside the chat use the Pulse chat's own model, as Hermes reads it back when it reopens the chat, unless Hermes's "Pulse memory" slot names one; a chat without a model of its own, or whose provider is gone, leaves them on Hermes's main model (2026-10-25, #1262, notifier #375, Eric's report: with the Pulse chat on Volcengine, report lists and a follow-up check ran on the main model and failed while it was out of capacity).
- Settings > Pulse never names the Pulse chat, which the user can't see: the model picker's first choice is "Default (model)", the model the hidden chat is set to, or "Default (Hermes' main model)" when it has none or its provider is no longer set up (just "Default" from a plugin before 0.120.3, which doesn't say); the section shown while there's no chat is Set up Pulse; an unpinned chat gets a Pin it button, and the plugin's problems say to fix them from Settings > Pulse (2026-10-30, Eric: "it says use the same model as pulse chat. you never see pulse chat anymore"; #1520, notifier 0.120.3).
- Do it's message fits what the card is about. For something the user meant to do (a commitment, a reminder, a plan, a follow-up topic, a next step) it asks Hermes to take care of it; for what Hermes said it would do (a follow-up card, a promise), to go ahead; for a date, to help get ready; for a deadline, to help take care of it before then; for something watched, where it stands; for an interest, to tell more; for anything else, to look into it. The Do it button's icon has its colour set outright, so it shows on the button's accent fill (2026-10-25, #1275, Eric's report: the Do it line didn't always make sense for the card, and the button showed its title alone, pushed right).
- A card whose chat is a Kanban task's worker (see Kanban workers' transcripts) names the task, from the dispatcher's `work kanban task <id>` prompt (`kanban_task`, notifier 0.117.1). Hermes won't reopen a worker as a chat, so the card links the task instead, opened in Tasks › Board on whichever board holds it, where Reply & unblock, Note & requeue and Reclaim are; and Do it starts a new chat in Pulse's profile, as for an item from no chat, asking Hermes to check the task on the board and get it going again if it's stuck. The Do it check reads that new chat, not the worker's transcript (2026-10-29, #1473, notifier #458; a tester's report via Eric: Do it opened the worker's chat, where the task couldn't be started again, and they suggested a new chat or putting the task back to work).
- A note to Pulse, in the user's own words, from Settings > Pulse or `hermes conduit-push pulse note`: the report's candidate list, the report turn, the morning brief and the follow-up, held-card and found-card checks read it as the closing paragraph of their instructions, and where it says what to bring up or leave out it comes before Pulse's own rules. Up to 1,500 characters; memory and the Do it check don't read it. The app shows the field only to a plugin that reports `pulse_note` (2026-10-25, Eric asked for the five improvements; notifier #378, #1277).
- Quiet times: quiet days of the week and a vacation until a day in Settings > Pulse, and Quiet for today on the Pulse screen and as a Pulse notification's button. While quiet, Pulse sends nothing on its own: no report, look or morning brief, none it skipped goes late when the quiet ends at midnight, and a follow-up due to push waits for the first brief after. Memory, Do it's checks and a put-off card's return go on, and a report or look the user asks for still comes. Quiet for today lasts until midnight and never shortens a longer spell. The Pulse screen says Pulse is quiet and until when, with End quiet time for a spell. The notification's button works without opening Conduit, on the host the push came from (by its relay gateway) when that is the dashboard in use; otherwise, or when it can't reach Hermes, it says so, and that notification's tap tries again with Conduit open, switching dashboards as a tap on the push would. During a call it waits for the call to end, as a tapped notification does, and says so; of it and a tapped notification, whichever started waiting last is the one that goes through, and if Conduit closes meanwhile it waits again at the next launch, on the day it was pressed only, since it was Quiet for that day, and not once it's two hours old, as a tap. It opens the Pulse screen only on the push's own dashboard. A pairing with no key gets no Quiet for today button: the button acts on the push's host, so it needs a push Conduit could verify. Settings shows a vacation's day in the plugin's time zone, as the plugin keeps it, and the Pulse screen says when quiet ends on the phone's clock. The app shows all of it only to a plugin that reports `pulse_quiet` (2026-10-26, Eric asked for the five improvements; notifier #383, #1285; the wait for a call came in #1302, carrying #1297's wait for a tapped notification over to the retry, the call fix Eric asked for with them).
- Pulse remembers dates that come back every year and looks two weeks ahead. A birthday, an anniversary or another yearly date said in a chat is kept with its month and day, never expires, and stays open when a card about it is marked done; the people picked in Settings > Calendar & phone > People bring their birthdays, and a birthday said in a chat on the same day as a picked person's counts once. Birthdays and anniversaries come up two weeks ahead (or the first day Pulse knows of them, while over a day away), the day before and on the day; other yearly dates the day before and on the day; each lead time once a year, unless its card is still open (see the open-card ruling below). Once a day, from an hour before the morning brief and not while Pulse is quiet, one model call reads the next two weeks (the yearly dates, the phone's calendar and reminders, what Pulse remembers and what it brought up lately), words each date due and adds up to five things worth starting on today. Code decides as for the report, a date due a floor unless the call says it's done, covered or raised lately, and journals every candidate, so What Pulse left out lists the look ahead's too and says which left each out. What Pulse remembers and `pulse memory` show a yearly fact's day. What comes up is held for that morning's brief, or goes to the screen once the brief went; nothing from the look ahead pushes on its own except a pick held for a saved place or a kind of shop, which pushes when the user gets there (see Where you are, for Pulse), and a held card no brief took that day goes to the screen at midnight. With the follow-ups' budget spent or the call failing, the dates still come up in Pulse's own words. It runs with Pulse memory, on the follow-up budget whatever the follow-ups' switch, and `pulse ahead off` turns it off. People's caption says Pulse brings up their birthdays where the plugin reports `pulse_dates` (2026-10-27, Eric chose to build the gaps in order; notifier #407, #1339).
- Pulse memory keeps deadlines from the Shortcuts inbox, quietly. With memory on, each memory run reads what was logged since it last read, after the chats and on what they leave of memory's budget (a week back the first time; NFC tags, sounds and the last minute's uploads skipped), and keeps only a day by which something of the user's ends, renews, closes or is due: a free trial, a renewal, a bill, a return window, a booking, an expiring card or licence, never sales, deliveries or appointments. Code keeps one only when the words it came from and its day are in the event; one already over when read is kept as expired. A later event repeats, moves or closes it ("Payment received"), and so can a chat. Each comes up a week ahead and the day before, in its own section of the look ahead, as a floor; deadlines have their own level in What Pulse learned, starting held for the morning brief, so none pushes until the user turns them up, and a model's finds never make one. Done on its card closes it and Undo opens it again; Do it starts a new chat. A deadline is deleted a day after it's done, forgotten or expired, and at once when its event is deleted in Settings > Shortcuts inbox. Settings > Pulse's Deadlines from Shortcuts switch, under Memory, turns it off and forgets them, after asking. The app shows the switch, What Pulse remembers' Deadlines with who each is from and when it was logged, and the inbox page's caption to a plugin that reports `pulse_inbox` (2026-10-27, Eric's card "Keep deadlines from your phone's inbox in Pulse memory, like trial ends and bills?": Keep them quietly; notifier #410, #1341).
- Pulse looks first, then asks. With Look things up first on (the default; Settings > Pulse or `hermes conduit-push pulse look`), a Pulse turn may read the phone's calendar, reminders, alarms, contacts and status, look up places in Maps between places it names, never where the user is or their saved places (with Where you are on they may, and walking past's shop search on the phone is not a look-up; see Where you are, for Pulse), and on a follow-up about something said in a chat search the web: at most 6 look-ups a turn, 20 Maps and 10 web searches a day, and nothing else, whatever Hermes's approvals say. Why? on its cards says what it looked at. It never changes anything itself: an event or reminder it would add is checked as the calendar tool's write would check it and kept as a suggestion (at most 2 a turn and 5 a day), its own card once the turn's message is in, saying what it adds in words code writes from its fields, with times in the phone's time zone. Add asks the phone for that change once, never in the add-without-asking tier: the app that tapped Add applies it without the phone's own card within 15 minutes, and another device asks there. The card follows the change (adding, added, changed on the phone, couldn't add, not added, expired), and Undo, after asking, deletes what it added the same way, once. When the tapping app's exchange doesn't get the change to the phone, the Pulse screen says so, and its next exchange tries again. Not now drops it. A suggestion is always a card of its own, never one of a morning brief's. While a Pulse turn is in flight in its chat, the calendar and phone tools refuse changes from that chat, and from a call Hermes names no chat for (`pulse_turn`). The app shows the switch and Why?'s look-ups to a plugin that reports `pulse_look`, and suggestion cards to one that reports `pulse_proposals` (2026-10-27, Eric chose to build the gaps in order; notifier #415, #417, #1356).
- The morning brief brings what Pulse remembers about today's events: with Pulse memory on, for each timed event left today, soonest first, the open items that share a name with it (its people when the phone shares them, a name in its title) or a word few items have, at most five in all, looked up in code with no model, so the brief can say "lunch with Dan at 1: he started the new job on Monday" (2026-10-27, Eric chose to build the gaps in order; notifier #422).
- How much a Pulse push may interrupt, and a private one's words, follow the Notifications rulings; where the user is, the Where you are, for Pulse rulings (2026-10-27, notifier #420, #422, #423, #424, #1379).
- Pulse knows what comes next. The candidate list reads what got done since the last report and the timed events on the phone's calendar that ended since then, and may bring up a next step after one: the hotel once the flights are booked, the cleaning the dentist said to book. Code keeps one only when it names the done item or the ended event it follows, at most 2 a report. Next steps have a level of their own in What Pulse learned, held for the morning brief by default (Eric chose Morning brief, 2026-10-27), and their cards are titled "Next step", tinted indigo; Do it opens the chat of what it follows, or a new one. A job whose runs fail covers nothing (notifier 0.106.0, `pulse_next`).
- A Do it that stalled comes back once: nothing sent from the chat a day after Do it, or Pulse's checks finding it still not done, brings the card back at the next steps' level, never twice, and not once its item closed or the user marked it done, put it off or rated it not useful. Its Why? says when Do it was tapped in the App Language, from the feed's `back` and `back_acted_at` (notifier 0.107.0).
- A phone reminder comes up once, however often it's moved: the report's list keys each open reminder, and a card about one isn't made again within a week (except once in the last 24 hours before it's due, notifier #471), or at all while it's open once its card was put away for good or rated not useful. A reminder due within a day still comes up the first time (2026-10-27, Eric: three cards for one cipher-lock reminder he kept moving back, "there just wasn't a reason to show it 3 times"; notifier #429, 0.106.1).
- Nothing comes up again while its card is open: while a card about a remembered item, a phone reminder or a calendar entry is on the Pulse screen, waiting for the brief, a place or a shop, or resting with Not now, the report and the look ahead skip it as raised. Only in the last 24 hours before it's due (for a date, its whole due day) may one more card come, once; a reminder's due is the phone's, an entry's its own day. Once its card is done, a reminder or calendar entry waits a week, and a remembered item comes back as before. Calendar entries are keyed like reminders in the report's list and the look ahead (`v1`), or matched by every word of an entry's title in the next two weeks (on the day the find says it's due, or, with no day, when the title is at least half of what it says), one card per occurrence; two finds about one entry in a run make one card (2026-10-29, Eric: three cards for one birthday on the calendar, then "if it's still open, why are we repeating it?"; notifier #471, 0.120.2). The morning brief follows the same rule: what it reads leaves out the remembered items, reminders and calendar entries an open card says, and those put away for good, except once on the day one is due (2026-10-30, Eric: the RAPIDS appointment left open the day before, and the Volcengine plan's end, came back in the next morning's brief; notifier #478, 0.122.1).
- A failed tool call reaches the report only when something went wrong: a terminal command's ledger row keeps, as its error, the line of its output that says what went wrong (or its last line), and the report leaves out a failure only when the command said it doesn't matter and its output shows nothing wrong: the part that set the exit is a lookup like ls or cat that silenced its errors (sent them to /dev/null; a silenced git push, curl or script still counts), or is a yes/no check whose exit 1 means no (grep, test, diff and the like); it also leaves out a call that later went through as the very same call (same tool and arguments). Every other failure stays however it's worded, since a list of failure words can never be complete (the first version dropped any exit without one; review found real failures it missed). This is decided on the raw command and output and written into the error, and a timeout, a command that couldn't run or a kill (exit 124 and up) is never harmless. The kept line loses URL user info and queries, secret-looking `key=value` pairs, bearer tokens and long key-like runs. A traceback still shows, with its exception. A bare exit with no output stays, and the report's prompt says it matters only when what the command was for (a deploy, a backup, a send) plainly didn't happen; exit codes alone never decide (2026-10-31, Eric, from Furina's report: an `ls` of an unmatched glob with its errors silenced made a card saying "exit 2", and a scraper's passing DNS failure made another; notifier #483, 0.122.3).
- Settings > Pulse and What Pulse remembers open on what Pulse answered last on this dashboard, kept on the phone (see Screens that open on their last answer). Until Pulse answers again, a step that writes back what the page shows besides what was picked, or acts on it (Set up Pulse, Pin it, reading older chats), waits; a kept state never stops this iPhone watching shops (Eric's ruling of 2026-10-30 on issue #1533, #1555).

**Open gaps**
- Set up Pulse: if titling the new chat (or the profile check) fails after the host made it, the chat stays in the default profile untitled and unpinned, not yet recorded as Pulse's, so it can show in Chats (`AppState.createPulseHomeChat`; from #1092, found in review on #1517).
- Set up Pulse in Settings > Pulse hasn't been tried on a real host: it must make a chat Pulse finds before anything is sent in it.
- What a Pulse push does on the Watch, which has no Pulse screen, hasn't been checked, Quiet for today's button included.
- The note to Pulse in Settings > Pulse hasn't been tried on a phone against notifier 0.78.2 (#1277).
- Not now's later today, tomorrow and next week haven't been tried on a phone against notifier 0.78.3 (#1278, #380).
- Why? on report cards hasn't been tried on a phone against notifier 0.80.1 (#1283, #381).
- Quiet for today from a Pulse notification hasn't been tried on a phone: its button runs in the background, where Conduit may still be connecting (#1285).
- Learning hasn't been tried on a phone against notifier 0.81.1, nor a report card's reasons (#1286, #385).
- What Pulse learned's Reset and Start over, Why?'s line on what learning did, and What Pulse left out haven't been tried on a phone against notifier 0.84.0 (#1302, #394).
- The night, waiting while busy, and Wrong time haven't been tried on a phone against notifier 0.86.0 (#1318, #399).
- What got done elsewhere hasn't been tried on a phone against notifier 0.87.0 (#1326, notifier #400).
- Yearly dates, the look ahead, What Pulse left out's look ahead section, a yearly fact's day in What Pulse remembers and People's caption haven't been tried on a phone against notifier 0.88.0 (#1339, notifier #407).
- Deadlines from the Shortcuts inbox haven't been tried on a phone against notifier 0.90.0, nor on real logged emails and notifications (#1341, notifier #410).
- Looking first and suggestion cards haven't been tried on a phone against notifier 0.98.0, nor a change approved on a card on one device and asked for on another (#1356, notifier #415, #417).
- The brief's items related to today's events, a push's level and private pushes haven't been tried on a phone against notifier 0.104.0 (#1379, notifier #422, #424).
- Next steps and cards back after a stalled Do it haven't been tried on a phone against notifier 0.107.0, nor on real ended events.
- A card from a Kanban task's worker (its task link and Do it's new chat) hasn't been tried on a phone against notifier 0.117.1 (#1473, notifier #458).
- One card per thing while its card is open (calendar entries keyed, the due-day card) hasn't been tried on a phone against notifier 0.120.2 (#1516, notifier #471), nor the morning brief leaving out what an open card says against notifier 0.122.1 (#1543, notifier #478), nor harmless command failures left out of the report against notifier 0.122.3 (#1575, notifier #483).
- Not now's choices read the night and the brief's time on the phone's clock, while the plugin keeps them in Pulse's time zone: the two differ only when Settings > Pulse sets a time zone other than the phone's.

**Checked:** 2026-10-31, #1575 (harmless command failures and calls that later went through are left out of the report, notifier #483; the app, pushes and the Watch needed no change); #1555 (Settings > Pulse and What Pulse remembers open on their kept answers, and the steps that carry what's shown wait for Pulse's; a push's Quiet for today keeps the state Pulse answers with; the Pulse screen, the Watch and the notifier needed no change); 2026-10-30, #1543 (the morning brief leaves out what an open card says, notifier #478; the app, pushes and the Watch needed no change); #1528 (on a Mac, Not now on cards and brief items and Forget in What Pulse remembers are on a right-click menu too, since a trackpad no longer swipes rows there; see Swiping list rows on a Mac); #1520 (Settings > Pulse no longer names the hidden Pulse chat: Default names its model, Set up Pulse, Pin it, with notifier 0.120.3; the Pulse screen, pushes and the Watch needed no change); 2026-10-29, #1517 (the `pulse` branch merged into main, and Pulse no longer hidden on App Store builds: Settings > Pulse and the Pulse screen, its text scaled on a Mac like the rest of the app, the README; the gap on unchecked app paths closed; the notifier, the Watch and pushes needed no change); #1516 (nothing comes up again while its card is open, and calendar entries keyed like reminders, notifier #471; the app, pushes and the Watch needed no change); #1484, carrying #1482 from the `pulse` branch (each morning's brief replaces the one before; pushes, the Watch and the notifier needed no change); #1479, carrying #1473 from the `pulse` branch (a card from a Kanban task's worker links the task and Do it starts a new chat, with notifier #458, 0.117.1; pushes, the Watch, What Pulse left out and learned needed no change); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, at #1427, carrying #1426 from the `pulse` branch (the `pulse` branch's entry after #1426, adding the Walking past lines to main); at #1423 (the look ahead's ruling names its picks held for a place or a shop, and the look-ups' ruling points to Where you are, for Pulse, for Maps from where the user is and walking past's own search); 2026-10-27, at #1398, carrying the `pulse` branch's entry: #1392, with notifier 0.106.0, 0.106.1 and 0.107.0 (next steps: their title and tint, Do it's message and their row in What Pulse learned; a card back after a stalled Do it: its Why? in the App Language; the morning brief, pushes, the Watch and calls from Hermes needed no change); 2026-10-27, at #1383, carrying the `pulse` branch's entry: #1379 (Where you are, with notifier #420, #422 and #423, in its own entry; a push's level and private pushes, with notifier #424: Settings > Pulse's Where you are and Hide private reminders on the Lock Screen, the place a promise waits for on What Pulse remembers, "where you are" in what a card's turn looked at and the extension's private line; the brief's items related to today's events; the Pulse screen, Quiet for today, the Watch, calls from Hermes, the Shortcuts inbox and Do it's new chat needed no change); 2026-10-27, at #1375, carrying the `pulse` branch's entry: #1356 (looking first and suggestions, with notifier #415 and #417: Settings > Pulse's Look things up first, Why?'s line on what Pulse looked at, suggestion cards with Add, Not now and Undo and their states, and the phone applying a change approved on a card, saying so when its exchange didn't get it or it doesn't share its calendar; the morning brief's block leaves suggestions out, each its own card; Phone change errors and Phone data sync with the host gained their Pulse rulings); 2026-10-27, at #1345, carrying the `pulse` branch's entry: #1341 (deadlines from the Shortcuts inbox, with notifier #410: Settings > Pulse's Deadlines from Shortcuts switch, What Pulse remembers' Deadlines with who each is from and when it was logged, deadline cards with Done and Do it's message, What Pulse learned's Deadlines row and the inbox as a place, and Settings > Shortcuts inbox's caption and delete-all message); 2026-10-27, at #1340, carrying the `pulse` branch's entry: #1339 (yearly dates and the look ahead, with notifier #407: birthdays and anniversaries from the chats and the picked people every year, the daily look two weeks ahead held for the brief, What Pulse left out's look ahead section, a yearly fact's day in What Pulse remembers, and People's caption, which says Pulse's memory has to be on); at #1332, carrying the `pulse` branch's entry: #1318 (Pulse at the right time, with notifier #399: the night, waiting while busy, Wrong time and its lesson, and Not now's choices at night) and #1326 (what got done elsewhere, with notifier #400: memory's close marks the thing's cards, a reminded commitment stays closable for two weeks, report items Pulse found on its own are read again, a card put back with Undo isn't marked again from its chat, and a card done while it's put off shows as done, with Undo and Wrong time under it when that put it off); at #1308, carrying the `pulse` branch's entry: #1302 (what learning decided, with notifier #394: Why? names it, What Pulse learned's Reset and Start over, and What Pulse left out with Bring it up; and Quiet for today's retry waits for a call, kept across a relaunch on the day it was pressed) and #1306 (the morning brief folds from its header and stays folded until it's opened again or a card in it comes back open); at #1297 (a Pulse push tapped during a call no longer switches and opens once the call ends, like any notification, and Quiet for today's retry waits for the call the same way; the `pulse` branch gets both with its port); at #1293 with notifier #392 (the lease after a plugin update; the `pulse` branch's older-copy line needed no change); at #1292 (the Watch joins Siblings), carrying the `pulse` branch's entry: #1286 (learning, with notifier #385), #1285 (quiet times, with notifier #383), #1283 (Why? on report cards, with notifier #381), #1278 (Not now until when, with notifier #380), #1277 (the note to Pulse, with notifier #378) and #1275 (Do it's message and icon); 2026-10-25, at #1266, with #1264 on the `pulse` branch and notifier #375 (Pulse's model, ruled in #1262); the app side at #1240 on the `pulse` branch, with notifier #362 and #364, carried to main in #1241.

## Where you are, for Pulse

Pulse using where the user is, once they turn it on: what they said they'd
do at a saved place comes up as they get there or leave, a pick from the
daily look ahead can wait for a place or a kind of shop the phone watches
(walking past), and Pulse's look-ups can start from where they are. Like the
rest of Pulse, it's on main and in App Store builds.

**Siblings:** Settings > Pulse's Where you are and Walking past switches and their captions · What Pulse
remembers (the place a promise waits for, and the saved place it names) ·
location sharing (Settings > Location: sharing in the background, its pause,
saved and private places, When Hermes read your location) · the notifier's
location store and its arrivals and departures, in each profile that reads
the location · the place rules (call limits and jobs by place read the same
arrivals) · Pulse's follow-ups, the daily look ahead and the Pulse screen (a
held pick's card and its Why?) · Pulse's look-ups (`conduit_location`, and
Maps from "me" or a saved place) · Pulse pushes (a reminder for a place, or a
pick at its moment, goes time-sensitive; see Notifications) · the Watch
(those pushes there) · walking past (the shops the phone watches with a
second CLMonitor, Apple Maps search on the phone, the sealed reply to a
location batch, `spot_entries` in the next one) · the `hermes conduit-push
pulse where`, `pulse spots` and `pulse status` commands (`pulse status` shows Where you are; walking past's state and entries are in `pulse spots`) · the privacy policy
(notifier docs/privacy: what Pulse keeps of walking past and how to turn it off)

**Code**
- App: `Conduit/Services/PulseSettings.swift` (PulseState's whereYouAre, whereReady and walkingPast, PulseMemoryPlace), `Conduit/Views/PulseSettingsViews.swift` (the switch, its caption and the line when Pulse can't read the location yet, the Walking past switch, its caption and the lines when this iPhone isn't watching shops (Location settings, or saved places using every place iOS lets Conduit watch), which update as Location settings change, either switch or Pulse's own off, turned off here or found off in Pulse's answer when the page loads (never in the state the page kept from last time), stopping this iPhone's watches at once through LocationSharingController.forgetSpots, and all three on sending at once so the reply brings the shops to watch; a reply to a batch sent before the off is ignored and a batch still connecting then carries no shop entries, shops becoming allowed again in iOS Settings sends at once, and a change made elsewhere otherwise reaches this iPhone with the host's next reply, and a promise's place in What Pulse remembers), `Conduit/Services/PulseFeed.swift` (pulseReadsWhere, and "where you are" in what a card's turn looked at), `Conduit/Location/PulseSpotWatcher.swift` (walking past: the shops searched and watched, first state, entries), `Shared/Location/LocationSpots.swift` (watches, entries, the sealed reply, PulseSpotState), `Conduit/Location/LocationSharingController.swift` (watchesSpots, spotEntered, sendNow's spot_entries and spots_room), `Conduit/Location/LocationSyncEngine.swift` (spotsReplied), `Shared/Location/LocationBatch.swift` and `Shared/Location/LocationSharedStore.swift` (spot entries in the batch and unsent, spots.json)
- Location settings the Walking past lines follow: `Conduit/Views/LocationSettingsViews.swift` (background sharing at Precise, Always and Precise Location for Conduit, and saved places, whose count can leave iOS no room to watch shops)
- Notifier: `notifier/pulse_places.py` (the switch and whether the phone shares in the background, moments, place words to saved places, what waits for a place, what Pulse remembers about a place, the look ahead's picks held for a place with `bring_up`, `settle_picks` and `release_picks`, and what `pulse where` says), `notifier/pulse_followup.py` (`waits_for_place`, `place_reached`), `notifier/pulse_ahead.py` (a pick's `moment`), `notifier/pulse_memory.py` (the place words), `notifier/pulse_store.py` (moments, `place_words` and `place_on`, and the cards at level `moment`), `notifier/pulse_tools.py` (location reads behind the switch), `notifier/dashboard/api/phone_data.py` (`_location_ingest` hands arrivals and departures to Pulse), `notifier/pulse_control.py` (`where`, `where_ready`, a memory item's `place`), `notifier/cli.py` (`pulse where`, `pulse spots`), `notifier/pulse_spots.py` (walking past: watches by intent and circle, the reply, entries made moments with their reach, lateness), `notifier/location_store.py` (`spot_entries`, `spots_aad` and the sealed `reply`, only at Precise), `notifier/docs/privacy/index.html` (what Pulse keeps of walking past)
- Tests: `notifier/tests/test_pulse_places.py` (the switch, moments, places in what memory keeps, a reminder that waits for its place, and what a place brings up), `notifier/tests/test_pulse_held.py` (the look ahead's picks held for a place), `notifier/tests/test_pulse_spots.py` (walking past); the app's `ConduitTests/PulseSettingsTests.swift` (Where you are, Walking past's state, and a promise's place in What Pulse remembers), `ConduitTests/LocationSharingTests.swift` (Walking past turned off drops the shop entries waiting to be sent) and `ConduitTests/LocationSpotsTests.swift` (walking past: the shared vector, the batch, the watcher)

**Rulings**
- Where you are is off until the user turns it on, in Settings > Pulse or with `hermes conduit-push pulse where on`, and separate from sharing location with Hermes. Pulse reads where the user is only while it's on and Conduit shares the location in the background, not paused; Settings > Pulse says when it can't read it yet. A private place is never read. Off reads nothing and deletes the arrivals and departures and the shops come near that Pulse kept, and so do turning Pulse off and wiping location (turning walking past off deletes the shops alone); the places on what Pulse remembers stay, like the rest of its memory. The app shows the switch, a promise's place and "where you are" in Why?'s look-ups to a plugin that reports `pulse_where` (2026-10-27, Eric's card on step 5: Opt in; notifier #420, #1379; the shops, 2026-10-28, Eric in the Pulse thread, as for walking past below).
- A commitment or promise said for a place ("next time I'm at Costco", "when I leave work") keeps the place's words, only when they're on the item's own line, never guessed. They name a saved place by its name or its kind ("home", "work" or "the office", "the gym", "school"), and a kind's words name only a place of that kind; words that name no saved place match one saved later. The item waits for its place, 30 days or a week past its date, instead of checks on a schedule. Getting there (or leaving, when that's what was said) makes it due: checked as any follow-up, with where the user is and what Pulse remembers about the place, its reminder goes at once and time-sensitive, and Why? says so. Nothing is made due at night, on a quiet day, in a part of the day closed for follow-ups, during an event or a Focus that holds calls (driving doesn't count), or with follow-ups off or kept for the brief: it waits for the next time (2026-10-27, notifier #420, #422).
- Arrivals and departures at saved, non-private places, at most 15 minutes old, reach Pulse from `/location/ingest`, here and in each profile that reads this location, and Pulse handles them first on its next tick; each is kept a day. One with nothing waiting for it says nothing yet: what it would have brought up is kept for `pulse where` to list, to judge before it speaks (2026-10-27, notifier #420, #422).
- The daily look ahead may hold a pick that would push for a saved place it listed, until the start of the pick's day and at most two weeks, ten at once. The held card waits off the Pulse screen, read every six hours like a card held for the brief. The first time the user gets to (or leaves) the place where Pulse may speak up, a turn of its own brings it up, one pick a moment, looking things up first but never the web, and pushes as "Pulse noticed something", time-sensitive. A turn that doesn't go out leaves it waiting. At its window's end, with Where you are off, or once its kind is made quieter than a push, it comes on the screen without a notification; done while it waited, it goes where it was made, as seen (2026-10-27, notifier #423, #424).
- Walking past: the look ahead may hold a pick for a kind of shop (`"moment": {"spot": "a florist"}`), held as a saved place's pick is, in the same window and the same ten at once, and an item said for a place that matches no saved place is watched by its words. Only search words go to the phone, in the sealed reply to a location batch that carries `spot_entries`, at most six; it searches Apple Maps near where it is, watches the nearest three per search word, taken in turn, with a second CLMonitor in what saved places leave of iOS's twenty (at most ten in all), searches again after moving 1 km (at most every 30 minutes) or starting or stopping driving, and reports the shop's name, when, and a fresh fix's distance, accuracy and speed, never the shop's coordinates. Only with Pulse, Where you are and walking past on (on by default; the Walking past switch in Settings > Pulse, shown under Where you are while it's on and only when GET /pulse reports `spots` (notifier 0.111.0, so an older plugin shows no switch), `pulse spots off` or PUT /pulse's `spots` turns it off alone and forgets its entries; its caption says what the phone searches and what the gateway learns), and while background sharing is at Precise, with Always and precise location, not paused; nothing inside a private place. The phone's Apple Maps search is its own, not one of Pulse's look-ups: it doesn't count against their caps, and the host learns only what the phone reports of an entry. Each watch has an intent sizing its circle, aimed at a useful chance to act rather than the shop's edge: an opportunity (a pick's default) 750 m walking and 3 km driving, any entry counts; an errand (an item's default) 100 m, the fix inside it; an arrival 100 m, the fix inside with its accuracy; the look ahead may set its own `radius_m`, within its intent's bounds (an opportunity's 500 m to 5 km, an errand's and an arrival's 50 to 300 m). The phone's search has no daily cap: it runs on the phone, costs the host nothing, and only moving 1 km or starting or stopping driving sets it off, at most every 30 minutes. Pulse says the user came near the shop or got to it or right by it, never that they went in. Every entry is kept 30 days with how late iOS told the app (`pulse spots`), and it ships live, no shadow mode (2026-10-28, Eric in the Pulse thread; notifier #435, #1414).
- With Where you are on, Pulse's look-ups may read `conduit_location` and ask Maps from "me" or a saved place, within the look-ups' caps, each read listed in Settings > Location's When Hermes read your location under the Pulse chat (2026-10-27, notifier #420).

**Open gaps**
- A failed Maps search in a walking-past pass (no network, Maps refusing) still counts as that watch's search, whether every search failed or only that watch's: the watch has no shops until the next 1 km move after 30 minutes, and a reply with the same list retries only when no watch has any shops. Retrying sooner would change the 30-minute ruling, which is the maintainer's call (found in review on #1517).
- None of it has been tried on a phone against notifier 0.104.0, nor the Walking past switch and its caption against notifier 0.111.0, nor arrivals from a real day's location sharing (#1379, #1426, notifier #420, #422, #423, #424).
- A held pick also matches another saved place with the same name: the model names the place by its name, and the name keeps a pick working after its place is saved again (notifier #424).
- Walking past hasn't been tried on a phone: how late iOS fires for 100 m circles, and whether a 3 km driving circle helps or nags, are what the kept timings are for (notifier #435, #1414). Arriving at or leaving a place that is neither saved nor a watched shop still wakes nothing.
- An item said for a place that has no saved place keeps waiting for one until it expires; meanwhile, with walking past on, its words are watched as a kind of shop and coming near one makes it due as getting there would. What Pulse remembers says it waits, but nothing asks the user to save the place.

**Checked:** 2026-10-31, #1555 (Settings > Pulse opens on its kept state, which never stops this iPhone's watches: only Pulse's answer does; the stores needed no change); 2026-10-30, #1542 (All history stays after the host's 2000 limit and stops at the oldest reading; the stores needed no change); 2026-10-29, #1517 (the `pulse` branch merged into main: the app paths it lists are on main now; nothing else changed); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, at #1427, carrying #1426 from the `pulse` branch (the Walking past switch and its caption in Settings > Pulse, closing that gap, with the plugin version that shows it and the Location settings its lines follow; the shops' deletion cites the walking-past decision); at #1423, carrying the `pulse` branch's entry: #1414 (walking past, from notifier #435 and the app's spot watcher; the rest as at #1379).

## Artifacts

The files, pages and links Hermes made, listed for every chat (the Chats
bar's Artifacts page) or for one chat (its … menu), opened in the chat's own
viewers, with Show in Chat. Beside the list, the Folder tab (Workspace files).

**Siblings:** the Artifacts page · a chat's own Artifacts sheet · the panel
beside the chat on a wide window · Bot Chats
(kept in the bot's own profile) · All (every included profile's chats) ·
group rooms (no Artifacts list) · the notifier's artifacts route · README.md

**Code**
- List model and merge: `Conduit/Services/Artifacts.swift` (ArtifactItem, ArtifactSource, ArtifactFeed, ArtifactsClient, its keptRoute, keptPage and answer(_:withoutRowsOf:))
- Which stores a list reads, a chat's ids, Show in Chat: `Conduit/Services/AppState+Artifacts.swift` (artifactSources, activeChatArtifactSessionIDs, botChatIDs, showArtifactInChat)
- Screens: `Conduit/Views/V2/V2ArtifactsViews.swift`
- A chat's store: `Conduit/Services/AppState.swift` (botStoreProfile, openLinkedBotChat, openOtherProfileChat; removeSavedCopies takes a deleted chat's rows from the profile's kept list)
- Host: `notifier/artifacts_index.py`, `notifier/dashboard/api/workspace.py` (GET /artifacts, one profile per request)
- Tests: `ConduitTests/GatewayRestartTests+Artifacts.swift`, `ConduitTests/AppStateMultiDashboardTests.swift` (testADeleteAnsweredAfterASwitchSaysNothingOnTheNewDashboard)

**Rulings**
- A list reads each store the chats it covers are kept in: a Bot Chat's sheet reads the bot's profile, and the Artifacts page reads the profile in use, each other profile All shows while it's on, and every other bot's Bot Chat, merged newest first (2026-10-24, #1203, Eric's report).
- Stores are read one at a time (the host reads two lists at once at most) and each shows as it arrives; a refresh keeps the list it is refreshing until every store answers. A bot's chat or other profile that can't be read leaves the rest listed.
- A bot whose profile is read whole (the profile in use, or one All shows) isn't read again for its Bot Chat; that chat's rows still go by the bot's name and open the way Bots opens them.
- The profile in use is always read, even when All leaves it out.
- A Bot Chat has no row in the workspace's chat list, so its ⋯ menu finds its ids from the chat itself (with the durable id Hermes confirmed under the bot's profile, so a relaunch or a reopened runtime still finds it) and the roster's registry id and lineage tip (2026-10-24, #1218, Eric's report: the item was greyed out).
- A picture image generation made is listed: the host reads `image_generate`'s result, a saved file as a written image and a hosted one as an image link (2026-10-24, #1218 with notifier #353, plugin 0.71.1, Eric's report: a bot's generated pictures were missing).
- A Bot Chat is listed though Hermes keeps it hidden: the host reads a chat asked for by id whether hidden or not, and a profile's whole list takes its hidden "Bot Chat" session and the sessions continuing it, while other hidden chats (a group room member's turns) stay out (2026-10-25, #1272 with notifier #376, plugin 0.78.1, Eric's report: a bot's pictures were still missing from both lists).
- On a window with room for the chat and the panel, ⋯ › Artifacts opens beside the chat instead of in a sheet, with its own search field; a phone keeps the sheet (2026-10-27, #1399).
- The panel beside the chat drags wider or narrower by the line beside it, kept per device; it shows at its standard width's window as before (Eric, 2026-10-29, #1492, see Resizable columns on a split window).
- One host path is one artifact across stores: profiles share the host's files, so a file two stores list shows once, at its newest mention.
- A file still opening is dropped when the list moves to another server or profile, and only the latest open clears the spinner. Every reload, including one on a dashboard without artifacts, outdates the request before it (2026-10-24, from #895's review, #1191).
- A list opens on what it listed last time, kept as it opens (every kind, unsearched, its first page) for each store's profile, a chat's own for the chats read last, which a deleted chat takes with it, as it takes its rows from the profile's; a bot's store that fails shows its kept rows, which don't page on, and kept rows wait for the plugin to say it serves artifacts or rule them out. The update notice shows only once it rules them out: with nothing kept, the list shows its loader until then, or offline, that Conduit isn't connected. Connected with no word from the plugin (its read failed as Conduit connected), the list asks it again as it opens and on a refresh, and with nothing kept says it couldn't reach the dashboard's notifier, with Try Again, if it still doesn't answer. A list kept or loaded empty says so at once, offline too (2026-10-31, #1582 and #1584, issue #1533; see Screens that open on their last answer).

**Open gaps**
- Group rooms' messages aren't listed: a room has no Artifacts list, and its members' replies stay out of the Artifacts page.

**Checked:** 2026-10-31, #1584 (from #1582's review, a deleted chat's rows leave the profile's kept list, and offline a list kept empty says so); 2026-10-31, #1582 (a list opens on what it listed last time, and a deleted chat takes its own; the update notice waits for the plugin to rule artifacts out, kept rows or none, and a list whose plugin never answered asks it again); 2026-10-29, #1491 (a picture opens in the picture viewer and pages through the list's pictures); 2026-10-29, #1492 (the panel's width drags); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-27, #1399 (the panel and the Folder tab); #1272 with notifier #376; the sheet's ids at #1218; the page and Show in Chat at #1203; opens and reloads at #1191.

## Workspace files

The Folder beside Artifacts: the open chat's working folder or a project's,
browsed as a tree, searched, previewed, edited and changed, and a file path a
reply names opened there (#1389).

**Siblings:** a chat's ⋯ › Artifacts sheet (Folder tab) · the panel beside
the chat on a wide window · the Chats bar's Artifacts page (projects' folders
only) · + › Workspace in the drawer shell (V2 off, which has no Artifacts) ·
file paths in replies (Links in messages) · group rooms (a tapped path opens
the Folder on its own) · Bot Chats (the bot's profile) · the notifier's
workspace routes · the project folder picker (same Hermes listing) · Files
prepared for preview (how the Folder opens pages and Quick Look) ·
README.md

**Code**
- Client and path links: `Conduit/Services/WorkspaceFiles.swift` (WorkspaceFilesClient and its kept listing and recent files, WorkspacePathLinks, WorkspaceRoot, WorkspaceReveal)
- Roots, profile, reveal and refresh: `Conduit/Services/AppState+Workspace.swift` (workspaceRoots, workspaceProfile, absoluteWorkspacePath, revealWorkspaceFile, noteWorkspaceToolCompleted, readWorkspaceText, workspaceDirectoryEntries)
- Tree, search, viewing and changes: `Conduit/Services/WorkspaceExplorer.swift` (askPluginIfUnanswered, from open and refresh)
- Screens: `Conduit/Views/V2/V2WorkspaceViews.swift` (WorkspaceFolderView, WorkspaceFileSheet, WorkspaceMoveSheet), `Conduit/Views/V2/V2ArtifactsViews.swift` (ChatArtifactsContent, the page's tabs), `Conduit/Views/V2/V2ConversationScreen.swift` (ChatSidePanel, openArtifacts), `Conduit/Views/ChatSupportSheets.swift` (WorkspaceSheet), `Conduit/Views/RootView.swift`, `Conduit/Views/Components/ComposerBar.swift` (+ › Workspace)
- Links: `Conduit/Views/Components/SelectableTextView.swift` (bridge), `Conduit/Services/ConduitAppLink.swift` (file)
- State: `Conduit/Models/Models.swift` (WorkspaceEntry, WorkspaceFilePreview), `Conduit/Services/AppState.swift` (workspaceReveal, workspaceChanges, showWorkspaceSheet, openWorkspace)
- Tests: `ConduitTests/WorkspaceFilesTests.swift` (testWorkspaceListingAndRecentFilesAreKeptForNextTime), `ConduitTests/AppStateMultiDashboardTests.swift` (workspace listing and file pick, testAFolderOpensOnItsListingKeptLastTime)
- Host: `notifier/workspace_files.py` (notifier #431), `notifier/dashboard/api/workspace.py` (/workspace/list, search, recent and the POST actions; capability workspace-files)

**Rulings**
- The Folder lives in Artifacts, not behind the composer's +: a tab in the chat's ⋯ › Artifacts sheet, beside the chat on a wide window, and on the Chats bar's Artifacts page. + › Workspace stays only in the drawer shell, which has no Artifacts (2026-10-27, #1399, Eric: "+" hurt visibility).
- The full explorer: previews, search, Recently Changed, new folder and file, rename, move, duplicate, delete with a confirmation, upload, and text editing that refuses a save over a file changed since it was opened (Replace It or Keep Editing) (2026-10-27, #1399, Eric picked it).
- The tree starts at the chat's folder and switches to a project's folder, never above them; the plugin keeps every path inside the root it's given and leaves out files holding keys or passwords. Hermes' own file routes already reach the home folder, so this scopes the view rather than guarding the host: on a personal install the plugin takes any folder as a root, and on a hosted or locked install only one inside Hermes' files folder (2026-10-27, #1399).
- Without the plugin's workspace routes the Folder still browses and opens files through Hermes' own listing; search, Recently Changed and changes ask for a plugin update.
- A path in a reply is a link when inline code names one, or when plain text names a path with a folder and a known file type; a relative path is in the chat's folder. It opens in the Folder, at the file, switching to the chat's or a project's folder that holds it. A file in none of them opens to read only, outside the tree, as Hermes' own file routes would show it (2026-10-27, #1399).
- A tool that writes, moves or deletes files, or runs commands, refreshes an open Folder when it completes; nothing polls.
- An answer for another dashboard, profile or folder is dropped, its failure too, and only the latest file picked shows.
- A folder opens on the listing and Recently Changed the plugin gave last time, kept on the phone for the folders read last, while it asks again; a folder opened in the tree, Hermes' own listing, search and a file read Hermes. Only an answer the folder can read is kept. A kept listing waits for the plugin's word rather than giving way to Hermes' own listing: the plugin reporting its routes reads the open folders again through them, and saying it doesn't serve them reads them through Hermes'; the update label waits until then. Connected with no word from the plugin (its read failed as Conduit connected), the folder asks it again as it opens and on a refresh, as the Artifacts list does (2026-10-31, #1582 and #1584, issue #1533; see Screens that open on their last answer).

**Open gaps**
- Group rooms have no Artifacts: a path tapped in a room opens the Folder on its own, at the projects' folders.

**Checked:** 2026-10-31, #1584 (from #1582's review, the folder asks a plugin that never answered again as it opens and on a refresh); 2026-10-31, #1582 (a folder opens on its kept listing and recent files, which wait for the plugin's word, and keeps only an answer it can read); 2026-10-29, #1491 (a picture, opened or Share or Save, opens in the picture viewer among its folder's pictures); 2026-10-29, #1492 (ChatSidePanel's width drags; the Folder in it is unchanged); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1407 with notifier #431 and its follow-up; 2026-10-27, #1399 with notifier #431.

## Bots: create and edit

New Bot and Edit Bot, and what they write to the bot's Hermes profile.
Hermes Desktop's bot editor writes the same records, so both apps show the
same bot.

**Siblings:** New Bot · Edit Bot · Hermes Desktop's bot editor (same
profile records) · the bot's face in the Bots list, its Bot Chat and group
rooms · generated pictures, shared with group pictures · profile pictures in the profile picker · the profile's name everywhere else in Conduit (Profile names) · the SOUL a new bot is
born with (the messaging section older gateways need) · the Bots list's row
menu (New Chat, Groups, Pin, Hide, Duplicate, Delete) and its Hidden section,
as on Desktop's bot row · Edit Bot's MCP catalog (adding a server with
its keys, OAuth sign-in through Safari, and the sign-in loopback shared with
Hermes sign-in) · what the editor shows before Hermes answers (Screens that
open on their last answer) · the text that describes them (the editor's footers
and README.md's bots line)

**Code**
- Editor: `Conduit/Views/BotEditorSheet.swift`, `Conduit/Views/BotModelPicker.swift`, `Conduit/Views/BotCapabilitiesView.swift`, `Conduit/Views/BotRosterView.swift`
- Writes: `Conduit/Services/BotManagement.swift` (BotCreateRequest, BotCapabilities, BotSoul, BotMetaPatch), `Conduit/Services/AppState.swift` (createBot, updateBot, saveBotModel, loadBotDetails, loadBotCapabilities, openNewBotChat; what a save, an MCP add or a sign-in Hermes took is kept for the editor, see Screens that open on their last answer), `Conduit/Services/HermesClient.swift` (createBotProfile, describeBotProfile, configureBotProfile, configureBotModel, botRuntimeCheck)
- Roster: `Conduit/Services/BotModeModels.swift`
- MCP catalog and sign-in: `Conduit/Views/BotCapabilitiesView.swift` (catalogRow, signInRow, BotMcpKeysSheet, BotMcpBrowserView), `Conduit/Services/BotMcpSetup.swift`, `Conduit/Services/AppState.swift` (loadBotMcpSetup, addBotMcpServer, signInBotMcpServer), `Conduit/Services/HermesClient.swift` (botMcpCatalog, botMcpServers, addBotMcpServer, setBotMcpKey, testBotMcpServer, botMcpOAuth), `Conduit/Services/NativeOAuth.swift` (NativeOAuthLoopbackServer's relay mode, NativeOAuthFlow.callbackValues)
- Row menu: `Conduit/Views/BotRosterView.swift` (BotRosterRow, botRooms, the Hidden section), `Conduit/Services/BotManagement.swift` (BotDuplicate), `Conduit/Services/AppState.swift` (duplicateBot, setBotHidden, setBotPinned, canDeleteBot, deleteBot and forgetKeptBot), `Conduit/Views/GroupChatView.swift` (GroupCreateSheet's preselected bots)
- A bot's face and color in its Bot Chat: `Conduit/Services/AppState.swift` (conversationAgentIdentity), `Conduit/Services/AppState+V2Shell.swift` (profileGlowTint), both from the shown roster
- Generated pictures: `Conduit/Views/GeneratePictureSheet.swift`, `Conduit/Services/PictureGeneration.swift`, `Conduit/Services/GroupRoomPictures.swift` (group pictures' list and upload, and the ones kept for the Bots list), `Conduit/Views/GroupChatView.swift` (GroupRoomPicturePicker, GroupRoomActionItems), `Conduit/Views/V2/V2ConversationScreen.swift` (the V2 room menu's picker), `Conduit/Services/AppState.swift` (refreshPictureGeneration, generatePicture), `Conduit/Services/HermesClient.swift` (imageGenerationAvailable, generateImage)

**Rulings**
- A bot's look lives on Hermes: title, color and picture kind in `ui_meta['hermes-bots']`, the picture in the profile's asset store, never on the device (2026-10-02, #297; 2026-10-14, #580).
- New Bot does what Desktop's does: it copies the main profile's settings and shares its keys and accounts unless Advanced says otherwise (Start From another bot or a fresh profile, a separate copy of the keys, no bundled skills), then introduces itself only when its profile can reach a model (2026-10-23, Eric asked for Desktop parity).
- An edited bot always keeps a model of its own: Edit Bot offers no "Same as Main Profile", since `profiles.configure` pins a provider and model and has no way to clear the pin (2026-10-23).
- On Edit Bot, a model pick the gateway guards (expensive or data-training) is saved only after the user confirms its message (2026-10-23).
- Skills, tools and MCP write only the sections the user changed; a new bot's lists start from its Start From profile, as on Desktop. A fresh profile offers no lists until it exists, since its set is Hermes' defaults (Desktop shows the main profile's instead) (2026-10-24, #1177).
- A bot keeps at least one tool on: `enabled_toolsets: []` means Hermes' default tools, so turning every tool off can't be saved (2026-10-24, #1177).
- MCP servers are plain on/off per server: `enabled_mcp_servers: []` turns them all off (2026-10-24, #1177).
- Edit Bot adds servers from Hermes' catalog (`mcp.catalog`) the way Desktop's Set Up does: `mcp.servers.add` from the preset, each typed key through `mcp.servers.set_api_key` (blank ones skipped), then `mcp.servers.test`. Hermes writes the server at once, so it stays even if the editor is cancelled, as on Desktop. Keys go to Hermes and aren't kept on the phone (2026-10-24).
- An OAuth server (from `mcp.servers.list`, or the add reply) signs in in Safari. Hermes runs the flow and keeps the tokens; the redirect comes back to a loopback on the phone, which hands it to Hermes (`client_redirect_uri` and `mcp.servers.oauth.callback`, as Desktop does for a remote Hermes). A Hermes that ignores the redirect is told to update rather than opening a page that can't finish (2026-10-24).
- New Bot offers no catalog: the server and its keys live in the bot's profile, which doesn't exist until Create. Desktop creates the profile early instead; Conduit says to add them in Edit Bot (2026-10-24).
- Generated pictures come from Hermes' own image generation (`image.generate`). Generate shows only when Hermes says a backend is set up, and the bot editor and group pictures share one sheet (2026-10-24, #1179).
- A group picture read or change that a dashboard or room switch overtook commits nothing and says nothing, on success and failure alike (#862 follow-up, #1191).
- Duplicate makes `<name>-2` (the first free number) as a full `clone_from` copy, then copies the look with " (copy)" on the title, as Desktop's `duplicateBot` does. A clone doesn't copy the asset store, so Conduit copies the photo itself and only claims one that landed; the copy is neither hidden nor pinned, whatever the original is (2026-10-24, #1192).
- Hide is the ui_meta `hidden` flag Desktop writes: a hidden bot moves to a collapsed Hidden section at the end of the list, and Desktop hides it too. It keeps working and keeps its rooms, but isn't offered for a new group, whose picker lists visible bots only (2026-10-24, #1192).
- Groups lists the hosted rooms the bot is in, then New Group Chat with the bot already picked. Hosted groups can't add or remove members after they start, so there's no Add to Group (2026-10-24).
- A kept bot, drawn from Hermes' last answer until it answers again (Screens that open on their last answer), is never written: its copy has no ui_meta to send back whole, so its row offers only New Chat and Groups' rooms, and updateBot, setBotPinned, setBotHidden, duplicateBot and deleteBot (canDeleteBot) refuse one. A bot's face shows from the copy of its picture the profile pictures keep on the phone until the fetch lands, and a kept bot's Bot Chat shows its face and color from the kept roster. A deleted bot leaves the kept roster as it goes, on the dashboard it was deleted from even if its bridge was rebuilt meanwhile, so neither a read after the delete that fails nor one asked before it brings it back (2026-10-31, #1568).
- Edit Bot opens on the bot's SOUL, model, skills, tools and MCP servers as Hermes gave them last time, New Bot on its Start From profile's lists and the MCP page on the catalog and sign-ins, all read-only until Hermes answers, since a save compares with Hermes' own; what a save, a catalog add or a sign-in Hermes took is what they open on next (Screens that open on their last answer, 2026-10-31, #1588).

**Open gaps**
- New Bot's model pick isn't guarded: `profiles.create` pins it without the gateway's expensive-model check, the same as on Desktop.
- Desktop's drawn faces, shapes and pets show only as stills; Conduit draws an initial on the color.
- The group picture switch guard has no test: it needs a ready DashboardTicketBridge double and a room switch mid-request (#1191).

**Checked:** 2026-10-31, #1588 (Edit Bot, New Bot's Start From lists and the MCP page open on what Hermes gave last time, read-only until it answers, and a save, MCP add or sign-in Hermes took is what they open on next; see Screens that open on their last answer); 2026-10-31, #1568 (a kept bot is never written, Delete included, a bot's face shows from the phone's copy until its fetch lands, its Bot Chat's face and color included, and a deleted bot leaves the kept roster); 2026-10-31, #1567 (the editor's Model page opens on the models kept from Hermes' last answer, picked once Hermes answers, with Try Again after a read that fails; see Model lists that fail to load); 2026-10-28, #1457 (the main bot goes by its Conduit name, see Profile names); 2026-10-28, #1448 (an unnamed bot shows its id capitalized); 2026-10-28, #1413 (a rename here names the profile everywhere, see Profile names); 2026-10-27, at #1395 (the editor's Model page gained search with each match's provider; saving unchanged); 2026-10-25, at #1222 (configure and MCP add wait in the profile config queue); before that #1192; group pictures at #1191.

## Opening a Bot Chat

How Conduit finds a bot's one Bot Chat (the hidden session titled "Bot Chat"
in the bot's profile), makes it the first time, and opens it.

**Siblings:** a tap in the Bots list, on Hermes' roster or the one kept from
its last answer · a new bot's first open and its
introduction · a push or a call from a Bot Chat · a link, card or artifact
that names a bot · a widget, Shortcuts or shared-draft open of a Bot Chat (opens an existing chat only, by the lookup's row) · a last-chat restore that lands on a Bot Chat (resumes the saved row's stored id) · Hermes Desktop's Bot Chat open (same lookup, same title,
same stored-id open)

**Code**
- Open: `Conduit/Services/AppState.swift` (openBotChat, resolveAndOpenBotChat, createAndOpenBotChat, adoptWinningBotChat, openCanonicalBotChat, openNewBotChat, openLinkedBotChat)
- Lookup: `Conduit/Services/BotModeModels.swift` (BotChatLookupRow, BotChatResolver, BotChatTitleCollision), `Conduit/Services/HermesClient.swift` (findBotChatSession, createBotChatSession)
- Callers: `Conduit/Views/BotRosterView.swift`, `Conduit/Services/AppState.swift` (routeBotOwnedNotification, the push and call route), `Conduit/Services/AppState.swift` (openWidgetConversation), `Conduit/Services/AppState+WidgetLaunch.swift`

**Rulings**
- One chat per bot, found by its title on the bot's profile; a lookup that fails, or comes back empty while the roster still names a chat, never makes a new one (Desktop's rule).
- A chat Conduit makes is opened by its stored id, as Desktop does: Hermes resumes a chat by its stored key and answers 4007 for a runtime id. Opening the runtime id failed the open, so a new bot's first message went to a chat Conduit didn't have open and was gone on the way back (2026-10-26, a tester's report via Eric, #1300). A create that names no stored id is found by its title, which has just landed, and that row is opened; the runtime id is never resumed.
- A title collision while making the chat adopts the chat that won instead of making a second one.
- A row of the kept roster opens through the same lookup, its kept chat counting as the roster's last confirmation, so an empty lookup still makes no chat, and so does a widget's open of a kept bot's chat (2026-10-31, #1568).
- A push or a call from a Bot Chat is routed by the roster Hermes confirmed on this connection, never the kept one: a push that crosses profiles asks for the roster again at the tap, and one that can't be told apart from a workspace's waits or is refused, as before. A kept copy is no evidence: a bot made since its answer is missing from it, and its chat would open as the workspace's own (2026-10-31, #1568).

**Open gaps**
- The new-bot fix (#1300) was read from Conduit's and Hermes' code, not reproduced on a device; a tester confirms it on the next build.

**Checked:** 2026-10-31, #1568 (a kept row's tap and a widget's open of a kept bot's chat; a push's routing keeps to Hermes' confirmed roster, recorded); 2026-10-28, #1457 (the main bot goes by its Conduit name, see Profile names); 2026-10-28, #1448 (a restored Bot Chat names an unnamed bot by its id capitalized, also when saved with the id as its label); 2026-10-26, #1300.

## Bot mentions and teammate messages

How the user brings another bot into a chat, and how bots' messages to each
other read in it.

**Siblings:** the @ list while typing · Mention a Bot in the composer's + menu ·
chats, project chats and Bot Chats (the chat's own bot is left out) · group
rooms (their own @ list and recipient picks) · the note that tells the bot
who each tag is · a teammate's delivery in the chat ("Message from Atlas") ·
the bot's folded reply to it ("Replied to Atlas") · the same notes in a saved
chat's copy · the sender's step ("Messaged Atlas") · the Live Activity's tool line ·
Hermes Desktop's bot chat · chat list previews and quotes · Read Aloud and live voice ·
the bot's SOUL messaging section · README.md's bots line

**Code**
- Tags and the note to the bot: `Conduit/Services/BotMentions.swift`, `Conduit/Services/GroupChatModels.swift` (MentionAutocomplete), `Conduit/Services/AppState.swift` (composerMentionCandidates and mentionAnnotatedOutboundText, from the shown roster)
- Composer: `Conduit/Views/Components/ComposerBar.swift` (mentionCandidates, attachmentButton), `Conduit/Views/Components/GroupRoomComposer.swift`
- Teammate messages: `Conduit/Services/BotTeammateMessages.swift`, `Conduit/Services/AppState.swift` (shownBotRoster, and shownBotRosterChanged, which TeammateMessageNote reads it again on), `Conduit/Views/ChatView.swift` (TeammateMessageNote, TeammateReplyNote, SettledToolCardContent.stepTitle, runningToolTitle), `Conduit/Views/ChatRowState.swift` (teammateReplies, botLabels), `Conduit/Views/ChatActivityRows.swift` (ChatStepSubject, ChatWorkingLine.currentToolTitle), `Conduit/Views/ChatRowDisclosure.swift` (how the notes open); a saved copy's rows are the chat's own while they stand in, folded from the rows drawn (`Conduit/Views/ChatRowState.swift`, ChatRowFacts.teammateReplies, worked out by `Conduit/Views/TranscriptModel.swift` once per change of the rows)
- Previews, quotes and speech: `Conduit/Services/PreviewText.swift` (strip), read by the chat list and spoken previews
- Tool categories: `Shared/Widgets/HermesTurnActivity.swift`, and its twin, `notifier/live_activity.py` (`tool_category`, notifier #338)
- The messaging protocol a bot is born with: `Conduit/Services/BotManagement.swift` (BotSoul)

**Rulings**
- A tag is sent as typed; Conduit only adds a note naming the teammate, and the bot sends with its own `message_agent` tool. Nothing is delivered from the phone (upstream Desktop's mention middleware).
- Mention a Bot inserts the same tag the @ list does, at the end of the draft (2026-10-24, #1181, Eric asked for an easier way to tag another bot).
- A user turn signed "Message from 🤖 Name", "Message from Name (@handle)" or "[Message from agent 'name']" is a teammate's delivery and reads as a note with the bot's face, its text one tap away. An unsigned "Message from Name: …" stays the user's text, unlike Desktop (2026-10-24, #1181).
- A `message_agent` call, or a terminal `hermes -p name chat … -q "Message from …"` run, reads as "Messaged Name" (2026-10-24, #1181).
- A step's subject line prefers a `message` field after the usual keys, for every tool, so a delivery shows what was said (2026-10-24, #1181).
- `message_agent` is a messaging tool on the Live Activity, in both the app's and the plugin's category lists (2026-10-24, #1181, notifier #338).
- A delivery previews as "Atlas: what it said" wherever `PreviewText` reads it (the chat list, spoken previews), and its body renders as Markdown. A quote is taken from the opened note's text, so it carries no signature. Read Aloud and live voice speak replies, never a delivery, so they need nothing (2026-10-24, #1192).
- The bot's replies to a delivery it didn't ask for fold under "Replied to Atlas" until the user next writes; a delivery answering the bot's own `message_agent` doesn't fold, and a reply still streaming stays open (upstream `dispatchedTo`, 2026-10-24).
- A terminal or `process` delivery's step shows the message, not the command, and the teammate's answer from the output as a note under it; a failed send (an error or non-zero exit) stays a plain tool step (2026-10-24).
- The working line says "Messaging Atlas…" while a delivery runs. The Live Activity keeps "Sending a message": it carries only a tool category, never names, by design (2026-10-24).
- A signature is read from the first 320 characters, so a message of any length is still a delivery; tool calls past 64 KB aren't scanned. A signed name may contain "(" ("Atlas (v2)") (2026-10-24).
- A "Messaged" step names the bot from the roster, and redraws when the roster loads (2026-10-24). Until Hermes' roster answers, the notes, replies and steps name teammates from the bots kept from its last answer, so a name doesn't change when it does, and the @ list, Mention a Bot and the note to the bot offer and name the kept bots; a tag for one Hermes no longer has reaches no one, as a mistyped tag does (2026-10-31, #1568).
- Group rooms have no Mention a Bot item: their recipient picks do the same job (2026-10-24).
- A delivery's note and a folded reply open and close like every other row: the chat's scroller hears first, so the tapped row stays put, and the choice outlives the row being rebuilt (2026-10-25, Eric's report: opening either one froze the app until iOS ended it).

**Open gaps**
- None known.

**Checked:** 2026-10-31, #1577 (TranscriptScroller is the scroller that hears first, now that chats draw on the transcript; Rulings); 2026-10-31, #1568 (teammates named, the @ list and Mention a Bot offered, and the note to the bot written from the kept bots until Hermes answers; a teammate's note reads the bots again once a change has landed, so the empty roster before Hermes answers never takes its name; Code); 2026-10-31, #1565 (the folded replies are worked out once per change of the rows drawn, not on each publish; Code); 2026-10-30, #1550 (a saved copy's notes and folded replies are drawn by the chat's own rows, folded as Hermes' rows will be); 2026-10-30, #1524 (Hermes Desktop's directives are read alongside, with their own entry, Cards made for Hermes Desktop); 2026-10-28, #1448 (an unnamed teammate is named by its id capitalized in its notes, replies and steps, through displayLabel); 2026-10-25, at #1259.

## Links in messages

A tap on a link in a reply opens it, the first time, wherever the reply is
drawn until a touch mounts its text view.

**Siblings:** chats, project chats and Bot Chat (one chat view) · group rooms ·
table cells once selection is on (plain cells open links through openURL; see Tables in messages) · VoiceOver and Switch Control (text view always mounted) · Voice Control and Full
Keyboard Access (the text view mounts and lays out when they ask for the
reply's elements) · long-press Open Link · file paths, linked to the Folder
(Workspace files)

**Code**
- Drawn until touched, mounted on touch: `Conduit/Views/Components/SelectableTextView.swift` (drawsUntilTouched, SelectableTextViewHostView.hitTest and accessibilityElements, mountTextViewForTouch)
- File paths: `Conduit/Views/Components/SelectableTextView.swift` (bridge), `Conduit/Services/WorkspaceFiles.swift` (WorkspacePathLinks), `Conduit/Services/ConduitAppLink.swift` (file), `Conduit/Services/AppState+Workspace.swift` (absoluteWorkspacePath, revealWorkspaceFile)
- Test: `ConduitTests/DrawnTextLinkTapTests.swift`
- Surfaces that draw until touched: `Conduit/Views/ChatView.swift`, `Conduit/Views/GroupChatView.swift` (selectableTextDrawsUntilTouched)

**Rulings**
- The touch that mounts a reply's text view is routed to it laid out, so it finds the link under the finger; a link never needs a second tap (2026-10-26, #1303, carried in #1311).
- A file path in a reply is a `conduit://file` link, drawn as a link, that opens the Folder at that file; only inside the app (2026-10-27, #1399).

**Open gaps**
- None known.

**Checked:** 2026-10-30, #1535 (table cells join the drawn-until-touched path once selection is on); 2026-10-29, #1491 (a room's pictures open in the picture viewer); 2026-10-27, #1399 (file paths); #1311 (carries #1303; Voice Control and Full Keyboard Access in Siblings).

## Markdown lists in messages

How a reply's lists read: numbering, loose lists, and the same list in every
view that draws Markdown.

**Siblings:** chat bubbles (block views and prose runs) · very long replies
(chunked) · selection and Copy · group rooms · tool results · call job cards ·
Read Aloud and live voice read-back · chat list previews and quotes

**Code**
- Parser and block views: `Conduit/Views/Components/MarkdownText.swift` (MarkdownParser, MarkdownList, MarkdownSelectionFormatter)
- Prose runs: `Conduit/Views/Components/MarkdownProseRun.swift`
- Long replies: `Conduit/Views/Components/MarkdownLargeDocument.swift` (splitListItems; LargeStreamPromotion while streaming), `Conduit/Views/Components/MarkdownLargeDocumentView.swift`, `Conduit/Views/Components/StreamingText.swift` (largeStableChunks)
- Selection: `Conduit/Views/Components/MarkdownSelectionCoordinator.swift`
- Copy response (copies the source): `Conduit/Views/ChatView.swift` (copyResponse)
- Other surfaces drawing MarkdownText: `Conduit/Views/GroupChatView.swift`, `Conduit/Views/ToolResultViews.swift`, `Conduit/Views/LiveVoiceCallJobs.swift`
- Spoken text (source lines, not parsed blocks): `Conduit/Voice/VoiceReadBack.swift`, `Conduit/Voice/SpokenTextFilter.swift`
- Previews and quotes: `Conduit/Services/PreviewText.swift`, `Conduit/Views/Components/ChatQuote.swift`

**Rulings**
- Ordered lists number as CommonMark and Hermes Desktop do: blank lines between items keep one list (2026-10-23, #1168), and a list starts at its first item's number, so steps split by a code block carry on; a marker is one to nine ASCII digits, anything else is text (2026-10-23, #1175, Eric).
- Every view that draws a list reads the parsed block, so a numbering change is a parser change plus each renderer's marker; long replies bake ordinals into continuation chunks (#1168).
- An item that is a Hermes Desktop card, or a preview where previews draw (`holdsDirective`), ends the list: the block draws on its own, and the items after it start a new list from the number written on the first of them (2026-10-30, #1524, see Cards made for Hermes Desktop).

**Open gaps**
- Nested lists are flattened: an indented sub-list draws as its own list at the left edge.
- Read Aloud and live read-back speak the numbers as written, so "1. 1. 1." is spoken 1, 1, 1 while the screen draws 1, 2, 3.
- Copy response under a reply copies the Markdown source, so "1. 1. 1." copies as written while the screen draws 1, 2, 3; selection Copy matches the screen where the list is selectable text (prose runs, one text view).
- A list drawn as a block view (outside a prose run, e.g. under VoiceOver or next to a task list) keeps its number outside the selectable text, so selection Copy leaves the number out.
- A reply that grows past the large-document size while streaming is parsed per promoted slice, so a list cut at a slice boundary carries on from the number written on the slice's first item (right when numbered 1, 2, 3; restarts for "1. 1. 1.").
- A marker past two digits ("100.") can crowd its column in the block view.
- A single list item too big for one long-reply chunk is split into paragraphs that each repeat its number.
- A long reply's continuation chunks draw list items as paragraphs with the number baked in, so they lose the list's styled marker column.

**Checked:** 2026-10-30, #1524 (a Desktop card ends a list; previews and quotes name it); 2026-10-28, #1449 (speech leaves Hermes' file tags out, see Files Hermes attaches); 2026-10-28, #1430 (speech no longer takes a `* ` item marker for the start of a narrated action); 2026-10-23, at #1175.

## Tables in messages

How a reply's Markdown table is drawn, selected and copied, in every view
that draws Markdown.

**Siblings:** chats, project chats and Bot Chat (one chat view: plain cells)
· group rooms and other Markdown surfaces (selectable cells from the start) ·
very long replies and big tables (paged) · the long-press menu (Copy Table,
Select Text), the pointer's Copy Table button, and VoiceOver's actions for them (Copy Table on every surface) · a pointer on a Mac or an
iPad · selection across the reply · Copy response · links in cells (plain cells open them through openURL, selectable cells as Links in messages does)

**Code**
- Tables, cells and the menu: `Conduit/Views/Components/MarkdownText.swift` (MarkdownTable, MarkdownTableRowView, MarkdownPlainCell, MarkdownTableMenu, LargeMarkdownTable; MarkdownTableLayout for column widths and Copy Table's text)
- Plain cells in the chat: `Conduit/Views/ChatView.swift` (markdownTablePlainCells)
- Long replies: `Conduit/Views/Components/MarkdownLargeDocumentView.swift`, `Conduit/Views/Components/MarkdownRichContent.swift` (isComplexTable)
- Selection: `Conduit/Views/Components/MarkdownSelectionCoordinator.swift` (deferRegistration, which mounts a waiting table when a selection begins)
- Selectable cells, drawn until touched in the chat: `Conduit/Views/Components/SelectableTextView.swift`

**Rulings**
- The chat draws table cells as plain text, the cheapest to build as rows scroll in (#693). A long press offers Copy Table and Select Text; Select Text draws the cells as selectable text until the row is taken down.
- Selection on a table turns on as it does for the reply's drawn text: a selection that starts elsewhere in the message mounts the cells, so a drag from the text above or below carries into the table, and a pointer over the table (a Mac, an iPad's trackpad or mouse) turns it on, so a click and drag selects in a cell and Cmd+C and the context menu's Copy work (2026-10-30, issue 1531, #1535; Eric: most selections start in the text around the table).
- A pointer over a table (a Mac, an iPad's trackpad or mouse) shows a Copy Table button at the table's top right, on every Markdown surface, since the cells' own right-click menu replaces the table's (2026-10-30, Eric, #1540).
- VoiceOver's Copy Table is on every table, whether or not selection is on, group rooms' included: a VoiceOver user selecting cell by cell has no other way to take the whole table (#1535).

**Open gaps**
- On a touch screen, once selection is on (Select Text, or a selection elsewhere in the message), the long-press menu is the text's own, so Copy Table is gone for that table until its row is taken down; selecting across the table copies its cells, and Copy response copies the reply.
- No Copy cell or Copy row (asked for as optional in issue 1531).
- The pointer's Copy Table button covers the corner of the last header cell while the pointer is over the table.
- A big table mounts its rows in batches (`LargeMarkdownTable`), and a selection copies only mounted cells, so a selection across a table past its first batch leaves the rest out until Show more; Copy Table copies every row.

**Checked:** 2026-10-30, #1540 (the pointer's Copy Table button); #1535 (a selection in the message mounts the cells; VoiceOver's Copy Table kept).

## Attaching files

Photos, camera shots and any other file go into the composer as
attachments, staged on the device and sent with the next message.

**Siblings:** chat composer (chats, project chats, Bot Chat) · the full
editor · group rooms · the composer's text field (pasted pictures, long
pasted text, files dropped on it) · iPad and Mac (the same fields; Cmd-V
and Paste and Match Style) · the sent message and a room message (a paste
reads "Pasted text") · Hermes Desktop (the same threshold and file name) ·
README.md's feature list

| Way in | Chat composer and its full editor | Group room and its full editor |
|---|---|---|
| Attach › Camera, Photo Library, Document | yes | yes, with a plugin that stores room files |
| A picture pasted in the field | yes, one picture | no |
| Text pasted in the field, over 3,000 characters | yes, as a text attachment | yes, with a plugin that stores room files |
| Files dragged onto the chat, the room, the field or the full editor | yes | yes, with a plugin that stores room files |

**Code**
- Staging and its limits: `Conduit/Views/Components/ComposerAttachments.swift` (AttachmentSizeLimit, AttachmentTypePolicy, AttachmentStaging's stageCopy and finishStaging)
- Dropped files: `Conduit/Views/Components/AttachmentDrop.swift` (AttachmentDrop, attachmentDropTarget), `Conduit/Views/ChatView.swift` and `Conduit/Views/GroupChatView.swift` (the drop targets), `Conduit/Services/AppState.swift` (dropIntoComposer, dropIntoRoomComposer), `Conduit/Views/Components/ComposerFullEditor.swift` (onDropFiles)
- Chat composer: `Conduit/Views/Components/ComposerBar.swift` (attachmentButton, handleDocumentSelection, handleDroppedFiles, handlePastedImage, attachLongPaste, pastedTextActions), `Conduit/Views/Components/ComposerPasteTextView.swift` (paste(itemProviders:), onDroppedFiles)
- Long pastes: `Conduit/Views/Components/PastedTextAttachment.swift` (PastedText: threshold, name, staging; PastedTextSheet), `Conduit/Views/Components/ReturnKeyTextView.swift` (onLongTextPaste, paste and pasteAndMatchStyle, for every composer field), `Conduit/Views/Components/ComposerAttachments.swift` (ComposerAttachmentChip, AttachmentTypePolicy.displayName), `Conduit/Views/ChatView.swift` (UserDocumentAttachmentChip), `Conduit/Views/GroupChatView.swift` (GroupMessageFiles)
- Group rooms: `Conduit/Views/Components/GroupRoomComposer.swift` (attachButton, importDocuments, importDroppedFiles, finishImport, attachLongPaste, pastedTextActions)
- Tests: `ConduitTests/ComposerAttachmentPolicyTests.swift`, `ConduitTests/PastedTextAttachmentTests.swift`, `ConduitTests/ComposerPasteTextViewTests.swift`

**Rulings**
- Every way in stages the same way: copied into the staging folder, size checked against the device's limit before it is read, images providers can't read re-encoded as JPEG, and anything left out named in the composer's notice. Nothing is sent until the user presses Send (2026-10-28, #1411).
- A drop attaches files and leaves the rest: words dragged from another app go into the draft only when dropped on the field, and a link stays a link. Text counts as a file only when it comes as a named file. One picture dropped or pasted on the field keeps the picture paste; several items, or any other file, are staged like picked documents (2026-10-28, #1411, from #1408).
- A locked chat composer takes no drop, as its Attach menu is off then; a room on a plugin that can't store its files says what fixes it, as its Attach menu does (2026-10-28, #1411).
- A dropped folder is taken but not attached: the composer's notice names it and says to drop the files inside. Files dropped with it still attach (2026-10-28, #1422).
- Text pasted in a composer field (inline or full editor, chat or room) over 3,000 characters, Hermes Desktop's threshold, goes in as a removable text attachment instead of into the field: a `.txt` named as Desktop names a paste (`pasted_content_<time>_<hex>.txt`), staged and sent like any file, so Hermes puts its text in the prompt through the `@file:` reference and a reopened chat, here or in Desktop, shows it as pasted text. Pasted over a selection, it still replaces the selection. Its chip shows the first words; a tap shows the whole paste to read or edit, and Paste as text puts it back in the field after what was typed, and clearing its text removes it, as × does. The file is written off the main actor; if it can't be written, the words go into the field after all. Only the Paste command (`paste(_:)`: Cmd-V, the edit menu, the keyboard's Paste) attaches it; words that come through the item-provider route, dropped or from a keyboard action, stay words, so the clipboard is read only when the user pastes. A shorter paste, a picture, or a paste where the composer can't take files (locked, a chat still on its way, whose waiting message is words only, or a room on a plugin that can't store files) goes into the field as before, and so does one too big for the attachment limit, which can't go as a file. Dropped words stay words, as above. The message also sends the paste's first 1,000 characters as `title_preview`, as Desktop does, so a chat that opens with a paste gets a title from its words, not its file name; a Hermes that refuses the key gets the message without it (Eric asked for it, 2026-10-29, #1515).
- A paste is an attachment like any other: while Hermes replies it goes as Queue (#1154), `/new` in a Bot Chat refuses it, Edit and resend is off for its message, and the draft keeps it. Paste as text turns it back into words to Steer with (2026-10-29, #1515).

**Open gaps**
- A dropped folder's files aren't attached for the user; they drop the files themselves.

**Checked:** 2026-10-29, #1515 (long pastes become text attachments); 2026-10-28, #1422 (folder drops say why they aren't attached).

## A chat while it opens

A chat that's opened again shows what it had at once, while Hermes sends
the rest, instead of a blank chat.

**Siblings:** chats and project chats · Bot Chat · group rooms · a cold
launch and a chat picked in the saved Chats list (the same read-only copy) ·
a profile switch (the chat the new profile opens on), whether from the strip,
the picker, CarPlay, or a chat opened in another profile from All chats, a
notification, a link, a widget or a Shortcut · iPad and Mac windows (the same chat view) · Settings' Data handling caption ·
the notifier's history page route (`POST /sessions/history-page`, its README section and changelog) ·
Load earlier (not needed: it reads past the newest page, where the phone holds no rows to stand in) ·
voice's reads of a chat (the last reply read back, a voice row's history): their newest page goes through the history page too ·
what the saved rows draw, the chat's own rows (each with its entry): message row actions, bot mentions and teammate messages, steps in a turn, pictures in messages and the picture viewer, cards drawn in web pages, self-improvement updates, and bars lists scroll under ·
docs/PLAN_CARD.md (not needed: the plan card still doesn't show while saved rows stand in, as it says) ·
Watch and CarPlay (not needed: neither shows a transcript)

| Opening | Shows while it loads | Kept |
|---|---|---|
| A chat or project chat | its saved copy (the rows it had loaded when it was left, up to 500), drawn as its own rows until Hermes' replace them in place | on the phone, the last 100 chats left per dashboard and profile while their files fit 64 MB (the newest always stays); in memory, the last 16 read, saved or read ahead while their files fit 32 MB, and each dashboard and profile's saved Chats list and list of its copies once read or saved, with no budget, until a sign-out, a removed dashboard or Delete saved chats. Once the live list is in, the copies of the 6 chats opened last in the profile are read ahead, and for a switch each other profile's saved list and last chat, into room memory has free |
| A Bot Chat | the copy kept when it was left (after a `/new`, the compacted chat as it showed), drawn the same way | in memory, per dashboard and bot, one per bot, up to 500 rows (its newest page's raw rows, for the history page, are kept on the phone under the bot's profile like any chat's, until the bot is deleted or they're pruned) |
| A group room | the events it had | in memory, per dashboard and room, up to 400 events, until the room leaves the list |
| A chat never opened | nothing, as before | not applicable |

**Code**
- Chats: `Conduit/Services/AppState.swift` (performSessionOpenNotingRefusal and its landing from saved rows, savedRowsEndMidTurn, presentSavedCopyWhileOpening, recordOfflineChatCopy; presentRestoredChatAfterProfileChange and its rollback in switchProfile; prefetchSavedChats from savedChatListReplacedByLiveList; makeDefaultOfflineChatCache; holdBackgroundTaskUntilCacheWritesLand), `Conduit/Services/OfflineChatCache.swift` (loadTranscript, keptTranscripts; writesAsynchronously: record, recordChatList and recordHeldRows on the store's queue, the removals' performAndWait, keptIndexes and keptChatLists; unchangedEntry; prefetch; OfflineCachedMessage.rowId)
- The saved rows drawn as the chat's: `Conduit/Services/AppState.swift` (chatRowsOnScreen, savedCopyScrollSessionKey, chatOnScreenIsBusy, chatImageGallery), `Conduit/Views/ChatView.swift` (the scroller fed chatRowsOnScreen, and told when saved rows Hermes' matched leave; drawnScrollSessionKey, and drawnOrFallbackScrollSessionKey, which names the conversation the rows' kept heights go by (drawnConversation); transcriptTopBar, savedCopyStatus, quotedReplyJump, transcriptBackfillAvailable), `Conduit/Views/TranscriptModel.swift` (rows, in order: Load earlier, the saved copy's status or an empty chat's welcome, the chat's rows, the live turn's and a send waiting; the status and the welcome follow the rows drawn, never while the chat's rows are on their way to the scroller, as on a new view's first pass), `Conduit/Views/OfflineChatBanner.swift`, `Conduit/Views/ChatRowState.swift` (ChatRowFacts, from the rows drawn, which TranscriptModel works out; isOffline keeps Hermes' actions off), `Conduit/Services/TranscriptScroller.swift` (transcriptChanged's isProvisional; replyStartLandingRequested's transition, which the open's own switch keeps; see Following the latest message), `Conduit/Services/AppState+PendingSend.swift` (a message waiting under saved rows is scrolled to)
- The newest page's rows, read without the ones the phone holds: `Conduit/Services/HistoryPage.swift`, `Conduit/Services/AppState.swift` (historyPagePayload, from fetchPersistedHistoryPayload and voiceHistoryPage, which latestSavedThreadReply and voiceRowMessages read through), `Conduit/Services/DashboardTicketBridge.swift` (requestJSON's readsOnly: the read fails with the page on a sign-out, as a GET does; receive parses its answer, as every request's, off the main thread when it's over 64 KB, as a long chat's page is, and where it arrives when smaller, then hands it to answer on the main actor), `Conduit/Services/OfflineChatCache.swift` (heldRowsFileURL, loadHeldRows, writeHeldRows through recordHeldRows, removeHeldRows from deleteBot; boundedTranscripts for the copies' budget); notifier: `notifier/dashboard/api/history.py`
- Bot Chat: `Conduit/Services/AppState.swift` (keepBotChatCopy, botChatCopyOwner, noteBotChatOpen, outgoingBotChatCopyOwner and where it's cleared: flushPendingPresentationCache, performSessionOpenNotingRefusal, switchDashboard, createNewSession; presentKeptBotChatCopy, keptBotChatCopies)
- Group rooms: `Conduit/Services/AppState.swift` (openGroupRoom, parkActiveRoomSend, keptRoomReplays; chatSyncErrorMessage, chatErrorBehindRoom and closeRoomSurfaceBackToChat for the chat's error under a room)
- Tests: `ConduitTests/OfflineChatCacheTests.swift`, `ConduitTests/ChatScrollStateTests+TranscriptModel.swift` (the rows drawn, the saved copy's status and the welcome), `ConduitTests/TranscriptScrollerTests.swift` (testHermesRowsAfterSavedOnesDoNotArmTheHold, testASwitchKeepsTheLandingItsOwnOpenAskedFor, testASwitchDropsALandingAnEarlierOpenAskedFor), `ConduitTests/HistoryPageTests.swift`, `ConduitTests/GroupChatSessionSafetyTests.swift`, `ConduitTests/CrossProfilePresentationCacheTests.swift` (testTheOutgoingTranscriptLeavesWhenTheProfileChangesOver), `ConduitTests/AppStateChatResumeTests.swift` (testAChatSyncErrorWaitsBehindAnOpenRoom); notifier: `notifier/tests/test_history_page.py`, `notifier/upstream/test_history_page.py`

**Rulings**
- A chat that opens with saved rows (opened again, a Bot Chat's kept copy, the chat a launch or a profile switch opens on, a chat picked in the saved list) shows them as its own: the chat's scroll view draws them, provisional until Hermes answers, and Hermes' rows replace them by id in the same update, so the rows still there stay where they are and nothing is laid out again. They never enter the live transcript, so approvals, paging, resume and sends never read them, and while they stand in nothing that needs Hermes' word acts on them (Edit and resend, Retry, Branch, reactions, pins, Read aloud, Explain, a "Replying to" jump, Load earlier). The offline banner shows only while Hermes can't be reached. An unread chat whose saved rows end mid-turn lands at that turn's reply start from them, since Hermes' rows start there too (2026-10-30, #1550, from issue #1533: Eric replaced #1404's ruling, under which the copy was an overlay the live transcript replaced wholesale, with this).
- Copies are kept per dashboard and profile (Bot Chat: per bot), so another profile's history never shows (2026-10-27, #1404).
- A profile switch takes the outgoing profile's transcript, and any reply still streaming into it, off the screen as the profile changes over: the chat the new profile opens on shows its saved copy (a Bot Chat, its kept copy), or nothing, until Hermes sends it, and a chat opened in that profile replaces it as it opens. It used to stay up under the new chat's title for the whole switch, several seconds on a real dashboard. A switch that fails puts the outgoing chat and its transcript back as they were, over a chat opened during the switch (the transcript never onto another dashboard), until the reconnect resolves it (2026-10-28, #1447, Eric asked for it, from issue #1442).
- A group room on screen shows only its own errors. The chat under it can still sync (a return to the app), and its error used to land in the room's banner, read as the room failing (issue #1459). A chat sync's error raised while a room is on screen waits and shows when the room closes back to that chat (closed, or gone: disbanded or not found); opening another chat or a new one, switching profile, a reconnect or the chat resuming meanwhile drops it (2026-10-28, #1461, from issue #1459, which Eric asked to fix).
- A chat's newest page is read through the notifier's history page route when the plugin lists `history-page` (plugin 0.121+): the plugin reads Hermes' own `/messages` page and sends each row the phone kept from the last read as its fingerprint, and Conduit puts those rows back in place, so the page it reads is Hermes' answer row for row; an edit, an /undo or a compaction changes a row's fingerprint and that row comes in full. The kept rows are Hermes' raw rows, never the saved copy, which stays presentation only; they're kept for the last 100 chats read per dashboard and profile within 32 MB, beside the copies' 64 MB, and kept only when nothing was removed from the saved chats during the read (a sign-out, a removed dashboard, Delete saved chats, a deleted chat, a deleted bot, whose held rows go with it) and the same sign-in still holds. A host that can't serve the route for a profile (405, 501) isn't asked again that run. A refusal from the route (an older Hermes, a profile that turned the plugin off) or a fingerprint the phone no longer holds reads Hermes' route instead; the link's own trouble fails the read as Hermes' route would. Every open still reads the page: issue #1525's skip-the-read on a matching chat-list stamp was left out, since the list can be older than the chat on a dropping link (2026-10-30, #1536 and notifier #477, from issue #1525, Eric approved).
- Saving for a chat never runs on a tap: the app's store writes copies, held rows and the saved Chats list on its own queue and answers from memory meanwhile (a list as soon as it's given, a copy or an index once written), and a copy left again unchanged within 5 minutes isn't written again. A removal (a deleted chat, a deleted bot's held rows, Delete saved chats, a sign-out, a removed dashboard) waits for the saves queued before it, so it still takes them and the held rows' check before their write still holds. Once the live list is in, what a tap shows next is read ahead into memory (2026-10-30, #1545, Eric asked for loads to move to the background and every screen to show its last saved state at once, from issue #1533).
- A Bot Chat's copy is kept only for the bot owning the id the chat is open as (the registry first, then the roster and the saved last-chat reference). The chat's other ids never decide the bot: the scroll identity's aliases can name the chat it replaced, another bot's, so an ordinary chat left after a Bot Chat keeps no copy for it, and reopening one bot never shows another's chat. The owner is taken before a bot open notes its own ids, so a bot opening as the same id never takes the copy of the chat being left (2026-10-28, #1432).

**Open gaps**
- A chat whose live transcript lands somewhere other than its newest row moves there at the handover: a restored reading place, and an unread reply when the saved rows already had one (Hermes' rows can start a newer turn below them, so that landing waits for them).
- Saved rows older than Hermes' newest page leave the screen when it lands, since the live transcript starts at that page (Load earlier brings them back): a reader who scrolled up into them is moved (#1550).
- While saved rows stand in they show no pins, and the pinned replies bar and the plan card wait for Hermes' rows: both are read from the live transcript. An open choice made on a chat picked in the saved list (a run of steps opened) closes when the chat opens, as the choices follow the live chat (#1550).
- Bot Chat copies and group room events are memory only, so they don't outlive Conduit being stopped (a Bot Chat's held raw rows do, but only stand in for rows of a later read, never show on their own).
- An error already on the chat when a room opens is cleared by the open (openGroupRoom) and doesn't come back when the room closes; only a sync error raised while the room is up waits (#1461 review). `errorMessage` holds non-chat errors too, so carrying it needs a rule for which ones are the chat's.
- Settings' Data handling caption says recent conversations, and what each screen last showed, are kept so Conduit opens straight to them while it connects (#1552). It doesn't mention a chat reopening where it was, since that keeps nothing more on the device.
- A chat opened that wasn't read ahead (past the 6 opened last in its profile, or opened before the live list landed) reads its file on the main thread the first time, up to 500 rows; a launch reads the chat it opens on and its saved list there too, as they're its first frame (#1404, #1536, #1545).
- A removal waits on the main thread for the saves queued before it (reads ahead still queued skip themselves): at most a long chat's copy being written or one being read ahead, tens of milliseconds (#1545).
- A 404 from the history page route isn't remembered, since Hermes' own "no such chat" comes through as one: a profile whose plugin is off while the dashboard still lists `history-page` reads Hermes' route after it on each open (#1536 review).
- A deleted chat's held rows go with it under the ids the delete names and their saved aliases; under an id neither names they stay until the scope's held rows are pruned (#1536 review).
- While saved rows stand in, VoiceOver reads them with no "opening" announcement; the header and composer say Conduit is connecting, as for a chat picked in the saved list (#1404, #1550).

**Checked:** 2026-10-31, #1577 (the saved rows are drawn by the chat's transcript, where Hermes' rows replace them by id with the heights they measured; TranscriptScroller keeps their scroll rules; Code, Tests); 2026-10-31, #1566 (TranscriptScroller keeps the saved rows' scroll rules, not called yet; nothing changes; Code); 2026-10-31, #1565 (TranscriptModel decides the rows the chat draws, the saved copy's status and an empty chat's welcome among them, from the rows the engine has, and not while the chat's rows are on their way to it; nothing on screen changes; Code); 2026-10-31, #1552 (the open profile's kept settings answers are read ahead with its chats); 2026-10-30, #1550 (saved rows drawn as the chat's own and replaced in place, Eric's ruling replacing #1404's; an unread chat left mid-turn lands from its saved rows); 2026-10-30, #1547 (the saved lists and lists of copies kept in memory, in Kept; the newest page's answer parsed off the main thread when it's big, in Code); 2026-10-30, #1545 (copies, held rows and saved lists saved on the store's queue; recent copies and other profiles' lists read ahead into memory); 2026-10-30, #1536 (the newest page read without the rows the phone holds, through notifier #477; copies keep up to 500 rows for 100 chats within 64 MB); 2026-10-28, #1461 (a chat's sync error stays out of a room on screen); 2026-10-28, #1447 (a profile switch shows the new profile's chat, not the outgoing transcript); 2026-10-28, #1432.

## Screens that open on their last answer

A screen that reads Hermes draws what Hermes told it last time at once,
kept on the phone, while it asks again, and the new answer changes only
what changed.

**Siblings:** the agent settings pages: Model (Default model, Fast mode and
limits, Fallback models), Chat, Workspace, Memory & delegation (Delegate
model, Pause delegation) and Advanced · Settings > Pulse and What Pulse
remembers · Settings > Usage · Voice settings (the setup steps, the provider
sections, the API keys, Speech to text's speech server, Local's fast model
and the Voice replies model) · the models the model sheet, the bot
editor's Model page and the Voice replies, Voice jobs and Settings > Pulse
model pickers list (the `model.options` answer Usage keeps; the model sheet
asks for its chat's session) · the saved chats, whose wipes take the kept answers (Delete Saved
Chats, a sign-out, a removed dashboard; a deleted bot takes its own) ·
Settings' Data handling caption and the Delete Saved Chats confirmation ·
the Bots list: its bots, Desktop's groups, the hosted rooms and their
pictures, and the bots' faces (done) · the teammate names chats and rooms
show (done: from the kept bots until Hermes answers, so a name doesn't
change) · Capabilities' tabs: the installed skills and toolsets, the
official skills, the year's tool calls, the MCP servers and catalog, and
the plugins and plugin catalog (done) · the Kanban task composer's skill
picker, which lists the installed skills (done) · the Kanban model
override's roster (done) · the Tasks board: its
boards, the board shown and its cards, the profiles, projects and
orchestration settings (done) · the Artifacts lists: the Artifacts page, a
chat's own (its sheet or the panel beside it) and Bot Chats' (done) · the
Folder tab: a folder's listing and Recently Changed, in Artifacts and the
drawer shell's Workspace (done) · Capabilities' pages: a skill's SKILL.md,
a catalog skill's preview, a toolset's backends and keys, and where the
terminal runs (done) · the bot editor: Edit Bot's personality, model,
skills, tools and MCP servers, New Bot's Start From lists and the MCP
page's catalog and sign-ins (done) · Assistant speech on the speech server (opens on no
kept answer: the notifier's status answers with the server's key, which is
never kept, and the server's address and steps hang on it; done: a read
that fails keeps the status shown, and the section reopened on the page
opens on the one held in memory) · voice itself (not needed:
AppState's voice check reads Hermes each time, and the pages keep what they
read) · the live voice modes' status lines on Voice settings (Gemini Live,
Qwen Live, Grok Live, GPT-Live; done: each opens on what its last check
said, GPT-Live's per billing, kept as the line it showed, since the check's
answer names its sign-in under `auth`, which the store leaves out. Local
Live's is its fast model, above) · the Pulse screen (not needed: its cards are their own feed; Quiet
for today there keeps the state Pulse answers with, which Settings > Pulse
opens on) · a Pulse notification's Quiet for today (done: it keeps the state
Pulse answers with too) · Watch and CarPlay (not needed: neither shows these
screens) · the notifier (not needed: the pages read the same routes) ·
README and docs (not needed: neither describes these pages' loading)

**Code**
- Store: `Conduit/Services/OfflineChatCache.swift` (keptAnswer, recordAnswer, withoutCredentials and withoutUnparsedURLCredentials, trimKeptAnswersLocked, removeKeptAnswers, readKeptAnswersAhead from prefetch's answers, forgetMemory; lastOpenedRoutePrefix, whose answers keep the newest maxLastOpenedAnswers per scope through removeOldestFiles, as the held rows do, and removeLastOpenedAnswers, which takes a deleted chat's by the session ids its route names (sessionIDs(namedIn:)); KeptAnswers, how Voice settings, Capabilities, the Tasks board, Artifacts and the Folder tab reach them)
- Reads and saves: `Conduit/Services/AppState.swift` (KeptRoute, readKeepingAnswer, keepingAnswer and its writes, keepWrittenAnswer, noteKeptAnswerWrite, keepAnswer and keptAnswerTurns, keptAnswer(on:) for a write's dashboard, keptProfileSettings, keptProfileConfigOptions, keptProfileModelDefaults, keptProfileConfigSchema, keptProfileFallbackModels, loadDelegationPaused, setDelegationPaused and keptDelegationPaused, loadModelProviders, keptModelProviders and modelProviders, loadVoiceReplyModel and keptVoiceReplyModel, keptLiveVoiceStatus, liveVoiceStatusKeeper and gptLiveStatusKeeper; updateProfileConfig and setProfileSetting keep what they saved, setProfileMainModel reads the catalog and the model's info again, and setVoiceReplyModel the slots, saying why when Hermes doesn't take one; prefetchSavedChats; deleteBot; deleteSavedChats)
- Pages: `Conduit/Views/AuxiliaryViews.swift` (KeptAnswerGate, ProfileConfigSettingsPage's showKept, reload and answerChanges, ProfileModelSettingsDetail, DelegationModelSettings, DelegationPauseSettings, FallbackModelsSettings, ChatSettingsDetail, MemorySettingsDetail; AboutSettingsDetail's caption and confirmation), `Conduit/Views/V2/V2SettingsTab.swift` (a profile or dashboard switch starts the Settings stack over, so no page outlives its own)
- Pulse: `Conduit/Services/AppState+Pulse.swift` (pulseClient and quietPulseForToday keep what PulseClient.keptRoute names, keptPulseState, keptPulseMemory, forgetKeptPulseMemoryItem), `Conduit/Services/PulseSettings.swift` (PulseClient.keptRoute, memoryItems), `Conduit/Views/PulseSettingsViews.swift` (PulseSettingsPage's showKept, its models included, answered and waiting, and reload, which offers Try again before Pulse ever answered; PulseMemoryList's showKept and forget)
- Usage: `Conduit/Services/AppState+Usage.swift` (loadUsageReport, keptUsageReport, loadProviderQuotas, keptProviderQuotas), `Conduit/Models/UsageReport.swift` (route), `Conduit/Services/HermesClient.swift` (modelOptionsAnswer), `Conduit/Views/UsageSettingsViews.swift` (showKept, also from the period picker, the line over kept numbers offline)
- Voice: `Conduit/Voice/HermesVoiceConfigurationService.swift` (KeptRead, keptSnapshot, answered, isChecking, awaitsKeys, keeping, putConfig, reload's kept toolsets and schema and its reason with nothing shown (isRouteMissing), lastEnvironment, speechServerStatus, speechServerVoiceStatus, rotateSpeechServerVoiceKey and lastFrontModel), `Conduit/Views/SpeechServerVoiceSettingsView.swift` (load, read, show, readError, rotate), `Conduit/Voice/SpeechServerTranscription.swift` and `Conduit/Voice/SpeechServerSpeech.swift` (the statuses' readFailed), `Conduit/Views/VoiceSettingsView.swift` (hermesStep, the speech steps, advancedSection, classicSpeechNeedsAttention, answeredValues, privateVoiceRow's picks and usePrivateProvider, VoiceProviderFieldEditor's ready and its choice saved when picked), `Conduit/Views/VoiceAPIKeyRow.swift` (its field waits on awaitsKeys), `Conduit/Views/SpeechServerSettingsView.swift` (showKept, answered, read and readFailed), `Conduit/Views/LocalLiveViews.swift` (LocalLiveFrontModelSettingsView's showKept, loaded, read and readFailed), `Conduit/Views/GeminiLiveViews.swift` (VoiceJobModelSettingsSection's kept models, VoiceReplyModelPicks, VoiceReplyModelSettingsSection's showKept, read, save and pageIsChecking, LiveVoiceStatusLine, GeminiLiveSettingsSection's status line), `Conduit/Views/GrokLiveViews.swift` and `Conduit/Views/GPTLiveViews.swift` (the status line's keptStatus and keepStatus), `Conduit/Services/AppState.swift` (voiceSettingsAnswers), `Conduit/Views/AuxiliaryViews.swift` (VoiceSettingsRoute's answers, kept models and kept status lines)
- Model pickers: `Conduit/Views/ModelPickerView.swift` (KeptModelCatalog, the model sheet's onAppear and loadModels), `Conduit/Views/BotModelPicker.swift` (load, its rows waiting for the answer), `Conduit/Services/AppState.swift` (loadModelProviders(sessionId:))
- Bots list: `Conduit/Services/AppState.swift` (KeptRoute.botRoster and groupRooms, keepingRead, keptRead and keptAnswerTurn; performBotRosterRefresh and refreshGroupRooms keep what they read; shownBotRoster, shownBotRosterChanged, shownDesktopGroupChats and keptBotRoster; shownGroupRooms, groupRoomsListed and keptGroupRooms; botAvatarImage's picture kept on the phone; groupMemberBot; updateBot, setBotPinned, setBotHidden and duplicateBot refuse a kept bot; deleteBot's forgetKeptBot, for the dashboard it was deleted from; keepGroupRoomPictures keeps a picture set or removed here; openGroupRoom asks whether Hermes hosts rooms first; prefetchSavedChats reads the dashboard's own answers ahead), `Conduit/Services/GroupRoomPictures.swift` (groupRoomPicture, keptGroupRoomsNow, adoptKeptGroupRoomPictures, setGroupRoomPicture, keptBytes), `Conduit/Services/BotModeModels.swift` (KeptBotRoster and cappingPictures, BotProfile's CodingKeys and isKeptCopy), `Conduit/Services/GroupChatModels.swift` (KeptGroupRooms, DesktopGroupChat's CodingKeys), `Conduit/Views/BotRosterView.swift` (the shown bots and rooms, canStartGroups, BotMonogramView fetching again on connecting), `Conduit/Views/GroupChatView.swift` (GroupMemberAvatar likewise, the members' names), `Conduit/Views/ChatView.swift` and `Conduit/Views/ChatRowState.swift` (teammate names)
- Bot editor: `Conduit/Services/AppState.swift` (KeptRoute.botDetails and botMcpSetup; loadBotDetails, loadBotCapabilities (readBotDetails) and loadBotMcpSetup keep what they read through keepingRead, and keptBotDetails, keptBotCapabilities and keptBotMcpSetup give it back; keepWrittenChange keeps a write Hermes took over any read asked before it: updateBot's description, SOUL and the capability sections Hermes took (keepBotDetailsWritten), saveBotModel's model, addBotMcpServer's server (keepBotMcpServerAdded) and signInBotMcpServer's sign-in; ChatResumeLifecycleOperations' describeBotProfile and botMcpSetup seams), `Conduit/Services/BotManagement.swift` (BotProfileDetails, BotCapability and BotCapabilities Codable; BotCapabilities.taking), `Conduit/Services/BotMcpSetup.swift` (BotMcpServerSummary's `sign_in`, BotMcpSetupSnapshot's servers kept as a list), `Conduit/Views/BotEditorSheet.swift` (seedShown before the first frame; keptDetails and showsKeptDetails, the SOUL, model and lists read-only until Hermes answers; keptCapabilities and showKeptStartFrom; one capabilities link for the kept lists and Hermes'), `Conduit/Views/BotCapabilitiesView.swift` (editable; rows keyed by name; mcpSetupKept and canSetUpServers)
- Capabilities: `Conduit/Services/CapabilitiesStore.swift` (KeptRoute, KeptList and showsKept, configure's answers and showKept, read, keptJSON and rows; loadOfficialSkills, loadToolCalls, loadConnectors and loadPlugins keep what they read; installSkill, setServerEnabled, removeServer, installConnector, setPluginEnabled, removePlugin and keepChange keep a change Hermes took in the answers taken before it went out, noting one with nothing kept to change, as installConnector, installPlugin, updatePlugin and saveServer do for the row Hermes' answer brings; readKeptServersAgain tests a kept list it reads again, as installConnector and saveServer do one Hermes' answer replaced, and probeServers only the servers Hermes listed; markCatalog and keepCatalog keep the plugin catalog's flags with an install, update or removal; loadConnectors and loadPlugins leave a kept catalog whose read failed in showsKept, and loadPlugins takes a cancelled read for none; skillContent, skillPreview, toolsetConfig and terminalBackends keep what they read, a page's under KeptRoute.page, and keptSkillContent, keptSkillPreview, keptToolsetConfig and keptTerminalBackends give it back; selectProvider, selectTerminalBackend and saveKey keep a change Hermes took in the page's kept answer through keepChange), `Conduit/Models/CapabilityCatalogModels.swift` (ConnectorServer's keptCopy and origin, its CodingKeys, ConnectorCatalogEntry's; PluginCatalogEntry.isSource, the entry a plugin came from; ToolsetConfig.choosing and settingKey and TerminalBackendOption.choosing, a page's answer, and the config or backends it shows, as Hermes holds them after a change), `Conduit/Services/AppState.swift` (KeptRoute.skills and toolsets; loadCapabilities and loadToolCatalogIfNeeded keep what they read, the toolsets through readKeepingToolsets, which keeps no empty list; showKeptCapabilities, capabilitiesAreKept, keepFlip, screenAnswers, the dashboard's they were made for), `Conduit/Models/Models.swift` (CapabilitySkill's and CapabilityToolset's ids, by name), `Conduit/Views/CapabilitiesView.swift` (Scope, the dashboard's id included, and configure before the first frame, loadForSearch), `Conduit/Views/Capabilities/CapabilitySkillsTab.swift` and `Conduit/Views/Capabilities/CapabilityToolsTab.swift` (a kept list asks again; the bulk switches wait; CapabilitySkillDetailPage, OfficialSkillDetailPage and CapabilityToolsetDetailPage open on their kept answers, showKept; choose, select and save show a change as Hermes took it, kept or not, before they read again; offline, the backend, key and Install controls are off, a catalog skill's row's Install too), `Conduit/Views/Capabilities/CapabilityConnectorsTab.swift` and `Conduit/Views/Capabilities/CapabilityPluginsTab.swift` (no loader over a kept list; a kept list or catalog asks again; ConnectorDetailPage tests a kept server once Hermes lists it, and shows its address and command once Hermes answers), `Conduit/Views/Kanban/KanbanTaskComposerView.swift` (KanbanSkillsPickerSheet)
- Tasks board: `Conduit/Services/KanbanService.swift` (answers, KeptRoute, decode's keptAs, keeping only an answer that decodes and that keepsIf takes, kept), `Conduit/Services/KanbanStore.swift` (configure's answers, offline too, and answers that name the dashboard late, until Hermes lists the boards (boardsAnswered); showKept and keptBoard; selectBoard shows the board picked as kept; reload says to connect over a kept board), `Conduit/Views/KanbanViews.swift` (configureStore before the first frame and on a switch before the next, with screenAnswers, and configuredServerKey, which the board waits for; pollingKey and serverIdentityKey name the dashboard; taskCard keeps a kept or switching board's cards read-only while the board scrolls; the Loading capsule gives way to a failed read's), `Conduit/Models/KanbanModels.swift` (KanbanBoard leaves out Hermes' clock); the model override: KanbanService's KeptRoute.modelOptions and offerable, a roster with none not kept, KanbanStore's keptModelOptions, `Conduit/Views/Kanban/KanbanTaskComposerView.swift` (KanbanModelOverrideSheet's showKept and optionsAnswered)
- Artifacts: `Conduit/Services/Artifacts.swift` (ArtifactsClient's page keeping the list as it opens, keptRoute and keptPage), `Conduit/Views/V2/V2ArtifactsViews.swift` (ArtifactsList's showKept, before the first frame and in reload; Reading, which reads again once the plugin says it serves artifacts; a failed bot store's kept rows; content: the update notice only once the plugin rules artifacts out, the loader or offline why with nothing kept, and a list kept empty saying so at once, offline too; reload asking the plugin again when it never answered), `Conduit/Services/AppState.swift` (removeSavedCopies: a deleted chat's rows leave the profile's kept list), `Conduit/Services/NotifierPluginStatus.swift` (mayServe)
- Folder tab: `Conduit/Services/WorkspaceFiles.swift` (list and recent keeping their answers once they parse, get's readable, keptListing, keptRecent and keptRoute), `Conduit/Services/WorkspaceExplorer.swift` (open shows the kept listing and recent files; showsKeptRoot, which load leaves up until the plugin says what it serves; load keeps the folder's own listing, never one opened in the tree; askPluginIfUnanswered, from open and refresh), `Conduit/Views/V2/V2WorkspaceViews.swift` (WorkspaceFolderView's Changes, the plugin's routes reported or ruled out reading the folders again; the spinner, the update label and Recently Changed)
- Tests: `ConduitTests/OfflineChatCacheTests.swift` (Kept answers, testAKeptSchemaKeepsItsFieldNames, testAnswersAboutOneChatOrFolderOfManyKeepTheNewest, testADeletedChatTakesItsKeptArtifactsList), `ConduitTests/AppStateMultiDashboardTests.swift` (Kept settings answers, Pulse's, Usage's, Voice's and the live voice modes' status lines among them, testAReadAskedBeforeAWriteNeverPutsItsAnswerBack; testAModelSaveLandedBeforeAProfileSwitchStillWritesItsProfileConfig; the Bots list's, testTheBotsListOpensOnTheRosterHermesGaveLastTime, testTheKeptRosterCapsDesktopGroupPictures and testTheBotsListOpensOnTheHostedRoomsListedLastTime; testCapabilitiesOpenOnTheSkillsAndToolsetsHermesGaveLastTime, testACapabilitiesChangeLandingAfterASwitchChangesItsDashboardsCopy, testAFolderOpensOnItsListingKeptLastTime, testADeleteAnsweredAfterASwitchSaysNothingOnTheNewDashboard; the bot editor's, testTheBotEditorOpensOnWhatHermesGaveLastTime), `ConduitTests/KanbanTests.swift` (testTheBoardOpensOnWhatItShowedLastTime, testABoardPickedShowsWhatItShowedLastTimeWhileItLoads, testOnlyAReadableAnswerIsKeptAndLateAnswersShowTheKeptBoard, testPollReturningTheSameSnapshotOnlyTogglesLoading, testTheModelOverrideOpensOnTheRosterItListedLastTime, testAnswersGivenAgainAfterHermesListedTheBoardsLeaveItsList), `ConduitTests/KanbanTests+Capabilities.swift` (testEachCapabilitiesTabOpensOnWhatItShowedLastTime, testChangesOnKeptListsReadThemAgain, testPluginChangesKeepTheCatalogsFlags, testAKeptCatalogWhoseReadFailsAsksAgain, testAChangeLandingAfterASwitchIsKeptForItsOwnProfile, testEachCapabilityPageOpensOnWhatItShowedLastTime, testAPageChangeHermesTookIsKeptAsHermesHoldsIt, testACancelledPluginsReadIsNoFailure), `ConduitTests/HermesVoiceConfigurationServiceTests+KeptAnswers.swift`, `ConduitTests/ProfileModelDefaultsTests+ConfigSchema.swift` (testAnAnswerChangesOnlyWhatHermesChanged, testASaveOfAKeptPageWaitsForHermesAnswer), `ConduitTests/ModelPickerTests.swift` (testAPickerOpensOnTheKeptModels), `ConduitTests/GatewayRestartTests+Artifacts.swift` (testArtifactsKeepTheListAsItOpens), `ConduitTests/WorkspaceFilesTests.swift` (testWorkspaceListingAndRecentFilesAreKeptForNextTime)

**Rulings**
- Every screen shows its last saved state at once, and an update never redraws the whole screen (Eric, 2026-10-30, issue #1533).
- An answer is kept per dashboard, profile and route in the saved chats' store, so every wipe of the saved chats takes it, a deleted bot's go with it, and a deleted chat takes its own Artifacts list and its rows from the profile's. An answer about every profile at once (delegation's pause, and Pulse's state and memory, Pulse being one per host) is kept once per dashboard, so each profile's page opens on it. A read is kept only while its dashboard is still the one open and nothing was wiped since it was asked. The open profile's are read ahead with its chats, and the dashboard's own with them; memory holds the answers used last, at most 32 and 8 MB, and an answer over 2 MB isn't kept, on disk or in memory.
- Memory and the kept file leave out credential-shaped keys at any depth (any name ending in key or keys, token or tokens, secret or secrets, cookie or cookies, auth or authorization, one with an `auth` word, and one containing password, passwd, passphrase or credential), a pair's value when its name or key is one of those (`{"name": "Authorization", "value": …}`), and a URL's user and password or a credential-shaped name in its query (`?api_key=…`), since a config can hold a custom endpoint's key. Such a key whose value is true or false stays, being a setting about them (`redact_secrets`); so does a number under a name ending in tokens, or in a pair so named by its `name` or `key` (`max_tokens`, a usage report's token counts), and a `key` beside `is_set`, which names the variable whose presence the row reports. A schema's fields keep their names, which are config paths; what each holds is filtered. A name that only looks like a credential's comes in with Hermes' answer; none of the pages' own fields does. `/api/env` is never kept.
- A page draws its kept answer before its first frame, with its kept schema when it reads one, so no row comes or goes when Hermes answers; with nothing kept it shows its loader as before. A config Conduit saves is what the pages open on next, and a Default model save reads the catalog and the model's info again so their kept copies follow it. Pulse's state is kept from every step that answers with it (a change, a step reading older chats, Quiet for today on the Pulse screen or from a Pulse notification), so Settings > Pulse opens on the last state Pulse gave. A kept Pulse state is only drawn: one with Where you are or Walking past off doesn't stop this iPhone watching shops until Pulse's own answer says so.
- Hermes' answer changes only the fields it changed: a field changed on the page since it asked (a save still in flight included), and the one being typed in, stay as they are. A read that fails keeps what's shown.
- A save that writes several values or a whole list (Save model defaults, Save delegate defaults, Save fallbacks) waits for Hermes' answer, and the kept fallback list can't be edited until then: it may be stale and has no credentials to write back. A single setting saves at once, since its write reads Hermes' config first. On Settings > Pulse, a step that writes back what the page shows besides what was picked (report times, quiet days, the night's start and end, the note, the model, whose refusal puts the shown one back) or acts on it (Set up Pulse, Pin it, reading older chats) waits for Pulse's answer; a setting picked outright saves at once. Forgetting a kept item in What Pulse remembers doesn't wait: it's named by its id, and it leaves the kept list too.
- Voice settings open on Hermes' config and speech toolsets as last read, the config being the one the agent pages keep, and only once both toolsets are kept, so no voice reads not ready for want of one. Which keys are set comes from `/api/env`, which is never kept: a key the kept toolsets don't list as set reads Checking…, with no field, until Hermes answers (after a read that fails it says Hermes didn't say, still with no field), and a read of it that fails keeps which keys the page showed set, from Hermes' last answer held in memory (a key saved since included). Meanwhile the setup steps show the kept settings and the Hermes step says Checking…; if Hermes doesn't answer, it says to connect and the settings stay. With no settings shown it says to connect too; only a Hermes that answers without the voice routes is told to update. Speech to text's speech server opens on the notifier's status as last read, and Local's fast model on the one Assistant speech's status gave, kept without the server's key; Assistant speech's own steps wait for the host, since they hang on that key; reopened on the page, they open on its status read earlier, held in memory with its key (a new key included), while the host is asked again. A read of the speech server, Assistant speech's status or the fast model that fails keeps what's shown, the setup steps included, and says why; their fields wait until the page's next check (Check again included) gets an answer, and Assistant speech's section, showing why its read failed, reads again then too. A new key that fails keeps the one shown. A speech toolset or schema read that fails while the config answers keeps the one shown, so a ready voice doesn't flip to not ready. The provider pickers, Private voice's Use, the provider fields, Show words while you speak, the speech server's address and the fast model's fields, with their Save and Remove key, wait for the answer, as the pickers always waited for a read: a kept value may be stale, and a kept address has no user or password to write back. A choice saves when it's picked, never when Hermes' answer changes it. A voice config save is what the page opens on next. The Voice replies model opens on the slot Hermes gave last, and its pickers wait for Hermes, since a save writes the whole slot; a read that fails keeps it, and the page's next check asks again; a pick written while Hermes is asked stays over that answer; an answer without the slot hides it. The Voice replies, Voice jobs and Settings > Pulse model pickers open on the models of the `model.options` answer Usage keeps, picked from once Hermes answers, and a read that fails keeps the models listed.
- The model sheet and the bot editor's Model page open on the models of that `model.options` answer too; a read that fails leaves them up with "Could not load models." and Try Again under them. Their rows can be picked once Hermes answers, as a list that didn't load is never picked from (see Model lists that fail to load). The sheet's read names its chat's session, and every reader takes only the answer's providers (Usage their quota rows), so one kept answer serves them all; each asks again when it opens (#1567).
- The Bots list opens on the bots and Desktop's groups `profiles.list` gave last time and the hosted rooms `groups.list` gave, with the host's pictures for the rooms up to 1 MB and Desktop's own group pictures up to 1 MB (the rest are left out, so pictures never cost the bots their kept copy), kept once per dashboard as Conduit read them, `profiles.list` listing the whole Hermes. They show until Hermes answers, and a read that fails keeps them up. The kept copy leaves out each bot's ui_meta, which a write sends back whole, so nothing writes a kept bot: Pin, Hide, Edit, Duplicate and Delete wait for Hermes' answer, as do New Bot and New Group Chat, whose picker lists Hermes' bots. A kept bot's row opens its Bot Chat through the lookup, its kept chat counting as the roster's last confirmation, so an empty lookup still makes none. A kept room tapped before Hermes lists the rooms asks for the list first (and whether Hermes hosts rooms, if it hasn't said), then opens as Hermes lists it; one it no longer lists, or on a Hermes that no longer hosts rooms, is no longer available and doesn't open, and a list that fails says to try again. The kept pictures are taken as the first list lands, before the plugin says it keeps pictures too, so only one whose revision moved is fetched again, and a picture set or removed here is kept with the rooms. A bot's face shows from the copy the profile pictures keep on the phone until its fetch lands, and connecting fetches it again. Chats and rooms name teammates from the same bots, and a kept bot's Bot Chat face and color, the @ list, Mention a Bot, the note to the bot and a spoken job's bot names come from them, so nothing changes when Hermes answers (#1568).
- The bot editor opens on what Hermes gave last time for the profile: Edit Bot on the bot's `profiles.describe` (its SOUL, model, skills, tools and MCP servers), New Bot on its Start From profile's lists and the MCP page on Hermes' catalog and its servers' sign-ins, each kept in that profile's answers, as Conduit read them (a server's sign-in as `sign_in`, the servers as a list, since a server's name can look like a credential's), so a deleted bot takes its own. They're read-only until Hermes answers: they may be stale (a change made in Capabilities or on Desktop since), and a save compares with Hermes' answer, never the kept one, so Add, Sign In, the switches, the SOUL and the model wait for it; the description stays the Bots list's until then, as before. A read that fails keeps them shown under its note, the MCP page's with Try Again. A servers list that fails while the catalog answers keeps nothing: the page shows Hermes' catalog with the sign-ins kept last time, where it used to show no sign-ins (from #1588's review). A write Hermes took is what they open on next, even if the read after it fails: a description, SOUL, model or capability section saved, a catalog server added (on, and installed in the catalog) and a sign-in (#1588).
- Capabilities opens each tab on the lists it showed last time on the dashboard and profile: the installed skills and toolsets (shown only once both are kept; an answer listing no toolsets, a Hermes still loading its plugins, isn't kept), the official skills, the year's calls per tool (the usage answer's `tools` alone), the MCP servers and catalog, and the plugins, the plugin catalog being kept once per dashboard, as it's the same for every profile. Each list asks Hermes again when its tab shows; a read that fails keeps it up, and Hermes' answer takes its place, redrawing only the rows that changed. A catalog's read can fail while its list's answers: a kept catalog then stays up and asks again when its tab next shows, as a kept list does. The servers and the catalog are kept as Conduit read them: a server's command arguments, which can hold a key, are left out until Hermes answers, and so are its address's path and query (`/sse/<token>`), its scheme, host and port kept, so a server's page shows its address and command once Hermes answers; how it signs in is kept as `sign_in`, which the filter doesn't take for a credential's name. A catalog entry's command and arguments are kept: they're the catalog's template, the same on every Hermes, and an install's keys go to Hermes, never into them. Kept servers are tested only once Hermes lists them, a change made on the kept list reading them again included, a connector install, an edit or a switch Hermes refused among them; a server switched on or edited is tested once Hermes takes the change, as on a live list, even if the read after it fails, since Hermes taking it says the server is there. A server's page waits for Hermes' list before its own first test too, and says the server is untested if the list's read fails. The plugins are kept as Hermes gave them, the answer the Chat and Memory pages read their choices from, so a plugin's sign-in command, under Hermes' `auth_command`, which the filter drops as it drops every name with an `auth` word, shows once Hermes answers. A switch, install, update, edit or removal Hermes took is kept over any read asked before it, one with nothing kept to change counting all the same, and a list still showing its kept copy then reads it again, since the read on its way no longer commits. It's kept for the dashboard and profile it was made on, a switch to another while it was out included, never for the one switched to: the change is made to the kept copy, not to the rows on screen, and an install or edit, whose row comes with Hermes' answer, counts as a write there; a switch Hermes refused is never kept, and a kept list reads again after one too. A plugin's install, update or removal is kept in the plugin catalog too, and a connector's install or removal in the connector catalog, its entry marked installed or not (a plugin's with no update waiting), so a removal whose read fails offers it again and an install's doesn't; the catalog shown keeps an installed entry until Hermes' answer brings its row. Offline the tabs open on their kept lists too, after a dashboard switch made offline included, and the skill and toolset switches are off until a dashboard connects. Turn All On, Turn All Off and Turn Off Unused wait for Hermes' answer, as they pick from the list shown. The Kanban task composer's skill picker lists the kept skills too (#1569).
- Capabilities' pages open on what they showed last time on the dashboard and profile: a skill's SKILL.md, a catalog skill's preview and a toolset's backends and keys, each one page's of many, kept with the chats' and folders' lists (the 100 read last), and where the terminal runs. A read that fails keeps what's shown. A backend, terminal or key change Hermes took shows on the page at once as Hermes now holds it (the backend chosen, a key set, never the key itself), a page with nothing kept included, and changes the page's kept answer the same way, so the page shows it next time even if the read after it fails; then the page reads again, as before. Offline, a page's backends and keys and a catalog skill's Install, on its row as on its page, are off, as the switches are. A plugins read cut off by leaving the tab is no failure, so the tab asks again when it next shows (#1584).
- The Tasks board opens on what it showed last time on the dashboard: the boards, the board shown and its cards as they show without archived tasks, the profiles, projects and orchestration settings, kept once per dashboard as Hermes gave them, Kanban being shared by every profile; offline too, saying to connect. Nothing on a kept board can be changed until Hermes answers: its cards are read-only, as a board's being switched away from are, and the board still scrolls. A board picked shows its own kept cards while it loads, rather than the last board's. Show archived reads Hermes, as archived tasks aren't kept. Hermes' board answer carries its clock, which nothing shows: it's left out, so a poll that brings back the same board doesn't redraw it. Only an answer Conduit can read is kept: one it can't fails like any read, leaving the last one kept. The board shows once it's pointed at the dashboard open, before the first frame and on a switch before the next, so neither an empty board nor the last dashboard's is drawn first; answers that name the dashboard only later show its kept board until Hermes lists the boards, and answers given again never put kept lists back over Hermes'. The model override (the task composer's and a task's own) opens on the roster the plugin gave last time, kept once per dashboard too (see Model lists that fail to load).
- The Artifacts lists open on what they listed last time: each store's first page of every kind, unsearched, as the list opens, kept for the dashboard and the store's profile as Hermes gave it; a filter, a search and the pages after the first read Hermes, a filter or search showing the last rows dimmed until it answers. The Artifacts page's own stores are kept with each profile's other answers. A chat's own list (a Bot Chat's included) and a folder's listing and recent files are each one of many, so each profile keeps the 100 of them read last, within 16 MB, and never reads them ahead, so they don't take the room the settings pages' answers have. A read that fails keeps the rows shown, and a bot's store that fails shows its kept rows, which don't page on. Kept rows show before the plugin says what it serves, offline too, and the list reads Hermes once it says it serves artifacts; once it says it doesn't, or isn't there, the update notice takes their place, and never before: with nothing kept the list shows its loader until then, or offline, that Conduit isn't connected. Connected with no word from the plugin, the list asks it again as it opens and on a refresh, and with nothing kept says it couldn't reach the dashboard's notifier if it still doesn't answer. A list kept or loaded empty says so at once, through a refresh too. A listed link is kept without a credential-shaped query, as every kept URL is, so offline its kept row opens the address without it until Hermes answers. The Folder tab opens a folder on the listing and Recently Changed the plugin gave last time; a folder opened in the tree, Hermes' own listing (a plugin without the workspace routes), search and a file read Hermes. A kept listing waits for the plugin's word, rather than giving way to Hermes' own listing, which has no sizes or dates: it reads again through the plugin's routes once it says it serves them, or through Hermes' own once it says it doesn't, and the update label waits until then. Only an answer the list or folder can read is kept (#1582).
- Offline, Settings > Usage shows the numbers it kept, the quota with them, under "Connect to Hermes to update these numbers." instead of clearing the page as it did since #813; a refresh that fails says so over them, and a quota that can't be read while connected still goes (Eric's ruling above, #1555). A per-model read that fails is kept as none, so the page opens on the usage route's own rows, as it showed them, never on an older split and its cost beside newer totals.

**Open gaps**
- A page whose answers weren't read ahead (another profile's, the bot editor's included, Usage's, a chat's own Artifacts list and a folder's listing and recent files, which are never read ahead, or one opened before the live list landed), and a save, forget or Capabilities change that lands after a dashboard switch, read their kept files on the main thread: a config or schema is usually tens of kilobytes, as are most chats' Artifacts and folders' listings, and a file can be up to 2 MB. A chat's Artifacts list reads one kept file per store as it opens (with All profiles, its profile's and every bot's), and a folder two (its listing and Recently Changed), so a chat with many bots or a large folder reads the most.

**Checked:** 2026-10-31, #1588 (the bot editor opens on its kept answers: Edit Bot's SOUL, model and lists, New Bot's Start From lists and the MCP page's catalog and sign-ins, read-only until Hermes answers, and a write Hermes took is what it opens on next; a gap closed; from its review, a servers list that fails alone keeps nothing and leaves the kept sign-ins up, and the MCP page offers Try Again over a kept catalog); 2026-10-31, #1584 (Capabilities' pages open on their kept answers: a skill's SKILL.md, a catalog skill's preview, a toolset's backends and where the terminal runs; a cancelled plugins read is no failure; the Kanban model override opens on its kept roster; a gap narrowed; from #1581's review, the Tasks board keeps only answers that decode, waits to be pointed at the dashboard open before it draws, and shows the kept board when the answers name the dashboard late; from its review, a page's backend, terminal or key change is kept as Hermes took it and shows at once, offline a page's backends, keys and Install are off, answers given again after Hermes listed the boards leave its lists, and a roster with nothing to offer isn't kept; from the review after, a change shows at once on a page with nothing kept too, and a catalog skill's row's Install is off offline as its page's is; from #1582's review, a deleted chat's rows leave the profile's kept Artifacts list, offline a list kept empty says so, and the Folder asks a plugin that never answered again); 2026-10-31, #1582 (the Artifacts lists and the Folder tab open on their kept answers, offline too, a chat's list and a folder's kept for the 100 read last within 16 MB and never read ahead; a failed bot store shows its kept rows; the update notice and label wait for the plugin to rule them out; a gap closed; from its review, with nothing kept the notice still waits, showing the loader or, offline, why; a deleted chat takes its kept Artifacts list; a kept folder listing waits for the plugin's word; only a folder answer that parses is kept; a list kept empty says so at once; the main-thread reads gap names the one-of-many answers; from the review after, a list whose plugin never answered asks it again and says so, and the gap names the reads per store and folder); 2026-10-31, #1581 (the Tasks board opens on its kept answers, offline too, and a board picked on its own; its cards wait for Hermes while the board scrolls, and a poll that brings back the same board doesn't redraw it; a gap closed); 2026-10-31, #1569 (Capabilities' tabs open on their kept lists, offline and after an offline dashboard switch too, and the Kanban skill picker on the kept skills; a change Hermes took is kept, never a refused switch, a plugin's removal, install and update included, and a kept list reads again after one, a refused plugin switch too; kept servers are tested once Hermes lists them, after a change on the kept list too, a connector install or a refused switch among them; a server's address is kept without its path, and the catalog's templates are kept; every tab asks again when it shows a kept list, a connector install counts as a write, and offline the switches are off; the detail pages and the bot editor's capability pages named among the screens still waiting; a sibling done; the plugin catalog's flags kept with an install, update or removal, a kept server's page showing its address and command once Hermes answers, and a server switched on tested once Hermes takes it; with #1574 merged in, an edit counts as a change and a server's page waits for Hermes' list before its first test; from the next review, a kept catalog whose read fails asks again, and a change that lands after a profile or dashboard switch is kept for the one it was made on, an edit on a kept list tests the servers Hermes lists, a gap's reach widened; from the review after, a connector install keeps its catalog entry installed, and an empty toolsets answer isn't kept); 2026-10-31, #1568 (the Bots list, Desktop's groups, the hosted rooms and their pictures, and the bots' faces open on their kept answers, and chats and rooms name teammates from the kept bots, which a kept bot's Bot Chat, the @ list, Mention a Bot and spoken jobs use too; nothing writes a kept bot, and a deleted one leaves the kept roster on its own dashboard; Desktop's group pictures are capped so the bots are always kept, and a room picture set here is kept; a kept room opens only as Hermes lists it, and one on a Hermes that hosts no rooms any more is no longer available; a teammate's note reads the kept bots again once a change lands; the dashboard's own answers are read ahead; a gap closed); 2026-10-31, #1567 (the model sheet and the bot editor's Model page open on the kept models, picked once Hermes answers, as are the Voice replies, Voice jobs and Pulse pickers' models, the sheet's read keeping its answer for them and the other pickers; a sibling done); 2026-10-31, #1563 (fixes that bring the code in line with the rulings above, from #1558's review and its own: an older read never replaces a write or a newer read among the kept answers (a forget, a config save, a Voice replies pick, Pulse's steps, delegation's pause), a write with nothing to keep and one that lands after a profile or dashboard switch included, and a write that lands after a dashboard switch is kept for the dashboard it was made on, so its pages open on the save or without the forgotten item when it's back; a key's field waits until Hermes says which keys are set, when only the config's read fails too, on a Hermes without the speech toolsets' routes included; the Voice replies model writes one pick at a time, and one Hermes doesn't take puts back what it holds, saying why, and a read asked before one that answered first leaves its models too; the live voice modes' status lines open on their last check, GPT-Live's under the billing its check asked about and, on a billing switch, the new billing's while it's checked again, a sibling now done under Eric's ruling; a dashboard switch starts Settings over as a profile switch does, so no page stays on the dashboard left; a URL's credentials leave text with a space in it too, which never goes to the URL parser (since iOS 17 it takes such text by escaping the space, and read an address in the prose after a URL as its host), a space in the password or in a query credential's value included, its query's names and the prose after it staying, and neither a port, a space after the host's colon nor a line's end read as a password); 2026-10-31, #1558 (Voice settings, Speech to text's speech server, Local's fast model and the Voice replies model open on their kept answers, and the Voice, Voice jobs and Pulse model pickers on the kept models; their provider settings wait for the answer, and a read that fails keeps what's shown, Assistant speech's status (its section reopening on the one in memory, a new key included), the Voice replies model (a pick made during a read staying) and which keys are set included, until the page's next check answers, and a key's field waits through it; with nothing shown, a Hermes that doesn't answer is one to connect to; the live voice modes' status lines not needed; voice config saves are what the page opens on next; from #1555's review, a count in a pair named like tokens, by `name` or `key`, is kept, a forgotten item leaves the kept list, a failed per-model read keeps no older split, and a new Usage period shows its kept numbers in the same frame); 2026-10-31, #1555 (Settings > Pulse, What Pulse remembers and Settings > Usage open on their kept answers, and a Pulse notification's Quiet for today keeps Pulse's answer; the filter's pairs, counts, schema names and a URL's query; a Default model save's catalog; the Save gate's test); 2026-10-31, #1552 (the agent settings pages open on their kept answers).

## Composer drafts

Unsent words, files and a quoted reply wait in the composer they were typed
in until they're sent, whichever way the user leaves.

**Siblings:** chat composer (chats, project chats, Bot Chat) · New Chat ·
a saved copy's composer and its waiting message ("Sends when connected") ·
group rooms · the full editor · the notices that say where words went ·
the composer's Sending… while a send checks Hermes

| Leaving by | Chat composer | Group room |
|---|---|---|
| Back, or another chat from the list | text, files and quote kept | text and files kept |
| A room opened over the chat | kept | not applicable |
| Leaving while a send is on its way | back in its draft if it doesn't go | held by the room's pending message |
| Sign-out or another server | dropped | dropped, files deleted |
| The room disbanded or left the list | not applicable | dropped, files deleted |

**Code**
- Chat composer: `Conduit/Views/Components/ComposerBar.swift` (loadDraft, saveDraft, handoffComposer, onDisappear, draftKeyToKeep, restoreSubmittedDraftIfNeeded, applyComposerRestoreRequests, sendingNotice, composerInUse), `Conduit/Views/Components/ComposerUpdates.swift` (isCheckingSend), `Conduit/Views/Components/ComposerDraftStore.swift` (clearCount)
- A send that didn't go: `Conduit/Services/AppState+PendingSend.swift` (returnFailedComposerSubmission, restoreFailedPendingComposerSend's mayHaveGone), `Conduit/Services/AppState.swift` (composerSubmissionStoppedQuietly, takeComposerSubmissionOfUnknownDelivery); its checks before the message shows: `Conduit/Services/AppState.swift` (checkingBeforeSend, composerSendIsChecking: the stale-idle probe, the transcript freshness read, starting a chat from the empty canvas)
- Waiting message: `Conduit/Services/AppState+PendingSend.swift` (returnPendingComposerSendToDraft, restoreFailedPendingComposerSend, pendingComposerSendNotice), `Conduit/Services/AppState.swift` (conversationIsGone), `Conduit/Models/PendingComposerSend.swift`
- Group rooms: `Conduit/Views/Components/GroupRoomComposer.swift`, `Conduit/Services/AppState.swift` (activeRoomDraft, activeRoomAttachments, pruneRoomStores)
- Tests: `ConduitTests/ComposerDraftStoreTests.swift`, `ConduitTests/GroupChatSessionSafetyTests.swift`, `ConduitTests/OfflineChatCacheTests.swift`, `ConduitTests/AppStateChatResumeTests.swift`, `ConduitTests/AppStateForegroundLifecycleTests.swift` (the Sending… line, leaving mid-send)

**Rulings**
- Drafts live in memory per (profile, chat), and a sign-out or server switch clears them on purpose; nothing the composer held before the clear goes back in after it: not when it goes away, hands off to another chat or a room, nor when a send that was on its way fails (2026-10-24, #1185).
- A send's words leave the field when Send is tapped. If it doesn't go, they come back through AppState's restore requests, never through the composer that sent them: leaving the chat mid-send replaces that composer, and words put back into it were lost, so the user had to type them again. The composer on screen puts them in its field when they're its chat's, otherwise in their chat's stored draft. A send that stopped with no error to say so (its chat was left before its message showed) leaves the waiting message's notice: back in the composer, or back in that chat's draft, by name, and only while its dashboard and profile are on screen. One whose reply was lost after its chat was left may have reached Hermes, so its words come back without that notice, a waiting message's included. Sending… keeps the V2 composer open, as other notices do (2026-10-27, #1403, from #1401).
- Until a send's message shows in the transcript, the composer says "Sending…" in the chat it was sent from: on a slow or dropped connection the checks before it (whether Hermes is still busy, whether the transcript is current, starting the chat) can take seconds, and an emptied field with nothing else read as a message that went nowhere (2026-10-27, #1403, from #1401).
- A waiting message is never sent on its own after it's handed back. When Hermes says its chat is gone, its words go into the composer on screen, unsent, with a notice saying so (2026-10-24, #1185).
- A waiting message is words only, so a long paste while its chat is on its way stays in the field as text instead of becoming an attachment, and can wait like typed words. Once the chat is open, a long paste becomes a text attachment, which the draft keeps like any file ("Attaching files", 2026-10-29, #1515).

**Open gaps**
- Drafts don't outlive Conduit being stopped; only a waiting message does (as a file).
- A waiting message left from an earlier run whose chat is gone still goes back into that chat's draft: the gone chats are only known for this run.
- A room's quoted message and its "To" picks aren't kept when the room is left.
- A room that's disbanded while another dashboard is in use keeps its staged files until that dashboard is opened again or the user signs out.

**Checked:** 2026-10-30, #1527 (a handoff clears the full editor's kept-focus latch, so a send's focus doesn't follow into the next chat); 2026-10-29, #1515 (a long paste stays words while the chat is on its way); 2026-10-27, #1403 (failed sends' words outlast the composer; Sending… before the message shows); 2026-10-24, at #1185; a failed '/command' put back without its suggestion list over it at #1191 (#891 review).

## A new chat that something waits on

Some actions start a chat and then put something in it: a message sent from
the empty canvas, a screenshot, a Hermes call setup prompt. The thing goes
into the chat that action created, never into another one that opened
meanwhile.

**Siblings:** the composer's send from the empty canvas · Ask Hermes About
Screen (the voice sheet's screenshot and a screen question) · Settings' Hermes
test call and watch prompts · a Classic voice conversation's fresh chat ·
New Chat and its focus · a widget's or Shortcut's New Chat · the /new command
· Pulse's Do it on an item from no chat or from a Kanban task's worker

**Code**
- Creating the chat: `Conduit/Services/AppState.swift` (createNewSession and createAndReconcileSession return the chat they opened; startChatForComposerSubmission; startNewChat and focusNewChatComposer; prepareVoiceConversation)
- Screenshots: `Conduit/Services/AppState+ScreenQuestion.swift` (startChatForScreenshot, openScreenQuestion)
- Hermes calls: `Conduit/Services/AppState+HermesCalls.swift` (startHermesCallsChat)
- Widget and Shortcut launches: `Conduit/Services/AppState+WidgetLaunch.swift`
- Pulse's Do it: `Conduit/Services/AppState.swift` (startPulseNewChat), `Conduit/Services/PulseFeed.swift` (actOnPulseCard)
- Tests: `ConduitTests/SessionRenameTests.swift`, `ConduitTests/PulseFeedTests.swift`

**Rulings**
- What waits on a new chat goes in only when the chat createNewSession returned is still the one open. Another chat opened or created meanwhile (a voice action, a screen question, a notification) gets nothing. The message stays in the composer, the screenshot goes back or waits, and the user is told (2026-10-24, #941's review, #1191).
- New Chat focuses the composer only on the chat it made. A Classic voice conversation files and archives only its own new chat under Voice; a fresh one asked for fails when another chat took the screen.
- Pulse's Do it on an item from no chat (and, since #1473, on one from a Kanban task's worker, which Hermes won't reopen as a chat) starts a chat only when New Chat can start one at once, and puts the reminder only in the chat its own create returned, while that one is still open. The Pulse screen stays up until then, so a chat that didn't start leaves it there to say why (2026-10-25, #1240 on the `pulse` branch).

**Open gaps**
- A widget's or Shortcut's New Chat and /new put nothing in the chat, so they only report whether the open chat changed.

**Checked:** 2026-10-30, #1542 (All history stays after the host's 2000 limit and stops at the oldest reading; the stores needed no change); 2026-10-29, #1517 (the `pulse` branch merged into main: the app paths it lists are on main now; nothing else changed); 2026-10-29, #1479, carrying #1473 from the `pulse` branch (Do it on a card from a Kanban task's worker takes the same new chat); 2026-10-25, #1241 (Pulse's Do it, from #1240 on the `pulse` branch); main's code as at #1191.

## /new in a Bot Chat

`/new` (and `/reset`, `/clear`) starts a new chat, except in a bot's one
chat, which never forks: there it compacts the same chat instead, so the
bot starts from a summary with fresh context and the user stays in Bots.

**Siblings:** the composer's `/new` in chats and project chats (starts a new
chat) · Bot Chat (compacts) · a Bot Chat `/new` with attachments (refused,
the draft kept) · group rooms (no slash commands) · the notice the compaction
shows (says the chat compacts and keeps its memory and skills) · the `/help`
text and the slash suggestions' "Start a new conversation" (the general
command, still right outside Bot Chats) · "A new chat that something waits
on" (a Bot Chat's `/new` opens no chat, so nothing waits on one)

**Code**
- The guard: `Conduit/Services/AppState.swift` (activeChatIsCanonicalBotChat, isCanonicalForeverChatReset, executeSlashCommand's new/reset/clear case, the attachment refusal in performComposerSubmission)
- Tests: `ConduitTests/AppStateSessionCompressTests.swift`

**Rulings**
- A Bot Chat is one continuous conversation: `/new` there compacts it, whatever follows the command, and never opens a chat in Chats. Saved memory and skills stay (upstream Bot Mode's forever chat; 2026-10-26, #1310, issue #1307).
- The chat is a Bot Chat by positive evidence only: one of the chat's own ids is one this process registered when it opened the Bot Chat (a reopened one runs under a fresh runtime id), or the roster's canonical id. Without either, `/new` starts a new chat.
- With attachments, `/new` in a Bot Chat (title or not) is refused and the draft kept: a compaction carries no attachments, and the text is never sent to the bot.

**Open gaps**
- None known.

**Checked:** 2026-10-26, #1310.

## Bot workstreams

A bot's Bot Chat as its coordinator: it hands work that needs tools to
workstreams, hidden sessions of its own on the bot's profile, follows them by
ref (W1, W2), and hears back when one finishes, fails or waits on the user.
Each bot turns it on for itself (`hermes -p <bot> conduit-push work on`). It's
being built on the notifier's `bot-workstreams` branch (M0, notifier #484), so
none of it is on either main yet, and the app has no screen for it until M2.

**Siblings:** the Bot Chat (the eight work tools, offered only there and only
with workstreams on; its policy, strict or lookups, holding its tools and a
fork's; the note on its turns listing open work; the work updates that come
in as hidden turns, which the transcript leaves out as it does every hidden
user turn) · a workstream's session (hidden, titled, on the bot's own
profile, its steps journaled; a reply in it sends no push, the Bot Chat's
reply to the update is the one push, and its turns start no Live Activity) · the `conduit://session/` link a work
tool's answer carries, with the bot's profile (see Links in messages) · an
approval in a workstream (marks it waiting on you and tells the Bot Chat) ·
Bot mentions and teammate messages (`message_agent` refused in a coordinator,
asks between bots come in M1) · Opening a Bot Chat (the "Bot Chat" title is
how the plugin knows the coordinator) · Hermes Desktop's Bot Chat (the same
plugin, the same tools) · the `hermes conduit-push work` commands · the tool
descriptions, the worker's and the update's prompts, and the notifier's
README section · M2's Work panel and Bots and Tasks screens (not built)

**Code**
- Notifier, on its `bot-workstreams` branch (plain text until it reaches main): work_store.py (the registry, conduit/workstreams.db in the bot's home), work_broker.py (Hermes' session API in the dashboard's process), work_tool.py (the tools, the policy, the hooks' work, the note and the updates), __init__.py (the hook calls), cli.py (`work`), tests/test_work.py, upstream/test_bot_work.py
- App: `Conduit/Services/HermesClient.swift` (normalizeMessages, which drops hidden rows from the transcript), `Conduit/Services/ConduitAppLink.swift` and `Conduit/Services/AppState.swift` (openAppLink, the link's profile)
- Design: designs/bot-mode-coordinator (project files)

**Rulings**
- Built on the `bot-workstreams` branches, tested apart from public TestFlight, and never merged to main until Eric says so (2026-10-31, notifier #484, Eric).
- Each bot's Bot Chat coordinates its own work; bots ask each other rather than one coordinator for all (2026-10-31, Eric).
- The model names work by ref only: a session id appears only inside the link, and a ref from another bot's registry names nothing (2026-10-31, notifier #484).
- Off unless the bot turns it on; once on, a registry that can't be read holds the Bot Chat to strict rather than freeing it (2026-10-31, notifier #484's review).
- Once on, a chat whose title can't be read is held to the policy for that call, since it might be the coordinator (2026-10-31, notifier #484's review).
- Under `plugins.isolation: host` the tools answer with the reason rather than starting anything, since the session API is only in the dashboard's process (2026-10-31, notifier #484).
- "Bot Chat" is the coordinator's title only: work_start refuses it for a workstream, since the title names the session and the policy reads it (2026-10-31, notifier #485).
- A registry that exists but can't be read at a turn's hooks keeps that turn quiet (no push, alert call or Live Activity), since it may be a hidden workstream; the Bot Chat's own turn still pushes when its title can be read (2026-10-31, notifier #485).

**Open gaps**
- No screen in the app: workstreams show only as the Bot Chat's answers and their links until M2's Work panel. M2 builds on the cache-first screens and the transcript rewrite (see Screens that open on their last answer), checked with that work first.
- The app's handling of an approval in a hidden workstream session is unchecked: the request goes to the user from that session, and nothing in the app opens it from the Bot Chat yet.
- The Notifications entry gains a line for workstream turns' quiet pushes once this reaches main.
- The first session Hermes builds on a secondary profile after the dashboard starts can come up without the work tools; the upstream test takes it with a warm-up session (2026-10-31 canary).
- The plugin's version is bumped when the branch merges to main.

**Checked:** 2026-10-31, #1587 (rulings for notifier #485).

## Composer Return key

The optional hardware-keyboard shortcut in Settings > Keyboard: with it on,
Return sends the composer message and Shift-Return starts a new line. It
is on by default on a Mac and off on iPhone and iPad; the on-screen keyboard's
Return key always inserts a new line.

**Siblings:** the chat composer's inline field (chats, project chats, Bot
Chat; done) · the full editor, a chat's and a room's (done, #1394) · group
rooms' field (done, #1394) · the Mac, where the iPad app's text system
takes Return before the key presses reach the field (done, #1394: a Return
key command with priority over the text system) · iPad and iPhone with a
hardware keyboard (done, the same command, with the key-press route kept
for keypad Enter) · the Keyboard caption ("When on, Return sends and
Shift-Return starts a new line.", done, #1208) · the toggle's accessibility
hint (not needed, it already says the setting applies to hardware keyboards
only) · the two default footnotes, Mac on and iPhone/iPad off (not needed,
each states the default for its device) · the hardware-keyboards caption
(not needed, shown only off a Mac and already says the on-screen Return key
is unchanged) · a running dictation (done, #1315: Return stops it; the
Keyboard caption is unchanged, as it describes the option)

**Code**
- Policy: `Conduit/Views/Components/ComposerReturnKey.swift` (ComposerReturnKey)
- Key handling: `Conduit/Views/Components/ReturnKeyTextView.swift` (ReturnKeyTextView: the Return key command and pressesBegan; ReturnKeyTextEditor, the field rooms and the full editor use)
- Chat composer: `Conduit/Views/Components/ComposerPasteTextView.swift` (ImagePasteTextView), `Conduit/Views/Components/ComposerBar.swift` (submitFromReturnKey, the full editor's)
- Full editor: `Conduit/Views/Components/ComposerFullEditor.swift`
- Group rooms: `Conduit/Views/Components/GroupRoomComposer.swift` (field, submitFromReturnKey)
- Settings: `Conduit/Views/AuxiliaryViews.swift` (ComposerReturnKeySettings)
- Tests: `ConduitTests/ComposerReturnKeyTests.swift`

**Rulings**
- On a Mac the composer fields (a chat's, a room's, the full editor) show no inline prediction (autocorrect and spelling stay on; ReturnKeyTextView). macOS draws it in a correction panel with its own nested event loop, and both Mac freezes captured on 2.2.1 (237) ran inside three or four of them, the chat's LazyVStack re-laying out forever (2026-10-28, #1460).
- The caption describes the option, not current behaviour, because the
  option starts off on iPhone and iPad (2026-10-24, #1208, review of #1190).
- While dictating, Return does what the Stop in Send's place does: stops
  the dictation, or calls off one still coming up, and sends nothing. The
  next Return, once the words are in and Send is back, sends (2026-10-26,
  #1315, see Send while dictating).
- Every composer takes the option, the full editor included: Return there
  sends like its Send button, and Shift-Return starts a new line (2026-10-27,
  #1394).

**Open gaps**
- Not yet checked on a Mac or an iPad with a keyboard: the Return key
  command sending, Shift-Return and the IME's Return still reaching the
  text, in chats, rooms and the full editor.

**Checked:** 2026-10-30, #1527 (a Return send keeps the field's focus on a Mac or with a hardware keyboard, see Composer focus after a send; ImagePasteTextView takes focus once in the window); 2026-10-29, #1515 (the same fields take a long paste as an attachment, `onLongTextPaste`; Return unchanged); 2026-10-28, #1460 (inline prediction off on a Mac).

## Composer at rest and expanded

Whether the composer rests as a slim bar (attach, the field, the mic) until
it is used, or stays expanded with its controls row showing: attach, the
model chip, the context ring, agents, the mic and Send.

**Siblings:** the chat composer (chats, project chats, Bot Chat; done, #1512)
· group rooms' composer (done, #1512) · the chat's voice button beside it
(done, #1512: it stays beside a composer that stays expanded, level with its
bottom, and the composer's own voice and mic buttons give way to it, see
Starting a call) · the composer bar the transcript fades under (not needed:
the bar takes the composer's height, see Bars lists scroll under) · the
drawer shell's chat (not needed: its chat composer never rests; its rooms'
composer follows the same rule, #1512) · iPhone, iPad and Mac · text:
docs/VOICE_SETTINGS.md "Dictate into the composer" (done, #1512); no
Settings caption describes it · the placeholder (the chat's: Message,
Interrupt, Steer, Queue, a chat on its way; the room's; the drawer
shell's chat, the same ComposerBar; done, #1541) · accessibility Text
Sizes on a narrow iPhone (both composers, resting and expanded, in both
shells; done, #1541)

**Code**
- Rule: `Conduit/Views/Components/ComposerLayout.swift` (ComposerLayout.staysExpanded, expandedMinimumWidth, composerStaysExpanded, composerLayoutFromWidth)
- V2: `Conduit/Views/V2/V2ConversationScreen.swift` (chatColumnWidth, composerStaysExpanded, voiceButtonBottomPadding), `Conduit/Views/Components/ComposerBar.swift` (rests, inUseOrHeld, keepsVoiceButtonBeside, showsEmptyDraftSend, controlsRowShowsDictate, composerInUse), `Conduit/Views/Components/GroupRoomComposer.swift` (rests, inUse)
- Drawer shell: `Conduit/Views/RootView.swift` (chatNavigationContent)
- Large Text Sizes: `Conduit/Views/Components/DynamicTypeSupport.swift` (ComposerPlaceholderText, conduitFixedGlyph), `Conduit/Services/AppState.swift` (composerPlaceholder, composerShortPlaceholder), used in `Conduit/Views/Components/ComposerBar.swift` (composerContent's resting row, composerField) and `Conduit/Views/Components/GroupRoomComposer.swift` (the resting row's attachButton, field)
- Tests: `ConduitTests/ChatVoiceButtonTests.swift` (testComposerRestsOnIPhoneAndStaysExpandedOnMacAndWideIPad, testBigButtonSitsLevelWithTheBottomOfAComposerThatStaysExpanded)

**Rulings**
- iPhone: the composer rests and expands while it is used (focus, a draft,
  dictation, a notice, a control's sheet), at any width. iPad: it stays
  expanded when the chat's column has the room (600 pt, Artifacts beside it
  taken off) and rests below that. Mac: it stays expanded at any width, with
  its controls always in reach. There is no setting (Eric, 2026-10-29,
  #1512, issue 1483). A Mac's composer never rests, so a send that keeps
  the field focused changes nothing there. With a hardware keyboard on a
  narrow iPad a send keeps focus too, so a composer that rests stays
  expanded after it until a tap on the transcript (Eric, 2026-10-30, #1527).
  An iPhone never keeps focus after a send, keyboard or not, so its
  composer rests again and the reply has the height (Eric, 2026-10-31,
  #1556, see Composer focus after a send).
- A composer that stays expanded keeps the big voice button beside it, as the
  resting bar does, rather than sliding it aside while typing; the controls
  row then leaves out its own voice button, and its mic when the big button
  dictates. With an empty draft its Send shows dimmed, not the lock a
  composer that can't send (reconnecting, an offline copy, a chat still being made) shows (2026-10-29, #1512).
- Only use opens and closes the composer with its animation; the layout
  rule changing (a chat's first measured width, a window resized) switches
  it at once (2026-10-29, #1512).

- At the accessibility Text Sizes the resting bar's controls (attach, the
  mic, Stop) are capped at xxLarge like the controls row's, and the
  placeholder keeps to one line: the whole hint when it fits, then the
  hint without the agent's name ("Interrupt…"), then that one shrunk to
  fit and cut off. Below them it wraps as before, so the name stays
  (#1476). The same in group rooms (Eric's report, 2026-10-30, #1541).

**Open gaps**
- Not yet seen on a device: an iPad crossing 600 pt as a split or Artifacts
  resizes, and a Mac window at its narrowest. On an iPad the first frame
  of a chat may still show the resting bar before its width is measured.
- Not yet seen on a device: an iPhone at AX3 to AX5 in a running chat and
  in a group room (#1541, checked in code and a unit test only).

**Checked:** 2026-10-31, #1556 (an iPhone rests again after a send, keyboard or not); 2026-10-30, #1541 (the resting bar and its placeholder at accessibility Text Sizes on a narrow iPhone); 2026-10-30, #1527 (a send keeps focus with a hardware keyboard, so the composer stays expanded after it); 2026-10-29, #1512 (new entry, issue 1483).

## Composer focus after a send

Whether the composer's field keeps focus once a message goes, so the next
one can be typed straight away, or gives it up so the keyboard goes down.

**Siblings:** the chat composer (chats, project chats, Bot Chat; done,
#1527) · Send, Return and the long-press choices (Steer, Queue,
Interrupt), and a message that waits for its chat ("Sends when connected";
done, #1527) · Stop in Send's place (done, #1527) · the full editor (done,
#1527: a send from it gives the field focus back as the sheet goes) · group
rooms' composer (done, #1556: it follows the same rule, its full editor included) · a prediction sent from the suggestion row (done, #1527:
the same send, so it keeps whatever focus the field had) · the plan card, which opens whatever the focus on a Mac or with a hardware
keyboard (not needed: its check is for the keyboard, not the focus; its
ruling now says the focus stays, see Plan card) · the resting composer and
the minimised call bar (done, #1527, #1556: with a hardware keyboard on a
narrow iPad the composer stays expanded after a send while the field
keeps focus, until a tap on the transcript, see Composer at rest and
expanded; the call bar, on those and on a Mac, comes back after a send and
hides again only once words are typed) ·
iPhone, iPad and Mac · no Settings caption or doc describes it

**Code**
- Rule: `Conduit/Views/Components/ComposerLayout.swift` (ComposerLayout.keepsFocusAfterSend)
- Chat composer: `Conduit/Views/Components/ComposerBar.swift` (endInput, dismissComposer, collapseSubmittedDraft, submit, submitFromReturnKey, queueUntilChatIsReady, performComposerAction; handoffComposer, which clears focusesAfterFullEditor; composerInUse and hidesMinimisedCallBar, which follow focus), `Conduit/Views/Components/ComposerPasteTextView.swift` (updateUIView, ImagePasteTextView.setFocusIntent and didMoveToWindow: a field rebuilt with focus takes it once it's in the window), `Conduit/Views/ChatView.swift` (composerTyping, read through V2ComposerTypingKey, hides MinimisedLiveVoiceBar)
- Full editor: `Conduit/Views/Components/ComposerFullEditor.swift`, opened by ComposerBar's expand button (which takes focus from the field) and its sheet
- Group rooms: `Conduit/Views/Components/GroupRoomComposer.swift` (send; focusesAfterFullEditor, read in the full editor sheet's onDismiss)
- Tests: `ConduitTests/ChatVoiceButtonTests.swift` (testComposerKeepsFocusAfterSendOnMacAndOnAnIPadWithAHardwareKeyboard), `ConduitTests/ComposerPasteTextViewTests.swift` (testARebuiltFieldTakesFocusOnlyWhenItWantsItAsItReachesTheWindow)

**Rulings**
- On a Mac, or on an iPad with a hardware keyboard, a send or Stop
  leaves the field focused when the user was typing, as a desktop client
  does; a click or tap on the transcript still takes focus away. With only
  the on-screen keyboard it goes down, so the reply has the screen (Eric,
  2026-10-30, #1527). The iPad's check is for a connected keyboard, as the
  plan card's is.
- An iPhone never keeps focus after a send, keyboard or not: a kept
  composer takes height the reply needs (Eric, 2026-10-31, #1556; #1527 had
  kept it with a keyboard).
- Group rooms follow the same rule as chats (2026-10-31, #1556; their
  send had never let go of focus).
- Where the field keeps focus, focus alone doesn't hide the minimised call
  bar: it shows after a send and hides only while words are typed, so a
  kept focus never hides a call (2026-10-30, #1527).
- A send or Stop from the full editor gives the field focus once the sheet
  has gone, not while it is dismissing; if the composer hands off to another
  chat first, that focus doesn't follow it there (2026-10-30, #1527).
- Opening a call from the composer still takes focus away on every device:
  the call has the screen (2026-10-30, #1527).

**Open gaps**
- Not yet seen on a device: a Mac and an iPad with a keyboard sending from
  the field and from the full editor, and which controls besides the
  transcript take focus from the field on a Mac. No test reaches
  `updateUIView` passing the binding's focus to the field (it needs a SwiftUI
  Context), so that link is checked on a device only.

**Checked:** 2026-10-31, #1556 (an iPhone always lets go; rooms follow chats); 2026-10-30, #1527 (new entry).

## A chat's last reply

Reading the newest reply in a chat without opening it, from the open chat's
transcript or else its saved history.

**Siblings:** the Send to Hermes Shortcut ("Wait for Answer") · live voice
calls reading a job's chat · the Watch's answer to a call from Hermes

**Code**
- Reader: `Conduit/Services/AppState.swift` (latestLiveVoiceThreadReply, latestLiveVoiceThreadReplyMessage, latestReplyTurn)
- Shortcut: `Conduit/Intents/SendToHermesIntent.swift` (ShortcutReply.mayBe), `Conduit/Services/AppState+ShortcutSend.swift`
- Live calls: `Conduit/Voice/VoiceBackgroundJobs.swift` (latestThreadReply)
- Tests: `ConduitTests/ShortcutSendTests.swift`

**Rulings**
- Only the Shortcut has to tell a new reply from the one before it. Its row ids decide first, then the user's message each reply answers (this run's against another), and the wording last (2026-10-24, #1185).
- Voice calls and the Watch use only the reply's text (2026-10-24, #1185).

**Open gaps**
- The same message sent twice and answered in the same words, read once from saved history and once from the open chat, still can't be told apart.

**Checked:** 2026-10-24, at #1185; a Shortcut send's failed try counted even when its text repeats the banner at #1191 (#1056 review).

## Following the latest message

Whether a transcript keeps itself at the newest message as replies and
events arrive, or stays where the user scrolled to read, and where a long
reply stops.

**Siblings:** chats, project chats and Bot Chat (one transcript) · group
rooms · a delegate agent's live tail sheet · the jump-to-latest button · how
much history an open transcript keeps · opening a chat with an unread reply ·
Settings > Chat's Long replies switch and captions (shared by Sync across
devices)

**Code**
- Chats: `Conduit/Services/TranscriptScroller.swift` (following, browsing on the reader's row, and restoring: pin; keepAnchor, which moves a browsing reader's offset in the pass that lands rows growing, arriving or going above them, see Cards drawn in web pages; pinOwed and insetAtDragStart, for a bar changing under a finger; replyHoldOffset, refreshReplyRoom, dropReplyRoomOutOfSight and relatchAfterReplyRoomDrop, noteLatestUserRow and transcriptChanged's arming of the hold, replyStartLandingRequested, landAtReplyStartIfPending, ChatReplyStartPreference; renderedSessionChanged, userWillToggleRow, restorationRequested and its deadline, explicitLatestRequested and showsJumpToLatest, explicitTopRequested (the title tap), replyStartPreferenceChanged (Long replies switched, here or from another device), notificationHandoffBegan and notificationHandoffFinished (a notification opening a chat); write; TranscriptScrollSurface, what it reads of the collection view), `Conduit/Views/TranscriptView.swift` (TranscriptView and TranscriptViewController: the collection view under the bars and the keyboard, whose heights it takes as its insets, in SwiftUI's animation when it animates them; TranscriptCollectionView; TranscriptCell's updateEnvironment), `Conduit/Views/TranscriptCellEnvironment.swift` (TranscriptCellEnvironment: what the rows read of the chat's environment, handed to each row's hosting controller; setInsideRows, the keys the rows set themselves, where they read them), `scripts/check-transcript-environment.py` (in CI: fails a key Conduit declares that's neither copied there nor listed, and a listed one nothing sets), `Conduit/Views/TranscriptLayout.swift` (the rows' frames, measured or estimated, each row's estimate made once per width and scope from its text's characters, and again when setRows names it changed; noteHeight, the content's height a row's change brings, since a pass for some rows never asks for it again; the room under a sent message, reserveContentHeight, and rowsHeight, the rows' own height as the last pass laid them out, without it; TranscriptHeights, the heights kept per conversation and width), `Conduit/Views/ChatView.swift` (chatTranscript; ChatJumpControls and requestLatest; the send arming the hold; the unread landing observer, takeReplyStartLanding; installScrollerCallbacks and ChatScrollEventRouter; the live rows, through ChatView.liveTurn, the rule `Conduit/Views/TranscriptModel.swift` draws them by, TranscriptModel.LiveTurn)
- Unread open: `Conduit/Services/AppState.swift` (performSessionOpenNotingRefusal, chatReplyStartLandingRequest, takeChatReplyStartLanding)
- Another device's message: `Conduit/Services/AppState.swift` (noteUserMessageElsewhere: one Hermes announces under a row id this chat doesn't show; its words decide only while this iPhone's latest send has no row id yet), `Conduit/Services/TranscriptScroller.swift` (noteLatestUserRow, which arms the hold for that message)
- Group rooms, on the same transcript: `Conduit/Views/GroupChatView.swift` (transcript: the room's rows on TranscriptView, moved by a TranscriptScroller and opened and closed through a ChatRowDisclosure of its own; roomRow; GroupRoomJumpButton, from the scroller's chrome; the send's, Retry's and the quoted jump's commands; Long replies switched, here or from another device, told to the scroller's replyStartPreferenceChanged), `Conduit/Views/TranscriptModel.swift` (GroupRoomRow; GroupRoomTranscript's rows and replyStart; GroupRoomTranscriptBox, which tells the scroller of new events, and of a member starting or ending its turn, as it builds the rows), `Conduit/Services/TranscriptScroller.swift` (roomTranscriptChanged; replyHoldOffset's stop at a member message's own start), `Conduit/Views/TranscriptLayout.swift` (the room rows' estimates)
- Delegate tail sheet (its own follow state and Latest button): `Conduit/Views/ChatSupportSheets.swift` (DelegateAgentTailSheet)
- Room history kept: `Conduit/Services/GroupChatModels.swift` (GroupRoomReplay tailWindow, retainedLimit), `Conduit/Services/AppState.swift` (the open and resync tail windows)
- Setting: `Conduit/Views/AuxiliaryViews.swift` (ReplyStartSettings), `Conduit/Services/AppState+SyncedPreferences.swift` (`app.stop_at_reply_start`), `Conduit/Services/TranscriptScroller.swift` (replyStartPreferenceChanged, which takes the room away or brings it back at once, unless the reader scrolled away from it)
- Tests: `ConduitTests/TranscriptScrollerTests.swift` (the engine's tests ported rule by rule: Following, Browsing, Rows changing height, Background, Long replies stop at their start, with testScrollingAwayFromTheRoomTakesItAway, testScrollingWhileTheRoomShowsKeepsIt, testLettingGoNearTheEndADroppedRoomLeavesFollowsAgain, testARoomScrolledAwayFromWithLongRepliesOffDoesntComeBack, An unread chat opens at its latest reply), `ConduitTests/TranscriptLayoutTests.swift` (the rows' frames, a row's growth moving the rows under it in the same pass, the heights kept per conversation and width, the room under a sent message, testEachRowIsGuessedOncePerWidth, testARowNotMeasuredIsGuessedAgainWhenItChanges, testAGuessCountsCharactersNotBytes, and a room's rows, testARoomsRowsAreGuessedFromTheirText), `ConduitTests/ChatScrollStateTests+TranscriptModel.swift` (the live rows), `ConduitTests/ChatScrollHostedTests.swift` (the real ChatView on the collection view: a reply streaming under the sent message without moving, long and short, following to the end with Long replies off, an idle transcript holding still, a row's controller kept aside while its sheet is up, and testAChangeToTheChatsTextSizeReachesTheRowsDrawn; a group room's GroupChatView on the collection view, opened at its end, a sent message drawn under its event's id and the event taking that row in place, testARoomDrawsOnTheTranscriptAndASendLandsInPlace), `ConduitTests/TranscriptScrollerTests.swift` (Group rooms: a long member message stops at its start, a short one follows until it measures longer, a member starting its turn is followed, a later message stops at its own start, a browsing reader stays, a member message during a fling stops the room once it rests, the jump and a send go past the stop, the setting off, the setting switched off at a stop, the quoted jump), `ConduitTests/GroupChatModelsTests.swift` (testANewMemberMessageIsWhereTheRoomLands, testRoomTranscriptRowsKeepTheMessageOnItsWayUnderItsEventsID, testTheRoomBoxTellsTheScrollerOfANewMemberMessage), `scripts/tests/test_check_transcript_environment.py` (the environment checker)

**Rulings**
- Only the user's own scroll leaves following, except a long reply's stop below. Being near the bottom (40 pt), the jump button or sending returns to it (TranscriptScroller, for chats and group rooms; group rooms 2026-10-24, #1184, on the transcript's scroller since 2026-10-31, #1590).
- Following keeps the end above the bar under it as the bar grows or shrinks: Predictive's chips, the plan dock or a call's bar coming and going. On iOS 26 only the scroll view's bottom inset changed then, which nothing reported, so the chips covered the reply's actions. The transcript takes the bars' heights, and the keyboard's, as its own insets, so the pass that applies a change pins in it, in the same animation when SwiftUI animates the change; a finger or fling on the chat holds the pin until it lets go, and whether a reader who lets go is near the bottom is measured against the bottom as it was when the finger came down. A reader browsing stays browsing; one a shrinking bar leaves past the new bottom is moved up to it, so no empty space shows (Michel, #1431; accepted by Eric 2026-10-28, #1455; the insets read in the pass that applies them since the transcript rewrite, 2026-10-31, #1577; Eric delegated the chat scroll's design to Claude, 2026-09-28, and approved the transcript rewrite's design, 2026-10-30).
- A reply longer than the screen stops at its start: following never pins past the user's message it answers, and once the reply runs on, the reader is left browsing there. On by default, switchable in Settings > Chat (Eric, 2026-10-25, #1256, notifier issue 365).
- The stop puts the user's message at the top, 37 pt below the viewport's top (where a new chat's first message sits), with the reply under it; a message taller than a third of the screen shows its last third. It was the bottom of the message (#1256), which scrolled the message away a line at a time as the reply reached the bottom, and with little room left kept the chat moving for a whole screen of reply (2026-10-29, issue 1436, #1509; the chat scroll's design is Claude's, 2026-09-28).
- A send, or a turn started on another device, makes room under the message: the transcript's content is at least the stop plus a screen tall, so the message moves to the top in one animated move once that room is laid out (none with Reduce Motion), and the reply streams into the room without moving anything. A short reply ends with empty room under it, as in Claude's and Gemini's apps. The room stays until the hold disarms (the jump button, the title tap, a jump to a question, a session switch, a reader below the reply's start), the reader scrolls away from it until none of it shows, or the next send, which lands in it and keeps it until the new message has a frame; while the content is no taller than the room, following holds the stop even if the room lags a pass behind a keyboard, a bar or a row shrinking. A send goes to the end before its message reaches the scroller, never to the last message's stop, so whichever arrives first the new message lands at the top. Switching Long replies off takes the room away at once. A reader who scrolls away from the room takes it away (nothing on screen moves: the content shrinks only below what they see), so coming back down ends at the reply's last row above the composer, not at the stop over empty room; the hold stays armed, so a reply still streaming is followed and stops at its start once it outgrows the screen. Switching Long replies off and on again afterwards doesn't bring that room back, nor does switching it on after a send made with it off: the reader has left it (2026-10-31, issue 1546, #1595; the chat scroll's design is Claude's). Group rooms, which share the switch, make no room: a room's send still goes to the end, and members' replies arrive whole and land at their top, so the Settings caption names chats for the move to the top. An unread chat opened at its reply makes no room: the reply is already there; it lands with the message at the top when the message is laid out, and with the reply's first row at the top when it isn't (2026-10-29, issue 1436, #1509).
- The stop never moves the offset up: a reader already below the reply's start (back at its end, or a reply that outgrew the screen before its message was laid out) follows on to the end. It holds at the turn's start, not the answer text, because a turn's steps fold and their summaries arrive below that point (2026-10-25, #1256).
- What arms it: a send, a new user message from another device, and opening a chat that was unread, which lands at the start of its latest reply once its transcript is in. The jump button, the title tap, a jump to a question and a session switch disarm it (2026-10-25, #1256).
- A chat's row draws in a hosting controller of its own and inherits nothing from the chat: what it reads of the chat's environment reaches it through TranscriptCellEnvironment, and a change reaches the rows drawn in place, their content as it is. A sheet, popover or dialog a row presents stays up when its cell is given to another row: the row's controller waits aside, in the transcript, until it closes. While one is up, every cell given to another row puts its row's controller aside, the presenting row's or not: UIKit's presentedViewController answers for an ancestor's presentation too, so a row can't tell it presented. A key Conduit adds is copied there, or listed in its setInsideRows when the rows set it themselves, where they read it; CI's check-transcript-environment.py fails one that's neither, a listed one nothing in Conduit sets, and one copied or applied from another key's value. The check sees only that something in Conduit sets a listed key, not where, so a key set above the transcript is copied, never listed (2026-10-31, #1577, #1586, under the transcript rewrite's design, which Eric approved 2026-10-30).
- A group room is drawn by the chat's transcript and moved by its scroller, by the same rules. A following room stops at the first new member message's start, 37 pt below the top, where a chat's stop puts the user's message, and the reader is left browsing there once what came runs past the screen; the stop holds through the message measuring taller than its guess, a message arriving while a fling moves the room stops it once the fling rests, as a chat's hold waits for a finger, and a later member message stops at its own start. Anything else new (a caption, a member starting or ending its turn) is followed to the end, what draws nothing new at the end (a turn's heartbeat, the oldest rows trimmed) leaves the stop where it is, and the jump button, a send, Retry and a quoted message's jump end the stop. Switching Long replies off, here or on another device, takes a following room's stop away at once, as it takes a chat's room. A long message opened with Show all keeps the row tapped where it is, as a chat's rows do. Its rows are 18 pt apart with 18 pt margins, as a chat's, where the room's stack had 14 and 16 (2026-10-25, #1256; on the transcript since 2026-10-31, #1590, under the transcript rewrite's design, which Eric approved 2026-10-30).
- An open group room keeps a bounded tail: it opens on the last 200 events, and polling trims back to 200 once it holds 400 (2026-10-24, #1184).
- The delegate tail sheet always follows its end: it is a live log, not a reply to read (2026-10-25, #1256).
- Nothing rebuilds a transcript. Chats and group rooms each rebuilt a following lazy stack that laid out no row on screen (#887, #971, #1367, issue 1358) until the transcript rewrite: their collection view lays out every row crossing the screen, at its measured or estimated height, so the lazy stack's blank screen can't happen there (chats 2026-10-31, #1577; group rooms 2026-10-31, #1590; Eric delegated the chat scroll's design to Claude, 2026-09-28, and approved the transcript rewrite's design, 2026-10-30).

**Open gaps**
- Group rooms have no "Load earlier messages", so history above the 200-event tail isn't reachable in the app.
- The Responding row reads the kept tail, so a discussion longer than 200 events (when opened, or after a trim) can lose it while a member still works.
- Trimming a busy room's tail, once per 200 new events, takes away the rows of a reader scrolled up to the oldest ones, who is left on what's at their place then; a reader whose rows stay keeps them where they were.
- Opening an unread chat lands at the reply after its last user message, so one whose unread rows came without a new user message (a cron or background result after an already read reply) lands at that older reply, not at the newest row; a chat with no user message at all stays at the end.
- A chat restored on launch (Continue where you left off) keeps its saved place, unread or not.
- A group room that opens empty scrolls its first events to the end: that batch is usually the room's history arriving, which should open at its newest row, so only events after a row already seen land at a member message's start.

**Checked:** 2026-10-31, #1595 (issue 1546: a reader who scrolls away from the room under a sent message until none of it shows takes it away, so back down the chat ends at the reply, not over empty room; group rooms not needed, they make no room; the Settings caption not needed, it describes the move to the top, which is unchanged; Code, Rulings, Tests); 2026-10-31, #1590 (group rooms move onto the transcript: GroupChatView draws its rows, GroupRoomTranscript's, on TranscriptView with a TranscriptScroller of its own, told of new events and of a member starting or ending its turn as the rows are built, so a following room stops at a new member message's start by the chat's hold and follows anything else to the end, and its jump button shows from the scroller's chrome; a turn's heartbeat or the oldest rows trimmed leave the stop where it is, Long replies switched off takes it away at once, and a member message arriving mid-fling stops the room once the fling rests; a hosted test mounts the room on the collection view, and the room rows' guesses are tested; GroupRoomScrollFollow, its blank-screen rebuild and that rebuild's trace are gone; the composer bar, ScrollViewReader and browsing-blank gaps closed, the trimming gap narrowed; Code, Rulings, Tests, gaps); 2026-10-31, #1586 (from #1577's review: a row not measured yet is guessed once per width and scope, and again when it draws something else, from its text's characters; a hosted test changes the chat's text size under the rows drawn, checking the latest row's frame is its cell's measurement; setInsideRows and the check say the check can't tell where a listed key is set; Code, Rulings, Tests); 2026-10-31, #1577 (chats draw on the transcript's collection view, which TranscriptScroller moves: the bars' and the keyboard's heights are its insets, read in the pass that applies them; a row changing height above a browsing reader keeps their row in that pass, under a finger and through a fling too; a chat has no blank-screen rebuild; ChatScrollEngine and its tests are gone, ported to TranscriptScrollerTests; the rulings #1566 departed from rewritten here and in Pictures in messages and Cards drawn in web pages, and its Open gaps lines gone; the rows' environment copy and its CI check named, and a row's sheet outliving its cell tested; a row opened or closed keeps the tapped row; the rulings it changed name Eric's decisions; the content grows and shrinks with a row that changes height after it was measured (a reply streaming in), and stays the room held for a reply until the rows pass it; the environment check compares the values copied, and the soft top edge's modifier says the transcript's iOS 26 edge is set on the collection view; Code, Rulings, Tests, gaps); 2026-10-31, #1566 (TranscriptScroller, the chat's scroll rules in plain Swift with the engine's tests ported to it; nothing calls it yet, so nothing moves differently; Code, and the rulings it departs from in Open gaps, here and in Pictures in messages and Cards drawn in web pages); 2026-10-31, #1565 (the live rows the blank check counts are the ones TranscriptModel draws, by one rule; nothing moves differently; Code); 2026-10-31, #1554 (the chat recorder: every offset the engine writes goes through one write that names the rule in the trace, and the engine, the chat's scroll view and group rooms' locator feed ChatViewportWatch; nothing moves differently; see Crash and freeze reports); 2026-10-30, #1550 (an unread chat left mid-turn lands at its reply start from its saved rows, a landing the open's own switch keeps; Hermes' first rows after saved ones don't arm the hold, and saved rows that matched them still leave the engine's provisional state); 2026-10-29, #1509 (issue 1436: the stop puts the sent message at the top and the reply streams into room under it; group rooms not needed: their events arrive whole and already land at a member message's top, and the caption names chats for the send's move; Code, Rulings, Tests, Settings caption); 2026-10-28, #1455 (carrying #1431; following pins when the composer bar's height changes; Code, Rulings, gap); 2026-10-27, #1367 (the blank viewport check counts live rows and runs during a turn, and group rooms have it too; Code, Rulings, gaps); 2026-10-26, #1313 (the stop stays armed, so a reader a shrinking row estimate clamps back to the bottom stops again instead of following the reply to its end; ChatScrollHostedTests in Tests); 2026-10-26, #1290 (the check for another device's message goes by row id; Code); 2026-10-25, at #1270.

## Reconnecting to Hermes

How the chat connection comes back after it drops, and when it tries at
once instead of waiting out its backoff.

**Siblings:** a socket that closed (handleDisconnect) · the network path
changing · someone waiting by voice (a call's request, CarPlay back on
screen) · CarPlay, locked, Watch and CallKit calls with the app in the
background · a failed sync's retry · the backoff itself · the hidden
dashboard page's failed load

**Code**
- Reconnects: `Conduit/Services/AppState.swift` (handleDisconnect, scheduleReconnect, scheduleReconnectAfterFailedSync, networkPathChanged, reconnectNowForWaitingVoice, recoverTransportForCarPlayIfNeeded, handleCarPlaySceneWillEnterForeground, checkQuietTransportOffScreen, clientForVoiceRequest)
- A call's requests: `Conduit/Services/AppState.swift` (voiceBackgroundJobSupervisor's backend), `Conduit/Services/AppState+SpokenApprovals.swift` (respondToApprovalByVoice, respondToClarifyByVoice)
- Network path: `Conduit/Services/PowerPolicy.swift` (pathSatisfied), `Conduit/Services/HermesClient.swift` (networkPathChanged, the ping of an open socket, checkLiveness)
- The hidden dashboard page: `Conduit/Services/DashboardTicketBridge.swift` (waitUntilReady, mintCookieTicket, requestJSON)
- Tests: `ConduitTests/ReconnectBackoffTests.swift`, `ConduitTests/CarPlayTransportRecoveryTests.swift`, `ConduitTests/HermesClientTests.swift` (the liveness check), `ConduitTests/DashboardTicketBridgeTests.swift` (testRequestOnAFailedPageReloadsIt, testConcurrentRequestsOnAFailedPageReloadItOnce, testRequestLeavesALoadInFlightAlone)

**Rulings**
- A reconnect that skips the backoff needs a usable network path: without one no attempt can work, and the path coming back reconnects at once anyway. A drop mid-reply and someone waiting by voice both check it (#1060; #846 follow-up, #1191).
- The network path changing reconnects at once without reading the path: it runs before the path monitor holds the new one, so a check there would stall recovery for the whole backoff (#1191).
- Someone waiting by voice skips the backoff but keeps its count, so one request after another against a gateway that is down doesn't reset it (#1060).
- The path change's ping of an open socket waits while a large frame (a picture) is still being written: its pings can't be answered in time and would close a working socket. A path that really died fails the write (2026-10-25, #1268).
- A call's request to Hermes made while Conduit is off screen (CarPlay, a locked phone, a Watch call, a call from Hermes; every voice mode, spoken approvals and answers included) first pings a socket that has been quiet 30 s, as the phone coming on screen does: iOS may have held Conduit suspended until the car or the call woke it, and a socket that died then still looks open. Starting, titling and cancelling a call's jobs count, and so does asking whether a chat is busy before its turn. One that doesn't answer in a keepalive ping's 10 s (a relayed path can be slow off screen without being dead) is closed and the request waits for the reconnect, as after any drop. Before, GPT-Live started from CarPlay ran (it starts over HTTP) while every request it handed Hermes waited on the dead socket until it timed out (2026-10-27, #1382, from #1362).
- The hidden dashboard page comes back with the next dashboard request, not only with the next ticket: any request (chat history, status, a ticket) reloads a page whose load failed, and one still loading is waited for, never restarted. A request that stalled across a Wi-Fi change marks the page failed while the socket stays open, and an open socket mints no ticket, so before, every history and status read was refused with "still connecting to your dashboard" until the app quit (2026-10-30, #1526, issue 1412).

**Open gaps**
- `recoverTransportForCarPlayIfNeeded(immediately:)` still reconnects at once without a path check (CarPlay connecting only).

**Checked:** 2026-10-30, #1526 (the hidden page reloads a failed load on any request); 2026-10-28, #1452 (a drop on a socket handed on at a profile switch reaches the client holding it); 2026-10-27, #1382 (a call's request off screen checks a quiet socket first); 2026-10-25, at #1268; 2026-10-24, at #1191.

## Native sign-in browser

The browser a native (PKCE) dashboard sign-in opens in, and the Private
sign-in page switch that makes it start fresh.

**Siblings:** the sign-in screen's Advanced card (Add a dashboard) ·
Repair's Sign In to Reconnect · Settings' Sign In Again · the saved
dashboards screen · the switch's captions in 13 languages · the embedded
browser sign-in (AuthWebView, a different flow) · the bot MCP sign-in
browser (separate)

**Code**
- Browser and setting: `Conduit/Services/NativeOAuth.swift` (NativeOAuthBrowserPreference, NativeOAuthSignInSheet, WebAuthenticationPresenterViewController, NativeOAuthLoginModel.run)
- The switch: `Conduit/Views/Login/LoginScreens.swift` (PrivateSignInPageToggle, advancedFields)
- Error shown when the page fails: `Conduit/Services/ConnectionFailure.swift` (ConnectionFailure.signInPageFailed, ConnectionFailureClassifier.classify), `Conduit/Services/ConnectionSetupFlow.swift` (repairPath: a failed page goes to the staged test)
- Repair and Sign In Again: `Conduit/Views/ConnectionSetupForm.swift` (repairReviewFooter, settingsSignInAgain), `Conduit/Views/ConnectionSetupView.swift` (repairSignInSheet), `Conduit/Services/ConnectionRepair.swift` (ConnectionRepairSignIn.mayOpenNativeSignIn, showsPrivateSignInSwitch)
- Saved dashboards screen: `Conduit/Views/Login/LoginScreens.swift` (LoginDashboardsScreen.mayOpenSignInPage)
- Tests: `ConduitTests/ConnectionRepairTests.swift` (testPrivateSignInSwitchShowsOnlyWhereSignInCanBeNative, testRepairRoutingStartsNearTheClassifiedProblem), `ConduitTests/ConnectionFailureTests.swift` (testNativeSignInBrowserFailureClassifiesAsSignInPageFailed, testNativeSignInFailuresNeverClaimBadCredentials)
- Embedded browser sign-in: `Conduit/Views/LoginView.swift` (AuthWebView)
- Bot MCP sign-in, its own browser: `Conduit/Views/BotCapabilitiesView.swift` (BotMcpBrowserView)

**Rulings**
- A native sign-in that opens the sign-in page opens it in an ASWebAuthenticationSession, not ephemeral by default, so the provider's page can remember the account between sign-ins. iOS asks "Conduit wants to use … to sign in" before a non-ephemeral session opens. Hermes accepts only a loopback redirect, so the code still arrives through the loopback listener and Conduit closes the browser itself (2026-10-26, #1329).
- Private sign-in page makes each new browser session ephemeral, so a sign-in that opens the page shows every way the provider offers (a login code as well as a passkey) and can pick another account. It doesn't skip a saved grant: NativeOAuthLoginModel.run signs in with one without opening the page (2026-10-26, #1329).
- The switch, with the caption for its setting inside its label, shows only where a native sign-in can start: the sign-in screen's Advanced card; Repair's Sign In to Reconnect and Settings' Sign In Again when the test's sign-in is native or a choice the capability check may still send to Safari, never when it is the embedded browser, which doesn't read it; and the saved dashboards screen while a row signs in without a saved password, since that row's discovery decides native or embedded browser on the tap (a list of password dashboards never shows it). Each place has its own accessibility identifier (2026-10-27, #1329, Eric).
- A browser that fails or doesn't start reports "The sign-in page couldn’t open" through the sheet's error; only the user closing it is a cancellation, and a closed browser never reopens. Repair's Sign In to Reconnect and Settings' Sign In Again classify it as ConnectionFailure.signInPageFailed and show that message above their sign-in button, not the generic connection failure. Their other native sign-in failures classify too: an HTTP status as at provider discovery (a 401 or 403 is never bad credentials), a malformed answer as an unexpected response (2026-10-27, #1329, #1343).

**Open gaps**
- To switch accounts on a dashboard with a saved grant, sign out first; the switch alone keeps the grant.
- Whether the session shares MobileSafari's own sign-in depends on iOS; in simulator testing with Pocket ID it kept only its own session.

**Checked:** 2026-10-27, at #1343, carrying #1329.

## Dashboard sign-in redirects

When an auth proxy in front of the dashboard (an oauth2-proxy-style edge,
a Cloudflare Access gate) sends a dashboard request to sign in instead.

**Siblings:** the hidden dashboard page · requests sent without it
(background requests and file downloads) · the background session's
redirect rule · the dashboard socket's handshake · the login screen's
signed-in check

**Code**
- The decision: `Conduit/Services/DashboardSignInRedirect.swift` (isSignIn, redirectIsSignIn, isSignInPath)
- Page: `Conduit/Services/DashboardTicketBridge.swift`
- Requests: `Conduit/Services/DashboardBackgroundRequests.swift` (the redirect rule and a returned redirect), `Conduit/Services/DashboardFileDownload.swift`
- Socket: `Conduit/Services/DashboardWebSocketSession.swift` (DashboardSocketHandshakeError.failure)
- Login: `Conduit/Views/LoginView.swift` (isSignedInDashboardPage)
- Tests: `ConduitTests/DashboardProxySignOutTests.swift`

**Rulings**
- One decision for the page, the requests and the socket: any web address on another origin is sign-in, and on the dashboard's own origin only a sign-in page is (#731 follow-up, #1191).
- The dashboard's own host moving from http to https, on https's port or the dashboard's own, counts as its own origin; another port on that host is another origin (#1191).
- A handshake redirect is never followed, so the ticket never goes along.

**Open gaps**
- The background session's redirect rule and the login screen's signed-in check compare origins strictly, without the http to https allowance: such a redirect comes back as the response (and is judged by isSignIn there), and the login screen with a dashboard saved on http behind a TLS edge hasn't been checked.
- The hidden page doesn't follow that upgrade either: its navigation policy cancels an http to https move to an ordinary page as a failed load (no longer as sign-in), so a dashboard behind a TLS-forcing edge must be saved on https. Following it would take the page's landing and script-message checks and the socket off the saved origin, so it was left as is (#1191 review).

**Checked:** 2026-10-30, #1526 (any request, not only a ticket, reloads a page whose load failed, so a reload that lands on sign-in now reaches a history or status read as sign-in required, where it got "still connecting" before); 2026-10-26, #1247 (the hidden page's deinit removes its script handler on the main actor); 2026-10-24, at #1191.

## Skill and tool switches

The installed skills' and toolsets' switches in Settings > Capabilities, and
the lists they sit in.

**Siblings:** installed skills and toolsets (AppState) · the catalog, tool
counts, backends, MCP servers and plugins (CapabilitiesStore) · the Skills
and Tools tabs · the Connectors tab's list and server page (their tests) · the bot editor's skills, tools and MCP lists (see Bots:
create and edit) · the skill, toolset and catalog skill detail pages · the Kanban
task composer's skill picker · a connector's editor (Edit Server: the form
and the JSON, as Hermes Desktop's mcp.json editor) · a catalog connector's
install sheet (its Runs line shows arguments the same way) · the Capabilities
captions ("Changes apply to new sessions."; the editor's footers) ·
README.md's Capabilities line

**Code**
- Installed lists and switches: `Conduit/Services/AppState.swift` (loadCapabilities, toggleSkill, toggleToolset, keepFlip, showKeptCapabilities, capabilitiesAreKept, canChangeCapabilities, capabilityLoadGeneration, capabilitiesOwner, currentCapabilitiesOwner, capabilitiesAreCurrent, capabilityRowsAreCurrent, retireCapabilitySnapshot, CapabilitySnapshotOwner, CapabilityDetailScope, CapabilityLoadPolicy), `Conduit/Services/CapabilityToggleWrites.swift` (Outcome's taken)
- The rest of the page: `Conduit/Services/CapabilitiesStore.swift` (configure, serves, showsKept, probe, probeServers)
- Views: `Conduit/Views/CapabilitiesView.swift`, `Conduit/Views/Capabilities/CapabilitySkillsTab.swift`, `Conduit/Views/Capabilities/CapabilityToolsTab.swift`, `Conduit/Views/Kanban/KanbanTaskComposerView.swift` (KanbanSkillsPickerSheet)
- Connectors tab: `Conduit/Views/Capabilities/CapabilityConnectorsTab.swift` (CapabilityConnectorsTab's tests, ConnectorDetailPage, its first test waiting for Hermes' list when the kept one shows)
- Editing a connector: `Conduit/Models/CapabilityCatalogModels.swift` (ConnectorServerEdit, ConnectorServer.saved, ConnectorServer.argumentText, used by ConnectorServer.list and ConnectorCatalogEntry.list), `Conduit/Services/CapabilitiesStore.swift` (serverConfig, saveServer), `Conduit/Views/Capabilities/CapabilityConnectorsTab.swift` (ConnectorDetailPage, ConnectorEditSheet)
- Tests: `ConduitTests/KanbanTests+Capabilities.swift`, `ConduitTests/KanbanTests.swift` (CapabilityLoadPolicy), `ConduitTests/AppStateMultiDashboardTests.swift` (testCapabilitiesOpenOnTheSkillsAndToolsetsHermesGaveLastTime)

**Rulings**
- A list read that started before a switch was flipped commits nothing, in AppState and in CapabilitiesStore alike (#867; AppState's lists at #1191).
- The lists open on the copy kept on the phone (Screens that open on their last answer). A switch Hermes took is kept in it, over any read asked before it, and one it refused never is, a flip a newer one replaced (which reports no failure) included; one flipped on a kept list, taken or refused, reads the lists again, since the read on its way no longer commits, and the bulk switches wait for Hermes' answer. Offline, where only the kept lists show, the switches and the bulk switches are off until a dashboard connects, since a flip has nowhere to go (#1569).
- Switches reach Hermes one after another in the order flipped, since each rewrites one config.yaml. A failed write puts back what Hermes last confirmed only when no newer flip of that switch is on its way, and a flip a newer one replaced reports no failure (#868 follow-up, #1191).
- The installed lists belong to a dashboard, its bridge and a profile, not a profile name: two dashboards can both have "default". Another dashboard's rows never show, act or seed a picker, a dashboard switch clears them, and Turn All On/Off stops once the list it started from isn't the one showing, and a pushed detail page reads its skill or toolset again once Capabilities points at the new dashboard and profile; a catalog skill's page keeps to the one it was opened for and shows only its name and description after a switch (2026-10-24, #1005, #1219; Eric approved the #1005 fixes).
- Switches, the store's other config-changing writes and the bot editor's writes wait their turn with every other profile config save (Profile config saves), so a settings GET→PUT can't put a flip back (2026-10-24, #1222).
- A connector test runs to its answer once sent, even when the list or page that started it goes away (opening a server from the list cancels the list's tests), and leaving the list starts no more. A test cancelled under it (the dashboard gone) records nothing, so it's tested again rather than shown as "interrupted"; the server page then says it's untested (Eric asked for issue 1570's fix, 2026-10-31, #1574).
- A connector is edited where it lives: the profile's `mcp_servers` in config.yaml, read with `include_defaults=false` so `${NAME}` key references stay references and keys stay in .env. The form changes the name, address, command and arguments and keeps every other key; an argument line left as it was keeps its value, and a whole number typed in place of a number argument stays a number (other text, "007" or "1.10" included, is saved as typed). The JSON is the whole entry. Saving reads the map again and writes it back whole (`PUT /api/mcp/servers`, Desktop's mcp.json save) in one turn of the config queue, so the other servers go back as the host had them a moment before (a Desktop or terminal write landing between those two requests is still overwritten, Profile config saves' open gap); both go to the dashboard and profile the editor opened on, and after a switch nothing is written and the editor says so. A server the host changed while the editor was open is refused rather than overwritten, and a test of the old entry still running is run again on the saved one. When the list can't be read again after a save, the saved server is shown from its entry alone (a key it leaves out is the default), so a renamed page doesn't say it's gone and the re-test follows the saved on/off. The server page, the saved row, the editor and a catalog connector's install sheet show number arguments as written and true/false as words (Eric asked for #1574's review gaps closed, 2026-10-31, #1578). A rename that would take another server's name is refused, an OAuth server's rename says it signs out (Hermes keeps tokens by name), a plugin's server has no Edit, and a Hermes without the route says to update (Eric asked for editing 2026-10-31, #1574, issue 1570).

**Open gaps**
- Whether a list read can overwrite a flip in the bot editor's lists hasn't been checked.
- The Kanban skill picker says "No skills match." when it withholds another dashboard's skills, the same as a search miss.

**Checked:** 2026-10-31, #1578 (edited number arguments stay numbers; a renamed server shows after a failed reload); 2026-10-31, #1569 (the lists open on their kept copy and a switch Hermes took is kept in it, never one it refused; offline the switches wait for a dashboard; AppState's list reads are tested through held dashboard requests, its generation guard included, closing a gap; with #1574 merged in, a server's page waits for Hermes' list before its first test and a connector edit counts as a change, see Screens that open on their last answer); 2026-10-31, #1574 (connector tests outlive the page that started them; Edit Server); 2026-10-24, at #1219 and #1222.

## Reply progress signals

Everything that reacts to a turn's output as it arrives: the agent's text,
and its commentary between tool calls (`message.interim`).

**Siblings:** the compaction spinner's release · the Live Activity's writing
state · a call's background jobs (follow-up, status, session) · Local Live's
writing-again · the writing haptic · Classic speech (phone, CarPlay and calls
from Hermes: commentary is said, see Acknowledging work handed to Hermes)

**Code**
- Events: `Conduit/Services/StreamEventParser.swift`, `Conduit/Services/AppState.swift` (handleStreamEvent, the compaction release)
- Live Activity: `Conduit/Services/LiveTurnActivities.swift`
- Calls: `Conduit/Voice/VoiceBackgroundJobs.swift`, `Conduit/Voice/LocalLive/LocalLiveTurnRunner.swift`
- Haptics: `Conduit/Services/Haptics.swift` (signal)
- Classic: `Conduit/Voice/VoiceTypes.swift` (VoiceAssistantEvent), `Conduit/Services/AppState.swift` (interim/completion voice notifications), `Conduit/Voice/VoiceConversationController.swift` (speech-segment boundaries)

**Rulings**
- Commentary between tool calls is the agent writing, wherever its text is: it releases a compaction claim, shows as writing and moves a call's job along (#912 follow-up, #1191). Classic says it aloud, as Hermes' acknowledgement; nothing else speaks it (Eric 2026-10-27, #1390).

**Open gaps**
- `Haptics.signal` still plays the writing haptic only for `message.delta`.

**Checked:** 2026-10-28, #1449 (Local Live's screen shows a reply's attached files, even beside a card); 2026-10-28, #1430 (Local Live's spoken stream passes the action filter; its writing state is unchanged); 2026-10-27, #1390 (Classic speaks commentary, carried from #1384); 2026-10-27, #1374 (the Live Activity's registration only; its writing state is unchanged); 2026-10-24, at #1191.

## Live Activity for a running turn

The Lock Screen and Dynamic Island card for a turn Conduit sent: started when
the prompt is accepted, kept current from the chat's stream while Conduit
runs and by the Conduit plugin through the push relay once it doesn't, and
ended when the turn ends.

**Siblings:** the stream's states (LiveTurnProgress) · the live registry check
when Conduit is back (reconcile) · the card's push token, registered with the
relay · the plugin's reporter (phases, tool categories, context, ends) · the
relay's route, which turns reports into Live Activity pushes · the widget's
Lock Screen and Dynamic Island views · Settings > Notifications > Progress on
the Lock Screen · a tap on the card, which opens the chat · the plugin's
CHANGELOG

**Code**
- App: `Conduit/Services/LiveTurnActivities.swift` (turnStarted, observe, reconcile, register, registerUnregistered), `Conduit/Services/PushNotificationService.swift` (registerLiveActivity), `Conduit/Services/AppState.swift` (the turnStarted call, liveTurnActivitiesRegistrySnapshot)
- Widget: `Shared/Widgets/HermesTurnActivity.swift`, `ConduitWidgets/HermesTurnLiveActivity.swift`
- Notifier: `notifier/live_activity.py` (the reporter, compacted_from), `notifier/__init__.py` (the hooks that feed it), `notifier/relay/src/live-activities.mjs`, `notifier/relay/src/server.mjs`

**Rulings**
- Only a phase, a tool category from a fixed list, a tool count and a context percentage cross the relay; the chat's title stays on the phone (#605, notifier #111).
- A turn's end reaches its card three ways: the stream while Conduit runs, the plugin through the relay, and the live registry once Conduit is back. The relay keeps an end reported before the phone registered the card, and ends a card registered later if it started before that end, never the chat's next turn's (2026-10-27, issue #1361, #1374, notifier #421).
- A turn that a compaction moves to a new session id reports and ends under the id the card was registered with (2026-10-27, #1374, notifier #421).
- A fork of the chat (Predictions' `/predict`, step summaries' /btw, the self-improvement review) never starts, moves or ends its card, even on a Hermes that runs plugin hooks for forks (2026-10-29, #1495 carrying #1489, notifier #464 carrying #462; see Notifications).
- The card's registration runs as a background task, so it finishes when Conduit leaves the screen right after sending, and one that didn't reach the relay is sent again when Conduit is next on screen (2026-10-27, #1374).

**Open gaps**
- The relay keeps registrations and unwatched ends in memory: a relay restart during a turn leaves its card to Conduit's next time on screen, or to iOS's 8 hours.
- The live registry check reads the profile and dashboard on screen, so a card from another one ends only by push.
- The registration and its retry go through `URLSession.shared`, so only their decisions (`needsRegistration`, `liveActivityStartedAgo`, `liveActivityRouteExists`) are tested.

**Checked:** 2026-10-29, #1495, carrying #1489 (a chat's fork never touches the card, notifier #464); 2026-10-27, #1374.

## Large code blocks in messages

A code block too big to draw at once: its collapsed preview, its line
count and the expanded block.

**Siblings:** the collapsed preview · "Show all N lines" · the expanded
block, drawn in slices · Copy

**Code**
- Slicing: `Conduit/Views/Components/MarkdownLargeDocument.swift` (MarkdownCodeSlicer)
- The block: `Conduit/Views/Components/MarkdownLargeDocumentView.swift` (the code block view, lineStats)
- Tests: `ConduitTests/MarkdownLargeDocumentTests.swift`

**Rulings**
- The slices put back together are exactly the source, so Copy and round trips stay exact.
- A line ends at a `\n` byte, so a block with Windows line endings counts each line once (#894 follow-up, #1191).

**Open gaps**
- `MarkdownCodeSlicer.slice` still splits on a Character `"\n"`, where `"\r\n"` is one Character, so a block with Windows line endings is sliced by its byte budget only.

**Checked:** 2026-10-30, #1524 (a Desktop card is its own block, counted like a preview; slicing unchanged); 2026-10-24, at #1191.

## Model lists that fail to load

What a model picker shows before Hermes's model catalog has rows: still
loading, a fetch that failed, or a gateway that lists no models.

**Siblings:** the model sheet · the Model page's Default model, Delegate
model and Fallback models editors · a bot's model picker · the voice job and
voice reply model pickers · Settings > Pulse's model picker · the Kanban model
override's catalog (in the task composer and on a task's page)

**Code**
- The rule: `Conduit/Views/ModelPickerView.swift` (ModelCatalogState, KeptModelCatalog, and the model sheet's modelSection, searchResultsSection, catalogFailedRow, modelRowsLocked, loadModels), `Conduit/Services/HermesClient.swift` (modelOptionsAnswer: an answer that isn't one is a failed read)
- Model page: `Conduit/Views/AuxiliaryViews.swift` (ModelCatalogPlaceholder, ProfileModelSettingsDetail, DelegationModelSettings, FallbackModelsSettings)
- Bots: `Conduit/Views/BotModelPicker.swift` (load, loadFailedRows)
- Voice and Pulse: `Conduit/Views/GeminiLiveViews.swift` (the voice job and voice reply model settings: VoiceJobModelSettingsSection.loadProviders and modelsAnswered, VoiceReplyModelSettingsSection.read, tryAgain, reloadProviders and modelsAnswered, VoiceReplyModelPicks.readDidFail), `Conduit/Views/PulseSettingsViews.swift` (Settings > Pulse's model picker, loadModels and modelsAnswered), `Conduit/Views/AuxiliaryViews.swift` (ModelCatalogPlaceholder's failed row under them), `Conduit/Services/AppState.swift` (loadModelProviders, keptModelProviders)
- Kanban: `Conduit/Views/Kanban/KanbanTaskComposerView.swift` (KanbanModelOverrideSheet's catalogSection, showKept, optionsAnswered and loadOptions), `Conduit/Services/KanbanService.swift` (fetchModelOptions keeps an answer with a model to offer; offerable), `Conduit/Services/KanbanStore.swift` (keptModelOptions), `Conduit/Models/KanbanModels.swift` (KanbanModelOptionsResponse drops a provider row it can't read on its own)
- Tests: `ConduitTests/KanbanTests.swift` (testTheModelOverrideOpensOnTheRosterItListedLastTime), `ConduitTests/KanbanV2Tests.swift` (testModelOptionsDecodeTolerantly)

**Rulings**
- A failed fetch says "Could not load models." with Try Again; "No models are available from this gateway." is only for a catalog that loaded empty; neither shows while loading. A re-load that fails keeps the rows it had (2026-10-24, from #1016's review).
- A list that didn't load is never edited or saved: Save stays off until the catalog is in.
- The Model page's editors open on the catalog kept from Hermes' last answer (see Screens that open on their last answer); a read that fails leaves it up with "Could not load models." and Try Again under it, and Save stays off until Hermes answers (#1552). A Default model save reads the catalog again after, so the provider it marks in use, whose models an inherited delegate shows, follows the save (#1555).
- The model sheet and a bot's model picker open on the models kept from Hermes' last `model.options` answer the same way, with "Could not load models." and Try Again under them (under the sheet's search matches too) after a read that fails; their kept models wait for Hermes' answer before they can be picked (#1567).
- The voice job, voice reply and Settings > Pulse pickers keep the models they list (kept from Hermes' last answer, or none) when the read fails, and say "Could not load models." with Try Again under the Model menu, which waits for Hermes' answer before a model is picked, as the sheet's rows do. The voice reply section says it when the read of its setting fails too, with a setting kept (with none it stays hidden, as on a Hermes without the slot, until the page's next check asks again), its Try Again asks for both, and a failure older than the answer shown says nothing (#1567).
- The Kanban model override, in the task composer and on a task's page, opens on the roster the kanban plugin gave last time, kept once per dashboard, and its models wait for the plugin's answer before one is picked. A read that fails keeps them up with "Could not load models." and Try Again, the free-text entry under them; "No curated model catalog available" and the free-text entry are otherwise only for a roster that loaded empty, and neither shows before the first read answers. A roster with nothing to offer (a plugin whose inventory is down) is shown but never kept over the last one. Try Again over a kept roster shows no loader, as the model sheet's doesn't (#1584). A provider row Conduit can't read drops on its own, so one bad row never empties the roster (#1588, from #1584's review).

**Open gaps**
- None known.

**Checked:** 2026-10-31, #1588 (from #1584's review, a provider row the Kanban override can't read drops on its own, never the whole roster); 2026-10-31, #1584 (the Kanban model override opens on its kept roster, picked once the plugin answers, and says a failed read with Try Again, closing its gap; from its review, neither the empty roster's note nor the free-text entry shows before the first read answers, and a roster with nothing to offer isn't kept); 2026-10-31, #1567 (the model sheet and a bot's model picker open on the kept models, picked once Hermes answers, and the bot picker's failed read offers Try Again, closing its gap; the voice and Pulse pickers say a failed read with Try Again, the voice reply section's setting read included, closing theirs, and their Model menus wait for Hermes' answer); 2026-10-31, #1563 (the voice and Pulse pickers' loader, loadModelProviders since #1558, and its gap brought up to date; nothing else changed); 2026-10-31, #1555 (a Default model save reads the catalog again for its kept copy; the Save buttons' rule moved to KeptAnswerGate); 2026-10-31, #1552 (the Model page's editors open on a kept catalog, with Try Again under it when the read fails); 2026-10-27, at #1395 (search matches show only once the catalog is in; loading, failed and empty states unchanged, the Kanban composer's included); at #1334 (the model sheet's loading, failed and empty states unchanged under its new error row); 2026-10-24, at #1190; a reload that lands under unsaved Fallback models edits keeps them at #1191 (#1016 review).

## The Model sheet's settings

How the composer's Model sheet changes the chat's model, reasoning, speed and
YOLO: each one applies when it's tapped, with no Apply step.

**Siblings:** the sheet's Model rows and search matches (tapped, or picked
with Return), Reasoning pills, Fast mode and YOLO toggles · the composer's
reasoning chip · typed `/model` (opens the sheet),
`/fast` and `/yolo` · a bot's model picker and the Model page's Default,
Delegate and Fallback model editors (not siblings: they're saved with the bot
or the profile, not live session settings)

**Code**
- Sheet: `Conduit/Views/ModelPickerView.swift` (switchModel, runModelPickerSwitch, modelPickerShouldSwitch, modelRowsLocked, applySpeed, applyYolo, applyReasoning)
- Chip and writes: `Conduit/Views/Components/ComposerBar.swift` (the reasoning chip), `Conduit/Services/AppState.swift` (setReasoningEffort, setYoloModeReportingFailure), `Conduit/Services/HermesClient.swift` (setModel, setSpeed, ModelSwitchOutcome)
- Tests: `ConduitTests/ModelPickerTests.swift`

**Rulings**
- Every control applies on tap, like Settings; the sheet has no Apply button and stays open (Eric, 2026-10-27, #1333, #1334).
- A model Hermes wants confirmed asks on the tap; Cancel leaves the checkmark on the model the session still runs. A failed switch puts it back too and says why under the list.
- A switch made mid-turn is held by Hermes for the next turn, and the sheet says it switches when the reply finishes.
- Switching to a model without Ultrafast drops Ultrafast to Fast.
- Errors show in their own section of the sheet, since the composer's banner is behind it.

**Open gaps**
- The checked row doesn't follow a model changed elsewhere while the sheet is open.

**Checked:** 2026-10-31, #1567 (the sheet opens on the models kept from Hermes' last answer, whose rows switch once Hermes answers; a row being switched to keeps its check when an answer lands); 2026-10-27, at #1395 (a search match switches like a tapped row, through the same pick); at #1334.

## Searching for a model

Typing part of a model's name in a model picker to find it, where each match
names the provider that serves it, since several providers often offer the
same model and the pick switches to that provider's route.

**Siblings:** the model sheet (iPhone, iPad and Mac) · a bot's model
picker · the Kanban task's model override · the model sheet's Edit
(visibility) search (not needed: its matches sit under their provider's name)
· the Model page's Default, Delegate and Fallback model editors and the voice
job and voice reply model pickers (not needed: the provider is picked first,
or the menu row already reads "model · provider") · Text (not needed: no
README, docs or Settings caption describes the pickers)

**Code**
- Matching and the result row: `Conduit/Views/ModelSearch.swift` (ModelSearchQuery, modelSearchMatches, modelSearchHighlight, modelSearchFocusesOnOpen, ModelSearchResultText)
- Model sheet: `Conduit/Views/ModelPickerView.swift` (searchField, searchResultsSection, pickHighlightedMatch, modelRow's showsProvider)
- Bots: `Conduit/Views/BotModelPicker.swift` (searchResults)
- Kanban: `Conduit/Views/Kanban/KanbanTaskComposerView.swift` (KanbanModelOverrideSheet's searchMatches)
- Tests: `ConduitTests/ModelPickerTests.swift`

**Rulings**
- Every match shows its provider under the model; the same model from two providers is two matches (Eric, 2026-10-27, #1388).
- Every word typed must appear in the model's id or label or the provider's names, so "sonnet openrouter" finds one provider's Sonnet.
- The model sheet's search hides models and providers hidden with Edit; Edit's own search still finds them.
- On a Mac or with a hardware keyboard the sheet opens with the search focused, ↑ and ↓ move a highlight, Return picks the highlighted match as a tap would (the sheet stays open, per "The Model sheet's settings") and Esc closes the sheet. On touch the keyboard stays down until the field is tapped, and Return only puts it away.

**Open gaps**
- A hardware keyboard connected while the sheet is open doesn't turn on the highlight until the sheet opens again.

**Checked:** 2026-10-31, #1567 (the sheet and a bot's picker search the models kept from Hermes' last answer until it answers, their matches waiting for it like their rows, and the sheet says a failed read under its matches); 2026-10-27, at #1395.

## Files over the size limit

What Conduit says when a file is too large to attach, and which limit it
names.

**Siblings:** the chat composer (picker, drop, camera) · pasting into the
composer · the share extension · Ask Hermes About Screen · a recorded voice
message · the group room composer · the Settings caption for the limit

**Code**
- The limit and its message: `Conduit/Views/Components/ComposerAttachments.swift` (AttachmentSizeLimit, tooLargeMessage)
- Chat composer: `Conduit/Views/Components/ComposerBar.swift`
- Paste: `Conduit/Views/Components/ComposerPasteTextView.swift`
- Dropped files: `Conduit/Views/Components/AttachmentDrop.swift` (through AttachmentStaging.stageCopy, the Document picker's path)
- Share extension: `Conduit/Services/AppState+ShareDraft.swift`
- Ask Hermes About Screen: `Conduit/Intents/AskHermesAboutScreenIntent.swift`
- Voice message: `Conduit/Services/AppState+VoiceMessage.swift`
- Group rooms: `Conduit/Services/GroupRoomFiles.swift` (stagingLimit, tooLargeMessage), `Conduit/Views/Components/GroupRoomComposer.swift`
- Settings: `Conduit/Views/AuxiliaryViews.swift` (the attachment size limit setting)

**Rulings**
- The message names the limit that refused the file. When that is the user's Settings limit it says where to raise it; when it is a route's own cap at or below the Settings limit (a group room takes 50 MB), it names that cap and offers no setting (2026-10-24, from #935's review, #1190).

**Open gaps**
- The voice message says "larger than your attachment size limit" without the size or where to change it.
- A pasted picture link whose header claims more pixels than a reply's picture may have is refused as "The image provider returned invalid image data.", not as too large.
- The Settings caption doesn't say that a group room takes at most 50 MB whatever the limit.

**Checked:** 2026-10-29, #1515 (a long paste over the limit isn't attached: it goes into the field, as pastes did before); 2026-10-28, #1411 (dropped files refused with the same limit and message as picked ones); 2026-10-24, at #1190; the paste's pixel bound at #1191 (#892 review).

## Sending files in a chat

How a message's pictures and files go up to Hermes before the prompt, and
how long a large one may take on a slow link.

**Siblings:** the chat composer (picker, drop, camera, paste, a long paste as a text file) · the share
extension · Ask Hermes About Screen · a recorded voice message · Bot Chat and
project chats (the same send) · the group room composer (its own upload) ·
the socket's keepalive, the network path change's probe and the foreground
connection check · Settings captions, briefings, the notifier's tool text and
README (none describes upload size or timing) · the notifier (the upload is
Hermes' own RPC)

**Code**
- The send: `Conduit/Services/AppState.swift` (sendMessage: image.attach_bytes, file.attach when Hermes refuses the image, file.attach for every other file; a long paste's `title_preview`, `Conduit/Services/HermesClient.swift` sendPrompt, from `Conduit/Views/Components/PastedTextAttachment.swift` titlePreview)
- Resizing a picture: `Conduit/Services/PictureUpload.swift`, `Conduit/Services/AppState.swift` (AttachmentHelper.pictureForHermes)
- Budgets and the socket: `Conduit/Services/HermesClient.swift` (uploadTimeout, attachImage, attachFile, requestsBeingWritten, keepaliveQuietTimeLeft, probe, healthCheck; canHandOffSocket, which keeps a profile switch from handing on a socket mid-write, #1452)
- Group rooms: `Conduit/Services/GroupRoomFiles.swift` (timeoutMilliseconds)
- Tests: `ConduitTests/HermesClientTests.swift`, `ConduitTests/ComposerAttachmentPolicyTests.swift`

**Rulings**
- A picture sent as an image whose long edge is over 2048 px goes as a 2048 px JPEG (quality 0.85), upright, with a .jpg name, or a 2048 px PNG when some of its pixels are see-through (an alpha channel alone still goes as a JPEG); one that size or smaller, an animated one, or one the JPEG wouldn't make smaller goes as it is. The chat shows the picture as picked. Files sent as files are never changed (Eric, 2026-10-25, #1268, for #1265: a full-size photo on a slow link outlasted Hermes' own socket ping and dropped the connection).
- An upload's budget is two minutes, or about 1 s for every 64 KB it carries (about 0.5 Mbit/s) if that is longer, for a picture and a file alike; a group room's upload allows the same rate, with its own three-minute floor (2026-10-25, #1265 report: 3 to 4 MB photos failed now and then under the 30 s every request had).
- While a frame of 256 KB or more is still being written (a cancelled request's too), the keepalive, the network path change's probe and the foreground check don't ping: a ping queued behind it can't be answered in time and would drop a working socket. The request's own budget answers for the socket, and once it ends the pings come back; a cancelled request's frame counts until the socket finishes or fails the write, two minutes at most (2026-10-25, #1265 report).

**Open gaps**
- Files go up one after another as base64 over the chat socket; nothing shows how far an upload has got.
- The foreground check skipped behind an upload counts as passed, so a chat resumed then finds a dead socket only when that upload's budget ends or its write fails.
- An upload whose budget ends while its frame is still going out stops counting as written then, not when the socket finishes the write: the keepalive pings again, and a profile switch can hand the socket on behind it (#1452).

**Checked:** 2026-10-29, #1515 (a long paste goes as a text file with Desktop's title preview); 2026-10-28, #1452 (a profile switch's socket hand-off waits out a large write too); 2026-10-25, at #1268.

## Phone change errors

What Hermes and the user are told when a calendar, reminder or alarm change
can't be made on the phone.

**Siblings:** a change from a voice call (PhoneVoiceTools) · a change queued
by Hermes through the notifier (its result note) · the phone sync status line
· alarms and timers · the wording the notifier's tools give models · Pulse
(the `pulse_turn` refusal, and a suggestion's Add or Undo the phone store
refuses)

**Code**
- Calendar and reminder errors: `Conduit/Phone/EventKitPhoneSource.swift` (PhoneCalendarSourceError, apply, moveDestination)
- Alarm errors: `Conduit/Phone/PhoneAlarmSource.swift` (PhoneAlarmError)
- Voice tools: `Conduit/Phone/PhoneVoiceTools.swift` (the add, change, delete and alarm tools' catches)
- Queued changes and status: `Conduit/Phone/PhoneSyncEngine.swift` (record, lastError, describe)
- Notifier: `notifier/phone_tool.py` (the wording models read, `pulse_turn` among it), `notifier/pulse_proposals.py` (a suggestion's refusals)
- Pulse: `Conduit/Services/PulseSettings.swift` (PulseRefusal: what a suggestion's refusals say)

**Rulings**
- An error names what is missing: the item ("That item isn't on this iPhone any more."), or the calendar or list it was to move to, which leaves the item in place (2026-10-24, from #876's review, #1190).
- Voice tools turn only a missing item on a change or delete into "read the calendar again for its id"; every other error reaches the model as "It couldn't be changed: <reason>" (or added, deleted, set, cancelled) with the error's own text (2026-10-24, #1190).
- While a Pulse turn is in flight in Pulse's chat, `conduit_calendar` and `conduit_phone` refuse a change asked for from that chat, or from a call Hermes names no chat for, with `pulse_turn`: Pulse is taking a turn there and nothing in it can change the phone, so ask again once its message is in. A suggestion's Add or Undo that the phone store refuses shows the store's own note on the Pulse screen and leaves the suggestion to tap again; Undo before the phone has sent what it added says to try again in a moment (2026-10-27, notifier #417, #1356).

**Open gaps**
- Adding an event or reminder when the phone has no default calendar or list (and the one named is gone) says "That item isn't on this iPhone any more."

**Checked:** 2026-10-30, #1542 (All history stays after the host's 2000 limit and stops at the oldest reading; the stores needed no change); 2026-10-29, #1517 (the `pulse` branch merged into main: the app paths it lists are on main now; nothing else changed); 2026-10-27, at #1375, carrying #1356 from the `pulse` branch (Pulse's `pulse_turn` refusal and a suggestion's refusals, with notifier #417); 2026-10-24, at #1190.

## Live-call sends on a slow connection

How a live call's microphone audio, and the text turns and tool answers
sent beside it, go out when the connection stops taking them: in order,
with a bounded backlog, so a stalled socket doesn't pile up audio the model
can't use or hold text without end.

**Siblings:** Gemini Live · Qwen Live (its socket goes through the same writer) · Grok Live · Local Live · GPT-Live (WebRTC) ·
Classic's transcription streams · Watch calls (Gemini, Qwen, Grok, Local Live; GPT-Live over the host's audio bridge)

**Code**
- The writer: `Shared/GeminiLive/LiveVoiceSocketWriter.swift` (maxQueuedAudio, maxQueuedOther, Backlogged); what counts as audio: `Shared/GeminiLive/GeminiLiveProtocol.swift` (LiveVoiceClientMessage.isAudio)
- Sessions: `Shared/GeminiLive/GeminiLiveSession.swift`, `Shared/GrokLive/GrokLiveSession.swift`, `Shared/LocalLive/LocalLiveSession.swift`
- Watch: `ConduitWatch/WatchDirectCallModel.swift` (maxSendsInFlight, flushUplink; the same Gemini, Grok and Local Live sessions), `ConduitWatch/WatchBridgeCallModel.swift` (sendsInFlightLimit, eventsInFlightLimit, GPT-Live's bridge socket)
- Classic: `Conduit/Voice/SpeechServerTranscription.swift`, `Conduit/Voice/HermesLiveTranscription.swift` (sendChain)

**Rulings**
- Each connection's frames go out one at a time, in order. Up to 96 capture chunks of audio may be outstanding, the one on the socket included: for Gemini about two seconds of the tap's 1,024-frame buffers at 48 kHz (longer on a route that captures at a lower rate), and the same count of Grok's and Local Live's own chunks; audio past that is dropped as it arrives. Frames for a socket the session replaced fail instead of going out, and dropped audio is logged (2026-10-24, #1223).
- Text turns, context notes and tool answers are never dropped on their own. Up to 32 may be outstanding, the one on the socket included; one more means the socket stopped taking frames, so everything it holds fails and the session reconnects, each frame's failure handler handing its result back as for any failed send (2026-10-25, #1231).
- GPT-Live's audio on the phone is WebRTC's to pace; on the Watch it goes over the host's audio bridge, already capped at 20 sends in flight. The bridge's text events (Hermes' replies) are capped too: before each reply goes out, 32 events outstanding on the connection means the socket stopped taking them, so the Watch rejoins and the replies not yet sent stay pending for the new connection. A reply's chunks go out together, so one reply can take the count past 32. The check guards growth: a stalled socket with nothing more to send holds what it has, and the bridge's ping watchdog ends it (2026-10-25, #1231). Classic's transcription streams keep a whole utterance, since dropping audio there loses words (2026-10-24, #1223).

**Open gaps**
- On the Watch's GPT-Live bridge, a reply already handed to a socket that then drops is lost with it, on any dropped connection and not only a backlogged one: the bridge sends without asking for a confirmation, where the phone's writer hands a failed frame's result back.

**Checked:** 2026-10-28, #1424 (only audio the writer took counts toward the call trace's levels); 2026-10-25, Qwen in the siblings, at #1182, carried in #1235; #1231, for the text cap; 2026-10-24, #1223.

## Live call trace

The steps of the last Grok Live, Qwen Live or Local Live call that Diagnostics & logs
(Last connection) shows and copies, so a user can paste them into an issue:
setup, the microphone, the server's turn detection and the user's turns, and
each tool call.

**Siblings:** Grok Live (phone, CarPlay, calls from Hermes) · Local Live ·
Qwen Live (turn steps and the controller's tool steps) · Gemini Live and GPT-Live (no trace) · Watch
calls (no trace) · docs/VOICE_SETTINGS.md

**Code**
- The trace and its report: `Conduit/Voice/LiveCallTrace.swift`, `Conduit/Views/ChatSupportSheets.swift` (lastConnectionReport)
- Steps: `Shared/GrokLive/GrokLiveSession.swift`, `Shared/LocalLive/LocalLiveSession.swift`, `Shared/GeminiLive/QwenLiveSocket.swift`, `Shared/GeminiLive/GeminiLiveSession.swift` (onTrace), `Shared/GrokLive/LiveTurnTrace.swift`, `Shared/GrokLive/GrokLiveProtocol.swift` (turnDetectionSummary), `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift` (traceName, traceInputRoute)
- Wiring: `Conduit/Services/AppState.swift` (traceName, session.onTrace)

**Rulings**
- A long call keeps its first 20 steps (the setup) and its newest ones, up to 200, so a late turn that never ends is kept (2026-10-28, #1424).
- Event kinds, function names, routes and levels only: never what the user or the model said, a call's arguments or a tool's answer (2026-10-28, #1424, from #1418).
- The user's turns show when the server heard speech start and end, with the microphone's loudest and quietest 100 ms between them, and say once when 15 s of audio pass with no start or no end, so a turn the server never ends can be told apart from audio that never arrived (2026-10-28, #1424, from #1418).
- Qwen Live's trace has the turn steps, dropped microphone audio and the controller's tool steps; Grok's own session steps (setup, functions taken) have no Qwen counterpart (2026-10-28, #1424).
- A tool step is noted only while its call is still the current one, so a lookup that returns after hang-up stays out of the next call's trace (2026-10-28, #1424).

**Open gaps**
- Gemini Live sends no turn detection events and GPT-Live's turns run over WebRTC, so neither is traced; the Watch has no trace to show.

**Checked:** 2026-10-28, #1424.

## Narrated actions left out of speech

What a spoken reply leaves out that the chat keeps: a persona's narrated
actions in single asterisks or underscores, and emoji. Hermes' file tags
have their own entry, Files Hermes attaches, in what voices say.

**Siblings:** Classic voice (phone, CarPlay; streamed) · Read Aloud and its
Now Playing title · live read-back of a reply ("read me the last reply", in
Gemini, Qwen, Grok and GPT-Live) and the result a Hermes call reads out ·
Local Live (Hermes' words, streamed) · Gemini Live, Qwen Live, Grok Live and
GPT-Live with the Hermes personality (told not to say actions) · the chat
transcript (never filtered)

**Code**
- The filter: `Conduit/Voice/SpokenTextFilter.swift` (firstActionMarker, closingMarker, speakable)
- Classic voice: `Conduit/Voice/VoiceConversationController.swift` (spokenTextFilter)
- Read Aloud: `Conduit/Voice/MessageReadAloudController.swift`, `Conduit/Voice/ReadAloudNowPlaying.swift` (title)
- Read-back: `Conduit/Voice/VoiceReadBack.swift` (plainSpeech, line by line), read by `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift` (read_last_reply), `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift` (lastReplyText) and `Conduit/Voice/HermesCalls.swift` (a call's result)
- Local Live: `Conduit/Voice/LocalLive/LocalLiveTurnRunner.swift` (actions, after SpokenVisualSplitter)
- Persona instructions: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift`, `Conduit/Voice/GPTLive/GPTLiveConversationController.swift`
- Tests: `ConduitTests/GeminiLiveVoiceTests.swift` (testSpokenTextFilter…), `ConduitTests/VoiceBackgroundJobTests.swift` (plainSpeech), `ConduitTests/HermesVoiceGatewayTimeoutTests+LocalLive.swift` (testLocalLiveTurnLeavesNarratedActionsOutOfSpeech)

**Rulings**
- An action is three or more words between a single `*` or `_` pair on one line; emphasis ("*really*"), bold and snake_case are spoken (2026-09-28, 223fca85).
- As in Markdown, a marker followed by a space opens nothing and one after a space closes nothing, so "price * units sold * 12" is spoken; one after a space with a word right after it opens again (2026-10-28, #1429). A marker inside a word ("2*3", "4*5", snake_case) neither opens nor closes one (#1430). The Now Playing title strips emphasis, list and quote markers but keeps a spaced `*` within the line's words.
- Every path that speaks Hermes' own words drops actions, so a reply sounds the same in Classic voice, Read Aloud, a live read-back and Local Live; the live models that speak for themselves are told not to say them (2026-10-28, #1430).

**Open gaps**
- None known.

**Checked:** 2026-10-30, #1524 (Hermes Desktop's directives are read alongside, with their own entry, Cards made for Hermes Desktop); 2026-10-28, #1449 (Hermes' file tags are left out too, with their own entry, Files Hermes attaches); #1429, carried in #1430.

## Speech stream failures

What a spoken reply says when its speech stream fails partway: Classic voice
and Read Aloud speak through Hermes's speech stream or the user's speech
server.

**Siblings:** the Hermes speech stream · the speech-server speech stream ·
the one-shot fallback a Hermes stream falls back to before any audio · the
speech-server transcription stream (listening, not speaking)

**Code**
- Hermes speech: `Conduit/Voice/HermesVoiceGateway.swift` (HermesSpeechStream: pathLostError, armFinishIdleTimeout, socketWentSilent, the fallback)
- Speech server: `Conduit/Voice/SpeechServerSpeech.swift` (SpeechServerSpeechStream)
- Listening: `Conduit/Voice/SpeechServerTranscription.swift`
- Keepalive: `Conduit/Voice/VoiceSocketKeepalive.swift`

**Rulings**
- A dead Hermes speech stream is reported as a lost connection, not a timeout: "Lost the connection to Hermes speech." "Timed out" is only for a live stream that went quiet after some audio (2026-10-24, from #980's review, #1190). The speech-server speech stream can't tell yet (Open gaps); listening on a speech server says "Lost the connection to your speech server." when a send fails or the server closes early.
- Before any audio, a Hermes stream that drops or goes quiet tries the one-shot fallback instead of failing.

**Open gaps**
- The speech-server speech stream has no keepalive, so a dead path there shows as "Your speech server stopped speaking." after its idle timeout.

**Checked:** 2026-10-24, at #1208, carried in #1229.

## Profile config saves

Every change Conduit makes to a profile's Hermes config. Most are a GET, a
change and a PUT of the whole document, so two that overlap read the same
old config and the later one puts back what the earlier one changed.

**Siblings:** voice settings (providers, typed fields, live transcription) ·
the speech server page · Local Live settings · the toolset provider endpoint
(Hermes writes the config) · the Model page's savers and fallback models ·
the main and voice reply models (`/api/model/set`, Hermes writes the
config) · Advanced settings (`setProfileSetting`, and the default profile's
context engine and memory provider through `/api/dashboard/plugin-providers`)
· display preferences · Capabilities' skill and toolset switches, backends,
terminal backend, connectors and installs (Hermes writes the config; see
Skill and tool switches) · the bot editor's skills, tools, MCP servers and
model (`profiles.configure`, `mcp.servers.add`) · the busy input mode
(`config.set busy`) · the Conduit plugin's install and update (Hermes writes
the plugin list)

**Code**
- Queue: `Conduit/Services/ProfileConfigWriteQueue.swift`
- Voice: `Conduit/Voice/HermesVoiceConfigurationService.swift` (save, saveLiveTranscription, saveVendorSelection, saveProviderSelection; putConfig keeps what it wrote), used by `Conduit/Views/VoiceSettingsView.swift`, `Conduit/Views/SpeechServerSettingsView.swift`, `Conduit/Views/LocalLiveViews.swift`
- AppState: `Conduit/Services/AppState.swift` (updateProfileConfig, setDisplayPreference, setProfileFallbackModels, setProfileMainModel, setVoiceReplyModel, setProfileSetting, toggleSkill, toggleToolset)
- Capabilities: `Conduit/Services/CapabilitiesStore.swift` (request, writesProfileConfig, serverConfig and saveServer: Edit Server's read, and its read and whole-map write in one turn)
- Gateway RPCs: `Conduit/Services/HermesClient.swift` (configureBotProfile, configureBotModel, addBotMcpServer, setBusyInputMode)
- Plugin update: `Conduit/Services/NotifierPluginUpdate.swift` (NotifierPluginUpdater install and update requests)
- Tests: `ConduitTests/HermesVoiceConfigurationServiceTests+OverlappingSaves.swift`

**Rulings**
- Every profile config write, whichever page or service makes it, runs in the one app-wide queue, one at a time; a failed one doesn't hold up the next (2026-10-24, #1222, from #1004).
- Credentials go to `/api/env` and the speech server's voice key to the notifier's token store, and connector tests and sign-ins change no config, so none of them waits in the queue. Session-scoped
`config.set` (model, reasoning, speed, yolo for one chat) changes no config
file either. `profiles.create` (New Bot, Duplicate) writes a new profile's
first config, which nothing else is saving yet, and Delete Bot
(`DELETE /api/profiles/{name}`) removes the whole profile, so neither waits. The notifier, the Watch and
CarPlay don't write a profile's config, and the host-run plugin update
(`/self/update`) runs as a job on the host that changes the plugin's files,
not the config.

**Open gaps**
- A config edit from Hermes Desktop or the terminal can still land between Conduit's GET and PUT; Hermes has no revision check to refuse the stale PUT.

**Checked:** 2026-10-31, #1574 (Edit Server reads in turn, and reads and writes the whole MCP map in one turn); 2026-10-31, #1558 (voice settings' saves are what the page opens on next, kept on the phone; what's written is unchanged); 2026-10-31, #1552 (a config save, a single setting's included, is what the settings pages open on next, kept on the phone; what's written is unchanged); 2026-10-26, #1282 (the Thinking choice writes `display.show_reasoning` and `display.conduit_thinking_on_request` in one save); 2026-10-25, at #1230 (host-run plugin update recorded); at #1222.

## Wake phrase

Saying a phrase while Conduit is open starts voice on that phrase's profile.

**Siblings:** the foreground listener (iPhone and CarPlay) · Settings' Wake
phrase section and its captions · Siri, Shortcuts and the Action button (the
other ways to start, in Starting a call) · the Sherpa wake service (not
wired into the app, so not needed)

**Code**
- Listener: `Conduit/Voice/Wake/AppleSpeechWakeWordService.swift` (makeRecognizers, watchInterruption), `Conduit/Voice/Wake/WakeSpeechLocale.swift`, `Conduit/Voice/Wake/WakePhraseMatcher.swift`
- When it listens: `Conduit/Services/AppState+WakePhrase.swift`, `Conduit/Voice/Wake/WakeLifecycleCoordinator.swift`
- Settings: `Conduit/Views/VoiceSettingsView.swift` (the Wake phrase section), `Conduit/Views/AuxiliaryViews.swift` (wakeSettings), `Conduit/Services/AppState+WakePhrase.swift` (wakeListenedPhrases)
- Tests: `ConduitTests/WakePhraseCompilerTests.swift`, `ConduitTests/SpeechRecognitionLocaleTests+WakePhrases.swift`

**Rulings**
- Recognition is on-device only, and nothing is recorded or kept (#174).
- A Latin-letter phrase is heard in the app's locale. A phrase in another writing system is heard by a recognizer for a language that writes it, the person's own first (the app's language only when it has an on-device model), up to three languages at once; Settings names the language, or says this iPhone can't hear the phrase (2026-10-24, #1222, from #1004).
- Phrases in Han, kana, Hangul and Thai match as a run of characters, two at least, since those recognizers don't space words; the matcher reads scripts through WakeSpeechLocale, so the two agree (2026-10-25, #1230).
- A phrase past the third language isn't heard, and Settings says so beside it. The cap counts every profile's phrases on the dashboard, in the listener's order, so Settings and the listener agree (2026-10-24, #1222 review).
- After an interruption with no end from iOS, listening resumes only when no phone call is in progress, no other Conduit audio owner has the session and the session activates again (2026-10-24, #1222, from #1004).

**Open gaps**
- A phrase spelled in Bopomofo or in loose Hangul jamo goes to the right language but can't match: the recognizer writes Han characters and whole Hangul syllables (#1230 review).
- Han-only phrases on a phone with no Chinese or Japanese language set are heard in Simplified Chinese; a Japanese kanji-only name may be missed.

**Checked:** 2026-10-25, the Qwen call screen holds the listener, at #1182, carried in #1235; at #1230 (halfwidth Hangul, Jamo extensions, Bopomofo); at #1222.

## Dictation and voice message length

How long the microphone stays open for words that become text, and how much
audio is kept for them.

**Siblings:** composer dictation (chats, project chats, Bot Chat, group
rooms; Apple, Apple's new model and Hermes engines) · voice messages ·
Classic voice utterances

**Code**
- Dictation: `Conduit/Voice/ComposerDictationService.swift` (maximumDuration), `Conduit/Voice/DictationRecognizers.swift` (HermesDictationRecognizer.maximumRecordedBytes)
- Voice messages: `Conduit/Voice/VoiceMessageRecorder.swift` (maximumDuration)
- Classic: `Conduit/Voice/VoiceConversationController.swift` (maximumUtterance)

**Rulings**
- Dictation and voice messages stop by themselves at 15 minutes and keep what was said; Hermes dictation keeps at most that much audio for its upload (2026-10-24, #1222, from #1004).
- A Classic utterance ends at 60 seconds.

**Open gaps**
- Dictation stopping at the limit says nothing; the words are in the draft.

**Checked:** 2026-10-24, at #1222.

## Send while dictating

What the composer offers while a dictation runs: a wide Stop in Send's
place until the words are in the draft, so they're read over before they
go. Talking and sending in one go is Voice message's or Voice's job.

**Siblings:** chat composer (chats, project chats, Bot Chat; done) · group
rooms (done) · the full editor, both composers' (done, it shows the same
Stop) · the hardware Return key with Return sends on (done, it stops the
dictation, in chats, group rooms and the full editor, #1394) · the big voice button set to Dictation (done, its second
tap does what the Stop does, a settle included) · Voice
message's hold to record, let go to send (not changed, it's the one-tap
path) · docs/VOICE_SETTINGS.md "Dictate into the composer" (done) · strings (not
needed, Stop, Cancel, Transcribing and the dictation labels are already
translated) · Watch and CarPlay (not needed, no composer dictation) · the
notifier (not needed, dictation is app-side)

**Code**
- Policy: `Conduit/Voice/ComposerDictationService.swift` (ComposerDictation.holdsSendSlot, slotFace, slotTap; the service's settleGrace, settleCanEnd, slotFace and tapSlot; reserveStart and startToken, which let Cancel call off a start; receive clears isTranscribing once words land)
- The Stop: `Conduit/Views/Components/ComposerDictationStopButton.swift`
- Chat composer: `Conduit/Views/Components/ComposerBar.swift` (trailingControl, dictationHoldsSendSlot, controlsRowShowsDictate, submitFromReturnKey, applyDictationRequest for the big voice button, the full editor's buttons)
- Group rooms: `Conduit/Views/Components/GroupRoomComposer.swift` (sendSlot, dictationHoldsSendSlot, isDictationActive, submitFromReturnKey)
- Tests: `ConduitTests/DictationEngineTests.swift`, `ConduitTests/AppStateVoiceCapabilityTests.swift`

**Rulings**
- Send isn't offered while dictating, from the tap that starts it until its last words are in (a Hermes upload included). A wide Stop holds its place and the small mic steps aside; Send comes back with the words in the draft. Send doesn't stop and send in one tap (Eric, 2026-10-26, #1309, #1315).
- The Stop takes the whole slot, so a running reply's Stop, Steer or Queue comes back after the dictation too (2026-10-26, #1315).
- Once stopped, the Stop shows Transcribing (an Apple engine finalizing, or Hermes) and waits out a 3.5 second grace, so a tap can't cut off its final words. That outlasts either Apple engine's whole settle, so only Hermes ever offers Done: past the grace it reads Done and ends the dictation there, keeping the draft's words, so a slow host never holds Send back. A Hermes dictation none of whose words are in yet waits throughout; once its first words land it settles like any engine's, and typing ends it (2026-10-26, #1315 review).

**Open gaps**
- A Hermes upload none of whose words reached the draft can't be cut short: Transcribing waits until the words come or the watchdog ends it with its message. A dropped connection now adds up to about two minutes of retries to that wait, longer when each attempt runs to its timeout, up to the watchdog; Cancel ends it and keeps the recording for Retry (2026-10-27, #1380).
- Not yet checked on a device: the Stop's width and the swap in the controls row and the full editor, with long translations and large text.

**Checked:** 2026-10-29, #1512 (on a composer that stays expanded, the controls row's mic gives way to a big button set to Dictation, as beside the resting bar; see Composer at rest and expanded); 2026-10-27, at #1385.

## Hermes dictation kept until transcribed

A Hermes dictation's recording is written to the iPhone before it is
uploaded and kept until its words are in a draft. Once it is saved
(when the dictation stops), a dropped connection, a failed upload or
Conduit stopping doesn't lose what was said.

**Siblings:** chat composer (chats, project chats, Bot Chat, the full
editor; done, Retry and Delete above the composer) · the big voice button
set to Dictation (done, same service) · group rooms (done, Retry and
Delete above the room's composer, the words into the room's draft) ·
voice messages (not needed, the audio file is the message and goes with
it) · Classic utterances (not needed, not dictation) · Apple and Apple's
new model (not needed, on the iPhone) · docs/VOICE_SETTINGS.md "Dictate
into the composer" (done) · Watch and CarPlay (not needed, no composer
dictation)

**Code**
- Store and retry policy: `Conduit/Voice/DictationClipStore.swift` (DictationClipStore, DictationUploadRetry)
- What the composer offers: `Conduit/Voice/DictationClipInbox.swift` (keep, release, delivered, retry; AppState.restoreRetriedDictation)
- The recognizer: `Conduit/Voice/DictationRecognizers.swift` (HermesDictationRecognizer keepRecording, upload, cancel, deliver)
- Wiring: `Conduit/Voice/ComposerDictationService.swift` (clipInbox, makeRecognizer clips), `Conduit/ConduitApp.swift` (load at launch), `Conduit/Services/AppState+PendingSend.swift` (ComposerRestoreRequest.dictationClipID)
- The row: `Conduit/Views/Components/UndeliveredDictationNotice.swift`, `Conduit/Views/Components/ComposerBar.swift` (retryDictationClip; AppState.durableComposerDraftKeyOnScreen), `Conduit/Views/Components/GroupRoomComposer.swift` (retryDictationClip; AppState.appendToRoomDraft)
- Tests: `ConduitTests/DictationClipStoreTests.swift`, `ConduitTests/DictationClipInboxTests.swift`

**Rulings**
- The recording is on disk (Application Support, out of backups) before the upload starts, and goes once its words reach the draft; a long recording Hermes answers empty for is kept too (2026-10-27, #1380).
- An upload that fails on the connection or a busy host is tried again after 5, 15, 30 and 60 seconds while the Stop reads Transcribing (a dropped connection, a timeout, 408, 429 or a 5xx other than 501); a sign-in, any other 4xx or Hermes' own error isn't (2026-10-27, #1380). The settle watchdog (the longest single upload plus 10 seconds) isn't stretched to cover every retry: it still bounds how long Send waits, and a dictation it ends keeps its recording for Retry (2026-10-27, #1385).
- A recording whose words never came is offered above the chat composer and the group room composer for its own host and profile, with Retry (one upload; the words go into the draft that was on screen) and Delete (asks first). One kept from a dictation still listening when it ended counts when 2 seconds or longer (2026-10-27, #1380).
- A Retry that Hermes answers empty for deletes a recording under 10 seconds and keeps a longer one, as the first upload does. A Retry whose recording is gone drops the row quietly; one whose recording can't be read keeps the row and says so (2026-10-27, #1385).
- A Retry's words go to the draft on screen when it was tapped, even if another chat or room opened meanwhile. A chat's is named by its durable id, so a chat whose runtime id is reused elsewhere never gets them, and a chat deleted by then hands them to the draft on screen, as a failed send does; a room's by the dashboard and room, and a room gone by then (or on a dashboard switched away from) takes nothing and the recording stays. A chat's words still waiting for its composer when the dashboard is left go with it, and the recording is offered again. A disbanded room, or a host without room sends, offers none; a room send in flight doesn't hide the row, since the draft still takes words (2026-10-27, #1385).
- Kept recordings go once two weeks old, and past twenty the oldest go, the next time Conduit opens or a recording is delivered or deleted (2026-10-27, #1380).

**Open gaps**
- A recording is written when the dictation stops, not while it runs: Conduit ending mid-dictation still loses it.
- Recordings over about 9 minutes exceed the host's 25 MB transcription limit once base64-encoded, so their upload and Retry fail the same way.

**Checked:** 2026-10-27, at #1385.

## Chats top bar and search

The Chats screen's controls: the profile row, the filter, Projects,
Artifacts, New chat and the search field, and how they lay out when the
profiles don't fit beside the controls.

**Siblings:** the chats list · the Projects view (same bar and field) · the
one-row bar (every profile fits) and the stacked bar (profiles on their own
row) · iPad and Mac (same view) · searching messages ("In messages") ·
the profile strip on Tasks and Settings (same chips) · CarPlay's agent
list (picks a profile too) · the profile picker sheet (same switch) ·
Settings' busy-mode picker and display settings (show the new profile's
at the switch) · the chat socket (the new profile's client takes over the
open one) · the notifier's release of an idle chat's claim (#1123)

**Code**
- Bar layout: `Conduit/Views/V2/V2TopBar.swift` (ViewThatFits: one row, else stacked with lowerLeading under the profiles)
- Profile chips (on Chats, Tasks and Settings): `Conduit/Views/V2/V2TopBar.swift` (V2ProfileStrip), `Conduit/Views/V2/V2Shell.swift` (pickProfile, V2QueuedProfilePick, fadeContentBackIn, the activeProfile and isProfileSwitching handlers)
- CarPlay's agent list: `Conduit/CarPlay/CarPlayVoiceCoordinator.swift` (selectAgent, queueAgent)
- The switch itself: `Conduit/Services/AppState.swift` (switchProfile; the activeProfile didSet's restoreDisplayPreferences and restoreBusyInputMode; loadBusyInputMode, loadChatResumeProfileDisplayPreferences)
- The socket kept across the switch: `Conduit/Services/AppState.swift` (socketToKeepForProfileSwitch), `Conduit/Services/HermesClient.swift` (canHandOffSocket, handOffSocket, adoptSocket, receiveHandedOn, receiveFailedHandedOn, the receive loop's hand-on)
- The outgoing profile's events on the kept socket: its chats stay attached to it, as a chat left for another in the same profile does, so their events reach the new client; the open chat's session filter keeps them off its transcript, a compaction claim is the session's own, and a sessions.changed read is spaced 5 s apart as any is (#1452)
- Tests: `ConduitTests/HermesClientTests.swift` (testAHandedOnSocketCarriesTheNextProfilesRequestsAndEvents, testALateAnswerToTheOutgoingProfilesRequestNeverSettlesTheNextOnes, testASocketHandedOnTwiceStillReachesTheLatestClient, testAHandedOnSocketThatDropsReportsTheDropToTheClientHoldingIt, testAnApprovalOpenedBeforeTheHandOffIsStillWithdrawnAfterIt, testASocketStillWritingALargeFrameIsNotHandedOn, testASocketWaitingOnItsCapabilitiesReplyIsNotHandedOn, testASocketTheServerHasClosedIsNotHandedOn, testAClientWithNoOpenSocketHandsNothingOn, testASocketIsNotHandedOnToAClientThatHasOne, testASocketIsNotHandedOnToAnotherDashboard), `ConduitTests/CrossProfilePresentationCacheTests.swift` (testAProfileSwitchKeepsTheOpenSocket)
- Controls and search: `Conduit/Views/V2/V2ChatsView.swift` (trailingControls, stackedLeading, barUnstacked, setBarStacked, filterPill, barSearchField, searchField, searchCapsule)
- Message match row ("In messages"): `Conduit/Views/V2/V2SessionRow.swift` (V2ContentMatchRow: two lines of matching text, four at accessibility text sizes)

**Rulings**
- The profiles get their own row when they don't fit beside the controls, and the filter becomes a labeled pill under them (2026-10-22, #1117, Eric).
- In the stacked bar, search is a magnifier leading the controls. Tapping it turns the whole second row (filter and controls) into the field with Cancel until the search is cancelled, the list has no search row, and the filter pill fills the row up to the controls. The one-row bar keeps the field as the list's first row (2026-10-24, #1199, Eric).
- Going from the stacked bar to the one-row bar carries a query over to the list's field and closes an empty open field (2026-10-24, #1199).
- A profile chip tapped while a switch is still running (its fade-out included) is kept, with its haptic at once (the highlighted chip too, rather than opening Profiles), and the last one tapped is switched to when that switch ends, with no second haptic (none when it's where the switch landed). The chips stay tappable meanwhile: a switch takes a couple of seconds on a real dashboard, and taps in it used to do nothing (2026-10-28, #1435). The profile picker sheet still disables its rows during a switch, as it closes on the one picked. An agent picked in CarPlay's Voice list during a switch is kept the same way and switched to once it ends (#1435). A tap in the fade-out, before the switch starts, changes its target, and one back on the profile showing cancels it; a tap on All drops a kept pick. A kept pick is dropped if the dashboard changed meanwhile, and the content stays out until a pick kept from the strip lands rather than flickering in between (one kept in CarPlay doesn't hold the phone's content: it comes back at the profile change and switches again when the CarPlay pick lands).
- A switch picked from the strip shows the new profile's chats as soon as the profile changes over (its saved list until the live one lands), not once the whole switch is over; the profile's busy mode and display settings show what it last said at once and are read again in the background, so neither the switch nor a chat opened in another profile (from All chats, a notification, a link, a widget or a Shortcut) waits on them (2026-10-28, #1443, Eric, from issue #1442).
- A switch on the same dashboard keeps the open socket: the new profile's client takes it over, with no new ticket or socket. Hermes' dashboard socket may address any profile it serves (every request names its own), and opening one cost five to seven round trips, 1.2 to 2.1 s on Eric's path, on top of the ticket's. The outgoing client's waiting requests fail, a late answer to one of them matches nothing (request ids carry on), and the frame its last receive brings goes to the client holding the socket. A switch with no open socket (or one the server has closed), or with one still writing a large frame or waiting on the gateway's answer to its capabilities, opens its own as before (2026-10-28, #1452, Eric asked for a faster switch; his trace on issue #1442 showed the socket's cost).
- The list's search row follows the bar's layout, starting from the last layout seen (`barStackedKey`). Before any layout is known (first launch) the row stays out until the one-row bar appears; a change of layout (rotation, a profile added) animates it in or out (2026-10-24, #1206: implementation of #1199's open gap).

**Open gaps**
- A launch whose layout differs from the last one seen still starts from the old layout, so the row can show for a frame or arrive a frame late: the iPad was rotated or profiles were added while Conduit was closed, or another iPad window in the other layout wrote the shared key last. Closing it needs the bar's choice before the first frame, which `ViewThatFits` doesn't expose.

**Checked:** 2026-10-28, #1452 (a switch keeps the open socket); 2026-10-28, #1447 (a switch takes the outgoing transcript off as the profile changes over, see A chat while it opens); 2026-10-28, #1443 (the strip shows the new profile's chats as soon as it's active); 2026-10-28, #1435 (profile chips and CarPlay's agent list keep a pick made during a switch); 2026-10-26, #1328 (the chip names Home apart from hidden projects); #1322 (the chip and filter pill also name hidden projects, "Project chats in Chats"); at #1319 (trailingControls' swapped voice steps aside beside a chat, see Voice beside the tabs); the match row at #1208, carried in #1229.

## Project chats in Chats

Which of a project's chats the Chats list shows: Settings > Appearance >
Project chats (Off, Recent, All) and Filter ▸ Projects, which leaves the
projects you untick out.

**Siblings:** the Chats list with no filter · the status, Starred and source
filters (they look through project chats too) · search and "In messages" ·
the project's own page · pinned chats · All profiles · the iPad and Mac list
(same view) · the empty list · Sync across devices · the Settings caption ·
the chat pickers that read the same catalog (CarPlay's chat list, the Home
Screen widget's and the Share extension's pickers, the home voice button's
Recent menu) · the Archived sheet · README.md

**Code**
- Setting, its default and hidden projects: `Conduit/Models/ChatListSections.swift` (ProjectChatsInChats, deviceDefaultKey, settleDefault, HiddenChatProjects)
- Old installs keep Off: `Conduit/Services/AppState.swift` (init, after the dashboard registry loads)
- List and menu: `Conduit/Views/V2/V2ChatsView.swift` (mainListShows, uncachedFilterRows, projectsFilterMenu, projectToggle, hiddenProjectCount, shownHiddenProjectCount, hidesEverything, selectionTitles, searchCapsule)
- Project of a row: `Conduit/Services/AppState.swift` (knownProjectID: the chats the project tree previews)
- Settings: `Conduit/Views/AuxiliaryViews.swift` (Project chats section)
- Sync: `Conduit/Services/AppState+SyncedPreferences.swift` (app.project_chats, hiddenChatProjectsSlot as app.hidden_chat_projects)

**Rulings**
- Recent is the default for a new install; a phone signed in before the change keeps Off, set once at launch from its saved dashboards or connection (a launch that can't read the dashboard registry, on a locked phone, leaves it to a later one), and a choice already made stays (2026-10-26, #1317, Eric). That default is the device's own (`deviceDefaultKey`), never the synced choice, so it can't overwrite a choice made on another device; a synced choice wins over it.
- Filter ▸ Projects is a multi-select with every project ticked to start, Home's chats standing in for the ones in no project ("Not in a project" without a Home). It narrows every filter, is kept per profile, and All doesn't clear it; the gold chip names it and its × shows every project again (2026-10-26, #1317, Eric picked a menu over a switch on each project). The chip counts projects ("2 projects hidden") and names Home on its own ("Home hidden", or "Chats outside projects hidden" without a Home), since Home's chats are in no project (Eric, 2026-10-26, #1328).
- A pinned chat stays listed whatever is hidden, and a search looks through every chat, a hidden project's too, as it does with the setting at Off (#708).
- A hidden project's chat that waits for approval leaves the list like its other chats, but the filter's amber dot and its spoken count still count it, and Needs approval lists it (its count too), so hiding a project never keeps a wait from the dot out of Needs approval (2026-10-26, #1322; Needs approval in #1328, Eric). Starred and the sources still narrow Needs approval as they narrow every filter, while the dot counts every wait; that predates hidden projects.
- When hidden projects are what empty the list, under any filter, the empty list says so and points to Filter > Projects instead of the filter's own wording (2026-10-26, #1322).
- Filter ▸ Projects is offered once the profile has a project besides Home; with Home alone it would only hide every chat. On the Projects page, which lists every project, the bar's chip and filled icon leave hidden projects out (2026-10-26, #1322).
- Filter ▸ Projects isn't offered in All profiles, where projects belong to one profile; the Settings switch still applies there to the projects of the profile in use, as before (2026-10-26, #1322).
- The chat pickers (CarPlay's chat list, the widget's and Share extension's pickers, the home voice button's Recent menu) and the Archived sheet follow neither: each picks a chat to talk to or restore from every chat, and never hid project chats (2026-10-26, #1322).

**Open gaps**
- Until the profile's projects load, nothing is hidden: every chat would read as one in no project.
- A row's project comes from the chats the project tree previews, so a project chat beyond its preview counts as in no project: it shows with the setting at Off, and hides with "Not in a project".

**Checked:** 2026-10-26, #1328.

## All profiles in Chats

The All chip in the Chats list's profile row: every included profile's chats
in one list, newest first with each row's profile picture, or with Group by
profile a section per profile listing its pinned chats and its five newest
until Show more (issue 1560 asked for the list; Eric asked for the cap).

**Siblings:** the chip and its Show in All sheet (which profiles, Group by
profile) · Filter's Group by profile switch · the date sections and the
mixed Pinned section · each profile's section (closing it, Show more,
reordering its pins) · search and "In messages" across profiles · the
status, Starred and source filters · opening, renaming, archiving and
deleting another profile's chat · New chat (asks which profile) · the open
chat's row on the iPad and Mac (same view) · unread dots (another profile's
replies) · VoiceOver · README.md

**Code**
- Settings, merge and groups: `Conduit/Models/AllProfilesChats.swift` (AllProfilesChatsSettings, rows, groups, preview, groupPreviewCount, holdsOpen), `Conduit/Models/ChatListSections.swift` (latestActivity)
- State and other profiles' rows: `Conduit/Services/AppState.swift` (rowProfile, isOtherProfileRow, isAllProfilesChatsOn, allProfilesIncluded, allProfilesGroupsByProfile, refreshAllProfilesCatalog, listAllProfilesCatalog, startNewChat(inProfile:))
- Chip and sheet: `Conduit/Views/V2/V2TopBar.swift` (withAllProfilesChip), `Conduit/Views/V2/V2AllProfilesSheet.swift`
- List: `Conduit/Views/V2/V2ChatsView.swift` (profileGroups, profileSection, profileShowMoreRow, profilesShowingAll, holdsOpenChat, collapsedProfiles, revealActiveSection, badgesRows, rowScope)
- Row badge: `Conduit/Views/V2/V2SessionRow.swift` (V2ProfileBadge)
- Search: `Conduit/Services/SessionContentSearch.swift` (otherProfiles)
- Docs: `README.md` (Features)
- Tests: `ConduitTests/SidebarLayoutTests+AllProfiles.swift`

**Rulings**
- All is offered with two or more profiles on the dashboard; the profiles left out are kept by name, so a profile added later is in, and leaving every one out lists them all (2026-10-22, #1128, Eric picked the chip and grouping).
- Grouped by profile, a section lists its pinned chats, then the five chats with the newest activity (a nest by its newest row, as the date sections file it), in the list's order, until "Show 12 more"; "Show fewer" puts it back. The open chat stays listed past the five, so a wide window never highlights a hidden row. A search or a status or Starred filter lists every match; a source filter (Voice, Scheduled and the like) is still a browse and keeps the cap. The row shows only while the cap hides something, so a profile that shrinks to five loses its Show fewer. Show more is remembered per profile until the app closes, while a closed section stays closed across launches (2026-10-31, #1571, Eric: one busy profile filled the list and few found the section's close).
- The ungrouped list stays one list, newest first, with no cap: it's ordered by last activity across profiles, as issue 1560 asked.
- Projects belong to one profile, so All shows chats only (see Project chats in Chats).

**Open gaps**
- Live status (the live registry's Running and waits) and scheduled runs follow the profile in use only, as built in #1128.

**Checked:** 2026-10-31, #1571.

## Unread dot on projects

The gold dot on a project in the Projects list while any chat in it has a
reply the user hasn't seen (issue 1496).

**Siblings:** the V2 Projects list (Chats › Projects) · the iPad and Mac
list (same view) · the classic drawer's Projects list · a chat row's unread
dot, which each project's dot follows (the project's page shows the same
dots on its chats) · the Running line on the same row · Mark as read and
unread · VoiceOver · the profile strip's dot, the same signal a level up ·
README.md

**Code**
- Which projects: `Conduit/Services/AppState+V2Shell.swift` (projectsWithUnread), `Conduit/Services/AppState.swift` (catalogRow: a chat's catalog copy, its own ids before the ids it shares, cached per catalog change)
- Rows: `Conduit/Views/V2/V2ChatsView.swift` (projectsList, projectRow, V2ProjectRow), `Conduit/Views/SidebarView.swift` (the Projects section, ProjectRow)
- Read state: `Conduit/Services/ChatReadState.swift` (isUnread), `Conduit/Services/AppState.swift` (isSessionUnread)
- Docs: `README.md` (Features)
- Tests: `ConduitTests/ChatReadStateTests.swift` (testProjectDotsMarkEachProjectWithAnUnreadChat)

**Rulings**
- The dot means an unread reply, read as a chat row reads it (Hermes' shared flag, a mark, or messages past what this device saw), never only that a chat finished: a reply already read leaves no dot. It stays while any chat in the project is unread, so reading one leaves it for the others (issue 1496).
- The dot sits on the tile's corner, as on a chat row's icon, apart from the Running line: a project can show both.
- Home gets the dot too, for its chats in no project.

**Open gaps**
- The dot reads the chats the project tree lists, as the Running line does, so an unread chat beyond the tree's preview of a big project doesn't light it. A chat the catalog also lists reads its copy there, which stays current between loads of the tree.
- Projects belong to the profile in use; All profiles has no Projects list of its own.

**Checked:** 2026-10-29, #1499.

## Pinned chats order

The Pinned section in the order the person sets (issue 1354): a pinned chat
dragged in place in the Chats list, or moved in Reorder pinned chats.

**Siblings:** the Chats list's Pinned section · the Projects view's Pinned
section · All profiles (a section per profile, and the mixed Pinned section)
· the iPad and Mac list (same view) · the classic drawer · Reorder pinned
chats (from a pinned row's touch-and-hold menu and the Pinned header's) · the
row's swipes and touch-and-hold menu, which a drag must not take over ·
VoiceOver · pin sync with Hermes (#555) · Sync across devices and its
Settings caption · CarPlay's chat list · the chat pickers (the Home Screen
widget's and the Share extension's) · README.md

**Code**
- Order: `Conduit/Models/PinnedChatOrder.swift` (arrange, interleave, orders, mixedOrder, movableOffsets), `Conduit/Services/AppState+PinnedChatOrder.swift` (arrangePinned, movePinnedChats, pinnedChatsForOrdering, pinnedChatOrderSlot), `Conduit/Services/AppState.swift` (pinnedChatOrder, setPinnedChatOrder, setPinnedChatMixedOrder, dropFromPinnedChatOrder from storePins and removePinnedState; sign-out and a new server clear both stored orders, and deleting a profile its own, in the mix too)
- Chats list: `Conduit/Views/V2/V2ChatsView.swift` (nestedSections, listRows' movesPinned, dragsPinned, pinnedHeader, projectsList, V2SessionActions' onReorderPinned)
- Sheet and menu: `Conduit/Views/PinnedChatsOrderSheet.swift` (reorderPinnedChatsMenu for the Pinned headers), `Conduit/Views/SidebarView.swift` (SessionActionMenuItems' onReorderPinned; the classic drawer's nestedSessionSections, projectsViewPinnedSessions and pinnedHeader)
- CarPlay: `Conduit/CarPlay/CarPlayBrowseTemplates.swift` (chatList's arrangePinned), `Conduit/CarPlay/CarPlayVoiceCoordinator.swift` (chatList, chatsObservation)
- Sync: `Conduit/Services/AppState+SyncedPreferences.swift` (chats.pinned_order), `Conduit/Views/SyncedPreferencesViews.swift` (the caption)
- Docs: `README.md` (Features)
- Tests: `ConduitTests/PinnedChatOrderTests.swift`, `ConduitTests/CarPlayVoiceTests.swift` (testChatListPinnedChatsFollowThePhonesOrder)

**Rulings**
- Drag in place plus Reorder pinned chats, together: a hold that moves lifts a pinned row, a hold that stays still opens the menu as before, and a swipe starts before either; the sheet is the way with VoiceOver and in the classic drawer (Eric, 2026-10-27, issue 1354).
- Only pinned chats move, among the pins the section shows (in All's mixed Pinned section, other profiles' too; see below): a drop past the last pinned chat lands at the end of Pinned, never among recent chats, and moving never pins or unpins. A nest's "3 jobs" line and its open children stay put and follow their parent.
- Rows move by dragging while the list shows every pinned chat: not during a search or under a filter, whose rows are a lookup. The Pinned header reorders the profile in use's pins, and in All grouped by profile each profile's header reorders that profile's; a row's menu reorders its own profile's.
- Until a profile's pins are reordered (or shown in a drag in All's mixed Pinned section, below) they follow recent activity, as before. Once ordered, a chat pinned since (here, on another device or in Hermes Desktop) goes on top, and an unpinned chat leaves the order, so pinning it again puts it on top too.
- The order is kept per profile under each chat's pin id (its lineage root), so a compacted chat keeps its place. Hermes keeps only whether a chat is pinned, so the order goes to other devices through Sync across devices (`chats.pinned_order`, the profile in use's), not through Hermes.
- In All's mixed Pinned section a chat stays where it's dropped, among the other profiles' too: the section also keeps which profile holds each place, and each profile's chats fill its places in that profile's own order. A drag there saves the order of every profile it shows, so later activity doesn't move a chat dropped among another profile's. That mix stays on this device, like All's other settings, and applies to the mixed section only (All grouped by profile and a profile's own list follow each profile's order); a chat pinned since goes on top, and an unpinned one leaves it. This replaces "each profile's pinned rows keep the places they held among the others'", under which a drop past another profile's chats snapped back (Eric, 2026-10-29, issue 1486, #1490).
- CarPlay's pinned chats follow the order. The widget's and Share extension's pickers don't: they pick a chat from every chat, pinned ones first by recent activity.
- In All grouped by profile, a section's pinned chats are never held back by its Show more, and still move among themselves; the Show more row stays out of the drag (2026-10-31, #1571).

**Open gaps**
- Hermes Desktop keeps its own pin order, and Hermes has no field for one, so the two never match.
- The classic drawer reorders only from the sheet: its nested rows are one block each, which a List drag can't move cleanly.
- Not yet tried on a device: whether the system's lift from a held row and the touch-and-hold menu share the hold as planned.

**Checked:** 2026-10-31, #1571 (a profile section's Show more, see All profiles in Chats); 2026-10-29, #1490.

## Deleting from a list row

A row's swipe Delete in the lists that ask before deleting: the chat, the
project or the bot goes only once the confirmation is answered.

**Siblings:** the Chats list's rows and a project page's rows (V2) · the
Projects view's rows · the drawer shell's sidebar (chats, projects, a
project's chats sheet) · the Bots list · Tasks' scheduled jobs · each row's
context menu Delete · pinned replies' Unpin (acts at once, no confirmation) ·
the iPad and Mac list beside the open chat (same views) · text: no Settings
caption or doc describes it

**Code**
- V2 rows: `Conduit/Views/V2/V2ChatsView.swift` (V2SessionActions, projectRow's swipe actions, the Delete alerts)
- Drawer shell: `Conduit/Views/SidebarView.swift` (SessionList's chat and project rows, ProjectSessionsSheet)
- Bots: `Conduit/Views/BotRosterView.swift` (BotRosterRow, the Delete Bot dialog)
- Scheduled jobs: `Conduit/Views/V2/V2TasksView.swift`
- Pins: `Conduit/Views/PinnedReplyViews.swift`

**Rulings**
- A swipe Delete that asks first is a plain button tinted red, never the destructive role: SwiftUI takes a destructive swipe button's row out as it's tapped, so the row was gone before the answer, came back on Cancel, and on a Mac the whole list could go blank once the data caught up (2026-10-27, #1372, issue #1364). A swipe action that acts at once (Unpin) and context menu items keep the destructive role.

**Open gaps**
- Not checked on a device: whether the report's blank list came from the swipe or the context menu Delete.

**Checked:** 2026-10-27, #1372.

## Plan card

The agent's plan ("Tasks", from Hermes's `todo` tool) docked above the
composer: a slim line that opens upward into a card, and a sheet with the
whole plan. [docs/PLAN_CARD.md](PLAN_CARD.md) is the design.

**Siblings:** the line · the card · the whole-plan sheet · chats, project
chats and Bot Chat (one chat screen) · group rooms (no plan) · the `todo`
tool result in the transcript, which draws the same items · VoiceOver's
reading of the line and its new-plan announcement · iPhone, iPad and Mac
(the keyboard rule differs on a Mac and with a hardware keyboard) · the
classic shell (never reports the composer's focus, so the line never
keeps to itself there)

**Code**
- Model: `Conduit/Services/ChatCardsModel.swift` (present, announcement, planRetired), `Conduit/Services/AgentPlan.swift` (AgentPlanTranscript, AgentPlanWindow)
- Views: `Conduit/Views/Components/ChatCards.swift` (ChatPlanDock, PlanStrip, PlanCard, PlanSheet, PlanText)
- Feeding it: `Conduit/Services/AppState+ChatCards.swift`, `Conduit/Views/ChatView.swift` (planDock), `Conduit/Services/HermesClient.swift` (`todo_state` on resume)
- Transcript row: `Conduit/Views/ToolResultViews.swift` (the todos case)
- Tests: `ConduitTests/GatewayRestartTests+ChatCards.swift`

**Rulings**
- Docked at the bottom above the composer, a line that announces a new plan without opening over the chat; the artifact card was dropped (2026-10-23, #1135, Eric).
- An announced plan is on screen: a new plan, even one that arrives finished after the last one went, clears the hidden state and gets its own 60 s (2026-10-24, #1188, merged by Eric; salvage of the #1135 review).
- The line and the card cap Dynamic Type at accessibility1; the sheet, a scrolling list, takes every size (2026-10-24, #1188, merged by Eric; salvage of the #1135 review).
- The plan keeps to its one line only while an on-screen keyboard can be up: a Mac has none and a hardware keyboard puts it away (a Mac and an iPad with one keep the composer's focus between messages, see Composer focus after a send), so there the line opens whatever the focus, and a tap on the line under the keyboard puts the keyboard away and opens the card (2026-10-29, #1511, issue #1510; focus kept after a send, #1527).

**Open gaps**
- The new-plan announcement reads the line's label ("Tasks, 0 of 4 done, now: ..."), with no word saying the plan is new or reopened.
- Two announcements within 450 ms race on the pulse (#1135 review).
- With a hardware keyboard the line opens even if the on-screen keyboard is summoned; the check is for a connected keyboard, not a visible one (#1511 review).

**Checked:** 2026-10-31, #1556 (an iPhone with a keyboard no longer keeps focus after a send; the check is unchanged); 2026-10-30, #1527 (the ruling's premise: a send keeps focus on a Mac and with a hardware keyboard; the check is unchanged); 2026-10-29, #1511.

## White text on the accent

A chip, badge or step number that puts white text or a white glyph on a
solid accent fill. The accent the user picks is light in dark mode, so
white on it can fall to about 2:1; the sent-bubble colour is the shade held
to 4.5:1 under white in both modes.

**Siblings:** the running timer chip and the "Recommended" badge on rich
cards · the numbered or symbol marker on a rich card's place rows · the
step numbers of the notification setup commands · the Gemini Live setup
step number · marks picked by `markColor(on:)` (text selection on a sent
bubble, the accent swatch check) · the primary buttons (the sign-in flow's
Continue and Sign in, Settings' Save and Apply), white only in light mode

**Code**
- Fill: `Conduit/Theme.swift` (conduitUserBubble, ConduitAccentChoice.markColor)
- Surfaces: `Conduit/Cards/RichInfoCardViews.swift` (RichOptionColumn, RichStepTimer), `Conduit/Cards/RichCardViews.swift` (the place row marker), `Conduit/Views/AuxiliaryViews.swift` (NotificationSetupCommand), `Conduit/Views/LiveVoiceSetupSheet.swift` (the Gemini and Qwen steps)
- Primary buttons: `Conduit/Views/Login/LoginScreens.swift` (LoginPrimaryButton), `Conduit/Views/AuxiliaryViews.swift` (SettingsButtonLabel)
- Tests: `ConduitTests/AccentContrastTests.swift`

**Rulings**
- White text on a solid fill uses the sent-bubble colour, not the accent; a mark whose colour is computed takes whichever of black and white contrasts more with its fill (2026-10-24, #1188, salvage of the #955 review).
- The primary buttons need no change: their white label is light mode only, where the accent is the sent-bubble colour, and dark mode draws a black label (2026-10-24, #1208, Eric).

**Open gaps**
- Dark glyphs on the accent (the voice and new-chat buttons, the voice message send button, the chats list capsule, the primary buttons' dark-mode label) and background-coloured text on it (the confirm panel, the sidebar button, the profile camera badge, a rich card's prominent action in `Conduit/Cards/RichMediaCardViews.swift`) aren't checked against a custom accent.

**Checked:** 2026-10-25, the Qwen setup step, at #1182, carried in #1235; 2026-10-24, at #1208, carried in #1229.

## Phone data sync with the host
- Background time: `Conduit/Services/BackgroundTaskHold.swift` (LocationSharingController's fix and send work)

The phone sending calendar, reminders, alarms, contacts and phone status,
health data and location to the notifier, each under its own agreed key, and
what it does when the host refuses.

**Siblings:** phone sync (calendar, reminders, alarms, contacts, Focus and
status) · health sync · location sharing · the voice reads that use the same
keys · each one's pause message in Settings · a locate answered from the push
extension · the notifier's three stores and their refusals · the Shortcuts
inbox (the same 409 codes) · Pulse's suggestions (a change approved on a
card) · Pulse's next steps (the events that ended since its last report, read
on the host from what the phone already shares) · Pulse's Where you are (location's arrivals and departures at saved
places, and walking past's shop entries with the sealed reply that brings the
watches back; see Where you are, for Pulse) · Use my data's free/busy in rooms
(busy blocks read on the host from the calendar the phone already shares; see
Linked Rooms) · asks between linked agents' free on a date (the same busy
blocks, answered by the asked owner's rules; see Linked Rooms)

**Code**
- Phone: `Conduit/Phone/PhoneSyncEngine.swift` (pass; approveFromCard, for Pulse), `Conduit/Phone/PhoneSyncModels.swift` (PhoneSyncPause)
- Alarms: `Conduit/Phone/PhoneAlarmSource.swift` (PhoneAlarmSources.system: AlarmKit, or unsupported before iOS 26 and where AlarmKit isn't loaded, as on a Vision Pro)
- Health: `Conduit/Health/HealthSyncEngine.swift` (sendHistory, prepareHistory), `Conduit/Health/HealthSyncModels.swift` (HealthSyncPause, HealthSyncLimits.oldestDay), `Conduit/Health/HealthKitSource.swift` (HealthDataSource: earliestDate, oldestReading, changes), `Conduit/Views/HealthSettingsViews.swift` (the history progress caption, done at the walk's floor)
- Location: `Conduit/Location/LocationSyncEngine.swift` (send, LocationSyncPause; `spotsReplied`), `Conduit/Location/LocationSharingController.swift` (sendNow: keeps the batch on `.failed`; `spot_entries` and `spots_room` in the batch), `ConduitLocationPush/LocationPushService.swift` (a locate answered from the push extension)
- Which 409 means what: `Conduit/Services/HostKeyConflict.swift`
- Voice reads: `Conduit/Services/AppState+VoiceHostTools.swift`, `Conduit/Phone/PhoneVoiceTools.swift`
- Notifier: `notifier/phone_store.py`, `notifier/health_store.py`, `notifier/location_store.py`, `notifier/dashboard/api/phone_data.py` (_store_refusal; `_location_ingest`, which hands arrivals and departures to Pulse)
- Tests: `ConduitTests/PhoneSyncTests.swift`, `ConduitTests/HealthSyncTests.swift`, `ConduitTests/LocationSharingTests.swift`, `ConduitTests/LocationSpotsTests.swift` (walking past's shop entries in the batch, what drops them, and the sealed reply)

**Rulings**
- Only a 409 that says the host lost this phone's key (`unknown_key`, `bad_seal`) clears the key and sets up again; any other 409 keeps it (2026-10-19, #906; 2026-10-20, #1025).
- The iPad app on a Vision Pro has no AlarmKit though it reports iOS 26: alarms are unsupported wherever `AlarmManager.shared`'s symbol isn't bound, as before iOS 26, and AlarmKit is only read when used (2026-10-29, #1474, a launch crash since #596).
- A store written by a newer plugin (409 `schema`) pauses with the "update the Conduit plugin" message, keeps the key and keeps what waits to be sent (2026-10-24, #1196).
- A later refusal, timeout or 404 replaces that plugin-update pause with its own message, as for any other pause (2026-10-24, #1196).
- A change approved on a Pulse suggestion's card (Add, or Undo after its question) is applied by the app that tapped it without the phone's own card, once the host has it and for 15 minutes from the tap; that app exchanges at once, and again to report it, and when that exchange doesn't get the change, the Pulse screen says the phone tries again on its next one, or, when the phone doesn't share its calendar, that the change waits for a device that does. Another device, or the same one later, shows the phone's card as for any change (2026-10-27, notifier #417, #1356).
- With Pulse's Where you are on, location's arrivals and departures at saved, non-private places, at most 15 minutes old, also go to Pulse, in this profile and each one that reads the location. Pulse keeps each a day, and turning Where you are or Pulse off, or wiping location, deletes them, with walking past's shop entries; turning walking past off deletes the shop entries alone (2026-10-27, Eric chose Opt in; notifier #420, #1379; shop entries 2026-10-28, Eric in the Pulse thread chose to ship walking past; notifier #435).
- Health history starts no earlier than the first local midnight whose sleep window opens after the host's limit (2000-01-01Z, `notifier/health_store.py` EARLIEST), and the walk back stops at the day of the oldest reading in the shared categories, asked every pass so an import of older readings reaches back again; Settings shows history as coming in only while the walk is above that floor (2026-10-30, #1542, issue 1537).
- Walking past's shop entries ride the location batch (`spot_entries`, with `spots_room`) and go through the same refusals and pauses: a failed send, a 409 `schema` included, keeps them with the batch; a refusal drops them with it; a pause, a wipe, or the phone no longer watching shops drops what waits. The host answers such a batch with the watches sealed under this phone's key and tied to the batch's id; a reply that doesn't open, or opens to something else, changes nothing and is logged (2026-10-28, notifier #435, #1414).

**Open gaps**
- The dashboard sends the store's code beside its message, but the phone keeps only the message: a reworded notifier message is missed until `Conduit/Services/HostKeyConflict.swift` learns it. Phone and health then pause with the host's reason; location drops the waiting fix, events and shop entries as refused.
- A locate answered from the push extension drops its fix on any failed post, a 409 `schema` included, and shows no pause: it is a one-shot answer, and the app shares its own fix next time.
- A voice read that meets a 409 `schema` tells the model only that the read failed, not that the plugin needs an update.

**Checked:** 2026-10-30, #1542 (All history stays after the host's 2000 limit and stops at the oldest reading; the stores needed no change); 2026-10-29, #1517 (the `pulse` branch merged into main: the app paths it lists are on main now; nothing else changed); 2026-10-29, #1497 (asks between linked agents answer free on a date from the same busy blocks, notifier #465; the sync itself needed no change); 2026-10-29, #1494 (Use my data's free/busy reads the shared calendar's busy blocks, notifier #463; the sync itself needed no change); 2026-10-29, #1474 (alarms unsupported on a Vision Pro; Settings, the voice tools and Pulse read the same source and needed no change); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, at #1427, carrying #1426 from the `pulse` branch (the shop entries' deletion cites the walking-past decision, and names turning walking past off); at #1423, carrying #1414 from the `pulse` branch (walking past's shop entries and sealed reply ride the location batch, with notifier #435; the refusals and pauses apply as for the batch); 2026-10-27, at #1398, carrying #1392 from the `pulse` branch (Pulse's next steps read the events that ended on the host, from what the phone already shares; the sync needed no change); 2026-10-27, at #1383, carrying #1379 from the `pulse` branch (location's arrivals and departures reach Pulse with Where you are on, with notifier #420; the stores' refusals and pauses needed no change); 2026-10-27, at #1375, carrying #1356 from the `pulse` branch (a change approved on a Pulse card, with notifier #417); 2026-10-26, #1247 (location sharing's fix and send work keep Conduit running through BackgroundTaskHold); 2026-10-24, at main e9d9592; the Shortcuts inbox added as a sibling in #1214 (fork CI #87), carried in #1232.

## Shortcuts inbox (Log to Hermes)

What the user's Shortcuts automations hand over (a notification from an app
they pick, a message, an email, a Wallet payment, an NFC tag, a sound),
kept on the host for Hermes to look up later, read by Pulse when it's on
(its memory keeps the deadlines it finds), and shown on the phone in
Settings > Shortcuts inbox. Logging starts no chat
and sends no push; Send to Hermes is the action that talks.

**Siblings:** the Log to Hermes action (typed fields, the phone's queue, the
sign-in code filter) · Settings > Shortcuts inbox (read back and delete,
which deletes Pulse's deadlines from those events, and its caption on them) ·
the notifier's inbox store, its sealed routes under /inbox and the
shortcut-inbox capability · the conduit_inbox tool and its description ·
Pulse's report, its morning brief, its watches and its memory's deadlines,
with Settings > Pulse's Deadlines from Shortcuts switch (pulse_report,
pulse_brief, pulse_followup, pulse_memory) · the plugin's
README and CHANGELOG · the privacy policy (notifier docs/privacy) · the phone
features' sealing and 409 handling (Phone data sync with the host)

**Code**
- Action: `Conduit/Intents/LogToHermesIntent.swift`, `Conduit/Services/AppState+ShortcutInbox.swift`; a removed or signed-out dashboard's inboxes: `Conduit/Services/AppState.swift` (removeDashboard, disconnect, signOutDashboard, ShortcutInboxQueue.forgetDashboard)
- Queue, filter, sealing, the one-at-a-time gate and the Settings page's reader: `Conduit/Shortcuts/ShortcutInbox.swift` (ShortcutInboxScope, ShortcutInboxQueue, ShortcutInboxGate, ShortcutInboxBrowser); key: `Conduit/Services/AppState.swift` (KeychainHelper shortcutInboxKey, one per dashboard and profile); the drain on connect: `Conduit/Services/AppState.swift` (refreshNotifierPluginStatus) and `Conduit/Services/AppState+ShortcutInbox.swift` (drainShortcutInbox)
- Settings page: `Conduit/Views/ShortcutInboxSettingsViews.swift` (its caption and delete-all message on Pulse's deadlines), linked from `Conduit/Views/AuxiliaryViews.swift` (SettingsDestination.shortcutInbox)
- Notifier: `notifier/inbox_store.py` (store, list_sealed, delete_events; received and present, for Pulse's deadlines), `notifier/inbox_tool.py` (tool), `notifier/dashboard/api/phone_data.py` (/inbox, _inbox_tell_pulse; /inbox/delete and /inbox/wipe delete Pulse's deadlines from those events), `notifier/dashboard/api/capabilities.py` (ROUTE_CAPABILITIES), `notifier/tests/test_inbox.py` and `notifier/tests/inbox_vector.json` (both sides seal against it)
- Pulse: `notifier/pulse_report.py` (inbox_context, in gather), `notifier/pulse_brief.py` (the brief's context, LOGGED_TITLE), `notifier/pulse_followup.py` (watch checks, inbox_arrived, check_watches_now), `notifier/pulse.py` (wake, the memory run), `notifier/pulse_memory.py` (read_inbox, the deadlines memory keeps; forget_inbox and forget_deleted, which delete them with their events), `notifier/tests/test_pulse_followup.py`, `notifier/tests/test_pulse_learning.py` (the brief reads what was logged), `notifier/tests/test_pulse_inbox.py` (the deadlines memory keeps, and deleting events deleting them)
- Privacy policy: `notifier/docs/privacy/index.html` (Optional events from Shortcuts automations)
- Tests: `ConduitTests/ShortcutInboxTests.swift`

**Rulings**
- The inbox works with Pulse off, and nothing in it reaches a chat or a push on its own; only Pulse, when the user turned it on, may bring something up (2026-10-24, Michel).
- With Pulse on, its report reads what was logged since the last one, and the user's watches are checked against new events as they arrive (at most a run every 15 minutes), so a watch is told on arrival, not at the next report (2026-10-24, Eric's review of #1214).
- The morning brief reads what was logged since the report's look back starts (the last report, 4 to 24 hours ago), under a heading that says so and that it's other people's words, and says nothing was logged only on a host that keeps an inbox (2026-10-25, notifier #357).
- A watch asks if it's still wanted after a month, not a week like a promise (2026-10-24).
- The Settings page shows only this iPhone's own events, read back sealed for it alone under a second key from the same agreement, and deletes one or everything (2026-10-24, Eric's review of #1214).
- Each field is cut on the phone to what the host keeps (From 120, Title 200, Details 4,000 and Amount 40 characters), so a long email never makes a batch the host refuses (2026-10-25).
- Sign-in codes, one-time passwords and sign-in links never leave the phone, and the host drops them again. The phone checks every field the action takes (From, Title or Subject, Details, Amount), not just the text. The two code filters (ShortcutEventFilter and looks_like_code) change together, with the same test cases (2026-10-24; every field: Eric's review of #1214, 2026-10-25).
- An event belongs to the dashboard and profile in use when it was logged: each pair has its own waiting queue, device id and key, like the other phone data, and an event only ever goes to its own profile's inbox, so agreeing a key with one profile never drops what another holds (Eric's review of #1214, 2026-10-25).
- An event waits on the phone only where the host keeps events (the plugin reports `shortcut-inbox`, or this profile already agreed a key there), so a waiting event always has a Settings page that shows and deletes it; otherwise the action says it wasn't kept. Waiting events go with the next run and whenever Conduit connects (Eric's review of #1214, 2026-10-25).
- Waiting events never sit in UserDefaults or a backup: one file in Application Support, excluded from backup and protected until first unlock, because automations run while the phone is locked (the key's keychain item has the same reach) (Eric's review of #1214, 2026-10-25).
- One inbox operation runs at a time (send, first key agreement, read back, delete): two automation runs at once never send an event twice or agree two keys (Eric's review of #1214, 2026-10-25).
- The drain on connect holds that gate for at most 10 seconds, whatever the connection does, so a Log to Hermes run never waits behind it past that; whether Settings shows the page comes from memory (ShortcutInboxLocalState), so drawing Settings never reads the queue file or the keychain (2026-10-25).
- A delete that can't reach Hermes says so, and deletes only what waits on the phone; deleting an event also drops a waiting copy of it (Eric's review of #1214, 2026-10-25).
- Removing a saved dashboard drops what waits for its profiles and their inbox keys: those events could never go anywhere (2026-10-25). Signing out of a dashboard drops them too, since they belong to the signed-out user and the next sign-in may be someone else's (2026-10-25, #1232).
- An event dated more than 30 days back (the action's When) isn't kept: the action says it's too old, since the host would delete it at once (2026-10-25).
- Events are sealed end to end like the phone features; the host keeps them a fixed 30 days and then deletes them (Eric, 2026-10-24 email on Pulse), at most 5,000 per device, and a new device key drops what the old one sent.
- Events can match watches and become report candidates, and a card or a watch's message may quote one, but Pulse memory never keeps message bodies or facts about the sender unless the user asks; pulse_memory's instructions say so (Eric, 2026-10-24 email on Pulse). The one exception is a deadline: with Pulse memory on, it keeps a day by which something of the user's ends, renews, closes or is due (a trial ending, a bill due), with the words it came from and who sent it, and nothing else from the event (2026-10-27, Eric's card "Keep deadlines from your phone's inbox in Pulse memory, like trial ends and bills?": Keep them quietly; notifier #410).
- Deleting events (one, everything from a phone, or the whole inbox) deletes the deadlines Pulse kept from them at once, whether or not Pulse is on, and the loop backs that up; a deadline whose event aged out or went past the cap stays until a day after its day. Pairing the phone again drops what the old key sent but keeps Pulse's deadlines, since the user deleted nothing. Settings > Shortcuts inbox says Pulse keeps deadlines, and its Delete Everything says they go too, with a plugin that reports `pulse_inbox` (2026-10-27, notifier #410, #1341).
- Calls stay opt-in: an explicit watch ("call me if the bank flags fraud") is the confirm a new kind of call needs (Eric, 2026-10-24 email on Pulse).
- What the inbox holds is other people's words: conduit_inbox and the watch check both say to treat it as data, never instructions, and never to forward it unless the user asks (2026-10-24).
- A 409 `schema` keeps the event on the phone with the "update the plugin" message, as the phone features do (2026-10-24).

**Open gaps**
- Ready-made automation recipes aren't written yet, and the fields the Message, Email, Wallet, NFC and Sound triggers hand over haven't been checked on a device. The Notification trigger is checked: Eric asked to confirm that the iOS 27 Notification trigger hands other apps' notifications to a Shortcuts action, and Michel's iPhone confirmed it on 2026-10-24. With a Notification automation on the Claude app, set to run immediately, two notifications reached an Append to Note action, one while the phone was locked, with no prompt. The trigger offers typed fields (Title, Subtitle, Body, App, Associated content, Name) besides the Shortcut Input, a text attachment of title and body. Title and body came through; App and Name came out empty, so its recipe will map Title and Body and name the app itself.
- Pulse reads only the inbox of its own home; with `report_profiles` all, the other profiles' inboxes aren't read, for deadlines either.
- A watch is checked only by a run of the memory thread, so with Pulse memory off no watch is ever checked, on arrival or otherwise.
- Not on the Watch or in CarPlay: automations run on the iPhone.

**Checked:** 2026-10-30, #1542 (All history stays after the host's 2000 limit and stops at the oldest reading; the stores needed no change); 2026-10-29, #1517 (the `pulse` branch merged into main: the Settings page's Pulse caption is on main now; nothing else changed); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-27, at #1375, the privacy policy sibling: notifier #410 added what Pulse keeps from these events to its Optional events from Shortcuts automations; at #1345, carrying the `pulse` branch's entry: #1341, with notifier #410 (Pulse memory keeps deadlines from the inbox: the ruling on what memory keeps, deleting events deleting them, and on the `pulse` branch the inbox page's caption and Delete Everything's message; the Log to Hermes action, the conduit_inbox tool, watches, the report and the brief needed no change); before that 2026-10-25, #1214 (fork CI #87), at main 6e0f32d and notifier main with notifier #350; the privacy policy sibling and sign-out added in #1232 (privacy in notifier #356), which carries #1214; the morning brief added as a reader in notifier #357 (its README line in notifier #360), carried in #1237.

## Steps in a turn

How a turn's thinking and tool calls read in the chat while it runs and
once it is done.

**Siblings:** the step rows (chats, project chats, Bot Chats, the saved
offline copy) · the collapsed run of steps ("7 steps · 12s") · the working
line ("Home · Searching the web") · the Live Activity's tool line · the
notifier's twin category list · Settings > Chat's Tool cards and Keep tool cards expanded switches (they show, hide and open rows; their words follow the row) ·
the run's summary, its Explain these steps menu (and a lone step's Explain this step), and its switch, step limit and captions in Settings > Chat · /btw ·
Show thinking in the run's menu and in its reply's ⋯, and Settings > Chat's Thinking choice (Show in every chat, On request, Off) and its caption

**Code**
- Rows and words: `Conduit/Views/ChatActivityRows.swift` (ChatStepStyle, ChatStepLabel, ChatStepSubject, ChatStepGroupHeader, ChatWorkingLine), `Conduit/Views/ChatView.swift` (ToolCard, SettledToolCardContent), `Conduit/Views/TranscriptModel.swift` (rows: a step folded into its run draws no row; the working line's tool and timer, TranscriptWorkingLine)
- Hermes' tools catalog: `Conduit/Models/ToolCatalog.swift`, toolset names shared with Settings > Capabilities in `Conduit/Models/CapabilityCatalogModels.swift` (CapabilityToolsetOrdering.label), `Conduit/Services/AppState.swift` (loadToolCatalogIfNeeded), `Conduit/Views/ChatRowState.swift` (toolCatalog)
- Tool Search wrapper: `Conduit/Models/ToolSearchBridge.swift`
- Show thinking: `Conduit/Views/ChatActivityRows.swift` (ChatThinkingReveal, chatStepMenu, ChatStepGroup.countedMembers), `Conduit/Views/ChatRowDisclosure.swift` (showsThinking, willShowThinking), `Conduit/Services/ChatScrollState.swift` (stepsAbove), `Conduit/Views/ChatView.swift` (AssistantMessageMoreMenuWithThinking, ThinkingCard; a saved copy's steps are the chat's own rows); the Thinking choice: `Conduit/Models/Models.swift` (ReasoningDisplayMode, ProfileDisplayPreferences), `Conduit/Views/AuxiliaryViews.swift` (ChatSettingsDetail.fields), `Conduit/Services/AppState.swift` (loadProfileSettings, setProfileSetting, loadProfileDisplayPreferences; kept on the device by rememberDisplayPreferences and restoreDisplayPreferences)
- Run summaries: `Conduit/Services/ChatStepSummaries.swift`, `Conduit/Services/AppState+StepSummaries.swift`, `Conduit/Views/AuxiliaryViews.swift` (StepSummarySettings), `Conduit/Views/ChatRowState.swift` (stepSummariesAsked, canExplainStepRuns), sent with `Conduit/Services/HermesClient.swift` (startSideAgent)
- Tool categories: `Shared/Widgets/HermesTurnActivity.swift`, and its twin, `notifier/live_activity.py` (`tool_category`)
- Tests: `ConduitTests/ChatTypographyTests+StepRows.swift`, `ConduitTests/ChatTypographyTests+StepSummaries.swift`, `ConduitTests/ChatScrollStateTests+RowDisclosure.swift` (Show thinking, the Thinking choice), `ConduitTests/ConfigFieldLocalizationTests.swift`

**Rulings**
- A step Conduit has words for keeps them, translated ("Searched the web"). Any other step is named: an MCP or connector tool by its app with the action as its subject line (a Tool Search batch: its apps' names with the connector icon, then every action it ran), else by the toolset Hermes' catalog (`/api/tools/toolsets`) puts it in, else by its own name made readable. "Used a tool" is only for a call with no name. Names are shown as Hermes writes them (2026-10-24, #1201).
- The catalog is read once per profile per run and saved on the device, so a chat opened offline or before the dashboard answers still names its steps. An empty answer keeps the saved catalog and is asked again (2026-10-24, #1201).
- The Live Activity stays on categories: its state goes through the push relay, which never sees tool names, so neither it nor the notifier's `tool_category` names tools (2026-10-24, #1201).
- A run's summary is opt-in and device-only, off by default. Once a turn has settled (its reply in place, nothing running) and its last run folds on screen (two steps or more of those Settings shows) with a tool call in it, Conduit asks a hidden `/btw` (Hermes' cache-sharing fork, no tools, the chat untouched) for a short train of thought in the app's language: one natural first-person paragraph, looking back, on what Hermes set out to do and why each step came next, a coherent story of intentions from the calls' real arguments that names a result only where it changed course (the reply already has the results) and never a tool's name, and that keeps to the calls since the user's last message. Its budget is about half a phone line per tool call (9 words a line, 2 lines at least and 4 at most, so a long run doesn't make a page of it). A run of more steps than Settings > Chat's limit (20 by default, 5 to 100, counted like the folded line's "N steps", the steps Settings shows) isn't summarized on its own (Michel, 2026-10-25, #1233).
- The folded run shows every step's icon and the count on its first line (an ellipsis when they don't fit) and the summary under them, uncut; opened, the summary stays at the top of the card, under the count (2026-10-25, #1233).
- Touching and holding a finished run whose first tool call has an id of its own, switch on or off, offers Explain these steps (Explain again over a summary), and a lone tool step offers Explain this step once its turn is done, its answer under the step's card (under a lone thought instead when Settings hides the tools, which then carries the menu). An answer to a question that was forgotten or asked again since is only taken from the stream. Its question lists the run's calls with their arguments and the start of their results (the first 30, then how many more followed), since /btw only sees up to the last reply and, once the chat's agent is gone, only a digest of tool names, and asks for a somewhat longer paragraph about that run alone. Its answer is kept like the others, so the switch only turns automatic summaries on and off and kept summaries always show (2026-10-25, #1233).
- A summary's /btw never notifies: its fork runs under the chat's session id, and the plugin keeps its answer from going out as the chat's reply push, or moving the Live Activity, on a Hermes that runs plugin hooks for forks (2026-10-29, Michel, #1495 carrying #1489, notifier #464 carrying #462; see Notifications).
- Summaries are kept per dashboard and profile, by the run's first tool call, so only a run whose call ids are its own is described (not ids numbered per turn, like `functions.web_search:0`). Questions unanswered after two minutes are forgotten (the run's menu can ask again), and so is an answer that comes later; that run keeps the count. The kept summaries describe chats, so they go with a dashboard's saved chats (sign-out, removal, a new interactive sign-in) and with Delete Saved Chats. In Conduit an answer never shows as a /btw note, late, replayed or asked by another device, and the user's own /btw is never taken for one (only the exact questions are, today's or 2.2.1's) (2026-10-24, #1202; #1233).
- Settings > Chat's Thinking is a choice of three (Eric, 2026-10-25, #1243): Show in every chat (Hermes' `display.show_reasoning` on), On request (thinking hidden, Show thinking offered), Off (hidden, no Show thinking anywhere). Hermes' key stays a switch other clients read; Conduit's `display.conduit_thinking_on_request` tells On request from Off while it is off. An install that had the switch on keeps Show, one that had it off gets On request. It is the only control for thinking: the old Show reasoning switch (an unused settings view's Chat display section) is gone. This replaces the earlier ruling that the profile-wide switch stays as it is.
- On request: a finished run with thinking offers Show thinking in its menu (touch and hold), and a reply right under such a run offers it in its ⋯ (the only way in when the tools are hidden too; not on a folded teammate reply). It shows that run's thoughts, the run and the thoughts opened, until Hide thinking, which puts the run and its thoughts back the way they were, or another conversation; nothing is saved or asked of Hermes, since the history already carries each reply's reasoning. The steps a summary counts, and the run's "N steps" line and its discs while its thinking shows, stay the ones Settings shows; when Settings shows none of the run's steps (the tools hidden too), the line counts the thoughts shown rather than read 0 steps (Michel and Eric, 2026-10-25, #1243; #1282).
- The display preferences last read or set are kept on the device per dashboard and profile, so before the config is read (offline from launch, or a read that fails) the chat and its saved copy draw as Settings last said, thinking set to Off included, and Settings > Chat's Thinking, Tool cards and Keep tool cards expanded rows show those choices (Self-improvement updates shows Never show, or Hermes' default when the rows show) (2026-10-26, #1282).
- History: #1202 (2.2.1) asked for one sentence of at most 15 words, only for runs of 3 or more tool calls, and switching off hid the kept sentences. Michel found the sentence listed tools and was cut after two lines, and asked for the story of intentions, the uncut layout and Explain on demand (2026-10-25, #1233).

**Open gaps**
- Summaries are kept on the device that saw the turn end: other devices, the Watch and turns that ended elsewhere show the count only. Sharing them would need the plugin to store them.
- A turn that ends while another chat is open on this device isn't asked about either; opening its chat later shows the count. Asking then would spend a model call on each old chat opened, so it is left to the run's Explain these steps.
- An older Hermes without the hidden `/btw` (`prompt.btw`) leaves the count, with no notice that the switch does nothing there.
- A Hermes that routes `auxiliary.side_question` to another model answers from a transcript digest, not the cached prefix. One with no live agent for the chat (restarted, or the gateway let it go) answers from a transcript where tool calls are names only and results are cut to 2,000 characters, so its automatic summaries say less (Explain these steps sends the calls itself).
- Other clients on the same chat (Hermes Desktop, the TUI, an older Conduit) show the hidden question and its answer as a `[btw …]` note.
- The saved offline copy of a chat shows kept summaries but offers no Explain: there is no live Hermes to ask.
- Runs from a provider that numbers its tool call ids per turn (`functions.web_search:0`) get no summary and no Explain menu; keying them would need the chat's durable id.
- The Live Activity, fed by the app and by the notifier's `tool_category` twin, says "Using a tool" for a step the chat row and working line name.
- An older Hermes' single-underscore MCP names (`mcp_server_tool`) can't be split into app and action; they read "Used a connector".
- Show thinking has nothing to show for a model that returns no reasoning text (hidden or summarized only), and a thought in the middle of a turn, above an interim reply, is reached from that reply's ⋯, not the last one's.

**Checked:** 2026-10-31, #1577 (Show thinking's and the Thinking choice's tests moved to ChatRowDisclosure's own, as the engine's tests went; Code); 2026-10-31, #1569 (the chat's toolsets read keeps its answer for Capabilities' Tools tab, which opens on it; how steps are named is unchanged); 2026-10-31, #1565 (which steps draw, and what the working line says, are decided in TranscriptModel; Code); 2026-10-31, #1552 (Settings' Thinking choice opens on its kept answer; what it saves is unchanged); 2026-10-30, #1550 (a saved copy's steps are drawn by the chat's own rows, with its open choices); 2026-10-29, #1495, carrying #1489 (a summary's /btw sends no push, notifier #464); 2026-10-26, at #1282, carrying #1243 (Show thinking on request, the three-way Thinking choice as the only thinking control, Hide thinking restoring the run, the count while thinking shows), after #1233, carried in #1236.

## Code fences in messages

Where a code block starts and ends, read the same by every piece of Conduit
that looks for one.

**Siblings:** chat bubbles (block views) · very long replies (sliced) · a call
screen card cut to its limit · a call turn cut to the plugin's limit · group
room mention links · Bot Chat mention routing · Local Live's spoken and shown
split · Read Aloud and live read-back · chat list previews and quotes

**Code**
- The rule: `Conduit/Views/Components/MarkdownText.swift` (MarkdownFence, MarkdownParser)
- Long replies: `Conduit/Views/Components/MarkdownLargeDocument.swift`
- Cuts: `Conduit/Voice/VoiceBackgroundJobs.swift` (clippedScreenMarkdown, fenceClosedPrefix, closingCutFence), `Conduit/Voice/VoiceHistory.swift` (VoiceTranscriptRecorder.clipped)
- Group rooms: `Conduit/Services/GroupChatModels.swift` (GroupRoomMentions.linkingMarkdown)
- Bot Chat routing: `Conduit/Services/BotMentions.swift` (proseStrippingCode)
- Spoken text: `Conduit/Voice/LocalLive/SpokenVisualSplitter.swift`, `Conduit/Voice/VoiceReadBack.swift`
- Previews and quotes: `Conduit/Services/PreviewText.swift`, `Conduit/Views/Components/ChatQuote.swift`
- Hermes Desktop directives: `Conduit/Views/Components/TranscriptDirectives.swift` (CodeFence, used by rewriting and by `Conduit/Voice/SpokenMediaTagFilter.swift`)
- Tests: `ConduitTests/VoiceBackgroundJobTests.swift`, `ConduitTests/VoiceHistoryTests.swift`, `ConduitTests/GroupChatModelsTests.swift`

**Rulings**
- A fence is three or more backticks or tildes; only a line of the same mark, at least as long and with nothing after it, closes it, so a ```` block can show ``` lines (#893). The cuts and group room mention links read fences with `MarkdownFence`; the spoken-text readers follow the same rule in their own line-by-line code (2026-10-24, #1220, from #1002).
- Bot Chat mention routing strips code with Hermes' own pattern (the first ``` closes a block), not this rule, so Conduit picks the same bot Hermes would.
- A cut that leaves a block open closes it with a fence as long as the opener, and the closer's room comes off the cut, so the result stays within its limit however long the fence (2026-10-24, #1220).

**Open gaps**
- Previews and quotes only drop fence lines and track no block, so they need no closing rule (not a gap, noted so nobody adds one).
- A ```` block holding a ``` line in a Bot Chat can route a mention after that line, as Hermes does; changing it starts in Hermes.

**Checked:** 2026-10-30, #1524 (a Desktop card or preview directive in a code block stays as written: read-back, previews, quotes and the streaming speech filter); 2026-10-28, #1449 (Local Live's split leaves file tags unsaid and shows their files); 2026-10-28, #1430 (read-back's action filter runs only on lines outside a code block); 2026-10-24, at #1220.

## Files prepared for preview and Save to Files

Gateway files Conduit downloads to show or hand to the share sheet: where the
copy goes and when it is removed.

**Siblings:** a chat's media and file previews · the picture viewer · the
Artifacts page's opener · the gateway media resolver · the Folder's Quick Look
and Share or Save

**Code**
- Media previews: `Conduit/Views/Components/MediaPreviewPresenter.swift` (stage, stagingRoot, removeDirectory), `Conduit/Views/Components/MarkdownText.swift`, `Conduit/Views/Components/GatewayMediaDataURLResolver.swift`, `Conduit/Views/V2/V2ArtifactsViews.swift`
- Folder: `Conduit/Views/V2/V2WorkspaceViews.swift` (quickLook), through the media preview presenter
- Picture viewer: `Conduit/Views/Components/ImageGalleryViewer.swift` (ImageGalleryFile, ImageGalleryViewController.finish)
- Tests: `ConduitTests/MarkdownLargeDocumentTests+MediaPreview.swift`

**Rulings**
- Each download goes in a folder of its own, removed when the preview or share sheet that asked for it closes, or when it is dismissed or switched to another file while still downloading; a previous run's leftovers are swept at launch (2026-10-24, #1220, from #1002).
- The Folder opens files through the media preview presenter, so its copies follow the same rule; the workspace browser's own download folder is gone (2026-10-27, #1399).
- The picture viewer fetches each picture into a folder of its own the same way, removes one once the reader is two pages past it (paging back fetches it again), and removes the rest when it closes, including one still arriving then; a photo on the device or a copy kept on the phone is shown in place and stays (2026-10-29, #1491).

**Open gaps**
- None known.

**Checked:** 2026-10-30, #1524 (the resolver gains the connected dashboard's bridge and a plugin route read for Desktop cards; previews unchanged); 2026-10-29, #1491 (the picture viewer's copies); 2026-10-27, #1399; #1220.

## Review labels

Whose turn a contributor's PR is: `waiting on contributor` while it waits on
its author, `waiting on Eric` once the author has answered.

**Siblings:** this repo's label workflow · the notifier's copy of it ·
CONTRIBUTING.md's Review labels section here and in the notifier · docs/CI.md's
workflow table

**Code**
- Workflow: `.github/workflows/contributor-label.yml`
- Notifier: `notifier/.github/workflows/contributor-label.yml`, `notifier/CONTRIBUTING.md` (Review labels)
- Text: `CONTRIBUTING.md` (Review labels), `docs/CI.md` (the workflow table)

**Rulings**
- `waiting on contributor` marks a PR waiting on its author; a push or a PR comment by the author swaps it for `waiting on Eric`, and adding `waiting on contributor` again takes `waiting on Eric` off (2026-10-24, notifier #351, Eric asked for the flip).
- The workflow only edits labels: nothing from the PR is checked out or run, so it can run on forks' PRs (2026-10-24, notifier #351).

**Open gaps**
- A reply inside a review thread doesn't flip the label, since a fork's review events get a read-only token; the docs tell contributors to comment on the PR or push.

**Checked:** 2026-10-24, at #1216.

## Connection setup guide

How to make the dashboard reachable from the phone (Tailscale Serve, the
home network, your own domain) and what to tell Hermes to set it up.

**Siblings:** README.md (Connecting: the ask-Hermes prompt, Docker or a NAS,
by hand) · the website's setup page (setup/index.html, written by
scripts/build_site.py in hermes-conduit-website) · the sign-in screen's Need
help connecting? assistant and the prompts it hands out ·
docs/OWN_VOICE_SERVER.md (names Tailscale only as a way to reach the speech
server, never Tailscale SSH)

**Code**
- Assistant: `Conduit/Services/ConnectionSetupFlow.swift`, `Conduit/Views/ConnectionSetupView.swift`, `Conduit/Views/ConnectionSetupForm.swift`, `Conduit/Views/Login/LoginScreens.swift`
- Docs: `README.md`

**Rulings**
- Remote access goes through Tailscale Serve, never Tailscale SSH or a port opened to the internet. The README and the setup page say Conduit doesn't need Tailscale SSH and to keep Tailscale updated (Eric, 2026-10-27, #1377, from issue #1366).

**Open gaps**
- None known.

**Checked:** 2026-10-27, at #1377.

## Connection failure messages

What Conduit says when it can't connect or sign in, classified from the
error's type and code (never its text), and the troubleshooting it points to.

**Siblings:** the sign-in screen's failure card · the setup assistant's
connection test · Repair's Reconnect Now · Settings' Sign In Again · Siri's
voice launch notice · the HTTPS & certificates troubleshooting page · the
website's setup page (When it doesn't connect, in scripts/build_site.py in
hermes-conduit-website)

**Code**
- Classification and copy: `Conduit/Services/ConnectionFailure.swift` (ConnectionFailureClassifier, TLSTrustDiagnosis, userTitle, userMessage, helpDestination)
- Where it lands: `Conduit/Services/ConnectionSetupFlow.swift` (repairPath), `Conduit/Services/ConnectionSetupTest.swift` (ConnectionSetupTestRecoveryPlan)
- Shown: `Conduit/Views/ConnectionSetupForm.swift`, `Conduit/Views/ConnectionSetupView.swift` (the troubleshooting checks), `Conduit/Voice/Wake/PendingVoiceLaunchPolicy.swift`
- Tests: `ConduitTests/ConnectionFailureTests.swift`, `ConduitTests/ConnectionSetupTestTests.swift`, `ConduitTests/ConnectionRepairTests.swift`

**Rulings**
- No TLS validation override: a certificate iOS refuses is never accepted, on any device (Eric, 2026-10-19, issue #129).
- A refused certificate names the check iOS failed, read from the peer trust URLSession leaves on the error: the certificate doesn't name the address, it breaks Apple's certificate rules (825 days, serverAuth, key size, SHA-2), its dates, or else its root isn't trusted. The most specific comes first, since trusting the root wouldn't fix the others (2026-10-27, #1405, from issue #129's iPad report).

**Open gaps**
- The Watch and the dictation clip retry treat TLS failures only as never sent or not transient; they show no classified copy.

**Checked:** 2026-10-27, #1405.

## Review bots

The two opencode reviewers that review every PR here and in the notifier, and
the models they call.

**Siblings:** this repo's reviewer workflow and opencode config · the
notifier's copies of both

**Code**
- Workflow: `.github/workflows/opencode-review.yml` (the reviewer matrix, secrets and prompt)
- Config: `opencode.json` (providers, models and the reviewer's permissions)
- Notifier: `notifier/.github/workflows/opencode-review.yml`, `notifier/opencode.json`
- CI's smoke skip: the "Does the change need the macOS build" step in `.github/workflows/ci.yml` (its app-folder Markdown rule is the review plan's too; `scripts/tests/test_ci_workflow_contract.py` holds them to the same pattern)
- Change id: the review plan's inline copy in `.github/workflows/opencode-review.yml` (and the notifier's), and `scripts/pr-change-id.py`, which CI's smoke skip uses; `scripts/tests/test_pr_change_id.py` holds this repo's two to the same ids

**Rulings**
- Two reviewers gate merges (one, GLM-5.3-Flash, on a docs and config PR; see Review cost below), and both repos run the same pair: GLM-5.3-Flash on Z.ai at reasoning effort max (2026-10-30, Eric asked to switch back from GLM-5.3, which it reviewed with from 2026-10-28, #1458), and Claude Haiku 5.5 on the Anthropic API at effort high, set in opencode.json (2026-10-28, #1421, Eric; Muse Spark 1.3 on Command Code before that, #1335).
- Both repos give the reviewers the same prompt apart from their focus areas: bugs the PR introduces first, a concrete failure for each finding, the four severities defined, and REQUEST_CHANGES on any critical or major finding (2026-10-28, #1421, Eric asked for a review of the prompt).
- A provider whose id is in the models.dev catalog (`anthropic` is, as `commandcode` was) whitelists the one model it reviews with. Otherwise opencode titles each session with the newest small model in that catalog, which was Gemini 3.8 Flash, a call Eric didn't want (2026-10-27, #1391 and notifier #428, Eric asked why Gemini Flash was being called).
- Reviews run when a PR opens, on every push, on reopen and, on a fork's PR, on the run-review label, drafts included; marking a draft ready doesn't rerun them, since that head was already reviewed (2026-10-29, #1465 and notifier #453, Eric asked why reviews reran after draft to ready).
- Review cost (2026-10-29, #1466 and notifier #454, Eric: reviews shouldn't spend inference on code they already saw). A `plan` job decides before any model runs: it waits 60s so a quick push cancels the run first; it skips a run whose change (the PR's diff from its base, whitespace kept; hunk headers and blob ids left out, and a Markdown file counted by the words the PR adds and removes, so a resolved feature map conflict still matches) matches a commit a review already ran on (whatever its verdict), so a clean merge of main or a reopen isn't reviewed again; and a PR whose files (both names of a rename) are all docs or config (Markdown, text, JSON, YAML, TOML; .github/, the notifier's skills/, opencode.json, .coderabbit.yaml, manifests that declare code, targets or dependencies, the notifier's data files the plugin reads, channels.yaml, bip39_english.txt and upstream/contract.yml, and Markdown under an app or test folder, which CI always builds too, count as code; Eric chose both reviewers for that Markdown on 2026-10-29, #1469 and notifier #456) gets GLM-5.3-Flash alone, as Eric asked, since it's the cheaper of the two. A manual run (both repos have one now), or adding run-review to a fork's PR, always reviews. CI skips this repo's Smoke job on the same change id (`scripts/pr-change-id.py`, docs/CI.md, #1467): after any merge of main that keeps the id, not only a feature map conflict, the merge commit isn't built on the PR, as for a PR that never merged main (Eric, 2026-10-29, #1467).

**Open gaps**
- The workflow runs main's config, so a change to either file is first exercised by the review after it merges.
- A clean merge of main isn't reviewed again, so a main change that breaks the PR's code without touching its diff goes unreviewed until the next push; a reviewer or prompt change on main doesn't re-review a change already reviewed either. A manual run covers both (2026-10-29, #1466).
- Data files the app or CI reads (`Conduit/Cards/card-schema.json`, `scripts/smoke-suite.json`, `scripts/hosted-suite.json`, test fixtures) count as config, so a PR that changes only those gets GLM-5.3-Flash alone (2026-10-29, #1466).
- A run can't say which PR it reviewed (GitHub fills a run's PRs from the branch's open PRs when read), so the same commit reviewed in a PR into main counts as reviewed in a PR into `pulse` or `linked-rooms` from the same branch (2026-10-29, #1466).
- A Markdown file counts by its words, so a push that only reorders or re-indents Markdown the PR already changed matches the earlier review and isn't reviewed again; that keeps a resolved feature map conflict from costing a review (2026-10-29, #1466).
- CI's smoke skip counts a passing Smoke from whatever PR it ran for, as reviews do: a commit that passed in a PR into `pulse` or `linked-rooms` counts for a PR into `main` from the same branch (2026-10-29, #1469).
- Re-running a review from the Actions page still reviews: the run being rerun isn't finished, so it doesn't count as reviewed (2026-10-29, #1466).

**Checked:** 2026-10-30, #1548 (GLM-5.3-Flash again; notifier #480); 2026-10-29, #1502 (Eric ruled that Markdown under an app or test folder gets both reviewers); 2026-10-29, #1469 (Markdown under an app or test folder counts as code for reviews and always builds in CI; notifier #456); #1467 (the change id hashes any bytes and a failing one counts as no match; the notifier's data files count as code, notifier #455; CI's copy of the change id is in Code, held to the review's by a test); #1466.

## Nightly reruns

A scheduled Nightly whose only losses are jobs GitHub never gave a macOS runner reruns
those jobs by itself.

**Siblings:** the Nightly workflow it follows (its name and its matrices) ·
docs/CI.md's workflow table and the Nightly paragraph · docs/RELEASE_WORKFLOW.md's
rule that every job of a candidate's dispatched Nightly passes

**Code**
- Rerun: `.github/workflows/nightly-rerun.yml`, `scripts/tests/test_nightly_rerun.py` (the decision against fixture job lists, and that it still follows Nightly's name and `fail-fast: false` matrices)
- Nightly: `.github/workflows/nightly.yml`
- Docs: `docs/CI.md`, `docs/RELEASE_WORKFLOW.md`

**Rulings**
- A job counts as never placed when it is `cancelled` with no runner and no steps (GitHub's "not acquired by Runner of type hosted"). The run reruns its failed jobs only when every job that didn't pass is one of those, at most twice, so a test that ran and failed is never retried. Only scheduled runs rerun: a dispatched run, such as a release candidate's, keeps its own result, so the release rule is unchanged (2026-10-29, #1506, after Nightly lost 2 jobs on 10-28 and 3 on 10-29 to macOS arm64 capacity).

**Open gaps**
- The failure email for the first attempt still goes out. The two-rerun cap assumes GitHub fires `workflow_run` for each rerun attempt; the first live rerun shows it.

**Checked:** 2026-10-29, #1506.

## Smoke selection

What the one macOS Smoke job runs on every PR and push, against what only the
nightly run covers.

**Siblings:** the pinned lists and their caps · the change's own unit classes
· the source contracts · the UI targeted retry · the step summary · the
nightly partition, which runs everything Smoke leaves out · docs/CI.md

**Code**
- Lists and caps: `scripts/smoke-suite.json`; validation and the change's own classes: `scripts/plan-tests.py` (`smoke`)
- Workflow steps: `.github/workflows/ci.yml` (the plan job's selection, the Smoke job's unit and UI steps)
- UI retry: `scripts/smoke-retry-classes.py`; step summary: `scripts/smoke-summary.py`
- Nightly partition: `scripts/hosted-suite.json`, `.github/workflows/nightly.yml`; the app-only overlay its unit shards build: `project-tests.yml`
- Tests: `scripts/tests/test_ci_workflow_contract.py`, `scripts/tests/test_smoke_job_runner.py`, `scripts/tests/test_hosted_ci.py`
- Docs: `docs/CI.md`

**Rulings**
- Smoke pins single tests (Class/testMethod), never whole classes, under `max_unit_tests` (70) and `max_ui_tests` (4); `plan-tests.py smoke` fails a whole-class entry, a test its class doesn't declare, a pinned nightly-only timing family and a list over its cap. Add coverage by swapping a test; raising a cap is a deliberate change with its reason in the PR (Eric, 2026-10-29, #1508: whole classes let unit smoke grow from 195 s to 240 s with the list unchanged).
- The source contracts and the change's own unit classes run whole; a changed class runs in place of the tests pinned from it (2026-10-29, #1508).
- Everything Smoke leaves out runs every night; the nightly run is the exhaustive authority (CI v5, #739).
- Smoke builds the full app (`project.yml`) on every PR and push, from the cache main's latest merge saved; the app-only overlay (`project-tests.yml`) is built only by the nightly unit shards and the App Store screenshots capture job (`.github/workflows/app-store-screenshots.yml`). An app-only PR build restored only nightly's cache and recompiled the day's main: 682 s to a finished build against 537 s, medians of 275 runs 2026-10-22..29 (2026-10-29, #1513).

**Open gaps**
- A changed UI test class doesn't join Smoke: a UI test a PR adds or edits first runs at night. UI tests are the slow ones (36-150 s each) and the list is capped at 4 (2026-10-29, #1508).
- A changed unit class with no timing baseline is charged 3 s of `changed_budget_s`, and `scripts/test-timings.json` was last seeded in August, so a PR adding several slow new classes isn't held to the budget (2026-10-29, #1508).

**Checked:** 2026-10-29, #1513 (Smoke builds the full app); #1508.

## Settings connection page

The page with the server, Reconnect, Restart Gateway, Cloudflare Access,
custom headers and sign out, and the places that send people to it.

**Siblings:** the V2 Settings row (Connection, first under the profile name)
and the page title · the legacy Settings sheet (Gateway, under Connection) ·
the chat's Gateway sheet · README.md (Cloudflare Access) · the notifier's
support page · the website's setup page (setup/index.html in
hermes-conduit-website)

**Code**
- Rows and page: `Conduit/Views/AuxiliaryViews.swift` (v2Sections, SettingsHome, GatewaySettingsDetail and its title)
- Chat's sheet: `Conduit/Views/ChatSupportSheets.swift`, `Conduit/Views/V2/V2ConversationScreen.swift`
- Docs: `README.md`, `notifier/docs/support/index.html`

**Rulings**
- The page takes its row's name: Connection in V2's Settings, Gateway in the legacy sheet. Docs and support text say Settings > Connection (2026-10-26, #1298).

**Open gaps**
- None known.

**Checked:** 2026-10-26, at #1298.

## Another saved dashboard's address

When the address typed while editing or repairing one dashboard is already
saved as another.

**Siblings:** Settings' Edit Connection · Repair's password reconnect
(Reconnect Now) · Repair's sign-in (browser and native OAuth) · Settings'
Sign In Again · the two alerts' text (no Settings caption, README or doc
describes this case)

**Code**
- Edit Connection: `Conduit/Services/ConnectionSetupApplication.swift` (perform, addressBelongsToDashboard), `Conduit/Views/AuxiliaryViews.swift` (the Settings not applied alert)
- Repair: `Conduit/Services/AppState.swift` (performConnectionRepair, repairAddressOwner, registerRepairDashboard, repairRegisteredDashboardIDs, beginConnectionRepair, beginSavedConnectionRepair), `Conduit/Services/ConnectionRepair.swift` (ConnectionRepairActivationOutcome), `Conduit/Views/ConnectionSetupView.swift` (beginRepairSignIn, activate, the Already a Saved Dashboard alert)
- Tests: `ConduitTests/ConnectionRepairTests.swift`

**Rulings**
- The two never merge: nothing of the other dashboard's (password, Face ID choice, Cloudflare token, sign-in cookies) is written. Edit Connection says so; Repair stops before connecting and offers to switch to it (2026-10-24, #995, #1219, Eric).
- Repair's sign-in is checked before its sheet registers the address, and a new address a repair registered (by sign-in or password reconnect) stays that repair's own for its next try, until that repair connects or another repair begins (2026-10-24, #1219).

**Open gaps**
- Settings' Sign In Again only offers the active dashboard's own address, so it never meets this case; it shares Repair's activation and would refuse the same way.

**Checked:** 2026-10-24, at #1219.

## App Store screenshots and showcase clips

What the capture run shows of each screen: the App Store screenshots and
previews, and the short clips hermesconduit.app (kaishi00/hermes-conduit-website#2)
and the README's "See it in action" strip show.

**Siblings:** the iPhone and iPad capture · the Watch capture · the call
fixtures they launch (phone and Watch) · the showcase clips · the App Preview
cut · scripts/app-store/README.md · README.md's "See it in action" strip · the hermesconduit.app pages that show the
clips (kaishi00/hermes-conduit-website)

**Code**
- Workflow: `.github/workflows/app-store-screenshots.yml`
- Scripts: `scripts/app-store/record-clip.sh`, `scripts/app-store/cut-preview.sh`
- UI test: `ConduitScreenshots/AppStoreScreenshotTests.swift`
- Fixtures: `Conduit/Services/ScreenshotCallFixture.swift`, `ConduitWatch/WatchVoiceCall.swift` (applyScreenshotFixture)
- Demo Hermes: `scripts/app-store/start-demo-hermes.sh`, `scripts/app-store/llm_stub.py`, `scripts/app-store/demo-script.json`
- Text: `scripts/app-store/README.md`
- README strip: `README.md` ("See it in action"), `docs/media/voice.webp`, `docs/media/watch-speaking.webp`, `docs/media/watch-approval.webp`

**Rulings**
- A real Hermes with a scripted model, not a mock gateway; only audio-driven states (calls) use DEBUG-only launch fixtures (2026-10-17, #753).
- Clips come from the same fixtures as the screenshots. The workflow lists the screenshot states and the clip states separately, so a call state that should move goes into both lists. `home` and `listening` are screenshots only: neither moves enough to need a clip (2026-10-25, #1226).
- The site and README show only V2 media; footage from before the V2 redesign isn't reused (2026-10-24, Eric, #1226).

**Open gaps**
- No clips yet of an incoming Hermes call, of CarPlay or of a lock-screen approval. A simulator can't show any of them (calls ring through CallKit, and the CarPlay window opens only by hand), so they come from recordings on Eric's devices, then go into the README strip and the site (#1193).

**Checked:** 2026-10-25, at #1228.

## Pictures in messages

How a picture in a transcript loads, and the room its row takes before it
does.

**Siblings:** chats, project chats and Bot Chat · the saved-chat copy · reply
pictures in tool results, large documents and HTML previews · call job
result sheets · group rooms · the cards drawn in web pages, which share the
memo and the transcript's rule for rows growing above the reader (see Cards
drawn in web pages) · text that describes it (none today: no Settings
caption, briefing or doc says how pictures load)

**Code**
- Attachments: `Conduit/Views/ChatView.swift` (UserImageAttachmentPreview)
- Reply pictures (`MEDIA:` and web): `Conduit/Views/Components/MarkdownText.swift` (RemoteMarkdownImage, WebFallbackImage), `Conduit/Views/Components/BoundedRemoteImage.swift`, `Conduit/Views/Components/GatewayMediaDataURLResolver.swift` (imageCacheKey, imageCacheKey(forMediaPath:)), set for job sheets in `Conduit/Views/LiveVoiceCallJobs.swift`
- Kept and remembered: `Conduit/Services/TranscriptImageCache.swift` (files on the phone), `Conduit/Services/TranscriptPictureMemory.swift` (decoded reply pictures, attachment previews, every picture's size and the card heights, loaded as the app opens from `Conduit/ConduitApp.swift` and again asked for by ChatView), both forgotten in `Conduit/Services/AppState.swift` (wipeOfflineChatCache, deleteSavedChats)
- A picture's arrival, or its failure: `Conduit/Views/Components/MarkdownText.swift` (placeGatewayImage, placeRemoteImage, placeGatewayFailure, placeRemoteFailure), the row's new height reaching `Conduit/Views/TranscriptLayout.swift` (rowResized) from `Conduit/Views/TranscriptView.swift` (TranscriptCellRoot), and `Conduit/Services/TranscriptScroller.swift` (keepAnchor) keeping the reader's row, see Cards drawn in web pages
- Tests: `ConduitTests/TranscriptInlineImageTests.swift`, `ConduitTests/TranscriptScrollerTests.swift` (Rows changing height), `ConduitTests/TranscriptLayoutTests.swift` (testARowChangingHeightMovesTheRowsUnderItInTheSamePass)

**Rulings**
- A row never changes height when its picture arrives, if the picture has loaded on this phone before: its size is remembered (kept next to the pictures, read once off the main thread) and its placeholder takes it (2026-10-25, #1239, #1238).
- Reading, decoding and keeping a picture, and its size, stay off the main thread: a body looks pictures and sizes up in memory only (a local photo's existence is still checked there: a stat, never a picture read). A picture kept on the phone is never fetched again (2026-10-25, #1239).
- A picture with no remembered size takes its height as it arrives, as a card does. In a chat the reader's row (the first starting on screen) stays put in the same layout pass, scrolling or not, a finger keeping its drag and a fling its momentum (TranscriptScroller.keepAnchor): a row above it grows up out of view, one on screen grows down. Its size is remembered as it shows. A picture still loading when its row's cell goes to another row is dropped, and shows from memory or loads again when the row is back; one whose row has moved on to another picture never shows there. In a chat a web picture lands without its fade, since the move needs the growth in one pass (2026-10-25, #1270, #1238; taken at once, scrolling or not, since the transcript rewrite gave every row a frame of its own, 2026-10-31, #1577: the wait for the reader's scrolling to rest, and the rules it needed, went with ChatScrollEngine; Eric delegated the chat scroll's design to Claude, 2026-09-28, and approved the transcript rewrite's design, 2026-10-30).
- A picture that won't load (unavailable, too large, or a web picture its page can't show either) gives its place to its label or fallback the same way, at once, the reader's row kept by what the label's layout took. The web fallback's page measuring the picture goes the same way, and a row loading again a picture that failed keeps its label meanwhile (2026-10-26, #1270; at once since 2026-10-31, #1577, under the transcript rewrite's design, which Eric approved 2026-10-30).
- What memory already holds for a row (its picture, decoded, or the picture's size) shows as the row draws, on its first frame or a later one (another row of the same picture showed it since, a cold launch's kept sizes loaded): a row that resizes on its own keeps the reader's row like any growth, so nothing waits for an arrival. A web picture already decoded shows on the first frame too, its size remembered or not (2026-10-26, #1270; on a later frame too since 2026-10-31, #1577, under the transcript rewrite's design, which Eric approved 2026-10-30).
- Outside a transcript (job sheets, whose web pictures load through the same view) a picture, or the label of one that won't load, takes its height as soon as it arrives too, but nothing there keeps the reader's row: a row above them grows down into what they read (2026-10-26, #1270). The saved copy's rows are the chat's own, drawn by its transcript, so their pictures arrive as a chat's do (2026-10-30, #1550), and so are a group room's, whose web pictures land without their fade as a chat's do (2026-10-31, #1590).

**Open gaps**
- A picture never loaded on this phone, or kept by a build before #1239 and not shown since, or whose row was laid out before a cold launch's kept sizes loaded, still grows its row once as it arrives: above the reader the offset moves with it, on screen it grows below what they look at, unanimated. Its height follows the row's width, so the memo can't reserve it before it loads, and only a read on the main thread before the first frame, which the ruling above keeps off it, would have the kept sizes in time.
- Job sheets have no transcript: a web picture never loaded on this phone grows its row where it is, and above a reader scrolled back it moves what they read, as chats did before #1270.
- Group rooms show no `MEDIA:` pictures: their Markdown is given no gateway data URL (the resolver they have since #1524 reads Desktop cards only).
- Past 4,000 remembered sizes the memo starts again (no LRU), so pictures grow once more until each loads again.

**Checked:** 2026-10-31, #1590 (group rooms draw on the transcript: a picture, or its label, takes its height as it arrives with the reader's row kept, and a web picture lands without its fade, the room's rows reading a ChatRowDisclosure as a chat's do; Rulings, gaps); 2026-10-31, #1577 (chats draw on the transcript's collection view: a picture, or its label, takes its height as it arrives, scrolling or not, and TranscriptScroller keeps the reader's row; ChatRowArrival and the engine's wait for a rest are gone; the rulings #1566 departed from rewritten, and its Open gaps line gone; Code, Rulings, Tests, gaps); 2026-10-31, #1566 (TranscriptScroller's rule for rows growing above the reader, not called yet; pictures arrive as before; Code, and the rulings it departs from in Open gaps); 2026-10-30, #1550 (the saved copy is drawn by the chat's engine, so its pictures arrive as a chat's); 2026-10-30, #1524 (group rooms get the connected Hermes' resolver for Desktop cards only, their `MEDIA:` pictures still don't load; the resolver gains connectedDashboardBridge); 2026-10-29, #1491 (a tapped picture opens in the picture viewer among the chat's pictures); 2026-10-26, #1281 (wipeOfflineChatCache also forgets Predictive's state); at #1270.

## The picture viewer

A picture tapped full screen: swiped left and right through the pictures
around it, closed with a swipe down, zoomed with a pinch or a double tap, and
shared or saved from its Share button.

**Siblings:** chats, project chats and Bot Chat (attachments, reply pictures,
tool pictures) · the saved-chat copy · call job result sheets and the cards a
voice model shows · group rooms · the Artifacts page, a chat's Artifacts sheet
and the panel beside the chat · the Folder tab · iPhone, iPad and Mac (the
same viewer; keys and a trackpad on an iPad or Mac) · Quick Look, which still
opens videos, audio and documents · README.md · text that describes it (the
pictures' VoiceOver hint "Opens full screen with save and share")

**Code**
- Viewer and presenting it: `Conduit/Views/Components/ImageGalleryViewer.swift` (ImageGalleryViewController, ImageGalleryPageController, ImageGalleryDecoder, ImageGalleryItem, ImageGallery, ImageGallerySource, the `imageGallery` environment value), `Conduit/Views/Components/MediaPreviewPresenter.swift` (presentGallery)
- What a chat lists: `Conduit/Views/Components/ImageGalleryItems.swift` (ChatImageGallery, the item makers), set in `Conduit/Services/AppState.swift` (chatImageGallery, from chatRowsOnScreen: the saved copy's pictures while it stands in) and `Conduit/Views/ChatView.swift`
- Taps: `Conduit/Views/ChatView.swift` (UserImageAttachmentPreview), `Conduit/Views/Components/MarkdownText.swift` (RemoteMarkdownImage.openImage)
- Other lists: `Conduit/Views/GroupChatView.swift` (GroupRoomImageGallery), `Conduit/Views/LiveVoiceCallJobs.swift` (both sheets), `Conduit/Views/V2/V2ArtifactsViews.swift` (openImage), `Conduit/Views/V2/V2WorkspaceViews.swift` (openImage)
- Tests: `ConduitTests/MarkdownLargeDocumentTests+ImageGallery.swift`

**Rulings**
- Pictures page in Conduit's own viewer, not Quick Look: Quick Look shows one file and has no swipe down. Videos, audio and documents still open in Quick Look; a picture never pages to one (2026-10-29, #1491, Eric asked for both gestures).
- A picture pages through the pictures of what it was tapped in, in the order they show: a chat's (each message's pictures in its text, then the ones it attaches, then a tool's), the saved copy's, a room's, a job result's or card's, the Artifacts list's as filtered, or the Folder's (the search's names, else the file's folder, else Recently Changed); one in a Markdown file the Folder previews pages through that file's pictures. Each picture is listed once, where it first shows. One its list doesn't have (a reply still streaming) opens alone (2026-10-29, #1491).
- The list is read when a picture is tapped, never while scrolling: each screen holds one source, so no row redraws for it. Each picture fetches its original only as its page comes near (its own, then its neighbours once it is in, so a tap never starts three large downloads at once), the way its row opened it alone: the photo on this device, the copy kept on the phone, then Hermes; a picture in a list fetches as Artifacts and the Folder open a file. The row's own copy shows until the original is in, and stays if the original can't be had (2026-10-29, #1491).
- A swipe down (or up) of a picture that isn't zoomed in drags it, fading the backdrop; past a fifth of the screen or flung it closes, short of that it springs back. A zoomed picture pans instead, and its edge hands a sideways swipe on to the next. One finger only: two are a pinch. A trackpad's two-finger swipe does the same; on a keyboard the arrows page and Escape closes; VoiceOver pages with a three-finger swipe and closes with the escape gesture (2026-10-29, #1491).
- A single tap shows or hides the bar (Done, the name, "3 / 12", Share); Share opens once the picture's original is in. The Folder's Share or Save opens a picture in the viewer too, since its Share saves and copies (2026-10-29, #1491).
- A picture whose original can't be had keeps the row's copy, or says "Image unavailable" ("Too large to open on this phone" for one over the download limit), and one that failed otherwise (a dropped connection) is fetched again each time it is paged to; one too large isn't, since it would be again (2026-10-29, #1491).
- Copies fetched for the viewer are removed once it is two pages past them, and the rest when it closes, so a long list of large photos doesn't fill the phone (see Files prepared for preview and Save to Files).

**Open gaps**
- Not checked on a device yet: the swipe down beside the pager's own pan, the zoomed edge handing on to the next page, and the trackpad swipe on a Mac.
- A reply still streaming isn't listed: its pictures open alone until it settles.
- An animated GIF plays at up to 120 frames, drawn small enough that its frames stay within 32 MB (the pager holds three pages); Quick Look played every frame at full size.
- The Folder pages through its listed files only: a folder not opened in the tree isn't listed.

**Checked:** 2026-10-30, #1550 (a saved copy's pictures page through the chat's own list, from the rows drawn); 2026-10-29, #1491.

## Cards drawn in web pages

How an HTML preview (`::preview{file=…}`), a Mermaid diagram or a LaTeX
formula draws in a message, and the room its row takes before its page
reports its height.

**Siblings:** chats, project chats and Bot Chat (the transcript's rows) · the
saved-chat copy · call job result sheets · group rooms · the full-screen
sheets (the same page, interactive) · pictures in messages (the same memo
and the same rule, see Pictures in messages) · text that describes it (none
today: no Settings caption, briefing or doc says how these cards draw)

**Code**
- HTML previews: `Conduit/Views/Components/HTMLPreviewBlock.swift` (HTMLPreviewBlock, heightKey, HTMLPreviewPage.placeholderHeight); the `::preview` grammar, shared with Desktop cards: `Conduit/Views/Components/TranscriptDirectives.swift` (segments, isHTML)
- Diagrams and formulas: `Conduit/Views/Components/MarkupBlock.swift` (MarkupBlock, heightKey(for:), placeholderHeight(for:))
- The room a card holds, and its height taken: `Conduit/Views/Components/ChatCardHeight.swift` (frameHeight, pageMeasured, pageReplaced), the row's new height reaching `Conduit/Views/TranscriptLayout.swift` (rowResized) from `Conduit/Views/TranscriptView.swift` (TranscriptCellRoot)
- The reader's row kept: `Conduit/Services/TranscriptScroller.swift` (keepAnchor: a row growing above a browsing reader moves the offset by as much in the pass that lays it out, under a finger and through a fling too; see Following the latest message)
- Heights kept across launches: `Conduit/Services/TranscriptPictureMemory.swift` (height, rememberHeight, with the picture sizes), forgotten in `Conduit/Services/AppState.swift` (wipeOfflineChatCache, deleteSavedChats)
- Built from Markdown: `Conduit/Views/Components/MarkdownText.swift` (htmlPreview, math and mermaid blocks)
- Tests: `ConduitTests/TranscriptScrollerTests.swift` (Rows changing height), `ConduitTests/TranscriptLayoutTests.swift` (testARowChangingHeightMovesTheRowsUnderItInTheSamePass), `ConduitTests/TranscriptInlineImageTests.swift`, `ConduitTests/MarkupBlockTests.swift`, `ConduitTests/MarkdownLargeDocumentTests+HTMLPreview.swift`

**Rulings**
- A card holds one height from its first frame until its page has measured itself: the height it measured on this phone before (kept with the picture sizes; a preview by its file on the connected Hermes, a diagram or formula by kind, text size and source), else a placeholder (280 pt for a preview, 180 for a diagram, 56 for a formula). Loading the file, the page drawing and a redraw (theme, text size, Try again) all happen inside that room (2026-10-25, #1270, #1238).
- A card takes the height its page measured as soon as it reports, scrolling or not. In a chat the reader's row (the first starting on screen) stays put in the layout pass that lands it, a finger keeping its drag and a fling its momentum: a card above it grows up out of view, one on screen grows down. In the background, where the scroller leaves the offset alone, what grows meanwhile moves under the reader, and their row is put back where it was when the app is back (2026-10-25, #1270, #1238, under which a card waited for the reader's scrolling to rest; taken at once since the transcript rewrite gave every row a frame of its own, 2026-10-31, #1577; Eric delegated the chat scroll's design to Claude, 2026-09-28, and approved the transcript rewrite's design, 2026-10-30).
- Outside a transcript (job sheets) a card takes its height as soon as its page reports too, and so does a picture (see Pictures in messages), but nothing there keeps the reader's row. The saved copy's rows are the chat's own, drawn by its transcript, so their cards take their heights as a chat's do (2026-10-30, #1550), and so are a group room's (2026-10-31, #1590).
- A row's height is its own cell's measurement, so a growth is the row's own change: a reply streaming in below the reader never passes for a card above them. The rows above the reader's row that change height in a pass move the offset by exactly their change, in that pass. When rows below the reader shrink or go so far that the end is above where their row would put them, they're back at the latest message, following it, since nothing under them is left to stay on (a bar shrinking under them leaves them browsing at the new end instead; see Following the latest message). No growth waits, so a drag or a jump has none to drop (2026-10-31, #1577, replacing #1270's owed shifts, which the stack's separate content-size and frame reports needed; Eric delegated the chat scroll's design to Claude, 2026-09-28, and approved the transcript rewrite's design, 2026-10-30).
- A page that fails gives its place the same way, at once: the file card (a preview whose file can't be read or drawn) or "Couldn't draw" (a diagram or formula), the reader's row kept by what its layout took. A preview showing its file card keeps it while the file is read again, and the card comes back the same way once it reads; a surface with no way to read the file shows the file card from the first frame (2026-10-26, #1270; at once since 2026-10-31, #1577, under the transcript rewrite's design, which Eric approved 2026-10-30).

**Open gaps**
- A card never measured on this phone still grows once, as its page reports; the first scroll up through a chat from another device grows its cards one by one as they draw, the reader's row kept.
- On a cold launch, a card laid out before the kept heights have loaded (read off the main thread as the app opens) holds its placeholder and grows once, like one never measured. Taking the kept height later would still be a growth, so only a read on the main thread before the first frame would save it.
- A kept height is for the width and text size it was measured at: an iPad whose chat column changed width, or a formula after a text size change, takes the kept height and then its new one, like any growth.
- Past 2,000 remembered heights the memo starts again (no LRU), so cards grow once more until each is measured again; the picture sizes have the same limit at 4,000 (see Pictures in messages).
- Job sheets aren't on a transcript, so their cards grow where they are, and above a reader scrolled back move what they read.
- Group rooms show no HTML previews (no gateway data URL; the resolver they have since #1524 reads Desktop cards only).

**Checked:** 2026-10-31, #1590 (group rooms draw on the transcript, so their diagrams and formulas take their heights with the reader's row kept; Rulings, gaps); 2026-10-31, #1577 (chats draw on the transcript's collection view: a card or picture takes its height at once, scrolling or not, and TranscriptScroller keeps the reader's row; the wait for a rest, the owed shifts and the closing chat's waiting cards give way to that one rule, under the chat scroll's design being Claude's; the rulings #1566 departed from rewritten, and its Open gaps line gone; Code, Rulings, Tests, gaps); 2026-10-31, #1566 (TranscriptScroller's one rule for rows growing above the reader, not called yet; cards take their heights as before; Code, and the rulings it departs from in Open gaps); 2026-10-30, #1550 (the saved copy is drawn by the chat's engine, so its cards take their heights as a chat's); 2026-10-30, #1524 (the `::preview` grammar moved to TranscriptDirectives.swift, shared with Desktop cards; group rooms still show no previews); 2026-10-26, #1281 (wipeOfflineChatCache also forgets Predictive's state); at #1270.

## Cards made for Hermes Desktop

A Hermes Desktop plugin with a client half has the agent write a directive
only Desktop draws, such as hermes-rich-ui's `::richui{id="…"}` from its
`rich_present` tool. Conduit doesn't rebuild those renderers: it shows a card
in the directive's place that says what was there and where it opens, and
nothing that reads a reply says the directive out.

**Siblings:** chats, project chats, Bot Chat, group rooms, the saved-chat
copy and call job sheets (every Markdown surface, with or without the
connected Hermes) · Read Aloud, Classic voice's spoken reply and Local Live's
split · live read-backs and a Hermes call's result · what live models are
handed, on the phone and the Watch · chat list and bot list previews and
quote chips · the
notifier's push text and the README line that describes it · `::preview`
(the same grammar, see Cards drawn in web pages)

**Code**
- The grammar: `Conduit/Views/Components/TranscriptDirectives.swift` (segments, rewriting, naming, DesktopCardDirective; also built into the Watch app, `project.yml`)
- The card, its details sheet and the read of hermes-rich-ui's card: `Conduit/Views/Components/DesktopCardBlock.swift` (DesktopCardBlock, DesktopCardSheet, DesktopCardContents, DesktopCardContent, PluginRead, TranscriptDirectives.readable), through `Conduit/Views/Components/GatewayMediaDataURLResolver.swift` (connectedDashboardBridge, pluginRead)
- Built from Markdown: `Conduit/Views/Components/MarkdownText.swift` (desktopCard block, directiveSegments, holdsDirective), in group rooms with the connected Hermes' resolver, `Conduit/Views/GroupChatView.swift`
- Spoken: `Conduit/Voice/MessageReadAloudController.swift` (toggle), `Conduit/Voice/VoiceReadBack.swift` (plainSpeech), `Conduit/Voice/SpokenMediaTagFilter.swift` (Classic, Read Aloud's Now Playing, Local Live)
- Live models: `Conduit/Views/Components/GatewayMediaTags.swift` (namingFiles)
- Previews and quote chips: `Conduit/Services/PreviewText.swift` (strip), `Conduit/Views/Components/ChatQuote.swift` (excerpt)
- Push text: `notifier/events.py` (media_free, _desktop_free), described in `notifier/README.md` (what notifications show)
- Tests: `ConduitTests/MarkdownLargeDocumentTests+DesktopCard.swift` (the grammar, the read cache with its clock and fetch passed in), `ConduitTests/GeminiLiveVoiceTests.swift` (testSpokenMediaTagFilterGivesTheSameSpeechHoweverTheReplyIsSplit), `notifier/tests/test_events.py` (test_no_push_shows_a_desktop_directive)

**Rulings**
- A card's line, and a preview's where previews draw, leaves a list (the list carries on after it), and a list or heading marker before it on its line goes with the directive; a directive in a table cell is table text, as a preview's is. A directive still being written while the reply streams shows as text until its closing brace, as a preview does.
- Never hidden without a trace: every directive Conduit can't draw becomes a visible card naming its plugin, and a tap shows the directive as written. Maintainer's ruling (2026-10-30, #1522).
- Conduit doesn't draw a plugin's components (Table, Chart, Metric…) as its own cards: that would be the plugin's Desktop half rebuilt, kept in step with a plugin we don't control. Agents that want cards in both apps use `conduit_show` (2026-10-30, issue #1522).
- hermes-rich-ui's card shows its own plain-text fallback, `meta.title` and `meta.summary`, from `GET /api/plugins/hermes-rich-ui/cards/<id>` on the connected Hermes, only for a well-formed id (`ru-` and 12 hex). Without it (plugin not installed, card gone, no network, no connected Hermes as in the saved copy) the card says "Card for Hermes Desktop" and to open the chat there. A read is kept for the launch; a failed one is tried again after five minutes, by a card on screen too, waiting only for what's left of them, and one shown before Hermes connected or while its page loads asks again within seconds (nothing is kept for it).
- The card holds one title line and two summary lines from its first frame, so it never changes height as its text arrives; the whole summary is in the details sheet. VoiceOver hears that a tap shows the full summary and the line Hermes wrote.
- A directive is one at a word's start, `::name{…}` holding only `key="value"` attributes, at least one: prose, code spans and CSS (`::selection{color:red}`) stay text. A quoted directive is an example and a table header cell is table text, as for previews. Desktop cards show on every Markdown surface; previews still need the connected Hermes.
- Read Aloud and voices say "(There's a card here for Hermes Desktop.)" and leave a preview out, as Read Aloud already did; live models are told "(a card in the chat made for Hermes Desktop, from <plugin>)" and a preview as its file; previews and quote chips read "Card for Hermes Desktop" and a preview as its file; a push reads "🗂 <plugin> card" and a preview as its file, named as a MEDIA tag's (notifier 0.120.4). Lines in a fenced code block and directives in a code span stay as written everywhere.

**Open gaps**
- The on-screen retry loop has no unit test: it lives in the view's task (the read cache and the wait it sleeps for are tested).
- Two rows showing the same card while it is first read each ask for it.

**Checked:** 2026-10-30, #1524.

## Self-improvement updates

The "💾 Self-improvement review" rows Hermes adds to a chat after it saves a
memory or a skill, and the Chat setting that shows or hides them
(`display.memory_notifications`: Use Hermes default, Always show, Never show).

**Siblings:** the Chat settings row and its caption · the review row in the
chat, live and in the offline copy · chats, project chats, Bot Chat and group
rooms (all the dashboard's chats) · Hermes' messaging platforms · the
notifier's live read of the setting for chats already open

**Code**
- Setting: `Conduit/Views/AuxiliaryViews.swift` (ChatSettingsDetail fields, `display.memory_notifications`), `Conduit/Models/Models.swift` (ProfileDisplayPreferences.showReviews), `Conduit/Services/AppState.swift` (loadProfileDisplayPreferences, setProfileSetting)
- Row: `Conduit/Services/StreamEventParser.swift` (`review.summary`), `Conduit/Services/HermesClient.swift` (reviewActivity), `Conduit/Services/AppState.swift` (the review cache, mergeCachedReviews, placingReviews, replacingSavedReviews after Load earlier), `Conduit/Views/ChatView.swift` (SELF-IMPROVEMENT REVIEW, ReviewSummaryCard, ReviewRunCard, and ModelChangeSummaryCard and CardHeaderCaption, which share its layout), `Conduit/Views/TranscriptModel.swift` (rows, which leaves out a review that draws nothing), `Conduit/Views/ChatActivityRows.swift` (ChatMessageScrollTarget.drawsRow, drawsReviewCard, ChatReviewRun, ChatReviewPlacement), `Conduit/Services/ChatScrollState.swift` (placeReviews, restorationAnchorID), `Conduit/Services/TranscriptScroller.swift` (a saved place on a folded review restores to its run, through restorationAnchorID), `Conduit/Views/ChatRowDisclosure.swift` (a run's open choice); the offline copy's reviews are the chat's own rows while they stand in
- Tests: `ConduitTests/AppStateChatResumeTests.swift` (testReviewRowsFollowTheSelfImprovementSetting, testConsecutiveReviewsFoldIntoOneRun, testSavedReviewsGoAmongHermesRowsByTime)
- Notifier: `notifier/review_notices.py`, `notifier/tests/test_review_notices.py`

**Rulings**
- A changed setting reaches chats already open at their next review, with no restart: the dashboard reads it only when it builds a chat's agent, so the plugin reads it again from the chat's profile before each review. Hermes' messaging platforms need nothing, its gateway reads it every turn (2026-10-25, notifier #373, #1260).
- Never show hides the rows a chat already has too, live and in the offline copy (from the setting last read for that profile, kept on the phone, until the dashboard answers; Settings then reads Never show), without deleting them: they come back when the setting does. Anything but "off" (or a YAML false) shows them, as Hermes reads it (2026-10-25, #1260; Eric's rule to close gaps in the same change).
- On the review row, as on the Model updated card beside it, the card's caption and its time share the top row, the time on the right on one line (a long caption wraps beside it), and the summary runs the card's full width below, never in a column beside the time; at the accessibility text sizes the time goes under the caption (2026-10-29, #1507, issue #1440).
- A review the phone saved goes back among Hermes' rows by its time when the chat loads, before the first row timed after it, and never moves Hermes' own rows; a row with no time doesn't decide its place. Load earlier places them again among the older rows it adds (2026-10-30, #1551, issue #1549).
- Two or more reviews in a row fold into one line, "N self-improvement reviews" with the last one's time, closed every time the chat opens; a tap opens it to every card as before, and the choice lasts while the chat stays open, like a run of steps. Any other row ends the run, so an approval, a question or an error is never folded into it; a lone review keeps its own card. Live and in the offline copy, every chat kind. No setting of its own: Never show still hides them all (2026-10-30, #1519, issue #1518).

**Open gaps**
- A saved review's place uses the phone's clock and Hermes' rows the host's (Hermes' review event carries no time), so a host clock that is off by more than the time between a review and the next row puts the review on the wrong side of that row when the chat reloads. Reviews are stamped to the millisecond, so a row from the same second doesn't (#1551).
- An open run of reviews keeps its choice by its first review, so loading older history that holds reviews right above it closes it again; runs of steps do the same.

**Checked:** 2026-10-31, #1577 (a saved place on a folded review restores through TranscriptScroller; Code); 2026-10-31, #1565 (which reviews draw is decided in TranscriptModel; Code); 2026-10-31, #1552 (its settings open on their kept answer; what they save is unchanged); 2026-10-30, #1551 (saved reviews placed by time, not after the newest message, #1549); 2026-10-30, #1550 (the offline copy's reviews are drawn and folded by the chat's own rows); 2026-10-30, #1519 (runs of reviews fold into one line, #1518); 2026-10-29, #1507 (caption and time on the row's top line, summary full width below, #1440); 2026-10-26, #1282 (display settings kept on the phone, so the offline copy follows Never show from launch); 2026-10-25, #1260.

## Profile glow color

The backdrop's warm glow takes a profile's color: the one picked for it in
the Profiles sheet, else the main color of its photo, else its bot's color in
Hermes, else the gold accent.

**Siblings:** the tab roots and the iPad chat placeholder (the profile in
use) · the open chat (chats, project chats, Bot Chat: the chat's own agent)
and its working line · sheets over the open chat (Model, Context) · group
rooms (the profile in use) · Settings and its pages · the Profiles and All
profiles sheets · the Live Activity's color · Settings captions and
model-facing text (none describe the glow)

**Code**
- Colors: `Conduit/Services/ProfileGlowColors.swift`, `Conduit/Services/AppState+V2Shell.swift` (profileGlowTint), `Conduit/Services/AppState.swift` (profileGlowColors, setProfileGlowColor, conversationIdentityProfile), `Conduit/Services/ProfileAppearanceStore.swift` (picks)
- Backdrop: `Conduit/Theme.swift` (ConduitBackdrop), `Conduit/Views/V2/V2TopBar.swift` (V2Backdrop, glowProfile)
- Open chat: `Conduit/Views/V2/V2ConversationScreen.swift`, `Conduit/Views/ChatRowState.swift` (agentGlowTint), `Conduit/Views/ModelPickerView.swift`, `Conduit/Views/AuxiliaryViews.swift` (ContextSheet, SettingsBackdrop)
- Elsewhere: `Conduit/Views/V2/V2SettingsTab.swift`, `Conduit/Views/ProfilePickerSheet.swift`, `Conduit/Views/V2/V2AllProfilesSheet.swift`
- Tests: `ConduitTests/ProfileGlowColorTests.swift`, `ConduitTests/BotModeTests.swift` (conversationIdentityProfile, the bot's glow)

**Rulings**
- A Bot Chat glows in its bot's color: its backdrop, the Model and Context sheets over it, its working line and its Live Activity; the Bots list and every other root keep the profile in use (2026-10-25, Eric's report, #1263).
- Sheets reached from Settings or a page take the glow as an environment value (`settingsGlowTint`), not from AppState, so a sheet built on them needs nothing injected (#638).

**Open gaps**
- The drawer shell (Appearance, V2 off) draws every chat on the gold backdrop, a Bot Chat included, though the Model and Context sheets over it take the chat's glow.
- The chat's other sheets (gateway diagnostics, workspace browser, delegate agents, pinned replies) never took a profile glow and stay gold.

**Checked:** 2026-10-28, #1413.

## Profile names

What Conduit calls a profile, and where it is renamed. A bot is a Hermes
profile, so its name in Bots and its name everywhere else are one name.

**Siblings:** the Profiles sheet's Edit menu (Rename, Choose Photo, Remove
Photo) · Settings > Edit profile (the profile in use) · Edit Bot's name
· Hermes Desktop's bot editor (the same title) · every place Conduit names a
profile through `profileDisplayName` (sidebar, profile switcher and chips,
All profiles, chat placeholders, call screens, voice settings, widgets) ·
Siri and Shortcuts' profile picker (`conduit.knownProfileNames.v1`) ·
spoken "for <name>, …" jobs on the phone and the Watch (`voiceJobProfileTarget`, `watchJobProfileNames`) ·
the Bots list and Bot Chats, rooms, the widget and Artifacts (`displayLabel`; the main bot's carries its Conduit name, `conduitName`; a rename replaces the label an open Bot Chat captured) · pushes and calls from Hermes,
named by the notifier's `bot_name` in the same order, the main bot's by its Conduit name on the phone (`NotificationCopy.named`, from `NotificationSharedSettings.mainProfileNames`) · the Watch's caller
name (`mainProfileNamesByDashboard`) · the text that describes them (the
rename sheet's message, the Profiles row caption in Settings, README.md's
profiles line)

**Code**
- Names: `Conduit/Services/AppState.swift` (profileDisplayName, adoptProfileBotTitles, adoptProfileHermesNames, renameProfile, saveDefaultProfileName, updateBot), `Conduit/Services/ProfileAppearanceStore.swift` (the main profile's name, device names, and each dashboard's remembered titles and display names)
- Profiles sheet: `Conduit/Views/ProfilePickerSheet.swift` (ProfilePickerRow's editMenu and rename alert)
- Settings: `Conduit/Views/AuxiliaryViews.swift` (ProfileSettingsDetail: every profile's name)
- Bots: `Conduit/Services/BotModeModels.swift` (BotProfile.displayLabel, conduitName), `Conduit/Services/AppState.swift` (stampMainBotConduitName), `Conduit/Views/BotEditorSheet.swift`
- Spoken jobs: `Conduit/Services/AppState.swift` (voiceJobProfileTarget, watchJobProfileNames: a profile is matched by the name Conduit shows too, and a bot by the kept roster's names until Hermes answers)
- Siri and Shortcuts: `Conduit/Intents/StartVoiceConversationIntent.swift` (ConduitProfileEntityQuery), fed by AppState's persistSiriProfileNames
- Pushes: `notifier/session_titles.py` (bot_name, _bot_name), `Shared/Notifications/NotificationCopy.swift` (named), `ConduitNotificationService/NotificationService.swift`, `Shared/NotificationE2E.swift` (NotificationSharedSettings.mainProfileNames, activeDashboardID), `Conduit/Services/AppState+HermesCalls.swift` (shareMainProfileNamesWithNotifications)
- Bot Chat labels: `Conduit/Services/AppState.swift` (botConversationTitle, renameCapturedBotChatLabels), `Conduit/Services/AppState+Widgets.swift` (publishWidgetSnapshot)
- Tests: `ConduitTests/BotModeTests.swift` (testABotTitleNamesItsProfileEverywhere, testAnUnnamedMainBotIsHermes, testADeviceNameNamesAProfileOnlyWithoutBotLooks), `ConduitTests/NotificationCopyTests.swift` (testTheMainBotGoesByItsConduitName), `ConduitTests/ProfileDiscoveryTests.swift` (display names, device names)

**Rulings**
- A profile goes by its bot title (`ui_meta['hermes-bots'].title`), else its Hermes `display_name`, else its id, as on Desktop and in its pushes. A listing that only knows `display_name` (`/api/profiles`) never undoes a title (Eric 2026-10-28, #1413, issue #1409).
- The main profile goes by its Conduit name, kept on the device per dashboard, and by its bot's name only while it has none (#1257). Renaming it on the Profiles sheet or in Settings > Edit profile sets that name; renaming the main bot in Edit Bot sets it too, so the rename shows. A rename on the card or in Settings doesn't reach the main bot's title, so Desktop keeps its (2026-10-28, #1413).
- The main bot goes by its Conduit name in Bot Mode too: Bots, Bot Chats, rooms, the widget, Artifacts and its pushes, "Hermes" while nobody named it, not "Default". The notifier names an unnamed main bot "Hermes"; the Notification Service Extension swaps in a name given on the phone, renaming a chat title that is only the bot's name (Eric 2026-10-28, #1457, notifier #446; replaces "Bots keep theirs" from #1413).
- Renaming any other profile, on its card or in Settings > Edit profile, writes its bot title the way Edit Bot does (compare-and-swap on ui_meta, retried once on a conflict), so Bots and Desktop show it, and its id, chats and settings stay. An empty name goes back to Hermes' name (2026-10-28, #1413).
- A profile with neither title nor display name (or one that is only its id) goes by its id capitalized everywhere, Bots, Bot Chats, rooms, the widget, Artifacts and its pushes included (`displayLabel`, the notifier's `_bot_name`) (Eric 2026-10-28, #1448), except the main profile, which is "Hermes" (#1457).
- Titles and display names are remembered per saved dashboard, so one server's names never label another's profiles (2026-10-28, #1413).
- Every profile is renamed from its Profiles card, Bot Mode or not: people who never open Bots still need it (Eric 2026-10-28, #1413).
- A spoken "for <name>, …" job, on the phone or the Watch, reaches a bot by the names of the roster kept from Hermes' last answer until it answers again, so a call made right after launch still finds it (2026-10-31, #1568).
- A gateway without bot looks (`botModePhase == .gatewayUnsupported`) has nowhere to keep another profile's name, so the name stays on the device per dashboard, as photos there do, and comes first until the roster says the gateway keeps bot looks (at launch and offline too); from then its title and display name name the profile, and a roster that answers drops the device names, so they don't come back offline (2026-10-28, #1413).

**Open gaps**
- A pairing without notification keys gets the relay's plain copy, which the extension delivers as written, so its pushes name the main bot by its bot's name or "Hermes", not a name given only on the phone (#1457: the relay never sees that name).
- A push carries no Bot Chat marker, so a regular main-profile chat titled exactly the bot's name, "Hermes" or "Default" is renamed in its push as the Bot Chat is (#1457). A marker from the notifier would let the extension rename only Bot Chats.
- A plugin older than #1257 sends no `profile_name`, so with a phone name its titled main bot's Bot Chat push keeps the bot's title over the phone name as subtitle (#1457).

**Checked:** 2026-10-31, #1568 (a spoken job and a Watch call's names reach a bot from the kept roster until Hermes answers); 2026-10-28, #1457 (the main bot goes by its Conduit name in Bot Mode and its pushes); 2026-10-28, #1448 (an unnamed profile goes by its id capitalized in Bots, rooms, the widget, Artifacts and pushes); 2026-10-28, #1413.

## Settings rows a toggle reveals

Rows, captions and fields that appear under a Settings switch when it turns
on, and go when it turns off. They slide in and out on the app's motion
curve rather than popping in one frame.

**Siblings:** Calls from Hermes · Location (talking and background layers) ·
Health (detailed readings per category, and sharing turned on from its
consent sheet) · Phone (Reminders read only, attendee email addresses, and
sharing turned on from its consent sheet) · Voice: Enable voice on this device (the setup
checklist and tests), Hands-free on your speech server (its speech server
section), the wake phrase · Live call style's greeting · Sync across devices ·
Cloudflare Access's service token · a connector's Turned on (Capabilities) ·
Predictive (how many, the pause, the first follow-up check) ·
text that describes it (none: no caption or doc mentions the motion) ·
not needed: the live voice modes' Use switches, which Voice never shows (its
mode picker shows a mode's section only once that mode is picked)

**Code**
- Motion: `Conduit/Theme.swift` (ConduitMotion.ease)
- Enable voice on this device shows the saved switch, not the live state that reads off while reconnecting: `Conduit/Services/AppState.swift` (activeProfileVoiceSwitch), `Conduit/Views/AuxiliaryViews.swift` (VoiceSettingsRoute)
- A switch that sets state at once animates its own setter: `Conduit/Views/HermesCallSettingsViews.swift` (change), `Conduit/Views/HealthSettingsViews.swift` (categoryBinding), `Conduit/Views/PhoneSettingsViews.swift` (binding), `Conduit/Views/VoiceSettingsView.swift` (setVoice, localHandsFreeSection, WakePhraseSettingsSection.save), `Conduit/Views/LiveVoiceStyleViews.swift`, `Conduit/Views/AuxiliaryViews.swift` (GatewaySettingsDetail, Cloudflare Access)
- A switch whose state lands later (a consent sheet, the host's answer) animates on the value, page-wide: `Conduit/Views/LocationSettingsViews.swift` (LocationSettingsPage), `Conduit/Views/SyncedPreferencesViews.swift` (also the switch easing back after a failed host check), `Conduit/Views/Capabilities/CapabilityConnectorsTab.swift` (ConnectorDetailPage), `Conduit/Views/PredictiveSettingsView.swift` (PredictiveSettingsPage), `Conduit/Views/HealthSettingsViews.swift` and `Conduit/Views/PhoneSettingsViews.swift` (sharing turned on from the consent sheet)

**Rulings**
- Revealed rows animate with `ConduitMotion.ease`, which is the settle fade under Reduce Motion. Use withAnimation in the setter, or `.animation(_:value:)` on the whole page, never on one section alone: an animation scoped to a section grows its card while the sections below jump (proposed in #1246, 2026-10-25).

**Open gaps**
- A row revealed by something other than a switch (a picker or a host answer) isn't covered here.

**Checked:** 2026-10-30, #1544: Calls from Hermes' "Wait while I'm at a screen" shows under "Call about approvals and questions" while it's on, through the same animated `change`. 2026-10-28, #1441: Enable voice on this device shows the saved switch while Conduit reconnects, so its rows stay. Earlier 2026-10-26, at #1281 (carrying #1242): Predictive's switches reveal their pickers on the page-wide ease. Earlier 2026-10-25, at #1274: Health and Phone's consent-sheet turn-on animate; the live voice Use switches are not needed (never shown). Earlier at #1246 (fork CI #92): Eric's review added Enable voice and Hands-free; a connector's Turned on and Sync's failed check added from the bot reviews.

## Predictions

Settings > Chat > Predictive: Hermes guesses the user's next move in the
open chat. Suggested replies after a reply, guesses for a paused draft, and
a turn Hermes takes on its own while the chat sits on screen.

**Siblings:** chats, project chats and Bot Chat (one row above the composer) ·
group rooms · the Apple Watch · voice modes and CarPlay · Hermes Desktop and
the TUI on the same chat · the reply push while the chat is on screen · step
summaries' /btw · the composer's draft and Send · the plugin's `/predict`
route, its README section and the CHANGELOG · the Predictive page's captions

**Code**
- Model and store: `Conduit/Services/Predictive.swift` (Predictive, PredictiveStore, PredictiveComposerRequest, PredictiveFollowUpState)
- Asking and the follow-up clock: `Conduit/Services/AppState+Predictive.swift`, fed by `Conduit/Services/AppState+ChatOnScreen.swift` (updateChatOnScreen) and the settled, failed or interrupted turn in `Conduit/Services/AppState.swift`; cleared when the open dashboard signs out, is removed or connects to a different server by forgetPredictiveState in `Conduit/Services/AppState.swift` (wipeOfflineChatCache, prepareChatResumeForConnection; predictiveGeneration drops answers asked before it), and a follow-up's wait by every connect, same server included (prepareChatResumeForConnection, reconnectForRetry, stopWaitingForPredictiveFollowUp); another client's message (noteUserMessageElsewhere) is noted for the wait
- The hidden turn: `Conduit/Services/HermesClient.swift` (sendPrompt, `hidden`; a gateway refusing `display_kind` is remembered and gets no more follow-ups)
- Row and tag: `Conduit/Views/Components/PredictiveRow.swift`, placed in `Conduit/Views/ChatView.swift` (bottomBar, MessageBubble), its reasons in `Conduit/Views/ChatRowState.swift`
- Composer: `Conduit/Views/Components/ComposerBar.swift` (applyPredictiveRequest, predictiveDraftChanged), `Conduit/Views/Components/ComposerUpdates.swift`
- Settings: `Conduit/Views/PredictiveSettingsView.swift`, listed in `Conduit/Views/AuxiliaryViews.swift` (ChatSettingsDetail)
- Notifier, from plugin 0.80: `notifier/predict.py` and `notifier/dashboard/api/chats.py` (`/predict`), tested in `notifier/tests/test_predict.py`; `notifier/README.md`, `notifier/CHANGELOG.md`
- Tests: `ConduitTests/ChatTypographyTests+Predictive.swift`, the reconnect in `ConduitTests/AppStateChatResumeTests.swift`

**Rulings**
- All three are off by default, device-only, and need the plugin's `predict` capability (0.80+); without it the page says so and nothing is asked (2026-10-25, Michel, #1242).
- Guesses come from the plugin's `POST /predict`, a no-tools fork of the live chat that saves nothing, answered only to the asking device, never from `prompt.btw`, whose answers reach every client and show in Desktop (2026-10-25, Michel, #1242).
- One row of chips, best first, with no percentages: tap sends, long-press edits; taps in its first 0.4 s are ignored. Continuations are phrase chips, not ghost text (2026-10-25, Michel, #1242; "capsules" became "chips" (Michel, #1431; accepted by Eric 2026-10-28, #1455) once reply chips wrap, see below).
- A chip that sends shows its whole message, never cut short with an ellipsis: past about 250 pt it wraps onto more lines, and the row grows with it, so reply chips are rounded rectangles rather than capsules. A guess over 200 characters is dropped, never shortened. Continuations, which only add to the draft, stay one line (Michel, #1431; accepted by Eric 2026-10-28, #1455).
- Suggested replies are asked once per reply, when it settles on screen or its chat is opened. A draft is asked about after the chosen pause, once per draft, and its answer counts for 4 s; typing folds the row to a ✦ button (2026-10-25, #1242).
- Hermes follows up only while the chat is on screen, settled and unwritten: first check after the chosen wait, then when Hermes asks (held to 30 s–15 min), at most 4 checks per reply, and at most one hidden turn per message the user sends. Conduit measures every duration and sends it (2026-10-25, Michel, #1242).
- On screen means not covered by the sidebar or a room, with Conduit in front. A paused draft's question and a follow-up's hidden turn check it again just before they are sent (2026-10-26, #1281).
- A follow-up's reply holds the chat on screen for pushes even when nobody touched the phone in the last two minutes (2026-10-25, #1242).
- A guess never notifies: `/predict`'s fork runs under the chat's session id, and the plugin keeps its turn from sending a push or moving the Live Activity on a Hermes that runs plugin hooks for forks (2026-10-29, Michel, #1495 carrying #1489, notifier #464 carrying #462; see Notifications).
- Hide for this chat also stops a follow-up check already asked, and leaving the chat (another chat, the sidebar, a room, Conduit in the background) drops a follow-up's hold and its tag. A tapped guess goes only into the chat it was offered in (2026-10-25, #1242).
- A turn that ends in a system notice, fails or is interrupted tags nothing and doesn't restart the reply's idle time, and a notice merged into the last row is no reply to guess at; a follow-up that never reached Hermes doesn't spend the user's message and is checked again (within the 4 checks), unless the gateway takes no hidden prompts. A follow-up that leaves no reply of its own asks for the reply's guesses again. A switch turned off takes its chips with it (2026-10-26, Eric, #1242).
- Signing out of or removing the open dashboard, or its connection reaching a different server, forgets every guess, the draft they read, hidden follow-ups and checks still waiting, and drops answers still on their way; Delete Saved Chats leaves them, as it leaves the chat in use. A follow-up Hermes queued keeps its tag and hold, since it runs as its own turn, until a reconnect (below), and the turn it waited behind (another client's) gets neither, even when that turn ends before Hermes says the prompt was queued; only one steered or redirected into a running turn loses them (2026-10-26, #1281). When Hermes queued the hidden prompt, a reply to a message someone sent before it (another client's, queued ahead) isn't tagged either, and the chat stays held while Conduit waits: it skips up to 3 such replies, and a fourth ends the wait untagged; a message sent after the hidden prompt runs after it, so once its row is read the next reply is still the follow-up's. A message another client sends during the wait counts even when it's read in before the turn the follow-up waited behind ends, on a gateway that announces `user.message`; without it, only rows read in after that turn count. A turn of a message queued ahead that fails, is interrupted or ends in a notice counts as one of the 3. A reply that ends while a message another client sent hasn't been read into the chat yet, or after the row the follow-up was sent after has left the chat (a reload), isn't tagged and ends the wait, since whose reply it is can't be told. No second follow-up is checked for in a chat while one waits there. A reconnect ends the wait, queued or not, and with it the tag; the hold is no longer renewed and lapses at the next renewal unless someone is using the chat, since the turn may have ended unseen (2026-10-26, Eric, #1290).

**Open gaps**
- Group rooms get no row: with several people and bots, "your next message" is unclear.
- The Apple Watch has no suggested replies yet, where typing is hardest.
- Voice modes and CarPlay get none, by design: calls take turns their own way, and chips while driving distract. With Voice open, no draft is asked about and no follow-up is sent.
- Hide for this chat lasts until Conduit is relaunched; the chat then gets predictions again.
- "Hermes followed up" is kept in memory for this run: after a relaunch or a new copy of the chat from the host, the reply shows without it.
- Step summaries still use `prompt.btw`, so Desktop keeps showing their notes; moving them to `/predict` is left for its own change.
- The fast model is the profile's `auxiliary.conduit_predict` on the host; Conduit can't set it.
- Which reply is Hermes' own, when other clients' messages are queued around the hidden prompt, is inferred from row timestamps (the phone's clock at sending against the host's) and `user.message` events. Hermes sends no turn ownership, so a message sent within clock skew of the prompt, one read into the chat before its event arrives, another device's message repeating the text this iPhone sent last before that message has its row id (taken for this iPhone's own), a message whose event arrives only after the hidden prompt while its turn is the one the prompt queued behind (counted twice), or a message queued ahead whose row is read in before the turn the prompt queued behind ends and whose event came before the prompt (not counted), can still put the tag on the wrong reply; and this iPhone's own message announced back after a newer one of its own is taken for someone else's, which drops the tag. The event's origin isn't read for this (#1290).

**Checked:** 2026-10-30, #1527 (a guess sent from the row keeps whatever focus the field had, see Composer focus after a send); 2026-10-29, #1495, carrying #1489 (a guess's fork sends no push, notifier #464); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1455 (carrying #1431; a chip that sends wraps instead of truncating; Rulings); 2026-10-26, #1290 (a follow-up's tag skips replies to other messages); at #1281 (carrying #1242).

## Linked Rooms

Group rooms with agents that belong to other people. Each agent runs on its
owner's Hermes, with its owner's model and keys and its owner's rules for the
room, and the hosts reach each other through the rooms mailbox. It's being
built: the notifier side is on its main, and the app side comes in the
`linked-rooms` branch's PRs, so none of it is in the app on main yet.

**Siblings:** the room screen and Group Info in both shells (members from
other installations, their route status and pictures, your agents' choices for
the room) · New Group Chat with linked people, the invite list and the join
card · Settings > People (host setup, Links, Link with someone, Scan and
Paste) · an invite (`conduit://link/`) opened from another app, a chat or the
Camera · the sign-in Scan Code sheet, which Scan reuses · the Chats list
(rooms hosted by others, and deleting one that ended) · posting in a room
hosted by others through your own Hermes, and who wrote each post (your own
rooms' and copies' messages from linked people) · the notifier's owner
rules for room turns (tools, the framing, the reply scrub, past-chat search),
with their routes and the `hermes conduit-push rooms` commands · the room
memory guard · the room planner and the room driver's wakeups · a member cut
off by its host · disbanding a room (the home's own agents' hidden chats for
it, and the people linked into it told) and a guest's `rooms forget` · the
rooms mailbox (rooms.milim.dev) · Links
between installations (invites, the four words, unlinking), with their routes
and the `hermes conduit-push links` commands · getting a Hermes ready for
rooms (its API server and the tools rooms may use), with its route and
`hermes conduit-push rooms setup` · the room bridge (a member's Hermes
answering a room's requests over its Link, with When asked and its turns a day
held there, and the home's Hermes reaching a member's agent through it) ·
rooms with people you've linked (a draft and its invites, joining with a grant
for each agent, the start in the running room service, Start now, taking a
draft back, fresh grants while it goes on, leaving it, taking an agent out),
with their routes and the rooms commands `invite`, `drafts`, `start`,
`withdraw`, `invites`, `join`, `decline`, `leave` and `remove` · who's who in
a room (the framing names each other agent's owner and the room's host, and
leaves out agents that are out) · rooms of
only your own agents (unchanged, except that disbanding one now deletes its
hidden chats) · past-chat search in every chat (it no longer finds those
rooms) · approvals for your agents in rooms hosted elsewhere, with their
routes and the rooms commands `approvals`, `approve` and `deny` · copies of
rooms hosted elsewhere (the home's pages to everyone with agents in a room, the
copy each keeps on their own Hermes, its routes and `rooms copies`) · your agent
working on a room for you in your private chats (the conduit_room tool), a
room's own private chat and the notes it gets once the room goes quiet · Ask me
first (your agent asking your phone before it shares something personal in a
room, the conduit_ask_owner tool and its prompt in the present store, the
answer reaching its next turn there; the app's panel for it is C5c) · Use my
data's free/busy (your agent saying when you're busy, from the calendar your
phone shares, the conduit_free_busy tool; the app offers Use my data in C6, on
the `linked-rooms` branch only) · asks between linked agents (your agent asking
someone you've linked with whether they're free on a date, or a question, in
your private chats, the conduit_ask_linked tool; the asked side's standing
rules per Link, or its owner on the phone or with `links asks` and `links
answer`; the app's rules on Settings > People and its panel for a Link's ask
are C7) · the invite
push (room.invite, on a phone whose Conduit turns it on) and the reply and
failure pushes your agents' turns in rooms hosted elsewhere don't send · a profile
the dashboard didn't start with (new drafts and the setup take
`?conduit_profile=`, as in "Voice on a profile the dashboard didn't start
with") · text that
describes it: the notifier README's "Rooms with other people's agents", "A
member cut off from a room", "Disbanding a room ends its hidden chats",
"Linking with someone", "Setting this Hermes up for rooms", "Rooms with people
you've linked", "Group rooms between turns", "Your agent works on a room
for you", "Ask me first", "Use my data: free/busy" and "Asks between linked
agents", the conduit_room, conduit_ask_owner, conduit_free_busy and
conduit_ask_linked tools'
descriptions and results, the framing and block
messages models read, Disband's warning, Group Info and the choices page's
captions, Settings captions, the invite's share message

**Code**
- Owner rules: `notifier/room_rules.py` (room_turn, tool_block, framing, scrub, filter_search), `notifier/room_choices.py` (the per-room choices, NEVER), `notifier/__init__.py` (pre_tool_call, pre_llm_call, transform_llm_output, transform_tool_result), `notifier/dashboard/api/linked_rooms.py` (/rooms/choices, /rooms/defaults, capability room-rules), `notifier/cli.py` (rooms show, rooms set), `notifier/README.md` (Rooms with other people's agents)
- Memory guard, planner and wakeups: `notifier/room_memory.py`, `notifier/room_planner.py`, `notifier/room_wakeups.py` (a room's pass that ends doesn't keep every room's pass going), `notifier/README.md` (Group rooms between turns)
- Cut-off members and disband cleanup: `notifier/room_cutoff.py` (MemberCutOff, read before Hermes sets a turn up), `notifier/room_cleanup.py` (the disband guard, which first tells the people linked into a room, the load sweep, forget_room), `notifier/dashboard/api/linked_rooms.py` (DELETE /rooms/sessions, capability room-forget), `notifier/dashboard/api/rooms.py` (both guards, where the dashboard drives rooms), `notifier/cli.py` (rooms forget), `notifier/README.md` (A member cut off from a room, Disbanding a room ends its hidden chats)
- Mailbox: `notifier/mailbox/src/server.mjs`, `notifier/mailbox/README.md` (protocol v1, self-hosting), `notifier/mailbox/deploy/compose.yaml`
- Links: `notifier/room_links.py` (invites, the accept and its confirm, unlinking, the inbox loop, links.json), `notifier/room_identity.py` (an installation's keys and its four words), `notifier/bip39_english.txt`, `notifier/room_envelope.py` (sealed, signed envelopes), `notifier/room_mailbox.py` (the mailbox client, which looks a peer mailbox's name up), `notifier/dashboard/api/linked_rooms.py` (/rooms/identity, /rooms/links, capability room-links), `notifier/cli.py` (links invite, preview, accept, list, remove, cancel), `notifier/README.md` (Linking with someone)
- Host setup: `notifier/room_setup.py` (what a profile needs, the setup and its gateway restart), `notifier/dashboard/api/linked_rooms.py` (/rooms/setup, capability room-setup; `?conduit_profile=` with capability room-dashboard-profiles, and no restart from a plugin host), `notifier/cli.py` (rooms setup), `notifier/README.md` (Setting this Hermes up for rooms)
- Room bridge, a member's side: `notifier/room_bridge.py` (the envelopes' bodies and their checks, a grant's scope, bridge.json), `notifier/room_bridge_member.py` (a member's Hermes answers a home's room requests over its Link: the replay to its own API server, When asked and turns a day as "(pass)" runs, the run's statuses, the 10-minute cap), `notifier/room_links.py` (`Received.age` and `root`), `notifier/room_mailbox.py` (`Delivered.age`, by the mailbox's clock), `notifier/dashboard/api/linked_rooms.py` (starts the bridge before the links loop)
- Room bridge, the home's side: `notifier/room_bridge_home.py` (the loopback server Hermes reaches a member's agent at: each request carried over the Link, status reads answered from the statuses the member sends, a quiet member, a 12-minute turn and an unanswered dispatch read failed, Stop and revoke through an outbox, bridge.json's home section), `notifier/room_bridge.py` (the route table, the run states and the fields Hermes' client reads, `url`, `start` for both sides)
- Rooms over Links: `notifier/room_invites.py` (drafts and invites on both sides, the answers, the rooms loop beside the bridge, rooms.json and its outbox, the join card's choices from the last room with the same people, who's who with each member's status; while a room goes on, the fresh grants every 12 hours, leaving, taking an agent out and the end of a disbanded room, with their envelopes), `notifier/room_join.py` (a join's grants for its places, never approve, the reservation, the catalog from this Hermes' API server, the bridge binding and the choices, and undoing them; `renew`), `notifier/room_start.py` (the start: each agent probed through the bridge, the room made in the running room service the draft names, legacy or canonical, its routes registered live, and the gateway's lock on the CLI's drafts; later a route's fresh grant, `swap`, and a member cut off, `cut_off` and `revoke`), `notifier/room_bridge.py` (`grant_issued_at`), `notifier/room_choices.py` (a room's people, `last_with`), `notifier/room_rules.py` and `notifier/__init__.py` (the framing names other agents' owners and the room's host, and leaves out agents that are out), `notifier/dashboard/api/linked_rooms.py` (/rooms/drafts, /rooms/drafts/start, /rooms/invites, /rooms/invites/answer, /rooms/people, capability room-invites; a new draft's `?conduit_profile=`, capability room-dashboard-profiles; /rooms/leave, /rooms/drafts/remove, capability room-leave; the rooms loop starts with the bridge), `notifier/cli.py` (rooms invite, drafts, start, withdraw, invites, join, decline, leave, remove), `notifier/README.md` (Rooms with people you've linked)
- Copies of rooms hosted elsewhere: `notifier/room_copies.py` (the home's pages, one waiting for its answer at a time; the copy, kept with Hermes' replica store in conduit-rooms/copies.db; what Conduit reads), `notifier/room_invites.py` (room.page and room.copied, the rooms loop's pass), `notifier/dashboard/api/linked_rooms.py` (/rooms/copies, /rooms/copies/log, capability room-copies), `notifier/cli.py` (rooms copies), `notifier/README.md` (Rooms with people you've linked)
- Your agent reads your rooms for you: `notifier/room_reading.py` (the rooms this Hermes hosts and its copies, who said what, pages and the answer's cap), `notifier/room_tool.py` (conduit_room, refused in a room turn, a subagent and a call without a session), `notifier/room_chats.py` (a room's private chat per profile, conduit-room-chats.json; its turns' line; the notes on a quiet or ended room, from the rooms loop through the session host), `notifier/room_invites.py` (the rooms loop's notes pass; people() follows the current invite), `notifier/room_copies.py` (forget's refusals; the copy's note of your agents), `notifier/room_choices.py` (conduit_room never in a room), `notifier/__init__.py` (registers the tool; the room chat's line), `notifier/dashboard/api/linked_rooms.py` (GET/PUT /rooms/chats, capability room-chats), `notifier/dashboard/api/capabilities.py` (room-chats), `notifier/README.md` (Your agent works on a room for you)
- Ask me first: `notifier/room_asks.py` (conduit_ask_owner in toolset conduit_rooms, its refusals and its 30 s wait; the framing's later answers and when they count as heard: begin, replied, ended), `notifier/present_store.py` (a room's ask as a confirm prompt with `room`, feature room-asks, ask_room and its caps and budgets, room_answers, mark_heard, the exchange's own window for room asks, unheard answers kept), `notifier/room_rules.py` (ASK_TOOL through tool_block under Ask me first in any tier, Tool Search kept open for it, the share and tool lines that name it), `notifier/room_setup.py` (conduit_rooms always in the ceiling), `notifier/__init__.py` (registers the tool; the framing's answers, settled on on_session_end; never in a delegated child's turn), `notifier/README.md` (Ask me first)
- Use my data: `notifier/room_free_busy.py` (conduit_free_busy in toolset conduit_rooms, its refusals, the 31-day cap, busy blocks only, the note per share choice), `notifier/room_rules.py` (FREE_BUSY_TOOL, DATA_TOOLS in the data tier, out under Nothing personal, FREE_BUSY_LINES), `notifier/phone_store.py` (busy_blocks), `notifier/__init__.py` (registers the tool), `notifier/dashboard/api/capabilities.py` (room-free-busy), `notifier/cli.py` (rooms set's --tools help), `notifier/README.md` (Use my data: free/busy)
- Asks between linked agents: `notifier/link_asks.py` (ask.ask and ask.answer over a Link, each Link's rules and the profile that answers, the computed free-on answer, held asks and their prompts, budgets, conduit-rooms/asks.json, the loop that sends answers), `notifier/link_ask_tool.py` (conduit_ask_linked in toolset conduit, refused in a room turn and a subagent, its 20 s wait; the framing's later answers, heard as room asks' are), `notifier/present_store.py` (a Link's ask as a confirm prompt with `link`, feature link-asks, ask_link, settle_link, kept out of the private chats' present tools; with a room's asks, within the 40 from elsewhere the phone shows), `notifier/__init__.py` (registers the tool; the framing's answers, settled on on_session_end), `notifier/dashboard/api/link_asks.py` (GET/PUT /links/rules, GET /links/asks), `notifier/dashboard/api/linked_rooms.py` (the asks start with the rooms' handlers), `notifier/dashboard/api/capabilities.py` (link-asks), `notifier/cli.py` (links rules, asks, answer), `notifier/README.md` (Asks between linked agents)
- Posting in rooms hosted elsewhere: `notifier/room_posts.py` (the person's post and list, the home's take and answer, conduit-rooms/posts.db), `notifier/room_invites.py` (room.post and room.posted, GET /rooms/people's posts and you), `notifier/room_copies.py` (pages' posts, the copy's post field, reads that skip a corrupt row), `notifier/room_rules.py` and `notifier/__init__.py` (who wrote the user's lines, in the framing), `notifier/dashboard/api/linked_rooms.py` (/rooms/copies/messages, capability room-posts), `notifier/README.md` (Rooms with people you've linked)
- Approvals from rooms hosted elsewhere: `notifier/room_approvals.py` (each approval your agents' turns there wait for, read with the run's own grant; the answer, once or deny, through this Hermes' API server with a grant for that answer alone; the session its notification names), `notifier/dashboard/api/linked_rooms.py` (/rooms/approvals, /rooms/approvals/answer, capability room-approvals), `notifier/cli.py` (rooms approvals, approve, deny), `notifier/README.md` (Rooms with people you've linked)
- The invite push and quiet room turns: `notifier/room_invites.py` (notify_invite, Rooms' notify), `notifier/events.py` (sanitize_room), `notifier/e2e.py` (the room sealed, its ids alone when it can't be), `notifier/client.py` (relay_takes), `notifier/relay/src/server.mjs` (validateRoom, genericCopy, shouldDeliver, the gateway's GET /v1/meta, capability room-invites), `notifier/relay/src/store.mjs` (room_invite, off by default), `notifier/__init__.py` (_member_room_turn), `notifier/README.md` (Rooms with people you've linked), `notifier/docs/privacy/index.html` (room invites); tests `notifier/tests/test_delivery.py`, `notifier/tests/test_turn_end_pushes.py`, `notifier/relay/test/server.test.mjs`, `notifier/relay/test/decisions.e2e.test.mjs`
- App, today's rooms (a member from another installation has target kind peer): `Conduit/Services/GroupChatModels.swift` (GroupMember.target, members(namedBy:)), `Conduit/Services/AppState.swift` (activeRoomResponder, groupMemberBot), `Conduit/Views/GroupChatView.swift` (and Disband's warning), `Conduit/Views/V2/V2ConversationScreen.swift` (Disband's warning in V2), `Conduit/Services/HermesClient.swift` (groups.*)
- App, on the `linked-rooms` branch only, so not in backticks: Conduit/Services/RoomChoices.swift (RoomChoices, RoomChoicesClient, canSetRoomChoices), Conduit/Views/GroupRoomInfoView.swift (GroupRoomInfoSheet, RoomAgentChoicesView), ConduitTests/GroupChatModelsTests+LinkedRooms.swift; in the files above, GroupPeerRoute, GroupMemberActivity, responderState, liveMember, rosterBot and GroupRoomDisband (GroupChatModels.swift), roomResponderCache and activeRoomResponderState (AppState.swift), and Group Info in both room menus. Each of the branch's PRs names here the app paths it adds
- Settings > People, on the branch only too: Conduit/Views/PeopleSettingsViews.swift (PeopleSettingsPage, RoomSetupSection, PeopleSettingsText; Link with someone, Scan, Paste), Conduit/Views/RoomLinkSheets.swift (RoomLinkInviteSheet, RoomLinkOpenedSheet, RoomLinkQRCode, RoomLinkSheetText), Conduit/Services/RoomLinks.swift (RoomLinksClient, RoomLinkURL, canLinkRooms, routeRoomLink), Conduit/Services/RoomSetup.swift (RoomSetupClient, canSetUpRooms), ConduitTests/GroupChatModelsTests+People.swift; in files on main, the People row under Hermes in both shells (`Conduit/Views/AuxiliaryViews.swift`), DashboardTicketBridgeError.meaningfulDetail (`Conduit/Services/DashboardTicketBridge.swift`), pendingRoomLink (`Conduit/Services/AppState.swift`), an invite's way in through openURL and onOpenURL (`Conduit/ConduitApp.swift`) to its sheet (`Conduit/Views/RootView.swift`), the scheme's notes (`Conduit/Services/ConduitAppLink.swift`), and CodeScanPurpose, the scanner's words for an invite (`Conduit/Views/Login/DashboardCodeScanner.swift`)
- Tests: `notifier/tests/test_room_rules.py`, `notifier/tests/test_room_choices.py`, `notifier/tests/test_room_memory.py`, `notifier/tests/test_room_cutoff.py`, `notifier/tests/test_room_cleanup.py`, `notifier/tests/test_room_identity.py`, `notifier/tests/test_room_envelope.py`, `notifier/tests/test_room_mailbox.py`, `notifier/tests/test_room_links.py`, `notifier/tests/test_room_wakeups.py`, `notifier/tests/test_room_setup.py`, `notifier/tests/test_room_bridge.py`, `notifier/tests/test_room_bridge_member.py`, `notifier/tests/test_room_bridge_home.py`, `notifier/tests/test_room_invites.py`, `notifier/tests/test_room_join.py`, `notifier/tests/test_room_start.py`, `notifier/tests/test_room_approvals.py`, `notifier/tests/test_room_copies.py`, `notifier/tests/test_room_posts.py`, `notifier/tests/test_room_reading.py`, `notifier/tests/test_room_chats.py`, `notifier/tests/test_room_asks.py`, `notifier/tests/test_room_free_busy.py`, `notifier/tests/test_link_asks.py`, `notifier/tests/test_link_ask_tool.py`, `notifier/tests/roomlink_client.py` (Hermes' own RoomLink client, verbatim from c73cbcc4), `notifier/mailbox/test/server.e2e.test.mjs`

**Rulings**
- The app side stays off main: Linked Rooms PRs target `linked-rooms`, which reaches main only once Eric has seen it all work, like `pulse`. The notifier side is on its main, hidden until Conduit shows it (2026-10-23, Eric).
- Main reaches `linked-rooms` by a merge commit, never a squash, as it reaches `pulse`, so the next merge of main doesn't re-stitch old conflicts (2026-10-26, #1287; Pulse's ruling from #1186).
- Memory stays on in rooms. Instead, past-chat search is off unless chosen, nothing from a room turn is saved to memory, skills or a memory provider, the agent is told who's asking, and what it shares follows its owner's choice for the room. A provider's automatic recall stays on, like MEMORY.md (2026-10-22, Eric; notifier #305).
- Each owner's rules run on their own host, whichever host the room lives on. A room's choices default to Talk only, ask first, no past-chat search, joins in and 40 turns a day. Memory and skill writes, delegation, messaging, scheduled jobs, running code and Conduit's calls and settings are never allowed, the background review's included (2026-10-25, notifier #379).
- The rules hold through Hermes' tool hooks, which see a call only when it carries the room session's id. A tool that calls other tools without it (`execute_code`) is never allowed, and a profile whose tools run outside the hooks (the Codex app-server runtime) can't take part in a room with other people's agents (2026-10-25, notifier #379).
- A room whose store or choices can't be read, or aren't of a shape Hermes or the plugin writes, or a room session Hermes hasn't titled yet, gets no tools that turn; a room's broken choices get Talk only, never the defaults. A session store that can't be read blocks each tool call it can't check, in any chat, until it can be read; a turn on Hermes' room platform still gets the framing and the scrub. A room in no store runs as Hermes alone would (its tools and its search hits), with a warning in the log, and a disbanded room keeps its rules (2026-10-26, notifier #379). So does a turn where the plugin can't find the Hermes home, since blocking there would block every chat, but a past-chat search there fails when it names rooms (2026-10-26, notifier #384).
- The rules follow a room's sessions: a compaction's continuation (Hermes moves the title to it) and a delegated child keep the room, whatever title Hermes gives the child, and the memory guard follows them the same way; a branch is its own conversation; past-chat search checks every hit, whatever source Hermes gives it. Tool Search's bridge works whenever anything is allowed, since Hermes runs the hooks on the tool it reaches, and a `tool_call` the hooks see whole is checked by every tool it names (2026-10-26, notifier #379).
- Rooms of only your own agents get none of the rules: they apply once a room seats a member from another installation (2026-10-25, notifier #379). Disbanding one deletes its hidden chats, as in every room (2026-10-26, Eric; notifier #384).
- A member whose host refuses the room (its grant revoked or run out) fails its turn once, with a reason, and the room goes on without it. It stays out until its link is saved again, with no probe, so renewing a link saves it through Hermes. A member that's only offline is Hermes' to retry (2026-10-26, notifier #384).
- Disbanding a room deletes the home's own agents' hidden chats for it, with their earlier history and their helpers' chats, in every room, rooms of only your own agents too. Agents on other people's Hermes keep theirs, and their owners delete them later with `hermes conduit-push rooms forget` or the route the Chats list calls, which refuses a room still going on that host (2026-10-26, Eric; notifier #384).
- Every link goes through the mailbox, on one LAN too. The shared one is rooms.milim.dev, a service of its own beside push.milim.dev (2026-10-22, Eric).
- An agent runs on its owner's host with its owner's model and keys, so each owner pays for their own (2026-10-22, Eric).
- Links are an installation's, not a profile's: each Hermes home has one identity, whose four words the other person compares, and the links routes take no profile. An invite (a link, or its QR code) is good for one accept within 24 hours. The inviter's Hermes confirms it, and the acceptor's then uses the mailbox that signed confirm names, not the invite's. Unlinking ends a Link at once on that side, and on the other when it next reads its mailbox. A Hermes keeps up to 50 Links and 10 waiting invites, each invite holding a place for its Link (2026-10-26, notifier #390). A peer's mailbox named by a host name is looked up before anything is sent to it, and refused (`bad_url`) when any address it has is on this computer or a private network (2026-10-26, notifier #397).
- Getting a Hermes ready for rooms is one setup, from `hermes conduit-push rooms setup` or the route Settings > People calls, for one profile. It turns on the installation's API server (with a key made on the host that never leaves it, and a named profile's own key), saves the profile's room ceiling exactly (apart from conduit_rooms, which it always keeps: 2026-10-29, notifier #460), with MCP servers and toolsets added later kept out until they're added there, turns approvals that are off to manual, and restarts the gateway only when the API server isn't running. What it can't fix (YOLO mode, a managed install, a profile the host gateway doesn't serve, no free port) stops it before anything is written. A room pins its members' ceilings when it starts, so a changed ceiling stops that agent answering in rooms already started, and changing one the setup saved says so before it saves (2026-10-26, notifier #398). For a profile the dashboard didn't start with, on Hermes 0.22.3 and later, the route takes `?conduit_profile=`; one served in that profile's plugin host saves but doesn't restart the gateway, and says to restart it (2026-10-27, notifier #419).
- A member's Hermes answers a room's requests only over the Link its grant's scope is bound to (bound when the agent joins), for that grant's profile, replayed to its own API server with the grant, never through a proxy. Approvals and clarify are refused there: the agent's owner answers them on their own Hermes. A request that waited more than 30 s at the mailbox, by the mailbox's clock, is dropped, since the home asks again if it still needs to, so a Hermes that was off never runs the turns it missed; stops and revokes apply however old. When asked and Listens only answer with a "(pass)" run and no model call; past its turns a day, the day's first turn is a notice and the rest pass. A turn still running 10 minutes after it started is stopped. Only a run's status and its final reply (cut to 64 KiB) go back, and a refusal as its code with a fixed sentence, never Hermes' text (2026-10-27, notifier #401).
- A home's Hermes reaches a member's agent through the bridge's loopback server, at the URL the agent's route names (`room_bridge.url`: its Link and profile), only with a HermesRoom grant and only over that Link. Hermes' API key never leaves the host, approvals and clarify are refused there with nothing sent, and a Link that ended reads cut off. The member's answer is waited for 15 s: no answer is 504, and the mailbox refusing a request, 16 waiting or 60 a minute on a Link are 503, never a 4xx, which Hermes takes as a turn not admitted. Status reads are answered there from the statuses the member sends. A member quiet for 3 minutes, a turn still running 12 minutes after its admission, and a dispatch the member never answered, at Hermes' recovery of it, read failed with a sentence naming the Link ("Laifu's Hermes didn't answer."), so the room goes on. A read, a stop or a kept admission is answered there only for a grant the member took for that run; anything else is asked of the member (2026-10-27, notifier #406).
- A room with people you've linked starts as a draft on its home, the Hermes that will host it: its name, the creator's own agents, and up to 5 people by Link, with up to 6 agents in all. Each Link gets (6 − the creator's agents) ÷ Links places, so no answer can overflow the room. It starts by itself once everyone has answered, or with whoever has joined when its creator starts it anyway (Start now); with fewer than 2 agents it makes no room and ends `too_few`. A draft lasts 7 days, the mailbox's hold, and can be taken back while it waits, which undoes the joins on each person's Hermes (2026-10-27, notifier #409).
- An invite's join card shows who it's from (the Link's name), the room's name, the other people and agents, the places, and each profile's choices for the room from its most recent room with the same people (the same Links and other people's names), else its defaults. Joining mints each agent a grant on its own Hermes for its place: dispatch for 24 hours, status and stop for 30 days, never approve. Hermes reserves the place, the catalog comes from that Hermes' own API server with the new grant (the grant names the policy the API server runs, which a look-only grant for a minute reads first, and an API server that doesn't answer, or whose policy changes while it joins, refuses the join, `api_server`), the bridge binds the grant to the Link, and the agent's choices are saved. A join is refused with nothing made or sent for a profile not set up for rooms, one whose turns run on Codex's app server, an invite that ran out, a Link that ended, or more agents than places; one agent failing undoes the others, and so does the home's word on the room, or the invite running out, while they join (`ended`, `lapsed`) (2026-10-27, notifier #409).
- The home takes an answer only from the Link it invited, for that Link's places, from the installation that Link's answers first came from, while the draft waits. At the start it asks each joined agent's Hermes through the bridge whether it still takes the grant: a refusal (a 4xx but 408 and 429) or a changed catalog or scope leaves the agent out, and no answer keeps it, for the bridge to settle its turns. The room is made in the running room service with every member at once, and each linked agent's route is registered at the bridge's URL, live with no restart on either side; a route that can't be saved leaves its agent cut off, and a create that fails is tried on 3 passes, then ends `start_failed`. Each person's Hermes hears that it started, with who's in it, or why not (`started_without_you`, `refused`, `withdrawn`, `lapsed`, `too_few`, `start_failed`) (2026-10-27, notifier #409).
- The room goes in the room service the request that made it would use: with the dashboard in the gateway, that profile's canonical service, owned by the request's subject as Conduit's own rooms there are; else the legacy one the dashboard runs. A draft from the CLI goes to the gateway's while the gateway's dashboard runs the rooms loop, even with another dashboard beside it (Hermes Desktop's), else to the dashboard's. Answers arrive, and rooms start, only in a dashboard's rooms loop, one start at a time per installation (2026-10-27, notifier #409). A draft for a profile the dashboard didn't start with comes with `?conduit_profile=` (capability room-dashboard-profiles), so it's made in the dashboard for that profile's service; made with `?profile=`, it's made in the profile's plugin host and starts in the legacy service, not refused, since the plugin can't tell that host from a Hermes that runs every plugin in a host beside a legacy dashboard (2026-10-27, notifier #419).
- A linked agent's peer id is `l` and 12 hex of its Link id's SHA-256, and its member id that and `-<n>`, since Hermes' ids don't take a Link id's base64url. Its handle comes from its owner, made unique in the room (`laifu`, then `laifu-2`), with `@user`, `@all` and `@everyone` reserved; an agent named in the CLI gets its handle and name as Conduit tags its bot, and the default profile with no bot name is `@hermes`, Hermes. Every host's framing names each other agent's owner and the room's host, by the names this host's owner gave their Links, and GET /rooms/people gives that record for the app (2026-10-27, notifier #409). The record gives each member's status (in, left, removed), and the home's framing stops naming agents that are out, which Hermes' roster keeps; on a member's Hermes only its own agents' status is known. The CLI's drafts show a started room's agents by their handles there, which `rooms remove` takes (2026-10-27, notifier #411).
- The home's own agents need no room setup (they run in its own room service, with no grant) and always join in: their How it takes part and Turns a day aren't enforced there, as the build plan's decision 8 has it for v1 (2026-10-27, notifier #409).
- Both sides keep their drafts, invites and outbox in conduit-rooms/rooms.json in the root Hermes home, 0600 under a file lock, and each envelope has its own message id, so one sent twice lands once. Grants travel only in answers, fresh grants' envelopes (notifier #411) and that file, never in a route's answer, the CLI's output or a log line. A join whose room never starts is undone a week after its invite ran out, and ended drafts and invites are forgotten after 30 days. The routes (capability room-invites) answer 60 requests a minute between them, and one that sends over the Links answers within 50 s or with `timed_out` (504) (2026-10-27, notifier #409).
- While a room goes on, each joined agent's own Hermes mints it a fresh grant every 12 hours, from its join until it's out of the room, so a waiting join's too: the same place and policy, a new grant id, 24 hours to start turns and 30 days to read and stop them from then. The home takes it only from the agent's own Link, for its own place, while the agent is in the room, and only when it was issued after the one the home has, and puts it in the agent's route in the room service the room started in (`register_peer_route` again, which saves before it publishes); a route cut off at the start gets saved then, and one the room service dropped itself (a disband's) isn't brought back. Renewing never revokes anything, since Hermes revokes a grant's whole scope. A renewal its API server doesn't answer is tried again in a minute, one for a changed policy or a Hermes missing a call in 12 hours, and a refusal, a grant past its 30 days or a Link that ended stops that agent's renewals, so its turns read cut off once its grant runs out (2026-10-27, notifier #411).
- A person takes some or all of their agents out of a started room (POST /rooms/leave, `rooms leave`): each is undone on their own Hermes at once (unbound, its grant's scope revoked) and the home cuts off its route, so its queued turns fail as a cut-off member's do. A room that hasn't started can't be left (`not_started`): while its invite waits it can be declined (`rooms decline`), and once joined it can be left when the room starts. Their hidden chats for the room stay, for `rooms forget` (Eric, 2026-10-26) (2026-10-27, notifier #411).
- The home takes a linked person's agent out of a started room (POST /rooms/drafts/remove, by member id or handle, `rooms remove`): it revokes the agent's grant on its Hermes through the route, where that answers, cuts off the route, and tells its Hermes, which undoes the join. The home's own agents can't be taken out, since a room in Hermes keeps its members: disbanding ends it (2026-10-27, notifier #411).
- Disbanding a room over Links ends it on the home and tells each person with agents still in it, whose Hermes undo their joins, so a revoke Hermes' disband sent through the bridge and lost still ends it there; their hidden chats stay (2026-10-27, notifier #411).
- An approval one of your agents' turns waits for in a room hosted elsewhere waits on your own Hermes, and the home only hears that the turn waits. GET /rooms/approvals lists each, the oldest turn's first, with the room, who hosts it, the agent by its handle there and what it asks, reading each run with the grant the bridge keeps for it, since Hermes ties a room's run to the grant scope that started it. POST /rooms/approvals/answer (`rooms approve`, `rooms deny`) answers it once or deny only, through this Hermes' own API server, with a grant made for that answer alone: the run's scope and policy, approve only, for a minute, never stored, sent, logged or returned, and not revoked, which would revoke the agent's own. Each listed approval names the session its "Approval needed" notification names (`session_key`), for the app to match them. The routes (capability room-approvals) take no profile and answer 60 requests a minute of their own, on two threads of their own, each within 30 s, so a slow API server never holds the dashboard's shared ones (2026-10-27, notifier #416).
- An invite tells the invited person's phone: their Hermes sends a room.invite push when it comes in, once per invite, with the pairing of the profile its dashboard runs as, titled "<who> invited you to <room>" and carrying the invite's Link and room for the tap. The relay sends it only to a phone whose Conduit turned its `room_invite` preference on, off until then, so main's app, which would show it as a reply, gets none; see Notifications for the gate on relays from before it and what stays sealed. An invite dropped as it comes in (over the 50 kept) tells no one, and a push that fails never stops the rooms loop (2026-10-27, #1381, notifier #425).
- Everyone whose agents are in a room keeps a copy of it on their own Hermes, which their Conduit reads, never the home. The home sends each of them its log a page at a time (room.page: at most 500 events and 160 KB, one waiting for its answer at a time and sent again after a minute without one), with what the room is doing (whether it ended, who's answering, each linked agent's route), never the home's approvals or its own agents' turn errors. Their Hermes takes a page only over the Link that invited it, once the room started, from the room's own authority, keeps it with Hermes' replica store in its own conduit-rooms/copies.db (owner only, apart from Hermes' rooms), and answers with what the copy holds (room.copied), so a gap or a lost page starts the next one where the copy is. Pages stop when a person's agents are all out; a disbanded room's go on until every copy has its end. GET /rooms/copies, /rooms/copies/log and DELETE /rooms/copies (capability room-copies, `rooms copies`) read and forget them (2026-10-28, notifier #434). Forgetting is refused while an agent of yours is still in the room (`still_in`), so your posts keep framing its turns, and for a room this Hermes hosts (`hosted`). A copy notes which members are your agents, so once its invite is forgotten (30 days after it ended) the copy still lists them, and from then the room in it reads `left` unless the home said it ended (2026-10-29, notifier #448).
- A person with an agent still in a room someone else hosts posts in it from their own Conduit, to their own Hermes (POST /rooms/copies/messages, capability room-posts), which keeps it as sending and sends it over the Link that invited it (room.post). The home posts it with Hermes' own send in thread main, every line starting with the person's name as its Link calls them ("Mona: "; "Guest: " for a Link without a name, or with anything but letters, digits, spaces and `.'&-`, so no name carries a colon, a bracket or a line break), so none reads as its owner's in Hermes' prompt; at most 16,000 bytes, 60 an hour per person per room; and answers with the seq or why not (room.posted). The home records who each post was for: its pages carry it to the copies (an event's `post.by`, null for your own) and GET /rooms/people lists the latest 500 (`posts`). Its agents are told the others' names start their lines; a member's agents are told their owner's do, and a line under their owner's name that their Hermes didn't forward is the host's (2026-10-28, notifier #441). Posts and who's who follow the room's current invite, so a room re-joined over a new Link is another room; a page keeps who posted before its events (2026-10-29, notifier #448).
- Your agent works on a room for you in your private chats: notes, a summary, what someone said, a draft reply. The conduit_room tool (toolset conduit) lists the rooms this Hermes hosts over Links and its copies of rooms hosted elsewhere, and reads one's messages, newest first or from a seq on (at most 200, each cut at 4,000 characters, the answer at most 64 KB, keeping a forward page's start). Each message is named as the room screen names it: "you", a linked person by their Link's name, an agent with its owner. A line the home marks as yours is yours only when it's one of your posts (by its seq, or its text while still sending), else "<host>, as if from you (not one of your posts)"; a name another Hermes gives that reads as "you" is Guest, and room and agent names are one line of at most 80 characters. Nothing goes back to the room. A room turn never has the tool (room_choices' NEVER), and it refuses a room's session, a subagent and a call without a session id. A room's private chat (one per room and profile, conduit-room-chats.json) tells each turn which room it's about, its name framed as the host's words. In a room hosted elsewhere where your agent Listens only, the rooms loop (looking once a minute) sends that agent a hidden turn in the room's chat through the session host, once the room has been quiet 30 minutes after new messages or has ended: notes on what's new since its last ones, at most 200 messages a turn, counted once the chat takes the turn; a refused or failed send waits 30 minutes (2026-10-29, notifier #448). GET /rooms/chats lists a profile's room chats and PUT /rooms/chats makes a chat that room's chat for the profile (capability room-chats; 404 for a room this Hermes doesn't have, 503 when its rooms can't be read); a chat the room gets starts its notes at the room's newest message, and one Hermes no longer has is forgotten when its notes come due. In the tool's list a copy whose agents were all taken out reads "you were taken out" while the room goes on, and other people's agents in a copy carry no in-room status, which the home's pages don't give (2026-10-29, notifier #457).
- Ask me first: in a room turn with other people's agents whose owner chose Ask me first (the default), the agent asks its owner's phone with conduit_ask_owner (question, and exactly what it would share) before it shares anything personal, in any tools tier, Talk only included. The ask is a confirm prompt in the profile's present store that lasts 24 hours and goes only to, and is answered only by, a Conduit with feature room-asks: Share (share exactly that), Say instead (say only what the owner wrote; no text reads as no) or Don't share. The tool waits 30 s; an answer that comes later reaches the room's next turn privately, once, by room so a compacted session hears it too, and counts as heard only when that turn replied and Hermes says it ended without failing or being stopped, never in a delegated child's turn or a fork of the chat (the self-improvement review, a /btw), which isn't framed with them either (#1495 carrying #1489, notifier #464). Room asks have their own caps (3 waiting a room, 40 across rooms, 6 an hour a room, 12 across rooms), never use the owner's own, and keep the newest 10 unheard answers a room (60 across rooms) for a week. Where no ask is kept, the agent says it can't share that, never that it'll check. Setup always keeps conduit_rooms in the room ceiling, the one exception to its saving the ceiling exactly (2026-10-29, notifier #460, notifier #461).
- Use my data: in a room turn with other people's agents whose owner chose Use my data, the agent may call conduit_free_busy for its owner's busy times from the calendar the phone shares with the profile (merged busy blocks, at most 31 days a call, with the time zone, when the phone last synced and the synced window when the range leaves it), never titles, places, calendars, people or the device. Busy times follow the room's share choice, as the 2026-10-22 ruling has what an agent shares: What helps may share them, Ask me first asks the owner with conduit_ask_owner before it does, and Nothing personal takes the tool out of the room. Use my data allows every room-safe data tool, only conduit_free_busy for now, so choosing it is choosing free/busy and there's no tool picker; conduit_calendar stays out (2026-10-29, notifier #463).
- Asks between linked agents: in the owner's private chats only (never a room turn or a subagent), their agent asks a linked person's Hermes with conduit_ask_linked whether they're free on a date (in their time zone, at most 92 days off) or a question (one line, at most 300 characters). No agent answers on the asked side: the asked owner's standing rules for that Link answer, computed by the plugin, or the owner does, so nothing the asker writes reaches a model there. Free on a date is yes_no (free or busy), times (also the busy times in that window), ask (the default: the owner sees what the rule would say and Shares it, Says instead or Doesn't share) or off; a question is ask (the default) or off; the rules name the profile whose phone and calendar answer. What waits is a confirm prompt in that profile's present store carrying the Link, shown and answered only by a Conduit with feature link-asks, for 24 hours, with a question shown as plain text; with no such Conduit it's answered that it can't be now, and unanswered the asker hears no answer came. The asked side allows 10 asks an hour a Link, 3 waiting a Link and 20 in all. The tool waits 20 s; a later answer reaches the chat that asked before its next turn, once (also when Hermes continues the chat under a new session after a compaction), heard as room asks' answers are, an answer the tool gave too, and whatever the other side sends back is quoted and framed as theirs, never as instructions. A free-on answer from a phone that last shared its calendar over 6 hours ago says how long ago (2026-10-29, notifier #465).
- Your agents' turns in a room someone else hosts send no reply or failure push and no automatic alert call, since the room shows them and their hidden chats aren't ones Conduit opens; approvals and questions still notify. A turn whose room can't be told from the session store notifies as any other (2026-10-27, #1381, notifier #425).
- Who's live in a room: the gateway's live turns where it reports them (`member_activity`, Hermes c73cbcc4), a running or stopping turn before a queued one, as Hermes Desktop reads them, and a status this build doesn't know is skipped; else the log, as before. A live member on another Hermes whose route says its Hermes refused the room reads "<name> is cut off", and one whose Hermes couldn't be reached reads "<name> can't be reached", in the header and where its reply would land, until its turn runs, whether the turn names it by member id or, having none, by profile. Hermes keeps routes in memory, so one not tried since its room service started reads as responding (2026-10-26, #1289).
- Disband's warning in a room with a member from another installation says the room ends for everyone, your agents' sessions for it are deleted, and agents on other people's Hermes keep theirs. Rooms of only your own agents keep the old text, which holds since notifier #384 (2026-10-26, #1289).
- Group Info, from the room menu in both shells, lists each member as your agent or on another Hermes, with its route's trouble. In a room with a member from another installation, each of your agents opens its choices for the room when the plugin reports room-rules, which stays out of usedCapabilities, so an older plugin gets no update notice. The choices page offers Talk only and Look things up, and shows Use my data or Custom, with its tools, only while one is the choice; how an agent takes part and its turns a day stay off it until rooms go over Links (N5), where the room bridge holds agents to them. Each change sends only that choice, one at a time from the tap, so an older answer can't land over a newer change; the page shows what the plugin answers, refuses an answer that isn't ok or names another room, and requests stay with the dashboard they were made for. The note's footer says it holds up to 1,000 characters, where typing stops (2026-10-26, #1289).
- A member on another Hermes never takes one of your bots' names, pictures or colors, whatever its profile is called there (2026-10-26, #1289).
- Settings > People is one page, from a People row under Hermes in both shells, shown while the plugin reports room-links. Its host setup needs room-setup, and with an older plugin the page says to update it. Neither joins usedCapabilities, so an older plugin gets no update notice. The Links part takes no profile; host setup is for the profile in use, which it names. Requests stay with the dashboard they were made for, and an unlink or a cancel, which waits on the mailbox, gets 55 s, past the plugin's 50. A refusal shows the plugin's words, a 502, 503 or 504 with words of its own too, since those are the mailbox's answers, not a dashboard that couldn't reach Hermes (2026-10-26, #1323).
- Host setup lists what Set up will do, from what the plugin says it would change, or what blocks it, with only Check again then. The tools rooms may use are a switch for each toolset the plugin offers, starting from what it saved, and a setup that leaves them as they were keeps that ceiling as it is. Changing a ceiling the setup saved, from Change or from Set up, asks first with the CLI's words: the agent then stops answering in rooms already started with other people's agents. While the API server is already on, the page says other apps using it get only these tools too. A gateway busy with chats asks before restarting (Restart now or Later), and a restart that starts is followed every 2 s for up to 30 s, until the API server runs or says why it doesn't (2026-10-26, #1323).
- Each Link shows its name, its status (Linked; waiting for the other Hermes to confirm; or never confirmed, so ask for a new invite; none for a status this build doesn't know) and their four words, with Unlink, which asks first and says it unlinks both sides. While one waits, the page reads the list every 5 s for up to 3 minutes. An invite waiting shows the name it shows you by and until when, with Cancel invite. Your Hermes' words show once its first invite or accept made its keys, and a Hermes without Python's cryptography package says it can't make Links. While there's a Link or an invite and nothing on the host reads the mailbox, the page says what the other side sends waits there, for up to 7 days (2026-10-26, #1323).
- Only the plugin reads an invite. The app takes `conduit://link/` and a base64url payload, 2,048 characters in all at most, as the plugin does, whatever the case of the scheme and host, and sends it in the plugin's spelling. It never logs one and leaves it out of descriptions, since its token links whoever holds it with the inviter (2026-10-26, #1327).
- Link with someone, at the top of Settings > People, asks for the name the other person sees, kept on this device for the next invite or accept, then makes the invite and shows its QR code, Send the invite (the share sheet, with the link), your Hermes' four words to compare, and until when it works, for one person. While it shows, it reads the Links every 3 s for up to 3 minutes and says when they've linked. Making and accepting an invite wait on the mailbox, so they get 55 s; reading one keeps the bridge's own time (2026-10-26, #1327).
- An invite opened from another app (the share link, or the Camera reading its QR code), tapped in a chat, scanned with Scan or pasted opens one sheet over the app, and nothing else reads it: no chat or Settings link, no sign-in code. One the app can't read opens nothing. The sheet shows who it's from, their Hermes' four words to check with them, the mailbox's host, until when it works and, with more than one dashboard saved, which Hermes links; then Link with <name> (the catalog's Link is a web link), with the name they'll see you by. It stops there when the invite is your own, ran out, or is from someone already linked, whose Link it names, in that order. Until Conduit has connected and the plugin says what it serves, it waits, and a plugin without room-links says to update it (2026-10-26, #1327).
- After Link with <name>, the sheet shows the Link waiting and reads the list every 3 s for up to 90 s, until it's linked. One still waiting then says their Hermes confirms once it reads its mailbox, and one gone from the list says to ask for a new invite. An accept the mailbox couldn't take yet keeps its Link waiting: the sheet shows the plugin's words and follows that Link. An invite from someone whose Link still waits opens on that Link (2026-10-26, #1327).
- Scan reuses the sign-in Scan Code sheet, with an invite's words and without the prompt that asks Hermes for a sign-in code, and the invite opens once the scanner has closed. Paste is the system's paste control, so iOS asks nothing before it reads the clipboard, and it takes the first invite in what was copied (2026-10-26, #1327).

**Open gaps**
- On main the app shows none of it, and invites are made and opened with `hermes conduit-push links`. The `linked-rooms` branch has the room screen, Group Info with your agents' choices, and Settings > People with host setup, the Links and linking with someone; New Group Chat with linked people, the join card and the Chats list come in its later PRs, with their Settings captions. Until then a room with linked people is made with `hermes conduit-push rooms invite` and joined with `rooms join`, and choices for a room hosted elsewhere are set with `hermes conduit-push rooms set`.
- How an agent takes part and its turns a day are held by the room bridge (notifier #401 and #406), for agents in rooms hosted elsewhere; the home's own agents always join in. The choices page leaves them out until C3, which shows them only for agents in rooms hosted elsewhere.
- Other people's leaving isn't told to a room's other hosts: on a member's Hermes, who's who knows only its own agents' status, while the home's knows everyone's.
- Leaving a room, taking an agent out and who's out are in the notifier and its CLI only: C4 adds Leave to a room hosted by others, Take out to Group Info in your own, and who left or was taken out.
- A memory provider's automatic recall can't be skipped in a room without a Hermes change (written up for Hermes).
- Asks between linked agents are in the notifier and its CLI only: C7 adds "What <name>'s Hermes can ask" to Settings > People and a Link's ask to the present panel. Until then no Conduit reports link-asks, so an ask a rule doesn't answer is answered that it can't be now.
- On main, Disband's warning says every member's session ends, which holds for rooms of your own agents; the `linked-rooms` branch's says that in a room with other people's agents theirs stay on their hosts.
- On main a cut-off member shows only as a failed turn (reason code unknown: Hermes has none for it); the `linked-rooms` branch's room screen reads its route status. Deleting an ended room hosted elsewhere from the Chats list comes with the branch's Chats list.
- The branch's host setup sends `?profile=`, so for a profile the dashboard didn't start with it saves without restarting the gateway and says to restart it. C3 sends `?conduit_profile=` to the setup and to new drafts when the plugin lists room-dashboard-profiles.
- Approvals for your agents in rooms hosted elsewhere are answered on your own Hermes with `hermes conduit-push rooms approvals`, `approve` and `deny`, or by a call from Hermes about one; C3 adds their card to the app, opened from the "Approval needed" notification by its `session_key`.
- No app turns the relay's `room_invite` on yet, so an invite shows only in `hermes conduit-push rooms invites`: C3c, on the `linked-rooms` branch, turns it on with the invite push's copy, its tap to the join card and Settings > Notifications' Room invites.
- No app reads the copies of rooms hosted elsewhere yet: C4, on the `linked-rooms` branch, shows those rooms in the Chats list and the room screen from them, and forgets one with its hidden chats when you delete it.
- No app posts in rooms hosted elsewhere yet, or names linked people's posts in your own rooms: C5a, on the `linked-rooms` branch, adds the composer to a copy (sending and refused) and shows each post as its person's from `post.by` and GET /rooms/people's posts.
- Main's app doesn't open a room's private chat, so no room gets notes there: C5b (#1471, on the `linked-rooms` branch) adds Ask and Wrap Up to Group Info, through the routes notifier #457 added.
- Ask me first's panel in the app (C5c: the room's name, Say instead, the feature `room-asks`) isn't built. Until it is, no Conduit gets a room's ask, so the tool answers `no_device` and the agent says it can't share that.
- A copy shows every agent in it as in, even one that left or was taken out, since the home's pages don't carry who's out; and in the app a copy whose agents were taken out reads ended while the room goes on (the conduit_room tool says "you were taken out", notifier #457).
- Only someone with an agent in a room can post in it: an answer with no agents declines ("Just me" isn't built).
- A copy's events are Hermes' as the home logged them, apart from the home's own agents' turn errors; a single event too big for a page (160 KB) reaches the copy without its payload.
- Agents that aren't Hermes (an A2A member) are left out.
- An acceptor's Hermes that stays off for more than 7 days while its confirm waits at the mailbox leaves the inviter's side linked until its owner unlinks it (the notifier README says so).
- Changing the tools rooms may use says the agent stops answering in rooms already started, but not in which.
- An invite opened from another app while a sheet is already up (classic Settings, say) can't show over it, as a sign-in code link can't: open it again once the sheet is closed.

**Checked:** 2026-10-29, #1497 (asks between linked agents: the tool, the rules, the CLI and routes, the README section, the gap left for C7), with notifier #465; 2026-10-29, #1491 (a room's pictures open in the picture viewer); 2026-10-29, #1495 (a fork of a room's chat neither hears nor is framed with the owner's answers, notifier #464); 2026-10-29, #1494 (Use my data's free/busy: the tool, its rules, the README section, the gap closed), with notifier #463; 2026-10-29, #1485 (Ask me first: the tool, its prompt and its answers, the gap left for C5c), with notifier #460 and #461; 2026-10-29, #1475 (the room chats routes, the tool's "you were taken out", the README section in the text sibling), with notifier #457; 2026-10-29, #1470 (your agent reading your rooms, the room chats and their notes, N7a's minors), with notifier #448; 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1448 (a member known only by name matches a bot's own name before an unnamed bot's id capitalized); #1450 (posting in rooms hosted elsewhere), with notifier #441; #1410 (copies of rooms hosted elsewhere), with notifier #434; 2026-10-27, #1381 (the invite push and quiet room turns), with notifier #425; #1360 (new drafts and the setup on a profile the dashboard didn't start with), with notifier #387, #390, #396, #397, #398, #401, #406, #409, #411, #416 and #419.

## Chat sources

Where a chat came from: Hermes' `source` on each session row, which Conduit
files under a source (`SessionSource`) for the row's icon and the Chats
filter's Sources section. Cron runs and the sessions that aren't chats are
kept out of the chats list (see Kanban workers' transcripts).

**Siblings:** the V2 Chats row icon and the Sources filter · the iPad and Mac
list (same view) · the older sidebar's source filters · All profiles · the
saved chat list and offline copies (they store the source) · CarPlay's chat
list (a speech bubble for every messaging source) · the notifier's messaging
group for reply notifications (`notifier/reply_sources.py`, the same Hermes
platform list) · the chat header (shows no source)

**Code**
- Sources and their names, icons and colors: `Conduit/Models/Models.swift` (SessionSource, gatewayPlatforms)
- Filing a row: `Conduit/Services/HermesClient.swift` (MessageNormalizer.classifySource), `Conduit/Services/AppState.swift` (sessionCategory)
- Filter order: `Conduit/Services/AppState.swift` (defaultSessionFilterOrder, normalizedSessionFilterOrder)
- Filters and icons: `Conduit/Views/V2/V2ChatsView.swift` (sourceFilters, sourceRows), `Conduit/Views/V2/V2SessionRow.swift` (V2SessionIcon), `Conduit/Views/SidebarView.swift` (availableSources)
- Saved copies: `Conduit/Services/OfflineChatCache.swift` (OfflineCachedSession.source, SavedChatList: rows keep the source they were filed under)
- CarPlay: `Conduit/CarPlay/CarPlayBrowseTemplates.swift` (chatSymbol)
- Tests: `ConduitTests/MessageNormalizerTests.swift` (testGatewayPlatformsAreNamedByTheirHermesSource), `ConduitTests/VoiceHistoryTests.swift` (testVoiceFiltersJoinASavedOrderAfterChat), `ConduitTests/SidebarLayoutTests+CronFilter.swift`

**Rulings**
- Each Hermes gateway platform (`gateway.config.Platform` and the bundled platform plugins) is its own source, by name, with its own filter; a platform with two backends is one source (WhatsApp and WhatsApp Cloud, iMessage over BlueBubbles or Photon, WeCom and its callback app, a Microsoft Graph webhook under Webhook). A plugin platform Conduit doesn't know yet is Other, not a guess (2026-10-31, #1572, issue #1561, which Eric asked to fix).
- A chat handed off to a platform is filed under it once the handoff completed; a pending or failed handoff leaves it where it started (Hermes keeps `handoff_platform` on both). A host that reports no `handoff_state` files by the platform (2026-10-31, #1572 review).
- A source added to the filter order takes its default place after the source before it in a saved order, as Voice and Cron did, so the new platforms follow Telegram wherever the user moved it.
- Chats Conduit starts are Hermes `desktop` sessions, the same as Hermes Desktop's, and aren't a source of their own: a chat started on either side resumes on the other and is listed where Desktop users expect it (2026-10-31, Eric, issue #1561).

**Open gaps**
- The chat header shows no source; only the row icon does.
- A plugin platform Hermes adds after this list shows as Other until it's added here.
- A saved chat list written before #1572 keeps Other on its platform rows until the live list replaces it: a saved row keeps no raw Hermes source, as in Kanban workers' transcripts.

**Checked:** 2026-10-31, #1572 (every gateway platform named, issue #1561).

## Kanban workers' transcripts

A Kanban task's worker runs in a Hermes session of its own (source
`kanban`). Hermes refuses to reopen one as a chat (`session.resume` 4132):
only the board may run it, so it can supervise the worker. Conduit leaves
these sessions out wherever it offers chats, and the task's Worker Log is
where to follow one. The other sessions Hermes' pickers hide as not
conversations (`INTERNAL_LISTING_SOURCES`: `kanban`, `tool`, `oneshot`) stay
out the same way, and so do workers Hermes stored before it tagged them.

**Siblings:** each profile's chats list and its archived list (and their
`session.list` fallback) · All profiles · project chats (lanes and
previews) · search "In messages" · find chat on a phone call in Gemini,
Qwen, Grok, GPT-Live and Local Live (VoiceChatFinder) · Classic voice and
Hermes-run turns, which search with Hermes' own `session_search` · find chat
on an Apple Watch call (notifier) · CarPlay's chat list, the Home Screen
launcher widget's conversation picker, the Share extension's chat picker and
the home voice button's Recent menu (they read the same list, the pickers
through the widget snapshot) · opening a chat from a
link or notification (the message shown) · a Pulse card drawn from a
worker's session (it links the task, and Do it starts a new chat) · the Kanban task's Worker Log ·
Hermes Desktop's sidebar (upstream, leaves `kanban` out too)

**Code**
- Sources: `Conduit/Models/Models.swift` (SessionSource.hermesKanbanSource, hermesInternalSources, nonChatExcludedSources, chatListExcludedSources, isLegacyKanbanWorker)
- Lists: `Conduit/Services/AppState.swift` (profileSessionsPath, archivedSessionsPath), `Conduit/Models/AllProfilesChats.swift` (sessionsPath), `Conduit/Services/HermesClient.swift` (MessageNormalizer.normalizeSessions drops `kanban`, `tool` and `oneshot` rows and legacy workers from every list it builds: the `session.list` fallback, project lanes and previews)
- Search: `Conduit/Services/SessionContentSearch.swift` (path, hits drops legacy workers), `Conduit/Voice/VoiceChatFinder.swift` (path, matches drops legacy workers), `notifier/dashboard/api/watch_tools.py` (run_watch_find_chat, CHAT_SEARCH_EXCLUDED_SOURCES, chat_matches drops legacy workers with is_legacy_kanban_worker)
- Opening one anyway: `Conduit/Services/AppState.swift` (the 4132 case where a resume fails, reconciliationWasKanbanWorker)
- Pickers: `Conduit/Services/AppState+Widgets.swift` (publishWidgetSnapshot builds the widget and Share extension choices from the chats list), `Conduit/Services/AppState+WidgetLaunch.swift` (prepareWidgetLaunch says a choice no longer listed is unavailable), `Conduit/Services/AppState+ShareDraft.swift` (deliverSharedDraft's fallback to the chat on screen)
- Worker Log: `Conduit/Views/Kanban/KanbanWorkerLogScreen.swift`
- Pulse cards: `notifier/pulse_hermes.py` (worker_tasks, the same legacy rule, kept in step by `notifier/tests/test_watch_chats.py`'s test_pulse_tells_legacy_workers_apart_the_same_way), `notifier/pulse_control.py` (`kanban_task` on the card); the app side is in the Pulse entry
- Tests: `ConduitTests/SessionContentSearchTests.swift` (testHitsLeaveOutKanbanWorkersStoredBeforeTheTag, testHitsKeepTwentyRealChatsBehindLegacyWorkers), `ConduitTests/VoiceChatFinderTests.swift` (testChatSearchLeavesOutKanbanWorkersStoredBeforeTheTag), `ConduitTests/MessageNormalizerTests.swift`, `ConduitTests/SidebarLayoutTests+AllProfiles.swift`, `ConduitTests/AppStateChatResumeTests.swift` (testOpeningAKanbanWorkerPointsAtTheBoard, testAutomaticReturnRetiresASavedKanbanWorker, testAutomaticReturnDoesNotRetryAKanbanWorkerByItsStoredID), `notifier/tests/test_watch_chats.py` (test_find_chat_keeps_five_real_chats_behind_legacy_workers)

**Rulings**
- Kanban workers aren't chats: lists, search and voice leave them out with `exclude_sources`, as Desktop does, and the board's Worker Log shows them. The session normalizer drops them too, so a list whose source doesn't filter (projects, `session.list`) can't show one. Classic voice needs nothing for tagged workers: Hermes' `session_search` already hides `kanban` (legacy ones are an open gap) (2026-10-26, #1305, tester report via Eric; narrowed 2026-10-29, #1464).
- A worker reached anyway (a link, a cached row) says it belongs to the board and points at its Worker Log instead of "Failed to restore this conversation" (2026-10-26, #1305).
- A 4132 counts as "not found" everywhere a missing chat is handled: a worker saved as the last conversation is retired on the next return (the newest chat opens instead, and its stored id isn't tried, since Hermes refuses a worker under any id) and a notification for one isn't retried; only the message differs (2026-10-26, #1305 review).
- A Pulse card drawn from a worker's session links the task, opened in Tasks › Board, instead of the worker, and its Do it starts a new chat about the task, since the worker can't be continued (2026-10-29, #1473 on the `pulse` branch, notifier #458; a tester's report via Eric).
- A launcher widget still holding a worker (picked or saved before this change) says the conversation is unavailable, since the worker isn't in the chats list any more; it doesn't try the resume that would show the board message. A share sent to a worker from a snapshot written before this change goes the same way: the draft lands in the chat on screen with "Conduit couldn't open the chat you picked". The next snapshot, written once the app reads its chats list, has no workers (2026-10-26, #1305 review).
- Rows saved before this change stay in the saved chat list until a full, non-empty read replaces them: a saved `SessionSummary` keeps no raw Hermes source (a worker is `.other`), and storing one for that window isn't worth the code (2026-10-26, #1305 review).
- Conduit hides what Hermes' own pickers hide: `tool` (third-party integrations, `hermes chat --source tool`) and `oneshot` (`chat -q`, `-z`) sessions as well as `kanban`, in the lists, search and voice, the Watch's find chat included (2026-10-28, #1461, from issue #1459, which Eric asked to fix; the Watch in notifier #450, 0.115.4).
- A worker Hermes stored before it tagged workers `kanban` is a `cli` (or `local`) row whose preview is the dispatcher's one-line prompt, `work kanban task <task id>`. Hermes retags only those whose folder is under the board's workspaces, and resumes the rest, so they listed as chats (Eric's own list, 2026-10-28). The lists leave out a `cli` or `local` row whose preview is exactly that prompt; one where a person wrote more after it stays, and so does a row from another source (Telegram, cron) that reads the same; a chat whose whole first message is that prompt would hide too, which no one types (2026-10-28, #1461: follows from issue #1459's stated fix, which Eric asked for after the rows showed in his TestFlight list).
- Search "In messages" and find chat on a phone or Watch call leave out legacy workers the same way, by the `source` and `preview` newer hosts put on each search row (the tip's list row), and each asks Hermes for three times the rows it keeps (`SessionContentSearch.searchLimit`, 60 for 20; `VoiceChatFinder.searchLimit` and notifier `WATCH_CHAT_SEARCH_LIMIT`, 15 for 5) so workers a word like "task" matches don't crowd real chats out; Classic voice and Hermes-run turns use Hermes' own `session_search`, which hides by source only (`kanban`, `subagent`, `tool`), so it can still recall a legacy worker as past work (see Open gaps) (2026-10-29, #1464 and notifier #452, closing the gap #1461 left).

**Open gaps**
- A project card's count is Hermes' `session_count`, which may include workers in the project's folders; only the fallback (counting previews) leaves them out.
- A worker's transcript (its messages, not the log) can't be read in Conduit. Hermes would serve it read-only over `GET /api/sessions/{id}/messages`; a read-only view is the maintainer's call.
- On a Hermes whose search rows carry no `preview` (before it added the list row's fields to them), search "In messages" and the phone and Watch find chat can still match a legacy worker. Hermes resumes those, so one opens as a chat.
- Hermes' `session_search` (Classic voice, Hermes-run turns, every Hermes channel) can recall a legacy worker's transcript: it hides workers by the `kanban` source, which Hermes' retag never gave these. It's Hermes' recall, not a list Conduit draws; filtering it in the plugin (`transform_tool_result`) for every channel is the maintainer's call (#1464 review).
- A legacy worker saved as the last chat (picked before #1461) still reopens on a return: Hermes resumes it, so nothing retires the saved pointer until another chat is opened. It opens as a readable chat, not an error (#1461 review).

**Checked:** 2026-10-30, #1542 (All history stays after the host's 2000 limit and stops at the oldest reading; the stores needed no change); 2026-10-29, #1517 (the `pulse` branch merged into main: the app paths it lists are on main now; nothing else changed); 2026-10-29, #1479 (a Pulse card drawn from a worker links its task and Do it starts a new chat, #1473 on the `pulse` branch and notifier #458); 2026-10-29, #1464 (search and find chat leave out legacy workers by their preview, notifier #452); 2026-10-29, #1463 (the Watch's find chat leaves out `tool` and `oneshot` too, notifier #450); 2026-10-28, #1457 (the main bot's last chat takes its Conduit name and is listed once by its chat, see Profile names); 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-28, #1461 (`tool` and `oneshot` sessions and legacy workers left out, issue #1459); 2026-10-28, #1448 (Bot Chat rows and the last chat name an unnamed bot by its id capitalized); 2026-10-26, #1305 (with the Share extension's picker).

## Bars lists scroll under

The bars a screen's list or transcript scrolls under, and the fade under
them: a chat's composer bar, the tab bar's clearance, and the list headers.

**Siblings:** the chat composer bar (chats, project chats, Bot Chat) · group
rooms' composer bar · the tab bar's clearance under the Chats, Bots and Tasks
lists and Settings' pages · the Chats, Bots, Tasks and Capabilities headers and Settings' home header · a chat's and a group room's header (the navigation bar), which the transcript fades under ·
iPhone, iPad and Mac · iOS 26 and earlier · text: no Settings caption or doc
describes them

**Code**
- Bar and fade: `Conduit/Views/V2/V2TopBar.swift` (v2EdgeBar, V2SystemScrollEdge, V2LegacyEdgeBar); a screen's backdrop under the fade: `Conduit/Theme.swift` (ConduitBackdrop, ConduitBackdropBehindFade)
- Composer bars: `Conduit/Views/ChatView.swift` (bottomBar, whose height reaches the transcript as its bottom inset, see Following the latest message), `Conduit/Views/GroupChatView.swift` (bottomBar); the composers in them: `Conduit/Views/Components/ComposerBar.swift`, `Conduit/Views/Components/GroupRoomComposer.swift`, resting or expanded per Composer at rest and expanded
- Tab bar: `Conduit/Views/V2/V2Shell.swift` (tabBarClearance, V2TabBarClearance)
- Headers: `Conduit/Views/V2/V2ChatsView.swift`, `Conduit/Views/V2/V2BotsView.swift`, `Conduit/Views/V2/V2TasksView.swift`, `Conduit/Views/CapabilitiesView.swift` (v2EdgeBar(.top)), Settings' home header in `Conduit/Views/AuxiliaryViews.swift` (SettingsView, v2EdgeBar(.top)) with `Conduit/Views/V2/V2SettingsTab.swift` (homeHeader); the Settings sheet's header: `Conduit/Views/Components/ConduitSheetHeader.swift`; a chat's header: `Conduit/Views/ChatView.swift` (V2SoftTopScrollEdge, underChatHeader; setsOwnEdge on the transcript, which sets its iOS 26 edge itself; a saved copy scrolls under it in the chat's own transcript), also on `Conduit/Views/GroupChatView.swift` (setsOwnEdge too: a room's transcript is the same collection view); on iOS 26 the transcript's soft edges are set on its collection view, `Conduit/Views/TranscriptView.swift` (applyEdgeEffect)

**Rulings**
- On iOS 26 a bar is a `safeAreaBar` with the system's soft scroll edge. Before iOS 26, and on a Mac, it is a `safeAreaInset`, and the content under it fades out itself (see below). A bar and its fade read the same switch (`V2SystemScrollEdge.isUsed`), so they always agree (2026-10-27, #1397: on macOS 27 the composer bar's edge hid the transcript well above the composer, #1357).
- Where Conduit draws the fade (before iOS 26, and on a Mac), the content fades its own text out to transparent across the bar's height (a mask, `V2LegacyEdgeBar`), and no bar draws a fading material behind it (the Settings sheet's own header, `ConduitSheetHeader`, keeps its system `.bar` material, a header's background and not a fade; V2TopBar drew one on every system, under Settings' home header too, a box on a wide window; and before iOS 26 one behind a chat's header, where the transcript now fades itself): the backdrop shows through, as under iOS 26's soft edge. A backdrop inside the faded content (Chats, Bots, Tasks, Settings' pages) fades with it, so the bar draws the same backdrop behind the content and the fade never shows the window; the backdrop itself is left as it is, so a sheet presented from that content keeps its own. A material behind the bar drew a lighter box around a Mac's composer, as wide as the chat's column, and full width it would still have been a lighter band (Eric, 2026-10-29, #1468). The tab bar has no fade of its own either: each list fades under its clearance, so it stays the list's width (the bar's own material, across the window, covered the chat beside the list: 2026-10-28, #1444, #1439).

**Open gaps**
- The Mac fallback isn't confirmed on macOS 27; it waits on the reporter's TestFlight check (#1357).
- The navigation bar over a chat keeps the system's top edge on a Mac too (`V2SoftTopScrollEdge` in `Conduit/Views/ChatView.swift`; before iOS 26 the transcript fades itself under it, `underChatHeader`): #1357 only showed the bottom. If macOS 27 draws it too tall as well, it moves to the same switch.
- On iOS 26 the chat's transcript, and a group room's, is a UIKit collection view under SwiftUI's bars: its soft edges are set on it (applyEdgeEffect, soft under the header and under a floating composer, as the stack had them), and whether the bars' system edge draws over it as it did over the stack waits on a device check (the transcript rewrite, 2026-10-31, #1577; group rooms, #1590).

**Checked:** 2026-10-31, #1590 (a group room's transcript is the chat's collection view: its iOS 26 soft edges are set on it, V2SoftTopScrollEdge's setsOwnEdge on the room too, and the device check's gap covers it; Code, gap); 2026-10-31, #1586 (the chat's transcript no longer takes V2SoftTopScrollEdge's iOS 26 edge, which its collection view sets; Code); 2026-10-31, #1577 (the chat's transcript is a collection view: the bars' heights and the keyboard reach it as its insets, moved in SwiftUI's own animation; its iOS 26 soft edges are set on it, a gap until a device check; Code, gap); 2026-10-30, #1550 (a saved copy scrolls under the chat's header in the chat's own scroll view, its offline banner in the transcript's top inset); 2026-10-30, #1541 (at accessibility Text Sizes the resting composers are shorter, one-line placeholder and capped controls, and the bar takes their height as before; see Composer at rest and expanded); 2026-10-29, #1512 (a composer that stays expanded on a Mac or a wide iPad is taller, and the bar takes and reports its height as before; see Composer at rest and expanded); 2026-10-29, #1468 (the content fades itself instead of a material behind the bars; Code, Rulings); 2026-10-28, #1455 (carrying #1431; a chat's bar growing keeps a following transcript's end above it; Code); 2026-10-28, #1444; 2026-10-27, #1397.

## Readable width on wide windows

How wide a screen's content runs on an iPad, a Mac or a landscape phone,
where a phone layout would otherwise run the whole window.

**Siblings:** chat surfaces (chats, project chats, Bot Chat and group rooms
share the chat screen, so its column) · the chat beside the list and with the
list hidden · the drawer shell's chat (Appearance, V2 off, with or without
the persistent sidebar) · Settings' pages · a Chats or Bots list shown alone ·
the call screens (Classic, live calls, live voice consent) · the sign-in
screens (their own column) · cards and pictures whose kept heights depend on
the column's width (see Cards drawn in web pages) · the chat's text on a
wide column (transcript, step rows and cards, timestamps and the reply's
buttons, the composer, group rooms; the list beside it keeps its size) ·
sheets presented from the chat column (the full editor, pinned replies,
code and web previews) ·
Settings' text on its wider column · the Mac (an iPad app there: text
sizes have to grow by point size, the app's text styles through
`scaledFont`) · the check that keeps text styles on `scaledFont` · text: no Settings caption or doc gives a
width, and Chat text size's caption is about its slider, which still applies
on top

**Code**
- Widths and the modifier: `Conduit/Views/Components/ReadableContentWidth.swift` (ReadableWidth.chat(available:systemGrowsTextStyles:), chatMax, chatShare, settings(available:systemGrowsTextStyles:), settingsMax, macLineGrowth, macMaxTextScale, macShare, textSteps(column:base:), textSteps(column:base:from:), chatTextGrowth, columnText(column:base:scalesChatText:size:systemGrowsTextStyles:): the Dynamic Type size, transcript steps and ColumnText a column sets, readableChatColumn, readableSettingsColumn)
- Chat column: `Conduit/Views/V2/V2ConversationScreen.swift` (readableChatColumn()), and the drawer shell's in `Conduit/Views/RootView.swift` (chatNavigationContent); sheets it presents: `Conduit/Views/Components/ComposerBar.swift` (isShowingFullEditor), `Conduit/Views/ChatView.swift` (showsPinnedReplies), `Conduit/Views/Components/MarkupBlock.swift` (MarkupPreviewSheet), `Conduit/Views/Components/HTMLPreviewBlock.swift` (HTMLPreviewSheet, also opened from `Conduit/Views/V2/V2WorkspaceViews.swift` and `Conduit/Views/V2/V2ArtifactsViews.swift`, outside a chat column)
- Text on a wide column: `Conduit/Views/Components/ChatTypography.swift` (ChatTextAppearance.widthSteps, widthScale and widened(steps:in:), ChatTypography.widthScale(steps:from:), standardBodySizes, drawnBodySizes, missingGrowth, lowered, dimension(_:appearance:), font(for:appearance:environmentCategory:), chatWidthTextSteps, ColumnText and the columnText environment value), read at the chat's root in `Conduit/Views/ChatView.swift` (chatTextSize) and a room's in `Conduit/Views/GroupChatView.swift` (chatTextSize); geometry that grows with it: `Conduit/Views/Components/MarkdownProseRun.swift` (the list marker column), `Conduit/Views/Components/MarkdownText.swift` (marker frames); the spots that resolve against the column's already-stepped size: `Conduit/Views/Components/MarkdownText.swift` (markerFont), `Conduit/Views/ChatView.swift` (bodyLineHeight; the cards' UIKit text through `UIFont.preferredFont(forTextStyle:in:)`: ReviewSummaryCard, ModelChangeSummaryCard, ToolRawTextSection, ClarifyCard, ClarifyQuestionRow, ApprovalCard, InputPromptCard), `Conduit/Views/GroupChatView.swift` (GroupApprovalCard), `Conduit/Views/ToolResultViews.swift` (ToolResultBodyView's diff and output, the opened tool row's readable part); the composer's typed text: `Conduit/Views/Components/ComposerPasteTextView.swift` (bodyFont, set on each text size or column change rather than adjusted by UIKit) and its resting height in `Conduit/Views/Components/ComposerBar.swift` (restingTextHeight, textFrameHeight, showsFullEditorButton), and a group room's field and the full editor: `Conduit/Views/Components/ReturnKeyTextView.swift` (ReturnKeyTextEditor, the same way)
- Text styles in points on a Mac: `Conduit/Views/Components/ScaledFont.swift` (ScaledFont, font(in:), standardPoints, systemGrowsTextStyles, View.scaledFont), the column's plain text in `Conduit/Views/Components/ReadableContentWidth.swift` (the font transform); every text style in `Conduit/` is set with `.scaledFont(`, which `scripts/check-fixed-text-sizes.py` (find_text_style_fonts, tests in `scripts/tests/test_check_fixed_text_sizes.py`) holds for a `.font(` whose argument starts on its line; a sheet or full-screen view presented from the chat column (the full editor, pinned replies opened in a chat, a code or web preview in a reply) inherits the column's `columnText` and steps, so its text matches the column's, while one presented from the Chats list, Workspace or Artifacts keeps its own size
- List shown alone: `Conduit/Views/V2/V2Shell.swift` (ReadableWidth.list)
- Settings: `Conduit/Views/AuxiliaryViews.swift` (readableSettingsColumn())
- Calls: `Conduit/Views/VoiceConversationSheet.swift`, `Conduit/Views/LiveVoiceCallSheet.swift`, `Conduit/Views/LiveVoiceConsentViews.swift` (ReadableWidth.call)
- Sign-in: `Conduit/Views/Login/LoginScreens.swift` (LoginReadableWidth, 560 pt scaled with the text size)
- Tests: `ConduitTests/V2SplitLayoutTests.swift` (testChatColumnWidensWithTheWindowUpToItsCap, testChatTextStepsUpWithTheColumn, testSettingsColumnWidensAndStepsItsText, testColumnsSetTheirTextForTheirContent, testMacColumnsGrowTheirTextByScale, testScaledFontIsTheTextStyleUnlessScaled, testWideColumnStepsScaleTranscriptFonts)

**Rulings**
- Widths follow the window, not the device (2026-10-19, #949).
- A chat's column is 760 pt until the chat's width passes about 1056 pt, then takes 72% of it, up to 1040 pt: an iPad beside the list keeps 760 pt, a maximized Mac or iPad window gets a wider column, with the list shown or hidden, in V2 and the drawer shell alike (2026-10-26, #1320, Eric: the column was too narrow on a maximized window). This replaces the 2026-10-23 ruling (#1169) that kept 760 pt with the list hidden.
- A wider chat column shows bigger text rather than longer lines: the column's text goes up one system text size for each size whose lines still hold as many words as the 760 pt column does (none beside the list on an iPad, two with an iPad's list hidden, three on a maximized Mac). Everything in the column steps together, its chrome (timestamps, the reply's buttons, banners) with its text so they keep their proportions (the chrome through Dynamic Type, which holds them together wherever the system honors it; see the 2026-10-29 rulings for the Mac): transcript, thinking, step rows, cards, the composer and group rooms, on top of the user's Dynamic Type and Chat text size (which group rooms now follow too, size and style, as chats do); it stops at the largest standard size, so an accessibility size stays as set. The list beside the chat and the top bar keep their size: the list's column doesn't widen (Eric, 2026-10-27, #1393: maximized on a Mac the chat looked small in a big empty space).
- Transcript text grows by point size, body text's growth from the system's size to the stepped one (17 to 19, 21, 23 pt at the default size), not by resolving fonts at the stepped Dynamic Type size: an iPad app on a Mac appears to draw every size alike, so #1393's steps did nothing there (Eric, 2026-10-29, #1478: maximized or resized, the text didn't scale). In-column cards' UIKit text and the typed text of the chat's composer, a group room's field and the full editor (`UIFont.preferredFont(forTextStyle:in:)`) grow the same way wherever the system draws the stepped size smaller than iOS does, to the same size as the transcript: both land on iOS's body size for the stepped size, whatever the system draws at the column's base (`columnText`), and nothing is added outside a stepped column.
- On a Mac a column's text doesn't step: it grows by point size in proportion to the column, transcript, cards, composers and SwiftUI text alike. A Mac build showed an iPad app there draws every text style at its default size for any Dynamic Type size (body 17, title2 22 pt), and only a point size grows; it also draws at about 77%, so iOS's largest standard size (23 pt) looks like ordinary Mac text and a 1040 pt column a narrow strip. So on a Mac the column takes 80% of the window, its text at the system's size until its lines hold 1.5 times a phone's words (1140 pt for a chat), then growing with it, up to 2.2 times (a 2508 pt chat column), the margins past that (Eric, 2026-10-29, #1503: the 1040 pt column looked far too narrow on a maximized Mac; he chose text that keeps growing so lines stay a readable length, and to have buttons and Settings grow with the chat's text). The app sets every text style with `scaledFont`, which is the text style itself wherever the system grows text styles, and in such a column the style's default size (what a Mac draws at any system size) times the column's scale (`ColumnText.scale`, in twentieths so a window drag re-lays the transcript only a few times), the column's plain text included. Navigation bar titles are UIKit's and keep their size. The Watch app and widgets keep `font`: they never sit in a wide column. An iPhone or iPad keeps the steps and the caps above.
- Settings' column widens with the window as a chat's does, from 720 pt up to 980 pt, and its text steps up the same way from 720 pt (Eric, 2026-10-29, #1478: he expected Settings to scale too). This replaces Settings' fixed 720 pt from the 2026-10-26 ruling (#1320) below, which now keeps only a list shown alone and calls fixed.
- The chat's column and its text steps measure the room the list leaves, so a list dragged wider (Resizable columns on a split window) narrows the chat's column and may take a step back, as hiding the list adds one (2026-10-29, #1498; the behavior since #1492).
- A list shown alone (720 pt) and calls (640 pt) keep fixed widths: rows, cards and captions don't read better wider. The sign-in screens keep their own 560 pt column, which follows the text size (2026-10-26, #1320).

**Open gaps**
- Resizing a wide window changes the chat's column, so a card or picture's kept height is for another width and it grows once more (the gap in Cards drawn in web pages).

**Checked:** 2026-10-29, #1514 (a Mac composer's first frame at the column's height; sheets from the chat column noted in Code). Earlier 2026-10-29, #1512 (the drawer shell's chat column also sets whether its composer stays expanded, composerLayoutFromWidth; see Composer at rest and expanded); #1503: on a Mac, a column takes 80% of the window and its text, text styles through `scaledFont` included, grows by point size with it. Earlier 2026-10-29, #1498 (a dragged list narrows the chat's column, from #1492; Rulings); 2026-10-29, #1507 (the listed cards' text moved below their caption row, sizes unchanged); 2026-10-29, #1478: transcript text grows by point size so a Mac scales it; Settings widens and steps its text; 2026-10-27, #1393; 2026-10-26, #1320.

## A split window's columns fill the window

A wide window's columns (an iPad, a Mac, an iPhone Duo's inner screen in
landscape) draw their backdrop to the window's edges, as a one-column screen
does.

**Siblings:** the Chats list column · the Bots list column · the chat column
(a chat, its side panel, the empty column, Settings beside the list) · the
drawer shell's persistent sidebar beside its chat (Appearance, V2 off), never
clipped · the one-column screens they match (Tasks, a list shown alone, a
phone)

**Code**
- `Conduit/Views/V2/V2Shell.swift` (splitColumns, v2ClippedToColumn)
- Drawer shell: `Conduit/Views/RootView.swift` (sidebarLayoutContent)
- The line between them: `Conduit/Views/Components/ColumnDivider.swift` (ColumnDivider, which drags a column's width: Resizable columns on a split window)
- The backdrop: `Conduit/Theme.swift` (ConduitBackdrop ignores the safe area)

**Rulings**
- Each column's backdrop stays clipped at the divider, so the glows don't cross it, and runs under the window's safe areas at the top, the bottom and its own outer side: the home indicator, and a landscape status bar or sensor. Clipped at the safe area, every split tab showed black bars along the bottom and the right of an iPhone Duo's inner screen while Tasks filled it (2026-10-29, #1472, a tester's report).

**Open gaps**
- Not seen on a device yet: the simulator suites have no Duo before Xcode 27.1, so a Duo or a split iPad from TestFlight confirms it.

**Checked:** 2026-10-29, #1498 (ColumnDivider's store rules and drag direction are ColumnWidth functions; the layout is unchanged); 2026-10-29, #1492 (the 1 pt line between the columns is a draggable ColumnDivider above them; the drawer shell's sidebar threshold counts it); 2026-10-29, #1472.

## Resizable columns on a split window

The line between a wide window's list and its chat, and between the chat
and Artifacts beside it, drags the column's width (#1487).

**Siblings:** the Chats list column · the Bots list column · Settings
beside the list (it opens in the chat's column) · a group room beside the
list (the list drags; a room has no Artifacts) · Artifacts beside a chat ·
the drawer shell's persistent sidebar (Appearance, V2 off) · the tab bar
under the list (Voice beside the tabs) · the chat's readable column (it
measures the room left to it; done, Readable width's ruling, #1498) · hiding the list (#1164: the
width comes back with the list) · Settings > Appearance > Layout's caption
in both shells (the drawer shell's only while its persistent sidebar is
on) · not needed: README.md (it doesn't describe the split
layout)

**Code**
- Widths and the line: `Conduit/Views/Components/ColumnDivider.swift` (ColumnWidth: resolved, dragged; ColumnDivider)
- List: `Conduit/Views/V2/V2Shell.swift` (V2SplitLayout.listWidths, V2SplitLayout.ListColumn, V2SplitLayout.chatKeeps, sizedTabs, tabs, splitColumns)
- Artifacts: `Conduit/Views/V2/V2ConversationScreen.swift` (ChatSidePanel.widths, sidePanelWidth)
- Drawer shell: `Conduit/Views/RootView.swift` (sidebarLayoutContent, persistentSidebarWidth), `Conduit/Views/SidebarLayout.swift` (SidebarLayoutMetrics.persistentSidebarWidths)
- Caption: `Conduit/Views/AuxiliaryViews.swift` (Layout)
- Widths and the line: what a drag or a VoiceOver step stores is ColumnWidth.storedAfterDrag and storedAfterStep, its direction ColumnWidth.dragSign
- Tests: `ConduitTests/V2SplitLayoutTests.swift` (testDraggedColumnWidthsKeepToTheirBoundsAndTheWindow)

**Rulings**
- Both lines drag: the list (375 to 560 pt; it can't go under the tab bar's width) and Artifacts (300 to 720 pt, standard 340 pt); the drawer shell's sidebar 320 to 520 pt. A double-click or double-tap resets a line; VoiceOver adjusts it by 40 pt or resets it (Eric, 2026-10-29, #1492, issue 1487).
- Each width is kept per device, as hiding the list is, not synced. A window smaller than a width needs gives the column what's left beside the chat's least width (430 pt); a window splits, and Artifacts shows, at the standard width whatever the user's, so a widened column never takes them away (2026-10-29, #1492).
- Under a widened list the tab bar keeps its width, centered under the list's column (2026-10-29, #1492).
- A window with room for Artifacts beside a chat at the list's standard width keeps that room whatever the list's width, the panel open or not: widening the list never hides the panel or its toggle, and the list doesn't jump as a chat or the panel opens. The list's most is then the window less 772 pt: 408 pt on a 1180 pt iPad in landscape, 422 pt on an 11-inch's 1194 pt, the full 560 pt on a maximized Mac. Artifacts beside the chat then reaches the window less the list and 432 pt (the chat's 430 pt and two lines): about 373 pt on 1180 pt, 387 pt on 1194 pt. Where the panel starts to fit, at a 1147 pt window, the list's most drops from 560 pt to its standard 375 pt: one point narrower it keeps only the chat's least width, one point wider the panel's room as well. The drop stays: it shows only while resizing a window across that width with a widened list, and either way round it costs more (Eric, 2026-10-29, #1498; the layout since #1492).
- A drag lays the column out at its live width and stores it once, when the drag ends or is cancelled: every defaults write redraws each `@AppStorage` view. A press that doesn't move the line (under 4 pt) keeps the stored width, which a smaller window may show less of (2026-10-29, #1492, from review).
- The caption shows only with the setting that puts a line on a wide window: the list set beside the chat (V2), the persistent sidebar on (the drawer shell); a window too narrow to split still shows it (2026-10-29, #1492, from review).
- A drag follows the pointer right to left too: there a leading column is on the right, so dragging left widens it. VoiceOver finds the line by its 12 pt grip, not the 1 pt line (2026-10-29, #1498, from #1492's review).
- The drawer shell's sidebar is named "Chat list width" as V2's list is: both hold the chats (2026-10-29, #1498, from #1492's review).

**Open gaps**
- No resize cursor on a Mac: a Designed-for-iPad app can't set one from SwiftUI on iOS 17, so the line highlights on hover and a tooltip names it.
- Not seen on a device yet: a Mac or iPad from TestFlight confirms it.

**Checked:** 2026-10-29, #1498 (store rules, right to left, the grip's VoiceOver frame, the 1147 pt drop; Code, Rulings); 2026-10-29, #1492.

## Voice on a profile the dashboard didn't start with

Voice and Watch calls, chat takeover, Desktop views, predictions, and
making a room with linked people and getting a Hermes ready for rooms, on a
profile other than the one the Hermes dashboard started with. Hermes 0.22.3+ (PLG-3) runs such a profile's plugin requests in
a plugin host of its own, which carries no WebSockets and none of the
dashboard process's state, so these routes take the profile as
`?conduit_profile=` and stay in the dashboard (#1336).

**Siblings:** Local Live (status, key, the call socket, Classic's speak
socket) · Classic voice listening on a speech server · Grok Live's relay
socket · Watch calls (tool grant, revoke, audio status and prepare) · chat
takeover (claims are judged by the dashboard's pid) · Desktop views (the
hook watches the dashboard's gateway) · predictions (they fork the gateway's
chat) · the plugin update nudge (the `dashboard-profiles` capability) · Local
Live's reason when it runs in a plugin host · Linked Rooms' new drafts and
room setup (their own capability, `room-dashboard-profiles`), and the setup's
restart, which a plugin host never starts · the notifier README and
CHANGELOG · not needed: Gemini, Qwen and GPT-Live tokens, Grok Live's status,
the speech server's status and test (they read the profile's settings and dial
the server over plain HTTP), Hermes calls, chat on screen and the other routes
kept in the profile's home (plain HTTP and files, which work in the host), and the turn surface (sent without a
profile, so it already reaches the dashboard)

**Code**
- App: `Conduit/Services/DashboardPath.swift` (conduitProfileParameter), `Conduit/Services/NotifierPluginStatus.swift` (dashboardProfileParameter, usedCapabilities), `Conduit/Voice/LocalLive/LocalLiveClient.swift`, `Conduit/Voice/GrokLive/GrokLiveClient.swift`, `Conduit/Voice/HermesVoiceGateway.swift` (profileParameter, rebuilt by AppState's read-aloud currency check when it changes), `Conduit/Voice/SpeechServerTranscription.swift`, `Conduit/Voice/SpeechServerSpeech.swift`, `Conduit/Voice/HermesVoiceConfigurationService.swift`, `Conduit/Watch/WatchToolGrantClient.swift`, `Conduit/Services/ChatTakeover.swift`, `Conduit/Services/AppState+Predictive.swift`, `Conduit/Services/AppState.swift` (the Desktop views read), `Shared/LocalLive/LocalLiveProtocol.swift`
- Notifier: `notifier/dashboard/api/core.py` (_conduit_route_profile), `notifier/dashboard/api/local_live.py` (LOCAL_LIVE_PLUGIN_HOST_REASON), `notifier/dashboard/api/capabilities.py` (ROUTE_CAPABILITIES), `notifier/dashboard/api/linked_rooms.py` (post_room_draft, get_room_setup, post_room_setup and _restart_room_gateway's plugin host guard), `notifier/README.md`, `notifier/CHANGELOG.md`, `notifier/upstream/contract.yml` (the notes on these routes and the plugin host flag)
- Tests: `ConduitTests/HermesVoiceGatewayTimeoutTests+LocalLive.swift`, `ConduitTests/ChatTakeoverTests.swift`, `notifier/tests/test_local_live.py`, `notifier/tests/test_grok_live.py`, `notifier/tests/test_room_setup.py`, `notifier/tests/test_room_invites.py`

**Rulings**
- A workaround until Hermes' plugin host carries WebSockets (asked for on NousResearch/hermes-agent#140051). Conduit sends `?conduit_profile=`, which Hermes doesn't route on, only to a plugin that lists `dashboard-profiles`; an older plugin keeps `?profile=`. The plugin scopes the route to that profile after Hermes' own consent check there, and refuses a Hermes Desktop ticket for any profile but its own, as `?profile=` does (2026-10-27, Eric, #1336).
- The dashboard's own profile ("default") goes without `?conduit_profile=`. With `dashboard-profiles` the Grok Live and listening sockets leave it out too; with an older plugin they keep the `?profile=default` they always sent. Hermes' own `/api/audio/*` routes (Classic's speak and transcribe) aren't plugin routes and keep `?profile=`.

- Which routes need it: those that read the dashboard process's own state (its gateway's chats, Hermes' websocket auth, Local Live's key registry and calls, the Watch bridges) or open a socket. A route that only reads and writes the profile's home works in the host and keeps `?profile=`.
- Linked Rooms' `POST /rooms/drafts` and `GET`/`POST /rooms/setup` take it too: a draft starts in the room service of the profile's session authority, which only the dashboard has (made in a plugin host, it starts in the legacy service), and the setup writes the installation's `.env` and restarts the gateway as the dashboard does. They have their own capability, `room-dashboard-profiles`, since a plugin that lists `dashboard-profiles` without them would act for the dashboard's own profile. `/rooms/choices`, `/rooms/defaults` and `DELETE /rooms/sessions` keep `?profile=`, and the Links, invites and approvals routes take no profile. A setup served in a plugin host (an older Conduit's `?profile=`) saves but never restarts the gateway, which came back with the host's environment, Hermes' plugin host flag among it, and `restart.error` says so (2026-10-27, notifier #419).

**Open gaps**
- Drop the workaround once Hermes' plugin host carries WebSockets.
- Pulse's app side is on its branch, not main: when it calls its routes for such a profile, check them against this entry.
- Linked Rooms' app side, on the `linked-rooms` branch, sends `?profile=` to the setup until C3, which sends `?conduit_profile=` to it and to new drafts when the plugin lists `room-dashboard-profiles`. Until then the branch's setup for such a profile saves without restarting the gateway and says to restart it. Of the rooms routes, only a draft starts Linked Rooms' loops, so one made with `?profile=` (an older plugin) starts them in the plugin host too, where they wait on the lease the dashboard holds.

**Checked:** 2026-10-28, #1462 (the notifier code it lists moved from dashboard/plugin_api.py to dashboard/api/, one module per feature, notifier #449); 2026-10-27, #1360 with notifier #419 (Linked Rooms' drafts and setup); #1344 with notifier #412 (every plugin route checked for the dashboard process's state).

## Running and Needs approval in the chats list

Which listed chats show Running (a turn on Hermes) or Approve (Hermes waits on
the user), read from the dashboard's live registry (`session.active_list`)
and, for the open chat, from its own turn.

**Siblings:** the Chats list's rows and nests ("1 running · 1 to approve") ·
All profiles (another profile's rows) · a project's page (its rows and header
count) and the Projects view's running counts · the Status filter's Running
and Needs approval, and the filter's amber dot · iPad and Mac beside the open
chat (the list or a project's page stays on screen) · the drawer shell's
sidebar (V1, polls whenever it shows) · the open chat's own Working line ·
the Lock Screen's Live Activity, settled from the same reads (Reply progress
signals) · not needed: Bots (a bot's chats live in the bot's own list), CarPlay's
and the widget's pickers (no status), and no Settings caption or doc names it

**Code**
- Status: `Conduit/Services/AppState.swift` (sessionLiveStatus, refreshLiveSessionStatuses, recordActiveListEvidence, chatListPollTick), `Conduit/Services/SessionLiveStatusIndex.swift`, `Conduit/Services/PowerPolicy.swift` (ChatListPollPacer)
- Rows: `Conduit/Views/V2/V2SessionRow.swift` (V2SessionStatus, v2RowStatus), `Conduit/Views/V2/V2ChatsView.swift` (the poll's task, showsLiveRows, nestSummary, V2ProjectRow), `Conduit/Views/V2/V2ProjectPage.swift`, `Conduit/Views/SidebarView.swift`
- What the list column shows: `Conduit/Views/V2/V2Shell.swift` (V2SplitLayout.showsChatRows)
- Tests: `ConduitTests/AppStateChatResumeTests.swift` (testOpenChatLiveStatusPrecedence, testAnotherProfilesRowInAllFollowsTheRegistry), `ConduitTests/V2SplitLayoutTests.swift` (testV2ListColumnKeepsLiveRowsBesideTheChat)

**Rulings**
- The open chat's own turn decides its Running once known; Needs approval from the registry outranks it (#454).
- The dashboard's registry lists every profile's live chats (checked on Hermes 0.22.5, with or without a `profile` param), so another profile's row in All reads it too. A chat left running for one in another profile keeps Running, as one in the same profile does (2026-10-27, #1369, issue #1353).
- The registry is read while the list or a project's page is on screen. Beside the open chat on a wide window both stay on screen, so the poll keeps running there; one column, a chat pushed over them stops it (2026-10-27, #1369, issue #1353).

**Open gaps**
- Rows carry no profile, so a running chat in one profile lights a row of another with the same stored id (a profile copied with its chats) while that turn runs.
- After a send, the registry can read the turn as not started yet, and the next read comes 4 s later: a chat left within those seconds goes without Running until then.

**Checked:** 2026-10-27, #1369.

## Swiping list rows on a Mac

A list row's swipe actions in the iPad app on a Mac, and what keeps a mouse
wheel over such a list from crashing.

**Siblings:** every List with swipe actions (the Chats list's and a project
page's rows in V2, the drawer sidebar's chat, project and project-sheet rows,
Bots, Tasks' scheduled jobs (V2), the drawer sidebar's scheduled-jobs list, pinned replies, the Pulse page's cards and brief
items, Pulse memory) · each row's right-click menu · not needed: iPhone and
iPad (swipes unchanged) · text: no Settings caption or doc describes it

**Code**
- Guard and Mac-only menu: `Conduit/Services/MacWheelSwipeGuard.swift` (MacWheelSwipeGuardProbe, MacWheelSwipeGuardRecognizer, macSwipeActionsMenu), installed by `Conduit/ConduitApp.swift`
- Swipe-only rows: `Conduit/Views/V2/V2PulsePage.swift` (Not now), `Conduit/Views/PulseSettingsViews.swift` (Forget)
- Tests: `ConduitTests/MacWheelSwipeGuardTests.swift`

**Rulings**
- On a Mac, UIKit's row swipe recognizer takes no scroll events: a notched mouse wheel's events carry no raw delta, which that recognizer asks for, and newer macOS asserts on it ("Missing expected nonaccelerated scroll delta", issue #1480). Hovering a list, or a list opening under a resting pointer, clears the recognizer's allowedScrollTypesMask, which UIKit checks before the delta. A trackpad no longer swipes rows on a Mac, so a row whose actions are only in its swipe gets them on a right-click menu there (Eric ruled 2026-10-30, #1528: accept losing trackpad row swipes on a Mac to stop the crash).

**Open gaps**
- A list that opens under a pointer that hasn't moved is guarded within a quarter second (the resting check); a wheel turned there sooner isn't covered.
- After a launch, nothing is guarded until the pointer first moves in the window: a wheel turned over a list before then, with the pointer resting where it was, isn't covered (whether a Mac sends a hover as the window opens under the pointer isn't checked).
- A Pulse card with no Not now (done, cleared, or a plugin without it) gets an empty right-click menu on a Mac, as its swipe is empty.
- Not reproduced on a device: the reporter's macOS version isn't known yet, and 26.6.2 refuses the event instead of asserting.

**Checked:** 2026-10-30, #1528.

## Crash and freeze reports

After Conduit crashes or freezes, iOS hands it a MetricKit diagnostic on the
next launch; Conduit asks once, on a card over the main screen, whether to
send it to its developer, and Send posts it to Conduit's relay. The chat
recorder keeps what the transcript did, in every build; a watcher saves it
as a chat trace when a chat jumps, stops scrolling or freezes, and the trace
rides with the freeze's report or goes from Diagnostics & logs.

**Siblings:** the card over the main screen (both shells; the iPad app on a
Mac too) · Settings > Connection > Diagnostics & logs (its Device reports
caption, the shared reports file's `about` line, and Chat traces: its
captions, Send and Share) · the chat recorder's watchers in chats, project
chats, Bot Chat and Kanban workers' transcripts (one ChatView) and in group
rooms · the relay's route and store (notifier relay) · the privacy policy and
the relay README (notifier) · this README's Privacy section · the app's
privacy manifest (`Conduit/PrivacyInfo.xcprivacy`, crash, performance and
other diagnostic data, not linked, and its test) and App Store Connect's
privacy label (the maintainer's) · not needed: the Apple Watch (watchOS has
no MetricKit), CarPlay (the phone's card shows when the app is next opened,
and it draws no transcript), the widgets and the share extension (they don't
keep MetricKit reports or draw a transcript), a delegate agent's tail sheet
and a call's transcript sheet (short logs with lists of their own), Desktop's
read-only legacy groups (no transcript to watch)

**Code**
- Offer and upload: `Conduit/Services/CrashReportOffer.swift` (CrashReportUpload: what a report sends; CrashReportQueue; CrashReportOffer)
- Which diagnostics are offered: `Conduit/Services/MetricKitReports.swift` (queueCrashReport; MetricKitReportStore.save, normalized and shallowed, which keep a stack overflow's payload readable)
- Card: `Conduit/Views/CrashReportBanner.swift`, shown by `Conduit/Views/RootView.swift` (MainView's top overlay)
- Settings: `Conduit/Views/ChatSupportSheets.swift` (DeviceReportsSection, ChatTracesSection)
- Chat recorder: `Conduit/Services/ChatViewportTrace.swift` (the ring, a line in the relay's characters), `Conduit/Services/ChatViewportWatch.swift` (jump, layout storm), `Conduit/Services/MainThreadHangWatchdog.swift` (stall, StallClock; started in `Conduit/ConduitApp.swift`), `Conduit/Services/ChatTraceStore.swift` (ChatTraceStore, ChatTraceUpload.sendAll); the trace riding with a report: CrashReportOffer's pendingReports and send, CrashReportUpload.body(chatTrace:) and post
- What feeds it: `Conduit/Services/TranscriptScroller.swift` (write, the mode's log, layoutChanged, transcriptChanged, roomTranscriptChanged (a group room's events), refreshReplyRoom, the reply hold armed or disarmed, renderedSessionChanged's switch, landAtReplyStartIfPending's landing, placeRestorationIfReady's restore at a row and armRestorationDeadline's restore abandoned), `Conduit/Views/TranscriptView.swift` (traceSurface: the collection view's size, insets and content height; offsetMoved from scrollViewDidScroll; the status bar's tap), `Conduit/Views/TranscriptLayout.swift` (rowResized: a row changing height, by id, the live turn's thinking and reply aside, which grow a line at a time), `Conduit/Views/ChatView.swift` (ChatViewportWatch.command, from the chat's commands and ChatJumpControls), `Conduit/Views/GroupChatView.swift` (the room's commands: its jump button, a send, Retry and the quoted jump; the room's transcript is a TranscriptView, which feeds it as a chat's does), `Conduit/Views/TranscriptModel.swift` (TranscriptModelBox: each change of the chat's rows, by id, and a chat row left out for an id an earlier row has)
- Relay: `notifier/relay/src/crash-reports.mjs`, `notifier/relay/test/crash-reports.test.mjs`; privacy: `notifier/docs/privacy/index.html`
- Privacy manifest: `Conduit/PrivacyInfo.xcprivacy`, `ConduitTests/PrivacyManifestTests.swift`
- Tests: `ConduitTests/ConnectionFailureTests+CrashReports.swift`, `ConduitTests/ConnectionFailureTests+MetricKit.swift` (testMetricKitSaveKeepsAStackThatOverflowed), `ConduitTests/ConnectionFailureTests+ChatTraces.swift`

**Rulings**
- Ask once, upload to the relay: Not now drops the report from the offer (it stays in Diagnostics & logs), and nothing is sent without Send (2026-10-29, Eric chose it in the TestFlight crashes thread; #1477, notifier #459).
- A report is the diagnostic's crashes and hangs, with the version, build, iOS version and device model, and a freeze's chat trace (below); an exception's composed message and arguments are left out, since they can quote anything. It goes to the developer's relay (`push.milim.dev`) even when the user's notifications use another relay, and carries no installation credential (#1477, notifier #459; the trace since #1554, in the transcript rewrite's design Eric approved on 2026-10-30).
- Only a crash or hang from the last 7 days is offered, checked again when the card would show, the newest 5 at most, and one too big to send even trimmed to its first crash and hang is not. Those an earlier build kept are queued once per device, on the first launch with the card. Send sends only the reports the card asked about. A relay that answers 404 (no `CRASH_REPORTS_TOKEN`) stops the offers from that build on that device; what's still queued waits for the next build, so a build that ships before the relay route is deployed loses nothing, and a report declined or sent isn't asked about again. The look at reports earlier builds kept waits for a launch that can list the folder and finds none or reads at least one of them (locked files before first unlock fail together); a single file that can't be read is skipped (part of the ask-once design Eric delegated in the TestFlight crashes thread, 2026-10-29; #1477).
- A report is built from named keys only (the diagnostic's metadata, exception and stack frames); a key MetricKit adds later stays on the phone until it's named (#1477). A stack keeps its first 240 levels (one that overflowed can nest thousands, which would overflow the walk too, and JSONSerialization reads and writes nothing nested past 512, which a sent level-L frame is at 7 + 2L), and the relay keeps at most 512 frame levels. The stored payload has every container 500 deep emptied, so a stack overflow's crash is kept and offered rather than refused as unreadable (MetricKit's root frame is the one that was running and its subFrames lead out toward the thread's entry, so the crash site is what's kept: a real crash payload posted on Apple's developer forums, attachment 18fdc26d-396d-4950-950f-e4d2dffa25cc, nests libsystem_kernel, CoreFoundation, GraphicsServices, UIKitCore, the app, then dyld, root first). Both numbers are Claude's pick, under the ask-once design Eric delegated in the TestFlight crashes thread, after the 0.24.0 deploy, 2026-10-29; Eric hasn't ruled on them (#1505, notifier #469).

- Chat traces are recorded in every build, TestFlight and App Store included. A line names counts, sizes, offsets, timings and what moved the chat (a command, the scroller's rule, a finger, momentum), never message text, titles or file names; it keeps only the relay's characters, at most 160, and a trace is at most 2,000 lines. Traces are kept in Application Support/ChatTraces, the five newest, not backed up, and go only on a Send: the report card's, which carries the newest stall trace saved within the diagnostic's span, or Chat traces' in Diagnostics & logs, which saves what the recorder holds (replacing the one an earlier Send saved) and sends it with every saved trace. A trace leaves the device once the relay says it kept it. A relay that refuses a report for its trace (413 before relay 0.25, 400 for a line it won't take) is sent the report again without it, and the trace stays (the transcript rewrite's design, after Eric asked for a chat that's easier to diagnose, 2026-10-30; #1554, notifier #481).
- What saves a trace, each at most once a minute. A jump: the offset moves more than a screen at once with no finger or momentum on it, and no command, resize or new scroll view in the second before (an animated write of the scroller's, 0.6 s). A layout storm: more than 30 layout passes a second for 3 seconds (a transcript, a chat's or a group room's, changing its frames, its size or its insets) with no row changing and nobody scrolling; a row changing height (a reply streaming in, a picture loading) counts as a row changing, and one that only moves doesn't. A stall: the main thread away 2 s; the watchdog stops in the background and starts over after a suspension (a stall it was suspended in isn't reported as ending), the trace says how long the stall lasted once it ends (in that stall's own trace, never an earlier one's), and a stall within a minute of the last trace stays in the recorder for the next one. The numbers are Claude's pick under the rewrite's design; Eric hasn't ruled on them (#1554; a chat's transcript feeding them since 2026-10-31, #1577, and a group room's since #1590, which took the blank-screen rebuild's trace away with the rebuild: one an older build saved still lists and sends).

**Open gaps**
- A kill for memory (jetsam) leaves no MetricKit diagnostic, so a freeze that ends that way is never offered.
- MetricKit may hold diagnostics back on a device that doesn't share analytics with developers.
- App Store Connect's privacy label doesn't yet list Crash Data, Performance Data and Other Diagnostic Data (not linked, not tracked), which the privacy manifest now declares (the last for chat traces); the maintainer updates it before the next App Store submission.
- A crash with no stall before it carries no trace: the recorder's lines are in memory until a watcher saves them.
- Until relay 0.25 is deployed, Send in Chat traces fails (the relay refuses kind chat) and a report's trace is dropped by the relay and kept on the phone.

**Checked:** 2026-10-31, #1590 (a group room's transcript feeds the recorder as a chat's does, through its own TranscriptScroller and collection view; the blank-screen rebuild and its trace are gone, the reason kept so a trace an older build saved still lists and sends; Siblings, Code, Rulings); 2026-10-31, #1577 (the chat's transcript feeds the recorder: TranscriptScroller's writes and passes, the collection view's size, insets and content height, a row changing height by id, but for the live turn's thinking and reply, whose growth would push out the moves a trace is for; a chat has no blank-screen rebuild; Code, Rulings); 2026-10-31, #1566 (TranscriptScroller writes through the same recorder: the engine's write, mode, transcript and room lines, plus its own for the reply hold armed or disarmed, a switch, a landing at the reply start and a restoration placed or given up; not called yet; traces unchanged; Code); 2026-10-31, #1565 (the recorder logs each change of the chat's rows by id; a stall the app was suspended in no longer reports an end counting the time away, and a stall's end goes only in its own trace; Code, Rulings); 2026-10-31, #1554 (chat traces: the recorder in every build, its watchers in chats and group rooms, the stall trace riding with a freeze's report, Diagnostics & logs' Chat traces, the privacy manifest's Other Diagnostic Data; notifier #481, relay 0.25.0); 2026-10-29, #1505.

## Feature map rules

How a change brings its connected features along, and how this map stays
current with nobody tending it.

**Siblings:** CONTRIBUTING.md (the full rules) · this map's intro · the PR
template · the reviewer prompt · the notifier's CONTRIBUTING.md, PR template
and reviewer prompt · the map check in CI · README.md and docs/CI.md, which
point at the map and its check

**Code**
- Rules: `CONTRIBUTING.md`, `docs/FEATURE_MAP.md` (the intro and the sibling sets), `.github/pull_request_template.md` (Siblings)
- Reviewers: `.github/workflows/opencode-review.yml` (the Connected features focus area)
- Notifier: `notifier/CONTRIBUTING.md`, `notifier/.github/pull_request_template.md`, `notifier/.github/workflows/opencode-review.yml`
- Map check: `scripts/check-feature-map.py` (paths, entry shape, and on a PR the Checked line of each entry it edits; on a PR into `pulse` or `linked-rooms` that merges main, main's maps where the PR and its base meet main tell which entries came from main), `scripts/tests/test_check_feature_map.py`, run by `.github/workflows/ci.yml` (Feature map paths exist; a PR into `pulse` or `linked-rooms` runs that branch's copy, whose trigger lists it), its PR number, base map and main's maps pinned by `scripts/tests/test_ci_workflow_contract.py`
- Pointers: `README.md` (Architecture), `docs/CI.md` (the plan job under Jobs)

**Rulings**
- A checked-in map, a Siblings section in every PR, and rulings in each entry; a sibling left out without a reason is a major review finding (2026-10-23, #1167, Eric).
- Nobody tends the map separately: the PR that changes a feature updates its entry, adds one for a connected feature that has none, adds a sibling an earlier change missed, and records the maintainer's rulings with the date and the PR (2026-10-24, #1178, Eric).
- CONTRIBUTING.md holds the full rules. The intro, the PR templates and the reviewer prompts each carry the part their reader needs, so a rule change starts in CONTRIBUTING.md and then reaches each copy (2026-10-24, #1178).
- The notifier's reviewers can't read this map, so a notifier PR names its entry, or the hermes-conduit PR that adds or updates it (2026-10-24, #1178).
- An entry a PR adds or edits names that PR on its Checked line, and CI fails one that doesn't; a commit is only for an entry seeded from main. A carry PR names both, like "#1188, carried in #1200". The PR template asks for a Siblings line for every sibling the entry lists, Settings and model-facing text included (2026-10-24, #1209, Eric).
- On a PR into `pulse` or `linked-rooms` that merges main, an entry main changed between where that branch last met main and where the PR meets it, and that matches main's copy there, came in with main and keeps main's Checked line, so bringing main into the branch doesn't name the merge on every entry main changed. A PR into either that doesn't merge main gets no such pass, and neither does an entry main didn't change (2026-10-25, #1248; the first such merge after #1209 failed the check on 48 entries). `linked-rooms` gets the pass as `pulse` does, since Eric asked for the Linked Rooms app side on a branch like `pulse` (2026-10-26, #1287).
- A refactor that changes no behavior and no user-facing or model-facing text (moving code, or changing how state is stored or observed) has no siblings: its PR says "No mapped feature" and adds no new entry, and reviewers don't ask for one. If it moves code an entry's Code lists, it updates those paths and the Checked line (2026-10-25, #1271, Eric; reviewer prompts and notifier copies in #1273 and notifier #377).

**Open gaps**
- A connection nobody has noticed yet isn't caught by any check; it goes in the first time a fix turns it up.
- A notifier PR that moves a file listed here fails the next hermes-conduit PR's map check, not its own.
- A PR that changes a mapped feature's behavior without touching its entry isn't caught by CI; a reviewer flags it (minor). A refactor that changes no behavior is exempt unless it moves a listed path.
- On a merge of main into `pulse` or `linked-rooms`, an entry both sides changed that the merge settles on main's copy keeps main's Checked line, so CI doesn't flag dropping the branch's edit; a reviewer checks that choice. CI only sees content, and that copy is main's word for word.
- If GitHub can't say whether a PR into `pulse` or `linked-rooms` merges main, or can't give main's maps, the step warns and checks without them, so a merge of main fails on the entries it brings in until a re-run.

**Checked:** 2026-10-26, #1314.
