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
   `linked-rooms` or `all-live` that merges main, an entry main changed since
   that branch last took it that matches main's copy came in with main and
   keeps main's line). A feature with siblings and no entry gets one in that
   PR. A fix that brings a sibling in line with an earlier change it missed
   adds that sibling to the entry, so the next change reaches it.
5. Text that describes a behavior is one of its siblings: Settings captions,
   the briefings and tool results models read, the notifier's tool
   descriptions, README.md and docs/. List them in Siblings with the rest.
6. Conduit for desktop
   ([hermes-conduit-desktop](https://github.com/kaishi00/hermes-conduit-desktop))
   is a sibling of every feature it draws. Each entry's Desktop app line says
   whether it has the feature: has it or partly (naming where), not applicable
   (Watch, CarPlay, widgets and other phone-only features), gap (what's
   missing) or unchecked. The PR's Desktop section says Done (the desktop PR),
   Not needed (why) or Follow-up (the desktop issue or PR, or the entry whose
   Desktop app line records the gap), and CI fails a PR without one. A change
   to a feature the desktop has makes the desktop change too, or records the
   gap; keep the desktop compatible where it's cheap, but never hold or narrow
   a Conduit feature for it (Eric, 2026-11-11). The Desktop app line is left
   out of the Checked rule, so a desktop PR catching a feature up can flip it
   from gap to has it without a Checked line.

## Checks

CI runs these on Linux in seconds (docs/CI.md has the rest of CI). To run
them before pushing:

    python3 scripts/check-feature-map.py --repo-root .
    python3 scripts/check-l10n-coverage.py --repo-root .
    python3 scripts/plan-tests.py validate --repo-root . --baseline scripts/test-timings.json
    CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS=1 python3 -m unittest discover -s scripts/tests -p 'test_*.py'

## Fork PRs

Open a PR from a fork as a draft, and mark it ready when you've finished
pushing. The opencode reviews run on a trusted contributor's PR (the list in
`.github/workflows/opencode-review.yml`) once it's ready and on every push
after that, never while it's a draft. Anyone else's fork PR is reviewed after
a maintainer adds the `run-review` label. CI builds every push, once GitHub
no longer asks a maintainer to approve a first-time contributor's runs.

## Review labels

A PR labeled `waiting on contributor` is waiting on its author. Push or comment
on the PR when you've answered it, and a workflow swaps the label for
`waiting on Eric`, so the maintainer knows it's his turn again. Putting
`waiting on contributor` back on takes `waiting on Eric` off. A reply inside a
review thread doesn't count, so also comment on the PR itself or push.
