"""Regression coverage for scripts/check-fixed-text-sizes.py (fixed text size guard)."""

import textwrap
import unittest

from _util import load_module

check_fixed_text_sizes = load_module("check_fixed_text_sizes", "check-fixed-text-sizes.py")


def problems(text):
    return check_fixed_text_sizes.find_problems({"View.swift": textwrap.dedent(text)})


class FixedTextSizeTests(unittest.TestCase):
    def test_text_in_a_fixed_size_is_reported_at_the_font_line(self):
        found = problems("""
        Text("System")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.conduitAccent)
        """)
        self.assertEqual(len(found), 1)
        self.assertTrue(found[0].startswith("View.swift:3:"), found)

    def test_a_fixed_size_on_the_same_line_is_reported(self):
        self.assertEqual(len(problems('Text("A").font(.system(size: 12))\n')), 1)

    def test_text_styles_and_scaled_sizes_pass(self):
        self.assertEqual(problems("""
        Text("System")
            .font(.caption2.weight(.semibold))
        Text(line)
            .font(.system(size: currentLineSize, weight: .semibold))
        Text(initial)
            .font(.system(size: max(11, size * 0.42), weight: .semibold))
        Text(log)
            .font(.system(.caption2, design: .monospaced))
        """), [])

    def test_glyphs_are_left_alone(self):
        self.assertEqual(problems("""
        Image(systemName: "plus")
            .font(.system(size: 16, weight: .medium))
            .frame(width: 32, height: 32)
        """), [])

    def test_the_chain_ends_at_the_first_line_that_is_not_a_modifier(self):
        self.assertEqual(problems("""
        Text("Done")
            .font(.footnote)
        Image(systemName: "lock.fill")
            .font(.system(size: 8))
        """), [])

    def test_blank_and_comment_lines_keep_the_chain(self):
        self.assertEqual(len(problems("""
        Text("Title")

            // The label.
            .font(.system(size: 11))
        """)), 1)

    def test_a_text_argument_does_not_own_the_chain(self):
        self.assertEqual(problems("""
        Image(systemName: "plus").accessibilityLabel(Text("Add"))
            .font(.system(size: 16))
        """), [])

    def test_a_reason_over_two_comment_lines_exempts_the_text(self):
        self.assertEqual(problems("""
        // Fixed size: it sits inside the fixed 32 pt ring,
        // which the text must not outgrow.
        Text(percent)
            .font(.system(size: 9, weight: .semibold))
        """), [])

    def test_a_stated_reason_exempts_the_text(self):
        self.assertEqual(problems("""
        // Fixed size: it sits inside the fixed 32 pt ring.
        Text(percent)
            .font(.system(size: 9, weight: .semibold))
        """), [])


if __name__ == "__main__":
    unittest.main()
