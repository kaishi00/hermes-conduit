# CI v2 — timing-aware dynamic test lanes

This document describes the Conduit CI architecture that replaced the static
`unit-a…unit-d` shard system (see PR history for the migration). The pipeline
still runs the complete XCTest suite on every PR; nothing is skipped,
quarantined, or moved to a nightly gate.

## Architecture

```
                 test inventory (source scan)
                          |
                   plan-tests.py
             (LPT timing balance, watchdog math)
                          |
             +------------+------------+
             v                         v
   plan.json / unit matrix      timing history (Actions cache)
             |
      build-for-testing (once, workspace-anchored DerivedData)
             |
      .xctestrun + products artifact
             |
   +---------+---------+---------+
   v         v         v         v
 unit-1    unit-2    ...      unit-N         ui lane
 (test-without-building, measured watchdogs, native flake retry,
  class-granular hang isolation)
   |         |         |         |           |
   +---------+----+----+---------+-----------+
                  v
          report job -> GitHub Step Summary
                  v
        timing-history-update (main only, EWMA)
```

### Jobs

| Job | Runner | Purpose |
|---|---|---|
| `plan` | ubuntu | Discovery validation + planner unit tests + lane generation. Cheap guard before any macOS minutes are spent. |
| `build` | macos-26 | `build-for-testing` exactly once; `.xctestrun` portability audit; uploads products. |
| `unit` (matrix) | macos-26 | One dynamically planned lane per matrix entry. |
| `ui` | macos-26 | ConduitUITests lane, separate from the unit pool. |
| `report` | ubuntu | Aggregates lane results into the CI Test Report step summary. |
| `timing-history-update` | ubuntu | Main-only: merges fresh timings into the history cache (EWMA). |

## Test discovery

`scripts/plan-tests.py` discovers XCTestCase classes by scanning
`ConduitTests/` and `ConduitUITests/` sources:

* A class is a **test class** if it directly inherits `XCTestCase` (repo
  convention) or is named `*Tests` and inherits `XCTestCase` transitively.
  This matches the XCTest runtime inventory exactly (verified against
  `xcodebuild -enumerate-tests`: 67 unit + 1 UI classes).
* Classes that merely resolve to `XCTestCase` without the above (mocks such
  as `MockGateway`, `FakeSocket`) enumerate zero tests and are excluded from
  lanes - the same behavior as the old static shard guard.
* Target membership comes from the **directory** (`ConduitTests/` vs
  `ConduitUITests/`), never from the class name.
* Duplicates, and `*Tests`-named classes that do not resolve to
  `XCTestCase`, are hard errors. A new test class can never silently miss CI.

## Dynamic lanes

Unit classes are balanced with **longest-processing-time-first** (LPT) over
per-class duration estimates, with deterministic tie-breaking (estimate
descending, then class name). Lane count is derived, not fixed:

```
lanes = clamp(ceil(total_predicted / 240s), 4, 8), capped by class count
```

so the suite scales toward more lanes as measured runtime grows. Predicted
imbalance is reported in the plan summary and the CI Test Report.

## Timing data

* `scripts/test-timings.json` - checked-in **baseline fallback** (seconds per
  class), seeded from a full-suite xcresult measured on local hardware.
  Unseen classes get a conservative default (20 s) so a batch of new tests
  cannot all pile into one lane.
* **Timing history** - living estimates kept in a GitHub Actions cache
  (`timing-history-v1-*`). Only successful main runs write it; PR runs
  consume it read-only. Missing, corrupt, or stale history simply falls back
  to the baseline; planning correctness never depends on it.
* `scripts/update-timing-history.py` merges fresh per-class durations with an
  EWMA (`updated = 0.75 * previous + 0.25 * observed`), clamps extreme
  outliers to 5x the previous estimate, takes first observations verbatim,
  and prunes entries for classes that no longer exist.

## Build-once artifact fanout

The `.xctestrun` file embeds absolute paths. Instead of rewriting them
fragilely, the build uses a **workspace-anchored DerivedData path**
(`$GITHUB_WORKSPACE/.ci-derived-data`, i.e.
`/Users/runner/work/<repo>/<repo>/.ci-derived-data`), which is byte-identical
on every GitHub-hosted runner of this repository. The whole `Build/` tree is
uploaded as an artifact and each lane restores it to the same absolute path
before running `test-without-building` - no compilation downstream.

`plan-tests.py audit-xctestrun` fails the run if any absolute path inside the
generated `.xctestrun` points outside the workspace root (or outside known
system locations), so non-portable products are caught at build time, not at
lane time. If Xcode ever produces inherently non-portable products, the audit
is the documented tripwire: revert to per-lane `build-for-testing` and keep
the rest of CI v2.

## Retry and failure domains

1. **Ordinary test failure** - attempt 1 runs with Xcode-native
   `-retry-tests-on-failure -test-iterations 3`, which re-executes only the
   failing tests. Surviving failures fail the lane; healthy classes never
   rerun. Tests that passed after a retry are reported prominently as
   **FLAKE WARNING** in the summary (green-after-retry stays the policy, but
   the flake is visible).
2. **Infrastructure failure** - an invocation that dies without any test
   results (simulator crash, runner exit) gets exactly one bounded recovery:
   reset the simulator, retry the lane once.
3. **Hang / timeout** - a different failure mode. After the watchdog kills
   the xcodebuild process group, the simulator is reset **with erase** before
   the one full-lane retry; if that retry times out too, the lane enters
   **isolation**: classes re-run one at a time (heaviest estimate first,
   each under `max(180s, 4 x estimate)`, bounded by the isolation budget).
   The lane result names the class that hung ("Class C TIMEOUT, Class D
   PASS" style). Recovery-to-green is only legitimate when the isolation pass
   completed every class successfully; any undiagnosed class fails the lane
   so unexecuted tests stay visible.

## Watchdogs

`timeout = max(min_timeout, ceil(predicted x 2.5))` with a 300 s floor for
unit lanes (420 s for UI). The outer GitHub job ceiling is
`ceil((2 x watchdog + 600s) / 60)` minutes - the watchdog plus a full
isolation pass plus setup/download slack - so the ceiling can never preempt
legitimate in-script recovery (the script watchdogs are the real
enforcement).

Every `simctl` operation is deadline-bounded; the process-group watchdog kill
(xcodebuild + xctest + simulator agents) is preserved from the previous
architecture.

## Observability

Every run ends with a **CI Test Report** step summary: build duration,
per-lane predicted vs actual runtimes, UI lane result, retries/flake
warnings, hang isolation results with the identified class, slowest classes,
predicted and actual lane imbalance, and overall wall clock. On failure it
names the failing test, the lane, whether a simulator reset/erase occurred,
and whether the retry passed.

## Adding a test

Just add it. The planner discovers it on the next run, gives it the default
estimate (or its real history entry after the first main run), and balances
it into a lane. No lane-assignment files to maintain. To check locally:

```
python3 scripts/plan-tests.py validate
python3 -m unittest discover -s scripts/tests
```

## Local run directories

The CI workspace uses `.ci-derived-data/`, `.ci-lane/`, `.ci-artifacts/`,
`.ci-timing/`, `.ci-report/`, `.ci-update/` (all gitignored); the same paths
work for local rehearsal of the scripts.
