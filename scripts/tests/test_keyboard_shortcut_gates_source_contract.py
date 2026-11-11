"""Linux source-contract checks for #2224; not keyboard or SwiftUI evidence.

A hidden or covered chat stays mounted and keeps its field's focus, and a
SwiftUI shortcut ignores opacity, so a chat's own keys are gated in source:
on the shell's `chatTakesKeys`, on a Bot Chat coming over the chat, and on
nothing presented in front. These read the views for those gates. They can't
press a key; that's only observable on an iPad or a Mac.
"""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def read(relative):
    return (ROOT / relative).read_text()


class KeyboardShortcutGatesSourceContractTests(unittest.TestCase):
    def test_stop_waits_for_the_chat_on_screen_and_nothing_in_front(self):
        chat = read("Conduit/Views/ChatView.swift")
        self.assertIn(".keyboardShortcut(ConduitKeyboardShortcut.stop.shortcut)", chat)
        self.assertIn(".disabled(!shell.chatTakesKeys || appState.botChatComingOverAnother != nil)", chat)
        stop = chat[chat.index("func stopFromKeyboard"):]
        self.assertIn("guard KeyboardCommands.nothingInFront", stop[:400])

    def test_return_keys_skip_a_hidden_covered_or_bot_chat_covered_composer(self):
        bar = read("Conduit/Views/Components/ComposerBar.swift")
        self.assertIn("shell.chatTakesKeys && !updates.inputs.botChatComing", bar)
        self.assertIn("canSubmitFromReturn: returnKeysReachChat &&", bar)
        updates = read("Conduit/Views/Components/ComposerUpdates.swift")
        self.assertIn("botChatComing = appState.botChatComingOverAnother != nil", updates)
        room = read("Conduit/Views/Components/GroupRoomComposer.swift")
        self.assertIn(
            "shell.chatTakesKeys && appState.botChatComingOverAnother == nil && (canSend || dictationHoldsSendSlot)",
            room,
        )

    def test_chat_list_and_artifacts_keys_wait_for_sheets_and_the_shown_chat(self):
        screen = read("Conduit/Views/V2/V2ConversationScreen.swift")
        self.assertIn("ConduitKeyboardShortcut.chatList.shortcut", screen)
        self.assertIn("ConduitKeyboardShortcut.artifacts.shortcut", screen)
        self.assertGreaterEqual(screen.count("guard KeyboardCommands.nothingInFront else { return }"), 2)
        self.assertIn(".disabled(!shell.chatTakesKeys)", screen)
        self.assertIn(".disabled(!shell.chatTakesKeys || appState.botChatComingOverAnother != nil)", screen)

    def test_chat_takes_keys_only_in_the_shown_uncovered_tab(self):
        shell = read("Conduit/Views/V2/V2Shell.swift")
        self.assertIn("isTabActive && !isChatCovered", shell)
        self.assertIn("$0.isChatCovered = !chatShown", shell)


if __name__ == "__main__":
    unittest.main()
