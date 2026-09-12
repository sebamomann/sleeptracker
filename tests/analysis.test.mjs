import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NightAnalyser, DEFAULTS, keptMs, pct, median, clampDb } from '../public/analysis.js';

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
  assert.equal(ms, 7000 + 2 * DEFAULTS.ROLL_MS);
});
