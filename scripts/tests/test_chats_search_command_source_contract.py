"""Linux source-contract checks for #1925; not keyboard or SwiftUI evidence.

These read the view's source for which field each branch focuses and for the
pending-focus handoff. They cannot press Command-F, and focus behaviour in
either bar layout is only observable on a simulator or a device.
"""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHATS = ROOT / "Conduit/Views/V2/V2ChatsView.swift"


def block(source, name):
    """The declaration of a private func or var, up to the next one."""
    for kind in ("func", "var"):
        marker = f"private {kind} {name}"
        if marker in source:
            start = source.index(marker)
            end = source.find("\n    private ", start + 1)
            return source[start:end if end != -1 else len(source)]
    raise AssertionError(f"no private func or var named {name}")


class ChatsSearchCommandSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = CHATS.read_text()

    def test_the_shortcut_is_command_f_on_the_chats_view(self):
        command = block(self.source, "searchCommand")
        self.assertIn('keyboardShortcut("f", modifiers: .command)', command)
        self.assertIn("focusSearchFromKeyboard()", command)
        self.assertIn(".background { searchCommand }", self.source)

    def test_the_pending_flag_is_only_set_for_a_closed_stacked_bar(self):
        body = block(self.source, "focusSearchFromKeyboard")
        guard = body.index("if barStacked == true, !showsBarSearch {")
        pending = body.index("barSearchFocusPending = true")
        direct = body.index("searchFocused = true", guard)
        self.assertLess(guard, pending)
        self.assertLess(pending, direct)
        # Every other branch focuses the field on screen directly.
        self.assertIn("barSearchFocusPending = false", body)

    def test_un_stacking_hands_the_pending_focus_to_the_list_field(self):
        body = block(self.source, "barUnstacked")
        guard = body.index("if barSearchFocusPending {")
        cleared = body.index("barSearchFocusPending = false", guard)
        handed = body.index("searchFocused = true", guard)
        self.assertLess(guard, cleared)
        self.assertLess(cleared, handed)

    def test_a_cover_clears_the_pending_focus_as_well_as_the_field(self):
        # A chat pushed over the list puts the keyboard away; a request set
        # in the same transaction must not be waiting when the list returns.
        shown = self.source[self.source.index(".onChange(of: isShown, initial: true)"):]
        shown = shown[:shown.index(".onChange(of: appState.activeSessionId)")]
        self.assertIn("if !shown {", shown)
        self.assertIn("searchFocused = false", shown)
        self.assertIn("barSearchFocusPending = false", shown)

    def test_the_one_row_layout_reuses_the_same_focus_state(self):
        # Both fields bind one @FocusState, which is what lets a request move
        # between them at a layout change.
        self.assertEqual(self.source.count(".focused($searchFocused)"), 1)
        self.assertIn("searchCapsule(minHeight: 40)", block(self.source, "searchField"))
        self.assertIn("searchCapsule(minHeight: 44)", block(self.source, "barSearchField"))


if __name__ == "__main__":
    unittest.main()
