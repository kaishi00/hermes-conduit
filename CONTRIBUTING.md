# Contributing to hermes-conduit

Conduit is the iPhone, iPad and Apple Watch app for Hermes Agent, with
CarPlay. Its plugin and push relay are
[hermes-conduit-notifier](https://github.com/kaishi00/hermes-conduit-notifier).

## Connected features

Many features have siblings: the same behavior in each voice mode, on the
Watch and in CarPlay, in group rooms, or in the notifier.
[docs/FEATURE_MAP.md](docs/FEATURE_MAP.md) lists them, feature by feature.

1. Before changing a feature, find its entry in the map and put every sibling
   on your plan before writing code.
2. Follow the entry's rulings. Changing a ruling is the maintainer's call.
3. In the PR, fill in Siblings: each one done, not needed (and why), or a gap
   left open for the maintainer to decide.
4. Update the entry in the same PR: its siblings, code paths, rulings, the gaps
   opened or closed, and the Checked line. A feature with siblings and no
   entry gets one.
5. Text that describes a behavior is one of its siblings: Settings captions,
   the briefings and tool results models read, the notifier's tool
   descriptions, README.md and docs/.

## Checks

CI runs these on Linux in seconds (docs/CI.md has the rest of CI). To run
them before pushing:

    python3 scripts/check-feature-map.py --repo-root .
    python3 scripts/check-l10n-coverage.py --repo-root .
    python3 scripts/plan-tests.py validate --repo-root . --baseline scripts/test-timings.json
    CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS=1 python3 -m unittest discover -s scripts/tests -p 'test_*.py'
