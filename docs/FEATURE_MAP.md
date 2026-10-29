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
adds that sibling to the entry. [CONTRIBUTING.md](../CONTRIBUTING.md) has the
rules.

An entry holds the current state only; history stays in the PRs it cites.
Keep each to about a screen, and split one that grows past that. Every entry
has Siblings, Code, Rulings, Open gaps and a Checked line (the date of the
last check against the code, and the PR that checked it; an entry seeded from
main may name a commit). `scripts/check-feature-map.py` runs in CI: it checks
that shape, that every path in backticks exists, and that an entry a PR adds
or edits names that PR on its Checked line (on a PR into `pulse` that merges
main, one main changed since `pulse` last took it that matches main's copy came
in with main). A path that starts with notifier/ is in
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
rooms · the resume jump · what models and Settings say about it

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

**Code**
- Chat card: `Conduit/Views/ChatView.swift` (ApprovalCard, ClarifyCard), `Conduit/Services/ApprovalDisplayText.swift`, `Conduit/Services/AppState.swift` (respondToApproval, legacyApprovalTarget)
- What waits, and spoken picks: `Conduit/Voice/HermesCallWaiting.swift` (block, answerRule, pickedChoices, spokenQuestion)
- Classic and Local Live: `Conduit/Services/AppState+SpokenApprovals.swift` (answerQuestionBySpeech, noteClarifyForClassicVoice, openChatWaitingCards), `Conduit/Voice/SpokenApprovals.swift`, `Conduit/Voice/VoiceConversationController.swift` (noteApprovalWaiting), `Conduit/Views/VoiceConversationSheet.swift` (VoiceApprovalPanel), `Conduit/Voice/LocalLive/LocalLiveTurnRunner.swift` (approvalLine, waitingQuestion)
- Live modes: `Conduit/Voice/VoiceBackgroundJobs.swift` (waitingNotice, answerJobApproval, answerJobQuestion), `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift`, `Conduit/Voice/GPTLive/GPTLiveConversationController.swift` (jobApprovalRule), `Conduit/Views/LiveVoiceCallJobs.swift` (LiveVoiceWaitingPanel), `Conduit/Views/LiveVoiceCallSheet.swift`
- Call from Hermes: `Conduit/Voice/HermesCalls.swift` (instructionBlock), `Conduit/Services/AppState+HermesCalls.swift` (liveHermesCallInstructions, noteHermesCallChatWaiting, answerHermesCallApproval, answerHermesCallQuestion, watchHermesCallWaiting)
- Phone changes: `Conduit/Phone/PhoneChangeConfirmation.swift`, `Conduit/Phone/PhoneVoiceTools.swift` (confirmsChange)
- Call-screen confirmations: `Conduit/Services/PresentedScreens.swift` (PresentedConfirm.isConfirmed), `Conduit/Voice/VoiceBackgroundJobs.swift` (VoiceThreadRouting.containsRefusal), tests in `ConduitTests/PresentedScreensTests.swift`
- Watch: `ConduitWatch/WatchCallView.swift` (WatchApprovalCard), `ConduitWatch/WatchDirectCallModel.swift` (answerCallThroughRelay, answerApprovalByVoice, answer: said as a text update when the call reconnects), `ConduitWatch/WatchBridgeCallModel.swift` (answerCall), `Shared/WatchVoice/WatchCallAnswer.swift`, `Shared/WatchVoice/WatchJobRelay.swift`, `Conduit/Watch/WatchDirectBroker.swift` (grants), `Conduit/Watch/WatchToolGrantClient.swift` (answer_sessions, answer_approvals), `Conduit/Watch/WatchSettingsSection.swift`
- Group rooms: `Conduit/Views/GroupChatView.swift` (GroupApprovalCard)
- Resume jump: `Conduit/Services/ChatResumeCoordinator.swift` (pendingClarifyMessageID), `Conduit/Views/ChatView.swift` ("Go to your question", "Go to the approval")
- Settings text: `Conduit/Views/GeminiLiveViews.swift`
- Notifier: `notifier/events.py` (the push), `notifier/clarify_loop.py` (a call's answer wins), `notifier/calls_store.py` (the waiting copy, map_answer), `notifier/calls.py` (follow_approval), `notifier/__init__.py` (the approval hook), `notifier/dashboard/plugin_api.py` (/calls/waiting, answer_call, _local_live_call_answer), `notifier/phone_tool.py` (the wording models read)

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
- The resume jump and its button go to the newest question or approval waiting on the user (2026-10-24, #1194).
- A voice mode says an approval went only once Hermes took it: the phone's modes read the gateway's `resolved` count (expired otherwise), and the Watch's `answer_call` and Local Live wait up to 10 seconds for the plugin's follower to settle it, saying it didn't go through when no pending request was the one read out, and taking back an answer nothing picked up (2026-10-24, notifier 0.70.1).

**Open gaps**
- Group rooms: the card's failure line shows the error text raw, while the chat card reveals hidden characters in its error and expiry text (#951 follow-up).

**Checked:** 2026-10-25, Qwen in the siblings, the table and the Watch row, at #1182, carried in #1235; 2026-10-24, at #1221, for a Watch call's answer or voice approval whose reply lands while the call reconnects (said as a text update, not dropped); at #1207 (notifier 0.70.1), for the Watch's "approved" when nothing ran; at #1194 (after #1188, the approval card's shield); at #1191: message.interim ends a Local Live reply's approval wait and a voice job's needs-input state, as other output does (#912 review); the chat card's #951/#952 follow-ups; the call-screen confirmation's refusal veto (#1042).

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
| Classic | speech while Hermes thinks steers it | talking over the reply starts a new turn |
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
- Notifier (Watch relay jobs run on the host): `notifier/dashboard/plugin_api.py`

**Rulings**
- The voice model judges what the user meant, Conduit enforces and routes it, and Hermes reads the user's own words (2026-10-08, #451).
- "Add" goes as `session.steer`; "change", hold and cancel go as `session.redirect`. No kind, or a refused steer, falls back to redirect. The same in every live mode (2026-10-21, #1157).
- An unattached call with one running job and no job number follows up into that job; "New job:" starts another (2026-10-09, #472).
- Steering in the chat never waits for an OK (2026-10-08, #451).

**Open gaps**
- After a steer the model is still told Hermes "changes course now": steer and redirect both end as `.interrupted`, and the text has four copies, in `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift`, `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift`, `Shared/WatchVoice/WatchJobRelay.swift` and `Shared/WatchVoice/WatchBridgeDelegation.swift` (#1157).

**Checked:** 2026-10-25, Qwen in the siblings and the table, at #1182, carried in #1235; 2026-10-23, seeded from main at 64d53c3.

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
- Job lists (list_jobs, Classic's status, GPT-Live's status note): `Conduit/Voice/VoiceBackgroundJobs.swift` (listedJobs), `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift` (listResult); the Watch's: `Shared/WatchVoice/WatchJobRelay.swift` (listing), `ConduitWatch/WatchDirectCallModel.swift` (apply, for the iPhone's answer), `Conduit/Watch/WatchDirectBroker.swift` (listedJobs; result, for the jobs the iPhone runs), `Shared/WatchVoice/WatchVoiceWire.swift` (DirectToolResult.newsJobs), `notifier/dashboard/plugin_api.py` (_WatchJobs.list)
- Watch: `Shared/WatchVoice/WatchJobRelay.swift` (notice), `ConduitWatch/WatchDirectCallModel.swift` (checkNewsSpoken, answer, lostAnswerText), `ConduitWatch/WatchBridgeCallModel.swift` (checkNewsSpoken), `Conduit/Watch/WatchDirectBroker.swift` (lateAnswers, jobRefusal)
- Notifier (Watch relay jobs): `notifier/dashboard/plugin_api.py`

**Rulings**
- A result never talks over the user: it waits for a quiet moment, and the model answers what the user just said first (2026-10-04, #381).
- Results show during the call as job cards on the call screen, on the phone only, with no writes to the host mid-call (2026-10-03, #364).
- The saved transcript links each job the call started, drawn as a card (2026-10-03, #358; 2026-10-18, #758).
- Local Live agent calls announce results; calls that hand each turn to Hermes drop them (2026-10-23, #1160).
- A result that can't go out now is kept, never dropped: GPT-Live's quiet replies wait with the spoken ones, and replies still on their way when a conversation ends or is replaced go back to pending, as Gemini's unsent answers become text updates (2026-10-24, #1223).
- On the Watch, a job answered as accepted that Hermes then refuses is taken back as news, and an answer that can't go on its call while the session reconnects is said as a text update, as the phone's fallback is (2026-10-24, #1221).

**Open gaps**
- GPT-Live's model can't put a card on the call screen: Gemini, Grok and Local Live agent have `show_on_screen`, GPT-Live has no marker for it. Cards Hermes shows still appear (#366).

**Checked:** 2026-10-25, Qwen in the siblings, at #1182, carried in #1235; at #1224: a result counts as told once the model says something after it or once it has gone out twice (one resend, GPT-Live and Watch included), and a job stays on the job lists until then (#1210), a direct Watch call's iPhone-run jobs included; one already sent when the call ends counts as told, never carried into the next call. Earlier at #1223, for GPT-Live's replies that couldn't go out; at #1221, for the Watch's late refusals and answers lost to a reconnect; at 78f21da; at #1191; at #1220: a cut screen card reads fences as "Code fences in messages" says.

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
- Notifier: `notifier/phone_tool.py`, `notifier/health_tool.py`, `notifier/location_tool.py`, `notifier/maps_tool.py`, `notifier/conduit_first.py`, `notifier/dashboard/plugin_api.py` (/voice-tools), `notifier/relay/src/watch-tools.mjs`

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

**Checked:** 2026-10-25, Qwen in the siblings, and a Watch token minted after consent was withdrawn, at #1182, carried in #1235; 2026-10-24, at #1223, for send_request's yes; 2026-10-23, seeded from main at 64d53c3; at #1191, Location's rule delete says when no dashboard is open (#972 review), which changes nothing about consent.

## Starting a call

Every way a call starts, and which chat it joins.

**Siblings:** the chat's voice button (chats, project chats, Bot Chat) · the
top bar's call button · Home's main button · the sidebar's New voice call ·
Siri, Shortcuts and the Action button · the wake phrase · widgets · CarPlay ·
the Apple Watch · Resume Call · group rooms · a call from Hermes (its own
entry)

**Code**
- Start paths: `Conduit/Voice/VoiceTypes.swift` (PendingVoiceIntent.Source), `Conduit/Services/AppState.swift` (prepareVoiceConversation, voiceWaitsForRunningTurn)
- Which chat: `Conduit/Services/AppState.swift` (liveVoiceThreadForOpenChat, savedCallToResume)
- Chat voice button: `Conduit/Views/V2/V2VoiceButton.swift`, `Conduit/Views/V2/ChatVoiceButtonAction.swift`, `Conduit/Services/AppState+VoiceMessage.swift`, `Conduit/Voice/VoiceMessageRecorder.swift`
- Siri and Shortcuts: `Conduit/Intents/StartVoiceConversationIntent.swift`; wake phrase: `Conduit/Voice/Wake/WakeLifecycleCoordinator.swift`
- CarPlay: `Conduit/CarPlay/CarPlayVoiceCoordinator.swift` (prepareWaitingForConnection, establishLiveVoice), `Conduit/CarPlay/CarPlayBrowseTemplates.swift`
- A start's late answers: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift` (callEpoch, isStarting; Gemini, Qwen, Grok, Local Live), `Conduit/Voice/GPTLive/GPTLiveConversationController.swift` (startAttempt), `Conduit/Voice/VoiceConversationController.swift` (operationGeneration), `ConduitWatch/WatchDirectCallModel.swift` (callID)
- Watch: `ConduitWatch/WatchHomeView.swift`, `ConduitWatch/TalkToHermesIntent.swift`
- A chat open elsewhere: `Conduit/Services/ChatTakeover.swift` (ChatTakeoverPreference), `Conduit/Services/AppState.swift` (submitComposerForCall, sendCallPromptTakingOver)
- How an attached call behaves: `docs/VOICE_BACKGROUND_JOBS.md`

**Rulings**
- A live call started from a chat joins that chat for the whole call, and its requests become the chat's turns; started anywhere else, it stands alone (2026-10-02, #312). An empty chat counts as a chat (2026-10-16, #679).
- In a chat with a saved call, the voice button resumes that call (2026-10-16, #679).
- A call always takes over a chat that Desktop holds, whatever the setting, and "Take over automatically" is on by default (2026-10-21, #1066).
- Classic can't start while a reply runs; live calls start beside it (2026-10-18, #767).
- The chat's voice button does what the user picks: Live call, Voice message or Dictation, for all profiles or per profile (2026-10-22, #1134).
- A start that was stopped, or that a newer start replaced, changes nothing when its checks answer late, in every voice mode; a CarPlay start waiting for Hermes stops quietly when the voice mode changes, and the next tap starts the new mode (2026-10-24, #1223).

**Open gaps**
- Group rooms have no voice button setting, and the Watch and CarPlay don't follow it (#1134).
- When a Classic call can't take over its chat, it shows a generic error (#1066).

**Checked:** 2026-10-25, Qwen starts through the shared controller, at #1182, carried in #1235; 2026-10-24, at #1223, for a start's late answers and CarPlay's mode switch; 2026-10-23, seeded from main at 64d53c3.

## Ending a call and what gets saved

What happens to a call's words, its jobs and Hermes' memory when it ends.

**Siblings:** a call joined to a chat · a call on its own · a Bot Chat call ·
Classic in a chat it created · Watch calls · CarPlay calls · calls from
Hermes · Resume Call · memory at call end (notifier)

**Code**
- Recording and saving: `Conduit/Voice/VoiceHistory.swift` (VoiceTranscriptRecorder, VoiceTranscriptSaveRequest, VoiceCallChatLink, VoiceTranscriptOutbox, VoiceCallCheckpoint)
- In the app: `Conduit/Services/AppState.swift` (chatCallReconnectWindow, isArchivedVoiceChat, saveWatchVoiceCall, checkpointVoiceCall)
- The call's card in its chat: `Conduit/Views/VoiceChatCallTranscriptSheet.swift`
- Watch: `Conduit/Watch/WatchDirectBroker.swift`, `ConduitWatch/WatchDirectCallModel.swift` (trimTranscript), `ConduitWatch/WatchBridgeCallModel.swift` (trimTranscript), `Shared/WatchVoice/WatchVoiceWire.swift` (DirectTranscript)
- Notifier: `notifier/dashboard/plugin_api.py` (/voice/sessions, /voice/chat-calls, /voice/archive), `notifier/voice_archive.py`

**Rulings**
- A call's turns go to the host only when the call ends; saving mid-call stalled Gemini (2026-10-01, #281).
- While a call runs its unsaved turns are kept in the on-device outbox, within 10 seconds of a turn settling and on a 15-second timer, so a call the app loses mid-way is saved later. A checkpoint with nothing new (no turn, job or chat change) writes nothing, and a call cut short is measured to its last checkpoint (2026-10-24, #1220, from #1002). Gemini, Qwen, Grok, GPT-Live and Local Live share this path; Classic saves in its own chat, and the Watch saves once at the end.
- A saved call keeps the session source "desktop"; its voice tags live in their own meta key, since a session's source picks the agent's toolsets (2026-09-30).
- A call joined to a chat is kept with the chat, not in a second session, and a reconnect within 120 seconds continues the same call (2026-10-13, #574, notifier #98).
- A call that stands alone, and a chat a Classic call created, are archived when the call ends; a typed turn brings them back (2026-10-22, #1127, notifier #295).
- Ending a call runs Hermes' session-end hooks and memory commit; a call kept with its chat writes memory under the chat (2026-10-06, notifier #46; 2026-10-13, notifier #98).
- A call's turns stay in memory until the host has them; each capture starts after the last line it took, and rescans only when the engine changed a line before it (2026-10-24, #1222, from #1004).
- A Watch call, in every voice mode, keeps only the newest 40 KB of its transcript while it runs, the most its saved call can carry. Lines still in use (an open line, the user turn a tool call answers) and a single newest turn over 40 KB are kept whole; the saved call clips them (2026-10-24, #1221).

**Open gaps**
- None known.

**Checked:** 2026-10-25, Qwen joins the shared save path (`qwen-live` history), at #1182, carried in #1235; 2026-10-24, at #1222 (capture cursor); at #1221, for the Watch's transcript tail; at 78f21da; at #1191: a saved screen turn cut at the plugin's limit keeps its last line unless it can be half a fence (#926 review); at #1220: quiet checkpoints, and a saved turn's cut closes a long fence with one as long, within the plugin's limit.

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

## Calls from Hermes

Hermes rings the user (a job is done, it waits on an answer, a scheduled
check), and the call has to ring, start and talk everywhere it can be
answered.

**Siblings:** CallKit on the phone (unlocked, locked, in another app) ·
CarPlay · the Apple Watch (every voice, Local Live included) · each voice mode that answers (Classic, Gemini,
Qwen, Grok, GPT-Live, Local Live agent mode; Local Live otherwise opens Classic) · the missed-call notification ·
Bot Chat calls · the call trace · the notifier's call tool and skill ·
Pulse (it may call only once the user opts in)

**Code**
- Ringing and answering: `Conduit/Voice/HermesNativeCalls.swift` (receive, stopsWatchRing, startWatchCall), `Conduit/Voice/HermesCalls.swift`, `Conduit/Services/AppState+HermesCalls.swift` (answerHermesCall, hermesCallAudioActivated)
- Caller name: `Shared/WatchVoice/HermesRing.swift` (HermesCallerName)
- Trace: `Conduit/Voice/HermesCallTrace.swift`
- CarPlay: `Conduit/CarPlay/CarPlayVoiceCoordinator.swift`
- Watch: `ConduitWatch/HermesWatchCalls.swift` (followPhone, phoneCallMuted, leavePhone), `Conduit/Watch/WatchVoiceLink.swift` (startAnsweredCall), `Shared/WatchVoice/WatchCallVoices.swift` (rings), `Conduit/Watch/WatchDirectBroker.swift` (prepareLocalLive)
- Answered on the Watch, kept on the iPhone's headset: `Conduit/Voice/HermesNativeCalls.swift` (keepsWatchAnswer, keepFromWatch, startedOnWatch, watchControlChanged, muteOnWatch, inAppMuteChanged, endOnWatch), `Conduit/Services/AppState+HermesCalls.swift` (nativeCallVoiceMuted), `Shared/WatchVoice/HermesRing.swift` (HermesRingControl), `ConduitWatch/WatchVoiceCall.swift` (onPhone), `ConduitWatch/WatchCallView.swift`, `ConduitWatch/WatchDirectCallModel.swift` and `ConduitWatch/WatchBridgeCallModel.swift` (callOnPhone), `Shared/WatchVoice/WatchVoiceWire.swift` (callOnPhone, callsToken's phoneHeadset), `Conduit/Watch/WatchDirectBroker.swift` (handle: a kept call's start gets callOnPhone), `Conduit/Watch/WatchVoiceLink.swift` (callsToken: phoneHeadset), `notifier/relay/src/rings.mjs` (setControl, readControl, adopt)
- Settings: `Conduit/Views/HermesCallSettingsViews.swift`
- Notifier: `notifier/call_tool.py`, `notifier/calls.py`, `notifier/calls_store.py`, `notifier/call_watches.py`, `notifier/skills/calling-the-user/SKILL.md`, `notifier/relay/src/rings.mjs`

**Rulings**
- Answering is the only tap: the call opens its chat and starts talking by itself (2026-10-10, #508).
- A declined or missed call is told to Hermes in that chat's next turn, with no second ring (2026-10-10, #518, notifier #78).
- Hermes speaks first on a call it made (2026-10-11, #546, notifier #89).
- The call screen names the calling profile; the main profile goes by its Conduit name (2026-10-11, #541).
- A call about an approval or question is briefed from the chat's card, not the push's short reason, and answered by voice everywhere it can be (see "Hermes is waiting on you"; 2026-10-24, #1194, notifier #343).
- A Watch that answers starts the call through the relay, since its link to the iPhone is down under the call screen (2026-10-11, #526, notifier #82).
- Answered on the Watch while the iPhone has a headset on (AirPods, wired), the call stays on the iPhone and plays there, whatever the Watch's voice: the iPhone answers its own ring with its own voice mode, and the Watch's call screen keeps Mute and End, shared through the relay's ring control. Every mute reaches the other device: CallKit's on either call screen, and Conduit's own (the call screen's Mute, the minimised bar, Classic's paused microphone). A relay restart mid-call loses nothing: each device writes its state again and reads on, and a change made while the relay was down is retried. With no headset on the iPhone, or a relay older than 0.17, the Watch takes it as before (Eric 2026-10-24, #1225, notifier #354).
- In the car, CarPlay rings and the Watch stays quiet (2026-10-14, #602).

**Open gaps**
- A sealed push carries no profile to the Watch, so its call screen says "Hermes" (#541).
- The first push after install, before the first status read, can still switch dashboards, and missed-call outcomes are keyed by the pushed dashboard id (#1096).

**Checked:** 2026-10-25, Qwen among the modes that answer, and its mute on a call kept on the iPhone's headset (nativeCallVoiceMuted), at #1182, carried in #1235; 2026-10-24, #1225: a call answered on the Watch stays on the iPhone's headset (#1204); at #1194.

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

**Rulings**
- During a call from Hermes, CallKit owns the audio session: Conduit never deactivates or re-activates it, so the Speaker button stays true (2026-10-21, #1093; 2026-10-23, #1148).
- A conversation's replies move from the earpiece to the speaker, never during a CallKit call (2026-10-19, #943).
- Silence mutes the assistant's voice apart from the microphone; its speech is dropped, not held, and job news waits for unmute (2026-10-09, #488).
- An alarm or phone call pauses a live call, which comes back when the audio does (2026-10-04, #380).
- A call from Hermes answered on the Watch plays on the iPhone's headset when one is on there (AirPods, wired, never the car's); the Watch's Mute and End control it like a phone call's, and a mute from any of Conduit's own controls reaches the Watch (Eric 2026-10-24, #1225).

**Open gaps**
- Silence isn't on CarPlay or the minimised bar (#488).
- Classic still ends with "Audio was interrupted." when an alarm or phone call takes the audio, where live calls pause; only CarPlay and calls from Hermes restart it (#380, #1155).

**Checked:** 2026-10-25, Qwen in the siblings, and its mute reaching the Watch, at #1182, carried in #1235; 2026-10-24, #1225: the Watch's Mute and End for a call kept on the iPhone's headset; seeded from main at 64d53c3.

## Talking over Hermes

Speaking while Hermes talks or thinks: barge-in, talk-over, steering, push to
talk, and how long the microphone waits.

**Siblings:** Classic (phone, CarPlay, locked phone) · Gemini Live · Qwen
Live · Grok Live · GPT-Live · Local Live · Watch calls · headset, speaker and car routes ·
push to talk · Continuous Conversation · the Action, headset and CarPlay
buttons

| Mode | On a headset | On the speaker or in the car |
|---|---|---|
| Classic | talk-over starts a new turn; speech while Hermes thinks steers | the same, with "Talk over it on the speaker" on |
| Gemini, Qwen, Grok, Local Live | barge-in | barge-in with "Talk over it on the speaker" on |
| GPT-Live | barge-in (WebRTC cancels the echo) | barge-in |

**Code**
- Routes: `Conduit/Voice/VoiceBargeInRoutePolicy.swift`
- Classic: `Conduit/Voice/VoiceConversationController.swift` (isTalkOverAvailable, isSteerAvailable, beginPushToTalk), `Conduit/Voice/VoiceSpeechDetector.swift`, `Conduit/Voice/EchoCancellingVoiceConversationAudio.swift`
- Live modes: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift`, `Conduit/Voice/GeminiLive/LiveVoiceEchoCancellingAudio.swift`, `Conduit/Voice/GPTLive/GPTLiveConversationController.swift`
- Push to talk surfaces: `Conduit/Services/AppState.swift` (pushToTalkSurfaceAvailable)
- Settings: `Conduit/Views/VoiceSettingsView.swift`, `Conduit/Views/GeminiLiveViews.swift`, `Conduit/Views/GrokLiveViews.swift`

**Rulings**
- In Classic, talking over a spoken reply stops it and starts a new turn; speech while Hermes thinks steers it (2026-10-04, #391).
- Talking over on the speaker is opt-in, "Talk over it on the speaker", off by default, one setting shared by Qwen, Gemini, Grok and Classic, which each mode's caption says (2026-10-03, #351; Classic 2026-10-04, #393; Qwen 2026-10-25, #1182).
- Push to talk is per profile and off by default. While held no silence timer runs; a press while Hermes speaks interrupts, while it thinks steers. CarPlay and calls from Hermes stay hands-free (2026-10-22, #1106).
- With Continuous Conversation on, the default, Classic keeps listening through silence instead of pausing the microphone (2026-10-10, #520).

**Open gaps**
- Push to talk is Classic only: not the live modes, the Watch, or the Action, headset and CarPlay buttons (#1106).

**Checked:** 2026-10-25, Qwen in the siblings, the table and the shared caption, at #1182, carried in #1235; 2026-10-23, seeded from main at 64d53c3.

## Qwen direct voice

A live call on Alibaba Cloud's Qwen realtime model, from the phone or the
Watch, with temporary credentials the notifier mints.

**Siblings:** phone direct voice · Watch direct voice · CarPlay · incoming
Hermes calls · tools and jobs · consent · saved transcripts · notifier tokens

**Code**
- Adapter: `Shared/GeminiLive/QwenLiveSocket.swift`, `Shared/GeminiLive/GeminiLiveSession.swift`
- Credentials: `Shared/GeminiLive/GeminiLiveToken.swift`, `Conduit/Voice/GeminiLive/GeminiLiveTokenClient.swift`
- Watch wire: `Shared/WatchVoice/WatchDirectWire.swift`, `Shared/WatchVoice/WatchVoiceWire.swift`
- Provider setup: `docs/QWEN_LIVE.md`; notifier: `notifier/dashboard/plugin_api.py`
- Plugin capability inventory: `Conduit/Views/ConduitPluginViews.swift` (separate Gemini/Qwen feature entries)
- Lifecycle/recovery: `Conduit/Watch/WatchDirectBroker.swift` (directToken, tokenRefusalAfterMint), `ConduitWatch/WatchDirectCallModel.swift`, `Conduit/CarPlay/CarPlayVoiceCoordinator.swift`
- Watch relay token: `Shared/WatchVoice/WatchToolRelayClient.swift` (keeps `qwen_live_token` beside `live_token`), tests in `ConduitTests/WatchVoiceWireTests.swift`
- Which provider runs: `Conduit/Services/AppState.swift` (configuredLiveVoiceEngine, isQwenLiveEnabled, resumeVoiceCall, adoptSyncedVoicePreferences); what models read: `Conduit/Services/AppState+AgentSettings.swift` (voice.mode, voice.qwen.*, voice.live.save_calls)
- Phone entry, shared settings and captions: `Conduit/Services/AppState.swift`, `Conduit/Views/AuxiliaryViews.swift`, `Conduit/Views/GeminiLiveViews.swift`, `Conduit/Views/VoiceChatCallTranscriptSheet.swift`
- Picker/setup identity: `Conduit/Voice/VoiceModeChoice.swift`, `Conduit/Views/VoiceSettingsView.swift`, `Conduit/Voice/VoiceSetupIssue.swift`
- Saved-call preferences/identity: `Conduit/Voice/VoiceTypes.swift`, `Conduit/Voice/VoiceHistory.swift`
- Watch transport and diagnostics: `ConduitWatch/WatchGeminiSocket.swift`
- Watch capability compatibility tests: `ConduitTests/HermesCallsTests.swift` (legacy plugins, Qwen-only and concurrent providers)

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

**Checked:** 2026-10-25, voice.qwen.* and save_calls naming Qwen, the Watch's qwen_live_token, a token minted after consent was withdrawn, provider precedence and the screen-question gap, at #1182, carried in #1235; 2026-10-24, #1182: independent provider routes and regression tests.

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

The controls on a message: the row under a reply, its long-press and
selection menus, and the same actions in the other chat surfaces.

**Siblings:** chats, project chats and Bot Chat (one row view) · group rooms ·
the selection menu · the long-press menu · VoiceOver labels · pinned replies

**Code**
- Reply row: `Conduit/Views/ChatView.swift` (AssistantMessageActions, ReadAloudButton, AssistantMessageMoreMenu), `Conduit/Views/Components/MessageReactionViews.swift` (MessageReactButton)
- Selection and long-press menus: `Conduit/Views/Components/SelectableTextView.swift`
- Group rooms: `Conduit/Views/GroupChatView.swift` (GroupMessageCopyButton, GroupMessageQuoteButton, GroupReadAloudButton)
- Pins: `Conduit/Views/PinnedReplyViews.swift`, `Conduit/Services/AppState+PinnedReplies.swift`, `Conduit/Services/AppState.swift` (deleteBot, forgetBotChatPinnedReplies)
- Read Aloud: `Conduit/Voice/MessageReadAloudController.swift`, `Conduit/Views/ReadAloudPlayerBar.swift`

**Rulings**
- A reply's row is React, Copy, Read aloud and ⋯ (Quote, Branch, Pin reply); no more icons of their own under messages (2026-10-23, #1156).
- Pin lives in the long-press and selection menus, not the row: Pin for a passage, Pin reply for the whole reply (2026-10-20, #982 and #1097; 2026-10-23, #1156).
- Double-tap and long-press on text stay text selection; reactions come from React or a reaction chip (2026-10-07, #437).
- Read Aloud has no estimated follow-along highlight; only exact word timings from Hermes would bring it back (2026-10-19, #923).
- A quoted reply travels in the message text, since Hermes has no field for hidden context (2026-10-04, #387).
- Deleting a bot drops its Bot Chat pins under every profile, not only the one in use (#982 follow-up, #1191).

**Open gaps**
- Group rooms still show Copy, Quote and Read aloud as three icons, with no React and no ⋯ (#1156).

**Checked:** 2026-10-24, pins at 78f21daa plus the #982 follow-ups; a deleted bot's pins at #1191.

## Conduit plugin update

Updating (or installing) the Conduit plugin on the dashboard's host from
Conduit, and telling the user when it's done.

**Siblings:** the update notice over the main screen · Settings > Conduit
plugin (same status rows, Update and Cancel) · the Settings and Chats notice
that opens it · Finish setting up's plugin row · the host-run update on the
notifier (`/self/update`) and its push when it ends · the phone-run steps for
a plugin without it · the plugin's CHANGELOG.md (What's New) · what the
confirmation and README say about restarts

**Code**
- Updater and state: `Conduit/Services/NotifierPluginUpdate.swift` (NotifierPluginUpdater, NotifierPluginUpdateSlot), `Conduit/Services/AppState+NotifierPluginUpdate.swift` (the run, reconnecting after it, settled outcomes)
- Status and offer: `Conduit/Services/NotifierPluginStatus.swift`, `Conduit/Services/NotifierPluginLatestVersion.swift`, `Conduit/Services/NotifierPluginNoticeChannel.swift`, `Conduit/Services/NotifierPluginChangelog.swift`
- Views: `Conduit/Views/ConduitPluginViews.swift` (NotifierPluginUpdateBanner, NotifierPluginUpdateStatusView, ConduitPluginSettingsDetail), `Conduit/Views/AuxiliaryViews.swift` (NotifierPluginUpdateNotice), `Conduit/Views/V2/V2FinishSetupCard.swift`
- Gateway restart it reuses: `Conduit/Services/GatewayRestart.swift`
- Notifier: `notifier/dashboard/plugin_api.py` (/self/update, /self/restart, /capabilities, finish_self_update_after_restart), `notifier/CHANGELOG.md`, `notifier/channels.yaml`
- Tests: `ConduitTests/GatewayRestartTests+PluginUpdate.swift`, `notifier/tests/test_self_update.py`

**Rulings**
- No automatic updates: restarts are the user's call; the notice offers each version once, and Update runs the whole update (2026-10-13, #582, Eric).
- App Store builds are asked only below the stable floor, TestFlight and Xcode builds for every version on notifier main (2026-10-20, #984; 2026-10-23, #1166, Eric).
- The notice stays until the update truly ends: after the host is done, it shows Reconnecting until Conduit is back, has read the new plugin and the gateway serves, and only then says the plugin is ready. A failure the plugin's report contradicts (the new version runs) reads as ready, not as a silent close (2026-10-24, Eric's report on build 228).
- A gateway restart that takes the dashboard down with it (a service manager restarting both) still finishes the host job: the restarted dashboard marks it done when it loaded the new version (2026-10-24, notifier 0.69.1).
- The notice's What's New opens the notes in a sheet, presented by the notes it shows (a sheet item, not a flag); Settings shows the same notes inline in a disclosure (2026-10-25, Eric's report of a blank sheet, #1227).

**Open gaps**
- Hermes Desktop's own serve process on the host keeps the old plugin until Desktop restarts; nothing tells the user.
- A dashboard without a fixed basic-auth secret signs Conduit out at every restart; the updater signs in again, but the chat may land on the sign-in screen.

**Checked:** 2026-10-25, Qwen Live's feature row and the qwen-live capability in the update nudge, at #1182, carried in #1235; at #1230 (the phone-run install and update requests wait in the profile config queue, the host-run update doesn't); at #1222; at #1227: the notice's What's New sheet opened blank; Settings' disclosure and the notifier's CHANGELOG.md needed no change.

## Notifications

What a push says, in which language, where tapping it goes, and when it
stays quiet.

**Siblings:** reply · approval · question · failed turn · tasks and cron ·
phone changes · missed call · Pulse (pulse.noticed, pulse.brief, pulse.followup, each with
how much it may interrupt, and private ones; app side on the `pulse` branch only, see Pulse) ·
the Watch (mirrors the iPhone) · Bot Chat · the notification service extension · the relay's
plain copy and a push's interruption level ·
Settings > Notifications · end-to-end encryption (keys, rotation, the
padlock or shield in Settings > Notifications, on the dashboard rows of
Saved Dashboards and the Profiles sheet, and in the Watch's Settings)

**Code**
- Extension: `ConduitNotificationService/NotificationService.swift`, `ConduitNotificationService/NotificationLocalization.swift`
- Shared copy: `Shared/Notifications/NotificationCopy.swift`, `Shared/NotificationE2E.swift`
- Inline key rotation: `Conduit/Services/NotificationKeyRotation.swift` (the exchange), `Conduit/Services/PushNotificationService.swift` (provisionEncryption, rotateInline, finishInlineRotation: when to rotate, resends and pending rotations)
- App: `Conduit/Services/PushNotificationService.swift` (showPreviews; the relay registration and its updates; a tap's retries, its wait for a call, and the waiting tap kept across a relaunch), `Conduit/ConduitApp.swift` (the route that opens a tap), `Conduit/Services/AppState.swift` (openNotificationTarget, routeBotOwnedNotification, showCallRefusal and clearCallRefusal, callWaitCanEnd), `Conduit/Views/RootView.swift` (callTopBanners: the notice over a call's screen), `Conduit/Services/ChatOnScreen.swift`, `Conduit/Services/AppState+ChatOnScreen.swift`, `Conduit/Services/CronNotifications.swift`, `Conduit/Services/ReplySourceNotifications.swift`
- Missed calls: `Conduit/Voice/HermesCalls.swift`
- Categories, on the `pulse` branch only, so not in backticks: Conduit/Services/NotificationCategories.swift registers the call and Pulse categories together (each registration replaces the set; the call's category is still defined in HermesCalls.swift), and Conduit/ConduitApp.swift handles Pulse's Quiet for today (see Pulse)
- Settings: `Conduit/Views/AuxiliaryViews.swift`, `Conduit/Views/SavedDashboardsView.swift` (padlock on dashboard rows, also shown by `Conduit/Views/ProfilePickerSheet.swift`, which reuses `SavedDashboardRowLabel`; worked out by `AppState.notificationsEncryption(of:)` in `Conduit/Services/AppState.swift`)
- Watch padlock: `Conduit/Services/AppState+HermesCalls.swift` (shareWatchCallVoices), `Conduit/ConduitApp.swift` (the `.task`s that re-share the Watch context when the notifications state settles and when the active dashboard changes), `Shared/WatchVoice/WatchCallVoices.swift` (WatchPhoneContext.notificationsEncryption), `ConduitWatch/WatchHomeView.swift` (WatchSettingsView: the label and its footer say quantum-safe when the shield shows)
- Notifier: `notifier/events.py` (push_event, plain_text, media_free, sanitize_decision, sanitize_call), `notifier/session_titles.py`, `notifier/chat_on_screen.py`, `notifier/e2e.py`, `notifier/relay/src/apns.mjs`, `notifier/relay/src/server.mjs` (a push's interruption level and relevance score), `notifier/pulse_push.py` (a Pulse push's level and whether it's private)

**Rulings**
- Notifications follow the App Language: the extension builds the words from the event's title_label and session_title (2026-10-23, #1158, notifier #326).
- Pushes are titled with the Hermes session title (2026-10-12, notifier #93 and #94).
- No push shows a host path: replies (Bot Chat and Pulse included), background tasks, failed turns, questions, approvals, calls, updates and phone changes show each MEDIA tag as 📎 and the file's name, or its type when the name is only a hash, in the plain and the sealed copy alike, and so do the answer card and the call screen that come with them; a reply's fenced code stays as written (2026-10-24, Eric's review, #1212, notifier #348).
- A reply's push stays quiet while its chat is on screen and in use (2026-10-22, #1132, notifier #301).
- A Pulse morning brief's push says only the brief's first line, cut to 200 characters; the lines under it are for its card (2026-10-25, notifier #357).
- Each Pulse push says how much it may interrupt, decided in code, never by the model. Time-sensitive: a pick held for a place at its moment, a reminder for a place as the user gets there or leaves, the same for a kind of shop walking past comes near (2026-10-28, notifier #435), and a follow-up that can't wait (its check said it's urgent, or it went at night or in a closed part of the day because later would be no use), at most three a day in the user's time zone, then active. Passive (Notification Center, with no sound or lit screen): anything else that goes while the phone says the user is busy (an event, or a Focus that holds calls; driving doesn't count), and a report whose pushed picks are all interests or far off. Active: the rest, the morning brief included. The reply carries `level` beside the envelope as routing, so the relay sees it with encryption on and `redact on` keeps it; the relay (0.20, `push-levels`) sets the alert's interruption level and relevance score (0.2, 0.5, 0.9), and an older relay sends it at the default level, as every other push goes. A build without the Time Sensitive Notifications entitlement gets a time-sensitive push as active (2026-10-27, Eric chose to build the gaps in order; notifier #424, #1379).
- A Pulse push about someone's birthday or anniversary, or whose words are about a gift, a surprise, health or money, says only "Pulse has something for you." while Hide private reminders on the Lock Screen is on (the default), whatever Show previews says: its words never leave the host in a push, the sealed payload says `private` for the extension to write that line in the App Language, and its card shows everything. A pairing with no key gets the line in English (2026-10-27, notifier #424, #1379).
- A push from a Bot Chat opens the Bot Chat (2026-10-16, #654), and a call from one opens the bot (2026-10-16, #630).
- Notification status in Settings is for the active dashboard only (2026-10-05, #395).
- A notification from another workspace or profile, tapped during a call, doesn't switch to it: the switch would end the call, so the tap waits and opens once the call has ended and Conduit is on screen, however long the call lasts, and a notice over the screen says so, over a call's own screen too (with V2 off the drawer shell has no notice and keeps its error line, as before, which shows nothing during a call and drops it once the call ends or a newer tap replaces the waiting one). A newer tap replaces it. If Conduit closes meanwhile (which ends a call on the phone), the tap waits again at the next launch, unless it's over two hours old. A chat link, or a widget's or Shortcut's launch for another workspace, says to end the call first instead, in the same notice, since either can be tapped again and a tapped notification is gone. A call from Hermes opening its own chat (answered, or its notification tapped, a missed call's included) still switches, since talking to Hermes leaves the other call. Every call counts: on screen or minimised, Classic voice, CarPlay, the Watch and a call from Hermes (2026-10-26, #1297; found in #1286's review, where only chat links refused; waiting for the call, the notice and the relaunch came from #1297's reviews).
- Encryption keys rotate: every 7 days (30 before inline rotation), on Settings > Notifications > Rotate, or when the host asks (`hermes conduit-push e2e rotate`). The phone saves the new key before sending it, and both sides keep the replaced key 7 days for pushes and answers in flight. Rotation is per pairing and below every event kind, so reply, approval, question, failed turn, tasks and cron, phone changes, missed call, Pulse and Bot Chat pushes need no change. On the condition that nothing already working is disrupted: a pairing that never rotates (an older app or notifier) keeps sealing and opening pushes and answers with its one key, tested on both sides (2026-10-24, #1197 and notifier #344, Eric).
- The relay's plain copy is for pairings with no key. Rotation leaves it untouched: it neither reads nor changes the copy, and a pairing with no key never rotates (2026-10-24, #1197 and notifier #344, Eric).
- Keys rotate inline through a key exchange sealed with the current key (notifier 0.72+, `POST /e2e/rotate`): ML-KEM-768 with X25519 on iOS 26, X25519 alone below. A key handed over through the dashboard is replaced at once, and the next rotation after an update to iOS 26 is quantum-safe; the handover stays as the fallback when the chain breaks. Approved on the condition that iOS 17 to 25, older notifiers and the dashboard handover keep working as today (2026-10-24, #1213 and notifier #349, Eric).
- A quantum-safe pairing shows a shield (`lock.shield.fill`) instead of the padlock, in Settings > Notifications, on dashboard rows, and in the Watch's Settings for the iPhone's active dashboard. Approved on the condition that iOS 17 to 25, older notifiers and the dashboard handover keep working as today (2026-10-24, #1213 and notifier #349, Eric).
- The padlock is closed only when the host confirmed it seals with the key this iPhone holds, and that key isn't past 7 days plus the 7-day overlap. A host whose notifier can't rotate (before 0.71) keeps a closed padlock at any key age, with a caption asking for an update, since nothing on the phone could rotate it. A host that can't rotate is never shown as broken, so pairing with an older notifier is not disrupted (2026-10-24, #1197 and notifier #344, Eric).

**Open gaps**
- Rotation narrows what a leaked key opens, but a key copied while in use still opens the pushes captured with it; there is no per-message ratchet.
- Still English: the relay's plain copy (pairings with no key), the redacted decision text, and a clarify body with no arguments (#1158).
- A private Pulse push is found by English words only: a gift, a surprise, health or money said in another language shows its words. Birthdays and anniversaries are found from what Pulse remembers, in any language (notifier #424).
- Conduit doesn't have the Time Sensitive Notifications entitlement yet, so a time-sensitive Pulse push arrives as active. It waits for the capability on the app's identifier and a regenerated Hermes Conduit App Store profile, since signing is manual (#1379).
- "Notify me when" choices are one set per iPhone, not per dashboard: the relay keeps one set per installation (#395).
- A registration update landing after a relay move is dropped rather than written onto the new registration (#865 follow-up, #1191); the move itself has no test seam (it registers through URLSession.shared).

**Checked:** 2026-10-28, at #1428 on the `pulse` branch, carrying #1427 from main (a pick or reminder for a kind of shop walking past comes near pushes time-sensitive as a place's does, notifier #435); 2026-10-27, at #1379 on the `pulse` branch (a Pulse push's level and private ones, with notifier #424: the extension's private line in the App Language; other pushes, the relay's plain copy, encryption and Settings > Notifications needed no change); 2026-10-26, at #1302 on the `pulse` branch, carrying #1297 from main (a notification tapped during a call no longer switches and opens once the call ends, kept across a relaunch, with a notice over the call's screen too, and so does one whose Bot Mode check fails during the call; the extension, the relay's copy, encryption and Settings needed no change); Pulse pushes' Quiet for today button at #1285 on the `pulse` branch (see Pulse); 2026-10-25, the morning brief's push at notifier #357, carried in #1237; 2026-10-24, at #1213 (inline rotation, the shield and the Watch's row and footer; a pairing rotates at most once per run, a Rotate tap during a rotation joins it, and a verified key the Keychain refused stays pending and is shown as such; fork CI #85); #1212 (MEDIA tags in pushes, answer cards and the call screen); keys and padlock at #1197, carried in #1217 (fork CI #82); the registration update race at #1191; its relay registration error log redacted (bare hosts) at #1219.

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
says how much it may interrupt (see Notifications). It's a beta, so its app
side is only on the `pulse` branch.

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
- App, on the `pulse` branch only, so not in backticks (the map check reads main): Conduit/Views/V2/V2PulsePage.swift (the screen, the morning brief's block, What Pulse learned, What Pulse left out, suggestion cards with Add, Not now, Undo and its question), Conduit/Views/V2/V2ChatsView.swift (V2PulseButton in the Chats bar, Pulse's chat left out of the list and content search), Conduit/Views/V2/V2VoiceButton.swift (Pulse's chat left out of voice recents), Conduit/Views/PhoneSettingsViews.swift (People's caption on birthdays, with a plugin that reports `pulse_dates`), Conduit/Views/V2/V2Shell.swift (the `.pulse` route, full screen on a phone), Conduit/Services/PulseFeed.swift (cards, marks, ratings, which cards take Done and Do it and which ask why on a thumbs down, Do it's message per topic, a deadline's and a next step's among them, the brief's layout, which chat is Pulse's, what Pulse learned and left out, what a card's Why? says learning did, what Pulse looked at and when a card back after a stalled Do it had Do it tapped, and a suggestion's states and its Add, Not now and Undo calls), Conduit/Services/AppState+Pulse.swift and Conduit/Services/AppState.swift (opensPulseScreen, for pushes; pulseRememberedHomes, Pulse's chat per dashboard across launches; pulseFoldedBriefs, the briefs folded per dashboard across launches, the newest 30 of each and the one just folded; unfoldPulseCard, a card put back open in a folded brief; startPulseNewChat, the new chat Do it fills; quietPulseForToday, Quiet for today from a notification, which a call keeps from switching dashboards), Conduit/Services/PulseSettings.swift and Conduit/Views/PulseSettingsViews.swift (Settings > Pulse, quiet times, deadlines from Shortcuts, Look things up first, Where you are and Walking past, Hide private reminders on the Lock Screen, What Pulse remembers, a yearly fact's day, where a deadline came from and the place a promise waits for, and what a suggestion's refusals say), Conduit/Services/AppState+PhoneSync.swift (applyPulseApproval) and Conduit/Phone/PhoneSyncEngine.swift (approveFromCard: a change approved on a card, applied without the phone's own card), Conduit/Views/ShortcutInboxSettingsViews.swift (Settings > Shortcuts inbox's caption and delete-all message on Pulse's deadlines, with a plugin that reports `pulse_inbox`), Shared/Notifications/PulseNotifications.swift and ConduitNotificationService/NotificationService.swift (which Pulse pushes get Quiet for today), Shared/Notifications/NotificationCopy.swift (a private push's line, in the App Language), Shared/NotificationE2E.swift (pulseQuietGateways, the hosts whose pushes offer it, shared with the extension), Conduit/Services/NotificationCategories.swift and Conduit/ConduitApp.swift (its button, done in the background, and the retry), Conduit/Services/PushNotificationService.swift (pulseQuietTarget, the push's dashboard and gateway, checked again on the tap; pulseQuietAwaitsCall and takePendingPulseQuiet, the retry's wait for a call, kept across a relaunch on the day it was pressed); a card from a Kanban task's worker: Conduit/Services/PulseFeed.swift (kanbanTask, its Do it message, pulseCardHasChat, pulseCardTask, openPulseCardTask), Conduit/Views/V2/V2PulsePage.swift (sourceLink, taskLink), Conduit/Services/AppState.swift (kanbanTaskOpenRequest), Conduit/Views/V2/V2Shell.swift and Conduit/Views/V2/V2TasksView.swift (Tasks › Board for it), Conduit/Views/KanbanViews.swift (openRequestedTask) and Conduit/Services/KanbanStore.swift (findTask, on whichever board holds it)
- Loop: `notifier/pulse.py` (the tick, the report's candidate run, cards from turns, push copy, the model Pulse's calls outside its chat run on), `notifier/pulse_delivery.py`, `notifier/pulse_host.py`, `notifier/pulse_hermes.py`, `notifier/chat_takeover.py`
- Report: `notifier/pulse_report.py` (what it reads, the note to Pulse), `notifier/pulse_candidates.py` (the candidate list, which reads the note too, the router and the 30-day journal, which What Pulse left out lists)
- Memory, follow-ups and the brief: `notifier/pulse_memory.py`, `notifier/pulse_followup.py` (its checks read the note to Pulse), `notifier/pulse_brief.py` (what the brief reads: held cards, open items, the phone, the inbox, the note to Pulse, and what Pulse remembers related to today's events, from `today_related` in `notifier/pulse_places.py`)
- Quiet times: `notifier/pulse_quiet.py` (whether Pulse is quiet now, and until when); the tick's gates in `notifier/pulse.py`
- The right time: `notifier/pulse_hours.py` (the night, the parts of the day, when news is useful, and whether the user is busy); follow-ups' holds in `notifier/pulse_followup.py`, the report's caps in `notifier/pulse_candidates.py`, and the events on now in `notifier/phone_store.py`
- What happened since an item came up: `notifier/pulse_evidence.py` (later chats and cron runs, background processes); follow-up, held-reminder, brief-card, found-card and Do it checks read it with the item's chat in `notifier/pulse_followup.py`, its continuation through `notifier/pulse_hermes.py` (`chain_messages`), the phone's calendar and reminders and the report in `notifier/pulse_report.py`
- Yearly dates and the look ahead: `notifier/pulse_dates.py` (the dates that come back every year, from the picked people's birthdays in `notifier/phone_store.py` and memory's yearly facts, and their lead times), `notifier/pulse_ahead.py` (once a day before the brief: what it reads, its candidates, decided by `notifier/pulse_candidates.py`, and its cards, held for the brief); its run in `notifier/pulse.py`'s memory run, journaled by `notifier/pulse_store.py` (`add_run`, `journaled_refs`, `release_held`)
- Deadlines from the Shortcuts inbox: `notifier/pulse_memory.py` (`read_inbox`, its instructions and checks, after the chats in `notifier/pulse.py`'s memory run; `forget_inbox` in the tick, `forget_deleted` and `stop_inbox`), `notifier/inbox_store.py` (`received`, `present`), `notifier/pulse_store.py` (`keep_inbox`, which moves the inbox mark in the same write), their lead times in `notifier/pulse_dates.py` and their section and cards in `notifier/pulse_ahead.py`, their level in `notifier/pulse_learning.py`, and the inbox routes that delete theirs in `notifier/dashboard/plugin_api.py`
- What got done elsewhere: memory's close marks the thing's cards in `notifier/pulse_store.py` (`advance`, `found_cards`, `unmark_done`'s `put_back_at`, which keeps the checks off a card put back, and `end_rest`, which ends a done card's rest at its time without bringing it back), reminded commitments and word endings in `notifier/pulse_memory.py`, and the found-card checks and `read_first` in `notifier/pulse_followup.py`
- Learning: `notifier/pulse_prefs.py` (what thumbs, Do it and Done teach, how loudly things come up, and what a reset forgets); reasons, lessons and levels: `notifier/pulse_learning.py`; outcomes: `notifier/pulse_ledger.py`; store, with the signals: `notifier/pulse_store.py`
- Looking first and suggestions: `notifier/pulse_tools.py` (what a Pulse turn may call, and its caps), `notifier/pulse.py` (`pre_tool_call`, default deny), `notifier/pulse_proposals.py` (a suggestion kept, its card, Add, Not now and Undo, and what the card says), `notifier/phone_tool.py` (`proposed_add`, and the `pulse_turn` refusal), `notifier/phone_store.py` (`check_change`, `change_outcome`, and `add_change`'s `ask` and `change_id`), `notifier/pulse_store.py` (the proposals table, `swap_proposal`)
- How a push goes: `notifier/pulse_push.py` (its level, at most three time-sensitive a day, and whether it's private), `notifier/pulse.py` (`push_copy`), `notifier/events.py` and `notifier/e2e.py` (`level` beside the envelope, `private` sealed), `notifier/relay/src/server.mjs` (the alert's `interruption-level` and `relevance-score`)
- Where the user is: see Where you are, for Pulse
- A card from a Kanban task's worker: `notifier/pulse_hermes.py` (`worker_tasks`: which chats are a worker, and the task its prompt names), `notifier/pulse_followup.py` (`worker_tasks` per profile, and the Do it check reading the new chat for one), `notifier/pulse_control.py` (`feed`'s `kanban_task`)
- Control: `notifier/pulse_control.py` (shared by the commands and the routes), `notifier/cli.py`, `notifier/dashboard/plugin_api.py` (/pulse)
- Tests: `notifier/tests/test_pulse.py` (with memory's closes), `notifier/tests/test_pulse_learning.py` (ratings, cards and the brief, and the checks that mark cards done), `notifier/tests/test_pulse_candidates.py`, `notifier/tests/test_pulse_prefs.py` (the learning), `notifier/tests/test_pulse_personas.py` (personas over two weeks, each against the same run without learning), `notifier/tests/test_pulse_hours.py` (the night, waiting while busy, when news is useful, Wrong time), `notifier/tests/test_pulse_dates.py` (the yearly dates, their lead times and the look ahead), `notifier/tests/test_pulse_inbox.py` (deadlines from the Shortcuts inbox: what's kept, when they come up, and how they're forgotten), `notifier/tests/test_pulse_tools.py` (what a Pulse turn may look up), `notifier/tests/test_pulse_proposals.py` (suggestions: kept, carded, added once, followed and undone), `notifier/tests/test_pulse_push.py` (a push's level and private pushes), `notifier/tests/test_pulse_places.py` (the brief's items related to today's events, with Where you are's tests); the app's ConduitTests/PulseFeedTests.swift (cards and their Why?, the brief's fold, What Pulse learned, What Pulse left out and what the look ahead left out, People's caption, Wrong time, Not now's choices at night, a card marked done while it's put off, a deadline's card and the Shortcuts inbox page's caption, what Pulse looked at, suggestion cards and their states, a next step's card, and a card back after a stalled Do it), ConduitTests/PulseSettingsTests.swift (Settings > Pulse, quiet times, the night, deadlines from Shortcuts, Look things up first, Where you are, Hide private reminders, a yearly fact's day, where a deadline came from and a promise's place in What Pulse remembers, and a suggestion's refusals), ConduitTests/PhoneSyncTests.swift (a change approved on a card), ConduitTests/NotificationCopyTests.swift (which Pulse pushes offer Quiet for today, and a private push's line) and ConduitTests/NotificationDashboardOwnershipTests.swift (which dashboard Quiet for today acts on), on `pulse`

**Rulings**
- The app side stays off main: public TestFlight builds main, and internal testers' builds come from `pulse` (2026-10-21, #1092). The notifier side is on its main, off by default (2026-10-21, notifier #275).
- No Pulse chat in sight: reports and the brief land as cards on the Pulse screen, and the home chat is hidden from Chats, search and voice recents (2026-10-22, #1116, notifier #291). The app remembers each dashboard's Pulse chat, so after a relaunch the Pulse button shows and the chat stays hidden at once; the remembered chat follows the feed, and goes when the feed names none, the plugin answers without Pulse or the dashboard is removed (2026-10-25, #1234, Eric's report: Pulse showed as a chat for a while after reopening).
- Pulse learns in code, not as a line in a prompt. Thumbs, Do it (opened, something sent, got done) and Done are signals it learns from slowly, older ones counting for less: which kinds, chats and timings are worth bringing up, and how loudly, a push acted on within the hour making its kind louder. The report's candidates and the follow-ups go by what it learned. Not now, and a card opened and left alone, teach nothing. A kind's level (push now, Pulse screen, brief, off) is the loudest it gets, as the user set it or "too often" did, and learning moves things only below it. A promise Hermes made that's overdue, and a commitment or asked reminder due within a day, come up whatever learning says, within that level. A thumbs-down asks one tap for why, on a report card too once the plugin reports `pulse_learns`, and the reason acts at once for the card's kind (a report card's topic), as What Pulse learned says. Two thumbs no longer step a kind along the ladder, and the steps they made before are retired once (2026-10-26, Eric asked for the five improvements; notifier #385, #1286; before, thumbs moved a kind along the ladder, 2026-10-22, notifier #284). Each report item is its own card with its own thumbs (2026-10-23, notifier #330).
- A report that finds nothing leaves no card (2026-10-23, notifier #324).
- The morning brief comes every day at its time (07:00 by default, an hour before the first report) and sums up what's still open: what's due or on the calendar today, open promises and things the user said they'd do, and what the phone's automations logged. Held news still comes as its own cards under it, and a brief that brought none shows as its summary block. Read, it folds from its header to one row saying when it came and what's left in it, and stays folded on that phone, across launches, until it's opened again; one whose cards are all handled folds by itself. A Pulse mark pointing into a folded brief opens it, and so does a card in it that comes back open, from Not now or with Undo; a Pulse push opens the screen at its top, where a new brief shows open until it's folded (2026-10-26, Eric asked for a way to fold the brief once it's been read; #1306). The next report leaves out what the brief already brought up, unless something about it changed. Settings > Pulse says the brief comes every day only to a plugin that reports `pulse_daily_brief` (2026-10-25, notifier #357, #1234, Eric's report: a 05:00 brief with nothing held never came).
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
- Main reaches `pulse` by a merge commit, never a squash, so archives don't re-stitch old conflicts (2026-10-24, #1186; build 228's stitch lost the Chats Pulse button).
- Done and Do it work on every report item, one Pulse found on its own included. Do it opens the chat it was found in, or, for one from the calendar, reminders, Hermes's notes or scheduled jobs, or the Shortcuts inbox, a new chat in the dashboard's default profile, with the reminder in the composer, and only in the chat Do it's New Chat made. It starts that chat only when New Chat can start one at once: connecting, during a profile switch or with another new chat on its way, the Pulse screen says why instead. The Do it check then reads that chat with the others on the subject. Done on a found item marks only the card, and the next report reads it as done. On a found item the app shows them only to a plugin that reports `pulse_found_actions`; with an older plugin they stay on items about something Pulse remembers (2026-10-25, Eric; notifier #362, #1240; Eric asked why date and worth-knowing cards couldn't be acted on).
- What's finished stays finished. A reminder sent on with Do it, and Hermes's answer to it, can close a remembered item but never add one, and a commitment Pulse learns of more than half a day after its time (reading older chats) is kept as expired, never reminded (2026-10-25, Eric; notifier #364, Eric's report: a card blamed a reminder job for bringing back finished items).
- What got done elsewhere leaves the Pulse screen. When memory reads a chat that shows a remembered thing done or called off, the thing closes and its cards (follow-ups and report items, about it or about what it replaced) get Pulse's done mark in the same write, shown as "Done, seen in the chat": a held card leaves the brief, and one put off with Not now or Wrong time shows as done and doesn't come back. A commitment Pulse reminded the user of stays closable for two weeks, so an answer in any chat, or to the reminder, closes it; said again, it's a new item with its own reminder. A report item Pulse found on its own has its chats read again a day after it came and once more a day later, while it's on the screen and under three days old, at most three a run and last, on what the follow-up checks leave; held for the brief or put off with Not now, it's read before it goes in or comes back, like a remembered one, and one tapped Do it on is left to Do it's check; one found outside the chats is read without Pulse's own chat. Undo takes Pulse's mark off and reopens the thing while that close still holds it, and a card that was put off stays put off. A card put back after any of Pulse's marks isn't read again for a mark: it goes to the brief as it is, stays on the screen, or comes back from Not now unread, and only a new close or a new Do it marks it again. Pulse's marks teach nothing. On the Pulse screen, a card marked done while it's put off shows as done, with Undo, in a morning brief too, and one put off with Wrong time shows that reason under it, as a done card shows its reason (2026-10-26, Eric: "is there a way that pulse recognizes in later scans that a previously surfaced card is taken care of?"; notifier #400, #1326).
- After a plugin update the restarted dashboard takes Pulse over at once: a loop lease stamped with an older build is free, and one whose process has exited doesn't read as an older copy running, so Settings > Pulse and `pulse status` warn only while a process that loaded an older build really runs (2026-10-26, notifier #392, Eric's report: Pulse said the dashboard ran old code for a couple of minutes after the update had restarted it).
- Settings > Pulse's model runs all of Pulse: its turns (the reports and the morning brief), memory, the report's candidate list, and follow-up, held-reminder, brief-card, found-card and Do it checks. On "Same as the Pulse chat" the calls outside the chat use the Pulse chat's own model, as Hermes reads it back when it reopens the chat, unless Hermes's "Pulse memory" slot names one; a chat without a model of its own, or whose provider is gone, leaves them on Hermes's main model (2026-10-25, #1262, notifier #375, Eric's report: with the Pulse chat on Volcengine, report lists and a follow-up check ran on the main model and failed while it was out of capacity).
- Do it's message fits what the card is about. For something the user meant to do (a commitment, a reminder, a plan, a follow-up topic, a next step) it asks Hermes to take care of it; for what Hermes said it would do (a follow-up card, a promise), to go ahead; for a date, to help get ready; for a deadline, to help take care of it before then; for something watched, where it stands; for an interest, to tell more; for anything else, to look into it. The Do it button's icon has its colour set outright, so it shows on the button's accent fill (2026-10-25, #1275, Eric's report: the Do it line didn't always make sense for the card, and the button showed its title alone, pushed right).
- A card whose chat is a Kanban task's worker (see Kanban workers' transcripts on main) names the task, from the dispatcher's `work kanban task <id>` prompt (`kanban_task`, notifier 0.117.1). Hermes won't reopen a worker as a chat, so the card links the task instead, opened in Tasks › Board on whichever board holds it, where Reply & unblock, Note & requeue and Reclaim are; and Do it starts a new chat in Pulse's profile, as for an item from no chat, asking Hermes to check the task on the board and get it going again if it's stuck. The Do it check reads that new chat, not the worker's transcript (2026-10-29, #1473, notifier #458; a tester's report via Eric: Do it opened the worker's chat, where the task couldn't be started again, and they suggested a new chat or putting the task back to work).
- A note to Pulse, in the user's own words, from Settings > Pulse or `hermes conduit-push pulse note`: the report's candidate list, the report turn, the morning brief and the follow-up, held-card and found-card checks read it as the closing paragraph of their instructions, and where it says what to bring up or leave out it comes before Pulse's own rules. Up to 1,500 characters; memory and the Do it check don't read it. The app shows the field only to a plugin that reports `pulse_note` (2026-10-25, Eric asked for the five improvements; notifier #378, #1277).
- Quiet times: quiet days of the week and a vacation until a day in Settings > Pulse, and Quiet for today on the Pulse screen and as a Pulse notification's button. While quiet, Pulse sends nothing on its own: no report, look or morning brief, none it skipped goes late when the quiet ends at midnight, and a follow-up due to push waits for the first brief after. Memory, Do it's checks and a put-off card's return go on, and a report or look the user asks for still comes. Quiet for today lasts until midnight and never shortens a longer spell. The Pulse screen says Pulse is quiet and until when, with End quiet time for a spell. The notification's button works without opening Conduit, on the host the push came from (by its relay gateway) when that is the dashboard in use; otherwise, or when it can't reach Hermes, it says so, and that notification's tap tries again with Conduit open, switching dashboards as a tap on the push would. During a call it waits for the call to end, as a tapped notification does, and says so; of it and a tapped notification, whichever started waiting last is the one that goes through, and if Conduit closes meanwhile it waits again at the next launch, on the day it was pressed only, since it was Quiet for that day, and not once it's two hours old, as a tap. It opens the Pulse screen only on the push's own dashboard. A pairing with no key gets no Quiet for today button: the button acts on the push's host, so it needs a push Conduit could verify. Settings shows a vacation's day in the plugin's time zone, as the plugin keeps it, and the Pulse screen says when quiet ends on the phone's clock. The app shows all of it only to a plugin that reports `pulse_quiet` (2026-10-26, Eric asked for the five improvements; notifier #383, #1285; the wait for a call came in #1302, carrying #1297's wait for a tapped notification over to the retry, the call fix Eric asked for with them).
- Pulse remembers dates that come back every year and looks two weeks ahead. A birthday, an anniversary or another yearly date said in a chat is kept with its month and day, never expires, and stays open when a card about it is marked done; the people picked in Settings > Calendar & phone > People bring their birthdays, and a birthday said in a chat on the same day as a picked person's counts once. Birthdays and anniversaries come up two weeks ahead (or the first day Pulse knows of them, while over a day away), the day before and on the day; other yearly dates the day before and on the day; each lead time once a year. Once a day, from an hour before the morning brief and not while Pulse is quiet, one model call reads the next two weeks (the yearly dates, the phone's calendar and reminders, what Pulse remembers and what it brought up lately), words each date due and adds up to five things worth starting on today. Code decides as for the report, a date due a floor unless the call says it's done, covered or raised lately, and journals every candidate, so What Pulse left out lists the look ahead's too and says which left each out. What Pulse remembers and `pulse memory` show a yearly fact's day. What comes up is held for that morning's brief, or goes to the screen once the brief went; nothing from the look ahead pushes on its own except a pick held for a saved place or a kind of shop, which pushes when the user gets there (see Where you are, for Pulse), and a held card no brief took that day goes to the screen at midnight. With the follow-ups' budget spent or the call failing, the dates still come up in Pulse's own words. It runs with Pulse memory, on the follow-up budget whatever the follow-ups' switch, and `pulse ahead off` turns it off. People's caption says Pulse brings up their birthdays where the plugin reports `pulse_dates` (2026-10-27, Eric chose to build the gaps in order; notifier #407, #1339).
- Pulse memory keeps deadlines from the Shortcuts inbox, quietly. With memory on, each memory run reads what was logged since it last read, after the chats and on what they leave of memory's budget (a week back the first time; NFC tags, sounds and the last minute's uploads skipped), and keeps only a day by which something of the user's ends, renews, closes or is due: a free trial, a renewal, a bill, a return window, a booking, an expiring card or licence, never sales, deliveries or appointments. Code keeps one only when the words it came from and its day are in the event; one already over when read is kept as expired. A later event repeats, moves or closes it ("Payment received"), and so can a chat. Each comes up a week ahead and the day before, in its own section of the look ahead, as a floor; deadlines have their own level in What Pulse learned, starting held for the morning brief, so none pushes until the user turns them up, and a model's finds never make one. Done on its card closes it and Undo opens it again; Do it starts a new chat. A deadline is deleted a day after it's done, forgotten or expired, and at once when its event is deleted in Settings > Shortcuts inbox. Settings > Pulse's Deadlines from Shortcuts switch, under Memory, turns it off and forgets them, after asking. The app shows the switch, What Pulse remembers' Deadlines with who each is from and when it was logged, and the inbox page's caption to a plugin that reports `pulse_inbox` (2026-10-27, Eric's card "Keep deadlines from your phone's inbox in Pulse memory, like trial ends and bills?": Keep them quietly; notifier #410, #1341).
- Pulse looks first, then asks. With Look things up first on (the default; Settings > Pulse or `hermes conduit-push pulse look`), a Pulse turn may read the phone's calendar, reminders, alarms, contacts and status, look up places in Maps between places it names, never where the user is or their saved places (with Where you are on they may, and walking past's shop search on the phone is not a look-up; see Where you are, for Pulse), and on a follow-up about something said in a chat search the web: at most 6 look-ups a turn, 20 Maps and 10 web searches a day, and nothing else, whatever Hermes's approvals say. Why? on its cards says what it looked at. It never changes anything itself: an event or reminder it would add is checked as the calendar tool's write would check it and kept as a suggestion (at most 2 a turn and 5 a day), its own card once the turn's message is in, saying what it adds in words code writes from its fields, with times in the phone's time zone. Add asks the phone for that change once, never in the add-without-asking tier: the app that tapped Add applies it without the phone's own card within 15 minutes, and another device asks there. The card follows the change (adding, added, changed on the phone, couldn't add, not added, expired), and Undo, after asking, deletes what it added the same way, once. When the tapping app's exchange doesn't get the change to the phone, the Pulse screen says so, and its next exchange tries again. Not now drops it. A suggestion is always a card of its own, never one of a morning brief's. While a Pulse turn is in flight in its chat, the calendar and phone tools refuse changes from that chat, and from a call Hermes names no chat for (`pulse_turn`). The app shows the switch and Why?'s look-ups to a plugin that reports `pulse_look`, and suggestion cards to one that reports `pulse_proposals` (2026-10-27, Eric chose to build the gaps in order; notifier #415, #417, #1356).
- The morning brief brings what Pulse remembers about today's events: with Pulse memory on, for each timed event left today, soonest first, the open items that share a name with it (its people when the phone shares them, a name in its title) or a word few items have, at most five in all, looked up in code with no model, so the brief can say "lunch with Dan at 1: he started the new job on Monday" (2026-10-27, Eric chose to build the gaps in order; notifier #422).
- How much a Pulse push may interrupt, and a private one's words, follow the Notifications rulings; where the user is, the Where you are, for Pulse rulings (2026-10-27, notifier #420, #422, #423, #424, #1379).
- Pulse knows what comes next. The candidate list reads what got done since the last report and the timed events on the phone's calendar that ended since then, and may bring up a next step after one: the hotel once the flights are booked, the cleaning the dentist said to book. Code keeps one only when it names the done item or the ended event it follows, at most 2 a report. Next steps have a level of their own in What Pulse learned, held for the morning brief by default (Eric chose Morning brief, 2026-10-27), and their cards are titled "Next step", tinted indigo; Do it opens the chat of what it follows, or a new one. A job whose runs fail covers nothing (notifier 0.106.0, `pulse_next`).
- A Do it that stalled comes back once: nothing sent from the chat a day after Do it, or Pulse's checks finding it still not done, brings the card back at the next steps' level, never twice, and not once its item closed or the user marked it done, put it off or rated it not useful. Its Why? says when Do it was tapped in the App Language, from the feed's `back` and `back_acted_at` (notifier 0.107.0).
- A phone reminder comes up once, however often it's moved: the report's list keys each open reminder, and a card about one isn't made again within a week, or at all while it's open once its card was put away for good or rated not useful. A reminder due within a day still comes up the first time (2026-10-27, Eric: three cards for one cipher-lock reminder he kept moving back, "there just wasn't a reason to show it 3 times"; notifier #429, 0.106.1).

**Open gaps**
- Create Pulse chat in Settings > Pulse hasn't been tried on a real host: it must make a chat Pulse finds before anything is sent in it.
- The app paths above aren't checked by the map check while they live only on `pulse`; they go in backticks if the app side ever reaches main.
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
- Not now's choices read the night and the brief's time on the phone's clock, while the plugin keeps them in Pulse's time zone: the two differ only when Settings > Pulse sets a time zone other than the phone's.

**Checked:** 2026-10-29, at #1473 on the `pulse` branch (a card from a Kanban task's worker links the task and Do it starts a new chat, with notifier #458; pushes, the Watch, What Pulse left out and learned needed no change); 2026-10-28, at #1426 on the `pulse` branch (the entry as main has it after #1423, with the Walking past switch in its Settings > Pulse lines); at #1423 (the look ahead's ruling names its picks held for a place or a shop, and the look-ups' ruling points to Where you are, for Pulse, for Maps from where the user is and walking past's own search); 2026-10-27, at #1398, carrying the `pulse` branch's entry: #1392, with notifier 0.106.0, 0.106.1 and 0.107.0 (next steps: their title and tint, Do it's message and their row in What Pulse learned; a card back after a stalled Do it: its Why? in the App Language; the morning brief, pushes, the Watch and calls from Hermes needed no change); 2026-10-27, at #1383, carrying the `pulse` branch's entry: #1379 (Where you are, with notifier #420, #422 and #423, in its own entry; a push's level and private pushes, with notifier #424: Settings > Pulse's Where you are and Hide private reminders on the Lock Screen, the place a promise waits for on What Pulse remembers, "where you are" in what a card's turn looked at and the extension's private line; the brief's items related to today's events; the Pulse screen, Quiet for today, the Watch, calls from Hermes, the Shortcuts inbox and Do it's new chat needed no change); 2026-10-27, at #1375, carrying the `pulse` branch's entry: #1356 (looking first and suggestions, with notifier #415 and #417: Settings > Pulse's Look things up first, Why?'s line on what Pulse looked at, suggestion cards with Add, Not now and Undo and their states, and the phone applying a change approved on a card, saying so when its exchange didn't get it or it doesn't share its calendar; the morning brief's block leaves suggestions out, each its own card; Phone change errors and Phone data sync with the host gained their Pulse rulings); 2026-10-27, at #1345, carrying the `pulse` branch's entry: #1341 (deadlines from the Shortcuts inbox, with notifier #410: Settings > Pulse's Deadlines from Shortcuts switch, What Pulse remembers' Deadlines with who each is from and when it was logged, deadline cards with Done and Do it's message, What Pulse learned's Deadlines row and the inbox as a place, and Settings > Shortcuts inbox's caption and delete-all message); 2026-10-27, at #1340, carrying the `pulse` branch's entry: #1339 (yearly dates and the look ahead, with notifier #407: birthdays and anniversaries from the chats and the picked people every year, the daily look two weeks ahead held for the brief, What Pulse left out's look ahead section, a yearly fact's day in What Pulse remembers, and People's caption, which says Pulse's memory has to be on); at #1332, carrying the `pulse` branch's entry: #1318 (Pulse at the right time, with notifier #399: the night, waiting while busy, Wrong time and its lesson, and Not now's choices at night) and #1326 (what got done elsewhere, with notifier #400: memory's close marks the thing's cards, a reminded commitment stays closable for two weeks, report items Pulse found on its own are read again, a card put back with Undo isn't marked again from its chat, and a card done while it's put off shows as done, with Undo and Wrong time under it when that put it off); at #1308, carrying the `pulse` branch's entry: #1302 (what learning decided, with notifier #394: Why? names it, What Pulse learned's Reset and Start over, and What Pulse left out with Bring it up; and Quiet for today's retry waits for a call, kept across a relaunch on the day it was pressed) and #1306 (the morning brief folds from its header and stays folded until it's opened again or a card in it comes back open); at #1297 (a Pulse push tapped during a call no longer switches and opens once the call ends, like any notification, and Quiet for today's retry waits for the call the same way; the `pulse` branch gets both with its port); at #1293 with notifier #392 (the lease after a plugin update; the `pulse` branch's older-copy line needed no change); at #1292 (the Watch joins Siblings), carrying the `pulse` branch's entry: #1286 (learning, with notifier #385), #1285 (quiet times, with notifier #383), #1283 (Why? on report cards, with notifier #381), #1278 (Not now until when, with notifier #380), #1277 (the note to Pulse, with notifier #378) and #1275 (Do it's message and icon); 2026-10-25, at #1266, with #1264 on the `pulse` branch and notifier #375 (Pulse's model, ruled in #1262); the app side at #1240 on the `pulse` branch, with notifier #362 and #364, carried to main in #1241.

## Where you are, for Pulse

Pulse using where the user is, once they turn it on: what they said they'd
do at a saved place comes up as they get there or leave, a pick from the
daily look ahead can wait for a place or a kind of shop the phone watches
(walking past), and Pulse's look-ups can start from where they are. Like the
rest of Pulse's, its app side is only on the `pulse` branch.

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
- App, on the `pulse` branch only, so not in backticks (the map check reads main): Conduit/Services/PulseSettings.swift (PulseState's whereYouAre, whereReady and walkingPast, PulseMemoryPlace), Conduit/Views/PulseSettingsViews.swift (the switch, its caption and the line when Pulse can't read the location yet, the Walking past switch, its caption and the lines when this iPhone isn't watching shops (Location settings, or saved places using every place iOS lets Conduit watch), which update as Location settings change, either switch or Pulse's own off, turned off here or found off when the page loads, stopping this iPhone's watches at once through LocationSharingController.forgetSpots, and all three on sending at once so the reply brings the shops to watch; a reply to a batch sent before the off is ignored and a batch still connecting then carries no shop entries, shops becoming allowed again in iOS Settings sends at once, and a change made elsewhere otherwise reaches this iPhone with the host's next reply, and a promise's place in What Pulse remembers), Conduit/Services/PulseFeed.swift (pulseReadsWhere, and "where you are" in what a card's turn looked at), Conduit/Location/PulseSpotWatcher.swift (walking past: the shops searched and watched, first state, entries), Shared/Location/LocationSpots.swift (watches, entries, the sealed reply, PulseSpotState), Conduit/Location/LocationSharingController.swift (watchesSpots, spotEntered, sendNow's spot_entries and spots_room), Conduit/Location/LocationSyncEngine.swift (spotsReplied), Shared/Location/LocationBatch.swift and Shared/Location/LocationSharedStore.swift (spot entries in the batch and unsent, spots.json)
- Location settings the Walking past lines follow: `Conduit/Views/LocationSettingsViews.swift` (background sharing at Precise, Always and Precise Location for Conduit, and saved places, whose count can leave iOS no room to watch shops)
- Notifier: `notifier/pulse_places.py` (the switch and whether the phone shares in the background, moments, place words to saved places, what waits for a place, what Pulse remembers about a place, the look ahead's picks held for a place with `bring_up`, `settle_picks` and `release_picks`, and what `pulse where` says), `notifier/pulse_followup.py` (`waits_for_place`, `place_reached`), `notifier/pulse_ahead.py` (a pick's `moment`), `notifier/pulse_memory.py` (the place words), `notifier/pulse_store.py` (moments, `place_words` and `place_on`, and the cards at level `moment`), `notifier/pulse_tools.py` (location reads behind the switch), `notifier/dashboard/plugin_api.py` (`_location_ingest` hands arrivals and departures to Pulse), `notifier/pulse_control.py` (`where`, `where_ready`, a memory item's `place`), `notifier/cli.py` (`pulse where`, `pulse spots`), `notifier/pulse_spots.py` (walking past: watches by intent and circle, the reply, entries made moments with their reach, lateness), `notifier/location_store.py` (`spot_entries`, `spots_aad` and the sealed `reply`, only at Precise), `notifier/docs/privacy/index.html` (what Pulse keeps of walking past)
- Tests: `notifier/tests/test_pulse_places.py` (the switch, moments, places in what memory keeps, a reminder that waits for its place, and what a place brings up), `notifier/tests/test_pulse_held.py` (the look ahead's picks held for a place), `notifier/tests/test_pulse_spots.py` (walking past); the app's ConduitTests/PulseSettingsTests.swift (Where you are, Walking past's state, and a promise's place in What Pulse remembers), ConduitTests/LocationSharingTests.swift (Walking past turned off drops the shop entries waiting to be sent) and ConduitTests/LocationSpotsTests.swift (walking past: the shared vector, the batch, the watcher), on `pulse`

**Rulings**
- Where you are is off until the user turns it on, in Settings > Pulse or with `hermes conduit-push pulse where on`, and separate from sharing location with Hermes. Pulse reads where the user is only while it's on and Conduit shares the location in the background, not paused; Settings > Pulse says when it can't read it yet. A private place is never read. Off reads nothing and deletes the arrivals and departures and the shops come near that Pulse kept, and so do turning Pulse off and wiping location (turning walking past off deletes the shops alone); the places on what Pulse remembers stay, like the rest of its memory. The app shows the switch, a promise's place and "where you are" in Why?'s look-ups to a plugin that reports `pulse_where` (2026-10-27, Eric's card on step 5: Opt in; notifier #420, #1379; the shops, 2026-10-28, Eric in the Pulse thread, as for walking past below).
- A commitment or promise said for a place ("next time I'm at Costco", "when I leave work") keeps the place's words, only when they're on the item's own line, never guessed. They name a saved place by its name or its kind ("home", "work" or "the office", "the gym", "school"), and a kind's words name only a place of that kind; words that name no saved place match one saved later. The item waits for its place, 30 days or a week past its date, instead of checks on a schedule. Getting there (or leaving, when that's what was said) makes it due: checked as any follow-up, with where the user is and what Pulse remembers about the place, its reminder goes at once and time-sensitive, and Why? says so. Nothing is made due at night, on a quiet day, in a part of the day closed for follow-ups, during an event or a Focus that holds calls (driving doesn't count), or with follow-ups off or kept for the brief: it waits for the next time (2026-10-27, notifier #420, #422).
- Arrivals and departures at saved, non-private places, at most 15 minutes old, reach Pulse from `/location/ingest`, here and in each profile that reads this location, and Pulse handles them first on its next tick; each is kept a day. One with nothing waiting for it says nothing yet: what it would have brought up is kept for `pulse where` to list, to judge before it speaks (2026-10-27, notifier #420, #422).
- The daily look ahead may hold a pick that would push for a saved place it listed, until the start of the pick's day and at most two weeks, ten at once. The held card waits off the Pulse screen, read every six hours like a card held for the brief. The first time the user gets to (or leaves) the place where Pulse may speak up, a turn of its own brings it up, one pick a moment, looking things up first but never the web, and pushes as "Pulse noticed something", time-sensitive. A turn that doesn't go out leaves it waiting. At its window's end, with Where you are off, or once its kind is made quieter than a push, it comes on the screen without a notification; done while it waited, it goes where it was made, as seen (2026-10-27, notifier #423, #424).
- Walking past: the look ahead may hold a pick for a kind of shop (`"moment": {"spot": "a florist"}`), held as a saved place's pick is, in the same window and the same ten at once, and an item said for a place that matches no saved place is watched by its words. Only search words go to the phone, in the sealed reply to a location batch that carries `spot_entries`, at most six; it searches Apple Maps near where it is, watches the nearest three per search word, taken in turn, with a second CLMonitor in what saved places leave of iOS's twenty (at most ten in all), searches again after moving 1 km (at most every 30 minutes) or starting or stopping driving, and reports the shop's name, when, and a fresh fix's distance, accuracy and speed, never the shop's coordinates. Only with Pulse, Where you are and walking past on (on by default; the Walking past switch in Settings > Pulse, shown under Where you are while it's on and only when GET /pulse reports `spots` (notifier 0.111.0, so an older plugin shows no switch), `pulse spots off` or PUT /pulse's `spots` turns it off alone and forgets its entries; its caption says what the phone searches and what the gateway learns), and while background sharing is at Precise, with Always and precise location, not paused; nothing inside a private place. The phone's Apple Maps search is its own, not one of Pulse's look-ups: it doesn't count against their caps, and the host learns only what the phone reports of an entry. Each watch has an intent sizing its circle, aimed at a useful chance to act rather than the shop's edge: an opportunity (a pick's default) 750 m walking and 3 km driving, any entry counts; an errand (an item's default) 100 m, the fix inside it; an arrival 100 m, the fix inside with its accuracy; the look ahead may set its own `radius_m`, within its intent's bounds (an opportunity's 500 m to 5 km, an errand's and an arrival's 50 to 300 m). The phone's search has no daily cap: it runs on the phone, costs the host nothing, and only moving 1 km or starting or stopping driving sets it off, at most every 30 minutes. Pulse says the user came near the shop or got to it or right by it, never that they went in. Every entry is kept 30 days with how late iOS told the app (`pulse spots`), and it ships live, no shadow mode (2026-10-28, Eric in the Pulse thread; notifier #435, #1414).
- With Where you are on, Pulse's look-ups may read `conduit_location` and ask Maps from "me" or a saved place, within the look-ups' caps, each read listed in Settings > Location's When Hermes read your location under the Pulse chat (2026-10-27, notifier #420).

**Open gaps**
- None of it has been tried on a phone against notifier 0.104.0, nor the Walking past switch and its caption against notifier 0.111.0, nor arrivals from a real day's location sharing (#1379, #1426, notifier #420, #422, #423, #424).
- A held pick also matches another saved place with the same name: the model names the place by its name, and the name keeps a pick working after its place is saved again (notifier #424).
- Walking past hasn't been tried on a phone: how late iOS fires for 100 m circles, and whether a 3 km driving circle helps or nags, are what the kept timings are for (notifier #435, #1414). Arriving at or leaving a place that is neither saved nor a watched shop still wakes nothing.
- An item said for a place that has no saved place keeps waiting for one until it expires; meanwhile, with walking past on, its words are watched as a kind of shop and coming near one makes it due as getting there would. What Pulse remembers says it waits, but nothing asks the user to save the place.

**Checked:** 2026-10-28, at #1428 on the `pulse` branch, carrying #1427 from main (the switch shows only when GET /pulse reports `spots`, notifier 0.111.0; the untested-switch gap names that version; Settings > Location's code, which its lines follow); at #1426 on the `pulse` branch (the Walking past switch and its caption in Settings > Pulse, closing that gap; the shops' deletion cites the walking-past decision); at #1423, carrying the `pulse` branch's entry: #1414 (walking past, from notifier #435 and the app's spot watcher; the rest as at #1379).

## Artifacts

The files, pages and links Hermes made, listed for every chat (the Chats
bar's Artifacts page) or for one chat (its … menu), opened in the chat's own
viewers, with Show in Chat.

**Siblings:** the Artifacts page · a chat's own Artifacts sheet · Bot Chats
(kept in the bot's own profile) · All (every included profile's chats) ·
group rooms (no Artifacts list) · the notifier's artifacts route · README.md

**Code**
- List model and merge: `Conduit/Services/Artifacts.swift` (ArtifactItem, ArtifactSource, ArtifactFeed, ArtifactsClient)
- Which stores a list reads, a chat's ids, Show in Chat: `Conduit/Services/AppState+Artifacts.swift` (artifactSources, activeChatArtifactSessionIDs, botChatIDs, showArtifactInChat)
- Screens: `Conduit/Views/V2/V2ArtifactsViews.swift`
- A chat's store: `Conduit/Services/AppState.swift` (botStoreProfile, openLinkedBotChat, openOtherProfileChat)
- Host: `notifier/artifacts_index.py`, `notifier/dashboard/plugin_api.py` (GET /artifacts, one profile per request)

**Rulings**
- A list reads each store the chats it covers are kept in: a Bot Chat's sheet reads the bot's profile, and the Artifacts page reads the profile in use, each other profile All shows while it's on, and every other bot's Bot Chat, merged newest first (2026-10-24, #1203, Eric's report).
- Stores are read one at a time (the host reads two lists at once at most) and each shows as it arrives; a refresh keeps the list it is refreshing until every store answers. A bot's chat or other profile that can't be read leaves the rest listed.
- A bot whose profile is read whole (the profile in use, or one All shows) isn't read again for its Bot Chat; that chat's rows still go by the bot's name and open the way Bots opens them.
- The profile in use is always read, even when All leaves it out.
- A Bot Chat has no row in the workspace's chat list, so its ⋯ menu finds its ids from the chat itself (with the durable id Hermes confirmed under the bot's profile, so a relaunch or a reopened runtime still finds it) and the roster's registry id and lineage tip (2026-10-24, #1218, Eric's report: the item was greyed out).
- A picture image generation made is listed: the host reads `image_generate`'s result, a saved file as a written image and a hosted one as an image link (2026-10-24, #1218 with notifier #353, plugin 0.71.1, Eric's report: a bot's generated pictures were missing).
- One host path is one artifact across stores: profiles share the host's files, so a file two stores list shows once, at its newest mention.
- A file still opening is dropped when the list moves to another server or profile, and only the latest open clears the spinner. Every reload, including one on a dashboard without artifacts, outdates the request before it (2026-10-24, from #895's review, #1191).

**Open gaps**
- Group rooms' messages aren't listed: a room has no Artifacts list, and its members' replies stay out of the Artifacts page.

**Checked:** 2026-10-24, #1218; the page and Show in Chat at #1203; opens and reloads at #1191.

## Bots: create and edit

New Bot and Edit Bot, and what they write to the bot's Hermes profile.
Hermes Desktop's bot editor writes the same records, so both apps show the
same bot.

**Siblings:** New Bot · Edit Bot · Hermes Desktop's bot editor (same
profile records) · the bot's face in the Bots list, its Bot Chat and group
rooms · generated pictures, shared with group pictures · profile pictures in the profile picker · the SOUL a new bot is
born with (the messaging section older gateways need) · the Bots list's row
menu (New Chat, Groups, Pin, Hide, Duplicate, Delete) and its Hidden section,
as on Desktop's bot row · Edit Bot's MCP catalog (adding a server with
its keys, OAuth sign-in through Safari, and the sign-in loopback shared with
Hermes sign-in) · the text that describes them (the editor's footers
and README.md's bots line)

**Code**
- Editor: `Conduit/Views/BotEditorSheet.swift`, `Conduit/Views/BotModelPicker.swift`, `Conduit/Views/BotCapabilitiesView.swift`, `Conduit/Views/BotRosterView.swift`
- Writes: `Conduit/Services/BotManagement.swift` (BotCreateRequest, BotCapabilities, BotSoul, BotMetaPatch), `Conduit/Services/AppState.swift` (createBot, updateBot, saveBotModel, loadBotCapabilities, openNewBotChat), `Conduit/Services/HermesClient.swift` (createBotProfile, describeBotProfile, configureBotProfile, configureBotModel, botRuntimeCheck)
- Roster: `Conduit/Services/BotModeModels.swift`
- MCP catalog and sign-in: `Conduit/Views/BotCapabilitiesView.swift` (catalogRow, signInRow, BotMcpKeysSheet, BotMcpBrowserView), `Conduit/Services/BotMcpSetup.swift`, `Conduit/Services/AppState.swift` (loadBotMcpSetup, addBotMcpServer, signInBotMcpServer), `Conduit/Services/HermesClient.swift` (botMcpCatalog, botMcpServers, addBotMcpServer, setBotMcpKey, testBotMcpServer, botMcpOAuth), `Conduit/Services/NativeOAuth.swift` (NativeOAuthLoopbackServer's relay mode, NativeOAuthFlow.callbackValues)
- Row menu: `Conduit/Views/BotRosterView.swift` (BotRosterRow, botRooms, the Hidden section), `Conduit/Services/BotManagement.swift` (BotDuplicate), `Conduit/Services/AppState.swift` (duplicateBot, setBotHidden, setBotPinned), `Conduit/Views/GroupChatView.swift` (GroupCreateSheet's preselected bots)
- Generated pictures: `Conduit/Views/GeneratePictureSheet.swift`, `Conduit/Services/PictureGeneration.swift`, `Conduit/Services/GroupRoomPictures.swift` (group pictures' list and upload), `Conduit/Views/GroupChatView.swift` (GroupRoomPicturePicker, GroupRoomActionItems), `Conduit/Views/V2/V2ConversationScreen.swift` (the V2 room menu's picker), `Conduit/Services/AppState.swift` (refreshPictureGeneration, generatePicture), `Conduit/Services/HermesClient.swift` (imageGenerationAvailable, generateImage)

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

**Open gaps**
- New Bot's model pick isn't guarded: `profiles.create` pins it without the gateway's expensive-model check, the same as on Desktop.
- Desktop's drawn faces, shapes and pets show only as stills; Conduit draws an initial on the color.
- The group picture switch guard has no test: it needs a ready DashboardTicketBridge double and a room switch mid-request (#1191).

**Checked:** 2026-10-25, at #1222 (configure and MCP add wait in the profile config queue); before that #1192; group pictures at #1191.

## Bot mentions and teammate messages

How the user brings another bot into a chat, and how bots' messages to each
other read in it.

**Siblings:** the @ list while typing · Mention a Bot in the composer's + menu ·
chats, project chats and Bot Chats (the chat's own bot is left out) · group
rooms (their own @ list and recipient picks) · the note that tells the bot
who each tag is · a teammate's delivery in the chat ("Message from Atlas") ·
the sender's step ("Messaged Atlas") · the Live Activity's tool line ·
Hermes Desktop's bot chat · chat list previews and quotes · Read Aloud and live voice ·
the bot's SOUL messaging section · README.md's bots line

**Code**
- Tags and the note to the bot: `Conduit/Services/BotMentions.swift`, `Conduit/Services/GroupChatModels.swift` (MentionAutocomplete)
- Composer: `Conduit/Views/Components/ComposerBar.swift` (mentionCandidates, attachmentButton), `Conduit/Views/Components/GroupRoomComposer.swift`
- Teammate messages: `Conduit/Services/BotTeammateMessages.swift`, `Conduit/Views/ChatView.swift` (TeammateMessageNote, TeammateReplyNote, SettledToolCardContent.stepTitle, runningToolTitle), `Conduit/Views/ChatRowState.swift` (teammateReplies, botLabels), `Conduit/Views/ChatActivityRows.swift` (ChatStepSubject, ChatWorkingLine.currentToolTitle)
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
- A "Messaged" step names the bot from the roster, and redraws when the roster loads (2026-10-24).
- Group rooms have no Mention a Bot item: their recipient picks do the same job (2026-10-24).

**Open gaps**
- None known.

**Checked:** 2026-10-24, at #1192.

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

**Open gaps**
- Nested lists are flattened: an indented sub-list draws as its own list at the left edge.
- Read Aloud and live read-back speak the numbers as written, so "1. 1. 1." is spoken 1, 1, 1 while the screen draws 1, 2, 3.
- Copy response under a reply copies the Markdown source, so "1. 1. 1." copies as written while the screen draws 1, 2, 3; selection Copy matches the screen where the list is selectable text (prose runs, one text view).
- A list drawn as a block view (outside a prose run, e.g. under VoiceOver or next to a task list) keeps its number outside the selectable text, so selection Copy leaves the number out.
- A reply that grows past the large-document size while streaming is parsed per promoted slice, so a list cut at a slice boundary carries on from the number written on the slice's first item (right when numbered 1, 2, 3; restarts for "1. 1. 1.").
- A marker past two digits ("100.") can crowd its column in the block view.
- A single list item too big for one long-reply chunk is split into paragraphs that each repeat its number.
- A long reply's continuation chunks draw list items as paragraphs with the number baked in, so they lose the list's styled marker column.

**Checked:** 2026-10-23, at #1175.

## Composer drafts

Unsent words, files and a quoted reply wait in the composer they were typed
in until they're sent, whichever way the user leaves.

**Siblings:** chat composer (chats, project chats, Bot Chat) · New Chat ·
a saved copy's composer and its waiting message ("Sends when connected") ·
group rooms · the full editor · the notices that say where words went

| Leaving by | Chat composer | Group room |
|---|---|---|
| Back, or another chat from the list | text, files and quote kept | text and files kept |
| A room opened over the chat | kept | not applicable |
| Sign-out or another server | dropped | dropped, files deleted |
| The room disbanded or left the list | not applicable | dropped, files deleted |

**Code**
- Chat composer: `Conduit/Views/Components/ComposerBar.swift` (loadDraft, saveDraft, handoffComposer, onDisappear, draftKeyToKeep, restoreSubmittedDraftIfNeeded), `Conduit/Views/Components/ComposerDraftStore.swift` (clearCount)
- Waiting message: `Conduit/Services/AppState+PendingSend.swift` (returnPendingComposerSendToDraft, restoreFailedPendingComposerSend, pendingComposerSendNotice), `Conduit/Services/AppState.swift` (conversationIsGone), `Conduit/Models/PendingComposerSend.swift`
- Group rooms: `Conduit/Views/Components/GroupRoomComposer.swift`, `Conduit/Services/AppState.swift` (activeRoomDraft, activeRoomAttachments, pruneRoomStores)
- Tests: `ConduitTests/ComposerDraftStoreTests.swift`, `ConduitTests/GroupChatSessionSafetyTests.swift`, `ConduitTests/OfflineChatCacheTests.swift`, `ConduitTests/AppStateChatResumeTests.swift`

**Rulings**
- Drafts live in memory per (profile, chat), and a sign-out or server switch clears them on purpose; nothing the composer held before the clear goes back in after it: not when it goes away, hands off to another chat or a room, nor when a send that was on its way fails (2026-10-24, #1185).
- A waiting message is never sent on its own after it's handed back. When Hermes says its chat is gone, its words go into the composer on screen, unsent, with a notice saying so (2026-10-24, #1185).

**Open gaps**
- Drafts don't outlive Conduit being stopped; only a waiting message does (as a file).
- A waiting message left from an earlier run whose chat is gone still goes back into that chat's draft: the gone chats are only known for this run.
- A room's quoted message and its "To" picks aren't kept when the room is left.
- A room that's disbanded while another dashboard is in use keeps its staged files until that dashboard is opened again or the user signs out.

**Checked:** 2026-10-24, at #1185; a failed '/command' put back without its suggestion list over it at #1191 (#891 review).

## A new chat that something waits on

Some actions start a chat and then put something in it: a message sent from
the empty canvas, a screenshot, a Hermes call setup prompt. The thing goes
into the chat that action created, never into another one that opened
meanwhile.

**Siblings:** the composer's send from the empty canvas · Ask Hermes About
Screen (the voice sheet's screenshot and a screen question) · Settings' Hermes
test call and watch prompts · a Classic voice conversation's fresh chat ·
New Chat and its focus · a widget's or Shortcut's New Chat · the /new command
· Pulse's Do it on an item from no chat or from a Kanban task's worker (the `pulse` branch)

**Code**
- Creating the chat: `Conduit/Services/AppState.swift` (createNewSession and createAndReconcileSession return the chat they opened; startChatForComposerSubmission; startNewChat and focusNewChatComposer; prepareVoiceConversation)
- Screenshots: `Conduit/Services/AppState+ScreenQuestion.swift` (startChatForScreenshot, openScreenQuestion)
- Hermes calls: `Conduit/Services/AppState+HermesCalls.swift` (startHermesCallsChat)
- Widget and Shortcut launches: `Conduit/Services/AppState+WidgetLaunch.swift`
- Pulse's Do it, on the `pulse` branch only, so not in backticks: Conduit/Services/AppState.swift (startPulseNewChat), Conduit/Services/PulseFeed.swift (actOnPulseCard)
- Tests: `ConduitTests/SessionRenameTests.swift`; on the `pulse` branch, ConduitTests/PulseFeedTests.swift

**Rulings**
- What waits on a new chat goes in only when the chat createNewSession returned is still the one open. Another chat opened or created meanwhile (a voice action, a screen question, a notification) gets nothing. The message stays in the composer, the screenshot goes back or waits, and the user is told (2026-10-24, #941's review, #1191).
- New Chat focuses the composer only on the chat it made. A Classic voice conversation files and archives only its own new chat under Voice; a fresh one asked for fails when another chat took the screen.
- Pulse's Do it on an item from no chat (and, since #1473, on one from a Kanban task's worker, which Hermes won't reopen as a chat) starts a chat only when New Chat can start one at once, and puts the reminder only in the chat its own create returned, while that one is still open. The Pulse screen stays up until then, so a chat that didn't start leaves it there to say why (2026-10-25, #1240 on the `pulse` branch).

**Open gaps**
- A widget's or Shortcut's New Chat and /new put nothing in the chat, so they only report whether the open chat changed.

**Checked:** 2026-10-29, at #1473 on the `pulse` branch (Do it on a card from a Kanban task's worker takes the same new chat); 2026-10-25, #1241 (Pulse's Do it, from #1240 on the `pulse` branch); main's code as at #1191.

## Composer Return key

The optional hardware-keyboard shortcut in Settings > Keyboard: with it on,
Return sends the composer message and Shift-Return starts a new line. It
starts on on a Mac and off on iPhone and iPad; the on-screen keyboard's
Return key always inserts a new line.

**Siblings:** the Keyboard caption ("When on, Return sends and Shift-Return
starts a new line.", done, #1208) · the toggle's accessibility hint (not
needed, it already says the setting applies to hardware keyboards only) ·
the two default footnotes, Mac on and iPhone/iPad off (not needed, each
states the default for its device) · the hardware-keyboards caption (not
needed, shown only off a Mac and already says the on-screen Return key is
unchanged)

**Code**
- Policy: `Conduit/Views/Components/ComposerReturnKey.swift` (ComposerReturnKey)
- Settings: `Conduit/Views/AuxiliaryViews.swift` (ComposerReturnKeySettings)
- Tests: `ConduitTests/ComposerReturnKeyTests.swift`

**Rulings**
- The caption describes the option, not current behaviour, because the
  option starts off on iPhone and iPad (2026-10-24, #1208, review of #1190).

**Open gaps**
- None known.

**Checked:** 2026-10-24, at #1208, carried in #1229.

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
events arrive, or stays where the user scrolled to read.

**Siblings:** chats, project chats and Bot Chat (one scroll engine) · group
rooms · a delegate agent's live tail sheet · the jump-to-latest button · how
much history an open transcript keeps

**Code**
- Chats: `Conduit/Services/ChatScrollEngine.swift`, `Conduit/Views/ChatScrollSurfaceLocator.swift`, `Conduit/Views/ChatView.swift` (jumpToLatest)
- Group rooms: `Conduit/Views/GroupRoomScrollFollow.swift` (GroupRoomFollow, GroupRoomScrollLocator), `Conduit/Views/GroupChatView.swift` (isFollowingLatest, jumpToLatestButton)
- Delegate tail sheet (its own follow state and Latest button): `Conduit/Views/ChatSupportSheets.swift` (DelegateAgentTailSheet)
- Room history kept: `Conduit/Services/GroupChatModels.swift` (GroupRoomReplay tailWindow, retainedLimit), `Conduit/Services/AppState.swift` (the open and resync tail windows)

**Rulings**
- Only the user's own scroll leaves following; new content never does. Being near the bottom (40 pt), the jump button or sending returns to it (chats: ChatScrollEngine; group rooms 2026-10-24, #1184).
- An open group room keeps a bounded tail: it opens on the last 200 events, and polling trims back to 200 once it holds 400 (2026-10-24, #1184).

**Open gaps**
- Group rooms have no "Load earlier messages", so history above the 200-event tail isn't reachable in the app.
- The Responding row reads the kept tail, so a discussion longer than 200 events (when opened, or after a trim) can lose it while a member still works.
- Trimming a busy room's tail moves rows above a reader scrolled to its top, once per 200 new events.
- Group rooms keep the scroll position by row id (ScrollViewReader), not by the chat engine's same-pass layout, so a follow can animate where a chat snaps.

**Checked:** 2026-10-24, at #1184.

## Reconnecting to Hermes

How the chat connection comes back after it drops, and when it tries at
once instead of waiting out its backoff.

**Siblings:** a socket that closed (handleDisconnect) · the network path
changing · someone waiting by voice (a call's request, CarPlay back on
screen) · CarPlay, locked, Watch and CallKit calls with the app in the
background · a failed sync's retry · the backoff itself

**Code**
- Reconnects: `Conduit/Services/AppState.swift` (handleDisconnect, scheduleReconnect, scheduleReconnectAfterFailedSync, networkPathChanged, reconnectNowForWaitingVoice, recoverTransportForCarPlayIfNeeded, handleCarPlaySceneWillEnterForeground)
- Network path: `Conduit/Services/PowerPolicy.swift` (pathSatisfied), `Conduit/Services/HermesClient.swift` (networkPathChanged, the ping of an open socket)
- Tests: `ConduitTests/ReconnectBackoffTests.swift`, `ConduitTests/CarPlayTransportRecoveryTests.swift`

**Rulings**
- A reconnect that skips the backoff needs a usable network path: without one no attempt can work, and the path coming back reconnects at once anyway. A drop mid-reply and someone waiting by voice both check it (#1060; #846 follow-up, #1191).
- The network path changing reconnects at once without reading the path: it runs before the path monitor holds the new one, so a check there would stall recovery for the whole backoff (#1191).
- Someone waiting by voice skips the backoff but keeps its count, so one request after another against a gateway that is down doesn't reset it (#1060).

**Open gaps**
- `recoverTransportForCarPlayIfNeeded(immediately:)` still reconnects at once without a path check (CarPlay connecting only).

**Checked:** 2026-10-24, at #1191.

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

**Checked:** 2026-10-24, at #1191.

## Skill and tool switches

The installed skills' and toolsets' switches in Settings > Capabilities, and
the lists they sit in.

**Siblings:** installed skills and toolsets (AppState) · the catalog, tool
counts, backends, MCP servers and plugins (CapabilitiesStore) · the Skills
and Tools tabs · the bot editor's skills, tools and MCP lists (see Bots:
create and edit) · the skill, toolset and catalog skill detail pages · the Kanban
task composer's skill picker · the Capabilities captions ("Changes apply
to new sessions."; no other behavior text describes these lists)

**Code**
- Installed lists and switches: `Conduit/Services/AppState.swift` (loadCapabilities, toggleSkill, toggleToolset, capabilityLoadGeneration, capabilitiesOwner, currentCapabilitiesOwner, capabilitiesAreCurrent, capabilityRowsAreCurrent, retireCapabilitySnapshot, CapabilitySnapshotOwner, CapabilityDetailScope, CapabilityLoadPolicy), `Conduit/Services/CapabilityToggleWrites.swift`
- The rest of the page: `Conduit/Services/CapabilitiesStore.swift` (configure, serves)
- Views: `Conduit/Views/CapabilitiesView.swift`, `Conduit/Views/Capabilities/CapabilitySkillsTab.swift`, `Conduit/Views/Capabilities/CapabilityToolsTab.swift`, `Conduit/Views/Kanban/KanbanTaskComposerView.swift` (KanbanSkillsPickerSheet)
- Tests: `ConduitTests/KanbanTests+Capabilities.swift`, `ConduitTests/KanbanTests.swift` (CapabilityLoadPolicy)

**Rulings**
- A list read that started before a switch was flipped commits nothing, in AppState and in CapabilitiesStore alike (#867; AppState's lists at #1191).
- Switches reach Hermes one after another in the order flipped, since each rewrites one config.yaml. A failed write puts back what Hermes last confirmed only when no newer flip of that switch is on its way, and a flip a newer one replaced reports no failure (#868 follow-up, #1191).
- The installed lists belong to a dashboard, its bridge and a profile, not a profile name: two dashboards can both have "default". Another dashboard's rows never show, act or seed a picker, a dashboard switch clears them, and Turn All On/Off stops once the list it started from isn't the one showing, and a pushed detail page reads its skill or toolset again once Capabilities points at the new dashboard and profile; a catalog skill's page keeps to the one it was opened for and shows only its name and description after a switch (2026-10-24, #1005, #1219; Eric approved the #1005 fixes).
- Switches, the store's other config-changing writes and the bot editor's writes wait their turn with every other profile config save (Profile config saves), so a settings GET→PUT can't put a flip back (2026-10-24, #1222).

**Open gaps**
- AppState's list reads go through a live DashboardTicketBridge with no test seam, so its generation guard has no test.
- Whether a list read can overwrite a flip in the bot editor's lists hasn't been checked.
- The Kanban skill picker says "No skills match." when it withholds another dashboard's skills, the same as a search miss.

**Checked:** 2026-10-24, at #1219 and #1222.

## Reply progress signals

Everything that reacts to a turn's output as it arrives: the agent's text,
and its commentary between tool calls (`message.interim`).

**Siblings:** the compaction spinner's release · the Live Activity's writing
state · a call's background jobs (follow-up, status, session) · Local Live's
writing-again · the writing haptic

**Code**
- Events: `Conduit/Services/StreamEventParser.swift`, `Conduit/Services/AppState.swift` (handleStreamEvent, the compaction release)
- Live Activity: `Conduit/Services/LiveTurnActivities.swift`
- Calls: `Conduit/Voice/VoiceBackgroundJobs.swift`, `Conduit/Voice/LocalLive/LocalLiveTurnRunner.swift`
- Haptics: `Conduit/Services/Haptics.swift` (signal)

**Rulings**
- Commentary between tool calls is the agent writing, wherever its text is: it releases a compaction claim, shows as writing and moves a call's job along, but isn't spoken (#912 follow-up, #1191).

**Open gaps**
- `Haptics.signal` still plays the writing haptic only for `message.delta`.

**Checked:** 2026-10-24, at #1191.

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

**Checked:** 2026-10-24, at #1191.

## Model lists that fail to load

What a model picker shows before Hermes's model catalog has rows: still
loading, a fetch that failed, or a gateway that lists no models.

**Siblings:** the model sheet · the Model page's Default model, Delegate
model and Fallback models editors · a bot's model picker · the voice job and
voice reply model pickers · the Kanban task composer's catalog

**Code**
- The rule: `Conduit/Views/ModelPickerView.swift` (ModelCatalogState, and the model sheet's modelSection, loadModels)
- Model page: `Conduit/Views/AuxiliaryViews.swift` (ModelCatalogPlaceholder, ProfileModelSettingsDetail, DelegationModelSettings, FallbackModelsSettings)
- Bots: `Conduit/Views/BotModelPicker.swift`
- Voice: `Conduit/Views/GeminiLiveViews.swift` (the voice job and voice reply model settings), `Conduit/Services/AppState.swift` (loadVoiceJobModelProviders)
- Kanban: `Conduit/Views/Kanban/KanbanTaskComposerView.swift` (catalogSection)

**Rulings**
- A failed fetch says "Could not load models." with Try Again; "No models are available from this gateway." is only for a catalog that loaded empty; neither shows while loading. A re-load that fails keeps the rows it had (2026-10-24, from #1016's review).
- A list that didn't load is never edited or saved: Save stays off until the catalog is in.

**Open gaps**
- The voice job and voice reply pickers get `[]` for a failed fetch (loadVoiceJobModelProviders), so they can't tell failed from empty.
- The bot model picker says "Could not load models." without Try Again.
- The Kanban composer shows a failed catalog as "No curated model catalog available", whose manual entry still works.

**Checked:** 2026-10-24, at #1190; a reload that lands under unsaved Fallback models edits keeps them at #1191 (#1016 review).

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

**Checked:** 2026-10-24, at #1190; the paste's pixel bound at #1191 (#892 review).

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
- Pulse, on the `pulse` branch only: Conduit/Services/PulseSettings.swift (PulseRefusal: what a suggestion's refusals say)

**Rulings**
- An error names what is missing: the item ("That item isn't on this iPhone any more."), or the calendar or list it was to move to, which leaves the item in place (2026-10-24, from #876's review, #1190).
- Voice tools turn only a missing item on a change or delete into "read the calendar again for its id"; every other error reaches the model as "It couldn't be changed: <reason>" (or added, deleted, set, cancelled) with the error's own text (2026-10-24, #1190).
- While a Pulse turn is in flight in Pulse's chat, `conduit_calendar` and `conduit_phone` refuse a change asked for from that chat, or from a call Hermes names no chat for, with `pulse_turn`: Pulse is taking a turn there and nothing in it can change the phone, so ask again once its message is in. A suggestion's Add or Undo that the phone store refuses shows the store's own note on the Pulse screen and leaves the suggestion to tap again; Undo before the phone has sent what it added says to try again in a moment (2026-10-27, notifier #417, #1356).

**Open gaps**
- Adding an event or reminder when the phone has no default calendar or list (and the one named is gone) says "That item isn't on this iPhone any more."

**Checked:** 2026-10-27, at #1356 on the `pulse` branch (Pulse's `pulse_turn` refusal and a suggestion's refusals, with notifier #417); 2026-10-24, at #1190.

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

**Checked:** 2026-10-25, Qwen in the siblings, at #1182, carried in #1235; #1231, for the text cap; 2026-10-24, #1223.

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
- Voice: `Conduit/Voice/HermesVoiceConfigurationService.swift` (save, saveLiveTranscription, saveVendorSelection, saveProviderSelection), used by `Conduit/Views/VoiceSettingsView.swift`, `Conduit/Views/SpeechServerSettingsView.swift`, `Conduit/Views/LocalLiveViews.swift`
- AppState: `Conduit/Services/AppState.swift` (updateProfileConfig, setDisplayPreference, setProfileFallbackModels, setProfileMainModel, setVoiceReplyModel, setProfileSetting, toggleSkill, toggleToolset)
- Capabilities: `Conduit/Services/CapabilitiesStore.swift` (request, writesProfileConfig)
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

**Checked:** 2026-10-25, at #1230 (host-run plugin update recorded); at #1222.

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

## Chats top bar and search

The Chats screen's controls: the profile row, the filter, Projects,
Artifacts, New chat and the search field, and how they lay out when the
profiles don't fit beside the controls.

**Siblings:** the chats list · the Projects view (same bar and field) · the
one-row bar (every profile fits) and the stacked bar (profiles on their own
row) · iPad and Mac (same view) · searching messages ("In messages")

**Code**
- Bar layout: `Conduit/Views/V2/V2TopBar.swift` (ViewThatFits: one row, else stacked with lowerLeading under the profiles)
- Controls and search: `Conduit/Views/V2/V2ChatsView.swift` (trailingControls, stackedLeading, barUnstacked, setBarStacked, filterPill, barSearchField, searchField, searchCapsule)
- Message match row ("In messages"): `Conduit/Views/V2/V2SessionRow.swift` (V2ContentMatchRow: two lines of matching text, four at accessibility text sizes)

**Rulings**
- The profiles get their own row when they don't fit beside the controls, and the filter becomes a labeled pill under them (2026-10-22, #1117, Eric).
- In the stacked bar, search is a magnifier leading the controls. Tapping it turns the whole second row (filter and controls) into the field with Cancel until the search is cancelled, the list has no search row, and the filter pill fills the row up to the controls. The one-row bar keeps the field as the list's first row (2026-10-24, #1199, Eric).
- Going from the stacked bar to the one-row bar carries a query over to the list's field and closes an empty open field (2026-10-24, #1199).
- The list's search row follows the bar's layout, starting from the last layout seen (`barStackedKey`). Before any layout is known (first launch) the row stays out until the one-row bar appears; a change of layout (rotation, a profile added) animates it in or out (2026-10-24, #1206: implementation of #1199's open gap).

**Open gaps**
- A launch whose layout differs from the last one seen still starts from the old layout, so the row can show for a frame or arrive a frame late: the iPad was rotated or profiles were added while Conduit was closed, or another iPad window in the other layout wrote the shared key last. Closing it needs the bar's choice before the first frame, which `ViewThatFits` doesn't expose.

**Checked:** 2026-10-24, at #1206; the match row at #1208, carried in #1229.

## Plan card

The agent's plan ("Tasks", from Hermes's `todo` tool) docked above the
composer: a slim line that opens upward into a card, and a sheet with the
whole plan. [docs/PLAN_CARD.md](PLAN_CARD.md) is the design.

**Siblings:** the line · the card · the whole-plan sheet · chats, project
chats and Bot Chat (one chat screen) · group rooms (no plan) · the `todo`
tool result in the transcript, which draws the same items · VoiceOver's
reading of the line and its new-plan announcement

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

**Open gaps**
- The new-plan announcement reads the line's label ("Tasks, 0 of 4 done, now: ..."), with no word saying the plan is new or reopened.
- Two announcements within 450 ms race on the pulse (#1135 review).

**Checked:** 2026-10-24, at #1208, carried in #1229.

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
watches back; see Where you are, for Pulse)

**Code**
- Phone: `Conduit/Phone/PhoneSyncEngine.swift` (pass; approveFromCard on the `pulse` branch), `Conduit/Phone/PhoneSyncModels.swift` (PhoneSyncPause)
- Health: `Conduit/Health/HealthSyncEngine.swift`, `Conduit/Health/HealthSyncModels.swift` (HealthSyncPause)
- Location: `Conduit/Location/LocationSyncEngine.swift` (send, LocationSyncPause; `spotsReplied` on the `pulse` branch), `Conduit/Location/LocationSharingController.swift` (sendNow: keeps the batch on `.failed`; `spot_entries` and `spots_room` in the batch on the `pulse` branch), `ConduitLocationPush/LocationPushService.swift` (a locate answered from the push extension)
- Which 409 means what: `Conduit/Services/HostKeyConflict.swift`
- Voice reads: `Conduit/Services/AppState+VoiceHostTools.swift`, `Conduit/Phone/PhoneVoiceTools.swift`
- Notifier: `notifier/phone_store.py`, `notifier/health_store.py`, `notifier/location_store.py`, `notifier/dashboard/plugin_api.py` (_store_refusal; `_location_ingest`, which hands arrivals and departures to Pulse)
- Tests: `ConduitTests/PhoneSyncTests.swift`, `ConduitTests/HealthSyncTests.swift`, `ConduitTests/LocationSharingTests.swift`; on the `pulse` branch, ConduitTests/LocationSpotsTests.swift (walking past's shop entries in the batch, what drops them, and the sealed reply)

**Rulings**
- Only a 409 that says the host lost this phone's key (`unknown_key`, `bad_seal`) clears the key and sets up again; any other 409 keeps it (2026-10-19, #906; 2026-10-20, #1025).
- A store written by a newer plugin (409 `schema`) pauses with the "update the Conduit plugin" message, keeps the key and keeps what waits to be sent (2026-10-24, #1196).
- A later refusal, timeout or 404 replaces that plugin-update pause with its own message, as for any other pause (2026-10-24, #1196).
- A change approved on a Pulse suggestion's card (Add, or Undo after its question) is applied by the app that tapped it without the phone's own card, once the host has it and for 15 minutes from the tap; that app exchanges at once, and again to report it, and when that exchange doesn't get the change, the Pulse screen says the phone tries again on its next one, or, when the phone doesn't share its calendar, that the change waits for a device that does. Another device, or the same one later, shows the phone's card as for any change (2026-10-27, notifier #417, #1356).
- With Pulse's Where you are on, location's arrivals and departures at saved, non-private places, at most 15 minutes old, also go to Pulse, in this profile and each one that reads the location. Pulse keeps each a day, and turning Where you are or Pulse off, or wiping location, deletes them, with walking past's shop entries; turning walking past off deletes the shop entries alone (2026-10-27, Eric chose Opt in; notifier #420, #1379; shop entries 2026-10-28, Eric in the Pulse thread chose to ship walking past; notifier #435).
- Walking past's shop entries ride the location batch (`spot_entries`, with `spots_room`) and go through the same refusals and pauses: a failed send, a 409 `schema` included, keeps them with the batch; a refusal drops them with it; a pause, a wipe, or the phone no longer watching shops drops what waits. The host answers such a batch with the watches sealed under this phone's key and tied to the batch's id; a reply that doesn't open, or opens to something else, changes nothing and is logged (2026-10-28, notifier #435, #1414).

**Open gaps**
- The dashboard sends the store's code beside its message, but the phone keeps only the message: a reworded notifier message is missed until `Conduit/Services/HostKeyConflict.swift` learns it. Phone and health then pause with the host's reason; location drops the waiting fix, events and shop entries as refused.
- A locate answered from the push extension drops its fix on any failed post, a 409 `schema` included, and shows no pause: it is a one-shot answer, and the app shares its own fix next time.
- A voice read that meets a 409 `schema` tells the model only that the read failed, not that the plugin needs an update.

**Checked:** 2026-10-28, at #1428 on the `pulse` branch, carrying #1427 from main (the shop entries' deletion names turning walking past off); at #1426 on the `pulse` branch (the shop entries' deletion cites the walking-past decision); at #1423, carrying #1414 from the `pulse` branch (walking past's shop entries and sealed reply ride the location batch, with notifier #435; the refusals and pauses apply as for the batch); 2026-10-27, at #1398, carrying #1392 from the `pulse` branch (Pulse's next steps read the events that ended on the host, from what the phone already shares; the sync needed no change); 2026-10-27, at #1383, carrying #1379 from the `pulse` branch (location's arrivals and departures reach Pulse with Where you are on, with notifier #420; the stores' refusals and pauses needed no change); 2026-10-27, at #1375, carrying #1356 from the `pulse` branch (a change approved on a Pulse card, with notifier #417); 2026-10-26, #1247 (location sharing's fix and send work keep Conduit running through BackgroundTaskHold); 2026-10-24, at main e9d9592; the Shortcuts inbox added as a sibling in #1214 (fork CI #87), carried in #1232.

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
- Settings page: `Conduit/Views/ShortcutInboxSettingsViews.swift` (on `pulse`, its caption and delete-all message on Pulse's deadlines), linked from `Conduit/Views/AuxiliaryViews.swift` (SettingsDestination.shortcutInbox)
- Notifier: `notifier/inbox_store.py` (store, list_sealed, delete_events; received and present, for Pulse's deadlines), `notifier/inbox_tool.py` (tool), `notifier/dashboard/plugin_api.py` (/inbox, _inbox_tell_pulse, ROUTE_CAPABILITIES; /inbox/delete and /inbox/wipe delete Pulse's deadlines from those events), `notifier/tests/test_inbox.py` and `notifier/tests/inbox_vector.json` (both sides seal against it)
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

**Checked:** 2026-10-27, at #1379 on the `pulse` branch, carrying main's #1375: the privacy policy sibling (notifier #410 added what Pulse keeps from these events to its Optional events from Shortcuts automations); at #1341 on the `pulse` branch, with notifier #410 (Pulse memory keeps deadlines from the inbox: the ruling on what memory keeps, deleting events deleting them, the inbox page's caption and Delete Everything's message; the Log to Hermes action, the conduit_inbox tool, watches, the report and the brief needed no change); before that 2026-10-25, #1214 (fork CI #87), at main 6e0f32d and notifier main with notifier #350; the privacy policy sibling and sign-out added in #1232 (privacy in notifier #356), which carries #1214; the morning brief added as a reader in notifier #357 (its README line in notifier #360), carried in #1237.

## Steps in a turn

How a turn's thinking and tool calls read in the chat while it runs and
once it is done.

**Siblings:** the step rows (chats, project chats, Bot Chats, the saved
offline copy) · the collapsed run of steps ("7 steps · 12s") · the working
line ("Home · Searching the web") · the Live Activity's tool line · the
notifier's twin category list · Settings > Display's step switches (they show, hide and open rows; their words follow the row) ·
the run's summary, its Explain these steps menu (and a lone step's Explain this step), and its switch, step limit and captions in Settings > Chat · /btw

**Code**
- Rows and words: `Conduit/Views/ChatActivityRows.swift` (ChatStepStyle, ChatStepLabel, ChatStepSubject, ChatStepGroupHeader, ChatWorkingLine), `Conduit/Views/ChatView.swift` (ToolCard, SettledToolCardContent)
- Hermes' tools catalog: `Conduit/Models/ToolCatalog.swift`, toolset names shared with Settings > Capabilities in `Conduit/Models/CapabilityCatalogModels.swift` (CapabilityToolsetOrdering.label), `Conduit/Services/AppState.swift` (loadToolCatalogIfNeeded), `Conduit/Views/ChatRowState.swift` (toolCatalog)
- Tool Search wrapper: `Conduit/Models/ToolSearchBridge.swift`
- Run summaries: `Conduit/Services/ChatStepSummaries.swift`, `Conduit/Services/AppState+StepSummaries.swift`, `Conduit/Views/AuxiliaryViews.swift` (StepSummarySettings), `Conduit/Views/ChatRowState.swift` (stepSummariesAsked, canExplainStepRuns), sent with `Conduit/Services/HermesClient.swift` (startSideAgent)
- Tool categories: `Shared/Widgets/HermesTurnActivity.swift`, and its twin, `notifier/live_activity.py` (`tool_category`)
- Tests: `ConduitTests/ChatTypographyTests+StepRows.swift`, `ConduitTests/ChatTypographyTests+StepSummaries.swift`

**Rulings**
- A step Conduit has words for keeps them, translated ("Searched the web"). Any other step is named: an MCP or connector tool by its app with the action as its subject line (a Tool Search batch: its apps' names with the connector icon, then every action it ran), else by the toolset Hermes' catalog (`/api/tools/toolsets`) puts it in, else by its own name made readable. "Used a tool" is only for a call with no name. Names are shown as Hermes writes them (2026-10-24, #1201).
- The catalog is read once per profile per run and saved on the device, so a chat opened offline or before the dashboard answers still names its steps. An empty answer keeps the saved catalog and is asked again (2026-10-24, #1201).
- The Live Activity stays on categories: its state goes through the push relay, which never sees tool names, so neither it nor the notifier's `tool_category` names tools (2026-10-24, #1201).
- A run's summary is opt-in and device-only, off by default. Once a turn has settled (its reply in place, nothing running) and its last run folds on screen (two steps or more of those Settings > Display shows) with a tool call in it, Conduit asks a hidden `/btw` (Hermes' cache-sharing fork, no tools, the chat untouched) for a short train of thought in the app's language: one natural first-person paragraph, looking back, on what Hermes set out to do and why each step came next, a coherent story of intentions from the calls' real arguments that names a result only where it changed course (the reply already has the results) and never a tool's name, and that keeps to the calls since the user's last message. Its budget is about half a phone line per tool call (9 words a line, 2 lines at least and 4 at most, so a long run doesn't make a page of it). A run of more steps than Settings > Chat's limit (20 by default, 5 to 100, counted like the folded line's "N steps", the steps Settings > Display shows) isn't summarized on its own (Michel, 2026-10-25, #1233).
- The folded run shows every step's icon and the count on its first line (an ellipsis when they don't fit) and the summary under them, uncut; opened, the summary stays at the top of the card, under the count (2026-10-25, #1233).
- Touching and holding a finished run whose first tool call has an id of its own, switch on or off, offers Explain these steps (Explain again over a summary), and a lone tool step offers Explain this step once its turn is done, its answer under the step's card (under a lone thought instead when Settings > Display hides the tools, which then carries the menu). An answer to a question that was forgotten or asked again since is only taken from the stream. Its question lists the run's calls with their arguments and the start of their results (the first 30, then how many more followed), since /btw only sees up to the last reply and, once the chat's agent is gone, only a digest of tool names, and asks for a somewhat longer paragraph about that run alone. Its answer is kept like the others, so the switch only turns automatic summaries on and off and kept summaries always show (2026-10-25, #1233).
- Summaries are kept per dashboard and profile, by the run's first tool call, so only a run whose call ids are its own is described (not ids numbered per turn, like `functions.web_search:0`). Questions unanswered after two minutes are forgotten (the run's menu can ask again), and so is an answer that comes later; that run keeps the count. The kept summaries describe chats, so they go with a dashboard's saved chats (sign-out, removal, a new interactive sign-in) and with Delete Saved Chats. In Conduit an answer never shows as a /btw note, late, replayed or asked by another device, and the user's own /btw is never taken for one (only the exact questions are, today's or 2.2.1's) (2026-10-24, #1202; #1233).
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

**Checked:** 2026-10-25, at #1233, carried in #1236 (an old question's answer never lands on a newer one; a run summarized on its own must fold on screen, Explain needs no fold; nothing offers Explain over a step still marked running; a lone step's Explain waits for the turn to end; a kept summary shows under a lone thought when the tools are hidden).

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
- Tests: `ConduitTests/VoiceBackgroundJobTests.swift`, `ConduitTests/VoiceHistoryTests.swift`, `ConduitTests/GroupChatModelsTests.swift`

**Rulings**
- A fence is three or more backticks or tildes; only a line of the same mark, at least as long and with nothing after it, closes it, so a ```` block can show ``` lines (#893). The cuts and group room mention links read fences with `MarkdownFence`; the spoken-text readers follow the same rule in their own line-by-line code (2026-10-24, #1220, from #1002).
- Bot Chat mention routing strips code with Hermes' own pattern (the first ``` closes a block), not this rule, so Conduit picks the same bot Hermes would.
- A cut that leaves a block open closes it with a fence as long as the opener, and the closer's room comes off the cut, so the result stays within its limit however long the fence (2026-10-24, #1220).

**Open gaps**
- Previews and quotes only drop fence lines and track no block, so they need no closing rule (not a gap, noted so nobody adds one).
- A ```` block holding a ``` line in a Bot Chat can route a mention after that line, as Hermes does; changing it starts in Hermes.

**Checked:** 2026-10-24, at #1220.

## Files prepared for preview and Save to Files

Gateway files Conduit downloads to show or hand to the share sheet: where the
copy goes and when it is removed.

**Siblings:** a chat's media and file previews · the Artifacts page's opener ·
the gateway media resolver · the workspace browser's Save to Files

**Code**
- Media previews: `Conduit/Views/Components/MediaPreviewPresenter.swift` (stage, stagingRoot, removeDirectory), `Conduit/Views/Components/MarkdownText.swift`, `Conduit/Views/Components/GatewayMediaDataURLResolver.swift`, `Conduit/Views/V2/V2ArtifactsViews.swift`
- Workspace: `Conduit/Services/WorkspaceDownloads.swift`, `Conduit/Services/AppState.swift` (workspaceDownload), `Conduit/Views/ChatSupportSheets.swift` (WorkspaceFilePreviewSheet), swept at launch from `Conduit/ConduitApp.swift`
- Tests: `ConduitTests/MarkdownLargeDocumentTests+MediaPreview.swift`

**Rulings**
- Each download goes in a folder of its own, removed when the preview or share sheet that asked for it closes, or when it is dismissed or switched to another file while still downloading; a previous run's leftovers are swept at launch (2026-10-24, #1220, from #1002).

**Open gaps**
- None known.

**Checked:** 2026-10-24, at #1220.

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
result sheets · group rooms · text that describes it (none today: no
Settings caption, briefing or doc says how pictures load)

**Code**
- Attachments: `Conduit/Views/ChatView.swift` (UserImageAttachmentPreview)
- Reply pictures (`MEDIA:` and web): `Conduit/Views/Components/MarkdownText.swift` (RemoteMarkdownImage), `Conduit/Views/Components/BoundedRemoteImage.swift`, `Conduit/Views/Components/GatewayMediaDataURLResolver.swift` (imageCacheKey, imageCacheKey(forMediaPath:)), set for job sheets in `Conduit/Views/LiveVoiceCallJobs.swift`
- Kept and remembered: `Conduit/Services/TranscriptImageCache.swift` (files on the phone), `Conduit/Services/TranscriptPictureMemory.swift` (decoded reply pictures, attachment previews, every picture's size, loaded from ChatView), both forgotten in `Conduit/Services/AppState.swift` (wipeOfflineChatCache, deleteSavedChats)
- Tests: `ConduitTests/TranscriptInlineImageTests.swift`

**Rulings**
- A row never changes height when its picture arrives, if the picture has loaded on this phone before: its size is remembered (kept next to the pictures, read once off the main thread) and its placeholder takes it (2026-10-25, #1239, #1238).
- Reading, decoding and keeping a picture, and its size, stay off the main thread: a body looks pictures and sizes up in memory only (a local photo's existence is still checked there: a stat, never a picture read). A picture kept on the phone is never fetched again (2026-10-25, #1239).

**Open gaps**
- A picture never loaded on this phone, or kept by a build before #1239 and not shown since, still mounts as a loading line and grows once.
- Group rooms show no `MEDIA:` pictures: their Markdown has no gateway resolver.
- Past 4,000 remembered sizes the memo starts again (no LRU), so pictures grow once more until each loads again.

**Checked:** 2026-10-25, at #1239.

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
- Map check: `scripts/check-feature-map.py` (paths, entry shape, and on a PR the Checked line of each entry it edits; on a PR into `pulse` that merges main, main's maps where the PR and its base meet main tell which entries came from main), `scripts/tests/test_check_feature_map.py`, run by `.github/workflows/ci.yml` (Feature map paths exist; a PR into `pulse` runs `pulse`'s copy, whose trigger lists `pulse`), its PR number, base map and main's maps pinned by `scripts/tests/test_ci_workflow_contract.py`
- Pointers: `README.md` (Architecture), `docs/CI.md` (the plan job under Jobs)

**Rulings**
- A checked-in map, a Siblings section in every PR, and rulings in each entry; a sibling left out without a reason is a major review finding (2026-10-23, #1167, Eric).
- Nobody tends the map separately: the PR that changes a feature updates its entry, adds one for a connected feature that has none, adds a sibling an earlier change missed, and records the maintainer's rulings with the date and the PR (2026-10-24, #1178, Eric).
- CONTRIBUTING.md holds the full rules. The intro, the PR templates and the reviewer prompts each carry the part their reader needs, so a rule change starts in CONTRIBUTING.md and then reaches each copy (2026-10-24, #1178).
- The notifier's reviewers can't read this map, so a notifier PR names its entry, or the hermes-conduit PR that adds or updates it (2026-10-24, #1178).
- An entry a PR adds or edits names that PR on its Checked line, and CI fails one that doesn't; a commit is only for an entry seeded from main. A carry PR names both, like "#1188, carried in #1200". The PR template asks for a Siblings line for every sibling the entry lists, Settings and model-facing text included (2026-10-24, #1209, Eric).
- On a PR into `pulse` that merges main, an entry main changed between where `pulse` last met main and where the PR meets it, and that matches main's copy there, came in with main and keeps main's Checked line, so bringing main into `pulse` doesn't name the merge on every entry main changed. A `pulse` PR that doesn't merge main gets no such pass, and neither does an entry main didn't change (2026-10-25, #1248; the first such merge after #1209 failed the check on 48 entries).

**Open gaps**
- A connection nobody has noticed yet isn't caught by any check; it goes in the first time a fix turns it up.
- A notifier PR that moves a file listed here fails the next hermes-conduit PR's map check, not its own.
- A PR that changes a mapped feature's code without touching its entry isn't caught by CI; a reviewer flags it (minor).
- On a merge of main into `pulse`, an entry both sides changed that the merge settles on main's copy keeps main's Checked line, so CI doesn't flag dropping `pulse`'s edit; a reviewer checks that choice. CI only sees content, and that copy is main's word for word.
- If GitHub can't say whether a PR into `pulse` merges main, or can't give main's maps, the step warns and checks without them, so a merge of main fails on the entries it brings in until a re-run.

**Checked:** 2026-10-25, #1248.
