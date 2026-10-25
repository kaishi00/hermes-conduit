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
