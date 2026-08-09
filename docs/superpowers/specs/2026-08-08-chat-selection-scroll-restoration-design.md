# Chat Text Selection and Scroll Restoration Design

## Goal

Improve the chat reading experience for the next submission by allowing users
to select and copy portions of any textual chat content, and by preserving the
current conversation position when the app is backgrounded and foregrounded.

## User-facing behavior

- Long-press selection is available for user messages, assistant responses,
  streamed text, reasoning, tool output, review/clarification/approval text,
  system messages, and code.
- The existing whole-response and whole-code copy buttons remain available.
- Buttons, controls, images, diagrams, and other non-text content remain
  interactive rather than becoming part of a selectable surface.
- When the app leaves the foreground, Conduit records the active conversation's
  semantic scroll position.
- If the user was reading above the latest message, returning to Conduit
  restores the top visible message instead of jumping to the newest message,
  even if new messages arrived while the app was away.
- If the user was already following the latest message, returning to Conduit
  continues to show the latest content and new responses.
- If the saved message no longer exists after the gateway refreshes or compacts
  history, Conduit falls back to its existing latest-message behavior rather
  than leaving the transcript at an undefined position.
- Scroll state is retained in memory for the current scene lifetime and is
  scoped by session ID. A process relaunch continues to use the existing
  startup restoration behavior; this feature does not add durable scroll
  preferences.

## Chosen approach

### Native selection at the message boundary

Apply SwiftUI's `.textSelection(.enabled)` to the `MessageBubble` container so
all nested native `Text` views inherit the same selection policy. Remove the
streaming bubble's explicit selection opt-out and enable selection on the
streaming bubble itself. Keep the current block-aware Markdown renderer,
syntax-highlighted code presentation, images, diagrams, and action buttons
unchanged. This provides partial selection without replacing the existing rich
rendering system.

The message boundary is the narrowest shared surface that covers all current
message roles. Selection is a view capability, not a new copy service; the
system text interaction supplies the contextual Copy action for selected text,
while existing explicit copy buttons continue to copy complete responses or
code blocks.

### Semantic scroll anchors

Use the iOS 17 `ScrollPosition` API with the existing stable message IDs and a
scroll target layout. `ScrollPosition` reports the top-most visible target and
can be restored by target ID, which is appropriate for a transcript whose
content may be reconstructed during foreground recovery.

Add a small, pure `ChatScrollStateStore` value type that keeps snapshots keyed
by session ID:

```swift
struct ChatScrollSnapshot: Equatable {
    let anchorMessageID: String?
    let followsLatest: Bool
}
```

The store exposes a restoration lookup that accepts the current set of message
IDs. A saved non-latest snapshot whose anchor is absent returns a latest-follow
snapshot, making the missing-history fallback explicit and testable.

`ChatView` owns the store for the scene lifetime. On `.inactive` or
`.background`, it saves the active session's current top visible message ID
and whether the view was following the bottom. On `.active`, a non-latest
snapshot becomes a pending restoration. Existing geometry callbacks wait until
the refreshed transcript has emitted layout, then restore the saved message
without animation. During that handoff, existing automatic latest-message
scroll triggers are suppressed. A latest-following snapshot uses the current
follow-latest behavior instead.

The implementation will preserve the message-level position. It will not try
to persist a pixel offset inside a long message, because message IDs remain
stable across transcript refreshes while pixel offsets can become invalid when
streaming content, images, or tool cards change height.

## Alternatives considered

1. **Unified attributed text for each response.** Rejected: it would make
   cross-block selection easier but would discard or complicate the current
   Markdown blocks, code formatting, tables, diagrams, media, and controls.
2. **HTML or `UITextView` chat rendering.** Rejected: it would introduce a
   large UIKit/WebKit integration and new layout, accessibility, and streaming
   risks for a problem the native SwiftUI text hierarchy can address.
3. **Persist raw scroll offsets in `UserDefaults`.** Rejected: offsets are
   fragile when transcript content changes; semantic message IDs are stable
   and are sufficient for the requested app-switch behavior.

## Files and boundaries

- `Conduit/Services/ChatTextSelectionPolicy.swift`: define the exhaustive,
  pure message-role selection contract used by the chat views.
- `Conduit/Views/ChatView.swift`: apply the shared text-selection policy to
  message and streaming bubbles, attach semantic scroll targets, save/restore
  scene-scoped scroll snapshots, and coordinate restoration with existing
  layout and follow-latest logic.
- `Conduit/Services/ChatScrollState.swift`: define the testable snapshot and
  per-session store without UIKit or SwiftUI dependencies.
- `ConduitTests/ChatScrollStateTests.swift`: cover session isolation,
  latest-following state, non-latest anchor restoration, and missing-anchor
  fallback behavior.
- `ConduitTests/ChatTextSelectionTests.swift`: cover the explicit selection
  policy for every current `MessageRole`, preventing future message roles from
  silently opting out. The UI behavior itself will also receive simulator
  verification because SwiftUI text-selection gestures are not unit-testable.

## Testing and acceptance criteria

- Add the pure state tests before changing production code and observe them
  fail for the new behavior.
- Run the targeted chat-state tests after implementation, then the complete
  iOS simulator suite.
- Build and launch the simulator app from the follow-up branch.
- Manually verify that partial text can be selected and copied from at least a
  user message, assistant Markdown paragraph, code block, and tool/approval
  text. Verify action buttons still respond and images are not selectable.
- Manually verify the following scroll cases:
  - scroll into earlier history, background, return after the transcript
    refreshes, and confirm the same message remains at the reading position;
  - background while a response is active and confirm the saved anchor is
    restored after the response completes;
  - remain at the bottom, background, and confirm new content still appears at
    the latest edge on return;
  - remove or invalidate the saved message and confirm the latest-message
    fallback is deterministic.
- Keep iPhone portrait-only and iPad orientation behavior unchanged.
