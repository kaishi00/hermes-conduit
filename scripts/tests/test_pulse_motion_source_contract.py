"""Linux source-contract checks for #1922; not Swift runtime evidence.

These inspect call sites and suspension order, not SwiftUI animation behavior
or live accessibility-setting changes on a device.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PULSE = ROOT / "Conduit/Views/V2/V2PulsePage.swift"
LIVE = "ConduitMotion.ease(reduceMotion: UIAccessibility.isReduceMotionEnabled)"
ENVIRONMENT = "ConduitMotion.ease(reduceMotion: reduceMotion)"


def function(source, name):
    start = source.index(f"private func {name}(")
    end = source.find("\n    private ", start + 1)
    return source[start:end if end != -1 else len(source)]


class PulseMotionSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = PULSE.read_text()

    def test_all_eight_motion_sites_have_the_expected_setting_source(self):
        arguments = re.findall(r"withAnimation\((ConduitMotion\.ease\(reduceMotion: [^)]+\))\)", self.source)
        self.assertEqual(arguments, [LIVE, ENVIRONMENT, ENVIRONMENT, ENVIRONMENT,
                                     LIVE, LIVE, LIVE, LIVE])
        self.assertIn("import UIKit", self.source)
        self.assertIn("@Environment(\\.accessibilityReduceMotion) private var reduceMotion", self.source)

    def test_synchronous_actions_keep_environment_motion(self):
        for name in ("fold", "clearedToggle", "undoBar"):
            with self.subTest(action=name):
                self.assertIn(f"withAnimation({ENVIRONMENT})", function(self.source, name))

    def test_timeout_reads_live_setting_after_unchanged_six_seconds_and_cancellation_guard(self):
        start = self.source.index(".task(id: undo?.id)")
        timeout = self.source[start:self.source.index(".onAppear", start)]
        sleep = timeout.index("try? await Task.sleep(for: .seconds(6))")
        guard = timeout.index("guard !Task.isCancelled else { return }")
        animation = timeout.index(f"withAnimation({LIVE})")
        self.assertLess(sleep, guard)
        self.assertLess(guard, animation)
        self.assertNotIn(ENVIRONMENT, timeout)

    def test_card_completion_animations_read_live_setting_after_await(self):
        for name, call in (("rate", "client.rate"), ("dismiss", "client.dismiss"),
                           ("dismissProposal", "client.dismissProposal")):
            with self.subTest(action=name):
                body = function(self.source, name)
                self.assertLess(body.index(f"try await {call}"), body.index(f"withAnimation({LIVE})"))
                self.assertNotIn(ENVIRONMENT, body)

    def test_show_undo_reads_live_setting_for_all_post_await_callers(self):
        self.assertIn(f"withAnimation({LIVE})", function(self.source, "showUndo"))
        for name, call in (("rate", "client.rate"), ("dismiss", "client.dismiss"),
                           ("markDone", "client.markDone")):
            with self.subTest(action=name):
                body = function(self.source, name)
                self.assertLess(body.index(f"try await {call}"), body.index("showUndo("))
                self.assertNotIn(ENVIRONMENT, body)


if __name__ == "__main__":
    unittest.main()
