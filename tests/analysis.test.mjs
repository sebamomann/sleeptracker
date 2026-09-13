import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  NightAnalyser, DEFAULTS, keptMs, pct, median, clampDb, summarise, findQuietGaps,
  calibrate, nightStats, CALIBRATION, sleepTimeline, SLEEP, ASLEEP, RESTLESS, AWAKE,
} from '../public/analysis.js';
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

/* ── quiet gaps ───────────────────────────────────────────────────────────── */

/** Build an envelope where `loud` ranges are at -25 dB and everything else at -60. */
function envelopeWith(seconds, loudRanges) {
  return Array.from({ length: seconds }, (_, i) => {
    const loud = loudRanges.some(([a, b]) => i >= a && i < b);
    return loud ? [-30, -25, -32] : [-60, -59, -61];
  });
}

test('a pause inside an ongoing episode is flagged', () => {
  // Snoring, 15 s of near-silence, snoring again.
  const envelope = envelopeWith(120, [[0, 20], [35, 55]]);
  const events = [{ s: 0, e: 20 }, { s: 35, e: 55 }];
  const gaps = findQuietGaps({ envelope, events, floorDb: -61 });
  assert.equal(gaps.length, 1);
  assert.equal(gaps[0].startS, 20);
  assert.equal(gaps[0].durationS, 15);
});

test('a quiet night produces no gaps at all', () => {
  // The failure mode that makes naive silence detection useless: eight hours of quiet
  // would otherwise be one enormous "pause", or thousands of them.
  const envelope = envelopeWith(600, []);
  const gaps = findQuietGaps({ envelope, events: [], floorDb: -61 });
  assert.equal(gaps.length, 0);
});

test('silence after the last sound is not a pause', () => {
  // Nothing resumed, so nothing paused — the episode simply ended.
  const envelope = envelopeWith(200, [[0, 20]]);
  const events = [{ s: 0, e: 20 }];
  assert.equal(findQuietGaps({ envelope, events, floorDb: -61 }).length, 0);
});

test('an ordinary pause between breaths is too short to flag', () => {
  const envelope = envelopeWith(120, [[0, 20], [25, 45]]);   // 5 s gap
  const events = [{ s: 0, e: 20 }, { s: 25, e: 45 }];
  assert.equal(findQuietGaps({ envelope, events, floorDb: -61 }).length, 0);
});

test('a long quiet stretch between episodes is not a pause', () => {
  // 100 s of quiet is the room being quiet, not a held breath — and adjacency alone cannot
  // reject it, since the quiet sits exactly between the two events. Hence GAP_MAX_S.
  const envelope = envelopeWith(260, [[0, 20], [120, 140]]);
  const events = [{ s: 0, e: 20 }, { s: 120, e: 140 }];
  assert.equal(findQuietGaps({ envelope, events, floorDb: -61 }).length, 0);
});

test('a pause at the very edge of plausible is still reported', () => {
  const envelope = envelopeWith(200, [[0, 20], [100, 120]]);   // 80 s, under GAP_MAX_S
  const events = [{ s: 0, e: 20 }, { s: 100, e: 120 }];
  const gaps = findQuietGaps({ envelope, events, floorDb: -61 });
  assert.equal(gaps.length, 1);
  assert.equal(gaps[0].durationS, 80);
});

test('several pauses in one episode are all found', () => {
  const envelope = envelopeWith(200, [[0, 10], [25, 35], [50, 60], [75, 85]]);
  const events = [{ s: 0, e: 10 }, { s: 25, e: 35 }, { s: 50, e: 60 }, { s: 75, e: 85 }];
  const gaps = findQuietGaps({ envelope, events, floorDb: -61 });
  assert.equal(gaps.length, 3);
  assert.deepEqual(gaps.map(g => g.durationS), [15, 15, 15]);
});

test('findQuietGaps tolerates missing input', () => {
  assert.deepEqual(findQuietGaps({ envelope: [], events: [], floorDb: -60 }), []);
  assert.deepEqual(findQuietGaps({}), []);
});

/* ── rejecting what isn't an event ────────────────────────────────────────── */

test('a brief tick does not become a four-second file', () => {
  // The shape that produced most of a real night's 102 events: something 200 ms long, which
  // pre- and post-roll then pad into a clip that sounds like silence with a click in it.
  const a = makeAnalyser();
  run(a, 60 * 50, t => ((t % 10) < 0.2 ? -20 : -60));
  assert.equal(a.events.length, 0, 'ticks shorter than MIN_EVENT_MS must be dropped');
  assert.ok(a.rejected > 0, 'and counted, so a bad threshold is visible');
});

test('a sustained sound of the same loudness is kept', () => {
  const a = makeAnalyser();
  run(a, 60 * 50, t => ((t % 20) < 3 ? -20 : -60));
  assert.ok(a.events.length >= 2, 'real episodes still open');
  assert.ok(a.events.every(e => (e.e - e.s) >= 0.4));
});

test('a sound that never becomes audible is dropped however prominent', () => {
  // -70 dB is 20 dB above a -90 dB floor, so the relative rule alone would keep it — but
  // nothing at -70 dBFS is audible on a phone speaker.
  const a = makeAnalyser();
  run(a, 60 * 50, t => ((t % 20) < 3 ? -70 : -90));
  assert.equal(a.events.length, 0);
  assert.ok(a.rejected > 0);
});

test('a real snore clears both rules', () => {
  const a = makeAnalyser();
  run(a, 60 * 50, t => ((t % 20) < 4 ? -26 : -58));
  assert.ok(a.events.length >= 2);
  assert.ok(a.events.every(e => e.peak >= DEFAULTS.MIN_PEAK_DB));
});

/* ── self-calibration ─────────────────────────────────────────────────────── */

const night = (events, hours = 8, medianPeakDb = -30) => ({ hours, events, medianPeakDb });

test('too many events a night makes the gate listen less closely', () => {
  // The real complaint: 102 events in roughly eight hours, about 13/h against a target of 4.
  const out = calibrate([night(102)], { gateDb: 15, minPeakDb: -52 });
  assert.ok(out.gateDb > 15, `gate went to ${out.gateDb}, expected higher`);
  assert.match(out.why, /listening less closely/);
});

test('too few events makes it listen more closely', () => {
  const out = calibrate([night(4)], { gateDb: 20, minPeakDb: -40 });
  assert.ok(out.gateDb < 20);
  assert.match(out.why, /listening more closely/);
});

test('a night already on target holds still', () => {
  const out = calibrate([night(32)], { gateDb: 15, minPeakDb: -45 });
  assert.equal(out.gateDb, 15);
  assert.match(out.why, /holding/);
});

test('one night cannot swing the gate wide open', () => {
  // A party next door should not deafen the app for a week.
  const out = calibrate([night(4000)], { gateDb: 15, minPeakDb: -45 });
  assert.ok(out.gateDb <= 15 + CALIBRATION.MAX_STEP_DB);
});

test('it converges on the target instead of oscillating', () => {
  // Feed back a rate that responds to the gate: every extra dB halves the events.
  let current = { gateDb: 12, minPeakDb: -45 };
  let events = 102;
  for (let i = 0; i < 12; i++) {
    const next = calibrate([night(events)], current);
    events = Math.max(1, Math.round(events / Math.pow(2, next.gateDb - current.gateDb)));
    current = next;
  }
  const finalRate = events / 8;
  assert.ok(Math.abs(finalRate - CALIBRATION.TARGET_PER_HOUR) < 2,
    `settled at ${finalRate.toFixed(1)}/h, target ${CALIBRATION.TARGET_PER_HOUR}`);
  assert.ok(current.gateDb >= CALIBRATION.GATE_MIN_DB);
  assert.ok(current.gateDb <= CALIBRATION.GATE_MAX_DB);
});

test('the absolute floor follows the room, not a constant', () => {
  // A phone on the pillow hears everything louder than one across the room, and the
  // same written-down -52 dBFS means something different in each.
  const near = calibrate([night(32, 8, -20)], { gateDb: 15, minPeakDb: -52 });
  const far = calibrate([night(32, 8, -44)], { gateDb: 15, minPeakDb: -52 });
  assert.ok(near.minPeakDb > far.minPeakDb,
    `near ${near.minPeakDb} should sit above far ${far.minPeakDb}`);
  assert.equal(near.minPeakDb, -32);
  assert.equal(far.minPeakDb, -56);
});

test('short nights are not evidence', () => {
  const out = calibrate([night(60, 0.1)], { gateDb: 15, minPeakDb: -52 });
  assert.equal(out.nights, 0);
  assert.equal(out.gateDb, 15);
  assert.match(out.why, /no nights yet/);
});

test('thresholds stay inside their bounds however extreme the history', () => {
  let current = { gateDb: 15, minPeakDb: -52 };
  for (let i = 0; i < 30; i++) current = calibrate([night(100_000)], current);
  assert.equal(current.gateDb, CALIBRATION.GATE_MAX_DB);
  for (let i = 0; i < 30; i++) current = calibrate([night(0)], current);
  assert.equal(current.gateDb, CALIBRATION.GATE_MIN_DB);
});

test('nightStats reduces a session to what calibration needs', () => {
  const stats = nightStats({
    wallMs: 8 * 3_600_000,
    events: [{ peak: -20 }, { peak: -30 }, { peak: -40 }],
  });
  assert.equal(stats.hours, 8);
  assert.equal(stats.events, 3);
  assert.equal(stats.medianPeakDb, -30);
});

/* ── sleep, inferred ──────────────────────────────────────────────────────── */

const HOURS_8 = 8 * 3_600_000;
/** Events spread evenly through an epoch-aligned window. */
function busy(fromMin, toMin, perEpoch = 8, kind = 'movement') {
  const out = [];
  for (let minute = fromMin; minute < toMin; minute += 5) {
    for (let n = 0; n < perEpoch; n++) out.push({ s: minute * 60 + n, kind });
  }
  return out;
}

test('a quiet night is asleep almost all of it', () => {
  const out = sleepTimeline({ events: [], wallMs: HOURS_8 });
  assert.equal(out.onsetS, 0);
  assert.ok(out.efficiency > 0.95);
  assert.equal(out.awakenings, 0);
});

test('time spent settling is not counted as sleep', () => {
  // Half an hour of reading and moving before it goes quiet.
  const out = sleepTimeline({ events: busy(0, 30), wallMs: HOURS_8 });
  assert.equal(out.onsetS, 30 * 60, `onset at ${out.onsetS}s, expected 1800`);
  assert.equal(out.asleepSeconds, 7.5 * 3600, 'the half hour spent settling is excluded');
});

test('getting up at the end ends the night there', () => {
  const out = sleepTimeline({ events: busy(450, 480), wallMs: HOURS_8 });
  assert.equal(out.finalWakeS, 450 * 60);
  assert.ok(out.inBedSeconds < HOURS_8 / 1000);
});

test('waking in the middle is counted, not ignored', () => {
  const out = sleepTimeline({ events: busy(180, 200), wallMs: HOURS_8 });
  assert.equal(out.awakenings, 1);
  assert.ok(out.efficiency < 0.98);
  assert.ok(out.efficiency > 0.8, 'one wake should not wreck the whole night');
});

test('talking means awake however little of it there was', () => {
  // One sentence is not restlessness. People do not hold conversations asleep.
  const quiet = sleepTimeline({ events: [{ s: 3600, kind: 'movement' }], wallMs: HOURS_8 });
  const spoke = sleepTimeline({ events: [{ s: 3600, kind: 'talking' }], wallMs: HOURS_8 });
  assert.equal(quiet.awakenings, 0);
  assert.equal(spoke.awakenings, 1);
});

test('a brief stir is not getting up', () => {
  // Five minutes of activity at the end, under WAKE_RUN_EPOCHS, so the night still
  // ends at the recording's end rather than being cut short.
  const out = sleepTimeline({ events: busy(475, 480), wallMs: HOURS_8 });
  assert.equal(out.finalWakeS, 480 * 60);
});

test('a night that never settles reports no sleep rather than guessing', () => {
  const out = sleepTimeline({ events: busy(0, 480), wallMs: HOURS_8 });
  assert.equal(out.onsetS, null);
  assert.equal(out.asleepSeconds, 0);
  assert.equal(out.efficiency, 0);
});

test('an empty recording produces zeroes, not NaN', () => {
  const out = sleepTimeline({ events: [], wallMs: 0 });
  assert.deepEqual(out.epochs, []);
  assert.equal(out.efficiency, 0);
  assert.equal(out.asleepSeconds, 0);
});
