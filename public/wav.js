// One WAV writer, used by the browser's keep-alive carrier and by the Node recorder.

/** 16-bit PCM WAV from float samples in [-1, 1]. */
export function encodeWav(samples, rate) {
  const n = samples.length;
  const buf = new ArrayBuffer(44 + n * 2);
  const v = new DataView(buf);
  const ascii = (off, str) => {
    for (let i = 0; i < str.length; i++) v.setUint8(off + i, str.charCodeAt(i));
  };

  ascii(0, 'RIFF');  v.setUint32(4, 36 + n * 2, true);
  ascii(8, 'WAVE');
  ascii(12, 'fmt '); v.setUint32(16, 16, true);
  v.setUint16(20, 1, true);         // PCM
  v.setUint16(22, 1, true);         // mono
  v.setUint32(24, rate, true);
  v.setUint32(28, rate * 2, true);  // byte rate
  v.setUint16(32, 2, true);         // block align
  v.setUint16(34, 16, true);        // bits per sample
  ascii(36, 'data'); v.setUint32(40, n * 2, true);

  for (let i = 0; i < n; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    // Rounded, not truncated. Truncation biases every sample toward zero, and at the
    // amplitudes the keep-alive carrier uses it rounds a one-LSB tone away entirely:
    // 1/32767 stored as float32 is a hair under, so ×32767 truncates to silence.
    v.setInt16(44 + i * 2, Math.round(s < 0 ? s * 0x8000 : s * 0x7fff), true);
  }
  return buf;
}

/**
 * Ramp the first and last `ms` of a clip to silence, in place.
 *
 * A gated clip starts and ends at an arbitrary sample, so its first and last values are
 * almost never zero — and a waveform that jumps straight to a non-zero value is a step
 * discontinuity, which is heard as a click at both ends of every event. A raised-cosine
 * ramp removes it without audibly shortening anything.
 */
export function fadeEdges(samples, rate, ms = 40) {
  const n = Math.min(Math.round(rate * ms / 1000), Math.floor(samples.length / 2));
  if (n < 1) return samples;
  for (let i = 0; i < n; i++) {
    const g = 0.5 - 0.5 * Math.cos(Math.PI * i / n);
    samples[i] *= g;
    samples[samples.length - 1 - i] *= g;
  }
  return samples;
}
