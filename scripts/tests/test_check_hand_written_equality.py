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

    def test_a_generic_equality_counts_too(self):
        self.assertEqual(check.count("static func == <Other: Equatable>(lhs: Self, rhs: Other) -> Bool { false }"), 1)

    def test_comments_and_strings_are_not_code(self):
        self.assertEqual(check.count("/* static func == (lhs: A, rhs: A) -> Bool { true } */"), 0)
        self.assertEqual(check.count("/* outer /* nested */ static func == (l: A, r: A) -> Bool { true } */"), 0)
        self.assertEqual(check.count('let doc = "static func == (lhs: A, rhs: A)"'), 0)
        self.assertEqual(check.count('let doc = """\nstatic func == (lhs: A, rhs: A)\n"""'), 0)
        self.assertEqual(check.count('let raw = #"a \\" static func == ( "#'), 0)
        self.assertEqual(check.count('let raw = ##"a "# static func == ( "##'), 0)
        self.assertEqual(check.count('let raw = #"""\nstatic func == (lhs: A, rhs: A)\n"""#'), 0)
        self.assertEqual(check.count('let url = "https://x"; static func == (lhs: A, rhs: A) -> Bool { true }'), 1)

    def test_a_comment_between_the_words_still_counts(self):
        self.assertEqual(check.count("static /* by identity */ func == (lhs: A, rhs: A) -> Bool { true }"), 1)
        self.assertEqual(check.count("static func // the operator\n    == (lhs: A, rhs: A) -> Bool { true }"), 1)

    def test_an_interpolation_stays_code_and_its_string_closes(self):
        text = 'let s = "a \\(f("x")) b"\nstatic func == (lhs: A, rhs: A) -> Bool { true }'
        self.assertEqual(check.count(text), 1)
        raw = 'let s = #"a \\#(f("x")) \\(b) "#\nstatic func == (lhs: A, rhs: A) -> Bool { true }'
        self.assertEqual(check.count(raw), 1)

    def test_the_wrappers_file_holds_only_the_wrappers(self):
        three = "static func == (l: A, r: A) -> Bool { true }\n" * 3
        self.assertEqual(check.find_problems({check.WRAPPERS: three}, allowed={}), [])
        problems = check.find_problems({check.WRAPPERS: three + NONISOLATED}, allowed={})
        self.assertIn("expected 3", problems[0])

    def test_synthesized_and_commented_pass(self):
        self.assertEqual(check.find_problems({"Conduit/A.swift": SYNTHESIZED}, allowed={}), [])

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
