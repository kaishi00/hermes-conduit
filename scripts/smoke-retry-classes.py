#!/usr/bin/env python3
"""Select one hosted UI retry; uncertain results retain the whole selection."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys


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
            # xcresulttool attaches assertion diagnostics to failed cases.
            # The normalizer intentionally ignores those leaves: their failure
            # already belongs to this case. Still reject hidden cases, unknown
            # metadata, or inconsistent diagnostics instead of dropping them.
            for child in children:
                if (result != "Failed" or not isinstance(child, dict)
                        or child.get("nodeType") != "Failure Message"
                        or not isinstance(child.get("name"), str) or not child["name"]
                        or child.get("children") not in (None, [])
                        or child.get("result") is not None):
                    raise ValueError("unattributable raw test case child")
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


def retry_classes(detail, selected):
    attempts = detail.get("attempts")
    failures = detail.get("failures")
    if not isinstance(attempts, list) or not isinstance(failures, list) or not failures:
        raise ValueError("no reliable test failures in the result")
    observed = set()
    failed = set()
    for attempt in attempts:
        cls = attempt.get("class")
        status = attempt.get("final")
        if cls not in selected or status not in ("Passed", "Failed"):
            raise ValueError("unknown, skipped, or synthetic test result")
        observed.add(cls)
        if status == "Failed":
            failed.add(cls)
    if observed != set(selected):
        raise ValueError("not every selected class produced a result")
    if {failure.get("class") for failure in failures} != failed or not failed:
        raise ValueError("failure attribution is incomplete")
    return [cls for cls in selected if cls in failed]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--classes", required=True)
    parser.add_argument("--xcresult", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    selected = args.classes.split(",")
    if not selected or any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", cls) for cls in selected):
        parser.error("classes must be a nonempty CSV of XCTest class names")
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
