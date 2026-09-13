# sleeptracker

Records the sounds of a night, keeps only the parts that aren't silence, classifies them,
and gives you a timeline you can play back in the morning.

**Status: phase 0 — the survival spike.** It stores no audio. It measures whether browser
audio capture survives a locked phone, and what your bedroom's noise floor is. Both
answers are needed before any of the rest is worth building.

Working on this repo: **[AGENTS.md](AGENTS.md)** carries the rules that are not obvious
from the code — which half owns the gate, the threading contract, the Codable trap, the
tooling gotchas, and what has already been settled by measurement so it is not re-litigated.

## Layout

| Path | What |
|---|---|
| `public/index.html` | The app — one page, three screens (setup / recording / report) |
| `public/analysis.js` | Noise floor, gate and gap detection. Pure, no DOM, injected clock |
| `tests/analysis.test.mjs` | Tests for the above, incl. simulated OS suspensions |
| `public/wav.js` | 16-bit PCM WAV encoder, shared by the browser and the recorder |
| `ios/` | The iOS recorder — `UIBackgroundModes: audio`, gate ported from `analysis.js` |
| `recorder/record.mjs` | Bedside recorder — captures, gates, writes one WAV per event |
| `recorder/ring.mjs` | Rolling PCM history, so a closed event can still be cut out |
| `server.mjs` | Production server: static files + `/api/health`. Stdlib only |
| `scripts/dev-https.mjs` | Local HTTPS with a self-signed cert, for testing on a phone |
| `Dockerfile` · `Jenkinsfile` · `ci/` | Build and deploy, same shape as the plants repo |

No dependencies, no build step.

## Local

```sh
make help             # every target
make check            # lint + test + dupes + iOS build

npm start             # http://localhost:3000 — a secure context, so the mic works
npm run dev:https     # https://<your-lan-ip>:8443 — for testing on the phone
```

`getUserMedia` needs a secure context: `localhost` or HTTPS, no exceptions. `dev:https`
generates a self-signed cert into `certs/` on first run (gitignored); the phone warns once
— *Show Details → visit this website* on Safari, *Advanced → Proceed* on Chrome. Once
deployed behind the real certificate this stops being a problem.

## Deploy

Mirrors the plants pipeline: multibranch, branch-scoped Docker resources, an immutable
`sleeptracker:<branch>-<build>` tag built once and carried through to deploy, health-checked
rollout with rollback to the previous container, and `ci/prune-images.sh` on every build.

Differences from plants, all because this app is smaller: no database, no Playwright stage,
no npm cache volumes (there are no dependencies), and no volume mounts — the app is
stateless, since a night's data lives in the phone's `localStorage` until phase 2 adds an
upload endpoint.

Container port 3000 is published on **34257** on the host.

### Host setup

Already in place: the GitHub remote, the multibranch pipeline job (script path
`Jenkinsfile`), and the vhost pointing at the container.

GitHub commit-status reporting is deliberately absent — the plants pipeline posts build
status back to the PR via `githubNotify`, this one does not. Add it back by copying that
repo's `Notify: Pending` stage and `post { success / failure / aborted }` blocks, plus a
Jenkins credential holding a token with `repo:status`.

Push to `main` and the pipeline builds, tests, smoke-tests and deploys.

## The recorder

iOS revokes the microphone the moment the screen locks (see below), so the thing that
actually records a night is a small always-on machine, not a phone. The recorder runs the
**same analysis module** as the browser spike — same gate, same rolling floor, same
thresholds — but outside a sandbox, so it keeps the audio.

```sh
node recorder/record.mjs                 # until Ctrl-C
node recorder/record.mjs --minutes 5     # short trial
node recorder/record.mjs --source stdin  # f32le PCM from a pipe, for testing
```

Capture backend, first one found: `arecord` (ships with Raspberry Pi OS — a Pi needs
nothing installed), then `sox`, then `ffmpeg`. Output:

```
nights/2026-09-12-23-00/
  session.json          envelope, gaps, event index, noise floor
  events/0001-231407.wav  one file per event, 16 kHz mono, pre/post-rolled
```

A night of real snoring lands in the low tens of MB as WAV. Re-encoding to Opus at 24 kbps
cuts that by roughly 10× and is the next step, along with uploading to this server.

## The night

1. Open the site on the phone. Add to home screen if you want it standalone.
2. Plug the phone in.
3. Pick **Baseline** for night one — no keep-alive tricks. That is the measurement.
4. Press **Start recording**, grant mic access, **lock the phone**, go to sleep.
5. Morning: unlock, press **Stop recording**. On the keep-alive profile you can also stop
   from the lock screen.

If the browser evicted the tab overnight, the data is still there — reopen the page and it
offers the interrupted session's report. A night that died is still a result.

## Where the result lives

Nothing is sent anywhere — the night is held in the phone's `localStorage` and the report
renders from it locally.

- **Normal morning:** unlock, press **Stop recording**. The report appears.
- **The tab was evicted overnight:** reopen the page. It offers the interrupted session's
  report from the last save (every 10 s, plus one forced save the moment the screen locks,
  so at most 10 s is ever missing).
- **Getting it onto a real screen:** **Copy JSON** or **Download JSON** on the report, then
  open it on the Mac with *open a saved JSON* on the start screen. Reports render entirely
  client-side, so the file opens unchanged on any device.
- **Live console output while it runs:** iPhone Settings → Safari → Advanced → Web
  Inspector, connect by cable, then Safari on the Mac → Develop → your phone. This survives
  the screen locking and is the only way to watch it die in real time.
- **Deploy logs:** the Jenkins job. Nothing about a night's recording goes through it.

## Reading the report

| Reading | Means |
|---|---|
| Dead time under ~30 s | Survived a locked screen. Build phase 1 as a PWA. |
| "Capture died at HH:MM and never came back" | The OS suspended the page and never resumed it — the expected iOS result. |
| A gap starting within seconds of `visibility: hidden` | The OS suspended capture on lock. Go native. |
| Many stalls, zero audio lost | Main thread throttled, capture fine. Harmless. |
| Suggested gate | Use as `GATE_DB` in phase 1 — and in Swift, if it comes to that. |
| "Would have kept" | Over ~10% of the night means the gate is too sensitive. |

Dead time is derived from the worklet's sample counter, not from a timer, because a
throttled main thread makes every timer lie — a stalled `setInterval` looks exactly like a
dead recorder otherwise. The session's *end*, though, has to come from outside the audio
thread (the stop timestamp, or the last save), because capture that stops and never resumes
freezes every counter inside the analyser along with it — and differencing frozen counters
reports a short, perfectly healthy night. `summarise()` in `public/analysis.js` owns that
distinction and is tested against it.

### iOS — measured, three times

Three runs on iOS 26.6.1, all with the same signature:

```
audiocontext: interrupted   4.30s
visibility:   hidden        4.43s   <- 122ms LATER
```

The audio session is torn down *before* the page lifecycle registers anything, so this is
not page throttling to work around — the OS revokes the session. 98.7% and 99.6% of those
sessions were dead air.

iOS governs playback and capture separately: a page that only plays audio keeps the
`playback` category and continues while locked, which is why YouTube works. Calling
`getUserMedia` switches the session to `playAndRecord`, and that category is interrupted on
background. There is no web equivalent of `UIBackgroundModes: audio`, in a tab or an
installed PWA, and a native app needs a code signature to run at all — signing is an OS
requirement, not an App Store one.

Hence the recorder above.

## Tunables

`DEFAULTS` at the top of `public/analysis.js`:

| Const | Default | Effect |
|---|---|---|
| `GATE_DB` | 12 | dB above the rolling floor before an event opens |
| `OPEN_MS` | 150 | debounce before opening — raise to reject clicks and pops |
| `CLOSE_MS` | 4000 | quiet before closing. Breathing and snoring arrive in bursts; a short hold chops one episode into unlistenable fragments |
| `PRE_ROLL_MS` | 4000 | kept before the gate opened, so events don't start mid-snore |
| `POST_ROLL_MS` | 4000 | kept after it closed. May exceed `CLOSE_MS` — the cut waits for the tail |
| `FADE_MS` | 40 | raised-cosine ramp at each edge. A clip starts at an arbitrary sample, and that step is audible as a click |
| `FLOOR_WIN_S` | 60 | rolling window for the noise floor; tracks fans and traffic |
| `FLOOR_WARMUP_S` | 10 | before which the floor may fall but never rise |

Capture is 16 kHz mono (YAMNet's native rate) with `echoCancellation`, `noiseSuppression`
and `autoGainControl` all **off** — with them on, AGC renormalises levels so the floor is
meaningless and noise suppression deletes exactly the quiet sounds we're hunting for.
