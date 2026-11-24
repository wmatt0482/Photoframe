import { viewSize, adjust, dither, pack, toRGBA } from './epd.js';

const $ = (id) => document.getElementById(id);
const PASSWORD_KEY = 'photoframe.password';

let password = localStorage.getItem(PASSWORD_KEY) ?? '';
let state = null;

// ------------------------------------------------------------------- API

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { ...(options.headers ?? {}), Authorization: `Bearer ${password}` },
  });
  if (response.status === 401) {
    showLogin('That password was not accepted.');
    throw new Error('unauthorized');
  }
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error ?? `Request failed (${response.status})`);
  return body;
}

// ---------------------------------------------------------------- screens

function show(screen) {
  for (const id of ['login', 'home', 'editor']) $(id).hidden = id !== screen;
}

function showLogin(message) {
  show('login');
  $('login-error').textContent = message ?? '';
  $('login-error').hidden = !message;
  $('password').focus();
}

$('login-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  password = $('password').value;
  try {
    await refresh();
    localStorage.setItem(PASSWORD_KEY, password);
    $('password').value = '';
  } catch (err) {
    if (err.message !== 'unauthorized') showLogin(err.message);
  }
});

async function refresh() {
  state = await api('/api/state');
  renderHome();
  show('home');
}

// ---------------------------------------------------------------- library

function renderHome() {
  $('frame-status').textContent = describeFrame(state.frame);
  $('empty').hidden = state.photos.length > 0;

  const grid = $('grid');
  grid.replaceChildren();
  for (const photo of state.photos) {
    const item = document.createElement('li');
    const button = document.createElement('button');
    button.type = 'button';
    const img = document.createElement('img');
    img.src = `/api/photos/${photo.id}/preview`;
    img.alt = photo.caption || `Photo added ${formatDate(photo.createdAt)}`;
    img.loading = 'lazy';
    button.append(img);

    const label = badgeFor(photo);
    if (label) {
      const badge = document.createElement('span');
      badge.className = 'badge';
      badge.textContent = label;
      button.append(badge);
    }
    button.addEventListener('click', () => openPhoto(photo));
    item.append(button);
    grid.append(item);
  }
}

function badgeFor(photo) {
  if (state.frame?.showing === photo.id) return 'On the frame';
  if (state.nextId === photo.id) return 'Up next';
  if (photo.shownCount === 0) return 'Waiting';
  return '';
}

function describeFrame(frame) {
  if (!frame) return 'The frame has not checked in yet.';
  const parts = [`Frame last checked in ${formatAgo(frame.seenAt)}`];
  if (frame.onUsb) parts.push('on USB power');
  else if (frame.batteryPct !== null && frame.batteryPct >= 0) parts.push(`battery ${frame.batteryPct}%`);
  return parts.join(', ') + '.';
}

function formatAgo(ms) {
  const minutes = Math.round((Date.now() - ms) / 60000);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours} h ago`;
  return `${Math.round(hours / 24)} days ago`;
}

function formatDate(ms) {
  return new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

// ----------------------------------------------------------- photo dialog

let openId = null;

function openPhoto(photo) {
  openId = photo.id;
  $('photo-dialog-img').src = `/api/photos/${photo.id}/preview`;
  const shown = photo.shownCount === 0 ? 'not shown yet' : `shown ${photo.shownCount} time${photo.shownCount === 1 ? '' : 's'}`;
  $('photo-dialog-meta').textContent = `Added ${formatDate(photo.createdAt)}, ${shown}.`;
  $('photo-dialog').showModal();
}

$('photo-close').addEventListener('click', () => $('photo-dialog').close());

$('photo-next').addEventListener('click', async () => {
  await api(`/api/photos/${openId}/next`, { method: 'POST' });
  $('photo-dialog').close();
  await refresh();
});

$('photo-delete').addEventListener('click', async () => {
  if (!confirm('Delete this photo?')) return;
  await api(`/api/photos/${openId}`, { method: 'DELETE' });
  $('photo-dialog').close();
  await refresh();
});

// --------------------------------------------------------------- settings

$('open-settings').addEventListener('click', () => {
  const s = state.settings;
  $('s-orientation').value = s.orientation;
  $('s-flip').checked = s.flip;
  setSelect($('s-check'), s.checkMinutes);
  setSelect($('s-rotate'), s.rotateMinutes);
  $('s-order').value = s.order;
  $('settings-error').hidden = true;
  $('settings-dialog').showModal();
});

// A value set outside the app may not be one of the presets; add it so the
// select shows the truth and saving does not silently change it.
function setSelect(select, minutes) {
  if (![...select.options].some((o) => Number(o.value) === minutes)) {
    select.add(new Option(`Every ${minutes} minutes`, String(minutes)));
  }
  select.value = String(minutes);
}

$('settings-close').addEventListener('click', () => $('settings-dialog').close());

$('settings-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    state.settings = await api('/api/settings', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        orientation: $('s-orientation').value,
        flip: $('s-flip').checked,
        checkMinutes: Number($('s-check').value),
        rotateMinutes: Number($('s-rotate').value),
        order: $('s-order').value,
      }),
    });
    $('settings-dialog').close();
  } catch (err) {
    $('settings-error').textContent = err.message;
    $('settings-error').hidden = false;
  }
});

$('sign-out').addEventListener('click', () => {
  localStorage.removeItem(PASSWORD_KEY);
  password = '';
  $('settings-dialog').close();
  showLogin();
});

// ----------------------------------------------------------------- editor

const canvas = $('canvas');
const ctx = canvas.getContext('2d', { willReadFrequently: true });
const edit = { image: null, zoom: 1, minZoom: 1, coverZoom: 1, x: 0, y: 0, indices: null };
let renderQueued = false;

$('file').addEventListener('change', async (event) => {
  const file = event.target.files[0];
  event.target.value = '';
  if (!file) return;
  try {
    edit.image = await createImageBitmap(file, { imageOrientation: 'from-image' });
  } catch {
    alert('That file could not be opened as a picture.');
    return;
  }
  const { width, height } = viewSize(state.settings.orientation);
  canvas.width = width;
  canvas.height = height;

  const contain = Math.min(width / edit.image.width, height / edit.image.height);
  edit.coverZoom = Math.max(width / edit.image.width, height / edit.image.height);
  edit.minZoom = contain;
  edit.zoom = edit.coverZoom;
  edit.x = 0;
  edit.y = 0;
  $('zoom').value = zoomToSlider(edit.zoom);
  $('show-original').checked = false;
  $('editor-error').hidden = true;
  $('send').disabled = false;
  $('send').textContent = 'Send to frame';
  show('editor');
  queueRender();
});

// The slider runs from "whole picture visible" to four times "fills the frame".
function sliderToZoom(t) {
  const max = edit.coverZoom * 4;
  return edit.minZoom * Math.pow(max / edit.minZoom, t);
}
function zoomToSlider(zoom) {
  const max = edit.coverZoom * 4;
  return Math.log(zoom / edit.minZoom) / Math.log(max / edit.minZoom);
}

// Keeps the picture from being dragged off the canvas.
function clampOffset() {
  const maxX = Math.abs(edit.image.width * edit.zoom - canvas.width) / 2;
  const maxY = Math.abs(edit.image.height * edit.zoom - canvas.height) / 2;
  edit.x = Math.max(-maxX, Math.min(maxX, edit.x));
  edit.y = Math.max(-maxY, Math.min(maxY, edit.y));
}

function drawSource(target, scale = 1) {
  const w = edit.image.width * edit.zoom * scale;
  const h = edit.image.height * edit.zoom * scale;
  const cw = canvas.width * scale;
  const ch = canvas.height * scale;
  target.fillStyle = '#fff';
  target.fillRect(0, 0, cw, ch);
  target.imageSmoothingQuality = 'high';
  target.drawImage(edit.image, (cw - w) / 2 + edit.x * scale, (ch - h) / 2 + edit.y * scale, w, h);
}

function queueRender() {
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(() => {
    renderQueued = false;
    render();
  });
}

function render() {
  clampOffset();
  drawSource(ctx);
  const pixels = ctx.getImageData(0, 0, canvas.width, canvas.height);
  adjust(pixels.data, { contrast: Number($('contrast').value), saturation: Number($('saturation').value) });
  edit.indices = dither(pixels.data, canvas.width, canvas.height);
  if (!$('show-original').checked) {
    ctx.putImageData(new ImageData(toRGBA(edit.indices, 'rgb'), canvas.width, canvas.height), 0, 0);
  }
}

for (const id of ['contrast', 'saturation', 'show-original']) $(id).addEventListener('input', queueRender);

$('zoom').addEventListener('input', () => {
  edit.zoom = sliderToZoom(Number($('zoom').value));
  queueRender();
});

// Drag to pan; pointer events cover mouse and touch.
let drag = null;
canvas.addEventListener('pointerdown', (event) => {
  canvas.setPointerCapture(event.pointerId);
  drag = { px: event.clientX, py: event.clientY, x: edit.x, y: edit.y };
});
canvas.addEventListener('pointermove', (event) => {
  if (!drag) return;
  const scale = canvas.width / canvas.getBoundingClientRect().width;
  edit.x = drag.x + (event.clientX - drag.px) * scale;
  edit.y = drag.y + (event.clientY - drag.py) * scale;
  queueRender();
});
for (const type of ['pointerup', 'pointercancel']) canvas.addEventListener(type, () => { drag = null; });

// Arrow keys move the picture for people not using a pointer.
canvas.tabIndex = 0;
canvas.addEventListener('keydown', (event) => {
  const step = event.shiftKey ? 40 : 10;
  const moves = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
  const move = moves[event.key];
  if (!move) return;
  event.preventDefault();
  edit.x += move[0];
  edit.y += move[1];
  queueRender();
});

$('editor-cancel').addEventListener('click', () => show('home'));

$('send').addEventListener('click', async () => {
  $('send').disabled = true;
  $('send').textContent = 'Sending…';
  $('editor-error').hidden = true;
  try {
    render();
    const { orientation, flip } = state.settings;
    const frame = pack(edit.indices, orientation, flip);

    const form = new FormData();
    form.append('frame', new Blob([frame], { type: 'application/octet-stream' }), 'frame.bin');
    form.append('preview', await makePreview(), 'preview.jpg');
    await api('/api/photos', { method: 'POST', body: form });
    await refresh();
  } catch (err) {
    $('editor-error').textContent = `Could not send: ${err.message}`;
    $('editor-error').hidden = false;
    $('send').disabled = false;
    $('send').textContent = 'Send to frame';
  }
});

// The library thumbnail is the cropped original, not the dithered version.
function makePreview() {
  const scale = 0.5;
  const small = document.createElement('canvas');
  small.width = canvas.width * scale;
  small.height = canvas.height * scale;
  drawSource(small.getContext('2d'), scale);
  return new Promise((resolve, reject) => {
    small.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('could not make preview'))), 'image/jpeg', 0.82);
  });
}

// ------------------------------------------------------------------ start

if (password) {
  refresh().catch((err) => {
    if (err.message !== 'unauthorized') showLogin(err.message);
  });
} else {
  showLogin();
}

// Pick up frame check-ins and uploads from other people while the app is open.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && state && !$('home').hidden) refresh().catch(() => {});
});
