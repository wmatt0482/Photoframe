import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  INKS, PANEL_W, PANEL_H, FRAME_BYTES,
  viewSize, adjust, dither, pack, unpack, isValidFrame, encode,
} from '../public/epd.js';

const solid = (w, h, [r, g, b]) => {
  const rgba = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < rgba.length; i += 4) rgba.set([r, g, b, 255], i);
  return rgba;
};

test('each ink colour dithers to itself', () => {
  INKS.forEach((ink, i) => {
    const out = dither(solid(16, 16, ink.rgb), 16, 16);
    assert.ok(out.every((v) => v === i), ink.name);
  });
});

test('pure white and pure black stay solid', () => {
  assert.ok(dither(solid(32, 32, [255, 255, 255]), 32, 32).every((v) => INKS[v].name === 'white'));
  assert.ok(dither(solid(32, 32, [0, 0, 0]), 32, 32).every((v) => INKS[v].name === 'black'));
});

test('mid grey dithers to a mix that averages near grey', () => {
  const out = dither(solid(64, 64, [128, 128, 128]), 64, 64);
  const sum = [0, 0, 0];
  for (const v of out) INKS[v].rgb.forEach((c, k) => { sum[k] += c; });
  for (const total of sum) assert.ok(Math.abs(total / out.length - 128) < 6);
});

test('pack produces a valid frame of the right size', () => {
  for (const orientation of ['landscape', 'portrait']) {
    const { width, height } = viewSize(orientation);
    const indices = Uint8Array.from({ length: width * height }, (_, i) => i % INKS.length);
    const frame = pack(indices, orientation);
    assert.equal(frame.length, FRAME_BYTES);
    assert.ok(isValidFrame(frame));
  }
});

test('unpack reverses pack in every orientation', () => {
  for (const orientation of ['landscape', 'portrait']) {
    for (const flip of [false, true]) {
      const { width, height } = viewSize(orientation);
      const indices = Uint8Array.from({ length: width * height }, (_, i) => (i * 7 + (i >> 5)) % INKS.length);
      assert.deepEqual(unpack(pack(indices, orientation, flip), orientation, flip), indices);
    }
  }
});

// Waveshare's firmware turns a landscape picture 180 degrees before sending
// it, so the viewer's top-left pixel is the panel's last pixel.
test('landscape matches the stock 180 degree mounting', () => {
  const indices = new Uint8Array(PANEL_W * PANEL_H).fill(1);
  indices[0] = 3; // red, top-left as seen by the viewer
  const frame = pack(indices, 'landscape');
  assert.equal(frame[FRAME_BYTES - 1] & 0x0f, INKS[3].code);
  assert.equal(frame[0], 0x11);
});

// Stock portrait handling: panel(x = viewY, y = 479 - viewX).
test('portrait matches the stock 90 degree rotation', () => {
  const indices = new Uint8Array(PANEL_W * PANEL_H).fill(1);
  indices[0] = 4; // blue, top-left as seen by the viewer
  const frame = pack(indices, 'portrait');
  const at = (PANEL_H - 1) * (PANEL_W / 2);
  assert.equal(frame[at] >> 4, INKS[4].code);
});

test('flip turns the picture a further 180 degrees', () => {
  const indices = new Uint8Array(PANEL_W * PANEL_H).fill(1);
  indices[0] = 3;
  const frame = pack(indices, 'landscape', true);
  assert.equal(frame[0] >> 4, INKS[3].code);
});

test('isValidFrame rejects wrong sizes and unused codes', () => {
  assert.equal(isValidFrame(new Uint8Array(10)), false);
  const frame = new Uint8Array(FRAME_BYTES).fill(0x11);
  assert.equal(isValidFrame(frame), true);
  frame[100] = 0x14; // code 4 is not an ink
  assert.equal(isValidFrame(frame), false);
  frame[100] = 0x71;
  assert.equal(isValidFrame(frame), false);
});

test('adjust leaves the image alone at 1 and raises contrast above it', () => {
  const rgba = solid(2, 2, [100, 150, 200]);
  assert.deepEqual(adjust(new Uint8ClampedArray(rgba)), rgba);
  const out = adjust(new Uint8ClampedArray(rgba), { contrast: 1.5 });
  assert.ok(out[0] < 100 && out[2] > 200);
});

test('encode does not modify its input', () => {
  const rgba = solid(PANEL_W, PANEL_H, [90, 120, 60]);
  const copy = new Uint8ClampedArray(rgba);
  const { frame } = encode(rgba, { contrast: 1.3, saturation: 1.4 });
  assert.deepEqual(rgba, copy);
  assert.ok(isValidFrame(frame));
});

const inkShare = (out, names) => out.filter((v) => names.includes(INKS[v].name)).length / out.length;

// The black ink is slightly blue, so a rare coloured dot corrects for it.
test('neutral greys are at least 97% black and white ink', () => {
  for (const level of [60, 128, 190]) {
    const out = dither(solid(64, 64, [level, level, level]), 64, 64);
    assert.ok(inkShare(out, ['black', 'white']) >= 0.97, `grey ${level}`);
  }
});

test('a faintly tinted grey stays almost entirely black and white', () => {
  const out = dither(solid(64, 64, [150, 156, 166]), 64, 64);
  assert.ok(inkShare(out, ['black', 'white']) > 0.85);
});

test('clearly coloured areas still use coloured ink', () => {
  const sky = dither(solid(64, 64, [70, 130, 220]), 64, 64);
  assert.ok(inkShare(sky, ['blue']) > 0.4);
  const skin = dither(solid(64, 64, [224, 168, 130]), 64, 64);
  assert.ok(inkShare(skin, ['yellow', 'red']) > 0.2);
});
