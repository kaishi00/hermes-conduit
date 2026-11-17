# CI — GitHub-hosted CI is the merge gate (CI v5)

**As of 2026-09-30, GitHub-hosted CI is the only merge gate.** No merge or
release needs a Mac result. The Mac local gate it replaced (`local-ci-gate.sh`,
`local-gate.py`, `ci-test-lane.sh`, `ci-gate-lock.sh` and their tests) was
deleted on 2026-10-25; git history has it, and this document's history before
that date describes it.

## CI v5 at a glance

CI v5 pairs CI v3's lightweight merge gate with CI v4's comprehensive
coverage, moved to the nightly run. CI v4 ran three macOS jobs on every PR and
every push to `main` (two unit shards with every unit class, plus UI smoke),
about 18 minutes per run, and with GitHub's limit of 5 concurrent macOS jobs
per account, waiting for a runner had become the main cost.

| Workflow | When | What runs | Gates a merge? |
|---|---|---|---|
| `.github/workflows/ci.yml` | every PR and every push to `main`, `linked-rooms` or `all-live` (each of those branches runs its own copy) | the Linux validation and CI-tooling self-test, and **one macOS job** (`Smoke`, left out of a docs-only PR or one-commit docs-only push) that builds once and runs the pinned unit smoke tests on that build and simulator, and on a push the pinned UI smoke tests too | yes, through the single `CI Gate` check |
| `.github/workflows/nightly.yml` | nightly on `main` at 3:17 AM ET, dispatched by a timer on the Hermes host ([scripts/nightly-timer/](../scripts/nightly-timer/README.md)) with its own cron as a backup that skips when that run happened, and on demand (Actions > Nightly > Run workflow) | **every unit class** except the timing families in `unit_shards` balanced jobs, the timing/performance/dormancy families repeated 3 times, and the **complete UI suite** in `nightly_ui_shards` jobs, no job retrying its own tests (`nightly-rerun.yml` reruns only a nightly run's jobs that never got a runner; an invocation whose simulator runtime was lost before any test ran runs once more after a reboot, `scripts/ci-recover-lost-runtime.sh`) | no; a failed nightly run emails the owner |
| `.github/workflows/nightly-rerun.yml` | a nightly Nightly run that failed: the cron's or the timer's "Nightly (overnight)" (never another dispatched one, so a release candidate's run keeps its result) | reruns the run's failed jobs when every one of them was cancelled without ever getting a runner (macOS capacity), at most twice; a run with a job that ran and failed is left alone | no |
| `.github/workflows/contributor-label.yml` | a push or PR comment by the author of a PR labeled `waiting on contributor`, and that label being added | swaps the label for `waiting on Eric` (and back); it only edits labels and checks nothing out | no |

**Releases** have no workflow of their own: a release candidate is validated
by dispatching Nightly on the release ref (Actions > Nightly > Run workflow,
pick the release branch, or `gh workflow run nightly.yml --ref <release-branch>`)
before the TestFlight upload, and checking that every job passed. That run
is the full unit suite, the timing repeats and the complete UI suite on the
exact code being shipped.

`scripts/smoke-suite.json` owns the smoke selection: single tests, pinned as
`Class/testMethod` (70 unit, 4 UI), capped by `max_unit_tests` and
`max_ui_tests`, and `plan-tests.py smoke` validates them against the
discovered inventory on every run: a renamed test, a whole class or a list
over its cap fails the plan job. The UI tests run on pushes to `main`,
`linked-rooms` and `all-live` only, not on PRs (Eric, 2026-11-02, [UI smoke after the merge](#ui-smoke-after-the-merge)). `scripts/hosted-suite.json` owns the nightly shape: the shard counts and
the `nightly_only_unit` list. `plan-tests.py hosted` puts every discovered
unit class in exactly one nightly unit shard or the nightly-only list, and
every UI class in one nightly UI shard. It runs in ci.yml's self-test job too, so a
renamed class fails the PR that renamed it, not the next night, and no test
can drop out of both workflows.

Two additions ride in the same unit invocation. The **source contracts**
(`source_contracts`: the accessibility label audit, log redaction, the privacy
manifest) are static scans that take seconds and that a PR breaks without
touching them. The **change's own classes**: `plan-tests.py smoke
--changed-from HEAD^1` adds every unit class declared or extended in a changed
`ConduitTests/` file, and `<Stem>Tests` for a changed app file `<Stem>.swift`,
cheapest first within `changed_budget_s` of baseline time (a class with no
baseline counts 3 s) and `changed_max_classes`. What budget is left goes to
the stem's family, `<Stem><Topic>Tests`, also cheapest first: a change to
`AppState.swift` or `AppState+Composer.swift` brings in about fifteen of the
`AppState...Tests` (`AppStateMultiDashboardTests` among them), and a heavy
member that no longer fits, such as the 35 s `AppStateChatResumeTests`, runs
at night. The rest are named in a notice and the step summary. A changed class
runs whole, in place of any tests pinned from it.
Timing families are never added, and neither are changed UI classes: UI
tests take 36-150 s each, so a UI test a PR adds or edits first runs at
night. Most red nights from 2026-10-19 to 10-22
were tests a PR had added or edited and never run before merge; 2026-10-24's
was an `AppState.swift` change (#1154) that broke `AppStateChatResumeTests`.

What a PR still does not get is the full unit suite: a unit test outside
these that a PR breaks fails that night's run on `main`, and whoever merged
the breaking PR fixes `main` forward.

### How a macOS test job spends its time

Each macOS job (`smoke` and every nightly job) runs
`scripts/ci-hosted-build.sh`. It starts `ci-prepare-smoke.sh` (the pinned
simulator's lookup, boot and `bootstatus`) in the background and runs
`ci-build-for-testing.sh` on the same runner, which waits for the preparation
to end and then resolves packages and compiles the test products. On the v3
runs, boot readiness was a serial ~2.5 minutes after a separate build job and
an artifact hop.

What gets compiled (2026-10-15, when builds had grown to 9-17 minutes):

- **The full app on every PR, from main's latest build.** The smoke job
  builds `project.yml`, the app as shipped with its Watch app and
  extensions, on every PR and push that builds (a docs-only one skips,
  see CI Gate). From 2026-10-15 to 10-29 a PR that
  didn't touch those targets built `project-tests.yml` instead, an xcodegen
  overlay of `project.yml` whose only change is that the Conduit target no
  longer embeds the Watch app and the app extensions. But the only cache of
  that build is the one nightly unit shard 1 saves, so such a PR recompiled
  everything main had merged since the night: over 275 green Smoke runs from
  2026-10-22 to 10-29 its build finished after 682 s (median), against 537 s
  for a PR building the full app from the latest merge's cache, Watch app
  included. A full build also catches a Watch or extension compile error
  before merge. The nightly unit shards and timing repeats still build
  `project-tests.yml`.
- **Incremental builds from an earlier build.** Builds on `main` save their
  DerivedData to the Actions cache, keyed by project kind,
  Xcode build and runner image (`dd-v1-<kind>-<xcode>-<image>-<sha>`): the
  smoke job of every push to `main` that builds saves the full app (right
  after its build and weak-imports check, before its tests: its UI smoke runs
  another 3-5 minutes, and a PR opened meanwhile restored an older build and
  recompiled main's latest merge, 2026-11-16), and nightly unit
  shard 1 saves the app-only (slim) build when it runs on `main`. A push to
  `linked-rooms` or `all-live` saves its full app as well, for that branch's
  later pushes and the PRs into it (GitHub gives a run its own branch's
  entries, a PR's base branch's and main's). A PR's Smoke run saves its
  build too (since 2026-11-16), so the PR's next push, often a review fix,
  restores the PR's own last build and recompiles only what changed since,
  not the PR again on top of main's (or its base branch's) build; it costs about half a minute of upload
  per run and more churn under the repository's cache limit, where main's
  newest entry, which every run can fall back to, stays. A failed save only warns. The
  smoke job and the nightly unit shards restore the newest matching entry before
  building (from the same runner
  image if there is one, otherwise from any image with the same Xcode build,
  which happens while GitHub rolls out a new image), so a PR recompiles only
  what it changed since its own last build or, on its first run, main's latest merge. Xcode trusts a restored build only when each input's file
  info matches exactly, and a fresh checkout stamps every file with the clone
  time, so `ci-build-for-testing.sh` first gives every tracked file (and the
  generated project) a timestamp derived from its content
  (`ci-normalize-mtimes.py`) and sets XCBuild's
  `IgnoreFileSystemDeviceInodeChanges`. An incremental build that fails with
  no error in a source file is retried once from scratch. The build's notice
  and log line name how many Swift files each target compiled, so a slow
  incremental build shows what it rebuilt. A new Xcode build
  misses the cache and builds clean, and a build that restored no cache (the
  nightly UI shards' every build) gets 1800 s instead of 1200 s: the first
  Xcode 27 build outran 1200 s (#2319). Every nightly build gets 1800 s: the unit
  shards' and timing repeats' restored cache is the last Nightly's, and builds
  from it still outran 1200 s beside the other nightly jobs (2026-11-13). Every macOS job selects the newest
  released Xcode on its image (`ci-select-xcode.sh`), not the image's default
  `Xcode.app`, which can lag it (27.1 beside 27.2 and its iOS 27.2 runtime). When the selected Xcode can't run `metal` (image 20261112.0361.1's
  Xcode 27.3 shipped without the Metal toolchain component, and every build
  failed at CompileMetalFile), the script downloads it first; every macOS job on such an image pays that fetch until GitHub updates the image. When the download fails too (Apple's catalog had no toolchain for that build, the 2026-11-16 Nightly), the script selects the next newest release and tries again, then the image's default `Xcode.app`. A candidate whose iOS simulator SDK lookup fails or returns no version is skipped before the Metal check. A fallback that needs runtime pins is also skipped when its watchOS simulator SDK lookup fails or returns no version. The step fails when no candidate has the required simulator SDKs and a working Metal toolchain. A job that falls back to an Xcode with an older simulator SDK than the first candidate with an SDK pins `SIMULATOR_OS` and `WATCH_SIMULATOR_OS` to its Xcode's simulator SDK versions through `GITHUB_ENV` (the Select Xcode steps run `sudo --preserve-env=GITHUB_ENV`). Versions are compared numerically: another copy of the same version (such as `Xcode_27.3.app` beside `Xcode_27.3.0.app`) or a newer default `Xcode.app` pins nothing. This keeps the device lookups' newest-runtime rule (`scripts/ci-lib.sh`, and the App Store screenshots jobs' own iPhone, iPad and Watch lookups) from picking a runtime that Xcode can't build for. The nightly timing repeats build
  `project-tests.yml` too and restore the slim cache without saving it
  (since 2026-11-11: their clean full builds ran 1162-1590 s beside the unit
  shards and outran the 1200 s budget on 11-09 and 11-11). A night with a
  new Xcode build has no slim cache yet, so its timing repeats still build
  clean, now without the Watch app and extensions; the nightly UI jobs never
  restore one.
- **Packages from the restored checkout.** When the restored DerivedData
  holds the WebRTC checkout (the only package), the build passes
  `-skipPackageUpdates` and resolves from it instead of the network. A new
  pinned version fails that build, and the clean retry resolves it from the
  network.
- **A generic build destination, built after the boot.** With nothing to
  compile, the first incremental builds still took 139-340 s: 4-64 s finding
  the pinned device, then 116-213 s with no output around "Resolve Package
  Graph", with or without `-skipPackageUpdates`. The silence ended 30-75 s
  after the simulator booting alongside was ready: with that device as its
  destination, xcodebuild waited for it. Hosted jobs now build for
  `generic/platform=iOS Simulator` (`BUILD_DESTINATION`, set by
  `ci-hosted-build.sh`), which needs no device; the products and `.xctestrun`
  are the same, and the tests still run on the booted device. Building during
  the boot was tried in #629 and starved it on the 3-core runners: 2 of 3
  boots missed their 200 s readiness budget, and the tests then waited 4-7
  minutes for the device. Even a `-resolvePackageDependencies` call alone
  during the boot sat at "Resolve Package Graph" until 43-73 s after the boot
  ended (2 of 3 jobs). So `ci-build-for-testing.sh` calls xcodebuild only once
  the preparation has ended (`BUILD_AFTER`): a separate, timed package
  resolution, then the build.
- **No whole-module Swift.** Tried in #629: the 3-core hosted runners built
  the full app in 20.5 minutes against 11-16 before, because the app is one
  large module type-checked on one core.
- **No hand-written `==`.** What an incremental build recompiles depends
  on the change, and one kind cost a near-full rebuild: adding any member,
  stored or computed, to a type with a hand-written `static func ==`
  recompiled 718 of the app's 766 files (measured on a Mac with CI's build
  command, Xcode 27.2, 2026-11-17), as almost every file uses `==` and Swift
  resolves the operator across all of them. With a synthesized `==` the
  same change recompiled 3 (`TranscriptCellEnvironment`) to 46 files, 217
  for `BackgroundChat`, a new AppState property about 280, a body edit 1. One such change (#2665, `ConversationAgentIdentity`)
  sent the next PRs' Smoke builds to 1,500 s of compile from main's cache.
  So types let Swift synthesize `==` and wrap a field that compares another
  way in `Conduit/Services/EquatableWrappers.swift`'s `@EqualityIgnored`,
  `@IdentityEquatable` or `@OptionalIdentityEquatable` (that file stays in
  `Conduit/Services`: the same file in `Conduit/Models` brought the 719-file
  rebuilds back for every type using a wrapper, for reasons the build log
  doesn't show);
  `check-hand-written-equality.py` fails a new hand-written `==` and lists
  the files that still hold one. Two more full rebuilds are known and left:
  a removed or renamed Swift file turns incremental compilation off for its
  target ("inputs were used in the previous compilation but not in this
  one"), and any change to the app's interface recompiles every test file,
  since they `@testable import Conduit`.

Each build posts two notices on its job: the slowest build phases from
`-showBuildTimingSummary` (with the cache it restored, how many Swift files
each target compiled (`ci-build-compiled-counts.py`), and the seconds spent on the destination, waiting for the simulator and the packages before the
build), and the longest
stretches where the build log stopped growing, with the lines around each
(`ci-build-quiet-stretches.py`). The second shows time the first cannot:
package resolution, build planning, waiting on the simulator service. A
build that fails posts its first source errors (up to 8) as annotations,
which the API serves when the job log can't be read: the log is fetched
from storage some networks can't reach.

The smoke job then runs its test steps on the one build and booted
simulator. **Unit smoke** runs the pinned unit tests as one
`test-without-building` invocation with no retry of a test (an invocation
that lost its simulator runtime before any test ran gets one more attempt
after a reboot, `scripts/ci-recover-lost-runtime.sh`); a failure posts xcodebuild's
list of failing tests and the first error lines as an annotation, and the
invocation posts how long it took and how much of that ran tests. **UI smoke**
runs the pinned UI tests as one invocation with one targeted retry (see
[What the hosted gate deliberately does NOT do](#what-the-hosted-gate-deliberately-does-not-do)).
**UI smoke** runs on pushes only. There the UI step runs even when the unit
step failed, so a run always reports both; only a failed build or a cancelled
run skips it, and the job fails if either step failed.

#### UI smoke after the merge

From 2026-11-02 (Eric) a PR's Smoke runs no UI tests. They took 3-5 of a PR
run's 18-22 minutes and were its flakiest step, while the two reviews took
9-14. A PR still builds every UI test (a test that no longer compiles fails
it), and the unit tests run inside the app, so a PR that breaks its launch
still fails. A UI regression shows up in `main`'s run after the merge, or that
night, and whoever merged it fixes `main` forward, as for any unit test
outside the smoke set. The same change started the smoke job beside the Linux
checks instead of after them: `plan` holds only the smoke selection and the
skip decision (about 20 seconds), and the checks moved to `self-test`.

A push skips the smoke job as a PR does when it changes only docs and config
(Markdown outside the app and test folders, docs/, LICENSE, review config,
`.github/` other than ci.yml), read against the branch's tip before it. Only a
one-commit push (main's squash merges, a merge commit into `linked-rooms` or
`all-live`) is read that way; a push of several commits or a new branch builds.
Nothing such a commit changes reaches the build or the smoke tests, and on
2026-11-15 each feature-map merge to `main` still held a macOS runner for
about half an hour (with UI smoke) while PRs queued behind it.

Nightly unit shards run their classes as sequential `test-without-building`
batches on the one booted simulator: the fewest batches of at most
`UNIT_BATCH_SIZE` (45) classes, split evenly, so a shard of about 78 classes
runs as two batches of about 39. A failing batch does not stop the shard:
every batch runs, and the job fails at the end listing the failed batches.
Each failed batch also posts its failing cases as an annotation, since the
job log API returns only a job's last 5,000 lines and a large first batch's
failures fall outside them. Every batch also posts how long it took and how
much of that ran tests: on a freshly booted simulator, the first batch spent
154 s outside its tests and the second 20 s (#629).
`-test-timeouts-enabled YES` with a 180s allowance (unit smoke and the unit
shards alike) kills a hung test instead of letting it burn the job ceiling.
UI smoke uses a 480s allowance (`UI_TEST_ALLOWANCE_S`; the slowest passing
hosted UI test took 246s), so a hung launch or idle-wait stall ends and the
targeted retry still runs inside the job timeout.

Why 45 and not 7: the 7-class cap came from hosted stalls in PRs #178-#183.
Since then the hosted hangs we have traced were test bugs, for example the
scene-phase fixtures fixed in #272/#273 and the dropped fake-socket frames
fixed in #274. Every invocation has a fixed hosted cost, so fewer, larger
batches are what make the full suite affordable: measured 2026-10-15
(#629), an invocation spends 40-60 s before its first test, and the first one
on a fresh simulator about 100 s. With a cap of 35 each shard ran a third
batch of 7-9 classes, one of them 39 s for 0.8 s of tests. If a stall
reappears, lower `UNIT_BATCH_SIZE` in `nightly.yml` and root-cause the test.

### Budget

The repository is public, so standard hosted runners cost nothing, but GitHub
allows **5 concurrent macOS jobs** per account, and in CI v4 waiting for one
was the main bottleneck. A PR run now uses **1** (`smoke`), and
a PR's newer run cancels its superseded ones, which leaves room for the
next push. For a PR from this repository, the newer run's plan job cancels
them (Cancel this PR's older runs), and each run has a concurrency group of
its own, so the new run starts at once instead of waiting the 3.5 minutes a
cancelled Smoke job takes to wind down (2026-11-02). It cancels only runs
whose one PR is this one (number and base), so a branch with PRs into both
`main` and `linked-rooms` (or `all-live`) never cancels the other PR's run. A fork PR, whose
token can't cancel runs, keeps one group per PR with `cancel-in-progress`.
Pushes to a branch share one concurrency group without cancelling (Eric,
2026-11-15): the run under way finishes, the newest push waits, and GitHub
cancels a waiting push's run when a newer push arrives, so main has at most
one run going and one waiting. A docs-only push after a cancelled one builds
anyway (see CI Gate), so a merge whose run was cancelled is always built by the
next run. The change's own unit classes come from the newest commit only; a
cancelled merge's classes ran on its PR before it merged. Branch protection does not require PRs to be up
to date with main, and main's run is what catches two PRs that are green alone
but break together (within the smoke set; the nightly run catches the rest);
the waiting run holds every merge since the last one, so a break shows there,
named by a range of merges rather than one. Whoever merged the breaking PR
fixes main forward. Before, every merge got its own run: on 2026-11-14 twenty
merges in five hours held up to 6 of the 5 macOS runners, main's Smoke jobs
queued 83-86 minutes with PRs behind them, and the build cache PRs restore fell
14 merges behind. So up to five PR or push runs can run side by side before
anything queues, and main takes at most one of them. "Require branches to be up to date
before merging" is a repository setting (Settings > Branches > main) that this
workflow assumes is off; if it is turned back on, PRs must update again. Grow
the smoke set or add a macOS job to ci.yml only with that ceiling in mind.
Pushes to `linked-rooms` and `all-live` run the same way, in that branch's
copy of the workflow. `all-live` holds the all-live rework (several chats
and Hermes instances live at once) until Eric has tested each stage; its
TestFlight builds are archived from that branch, see
[RELEASE_WORKFLOW.md](RELEASE_WORKFLOW.md#builds-from-a-long-lived-branch).

A nightly run schedules 8 macOS jobs (2 unit shards + 3 timing repeats + 3 UI
shards), so three of them queue behind the ceiling, and a nightly that
overlaps a PR run slows both. That is accepted: nightly results are not
time-critical. Each extra `unit_shards` or `nightly_ui_shards` shard adds one
more build and one more queued job.

They must not be in the day's way, though. GitHub created Nightly's cron
events 7 to 10 hours late (2026-11-09..14: 15:07-18:50 UTC for a 08:17 UTC
cron), so the run held the macOS runners through Eric's mornings and his PRs'
Smoke jobs queued behind it. Nightly is now dispatched at 3:17 AM ET by a
systemd timer on the Hermes host, with `nightly: true`, which titles the run
"Nightly (overnight)" ([scripts/nightly-timer/](../scripts/nightly-timer/README.md)).
The cron moved to 09:47 UTC, after the timer in EDT and EST alike, as a
backup: its plan job skips the run when a dispatched Nightly ran on `main` in
the last 20 hours (cron runs don't count, so yesterday's skipped backup can't
hide a missed timer), and otherwise runs with a warning: that no dispatch
reached GitHub (the timer's journal shows a refused or failed dispatch, such
as an expired token; no entry for 03:17 means the service never started, so
check that the host was up and `systemctl list-timers conduit-nightly.timer`),
or, when the run lookup itself fails,
that it's unknown whether the timer ran.

When macOS arm64 capacity runs short, GitHub gives up on a queued job after
about 40 minutes: it ends `cancelled` with no runner and no steps ("The job was
not acquired by Runner of type hosted even after multiple attempts"). Nightly
lost 2 jobs that way on 2026-10-28 and 3 on 2026-10-29. `nightly-rerun.yml`
reruns a nightly run's failed jobs (the cron's or the timer's), up to twice, but only when every failed job
is one of these; those jobs never ran a test, so the rerun hides no flake.

## Hosted gate architecture

The CI v5 shape of `.github/workflows/ci.yml` (every PR, and every push to
`main`, `linked-rooms` or `all-live`):

```
        source scan (inventory)                     validate & self-test (ubuntu)
                 |                                   inventory, localization,
   scripts/smoke-suite.json                          feature map, plugin version,
   (validated against the inventory)                 the nightly partition
                 |                                   (plan-tests.py hosted) and
   plan-tests.py smoke  -> unit-csv / ui-csv         the CI-tooling suites - runs
   does the change need the build -> smoke           concurrently, never delays
                 |                                   the build
                 v
   smoke (ONE macOS job)
     restore the PR's own last build, else main's (or its base branch's)
     build-for-testing  ||  simulator boot      (ci-hosted-build.sh)
     check-weak-imports; save the full build cache
     unit smoke: 70 pinned tests, ONE invocation, no test retry (a lost runtime: once more)
     UI smoke:   pushes only: 4 pinned tests, ONE invocation, one
                 targeted retry (runs even if unit smoke failed)
                 |
                 v
          ci-gate  ->  "CI Gate" (the single required status check)
```

`.github/workflows/nightly.yml` runs its own plan job (`plan-tests.py hosted`)
and fans out into `unit` (one job per unit shard, sequential batches; shard 1
saves the slim build cache on `main`), `timing` (three repeats of the
nightly-only families, on the slim build and cache) and `ui` (one job per UI shard).

### Jobs

| Job | Runner | Purpose |
|---|---|---|
| `plan` | ubuntu | Only what `smoke` needs to start: the **smoke selection** (`plan-tests.py smoke`: `unit-csv`, `ui-csv`) and whether the PR or push needs the smoke job at all (`smoke`, below). About 20 seconds, so the macOS job starts almost at once. |
| `self-test` (`Validate & self-test`) | ubuntu | Inventory/planner validation (`plan-tests.py validate`), localization coverage, the recommended plugin version, the feature map's paths and entry shape and, on a PR, that each entry it adds or edits names the PR on its Checked line (`check-feature-map.py`, given the base's map from `HEAD^1` and, on a PR into `linked-rooms` or `all-live` that merges main, main's maps where the PR and its base meet main, so the entries a merge of main brings in keep main's Checked lines (if GitHub can't say whether the PR merges main or give those maps, it warns and checks without them, so those entries fail as the PR's edits until a re-run); its notifier/ paths are looked up on the plugin's main, so a file removed there turns every PR red until the map follows, and a GitHub outage during that lookup only warns), the **nightly partition** check (`plan-tests.py hosted`) and the CI-tooling regression suites (planner tests, destination lookup, gate/contract tests, the bash wrapper tests included), concurrent with `smoke`. |
| `smoke` (`Smoke`) | xcode-27 | The only macOS job: restores the PR's own last build, else main's build cache (on a PR into `linked-rooms` or `all-live`, that branch's when it has one), builds the app and every test target once while the simulator boots (the compile gate), then runs the pinned unit tests (one invocation, no test retried; an invocation that lost its simulator runtime before any test ran runs once more after a reboot, `scripts/ci-recover-lost-runtime.sh`) and, on a push, the pinned UI tests (one invocation, one targeted retry) on that build. Saves the full build cache after the build and its weak-imports check and before the tests: a push's for later PRs, a PR's for its own next push. |
| `ci-gate` | ubuntu | The single stable branch-protection verdict (`CI Gate`), aggregating `plan`, `smoke` and `self-test` via `scripts/ci-gate.py`. |

The self-test job's timeout layering holds: each synthetic hang in the suites
is watchdog-killed within a 1–6 s test budget, far under the job's 10-minute
ceiling, so GitHub is never the first layer to kill a regression suite.

Every hosted macOS job uses `scripts/ci-prepare-smoke.sh`, a hosted-only wrapper around
`ci-lib.sh`'s bounded operations. It attempts to disable automatic clipboard
sync before boot, warning and continuing if the preference cannot be written.
It waits for the destination inventory, retains the selected `SIMULATOR_UDID`,
and uses that ID for shutdown, boot, boot readiness and the test destination.
This avoids re-resolving an already-selected device by an ambiguous name across
multiple installed runtimes. Destination settlement remains fatal when no
device appears; shutdown and boot remain best-effort, with the existing 60s
command and 200s readiness budgets. Unresolvable IDs retain the existing
name-based destination fallback. No device erase or additional retry is added.
The shared library has an optional
`SIMULATOR_INVENTORY_CACHE` diagnostic sink, enabled only by hosted preparation:
successful live device lookups retain their inventory without affecting which
device is selected. Cache-write failures warn and preserve the lookup result.

`ci-lane/destination/preparation.json` and the job summary report device ID,
runtime, boot confirmation, and separate lookup, shutdown, boot and readiness
seconds. The existing three-second settling delay is additional. Runtime
reporting reuses that retained pre-boot inventory; it never adds a post-boot
`simctl list` probe. Each preparation gets a fresh diagnostic file so an existing
UDID pin cannot reuse stale metadata. Missing diagnostics report runtime unknown.
Summary/report failures warn and continue; exporting the destination to the next
step remains required. Reporting is outside those phase measurements.

`scripts/ci-self-test.py` runs full unittest discovery of `scripts/tests/`. It
removes the wrapper-skip flag (`CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS`, for local runs) first, so nothing is skipped there,
and fails on discovery/import errors, on an empty discovery, or on a failing
test.

### The smoke selection

`scripts/smoke-suite.json` is the checked-in selection the `smoke` job runs on
every PR (its unit tests) and every push to `main`, `linked-rooms` or `all-live` (CI v5) that
builds, and
`plan-tests.py smoke` validates it
against the discovered inventory on every run:

* a class that is **renamed, deleted or moved between targets fails the plan
  job** — hosted coverage can never silently shrink;
* duplicates fail;
* the run summary states the split (selected vs left to the nightly run) so
  it is visible which coverage came from where.

Selection policy — a few pinned tests from one class per risk area (ten
each for the unit areas, two per UI class), chosen for fast deterministic
signal:

| Risk area | Smoke coverage (tests pinned from) |
|---|---|
| app/session lifecycle | `AppStateForegroundLifecycleTests` |
| profile/store/session restoration | `ProfileDiscoveryTests` |
| Bot Mode isolation | `BotModeTests` |
| connection/protocol | `HermesClientTests` |
| settings/persistence | `ComposerDraftStoreTests` |
| transcript/Markdown correctness | `MarkdownLargeDocumentTests` |
| notifications/push routing | `NotificationDashboardOwnershipTests` |
| basic UI launch/navigation | `ConnectionSetupUITests`, `ProfilePickerUITests` |

**Pinned tests under a cap, and that is the design.** Until 2026-10-29 the
list named whole classes, so every test added to one of them joined every
PR's run: from 2026-10-18 to 10-29 the seven unit classes went from about 500
tests to 680 and unit smoke from 195 s to 240 s with the list unchanged, and
the 8 UI tests took about 460 s, 150 s of it one setup walk. Pinned tests
(4 UI, about 180 s) grow only when someone edits the list, and
`max_unit_tests` and `max_ui_tests` make that a deliberate change: replace a
test rather than add one, and raise a cap only with the reason in the PR.
Every
`test-without-building` invocation has a fixed hosted cost (40-100 s before
its first test, measured 2026-10-15), and the merge gate's job is a fast
verdict on a shared, queue-limited runner pool. The pinned unit tests are one
invocation. Growing the set adds wall clock to every PR without adding
coverage the nightly run lacks: it is the exhaustive authority, and the smoke
job only has to answer "does it build, and is anything obviously broken?".
(The CI v3 numbers behind the original sizing, from 2026-09-23: the whole
137-class unit suite was 13.9 minutes of *test* time on a hosted runner, while
one invocation then cost ~12 minutes of xcodebuild + simulator + test-host
overhead.)

**Left to the nightly run** (deliberately NOT in the smoke set): every other
unit class, in the nightly unit shards, and every other UI class, in the
nightly UI shards (154 unit + 6 UI classes on 2026-10-18). In particular the
timing/performance/dormancy families — `TranscriptPerformanceFixtureTests`,
`TranscriptPerfLedgerContractTests`, `LongContextScalingFixtureTests`,
`SettledMessageIsolationTests`, `MarkdownRichContentHostedTests`
(`nightly_only_unit` in `scripts/hosted-suite.json`) — run there with three
repeats. Those suites measure scheduling and rendering behaviour; running
them on every PR's shared runner produced flakes that cost more than they
caught. `SmokeSelectionTests` asserts they never enter the smoke set, and
`HostedSelectionTests` that every smoke class also runs in a nightly shard.

### What the hosted gate deliberately does NOT do

* **No dynamic lane fanout.** The PR gate is ONE job with one invocation per
  target, and the nightly shards are a fixed count from
  `scripts/hosted-suite.json`; lane balancing buys nothing at this size and
  made job count unpredictable.
* **No Xcode-native flake retry** (`-test-iterations` / `-retry-tests-on-failure`).
  A genuine assertion failure must fail the run — never be re-run until it
  agrees. (Contract-tested in `WorkflowContractTests`.) The one exception is the
  UI smoke job, which applies one rule for a failing UI batch:
  **one** targeted retry of the failed selected classes, with the original
  failure and retry scope reported, and a class that fails twice failing the job.
  Each invocation writes a separate result bundle. `smoke-retry-classes.py`
  uses the existing result extractor's normalizer, with a hosted-only 30s read
  deadline. Narrowing requires results for every selected class, recognized
  passed/failed states, and consistent failure attribution. Missing, incomplete,
  synthetic, unknown, skipped or unreadable evidence retains the whole selection.
  The initial extraction and fallback reason are retained in `ui-retry.json`;
  it cannot turn an empty result into an unfiltered test invocation.
  UI tests are the only part of the hosted gate with a measured flake rate on
  shared runners (over three runs of the introducing PR, two different UI tests
  failed — a photo picker that did not appear inside its 15 s wait, a wizard step
  that never advanced — and one run was green with nothing changed in between),
  and the unit classes are deterministic, so the retry exists there and nowhere
  else. A red UI run costs one extra invocation, but no longer repeats classes
  already known to have passed when attribution is reliable. Compact initial
  logs, retry evidence and preparation timings are uploaded as UI diagnostics;
  large result bundles are not uploaded on the normal path.
* **No timing history.** The EWMA cache + `update-timing-history.py` and the
  main-only job that wrote it are gone; nothing produces the planner's
  `--history` input any more.
* **No watchdogs or recovery plumbing.** A wedged hosted runner fails the job
  and is re-run by a human, deliberately. The one exception: a test invocation
  whose simulator runtime was lost before any test ran reboots the device and
  runs once more (`scripts/ci-recover-lost-runtime.sh`, the Nightly reruns
  entry in docs/FEATURE_MAP.md).

### Cost

CI v5: one macOS job per PR run or push run, none for a docs-only one (one build, one boot, and the
unit invocation; a push adds the UI invocation and its retry when needed), against CI v4's three (each with
its own build and boot, ~18 minutes of wall clock per run). The full unit
suite's macOS minutes moved to the nightly run, which spends them once a day
instead of on every push.

The history below is CI v2 and v3.

Measured on the last full v2 run of main (18 jobs): **129.2 macOS minutes** per
run, wall clock ~20–21 minutes, longest job 18.8 min. The original v3 shape was 6 jobs:
`plan` + `self-test` + `ci-gate` on Linux (the same work as before), and three
macOS jobs — the unchanged compile-everything `build`, plus one `unit-smoke`
and one `ui-smoke` job.

Measured on the v3 shape itself (runs on 2026-09-23, PR #203): plan 1m44s,
self-test 9m52s, build 2m44s, `ui-smoke` **15m03s green** (5m of device
settle/boot + one invocation), `unit-smoke` ~17m once the curated set was sized
to one invocation. That is roughly **35 macOS minutes** against 129.2 — a ~3.7×
cut — plus a much smaller flake surface: no lane matrix, no timing families, no
retries. Two overshoots on the way there are recorded in the PR: a 32-class
selection that spent ~25 minutes of wall clock on 2.9 minutes of tests, and a
14-class one that still exceeded the job ceiling because it paid for two
invocations.

macOS minutes are the smaller part of the win: the point is that the hosted
verdict no longer depends on shared runners re-litigating timing-sensitive
suites.

## Test discovery


`scripts/plan-tests.py` discovers XCTestCase classes by scanning
`ConduitTests/` and `ConduitUITests/` sources:

* A class is a **test class** if it directly inherits `XCTestCase` (repo
  convention) or is named `*Tests` and inherits `XCTestCase` transitively.
  This matches the XCTest runtime inventory exactly (verified against
  `xcodebuild -enumerate-tests`; at the time the smoke split landed the
  inventory stood at 137 unit + 7 UI classes).
* Classes that merely resolve to `XCTestCase` without the above (mocks such
  as `MockGateway`, `FakeSocket`) enumerate zero tests and are excluded from
  lanes - the same behavior as the old static shard guard.
* Target membership comes from the **directory** (`ConduitTests/` vs
  `ConduitUITests/`), never from the class name.
* Duplicates, and `*Tests`-named classes that do not resolve to
  `XCTestCase`, are hard errors. A new test class can never silently miss CI.

## Timing data

* `scripts/test-timings.json` - checked-in **baseline** (seconds per class).
  Smoke charges each changed unit class its time against `changed_budget_s`
  (a class missing from it is charged 3 s), and the nightly planner splits
  the unit shards with it. The unit classes come from a green nightly's two
  unit shards on the hosted runners: `scripts/refresh-test-timings.py
  --baseline scripts/test-timings.json <shard logs>` reads each class's
  `Test Suite ... passed|failed` and `Executed ... (S) seconds` lines and
  replaces the classes it measured, keeping the rest (UI classes, the
  nightly-only timing families). Rerun it when classes are added or grow:
  the August seed had drifted until half the unit classes had no entry and
  app-code PRs ran 4-6 minutes of changed classes against the 120 s budget
  (refreshed 2026-11-17). Unseen classes get a conservative default (20 s)
  in lane planning so a batch of new tests cannot all pile into one lane.
* **Timing history** - there is none any more. The `timing-history-v1-*`
  Actions cache and the main-only job that wrote it were removed in CI v3: they
  existed to rebalance the hosted lane matrix, which no longer exists.
  Nothing produces `plan-tests.py`'s `--history` input now; estimates come
  from the checked-in baseline (or the planner default) and planning
  correctness never depended on either.

## Destination readiness gate

Hosted test jobs skip this gate for the build, which targets a generic
simulator (see "What gets compiled"); their preparation step still waits for
the pinned device before the tests run. The gate applies when
`ci-build-for-testing.sh` runs without `BUILD_DESTINATION`.

The build job pins one known simulator name (`SIMULATOR_NAME`, no `simctl`
enumeration on the happy path). Fresh hosted runners occasionally reach the
build step before CoreSimulator has settled its device pairs; xcodebuild then
fails destination resolution with an **empty** available-destinations list
("Unable to find a device matching the provided destination specifier") and
every downstream lane is skipped. Before invoking xcodebuild,
`ci-build-for-testing.sh` now runs `wait_for_destination_device`
(`ci-lib.sh`): a bounded poll (default 180 s, `DESTINATION_SETTLE_TIMEOUT_S`,
read as base 10 and clamped to one day)
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

The resolved UDID is also what every invocation actually targets:
`build_destination` emits `platform=iOS Simulator,id=<UDID>,arch=arm64`
(falling back to the `name=` form only when the UDID cannot be resolved; the
arch is `SIMULATOR_ARCH`-overridable), so build and lane jobs can never
disambiguate a name that matches several runtimes and never have to choose
between the arm64 and Rosetta-x86_64 candidates every Apple Silicon
simulator registers - the source of the "multiple matching destinations"
warning, where xcodebuild silently uses the first match and can bypass the
OS pin.

## CI Gate (branch protection)

The `CI Gate` job is the single stable required status check for branch
protection. It passes only when:

* `plan`, `smoke` and `self-test` all succeed (CI v5). `smoke` fails when
  its build, its unit smoke step or (on a push) its UI smoke step failed. The one
  legitimate skip is the plan job's: its `smoke` output is `false` on a PR
  or push that doesn't need the macOS build, and the gate passes a skipped `smoke`
  only then. Otherwise `plan-tests.py smoke` fails closed on an empty curated
  selection and both smoke test steps refuse to run unfiltered, so a
  `skipped` job means an upstream failure cascade — which fails the gate.

A PR doesn't need the smoke job when it changes only what the build and the
smoke tests never read (Markdown, `docs/`, `LICENSE`, `opencode.json`,
`.coderabbit.yaml`, `.github/` other than `ci.yml`; a file under `Conduit*/` or
`Shared/` always builds, and a rename counts by both names), or when its change is the
same as at an earlier commit of it whose smoke job passed:
`scripts/pr-change-id.py` hashes the PR's diff from its base without hunk
headers or blob ids, and its Markdown by the words the PR adds and removes, so
merging main or resolving a feature map conflict keeps it. That merge commit
is then never built on the PR, which is the ruling for any merge of main
that keeps the change id, not only a feature map conflict (Eric, 2026-10-29,
#1467: the same exposure as a PR that never merged main); main's own run after
the merge still builds, and catches two PRs that break together, as it does
for any PR that wasn't up to date. The review plan in
`opencode-review.yml` hashes the same way with an inline copy of the script,
and `scripts/tests/test_pr_change_id.py` holds the two to the same ids. A
passing Smoke counts whatever PR it ran for (GitHub can't say which PR a run
belonged to), so a commit that passed in a PR into `linked-rooms` or `all-live`
counts for a PR into `main` from the same branch; Markdown under an app or
test folder always builds, since the id counts Markdown only by its words.
A push builds unless it is one commit (main's squash merge, or a merge commit
into `linked-rooms` or `all-live`) of only docs and config, read against the
branch's tip before it, and that tip's own push run passed: a push whose run
GitHub cancelled while it waited (see Budget) was never built, so the next
push builds even if it is docs. The same-change skip is for PRs only, and every
lookup that fails builds.

Branch protection must require **CI Gate** (and nothing else from this
workflow): the jobs behind it are implementation detail, and any job that can
be renamed or split must never be pinned individually — CI v5 removed the
`unit` shard and `ui-smoke` jobs without touching branch protection. The
verdict is produced by `scripts/ci-gate.py`, whose policy is contract-tested.

The gate covers the PR shape only. The nightly workflow (full unit suite,
timing repeats, complete UI suite) never gates a merge; it reports on `main`
every night, and a release is validated by dispatching it on the release ref.

Each run ends with a smoke-selection summary (selected classes per target and
the count left to the nightly run) so the coverage split is visible on the
run page. When the smoke job fails, its annotations and log name the class
and method; there is no retry layer that could turn a genuine unit assertion
into a green run.

## Adding a test

Just add it. The nightly run picks it up through `plan-tests.py hosted`, which
puts every discovered class in a nightly shard — no shard-assignment files to
maintain. Before pushing:

```
python3 scripts/plan-tests.py validate
python3 scripts/plan-tests.py smoke
python3 -m unittest discover -s scripts/tests
```

`validate` checks inventory completeness; `smoke` is the command that actually
reads `scripts/smoke-suite.json`, so it is the one that catches a pinned test
whose class or method was renamed, deleted or moved between targets, or a list
over its cap — the same check the hosted
plan job runs (`validate` runs in the self-test job).

**Hosted smoke coverage is a decision, not a default.** A new test runs on
GitHub before merge only if its class is part of the change (the change's own
classes) or it is pinned in `scripts/smoke-suite.json`; the smoke gate does
not grow with the suite, which is what keeps it cheap (see
[The smoke selection](#the-smoke-selection)). Pin a test when it covers a
risk area the smoke set does not already cover, and swap one out to stay
under the cap. A name in the file that no longer exists fails the plan job, so the
selection cannot silently decay; the timing/performance/dormancy families must
stay out (a contract test enforces that).

**New timing/performance/dormancy class?** Add it to `nightly_only_unit` in
`scripts/hosted-suite.json`, so it runs in the nightly timing job's three
repeats rather than in a unit shard, and stays out of the smoke set.

## Local run directories

The CI workspace uses `ci-derived-data/`, `ci-lane/` and `ci-artifacts/` (all
gitignored); the same paths work for local rehearsal of the scripts.
