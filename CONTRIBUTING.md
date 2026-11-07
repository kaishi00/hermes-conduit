# Contributing to hermes-conduit

Conduit is the iPhone, iPad and Apple Watch app for Hermes Agent, with
CarPlay. Its plugin and push relay are
[hermes-conduit-notifier](https://github.com/kaishi00/hermes-conduit-notifier).

## Connected features

Many features have siblings: the same behavior in each voice mode, on the
Watch and in CarPlay, in group rooms, or in the notifier.
[docs/FEATURE_MAP.md](docs/FEATURE_MAP.md) lists them, feature by feature.
Nobody tends it separately: each PR that changes a feature keeps its entry
current.

1. Before changing a feature, find its entry in the map and put every sibling
   on your plan before writing code.
2. Follow the entry's rulings. Changing a ruling is the maintainer's call;
   record their decision in the entry, with the date and the PR.
3. In the PR, fill in Siblings: each one done, not needed (and why), or a gap
   left open for the maintainer to decide. "No mapped feature" is only for a
   change with no siblings. A refactor that changes no behavior and no
   user-facing or model-facing text (moving code, or changing how state is
   stored or observed) has none and needs no new entry; if it moves code an
   entry's Code lists, it updates those paths and that entry's Checked line.
4. Update the entry in the same PR: its siblings, code paths, rulings, the gaps
   opened or closed, and the Checked line, which names this PR (CI fails an
   entry the PR adds or edits whose Checked line doesn't; on a PR into
   `linked-rooms` that merges main, an entry main changed since
   that branch last took it that matches main's copy came in with main and
   keeps main's line). A feature with siblings and no entry gets one in that
   PR. A fix that brings a sibling in line with an earlier change it missed
   adds that sibling to the entry, so the next change reaches it.
5. Text that describes a behavior is one of its siblings: Settings captions,
   the briefings and tool results models read, the notifier's tool
   descriptions, README.md and docs/. List them in Siblings with the rest.

## Checks

CI runs these on Linux in seconds (docs/CI.md has the rest of CI). To run
them before pushing:

    python3 scripts/check-feature-map.py --repo-root .
    python3 scripts/check-l10n-coverage.py --repo-root .
    python3 scripts/plan-tests.py validate --repo-root . --baseline scripts/test-timings.json
    CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS=1 python3 -m unittest discover -s scripts/tests -p 'test_*.py'

## Review labels

A PR labeled `waiting on contributor` is waiting on its author. Push or comment
on the PR when you've answered it, and a workflow swaps the label for
`waiting on Eric`, so the maintainer knows it's his turn again. Putting
`waiting on contributor` back on takes `waiting on Eric` off. A reply inside a
review thread doesn't count, so also comment on the PR itself or push.
