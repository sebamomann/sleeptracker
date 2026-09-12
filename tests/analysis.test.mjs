import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NightAnalyser, DEFAULTS, keptMs, pct, median, clampDb, summarise } from '../public/analysis.js';
import { buildSilentWav } from '../public/silent-audio.js';
import { fadeEdges } from '../public/wav.js';

const SR = 16000;
const FRAME_SAMPLES = SR * DEFAULTS.FRAME_MS / 1000;   // 320
const rms = db => Math.pow(10, db / 20);

function makeAnalyser(t0 = 1_700_000_000_000) {
  return new NightAnalyser({ sampleRate: SR, t0 });
}

/** Feed `frames` 20 ms frames, 10 at a time, advancing an injected clock in lockstep. */
function run(a, frames, dbAt) {
  let total = 0, batch = [], now = a.t0;
  for (let f = 0; f < frames; f++) {
    batch.push(rms(dbAt(f * DEFAULTS.FRAME_MS / 1000)));
    total += FRAME_SAMPLES;
    if (batch.length === 10) {
      now += 10 * DEFAULTS.FRAME_MS;
      a.pushFrames(batch, total, now);
      batch = [];
    }
  }
  return a;
}

test('helpers', () => {
  assert.equal(clampDb(12), 0);
  assert.equal(clampDb(-400), -100);
  assert.equal(median([1, 2, 3, 4, 5]), 3);
  assert.equal(pct([], 0.5), -100, 'empty input must not produce NaN');
});

test('noise floor tracks the room, not the events in it', () => {
  const a = makeAnalyser();
  // 10 minutes of -58 dB room tone with a loud 6 s burst every 45 s.
  run(a, 10 * 60 * 50, t => ((t % 45) < 6 ? -30 : -58));
  assert.ok(Math.abs(a.floorDb - -58) <= 2, `floor ${a.floorDb} should sit near -58`);
  assert.equal(a.env.length, 600, 'one envelope sample per second');
});

test('gate finds the events and gets their boundaries right', () => {
  const a = makeAnalyser();
  run(a, 10 * 60 * 50, t => ((t % 45) < 6 ? -30 : -58));
  assert.equal(a.events.length, 14, '13 complete bursts + 1 still open at the end');

  const e = a.events[1];
  assert.equal(e.s, 45, 'event starts on the burst, not after the open-debounce');
  assert.equal(e.e, 51, 'event ends on the burst, not after the close-hold');
  assert.ok(Math.abs(e.peak - -30) <= 2, `peak ${e.peak} should be near -30`);
});

test('a quiet night produces no events at all', () => {
  const a = makeAnalyser();
  run(a, 5 * 60 * 50, () => -58);
  assert.equal(a.events.length, 0);
  assert.equal(a.realGaps.length, 0);
});

test('the gate follows a rising noise floor instead of latching open', () => {
  const a = makeAnalyser();
  // The room gets 20 dB louder halfway through — a fan kicking in, say. A fixed
  // threshold would fire continuously from that point on; a rolling floor adapts.
  run(a, 10 * 60 * 50, t => (t < 300 ? -70 : -50));
  assert.ok(a.floorDb > -55, 'floor should have followed the room up');
  assert.ok(keptMs(a.events) < 60_000,
    `adapted gate kept ${Math.round(keptMs(a.events) / 1000)}s; a latched one would keep ~300s`);
});

test('a suspended capture is recorded as real dead time', () => {
  const a = makeAnalyser();
  const batch = Array(10).fill(rms(-58));
  let total = 0, now = a.t0;
  const push = () => { total += 10 * FRAME_SAMPLES; a.pushFrames(batch, total, now); };

  for (let i = 0; i < 25; i++) { push(); now += 200; }   // 5 s of normal operation
  now += 30_000; push();                                  // 30 s with no audio at all

  assert.equal(a.realGaps.length, 1);
  assert.ok(Math.abs(a.realGaps[0].audioLostMs - 30_000) < 500);
  assert.ok(Math.abs(a.deadMs - 30_000) < 1000, `deadMs ${a.deadMs} should be ~30000`);
});

test('a throttled main thread is NOT counted as dead time', () => {
  const a = makeAnalyser();
  const batch = Array(10).fill(rms(-58));
  let total = 0, now = a.t0;
  const push = () => { total += 10 * FRAME_SAMPLES; a.pushFrames(batch, total, now); };

  for (let i = 0; i < 25; i++) { push(); now += 200; }
  // 5 s passes; the worklet kept capturing and flushes the backlog in one late message.
  total += 25 * 10 * FRAME_SAMPLES;
  now += 5_000; push();

  assert.equal(a.gaps.length, 1, 'the stall is still recorded...');
  assert.equal(a.realGaps.length, 0, '...but no audio was lost, so it is not a failure');
  assert.ok(a.deadMs < 1000, `deadMs ${a.deadMs} should be ~0`);
});

test('storage caps hold on a pathological night', () => {
  const a = new NightAnalyser({ sampleRate: SR, t0: 0, cfg: { MAX_EVENTS: 3 } });
  run(a, 5 * 60 * 50, t => ((t % 10) < 3 ? -20 : -70));
  assert.equal(a.events.length, 3, 'event list must not grow without bound');
});

test('keptMs adds the pre/post roll to every event', () => {
  const ms = keptMs([{ s: 0, e: 5 }, { s: 10, e: 12 }]);
  assert.equal(ms, 7000 + 2 * (DEFAULTS.PRE_ROLL_MS + DEFAULTS.POST_ROLL_MS));
});

/* ── summarise ────────────────────────────────────────────────────────────── */

const HOUR = 3600_000;
const T0 = Date.parse('2026-09-12T23:00:00Z');

function session(over = {}) {
  return { t0: T0, audioSec: 600, wallMs: 600_000, gaps: [], env: [], events: [],
           lastFrameAt: T0 + 600_000, ...over };
}

test('summarise: a session that ran to the end survived', () => {
  const r = summarise(session({
    audioSec: 8 * 3600, wallMs: 8 * HOUR, lastFrameAt: T0 + 8 * HOUR,
    endedAt: new Date(T0 + 8 * HOUR).toISOString(),
  }));
  assert.equal(r.survived, true);
  assert.ok(r.deadMs < 1000);
  assert.equal(r.diedAndStayedDead, false);
});

test('summarise: capture that dies and never resumes is NOT reported as survived', () => {
  // The regression this exists for. Every counter inside the analyser freezes when frames
  // stop arriving, so differencing them alone shows a short, perfectly healthy session —
  // which is exactly what an iPhone locking the screen produces.
  const r = summarise(session({ endedAt: new Date(T0 + 8 * HOUR).toISOString() }));
  assert.equal(r.survived, false, 'ten minutes of audio inside an eight-hour night is not a pass');
  assert.equal(r.diedAndStayedDead, true);
  assert.equal(r.stoppedAt, T0 + 600_000);
  assert.ok(Math.abs(r.wall - 8 * HOUR) < 1000, 'wall clock comes from the stop time');
  assert.ok(Math.abs(r.deadMs - (8 * HOUR - 600_000)) < 1000);
  assert.ok(Math.abs(r.trailingDeadMs - (8 * HOUR - 600_000)) < 1000);
});

test('summarise: an interrupted session falls back to its last save', () => {
  // No endedAt — the tab was evicted, so the newest save is the only evidence of how far
  // the night actually got.
  const r = summarise(session({ lastAliveAt: T0 + 3 * HOUR }));
  assert.ok(Math.abs(r.wall - 3 * HOUR) < 1000);
  assert.equal(r.survived, false);
  assert.equal(r.diedAndStayedDead, true);
});

test('summarise: a short session is flagged rather than judged', () => {
  const r = summarise(session({ audioSec: 30, wallMs: 30_000,
    lastFrameAt: T0 + 30_000, endedAt: new Date(T0 + 30_000).toISOString() }));
  assert.equal(r.tooShort, true);
  assert.equal(r.survived, false);
});

test('summarise: gaps mid-night are counted but do not imply a permanent death', () => {
  const r = summarise(session({
    audioSec: 8 * 3600 - 40, wallMs: 8 * HOUR, lastFrameAt: T0 + 8 * HOUR,
    endedAt: new Date(T0 + 8 * HOUR).toISOString(),
    gaps: [{ at: T0 + HOUR, ms: 40_000, audioLostMs: 40_000 },
           { at: T0 + 2 * HOUR, ms: 800, audioLostMs: 0 }],
  }));
  assert.equal(r.realGaps.length, 1, 'the 800 ms stall lost no audio');
  assert.equal(r.worstGapMs, 40_000);
  assert.equal(r.diedAndStayedDead, false, 'it recovered, so it did not stay dead');
  assert.equal(r.survived, false, '40 s of lost audio is still a failure');
});

test('summarise: tolerates a legacy session with no lastFrameAt', () => {
  const r = summarise({ t0: T0, audioSec: 600, wallMs: 600_000, gaps: [], env: [], events: [] });
  assert.equal(r.stoppedAt, null);
  assert.equal(r.diedAndStayedDead, false);
  assert.ok(Math.abs(r.wall - 600_000) < 1000);
});

/* ── the keep-alive carrier ───────────────────────────────────────────────── */

test('buildSilentWav produces a real, playable, non-silent track', () => {
  const b = Buffer.from(buildSilentWav({ seconds: 1, rate: 8000 }));

  assert.equal(b.toString('ascii', 0, 4), 'RIFF');
  assert.equal(b.toString('ascii', 8, 12), 'WAVE');
  assert.equal(b.toString('ascii', 36, 40), 'data');
  assert.equal(b.readUInt32LE(4), b.length - 8, 'RIFF size must cover everything after it');

  const rate = b.readUInt32LE(24), dataBytes = b.readUInt32LE(40);
  assert.equal(rate, 8000);
  assert.equal(b.readUInt16LE(34), 16, '16-bit samples');
  assert.equal(dataBytes, b.length - 44);

  // The regression: a zero-length track is not playback, and iOS will not keep a page
  // alive for one. This is what shipped first and silently invalidated the profile.
  assert.ok(dataBytes > 0, 'must contain actual samples');
  assert.equal(dataBytes / 2 / rate, 1, 'one second long');

  // ...and it must not be digital silence, which is equally disqualifying.
  let nonZero = 0;
  for (let i = 44; i < b.length; i += 2) if (b.readInt16LE(i) !== 0) nonZero++;
  assert.equal(nonZero, dataBytes / 2, 'every sample is non-zero');

  let peak = 0;
  for (let i = 44; i < b.length; i += 2) peak = Math.max(peak, Math.abs(b.readInt16LE(i)));
  assert.equal(peak, 1, 'one LSB — -90 dBFS, inaudible but not silent');
});

test('buildSilentWav honours its duration', () => {
  const b = Buffer.from(buildSilentWav({ seconds: 0.5, rate: 16000 }));
  assert.equal(b.readUInt32LE(40) / 2 / 16000, 0.5);
});

test('a recorder started mid-sound does not close the gate on that sound', () => {
  // The floor window starts empty, so the first seconds are the only evidence of what the
  // room sounds like. If a loud opening is taken as the floor, the threshold rises above
  // the sound in progress and the gate shuts roughly a close-hold later — truncating
  // exactly the event that was loud enough to start the recording.
  const a = makeAnalyser();
  run(a, 60 * 50, t => (t < 8 ? -26 : -58));

  assert.ok(a.events.length >= 1, 'the opening sound must produce an event');
  const first = a.events[0];
  assert.ok(first.e - first.s > 6,
    `opening event lasted ${(first.e - first.s).toFixed(1)}s; the sound ran 8s`);
});

test('the floor still converges on the room once the window fills', () => {
  const a = makeAnalyser();
  run(a, 5 * 60 * 50, t => (t < 8 ? -26 : -58));
  assert.ok(Math.abs(a.floorDb - -58) <= 2,
    `floor ${a.floorDb} should settle on the room, not the loud opening`);
});

/* ── edge fades ───────────────────────────────────────────────────────────── */

test('fadeEdges ramps both ends to silence and leaves the middle alone', () => {
  const rate = 16000, ms = 40;
  const s = new Float32Array(rate);      // one second of full-scale DC
  s.fill(1);
  fadeEdges(s, rate, ms);

  const n = rate * ms / 1000;            // 640 samples
  assert.ok(Math.abs(s[0]) < 1e-6, 'first sample must be silent');
  assert.ok(Math.abs(s[s.length - 1]) < 1e-6, 'last sample must be silent');
  assert.ok(s[Math.floor(n / 2)] > 0.3 && s[Math.floor(n / 2)] < 0.7, 'monotonic ramp in');
  assert.equal(s[rate / 2], 1, 'the middle is untouched');

  // Monotonic, so the ramp cannot introduce a discontinuity of its own.
  for (let i = 1; i < n; i++) assert.ok(s[i] >= s[i - 1], `ramp dipped at ${i}`);
});

test('fadeEdges does not over-fade a clip shorter than two ramps', () => {
  const s = new Float32Array(100); s.fill(1);
  fadeEdges(s, 16000, 40);                // 640-sample ramp into a 100-sample clip
  assert.ok(Math.abs(s[0]) < 1e-6);
  assert.ok(s.some(v => v > 0.9), 'something must survive in the middle');
});

test('fadeEdges tolerates a clip too short to ramp at all', () => {
  const s = new Float32Array(1); s.fill(1);
  assert.doesNotThrow(() => fadeEdges(s, 16000, 40));
  assert.equal(s[0], 1);
});

test('a three-second pause stays inside one event', () => {
  // The behaviour asked for: breathing and snoring arrive in bursts, and a pause between
  // them is part of the same episode, not a reason to start a new file.
  const a = makeAnalyser();
  // 2 s loud, 3 s quiet, 2 s loud, then a long silence to close it.
  run(a, 60 * 50, t => {
    if (t < 2) return -26;
    if (t < 5) return -58;
    if (t < 7) return -26;
    return -58;
  });
  assert.equal(a.events.length, 1, 'the 3 s pause must not split the event');
  assert.ok(a.events[0].e >= 7, `event ended at ${a.events[0].e}s, expected to span to 7s`);
});

test('a pause longer than the close hold still separates events', () => {
  const a = makeAnalyser();
  run(a, 60 * 50, t => {
    if (t < 2) return -26;
    if (t < 12) return -58;      // 10 s — well past CLOSE_MS
    if (t < 14) return -26;
    return -58;
  });
  assert.equal(a.events.length, 2, 'a 10 s gap is two episodes');
});
