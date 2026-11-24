// Photoframe server: stores pictures already encoded for the panel and hands
// them to the frame when it wakes up. It also serves the web page, which the
// build step bundles from ./public into assets.generated.js.

import { FRAME_BYTES, isValidFrame } from '../public/epd.js';
import { ASSETS } from './assets.generated.js';

const MAX_PHOTOS = 500;
const MAX_PREVIEW_BYTES = 400_000;
const MAX_CAPTION = 200;
const MIN_SLEEP_S = 5 * 60;
const MAX_SLEEP_S = 24 * 60 * 60;

const DEFAULT_SETTINGS = {
  orientation: 'landscape', // 'landscape' | 'portrait'
  flip: false,              // rotate a further 180 degrees
  checkMinutes: 30,         // how often the frame wakes to look for new pictures
  rotateMinutes: 24 * 60,   // how often it moves on when nothing is new; 0 = never
  order: 'sequential',      // 'sequential' | 'shuffle'
};

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (err) {
      if (err instanceof HttpError) return json({ error: err.message }, err.status);
      console.error(err);
      return json({ error: 'internal error' }, 500);
    }
  },
};

async function route(request, env) {
  const url = new URL(request.url);
  const { pathname } = url;
  const method = request.method;

  if (!pathname.startsWith('/api/')) return serveAsset(request, pathname);

  // Previews are fetched by <img> tags, which cannot send an Authorization
  // header. They are protected by the photo id, 128 random bits.
  const preview = pathname.match(/^\/api\/photos\/([0-9a-f]{32})\/preview$/);
  if (preview && method === 'GET') return getPreview(env, preview[1]);

  if (pathname === '/api/frame/next' && method === 'GET') {
    await requireSecret(request, env.FRAME_TOKEN, 'FRAME_TOKEN');
    return frameNext(env, url.searchParams);
  }

  await requireSecret(request, env.UPLOAD_PASSWORD, 'UPLOAD_PASSWORD');

  if (pathname === '/api/state' && method === 'GET') return json(await getState(env));
  if (pathname === '/api/settings' && method === 'PUT') return putSettings(env, request);
  if (pathname === '/api/photos' && method === 'POST') return postPhoto(env, request);

  const photo = pathname.match(/^\/api\/photos\/([0-9a-f]{32})(\/next)?$/);
  if (photo && !photo[2] && method === 'DELETE') return deletePhoto(env, photo[1]);
  if (photo && photo[2] && method === 'POST') return pinNext(env, photo[1]);

  return json({ error: 'not found' }, 404);
}

function serveAsset(request, pathname) {
  const asset = ASSETS[pathname === '/' ? '/index.html' : pathname];
  if (!asset || !['GET', 'HEAD'].includes(request.method)) return json({ error: 'not found' }, 404);
  const headers = {
    'Content-Type': asset.type,
    'ETag': asset.etag,
    // Always revalidate so a new deploy shows up on the next page load.
    'Cache-Control': 'no-cache',
    'X-Content-Type-Options': 'nosniff',
  };
  if (request.headers.get('If-None-Match') === asset.etag) return new Response(null, { status: 304, headers });
  return new Response(request.method === 'HEAD' ? null : asset.body, { headers });
}

// ---------------------------------------------------------------- web app API

async function getState(env) {
  const [photos, settings, frame, currentId, nextId] = await Promise.all([
    env.DB.prepare(
      'SELECT id, created_at, caption, source, shown_count, last_shown_at FROM photos ORDER BY created_at DESC',
    ).all(),
    getSettings(env),
    kvGet(env, 'frame_status'),
    kvGet(env, 'current_id'),
    kvGet(env, 'next_id'),
  ]);
  return {
    settings,
    frame: frame ?? null,
    currentId: currentId ?? null,
    nextId: nextId ?? null,
    photos: photos.results.map((p) => ({
      id: p.id,
      createdAt: p.created_at,
      caption: p.caption,
      source: p.source,
      shownCount: p.shown_count,
      lastShownAt: p.last_shown_at,
    })),
  };
}

async function putSettings(env, request) {
  const body = await request.json().catch(() => null);
  if (!body || typeof body !== 'object') throw new HttpError(400, 'expected a JSON object');
  const settings = { ...(await getSettings(env)) };

  if ('orientation' in body) {
    if (!['landscape', 'portrait'].includes(body.orientation)) throw new HttpError(400, 'bad orientation');
    settings.orientation = body.orientation;
  }
  if ('flip' in body) settings.flip = Boolean(body.flip);
  if ('order' in body) {
    if (!['sequential', 'shuffle'].includes(body.order)) throw new HttpError(400, 'bad order');
    settings.order = body.order;
  }
  if ('checkMinutes' in body) settings.checkMinutes = intInRange(body.checkMinutes, 5, 24 * 60, 'checkMinutes');
  if ('rotateMinutes' in body) settings.rotateMinutes = intInRange(body.rotateMinutes, 0, 30 * 24 * 60, 'rotateMinutes');

  await kvPut(env, 'settings', settings);
  return json(settings);
}

async function postPhoto(env, request) {
  const form = await request.formData().catch(() => null);
  if (!form) throw new HttpError(400, 'expected multipart form data');
  const frameFile = form.get('frame');
  const previewFile = form.get('preview');
  if (!(frameFile instanceof File) || !(previewFile instanceof File)) {
    throw new HttpError(400, 'frame and preview files are required');
  }
  if (frameFile.size !== FRAME_BYTES) throw new HttpError(400, `frame must be exactly ${FRAME_BYTES} bytes`);
  if (previewFile.size === 0 || previewFile.size > MAX_PREVIEW_BYTES) throw new HttpError(400, 'preview is too large');

  const frame = new Uint8Array(await frameFile.arrayBuffer());
  if (!isValidFrame(frame)) throw new HttpError(400, 'frame contains values the panel cannot display');
  const preview = new Uint8Array(await previewFile.arrayBuffer());
  if (!(preview[0] === 0xff && preview[1] === 0xd8)) throw new HttpError(400, 'preview must be a JPEG');

  const { n } = await env.DB.prepare('SELECT COUNT(*) AS n FROM photos').first();
  if (n >= MAX_PHOTOS) throw new HttpError(409, `library is full (${MAX_PHOTOS} photos); delete some first`);

  const id = randomId();
  const caption = String(form.get('caption') ?? '').slice(0, MAX_CAPTION);
  const createdAt = Date.now();
  await env.DB.prepare(
    'INSERT INTO photos (id, created_at, caption, source, frame, preview) VALUES (?, ?, ?, ?, ?, ?)',
  ).bind(id, createdAt, caption, 'web', frame.buffer, preview.buffer).run();

  return json({ id, createdAt, caption }, 201);
}

async function getPreview(env, id) {
  const row = await env.DB.prepare('SELECT preview FROM photos WHERE id = ?').bind(id).first();
  if (!row) return json({ error: 'not found' }, 404);
  return new Response(blobBytes(row.preview), {
    headers: {
      'Content-Type': 'image/jpeg',
      'Cache-Control': 'private, max-age=31536000, immutable',
    },
  });
}

async function deletePhoto(env, id) {
  const result = await env.DB.prepare('DELETE FROM photos WHERE id = ?').bind(id).run();
  if (result.meta.changes === 0) throw new HttpError(404, 'not found');
  if ((await kvGet(env, 'next_id')) === id) await kvDelete(env, 'next_id');
  return json({ ok: true });
}

async function pinNext(env, id) {
  const row = await env.DB.prepare('SELECT id FROM photos WHERE id = ?').bind(id).first();
  if (!row) throw new HttpError(404, 'not found');
  await kvPut(env, 'next_id', id);
  return json({ ok: true, nextId: id });
}

// ------------------------------------------------------------------ frame API

// Called by the frame each time it wakes. Replies with one of:
//   200 + 192,000 bytes   paint this
//   304                   keep what you are showing
//   204                   nothing has been uploaded yet
// X-Sleep-Seconds always says how long to sleep before asking again.
async function frameNext(env, params) {
  const now = Date.now();
  const have = /^[0-9a-f]{32}$/.test(params.get('have') ?? '') ? params.get('have') : null;
  const advance = params.get('advance') === '1';
  const settings = await getSettings(env);
  const sleepSeconds = clamp(settings.checkMinutes * 60, MIN_SLEEP_S, MAX_SLEEP_S);

  const lastChangeAt = (await kvGet(env, 'last_change_at')) ?? 0;
  const chosen = await chooseNext(env, { have, advance, settings, now, lastChangeAt });

  await kvPut(env, 'frame_status', {
    seenAt: now,
    batteryMv: numberOrNull(params.get('mv')),
    batteryPct: numberOrNull(params.get('pct')),
    onUsb: params.get('usb') === '1',
    rssi: numberOrNull(params.get('rssi')),
    firmware: (params.get('fw') ?? '').slice(0, 16),
    showing: chosen ? chosen.id : have,
  });

  const headers = { 'X-Sleep-Seconds': String(sleepSeconds), 'Cache-Control': 'no-store' };

  if (!chosen) {
    const { n } = await env.DB.prepare('SELECT COUNT(*) AS n FROM photos').first();
    return new Response(null, { status: n === 0 ? 204 : 304, headers });
  }

  await env.DB.batch([
    env.DB.prepare('UPDATE photos SET shown_count = shown_count + 1, last_shown_at = ? WHERE id = ?').bind(now, chosen.id),
    env.DB.prepare('INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v').bind('current_id', JSON.stringify(chosen.id)),
    env.DB.prepare('INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v').bind('last_change_at', JSON.stringify(now)),
  ]);

  const frame = blobBytes(chosen.frame);
  return new Response(frame, {
    headers: {
      ...headers,
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(frame.byteLength),
      'X-Photo-Id': chosen.id,
    },
  });
}

// Priority: a picture the user pinned as "show next", then anything never
// shown (oldest upload first), then the regular rotation when it is due.
async function chooseNext(env, { have, advance, settings, now, lastChangeAt }) {
  const db = env.DB;
  const notHave = have ?? '';

  const pinned = await kvGet(env, 'next_id');
  if (pinned) {
    await kvDelete(env, 'next_id');
    const row = await db.prepare('SELECT id, frame FROM photos WHERE id = ?').bind(pinned).first();
    if (row && row.id !== have) return row;
  }

  const unseen = await db.prepare(
    'SELECT id, frame FROM photos WHERE shown_count = 0 AND id != ? ORDER BY created_at ASC LIMIT 1',
  ).bind(notHave).first();
  if (unseen) return unseen;

  // The frame lost its picture (first boot, or it was deleted): send something.
  const haveExists = have && (await db.prepare('SELECT 1 AS x FROM photos WHERE id = ?').bind(have).first());

  // The frame's timer drifts a little, so allow a minute of slack.
  const rotationDue = settings.rotateMinutes > 0 && now - lastChangeAt >= settings.rotateMinutes * 60_000 - 60_000;
  if (!advance && !rotationDue && haveExists) return null;

  const orderBy = settings.order === 'shuffle' ? 'RANDOM()' : 'last_shown_at ASC, created_at ASC';
  return db.prepare(`SELECT id, frame FROM photos WHERE id != ? ORDER BY ${orderBy} LIMIT 1`).bind(notHave).first();
}

// -------------------------------------------------------------------- helpers

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

async function requireSecret(request, secret, name) {
  // Fail closed: an unset secret must never mean "no password".
  if (!secret || secret.length < 8) throw new HttpError(500, `server is missing the ${name} secret (8+ characters)`);
  const header = request.headers.get('Authorization') ?? '';
  const given = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!(await safeEqual(given, secret))) throw new HttpError(401, 'unauthorized');
}

// Compares digests so timing does not reveal how much of the secret matched.
async function safeEqual(a, b) {
  const enc = new TextEncoder();
  const [da, db] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(a)),
    crypto.subtle.digest('SHA-256', enc.encode(b)),
  ]);
  const x = new Uint8Array(da);
  const y = new Uint8Array(db);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

async function getSettings(env) {
  return { ...DEFAULT_SETTINGS, ...((await kvGet(env, 'settings')) ?? {}) };
}

async function kvGet(env, key) {
  const row = await env.DB.prepare('SELECT v FROM kv WHERE k = ?').bind(key).first();
  return row ? JSON.parse(row.v) : undefined;
}

async function kvPut(env, key, value) {
  await env.DB.prepare('INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v')
    .bind(key, JSON.stringify(value)).run();
}

async function kvDelete(env, key) {
  await env.DB.prepare('DELETE FROM kv WHERE k = ?').bind(key).run();
}

// D1 returns BLOB columns as plain arrays of numbers.
function blobBytes(value) {
  return value instanceof ArrayBuffer ? new Uint8Array(value) : Uint8Array.from(value);
}

function randomId() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

function intInRange(value, min, max, name) {
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new HttpError(400, `${name} must be a whole number from ${min} to ${max}`);
  }
  return value;
}

function numberOrNull(value) {
  const n = Number(value);
  return value !== null && value !== '' && Number.isFinite(n) ? n : null;
}

function clamp(v, min, max) {
  return Math.min(max, Math.max(min, v));
}
