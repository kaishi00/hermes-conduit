"""Each opencode reviewer is a chain of model and key pairs
(ALL_REVIEWERS in opencode-review.yml), and the review step's inline
script (REVIEW_CHAIN_SH) walks it: a test request skips a key that is
unset or refused (a usage limit's 429), a review that runs too long moves
on to the next key when its key now refuses and to the next model
otherwise, and a failed review moves on. These run that script with
stand-ins for curl and opencode."""

import json
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest

from test_review_verdict import WORKFLOW, _inline

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Answers the test request with the HTTP code that $FAKE/codes maps the
# request's key to (200 when unlisted). Logs "probe <key> <model>".
FAKE_CURL = r"""#!/usr/bin/env bash
out=''; key=''; data=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -H) case "$2" in "Authorization: Bearer "*) key=${2#Authorization: Bearer } ;; esac; shift ;;
    -d) data=$2; shift ;;
    -w|--max-time) shift ;;
  esac
  shift
done
model=$(jq -r .model <<<"$data")
echo "probe $key $model" >> "$FAKE/log"
code=$(awk -v k="$key" '$1 == k { c = $2 } END { print c ? c : 200 }' "$FAKE/codes")
# A key listed as "later" refuses only from its second test request on.
if [ "$code" = later ]; then
  if grep -qx "probe $key" "$FAKE/seen" 2>/dev/null; then code=429; else code=200; fi
  echo "probe $key" >> "$FAKE/seen"
fi
echo '{"error": "limit"}' > "$out"
printf '%s' "$code"
"""

# Behaves as $FAKE/runs says for "<model> <key>": ok, fail or hang.
FAKE_OPENCODE = r"""#!/usr/bin/env bash
var=$(jq -r --arg p "${MODEL%%/*}" '.provider[$p].options.apiKey' "$CONFIG" | sed 's/^{env://; s/}$//')
key=${!var}
echo "review $MODEL $key ${PROMPT%%$'\n'*}" >> "$FAKE/log"
for k in OPENCODE_GO_API_KEY_2 COMMANDCODE_API_KEY_2; do
  [ "$k" = "$var" ] || [ -z "${!k:-}" ] || echo "leak $k" >> "$FAKE/log"
done
what=$(awk -v m="$MODEL" -v k="$key" '$1 == m && $2 == k { w = $3 } END { print w ? w : "ok" }' "$FAKE/runs")
case "$what" in
  ok) exit 0 ;;
  fail) exit 1 ;;
  hang) exec sleep 30 ;;
  slow) sleep 4; exit 0 ;;
esac
"""

KEYS = {"OPENCODE_GO_API_KEY": "go1", "OPENCODE_GO_API_KEY_2": "go2",
        "COMMANDCODE_API_KEY": "cc1", "COMMANDCODE_API_KEY_2": "cc2", "ZAI_API_KEY": "zai"}


def chain(name):
    with open(WORKFLOW, encoding="utf-8") as fh:
        text = fh.read()
    start = text.index("          ALL_REVIEWERS: >-\n") + len("          ALL_REVIEWERS: >-\n")
    end = text.index("\n          DOCS_REVIEWER:", start)
    reviewers = json.loads(" ".join(text[start:end].split()))
    return next(r["chain"] for r in reviewers if r["reviewer"] == name)


@unittest.skipUnless(shutil.which("jq") and shutil.which("timeout"), "jq or timeout isn't installed")
class ReviewChainTests(unittest.TestCase):
    def run_chain(self, reviewer="DeepSeek, then Beam", codes=(), runs=(), unset=(), chain_minutes="70"):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        bin_dir = os.path.join(tmp, "bin")
        os.mkdir(bin_dir)
        for name, body in (("curl", FAKE_CURL), ("opencode", FAKE_OPENCODE)):
            path = os.path.join(bin_dir, name)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
            os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        with open(os.path.join(tmp, "codes"), "w", encoding="utf-8") as fh:
            fh.write("".join(f"{k} {c}\n" for k, c in codes))
        with open(os.path.join(tmp, "runs"), "w", encoding="utf-8") as fh:
            fh.write("".join(f"{m} {k} {w}\n" for m, k, w in runs))
        output = os.path.join(tmp, "output")
        env = dict(os.environ, PATH=bin_dir + os.pathsep + os.environ["PATH"], FAKE=tmp, RUNNER_TEMP=tmp,
                   CONFIG=os.path.join(REPO_ROOT, "opencode.json"), GITHUB_OUTPUT=output,
                   GITHUB_EVENT_PATH="/dev/null", GITHUB_RUN_ID="1", REPO_OWNER="o",
                   CHAIN=json.dumps(chain(reviewer)), REVIEW_MINUTES="0.03", CHAIN_MINUTES=chain_minutes,
                   PROMPT="Start the review with the label: Review by {reviewer}.\nmore")
        env.pop("GITHUB_STEP_SUMMARY", None)
        for k, v in KEYS.items():
            if k not in unset:
                env[k] = v
        run = subprocess.run(["bash", "-c", _inline("REVIEW_CHAIN_SH")], cwd=REPO_ROOT, env=env,
                             capture_output=True, text=True, timeout=60)
        with open(os.path.join(tmp, "log"), encoding="utf-8") as fh:
            log = fh.read().splitlines()
        outputs = {}
        if os.path.exists(output):
            with open(output, encoding="utf-8") as fh:
                outputs = dict(line.split("=", 1) for line in fh.read().splitlines())
        return run, log, outputs

    def reviews(self, log):
        return [line.split(" ")[1:3] for line in log if line.startswith("review ")]

    def test_first_key_that_answers_reviews(self):
        run, log, out = self.run_chain()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.reviews(log), [["go-custom/deepseek-v4.1-flash", "go1"]])
        self.assertEqual(log[0], "probe go1 deepseek-v4.1-flash")
        self.assertIn("Review by DeepSeek V4.1 Flash.", log[1])
        self.assertEqual(out, {"model": "go-custom/deepseek-v4.1-flash", "name": "DeepSeek V4.1 Flash"})

    def test_limited_keys_fall_through_to_command_code_then_beam(self):
        run, log, out = self.run_chain(codes=[("go1", 429), ("go2", 429)])
        self.assertEqual(self.reviews(log), [["commandcode/deepseek/deepseek-v4.1-flash", "cc1"]])
        self.assertIn("probe cc1 deepseek/deepseek-v4.1-flash", log)

        run, log, out = self.run_chain(codes=[("go1", 429), ("go2", 429), ("cc1", 402), ("cc2", 429)])
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertEqual(self.reviews(log), [])

    def test_unset_keys_are_skipped(self):
        run, log, out = self.run_chain(codes=[("go1", 429)], unset=["OPENCODE_GO_API_KEY_2", "COMMANDCODE_API_KEY_2"])
        self.assertEqual(self.reviews(log), [["commandcode/deepseek/deepseek-v4.1-flash", "cc1"]])
        self.assertIn("OPENCODE_GO_API_KEY_2 isn't set", run.stdout)

    def test_failed_reviews_fall_through_to_beam(self):
        run, log, out = self.run_chain(runs=[("go-custom/deepseek-v4.1-flash", "go1", "fail"),
                                             ("go-custom/deepseek-v4.1-flash", "go2", "fail"),
                                             ("commandcode/deepseek/deepseek-v4.1-flash", "cc1", "fail"),
                                             ("commandcode/deepseek/deepseek-v4.1-flash", "cc2", "fail")])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.reviews(log)[-1], ["go-custom/beam-free", "go1"])
        self.assertEqual(len(self.reviews(log)), 5)
        self.assertIn("Review by Beam.", log[-1])
        self.assertEqual(out["model"], "go-custom/beam-free")

    def test_a_slow_model_skips_its_other_keys(self):
        run, log, out = self.run_chain(runs=[("go-custom/deepseek-v4.1-flash", "go1", "hang")])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.reviews(log), [["go-custom/deepseek-v4.1-flash", "go1"], ["go-custom/beam-free", "go1"]])
        self.assertIn("trying the next model", run.stdout)

    def test_a_limit_hit_mid_review_tries_the_next_key(self):
        run, log, out = self.run_chain(codes=[("go1", "later")],
                                       runs=[("go-custom/deepseek-v4.1-flash", "go1", "hang")])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.reviews(log), [["go-custom/deepseek-v4.1-flash", "go1"],
                                             ["go-custom/deepseek-v4.1-flash", "go2"]])
        self.assertIn("trying the next key", run.stdout)

    def test_the_chain_stops_when_its_time_is_up(self):
        # Every review hangs and every key then refuses, so each pair would
        # run; 0.05 minutes (3 s) fits one 2 s review and a 1 s remainder,
        # which is too short to start another.
        run, log, out = self.run_chain(codes=[("go1", "later"), ("go2", "later")], chain_minutes="0.05",
                                       runs=[("go-custom/deepseek-v4.1-flash", "go1", "hang")])
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertEqual(self.reviews(log), [["go-custom/deepseek-v4.1-flash", "go1"]])
        self.assertIn("nearly up", run.stdout)

    def test_each_fallback_is_labelled_with_its_own_model(self):
        run, log, out = self.run_chain(runs=[("go-custom/deepseek-v4.1-flash", "go1", "fail"),
                                             ("go-custom/deepseek-v4.1-flash", "go2", "fail"),
                                             ("commandcode/deepseek/deepseek-v4.1-flash", "cc1", "fail"),
                                             ("commandcode/deepseek/deepseek-v4.1-flash", "cc2", "fail")])
        labels = [line.split("label: ", 1)[1] for line in log if line.startswith("review ")]
        self.assertEqual(labels, ["Review by DeepSeek V4.1 Flash."] * 4 + ["Review by Beam."])

    def test_the_last_model_isnt_cut_short(self):
        # A chain of one has nothing to fall back to, so a slow GLM review
        # gets the chain's whole budget, not REVIEW_MINUTES (1.8 s here).
        tmp_runs = [("zai-custom/glm-5.3-flash", "zai", "slow")]
        run, log, out = self.run_chain(reviewer="GLM-5.3-Flash", runs=tmp_runs, chain_minutes="0.2")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(out["model"], "zai-custom/glm-5.3-flash")

    def test_only_the_attempts_key_reaches_opencode(self):
        run, log, out = self.run_chain(codes=[("go1", 429)])
        self.assertEqual(self.reviews(log), [["go-custom/deepseek-v4.1-flash", "go2"]])
        self.assertFalse([line for line in log if line.startswith("leak ")], log)

    def test_glm_is_a_chain_of_one(self):
        run, log, out = self.run_chain(reviewer="GLM-5.3-Flash")
        self.assertEqual(self.reviews(log), [["zai-custom/glm-5.3-flash", "zai"]])
        self.assertEqual(out["model"], "zai-custom/glm-5.3-flash")

    def test_every_chain_model_is_in_opencode_json(self):
        with open(os.path.join(REPO_ROOT, "opencode.json"), encoding="utf-8") as fh:
            providers = json.load(fh)["provider"]
        with open(WORKFLOW, encoding="utf-8") as fh:
            workflow = fh.read()
        for reviewer in ("DeepSeek, then Beam", "GLM-5.3-Flash"):
            for step in chain(reviewer):
                provider, model = step["model"].split("/", 1)
                self.assertIn(model, providers[provider]["models"], step)
                self.assertRegex(providers[provider]["options"]["apiKey"], r"^\{env:[A-Za-z0-9_]+\}$")
                self.assertIn(f"secrets.{step['key']} }}}}", workflow)
                # The script copies only the keys it lists, then hides them
                # all from opencode; a key missing there would always skip.
                self.assertRegex(_inline("REVIEW_CHAIN_SH"), rf"for k in [^\n]*\b{step['key']}\b")


if __name__ == "__main__":
    unittest.main()
