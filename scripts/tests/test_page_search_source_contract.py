"""Linux source-contract check for the pages' search field; not SwiftUI evidence.

iOS 26 puts a pushed page's `.searchable` field at the foot of an iPhone
screen, behind Conduit's floating tab bar and main button (the Skill Hub's
search, a tester's screenshot, 2026-11-11). Pages that can show with the tabs
up search through `pageSearchable`, which keeps the field under the title.
A bare `.searchable` is only for the screens listed here, where no tabs float
over the screen. Where the field lands is only observable on a simulator or a
device.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHELL = ROOT / "Conduit/Views/V2/V2Shell.swift"

# File -> how many bare `.searchable(` calls it may make, and why.
BARE_SEARCH = {
    # The drawer shell (V2 off) has no tab bar.
    "Conduit/Views/SidebarView.swift": 3,
    # Add a provider is a sheet.
    "Conduit/Views/ProviderSettingsViews.swift": 1,
    # The task composer's skill and parent-task pickers are sheets.
    "Conduit/Views/Kanban/KanbanTaskComposerView.swift": 2,
}


class PageSearchSourceContractTests(unittest.TestCase):
    def test_page_search_sits_under_the_title(self):
        source = SHELL.read_text()
        start = source.index("func pageSearchable(")
        body = source[start:source.index("\n    }\n", start)]
        self.assertIn("placement: .navigationBarDrawer(displayMode: .always)", body)

    def test_only_screens_without_the_tabs_search_bare(self):
        found = {}
        for path in sorted((ROOT / "Conduit").rglob("*.swift")):
            count = len(re.findall(r"\.searchable\(", path.read_text()))
            if count:
                found[str(path.relative_to(ROOT))] = count
        self.assertEqual(
            found,
            BARE_SEARCH,
            "A page that can show with the tabs up searches with pageSearchable; "
            "a bare .searchable is only for a sheet or the drawer shell (add it to BARE_SEARCH).",
        )


if __name__ == "__main__":
    unittest.main()
