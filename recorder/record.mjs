#!/usr/bin/env node
/**
 * Bedside recorder. Captures from the default microphone, runs the same gate the browser
 * spike used, and writes one WAV per detected event plus a session index.
 *
 * Unlike the browser, nothing here is sandboxed or suspendable: the analysis module,
 * thresholds and gap detection are shared verbatim with public/analysis.js, but this
 * process actually keeps the audio.
 *
 *   node recorder/record.mjs                 # until Ctrl-C
 *   node recorder/record.mjs --minutes 5     # short trial
 *   node recorder/record.mjs --source stdin  # read f32le PCM from a pipe
 */
import { spawn } from 'node:child_process';
import { execFileSync } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { NightAnalyser, DEFAULTS, keptMs, summarise } from '../public/analysis.js';
import { encodeWav, fadeEdges } from '../public/wav.js';
import { SampleRing } from './ring.mjs';

const RATE = 16000;             // YAMNet's native rate
const PRE_ROLL_S = DEFAULTS.PRE_ROLL_MS / 1000;
const POST_ROLL_S = DEFAULTS.POST_ROLL_MS / 1000;
const RING_S = 120;             // history kept so a closed event can still be cut out

const argv = process.argv.slice(2);
const arg = (k, d) => {
  const i = argv.indexOf('--' + k);
  return i === -1 ? d : (argv[i + 1]?.startsWith('--') ? true : argv[i + 1] ?? true);
};

function setFormat(f) {
  if (f === 's16le') { sampleBytes = 2; decode = (b, i) => b.readInt16LE(i * 2) / 0x8000; }
  else { sampleBytes = 4; decode = (b, i) => b.readFloatLE(i * 4); }
}

const have = c => { try { execFileSync('which', [c], { stdio: 'ignore' }); return true; } catch { return false; } };

/**
 * Whatever can hand us raw mono PCM on stdout. arecord is first because it ships with
 * Raspberry Pi OS — a Pi needs nothing installed at all — and S16_LE because every ALSA
 * device supports it, while FLOAT_LE is not universal.
 */
function capture() {
  const device = typeof arg('device') === 'string' ? arg('device') : null;
  const linux = process.platform === 'linux';

  if (linux && have('arecord')) return {
    cmd: 'arecord',
    args: ['-q', '-D', device ?? 'default', '-f', 'S16_LE', '-r', String(RATE),
           '-c', '1', '-t', 'raw'],
    format: 's16le',
  };
  if (have('sox')) return {
    cmd: 'sox',
    args: ['-q', '-d', '-t', 'raw', '-e', 'float', '-b', '32',
           '-r', String(RATE), '-c', '1', '-'],
    format: 'f32le',
  };
  if (have('ffmpeg')) return {
    cmd: 'ffmpeg',
    args: ['-hide_banner', '-loglevel', 'error',
           ...(linux ? ['-f', 'alsa', '-i', device ?? 'default']
                     : ['-f', 'avfoundation', '-i', device ?? ':0']),
           '-ac', '1', '-ar', String(RATE), '-f', 'f32le', '-'],
    format: 'f32le',
  };
  return null;
}

/* ── state ────────────────────────────────────────────────────────────────── */
const t0 = Date.now();
const stamp = new Date(t0).toISOString().slice(0, 16).replace(/[:T]/g, '-');
const outDir = join(String(arg('out', 'nights')), stamp);
const eventsDir = join(outDir, 'events');

const A = new NightAnalyser({ sampleRate: RATE, t0 });
const ring = new SampleRing({ capacity: RING_S * RATE });
const index = [];
const writes = [];
let seen = 0, lost = 0, bytes = 0;
const pending = [];   // events whose tail has not been recorded yet
let acc = 0, nAcc = 0, batch = [], total = 0, rem = Buffer.alloc(0);
let sampleBytes = 4, decode = (b, i) => b.readFloatLE(i * 4);
const PER_FRAME = RATE * DEFAULTS.FRAME_MS / 1000;

const hhmmss = ts => new Date(ts).toTimeString().slice(0, 8);
const dur = ms => {
  const s = Math.round(ms / 1000);
  return `${Math.floor(s / 3600)}:${String(Math.floor(s % 3600 / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
};

function onPcm(chunk) {
  if (rem.length) { chunk = Buffer.concat([rem, chunk]); rem = Buffer.alloc(0); }
  // Chunk boundaries do not respect sample boundaries; carry the tail to the next read.
  const usable = chunk.length - (chunk.length % sampleBytes);
  if (usable < chunk.length) rem = Buffer.from(chunk.subarray(usable));
  if (!usable) return;

  const samples = new Float32Array(usable / sampleBytes);
  for (let i = 0; i < samples.length; i++) samples[i] = decode(chunk, i);
  ring.push(samples);

  for (const s of samples) {
    acc += s * s;
    if (++nAcc >= PER_FRAME) { batch.push(Math.sqrt(acc / nAcc)); acc = 0; nAcc = 0; }
  }
  total += samples.length;

  if (batch.length >= 10) {
    A.pushFrames(batch, total, Date.now());
    batch = [];
    harvest();
  }
}

/**
 * Cut each closed event out of the ring and write it.
 *
 * An event is only cut once its tail exists. The gate closes CLOSE_MS after a sound stops,
 * so at that moment the ring holds only that much tail; a post-roll longer than the close
 * hold would be clamped by `slice` and silently reintroduce the clipped endings it was
 * raised to prevent.
 */
function harvest({ final = false } = {}) {
  while (seen < A.events.length) pending.push(A.events[seen++]);

  const ready = final ? pending.splice(0) : [];
  if (!final) {
    for (let i = pending.length - 1; i >= 0; i--) {
      const to = Math.round((pending[i].e + POST_ROLL_S) * RATE);
      if (total >= to) ready.unshift(...pending.splice(i, 1));
    }
  }

  for (const ev of ready) {
    const from = Math.max(0, Math.round((ev.s - PRE_ROLL_S) * RATE));
    const to = Math.round((ev.e + POST_ROLL_S) * RATE);
    const pcm = ring.slice(from, to);

    // An empty slice means the audio scrolled out of the window before we got to it.
    // Recording it as a file of zeroes would be worse than admitting it is gone.
    if (!pcm.length) { lost++; continue; }

    const at = t0 + from / RATE * 1000;
    const file = `${String(seen).padStart(4, '0')}-${hhmmss(at).replace(/:/g, '')}.wav`;
    // Ramp the edges before writing: a gated clip starts at an arbitrary sample, and the
    // step discontinuity is audible as a click at both ends.
    const wav = Buffer.from(encodeWav(fadeEdges(pcm, RATE, DEFAULTS.FADE_MS), RATE));
    bytes += wav.length;
    index.push({ i: seen, file, at: new Date(at).toISOString(),
                 startS: ev.s, endS: ev.e, peakDb: ev.peak,
                 durationS: +((pcm.length / RATE).toFixed(2)) });
    writes.push(writeFile(join(eventsDir, file), wav));
    process.stdout.write(`  ${hhmmss(at)}  event ${seen}  ${(pcm.length / RATE).toFixed(1)}s  peak ${ev.peak} dB\n`);
  }
}

async function saveSession(ended) {
  const s = { v: 1, t0, startedAt: new Date(t0).toISOString(),
              endedAt: ended ? new Date().toISOString() : null, ended,
              lastAliveAt: Date.now(), source: 'node-recorder', rate: RATE,
              marks: [], ...A.toJSON(), index, lostEvents: lost };
  await writeFile(join(outDir, 'session.json'), JSON.stringify(s, null, 2));
  return s;
}

/* ── run ──────────────────────────────────────────────────────────────────── */
await mkdir(eventsDir, { recursive: true });

let child = null;
if (arg('source') === 'stdin') {
  if (arg('format') === 's16le') setFormat('s16le');
  process.stdin.on('data', onPcm);
  process.stdin.on('end', () => finish('input ended'));
} else {
  const cmd = capture();
  if (!cmd) {
    console.error('No capture tool found. Install one:\n\n' +
      (process.platform === 'linux'
        ? '  sudo apt install alsa-utils   # arecord, usually already present\n'
        : '  brew install sox              # small, recommended\n') +
      '  or ffmpeg\n');
    process.exit(1);
  }
  setFormat(cmd.format);
  console.log(`Capturing with ${cmd.cmd} (${cmd.format}) at ${RATE} Hz mono → ${outDir}`);
  child = spawn(cmd.cmd, cmd.args, { stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', onPcm);
  child.stderr.on('data', d => process.stderr.write(d));
  child.on('error', e => { console.error('Capture failed:', e.message); process.exit(1); });
  child.on('exit', code => { if (code) finish(`capture exited with code ${code}`); });
}

const status = setInterval(() => {
  process.stdout.write(`\r  ${dur(Date.now() - t0)}  floor ${Math.round(A.floorDb)} dB  ` +
    `gate ${Math.round(A.threshold)} dB  ${A.events.length} events  ` +
    `${(bytes / 1e6).toFixed(1)} MB   `);
}, 5000);

const saver = setInterval(() => saveSession(false), 15000);

const minutes = Number(arg('minutes', 0));
if (minutes) setTimeout(() => finish(`--minutes ${minutes} reached`), minutes * 60_000);

let finishing = false;
async function finish(why) {
  if (finishing) return; finishing = true;
  clearInterval(status); clearInterval(saver);
  try { child?.kill('SIGTERM'); } catch {}
  harvest({ final: true });   // a short last event beats losing it
  await Promise.allSettled(writes);
  const s = await saveSession(true);
  const R = summarise(s);

  const kept = keptMs(A.events);
  console.log(`\n\n── ${why} ──`);
  console.log(`  ran            ${dur(R.wall)}   audio ${dur(R.audioMs)}   dead ${dur(R.deadMs)}`);
  console.log(`  noise floor    ${Math.round(A.floorDb)} dB    gate ${Math.round(A.threshold)} dB`);
  console.log(`  events         ${A.events.length} kept, ${lost} lost to the ring`);
  // Against captured audio, not wall clock: when reading from a pipe the two are
  // unrelated, and "what fraction of the audio is worth keeping" is the useful number
  // either way.
  console.log(`  audio written  ${(bytes / 1e6).toFixed(1)} MB  (${dur(kept)} of ${dur(R.audioMs)} ` +
              `captured = ${R.audioMs ? (kept / R.audioMs * 100).toFixed(1) : 0}%)`);
  console.log(`  → ${outDir}\n`);
  process.exit(0);
}

for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => finish(`stopped (${sig})`));
