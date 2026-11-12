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

# File -> the prompts of the bare `.searchable(` calls it may make, and why.
# Matched by prompt, not by count, so a page's search can't take a sheet's place.
BARE_SEARCH = {
    # The drawer shell (V2 off) has no tab bar.
    "Conduit/Views/SidebarView.swift": [
        "Search projects and pinned chats",
        "Search archived conversations",
        "Search scheduled jobs",
    ],
    # Add a provider is a sheet.
    "Conduit/Views/ProviderSettingsViews.swift": ["Search providers"],
    # The task composer's skill and parent-task pickers are sheets.
    "Conduit/Views/Kanban/KanbanTaskComposerView.swift": ["Search skills", "Search tasks"],
}

# The pages that can show with the tabs up and search.
PAGE_SEARCH = [
    "Conduit/Views/Capabilities/SkillHubViews.swift",
    "Conduit/Views/Capabilities/PluginCatalogViews.swift",
    "Conduit/Views/Capabilities/HostedAppsViews.swift",
    "Conduit/Views/ModelChooserPage.swift",
    "Conduit/Views/V2/V2ArtifactsViews.swift",
]


class PageSearchSourceContractTests(unittest.TestCase):
    def test_page_search_sits_under_the_title(self):
        source = SHELL.read_text()
        start = source.index("func pageSearchable(")
        body = source[start:source.index("func ", start + 1)]
        self.assertIn("placement: .navigationBarDrawer(displayMode: .always)", body)

    def test_the_pages_under_the_tabs_search_through_it(self):
        for page in PAGE_SEARCH:
            with self.subTest(page=page):
                self.assertIn(".pageSearchable(", (ROOT / page).read_text())

    def test_only_screens_without_the_tabs_search_bare(self):
        found = {}
        for path in sorted((ROOT / "Conduit").rglob("*.swift")):
            for line in path.read_text().splitlines():
                if ".searchable(" in line:
                    prompt = re.search(r'string\("([^"]+)"(?:, table: \.\w+)?\)', line)
                    found.setdefault(str(path.relative_to(ROOT)), []).append(
                        prompt.group(1) if prompt else line.strip()
                    )
        self.assertEqual(
            found,
            BARE_SEARCH,
            "A page that can show with the tabs up searches with pageSearchable; "
            "a bare .searchable is only for a sheet or the drawer shell (add it to BARE_SEARCH).",
        )


if __name__ == "__main__":
    unittest.main()
