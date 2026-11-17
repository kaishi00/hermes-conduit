Local run on Eric's Mac (iPhone 18 Pro Max, iOS 27.2, Xcode 27.2), branch claude/project-thread-guh5ib @ a489dca.
The test failed in room-across (DemoVideoTests.swift:480, "Send message" button not found), so it never
printed "SCENE stop all" and cut-scenes.sh cut nothing. The five finished scenes here were cut afterwards
with a stop mark calibrated by eye (reorder's end frame), with 6 s lead/tail padding instead of 0.5 s, since
recordVideo's timeline drifts a few seconds between scenes. Trim before use. Marks used: videos/approx-cut.marks.
