# AGENTS.md

Records the sounds of a night, keeps only what isn't silence, labels it on-device, and shows
a report in the morning.

Two halves that share one algorithm:

| Half | What it is |
|---|---|
| `ios/` | **The product.** A native iOS app — the only thing that can record a locked iPhone |
| `public/`, `server.mjs` | The web survival spike that proved the browser *cannot*, deployed via Jenkins |
| `recorder/` | A Node recorder for any always-on machine, sharing `public/analysis.js` verbatim |

## Commands

`make` is the front door for both halves; `make help` lists everything.

```sh
make check      # lint + test + dupes + build — run before finishing every task
make fix        # autocorrect the mechanical half
make project    # regenerate the Xcode project after adding/moving any Swift file
make tools      # install the Swift toolchain, and warn if it drifts from CI
```

`npm test` still runs the analysis suite directly; `package.json` covers the JS half only.
Neither half's package manager is in charge of the other.

SwiftLint also runs as an Xcode **build phase**, so violations appear as warnings beside the
code on every ⌘B — non-strict there, strict in CI.

## Structure

```
public/analysis.js        THE GATE — noise floor, hysteresis, gaps, quiet gaps. Tested.
public/wav.js             WAV encoder + edge fades
recorder/                 Node bedside recorder (arecord/sox/ffmpeg → the gate)
tests/                    node:test suites for the above
ios/SleepTracker/
  App/                    tab shell, entry point
  Design/                 colours, ONE spacing scale, semantic type roles, ALL date formats
  Model/                  NightSession (the file format), derived summaries, value types
  Audio/                  capture, session policy, gate, ring, event writing, orchestration
  Analysis/               classifier, transcriber, quiet gaps, highlight ranking
  Storage/                nights on disk; NightsStore is the ONLY place marks are mutated
  Views/                  Record/ Nights/ Favourites/ Shared/
```

## Rules that are not obvious from the code

**`public/analysis.js` is the source of truth for the gate.** It has the test suite; the
Swift in `ios/SleepTracker/Audio/NoiseGate.swift` and `Analysis/QuietGaps.swift` are ports.
Change and test there **first**, then port, and keep the constants in step. A tuning change
made only in Swift is untested by definition.

**Never use raw spacing, fonts or date formats in a view.** `Layout`, the semantic `Font`
roles and `Fmt` exist because card padding was once 12/13/14/16 and six views each had their
own `DateFormatter` that had already drifted. Add to `Design/` instead.

**The thresholds are learned, not written down.** `Calibration` moves the gate toward
whatever produces the target events per hour, and sets the absolute floor from the peaks the
room actually produces — the part that genuinely cannot be guessed, since it is set by
microphone gain and by how far the phone sleeps from the bed. It is proportional in octaves,
capped at 2 dB a night so one noisy night cannot swing it, and bounded at both ends. Change
the rules in `calibrate()` in `public/analysis.js`, where a test asserts it converges rather
than oscillates, then port. Each night records the values it ran with, so an old night can
be read against its own settings.

**An event has to clear three rules, not one.** Prominence above the rolling floor was the
only test, and one real night produced 102 events of which most were rustles and room tone:
in a quiet room the floor sits so low that anything clears it, and pre/post roll turns a
150 ms tick into a four-second file that sounds like silence. `MIN_EVENT_MS` and
`MIN_PEAK_DB` are the other two, and rejections are counted into the session so a wrong
threshold is visible rather than silent. `Relevance` is the after-the-fact version for
nights recorded before a rule changed; it never touches anything marked, transcribed, or
recognised as snoring, speech or coughing.

**Never show a raw classifier identifier.** Apple's model knows ~300 general-purpose sounds
at ordinary listening levels; a night recording is quiet, close and mostly breathing, so it
falls back on whichever class attracts most. Everything user-facing goes through `SoundKind`,
which maps its output into the handful of things that happen in a bedroom and returns
`unclear` for anything unconvincing. `unclear` is honest; `music` at 3am is not. A correction
made by ear (`userKind`) beats the model outright and is exported by `TrainingExport` as
Create ML training data; `EventClassifier` prefers a bundled `SleepSounds.mlmodelc` over
Apple's and records which one it used.

**`music` means the classifier gave up.** It is what SoundAnalysis reaches for when a clip
carries too little information to identify, so a low-confidence catch-all label on a quiet
clip is "nothing happened", not a finding. See `Relevance.vagueLabels`.

**Playback is amplified, files are not.** Sleep audio peaks around −30 dBFS and is inaudible
played back untouched, and `AVAudioPlayer.volume` cannot exceed 1.0 — hence AVAudioEngine
with an EQ node lifting each clip toward −6 dBFS using its recorded peak. `peakDb` stays the
true measurement; the boost lives only in the signal path.

**The spectral ramp is for data only.** `Theme.spectrum` — violet, cyan, mint, amber — paints
bars, chart fills and classifier output, and nothing else. Structure, labels and chrome stay
greyscale, which is what leaves the numbers as the only colour on a screen. `Theme.gap` sits
deliberately outside the ramp so a warning can never be mistaken for a measurement. The app
is dark-committed; there is no light mode, by choice.

**The recording screen answers to different rules from everything else.** It has its own
ground (`NightGround`) and a single ink token (`Theme.nightInk`, currently cool teal). It is
the only screen looked at in the dark, so anything added there stays dim and low-contrast.
Switching back to the dim red it used to have is one token.

**Animation goes through `Motion`, and must yield to Reduce Motion.** Use `Motion.quick`,
`.standard`, `.gentle` or `.springy`, and either `.motion(_:value:)` or
`withAnimation(Motion.respecting(...))` — never a bare `Animation` literal. Two speeds for
two situations: anything you touch responds in under 200 ms, while anything to do with going
to sleep takes its time. The recording screen is looked at in a dark bedroom, so motion
there stays slow and low-contrast; a bright or fast effect on that screen is a bug.

**New `NightSession` or `EventRecord` fields must be optional.** Synthesised `Codable` does
not fall back to a property's default for a missing key — it throws. A non-optional `Bool`
makes every previously recorded night unreadable.

**Three threads meet in `Audio/`, and the boundaries are the design.** The audio thread
delivers samples and must never wait on anything; `AnalysisPipeline` owns the gate, ring and
health counters on its own serial queue; `io` encodes, classifies and writes. Putting slow
work on the analysis queue stalls capture and drops audio — that bug has been made twice.

**Liveness comes from the sample counter, never a timer.** A suspended app's timers stop
too, so a timer-based heartbeat cannot distinguish "frozen" from "not scheduled". And a
session's *end* must come from outside the audio thread (`endedAt` or `lastAliveAt`):
capture that dies and never resumes freezes every counter with it, and differencing frozen
counters reports a short, perfectly healthy night. `summarise()` owns this and is tested.

**Everything stays on the phone.** There is no networking code in the iOS target, and
transcription sets `requiresOnDeviceRecognition`. Do not add uploads without asking.

**Quiet gaps are observation, not diagnosis.** Keep the on-screen wording that says so.

## Build and deploy facts

- `ios/SleepTracker.xcodeproj` and `ios/SleepTracker/Info.plist` are **generated** from
  `ios/project.yml` and gitignored. Add plist keys to `project.yml`; editing the generated
  plist silently loses them on the next `xcodegen generate`. That once dropped
  `UIBackgroundModes`, which would have shipped an app that stops recording on screen lock.
- `DEVELOPMENT_TEAM` is pinned in `project.yml` because XcodeGen rewrites the project and
  drops whatever Xcode's signing pane had. Command-line signed builds also need Xcode
  running, or they fail with `No Account for Team`; use `CODE_SIGNING_ALLOWED=NO` to
  type-check without signing, and ⌘R for anything that must reach the device.
- Free personal team: the app expires after **7 days**, re-signed with ⌘R (wirelessly —
  the phone is paired over `localNetwork`). Recorded nights survive; it is an upgrade
  install.
- `xcodebuild` will not resolve an iOS destination unless the iOS platform is installed
  (`xcodebuild -downloadPlatform iOS`, ~8.5 GB). Do not delete simulator runtimes to tidy
  up — doing so removed both and cost the download twice.
- The web half deploys on push to `main`: branch-scoped Docker resources, immutable
  `sleeptracker:<branch>-<build>` tag, health-checked rollout with rollback, port `34257`.

## Tooling traps

- **Tool versions must move together.** `SWIFTLINT_VERSION` in the `Makefile` and the image
  tag in the `Jenkinsfile` are the same number, and `make tools` warns when the local
  install drifts. This was `swiftlint:latest` in CI, which meant an upstream release could
  fail a build containing no change of ours.
- **jscpd does not scan Swift by default.** `format` in `.jscpd.json` must list `swift`
  explicitly, or all 43 files are skipped while the report still reads `0 clones`.
- **SwiftFormat's `modifierOrder` is disabled** because SwiftLint wants the opposite order
  and each run undid the other. One tool per concern.
- SwiftLint thresholds are set **where the code already sits**, so a violation means
  something changed. Fix the code, don't relax the config.

## Settled by measurement — do not re-litigate

- **Browser audio capture cannot survive a locked iPhone.** Measured three times on iOS
  26.6.1: `audiocontext: interrupted` fires ~120–190 ms *before* `visibility: hidden`, so
  the OS revokes the audio session rather than throttling the page. 98.7% and 99.6% dead
  air. Playback survives (that is why YouTube works); capture is gated separately, and no
  keep-alive, PWA install or third-party browser changes it.
- **Code signing is mandatory on iOS** — it is the OS refusing to run unsigned binaries,
  not an App Store rule. Free provisioning satisfies it at no cost.
- **AAC/m4a, not Opus.** On iOS, Opus means a CAF container nothing outside Apple's stack
  opens. 32 kbps mono AAC is ~a tenth of WAV and is read natively by the classifier and the
  transcriber.

## Definition of done

1. Gate or analysis change? `public/analysis.js` + a test first, then port to Swift.
2. Added or moved a Swift file? `make project`.
3. `make check` — 0 violations, 0 clones, all tests passing, unsigned build succeeds.
4. Say plainly what was **not** verified. On-device behaviour, classifier accuracy on real
   bedroom audio, and anything needing signing cannot be checked from a terminal.
