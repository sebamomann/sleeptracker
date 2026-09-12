// A looping media element is the only way a web page can ask iOS for background audio, and
// it only counts if the OS considers it genuine playback. The first attempt here was a
// zero-length WAV at volume 0 — a track with no samples, silenced — which is disqualified
// on both counts and made the keep-alive profile untestable.

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
  const buf = new ArrayBuffer(44 + n * 2);
  const v = new DataView(buf);
  const ascii = (off, str) => {
    for (let i = 0; i < str.length; i++) v.setUint8(off + i, str.charCodeAt(i));
  };

  ascii(0, 'RIFF');   v.setUint32(4, 36 + n * 2, true);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true);        // PCM
  v.setUint16(22, 1, true);        // mono
  v.setUint32(24, rate, true);
  v.setUint32(28, rate * 2, true); // byte rate
  v.setUint16(32, 2, true);        // block align
  v.setUint16(34, 16, true);       // bits per sample
  ascii(36, 'data');  v.setUint32(40, n * 2, true);

  for (let i = 0; i < n; i++) v.setInt16(44 + i * 2, i % 2 ? 1 : -1, true);
  return buf;
}

export function silentWavUrl(opts) {
  return URL.createObjectURL(new Blob([buildSilentWav(opts)], { type: 'audio/wav' }));
}
