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
  `"seed": false` is only sent live by the preview recording; a bot's turn
  with `"seed": false` is only answered live (the promo's message and its
  work updates).
- A new screen: add a `snap("NN-name")` step to the test. Wait for real
  content before snapping; the hosted Mac is slow.
- Message times read just before the 9:41 status bar because the test runs
  the app in a matching time zone (`timeZoneNearStatusBarTime`).
- Keep markdown out of the first line of answers that show as previews (bot
  list, chat list).

## Promo footage

`.github/workflows/app-store-promo.yml` records the footage the App Store's
promo loops (the product page header and the search result video) are cut
from. Run it from Actions > App Store promo footage > Run workflow; `device`
takes a simulator name (iPhone 17 Pro Max by default).

- The dashboard plays `promo-script.json` instead (`DEMO_SCRIPT`): the
  anime's bots, Conduit Chan, Piko, Mira and Riri, with their pictures from
  `portraits/` (a bot's `"avatar"`, stored with `profiles.set_asset` as
  Conduit does), and Hermes with the app icon. `"approvals": "manual"` sets
  that bot's own approval mode, so its workstreams' risky steps ask in
  Conduit; `"workstreams": true` turns the notifier on in every bot's profile
  and restarts Hermes, so the Bot Chats coordinate work; `"files"` are empty
  files the scripted tool calls work on.
- The scripted Bot Chat calls the work tools through `tool_call`, as a real
  model does when Hermes keeps them behind Tool Search. A workstream's turns
  match on its brief (`<title>); the user can open it`), and the Bot Chat's
  work updates on words from their reports, so the order of a bot's `turns`
  matters: the first match wins.
- `testRecordPromo` signs in, opens Conduit Chan from Bots Home, asks her to
  plan a Kyoto weekend, waits while two workstreams run, approves the photo
  cleanup from the Work panel and goes back to Bots Home, while
  `simctl io recordVideo` records the whole walk. Its `PROMO_MARK` lines land
  in `promo.marks` beside `promo.mov`, with the recorder's start time, to cut
  by. Then `record-clip.sh` records the live voice fixtures
  (`clips/voice-listening.mp4`, `clips/voice-speaking.mp4`).
- Results, under `refs/app-store-shots/<run id>-promo`, in `shots/`:
  `promo.mov` (dropped when over 90 MB; `promo-full-NN.mp4` are the same at
  full resolution, 90 s each, and a part over 90 MB is dropped too),
  `promo.mp4` (1920 px high), `promo.marks`, `stills/` (the test's
  `promo-*` screenshots, named from the result's manifest) and `clips/`; in
  `logs/`, Hermes' and xcodebuild's logs, the app's own log (`app-log.txt`)
  and `probe_bot_routes.py`'s answers from the runner before and after the
  walk (`probe-bots-before.txt`, `probe-bots.txt`), for a walk that stopped short.
