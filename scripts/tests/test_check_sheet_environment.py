"""Regression coverage for scripts/check-sheet-environment.py (sheet environment guard)."""

import importlib.util
import os
import textwrap
import unittest

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(SCRIPTS_DIR)
SPEC = importlib.util.spec_from_file_location(
    "check_sheet_environment", os.path.join(SCRIPTS_DIR, "check-sheet-environment.py"))
check_sheet_environment = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_sheet_environment)

APP_STATE_CHILD = """
struct Child: View {
    @EnvironmentObject private var appState: AppState
    var body: some View { Text(appState.title) }
}
"""


def problems(*swift_files):
    sources = {
        f"File{i}.swift": check_sheet_environment.strip_comments(textwrap.dedent(text))
        for i, text in enumerate(swift_files)
    }
    return check_sheet_environment.find_problems(sources)


class SheetEnvironmentTests(unittest.TestCase):
    def test_uninjected_sheet_is_reported_with_the_fix(self):
        found = problems(APP_STATE_CHILD, """
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) {
                    Child()
                }
            }
        }
        """)
        self.assertEqual(len(found), 1)
        self.assertIn("needs AppState", found[0])
        self.assertIn(".environmentObject(appState)", found[0])

    def test_injected_sheet_passes(self):
        self.assertEqual(problems(APP_STATE_CHILD, """
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) {
                    Child()
                        .environmentObject(appState)
                }
            }
        }
        """), [])

    def test_need_is_found_through_intermediate_views(self):
        found = problems(APP_STATE_CHILD, """
        struct Middle: View {
            var body: some View { Child() }
        }
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) { Middle() }
            }
        }
        """)
        self.assertEqual(len(found), 1)

    def test_view_that_injects_its_own_object_satisfies_its_children(self):
        self.assertEqual(problems("""
        struct StoreChild: View {
            @EnvironmentObject private var store: KanbanStore
            var body: some View { Text(store.name) }
        }
        struct Board: View {
            @StateObject private var store = KanbanStore()
            var body: some View { StoreChild().environmentObject(store) }
        }
        struct Parent: View {
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) { Board() }
            }
        }
        """), [])

    def test_injecting_into_own_sheets_does_not_hide_the_views_own_need(self):
        # The build-199 crash shape: the drawer's SidebarView reads AppState
        # and injects it into its own nested sheets; the drawer sheet still
        # has to hand it AppState.
        found = problems(APP_STATE_CHILD, """
        struct Drawer: View {
            @EnvironmentObject var appState: AppState
            @State private var picker = false
            var body: some View {
                Text(appState.title).sheet(isPresented: $picker) {
                    Child().environmentObject(appState)
                }
            }
        }
        struct Root: View {
            @EnvironmentObject var appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) { Drawer() }
            }
        }
        """)
        self.assertEqual(len(found), 1)
        self.assertIn("File1.swift:15", found[0])  # Root's sheet, not the drawer's

    def test_content_after_on_dismiss_is_the_content_checked(self):
        found = problems(APP_STATE_CHILD, """
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown, onDismiss: { shown = false }) {
                    Child()
                }
            }
        }
        """)
        self.assertEqual(len(found), 1)

    def test_helper_property_content_is_followed(self):
        found = problems(APP_STATE_CHILD, """
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) { helperSheet }
            }
            private var helperSheet: some View {
                NavigationStack { Child() }
            }
        }
        """)
        self.assertEqual(len(found), 1)

    def test_injection_in_a_comment_does_not_count(self):
        found = problems(APP_STATE_CHILD, """
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) {
                    Child() // .environmentObject(appState)
                }
            }
        }
        """)
        self.assertEqual(len(found), 1)

    def test_plain_stored_reference_can_be_injected(self):
        self.assertEqual(problems(APP_STATE_CHILD, """
        struct CallScreen: View {
            let appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) {
                    Child().environmentObject(appState)
                }
            }
        }
        """), [])

    def test_sheet_without_environment_needs_passes(self):
        self.assertEqual(problems("""
        struct Plain: View {
            var body: some View { Text("Hi") }
        }
        struct Parent: View {
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) { Plain() }
            }
        }
        """), [])


class RepositoryTests(unittest.TestCase):
    def test_app_sources_inject_every_sheet_environment_object(self):
        sources = check_sheet_environment.load_sources(REPO_ROOT)
        self.assertTrue(sources, "no Swift sources found")
        self.assertEqual(check_sheet_environment.find_problems(sources), [])


if __name__ == "__main__":
    unittest.main()
