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

    def test_view_that_reads_and_passes_on_an_object_still_needs_it(self):
        # KanbanTaskDetailView's shape: it reads the store and injects it
        # into a NavigationLink destination; its sheet still has to hand it
        # the store.
        found = problems("""
        struct Log: View {
            @EnvironmentObject private var store: KanbanStore
            var body: some View { Text(store.name) }
        }
        struct Detail: View {
            @EnvironmentObject private var store: KanbanStore
            var body: some View {
                NavigationLink { Log().environmentObject(store) } label: { Text(store.name) }
            }
        }
        struct Board: View {
            @StateObject private var store = KanbanStore()
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) { Detail() }
            }
        }
        """)
        self.assertEqual(len(found), 1)
        self.assertIn("needs KanbanStore", found[0])
        self.assertIn(".environmentObject(store)", found[0])

    def test_self_qualified_injection_counts(self):
        self.assertEqual(problems(APP_STATE_CHILD, """
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) {
                    Child().environmentObject(self.appState)
                }
            }
        }
        """), [])

    def test_helpers_are_followed_through_other_helpers(self):
        found = problems(APP_STATE_CHILD, """
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) { outerSheet }
            }
            private var outerSheet: some View {
                NavigationStack { innerContent }
            }
            private var innerContent: some View {
                Child()
            }
        }
        """)
        self.assertEqual(len(found), 1)

    def test_self_qualified_helper_is_followed(self):
        found = problems(APP_STATE_CHILD, """
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) { self.helperSheet }
            }
            private var helperSheet: some View { Child() }
        }
        """)
        self.assertEqual(len(found), 1)

    def test_helper_func_with_closure_typed_parameter_is_followed(self):
        found = problems(APP_STATE_CHILD, """
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown) { makeSheet(action: {}) }
            }
            private func makeSheet(action: @escaping () -> Void) -> some View {
                Child()
            }
        }
        """)
        self.assertEqual(len(found), 1)

    def test_a_sibling_sheets_injection_does_not_satisfy_this_one(self):
        # `.font(.body)` names `body`; the parent's body (and the other
        # sheet's injection in it) must not be pulled in as a helper.
        found = problems(APP_STATE_CHILD, """
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var a = false
            @State private var b = false
            var body: some View {
                VStack {
                    Color.clear.sheet(isPresented: $a) { Child().font(.body) }
                    Color.clear.sheet(isPresented: $b) { Child().environmentObject(appState) }
                }
            }
        }
        """)
        self.assertEqual(len(found), 1)
        self.assertIn("File1.swift:8", found[0])

    def test_needs_are_complete_whichever_view_of_a_cycle_is_walked_first(self):
        sources = {
            "File0.swift": check_sheet_environment.strip_comments(textwrap.dedent("""
            struct A: View {
                @EnvironmentObject private var appState: AppState
                var body: some View { B() }
            }
            struct B: View {
                var body: some View { A() }
            }
            """)),
        }
        index = check_sheet_environment.Index(sources)
        self.assertEqual(index.needs("A"), {"AppState"})
        self.assertEqual(index.needs("B"), {"AppState"})  # not the cut-short walk from A

    def test_multiline_and_raw_strings_are_blanked(self):
        stripped = check_sheet_environment.strip_comments(textwrap.dedent('''
        let a = """
            "quoted" Child() { .sheet(
            """
        let b = #"raw "Child()" text"#
        let c = Real()
        '''))
        self.assertNotIn("Child", stripped)
        self.assertNotIn(".sheet", stripped)
        self.assertIn("Real()", stripped)
        self.assertEqual(stripped.count("\n"), 6)  # line numbers survive

    def test_full_screen_cover_popover_and_content_label_are_checked(self):
        found = problems(APP_STATE_CHILD, """
        struct Parent: View {
            @EnvironmentObject var appState: AppState
            @State private var a = false
            @State private var b = false
            @State private var c = false
            var body: some View {
                VStack {
                    Color.clear.fullScreenCover(isPresented: $a) { Child() }
                    Color.clear.popover(isPresented: $b) { Child() }
                    Color.clear.sheet(isPresented: $c, content: { Child() })
                }
            }
        }
        """)
        self.assertEqual([p.split(": ")[1].split()[0] for p in found], [".fullScreenCover", ".popover", ".sheet"])

    def test_content_that_is_not_a_closure_is_reported(self):
        found = problems(APP_STATE_CHILD, """
        struct Parent: View {
            @State private var shown = false
            var body: some View {
                Color.clear.sheet(isPresented: $shown, content: makeChild)
            }
        }
        """)
        self.assertEqual(len(found), 1)
        self.assertIn("isn't a closure", found[0])

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


class CommandLineTests(unittest.TestCase):
    def test_a_root_without_swift_sources_fails(self):
        import contextlib
        import io
        import tempfile
        with tempfile.TemporaryDirectory() as empty, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(check_sheet_environment.main(["--repo-root", empty]), 1)
        self.assertIn("no Swift sources", out.getvalue())


class RepositoryTests(unittest.TestCase):
    def test_app_sources_inject_every_sheet_environment_object(self):
        sources = check_sheet_environment.load_sources(REPO_ROOT)
        self.assertTrue(sources, "no Swift sources found")
        self.assertEqual(check_sheet_environment.find_problems(sources), [])


if __name__ == "__main__":
    unittest.main()
