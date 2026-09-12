/**
 * A rolling window of the most recent audio, addressed by absolute sample index.
 *
 * The gate only closes CLOSE_MS after a sound ends, and events want PRE_ROLL seconds of
 * lead-in — so by the time an event is known, its opening is already in the past. This
 * keeps enough history to cut it back out, and drops everything older.
 */
export class SampleRing {
  constructor({ capacity }) {
    this.capacity = capacity;   // samples to retain
    this.chunks = [];           // {start, data} in ascending order, no gaps
    this.written = 0;           // absolute index one past the newest sample
  }

  get oldest() { return this.chunks.length ? this.chunks[0].start : this.written; }

  push(data) {
    this.chunks.push({ start: this.written, data });
    this.written += data.length;
    const keepFrom = this.written - this.capacity;
    // Drop whole chunks that have fallen entirely out of the window. Partial chunks stay:
    // trimming them would cost a copy per push to reclaim a bounded overshoot.
    while (this.chunks.length && this.chunks[0].start + this.chunks[0].data.length <= keepFrom) {
      this.chunks.shift();
    }
  }

  /**
   * Samples in [from, to), clamped to what is still retained. Returns an empty array if the
   * range has already scrolled out — callers must treat that as "too late", not as silence.
   */
  slice(from, to) {
    const lo = Math.max(from, this.oldest);
    const hi = Math.min(to, this.written);
    if (hi <= lo) return new Float32Array(0);

    const out = new Float32Array(hi - lo);
    for (const { start, data } of this.chunks) {
      const end = start + data.length;
      if (end <= lo || start >= hi) continue;
      const a = Math.max(lo, start), b = Math.min(hi, end);
      out.set(data.subarray(a - start, b - start), a - lo);
    }
    return out;
  }
}
