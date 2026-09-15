# sleeptracker

Records the sounds of a night on an iPhone, keeps only the parts that aren't silence, labels
them on-device, and gives you a report you can play back in the morning. Nothing leaves the
phone.

The app lives in **[`ios/`](ios/README.md)**, which covers building it on a free Apple ID, the
7-day re-signing, and the audio format. Working on this repo: **[AGENTS.md](AGENTS.md)** carries
the rules that are not obvious from the code.

```sh
make help       # every target
make check      # lint + tests + duplication + unsigned build
```

## Why native

This started as a web page. Measured three times on iOS 26.6.1, the browser cannot record a
locked phone: the audio session is revoked ~120 ms *before* the page even registers that it
was hidden, leaving 98.7% and 99.6% of those nights as dead air. Playback survives a lock —
which is why YouTube works — but capture is gated separately, and no keep-alive, PWA install
or third-party browser changes that. A native app with `UIBackgroundModes: audio` keeps
recording, and that is a plist key rather than a paid entitlement.

The web spike and a Node bedside recorder were removed once the app replaced them; both are in
git history.
