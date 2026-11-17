# App Store screenshots and previews

`.github/workflows/app-store-screenshots.yml` captures the App Store set on a
hosted Mac: iPhone 6.9" and iPad 13" screenshots, a 30 s App Preview for each,
and Apple Watch call screens. Run it from Actions > App Store screenshots >
Run workflow. Pick any branch, so a branch with iPad or Watch UI changes can be
captured before it merges. The `devices` and `watch` inputs take simulator
names.

Results:
- Artifact `app-store-screenshots`: one folder per device with `01-chats.png`
  and the rest, `preview-<device>.mp4` (ready to upload) and the raw
  `preview-<device>.mov`. Artifact `app-store-watch-screenshots` holds
  the Watch shots, including the approval card (`04-approval.png`).
- `clips/`: short silent MP4s for the README and hermesconduit.app, recorded
  by `record-clip.sh` from the same fixtures: `voice-<device>.mp4` (the live
  voice orb mid-reply, 10 s) in each device's run, and `watch-speaking.mp4`
  and `watch-approval.mp4` (8 s) in the Watch run. Each clip's recorder log
  sits beside it as `clips/<name>.log`. The script needs ffmpeg; both jobs
  install it. A failed phone clip is listed with the other missing screens at
  the end of the run; the Watch job has no such list, so it fails its own step
  after trying both clips.
  The README's strip uses animated WebP copies in `docs/media/`:
  `clips/voice-iPhone-17-Pro-Max.mp4` becomes `voice.webp`, and the two Watch
  clips keep their names. For the iPhone clip:
  `ffmpeg -i clips/voice-iPhone-17-Pro-Max.mp4 -vf "fps=12,scale=270:-1:flags=lanczos" -c:v libwebp_anim -loop 0 -q:v 60 docs/media/voice.webp`
  (`scale=200` and `-q:v 70` for the Watch clips).
- Artifact `app-store-logs`: the demo Hermes, seeding, preview recorder and
  xcodebuild logs. `app-store-watch-logs` holds the Watch build log. The clip
  recorder logs travel with the clips in the screenshots artifacts.
- Git ref `refs/app-store-shots/<run id>` (and `<run id>-watch`) with the same
  files minus large raw videos, for sessions that can't download artifacts:
  `git fetch origin refs/app-store-shots/<id> && git archive FETCH_HEAD | tar -x`.
  The capture jobs only read the repository; they upload these files as the
  one-day `app-store-shots-ref*` artifacts, and the `publish` job pushes them.

## How it works

1. `start-demo-hermes.sh` installs Hermes Agent at a pinned commit with the
   Conduit notifier plugin, turns on password sign-in, and serves the
   dashboard at `http://hermes.tail-demo.ts.net:9119` (an `/etc/hosts` name,
   so the app's Tailscale rules allow plain HTTP).
2. The model is `llm_stub.py`, an OpenAI-compatible server that replays
   `demo-script.json`: each turn's `match` text picks the scripted reasoning,
   tool calls and answer, and chat titles come from the script too.
3. `seed_demo.py` creates the bots and chats through the gateway's own RPC,
   the way Conduit does. `seed_board.py` stages the Kanban board, and the
   start script adds the scheduled jobs.
4. `ConduitScreenshots/AppStoreScreenshotTests.swift` signs in, walks the
   screens and saves each as a named attachment. Live voice screens use the
   DEBUG-only `-conduitScreenshotCall listening|speaking` fixture
   (`Conduit/Services/ScreenshotCallFixture.swift`); the Watch job launches the
   Watch app with the same argument (`home|speaking|listening|approval`;
   `ended` and `approvalDenyOnly` also exist).
5. `testRecordPreview` runs while `simctl io recordVideo` records; its
   `PREVIEW_MARK` lines and the recorder's stop time let `cut-preview.sh` cut
   the 30 s preview.

## Changing what's shown

- Chats, bots, tasks and scheduled jobs: edit `demo-script.json`. A chat with
  `"seed": false` is only sent live by the preview recording.
- A new screen: add a `snap("NN-name")` step to the test. Wait for real
  content before snapping; the hosted Mac is slow.
- Message times read just before the 9:41 status bar because the test runs
  the app in a matching time zone (`timeZoneNearStatusBarTime`).
- Keep markdown out of the first line of answers that show as previews (bot
  list, chat list).

## Demo videos

`.github/workflows/demo-videos.yml` records the scenes for release posts and
App Store material, one MP4 per scene, from a single run on a hosted Mac.
Nothing is filmed by hand: real Hermes with a scripted model, on a
simulator, no production Hermes or physical device. Run it from
Actions > Demo videos > Run workflow; `scenes` picks which scenes to cut
(all by default), `devices` the simulators.

It starts demo dashboards on the runner: **Home**
(`http://hermes.tail-demo.ts.net:9119`) and **Studio**
(`http://studio.tail-demo.ts.net:9129`), each from its own script in
`videos/` (`home.json`, `studio.json`) and sharing one Hermes checkout, and
Sam for the multiplayer scene (below). Each gateway runs under a loop that
starts it again if it exits, since Hermes' liveness watchdog can stop one
while the app builds on the busy runner.
`link-demo-hermes.sh` starts a rooms mailbox on the runner from the notifier
repo and links the two as the owner's own Hermes, so a room can hold bots from
both. Studio starts with `DEMO_ROOM_GUEST=1`, which runs `conduit-push rooms setup`
for each of its profiles (an API server with keys) and restarts its gateway, so
Home lists Studio's bots as ready to join a room; the link step waits until
it does. A drag in the test presses again when the press opened the bot's
menu or scrolled the grid instead of lifting it. Both ask for approvals (`DEMO_APPROVALS=manual`): Home for Mira's publish
in the room it hosts, Studio for Chibi's in Needs you. Their seeded turns run
nothing that asks, and `seed_demo.py` refuses a seeded tool call on an instance
that asks; tool calls go in `replies`, sent while the video records.

`ConduitScreenshots/DemoVideoTests.swift` signs in to Home, adds Studio and
combines the two, and plays the scenes while `simctl io recordVideo` runs.
Each scene prints `SCENE start <name>` and `SCENE end <name>` with the time,
and `cut-scenes.sh` cuts the recording at those marks, so the setup between
scenes never shows. What changes on a dashboard mid-scene comes from
`demo_director.py`, a small server on the runner the test calls: `add-bot`
creates a bot the script marks `"later"` (Bots Home going from one bot to
four), and `prompt` sends a line in a bot's chat so it works on its own (a
second bot replying, an approval that shows up in Needs you). At the end the
test calls `stop-recording`, so the video ends at its last mark, which is
what `cut-scenes.sh` dates the recording from.
The recording repeats a few frame times, after which ffmpeg would fall back
to packet times that lag by up to 44 s, so the cut reads it with
`-fflags +igndts`. The cut uses only the marks; the stills at each scene's
start and end (`scene-<name>-start.png`, `-end.png`) are there to check it
against.

The scenes: `bots-home-layouts`, `mixed-bots-home`, `chats-strip`,
`two-replying`, `reorder`, `room-across`, `room-approval`, `multiplayer`,
`needs-you`.

The multiplayer scene adds a third dashboard, **Sam**
(`http://sam.tail-demo.ts.net:9139`, `videos/sam.json`): another person's
Hermes, linked to Home as someone else (`link-demo-hermes.sh link` with
`OWN=0`), never added to the app. The test makes the room in New Group Chat
(Conduit-chan, inviting Sam), the director's `join-room` has Sam join with
his bot Nori by the plugin's CLI, and `room-say` posts Sam's lines the way
his Conduit would (`POST /rooms/copies/messages`), so the room shows two
people and a bot each. `start-room` makes such a room without the app.

Results: artifact `demo-videos` (`<device>/<scene>.mp4`, the raw recording and
stills at the start and end of each scene in `stills/`), and the git ref
`refs/demo-videos/<run id>` with the same minus the raw recording (and any scene
over 90 MB, past what git takes), for
sessions that can't download artifacts.
Each run makes its own ref; delete old ones with `git push --delete`.
The workflow's steps also run by hand on a Mac of your own, which takes
about 25 minutes with a warm Xcode build, against about two hours hosted.

Bot pictures come from `avatars/<name>.png` (256 px), uploaded the way the app
uploads one. A turn sent live rather than seeded goes under `"replies"`, and
`"system_has"` picks which bot answers when several hear the same words in a
room. A script can borrow chats from another with `"include_chats"`.
