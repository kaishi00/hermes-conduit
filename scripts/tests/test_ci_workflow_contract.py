"""Contract tests: the hosted workflow must invoke the tooling CLIs correctly.

These tests pin the workflow/script interface so it cannot silently diverge
again (e.g. passing observation files positionally when the script requires
--observations).

CI v5 shape (docs/CI.md): GitHub-hosted CI is the merge gate, and it is light.
A PR or a push runs the cheap Linux validation and ONE macOS `smoke` job
that compiles the full app (incrementally from main's latest build) and every
test target once, then runs the pinned unit smoke tests and the pinned UI
smoke tests (scripts/smoke-suite.json) on that build and simulator.
nightly.yml runs every other unit class in balanced shards
(scripts/hosted-suite.json), the timing families with repeats and the complete
UI suite. There is NO lane matrix, NO timing-history job and NO native flake
retry that would re-run a genuine assertion until it agrees.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

from _util import SCRIPTS_DIR

REPO_ROOT = os.path.dirname(SCRIPTS_DIR)
WORKFLOW = os.path.join(REPO_ROOT, ".github", "workflows", "ci.yml")
NIGHTLY = os.path.join(REPO_ROOT, ".github", "workflows", "nightly.yml")
SCREENSHOTS = os.path.join(REPO_ROOT, ".github", "workflows", "app-store-screenshots.yml")
SMOKE_SUITE = os.path.join(SCRIPTS_DIR, "smoke-suite.json")

CACHE_PATH = ("          path: |\n"
              "            ci-derived-data\n"
              "            !ci-derived-data/Logs\n")


def _read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _job_text(path, job_key):
    """Extract one job's text block (stdlib-only YAML slicing). Job keys sit
    at exactly two spaces of indentation; their bodies are deeper."""
    lines = _read(path).splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith("  ") and line.strip() == "{0}:".format(job_key):
            start = i
            break
    if start is None:
        raise AssertionError("job {0!r} not found in {1}".format(
            job_key, os.path.basename(path)))
    out = [lines[start]]
    for line in lines[start + 1:]:
        if line.startswith("  ") and line[2:3] not in ("", " ", "\t"):
            break  # next sibling job key
        out.append(line)
    return "\n".join(out)


def _step_text(job_text, step_name):
    """One step's text block inside a job block: from its `- name:` line to
    the next step."""
    lines = job_text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip() == "- name: " + step_name:
            start = i
            break
    if start is None:
        raise AssertionError("step {0!r} not found".format(step_name))
    indent = len(lines[start]) - len(lines[start].lstrip(" "))
    out = [lines[start]]
    for line in lines[start + 1:]:
        if line.strip() and len(line) - len(line.lstrip(" ")) <= indent:
            break
        out.append(line)
    return "\n".join(out)


def _job_keys(path):
    """The workflow's job keys, in file order."""
    lines = _read(path).splitlines()
    start = lines.index("jobs:")
    return [line.strip()[:-1] for line in lines[start + 1:]
            if re.match(r"^  [A-Za-z0-9_-]+:$", line)]


def _assert_cache_round_trip(tc, text, saver, label):
    """A job restores the newest DerivedData it can reach before building and
    saves its own after the tests, never a PR's and only after a successful
    build, with the same path list (a different list is a different cache)."""
    tc.assertIn("uses: actions/cache/restore@v5", text, label)
    tc.assertIn("uses: actions/cache/save@v5", text, label)
    tc.assertEqual(2, text.count(CACHE_PATH), label)
    tc.assertLess(text.index("actions/cache/restore@v5"),
                  text.index("bash scripts/ci-hosted-build.sh"), label)
    tc.assertLess(text.index("bash scripts/ci-hosted-build.sh"),
                  text.index("actions/cache/save@v5"), label)
    tc.assertIn("id: build", text, label)
    tc.assertIn("steps.build.outcome == 'success'", text, label)
    tc.assertIn("steps.cache.outputs.cache-hit != 'true'", text, label)
    tc.assertNotIn("head_ref", text, f"{label}: a PR's build must never be saved")
    tc.assertIn(saver, text, label)
    tc.assertIn("dd-v1-$kind-$xcode-${ImageVersion:-image}", text, label)
    # The key still names the image, and the image-specific prefix is tried
    # before the any-image one.
    tc.assertIn("key: ${{ steps.cache-key.outputs.prefix }}-${{ github.sha }}", text, label)
    tc.assertIn("restore-keys: |\n"
                "            ${{ steps.cache-key.outputs.prefix }}-\n"
                "            ${{ steps.cache-key.outputs.xcode-prefix }}-\n", text, label)


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        if not os.path.exists(WORKFLOW):
            self.skipTest("ci.yml not present")

    def _workflow_text(self):
        return _read(WORKFLOW)

    def _job_text(self, job_key):
        return _job_text(WORKFLOW, job_key)

    def test_ci_gate_job_present_and_required_shape(self):
        text = self._workflow_text()
        self.assertIn("CI Gate", text)
        self.assertNotIn("Build & Test", text)

    def test_one_macos_job_per_run(self):
        """Runner queueing (5 concurrent macOS jobs per account) was CI v4's
        bottleneck: a PR or push run gets exactly one macOS job."""
        jobs = _job_keys(WORKFLOW)
        self.assertEqual(jobs, ["plan", "self-test", "smoke", "ci-gate"], jobs)
        self.assertEqual(self._workflow_text().count("runs-on: macos-"), 1)
        self.assertIn("runs-on: macos-26", self._job_text("smoke"))
        self.assertNotIn("matrix", self._job_text("smoke"),
                         "the smoke job must not fan out into several macOS jobs")
        self.assertNotIn("unit-shards", self._workflow_text(),
                         "the unit shards run in nightly.yml, not on every PR")

    # --- the plan job owns every test-to-run mapping -----------------------

    def test_plan_job_selects_the_smoke_suite_and_nothing_else(self):
        """Smoke waits only for what it needs: the plan job holds the smoke
        selection and the skip decision, and the Linux checks run in the
        self-test job beside the build (Eric, 2026-11-02)."""
        plan = self._job_text("plan")
        self.assertIn("plan-tests.py smoke", plan,
                      "the plan job owns the smoke selection")
        self.assertIn("--suite scripts/smoke-suite.json", plan)
        self.assertIn("unit-csv: \"${{ steps.smoke.outputs.unit-csv }}\"", plan)
        self.assertIn("ui-csv: \"${{ steps.smoke.outputs.ui-csv }}\"", plan)
        self.assertIn("echo \"unit-csv=$(jq -r '.unit_csv' ci-artifacts/smoke.json)\"", plan)
        self.assertIn("echo \"ui-csv=$(jq -r '.ui_csv' ci-artifacts/smoke.json)\"", plan)
        self.assertIn("smoke-summary.py", plan)
        for check in ("plan-tests.py validate", "plan-tests.py hosted", "check-l10n-coverage.py",
                      "check-plugin-version.py", "check-feature-map.py", "unittest discover"):
            self.assertNotIn(check, plan, f"{check} runs beside the build, not before it")

    def test_self_test_job_runs_the_linux_checks_beside_the_build(self):
        checks = self._job_text("self-test")
        self.assertNotIn("needs:", checks, "the checks never delay the build")
        # A renamed nightly-only class, or a class in no list, must fail the
        # PR that caused it, not the next night.
        self.assertIn("plan-tests.py hosted", checks)
        self.assertIn("--suite scripts/hosted-suite.json", checks)
        self.assertIn("plan-tests.py validate", checks)
        self.assertIn("check-l10n-coverage.py", checks)
        self.assertIn("check-fixed-text-sizes.py", checks)
        self.assertIn("check-transcript-environment.py", checks)
        self.assertIn("check-plugin-version.py", checks)
        self.assertIn("check-card-schema.py", checks)
        self.assertIn("check-feature-map.py", checks)
        # The feature map check reads the base's map at HEAD^1.
        self.assertIn("fetch-depth: 2", checks)

    def test_the_smoke_skip_builds_for_anything_the_app_or_ci_reads(self):
        step = _step_text(self._job_text("plan"), "Does the change need the macOS build")
        self.assertIn("git -c core.quotePath=false diff --no-renames --name-only HEAD^1 HEAD", step,
                      "a rename must count by both names")
        greps = re.findall(r"grep -E(v?) '([^']+)'", step)
        self.assertEqual([flag for flag, _ in greps], ["v", "", ""])
        docs, builds, app_markdown = (re.compile(pattern) for _, pattern in greps)
        # The same-change skip builds for Markdown in an app or test folder,
        # since the change id counts Markdown only by its words.
        # core.quotePath=false keeps a non-ASCII name unquoted, so it matches.
        for path in ("Conduit/Resources/Help.md", "ConduitTests/x.md", "Shared/a/b.md",
                     "Conduit/Resources/日本語.md", '"Conduit/a\\"b.md"'):
            self.assertTrue(app_markdown.search(path), path)
        for path in ("docs/FEATURE_MAP.md", "README.md", "Conduit/App.swift"):
            self.assertFalse(app_markdown.search(path), path)
        # The review plan counts the same Markdown as code (both reviewers).
        review = _read(os.path.join(REPO_ROOT, ".github", "workflows", "opencode-review.yml"))
        code_config = re.search(r"code_config='([^']+)'", review).group(1)
        self.assertIn("|^(Conduit[^/]*|Shared)/.*\\.md$|", code_config)
        # ...and the same-change branch is gated on it and on a non-empty diff.
        self.assertIn("&& changed=$(git -c core.quotePath=false diff --no-renames --name-only HEAD^1 HEAD) && [ -n \"$changed\" ] \\\n"
                      "            && ! printf '%s\\n' \"$changed\" | grep -E '^\"?(Conduit[^/]*|Shared)/.*\\.md\"?$' >/dev/null; then\n"
                      "            repo=", step)
        # The lookup takes only a passing Smoke job on another of the PR's
        # commits, built as this PR's merge commit, with a non-empty id.
        self.assertIn('select(.name == "Smoke" and .conclusion == "success")', step)
        self.assertIn('[ "$sha" != "$PR_HEAD" ] || continue', step)
        self.assertIn('[ -n "$now" ] && [ "$now" = "$(change_id "$passed")" ]', step)
        self.assertEqual(2, step.count("[ \"$(git rev-parse -q --verify 'HEAD^2' || true)\" = \"$PR_HEAD\" ]"))

        def skips(*paths):
            return all(docs.search(p) for p in paths) and not any(builds.search(p) for p in paths)

        self.assertTrue(skips("README.md", "docs/FEATURE_MAP.md", "designs/x.md", "LICENSE",
                              "opencode.json", ".coderabbit.yaml", ".github/workflows/opencode-review.yml"))
        for path in (".github/workflows/ci.yml", "Conduit/Resources/Help.md", "Shared/notes.md",
                     "ConduitWatch/README.md", "ConduitTests/fixture.md", "scripts/ci-gate.py",
                     "project.yml", "Conduit/App.swift"):
            self.assertFalse(skips("README.md", path), path)
        # A Swift file moved to docs/ lists its old name too, so it builds.
        self.assertFalse(skips("Conduit/X.swift", "docs/X.md"))

    def test_the_feature_map_check_knows_the_pr_and_its_base(self):
        """On a PR, an entry it edits names it on its Checked line: the step
        passes the PR's number and the base's map (HEAD^1 of the merge commit),
        and for a PR into pulse or linked-rooms, main's maps where the PR and
        its base meet main, so the entries a merge of main brings in keep
        main's Checked lines."""
        step = _step_text(self._job_text("self-test"), "Feature map paths exist")
        self.assertIn("PR_NUMBER: ${{ github.event.pull_request.number }}", step)
        self.assertIn("git show HEAD^1:docs/FEATURE_MAP.md", step)
        self.assertIn('--pr "$PR_NUMBER"', step)
        self.assertIn("--base-map", step)
        self.assertIn("BASE_REF: ${{ github.event.pull_request.base.ref }}", step)
        self.assertIn('if [ "$BASE_REF" != "main" ]', step)
        # Only a PR that merges main (fewer of main's commits left to take
        # than its base) gets main's maps, from where its head and its base
        # meet main.
        self.assertIn("BASE_SHA: ${{ github.event.pull_request.base.sha }}", step)
        self.assertIn('compare="repos/$GITHUB_REPOSITORY/compare/main..."', step)
        self.assertIn("meets='\"\\(.merge_base_commit.sha) \\(.behind_by)\"'", step)
        self.assertIn('"$compare$HEAD_SHA?per_page=1" --jq "$meets"', step)
        self.assertIn('"$compare$BASE_SHA?per_page=1" --jq "$meets"', step)
        self.assertIn('elif [ "${head#* }" -lt "${base#* }" ]', step)
        self.assertIn('git fetch --no-tags --depth=1 origin "${head% *}" "${base% *}"', step)
        self.assertIn('git show "${head% *}:docs/FEATURE_MAP.md"', step)
        self.assertIn('git show "${base% *}:docs/FEATURE_MAP.md"', step)
        self.assertIn("--main-map", step)
        self.assertIn("--main-base-map", step)
        # GitHub out of reach: warn and check as before, like the notifier lookup.
        self.assertIn("::warning::Couldn't ask GitHub whether the PR merges main", step)
        self.assertIn("::warning::Couldn't read docs/FEATURE_MAP.md on main", step)

    def test_smoke_job_builds_while_the_simulator_boots(self):
        """The smoke job builds its own products with the simulator booting in
        the background: no shared-artifact hop, and package resolution runs
        during the boot."""
        text = self._job_text("smoke")
        self.assertIn("bash scripts/ci-hosted-build.sh", text)
        self.assertIn("needs: plan", text)
        self.assertNotIn("build-products", text)
        self.assertEqual(1, text.count("bash scripts/ci-hosted-build.sh"),
                         "both test steps run on the one build")
        build = _read(os.path.join(SCRIPTS_DIR, "ci-hosted-build.sh"))
        self.assertIn("ci-prepare-smoke.sh", build)
        self.assertIn("&\n", build, "preparation must run in the background")
        self.assertIn("ci-build-for-testing.sh", build)
        self.assertIn('wait "$prepare_pid"', build)
        self.assertIn("XCRUN_FILE=", build)

    def test_smoke_job_runs_unit_then_ui_on_the_same_build(self):
        text = self._job_text("smoke")
        build = text.index("- name: Build and boot the simulator in parallel")
        unit = text.index("- name: Run the curated unit smoke classes")
        ui = text.index("- name: Run the curated UI smoke suite")
        self.assertLess(build, unit)
        self.assertLess(unit, ui)

    def test_a_unit_smoke_failure_does_not_skip_the_ui_step(self):
        """Both verdicts are visible on every push run: the UI step runs after
        a failed unit step (any failed step still fails the job), and only a
        failed build or a cancelled run skips it. A PR runs no UI smoke
        (Eric, 2026-11-02): main's run after the merge and the nightly do."""
        ui = _step_text(self._job_text("smoke"), "Run the curated UI smoke suite")
        self.assertIn("if: ${{ !cancelled() && steps.build.outcome == 'success' && github.event_name == 'push' }}", ui)
        remove = _step_text(self._job_text("smoke"), "Remove the app before UI smoke")
        self.assertIn("if: ${{ !cancelled() && steps.build.outcome == 'success' && github.event_name == 'push' }}", remove)
        unit = _step_text(self._job_text("smoke"), "Run the curated unit smoke classes")
        self.assertNotIn("if:", unit, "the unit step runs only after a good build")
        self.assertNotIn("continue-on-error", self._job_text("smoke"),
                         "a failed step must fail the job")

    def test_unit_smoke_step_runs_the_curated_classes_once_without_retry(self):
        unit = _step_text(self._job_text("smoke"), "Run the curated unit smoke classes")
        self.assertIn('UNIT_CLASSES: "${{ needs.plan.outputs.unit-csv }}"', unit)
        self.assertIn("-only-testing:ConduitTests/", unit)
        self.assertEqual(1, unit.count("xcodebuild test-without-building"),
                         "the curated unit classes are ONE invocation")
        for flag in ("-parallel-testing-enabled NO",
                     "-collect-test-diagnostics never",
                     "-test-timeouts-enabled YES",
                     '-default-test-execution-time-allowance "${UNIT_TEST_ALLOWANCE_S:-180}"'):
            self.assertIn(flag, unit)
        self.assertIn('UNIT_TEST_ALLOWANCE_S: "180"', unit)
        # A genuine assertion must FAIL the run: no Xcode-native retry, and no
        # job-level retry either.
        self.assertNotIn("-test-iterations", unit)
        self.assertNotIn("-retry-tests-on-failure", unit)
        self.assertNotIn("smoke-retry-classes.py", unit)
        self.assertIn("::error title=unit smoke failures::", unit,
                      "the failing cases must reach an annotation")

    def test_smoke_job_builds_the_full_app(self):
        """Smoke builds the full app on every PR and push, so a PR starts from
        the build main's latest merge saved and recompiles only its change.
        The app-only build (project-tests.yml) restored last night's cache,
        so a PR recompiled the whole day's main: 682 s against 537 s to
        a finished build, medians of 2026-10-22..29."""
        smoke = self._job_text("smoke")
        self.assertIn("xcodegen generate --spec project.yml", smoke)
        self.assertNotIn("project-tests.yml\n", smoke)
        self.assertNotIn("ui-spec", self._workflow_text())
        self.assertIn("kind=full\n", smoke)
        self.assertNotIn("kind=slim", smoke)
        overlay = _read(os.path.join(REPO_ROOT, "project-tests.yml"))
        self.assertIn("- path: project.yml", overlay)
        self.assertIn("dependencies:REPLACE:", overlay)
        self.assertNotIn("- target:", overlay)

    def test_smoke_job_builds_incrementally_and_pushes_save_the_full_build(self):
        """The smoke job restores the newest DerivedData it can reach (main's,
        and on a PR into pulse or linked-rooms that branch's) before
        building, and saves its own only on pushes (to main, and in pulse's
        and linked-rooms' copies to that branch; always the full app there),
        after a successful build, with the same path list (a different list
        is a different cache)."""
        text = self._job_text("smoke")
        _assert_cache_round_trip(self, text, "github.event_name == 'push'", "smoke")
        self.assertIn("&& github.event_name == 'push'\n", text)
        build = _read(os.path.join(SCRIPTS_DIR, "ci-build-for-testing.sh"))
        self.assertIn("ci-normalize-mtimes.py", build)
        self.assertIn("IgnoreFileSystemDeviceInodeChanges", build)
        self.assertIn('[ "${GITHUB_ACTIONS:-}" = "true" ]', build,
                      "never restamp a developer checkout or change their Xcode defaults")
        self.assertIn('[ -d "$DERIVED_DATA_PATH/SourcePackages/checkouts" ] || return 0', build,
                      "-skipPackageUpdates only when the restored cache holds the checkout")
        self.assertIn('${package_flag:+"$package_flag"}', build)

    def test_a_failed_build_posts_its_source_errors(self):
        """A failed build posts its first source errors as annotations, which
        the API serves when the job log can't be read."""
        build = _read(os.path.join(SCRIPTS_DIR, "ci-build-for-testing.sh"))
        self.assertIn('echo "::error file=${file#"$PWD/"},line=$row,col=$col::$message"', build)
        # A message escapes % and a carriage return, as workflow commands need.
        self.assertIn('message="${rest//%/%25}"; message="${message//$\'\\r\'/%0D}"', build)
        self.assertLess(
            build.index("  annotate_source_errors\n"),
            build.index('echo "::error::build-for-testing failed'),
        )

    def test_no_shared_build_job_remains(self):
        text = self._workflow_text()
        self.assertFalse(
            any(line.startswith("  ") and line.strip() == "build:"
                for line in text.splitlines()),
            "the shared build job is gone: the smoke job builds for itself")
        self.assertNotIn("upload-artifact@v4\n        with:\n          name: build-products", text)

    def test_ui_smoke_step_runs_the_curated_classes(self):
        ui = _step_text(self._job_text("smoke"), "Run the curated UI smoke suite")
        self.assertIn('UI_CLASSES: "${{ needs.plan.outputs.ui-csv }}"', ui)
        self.assertIn("-only-testing:ConduitUITests/", ui)
        self.assertNotIn("-test-iterations", ui)
        self.assertNotIn("-retry-tests-on-failure", ui)
        self.assertIn("one targeted retry", ui,
                      "UI smoke absorbs exactly one runner-level flake, visibly")

    def test_smoke_steps_fail_closed_on_an_empty_selection(self):
        # With no -only-testing filter, xcodebuild runs the WHOLE suite.
        smoke = self._job_text("smoke")
        for step in ("Run the curated unit smoke classes", "Run the curated UI smoke suite"):
            self.assertIn("refusing to run unfiltered", _step_text(smoke, step),
                          f"{step} must refuse an empty selection")

    def test_every_hosted_invocation_skips_failure_diagnostics(self):
        # Xcode's on-failure default gathers a simulator payload under its own
        # 600s timeout (docs/CI.md): ten minutes of dead time per failed batch.
        for path in (WORKFLOW, NIGHTLY):
            text = _read(path)
            self.assertEqual(
                text.count("xcodebuild test-without-building"),
                text.count("-collect-test-diagnostics never \\"), path)

    def test_smoke_job_pins_the_simulator_destination(self):
        # A name-only destination lets xcodebuild pick the first of several
        # devices with that name; the shared ci-lib.sh helpers pin the UDID.
        preparation = _read(os.path.join(SCRIPTS_DIR, "ci-prepare-smoke.sh"))
        for needle in ("ci-lib.sh", "wait_for_destination_device",
                       "build_destination", "shutdown_own_simulator",
                       "LOG_DIR=", "export LOG_DIR"):
            self.assertIn(needle, preparation)
        smoke = self._job_text("smoke")
        for step in ("Run the curated unit smoke classes", "Run the curated UI smoke suite"):
            text = _step_text(smoke, step)
            self.assertIn('-destination "$DESTINATION"', text, step)
        self.assertNotIn("platform=iOS Simulator,name=", smoke,
                         "the smoke job must not hand xcodebuild an unpinned destination")

    def test_smoke_diagnostics_keep_both_logs(self):
        upload = _step_text(self._job_text("smoke"), "Upload hosted smoke diagnostics")
        self.assertIn("if: always()", upload)
        self.assertIn("ci-lane/unit-smoke.log", upload)
        self.assertIn("ci-lane/ui-smoke.log", upload)
        self.assertIn("UNIT_SMOKE_LOG: ci-lane/unit-smoke.log", self._job_text("smoke"))

    def test_the_self_test_job_runs_full_discovery_and_stays_required(self):
        text = self._job_text("self-test")
        self.assertNotIn("matrix", text)
        self.assertIn("python3 scripts/ci-self-test.py", text)
        self.assertIn("self-test]", self._job_text("ci-gate"))
        self.assertIn('--self-test "${{ needs.self-test.result }}"', self._job_text("ci-gate"))

    def test_ci_gate_requires_plan_smoke_and_self_test(self):
        gate = self._job_text("ci-gate")
        self.assertIn("needs: [plan, smoke, self-test]", gate)
        self.assertIn("if: always()", gate)
        self.assertIn("name: CI Gate", gate)
        self.assertIn('--plan "${{ needs.plan.result }}"', gate)
        self.assertIn('--smoke "${{ needs.smoke.result }}"', gate)
        # Without it every legitimately skipped smoke job fails the gate.
        self.assertIn('--smoke-needed "${{ needs.plan.outputs.smoke }}"', gate)
        self.assertIn("if: needs.plan.outputs.smoke != 'false'", self._job_text("smoke"))
        self.assertNotIn("needs.unit.", gate)
        self.assertNotIn("needs.ui-smoke.", gate)

    def test_no_write_only_build_metadata_artifact(self):
        self.assertNotIn("name: build-meta", self._workflow_text(),
                         "nothing consumes build-meta once the report job is gone")

    def test_no_lane_matrix_or_timing_history_machinery_remains(self):
        text = self._workflow_text()
        self.assertNotIn("fromJSON(needs.plan.outputs.matrix)", text)
        self.assertNotIn("fromJSON(needs.plan.outputs.ui-matrix)", text)
        # The only cache left is the build cache (DerivedData); the
        # timing-history cache is gone with its job.
        self.assertNotIn("timing-history", text)
        for obsolete in ("report:", "timing-history-update:", "unit-smoke:",
                         "unit:", "ui-smoke:"):
            self.assertFalse(
                any(line.startswith("  ") and line.strip() == obsolete
                    for line in text.splitlines()),
                f"obsolete job {obsolete!r} still present in ci.yml")

    def test_ci_gate_script_verdict_matches_spec_examples(self):
        spec = {
            ("success", "success", "success"): True,
            # No hosted job is ever legitimately skipped: a skip is always an
            # upstream failure cascade - and fails the gate.
            ("success", "skipped", "success"): False,
            ("success", "failure", "success"): False,
            ("success", "timed_out", "success"): False,
            ("success", "cancelled", "success"): False,
            ("success", "success", "failure"): False,
            ("failure", "skipped", "skipped"): False,
            ("cancelled", "success", "success"): False,
        }
        for (plan, smoke, self_test), expected in spec.items():
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "ci-gate.py"),
                 "--plan", plan, "--smoke", smoke, "--self-test", self_test],
                capture_output=True, text=True)
            self.assertEqual(
                proc.returncode == 0, expected,
                f"gate({plan},{smoke},{self_test}) -> {proc.stdout}")


class NightlyWorkflowTests(unittest.TestCase):
    def setUp(self):
        if not os.path.exists(NIGHTLY):
            self.skipTest("nightly.yml not present")
        self.text = _read(NIGHTLY)

    def test_nightly_never_runs_on_pull_requests(self):
        self.assertIn("schedule:", self.text)
        self.assertIn("workflow_dispatch:", self.text)
        self.assertNotIn("pull_request", self.text)

    def test_nightly_runs_full_unit_shards_timing_and_the_whole_ui_suite(self):
        self.assertEqual(_job_keys(NIGHTLY), ["plan", "unit", "timing", "ui"])
        plan = _job_text(NIGHTLY, "plan")
        self.assertIn("plan-tests.py hosted", plan)
        self.assertIn("--suite scripts/hosted-suite.json", plan)
        self.assertIn("nightly_unit_csv", plan)
        for output in ("unit-shards", "timing-csv", "ui-shards"):
            self.assertIn(f'{output}: "${{{{ steps.hosted.outputs.{output} }}}}"', plan)
        self.assertIn("fromJSON(needs.plan.outputs.unit-shards)", _job_text(NIGHTLY, "unit"))
        self.assertIn("fromJSON(needs.plan.outputs.ui-shards)", _job_text(NIGHTLY, "ui"))
        self.assertIn("repeat: [1, 2, 3]", _job_text(NIGHTLY, "timing"),
                      "each timing pass is its own job, so one never outgrows its ceiling")
        self.assertIn("-collect-test-diagnostics never", self.text)
        self.assertNotIn("-retry-tests-on-failure", self.text)
        self.assertNotIn("-test-iterations", self.text)

    def test_every_nightly_test_job_fails_closed_on_an_empty_selection(self):
        for job in ("unit", "timing", "ui"):
            self.assertIn("refusing to run unfiltered", _job_text(NIGHTLY, job), job)

    def test_unit_shards_run_one_shard_per_matrix_entry_in_sequential_batches(self):
        unit = _job_text(NIGHTLY, "unit")
        self.assertIn("needs: plan", unit)
        self.assertIn("fail-fast: false", unit,
                      "one failing shard must not cancel the other")
        self.assertIn('UNIT_CLASSES: "${{ matrix.classes }}"', unit)
        self.assertIn("UNIT_BATCH_SIZE", unit)
        self.assertIn("-only-testing:ConduitTests/", unit)
        self.assertIn("-test-timeouts-enabled YES", unit,
                      "a hung unit test must be killed, not burn the job ceiling")
        self.assertIn('-destination "$DESTINATION"', unit)
        self.assertNotIn("platform=iOS Simulator,name=", unit)
        self.assertNotIn("targeted retry", unit)
        self.assertIn("bash scripts/ci-hosted-build.sh", unit)
        self.assertIn("xcodegen generate --spec project-tests.yml", unit)

    def test_unit_shard_one_saves_the_slim_build_cache_on_main(self):
        """Only the nightly unit shards build project-tests.yml and restore
        the slim cache; shard 1 saves it on main. Smoke builds the full app."""
        unit = _job_text(NIGHTLY, "unit")
        _assert_cache_round_trip(self, unit, "matrix.shard == 1", "nightly unit")
        self.assertIn("SPEC: project-tests.yml", unit)
        self.assertIn("&& github.ref == 'refs/heads/main'\n", unit,
                      "only main's builds may be saved")

    def test_nightly_documents_the_release_validation_path(self):
        self.assertIn("release", self.text.split("\non:\n")[0])


class ScreenshotWorkflowTests(unittest.TestCase):
    """app-store-screenshots.yml runs a downloaded Hermes, its plugins and
    Homebrew packages; none of that may share a job with a token that can
    write to the repository."""

    def setUp(self):
        if not os.path.exists(SCREENSHOTS):
            self.skipTest("app-store-screenshots.yml not present")
        self.text = _read(SCREENSHOTS)

    def test_the_workflow_only_reads_by_default(self):
        self.assertTrue("\npermissions:\n  contents: read\n" in self.text,
                        "the workflow-wide token must be read-only")

    def test_only_a_job_that_runs_nothing_it_checked_out_or_installed_writes(self):
        default_writes = "\npermissions:\n  contents: write\n" in self.text
        writers = [key for key in _job_keys(SCREENSHOTS)
                   if "contents: write" in _job_text(SCREENSHOTS, key)
                   or (default_writes and "permissions:" not in _job_text(SCREENSHOTS, key))]
        self.assertTrue(writers, "nothing publishes the screenshot refs")
        for key in writers:
            text = _job_text(SCREENSHOTS, key)
            for runs_code in ("actions/checkout", "scripts/", "brew install", "pip install"):
                self.assertFalse(runs_code in text, f"{key} can write and runs {runs_code}")

    def test_the_token_is_never_part_of_a_url_or_script(self):
        self.assertFalse("x-access-token:${{" in self.text, "the token is in a push URL")
        for key in _job_keys(SCREENSHOTS):
            for line in _job_text(SCREENSHOTS, key).splitlines():
                if "${{ github.token }}" in line:
                    self.assertRegex(line, r"^\s+[A-Z_]+: \$\{\{ github\.token \}\}$", key)


class WorkflowExpressionTests(unittest.TestCase):
    """GitHub rejects a workflow file whose ${{ }} expressions don't parse, and
    the run then fails before any job starts. Expressions have no arithmetic,
    which is how `strategy.job-index + 1` in a job name broke both workflows."""

    def test_no_arithmetic_inside_expressions(self):
        for path in (WORKFLOW, NIGHTLY):
            text = _read(path)
            for expr in re.findall(r"\$\{\{(.*?)\}\}", text):
                self.assertNotRegex(expr, r"[+/]|\s-\s",
                                    f"{path}: arithmetic in expression '${{{{{expr}}}}}'")

    def test_shard_matrices_carry_one_based_shard_numbers(self):
        text = _read(NIGHTLY)
        for output in ("unit-shards", "ui-shards"):
            self.assertIn(f"include: ${{{{ fromJSON(needs.plan.outputs.{output}) }}}}", text)
        self.assertEqual(2, text.count("(shard ${{ matrix.shard }})"))
        self.assertEqual(2, text.count("map({shard: (.key + 1), classes: .value})"))

    def test_every_needs_output_is_declared_by_the_plan_job(self):
        """A typo in needs.plan.outputs.<name> expands to an empty string,
        which the test steps would then refuse - or a matrix that fails to
        parse. Every output a workflow reads must be one its plan declares."""
        for path in (WORKFLOW, NIGHTLY):
            text = _read(path)
            plan = _job_text(path, "plan")
            declared = set(re.findall(r"^      ([a-z0-9-]+): \"\$\{\{ steps\.", plan, re.M))
            used = set(re.findall(r"needs\.plan\.outputs\.([a-z0-9-]+)", text))
            self.assertTrue(used, path)
            self.assertLessEqual(used, declared, path)

    def test_every_step_reference_names_a_step_of_the_same_job(self):
        for path in (WORKFLOW, NIGHTLY):
            for job in _job_keys(path):
                text = _job_text(path, job)
                ids = set(re.findall(r"^\s+id: ([a-z0-9-]+)$", text, re.M))
                for ref in re.findall(r"steps\.([a-z0-9-]+)\.", text):
                    self.assertIn(ref, ids, f"{path} job {job}: steps.{ref} has no step")


class HostedSelectionTests(unittest.TestCase):
    """plan-tests.py hosted: every unit class lands in exactly one nightly unit
    shard or the nightly-only timing list, every UI class in one nightly UI
    shard, and a stale nightly name fails the plan. With the PR gate down to
    the smoke classes, this partition is what keeps any test from dropping
    out of both workflows."""

    HOSTED_SUITE = os.path.join(SCRIPTS_DIR, "hosted-suite.json")

    def _run(self, suite_path, out_path=None):
        args = [sys.executable, os.path.join(SCRIPTS_DIR, "plan-tests.py"),
                "hosted", "--repo-root", REPO_ROOT, "--suite", suite_path]
        if out_path:
            args += ["--out", out_path]
        return subprocess.run(args, capture_output=True, text=True)

    def _write(self, tmp, doc):
        path = os.path.join(tmp, "hosted.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh)
        return path

    def test_shipped_suite_partitions_the_whole_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out.json")
            proc = self._run(self.HOSTED_SUITE, out)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            with open(out, encoding="utf-8") as fh:
                doc = json.load(fh)
        with open(self.HOSTED_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        shard_classes = [c for csv in doc["unit_shards"] for c in csv.split(",")]
        nightly = doc["nightly_unit_csv"].split(",")
        self.assertEqual(len(doc["unit_shards"]), suite["unit_shards"])
        self.assertEqual(len(shard_classes), len(set(shard_classes)))
        self.assertFalse(set(shard_classes) & set(nightly))
        self.assertEqual(len(shard_classes) + len(nightly), doc["inventory_unit"])
        ui_classes = [c for csv in doc["ui_shards"] for c in csv.split(",")]
        self.assertEqual(len(ui_classes), len(set(ui_classes)))
        self.assertEqual(len(ui_classes), doc["inventory_ui"])
        self.assertEqual(len(doc["ui_shards"]), suite["nightly_ui_shards"])

    def test_every_smoke_class_also_runs_in_a_nightly_shard(self):
        """The smoke classes are a sample of the nightly suite, not a carve-out
        from it: each one is also in a nightly unit or UI shard."""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out.json")
            proc = self._run(self.HOSTED_SUITE, out)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            with open(out, encoding="utf-8") as fh:
                doc = json.load(fh)
        with open(SMOKE_SUITE, encoding="utf-8") as fh:
            smoke = json.load(fh)
        shard_classes = {c for csv in doc["unit_shards"] for c in csv.split(",")}
        ui_classes = {c for csv in doc["ui_shards"] for c in csv.split(",")}
        self.assertLessEqual({t.split("/")[0] for t in smoke["unit"]}, shard_classes)
        self.assertLessEqual({t.split("/")[0] for t in smoke["ui"]}, ui_classes)

    def test_a_stale_nightly_class_fails_the_selection(self):
        with open(self.HOSTED_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        suite["nightly_only_unit"] = suite["nightly_only_unit"] + ["NoSuchClassTests"]
        with tempfile.TemporaryDirectory() as tmp:
            proc = self._run(self._write(tmp, suite))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("NoSuchClassTests", proc.stdout)

    def test_an_unknown_schema_version_fails_the_selection(self):
        with open(self.HOSTED_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        suite["schema_version"] = 2
        with tempfile.TemporaryDirectory() as tmp:
            proc = self._run(self._write(tmp, suite))
        self.assertNotEqual(proc.returncode, 0)

    def test_a_non_positive_shard_count_fails_the_selection(self):
        with open(self.HOSTED_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        for bad in (0, -1, "2", True):
            suite["unit_shards"] = bad
            with tempfile.TemporaryDirectory() as tmp:
                proc = self._run(self._write(tmp, suite))
            self.assertNotEqual(proc.returncode, 0, repr(bad))


class SmokeSelectionTests(unittest.TestCase):
    """The hosted suite selection is a checked-in list, so its integrity is a
    contract: every class must exist, and the split must be visible."""

    def _run_smoke(self, suite_path, out_path=None):
        args = [sys.executable, os.path.join(SCRIPTS_DIR, "plan-tests.py"),
                "smoke", "--repo-root", REPO_ROOT, "--suite", suite_path]
        if out_path:
            args += ["--out", out_path]
        return subprocess.run(args, capture_output=True, text=True)

    def test_shipped_smoke_suite_validates_against_the_inventory(self):
        self.assertTrue(os.path.exists(SMOKE_SUITE), "smoke-suite.json missing")
        proc = self._run_smoke(SMOKE_SUITE)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("smoke selection OK", proc.stdout)
        self.assertIn("not in the smoke set", proc.stdout)

    def test_shipped_smoke_suite_never_names_a_timing_family(self):
        with open(SMOKE_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        with open(os.path.join(SCRIPTS_DIR, "hosted-suite.json"), encoding="utf-8") as fh:
            nightly_only = set(json.load(fh)["nightly_only_unit"])
        # The timing/performance/dormancy families run with repeats in the
        # nightly workflow (docs/CI.md): running them in the smoke job would
        # re-litigate timing-sensitive suites on every PR's shared runner.
        timing_families = {
            "TranscriptPerformanceFixtureTests",
            "TranscriptPerfLedgerContractTests",
            "LongContextScalingFixtureTests",
            "SettledMessageIsolationTests",
            "MarkdownRichContentHostedTests",
        }
        self.assertLessEqual(timing_families, nightly_only)
        self.assertFalse(
            nightly_only & {t.split("/")[0] for t in suite.get("unit") or []},
            "a nightly-only timing family must not be in the smoke set")
        self.assertFalse(nightly_only & set(suite.get("source_contracts") or []))
        self.assertFalse(nightly_only & {t.split("/")[0] for t in suite.get("ui") or []})

    def test_a_nonexistent_class_fails_the_selection(self):
        with open(SMOKE_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        suite["unit"] = list(suite["unit"]) + ["NoSuchTestsHere"]
        with tempfile.TemporaryDirectory() as tmp:
            bogus = os.path.join(tmp, "suite.json")
            with open(bogus, "w", encoding="utf-8") as fh:
                json.dump(suite, fh)
            proc = self._run_smoke(bogus)
        self.assertNotEqual(proc.returncode, 0,
                            "a renamed/deleted class must fail the plan job")
        self.assertIn("NoSuchTestsHere", proc.stdout)

    def test_a_duplicated_class_fails_the_selection(self):
        with open(SMOKE_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        suite["unit"] = list(suite["unit"]) + [suite["unit"][0]]
        with tempfile.TemporaryDirectory() as tmp:
            bogus = os.path.join(tmp, "suite.json")
            with open(bogus, "w", encoding="utf-8") as fh:
                json.dump(suite, fh)
            proc = self._run_smoke(bogus)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("twice", proc.stdout)

    def test_a_whole_class_entry_fails_the_selection(self):
        # A class grows with every test added to it, and the PR gate with it:
        # the curated lists pin single tests.
        def mutate(suite):
            suite["unit"] = list(suite["unit"]) + ["ProfileDiscoveryTests"]

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Class/testMethod", proc.stdout)

    def test_a_renamed_test_fails_the_selection(self):
        def mutate(suite):
            suite["ui"] = list(suite["ui"]) + ["ProfilePickerUITests/testNoSuchThing"]
            suite["max_ui_tests"] = len(suite["ui"])

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("has no test method testNoSuchThing()", proc.stdout)

    def test_a_list_over_its_cap_fails_the_selection(self):
        for key, cap in (("unit", "max_unit_tests"), ("ui", "max_ui_tests")):
            with self.subTest(key=key):
                def mutate(suite, cap=cap, key=key):
                    suite[cap] = len(suite[key]) - 1

                proc = self._run_smoke_with(mutate)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("over its cap", proc.stdout)
                self.assertIn(cap, proc.stdout)

    def test_a_pinned_timing_family_test_fails_the_selection(self):
        with open(os.path.join(SCRIPTS_DIR, "hosted-suite.json"), encoding="utf-8") as fh:
            family = json.load(fh)["nightly_only_unit"][0]
        method = None
        for dirpath, _, files in os.walk(os.path.join(REPO_ROOT, "ConduitTests")):
            for f in files:
                with open(os.path.join(dirpath, f), encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
                m = re.search(r"^(?:final )?class " + family + r"\b.*?^    func (test\w+)\(\)",
                              text, re.M | re.S)
                if m:
                    method = m.group(1)
        self.assertTrue(method, family)

        def mutate(suite):
            suite["unit"] = list(suite["unit"])[:-1] + [f"{family}/{method}"]

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("nightly-only timing family", proc.stdout)

    def test_a_missing_cap_fails_the_selection(self):
        def mutate(suite):
            suite.pop("max_ui_tests")

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("max_ui_tests", proc.stdout)

    def _run_smoke_with(self, mutate):
        """Run `smoke` against a copy of the shipped suite after `mutate`."""
        with open(SMOKE_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        mutate(suite)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "suite.json")
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(suite, fh)
            return self._run_smoke(path)

    def test_a_class_in_the_wrong_target_fails_the_selection(self):
        # Validating against the union of both inventories would let a class
        # moved between ConduitTests/ and ConduitUITests/ through, and the smoke
        # job would then filter it against the wrong bundle - running zero tests
        # for it while the plan job reported success.
        def mutate(suite):
            suite["unit"] = list(suite["unit"]) + [
                "ConnectionSetupUITests/testWizardAdvancesThroughQuestionsToTailscaleBranchAndBack"]

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("ConnectionSetupUITests is not a unit test class", proc.stdout)

    def test_a_missing_target_key_fails_the_selection(self):
        def mutate(suite):
            suite.pop("ui")

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("must declare", proc.stdout)

    def test_an_empty_target_list_fails_the_selection(self):
        def mutate(suite):
            suite["ui"] = []

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)

    def test_a_non_class_name_entry_fails_the_selection(self):
        def mutate(suite):
            suite["unit"] = list(suite["unit"]) + ["Not A Class"]

        proc = self._run_smoke_with(mutate)
        self.assertNotEqual(proc.returncode, 0)

    def test_a_failing_selection_writes_no_output_file(self):
        # The plan job's `jq -r '.unit_csv' smoke.json` must never read a stale
        # or partially written selection: a failed validation writes nothing.
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "smoke.json")
            with open(SMOKE_SUITE, encoding="utf-8") as fh:
                suite = json.load(fh)
            suite.pop("ui")
            bogus = os.path.join(tmp, "suite.json")
            with open(bogus, "w", encoding="utf-8") as fh:
                json.dump(suite, fh)
            proc = self._run_smoke(bogus, out_path=out)
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse(os.path.exists(out),
                             "a failed selection must not leave a selection file")

    def test_selection_output_feeds_the_smoke_jobs(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "smoke.json")
            proc = self._run_smoke(SMOKE_SUITE, out_path=out)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            with open(out, encoding="utf-8") as fh:
                doc = json.load(fh)
            self.assertTrue(doc["unit_csv"])
            self.assertEqual(doc["unit_csv"].split(","), doc["unit"])
            self.assertEqual(doc["ui_csv"].split(","), doc["ui"])
            self.assertEqual(
                doc["delegated_unit"] + len({t.split("/")[0] for t in doc["unit"]}),
                doc["inventory_unit"])
            summary = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "smoke-summary.py"),
                 "--selection", out],
                capture_output=True, text=True)
        self.assertEqual(summary.returncode, 0, summary.stderr)
        self.assertIn("Hosted CI selection", summary.stdout)
        self.assertIn("nightly workflow", summary.stdout)
        # A PR runs no UI smoke, so the summary never says it did.
        self.assertIn("pinned UI tests (pushes only)", summary.stdout)
        self.assertIn("UI (pushes only): ", summary.stdout)

    def _changed_selection(self, changed, mutate=None):
        """Run `smoke --changed-files` on the shipped (or mutated) suite and
        return (proc, selection document or None)."""
        with open(SMOKE_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        if mutate:
            mutate(suite)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "suite.json")
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(suite, fh)
            listing = os.path.join(tmp, "changed.txt")
            with open(listing, "w", encoding="utf-8") as fh:
                fh.write("\n".join(changed) + "\n")
            out = os.path.join(tmp, "smoke.json")
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "plan-tests.py"),
                 "smoke", "--repo-root", REPO_ROOT, "--suite", path,
                 "--out", out, "--changed-files", listing,
                 "--hosted-suite", os.path.join(SCRIPTS_DIR, "hosted-suite.json"),
                 "--baseline", os.path.join(SCRIPTS_DIR, "test-timings.json")],
                capture_output=True, text=True)
            doc = None
            if os.path.exists(out):
                with open(out, encoding="utf-8") as fh:
                    doc = json.load(fh)
        return proc, doc

    def test_ci_passes_the_change_to_the_smoke_selection(self):
        plan = _step_text(_job_text(WORKFLOW, "plan"),
                          "Select the hosted smoke suite")
        self.assertIn("--changed-from HEAD^1", plan)

    def test_source_contracts_always_join_the_unit_invocation(self):
        proc, doc = self._changed_selection([])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        for name in ("AccessibilityLabelAuditTests", "LogRedactionTests"):
            self.assertIn(name, doc["unit"])
            self.assertIn(name, doc["unit_csv"].split(","))
        self.assertEqual(doc["changed_unit"], [])

    def test_a_changed_test_file_adds_its_classes(self):
        proc, doc = self._changed_selection(["ConduitTests/SessionPresentationCacheTests.swift"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("SessionPresentationCacheTests", doc["changed_unit"])
        self.assertEqual(doc["unit_csv"].split(","), doc["unit"])
        self.assertEqual(doc["delegated_unit"] + len({t.split("/")[0] for t in doc["unit"]}),
                         doc["inventory_unit"])

    def test_a_changed_pinned_class_runs_whole_instead_of_its_pinned_tests(self):
        proc, doc = self._changed_selection(["ConduitTests/BotModeTests.swift"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("BotModeTests", doc["changed_unit"])
        self.assertIn("BotModeTests", doc["unit"])
        self.assertFalse([t for t in doc["unit"] if t.startswith("BotModeTests/")])
        self.assertTrue([t for t in doc["curated_unit"] if t.startswith("BotModeTests/")])
        self.assertEqual(doc["replaced_unit"],
                         [t for t in doc["curated_unit"] if t.startswith("BotModeTests/")])

    def test_a_changed_app_file_adds_its_namesake_tests(self):
        proc, doc = self._changed_selection(
            ["Conduit/Services/ServerSignOut.swift", "README.md",
             "ConduitUITests/ConnectionSetupUITests.swift"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(doc["changed_unit"], ["ServerSignOutTests"])
        self.assertNotIn("ConnectionSetupUITests", doc["unit"])

    def test_a_changed_app_file_adds_its_stems_family(self):
        proc, doc = self._changed_selection(
            ["Conduit/Services/AppState+PendingSend.swift"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        # #1154 changed AppState.swift and broke this class, which then
        # failed only at night.
        self.assertIn("AppStateChatResumeTests", doc["changed_unit"])
        self.assertIn("AppStateMultiDashboardTests", doc["changed_unit"])
        for name in doc["changed_unit"]:
            self.assertTrue(name.startswith("AppState"), name)

    def test_a_family_member_does_not_crowd_out_the_changes_own_class(self):
        def mutate(suite):
            suite["changed_max_classes"] = 1
        proc, doc = self._changed_selection(
            ["Conduit/Services/AppState.swift",
             "ConduitTests/SessionPresentationCacheTests.swift"], mutate)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(doc["changed_unit"], ["SessionPresentationCacheTests"])
        self.assertIn("AppStateChatResumeTests", doc["changed_skipped"])

    def test_a_heavy_own_class_still_runs_before_a_family_member(self):
        def mutate(suite):
            suite["changed_budget_s"] = 0.5
        proc, doc = self._changed_selection(
            ["Conduit/Services/AppState.swift",
             "ConduitTests/DashboardTicketBridgeTests.swift"], mutate)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("DashboardTicketBridgeTests", doc["changed_unit"])
        self.assertIn("runs anyway", proc.stdout)

    def test_a_family_only_change_still_runs_one_class(self):
        def mutate(suite):
            suite["changed_budget_s"] = 0
        proc, doc = self._changed_selection(
            ["Conduit/Services/AppState.swift"], mutate)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(len(doc["changed_unit"]), 1)
        self.assertTrue(doc["changed_unit"][0].startswith("AppState"))

    def test_a_changed_timing_family_stays_nightly_only(self):
        proc, doc = self._changed_selection(
            ["ConduitTests/LongContextScalingFixtureTests.swift"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn("LongContextScalingFixtureTests", doc["unit"])

    def test_changed_classes_over_the_budget_are_left_to_nightly(self):
        def mutate(suite):
            suite["changed_budget_s"] = 0
        proc, doc = self._changed_selection(
            ["ConduitTests/SessionPresentationCacheTests.swift",
             "ConduitTests/DashboardTicketBridgeTests.swift"], mutate)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        # The cheapest still runs, so a change always gets one of its own.
        self.assertEqual(doc["changed_unit"], ["SessionPresentationCacheTests"])
        self.assertEqual(doc["changed_skipped"], ["DashboardTicketBridgeTests"])
        self.assertIn("classes related to this change left to nightly", proc.stdout)

    def test_changed_classes_are_capped_by_count(self):
        def mutate(suite):
            suite["changed_max_classes"] = 1
        proc, doc = self._changed_selection(
            ["ConduitTests/SessionPresentationCacheTests.swift",
             "Conduit/Services/ServerSignOut.swift"], mutate)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(len(doc["changed_unit"]), 1)
        self.assertEqual(len(doc["changed_skipped"]), 1)

    def test_shipped_smoke_invocation_fits_a_nightly_batch(self):
        with open(SMOKE_SUITE, encoding="utf-8") as fh:
            suite = json.load(fh)
        # Counted in classes, as nightly batches are: the pinned tests come
        # from a few classes.
        total = (len({t.split("/")[0] for t in suite["unit"]})
                 + len(suite.get("source_contracts", []))
                 + suite.get("changed_max_classes", 0))
        self.assertLessEqual(total, 45, "nightly.yml runs unit batches of 45")

    def test_an_unreadable_hosted_suite_adds_no_changed_classes(self):
        with tempfile.TemporaryDirectory() as tmp:
            listing = os.path.join(tmp, "changed.txt")
            with open(listing, "w", encoding="utf-8") as fh:
                fh.write("ConduitTests/LongContextScalingFixtureTests.swift\n")
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "plan-tests.py"),
                 "smoke", "--repo-root", REPO_ROOT, "--suite", SMOKE_SUITE,
                 "--changed-files", listing,
                 "--hosted-suite", os.path.join(tmp, "missing.json")],
                capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn("changed unit classes added", proc.stdout)
        self.assertIn("no changed classes added", proc.stdout + proc.stderr)

    def test_an_unknown_source_contract_fails_the_selection(self):
        def mutate(suite):
            suite["source_contracts"] = ["NoSuchAuditTests"]
        proc, doc = self._changed_selection([], mutate)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("NoSuchAuditTests", proc.stdout)
        self.assertIsNone(doc)

    def test_smoke_summary_rejects_an_empty_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            empty = os.path.join(tmp, "empty.json")
            with open(empty, "w", encoding="utf-8") as fh:
                json.dump({"unit": [], "ui": [], "inventory_unit": 3,
                           "inventory_ui": 0}, fh)
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "smoke-summary.py"),
                 "--selection", empty],
                capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0,
                            "a smoke gate with no unit classes must not pass "
                            "silently")

    def test_smoke_summary_rejects_an_empty_ui_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            doc = os.path.join(tmp, "no-ui.json")
            with open(doc, "w", encoding="utf-8") as fh:
                json.dump({"unit": ["SomeExistingTests"], "ui": [],
                           "inventory_unit": 3, "inventory_ui": 0}, fh)
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "smoke-summary.py"),
                 "--selection", doc],
                capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0,
                            "a smoke gate with no UI classes must not pass "
                            "silently")

    def test_smoke_summary_tolerates_absent_counts(self):
        # Hand-built fixture: the summary must render, not print "None".
        with tempfile.TemporaryDirectory() as tmp:
            doc = os.path.join(tmp, "min.json")
            with open(doc, "w", encoding="utf-8") as fh:
                json.dump({"unit": ["SomeExistingTests"], "ui": ["OtherUITests"]}, fh)
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "smoke-summary.py"),
                 "--selection", doc],
                capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("None", proc.stdout)


if __name__ == "__main__":
    unittest.main()
