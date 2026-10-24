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
or edits names that PR on its Checked line. A path that starts with notifier/ is in
[hermes-conduit-notifier](https://github.com/kaishi00/hermes-conduit-notifier),
checked against its main.

**Sibling sets.** Most entries draw on these. A change to one member is
checked against the rest, and where one can't follow, the PR says so and the
maintainer decides (2026-10-20).

- Voice modes: Classic (hands-free on a speech server too), Gemini Live, Grok
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
Gemini Live · Grok Live · GPT-Live · Local Live · Watch calls · a call from
Hermes about it · a confirmation Hermes shows on the call screen · group
rooms · the resume jump · what models and Settings say about it

| Where | Says it | Answer by voice | Card on screen |
|---|---|---|---|
| Classic | approvals, and questions with their numbered choices | approvals and phone changes, yes or no; a question's answer, by number, label or own words | over the voice sheet (approval or question card); not on CarPlay |
| Gemini, Grok, GPT-Live | a job's approval or question, with its choices | job approvals, once or deny; job questions by number or own words | above the job strip: the call's chat card, else the job's Run and Reject or choices |
| Local Live | approvals and questions, with choices | yes or no; a question's answer | as Gemini (one call screen) |
| Watch | job approvals; a call from Hermes' question or approval | Gemini, Grok and Local Live answer the call's question, and its approval when "Approve from the Watch" is "Tap or voice"; GPT-Live answers questions only | Approve once and Deny |
| Group rooms | no voice | no voice | Run and Reject above the composer |

A call Hermes made about an approval or question is briefed from the
chat's card: every question with its numbered choices (marked
"(Recommended)" as Hermes wrote them), the command and why, and what Hermes
wrote before asking. The user answers by voice: `answer_approval` and
`answer_question` on Gemini, Grok and Local Live agent mode, "Approve:",
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
- Watch: `ConduitWatch/WatchCallView.swift` (WatchApprovalCard), `ConduitWatch/WatchDirectCallModel.swift` (answerCallThroughRelay), `ConduitWatch/WatchBridgeCallModel.swift` (answerCall), `Shared/WatchVoice/WatchCallAnswer.swift`, `Shared/WatchVoice/WatchJobRelay.swift`, `Conduit/Watch/WatchDirectBroker.swift` (grants), `Conduit/Watch/WatchToolGrantClient.swift` (answer_sessions, answer_approvals), `Conduit/Watch/WatchSettingsSection.swift`
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

**Checked:** 2026-10-24, at #1207 (notifier 0.70.1), for the Watch's "approved" when nothing ran; at #1194 (after #1188, the approval card's shield); at #1191: message.interim ends a Local Live reply's approval wait and a voice job's needs-input state, as other output does (#912 review); the chat card's #951/#952 follow-ups; the call-screen confirmation's refusal veto (#1042).

## Voice follow-ups

What the user adds or changes by voice while Hermes is already working on
their request.

**Siblings:** Gemini Live · Grok Live · GPT-Live · Local Live · Classic
(phone, CarPlay) · Watch calls · the composer's Steer, Interrupt and Queue ·
the outcome text each model is told

| Where | Add to the work | Change or stop it |
|---|---|---|
| Gemini, Grok, Local Live agent | `interrupt_job` with kind add: `session.steer` | kind change, or none: `session.redirect` |
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

**Checked:** 2026-10-23, seeded from main at 64d53c3.

## Job results during calls

How a background job's result, failure or question reaches the user while a
call is still going, and what of it stays after.

**Siblings:** Classic · Gemini Live · Grok Live · GPT-Live · Local Live (agent
mode, Hermes turns) · Watch calls · CarPlay · the call screen's job cards ·
the saved transcript's job cards · `docs/VOICE_BACKGROUND_JOBS.md`

| Where | How a result arrives |
|---|---|
| Classic | Hermes summarizes it in the call's own session; failures and questions are short spoken notices |
| Gemini | on the job's own tool call once the model is quiet; sent again as text after 6 s of silence |
| Grok | a text turn, sent only while quiet |
| GPT-Live | on the delegation, after the user has finished talking |
| Local Live agent | an update, as in the live modes |
| Local Live, Hermes turns | dropped: Hermes' reply is already the call's turn |
| Watch | the relay's job news, at the next quiet moment |

**Code**
- All modes: `Conduit/Voice/VoiceBackgroundJobs.swift` (takeNotice, outcomePrompt, showOnScreen, VoiceJobCallAnchor)
- Gemini and Grok: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift`, `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift`
- GPT-Live: `Conduit/Voice/GPTLive/GPTLiveConversationController.swift` (userQuietInterval), `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift`
- Local Live: `Conduit/Voice/LocalLive/LocalLiveNoticeRoute.swift`
- Classic: `Conduit/Voice/VoiceConversationController.swift`
- Call screen: `Conduit/Views/LiveVoiceCallJobs.swift` (LiveVoiceJobCard, LiveVoiceCallTimeline), `Conduit/Services/AppState+PresentedScreens.swift` (cards Hermes shows)
- Saved transcript: `Conduit/Services/AppState.swift` (voiceJobStartedNote), `Conduit/Voice/VoiceJobLinkNote.swift`, `Conduit/Views/VoiceJobLinkCard.swift`
- Watch: `Shared/WatchVoice/WatchJobRelay.swift` (notice), `ConduitWatch/WatchDirectCallModel.swift`, `ConduitWatch/WatchBridgeCallModel.swift`
- Notifier (Watch relay jobs): `notifier/dashboard/plugin_api.py`

**Rulings**
- A result never talks over the user: it waits for a quiet moment, and the model answers what the user just said first (2026-10-04, #381).
- Results show during the call as job cards on the call screen, on the phone only, with no writes to the host mid-call (2026-10-03, #364).
- The saved transcript links each job the call started, drawn as a card (2026-10-03, #358; 2026-10-18, #758).
- Local Live agent calls announce results; calls that hand each turn to Hermes drop them (2026-10-23, #1160).

**Open gaps**
- GPT-Live's model can't put a card on the call screen: Gemini, Grok and Local Live agent have `show_on_screen`, GPT-Live has no marker for it. Cards Hermes shows still appear (#366).

**Checked:** 2026-10-24, at 78f21da; at #1191: a cut screen card keeps its last line unless it can be half a fence, so prose that opens with inline code stays (#926 review), and message.interim counts as a job's progress (#912 review).

## Tools and consent in calls

What a call can do for the user (phone features, health and location reads,
finding chats, web lookups) and the consent each needs.

**Siblings:** Gemini Live · Grok Live · GPT-Live · Local Live agent · Classic
(Hermes' own tools) · Watch calls · CarPlay · the phone features set · the
consent screens · the tool text each model reads, in Conduit and the notifier

**Code**
- Phone tools: `Conduit/Phone/PhoneVoiceTools.swift`, `Conduit/Phone/PhoneChangeConfirmation.swift`
- Host reads for live modes: `Conduit/Voice/VoiceHostTools.swift` (VoiceHostTool, gptLiveRules), `Conduit/Services/AppState+VoiceHostTools.swift`
- Declarations: `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift` (declarations, watchDeclarations); GPT-Live markers: `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift`
- Chats by voice: `Conduit/Voice/VoiceChatFinder.swift`, `Shared/WatchVoice/VoiceChatToolText.swift`
- Provider consent: `Conduit/Voice/LiveVoiceProviderConsent.swift`, `Conduit/Services/AppState+LiveVoiceConsent.swift`, `Conduit/Views/LiveVoiceConsentViews.swift`
- Consent for reads, per mode: `Conduit/Views/HealthSettingsViews.swift`, `Conduit/Views/LocationSettingsViews.swift`, `Conduit/Views/PhoneSettingsViews.swift`
- Watch: `Conduit/Watch/WatchDirectBroker.swift`, `Conduit/Watch/WatchToolGrantClient.swift`, `Shared/WatchVoice/WatchToolRelay.swift`
- Notifier: `notifier/phone_tool.py`, `notifier/health_tool.py`, `notifier/location_tool.py`, `notifier/maps_tool.py`, `notifier/conduit_first.py`, `notifier/dashboard/plugin_api.py` (/voice-tools), `notifier/relay/src/watch-tools.mjs`

**Rulings**
- Live calls do phone actions on the device rather than handing them to Hermes (2026-10-20, #991).
- Live modes read health, location and calendar through the host's /voice-tools, with consent for each voice mode that names its provider, off by default (2026-10-14, #585, notifier #104).
- A live provider hears nothing until the user agrees, once per provider on the device; Local Live never asks (2026-10-20, #1052).
- Conduit's tools come first: models use them before handing work to Hermes or older routes such as gog (2026-10-16, #634, notifier #121).

**Open gaps**
- The consent ask doesn't cover Classic with cloud speech through the host, or Local Live (#1052).
- A Watch Gemini call can't be ended from the phone when consent is taken back (#1052).
- Watch GPT-Live and Local Live calls have no phone tools, and the Watch doesn't announce Hermes' phone changes (#994).
- Classic finds and reads old chats through Hermes' session_search but can't open one in Conduit (#535).

**Checked:** 2026-10-23, seeded from main at 64d53c3.

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
- CarPlay: `Conduit/CarPlay/CarPlayVoiceCoordinator.swift`, `Conduit/CarPlay/CarPlayBrowseTemplates.swift`
- Watch: `ConduitWatch/WatchHomeView.swift`, `ConduitWatch/TalkToHermesIntent.swift`
- A chat open elsewhere: `Conduit/Services/ChatTakeover.swift` (ChatTakeoverPreference), `Conduit/Services/AppState.swift` (submitComposerForCall, sendCallPromptTakingOver)
- How an attached call behaves: `docs/VOICE_BACKGROUND_JOBS.md`

**Rulings**
- A live call started from a chat joins that chat for the whole call, and its requests become the chat's turns; started anywhere else, it stands alone (2026-10-02, #312). An empty chat counts as a chat (2026-10-16, #679).
- In a chat with a saved call, the voice button resumes that call (2026-10-16, #679).
- A call always takes over a chat that Desktop holds, whatever the setting, and "Take over automatically" is on by default (2026-10-21, #1066).
- Classic can't start while a reply runs; live calls start beside it (2026-10-18, #767).
- The chat's voice button does what the user picks: Live call, Voice message or Dictation, for all profiles or per profile (2026-10-22, #1134).

**Open gaps**
- Group rooms have no voice button setting, and the Watch and CarPlay don't follow it (#1134).
- When a Classic call can't take over its chat, it shows a generic error (#1066).

**Checked:** 2026-10-23, seeded from main at 64d53c3.

## Ending a call and what gets saved

What happens to a call's words, its jobs and Hermes' memory when it ends.

**Siblings:** a call joined to a chat · a call on its own · a Bot Chat call ·
Classic in a chat it created · Watch calls · CarPlay calls · calls from
Hermes · Resume Call · memory at call end (notifier)

**Code**
- Recording and saving: `Conduit/Voice/VoiceHistory.swift` (VoiceTranscriptRecorder, VoiceTranscriptSaveRequest, VoiceCallChatLink)
- In the app: `Conduit/Services/AppState.swift` (chatCallReconnectWindow, isArchivedVoiceChat, saveWatchVoiceCall)
- The call's card in its chat: `Conduit/Views/VoiceChatCallTranscriptSheet.swift`
- Watch: `Conduit/Watch/WatchDirectBroker.swift`
- Notifier: `notifier/dashboard/plugin_api.py` (/voice/sessions, /voice/chat-calls, /voice/archive), `notifier/voice_archive.py`

**Rulings**
- A call's turns go to the host only when the call ends; saving mid-call stalled Gemini (2026-10-01, #281).
- A saved call keeps the session source "desktop"; its voice tags live in their own meta key, since a session's source picks the agent's toolsets (2026-09-30).
- A call joined to a chat is kept with the chat, not in a second session, and a reconnect within 120 seconds continues the same call (2026-10-13, #574, notifier #98).
- A call that stands alone, and a chat a Classic call created, are archived when the call ends; a typed turn brings them back (2026-10-22, #1127, notifier #295).
- Ending a call runs Hermes' session-end hooks and memory commit; a call kept with its chat writes memory under the chat (2026-10-06, notifier #46; 2026-10-13, notifier #98).

**Open gaps**
- None known.

**Checked:** 2026-10-24, at 78f21da; at #1191: a saved screen turn cut at the plugin's limit keeps its last line unless it can be half a fence (#926 review).

## Calls from Hermes

Hermes rings the user (a job is done, it waits on an answer, a scheduled
check), and the call has to ring, start and talk everywhere it can be
answered.

**Siblings:** CallKit on the phone (unlocked, locked, in another app) ·
CarPlay · the Apple Watch (every voice, Local Live included) · each voice mode that answers (Classic, Gemini,
Grok, GPT-Live, Local Live agent mode; Local Live otherwise opens Classic) · the missed-call notification ·
Bot Chat calls · the call trace · the notifier's call tool and skill ·
Pulse (it may call only once the user opts in)

**Code**
- Ringing and answering: `Conduit/Voice/HermesNativeCalls.swift` (receive, stopsWatchRing, startWatchCall), `Conduit/Voice/HermesCalls.swift`, `Conduit/Services/AppState+HermesCalls.swift` (answerHermesCall, hermesCallAudioActivated)
- Caller name: `Shared/WatchVoice/HermesRing.swift` (HermesCallerName)
- Trace: `Conduit/Voice/HermesCallTrace.swift`
- CarPlay: `Conduit/CarPlay/CarPlayVoiceCoordinator.swift`
- Watch: `ConduitWatch/HermesWatchCalls.swift`, `Conduit/Watch/WatchVoiceLink.swift` (startAnsweredCall), `Shared/WatchVoice/WatchCallVoices.swift` (rings), `Conduit/Watch/WatchDirectBroker.swift` (prepareLocalLive)
- Settings: `Conduit/Views/HermesCallSettingsViews.swift`
- Notifier: `notifier/call_tool.py`, `notifier/calls.py`, `notifier/calls_store.py`, `notifier/call_watches.py`, `notifier/skills/calling-the-user/SKILL.md`, `notifier/relay/src/rings.mjs`

**Rulings**
- Answering is the only tap: the call opens its chat and starts talking by itself (2026-10-10, #508).
- A declined or missed call is told to Hermes in that chat's next turn, with no second ring (2026-10-10, #518, notifier #78).
- Hermes speaks first on a call it made (2026-10-11, #546, notifier #89).
- The call screen names the calling profile; the main profile goes by its Conduit name (2026-10-11, #541).
- A call about an approval or question is briefed from the chat's card, not the push's short reason, and answered by voice everywhere it can be (see "Hermes is waiting on you"; 2026-10-24, #1194, notifier #343).
- A Watch that answers starts the call through the relay, since its link to the iPhone is down under the call screen (2026-10-11, #526, notifier #82).
- In the car, CarPlay rings and the Watch stays quiet (2026-10-14, #602).

**Open gaps**
- A sealed push carries no profile to the Watch, so its call screen says "Hermes" (#541).
- The first push after install, before the first status read, can still switch dashboards, and missed-call outcomes are keyed by the pushed dashboard id (#1096).

**Checked:** 2026-10-24, at #1194.

## Audio route, Speaker and mute

Where the voice comes out, who owns the audio session, and what mutes what.

**Siblings:** Classic · Gemini, Grok and Local Live (default and
echo-cancelling audio) · GPT-Live (WebRTC) · calls from Hermes (CallKit's
Speaker button) · CarPlay · AirPods and Bluetooth · Read Aloud · the call
screen's Mute and Silence · the minimised call bar

**Code**
- Session owner: `Conduit/Voice/VoiceAudioSessionCoordinator.swift` (ensureConversationSpeaker, isNativeCallAudioActive), `Conduit/Voice/VoiceAudioSessionConfiguration.swift`
- Playback: `Conduit/Voice/AVSpeechPlaybackService.swift` (resumeOnFreshEngine), `Conduit/Voice/VoiceAudioEngineRecovery.swift`
- Live audio: `Conduit/Voice/GPTLive/GPTLiveAudioLink.swift`, `Conduit/Voice/GeminiLive/LiveVoiceEchoCancellingAudio.swift`, `Conduit/Voice/EchoCancellingVoiceConversationAudio.swift`
- Mute and Silence: `Conduit/Views/LiveVoiceCallSheet.swift`, `Conduit/Views/MinimisedLiveVoiceBar.swift`, `Conduit/Voice/HeadsetMicrophoneMute.swift`
- Read Aloud: `Conduit/Voice/MessageReadAloudController.swift`, `Conduit/Views/ReadAloudPlayerBar.swift`

**Rulings**
- During a call from Hermes, CallKit owns the audio session: Conduit never deactivates or re-activates it, so the Speaker button stays true (2026-10-21, #1093; 2026-10-23, #1148).
- A conversation's replies move from the earpiece to the speaker, never during a CallKit call (2026-10-19, #943).
- Silence mutes the assistant's voice apart from the microphone; its speech is dropped, not held, and job news waits for unmute (2026-10-09, #488).
- An alarm or phone call pauses a live call, which comes back when the audio does (2026-10-04, #380).

**Open gaps**
- Silence isn't on CarPlay or the minimised bar (#488).
- Classic still ends with "Audio was interrupted." when an alarm or phone call takes the audio, where live calls pause; only CarPlay and calls from Hermes restart it (#380, #1155).

**Checked:** 2026-10-23, seeded from main at 64d53c3.

## Talking over Hermes

Speaking while Hermes talks or thinks: barge-in, talk-over, steering, push to
talk, and how long the microphone waits.

**Siblings:** Classic (phone, CarPlay, locked phone) · Gemini Live · Grok
Live · GPT-Live · Local Live · Watch calls · headset, speaker and car routes ·
push to talk · Continuous Conversation · the Action, headset and CarPlay
buttons

| Mode | On a headset | On the speaker or in the car |
|---|---|---|
| Classic | talk-over starts a new turn; speech while Hermes thinks steers | the same, with "Talk over it on the speaker" on |
| Gemini, Grok, Local Live | barge-in | barge-in with "Talk over it on the speaker" on |
| GPT-Live | barge-in (WebRTC cancels the echo) | barge-in |

**Code**
- Routes: `Conduit/Voice/VoiceBargeInRoutePolicy.swift`
- Classic: `Conduit/Voice/VoiceConversationController.swift` (isTalkOverAvailable, isSteerAvailable, beginPushToTalk), `Conduit/Voice/VoiceSpeechDetector.swift`, `Conduit/Voice/EchoCancellingVoiceConversationAudio.swift`
- Live modes: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift`, `Conduit/Voice/GeminiLive/LiveVoiceEchoCancellingAudio.swift`, `Conduit/Voice/GPTLive/GPTLiveConversationController.swift`
- Push to talk surfaces: `Conduit/Services/AppState.swift` (pushToTalkSurfaceAvailable)
- Settings: `Conduit/Views/VoiceSettingsView.swift`, `Conduit/Views/GeminiLiveViews.swift`, `Conduit/Views/GrokLiveViews.swift`

**Rulings**
- In Classic, talking over a spoken reply stops it and starts a new turn; speech while Hermes thinks steers it (2026-10-04, #391).
- Talking over on the speaker is opt-in, "Talk over it on the speaker", off by default (2026-10-03, #351; Classic 2026-10-04, #393).
- Push to talk is per profile and off by default. While held no silence timer runs; a press while Hermes speaks interrupts, while it thinks steers. CarPlay and calls from Hermes stay hands-free (2026-10-22, #1106).
- With Continuous Conversation on, the default, Classic keeps listening through silence instead of pausing the microphone (2026-10-10, #520).

**Open gaps**
- Push to talk is Classic only: not the live modes, the Watch, or the Action, headset and CarPlay buttons (#1106).

**Checked:** 2026-10-23, seeded from main at 64d53c3.

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

**Open gaps**
- Hermes Desktop's own serve process on the host keeps the old plugin until Desktop restarts; nothing tells the user.
- A dashboard without a fixed basic-auth secret signs Conduit out at every restart; the updater signs in again, but the chat may land on the sign-in screen.

**Checked:** 2026-10-24, at main 79a5319.

## Notifications

What a push says, in which language, where tapping it goes, and when it
stays quiet.

**Siblings:** reply · approval · question · failed turn · tasks and cron ·
phone changes · missed call · Pulse (pulse.noticed, pulse.brief, pulse.followup; app
side on the `pulse` branch only, see Pulse) · the Watch (mirrors the iPhone) · Bot Chat ·
the notification service extension · the relay's plain copy ·
Settings > Notifications

**Code**
- Extension: `ConduitNotificationService/NotificationService.swift`, `ConduitNotificationService/NotificationLocalization.swift`
- Shared copy: `Shared/Notifications/NotificationCopy.swift`, `Shared/NotificationE2E.swift`
- App: `Conduit/Services/PushNotificationService.swift` (showPreviews; the relay registration and its updates), `Conduit/Services/AppState.swift` (openNotificationTarget, routeBotOwnedNotification), `Conduit/Services/ChatOnScreen.swift`, `Conduit/Services/AppState+ChatOnScreen.swift`, `Conduit/Services/CronNotifications.swift`, `Conduit/Services/ReplySourceNotifications.swift`
- Missed calls: `Conduit/Voice/HermesCalls.swift`
- Settings: `Conduit/Views/AuxiliaryViews.swift`
- Notifier: `notifier/events.py` (push_event), `notifier/session_titles.py`, `notifier/chat_on_screen.py`, `notifier/e2e.py`, `notifier/relay/src/apns.mjs`

**Rulings**
- Notifications follow the App Language: the extension builds the words from the event's title_label and session_title (2026-10-23, #1158, notifier #326).
- Pushes are titled with the Hermes session title (2026-10-12, notifier #93 and #94).
- A reply's push stays quiet while its chat is on screen and in use (2026-10-22, #1132, notifier #301).
- A push from a Bot Chat opens the Bot Chat (2026-10-16, #654), and a call from one opens the bot (2026-10-16, #630).
- Notification status in Settings is for the active dashboard only (2026-10-05, #395).

**Open gaps**
- Still English: the relay's plain copy (pairings with no key), the redacted decision text, and a clarify body with no arguments (#1158).
- "Notify me when" choices are one set per iPhone, not per dashboard: the relay keeps one set per installation (#395).
- A registration update landing after a relay move is dropped rather than written onto the new registration (#865 follow-up, #1191); the move itself has no test seam (it registers through URLSession.shared).

**Checked:** 2026-10-24, at #1180 (Siblings only); the registration update race at #1191.

## Pulse

Hermes speaking up on its own: the report a few times a day, the morning
brief and follow-ups, each landing as cards on the Pulse screen, with what
Pulse remembers from the chats and how ratings change what it sends. It's a
beta, so its app side is only on the `pulse` branch.

**Siblings:** the Pulse screen (cards, New and Earlier, thumbs and the
one-tap reason, Not now, Done and Undo, Do it) · Settings > Pulse (on and
off, model, nudge, budgets, home chat) · Pulse pushes (kinds
pulse.noticed, pulse.brief and pulse.followup, titled per the Notifications
rulings, opening the Pulse screen) · a call from Hermes (Pulse may call only
once the user opts in) · the hidden Pulse chat · the notifier's loop (report, brief, follow-ups,
memory), its routes under /pulse and its capabilities · the
`hermes conduit-push pulse` commands

**Code**
- App, on the `pulse` branch only, so not in backticks (the map check reads main): Conduit/Views/V2/V2PulsePage.swift (the screen), Conduit/Services/PulseFeed.swift (cards, marks, ratings), Conduit/Services/AppState+Pulse.swift and Conduit/Services/AppState.swift (opensPulseScreen, for pushes), Conduit/Services/PulseSettings.swift and Conduit/Views/PulseSettingsViews.swift (Settings > Pulse)
- Loop: `notifier/pulse.py` (the tick, the report's candidate run, cards from turns, push copy), `notifier/pulse_delivery.py`, `notifier/pulse_host.py`, `notifier/pulse_hermes.py`, `notifier/chat_takeover.py`
- Report: `notifier/pulse_report.py` (what it reads), `notifier/pulse_candidates.py` (the candidate list, the router and the 30-day journal)
- Memory, follow-ups and the brief: `notifier/pulse_memory.py`, `notifier/pulse_followup.py`, `notifier/pulse_brief.py`
- Ratings and lessons: `notifier/pulse_learning.py`; outcomes: `notifier/pulse_ledger.py`; store: `notifier/pulse_store.py`
- Control: `notifier/pulse_control.py` (shared by the commands and the routes), `notifier/cli.py`, `notifier/dashboard/plugin_api.py` (/pulse)
- Tests: `notifier/tests/test_pulse.py`, `notifier/tests/test_pulse_candidates.py`, `notifier/tests/test_pulse_personas.py` (personas over two weeks)

**Rulings**
- The app side stays off main: public TestFlight builds main, and internal testers' builds come from `pulse` (2026-10-21, #1092). The notifier side is on its main, off by default (2026-10-21, notifier #275).
- No Pulse chat in sight: reports and the brief land as cards on the Pulse screen, and the home chat is hidden from Chats, search and voice recents (2026-10-22, #1116, notifier #291).
- Ratings act in code, not as a line in a prompt: thumbs move a kind along the loudness ladder (push now, Pulse screen, brief, off), and a thumbs-down asks one tap for why (2026-10-22, notifier #284). Each report item is its own card with its own thumbs (2026-10-23, notifier #330).
- A report that finds nothing leaves no card (2026-10-23, notifier #324).
- Not now hides a card without teaching Pulse anything, and the item rests a week (2026-10-23, #1173, notifier #334); it stays neutral when Pulse learns from ratings (2026-10-24, Eric).
- Pulse gets louder on its own only within the channels and intensity the user allowed. It never turns on a channel they turned off and never grants calling: calls need an opt-in, and adding the kinds that may call asks first (2026-10-24, Eric).
- Tone stays out of what Pulse learns, and a reason given on a thumbs-down applies at once (2026-10-24, Eric).
- Pulse pushes follow the Notifications rulings: App Language from title_label, titled with the session title (2026-10-23, notifier #334).
- Code picks the report's items from a candidate list the model makes, and every candidate is journaled for 30 days (2026-10-24, notifier #337).

**Open gaps**
- Learning from ratings in code is the next slice. Until it lands, the persona criteria (Quiet and Samantha diverge, a changed interest is heard, due items always surface) are strict xfail in `notifier/tests/test_pulse_personas.py`.
- Create Pulse chat in Settings > Pulse hasn't been tried on a real host: it must make a chat Pulse finds before anything is sent in it.
- The app paths above aren't checked by the map check while they live only on `pulse`; they go in backticks if the app side ever reaches main.
- What a Pulse push does on the Watch, which has no Pulse screen, hasn't been checked.

**Checked:** 2026-10-24, at #1180, with notifier #337 and the `pulse` branch at fae4ec6.

## Artifacts

The files, pages and links Hermes made, listed for every chat (the Chats
bar's Artifacts page) or for one chat (its … menu), opened in the chat's own
viewers, with Show in Chat.

**Siblings:** the Artifacts page · a chat's own Artifacts sheet · Bot Chats
(kept in the bot's own profile) · All (every included profile's chats) ·
group rooms (no Artifacts list) · the notifier's artifacts route · README.md

**Code**
- List model and merge: `Conduit/Services/Artifacts.swift` (ArtifactItem, ArtifactSource, ArtifactFeed, ArtifactsClient)
- Which stores a list reads, Show in Chat: `Conduit/Services/AppState+Artifacts.swift` (artifactSources, showArtifactInChat)
- Screens: `Conduit/Views/V2/V2ArtifactsViews.swift`
- A chat's store: `Conduit/Services/AppState.swift` (botStoreProfile, openLinkedBotChat, openOtherProfileChat)
- Host: `notifier/artifacts_index.py`, `notifier/dashboard/plugin_api.py` (GET /artifacts, one profile per request)

**Rulings**
- A list reads each store the chats it covers are kept in: a Bot Chat's sheet reads the bot's profile, and the Artifacts page reads the profile in use, each other profile All shows while it's on, and every other bot's Bot Chat, merged newest first (2026-10-24, #1203, Eric's report).
- Stores are read one at a time (the host reads two lists at once at most) and each shows as it arrives; a refresh keeps the list it is refreshing until every store answers. A bot's chat or other profile that can't be read leaves the rest listed.
- A bot whose profile is read whole (the profile in use, or one All shows) isn't read again for its Bot Chat; that chat's rows still go by the bot's name and open the way Bots opens them.
- The profile in use is always read, even when All leaves it out.
- One host path is one artifact across stores: profiles share the host's files, so a file two stores list shows once, at its newest mention.
- A file still opening is dropped when the list moves to another server or profile, and only the latest open clears the spinner. Every reload, including one on a dashboard without artifacts, outdates the request before it (2026-10-24, from #895's review, #1191).

**Open gaps**
- Group rooms' messages aren't listed: a room has no Artifacts list, and its members' replies stay out of the Artifacts page.

**Checked:** 2026-10-24, at #1203; opens and reloads at #1191.

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

**Checked:** 2026-10-24, at #1192; group pictures at #1191.

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

**Code**
- Creating the chat: `Conduit/Services/AppState.swift` (createNewSession and createAndReconcileSession return the chat they opened; startChatForComposerSubmission; startNewChat and focusNewChatComposer; prepareVoiceConversation)
- Screenshots: `Conduit/Services/AppState+ScreenQuestion.swift` (startChatForScreenshot, openScreenQuestion)
- Hermes calls: `Conduit/Services/AppState+HermesCalls.swift` (startHermesCallsChat)
- Widget and Shortcut launches: `Conduit/Services/AppState+WidgetLaunch.swift`
- Tests: `ConduitTests/SessionRenameTests.swift`

**Rulings**
- What waits on a new chat goes in only when the chat createNewSession returned is still the one open. Another chat opened or created meanwhile (a voice action, a screen question, a notification) gets nothing. The message stays in the composer, the screenshot goes back or waits, and the user is told (2026-10-24, #941's review, #1191).
- New Chat focuses the composer only on the chat it made. A Classic voice conversation files and archives only its own new chat under Voice; a fresh one asked for fails when another chat took the screen.

**Open gaps**
- A widget's or Shortcut's New Chat and /new put nothing in the chat, so they only report whether the open chat changed.

**Checked:** 2026-10-24, at #1191.

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

**Checked:** 2026-10-24, at #1185.

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
create and edit)

**Code**
- Installed lists and switches: `Conduit/Services/AppState.swift` (loadCapabilities, toggleSkill, toggleToolset, capabilityLoadGeneration), `Conduit/Services/CapabilityToggleWrites.swift`
- The rest of the page: `Conduit/Services/CapabilitiesStore.swift`
- Views: `Conduit/Views/CapabilitiesView.swift`, `Conduit/Views/Capabilities/CapabilitySkillsTab.swift`, `Conduit/Views/Capabilities/CapabilityToolsTab.swift`
- Tests: `ConduitTests/KanbanTests+Capabilities.swift`

**Rulings**
- A list read that started before a switch was flipped commits nothing, in AppState and in CapabilitiesStore alike (#867; AppState's lists at #1191).
- Switches reach Hermes one after another in the order flipped, since each rewrites one config.yaml. A failed write puts back what Hermes last confirmed only when no newer flip of that switch is on its way, and a flip a newer one replaced reports no failure (#868 follow-up, #1191).

**Open gaps**
- AppState's list reads go through a live DashboardTicketBridge with no test seam, so its generation guard has no test.
- Whether a list read can overwrite a flip in the bot editor's lists hasn't been checked.

**Checked:** 2026-10-24, at #1191.

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
· alarms and timers · the wording the notifier's tools give models

**Code**
- Calendar and reminder errors: `Conduit/Phone/EventKitPhoneSource.swift` (PhoneCalendarSourceError, apply, moveDestination)
- Alarm errors: `Conduit/Phone/PhoneAlarmSource.swift` (PhoneAlarmError)
- Voice tools: `Conduit/Phone/PhoneVoiceTools.swift` (the add, change, delete and alarm tools' catches)
- Queued changes and status: `Conduit/Phone/PhoneSyncEngine.swift` (record, lastError, describe)
- Notifier: `notifier/phone_tool.py` (the wording models read)

**Rulings**
- An error names what is missing: the item ("That item isn't on this iPhone any more."), or the calendar or list it was to move to, which leaves the item in place (2026-10-24, from #876's review, #1190).
- Voice tools turn only a missing item on a change or delete into "read the calendar again for its id"; every other error reaches the model as "It couldn't be changed: <reason>" (or added, deleted, set, cancelled) with the error's own text (2026-10-24, #1190).

**Open gaps**
- Adding an event or reminder when the phone has no default calendar or list (and the one named is gone) says "That item isn't on this iPhone any more."

**Checked:** 2026-10-24, at #1190.

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
- A dead connection is reported as a lost connection, not a timeout: "Lost the connection to Hermes speech." and "Lost the connection to your speech server." "Timed out" is only for a live stream that went quiet after some audio (2026-10-24, from #980's review, #1190).
- Before any audio, a Hermes stream that drops or goes quiet tries the one-shot fallback instead of failing.

**Open gaps**
- The speech-server speech stream has no keepalive, so a dead path there shows as "Your speech server stopped speaking." after its idle timeout.

**Checked:** 2026-10-24, at #1190.

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

**Rulings**
- The profiles get their own row when they don't fit beside the controls, and the filter becomes a labeled pill under them (2026-10-22, #1117, Eric).
- In the stacked bar, search is a magnifier leading the controls. Tapping it turns the whole second row (filter and controls) into the field with Cancel until the search is cancelled, the list has no search row, and the filter pill fills the row up to the controls. The one-row bar keeps the field as the list's first row (2026-10-24, #1199, Eric).
- Going from the stacked bar to the one-row bar carries a query over to the list's field and closes an empty open field (2026-10-24, #1199).
- The list's search row follows the bar's layout, starting from the last layout seen (`barStackedKey`). Before any layout is known (first launch) the row stays out until the one-row bar appears; a change of layout (rotation, a profile added) animates it in or out (2026-10-24, #1206: implementation of #1199's open gap).

**Open gaps**
- A launch whose layout differs from the last one seen still starts from the old layout, so the row can show for a frame or arrive a frame late: the iPad was rotated or profiles were added while Conduit was closed, or another iPad window in the other layout wrote the shared key last. Closing it needs the bar's choice before the first frame, which `ViewThatFits` doesn't expose.

**Checked:** 2026-10-24, at #1206.

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
- An announced plan is on screen: a new plan, even one that arrives finished after the last one went, clears the hidden state and gets its own 60 s (2026-10-24, salvage of the #1135 review).
- The line and the card cap Dynamic Type at accessibility1; the sheet, a scrolling list, takes every size (2026-10-24, salvage of the #1135 review).

**Open gaps**
- The new-plan announcement reads the line's label ("Tasks, 0 of 4 done, now: ..."), with no word saying the plan is new or reopened.
- Two announcements within 450 ms race on the pulse (#1135 review).

**Checked:** 2026-10-24, at #1188.

## White text on the accent

A chip, badge or step number that puts white text or a white glyph on a
solid accent fill. The accent the user picks is light in dark mode, so
white on it can fall to about 2:1; the sent-bubble colour is the shade held
to 4.5:1 under white in both modes.

**Siblings:** the running timer chip and the "Recommended" badge on rich
cards · the numbered or symbol marker on a rich card's place rows · the
step numbers of the notification setup commands · the Gemini Live setup
step number · marks picked by `markColor(on:)` (text selection on a sent
bubble, the accent swatch check)

**Code**
- Fill: `Conduit/Theme.swift` (conduitUserBubble, ConduitAccentChoice.markColor)
- Surfaces: `Conduit/Cards/RichInfoCardViews.swift` (RichOptionColumn, RichStepTimer), `Conduit/Cards/RichCardViews.swift` (the place row marker), `Conduit/Views/AuxiliaryViews.swift` (NotificationSetupCommand), `Conduit/Views/LiveVoiceSetupSheet.swift` (the Gemini step)
- Tests: `ConduitTests/AccentContrastTests.swift`

**Rulings**
- White text on a solid fill uses the sent-bubble colour, not the accent; a mark whose colour is computed takes whichever of black and white contrasts more with its fill (2026-10-24, #1188, salvage of the #955 review).

**Open gaps**
- Dark glyphs on the accent (the voice and new-chat buttons, the voice message send button, the chats list capsule) and background-coloured text on it (the confirm panel, the sidebar button, the profile camera badge) aren't checked against a custom accent.

**Checked:** 2026-10-24, at #1188.

## Phone data sync with the host

The phone sending calendar, reminders, alarms, contacts and phone status,
health data and location to the notifier, each under its own agreed key, and
what it does when the host refuses.

**Siblings:** phone sync (calendar, reminders, alarms, contacts, Focus and
status) · health sync · location sharing · the voice reads that use the same
keys · each one's pause message in Settings · a locate answered from the push
extension · the notifier's three stores and their refusals

**Code**
- Phone: `Conduit/Phone/PhoneSyncEngine.swift` (pass), `Conduit/Phone/PhoneSyncModels.swift` (PhoneSyncPause)
- Health: `Conduit/Health/HealthSyncEngine.swift`, `Conduit/Health/HealthSyncModels.swift` (HealthSyncPause)
- Location: `Conduit/Location/LocationSyncEngine.swift` (send, LocationSyncPause), `Conduit/Location/LocationSharingController.swift` (sendNow: keeps the batch on `.failed`), `ConduitLocationPush/LocationPushService.swift` (a locate answered from the push extension)
- Which 409 means what: `Conduit/Services/HostKeyConflict.swift`
- Voice reads: `Conduit/Services/AppState+VoiceHostTools.swift`, `Conduit/Phone/PhoneVoiceTools.swift`
- Notifier: `notifier/phone_store.py`, `notifier/health_store.py`, `notifier/location_store.py`, `notifier/dashboard/plugin_api.py` (_store_refusal)
- Tests: `ConduitTests/PhoneSyncTests.swift`, `ConduitTests/HealthSyncTests.swift`, `ConduitTests/LocationSharingTests.swift`

**Rulings**
- Only a 409 that says the host lost this phone's key (`unknown_key`, `bad_seal`) clears the key and sets up again; any other 409 keeps it (2026-10-19, #906; 2026-10-20, #1025).
- A store written by a newer plugin (409 `schema`) pauses with the "update the Conduit plugin" message, keeps the key and keeps what waits to be sent (2026-10-24, #1196).
- A later refusal, timeout or 404 replaces that plugin-update pause with its own message, as for any other pause (2026-10-24, #1196).

**Open gaps**
- The dashboard sends the store's code beside its message, but the phone keeps only the message: a reworded notifier message is missed until `Conduit/Services/HostKeyConflict.swift` learns it. Phone and health then pause with the host's reason; location drops the waiting fix and events as refused.
- A locate answered from the push extension drops its fix on any failed post, a 409 `schema` included, and shows no pause: it is a one-shot answer, and the app shares its own fix next time.
- A voice read that meets a 409 `schema` tells the model only that the read failed, not that the plugin needs an update.

**Checked:** 2026-10-24, at main e9d9592.

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
- Map check: `scripts/check-feature-map.py` (paths, entry shape, and on a PR the Checked line of each entry it edits), `scripts/tests/test_check_feature_map.py`, run by `.github/workflows/ci.yml` (Feature map paths exist), its PR number and base map pinned by `scripts/tests/test_ci_workflow_contract.py`
- Pointers: `README.md` (Architecture), `docs/CI.md` (the plan job under Jobs)

**Rulings**
- A checked-in map, a Siblings section in every PR, and rulings in each entry; a sibling left out without a reason is a major review finding (2026-10-23, #1167, Eric).
- Nobody tends the map separately: the PR that changes a feature updates its entry, adds one for a connected feature that has none, adds a sibling an earlier change missed, and records the maintainer's rulings with the date and the PR (2026-10-24, #1178, Eric).
- CONTRIBUTING.md holds the full rules. The intro, the PR templates and the reviewer prompts each carry the part their reader needs, so a rule change starts in CONTRIBUTING.md and then reaches each copy (2026-10-24, #1178).
- The notifier's reviewers can't read this map, so a notifier PR names its entry, or the hermes-conduit PR that adds or updates it (2026-10-24, #1178).
- An entry a PR adds or edits names that PR on its Checked line, and CI fails one that doesn't; a commit is only for an entry seeded from main. A carry PR names both, like "#1188, carried in #1200". The PR template asks for a Siblings line for every sibling the entry lists, Settings and model-facing text included (2026-10-24, #1209, Eric).

**Open gaps**
- A connection nobody has noticed yet isn't caught by any check; it goes in the first time a fix turns it up.
- A notifier PR that moves a file listed here fails the next hermes-conduit PR's map check, not its own.
- A PR that changes a mapped feature's code without touching its entry isn't caught by CI; a reviewer flags it (minor).

**Checked:** 2026-10-24, at #1209.
