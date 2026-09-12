import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SampleRing } from '../recorder/ring.mjs';

const ramp = (from, n) => Float32Array.from({ length: n }, (_, i) => from + i);

test('slices across chunk boundaries', () => {
  const r = new SampleRing({ capacity: 1000 });
  r.push(ramp(0, 10)); r.push(ramp(10, 10)); r.push(ramp(20, 10));
  assert.deepEqual([...r.slice(5, 25)], [...ramp(5, 20)]);
  assert.deepEqual([...r.slice(0, 30)], [...ramp(0, 30)]);
  assert.equal(r.written, 30);
});

test('retains at least the requested window', () => {
  const r = new SampleRing({ capacity: 50 });
  for (let i = 0; i < 20; i++) r.push(ramp(i * 10, 10));
  // 200 samples written, 50 required — the newest 50 must still be exact.
  assert.deepEqual([...r.slice(150, 200)], [...ramp(150, 50)]);
});

test('drops history beyond the window instead of growing forever', () => {
  const r = new SampleRing({ capacity: 50 });
  for (let i = 0; i < 1000; i++) r.push(ramp(i * 10, 10));
  assert.ok(r.chunks.length <= 7, `held ${r.chunks.length} chunks; must stay bounded`);
  assert.ok(r.oldest >= 9940, 'oldest retained sample tracks the window');
});

test('a range that scrolled away comes back empty, not as silence', () => {
  // The distinction matters: an event whose audio is gone must be reported as lost, never
  // written out as a file full of zeroes that looks like a silent recording.
  const r = new SampleRing({ capacity: 50 });
  for (let i = 0; i < 20; i++) r.push(ramp(i * 10, 10));
  assert.equal(r.slice(0, 40).length, 0);
});

test('clamps a range that runs past the newest sample', () => {
  const r = new SampleRing({ capacity: 1000 });
  r.push(ramp(0, 10));
  assert.deepEqual([...r.slice(5, 999)], [...ramp(5, 5)]);
});

test('an empty ring yields empty slices', () => {
  const r = new SampleRing({ capacity: 100 });
  assert.equal(r.slice(0, 10).length, 0);
  assert.equal(r.oldest, 0);
});
