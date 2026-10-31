"""Regression coverage for scripts/check-transcript-environment.py (transcript rows' environment guard)."""

import unittest

from _util import load_module

check = load_module("check_transcript_environment", "check-transcript-environment.py")

CELL = check.CELL_ENVIRONMENT

KEYS = """
extension EnvironmentValues {
    var chatRowState: ChatRowState {
        get { self[ChatRowStateKey.self] }
        set { self[ChatRowStateKey.self] = newValue }
    }
    @Entry var markdownReferences: [String: URL] = [:]
}
"""


ROWS = """
struct Row: View {
    var body: some View {
        Text(verbatim: "").environment(\\.markdownReferences, [:])
    }
}
"""


def cell(set_in_init=("chatRowState",), applied=("chatRowState",), set_inside=("markdownReferences",)):
    lines = [
        "struct TranscriptCellEnvironment {",
        "    static let setInsideRows = [" + ", ".join(f'"{key}"' for key in set_inside) + "]",
        "    init(_ values: EnvironmentValues, disclosure: ChatRowDisclosure?) {",
    ]
    lines += [f"        {key} = values.{key}" for key in set_in_init]
    lines += [
        "    }",
        "}",
        "private struct Applied: ViewModifier {",
        "    let values: TranscriptCellEnvironment",
        "    func body(content: Content) -> some View {",
        "        content",
    ]
    lines += [f"            .environment(\\.{key}, values.{key})" for key in applied]
    lines += ["    }", "}", ""]
    return "\n".join(lines)


def problems(keys=KEYS, rows=ROWS, **kwargs):
    return check.find_problems({"Conduit/Keys.swift": keys, "Conduit/Rows.swift": rows, CELL: cell(**kwargs)})


class TranscriptEnvironmentTests(unittest.TestCase):
    def test_every_key_copied_or_set_inside_the_rows_passes(self):
        self.assertEqual(problems(), [])

    def test_a_key_that_reaches_no_row_is_reported_where_it_is_declared(self):
        found = problems(keys=KEYS + "extension EnvironmentValues {\n    @Entry var chatCompact: Bool = false\n}\n")
        self.assertEqual(len(found), 1)
        self.assertTrue(found[0].startswith("Conduit/Keys.swift: \\.chatCompact reaches no transcript row"), found)

    def test_a_key_set_but_not_applied_is_reported(self):
        found = problems(applied=())
        self.assertEqual(found, [f"{CELL}: \\.chatRowState is set in the init but never applied to the rows"])

    def test_a_key_applied_but_not_set_is_reported(self):
        # The modifier's own `values.chatRowState` is no copy of the chat's.
        found = problems(set_in_init=())
        self.assertEqual(found, [f"{CELL}: \\.chatRowState is applied to the rows but never set in the init"])

    def test_a_listed_key_conduit_does_not_declare_is_reported(self):
        found = problems(set_inside=("markdownReferences", "gone"))
        self.assertEqual(found, [f"{CELL}: setInsideRows lists gone, which Conduit doesn't declare"])

    def test_a_listed_key_nothing_sets_is_reported(self):
        found = problems(rows="")
        self.assertEqual(found, [f"{CELL}: setInsideRows lists markdownReferences, which nothing in Conduit sets"])

    def test_only_the_extensions_own_members_are_keys(self):
        keys = KEYS + """
extension EnvironmentValues {
    static var fallback: Int { 0 }
    var derived: Int {
        var total: Int = 0
        return total
    }
    // var commented: Bool
}
"""
        found = problems(keys=keys)
        self.assertEqual(len(found), 1, found)
        self.assertIn("\\.derived reaches no transcript row", found[0])

    def test_a_list_in_a_comment_is_not_the_one_read(self):
        source = cell(set_inside=()).replace(
            "    static let setInsideRows = []",
            '    // static let setInsideRows = ["markdownReferences"]\n    static let setInsideRows = []',
        )
        found = check.find_problems({"Conduit/Keys.swift": KEYS, "Conduit/Rows.swift": ROWS, CELL: source})
        self.assertEqual(len(found), 1, found)
        self.assertIn("\\.markdownReferences reaches no transcript row", found[0])

    def test_a_missing_cell_environment_fails(self):
        self.assertEqual(len(check.find_problems({"Conduit/Keys.swift": KEYS})), 1)


if __name__ == "__main__":
    unittest.main()
