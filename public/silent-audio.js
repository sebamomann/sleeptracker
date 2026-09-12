// A looping media element is the only way a web page can ask iOS for background audio, and
// it only counts if the OS considers it genuine playback. The first attempt here was a
// zero-length WAV at volume 0 — a track with no samples, silenced — which is disqualified
// on both counts and made the keep-alive profile untestable.
import { encodeWav } from './wav.js';

const LSB = 1 / 0x7fff;

/**
 * A WAV of near-silence: real samples, at one LSB of amplitude.
 *
 * Not digital silence and not muted, deliberately. An all-zero or muted track is a
 * candidate for being treated as inaudible, and inaudible playback is not what earns
 * background audio. One LSB of a 16-bit sample is -90 dBFS: inaudible to a person,
 * non-zero to the OS.
 */
export function buildSilentWav({ seconds = 1, rate = 8000 } = {}) {
  const n = Math.round(seconds * rate);
  const samples = new Float32Array(n);
  for (let i = 0; i < n; i++) samples[i] = i % 2 ? LSB : -LSB;
  return encodeWav(samples, rate);
}

export function silentWavUrl(opts) {
  return URL.createObjectURL(new Blob([buildSilentWav(opts)], { type: 'audio/wav' }));
}
