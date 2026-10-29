# Plan card

The open chat shows what the agent is working through right now, its
plan, titled "Tasks", docked above the composer: one slim line that opens
upward into the whole card. It isn't shown in a chat that has none.

(A floating card at the top right and an artifact card were tried first.
The plan moved to the bottom on review, since a chat is read from the
bottom, where the live working line, the composer and the main button
are; the artifact card was dropped.)

## What Hermes sends (checked against Hermes 0.21.0, tag v2026.8.31)

Hermes has one planning tool, `todo` (`tools/todo_tool.py`):

- Arguments: `todos: [{id, content, status, parent?}]` and `merge: bool`.
  `merge: false` (the default) replaces the list; `merge: true` updates
  items by id and appends new ones. No `todos` reads the list.
- Statuses: `pending`, `in_progress`, `completed`, `cancelled`. List order
  is priority. `parent` nests a subtask under another item.
- **Every call returns the full list** as JSON:
  `{"todos": [...], "revision": N, "summary": {...}}`. The revision goes up
  by one on every write that changes the list. An error returns
  `{"error": ...}`.
- The gateway always sends `tool.start` / `tool.complete` for `todo`,
  even with tool progress turned off, and the completion's `result` is that
  full list. It also sends a `todo.updated` event with the same snapshot.
- `session.resume` attaches `todo_state: {todos, revision}`. The gateway
  works it out from the latest `todo` result in the whole stored history,
  not only the page Conduit loads.

Other things named "plan" in Hermes (the `plan-mode` plugin, `/plan`
prompts, billing plans) aren't task lists. Subagents keep their own
`todo` lists, and those don't reach the parent chat's events.

## Working out the current plan

Each source below takes over from the one before it:

1. **The transcript.** Walking back from the newest `todo` row:
   - A row whose output is a full list is the plan. Stop there.
   - A row with no output yet (still running, or a compact resume row)
     uses its arguments. A replace write is a full list, so stop there. A
     merge write is kept and applied on top of the full list found further
     back.
   - A read call, or an error, is skipped.

   This is the "find the last full plan, then replay the updates after it"
   walk. Since Hermes returns the full list every time, it usually stops at
   the first row.
2. **`todo_state` on `session.resume`.** It covers a chat whose last plan
   is older than the history page Conduit loaded.

The loaded page is the tail of the history, so a plan it shows is the
newest one: the transcript wins whenever it has one. Otherwise the resume
snapshot stands.

**The plugin isn't needed.** Hermes 0.21 already gives Conduit the newest
plan when a chat opens, without working anything out on the phone. The
conduit_push plugin doesn't change.

## Plan card

- **Hidden** when the chat has no plan, or the plan is empty.
- **The line** (folded, the default): a small progress ring, "Tasks",
  "2/5" and the item in progress ("Copy uploads and fix permissions"),
  then a chevron. A finished plan shows a green check and "Tasks 5/5".
  Tapping it opens the card.
- **The card** opens upward from the line: title "Tasks", a count ("3 of
  5 done"), a thin progress bar, and the items. A spinner marks the item
  in progress, an empty circle marks a pending one, a check marks a
  completed one (dimmed), and a struck-through dash marks a cancelled
  one. Subtasks are indented. Its chevron folds it back to the line.
- **A new plan announces itself on the line**: the line pops in (or, if
  it was already there, pulses with an accent tint for half a second),
  with a light haptic, and VoiceOver reads the line out ("Tasks, 0 of 4
  done, now: …"). It doesn't open over the chat. A plan counts as
  new when it's the first in the chat, when fewer than half of its items
  match the previous plan's (same id and same text), or when work is
  added to a finished plan.
- **A finished plan goes after a while.** It shows "✓ Tasks 5/5" for
  60 s after its last item is completed or cancelled, then disappears:
  the line and, if the user had it open, the card or the whole-plan
  sheet. Opening or folding the card of a
  finished plan starts those 60 s again. More work on it (an item added
  or reopened) brings the line back and announces it, and so does a
  new plan that arrives already finished; that one gets its own 60 s.
- **Reopening a chat** shows an unfinished plan's line; nothing
  announces. A plan that finished before the chat opened shows nothing.
- **Too many items:** the card shows at most 5 rows. They're picked around
  the active item: the one just before it, the active item, then the next
  pending ones. Completed items above that window fold into one "✓ 4 done"
  row, and the rest fold into "+6 more". Each item is at most 2 lines.
  Tapping the header or "more" opens a sheet with the whole plan.
- **Pin:** a pin button keeps the card open, finished or not.
  The pin is a preference for every chat (pinning means "I always want
  to see the plan"), not a setting of one chat. Folding a pinned card
  unpins it.

## Layout

- In the stack above the composer, with the minimised call bar and the
  read-aloud player: the same 12 pt side margins and glass. Being in that
  stack, it never covers messages: the transcript's bottom inset grows
  by its height.
- **Keyboard up** (someone typing): the plan keeps to its one line; an
  open card comes back when the keyboard goes. A tap on the line puts the
  keyboard away and opens the card. A Mac has no on-screen keyboard and
  its composer keeps focus between messages, and a hardware keyboard puts
  it away, so there the line opens whatever the focus (issue 1510). The
  classic shell doesn't report the composer's focus, so there the line
  never keeps to itself.
- The line pops up from the composer and the card opens upward with a
  slight overshoot. Under Reduce Motion they fade without moving and the
  line doesn't pulse.
- Liquid Glass (`conduitGlassControl`) on iOS 26, and a material
  background before that.
- It doesn't show in the saved offline copy, a pending New Chat, or a
  group room.
- VoiceOver reads the line and the card's header as one element:
  "Tasks, 3 of 5 done, now: …".
- Text size: the line and the card stop growing at the first
  accessibility size; the whole-plan sheet, a scrolling list, takes
  every size.
