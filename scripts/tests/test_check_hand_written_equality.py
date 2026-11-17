"""Regression coverage for scripts/check-hand-written-equality.py."""

import os
import unittest

from _util import load_module

check = load_module("check_hand_written_equality", "check-hand-written-equality.py")

HAND = """
struct Notice: Equatable {
    let id = UUID()
    let text: String
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
"""

NONISOLATED = """
extension Row: Equatable {
    nonisolated static func == (lhs: Row, rhs: Row) -> Bool { lhs === rhs }
}
"""

SYNTHESIZED = """
struct Notice: Equatable {
    let id = UUID()
    @EqualityIgnored var text: String
    // static func == (lhs: Self, rhs: Self) -> Bool { written once, by hand }
}
"""


class HandWrittenEqualityTests(unittest.TestCase):
    def test_a_new_hand_written_equality_fails(self):
        problems = check.find_problems({"Conduit/A.swift": HAND}, allowed={})
        self.assertEqual(len(problems), 1)
        self.assertIn("Conduit/A.swift: 1 hand-written", problems[0])

    def test_nonisolated_counts_too(self):
        self.assertEqual(check.count(NONISOLATED), 1)

    def test_synthesized_and_commented_pass(self):
        self.assertEqual(check.find_problems({"Conduit/A.swift": SYNTHESIZED}, allowed={}), [])

    def test_the_wrappers_file_is_exempt(self):
        self.assertEqual(check.find_problems({check.WRAPPERS: HAND + NONISOLATED}, allowed={}), [])

    def test_an_allowance_holds_and_only_shrinks(self):
        self.assertEqual(check.find_problems({"Conduit/A.swift": HAND}, allowed={"Conduit/A.swift": 1}), [])
        over = check.find_problems({"Conduit/A.swift": HAND + NONISOLATED}, allowed={"Conduit/A.swift": 1})
        self.assertIn("allowed 1", over[0])
        under = check.find_problems({"Conduit/A.swift": SYNTHESIZED}, allowed={"Conduit/A.swift": 1})
        self.assertIn("lower its entry", under[0])
        gone = check.find_problems({}, allowed={"Conduit/A.swift": 1})
        self.assertIn("not found", gone[0])

    def test_the_repository_passes(self):
        root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        self.assertEqual(check.find_problems(check.load_sources(root)), [])


if __name__ == "__main__":
    unittest.main()
