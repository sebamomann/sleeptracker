// Pure analysis core: no DOM, no timers, no globals. The clock is injected so the gap
// detector can be tested against simulated suspensions, which is the one behaviour of
// this app that cannot be reproduced by hand.

export const DEFAULTS = {
  FRAME_MS:    20,    // analysis frame length
  GATE_DB:     12,    // open the gate this far above the rolling noise floor
  OPEN_MS:     150,   // sustained above threshold before an event opens
  // Sustained below threshold before the gate closes. Generous on purpose: breathing and
  // snoring come in bursts with seconds of quiet between them, and a short hold chops one
  // episode into a string of unlistenable fragments. Anything quieter than this for less
  // than CLOSE_MS stays inside the same event.
  CLOSE_MS:    4000,
  PRE_ROLL_MS: 2000,  // kept before the gate opened — otherwise events start mid-snore
  POST_ROLL_MS: 2000, // ...and after it closed, so the tail is not clipped
  FADE_MS:      40,   // ramp at each edge, so a clip does not begin and end with a click
  FLOOR_WIN_S: 60,    // rolling window for the noise floor
  FLOOR_WARMUP_S: 10, // ...before which the floor may only fall, never rise
  INITIAL_FLOOR_DB: -60,
  MAX_HOURS:   14,    // hard cap on stored envelope length
  MAX_EVENTS:  5000,

  // Quiet-gap detection: stretches of near-silence *inside* an otherwise noisy episode.
  // Deliberately not "the room went quiet" — that is most of a normal night. A gap only
  // counts when sound brackets it on both sides, which is what makes it a pause in
  // something rather than the absence of anything.
  GAP_MIN_S:      10,   // shorter than this is an ordinary pause between breaths
  GAP_MAX_S:      90,   // longer than this is not a pause in anything, just a quiet room
  GAP_MARGIN_DB:  4,    // within this much of the floor counts as quiet
  GAP_ADJOIN_S:   5,    // sound must stop this close to the start, and resume this close
                        // to the end — the quiet has to BE the interruption, not merely
                        // sit somewhere between two distant episodes

  STALL_MS:    700,   // a message gap longer than this is recorded
  LOST_MS:     300,   // ...and counts as real dead time past this much missing audio
};

export const clampDb = db => Math.max(-100, Math.min(0, db));

export function pct(arr, p) {
  if (!arr.length) return -100;
  const a = [...arr].sort((x, y) => x - y);
  return a[Math.min(a.length - 1, Math.floor(a.length * p))];
}
export const median = a => pct(a, 0.5);

export class NightAnalyser {
  constructor({ sampleRate, t0, cfg = {} }) {
    this.cfg = { ...DEFAULTS, ...cfg };
    this.sampleRate = sampleRate;
    this.t0 = t0;

    this.env = [];        // per second: [meanDb, maxDb, p10Db]
    this.gaps = [];       // {at, ms, audioLostMs}
    this.events = [];     // {s, e, peak}
    this.audioSec = 0;
    this.wallMs = 0;
    this.msgCount = 0;
    this.peakSinceRead = -100;
    // Wall clock of the most recent frame batch. This is the only record of when capture
    // actually stopped: if the OS suspends the page and never resumes it, pushFrames is
    // simply never called again, and every other counter freezes with it.
    this.lastFrameAt = 0;

    this._sec = [];
    this._floorHist = [];
    this.floorDb = this.cfg.INITIAL_FLOOR_DB;
    this._frame = 0;
    this._lastMsg = 0;
    this._lastAudioSec = 0;
    this._gate = { open: false, aboveN: 0, belowN: 0, startFrame: 0, peak: -100 };
  }

  get threshold() { return this.floorDb + this.cfg.GATE_DB; }

  /** Dead time is derived from the sample counter, not from timers — a throttled
   *  main thread makes every timer lie, but samples processed cannot be faked. */
  get deadMs() { return Math.max(0, this.wallMs - this.audioSec * 1000); }

  get realGaps() { return this.gaps.filter(g => g.audioLostMs > this.cfg.LOST_MS); }

  /** Peak dB since the last call, for the level meter. Resets on read. */
  readPeak() { const p = this.peakSinceRead; this.peakSinceRead = -100; return p; }

  toJSON() {
    const { env, gaps, events, audioSec, wallMs, msgCount, sampleRate, t0, lastFrameAt } = this;
    return { env, gaps, events, audioSec, wallMs, msgCount, sampleRate, t0, lastFrameAt };
  }

  pushFrames(rmsList, totalSamples, now) {
    const C = this.cfg;
    const audioSec = totalSamples / this.sampleRate;

    // Distinguish "the main thread was throttled" (messages arrive late, but the audio
    // thread kept running and flushes a backlog) from "capture was suspended" (the
    // sample counter also fell behind). Only the second is a real failure, and from the
    // UI they look identical.
    if (this._lastMsg) {
      const wallGap  = now - this._lastMsg;
      const audioGap = (audioSec - this._lastAudioSec) * 1000;
      if (wallGap > C.STALL_MS) {
        this.gaps.push({
          at: this._lastMsg,
          ms: Math.round(wallGap),
          audioLostMs: Math.round(Math.max(0, wallGap - audioGap)),
        });
      }
    }
    this._lastMsg = now;
    this._lastAudioSec = audioSec;
    this.lastFrameAt = now;
    this.audioSec = audioSec;
    this.wallMs = now - this.t0;
    this.msgCount++;

    for (const rms of rmsList) {
      const db = clampDb(20 * Math.log10(rms + 1e-12));
      if (db > this.peakSinceRead) this.peakSinceRead = db;
      this._sec.push(db);
      this._frame++;
      if (this._sec.length >= 1000 / C.FRAME_MS) this._rollSecond();
      this._runGate(db);
    }
  }

  _rollSecond() {
    const C = this.cfg, buf = this._sec;
    const mean = buf.reduce((a, b) => a + b, 0) / buf.length;
    const p10  = pct(buf, 0.10);
    if (this.env.length < C.MAX_HOURS * 3600) {
      this.env.push([Math.round(mean), Math.round(Math.max(...buf)), Math.round(p10)]);
    }
    this._floorHist.push(p10);
    if (this._floorHist.length > C.FLOOR_WIN_S) this._floorHist.shift();
    // The median is right once the window holds a representative mix of quiet and loud
    // seconds. Before that it is whatever happened to come first: a recorder started
    // mid-snore takes the snore as the floor, lifts the threshold above it, and closes the
    // gate on the very event it was opened for. Until there is enough history, take the
    // quietest second seen instead — the conservative reading, and the one that keeps the
    // opening event intact.
    this.floorDb = this._floorHist.length >= C.FLOOR_WARMUP_S
      ? median(this._floorHist)
      // During warmup the floor may fall but never rise. A quiet room is recognised on the
      // first second; a loud opening cannot drag the threshold up over itself, because the
      // one thing a short loud window does not tell you is how quiet the room gets.
      : Math.min(C.INITIAL_FLOOR_DB, ...this._floorHist);
    this._sec = [];
  }

  _runGate(db) {
    const C = this.cfg, g = this._gate, thresh = this.threshold;
    if (!g.open) {
      g.aboveN = db > thresh ? g.aboveN + 1 : 0;
      if (g.aboveN * C.FRAME_MS >= C.OPEN_MS) {
        g.open = true; g.belowN = 0; g.startFrame = this._frame - g.aboveN; g.peak = db;
      }
      return;
    }
    if (db > g.peak) g.peak = db;
    g.belowN = db < thresh ? g.belowN + 1 : 0;
    if (g.belowN * C.FRAME_MS >= C.CLOSE_MS) {
      const s = g.startFrame * C.FRAME_MS / 1000;
      const e = (this._frame - g.belowN) * C.FRAME_MS / 1000;
      if (this.events.length < C.MAX_EVENTS) {
        this.events.push({ s: +s.toFixed(1), e: +e.toFixed(1), peak: Math.round(g.peak) });
      }
      this._gate = { open: false, aboveN: 0, belowN: 0, startFrame: 0, peak: -100 };
    }
  }
}

/** Total audio the gate would have kept, including pre/post roll. */
export function keptMs(events, cfg = DEFAULTS) {
  const roll = cfg.PRE_ROLL_MS + cfg.POST_ROLL_MS;
  return events.reduce((a, e) => a + (e.e - e.s) * 1000 + roll, 0);
}

/** Opus mono at 24 kbps. */
export const megabytesFor = ms => ms / 1000 * (24 / 8) / 1024;

/**
 * Turn a stored session into the numbers the report shows.
 *
 * The subtlety this exists for: the analyser's own `wallMs` advances only while frames
 * arrive, so a capture that is suspended and never resumes leaves every counter frozen at
 * the moment it died — and naively differencing them says no time was lost at all. The
 * session's real end has to come from outside the audio thread: the stop timestamp, or
 * the last time the page was alive enough to save.
 */
export function summarise(s, cfg = DEFAULTS) {
  const t0 = s.t0;
  const endAt = s.endedAt ? Date.parse(s.endedAt)
              : (s.lastAliveAt ?? t0 + (s.wallMs ?? 0));
  const wall = Math.max(0, endAt - t0);
  const audioMs = (s.audioSec ?? 0) * 1000;
  const deadMs = Math.max(0, wall - audioMs);

  const realGaps = (s.gaps ?? []).filter(g => g.audioLostMs > cfg.LOST_MS);
  const worstGapMs = realGaps.reduce((m, g) => Math.max(m, g.audioLostMs), 0);

  // Capture that stopped and never came back leaves no gap record — there is no later
  // message to close one — so it is measured from the last frame to the end instead.
  const stoppedAt = s.lastFrameAt || null;
  const trailingDeadMs = stoppedAt ? Math.max(0, endAt - stoppedAt) : 0;
  const diedAndStayedDead = trailingDeadMs > 60_000;

  const tooShort = wall <= 60_000;
  const survived = !tooShort && deadMs < 30_000;

  return { t0, endAt, wall, audioMs, deadMs, realGaps, worstGapMs,
           stoppedAt, trailingDeadMs, diedAndStayedDead, tooShort, survived };
}

/**
 * Near-silent stretches bracketed by sound — pauses in an ongoing episode.
 *
 * This is the inverse of the gate: it looks for the ABSENCE of sound, which needs different
 * rules. Plain silence is uninformative (most of a quiet night is silence), so a run only
 * qualifies when the surrounding `GAP_CONTEXT_S` contains real events on BOTH sides. That
 * turns "the room is quiet" into "something was happening, then stopped, then resumed".
 *
 * Takes the per-second envelope and the event list; returns offsets in seconds.
 *
 * This is an observational signal, not a diagnosis — a fan, rolling over, or simply
 * breathing quietly all look the same from here.
 */
export function findQuietGaps({ envelope, events, floorDb }, cfg = DEFAULTS) {
  if (!envelope?.length || !events?.length) return [];

  const quietBelow = floorDb + cfg.GAP_MARGIN_DB;
  const gaps = [];
  let runStart = null;

  const closeRun = end => {
    if (runStart === null) return;
    const length = end - runStart;
    // An upper bound is what separates a pause from plain quiet. Without it, the hours
    // between the last snore of one episode and the first of the next qualify: the gap IS
    // the space between two events, so adjacency alone can never rule it out.
    if (length >= cfg.GAP_MIN_S && length <= cfg.GAP_MAX_S) {
      const stopped = events.some(e => Math.abs(e.e - runStart) <= cfg.GAP_ADJOIN_S);
      const resumed = events.some(e => Math.abs(e.s - end) <= cfg.GAP_ADJOIN_S);
      if (stopped && resumed) {
        gaps.push({ startS: runStart, endS: end, durationS: length });
      }
    }
    runStart = null;
  };

  for (let i = 0; i < envelope.length; i++) {
    const peak = envelope[i][1];
    if (peak < quietBelow) {
      if (runStart === null) runStart = i;
    } else {
      closeRun(i);
    }
  }
  closeRun(envelope.length);
  return gaps;
}
