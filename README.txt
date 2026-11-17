Local run on Eric's Mac (iPhone 18 Pro Max, iOS 27.2, Xcode 27.2), branch claude/project-thread-guh5ib @ 3c4cca1.
All 9 scenes played; cut by cut-scenes.sh from "SCENE stop all". After needs-you the test failed at
DemoVideoTests.swift:279 ("No Bots tab") and the director's stop-recording timed out (recorder still running
15 s after SIGINT). Checked each cut's last frame against its end still: mixed-bots-home, chats-strip,
two-replying, room-across, reorder, needs-you match; room-approval ends slightly late; bots-home-layouts and
multiplayer run ~20 s late (they end in the next scene's setup). The raw .mov stays on the Mac for a recut.
