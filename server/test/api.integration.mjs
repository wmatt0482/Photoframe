// End-to-end check of the API against a running server (local `wrangler dev`
// or a deployment). Starts from whatever is in the database and cleans up the
// photos it adds.
//
//   node test/api.integration.mjs http://127.0.0.1:8787 dev-password dev-frame-token

import assert from 'node:assert/strict';
import { FRAME_BYTES, INKS, pack, PANEL_W, PANEL_H } from '../public/epd.js';

const [base, password, token] = process.argv.slice(2);
const user = { Authorization: `Bearer ${password}` };
const frameAuth = { Authorization: `Bearer ${token}` };
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
const added = [];
let passed = 0;

async function step(name, fn) {
  await fn();
  passed++;
  console.log(`ok - ${name}`);
}

const solidFrame = (inkIndex) => pack(new Uint8Array(PANEL_W * PANEL_H).fill(inkIndex));

async function upload(frame, preview = JPEG) {
  const form = new FormData();
  form.append('frame', new Blob([frame]), 'frame.bin');
  form.append('preview', new Blob([preview]), 'preview.jpg');
  return fetch(`${base}/api/photos`, { method: 'POST', headers: user, body: form });
}

const next = (have = '', extra = '') =>
  fetch(`${base}/api/frame/next?have=${have}&mv=4000&pct=80&rssi=-60&fw=test${extra}`, { headers: frameAuth });

const state = async () => (await fetch(`${base}/api/state`, { headers: user })).json();

try {
  await step('rejects missing and wrong credentials', async () => {
    assert.equal((await fetch(`${base}/api/state`)).status, 401);
    assert.equal((await fetch(`${base}/api/state`, { headers: { Authorization: 'Bearer nope' } })).status, 401);
    assert.equal((await fetch(`${base}/api/frame/next`)).status, 401);
  });

  await step('the two secrets are not interchangeable', async () => {
    assert.equal((await fetch(`${base}/api/state`, { headers: frameAuth })).status, 401);
    assert.equal((await fetch(`${base}/api/frame/next`, { headers: user })).status, 401);
  });

  await step('rejects malformed uploads', async () => {
    assert.equal((await upload(new Uint8Array(100))).status, 400);
    assert.equal((await upload(new Uint8Array(FRAME_BYTES).fill(0x44))).status, 400);
    assert.equal((await upload(solidFrame(1), new Uint8Array([1, 2, 3]))).status, 400);
  });

  let a, b;
  await step('accepts valid uploads', async () => {
    const ra = await upload(solidFrame(3));
    assert.equal(ra.status, 201);
    a = (await ra.json()).id;
    b = (await (await upload(solidFrame(4))).json()).id;
    added.push(a, b);
    const ids = (await state()).photos.map((p) => p.id);
    assert.ok(ids.includes(a) && ids.includes(b));
  });

  await step('serves the preview by id', async () => {
    const res = await fetch(`${base}/api/photos/${a}/preview`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'image/jpeg');
    assert.deepEqual(new Uint8Array(await res.arrayBuffer()), JPEG);
  });

  // Drain anything already waiting in this database so the order is known.
  let have = '';
  const seen = [];
  await step('new uploads reach the frame, oldest first, byte for byte', async () => {
    for (let i = 0; i < 600; i++) {
      const res = await next(have);
      if (res.status !== 200) break;
      have = res.headers.get('x-photo-id');
      const body = new Uint8Array(await res.arrayBuffer());
      assert.equal(body.length, FRAME_BYTES);
      if (have === a) assert.ok(body.every((v) => v === (INKS[3].code << 4 | INKS[3].code)));
      seen.push(have);
    }
    assert.ok(seen.indexOf(a) >= 0 && seen.indexOf(a) < seen.indexOf(b));
    assert.equal(have, b);
  });

  await step('answers 304 with a sleep time when nothing is new', async () => {
    const res = await next(have);
    assert.equal(res.status, 304);
    assert.ok(Number(res.headers.get('x-sleep-seconds')) >= 300);
  });

  await step('records the frame check-in', async () => {
    const s = await state();
    assert.equal(s.frame.batteryPct, 80);
    assert.equal(s.frame.showing, b);
    assert.equal(s.currentId, b);
  });

  await step('a button press advances to another picture', async () => {
    const res = await next(have, '&advance=1');
    assert.equal(res.status, 200);
    assert.notEqual(res.headers.get('x-photo-id'), have);
    have = res.headers.get('x-photo-id');
    await res.arrayBuffer();
  });

  await step('"show next" pins a picture for the next check-in', async () => {
    const target = have === a ? b : a;
    assert.equal((await fetch(`${base}/api/photos/${target}/next`, { method: 'POST', headers: user })).status, 200);
    assert.equal((await state()).nextId, target);
    const res = await next(have);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('x-photo-id'), target);
    await res.arrayBuffer();
    have = target;
    assert.equal((await state()).nextId, null);
  });

  await step('a frame holding a deleted picture gets a replacement', async () => {
    const res = await next('0'.repeat(32));
    assert.equal(res.status, 200);
    have = res.headers.get('x-photo-id');
    await res.arrayBuffer();
  });

  await step('validates and saves settings', async () => {
    const put = (body) => fetch(`${base}/api/settings`, {
      method: 'PUT', headers: { ...user, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
    const before = (await state()).settings;
    assert.equal((await put({ checkMinutes: 1 })).status, 400);
    assert.equal((await put({ orientation: 'sideways' })).status, 400);
    assert.equal((await put({ checkMinutes: 60 })).status, 200);
    assert.equal(Number((await next(have)).headers.get('x-sleep-seconds')), 3600);
    assert.equal((await put(before)).status, 200);
  });

  await step('deletes photos', async () => {
    for (const id of added.splice(0)) {
      assert.equal((await fetch(`${base}/api/photos/${id}`, { method: 'DELETE', headers: user })).status, 200);
    }
    assert.equal((await fetch(`${base}/api/photos/${a}`, { method: 'DELETE', headers: user })).status, 404);
    assert.equal((await fetch(`${base}/api/photos/${a}/preview`)).status, 404);
  });

  console.log(`\n${passed} steps passed`);
} finally {
  for (const id of added) await fetch(`${base}/api/photos/${id}`, { method: 'DELETE', headers: user });
}
