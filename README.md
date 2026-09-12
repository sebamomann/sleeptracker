# sleeptracker

Records the sounds of a night, keeps only the parts that aren't silence, classifies them,
and gives you a timeline you can play back in the morning.

**Status: phase 0 — the survival spike.** It stores no audio. It measures whether browser
audio capture survives a locked phone, and what your bedroom's noise floor is. Both
answers are needed before any of the rest is worth building.

## Layout

| Path | What |
|---|---|
| `public/index.html` | The app — one page, three screens (setup / recording / report) |
| `public/analysis.js` | Noise floor, gate and gap detection. Pure, no DOM, injected clock |
| `tests/analysis.test.mjs` | Tests for the above, incl. simulated OS suspensions |
| `server.mjs` | Production server: static files + `/api/health`. Stdlib only |
| `scripts/dev-https.mjs` | Local HTTPS with a self-signed cert, for testing on a phone |
| `Dockerfile` · `Jenkinsfile` · `ci/` | Build and deploy, same shape as the plants repo |

No dependencies, no build step.

## Local

```sh
npm test              # the analysis suite
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

## The night

1. Open the site on the phone. Add to home screen if you want it standalone.
2. Plug the phone in.
3. Pick **Baseline** for night one — no keep-alive tricks. That is the measurement.
4. Press **Start recording**, grant mic access, **lock the phone**, go to sleep.
5. Morning: unlock, press **Stop recording**. On the keep-alive profile you can also stop
   from the lock screen.

If the browser evicted the tab overnight, the data is still there — reopen the page and it
offers the interrupted session's report. A night that died is still a result.

## Reading the report

| Reading | Means |
|---|---|
| Dead time under ~30 s | Survived a locked screen. Build phase 1 as a PWA. |
| A gap starting within seconds of `visibility: hidden` | The OS suspended capture on lock. Go native. |
| Many stalls, zero audio lost | Main thread throttled, capture fine. Harmless. |
| Suggested gate | Use as `GATE_DB` in phase 1 — and in Swift, if it comes to that. |
| "Would have kept" | Over ~10% of the night means the gate is too sensitive. |

Dead time is derived from the worklet's sample counter, not from a timer, because a
throttled main thread makes every timer lie — a stalled `setInterval` looks exactly like a
dead recorder otherwise.

### iOS

iOS suspends microphone capture when the screen locks, and there is no background-audio
permission for web pages. The app detects iOS and says so up front. The spike is still
worth running there: it confirms the failure and measures your noise floor, which is the
number a native recorder needs anyway.

## Tunables

`DEFAULTS` at the top of `public/analysis.js`:

| Const | Default | Effect |
|---|---|---|
| `GATE_DB` | 12 | dB above the rolling floor before an event opens |
| `OPEN_MS` | 150 | debounce before opening — raise to reject clicks and pops |
| `CLOSE_MS` | 1500 | silence before closing — raise to merge snores into one event |
| `ROLL_MS` | 3000 | pre + post roll added to each event's size estimate |
| `FLOOR_WIN_S` | 60 | rolling window for the noise floor; tracks fans and traffic |

Capture is 16 kHz mono (YAMNet's native rate) with `echoCancellation`, `noiseSuppression`
and `autoGainControl` all **off** — with them on, AGC renormalises levels so the floor is
meaningless and noise suppression deletes exactly the quiet sounds we're hunting for.
