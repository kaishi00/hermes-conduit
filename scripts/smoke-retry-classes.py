#!/usr/bin/env python3
"""Select one hosted UI retry; uncertain results retain the whole selection.

The selection names whole classes or single tests (`Class/testMethod`, as
scripts/smoke-suite.json pins them); the retry names the failed ones the
same way."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys


# What xcresulttool hangs under a test case: its failure messages, their
# source references, attachments such as the screenshot taken on a failure,
# and runtime warnings. They describe that case, so its class is the one to
# retry whatever they hold.
CASE_DETAILS = {"Failure Message", "Source Code Reference", "Attachment",
                "Expression", "Test Value", "Runtime Warning"}


def check_case_detail(node, case_result):
    """Reject anything under a case that could hide another result: a nested
    test, a repetition, an unknown node, or a failure under a case that did
    not fail."""
    if not isinstance(node, dict):
        raise ValueError("malformed raw test case child")
    kind = node.get("nodeType")
    if kind not in CASE_DETAILS:
        raise ValueError("unattributable raw test case child: {} {!r} under a {} case".format(
            kind, str(node.get("name") or "")[:60], case_result))
    if kind == "Failure Message" and (case_result != "Failed" or not isinstance(node.get("name"), str)
                                      or not node["name"]):
        raise ValueError("inconsistent failure message under a {} case".format(case_result))
    if node.get("result") not in (None, "Passed", "Failed", "Skipped"):
        raise ValueError("unrecognized raw result status")
    children = node.get("children", []) or []
    if not isinstance(children, list):
        raise ValueError("malformed raw result children")
    for child in children:
        check_case_detail(child, case_result)


def extract_for_retry(data, label):
    # Timing extraction intentionally tolerates lossy schemas. Retry attribution
    # cannot: every raw result must be understood and every case accounted for.
    def count_cases(node, in_bundle=False, in_suite=False):
        if not isinstance(node, dict):
            raise ValueError("malformed raw result node")
        kind = str(node.get("nodeType", "")).lower()
        children = node.get("children", []) or []
        if not isinstance(children, list):
            raise ValueError("malformed raw result children")
        result = node.get("result")
        if result is not None and result not in ("Passed", "Failed", "Skipped"):
            raise ValueError("unrecognized raw result status")
        if "test case" in kind:
            if not in_bundle or not in_suite:
                raise ValueError("unattributable raw test case")
            # The normalizer intentionally ignores a case's diagnostics: what
            # they report already belongs to this case. Still reject hidden
            # cases, unknown metadata, or inconsistent diagnostics instead of
            # dropping them.
            for child in children:
                check_case_detail(child, result)
            return 1, result == "Failed"
        if "test bundle" in kind:
            in_bundle, in_suite = True, False
        elif "test suite" in kind:
            in_suite = True
        elif "test plan" not in kind and not (not kind and not in_bundle and children):
            raise ValueError("unrecognized raw result node: " + (kind or "missing type"))
        observations = [count_cases(child, in_bundle, in_suite) for child in children]
        has_failure = any(failed for _, failed in observations)
        if result == "Failed" and not has_failure:
            raise ValueError("container failure has no attributable failed test case")
        return sum(count for count, _ in observations), has_failure

    raw_count = sum(count_cases(node)[0] for node in data["testNodes"])
    spec = importlib.util.spec_from_file_location(
        "extract_test_timings", os.path.join(os.path.dirname(__file__), "extract-test-timings.py"))
    extractor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(extractor)
    warnings = io.StringIO()
    with contextlib.redirect_stderr(warnings):
        detail = extractor.extract_from_doc(data, label)
    if warnings.getvalue() or detail["counts"]["cases"] != raw_count:
        raise ValueError("result extraction was incomplete or emitted schema warnings")
    return detail


def _entry_for(attempt, selected):
    """The selected entry an attempt ran for: its class, or its single test."""
    cls = attempt.get("class")
    if cls in selected:
        return cls
    test = str(attempt.get("test") or "")
    if test.endswith("()"):
        test = test[:-2]
    entry = "{}/{}".format(cls, test)
    if entry in selected:
        return entry
    raise ValueError("unknown, skipped, or synthetic test result")


def retry_classes(detail, selected):
    attempts = detail.get("attempts")
    failures = detail.get("failures")
    if not isinstance(attempts, list) or not isinstance(failures, list) or not failures:
        raise ValueError("no reliable test failures in the result")
    observed = set()
    failed = set()
    for attempt in attempts:
        status = attempt.get("final")
        if status not in ("Passed", "Failed"):
            raise ValueError("unknown, skipped, or synthetic test result")
        entry = _entry_for(attempt, selected)
        observed.add(entry)
        if status == "Failed":
            failed.add(entry)
    if observed != set(selected):
        raise ValueError("not every selected class produced a result")
    if ({failure.get("class") for failure in failures}
            != {entry.split("/")[0] for entry in failed} or not failed):
        raise ValueError("failure attribution is incomplete")
    return [entry for entry in selected if entry in failed]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--classes", required=True)
    parser.add_argument("--xcresult", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    selected = args.classes.split(",")
    if not selected or any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(/test[A-Za-z0-9_]*)?", cls)
                           for cls in selected):
        parser.error("classes must be a nonempty CSV of XCTest classes or Class/testMethod tests")
    detail = None
    reason = None
    retry = selected
    try:
        # Bound hosted extraction to 30s; the local extractor's 300s policy is
        # unchanged. Reuse its normalizer rather than inventing an xcresult schema.
        proc = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests",
                               "--path", args.xcresult], capture_output=True, text=True, timeout=30)
        if proc.returncode:
            raise ValueError("xcresulttool could not read the initial result")
        detail = extract_for_retry(json.loads(proc.stdout), args.xcresult)
        retry = retry_classes(detail, selected)
    except (OSError, subprocess.TimeoutExpired, ValueError, RuntimeError, TypeError, AttributeError, KeyError) as exc:
        reason = str(exc)
        print("::warning::UI retry attribution unavailable; retaining entire selection: " + reason,
              file=sys.stderr)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"selected_classes": selected, "retry_classes": retry,
                   "fallback": reason is not None, "reason": reason,
                   "initial_result": detail}, fh, indent=2)
        fh.write("\n")
    print(",".join(retry))
    return 0


if __name__ == "__main__":
    sys.exit(main())
