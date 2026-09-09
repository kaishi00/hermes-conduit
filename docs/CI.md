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
   plan.json / matrices        timing history (Actions cache)
   (unit + UI)
             |
      build-for-testing (once, workspace-anchored DerivedData)
             |
      .xctestrun + products artifact
             |
   +---------+---------+---------+
   v         v         v         v
 unit-1    unit-2    ...     ui-1   ui-2   ui-3 ...
 (test-without-building from the SHARED products;
  measured watchdogs; units use native flake retry,
  UI runs each class as its own invocation with a
  per-class watchdog and one targeted class retry)
   |         |         |         |
   +---------+----+----+---------+
                  v
          report job -> GitHub Step Summary
                  v
        timing-history-update (main only, EWMA)
```

### Jobs

| Job | Runner | Purpose |
|---|---|---|
| `plan` | ubuntu | Discovery validation + planner unit tests + lane generation (unit AND UI matrices). Cheap guard before any macOS minutes are spent. |
| `build` | macos-26 | `build-for-testing` exactly once; `.xctestrun` portability audit; uploads products. |
| `unit` (matrix) | macos-26 | One dynamically planned lane per matrix entry. |
| `ui` (matrix) | macos-26 | Dynamically planned UI lane; runs each class independently (see below). |
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

### Parallel UI lanes

UI classes are balanced with the same LPT algorithm into their own parallel
shards, so normal PR wall clock is governed by the slowest UI shard rather
than the sum of the whole UI suite:

```
ui lanes = clamp(ceil(total_predicted / 480s), 3, 4), capped by class count
```

Today's ~22 minutes of cumulative UI work lands on 3 lanes of roughly
7-8 predicted minutes each. The count scales out automatically if the UI
suite grows (and shrinks if it drops below 3 classes).

### Per-class UI execution

Inside a UI shard, **every class is its own `xcodebuild
test-without-building` invocation** from the shared build products (the app
is never rebuilt). This makes hangs attributable to exactly one class,
enables the per-class watchdogs, restricts any retry to the failed class,
and records per-class timing history. The simulator is booted once at shard
start so only the first class pays the cold-boot overhead; classes that pass
move on immediately; a class that fails gets exactly ONE targeted retry of
just that class - successful classes are never re-executed, and a retry pass
is reported as a runner-level FLAKE (with both attempt result bundles kept),
never hidden as a clean pass. A class whose retry fails again as an
infrastructure failure is recorded as a persistent infrastructure failure
and fails the lane, but the remaining classes still run after a clean
simulator reset; only a confirmed hang or an untrusted recovery stops a
shard early.

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
(`$GITHUB_WORKSPACE/ci-derived-data`, i.e.
`/Users/runner/work/<repo>/<repo>/ci-derived-data`), which is byte-identical
on every GitHub-hosted runner of this repository. The whole `Build/` tree is
uploaded as an artifact and each lane restores it to the same absolute path
before running `test-without-building` - no compilation downstream.

`plan-tests.py audit-xctestrun` fails the run if any absolute path inside the
generated `.xctestrun` points outside the workspace root (or outside known
system locations), so non-portable products are caught at build time, not at
lane time. If Xcode ever produces inherently non-portable products, the audit
is the documented tripwire: revert to per-lane `build-for-testing` and keep
the rest of CI v2.

## Failure domains

1. **Ordinary test failures** never rerun healthy work. Unit attempt 1 runs
   with Xcode-native flake retry (`-retry-tests-on-failure
   -test-iterations N`), which re-executes only the failing tests; survivors
   fail the lane with the failing tests identified. UI classes get one
   **targeted retry of just the failed class**; if the retry passes, the
   class is reported as a runner-level flake and the lane continues.
2. **Unclassifiable failure** - if an invocation exits nonzero and the
   XCTest result cannot be classified (timing/result extraction failed),
   the lane FAILS immediately. Timing extraction is best-effort and must
   never decide test correctness, so an unclassifiable failure is never
   retried into a green lane.
3. **Infrastructure failure** - an invocation that exits nonzero with a
   KNOWN zero failing-test count (simulator crash, runner exit) gets
   exactly one bounded recovery: reset the simulator and retry. Units retry
   the whole lane (it is one invocation); a UI lane retries only the
   affected class. If a UI class fails AGAIN as an infrastructure failure,
   it is recorded as a **persistent infrastructure failure** and the lane
   fails - but the remaining classes still run after a clean simulator
   reset, because the culprit is fully identified and a wedge must not
   suppress otherwise-independent UI coverage. If that recovery itself
   cannot be trusted (erase failed, UDID unresolvable, boot never
   completed), later results would be misleading: the lane stops there and
   the remaining classes are recorded as `not_diagnosed`. A retry that
   times out falls through to hang handling (4).
4. **Hang / timeout** - a watchdog kill is positive identification of a
   hang. Units erase the simulator and enter **isolation** immediately (no
   second full-lane attempt): classes re-run one at a time (heaviest
   estimate first, each under `max(180s, 4 x estimate)`, bounded by the
   isolation budget). Isolation STOPS at the first confirmed class-level
   hang - the culprit is identified and later classes are recorded as
   `not_diagnosed` instead of running on a potentially contaminated
   simulator. UI classes are already isolated: the simulator is erased and
   the SAME class retries once under its own watchdog; a second timeout
   names the hung class (`hung_class` in the lane result), fails the lane,
   and later classes are recorded as `not_diagnosed`. Recovery-to-green is
   only legitimate when the retried class completed successfully; any
   undiagnosed class fails the lane so unexecuted tests stay visible.

### Destination readiness gate

The build job pins one known simulator name (`SIMULATOR_NAME`, no `simctl`
enumeration on the happy path). Fresh hosted runners occasionally reach the
build step before CoreSimulator has settled its device pairs; xcodebuild then
fails destination resolution with an **empty** available-destinations list
("Unable to find a device matching the provided destination specifier") and
every downstream lane is skipped. Before invoking xcodebuild,
`ci-build-for-testing.sh` now runs `wait_for_destination_device`
(`ci-lib.sh`): a bounded poll (default 180 s, `DESTINATION_SETTLE_TIMEOUT_S`)
of `simctl list devices available` that absorbs the settlement race and, if
the pinned device never appears, fails fast with the full device/runtime
inventory instead of a misleading xcodebuild error. The gate never
substitutes another device for the pinned name - an image refresh that
renames devices still fails, with an explicit diagnostic. The lookup behind
the gate (`simulator_udid`) is also OS-qualified: when `SIMULATOR_OS` is
set, only a device with the pinned name on that exact runtime satisfies it
(exact numeric-component match, so `26.1` never matches `26.10`), with no
fallback to another runtime - the resolved UDID always belongs to the
destination xcodebuild will use. `SIMULATOR_OS` must be numeric dotted
components (e.g. `26.0`); xcodebuild-only values such as `latest` are not
supported by the pin and fail the gate.

## Watchdogs

Unit lanes: `timeout = max(min_timeout, ceil(predicted x 2.5))` with a 600 s
floor. The outer GitHub job ceiling is `ceil((3 x watchdog + 1200s) / 60)`
minutes - attempt 1 + attempt 2 + a full isolation pass plus two bounded
simulator resets and setup/download slack - so the ceiling can never preempt
legitimate in-script recovery (the script watchdogs are the real
enforcement).

UI classes each get their **own** watchdog, planned per class from the same
timing data that balances the lanes. **`plan-tests.py` is the single
authority for this policy**: every UI lane receives an explicit budget table
(`--class-timeouts`) and the runner refuses to start unless it covers every
assigned class - there is no fallback formula in `ci-test-lane.sh` to drift
from the planner:

```
ui_class_timeout = max(420s, ceil(estimate x 3.0))   # computed in plan-tests.py only
```

- the floor carries the fixed xcodebuild/automation-session/simulator
  overhead that dominates small classes (~2.5 min before the first test +
  ~1 min of xcresult finalization on macos-26, measured - see the run #500
  history for why this floor must not be lower), plus headroom for the
  targeted retry of a legitimately slow class;
- the 3x multiplier gives slow-but-healthy classes proportional room on
  slower runners without letting any single class hold a lane hostage;
- a class normally taking 2-4 minutes is caught in ~7-17 minutes if it
  hangs, instead of the old single 2861s (~48 min) suite-level watchdog;
- estimates come from timing history (EWMA, outlier-clamped), so one
  anomalous run cannot inflate a class's watchdog;
- UI lane ceilings are `sum(per-class budgets)`, and the outer GitHub job
  ceiling is `ceil((2 x sum + (n_classes + 1) x 600s + 2 x n_classes x 300s
  + 1200s) / 60)` minutes - the worst in-script path is every class running
  its one targeted retry, each failing class paying one bounded
  erase/reboot recovery, and each attempt's timing extraction wedging to
  the xcresulttool bound, plus setup slack.

**Finalize grace.** When a watchdog expires but the log already carries
xcodebuild's terminal result marker (`** TEST EXECUTE SUCCEEDED/FAILED **`),
the test session has ENDED and the process is only writing its xcresult.
Killing there converts a completed run into a timeout (run #500) and can
truncate the result bundle, so the deadline is extended once by a bounded
`XCODEBUILD_FINALIZE_GRACE_S` (default 180 s) and the process may exit on its
own. The verdict still comes exclusively from the real exit status - the
marker never declares success on its own - and a process that outlives the
grace is killed and classified as a timeout exactly as before.

Every `simctl` operation is deadline-bounded; the process-group watchdog kill
(xcodebuild + xctest + simulator agents) is preserved from the previous
architecture.

## Observability

Every lane uploads a `lane-<lane-name>` artifact (e.g. `lane-ui-1`,
`lane-unit-3`) containing `lane-result.json` (status, attempt chain, hung
class, retried classes, predicted vs actual), the merged per-class timings
(`observations.json`) and per-test attempt details (`detail.json`), and a
`logs/` directory. UI lanes log and name every invocation by class and
attempt (`logs/class-<class>-a<N>.log`), keep per-attempt `.xcresult`
bundles for failed lanes, and on a green lane preserve both attempt bundles
of any class that needed its targeted retry. Timing history is recorded per
class (UI included), which is what lets the planner balance UI shards from
real runtimes.

## CI Gate (branch protection)

The `CI Gate` job is the single stable required status check for branch
protection. It passes only when:

* `plan`, `build` and every dynamic `unit` lane succeed, and
* every dynamic `ui` lane succeeds (or is skipped entirely because the repo
  contains no UI tests).

The number of dynamic unit AND UI lanes can change between runs, so lane
jobs must never be pinned individually. Configure repository branch
protection to require **CI Gate**, replacing the obsolete **Build & Test**
check from the previous architecture. The `Report` job is best-effort and
must not be used as a required check.

Every run ends with a **CI Test Report** step summary: build duration,
per-lane predicted vs actual runtimes (unit and UI), retries/flake warnings
(native-test flakes, runner-level class retries, and infrastructure-wedge
recoveries - each labeled for what it is), hang results with the identified
class, slowest classes, predicted and actual lane imbalance, and overall
wall clock. On failure it names the failing test, the lane, whether a
simulator reset/erase occurred, whether the targeted retry passed, and any
classes left `not_diagnosed` after a confirmed hang.

## Adding a test

Just add it. The planner discovers it on the next run, gives it the default
estimate (or its real history entry after the first main run), and balances
it into a lane. No lane-assignment files to maintain. To check locally:

```
python3 scripts/plan-tests.py validate
python3 -m unittest discover -s scripts/tests
```

## Local run directories

The CI workspace uses `ci-derived-data/`, `ci-lane/`, `ci-artifacts/`,
`ci-timing/`, `ci-report/`, `ci-update/` (all gitignored); the same paths
work for local rehearsal of the scripts.