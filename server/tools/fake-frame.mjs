#!/usr/bin/env node
// Pretends to be the frame: asks the server for the next picture exactly the
// way the firmware does and saves what the panel would show as a PNG. Useful
// for testing the server without the hardware.
//
//   node tools/fake-frame.mjs <server-url> <frame-token> [--advance] [--out frame.png]

import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { unpack, toRGBA, viewSize } from '../public/epd.js';

const args = process.argv.slice(2);
const flags = new Set(args.filter((a) => a.startsWith('--')));
const outAt = args.indexOf('--out');
const out = outAt >= 0 ? args[outAt + 1] : 'frame.png';
const [server, token] = args.filter((a, i) => !a.startsWith('--') && i !== outAt + 1);
if (!server || !token) {
  console.error('usage: fake-frame.mjs <server-url> <frame-token> [--advance] [--portrait] [--out frame.png]');
  process.exit(2);
}

const stateFile = '.fake-frame-have';
const have = existsSync(stateFile) ? readFileSync(stateFile, 'utf8').trim() : '';
const query = new URLSearchParams({
  have, advance: flags.has('--advance') ? '1' : '0', mv: '3950', pct: '78', usb: '0', rssi: '-61', fw: 'fake',
});

const response = await fetch(`${server}/api/frame/next?${query}`, { headers: { Authorization: `Bearer ${token}` } });
console.log(`HTTP ${response.status}, sleep ${response.headers.get('x-sleep-seconds')} s`);

if (response.status === 200) {
  const frame = new Uint8Array(await response.arrayBuffer());
  const id = response.headers.get('x-photo-id');
  const orientation = flags.has('--portrait') ? 'portrait' : 'landscape';
  const { width, height } = viewSize(orientation);
  writeFileSync(out, png(toRGBA(unpack(frame, orientation), 'rgb'), width, height));
  writeFileSync(stateFile, id);
  console.log(`photo ${id}, ${frame.length} bytes, wrote ${out}`);
} else if (response.status === 304) {
  console.log('keep showing the current picture');
} else if (response.status === 204) {
  console.log('no pictures uploaded yet');
} else {
  console.log(await response.text());
  process.exit(1);
}

// Minimal PNG writer (8-bit RGBA, no dependencies).
function png(rgba, width, height) {
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    Buffer.from(rgba.buffer, y * width * 4, width * 4).copy(raw, y * (width * 4 + 1) + 1);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header.set([8, 6, 0, 0, 0], 8);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]);
}

function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type), data]);
  const out = Buffer.alloc(body.length + 8);
  out.writeUInt32BE(data.length, 0);
  body.copy(out, 4);
  out.writeUInt32BE(crc32(body), body.length + 4);
  return out;
}

function crc32(buf) {
  let c = ~0;
  for (const byte of buf) {
    c ^= byte;
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return ~c >>> 0;
}
