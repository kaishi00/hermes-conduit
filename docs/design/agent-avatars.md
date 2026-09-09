# Conduit character system

Original native SwiftUI artwork inspired by the presence principles in [Grok Bot's design study](https://x.ai/news/designing-grok-bot). No downloaded assets, animation dependencies, or remote image requests.

Each profile has a stable silhouette, accessory, and independent color selection derived from its profile ID. Renaming the bot does not change its character. Existing custom photos are preserved and receive the same activity ring and attention/completion badges.

| State | Expression and motion | Source |
| --- | --- | --- |
| Idle | Breathing, occasional blink, wandering gaze | Ready with no completed reply |
| Thinking | Upward gaze, curious tilt, slow orbit | Running before tool activity or output |
| Working | Focused gaze, rhythmic bounce and squash, faster orbit | Running tool or streaming output |
| Waiting | Attentive tilt, neutral mouth, pause badge | Approval, clarification, profile switch, or reconnect |
| Blocked | Concerned brows and mouth, restrained movement, exclamation badge | Disconnection, unsupported gateway, or failed approval/clarification |
| Done | Smiling eyes, brief celebratory bounce, check badge | Idle after an assistant reply |

The live state belongs to the active profile's current session. Other profiles remain idle because their live runtime state is not known. Messaging threads are a second live-state source: incomplete `MessagingRun` rows drive a pinned avatar presence row above the composer (queued → waiting, running → working), independent of the active Hermes session. The state resolver ignores attention cards from earlier turns. Settled transcript avatars are static.

## Motion and accessibility

Animation is local to each avatar's TimelineView, capped at 15 fps at rest and 30 fps during activity. Profile-derived phase offsets prevent synchronized blinking. Timelines pause when hidden, when the scene is inactive, or when Reduce Motion is enabled. The completion bounce settles after two seconds. Static photos do not animate at rest. Expressions and SF Symbol badges preserve state without relying on color or motion; the avatar exposes its display name and state to VoiceOver.

## Review in Xcode

Open the `Character studio` preview in `Conduit/Views/Components/AgentAvatar.swift`, or run a Debug build with the launch argument `--avatar-gallery`. The gallery renders the actual production component, with six state controls, a size comparison, a character family, and a Reduce Motion toggle. It is excluded from Release builds.

The component accepts `state:` and `animates:` without requiring AppState. Live application surfaces use `appState.avatarState(for:)`; settled chat marks pass `animates: false`.

## Choose a profile avatar

In Profiles, tap the palette badge on a profile avatar to open **Choose avatar**. The production sheet provides a live preview, six character shapes, six colors, four accessories, and the existing photo library/crop picker. Animation previews are optional; runtime activity still controls the avatar outside this sheet.

Save persists the draft for that profile on this device. Cancel or swiping the sheet away discards it. Reset to default restores the generated character when saved. Switching to Character hides a saved photo without deleting it; Photo can reuse it later. A newly selected photo is not written until Save.

Choices live under `conduit.profileAvatarSelections.v1`, observed by each avatar so changes update even settled transcript rows. Profiles without a saved choice retain their generated appearance or existing photo. Unknown entries are ignored individually and retained when another profile is edited. Photo replacement invalidates the decoded image cache and records a revision so views refresh even when the file URL stays the same.
