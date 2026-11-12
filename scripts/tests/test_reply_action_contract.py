"""Source contracts for reply controls; SwiftUI runtime tests need Xcode."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def view(source, name):
    return source.split(f"struct {name}: View {{", 1)[1].split("\nstruct ", 1)[0]


class ReplyActionContractTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / "Conduit/Views/ChatView.swift").read_text()

    def test_reply_targets_reserve_their_full_size(self):
        for name in ("AssistantMessageActions", "ReadAloudButton", "AssistantMessageMoreMenu"):
            with self.subTest(control=name):
                control = view(self.source, name)
                self.assertIn(".frame(width: 44, height: 44)", control)
                self.assertIn(".contentShape(Rectangle())", control)
                self.assertNotRegex(control, r"\.padding\([^\n]*-\d")
        # The row must preserve positive spacing even when Pulse and React show.
        footer = self.source.split("// Pulse follows up on what Hermes promised here:", 1)
        self.assertTrue(footer[0].rstrip().endswith("HStack(spacing: 4) {"))
        row = footer[1].split(".padding(.top, 2)", 1)[0]
        for name in ("PulseMessageMark", "MessageReactButton", "AssistantMessageActions", "ReadAloudButton", "AssistantMessageMoreMenu"):
            self.assertIn(name, row)
        self.assertNotRegex(row, r"\.padding\([^\n]*-\d")

    def test_disappearance_clears_copy_feedback_and_pending_timer(self):
        control = view(self.source, "AssistantMessageActions")
        disappear = re.search(r"\.onDisappear\s*\{([^}]+)\}", control).group(1)
        self.assertIn("resetTask?.cancel()", disappear)
        self.assertIn("resetTask = nil", disappear)
        self.assertIn("copied = false", disappear)
        copy = control.split("private func copyResponse()", 1)[1]
        self.assertLess(copy.index("resetTask?.cancel()"), copy.index("resetTask = Task"))
        self.assertLess(copy.index("guard !Task.isCancelled else { return }"), copy.index("copied = false"))


if __name__ == "__main__":
    unittest.main()
