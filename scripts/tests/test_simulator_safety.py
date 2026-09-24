"""Static safety rule: automation must not issue global simulator lifecycle
commands.

`simctl shutdown all` / `erase all` / `delete all` reach every simulator on
this shared build host - devices other projects and developers own. Two
concurrent simulator chains on one host corrupt each other's state (the
launch-wedge infrastructure failures documented in docs/CI.md), and a global
lifecycle command is the cheapest way to cause one from inside automation.
The rule mirrors the host-level check (`ios-ci-host audit`) so repositories
can enforce it in hosted CI without the Mac: same pattern, same suppression
marker.
"""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SCAN_ROOTS = [
    REPO / "scripts",
    REPO / ".github" / "workflows",
]

# Identical to the host tool's AUDIT_BLOCKER (ios-ci-host), including the
# line-level suppression marker, so the two checks cannot drift apart in
# what they accept. `delete unavailable` is included: it deletes devices
# whose runtime is gone - on a shared host those are OTHER projects'
# devices, so it is just as host-wide as `all`.
FORBIDDEN = re.compile(
    r"\bsimctl\s+(?:-{1,2}[a-z-]+\s+)*(shutdown|erase|delete)\s+(?:[\"\x27]?(?:all|unavailable)[\"\x27]?)\b",
    re.IGNORECASE,
)
ALLOW_MARKER = "host-safety: allow"


def logical_lines(text):
    """Yield (first physical line number, logical line) with backslash
    continuations joined, so a command split across lines cannot hide from
    the scan."""
    buf = ""
    start = 1
    for lineno, line in enumerate(text.splitlines(), 1):
        if not buf:
            if not line.strip():
                continue
            start = lineno
        buf = (buf + " " + line.strip()).rstrip() if buf else line
        if buf.rstrip().endswith("\\"):
            buf = buf.rstrip()[:-1]
            continue
        yield start, buf
        buf = ""
    if buf:
        yield start, buf

# This rule's own source quotes the forbidden commands in its documentation
# and pattern; a detector must not flag itself.
EXEMPT_FILE_NAMES = {"test_simulator_safety.py"}


class GlobalSimulatorCommandRule(unittest.TestCase):

    def test_detector_flags_canonical_offenders(self):
        """Positive controls: a regex typo that made FORBIDDEN match nothing
        would otherwise pass the clean-tree assertion forever."""
        cases = {
            "xcrun simctl shutdown all": True,
            "simctl erase 'all'": True,
            'simctl shutdown "all"': True,
            "xcrun simctl delete unavailable": True,
            "xcrun simctl shutdown \\\n  all": True,
            'xcrun simctl shutdown "$UDID" || true': False,
            "xcrun simctl boot \"$UDID\"": False,
            "bounded_run 60 xcrun simctl shutdown \"$udid\" || true  # host-safety: allow": False,
        }
        for text, expect in cases.items():
            joined = " ".join(line for _, line in logical_lines(text))
            self.assertEqual(bool(FORBIDDEN.search(joined)), expect,
                             "detector misclassified: %r" % text)

    def test_automation_contains_no_global_simulator_lifecycle_commands(self):
        offenders = []
        scanned = 0
        for root in SCAN_ROOTS:
            if not root.exists():
                continue
            for path in sorted(root.rglob("*")):
                if not path.is_file():
                    continue
                if any(part in (".git", "__pycache__") for part in path.parts):
                    continue
                if path.name in EXEMPT_FILE_NAMES:
                    continue
                try:
                    text = path.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                scanned += 1
                for lineno, line in logical_lines(text):
                    if ALLOW_MARKER in line:
                        continue
                    match = FORBIDDEN.search(line)
                    if match:
                        offenders.append("%s:%d: %s (%s)"
                                         % (path.relative_to(REPO), lineno,
                                            match.group(0), line.strip()[:120]))
        self.assertEqual(
            offenders, [],
            "global simulator lifecycle commands are forbidden in automation "
            "(use UDID-scoped operations; the shared build host coordinates "
            "through ios-ci-host). Offenders:\n" + "\n".join(offenders))
        self.assertGreater(scanned, 10, "the scan must actually cover the tree")


if __name__ == "__main__":
    unittest.main()
