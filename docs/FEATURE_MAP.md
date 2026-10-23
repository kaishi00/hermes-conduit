# Feature map

Features that have siblings: other screens, voice modes or notifier pieces
that must do the same thing. A change that reaches one sibling and not the
others leaves a gap that users find later. Each entry lists the siblings,
where their code lives, the rulings that decide how they behave, and the gaps
already known.

Before changing a feature, read its entry and put every sibling on the plan.
In the PR, say for each sibling whether it's done, not needed (and why), or
left as a gap, and update the entry in the same PR.
[CONTRIBUTING.md](../CONTRIBUTING.md) has the rules.

An entry holds the current state only; history stays in the PRs it cites.
Keep each to about a screen, and split one that grows past that. Every entry
has Siblings, Code, Rulings, Open gaps and a Checked line (the date and PR of
the last check against the code). `scripts/check-feature-map.py` runs in CI:
it checks that shape and that every path in backticks exists. A path that
starts with notifier/ is in
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
Hermes about it · group rooms · the resume jump · what models and Settings
say about it

| Where | Says it | Answer by voice | Card on screen |
|---|---|---|---|
| Classic | approvals, not questions | approvals and phone changes, yes or no | over the voice sheet; not on CarPlay |
| Gemini, Grok, GPT-Live | a job's approval or question | job approvals, once or deny | none; the job row says "Waiting for you" |
| Local Live | approvals | yes or no | none |
| Watch | job approvals | Gemini and Grok, when "Approve from the Watch" is "Tap or voice" | Approve once and Deny |
| Group rooms | no voice | no voice | Run and Reject above the composer |

A call Hermes made about an approval or question takes the answer by voice:
`answer_approval` and `answer_question` on Gemini and Grok, "Approve:",
"Deny:" and "Answer:" on GPT-Live.

**Code**
- Chat card: `Conduit/Views/ChatView.swift` (ApprovalCard), `Conduit/Services/ApprovalDisplayText.swift`
- Classic and Local Live: `Conduit/Services/AppState+SpokenApprovals.swift`, `Conduit/Voice/SpokenApprovals.swift`, `Conduit/Voice/VoiceConversationController.swift` (noteApprovalWaiting), `Conduit/Views/VoiceConversationSheet.swift`, `Conduit/Voice/LocalLive/LocalLiveTurnRunner.swift` (approvalLine)
- Live modes: `Conduit/Voice/VoiceBackgroundJobs.swift` (waitingNotice, answerJobApproval), `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift`, `Conduit/Voice/GPTLive/GPTLiveConversationController.swift` (jobApprovalRule), `Conduit/Views/LiveVoiceCallJobs.swift`
- Call from Hermes: `Conduit/Services/AppState+HermesCalls.swift` (answerHermesCallApproval, answerHermesCallQuestion)
- Phone changes: `Conduit/Phone/PhoneChangeConfirmation.swift`, `Conduit/Phone/PhoneVoiceTools.swift` (confirmsChange)
- Watch: `ConduitWatch/WatchCallView.swift` (WatchApprovalCard), `ConduitWatch/WatchDirectCallModel.swift`, `ConduitWatch/WatchBridgeCallModel.swift`, `Shared/WatchVoice/WatchJobRelay.swift`, `Conduit/Watch/WatchSettingsSection.swift`
- Group rooms: `Conduit/Views/GroupChatView.swift` (GroupApprovalCard)
- Resume jump: `Conduit/Views/ChatView.swift` ("Go to your question")
- Settings text: `Conduit/Views/GeminiLiveViews.swift`
- Notifier: `notifier/events.py` (the push), `notifier/clarify_loop.py`, `notifier/phone_tool.py` (the wording models read)

**Rulings**
- A spoken answer counts only when exactly one item is waiting, and it can only approve once or deny (2026-10-20, #991).
- A phone change needs the user's own yes, as their next words after the reply that asked (2026-10-20, #991, #1051).
- Only the user's own words answer: never the model's judgment, a web page or a job's output (2026-10-20, #991).

**Open gaps**
- Classic: a clarify question sits silently on Thinking (#1161).
- CarPlay shows no card; the user only hears the approval (#1161).
- Classic's notice says "Say yes" under push to talk or a paused microphone (#1161).
- Live call screens show no approval card, only "Waiting for you" on the job row, while Classic and the Watch show one (found seeding this map).
- The resume jump finds clarify cards, not approvals (#486).
- Settings > Gemini Live says "Approvals are never given by voice", and the header comments of `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift` and `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift` say the same; stale since #991.

**Checked:** 2026-10-23, seeded from main at 64d53c3.

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
- All modes: `Conduit/Voice/VoiceBackgroundJobs.swift` (takeNotice, outcomePrompt, showOnScreen)
- Gemini and Grok: `Conduit/Voice/GeminiLive/GeminiLiveConversationController.swift`, `Conduit/Voice/GeminiLive/GeminiLiveToolBridge.swift`
- GPT-Live: `Conduit/Voice/GPTLive/GPTLiveConversationController.swift` (userQuietInterval), `Conduit/Voice/GPTLive/GPTLiveDelegationBridge.swift`
- Local Live: `Conduit/Voice/LocalLive/LocalLiveNoticeRoute.swift`
- Classic: `Conduit/Voice/VoiceConversationController.swift`
- Call screen: `Conduit/Views/LiveVoiceCallJobs.swift` (VoiceJobCallAnchor), `Conduit/Services/AppState+PresentedScreens.swift` (cards Hermes shows)
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

**Checked:** 2026-10-23, seeded from main at 64d53c3.

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

**Checked:** 2026-10-23, seeded from main at 64d53c3.

## Calls from Hermes

Hermes rings the user (a job is done, it waits on an answer, a scheduled
check), and the call has to ring, start and talk everywhere it can be
answered.

**Siblings:** CallKit on the phone (unlocked, locked, in another app) ·
CarPlay · the Apple Watch · each voice mode that answers (Classic, Gemini,
Grok, GPT-Live; Local Live opens Classic) · the missed-call notification ·
Bot Chat calls · the call trace · the notifier's call tool and skill

**Code**
- Ringing and answering: `Conduit/Voice/HermesNativeCalls.swift` (receive, stopsWatchRing, startWatchCall), `Conduit/Voice/HermesCalls.swift`, `Conduit/Services/AppState+HermesCalls.swift` (answerHermesCall, hermesCallAudioActivated)
- Caller name: `Shared/WatchVoice/HermesRing.swift` (HermesCallerName)
- Trace: `Conduit/Voice/HermesCallTrace.swift`
- CarPlay: `Conduit/CarPlay/CarPlayVoiceCoordinator.swift`
- Watch: `ConduitWatch/HermesWatchCalls.swift`, `Conduit/Watch/WatchVoiceLink.swift` (startAnsweredCall)
- Settings: `Conduit/Views/HermesCallSettingsViews.swift`
- Notifier: `notifier/call_tool.py`, `notifier/calls.py`, `notifier/calls_store.py`, `notifier/call_watches.py`, `notifier/skills/calling-the-user/SKILL.md`, `notifier/relay/src/rings.mjs`

**Rulings**
- Answering is the only tap: the call opens its chat and starts talking by itself (2026-10-10, #508).
- A declined or missed call is told to Hermes in that chat's next turn, with no second ring (2026-10-10, #518, notifier #78).
- Hermes speaks first on a call it made (2026-10-11, #546, notifier #89).
- The call screen names the calling profile; the main profile goes by its Conduit name (2026-10-11, #541).
- A Watch that answers starts the call through the relay, since its link to the iPhone is down under the call screen (2026-10-11, #526, notifier #82).
- In the car, CarPlay rings and the Watch stays quiet (2026-10-14, #602).

**Open gaps**
- A sealed push carries no profile to the Watch, so its call screen says "Hermes" (#541).
- The first push after install, before the first status read, can still switch dashboards, and missed-call outcomes are keyed by the pushed dashboard id (#1096).

**Checked:** 2026-10-23, seeded from main at 64d53c3.

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

## Message row actions

The controls on a message: the row under a reply, its long-press and
selection menus, and the same actions in the other chat surfaces.

**Siblings:** chats, project chats and Bot Chat (one row view) · group rooms ·
the selection menu · the long-press menu · VoiceOver labels · pinned replies

**Code**
- Reply row: `Conduit/Views/ChatView.swift` (MessageReactButton, AssistantMessageActions, ReadAloudButton, AssistantMessageMoreMenu)
- Selection and long-press menus: `Conduit/Views/Components/SelectableTextView.swift`
- Group rooms: `Conduit/Views/GroupChatView.swift` (GroupMessageCopyButton, GroupMessageQuoteButton, GroupReadAloudButton)
- Pins: `Conduit/Views/PinnedReplyViews.swift`, `Conduit/Services/AppState+PinnedReplies.swift`
- Read Aloud: `Conduit/Voice/MessageReadAloudController.swift`, `Conduit/Views/ReadAloudPlayerBar.swift`

**Rulings**
- A reply's row is React, Copy, Read aloud and ⋯ (Quote, Branch, Pin reply); no more icons of their own under messages (2026-10-23, #1156).
- Pin lives in the long-press and selection menus, not the row: Pin for a passage, Pin reply for the whole reply (2026-10-20, #982 and #1097; 2026-10-23, #1156).
- Double-tap and long-press on text stay text selection; reactions come from React or a reaction chip (2026-10-07, #437).
- Read Aloud has no estimated follow-along highlight; only exact word timings from Hermes would bring it back (2026-10-19, #923).
- A quoted reply travels in the message text, since Hermes has no field for hidden context (2026-10-04, #387).

**Open gaps**
- Group rooms still show Copy, Quote and Read aloud as three icons, with no React and no ⋯ (#1156).

**Checked:** 2026-10-23, seeded from main at 64d53c3.

## Notifications

What a push says, in which language, where tapping it goes, and when it
stays quiet.

**Siblings:** reply · approval · question · failed turn · tasks and cron ·
phone changes · missed call · the Watch (mirrors the iPhone) · Bot Chat ·
the notification service extension · the relay's plain copy ·
Settings > Notifications

**Code**
- Extension: `ConduitNotificationService/NotificationService.swift`, `ConduitNotificationService/NotificationLocalization.swift`
- Shared copy: `Shared/Notifications/NotificationCopy.swift`, `Shared/NotificationE2E.swift`
- App: `Conduit/Services/PushNotificationService.swift` (showPreviews), `Conduit/Services/AppState.swift` (openNotificationTarget, routeBotOwnedNotification), `Conduit/Services/ChatOnScreen.swift`, `Conduit/Services/AppState+ChatOnScreen.swift`, `Conduit/Services/CronNotifications.swift`, `Conduit/Services/ReplySourceNotifications.swift`
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

**Checked:** 2026-10-23, seeded from main at 64d53c3.
