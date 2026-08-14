# Cross-Block Markdown Selection, Composer Isolation, and Title Scroll Design

Date: 2026-08-13
Status: Proposed for review

## Context

Build 127 has three user-visible regressions:

1. A response containing a Markdown table or fenced code block cannot be selected across paragraph boundaries. The current renderer creates one `UITextView` only when every parsed block is a simple selectable-flow block. The presence of a table or code block switches the entire response to a SwiftUI fallback in which paragraphs, code, and table cells are separate selectable views.
2. Switching sessions while the composer contains text can crash or leave the app in synchronization. `ComposerBar` owns a stateful UIKit text view whose draft and first-responder state currently outlive the session identity that owns them.
3. The custom toolbar title is a plain `Text`, and the chat has an explicit “scroll to latest” command but no explicit “scroll to top” command.

The focused baseline suite currently passes. It covers the paragraph-only selection path and AppState session cancellation, but not mixed Markdown selection, UIKit composer teardown during a session switch, or title-driven top scrolling.

## Goals

- Preserve the current visual table grid, code card, horizontal table/code scrolling, copy buttons, and rich Markdown rendering.
- Allow selection to span selectable text blocks within one Markdown response, including paragraphs, headings, lists, quotes, table cells, code, and inline links.
- Keep links tappable when the user is performing a normal link interaction, and preserve link attributes in copied content.
- Make composer ownership explicit across session changes so stale first-responder callbacks cannot affect a new session or keep synchronization stuck.
- Make tapping the session title reliably scroll the current conversation to its first content.
- Keep settled Markdown caching and Dynamic Type behavior intact.

## Non-goals

- Flattening tables or code into a single textual card.
- Replacing the existing rich renderer with a single plain `UITextView`.
- Making selection span separate chat messages, system cards, or the visual contents of a rendered Mermaid/LaTeX preview.
- Changing the server-side session or resume protocol unless a new regression test proves the AppState transition itself is incomplete.

## Design

### 1. Response-level Markdown selection coordinator

The existing rich block tree remains the visual source of truth. A Markdown response that uses the fallback renderer will also create a response-scoped selection coordinator. The coordinator manages a logical sequence of selectable child surfaces without replacing their layout.

Each selectable child registers a stable segment containing:

- a block/cell identity and ordering position;
- its current `UITextView` instance;
- the displayed attributed text and local character range;
- a way to convert its bounds and selection rects into the response host’s coordinate space.

The segment order follows rendered Markdown order. Table cells are ordered row-major; code is one segment; paragraphs and inline block views retain their existing local text and attributes.

`SelectableTextView` gains an optional selection-session hook. The existing standalone behavior remains unchanged when no coordinator is supplied, so tool cards and other independent text surfaces keep their current native selection behavior.

#### Selection lifecycle

1. A child text view begins a native selection or long-press interaction and reports its local anchor/focus to the coordinator.
2. A simultaneous, non-cancelling response-host gesture observes the pointer location while that selection is active. It does not intercept ordinary taps, link activation, table scrolling, or the code copy button.
3. If the pointer remains within one child, UIKit continues to own the normal selection behavior.
4. If the pointer crosses into another registered child, the coordinator resolves the destination segment and local caret position from the child’s current layout. It then updates the anchor-to-focus range across all affected segments:
   - the first segment is selected from the anchor to its boundary;
   - intermediate segments are fully selected;
   - the final segment is selected from its boundary to the focus.
5. Selection highlights are rendered in the child views or a response overlay using each text view’s current selection rects. Native handles and the edit menu remain attached to the active endpoint where UIKit supports them.
6. On copy, the coordinator concatenates the selected segment text with the same logical separators used by the Markdown response. The copied attributed content retains inline links, emphasis, code traits, and syntax colors where available.
7. When the gesture ends or the response content changes, the coordinator clears stale registrations and selection state. It never carries character offsets across a changed source revision.

The coordinator must account for nested horizontal scroll views. Segment frames are converted after the table/code scroll view’s current content offset is applied, so a drag over a horizontally scrolled table cell resolves against what is actually visible.

#### Link behavior

The current `SelectableTextView` delegate link handling remains the link activation path. A tap that does not establish a cross-block selection continues to open the URL. Link runs are registered with the coordinator as ordinary character ranges, so a copied multi-block selection includes their display text and link metadata without disabling tapping.

#### Rich block compatibility

The coordinator is used for text-bearing blocks that currently render with one or more child `SelectableTextView`s: paragraphs, headings, lists, quotes, tables, code, callouts, and columns. Images, Mermaid/LaTeX previews, dividers, and other non-text blocks remain visual gaps and are not made selectable through this change. Existing standalone selection in tool input/output and preview source remains available.

The paragraph-only fast path continues to use the existing single cached text view. The coordinator is only needed when the fallback renderer would otherwise split a response into multiple selectable surfaces.

### 2. Composer session isolation

Composer state is separated into:

- session-owned draft data (text and attachments);
- transient editor state (first responder, slash suggestions, paste error, measured height, and UIKit view identity).

The recommended draft policy is to preserve drafts per profile/session in an in-memory draft store while never carrying first-responder state across sessions. On an active-session change, `ComposerBar` will:

1. save the old session’s draft;
2. resign the current text view and dismiss slash suggestions;
3. invalidate the old editor identity so the UIKit bridge cannot deliver callbacks into the new session;
4. restore the destination session’s draft, if any, without automatically focusing it;
5. keep the existing AppState request-generation and reconciliation guards in force.

If review chooses clearing drafts instead, the same lifecycle boundary applies but the store is discarded on each session transition.

The `ComposerPasteTextView` coordinator will ignore callbacks caused by programmatic text/focus updates during this handoff. Context refresh tasks remain keyed to the active session and retain their existing client/session guards.

The AppState implementation will only be changed if a new regression test demonstrates that a superseded explicit open can leave `turnState` or reconciliation ownership unresolved. Existing rapid-switch and cancellation tests remain mandatory.

### 3. Explicit title-driven scroll to top

`AppState` adds a monotonic `chatScrollToTopRequest` signal and `requestChatScrollToTop()` method, parallel to the existing latest-scroll request.

The toolbar principal item becomes a plain-styled button containing the existing title surface. Its accessibility label describes the action as “Scroll to top of conversation.”

`ChatView` adds a stable top anchor to the lazy chat layout. When the request changes, it:

- invalidates an active drag and cancels pending automatic restoration;
- stops following the latest message for this explicit user action;
- scrolls to the top anchor, with one layout-delayed retry for lazy content;
- allows the normal viewport persistence machinery to record the first visible message afterward.

The command works for populated, empty, restored, and long transcripts without relying on implicit navigation-bar behavior.

## Testing strategy

### Unit tests

- Extend `ChatTextSelectionTests` with mixed paragraph/table and paragraph/code fixtures. Assert that the response creates a coordinator, selection ranges span segment boundaries, and table links retain URL attributes.
- Add coordinator tests for forward/reverse selection, full intermediate segments, table row/cell ordering, content revisions, and horizontal-offset geometry.
- Add copy tests for separators and mixed attributed content.
- Add composer lifecycle tests for saving/restoring or clearing drafts, resigning focus, editor identity invalidation, and ignoring programmatic UIKit callbacks.
- Extend `AppStateChatResumeTests` only where a failing session-switch lifecycle case requires it; retain the existing rapid-switch and cancellation coverage.
- Add an AppState scroll-command test verifying each title tap produces a distinct top-scroll request.

### Simulator/UI verification

- Select from a paragraph into a table, from a table into a paragraph, and across a code block in both directions.
- Tap links before and after selection; verify they remain tappable.
- Exercise table horizontal scrolling while selecting.
- Type a multiline composer draft, switch sessions repeatedly, and verify no crash, no stuck synchronization, and the selected draft policy.
- Scroll deep into a long conversation and tap the title; verify the first message is visible.
- Repeat with Dynamic Type changes, light/dark mode, streaming Markdown, and repeated large local image attachment opens.

## Risks and mitigations

- Gesture arbitration may conflict with UIKit’s native selection or table horizontal scrolling. Use simultaneous, non-cancelling recognizers and fall back to native within-block selection when a cross-block gesture cannot be established.
- Multiple selected child views may not all display native selection highlights when they are not first responder. The response overlay will draw selection rects for non-active segments.
- SwiftUI view identity can change while streaming. Stable segment IDs plus source-revision invalidation prevent stale registrations and offsets.
- Per-session draft retention can grow without bound. Limit the store to a small number of recent session keys and drop drafts on memory warning or explicit disconnect.
- The coordinator adds layout work during selection only; Markdown parsing, syntax highlighting, and image decoding remain on their existing cached/off-main paths.

## Rollout

Implement behind no user-facing feature flag, because the old behavior is the reported regression. Land the regression tests first, then the coordinator, composer isolation, and title command in small commits. Run the focused suites, the full simulator test suite, and a manual UI pass before producing a new TestFlight build.
