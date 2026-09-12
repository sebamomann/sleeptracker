# SleepTracker — iOS recorder

The native recorder. iOS revokes the microphone the moment the screen locks for web
content; a native app with `UIBackgroundModes: audio` keeps recording. That key is an
Info.plist declaration, **not** a signed entitlement, so none of this needs a paid account.

The gate is a direct port of `public/analysis.js` — same constants, same rolling floor,
same hysteresis, same warmup rule, same edge fades. Keep the two in step when tuning; the
JS side is the one with the test suite, so change and test there first.

| Folder | What |
|---|---|
| `App/` | The tab shell and app entry point |
| `Design/` | Colours, one spacing scale, semantic type roles, every date format |
| `Model/` | `NightSession` (the file format), its derived summaries, value types |
| `Audio/` | Capture, session policy, the gate, the ring, event writing, orchestration |
| `Analysis/` | Classifier, transcriber, quiet gaps, highlight ranking |
| `Storage/` | Nights on disk, and the one place marks are mutated |
| `Playback/` · `System/` | Event playback; the bedtime reminder |
| `Views/` | `Record/`, `Nights/`, `Favourites/`, `Shared/` |

Three threads meet in `Audio/`, and the boundaries are the design: the **audio thread**
delivers samples and never waits on anything; **`AnalysisPipeline`** owns the gate, ring and
health counters on its own serial queue; **`io`** encodes, classifies and writes, which takes
long enough that sharing a queue with the audio path would drop capture.

## Build it (free Apple ID, no payment)

1. Install **Xcode** from the App Store. Free, ~15 GB, macOS only.
2. Generate the project:
   ```sh
   brew install xcodegen
   cd ios && xcodegen generate && open SleepTracker.xcodeproj
   ```
   Or skip XcodeGen: *File → New → Project → iOS App*, name it `SleepTracker`, delete the
   generated `ContentView.swift`/`*App.swift`, drag in the files from `ios/SleepTracker/`,
   and add the two Info.plist keys from `Info.plist` by hand.
3. In Xcode: select the target → **Signing & Capabilities** → **Team** → *Add an
   Account…* → sign in with your ordinary Apple ID. It appears as **(Personal Team)**.
   Leave signing on Automatic.
4. Plug in the iPhone, pick it as the run destination, press **⌘R**.
5. First launch only: on the phone, **Settings → General → VPN & Device Management** →
   trust your developer certificate.

Recordings land in the app's Documents directory as `nights/<date>/events/NNNN-HHMMSS.wav`.

## The 7-day expiry

Within the window the app is completely normal — microphone, background capture, all of it.
Nothing degrades over the 7 days; at the end the app simply refuses to launch until it is
re-signed. Re-sign on day 5 or 6 rather than finding out at bedtime on day 8; signing early
costs nothing, the clock restarts from that moment.

Three ways to do it, none needing a cable after the first pairing:

| | Cable | Automatic | Mac running |
|---|---|---|---|
| **Xcode over Wi-Fi** | once, to pair | no — you press ⌘R | yes, Xcode open |
| **AltStore + AltServer** | once | **yes**, in the background | yes, on the same Wi-Fi |
| **SideStore** | once, to pair | yes | **no** |

**Xcode over Wi-Fi.** Pair the phone over USB once, then *Window → Devices and Simulators* →
tick **Connect via network**. After that ⌘R deploys wirelessly. Same bundle ID means an
upgrade, not a fresh install — **your recorded nights are preserved**.

**AltStore**, to stop thinking about it entirely. AltServer refreshes the signature in the
background whenever the phone is on the same Wi-Fi. It installs `.ipa` files, and
*Product → Archive → Distribute* cannot produce one here — that path wants a distribution
certificate a free team does not have. `ios/scripts/make-ipa.sh` builds for device and
wraps the result instead:

```sh
sh ios/scripts/make-ipa.sh      # → ios/build/SleepTracker.ipa
```

AirDrop it to the phone and open it with AltStore. (Written against the documented
procedure but **not run** — there is no Xcode on the machine it was written on.)

Re-signing the same app does not consume new App IDs — the 10-per-week limit applies to
*distinct* bundle identifiers, not rebuilds.

The $99 Developer Program changes this one number to a year. It buys nothing else this app
uses: background audio, microphone access and SoundAnalysis are all available to a free
personal team.

## Verify the premise first

Before building anything on top, confirm the thing the whole plan rests on:

1. Run the app, press **Start recording**.
2. **Lock the phone.** Leave it 5 minutes. Talk near it once or twice.
3. Unlock, press stop.

If events appear with timestamps from while the screen was locked, background capture works
on a free personal team and the rest of the roadmap is unblocked. If it does not, say so
before spending more time — that is the one assumption in this plan that could not be
tested from a terminal.

## Quality gates

```sh
npm run check        # tests, then all three linters
npm run lint:fix     # autocorrect what is mechanical
```

| Tool | Catches | Config |
|---|---|---|
| SwiftLint | complexity, file/type/function length, naming, smells | `.swiftlint.yml` |
| SwiftFormat | formatting only | `.swiftformat` |
| jscpd | copy-paste across Swift *and* the JS side | `.jscpd.json` |

All three run in CI and fail the build. Two things worth knowing if you touch the configs:

- SwiftLint's thresholds are set **where the code already sits**, so a violation means
  something changed rather than that the bar was never met. That is what makes `--strict`
  fair rather than noise everyone learns to ignore.
- jscpd needs `format` to list `swift` explicitly. It is not in the default set, and without
  it the entire app is silently skipped while the report still reads `0 clones`.
- `modifierOrder` is disabled in SwiftFormat because SwiftLint wants the opposite order, and
  with both enabled each run undid the other. One tool per concern.

Install the Swift pair once: `brew install swiftlint swiftformat`. jscpd runs via `npx`.

## Audio format

Events are AAC in `.m4a` at 32 kbps mono — roughly a tenth the size of the WAVs this
originally wrote, and ample for 16 kHz speech and snoring. **Not Opus**, despite Opus being
the better codec on paper: on iOS it means a CAF container nothing outside Apple's stack
will open, while `.m4a` plays everywhere and is read natively by both the classifier and
the transcriber.

## Everything is local

No networking code exists in this target. Audio, labels and transcripts stay in the app's
Documents directory. Transcription sets `requiresOnDeviceRecognition`, so not even Apple's
speech servers see it.

## Next

- Retention: prune nights automatically once there are enough to be worth pruning
- Upload to the deployed web app, if a big-screen viewer ever beats the phone
